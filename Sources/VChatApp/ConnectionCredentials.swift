import Foundation
import VChatCore

extension ChatViewModel {
    /// Loading saved credentials is exclusively an explicit user action.
    /// Session-only stores never call the system Keychain.
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
        for name in ServiceSecret.allCases {
            do { serviceSecrets[name] = try await vault.read(name.rawValue, allowingInteraction: allowInteraction) }
            catch { locked = true; if allowInteraction { self.error = error.localizedDescription } }
        }
        credentialsLocked = locked
    }
}
