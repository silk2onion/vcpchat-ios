import SwiftUI
import VChatRendering

struct SettingsView: View {
    @Bindable var model: ChatViewModel
    var embedded = false
    @Environment(\.dismiss) private var dismiss
    @State private var regex = false
    @State private var mainAgent = false
    private var palette: WorkspacePalette { .init(theme: model.appearance.theme) }
    var body: some View { Group { if embedded { content } else { NavigationStack { content } } }.frame(minWidth: 350,minHeight: 540) }
    private var content: some View {
        VStack(spacing: 0) {
            WorkspaceDetailHeader(title: "设置",palette: palette,back: { dismiss() }) { EmptyView() }
            ScrollView {
                VStack(alignment: .leading,spacing: 0) {
                    HStack(spacing: 14) { WorkspaceGlyph("render",size: 30).foregroundStyle(palette.accentInk).frame(width: 58,height: 58).background(palette.accent,in: RoundedRectangle(cornerRadius: 19)); VStack(alignment: .leading,spacing: 5) { Text("VCPChat").font(.system(size: 22,weight: .bold)); Text("你的 Agent，随身同行。").font(.system(size: 13)).foregroundStyle(palette.muted) }; Spacer(); Text(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.3.0").font(.system(size: 11)).foregroundStyle(palette.muted) }.padding(.vertical,10)
                    label("连接")
                    VStack(spacing: 0) {
                        NavigationLink { ConnectionView(model: model,embedded: true).workspaceRootNavigation() } label: { row("服务器与模型","server",model.configuration.model.isEmpty ? "连接你的 VCPToolBox" : model.configuration.model) }
                        WorkspaceSeparator(palette: palette)
                        NavigationLink { ConnectionView(model: model,embedded: true,focusLogs: true).workspaceRootNavigation() } label: { row("日志通道","logs","VCPLog 与 VCPInfo",blue: true) }
                        WorkspaceSeparator(palette: palette)
                        NavigationLink { ActivityView(model: model).workspaceDetailNavigation() } label: { row("查看实时日志","history",model.activity.statuses[.log] ?? "未连接",blue: true) }
                    }.workspaceGlass(palette)
                    label("个性化")
                    VStack(spacing: 0) {
                        Button { mainAgent = true } label: { row("主 Agent","star",model.mainAgent?.name ?? "未设置") }
                        WorkspaceSeparator(palette: palette)
                        HStack(spacing: 8) { WorkspaceMenuRow(title: "回车键发送消息",icon: "keyboard",color: Color(rgb: 0x71a8d5),subtitle: model.inputPreferences.enterSends ? "回车发送，点“换行”插入新行" : "回车换行，点箭头发送",chevron: false); Toggle("回车键发送消息",isOn: $model.inputPreferences.enterSends).labelsHidden().toggleStyle(.switch).padding(.trailing,14) }
                        WorkspaceSeparator(palette: palette)
                        NavigationLink { RenderingSettings(model: model).workspaceDetailNavigation() } label: { row("高级渲染","render",model.renderOptions.enabled ? "已开启" : "轻量模式",purple: true) }
                        WorkspaceSeparator(palette: palette)
                        NavigationLink { AppearanceSettingsView(model: model).workspaceDetailNavigation() } label: { row("外观","palette",model.appearance.theme.title,purple: true) }
                        WorkspaceSeparator(palette: palette)
                        NavigationLink { ProfileEditor(model: model,profile: model.profile).workspaceDetailNavigation() } label: { row("身份与日记","agents","称呼与服务器日记账号",blue: true) }
                        WorkspaceSeparator(palette: palette)
                        NavigationLink { SpeechSettingsView(model: model).workspaceDetailNavigation() } label: { row("语音与朗读","speaker","SoVITS / MiMo · 每个 Agent 的声音") }
                        WorkspaceSeparator(palette: palette)
                        Button { regex = true } label: { row("全局正则","regex","\(model.regexRules.count) 条规则 · 显示与上下文",purple: true) }
                    }.workspaceGlass(palette)
                    label("应用")
                    VStack(spacing: 0) {
                        NavigationLink { DataManagementView(model: model).workspaceDetailNavigation() } label: { row("本机数据","folder","备份、恢复与连接密钥",blue: true) }
                        WorkspaceSeparator(palette: palette)
                        NavigationLink { AboutVChat().workspaceDetailNavigation() } label: { row("关于 VCPChat","info","") }
                    }.workspaceGlass(palette)
                }.padding(.horizontal,20).padding(.bottom,28).frame(maxWidth: 760).frame(maxWidth: .infinity)
            }
        }.workspaceRootNavigation().buttonStyle(WorkspacePress()).foregroundStyle(palette.ink)
        .background(ThemeWallpaper(model.appearance,animations: model.renderOptions.motion).ignoresSafeArea())
        .onChange(of: model.inputPreferences) { _,_ in Task { await model.saveInputPreferences() } }
        .sheet(isPresented: $regex) { RegexRulesView(title: "全局正则",rules: $model.regexRules) { await model.saveRegexRules() } }
        .sheet(isPresented: $mainAgent) { WorkspaceOwnerPicker(model: model,mainOnly: true,selectAgent: { agent in Task { await model.setMainAgent(agent.id) } }) }
    }
    private func label(_ title: String) -> some View { Text(title).font(.system(size: 14,weight: .medium)).foregroundStyle(palette.muted).padding(.top,22).padding(.bottom,10).padding(.leading,6) }
    private func row(_ title: String,_ icon: String,_ subtitle: String,blue: Bool = false,purple: Bool = false) -> some View { WorkspaceMenuRow(title: title,icon: icon,color: blue ? Color(rgb: 0x71a8d5) : purple ? Color(rgb: 0xad93db) : palette.accent,subtitle: subtitle) }
}
private struct AboutVChat: View {
    private var version: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.3.0" }
    var body: some View {
        Form {
            Section {
                VStack(alignment: .leading,spacing: 10) { Image(systemName: "sparkle").font(.largeTitle).foregroundStyle(.mint); Text("VChat").font(.title.bold()); Text("\(version) · 随身的 Agent 工作空间").foregroundStyle(.secondary); Text("SwiftUI 原生界面，连接你自己的 VCP 服务。聊天、笔记与文件保存在这台设备上。") }.padding(.vertical,12)
                Link("使用说明",destination: URL(string: "https://github.com/silk2onion/vcpchat-ios/blob/feat/swiftui-phase1/README.md")!)
                Link("项目源码",destination: URL(string: "https://github.com/silk2onion/vcpchat-ios")!)
            }
            Section("许可与来源") {
                Text("CC BY-NC-SA 4.0 · 署名—非商业性使用—相同方式共享")
                Link("查看项目许可",destination: URL(string: "https://github.com/silk2onion/vcpchat-ios/blob/feat/swiftui-phase1/LICENSE")!)
                Text("参考并适配 VCPMobile、VCPChat 与 VCPToolBox 的协议与交互。原 Tauri/Vue 实现已重写为 SwiftUI 原生客户端；各开源组件保留独立许可，完整说明见 README。").font(.callout).foregroundStyle(.secondary)
                Link("VCPMobile",destination: URL(string: "https://github.com/MRiecy/VCPMobile")!); Link("VCPChat",destination: URL(string: "https://github.com/lioensky/VCPChat")!); Link("VCPToolBox",destination: URL(string: "https://github.com/lioensky/VCPToolBox")!)
            }
        }.formStyle(.grouped).navigationTitle("关于 VChat")
    }
}
private struct RenderingSettings: View {
    @Bindable var model: ChatViewModel
    private var palette: WorkspacePalette { .init(theme: model.appearance.theme) }
    var body: some View {
        ScrollView {
            VStack(spacing: 22) {
                Toggle("高级渲染",isOn: $model.renderOptions.enabled).font(.headline).padding(18).workspaceGlass(palette)
                VStack(spacing: 0) {
                    toggle("代码高亮","代码块的语法着色",$model.renderOptions.code)
                    toggle("数学公式","原生数学排版与符号",$model.renderOptions.math)
                    toggle("Mermaid 图表","流程图、时序图等",$model.renderOptions.mermaid)
                    toggle("HTML 气泡","在独立沙箱里运行动画与交互",$model.renderOptions.html)
                    toggle("图片与视频预览","点击图片放大，播放视频",$model.renderOptions.media)
                    toggle("气泡动画","消息出现与生成时的轻动效",$model.renderOptions.motion)
                }.workspaceGlass(palette).disabled(!model.renderOptions.enabled)
            }.padding(20).frame(maxWidth: 760).frame(maxWidth: .infinity)
        }.navigationTitle("高级渲染").background(ThemeWallpaper(model.appearance,animations: model.renderOptions.motion).ignoresSafeArea()).tint(palette.accent)
        .onChange(of: model.renderOptions) { _,_ in Task { await model.saveRenderOptions() } }
    }
    private func toggle(_ title: String,_ subtitle: String,_ binding: Binding<Bool>) -> some View { VStack(spacing: 0) { Toggle(isOn: binding) { VStack(alignment: .leading,spacing: 4) { Text(title).font(.system(size: 15,weight: .semibold)); Text(subtitle).font(.system(size: 13)).foregroundStyle(palette.muted) } }.toggleStyle(.switch).accessibilityLabel(title).padding(17); WorkspaceSeparator(palette: palette) } }
}
