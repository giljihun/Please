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
    case white, black, red, yellow, blue

    var id: Self { self }

    /// VoiceOver용 이름 — 색상 버튼이 시각 정보(Circle)뿐이면 구분 불가
    var name: String {
        switch self {
        case .white: "흰색"
        case .black: "검정"
        case .red: "빨강"
        case .yellow: "노랑"
        case .blue: "파랑"
        }
    }

    var color: Color {
        switch self {
        case .white: .white
        case .black: .black
        case .red: .red
        case .yellow: .yellow
        case .blue: .blue
        }
    }

    var uiColor: UIColor {
        switch self {
        case .white: .white
        case .black: .black
        case .red: .systemRed
        case .yellow: .systemYellow
        case .blue: .systemBlue
        }
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

    var penColor: PenColor = .white
    var penWidth: CGFloat = 6

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
