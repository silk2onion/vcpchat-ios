import Foundation
import Markdown
import VChatCore
import Highlighter
#if os(iOS)
import UIKit
#else
import AppKit
#endif

public actor MessageRenderer {
    public static let shared = MessageRenderer()
    private var highlighter: Highlighter?
    private var dark = false
    private var streaming = false
    private var diagrams = DiagramCache()
    private var links: NSDataDetector?
    public init() {}
    private struct MathToken { var token: String; var latex: String; var original: String; var block: Bool }
    private var mathTokens: [MathToken] = []
    public func render(_ source: String, options: RenderOptions, dark: Bool, streaming: Bool = false, rules: [RegexRule] = [], role: String = "assistant", depth: Int = 0) async throws -> [RenderBlock] {
        try Task.checkCancellation()
        let source = rules.isEmpty ? source : try await RegexEngine.shared.apply(source, rules: rules, scope: "frontend", role: role, depth: depth)
        guard options.enabled else { return [.literal(source)] }
        self.streaming = streaming
        var output: [RenderBlock] = []
        for segment in VCPMarkup.parse(source, protectingHTMLLiterals: HTMLIslandPolicy.accepts(source)) {
            switch segment {
            case .text(let prose):
                if let island = island(prose,options: options) { output.append(island) }
                else { output += try markdown(prose, options: options, dark: dark) }
            default: output.append(.vcp(segment))
            }
        }
        return output
    }
    private func island(_ source: String,options: RenderOptions) -> RenderBlock? {
        guard HTMLIslandPolicy.accepts(source) else { return nil }
        return options.html ? .html(source) : .literal(source)
    }
    private func markdown(_ source: String, options: RenderOptions, dark: Bool) throws -> [RenderBlock] {
        self.dark = dark
        mathTokens = []
        let text = source as NSString
        let full = NSRange(location: 0, length: text.length)
        let codes = (try? NSRegularExpression(pattern: #"(?s)(`+).*?\1|~~~.*?~~~|!?\[[^\]]*\]\([^)]*\)|<https?://[^>]*>"#))?.matches(in: source, range: full).map(\.range) ?? []
        let regex = try NSRegularExpression(pattern: #"(?s)\$\$(.*?)\$\$|\\\[(.*?)\\\]|(?<!\\)\$(?!\s)([^$\n]*?[^$\s])\$(?!\d)|\\\((.*?)\\\)"#)
        let namespace = UUID().uuidString.replacingOccurrences(of: "-", with: "")
        let matches = regex.matches(in: source, range: full).filter { match in !codes.contains { NSIntersectionRange($0, match.range).length > 0 } }
        var protected = source
        for (index, match) in matches.enumerated().reversed() {
            let capture = (1..<match.numberOfRanges).first { match.range(at: $0).location != NSNotFound }!
            let token = "\u{E000}" + namespace + "M" + String(index) + "\u{E001}"
            let original = text.substring(with: match.range)
            mathTokens.append(MathToken(token: token, latex: text.substring(with: match.range(at: capture)), original: original, block: capture <= 2))
            if let range = Range(match.range, in: protected) { protected.replaceSubrange(range, with: token) }
        }
        return try blocks(Document(parsing: protected), options: options)
    }
    private func blocks(_ container: any Markup, options: RenderOptions) throws -> [RenderBlock] {
        try container.children.map { node in
            try Task.checkCancellation()
            switch node {
            case let node as Heading: return .heading(node.level, inline(node, options: options))
            case let node as CodeBlock:
                let language = node.language ?? ""
                if options.mermaid,!streaming,["mermaid","flowchart","graph"].contains(language.lowercased()) {
                    var text = restore(node.code)
                    if language.lowercased() != "mermaid",!text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased().hasPrefix("flowchart"),!text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased().hasPrefix("graph") { text = language.lowercased() + " " + text }
                    return .diagram(text,diagrams.render(text,dark: dark))
                }
                return .code(language, restore(node.code), options.code ? highlighted(restore(node.code), language: language) : [])
            case let node as BlockQuote: return .quote(try blocks(node, options: options))
            case let node as OrderedList: return .list(try node.children.map { try blocks($0, options: options) }, Int(node.startIndex))
            case let node as UnorderedList: return .list(try node.children.map { try blocks($0, options: options) }, nil)
            case let node as Table:
                let head = node.head.cells.map { self.inline($0, options: options) }
                let rows = node.body.rows.map { row in row.cells.map { self.inline($0, options: options) } }
                return .table([Array(head)] + rows.map(Array.init))
            case is ThematicBreak: return .rule
            case let node as HTMLBlock:
                let raw = restore(node.rawHTML)
                if options.media,let media = MessageMedia.html(raw) { return .paragraph([.media(media)]) }
                return .literal(raw)
            default:
                let content = node.children.map { $0.detachedFromParent.format() }.joined().trimmingCharacters(in: .whitespacesAndNewlines)
                if let math = mathTokens.first(where: { $0.token == content && $0.block }) { return options.math ? .math(math.latex) : .literal(math.original) }
                return .paragraph(inline(node, options: options))
            }
        }
    }
    private func restore(_ text: String) -> String { mathTokens.reduce(text) { $0.replacingOccurrences(of: $1.token, with: $1.original) } }
    private func inline(_ node: any Markup, options: RenderOptions) -> [InlineRun] {
        if node.childCount == 0 { return inlineSource(node.detachedFromParent.format(),options: options) }
        var result: [InlineRun] = [],buffer = ""
        func flush() { if !buffer.isEmpty { result += inlineSource(buffer,options: options); buffer = "" } }
        for child in node.children {
            if let image = child as? Markdown.Image {
                flush(); let caption = image.children.map { $0.detachedFromParent.format() }.joined()
                if options.media,let media = MessageMedia(source: image.source ?? "",caption: caption) { result.append(.media(media)) }
                else { result.append(.text(AttributedString("图片：" + (caption.isEmpty ? image.source ?? "未命名" : caption)))) }
            } else if let link = child as? Markdown.Link,options.media,let media = MessageMedia(source: link.destination ?? "",caption: link.children.map { $0.detachedFromParent.format() }.joined(),videoOnly: true) {
                flush(); result.append(.media(media))
            } else if let html = child as? InlineHTML,options.media,let media = MessageMedia.html(html.rawHTML) {
                flush(); result.append(.media(media))
            } else if containsMedia(child,videos: options.media) { flush(); result += inline(child,options: options) }
            else { buffer += child.detachedFromParent.format() }
        }
        flush(); return result
    }
    private func containsMedia(_ node: any Markup,videos: Bool) -> Bool {
        node is Markdown.Image || (videos && (node as? Markdown.Link).map { MessageMedia.isVideo($0.destination ?? "") } == true) || node.children.contains { containsMedia($0,videos: videos) }
    }
    private func inlineSource(_ source: String,options: RenderOptions) -> [InlineRun] {
        let attributed = (try? AttributedString(markdown: source, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(source)
        let found = mathTokens.compactMap { token -> (Range<AttributedString.Index>, MathToken)? in attributed.range(of: token.token).map { ($0, token) } }.sorted { $0.0.lowerBound < $1.0.lowerBound }
        var result: [InlineRun] = []; var cursor = attributed.startIndex
        for (range, token) in found {
            if cursor < range.lowerBound { result.append(.text(AttributedString(attributed[cursor..<range.lowerBound]))) }
            result.append(options.math ? .math(token.latex) : .text(AttributedString(token.original)))
            cursor = range.upperBound
        }
        if cursor < attributed.endIndex { result.append(.text(AttributedString(attributed[cursor...]))) }
        return result.flatMap { run in if case .text(let value) = run { return linkedText(value,options: options) }; return [run] }
    }
    private func linkedText(_ value: AttributedString,options: RenderOptions) -> [InlineRun] {
        var attributed = value
        let text = String(attributed.characters)
        guard text.contains("://") || text.contains("@") else { return [.text(value)] }
        if links == nil { links = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) }
        let found = (links?.matches(in: text,range: NSRange(text.startIndex...,in: text)) ?? []).compactMap { match -> (Range<AttributedString.Index>,URL)? in
            guard let url = match.url,["http","https","mailto"].contains(url.scheme),let range = Range(match.range,in: text),let lower = AttributedString.Index(range.lowerBound,within: attributed),let upper = AttributedString.Index(range.upperBound,within: attributed) else { return nil }
            guard attributed[lower..<upper].inlinePresentationIntent?.contains(.code) != true else { return nil }
            return (lower..<upper,url)
        }
        for (range,url) in found { if attributed[range].link == nil { attributed[range].link = url } }
        var result: [InlineRun] = [],cursor = attributed.startIndex
        for (range,url) in found where options.media && attributed[range].link == url && MessageMedia.isVideo(url.absoluteString) {
            guard let media = MessageMedia(source: url.absoluteString,videoOnly: true) else { continue }
            if cursor < range.lowerBound { result.append(.text(AttributedString(attributed[cursor..<range.lowerBound]))) }; result.append(.media(media)); cursor = range.upperBound
        }
        if cursor < attributed.endIndex { result.append(.text(AttributedString(attributed[cursor...]))) }; return result
    }
    private func highlighted(_ code: String, language: String) -> [CodeSpan] {
        if highlighter == nil { highlighter = Highlighter() }
        _ = highlighter?.setTheme(dark ? "atom-one-dark" : "atom-one-light")
        guard let value = highlighter?.highlight(code, as: language.isEmpty ? nil : language) else { return [] }
        var spans: [CodeSpan] = []
        value.enumerateAttribute(.foregroundColor, in: NSRange(location: 0, length: value.length)) { color, range, _ in
            var rgba: [Double]?
            #if os(iOS)
            if let color = color as? UIColor { var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0; if color.getRed(&r, green: &g, blue: &b, alpha: &a) { rgba = [Double(r), Double(g), Double(b), Double(a)] } }
            #else
            if let color = (color as? NSColor)?.usingColorSpace(.deviceRGB) { rgba = [Double(color.redComponent), Double(color.greenComponent), Double(color.blueComponent), Double(color.alphaComponent)] }
            #endif
            spans.append(CodeSpan(text: (value.string as NSString).substring(with: range), color: rgba))
        }
        return spans
    }
}
