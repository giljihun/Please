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

    /// 추적이 끊긴 이유.
    ///
    /// 하나로 뭉뚱그리면 대응을 고를 수 없다. "펜이 사라졌다"는 같은 현상이라도
    /// 모델이 손을 못 찾은 것과 우리 상태 머신이 끊은 것은 고칠 곳이 완전히 다르다.
    /// 실기기에서 어느 사유가 지배적인지 세어 보고 그다음을 정한다 (#26)
    enum TrackingLoss: String, CaseIterable, Sendable {
        /// Vision이 손 자체를 찾지 못함 — 카메라·조명·모션 블러 쪽
        case handNotFound
        /// 손은 찾았으나 검지 관절이 아예 없음 — 역시 카메라 쪽
        case penTipMissing
        /// 검지는 있으나 신뢰도가 기준 미달 — 임계값 조정으로 회수 가능
        case penTipLowConfidence
        /// 정규화 좌표를 화면 좌표로 옮기지 못함 — 레이아웃/버퍼 크기 문제
        case mappingFailed
        /// 그립 판정에 필요한 관절이 없음. 직전 판정으로 메우므로 대개 무해하다
        case gripUnavailable
        /// 직전 판정 유지 시간마저 지나 그립을 정말로 알 수 없는 상태
        case gripHoldExpired
        /// 유실 허용 시간을 넘겨 획을 끊음
        case missTimeout
        /// 보류 좌표를 확정하지 못한 채 시간이 지나 획을 끊음
        case pendingTimeout
        /// 캡처 타임스탬프가 비정상(역행·무효)이라 생명주기를 재시작함
        case timestampInvalid

        /// 디버그 표시용 짧은 한글 이름
        var shortLabel: String {
            switch self {
            case .handNotFound: "손없음"
            case .penTipMissing: "검지없음"
            case .penTipLowConfidence: "검지약함"
            case .mappingFailed: "변환실패"
            case .gripUnavailable: "그립가림"
            case .gripHoldExpired: "그립상실"
            case .missTimeout: "유실초과"
            case .pendingTimeout: "보류초과"
            case .timestampInvalid: "시각이상"
            }
        }
    }

    /// 화면의 펜 커서·사운드 같은 피드백에 필요한 최신 값.
    struct Feedback: Equatable {
        let state: State
        let point: CGPoint?
        let gripRatio: CGFloat?
        let isWaitingForRelease: Bool
        /// 가장 최근에 기록된 유실 사유 (#26 계측용)
        var lastLoss: TrackingLoss?
        /// 사유별 누적 횟수 (#26 계측용)
        var lossCounts: [TrackingLoss: Int] = [:]
        /// 검지 끝 신뢰도. 관절이 없으면 nil — 임계값을 낮추면 회수되는지 판단용
        var penTipConfidence: Float?
    }

    private struct PendingSample {
        let point: CGPoint
        let timestamp: TimeInterval
    }

    // MARK: - 판정 기준

    /// 하나의 문턱만 쓰면 경계에서 떨릴 때 획이 잘게 끊기므로 진입·이탈 값을 벌린다.
    ///
    /// 실측 기준 (2026-08-26, 검지 길이 대비 비율):
    /// 꽉 잡으면 0.08, 붙이면 0.13. 검지 길이를 7.5cm로 보면 비율 × 7.5cm가 실제 간격이다.
    ///
    /// 이탈이 0.45(3.4cm)였을 때 문제가 있었다. 손가락을 의식적으로 활짝 벌려야 하는
    /// 거리라, 사인 중 자연스럽게 1.5~3cm 벌어지는 구간이 전부 "아직 쥐고 있음"으로
    /// 판정돼 이동 중에도 획이 계속 그려졌다.
    ///
    /// 0.32(2.4cm)는 의도적으로 벌려야 닿으면서 사인 중 흔들림으로는 닿지 않는 거리다.
    /// 간격 0.12는 좌표 노이즈(±0.03)의 4배라 경계에서 상태가 뒤집히지 않는다
    private static let gripEnterRatio: CGFloat = 0.20
    private static let gripExitRatio: CGFloat = 0.32

    /// 새 좌표 반영률. 작을수록 부드럽지만 펜이 손을 늦게 따라간다.
    private static let smoothingFactor: CGFloat = 0.4

    /// 검지 끝을 잠깐 놓친 프레임 때문에 획을 즉시 끊지 않는 허용 시간.
    private static let maxMissedInterval: TimeInterval = 0.13

    /// pinch 판정 불가 좌표를 캔버스에 확정하기 전 보류하는 최대 시간과 개수.
    /// 시간과 개수를 함께 제한해 프레임률이 달라도 메모리와 지연이 상한을 넘지 않게 한다.
    ///
    /// 0.10초/6샘플에서 늘렸다 (2026-08-26 계측). 그 값에서는 정상적인 사인 도중에도
    /// 보류 초과가 지배적으로 발생했다 — 엄지는 쥐면 검지 뒤로 숨으므로
    /// 판정 불가가 예외가 아니라 상시 상태였기 때문이다
    private static let maxPendingInterval: TimeInterval = 0.30
    private static let maxPendingSampleCount = 20

    /// 그립 비율을 못 구했을 때 직전 값을 대신 쓰는 최대 시간.
    ///
    /// 손은 순간이동하지 않으므로 직전 판정은 짧은 구간에서 여전히 유효하다.
    /// 특히 이 상황이 안전한 이유: 비율을 못 구하는 주된 원인은 **쥘 때 엄지가
    /// 검지 뒤로 숨는 것**이다. 손을 펴면 엄지가 오히려 더 잘 보여 값이 즉시 돌아온다.
    /// 즉 값을 유지하면 "아직 쥐고 있다"로 남는데, 그게 실제로 맞다
    private static let maxGripRatioHoldInterval: TimeInterval = 0.30

    // MARK: - 상태

    private let strokeSink: any GestureStrokeSink
    private var isStrokeActive = false
    private var smoothedPoint: CGPoint?
    private var lastSeenAt: TimeInterval?
    private var lastInputTimestamp: TimeInterval?
    private var pendingSamples: [PendingSample] = []
    private var isWaitingForRelease = false
    private var lastRatioValue: CGFloat?
    private var lastRatioAt: TimeInterval?

    private(set) var state: State = .hidden

    /// 유실 사유별 누적 횟수 (#26). 검증이 끝나면 제거한다
    private(set) var lossCounts: [TrackingLoss: Int] = [:]
    private(set) var lastLoss: TrackingLoss?
    private var lastPenTipConfidence: Float?

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
            record(.timestampInvalid)
            reset(requiresRelease: true)
            return
        }
        if let lastInputTimestamp, timestamp <= lastInputTimestamp {
            if timestamp < lastInputTimestamp {
                record(.timestampInvalid)
                reset(requiresRelease: true)
            }
            return
        }
        lastInputTimestamp = timestamp

        let mapper = VisionCoordinateMapper(imageSize: imageSize, viewSize: viewSize)

        // 세 가지를 한 guard로 묶으면 "펜이 사라졌다"까지만 알고 원인은 알 수 없다.
        // 각각 고칠 곳이 달라서 (카메라 / 임계값 / 레이아웃) 사유를 갈라 기록한다
        // 손이 없는 프레임도 갱신 대상이다 — guard 뒤에서 갱신하면
        // 손이 사라진 동안 진단 화면에 직전 프레임의 신뢰도가 계속 남는다
        lastPenTipConfidence = pose?.penTipConfidence
        guard let pose else {
            handleMissingTip(.handNotFound, at: timestamp)
            return
        }
        guard let tip = pose.penTip else {
            handleMissingTip(
                pose.penTipConfidence == nil ? .penTipMissing : .penTipLowConfidence,
                at: timestamp
            )
            return
        }
        guard let point = mapper.screenPoint(tip) else {
            handleMissingTip(.mappingFailed, at: timestamp)
            return
        }

        // 분석 공백 뒤의 좌표를 이전 획에 연결하면 화면을 가로지르는 직선이 생긴다.
        if isStrokeActive,
           let lastSeenAt,
           timestamp - lastSeenAt > Self.maxMissedInterval {
            record(.missTimeout)
            finishStroke()
        }
        lastSeenAt = timestamp

        let ratio = heldRatio(pose.gripRatio(imageSize: imageSize), at: timestamp)

        if isWaitingForRelease {
            handleReleaseGate(point: point, ratio: ratio)
            return
        }

        guard let ratio else {
            record(.gripHoldExpired)
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
                record(.pendingTimeout)
                // 획은 끊되 입력을 잠그지는 않는다. 추적이 잠깐 흔들린 것과
                // 사용자가 손을 뗀 것은 다르며, 쥐고 있는데 다시 못 그리는 쪽이
                // 획이 잠깐 끊기는 것보다 훨씬 나쁘다 (2026-08-26 계측 근거)
                finishStroke()
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
        lastRatioValue = nil
        lastRatioAt = nil
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

    private func handleMissingTip(_ reason: TrackingLoss, at timestamp: TimeInterval) {
        record(reason)
        if isStrokeActive,
           let lastSeenAt,
           timestamp - lastSeenAt > Self.maxMissedInterval {
            record(.missTimeout)
            finishStroke()
        }
        publish(.hidden, point: nil, ratio: nil)
    }

    /// 비율을 못 구한 프레임에서 직전 판정을 대신 쓴다 — 이유는 [maxGripRatioHoldInterval] 참고
    private func heldRatio(_ ratio: CGFloat?, at timestamp: TimeInterval) -> CGFloat? {
        if let ratio {
            lastRatioValue = ratio
            lastRatioAt = timestamp
            return ratio
        }

        record(.gripUnavailable)
        guard let lastRatioValue,
              let lastRatioAt,
              timestamp - lastRatioAt <= Self.maxGripRatioHoldInterval else { return nil }
        return lastRatioValue
    }

    /// 유실 사유를 누적한다. 계측이 끝나면 이 경로 전체를 제거한다 (#26)
    private func record(_ reason: TrackingLoss) {
        lastLoss = reason
        lossCounts[reason, default: 0] += 1
    }

    /// 비율이 없는 좌표는 아직 잉크가 아니다. 짧게 보관한 뒤 pinch 재확인 때만 커밋한다.
    private func holdUncertain(point: CGPoint, timestamp: TimeInterval) {
        pendingSamples.append(PendingSample(point: point, timestamp: timestamp))

        let exceededCount = pendingSamples.count > Self.maxPendingSampleCount
        let exceededTime = pendingWindowExceeded(at: timestamp)

        if exceededCount || exceededTime {
            record(.pendingTimeout)
            finishStroke()
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
                isWaitingForRelease: isWaitingForRelease,
                lastLoss: lastLoss,
                lossCounts: lossCounts,
                penTipConfidence: lastPenTipConfidence
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
