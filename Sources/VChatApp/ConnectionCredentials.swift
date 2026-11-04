import Foundation
import VChatCore

extension ChatViewModel {
    /// Startup and foreground restoration are silent; only the unlock button allows system UI.
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
        await restoreRequestedConnections()
    }
}

extension ChatViewModel {
    /// User intent is durable; sockets and credentials in memory are not.
    func saveAndConnectPush() async {
        guard !connectingPush else { return }
        connectingPush = true
        defer { connectingPush = false }
        let server = services.logServer.isEmpty ? configuration.server : services.logServer
        do {
            for channel in PushChannel.allCases { _ = try SocketEndpoint.url(server: server,key: logKey,channel: channel) }
        } catch { self.error = error.localizedDescription; return }
        let previous = services.logsEnabled
        services.logsEnabled = true
        guard await saveConnection() else { services.logsEnabled = previous; return }
        guard !backgrounded else { activity.showInactiveStatus("后台暂停"); return }
        activity.error = nil
        await activity.connect(server: server,key: logKey,secrets: [apiKey,logKey] + Array(serviceSecrets.values))
    }

    /// Notification-center refresh uses cached keys, without another Keychain write.
    func reconnectPush() async {
        guard !credentialsLocked else { activity.error = "请在连接设置中解锁已有连接"; return }
        let server = services.logServer.isEmpty ? configuration.server : services.logServer
        do {
            guard let store else { throw ClientError.server("本机数据尚未就绪") }
            for channel in PushChannel.allCases { _ = try SocketEndpoint.url(server: server,key: logKey,channel: channel) }
            var enabled = services; enabled.logsEnabled = true
            try await store.put(enabled,kind: "services",id: "settings")
            services.logsEnabled = true; activity.error = nil
            guard !backgrounded else { activity.showInactiveStatus("后台暂停"); return }
            await activity.connect(server: server,key: logKey,secrets: [apiKey,logKey] + Array(serviceSecrets.values))
        } catch { activity.error = error.localizedDescription }
    }

    func disconnectPush() async {
        var disabled = services; disabled.logsEnabled = false
        do {
            guard let store else { throw ClientError.server("本机数据尚未就绪") }
            try await store.put(disabled,kind: "services",id: "settings")
            services.logsEnabled = false
            await activity.disconnect(); activity.error = nil
        } catch { activity.error = error.localizedDescription }
    }

    func disconnectMobileTools() async {
        var disabled = services; disabled.fileNode.enabled = false
        do {
            guard let store else { throw ClientError.server("本机数据尚未就绪") }
            try await store.put(disabled,kind: "services",id: "settings")
            services.fileNode.enabled = false
            await fileNode.stop()
        } catch { self.error = error.localizedDescription }
    }

    /// Uses credentials already restored in memory; preserves explicit stop/disconnect choices.
    func restoreRequestedConnections() async {
        guard store != nil, !backgrounded, !restoringConnections else { return }
        restoringConnections = true
        defer { restoringConnections = false }
        if services.logsEnabled {
            if credentialsLocked { activity.showInactiveStatus("待解锁连接") }
            else if logKey.isEmpty { activity.showInactiveStatus("请配置 VCPLog Key") }
            else {
                let server = services.logServer.isEmpty ? configuration.server : services.logServer
                await activity.connect(server: server,key: logKey,secrets: [apiKey,logKey] + Array(serviceSecrets.values))
            }
        }
        guard !backgrounded else { return }
        if services.fileNode.enabled {
            if credentialsLocked { fileNode.status = "待解锁连接" }
            else if (serviceSecrets[.fileNodeKey] ?? "").isEmpty { fileNode.status = "请配置分布式 Key" }
            else { await connectMobileTools(persist: false) }
        }
    }
}
