import Foundation
import CoreGraphics

// MARK: - Geometry helpers

let CW: CGFloat = 150          // note width
let CH: CGFloat = 132          // note height
let CLIP: CGFloat = 8          // rope → note top
let STAMP_OFF: CGFloat = 18    // checkbox inset from bottom-right
let GAP: CGFloat = CW + 28     // min spacing on the rope
let ROPE_NODES = 64

@inline(__always) func rot(_ th: CGFloat, _ x: CGFloat, _ y: CGFloat) -> CGPoint {
    let c = cos(th), s = sin(th)
    return CGPoint(x: c * x - s * y, y: s * x + c * y)
}
@inline(__always) func hypot2(_ x: CGFloat, _ y: CGFloat) -> CGFloat { (x * x + y * y).squareRoot() }
@inline(__always) func clamp(_ v: CGFloat, _ lo: CGFloat, _ hi: CGFloat) -> CGFloat { max(lo, min(hi, v)) }
/// Deterministic pseudo-random in [0,1) for stable per-note decoration.
func srand(_ seed: Double, _ i: Double) -> CGFloat {
    let x = sin(seed * 12.9898 + i * 78.233) * 43758.5453
    return CGFloat(x - floor(x))
}

// MARK: - Bodies

enum Mode { case hang, drag, free, sink, crumple }

final class Card {
    let id: UUID
    var text: String
    var style: Int
    let seed: Double

    var mode: Mode = .hang
    let w: CGFloat = CW, h: CGFloat = CH
    // position along the rope
    var x: CGFloat = 0, homeX: CGFloat = 0, vx: CGFloat = 0
    // rotation
    var th: CGFloat = 0, om: CGFloat = 0
    // pivot (rope point or the grabbing hand)
    var piv = CGPoint.zero, pv = CGPoint.zero, pa = CGPoint.zero
    var p1: CGPoint?, p2: CGPoint?
    var r0 = CGPoint(x: 0, y: CLIP + CH / 2)     // pivot → centre, in note space
    var c = CGPoint.zero                           // centre
    var v = CGPoint.zero                           // desk velocity
    var rest: CGFloat = 0
    var snap = CGPoint.zero                        // visual offset that eases to zero
    var force = CGPoint.zero                       // load on the rope
    var sc: CGFloat = 1
    var z = 0
    // finishing
    var stampAt: Double?
    var stampDate: Date?
    var stampPending = false
    var fallAt: Double = 0
    var t: CGFloat = 0, dur: CGFloat = 0.4
    var s0 = CGPoint.zero, ctrl = CGPoint.zero, th0: CGFloat = 0, spin: CGFloat = 0
    var doneAt: Date?
    var wasOnRope = false      // waiting on the desk while the rope is hidden
    // file shortcuts
    var kind: CardKind = .note
    var url: URL?
    var bookmark: Data?
    var thumb: CGImage?
    var itemCount: Int?
    var missing = false
    var ext: String { url?.pathExtension.uppercased() ?? "" }
    /// Paper colour: notes follow their journal style, shortcuts have their own stock.
    var color: UInt32 {
        switch kind {
        case .note:
            if Theme.current == .sticky { return stickyColors[((style % stickyColors.count) + stickyColors.count) % stickyColors.count] }
            return styleDef.color
        case .image: return 0xFCFBF8
        case .folder: return 0xD6B38A
        case .file: return 0xFBFBF7
        }
    }

    init(id: UUID = UUID(), text: String, style: Int) {
        self.id = id; self.text = text; self.style = style
        let u = id.uuid
        seed = Double((Int(u.0) << 8 | Int(u.1)) % 997 + 1)
    }

    var styleDef: NoteStyle { journalStyles[((style % journalStyles.count) + journalStyles.count) % journalStyles.count] }
    var center: CGPoint { mode == .hang ? CGPoint(x: c.x + snap.x, y: c.y + snap.y) : c }
    var title: String {
        let t = text.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? ""
        let s = t.trimmingCharacters(in: .whitespaces)
        return s.isEmpty ? "便签" : s
    }
    var inertia: CGFloat { (w * w + h * h) / 12 + r0.x * r0.x + r0.y * r0.y }
}

struct RopeNode { var x, y, px, py, fx, fy: CGFloat }

/// Drift bottle hanging from the left end of the twine; finished notes go in here.
struct Bottle {
    var x: CGFloat = 46
    var ang: CGFloat = 0, av: CGFloat = 0     // gentle swing
    var s: CGFloat = 1, sv: CGFloat = 0       // grows a little while a note hovers over it
    var hot = false
}

// MARK: - World

final class World {
    var W: CGFloat = 1280, H: CGFloat = 800
    let anchorY: CGFloat = 12
    var nodes: [RopeNode] = []
    var cards: [Card] = []
    var finished: [Card] = []          // newest first
    var bottle = Bottle()
    /// Rope, bottle and "+" tag hidden: notes simply lie on the desktop.
    private(set) var ropeHidden = false
    var tWorld: Double = 0
    var zTop = 1

    // pointer
    var ptr = CGPoint(x: -9999, y: -9999)
    private var lastPtr = CGPoint(x: -9999, y: -9999)
    private var pvel = CGPoint.zero
    var hoverCard: Card?
    var hoverStamp: Card?
    var hoverHangBack: Card?
    /// Short confirmation shown above a note, e.g. after copying.
    var flash: (card: Card, text: String, until: Double)?
    var dragging: Card?
    private var pending: (card: Card, at: CGPoint)?
    var dragSlot: CGFloat?
    var slotX: CGFloat?

    // undo toast (button rect is filled in by the renderer)
    var toast: (card: Card, until: Double)?
    var toastButton: CGRect = .zero
    var toastRect: CGRect = .zero

    // callbacks to the app layer
    var onChange: (() -> Void)?
    var onEdit: ((Card) -> Void)?
    var onOpenFinished: (() -> Void)?
    var onOpen: ((Card) -> Void)?
    var onReveal: ((Card) -> Void)?
    var onNeedThumbnail: ((Card) -> Void)?

    /// Files are being dragged in from Finder (set by the app layer each frame).
    var externalDrag = false

    /// Seconds of "keep redrawing" left; anything moving refreshes it.
    private(set) var awake: Double = 1

    // MARK: layout

    func resize(width: CGFloat, height: CGFloat) {
        let oldW = W, oldH = H
        W = max(400, width); H = max(300, height)
        if !nodes.isEmpty {
            let sx = W / oldW, sy = H / oldH
            for c in cards {
                c.homeX *= sx; c.x *= sx
                if c.mode != .hang { c.c.x *= sx; c.c.y *= sy }
            }
        }
        buildRope()
        for c in cards where c.mode == .hang { c.p1 = nil; c.p2 = nil }
        poke()
    }

    private func buildRope() {
        nodes = (0..<ROPE_NODES).map { i in
            let x = -6 + (W + 12) * CGFloat(i) / CGFloat(ROPE_NODES - 1)
            return RopeNode(x: x, y: anchorY, px: x, py: anchorY, fx: 0, fy: 0)
        }
    }

    func ropeAt(_ x: CGFloat) -> (x: CGFloat, y: CGFloat, i: Int, t: CGFloat) {
        var lo = 0, hi = nodes.count - 1
        while hi - lo > 1 {
            let m = (lo + hi) >> 1
            if nodes[m].x <= x { lo = m } else { hi = m }
        }
        let a = nodes[lo], b = nodes[hi]
        let d = b.x - a.x
        let t = clamp((x - a.x) / (d == 0 ? 1 : d), 0, 1)
        return (a.x + (b.x - a.x) * t, a.y + (b.y - a.y) * t, lo, t)
    }

    // rope ends are taken by the bottle (left) and the "+" tag (right)
    var ropeLo: CGFloat { 100 + CW / 2 }
    var ropeHi: CGFloat { W - 100 - CW / 2 }

    var bottleHang: CGPoint { let r = ropeAt(bottle.x); return CGPoint(x: r.x, y: r.y) }
    /// Bottle space (origin at the knot on the rope, y down) → screen.
    func bottlePoint(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
        let h = bottleHang, p = rot(bottle.ang, x, y)
        return CGPoint(x: h.x + p.x, y: h.y + p.y)
    }
    var bottleMouth: CGPoint { bottlePoint(0, 22) }
    var bottleCenter: CGPoint { bottlePoint(0, 66) }

    private struct Slot { var id: UUID?; var x: CGFloat; var r: CGFloat = 0 }

    /// Resolved rope positions: no two notes closer than GAP, the hovered slot stays put.
    private func layoutTargets() -> [UUID: CGFloat] {
        var items = cards.filter { $0.mode == .hang }.map { Slot(id: $0.id, x: $0.homeX) }
        if let s = dragSlot { items.append(Slot(id: nil, x: s)) }
        items.sort { $0.x < $1.x }
        let lo = ropeLo, hi = ropeHi
        for i in items.indices { items[i].r = clamp(items[i].x, lo, hi) }
        if items.count > 1 {
            for _ in 0..<40 {
                var moved = false
                for i in 0..<(items.count - 1) {
                    let o = GAP - (items[i + 1].r - items[i].r)
                    if o <= 0.01 { continue }
                    moved = true
                    if items[i].id == nil { items[i + 1].r += o }
                    else if items[i + 1].id == nil { items[i].r -= o }
                    else { items[i].r -= o / 2; items[i + 1].r += o / 2 }
                }
                for i in items.indices { items[i].r = clamp(items[i].r, lo, hi) }
                if !moved { break }
            }
            for i in 1..<items.count { items[i].r = max(items[i].r, items[i - 1].r + GAP) }
            for i in stride(from: items.count - 2, through: 0, by: -1) { items[i].r = min(items[i].r, items[i + 1].r - GAP) }
            for i in items.indices { items[i].r = max(items[i].r, lo); if i > 0 { items[i].r = max(items[i].r, items[i - 1].r + GAP) } }
        }
        var map: [UUID: CGFloat] = [:]
        slotX = nil
        for it in items {
            if let id = it.id { map[id] = it.r } else { slotX = it.r }
        }
        return map
    }

    func widestGap() -> CGFloat {
        let xs = cards.filter { $0.mode == .hang }.map(\.homeX).sorted()
        let pts = [ropeLo - GAP / 2] + xs + [ropeHi + GAP / 2]
        var best = W / 2, gap: CGFloat = -1
        for i in 0..<(pts.count - 1) {
            let g = pts[i + 1] - pts[i]
            if g > gap { gap = g; best = (pts[i] + pts[i + 1]) / 2 }
        }
        return best
    }

    // MARK: physics

    func advance(_ dtIn: Double) {
        let dt = min(max(dtIn, 1.0 / 240), 1.0 / 30)
        frameInteract(CGFloat(dt))
        let steps = max(1, Int(ceil(dt * 240)))
        let h = CGFloat(dt) / CGFloat(steps)
        for _ in 0..<steps { step(h) }
        if let t = toast, tWorld > t.until { toast = nil; poke() }
        if let f = flash, tWorld > f.until { flash = nil; poke() }
        // stay awake while anything moves
        var motion: CGFloat = 0
        for c in cards {
            motion = max(motion, abs(c.om), abs(c.vx) / 60, hypot2(c.snap.x, c.snap.y) / 4, hypot2(c.v.x, c.v.y) / 60)
            if c.mode != .hang && c.mode != .free { motion = 10 }
            if c.stampPending { motion = 10 }
        }
        for n in nodes { motion = max(motion, abs(n.y - n.py) * 60, abs(n.x - n.px) * 60) }
        motion = max(motion, abs(bottle.sv), abs(bottle.av), abs(bottle.ang) * 4, abs(bottle.s - (bottle.hot ? 1.08 : 1)) * 20)
        if motion > 0.02 || dragging != nil || toast != nil || flash != nil { awake = 0.4 } else { awake -= dt }
    }
    var needsRedraw: Bool { awake > 0 }
    func poke() { awake = max(awake, 0.4) }

    private func step(_ h: CGFloat) {
        tWorld += Double(h)
        let g = Tuning.gravity

        // clips slide toward their resolved spots
        let targets = layoutTargets()
        for c in cards where c.mode == .hang {
            let tx = targets[c.id] ?? c.homeX, w: CGFloat = 9.5
            let a = w * w * (tx - c.x) - 2 * 0.72 * w * c.vx
            c.vx += a * h; c.x += c.vx * h
        }

        // note loads onto the rope
        for c in cards where c.mode == .hang {
            let r = ropeAt(c.x)
            let j = min(nodes.count - 1, r.i + 1)
            nodes[r.i].fx += c.force.x * (1 - r.t); nodes[r.i].fy += c.force.y * (1 - r.t)
            nodes[j].fx += c.force.x * r.t;       nodes[j].fy += c.force.y * r.t
        }

        // Verlet rope
        let damp = 1 - Tuning.ropeDamp, h2 = h * h
        for i in 1..<(nodes.count - 1) {
            var n = nodes[i]
            let vx = (n.x - n.px) * damp, vy = (n.y - n.py) * damp
            n.px = n.x; n.py = n.y
            n.x += vx + n.fx * h2
            n.y += vy + (g + n.fy) * h2
            n.fx = 0; n.fy = 0
            nodes[i] = n
        }
        let last = nodes.count - 1
        nodes[0] = RopeNode(x: -6, y: anchorY, px: -6, py: anchorY, fx: 0, fy: 0)
        nodes[last] = RopeNode(x: W + 6, y: anchorY, px: W + 6, py: anchorY, fx: 0, fy: 0)

        // distance constraints: a rope pulls, never pushes
        let L = (W + 12) * (1 + Tuning.slack) / CGFloat(nodes.count - 1)
        let iters = 1 + Int((Tuning.stiff * 15).rounded())
        let kf = 0.3 + 0.7 * Tuning.stiff
        for it in 0..<iters {
            let fwd = it % 2 == 0
            for k in 0..<last {
                let i = fwd ? k : last - 1 - k
                let a = nodes[i], b = nodes[i + 1]
                let dx = b.x - a.x, dy = b.y - a.y
                let d = max(1e-6, hypot2(dx, dy))
                if d <= L { continue }
                let diff = (d - L) / d * kf
                if i == 0 { nodes[i + 1].x -= dx * diff; nodes[i + 1].y -= dy * diff }
                else if i + 1 == last { nodes[i].x += dx * diff; nodes[i].y += dy * diff }
                else {
                    nodes[i].x += dx * diff * 0.5; nodes[i].y += dy * diff * 0.5
                    nodes[i + 1].x -= dx * diff * 0.5; nodes[i + 1].y -= dy * diff * 0.5
                }
            }
        }

        // bottle: grows a touch while hot, swings gently when something drops in
        let bt: CGFloat = bottle.hot ? 1.08 : 1
        let ba = 320 * (bt - bottle.s) - 2 * 0.45 * CGFloat(320).squareRoot() * bottle.sv
        bottle.sv += ba * h; bottle.s += bottle.sv * h
        let aa = -16 * bottle.ang - 2.4 * bottle.av
        bottle.av += aa * h; bottle.ang += bottle.av * h

        var done: [(Card, String)] = []
        for c in cards {
            if c.stampPending && tWorld >= c.fallAt && (c.mode == .hang || c.mode == .free) {
                c.stampPending = false
                startSink(c, duration: 0.95)
            }
            switch c.mode {
            case .hang:
                let r = ropeAt(c.x)
                let p = CGPoint(x: r.x, y: r.y)
                if let p1 = c.p1, let p2 = c.p2 {
                    var ax = (p.x - 2 * p1.x + p2.x) / h2, ay = (p.y - 2 * p1.y + p2.y) / h2
                    let m = hypot2(ax, ay), lim: CGFloat = 30000
                    if m > lim { ax *= lim / m; ay *= lim / m }
                    c.pa.x += (ax - c.pa.x) * 0.3; c.pa.y += (ay - c.pa.y) * 0.3
                }
                c.p2 = c.p1; c.p1 = p; c.piv = p
                pendulum(c, h)
                let k = exp(-h * 9); c.snap.x *= k; c.snap.y *= k
            case .drag:
                let w = Tuning.follow
                let ax = w * w * (ptr.x - c.piv.x) - 2 * w * c.pv.x
                let ay = w * w * (ptr.y - c.piv.y) - 2 * w * c.pv.y
                c.pv.x += ax * h; c.pv.y += ay * h
                c.piv.x += c.pv.x * h; c.piv.y += c.pv.y * h
                c.pa = CGPoint(x: ax, y: ay)
                pendulum(c, h)
                let st: CGFloat = bottle.hot ? 0.55 : 1
                c.sc += (st - c.sc) * (1 - exp(-h * 14))
            case .sink:
                c.t += h / c.dur
                let t = min(1, c.t), e = t * t, u = 1 - e
                let m = bottleMouth
                c.c.x = u * u * c.s0.x + 2 * u * e * c.ctrl.x + e * e * m.x
                c.c.y = u * u * c.s0.y + 2 * u * e * c.ctrl.y + e * e * m.y
                c.sc = 1 - 0.92 * e; c.th = c.th0 + c.spin * e
                if c.t >= 1 { done.append((c, "bottle")) }
            case .crumple:
                c.c.x += c.v.x * h; c.c.y += c.v.y * h; c.th += c.spin * h
                c.t += h / 0.2
                if c.c.x < -90 || c.c.x > W + 90 || c.c.y < -90 || c.c.y > H + 90 { done.append((c, "fling")) }
            case .free:
                c.c.x += c.v.x * h; c.c.y += c.v.y * h
                let k = exp(-Tuning.friction * h); c.v.x *= k; c.v.y *= k
                let m: CGFloat = 40, spd = hypot2(c.v.x, c.v.y)
                if spd > 650 && (c.c.x < m || c.c.x > W - m || c.c.y > H - 40 || c.c.y < 40) { startCrumple(c); continue }
                if c.c.x < m { c.c.x = m; c.v.x = abs(c.v.x) * 0.4 }
                if c.c.x > W - m { c.c.x = W - m; c.v.x = -abs(c.v.x) * 0.4 }
                if c.c.y < 40 { c.c.y = 40; c.v.y = abs(c.v.y) * 0.4 }
                if c.c.y > H - 40 { c.c.y = H - 40; c.v.y = -abs(c.v.y) * 0.4 }
                let al = -55 * (c.th - c.rest) - 9 * c.om
                c.om += al * h; c.th += c.om * h
            }
        }
        for (c, how) in done { archive(c, how: how) }
    }

    /// Physical pendulum hanging from a moving pivot.
    private func pendulum(_ c: Card, _ h: CGFloat) {
        let d = rot(c.th, c.r0.x, c.r0.y)
        let fx = -c.pa.x, fy = Tuning.gravity - c.pa.y
        let I = c.inertia
        let al = (d.x * fy - d.y * fx) / I - Tuning.swingDamp * c.om - 0.12 * c.om * abs(c.om)
        c.om += al * h; c.th += c.om * h
        // reaction on the pivot, fed back into the rope
        let acx = c.pa.x - al * d.y - c.om * c.om * d.x
        let acy = c.pa.y + al * d.x - c.om * c.om * d.y
        let m = Tuning.cardMass
        var Fx = m * (-acx) * Tuning.coupling
        var Fy = m * Tuning.gravity * (1 - Tuning.coupling) + m * (Tuning.gravity - acy) * Tuning.coupling
        let lim = 4 * m * Tuning.gravity, mag = hypot2(Fx, Fy)
        if mag > lim { Fx *= lim / mag; Fy *= lim / mag }
        c.force = CGPoint(x: Fx, y: Fy)
        let d2 = rot(c.th, c.r0.x, c.r0.y)
        c.c = CGPoint(x: c.piv.x + d2.x, y: c.piv.y + d2.y)
    }

    // MARK: per-frame interaction (pointer is polled, so this works even when clicks pass through)

    private func frameInteract(_ dt: CGFloat) {
        guard ptr.x > -9000 else { lastPtr = ptr; return }
        if lastPtr.x < -9000 { lastPtr = ptr }
        let vx = (ptr.x - lastPtr.x) / dt, vy = (ptr.y - lastPtr.y) / dt
        pvel.x += (vx - pvel.x) * 0.5; pvel.y += (vy - pvel.y) * 0.5

        if dragging == nil && pending == nil {
            // brush past hanging notes
            if Tuning.brush > 0 && hypot2(vx, vy) > 30 {
                for c in cards where c.mode == .hang && hit(c, ptr) {
                    let rx = ptr.x - c.piv.x, ry = ptr.y - c.piv.y
                    let dw = clamp((rx * pvel.y - ry * pvel.x) / c.inertia * Tuning.brush * 0.012, -0.05, 0.05)
                    // only ever a light sway
                    if abs(c.om + dw) < Tuning.brushCap || abs(c.om + dw) < abs(c.om) { c.om += dw }
                    poke()
                }
            }
        }

        if let c = dragging {
            let up = rot(c.th, 0, -c.h / 2 * c.sc)
            let tc = CGPoint(x: c.c.x + up.x, y: c.c.y + up.y)
            let r = ropeAt(clamp(tc.x, 1, W - 1))
            let near = !ropeHidden && tc.y > r.y - 60 && tc.y < r.y + 95 && tc.x > 30 && tc.x < W - 30
            let bc = bottleCenter
            bottle.hot = !ropeHidden && (hypot2(c.c.x - bc.x, c.c.y - bc.y) < 95 || hypot2(ptr.x - bc.x, ptr.y - bc.y) < 60)
            dragSlot = near && !bottle.hot ? tc.x : nil
        } else if externalDrag {
            bottle.hot = false
            dragSlot = ropeDropOK(ptr) ? ptr.x : nil
        } else {
            dragSlot = nil; bottle.hot = false
        }
        lastPtr = ptr
    }

    // MARK: hit testing

    func hit(_ c: Card, _ p: CGPoint) -> Bool {
        let cc = c.center
        let q = rot(-c.th, p.x - cc.x, p.y - cc.y)
        if abs(q.x) <= c.w / 2 + 3 && abs(q.y) <= c.h / 2 + 3 { return true }
        return abs(q.x) <= 12 && q.y < -c.h / 2 && q.y > -c.h / 2 - 24
    }
    func stampHit(_ c: Card, _ p: CGPoint) -> Bool {
        guard c.stampAt == nil, c.mode == .hang || c.mode == .free else { return false }
        let cc = c.center
        let q = rot(-c.th, p.x - cc.x, p.y - cc.y)
        return hypot2(q.x - (c.w / 2 - STAMP_OFF), q.y - (c.h / 2 - STAMP_OFF)) < 13
    }
    func pick(_ p: CGPoint) -> Card? {
        for c in cards.reversed() where c.mode == .hang && hit(c, p) { return c }
        for c in cards.filter({ $0.mode == .free }).sorted(by: { $0.z > $1.z }) where hit(c, p) { return c }
        return nil
    }
    /// The little "hang back" button on a note lying on the desk.
    func hangBackHit(_ c: Card, _ p: CGPoint) -> Bool {
        guard c.mode == .free, !ropeHidden else { return false }
        let cc = c.center
        let q = rot(-c.th, p.x - cc.x, p.y - cc.y)
        return hypot2(q.x - (c.w / 2 - 15), q.y - (-c.h / 2 + 15)) < 13
    }

    func bottleHit(_ p: CGPoint) -> Bool {
        guard !ropeHidden else { return false }
        let c = bottleCenter, m = bottleMouth
        return hypot2(p.x - c.x, p.y - c.y) < 34 || (abs(p.x - m.x) < 12 && p.y > m.y - 24 && p.y < c.y)
    }
    var plusCenter: CGPoint { let x = W - 46; return CGPoint(x: x, y: ropeAt(x).y + 30) }
    func plusHit(_ p: CGPoint) -> Bool { !ropeHidden && hypot2(p.x - plusCenter.x, p.y - plusCenter.y) < 20 }
    func toastHit(_ p: CGPoint) -> Bool { toast != nil && toastRect.contains(p) }

    /// A file dragged from Finder can be dropped in the band just around the rope.
    func ropeDropOK(_ p: CGPoint) -> Bool {
        guard !ropeHidden, p.x > 30, p.x < W - 30 else { return false }
        let r = ropeAt(p.x)
        return p.y > r.y - 50 && p.y < r.y + 160
    }

    /// Whether the overlay should take the mouse at this point (otherwise clicks pass through).
    func wantsMouse(at p: CGPoint) -> Bool {
        if externalDrag { return ropeDropOK(p) }
        return dragging != nil || pending != nil || pick(p) != nil || bottleHit(p) || plusHit(p) || toastHit(p)
    }

    func updateHover() {
        let hc = pick(ptr)
        let hs = hc.flatMap { stampHit($0, ptr) ? $0 : nil }
        let hb = hc.flatMap { hangBackHit($0, ptr) ? $0 : nil }
        if hc !== hoverCard || hs !== hoverStamp || hb !== hoverHangBack { poke() }
        hoverCard = hc; hoverStamp = hs; hoverHangBack = hb
    }

    // MARK: pointer events

    func pointerDown(_ p: CGPoint, clickCount: Int) {
        ptr = p
        if toast != nil && toastButton.contains(p), let c = toast?.card { restore(c); return }
        if plusHit(p) { addNote(); return }
        if let c = pick(p) {
            if hangBackHit(c, p) { hangBack(c); return }
            if stampHit(c, p) { stamp(c); return }
            if clickCount >= 2 {
                pending = nil
                if c.kind != .note { onOpen?(c) } else if c.stampAt == nil { onEdit?(c) }
                return
            }
            pending = (c, p)
            return
        }
        if bottleHit(p) { bottle.av += 0.9; poke(); onOpenFinished?() }
    }

    func pointerDragged(_ p: CGPoint) {
        ptr = p
        if let pd = pending, dragging == nil, hypot2(p.x - pd.at.x, p.y - pd.at.y) > 5 {
            startDrag(pd.card); pending = nil
        }
    }

    func pointerUp(_ p: CGPoint) {
        ptr = p
        if dragging != nil { endDrag() }
        else if let pd = pending {
            let c = pd.card
            let side: CGFloat = p.x < c.center.x ? 1 : -1
            c.om += side * Tuning.nudge * (c.mode == .hang ? 1 : 0.6)
            poke()
        }
        pending = nil
    }

    private func startDrag(_ c: Card) {
        let cc = c.center
        if c.mode == .hang { c.c = cc; c.snap = .zero }
        c.mode = .drag; c.stampPending = false; c.sc = 1
        c.piv = ptr; c.pv = .zero; c.pa = .zero
        c.r0 = rot(-c.th, c.c.x - ptr.x, c.c.y - ptr.y)
        zTop += 1; c.z = zTop
        dragging = c
        cards.removeAll { $0 === c }; cards.append(c)
        poke()
    }

    private func endDrag() {
        guard let c = dragging else { return }
        dragging = nil
        let d = rot(c.th, c.r0.x, c.r0.y)
        defer { dragSlot = nil; poke(); onChange?() }
        if bottle.hot {
            bottle.hot = false; c.stampPending = false
            startSink(c, duration: 0.42)
            let m = bottleMouth
            c.ctrl = CGPoint(x: m.x + (c.c.x - m.x) * 0.4, y: min(c.c.y, m.y) - 50)
            return
        }
        if dragSlot != nil {
            let targets = layoutTargets()
            for k in cards where k.mode == .hang { if let t = targets[k.id] { k.homeX = t } }
            let old = c.c
            let up = rot(c.th, 0, -c.h / 2)
            c.mode = .hang; c.sc = 1
            c.x = c.c.x + up.x; c.vx = 0; c.homeX = slotX ?? c.x
            c.r0 = CGPoint(x: 0, y: CLIP + c.h / 2)
            let r = ropeAt(c.x), nd = rot(c.th, c.r0.x, c.r0.y)
            c.piv = CGPoint(x: r.x, y: r.y)
            c.c = CGPoint(x: r.x + nd.x, y: r.y + nd.y)
            c.snap = CGPoint(x: old.x - c.c.x, y: old.y - c.c.y)
            c.p1 = nil; c.p2 = nil; c.pa = .zero
            return
        }
        c.mode = .free; c.sc = 1
        c.v = CGPoint(x: c.pv.x - c.om * d.y, y: c.pv.y + c.om * d.x)
        let sp = hypot2(c.v.x, c.v.y)
        // flung hard enough to leave the screen → ball it up
        let sx = c.c.x + c.v.x / (Tuning.friction * 0.6), sy = c.c.y + c.v.y / (Tuning.friction * 0.6)
        if sp > 1100 && (sx < -40 || sx > W + 40 || sy < -40 || sy > H + 40) { startCrumple(c); return }
        if sp > 2600 { c.v.x *= 2600 / sp; c.v.y *= 2600 / sp }
        c.th = atan2(sin(c.th), cos(c.th))
        c.rest = CGFloat.random(in: -0.07...0.07)
        c.om *= 0.5
    }

    // MARK: finishing

    private func startSink(_ c: Card, duration: CGFloat) {
        let cc = c.center
        if dragging === c { dragging = nil }
        c.mode = .sink; c.t = 0; c.dur = duration
        c.s0 = cc; c.c = cc; c.snap = .zero
        let m = bottleMouth
        c.th0 = c.th; c.spin = (cc.x > m.x ? -1 : 1) * CGFloat.random(in: 0.6...1.4)
        c.ctrl = CGPoint(x: cc.x + (m.x - cc.x) * 0.3, y: min(cc.y, m.y) - 70)
        zTop += 1; c.z = zTop
        poke()
    }

    private func startCrumple(_ c: Card) {
        let sp = max(1, hypot2(c.v.x, c.v.y))
        c.mode = .crumple; c.t = 0; c.stampPending = false; c.sc = 1
        let k = max(1, 1900 / sp); c.v.x *= k; c.v.y *= k
        c.spin = (c.v.x >= 0 ? 1 : -1) * CGFloat.random(in: 7...12)
        zTop += 1; c.z = zTop
        poke()
    }

    func stamp(_ c: Card) {
        c.stampAt = tWorld; c.stampDate = Date()
        c.stampPending = true; c.fallAt = tWorld + 1.15
        c.om += (Bool.random() ? -1 : 1) * Tuning.nudge * (c.mode == .hang ? 1 : 0.5)
        poke()
    }

    private func archive(_ c: Card, how: String) {
        cards.removeAll { $0 === c }
        if dragging === c { dragging = nil }
        c.doneAt = Date()
        finished.insert(c, at: 0)
        bottle.av += how == "bottle" ? 1.6 : 0.8
        toast = (c, tWorld + 4.5)
        poke()
        onChange?()
    }

    private func hang(_ c: Card, from: CGPoint, at spot: CGFloat? = nil) {
        let x = spot ?? widestGap(), r = ropeAt(x)
        c.mode = .hang; c.x = x; c.homeX = x; c.vx = 0
        c.r0 = CGPoint(x: 0, y: CLIP + CH / 2)
        c.th = CGFloat.random(in: -0.06...0.06); c.om = (Bool.random() ? -1 : 1) * Tuning.nudge
        c.piv = CGPoint(x: r.x, y: r.y); c.pa = .zero; c.p1 = nil; c.p2 = nil; c.sc = 1
        c.wasOnRope = false
        c.c = CGPoint(x: r.x, y: r.y + CLIP + CH / 2)
        c.snap = CGPoint(x: from.x - c.c.x, y: from.y - c.c.y)
        if !cards.contains(where: { $0 === c }) { cards.append(c) }
        poke()
    }

    func restore(_ c: Card) {
        finished.removeAll { $0 === c }
        if toast?.card === c { toast = nil }
        c.stampAt = nil; c.stampPending = false; c.doneAt = nil
        if ropeHidden { putOnDesk(c) } else { bottle.av -= 1.0; hang(c, from: bottleMouth) }
        onChange?()
    }

    /// The bottle empties itself each new day and on every launch.
    func clearFinished() {
        guard !finished.isEmpty else { return }
        finished.removeAll()
        if let t = toast, !cards.contains(where: { $0 === t.card }) { toast = nil }
        poke(); onChange?()
    }

    func deleteFinished(_ c: Card) {
        finished.removeAll { $0 === c }
        if toast?.card === c { toast = nil }
        poke(); onChange?()
    }

    @discardableResult
    func addNote(text: String = "新便签\n双击写点什么", edit: Bool = true) -> Card {
        let c = Card(text: text, style: cards.count + finished.count)
        if ropeHidden {
            putOnDesk(c)
        } else {
            hang(c, from: .zero)
            c.snap = CGPoint(x: 0, y: -260)
        }
        onChange?()
        if edit {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) { [weak self] in self?.onEdit?(c) }
        }
        return c
    }

    /// Hang shortcuts to files dropped from Finder, starting at the slot under the pointer.
    func dropFiles(_ urls: [URL], at p: CGPoint) {
        guard !ropeHidden, !urls.isEmpty else { return }
        let base = slotX ?? p.x
        let targets = layoutTargets()
        for k in cards where k.mode == .hang { if let t = targets[k.id] { k.homeX = t } }
        for (i, url) in urls.prefix(8).enumerated() {
            let info = FileShortcuts.classify(url)
            let c = Card(text: FileShortcuts.displayName(url, kind: info.kind), style: Int.random(in: 0..<journalStyles.count))
            c.kind = info.kind; c.url = url; c.itemCount = info.count
            c.bookmark = FileShortcuts.bookmark(url)
            hang(c, from: CGPoint(x: p.x + CGFloat(i) * 14, y: p.y + CGFloat(i) * 10), at: base + CGFloat(i) * GAP)
            onNeedThumbnail?(c)
        }
        externalDrag = false; dragSlot = nil
        poke(); onChange?()
    }

    /// Put a note from the desk back on the rope: its old spot if it had one, else the widest gap.
    func hangBack(_ c: Card) {
        guard !ropeHidden, c.mode == .free else { return }
        hang(c, from: c.center, at: c.homeX > 0 ? c.homeX : nil)
        onChange?()
    }

    /// Every note lying on the desk goes back on the rope.
    func hangAllBack() {
        if ropeHidden { setRopeHidden(false) }
        for c in cards where c.mode == .free {
            hang(c, from: c.center, at: c.homeX > 0 ? c.homeX : nil)
        }
        poke(); onChange?()
    }

    func showFlash(_ c: Card, _ text: String) {
        flash = (c, text, tWorld + 1.3)
        poke()
    }

    /// Hang shortcuts in the widest free spots (or lay them on the desk while the rope is hidden).
    func addFiles(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        for (i, url) in urls.prefix(8).enumerated() {
            let info = FileShortcuts.classify(url)
            let c = Card(text: FileShortcuts.displayName(url, kind: info.kind), style: Int.random(in: 0..<journalStyles.count))
            c.kind = info.kind; c.url = url; c.itemCount = info.count
            c.bookmark = FileShortcuts.bookmark(url)
            if ropeHidden {
                putOnDesk(c)
                c.c.x += CGFloat(i) * 24; c.c.y += CGFloat(i) * 18
            } else {
                hang(c, from: CGPoint(x: W - 60, y: -CH))      // drops in from the menu bar side
            }
            onNeedThumbnail?(c)
        }
        poke(); onChange?()
    }

    /// A note placed loosely on the desktop, somewhere near the upper middle.
    private func putOnDesk(_ c: Card) {
        c.mode = .free; c.sc = 1; c.snap = .zero; c.wasOnRope = false
        c.c = CGPoint(x: W / 2 + CGFloat.random(in: -140...140), y: H * 0.32 + CGFloat.random(in: -60...60))
        c.v = .zero
        c.rest = CGFloat.random(in: -0.07...0.07); c.th = c.rest + (Bool.random() ? 0.25 : -0.25); c.om = 0
        zTop += 1; c.z = zTop
        if !cards.contains(where: { $0 === c }) { cards.append(c) }
        poke()
    }

    /// Hide the rope: hanging notes drop gently onto the desk where they are.
    /// Show it again: those notes go back to their places on the rope.
    func setRopeHidden(_ hide: Bool) {
        guard hide != ropeHidden else { return }
        ropeHidden = hide
        if hide {
            bottle.hot = false; dragSlot = nil
            for c in cards where c.mode == .hang {
                let cc = c.center
                c.mode = .free; c.c = cc; c.snap = .zero; c.wasOnRope = true
                c.v = CGPoint(x: 0, y: CGFloat.random(in: 160...280))
                c.th = atan2(sin(c.th), cos(c.th))
                c.rest = CGFloat.random(in: -0.07...0.07)
            }
        } else {
            for c in cards where c.mode == .free && c.wasOnRope {
                hang(c, from: c.center, at: c.homeX)
            }
        }
        poke(); onChange?()
    }

    func edited(_ c: Card, text: String) {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        c.text = t.isEmpty ? "（空白）" : t
        c.om += Tuning.nudge * 0.5
        poke(); onChange?()
    }

    // MARK: persistence

    func book() -> Book {
        var b = Book()
        b.notes = cards.compactMap { c in
            switch c.mode {
            case .hang:
                return StoredNote(id: c.id, text: c.text, style: c.style, onRope: true, ropeX: Double(c.homeX / W),
                                  deskX: 0, deskY: 0, tilt: 0, stamped: c.stampAt != nil,
                                  kind: c.kind == .note ? nil : c.kind.rawValue, path: c.url?.path, bookmark: c.bookmark)
            case .free, .drag:
                return StoredNote(id: c.id, text: c.text, style: c.style, onRope: false, ropeX: Double(c.homeX / W),
                                  deskX: Double(c.c.x / W), deskY: Double(c.c.y / H), tilt: Double(c.rest), stamped: c.stampAt != nil,
                                  wasOnRope: c.wasOnRope,
                                  kind: c.kind == .note ? nil : c.kind.rawValue, path: c.url?.path, bookmark: c.bookmark)
            case .sink, .crumple:
                return nil   // about to be finished; saved with the finished list
            }
        }
        b.done = []   // the bottle starts empty after a restart
        return b
    }

    func load(_ b: Book) {
        cards = []; finished = []
        for n in b.notes {
            let c = Card(id: n.id, text: n.text, style: n.style)
            if n.stamped { c.stampAt = -10; c.stampDate = Date() }
            if let k = n.kind.flatMap(CardKind.init(rawValue:)), k != .note {
                c.kind = k; c.bookmark = n.bookmark
                c.url = n.path.map { URL(fileURLWithPath: $0) }
            }
            if n.onRope {
                let x = CGFloat(n.ropeX) * W
                c.mode = .hang; c.x = x; c.homeX = x
                let r = ropeAt(x)
                c.piv = CGPoint(x: r.x, y: r.y); c.c = CGPoint(x: r.x, y: r.y + CLIP + CH / 2)
                c.th = CGFloat.random(in: -0.04...0.04)
            } else {
                c.mode = .free
                c.c = CGPoint(x: clamp(CGFloat(n.deskX) * W, 40, W - 40), y: clamp(CGFloat(n.deskY) * H, 40, H - 40))
                c.rest = CGFloat(n.tilt); c.th = c.rest
                if n.wasOnRope == true { c.wasOnRope = true; c.homeX = CGFloat(n.ropeX) * W }
            }
            cards.append(c)
        }
        poke()
    }

    func seedWelcome() {
        let n = welcomeNotes.count
        let start = max(ropeLo, (W - CGFloat(n - 1) * GAP) / 2)
        for (i, t) in welcomeNotes.enumerated() {
            let c = Card(text: t, style: i)
            let x = start + CGFloat(i) * GAP
            c.mode = .hang; c.x = x; c.homeX = x
            let r = ropeAt(x)
            c.piv = CGPoint(x: r.x, y: r.y); c.c = CGPoint(x: r.x, y: r.y + CLIP + CH / 2)
            c.th = CGFloat.random(in: -0.04...0.04)
            cards.append(c)
        }
        poke()
    }
}
