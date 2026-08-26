//
//  DrawingCanvasView.swift
//  Please
//
//  Created by 길지훈 on 8/18/26.
//

import UIKit

/// 터치 드로잉 캔버스.
///
/// 설계 근거: PencilKit 대신 커스텀 캔버스를 쓰는 이유는
/// ① 입력을 "점 시퀀스"로 추상화해야 나중에 Vision 손 좌표도 같은 경로로 주입 가능 (제스처 모드)
/// ② CGPath를 직접 보유해야 녹화 합성 시 프레임 단위 렌더링을 완전히 제어 가능
/// (PLANNING.md 5장 드로잉 엔진 결정 참고)
final class DrawingCanvasView: UIView {

    // MARK: - 그리기 설정 (외부에서 주입)

    var strokeColor: UIColor = .white {
        didSet { applyStrokeStyle() }
    }
    var strokeWidth: CGFloat = 6 {
        didSet { applyStrokeStyle() }
    }

    // MARK: - 레이어 구성
    // 완성 스트로크 / 진행 중 스트로크 / 예측 구간을 레이어로 분리:
    // 예측 터치는 다음 프레임에 실제 터치로 교체되는 "임시 그림"이라
    // 커밋된 경로와 섞이면 안 되기 때문 (섞이면 선 끝이 계속 흔들림).
    // 완성 스트로크는 "그린 시점의 스타일"을 보존해야 하므로 스트로크마다
    // 개별 레이어로 고정한다 — 한 레이어에 몰면 색을 바꿀 때 이미 그린 사인까지 바뀐다

    private var committedLayers: [CAShapeLayer] = []  // 손을 뗀 완성 선들 (스타일 고정)
    private let liveLayer = CAShapeLayer()            // 현재 그리는 선 (coalesced 반영)
    private let predictedLayer = CAShapeLayer()       // 예측 터치 미리 그리기 (지연 체감 감소)

    private var livePath = UIBezierPath()

    /// 획이 진행 중인지. 제스처 입력은 터치와 달리 began/ended가 시스템에서 보장되지 않아
    /// (손이 사라지면 endStroke가 여러 번 올 수 있다) 중복 호출을 여기서 막는다
    private var isStrokeActive = false

    // MARK: - 초기화

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
        // 두 손가락 팬 등과의 충돌 방지 — 사인은 한 손가락 전제
        isMultipleTouchEnabled = false

        for layer in [liveLayer, predictedLayer] {
            configureStrokeLayer(layer)
            self.layer.addSublayer(layer)
        }
        applyStrokeStyle()
    }

    private func configureStrokeLayer(_ layer: CAShapeLayer) {
        layer.fillColor = nil
        layer.lineCap = .round
        layer.lineJoin = .round
    }

    /// 현재 스타일은 진행 중/예측 레이어에만 적용 — 완성 레이어는 그린 시점 스타일 유지
    private func applyStrokeStyle() {
        for layer in [liveLayer, predictedLayer] {
            layer.strokeColor = strokeColor.cgColor
            layer.lineWidth = strokeWidth
        }
    }

    // MARK: - 외부 제어

    /// 캔버스 전체 지우기
    func clear() {
        for layer in committedLayers {
            layer.removeFromSuperlayer()
        }
        committedLayers.removeAll()
        isStrokeActive = false
        livePath.removeAllPoints()
        liveLayer.path = nil
        predictedLayer.path = nil
    }

    // MARK: - 스트로크 입력 (터치·제스처 공통 경로)
    // 입력을 "점 시퀀스"로 추상화한 지점. 터치든 Vision 손 좌표든 이 세 메서드로만
    // 들어오므로 캔버스는 입력원을 알 필요가 없다 (PencilKit을 버린 이유가 바로 이것)

    /// 새 획 시작
    func beginStroke(at point: CGPoint) {
        endStroke()  // 이전 획이 남아 있으면 먼저 정리 (제스처 경로의 안전장치)
        livePath = UIBezierPath()
        livePath.move(to: point)
        isStrokeActive = true
    }

    /// 진행 중인 획에 점 추가
    func appendPoint(_ point: CGPoint) {
        guard isStrokeActive else { return }
        livePath.addLine(to: point)
        liveLayer.path = livePath.cgPath
    }

    /// 진행 중인 획을 스타일이 고정된 개별 레이어로 승격하고 임시 레이어를 비운다
    func endStroke() {
        guard isStrokeActive else { return }
        isStrokeActive = false

        defer {
            livePath = UIBezierPath()
            liveLayer.path = nil
            predictedLayer.path = nil
        }
        guard !livePath.isEmpty else { return }

        // 이동 없는 단순 탭(점 찍기): 진행 폭이 0에 가까우면 극소 길이 선분을
        // 추가해 round cap이 점으로 보이게 만든다 (사인의 온점 대응).
        // 플래그 대신 경로의 기하(bounds)로 판정 — 같은 지점 재샘플에도 안전
        if livePath.bounds.width < 0.5, livePath.bounds.height < 0.5 {
            let point = livePath.currentPoint
            livePath.addLine(to: CGPoint(x: point.x + 0.1, y: point.y))
        }

        let stroke = CAShapeLayer()
        configureStrokeLayer(stroke)
        stroke.strokeColor = strokeColor.cgColor  // 그린 시점의 스타일로 고정
        stroke.lineWidth = strokeWidth
        stroke.path = livePath.cgPath
        layer.insertSublayer(stroke, below: liveLayer)
        committedLayers.append(stroke)
    }

    // MARK: - 터치 처리
    // coalescedTouches: 디스플레이 주사율(60Hz)보다 촘촘하게 샘플링된 터치(120Hz+)를
    // 모두 받아 곡선을 매끄럽게 만든다. 이걸 안 쓰면 빠른 사인에서 선이 각져 보임.
    // predictedTouches: 시스템이 예측한 미래 좌표를 미리 그려 체감 지연을 줄인다.

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let touch = touches.first else { return }
        beginStroke(at: touch.location(in: self))
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let touch = touches.first else { return }
        appendCoalescedSamples(for: touch, with: event)

        // 예측 구간은 매번 새로 그림 (이전 예측은 폐기 — 실제 터치가 이미 대체했음)
        if let predicted = event?.predictedTouches(for: touch), !predicted.isEmpty {
            let predictedPath = UIBezierPath()
            predictedPath.move(to: touch.location(in: self))
            for sample in predicted {
                predictedPath.addLine(to: sample.location(in: self))
            }
            predictedLayer.path = predictedPath.cgPath
        } else {
            predictedLayer.path = nil
        }
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        // 종료 이벤트에도 마지막 coalesced 샘플이 실려 온다 —
        // 반영하지 않으면 획의 끝부분이 잘린다
        if let touch = touches.first {
            appendCoalescedSamples(for: touch, with: event)
        }
        endStroke()
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        endStroke()
    }

    /// coalesced 샘플을 진행 중 경로에 추가 (moved/ended 공통 경로)
    private func appendCoalescedSamples(for touch: UITouch, with event: UIEvent?) {
        let coalesced = event?.coalescedTouches(for: touch) ?? [touch]
        for sample in coalesced {
            appendPoint(sample.location(in: self))
        }
    }
}
