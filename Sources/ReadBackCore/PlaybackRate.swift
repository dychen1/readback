import Foundation

public enum PlaybackRate {
    public static let minimum = 0.5
    public static let maximum = 2.0
    public static let `default` = 1.0
    public static let presets = [0.5, 0.75, 1.0, 1.25, 1.5, 1.75, 2.0]

    public static func clamped(_ rate: Double) -> Double {
        min(max(rate, minimum), maximum)
    }
}
