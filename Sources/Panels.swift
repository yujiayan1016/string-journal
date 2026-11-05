import AppKit
import SwiftUI

private let inkColor = Color(red: 0x2E / 255, green: 0x34 / 255, blue: 0x48 / 255)
private func swiftColor(_ hex: UInt32) -> Color {
    Color(red: Double((hex >> 16) & 0xFF) / 255, green: Double((hex >> 8) & 0xFF) / 255, blue: Double(hex & 0xFF) / 255)
}
private func handF(_ size: CGFloat) -> Font {
    Theme.current != .sticky ? .custom("LXGWWenKaiTC-Regular", size: size) : .system(size: size - 1)
}
private func titleF(_ size: CGFloat) -> Font {
    Theme.current != .sticky ? .custom("ZCOOLKuaiLe-Regular", size: size) : .system(size: size - 1, weight: .semibold)
}

/// Borderless panel that can still take keyboard focus.
final class PaperPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

private func makePaperPanel(size: NSSize) -> PaperPanel {
    let p = PaperPanel(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered, defer: false)
    p.isOpaque = false
    p.backgroundColor = .clear
    p.hasShadow = true
    p.level = .normal
    p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
    p.isReleasedWhenClosed = false
    p.hidesOnDeactivate = false
    return p
}

/// A strip of washi tape, used as decoration on the paper panels.
private struct Washi: View {
    let color: Color
    var body: some View {
        Rectangle()
            .fill(color.opacity(0.85))
            .overlay(
                HStack(spacing: 4) { ForEach(0..<12, id: \.self) { _ in Rectangle().fill(Color.white.opacity(0.45)).frame(width: 3) } }
            )
            .clipped()
            .frame(width: 84, height: 18)
            .rotationEffect(.degrees(-3))
    }
}

// MARK: - Editor

final class EditorModel: ObservableObject {
    @Published var text: String
    init(text: String) { self.text = text }
}

private struct EditorView: View {
    @ObservedObject var model: EditorModel
    let paper: Color
    let done: (Bool) -> Void
    @FocusState private var focused: Bool

    var body: some View {
        ZStack(alignment: .top) {
            Rectangle().fill(paper)
            VStack(alignment: .leading, spacing: 8) {
                TextEditor(text: $model.text)
                    .font(handF(18))
                    .lineSpacing(5)
                    .foregroundColor(inkColor)
                    .scrollContentBackground(.hidden)
                    .background(Color.clear)
                    .focused($focused)
                HStack {
                    Text("第一行是标题 · Esc 取消 · ⌘↩ 保存")
                        .font(handF(12))
                        .foregroundColor(inkColor.opacity(0.55))
                    Spacer()
                    Button(action: { done(true) }) {
                        Text("保存").font(titleF(14)).foregroundColor(.white)
                            .padding(.horizontal, 14).padding(.vertical, 5)
                            .background(RoundedRectangle(cornerRadius: 3).fill(inkColor))
                    }
                    .buttonStyle(.plain)
                    .keyboardShortcut(.return, modifiers: .command)
                }
            }
            .padding(EdgeInsets(top: 26, leading: 18, bottom: 14, trailing: 18))
            if Theme.current != .sticky { Washi(color: Color(red: 0.66, green: 0.81, blue: 0.75)).offset(y: -4) }
        }
        .frame(width: 330, height: 270)
        .onExitCommand { done(false) }
        .onAppear { DispatchQueue.main.async { focused = true } }
    }
}

final class EditorController: NSObject, NSWindowDelegate {
    let panel: PaperPanel
    private let model: EditorModel
    private let onFinish: (String?) -> Void
    private var finished = false

    init(card: Card, anchorTop: NSPoint, within screen: NSRect, onFinish: @escaping (String?) -> Void) {
        model = EditorModel(text: card.text)
        self.onFinish = onFinish
        let size = NSSize(width: 330, height: 270)
        panel = makePaperPanel(size: size)
        super.init()
        let view = EditorView(model: model, paper: swiftColor(card.color)) { [weak self] save in
            self?.finish(save: save)
        }
        panel.contentView = NSHostingView(rootView: view)
        panel.delegate = self
        // open just under the note's top edge, kept on screen
        var origin = NSPoint(x: anchorTop.x - size.width / 2, y: anchorTop.y - size.height - 10)
        origin.x = min(max(origin.x, screen.minX + 12), screen.maxX - size.width - 12)
        origin.y = min(max(origin.y, screen.minY + 12), screen.maxY - size.height - 12)
        panel.setFrameOrigin(origin)
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
    }

    func finish(save: Bool) {
        guard !finished else { return }
        finished = true
        let text = model.text
        panel.orderOut(nil)
        onFinish(save ? text : nil)
    }

    // clicking elsewhere saves, like closing a notebook
    func windowDidResignKey(_ notification: Notification) { finish(save: true) }
}

// MARK: - Finished notes

final class FinishedModel: ObservableObject {
    @Published var items: [Card] = []
}

private struct FinishedView: View {
    @ObservedObject var model: FinishedModel
    let restore: (Card) -> Void
    let delete: (Card) -> Void
    private static let fmt: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "M月d日 HH:mm"; return f
    }()

    var body: some View {
        ZStack(alignment: .top) {
            Rectangle().fill(Color(red: 0.99, green: 0.988, blue: 0.973))
            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .firstTextBaseline) {
                    Text("已完成").font(titleF(19)).foregroundColor(inkColor)
                    Spacer()
                    Text(model.items.isEmpty ? "" : "\(model.items.count) 张").font(handF(13)).foregroundColor(inkColor.opacity(0.6))
                }
                .padding(.bottom, 2)
                Text("第二天或重启后，漂流瓶会自动清空").font(handF(11)).foregroundColor(inkColor.opacity(0.45))
                    .padding(.bottom, 8)
                if model.items.isEmpty {
                    Text("漂流瓶还是空的。勾选便签右下角的小方框、把便签拖进漂流瓶，或者用力甩出屏幕，完成的便签都会收在这里。")
                        .font(handF(14)).foregroundColor(inkColor.opacity(0.6))
                        .lineSpacing(6).fixedSize(horizontal: false, vertical: true)
                        .padding(.vertical, 6)
                } else {
                    VStack(spacing: 0) {
                        ForEach(Array(model.items.prefix(10)), id: \.id) { c in row(c) }
                    }
                    if model.items.count > 10 {
                        Text("还有 \(model.items.count - 10) 张更早的").font(handF(12))
                            .foregroundColor(inkColor.opacity(0.5)).padding(.top, 6)
                    }
                }
            }
            .padding(EdgeInsets(top: 24, leading: 18, bottom: 12, trailing: 14))
            if Theme.current != .sticky { Washi(color: Color(red: 0.95, green: 0.74, blue: 0.72)).offset(y: -4) }
        }
        .frame(width: 300)
        .fixedSize(horizontal: false, vertical: true)
    }

    private func row(_ c: Card) -> some View {
        HStack(spacing: 9) {
            Rectangle().fill(swiftColor(c.color)).frame(width: 13, height: 13)
                .shadow(color: .black.opacity(0.15), radius: 1, y: 1)
            VStack(alignment: .leading, spacing: 1) {
                Text(c.title).font(handF(16)).foregroundColor(inkColor)
                    .strikethrough(true, color: Color(red: 0.78, green: 0.22, blue: 0.18).opacity(0.6))
                    .lineLimit(1)
                if let d = c.doneAt {
                    Text(Self.fmt.string(from: d)).font(.system(size: 10)).foregroundColor(inkColor.opacity(0.5))
                }
            }
            Spacer(minLength: 4)
            Button(action: { restore(c) }) {
                Text("挂回").font(titleF(13)).foregroundColor(inkColor)
                    .padding(.horizontal, 9).padding(.vertical, 3)
                    .background(RoundedRectangle(cornerRadius: 3).fill(Color(red: 0.97, green: 0.85, blue: 0.84)))
            }.buttonStyle(.plain)
            Button(action: { delete(c) }) {
                Image(systemName: "trash").font(.system(size: 11)).foregroundColor(inkColor.opacity(0.45))
            }.buttonStyle(.plain).help("永久删除")
        }
        .padding(.vertical, 7)
        .overlay(Rectangle().fill(Color(red: 0.37, green: 0.55, blue: 0.73).opacity(0.22)).frame(height: 1), alignment: .bottom)
    }
}

final class FinishedController: NSObject, NSWindowDelegate {
    let panel: PaperPanel
    private let model = FinishedModel()
    private weak var world: World?
    private var host: NSHostingView<AnyView>?

    init(world: World) {
        self.world = world
        panel = makePaperPanel(size: NSSize(width: 300, height: 200))
        super.init()
        let view = FinishedView(model: model, restore: { [weak world] c in world?.restore(c) },
                                delete: { [weak world] c in world?.deleteFinished(c) })
        let h = NSHostingView(rootView: AnyView(view))
        host = h
        panel.contentView = h
        panel.delegate = self
    }

    func refresh() {
        model.items = world?.finished ?? []
        guard panel.isVisible, let h = host else { return }
        let size = h.fittingSize
        let top = panel.frame.maxY   // keep the top edge where it hangs, grow downward
        panel.setFrame(NSRect(x: panel.frame.minX, y: top - size.height, width: size.width, height: size.height), display: true)
    }

    func show(topLeft: NSPoint) {
        model.items = world?.finished ?? []
        let size = host?.fittingSize ?? NSSize(width: 300, height: 200)
        panel.setFrame(NSRect(x: topLeft.x, y: topLeft.y - size.height, width: size.width, height: size.height), display: true)
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
    }

    func close() { panel.orderOut(nil) }
    func windowDidResignKey(_ notification: Notification) { close() }
}
