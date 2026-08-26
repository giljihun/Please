//
//  VisionCoordinateMapper.swift
//  Please
//
//  Created by 길지훈 on 8/26/26.
//

import CoreGraphics

/// Vision 정규화 좌표(정립 이미지 기준, 좌하단 원점) → 화면 좌표 변환기.
///
/// 프리뷰 레이어의 `layerPointConverted`를 쓰지 않는 이유: 그 메서드는
/// "회전·미러링이 적용되지 않은 원본 버퍼" 좌표를 기대한다. 감지기가 이미
/// 정립 방향(.leftMirrored)으로 인식했으므로 그대로 넘기면 보정이 두 번 걸린다.
///
/// 대신 프리뷰와 동일한 aspectFill 규칙(짧은 변을 채우고 넘치는 쪽은 잘라냄)을
/// 직접 재현한다 — 프리뷰가 videoGravity = .resizeAspectFill이므로 결과가 일치한다.
///
/// 별도 타입으로 분리한 이유: 스켈레톤 오버레이와 제스처 드로잉이 반드시 같은 변환을
/// 써야 하기 때문. 둘이 다른 좌표를 보면 "링이 가리키는 곳"과 "선이 그려지는 곳"이 어긋난다
struct VisionCoordinateMapper {

    /// 감지에 쓰인 정립 이미지 크기 (세로 모드에서 버퍼는 누워 있으므로 폭·높이가 뒤바뀐 값)
    let imageSize: CGSize

    /// 표시 대상 뷰의 크기
    let viewSize: CGSize

    func screenPoint(_ normalized: CGPoint) -> CGPoint? {
        guard imageSize.width > 0, imageSize.height > 0,
              viewSize.width > 0, viewSize.height > 0 else { return nil }

        // aspectFill: 두 축 중 더 큰 배율을 택해야 여백 없이 채워진다
        let scale = max(viewSize.width / imageSize.width, viewSize.height / imageSize.height)
        let scaledSize = CGSize(
            width: imageSize.width * scale,
            height: imageSize.height * scale
        )
        // 크롭으로 잘려나간 만큼을 좌우·상하 대칭으로 보정
        let offset = CGPoint(
            x: (viewSize.width - scaledSize.width) / 2,
            y: (viewSize.height - scaledSize.height) / 2
        )

        return CGPoint(
            x: normalized.x * scaledSize.width + offset.x,
            y: (1 - normalized.y) * scaledSize.height + offset.y  // Vision은 좌하단 원점
        )
    }
}
