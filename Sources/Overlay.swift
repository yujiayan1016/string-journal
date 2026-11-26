import AppKit
import UniformTypeIdentifiers
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

final class OverlayView: NSView, NSDraggingSource {
    let world: World
    /// The stand-in file carried by a drag to the Trash, and the folder it lives in.
    private var trashFile: URL?

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
    override func mouseDragged(with e: NSEvent) {
        world.pointerDragged(point(e))
        // a note pulled past the edge where the Dock is becomes a real drag, so it can be dropped on the Trash
        if let c = world.dragging, let f = window?.frame, Self.dockDistance(NSEvent.mouseLocation, in: f) <= 1 {
            beginTrashDrag(c, event: e)
        }
    }
    override func mouseUp(with e: NSEvent) { world.pointerUp(point(e)) }

    // MARK: drag to the Trash

    /// Which side of the screen the Dock is on (System Settings → Desktop & Dock).
    static func dockEdge() -> NSRectEdge {
        switch UserDefaults(suiteName: "com.apple.dock")?.string(forKey: "orientation") {
        case "left": return .minX
        case "right": return .maxX
        default: return .minY
        }
    }

    /// How far a screen point is from the overlay's edge on the Dock side (≤ 0 once past it).
    static func dockDistance(_ sp: NSPoint, in f: NSRect) -> CGFloat {
        switch dockEdge() {
        case .minX: return sp.x - f.minX
        case .maxX: return f.maxX - sp.x
        default: return sp.y - f.minY
        }
    }

    /// A plain-text copy of the note: it is what lands in the Trash, so a note deleted by mistake can still be read.
    static func writeStandIn(for c: Card) -> URL? {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("StringJournal-Trash", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var name = c.title.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
        if name.count > 60 { name = String(name.prefix(60)) }
        if c.kind != .note { name += "（快捷方式）" }
        let url = dir.appendingPathComponent(name + ".txt")
        var body = c.text
        if c.kind != .note, let path = c.url?.path { body += "\n\n绳上手帐里的快捷方式，原文件没有被删除：\n" + path }
        do { try body.write(to: url, atomically: true, encoding: .utf8) } catch { return nil }
        return url
    }

    private func beginTrashDrag(_ c: Card, event e: NSEvent) {
        guard trashFile == nil, let url = Self.writeStandIn(for: c) else { return }
        // picture of the note as it looks right now
        let cc = c.center
        let side = ceil(hypot2(c.w, c.h) * max(1, c.sc)) + 50
        let img = NSImage(size: NSSize(width: side, height: side), flipped: true) { [world] _ in
            guard let ctx = NSGraphicsContext.current?.cgContext else { return false }
            ctx.translateBy(x: side / 2 - cc.x, y: side / 2 - cc.y)
            let r = Renderer(ctx: ctx, world: world)
            r.drawPaper(c, lift: 2); r.drawAttach(c)
            return true
        }
        guard world.liftForSystemDrag() != nil else { return }
        trashFile = url
        let item = NSDraggingItem(pasteboardWriter: url as NSURL)
        item.setDraggingFrame(NSRect(x: cc.x - side / 2, y: cc.y - side / 2, width: side, height: side), contents: img)
        let session = beginDraggingSession(with: [item], event: e, source: self)
        session.animatesToStartingPositionsOnCancelOrFail = false
    }

    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        // only the Trash (delete) or a copy elsewhere; never back onto our own rope as a "file"
        context == .outsideApplication ? [.copy, .delete] : []
    }

    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        guard let url = trashFile else { return }
        trashFile = nil
        let deleted = operation == .delete || !FileManager.default.fileExists(atPath: url.path)
        var p = CGPoint(x: bounds.midX, y: bounds.maxY - 80)
        if let w = window { p = convert(w.convertPoint(fromScreen: screenPoint), from: nil) }
        world.endSystemDrag(deleted: deleted, at: p)
        try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
    }

    // MARK: right-click menu

    override func rightMouseDown(with e: NSEvent) {
        guard let c = world.pick(point(e)) else { return }
        let menu = NSMenu()
        if c.kind == .note {
            menu.addItem(MenuAction.item("编辑") { [weak self] in self?.world.onEdit?(c) })
            menu.addItem(MenuAction.item("复制文字") { [weak self] in
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(c.text, forType: .string)
                self?.world.showFlash(c, "已复制文字")
            })
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
        if c.kind == .note && !Theme.paperActive {
            let colors = NSMenuItem(title: "颜色", action: nil, keyEquivalent: "")
            let sub = NSMenu()
            let auto = MenuAction.item("跟随风格") { [weak self] in self?.world.setColor(c, nil) }
            auto.state = c.customColor.map { cc in Theme.current == .christmas && !christmasPalette.contains { $0.hex == cc } } ?? true ? .on : .off
            sub.addItem(auto); sub.addItem(.separator())
            for p in notePalette {
                let it = MenuAction.item(p.name) { [weak self] in self?.world.setColor(c, p.hex) }
                it.image = Self.swatchImage(p.hex)
                it.state = c.customColor == p.hex ? .on : .off
                sub.addItem(it)
            }
            if Theme.current != .christmas {
                sub.addItem(.separator())
                sub.addItem(MenuAction.item("自定义…（在编辑框里选）") { [weak self] in self?.world.onEdit?(c) })
            }
            colors.submenu = sub
            menu.addItem(colors)
        }
        if c.kind == .note && !Theme.paperActive {
            let sizes = NSMenuItem(title: "大小", action: nil, keyEquivalent: "")
            let sub = NSMenu()
            for z in NoteSize.allCases {
                let it = MenuAction.item(z.name) { [weak self] in self?.world.setSize(c, z) }
                it.state = c.noteSize == z ? .on : .off
                sub.addItem(it)
            }
            sizes.submenu = sub
            menu.addItem(sizes)
        }
        menu.addItem(.separator())
        menu.addItem(MenuAction.item(c.kind == .note ? "扔进废纸篓" : "取下快捷方式（原文件不动）") { [weak self] in
            self?.world.throwInTrash(c)
        })
        NSMenu.popUpContextMenu(menu, with: e, for: self)
    }

    static func swatchImage(_ hex: UInt32) -> NSImage {
        NSImage(size: NSSize(width: 12, height: 12), flipped: false) { r in
            let p = NSBezierPath(ovalIn: r.insetBy(dx: 0.5, dy: 0.5))
            NSColor(cgColor: rgb(hex))?.setFill(); p.fill()
            NSColor.black.withAlphaComponent(0.2).setStroke(); p.lineWidth = 0.5; p.stroke()
            return true
        }
    }

    // MARK: files dragged in from Finder

    private func dropOperation(_ info: NSDraggingInfo) -> NSDragOperation {
        guard info.draggingSource == nil else { return [] }   // our own note on its way to the Trash
        let p = convert(info.draggingLocation, from: nil)
        world.ptr = p
        guard world.ropeDropOK(p) else { return [] }
        return info.draggingSourceOperationMask.contains(.link) ? .link : .copy
    }
    override func draggingEntered(_ info: NSDraggingInfo) -> NSDragOperation { dropOperation(info) }
    override func draggingUpdated(_ info: NSDraggingInfo) -> NSDragOperation { dropOperation(info) }
    override func performDragOperation(_ info: NSDraggingInfo) -> Bool {
        guard info.draggingSource == nil else { return false }
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
    private var guideCard: GuideCardController?
    /// Shown in the welcome card, and lit up in the menu bar while that card is open.
    var menuIcon: NSImage?
    var onHighlightMenuIcon: ((Bool) -> Void)?
    /// While the guide runs the rope floats above all windows, so nobody has to clear their desktop first.
    private var guideRaised = false { didSet { applyLevel() } }
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
        if Theme.current == .custom { CustomPapers.load(Theme.customSet) }
        let frame = targetFrame()
        panel = OverlayPanel(frame: frame)
        view = OverlayView(world: world)
        view.frame = NSRect(origin: .zero, size: frame.size)
        view.autoresizingMask = [.width, .height]
        panel.contentView = view
        world.resize(width: frame.width, height: frame.height)
        let firstRun: Bool
        if let book = store.load() { world.load(book); firstRun = false } else { world.seedWelcome(); scheduleSave(); firstRun = true }

        world.onChange = { [weak self] in self?.scheduleSave(); self?.finishedPanel?.refresh() }
        world.onEdit = { [weak self] card in self?.openEditor(card) }
        world.onOpenFinished = { [weak self] in self?.toggleFinished() }
        world.onGuideEnd = { [weak self] completed in self?.guideEnded(completed: completed) }
        world.onOpen = { [weak self] c in
            if !FileShortcuts.open(c) { self?.world.poke() }   // shows "找不到原文件"
        }
        world.onReveal = { c in FileShortcuts.reveal(c) }
        world.trashTarget = { [weak self] in self?.dockTrashPoint() ?? .zero }
        world.onTrashed = { c in
            // a plain-text copy goes into the real Trash, so a mistake can still be read back
            if c.kind == .note, c.text != trashPracticeText, c.text != practiceNoteText, let url = OverlayView.writeStandIn(for: c) {
                try? FileManager.default.trashItem(at: url, resultingItemURL: nil)
                try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
            }
            let sound = "/System/Library/Components/CoreAudio.component/Contents/SharedSupport/SystemSounds/dock/drag to trash.aif"
            (NSSound(contentsOfFile: sound, byReference: true) ?? NSSound(named: "Pop"))?.play()
        }
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

        if firstRun {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in self?.showGuide() }
        }
    }

    // MARK: guide

    private var floatingCardLevel: NSWindow.Level { NSWindow.Level(rawValue: NSWindow.Level.floating.rawValue + 1) }

    /// Opens the welcome card; from the menu this starts the guide over.
    func showGuide() {
        world.endGuide(completed: false, notify: false)
        guideCard?.close()
        guideRaised = true
        let screen = targetFrame()
        guideCard = GuideCardController(card: guideWelcomeCard, icon: menuIcon, on: screen, level: floatingCardLevel,
            primary: { [weak self] in self?.beginGuideSteps() },
            secondary: { [weak self] in self?.closeGuide() })
        guideCard?.show()
        onHighlightMenuIcon?(true)
    }

    private func beginGuideSteps() {
        guideCard?.close(); guideCard = nil
        onHighlightMenuIcon?(false)
        if ropeHidden { ropeHidden = false }
        world.startGuide()
    }

    private func guideEnded(completed: Bool) {
        guard completed else { closeGuide(); return }
        // let the note land in the bottle before the closing card appears
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.1) { [weak self] in
            guard let self, self.guideRaised, self.world.guideStep == nil else { return }
            self.guideCard = GuideCardController(card: guideDoneCard, icon: self.menuIcon, on: self.targetFrame(), level: self.floatingCardLevel,
                primary: { [weak self] in self?.closeGuide() }, secondary: {})
            self.guideCard?.show()
        }
    }

    private func closeGuide() {
        guideCard?.close(); guideCard = nil
        onHighlightMenuIcon?(false)
        guideRaised = false
    }

    // MARK: Trash in the Dock

    /// Rough spot of the Trash icon, in overlay coordinates. Worked out from the Dock's settings
    /// (side, icon size, number of icons) because the exact frame needs accessibility access.
    func dockTrashPoint() -> CGPoint {
        guard let screen = targetScreen() else { return CGPoint(x: world.W * 0.7, y: world.H + 80) }
        let f = screen.frame, pf = panel.frame
        let dock = UserDefaults(suiteName: "com.apple.dock")
        var tile = CGFloat(dock?.double(forKey: "tilesize") ?? 0); if tile < 16 { tile = 48 }
        let apps = (dock?.array(forKey: "persistent-apps")?.count ?? 0) + 1           // + Finder
        let others = dock?.array(forKey: "persistent-others")?.count ?? 0
        let showRecents = dock?.object(forKey: "show-recents") as? Bool ?? true
        let recents = showRecents ? min(3, dock?.array(forKey: "recent-apps")?.count ?? 3) : 0
        let running = NSWorkspace.shared.runningApplications.filter { $0.activationPolicy == .regular }.count
        let extra = max(0, running - apps) / 2
        let length = CGFloat(apps + others + recents + extra + 1) * tile * 1.08 + 24
        var sp: CGPoint
        switch OverlayView.dockEdge() {
        case .minX: sp = CGPoint(x: f.minX + tile / 2, y: f.midY - length / 2 + tile / 2)
        case .maxX: sp = CGPoint(x: f.maxX - tile / 2, y: f.midY - length / 2 + tile / 2)
        default: sp = CGPoint(x: min(f.maxX - tile, f.midX + length / 2 - tile / 2), y: f.minY + tile / 2)
        }
        // overlay view is y-down from the panel's top-left
        return CGPoint(x: sp.x - pf.minX, y: pf.maxY - sp.y)
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

    /// On the desktop layer: above the wallpaper and icons, below every app window (except during the guide).
    private func applyLevel() {
        guard let panel else { return }
        panel.level = guideRaised ? .floating : NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopIconWindow)) + 1)
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
        world.externalDrag = pressed && world.dragging == nil && world.systemDrag == nil
            && (types.contains(.fileURL) || types.contains(Self.legacyFilenames))
        // dragging a note toward the Dock: offer the Trash
        let hint = world.dragging != nil && OverlayView.dockDistance(NSEvent.mouseLocation, in: panel.frame) < 70
        if hint != world.trashHint { world.trashHint = hint; world.poke() }

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

        else if world.hoverStamp != nil || world.hoverHangBack != nil || world.hoverTask != nil || world.hoverDelete != nil || world.plusHit(p) || world.bottleHit(p) || world.toastButton.contains(p) || world.guideSkipRect.contains(p) { NSCursor.pointingHand.set() }
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

    var history: [StoredDone] {
        if world.pruneHistory() { world.onChange?() }
        return world.history
    }
    func rehang(historyID id: UUID) { world.rehang(historyID: id) }
    func clearHistory() { world.clearHistory() }

    func hangAllBack() {
        if ropeHidden { ropeHidden = false }   // keeps the menu setting in step
        world.hangAllBack()
    }

    var theme: Theme {
        get { Theme.current }
        set {
            if Theme.current == .christmas && newValue != .christmas { ChristmasWallpaper.restore() }
            Theme.current = newValue
            if newValue == .custom { CustomPapers.load(Theme.customSet) }
            world.themeChanged(); view.needsDisplay = true
        }
    }

    func useCustom(_ name: String) {
        Theme.customSet = name
        CustomPapers.load(name, force: true)
        theme = .custom
    }

    /// Pick a folder of images (or several images); they become a new note-paper style.
    func importPapers() {
        let p = NSOpenPanel()
        p.canChooseFiles = true
        p.canChooseDirectories = true
        p.allowsMultipleSelection = true
        p.allowedContentTypes = [.image, .folder]
        p.prompt = "导入"
        p.message = "选择一个装着便签纸图片的文件夹（或几张图片）。文件夹名就是风格名；图片只保存在这台 Mac 上。"
        NSApp.activate(ignoringOtherApps: true)
        guard p.runModal() == .OK, let name = CustomPapers.importPapers(p.urls) else { return }
        useCustom(name)
    }

    func openPapersFolder() {
        NSWorkspace.shared.open(CustomPapers.root)
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
        editor = EditorController(card: card, anchorTop: anchor, within: panel.frame) { [weak self] edit in
            guard let self else { return }
            if let edit { self.world.edited(card, text: edit.text, done: edit.done, color: .some(edit.color), size: edit.size) }
            self.editor = nil
            self.world.guidePaused = false
        }
        world.guidePaused = true
        if guideRaised { editor?.panel.level = floatingCardLevel }
    }

    func toggleFinished() {
        if let f = finishedPanel, f.panel.isVisible { f.close(); return }
        let c = world.ropeHidden ? CGPoint(x: 42, y: world.anchorY + 20) : world.bottleCenter
        let anchor = screenPoint(CGPoint(x: max(12, c.x - 30), y: c.y + 46))
        let f = finishedPanel ?? FinishedController(world: world)
        finishedPanel = f
        f.panel.level = guideRaised ? floatingCardLevel : .normal
        f.show(topLeft: anchor)
    }
}
