# Please!

화면에 사인하면 렌즈에 새기는 듯한 경험을 선사하는 iOS 앱.

팬이 셀럽/선수에게 사인을 받는 순간을 스마트폰만으로 재현합니다.
이름은 르브론 제임스가 "please"라고 외친 어린 팬을 위해 멈춰선 일화에서.

## 요구사항

iOS 26+ · Xcode 26 · Swift 6

## 설계 결정

| 결정 | 이유 |
|---|---|
| 세션 화면만 UIKit, 나머지는 SwiftUI | `coalesced`/`predictedTouches` 드로잉 품질은 UIKit 터치 이벤트에서만 |
| 드로잉은 커스텀 캔버스 (PencilKit ✗) | 입력을 점 시퀀스로 추상화해야 Vision 손 좌표도 같은 경로로 주입 |
| 녹화는 화면 캡처 ✗, 프레임 합성 | UI 요소를 결과물에서 제외해야 함 (AVAssetWriter) |
| SwiftUI ↔ UIKit은 공유 `@Observable` | 양쪽이 같은 상태를 보는 문제 → 이벤트 전달이 아닌 상태 관찰 |
| 저장은 앱 Documents + SwiftData | 랜덤 한글 이름·썸네일 등 메타데이터가 필요 |

근거 상세는 [PLANNING.md](PLANNING.md).

## 구조

```
App/           앱 진입점
Presentation/  화면 (SwiftUI + MVVM)
Core/          Capture · Drawing (UIKit)
Resources/     Assets
```

## 현황

PoC 검증 단계 — 카메라 프리뷰 + 터치 드로잉 완료, 합성 녹화 진행 예정.
[마일스톤](https://github.com/giljihun/Please/milestones)에서 로드맵 확인.
