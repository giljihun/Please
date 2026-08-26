//
//  GestureDrawingController.swift
//  Please
//
//  Created by 길지훈 on 8/26/26.
//

import UIKit

/// 손 제스처를 드로잉 입력으로 번역하는 컨트롤러.
///
/// 하는 일은 셋뿐이다:
/// ① 언제 그릴지 판정(그립) ② 좌표 안정화(스무딩) ③ 캔버스에 전달
///
/// 별도 타입으로 분리한 이유: "언제 그릴지"의 판정 기준은 실기기에서 바뀔 값이다.
/// (엄지 방아쇠 → 손목 회전 → 손 크기 기반 깊이 판정 등 후보가 여럿 남아 있다)
/// 판정을 이 타입 안에만 가둬두면 기준을 갈아끼워도 캡처·캔버스 코드는 손댈 일이 없다
final class GestureDrawingController {

    // MARK: - 판정 기준
    // 이력현상(hysteresis): 문턱을 하나만 두면 그 값 근처에서 손이 미세하게 떨릴 때
    // 선이 끊겼다 이어졌다를 반복한다. 들어가는 문턱과 나오는 문턱을 벌려두면
    // 경계에서 흔들려도 상태가 뒤집히지 않는다 (에어컨이 24도에 켜고 26도에 끄는 것과 같은 원리)

    /// 엄지·검지가 이만큼 붙으면 펜을 쥔 것으로 본다
    private static let gripEnterRatio: CGFloat = 0.30
    /// 이만큼 벌어져야 뗀 것으로 본다
    private static let gripExitRatio: CGFloat = 0.45

    /// 새 좌표를 얼마나 반영할지 (작을수록 부드럽지만 손을 늦게 따라온다)
    private static let smoothingFactor: CGFloat = 0.4

    /// 펜 끝을 놓쳐도 획을 유지할 최대 프레임 수 (30fps 기준 약 0.13초).
    ///
    /// 실시간 포즈 추정은 프레임마다 신뢰도가 출렁이는 게 정상이고, 사인처럼 빠른
    /// 움직임에서는 모션 블러로 검지 끝이 순간 사라진다. 한 프레임에 반응해 획을 닫으면
    /// 손을 떼지도 않았는데 사인이 조각난다.
    /// 그렇다고 무한정 참으면 손이 실제로 사라졌다 돌아올 때 화면을 가로지르는
    /// 직선이 생기므로 상한을 둔다 — 실기기에서 조정할 값
    private static let maxMissedFrames = 4

    // MARK: - 상태

    private let canvas: DrawingCanvasView
    private var isDrawing = false
    private var smoothedPoint: CGPoint?
    private var missedFrames = 0

    init(canvas: DrawingCanvasView) {
        self.canvas = canvas
    }

    // MARK: - 입력

    /// 프레임마다 호출. 손이 잡히지 않았으면 pose에 nil을 넘긴다
    func update(pose: HandPose?, imageSize: CGSize, viewSize: CGSize) {
        let mapper = VisionCoordinateMapper(imageSize: imageSize, viewSize: viewSize)

        guard let pose,
              let tip = pose.penTip,
              let point = mapper.screenPoint(tip)
        else {
            handleMissedFrame()
            return
        }
        missedFrames = 0

        let ratio = pose.gripRatio(imageSize: imageSize)

        if isDrawing {
            // ratio가 nil = 엄지를 못 찾았다. 이때 획을 끊지 않는 이유:
            // 엄지·검지를 붙이는 동작 자체가 엄지를 검지 뒤로 숨긴다.
            // 안 보인다고 끊으면 정작 쥐고 있을 때 사인이 조각난다.
            // 대신 "시작"할 때는 비율이 확인돼야 한다 (아래 분기) — 못 보고 긋기 시작하진 않는다
            if let ratio, ratio >= Self.gripExitRatio {
                endStroke()
            } else {
                canvas.appendPoint(smooth(point))
            }
        } else if let ratio, ratio <= Self.gripEnterRatio {
            isDrawing = true
            // 새 획은 현재 위치에서 시작한다 — 직전 획의 스무딩 이력을 물려받으면
            // 획이 엉뚱한 곳에서 끌려오며 시작된다
            smoothedPoint = point
            canvas.beginStroke(at: point)
        }
    }

    /// 진행 중인 획을 정리하고 스무딩 이력을 버린다 (모드 종료·손 유실)
    func reset() {
        if isDrawing {
            endStroke()
        }
        smoothedPoint = nil
        missedFrames = 0
    }

    /// 펜 끝을 얻지 못한 프레임 처리.
    ///
    /// 그리는 중이면 잠깐은 참는다 — 이유는 [maxMissedFrames] 주석 참고.
    /// 그립 비율이 nil일 때 획을 끊지 않는 것과 같은 원칙이다:
    /// 인식이 잠깐 흔들린 것과 사용자가 손을 뗀 것은 다르다
    private func handleMissedFrame() {
        guard isDrawing else {
            reset()
            return
        }
        missedFrames += 1
        if missedFrames > Self.maxMissedFrames {
            reset()
        }
    }

    private func endStroke() {
        isDrawing = false
        smoothedPoint = nil  // 획 사이에 이력을 남기지 않는다
        canvas.endStroke()
    }

    // MARK: - 스무딩

    /// 지수 이동평균(EMA). Vision 좌표는 프레임마다 몇 픽셀씩 튀는데
    /// 그대로 그리면 선이 지렁이처럼 떨린다. 직전 좌표와 섞어 흔들림을 눌러준다.
    /// 획이 진행 중일 때만 호출된다 — 쉬는 동안의 좌표가 섞이면 다음 획이 끌려온다
    private func smooth(_ point: CGPoint) -> CGPoint {
        guard let previous = smoothedPoint else {
            // 첫 좌표는 섞을 대상이 없다 — 그대로 채택 (엉뚱한 곳에서 끌려오는 지연 방지)
            smoothedPoint = point
            return point
        }

        let factor = Self.smoothingFactor
        let smoothed = CGPoint(
            x: previous.x * (1 - factor) + point.x * factor,
            y: previous.y * (1 - factor) + point.y * factor
        )
        smoothedPoint = smoothed
        return smoothed
    }
}
