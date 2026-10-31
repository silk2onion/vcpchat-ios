import SwiftUI
import VChatCore
import VChatRendering
struct SpeechSettingsView: View {
    @Bindable var model: ChatViewModel
    @State private var loading = false
    @State private var choosing = false
    @State private var error: String?
    @State private var saved = false
    var key: String { model.serviceSecrets[.speechKey] ?? "" }
    private var palette: WorkspacePalette { .init(theme: model.appearance.theme) }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading,spacing: 24) {
                if let error { Text(error).foregroundStyle(.red) }
                if model.credentialsLocked { Button("解锁已有服务密钥",systemImage: "lock.open") { Task { await model.loadCredentials(allowInteraction: true) } } }
                HStack(spacing: 12) { WorkspaceGlyph("speaker",size: 28).foregroundStyle(palette.accent); VStack(alignment: .leading,spacing: 4) { Text("语音服务").font(.system(size: 19,weight: .semibold)); Text("为每位 Agent 留下熟悉的声音。").font(.system(size: 13)).foregroundStyle(palette.muted) } }
                VStack(alignment: .leading,spacing: 22) {
                    WorkspaceField(title: "服务类型",palette: palette) { Picker("服务类型",selection: $model.services.speech.mode) { Text("SoVITS v2ProPlus").tag(SpeechMode.sovits); Text("MiMo TTS").tag(SpeechMode.mimo) }.labelsHidden() }
                    WorkspaceField(title: "语音服务 URL",palette: palette) { TextField("语音服务 URL",text: $model.services.speech.server) }
                    WorkspaceField(title: "API Key",palette: palette) { SecureField("语音 API Key",text: Binding(get: { key },set: { model.serviceSecrets[.speechKey] = $0 })) }
                    if model.services.speech.mode == .mimo { WorkspaceField(title: "MiMo 模型 ID",palette: palette) { TextField("MiMo 模型 ID",text: $model.services.speech.model) } }
                }.padding(18).workspaceGlass(palette)
                VStack(alignment: .leading,spacing: 22) {
                    HStack { Text("音色与表达").font(.system(size: 16,weight: .semibold)); Spacer(); Button(loading ? "读取中…" : "读取音色列表",systemImage: "arrow.clockwise") { loading = true; Task { defer { loading = false }; do { try await model.speech.refresh(model.services.speech,key: key); choosing = true } catch { self.error = error.localizedDescription } } }.font(.system(size: 13)).foregroundStyle(palette.accent).disabled(loading) }
                    WorkspaceField(title: "音色 ID",palette: palette) { TextField("音色 ID",text: $model.services.speech.voice) }
                    LabeledContent("语速",value: model.services.speech.speed.formatted(.number.precision(.fractionLength(2))))
                    Slider(value: $model.services.speech.speed,in: 0.5...2,step: 0.05)
                    WorkspaceField(title: "导演提示词（可选）",palette: palette) { TextField("导演提示词",text: $model.services.speech.director,axis: .vertical).lineLimit(2...5) }
                    Button("试听",systemImage: "play.fill") { model.speech.read(id: "voice-preview",content: "你好，这是一段 VChat 原生语音试听。",settings: model.services.speech,key: key,agent: nil) }.workspaceAction(palette)
                }.padding(18).workspaceGlass(palette)
                Button(saved ? "已保存" : "保存语音设置") { Task { saved = await model.saveServices(); error = saved ? nil : model.error } }.workspaceAction(palette,primary: true)
            }.padding(20).frame(maxWidth: 760).frame(maxWidth: .infinity)
        }.buttonStyle(WorkspacePress()).navigationTitle("语音与朗读").background(ThemeWallpaper(model.appearance,animations: model.renderOptions.motion).ignoresSafeArea())
        .sheet(isPresented: $choosing) { VoicePicker(voices: model.speech.voices,selection: $model.services.speech.voice) }
    }
}
struct VoicePicker: View {
    let voices: [SpeechVoice]
    @Binding var selection: String
    @State private var query = ""
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack { List(voices.filter { query.isEmpty || ($0.id + $0.name).localizedCaseInsensitiveContains(query) }) { voice in Button { selection = voice.id; dismiss() } label: { HStack { VStack(alignment: .leading) { Text(voice.name); Text(voice.id).font(.caption).foregroundStyle(.secondary) }; Spacer(); if selection == voice.id { Image(systemName: "checkmark") } }.contentShape(Rectangle()) }.buttonStyle(.plain) }.searchable(text: $query,prompt: "搜索音色").navigationTitle("选择音色").toolbar { Button("取消") { dismiss() } } }.frame(minWidth: 340,minHeight: 450)
    }
}
struct MiniSpeechPlayer: View {
    let player: SpeechPlayback
    @Environment(\.workspaceTheme) private var theme
    var body: some View {
        if player.phase != "idle" {
            VStack(spacing: 6) {
                HStack(spacing: 12) {
                    if player.phase == "loading" { ProgressView().controlSize(.small) }
                    else { Button { player.toggle() } label: { Image(systemName: player.phase == "playing" ? "pause.fill" : "play.fill").frame(width: 36,height: 36) }.accessibilityLabel(player.phase == "playing" ? "暂停朗读" : "继续朗读").disabled(player.phase == "error") }
                    VStack(alignment: .leading,spacing: 3) { Text(player.speaker).font(.callout.weight(.medium)); Text(player.error ?? (player.phase == "loading" ? "正在合成第 \(player.segment)/\(player.totalSegments) 段…" : "\(Int(player.elapsed)) / \(Int(player.duration)) 秒 · 第 \(player.segment)/\(player.totalSegments) 段")).font(.caption).foregroundStyle(player.error == nil ? Color.secondary : .red).lineLimit(2) }
                    Spacer(); Button { player.stop() } label: { Image(systemName: "xmark").frame(width: 36,height: 36) }.accessibilityLabel("停止朗读")
                }.buttonStyle(.plain)
                if player.duration > 0 { ProgressView(value: min(player.elapsed,player.duration),total: player.duration) }
            }.padding(12).workspaceGlass(WorkspacePalette(theme: theme),radius: 19).padding(.horizontal,15).padding(.vertical,8).transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }
}
