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
            }.formStyle(.grouped).navigationTitle("设置")
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } } }
            .onChange(of: model.inputPreferences) { _, _ in Task { await model.saveInputPreferences() } }
            .sheet(isPresented: $connection) { ConnectionView(model: model) }
            .sheet(isPresented: $regex) { RegexRulesView(title: "全局正则", rules: $model.regexRules) { await model.saveRegexRules() } }
        }.frame(minWidth: 350, minHeight: 540)
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
                Toggle("HTML 视觉气泡", isOn: $model.renderOptions.html)
                Toggle("气泡动画", isOn: $model.renderOptions.motion)
                Toggle("气泡图片与媒体", isOn: $model.renderOptions.media)
            }.disabled(!model.renderOptions.enabled)
            Section { Text("修改后会立即应用到已有消息。关闭高级渲染时显示原始文字。").font(.callout).foregroundStyle(.secondary) }
        }.formStyle(.grouped).navigationTitle("消息渲染")
        .onChange(of: model.renderOptions) { _, _ in Task { await model.saveRenderOptions() } }
    }
}
