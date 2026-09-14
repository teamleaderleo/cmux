import AppKit
import SwiftUI

/// Provider artwork shared with cmux's mobile shell.
public struct ProviderIcon: View {
    public let provider: String
    @Environment(\.colorScheme) private var scheme
    public init(_ provider: String) { self.provider = provider }
    @MainActor private static let artwork: [String: NSImage] = {
        var result: [String: NSImage] = [:]
        for name in ["Claude", "Codex", "Codex-dark", "OpenCode"] {
            if let url = Bundle.module.url(forResource: name, withExtension: "png"),
               let image = NSImage(contentsOf: url) { result[name] = image }
        }
        return result
    }()
    @MainActor public static func menuImage(_ provider: String) -> NSImage? {
        guard let image = artwork[provider]?.copy() as? NSImage else { return nil }
        image.size = NSSize(width: 16, height: 16)
        image.isTemplate = provider != "OpenCode"
        return image
    }
    public var body: some View {
        let name = provider == "Codex" && scheme == .dark ? "Codex-dark" : provider
        if let image = Self.artwork[name] {
            Image(nsImage: image)
                .renderingMode(provider == "OpenCode" ? .original : .template)
                .resizable().scaledToFit().foregroundStyle(Color.primary.opacity(0.9)).accessibilityLabel(provider)
        }
    }
}
