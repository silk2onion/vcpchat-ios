import Foundation
import GRDB

public struct ConversationSummary: Decodable,Sendable,FetchableRecord,Equatable {
    public var topicID: String
    public var authorName: String
    public var role: String
    public var preview: String
    public var status: String
    public var createdAt: Double?
    public var hasAttachments: Bool
    public var display: String {
        if preview.isEmpty { return hasAttachments ? "[附件]" : "" }
        if preview.hasPrefix("<div id=\"vcp-root\">") { return "[互动内容]" }
        if preview.contains("<<<[TOOL_REQUEST]>>>") { return "[工具调用]" }
        if preview.contains("```mermaid") { return "[图表]" }
        if preview.contains("```") { return "[代码]" }
        return preview.replacingOccurrences(of: "!\\[[^\\]]*\\]\\([^)]*\\)",with: "[图片]",options: .regularExpression)
            .replacingOccurrences(of: "\\[([^\\]]+)\\]\\([^)]*\\)",with: "$1",options: .regularExpression)
            .replacingOccurrences(of: "\\s+",with: " ",options: .regularExpression)
            .replacingOccurrences(of: "^[#>*`_\\s]+",with: "",options: .regularExpression)
            .replacingOccurrences(of: "**",with: "").trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
extension ChatStore {
    /// One indexed seek per topic. SwiftUI receives short previews and attachment
    /// presence, not decoded attachments, full transcripts or live token buffers.
    public func conversationSummaries() async throws -> [ConversationSummary] {
        try await pool.read { db in
            try ConversationSummary.fetchAll(db,sql: """
                SELECT l.id AS topicID,coalesce(m.authorName,'') AS authorName,
                coalesce(m.role,'') AS role,substr(coalesce(m.content,''),1,180) AS preview,
                coalesce(m.status,'') AS status,m.createdAt,
                CASE WHEN m.attachments IS NOT NULL AND m.attachments<>'[]' THEN 1 ELSE 0 END AS hasAttachments
                FROM library l LEFT JOIN messages m ON m.rowid=(
                    SELECT rowid FROM messages WHERE topicID=l.id ORDER BY createdAt DESC,rowid DESC LIMIT 1
                ) WHERE l.kind='topic'
                """
            )
        }
    }
}
