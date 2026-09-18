import SwiftUI

/// Native host adapter for dragging a conversation through the host's pane transfer system.
public struct ConversationDragAdapter: Sendable {
    public let overlay: @MainActor (String, String, String, String, @escaping @MainActor () -> Void) -> AnyView
    public init(overlay: @escaping @MainActor (String, String, String, String, @escaping @MainActor () -> Void) -> AnyView) {
        self.overlay = overlay
    }
}

private struct ConversationDragAdapterKey: EnvironmentKey {
    static let defaultValue: ConversationDragAdapter? = nil
}

extension EnvironmentValues {
    public var conversationDragAdapter: ConversationDragAdapter? {
        get { self[ConversationDragAdapterKey.self] }
        set { self[ConversationDragAdapterKey.self] = newValue }
    }
}

