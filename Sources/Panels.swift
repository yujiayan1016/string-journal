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

/// What the editor hands back when it saves.
struct NoteEdit {
    var text: String
    var done: Set<String>
    var color: UInt32?
}

private func hexOf(_ c: Color) -> UInt32? {
    guard let n = NSColor(c).usingColorSpace(.sRGB) else { return nil }
    func b(_ v: CGFloat) -> UInt32 { UInt32(max(0, min(255, (v * 255).rounded()))) }
    return b(n.redComponent) << 16 | b(n.greenComponent) << 8 | b(n.blueComponent)
}

final class EditorModel: ObservableObject {
    struct Task: Identifiable { let id = UUID(); var text: String; var done: Bool }
    @Published var title: String
    @Published var tasks: [Task]
    @Published var color: UInt32?
    let styleColor: UInt32       // the colour the note has when it follows the look

    init(card: Card) {
        let placeholder = card.text == "新便签\n双击写点什么"
        let first = card.text.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? ""
        title = placeholder ? "" : first
        let ts = placeholder ? [] : card.tasks
        tasks = ts.isEmpty ? [Task(text: "", done: false)] : ts.map { Task(text: $0, done: card.doneTasks.contains($0)) }
        color = card.customColor
        let saved = card.customColor
        card.customColor = nil
        styleColor = card.color
        card.customColor = saved
    }

    /// Checkboxes appear as soon as there is more than one task.
    var showChecks: Bool { tasks.count > 1 }
    var paper: UInt32 { color ?? styleColor }

    @discardableResult
    func addTask(after id: UUID?) -> UUID {
        let t = Task(text: "", done: false)
        if let id, let i = tasks.firstIndex(where: { $0.id == id }) { tasks.insert(t, at: i + 1) } else { tasks.append(t) }
        return t.id
    }
    func remove(_ id: UUID) {
        tasks.removeAll { $0.id == id }
        if tasks.isEmpty { tasks = [Task(text: "", done: false)] }
    }

    func result() -> NoteEdit {
        var lines: [String] = [], done: Set<String> = []
        for t in tasks {
            // a pasted block of several lines becomes several tasks
            for l in t.text.split(separator: "\n").map({ $0.trimmingCharacters(in: .whitespaces) }) where !l.isEmpty {
                lines.append(l)
                if t.done { done.insert(l) }
            }
        }
        let head = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let text = ([head.isEmpty ? "便签" : head] + lines).joined(separator: "\n")
        return NoteEdit(text: text, done: done, color: color)
    }
}

private struct EditorView: View {
    @ObservedObject var model: EditorModel
    let done: (Bool) -> Void
    enum Field: Hashable { case title, task(UUID) }
    @FocusState private var focus: Field?

    var body: some View {
        ZStack(alignment: .top) {
            Rectangle().fill(swiftColor(model.paper))
            VStack(alignment: .leading, spacing: 10) {
                TextField("标题", text: $model.title)
                    .textFieldStyle(.plain)
                    .font(titleF(20))
                    .foregroundColor(inkColor)
                    .focused($focus, equals: .title)
                    .onSubmit { if let f = model.tasks.first { focus = .task(f.id) } }
                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(alignment: .leading, spacing: 7) {
                            ForEach($model.tasks) { $t in taskRow($t).id(t.id) }
                            Button(action: newTask) {
                                Label("新建任务", systemImage: "plus.circle.fill")
                                    .font(.system(size: 13, weight: .medium))
                                    .foregroundColor(inkColor.opacity(0.7))
                            }
                            .buttonStyle(.plain)
                            .keyboardShortcut("n", modifiers: .command)
                            .help("新建任务（⌘N）")
                            .padding(.top, 2)
                            .id("add")
                        }
                        .padding(.vertical, 2)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .onChange(of: model.tasks.count) { _ in
                        withAnimation { proxy.scrollTo("add") }
                    }
                }
                if !Theme.paperActive { swatches }
                HStack {
                    Text("↩ 下一项 · Esc 取消 · ⌘↩ 保存")
                        .font(.system(size: 11))
                        .foregroundColor(inkColor.opacity(0.5))
                    Spacer()
                    Button(action: { done(true) }) {
                        Text("保存").font(.system(size: 13, weight: .semibold)).foregroundColor(.white)
                            .padding(.horizontal, 14).padding(.vertical, 5)
                            .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(inkColor))
                    }
                    .buttonStyle(.plain)
                    .keyboardShortcut(.return, modifiers: .command)
                }
            }
            .padding(EdgeInsets(top: 24, leading: 18, bottom: 14, trailing: 18))
            if Theme.current != .sticky { Washi(color: Color(red: 0.66, green: 0.81, blue: 0.75)).offset(y: -4) }
        }
        .frame(width: 340, height: 380)
        .onExitCommand { done(false) }
        .onAppear {
            DispatchQueue.main.async {
                if model.title.isEmpty { focus = .title } else if let f = model.tasks.first { focus = .task(f.id) }
            }
        }
    }

    private func newTask() {
        let id = withAnimation(.easeOut(duration: 0.15)) { model.addTask(after: nil) }
        DispatchQueue.main.async { focus = .task(id) }
    }

    private func taskRow(_ t: Binding<EditorModel.Task>) -> some View {
        let checks = model.showChecks
        return HStack(alignment: .firstTextBaseline, spacing: 8) {
            if checks {
                Button(action: { t.wrappedValue.done.toggle() }) {
                    Image(systemName: t.wrappedValue.done ? "checkmark.square.fill" : "square")
                        .font(.system(size: 14))
                        .foregroundColor(t.wrappedValue.done ? Color(red: 0.78, green: 0.22, blue: 0.18) : inkColor.opacity(0.6))
                }
                .buttonStyle(.plain)
                .transition(.scale.combined(with: .opacity))
            }
            TextField(checks ? "任务" : "写点什么…", text: t.text, axis: .vertical)
                .textFieldStyle(.plain)
                .font(handF(16))
                .lineLimit(1...4)
                .foregroundColor(inkColor.opacity(t.wrappedValue.done && checks ? 0.45 : 1))
                .strikethrough(t.wrappedValue.done && checks, color: Color(red: 0.78, green: 0.22, blue: 0.18).opacity(0.6))
                .focused($focus, equals: .task(t.wrappedValue.id))
                .onSubmit {
                    let id = withAnimation(.easeOut(duration: 0.15)) { model.addTask(after: t.wrappedValue.id) }
                    DispatchQueue.main.async { focus = .task(id) }
                }
            if checks {
                Button(action: { let id = t.wrappedValue.id; withAnimation(.easeOut(duration: 0.15)) { model.remove(id) } }) {
                    Image(systemName: "xmark").font(.system(size: 10, weight: .semibold)).foregroundColor(inkColor.opacity(0.35))
                }
                .buttonStyle(.plain)
                .help("删除这一项")
            }
        }
    }

    private var swatches: some View {
        HStack(spacing: 7) {
            swatch(nil, fill: model.styleColor).help("跟随风格")
            ForEach(notePalette, id: \.hex) { p in swatch(p.hex, fill: p.hex).help(p.name) }
            if Theme.current != .christmas { customButton }
        }
    }

    private var customButton: some View {
            Button(action: { ColorSink.shared.open(model) }) {
                Circle()
                    .fill(AngularGradient(colors: [.red, .orange, .yellow, .green, .blue, .purple, .red], center: .center))
                    .frame(width: 18, height: 18)
                    .overlay(Circle().fill(Color.white).frame(width: 7, height: 7))
                    .padding(2)
                    .overlay(Circle().stroke(inkColor.opacity(isCustom ? 0.8 : 0), lineWidth: 1.5))
            }
            .buttonStyle(.plain)
            .help("自定义颜色")
    }

    private var isCustom: Bool {
        guard let c = model.color else { return false }
        return !notePalette.contains { $0.hex == c }
    }

    private func swatch(_ value: UInt32?, fill: UInt32) -> some View {
        let on = model.color == value
        return Button(action: { model.color = value }) {
            ZStack {
                Circle().fill(swiftColor(fill)).frame(width: 18, height: 18)
                    .overlay(Circle().stroke(Color.black.opacity(0.18), lineWidth: 0.5))
                if value == nil {   // "follow the look": a little A
                    Text("A").font(.system(size: 9, weight: .bold)).foregroundColor(inkColor.opacity(0.6))
                }
            }
            .padding(2)
            .overlay(Circle().stroke(inkColor.opacity(on ? 0.8 : 0), lineWidth: 1.5))
        }
        .buttonStyle(.plain)
    }
}

/// Routes the system colour panel to the editor that opened it.
final class ColorSink: NSObject {
    static let shared = ColorSink()
    private weak var model: EditorModel?
    func open(_ m: EditorModel) {
        model = m
        let p = NSColorPanel.shared
        p.showsAlpha = false
        p.color = NSColor(cgColor: rgb(m.paper)) ?? .yellow
        p.setTarget(self); p.setAction(#selector(changed(_:)))
        p.level = NSWindow.Level(rawValue: NSWindow.Level.floating.rawValue + 2)   // above the editor, even during the guide
        p.orderFront(nil)
    }
    @objc private func changed(_ p: NSColorPanel) {
        model?.color = hexOf(Color(nsColor: p.color))
    }
}

final class EditorController: NSObject, NSWindowDelegate {
    let panel: PaperPanel
    private let model: EditorModel
    private let onFinish: (NoteEdit?) -> Void
    private var finished = false
    private var colorObserver: Any?

    init(card: Card, anchorTop: NSPoint, within screen: NSRect, onFinish: @escaping (NoteEdit?) -> Void) {
        model = EditorModel(card: card)
        self.onFinish = onFinish
        let size = NSSize(width: 340, height: 380)
        panel = makePaperPanel(size: size)
        super.init()
        let view = EditorView(model: model) { [weak self] save in
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
        // closing the colour panel hands the keyboard back to the editor
        colorObserver = NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: NSColorPanel.shared, queue: .main) { [weak self] _ in
            guard let self, !self.finished else { return }
            self.panel.makeKeyAndOrderFront(nil)
        }
    }

    deinit { if let o = colorObserver { NotificationCenter.default.removeObserver(o) } }

    func finish(save: Bool) {
        guard !finished else { return }
        finished = true
        let edit = model.result()
        panel.orderOut(nil)
        if NSColorPanel.shared.isVisible { NSColorPanel.shared.orderOut(nil) }
        onFinish(save ? edit : nil)
    }

    // clicking elsewhere saves, like closing a notebook (but not when the colour panel takes the keyboard)
    func windowDidResignKey(_ notification: Notification) {
        DispatchQueue.main.async { [weak self] in
            guard let self, !self.finished else { return }
            if NSApp.keyWindow === NSColorPanel.shared || NSApp.keyWindow === self.panel { return }
            self.finish(save: true)
        }
    }
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

// MARK: - Guide cards

/// Native translucent background (like a macOS popover / alert).
private struct VisualEffect: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let v = NSVisualEffectView()
        v.material = .popover
        v.blendingMode = .behindWindow
        v.state = .active
        return v
    }
    func updateNSView(_ v: NSVisualEffectView, context: Context) {}
}

private struct GuideCardView: View {
    let card: GuideCard
    let icon: NSImage?
    let primary: () -> Void
    let secondary: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(card.title).font(.system(size: 22, weight: .bold))
            Text(card.lead).font(.system(size: 13)).foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true).padding(.top, 6)
            VStack(alignment: .leading, spacing: 12) {
                ForEach(Array(card.rows.enumerated()), id: \.offset) { _, row in rowView(row) }
            }
            .padding(.top, 18)
            HStack(spacing: 10) {
                Spacer(minLength: 8)
                if let label = card.secondary {
                    Button(label, action: secondary).controlSize(.large)
                }
                Button(card.primary, action: primary)
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .keyboardShortcut(.defaultAction)
            }
            .padding(.top, 22)
            if let note = card.footnote {
                Text(note).font(.system(size: 11)).foregroundColor(.secondary)
                    .frame(maxWidth: .infinity, alignment: .trailing).padding(.top, 10)
            }
        }
        .padding(EdgeInsets(top: 24, leading: 24, bottom: 20, trailing: 24))
        .frame(width: 420)
        .fixedSize(horizontal: false, vertical: true)
        .background(VisualEffect())
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(Color.primary.opacity(0.1), lineWidth: 0.5))
        .onExitCommand { card.secondary == nil ? primary() : secondary() }
    }

    private func rowView(_ row: GuideCard.Row) -> some View {
        HStack(alignment: .center, spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Color.accentColor.opacity(0.14))
                if row.usesMenuIcon, let icon {
                    Image(nsImage: icon).renderingMode(.template).foregroundColor(.accentColor)
                } else {
                    Image(systemName: row.symbol).font(.system(size: 14, weight: .medium)).foregroundColor(.accentColor)
                }
            }
            .frame(width: 30, height: 30)
            Text(row.text).font(.system(size: 13)).fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// The welcome and closing cards of the guide. They float above everything: the overlay is raised while they show.
final class GuideCardController {
    let panel: PaperPanel

    init(card: GuideCard, icon: NSImage?, on screen: NSRect, level: NSWindow.Level,
         primary: @escaping () -> Void, secondary: @escaping () -> Void) {
        panel = makePaperPanel(size: NSSize(width: 420, height: 300))
        let host = NSHostingView(rootView: GuideCardView(card: card, icon: icon, primary: primary, secondary: secondary))
        panel.contentView = host
        panel.isMovableByWindowBackground = true
        panel.level = level
        let size = host.fittingSize
        // below the rope, so the notes stay in view
        let top = max(screen.minY + size.height + 12, screen.maxY - 200)
        panel.setFrame(NSRect(x: screen.midX - size.width / 2, y: top - size.height, width: size.width, height: size.height), display: true)
    }

    func show() {
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
        panel.invalidateShadow()    // shadow follows the rounded corners
    }
    func close() { panel.orderOut(nil) }
}
