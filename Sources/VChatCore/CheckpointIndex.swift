import Foundation
import SQLite3
import GRDB

public struct SyncCheckpointSummary: Sendable, Identifiable, FetchableRecord, Decodable {
    public let id: String, profileID: String, at: Double, beforeTopics: Int, afterTopics: Int
}

extension ChatStore {
    static func putCheckpoint(_ db: Database, _ checkpoint: SyncCheckpoint) throws {
        try putSync(db, checkpoint, kind: "sync-checkpoint", id: checkpoint.id)
        try index(db, .init(id: checkpoint.id, profileID: checkpoint.profileID, at: checkpoint.at,
                            beforeTopics: checkpoint.before.topics.count, afterTopics: checkpoint.after.topics.count))
    }
    private static func index(_ db: Database, _ row: SyncCheckpointSummary) throws {
        try db.execute(sql: "INSERT INTO syncCheckpointIndex (id,profileID,at,beforeTopics,afterTopics) VALUES (?,?,?,?,?)",
                       arguments: [row.id,row.profileID,row.at,row.beforeTopics,row.afterTopics])
    }
    public func checkpointSummaries() async throws -> [SyncCheckpointSummary] {
        let missingSQL = """
            SELECT l.rowid,l.id FROM library l LEFT JOIN syncCheckpointIndex i ON i.id=l.id
            WHERE l.kind='sync-checkpoint' AND i.id IS NULL
            """
        let listSQL = "SELECT * FROM syncCheckpointIndex ORDER BY at DESC,id"
        let ready = try await pool.read { db -> [SyncCheckpointSummary]? in
            guard try Int.fetchOne(db, sql: "SELECT EXISTS(" + missingSQL + ")") == 0 else { return nil }
            return try SyncCheckpointSummary.fetchAll(db, sql: listSQL)
        }
        if let ready { return ready }
        return try await pool.write { db in
            // Old versions stored only a JSON blob. Index missing rows once, without
            // materializing a checkpoint or rewriting any of the original backups.
            let missing = try Row.fetchAll(db, sql: missingSQL)
            for row in missing {
                try Task.checkCancellation()
                let reader = try CheckpointReader(db, rowID: row["rowid"])
                try Self.index(db, reader.summary(id:row["id"]))
            }
            return try SyncCheckpointSummary.fetchAll(db, sql: listSQL)
        }
    }
}

/// Streaming projection for JSONEncoder's legacy checkpoint envelope. Skip strings
/// (including escaped quotes) and nested values in-place; capture only the two
/// scalar fields and count elements directly inside each snapshot's topics array.
private final class CheckpointReader {
    private let blob: OpaquePointer
    private let size: Int
    private static let capacity = 64 * 1024
    private let bytes = UnsafeMutablePointer<UInt8>.allocate(capacity: capacity + 1)
    private var loaded = 0, pos = 0, end = 0
    private var invalid: Error { SyncWire.fail("恢复点索引读取失败；原恢复点未改动") }

    init(_ db: Database, rowID: Int64) throws {
        var opened: OpaquePointer?
        guard sqlite3_blob_open(db.sqliteConnection, "main", "library", "payload", rowID, 0, &opened) == SQLITE_OK, let opened else {
            bytes.deallocate()
            throw SyncWire.fail("无法打开已有恢复点")
        }
        blob = opened; size = Int(sqlite3_blob_bytes(opened))
    }
    deinit { sqlite3_blob_close(blob); bytes.deallocate() }

    private func peek() throws -> UInt8 {
        if pos == end {
            guard loaded < size else { throw invalid }
            try Task.checkCancellation()
            end = min(Self.capacity, size-loaded)
            guard sqlite3_blob_read(blob, bytes, Int32(end), Int32(loaded)) == SQLITE_OK else { throw invalid }
            bytes[end] = 0; loaded += end; pos = 0
        }
        return bytes[pos]
    }
    private func whitespace() throws { while try [9,10,13,32].contains(peek()) { pos += 1 } }
    private func take(_ byte: UInt8) throws {
        try whitespace(); guard try peek() == byte else { throw invalid }; pos += 1
    }
    // The buffer is NUL-terminated; valid JSON text contains no literal NUL.
    private func span(_ delimiters: UnsafePointer<CChar>) -> Int {
        strcspn(UnsafeRawPointer(bytes + pos).assumingMemoryBound(to: CChar.self), delimiters)
    }
    private func string(capture: Bool = false) throws -> String {
        try take(34)
        var data = Data()
        if capture { data.append(34) }
        while true {
            _ = try peek()
            let n = span("\"\\")
            if capture { data.append(bytes+pos,count:n) }
            pos += n
            if pos == end { continue }
            let c = bytes[pos]; pos += 1
            guard c == 34 || c == 92 else { throw invalid }
            if capture { data.append(c) }
            if c == 34 { return capture ? try JSONDecoder().decode(String.self,from:data) : "" }
            let escaped = try peek(); pos += 1
            if capture { data.append(escaped) }
        }
    }
    private func skipValue() throws {
        try whitespace()
        switch try peek() {
        case 34: _ = try string()
        case 91,123:
            var depth = 1; pos += 1
            while depth > 0 {
                _ = try peek(); pos += span("\"{}[]")
                if pos == end { continue }
                switch bytes[pos] {
                case 34: _ = try string()
                case 123,91: pos += 1; depth += 1
                case 125,93: pos += 1; depth -= 1
                default: throw invalid
                }
            }
        default:
            while try ![44,93,125,9,10,13,32].contains(peek()) { pos += 1 }
        }
    }
    private func object(_ field: (String) throws -> Void) throws {
        try take(123); try whitespace()
        if try peek() != 125 {
            while true {
                let key = try string(capture:true); try take(58); try field(key); try whitespace()
                if try peek() != 44 { break }; pos += 1
            }
        }
        try take(125)
    }
    private func topics() throws -> Int {
        var count: Int?
        try object { key in
            guard key == "topics" else { try skipValue(); return }
            try take(91); try whitespace(); var n = 0
            if try peek() != 93 {
                while true {
                    try skipValue(); n += 1; try whitespace()
                    if try peek() != 44 { break }; pos += 1
                }
            }
            try take(93); count = n
        }
        guard let count else { throw invalid }; return count
    }
    func summary(id: String) throws -> SyncCheckpointSummary {
        var profile: String?, at: Double?, before: Int?, after: Int?
        try object { key in
            switch key {
            case "profileID": profile = try string(capture:true)
            case "at":
                try whitespace(); var number: [UInt8] = []
                while try ![44,125,9,10,13,32].contains(peek()) { number.append(bytes[pos]); pos += 1 }
                at = Double(String(decoding:number,as:UTF8.self))
            case "before": before = try topics()
            case "after": after = try topics()
            default: try skipValue()
            }
        }
        guard let profile, let at, let before, let after else { throw invalid }
        return .init(id:id,profileID:profile,at:at,beforeTopics:before,afterTopics:after)
    }
}
