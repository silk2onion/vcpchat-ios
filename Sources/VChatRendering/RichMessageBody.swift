import SwiftUI
import Observation
import VChatCore
#if os(iOS)
import UIKit
#else
import AppKit
#endif

@MainActor @Observable private final class RenderState {
    var blocks: [RenderBlock] = []
    @ObservationIgnored private var pending: Input?
    @ObservationIgnored private var worker: Task<Void, Never>?
    @ObservationIgnored private var generation = UUID()
    struct Input: Equatable { var source: String; var options: RenderOptions; var dark: Bool; var streaming: Bool; var rules: [RegexRule]; var role: String; var depth: Int }
    func update(_ input: Input) {
        pending = input
        guard worker == nil else { return }
        let id = UUID(); generation = id
        worker = Task {
            while generation == id, let input = pending, !Task.isCancelled {
                pending = nil
                do {
                    let rendered = try await MessageRenderer.shared.render(input.source, options: input.options, dark: input.dark, streaming: input.streaming, rules: input.rules, role: input.role, depth: input.depth)
                    if !Task.isCancelled && generation == id { blocks = rendered }
                    try await Task.sleep(for: .milliseconds(70))
                } catch is CancellationError { break }
                catch { blocks = [.literal("消息渲染失败：" + error.localizedDescription)] }
            }
            if generation == id { worker = nil }
        }
    }
    func cancel() { generation = UUID(); worker?.cancel(); worker = nil; pending = nil }
}
public struct RichMessageBody: View {
    public var source: String
    public var options: RenderOptions
    public var streaming: Bool
    public var rules: [RegexRule]
    public var role: String
    public var depth: Int
    @State private var rendering = RenderState()
    @State private var visible = false
    @Environment(\.colorScheme) private var scheme
    public init(_ source: String, options: RenderOptions = RenderOptions(), streaming: Bool = false, rules: [RegexRule] = [], role: String = "assistant", depth: Int = 0) { self.source = source; self.options = options; self.streaming = streaming; self.rules = rules; self.role = role; self.depth = depth }
    private var plain: Bool { rules.isEmpty && (!options.enabled || (!source.hasPrefix("- ") && !source.contains("\n- ") && !source.contains("\n1. ") && !source.hasPrefix("1. ") && !source.contains(where: { "`~*#_[]<>$|\\".contains($0) }))) }
    public var body: some View {
        Group {
            if plain { Text(verbatim: source).textSelection(.enabled) }
            else if rendering.blocks.isEmpty { Text(verbatim: rules.isEmpty ? source : "…").textSelection(.enabled) }
            else { NativeBlocks(blocks: rendering.blocks, options: options).equatable() }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .onChange(of: RenderState.Input(source: source, options: options, dark: scheme == .dark, streaming: streaming, rules: rules, role: role, depth: depth), initial: true) { _, input in
            if visible && !plain { rendering.update(input) } else { rendering.cancel() }
        }
        .onAppear { visible = true; if !plain { rendering.update(.init(source: source, options: options, dark: scheme == .dark, streaming: streaming, rules: rules, role: role, depth: depth)) } }
        .onDisappear { visible = false; rendering.cancel() }
        .environment(\.openURL, OpenURLAction { url in ["http", "https", "mailto"].contains(url.scheme) ? .systemAction : .discarded })
    }
}
private struct NativeBlocks: View, Equatable {
    var blocks: [RenderBlock]
    var options: RenderOptions
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in blockView(block) }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
    @ViewBuilder func blockView(_ block: RenderBlock) -> some View {
        switch block {
        case .html(let source): HTMLIsland(source: source, options: options)
        case .vcp(let segment): VCPCardView(segment: segment, options: options)
        case .literal(let text): Text(verbatim: text).textSelection(.enabled)
        case .paragraph(let runs): InlineBody(runs: runs)
        case .heading(let level, let text): InlineBody(runs: text).font(level == 1 ? .title2.bold() : level == 2 ? .title3.bold() : .headline)
        case .quote(let blocks): HStack(alignment: .top, spacing: 10) { RoundedRectangle(cornerRadius: 2).fill(.secondary.opacity(0.35)).frame(width: 3); NativeBlocks(blocks: blocks, options: options).foregroundStyle(.secondary) }.fixedSize(horizontal: false, vertical: true)
        case .list(let items, let start):
            VStack(alignment: .leading, spacing: 8) { ForEach(Array(items.enumerated()), id: \.offset) { index, blocks in HStack(alignment: .top, spacing: 8) { Text(start.map { "\($0 + index)." } ?? "•").foregroundStyle(.secondary); NativeBlocks(blocks: blocks, options: options) } } }
        case .rule: Divider()
        case .math(let source): ScrollView(.horizontal) { NativeMath(source).fixedSize().padding(.vertical, 3) }
        case .code(let language, let code, let spans): NativeCode(language: language, source: code, spans: spans)
        case .table(let rows):
            ScrollView(.horizontal) {
                Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 10) {
                    ForEach(Array(rows.enumerated()), id: \.offset) { index, row in
                        GridRow { ForEach(Array(row.enumerated()), id: \.offset) { _, cell in InlineBody(runs: cell).fontWeight(index == 0 ? .semibold : .regular).frame(minWidth: 70, alignment: .leading) } }
                        if index == 0 { Divider().gridCellUnsizedAxes(.horizontal) }
                    }
                }.padding(12)
            }.background(.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 12))
        }
    }
}
private struct NativeCode: View {
    var language: String
    var source: String
    var spans: [CodeSpan]
    var text: AttributedString {
        guard !spans.isEmpty else { return AttributedString(source) }
        var result = AttributedString()
        for span in spans {
            var text = AttributedString(span.text)
            if let c = span.color, c.count == 4 { text.foregroundColor = Color(.sRGB, red: c[0], green: c[1], blue: c[2], opacity: c[3]) }
            result.append(text)
        }
        return result
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack { Text(language.isEmpty ? "代码" : language).font(.caption); Spacer(); CopyCode(source: source) }.foregroundStyle(.secondary).padding(11)
            Divider()
            ScrollView(.horizontal) { Text(text).font(.system(.callout, design: .monospaced)).textSelection(.enabled).fixedSize(horizontal: true, vertical: false).padding(12) }
        }.background(.secondary.opacity(0.07), in: RoundedRectangle(cornerRadius: 12)).overlay(RoundedRectangle(cornerRadius: 12).stroke(.secondary.opacity(0.12)))
    }
}
private struct CopyCode: View {
    var source: String
    @State private var copied = false
    var body: some View {
        Button {
            #if os(iOS)
            UIPasteboard.general.string = source
            #else
            NSPasteboard.general.clearContents(); NSPasteboard.general.setString(source, forType: .string)
            #endif
            copied = true
        } label: { Label(copied ? "已复制" : "复制", systemImage: copied ? "checkmark" : "doc.on.doc") }.buttonStyle(.plain).font(.caption)
    }
}
private struct InlineBody: View {
    var runs: [InlineRun]
    var text: AttributedString {
        runs.reduce(into: AttributedString()) { result, run in if case .text(let text) = run { result.append(text) } }
    }
    var hasMath: Bool { runs.contains { if case .math = $0 { return true }; return false } }
    var pieces: [InlineRun] {
        var pieces: [InlineRun] = []
        for run in runs {
            guard case .text(let text) = run else { pieces.append(run); continue }
            var start = text.startIndex
            for index in text.characters.indices where text.characters[index].isWhitespace {
                let end = text.characters.index(after: index)
                pieces.append(.text(AttributedString(text[start..<end]))); start = end
            }
            if start < text.endIndex { pieces.append(.text(AttributedString(text[start...]))) }
        }
        return pieces
    }
    var body: some View {
        if !hasMath { Text(text).textSelection(.enabled).lineSpacing(4) }
        else {
            InlineFlow {
                ForEach(Array(pieces.enumerated()), id: \.offset) { _, part in
                    switch part { case .text(let value): Text(value).textSelection(.enabled); case .math(let value): NativeMath(value, size: 17).fixedSize() }
                }
            }
        }
    }
}
private struct InlineFlow: Layout {
    func positions(width: CGFloat, subviews: Subviews) -> (CGSize, [CGPoint]) {
        var points: [CGPoint] = []; var x: CGFloat = 0; var y: CGFloat = 0; var row: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(ProposedViewSize(width: width, height: nil))
            if x > 0 && x + size.width > width { x = 0; y += row + 3; row = 0 }
            points.append(CGPoint(x: x, y: y)); x += size.width; row = max(row, size.height)
        }
        return (CGSize(width: width, height: y + row), points)
    }
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize { positions(width: proposal.width ?? 350, subviews: subviews).0 }
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let (_, points) = positions(width: bounds.width, subviews: subviews)
        for (view, point) in zip(subviews, points) { view.place(at: CGPoint(x: bounds.minX + point.x, y: bounds.minY + point.y), anchor: .topLeading, proposal: ProposedViewSize(width: bounds.width, height: nil)) }
    }
}
