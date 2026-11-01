import SwiftUI
#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// The original VChat default avatar, shared by every native Agent surface.
public struct DefaultAgentAvatar: View {
    public init() {}
    public var body: some View {
        image.resizable().scaledToFill().accessibilityHidden(true)
    }
    private var image: Image {
        guard let url = Bundle.module.url(forResource: "default-agent",withExtension: "png") else { return Image(systemName: "person.crop.circle") }
        #if os(macOS)
        guard let image = NSImage(contentsOf: url) else { return Image(systemName: "person.crop.circle") }
        return Image(nsImage: image)
        #else
        guard let image = UIImage(contentsOfFile: url.path) else { return Image(systemName: "person.crop.circle") }
        return Image(uiImage: image)
        #endif
    }
}
