import AppKit
import SwiftUI

/// 화면 상단(녹음 인디케이터 아래)에 잠깐 떴다 사라지는 비차단 알림.
///
/// NSAlert.runModal은 메뉴바 앱에서 다른 앱 뒤에 숨거나, 떠 있는 동안 메인 런루프를 모달 모드로
/// 묶어 타이머가 멈춘다. "녹음이 저장됐습니다" 같은 안내까지 확인 버튼을 누르게 하는 건 과하다.
/// 조치가 필요한 권한 오류만 AppDelegate.notifyActionable(창)로 가고, 나머지는 전부 여기로 온다.
@MainActor
final class ToastController {
    static let shared = ToastController()

    enum Kind { case info, warning }

    private var panel: NSPanel?
    private let model = ToastModel()
    private var hideWork: DispatchWorkItem?

    func show(_ message: String, kind: Kind = .info) {
        let text = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        if panel == nil { build() }
        model.message = text
        model.kind = kind
        resizeAndPosition()
        panel?.alphaValue = 1
        panel?.orderFrontRegardless()

        // 읽을 시간: 기본 3.5초(경고 6초) + 글자 수 비례, 최대 12초
        let base: Double = kind == .warning ? 6 : 3.5
        let duration = min(12, base + Double(text.count) / 25)
        hideWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.hide() }
        }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + duration, execute: work)
    }

    func hide() {
        hideWork?.cancel()
        hideWork = nil
        guard let panel = panel, panel.isVisible else { return }
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.2
            panel.animator().alphaValue = 0
        }, completionHandler: {
            MainActor.assumeIsolated { panel.orderOut(nil) }
        })
    }

    private func build() {
        let host = NSHostingView(rootView: ToastView(model: model, onTap: { [weak self] in self?.hide() }))
        let p = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 320, height: 44),
                        styleMask: [.borderless, .nonactivatingPanel],
                        backing: .buffered, defer: false)
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = true
        p.level = .statusBar
        p.hidesOnDeactivate = false   // 다른 앱이 포커스여도 보여야 한다 (메뉴바 앱의 기본 상황)
        p.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        p.contentView = host
        panel = p
    }

    private func resizeAndPosition() {
        guard let panel = panel, let host = panel.contentView else { return }
        host.layoutSubtreeIfNeeded()
        var size = host.fittingSize
        if size.width < 10 || size.height < 10 { size = CGSize(width: 320, height: 44) }
        let screen = NSScreen.screens.first(where: { $0.frame.contains(NSEvent.mouseLocation) }) ?? NSScreen.main
        guard let vf = screen?.visibleFrame, let sf = screen?.frame else { return }
        // 녹음 인디케이터(메뉴바 바로 아래)와 겹치지 않게 그 아래쪽에 둔다
        let x = sf.midX - size.width / 2
        let y = vf.maxY - size.height - 52
        panel.setFrame(NSRect(x: x, y: y, width: size.width, height: size.height), display: true)
    }
}

@MainActor
final class ToastModel: ObservableObject {
    @Published var message = ""
    @Published var kind: ToastController.Kind = .info
}

struct ToastView: View {
    @ObservedObject var model: ToastModel
    var onTap: () -> Void = {}

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: model.kind == .warning ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                .foregroundStyle(model.kind == .warning ? Color.orange : Color.green)
                .font(.system(size: 15))
            Text(model.message)
                .font(.system(size: 13))
                .foregroundStyle(.white)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 420, alignment: .leading)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.black.opacity(0.85)))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Color.white.opacity(0.12), lineWidth: 0.5))
        .fixedSize()
        .contentShape(Rectangle())
        .onTapGesture { onTap() }
    }
}

/// 헤드리스 렌더 (WindowServer 없이 픽셀 검증). `VoiceType --render-toast <폴더>`
@MainActor
enum ToastRenderer {
    static func renderAll(to dir: String) -> [String] {
        let samples: [(String, ToastController.Kind, String)] = [
            ("info", .info, "녹음이 저장됐습니다. 설정 > 히스토리에서 확인하세요."),
            ("warning", .warning, "'영어 번역' 후처리에 실패해 원문을 붙여넣었습니다.\n모델명 'gemini-x'을 찾을 수 없습니다. 모델명을 확인하세요."),
        ]
        var written: [String] = []
        for (name, kind, text) in samples {
            let model = ToastModel()
            model.message = text
            model.kind = kind
            let content = ZStack {
                Color(red: 0.93, green: 0.94, blue: 0.96)   // 밝은 데스크톱 근사
                ToastView(model: model).padding(24)
            }.fixedSize()
            let renderer = ImageRenderer(content: content)
            renderer.scale = 2
            guard let img = renderer.nsImage, let tiff = img.tiffRepresentation,
                  let rep = NSBitmapImageRep(data: tiff),
                  let png = rep.representation(using: .png, properties: [:]) else { continue }
            let path = (dir as NSString).appendingPathComponent("toast_\(name).png")
            if (try? png.write(to: URL(fileURLWithPath: path))) != nil { written.append(path) }
        }
        return written
    }
}
