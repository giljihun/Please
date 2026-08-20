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
        // defer: 성공/실패 어느 경로로 빠져도 commit이 보장됨 (begin/commit 짝 맞추기)
        defer { session.commitConfiguration() }

        session.sessionPreset = .high

        guard let device = AVCaptureDevice.default(
            .builtInWideAngleCamera, for: .video, position: .front
        ) else {
            throw CameraServiceError.deviceUnavailable
        }

        // 고정 30fps: AVAssetWriter 프레임 합성 시 타임스탬프가 예측 가능해야
        // 인코딩이 안정적이다. 가변 프레임레이트면 합성 타이밍이 흔들린다 (#6 선행 조건).
        // throw 가능 구간을 addInput보다 앞에 둔다 — 입력 추가 후 실패하면
        // 세션에 입력이 남아 재시도가 영구 실패(canAddInput == false)로 굳는다
        try device.lockForConfiguration()
        device.activeVideoMinFrameDuration = Self.targetFrameDuration
        device.activeVideoMaxFrameDuration = Self.targetFrameDuration
        device.unlockForConfiguration()

        let input = try AVCaptureDeviceInput(device: device)
        guard session.canAddInput(input) else {
            throw CameraServiceError.configurationFailed
        }
        session.addInput(input)

        registerSessionObservers()
    }

    /// 목표 프레임 간격 (30fps)
    private static let targetFrameDuration = CMTime(value: 1, timescale: 30)

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
