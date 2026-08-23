# Please! — 개발 설계 문서 (v0.1)

## 1. 컨셉 요약
- 실제 팬 문화인 "카메라 렌즈 사인"을 스마트폰으로 재현
- **기본 입력은 카메라 앞 공중 제스처** (터치는 폴백) — 2026-08-23 실기기 검증 결과 반영
- 네이밍 유래: 르브론 제임스가 "please"라고 말한 어린 팬을 위해 멈춰준 일화
- 타깃: K-pop 팬, 스포츠 팬, 콘서트 관객, 콘텐츠 크리에이터 (글로벌)
- 직접 경쟁자 없음

## 2. 화면 인벤토리 (화면 → 필요 기술 → 선택 기술)

| # | 화면 | 필요 기술 | 선택 기술 |
|---|------|----------|----------|
| 1 | 온보딩 / 권한 요청 | AVCaptureDevice.requestAccess, PHPhotoLibrary 권한 플로우 | SwiftUI |
| 2 | 홈 (세션 시작, 모드 선택) | 단순 네비게이션 | SwiftUI |
| 3 | 사인 세션 화면 ★핵심 | AVCaptureVideoPreviewLayer, touchesMoved + coalesced/predictedTouches 드로잉, VNDetectHumanHandPoseRequest 손 추적, AVAssetWriter 프레임 합성 녹화, 카운트다운 오버레이 | UIKit 코어 + SwiftUI 래퍼(UIViewControllerRepresentable), 펜 도구/완료 버튼 오버레이는 SwiftUI |
| 4 | 세션 완료 / 미리보기 | AVPlayer 재생, 랜덤 한글 파일명 생성, 저장/재촬영 분기 | SwiftUI + VideoPlayer |
| 5 | 라이브러리 (보관함) | 그리드 목록, AVAssetImageGenerator 썸네일, 메타데이터 저장 | SwiftUI(LazyVGrid) + SwiftData |
| 6 | 영상 상세 / 재생 | 재생, 프레임 캡처, 공유 시트, AVMutableVideoComposition 워터마크 합성 | SwiftUI + AVFoundation |
| 7 | 편집 화면 | AVAssetExportSession 트리밍, 파일명 변경 | SwiftUI + AVFoundation |

### 독립 화면이 아닌 것
- 카운트다운 → 3번 화면의 오버레이 상태
- 펜 커스터마이징(종류/색/굵기) → 3번 화면의 툴바/시트
- 설정 화면 → v0.1 스코프에서 생략 (설정할 항목 아직 없음)

### 화면 플로우
온보딩(최초 1회) → 홈 → 세션(3) → 미리보기(4) → 라이브러리(5) → 상세(6) → 편집(7)

## 3. 모듈 구조

```
App (SwiftUI)
├── 온보딩 / 홈 / 라이브러리 / 상세 / 편집 → 순수 SwiftUI
└── SigningSessionView (SwiftUI 래퍼)
     └── UIViewControllerRepresentable
          └── CaptureViewController (UIKit)
               ├── AVCaptureVideoPreviewLayer (전면 카메라)
               ├── DrawingCanvasView (custom UIView)
               └── Vision 좌표 → 캔버스 브릿지
```

## 4. 기술 리스크 및 개발 우선순위
- 공수의 절반 이상이 3번(사인 세션 화면)에 집중됨
- 최우선 PoC: 카메라 프레임 + 드로잉 레이어 합성 녹화 (AVAssetWriter)
- 두 번째 난이도: 6번의 워터마크 합성
- Vision 손 추적 좌표는 스무딩(이동평균/칼만 필터) 필수 — 없으면 선이 떨림

## 5. 기술 결정 사항 (2026-08-18 확정, 이슈 #4)
- [x] **SwiftUI ↔ UIKit 통신: 공유 `@Observable` ViewModel 주입**
  - 세션 화면은 SwiftUI 오버레이와 UIKit 캡처 코어가 같은 상태(펜 설정, 녹화 상태)를 동시에 봐야 함 → 이벤트 전달(델리게이트)이 아닌 상태 관찰 문제. 단일 진실 공급원 확보
  - 델리게이트는 캡처 코어 내부 컴포넌트 간 통신에만 사용
- [x] **드로잉 엔진: UIBezierPath 커스텀 캔버스** (PencilKit 탈락)
  - PKCanvasView는 터치 이벤트 전용이라 Vision 손 좌표 주입 불가 → 입력을 "점 시퀀스"로 추상화해 터치/제스처 모드 동일 처리
  - CGPath를 직접 보유하므로 녹화 합성 시 프레임 단위 렌더링 완전 제어
- [x] **저장 위치: 앱 Documents + SwiftData 메타데이터**
  - 라이브러리 요구사항(랜덤 한글 이름, 썸네일, 보관함)이 메타데이터를 전제. 사진 앱 저장은 미리보기/상세의 명시적 버튼으로만 (Add-only 권한 유지)
- [ ] **합성 파이프라인: Core Image(CIContext) 잠정** — PoC(#6)에서 1080p/30fps 실측 후 확정, 프레임 드랍 시 Metal 전환

## 6. 개발 착수 순서 (제안)
1. ~~Xcode 프로젝트 셋업~~ ✅
2. ~~PoC: 전면 카메라 프리뷰 + 터치 드로잉 오버레이~~ ✅ (터치는 폴백 입력으로 유지)
3. **PoC: Vision 제스처 입력** ← 순서 변경. 기본 입력이 확정돼야 녹화 대상 구도가 정해진다
4. PoC: 프리뷰+드로잉 합성 AVAssetWriter 녹화
5. 세션 플로우 완성 (카운트다운, 완료, 파일명 생성)
6. 라이브러리/상세/공유
7. 편집, 워터마크 내보내기
