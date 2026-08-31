//
//  GesturePenFeedbackView.swift
//  Please
//
//  Created by 길지훈 on 8/26/26.
//

import UIKit

/// 공중 제스처의 펜 상태를 검지 끝에 보여주는 오버레이.
///
/// 획만으로 상태를 알리면 사용자는 인식 실패를 **잘못 그어진 뒤에야** 발견한다.
/// 공중 제스처는 터치와 달리 "지금 인식되고 있는지"를 몸이 알 수 없기 때문이다.
/// 따라서 긋기 전에 pinch 상태를 시각으로 먼저 알린다.
///
/// ## 녹화 포함 여부는 상태마다 다르다 (2026-08-31 확정, 이슈 #13)
///
/// - `drawing`의 **펜 본체는 녹화에 포함된다.** 사인하는 도구이므로 UI가 아니라 콘텐츠다 —
///   "UI 요소는 녹화에 넣지 않는다"는 원칙의 유일한 예외
/// - `hover`·`uncertain`의 **링은 제외된다.** 인식 상태를 알리는 진단용 표시일 뿐이다
///
/// 합성(#6)은 화면에 보이는 애니메이션 상태가 아니라 **해당 프레임의 캡처 좌표**로 펜을 그려야 한다.
/// spring 애니메이션은 사람 눈을 위한 표현이지 결과물의 사실이 아니다
final class GesturePenFeedbackView: UIView {

    enum State: Equatable {
        /// 제스처 모드가 꺼졌거나 손을 찾지 못한 상태.
        case hidden
        /// 손은 추적 중이지만 pinch 전. 펜 대신 작은 위치 가이드만 보여준다.
        case hover
        /// pinch가 확정되어 획을 그리고 있는 상태.
        case drawing
        /// 관절 누락 또는 release 대기 때문에 아직 안전하게 그릴 수 없는 상태.
        case uncertain
    }

    private enum Metrics {
        static let markerSize = CGSize(width: 38, height: 54)
        static let markerEdgeMargin: CGFloat = 6
        static let guideDiameter: CGFloat = 12
        static let uncertainDiameter: CGFloat = 22
    }

    private let markerView = MarkerGlyphView(frame: CGRect(origin: .zero, size: Metrics.markerSize))
    private let guideLayer = CAShapeLayer()
    private let uncertainLayer = CAShapeLayer()

    private(set) var state: State = .hidden
    private var renderedState: State = .hidden
    private var lastScreenPoint: CGPoint?
    private var penColor: UIColor = .systemRed
    private var markerBaseTransform = CGAffineTransform.identity

    override init(frame: CGRect) {
        super.init(frame: frame)
        setup()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setup()
    }

    private func setup() {
        backgroundColor = .clear
        isUserInteractionEnabled = false
        isAccessibilityElement = false
        accessibilityElementsHidden = true

        configureRingLayer(guideLayer)
        configureRingLayer(uncertainLayer)
        layer.addSublayer(guideLayer)
        layer.addSublayer(uncertainLayer)

        markerView.bounds = CGRect(origin: .zero, size: Metrics.markerSize)
        // 펜 끝을 좌표에 고정한 채 몸체만 spring으로 움직이게 한다.
        markerView.layer.anchorPoint = CGPoint(x: 0.5, y: 1)
        markerView.isHidden = true
        markerView.isUserInteractionEnabled = false
        addSubview(markerView)

        updateRingPaths()
        updateColors()
        applyHiddenAppearance()
    }

    private func configureRingLayer(_ ring: CAShapeLayer) {
        ring.fillColor = UIColor.clear.cgColor
        ring.lineCap = .round
        ring.isHidden = true
        ring.shadowColor = UIColor.black.cgColor
        ring.shadowOpacity = 0.35
        ring.shadowRadius = 1.5
        ring.shadowOffset = .zero
    }

    /// Vision이 계산한 화면 좌표와 현재 pinch 상태를 반영한다.
    ///
    /// 같은 상태가 프레임마다 들어와도 위치와 색만 갱신하며 pop 애니메이션은 재시작하지 않는다.
    /// `uncertain`에 좌표가 없으면 마지막으로 확인한 좌표를 유지해 추적 불안을 명확히 보여준다.
    func update(state newState: State, screenPoint: CGPoint?, penColor newColor: UIColor) {
        let previousState = renderedState
        let didChangeState = previousState != newState

        if let screenPoint, screenPoint.x.isFinite, screenPoint.y.isFinite {
            lastScreenPoint = screenPoint
        }
        if !penColor.isEqual(newColor) {
            penColor = newColor
            updateColors()
        }

        state = newState

        guard newState != .hidden, let point = lastScreenPoint else {
            applyHiddenAppearance()
            if newState == .hidden {
                lastScreenPoint = nil
                renderedState = .hidden
            }
            return
        }

        positionFeedback(at: point)

        guard didChangeState else { return }
        renderedState = newState

        switch newState {
        case .hidden:
            applyHiddenAppearance()
        case .hover:
            applyHoverAppearance()
        case .drawing:
            applyDrawingAppearance(animated: previousState != .drawing)
        case .uncertain:
            applyUncertainAppearance()
        }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        guard state != .hidden, let lastScreenPoint else { return }
        positionFeedback(at: lastScreenPoint)
    }

    private func positionFeedback(at point: CGPoint) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        guideLayer.position = point
        uncertainLayer.position = point
        markerView.layer.position = point
        CATransaction.commit()

        let updatedTransform = markerTransform(at: point)
        guard updatedTransform != markerBaseTransform else { return }
        markerBaseTransform = updatedTransform

        // 가장자리에서 방향이 바뀌더라도 매 프레임 animation을 만들지 않는다.
        UIView.performWithoutAnimation {
            markerView.transform = markerBaseTransform
        }
    }

    /// 펜 끝 좌표는 움직이지 않고, 화면 가장자리에 따라 몸체가 뻗는 방향만 바꾼다.
    /// 상단에서는 아래로 뒤집고 좌우에서는 안쪽으로 기울여 작은 화면에서도 잘리지 않게 한다.
    private func markerTransform(at point: CGPoint) -> CGAffineTransform {
        let margin = Metrics.markerSize.width / 2 + Metrics.markerEdgeMargin
        let extendsDownward = point.y < Metrics.markerSize.height + Metrics.markerEdgeMargin
        let leansRight = point.x < margin
        let leansLeft = point.x > bounds.width - margin

        let lean: CGFloat
        if leansRight {
            lean = 0.30
        } else if leansLeft {
            lean = -0.30
        } else {
            lean = -0.18
        }

        return CGAffineTransform(rotationAngle: extendsDownward ? .pi - lean : lean)
    }

    private func applyHoverAppearance() {
        // Apple식 경험: pinch를 놓는 순간 펜 본체는 즉시 사라지고 위치 힌트만 남는다.
        hideMarkerImmediately()
        uncertainLayer.isHidden = true
        guideLayer.isHidden = false
        guideLayer.opacity = 0.38
    }

    private func applyDrawingAppearance(animated: Bool) {
        guideLayer.isHidden = true
        uncertainLayer.isHidden = true

        markerView.layer.removeAllAnimations()
        markerView.isHidden = false
        markerView.alpha = 1

        guard animated else {
            markerView.transform = markerBaseTransform
            return
        }

        markerView.transform = markerBaseTransform.scaledBy(x: 0.72, y: 0.72)
        markerView.alpha = 0.55
        UIView.animate(
            withDuration: 0.22,
            delay: 0,
            usingSpringWithDamping: 0.62,
            initialSpringVelocity: 0.8,
            options: [.beginFromCurrentState, .allowUserInteraction]
        ) {
            self.markerView.transform = self.markerBaseTransform
            self.markerView.alpha = 1
        }
    }

    private func applyUncertainAppearance() {
        // 판정 불가 구간을 계속 drawing처럼 보이면 사용자가 release 실패로 오해한다.
        hideMarkerImmediately()
        guideLayer.isHidden = true
        uncertainLayer.isHidden = false
        uncertainLayer.opacity = 0.72
    }

    private func applyHiddenAppearance() {
        hideMarkerImmediately()
        guideLayer.isHidden = true
        uncertainLayer.isHidden = true
    }

    private func hideMarkerImmediately() {
        markerView.layer.removeAllAnimations()
        markerView.alpha = 0
        markerView.isHidden = true
        markerView.transform = markerBaseTransform
    }

    private func updateColors() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)

        markerView.color = penColor
        guideLayer.strokeColor = penColor.withAlphaComponent(0.9).cgColor
        uncertainLayer.strokeColor = penColor.withAlphaComponent(0.95).cgColor

        CATransaction.commit()
    }

    private func updateRingPaths() {
        let guideBounds = CGRect(
            x: -Metrics.guideDiameter / 2,
            y: -Metrics.guideDiameter / 2,
            width: Metrics.guideDiameter,
            height: Metrics.guideDiameter
        )
        let uncertainBounds = CGRect(
            x: -Metrics.uncertainDiameter / 2,
            y: -Metrics.uncertainDiameter / 2,
            width: Metrics.uncertainDiameter,
            height: Metrics.uncertainDiameter
        )

        CATransaction.begin()
        CATransaction.setDisableActions(true)

        guideLayer.bounds = CGRect(origin: .zero, size: guideBounds.size)
        guideLayer.path = UIBezierPath(ovalIn: guideBounds.offsetBy(
            dx: Metrics.guideDiameter / 2,
            dy: Metrics.guideDiameter / 2
        )).cgPath
        guideLayer.lineWidth = 1.5

        uncertainLayer.bounds = CGRect(origin: .zero, size: uncertainBounds.size)
        uncertainLayer.path = UIBezierPath(ovalIn: uncertainBounds.offsetBy(
            dx: Metrics.uncertainDiameter / 2,
            dy: Metrics.uncertainDiameter / 2
        )).cgPath
        uncertainLayer.lineWidth = 2
        uncertainLayer.lineDashPattern = [2, 3]

        CATransaction.commit()
    }
}

private final class MarkerGlyphView: UIView {

    var color: UIColor = .systemRed {
        didSet {
            guard !color.isEqual(oldValue) else { return }
            setNeedsDisplay()
        }
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        configure()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        configure()
    }

    private func configure() {
        backgroundColor = .clear
        isOpaque = false
        contentMode = .redraw
        layer.shadowColor = UIColor.black.cgColor
        layer.shadowOpacity = 0.4
        layer.shadowRadius = 2.5
        layer.shadowOffset = CGSize(width: 0, height: 1)
    }

    override func draw(_ rect: CGRect) {
        guard let context = UIGraphicsGetCurrentContext() else { return }

        context.saveGState()
        context.setLineJoin(.round)
        context.setLineCap(.round)

        let bodyRect = CGRect(x: 9, y: 2, width: 20, height: 34)
        let body = UIBezierPath(roundedRect: bodyRect, cornerRadius: 7)

        let tip = UIBezierPath()
        tip.move(to: CGPoint(x: 11, y: 31))
        tip.addLine(to: CGPoint(x: 27, y: 31))
        tip.addLine(to: CGPoint(x: 21, y: 51))
        tip.addQuadCurve(to: CGPoint(x: 17, y: 51), controlPoint: CGPoint(x: 19, y: 54))
        tip.close()

        // 흰 펜도 카메라 영상 위에서 형태를 잃지 않도록 얇은 어두운 외곽선을 둔다.
        UIColor.black.withAlphaComponent(0.38).setStroke()
        color.setFill()
        body.lineWidth = 1.2
        tip.lineWidth = 1.2
        body.fill()
        body.stroke()
        tip.fill()
        tip.stroke()

        UIColor.white.withAlphaComponent(0.55).setStroke()
        let highlight = UIBezierPath()
        highlight.move(to: CGPoint(x: 14, y: 8))
        highlight.addLine(to: CGPoint(x: 14, y: 27))
        highlight.lineWidth = 1.4
        highlight.stroke()

        context.restoreGState()
    }
}
