import SwiftUI
import VChatCore

struct WorkspaceModelField: View {
    @Bindable var model: ChatViewModel
    @Binding var selection: String
    var title = "模型"
    var prompt = "留空使用设置里的默认模型"
    @State private var expanded = false
    @State private var query = ""
    @State private var limit = 40
    @State private var loading = false
    @Environment(\.workspaceMotion) private var motion
    private var palette: WorkspacePalette { .init(theme: model.appearance.theme) }
    private var matches: [String] { model.catalog?.matches(query) ?? model.models.filter { query.isEmpty || $0.localizedCaseInsensitiveContains(query) } }
    var body: some View {
        VStack(alignment: .leading,spacing: 9) {
            Text(title).font(.system(size: 14)).foregroundStyle(palette.muted)
            HStack(spacing: 6) {
                TextField(prompt,text: $selection).textFieldStyle(.plain).font(.system(size: 16)).padding(13).frame(minHeight: 46).background(palette.input,in: RoundedRectangle(cornerRadius: 13)).accessibilityLabel(title)
                Button { withAnimation(motion ? .easeOut(duration: 0.18) : nil) { expanded.toggle() } } label: { WorkspaceGlyph(expanded ? "close" : "down",size: 18).frame(width: 42,height: 46).workspaceGlass(palette,radius: 12) }.accessibilityLabel("选择" + title)
            }
            if expanded {
                VStack(spacing: 0) {
                    HStack { WorkspaceGlyph("search",size: 18); TextField("搜索模型 ID…",text: $query).textFieldStyle(.plain).accessibilityLabel("搜索" + title + " ID"); Button { loading = true; Task { await model.refreshModels(); loading = false } } label: { if loading { ProgressView().controlSize(.small) } else { WorkspaceGlyph("history",size: 18).frame(width: 36,height: 36) } }.disabled(loading).accessibilityLabel("刷新模型列表") }.padding(12)
                    HStack { Text("\(matches.count) 个模型"); Spacer(); Text("已缓存").foregroundStyle(palette.accent) }.font(.system(size: 11)).foregroundStyle(palette.muted).padding(.horizontal,12).padding(.bottom,8)
                    WorkspaceSeparator(palette: palette)
                    ScrollView {
                        LazyVStack(spacing: 0) {
                            if query.isEmpty,let recent = model.catalog?.recent,!recent.isEmpty { Text("最近使用").font(.system(size: 11)).foregroundStyle(palette.muted).frame(maxWidth: .infinity,alignment: .leading).padding(12); ForEach(recent,id: \.self) { choice($0) }; WorkspaceSeparator(palette: palette) }
                            ForEach(matches.prefix(limit),id: \.self) { choice($0) }
                            if matches.count > limit { Button("再显示 40 个") { limit += 40 }.frame(minHeight: 44).foregroundStyle(palette.accent) }
                            if matches.isEmpty { Text("没有匹配的模型；可以直接填写 ID").font(.caption).foregroundStyle(palette.muted).padding(14) }
                        }
                    }.frame(maxHeight: 250)
                }.workspaceGlass(palette).transition(.opacity.combined(with: .offset(y: -4)))
            }
        }.onChange(of: query) { _,_ in limit = 40 }.buttonStyle(WorkspacePress())
    }
    private func choice(_ id: String) -> some View {
        Button { selection = id; Task { await model.rememberModel(id) }; withAnimation(motion ? .easeOut(duration: 0.18) : nil) { expanded = false } } label: { HStack { Text(id).font(.system(size: 13)).foregroundStyle(palette.ink).lineLimit(2); Spacer(); if selection == id { WorkspaceGlyph("check",size: 16).foregroundStyle(palette.accent) } }.padding(.horizontal,14).frame(minHeight: 44).contentShape(Rectangle()) }
    }
}
