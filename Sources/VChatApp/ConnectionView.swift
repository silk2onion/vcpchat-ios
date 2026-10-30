import SwiftUI
import VChatCore
import UniformTypeIdentifiers
struct ConnectionView: View {
    @Bindable var model: ChatViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var importing = false
    @State private var choosingModel = false
    @State private var fetching = false
    @State private var query = ""
    var body: some View {
        NavigationStack {
            Form {
                if let error = model.error { Section { Label(error, systemImage: "exclamationmark.circle").foregroundStyle(.red) } }
                if model.savingConnection { Section { ProgressView(model.credentialsInMemory ? "正在应用本次连接…" : "正在保存到系统钥匙串…") } }
                Section {
                    Button("导入桌面 VCPChat 连接…", systemImage: "square.and.arrow.down") { importing = true }.disabled(model.credentialsInMemory)
                    Text(model.credentialsInMemory ? "会话模式：连接密钥只保留到退出 App，不访问系统钥匙串。" : "只读取服务器和连接密钥，保存到本机钥匙串。不会改动旧配置和会话。").font(.caption).foregroundStyle(.secondary)
                }
                if model.credentialsLocked {
                    Section {
                        Button(model.unlockingCredentials ? "正在等待系统确认…" : "解锁已有连接", systemImage: "lock.open") { Task { await model.loadCredentials(allowInteraction: true) } }.disabled(model.unlockingCredentials)
                        Text("启动时不会弹出密码框；只有主动解锁才请求系统授权。").font(.caption).foregroundStyle(.secondary)
                    }
                }
                Section("VCP 服务器") {
                    TextField("https://agent.sijinworld.com", text: $model.configuration.server)
                    SecureField("聊天 API Key", text: $model.apiKey)
                    Picker("接口模式", selection: $model.configuration.endpointMode) { ForEach(EndpointMode.allCases, id: \.self) { Text($0.title).tag($0) } }
                    TextField("模型 ID", text: $model.configuration.model)
                    Toggle("发送 Temperature", isOn: $model.configuration.sendTemperature)
                    if model.configuration.sendTemperature { LabeledContent("Temperature", value: model.configuration.temperature.formatted(.number.precision(.fractionLength(2)))); Slider(value: $model.configuration.temperature, in: 0...2) }
                    Button(fetching ? "正在读取…" : "鉴权并读取模型") { fetching = true; Task { await model.refreshModels(); fetching = false } }.disabled(fetching)
                    Button("选择模型 · \(model.models.count) 个", systemImage: "list.bullet") { choosingModel = true }
                }
                Section("实时推送") {
                    SecureField("VCPLog Key（与聊天 Key 分开）", text: $model.logKey)
                    Button("连接 WebSocket") { model.connectPush() }
                    LabeledContent("状态", value: model.pushStatus)
                }
                Section("流式显示") {
                    Picker("流式刷新率", selection: $model.configuration.framesPerSecond) { Text("标准 · 60 Hz").tag(60); Text("高刷新率 · 120 Hz").tag(120) }

                }
            }
            .sheet(isPresented: $choosingModel) { ModelPicker(model: model, selection: $model.configuration.model) }
            .onChange(of: model.configuration.server) { _, _ in Task { await model.loadCatalog() } }
            .fileImporter(isPresented: $importing, allowedContentTypes: [.json]) { result in
                switch result {
                case .success(let url): Task { await model.importConnection(from: url) }
                case .failure: break
                }
            }
            .formStyle(.grouped)
            .navigationTitle("连接设置")
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("关闭") { dismiss() } }; ToolbarItem(placement: .confirmationAction) { Button(model.savingConnection ? "保存中…" : "保存") { Task { if await model.saveConnection() { dismiss() } } }.disabled(model.savingConnection) } }
        }.frame(minWidth: 350, minHeight: 560)
    }
}
