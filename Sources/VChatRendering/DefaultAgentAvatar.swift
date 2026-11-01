import SwiftUI

/// The original VChat default avatar, shared by every native Agent surface.
public struct DefaultAgentAvatar: View {
    public init() {}
    public var body: some View {
        Image("default-agent",bundle: .module).resizable().scaledToFill().accessibilityHidden(true)
    }
}
