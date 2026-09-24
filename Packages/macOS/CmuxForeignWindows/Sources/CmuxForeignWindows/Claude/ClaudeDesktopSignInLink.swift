public import Foundation

/// A `claude://` link that finishes a Claude Desktop sign-in.
///
/// Two shapes are accepted, and nothing else:
/// - `claude://login/<path>`: the OAuth callback the browser opens after
///   Google sign-in, for example `claude://login/google-auth?code=…&hop_nonce=…`.
///   Claude rejects it unless the receiving instance issued the nonce.
/// - `claude://claude.ai/magic-link…` or `claude://claude.ai/login…`: the
///   email sign-in link. It carries no nonce, so it must only reach the
///   instance the user meant.
///
/// Other `claude://` links (`claude://claude.ai/new`, deep links into chats)
/// are refused, so a pasted link can never drive a pane anywhere but sign-in.
///
/// ```swift
/// switch ClaudeDesktopSignInLink.parse(NSPasteboard.general.string(forType: .string) ?? "") {
/// case .success(let link): deliver(link.url)
/// case .failure: showNotASignInLink()
/// }
/// ```
public struct ClaudeDesktopSignInLink: Equatable, Sendable {
    /// Which sign-in flow the link completes.
    public enum Kind: Equatable, Sendable {
        /// `claude://login/…`, an OAuth callback bound to a nonce.
        case oauthCallback
        /// `claude://claude.ai/magic-link…` or `claude://claude.ai/login…`.
        case magicLink
    }

    /// Why text was not accepted as a sign-in link.
    public enum Rejection: Error, Equatable, Sendable {
        /// Nothing but whitespace.
        case empty
        /// Not a well-formed URL, or longer than any real sign-in link.
        case malformed
        /// A URL whose scheme is not `claude`.
        case wrongScheme
        /// A `claude://` URL that does not finish a sign-in.
        case notSignIn
    }

    /// Longer input is refused outright; real sign-in links are well under it.
    static let maximumLength = 8192

    /// The link to deliver, exactly as parsed.
    public let url: URL
    /// Which sign-in flow ``url`` completes.
    public let kind: Kind

    /// Validates `text` as a sign-in link after trimming surrounding whitespace.
    ///
    /// - Parameter text: Typically the general pasteboard's string.
    /// - Returns: The link, or why it was refused.
    public static func parse(_ text: String) -> Result<ClaudeDesktopSignInLink, Rejection> {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .failure(.empty) }
        guard trimmed.utf8.count <= maximumLength,
              !trimmed.unicodeScalars.contains(where: {
                  CharacterSet.whitespacesAndNewlines.contains($0)
                      || CharacterSet.controlCharacters.contains($0)
              }),
              let components = URLComponents(string: trimmed),
              let scheme = components.scheme,
              let url = components.url else {
            return .failure(.malformed)
        }
        guard scheme.lowercased() == ClaudeDesktopLinkRouter.scheme else {
            return .failure(.wrongScheme)
        }
        // A sign-in link never carries credentials or a port.
        guard components.user == nil,
              components.password == nil,
              components.port == nil,
              let host = components.host?.lowercased() else {
            return .failure(.notSignIn)
        }
        let pathComponents = components.path
            .split(separator: "/", omittingEmptySubsequences: true)
            .map { $0.lowercased() }
        let firstPathComponent = pathComponents.first ?? ""
        switch host {
        case "login" where !pathComponents.isEmpty:
            return .success(ClaudeDesktopSignInLink(url: url, kind: .oauthCallback))
        case "claude.ai" where ["magic-link", "login"].contains(firstPathComponent):
            return .success(ClaudeDesktopSignInLink(url: url, kind: .magicLink))
        default:
            return .failure(.notSignIn)
        }
    }
}
