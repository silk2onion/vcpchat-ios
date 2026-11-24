import Foundation

/// VCP display envelopes are data, never executable tool commands.
public enum VCPMarkup {
    public struct Field: Sendable, Equatable { public var key: String; public var value: String }
    public struct Diary: Sendable, Equatable {
        public var update: Bool; public var agent: String; public var label: String
        public var title: String; public var date: String; public var folder: String
        public var content: String; public var target: String; public var replacement: String; public var tag: String
    }
    public struct Result: Sendable, Equatable {
        public var tool: String; public var status: String; public var ok: Bool?
        public var fields: [Field]; public var content: String
    }
    public enum Receipt: Sendable, Equatable {
        case note(String), summary([String], Bool), result(Result, Bool)
    }
    public enum Segment: Sendable, Equatable {
        case batch([Receipt], Bool)
        case text(String)
        case think(String, String, Bool)
        case tool(String, String, String, Bool)
        case diary(Diary, Bool)
        case result(Result, Bool)
        case summary([String], Bool)
        case divider(String, Bool)
        case push(String, Bool)
    }
    private static let resultStart = "[[VCP调用结果信息汇总:"
    private static let resultEnd = "VCP调用结果结束]]"
    private static let markers = ["<think>", "<thinking>", "<<<[TOOL_REQUEST]>>>", resultStart, "<<<DailyNoteStart>>>", "[--- VCP元思考链", "[本轮工具调用摘要:]", "<<<[DESKTOP_PUSH]>>>", "<<<[ROLE_DIVIDE_", "<<<[END_ROLE_DIVIDE_"]
    private static func match(_ pattern: String, _ text: String, options: NSRegularExpression.Options = []) -> [String]? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: options), let m = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) else { return nil }
        let s = text as NSString
        return (0..<m.numberOfRanges).map { m.range(at: $0).location == NSNotFound ? "" : s.substring(with: m.range(at: $0)) }
    }
    public static func field(_ body: String, _ name: String, streaming: Bool = false) -> String {
        let prefix = "(?:^|[\\s,，])" + NSRegularExpression.escapedPattern(for: name) + "\\s*[:：]\\s*"
        let open = "(?:「始(?:escape)?」|\\{始(?:escape)?\\})", close = "(?:「末(?:escape)?」|\\{末(?:escape)?\\})"
        if let m = match(prefix + open + "([\\s\\S]*?)" + close, body, options: .caseInsensitive) { return m[1].trimmingCharacters(in: .whitespacesAndNewlines) }
        if streaming, let m = match(prefix + open + "([\\s\\S]*)$", body, options: .caseInsensitive) { return m[1].trimmingCharacters(in: .whitespacesAndNewlines) }
        return match("(?:^|\\n)\\s*" + NSRegularExpression.escapedPattern(for: name) + "\\s*[:：]\\s*([^\\n,]+)", body, options: .caseInsensitive)?[1].trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }
    private static func fences(_ source: String) -> [NSRange] {
        var ranges: [NSRange] = []; var opened: (Int, String, Int)?; var offset = 0
        for raw in source.components(separatedBy: "\n") {
            let line = raw.hasSuffix("\r") ? String(raw.dropLast()) : raw
            if let (start, marker, count) = opened {
                if let m = match("^ {0,3}(`+|~+)[ \\t]*$", line), m[1].hasPrefix(marker), m[1].count >= count { ranges.append(NSRange(location: start, length: min((source as NSString).length, offset + raw.utf16.count + 1) - start)); opened = nil }
            } else if let m = match("^ {0,3}(`{3,}|~{3,})(.*)$", line), !(m[1].hasPrefix("`") && m[2].contains("`")) { opened = (offset, String(m[1].prefix(1)), m[1].count) }
            offset += raw.utf16.count + 1
        }
        if let (start, _, _) = opened { ranges.append(NSRange(location: start, length: source.utf16.count - start)) }
        return ranges
    }
    public static func parse(_ source: String, protectingHTMLLiterals: Bool = false, streaming: Bool = false) -> [Segment] {
        var output: [Segment] = []
        for domain in ToolBatchMarkup.split(source, streaming: streaming) {
            switch domain {
            case .prose(let prose):
                // Older servers omit the batch envelope but put its summary
                // directly after the results. Never associate across prose or a call.
                var preceding: [Receipt] = []
                func flushResults() {
                    for case .result(let value, let done) in preceding { output.append(.result(value, done)) }
                    preceding.removeAll(keepingCapacity: true)
                }
                for block in parseLegacy(prose, tokens: protectingHTMLLiterals ? proseWithHTML : proseTokens) {
                    switch block {
                    case .result(let value, let done): preceding.append(.result(value, done))
                    case .summary(let items, let done) where !preceding.isEmpty:
                        output.append(.batch(preceding + [.summary(items, done)], done)); preceding.removeAll(keepingCapacity: true)
                    default: flushResults(); output.append(block)
                    }
                }
                flushResults()
            case .receipt(let body, let closed):
                // Only summaries and results are structural inside a receipt; other tool output is inert text.
                let parts: [Receipt] = parseLegacy(body, tokens: receiptTokens).compactMap {
                    switch $0 {
                    case .text(let text): return .note(text.trimmingCharacters(in:.whitespacesAndNewlines))
                    case .summary(let items, let complete): return items.isEmpty ? nil : .summary(items,complete)
                    case .result(let result, let complete): return .result(result,complete)
                    default: return nil
                    }
                }
                if !parts.isEmpty || !closed { output.append(.batch(parts,closed)) }
            }
        }
        return output
    }
    // Match whole backtick runs within a paragraph. A tag mentioned in Markdown
    // code is text, so it must never start an HTML range outside that code span.
    private static let inlineCode = #"(?<![\\`])(`++)(?:(?!\r?\n[ \t]*\r?\n)[\s\S])*?(?<!`)\1(?!`)"#
    private static func tokens(_ markers: [String], html: Bool) -> NSRegularExpression {
        let raw = #"(?i:<!--|<(script|style|pre|code|textarea)\b(?:"[^"]*"|'[^']*'|[^'">])*>)"#
        let protocolTokens = markers.map { NSRegularExpression.escapedPattern(for: $0) }.joined(separator: "|")
        return try! NSRegularExpression(pattern: inlineCode + "|" + (html ? raw + "|" : "") + protocolTokens)
    }
    private static let proseTokens = tokens(markers, html: false)
    private static let proseWithHTML = tokens(markers, html: true)
    private static let receiptTokens = tokens([resultStart, "[本轮工具调用摘要:]"], html: true)
    private static let closingTags = Dictionary(uniqueKeysWithValues: ["script","style","pre","code","textarea"].map {
        ($0, try! NSRegularExpression(pattern: "</" + $0 + #"\s*>"#, options: .caseInsensitive))
    })

    private static func parseLegacy(_ source: String, tokens: NSRegularExpression) -> [Segment] {
        let s = source as NSString
        var result: [Segment] = [], cursor = 0, textFrom = 0
        // Scan in source order: inline code cannot open HTML, HTML cannot open
        // tools, and a tool's payload cannot hide the next sibling block.
        for fence in fences(source) + [NSRange(location: s.length, length: 0)] {
            guard fence.location >= cursor else { continue } // inside a consumed payload
            while cursor < fence.location {
                let gap = NSRange(location: cursor, length: fence.location - cursor)
                guard let token = tokens.firstMatch(in: source, options: [.withTransparentBounds], range: gap) else { break }
                let at = token.range.location
                cursor = NSMaxRange(token.range)
                if token.range(at: 1).location != NSNotFound { continue } // inline code
                let marker = s.substring(with: token.range)
                let remaining = NSRange(location: cursor, length: s.length - cursor)
                if marker == "<!--" {
                    let end = s.range(of: "-->", range: remaining)
                    cursor = end.location == NSNotFound ? s.length : NSMaxRange(end)
                } else if token.numberOfRanges > 2, token.range(at: 2).location != NSNotFound {
                    let tag = s.substring(with: token.range(at: 2)).lowercased()
                    let end = closingTags[tag]?.firstMatch(in: source, range: remaining)
                    cursor = end.map { NSMaxRange($0.range) } ?? s.length
                } else if let (segment, end) = parseOne(s, marker: marker, at: at) {
                    let prose = s.substring(with: NSRange(location: textFrom, length: at - textFrom))
                    if !prose.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { result.append(.text(prose)) }
                    result.append(segment); cursor = end; textFrom = end
                }
            }
            if cursor <= fence.location { cursor = NSMaxRange(fence) }
        }
        if textFrom < s.length { let text = s.substring(from: textFrom); if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { result.append(.text(text)) } }
        return result
    }
    private static func parseOne(_ s: NSString, marker: String, at: Int) -> (Segment, Int)? {
        var start = at + marker.utf16.count
        var title = "思考过程"
        if marker.contains("ROLE_DIVIDE_") {
            guard let m = match("^<<<\\[(END_)?ROLE_DIVIDE_(SYSTEM|ASSISTANT|USER)\\]>>>", s.substring(from: at)) else { return nil }
            return (.divider(m[2].lowercased(), !m[1].isEmpty), at + m[0].utf16.count)
        }
        if marker == "[--- VCP元思考链" {
            guard let m = match("^\\[--- VCP元思考链(?::\\s*\"([^\"]*)\")?\\s*---\\][ \\t]*\\r?\\n?", s.substring(from: at)) else { return nil }
            start = at + m[0].utf16.count; title = m[1].isEmpty ? "元思考链" : m[1]
        }
        let close: String = switch marker {
        case "<think>": "</think>"; case "<thinking>": "</thinking>"
        case "<<<DailyNoteStart>>>": "<<<DailyNoteEnd>>>"
        case "[--- VCP元思考链": "[--- 元思考链结束 ---]"
        case "[本轮工具调用摘要:]": "[本轮工具调用摘要结束]"
        case "<<<[DESKTOP_PUSH]>>>": "<<<[DESKTOP_PUSH_END]>>>"
        case resultStart: resultEnd
        default: ""
        }
        var end: NSRange
        if marker == "<<<[TOOL_REQUEST]>>>" {
            let tail = s.substring(from: start)
            end = (try? NSRegularExpression(pattern: "<{2,4}\\[END_TOOL_REQUEST\\]>{2,4}"))?.firstMatch(in: tail, range: NSRange(location: 0, length: tail.utf16.count))?.range ?? NSRange(location: NSNotFound, length: 0)
            if end.location != NSNotFound { end.location += start }
        } else if marker == resultStart {
            var depth = 1, offset = start; end = NSRange(location: NSNotFound, length: 0)
            while offset < s.length {
                let search = NSRange(location: offset, length: s.length - offset), a = s.range(of: resultStart, range: search), b = s.range(of: resultEnd, range: search)
                if b.location == NSNotFound { break }
                if a.location != NSNotFound && a.location < b.location { depth += 1; offset = NSMaxRange(a) }
                else { depth -= 1; if depth == 0 { end = b; break }; offset = NSMaxRange(b) }
            }
        } else { end = s.range(of: close, range: NSRange(location: start, length: s.length - start)) }
        let closed = end.location != NSNotFound, body = s.substring(with: NSRange(location: start, length: (closed ? end.location : s.length) - start)).trimmingCharacters(in: .whitespacesAndNewlines)
        let next = closed ? NSMaxRange(end) : s.length
        switch marker {
        case "<think>", "<thinking>", "[--- VCP元思考链": return (.think(title, body, closed), next)
        case resultStart: return (.result(resultFields(body), closed), next)
        case "<<<[TOOL_REQUEST]>>>":
            let name = field(body, "tool_name"), command = field(body, "command")
            if name.lowercased() == "dailynote", let diary = diary(body, command: command) { return (.diary(diary, closed), next) }
            return (.tool(name.isEmpty ? "工具调用" : name, command, body, closed), next)
        case "<<<DailyNoteStart>>>":
            let agent = field(body, "Maid"), date = field(body, "Date")
            let content = match("Content:\\s*([\\s\\S]*)", body)?[1] ?? body
            return (.diary(Diary(update: false, agent: agent, label: "Maid", title: "Maid's Diary", date: date, folder: "", content: content, target: "", replacement: "", tag: ""), closed), next)
        case "[本轮工具调用摘要:]":
            let items = body.components(separatedBy: .newlines).map { $0.replacingOccurrences(of: "^\\s*[-*•\\d.、]+\\s*", with: "", options: .regularExpression).trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            return (.summary(items, closed), next)
        default: return (.push(body, closed), next)
        }
    }
    private static func diary(_ body: String, command: String) -> Diary? {
        let content = field(body, "Content", streaming: true), target = field(body, "target", streaming: true), replacement = field(body, "replace", streaming: true)
        let update = command.lowercased() == "update" || (command.isEmpty && !target.isEmpty && !replacement.isEmpty)
        guard update || command.lowercased() == "create" || (command.isEmpty && !content.isEmpty) else { return nil }
        let valet = field(body, "valet").isEmpty ? field(body, "valetName") : field(body, "valet")
        let maid = field(body, "maid").isEmpty ? field(body, "maidName") : field(body, "maid")
        let label = valet.isEmpty ? "Maid" : "Valet", name = field(body, "fileName")
        return Diary(update: update, agent: valet.isEmpty ? maid : valet, label: label, title: name.isEmpty ? "\(label)'s Diary" : name, date: field(body, "Date"), folder: field(body, "folder"), content: update ? "" : content, target: update ? target : "", replacement: update ? replacement : "", tag: field(body, "Tag"))
    }
    public static func resultFields(_ source: String) -> Result {
        let textKeys = ["返回内容", "内容", "Result", "返回结果", "output"]
        let known = ["工具名称", "执行状态", "命令", "参数", "可访问URL", "url", "image"] + textKeys
        var fields: [Field] = [], content: [String] = []
        var inOutput = false
        for line in source.replacingOccurrences(of:"\r\n",with:"\n").components(separatedBy:"\n") {
            // VCP puts the plugin's return value last. Its Markdown bullets, JSON
            // and status-looking lines are payload, not a second set of headers.
            if inOutput { content.append(line); continue }
            if let m = match("^\\s*-?\\s*([^:：\\n]{1,24}?)\\s*[:：]\\s?(.*)$", line) {
                let key = m[1].trimmingCharacters(in:.whitespaces)
                if textKeys.contains(key) { inOutput = true; content.append(m[2]); continue }
                if known.contains(key) || match("^\\s*-\\s", line) != nil {
                    fields.append(Field(key:key,value:m[2])); continue
                }
            }
            if let last = fields.last, !["工具名称","执行状态"].contains(last.key) {
                fields[fields.count - 1].value += "\n" + line
            } else { content.append(line) }
        }
        fields = fields.map { Field(key: $0.key, value: $0.value.trimmingCharacters(in: .whitespacesAndNewlines)) }
        let status = fields.first { $0.key == "执行状态" }?.value ?? ""
        let ok: Bool? = status.isEmpty ? nil : (match("❌|error|fail|失败", status, options: .caseInsensitive) != nil ? false : match("✅|success|成功", status, options: .caseInsensitive) != nil)
        return Result(tool: fields.first { $0.key == "工具名称" }?.value ?? "", status: status, ok: ok, fields: fields.filter { !["工具名称", "执行状态"].contains($0.key) }, content: content.joined(separator:"\n").trimmingCharacters(in:.whitespacesAndNewlines))
    }
}
