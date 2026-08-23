//
//  HandPoseDetector.swift
//  Please
//
//  Created by 길지훈 on 8/23/26.
//

import Vision
import AVFoundation

/// 감지된 손의 관절 좌표 묶음.
///
/// 좌표계: Vision 정규화 좌표(0~1, 좌하단 원점)를 그대로 보존한다.
/// 화면 좌표 변환은 프리뷰 레이어를 아는 쪽(뷰 계층)의 책임 —
/// 감지기가 화면을 알면 테스트도 재사용도 어려워진다
nonisolated struct HandPose: Sendable {

    /// 관절별 위치와 신뢰도
    struct Joint: Sendable {
        let location: CGPoint   // Vision 정규화 좌표
        let confidence: Float   // 0~1
    }

    let joints: [VNHumanHandPoseObservation.JointName: Joint]

    /// 손가락별 관절 연결 순서 (스켈레톤 선 그리기용).
    /// 손목에서 시작해 각 손가락 끝으로 뻗는 5개의 사슬
    static let fingerChains: [[VNHumanHandPoseObservation.JointName]] = [
        [.wrist, .thumbCMC, .thumbMP, .thumbIP, .thumbTip],
        [.wrist, .indexMCP, .indexPIP, .indexDIP, .indexTip],
        [.wrist, .middleMCP, .middlePIP, .middleDIP, .middleTip],
        [.wrist, .ringMCP, .ringPIP, .ringDIP, .ringTip],
        [.wrist, .littleMCP, .littlePIP, .littleDIP, .littleTip]
    ]

    /// 펜 끝으로 삼을 지점 — 엄지 끝과 검지 끝의 중점.
    /// 단일 손가락 끝보다 흔들림이 적다 (두 점의 평균이므로 오차가 상쇄됨)
    var penTip: CGPoint? {
        guard let thumb = joints[.thumbTip], let index = joints[.indexTip] else { return nil }
        return CGPoint(
            x: (thumb.location.x + index.location.x) / 2,
            y: (thumb.location.y + index.location.y) / 2
        )
    }

    /// 손 크기 기준자 — 손목에서 중지 밑동까지의 거리.
    ///
    /// 그립 판정에 절대 거리를 쓰면 손이 멀어질 때 오작동한다
    /// (손 전체가 작아지므로 손을 펴도 손끝 간격이 좁게 측정됨).
    /// 이 기준자로 나눠 비율로 판정하면 거리와 무관해진다 — 원거리 사용의 전제
    var handScale: CGFloat? {
        guard let wrist = joints[.wrist], let middle = joints[.middleMCP] else { return nil }
        return hypot(
            middle.location.x - wrist.location.x,
            middle.location.y - wrist.location.y
        )
    }
}

/// 카메라 프레임에서 손 관절을 찾아내는 감지기.
///
/// 설계 근거: 손 인식 모델은 직접 학습하지 않고 Vision을 사용한다.
/// 애플이 대규모 데이터로 학습해 Neural Engine에 최적화한 모델이며,
/// 실패의 대부분은 모델이 아니라 후처리(임계값·스무딩·좌표 변환)에서 발생하기 때문.
/// 이 판단은 #19 실측으로 검증한다
/// ※ nonisolated: 프레임 델리게이트 큐에서 호출되어야 하므로 메인 액터에 묶이면 안 된다
///   (프로젝트 기본 격리가 MainActor라 명시가 필요하다)
nonisolated final class HandPoseDetector: @unchecked Sendable {

    /// 감지 결과 (신뢰도 낮은 관절은 이미 걸러진 상태)
    struct Result: Sendable {
        let pose: HandPose?
        let processingMilliseconds: Double
        /// 방향 보정 후의 이미지 크기. 오버레이가 화면 좌표로 변환할 때 필요하다
        /// (세로 모드에서 버퍼는 가로로 누워 있으므로 폭·높이가 뒤바뀐다)
        let uprightImageSize: CGSize
    }

    /// 이 값 미만의 관절은 버린다 — 애매한 좌표로 선을 그리면 획이 엉뚱한 곳으로 튄다
    private static let minimumConfidence: Float = 0.5

    private let request: VNDetectHumanHandPoseRequest = {
        let request = VNDetectHumanHandPoseRequest()
        request.maximumHandCount = 1  // 사인은 한 손 — 여러 손을 찾으면 연산만 늘어난다
        return request
    }()

    /// 처리 중 플래그 (백프레셔).
    /// Vision 분석이 프레임 간격보다 오래 걸릴 때 요청이 쌓이면 지연이 누적된다.
    /// 처리 중이면 새 프레임을 그냥 버려 항상 "최신 프레임"만 분석하도록 한다
    private let lock = NSLock()
    private var isProcessing = false

    /// 프레임 하나를 분석. 처리 중이면 nil을 반환하고 프레임을 버린다
    func detect(in sampleBuffer: CMSampleBuffer) -> Result? {
        let shouldProcess = lock.withLock {
            if isProcessing { return false }
            isProcessing = true
            return true
        }
        guard shouldProcess else { return nil }
        defer { lock.withLock { isProcessing = false } }

        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return nil }

        let start = CFAbsoluteTimeGetCurrent()

        // 방향 보정 후 크기 — 90도 회전이므로 폭과 높이가 뒤바뀐다
        let uprightSize = CGSize(
            width: CVPixelBufferGetHeight(pixelBuffer),
            height: CVPixelBufferGetWidth(pixelBuffer)
        )

        // 전면 카메라 세로 모드에서 버퍼는 가로로 누워 있고 좌우가 뒤집혀 있다.
        //
        // 이 값은 단순한 좌표 설정이 아니라 "손이 어느 방향인지"를 모델에 알려주는 입력이다.
        // 누운 이미지를 그대로 넣으면 인식률 자체가 떨어지므로 반드시 정립 방향을 지정한다.
        // 대신 반환 좌표는 "정립 이미지 기준"이 되므로, 화면 변환은 오버레이가
        // 프리뷰 레이어가 아닌 이 크기를 기준으로 직접 수행한다 (이중 보정 방지)
        let handler = VNImageRequestHandler(
            cvPixelBuffer: pixelBuffer,
            orientation: .leftMirrored,
            options: [:]
        )

        do {
            try handler.perform([request])
        } catch {
            return Result(pose: nil, processingMilliseconds: elapsed(since: start), uprightImageSize: uprightSize)
        }

        guard let observation = request.results?.first else {
            return Result(pose: nil, processingMilliseconds: elapsed(since: start), uprightImageSize: uprightSize)
        }

        let pose = makePose(from: observation)
        return Result(pose: pose, processingMilliseconds: elapsed(since: start), uprightImageSize: uprightSize)
    }

    private func makePose(from observation: VNHumanHandPoseObservation) -> HandPose? {
        guard let recognized = try? observation.recognizedPoints(.all) else { return nil }

        var joints: [VNHumanHandPoseObservation.JointName: HandPose.Joint] = [:]
        for (name, point) in recognized where point.confidence >= Self.minimumConfidence {
            joints[name] = HandPose.Joint(
                location: point.location,
                confidence: point.confidence
            )
        }
        return joints.isEmpty ? nil : HandPose(joints: joints)
    }

    private func elapsed(since start: CFAbsoluteTime) -> Double {
        (CFAbsoluteTimeGetCurrent() - start) * 1000
    }
}
