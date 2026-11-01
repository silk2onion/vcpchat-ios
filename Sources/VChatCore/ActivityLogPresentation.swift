import Foundation

/// A display-only projection of VCPLog's nested tool output. Routing and approval
/// identities always come from ActivityEntry.data, never from this projection.
public struct ActivityLogPresentation: Codable, Sendable, Equatable {
    public enum Category: String, Codable, Sendable { case log, notification, error }
    public var category: Category
    public var title: String
    public var message: String
    public var author: String
    public var folder: String
    public var file: String
    public var indexState: String
    public var status: String
    public var occurredAt: Double?
    public var isDiary: Bool
    public var indexLabel: String {
        switch indexState.lowercased() {
        case "queued", "pending": "索引等待更新"
        case "processing", "running", "indexing": "索引更新中"
        case "completed", "complete", "success", "indexed": "索引已更新"
        case "failed", "error": "索引更新失败"
        default: indexState.isEmpty ? "" : "索引：" + indexState
        }
    }
    public init?(payload: JSONValue) {
        let routedType = payload["data"]["type"].text
        let type = routedType.isEmpty ? payload["type"].text : routedType
        guard ["vcp_log", "daily_note_created", "DailyNote", "video_generation_status"].contains(type) else { return nil }
        // Bounded envelope traversal, not a recursive search through arbitrary note content.
        var layers = [payload], cursor = 0, encodedObjects: Set<String> = []
        while cursor < layers.count && layers.count < 12 {
            let value = layers[cursor]; cursor += 1
            for key in ["data", "content", "original_plugin_output", "result", "message"] where layers.count < 12 {
                if let object = Self.object(value[key]) {
                    layers.append(object)
                    if case .string(let text) = value[key] { encodedObjects.insert(text) }
                }
            }
        }
        func first(_ keys: [String]) -> String {
            for layer in layers.reversed() {
                for key in keys {
                    if case .string(let value) = layer[key], !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                       !encodedObjects.contains(value) { return value }
                }
            }
            return ""
        }
        let tool = first(["tool_name", "toolName"])
        author = first(["MaidName", "maidName", "agentName", "maid"])
        folder = first(["folder", "folderName"])
        file = first(["fileName", "filename"])
        indexState = first(["indexStatus"])
        message = first(["plugin_error", "error"])
        if message.isEmpty { message = first(["message", "text", "summary"]) }
        if message.isEmpty { message = first(["content"]) }
        let statuses = layers.flatMap { [$0["status"].text.lowercased(), $0["level"].text.lowercased()] }
        let failed = statuses.contains { ["error", "failed", "failure", "timeout"].contains($0) } || layers.contains { $0["success"].bool == false }
        status = failed ? "error" : first(["status"])
        isDiary = ["daily_note_created", "DailyNote"].contains(type) || tool == "DailyNote" || (!folder.isEmpty && !file.isEmpty && !indexState.isEmpty)
        guard isDiary || !message.isEmpty else { return nil }
        if isDiary {
            let saved = !failed && (status.lowercased() == "success" || message.range(of: "日记.*已(?:成功)?保存|日记.*已成功创建",options: .regularExpression) != nil)
            title = failed ? "日记处理失败" : saved ? "日记已保存" : "日记更新"
            category = failed ? .error : .notification
            // The standard saved notice repeats the path and indexing state already
            // shown as native fields. Keep custom/error messages and the raw payload.
            if saved, !folder.isEmpty, !file.isEmpty, message.contains(folder), message.contains(file), message.contains("知识库索引") { message = "" }
        } else {
            title = tool.isEmpty ? (type == "video_generation_status" ? "视频生成进度" : "VCP 日志") : tool
            category = failed ? .error : type == "video_generation_status" ? .notification : .log
        }
        occurredAt = nil
        let parser = ISO8601DateFormatter(); parser.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        for layer in layers.reversed() {
            if let value = layer["timestamp"].number, value.isFinite, value > 0 {
                occurredAt = value > 10_000_000_000 ? value / 1000 : value; break
            }
            let value = layer["timestamp"].text
            if let date = parser.date(from: value) ?? ISO8601DateFormatter().date(from: value) { occurredAt = date.timeIntervalSince1970; break }
        }
    }
    private static func object(_ input: JSONValue) -> JSONValue? {
        var value = input
        for _ in 0..<3 {
            if case .object = value { return value }
            guard case .string(let text) = value, text.utf8.count <= 1_000_000 else { return nil }
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmed.hasPrefix("{") || trimmed.hasPrefix("\""),
                  let decoded = try? JSONDecoder().decode(JSONValue.self,from: Data(trimmed.utf8)) else { return nil }
            value = decoded
        }
        if case .object = value { return value }; return nil
    }
}
