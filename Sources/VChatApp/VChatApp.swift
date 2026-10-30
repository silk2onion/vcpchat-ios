import SwiftUI
#if os(macOS)
import AppKit
#endif

@main struct VChatApp: App {
    @State private var model = ChatViewModel()
    @Environment(\.scenePhase) private var phase
    var body: some Scene {
        WindowGroup {
            WorkspaceView(model: model)
                .task { if model.loading { await model.load() } }
                .onChange(of: phase) { _, next in
                    if next == .background { Task { await model.suspend() } }
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
