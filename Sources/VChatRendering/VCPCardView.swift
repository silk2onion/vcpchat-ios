import SwiftUI
import VChatCore
import Markdown
import struct SwiftUI.Text
import struct SwiftUI.Image

struct VCPCardView: View {
    var segment: VCPMarkup.Segment
    var options: RenderOptions
    @ViewBuilder var body: some View {
        switch segment {
        case .batch(let parts, let closed):
            if parts.isEmpty && !closed {
                Label("正在接收工具结果", systemImage: "ellipsis").font(.caption).foregroundStyle(.secondary)
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(ToolPresentation.receiptRows(for: parts)) { row in
                        switch row.part {
                        case .summary(let items, let done): ToolSummary(items:items, closed:done, options:options,
                            results: row.results)
                        case .result(let result, let done): resultCard(result, closed:done, receipt:true)
                        case .note(let text):
                            FoldedCard(kind:"note",title:"工具结果",icon:"doc.text",subtitle:"",initiallyOpen:false,motion:options.motion) {
                                RichMessageBody(receipt: text, options: options).font(.callout)
                            }
                        }
                    }
                }
            }
        case .text(let text): RichMessageBody(text, options: options)
        case .think(let title, let text, let closed):
            FoldedCard(kind:"think",title: title, icon: "sparkles", subtitle: closed ? "" : "进行中", initiallyOpen: !closed,motion: options.motion) { RichMessageBody(text, options: options) }
        case .tool(let name, let command, let body, let closed):
            FoldedCard(kind:"tool",title: name, icon: "wrench.and.screwdriver", subtitle: closed ? command : "输入中 · " + command, initiallyOpen: !closed,motion: options.motion) { Text(verbatim: body).font(.callout.monospaced()).modifier(MessageTextSelection()).frame(maxWidth: .infinity, alignment: .leading) }
        case .result(let result, let closed):
            resultCard(result, closed:closed, receipt:false)
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
            ToolSummary(items:items, closed:closed, options:options)
        case .divider(let role, let end):
            HStack(spacing: 8) {
                Rectangle().fill(.secondary.opacity(0.25)).frame(height: 1)
                Text((role == "user" ? "用户" : role == "system" ? "系统" : "助手") + " · " + (end ? "结束" : "开始"))
                    .font(.caption).foregroundStyle(.secondary).fixedSize()
                Rectangle().fill(.secondary.opacity(0.25)).frame(height: 1)
            }.fixedSize(horizontal:false,vertical:true).allowsHitTesting(false)
        case .push(let text, let closed):
            FoldedCard(kind:"push",title: "桌面推送", icon: "desktopcomputer", subtitle: closed ? "仅展示，不执行" : "接收中", initiallyOpen: false,motion: options.motion) { Text(verbatim: text).font(.callout.monospaced()).modifier(MessageTextSelection()) }
        }
    }

    @ViewBuilder private func resultCard(_ result: VCPMarkup.Result, closed: Bool, receipt: Bool) -> some View {
        let title = result.tool.isEmpty ? "工具结果" : "工具结果 · " + result.tool
        let icon = result.ok == false ? "exclamationmark.triangle" : "doc.text"
        FoldedCard(kind:"result",title:title,icon:icon,subtitle:closed ? result.status : "接收中",
                   initiallyOpen:!closed,failed:result.ok == false,motion:options.motion) {
            VStack(alignment:.leading,spacing:10) {
                ForEach(Array(result.fields.enumerated()), id: \.offset) { _, field in
                    VStack(alignment:.leading,spacing:3) {
                        Text(field.key).font(.caption).foregroundStyle(.secondary)
                        if receipt { RichMessageBody(receipt: field.value, options: options) }
                        else { Text(verbatim:field.value).modifier(MessageTextSelection()) }
                    }
                }
                if !result.content.isEmpty {
                    if receipt { RichMessageBody(receipt: result.content, options: options) }
                    else { RichMessageBody(result.content, options:options) }
                } else if result.fields.isEmpty {
                    Text(closed ? "服务端没有返回结果正文。" : "正在接收结果…").font(.callout).foregroundStyle(.secondary)
                }
            }.frame(maxWidth:.infinity,alignment:.leading)
        }
    }
}

/// The timeline owns disclosure; its payload never installs a second header.
struct ToolPayload: View {
    let segment: VCPMarkup.Segment
    let options: RenderOptions
    var streaming = false
    var receipt = false
    var results: [VCPMarkup.Result] = []

    @ViewBuilder var body: some View {
        switch segment {
        case .tool(_, _, let source, _):
            Text(verbatim: source).font(.callout.monospaced()).modifier(MessageTextSelection())
        case .result(let value, let closed):
            resultBody(value, closed: closed, receipt: receipt)
        case .summary(let items, let closed):
            ForEach(Array(items.enumerated()), id: \.offset) { _, item in Text(verbatim: item).font(.callout) }
            ForEach(Array(results.enumerated()), id: \.offset) { _, result in
                Divider()
                HStack {
                    Text(result.tool.isEmpty ? "返回结果" : result.tool).font(.caption.bold())
                    Text(result.status).font(.caption).foregroundStyle(.secondary)
                }
                resultBody(result, closed: true, receipt: true)
            }
            if closed && results.isEmpty { Text("这条摘要没有附带结果正文。").font(.caption).foregroundStyle(.secondary) }
        case .batch(let parts, _):
            ForEach(Array(parts.enumerated()), id: \.offset) { _, part in
                if case .note(let note) = part { valueView(note, receipt: true) }
            }
            if parts.isEmpty { Text("正在接收工具结果").font(.caption) }
        case .text, .think, .diary, .divider, .push:
            VCPCardView(segment: segment, options: options)
        }
    }

    private func resultBody(_ result: VCPMarkup.Result, closed: Bool, receipt: Bool) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(result.fields.enumerated()), id: \.offset) { _, field in
                Text(field.key).font(.caption).foregroundStyle(.secondary)
                valueView(field.value, caption: field.key, receipt: true)
            }
            if !result.content.isEmpty {
                valueView(result.content, receipt: receipt, live: streaming && !closed)
            } else if result.fields.isEmpty {
                Text(closed ? "服务端没有返回结果正文。" : "正在接收结果…").font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder private func valueView(_ value: String, caption: String = "", receipt: Bool, live: Bool = false) -> some View {
        if options.media, let media = ToolPresentation.directMedia(value, caption: caption) {
            NativeMessageMedia(item: media, animations: options.motion)
            if !value.hasPrefix("data:") { Text(verbatim: value).font(.caption).modifier(MessageTextSelection()) }
        } else if receipt {
            RichMessageBody(receipt: value, options: options)
            if options.media, ToolReceiptVideos.mayContainVideo(value) {
                ToolReceiptVideos(source: value, motion: options.motion)
            }
        } else {
            RichMessageBody(value, options: options, streaming: live)
        }
    }
}

/// Receipts are inert. Recognize video links in prose, never in examples or scripts;
/// retain the original receipt text and the existing native image/save path.
struct ToolReceiptVideos: View {
    let source: String
    let motion: Bool
    @State private var videos: [MessageMedia] = []

    static func mayContainVideo(_ value: String) -> Bool {
        ["<video", ".mp4", ".mov", ".m4v", ".webm", ".ogv", "data:video/"].contains { value.localizedCaseInsensitiveContains($0) }
    }

    nonisolated static func extract(_ source: String) -> [MessageMedia] {
        var result: [MessageMedia] = [], seen = Set<String>()
        func append(_ media: MessageMedia?) {
            if let media, media.kind == "video", seen.insert(media.source).inserted { result.append(media) }
        }
        func visit(_ node: any Markup) {
            switch node {
            case let link as Markdown.Link:
                append(MessageMedia(source: link.destination ?? "", caption: link.plainText, videoOnly: true))
            case let image as Markdown.Image:
                append(MessageMedia(source: image.source ?? "", caption: image.plainText, videoOnly: true))
            case let html as HTMLBlock: append(MessageMedia.html(html.rawHTML))
            case let html as InlineHTML: append(MessageMedia.html(html.rawHTML))
            case let text as Markdown.Text:
                for word in text.string.split(whereSeparator: \.isWhitespace) {
                    append(MessageMedia(source: String(word), videoOnly: true))
                }
            default: for child in node.children { visit(child) }
            }
        }
        visit(Document(parsing: source))
        return result
    }

    var body: some View {
        VStack(alignment: .leading) { ForEach(videos) { NativeMessageMedia(item: $0, animations: motion) } }
            .task(id: source) {
                let value = await Self.extractOffMain(source)
                if !Task.isCancelled { videos = value }
            }
    }

    private nonisolated static func extractOffMain(_ source: String) async -> [MessageMedia] { extract(source) }
}

private struct ToolSummary: View {
    let items: [String]; let closed: Bool; let options: RenderOptions
    var results: [VCPMarkup.Result] = []
    var body: some View {
        FoldedCard(kind:"summary",title:"本轮工具调用摘要",icon:"checklist",subtitle:closed ? (results.isEmpty ? "执行状态" : "\(results.count) 份结果") : "接收中",initiallyOpen:!closed,motion:options.motion) {
            VStack(alignment:.leading,spacing:6) {
                ForEach(Array(items.enumerated()),id:\.offset) { _, item in Text(verbatim:item).font(.callout) }
                ForEach(Array(results.enumerated()),id:\.offset) { _, result in
                    Divider()
                    HStack {
                        Text(result.tool.isEmpty ? "返回结果" : result.tool).font(.caption.weight(.semibold))
                        if !result.status.isEmpty { Text(result.status).font(.caption).foregroundStyle(result.ok == false ? Color.red : Color.secondary) }
                    }
                    ForEach(Array(result.fields.enumerated()),id:\.offset) { _, field in
                        Text(field.key).font(.caption).foregroundStyle(.secondary)
                        RichMessageBody(receipt: field.value, options: options)
                    }
                    if !result.content.isEmpty { RichMessageBody(receipt: result.content, options: options) }
                    else if result.fields.isEmpty { Text("没有返回正文。").font(.caption).foregroundStyle(.secondary) }
                }
                if closed && results.isEmpty {
                    Text("这条摘要没有附带结果正文。连接 VCP 时可在「服务器与模型」选择「VCP 工具模式」，对新请求生效。").font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }
}

private struct FoldedCard<Content: View>: View {
    var kind: String; var title: String; var icon: String; var subtitle: String
    var initiallyOpen: Bool; var failed = false; var motion = true
    @ViewBuilder var content: () -> Content
    var body: some View {
        MessageDisclosure(kind:kind,title:title,initiallyOpen:initiallyOpen,motion:motion) {
            HStack(alignment:.firstTextBaseline,spacing:8) {
                Image(systemName:icon).foregroundStyle(failed ? .red : .secondary)
                Text(title).font(.callout.weight(.semibold))
                Spacer(minLength:4)
                if !subtitle.isEmpty { Text(subtitle).font(.caption).foregroundStyle(failed ? .red : .secondary).lineLimit(2) }
            }
        } content: { content().padding(.bottom,10) }
        .padding(.horizontal,12).padding(.vertical,2)
        .background((failed ? Color.red : .secondary).opacity(0.06), in: RoundedRectangle(cornerRadius:14))
    }
}

/// A List disclosure can turn the hosting cell into the disclosure control.
/// Give only the header its own button, keeping adjacent headers and the body independent.
public struct MessageDisclosure<Heading: View, Content: View>: View {
    private let kind: String, title: String, initiallyOpen: Bool, motion: Bool
    private let heading: Heading, content: () -> Content
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var choice: Bool?
    public init(kind: String, title: String, initiallyOpen: Bool = false, motion: Bool = true,
                @ViewBuilder heading: () -> Heading, @ViewBuilder content: @escaping () -> Content) {
        self.kind = kind; self.title = title; self.initiallyOpen = initiallyOpen; self.motion = motion
        self.heading = heading(); self.content = content
    }
    private var expanded: Bool { choice ?? initiallyOpen }
    public var body: some View {
        VStack(alignment:.leading,spacing:4) {
            Button {
                choice = !expanded
            } label: {
                HStack(spacing:8) {
                    heading
                    Spacer(minLength:0)
                    Image(systemName:expanded ? "chevron.down" : "chevron.forward")
                        .font(.caption.weight(.semibold)).foregroundStyle(.secondary).accessibilityHidden(true)
                }.frame(maxWidth:.infinity,minHeight:44,alignment:.leading).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(title).accessibilityValue(expanded ? "已展开" : "已收起")
            if expanded { content() }
        }
        .animation(motion && !reduceMotion ? .easeOut(duration:0.18) : nil,value:expanded)
    }
}
