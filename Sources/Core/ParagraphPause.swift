public enum ParagraphPause {
    public static let `default` = 0.05
    public static let minimum = 0.0
    public static let maximum = 0.25
    public static let step = 0.025

    public static func clamped(_ seconds: Double) -> Double {
        let bounded = min(max(seconds, minimum), maximum)
        let stepMilliseconds = (step * 1_000).rounded()
        let milliseconds = (bounded * 1_000 / stepMilliseconds).rounded() * stepMilliseconds
        return milliseconds / 1_000
    }
}
