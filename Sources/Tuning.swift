import CoreGraphics

/// Hand-feel parameters, tuned in the browser prototype.
/// Change values here and rebuild to adjust the feel.
enum Tuning {
    // Rope
    static let slack: CGFloat = 0          // extra rope length vs. span (0 = taut)
    static let stiff: CGFloat = 0.96       // 0…1, lower = stretchier
    static let ropeDamp: CGFloat = 0.06    // per-substep velocity loss
    // Notes
    static let gravity: CGFloat = 400      // px/s², sets swing speed
    static let cardMass: CGFloat = 1.5     // weight relative to one rope node
    static let swingDamp: CGFloat = 7.5    // how fast a swing settles (higher = calmer)
    static let coupling: CGFloat = 0.1     // how much swinging tugs the rope
    // Hand
    static let follow: CGFloat = 24        // drag spring; lower = laggier
    static let dragSway: CGFloat = 0.45    // how much a fast drag swings the note (1 = full pendulum)
    static let dragMaxTilt: CGFloat = 0.3  // a dragged note never turns further than this, rad (~17°)
    static let brush: CGFloat = 0.05       // brushing past a hanging note (kept subtle)
    static let brushCap: CGFloat = 0.06    // max swing speed a brush can add, rad/s
    static let nudge: CGFloat = 0.2        // swing from a click, a new note, a stamp
    static let maxTilt: CGFloat = 0.14     // a hanging note never tilts further than this, rad (~8°)
    static let friction: CGFloat = 4       // sliding on the desk
}
