//
//  InkStrokeLayer.swift
//  Please
//
//  Created by 길지훈 on 8/31/26.
//

import UIKit

/// 마커 잉크 한 획을 그리는 레이어.
///
/// 실제 렌즈 사인은 "화면 위에 그려진 선"이 아니라 **"유리 표면에 얹힌 잉크"** 다.
/// 그 차이를 만드는 것이 넷이다.
///
/// 1. **반투명** — 잉크 너머로 뒤가 살짝 비친다
/// 2. **곱하기 합성** — 아래 영상의 밝기에 반응한다. 불투명한 스티커처럼 떠 보이지 않는다
/// 3. **그림자** — 잉크가 유리 위에 얹힌 두께감
/// 4. **광택** — 획을 따라 흐르는 유리 반사
///
/// 획 하나가 레이어 하나이므로 **한 획 안에서는 겹쳐도 균일하고, 획끼리 겹치면 진해진다.**
/// 실제 마커와 같은 성질이며, 획마다 레이어를 나누는 또 하나의 이유다
/// (기존 이유는 "그린 시점의 스타일 보존" — DrawingCanvasView 참고)
/// `nonisolated`인 이유: 이 프로젝트는 `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`라
/// 선언이 기본적으로 MainActor로 격리된다. 그런데 `CALayer`는 `UIView`와 달리
/// MainActor가 아니어서, 상속한 생성자들과 격리 수준이 어긋나 컴파일되지 않는다.
/// 실제 사용은 캔버스(메인 스레드)에서만 이뤄지므로 격리를 낮춰도 안전하다
nonisolated final class InkStrokeLayer: CALayer {

    /// 잉크의 시각 상수. 실기기에서 조율할 값이므로 한곳에 모은다
    private enum Ink {
        /// 잉크 불투명도. 1.0이면 스티커처럼 떠 보이고, 너무 낮으면 사인이 안 읽힌다
        static let alpha: CGFloat = 0.88
        /// 밝은 잉크(흰 펜)와 어두운 잉크를 가르는 밝기 기준
        static let lightInkThreshold: CGFloat = 0.6

        /// 본선 대비 광택 선의 굵기
        static let highlightWidthRatio: CGFloat = 0.24
        static let highlightAlpha: CGFloat = 0.72
        /// 광택은 빛이 오는 쪽(좌상단)으로 어긋나야 표면처럼 읽힌다.
        /// 굵기에 비례해야 굵은 펜에서도 선 안쪽에 머문다
        static let highlightOffsetRatio: CGFloat = 0.16

        /// 광택 주변의 옅은 번짐. 젖은 잉크의 반사는 경계가 딱 떨어지지 않는다
        static let highlightGlowOpacity: Float = 0.9
        static let highlightGlowRadius: CGFloat = 1.5

        /// 넓고 아주 옅은 2차 반사 — 유리 표면 전체가 빛을 받는 느낌
        static let sheenWidthRatio: CGFloat = 0.55
        static let sheenAlpha: CGFloat = 0.16

        static let shadowOpacity: Float = 0.3
        static let shadowRadius: CGFloat = 2
        static let shadowOffset = CGSize(width: 0, height: 1.5)
    }

    private let ink = CAShapeLayer()
    /// 넓고 옅은 2차 반사 — 잉크 위에 먼저 깔린다
    private let sheen = CAShapeLayer()
    /// 좁고 밝은 1차 반사 — 유리의 하이라이트
    private let highlight = CAShapeLayer()

    var path: CGPath? {
        didSet {
            ink.path = path
            sheen.path = path
            highlight.path = path
        }
    }

    var strokeColor: UIColor = .systemRed {
        didSet {
            guard !strokeColor.isEqual(oldValue) else { return }
            applyStyle()
        }
    }

    var strokeWidth: CGFloat = 12 {
        didSet {
            guard strokeWidth != oldValue else { return }
            applyStyle()
        }
    }

    override init() {
        super.init()
        setup()
    }

    /// CALayer는 애니메이션의 표현 트리를 만들 때 자기 자신을 이 생성자로 복제한다.
    /// 빠뜨리면 복제본에 하위 레이어가 없어 획이 깜빡인다
    override init(layer: Any) {
        super.init(layer: layer)
        if let source = layer as? InkStrokeLayer {
            strokeColor = source.strokeColor
            strokeWidth = source.strokeWidth
        }
        setup()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setup()
    }

    private func setup() {
        // bounds를 비워 두는 이유: CAShapeLayer는 masksToBounds가 꺼져 있으면
        // 자기 크기와 무관하게 path를 그린다. 캔버스 좌표를 그대로 쓸 수 있어
        // 뷰 크기가 바뀌어도 레이아웃을 다시 계산할 필요가 없다
        // 순서가 곧 쌓임 순서다 — 잉크 위에 넓은 반사, 그 위에 밝은 하이라이트
        for shape in [ink, sheen, highlight] {
            shape.fillColor = nil
            shape.lineCap = .round
            shape.lineJoin = .round
            addSublayer(shape)
        }
        applyStyle()
    }

    /// 색과 굵기가 정해진 뒤 잉크·광택의 모든 표현을 다시 맞춘다
    private func applyStyle() {
        ink.strokeColor = strokeColor.withAlphaComponent(Ink.alpha).cgColor
        ink.lineWidth = strokeWidth
        ink.shadowColor = UIColor.black.cgColor
        ink.shadowOpacity = Ink.shadowOpacity
        ink.shadowRadius = Ink.shadowRadius
        ink.shadowOffset = Ink.shadowOffset

        sheen.strokeColor = UIColor.white
            .withAlphaComponent(Ink.sheenAlpha).cgColor
        sheen.lineWidth = strokeWidth * Ink.sheenWidthRatio

        highlight.strokeColor = UIColor.white
            .withAlphaComponent(Ink.highlightAlpha).cgColor
        highlight.lineWidth = strokeWidth * Ink.highlightWidthRatio
        // 젖은 잉크의 반사는 경계가 딱 떨어지지 않는다. 흰 그림자를 얹어 번지게 한다
        highlight.shadowColor = UIColor.white.cgColor
        highlight.shadowOpacity = Ink.highlightGlowOpacity
        highlight.shadowRadius = Ink.highlightGlowRadius
        highlight.shadowOffset = .zero

        // 어긋남을 굵기에 비례시켜야 굵은 펜에서도 반사가 선 안쪽에 머문다.
        // 고정값을 쓰면 12pt에서 맞춘 값이 24pt에서는 선 가운데로 와 버린다
        let offset = strokeWidth * Ink.highlightOffsetRatio
        sheen.position = CGPoint(x: -offset * 0.4, y: -offset * 0.4)
        highlight.position = CGPoint(x: -offset, y: -offset * 1.4)

        // 어두운 잉크에만 곱하기 합성을 건다.
        //
        // 곱하기는 `결과 = 배경 × 잉크`이고 **흰색(1.0)은 곱셈의 항등원**이다.
        // 흰 펜에 곱하기를 걸면 배경 영상이 그대로 통과해 글씨가 사라진다.
        // 반대로 어두운 잉크는 배경을 눌러 "유리에 얹힌 반투명 잉크"로 읽힌다
        ink.compositingFilter = isLightInk ? nil : "multiplyBlendMode"
    }

    /// 흰 펜처럼 밝은 잉크인지. 실패하면 어두운 쪽으로 간주해 합성을 유지한다
    private var isLightInk: Bool {
        var white: CGFloat = 0
        var alpha: CGFloat = 0
        guard strokeColor.getWhite(&white, alpha: &alpha) else { return false }
        return white >= Ink.lightInkThreshold
    }
}
