public enum ParagraphPause {
    public static let `default` = 0.5
    public static let minimum = 0.0
    public static let maximum = 2.0
    public static let presets = [0.0, 0.25, 0.5, 0.75, 1.0, 1.5, 2.0]

    public static func clamped(_ seconds: Double) -> Double {
        min(max(seconds, minimum), maximum)
    }
}
