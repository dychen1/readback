import Foundation

/// Cleans a name that a client sends, such as an agent host name, before ReadBack saves or
/// shows it.
public enum UntrustedLabel {
    /// Removes control characters, invisible format characters such as bidirectional
    /// overrides, and line separators. Then removes spaces at each end and keeps at most
    /// `maximumLength` Unicode scalars. The cap counts scalars, not characters, because one
    /// character can hold any number of combining marks.
    public static func clean(_ value: String, maximumLength: Int) -> String {
        let visible = value.unicodeScalars.filter { scalar in
            switch scalar.properties.generalCategory {
            case .control, .format, .lineSeparator, .paragraphSeparator: false
            default: true
            }
        }
        let trimmed = String(String.UnicodeScalarView(visible))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return String(String.UnicodeScalarView(trimmed.unicodeScalars.prefix(maximumLength)))
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
