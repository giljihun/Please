//
//  HandOverlayView.swift
//  Please
//
//  Created by 길지훈 on 8/23/26.
//

import UIKit
import AVFoundation
import Vision

/// 손 관절 스켈레톤을 그리는 개발용 오버레이.
///
/// 목적: 인식 실패의 원인을 눈으로 구분하기 위함.
/// 점 하나만 표시하면 "안 된다"까지만 알 수 있지만, 관절 전체와 신뢰도를 보면
/// 어두운 곳에서 어느 손가락이 먼저 무너지는지, 멀어질 때 무엇이 흔들리는지가 드러난다.
/// #19 실측이 끝나면 제거하거나 개발자 설정 뒤로 숨긴다
final class HandOverlayView: UIView {

    private var pose: HandPose?

    /// 감지에 쓰인 정립 이미지 크기 — aspectFill 크롭 계산의 기준
    private var imageSize: CGSize = .zero

    /// 표시할 포즈 갱신. nil이면 오버레이를 비운다
    func update(pose: HandPose?, imageSize: CGSize) {
        self.pose = pose
        self.imageSize = imageSize
        setNeedsDisplay()
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        isUserInteractionEnabled = false  // 터치는 아래 캔버스로 통과시킨다
        contentMode = .redraw
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        backgroundColor = .clear
        isUserInteractionEnabled = false
        contentMode = .redraw
    }

    override func draw(_ rect: CGRect) {
        guard let pose, let context = UIGraphicsGetCurrentContext() else { return }

        drawBones(pose: pose, in: context)
        drawJoints(pose: pose, in: context)
        drawPenTip(pose: pose, in: context)
    }

    // MARK: - 그리기

    /// 손가락 사슬을 선으로 연결. 양 끝 관절이 모두 인식된 구간만 그린다
    private func drawBones(pose: HandPose, in context: CGContext) {
        context.setLineWidth(3)
        context.setLineCap(.round)
        context.setStrokeColor(UIColor.white.withAlphaComponent(0.55).cgColor)

        for chain in HandPose.fingerChains {
            for index in 0..<(chain.count - 1) {
                guard let from = pose.joints[chain[index]],
                      let to = pose.joints[chain[index + 1]],
                      let start = screenPoint(from.location),
                      let end = screenPoint(to.location) else { continue }

                context.move(to: start)
                context.addLine(to: end)
                context.strokePath()
            }
        }
    }

    /// 관절 점. 색이 곧 신뢰도 — 초록(확실) → 노랑 → 빨강(의심)
    private func drawJoints(pose: HandPose, in context: CGContext) {
        for (_, joint) in pose.joints {
            guard let point = screenPoint(joint.location) else { continue }

            context.setFillColor(confidenceColor(joint.confidence).cgColor)
            let radius: CGFloat = 5
            context.fillEllipse(in: CGRect(
                x: point.x - radius, y: point.y - radius,
                width: radius * 2, height: radius * 2
            ))
        }
    }

    /// 펜 끝 후보(엄지-검지 중점)를 링으로 강조 — 실제로 선이 그려질 지점
    private func drawPenTip(pose: HandPose, in context: CGContext) {
        guard let tip = pose.penTip, let point = screenPoint(tip) else { return }

        context.setStrokeColor(UIColor.systemRed.cgColor)
        context.setLineWidth(3)
        let radius: CGFloat = 14
        context.strokeEllipse(in: CGRect(
            x: point.x - radius, y: point.y - radius,
            width: radius * 2, height: radius * 2
        ))
    }

    // MARK: - 좌표 변환

    /// Vision 정규화 좌표(정립 이미지 기준, 좌하단 원점) → 화면 좌표.
    ///
    /// 프리뷰 레이어의 `layerPointConverted`를 쓰지 않는 이유: 그 메서드는
    /// "회전·미러링이 적용되지 않은 원본 버퍼" 좌표를 기대한다. 감지기가 이미
    /// 정립 방향으로 인식했으므로 그대로 넘기면 보정이 두 번 걸려 스켈레톤이 어긋난다.
    ///
    /// 대신 프리뷰와 동일한 aspectFill 규칙(짧은 변을 채우고 넘치는 쪽을 잘라냄)을
    /// 직접 재현한다 — 프리뷰가 videoGravity = .resizeAspectFill이므로 결과가 일치한다
    private func screenPoint(_ normalized: CGPoint) -> CGPoint? {
        guard imageSize.width > 0, imageSize.height > 0 else { return nil }

        let scale = max(bounds.width / imageSize.width, bounds.height / imageSize.height)
        let scaledSize = CGSize(
            width: imageSize.width * scale,
            height: imageSize.height * scale
        )
        // 크롭으로 잘려나간 만큼을 좌우·상하 대칭으로 보정
        let offset = CGPoint(
            x: (bounds.width - scaledSize.width) / 2,
            y: (bounds.height - scaledSize.height) / 2
        )

        return CGPoint(
            x: normalized.x * scaledSize.width + offset.x,
            y: (1 - normalized.y) * scaledSize.height + offset.y  // Vision은 좌하단 원점
        )
    }

    /// 신뢰도 → 색. 0.5(임계) 부근은 빨강, 1.0에 가까울수록 초록
    private func confidenceColor(_ confidence: Float) -> UIColor {
        let normalized = max(0, min(1, (confidence - 0.5) * 2))  // 0.5~1.0 → 0~1
        return UIColor(
            hue: CGFloat(normalized) * 0.33,  // 0(빨강) → 0.33(초록)
            saturation: 0.9, brightness: 0.95, alpha: 1
        )
    }
}
