import Foundation

public enum PlaybackRate {
    public static let minimum = 0.5
    public static let maximum = 2.0
    public static let `default` = 1.0
    public static let step = 0.25

    public static func clamped(_ rate: Double) -> Double {
        let bounded = min(max(rate, minimum), maximum)
        return (bounded / step).rounded() * step
    }
}
