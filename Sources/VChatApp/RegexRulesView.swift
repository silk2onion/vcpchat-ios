import SwiftUI
import VChatCore
import VChatRendering
import UniformTypeIdentifiers

struct RegexRulesView: View {
    var title: String
    @Binding var rules: [RegexRule]
    var save: () async -> Void
    @State private var editing: RegexRule?
    @State private var importing = false
    @State private var exporting = false
    @State private var document = TextExportDocument()
    @State private var error: String?
    @Environment(\.dismiss) private var dismiss
    @Environment(\.workspaceTheme) private var theme
    var body: some View {
        NavigationStack {
            List {
                Section { Button { editing = RegexRule() } label: { Label("添加规则", systemImage: "plus.circle.fill").frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle()) } }
                if let error { Text(error).foregroundStyle(.red) }
                if rules.isEmpty { ContentUnavailableView("还没有正则规则", systemImage: "text.magnifyingglass", description: Text("添加规则，或导入 VChat / SillyTavern JSON。")) }
                ForEach(Array(rules.enumerated()), id: \.element.id) { index, rule in
                    HStack(spacing: 12) {
                        Toggle(rule.title, isOn: Binding(get: { rules.first { $0.id == rule.id }?.enabled ?? false }, set: { value in if let i = rules.firstIndex(where: { $0.id == rule.id }) { rules[i].enabled = value; Task { await save() } } })).labelsHidden().accessibilityLabel("启用 " + rule.title)
                        Button { editing = rule } label: { VStack(alignment: .leading, spacing: 5) { Text(rule.title).font(.headline); Text([rule.applyToFrontend ? "显示" : "", rule.applyToContext ? "发送上下文" : ""].filter { !$0.isEmpty }.joined(separator: " · ")).font(.caption).foregroundStyle(.secondary) }.frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle()) }.buttonStyle(.plain)
                        Menu {
                            Button("上移", systemImage: "arrow.up") { move(index, -1) }.disabled(index == 0)
                            Button("下移", systemImage: "arrow.down") { move(index, 1) }.disabled(index + 1 == rules.count)
                            Button("编辑", systemImage: "pencil") { editing = rule }
                        } label: { Image(systemName: "ellipsis").frame(width: 32, height: 36) }.menuStyle(.borderlessButton).fixedSize()
                    }.padding(.vertical, 4)
                }.onMove { from, to in rules.move(fromOffsets: from, toOffset: to); Task { await save() } }
            }.scrollContentBackground(.hidden).background(WorkspacePalette(theme: theme).solid).navigationTitle(title)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("完成") { dismiss() } }
                ToolbarItemGroup(placement: .primaryAction) {
                    Menu { Button("导入 JSON", systemImage: "square.and.arrow.down") { importing = true }; Button("导出 JSON", systemImage: "square.and.arrow.up") { do { document = TextExportDocument(text: String(decoding: try JSONEncoder().encode(rules), as: UTF8.self)); exporting = true } catch { self.error = error.localizedDescription } } } label: { Image(systemName: "square.and.arrow.up.on.square") }
                }
            }
            .sheet(item: $editing) { rule in RegexRuleEditor(rule: rule, existing: rules.contains { $0.id == rule.id }) { updated in if let i = rules.firstIndex(where: { $0.id == updated.id }) { rules[i] = updated } else { rules.append(updated) }; await save() } remove: { rules.removeAll { $0.id == rule.id }; await save() } }
            .fileImporter(isPresented: $importing, allowedContentTypes: [.json]) { result in if case .success(let url) = result { Task { do { let imported = try await RegexEngine.shared.importFile(url); rules.append(contentsOf: imported); await save() } catch { self.error = error.localizedDescription } } } }
            .fileExporter(isPresented: $exporting, document: document, contentType: .json, defaultFilename: "VChat-regex.json") { result in if case .failure(let error) = result, (error as? CocoaError)?.code != .userCancelled { self.error = error.localizedDescription } }
        }.frame(minWidth: 370, minHeight: 500)
    }
    private func move(_ index: Int, _ delta: Int) { rules.swapAt(index, index + delta); Task { await save() } }
}
private struct RegexRuleEditor: View {
    @State var rule: RegexRule
    var existing: Bool
    var save: (RegexRule) async -> Void
    var remove: () async -> Void
    @State private var sample = "你好 {{user}}"
    @State private var output = ""
    @State private var previewScope = "frontend"
    @State private var previewRole = "assistant"
    @State private var error: String?
    @State private var deleting = false
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            Form {
                if let error { Section { Text(error).foregroundStyle(.red) } }
                Section("替换规则") {
                    TextField("名称", text: $rule.title)
                    TextField("查找，例如 /pattern/gi", text: $rule.findPattern, axis: .vertical).font(.callout.monospaced())
                    TextField("替换为（支持 $1、$& 等）", text: $rule.replaceWith, axis: .vertical).lineLimit(2...5)
                    Toggle("启用", isOn: $rule.enabled)
                }
                Section("应用位置") {
                    Toggle("消息显示", isOn: $rule.applyToFrontend)
                    Toggle("发送给模型的上下文", isOn: $rule.applyToContext)
                    Toggle("用户消息", isOn: role("user")); Toggle("助手消息", isOn: role("assistant"))
                    TextField("最小轮深（-1 不限制）", value: $rule.minDepth, format: .number)
                    TextField("最大轮深（-1 不限制）", value: $rule.maxDepth, format: .number)
                }
                Section("预览 · 轮深 0") {
                    Picker("位置", selection: $previewScope) { Text("显示").tag("frontend"); Text("上下文").tag("context") }
                    Picker("角色", selection: $previewRole) { Text("用户").tag("user"); Text("助手").tag("assistant") }
                    TextEditor(text: $sample).frame(minHeight: 75)
                    Button("预览替换") { Task { do { output = try await RegexEngine.shared.apply(sample, rules: [rule], scope: previewScope, role: previewRole); error = nil } catch { self.error = error.localizedDescription } } }.disabled(rule.findPattern.isEmpty)
                    if !output.isEmpty { Text(verbatim: output).textSelection(.enabled) }
                }
                if existing { Section { Button("删除规则", role: .destructive) { deleting = true } } }
            }.formStyle(.grouped).navigationTitle(existing ? "编辑正则" : "添加正则")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("保存") { Task { do { try await RegexEngine.shared.validate(rule.findPattern); await save(rule); dismiss() } catch { self.error = error.localizedDescription } } }.disabled(rule.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || rule.findPattern.isEmpty) }
            }
            .confirmationDialog("删除这条规则？", isPresented: $deleting, titleVisibility: .visible) { Button("删除", role: .destructive) { Task { await remove(); dismiss() } } }
        }.frame(minWidth: 370, minHeight: 570)
    }
    private func role(_ role: String) -> Binding<Bool> { Binding(get: { rule.applyToRoles.contains(role) }, set: { value in rule.applyToRoles.removeAll { $0 == role }; if value { rule.applyToRoles.append(role) } }) }
}
