//
//  CaptureViewController.swift
//  Please
//
//  Created by 길지훈 on 8/18/26.
//

import UIKit
import AVFoundation

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
    private var previewLayer: AVCaptureVideoPreviewLayer?
    private var appearTask: Task<Void, Never>?

    /// 카메라 이벤트를 SwiftUI 쪽(ViewModel)으로 전달하는 브릿지
    var onCameraEvent: ((CameraEvent) -> Void)?

    /// 손 인식 결과를 개발용 지표로 전달 (#19 검증용 — 인식 성공 여부, 처리 시간)
    var onHandDetection: ((Bool, Double) -> Void)?

    /// 스켈레톤 오버레이 표시 여부 (개발용 토글)
    var isHandOverlayEnabled = false {
        didSet {
            handOverlayGeneration += 1
            handOverlay.isHidden = !isHandOverlayEnabled
            updateFrameHandler()
        }
    }

    /// 토글 세대 번호. "켜짐 여부"만으로는 껐다 켠 사이에 완료된 분석을 걸러낼 수 없어
    /// (다시 켜면 조건을 통과함), 결과가 어느 세션의 것인지 함께 확인한다.
    /// VM의 명령 카운터·실패 세대와 같은 패턴 — 비동기 결과의 유효성 판단
    private var handOverlayGeneration = 0

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

        // 스켈레톤은 캔버스 위에 — 사인 선에 가려지면 진단 도구로서 의미가 없다
        handOverlay.frame = view.bounds
        handOverlay.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        handOverlay.isHidden = true
        view.addSubview(handOverlay)

        // sessionQueue → 메인 액터 홉: UI 상태 갱신은 메인에서만
        cameraService.setEventHandler { [weak self] event in
            Task { @MainActor in
                self?.onCameraEvent?(event)
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
        // 최초 진입: 권한 거부 시 이벤트로 보고 (알럿 표시)
        startCameraFlow(reportDenial: true)
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        appearTask?.cancel()
        appearTask = nil
        cameraService.stop()
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
                    onCameraEvent?(.failed(.permissionDenied))
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

    // MARK: - 손 인식 파이프라인

    /// 오버레이가 꺼져 있으면 프레임 핸들러 자체를 해제한다 —
    /// 쓰지도 않을 Vision 분석으로 배터리를 태우지 않기 위함
    private func updateFrameHandler() {
        guard isHandOverlayEnabled else {
            cameraService.setFrameHandler(nil)
            handOverlay.update(pose: nil, imageSize: .zero)
            return
        }

        // detector를 지역 상수로 캡처하는 이유: 클로저가 self(메인 액터 격리)를 잡으면
        // 컴파일러가 "샘플 버퍼를 메인 액터로 보낸다"고 판단해 데이터 레이스로 막는다.
        // 버퍼는 이 큐 안에서 소비하고, 결과(값 타입)만 메인으로 넘긴다
        let detector = handDetector
        let generation = handOverlayGeneration
        cameraService.setFrameHandler { [weak self] sampleBuffer in
            // 프레임 델리게이트 큐에서 분석 (메인 스레드를 막지 않는다).
            // 처리 중이면 detect가 nil을 반환하며 프레임을 버린다
            guard let result = detector.detect(in: sampleBuffer) else { return }

            Task { @MainActor in
                // 토글을 끄는 순간 이미 분석 중이던 프레임의 결과가 뒤늦게 도착할 수 있다.
                // 그대로 반영하면 다시 켤 때 낡은 손 위치가 한 프레임 스쳐 지나간다
                guard let self,
                      self.isHandOverlayEnabled,
                      self.handOverlayGeneration == generation else { return }
                self.handOverlay.update(pose: result.pose, imageSize: result.uprightImageSize)
                self.onHandDetection?(result.pose != nil, result.processingMilliseconds)
            }
        }
    }
}
