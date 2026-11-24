import Compression
import CoreLocation
import Foundation
import Testing
@testable import VChatApp
import VChatCore

private func gunzipRFC1952(_ data: Data) -> Data? {
    guard data.count >= 18, data[0] == 0x1F, data[1] == 0x8B else { return nil }
    let deflated = data.subdata(in: 10..<(data.count - 8))
    let dstCapacity = max(4096, deflated.count * 16)
    var dstBuffer = [UInt8](repeating: 0, count: dstCapacity)
    let size = deflated.withUnsafeBytes { rawSrc -> Int in
        guard let srcPtr = rawSrc.bindMemory(to: UInt8.self).baseAddress else { return 0 }
        return compression_decode_buffer(&dstBuffer, dstCapacity, srcPtr, deflated.count, nil, COMPRESSION_ZLIB)
    }
    guard size > 0 else { return nil }
    return Data(dstBuffer.prefix(size))
}

private final class StubChatManager: CLLocationManager {
    var status: CLAuthorizationStatus = .authorizedAlways
    var precision: CLAccuracyAuthorization = .fullAccuracy
    var starts = 0, stops = 0, slcStops = 0, alwaysPrompts = 0, whenInUsePrompts = 0
    var backgroundAllowed = false
    override var authorizationStatus: CLAuthorizationStatus { status }
    override var accuracyAuthorization: CLAccuracyAuthorization { precision }
    override var allowsBackgroundLocationUpdates: Bool {
        get { backgroundAllowed }
        set { backgroundAllowed = newValue }
    }
    override func requestWhenInUseAuthorization() { whenInUsePrompts += 1 }
    override func requestAlwaysAuthorization() { alwaysPrompts += 1 }
    override func startUpdatingLocation() { starts += 1 }
    override func stopUpdatingLocation() { stops += 1 }
    override func stopMonitoringSignificantLocationChanges() { slcStops += 1 }
}

private final class StubMemoryDefaults: UserDefaults {
    var store: [String: Data] = [:]
    override func set(_ value: Any?, forKey defaultName: String) {
        if let data = value as? Data { store[defaultName] = data }
        else { store.removeValue(forKey: defaultName) }
    }
    override func data(forKey defaultName: String) -> Data? { store[defaultName] }
    override func removeObject(forKey defaultName: String) { store.removeValue(forKey: defaultName) }
}

@MainActor private final class StubPowerSaverDriver: FootprintPowerSaverDriver {
    var active = false
    var visitsMonitoring = false
    var slcMonitoring = false
    var allowsBackgroundUpdates = false
    var authorizationStatus: CLAuthorizationStatus = .authorizedAlways
    var accuracyAuthorization: CLAccuracyAuthorization = .fullAccuracy
    var startCalls = 0
    var stopCalls = 0
    var alwaysRequests = 0
    var onSamples: (@MainActor ([FootprintRawSample]) -> Void)?
    var onAuthChanged: (@MainActor () -> Void)?

    func observeAuthorization(_ handler: @escaping @MainActor () -> Void) {
        self.onAuthChanged = handler
    }

    func requestAlwaysAuthorization() { alwaysRequests += 1 }

    func start(
        backgroundAllowed: Bool,
        onSamples: @escaping @MainActor ([FootprintRawSample]) -> Void,
        onAuthorizationChanged: @escaping @MainActor () -> Void
    ) {
        self.onSamples = onSamples
        self.onAuthChanged = onAuthorizationChanged
        active = true
        visitsMonitoring = true
        slcMonitoring = true
        allowsBackgroundUpdates = backgroundAllowed
        startCalls += 1
    }

    func stop() {
        if active { stopCalls += 1 }
        active = false
        visitsMonitoring = false
        slcMonitoring = false
        allowsBackgroundUpdates = false
    }
}

@MainActor private final class StubLiveStreamDriver: FootprintLiveStreamDriver {
    var active = false
    var hasBackgroundSession = false
    var startCalls = 0
    var stopCalls = 0
    var onEvent: (@MainActor (FootprintLiveStreamEvent) -> Void)?

    func start(
        backgroundAllowed: Bool,
        accuracyProvider: @escaping @MainActor () -> CLAccuracyAuthorization,
        onEvent: @escaping @MainActor (FootprintLiveStreamEvent) -> Void
    ) {
        self.onEvent = onEvent
        active = true
        hasBackgroundSession = backgroundAllowed
        startCalls += 1
    }

    func stop() {
        if active { stopCalls += 1 }
        active = false
        hasBackgroundSession = false
    }
}

private final class ToggleableProtector: FootprintStorageProtector, @unchecked Sendable {
    private let lock = NSLock()
    private var _locked = false
    private let real = SystemFootprintStorageProtector()

    var locked: Bool {
        get { lock.withLock { _locked } }
        set { lock.withLock { _locked = newValue } }
    }

    func prepareDirectory(_ directoryURL: URL) throws {
        if locked { throw FootprintStoreError.protectedDataUnavailable }
        try real.prepareDirectory(directoryURL)
    }

    func protectDatabaseFile(_ databaseURL: URL) throws {
        if locked { throw FootprintStoreError.protectedDataUnavailable }
        try real.protectDatabaseFile(databaseURL)
    }
}

private actor StubSecretStore: FootprintSecretStore {
    var values: [String: String] = [:]
    var locked = false
    var saveCount = 0

    func setLocked(_ value: Bool) { locked = value }
    func setValues(_ next: [String: String]) { values = next }
    func getSaveCount() -> Int { saveCount }

    func readSecret(_ name: String, allowingInteraction: Bool) async throws -> String {
        if locked && !allowingInteraction {
            throw CredentialVault.AccessError.authorizationRequired
        }
        return values[name] ?? ""
    }

    func saveSecret(_ value: String, name: String) async throws {
        saveCount += 1
        values[name] = value
    }
}

private actor CapturingHTTPTransport: FootprintHTTPTransport {
    var requests: [FootprintHTTPRequest] = []
    var statusCode = 200
    var responseBody = Data("{\"acked_point_ids\":[],\"rejected\":[]}".utf8)

    func setResponse(statusCode: Int, body: Data) {
        self.statusCode = statusCode
        self.responseBody = body
    }

    func recorded() -> [FootprintHTTPRequest] { requests }

    func send(_ request: FootprintHTTPRequest) async throws -> FootprintHTTPResponse {
        requests.append(request)
        return FootprintHTTPResponse(statusCode: statusCode, body: responseBody)
    }
}

@MainActor @Suite("LocationAcquisitionCoordinator & Non-UI Background Restore")
struct FootprintCoordinatorTests {
    private func makeTempDir(_ tag: String) -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("vchat-coord-\(tag)-\(UUID().uuidString)", isDirectory: true)
    }

    @Test("Three-condition AND gate: launchOptions[.location] never bypasses disabled, non-Always, or missing recoverable session")
    func backgroundRestoreThreeConditionGate() async throws {
        let dir = makeTempDir("restore-gate")
        defer { try? FileManager.default.removeItem(at: dir) }
        let defaults = StubMemoryDefaults()
        let powerDriver = StubPowerSaverDriver()
        let liveDriver = StubLiveStreamDriver()
        let secretStore = StubSecretStore()
        await secretStore.setValues([PersistentFootprintKeychain.deviceIDAccount: "stable-dev-id"])

        let tracker = FootprintTracker(
            defaults: defaults,
            directoryURL: dir,
            secretStore: secretStore,
            powerSaverDriver: powerDriver,
            liveStreamDriver: liveDriver
        )

        // 1. Disabled + launchOptions[.location] = true -> MUST skip
        let r1 = await tracker.attemptBackgroundRestore(launchHadLocationKey: true)
        #expect(r1 == .skippedDisabled)
        #expect(!tracker.running && !powerDriver.active)

        // 2. Enabled + non-Always (.denied / .notDetermined) + launchOptions[.location] = true -> MUST skip
        powerDriver.authorizationStatus = .notDetermined
        var settings = FootprintSettings(enabled: true, mode: .powerSaver, recoverableBackgroundSession: true)
        await tracker.applySettings(settings)
        let r2 = await tracker.attemptBackgroundRestore(launchHadLocationKey: true)
        #expect(r2 == .skippedAuthorizationNotAlways)
        #expect(!tracker.running && !powerDriver.active)

        // 3. Enabled + Always + recoverableBackgroundSession == false -> MUST skip with ZERO intermediate starts!
        powerDriver.authorizationStatus = .authorizedAlways
        settings.recoverableBackgroundSession = false
        await tracker.applySettings(settings)
        let r3 = await tracker.attemptBackgroundRestore(launchHadLocationKey: true)
        #expect(r3 == .skippedNoRecoverableSession)
        #expect(!tracker.running && !powerDriver.active && powerDriver.startCalls == 0)

        // 4. All three conditions true -> restores power-saver mode
        settings.recoverableBackgroundSession = true
        await tracker.applySettings(settings)
        let r4 = await tracker.attemptBackgroundRestore(launchHadLocationKey: true)
        #expect(r4 == .restored(.powerSaver))
        #expect(tracker.running && powerDriver.active && powerDriver.visitsMonitoring && powerDriver.slcMonitoring && powerDriver.allowsBackgroundUpdates)
    }

    @Test("Unlocked DB with locked Keychain defers restore without creating identity; generic storage error reports failedStorageError")
    func unlockedDBLockedKeychainAndGenericStorageError() async throws {
        let dir = makeTempDir("keychain-only-lock")
        defer { try? FileManager.default.removeItem(at: dir) }
        let defaults = StubMemoryDefaults()
        let powerDriver = StubPowerSaverDriver()
        powerDriver.authorizationStatus = .authorizedAlways
        let secretStore = StubSecretStore()
        await secretStore.setLocked(true)
        await secretStore.setValues([PersistentFootprintKeychain.deviceIDAccount: "keep-my-id"])

        let savedSettings = FootprintSettings(enabled: true, mode: .powerSaver, recoverableBackgroundSession: true)
        defaults.set(try JSONEncoder().encode(savedSettings), forKey: FootprintTracker.settingsDefaultsKey)

        // Case A: Directory/DB opens fine, ONLY Keychain throws authorizationRequired -> deferredUntilFirstUnlock
        let tracker = FootprintTracker(
            defaults: defaults,
            directoryURL: dir,
            secretStore: secretStore,
            powerSaverDriver: powerDriver
        )
        let outcome = await tracker.attemptBackgroundRestore(launchHadLocationKey: true)
        #expect(outcome == .deferredUntilFirstUnlock)
        #expect(tracker.waitingForFirstUnlock == true)
        #expect(await secretStore.getSaveCount() == 0)

        await secretStore.setLocked(false)
        let resumed = await tracker.handleProtectedDataBecameAvailable()
        #expect(resumed == .restored(.powerSaver))
        #expect(tracker.deviceID == "keep-my-id")

        // Case B: Non-protection storage error -> failedStorageError and waitingForFirstUnlock == false
        struct BrokenProtector: FootprintStorageProtector {
            func prepareDirectory(_ directoryURL: URL) throws {
                throw FootprintStoreError.storagePreparationFailed("disk full")
            }
            func protectDatabaseFile(_ databaseURL: URL) throws {}
        }
        let brokenTracker = FootprintTracker(
            defaults: defaults,
            directoryURL: makeTempDir("broken"),
            protector: BrokenProtector(),
            secretStore: secretStore,
            powerSaverDriver: powerDriver
        )
        let errOutcome = await brokenTracker.attemptBackgroundRestore(launchHadLocationKey: true)
        #expect(errOutcome == .failedStorageError(FootprintStoreError.storagePreparationFailed("disk full").localizedDescription))
        #expect(brokenTracker.waitingForFirstUnlock == false)
        #expect(brokenTracker.lastStorageError != nil)
    }

    @Test("Restart downgrade calibration purges stale precise outbox; switching URL isolates token/queue; stream exit resets running")
    func restartDowngradeURLSwitchAndStreamEnd() async throws {
        let dir = makeTempDir("downgrade-url")
        defer { try? FileManager.default.removeItem(at: dir) }
        let defaults = StubMemoryDefaults()
        let secretStore = StubSecretStore()
        await secretStore.setValues([PersistentFootprintKeychain.deviceIDAccount: "dev-cal"])

        // Pre-populate DB with lastPersistedAccuracyAuth = .full and 1 pending precise outbox point
        let preStore = try await FootprintStore.open(directoryURL: dir)
        try await preStore.setLastPersistedAccuracyAuth(.full)
        let oldPrecise = FootprintPoint(pointID: "stale-pr", segmentID: "s1", measuredAtMs: 1_795_500_000_000, latitude: 52.95, longitude: -1.15, accuracyMeters: 5, accuracyAuth: .full)
        _ = try await preStore.append([oldPrecise], enqueueForSync: true, destinationKey: "https://server-a.example.com", nowMs: 1_795_500_000_000)

        // Simulate app relaunch after user downgraded to .reducedAccuracy while app was terminated
        let powerDriver = StubPowerSaverDriver()
        powerDriver.authorizationStatus = .authorizedAlways
        powerDriver.accuracyAuthorization = .reducedAccuracy
        let liveDriver = StubLiveStreamDriver()

        let settings = FootprintSettings(enabled: true, mode: .continuous, syncEnabled: true, syncEndpointURL: "https://server-a.example.com", recoverableBackgroundSession: true)
        defaults.set(try JSONEncoder().encode(settings), forKey: FootprintTracker.settingsDefaultsKey)

        let tracker = FootprintTracker(
            defaults: defaults,
            directoryURL: dir,
            secretStore: secretStore,
            powerSaverDriver: powerDriver,
            liveStreamDriver: liveDriver
        )
        let res = await tracker.attemptBackgroundRestore(launchHadLocationKey: true)
        #expect(res == .restored(.continuous))
        #expect(try await preStore.pendingOutboxCount() == 0)
        #expect(try await preStore.pendingStateUpdate()?.accuracyAuth == .reduced)

        // Switching URL via commitSyncConfiguration isolates token and drops old destination queue
        try await tracker.commitSyncConfiguration(endpointURL: "https://server-a.example.com", format: .batchJSON, writeToken: "token-A")
        let queuedForA = FootprintPoint(pointID: "for-a", segmentID: "s2", measuredAtMs: 1_795_500_100_000, latitude: 52.95, longitude: -1.15, accuracyMeters: 2000, accuracyAuth: .reduced)
        _ = try await preStore.append([queuedForA], enqueueForSync: true, destinationKey: "https://server-a.example.com", nowMs: 1_795_500_100_000)
        #expect(try await preStore.pendingOutboxCount() == 1)

        try await tracker.commitSyncConfiguration(endpointURL: "https://server-b.example.com", format: .batchJSON, writeToken: nil)
        #expect(try await preStore.pendingOutboxCount() == 0)
        let tokenForB = try await tracker.readWriteToken(for: "https://server-b.example.com", allowingInteraction: false)
        #expect(tokenForB.isEmpty)

        // Stream exit resets tracker.running
        liveDriver.onEvent?(.ended)
        await Task.yield()
        #expect(tracker.running == false)

        // Clearing history also removes temporary GeoJSON exports
        let exportDir = FootprintTracker.exportDirectoryURL
        try FileManager.default.createDirectory(at: exportDir, withIntermediateDirectories: true)
        let tempExport = exportDir.appendingPathComponent("test.geojson")
        try Data("{}".utf8).write(to: tempExport)
        #expect(FileManager.default.fileExists(atPath: tempExport.path))
        _ = try await tracker.clearHistory(beforeMs: nil)
        #expect(!FileManager.default.fileExists(atPath: tempExport.path))
    }

    @Test("End-to-end outbound guarantees: cold-start auth callback before restore, buffered in-memory precise point on downgrade, and URL switch with local tracking disabled")
    func outboundDowngradeBufferedPointAndURLSwitchIsolation() async throws {
        // Case 1: Cold-start reduced auth callback arrives BEFORE restore -> old precise outbox purged;
        //         outbound HTTP sends ONLY coordinate-free state_update, NEVER stale precise coordinates!
        let dir1 = makeTempDir("cold-auth-first")
        defer { try? FileManager.default.removeItem(at: dir1) }
        let preStore1 = try await FootprintStore.open(directoryURL: dir1)
        try await preStore1.setLastPersistedAccuracyAuth(.full)
        let stalePrecise = FootprintPoint(pointID: "old-full-1", segmentID: "s1", measuredAtMs: 1_795_600_000_000, latitude: 52.9501, longitude: -1.1501, accuracyMeters: 5, accuracyAuth: .full)
        _ = try await preStore1.append([stalePrecise], enqueueForSync: true, destinationKey: "https://srv-a.example.com", nowMs: 1_795_600_000_000)

        let defaults1 = StubMemoryDefaults()
        let settings1 = FootprintSettings(enabled: true, mode: .continuous, syncEnabled: true, syncEndpointURL: "https://srv-a.example.com", syncFormat: .batchJSON, recoverableBackgroundSession: true)
        defaults1.set(try JSONEncoder().encode(settings1), forKey: FootprintTracker.settingsDefaultsKey)

        let secrets1 = StubSecretStore()
        await secrets1.setValues([
            PersistentFootprintKeychain.deviceIDAccount: "dev-auth-first",
            FootprintIdentityStore.writeTokenAccount(for: "https://srv-a.example.com"): "tok-A"
        ])
        let transport1 = CapturingHTTPTransport()
        let power1 = StubPowerSaverDriver()
        power1.authorizationStatus = .authorizedAlways
        power1.accuracyAuthorization = .reducedAccuracy
        let live1 = StubLiveStreamDriver()

        let tracker1 = FootprintTracker(
            defaults: defaults1,
            directoryURL: dir1,
            secretStore: secrets1,
            syncClient: FootprintSyncClient(transport: transport1),
            powerSaverDriver: power1,
            liveStreamDriver: live1
        )
        // Simulate delegate firing BEFORE attemptBackgroundRestore!
        await tracker1.handleAuthorizationChanged()
        _ = await tracker1.attemptBackgroundRestore(launchHadLocationKey: true)
        _ = await tracker1.syncNow()

        let reqs1 = await transport1.recorded()
        #expect(reqs1.count == 1)
        #expect(reqs1[0].url.absoluteString == "https://srv-a.example.com/ingest/batch")
        #expect(reqs1[0].headers["Authorization"] == "Bearer tok-A")
        #expect(reqs1[0].headers["Content-Encoding"] == "gzip")
        #expect(reqs1[0].body.prefix(2) == Data([0x1F, 0x8B]))
        let decompressed1 = try #require(gunzipRFC1952(reqs1[0].body))
        let bodyJSON1 = try JSONDecoder().decode(JSONValue.self, from: decompressed1)
        #expect(bodyJSON1["points"].array.isEmpty)
        #expect(bodyJSON1["state_update"]["accuracy_auth"].text == "reduced")
        #expect(try await preStore1.pendingOutboxCount() == 0)
        // Also verify cold-start restore alone (without manual syncNow) dispatches the coordinate-free downgrade state update!
        // Use a real relative clock (`tLaunch - 300` for DB last point, `tLaunch - 60` for pre-launch sample) so the
        // pre-launch sample is STRICTLY newer than DB last point and ONLY blocked by cold-start `accuracyChangedAt`!
        let dir1b = makeTempDir("cold-auto-notify")
        defer { try? FileManager.default.removeItem(at: dir1b) }
        let tLaunch = 1_795_600_500.0
        let preStore1b = try await FootprintStore.open(directoryURL: dir1b)
        try await preStore1b.setLastPersistedAccuracyAuth(.full)
        let stale1bMs = Int64((tLaunch - 300.0) * 1000.0)
        let stale1b = FootprintPoint(pointID: "old-full-1b", segmentID: "s1", measuredAtMs: stale1bMs, latitude: 52.9501, longitude: -1.1501, accuracyMeters: 5, accuracyAuth: .full)
        _ = try await preStore1b.append([stale1b], enqueueForSync: true, destinationKey: "https://srv-a.example.com", nowMs: stale1bMs)
        let transport1b = CapturingHTTPTransport()
        let power1b = StubPowerSaverDriver()
        power1b.authorizationStatus = .authorizedAlways
        power1b.accuracyAuthorization = .reducedAccuracy
        let tracker1b = FootprintTracker(
            defaults: defaults1,
            directoryURL: dir1b,
            secretStore: secrets1,
            syncClient: FootprintSyncClient(transport: transport1b),
            powerSaverDriver: power1b,
            liveStreamDriver: StubLiveStreamDriver(),
            now: { tLaunch }
        )
        _ = await tracker1b.attemptBackgroundRestore(launchHadLocationKey: true)
        #expect(await transport1b.recorded().count == 1)
        #expect(try await preStore1b.pendingStateUpdate() == nil)
        #expect(try await preStore1b.pendingOutboxCount() == 0)
        // P1-3B Cold-start late measurement: strictly newer than DB last point (tLaunch-300),
        // strictly older than cold-start calibration (tLaunch) -> MUST be dropped by cold-start accuracyChangedAt!
        let preLaunchTs = tLaunch - 60.0
        await tracker1b.ingestRawSamples([
            FootprintRawSample(latitude: 52.9999, longitude: -1.1999, accuracyMeters: 5, measuredAt: preLaunchTs, precise: false)
        ])
        let points1b = try await preStore1b.points(fromMs: 0, toMs: Int64.max)
        #expect(!points1b.contains { abs($0.latitude - 52.9999) < 0.0001 })

        // Case 2: Buffered in-memory collinear precise point MUST be discarded on downgrade and NEVER flushed or uploaded!
        let dir2 = makeTempDir("buffered-precise")
        defer { try? FileManager.default.removeItem(at: dir2) }
        var t2 = 1_795_700_000.0
        let defaults2 = StubMemoryDefaults()
        let secrets2 = StubSecretStore()
        await secrets2.setValues([
            PersistentFootprintKeychain.deviceIDAccount: "dev-buf",
            FootprintIdentityStore.writeTokenAccount(for: "https://srv-a.example.com"): "tok-A"
        ])
        let transport2 = CapturingHTTPTransport()
        let power2 = StubPowerSaverDriver()
        power2.authorizationStatus = .authorizedAlways
        power2.accuracyAuthorization = .fullAccuracy
        let live2 = StubLiveStreamDriver()
        let tracker2 = FootprintTracker(
            defaults: defaults2,
            directoryURL: dir2,
            secretStore: secrets2,
            syncClient: FootprintSyncClient(transport: transport2),
            powerSaverDriver: power2,
            liveStreamDriver: live2,
            now: { t2 }
        )
        tracker2.setForeground(true)
        await tracker2.applySettings(FootprintSettings(enabled: true, mode: .continuous, syncEnabled: true, syncEndpointURL: "https://srv-a.example.com", syncFormat: .owntracks))

        // Feed 3 collinear 15m steps -> step 3 sits in engine.pendingCollinearPoint (uncommitted in memory!)
        let dLon15m = 15.0 / (111_320.0 * cos(52.95 * Double.pi / 180.0))
        await tracker2.ingestRawSamples([
            FootprintRawSample(latitude: 52.9500, longitude: -1.1500, accuracyMeters: 5, measuredAt: t2, precise: true, speedMps: 1.5),
            FootprintRawSample(latitude: 52.9500, longitude: -1.1500 + dLon15m, accuracyMeters: 5, measuredAt: t2 + 10, precise: true, speedMps: 1.5),
            FootprintRawSample(latitude: 52.9500, longitude: -1.1500 + 2 * dLon15m, accuracyMeters: 5, measuredAt: t2 + 20, precise: true, speedMps: 1.5)
        ], isStationary: false)
        let preStore2 = try await tracker2.openStoreForUI()
        #expect(try await preStore2.totalPointCount() == 2) // 3rd point is buffered in memory

        // Snapshot outbound requests sent BEFORE downgrade (while accuracy was legitimately full).
        let beforeDowngradeCount = await transport2.recorded().count

        // Advance clock to downgrade instant, then downgrade to reduced!
        t2 += 30
        power2.accuracyAuthorization = .reducedAccuracy
        await tracker2.handleAuthorizationChanged()

        // Feed:
        // 1. A late precise sample (precise=true) -> dropped;
        // 2. A pre-downgrade precise coordinate relabeled as precise=false by a production driver (measuredAt < downgrade time) -> MUST ALSO BE DROPPED!
        // 3. A genuine post-downgrade reduced sample (measuredAt >= downgrade time) -> accepted without flushing buffered precise point!
        let downgradeTime = t2
        t2 += 10
        await tracker2.ingestRawSamples([
            FootprintRawSample(latitude: 52.9500, longitude: -1.1500 + 3 * dLon15m, accuracyMeters: 5, measuredAt: downgradeTime - 5, precise: true, speedMps: 1.5),
            FootprintRawSample(latitude: 52.9509, longitude: -1.1509, accuracyMeters: 6, measuredAt: downgradeTime - 2, precise: false),
            FootprintRawSample(latitude: 52.9600, longitude: -1.1600, accuracyMeters: 2500, measuredAt: downgradeTime + 5, precise: false)
        ], isStationary: false)
        _ = await tracker2.syncNow()

        let storedPoints2 = try await preStore2.points(fromMs: 0, toMs: Int64.max)
        #expect(storedPoints2.count == 3) // Only the 2 earlier full points + 1 genuine post-downgrade reduced point!
        let postDowngradeReqs = Array((await transport2.recorded()).dropFirst(beforeDowngradeCount))
        #expect(postDowngradeReqs.count == 1)
        let uploadedJSON2 = try JSONDecoder().decode(JSONValue.self, from: postDowngradeReqs[0].body)
        #expect(uploadedJSON2["lat"].number == 52.96)

        // Case 3: Local tracking DISABLED (`enabled = false`) + `syncEnabled = true` -> switching URL A -> B
        //         MUST still clear A's outbox and NEVER send A's token or A's queued coordinates to B!
        let dir3 = makeTempDir("url-switch-disabled-track")
        defer { try? FileManager.default.removeItem(at: dir3) }
        let preStore3 = try await FootprintStore.open(directoryURL: dir3)
        let queuedA = FootprintPoint(pointID: "a-queued", segmentID: "sA", measuredAtMs: 1_795_800_000_000, latitude: 52.95, longitude: -1.15, accuracyMeters: 8, accuracyAuth: .full)
        _ = try await preStore3.append([queuedA], enqueueForSync: true, destinationKey: "https://server-a.example.com", nowMs: 1_795_800_000_000)

        let defaults3 = StubMemoryDefaults()
        let initSettings3 = FootprintSettings(enabled: false, mode: .powerSaver, syncEnabled: true, syncEndpointURL: "https://server-a.example.com", syncFormat: .owntracks)
        defaults3.set(try JSONEncoder().encode(initSettings3), forKey: FootprintTracker.settingsDefaultsKey)

        let secrets3 = StubSecretStore()
        await secrets3.setValues([
            PersistentFootprintKeychain.deviceIDAccount: "dev-switch",
            FootprintIdentityStore.writeTokenAccount(for: "https://server-a.example.com"): "secret-token-A"
        ])
        let transport3 = CapturingHTTPTransport()
        let tracker3 = FootprintTracker(
            defaults: defaults3,
            directoryURL: dir3,
            secretStore: secrets3,
            syncClient: FootprintSyncClient(transport: transport3),
            powerSaverDriver: StubPowerSaverDriver(),
            liveStreamDriver: StubLiveStreamDriver()
        )
        // Simulate UI switching URL A -> B (UI clears token draft to "" when URL changes) while local tracking is OFF
        try await tracker3.commitSyncConfiguration(endpointURL: "https://server-b.example.com", format: .owntracks, writeToken: "")
        #expect(try await preStore3.pendingOutboxCount() == 0)
        _ = await tracker3.syncNow()
        #expect(await transport3.recorded().isEmpty)

        // Even if a concurrent point was enqueued tagged for server A (or case-different path /TeamA vs /teama),
        // server B's sync MUST NEVER dequeue or send it!
        let concurrentA = FootprintPoint(pointID: "a-concurrent", segmentID: "sA2", measuredAtMs: 1_795_800_050_000, latitude: 52.11, longitude: -1.11, accuracyMeters: 8, accuracyAuth: .full)
        _ = try await preStore3.append([concurrentA], enqueueForSync: true, destinationKey: "https://server-a.example.com", nowMs: 1_795_800_050_000)

        try await tracker3.saveWriteToken("secret-token-B", for: "https://server-b.example.com")
        let freshB = FootprintPoint(pointID: "b-fresh", segmentID: "sB", measuredAtMs: 1_795_800_100_000, latitude: 53.00, longitude: -1.20, accuracyMeters: 8, accuracyAuth: .full)
        _ = try await preStore3.append([freshB], enqueueForSync: true, destinationKey: "https://server-b.example.com", nowMs: 1_795_800_100_000)
        _ = await tracker3.syncNow()
        let reqs3 = await transport3.recorded()
        #expect(reqs3.count == 1)
        #expect(reqs3[0].url.absoluteString == "https://server-b.example.com/ingest/owntracks")
        #expect(reqs3[0].headers["Authorization"] == "Bearer secret-token-B")
        let bodyB = try JSONDecoder().decode(JSONValue.self, from: reqs3[0].body)
        #expect(bodyB["lat"].number == 53.0)

        // Case 4: P1-3A + P2-1 -> Gate is TRUE initially, then system downgrades to .reduced WHILE waiting
        //         before transport.send (after DB dequeue & encoding!) -> precise batch sends 0 coordinate POSTs,
        //         AND the newly queued coordinate-free downgrade state update is drained before releasing single-flight lock!
        let dir4 = makeTempDir("mid-flight-downgrade")
        defer { try? FileManager.default.removeItem(at: dir4) }
        let store4 = try await FootprintStore.open(directoryURL: dir4)
        try await store4.setLastPersistedAccuracyAuth(.full)
        let pt4 = FootprintPoint(pointID: "p4", segmentID: "s4", measuredAtMs: 1_795_900_000_000, latitude: 52.95, longitude: -1.15, accuracyMeters: 5, accuracyAuth: .full)
        _ = try await store4.append([pt4], enqueueForSync: true, destinationKey: "https://srv-a.example.com", nowMs: 1_795_900_000_000)
        let transport4 = CapturingHTTPTransport()
        let client4 = FootprintSyncClient(transport: transport4)
        let settings4 = FootprintSettings(enabled: true, syncEnabled: true, syncEndpointURL: "https://srv-a.example.com", syncFormat: .batchJSON)

        actor DowngradeTrigger {
            var downgraded = false
            func checkAndTriggerDowngrade(store: FootprintStore) async -> Bool {
                if !downgraded {
                    // Simulate live downgrade + DB calibration queuing reduced state update right before transport.send!
                    downgraded = true
                    _ = try? await store.reconcileAccuracyAuthorization(.reduced, enqueueBatchStateUpdate: true, nowMs: 1_795_900_010_000)
                }
                return false
            }
        }
        let trigger4 = DowngradeTrigger()
        do {
            _ = try await client4.flushOutbox(
                store: store4,
                settings: settings4,
                deviceID: "dev-4",
                writeToken: "tok-4",
                currentAccuracyAuth: .full,
                nowMs: 1_795_900_000_000,
                shouldContinue: { await trigger4.checkAndTriggerDowngrade(store: store4) },
                allowStateUpdateDrain: { true }
            )
            Issue.record("Expected cancelledByStateChange for precise batch")
        } catch let err as FootprintSyncError {
            #expect(err == .cancelledByStateChange)
        }
        // Exactly 1 POST went out: the drained coordinate-free state_update (points=[]), ZERO precise coordinates!
        let reqs4 = await transport4.recorded()
        #expect(reqs4.count == 1)
        let decomp4 = try #require(gunzipRFC1952(reqs4[0].body))
        let json4 = try JSONDecoder().decode(JSONValue.self, from: decomp4)
        #expect(json4["points"].array.isEmpty)
        #expect(json4["state_update"]["accuracy_auth"].text == "reduced")
        #expect(try await store4.pendingStateUpdate() == nil)

        // Case 5: P1-5B Buffered in-memory corner captured under Server A MUST NOT leak to Server B after switch!
        let dir5 = makeTempDir("corner-dest-isolation")
        defer { try? FileManager.default.removeItem(at: dir5) }
        var t5 = 1_795_950_000.0
        let defaults5 = StubMemoryDefaults()
        let secrets5 = StubSecretStore()
        await secrets5.setValues([
            PersistentFootprintKeychain.deviceIDAccount: "dev-corner-switch",
            FootprintIdentityStore.writeTokenAccount(for: "https://server-a.example.com"): "tok-A",
            FootprintIdentityStore.writeTokenAccount(for: "https://server-b.example.com"): "tok-B"
        ])
        let transport5 = CapturingHTTPTransport()
        let power5 = StubPowerSaverDriver()
        power5.authorizationStatus = .authorizedAlways
        power5.accuracyAuthorization = .fullAccuracy
        let tracker5 = FootprintTracker(
            defaults: defaults5,
            directoryURL: dir5,
            secretStore: secrets5,
            syncClient: FootprintSyncClient(transport: transport5),
            powerSaverDriver: power5,
            liveStreamDriver: StubLiveStreamDriver(),
            now: { t5 }
        )
        tracker5.setForeground(true)
        await tracker5.applySettings(FootprintSettings(enabled: true, mode: .continuous, syncEnabled: true, syncEndpointURL: "https://server-a.example.com", syncFormat: .owntracks))
        let dLat15 = 15.0 / 111_132.0
        let dLon15 = 15.0 / (111_320.0 * cos(52.95 * Double.pi / 180.0))
        let cornerLonA = -1.1500 + 2 * dLon15
        // 3 collinear points under Server A -> 3rd point sits in engine.pendingCollinearPoint!
        await tracker5.ingestRawSamples([
            FootprintRawSample(latitude: 52.9500, longitude: -1.1500, accuracyMeters: 5, measuredAt: t5, precise: true, speedMps: 1.5),
            FootprintRawSample(latitude: 52.9500, longitude: -1.1500 + dLon15, accuracyMeters: 5, measuredAt: t5 + 10, precise: true, speedMps: 1.5),
            FootprintRawSample(latitude: 52.9500, longitude: cornerLonA, accuracyMeters: 5, measuredAt: t5 + 20, precise: true, speedMps: 1.5)
        ], isStationary: false)
        // Switch destination A -> B
        try await tracker5.commitSyncConfiguration(endpointURL: "https://server-b.example.com", format: .owntracks, writeToken: "tok-B")
        let countBeforeB = await transport5.recorded().count
        // First turn under Server B -> MUST NOT flush A's buffered corner point to B!
        t5 += 30
        await tracker5.ingestRawSamples([
            FootprintRawSample(latitude: 52.9500 + dLat15, longitude: cornerLonA, accuracyMeters: 5, measuredAt: t5, precise: true, speedMps: 1.5)
        ], isStationary: false)
        _ = await tracker5.syncNow()
        let reqsToB = Array((await transport5.recorded()).dropFirst(countBeforeB))
        #expect(reqsToB.count == 1)
        #expect(reqsToB[0].url.absoluteString == "https://server-b.example.com/ingest/owntracks")
        #expect(reqsToB[0].headers["Authorization"] == "Bearer tok-B")
        let bodyToB = try JSONDecoder().decode(JSONValue.self, from: reqsToB[0].body)
        // Only B's turned point (lat = 52.9500 + dLat15) was sent, NEVER A's buffered corner (lat = 52.9500)!
        #expect(abs((bodyToB["lat"].number ?? 0) - (52.9500 + dLat15)) < 0.00001)

        // Case 6: §3.4 Stationary zero-heartbeat -> prolonged 510s stay produces EXACTLY 1 dwelled_5m POST!
        let dir6 = makeTempDir("stationary-single-post")
        defer { try? FileManager.default.removeItem(at: dir6) }
        var t6 = 1_795_960_000.0
        let defaults6 = StubMemoryDefaults()
        let transport6 = CapturingHTTPTransport()
        let power6 = StubPowerSaverDriver()
        power6.authorizationStatus = .authorizedAlways
        power6.accuracyAuthorization = .fullAccuracy
        let tracker6 = FootprintTracker(
            defaults: defaults6,
            directoryURL: dir6,
            secretStore: secrets5,
            syncClient: FootprintSyncClient(transport: transport6),
            powerSaverDriver: power6,
            liveStreamDriver: StubLiveStreamDriver(),
            now: { t6 }
        )
        tracker6.setForeground(true)
        await tracker6.applySettings(FootprintSettings(enabled: true, mode: .continuous, syncEnabled: true, syncEndpointURL: "https://server-b.example.com", syncFormat: .owntracks))
        for step in 0...17 {
            t6 = 1_795_960_000.0 + Double(step * 30)
            await tracker6.ingestRawSamples([
                FootprintRawSample(latitude: 52.9500, longitude: -1.1500, accuracyMeters: 6, measuredAt: t6, precise: true, speedMps: 0.0)
            ], isStationary: true)
        }
        // Only the 2 points (initial + single dwelled_5m) uploaded once at t=300; t=330..510 triggered 0 extra POSTs!
        let dwellReqs = await transport6.recorded()
        #expect(dwellReqs.count == 2)

        // Case 7: P1-5B Sync-OFF collinear 3rd point -> turn sync ON -> turn corner:
        //         the 3rd point captured while sync was OFF MUST NEVER be uploaded (only the 4th point captured with sync ON)!
        let dir7 = makeTempDir("sync-off-buffered-point")
        defer { try? FileManager.default.removeItem(at: dir7) }
        var t7 = 1_795_970_000.0
        let defaults7 = StubMemoryDefaults()
        let transport7 = CapturingHTTPTransport()
        let power7 = StubPowerSaverDriver()
        power7.authorizationStatus = .authorizedAlways
        power7.accuracyAuthorization = .fullAccuracy
        let tracker7 = FootprintTracker(
            defaults: defaults7,
            directoryURL: dir7,
            secretStore: secrets5,
            syncClient: FootprintSyncClient(transport: transport7),
            powerSaverDriver: power7,
            liveStreamDriver: StubLiveStreamDriver(),
            now: { t7 }
        )
        tracker7.setForeground(true)
        await tracker7.applySettings(FootprintSettings(enabled: true, mode: .continuous, syncEnabled: false, syncEndpointURL: "https://server-b.example.com", syncFormat: .owntracks))
        // Walk 3 collinear steps while syncEnabled == false -> 3rd point buffered in memory with syncDestinationKey = nil!
        await tracker7.ingestRawSamples([
            FootprintRawSample(latitude: 52.9500, longitude: -1.1500, accuracyMeters: 5, measuredAt: t7, precise: true, speedMps: 1.5),
            FootprintRawSample(latitude: 52.9500, longitude: -1.1500 + dLon15, accuracyMeters: 5, measuredAt: t7 + 10, precise: true, speedMps: 1.5),
            FootprintRawSample(latitude: 52.9500, longitude: cornerLonA, accuracyMeters: 5, measuredAt: t7 + 20, precise: true, speedMps: 1.5)
        ], isStationary: false)
        // Enable sync WITHOUT changing URL, then turn corner -> 3rd point flushes to local DB ONLY, NEVER to outbox/network!
        await tracker7.applySettings(FootprintSettings(enabled: true, mode: .continuous, syncEnabled: true, syncEndpointURL: "https://server-b.example.com", syncFormat: .owntracks))
        t7 += 30
        await tracker7.ingestRawSamples([
            FootprintRawSample(latitude: 52.9500 + dLat15, longitude: cornerLonA, accuracyMeters: 5, measuredAt: t7, precise: true, speedMps: 1.5)
        ], isStationary: false)
        _ = await tracker7.syncNow()
        let reqs7 = await transport7.recorded()
        #expect(reqs7.count == 1)
        let body7 = try JSONDecoder().decode(JSONValue.self, from: reqs7[0].body)
        #expect(abs((body7["lat"].number ?? 0) - (52.9500 + dLat15)) < 0.00001)

        // Case 8: P2-1 Old coordinate POST returns HTTP 503 while downgrade state update was queued ->
        //         single-flight catch branch MUST still drain the coordinate-free downgrade state update!
        let dir8 = makeTempDir("http-503-drain-state")
        defer { try? FileManager.default.removeItem(at: dir8) }
        let store8 = try await FootprintStore.open(directoryURL: dir8)
        let pt8 = FootprintPoint(pointID: "p8", segmentID: "s8", measuredAtMs: 1_795_980_000_000, latitude: 52.95, longitude: -1.15, accuracyMeters: 5, accuracyAuth: .full)
        _ = try await store8.append([pt8], enqueueForSync: true, destinationKey: "https://srv-a.example.com", nowMs: 1_795_980_000_000)
        actor FailThenDrainTransport: FootprintHTTPTransport {
            var count = 0
            var requests: [FootprintHTTPRequest] = []
            let store: FootprintStore
            init(store: FootprintStore) { self.store = store }
            func recorded() -> [FootprintHTTPRequest] { requests }
            func send(_ request: FootprintHTTPRequest) async throws -> FootprintHTTPResponse {
                requests.append(request)
                count += 1
                if count == 1 {
                    // Simulate downgrade queuing pending_state_update while 1st POST fails with 503!
                    _ = try? await store.reconcileAccuracyAuthorization(.reduced, enqueueBatchStateUpdate: true, nowMs: 1_795_980_010_000)
                    return FootprintHTTPResponse(statusCode: 503, body: Data())
                }
                return FootprintHTTPResponse(statusCode: 200, body: Data("{\"acked_point_ids\":[],\"rejected\":[]}".utf8))
            }
        }
        let transport8 = FailThenDrainTransport(store: store8)
        let client8 = FootprintSyncClient(transport: transport8)
        let settings8 = FootprintSettings(enabled: true, syncEnabled: true, syncEndpointURL: "https://srv-a.example.com", syncFormat: .batchJSON)
        do {
            _ = try await client8.flushOutbox(
                store: store8,
                settings: settings8,
                deviceID: "dev-8",
                writeToken: "tok-8",
                currentAccuracyAuth: .full,
                nowMs: 1_795_980_000_000,
                shouldContinue: { true },
                allowStateUpdateDrain: { true }
            )
            Issue.record("Expected httpStatus(503)")
        } catch let err as FootprintSyncError {
            #expect(err == .httpStatus(503))
        }
        let reqs8 = await transport8.recorded()
        #expect(reqs8.count == 2)
        let drained8 = try #require(gunzipRFC1952(reqs8[1].body))
        let drainedJSON8 = try JSONDecoder().decode(JSONValue.self, from: drained8)
        #expect(drainedJSON8["points"].array.isEmpty)
        #expect(drainedJSON8["state_update"]["accuracy_auth"].text == "reduced")
        #expect(try await store8.pendingStateUpdate() == nil)

        // Case 9: P1-5B Late callback measured at t=100 while sync was OFF -> user enables Server B at t=105 ->
        //         callback delivered at t=110 -> MUST persist locally ONLY and NEVER enqueue/send to Server B!
        let dir9 = makeTempDir("late-pre-sync-visit")
        defer { try? FileManager.default.removeItem(at: dir9) }
        var t9 = 1_795_990_100.0
        let defaults9 = StubMemoryDefaults()
        let transport9 = CapturingHTTPTransport()
        let power9 = StubPowerSaverDriver()
        power9.authorizationStatus = .authorizedAlways
        power9.accuracyAuthorization = .fullAccuracy
        let tracker9 = FootprintTracker(
            defaults: defaults9,
            directoryURL: dir9,
            secretStore: secrets5,
            syncClient: FootprintSyncClient(transport: transport9),
            powerSaverDriver: power9,
            liveStreamDriver: StubLiveStreamDriver(),
            now: { t9 }
        )
        tracker9.setForeground(true)
        await tracker9.applySettings(FootprintSettings(enabled: true, mode: .powerSaver, syncEnabled: false, syncEndpointURL: "", syncFormat: .owntracks))
        let visitMeasuredWhileSyncOff = t9 // t=100
        // At t=105, user enables sync to Server B
        t9 += 5.0
        await tracker9.applySettings(FootprintSettings(enabled: true, mode: .powerSaver, syncEnabled: true, syncEndpointURL: "https://server-b.example.com", syncFormat: .owntracks))
        // Simulate FULL PROCESS RESTART between enabling B (t=105) and receiving the delayed callback (t=110)!
        let tracker9Restarted = FootprintTracker(
            defaults: defaults9,
            directoryURL: dir9,
            secretStore: secrets5,
            syncClient: FootprintSyncClient(transport: transport9),
            powerSaverDriver: power9,
            liveStreamDriver: StubLiveStreamDriver(),
            now: { t9 }
        )
        tracker9Restarted.setForeground(true)
        // At t=110, delayed CLVisit callback measured at t=100 arrives after restart -> MUST remain local-only!
        t9 += 5.0
        await tracker9Restarted.ingestRawSamples([
            FootprintRawSample(
                latitude: 52.9505,
                longitude: -1.1505,
                accuracyMeters: 15,
                measuredAt: visitMeasuredWhileSyncOff,
                precise: true,
                source: "visit",
                transitionEvent: FootprintTransitionEvent.visitArrival.rawValue,
                forceKeep: true
            )
        ])
        _ = await tracker9Restarted.syncNow()
        let store9 = try await tracker9Restarted.openStoreForUI()
        #expect(try await store9.totalPointCount() == 1) // Saved locally
        #expect(try await store9.pendingOutboxCount() == 0) // Never enqueued for B even across restart!
        #expect(await transport9.recorded().isEmpty) // Never sent to B!
        // Meanwhile a legitimate point measured AFTER B was enabled (t=106) IS uploaded to B!
        await tracker9Restarted.ingestRawSamples([
            FootprintRawSample(
                latitude: 52.9600,
                longitude: -1.1600,
                accuracyMeters: 12,
                measuredAt: visitMeasuredWhileSyncOff + 6.0,
                precise: true,
                source: "visit",
                transitionEvent: FootprintTransitionEvent.visitDeparture.rawValue,
                forceKeep: true
            )
        ])
        _ = await tracker9Restarted.syncNow()
        let reqs9 = await transport9.recorded()
        #expect(reqs9.count == 1)
        let body9 = try JSONDecoder().decode(JSONValue.self, from: reqs9[0].body)
        #expect(abs((body9["lat"].number ?? 0) - 52.96) < 0.0001)

        // Case 9c: Legacy config upgrade (persisted JSON with syncEnabled=true and NO syncEligibleSince key):
        //          - On cold load, tracker establishes and persists syncEligibleSince = upgrade time,
        //          - Pre-existing bound outbox items still upload, while late pre-upgrade callbacks remain local-only!
        let dir9c = makeTempDir("legacy-sync-upgrade")
        defer { try? FileManager.default.removeItem(at: dir9c) }
        var t9c = 1_795_995_000.0
        let defaults9c = StubMemoryDefaults()
        let legacyJSON = Data("""
        {"enabled":true,"mode":"power_saver","syncEnabled":true,"syncEndpointURL":"https://server-b.example.com","syncFormat":"owntracks","retentionDays":365,"recoverableBackgroundSession":false,"deviceName":""}
        """.utf8)
        defaults9c.set(legacyJSON, forKey: FootprintTracker.settingsDefaultsKey)
        let preStore9c = try await FootprintStore.open(directoryURL: dir9c)
        let preExistingOutboxPt = FootprintPoint(pointID: "legacy-q", segmentID: "sq", measuredAtMs: Int64((t9c - 120) * 1000), latitude: 52.94, longitude: -1.14, accuracyMeters: 8, accuracyAuth: .full)
        _ = try await preStore9c.append([preExistingOutboxPt], enqueueForSync: true, destinationKey: "https://server-b.example.com", nowMs: Int64((t9c - 120) * 1000))
        let transport9c = CapturingHTTPTransport()
        let tracker9c = FootprintTracker(
            defaults: defaults9c,
            directoryURL: dir9c,
            secretStore: secrets5,
            syncClient: FootprintSyncClient(transport: transport9c),
            powerSaverDriver: power9,
            liveStreamDriver: StubLiveStreamDriver(),
            now: { t9c }
        )
        #expect(tracker9c.settings.syncEligibleSince == t9c)
        // Late callback measured BEFORE upgrade (t9c - 30) -> saved locally, NEVER enqueued/sent!
        t9c += 5
        await tracker9c.ingestRawSamples([
            FootprintRawSample(latitude: 52.9777, longitude: -1.1777, accuracyMeters: 10, measuredAt: t9c - 35, precise: true, source: "visit", transitionEvent: FootprintTransitionEvent.visitArrival.rawValue, forceKeep: true)
        ])
        _ = await tracker9c.syncNow()
        let reqs9c = await transport9c.recorded()
        #expect(reqs9c.count == 1) // Only the pre-existing outbox point (lat=52.94), NEVER 52.9777!
        let body9c = try JSONDecoder().decode(JSONValue.self, from: reqs9c[0].body)
        #expect(abs((body9c["lat"].number ?? 0) - 52.94) < 0.0001)
        #expect(try await preStore9c.totalPointCount() == 2)

        // Case 10: P1 §3.3/§3.4 36-minute continuous stay:
        //          - BEFORE clearHistory: chat tray reports dwelling=true, dwell_sec >= 2160 even with empty 30-min SQL window;
        //          - AFTER clearHistory(beforeMs: nil): engine dwell evidence is wiped immediately, next chat at t=2165 reports dwelling=false!
        let dir10 = makeTempDir("clear-wipes-dwell-evidence")
        defer { try? FileManager.default.removeItem(at: dir10) }
        var t10 = 1_796_000_000.0
        let start10 = t10
        let defaults10 = StubMemoryDefaults()
        let power10 = StubPowerSaverDriver()
        power10.authorizationStatus = .authorizedAlways
        power10.accuracyAuthorization = .fullAccuracy
        let tracker10 = FootprintTracker(
            defaults: defaults10,
            directoryURL: dir10,
            secretStore: secrets5,
            powerSaverDriver: power10,
            liveStreamDriver: StubLiveStreamDriver(),
            now: { t10 }
        )
        tracker10.setForeground(true)
        await tracker10.applySettings(FootprintSettings(enabled: true, mode: .continuous))
        for step in 0...72 { // 0..2160s (36 min)
            t10 = start10 + Double(step * 30)
            await tracker10.ingestRawSamples([
                FootprintRawSample(latitude: 52.9500, longitude: -1.1500, accuracyMeters: 8, measuredAt: t10, precise: true, speedMps: 0.0)
            ], isStationary: true)
        }
        #expect(tracker10.liveDwellEvidence?.confirmedDwelled5m == true)

        // Natural 36-min stay before clear -> dwelling=true
        var chatSettings10 = LocationSharingSettings()
        chatSettings10.enabled = true
        chatSettings10.agentIDs = ["alice"]
        let chatSnap10 = LocationSnapshot(latitude: 52.9500, longitude: -1.1500, accuracyMeters: 8, measuredAt: start10 + 2165, precise: true, speedMps: 0.0)
        let beforeClearTray = try LocationRequestContext(
            snapshot: chatSnap10,
            availability: .available,
            settings: chatSettings10,
            device: "iPhone",
            recentFootprintPoints: [],
            liveDwellEvidence: tracker10.liveDwellEvidence
        ).forAgent("alice").tray(at: start10 + 2166)
        let beforeClearJSON = try JSONDecoder().decode(JSONValue.self, from: Data(beforeClearTray.split(separator: "\n").first(where: { $0.hasPrefix("{") })!.utf8))
        #expect(beforeClearJSON["dwelling"].bool == true)
        #expect((beforeClearJSON["dwell_sec"].number ?? 0) >= 2160)

        // Full clear -> liveDwellEvidence MUST immediately become nil and chat at t=2165 MUST NOT report old dwell!
        t10 = start10 + 2162
        _ = try await tracker10.clearHistory(beforeMs: nil)
        #expect(tracker10.liveDwellEvidence == nil)
        let afterClearTray = try LocationRequestContext(
            snapshot: chatSnap10,
            availability: .available,
            settings: chatSettings10,
            device: "iPhone",
            recentFootprintPoints: [],
            liveDwellEvidence: tracker10.liveDwellEvidence
        ).forAgent("alice").tray(at: start10 + 2166)
        let afterClearJSON = try JSONDecoder().decode(JSONValue.self, from: Data(afterClearTray.split(separator: "\n").first(where: { $0.hasPrefix("{") })!.utf8))
        #expect(afterClearJSON["dwelling"].bool == false)
        #expect(afterClearJSON["dwell_sec"] == .null)

        // Case 10b (1): Late batch of 5-minute stationary pre-clear samples arrives AFTER clearHistory ->
        //               MUST be filtered by deleted_before_ms BEFORE entering engine so liveDwellEvidence stays nil!
        var lateBatch: [FootprintRawSample] = []
        for step in 0...11 {
            lateBatch.append(FootprintRawSample(
                latitude: 52.9500,
                longitude: -1.1500,
                accuracyMeters: 8,
                measuredAt: start10 + 100.0 + Double(step * 30),
                precise: true,
                speedMps: 0.0
            ))
        }
        t10 = start10 + 2170
        await tracker10.ingestRawSamples(lateBatch, isStationary: true)
        #expect(tracker10.liveDwellEvidence == nil)

        // Case 10b (2): Group chat prepares location once for [alice, bob]; clearHistory happens between speakers ->
        //               speaker 1 gets dwell semantics, speaker 2 has footprint semantics stripped at outbound time!
        var tGroup = Date().timeIntervalSince1970 - 400.0
        let groupStart = tGroup
        let chatDefaultsG = StubMemoryDefaults()
        var chatMgrsG: [StubChatManager] = []
        let chatServiceG = DeviceLocationService(
            defaults: chatDefaultsG,
            makeManager: {
                let m = StubChatManager()
                chatMgrsG.append(m)
                return m
            },
            now: { tGroup }
        )
        let dirG = makeTempDir("group-clear-mid-turn")
        defer { try? FileManager.default.removeItem(at: dirG) }
        let powerG = StubPowerSaverDriver()
        powerG.authorizationStatus = .authorizedAlways
        powerG.accuracyAuthorization = .fullAccuracy
        let trackerG = FootprintTracker(
            defaults: StubMemoryDefaults(),
            directoryURL: dirG,
            secretStore: secrets5,
            powerSaverDriver: powerG,
            liveStreamDriver: StubLiveStreamDriver(),
            now: { tGroup }
        )
        let coordG = LocationAcquisitionCoordinator(chatService: chatServiceG, footprintTracker: trackerG)
        let modelG = ChatViewModel(coordinator: coordG)
        let aliceG = VCPAgent(id: "alice", name: "Alice")
        let bobG = VCPAgent(id: "bob", name: "Bob")
        let grp = VCPGroup(name: "g", memberIds: ["alice", "bob"])
        modelG.agents = [aliceG, bobG]
        modelG.groups = [grp]
        modelG.locationSettings.enabled = true
        modelG.locationSettings.agentIDs = ["alice", "bob"]

        coordG.setForeground(true)
        await trackerG.applySettings(FootprintSettings(enabled: true, mode: .continuous))
        for step in 0...11 {
            tGroup = groupStart + Double(step * 30)
            await trackerG.ingestRawSamples([
                FootprintRawSample(latitude: 52.9500, longitude: -1.1500, accuracyMeters: 6, measuredAt: tGroup, precise: true, speedMps: 0.0)
            ], isStationary: true)
        }
        tGroup = Date().timeIntervalSince1970 - 2.0
        chatServiceG.setContinuous(true)
        let activeChatMgrG = try #require(chatMgrsG.last)
        chatServiceG.locationManager(
            activeChatMgrG,
            didUpdateLocations: [
                CLLocation(coordinate: .init(latitude: 52.9500, longitude: -1.1500), altitude: 0, horizontalAccuracy: 6, verticalAccuracy: 0, timestamp: Date(timeIntervalSince1970: tGroup))
            ]
        )
        let groupPrepared = try #require(await modelG.prepareLocation(for: [aliceG, bobG], preference: .automatic, group: grp))
        let aliceOut = try #require(try modelG.outboundLocation(groupPrepared, for: "alice", preference: .automatic))
        #expect(aliceOut.contains("\"dwelling\":true"))

        // User clears footprint history between speaker 1 (alice) and speaker 2 (bob)!
        _ = try await trackerG.clearHistory(beforeMs: nil)
        let bobOut = try #require(try modelG.outboundLocation(groupPrepared, for: "bob", preference: .automatic))
        #expect(!bobOut.contains("\"dwelling\""))
        #expect(!bobOut.contains("\"dwell_sec\""))
        #expect(!bobOut.contains("\"motion_state\""))

        // Case 10c: Overlap between clearHistory and prepareLocation + overlapping DUAL clears (partial + full):
        //           - While clear #1 (full) is suspended, clear #2 (partial) starts and finishes FIRST ->
        //             isClearingHistory MUST stay TRUE while clear #1 is still running!
        //           - prepareLocation running MID-CLEAR must strip old dwell semantics!
        let dirOverlap = makeTempDir("clear-prepare-overlap")
        defer { try? FileManager.default.removeItem(at: dirOverlap) }
        var tOv = Date().timeIntervalSince1970 - 400.0
        let startOv = tOv
        let chatMgrsOvBox = NSMutableArray()
        let chatServiceOv = DeviceLocationService(
            defaults: StubMemoryDefaults(),
            makeManager: {
                let m = StubChatManager()
                chatMgrsOvBox.add(m)
                return m
            },
            now: { tOv }
        )
        let powerOv = StubPowerSaverDriver()
        powerOv.authorizationStatus = .authorizedAlways
        powerOv.accuracyAuthorization = .fullAccuracy
        let trackerOv = FootprintTracker(
            defaults: StubMemoryDefaults(),
            directoryURL: dirOverlap,
            secretStore: secrets5,
            powerSaverDriver: powerOv,
            liveStreamDriver: StubLiveStreamDriver(),
            now: { tOv }
        )
        let coordOv = LocationAcquisitionCoordinator(chatService: chatServiceOv, footprintTracker: trackerOv)
        let modelOv = ChatViewModel(coordinator: coordOv)
        modelOv.agents = [aliceG]
        modelOv.locationSettings.enabled = true
        modelOv.locationSettings.agentIDs = ["alice"]
        coordOv.setForeground(true)
        await trackerOv.applySettings(FootprintSettings(enabled: true, mode: .continuous))
        for step in 0...11 {
            tOv = startOv + Double(step * 30)
            await trackerOv.ingestRawSamples([
                FootprintRawSample(latitude: 52.9500, longitude: -1.1500, accuracyMeters: 6, measuredAt: tOv, precise: true, speedMps: 0.0)
            ], isStationary: true)
        }
        tOv = Date().timeIntervalSince1970 - 2.0
        chatServiceOv.setContinuous(true)
        let mgrOv = try #require(chatMgrsOvBox.lastObject as? StubChatManager)
        chatServiceOv.locationManager(
            mgrOv,
            didUpdateLocations: [
                CLLocation(coordinate: .init(latitude: 52.9500, longitude: -1.1500), altitude: 0, horizontalAccuracy: 6, verticalAccuracy: 0, timestamp: Date(timeIntervalSince1970: tOv))
            ]
        )
        var midClearPrepared: PreparedLocation?
        var afterPartialPrepared: PreparedLocation?
        var stillClearingAfterFirstFinished = false
        trackerOv.onClearInProgressHook = {
            // Clear #1 (full) is now in flight; clear #2 (partial) enters AND finishes first without a hook!
            trackerOv.onClearInProgressHook = nil
            midClearPrepared = await modelOv.prepareLocation(for: [aliceG], preference: .automatic, group: nil)
            let cutoff30Days = Int64((Date().addingTimeInterval(-30 * 86_400).timeIntervalSince1970 * 1000.0).rounded())
            _ = try? await trackerOv.clearHistory(beforeMs: cutoff30Days)
            stillClearingAfterFirstFinished = trackerOv.isClearingHistory
            afterPartialPrepared = await modelOv.prepareLocation(for: [aliceG], preference: .automatic, group: nil)
        }
        _ = try await trackerOv.clearHistory(beforeMs: nil)
        #expect(stillClearingAfterFirstFinished == true)
        #expect(trackerOv.isClearingHistory == false)

        let overlapPrepared = try #require(midClearPrepared)
        let overlapOut = try #require(try modelOv.outboundLocation(overlapPrepared, for: "alice", preference: .automatic))
        #expect(!overlapOut.contains("\"dwelling\""))
        #expect(!overlapOut.contains("\"dwell_sec\""))

        let afterFirstPrepared = try #require(afterPartialPrepared)
        let afterFirstOut = try #require(try modelOv.outboundLocation(afterFirstPrepared, for: "alice", preference: .automatic))
        #expect(!afterFirstOut.contains("\"dwelling\""))
        #expect(!afterFirstOut.contains("\"dwell_sec\""))

        // Case 10d: NaN/Infinite/overflow timestamps MUST be safely dropped without crashing,
        //           and watermark read failure (`store.meta()` fails) MUST abort batch without reconstructing dwell!
        tOv += 120.0 // Advance past the T+60s watermark established by clearHistory in Case 10c
        await trackerOv.ingestRawSamples([
            FootprintRawSample(latitude: 52.9500, longitude: -1.1500, accuracyMeters: 6, measuredAt: Double.nan, precise: true),
            FootprintRawSample(latitude: 52.9500, longitude: -1.1500, accuracyMeters: 6, measuredAt: Double.infinity, precise: true),
            FootprintRawSample(latitude: 52.9500, longitude: -1.1500, accuracyMeters: 6, measuredAt: 1e20, precise: true),
            FootprintRawSample(latitude: 52.9500, longitude: -1.1500, accuracyMeters: 6, measuredAt: tOv, precise: true)
        ])
        let storeOv = try await trackerOv.openStoreForUI()
        #expect(try await storeOv.totalPointCount() == 1) // Bad timestamps safely skipped, valid point saved!

        let dirMetaFail = makeTempDir("meta-read-fail")
        defer { try? FileManager.default.removeItem(at: dirMetaFail) }
        let trackerFail = FootprintTracker(
            defaults: StubMemoryDefaults(),
            directoryURL: dirMetaFail,
            secretStore: secrets5,
            powerSaverDriver: powerOv,
            liveStreamDriver: StubLiveStreamDriver(),
            now: { tOv }
        )
        trackerFail.setForeground(true)
        await trackerFail.applySettings(FootprintSettings(enabled: true, mode: .continuous))
        let dbPathFail = dirMetaFail.appendingPathComponent(FootprintStore.databaseFileName).path
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
        proc.arguments = [dbPathFail, "DROP TABLE footprint_meta;"]
        try proc.run()
        proc.waitUntilExit()
        #expect(proc.terminationStatus == 0)
        await trackerFail.ingestRawSamples([
            FootprintRawSample(latitude: 52.9500, longitude: -1.1500, accuracyMeters: 6, measuredAt: tOv - 350, precise: true),
            FootprintRawSample(latitude: 52.9500, longitude: -1.1500, accuracyMeters: 6, measuredAt: tOv, precise: true)
        ])
        #expect(trackerFail.liveDwellEvidence == nil)
        #expect(try await trackerFail.openStoreForUI().totalPointCount() == 0)
    }

    @Test("Pre-first-unlock capability probe defers restore without creating new identity, then resumes on protectedDataDidBecomeAvailable")
    func preFirstUnlockDeferredRestore() async throws {
        let dir = makeTempDir("first-unlock")
        defer { try? FileManager.default.removeItem(at: dir) }
        let defaults = StubMemoryDefaults()
        let protector = ToggleableProtector()
        protector.locked = true
        let powerDriver = StubPowerSaverDriver()
        powerDriver.authorizationStatus = .authorizedAlways
        let liveDriver = StubLiveStreamDriver()
        let secretStore = StubSecretStore()
        await secretStore.setLocked(true)
        await secretStore.setValues([PersistentFootprintKeychain.deviceIDAccount: "persisted-id-123"])

        let savedSettings = FootprintSettings(enabled: true, mode: .continuous, recoverableBackgroundSession: true)
        defaults.set(try JSONEncoder().encode(savedSettings), forKey: FootprintTracker.settingsDefaultsKey)

        let tracker = FootprintTracker(
            defaults: defaults,
            directoryURL: dir,
            protector: protector,
            secretStore: secretStore,
            powerSaverDriver: powerDriver,
            liveStreamDriver: liveDriver
        )

        let initialOutcome = await tracker.attemptBackgroundRestore(launchHadLocationKey: true)
        #expect(initialOutcome == .deferredUntilFirstUnlock)
        #expect(tracker.waitingForFirstUnlock == true)
        #expect(!tracker.running && !liveDriver.active)
        #expect(await secretStore.getSaveCount() == 0)

        // Simulate first unlock: storage and Keychain become accessible
        protector.locked = false
        await secretStore.setLocked(false)

        let resumedOutcome = await tracker.handleProtectedDataBecameAvailable()
        #expect(resumedOutcome == .restored(.continuous))
        #expect(tracker.waitingForFirstUnlock == false)
        #expect(tracker.running && liveDriver.active && liveDriver.hasBackgroundSession)
        #expect(tracker.deviceID == "persisted-id-123")
        #expect(await secretStore.getSaveCount() == 0)
    }

    @Test("Dual-track isolation: Track B background release stops chat sampler ONLY and NEVER stops Track A; Track B never backfills coordinates from Track A")
    func dualTrackIsolation() async throws {
        let dir = makeTempDir("dual-track")
        defer { try? FileManager.default.removeItem(at: dir) }
        var now = Date().timeIntervalSince1970 - 120.0
        let chatDefaults = StubMemoryDefaults()
        let trackDefaults = StubMemoryDefaults()
        var chatManagers: [StubChatManager] = []

        let chatService = DeviceLocationService(
            defaults: chatDefaults,
            makeManager: {
                let m = StubChatManager()
                chatManagers.append(m)
                return m
            },
            now: { now }
        )
        let powerDriver = StubPowerSaverDriver()
        powerDriver.authorizationStatus = .authorizedAlways
        let liveDriver = StubLiveStreamDriver()
        let secretStore = StubSecretStore()
        await secretStore.setValues([PersistentFootprintKeychain.deviceIDAccount: "dev-dual"])

        let tracker = FootprintTracker(
            defaults: trackDefaults,
            directoryURL: dir,
            secretStore: secretStore,
            powerSaverDriver: powerDriver,
            liveStreamDriver: liveDriver,
            now: { now }
        )
        let coordinator = LocationAcquisitionCoordinator(chatService: chatService, footprintTracker: tracker)
        let model = ChatViewModel(coordinator: coordinator)
        let alice = VCPAgent(id: "alice", name: "Alice")
        model.agents = [alice]
        model.locationSettings.enabled = true
        model.locationSettings.agentIDs = ["alice"]

        // Foreground: start both Track B (chat continuous) and Track A (continuous footprint)
        coordinator.setForeground(true)
        chatService.setContinuous(true)
        #expect(chatService.locating == true)

        await tracker.applySettings(FootprintSettings(enabled: true, mode: .continuous))
        #expect(tracker.running == true)
        #expect(liveDriver.active == true)

        // Track A records a precise point in LocationTracks SQLite
        await tracker.ingestRawSamples([
            FootprintRawSample(latitude: 52.9500, longitude: -1.1500, accuracyMeters: 6, measuredAt: now - 30, precise: true, speedMps: 1.3)
        ], isStationary: false)

        // Move to background: Track B MUST stop immediately, Track A MUST keep running!
        coordinator.setForeground(false)
        #expect(chatService.foreground == false)
        #expect(chatService.locating == false)
        #expect(chatManagers.allSatisfy { !$0.backgroundAllowed })
        #expect(tracker.running == true)
        #expect(liveDriver.active == true && liveDriver.hasBackgroundSession == true)

        // Track B has NO chat snapshot -> recentPrecisePointsForChatSemantics MUST return [] and never backfill from Track A!
        chatService.clearChatCache()
        let leakedWindow = await coordinator.recentPrecisePointsForChatSemantics(
            chatSnapshot: chatService.snapshot,
            semanticRecipients: ["alice"],
            at: now
        )
        #expect(leakedWindow.isEmpty)

        // Even preparing location when Track B has no snapshot produces status=unavailable and NEVER Track A coordinates
        let prepared = await model.prepareLocation(for: [alice], preference: .automatic, group: nil)
        let outbound = try model.outboundLocation(prepared, for: "alice", preference: .automatic)
        #expect(outbound?.contains("52.95") == false)

        // P1-1 Production path: Foreground one-off .include to non-allowlisted guest sends current coordinate ONLY,
        // NEVER Track A sliding-window semantics (motion_state / recent_movement / dwell_sec)!
        coordinator.setForeground(true)
        chatService.setContinuous(true)
        let chatMgr = try #require(chatManagers.last)
        now += 5
        chatService.locationManager(
            chatMgr,
            didUpdateLocations: [
                CLLocation(coordinate: .init(latitude: 52.951, longitude: -1.150), altitude: 0, horizontalAccuracy: 6, verticalAccuracy: 0, timestamp: Date(timeIntervalSince1970: now))
            ]
        )
        let guest = VCPAgent(id: "guest", name: "Guest")
        let guestPrepared = try #require(await model.prepareLocation(for: [guest], preference: .include, group: nil))
        let guestTray = try #require(try model.outboundLocation(guestPrepared, for: "guest", preference: .include))
        #expect(guestTray.contains("\"latitude\":52.951"))
        #expect(!guestTray.contains("\"motion_state\""))
        #expect(!guestTray.contains("\"recent_movement\""))
        #expect(!guestTray.contains("\"dwell_sec\""))

        // P1-1 Outbound re-check: allowlisted agent prepared in foreground, then app backgrounds before HTTP send ->
        // historical footprint semantics MUST be stripped at outbound time!
        let alicePrepared = try #require(await model.prepareLocation(for: [alice], preference: .automatic, group: nil))
        let aliceForegroundTray = try #require(try model.outboundLocation(alicePrepared, for: "alice", preference: .automatic))
        #expect(aliceForegroundTray.contains("\"motion_state\""))
        coordinator.setForeground(false)
        let aliceBackgroundTray = try #require(try model.outboundLocation(alicePrepared, for: "alice", preference: .automatic))
        #expect(!aliceBackgroundTray.contains("\"motion_state\""))
        #expect(!aliceBackgroundTray.contains("\"recent_movement\""))
        #expect(!aliceBackgroundTray.contains("\"dwell_sec\""))

        // Continuous mode stationary -> moving resume triggers new segment_id
        now += 40
        await tracker.ingestRawSamples([
            FootprintRawSample(latitude: 52.9502, longitude: -1.1500, accuracyMeters: 6, measuredAt: now - 5, precise: true, speedMps: 0.0)
        ], isStationary: true)
        let segBeforeResume = tracker.lastRecordedPoint?.segmentID
        now += 30
        await tracker.ingestRawSamples([
            FootprintRawSample(latitude: 52.9510, longitude: -1.1500, accuracyMeters: 6, measuredAt: now - 2, precise: true, speedMps: 1.6)
        ], isStationary: false)
        let segAfterResume = tracker.lastRecordedPoint?.segmentID
        #expect(segBeforeResume != nil && segAfterResume != nil && segBeforeResume != segAfterResume)
    }
}