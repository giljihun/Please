//
//  DiagnosticsOverlay.swift
//  Please
//
//  Created by 길지훈 on 8/26/26.
//

import SwiftUI

/// 개발용 진단 표시 묶음 (#19, #26).
///
/// 한 곳에 모아둔 이유: 제품 화면과 개발 도구가 섞여 있으면 "지금 보이는 것 중
/// 무엇이 실제 UI인지" 판단할 수 없다. 세션 화면에서는 이 뷰 한 줄만 얹고,
/// 그 줄을 지우면 제품 화면만 남는다.
///
/// 여기 있는 것은 전부 임시다 — #9에서 세션 화면을 본 구현으로 정리할 때 제거한다.
/// 입력 방식 전환은 제품 기능이므로 여기 두지 않는다 (상단 바에 있다).
struct DiagnosticsOverlay: View {
    let viewModel: SigningSessionViewModel

    var body: some View {
        // 손 추적 진단은 제스처 모드에서만 의미가 있다.
        // 터치 폴백에서 제스처가 왜 실패했는지 보고 싶으면 모드를 되돌려 보면 된다
        if viewModel.inputMode == .gesture {
            VStack(alignment: .trailing, spacing: 8) {
                HStack(spacing: 8) {
                    VisionStatsView(viewModel: viewModel)
                    skeletonToggle
                }
                TrackingLossView(viewModel: viewModel)
            }
        }
    }

    /// 스켈레톤은 켜고 끌 수 있어야 한다 — 뼈대가 화면을 덮으면 정작 사인 선의
    /// 품질을 볼 수 없고, 반대로 선이 이상할 때는 뼈대를 봐야 원인을 안다
    private var skeletonToggle: some View {
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

/// 추적 유실 계측 표시 (#26). 관찰 범위를 좁히는 이유는 VisionStatsView와 같다
private struct TrackingLossView: View {
    let viewModel: SigningSessionViewModel

    var body: some View {
        VStack(alignment: .trailing, spacing: 2) {
            HStack(spacing: 6) {
                Text(viewModel.lastLossLabel ?? "정상")
                    .foregroundStyle(viewModel.lastLossLabel == nil ? .green : .orange)
                if let confidence = viewModel.penTipConfidence {
                    Text("검지 \(confidence, specifier: "%.2f")")
                        .foregroundStyle(.white.opacity(0.8))
                } else {
                    Text("검지 —")
                        .foregroundStyle(.red.opacity(0.9))
                }
            }
            // 문턱값은 전부 이 숫자를 실기기에서 재서 정했다.
            // 판정 방식이 바뀌면 값의 범위도 바뀌므로 다시 보여줘야 한다
            if let ratio = viewModel.gripRatio {
                Text("그립 \(ratio, specifier: "%.2f")")
                    .foregroundStyle(.cyan)
            } else {
                Text("그립 —")
                    .foregroundStyle(.red.opacity(0.9))
            }
            if !viewModel.lossSummary.isEmpty {
                Text(viewModel.lossSummary)
                    .foregroundStyle(.white.opacity(0.7))
            }
        }
        .font(.caption2.monospacedDigit())
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .glassEffect()
    }
}
