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
    /// Titles: rounded hand lettering for the journal look, system sans for sticky notes.
    static func title(_ size: CGFloat) -> NSFont {
        if Theme.current == .sticky { return .systemFont(ofSize: size, weight: .semibold) }
        return NSFont(name: "ZCOOLKuaiLe-Regular", size: size) ?? .systemFont(ofSize: size, weight: .semibold)
    }
    /// Body text: neat handwriting for the journal look, system sans for sticky notes.
    static func hand(_ size: CGFloat) -> NSFont {
        if Theme.current == .sticky { return .systemFont(ofSize: size - 1) }
        return NSFont(name: "LXGWWenKaiTC-Regular", size: size) ?? .systemFont(ofSize: size)
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
        for c in world.cards.filter({ $0.mode == .free }).sorted(by: { $0.z < $1.z }) { drawPaper(c, lift: 0); drawAttach(c) }
        let hanging = world.cards.filter { $0.mode == .hang }
        drawGhost()
        for c in hanging { drawPaper(c, lift: 1) }
        if !world.ropeHidden { drawRope(); if Theme.current == .christmas { drawRopeTrinkets(hanging) } }
        for c in hanging { drawAttach(c) }
        if world.ropeHidden { drawSinking() } else { drawBottle(); drawPlus() }
        for c in world.cards where c.mode == .crumple { drawBall(c, morph: min(1, c.t), scale: 1) }
        for c in world.cards where c.mode == .trash {
            let t = min(1, c.t)
            drawBall(c, morph: min(1, t / 0.25), scale: 1 - 0.35 * max(0, (t - 0.25) / 0.75))
        }
        if let d = world.dragging { drawPaper(d, lift: 2); drawAttach(d) }
        if world.bottle.hot { drawHotLabel() }
        if world.trashHint, let d = world.dragging { drawTrashHint(d) }
        drawToast()
        drawGuide()
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
        if Theme.current == .sticky {
            // a plain grey cord
            shadow(0, 3, 2.5, rgba(30, 30, 40, 0.22))
            ctx.addPath(path); ctx.setStrokeColor(rgb(0x8C8F96)); ctx.setLineWidth(1.6); ctx.strokePath()
            noShadow()
            ctx.translateBy(x: 0, y: -0.5)
            ctx.addPath(path); ctx.setStrokeColor(rgba(255, 255, 255, 0.55)); ctx.setLineWidth(0.5); ctx.strokePath()
            ctx.restoreGState()
            return
        }
        if Theme.current == .christmas {
            drawGarland(path)
            ctx.restoreGState()
            return
        }
        // red & white baker's twine
        shadow(0, 4, 3, rgba(40, 46, 62, 0.2))
        ctx.addPath(path); ctx.setStrokeColor(rgb(0xF4EFE7)); ctx.setLineWidth(3.2); ctx.strokePath()
        noShadow()
        ctx.setLineCap(.butt)
        ctx.setLineDash(phase: 0, lengths: [2.6, 3.2])
        ctx.addPath(path); ctx.setStrokeColor(rgb(Theme.paperActive ? 0x8FB4E3 : SEAL)); ctx.setLineWidth(3.2); ctx.strokePath()
        ctx.setLineDash(phase: 0, lengths: [])
        ctx.translateBy(x: 0, y: -0.8)
        ctx.addPath(path); ctx.setStrokeColor(rgba(255, 255, 255, 0.35)); ctx.setLineWidth(0.8); ctx.strokePath()
        ctx.restoreGState()
    }

    /// Christmas: plain jute twine, with greenery tied at both ends.
    private func drawGarland(_ path: CGPath) {
        shadow(0, 3, 2.5, rgba(70, 50, 25, 0.22))
        ctx.addPath(path); ctx.setStrokeColor(rgb(0xC8A777)); ctx.setLineWidth(3); ctx.strokePath()
        noShadow()
        ctx.setLineCap(.butt)
        ctx.setLineDash(phase: 0, lengths: [1.6, 2.2])
        ctx.addPath(path); ctx.setStrokeColor(rgb(0x9C7A4C, 0.75)); ctx.setLineWidth(3); ctx.strokePath()
        ctx.setLineDash(phase: 0, lengths: [])
        ctx.saveGState()
        ctx.translateBy(x: 0, y: -0.7)
        ctx.addPath(path); ctx.setStrokeColor(rgba(255, 245, 220, 0.4)); ctx.setLineWidth(0.7); ctx.strokePath()
        ctx.restoreGState()
    }

    /// A bundle of pine, eucalyptus and red berries tied with a jute bow (mirrored on the right).
    private func drawSprig(at p: CGPoint, mirror: CGFloat) {
        ctx.saveGState()
        ctx.translateBy(x: p.x, y: p.y); ctx.scaleBy(x: mirror * 1.45, y: 1.45)
        ctx.setLineCap(.round); ctx.setLineJoin(.round)
        // pine needles fanning down and inward
        ctx.setStrokeColor(rgb(0x4F6E4C)); ctx.setLineWidth(0.9)
        for (ang, len) in [(0.35, 30.0), (0.85, 26.0), (1.35, 22.0), (-0.1, 24.0)] as [(CGFloat, CGFloat)] {
            let e = CGPoint(x: cos(ang) * len, y: sin(ang) * len)
            line(.zero, e)
            var t: CGFloat = 0.2
            while t < 1 {
                let q = CGPoint(x: e.x * t, y: e.y * t)
                line(q, CGPoint(x: q.x + cos(ang + 0.6) * 5, y: q.y + sin(ang + 0.6) * 5))
                line(q, CGPoint(x: q.x + cos(ang - 0.6) * 5, y: q.y + sin(ang - 0.6) * 5))
                t += 0.14
            }
        }
        // eucalyptus: round sage leaves on thin stems
        for (ang, len) in [(0.6, 34.0), (1.1, 28.0), (-0.35, 30.0), (1.6, 20.0)] as [(CGFloat, CGFloat)] {
            ctx.setStrokeColor(rgb(0x7E9A7A)); ctx.setLineWidth(0.7)
            let e = CGPoint(x: cos(ang) * len, y: sin(ang) * len)
            line(.zero, e)
            var t: CGFloat = 0.3
            var side: CGFloat = 1
            while t <= 1.0 {
                let q = CGPoint(x: e.x * t + cos(ang + .pi / 2) * 3.5 * side, y: e.y * t + sin(ang + .pi / 2) * 3.5 * side)
                let rr: CGFloat = 4.2 - t * 1.6
                ctx.setFillColor(rgb(side > 0 ? 0xA6BBA2 : 0x93AC8F)); dot(q, rr)
                ctx.setStrokeColor(rgba(255, 255, 255, 0.35)); ctx.setLineWidth(0.4)
                ctx.strokeEllipse(in: CGRect(x: q.x - rr, y: q.y - rr, width: rr * 2, height: rr * 2))
                t += 0.23; side = -side
            }
        }
        // red berries
        for (x, y) in [(6.0, 7.0), (10.0, 4.0), (9.0, 10.0), (14.0, 8.0), (3.0, 12.0), (17.0, 14.0), (13.0, 15.0)] as [(CGFloat, CGFloat)] {
            ctx.setFillColor(rgb(0xB23A34)); dot(CGPoint(x: x, y: y), 2.3)
            ctx.setFillColor(rgba(255, 255, 255, 0.45)); dot(CGPoint(x: x - 0.7, y: y - 0.8), 0.6)
        }
        // jute bow
        ctx.setStrokeColor(rgb(0xB8935F)); ctx.setLineWidth(1.4)
        ctx.beginPath()
        ctx.move(to: .zero); ctx.addCurve(to: .zero, control1: CGPoint(x: -12, y: -10), control2: CGPoint(x: -13, y: 3))
        ctx.move(to: .zero); ctx.addCurve(to: .zero, control1: CGPoint(x: -4, y: -14), control2: CGPoint(x: 6, y: -10))
        ctx.move(to: .zero); ctx.addQuadCurve(to: CGPoint(x: -9, y: 12), control: CGPoint(x: -3, y: 5))
        ctx.strokePath()
        ctx.setFillColor(rgb(0xA8834F)); dot(.zero, 2)
        ctx.restoreGState()
    }

    /// Christmas: greenery at the ends, and two or three felt ornaments in the widest empty stretches.
    private func drawRopeTrinkets(_ hanging: [Card]) {
        let W = world.W
        drawRopeGreenery()
        drawSprig(at: CGPoint(x: 30, y: world.ropeAt(30).y), mirror: -1)
        drawSprig(at: CGPoint(x: W - 28, y: world.ropeAt(W - 28).y), mirror: 1)
        var busy = hanging.map { ($0.center.x - CW / 2 - 18, $0.center.x + CW / 2 + 18) }
        if let d = world.dragging { busy.append((d.center.x - CW / 2 - 18, d.center.x + CW / 2 + 18)) }
        busy.append((-100, 150)); busy.append((W - 120, W + 100))   // bottle and "+" ends
        busy.sort { $0.0 < $1.0 }
        var gaps: [(CGFloat, CGFloat)] = []
        var edge: CGFloat = -100
        for b in busy {
            if b.0 > edge { gaps.append((edge, b.0)) }
            edge = max(edge, b.1)
        }
        // at most one ornament per gap, the three widest gaps that fit one
        for g in gaps where g.1 - g.0 > 220 { beadSwag(from: g.0 + 22, to: g.1 - 22) }
        var spots: [CGFloat] = []
        for g in gaps.filter({ $0.1 - $0.0 > 80 }).sorted(by: { ($0.1 - $0.0) > ($1.1 - $1.0) }) {
            let wdt = g.1 - g.0
            let n = wdt > 900 ? 3 : wdt > 520 ? 2 : 1   // a long empty stretch gets a few, spaced out
            for k in 0..<n { spots.append(g.0 + wdt * CGFloat(k + 1) / CGFloat(n + 1)) }
            if spots.count >= 3 { break }
        }
        spots = Array(spots.prefix(3)).sorted()
        var used = Set<Int>()
        for (i, x) in spots.enumerated() {
            let slot = Int(x / 230) + i
            let r = world.ropeAt(x)
            let sway = sin(world.tWorld * 1.2 + Double(i) * 1.7) * 0.05
            ctx.saveGState()
            ctx.translateBy(x: r.x, y: r.y); ctx.rotate(by: sway)
            // a mix of baubles, Santa hats, candy canes and gingerbread men; a felt one now and then
            let seq = [0, 3, 5, 1, 4, 2, 6, 3, 0, 5, 2, 4]
            let lens: [CGFloat] = [10, 64, 30, 84, 18, 48, 72, 24, 56, 38, 92, 14]
            func pick(_ from: Int) -> Int {   // next kind not yet on the rope (baubles count as one family)
                for k in 0..<seq.count {
                    let v = seq[(from + k) % seq.count]
                    let fam = v <= 2 ? -1 : v
                    if fam == -1 ? !used.contains(v) && used.filter({ $0 <= 2 }).count < 2 : !used.contains(fam) { return v }
                }
                return seq[from % seq.count]
            }
            let main = pick(slot)
            used.insert(main)
            hangOrnament(main, len: lens[(slot * 5 + i * 7) % lens.count], scale: 1.45)
            if slot % 3 != 1 {   // a smaller partner beside it, at a quite different length
                var other = pick(slot + 5)
                if other == 6 { other = pick(slot + 6) }
                used.insert(other)
                ctx.translateBy(x: 27, y: 2)
                hangOrnament(other, len: lens[(slot * 5 + i * 7 + 5) % lens.count] * 0.8, scale: 1.05)
            }
            ctx.restoreGState()
        }
    }

    /// One hanging decoration: 0–2 baubles (red / cream / green), 3 Santa hat, 4 candy cane, 5 gingerbread man, 6 felt ornament.
    private func hangOrnament(_ kind: Int, len: CGFloat, scale: CGFloat) {
        ctx.saveGState()
        ctx.scaleBy(x: scale, y: scale)
        let l = len / scale
        switch kind {
        case 0, 1, 2: folkBauble(len: l, kind: kind)
        case 3: santaHat(len: l)
        case 4: candyCane(len: l)
        case 5: gingerbread(len: l)
        default:
            switch Int(len) % 4 {
            case 0: feltTree()
            case 1: feltMittens()
            case 2: feltStocking()
            default: feltWreath()
            }
            miniPeg()
        }
        ctx.restoreGState()
    }

    private func thread(_ len: CGFloat) {
        ctx.setStrokeColor(rgb(0xE2A93B)); ctx.setLineWidth(0.9)
        line(.zero, CGPoint(x: 0, y: len))
    }

    /// Red Santa hat hanging by its pompom, tip flopped to one side, white fur brim.
    private func santaHat(len: CGFloat) {
        thread(len)
        ctx.saveGState()
        ctx.translateBy(x: 0, y: len); ctx.rotate(by: -0.12)
        let hat = CGMutablePath()
        hat.move(to: CGPoint(x: 1, y: 3))
        hat.addQuadCurve(to: CGPoint(x: 12, y: 28), control: CGPoint(x: 13, y: 6))
        hat.addLine(to: CGPoint(x: -11, y: 28))
        hat.addQuadCurve(to: CGPoint(x: -2, y: 4), control: CGPoint(x: -9, y: 10))
        hat.closeSubpath()
        shadow(0, 2, 3, rgba(40, 30, 25, 0.22))
        ctx.addPath(hat); ctx.setFillColor(rgb(0xD8423A)); ctx.fillPath()
        noShadow()
        ctx.saveGState(); ctx.addPath(hat); ctx.clip()
        linear([rgba(255, 255, 255, 0.18), rgba(60, 0, 0, 0.3)], [0, 1], CGPoint(x: -10, y: 5), CGPoint(x: 12, y: 28))
        ctx.restoreGState()
        ctx.setStrokeColor(rgba(255, 255, 255, 0.35)); ctx.setLineWidth(0.8)
        ctx.beginPath(); ctx.move(to: CGPoint(x: 2, y: 8)); ctx.addQuadCurve(to: CGPoint(x: 6, y: 24), control: CGPoint(x: 8, y: 14)); ctx.strokePath()
        let brim = CGPath(roundedRect: CGRect(x: -13, y: 25, width: 27, height: 7), cornerWidth: 3.5, cornerHeight: 3.5, transform: nil)
        ctx.addPath(brim); ctx.setFillColor(rgb(0xFBF1E1)); ctx.fillPath()
        ctx.setFillColor(rgb(0xE6D9C4))
        for k in 0..<6 { dot(CGPoint(x: -10 + CGFloat(k) * 4.2, y: 28.5 + (k % 2 == 0 ? -1 : 1)), 0.8) }
        ctx.setFillColor(rgb(0xFBF1E1)); dot(CGPoint(x: 0, y: 2), 3.6)
        ctx.restoreGState()
    }

    /// Red-and-white candy cane hooked on the thread.
    private func candyCane(len: CGFloat) {
        thread(len)
        let p = CGMutablePath()
        p.move(to: CGPoint(x: -9, y: len + 9))
        p.addArc(center: CGPoint(x: -4.5, y: len + 5), radius: 5, startAngle: .pi * 0.85, endAngle: 0, clockwise: false)
        p.addLine(to: CGPoint(x: 0.5, y: len + 38))
        shadow(0, 2, 2.5, rgba(40, 30, 25, 0.22))
        ctx.setLineCap(.round)
        ctx.addPath(p); ctx.setStrokeColor(rgb(0xFBF1E1)); ctx.setLineWidth(4.6); ctx.strokePath()
        noShadow()
        ctx.setLineCap(.butt); ctx.setLineDash(phase: 0, lengths: [2.6, 2.6])
        ctx.addPath(p); ctx.setStrokeColor(rgb(0xD8423A)); ctx.setLineWidth(4.6); ctx.strokePath()
        ctx.setLineDash(phase: 1.3, lengths: [0.8, 4.4])
        ctx.addPath(p); ctx.setStrokeColor(rgb(0x3E8A4E)); ctx.setLineWidth(4.6); ctx.strokePath()
        ctx.setLineDash(phase: 0, lengths: [])
        // tiny red bow where it hangs
        miniBow(CGPoint(x: 0.5, y: len + 15), 0xD8423A, 0, size: 0.55)
    }

    /// Gingerbread man with white icing.
    private func gingerbread(len: CGFloat) {
        thread(len)
        let y = len
        let body = CGMutablePath()
        body.addEllipse(in: CGRect(x: -6.5, y: y, width: 13, height: 12))
        body.addPath(CGPath(roundedRect: CGRect(x: -6.5, y: y + 10, width: 13, height: 14), cornerWidth: 5, cornerHeight: 5, transform: nil))
        // arms and legs as fat rounded strokes
        let limbs = CGMutablePath()
        limbs.move(to: CGPoint(x: -12, y: y + 17)); limbs.addLine(to: CGPoint(x: 12, y: y + 13))
        limbs.move(to: CGPoint(x: -3, y: y + 20)); limbs.addLine(to: CGPoint(x: -8, y: y + 32))
        limbs.move(to: CGPoint(x: 3, y: y + 20)); limbs.addLine(to: CGPoint(x: 8, y: y + 32))
        let fat = limbs.copy(strokingWithWidth: 7, lineCap: .round, lineJoin: .round, miterLimit: 1)
        shadow(0, 2, 3, rgba(60, 35, 15, 0.25))
        ctx.setFillColor(rgb(0xC48447))
        ctx.addPath(fat); ctx.fillPath()
        ctx.addPath(body); ctx.fillPath()
        noShadow()
        ctx.saveGState()
        ctx.addPath(fat); ctx.addPath(body); ctx.clip()
        radial([rgba(255, 220, 170, 0.35), rgba(90, 45, 10, 0.3)], [0, 1], CGPoint(x: -3, y: y + 8), 2, CGPoint(x: 0, y: y + 16), 22)
        ctx.restoreGState()
        // icing squiggles at wrists and ankles
        ctx.setStrokeColor(rgb(0xFFF8EE)); ctx.setLineWidth(0.9); ctx.setLineCap(.round)
        func zig(_ x: CGFloat, _ yy: CGFloat, _ vertical: Bool) {
            ctx.beginPath()
            for k in 0..<4 {
                let t = CGFloat(k) * 1.8 - 2.7
                let pt = vertical ? CGPoint(x: x + (k % 2 == 0 ? -1.2 : 1.2), y: yy + t) : CGPoint(x: x + t, y: yy + (k % 2 == 0 ? -1.2 : 1.2))
                if k == 0 { ctx.move(to: pt) } else { ctx.addLine(to: pt) }
            }
            ctx.strokePath()
        }
        zig(-10, y + 17, true); zig(10, y + 13.5, true)
        zig(-7, y + 29.5, false); zig(7, y + 29.5, false)
        // face and buttons
        ctx.setFillColor(rgb(0x4A2A14)); dot(CGPoint(x: -2.2, y: y + 5), 0.9); dot(CGPoint(x: 2.2, y: y + 5), 0.9)
        ctx.setStrokeColor(rgb(0xFFF8EE)); ctx.setLineWidth(0.8)
        ctx.beginPath(); ctx.addArc(center: CGPoint(x: 0, y: y + 6.5), radius: 2.5, startAngle: 0.4, endAngle: .pi - 0.4, clockwise: false); ctx.strokePath()
        ctx.setFillColor(rgb(0xD8423A)); dot(CGPoint(x: 0, y: y + 15), 1.3)
        ctx.setFillColor(rgb(0x3E8A4E)); dot(CGPoint(x: 0, y: y + 19.5), 1.3)
    }

    /// Flat, printed-paper bauble: gold cap with a looped bow, stripes, a flower and two snowflakes.
    /// kind 0 = red, 1 = cream, 2 = green. Hangs `len` below the twine.
    private func folkBauble(len: CGFloat, kind: Int) {
        let (body, motif, band): (UInt32, UInt32, UInt32) = [
            (0xD8423A, 0xFBF1E1, 0xFBF1E1),
            (0xFBF1E1, 0xD8423A, 0xE0703F),
            (0x3E8A4E, 0xFBF1E1, 0xFBF1E1),
        ][kind]
        let R: CGFloat = 15
        let gold = rgb(0xE2A93B)
        ctx.saveGState()
        ctx.setStrokeColor(gold); ctx.setLineWidth(0.9)
        line(.zero, CGPoint(x: 0, y: len))
        // looped gold bow and cap
        ctx.setLineWidth(1.3); ctx.setLineCap(.round)
        ctx.beginPath()
        ctx.move(to: CGPoint(x: 0, y: len + 3)); ctx.addCurve(to: CGPoint(x: 0, y: len + 3), control1: CGPoint(x: -10, y: len - 5), control2: CGPoint(x: -9, y: len + 6))
        ctx.move(to: CGPoint(x: 0, y: len + 3)); ctx.addCurve(to: CGPoint(x: 0, y: len + 3), control1: CGPoint(x: 10, y: len - 5), control2: CGPoint(x: 9, y: len + 6))
        ctx.strokePath()
        let capY = len + 3
        ctx.setFillColor(gold)
        ctx.fill(CGRect(x: -4.5, y: capY, width: 9, height: 6))
        ctx.setFillColor(rgb(0xC78E2A)); ctx.fill(CGRect(x: -4.5, y: capY + 4.6, width: 9, height: 1.4))
        // body
        let c = CGPoint(x: 0, y: capY + 5 + R)
        let ball = CGPath(ellipseIn: CGRect(x: c.x - R, y: c.y - R, width: R * 2, height: R * 2), transform: nil)
        shadow(0, 2, 3, rgba(40, 30, 25, 0.22))
        ctx.addPath(ball); ctx.setFillColor(rgb(body)); ctx.fillPath()
        noShadow()
        ctx.addPath(ball); ctx.clip()
        radial([rgba(255, 255, 255, 0.0), rgba(30, 10, 10, 0.28)], [0, 1], CGPoint(x: c.x - 4, y: c.y - 5), 2, c, R * 1.15)
        ctx.setStrokeColor(rgb(band, 0.9)); ctx.setLineWidth(0.8)
        for dy in [-9.5, -7.5, 7.5, 9.5] as [CGFloat] { line(CGPoint(x: c.x - R, y: c.y + dy), CGPoint(x: c.x + R, y: c.y + dy)) }
        // tiny zigzag under the top band
        ctx.beginPath()
        var x = c.x - R
        ctx.move(to: CGPoint(x: x, y: c.y - 5))
        var up = true
        while x < c.x + R { x += 2; ctx.addLine(to: CGPoint(x: x, y: c.y - (up ? 6.2 : 5))); up.toggle() }
        ctx.setLineWidth(0.6); ctx.strokePath()
        // centre flower and two snowflakes
        ctx.setFillColor(rgb(motif))
        for k in 0..<8 {
            let a = CGFloat(k) * .pi / 4
            ctx.saveGState(); ctx.translateBy(x: c.x, y: c.y + 0.5); ctx.rotate(by: a)
            ctx.fillEllipse(in: CGRect(x: 0.8, y: -0.9, width: 4.4, height: 1.8))
            ctx.restoreGState()
        }
        ctx.setFillColor(rgb(body)); dot(CGPoint(x: c.x, y: c.y + 0.5), 0.9)
        radial([rgba(255, 255, 255, 0.6), rgba(255, 255, 255, 0)], [0, 1], CGPoint(x: c.x - 6, y: c.y - 7), 0, CGPoint(x: c.x - 6, y: c.y - 7), 7)
        ctx.setStrokeColor(rgb(motif, 0.95)); ctx.setLineWidth(0.6)
        for sx in [-9.0, 9.0] as [CGFloat] {
            let q = CGPoint(x: c.x + sx, y: c.y + 0.5)
            for k in 0..<3 { let a = CGFloat(k) * .pi / 3; line(CGPoint(x: q.x - cos(a) * 2.6, y: q.y - sin(a) * 2.6), CGPoint(x: q.x + cos(a) * 2.6, y: q.y + sin(a) * 2.6)) }
        }
        ctx.restoreGState()
    }

    /// Evergreen garland wound along the twine: pine tufts, eucalyptus, berries, velvet bows and warm lights.
    private func drawRopeGreenery() {
        let W = world.W
        var x: CGFloat = 70, k = 0
        while x < W - 60 {
            let a = world.ropeAt(x), b = world.ropeAt(x + 6)
            let ang = atan2(b.y - a.y, b.x - a.x)
            ctx.saveGState()
            ctx.translateBy(x: a.x, y: a.y); ctx.rotate(by: ang)
            pineTuft(seed: Double(k) * 7.3)
            if k % 2 == 0 { eucaSpray(seed: Double(k), flip: k % 4 == 0) }
            berries(at: CGPoint(x: 6, y: 2), seed: Double(k))
            ctx.restoreGState()
            x += 54; k += 1
        }
        // bows and lights on top of the greenery
        x = 70 + 54 * 1.5; k = 0
        while x < W - 60 {
            let a = world.ropeAt(x)
            if k % 3 == 1 { velvetBow(at: CGPoint(x: a.x, y: a.y)) }
            k += 1; x += 54
        }
        let colors: [UInt32] = [0xFFD27A, 0xFFE3A3, 0xFFC56B]
        x = 52; k = 0
        while x < W - 40 {
            let a = world.ropeAt(x)
            let tw = 0.65 + 0.35 * sin(world.tWorld * 1.8 + Double(k) * 2.4)
            let col = colors[k % colors.count]
            let p = CGPoint(x: a.x, y: a.y + (k % 2 == 0 ? -3 : 3))
            radial([rgb(col, 0.45 * tw), rgb(col, 0)], [0, 1], p, 0, p, 9)
            ctx.setFillColor(rgb(col, 0.85 + 0.15 * tw)); dot(p, 1.7)
            ctx.setFillColor(rgba(255, 255, 255, 0.9)); dot(p, 0.7)
            x += 27; k += 1
        }
    }

    /// A tuft of pine: a few needled twigs fanning left and right along the rope.
    private func pineTuft(seed: Double) {
        ctx.setLineCap(.round)
        let twigs: [(CGFloat, CGFloat)] = [(-0.25, 24), (0.35, 22), (3.0, 20), (-2.75, 22), (0.9, 14), (2.4, 15)]
        for (j, t) in twigs.enumerated() {
            let ang = t.0 + (srand(seed, Double(j)) - 0.5) * 0.4
            let len = t.1 * (0.85 + srand(seed, Double(j) + 9) * 0.3)
            let e = CGPoint(x: cos(ang) * len, y: sin(ang) * len)
            ctx.setStrokeColor(rgb(0x5B4630, 0.8)); ctx.setLineWidth(0.8)
            line(.zero, e)
            var u: CGFloat = 0.12
            while u < 1.02 {
                let q = CGPoint(x: e.x * u, y: e.y * u)
                let nl = 5.5 * (1.1 - u * 0.4)
                for side in [-1.0, 1.0] as [CGFloat] {
                    let na = ang + side * 0.75
                    ctx.setStrokeColor(rgb(side > 0 ? 0x2F5E3E : 0x3F7550)); ctx.setLineWidth(1.1)
                    line(q, CGPoint(x: q.x + cos(na) * nl, y: q.y + sin(na) * nl))
                }
                u += 0.11
            }
        }
    }

    private func eucaSpray(seed: Double, flip: Bool) {
        let ang: CGFloat = flip ? 2.6 : 0.5
        let e = CGPoint(x: cos(ang) * 22, y: sin(ang) * 22)
        ctx.setStrokeColor(rgb(0x7E9A7A)); ctx.setLineWidth(0.7)
        line(.zero, e)
        var u: CGFloat = 0.3, side: CGFloat = 1
        while u <= 1.0 {
            let q = CGPoint(x: e.x * u + cos(ang + .pi / 2) * 3.4 * side, y: e.y * u + sin(ang + .pi / 2) * 3.4 * side)
            let rr: CGFloat = 4 - u * 1.4
            ctx.saveGState(); ctx.addEllipse(in: CGRect(x: q.x - rr, y: q.y - rr, width: rr * 2, height: rr * 2)); ctx.clip()
            radial([rgb(0xBBCDB6), rgb(0x86A182)], [0, 1], CGPoint(x: q.x - rr * 0.4, y: q.y - rr * 0.4), 0, q, rr * 1.2)
            ctx.restoreGState()
            u += 0.23; side = -side
        }
    }

    private func berries(at c: CGPoint, seed: Double) {
        for j in 0..<3 {
            let p = CGPoint(x: c.x + (srand(seed, Double(j) + 40) - 0.5) * 9, y: c.y + (srand(seed, Double(j) + 60) - 0.3) * 7)
            ctx.saveGState()
            ctx.addEllipse(in: CGRect(x: p.x - 2.4, y: p.y - 2.4, width: 4.8, height: 4.8)); ctx.clip()
            radial([rgb(0xE5544B), rgb(0x9E2421)], [0, 1], CGPoint(x: p.x - 0.8, y: p.y - 0.9), 0, p, 2.6)
            ctx.restoreGState()
            ctx.setFillColor(rgba(255, 255, 255, 0.75)); dot(CGPoint(x: p.x - 0.8, y: p.y - 0.9), 0.55)
        }
    }

    /// Plump red velvet bow with shading.
    private func velvetBow(at p: CGPoint) {
        ctx.saveGState()
        ctx.translateBy(x: p.x, y: p.y)
        shadow(0, 2, 3, rgba(60, 10, 10, 0.3))
        let shape = CGMutablePath()
        for s in [-1.0, 1.0] as [CGFloat] {
            shape.move(to: CGPoint(x: 0, y: 0))
            shape.addCurve(to: CGPoint(x: 0, y: 1.5), control1: CGPoint(x: 13 * s, y: -12), control2: CGPoint(x: 16 * s, y: 9))
            shape.move(to: CGPoint(x: 1.5 * s, y: 1))
            shape.addLine(to: CGPoint(x: 8 * s, y: 17)); shape.addLine(to: CGPoint(x: 5 * s, y: 15.5)); shape.addLine(to: CGPoint(x: 3 * s, y: 18.5))
            shape.addLine(to: CGPoint(x: -1.5 * s, y: 2)); shape.closeSubpath()
        }
        ctx.addPath(shape); ctx.setFillColor(rgb(0xB3221E)); ctx.fillPath()
        noShadow()
        ctx.addPath(shape); ctx.clip()
        radial([rgba(255, 140, 120, 0.55), rgba(255, 100, 90, 0)], [0, 1], CGPoint(x: -5, y: -4), 0, CGPoint(x: -5, y: -4), 9)
        radial([rgba(255, 140, 120, 0.45), rgba(255, 100, 90, 0)], [0, 1], CGPoint(x: 6, y: -4), 0, CGPoint(x: 6, y: -4), 8)
        radial([rgba(60, 0, 0, 0), rgba(60, 0, 0, 0.35)], [0, 1], CGPoint(x: 0, y: 2), 4, CGPoint(x: 0, y: 2), 18)
        ctx.resetClip()
        let knot = CGPath(roundedRect: CGRect(x: -3, y: -3, width: 6, height: 6.5), cornerWidth: 2.2, cornerHeight: 2.2, transform: nil)
        ctx.addPath(knot); ctx.setFillColor(rgb(0x9C1A17)); ctx.fillPath()
        ctx.setFillColor(rgba(255, 170, 150, 0.5)); ctx.fill(CGRect(x: -1.6, y: -2.2, width: 3.2, height: 1.1))
        ctx.restoreGState()
    }

    /// A drooping string of gold beads between two points on the twine.
    private func beadSwag(from a: CGFloat, to b: CGFloat) {
        let pa = world.ropeAt(a), pb = world.ropeAt(b)
        let span = b - a
        let sag = min(46, 16 + span * 0.05)
        let n = Int(span / 5.2)
        for i in 0...n {
            let t = CGFloat(i) / CGFloat(n)
            let x = pa.x + (pb.x - pa.x) * t
            let y = pa.y + (pb.y - pa.y) * t + 4 * sag * t * (1 - t) + 2
            let r: CGFloat = i % 6 == 3 ? 2.6 : 1.6
            let p = CGPoint(x: x, y: y)
            ctx.saveGState()
            ctx.addEllipse(in: CGRect(x: p.x - r, y: p.y - r, width: r * 2, height: r * 2)); ctx.clip()
            radial([rgb(i % 6 == 3 ? 0xF4D7D3 : 0xFBE7A8), rgb(i % 6 == 3 ? 0xC94D46 : 0xC5922F)], [0, 1],
                   CGPoint(x: p.x - r * 0.4, y: p.y - r * 0.4), 0, p, r * 1.2)
            ctx.restoreGState()
        }
    }

    /// Little wooden clothes peg on the twine.
    private func miniPeg() {
        shadow(0, 1, 1.5, rgba(70, 50, 25, 0.3))
        let body = CGPath(roundedRect: CGRect(x: -2.6, y: -6, width: 5.2, height: 15), cornerWidth: 1.5, cornerHeight: 1.5, transform: nil)
        ctx.addPath(body); ctx.setFillColor(rgb(0xDDBF8E)); ctx.fillPath()
        noShadow()
        ctx.setStrokeColor(rgba(110, 80, 45, 0.45)); ctx.setLineWidth(0.5)
        line(CGPoint(x: 0, y: -5), CGPoint(x: 0, y: 8.5))
        ctx.setFillColor(rgb(0x8A8D92)); ctx.fill(CGRect(x: -3.2, y: 1, width: 6.4, height: 1.8))
    }

    /// Soft felt shading: a lighter centre and a faint dashed stitch inside the outline.
    private func felt(_ p: CGPath, _ color: UInt32, stitch: Bool = true) {
        shadow(0, 2, 3, rgba(60, 45, 30, 0.22))
        ctx.addPath(p); ctx.setFillColor(rgb(color)); ctx.fillPath()
        noShadow()
        ctx.saveGState()
        ctx.addPath(p); ctx.clip()
        let bb = p.boundingBox
        radial([rgba(255, 255, 255, 0.22), rgba(255, 255, 255, 0)], [0, 1], CGPoint(x: bb.midX - bb.width * 0.15, y: bb.midY - bb.height * 0.2), 0,
               CGPoint(x: bb.midX, y: bb.midY), max(bb.width, bb.height) * 0.7)
        ctx.restoreGState()
        if stitch {
            ctx.saveGState()
            ctx.addPath(p); ctx.clip()
            ctx.addPath(p); ctx.setStrokeColor(rgba(255, 250, 240, 0.55)); ctx.setLineWidth(1.6)
            ctx.setLineDash(phase: 0, lengths: [0.1, 0.1]); ctx.setLineDash(phase: 0, lengths: [1.6, 1.8])
            ctx.setLineWidth(0.6)
            ctx.translateBy(x: bb.midX, y: bb.midY); ctx.scaleBy(x: 0.82, y: 0.86); ctx.translateBy(x: -bb.midX, y: -bb.midY)
            ctx.addPath(p); ctx.strokePath()
            ctx.restoreGState()
        }
    }

    private func loop(_ to: CGFloat, _ color: UInt32) {
        ctx.setStrokeColor(rgb(color)); ctx.setLineWidth(1.4)
        ctx.beginPath(); ctx.move(to: CGPoint(x: -2.5, y: 4)); ctx.addQuadCurve(to: CGPoint(x: 0, y: to), control: CGPoint(x: -3, y: to - 4))
        ctx.move(to: CGPoint(x: 2.5, y: 4)); ctx.addQuadCurve(to: CGPoint(x: 0, y: to), control: CGPoint(x: 3, y: to - 4)); ctx.strokePath()
    }

    private func feltTree() {
        loop(14, 0xB23A34)
        let p = CGMutablePath()
        let tiers: [(CGFloat, CGFloat, CGFloat)] = [(13, 7, 23), (19, 10.5, 31), (26, 13.5, 40)]
        for (top, half, bot) in tiers {
            p.move(to: CGPoint(x: 0, y: top))
            p.addQuadCurve(to: CGPoint(x: half, y: bot), control: CGPoint(x: half * 0.5, y: bot - 3))
            p.addQuadCurve(to: CGPoint(x: -half, y: bot), control: CGPoint(x: 0, y: bot + 3))
            p.addQuadCurve(to: CGPoint(x: 0, y: top), control: CGPoint(x: -half * 0.5, y: bot - 3))
        }
        ctx.setFillColor(rgb(0x7A5A3A)); ctx.fill(CGRect(x: -2.5, y: 39, width: 5, height: 5))
        felt(p, 0x8FAA86, stitch: false)
        ctx.setFillColor(rgb(0xB23A34))
        for (x, y) in [(-3.0, 21.0), (4.0, 27.0), (-6.0, 33.0), (7.0, 37.0), (1.0, 35.0)] as [(CGFloat, CGFloat)] { dot(CGPoint(x: x, y: y), 1.7) }
    }

    private func feltMittens() {
        ctx.setStrokeColor(rgb(0xD9CBB0)); ctx.setLineWidth(1)
        ctx.beginPath(); ctx.move(to: CGPoint(x: -5, y: 13)); ctx.addLine(to: CGPoint(x: 0, y: 4)); ctx.addLine(to: CGPoint(x: 5, y: 13)); ctx.strokePath()
        for (dx, s) in [(-6.0, 1.0), (6.0, -1.0)] as [(CGFloat, CGFloat)] {
            ctx.saveGState(); ctx.translateBy(x: dx, y: 13); ctx.rotate(by: 0.12 * s); ctx.scaleBy(x: s, y: 1)
            let m = CGMutablePath()
            m.move(to: CGPoint(x: -5, y: 5))
            m.addLine(to: CGPoint(x: -6, y: 18))
            m.addQuadCurve(to: CGPoint(x: 5, y: 21), control: CGPoint(x: -4, y: 25))
            m.addLine(to: CGPoint(x: 7, y: 15))
            m.addQuadCurve(to: CGPoint(x: 6, y: 9), control: CGPoint(x: 11, y: 11))
            m.addLine(to: CGPoint(x: 5, y: 5)); m.closeSubpath()
            felt(m, 0x91AB8B)
            let cuff = CGPath(roundedRect: CGRect(x: -6, y: 0, width: 12, height: 6), cornerWidth: 2, cornerHeight: 2, transform: nil)
            ctx.addPath(cuff); ctx.setFillColor(rgb(0xEFE5D2)); ctx.fillPath()
            ctx.setStrokeColor(rgba(150, 125, 90, 0.35)); ctx.setLineWidth(0.5)
            var x: CGFloat = -4.5; while x < 6 { line(CGPoint(x: x, y: 0.8), CGPoint(x: x, y: 5.2)); x += 1.8 }
            ctx.restoreGState()
        }
    }

    private func feltStocking() {
        loop(10, 0xB23A34)
        let s = CGMutablePath()
        s.move(to: CGPoint(x: -6, y: 15))
        s.addLine(to: CGPoint(x: -6, y: 30))
        s.addQuadCurve(to: CGPoint(x: 3, y: 42), control: CGPoint(x: -7, y: 42))
        s.addLine(to: CGPoint(x: 12, y: 42))
        s.addQuadCurve(to: CGPoint(x: 13, y: 33), control: CGPoint(x: 18, y: 38))
        s.addLine(to: CGPoint(x: 7, y: 30))
        s.addLine(to: CGPoint(x: 7, y: 15)); s.closeSubpath()
        felt(s, 0xB9524A)
        let cuff = CGPath(roundedRect: CGRect(x: -8, y: 9, width: 17, height: 8), cornerWidth: 3, cornerHeight: 3, transform: nil)
        ctx.addPath(cuff); ctx.setFillColor(rgb(0xF1E8D6)); ctx.fillPath()
        ctx.setStrokeColor(rgba(255, 240, 225, 0.8)); ctx.setLineWidth(0.6)
        let c = CGPoint(x: 1, y: 27)
        for k in 0..<3 { let a = CGFloat(k) * .pi / 3; line(CGPoint(x: c.x - cos(a) * 3.2, y: c.y - sin(a) * 3.2), CGPoint(x: c.x + cos(a) * 3.2, y: c.y + sin(a) * 3.2)) }
    }

    private func feltWreath() {
        let c = CGPoint(x: 0, y: 22), R: CGFloat = 11
        shadow(0, 2, 3, rgba(60, 45, 30, 0.2))
        for k in 0..<18 {
            let a = CGFloat(k) / 18 * 2 * .pi
            let q = CGPoint(x: c.x + cos(a) * R, y: c.y + sin(a) * R)
            ctx.setFillColor(rgb(k % 3 == 0 ? 0x8DA888 : k % 3 == 1 ? 0xA6BBA2 : 0x6F8F6B)); dot(q, 3.6)
        }
        noShadow()
        ctx.setStrokeColor(rgb(0x4F6E4C)); ctx.setLineWidth(0.6)
        for k in 0..<12 {
            let a = CGFloat(k) / 12 * 2 * .pi + 0.2
            let q = CGPoint(x: c.x + cos(a) * (R + 2), y: c.y + sin(a) * (R + 2))
            line(q, CGPoint(x: q.x + cos(a + 1.2) * 4, y: q.y + sin(a + 1.2) * 4))
        }
        ctx.setFillColor(rgb(0xB23A34))
        for a in [0.5, 1.9, 2.4, 3.6, 4.4, 5.6] as [CGFloat] { dot(CGPoint(x: c.x + cos(a) * R, y: c.y + sin(a) * R), 1.8) }
        // ribbon from the peg to a bow on top
        ctx.setStrokeColor(rgb(0xB23A34)); ctx.setLineWidth(1.2)
        line(CGPoint(x: 0, y: 4), CGPoint(x: 0, y: 10))
        miniBow(CGPoint(x: 0, y: 11), 0xB23A34, 0, size: 0.75)
    }

    private func drawGhost() {
        guard world.dragging != nil, let sx = world.slotX else { return }
        let r = world.ropeAt(sx)
        ctx.saveGState()
        ctx.translateBy(x: r.x, y: r.y + CLIP)
        let rect = CGRect(x: -CW / 2, y: 0, width: CW, height: world.dragging?.h ?? CH)
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
        if Theme.current == .sticky {
            ctx.saveGState()
            ctx.setStrokeColor(rgb(0x8C8F96)); ctx.setLineWidth(1)
            line(CGPoint(x: r.x, y: r.y), CGPoint(x: p.x, y: p.y - 14))
            shadow(0, 2, 5, rgba(30, 30, 40, 0.22))
            ctx.setFillColor(rgb(hover ? 0xFFFFFF : 0xF7F7F5)); dot(p, 14)
            noShadow()
            ctx.setStrokeColor(rgba(30, 30, 40, 0.15)); ctx.setLineWidth(1)
            ctx.strokeEllipse(in: CGRect(x: p.x - 14, y: p.y - 14, width: 28, height: 28))
            ctx.setStrokeColor(rgb(0x5C5F66)); ctx.setLineWidth(2); ctx.setLineCap(.round)
            line(CGPoint(x: p.x - 5.5, y: p.y), CGPoint(x: p.x + 5.5, y: p.y))
            line(CGPoint(x: p.x, y: p.y - 5.5), CGPoint(x: p.x, y: p.y + 5.5))
            ctx.restoreGState()
            return
        }
        if Theme.current == .christmas {   // a red glass bauble
            ctx.saveGState()
            ctx.setStrokeColor(rgb(0xC9A24A)); ctx.setLineWidth(1)
            line(CGPoint(x: r.x, y: r.y), CGPoint(x: p.x, y: p.y - 17))
            ctx.setFillColor(rgb(0xD4AF5A)); ctx.fill(CGRect(x: p.x - 4, y: p.y - 18.5, width: 8, height: 4.5))
            shadow(0, 3, 6, rgba(60, 10, 10, 0.3))
            ctx.setFillColor(rgb(hover ? 0xD0262B : 0xB3141C)); dot(p, 15)
            noShadow()
            radial([rgba(255, 255, 255, 0.55), rgba(255, 255, 255, 0)], [0, 1], CGPoint(x: p.x - 5, y: p.y - 6), 0,
                   CGPoint(x: p.x - 5, y: p.y - 6), 9)
            ctx.setStrokeColor(rgb(0xF6D78A, 0.8)); ctx.setLineWidth(0.8)
            ctx.strokeEllipse(in: CGRect(x: p.x - 15, y: p.y - 3, width: 30, height: 6))
            ctx.setStrokeColor(rgb(0xFFF6E4)); ctx.setLineWidth(2); ctx.setLineCap(.round)
            line(CGPoint(x: p.x - 5.5, y: p.y), CGPoint(x: p.x + 5.5, y: p.y))
            line(CGPoint(x: p.x, y: p.y - 5.5), CGPoint(x: p.x, y: p.y + 5.5))
            ctx.restoreGState()
            return
        }
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
        if c.kind == .note && Theme.handmade && c.styleDef.paper == .torn {
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
        case .plain:
            // a faint laid-paper fleck
            ctx.setFillColor(rgba(120, 90, 50, 0.07))
            for i in 0..<40 {
                let d = Double(i)
                dot(CGPoint(x: x0 + srand(c.seed, d) * w, y: y0 + srand(c.seed, d + 300) * h), 0.5 + srand(c.seed, d + 600) * 0.6)
            }
        }
        ctx.restoreGState()
        drawFrame(c)
    }

    /// Christmas card, drawn light and by hand: thin inks, wobbly lines, small accents.
    private func drawFrame(_ c: Card) {
        let st = c.styleDef
        guard let kind = st.frame else { return }
        let w = c.w, h = c.h, x0 = -w / 2, y0 = -h / 2
        let ink = st.frameColor, ink2 = st.frameLine
        ctx.saveGState()
        ctx.setLineCap(.round); ctx.setLineJoin(.round)
        switch kind {
        case .tag:
            // fine two-colour graph paper, a stamp-edged cream panel, a bow sticker
            ctx.setLineWidth(0.6)
            var x = x0 + 4; var k = 0
            while x < x0 + w { ctx.setStrokeColor(rgb(k % 2 == 0 ? ink : ink2, 0.55)); line(CGPoint(x: x, y: y0), CGPoint(x: x, y: y0 + h + 3)); x += 6.5; k += 1 }
            var y = y0 + 4; k = 1
            while y < y0 + h + 3 { ctx.setStrokeColor(rgb(k % 2 == 0 ? ink : ink2, 0.55)); line(CGPoint(x: x0, y: y), CGPoint(x: x0 + w, y: y)); y += 6.5; k += 1 }
            let r = CGRect(x: x0 + 9, y: y0 + 9, width: w - 18, height: h - 19)
            let stamp = perforated(r, 3)
            ctx.addPath(stamp); ctx.setFillColor(rgb(c.color)); ctx.fillPath()
            ctx.addPath(stamp); ctx.setStrokeColor(rgb(ink, 0.9)); ctx.setLineWidth(0.8); ctx.strokePath()
            ctx.setStrokeColor(rgb(ink, 0.8)); ctx.setLineWidth(0.7)
            ctx.stroke(r.insetBy(dx: 6, dy: 6))
            bowSticker(CGPoint(x: r.maxX - 14, y: r.minY + 4), fill: ink2, knot: ink, size: 0.62, angle: 0.12)
        case .sketch:
            // two loose hand-drawn lines, a little line doodle
            for (inset, k) in [(6.5, 1.0), (9.0, 2.0)] as [(CGFloat, Double)] {
                let r = CGRect(x: x0 + inset, y: y0 + inset, width: w - inset * 2, height: h - inset * 2 - 1)
                ctx.addPath(sketchRect(r, seed: c.seed + k * 13, amp: 0.7))
                ctx.setStrokeColor(rgb(ink, 0.85)); ctx.setLineWidth(k == 1 ? 1.1 : 0.7); ctx.strokePath()
            }
            ctx.translateBy(x: 0, y: h / 2 - 21); ctx.scaleBy(x: 0.85, y: 0.85)
            if st.doodle == .holly { lineHolly(ink) } else { lineStarHat(ink) }
        case .stripe:
            // sage and cream candy stripes, a line-drawn bow and a hanging star
            ctx.setFillColor(rgb(ink))
            var x = x0 + 3; while x < x0 + w { ctx.fill(CGRect(x: x, y: y0, width: 6.5, height: h + 3)); x += 13 }
            ctx.saveGState()
            ctx.translateBy(x: 0, y: h / 2 - 20)
            lineStar(ink2, r: 7)
            ctx.restoreGState()
            miniBow(CGPoint(x: x0 + 15, y: y0 + 14), ink2, -0.25, size: 0.75)
        case .gingham:
            // watercolour gingham border, a white card, a pink line, gold corner flourishes
            let b: CGFloat = 10
            ctx.saveGState()
            let band = CGMutablePath()
            band.addRect(CGRect(x: x0, y: y0, width: w, height: h + 3))
            band.addRect(CGRect(x: x0 + b, y: y0 + b, width: w - 2 * b, height: h - 2 * b - 1))
            ctx.addPath(band); ctx.clip(using: .evenOdd)
            ctx.setFillColor(rgb(ink, 0.28))
            var x = x0 + 1; while x < x0 + w { ctx.fill(CGRect(x: x + jitter(c, x), y: y0, width: 5, height: h + 3)); x += 10 }
            var y = y0 + 1; while y < y0 + h + 3 { ctx.fill(CGRect(x: x0, y: y + jitter(c, y + 50), width: w, height: 5)); y += 10 }
            ctx.setStrokeColor(rgb(ink, 0.7)); ctx.setLineWidth(0.6)
            x = x0 + 8; while x < x0 + w { line(CGPoint(x: x, y: y0), CGPoint(x: x, y: y0 + h + 3)); x += 10 }
            y = y0 + 8; while y < y0 + h + 3 { line(CGPoint(x: x0, y: y), CGPoint(x: x0 + w, y: y)); y += 10 }
            ctx.restoreGState()
            let inner = CGRect(x: x0 + b, y: y0 + b, width: w - 2 * b, height: h - 2 * b - 1)
            ctx.setStrokeColor(rgb(ink, 0.9)); ctx.setLineWidth(0.8); ctx.stroke(inner.insetBy(dx: 2.5, dy: 2.5))
            let g = inner.insetBy(dx: 5.5, dy: 5.5)
            ctx.setStrokeColor(rgb(ink2, 0.85)); ctx.setLineWidth(0.7)
            line(CGPoint(x: g.minX + 9, y: g.minY), CGPoint(x: g.maxX - 9, y: g.minY))
            line(CGPoint(x: g.minX + 9, y: g.maxY), CGPoint(x: g.maxX - 9, y: g.maxY))
            line(CGPoint(x: g.minX, y: g.minY + 9), CGPoint(x: g.minX, y: g.maxY - 9))
            line(CGPoint(x: g.maxX, y: g.minY + 9), CGPoint(x: g.maxX, y: g.maxY - 9))
            for (px, py, sx, sy) in [(g.minX, g.minY, 1.0, 1.0), (g.maxX, g.minY, -1.0, 1.0), (g.minX, g.maxY, 1.0, -1.0), (g.maxX, g.maxY, -1.0, -1.0)] as [(CGFloat, CGFloat, CGFloat, CGFloat)] {
                flourish(CGPoint(x: px, y: py), sx, sy, ink2)
            }
        case .plaid:
            // pale Christmas tartan: soft wide bands, crossed by fine lines in the second colour
            ctx.setFillColor(rgb(ink, 0.11))
            var x = x0 + 4; while x < x0 + w { ctx.fill(CGRect(x: x, y: y0, width: 12, height: h + 3)); x += 30 }
            var y = y0 + 4; while y < y0 + h + 3 { ctx.fill(CGRect(x: x0, y: y, width: w, height: 12)); y += 30 }
            ctx.setStrokeColor(rgb(ink, 0.32)); ctx.setLineWidth(0.7)
            x = x0 + 10; while x < x0 + w { line(CGPoint(x: x, y: y0), CGPoint(x: x, y: y0 + h + 3)); x += 30 }
            y = y0 + 10; while y < y0 + h + 3 { line(CGPoint(x: x0, y: y), CGPoint(x: x0 + w, y: y)); y += 30 }
            ctx.setStrokeColor(rgb(ink2, 0.35)); ctx.setLineWidth(0.6)
            x = x0 + 21; while x < x0 + w { line(CGPoint(x: x, y: y0), CGPoint(x: x, y: y0 + h + 3)); x += 30 }
            y = y0 + 21; while y < y0 + h + 3 { line(CGPoint(x: x0, y: y), CGPoint(x: x0 + w, y: y)); y += 30 }
        case .bows:
            // one wobbly line with ribbon bows tied at two corners
            let r = CGRect(x: x0 + 9, y: y0 + 9, width: w - 18, height: h - 19)
            ctx.addPath(panelPath(c, r, .wavy)); ctx.setStrokeColor(rgb(ink, 0.85)); ctx.setLineWidth(1); ctx.strokePath()
            miniBow(CGPoint(x: r.minX + 1, y: r.minY + 1), ink, -0.7, size: 0.8)
            miniBow(CGPoint(x: r.maxX - 1, y: r.maxY - 1), ink, 2.45, size: 0.8)
        }
        ctx.restoreGState()
    }

    private func jitter(_ c: Card, _ k: CGFloat) -> CGFloat { (srand(c.seed, Double(k)) - 0.5) * 1.6 }

    /// A rectangle drawn freehand: each side bows and wavers a little, corners overshoot.
    private func sketchRect(_ r: CGRect, seed: Double, amp: CGFloat) -> CGPath {
        let p = CGMutablePath()
        let pts = [CGPoint(x: r.minX, y: r.minY), CGPoint(x: r.maxX, y: r.minY), CGPoint(x: r.maxX, y: r.maxY), CGPoint(x: r.minX, y: r.maxY)]
        for e in 0..<4 {
            let a = pts[e], b = pts[(e + 1) % 4]
            let len = hypot(b.x - a.x, b.y - a.y)
            let ux = (b.x - a.x) / len, uy = (b.y - a.y) / len
            let nx = -uy, ny = ux
            let n = Int(len / 9)
            let o = 1.6 * (srand(seed, Double(e)) - 0.3)
            p.move(to: CGPoint(x: a.x - ux * o, y: a.y - uy * o))
            for i in 1...n {
                let t = CGFloat(i) / CGFloat(n)
                let d = (srand(seed, Double(e * 50 + i)) - 0.5) * 2 * amp + sin(t * .pi) * amp * 0.8
                p.addLine(to: CGPoint(x: a.x + (b.x - a.x) * t + nx * d + ux * (i == n ? o : 0), y: a.y + (b.y - a.y) * t + ny * d + uy * (i == n ? o : 0)))
            }
        }
        return p
    }

    /// Stamp-style edge: small half-round bites all round.
    private func perforated(_ r: CGRect, _ rad: CGFloat) -> CGPath {
        let p = CGMutablePath()
        let pts = [CGPoint(x: r.minX, y: r.minY), CGPoint(x: r.maxX, y: r.minY), CGPoint(x: r.maxX, y: r.maxY), CGPoint(x: r.minX, y: r.maxY)]
        p.move(to: pts[0])
        for e in 0..<4 {
            let a = pts[e], b = pts[(e + 1) % 4]
            let len = hypot(b.x - a.x, b.y - a.y)
            let ux = (b.x - a.x) / len, uy = (b.y - a.y) / len
            let n = max(2, Int(len / (rad * 3.4)))
            let seg = len / CGFloat(n)
            for i in 0..<n {
                let s0 = CGFloat(i) * seg
                let m = s0 + seg / 2
                p.addLine(to: CGPoint(x: a.x + ux * (m - rad), y: a.y + uy * (m - rad)))
                // bite inward (to the right of travel for a clockwise path in y-down space)
                p.addArc(center: CGPoint(x: a.x + ux * m, y: a.y + uy * m), radius: rad,
                         startAngle: atan2(-uy, -ux), endAngle: atan2(uy, ux), clockwise: true)
                p.addLine(to: CGPoint(x: a.x + ux * (s0 + seg), y: a.y + uy * (s0 + seg)))
            }
        }
        p.closeSubpath()
        return p
    }

    /// Flat printed bow sticker, like a gift tag.
    private func bowSticker(_ at: CGPoint, fill: UInt32, knot: UInt32, size: CGFloat, angle: CGFloat) {
        ctx.saveGState()
        ctx.translateBy(x: at.x, y: at.y); ctx.rotate(by: angle); ctx.scaleBy(x: size, y: size)
        ctx.setFillColor(rgb(fill))
        for sx in [-1.0, 1.0] as [CGFloat] {
            ctx.beginPath()   // loop
            ctx.move(to: CGPoint(x: 0, y: 0))
            ctx.addCurve(to: CGPoint(x: 17 * sx, y: 9), control1: CGPoint(x: 8 * sx, y: -14), control2: CGPoint(x: 22 * sx, y: -10))
            ctx.addCurve(to: CGPoint(x: 0, y: 2), control1: CGPoint(x: 13 * sx, y: 13), control2: CGPoint(x: 5 * sx, y: 6))
            ctx.closePath(); ctx.fillPath()
            ctx.beginPath()   // tail
            ctx.move(to: CGPoint(x: 1 * sx, y: 2))
            ctx.addLine(to: CGPoint(x: 11 * sx, y: 19)); ctx.addLine(to: CGPoint(x: 6 * sx, y: 18)); ctx.addLine(to: CGPoint(x: 4 * sx, y: 22))
            ctx.addLine(to: CGPoint(x: -2 * sx, y: 4)); ctx.closePath(); ctx.fillPath()
        }
        ctx.setStrokeColor(rgba(255, 255, 255, 0.75)); ctx.setLineWidth(1)
        for sx in [-1.0, 1.0] as [CGFloat] {
            ctx.beginPath(); ctx.move(to: CGPoint(x: 4 * sx, y: -2))
            ctx.addQuadCurve(to: CGPoint(x: 14 * sx, y: 2), control: CGPoint(x: 10 * sx, y: -7)); ctx.strokePath()
        }
        ctx.setFillColor(rgb(knot)); ctx.fill(CGRect(x: -3, y: -3, width: 6, height: 7))
        ctx.restoreGState()
    }

    /// Thin gold scroll in a frame corner: a curl, two leaves and a dot.
    private func flourish(_ p: CGPoint, _ sx: CGFloat, _ sy: CGFloat, _ color: UInt32) {
        ctx.saveGState()
        ctx.translateBy(x: p.x, y: p.y); ctx.scaleBy(x: sx, y: sy)
        ctx.setStrokeColor(rgb(color, 0.9)); ctx.setLineWidth(0.8)
        ctx.beginPath()
        ctx.move(to: CGPoint(x: 9, y: 0)); ctx.addQuadCurve(to: CGPoint(x: 2, y: 2), control: CGPoint(x: 4, y: -1))
        ctx.addQuadCurve(to: CGPoint(x: 0, y: 9), control: CGPoint(x: -1, y: 4))
        ctx.move(to: CGPoint(x: 4, y: 4)); ctx.addArc(center: CGPoint(x: 5.5, y: 5.5), radius: 1.6, startAngle: .pi * 1.25, endAngle: .pi * 3, clockwise: false)
        ctx.strokePath()
        ctx.setFillColor(rgb(color, 0.9))
        dot(CGPoint(x: 12, y: 0.5), 0.9); dot(CGPoint(x: 0.5, y: 12), 0.9)
        ctx.restoreGState()
    }

    private func lineStar(_ color: UInt32, r: CGFloat) {
        ctx.beginPath()
        for k in 0..<10 {
            let a = -CGFloat.pi / 2 + CGFloat(k) * .pi / 5, rr = k % 2 == 1 ? r * 0.45 : r
            let pt = CGPoint(x: cos(a) * rr, y: sin(a) * rr)
            if k == 0 { ctx.move(to: pt) } else { ctx.addLine(to: pt) }
        }
        ctx.closePath()
        ctx.setStrokeColor(rgb(color, 0.85)); ctx.setLineWidth(0.9); ctx.strokePath()
    }

    /// Line-drawn star wearing a little Santa hat.
    private func lineStarHat(_ color: UInt32) {
        lineStar(color, r: 9)
        ctx.setFillColor(rgb(color, 0.85))
        ctx.beginPath()
        ctx.move(to: CGPoint(x: -4, y: -6)); ctx.addQuadCurve(to: CGPoint(x: 5, y: -13), control: CGPoint(x: 0, y: -14))
        ctx.addLine(to: CGPoint(x: 3, y: -6.5)); ctx.closePath(); ctx.fillPath()
        ctx.setFillColor(rgb(0xFFFFFF)); ctx.fill(CGRect(x: -4.5, y: -7, width: 8.5, height: 2))
        ctx.setStrokeColor(rgb(color, 0.85)); ctx.setLineWidth(0.6); ctx.stroke(CGRect(x: -4.5, y: -7, width: 8.5, height: 2))
        dot(CGPoint(x: 5.5, y: -13), 1.4)
        ctx.setFillColor(rgb(color, 0.85)); dot(CGPoint(x: -1.6, y: -1), 0.7); dot(CGPoint(x: 1.6, y: -1), 0.7)
    }

    private func lineHolly(_ color: UInt32) {
        ctx.setStrokeColor(rgb(color, 0.85)); ctx.setLineWidth(0.9)
        for a in [-2.5, -0.6] as [CGFloat] {
            ctx.saveGState(); ctx.rotate(by: a)
            ctx.beginPath(); ctx.move(to: .zero)
            ctx.addCurve(to: CGPoint(x: 11, y: 0), control1: CGPoint(x: 3, y: -5), control2: CGPoint(x: 8, y: -5))
            ctx.addCurve(to: .zero, control1: CGPoint(x: 8, y: 5), control2: CGPoint(x: 3, y: 5))
            ctx.move(to: CGPoint(x: 1, y: 0)); ctx.addLine(to: CGPoint(x: 9, y: 0))
            ctx.strokePath(); ctx.restoreGState()
        }
        ctx.setFillColor(rgb(0xB5342C)); dot(CGPoint(x: -1, y: 2), 2); dot(CGPoint(x: 2.5, y: 2.5), 2)
    }

    /// Outline of the Christmas text panel inside `r`.
    private func panelPath(_ c: Card, _ r: CGRect, _ kind: Panel) -> CGPath {
        let p = CGMutablePath()
        switch kind {
        case .wavy, .loops:
            let amp: CGFloat = kind == .wavy ? 1.7 : 0.9, wl: CGFloat = kind == .wavy ? 15 : 22
            let corners = [CGPoint(x: r.minX, y: r.minY), CGPoint(x: r.maxX, y: r.minY), CGPoint(x: r.maxX, y: r.maxY), CGPoint(x: r.minX, y: r.maxY)]
            for e in 0..<4 {
                let a = corners[e], b = corners[(e + 1) % 4]
                let len = hypot(b.x - a.x, b.y - a.y)
                let n = max(2, Int((len / wl).rounded()))
                let nx = (b.y - a.y) / len, ny = -(b.x - a.x) / len
                let steps = n * 8
                for s in 0...steps {
                    let t = CGFloat(s) / CGFloat(steps)
                    let o = sin(t * CGFloat(n) * 2 * .pi) * amp
                    let pt = CGPoint(x: a.x + (b.x - a.x) * t + nx * o, y: a.y + (b.y - a.y) * t + ny * o)
                    if e == 0 && s == 0 { p.move(to: pt) } else { p.addLine(to: pt) }
                }
            }
            p.closeSubpath()
        case .scallop:
            let rad: CGFloat = 3.2
            let corners = [CGPoint(x: r.minX, y: r.minY), CGPoint(x: r.maxX, y: r.minY), CGPoint(x: r.maxX, y: r.maxY), CGPoint(x: r.minX, y: r.maxY)]
            p.move(to: corners[0])
            for e in 0..<4 {
                let a = corners[e], b = corners[(e + 1) % 4]
                let len = hypot(b.x - a.x, b.y - a.y)
                let n = max(2, Int((len / (rad * 2)).rounded()))
                let dx = (b.x - a.x) / CGFloat(n), dy = (b.y - a.y) / CGFloat(n)
                let nx = (b.y - a.y) / len, ny = -(b.x - a.x) / len
                for i in 0..<n {
                    let s = CGPoint(x: a.x + dx * CGFloat(i), y: a.y + dy * CGFloat(i))
                    let e2 = CGPoint(x: s.x + dx, y: s.y + dy)
                    p.addQuadCurve(to: e2, control: CGPoint(x: (s.x + e2.x) / 2 + nx * rad * 1.6, y: (s.y + e2.y) / 2 + ny * rad * 1.6))
                }
            }
            p.closeSubpath()
        case .bracket:
            let n: CGFloat = 7
            p.move(to: CGPoint(x: r.minX + n, y: r.minY))
            p.addLine(to: CGPoint(x: r.maxX - n, y: r.minY))
            p.addArc(center: CGPoint(x: r.maxX, y: r.minY), radius: n, startAngle: .pi, endAngle: .pi / 2, clockwise: true)
            p.addLine(to: CGPoint(x: r.maxX, y: r.maxY - n))
            p.addArc(center: CGPoint(x: r.maxX, y: r.maxY), radius: n, startAngle: -.pi / 2, endAngle: -.pi, clockwise: true)
            p.addLine(to: CGPoint(x: r.minX + n, y: r.maxY))
            p.addArc(center: CGPoint(x: r.minX, y: r.maxY), radius: n, startAngle: 0, endAngle: -.pi / 2, clockwise: true)
            p.addLine(to: CGPoint(x: r.minX, y: r.minY + n))
            p.addArc(center: CGPoint(x: r.minX, y: r.minY), radius: n, startAngle: .pi / 2, endAngle: 0, clockwise: true)
            p.closeSubpath()
        }
        return p
    }

    /// A tiny line-drawn ribbon bow (panel corners, ornaments).
    private func miniBow(_ at: CGPoint, _ color: UInt32, _ angle: CGFloat, size: CGFloat = 1) {
        ctx.saveGState()
        ctx.translateBy(x: at.x, y: at.y); ctx.rotate(by: angle); ctx.scaleBy(x: size, y: size)
        ctx.setStrokeColor(rgb(color)); ctx.setLineWidth(1.3); ctx.setLineCap(.round); ctx.setLineJoin(.round)
        ctx.beginPath()
        ctx.move(to: .zero); ctx.addCurve(to: .zero, control1: CGPoint(x: -8, y: -6), control2: CGPoint(x: -9, y: 4))
        ctx.move(to: .zero); ctx.addCurve(to: .zero, control1: CGPoint(x: 8, y: -6), control2: CGPoint(x: 9, y: 4))
        ctx.move(to: .zero); ctx.addQuadCurve(to: CGPoint(x: -4, y: 8), control: CGPoint(x: -1, y: 4))
        ctx.move(to: .zero); ctx.addQuadCurve(to: CGPoint(x: 5, y: 7), control: CGPoint(x: 1, y: 4))
        ctx.strokePath()
        ctx.setFillColor(rgb(color)); dot(.zero, 1.6)
        ctx.restoreGState()
    }

    private func drawDoodle(_ c: Card) {
        guard let kind = c.styleDef.doodle, c.styleDef.frame == nil else { return }
        if [.holly, .ribbon, .tree, .snow].contains(kind) || (kind == .star && Theme.current == .christmas) { drawXmasDoodle(c, kind); return }
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
        default: break
        }
        ctx.strokePath()
        ctx.restoreGState()
    }

    /// Small painted Christmas motifs in the top-right corner.
    private func drawXmasDoodle(_ c: Card, _ kind: Doodle) {
        ctx.saveGState()
        ctx.translateBy(x: c.w / 2 - 22, y: -c.h / 2 + 22)
        ctx.rotate(by: (srand(c.seed, 7) - 0.5) * 0.4)
        ctx.scaleBy(x: 0.68, y: 0.68)
        ctx.setAlpha(0.8)
        ctx.setLineJoin(.round); ctx.setLineCap(.round)
        func leaf(_ a: CGFloat) {
            ctx.saveGState(); ctx.rotate(by: a)
            ctx.beginPath()
            ctx.move(to: .zero)
            ctx.addCurve(to: CGPoint(x: 11, y: 0), control1: CGPoint(x: 2, y: -5), control2: CGPoint(x: 8, y: -5.5))
            ctx.addCurve(to: .zero, control1: CGPoint(x: 8, y: 5.5), control2: CGPoint(x: 2, y: 5))
            ctx.setFillColor(rgb(0x1F6B3E)); ctx.fillPath()
            ctx.setStrokeColor(rgba(255, 255, 255, 0.45)); ctx.setLineWidth(0.6)
            line(CGPoint(x: 1.5, y: 0), CGPoint(x: 9.5, y: 0))
            ctx.restoreGState()
        }
        switch kind {
        case .holly:
            leaf(-2.6); leaf(-0.55)
            for (x, y) in [(-1.5, 2.0), (2.2, 2.6), (0.3, -0.8)] as [(CGFloat, CGFloat)] {
                ctx.setFillColor(rgb(0xC8102E)); dot(CGPoint(x: x, y: y), 2.4)
                ctx.setFillColor(rgba(255, 255, 255, 0.6)); dot(CGPoint(x: x - 0.7, y: y - 0.8), 0.6)
            }
        case .ribbon:
            ctx.setStrokeColor(rgb(0xC8102E)); ctx.setLineWidth(1.6)
            ctx.beginPath()
            ctx.move(to: .zero)
            ctx.addCurve(to: .zero, control1: CGPoint(x: -12, y: -9), control2: CGPoint(x: -13, y: 5))
            ctx.move(to: .zero)
            ctx.addCurve(to: .zero, control1: CGPoint(x: 12, y: -9), control2: CGPoint(x: 13, y: 5))
            ctx.move(to: .zero); ctx.addQuadCurve(to: CGPoint(x: -6, y: 11), control: CGPoint(x: -2, y: 6))
            ctx.move(to: .zero); ctx.addQuadCurve(to: CGPoint(x: 7, y: 10), control: CGPoint(x: 2, y: 6))
            ctx.strokePath()
            ctx.setFillColor(rgb(0xC8102E)); dot(.zero, 2.2)
        case .tree:
            ctx.setFillColor(rgb(0x1F6B3E))
            for (top, half, y) in [(-10.0, 5.0, -3.0), (-5.0, 7.5, 2.5), (0.0, 9.5, 8.0)] as [(CGFloat, CGFloat, CGFloat)] {
                ctx.beginPath(); ctx.move(to: CGPoint(x: 0, y: top))
                ctx.addLine(to: CGPoint(x: half, y: y)); ctx.addLine(to: CGPoint(x: -half, y: y)); ctx.closePath(); ctx.fillPath()
            }
            ctx.setFillColor(rgb(0x6B3A1E)); ctx.fill(CGRect(x: -1.5, y: 8, width: 3, height: 3))
            ctx.setFillColor(rgb(0xC8102E)); dot(CGPoint(x: -3, y: 0), 1.2); dot(CGPoint(x: 3.5, y: 5.5), 1.2)
            ctx.setFillColor(rgb(0xF2C14E)); dot(CGPoint(x: 2, y: -1.5), 1.1); dot(CGPoint(x: -4, y: 6), 1.1); dot(CGPoint(x: 0, y: -11), 1.8)
        case .star:
            ctx.beginPath()
            for i in 0..<10 {
                let a = -CGFloat.pi / 2 + CGFloat(i) * .pi / 5, r: CGFloat = i % 2 == 1 ? 4 : 9.5
                let pt = CGPoint(x: cos(a) * r, y: sin(a) * r)
                if i == 0 { ctx.move(to: pt) } else { ctx.addLine(to: pt) }
            }
            ctx.closePath()
            ctx.setFillColor(rgb(0xE9B949)); ctx.fillPath()
            ctx.setFillColor(rgba(255, 255, 255, 0.5)); dot(CGPoint(x: -1.5, y: -2), 1.2)
        case .snow:
            ctx.setStrokeColor(rgb(0x6F9CC4)); ctx.setLineWidth(1.2)
            for i in 0..<6 {
                let a = CGFloat(i) * .pi / 3
                let e = CGPoint(x: cos(a) * 9, y: sin(a) * 9), m = CGPoint(x: cos(a) * 5.5, y: sin(a) * 5.5)
                line(.zero, e)
                line(m, CGPoint(x: m.x + cos(a + 0.8) * 3, y: m.y + sin(a + 0.8) * 3))
                line(m, CGPoint(x: m.x + cos(a - 0.8) * 3, y: m.y + sin(a - 0.8) * 3))
            }
        default: break
        }
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
        ctx.addPath(path); ctx.setFillColor(rgb(c.color)); ctx.fillPath()
        noShadow()

        if c.kind != .note {
            drawFace(c, path: path)
        } else if Theme.paperActive, let img = CustomPapers.image(for: c) {
            drawPaperNote(c, img, path: path)
        } else if Theme.current == .sticky {
            drawStickyNote(c, path: path)
        } else {
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
        let pad = c.textPad
        let maxW = w - pad - 14 - c.frameInset
        let parts = c.text.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false)
        let title = parts.first.map(String.init) ?? ""
        let body = parts.count > 1 ? String(parts[1]) : ""

        let tpara = NSMutableParagraphStyle(); tpara.lineBreakMode = .byTruncatingTail
        let tAttr = NSAttributedString(string: title, attributes: [
            .font: Fonts.title(17), .foregroundColor: NSColor(cgColor: rgb(INK)) ?? .black, .paragraphStyle: tpara,
        ])
        let tMax = st.frame == nil || st.frame == .tag ? maxW - 18 : w - pad - 14
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
        if let lay = world.taskLayout(c) {
            drawTasks(c, lay, font: Fonts.hand(14), ink: rgb(INK, 0.85))
        } else if !body.isEmpty {
            let bpara = NSMutableParagraphStyle()
            bpara.minimumLineHeight = 21; bpara.maximumLineHeight = 21
            bpara.lineBreakMode = .byWordWrapping
            let bAttr = NSAttributedString(string: body, attributes: [
                .font: Fonts.hand(15), .foregroundColor: NSColor(cgColor: rgb(INK, 0.85)) ?? .black, .paragraphStyle: bpara,
            ])
            bAttr.draw(with: CGRect(x: x0 + pad, y: y0 + 45, width: maxW, height: h - 45 - 12 - c.frameInset * 2),
                       options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
        }
        drawDoodle(c)
        }

        // hand-drawn "done" checkbox
        if c.stampAt == nil && (c.mode == .hang || c.mode == .free) {
            let cb = world.checkboxCenter(c)
            let ox = cb.x, oy = cb.y
            let on = world.hoverStamp === c, near = world.hoverCard === c
            ctx.saveGState()
            ctx.setAlpha(alpha * (on ? 0.95 : near ? 0.6 : 0.28))
            ctx.setStrokeColor(rgb(on ? SEAL : INK)); ctx.setLineWidth(1.3)
            ctx.setLineCap(.round); ctx.setLineJoin(.round)
            let s: CGFloat = 6.5
            let wobble: CGFloat = Theme.handmade ? 1.4 : 0
            func j(_ k: Double) -> CGFloat { (srand(c.seed, k) - 0.5) * wobble }
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
        // trash can, bottom-left, shown on hover (drawn like the "done" box: thin ink lines)
        if c.stampAt == nil && (c.mode == .hang || c.mode == .free) && world.hoverCard === c && world.dragging == nil {
            let on = world.hoverDelete === c
            let p = world.deleteCenter(c)
            ctx.saveGState()
            ctx.setAlpha(alpha * (on ? 1 : 0.5))
            ctx.setStrokeColor(on ? rgb(0xE5483E) : rgb(INK)); ctx.setLineWidth(1.3)
            ctx.setLineCap(.round); ctx.setLineJoin(.round)
            // lid and handle
            line(CGPoint(x: p.x - 6.5, y: p.y - 4.5), CGPoint(x: p.x + 6.5, y: p.y - 4.5))
            ctx.beginPath()
            ctx.move(to: CGPoint(x: p.x - 2.5, y: p.y - 4.5)); ctx.addLine(to: CGPoint(x: p.x - 2, y: p.y - 6.8))
            ctx.addLine(to: CGPoint(x: p.x + 2, y: p.y - 6.8)); ctx.addLine(to: CGPoint(x: p.x + 2.5, y: p.y - 4.5))
            ctx.strokePath()
            // can
            ctx.beginPath()
            ctx.move(to: CGPoint(x: p.x - 5, y: p.y - 3)); ctx.addLine(to: CGPoint(x: p.x - 4.2, y: p.y + 6.5))
            ctx.addLine(to: CGPoint(x: p.x + 4.2, y: p.y + 6.5)); ctx.addLine(to: CGPoint(x: p.x + 5, y: p.y - 3))
            ctx.strokePath()
            ctx.setLineWidth(1)
            line(CGPoint(x: p.x - 1.6, y: p.y - 0.8), CGPoint(x: p.x - 1.4, y: p.y + 4.3))
            line(CGPoint(x: p.x + 1.6, y: p.y - 0.8), CGPoint(x: p.x + 1.4, y: p.y + 4.3))
            ctx.restoreGState()
        }
        // "hang back" button on desk notes, shown on hover
        if c.mode == .free && !world.ropeHidden && world.hoverCard === c {
            let on = world.hoverHangBack === c
            let p = CGPoint(x: w / 2 - 15, y: -h / 2 + 15)
            ctx.saveGState()
            shadow(0, 1, 3, rgba(30, 30, 40, 0.25))
            ctx.setFillColor(rgb(INK, on ? 0.95 : 0.7)); dot(p, 10)
            noShadow()
            ctx.setStrokeColor(rgb(0xFFFFFF)); ctx.setLineWidth(1.8); ctx.setLineCap(.round); ctx.setLineJoin(.round)
            line(CGPoint(x: p.x, y: p.y + 4.5), CGPoint(x: p.x, y: p.y - 4.5))
            ctx.beginPath()
            ctx.move(to: CGPoint(x: p.x - 4, y: p.y - 0.5)); ctx.addLine(to: CGPoint(x: p.x, y: p.y - 4.5)); ctx.addLine(to: CGPoint(x: p.x + 4, y: p.y - 0.5))
            ctx.strokePath()
            ctx.restoreGState()
            if on {
                let t = text("挂回绳子", font: Fonts.title(11), color: rgb(0xFFFFFF))
                let ts = t.size()
                let r = CGRect(x: p.x - ts.width / 2 - 7, y: p.y - 36, width: ts.width + 14, height: 20)
                ctx.addPath(CGPath(roundedRect: r, cornerWidth: 5, cornerHeight: 5, transform: nil))
                ctx.setFillColor(rgb(INK, 0.9)); ctx.fillPath()
                t.draw(at: CGPoint(x: r.minX + 7, y: r.midY - ts.height / 2))
            }
        }
        if let f = world.flash, f.card === c {
            let left = f.until - world.tWorld
            let a = CGFloat(min(1, max(0, left / 0.3)))
            let t = text(f.text, font: Fonts.title(12), color: rgb(0xFFFFFF))
            let ts = t.size()
            let r = CGRect(x: -ts.width / 2 - 9, y: -h / 2 - 30, width: ts.width + 18, height: 22)
            ctx.saveGState(); ctx.setAlpha(alpha * a)
            ctx.addPath(CGPath(roundedRect: r, cornerWidth: 6, cornerHeight: 6, transform: nil))
            ctx.setFillColor(rgb(INK, 0.9)); ctx.fillPath()
            t.draw(at: CGPoint(x: r.minX + 9, y: r.midY - ts.height / 2))
            ctx.restoreGState()
        }
        ctx.restoreGState()
    }

    /// Imported paper: the artwork fills the square note; text flows in the open area
    /// and steers around the bottom-right corner where the illustration usually sits.
    private func drawPaperNote(_ c: Card, _ img: CGImage, path: CGPath) {
        let w = c.w, h = c.h, x0 = -w / 2, y0 = -h / 2
        ctx.saveGState()
        ctx.addPath(path); ctx.clip()
        fill(img, into: CGRect(x: x0, y: y0, width: w, height: h), aspectFill: true)
        ctx.restoreGState()

        let parts = c.text.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false)
        let title = parts.first.map(String.init) ?? ""
        let body = parts.count > 1 ? String(parts[1]) : ""
        let tpara = NSMutableParagraphStyle(); tpara.lineBreakMode = .byTruncatingTail
        NSAttributedString(string: title, attributes: [
            .font: Fonts.title(16), .foregroundColor: NSColor(cgColor: rgb(INK)) ?? .black, .paragraphStyle: tpara,
        ]).draw(with: CGRect(x: x0 + 16, y: y0 + 22, width: w - 40, height: 22), options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
        if let lay = world.taskLayout(c) { drawTasks(c, lay, font: Fonts.hand(14), ink: rgb(INK, 0.85)); return }
        guard !body.isEmpty else { return }

        let bpara = NSMutableParagraphStyle()
        bpara.minimumLineHeight = 19; bpara.maximumLineHeight = 19
        let storage = NSTextStorage(string: body, attributes: [
            .font: Fonts.hand(14), .foregroundColor: NSColor(cgColor: rgb(INK, 0.85)) ?? .black, .paragraphStyle: bpara,
        ])
        let layout = NSLayoutManager()
        storage.addLayoutManager(layout)
        let origin = CGPoint(x: x0 + 16, y: y0 + 48)
        let box = NSTextContainer(size: CGSize(width: w - 30, height: h - 48 - 30))
        box.lineFragmentPadding = 0
        box.maximumNumberOfLines = 5
        box.lineBreakMode = .byTruncatingTail
        // keep clear of the artwork in the bottom-right corner
        let artX = w * 0.54 - 16, artY = h * 0.5 - 48
        box.exclusionPaths = [NSBezierPath(rect: NSRect(x: artX, y: artY, width: w, height: h))]
        layout.addTextContainer(box)
        layout.drawGlyphs(forGlyphRange: layout.glyphRange(for: box), at: origin)
    }

    /// Classic sticky note: flat colour, a faint adhesive strip, a lifted bottom corner.
    private func drawStickyNote(_ c: Card, path: CGPath) {
        let w = c.w, h = c.h, x0 = -w / 2, y0 = -h / 2
        ctx.saveGState()
        ctx.addPath(path); ctx.clip()
        ctx.setFillColor(rgba(0, 0, 0, 0.035)); ctx.fill(CGRect(x: x0, y: y0, width: w, height: 24))
        linear([rgba(255, 255, 255, 0.16), rgba(255, 255, 255, 0), rgba(0, 0, 0, 0.05)], [0, 0.45, 1],
               CGPoint(x: 0, y: y0), CGPoint(x: 0, y: y0 + h))
        linear([rgba(0, 0, 0, 0), rgba(0, 0, 0, 0.08)], [0, 1],
               CGPoint(x: x0 + w - 44, y: y0 + h - 44), CGPoint(x: x0 + w, y: y0 + h))
        ctx.restoreGState()

        let parts = c.text.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false)
        let title = parts.first.map(String.init) ?? ""
        let body = parts.count > 1 ? String(parts[1]) : ""
        let ink = NSColor(srgbRed: 0.13, green: 0.13, blue: 0.15, alpha: 1)
        let tpara = NSMutableParagraphStyle(); tpara.lineBreakMode = .byTruncatingTail
        NSAttributedString(string: title, attributes: [.font: NSFont.systemFont(ofSize: 15, weight: .semibold),
                                                       .foregroundColor: ink, .paragraphStyle: tpara])
            .draw(with: CGRect(x: x0 + 13, y: y0 + 28, width: w - 26, height: 22), options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
        if let lay = world.taskLayout(c) {
            drawTasks(c, lay, font: .systemFont(ofSize: 12.5), ink: ink.withAlphaComponent(0.82).cgColor)
        } else if !body.isEmpty {
            let bpara = NSMutableParagraphStyle()
            bpara.minimumLineHeight = 19; bpara.maximumLineHeight = 19
            NSAttributedString(string: body, attributes: [.font: NSFont.systemFont(ofSize: 13), .foregroundColor: ink.withAlphaComponent(0.82),
                                                          .paragraphStyle: bpara])
                .draw(with: CGRect(x: x0 + 13, y: y0 + 53, width: w - 26, height: h - 53 - 26), options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
        }
    }

    /// A note with several tasks: one line each, a small box in front; ticked lines are struck through.
    private func drawTasks(_ c: Card, _ lay: (rows: [TaskRow], more: Int, lineH: CGFloat), font: NSFont, ink: CGColor) {
        let para = NSMutableParagraphStyle(); para.lineBreakMode = .byTruncatingTail
        let hover = world.hoverTask?.card === c ? world.hoverTask?.index : nil
        let wobble: CGFloat = Theme.handmade ? 0.9 : 0
        for r in lay.rows {
            let on = hover == r.index
            // the box
            ctx.saveGState()
            let s: CGFloat = 4.5, b = r.box
            func j(_ k: Double) -> CGFloat { (srand(c.seed, k + Double(r.index) * 13) - 0.5) * wobble }
            ctx.setLineCap(.round); ctx.setLineJoin(.round)
            ctx.setStrokeColor(rgb(on ? SEAL : INK, r.done ? 0.45 : (on ? 0.95 : 0.6))); ctx.setLineWidth(1.1)
            ctx.beginPath()
            ctx.move(to: CGPoint(x: b.x - s + j(1), y: b.y - s + j(2)))
            ctx.addLine(to: CGPoint(x: b.x + s + j(3), y: b.y - s + j(4)))
            ctx.addLine(to: CGPoint(x: b.x + s + j(5), y: b.y + s + j(6)))
            ctx.addLine(to: CGPoint(x: b.x - s + j(7), y: b.y + s + j(8)))
            ctx.closePath(); ctx.strokePath()
            if r.done || on {
                ctx.setStrokeColor(rgb(SEAL, r.done ? 0.9 : 0.45)); ctx.setLineWidth(1.6)
                ctx.beginPath()
                ctx.move(to: CGPoint(x: b.x - 3.2, y: b.y)); ctx.addLine(to: CGPoint(x: b.x - 0.6, y: b.y + 3))
                ctx.addLine(to: CGPoint(x: b.x + 5.5, y: b.y - 5.5))
                ctx.strokePath()
            }
            ctx.restoreGState()
            // the words
            var attrs: [NSAttributedString.Key: Any] = [
                .font: font, .paragraphStyle: para,
                .foregroundColor: NSColor(cgColor: ink.copy(alpha: ink.alpha * (r.done ? 0.45 : 1)) ?? ink) ?? .black,
            ]
            if r.done {
                attrs[.strikethroughStyle] = NSUnderlineStyle.single.rawValue
                attrs[.strikethroughColor] = NSColor(cgColor: rgb(SEAL, 0.55))
            }
            let a = NSAttributedString(string: r.text, attributes: attrs)
            let th = a.boundingRect(with: CGSize(width: 1000, height: 100), options: [.usesLineFragmentOrigin]).height
            a.draw(with: CGRect(x: r.textX, y: r.rect.midY - th / 2, width: r.rect.maxX - r.textX, height: th + 2),
                   options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
        }
        if lay.more > 0, let last = lay.rows.last {
            let a = NSAttributedString(string: "还有 \(lay.more) 项…", attributes: [
                .font: font.withSize(font.pointSize - 2), .foregroundColor: NSColor(cgColor: ink.copy(alpha: ink.alpha * 0.55) ?? ink) ?? .gray,
            ])
            a.draw(at: CGPoint(x: last.textX, y: last.rect.maxY + 2))
        }
    }

    // MARK: file shortcut faces

    /// Draws a CGImage into a rect in this y-down context (CG images are y-up).
    private func drawImage(_ img: CGImage, in r: CGRect) {
        ctx.saveGState()
        ctx.translateBy(x: 0, y: r.minY + r.maxY); ctx.scaleBy(x: 1, y: -1)
        ctx.draw(img, in: r)
        ctx.restoreGState()
    }
    private func fill(_ img: CGImage, into r: CGRect, aspectFill: Bool) {
        let iw = CGFloat(img.width), ih = CGFloat(img.height)
        guard iw > 0, ih > 0 else { return }
        let s = aspectFill ? max(r.width / iw, r.height / ih) : min(r.width / iw, r.height / ih)
        let w = iw * s, h = ih * s
        drawImage(img, in: CGRect(x: r.midX - w / 2, y: r.midY - h / 2, width: w, height: h))
    }
    private func label(_ s: String, font: NSFont, color: CGColor, in r: CGRect, center: Bool = true) {
        let para = NSMutableParagraphStyle()
        para.lineBreakMode = .byTruncatingMiddle
        para.alignment = center ? .center : .left
        let a = NSAttributedString(string: s, attributes: [
            .font: font, .foregroundColor: NSColor(cgColor: color) ?? .black, .paragraphStyle: para,
        ])
        a.draw(with: r, options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
    }
    private func washiCorner(_ p: CGPoint, _ a: CGFloat, _ color: UInt32) {
        ctx.saveGState()
        ctx.translateBy(x: p.x, y: p.y); ctx.rotate(by: a)
        ctx.setFillColor(rgb(color, 0.82)); ctx.fill(CGRect(x: -13, y: -5, width: 26, height: 10))
        ctx.restoreGState()
    }

    private func drawFace(_ c: Card, path: CGPath) {
        let w = c.w, h = c.h, x0 = -w / 2, y0 = -h / 2
        switch c.kind {
        case .image:   // polaroid
            let photo = CGRect(x: x0 + 9, y: y0 + 9, width: w - 18, height: h - 42)
            ctx.setFillColor(rgb(0xE6E3DB)); ctx.fill(photo)
            if let img = c.thumb {
                ctx.saveGState(); ctx.clip(to: photo); fill(img, into: photo, aspectFill: true); ctx.restoreGState()
            }
            ctx.setStrokeColor(rgba(40, 46, 62, 0.12)); ctx.setLineWidth(1); ctx.stroke(photo)
            label(c.title, font: Fonts.hand(13), color: rgb(INK, 0.85),
                  in: CGRect(x: x0 + 12, y: y0 + h - 29, width: w - 44, height: 20), center: false)

        case .folder:  // kraft document wallet
            ctx.saveGState()
            ctx.addPath(path); ctx.clip()
            ctx.setLineWidth(0.7)
            for i in 0..<60 {
                let d = Double(i)
                let x = x0 + srand(c.seed, d) * w, y = y0 + srand(c.seed, d + 300) * h
                let a = srand(c.seed, d + 600) * .pi, l = 3 + srand(c.seed, d + 900) * 9
                ctx.setStrokeColor(i % 3 != 0 ? rgba(110, 75, 35, 0.16) : rgba(255, 240, 215, 0.3))
                line(CGPoint(x: x, y: y), CGPoint(x: x + cos(a) * l, y: y + sin(a) * l))
            }
            // front pocket
            let pocket = CGMutablePath()
            pocket.move(to: CGPoint(x: x0, y: y0 + 34))
            pocket.addQuadCurve(to: CGPoint(x: x0 + w, y: y0 + 30), control: CGPoint(x: 0, y: y0 + 40))
            pocket.addLine(to: CGPoint(x: x0 + w, y: y0 + h + 4)); pocket.addLine(to: CGPoint(x: x0, y: y0 + h + 4)); pocket.closeSubpath()
            ctx.addPath(pocket); ctx.setFillColor(rgb(0xDDBE95)); ctx.fillPath()
            ctx.addPath(pocket); ctx.setStrokeColor(rgba(110, 75, 35, 0.3)); ctx.setLineWidth(1); ctx.strokePath()
            ctx.restoreGState()
            // index tab
            let tab = CGPath(roundedRect: CGRect(x: x0 + w - 56, y: y0 + 8, width: 42, height: 16), cornerWidth: 3, cornerHeight: 3, transform: nil)
            ctx.addPath(tab); ctx.setFillColor(rgb(0xF2BCB7)); ctx.fillPath()
            // white label
            ctx.saveGState()
            ctx.translateBy(x: 0, y: y0 + 78); ctx.rotate(by: -0.025)
            shadow(0, 1, 2, rgba(40, 46, 62, 0.15))
            ctx.setFillColor(rgb(0xFBFAF5)); ctx.fill(CGRect(x: -w / 2 + 16, y: -24, width: w - 32, height: 46))
            noShadow()
            label(c.title, font: Fonts.title(14), color: rgb(INK), in: CGRect(x: -w / 2 + 22, y: -19, width: w - 44, height: 20))
            if let n = c.itemCount {
                label("\(n) 个项目", font: Fonts.hand(11), color: rgb(INK, 0.6), in: CGRect(x: -w / 2 + 22, y: 2, width: w - 44, height: 16))
            }
            ctx.restoreGState()

        case .file:    // a card with a quick-look preview
            ctx.saveGState()
            ctx.addPath(path); ctx.clip()
            ctx.setFillColor(rgba(60, 70, 95, 0.18))
            var y = y0 + 10
            while y < y0 + h { var x = x0 + 10; while x < x0 + w { dot(CGPoint(x: x, y: y), 0.8); x += 11 }; y += 11 }
            ctx.restoreGState()
            let box = CGRect(x: x0 + 22, y: y0 + 14, width: w - 44, height: 66)
            if let img = c.thumb {
                fill(img, into: box, aspectFill: false)
            }
            washiCorner(CGPoint(x: box.minX + 6, y: box.minY + 2), -0.6, c.styleDef.tape)
            washiCorner(CGPoint(x: box.maxX - 6, y: box.minY + 2), 0.6, c.styleDef.tape)
            label(c.title, font: Fonts.title(14), color: rgb(INK), in: CGRect(x: x0 + 12, y: y0 + 84, width: w - 24, height: 20))
            if !c.ext.isEmpty {
                let t = text(c.ext, font: Fonts.hand(11), color: rgb(INK, 0.7))
                let ts = t.size()
                let badge = CGRect(x: x0 + 12, y: y0 + h - 27, width: ts.width + 12, height: 17)
                ctx.addPath(CGPath(roundedRect: badge, cornerWidth: 3, cornerHeight: 3, transform: nil))
                ctx.setFillColor(rgb(c.styleDef.marker, 0.8)); ctx.fillPath()
                t.draw(at: CGPoint(x: badge.minX + 6, y: badge.midY - ts.height / 2))
            }

        case .note:
            break
        }
        if c.missing {
            ctx.saveGState()
            ctx.addPath(path); ctx.setFillColor(rgba(255, 255, 255, 0.55)); ctx.fillPath()
            label("找不到原文件", font: Fonts.title(14), color: rgb(SEAL), in: CGRect(x: x0 + 10, y: -10, width: w - 20, height: 22))
            ctx.restoreGState()
        }
    }

    private func drawStamp(_ c: Card, alpha: CGFloat) {
        let k = CGFloat(min(1, (world.tWorld - (c.stampAt ?? 0)) / 0.14))
        let e = 1 - pow(1 - k, 3)
        let s = 1.9 - 0.9 * e
        ctx.saveGState()
        let stampX: CGFloat = (c.kind == .note && Theme.paperActive) ? -c.w / 2 + 48 : c.w / 2 - 44
        ctx.translateBy(x: stampX, y: c.h / 2 - 36); ctx.rotate(by: -0.24); ctx.scaleBy(x: s, y: s)
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
        ctx.setFillColor(rgb(c.color))
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
        if Theme.current == .sticky { drawBinderClip() }
        else if Theme.paperActive && c.kind == .note { drawPeg(c.style % 2 == 0 ? 0xA8C8EE : 0xF5D77A) }
        else if st.attach == .bow { drawBow(st.tape) }
        else if st.attach == .tape { drawTape(c) } else { drawPeg(st.peg) }
        ctx.restoreGState()
    }

    /// A red velvet bow tied over the cord, tails hanging onto the card.
    private func drawBow(_ color: UInt32) {
        ctx.scaleBy(x: 0.72, y: 0.72)
        let y = -CLIP + 1
        shadow(0, 1.5, 2, rgba(60, 10, 10, 0.25))
        ctx.setFillColor(rgb(color))
        // tails
        for s in [-1.0, 1.0] as [CGFloat] {
            ctx.beginPath()
            ctx.move(to: CGPoint(x: -2 * s, y: y))
            ctx.addLine(to: CGPoint(x: -9 * s, y: y + 21))
            ctx.addLine(to: CGPoint(x: -5.5 * s, y: y + 19))
            ctx.addLine(to: CGPoint(x: -3 * s, y: y + 23))
            ctx.addLine(to: CGPoint(x: 2.5 * s, y: y + 1))
            ctx.closePath(); ctx.fillPath()
        }
        // loops
        for s in [-1.0, 1.0] as [CGFloat] {
            ctx.beginPath()
            ctx.move(to: CGPoint(x: 0, y: y))
            ctx.addCurve(to: CGPoint(x: 0, y: y + 1), control1: CGPoint(x: 15 * s, y: y - 13), control2: CGPoint(x: 18 * s, y: y + 9))
            ctx.closePath(); ctx.fillPath()
        }
        noShadow()
        // velvet sheen and folds
        ctx.setStrokeColor(rgba(255, 255, 255, 0.22)); ctx.setLineWidth(1)
        for s in [-1.0, 1.0] as [CGFloat] {
            ctx.beginPath(); ctx.move(to: CGPoint(x: 3 * s, y: y - 2))
            ctx.addQuadCurve(to: CGPoint(x: 12 * s, y: y - 3), control: CGPoint(x: 8 * s, y: y - 6)); ctx.strokePath()
        }
        ctx.setStrokeColor(rgba(0, 0, 0, 0.22)); ctx.setLineWidth(0.8)
        for s in [-1.0, 1.0] as [CGFloat] {
            ctx.beginPath(); ctx.move(to: CGPoint(x: 3 * s, y: y + 1))
            ctx.addQuadCurve(to: CGPoint(x: 11 * s, y: y + 2), control: CGPoint(x: 8 * s, y: y + 4)); ctx.strokePath()
        }
        // knot
        let knot = CGPath(roundedRect: CGRect(x: -3.5, y: y - 3.5, width: 7, height: 7.5), cornerWidth: 2.5, cornerHeight: 2.5, transform: nil)
        ctx.addPath(knot); ctx.setFillColor(rgb(color)); ctx.fillPath()
        ctx.addPath(knot); ctx.setFillColor(rgba(0, 0, 0, 0.12)); ctx.fillPath()
        ctx.setFillColor(rgba(255, 255, 255, 0.25)); ctx.fill(CGRect(x: -2, y: y - 2.5, width: 4, height: 1.2))
    }

    /// Black binder clip, wire handles folded up over the cord.
    private func drawBinderClip() {
        ctx.setStrokeColor(rgb(0xC9CCD2)); ctx.setLineWidth(1.6); ctx.setLineJoin(.round)
        ctx.beginPath()
        ctx.move(to: CGPoint(x: -7, y: 0)); ctx.addLine(to: CGPoint(x: -4, y: -CLIP - 3))
        ctx.addLine(to: CGPoint(x: 4, y: -CLIP - 3)); ctx.addLine(to: CGPoint(x: 7, y: 0))
        ctx.strokePath()
        shadow(0, 2, 3, rgba(30, 30, 40, 0.3))
        let body = CGPath(roundedRect: CGRect(x: -11, y: -2, width: 22, height: 13), cornerWidth: 2, cornerHeight: 2, transform: nil)
        ctx.addPath(body); ctx.setFillColor(rgb(0x2B2D31)); ctx.fillPath()
        noShadow()
        ctx.setFillColor(rgba(255, 255, 255, 0.22)); ctx.fill(CGRect(x: -10, y: -1, width: 20, height: 2))
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

    private func drawBall(_ c: Card, morph t: CGFloat, scale: CGFloat) {
        if t < 1 {
            c.sc = 1 - 0.72 * t
            drawPaper(c, lift: 2, alpha: 1 - t); drawAttach(c, alpha: 1 - t)
        }
        ctx.saveGState()
        ctx.setAlpha(t)
        ctx.translateBy(x: c.c.x, y: c.c.y); ctx.rotate(by: c.th)
        if scale != 1 { ctx.scaleBy(x: scale, y: scale) }
        shadow(0, 8, 10, rgba(40, 46, 62, 0.25))
        let R: CGFloat = 27, n = 13
        let p = CGMutablePath()
        for i in 0..<n {
            let a = CGFloat(i) / CGFloat(n) * 2 * .pi, r = R * (0.78 + srand(c.seed, Double(i)) * 0.3)
            let pt = CGPoint(x: cos(a) * r, y: sin(a) * r)
            if i == 0 { p.move(to: pt) } else { p.addLine(to: pt) }
        }
        p.closeSubpath()
        ctx.addPath(p); ctx.setFillColor(rgb(c.color)); ctx.fillPath()
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

    // MARK: drift bottle for finished notes

    /// Glass outline in bottle space: origin at the knot on the rope, y down.
    private func bottlePath() -> CGPath {
        let p = CGMutablePath()
        p.move(to: CGPoint(x: -7, y: 26))
        p.addLine(to: CGPoint(x: -7, y: 38))
        p.addQuadCurve(to: CGPoint(x: -22, y: 54), control: CGPoint(x: -22, y: 40))
        p.addLine(to: CGPoint(x: -22, y: 88))
        p.addQuadCurve(to: CGPoint(x: -14, y: 96), control: CGPoint(x: -22, y: 96))
        p.addLine(to: CGPoint(x: 14, y: 96))
        p.addQuadCurve(to: CGPoint(x: 22, y: 88), control: CGPoint(x: 22, y: 96))
        p.addLine(to: CGPoint(x: 22, y: 54))
        p.addQuadCurve(to: CGPoint(x: 7, y: 38), control: CGPoint(x: 22, y: 40))
        p.addLine(to: CGPoint(x: 7, y: 26))
        p.closeSubpath()
        return p
    }

    /// Notes flying into the bottle shrink toward the mouth and fade just before they slip inside.
    private func drawSinking() {
        for c in world.cards.filter({ $0.mode == .sink }).sorted(by: { $0.z < $1.z }) {
            let t = min(1, c.t)
            let a: CGFloat = t < 0.7 ? 1 : max(0, (1 - t) / 0.3)
            drawPaper(c, lift: 2, alpha: a); drawAttach(c, alpha: a)
        }
        for c in world.cards.filter({ $0.mode == .plane }).sorted(by: { $0.z < $1.z }) { drawPlaneFlight(c) }
    }

    /// Folding: the note shrinks away as the plane appears. Flight: the plane and a dashed trail behind it.
    private func drawPlaneFlight(_ c: Card) {
        let t = min(1, c.t)
        if t < PLANE_FOLD {
            let k = t / PLANE_FOLD
            let sc = c.sc
            c.sc = 1 - 0.7 * k * k
            drawPaper(c, lift: 2, alpha: 1 - k * k); drawAttach(c, alpha: 1 - k * k)
            c.sc = sc
            drawPlane(c, at: c.c, heading: c.th, scale: 0.4 + 0.6 * k, alpha: k)
            return
        }
        // trail: the stretch of path just flown, fading out behind the plane
        let e = c.pe, from = max(0, e - 0.22)
        if e - from > 0.01 {
            ctx.saveGState()
            ctx.setLineCap(.round)
            ctx.setLineDash(phase: 0, lengths: [3, 5])
            let n = 12
            for i in 0..<n {
                let a = from + (e - from) * CGFloat(i) / CGFloat(n), b = from + (e - from) * CGFloat(i + 1) / CGFloat(n)
                let p = world.planeAt(c, a).p, q = world.planeAt(c, b).p
                ctx.setStrokeColor(rgba(255, 255, 255, 0.7 * CGFloat(i) / CGFloat(n))); ctx.setLineWidth(3)
                line(p, q)
                ctx.setStrokeColor(rgb(INK, 0.35 * CGFloat(i) / CGFloat(n))); ctx.setLineWidth(1.2)
                line(p, q)
            }
            ctx.restoreGState()
        }
        let fade: CGFloat = e < 0.9 ? 1 : max(0, (1 - e) / 0.1)
        drawPlane(c, at: c.c, heading: c.th, scale: c.sc, alpha: fade)
    }

    /// A folded paper plane in the note's colour, nose along `heading`.
    private func drawPlane(_ c: Card, at p: CGPoint, heading: CGFloat, scale: CGFloat, alpha: CGFloat) {
        guard alpha > 0.01 else { return }
        func shade(_ hex: UInt32, _ k: CGFloat) -> CGColor {
            rgba(CGFloat((hex >> 16) & 0xFF) * k, CGFloat((hex >> 8) & 0xFF) * k, CGFloat(hex & 0xFF) * k, 1)
        }
        ctx.saveGState()
        ctx.setAlpha(alpha)
        ctx.translateBy(x: p.x, y: p.y); ctx.rotate(by: heading)
        // keep the big wing on top whichever way it flies
        let k = scale * 1.3
        ctx.scaleBy(x: k, y: cos(heading) < 0 ? -k : k)
        let nose = CGPoint(x: 22, y: 0), crease = CGPoint(x: -9, y: 1)
        let top = CGMutablePath(); top.addLines(between: [nose, CGPoint(x: -17, y: -14), crease]); top.closeSubpath()
        let under = CGMutablePath(); under.addLines(between: [nose, crease, CGPoint(x: -15, y: 10)]); under.closeSubpath()
        let keel = CGMutablePath(); keel.addLines(between: [nose, crease, CGPoint(x: -12, y: 6)]); keel.closeSubpath()
        shadow(0, 6, 8, rgba(40, 46, 62, 0.25))
        ctx.addPath(under); ctx.setFillColor(shade(c.color, 0.86)); ctx.fillPath()
        noShadow()
        ctx.addPath(keel); ctx.setFillColor(shade(c.color, 0.72)); ctx.fillPath()
        ctx.addPath(top); ctx.setFillColor(rgb(c.color)); ctx.fillPath()
        ctx.setStrokeColor(rgba(40, 46, 62, 0.28)); ctx.setLineWidth(0.8); ctx.setLineJoin(.round)
        ctx.addPath(top); ctx.strokePath()
        ctx.addPath(under); ctx.strokePath()
        // a tiny red "done" dot on the wing, so it reads as the finished note
        ctx.setFillColor(rgb(SEAL, 0.75)); dot(CGPoint(x: -4, y: -5), 2)
        ctx.restoreGState()
    }

    private func drawBottle() {
        let b = world.bottle, hang = world.bottleHang
        drawSinking()

        ctx.saveGState()
        ctx.translateBy(x: hang.x, y: hang.y); ctx.rotate(by: b.ang)
        ctx.translateBy(x: 0, y: 66); ctx.scaleBy(x: b.s, y: b.s); ctx.translateBy(x: 0, y: -66)

        // a short length of twine from the knot
        ctx.setLineCap(.round)
        ctx.setStrokeColor(rgb(0xF4EFE7)); ctx.setLineWidth(2)
        line(CGPoint(x: 0, y: 0), CGPoint(x: 0, y: 20))
        ctx.setLineDash(phase: 0, lengths: [2, 2.6]); ctx.setStrokeColor(rgb(SEAL)); ctx.setLineWidth(2)
        line(CGPoint(x: 0, y: 0), CGPoint(x: 0, y: 20))
        ctx.setLineDash(phase: 0, lengths: [])

        let glass = bottlePath()
        shadow(0, 6, 10, rgba(40, 46, 62, 0.18))
        ctx.addPath(glass); ctx.setFillColor(rgba(214, 232, 236, 0.42)); ctx.fillPath()
        noShadow()

        // finished notes, rolled into little scrolls
        ctx.saveGState()
        ctx.addPath(glass); ctx.clip()
        let items = Array(world.finished.prefix(12))
        for (i, c) in items.enumerated() {
            let row = i / 3, col = i % 3
            let x = -12 + CGFloat(col) * 12 + (row % 2 == 1 ? 5 : 0)
            let y = 89 - CGFloat(row) * 8
            ctx.saveGState()
            ctx.translateBy(x: x, y: y); ctx.rotate(by: (srand(c.seed, 5) - 0.5) * 0.9)
            let roll = CGPath(roundedRect: CGRect(x: -9, y: -3.5, width: 18, height: 7), cornerWidth: 3.5, cornerHeight: 3.5, transform: nil)
            ctx.addPath(roll); ctx.setFillColor(rgb(c.color)); ctx.fillPath()
            ctx.addPath(roll); ctx.setStrokeColor(rgba(60, 50, 40, 0.25)); ctx.setLineWidth(0.6); ctx.strokePath()
            ctx.setStrokeColor(rgb(SEAL, 0.8)); ctx.setLineWidth(1)
            line(CGPoint(x: 0, y: -3.5), CGPoint(x: 0, y: 3.5))
            ctx.restoreGState()
        }
        // glass shading
        linear([rgba(255, 255, 255, 0.4), rgba(255, 255, 255, 0), rgba(255, 255, 255, 0), rgba(60, 90, 110, 0.14)], [0, 0.3, 0.72, 1],
               CGPoint(x: -22, y: 0), CGPoint(x: 22, y: 0))
        ctx.restoreGState()

        ctx.addPath(glass); ctx.setStrokeColor(rgba(90, 125, 145, 0.55)); ctx.setLineWidth(1.2); ctx.strokePath()
        ctx.setStrokeColor(rgba(255, 255, 255, 0.75)); ctx.setLineWidth(2.2)
        line(CGPoint(x: -15, y: 57), CGPoint(x: -15, y: 84))
        ctx.setLineWidth(1.2); line(CGPoint(x: -4, y: 29), CGPoint(x: -4, y: 35))

        // cork
        let cork = CGPath(roundedRect: CGRect(x: -6.5, y: 18, width: 13, height: 11), cornerWidth: 2, cornerHeight: 2, transform: nil)
        ctx.addPath(cork); ctx.setFillColor(rgb(0xC9A477)); ctx.fillPath()
        ctx.setFillColor(rgba(110, 75, 35, 0.35))
        for (dx, dy) in [(-3, 21), (2, 23), (-1, 26), (3.5, 19.5)] as [(CGFloat, CGFloat)] { dot(CGPoint(x: dx, y: dy), 0.7) }
        // twine wrapped round the neck
        ctx.setLineWidth(1.4)
        ctx.setStrokeColor(rgb(SEAL)); line(CGPoint(x: -8, y: 31), CGPoint(x: 8, y: 32.5))
        ctx.setStrokeColor(rgb(0xF4EFE7)); line(CGPoint(x: -8, y: 33.5), CGPoint(x: 8, y: 35))

        // little kraft tag with the count
        let n = world.finished.count
        if n > 0 {
            ctx.saveGState()
            ctx.translateBy(x: 9, y: 34); ctx.rotate(by: 0.35)
            ctx.setStrokeColor(rgb(0xF4EFE7)); ctx.setLineWidth(0.9)
            line(CGPoint(x: 0, y: 0), CGPoint(x: 8, y: 0))
            let tag = CGMutablePath()
            tag.move(to: CGPoint(x: 8, y: -6)); tag.addLine(to: CGPoint(x: 28, y: -6)); tag.addLine(to: CGPoint(x: 28, y: 6))
            tag.addLine(to: CGPoint(x: 8, y: 6)); tag.addLine(to: CGPoint(x: 4, y: 0)); tag.closeSubpath()
            shadow(0, 1, 2, rgba(40, 46, 62, 0.18))
            ctx.addPath(tag); ctx.setFillColor(rgb(0xD5AE7E)); ctx.fillPath()
            noShadow()
            ctx.setFillColor(rgb(0xF4EFE7)); dot(CGPoint(x: 8, y: 0), 1.3)
            drawCentered(text("\(n)", font: Fonts.title(10), color: rgb(INK)), at: CGPoint(x: 18, y: 0.5))
            ctx.restoreGState()
        }
        ctx.restoreGState()
    }

    /// Shown while a note is dragged toward the Dock.
    private func drawTrashHint(_ c: Card) {
        let s = text("拖到废纸篓删除", font: Fonts.title(13), color: rgb(0xFBFAF5))
        let sz = s.size(), w = sz.width + 22
        let p = world.ptr
        let r = CGRect(x: clamp(p.x - w / 2, 8, world.W - w - 8), y: max(8, p.y - c.h / 2 * c.sc - 44), width: w, height: 24)
        ctx.addPath(CGPath(roundedRect: r, cornerWidth: 8, cornerHeight: 8, transform: nil))
        ctx.setFillColor(rgb(SEAL, 0.92)); ctx.fillPath()
        drawCentered(s, at: CGPoint(x: r.midX, y: r.midY))
    }

    private func drawHotLabel() {
        let c = world.bottleCenter
        let s = text("松手放进漂流瓶", font: Fonts.title(14), color: rgb(0xFBFAF5))
        let sz = s.size(), w = sz.width + 20, x = c.x + 34
        ctx.addPath(CGPath(roundedRect: CGRect(x: x, y: c.y - 12, width: w, height: 24), cornerWidth: 8, cornerHeight: 8, transform: nil))
        ctx.setFillColor(rgb(INK)); ctx.fillPath()
        drawCentered(s, at: CGPoint(x: x + w / 2, y: c.y))
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
        let x: CGFloat = 16, y = world.anchorY + 172
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
        if Theme.current == .sticky { ctx.setAlpha(0) }
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

    // MARK: first-run guide

    private func drawGuide() {
        world.guideSkipRect = .zero
        guard world.guideHintVisible, let step = world.guideStep, let c = world.guideTarget else { return }
        let age = world.tWorld - world.guideStepAt
        let a = CGFloat(min(1, max(0, (age - 0.3) / 0.25)))     // lets the note settle first
        guard a > 0 else { return }
        let cc = c.center
        func onNote(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
            let p = rot(c.th, x, y)
            return CGPoint(x: cc.x + p.x, y: cc.y + p.y)
        }

        ctx.saveGState()
        ctx.setAlpha(a)
        switch step {
        case .takeDown:
            let from = onNote(0, c.h / 2 - 6)
            guideArrow(from: from, to: CGPoint(x: from.x, y: from.y + 124), age: age)
        case .hangBack:
            let top = onNote(0, -c.h / 2 - 6), ropeY = world.ropeAt(top.x).y + 8
            if top.y - ropeY > 40 { guideArrow(from: top, to: CGPoint(x: top.x, y: ropeY), age: age) }
            guidePulse(at: onNote(c.w / 2 - 15, -c.h / 2 + 15), age: age)
        case .write:
            guidePulse(at: cc, age: age)
        case .tick:
            let row = world.taskLayout(c)?.rows.first { !$0.done }
            guidePulse(at: row.map { onNote($0.box.x, $0.box.y) } ?? cc, age: age)
        case .trash:
            let d = world.deleteCenter(c)
            guidePulse(at: onNote(d.x, d.y), age: age)
        case .finish:
            let b = world.checkboxCenter(c)
            guidePulse(at: onNote(b.x, b.y), age: age)
        }

        // the slip of paper, beside the arrow rather than on top of it
        let body = NSMutableAttributedString(attributedString: text(step.hint, font: .systemFont(ofSize: 13), color: rgba(60, 60, 67, 0.85)))
        let para = NSMutableParagraphStyle(); para.lineSpacing = 2
        body.addAttribute(.paragraphStyle, value: para, range: NSRange(location: 0, length: body.length))
        let w: CGFloat = 276
        let bodyH = ceil(body.boundingRect(with: CGSize(width: w - 30, height: 200), options: [.usesLineFragmentOrigin]).height)
        let h = 39 + bodyH + 13
        var x = cc.x + 26
        if x + w > world.W - 16 { x = cc.x - 26 - w }
        x = clamp(x, 16, max(16, world.W - 16 - w))
        var y = cc.y + c.h / 2 + 22
        if y + h > world.H - 16 { y = cc.y - c.h / 2 - 22 - h }
        let rect = CGRect(x: x, y: max(16, y), width: w, height: h)

        let card = CGPath(roundedRect: rect, cornerWidth: 14, cornerHeight: 14, transform: nil)
        shadow(0, 10, 28, rgba(0, 0, 0, 0.22))
        ctx.addPath(card); ctx.setFillColor(rgba(255, 255, 255, 0.97)); ctx.fillPath()
        noShadow()
        ctx.addPath(card); ctx.setStrokeColor(rgba(0, 0, 0, 0.08)); ctx.setLineWidth(0.5); ctx.strokePath()

        text(step.title, font: .systemFont(ofSize: 16, weight: .semibold), color: rgb(0x1D1D1F)).draw(at: CGPoint(x: rect.minX + 16, y: rect.minY + 13))
        body.draw(with: CGRect(x: rect.minX + 16, y: rect.minY + 39, width: w - 30, height: bodyH), options: [.usesLineFragmentOrigin])

        // "2 / 4 · skip" in the top corner
        let skipRect = CGRect(x: rect.maxX - 50, y: rect.minY + 6, width: 46, height: 30)   // generous click target
        let hoverSkip = skipRect.contains(world.ptr)
        let skip = text("跳过", font: .systemFont(ofSize: 12), color: hoverSkip ? rgb(0x0A84FF) : rgba(60, 60, 67, 0.6))
        let count = text("\(step.rawValue + 1) / \(GuideStep.allCases.count)", font: .systemFont(ofSize: 12), color: rgba(60, 60, 67, 0.4))
        let sk = skip.size(), cs = count.size()
        let skipX = rect.maxX - 14 - sk.width
        skip.draw(at: CGPoint(x: skipX, y: rect.minY + 14))
        count.draw(at: CGPoint(x: skipX - 10 - cs.width, y: rect.minY + 14))
        ctx.restoreGState()
        world.guideSkipRect = skipRect
    }

    /// A dashed arrow with a dot travelling along it, showing the gesture. Readable on any wallpaper.
    private func guideArrow(from: CGPoint, to: CGPoint, age: Double) {
        let angle = atan2(to.y - from.y, to.x - from.x)
        func head(_ s: CGFloat) -> [CGPoint] {
            [CGPoint(x: to.x + cos(angle + 2.5) * s, y: to.y + sin(angle + 2.5) * s), to,
             CGPoint(x: to.x + cos(angle - 2.5) * s, y: to.y + sin(angle - 2.5) * s)]
        }
        ctx.saveGState()
        ctx.setLineCap(.round); ctx.setLineJoin(.round)
        ctx.setStrokeColor(rgba(255, 255, 255, 0.75)); ctx.setLineWidth(5)
        line(from, to); ctx.addLines(between: head(12)); ctx.strokePath()
        ctx.setStrokeColor(rgb(SEAL)); ctx.setLineWidth(2.2)
        ctx.addLines(between: head(12)); ctx.strokePath()
        ctx.setLineDash(phase: 0, lengths: [6, 6])
        line(from, to)
        ctx.setLineDash(phase: 0, lengths: [])
        let u = CGFloat(age.truncatingRemainder(dividingBy: 1.7) / 1.3)
        if u < 1 {
            let e = u * u * (3 - 2 * u)
            let p = CGPoint(x: from.x + (to.x - from.x) * e, y: from.y + (to.y - from.y) * e)
            ctx.setFillColor(rgba(255, 255, 255, 0.95)); dot(p, 8)
            ctx.setFillColor(rgb(SEAL)); dot(p, 5.5)
        }
        ctx.restoreGState()
    }

    /// Soft rings that say "here".
    private func guidePulse(at p: CGPoint, age: Double) {
        ctx.saveGState()
        for k in 0..<2 {
            let u = CGFloat((age + Double(k) * 0.6).truncatingRemainder(dividingBy: 1.2) / 1.2)
            let r = 9 + 15 * u
            let box = CGRect(x: p.x - r, y: p.y - r, width: r * 2, height: r * 2)
            ctx.setStrokeColor(rgba(255, 255, 255, 0.7 * (1 - u))); ctx.setLineWidth(4.5); ctx.strokeEllipse(in: box)
            ctx.setStrokeColor(rgb(SEAL, 1 - u)); ctx.setLineWidth(2.2); ctx.strokeEllipse(in: box)
        }
        ctx.restoreGState()
    }
}
