//
//  GestureDrawingController.swift
//  Please
//
//  Created by 길지훈 on 8/26/26.
//

import UIKit

/// 제스처 컨트롤러가 필요로 하는 최소 캔버스 계약.
///
/// Vision 판정과 실제 렌더링을 분리해 상태 머신을 UI 없이 검증할 수 있게 한다.
@MainActor
protocol GestureStrokeSink: AnyObject {
    func beginStroke(at point: CGPoint)
    func appendPoint(_ point: CGPoint)
    func endStroke()
}

extension DrawingCanvasView: GestureStrokeSink {}

/// 검지 끝을 펜 위치로, 엄지·검지 pinch를 pen-down 신호로 번역한다.
@MainActor
final class GestureDrawingController {

    /// 펜 피드백이 표현할 네 가지 상태.
    enum State: Equatable {
        case hidden
        case hover
        case drawing
        case uncertain
    }

    /// 화면의 펜 커서·사운드 같은 피드백에 필요한 최신 값.
    struct Feedback: Equatable {
        let state: State
        let point: CGPoint?
        let gripRatio: CGFloat?
        let isWaitingForRelease: Bool
    }

    private struct PendingSample {
        let point: CGPoint
        let timestamp: TimeInterval
    }

    // MARK: - 판정 기준

    /// 하나의 문턱만 쓰면 경계에서 떨릴 때 획이 잘게 끊기므로 진입·이탈 값을 벌린다.
    private static let gripEnterRatio: CGFloat = 0.30
    private static let gripExitRatio: CGFloat = 0.45

    /// 새 좌표 반영률. 작을수록 부드럽지만 펜이 손을 늦게 따라간다.
    private static let smoothingFactor: CGFloat = 0.4

    /// 검지 끝을 잠깐 놓친 프레임 때문에 획을 즉시 끊지 않는 허용 시간.
    private static let maxMissedInterval: TimeInterval = 0.13

    /// pinch 판정 불가 좌표를 캔버스에 확정하기 전 보류하는 최대 시간과 개수.
    /// 시간과 개수를 함께 제한해 프레임률이 달라도 메모리와 지연이 상한을 넘지 않게 한다.
    private static let maxPendingInterval: TimeInterval = 0.10
    private static let maxPendingSampleCount = 6

    // MARK: - 상태

    private let strokeSink: any GestureStrokeSink
    private var isStrokeActive = false
    private var smoothedPoint: CGPoint?
    private var lastSeenAt: TimeInterval?
    private var lastInputTimestamp: TimeInterval?
    private var pendingSamples: [PendingSample] = []
    private var isWaitingForRelease = false

    private(set) var state: State = .hidden

    /// 상태뿐 아니라 좌표도 매 프레임 전달한다. 펜 커서가 hover 중에도 손을 따라야 하기 때문이다.
    var onFeedback: ((Feedback) -> Void)?

    init(strokeSink: any GestureStrokeSink) {
        self.strokeSink = strokeSink
    }

    /// 기존 프로덕션 호출부를 유지하는 편의 초기화 경로.
    convenience init(canvas: DrawingCanvasView) {
        self.init(strokeSink: canvas)
    }

    // MARK: - 입력

    /// Vision 결과를 반영한다.
    ///
    /// `timestamp`는 호출자가 주입하는 단조 증가 시간이어야 한다. 프레임 횟수가 아니라
    /// 실제 경과 시간을 써야 Vision 백프레셔로 프레임이 버려져도 허용 시간이 일정하다.
    func update(
        pose: HandPose?,
        imageSize: CGSize,
        viewSize: CGSize,
        timestamp: TimeInterval
    ) {
        // 캡처 PTS가 유효하지 않거나 역행하면 시간 기반 유실 판정을 신뢰할 수 없다.
        // 이전 획을 이어 붙이지 않고, release를 한 번 확인한 뒤 다시 시작한다.
        guard timestamp.isFinite else {
            reset(requiresRelease: true)
            return
        }
        if let lastInputTimestamp, timestamp <= lastInputTimestamp {
            if timestamp < lastInputTimestamp {
                reset(requiresRelease: true)
            }
            return
        }
        lastInputTimestamp = timestamp

        let mapper = VisionCoordinateMapper(imageSize: imageSize, viewSize: viewSize)

        guard let pose,
              let tip = pose.penTip,
              let point = mapper.screenPoint(tip)
        else {
            handleMissingTip(at: timestamp)
            return
        }

        // 분석 공백 뒤의 좌표를 이전 획에 연결하면 화면을 가로지르는 직선이 생긴다.
        if isStrokeActive,
           let lastSeenAt,
           timestamp - lastSeenAt > Self.maxMissedInterval {
            finishStroke()
            isWaitingForRelease = true
        }
        lastSeenAt = timestamp

        let ratio = pose.gripRatio(imageSize: imageSize)

        if isWaitingForRelease {
            handleReleaseGate(point: point, ratio: ratio)
            return
        }

        guard let ratio else {
            if isStrokeActive {
                holdUncertain(point: point, timestamp: timestamp)
            } else {
                publish(.uncertain, point: point, ratio: nil)
            }
            return
        }

        if isStrokeActive {
            if ratio >= Self.gripExitRatio {
                // 보류 좌표는 사용자가 이미 손을 뗀 뒤의 움직임일 수 있으므로 폐기한다.
                finishStroke()
                publish(.hover, point: point, ratio: ratio)
            } else if pendingWindowExceeded(at: timestamp) {
                // 마지막 unknown 프레임과 pinch 재확인 사이가 길어도 100ms 상한을 지킨다.
                // 같은 pinch로 획을 다시 시작하지 않고 release 확인까지 재무장을 막는다.
                finishStroke()
                isWaitingForRelease = true
                publish(.uncertain, point: point, ratio: ratio)
            } else {
                // pinch가 다시 확인된 경우에만 보류 좌표를 시간 순서대로 확정한다.
                let confirmedPoint = appendConfirmedSamples(endingAt: point)
                publish(.drawing, point: confirmedPoint, ratio: ratio)
            }
        } else if ratio <= Self.gripEnterRatio {
            beginStroke(at: point)
            publish(.drawing, point: point, ratio: ratio)
        } else {
            publish(.hover, point: point, ratio: ratio)
        }
    }

    /// 진행 중 획과 추적 이력을 비운다.
    ///
    /// 사용자가 캔버스를 지우는 경우 `requiresRelease`를 켜면, 지운 순간의 pinch가
    /// 다음 프레임에서 곧바로 새 획을 시작하지 않는다. open 상태를 한 번 확인한 뒤 재무장한다.
    func reset(requiresRelease: Bool = false) {
        finishStroke()
        lastSeenAt = nil
        lastInputTimestamp = nil
        isWaitingForRelease = requiresRelease
        publish(.hidden, point: nil, ratio: nil)
    }

    // MARK: - 상태 전이

    private func beginStroke(at point: CGPoint) {
        pendingSamples.removeAll(keepingCapacity: true)
        smoothedPoint = point
        isStrokeActive = true
        strokeSink.beginStroke(at: point)
    }

    /// 획 종료 시 확정되지 않은 좌표는 항상 폐기한다.
    private func finishStroke() {
        pendingSamples.removeAll(keepingCapacity: true)
        guard isStrokeActive else {
            smoothedPoint = nil
            return
        }

        isStrokeActive = false
        smoothedPoint = nil
        strokeSink.endStroke()
    }

    private func handleReleaseGate(point: CGPoint, ratio: CGFloat?) {
        guard let ratio else {
            publish(.uncertain, point: point, ratio: nil)
            return
        }

        guard ratio >= Self.gripExitRatio else {
            // 좌표와 pinch는 읽히지만 이전 생명주기가 끝나지 않은 상태다.
            // armed 상태인 hover로 보이면 사용자가 입력 거부를 인식할 수 없다.
            publish(.uncertain, point: point, ratio: ratio)
            return
        }
        isWaitingForRelease = false
        // gate가 열린 프레임도 hover로 남긴다. 새 pinch는 다음 프레임부터 시작한다.
        publish(.hover, point: point, ratio: ratio)
    }

    private func handleMissingTip(at timestamp: TimeInterval) {
        if isStrokeActive,
           let lastSeenAt,
           timestamp - lastSeenAt > Self.maxMissedInterval {
            finishStroke()
            isWaitingForRelease = true
        }
        publish(.hidden, point: nil, ratio: nil)
    }

    /// 비율이 없는 좌표는 아직 잉크가 아니다. 짧게 보관한 뒤 pinch 재확인 때만 커밋한다.
    private func holdUncertain(point: CGPoint, timestamp: TimeInterval) {
        pendingSamples.append(PendingSample(point: point, timestamp: timestamp))

        let exceededCount = pendingSamples.count > Self.maxPendingSampleCount
        let exceededTime = pendingWindowExceeded(at: timestamp)

        if exceededCount || exceededTime {
            finishStroke()
            isWaitingForRelease = true
        }
        publish(.uncertain, point: point, ratio: nil)
    }

    private func pendingWindowExceeded(at timestamp: TimeInterval) -> Bool {
        pendingSamples.first.map {
            timestamp - $0.timestamp > Self.maxPendingInterval
        } ?? false
    }

    /// 보류된 원시 좌표를 순서대로 스무딩해야, 폐기된 좌표가 EMA 이력에 섞이지 않는다.
    @discardableResult
    private func appendConfirmedSamples(endingAt point: CGPoint) -> CGPoint {
        for sample in pendingSamples {
            strokeSink.appendPoint(smooth(sample.point))
        }
        pendingSamples.removeAll(keepingCapacity: true)

        let confirmedPoint = smooth(point)
        strokeSink.appendPoint(confirmedPoint)
        return confirmedPoint
    }

    private func publish(_ state: State, point: CGPoint?, ratio: CGFloat?) {
        self.state = state
        onFeedback?(
            Feedback(
                state: state,
                point: point,
                gripRatio: ratio,
                isWaitingForRelease: isWaitingForRelease
            )
        )
    }

    // MARK: - 스무딩

    private func smooth(_ point: CGPoint) -> CGPoint {
        guard let previous = smoothedPoint else {
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
