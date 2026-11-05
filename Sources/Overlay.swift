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
        registerForDraggedTypes([.fileURL])
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

    // MARK: right-click menu

    override func rightMouseDown(with e: NSEvent) {
        guard let c = world.pick(point(e)) else { return }
        let menu = NSMenu()
        if c.kind == .note {
            menu.addItem(MenuAction.item("编辑") { [weak self] in self?.world.onEdit?(c) })
        } else {
            menu.addItem(MenuAction.item("打开") { [weak self] in self?.world.onOpen?(c) })
            if c.kind == .image {
                menu.addItem(MenuAction.item("复制图片") { [weak self] in
                    if FileShortcuts.copyImage(c) { self?.world.showFlash(c, "已复制图片") }
                })
            }
            menu.addItem(MenuAction.item(c.kind == .folder ? "复制文件夹" : "复制文件") { [weak self] in
                if FileShortcuts.copyFile(c) { self?.world.showFlash(c, "已复制") }
            })
            menu.addItem(MenuAction.item("在访达中显示") { [weak self] in self?.world.onReveal?(c) })
        }
        if c.mode == .free && !world.ropeHidden {
            menu.addItem(MenuAction.item("挂回绳子") { [weak self] in self?.world.hangBack(c) })
        }
        if c.stampAt == nil {
            menu.addItem(.separator())
            menu.addItem(MenuAction.item("完成，放进漂流瓶") { [weak self] in self?.world.stamp(c) })
        }
        NSMenu.popUpContextMenu(menu, with: e, for: self)
    }

    // MARK: files dragged in from Finder

    private func dropOperation(_ info: NSDraggingInfo) -> NSDragOperation {
        let p = convert(info.draggingLocation, from: nil)
        world.ptr = p
        guard world.ropeDropOK(p) else { return [] }
        return info.draggingSourceOperationMask.contains(.link) ? .link : .copy
    }
    override func draggingEntered(_ info: NSDraggingInfo) -> NSDragOperation { dropOperation(info) }
    override func draggingUpdated(_ info: NSDraggingInfo) -> NSDragOperation { dropOperation(info) }
    override func performDragOperation(_ info: NSDraggingInfo) -> Bool {
        let p = convert(info.draggingLocation, from: nil)
        guard world.ropeDropOK(p) else { return false }
        let urls = info.draggingPasteboard.readObjects(forClasses: [NSURL.self],
                                                       options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        guard !urls.isEmpty else { return false }
        world.dropFiles(urls, at: p)
        return true
    }
}

/// NSMenuItem that runs a closure.
final class MenuAction: NSObject {
    private let run: () -> Void
    private init(_ run: @escaping () -> Void) { self.run = run }
    @objc private func fire() { run() }
    static func item(_ title: String, _ run: @escaping () -> Void) -> NSMenuItem {
        let a = MenuAction(run)
        let i = NSMenuItem(title: title, action: #selector(fire), keyEquivalent: "")
        i.target = a
        i.representedObject = a     // keeps the action alive as long as the item
        return i
    }
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
    private var wasPressed = false
    private var dragCountAtPress = 0
    private static let legacyFilenames = NSPasteboard.PasteboardType("NSFilenamesPboardType")

    var ropeHidden: Bool {
        get { UserDefaults.standard.bool(forKey: "ropeHidden") }
        set { UserDefaults.standard.set(newValue, forKey: "ropeHidden"); world.setRopeHidden(newValue) }
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
        world.onOpen = { [weak self] c in
            if !FileShortcuts.open(c) { self?.world.poke() }   // shows "找不到原文件"
        }
        world.onReveal = { c in FileShortcuts.reveal(c) }
        world.onNeedThumbnail = { [weak self] c in
            FileShortcuts.loadThumbnail(c) { self?.world.poke() }
        }
        for c in world.cards where c.kind != .note {
            FileShortcuts.resolve(c)
            world.onNeedThumbnail?(c)
        }
        world.setRopeHidden(ropeHidden)

        applyLevel()
        panel.orderFrontRegardless()

        let t = Timer(timeInterval: 1.0 / 120, repeats: true) { [weak self] _ in self?.tick() }
        RunLoop.main.add(t, forMode: .common)
        timer = t

        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            self?.reposition()
        }
    }

    // MARK: which display

    /// A key that stays the same for a monitor across unplugging and reconnecting.
    static func key(for screen: NSScreen) -> String {
        let id = (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? 0
        return "\(CGDisplayVendorNumber(id))-\(CGDisplayModelNumber(id))-\(CGDisplaySerialNumber(id))"
    }

    /// The display chosen in the menu; nil means the primary display (the one with the menu bar).
    var displayKey: String? {
        get { UserDefaults.standard.string(forKey: "displayKey") }
        set { UserDefaults.standard.set(newValue, forKey: "displayKey"); reposition() }
    }

    /// The chosen display if it is connected, otherwise the primary one.
    func targetScreen() -> NSScreen? {
        if let k = displayKey, let s = NSScreen.screens.first(where: { Self.key(for: $0) == k }) { return s }
        return NSScreen.screens.first
    }
    var currentScreenKey: String? { targetScreen().map(Self.key(for:)) }

    private func targetFrame() -> NSRect {
        targetScreen()?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1280, height: 800)
    }

    private func reposition() {
        guard panel != nil else { return }
        let f = targetFrame()
        guard f != panel.frame else { return }
        panel.setFrame(f, display: true)
        world.resize(width: f.width, height: f.height)
        scheduleSave()
    }

    /// Always on the desktop layer: above the wallpaper and icons, below every app window.
    private func applyLevel() {
        guard let panel else { return }
        panel.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopIconWindow)) + 1)
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

        // a drag that started outside this app and carries files → let it land on the rope
        let pressed = NSEvent.pressedMouseButtons & 1 != 0
        let dragBoard = NSPasteboard(name: .drag)
        if pressed && !wasPressed { dragCountAtPress = dragBoard.changeCount }
        wasPressed = pressed
        let types = (pressed && dragBoard.changeCount != dragCountAtPress) ? (dragBoard.types ?? []) : []
        world.externalDrag = pressed && world.dragging == nil
            && (types.contains(.fileURL) || types.contains(Self.legacyFilenames))

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
        else if world.hoverStamp != nil || world.hoverHangBack != nil || world.plusHit(p) || world.bottleHit(p) || world.toastButton.contains(p) { NSCursor.pointingHand.set() }
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

    func hangAllBack() {
        if ropeHidden { ropeHidden = false }   // keeps the menu setting in step
        world.hangAllBack()
    }

    var theme: Theme {
        get { Theme.current }
        set { Theme.current = newValue; world.poke(); view.needsDisplay = true }
    }

    /// Hang shortcuts without dragging onto the rope (menu bar icon drop, or the open panel).
    func addFiles(_ urls: [URL]) {
        world.addFiles(urls)
    }

    func chooseFiles() {
        let p = NSOpenPanel()
        p.canChooseFiles = true
        p.canChooseDirectories = true
        p.allowsMultipleSelection = true
        p.prompt = "挂上去"
        p.message = "选择要挂到绳子上的文件或文件夹（只挂快捷方式，原文件不会移动）"
        NSApp.activate(ignoringOtherApps: true)
        if p.runModal() == .OK { addFiles(p.urls) }
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
        let c = world.ropeHidden ? CGPoint(x: 42, y: world.anchorY + 20) : world.bottleCenter
        let anchor = screenPoint(CGPoint(x: max(12, c.x - 30), y: c.y + 46))
        let f = finishedPanel ?? FinishedController(world: world)
        finishedPanel = f
        f.show(topLeft: anchor)
    }
}
