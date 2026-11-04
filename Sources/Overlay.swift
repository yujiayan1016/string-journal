import AppKit
import QuartzCore

/// Transparent, borderless panel covering the screen's visible area.
/// It only takes the mouse while the pointer is over a note, the drift bottle, the "+" tag or the undo strip.
final class OverlayPanel: NSPanel {
    init(frame: NSRect) {
        super.init(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
        hidesOnDeactivate = false
        isMovable = false
        becomesKeyOnlyIfNeeded = true
        ignoresMouseEvents = true
        isReleasedWhenClosed = false
    }
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

final class OverlayView: NSView {
    let world: World

    init(world: World) {
        self.world = world
        super.init(frame: .zero)
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override var isFlipped: Bool { true }
    override var isOpaque: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        ctx.clear(bounds)
        Renderer(ctx: ctx, world: world).drawAll()
    }

    private func point(_ e: NSEvent) -> CGPoint { convert(e.locationInWindow, from: nil) }
    override func mouseDown(with e: NSEvent) { world.pointerDown(point(e), clickCount: e.clickCount); world.poke() }
    override func mouseDragged(with e: NSEvent) { world.pointerDragged(point(e)) }
    override func mouseUp(with e: NSEvent) { world.pointerUp(point(e)) }
}

final class OverlayController {
    let world = World()
    let store = Store()
    private(set) var panel: OverlayPanel!
    private var view: OverlayView!
    private var timer: Timer?
    private var last = CACurrentMediaTime()
    private var saveWork: DispatchWorkItem?
    private var editor: EditorController?
    private var finishedPanel: FinishedController?
    private var cursorOwned = false
    private var today = Calendar.current.startOfDay(for: Date())
    private var lastDayCheck = CACurrentMediaTime()

    var floatAbove: Bool {
        get { UserDefaults.standard.object(forKey: "floatAbove") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "floatAbove"); applyLevel() }
    }

    func start() {
        let frame = targetFrame()
        panel = OverlayPanel(frame: frame)
        view = OverlayView(world: world)
        view.frame = NSRect(origin: .zero, size: frame.size)
        view.autoresizingMask = [.width, .height]
        panel.contentView = view
        world.resize(width: frame.width, height: frame.height)
        if let book = store.load() { world.load(book) } else { world.seedWelcome(); scheduleSave() }

        world.onChange = { [weak self] in self?.scheduleSave(); self?.finishedPanel?.refresh() }
        world.onEdit = { [weak self] card in self?.openEditor(card) }
        world.onOpenFinished = { [weak self] in self?.toggleFinished() }

        applyLevel()
        panel.orderFrontRegardless()

        let t = Timer(timeInterval: 1.0 / 120, repeats: true) { [weak self] _ in self?.tick() }
        RunLoop.main.add(t, forMode: .common)
        timer = t

        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            self?.reposition()
        }
    }

    private func targetFrame() -> NSRect {
        (NSScreen.main ?? NSScreen.screens.first)?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1280, height: 800)
    }

    private func reposition() {
        let f = targetFrame()
        panel.setFrame(f, display: true)
        world.resize(width: f.width, height: f.height)
    }

    private func applyLevel() {
        guard let panel else { return }
        if floatAbove {
            panel.level = .floating
        } else {
            panel.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopIconWindow)) + 1)
        }
        panel.orderFrontRegardless()
    }

    // MARK: loop

    private func tick() {
        let now = CACurrentMediaTime()
        let dt = now - last
        last = now

        let wp = panel.convertPoint(fromScreen: NSEvent.mouseLocation)
        let vp = view.convert(wp, from: nil)
        world.ptr = vp
        world.updateHover()
        world.advance(dt)

        // the drift bottle empties itself when a new day starts
        if now - lastDayCheck > 5 {
            lastDayCheck = now
            let d = Calendar.current.startOfDay(for: Date())
            if d != today { today = d; world.clearFinished() }
        }

        let wants = world.wantsMouse(at: vp)
        if panel.ignoresMouseEvents == wants { panel.ignoresMouseEvents = !wants }
        updateCursor(wants: wants, at: vp)

        if world.needsRedraw { view.needsDisplay = true }
    }

    private func updateCursor(wants: Bool, at p: CGPoint) {
        guard wants else {
            if cursorOwned { NSCursor.arrow.set(); cursorOwned = false }
            return
        }
        cursorOwned = true
        if world.dragging != nil { NSCursor.closedHand.set() }
        else if world.hoverStamp != nil || world.plusHit(p) || world.bottleHit(p) || world.toastButton.contains(p) { NSCursor.pointingHand.set() }
        else if world.hoverCard != nil { NSCursor.openHand.set() }
        else { NSCursor.arrow.set() }
    }

    // MARK: saving

    func scheduleSave() {
        saveWork?.cancel()
        let w = DispatchWorkItem { [weak self] in self?.saveNow() }
        saveWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6, execute: w)
    }
    func saveNow() { store.save(world.book()) }

    // MARK: panels

    func newNote() {
        world.addNote()
    }

    private func screenPoint(_ p: CGPoint) -> NSPoint {
        panel.convertPoint(toScreen: view.convert(p, to: nil))
    }

    func openEditor(_ card: Card) {
        editor?.finish(save: true)
        let anchor = screenPoint(CGPoint(x: card.center.x, y: card.center.y - card.h / 2))
        editor = EditorController(card: card, anchorTop: anchor, within: panel.frame) { [weak self] text in
            guard let self else { return }
            if let text { self.world.edited(card, text: text) }
            self.editor = nil
        }
    }

    func toggleFinished() {
        if let f = finishedPanel, f.panel.isVisible { f.close(); return }
        let c = world.bottleCenter
        let anchor = screenPoint(CGPoint(x: max(12, c.x - 30), y: c.y + 46))
        let f = finishedPanel ?? FinishedController(world: world)
        finishedPanel = f
        f.show(topLeft: anchor)
    }
}
