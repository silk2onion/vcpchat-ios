import Foundation

/// Relax quoted CJK strong-emphasis boundaries without rewriting stored messages.
/// Letter sentinels let both Markdown parsers apply their normal nesting rules;
/// they are removed from attributed output before anything reaches the screen.
enum MarkdownStrongCompatibility {
    static func prepare(_ source: String, marker: String, escapedStar: String) -> String {
        guard source.contains("**") || source.contains("\\*") else { return source }
        let text = source as NSString
        var protected: [NSRange] = []
        var fence: (start: Int, character: String, count: Int)?
        var offset = 0
        func match(_ pattern: String,_ value: String) -> NSTextCheckingResult? {
            (try? NSRegularExpression(pattern: pattern))?.firstMatch(in: value,range: NSRange(value.startIndex...,in: value))
        }
        for raw in source.components(separatedBy: "\n") {
            let line = raw.hasSuffix("\r") ? String(raw.dropLast()) : raw
            if let opened = fence {
                if let m = match("^ {0,3}(`+|~+)[ \\t]*$",line) {
                    let run = (line as NSString).substring(with: m.range(at: 1))
                    if run.hasPrefix(opened.character),run.count >= opened.count {
                        protected.append(NSRange(location: opened.start,length: min(text.length,offset + raw.utf16.count + 1) - opened.start)); fence = nil
                    }
                }
            } else if let m = match("^ {0,3}(`{3,}|~{3,})(.*)$",line) {
                let run = (line as NSString).substring(with: m.range(at: 1))
                let info = (line as NSString).substring(with: m.range(at: 2))
                if !run.hasPrefix("`") || !info.contains("`") { fence = (offset,String(run.prefix(1)),run.count) }
            } else if line.hasPrefix("    ") || line.hasPrefix("\t") { protected.append(NSRange(location: offset,length: raw.utf16.count)) }
            offset += raw.utf16.count + 1
        }
        if let fence { protected.append(NSRange(location: fence.start,length: text.length - fence.start)) }
        // Inline code, escapes, HTML attributes/literals and link destinations are opaque.
        let opaque = #"(?s)(`+).*?\1|<(script|style|pre|code|textarea)\b[^>]*>.*?(?:</\2\s*>|$)|<!--.*?(?:-->|$)|<[^>\n]*>|\]\([^\n)]*\)"#
        if let regex = try? NSRegularExpression(pattern: opaque,options: .caseInsensitive) {
            protected += regex.matches(in: source,range: NSRange(location: 0,length: text.length)).map(\.range)
        }
        let pattern = #"(?<![\\*])\*\*(?!\*)([^\n]+?)(?<![\\*])\*\*(?!\*)"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return source }
        let punctuation = CharacterSet(charactersIn: "\"'“”‘’「」『』《》〈〉【】（）［］｛｝〔〕〖〗！？。，；：")
        let cjk = try? NSRegularExpression(pattern: #"[\p{Han}\p{Hiragana}\p{Katakana}\p{Hangul}]"#)
        var changes: [(NSRange,String)] = []
        for m in regex.matches(in: source,range: NSRange(location: 0,length: text.length)).reversed() {
            let end = NSMaxRange(m.range) - 2
            guard !protected.contains(where: { NSLocationInRange(m.range.location,$0) || NSLocationInRange(end,$0) }) else { continue }
            let content = text.substring(with: m.range(at: 1))
            guard let first = content.unicodeScalars.first,let last = content.unicodeScalars.last,
                  !CharacterSet.whitespaces.contains(first),!CharacterSet.whitespaces.contains(last),
                  punctuation.contains(first) || punctuation.contains(last),
                  cjk?.firstMatch(in: content,range: NSRange(content.startIndex...,in: content)) != nil else { continue }
            changes.append((NSRange(location: m.range.location + 2,length: 0),marker))
            changes.append((NSRange(location: end,length: 0),marker))
        }
        // Preserve escaped asterisks through Swift Markdown -> Foundation's
        // second inline parse. Otherwise that parse can turn literal ** into bold.
        if let escapes = try? NSRegularExpression(pattern: #"(?<!\\)\\\*"#) {
            for m in escapes.matches(in: source,range: NSRange(location: 0,length: text.length)) where !protected.contains(where: { NSLocationInRange(m.range.location,$0) }) {
                changes.append((m.range,escapedStar))
            }
        }
        var result = source
        for (range,value) in changes.sorted(by: { $0.0.location > $1.0.location }) {
            if let range = Range(range,in: result) { result.replaceSubrange(range,with: value) }
        }
        return result
    }
}
