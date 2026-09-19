public import Foundation

/// Resolves Markdown file links relative to the Markdown document that contains them.
public struct MarkdownPanelFileLinkResolver: Sendable {
    private static let markdownExtensions: Set<String> = ["md", "markdown", "mkd", "mdx"]

    public init() {}

    /// Returns whether a path has a Markdown extension.
    public func isMarkdownPathLike(_ path: String) -> Bool {
        Self.markdownExtensions.contains(URL(fileURLWithPath: path).pathExtension.lowercased())
    }

    /// Resolves a relative Markdown link to an existing regular file.
    public func resolve(rawPath: String, relativeToMarkdownFile filePath: String) -> String? {
        let base = URL(fileURLWithPath: filePath).deletingLastPathComponent()
        let candidate = URL(fileURLWithPath: rawPath, relativeTo: base).standardizedFileURL.path
        guard isMarkdownPathLike(candidate), FileManager.default.fileExists(atPath: candidate) else { return nil }
        var isDirectory = ObjCBool(false)
        guard !FileManager.default.fileExists(atPath: candidate, isDirectory: &isDirectory), !isDirectory.boolValue else { return nil }
        return candidate
    }
}
