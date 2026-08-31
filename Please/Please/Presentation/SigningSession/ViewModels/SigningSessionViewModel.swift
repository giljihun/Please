//
//  SigningSessionViewModel.swift
//  Please
//
//  Created by 길지훈 on 8/18/26.
//

import SwiftUI

/// 사인에 쓸 수 있는 펜 색상 팔레트.
/// SwiftUI(Color)와 UIKit(UIColor)이 같은 색을 봐야 하므로 양쪽 변환을 함께 제공
enum PenColor: CaseIterable, Identifiable {
    case red, black, white, blue

    var id: Self { self }

    /// VoiceOver용 이름 — 색상 버튼이 시각 정보(Circle)뿐이면 구분 불가
    var name: String {
        switch self {
        case .red: "빨강"
        case .black: "검정"
        case .white: "흰색"
        case .blue: "파랑"
        }
    }

    var color: Color {
        switch self {
        case .red: .red
        case .black: .black
        case .white: .white
        case .blue: .blue
        }
    }

    var uiColor: UIColor {
        switch self {
        case .red: .systemRed
        case .black: .black
        case .white: .white
        case .blue: .systemBlue
        }
    }
}

/// 사인 입력 방식.
///
/// Bool이 아닌 enum인 이유: 기본값이 규칙을 표현해야 하기 때문이다.
/// `isGestureDrawingEnabled = false`는 "기본이 터치"라고 읽히는데,
/// 제품 규칙은 정반대다 — 제스처가 기본이고 터치는 폴백이다 (CLAUDE.md 제품 규칙).
/// 타입에 박아두면 나중에 읽는 사람이 이름에 의존해 추측할 일이 없다
enum InputMode: CaseIterable {
    /// 기본. 카메라 앞 공중 제스처
    case gesture
    /// 폴백. 조명 불량·인식 실패 시 사용자가 직접 전환한다 (자동 전환은 만들지 않는다)
    case touch

    /// VoiceOver용 이름 — 버튼이 아이콘뿐이라 없으면 구분 불가.
    /// "화면에 사인"이라 하지 않는다: 사인하는 행위가 아니라 입력 방식을 가리킨다
    var name: String {
        switch self {
        case .gesture: "공중에서 그리기"
        case .touch: "손끝으로 그리기"
        }
    }

    var symbolName: String {
        switch self {
        case .gesture: "hand.draw.fill"
        case .touch: "hand.point.up.left.fill"
        }
    }

    var toggled: InputMode {
        self == .gesture ? .touch : .gesture
    }
}

/// 사인 세션 화면의 단일 진실 공급원(Single Source of Truth).
///
/// 설계 근거: SwiftUI 오버레이(펜 도구)와 UIKit 캡처 코어가 같은 상태를
/// 동시에 봐야 하므로, 델리게이트(이벤트 전달)가 아닌 공유 @Observable
/// 객체(상태 관찰)를 채택했다. (PLANNING.md 5장 통신 방식 결정 참고)
@Observable
final class SigningSessionViewModel {

    // MARK: - 펜 설정 (SwiftUI 툴바 ↔ UIKit 캔버스 공유)

    // 실제 렌즈 사인은 굵은 마커(매직)로 이뤄지지만, 공중 제스처는 팔 전체로 쓰는
    // 동작이라 화면상 획이 짧다. 16pt는 글자가 뭉개져 8pt로 낮췄었다 (2026-08-26 실기기).
    // 곡선 스무딩과 반투명 잉크가 들어간 뒤 12pt로 올린다 — 각짐과 불투명함이
    // 사라지면서 굵어도 뭉개지지 않게 됐다. 실기기에서 재조율 대상 (#18)
    var penColor: PenColor = .red
    var penWidth: CGFloat = 12

    // MARK: - 입력 방식

    /// 무엇을 "펜을 쥔 것"으로 볼지 (#26 개발용 비교).
    /// 세 손가락과 손하트 중 어느 쪽이 실사용에서 나은지는 계산으로 알 수 없어
    /// 실기기에서 나란히 써보고 정한다. 확정되면 하나만 남기고 이 토글은 사라진다
    var gripMode: GripMode = .threeFinger

    /// 기본값이 곧 제품 규칙이다 — 제스처가 기본, 터치는 사용자가 직접 고르는 폴백
    var inputMode: InputMode = .gesture {
        didSet {
            // 터치로 넘어갈 때 스켈레톤을 끈다. 켜둔 채로 넘어가면 Vision이 계속
            // 도는데 화면에는 아무것도 안 보인다 — 보이지도 않는 분석에 배터리를 쓴다
            if inputMode == .touch { isHandOverlayEnabled = false }
        }
    }

    // MARK: - 명령 신호
    // "지우기/재시도"는 상태가 아닌 일회성 명령이라, 값 증가를 신호로 쓰는 카운터 방식 채택.
    // updateUIViewController가 이전 값과 비교해 변화를 감지한다

    private(set) var clearSignal = 0
    private(set) var retrySignal = 0

    func requestClear() {
        clearSignal += 1
    }

    func requestCameraRetry() {
        retrySignal += 1
    }

    // MARK: - 손 인식 검증 (#19 개발용)
    // 인식 실패 원인을 눈으로 구분하기 위한 지표. 검증이 끝나면 제거하거나
    // 개발자 설정 뒤로 숨긴다

    var isHandOverlayEnabled = false

    private(set) var isHandDetected = false
    private(set) var visionMilliseconds: Double = 0

    // MARK: - 추적 유실 계측 (#26 개발용)
    // "펜이 사라졌다"는 같은 현상이라도 원인마다 고칠 곳이 다르다.
    // 실기기에서 어느 사유가 지배적인지 세어 보고 대응을 고른다

    /// 가장 최근 유실 사유 (짧은 한글 이름)
    private(set) var lastLossLabel: String?

    /// 상위 3개 사유와 횟수 — 화면이 좁으므로 지배적인 것만 보여준다
    private(set) var lossSummary = ""

    /// 검지 끝 신뢰도. nil이면 관절 자체가 없다는 뜻이라 카메라 문제,
    /// 값이 있는데 낮으면 임계값으로 회수 가능하다는 뜻이다
    private(set) var penTipConfidence: Float?

    /// 그립 비율. **무엇을 잰 값인지는 `gripMode`에 따라 다르다** —
    /// 세 손가락은 끝점 간 최대 거리를, 손하트는 엄지와 검지 마디 사이 거리를 잰다.
    /// 문턱값을 실기기에서 정하려면 지금 값이 얼마인지 눈으로 봐야 한다 —
    /// 진입·이탈 문턱은 전부 이 숫자를 재서 정한다
    private(set) var gripRatio: CGFloat?

    func handleTrackingDiagnostics(_ feedback: GestureDrawingController.Feedback) {
        lastLossLabel = feedback.lastLoss?.shortLabel
        penTipConfidence = feedback.penTipConfidence
        gripRatio = feedback.gripRatio
        lossSummary = feedback.lossCounts
            .sorted { $0.value > $1.value }
            .prefix(3)
            .map { "\($0.key.shortLabel) \($0.value)" }
            .joined(separator: "  ")
    }

    func handleHandDetection(detected: Bool, milliseconds: Double) {
        isHandDetected = detected
        // 프레임마다 값이 튀면 읽기 어려우므로 이동평균으로 완만하게 (표시용)
        visionMilliseconds = visionMilliseconds == 0
            ? milliseconds
            : visionMilliseconds * 0.8 + milliseconds * 0.2
    }

    // MARK: - 카메라 상태
    // CameraEvent(코어의 사실)를 UI 상태(화면의 표현)로 번역하는 것이 VM의 역할.
    // cameraStatus는 오직 CameraEvent만이 바꾼다 (단일 진실 공급원) —
    // 뷰는 이 값을 절대 직접 수정하지 않고, "알럿을 닫았는지"만 자체 관리한다

    enum CameraStatus: Equatable {
        case active
        case interrupted                  // 상단 배너로 표시 (알럿 아님 — 사용자 개입 불필요)
        case failed(CameraServiceError)   // 알럿 표시 — 원본 에러 타입을 보존해야
                                          // 뷰가 케이스별 복구 동선(설정 이동/재시도)을 분기할 수 있다
    }

    private(set) var cameraStatus: CameraStatus = .active

    /// 실패 이벤트의 세대 번호. 뷰가 "마지막으로 닫은 알럿"과 비교해
    /// 새 실패가 오면 알럿을 다시 띄울 수 있게 한다
    private(set) var failureCount = 0

    func handleCameraEvent(_ event: CameraEvent) {
        // 같은 상태로의 재대입은 생략 — @Observable은 동일 값 재할당에도 변경을
        // 통지하므로, 걸러주지 않으면 불필요한 뷰 재평가가 발생한다.
        // 단 failureCount는 "같은 실패의 반복"도 새 세대로 세야 알럿이 다시 뜬다
        switch event {
        case .running:
            if cameraStatus != .active { cameraStatus = .active }
        case .interrupted:
            if cameraStatus != .interrupted { cameraStatus = .interrupted }
        case .failed(let error):
            failureCount += 1
            if cameraStatus != .failed(error) { cameraStatus = .failed(error) }
        }
    }
}
