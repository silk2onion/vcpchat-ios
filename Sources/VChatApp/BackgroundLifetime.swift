import SwiftUI
#if os(iOS)
import UIKit
#endif
/// One owner for the OS lease, deadline and foreground transition.
@MainActor final class BackgroundLifetime {
    private let grace: Duration
    private var background = false
    private var generation = UUID()
    private var preparation: Task<Void,Never>?
    private var expiry: Task<Void,Never>?
    private var expiring = false
    #if os(iOS)
    private var token = UIBackgroundTaskIdentifier.invalid
    #endif
    init(grace: Duration = .seconds(25)) { self.grace = grace }
    func transition(_ phase: ScenePhase,model: ChatViewModel) {
        if phase == .background {
            guard !background else { return }; background = true; expiring = false; generation = UUID(); let own = generation
            #if os(iOS)
            if model.rooms.values.contains(where: { $0.busy }) {
                token = UIApplication.shared.beginBackgroundTask(withName: "保存进行中的回复") { [weak self,weak model] in Task { @MainActor in if let model { self?.expire(own,model: model) } } }
            }
            #endif
            preparation = Task {
                await model.enterBackground()
                guard !Task.isCancelled,generation == own,background else { return }
                guard model.rooms.values.contains(where: { $0.busy }) else { endLease(); return }
                #if os(iOS)
                if token == .invalid { expire(own,model: model); return }
                #endif
                do { try await Task.sleep(for: grace) } catch { return }
                expire(own,model: model)
            }
        } else if phase == .active && background {
            background = false; generation = UUID(); let own = generation
            let previous = preparation, saving = expiry; previous?.cancel(); preparation = nil; endLease()
            Task { await previous?.value; await saving?.value; guard generation == own,!background else { return }; await model.enterForeground() }
        }
    }
    private func expire(_ own: UUID,model: ChatViewModel) {
        guard background,generation == own,!expiring else { return }; expiring = true
        expiry = Task {
            await model.interruptForBackground()
            if generation == own { endLease() }
        }
    }
    private func endLease() {
        #if os(iOS)
        guard token != .invalid else { return }; let value = token; token = .invalid; UIApplication.shared.endBackgroundTask(value)
        #endif
    }
}
