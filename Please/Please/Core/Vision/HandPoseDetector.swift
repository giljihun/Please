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

    /// 신뢰도 필터를 거치지 않은 검지 끝 신뢰도 (진단 전용).
    ///
    /// joints에서 읽으면 안 되는 이유: 수집 임계(0.3) 미만인 관절은 이미 걸러졌으므로
    /// "모델이 검지를 못 찾았다"와 "찾았는데 0.3 미만이다"가 똑같이 nil이 된다.
    /// 그 둘은 대응이 정반대라(카메라 vs 임계값) 원인 분류가 통째로 틀어진다
    let rawIndexTipConfidence: Float?

    /// 손가락별 관절 연결 순서 (스켈레톤 선 그리기용).
    /// 손목에서 시작해 각 손가락 끝으로 뻗는 5개의 사슬
    static let fingerChains: [[VNHumanHandPoseObservation.JointName]] = [
        [.wrist, .thumbCMC, .thumbMP, .thumbIP, .thumbTip],
        [.wrist, .indexMCP, .indexPIP, .indexDIP, .indexTip],
        [.wrist, .middleMCP, .middlePIP, .middleDIP, .middleTip],
        [.wrist, .ringMCP, .ringPIP, .ringDIP, .ringTip],
        [.wrist, .littleMCP, .littlePIP, .littleDIP, .littleTip]
    ]

    /// 펜 끝에 요구하는 신뢰도. 그립 판정보다 엄격하다 —
    /// 펜 끝은 좌표가 곧 선의 위치라 흔들리면 획이 튀지만,
    /// 그립 판정은 두 거리의 '비율'이라 좌표가 조금 흔들려도 결론이 잘 안 바뀐다.
    /// 정밀도가 필요한 곳과 아닌 곳에 같은 잣대를 쓸 이유가 없다
    private static let penTipMinimumConfidence: Float = 0.5

    /// 펜 끝으로 삼을 지점 — 검지 끝.
    ///
    /// 엄지·검지의 중점을 쓰지 않는 이유: 획을 끊으려 엄지를 벌리는 순간 중점이
    /// 함께 밀려나 "떼는 동작 자체가 펜 끝을 움직인다" (획 끝에 꼬리가 붙음).
    /// 검지만 쓰면 엄지가 어떻게 움직이든 펜 끝은 제자리다 —
    /// 실제 펜도 검지가 방향을 잡고 엄지는 쥐었다 놨다 하는 역할만 한다
    var penTip: CGPoint? {
        guard let index = joints[.indexTip],
              index.confidence >= Self.penTipMinimumConfidence else { return nil }
        return index.location
    }

    /// 검지 끝의 신뢰도. 모델이 검지를 아예 반환하지 않았을 때만 nil이다.
    ///
    /// penTip이 nil일 때 원인을 가르기 위해 필요하다.
    /// nil이면 "모델이 검지를 못 찾았다"(카메라·조명 문제),
    /// 값이 있는데 낮으면 "찾긴 찾았는데 확신이 없다"(임계값 문제)로 대응이 갈린다
    var penTipConfidence: Float? {
        rawIndexTipConfidence
    }

    /// 그립 비율 — **엄지·검지·중지** 세 끝점이 얼마나 뭉쳐 있는지를 손 크기로 나눈 값.
    ///
    /// 이 값이 작으면 "펜을 쥔 상태"(그린다), 크면 "뗀 상태"(획 끝).
    /// 절대 거리 대신 비율을 쓰는 이유는 `gripScale(imageSize:)` 주석 참고
    ///
    /// ## 왜 두 손가락이 아니라 세 손가락인가 (2026-08-31 변경)
    ///
    /// 엄지·검지만 보면 **쥘 의도가 없는데도 그립으로 오판**하는 일이 잦았다.
    /// 원인은 손가락이 실제로 붙어서가 아니라 **투영 붕괴**다 — 손이 카메라 축과
    /// 나란해지는 순간, 3D에서 멀리 떨어진 두 점도 2D 화면에서는 거의 겹쳐 보인다.
    ///
    /// 점이 셋이면 이 붕괴가 훨씬 어렵다. 두 점이 시선과 일직선이 되는 자세는 흔하지만,
    /// 세 점이 동시에 한 점으로 뭉쳐 보이는 자세는 드물다.
    /// 게다가 엄지·검지·중지는 **실제로 마커를 쥘 때 쓰는 세 손가락**이라 은유도 맞는다.
    ///
    /// 세 점의 **최대 쌍거리**를 쓴다. 하나라도 떨어져 있으면 값이 커지므로
    /// "전부 뭉쳤을 때만 쥔 것"이 된다. 평균을 쓰면 한 손가락이 벌어져도
    /// 나머지 둘이 붙어 있어 값이 낮게 나와, 없애려던 오탐이 그대로 남는다
    func gripRatio(imageSize: CGSize) -> CGFloat? {
        guard let thumb = joints[.thumbTip],
              let index = joints[.indexTip],
              let middle = joints[.middleTip],
              let scale = gripScale(imageSize: imageSize), scale > 0 else { return nil }

        let spread = max(
            Self.pixelDistance(thumb.location, index.location, imageSize: imageSize),
            Self.pixelDistance(thumb.location, middle.location, imageSize: imageSize),
            Self.pixelDistance(index.location, middle.location, imageSize: imageSize)
        )
        return spread / scale
    }

    /// 그립 판정의 기준자 — 검지 밑동에서 검지 끝까지의 거리 (이미지 픽셀 기준).
    ///
    /// 절대 거리를 쓰면 손이 멀어질 때 오작동한다 (손 전체가 작아지므로 손을 펴도
    /// 손끝 간격이 좁게 측정됨). 기준자로 나눠 비율로 판정하면 거리와 무관해진다.
    ///
    /// 손목→중지밑동이 아니라 검지를 쓰는 이유 (2026-08-26 실기기 검증):
    /// 손을 좌우로 옮기면 **손끝은 화면 안인데 손목이 프레임 밖으로 먼저 나간다.**
    /// 손목을 요구하면 그 순간 판정 전체가 불가능해져 화면 가장자리에서 그리기가 안 됐다.
    /// 검지 밑동·끝은 엄지 끝과 함께 손끝 영역에 모여 있어 프레임에서 같이 살아남는다
    func gripScale(imageSize: CGSize) -> CGFloat? {
        guard let mcp = joints[.indexMCP], let tip = joints[.indexTip] else { return nil }
        return Self.pixelDistance(mcp.location, tip.location, imageSize: imageSize)
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
        /// 캡처 타임라인 기준 표시 시각(초).
        ///
        /// Vision 완료 시각이 아니라 프레임이 촬영된 시각을 보존해야, 처리 시간이
        /// 순간적으로 늘어도 소비자가 어느 결과가 더 최신인지 정확히 판단할 수 있다.
        let presentationTimestamp: Double
        /// 방향 보정 후의 이미지 크기. 오버레이가 화면 좌표로 변환할 때 필요하다
        /// (세로 모드에서 버퍼는 가로로 누워 있으므로 폭·높이가 뒤바뀐다)
        let uprightImageSize: CGSize
    }

    /// 이 값 미만의 관절은 버린다.
    ///
    /// 낮게 잡은 이유: 관절을 여기서 버리면 어떤 소비자도 되살릴 수 없다.
    /// 정밀도가 필요한 쪽(펜 끝)은 자기 기준으로 한 번 더 거르므로,
    /// 수집 단계는 "쓸 수 있을지도 모르는 것"까지 남겨두는 편이 낫다.
    /// 0.5로 두면 손이 프레임 가장자리에 갈 때 그립 판정용 관절까지 함께 사라진다
    private static let minimumConfidence: Float = 0.3

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
        let presentationTimestamp = CMSampleBufferGetPresentationTimeStamp(sampleBuffer).seconds

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
            return Result(
                pose: nil,
                processingMilliseconds: elapsed(since: start),
                presentationTimestamp: presentationTimestamp,
                uprightImageSize: uprightSize
            )
        }

        guard let observation = request.results?.first else {
            return Result(
                pose: nil,
                processingMilliseconds: elapsed(since: start),
                presentationTimestamp: presentationTimestamp,
                uprightImageSize: uprightSize
            )
        }

        let pose = makePose(from: observation)
        return Result(
            pose: pose,
            processingMilliseconds: elapsed(since: start),
            presentationTimestamp: presentationTimestamp,
            uprightImageSize: uprightSize
        )
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
        return joints.isEmpty ? nil : HandPose(
            joints: joints,
            // 필터 전 원본에서 읽는다 — 걸러진 뒤에는 '없음'과 '낮음'을 구분할 수 없다
            rawIndexTipConfidence: recognized[.indexTip]?.confidence
        )
    }

    /// 경과 시간(ms). 벽시계가 아니라 단조 증가 시계를 쓰는 이유:
    /// CFAbsoluteTimeGetCurrent는 NTP 동기화나 시간 변경으로 앞뒤로 튄다.
    /// 두 시점 사이의 간격을 재는 데는 언제나 단조 시계를 쓴다
    private func elapsed(since start: CFTimeInterval) -> Double {
        (CACurrentMediaTime() - start) * 1000
    }
}
