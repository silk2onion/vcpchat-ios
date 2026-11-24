import Foundation
import GRDB

extension ChatRequest {
    public func urlRequest(streaming: Bool) throws -> URLRequest {
        guard !apiKey.isEmpty else { throw ClientError.missingKey }
        guard !configuration.model.isEmpty else { throw ClientError.missingModel }
        var call = URLRequest(url: try configuration.chatEndpoint())
        call.httpMethod = "POST"
        call.timeoutInterval = 600
        call.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        call.setValue("application/json", forHTTPHeaderField: "Content-Type")
        call.setValue(streaming ? "text/event-stream" : "application/json", forHTTPHeaderField: "Accept")
        struct Body: Encodable {
            let model: String, messages: [ChatTurn], temperature: Double?, contextTokenLimit: Int?, max_tokens: Int?, stream: Bool
        }
        call.httpBody = try JSONEncoder().encode(Body(model: configuration.model, messages: messages,
            temperature: temperature, contextTokenLimit: configuration.endpointMode == .vcpTools ? contextTokenLimit : nil,
            max_tokens: maxOutputTokens, stream: streaming))
        return call
    }
}

public struct BackgroundReplyJob: Codable, Sendable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "backgroundReplies"
    public let id: String, messageID: String, topicID: String
    public let userID: String?
    public init(id: String = UUID().uuidString, messageID: String, topicID: String, userID: String?) {
        self.id = id; self.messageID = messageID; self.topicID = topicID; self.userID = userID
    }
}

public struct FinishedReply: Sendable {
    public let text: String, reasoning: String
    public init(text: String, reasoning: String) { self.text = text; self.reasoning = reasoning }
    public init(data: Data) throws {
        struct Response: Decodable {
            struct Choice: Decodable {
                struct Message: Decodable { let content: String?, reasoning_content: String?, reasoning: String? }
                let message: Message?
            }
            let choices: [Choice]?
        }
        guard let message = try JSONDecoder().decode(Response.self, from: data).choices?.first?.message,
              message.content != nil || message.reasoning_content != nil || message.reasoning != nil else { throw ClientError.invalidResponse }
        text = message.content ?? ""; reasoning = message.reasoning_content ?? message.reasoning ?? ""
    }
}

extension ChatStore {
    public func registerBackgroundReply(_ job: BackgroundReplyJob) async throws {
        try await pool.write { try job.insert($0) }
    }
    public func backgroundReplies() async throws -> [BackgroundReplyJob] {
        try await pool.read { try BackgroundReplyJob.fetchAll($0) }
    }
    /// A late callback must neither resurrect a deleted message nor complete its regeneration.
    public func finishBackgroundReply(_ job: BackgroundReplyJob, reply: FinishedReply?, stopped: Bool = false, interrupted: Bool = false) async throws -> StoredMessage? {
        try await pool.write { db in
            guard try BackgroundReplyJob.deleteOne(db, key: job.id),
                  var message = try StoredMessage.fetchOne(db, key: job.messageID), message.topicID == job.topicID else { return nil }
            if let reply {
                guard message.content.utf8.count + message.reasoning.utf8.count + reply.text.utf8.count + reply.reasoning.utf8.count <= 8_000_000 else { throw ClientError.tooLarge }
                message.content += reply.text; message.reasoning += reply.reasoning
            }
            if reply != nil && !interrupted && !stopped {
                message.status = "complete"
                if let id = job.userID {
                    try db.execute(sql: "DELETE FROM outbox WHERE id=?", arguments: [id])
                    try db.execute(sql: "UPDATE messages SET status='complete' WHERE id=? AND topicID=? AND role='user'", arguments: [id, job.topicID])
                }
            } else { message.status = stopped ? "stopped" : "interrupted" }
            try message.update(db)
            return message
        }
    }
}
