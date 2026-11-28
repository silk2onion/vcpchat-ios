import SwiftUI
import VChatRendering
import UniformTypeIdentifiers
#if os(iOS)
import UserNotifications
import UIKit
#endif

struct SettingsView: View {
    @Bindable var model: ChatViewModel
    var embedded = false
    @Environment(\.dismiss) private var dismiss
    @State private var regex = false
    @State private var mainAgent = false
    private var palette: WorkspacePalette { .init(theme: model.appearance.theme) }
    var body: some View {
        Group { if embedded { content } else { NavigationStack { content } } }
            #if os(macOS)
            .frame(minWidth: 350, minHeight: 540)
            #endif
    }
    private var content: some View {
        VStack(spacing: 0) {
            #if os(macOS)
            WorkspaceDetailHeader(title: "设置",palette: palette,back: { dismiss() }) { EmptyView() }
            #endif
            ScrollView {
                VStack(alignment: .leading,spacing: 0) {
                    HStack(spacing: 14) { WorkspaceGlyph("render",size: 30).foregroundStyle(palette.accentInk).frame(width: 58,height: 58).background(palette.accent,in: RoundedRectangle(cornerRadius: 19)); VStack(alignment: .leading,spacing: 5) { Text("VCPChat").font(.system(size: 22,weight: .bold)); Text("你的 Agent，随身同行。").font(.system(size: 13)).foregroundStyle(palette.muted) }; Spacer(); Text(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.3.0").font(.system(size: 11)).foregroundStyle(palette.muted) }.padding(.vertical,10)
                    label("连接")
                    VStack(spacing: 0) {
                        NavigationLink { ConnectionView(model: model,embedded: true) } label: { row("服务器与模型","server",model.configuration.model.isEmpty ? "连接你的 VCPToolBox" : model.configuration.model) }
                        WorkspaceSeparator(palette: palette)
                        NavigationLink { ConnectionView(model: model,embedded: true,focusLogs: true) } label: { row("日志通道","logs","VCPLog 与 VCPInfo",blue: true) }

                    }.workspaceGlass(palette)
                    label("个性化")
                    VStack(spacing: 0) {
                        Button { mainAgent = true } label: { row("主 Agent","star",model.mainAgent?.name ?? "未设置") }
                        WorkspaceSeparator(palette: palette)
                        HStack(spacing: 8) { WorkspaceMenuRow(title: "回车键发送消息",icon: "keyboard",color: Color(rgb: 0x71a8d5),subtitle: model.inputPreferences.enterSends ? "回车发送，点“换行”插入新行" : "回车换行，点箭头发送",chevron: false); Toggle("回车键发送消息",isOn: $model.inputPreferences.enterSends).labelsHidden().toggleStyle(.switch).padding(.trailing,14) }
                        WorkspaceSeparator(palette: palette)
                        NavigationLink { RenderingSettings(model: model).workspaceDetailNavigation() } label: { row("高级渲染","render",model.renderOptions.enabled ? "已开启" : "轻量模式",purple: true) }
                        #if os(iOS)
                        WorkspaceSeparator(palette: palette)
                        NavigationLink { BackgroundReplySettings().workspaceDetailNavigation() } label: { row("后台回复与提醒","chat","锁屏收回复、通知与灵动岛",blue: true) }
                        WorkspaceSeparator(palette: palette)
                        NavigationLink { AdvancedReplySettingsView(model: model).workspaceDetailNavigation() } label: { row("高级回复","chat","气泡与工具提示词 · 注入位置和覆盖",purple: true) }.disabled(model.loading)
                        #endif
                        WorkspaceSeparator(palette: palette)
                        NavigationLink { AppearanceSettingsView(model: model).workspaceDetailNavigation() } label: { row("外观","palette",model.appearance.theme.title,purple: true) }
                        WorkspaceSeparator(palette: palette)
                        NavigationLink { ProfileEditor(model: model,profile: model.profile).workspaceDetailNavigation() } label: { row("身份与日记","agents","称呼与服务器日记账号",blue: true) }
                        WorkspaceSeparator(palette: palette)
                        NavigationLink { LocationSettingsView(model: model).workspaceDetailNavigation() } label: { row("位置共享","location",model.locationSettings.enabled ? "向选定 Agent 提供当前位置" : "按需分享位置与常用地点",blue: true) }
                        WorkspaceSeparator(palette: palette)
                        NavigationLink { SpeechSettingsView(model: model).workspaceDetailNavigation() } label: { row("语音与朗读","speaker","SoVITS / MiMo · 每个 Agent 的声音") }
                        WorkspaceSeparator(palette: palette)
                        Button { regex = true } label: { row("全局正则","regex","\(model.regexRules.count) 条规则 · 显示与上下文",purple: true) }
                    }.workspaceGlass(palette)
                    label("应用")
                    VStack(spacing: 0) {
                        NavigationLink { FileNodeView(model: model).workspaceDetailNavigation() } label: { row("移动工具节点","server","文件、历史回忆与主动话题",blue: true) }
                        WorkspaceSeparator(palette: palette)
                        NavigationLink { DataManagementView(model: model).workspaceDetailNavigation() } label: { row("本机数据","folder","备份、恢复与连接密钥",blue: true) }
                        WorkspaceSeparator(palette: palette)
                        NavigationLink { AboutVChat().workspaceDetailNavigation() } label: { row("关于 VCPChat","info","") }
                    }.workspaceGlass(palette)
                }.padding(.horizontal,20).padding(.bottom,28).frame(maxWidth: 760).frame(maxWidth: .infinity)
            }
        }.workspacePageNavigation(title: "设置",palette: palette,close: embedded ? nil : { dismiss() }).buttonStyle(WorkspacePress()).foregroundStyle(palette.ink)
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
        WorkspaceForm {
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
    @State private var savingBubbleRule = false
    @State private var importingStickers = false
    @State private var updatingStickers = false
    @State private var mediaNotice = ""
    private func updateStickers(_ file: URL? = nil) {
        guard !updatingStickers, let origin=model.stickerDeployment else { return }
        updatingStickers=true
        Task {
            defer { updatingStickers=false }
            do {
                let catalog: EmoticonCatalog
                if let file { catalog=try await StickerDirectories.shared.importFile(file,for:origin) }
                else { catalog=try await StickerDirectories.shared.refresh(origin:origin,username:model.services.adminUsername,password:model.serviceSecrets[.adminPassword] ?? "") }
                guard model.stickerDeployment==origin else { return }
                model.catalogDeployment=origin;model.stickerCatalog=catalog;mediaNotice="已更新表情目录"
            } catch { mediaNotice=error.localizedDescription }
        }
    }
    private var palette: WorkspacePalette { .init(theme: model.appearance.theme) }
    private var bubbleRule: Binding<Bool> {
        #if os(iOS)
        Binding(get: { model.advancedReplies.animatedBubbles },set: { enabled in
            var value = model.advancedReplies
            value.animatedBubbles = enabled
            savingBubbleRule = true
            Task { @MainActor in
                defer { savingBubbleRule = false }
                do { try await model.saveAdvancedReplies(value) }
                catch { model.error = error.localizedDescription }
            }
        })
        #else
        $model.outputPreferences.animatedBubbles
        #endif
    }
    var body: some View {
        ScrollView {
            VStack(spacing: 22) {
                Toggle(isOn: bubbleRule) {
                    VStack(alignment: .leading,spacing: 5) {
                        Text("Agent 输出动画气泡").font(.headline)
                        #if os(iOS)
                        Text("设置「高级回复」中动画气泡规则的全局启停；Agent 或群组可单独覆盖。与下方显示开关独立。").font(.caption).foregroundStyle(palette.muted)
                        #else
                        Text("向新请求追加 VCP 气泡输出规范，不改变已有消息。与下方显示开关独立。").font(.caption).foregroundStyle(palette.muted)
                        #endif
                    }
                }.toggleStyle(.switch).disabled(savingBubbleRule || model.loading).padding(18).workspaceGlass(palette)
                VStack(alignment: .leading, spacing: 12) {
                    Text("图片与表情包").font(.headline)
                    Text("下载过的图片可在本机复用。更新目录后，自动纠正回复里的表情包名、文件名和扩展名。").font(.caption)
                    Text("本服务器目录：\(model.stickers.catalog?.count ?? 0) 张")
                    Button("从当前 VCP 更新目录") { updateStickers() }.disabled(updatingStickers || model.stickerDeployment == nil)
                    Button("导入表情目录 JSON") { importingStickers=true }.disabled(updatingStickers || model.stickerDeployment == nil)
                    Button("清除聊天图片缓存") { Task { await NativeMediaLoader.shared.clearImageCache(); mediaNotice="聊天图片缓存已清除" } }
                    if !mediaNotice.isEmpty { Text(mediaNotice).font(.caption).accessibilityLabel(mediaNotice) }
                }.frame(maxWidth:.infinity,alignment:.leading).padding(18).workspaceGlass(palette)
                .fileImporter(isPresented:$importingStickers,allowedContentTypes:[.json]) { result in
                    if case .success(let url)=result { updateStickers(url) }
                }
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
        #if os(macOS)
        .onChange(of: model.outputPreferences) { _,_ in Task { await model.saveOutputPreferences() } }
        #endif
    }
    private func toggle(_ title: String,_ subtitle: String,_ binding: Binding<Bool>) -> some View { VStack(spacing: 0) { Toggle(isOn: binding) { VStack(alignment: .leading,spacing: 4) { Text(title).font(.system(size: 15,weight: .semibold)); Text(subtitle).font(.system(size: 13)).foregroundStyle(palette.muted) } }.toggleStyle(.switch).accessibilityLabel(title).padding(17); WorkspaceSeparator(palette: palette) } }
}

#if os(iOS)
private struct BackgroundReplySettings: View {
    @AppStorage(ReplyPresentation.modeKey) private var enabled = false
    @AppStorage(ReplyPresentation.islandKey) private var island = true
    @AppStorage(ServerReplyClient.preference) private var serverSync = false
    @AppStorage(ReplyPresentation.activityNoticeKey) private var activityNotice = ""
    @State private var permission: UNAuthorizationStatus = .notDetermined
    @State private var notice = ""
    @Environment(\.scenePhase) private var phase
    @Environment(\.openURL) private var openURL

    var body: some View {
        WorkspaceForm {
            Section {
                Toggle("后台收回复", isOn: $enabled)
                if enabled { Toggle("使用 VCP 回复续传插件",isOn:$serverSync) }
            } footer: {
                Text(enabled && serverSync ? "请先在自己的 VCP 安装 VChatReplySync。服务器继续生成，手机断线或重开后会补齐这条回复。未安装不会发起普通聊天请求。" : "前台实时显示回复。直连时，锁屏后 iOS 可能挂起连接；如需退出 App 后仍能补齐原回复，请安装并开启 VCP 回复续传插件。")
            }
            Section {
                Toggle("在锁屏与灵动岛显示进度", isOn: $island)
                if island && !activityNotice.isEmpty { Text(activityNotice).font(.caption).foregroundStyle(.secondary) }
                if permission == .notDetermined {
                    Button("允许回复完成通知") {
                        Task {
                            do { _ = try await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) }
                            catch { notice = error.localizedDescription }
                            await refresh()
                        }
                    }
                } else {
                    Button(permission == .denied ? "前往系统设置允许通知" : "管理回复通知") {
                        if let url = URL(string: UIApplication.openNotificationSettingsURLString) { openURL(url) }
                    }
                }
                if !notice.isEmpty { Text(notice).foregroundStyle(.secondary) }
            } footer: {
                Text("在其他 App 或锁屏时，轻点回复通知或实时活动可打开原话题。灵动岛需机型支持。即使不允许通知，回复也会保存。")
            }.disabled(!enabled)
        }.navigationTitle("后台回复与提醒").task { await refresh() }
        .onChange(of: phase) { _, value in if value == .active { Task { await refresh() } } }
    }
    private func refresh() async { permission = await ReplyPresentation.authorizationStatus() }
}
#endif
