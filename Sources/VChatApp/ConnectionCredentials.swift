import Foundation
import VChatCore

extension ChatViewModel {
    /// Startup only reads items already authorized for this signed app.
    /// The interactive path is entered only by the user's explicit unlock action.
    func loadCredentials(allowInteraction: Bool) async {
        guard !unlockingCredentials else { return }
        unlockingCredentials = true
        defer { unlockingCredentials = false }
        var locked = false
        let previousChat = apiKey, previousLog = logKey
        do {
            let value = try await vault.read("chat-api-key", allowingInteraction: allowInteraction)
            if apiKey == previousChat { apiKey = value }
        } catch CredentialVault.AccessError.authorizationRequired { locked = true }
        catch { locked = true; if allowInteraction { self.error = error.localizedDescription } }
        do {
            let value = try await vault.read("vcp-log-key", allowingInteraction: allowInteraction)
            if logKey == previousLog { logKey = value }
        } catch CredentialVault.AccessError.authorizationRequired { locked = true }
        catch { locked = true; if allowInteraction { self.error = error.localizedDescription } }
        credentialsLocked = locked
    }
}
