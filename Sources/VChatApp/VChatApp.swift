import SwiftUI
#if os(macOS)
import AppKit
#else
import UIKit
#endif

@main struct VChatApp: App {
    #if os(iOS)
    @UIApplicationDelegateAdaptor(ReplyAppDelegate.self) private var delegate
    private var model: ChatViewModel { delegate.model }
    #else
    @State private var model = ChatViewModel(coordinator: .shared)
    #endif
    @State private var lifetime = BackgroundLifetime()
    @Environment(\.scenePhase) private var phase
    #if os(iOS)
    init() {
        // Pad native indicator artwork, not the navigation stack or a replacement
        // button: system hit testing and interactive one-level pop stay in charge.
        let configuration = UIImage.SymbolConfiguration(pointSize: 20,weight: .medium)
        if let glyph = UIImage(systemName: "chevron.backward",withConfiguration: configuration) {
            let inset: CGFloat = 8
            let size = CGSize(width: glyph.size.width + inset,height: glyph.size.height)
            let indicator = UIGraphicsImageRenderer(size: size).image { _ in
                glyph.draw(at: CGPoint(x: inset,y: 0))
            }.withRenderingMode(.alwaysTemplate).imageFlippedForRightToLeftLayoutDirection()
            let navigationBar = UINavigationBar.appearance()
            navigationBar.backIndicatorImage = indicator
            navigationBar.backIndicatorTransitionMaskImage = indicator
        }
    }
    #endif
    var body: some Scene {
        WindowGroup {
            WorkspaceView(model: model)
                #if os(iOS)
                .onOpenURL { if let topic = ReplyActivityAttributes.topic(in: $0) { model.requestedReplyTopic = topic } }
                #endif
                .task { model.locationForeground(phase == .active); if model.loading { await model.load() } }
                .onChange(of: phase, initial: true) { _, next in
                    if next != .inactive { model.locationForeground(next == .active) }
                    lifetime.transition(next,model: model)
                }
                .frame(minWidth: 340, minHeight: 520)
                #if os(macOS)
                .onAppear { NSApp.setActivationPolicy(.regular); NSApp.activate(ignoringOtherApps: true) }
                #endif
        }
        #if os(macOS)
        .defaultSize(width: 430, height: 820)
        #endif
    }
}
