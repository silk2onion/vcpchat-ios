import SwiftUI

private struct MessageTextSelectionKey: EnvironmentKey {
    static let defaultValue = true
}
private struct MessageLongPressKey: EnvironmentKey {
    static let defaultValue: (@MainActor @Sendable () -> Void)? = nil
}
extension EnvironmentValues {
    public var messageTextSelectionEnabled: Bool {
        get { self[MessageTextSelectionKey.self] }
        set { self[MessageTextSelectionKey.self] = newValue }
    }
    public var messageLongPressAction: (@MainActor @Sendable () -> Void)? {
        get { self[MessageLongPressKey.self] }
        set { self[MessageLongPressKey.self] = newValue }
    }
}

/// Chat bubbles reserve long-press for message actions; standalone readers keep text selection.
struct MessageTextSelection: ViewModifier {
    @Environment(\.messageTextSelectionEnabled) private var enabled
    @ViewBuilder func body(content: Content) -> some View {
        if enabled { content.textSelection(.enabled) }
        else { content.textSelection(.disabled) }
    }
}
