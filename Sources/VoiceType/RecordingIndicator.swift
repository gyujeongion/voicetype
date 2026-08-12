import AppKit
import SwiftUI
import VoiceTypeCore

/// 화면 상단 중앙에 떠 있는 녹음 인디케이터. 디자인은 설정(IndicatorStyle)에서 선택.
@MainActor
final class RecordingIndicatorController {
    private var panel: NSPanel?
    private var host: NSHostingView<RecordingIndicatorView>?
    private let model = IndicatorModel()

    func show() {
        guard model.style != .off else { hide(); return }
        if panel == nil { build() }
        model.level = 0
        resizeToFit()
        reposition()
        panel?.orderFrontRegardless()
    }

    func hide() {
        panel?.orderOut(nil)
    }

    func setLevel(_ level: Float) { model.level = level }
    func setCaption(_ text: String) { model.caption = text }
    func setMode(_ mode: IndicatorModel.Mode) { model.mode = mode }
    func setSecondaryLevel(_ level: Float) { model.secondaryLevel = level }
    func setShowsSecondaryLevel(_ shows: Bool) { model.showsSecondaryLevel = shows }

    /// 경과 초를 mm:ss(1시간 넘으면 h:mm:ss)로 표시한다. 0이면 숨긴다.
    func setElapsed(_ seconds: Double) {
        guard seconds > 0 else { model.elapsedText = ""; return }
        let t = Int(seconds)
        let h = t / 3600, m = (t % 3600) / 60, sec = t % 60
        model.elapsedText = h > 0
            ? String(format: "%d:%02d:%02d", h, m, sec)
            : String(format: "%02d:%02d", m, sec)
    }

    /// 디자인 전환. 떠 있는 상태면 즉시 새 크기로 다시 그린다.
    func setStyle(_ style: IndicatorStyle) {
        guard model.style != style else { return }
        model.style = style
        if panel?.isVisible == true {
            if style == .off { hide() } else { resizeToFit(); reposition() }
        }
    }

    private func build() {
        let host = NSHostingView(rootView: RecordingIndicatorView(model: model))
        host.frame = NSRect(x: 0, y: 0, width: 200, height: 36)
        let p = NSPanel(contentRect: host.frame,
                        styleMask: [.borderless, .nonactivatingPanel],
                        backing: .buffered, defer: false)
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = model.style != .minimal   // 미니멀은 그림자 없이 더 은은하게
        p.level = .statusBar
        p.ignoresMouseEvents = true
        p.hidesOnDeactivate = false   // 다른 앱에 포커스가 있어도 계속 표시 (받아쓰기 핵심)
        p.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        p.contentView = host
        panel = p
        self.host = host
    }

    /// 현재 디자인의 고유 크기에 맞춰 패널 크기를 조정한다.
    private func resizeToFit() {
        guard let host = host, let panel = panel else { return }
        panel.hasShadow = model.style != .minimal
        host.layoutSubtreeIfNeeded()
        var size = host.fittingSize
        if size.width < 2 || size.height < 2 { size = CGSize(width: 200, height: 36) }
        host.frame = NSRect(origin: .zero, size: size)
        panel.setContentSize(size)
    }

    /// 메뉴바 영역 정중앙에 배치 (마우스가 있는 화면 기준)
    private func reposition() {
        guard let panel = panel else { return }
        let screen = NSScreen.screens.first(where: { $0.frame.contains(NSEvent.mouseLocation) })
            ?? NSScreen.main
        guard let screen = screen else { return }
        let sf = screen.frame
        let vf = screen.visibleFrame   // 메뉴바 제외 영역
        let size = panel.frame.size
        let x = sf.midX - size.width / 2
        // 메뉴바 바로 아래 중앙 — 노치(중앙 상단)에 가리지 않도록
        let y = vf.maxY - size.height - (model.style == .minimal ? 0 : 6)
        panel.setFrame(NSRect(x: x, y: y, width: size.width, height: size.height), display: true)
    }
}

@MainActor
final class IndicatorModel: ObservableObject {
    enum Mode { case recording, processing }
    @Published var level: Float = 0
    @Published var caption: String = "녹음 중"
    @Published var mode: Mode = .recording
    @Published var style: IndicatorStyle = .waveform
    /// 시스템 오디오 레벨 (0~1). 녹음 모드에서 두 번째 막대로 표시.
    @Published var secondaryLevel: Float = 0
    /// 보조 레벨 막대를 표시할지 (시스템 오디오 트랙이 실제로 붙었을 때만 true)
    @Published var showsSecondaryLevel: Bool = false
    /// 경과 시간 표시 문자열. 빈 문자열이면 표시하지 않는다.
    @Published var elapsedText: String = ""
}

private struct RecordingIndicatorView: View {
    @ObservedObject var model: IndicatorModel

    var body: some View {
        if model.style == .off {
            EmptyView()
        } else {
            // 녹음 부가 정보(경과 시간·시스템 오디오 레벨)는 스타일 5종 공통으로 여기서 붙인다.
            // 각 스타일 뷰를 따로 고치면 5곳이 어긋나기 쉽다.
            HStack(spacing: 8) {
                styleView
                if !model.elapsedText.isEmpty {
                    Text(model.elapsedText)
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                if model.showsSecondaryLevel {
                    // 시스템 오디오 레벨. 마이크 막대와 구분되게 파란 계열.
                    Capsule()
                        .fill(Color.blue.opacity(0.75))
                        .frame(width: 3, height: 4 + CGFloat(norm(model.secondaryLevel)) * 12)
                        .help("컴퓨터 소리")
                }
            }
        }
    }

    @ViewBuilder
    private var styleView: some View {
        switch model.style {
        case .classic:  ClassicIndicator(model: model)
        case .waveform: WaveformIndicator(model: model)
        case .aurora:   AuroraIndicator(model: model)
        case .orb:      OrbIndicator(model: model)
        case .minimal:  MinimalIndicator(model: model)
        case .off:      EmptyView()
        }
    }
}

// MARK: - 헤드리스 렌더 (디스플레이 세션 없이 실제 픽셀 검증용)

@MainActor
enum IndicatorRenderer {
    /// 어두운 배경 위에 지정 스타일을 그려 NSImage로 반환. WindowServer 불필요.
    static func image(style: IndicatorStyle,
                      level: Float = 0.5,
                      mode: IndicatorModel.Mode = .recording) -> NSImage? {
        let model = IndicatorModel()
        model.style = style
        model.level = level
        model.mode = mode
        let content = ZStack {
            Color(red: 0.10, green: 0.12, blue: 0.16)   // 다크 데스크톱 근사
            RecordingIndicatorView(model: model).padding(24)
        }
        .fixedSize()
        let renderer = ImageRenderer(content: content)
        renderer.scale = 2
        return renderer.nsImage
    }
}

// MARK: - 공통 헬퍼

/// 마이크 RMS(대략 0~0.15)를 0~1로 정규화
private func norm(_ level: Float) -> Double {
    Double(min(max(level * 6.0, 0.04), 1.0))
}

// MARK: - Classic (기존)

private struct ClassicIndicator: View {
    @ObservedObject var model: IndicatorModel
    @State private var pulse = false

    var body: some View {
        HStack(spacing: 8) {
            switch model.mode {
            case .recording:
                Circle()
                    .fill(Color.red)
                    .frame(width: 8, height: 8)
                    .opacity(pulse ? 1.0 : 0.35)
                    .animation(.easeInOut(duration: 0.6).repeatForever(autoreverses: true), value: pulse)
                    .onAppear { pulse = true }
            case .processing:
                ProgressView()
                    .controlSize(.small)
                    .scaleEffect(0.7)
                    .frame(width: 10, height: 10)
            }

            Text(model.caption)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.white)
                .fixedSize()

            if model.mode == .recording {
                LevelBars(level: model.level)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(Capsule(style: .continuous).fill(Color.black.opacity(0.82)))
        .overlay(Capsule(style: .continuous).strokeBorder(Color.white.opacity(0.12), lineWidth: 0.5))
    }
}

/// 마이크 입력 레벨에 반응하는 막대 미터 (Classic 전용)
private struct LevelBars: View {
    let level: Float
    private let count = 9

    var body: some View {
        HStack(spacing: 2.5) {
            ForEach(0..<count, id: \.self) { i in
                Capsule()
                    .fill(Color.white.opacity(0.9))
                    .frame(width: 2.5, height: barHeight(i))
            }
        }
        .frame(height: 16)
        .animation(.easeOut(duration: 0.08), value: level)
    }

    private func barHeight(_ i: Int) -> CGFloat {
        let center = Double(count - 1) / 2.0
        let dist = abs(Double(i) - center) / center      // 0(중앙)~1(가장자리)
        let bell = 1.0 - dist * 0.55                      // 가운데가 높은 종 모양
        let gained = CGFloat(norm(level))
        return 3 + 13 * gained * bell
    }
}

// MARK: - Waveform (슬림 파형)

private struct WaveformIndicator: View {
    @ObservedObject var model: IndicatorModel

    var body: some View {
        WaveBars(level: model.level, processing: model.mode == .processing)
            .frame(width: 98, height: 18)
            .padding(.horizontal, 14)
            .padding(.vertical, 7)
            .background(Capsule(style: .continuous).fill(Color.black.opacity(0.78)))
            .overlay(Capsule(style: .continuous).strokeBorder(Color.white.opacity(0.10), lineWidth: 0.5))
    }
}

private struct WaveBars: View {
    let level: Float
    let processing: Bool
    private let count = 15

    var body: some View {
        TimelineView(.animation) { ctx in
            let t = ctx.date.timeIntervalSinceReferenceDate
            HStack(spacing: 2) {
                ForEach(0..<count, id: \.self) { i in
                    Capsule()
                        .fill(Color.white.opacity(processing ? 0.5 : 0.92))
                        .frame(width: 2, height: height(i, t))
                }
            }
        }
    }

    private func height(_ i: Int, _ t: Double) -> CGFloat {
        let center = Double(count - 1) / 2.0
        let dist = abs(Double(i) - center) / center
        let bell = 1.0 - dist * 0.5
        let wobble = 0.5 + 0.5 * sin(t * 6.0 + Double(i) * 0.7)   // 바마다 살아있는 흔들림
        let amp = processing ? 0.28 : (0.15 + 0.85 * norm(level))
        return 3 + CGFloat(15.0 * amp * bell * wobble)
    }
}

// MARK: - Aurora (글래스 pill + 그라데이션 글로우)

private struct AuroraIndicator: View {
    @ObservedObject var model: IndicatorModel

    var body: some View {
        TimelineView(.animation) { ctx in
            let t = ctx.date.timeIntervalSinceReferenceDate
            let lvl = norm(model.level)
            ZStack {
                Capsule(style: .continuous).fill(.ultraThinMaterial)
                Capsule(style: .continuous)
                    .fill(AngularGradient(colors: colors, center: .center, angle: .degrees(t * 90)))
                    .opacity(0.35 + 0.5 * lvl)
                    .blur(radius: 6)
                    .padding(3)
                Circle()
                    .fill(Color.white.opacity(0.9))
                    .frame(width: 6, height: 6)
                    .offset(x: 26 * cos(t * 2.2))
            }
            .frame(width: 74, height: 20)
            .clipShape(Capsule(style: .continuous))
            .overlay(Capsule(style: .continuous).strokeBorder(Color.white.opacity(0.18), lineWidth: 0.5))
        }
    }

    private var colors: [Color] {
        model.mode == .processing
            ? [.cyan, .blue, .indigo, .cyan]
            : [.pink, .purple, .blue, .cyan, .pink]
    }
}

// MARK: - Orb (숨쉬는 글로우 점)

private struct OrbIndicator: View {
    @ObservedObject var model: IndicatorModel

    var body: some View {
        TimelineView(.animation) { ctx in
            let t = ctx.date.timeIntervalSinceReferenceDate
            let lvl = CGFloat(norm(model.level))
            let breathe = 0.5 + 0.5 * sin(t * 2.0)
            let scale = 0.8 + 0.2 * CGFloat(breathe) + 0.25 * lvl
            ZStack {
                Circle()
                    .fill(RadialGradient(colors: colors, center: .center, startRadius: 0, endRadius: 14))
                    .frame(width: 16, height: 16)
                    .scaleEffect(scale)
                    .blur(radius: 3)
                    .opacity(0.7)
                Circle()
                    .fill(RadialGradient(colors: colors, center: .center, startRadius: 0, endRadius: 9))
                    .frame(width: 14, height: 14)
                    .scaleEffect(scale)
            }
            .frame(width: 34, height: 34)
        }
    }

    private var colors: [Color] {
        model.mode == .processing ? [.cyan, .blue] : [.orange, .pink, .red]
    }
}

// MARK: - Minimal (거의 안 보이는 얇은 선)

private struct MinimalIndicator: View {
    @ObservedObject var model: IndicatorModel

    var body: some View {
        TimelineView(.animation) { ctx in
            let t = ctx.date.timeIntervalSinceReferenceDate
            let lvl = norm(model.level)
            let pulse = 0.5 + 0.5 * sin(t * 2.5)
            let base = model.mode == .processing ? 0.18 : (0.12 + 0.22 * lvl)
            Capsule()
                .fill(Color.white.opacity(base * (0.6 + 0.4 * pulse)))
                .frame(width: 46 + 40 * CGFloat(lvl), height: 3)
                .padding(.horizontal, 2)
                .padding(.vertical, 2)
        }
    }
}
