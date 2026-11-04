import AppKit
import CoreText

// MARK: - Colours & fonts

func rgb(_ hex: UInt32, _ a: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: a)
}
func rgba(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat) -> CGColor {
    CGColor(srgbRed: r / 255, green: g / 255, blue: b / 255, alpha: a)
}
let INK: UInt32 = 0x2E3448
let SEAL: UInt32 = 0xC7372F

enum Fonts {
    static func register() {
        for name in ["LXGWWenKaiTC-Regular", "ZCOOLKuaiLe-Regular"] {
            let url = Bundle.main.url(forResource: name, withExtension: "ttf", subdirectory: "Fonts")
                ?? Bundle.main.url(forResource: name, withExtension: "ttf")
            if let url { CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil) }
        }
    }
    static func title(_ size: CGFloat) -> NSFont {
        NSFont(name: "ZCOOLKuaiLe-Regular", size: size) ?? .systemFont(ofSize: size, weight: .semibold)
    }
    static func hand(_ size: CGFloat) -> NSFont {
        NSFont(name: "LXGWWenKaiTC-Regular", size: size) ?? .systemFont(ofSize: size)
    }
}

// MARK: - Renderer

/// Draws the whole overlay. Coordinates are y-down (the view is flipped), matching the prototype.
final class Renderer {
    let ctx: CGContext
    let world: World
    private let flip: CGFloat
    private let scale: CGFloat
    private let space = CGColorSpace(name: CGColorSpace.sRGB)!

    init(ctx: CGContext, world: World) {
        self.ctx = ctx; self.world = world
        let m = ctx.ctm
        scale = max(1, (m.a * m.a + m.b * m.b).squareRoot())
        flip = m.d < 0 ? -1 : 1      // shadow offsets live in base space
    }

    // MARK: helpers

    private func shadow(_ dx: CGFloat, _ dy: CGFloat, _ blur: CGFloat, _ color: CGColor) {
        ctx.setShadow(offset: CGSize(width: dx * scale, height: flip * dy * scale), blur: blur * scale, color: color)
    }
    private func noShadow() { ctx.setShadow(offset: .zero, blur: 0, color: nil) }

    private func linear(_ colors: [CGColor], _ locs: [CGFloat], _ a: CGPoint, _ b: CGPoint) {
        guard let g = CGGradient(colorsSpace: space, colors: colors as CFArray, locations: locs) else { return }
        ctx.drawLinearGradient(g, start: a, end: b, options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
    }
    private func radial(_ colors: [CGColor], _ locs: [CGFloat], _ c0: CGPoint, _ r0: CGFloat, _ c1: CGPoint, _ r1: CGFloat) {
        guard let g = CGGradient(colorsSpace: space, colors: colors as CFArray, locations: locs) else { return }
        ctx.drawRadialGradient(g, startCenter: c0, startRadius: r0, endCenter: c1, endRadius: r1, options: [.drawsAfterEndLocation])
    }
    private func line(_ a: CGPoint, _ b: CGPoint) {
        ctx.beginPath(); ctx.move(to: a); ctx.addLine(to: b); ctx.strokePath()
    }
    private func dot(_ p: CGPoint, _ r: CGFloat) {
        ctx.fillEllipse(in: CGRect(x: p.x - r, y: p.y - r, width: r * 2, height: r * 2))
    }

    private func text(_ s: String, font: NSFont, color: CGColor, alpha: CGFloat = 1) -> NSAttributedString {
        NSAttributedString(string: s, attributes: [
            .font: font,
            .foregroundColor: NSColor(cgColor: color.copy(alpha: color.alpha * alpha) ?? color) ?? .black,
        ])
    }
    private func drawCentered(_ s: NSAttributedString, at p: CGPoint) {
        let sz = s.size()
        s.draw(at: CGPoint(x: p.x - sz.width / 2, y: p.y - sz.height / 2))
    }

    // MARK: scene

    func drawAll() {
        drawEnvelope()
        for c in world.cards.filter({ $0.mode == .free }).sorted(by: { $0.z < $1.z }) { drawPaper(c, lift: 0); drawAttach(c) }
        let hanging = world.cards.filter { $0.mode == .hang }
        drawGhost()
        for c in hanging { drawPaper(c, lift: 1) }
        drawRope()
        for c in hanging { drawAttach(c) }
        drawPlus()
        for c in world.cards where c.mode == .crumple { drawBall(c) }
        if let d = world.dragging { drawPaper(d, lift: 2); drawAttach(d) }
        if world.basket.hot { drawHotLabel() }
        drawToast()
    }

    // MARK: rope

    private func ropePath() -> CGPath {
        let p = CGMutablePath()
        let n = world.nodes
        guard n.count > 2 else { return p }
        p.move(to: CGPoint(x: n[0].x, y: n[0].y))
        for i in 1..<(n.count - 1) {
            let a = n[i], b = n[i + 1]
            p.addQuadCurve(to: CGPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2), control: CGPoint(x: a.x, y: a.y))
        }
        p.addLine(to: CGPoint(x: n[n.count - 1].x, y: n[n.count - 1].y))
        return p
    }

    private func drawRope() {
        let path = ropePath()
        ctx.saveGState()
        ctx.setLineCap(.round); ctx.setLineJoin(.round)
        // red & white baker's twine
        shadow(0, 4, 3, rgba(40, 46, 62, 0.2))
        ctx.addPath(path); ctx.setStrokeColor(rgb(0xF4EFE7)); ctx.setLineWidth(3.2); ctx.strokePath()
        noShadow()
        ctx.setLineCap(.butt)
        ctx.setLineDash(phase: 0, lengths: [2.6, 3.2])
        ctx.addPath(path); ctx.setStrokeColor(rgb(SEAL)); ctx.setLineWidth(3.2); ctx.strokePath()
        ctx.setLineDash(phase: 0, lengths: [])
        ctx.translateBy(x: 0, y: -0.8)
        ctx.addPath(path); ctx.setStrokeColor(rgba(255, 255, 255, 0.35)); ctx.setLineWidth(0.8); ctx.strokePath()
        ctx.restoreGState()
    }

    private func drawGhost() {
        guard world.dragging != nil, let sx = world.slotX else { return }
        let r = world.ropeAt(sx)
        ctx.saveGState()
        ctx.translateBy(x: r.x, y: r.y + CLIP)
        let rect = CGRect(x: -CW / 2, y: 0, width: CW, height: CH)
        let p = CGPath(roundedRect: rect, cornerWidth: 4, cornerHeight: 4, transform: nil)
        ctx.addPath(p); ctx.setFillColor(rgba(255, 255, 255, 0.3)); ctx.fillPath()
        ctx.setLineDash(phase: 0, lengths: [5, 5])
        ctx.addPath(p); ctx.setStrokeColor(rgb(INK, 0.35)); ctx.setLineWidth(1.4); ctx.strokePath()
        ctx.restoreGState()
    }

    /// "+" kraft tag hanging near the right end of the twine.
    private func drawPlus() {
        let p = world.plusCenter
        let r = world.ropeAt(p.x)
        let hover = world.plusHit(world.ptr)
        ctx.saveGState()
        ctx.setStrokeColor(rgb(0xF4EFE7)); ctx.setLineWidth(1.2)
        line(CGPoint(x: r.x, y: r.y), CGPoint(x: p.x, y: p.y - 15))
        shadow(0, 3, 6, rgba(40, 46, 62, 0.22))
        ctx.setFillColor(rgb(hover ? 0xD5AE7E : 0xC9A477)); dot(p, 15)
        noShadow()
        ctx.setLineDash(phase: 0, lengths: [2.5, 2.5])
        ctx.setStrokeColor(rgba(255, 248, 235, 0.75)); ctx.setLineWidth(1)
        ctx.strokeEllipse(in: CGRect(x: p.x - 11.5, y: p.y - 11.5, width: 23, height: 23))
        ctx.setLineDash(phase: 0, lengths: [])
        ctx.setStrokeColor(rgb(0xFFFAF0)); ctx.setLineWidth(2); ctx.setLineCap(.round)
        line(CGPoint(x: p.x - 5.5, y: p.y), CGPoint(x: p.x + 5.5, y: p.y))
        line(CGPoint(x: p.x, y: p.y - 5.5), CGPoint(x: p.x, y: p.y + 5.5))
        ctx.setFillColor(rgb(0xF4EFE7)); dot(CGPoint(x: p.x, y: p.y - 15), 2)
        ctx.restoreGState()
    }

    // MARK: paper

    private func paperPath(_ c: Card) -> CGPath {
        let w = c.w, h = c.h, x0 = -w / 2, y0 = -h / 2
        let p = CGMutablePath()
        p.move(to: CGPoint(x: x0 + 1.5, y: y0))
        p.addLine(to: CGPoint(x: x0 + w - 1.5, y: y0))
        p.addQuadCurve(to: CGPoint(x: x0 + w, y: y0 + 1.5), control: CGPoint(x: x0 + w, y: y0))
        if c.styleDef.paper == .torn {
            p.addLine(to: CGPoint(x: x0 + w, y: y0 + h - 4))
            let n = 16
            for i in 1...n {
                let x = x0 + w - w * CGFloat(i) / CGFloat(n)
                let y = y0 + h - 4 + (srand(c.seed, Double(i)) - 0.3) * 6
                p.addLine(to: CGPoint(x: x, y: y))
            }
        } else {
            p.addLine(to: CGPoint(x: x0 + w + 0.5, y: y0 + h - 3))
            p.addQuadCurve(to: CGPoint(x: x0 + 1, y: y0 + h - 0.5), control: CGPoint(x: x0 + w * 0.55, y: y0 + h + 2.5))
        }
        p.addLine(to: CGPoint(x: x0, y: y0 + 1.5))
        p.addQuadCurve(to: CGPoint(x: x0 + 1.5, y: y0), control: CGPoint(x: x0, y: y0))
        p.closeSubpath()
        return p
    }

    private func paperTexture(_ c: Card) {
        let w = c.w, h = c.h, x0 = -w / 2, y0 = -h / 2
        ctx.saveGState()
        switch c.styleDef.paper {
        case .grid:
            ctx.setStrokeColor(rgba(95, 140, 185, 0.2)); ctx.setLineWidth(0.7)
            var x = x0 + 11; while x < x0 + w { line(CGPoint(x: x, y: y0), CGPoint(x: x, y: y0 + h)); x += 11 }
            var y = y0 + 11; while y < y0 + h { line(CGPoint(x: x0, y: y), CGPoint(x: x0 + w, y: y)); y += 11 }
        case .lined:
            ctx.setStrokeColor(rgba(95, 140, 185, 0.32)); ctx.setLineWidth(0.8)
            var y = y0 + 48; while y < y0 + h - 6 { line(CGPoint(x: x0, y: y), CGPoint(x: x0 + w, y: y)); y += 21 }
            ctx.setStrokeColor(rgb(SEAL, 0.35))
            line(CGPoint(x: x0 + 9, y: y0), CGPoint(x: x0 + 9, y: y0 + h))
        case .dot:
            ctx.setFillColor(rgba(60, 70, 95, 0.22))
            var y = y0 + 10
            while y < y0 + h {
                var x = x0 + 10
                while x < x0 + w { dot(CGPoint(x: x, y: y), 0.8); x += 11 }
                y += 11
            }
        case .kraft:
            ctx.setLineWidth(0.7)
            for i in 0..<70 {
                let d = Double(i)
                let x = x0 + srand(c.seed, d) * w, y = y0 + srand(c.seed, d + 300) * h
                let a = srand(c.seed, d + 600) * .pi, l = 3 + srand(c.seed, d + 900) * 9
                ctx.setStrokeColor(i % 3 != 0 ? rgba(110, 75, 35, 0.16) : rgba(255, 240, 215, 0.3))
                line(CGPoint(x: x, y: y), CGPoint(x: x + cos(a) * l, y: y + sin(a) * l))
            }
        case .torn:
            ctx.setFillColor(rgba(40, 45, 60, 0.13))
            var x = x0 + 12; while x < x0 + w - 6 { dot(CGPoint(x: x, y: y0 + 5), 1.6); x += 11 }
            ctx.setStrokeColor(rgba(95, 140, 185, 0.28)); ctx.setLineWidth(0.8)
            var y = y0 + 48; while y < y0 + h - 8 { line(CGPoint(x: x0, y: y), CGPoint(x: x0 + w, y: y)); y += 21 }
        }
        ctx.restoreGState()
    }

    private func drawDoodle(_ c: Card) {
        guard let kind = c.styleDef.doodle else { return }
        ctx.saveGState()
        ctx.translateBy(x: c.w / 2 - 22, y: -c.h / 2 + 22)
        ctx.rotate(by: (srand(c.seed, 7) - 0.5) * 0.5)
        ctx.setStrokeColor(rgb(INK, 0.55)); ctx.setLineWidth(1.2)
        ctx.setLineJoin(.round); ctx.setLineCap(.round)
        ctx.beginPath()
        switch kind {
        case .star:
            for i in 0..<11 {
                let a = -CGFloat.pi / 2 + CGFloat(i) * .pi / 5, r: CGFloat = i % 2 == 1 ? 3.6 : 8.5
                let pt = CGPoint(x: cos(a) * r, y: sin(a) * r)
                if i == 0 { ctx.move(to: pt) } else { ctx.addLine(to: pt) }
            }
            ctx.closePath()
        case .heart:
            ctx.move(to: CGPoint(x: 0, y: 7))
            ctx.addCurve(to: CGPoint(x: 0, y: -3), control1: CGPoint(x: -10, y: 0), control2: CGPoint(x: -7, y: -8))
            ctx.addCurve(to: CGPoint(x: 0, y: 7), control1: CGPoint(x: 7, y: -8), control2: CGPoint(x: 10, y: 0))
        case .leaf:
            ctx.move(to: CGPoint(x: -8, y: 6))
            ctx.addQuadCurve(to: CGPoint(x: 8, y: -7), control: CGPoint(x: -6, y: -7))
            ctx.addQuadCurve(to: CGPoint(x: -8, y: 6), control: CGPoint(x: 6, y: 6))
            ctx.move(to: CGPoint(x: -8, y: 6)); ctx.addLine(to: CGPoint(x: 4, y: -3))
        case .sun:
            ctx.addEllipse(in: CGRect(x: -4.5, y: -4.5, width: 9, height: 9))
            for i in 0..<8 {
                let a = CGFloat(i) * .pi / 4
                ctx.move(to: CGPoint(x: cos(a) * 7, y: sin(a) * 7)); ctx.addLine(to: CGPoint(x: cos(a) * 10, y: sin(a) * 10))
            }
        }
        ctx.strokePath()
        ctx.restoreGState()
    }

    func drawPaper(_ c: Card, lift: Int, alpha: CGFloat = 1) {
        let st = c.styleDef
        let cc = c.center, w = c.w, h = c.h, x0 = -w / 2, y0 = -h / 2
        ctx.saveGState()
        ctx.setAlpha(alpha)
        ctx.translateBy(x: cc.x, y: cc.y); ctx.rotate(by: c.th)
        if c.sc != 1 { ctx.scaleBy(x: c.sc, y: c.sc) }
        let S: [(CGFloat, CGFloat, CGFloat)] = [(4, 1, 2), (12, 3, 8), (30, 9, 24)]
        let s = S[min(2, max(0, lift))]
        shadow(s.1, s.2, s.0, rgba(40, 46, 62, 0.22))
        let path = paperPath(c)
        ctx.addPath(path); ctx.setFillColor(rgb(st.color)); ctx.fillPath()
        noShadow()

        ctx.saveGState()
        ctx.addPath(path); ctx.clip()
        paperTexture(c)
        linear([rgba(255, 255, 255, 0.22), rgba(255, 255, 255, 0), rgba(60, 45, 25, 0.06)], [0, 0.3, 1],
               CGPoint(x: 0, y: y0), CGPoint(x: 0, y: y0 + h))
        let sx = sin(c.th) * w
        let glint = 0.05 + min(0.12, abs(c.om) * 0.03)
        linear([rgba(255, 255, 255, 0), rgba(255, 255, 255, glint), rgba(255, 255, 255, 0)], [0, 0.5, 1],
               CGPoint(x: x0 - sx, y: y0), CGPoint(x: x0 + w + sx, y: y0 + h))
        ctx.restoreGState()

        // title with a highlighter swipe, then handwriting
        let pad: CGFloat = st.paper == .lined ? 17 : 14
        let maxW = w - pad - 14
        let parts = c.text.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false)
        let title = parts.first.map(String.init) ?? ""
        let body = parts.count > 1 ? String(parts[1]) : ""

        let tpara = NSMutableParagraphStyle(); tpara.lineBreakMode = .byTruncatingTail
        let tAttr = NSAttributedString(string: title, attributes: [
            .font: Fonts.title(17), .foregroundColor: NSColor(cgColor: rgb(INK)) ?? .black, .paragraphStyle: tpara,
        ])
        let tMax = maxW - 18
        let tw = min(tAttr.size().width, tMax)
        let base = y0 + 36
        if !title.isEmpty {
            ctx.saveGState()
            ctx.setFillColor(rgb(st.marker, 0.55))
            ctx.beginPath()
            ctx.move(to: CGPoint(x: x0 + pad - 3, y: base - 5)); ctx.addLine(to: CGPoint(x: x0 + pad + tw + 4, y: base - 7))
            ctx.addLine(to: CGPoint(x: x0 + pad + tw + 2, y: base + 3)); ctx.addLine(to: CGPoint(x: x0 + pad - 2, y: base + 4))
            ctx.closePath(); ctx.fillPath()
            ctx.restoreGState()
            tAttr.draw(with: CGRect(x: x0 + pad, y: y0 + 18, width: tMax, height: 24),
                       options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
        }
        if !body.isEmpty {
            let bpara = NSMutableParagraphStyle()
            bpara.minimumLineHeight = 21; bpara.maximumLineHeight = 21
            bpara.lineBreakMode = .byWordWrapping
            let bAttr = NSAttributedString(string: body, attributes: [
                .font: Fonts.hand(15), .foregroundColor: NSColor(cgColor: rgb(INK, 0.85)) ?? .black, .paragraphStyle: bpara,
            ])
            bAttr.draw(with: CGRect(x: x0 + pad, y: y0 + 45, width: maxW, height: h - 45 - 12),
                       options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
        }
        drawDoodle(c)

        // hand-drawn "done" checkbox
        if c.stampAt == nil && (c.mode == .hang || c.mode == .free) {
            let ox = w / 2 - STAMP_OFF, oy = h / 2 - STAMP_OFF
            let on = world.hoverStamp === c, near = world.hoverCard === c
            ctx.saveGState()
            ctx.setAlpha(alpha * (on ? 0.95 : near ? 0.6 : 0.28))
            ctx.setStrokeColor(rgb(on ? SEAL : INK)); ctx.setLineWidth(1.3)
            ctx.setLineCap(.round); ctx.setLineJoin(.round)
            let s: CGFloat = 6.5
            func j(_ k: Double) -> CGFloat { (srand(c.seed, k) - 0.5) * 1.4 }
            ctx.beginPath()
            ctx.move(to: CGPoint(x: ox - s + j(1), y: oy - s + j(2)))
            ctx.addLine(to: CGPoint(x: ox + s + j(3), y: oy - s + j(4)))
            ctx.addLine(to: CGPoint(x: ox + s + j(5), y: oy + s + j(6)))
            ctx.addLine(to: CGPoint(x: ox - s + j(7), y: oy + s + j(8)))
            ctx.closePath(); ctx.strokePath()
            if on {
                ctx.setLineWidth(1.8)
                ctx.beginPath()
                ctx.move(to: CGPoint(x: ox - 4.5, y: oy)); ctx.addLine(to: CGPoint(x: ox - 1, y: oy + 4)); ctx.addLine(to: CGPoint(x: ox + 8, y: oy - 8))
                ctx.strokePath()
            }
            ctx.restoreGState()
        }
        if c.stampAt != nil { drawStamp(c, alpha: alpha) }
        ctx.restoreGState()
    }

    private func drawStamp(_ c: Card, alpha: CGFloat) {
        let k = CGFloat(min(1, (world.tWorld - (c.stampAt ?? 0)) / 0.14))
        let e = 1 - pow(1 - k, 3)
        let s = 1.9 - 0.9 * e
        ctx.saveGState()
        ctx.translateBy(x: c.w / 2 - 44, y: c.h / 2 - 36); ctx.rotate(by: -0.24); ctx.scaleBy(x: s, y: s)
        ctx.setAlpha(alpha * 0.82 * k)
        ctx.setBlendMode(.multiply)
        ctx.setStrokeColor(rgb(SEAL))
        ctx.setLineWidth(2.6); ctx.strokeEllipse(in: CGRect(x: -27, y: -27, width: 54, height: 54))
        ctx.setLineWidth(0.9); ctx.strokeEllipse(in: CGRect(x: -22.5, y: -22.5, width: 45, height: 45))
        drawCentered(text("完成", font: Fonts.title(17), color: rgb(SEAL)), at: CGPoint(x: 0, y: -2))
        let d = c.stampDate ?? Date()
        let cal = Calendar.current
        let ds = String(format: "%d.%02d", cal.component(.month, from: d), cal.component(.day, from: d))
        drawCentered(text(ds, font: .monospacedSystemFont(ofSize: 7.5, weight: .semibold), color: rgb(SEAL)), at: CGPoint(x: 0, y: 12))
        // worn ink: specks of paper showing through
        ctx.setBlendMode(.normal)
        ctx.setFillColor(rgb(c.styleDef.color))
        for i in 0..<16 {
            let d = Double(i)
            let a = srand(c.seed, d) * 2 * .pi, r = 16 + srand(c.seed, d + 50) * 13
            dot(CGPoint(x: cos(a) * r, y: sin(a) * r), 0.6 + srand(c.seed, d + 99) * 1.3)
        }
        ctx.restoreGState()
    }

    // MARK: attachments

    func drawAttach(_ c: Card, alpha: CGFloat = 1) {
        let st = c.styleDef
        let cc = c.center, top = rot(c.th, 0, -c.h / 2 * c.sc)
        ctx.saveGState()
        ctx.setAlpha(alpha)
        ctx.translateBy(x: cc.x + top.x, y: cc.y + top.y); ctx.rotate(by: c.th)
        if c.sc != 1 { ctx.scaleBy(x: c.sc, y: c.sc) }
        if st.attach == .tape { drawTape(c) } else { drawPeg(st.peg) }
        ctx.restoreGState()
    }

    private func drawPeg(_ painted: UInt32?) {
        shadow(0, 2, 3, rgba(40, 46, 62, 0.3))
        let base = painted ?? 0xE3C595
        let body = CGPath(roundedRect: CGRect(x: -5, y: -CLIP - 12, width: 10, height: 31), cornerWidth: 4, cornerHeight: 4, transform: nil)
        ctx.addPath(body); ctx.setFillColor(rgb(base)); ctx.fillPath()
        noShadow()
        ctx.saveGState()
        ctx.addPath(body); ctx.clip()
        linear([rgba(255, 255, 255, 0.18), rgba(0, 0, 0, 0.14)], [0, 1], CGPoint(x: -5, y: 0), CGPoint(x: 5, y: 0))
        ctx.restoreGState()
        ctx.setStrokeColor(rgba(70, 50, 30, 0.4)); ctx.setLineWidth(0.8)
        line(CGPoint(x: 0, y: -CLIP - 10), CGPoint(x: 0, y: 18))
        ctx.setFillColor(rgba(70, 50, 30, 0.32))
        ctx.fillEllipse(in: CGRect(x: -3, y: -CLIP - 1.6, width: 6, height: 3.2))
        ctx.addPath(CGPath(roundedRect: CGRect(x: -7, y: 1, width: 14, height: 4.5), cornerWidth: 2, cornerHeight: 2, transform: nil))
        ctx.setFillColor(rgb(0x7A7D84)); ctx.fillPath()
        if painted != nil {   // a tiny painted heart
            ctx.setFillColor(rgba(255, 255, 255, 0.85))
            ctx.beginPath()
            ctx.move(to: CGPoint(x: 0, y: 13))
            ctx.addCurve(to: CGPoint(x: 0, y: 9), control1: CGPoint(x: -4, y: 10), control2: CGPoint(x: -3, y: 7))
            ctx.addCurve(to: CGPoint(x: 0, y: 13), control1: CGPoint(x: 3, y: 7), control2: CGPoint(x: 4, y: 10))
            ctx.fillPath()
        }
    }

    private func drawTape(_ c: Card) {
        let st = c.styleDef
        let tw: CGFloat = 42, y1 = -CLIP - 13, y2: CGFloat = 17
        ctx.rotate(by: (srand(c.seed, 11) - 0.5) * 0.22)
        let p = CGMutablePath()
        p.move(to: CGPoint(x: -tw / 2, y: y1))
        for i in 1...8 { p.addLine(to: CGPoint(x: -tw / 2 + tw * CGFloat(i) / 8, y: y1 + (i % 2 == 1 ? 2.2 : 0))) }
        p.addLine(to: CGPoint(x: tw / 2, y: y2))
        for i in stride(from: 7, through: 0, by: -1) { p.addLine(to: CGPoint(x: -tw / 2 + tw * CGFloat(i) / 8, y: y2 - (i % 2 == 1 ? 2.2 : 0))) }
        p.closeSubpath()
        shadow(0, 1, 2, rgba(40, 46, 62, 0.16))
        ctx.addPath(p); ctx.setFillColor(rgb(st.tape, 0.86)); ctx.fillPath()
        noShadow()
        ctx.saveGState()
        ctx.addPath(p); ctx.clip()
        let ink = rgb(st.tapeInk, 0.72)
        ctx.setFillColor(ink); ctx.setStrokeColor(ink)
        switch st.tapePattern {
        case .stripe:
            ctx.setLineWidth(3.5)
            var i: CGFloat = -60
            while i < 60 { line(CGPoint(x: i, y: y1 - 5), CGPoint(x: i + 30, y: y2 + 5)); i += 9 }
        case .dot:
            var y = y1 + 4, row = 0
            while y < y2 {
                var x = -tw / 2 + 3 + (row % 2 == 1 ? 3.5 : 0)
                while x < tw / 2 { dot(CGPoint(x: x, y: y), 1.4); x += 7 }
                y += 7; row += 1
            }
        case .grid:
            ctx.setLineWidth(0.8)
            var x = -tw / 2 + 5; while x < tw / 2 { line(CGPoint(x: x, y: y1), CGPoint(x: x, y: y2)); x += 6 }
            var y = y1 + 4; while y < y2 { line(CGPoint(x: -tw / 2, y: y), CGPoint(x: tw / 2, y: y)); y += 6 }
        }
        // the fold where the tape wraps over the twine
        ctx.setFillColor(rgba(255, 255, 255, 0.28)); ctx.fill(CGRect(x: -tw / 2, y: -CLIP - 2.5, width: tw, height: 2.2))
        ctx.setFillColor(rgba(40, 46, 62, 0.10)); ctx.fill(CGRect(x: -tw / 2, y: -CLIP + 0.5, width: tw, height: 1.5))
        ctx.restoreGState()
    }

    // MARK: crumpled ball

    private func drawBall(_ c: Card) {
        let t = min(1, c.t)
        if t < 1 {
            c.sc = 1 - 0.72 * t
            drawPaper(c, lift: 2, alpha: 1 - t); drawAttach(c, alpha: 1 - t)
        }
        ctx.saveGState()
        ctx.setAlpha(t)
        ctx.translateBy(x: c.c.x, y: c.c.y); ctx.rotate(by: c.th)
        shadow(0, 8, 10, rgba(40, 46, 62, 0.25))
        let R: CGFloat = 27, n = 13
        let p = CGMutablePath()
        for i in 0..<n {
            let a = CGFloat(i) / CGFloat(n) * 2 * .pi, r = R * (0.78 + srand(c.seed, Double(i)) * 0.3)
            let pt = CGPoint(x: cos(a) * r, y: sin(a) * r)
            if i == 0 { p.move(to: pt) } else { p.addLine(to: pt) }
        }
        p.closeSubpath()
        ctx.addPath(p); ctx.setFillColor(rgb(c.styleDef.color)); ctx.fillPath()
        noShadow()
        ctx.addPath(p); ctx.clip()
        radial([rgba(255, 255, 255, 0.45), rgba(50, 40, 30, 0.22)], [0, 1], CGPoint(x: -8, y: -10), 2, .zero, R * 1.1)
        ctx.setStrokeColor(rgba(60, 50, 40, 0.28)); ctx.setLineWidth(0.9)
        for i in 0..<7 {
            let d = Double(i)
            let a = srand(c.seed, d + 20) * 2 * .pi, b = a + 1.2 + srand(c.seed, d + 40) * 2.5
            ctx.beginPath()
            ctx.move(to: CGPoint(x: cos(a) * R, y: sin(a) * R))
            ctx.addLine(to: CGPoint(x: (srand(c.seed, d + 60) - 0.5) * 14, y: (srand(c.seed, d + 70) - 0.5) * 14))
            ctx.addLine(to: CGPoint(x: cos(b) * R, y: sin(b) * R))
            ctx.strokePath()
        }
        ctx.restoreGState()
    }

    // MARK: kraft envelope for finished notes

    private func squash() {
        let b = world.basket
        ctx.translateBy(x: b.x, y: b.bottom); ctx.scaleBy(x: 2 - b.s, y: b.s); ctx.translateBy(x: -b.x, y: -b.bottom)
    }

    private func drawEnvelope() {
        let b = world.basket, x = b.x, top = b.rim, bottom = b.bottom, hw: CGFloat = 66
        // back panel, open flap, peeking notes
        ctx.saveGState(); squash()
        shadow(0, 4, 10, rgba(40, 46, 62, 0.2))
        ctx.setFillColor(rgb(0xB48A5C)); ctx.fill(CGRect(x: x - hw, y: top - 4, width: hw * 2, height: bottom - top + 4))
        noShadow()
        let flap = CGMutablePath()
        flap.move(to: CGPoint(x: x - hw, y: top - 4)); flap.addLine(to: CGPoint(x: x - 10, y: top - 44))
        flap.addQuadCurve(to: CGPoint(x: x + 10, y: top - 44), control: CGPoint(x: x, y: top - 50))
        flap.addLine(to: CGPoint(x: x + hw, y: top - 4)); flap.closeSubpath()
        ctx.addPath(flap); ctx.setFillColor(rgb(0xC29A6B)); ctx.fillPath()
        ctx.addPath(flap); ctx.setStrokeColor(rgba(90, 60, 30, 0.25)); ctx.setLineWidth(1); ctx.strokePath()
        ctx.setFillColor(rgba(70, 45, 20, 0.22)); ctx.fill(CGRect(x: x - hw + 4, y: top - 4, width: hw * 2 - 8, height: 8))
        let peeks = Array(world.finished.prefix(4))
        for (i, c) in peeks.enumerated().reversed() {
            ctx.saveGState()
            ctx.translateBy(x: x - 34 + CGFloat(i) * 22, y: top + 6); ctx.rotate(by: (srand(c.seed, 3) - 0.5) * 0.5)
            shadow(0, 0, 3, rgba(40, 46, 62, 0.15))
            ctx.setFillColor(rgb(c.styleDef.color)); ctx.fill(CGRect(x: -15, y: -18, width: 30, height: 30))
            ctx.restoreGState()
        }
        ctx.restoreGState()

        // notes sliding in: visible above the mouth only
        let sinking = world.cards.filter { $0.mode == .sink }.sorted { $0.z < $1.z }
        if !sinking.isEmpty {
            ctx.saveGState()
            ctx.clip(to: CGRect(x: -1000, y: -1000, width: world.W + 2000, height: top + 1004))
            for c in sinking { drawPaper(c, lift: 2); drawAttach(c) }
            ctx.restoreGState()
        }

        // front pocket
        ctx.saveGState(); squash()
        let front = CGMutablePath()
        front.move(to: CGPoint(x: x - hw, y: top + 2)); front.addLine(to: CGPoint(x: x - 16, y: top + 2))
        front.addQuadCurve(to: CGPoint(x: x + 16, y: top + 2), control: CGPoint(x: x, y: top + 16))
        front.addLine(to: CGPoint(x: x + hw, y: top + 2)); front.addLine(to: CGPoint(x: x + hw, y: bottom))
        front.addLine(to: CGPoint(x: x - hw, y: bottom)); front.closeSubpath()
        ctx.saveGState()
        ctx.addPath(front); ctx.clip()
        linear([rgb(0xD8B487), rgb(0xC9A275)], [0, 1], CGPoint(x: 0, y: top), CGPoint(x: 0, y: bottom))
        ctx.setLineWidth(0.7)
        for i in 0..<60 {
            let d = Double(i)
            let fx = x - hw + srand(7, d) * hw * 2, fy = top + srand(8, d) * (bottom - top)
            let a = srand(9, d) * .pi, l = 3 + srand(10, d) * 8
            ctx.setStrokeColor(i % 3 != 0 ? rgba(110, 75, 35, 0.15) : rgba(255, 240, 215, 0.3))
            line(CGPoint(x: fx, y: fy), CGPoint(x: fx + cos(a) * l, y: fy + sin(a) * l))
        }
        ctx.setStrokeColor(rgba(100, 65, 30, 0.22)); ctx.setLineWidth(1)
        line(CGPoint(x: x - hw, y: bottom), CGPoint(x: x - 6, y: top + 44))
        line(CGPoint(x: x + hw, y: bottom), CGPoint(x: x + 6, y: top + 44))
        ctx.restoreGState()
        // stitching
        ctx.setLineDash(phase: 0, lengths: [3, 3]); ctx.setStrokeColor(rgba(255, 248, 235, 0.75)); ctx.setLineWidth(1)
        ctx.stroke(CGRect(x: x - hw + 5, y: top + 8, width: hw * 2 - 10, height: bottom - top - 13))
        ctx.setLineDash(phase: 0, lengths: [])
        // label
        ctx.saveGState()
        ctx.translateBy(x: x - 18, y: top + 38); ctx.rotate(by: -0.05)
        shadow(0, 1, 2, rgba(40, 46, 62, 0.15))
        ctx.setFillColor(rgb(0xFBFAF5)); ctx.fill(CGRect(x: -30, y: -12, width: 60, height: 24))
        noShadow()
        let n = world.finished.count
        drawCentered(text(n > 0 ? "已完成 \(n)" : "已完成", font: Fonts.title(14), color: rgb(INK)), at: CGPoint(x: 0, y: 1))
        ctx.restoreGState()
        // button & string
        let bx = x + 40, by = top + 38
        ctx.setStrokeColor(rgb(0xF3EEE6)); ctx.setLineWidth(1.4)
        ctx.beginPath(); ctx.move(to: CGPoint(x: bx, y: by))
        ctx.addCurve(to: CGPoint(x: bx + 18, y: by + 26), control1: CGPoint(x: bx + 14, y: by + 10), control2: CGPoint(x: bx + 4, y: by + 20))
        ctx.strokePath()
        ctx.setFillColor(rgb(0xE9D9BE)); dot(CGPoint(x: bx, y: by), 6.5)
        ctx.setStrokeColor(rgba(90, 60, 30, 0.35)); ctx.setLineWidth(0.8)
        ctx.strokeEllipse(in: CGRect(x: bx - 6.5, y: by - 6.5, width: 13, height: 13))
        ctx.setFillColor(rgba(90, 60, 30, 0.45))
        for (dx, dy) in [(-1.8, -1.8), (1.8, -1.8), (-1.8, 1.8), (1.8, 1.8)] as [(CGFloat, CGFloat)] { dot(CGPoint(x: bx + dx, y: by + dy), 0.9) }
        ctx.restoreGState()
    }

    private func drawHotLabel() {
        let b = world.basket
        let s = text("松手放进信封", font: Fonts.title(14), color: rgb(0xFBFAF5))
        let sz = s.size(), w = sz.width + 20, y = b.rim - 66
        ctx.addPath(CGPath(roundedRect: CGRect(x: b.x - w / 2, y: y - 12, width: w, height: 24), cornerWidth: 8, cornerHeight: 8, transform: nil))
        ctx.setFillColor(rgb(INK)); ctx.fillPath()
        drawCentered(s, at: CGPoint(x: b.x, y: y))
    }

    // MARK: undo strip

    private func drawToast() {
        guard let t = world.toast else { world.toastRect = .zero; world.toastButton = .zero; return }
        let left = t.until - world.tWorld
        let a = CGFloat(min(1, max(0, left / 0.3)))
        let label = text("已完成「\(t.card.title)」", font: Fonts.hand(15), color: rgb(INK))
        let btn = text("撤销", font: Fonts.title(14), color: rgb(0xFBFAF5))
        let ls = label.size(), bs = btn.size()
        let h: CGFloat = 36, bw = bs.width + 24
        let w = 16 + ls.width + 12 + bw + 7
        let x = world.basket.x + 82, y = world.basket.bottom - 44
        let rect = CGRect(x: x, y: y, width: w, height: h)
        world.toastRect = rect
        world.toastButton = CGRect(x: rect.maxX - 7 - bw, y: y + 6, width: bw, height: h - 12)
        ctx.saveGState()
        ctx.setAlpha(a)
        ctx.translateBy(x: rect.midX, y: rect.midY); ctx.rotate(by: 0.01); ctx.translateBy(x: -rect.midX, y: -rect.midY)
        shadow(0, 8, 22, rgba(40, 46, 62, 0.2))
        ctx.setFillColor(rgb(0xFDFCF8)); ctx.fill(rect)
        noShadow()
        // bit of washi tape holding it down
        ctx.saveGState()
        ctx.translateBy(x: x, y: y + h / 2); ctx.rotate(by: -0.2)
        ctx.setFillColor(rgb(0xE9C25E, 0.8)); ctx.fill(CGRect(x: -12, y: -7, width: 26, height: 14))
        ctx.restoreGState()
        label.draw(at: CGPoint(x: x + 16, y: rect.midY - ls.height / 2))
        let br = world.toastButton
        ctx.addPath(CGPath(roundedRect: br, cornerWidth: 3, cornerHeight: 3, transform: nil))
        ctx.setFillColor(rgb(INK)); ctx.fillPath()
        drawCentered(btn, at: CGPoint(x: br.midX, y: br.midY))
        ctx.restoreGState()
    }
}
