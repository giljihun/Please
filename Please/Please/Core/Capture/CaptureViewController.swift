//
//  CaptureViewController.swift
//  Please
//
//  Created by 길지훈 on 8/18/26.
//

import UIKit
import AVFoundation

/// Vision 결과의 메인 액터 전달을 하나의 최신값 슬롯으로 병합한다.
///
/// 프레임마다 `Task { @MainActor in ... }`를 만들면 메인 스레드가 잠깐 바쁜 동안
/// 과거 좌표가 큐에 계속 쌓인다. 사용자가 보는 것은 손의 현재 위치여야 하므로,
/// 아직 전달하지 않은 결과는 더 최신 프레임으로 덮어쓰고 예약된 Task는 최대 하나만 둔다.
/// 가변 상태는 락으로 보호하므로 프레임 큐와 메인 액터에서 동시에 접근해도 안전하다.
nonisolated private final class LatestHandPoseResultCoalescer: @unchecked Sendable {

    struct Item: Sendable {
        let result: HandPoseDetector.Result
        let generation: Int
    }

    typealias Handler = @MainActor @Sendable (Item) -> Void

    private let lock = NSLock()
    private let handler: Handler
    private var latestItem: Item?
    private var isDeliveryScheduled = false

    init(handler: @escaping Handler) {
        self.handler = handler
    }

    /// 호출 스레드와 무관하게 최신 결과 하나만 보관한다.
    func submit(_ item: Item) {
        let shouldSchedule = lock.withLock {
            // 같은 세대의 결과가 역순으로 도착하더라도 더 오래된 프레임이 최신값을
            // 덮지 못하게 캡처 타임스탬프를 함께 비교한다.
            if let latestItem,
               latestItem.generation == item.generation,
               latestItem.result.presentationTimestamp > item.result.presentationTimestamp {
                return false
            }

            latestItem = item
            guard !isDeliveryScheduled else { return false }
            isDeliveryScheduled = true
            return true
        }

        guard shouldSchedule else { return }
        scheduleDelivery()
    }

    /// 대기 중인 결과를 버린다. 이미 예약된 Task는 빈 슬롯을 확인하고 종료한다.
    func discardPending() {
        lock.withLock { latestItem = nil }
    }

    private func scheduleDelivery() {
        Task { @MainActor [self] in
            deliverLatest()
        }
    }

    @MainActor
    private func deliverLatest() {
        let item = lock.withLock {
            defer { latestItem = nil }
            return latestItem
        }

        if let item {
            handler(item)
        }

        let shouldContinue = lock.withLock {
            guard latestItem != nil else {
                isDeliveryScheduled = false
                return false
            }
            return true
        }

        // 소비 중 새 프레임이 도착했다면 다음 메인 액터 턴에서 최신값만 전달한다.
        // 현재 Task 안에서 반복하지 않아 UI 이벤트에 실행 기회를 돌려준다.
        if shouldContinue {
            scheduleDelivery()
        }
    }
}

/// 사인 세션 화면의 UIKit 코어.
///
/// 설계 근거: 이 화면만 SwiftUI가 아닌 UIKit인 이유는
/// ① AVCaptureVideoPreviewLayer를 직접 다뤄야 하고
/// ② coalesced/predictedTouches 기반 드로잉은 UIKit 터치 이벤트에서만 가능하기 때문
/// (PLANNING.md 3장 모듈 구조 참고)
final class CaptureViewController: UIViewController {

    let canvasView = DrawingCanvasView()

    private let cameraService = CameraService()
    private let handDetector = HandPoseDetector()
    private let handOverlay = HandOverlayView()
    private let gesturePenFeedback = GesturePenFeedbackView()
    private lazy var gestureDrawing = GestureDrawingController(canvas: canvasView)
    private lazy var handResultCoalescer = LatestHandPoseResultCoalescer { [weak self] item in
        self?.consumeHandResult(item.result, generation: item.generation)
    }
    private var previewLayer: AVCaptureVideoPreviewLayer?
    private var appearTask: Task<Void, Never>?
    private var isViewVisible = false

    /// 카메라 이벤트를 SwiftUI 쪽(ViewModel)으로 전달하는 브릿지
    var onCameraEvent: ((CameraEvent) -> Void)?

    /// 손 인식 결과를 개발용 지표로 전달 (#19 검증용 — 인식 성공 여부, 처리 시간)
    var onHandDetection: ((Bool, Double) -> Void)?

    /// 스켈레톤 오버레이 표시 여부 (개발용 토글)
    ///
    /// oldValue 비교가 필수인 이유: updateUIViewController는 VM의 어떤 값이 바뀌어도
    /// 다시 호출되므로(예: 처리 시간 표시가 매 프레임 갱신) 같은 값이 반복 대입된다.
    /// 걸러주지 않으면 매 프레임 세대 번호가 올라가 진행 중이던 분석 결과가 전부 폐기된다
    var isHandOverlayEnabled = false {
        didSet {
            guard isHandOverlayEnabled != oldValue else { return }
            handOverlay.isHidden = !isHandOverlayEnabled
            if !isHandOverlayEnabled {
                handOverlay.update(pose: nil, imageSize: .zero)
            }
            visionGeneration += 1
            updateFrameHandler()
        }
    }

    /// 제스처 드로잉 활성화 여부 (개발용 토글).
    ///
    /// 스켈레톤과 분리한 이유: 뼈대가 화면을 덮으면 사인 선의 품질을 눈으로 볼 수 없다.
    /// 반대로 선이 이상할 때는 뼈대를 켜서 원인을 봐야 한다 — 둘은 독립적으로 필요하다
    var isGestureDrawingEnabled = false {
        didSet {
            guard isGestureDrawingEnabled != oldValue else { return }
            // 켜지는 순간 진행 중이던 터치 획을 먼저 확정한다.
            // isUserInteractionEnabled = false는 "새 터치를 받지 않는다"는 뜻일 뿐,
            // 히트테스트는 터치가 시작될 때 한 번만 하므로 이미 배정된 터치는 계속 도착한다
            if isGestureDrawingEnabled {
                canvasView.endStroke()
            }
            // 제스처 모드에서 터치를 막는 이유: 화면을 스치기만 해도 사인에 선이 섞인다.
            // 제품 규칙상 터치는 제스처가 안 될 때의 폴백이지 동시 입력이 아니다
            canvasView.isUserInteractionEnabled = !isGestureDrawingEnabled
            // 모드를 켤 때 이미 pinch 중인 손을 새 획으로 오인하지 않도록,
            // open 상태를 한 번 본 뒤에만 Apple식 새 pinch 생명주기를 시작한다.
            gestureDrawing.reset(requiresRelease: isGestureDrawingEnabled)
            visionGeneration += 1
            updateFrameHandler()
        }
    }

    /// Vision 분석이 필요한지 — 둘 중 하나라도 켜져 있으면 돌린다
    private var isVisionEnabled: Bool {
        isHandOverlayEnabled || isGestureDrawingEnabled
    }

    /// 토글 세대 번호. "켜짐 여부"만으로는 껐다 켠 사이에 완료된 분석을 걸러낼 수 없어
    /// (다시 켜면 조건을 통과함), 결과가 어느 세션의 것인지 함께 확인한다.
    /// VM의 명령 카운터·실패 세대와 같은 패턴 — 비동기 결과의 유효성 판단
    private var visionGeneration = 0

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black

        // 프리뷰 레이어는 세션을 참조만 하므로 메인에서 생성해도 안전 (구성은 sessionQueue에서)
        let layer = cameraService.makePreviewLayer()
        layer.videoGravity = .resizeAspectFill  // 화면 꽉 채움 (여백보다 크롭 선택)
        view.layer.addSublayer(layer)
        previewLayer = layer

        canvasView.frame = view.bounds
        canvasView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(canvasView)

        // 장식용 펜 피드백은 결과물인 캔버스와 진단용 스켈레톤 사이에 둔다.
        // 터치를 가로채지 않으며 이후 녹화 합성 대상에서도 제외한다.
        gesturePenFeedback.frame = view.bounds
        gesturePenFeedback.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(gesturePenFeedback)

        // 스켈레톤은 캔버스 위에 — 사인 선에 가려지면 진단 도구로서 의미가 없다
        handOverlay.frame = view.bounds
        handOverlay.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        handOverlay.isHidden = true
        view.addSubview(handOverlay)

        gestureDrawing.onFeedback = { [weak self] feedback in
            self?.renderGestureFeedback(feedback)
        }
        gestureDrawing.reset(requiresRelease: isGestureDrawingEnabled)

        // sessionQueue → 메인 액터 홉: UI 상태 갱신은 메인에서만
        cameraService.setEventHandler { [weak self] event in
            Task { @MainActor in
                self?.handleCameraEvent(event)
            }
        }

        // 설정 앱에서 권한을 허용하고 돌아온 경우를 감지 —
        // viewDidAppear는 포그라운드 복귀만으로는 재호출되지 않는다.
        // 셀렉터 방식: iOS 9+는 자동 해제라 deinit 정리가 필요 없고,
        // Swift 6에서 nonisolated deinit이 non-Sendable 토큰을 못 만지는 문제도 회피
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleForegroundReturn),
            name: UIApplication.willEnterForegroundNotification,
            object: nil
        )
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        isViewVisible = true
        // 화면 이탈 때 프레임 핸들러를 해제하므로, 카메라를 켜기 전에 현재 세대로 복원한다.
        updateFrameHandler()
        // 최초 진입: 권한 거부 시 이벤트로 보고 (알럿 표시)
        startCameraFlow(reportDenial: true)
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        // stop() 뒤 늦은 카메라 이벤트가 와도 프레임 핸들러를 다시 설치하지 못하게 먼저 내린다.
        isViewVisible = false
        appearTask?.cancel()
        appearTask = nil
        cameraService.stop()
        // stop()은 이미 분석에 들어간 프레임까지 취소하지 못하므로, 세대를 올려
        // 화면 이탈 전에 시작된 결과를 전부 무효화한다.
        // 이 함수는 await 없는 동기 코드라 실행 중에 다른 Task가 끼어들 수 없다 —
        // 따라서 중요한 것은 "이 줄이 여기 있다"는 사실이지 reset()과의 순서가 아니다
        visionGeneration += 1
        handResultCoalescer.discardPending()
        // 핸들러를 그대로 두면 재진입 후에도 이전 generation을 캡처한 결과만 들어온다.
        // 화면 밖에서는 분석도 필요 없으므로 해제하고 viewDidAppear에서 새로 설치한다.
        cameraService.setFrameHandler(nil)
        // 프레임이 끊기면 그리던 획이 공중에 뜬 채 남는다 — 여기서 닫아준다
        gestureDrawing.reset(requiresRelease: true)
    }

    /// 권한 확인 → 세션 시작.
    ///
    /// Task를 보관하는 이유: 권한 다이얼로그가 떠 있는 동안 사용자가 화면을
    /// 벗어나면, VC가 사라진 뒤 완료된 Task가 멈춘 세션을 되살릴 수 있다.
    /// viewWillDisappear에서 취소해 이 경합을 차단한다.
    /// 취소 가드는 await 직후 — "화면을 떠났으면 어떤 경로로도 콜백을 쏘지 않는다"는
    /// 단일 규칙을 모든 분기에 일관 적용하기 위함
    private func startCameraFlow(reportDenial: Bool) {
        appearTask?.cancel()
        appearTask = Task {
            let granted = await CameraService.requestAccess()
            guard !Task.isCancelled else { return }
            guard granted else {
                if reportDenial {
                    handleCameraEvent(.failed(.permissionDenied))
                }
                return
            }
            cameraService.start()
        }
    }

    /// 포그라운드 복귀 시 재기동. 화면이 실제로 보일 때만 —
    /// 여전히 거부 상태면 침묵 (복귀할 때마다 알럿을 다시 띄우면 괴롭힘이 된다)
    @objc private func handleForegroundReturn() {
        guard viewIfLoaded?.window != nil else { return }
        startCameraFlow(reportDenial: false)
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        // 프리뷰 레이어는 오토레이아웃 대상이 아니라서 수동으로 프레임 동기화
        previewLayer?.frame = view.bounds
    }

    /// 실패 알럿의 "다시 시도" 동선 (SwiftUI → VM retrySignal → 여기)
    func retryCamera() {
        cameraService.start()
    }

    /// 캔버스 지우기 (SwiftUI → VM clearSignal → 여기).
    ///
    /// 캔버스를 직접 비우지 않고 이 경로를 거치는 이유: 그립 중에 지우면
    /// 캔버스는 획을 닫지만 제스처 컨트롤러는 여전히 "그리는 중"으로 남는다.
    /// 그 상태에서는 다음 프레임의 점이 전부 버려져, 손을 한 번 뗐다 다시 쥐어야 복구된다
    func clearCanvas() {
        // clear 직전 프레임이 메인 액터 대기열에 남아 있으면, 그 open 판정이 clear 뒤
        // release gate를 잘못 열 수 있다. 세대를 교체해 clear 이전 결과를 모두 무효화한다.
        visionGeneration += 1
        handResultCoalescer.discardPending()
        gestureDrawing.reset(requiresRelease: true)
        canvasView.clear()
        updateFrameHandler()
    }

    // MARK: - 손 인식 파이프라인

    /// 인터럽션·실패는 연속 프레임이라는 전제를 깨므로 진행 중 획도 함께 닫는다.
    /// 세대 증가 후 핸들러를 다시 설치해야 복구 뒤 새 프레임이 새 세대로 들어온다.
    private func handleCameraEvent(_ event: CameraEvent) {
        switch event {
        case .running:
            break
        case .interrupted, .failed:
            visionGeneration += 1
            handResultCoalescer.discardPending()
            gestureDrawing.reset(requiresRelease: true)
            handOverlay.update(pose: nil, imageSize: .zero)
            updateFrameHandler()
        }
        onCameraEvent?(event)
    }

    /// 상태 머신의 의미를 결과물과 분리된 시각 피드백으로 번역한다.
    /// pinch를 놓은 `.hover`에서는 펜 본체가 즉시 사라지고 작은 위치 링만 남는다.
    private func renderGestureFeedback(_ feedback: GestureDrawingController.Feedback) {
        guard isGestureDrawingEnabled else {
            gesturePenFeedback.update(
                state: .hidden,
                screenPoint: nil,
                penColor: canvasView.strokeColor
            )
            return
        }

        let state: GesturePenFeedbackView.State
        if feedback.state == .hidden {
            state = .hidden
        } else if feedback.isWaitingForRelease {
            // 인식은 되지만 release 전이라 입력이 잠긴 상태. armed hover와 구분한다.
            state = .uncertain
        } else {
            state = switch feedback.state {
            case .hidden: .hidden
            case .hover: .hover
            case .drawing: .drawing
            case .uncertain: .uncertain
            }
        }
        gesturePenFeedback.update(
            state: state,
            screenPoint: feedback.point,
            penColor: canvasView.strokeColor
        )
    }

    /// 둘 다 꺼져 있으면 프레임 핸들러 자체를 해제한다 —
    /// 쓰지도 않을 Vision 분석으로 배터리를 태우지 않기 위함
    private func updateFrameHandler() {
        guard isViewVisible, isVisionEnabled else {
            cameraService.setFrameHandler(nil)
            handResultCoalescer.discardPending()
            return
        }

        // detector를 지역 상수로 캡처하는 이유: 클로저가 self(메인 액터 격리)를 잡으면
        // 컴파일러가 "샘플 버퍼를 메인 액터로 보낸다"고 판단해 데이터 레이스로 막는다.
        // 버퍼는 이 큐 안에서 소비하고, 결과(값 타입)만 메인으로 넘긴다
        let detector = handDetector
        let coalescer = handResultCoalescer
        let generation = visionGeneration
        cameraService.setFrameHandler { sampleBuffer in
            // 프레임 델리게이트 큐에서 분석 (메인 스레드를 막지 않는다).
            // 처리 중이면 detect가 nil을 반환하며 프레임을 버린다
            guard let result = detector.detect(in: sampleBuffer) else { return }
            coalescer.submit(.init(result: result, generation: generation))
        }
    }

    /// 메인 액터에서 최신 결과 하나를 UI와 제스처 상태에 반영한다.
    private func consumeHandResult(_ result: HandPoseDetector.Result, generation: Int) {
        // 토글을 끄는 순간 이미 분석 중이던 프레임의 결과가 뒤늦게 도착할 수 있다.
        // 그대로 반영하면 다시 켤 때 낡은 손 위치가 한 프레임 스쳐 지나간다
        guard isVisionEnabled, visionGeneration == generation else { return }

        if isHandOverlayEnabled {
            handOverlay.update(pose: result.pose, imageSize: result.uprightImageSize)
        }
        if isGestureDrawingEnabled {
            gestureDrawing.update(
                pose: result.pose,
                imageSize: result.uprightImageSize,
                viewSize: canvasView.bounds.size,
                timestamp: result.presentationTimestamp
            )
        }
        onHandDetection?(result.pose != nil, result.processingMilliseconds)
    }
}
