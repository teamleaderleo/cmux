import Foundation

/// A Claude Desktop profile name that is safe to use as a directory component.
///
/// Each profile is one Electron `--user-data-dir`, so it keeps its own
/// sign-in. User-supplied names are lowercased, characters outside
/// alphanumerics and `-_.` become `-`, and leading or trailing `-`/`.` are
/// trimmed. An empty result becomes `default`.
///
/// ```swift
/// ClaudeDesktopProfileName("../Personal Acct").rawValue // "personal-acct"
/// ```
public struct ClaudeDesktopProfileName: Hashable, Sendable, CustomStringConvertible {
    /// The profile used when a panel names none.
    public static let fallback = "default"

    /// The normalized name.
    public let rawValue: String

    /// Normalizes a user-supplied profile name.
    ///
    /// - Parameter raw: The name as typed, or `nil` for the default profile.
    public init(_ raw: String?) {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_."))
        let cleaned = String((raw ?? "").lowercased().unicodeScalars.map {
            allowed.contains($0) ? Character($0) : "-"
        }).trimmingCharacters(in: CharacterSet(charactersIn: "-."))
        rawValue = cleaned.isEmpty ? Self.fallback : cleaned
    }

    /// Whether `name` is already normalized.
    ///
    /// - Parameter name: A candidate profile name, such as a directory name.
    /// - Returns: `true` when normalizing `name` leaves it unchanged.
    public static func isNormalized(_ name: String) -> Bool {
        ClaudeDesktopProfileName(name).rawValue == name
    }

    public var description: String { rawValue }
}
