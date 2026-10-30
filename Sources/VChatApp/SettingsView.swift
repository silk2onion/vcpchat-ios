import SwiftUI
import VChatRendering

struct SettingsView: View {
    @Bindable var model: ChatViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var connection = false
    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Button { connection = true } label: { Label("服务器与模型", systemImage: "network").frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle()) }
                    NavigationLink { RenderingSettings(model: model) } label: { Label("消息渲染", systemImage: "text.alignleft") }
                }
            }.formStyle(.grouped).navigationTitle("设置")
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } } }
            .sheet(isPresented: $connection) { ConnectionView(model: model) }
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
