//
//  SigningSessionView.swift
//  Please
//
//  Created by 길지훈 on 8/18/26.
//

import SwiftUI

/// UIKit CaptureViewController를 SwiftUI 트리에 얹는 래퍼.
///
/// updateUIViewController가 ViewModel의 관찰 대상 프로퍼티를 읽기 때문에,
/// 값이 바뀔 때마다 SwiftUI가 이 메서드를 다시 불러 UIKit 쪽에 반영된다
/// (SwiftUI → UIKit 단방향 상태 흘려보내기)
private struct CaptureViewRepresentable: UIViewControllerRepresentable {
    let viewModel: SigningSessionViewModel

    func makeUIViewController(context: Context) -> CaptureViewController {
        let controller = CaptureViewController()
        controller.onCameraEvent = { event in
            viewModel.handleCameraEvent(event)
        }
        controller.onHandDetection = { detected, milliseconds in
            viewModel.handleHandDetection(detected: detected, milliseconds: milliseconds)
        }
        return controller
    }

    func updateUIViewController(_ controller: CaptureViewController, context: Context) {
        controller.canvasView.strokeColor = viewModel.penColor.uiColor
        controller.canvasView.strokeWidth = viewModel.penWidth
        controller.isHandOverlayEnabled = viewModel.isHandOverlayEnabled
        controller.isGestureDrawingEnabled = viewModel.isGestureDrawingEnabled

        // 명령 카운터가 바뀌었을 때만 1회 실행 (일회성 명령 패턴)
        if context.coordinator.lastClearSignal != viewModel.clearSignal {
            context.coordinator.lastClearSignal = viewModel.clearSignal
            controller.canvasView.clear()
        }
        if context.coordinator.lastRetrySignal != viewModel.retrySignal {
            context.coordinator.lastRetrySignal = viewModel.retrySignal
            controller.retryCamera()
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    /// 명령 카운터의 "마지막으로 처리한 값"을 기억하는 저장소.
    /// Representable 구조체는 매번 새로 만들어지므로 상태는 Coordinator에 보관해야 함
    final class Coordinator {
        var lastClearSignal = 0
        var lastRetrySignal = 0
    }
}

/// 인식 상태와 처리 시간 — 조명·거리별 성능을 현장에서 바로 읽기 위한 지표.
///
/// 별도 View 구조체로 뺀 이유: @Observable의 변경 추적 단위는 "그 값을 읽은 body"다.
/// 처리 시간은 매 프레임 갱신되므로 부모 body에서 읽으면 화면 전체가 초당 30번
/// 재평가된다. 읽는 곳을 이 작은 뷰로 좁히면 갱신 범위도 여기로 한정된다
private struct VisionStatsView: View {
    let viewModel: SigningSessionViewModel

    var body: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(viewModel.isHandDetected ? .green : .red)
                .frame(width: 8, height: 8)
            Text("\(viewModel.visionMilliseconds, specifier: "%.0f")ms")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.white)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .glassEffect()
    }
}

/// 사인 세션 화면 (PoC: 카메라 프리뷰 + 드로잉 + 펜 도구 오버레이)
struct SigningSessionView: View {
    @State private var viewModel = SigningSessionViewModel()
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL

    /// 마지막으로 닫은 실패 알럿의 세대 번호 (뷰의 표시용 로컬 상태).
    /// 카메라가 죽었다는 "사실"은 VM에 남고, "알럿을 닫았는지"만 여기서 관리 —
    /// 뷰가 cameraStatus를 직접 mutate하면 단일 진실 공급원이 깨진다
    @State private var dismissedFailureCount = 0

    var body: some View {
        ZStack {
            CaptureViewRepresentable(viewModel: viewModel)
                .ignoresSafeArea()

            VStack {
                topBar
                if viewModel.cameraStatus == .interrupted {
                    interruptedBanner
                }
                Spacer()
                penToolbar
            }
        }
        .toolbarVisibility(.hidden, for: .navigationBar)
        .alert("카메라 오류", isPresented: failedAlertBinding) {
            // 권한 거부는 iOS가 다이얼로그를 재표시하지 않으므로
            // "다시 시도"가 무의미 — 유일한 실질 해결책인 설정 이동을 제공
            if case .failed(.permissionDenied) = viewModel.cameraStatus {
                Button("설정으로 이동") {
                    if let url = URL(string: UIApplication.openSettingsURLString) {
                        openURL(url)
                    }
                }
            } else {
                Button("다시 시도") { viewModel.requestCameraRetry() }
            }
            Button("닫기", role: .cancel) {}
        } message: {
            Text(failedMessage)
        }
    }

    /// 새 실패(세대 번호 증가)가 왔을 때만 알럿 표시. 닫으면 해당 세대를 기억해
    /// 같은 실패로는 다시 뜨지 않되, 다음 실패에는 다시 뜬다
    private var failedAlertBinding: Binding<Bool> {
        .init(
            get: {
                if case .failed = viewModel.cameraStatus {
                    viewModel.failureCount > dismissedFailureCount
                } else {
                    false
                }
            },
            set: { isPresented in
                if !isPresented { dismissedFailureCount = viewModel.failureCount }
            }
        )
    }

    private var failedMessage: String {
        if case .failed(let error) = viewModel.cameraStatus { error.userMessage } else { "" }
    }
}

// MARK: - 서브뷰

private extension SigningSessionView {

    /// 상단 바 — 나가기 + 손 인식 디버그 토글
    /// PoC 임시. 본 구현에서 "완료" 버튼으로 대체 예정 (#9), 디버그는 제거 (#19)
    var topBar: some View {
        HStack {
            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark")
                    .font(.title3)
                    .foregroundStyle(.white)
                    .padding(10)
            }
            .glassEffect()
            .accessibilityLabel("세션 나가기")

            Spacer()

            if viewModel.isHandOverlayEnabled || viewModel.isGestureDrawingEnabled {
                VisionStatsView(viewModel: viewModel)
            }

            Button {
                viewModel.isGestureDrawingEnabled.toggle()
            } label: {
                Image(systemName: viewModel.isGestureDrawingEnabled
                      ? "hand.draw.fill" : "hand.draw")
                    .font(.title3)
                    .foregroundStyle(viewModel.isGestureDrawingEnabled ? .green : .white)
                    .padding(10)
            }
            .glassEffect()
            .accessibilityLabel("제스처로 그리기")

            Button {
                viewModel.isHandOverlayEnabled.toggle()
            } label: {
                Image(systemName: viewModel.isHandOverlayEnabled ? "hand.raised.fill" : "hand.raised")
                    .font(.title3)
                    .foregroundStyle(viewModel.isHandOverlayEnabled ? .green : .white)
                    .padding(10)
            }
            .glassEffect()
            .accessibilityLabel("손 인식 표시")
        }
        .padding(.horizontal, 20)
        .padding(.top, 8)
    }

    /// 인터럽션 안내 배너 — 사용자 개입이 불필요한 중단이므로 알럿이 아닌 배너로.
    /// 세션이 복구되면(.running → .active) 자동으로 사라진다
    var interruptedBanner: some View {
        Text("카메라가 잠시 멈췄어요 — 곧 다시 시작됩니다")
            .font(.footnote)
            .foregroundStyle(.white)
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .glassEffect()
            .padding(.top, 8)
    }

    /// 펜 색상 팔레트 + 지우기 버튼
    var penToolbar: some View {
        HStack(spacing: 16) {
            ForEach(PenColor.allCases) { pen in
                Button {
                    viewModel.penColor = pen
                } label: {
                    Circle()
                        .fill(pen.color)
                        .frame(width: 28, height: 28)
                        .overlay {
                            Circle().strokeBorder(
                                .white.opacity(viewModel.penColor == pen ? 1 : 0.3),
                                lineWidth: 2
                            )
                        }
                }
                .accessibilityLabel("\(pen.name) 펜")
                .accessibilityAddTraits(viewModel.penColor == pen ? [.isSelected] : [])
            }

            Divider()
                .frame(height: 24)

            Button {
                viewModel.requestClear()
            } label: {
                Image(systemName: "eraser")
                    .font(.title3)
                    .foregroundStyle(.white)
            }
            .accessibilityLabel("전체 지우기")
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .glassEffect()
        .padding(.bottom, 24)
    }
}

#Preview {
    SigningSessionView()
}
