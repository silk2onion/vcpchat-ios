import Foundation
import GRDB

public enum FootprintStoreError: Error, Equatable, Sendable {
    case protectedDataUnavailable
    case storagePreparationFailed(String)
}

public protocol FootprintStorageProtector: Sendable {
    func prepareDirectory(_ directoryURL: URL) throws
    func protectDatabaseFile(_ databaseURL: URL) throws
}

public struct SystemFootprintStorageProtector: FootprintStorageProtector {
    public init() {}

    public func prepareDirectory(_ directoryURL: URL) throws {
        let fm = FileManager.default
        do {
            #if os(iOS)
            let attributes: [FileAttributeKey: Any] = [
                .protectionKey: FileProtectionType.completeUntilFirstUserAuthentication
            ]
            try fm.createDirectory(at: directoryURL, withIntermediateDirectories: true, attributes: attributes)
            try fm.setAttributes(attributes, ofItemAtPath: directoryURL.path)
            #else
            try fm.createDirectory(at: directoryURL, withIntermediateDirectories: true)
            #endif
            var mutableURL = directoryURL
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            try mutableURL.setResourceValues(values)
        } catch {
            if Self.isProtectedDataError(error) {
                throw FootprintStoreError.protectedDataUnavailable
            }
            throw FootprintStoreError.storagePreparationFailed(error.localizedDescription)
        }
    }

    public func protectDatabaseFile(_ databaseURL: URL) throws {
        let fm = FileManager.default
        let siblings = [
            databaseURL,
            URL(fileURLWithPath: databaseURL.path + "-wal"),
            URL(fileURLWithPath: databaseURL.path + "-shm")
        ]
        for url in siblings where fm.fileExists(atPath: url.path) {
            do {
                #if os(iOS)
                try fm.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: url.path)
                #endif
                var mutableURL = url
                var values = URLResourceValues()
                values.isExcludedFromBackup = true
                try mutableURL.setResourceValues(values)
            } catch {
                if Self.isProtectedDataError(error) {
                    throw FootprintStoreError.protectedDataUnavailable
                }
                throw FootprintStoreError.storagePreparationFailed(error.localizedDescription)
            }
        }
    }

    public static func isProtectedDataError(_ error: any Error) -> Bool {
        let nsError = error as NSError
        if nsError.domain == NSCocoaErrorDomain && [
            NSFileReadNoPermissionError,
            NSFileWriteNoPermissionError,
            NSFileLockingError
        ].contains(nsError.code) {
            return true
        }
        if nsError.domain == NSPOSIXErrorDomain && [Int(EPERM), Int(EACCES)].contains(nsError.code) {
            return true
        }
        if let dbError = error as? DatabaseError {
            // SQLITE_PERM(3) / SQLITE_AUTH(23) indicate permission/protection refusal.
            if [3, 23].contains(dbError.resultCode.rawValue) {
                return true
            }
            #if os(iOS)
            // Only treat SQLITE_CANTOPEN(14) as pre-first-unlock when extended code indicates permission/access refusal.
            if dbError.resultCode.rawValue == 14 && (dbError.extendedResultCode.rawValue == 14 || dbError.message?.localizedCaseInsensitiveContains("permission") == true) {
                return true
            }
            #endif
        }
        return false
    }
}

public struct FootprintStoreMeta: Sendable, Equatable {
    public let clearEpoch: Int64
    public let deletedBeforeMs: Int64

    public init(clearEpoch: Int64, deletedBeforeMs: Int64) {
        self.clearEpoch = clearEpoch
        self.deletedBeforeMs = deletedBeforeMs
    }
}

public struct FootprintOutboxBatch: Sendable, Equatable {
    public let clearEpoch: Int64
    public let items: [FootprintOutboxItem]

    public init(clearEpoch: Int64, items: [FootprintOutboxItem]) {
        self.clearEpoch = clearEpoch
        self.items = items
    }
}

public struct FootprintPendingStateUpdate: Codable, Sendable, Equatable {
    public let id: String
    public let clearEpoch: Int64
    public let accuracyAuth: FootprintAccuracyAuth
    public let status: String
    public let measuredAtMs: Int64

    public init(
        id: String = UUID().uuidString.lowercased(),
        clearEpoch: Int64,
        accuracyAuth: FootprintAccuracyAuth,
        status: String,
        measuredAtMs: Int64
    ) {
        self.id = id
        self.clearEpoch = clearEpoch
        self.accuracyAuth = accuracyAuth
        self.status = status
        self.measuredAtMs = measuredAtMs
    }
}

public struct FootprintTimelinePayload: Sendable, Equatable {
    public let segments: [FootprintSegment]
    public let summary: FootprintPeriodSummary

    public init(segments: [FootprintSegment], summary: FootprintPeriodSummary) {
        self.segments = segments
        self.summary = summary
    }
}

public struct FootprintAnnotatedWrite: Sendable, Equatable {
    public let point: FootprintPoint
    public let enqueueForSync: Bool
    public let destinationKey: String?

    public init(point: FootprintPoint, enqueueForSync: Bool, destinationKey: String? = nil) {
        self.point = point
        self.enqueueForSync = enqueueForSync
        self.destinationKey = destinationKey
    }
}

/// Independent GRDB WAL database for annual local footprints.
/// Strictly isolated from chat.sqlite and protected at the directory level before opening.
public actor FootprintStore {
    public static let directoryName = "LocationTracks"
    public static let databaseFileName = "location-tracks.sqlite"

    private let pool: DatabasePool
    public let databaseURL: URL

    public static func defaultDirectoryURL(baseRoot: URL? = nil) throws -> URL {
        let root: URL
        if let baseRoot {
            root = baseRoot
        } else if let isolated = ProcessInfo.processInfo.environment["VCHAT_DATA_DIR"] {
            root = URL(fileURLWithPath: isolated, isDirectory: true)
        } else {
            let appSupport = try FileManager.default.url(
                for: .applicationSupportDirectory,
                in: .userDomainMask,
                appropriateFor: nil,
                create: true
            )
            let folder = Bundle.main.bundleIdentifier == "app.vcpchat.native"
                ? "VChatNative"
                : (Bundle.main.bundleIdentifier ?? "VChatNative")
            root = appSupport.appendingPathComponent(folder, isDirectory: true)
        }
        return root.appendingPathComponent(directoryName, isDirectory: true)
    }

    public static func open(
        directoryURL: URL,
        protector: any FootprintStorageProtector = SystemFootprintStorageProtector()
    ) async throws -> FootprintStore {
        // Iron rule: create and protect directory BEFORE opening SQLite.
        try protector.prepareDirectory(directoryURL)
        let dbURL = directoryURL.appendingPathComponent(databaseFileName, isDirectory: false)
        do {
            var config = Configuration()
            config.busyMode = .timeout(5.0)
            let pool = try DatabasePool(path: dbURL.path, configuration: config)
            try migrate(pool)
            try protector.protectDatabaseFile(dbURL)
            return FootprintStore(pool: pool, databaseURL: dbURL)
        } catch let storeError as FootprintStoreError {
            throw storeError
        } catch {
            if SystemFootprintStorageProtector.isProtectedDataError(error) {
                throw FootprintStoreError.protectedDataUnavailable
            }
            throw error
        }
    }

    private init(pool: DatabasePool, databaseURL: URL) {
        self.pool = pool
        self.databaseURL = databaseURL
    }

    private static func migrate(_ pool: DatabasePool) throws {
        var migrator = DatabaseMigrator()
        migrator.registerMigration("footprint-v1") { db in
            try db.create(table: "footprint_points") { t in
                t.column("pointID", .text).primaryKey()
                t.column("segmentID", .text).notNull()
                t.column("measuredAtMs", .integer).notNull()
                t.column("latitude", .double).notNull()
                t.column("longitude", .double).notNull()
                t.column("accuracyMeters", .double).notNull()
                t.column("speedMps", .double)
                t.column("courseDegrees", .double)
                t.column("accuracyAuth", .text).notNull()
                t.column("motionState", .text)
                t.column("transitionEvent", .text)
                t.column("source", .text).notNull()
                t.column("receivedAtMs", .integer).notNull()
            }
            try db.create(index: "idx_footprint_points_measured", on: "footprint_points", columns: ["measuredAtMs"])
            try db.create(index: "idx_footprint_points_segment", on: "footprint_points", columns: ["segmentID", "measuredAtMs"])
            try db.create(index: "idx_footprint_points_precise_time", on: "footprint_points", columns: ["accuracyAuth", "measuredAtMs"])

            try db.create(table: "footprint_outbox") { t in
                t.column("pointID", .text).primaryKey()
                t.column("segmentID", .text).notNull()
                t.column("measuredAtMs", .integer).notNull()
                t.column("clearEpoch", .integer).notNull()
                t.column("accuracyAuth", .text).notNull()
                t.column("payloadJSON", .blob).notNull()
                t.column("attempts", .integer).notNull().defaults(to: 0)
                t.column("nextRetryAtMs", .integer).notNull().defaults(to: 0)
                t.column("createdAtMs", .integer).notNull()
            }
            try db.create(index: "idx_footprint_outbox_retry", on: "footprint_outbox", columns: ["nextRetryAtMs", "measuredAtMs"])

            try db.create(table: "footprint_meta") { t in
                t.column("key", .text).primaryKey()
                t.column("value", .text).notNull()
            }
            try db.execute(sql: "INSERT OR IGNORE INTO footprint_meta(key, value) VALUES('clear_epoch', '0')")
            try db.execute(sql: "INSERT OR IGNORE INTO footprint_meta(key, value) VALUES('deleted_before_ms', '0')")
        }
        migrator.registerMigration("footprint-v2-segment-summary") { db in
            try db.create(table: "footprint_segments_summary") { t in
                t.column("segmentID", .text).primaryKey()
                t.column("startMs", .integer).notNull()
                t.column("endMs", .integer).notNull()
                t.column("pointCount", .integer).notNull()
                t.column("distanceMeters", .double).notNull()
                t.column("accuracyAuth", .text).notNull()
                t.column("lastLat", .double).notNull()
                t.column("lastLon", .double).notNull()
                t.column("firstRowID", .integer).notNull().defaults(to: 0)
                t.column("lastRowID", .integer).notNull().defaults(to: 0)
            }
            try db.create(index: "idx_footprint_seg_sum_time", on: "footprint_segments_summary", columns: ["startMs", "endMs"])
            try db.create(table: "footprint_daily_summary") { t in
                t.column("dayKey", .integer).primaryKey()
                t.column("pointCount", .integer).notNull()
            }
            try Self.rebuildSegmentSummary(in: db)
        }
        migrator.registerMigration("footprint-v3-outbox-destination") { db in
            try db.alter(table: "footprint_outbox") { t in
                t.add(column: "destinationKey", .text).notNull().defaults(to: "")
            }
            try db.create(index: "idx_footprint_outbox_dest", on: "footprint_outbox", columns: ["destinationKey", "clearEpoch", "nextRetryAtMs"])
        }
        try migrator.migrate(pool)
    }

    private static func rebuildSingleSegmentSummary(_ segmentID: String, in db: Database) throws {
        let statement = try db.makeStatement(sql: """
            SELECT rowid, measuredAtMs, latitude, longitude, accuracyAuth
            FROM footprint_points
            WHERE segmentID = ?
            ORDER BY measuredAtMs ASC, rowid ASC
            """)
        let rows = try Row.fetchCursor(statement, arguments: [segmentID])
        var firstRowID: Int64 = 0
        var lastRowID: Int64 = 0
        var startMs: Int64 = 0
        var endMs: Int64 = 0
        var count = 0
        var distance = 0.0
        var auth = FootprintAccuracyAuth.reduced.rawValue
        var lastLat = 0.0
        var lastLon = 0.0
        while let row = try rows.next() {
            let rid: Int64 = row[0]
            let ts: Int64 = row[1]
            let lat: Double = row[2]
            let lon: Double = row[3]
            let rowAuth: String = row[4]
            if count == 0 {
                firstRowID = rid
                startMs = ts
                auth = rowAuth
            } else if auth == FootprintAccuracyAuth.full.rawValue {
                distance += FootprintPoint.haversineMeters(lat1: lastLat, lon1: lastLon, lat2: lat, lon2: lon)
            }
            lastRowID = rid
            endMs = ts
            lastLat = lat
            lastLon = lon
            count += 1
        }
        if count == 0 {
            try db.execute(sql: "DELETE FROM footprint_segments_summary WHERE segmentID = ?", arguments: [segmentID])
        } else {
            try db.execute(
                sql: """
                INSERT INTO footprint_segments_summary(segmentID, startMs, endMs, pointCount, distanceMeters, accuracyAuth, lastLat, lastLon, firstRowID, lastRowID)
                VALUES(?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(segmentID) DO UPDATE SET
                    startMs = excluded.startMs,
                    endMs = excluded.endMs,
                    pointCount = excluded.pointCount,
                    distanceMeters = excluded.distanceMeters,
                    accuracyAuth = excluded.accuracyAuth,
                    lastLat = excluded.lastLat,
                    lastLon = excluded.lastLon,
                    firstRowID = excluded.firstRowID,
                    lastRowID = excluded.lastRowID
                """,
                arguments: [segmentID, startMs, endMs, count, distance, auth, lastLat, lastLon, firstRowID, lastRowID]
            )
        }
    }

    private static func rebuildSegmentSummary(in db: Database) throws {
        try db.execute(sql: "DELETE FROM footprint_segments_summary")
        try db.execute(sql: "DELETE FROM footprint_daily_summary")
        let statement = try db.makeStatement(sql: """
            SELECT rowid, segmentID, measuredAtMs, latitude, longitude, accuracyAuth
            FROM footprint_points
            ORDER BY measuredAtMs ASC, rowid ASC
            """)
        let rows = try Row.fetchCursor(statement)
        struct Acc {
            var startMs: Int64
            var endMs: Int64
            var count: Int
            var distance: Double
            var auth: String
            var lastLat: Double
            var lastLon: Double
            var firstRowID: Int64
            var lastRowID: Int64
        }
        var accMap: [String: Acc] = [:]
        var dayCounts: [Int64: Int] = [:]
        while let row = try rows.next() {
            let rid: Int64 = row[0]
            let segID: String = row[1]
            let ts: Int64 = row[2]
            let lat: Double = row[3]
            let lon: Double = row[4]
            let auth: String = row[5]
            dayCounts[ts / 86_400_000, default: 0] += 1
            if var cur = accMap[segID] {
                if auth == FootprintAccuracyAuth.full.rawValue {
                    cur.distance += FootprintPoint.haversineMeters(lat1: cur.lastLat, lon1: cur.lastLon, lat2: lat, lon2: lon)
                }
                cur.endMs = max(cur.endMs, ts)
                cur.count += 1
                cur.lastLat = lat
                cur.lastLon = lon
                cur.lastRowID = rid
                accMap[segID] = cur
            } else {
                accMap[segID] = Acc(startMs: ts, endMs: ts, count: 1, distance: 0, auth: auth, lastLat: lat, lastLon: lon, firstRowID: rid, lastRowID: rid)
            }
        }
        for (segID, acc) in accMap {
            try db.execute(
                sql: """
                INSERT INTO footprint_segments_summary(segmentID, startMs, endMs, pointCount, distanceMeters, accuracyAuth, lastLat, lastLon, firstRowID, lastRowID)
                VALUES(?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """,
                arguments: [segID, acc.startMs, acc.endMs, acc.count, acc.distance, acc.auth, acc.lastLat, acc.lastLon, acc.firstRowID, acc.lastRowID]
            )
        }
        for (dayKey, count) in dayCounts {
            try db.execute(
                sql: "INSERT INTO footprint_daily_summary(dayKey, pointCount) VALUES(?, ?)",
                arguments: [dayKey, count]
            )
        }
    }

    private static func decodeRenderPointFromRow(_ row: Row) -> FootprintPoint {
        let authRaw: String = row[6]
        return FootprintPoint(
            pointID: row[0],
            segmentID: row[1],
            measuredAtMs: row[2],
            latitude: row[3],
            longitude: row[4],
            accuracyMeters: row[5],
            accuracyAuth: FootprintAccuracyAuth(rawValue: authRaw) ?? .reduced
        )
    }

    public func journalMode() async throws -> String {
        try await pool.read { try String.fetchOne($0, sql: "PRAGMA journal_mode") ?? "" }
    }

    public func meta() async throws -> FootprintStoreMeta {
        try await pool.read { db in
            let epoch = Int64(try String.fetchOne(db, sql: "SELECT value FROM footprint_meta WHERE key='clear_epoch'") ?? "0") ?? 0
            let deletedBefore = Int64(try String.fetchOne(db, sql: "SELECT value FROM footprint_meta WHERE key='deleted_before_ms'") ?? "0") ?? 0
            return FootprintStoreMeta(clearEpoch: epoch, deletedBeforeMs: deletedBefore)
        }
    }

    public func lastPersistedAccuracyAuth() async throws -> FootprintAccuracyAuth? {
        try await pool.read { db in
            guard let raw = try String.fetchOne(db, sql: "SELECT value FROM footprint_meta WHERE key='last_accuracy_auth'") else {
                return nil
            }
            return FootprintAccuracyAuth(rawValue: raw)
        }
    }

    public func setLastPersistedAccuracyAuth(_ auth: FootprintAccuracyAuth) async throws {
        try await pool.write { db in
            try db.execute(
                sql: "INSERT INTO footprint_meta(key, value) VALUES('last_accuracy_auth', ?) ON CONFLICT(key) DO UPDATE SET value=excluded.value",
                arguments: [auth.rawValue]
            )
        }
    }

    public func pendingStateUpdate() async throws -> FootprintPendingStateUpdate? {
        try await pool.read { db in
            guard let raw = try String.fetchOne(db, sql: "SELECT value FROM footprint_meta WHERE key='pending_state_update'"),
                  !raw.isEmpty else {
                return nil
            }
            return try? JSONDecoder().decode(FootprintPendingStateUpdate.self, from: Data(raw.utf8))
        }
    }

    public func setPendingStateUpdate(_ update: FootprintPendingStateUpdate?) async throws {
        try await pool.write { db in
            if let update {
                let data = try JSONEncoder().encode(update)
                let text = String(decoding: data, as: UTF8.self)
                try db.execute(
                    sql: "INSERT INTO footprint_meta(key, value) VALUES('pending_state_update', ?) ON CONFLICT(key) DO UPDATE SET value=excluded.value",
                    arguments: [text]
                )
            } else {
                try db.execute(sql: "DELETE FROM footprint_meta WHERE key='pending_state_update'")
            }
        }
    }

    /// Clears pending_state_update ONLY if its version ID matches, so a stale HTTP response never deletes a newer state update.
    public func clearPendingStateUpdate(matchingID id: String) async throws {
        try await pool.write { db in
            guard let raw = try String.fetchOne(db, sql: "SELECT value FROM footprint_meta WHERE key='pending_state_update'"),
                  let current = try? JSONDecoder().decode(FootprintPendingStateUpdate.self, from: Data(raw.utf8)),
                  current.id == id else {
                return
            }
            try db.execute(sql: "DELETE FROM footprint_meta WHERE key='pending_state_update'")
        }
    }

    /// Single-transaction accuracy authorization calibration:
    /// - If transitioning full -> reduced OR if reduced while stale precise outbox rows still exist:
    ///   drops all precise outbox rows, records last_accuracy_auth='reduced', and optionally queues a coordinate-free state update.
    /// - If liveAuth == .full: records 'full' and clears any stale pending reduced_accuracy state update.
    /// Returns true if a downgrade/purge occurred.
    @discardableResult
    public func reconcileAccuracyAuthorization(
        _ liveAuth: FootprintAccuracyAuth,
        enqueueBatchStateUpdate: Bool,
        nowMs: Int64 = Int64(Date().timeIntervalSince1970 * 1000.0)
    ) async throws -> Bool {
        try await pool.write { db in
            let persistedRaw = try String.fetchOne(db, sql: "SELECT value FROM footprint_meta WHERE key='last_accuracy_auth'")
            let persisted = persistedRaw.flatMap(FootprintAccuracyAuth.init(rawValue:))

            try db.execute(
                sql: "INSERT INTO footprint_meta(key, value) VALUES('last_accuracy_auth', ?) ON CONFLICT(key) DO UPDATE SET value=excluded.value",
                arguments: [liveAuth.rawValue]
            )

            if liveAuth == .full {
                try db.execute(sql: "DELETE FROM footprint_meta WHERE key='pending_state_update'")
                return false
            }

            // liveAuth == .reduced: purge ANY stale precise outbox rows atomically.
            try db.execute(sql: "DELETE FROM footprint_outbox WHERE accuracyAuth = ?", arguments: [FootprintAccuracyAuth.full.rawValue])
            let purgedCount = db.changesCount
            let transitionedFromFull = (persisted == .full)

            if (transitionedFromFull || purgedCount > 0) && enqueueBatchStateUpdate {
                let epoch = Int64(try String.fetchOne(db, sql: "SELECT value FROM footprint_meta WHERE key='clear_epoch'") ?? "0") ?? 0
                let pending = FootprintPendingStateUpdate(
                    clearEpoch: epoch,
                    accuracyAuth: .reduced,
                    status: "reduced_accuracy",
                    measuredAtMs: nowMs
                )
                let data = try JSONEncoder().encode(pending)
                let text = String(decoding: data, as: UTF8.self)
                try db.execute(
                    sql: "INSERT INTO footprint_meta(key, value) VALUES('pending_state_update', ?) ON CONFLICT(key) DO UPDATE SET value=excluded.value",
                    arguments: [text]
                )
            }
            return transitionedFromFull || purgedCount > 0
        }
    }

    public func lastPoint() async throws -> FootprintPoint? {
        try await pool.read { db in
            try FootprintPoint.fetchOne(db, sql: "SELECT * FROM footprint_points ORDER BY measuredAtMs DESC LIMIT 1")
        }
    }

    /// Appends points idempotently while enforcing clear_epoch and deleted_before_ms watermarks.
    /// Returns the number of newly inserted points.
    @discardableResult
    public func append(
        _ points: [FootprintPoint],
        enqueueForSync: Bool,
        destinationKey: String? = nil,
        expectedClearEpoch: Int64? = nil,
        nowMs: Int64 = Int64(Date().timeIntervalSince1970 * 1000.0)
    ) async throws -> Int {
        guard !points.isEmpty else { return 0 }
        let items = points.map { FootprintAnnotatedWrite(point: $0, enqueueForSync: enqueueForSync, destinationKey: destinationKey) }
        return try await appendBatch(items, expectedClearEpoch: expectedClearEpoch, nowMs: nowMs)
    }

    /// Writes an entire batch in ONE atomic SQLite write transaction while preserving per-point
    /// `enqueueForSync` eligibility and `destinationKey` binding.
    @discardableResult
    public func appendBatch(
        _ items: [FootprintAnnotatedWrite],
        expectedClearEpoch: Int64? = nil,
        nowMs: Int64 = Int64(Date().timeIntervalSince1970 * 1000.0)
    ) async throws -> Int {
        guard !items.isEmpty else { return 0 }
        let encoder = JSONEncoder()
        return try await pool.write { db in
            let currentEpoch = Int64(try String.fetchOne(db, sql: "SELECT value FROM footprint_meta WHERE key='clear_epoch'") ?? "0") ?? 0
            let deletedBefore = Int64(try String.fetchOne(db, sql: "SELECT value FROM footprint_meta WHERE key='deleted_before_ms'") ?? "0") ?? 0
            let persistedAuth = (try String.fetchOne(db, sql: "SELECT value FROM footprint_meta WHERE key='last_accuracy_auth'")).flatMap(FootprintAccuracyAuth.init(rawValue:))
            if let expectedClearEpoch, expectedClearEpoch < currentEpoch {
                return 0
            }
            var inserted = 0
            for entry in items where entry.point.valid {
                let point = entry.point
                if point.measuredAtMs <= deletedBefore { continue }
                // Atomic downgrade race guard: if DB already calibrated to 'reduced', NEVER enqueue stale 'full' points.
                if persistedAuth == .reduced && point.accuracyAuth == .full { continue }
                let exists = try Int.fetchOne(db, sql: "SELECT 1 FROM footprint_points WHERE pointID = ?", arguments: [point.pointID]) != nil
                if exists { continue }
                try point.insert(db)
                let insertedRowID = db.lastInsertedRowID
                if let existingSeg = try Row.fetchOne(
                    db,
                    sql: "SELECT startMs, endMs, pointCount, distanceMeters, accuracyAuth, lastLat, lastLon FROM footprint_segments_summary WHERE segmentID = ?",
                    arguments: [point.segmentID]
                ) {
                    let prevEnd: Int64 = existingSeg["endMs"]
                    if point.measuredAtMs < prevEnd {
                        try Self.rebuildSingleSegmentSummary(point.segmentID, in: db)
                    } else {
                        let prevCount: Int = existingSeg["pointCount"]
                        var prevDist: Double = existingSeg["distanceMeters"]
                        let prevLat: Double = existingSeg["lastLat"]
                        let prevLon: Double = existingSeg["lastLon"]
                        if point.accuracyAuth == .full {
                            prevDist += FootprintPoint.haversineMeters(lat1: prevLat, lon1: prevLon, lat2: point.latitude, lon2: point.longitude)
                        }
                        try db.execute(
                            sql: """
                            UPDATE footprint_segments_summary
                            SET endMs = ?, pointCount = ?, distanceMeters = ?, lastLat = ?, lastLon = ?, lastRowID = ?
                            WHERE segmentID = ?
                            """,
                            arguments: [
                                point.measuredAtMs,
                                prevCount + 1,
                                prevDist,
                                point.latitude,
                                point.longitude,
                                insertedRowID,
                                point.segmentID
                            ]
                        )
                    }
                } else {
                    try db.execute(
                        sql: """
                        INSERT INTO footprint_segments_summary(segmentID, startMs, endMs, pointCount, distanceMeters, accuracyAuth, lastLat, lastLon, firstRowID, lastRowID)
                        VALUES(?, ?, ?, 1, 0.0, ?, ?, ?, ?, ?)
                        """,
                        arguments: [point.segmentID, point.measuredAtMs, point.measuredAtMs, point.accuracyAuth.rawValue, point.latitude, point.longitude, insertedRowID, insertedRowID]
                    )
                }
                let dayKey = point.measuredAtMs / 86_400_000
                try db.execute(
                    sql: "INSERT INTO footprint_daily_summary(dayKey, pointCount) VALUES(?, 1) ON CONFLICT(dayKey) DO UPDATE SET pointCount = pointCount + 1",
                    arguments: [dayKey]
                )
                inserted += 1
                if entry.enqueueForSync, let key = entry.destinationKey {
                    let canonicalDest = FootprintIdentityStore.canonicalEndpointKey(key)
                    guard !canonicalDest.isEmpty else { continue }
                    let payload = try encoder.encode(point)
                    let outboxItem = FootprintOutboxItem(
                        pointID: point.pointID,
                        segmentID: point.segmentID,
                        measuredAtMs: point.measuredAtMs,
                        clearEpoch: currentEpoch,
                        accuracyAuth: point.accuracyAuth,
                        destinationKey: canonicalDest,
                        payloadJSON: payload,
                        attempts: 0,
                        nextRetryAtMs: 0,
                        createdAtMs: nowMs
                    )
                    try outboxItem.insert(db)
                }
            }
            return inserted
        }
    }

    public func recentPrecisePoints(
        withinSeconds windowSeconds: Double = 1800,
        maxCount: Int = 15,
        at nowMs: Int64 = Int64(Date().timeIntervalSince1970 * 1000.0)
    ) async throws -> [FootprintPoint] {
        let clampedLimit = max(1, min(100, maxCount))
        let fromMs = nowMs - Int64((windowSeconds * 1000.0).rounded())
        return try await pool.read { db in
            let rows = try FootprintPoint.fetchAll(
                db,
                sql: """
                SELECT * FROM footprint_points
                WHERE accuracyAuth = 'full' AND measuredAtMs >= ? AND measuredAtMs <= ?
                ORDER BY measuredAtMs DESC
                LIMIT ?
                """,
                arguments: [fromMs, nowMs + 10_000, clampedLimit]
            )
            return rows.reversed()
        }
    }

    public func points(fromMs: Int64, toMs: Int64, limit: Int? = nil) async throws -> [FootprintPoint] {
        try await pool.read { db in
            if let limit {
                return try FootprintPoint.fetchAll(
                    db,
                    sql: "SELECT * FROM footprint_points WHERE measuredAtMs >= ? AND measuredAtMs <= ? ORDER BY measuredAtMs ASC LIMIT ?",
                    arguments: [fromMs, toMs, max(1, limit)]
                )
            }
            return try FootprintPoint.fetchAll(
                db,
                sql: "SELECT * FROM footprint_points WHERE measuredAtMs >= ? AND measuredAtMs <= ? ORDER BY measuredAtMs ASC",
                arguments: [fromMs, toMs]
            )
        }
    }

    /// Loads segments strictly grouped by segmentID without joining across gaps.
    /// When `maxPointsPerSegment` is set, downsamples uniformly while keeping endpoints.
    public func segments(fromMs: Int64, toMs: Int64, maxTotalPoints: Int? = nil) async throws -> [FootprintSegment] {
        let allPoints = try await points(fromMs: fromMs, toMs: toMs)
        guard !allPoints.isEmpty else { return [] }
        var orderedIDs: [String] = []
        var grouped: [String: [FootprintPoint]] = [:]
        for point in allPoints {
            if grouped[point.segmentID] == nil {
                orderedIDs.append(point.segmentID)
                grouped[point.segmentID] = [point]
            } else {
                grouped[point.segmentID]?.append(point)
            }
        }
        let strideStep: Int
        if let maxTotalPoints, maxTotalPoints > 0, allPoints.count > maxTotalPoints {
            strideStep = max(2, allPoints.count / maxTotalPoints)
        } else {
            strideStep = 1
        }
        return orderedIDs.compactMap { segID -> FootprintSegment? in
            guard let pts = grouped[segID], !pts.isEmpty else { return nil }
            if strideStep <= 1 || pts.count <= 2 {
                return FootprintSegment(id: segID, points: pts)
            }
            var sampled: [FootprintPoint] = []
            sampled.reserveCapacity((pts.count / strideStep) + 2)
            for idx in stride(from: 0, to: pts.count, by: strideStep) {
                sampled.append(pts[idx])
            }
            if let last = pts.last, sampled.last?.pointID != last.pointID {
                sampled.append(last)
            }
            return FootprintSegment(id: segID, points: sampled)
        }
    }

    /// Fast indexed query producing exact period summary (via segment summary table)
    /// plus strictly budgeted render segments sampled in SQL.
    public func timelinePayload(
        fromMs: Int64,
        toMs: Int64,
        maxTotalPoints: Int? = nil,
        calendar: Calendar = .current
    ) async throws -> FootprintTimelinePayload {
        try await pool.read { db in
            let summary = try Self.computeSummary(in: db, fromMs: fromMs, toMs: toMs, calendar: calendar)
            guard summary.pointCount > 0 else {
                return FootprintTimelinePayload(segments: [], summary: summary)
            }

            let hardBudget = maxTotalPoints.map { max(1, $0) }
            var selectedPoints: [FootprintPoint] = []
            if let budget = hardBudget, summary.pointCount > budget {
                // 1. Preserve endpoints strictly INSIDE [fromMs, toMs] for every sampled segment
                //    (for straddling segments, query exact first/last rowid within [fromMs, toMs]).
                let segRows = try Row.fetchAll(
                    db,
                    sql: """
                    SELECT segmentID, startMs, endMs, firstRowID, lastRowID, pointCount
                    FROM footprint_segments_summary
                    WHERE endMs >= ? AND startMs <= ? AND firstRowID > 0
                    ORDER BY startMs ASC
                    """,
                    arguments: [fromMs, toMs]
                )
                var targetRowIDs = Set<Int64>()
                targetRowIDs.reserveCapacity(budget)
                struct SegMeta {
                    let segID: String
                    let startMs: Int64
                    let endMs: Int64
                    let firstRowID: Int64
                    let lastRowID: Int64
                    let pointCount: Int
                }
                var multiSegs: [SegMeta] = []
                var singleSegs: [SegMeta] = []
                for row in segRows {
                    let segID: String = row[0]
                    let segStart: Int64 = row[1]
                    let segEnd: Int64 = row[2]
                    var firstID: Int64 = row[3]
                    var lastID: Int64 = row[4]
                    var inWindowCount: Int = row[5]
                    // For straddling segments only, compute exact in-window point count & endpoints so a
                    // 5,001-point cross-year segment with only 1 point in this year never steals the longest-route slot!
                    if segStart < fromMs || segEnd > toMs {
                        inWindowCount = try Int.fetchOne(
                            db,
                            sql: "SELECT COUNT(*) FROM footprint_points WHERE segmentID = ? AND measuredAtMs >= ? AND measuredAtMs <= ?",
                            arguments: [segID, fromMs, toMs]
                        ) ?? 0
                        guard inWindowCount > 0 else { continue }
                        if let exactFirst = try Int64.fetchOne(
                            db,
                            sql: "SELECT rowid FROM footprint_points WHERE segmentID = ? AND measuredAtMs >= ? AND measuredAtMs <= ? ORDER BY measuredAtMs ASC LIMIT 1",
                            arguments: [segID, fromMs, toMs]
                        ) {
                            firstID = exactFirst
                        }
                        if inWindowCount == 1 {
                            lastID = firstID
                        } else if let exactLast = try Int64.fetchOne(
                            db,
                            sql: "SELECT rowid FROM footprint_points WHERE segmentID = ? AND measuredAtMs >= ? AND measuredAtMs <= ? ORDER BY measuredAtMs DESC LIMIT 1",
                            arguments: [segID, fromMs, toMs]
                        ) {
                            lastID = exactLast
                        }
                    }
                    let meta = SegMeta(
                        segID: segID,
                        startMs: segStart,
                        endMs: segEnd,
                        firstRowID: firstID,
                        lastRowID: lastID,
                        pointCount: inWindowCount
                    )
                    if inWindowCount >= 2 {
                        multiSegs.append(meta)
                    } else {
                        singleSegs.append(meta)
                    }
                }

                struct ActiveSegSpan {
                    let segID: String
                    let startMs: Int64
                    let endMs: Int64
                    let interiorCapacity: Int
                }
                var activeSpans: [ActiveSegSpan] = []
                var totalInteriorCapacity = 0

                // 1a. Reserve endpoints + interior budget for the LONGEST route FIRST so thousands of
                //     earlier 2-point segments can NEVER exhaust the budget before reaching the longest route!
                func resolveAndRecordMultiSegment(_ seg: SegMeta) throws {
                    var firstID = seg.firstRowID
                    var lastID = seg.lastRowID
                    if seg.startMs < fromMs || seg.endMs > toMs {
                        if let exactFirst = try Int64.fetchOne(
                            db,
                            sql: "SELECT rowid FROM footprint_points WHERE segmentID = ? AND measuredAtMs >= ? AND measuredAtMs <= ? ORDER BY measuredAtMs ASC LIMIT 1",
                            arguments: [seg.segID, fromMs, toMs]
                        ) {
                            firstID = exactFirst
                        }
                        if let exactLast = try Int64.fetchOne(
                            db,
                            sql: "SELECT rowid FROM footprint_points WHERE segmentID = ? AND measuredAtMs >= ? AND measuredAtMs <= ? ORDER BY measuredAtMs DESC LIMIT 1",
                            arguments: [seg.segID, fromMs, toMs]
                        ) {
                            lastID = exactLast
                        }
                    }
                    let clampedStart = max(fromMs, seg.startMs)
                    let clampedEnd = min(toMs, seg.endMs)
                    let interior = max(0, seg.pointCount - 2)
                    if interior > 0 && clampedEnd > clampedStart {
                        activeSpans.append(ActiveSegSpan(segID: seg.segID, startMs: clampedStart, endMs: clampedEnd, interiorCapacity: interior))
                        totalInteriorCapacity += interior
                    }
                    if targetRowIDs.count < budget { targetRowIDs.insert(firstID) }
                    if targetRowIDs.count < budget { targetRowIDs.insert(lastID) }
                }

                let longestIdx = multiSegs.indices.max(by: { multiSegs[$0].pointCount < multiSegs[$1].pointCount })
                var reservedForLongestInterior = 0
                if let longestIdx {
                    let longest = multiSegs[longestIdx]
                    try resolveAndRecordMultiSegment(longest)
                    // Guarantee actual interior drawing slots (not just 2 endpoints!) for the longest route.
                    if longest.pointCount > 2 {
                        reservedForLongestInterior = min(longest.pointCount - 2, max(2, budget / 8))
                    }
                }

                let endpointCap = max(targetRowIDs.count, budget - reservedForLongestInterior)
                let remainingMultiSlots = max(0, (endpointCap - targetRowIDs.count) / 2)
                if remainingMultiSlots > 0 && multiSegs.count > 1 {
                    let otherIndices = multiSegs.indices.filter { $0 != longestIdx }
                    let multiStride = otherIndices.count > remainingMultiSlots ? max(1, (otherIndices.count + remainingMultiSlots - 1) / remainingMultiSlots) : 1
                    for pos in stride(from: 0, to: otherIndices.count, by: multiStride) {
                        if targetRowIDs.count + 2 > endpointCap { break }
                        try resolveAndRecordMultiSegment(multiSegs[otherIndices[pos]])
                    }
                }

                // 1b. Allocate single-point segments at 1 point each (never 2!), capping them so multi-point route
                //     interiors still retain adequate budget when both coexist.
                if !singleSegs.isEmpty && targetRowIDs.count < budget {
                    let avail = budget - targetRowIDs.count
                    let reservedForRoutes = totalInteriorCapacity > 0 ? min(totalInteriorCapacity, avail / 2) : 0
                    let singleBudget = max(0, avail - reservedForRoutes)
                    if singleBudget > 0 {
                        let singleStride = singleSegs.count > singleBudget ? max(1, (singleSegs.count + singleBudget - 1) / singleBudget) : 1
                        var addedSingles = 0
                        for idx in stride(from: 0, to: singleSegs.count, by: singleStride) {
                            if addedSingles >= singleBudget || targetRowIDs.count >= budget { break }
                            if targetRowIDs.insert(singleSegs[idx].firstRowID).inserted {
                                addedSingles += 1
                            }
                        }
                    }
                }

                // 2. Proportionally allocate remaining budget across LIVE segment time spans using
                //    `WITH RECURSIVE` B-tree probes on `idx_footprint_points_segment(segmentID, measuredAtMs)`.
                //    Immune to sparse multi-month gaps (e.g. 5,000 pts + 1 pt 364 days later), out-of-order rowids, AND deletion holes!
                let remainingBudget = max(0, budget - targetRowIDs.count)
                if remainingBudget > 0 && totalInteriorCapacity > 0 {
                    let segCteStmt = try db.makeStatement(sql: """
                        WITH RECURSIVE slots(n) AS (
                            SELECT 1
                            UNION ALL
                            SELECT n + 1 FROM slots WHERE n < ?
                        )
                        SELECT DISTINCT (
                            SELECT rowid FROM footprint_points
                            WHERE segmentID = ? AND measuredAtMs >= (? + n * ?) AND measuredAtMs <= ?
                            ORDER BY measuredAtMs ASC
                            LIMIT 1
                        ) AS rid
                        FROM slots
                        """)
                    for span in activeSpans {
                        if targetRowIDs.count >= budget { break }
                        let share = Int((Double(remainingBudget) * Double(span.interiorCapacity) / Double(totalInteriorCapacity)).rounded(.up))
                        let slots = min(share, min(span.interiorCapacity, budget - targetRowIDs.count))
                        guard slots > 0 else { continue }
                        let timeStep = max(Int64(1), (span.endMs - span.startMs) / Int64(slots + 1))
                        let cursor = try Row.fetchCursor(segCteStmt, arguments: [slots, span.segID, span.startMs, timeStep, span.endMs])
                        while let row = try cursor.next() {
                            if targetRowIDs.count >= budget { break }
                            if let rid: Int64 = row[0] {
                                targetRowIDs.insert(rid)
                            }
                        }
                    }
                }

                let sortedIDs = targetRowIDs.sorted()
                selectedPoints.reserveCapacity(sortedIDs.count)
                // Pure `WHERE rowid IN (...)` forces SQLite's INTEGER PRIMARY KEY B-tree lookup.
                for chunkStart in stride(from: 0, to: sortedIDs.count, by: 500) {
                    let chunk = sortedIDs[chunkStart..<min(sortedIDs.count, chunkStart + 500)]
                    let idLiterals = chunk.map(String.init).joined(separator: ",")
                    let stmt = try db.makeStatement(sql: """
                        SELECT pointID, segmentID, measuredAtMs, latitude, longitude, accuracyMeters, accuracyAuth
                        FROM footprint_points
                        WHERE rowid IN (\(idLiterals))
                        """)
                    let cursor = try Row.fetchCursor(stmt)
                    while let row = try cursor.next() {
                        let pt = Self.decodeRenderPointFromRow(row)
                        if pt.measuredAtMs >= fromMs && pt.measuredAtMs <= toMs {
                            selectedPoints.append(pt)
                        }
                    }
                }
                selectedPoints.sort { $0.measuredAtMs < $1.measuredAtMs }
            } else {
                let stmt = try db.makeStatement(sql: """
                    SELECT pointID, segmentID, measuredAtMs, latitude, longitude, accuracyMeters, accuracyAuth
                    FROM footprint_points
                    WHERE measuredAtMs >= ? AND measuredAtMs <= ?
                    ORDER BY measuredAtMs ASC
                    """)
                let cursor = try Row.fetchCursor(stmt, arguments: [fromMs, toMs])
                while let row = try cursor.next() {
                    selectedPoints.append(Self.decodeRenderPointFromRow(row))
                }
            }

            var orderedSegIDs: [String] = []
            var grouped: [String: [FootprintPoint]] = [:]
            for pt in selectedPoints {
                if grouped[pt.segmentID] == nil {
                    orderedSegIDs.append(pt.segmentID)
                    grouped[pt.segmentID] = [pt]
                } else {
                    grouped[pt.segmentID]?.append(pt)
                }
            }
            let rendered = orderedSegIDs.compactMap { segID -> FootprintSegment? in
                guard let pts = grouped[segID], !pts.isEmpty else { return nil }
                return FootprintSegment(id: segID, points: pts, precomputedDistance: 0)
            }
            return FootprintTimelinePayload(segments: rendered, summary: summary)
        }
    }

    public func summary(fromMs: Int64, toMs: Int64, calendar: Calendar = .current) async throws -> FootprintPeriodSummary {
        try await pool.read { db in
            try Self.computeSummary(in: db, fromMs: fromMs, toMs: toMs, calendar: calendar)
        }
    }

    private static func computeSummary(in db: Database, fromMs: Int64, toMs: Int64, calendar: Calendar) throws -> FootprintPeriodSummary {
        // Fast path: segments fully enclosed within [fromMs, toMs] are read from footprint_segments_summary (<1ms for 100k points).
        let enclosedRow = try Row.fetchOne(
            db,
            sql: """
            SELECT COALESCE(SUM(pointCount), 0) AS pts,
                   COUNT(*) AS segs,
                   COALESCE(SUM(distanceMeters), 0.0) AS dist
            FROM footprint_segments_summary
            WHERE startMs >= ? AND endMs <= ?
            """,
            arguments: [fromMs, toMs]
        )
        var totalCount: Int = enclosedRow?["pts"] ?? 0
        var segmentCount: Int = enclosedRow?["segs"] ?? 0
        var totalDistance: Double = enclosedRow?["dist"] ?? 0.0

        // Exact boundary handling: any segment straddling fromMs or toMs is computed from its points inside the range.
        let boundarySegIDs = try String.fetchAll(
            db,
            sql: """
            SELECT segmentID FROM footprint_segments_summary
            WHERE endMs >= ? AND startMs <= ? AND (startMs < ? OR endMs > ?)
            """,
            arguments: [fromMs, toMs, fromMs, toMs]
        )
        for segID in boundarySegIDs {
            let pts = try FootprintPoint.fetchAll(
                db,
                sql: "SELECT * FROM footprint_points WHERE segmentID = ? AND measuredAtMs >= ? AND measuredAtMs <= ? ORDER BY measuredAtMs ASC",
                arguments: [segID, fromMs, toMs]
            )
            guard !pts.isEmpty else { continue }
            totalCount += pts.count
            segmentCount += 1
            if pts[0].accuracyAuth == .full && pts.count >= 2 {
                for i in 1..<pts.count {
                    totalDistance += pts[i - 1].distance(to: pts[i])
                }
            }
        }

        // Active days counted strictly in local calendar days (DST-aware, e.g., Europe/London BST 00:30 & 12:30 = 1 day).
        // Clamp scan window to actual [MIN(measuredAtMs), MAX(measuredAtMs)] so wide queries like fromMs=0 never truncate!
        var activeDays = 0
        if totalCount > 0,
           let bounds = try Row.fetchOne(
            db,
            sql: "SELECT MIN(measuredAtMs), MAX(measuredAtMs) FROM footprint_points WHERE measuredAtMs >= ? AND measuredAtMs <= ?",
            arguments: [fromMs, toMs]
           ),
           let actualMinMs: Int64 = bounds[0],
           let actualMaxMs: Int64 = bounds[1] {
            let startDate = Date(timeIntervalSince1970: Double(actualMinMs) / 1000.0)
            let endDate = Date(timeIntervalSince1970: Double(actualMaxMs) / 1000.0)
            var dayCursor = calendar.startOfDay(for: startDate)
            let probeStmt = try db.makeStatement(
                sql: "SELECT 1 FROM footprint_points WHERE measuredAtMs >= ? AND measuredAtMs <= ? LIMIT 1"
            )
            var guardSteps = 0
            while dayCursor <= endDate && guardSteps < 4000 {
                guardSteps += 1
                let nextDay = calendar.date(byAdding: .day, value: 1, to: dayCursor) ?? dayCursor.addingTimeInterval(86_400)
                let bucketStart = max(actualMinMs, Int64((dayCursor.timeIntervalSince1970 * 1000.0).rounded()))
                let bucketEnd = min(actualMaxMs, Int64((nextDay.timeIntervalSince1970 * 1000.0).rounded()) - 1)
                if bucketStart <= bucketEnd,
                   try Int.fetchOne(probeStmt, arguments: [bucketStart, bucketEnd]) != nil {
                    activeDays += 1
                }
                dayCursor = nextDay
            }
        }

        return FootprintPeriodSummary(
            pointCount: totalCount,
            segmentCount: segmentCount,
            activeDays: activeDays,
            totalDistanceMeters: totalDistance
        )
    }

    public func totalPointCount() async throws -> Int {
        try await pool.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM footprint_points") ?? 0 }
    }

    /// Clears history before `beforeMs`, or performs a full clear when `beforeMs == nil`.
    /// Full clear increments `clear_epoch` and sets `deleted_before_ms = nowMs + 60_000` (T+60s) to block stale backfill.
    @discardableResult
    public func clearHistory(
        beforeMs: Int64? = nil,
        nowMs: Int64 = Int64(Date().timeIntervalSince1970 * 1000.0)
    ) async throws -> FootprintStoreMeta {
        try await pool.write { db in
            let oldEpoch = Int64(try String.fetchOne(db, sql: "SELECT value FROM footprint_meta WHERE key='clear_epoch'") ?? "0") ?? 0
            let oldDeleted = Int64(try String.fetchOne(db, sql: "SELECT value FROM footprint_meta WHERE key='deleted_before_ms'") ?? "0") ?? 0
            if let cutoff = beforeMs {
                let nextDeleted = max(oldDeleted, cutoff)
                try Self.deletePointsAndPatchSummaries(cutoffMs: cutoff, inclusive: true, in: db)
                try db.execute(sql: "DELETE FROM footprint_outbox WHERE measuredAtMs <= ?", arguments: [cutoff])
                try db.execute(sql: "UPDATE footprint_meta SET value = ? WHERE key = 'deleted_before_ms'", arguments: [String(nextDeleted)])
                return FootprintStoreMeta(clearEpoch: oldEpoch, deletedBeforeMs: nextDeleted)
            } else {
                let nextEpoch = oldEpoch + 1
                let nextDeleted = max(oldDeleted, nowMs + 60_000)
                try db.execute(sql: "DELETE FROM footprint_points")
                try db.execute(sql: "DELETE FROM footprint_outbox")
                try db.execute(sql: "DELETE FROM footprint_segments_summary")
                try db.execute(sql: "DELETE FROM footprint_daily_summary")
                try db.execute(sql: "DELETE FROM footprint_meta WHERE key = 'pending_state_update'")
                try db.execute(sql: "UPDATE footprint_meta SET value = ? WHERE key = 'clear_epoch'", arguments: [String(nextEpoch)])
                try db.execute(sql: "UPDATE footprint_meta SET value = ? WHERE key = 'deleted_before_ms'", arguments: [String(nextDeleted)])
                return FootprintStoreMeta(clearEpoch: nextEpoch, deletedBeforeMs: nextDeleted)
            }
        }
    }

    /// Incrementally deletes points older than cutoff and patches ONLY affected segments & days (never rebuilds full year).
    @discardableResult
    private static func deletePointsAndPatchSummaries(cutoffMs: Int64, inclusive: Bool, in db: Database) throws -> Int {
        let op = inclusive ? "<=" : "<"
        let surviveOp = inclusive ? ">" : ">="
        let affectedSegments = try String.fetchAll(
            db,
            sql: "SELECT segmentID FROM footprint_segments_summary WHERE startMs \(op) ?",
            arguments: [cutoffMs]
        )
        try db.execute(sql: "DELETE FROM footprint_points WHERE measuredAtMs \(op) ?", arguments: [cutoffMs])
        let removed = db.changesCount
        guard removed > 0 else { return 0 }

        // Remove segments fully expired, and recompute boundary segments straddling cutoffMs
        // (including `endMs == cutoffMs` when deleting strictly `< cutoffMs`!).
        try db.execute(sql: "DELETE FROM footprint_segments_summary WHERE endMs \(op) ?", arguments: [cutoffMs])
        let boundarySegments = try String.fetchAll(
            db,
            sql: "SELECT segmentID FROM footprint_segments_summary WHERE startMs \(op) ? AND endMs \(surviveOp) ?",
            arguments: [cutoffMs, cutoffMs]
        )
        for segID in boundarySegments where affectedSegments.contains(segID) {
            try Self.rebuildSingleSegmentSummary(segID, in: db)
        }

        // Patch daily summary: delete days strictly before cutoffDay, recompute only cutoffDay.
        let cutoffDay = cutoffMs / 86_400_000
        try db.execute(sql: "DELETE FROM footprint_daily_summary WHERE dayKey < ?", arguments: [cutoffDay])
        let dayStart = cutoffDay * 86_400_000
        let dayEnd = (cutoffDay + 1) * 86_400_000 - 1
        let remainingInDay = try Int.fetchOne(
            db,
            sql: "SELECT COUNT(*) FROM footprint_points WHERE measuredAtMs >= ? AND measuredAtMs <= ?",
            arguments: [dayStart, dayEnd]
        ) ?? 0
        if remainingInDay > 0 {
            try db.execute(
                sql: "INSERT INTO footprint_daily_summary(dayKey, pointCount) VALUES(?, ?) ON CONFLICT(dayKey) DO UPDATE SET pointCount = excluded.pointCount",
                arguments: [cutoffDay, remainingInDay]
            )
        } else {
            try db.execute(sql: "DELETE FROM footprint_daily_summary WHERE dayKey = ?", arguments: [cutoffDay])
        }
        return removed
    }

    @discardableResult
    public func pruneExpired(retentionDays: Int, nowMs: Int64 = Int64(Date().timeIntervalSince1970 * 1000.0)) async throws -> Int {
        let clampedDays = max(7, retentionDays)
        let cutoff = nowMs - Int64(clampedDays) * 86_400_000
        return try await pool.write { db in
            let removed = try Self.deletePointsAndPatchSummaries(cutoffMs: cutoff, inclusive: false, in: db)
            try db.execute(sql: "DELETE FROM footprint_outbox WHERE measuredAtMs < ?", arguments: [cutoff])
            return removed
        }
    }

    // MARK: - Outbox Queue Operations

    public func pendingOutboxCount() async throws -> Int {
        try await pool.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM footprint_outbox") ?? 0 }
    }

    /// Atomically reads current clear_epoch + deleted_before_ms and matching outbox items in one transaction.
    /// When `allowedAccuracyAuth == .reduced`, SQL strictly excludes any precise ('full') outbox items.
    public func dequeueReadyOutboxBatch(
        limit: Int = 200,
        nowMs: Int64 = Int64(Date().timeIntervalSince1970 * 1000.0),
        allowedAccuracyAuth: FootprintAccuracyAuth = .full,
        destinationKey: String? = nil
    ) async throws -> FootprintOutboxBatch? {
        let clamped = max(1, min(200, limit))
        let canonicalDest = destinationKey.map(FootprintIdentityStore.canonicalEndpointKey)
        return try await pool.read { db in
            let currentEpoch = Int64(try String.fetchOne(db, sql: "SELECT value FROM footprint_meta WHERE key='clear_epoch'") ?? "0") ?? 0
            let deletedBefore = Int64(try String.fetchOne(db, sql: "SELECT value FROM footprint_meta WHERE key='deleted_before_ms'") ?? "0") ?? 0
            var clauses = ["clearEpoch = ?", "measuredAtMs > ?", "nextRetryAtMs <= ?"]
            var args: StatementArguments = [currentEpoch, deletedBefore, nowMs]
            if allowedAccuracyAuth == .reduced {
                clauses.append("accuracyAuth = 'reduced'")
            }
            if let canonicalDest {
                // Strict destination binding: unbound (empty) or other-server rows can NEVER be dequeued.
                guard !canonicalDest.isEmpty else { return nil }
                clauses.append("destinationKey = ?")
                args += [canonicalDest]
            }
            args += [clamped]
            let items = try FootprintOutboxItem.fetchAll(
                db,
                sql: """
                SELECT * FROM footprint_outbox
                WHERE \(clauses.joined(separator: " AND "))
                ORDER BY measuredAtMs ASC
                LIMIT ?
                """,
                arguments: args
            )
            guard !items.isEmpty else { return nil }
            return FootprintOutboxBatch(clearEpoch: currentEpoch, items: items)
        }
    }

    public func dequeueReadyOutbox(
        limit: Int = 200,
        nowMs: Int64 = Int64(Date().timeIntervalSince1970 * 1000.0),
        destinationKey: String? = nil
    ) async throws -> [FootprintOutboxItem] {
        try await dequeueReadyOutboxBatch(limit: limit, nowMs: nowMs, destinationKey: destinationKey)?.items ?? []
    }

    public func acknowledgeOutbox(pointIDs: [String]) async throws {
        guard !pointIDs.isEmpty else { return }
        try await pool.write { db in
            for id in pointIDs {
                try db.execute(sql: "DELETE FROM footprint_outbox WHERE pointID = ?", arguments: [id])
            }
        }
    }

    public func markOutboxRetry(pointIDs: [String], nowMs: Int64 = Int64(Date().timeIntervalSince1970 * 1000.0)) async throws {
        guard !pointIDs.isEmpty else { return }
        try await pool.write { db in
            for id in pointIDs {
                let currentAttempts = try Int.fetchOne(db, sql: "SELECT attempts FROM footprint_outbox WHERE pointID = ?", arguments: [id]) ?? 0
                let nextAttempts = currentAttempts + 1
                let backoffSec = min(900, 30 * (1 << min(nextAttempts - 1, 5)))
                let nextRetry = nowMs + Int64(backoffSec) * 1000
                try db.execute(
                    sql: "UPDATE footprint_outbox SET attempts = ?, nextRetryAtMs = ? WHERE pointID = ?",
                    arguments: [nextAttempts, nextRetry, id]
                )
            }
        }
    }

    /// Drops unsynced precise points on full -> reduced downgrade so stale precise data is never pushed later.
    @discardableResult
    public func dropPendingPreciseOutbox() async throws -> Int {
        try await pool.write { db in
            try db.execute(sql: "DELETE FROM footprint_outbox WHERE accuracyAuth = ?", arguments: [FootprintAccuracyAuth.full.rawValue])
            return db.changesCount
        }
    }

    public func clearOutbox() async throws {
        try await pool.write { db in
            try db.execute(sql: "DELETE FROM footprint_outbox")
        }
    }
}