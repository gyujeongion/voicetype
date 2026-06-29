import AppKit
import SwiftUI

/// 화면 상단 중앙에 떠 있는 녹음 인디케이터 (Spokenly 스타일).
@MainActor
final class RecordingIndicatorController {
    private var panel: NSPanel?
    private let model = IndicatorModel()

    func show() {
        if panel == nil { build() }
        model.level = 0
        reposition()
        panel?.orderFrontRegardless()
    }

    func hide() {
        panel?.orderOut(nil)
    }

    func setLevel(_ level: Float) { model.level = level }
    func setCaption(_ text: String) { model.caption = text }
    func setMode(_ mode: IndicatorModel.Mode) { model.mode = mode }

    private func build() {
        let host = NSHostingView(rootView: RecordingIndicatorView(model: model))
        host.frame = NSRect(x: 0, y: 0, width: 200, height: 32)
        let p = NSPanel(contentRect: host.frame,
                        styleMask: [.borderless, .nonactivatingPanel],
                        backing: .buffered, defer: false)
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = true
        p.level = .statusBar
        p.ignoresMouseEvents = true
        p.hidesOnDeactivate = false   // 다른 앱에 포커스가 있어도 계속 표시 (받아쓰기 핵심)
        p.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        p.contentView = host
        panel = p
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
        let y = vf.maxY - size.height - 6
        panel.setFrame(NSRect(x: x, y: y, width: size.width, height: size.height), display: true)
    }
}

@MainActor
final class IndicatorModel: ObservableObject {
    enum Mode { case recording, processing }
    @Published var level: Float = 0
    @Published var caption: String = "녹음 중"
    @Published var mode: Mode = .recording
}

private struct RecordingIndicatorView: View {
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
        .background(
            Capsule(style: .continuous)
                .fill(Color.black.opacity(0.82))
        )
        .overlay(
            Capsule(style: .continuous)
                .strokeBorder(Color.white.opacity(0.12), lineWidth: 0.5)
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// 마이크 입력 레벨에 반응하는 막대 미터
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
        let gained = CGFloat(min(max(level * 6.0, 0.04), 1.0)) // RMS 게인
        return 3 + 13 * gained * bell
    }
}
