import Foundation
import GRDB

public struct RecallQuery: Sendable {
    public struct Term: Sendable { public var words: [String]; public var weight: Double }
    public var terms: [Term] = []
    public var excluded: [String] = []
    public init(_ input: String) throws {
        guard input.utf8.count <= 2000 else { throw ClientError.server("检索词过长") }
        let pattern = #"\([^)]*\)|\{[^}]*\}|\[[^\]]*\]|"[^"]*"|[^,，\s]+"#
        let regex = try NSRegularExpression(pattern: pattern)
        for match in regex.matches(in: input,range: NSRange(input.startIndex...,in: input)) {
            guard let range = Range(match.range,in: input) else { continue }
            var part = String(input[range]), weight = 1.0
            if part.hasPrefix("[") { excluded.append(String(part.dropFirst().dropLast()).components(separatedBy: ":")[0]); continue }
            let group = part.hasPrefix("{")
            if group || part.hasPrefix("(") {
                part = String(part.dropFirst().dropLast())
                if let colon = part.lastIndex(of: ":"),let value = Double(part[part.index(after: colon)...]) {
                    guard value.isFinite,(0...2).contains(value) else { throw ClientError.server("关键词权重必须在0–2之间") }
                    weight = value; part = String(part[..<colon])
                }
            }
            if part.hasPrefix("\""),part.hasSuffix("\"") { part = String(part.dropFirst().dropLast()) }
            let words = (group ? part.components(separatedBy: "|") : [part]).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
            if !words.isEmpty { terms.append(Term(words: words,weight: weight)) }
        }
        excluded = excluded.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        guard !terms.isEmpty,terms.count + excluded.count <= 32 else { throw ClientError.server("请提供1–32组有效关键词") }
    }
}
public struct RecallHit: Sendable, Identifiable {
    public var id: String
    public var topicID: String
    public var title: String
    public var text: String
    public var score: Double
    public var excerpted: Bool
    public var json: JSONValue { .object(["message_id": .string(id),"topic_id": .string(topicID),"topic_name": .string(title),"text": .string(text),"score": .number(score),"excerpted": .bool(excerpted)]) }
}
public struct RecallRerankSettings: Codable, Sendable, Equatable {
    public var enabled = false
    public var server = ""
    public var model = ""
    public init() {}
}
extension ChatStore {
    /// FTS5 narrows candidates when every term fits the trigram index. Short Chinese
    /// terms use parameter-bound LIKE; neither query syntax nor SQL comes from input.
    public func recall(agentID: String,query: RecallQuery,window: Int,limit: Int) async throws -> [RecallHit] {
        let matches: [(StoredMessage,Double)] = try await pool.read { db in
            var params = ["agent": agentID], terms: [String] = [], exclusions: [String] = [], fts: [String] = []
            func literal(_ word: String) -> String { "%" + word.replacingOccurrences(of: "\\",with: "\\\\").replacingOccurrences(of: "%",with: "\\%").replacingOccurrences(of: "_",with: "\\_") + "%" }
            for (i,term) in query.terms.enumerated() {
                var group: [String] = []
                for (j,word) in term.words.enumerated() {
                    let name = "term\(i)_\(j)"; params[name] = literal(word)
                    group.append("m.content LIKE :\(name) ESCAPE '\\'")
                    fts.append("\"" + word.replacingOccurrences(of: "\"",with: "\"\"") + "\"")
                }
                params["weight\(i)"] = String(term.weight)
                terms.append("(CASE WHEN (\(group.joined(separator: " OR "))) THEN CAST(:weight\(i) AS REAL) ELSE 0 END)")
            }
            for (i,word) in query.excluded.enumerated() { params["exclude\(i)"] = literal(word); exclusions.append("AND m.content NOT LIKE :exclude\(i) ESCAPE '\\'") }
            let indexable = query.terms.flatMap(\.words).allSatisfy { $0.count >= 3 }
            if indexable { params["fts"] = fts.joined(separator: " OR ") }
            let index = indexable ? "AND m.rowid IN (SELECT rowid FROM messageSearch WHERE messageSearch MATCH :fts)" : ""
            let score = terms.joined(separator: " + ")
            let sql = "SELECT m.*, (\(score)) AS recallScore FROM messages m JOIN library t ON t.kind='topic' AND t.id=m.topicID WHERE json_extract(CAST(t.payload AS TEXT),'$.ownerType')='agent' AND json_extract(CAST(t.payload AS TEXT),'$.ownerId')=:agent AND m.role IN ('user','assistant') \(index) \(exclusions.joined(separator: " ")) AND (\(score))>0 ORDER BY recallScore DESC,m.createdAt DESC,m.id LIMIT 40"
            return try Row.fetchAll(db,sql: sql,arguments: StatementArguments(params)).map { row in (try StoredMessage(row: row),row["recallScore"] as Double) }
        }
        let topics = try await records(ChatTopic.self,kind: "topic")
        var hits: [RecallHit] = [], covered: [String:Set<String>] = [:]
        for (match,score) in matches {
            try Task.checkCancellation()
            guard hits.count < limit,covered[match.topicID]?.contains(match.id) != true,let topic = topics.first(where: { $0.id == match.topicID && $0.ownerId == agentID }) else { continue }
            let messages = try await messages(topicID: topic.id)
            guard let at = messages.firstIndex(where: { $0.id == match.id }) else { continue }
            // One turn contains an adjacent user/assistant pair; preserve surrounding
            // dialogue and keep the selected hit present even for a single huge bubble.
            let lower = max(0,at - window * 2), upper = min(messages.count,at + window * 2 + 1)
            let selected = Array(messages[lower..<upper])
            let maxPerMessage = max(400,18_000 / max(1,selected.count))
            var excerpted = false
            let text = selected.map { message in
                let body = MobileTopicTool.plain(message.content)
                var start = 0
                if message.id == match.id,body.unicodeScalars.count > maxPerMessage {
                    let positions = query.terms.flatMap(\.words).compactMap { body.range(of: $0,options: .caseInsensitive)?.lowerBound }
                    if let position = positions.min() { start = max(0,body[..<position].unicodeScalars.count - maxPerMessage / 3) }
                }
                var slice = String(body.unicodeScalars.dropFirst(start).prefix(maxPerMessage))
                if slice != body { excerpted = true; if start > 0 { slice = "…" + slice }; if start + maxPerMessage < body.unicodeScalars.count { slice += "…" } }
                return "**\(message.authorName.isEmpty ? message.role : message.authorName)**: \(slice)"
            }.joined(separator: "\n\n")
            covered[topic.id,default: []].formUnion(selected.map(\.id))
            hits.append(RecallHit(id: match.id,topicID: topic.id,title: topic.title,text: text,score: score,excerpted: excerpted))
        }
        return hits
    }
}
public actor RecallReranker {
    let http = VCPHTTP(allowingRedirects: false)
    public init() {}
    public func rank(_ hits: [RecallHit],query: String,settings: RecallRerankSettings,key: String) async throws -> [RecallHit] {
        guard settings.enabled,!settings.server.isEmpty,!settings.model.isEmpty,!key.isEmpty else { throw ClientError.server("请先配置并启用历史检索精排服务，或传rerank:false") }
        guard !hits.isEmpty else { return [] }
        let url = try ConnectionConfiguration(server: settings.server).endpoint("v1/rerank")
        let reply = try await http.json(url,method: "POST",authorization: "Bearer " + key,body: .object(["model": .string(settings.model),"query": .string(query),"documents": .array(hits.map { .string($0.text) }),"top_n": .number(Double(hits.count))]))
        var ranked: [RecallHit] = [], indices: Set<Int> = []
        guard case .array(let results) = reply["results"] else { throw ClientError.invalidResponse }
        for result in results {
            guard result["index"] != .null else { throw ClientError.invalidResponse }
            let index = try MobileTopicTool.integer(result["index"],default: 0,range: 0...(hits.count - 1))
            guard indices.insert(index).inserted,let score = result["relevance_score"].number,score.isFinite else { throw ClientError.invalidResponse }
            var hit = hits[index]; hit.score = score; ranked.append(hit)
        }
        guard !ranked.isEmpty else { throw ClientError.invalidResponse }
        return ranked
    }
}
