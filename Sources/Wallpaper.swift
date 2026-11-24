import AppKit

/// The Christmas look comes with a matching desktop picture: deep pine green, falling snow,
/// a row of little trees along the bottom. It is drawn to fit each screen, and the user's own
/// wallpaper is put back when they leave the Christmas look (unless they have changed it since).
enum ChristmasWallpaper {
    private static let version = 1
    private static let savedKey = "savedWallpapers"    // [screen id: original wallpaper path]
    private static let onKey = "christmasWallpaperOn"

    static var isOn: Bool {
        get { UserDefaults.standard.bool(forKey: onKey) }
        set { UserDefaults.standard.set(newValue, forKey: onKey) }
    }

    private static var dir: URL {
        let d = Store().url.deletingLastPathComponent().appendingPathComponent("Wallpapers", isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    private static func id(_ s: NSScreen) -> String {
        (s.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.stringValue ?? s.localizedName
    }

    private static func isOurs(_ url: URL?) -> Bool {
        guard let url else { return false }
        return url.standardizedFileURL.path.hasPrefix(dir.standardizedFileURL.path)
    }

    /// Remembers each screen's current picture, then puts up the Christmas one.
    static func apply() {
        var saved = UserDefaults.standard.dictionary(forKey: savedKey) as? [String: String] ?? [:]
        for s in NSScreen.screens {
            let current = NSWorkspace.shared.desktopImageURL(for: s)
            if let current, !isOurs(current) { saved[id(s)] = current.path }
            guard let url = render(for: s) else { continue }
            try? NSWorkspace.shared.setDesktopImageURL(url, for: s, options: [
                .imageScaling: NSImageScaling.scaleProportionallyUpOrDown.rawValue,
                .allowClipping: true,
            ])
        }
        UserDefaults.standard.set(saved, forKey: savedKey)
        isOn = true
    }

    /// Puts the user's own pictures back, but only on screens still showing ours.
    static func restore() {
        guard isOn else { return }
        let saved = UserDefaults.standard.dictionary(forKey: savedKey) as? [String: String] ?? [:]
        for s in NSScreen.screens where isOurs(NSWorkspace.shared.desktopImageURL(for: s)) {
            guard let path = saved[id(s)], FileManager.default.fileExists(atPath: path) else { continue }
            try? NSWorkspace.shared.setDesktopImageURL(URL(fileURLWithPath: path), for: s, options: [:])
        }
        isOn = false
    }

    // MARK: drawing

    private static func render(for screen: NSScreen) -> URL? {
        let scale = screen.backingScaleFactor
        let pw = Int(screen.frame.width * scale), ph = Int(screen.frame.height * scale)
        let url = dir.appendingPathComponent("christmas-\(pw)x\(ph)-v\(version).png")
        if FileManager.default.fileExists(atPath: url.path) { return url }
        guard let ctx = CGContext(data: nil, width: pw, height: ph, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        draw(ctx, w: CGFloat(pw), h: CGFloat(ph), u: scale)
        guard let img = ctx.makeImage() else { return nil }
        let rep = NSBitmapImageRep(cgImage: img)
        guard let data = rep.representation(using: .png, properties: [:]) else { return nil }
        try? data.write(to: url)
        return url
    }

    /// y-up context; `u` is points → pixels.
    private static func draw(_ ctx: CGContext, w: CGFloat, h: CGFloat, u: CGFloat) {
        let sp = CGColorSpace(name: CGColorSpace.sRGB)!
        func col(_ hex: UInt32, _ a: CGFloat = 1) -> CGColor { rgb(hex, a) }
        var seed: UInt64 = 0x5EED_C0DE
        func rnd() -> CGFloat {
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            return CGFloat(seed >> 33) / CGFloat(1 << 31)
        }

        // deep pine green, a touch lighter and warmer towards the top
        let bg = CGGradient(colorsSpace: sp, colors: [col(0x173124), col(0x1F3F2D), col(0x27503A)] as CFArray, locations: [0, 0.6, 1])!
        ctx.drawLinearGradient(bg, start: .zero, end: CGPoint(x: 0, y: h), options: [])
        let glow = CGGradient(colorsSpace: sp, colors: [col(0xF6D9A0, 0.10), col(0xF6D9A0, 0)] as CFArray, locations: [0, 1])!
        ctx.drawRadialGradient(glow, startCenter: CGPoint(x: w * 0.5, y: h * 0.92), startRadius: 0,
                               endCenter: CGPoint(x: w * 0.5, y: h * 0.92), endRadius: max(w, h) * 0.6, options: [])

        // a very faint tartan
        ctx.setFillColor(col(0xFBF1E1, 0.022))
        var x: CGFloat = 0
        while x < w { ctx.fill(CGRect(x: x, y: 0, width: 46 * u, height: h)); x += 150 * u }
        var y: CGFloat = 0
        while y < h { ctx.fill(CGRect(x: 0, y: y, width: w, height: 46 * u)); y += 150 * u }
        ctx.setFillColor(col(0xC8423A, 0.05))
        x = 70 * u; while x < w { ctx.fill(CGRect(x: x, y: 0, width: 2 * u, height: h)); x += 150 * u }
        y = 70 * u; while y < h { ctx.fill(CGRect(x: 0, y: y, width: w, height: 2 * u)); y += 150 * u }

        // falling snow: soft dots of different sizes
        let area = (w / u) * (h / u)
        for _ in 0..<Int(area / 2600) {
            let p = CGPoint(x: rnd() * w, y: rnd() * h)
            let r = (0.6 + rnd() * rnd() * 2.6) * u
            ctx.setFillColor(col(0xFFFFFF, 0.12 + rnd() * 0.4))
            ctx.fillEllipse(in: CGRect(x: p.x - r, y: p.y - r, width: r * 2, height: r * 2))
        }
        // and a scatter of line snowflakes
        ctx.setLineCap(.round)
        for _ in 0..<Int(area / 42000) {
            let c = CGPoint(x: rnd() * w, y: h * 0.18 + rnd() * h * 0.82)
            let R = (5 + rnd() * 10) * u
            ctx.setStrokeColor(col(0xFBF1E1, 0.16 + rnd() * 0.22))
            ctx.setLineWidth(max(1, R * 0.12))
            let rot = rnd() * .pi
            for k in 0..<6 {
                let a = rot + CGFloat(k) * .pi / 3
                let e = CGPoint(x: c.x + cos(a) * R, y: c.y + sin(a) * R)
                ctx.move(to: c); ctx.addLine(to: e)
                let m = CGPoint(x: c.x + cos(a) * R * 0.6, y: c.y + sin(a) * R * 0.6)
                for s in [-0.7, 0.7] as [CGFloat] {
                    ctx.move(to: m); ctx.addLine(to: CGPoint(x: m.x + cos(a + s) * R * 0.32, y: m.y + sin(a + s) * R * 0.32))
                }
            }
            ctx.strokePath()
        }

        // a soft snowdrift and a row of little pine trees along the bottom
        let drift = CGMutablePath()
        drift.move(to: .zero)
        drift.addLine(to: CGPoint(x: 0, y: 70 * u))
        var dx: CGFloat = 0
        while dx < w {
            let nx = dx + 260 * u
            drift.addQuadCurve(to: CGPoint(x: nx, y: (58 + rnd() * 26) * u), control: CGPoint(x: dx + 130 * u, y: (92 + rnd() * 24) * u))
            dx = nx
        }
        drift.addLine(to: CGPoint(x: w, y: 0)); drift.closeSubpath()
        var tx: CGFloat = -20 * u
        while tx < w {
            let th = (70 + rnd() * 110) * u, tw = th * (0.42 + rnd() * 0.1)
            let base = (54 + rnd() * 14) * u
            let tone: UInt32 = rnd() > 0.5 ? 0x112619 : 0x15301F
            ctx.setFillColor(col(tone, 0.9))
            for tier in 0..<3 {
                let t = CGFloat(tier)
                let bw = tw * (1 - t * 0.24), by = base + th * t * 0.26, top = by + th * (0.52 - t * 0.06)
                ctx.move(to: CGPoint(x: tx - bw / 2, y: by)); ctx.addLine(to: CGPoint(x: tx + bw / 2, y: by))
                ctx.addLine(to: CGPoint(x: tx, y: top)); ctx.closePath(); ctx.fillPath()
            }
            // a few warm lights on some trees
            if rnd() > 0.45 {
                for _ in 0..<4 {
                    let ly = base + rnd() * th * 0.7, half = tw * 0.5 * (1 - (ly - base) / th)
                    let lp = CGPoint(x: tx + (rnd() - 0.5) * half * 1.6, y: ly)
                    let lr = 1.6 * u
                    ctx.setFillColor(col(rnd() > 0.5 ? 0xFFD27A : 0xE5544B, 0.85))
                    ctx.fillEllipse(in: CGRect(x: lp.x - lr, y: lp.y - lr, width: lr * 2, height: lr * 2))
                }
            }
            tx += (60 + rnd() * 90) * u
        }
        ctx.addPath(drift); ctx.setFillColor(col(0xEEF2EC, 0.92)); ctx.fillPath()
        let shade = CGGradient(colorsSpace: sp, colors: [col(0xC9D6CF, 0.6), col(0xC9D6CF, 0)] as CFArray, locations: [0, 1])!
        ctx.saveGState(); ctx.addPath(drift); ctx.clip()
        ctx.drawLinearGradient(shade, start: .zero, end: CGPoint(x: 0, y: 90 * u), options: [])
        ctx.restoreGState()
    }
}
