import AppKit
import QuickLookThumbnailing
import UniformTypeIdentifiers

/// Files and folders hung on the rope are shortcuts: the original never moves.
enum FileShortcuts {
    static func classify(_ url: URL) -> (kind: CardKind, count: Int?) {
        let v = try? url.resourceValues(forKeys: [.isDirectoryKey, .isPackageKey, .contentTypeKey])
        if v?.isDirectory == true && v?.isPackage != true {
            let names = (try? FileManager.default.contentsOfDirectory(atPath: url.path)) ?? []
            return (.folder, names.filter { !$0.hasPrefix(".") }.count)
        }
        if let t = v?.contentType, t.conforms(to: .image) { return (.image, nil) }
        return (.file, nil)
    }

    static func bookmark(_ url: URL) -> Data? {
        try? url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
    }

    static func displayName(_ url: URL, kind: CardKind) -> String {
        kind == .folder ? url.lastPathComponent : url.deletingPathExtension().lastPathComponent
    }

    /// Re-find a file that may have been moved or renamed since it was hung up.
    static func resolve(_ c: Card) {
        if let data = c.bookmark {
            var stale = false
            if let u = try? URL(resolvingBookmarkData: data, options: [.withoutUI], relativeTo: nil, bookmarkDataIsStale: &stale) {
                c.url = u
                if stale { c.bookmark = bookmark(u) }
            }
        }
        guard let url = c.url, FileManager.default.fileExists(atPath: url.path) else { c.missing = true; return }
        c.missing = false
        c.text = displayName(url, kind: c.kind)
        if c.kind == .folder { c.itemCount = classify(url).count }
    }

    private static func icon(_ url: URL) -> CGImage? {
        let img = NSWorkspace.shared.icon(forFile: url.path)
        img.size = NSSize(width: 256, height: 256)
        var r = CGRect(x: 0, y: 0, width: 256, height: 256)
        return img.cgImage(forProposedRect: &r, context: nil, hints: nil)
    }

    static func loadThumbnail(_ c: Card, done: @escaping () -> Void) {
        guard let url = c.url, !c.missing else { return }
        if c.kind == .folder { done(); return }
        let req = QLThumbnailGenerator.Request(fileAt: url, size: CGSize(width: 240, height: 240), scale: 2, representationTypes: .all)
        QLThumbnailGenerator.shared.generateBestRepresentation(for: req) { rep, _ in
            DispatchQueue.main.async {
                c.thumb = rep?.cgImage ?? icon(url)
                done()
            }
        }
    }

    static func open(_ c: Card) -> Bool {
        resolve(c)
        guard let url = c.url, !c.missing else { return false }
        NSWorkspace.shared.open(url)
        return true
    }

    static func reveal(_ c: Card) {
        resolve(c)
        guard let url = c.url, !c.missing else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }
}
