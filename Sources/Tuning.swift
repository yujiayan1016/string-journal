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
    static let swingDamp: CGFloat = 4.7    // how fast a swing settles
    static let coupling: CGFloat = 0.18    // how much swinging tugs the rope
    // Hand
    static let follow: CGFloat = 24        // drag spring; lower = laggier
    static let pluck: CGFloat = 1          // strumming the rope
    static let brush: CGFloat = 1          // brushing past a hanging note
    static let friction: CGFloat = 4       // sliding on the desk
}
