import SwiftUI
import Observation
import VChatCore
@MainActor @Observable final class FileNodeController {
    var status = "未连接"
    var active = false
    @ObservationIgnored private var node: MobileFileNode?
    @ObservationIgnored private var task: Task<Void,Never>?
    func start(settings: FileNodeSettings,key: String,folders: ConnectedFolders) async {
        await stop(); active = true; let node = MobileFileNode(folders: folders); self.node = node
        do { let updates = try await node.start(settings,key: key); task = Task { for await value in updates { if Task.isCancelled { return }; status = value } } }
        catch { active = false; status = error.localizedDescription }
    }
    func pause() async { await node?.stop(); task?.cancel(); task = nil; status = "后台暂停" }
    func stop() async { active = false; await node?.stop(); task?.cancel(); task = nil; status = "未连接" }
}
struct FileNodeView: View {
    @Bindable var model: ChatViewModel
    @State private var error: String?
    var body: some View {
        Form {
            Section("移动版 FileOperator") {
                Text("向 VCP 发布本设备的文件操作能力。Agent 只能操作你在“连接文件夹”中单独授权的目录，默认不授权任何目录。").font(.callout).foregroundStyle(.secondary)
                TextField("VCP 分布式服务地址",text: $model.services.fileNode.server)
                SecureField("分布式 Key",text: Binding(get: { model.serviceSecrets[.fileNodeKey] ?? "" },set: { model.serviceSecrets[.fileNodeKey] = $0 }))
                TextField("设备名称",text: $model.services.fileNode.name)
                LabeledContent("状态",value: model.fileNode.status)
                Button(model.fileNode.active ? "重新连接" : "连接并发布工具") { Task { guard let folders = model.connectedFolders else { return }; model.services.fileNode.enabled = true; if await model.saveServices() { await model.fileNode.start(settings: model.services.fileNode,key: model.serviceSecrets[.fileNodeKey] ?? "",folders: folders) } else { error = model.error } } }
                Button("停止发布") { Task { model.services.fileNode.enabled = false; await model.fileNode.stop(); _ = await model.saveServices() } }.disabled(!model.fileNode.active)
                Text("iPhone 退到后台时暂停节点；回到前台可重新连接。持续运行的节点适合放在 Mac 或服务器。").font(.caption).foregroundStyle(.secondary)
            }
            if let error { Text(error).foregroundStyle(.red) }
        }.formStyle(.grouped).navigationTitle("移动文件节点")
    }
}
