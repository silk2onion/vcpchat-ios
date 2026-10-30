import SwiftUI
import VChatCore

struct ModelPicker: View {
    @Bindable var model: ChatViewModel
    @Binding var selection: String
    @State private var query = ""
    @State private var limit = 40
    @State private var loading = false
    @Environment(\.dismiss) private var dismiss
    var filtered: [String] { model.catalog?.matches(query) ?? model.models.filter { query.isEmpty || $0.localizedCaseInsensitiveContains(query) } }
    var body: some View {
        NavigationStack {
            List {
                Section {
                    TextField("模型 ID（可手动填写）", text: $selection)
                    Button(loading ? "正在读取…" : "从服务器刷新", systemImage: "arrow.clockwise") { loading = true; Task { await model.refreshModels(); loading = false } }.disabled(loading)
                }
                if query.isEmpty, let recent = model.catalog?.recent, !recent.isEmpty {
                    Section("最近使用") { ForEach(recent, id: \.self) { id in choice(id) } }
                }
                Section("\(filtered.count) 个模型") {
                    ForEach(filtered.prefix(limit), id: \.self) { id in choice(id) }
                    if filtered.count > limit { Button("再显示 40 个") { limit += 40 } }
                }
            }
            .searchable(text: $query, prompt: "搜索模型，支持多个关键词")
            .onChange(of: query) { _, _ in limit = 40 }
            .navigationTitle("选择模型")
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { Task { await model.rememberModel(selection); dismiss() } } } }
        }.frame(minWidth: 340, minHeight: 520)
    }
    func choice(_ id: String) -> some View {
        Button { selection = id; Task { await model.rememberModel(id) }; dismiss() } label: {
            HStack { Text(id).lineLimit(2).foregroundStyle(.primary); Spacer(); if selection == id { Image(systemName: "checkmark").foregroundStyle(.mint) } }.frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
        }.buttonStyle(.plain)
    }
}
