import SwiftUI
import VChatRendering

struct SettingsView: View {
    @Bindable var model: ChatViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var connection = false
    @State private var regex = false
    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Button { connection = true } label: { Label("服务器与模型", systemImage: "network").frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle()) }
                    NavigationLink { AppearanceSettingsView(model: model) } label: { Label("外观与壁纸", systemImage: "paintpalette") }
                    NavigationLink { SpeechSettingsView(model: model) } label: { Label("语音朗读", systemImage: "speaker.wave.2") }
                    NavigationLink { RenderingSettings(model: model) } label: { Label("消息渲染", systemImage: "text.alignleft") }
                    Button { regex = true } label: { Label("正则规则", systemImage: "text.magnifyingglass").frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle()) }
                }
                Section("输入") {
                    Toggle("回车键发送消息", isOn: $model.inputPreferences.enterSends)
                    Text(model.inputPreferences.enterSends ? "回车发送，点“换行”插入新行" : "回车换行，点箭头发送").font(.caption).foregroundStyle(.secondary)
                }
                Section {
                    NavigationLink { DataManagementView(model: model) } label: { Label("数据与连接",systemImage: "externaldrive") }
                    NavigationLink { AboutVChat() } label: { Label("关于 VChat",systemImage: "info.circle") }
                }
            }.formStyle(.grouped).navigationTitle("设置")
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } } }
            .onChange(of: model.inputPreferences) { _, _ in Task { await model.saveInputPreferences() } }
            .sheet(isPresented: $connection) { ConnectionView(model: model) }
            .sheet(isPresented: $regex) { RegexRulesView(title: "全局正则", rules: $model.regexRules) { await model.saveRegexRules() } }
        }.frame(minWidth: 350, minHeight: 540)
    }
}
private struct AboutVChat: View {
    private var version: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.3.0" }
    var body: some View {
        Form {
            Section {
                VStack(alignment: .leading,spacing: 10) {
                    Image(systemName: "sparkle").font(.largeTitle).foregroundStyle(.mint)
                    Text("VChat").font(.title.bold())
                    Text("\(version) · 随身的 Agent 工作空间").foregroundStyle(.secondary)
                    Text("SwiftUI 原生界面，连接你自己的 VCP 服务。聊天、笔记与文件保存在这台设备上。")
                }.padding(.vertical,12)
                Link("使用说明",destination: URL(string: "https://github.com/silk2onion/vcpchat-ios/blob/feat/swiftui-phase1/README.md")!)
                Link("项目源码",destination: URL(string: "https://github.com/silk2onion/vcpchat-ios")!)
            }
            Section("许可与来源") {
                Text("CC BY-NC-SA 4.0 · 署名—非商业性使用—相同方式共享")
                Link("查看项目许可",destination: URL(string: "https://github.com/silk2onion/vcpchat-ios/blob/feat/swiftui-phase1/LICENSE")!)
                Text("参考并适配 VCPMobile、VCPChat 与 VCPToolBox 的协议与交互。原 Tauri/Vue 实现已重写为 SwiftUI 原生客户端；各开源组件保留独立许可，完整说明见 README。").font(.callout).foregroundStyle(.secondary)
                Link("VCPMobile",destination: URL(string: "https://github.com/MRiecy/VCPMobile")!)
                Link("VCPChat",destination: URL(string: "https://github.com/lioensky/VCPChat")!)
                Link("VCPToolBox",destination: URL(string: "https://github.com/lioensky/VCPToolBox")!)
            }
        }.formStyle(.grouped).navigationTitle("关于 VChat")
    }
}
private struct RenderingSettings: View {
    @Bindable var model: ChatViewModel
    var body: some View {
        Form {
            Section { Toggle("高级渲染", isOn: $model.renderOptions.enabled) }
            Section {
                Toggle("代码语法高亮", isOn: $model.renderOptions.code)
                Toggle("数学公式", isOn: $model.renderOptions.math)
                Toggle("Mermaid 图表",isOn: $model.renderOptions.mermaid)
                Toggle("HTML 视觉气泡", isOn: $model.renderOptions.html)
                Toggle("气泡动画", isOn: $model.renderOptions.motion)
                Toggle("图片与视频", isOn: $model.renderOptions.media)
            }.disabled(!model.renderOptions.enabled)
            Section { Text("修改后会立即应用到已有消息。关闭高级渲染时显示原始文字。").font(.callout).foregroundStyle(.secondary) }
        }.formStyle(.grouped).navigationTitle("消息渲染")
        .onChange(of: model.renderOptions) { _, _ in Task { await model.saveRenderOptions() } }
    }
}
