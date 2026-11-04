import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let overlay = OverlayController()
    private var statusItem: NSStatusItem!
    private var floatItem: NSMenuItem!

    func applicationDidFinishLaunching(_ notification: Notification) {
        Fonts.register()
        overlay.start()
        setupStatusItem()
    }

    func applicationWillTerminate(_ notification: Notification) {
        overlay.saveNow()
    }

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = Self.menuIcon()
        statusItem.button?.toolTip = "绳上手帐"

        let menu = NSMenu()
        menu.delegate = self
        menu.addItem(item("新便签", #selector(newNote), "n"))
        menu.addItem(item("已完成的便签…", #selector(showFinished), ""))
        menu.addItem(.separator())
        floatItem = item("浮在其他窗口之上", #selector(toggleFloat), "")
        menu.addItem(floatItem)
        menu.addItem(item("打开数据文件夹", #selector(openData), ""))
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
        floatItem.state = overlay.floatAbove ? .on : .off
    }

    @objc private func newNote() { overlay.newNote() }
    @objc private func showFinished() { overlay.toggleFinished() }
    @objc private func toggleFloat() { overlay.floatAbove.toggle() }
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
