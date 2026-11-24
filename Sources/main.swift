import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate, NSWindowDelegate, NSDraggingDestination {
    private let overlay = OverlayController()
    private var statusItem: NSStatusItem!
    private var ropeItem: NSMenuItem!
    private var styleItem: NSMenuItem!
    private var displayItem: NSMenuItem!
    private var historyItem: NSMenuItem!

    func applicationDidFinishLaunching(_ notification: Notification) {
        Fonts.register()
        overlay.menuIcon = Self.menuIcon()
        overlay.onHighlightMenuIcon = { [weak self] on in self?.statusItem?.button?.highlight(on) }
        overlay.start()
        setupStatusItem()
        setupEditMenu()
    }

    /// The app has no menu bar of its own, so without this ⌘C / ⌘V / ⌘X / ⌘A / ⌘Z do nothing in the note editor.
    private func setupEditMenu() {
        let main = NSMenu()
        let appItem = NSMenuItem(); appItem.submenu = NSMenu()
        main.addItem(appItem)
        let editItem = NSMenuItem(); let edit = NSMenu(title: "编辑")
        editItem.submenu = edit
        func add(_ title: String, _ sel: String, _ key: String, _ mods: NSEvent.ModifierFlags = .command) {
            let i = NSMenuItem(title: title, action: Selector(sel), keyEquivalent: key)
            i.keyEquivalentModifierMask = mods
            edit.addItem(i)
        }
        add("撤销", "undo:", "z")
        add("重做", "redo:", "z", [.command, .shift])
        edit.addItem(.separator())
        add("剪切", "cut:", "x")
        add("拷贝", "copy:", "c")
        add("粘贴", "paste:", "v")
        add("粘贴并匹配样式", "pasteAsPlainText:", "v", [.command, .option, .shift])
        add("全选", "selectAll:", "a")
        main.addItem(editItem)
        NSApp.mainMenu = main
    }

    func applicationWillTerminate(_ notification: Notification) {
        overlay.saveNow()
    }

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = Self.menuIcon()
        statusItem.button?.toolTip = "绳上手帐：把文件拖到这里，就会挂到绳子上"
        // files dropped on the menu bar icon get hung on the rope
        if let w = statusItem.button?.window {
            w.registerForDraggedTypes([.fileURL])
            w.delegate = self
        }

        let menu = NSMenu()
        menu.delegate = self
        menu.addItem(item("新便签", #selector(newNote), "n"))
        menu.addItem(item("挂上文件…", #selector(chooseFiles), "o"))
        menu.addItem(item("已完成的便签…", #selector(showFinished), ""))
        historyItem = NSMenuItem(title: "任务历史", action: nil, keyEquivalent: "")
        historyItem.submenu = NSMenu()
        menu.addItem(historyItem)
        menu.addItem(.separator())
        menu.addItem(item("全部挂回绳子", #selector(hangAllBack), ""))
        menu.addItem(.separator())
        ropeItem = item("显示绳子", #selector(toggleRope), "")
        menu.addItem(ropeItem)
        styleItem = NSMenuItem(title: "风格", action: nil, keyEquivalent: "")
        styleItem.submenu = NSMenu()
        menu.addItem(styleItem)
        displayItem = NSMenuItem(title: "显示在", action: nil, keyEquivalent: "")
        displayItem.submenu = NSMenu()
        menu.addItem(displayItem)
        menu.addItem(item("打开数据文件夹", #selector(openData), ""))
        menu.addItem(item("新手引导…", #selector(showGuide), ""))
        menu.addItem(.separator())
        menu.addItem(item("退出绳上手帐", #selector(quit), "q"))
        statusItem.menu = menu
    }

    private func item(_ title: String, _ action: Selector, _ key: String) -> NSMenuItem {
        let i = NSMenuItem(title: title, action: action, keyEquivalent: key)
        i.target = self
        return i
    }

    func menuWillOpen(_ menu: NSMenu) {
        ropeItem.state = overlay.ropeHidden ? .off : .on
        historyItem.submenu = historyMenu()
        // styles: the two built-in looks, then every imported paper set
        let sm = NSMenu()
        let journal = item("手帐", #selector(useJournal), "")
        journal.state = overlay.theme == .journal ? .on : .off
        let sticky = item("便利贴", #selector(useSticky), "")
        sticky.state = overlay.theme == .sticky ? .on : .off
        let xmas = item("圣诞", #selector(useChristmas), "")
        xmas.state = overlay.theme == .christmas ? .on : .off
        sm.addItem(journal); sm.addItem(sticky); sm.addItem(xmas)
        let sets = CustomPapers.sets()
        if !sets.isEmpty {
            sm.addItem(.separator())
            for name in sets {
                let it = NSMenuItem(title: name, action: #selector(useCustom(_:)), keyEquivalent: "")
                it.target = self
                it.representedObject = name
                it.state = overlay.theme == .custom && Theme.customSet == name ? .on : .off
                sm.addItem(it)
            }
        }
        sm.addItem(.separator())
        sm.addItem(item("导入便签纸…", #selector(importPapers), ""))
        sm.addItem(item("打开便签纸文件夹", #selector(openPapers), ""))
        styleItem.submenu = sm
        // one entry per connected display; hidden when there is only one
        let screens = NSScreen.screens
        let current = overlay.currentScreenKey
        let sub = NSMenu()
        var seen: [String: Int] = [:]
        for (i, s) in screens.enumerated() {
            var name = s.localizedName
            seen[name, default: 0] += 1
            if seen[name]! > 1 { name += " \(seen[name]!)" }
            if i == 0 { name += "（主显示器）" }
            let it = NSMenuItem(title: name, action: #selector(pickDisplay(_:)), keyEquivalent: "")
            it.target = self
            it.representedObject = OverlayController.key(for: s)
            it.state = OverlayController.key(for: s) == current ? .on : .off
            sub.addItem(it)
        }
        displayItem.submenu = sub
        displayItem.isHidden = screens.count < 2
    }

    private static let historyDate: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "M月d日 HH:mm"; return f
    }()

    /// Tasks finished in the last 15 days; older ones drop off by themselves. Picking one hangs it back up.
    private func historyMenu() -> NSMenu {
        let m = NSMenu()
        let items = overlay.history
        let head = NSMenuItem(title: items.isEmpty ? "还没有完成的任务" : "最近 \(World.historyDays) 天完成的 \(items.count) 条",
                              action: nil, keyEquivalent: "")
        head.isEnabled = false
        m.addItem(head)
        guard !items.isEmpty else { return m }
        m.addItem(.separator())
        for h in items {
            let title = h.text.split(separator: "\n", maxSplits: 1).first.map(String.init)?.trimmingCharacters(in: .whitespaces) ?? ""
            let it = NSMenuItem(title: "", action: #selector(rehangHistory(_:)), keyEquivalent: "")
            it.target = self
            it.representedObject = h.id
            let s = NSMutableAttributedString(string: "✓ " + (title.isEmpty ? "便签" : String(title.prefix(28))),
                                              attributes: [.font: NSFont.menuFont(ofSize: 0)])
            s.append(NSAttributedString(string: "    " + Self.historyDate.string(from: h.doneAt),
                                        attributes: [.font: NSFont.menuFont(ofSize: 11), .foregroundColor: NSColor.secondaryLabelColor]))
            it.attributedTitle = s
            it.toolTip = h.text + "\n\n点一下重新挂回绳子"
            m.addItem(it)
        }
        m.addItem(.separator())
        m.addItem(item("清空任务历史", #selector(clearHistory), ""))
        return m
    }

    @objc private func rehangHistory(_ sender: NSMenuItem) {
        if let id = sender.representedObject as? UUID { overlay.rehang(historyID: id) }
    }
    @objc private func clearHistory() { overlay.clearHistory() }

    @objc private func newNote() { overlay.newNote() }
    @objc private func chooseFiles() { overlay.chooseFiles() }

    // MARK: drop files on the menu bar icon

    private func fileURLs(_ info: NSDraggingInfo) -> [URL] {
        info.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
    }
    func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard sender.draggingSource == nil, !fileURLs(sender).isEmpty else { return [] }
        statusItem.button?.highlight(true)
        return sender.draggingSourceOperationMask.contains(.link) ? .link : .copy
    }
    func draggingExited(_ sender: NSDraggingInfo?) { statusItem.button?.highlight(false) }
    func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        statusItem.button?.highlight(false)
        let urls = fileURLs(sender)
        guard sender.draggingSource == nil, !urls.isEmpty else { return false }
        overlay.addFiles(urls)
        return true
    }
    @objc private func showGuide() { overlay.showGuide() }
    @objc private func showFinished() { overlay.toggleFinished() }
    @objc private func toggleRope() { overlay.ropeHidden.toggle() }
    @objc private func hangAllBack() { overlay.hangAllBack() }
    @objc private func useJournal() { overlay.theme = .journal }
    @objc private func useSticky() { overlay.theme = .sticky }
    /// Switching to Christmas also changes the desktop picture, so ask first.
    @objc private func useChristmas() {
        guard overlay.theme != .christmas else { return }
        NSApp.activate(ignoringOtherApps: true)
        let a = NSAlert()
        a.messageText = "换成圣诞风格"
        a.informativeText = "圣诞风格配了一张圣诞桌面壁纸，桌面会一起换掉。\n\n之后想用别的壁纸，随时可以在「系统设置 › 墙纸」里换；切回其他风格时，会自动换回你原来的壁纸。"
        a.addButton(withTitle: "换风格和壁纸")
        a.addButton(withTitle: "只换便签，不换壁纸")
        a.addButton(withTitle: "取消")
        switch a.runModal() {
        case .alertFirstButtonReturn:
            overlay.theme = .christmas
            ChristmasWallpaper.apply()
        case .alertSecondButtonReturn:
            overlay.theme = .christmas
        default: break
        }
    }
    @objc private func useCustom(_ sender: NSMenuItem) {
        if let name = sender.representedObject as? String { overlay.useCustom(name) }
    }
    @objc private func importPapers() { overlay.importPapers() }
    @objc private func openPapers() { overlay.openPapersFolder() }
    @objc private func pickDisplay(_ sender: NSMenuItem) {
        guard let key = sender.representedObject as? String else { return }
        // choosing the primary display stores nil, so it follows whichever display has the menu bar
        overlay.displayKey = NSScreen.screens.first.map(OverlayController.key(for:)) == key ? nil : key
    }
    @objc private func openData() { NSWorkspace.shared.activateFileViewerSelecting([overlay.store.url]) }
    @objc private func quit() { overlay.saveNow(); NSApp.terminate(nil) }

    /// A note hanging from a little length of twine, as a template image.
    private static func menuIcon() -> NSImage {
        let img = NSImage(size: NSSize(width: 18, height: 18), flipped: true) { _ in
            NSColor.black.setStroke()
            let rope = NSBezierPath()
            rope.move(to: NSPoint(x: 1, y: 3.5))
            rope.curve(to: NSPoint(x: 17, y: 3.5), controlPoint1: NSPoint(x: 6, y: 6.5), controlPoint2: NSPoint(x: 12, y: 6.5))
            rope.lineWidth = 1.3
            rope.stroke()
            NSColor.black.setFill()
            NSBezierPath(rect: NSRect(x: 8.2, y: 2.5, width: 1.6, height: 4.5)).fill()
            let note = NSBezierPath(roundedRect: NSRect(x: 4, y: 6.5, width: 10, height: 10), xRadius: 1, yRadius: 1)
            note.lineWidth = 1.3
            note.stroke()
            NSBezierPath(rect: NSRect(x: 6, y: 10, width: 6, height: 1.1)).fill()
            NSBezierPath(rect: NSRect(x: 6, y: 12.6, width: 4, height: 1.1)).fill()
            return true
        }
        img.isTemplate = true
        return img
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
