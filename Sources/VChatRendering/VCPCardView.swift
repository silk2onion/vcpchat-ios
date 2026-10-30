import SwiftUI
import VChatCore

struct VCPCardView: View {
    var segment: VCPMarkup.Segment
    var options: RenderOptions
    @ViewBuilder var body: some View {
        switch segment {
        case .text(let text): RichMessageBody(text, options: options)
        case .think(let title, let text, let closed):
            FoldedCard(title: title, icon: "sparkles", subtitle: closed ? "" : "进行中", initiallyOpen: !closed) { RichMessageBody(text, options: options) }
        case .tool(let name, let command, let body, let closed):
            FoldedCard(title: name, icon: "wrench.and.screwdriver", subtitle: closed ? command : "输入中 · " + command, initiallyOpen: !closed) { Text(verbatim: body).font(.callout.monospaced()).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }
        case .result(let result, let closed):
            FoldedCard(title: result.tool.isEmpty ? "工具结果" : result.tool, icon: result.ok == false ? "exclamationmark.triangle" : "checkmark.circle", subtitle: closed ? result.status : "接收中", initiallyOpen: !closed, failed: result.ok == false) {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(Array(result.fields.enumerated()), id: \.offset) { _, field in VStack(alignment: .leading, spacing: 3) { Text(field.key).font(.caption).foregroundStyle(.secondary); Text(verbatim: field.value).textSelection(.enabled) } }
                    if !result.content.isEmpty { RichMessageBody(result.content, options: options) }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
        case .diary(let entry, let closed):
            VStack(alignment: .leading, spacing: 10) {
                HStack { Label(entry.update ? "日记修改" : entry.title, systemImage: "book.closed").font(.headline); Spacer(); Text(closed ? entry.date : "写入中").font(.caption).foregroundStyle(.secondary) }
                if !entry.agent.isEmpty || !entry.folder.isEmpty { Text([entry.agent.isEmpty ? "" : entry.label + "：" + entry.agent, entry.folder].filter { !$0.isEmpty }.joined(separator: " · ")).font(.caption).foregroundStyle(.secondary) }
                if entry.update {
                    Text("原文").font(.caption).foregroundStyle(.secondary); RichMessageBody(entry.target, options: options)
                    Divider(); Text("改为").font(.caption).foregroundStyle(.mint); RichMessageBody(entry.replacement, options: options)
                } else { RichMessageBody(entry.content, options: options) }
                if !entry.tag.isEmpty { Text(entry.tag).font(.caption).foregroundStyle(.secondary) }
            }.padding(14).background(.mint.opacity(0.07), in: RoundedRectangle(cornerRadius: 14))
        case .summary(let items, let closed):
            VStack(alignment: .leading, spacing: 6) { Label(closed ? "本轮工具调用" : "工具摘要 · 接收中", systemImage: "checklist").font(.caption).foregroundStyle(.secondary); ForEach(Array(items.enumerated()), id: \.offset) { _, item in Text("• " + item).font(.callout) } }.padding(12).frame(maxWidth: .infinity, alignment: .leading).background(.secondary.opacity(0.05), in: RoundedRectangle(cornerRadius: 12))
        case .divider(let role, let end):
            HStack { Divider(); Text((role == "user" ? "用户" : role == "system" ? "系统" : "助手") + " · " + (end ? "结束" : "开始")).font(.caption).foregroundStyle(.secondary).fixedSize(); Divider() }
        case .push(let text, let closed):
            FoldedCard(title: "桌面推送", icon: "desktopcomputer", subtitle: closed ? "仅展示，不执行" : "接收中", initiallyOpen: false) { Text(verbatim: text).font(.callout.monospaced()).textSelection(.enabled) }
        }
    }
}
private struct FoldedCard<Content: View>: View {
    var title: String; var icon: String; var subtitle: String
    var initiallyOpen: Bool; var failed = false
    @ViewBuilder var content: () -> Content
    @State private var expanded = false
    var body: some View {
        DisclosureGroup(isExpanded: $expanded) {
            content().padding(.top, 10)
        } label: {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: icon).foregroundStyle(failed ? .red : .secondary)
                Text(title).font(.callout.weight(.semibold)); Spacer(minLength: 8)
                if !subtitle.isEmpty { Text(subtitle).font(.caption).foregroundStyle(failed ? .red : .secondary).lineLimit(2) }
            }.contentShape(Rectangle())
        }.padding(14).background((failed ? Color.red : .secondary).opacity(0.06), in: RoundedRectangle(cornerRadius: 14))
        .onAppear { expanded = initiallyOpen }
    }
}
