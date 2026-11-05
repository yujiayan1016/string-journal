import AppKit
import ImageIO
import UniformTypeIdentifiers

/// Note paper made from the user's own images. Each set is a folder under
/// ~/Library/Application Support/StringJournal/Papers/<set name>/ and stays on this Mac only.
enum CustomPapers {
    static var root: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = base.appendingPathComponent("StringJournal/Papers", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private(set) static var images: [CGImage] = []
    private(set) static var loadedSet: String?
    /// Paper tints for things that need a flat colour (crumpled ball, lists).
    static let palette: [UInt32] = [0xF9E7B5, 0xCFE0F6, 0xF8D3DF, 0xE9DDF5, 0xD9EFE3]

    static func isImage(_ u: URL) -> Bool {
        UTType(filenameExtension: u.pathExtension)?.conforms(to: .image) ?? false
    }

    static func imageURLs(in dir: URL) -> [URL] {
        let items = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? []
        return items.filter(isImage).sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
    }

    /// Names of the imported sets that contain at least one image.
    static func sets() -> [String] {
        let dirs = (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])) ?? []
        return dirs.filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true && !imageURLs(in: $0).isEmpty }
            .map(\.lastPathComponent)
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    private static func thumbnail(_ u: URL) -> CGImage? {
        guard let src = CGImageSourceCreateWithURL(u as CFURL, nil) else { return nil }
        let opts: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: 900,
            kCGImageSourceCreateThumbnailWithTransform: true,
        ]
        return CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary)
    }

    static func load(_ name: String?, force: Bool = false) {
        guard let name else { images = []; loadedSet = nil; return }
        if name == loadedSet && !force && !images.isEmpty { return }
        images = imageURLs(in: root.appendingPathComponent(name, isDirectory: true)).compactMap(thumbnail)
        loadedSet = name
    }

    static func image(for c: Card) -> CGImage? {
        guard !images.isEmpty else { return nil }
        let n = images.count
        return images[((c.style % n) + n) % n]
    }

    /// Copies chosen images (or the images inside a chosen folder) into a new set.
    /// The set is named after the folder. Returns the set name.
    static func importPapers(_ urls: [URL]) -> String? {
        var files: [URL] = []
        var name: String?
        for u in urls {
            if (try? u.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
                name = name ?? u.lastPathComponent
                files += imageURLs(in: u)
            } else if isImage(u) {
                name = name ?? u.deletingLastPathComponent().lastPathComponent
                files.append(u)
            }
        }
        guard !files.isEmpty, let set = name else { return nil }
        let dest = root.appendingPathComponent(set, isDirectory: true)
        try? FileManager.default.createDirectory(at: dest, withIntermediateDirectories: true)
        for f in files {
            let to = dest.appendingPathComponent(f.lastPathComponent)
            try? FileManager.default.removeItem(at: to)
            try? FileManager.default.copyItem(at: f, to: to)
        }
        return set
    }
}

extension Theme {
    /// The imported-paper look is on and has images to draw.
    static var paperActive: Bool { current == .custom && !CustomPapers.images.isEmpty }

    /// Which imported set is chosen.
    static var customSet: String? {
        get { UserDefaults.standard.string(forKey: "customSet") }
        set { UserDefaults.standard.set(newValue, forKey: "customSet") }
    }
}
