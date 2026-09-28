public import Foundation

/// Maximum content column width for the markdown viewer.
///
/// The value is applied as CSS pixels to the rendered `.markdown-body`
/// `max-width`. The panel still uses full available width on narrower splits.
public enum MarkdownMaxWidthSettings {
    /// UserDefaults / cmux.json key (`markdown.maxWidth`).
    public static let key = "markdown.maxWidth"
    public static let defaultCSSPixels: Double = 980
    public static let minimumCSSPixels: Double = 320
    public static let maximumCSSPixels: Double = 2400
    public static let stepCSSPixels: Double = 20

    public static func clamp(_ value: Double) -> Double {
        min(max(value, minimumCSSPixels), maximumCSSPixels)
    }

    public static func resolvedDefault(defaults: UserDefaults = .standard) -> Double {
        guard let raw = defaults.object(forKey: key) as? NSNumber else {
            return defaultCSSPixels
        }
        return clamp(raw.doubleValue)
    }

    public static func setDefault(_ pixels: Double, defaults: UserDefaults = .standard) {
        defaults.set(Int(clamp(pixels).rounded()), forKey: key)
    }

    public static func resetDefault(defaults: UserDefaults = .standard) {
        defaults.removeObject(forKey: key)
    }
}
