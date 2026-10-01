import Foundation

/// Normalized binocular gaze: deliberate fixations joined by short saccades.
/// No random per-frame jitter; sampling is deterministic at any frame rate.
public struct DennyEyeMotionFrame: Equatable {
    public var x: Double = 0
    public var y: Double = 0
    public var blink: Double = 0
    public var isMoving: Bool = false
}

public enum DennyEyeMotion {
    private struct Fixation {
        let at: Double
        let x: Double
        let y: Double
        let travel: Double
    }
    private static let sequence: [Fixation] = [
        .init(at: 0, x: 0, y: 0, travel: 0.2),
        .init(at: 1.8, x: -0.72, y: 0.48, travel: 0.18),
        .init(at: 3.6, x: -0.57, y: 0.61, travel: 0.12),
        .init(at: 5.1, x: 0.64, y: -0.16, travel: 0.21),
        .init(at: 7.4, x: 0.18, y: 0.12, travel: 0.16),
        .init(at: 9.6, x: 0, y: -0.58, travel: 0.19),
        .init(at: 11.4, x: -0.38, y: 0.2, travel: 0.18),
        .init(at: 13.4, x: 0, y: 0, travel: 0.2)
    ]

    public static func frame(at time: Double, reduceMotion: Bool = false) -> DennyEyeMotionFrame {
        guard !reduceMotion, time.isFinite else { return .init() }
        let t = (time.truncatingRemainder(dividingBy: 16) + 16).truncatingRemainder(dividingBy: 16)
        var result = DennyEyeMotionFrame()
        var previous = sequence[0]
        for target in sequence.dropFirst() {
            if t < target.at { break }
            let u = min(1, max(0, (t - target.at) / target.travel))
            // Minimum-jerk trajectory, then a stable fixation.
            let p = u * u * u * (10 + u * (-15 + 6 * u))
            result.x = previous.x + (target.x - previous.x) * p
            result.y = previous.y + (target.y - previous.y) * p
            previous = target
        }
        result.isMoving = sequence.dropFirst().contains { t >= $0.at - 0.15 && t < $0.at + $0.travel + 0.1 }
        for start in [1.69, 5.01, 8.72, 8.99, 13.31] {
            let b = t - start
            guard b >= 0, b < 0.24 else { continue }
            // Fast closing lid, slower reopening. The pupil never flattens.
            result.blink = b < 0.075 ? smooth(b / 0.075) : 1 - smooth((b - 0.075) / 0.165)
        }
        result.isMoving = result.isMoving || [1.69, 5.01, 8.72, 8.99, 13.31].contains { t >= $0 - 0.15 && t < $0 + 0.3 }
        return result
    }

    private static func smooth(_ x: Double) -> Double { x * x * (3 - 2 * x) }
}
