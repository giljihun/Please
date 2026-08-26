//
//  HandPoseDetector.swift
//  Please
//
//  Created by 길지훈 on 8/23/26.
//

import Vision
import AVFoundation
import QuartzCore

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

    /// 펜 끝으로 삼을 지점 — 검지 끝.
    ///
    /// 엄지·검지의 중점을 쓰지 않는 이유: 획을 끊으려 엄지를 벌리는 순간 중점이
    /// 함께 밀려나 "떼는 동작 자체가 펜 끝을 움직인다" (획 끝에 꼬리가 붙음).
    /// 검지만 쓰면 엄지가 어떻게 움직이든 펜 끝은 제자리다 —
    /// 실제 펜도 검지가 방향을 잡고 엄지는 쥐었다 놨다 하는 역할만 한다
    var penTip: CGPoint? {
        joints[.indexTip]?.location
    }

    /// 그립 비율 — 엄지 끝과 검지 끝의 거리를 손 크기로 나눈 값.
    ///
    /// 이 값이 작으면 "펜을 쥔 상태"(그린다), 크면 "뗀 상태"(획 끝).
    /// 절대 거리 대신 비율을 쓰는 이유는 `handScale(imageSize:)` 주석 참고
    func gripRatio(imageSize: CGSize) -> CGFloat? {
        guard let thumb = joints[.thumbTip],
              let index = joints[.indexTip],
              let scale = handScale(imageSize: imageSize), scale > 0 else { return nil }

        return Self.pixelDistance(thumb.location, index.location, imageSize: imageSize) / scale
    }

    /// 손 크기 기준자 — 손목에서 중지 밑동까지의 거리 (이미지 픽셀 기준).
    ///
    /// 그립 판정에 절대 거리를 쓰면 손이 멀어질 때 오작동한다
    /// (손 전체가 작아지므로 손을 펴도 손끝 간격이 좁게 측정됨).
    /// 이 기준자로 나눠 비율로 판정하면 거리와 무관해진다 — 원거리 사용의 전제
    func handScale(imageSize: CGSize) -> CGFloat? {
        guard let wrist = joints[.wrist], let middle = joints[.middleMCP] else { return nil }
        return Self.pixelDistance(wrist.location, middle.location, imageSize: imageSize)
    }

    /// 정규화 좌표 두 점 사이의 실제 거리 (픽셀).
    ///
    /// 정규화 좌표를 그대로 hypot에 넣으면 안 되는 이유: x는 이미지 폭으로,
    /// y는 높이로 나눈 값이라 축마다 척도가 다르다. 1080×1920이면 x 0.1은 108px,
    /// y 0.1은 192px이다. 그대로 재면 **같은 길이도 손 방향에 따라 다른 값**이 나와
    /// 손을 기울이는 것만으로 그립 문턱을 넘나든다. 픽셀로 되돌린 뒤 잰다
    private static func pixelDistance(_ a: CGPoint, _ b: CGPoint, imageSize: CGSize) -> CGFloat {
        hypot((a.x - b.x) * imageSize.width, (a.y - b.y) * imageSize.height)
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

        let start = CACurrentMediaTime()

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

    /// 경과 시간(ms). 벽시계가 아니라 단조 증가 시계를 쓰는 이유:
    /// CFAbsoluteTimeGetCurrent는 NTP 동기화나 시간 변경으로 앞뒤로 튄다.
    /// 두 시점 사이의 간격을 재는 데는 언제나 단조 시계를 쓴다
    private func elapsed(since start: CFTimeInterval) -> Double {
        (CACurrentMediaTime() - start) * 1000
    }
}
