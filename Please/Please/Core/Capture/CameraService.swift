//
//  CameraService.swift
//  Please
//
//  Created by 길지훈 on 8/18/26.
//

import AVFoundation

/// 사용자 개입이 필요한 카메라 실패 사유
enum CameraServiceError: Error, Equatable {
    case permissionDenied
    case deviceUnavailable
    case configurationFailed
    case runtimeError

    var userMessage: String {
        switch self {
        case .permissionDenied: "카메라 권한이 필요합니다. 설정에서 허용해주세요."
        case .deviceUnavailable: "전면 카메라를 사용할 수 없습니다."
        case .configurationFailed: "카메라를 시작하지 못했습니다."
        case .runtimeError: "카메라 오류가 발생했습니다."
        }
    }
}

/// 카메라 세션의 모든 상태 변화를 단일 채널로 통지하는 이벤트.
///
/// 설계 근거: "에러"와 "상태 변화"를 분리한다.
/// - 인터럽션은 시스템이 복구할 정상 흐름이지 에러가 아니다
/// - 케이스가 enum에 전부 나열되므로 "카메라에 무슨 일이 생길 수 있는가"를
///   한눈에 파악 가능하고, 케이스 추가 시 컴파일러가 처리 누락을 잡아준다
enum CameraEvent {
    case running                     // 세션 동작 시작 (최초 시작 + 자동 복구 포함)
    case interrupted                 // 일시 중단 — 시스템 복구 대기 (사용자 개입 불필요)
    case failed(CameraServiceError)  // 사용자 개입이 필요한 실패
}

/// 전면 카메라 세션 관리 서비스.
///
/// 설계 근거: AVCaptureSession은 Sendable이 아니며, Apple 권장 패턴은
/// "전용 직렬 큐에서만 세션을 다룬다"는 큐 제약(queue confinement)이다.
/// startRunning()이 블로킹 호출이라 메인 스레드에서 부르면 UI가 멈추기 때문.
/// `@unchecked Sendable`은 "동기화는 내가 책임진다"는 선언이고,
/// 그 책임을 sessionQueue 하나로 모든 가변 상태 접근을 강제하는 방식으로 이행한다.
///
/// 책임 원칙: "의도(isActive)는 서비스가, 사실은 이벤트가, 표시는 뷰가" 관리한다.
/// ※ 녹화 상태가 추가되는 #6에서 명시적 enum 상태 머신으로 승격 예정 (이슈 #6 참고)
nonisolated final class CameraService: @unchecked Sendable {

    private let session = AVCaptureSession()
    private let sessionQueue = DispatchQueue(label: "camera.session.queue")

    /// 프레임 델리게이트 전용 큐. 세션 큐와 분리하는 이유:
    /// 프레임 처리(Vision 분석)가 오래 걸려도 세션 제어(시작/중지/복구)가 막히지 않아야 한다
    private let videoOutputQueue = DispatchQueue(label: "camera.video.output.queue")
    private let videoOutput = AVCaptureVideoDataOutput()
    private let frameDelegate = FrameDelegate()

    /// "카메라가 켜져 있어야 한다"는 의도. start/stop만이 바꾼다.
    /// 자동 복구 경로는 이 의도를 확인해야 함 — 화면을 떠난 뒤 카메라가
    /// 다시 켜지는 것은 배터리 낭비이자 프라이버시 문제(심사 리젝 사유)
    private var isActive = false
    private var isConfigured = false
    private var isRecovering = false
    private var observers: [NSObjectProtocol] = []

    /// 이벤트 콜백. sessionQueue에서 불리므로 수신 측이 메인 액터로 홉해야 함.
    /// @unchecked Sendable의 안전 증명을 지키기 위해 이 프로퍼티도 sessionQueue에서만 읽고 쓴다
    private var onEvent: (@Sendable (CameraEvent) -> Void)?

    /// 이벤트 핸들러 등록. 대입도 sessionQueue를 경유시켜 큐 제약을 프로퍼티 전체에 일관 적용
    func setEventHandler(_ handler: @escaping @Sendable (CameraEvent) -> Void) {
        sessionQueue.async { [self] in onEvent = handler }
    }

    /// 프리뷰 레이어 생성. session을 직접 노출하지 않기 위한 팩토리 —
    /// 외부 코드가 실수로 session.startRunning() 등을 불러 큐 제약을 깨는 것을 차단
    func makePreviewLayer() -> AVCaptureVideoPreviewLayer {
        AVCaptureVideoPreviewLayer(session: session)
    }

    /// 카메라 프레임 수신 핸들러 등록 (Vision 분석·녹화 합성의 공통 입구).
    /// videoOutputQueue에서 호출되므로 수신 측이 무거운 작업을 해도 세션은 멈추지 않는다
    func setFrameHandler(_ handler: (@Sendable (CMSampleBuffer) -> Void)?) {
        frameDelegate.setHandler(handler)
    }

    /// 카메라 권한 요청. 최초 1회는 시스템 다이얼로그, 이후는 저장된 상태 반환
    static func requestAccess() async -> Bool {
        await AVCaptureDevice.requestAccess(for: .video)
    }

    deinit {
        for observer in observers {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    // MARK: - 시작/중지 (의도 변경은 여기서만)

    func start() {
        sessionQueue.async { [self] in
            isActive = true
            startLocked()
        }
    }

    func stop() {
        sessionQueue.async { [self] in
            isActive = false
            isRecovering = false
            if session.isRunning {
                session.stopRunning()
            }
        }
    }

    /// 구성 + 시작의 실제 구현. sessionQueue에서만 호출할 것.
    ///
    /// 설계 근거: 시작/복구의 최종 성공·실패는 "이 함수 하나"만이 확정한다.
    /// 판정 지점을 한 곳으로 좁혀야 뒤늦게 도착한 성공 이벤트가
    /// 방금 발행된 실패 이벤트를 덮어쓰는 순서 역전이 구조적으로 불가능해진다
    private func startLocked() {
        // 진입 시 무조건 리셋 — 어떤 경로(조기 return 포함)로 끝나든
        // isRecovering이 true로 고착되는 회귀를 구조적으로 차단
        isRecovering = false
        if !isConfigured {
            do {
                try configure()
                isConfigured = true
            } catch let error as CameraServiceError {
                onEvent?(.failed(error))
                return
            } catch {
                onEvent?(.failed(.configurationFailed))
                return
            }
        }
        if !session.isRunning {
            session.startRunning()
        }
        // startRunning()은 리턴값도 throw도 없는 fire-and-forget —
        // 성공/실패 판정은 호출 직후 isRunning 확인으로만 가능하다.
        // 실패는 진입 경로(최초 시작/자동 복구/수동 재시도)와 무관하게 항상 보고 —
        // 조건을 걸면 그 조건이 안 걸린 경로에서 "침묵하는 실패"가 재발한다
        if session.isRunning {
            onEvent?(.running)
        } else {
            onEvent?(.failed(.runtimeError))
        }
    }

    /// 전면 카메라 입력 구성. sessionQueue에서만 호출할 것
    private func configure() throws {
        session.beginConfiguration()

        // 구성 도중 어느 단계에서 실패하든 이미 추가된 입출력을 전부 되돌린다.
        //
        // 실패 지점마다 롤백을 손으로 적으면 단계가 늘어날 때마다 누락이 생긴다
        // (실제로 입력 롤백을 추가한 뒤 출력 롤백을 빠뜨려 같은 버그가 재발했다).
        // 세션에 남은 입출력은 재시도 시 canAdd~ 실패로 이어져 영구 고장이 된다.
        // #6에서 오디오 입력·녹화 출력이 추가되어도 이 방식은 그대로 유효하다
        var isComplete = false
        defer {
            if !isComplete { removeAllInputsAndOutputs() }
            // begin/commit 짝은 성공·실패 어느 경로로도 보장되어야 한다
            session.commitConfiguration()
        }

        // 프리셋이 아니라 포맷을 직접 고른다.
        //
        // `.high`는 전면 카메라에서 16:9(1920×1080)를 준다. 그런데 화면은 약 9:19.5라
        // aspectFill이 **좌우를 잘라낸다** — Vision이 화면 밖으로 보는 여유가
        // 한쪽 11%밖에 안 됐다. 손을 옆으로 뻗으면 그립 판정에 필요한 관절이
        // 먼저 프레임을 벗어나 판정이 통째로 불가능해진다 (2026-08-31 실기기, #26).
        //
        // 4:3 포맷은 같은 화면에 대해 좌우 여유를 세 배 가까이 늘린다.
        // 프리뷰는 지금처럼 잘라서 보여주므로 **사용자가 보는 화면은 그대로이고
        // 인식 범위만 넓어진다.**
        //
        // 녹화(#6)에도 유리하다 — 넓게 담아 두고 내보낼 때 잘라내면 되기 때문이다.
        // 합성을 내보내기 시점으로 미룬 구조라 원본은 넓을수록 좋다
        session.sessionPreset = .inputPriority

        guard let device = AVCaptureDevice.default(
            .builtInWideAngleCamera, for: .video, position: .front
        ) else {
            throw CameraServiceError.deviceUnavailable
        }

        let input = try AVCaptureDeviceInput(device: device)
        guard session.canAddInput(input) else {
            throw CameraServiceError.configurationFailed
        }
        session.addInput(input)

        // 프레임 출력: Vision 분석과 (이후) 녹화 합성이 공유하는 통로.
        // alwaysDiscardsLateVideoFrames — 처리가 밀리면 오래된 프레임을 버린다.
        // 실시간 인터랙션에서는 "밀린 과거 프레임"보다 "최신 프레임"이 항상 옳다
        videoOutput.alwaysDiscardsLateVideoFrames = true
        videoOutput.setSampleBufferDelegate(frameDelegate, queue: videoOutputQueue)
        // 출력 추가 실패를 침묵시키지 않는다 — 조용히 넘어가면 세션은 .running을 발행하지만
        // 프레임이 오지 않아 손 인식만 영구히 죽는다. 원인 추적이 불가능해지는 전형적인 케이스.
        // 실패 시 입력도 되돌려야 재시도가 canAddInput == false로 굳지 않는다
        guard session.canAddOutput(videoOutput) else {
            throw CameraServiceError.configurationFailed
        }
        session.addOutput(videoOutput)

        // 고정 30fps: AVAssetWriter 프레임 합성 시 타임스탬프가 예측 가능해야
        // 인코딩이 안정적이다. 가변 프레임레이트면 합성 타이밍이 흔들린다 (#6 선행 조건).
        //
        // 반드시 addInput 이후에 설정 — addInput이 프리셋에 맞춰 activeFormat과
        // frame duration을 재설정할 수 있어, 먼저 설정하면 조용히 무효화되고
        // 검사 대상 포맷도 실제 세션 포맷과 달라진다.
        // 설정 실패 시 추가한 input을 명시적으로 롤백해 재시도 영구 실패를 막는다.
        //
        // 지원 범위 검증: 미지원 프레임 간격 대입은 Swift do/catch로 잡을 수 없는
        // ObjC 예외로 즉사한다. iOS 26 기기(iPhone 11+)의 기본 포맷은 전부 30fps를
        // 지원하므로 지금은 이론적 방어지만, #6에서 포맷을 직접 고르면 실효적이 된다
        do {
            try device.lockForConfiguration()
            defer { device.unlockForConfiguration() }

            // 넓은 화각의 4:3 포맷으로 교체. 못 찾으면 세션이 고른 포맷을 그대로 쓴다 —
            // 화각이 좁아질 뿐 동작은 하므로 실패로 취급하지 않는다
            if let format = Self.preferredWideFormat(for: device) {
                device.activeFormat = format
            }

            // 반드시 activeFormat 이후에 설정 — 포맷을 바꾸면 frame duration이
            // 그 포맷의 기본값으로 초기화되므로, 먼저 설정하면 조용히 덮어써진다.
            // 지원 범위 검증: 미지원 프레임 간격 대입은 Swift do/catch로 잡을 수 없는
            // ObjC 예외로 즉사한다
            let supports30fps = device.activeFormat.videoSupportedFrameRateRanges.contains {
                ($0.minFrameRate...$0.maxFrameRate).contains(30)
            }
            if supports30fps {
                device.activeVideoMinFrameDuration = Self.targetFrameDuration
                device.activeVideoMaxFrameDuration = Self.targetFrameDuration
            }
        } catch {
            session.removeInput(input)
            throw CameraServiceError.configurationFailed
        }

        registerSessionObservers()
        isComplete = true
    }

    /// 목표 프레임 간격 (30fps)
    private static let targetFrameDuration = CMTime(value: 1, timescale: 30)

    /// 손 추적에 쓸 넓은 화각 포맷을 고른다.
    ///
    /// 고르는 기준이 "가장 고화질"이 아닌 이유:
    /// - **4:3에 가까울수록** 좋다. 세로 화면은 좌우가 잘리므로 가로 여유가 곧 인식 범위다
    /// - **너무 크면 안 된다.** Vision 처리 시간은 픽셀 수에 비례하는데 이미 프레임 예산의
    ///   절반(17ms/33ms)을 쓰고 있다. 1080 안팎이면 인식에 충분하다
    /// - 30fps를 지원해야 한다 — 고정 프레임레이트가 녹화 타임라인의 전제다 (#6)
    private static func preferredWideFormat(for device: AVCaptureDevice) -> AVCaptureDevice.Format? {
        /// 세로 길이 상한. 이보다 크면 화질보다 Vision 부하가 먼저 문제가 된다
        let maximumHeight: Int32 = 1200
        /// 4:3(1.333)로 인정할 범위. 기기마다 미세하게 다른 값을 쓴다
        let targetAspectRatio: Double = 4.0 / 3.0
        let aspectTolerance: Double = 0.05

        return device.formats
            .filter { format in
                let dimensions = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
                guard dimensions.height <= maximumHeight, dimensions.height > 0 else { return false }

                let ratio = Double(dimensions.width) / Double(dimensions.height)
                guard abs(ratio - targetAspectRatio) <= aspectTolerance else { return false }

                return format.videoSupportedFrameRateRanges.contains {
                    ($0.minFrameRate...$0.maxFrameRate).contains(30)
                }
            }
            // 조건을 만족하는 것 중에서는 가장 큰 것 — 상한 안에서는 해상도가 높을수록
            // 관절 위치가 정확하다
            .max { lhs, rhs in
                CMVideoFormatDescriptionGetDimensions(lhs.formatDescription).height
                    < CMVideoFormatDescriptionGetDimensions(rhs.formatDescription).height
            }
    }

    /// 구성 실패 롤백. beginConfiguration 블록 안에서만 호출할 것
    private func removeAllInputsAndOutputs() {
        for output in session.outputs { session.removeOutput(output) }
        for input in session.inputs { session.removeInput(input) }
    }

    // MARK: - 세션 인터럽션/에러 대응
    // 전화 수신·다른 앱의 카메라 선점·미디어 서비스 리셋 시 세션은 "조용히" 멈춘다.
    // 관찰하지 않으면 검은 화면만 남으므로 반드시 감지해야 함.
    // 모든 자동 복구 경로는 isActive(의도)를 확인한 뒤에만 움직인다

    private func registerSessionObservers() {
        let center = NotificationCenter.default

        // 인터럽션 시작: 이유(reason)를 반드시 구분한다.
        // 백그라운드 전환은 카메라 앱의 "정상 흐름"이라 이벤트조차 쏘지 않는다
        // (인터럽션 ≠ 에러 — 복구 가능한 중단과 사용자 개입이 필요한 실패는 다른 개념)
        observers.append(center.addObserver(
            forName: AVCaptureSession.wasInterruptedNotification,
            object: session, queue: nil
        ) { [weak self] notification in
            guard let rawReason = notification.userInfo?[AVCaptureSessionInterruptionReasonKey] as? Int,
                  let reason = AVCaptureSession.InterruptionReason(rawValue: rawReason) else {
                return
            }
            switch reason {
            case .videoDeviceNotAvailableInBackground:
                // 홈 화면 이동 등 — interruptionEnded가 자동 복구하므로 침묵
                return
            default:
                // 전화 수신, 다른 앱의 카메라 선점, 시스템 과부하 등
                self?.emitIfActive(.interrupted)
            }
        })

        // 인터럽션 종료: 화면이 살아있을 때만 자동 재시작 →
        // 성공 시 startLocked()가 .running을 발행해 "일시 중단" 배너가 자동 해제된다
        observers.append(center.addObserver(
            forName: AVCaptureSession.interruptionEndedNotification,
            object: session, queue: nil
        ) { [weak self] _ in
            self?.restartIfActive()
        })

        // 런타임 에러: 미디어 서비스 리셋은 "사용자가 고칠 수 없는 문제"이므로
        // 묻지 않고 1회 자동 재시작을 먼저 시도한다.
        // 최종 성공/실패 판정은 startLocked()에 위임 — 여기서 .failed를 직접
        // 발행하지 않아야 이벤트 순서 역전이 원천 차단된다
        observers.append(center.addObserver(
            forName: AVCaptureSession.runtimeErrorNotification,
            object: session, queue: nil
        ) { [weak self] notification in
            guard let self else { return }
            let avError = notification.userInfo?[AVCaptureSessionErrorKey] as? AVError
            sessionQueue.async { [self] in
                guard isActive else { return }
                if avError?.code == .mediaServicesWereReset {
                    guard !isRecovering else { return }  // 이미 복구 시도 중 — 중복 무시
                    isRecovering = true
                    startLocked()
                } else {
                    onEvent?(.failed(.runtimeError))
                }
            }
        })
    }

    /// 노티피케이션은 임의 스레드에서 배달되므로 sessionQueue로 홉.
    /// 화면을 떠난 뒤(isActive == false)의 이벤트는 무의미하므로 버린다
    private func emitIfActive(_ event: CameraEvent) {
        sessionQueue.async { [self] in
            guard isActive else { return }
            onEvent?(event)
        }
    }

    private func restartIfActive() {
        sessionQueue.async { [self] in
            guard isActive else { return }
            startLocked()
        }
    }
}

/// 프레임 델리게이트.
///
/// 별도 클래스인 이유: AVCaptureVideoDataOutputSampleBufferDelegate는 NSObject를 요구하는데,
/// CameraService를 NSObject로 만들면 Swift 6 동시성 모델과 충돌한다.
/// 델리게이트 역할만 떼어내면 CameraService는 순수 Swift 타입으로 남는다.
nonisolated private final class FrameDelegate: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate, @unchecked Sendable {

    private let lock = NSLock()
    private var handler: (@Sendable (CMSampleBuffer) -> Void)?

    /// 핸들러는 메인 스레드에서 등록되고 videoOutputQueue에서 읽히므로 락으로 보호.
    /// (CameraService처럼 전용 큐로 몰지 않는 이유: 프레임 경로에 큐 홉을 추가하면
    ///  프레임마다 불필요한 디스패치 비용이 생긴다)
    func setHandler(_ handler: (@Sendable (CMSampleBuffer) -> Void)?) {
        lock.withLock { self.handler = handler }
    }

    func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        let handler = lock.withLock { self.handler }
        handler?(sampleBuffer)
    }
}
