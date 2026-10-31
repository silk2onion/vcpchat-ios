import SwiftUI
import VChatCore
import VChatRendering
import UniformTypeIdentifiers

struct ConnectionView: View {
    @Bindable var model: ChatViewModel
    var embedded = false
    var focusLogs = false
    @Environment(\.dismiss) private var dismiss
    @State private var importing = false
    @State private var fetching = false
    @State private var showKey = false
    @State private var management = false
    private var palette: WorkspacePalette { .init(theme: model.appearance.theme) }
    var body: some View { Group { if embedded { content } else { NavigationStack { content } } }.frame(minWidth: 350,minHeight: 560) }
    private var content: some View {
        VStack(spacing: 0) {
            WorkspaceDetailHeader(title: focusLogs ? "日志通道" : "服务器与模型",palette: palette,note: "本机保存",back: { dismiss() }) { EmptyView() }
            ScrollView {
                VStack(alignment: .leading,spacing: 22) {
                    if let error = model.error { Text(error).font(.system(size: 14)).foregroundStyle(.red).textSelection(.enabled) }
                    if model.savingConnection { ProgressView(model.credentialsInMemory ? "正在应用本次连接…" : "正在保存到系统钥匙串…") }
                    if model.credentialsLocked {
                        Button(model.unlockingCredentials ? "正在等待系统确认…" : "解锁已有连接") { Task { await model.loadCredentials(allowInteraction: true) } }.workspaceAction(palette).disabled(model.unlockingCredentials)
                    }
                    if !focusLogs {
                        VStack(alignment: .leading,spacing: 20) {
                            WorkspaceField(title: "VCP 服务器 URL",palette: palette) { TextField("https://agent.sijinworld.com",text: $model.configuration.server).autocorrectionDisabled().accessibilityLabel("VCP 服务器 URL") }
                            Text("可填写主机地址，或完整的 API 路径。").font(.system(size: 13)).foregroundStyle(palette.muted)
                            WorkspaceField(title: "API Key",palette: palette) { if showKey { TextField("聊天 API Key",text: $model.apiKey) } else { SecureField("聊天 API Key",text: $model.apiKey) } }
                            Toggle("显示密钥",isOn: $showKey).font(.system(size: 14))
                        }.padding(18).workspaceGlass(palette,radius: 20)
                        VStack(alignment: .leading,spacing: 24) {
                            WorkspaceField(title: "接口",palette: palette) { Picker("接口模式",selection: $model.configuration.endpointMode) { ForEach(EndpointMode.allCases,id: \.self) { Text($0.title).tag($0) } }.labelsHidden().frame(maxWidth: .infinity,alignment: .leading) }
                            WorkspaceModelField(model: model,selection: $model.configuration.model,title: "默认模型",prompt: "模型 ID")
                            Toggle(isOn: $model.configuration.sendTemperature) { VStack(alignment: .leading,spacing: 4) { Text("发送 Temperature").font(.system(size: 15,weight: .semibold)); Text("部分模型不接受此参数").font(.system(size: 13)).foregroundStyle(palette.muted) } }.toggleStyle(.switch).accessibilityLabel("发送 Temperature")
                            if model.configuration.sendTemperature { LabeledContent("Temperature",value: model.configuration.temperature.formatted(.number.precision(.fractionLength(2)))); Slider(value: $model.configuration.temperature,in: 0...2) }
                        }.padding(18).workspaceGlass(palette,radius: 20)
                        Button(fetching ? "正在读取…" : "测试连接并刷新模型") { fetching = true; Task { await model.refreshModels(); fetching = false } }.workspaceAction(palette,primary: true).disabled(fetching)
                        WorkspaceField(title: "流式显示",palette: palette) { Picker("流式刷新率",selection: $model.configuration.framesPerSecond) { Text("标准 · 60 Hz").tag(60); Text("高刷新率 · 120 Hz").tag(120) }.labelsHidden() }
                    }
                    if focusLogs || !embedded {
                        VStack(alignment: .leading,spacing: 20) {
                            WorkspaceField(title: "日志地址（留空使用聊天服务器）",palette: palette) { TextField("日志服务器",text: $model.services.logServer).autocorrectionDisabled() }
                            WorkspaceField(title: "VCPLog Key",palette: palette) { SecureField("与聊天 Key 分开",text: $model.logKey).accessibilityLabel("VCPLog Key") }
                            Button("连接 WebSocket") { model.connectPush() }.workspaceAction(palette,primary: true)
                            ForEach(PushChannel.allCases,id: \.self) { channel in LabeledContent(channel.title,value: model.activity.statuses[channel] ?? "未连接").font(.system(size: 13)) }
                        }.padding(18).workspaceGlass(palette,radius: 20)
                    }
                    DisclosureGroup("导入与连接管理",isExpanded: $management) {
                        VStack(alignment: .leading,spacing: 14) {
                            Button("导入桌面 VCPChat 连接…",systemImage: "square.and.arrow.down") { importing = true }.disabled(model.credentialsInMemory)
                            Text(model.credentialsInMemory ? "会话模式：连接密钥只保留到退出 App，不访问系统钥匙串。" : "只读取服务器和连接密钥，保存到本机钥匙串。不会改动旧配置和会话。").font(.caption).foregroundStyle(palette.muted)
                        }.padding(.top,12)
                    }
                }.padding(20).frame(maxWidth: 760).frame(maxWidth: .infinity)
            }.scrollDismissesKeyboard(.interactively)
            Button(model.savingConnection ? "保存中…" : "保存连接") { Task { if await model.saveConnection() { dismiss() } } }.workspaceAction(palette,primary: true).disabled(model.savingConnection).padding(.horizontal,20).padding(.vertical,12).background(palette.glass)
        }.buttonStyle(WorkspacePress()).workspaceRootNavigation().foregroundStyle(palette.ink).tint(palette.accent)
        .background(ThemeWallpaper(model.appearance,animations: model.renderOptions.motion).ignoresSafeArea())
        .onChange(of: model.configuration.server) { _,_ in Task { await model.loadCatalog() } }
        .fileImporter(isPresented: $importing,allowedContentTypes: [.json]) { result in if case .success(let url) = result { Task { await model.importConnection(from: url) } } }
    }
}
