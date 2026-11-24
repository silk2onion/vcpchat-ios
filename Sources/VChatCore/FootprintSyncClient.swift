import Compression
import Foundation

// MARK: - Forced Persistent Keychain (No In-Memory Session Fallback)

public protocol FootprintSecretStore: Sendable {
    func readSecret(_ name: String, allowingInteraction: Bool) async throws -> String
    func saveSecret(_ value: String, name: String) async throws
}

/// Strictly persistent Keychain wrapper for footprint device identity and write token.
/// Never falls back to CredentialVault.Persistence.session.
public actor PersistentFootprintKeychain: FootprintSecretStore {
    public static let deviceIDAccount = "footprint.device-id.v1"
    public static let writeTokenAccount = "footprint.sync-write-token.v1"

    private let vault: CredentialVault

    public init(service: String? = nil) {
        let resolvedService = service ?? ((Bundle.main.bundleIdentifier ?? "app.vcpchat.native") + ".footprint")
        self.vault = CredentialVault(service: resolvedService, persistence: .keychain)
    }

    public func readSecret(_ name: String, allowingInteraction: Bool) async throws -> String {
        try await vault.read(name, allowingInteraction: allowingInteraction)
    }

    public func saveSecret(_ value: String, name: String) async throws {
        try await vault.save(value, name: name)
    }
}

public enum FootprintIdentityError: Error, Equatable, Sendable {
    case protectedDataUnavailable
}

public enum FootprintIdentityStore {
    /// Reads persisted device_id. On silent background probe (`allowingInteraction == false`),
    /// an authorizationRequired error is propagated without generating or overwriting identity.
    public static func resolveDeviceID(
        from store: any FootprintSecretStore,
        allowingInteraction: Bool,
        makeID: () -> String = { UUID().uuidString.lowercased() }
    ) async throws -> String {
        do {
            let existing = try await store.readSecret(
                PersistentFootprintKeychain.deviceIDAccount,
                allowingInteraction: allowingInteraction
            ).trimmingCharacters(in: .whitespacesAndNewlines)
            if !existing.isEmpty { return existing }
            let generated = makeID()
            try await store.saveSecret(generated, name: PersistentFootprintKeychain.deviceIDAccount)
            return generated
        } catch CredentialVault.AccessError.authorizationRequired {
            throw FootprintIdentityError.protectedDataUnavailable
        } catch let err as FootprintIdentityError {
            throw err
        }
    }

    /// Canonical destination key: lowercases ONLY scheme and host while preserving
    /// case-sensitive path and query (e.g., `/TeamA/pub` != `/teama/pub`).
    public static func canonicalEndpointKey(_ endpointURL: String) -> String {
        let trimmed = endpointURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }
        guard var components = URLComponents(string: trimmed) else { return trimmed }
        if let scheme = components.scheme { components.scheme = scheme.lowercased() }
        if let host = components.host { components.host = host.lowercased() }
        return components.string ?? trimmed
    }

    /// Derives a destination-scoped Keychain account so switching sync endpoint URLs
    /// never carries over credentials from a previous server.
    public static func writeTokenAccount(for endpointURL: String) -> String {
        let canonical = canonicalEndpointKey(endpointURL)
        guard !canonical.isEmpty else { return PersistentFootprintKeychain.writeTokenAccount }
        let hash = String(format: "%08x", FootprintGzip.crc32(Data(canonical.utf8)))
        return "\(PersistentFootprintKeychain.writeTokenAccount).\(hash)"
    }

    public static func readWriteToken(
        for endpointURL: String,
        from store: any FootprintSecretStore,
        allowingInteraction: Bool
    ) async throws -> String {
        do {
            let scopedAccount = writeTokenAccount(for: endpointURL)
            return try await store.readSecret(
                scopedAccount,
                allowingInteraction: allowingInteraction
            ).trimmingCharacters(in: .whitespacesAndNewlines)
        } catch CredentialVault.AccessError.authorizationRequired {
            throw FootprintIdentityError.protectedDataUnavailable
        }
    }

    public static func saveWriteToken(
        _ token: String,
        for endpointURL: String,
        to store: any FootprintSecretStore
    ) async throws {
        let scopedAccount = writeTokenAccount(for: endpointURL)
        try await store.saveSecret(
            token.trimmingCharacters(in: .whitespacesAndNewlines),
            name: scopedAccount
        )
    }
}

// MARK: - RFC 1952 Gzip Compression (Zero External Dependencies)

public enum FootprintGzip {
    private static let crc32Table: [UInt32] = {
        (0..<256).map { i -> UInt32 in
            var c = UInt32(i)
            for _ in 0..<8 {
                c = (c & 1) != 0 ? (0xEDB8_8320 ^ (c >> 1)) : (c >> 1)
            }
            return c
        }
    }()

    public static func crc32(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xFFFF_FFFF
        for byte in data {
            let index = Int((crc ^ UInt32(byte)) & 0xFF)
            crc = crc32Table[index] ^ (crc >> 8)
        }
        return crc ^ 0xFFFF_FFFF
    }

    /// Produces a standard RFC 1952 gzip payload (header + raw deflate stream + CRC32 + ISIZE).
    public static func compress(_ input: Data) -> Data? {
        let deflated: Data
        if input.isEmpty {
            // Empty raw deflate block.
            deflated = Data([0x03, 0x00])
        } else {
            let dstCapacity = max(64, input.count + 64)
            var dstBuffer = [UInt8](repeating: 0, count: dstCapacity)
            let compressedSize = input.withUnsafeBytes { rawSrc -> Int in
                guard let srcPtr = rawSrc.bindMemory(to: UInt8.self).baseAddress else { return 0 }
                return compression_encode_buffer(
                    &dstBuffer,
                    dstCapacity,
                    srcPtr,
                    input.count,
                    nil,
                    COMPRESSION_ZLIB
                )
            }
            guard compressedSize > 0 else { return nil }
            deflated = Data(dstBuffer.prefix(compressedSize))
        }

        var output = Data()
        output.reserveCapacity(10 + deflated.count + 8)
        // RFC 1952 header: ID1, ID2, CM=8(deflate), FLG=0, MTIME=0, XFL=0, OS=255
        output.append(contentsOf: [0x1F, 0x8B, 0x08, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0xFF])
        output.append(deflated)
        var crc = crc32(input).littleEndian
        withUnsafeBytes(of: &crc) { output.append(contentsOf: $0) }
        var isize = UInt32(truncatingIfNeeded: input.count).littleEndian
        withUnsafeBytes(of: &isize) { output.append(contentsOf: $0) }
        return output
    }
}

// MARK: - Upload Transport & Scheduler

public struct FootprintHTTPRequest: Sendable, Equatable {
    public let url: URL
    public let method: String
    public let headers: [String: String]
    public let body: Data

    public init(url: URL, method: String, headers: [String: String], body: Data) {
        self.url = url
        self.method = method
        self.headers = headers
        self.body = body
    }
}

public struct FootprintHTTPResponse: Sendable, Equatable {
    public let statusCode: Int
    public let body: Data

    public init(statusCode: Int, body: Data) {
        self.statusCode = statusCode
        self.body = body
    }
}

public protocol FootprintHTTPTransport: Sendable {
    func send(_ request: FootprintHTTPRequest) async throws -> FootprintHTTPResponse
}

private final class FootprintNoRedirectDelegate: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        // Refuse HTTP redirects so bearer tokens and location payloads can never cross destinations.
        completionHandler(nil)
    }
}

public final class ShortTimeoutURLSessionTransport: FootprintHTTPTransport, Sendable {
    private let session: URLSession
    private let delegate = FootprintNoRedirectDelegate()

    public init(timeoutSeconds: TimeInterval = 9.0) {
        let config = URLSessionConfiguration.ephemeral
        config.httpShouldSetCookies = false
        config.urlCache = nil
        config.timeoutIntervalForRequest = timeoutSeconds
        config.timeoutIntervalForResource = min(10.0, timeoutSeconds + 1.0)
        config.waitsForConnectivity = false
        self.session = URLSession(configuration: config, delegate: delegate, delegateQueue: nil)
    }

    public func send(_ request: FootprintHTTPRequest) async throws -> FootprintHTTPResponse {
        var urlRequest = URLRequest(url: request.url)
        urlRequest.httpMethod = request.method
        urlRequest.httpBody = request.body
        for (key, value) in request.headers {
            urlRequest.setValue(value, forHTTPHeaderField: key)
        }
        let (data, response) = try await session.data(for: urlRequest)
        guard let http = response as? HTTPURLResponse else {
            throw ClientError.invalidResponse
        }
        return FootprintHTTPResponse(statusCode: http.statusCode, body: data)
    }
}

public enum FootprintSyncError: Error, Equatable, Sendable {
    case syncDisabled
    case cancelledByStateChange
    case invalidHTTPSURL
    case missingWriteToken
    case payloadTooLarge
    case invalidServerAck
    case httpStatus(Int)
}

public struct FootprintBatchSyncResult: Sendable, Equatable {
    public let ackedPointIDs: [String]
    public let rejectedPointIDs: [String]
    public let sentStateUpdateOnly: Bool

    public init(ackedPointIDs: [String], rejectedPointIDs: [String], sentStateUpdateOnly: Bool = false) {
        self.ackedPointIDs = ackedPointIDs
        self.rejectedPointIDs = rejectedPointIDs
        self.sentStateUpdateOnly = sentStateUpdateOnly
    }
}

public struct FootprintUploadScheduler: Sendable {
    public static let movingIntervalSeconds: Double = 240.0
    public static let movingBatchThreshold: Int = 15

    public private(set) var lastUploadAt: Double?

    public init(lastUploadAt: Double? = nil) {
        self.lastUploadAt = lastUploadAt
    }

    /// Power-saving upload pacing:
    /// - Transition event (left/arrived home, started moving, dwelled 5m, visit): immediate.
    /// - Moving state: every 3-5 minutes (240s) or when >= 15 points accumulated.
    /// - Stationary/sleeping with no transition: 0 heartbeats, 0 wakeups.
    public func shouldUploadNow(
        pendingCount: Int,
        latestPoint: FootprintPoint?,
        hasTransitionEvent: Bool = false,
        now: Double
    ) -> Bool {
        guard pendingCount > 0 else { return false }
        if hasTransitionEvent || latestPoint?.transitionEvent != nil {
            return true
        }
        let motion = latestPoint?.motionState ?? .stationary
        // Stationary/dwelling without transition: STRICTLY 0 heartbeat, 0 wakeup even if queue >= 15.
        guard motion == .walking || motion == .vehicle else {
            return false
        }
        if pendingCount >= Self.movingBatchThreshold {
            return true
        }
        guard let lastUploadAt else { return true }
        return (now - lastUploadAt) >= Self.movingIntervalSeconds
    }

    public mutating func recordUpload(at now: Double) {
        lastUploadAt = now
    }
}

/// Strictly single-flight (concurrency=1) optional HTTPS batch / OwnTracks uploader.
public actor FootprintSyncClient {
    public static let maxBatchPoints = 200
    public static let maxUncompressedBytes = 1_000_000

    private let transport: any FootprintHTTPTransport
    private var isFlushing = false

    public init(transport: any FootprintHTTPTransport = ShortTimeoutURLSessionTransport()) {
        self.transport = transport
    }

    public static func resolveEndpointURL(base: URL, format: FootprintSyncFormat) -> URL {
        let path = base.path.lowercased()
        switch format {
        case .batchJSON:
            if path.hasSuffix("/ingest/batch") { return base }
            return base.appendingPathComponent("ingest/batch")
        case .owntracks:
            if path.hasSuffix("/ingest/owntracks") || path.contains("owntracks") || path.hasSuffix("/pub") {
                return base
            }
            return base.appendingPathComponent("ingest/owntracks")
        }
    }

    /// Flushes ready items from `store` strictly single-flight.
    /// Re-checks `shouldContinue()` before EVERY HTTP POST so sync-off, downgrade, clear, or URL switch halts immediately.
    public func flushOutbox(
        store: FootprintStore,
        settings: FootprintSettings,
        deviceID: String,
        writeToken: String,
        currentAccuracyAuth: FootprintAccuracyAuth = .full,
        nowMs: Int64 = Int64(Date().timeIntervalSince1970 * 1000.0),
        shouldContinue: @escaping @Sendable () async -> Bool = { true },
        allowStateUpdateDrain: (@Sendable () async -> Bool)? = nil
    ) async throws -> FootprintBatchSyncResult? {
        guard settings.syncEnabled else { return nil }
        guard !isFlushing else { return nil }
        isFlushing = true
        defer { isFlushing = false }

        guard let baseURL = settings.validatedHTTPSURL() else { throw FootprintSyncError.invalidHTTPSURL }
        let token = writeToken.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty else { throw FootprintSyncError.missingWriteToken }

        let stateCheck: @Sendable () async -> Bool = allowStateUpdateDrain ?? shouldContinue

        @Sendable func drainPendingStateUpdate() async throws -> Bool {
            guard let pendingState = try await store.pendingStateUpdate() else { return false }
            if settings.syncFormat == .batchJSON {
                guard await stateCheck() else { throw FootprintSyncError.cancelledByStateChange }
                _ = try await sendCoordinateFreeStateUpdate(
                    settings: settings,
                    deviceID: deviceID,
                    writeToken: token,
                    clearEpoch: pendingState.clearEpoch,
                    accuracyAuth: pendingState.accuracyAuth,
                    status: pendingState.status,
                    measuredAtMs: pendingState.measuredAtMs,
                    shouldContinue: stateCheck
                )
                guard await stateCheck() else { throw FootprintSyncError.cancelledByStateChange }
                try await store.clearPendingStateUpdate(matchingID: pendingState.id)
                return true
            } else {
                try await store.clearPendingStateUpdate(matchingID: pendingState.id)
                return false
            }
        }

        let sentStateOnly = try await drainPendingStateUpdate()

        let destKey = FootprintIdentityStore.canonicalEndpointKey(settings.syncEndpointURL)
        guard let batch = try await store.dequeueReadyOutboxBatch(
            limit: Self.maxBatchPoints,
            nowMs: nowMs,
            allowedAccuracyAuth: currentAccuracyAuth,
            destinationKey: destKey
        ) else {
            return sentStateOnly ? FootprintBatchSyncResult(ackedPointIDs: [], rejectedPointIDs: [], sentStateUpdateOnly: true) : nil
        }

        let decoder = JSONDecoder()
        let points: [FootprintPoint] = batch.items.compactMap { try? decoder.decode(FootprintPoint.self, from: $0.payloadJSON) }
        guard !points.isEmpty else {
            guard await shouldContinue() else { throw FootprintSyncError.cancelledByStateChange }
            try await store.acknowledgeOutbox(pointIDs: batch.items.map(\.pointID))
            return FootprintBatchSyncResult(ackedPointIDs: [], rejectedPointIDs: batch.items.map(\.pointID))
        }

        let batchContainsPrecise = points.contains { $0.accuracyAuth == .full }
        let batchIDs = Set(points.map(\.pointID))
        do {
            let result: FootprintBatchSyncResult
            switch settings.syncFormat {
            case .batchJSON:
                do {
                    if batchContainsPrecise {
                        // Strict DB read (never try?): any DB error or reduced calibration halts precise send.
                        let dbAuth = try await store.lastPersistedAccuracyAuth()
                        if dbAuth == .reduced {
                            throw FootprintSyncError.cancelledByStateChange
                        }
                    }
                    result = try await sendBatchJSON(
                        baseURL: baseURL,
                        token: token,
                        deviceID: deviceID,
                        deviceName: settings.deviceName,
                        clearEpoch: batch.clearEpoch,
                        points: points,
                        allowedIDs: batchIDs,
                        beforeSend: shouldContinue
                    )
                    // Re-verify state AFTER POST completes and BEFORE touching outbox rows.
                    guard await shouldContinue() else { throw FootprintSyncError.cancelledByStateChange }
                    let doneIDs = result.ackedPointIDs + result.rejectedPointIDs
                    if !doneIDs.isEmpty {
                        try await store.acknowledgeOutbox(pointIDs: doneIDs)
                    }
                    let doneSet = Set(doneIDs)
                    let remaining = batch.items.map(\.pointID).filter { !doneSet.contains($0) }
                    if !remaining.isEmpty {
                        try await store.markOutboxRetry(pointIDs: remaining, nowMs: nowMs)
                    }
                } catch FootprintSyncError.cancelledByStateChange {
                    throw FootprintSyncError.cancelledByStateChange
                } catch {
                    if await shouldContinue() {
                        try await store.markOutboxRetry(pointIDs: batch.items.map(\.pointID), nowMs: nowMs)
                    }
                    throw error
                }

            case .owntracks:
                result = try await sendOwnTracks(
                    store: store,
                    baseURL: baseURL,
                    token: token,
                    deviceID: deviceID,
                    points: points,
                    nowMs: nowMs,
                    shouldContinue: shouldContinue
                )
            }
            // P2-1: Before releasing single-flight lock, drain any downgrade state update queued while we were busy!
            _ = try? await drainPendingStateUpdate()
            return result
        } catch {
            // Drain any newly queued coordinate-free downgrade state update on BOTH cancellation AND transient HTTP errors (e.g. 503)
            // before releasing the single-flight lock so stationary devices never strand the notification!
            _ = try? await drainPendingStateUpdate()
            throw error
        }
    }

    /// Sends a coordinate-free state update (e.g., on full -> reduced accuracy downgrade or tracking pause).
    public func sendCoordinateFreeStateUpdate(
        settings: FootprintSettings,
        deviceID: String,
        writeToken: String,
        clearEpoch: Int64,
        accuracyAuth: FootprintAccuracyAuth,
        status: String,
        measuredAtMs: Int64 = Int64(Date().timeIntervalSince1970 * 1000.0),
        shouldContinue: @Sendable () async -> Bool = { true }
    ) async throws -> FootprintBatchSyncResult {
        guard settings.syncEnabled else { throw FootprintSyncError.syncDisabled }
        guard await shouldContinue() else { throw FootprintSyncError.cancelledByStateChange }
        guard let baseURL = settings.validatedHTTPSURL() else { throw FootprintSyncError.invalidHTTPSURL }
        let token = writeToken.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty else { throw FootprintSyncError.missingWriteToken }

        let endpoint = Self.resolveEndpointURL(base: baseURL, format: .batchJSON)
        let payload: JSONValue = .object([
            "device_id": .string(deviceID),
            "device_name": .string(settings.deviceName),
            "clear_epoch": .number(Double(clearEpoch)),
            "points": .array([]),
            "state_update": .object([
                "status": .string(status),
                "accuracy_auth": .string(accuracyAuth.rawValue),
                "measured_at_ms": .number(Double(measuredAtMs))
            ])
        ])
        let raw = try encodeJSON(payload)
        let response = try await postJSON(url: endpoint, token: token, rawJSON: raw, useGzip: true, beforeSend: shouldContinue)
        guard (200..<300).contains(response.statusCode) else {
            throw FootprintSyncError.httpStatus(response.statusCode)
        }
        return FootprintBatchSyncResult(ackedPointIDs: [], rejectedPointIDs: [], sentStateUpdateOnly: true)
    }

    private func sendBatchJSON(
        baseURL: URL,
        token: String,
        deviceID: String,
        deviceName: String,
        clearEpoch: Int64,
        points: [FootprintPoint],
        allowedIDs: Set<String>,
        beforeSend: @Sendable () async -> Bool
    ) async throws -> FootprintBatchSyncResult {
        let endpoint = Self.resolveEndpointURL(base: baseURL, format: .batchJSON)
        let serializedPoints: [JSONValue] = points.map { pt in
            var obj: [String: JSONValue] = [
                "point_id": .string(pt.pointID),
                "segment_id": .string(pt.segmentID),
                "measured_at_ms": .number(Double(pt.measuredAtMs)),
                "lat": .number(pt.latitude),
                "lng": .number(pt.longitude),
                "accuracy_m": .number(pt.accuracyMeters),
                "accuracy_auth": .string(pt.accuracyAuth.rawValue)
            ]
            if let speed = pt.speedMps { obj["speed_mps"] = .number(speed) }
            if let course = pt.courseDegrees { obj["course_deg"] = .number(course) }
            if let motion = pt.motionState { obj["motion_state"] = .string(motion.rawValue) }
            if let event = pt.transitionEvent { obj["transition_event"] = .string(event) }
            return .object(obj)
        }
        let bodyObj: JSONValue = .object([
            "device_id": .string(deviceID),
            "device_name": .string(deviceName),
            "clear_epoch": .number(Double(clearEpoch)),
            "points": .array(serializedPoints)
        ])
        let raw = try encodeJSON(bodyObj)
        guard raw.count <= Self.maxUncompressedBytes else { throw FootprintSyncError.payloadTooLarge }

        let response = try await postJSON(url: endpoint, token: token, rawJSON: raw, useGzip: true, beforeSend: beforeSend)
        guard (200..<300).contains(response.statusCode) else {
            throw FootprintSyncError.httpStatus(response.statusCode)
        }
        // Strict ACK parsing: never treat empty/malformed/missing-ACK 2xx as whole-batch success.
        guard !response.body.isEmpty,
              let decoded = try? JSONDecoder().decode(JSONValue.self, from: response.body),
              case .object(let root) = decoded,
              root["acked_point_ids"] != nil || root["rejected"] != nil else {
            throw FootprintSyncError.invalidServerAck
        }
        let acked = decoded["acked_point_ids"].array.map(\.text).filter { allowedIDs.contains($0) }
        let ackedSet = Set(acked)
        let rejected = decoded["rejected"].array.compactMap { entry -> String? in
            let direct = entry.text
            if !direct.isEmpty && allowedIDs.contains(direct) && !ackedSet.contains(direct) { return direct }
            let nested = entry["point_id"].text
            return (!nested.isEmpty && allowedIDs.contains(nested) && !ackedSet.contains(nested)) ? nested : nil
        }
        guard !acked.isEmpty || !rejected.isEmpty else {
            throw FootprintSyncError.invalidServerAck
        }
        return FootprintBatchSyncResult(ackedPointIDs: acked, rejectedPointIDs: rejected)
    }

    private func sendOwnTracks(
        store: FootprintStore,
        baseURL: URL,
        token: String,
        deviceID: String,
        points: [FootprintPoint],
        nowMs: Int64,
        shouldContinue: @Sendable () async -> Bool
    ) async throws -> FootprintBatchSyncResult {
        let endpoint = Self.resolveEndpointURL(base: baseURL, format: .owntracks)
        let tid = String(deviceID.replacingOccurrences(of: "-", with: "").prefix(2)).uppercased()
        var acked: [String] = []
        for (index, pt) in points.enumerated() {
            if pt.accuracyAuth == .full {
                let dbAuth = try await store.lastPersistedAccuracyAuth()
                if dbAuth == .reduced {
                    throw FootprintSyncError.cancelledByStateChange
                }
            }
            var obj: [String: JSONValue] = [
                "_type": .string("location"),
                "tid": .string(tid.isEmpty ? "VC" : tid),
                "lat": .number(pt.latitude),
                "lon": .number(pt.longitude),
                "acc": .number(pt.accuracyMeters.rounded()),
                "tst": .number(Double(pt.measuredAtMs / 1000)),
                "t": .string(pt.source == "visit" ? "v" : "u")
            ]
            if let speed = pt.speedMps { obj["vel"] = .number((speed * 3.6).rounded()) }
            if let course = pt.courseDegrees { obj["cog"] = .number(course.rounded()) }
            let raw = try encodeJSON(.object(obj))
            do {
                let response = try await postJSON(url: endpoint, token: token, rawJSON: raw, useGzip: false, beforeSend: shouldContinue)
                guard (200..<300).contains(response.statusCode) else {
                    throw FootprintSyncError.httpStatus(response.statusCode)
                }
                // Re-verify state AFTER POST returns and BEFORE mutating outbox (e.g., clearHistory/disable/URL switch mid-POST).
                guard await shouldContinue() else {
                    throw FootprintSyncError.cancelledByStateChange
                }
                // Acknowledge each OwnTracks point immediately upon success so failure on point N never resends 0..<N.
                try await store.acknowledgeOutbox(pointIDs: [pt.pointID])
                acked.append(pt.pointID)
            } catch FootprintSyncError.cancelledByStateChange {
                throw FootprintSyncError.cancelledByStateChange
            } catch {
                if await shouldContinue() {
                    let unacked = points[index...].map(\.pointID)
                    try await store.markOutboxRetry(pointIDs: unacked, nowMs: nowMs)
                }
                throw error
            }
        }
        return FootprintBatchSyncResult(ackedPointIDs: acked, rejectedPointIDs: [])
    }

    private func encodeJSON(_ value: JSONValue) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(value)
    }

    private func postJSON(
        url: URL,
        token: String,
        rawJSON: Data,
        useGzip: Bool,
        beforeSend: @Sendable () async -> Bool = { true }
    ) async throws -> FootprintHTTPResponse {
        var headers: [String: String] = [
            "Authorization": "Bearer \(token)",
            "Content-Type": "application/json",
            "Accept": "application/json"
        ]
        let body: Data
        if useGzip, let gz = FootprintGzip.compress(rawJSON) {
            headers["Content-Encoding"] = "gzip"
            body = gz
        } else {
            body = rawJSON
        }
        // Final synchronous-gate check IMMEDIATELY before handing the encoded/compressed payload to transport.send.
        guard await beforeSend() else {
            throw FootprintSyncError.cancelledByStateChange
        }
        return try await transport.send(FootprintHTTPRequest(
            url: url,
            method: "POST",
            headers: headers,
            body: body
        ))
    }
}