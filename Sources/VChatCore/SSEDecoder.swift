import Foundation

public struct TokenDelta: Sendable, Equatable {
    public var text = ""
    public var reasoning = ""
    public var done = false
}
/// Used only from SessionActor; preserves multiline SSE data and fragmented Unicode lines.
public struct SSEDecoder: Sendable {
    private var data: [String] = []
    public init() {}
    public mutating func line(_ raw: String) throws -> TokenDelta? {
        let line = raw.hasSuffix("\r") ? String(raw.dropLast()) : raw
        if line.isEmpty {
            guard !data.isEmpty else { return nil }
            let payload = data.joined(separator: "\n"); data.removeAll(keepingCapacity: true)
            return try Self.decode(payload)
        }
        if line.hasPrefix("data:") {
            var value = String(line.dropFirst(5)); if value.hasPrefix(" ") { value.removeFirst() }
            data.append(value)
            if data.reduce(0, { $0 + $1.utf8.count }) > 1_000_000 { throw ClientError.tooLarge }
        }
        return nil
    }
    public mutating func finish() throws -> TokenDelta? { try line("") }
    public static func decode(_ payload: String) throws -> TokenDelta {
        if payload.trimmingCharacters(in: .whitespacesAndNewlines) == "[DONE]" { return TokenDelta(done: true) }
        let object = try JSONDecoder().decode(Completion.self, from: Data(payload.utf8))
        if let error = object.error { throw ClientError.server(error.message ?? "模型服务返回错误") }
        guard let choice = object.choices?.first else { return TokenDelta() }
        // VCP forwards each model round's finish_reason before executing its tools
        // and continuing on this same stream. Only [DONE] ends the whole request.
        return TokenDelta(text: choice.delta?.content ?? choice.message?.content ?? "", reasoning: choice.delta?.reasoning_content ?? choice.delta?.reasoning ?? "")
    }
    private struct Completion: Decodable {
        struct APIError: Decodable { let message: String? }
        struct Delta: Decodable { let content: String?; let reasoning_content: String?; let reasoning: String? }
        struct Choice: Decodable { let delta: Delta?; let message: Delta? }
        let choices: [Choice]?; let error: APIError?
    }
}

/// Frame deadlines, not one UI invalidation per token. All text assembly stays in the session actor.
public struct FramePacer: Sendable {
    public let interval: Duration
    private var deadline: ContinuousClock.Instant?
    public init(framesPerSecond: Int) { interval = .milliseconds(framesPerSecond >= 120 ? 8 : 16) }
    public mutating func ready(at now: ContinuousClock.Instant) -> Bool {
        guard let deadline else { self.deadline = now + interval; return true }
        guard now >= deadline else { return false }
        self.deadline = now + interval; return true
    }
}

/// URLSession.AsyncBytes.lines drops empty lines on Apple platforms. SSE needs those
/// delimiters, so decode UTF-8 only after a complete CR/LF-delimited line arrives.
public struct SSEByteDecoder: Sendable {
    private var parser = SSEDecoder()
    private var bytes: [UInt8] = []
    private var previousCR = false
    private var firstLine = true
    public init() {}
    public mutating func byte(_ byte: UInt8) throws -> TokenDelta? {
        if byte == 10 && previousCR { previousCR = false; return nil }
        previousCR = byte == 13
        if byte == 10 || byte == 13 {
            guard var line = String(bytes: bytes, encoding: .utf8) else { throw ClientError.invalidResponse }
            bytes.removeAll(keepingCapacity: true)
            if firstLine { if line.hasPrefix("\u{FEFF}") { line.removeFirst() }; firstLine = false }
            return try parser.line(line)
        }
        bytes.append(byte)
        guard bytes.count <= 1_000_000 else { throw ClientError.tooLarge }
        return nil
    }
    public mutating func finish() throws -> TokenDelta? {
        if !bytes.isEmpty {
            guard let line = String(bytes: bytes, encoding: .utf8) else { throw ClientError.invalidResponse }
            _ = try parser.line(line); bytes.removeAll()
        }
        return try parser.finish()
    }
}
