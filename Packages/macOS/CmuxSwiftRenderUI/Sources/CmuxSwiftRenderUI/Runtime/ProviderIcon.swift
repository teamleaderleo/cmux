import AppKit
import SwiftUI

/// Provider artwork shared with cmux's mobile shell.
public struct ProviderIcon: View {
    public let provider: String
    @Environment(\.colorScheme) private var scheme
    public init(_ provider: String) { self.provider = provider }
    public static func menuImage(_ provider: String) -> NSImage? {
        guard let url = Bundle.module.url(forResource: provider, withExtension: "png"),
              let image = NSImage(contentsOf: url) else { return nil }
        image.size = NSSize(width: 16, height: 16)
        return image
    }
    public var body: some View {
        let name = provider == "Codex" && scheme == .dark ? "Codex-dark" : provider
        if let url = Bundle.module.url(forResource: name, withExtension: "png"),
           let image = NSImage(contentsOf: url) {
            Image(nsImage: image).resizable().scaledToFit().accessibilityLabel(provider)
        }
    }
}
