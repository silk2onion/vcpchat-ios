import Foundation

public struct HostedCall: Codable, Equatable, Sendable {
    public struct Function: Codable, Equatable, Sendable {
        public var name = ""
        public var arguments = ""
    }
    public var id = ""
    public var type = ""
    public var function = Function()
}

public enum HostedSegment: Codable, Equatable, Sendable {
    case text(String), receipt(String), calls([HostedCall])
    var content: String? { switch self { case .text(let s), .receipt(let s): s; case .calls: nil } }
    private enum Keys: String, CodingKey { case content, tool_calls, receipt }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        if c.contains(.tool_calls) { self = .calls(try c.decode([HostedCall].self, forKey: .tool_calls)) }
        else { let text = try c.decode(String.self, forKey: .content); self = (try c.decodeIfPresent(Bool.self, forKey: .receipt)) == true ? .receipt(text) : .text(text) }
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: Keys.self)
        switch self { case .text(let text): try c.encode(text, forKey: .content)
        case .receipt(let text): try c.encode(text, forKey: .content); try c.encode(true, forKey: .receipt)
        case .calls(let calls): try c.encode(calls, forKey: .tool_calls) }
    }
}

public enum HostedHistory {
    static func valid(_ calls: [HostedCall]) -> Bool {
        !calls.isEmpty && Set(calls.map(\.id)).count == calls.count && calls.allSatisfy {
            !$0.id.isEmpty && $0.type == "function" && !$0.function.name.isEmpty && !$0.function.arguments.isEmpty
        }
    }
    static func callBytes(_ segments: [HostedSegment]?) -> Int {
        (segments ?? []).reduce(0) { sum, segment in
            guard case .calls(let calls) = segment else { return sum }
            return calls.reduce(sum) { $0 + $1.id.utf8.count + $1.type.utf8.count + $1.function.name.utf8.count + $1.function.arguments.utf8.count }
        }
    }
    public static func joining(_ prefix: [HostedSegment]?, text: String, tail: [HostedSegment]?, suffix: String) -> [HostedSegment]? {
        guard prefix != nil || tail != nil else { return nil }
        if prefix == nil && text.isEmpty { return tail }
        var result = prefix ?? (text.isEmpty ? [] : [.text(text)])
        let more = tail ?? (suffix.isEmpty ? [] : [.text(suffix)])
        guard case .text(let first) = more.first else { return result + more }
        let combined: String
        if case .text(let last) = result.last { result.removeLast(); combined = last + first } else { combined = first }
        if case .calls = result.last, let sealed = receipt(combined) {
            result.append(.receipt(sealed.raw))
            if !sealed.rest.isEmpty { result.append(.text(sealed.rest)) }
        } else { result.append(.text(combined)) }
        return result + more.dropFirst()
    }

    // Match a receipt only at the start of the text immediately after a batch.
    private static let header = try! NSRegularExpression(pattern: #"^\s*(?:(<<<\[ROLE_DIVIDE_USER\]>>>)\s*)?(<<<\[VCP_TOOL_BATCH_START:([^\]\r\n]{1,128})\]>>>)"#)
    private static let shellEnd = try! NSRegularExpression(pattern: #"^\s*<<<\[END_ROLE_DIVIDE_USER\]>>>[ \t]*(?:\r?\n|$)"#)
    static func receipt(_ text: String) -> (body: String, rest: String, raw: String)? {
        let ns = text as NSString
        guard let m = header.firstMatch(in: text, range: NSRange(location: 0, length: ns.length)) else { return nil }
        let start = NSMaxRange(m.range), id = ns.substring(with: m.range(at: 3))
        let close = ns.range(of: "<<<[VCP_TOOL_BATCH_END:" + id + "]>>>", options: .literal, range: NSRange(location: start,length: ns.length-start))
        guard close.location != NSNotFound else { return nil }
        let end = NSMaxRange(close)
        var boundary = end
        var rest = ns.substring(from: end)
        if m.range(at: 1).location != NSNotFound {
            guard let shell = shellEnd.firstMatch(in: rest,range: NSRange(rest.startIndex...,in: rest)) else { return nil }
            boundary += NSMaxRange(shell.range)
            rest = (rest as NSString).substring(from: NSMaxRange(shell.range))
        }
        return (ns.substring(with: NSRange(location: m.range(at: 2).location,length: end - m.range(at: 2).location)),rest,ns.substring(to: boundary))
    }
    public static func replay(_ segments: [HostedSegment]) -> [ChatTurn] {
        var turns: [ChatTurn] = [], prose = "", pending: [HostedCall]?, following = ""
        func flushText() {
            if !prose.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { turns.append(ChatTurn(role: "assistant", content: prose)) }
            prose = ""
        }
        func closeBatch() {
            guard let calls = pending else { return }
            defer { pending = nil; following = "" }
            if valid(calls), let sealed = receipt(following) {
                var assistant = ChatTurn(role: "assistant",content: prose); assistant.toolCalls = calls; turns.append(assistant)
                for call in calls { var tool = ChatTurn(role: "tool",content: "原始结果保留上下文摘要"); tool.toolCallID = call.id; turns.append(tool) }
                turns.append(ChatTurn(role: "user",content: sealed.body)); prose = sealed.rest
            } else {
                flushText()
                let tail = following.trimmingCharacters(in: .whitespacesAndNewlines)
                let markers = ["<<<[ROLE_DIVIDE_USER]", "<<<[VCP_TOOL_BATCH_START:"]
                if !markers.contains(where: { tail.hasPrefix($0) || $0.hasPrefix(tail) }) { prose = following }
            }
        }
        for segment in segments {
            switch segment {
            case .text(let value): if pending == nil { prose += value } else { following += value }
            case .receipt(let value): if pending == nil { prose += value } else { following += value; closeBatch() }
            case .calls(let calls): closeBatch(); pending = calls
            }
        }
        closeBatch(); flushText(); return turns
    }

    // A flat text edit changes the overlapping text ranges, not the call IDs.
    public static func edited(_ segments: [HostedSegment]?, from old: String, to new: String) -> [HostedSegment]? {
        guard let segments, old != new else { return segments }
        let prefix = old.commonPrefix(with: new, options: .literal)
        let a = old.dropFirst(prefix.count), b = new.dropFirst(prefix.count)
        let suffix = zip(a.reversed(), b.reversed()).prefix(while: { $0 == $1 }).count
        let start = prefix.count, end = old.count - suffix, insertion = String(b.dropLast(suffix))
        var offset = 0, placed = false, result: [HostedSegment] = []
        for segment in segments {
            guard let value = segment.content else { result.append(segment); continue }
            let length = value.count, next = offset + length
            defer { offset = next }
            if next > start && offset < end || !placed && start >= offset && start < next {
                let lo = max(0, start-offset), hi = min(length,end-offset)
                let updated = String(value.prefix(lo)) + (placed ? "" : insertion) + String(value.dropFirst(hi))
                if case .receipt = segment, receipt(updated)?.rest == "" { result.append(.receipt(updated)) }
                else { result.append(.text(updated)) }
                placed = true
            } else { result.append(segment) }
        }
        if !placed && !insertion.isEmpty { result.append(.text(insertion)) }
        // Segment boundaries can divide a composed character after a manual edit.
        guard result.compactMap(\.content).joined() == new else { return nil }
        return result
    }
}

/// One instance per generation, shared by the live session and durable response spool.
/// No dispatch or execution lives on the phone.
public struct HostedReplyStream: Sendable {
    public private(set) var text: String
    public private(set) var reasoning: String
    public private(set) var segments: [HostedSegment]?
    private var tail = ""
    private var pending: [Int: HostedCall] = [:]
    private var invalid = false
    public private(set) var byteCount: Int
    public init(prefix: String = "", reasoning: String = "", segments: [HostedSegment]? = nil) {
        text = prefix; self.reasoning = reasoning; self.segments = segments
        if case .text(let last) = self.segments?.last { self.segments?.removeLast(); tail = last }
        byteCount = prefix.utf8.count + reasoning.utf8.count + HostedHistory.callBytes(segments)
    }
    public var snapshot: [HostedSegment]? {
        guard let segments else { return nil }
        return tail.isEmpty ? segments : segments + [.text(tail)]
    }
    public mutating func finishBatch() {
        defer { pending.removeAll(keepingCapacity: true); invalid = false }
        guard !invalid, !pending.isEmpty else { return }
        let calls = pending.sorted { $0.key < $1.key }.map(\.value)
        guard HostedHistory.valid(calls) else { return }
        if segments == nil { segments = text.isEmpty ? [] : [.text(text)] }
        if !tail.isEmpty { segments?.append(.text(tail)); tail = "" }
        segments?.append(.calls(calls))
    }
    public mutating func append(_ delta: TokenDelta) throws {
        let size = delta.text.utf8.count + delta.reasoning.utf8.count + delta.callBytes
        guard size <= 8_000_000 - byteCount else { throw ClientError.tooLarge }
        byteCount += size
        if !delta.text.isEmpty && delta.callParts.isEmpty { finishBatch() }
        text += delta.text; reasoning += delta.reasoning
        if segments != nil, !delta.text.isEmpty {
            // Check a narrow overlap so a footer split across SSE frames is recognized.
            let closing: Bool
            if case .calls = segments?.last { closing = (String(tail.suffix(2)) + delta.text).contains(">>>") } else { closing = false }
            tail += delta.text
            if closing, let sealed = HostedHistory.receipt(tail) {
                segments?.append(.receipt(sealed.raw)); tail = sealed.rest
            }
        }
        for (position,part) in delta.callParts.enumerated() {
            let index = part["index"] == .null ? position : part["index"].number.flatMap(Int.init(exactly:)) ?? -1
            guard (0..<1024).contains(index), case .object = part else { invalid = true; continue }
            var call = pending.removeValue(forKey: index) ?? HostedCall()
            for (name, path) in [("id", \HostedCall.id), ("type", \HostedCall.type)] {
                guard let raw = part.object[name] else { continue }
                guard case .string(let value) = raw, call[keyPath:path].isEmpty || call[keyPath:path] == value else { invalid = true; continue }
                call[keyPath:path] = value
            }
            let fn = part["function"]
            for (name,path) in [("name", \HostedCall.Function.name), ("arguments", \HostedCall.Function.arguments)] {
                guard let raw = fn.object[name] else { continue }
                guard case .string(let value) = raw else { invalid = true; continue }
                if delta.completeCalls { call.function[keyPath:path] = value } else { call.function[keyPath:path] += value }
            }
            pending[index] = call
        }
        if delta.done || delta.closesBatch { finishBatch() }
    }
}
