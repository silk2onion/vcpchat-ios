import Foundation
import Testing
@testable import VChatCore

private final class RecordingProtector: FootprintStorageProtector, @unchecked Sendable {
    let lock = NSLock()
    var events: [String] = []
    var failProtectedOnPrepare = false
    private let real = SystemFootprintStorageProtector()

    func prepareDirectory(_ directoryURL: URL) throws {
        lock.withLock {
            events.append("prepareDirectory:\(directoryURL.lastPathComponent):exists=\(FileManager.default.fileExists(atPath: directoryURL.appendingPathComponent(FootprintStore.databaseFileName).path))")
        }
        if failProtectedOnPrepare {
            throw FootprintStoreError.protectedDataUnavailable
        }
        try real.prepareDirectory(directoryURL)
    }

    func protectDatabaseFile(_ databaseURL: URL) throws {
        lock.withLock {
            events.append("protectDatabaseFile:\(databaseURL.lastPathComponent):exists=\(FileManager.default.fileExists(atPath: databaseURL.path))")
        }
        try real.protectDatabaseFile(databaseURL)
    }
}

private actor MockSecretStore: FootprintSecretStore {
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

private actor MockHTTPTransport: FootprintHTTPTransport {
    var requests: [FootprintHTTPRequest] = []
    var nextHandler: (@Sendable (FootprintHTTPRequest) throws -> FootprintHTTPResponse)?

    func setHandler(_ handler: @escaping @Sendable (FootprintHTTPRequest) throws -> FootprintHTTPResponse) {
        nextHandler = handler
    }

    func recordedRequests() -> [FootprintHTTPRequest] { requests }

    func send(_ request: FootprintHTTPRequest) async throws -> FootprintHTTPResponse {
        requests.append(request)
        if let nextHandler {
            return try nextHandler(request)
        }
        return FootprintHTTPResponse(statusCode: 200, body: Data())
    }
}

@Suite("Footprint Core v4.0 (Storage, Engine, Semantics, GeoJSON, Sync)")
struct FootprintCoreTests {
    private func makeTempDir(_ name: String) -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("vchat-fp-\(name)-\(UUID().uuidString)", isDirectory: true)
    }

    private func extractTrayJSON(_ tray: String) throws -> JSONValue {
        let lines = tray.split(separator: "\n", omittingEmptySubsequences: true)
        guard let jsonLine = lines.first(where: { $0.hasPrefix("{") && $0.hasSuffix("}") }) else {
            throw ClientError.invalidResponse
        }
        return try JSONDecoder().decode(JSONValue.self, from: Data(jsonLine.utf8))
    }

    @Test("Directory is created, protected, and excluded from backup BEFORE SQLite opens")
    func directoryPreparedBeforeDatabaseOpens() async throws {
        let root = makeTempDir("protect-order")
        defer { try? FileManager.default.removeItem(at: root) }
        let dir = root.appendingPathComponent(FootprintStore.directoryName, isDirectory: true)

        let protector = RecordingProtector()
        let store = try await FootprintStore.open(directoryURL: dir, protector: protector)

        #expect(protector.events.count == 2)
        #expect(protector.events[0] == "prepareDirectory:LocationTracks:exists=false")
        #expect(protector.events[1] == "protectDatabaseFile:location-tracks.sqlite:exists=true")
        #expect(try await store.journalMode().lowercased() == "wal")

        let resourceValues = try dir.resourceValues(forKeys: [.isExcludedFromBackupKey])
        #expect(resourceValues.isExcludedFromBackup == true)
    }

    @Test("Ingestion enforces >120s split, full<->reduced split, drift suppression, corner retention, and never splits on network delay alone")
    func ingestionFilteringSplittingAndSimplification() {
        var engine = FootprintIngestionEngine()
        let base = 1_795_100_000.0
        var counter = 0
        let nextID: () -> String = { counter += 1; return "id-\(counter)" }

        // Batch 1: valid walk + noise drift (<12m) + invalid tail (>100m accuracy in precise mode)
        let batch1 = [
            FootprintRawSample(latitude: 52.9500, longitude: -1.1500, accuracyMeters: 8, measuredAt: base, precise: true, speedMps: 1.4),
            // Tiny drift 3m -> must be suppressed
            FootprintRawSample(latitude: 52.95002, longitude: -1.15001, accuracyMeters: 8, measuredAt: base + 10, precise: true, speedMps: 0.1),
            // Move east ~70m (walk)
            FootprintRawSample(latitude: 52.9500, longitude: -1.14895, accuracyMeters: 8, measuredAt: base + 50, precise: true, speedMps: 1.4),
            // Sharp 90-degree north turn (~55m north) -> corner MUST be retained
            FootprintRawSample(latitude: 52.9505, longitude: -1.14895, accuracyMeters: 8, measuredAt: base + 90, precise: true, speedMps: 1.4),
            // Bad precise outlier -> must be filtered without hiding valid earlier points
            FootprintRawSample(latitude: 52.9600, longitude: -1.1400, accuracyMeters: 350, measuredAt: base + 95, precise: true)
        ]
        let out1 = engine.ingest(batch1, now: base + 100, makeID: nextID)
        #expect(out1.count == 3)
        let seg1 = out1[0].segmentID
        #expect(out1.allSatisfy { $0.segmentID == seg1 })

        // Offline/network delay alone (measuredAt is only +110s <= 120s, even though 'now' is 5 minutes later): MUST NOT split segment!
        let offlineSample = FootprintRawSample(latitude: 52.9510, longitude: -1.14895, accuracyMeters: 8, measuredAt: base + 200, precise: true, speedMps: 1.3)
        let out2 = engine.ingest([offlineSample], now: base + 500, makeID: nextID)
        #expect(out2.count == 1)
        #expect(out2[0].segmentID == seg1)

        // >120s gap (base + 200 -> base + 325 = 125s): MUST split into a new segment!
        let afterGap = FootprintRawSample(latitude: 52.9520, longitude: -1.14895, accuracyMeters: 8, measuredAt: base + 325, precise: true, speedMps: 1.5)
        let out3 = engine.ingest([afterGap], now: base + 330, makeID: nextID)
        #expect(out3.count == 1)
        #expect(out3[0].segmentID != seg1)
        let seg2 = out3[0].segmentID

        // Accuracy full -> reduced within 20s: MUST split segment and mark reduced!
        let reduced = FootprintRawSample(latitude: 52.9530, longitude: -1.1500, accuracyMeters: 3500, measuredAt: base + 345, precise: false)
        let out4 = engine.ingest([reduced], now: base + 350, makeID: nextID)
        #expect(out4.count == 1)
        #expect(out4[0].accuracyAuth == .reduced)
        #expect(out4[0].segmentID != seg2)

        // Reduced -> full within 20s: MUST split again!
        let backToFull = FootprintRawSample(latitude: 52.9535, longitude: -1.1490, accuracyMeters: 10, measuredAt: base + 365, precise: true)
        let out5 = engine.ingest([backToFull], now: base + 370, makeID: nextID)
        #expect(out5.count == 1)
        #expect(out5[0].accuracyAuth == .full)
        #expect(out5[0].segmentID != out4[0].segmentID)
    }

    @Test("Stationary periodic fixes every 30s never falsely split segment and trigger dwelled_5m; 15m 90-degree corner is preserved")
    func stationaryDwellAndSharpCornerRetention() {
        var engine = FootprintIngestionEngine()
        let base = 1_795_150_000.0
        var counter = 0
        let nextID: () -> String = { counter += 1; return "st-\(counter)" }

        // 1. Stationary fixes every 30s for 330s (>5 min) with <3m jitter:
        //    MUST stay in the SAME segment and emit dwelled_5m!
        var collected: [FootprintPoint] = []
        for step in 0...11 {
            let t = base + Double(step * 30)
            let sample = FootprintRawSample(
                latitude: 52.9500 + Double(step % 2) * 0.00001,
                longitude: -1.1500,
                accuracyMeters: 8,
                measuredAt: t,
                precise: true,
                speedMps: 0.0
            )
            collected.append(contentsOf: engine.ingest([sample], now: t + 1, makeID: nextID))
        }
        #expect(collected.count == 2)
        #expect(collected[0].segmentID == collected[1].segmentID)
        #expect(collected[1].transitionEvent == FootprintTransitionEvent.dwelled5m.rawValue)
        #expect(collected[1].motionState == .dwelling)

        // 2. Three 15m steps forming a sharp 90-degree corner (East -> East -> North):
        //    Corner vertex (p2) MUST be flushed and preserved, never clipped!
        var cornerEngine = FootprintIngestionEngine()
        let t0 = base + 1000
        let dLat15m = 15.0 / 111_132.0
        let dLon15m = 15.0 / (111_320.0 * cos(52.95 * Double.pi / 180.0))
        let route = [
            FootprintRawSample(latitude: 52.9500, longitude: -1.1500, accuracyMeters: 5, measuredAt: t0, precise: true, speedMps: 1.5),
            FootprintRawSample(latitude: 52.9500, longitude: -1.1500 + dLon15m, accuracyMeters: 5, measuredAt: t0 + 10, precise: true, speedMps: 1.5),
            FootprintRawSample(latitude: 52.9500, longitude: -1.1500 + 2 * dLon15m, accuracyMeters: 5, measuredAt: t0 + 20, precise: true, speedMps: 1.5),
            FootprintRawSample(latitude: 52.9500 + dLat15m, longitude: -1.1500 + 2 * dLon15m, accuracyMeters: 5, measuredAt: t0 + 30, precise: true, speedMps: 1.5)
        ]
        let committed = cornerEngine.ingest(route, now: t0 + 35, makeID: nextID)
        let hasCornerVertex = committed.contains { pt in
            FootprintPoint.haversineMeters(
                lat1: pt.latitude, lon1: pt.longitude,
                lat2: 52.9500, lon2: -1.1500 + 2 * dLon15m
            ) < 0.5
        }
        #expect(hasCornerVertex)

        // 3. P2-1: Walk 200m in 20m steps every 30s (each step < 35m), then stop for 330s:
        //    dwell anchor MUST advance along the walk and trigger dwelled_5m at the stop!
        var walkStopEngine = FootprintIngestionEngine()
        let walkStart = base + 5000
        let dLat20m = 20.0 / 111_132.0
        var lastStopLat = 52.9500
        for step in 0...10 {
            let t = walkStart + Double(step * 30)
            lastStopLat = 52.9500 + Double(step) * dLat20m
            _ = walkStopEngine.ingest([
                FootprintRawSample(latitude: lastStopLat, longitude: -1.1500, accuracyMeters: 6, measuredAt: t, precise: true, speedMps: 0.7)
            ], now: t + 1, makeID: nextID)
        }
        var stopEvents: [FootprintPoint] = []
        let stopStart = walkStart + 10 * 30
        for step in 1...12 {
            let t = stopStart + Double(step * 30)
            stopEvents.append(contentsOf: walkStopEngine.ingest([
                FootprintRawSample(latitude: lastStopLat + Double(step % 2) * 0.00001, longitude: -1.1500, accuracyMeters: 6, measuredAt: t, precise: true, speedMps: 0.0)
            ], now: t + 1, makeID: nextID))
        }
        #expect(stopEvents.contains { $0.transitionEvent == FootprintTransitionEvent.dwelled5m.rawValue })

        // 4. §3.3 & §3.4 End-to-end: continue stationary fixes up to t=510s (every 30s):
        //    - `dwelled_5m` transition MUST be emitted EXACTLY ONCE (0 stationary heartbeats after t=300!)
        //    - Tray at t=300.0, t=300.5 (same-second replacement), t=330.0, AND t=450.0 ALL report dwelling=true!
        var extended = collected
        for step in 12...17 {
            let t = base + Double(step * 30)
            let sample = FootprintRawSample(
                latitude: 52.9500 + Double(step % 2) * 0.00001,
                longitude: -1.1500,
                accuracyMeters: 8,
                measuredAt: t,
                precise: true,
                speedMps: 0.0
            )
            extended.append(contentsOf: engine.ingest([sample], now: t + 1, makeID: nextID))
        }
        // Strictly ZERO extra persisted points or duplicate dwelled_5m transitions during prolonged stay!
        #expect(extended.count == 2)
        #expect(extended.filter { $0.transitionEvent == FootprintTransitionEvent.dwelled5m.rawValue }.count == 1)

        var chatSettings = LocationSharingSettings()
        chatSettings.enabled = true
        chatSettings.agentIDs = ["alice"]
        let segIDForStay = extended[0].segmentID
        for (offset, expectedMinDwell) in [(300.0, 300.0), (300.5, 300.0), (330.0, 330.0), (450.0, 450.0)] {
            let snap = LocationSnapshot(latitude: 52.9500, longitude: -1.1500, accuracyMeters: 8, measuredAt: base + offset, precise: true, speedMps: 0.0)
            let windowSlice = extended.filter { $0.measuredAtSeconds <= base + offset }
            let lastMeasuredAtOffset = base + floor(offset / 30.0) * 30.0
            let ev = FootprintLiveDwellEvidence(
                segmentID: segIDForStay,
                accuracyAuth: .full,
                anchorLatitude: 52.9500,
                anchorLongitude: -1.1500,
                anchorAccuracyMeters: 8,
                anchorStartedAt: base,
                lastValidMeasuredAt: lastMeasuredAtOffset,
                confirmedDwelled5m: true
            )
            let ctx = LocationRequestContext(
                snapshot: snap,
                availability: .available,
                settings: chatSettings,
                device: "iPhone",
                recentFootprintPoints: windowSlice,
                liveDwellEvidence: ev
            )
            let trayStr = try! ctx.forAgent("alice").tray(at: base + offset + 1)
            let lines = trayStr.split(separator: "\n", omittingEmptySubsequences: true)
            let json = try! JSONDecoder().decode(JSONValue.self, from: Data(lines.first(where: { $0.hasPrefix("{") })!.utf8))
            #expect(json["dwelling"].bool == true)
            #expect((json["dwell_sec"].number ?? 0) >= expectedMinDwell)
            #expect(json["motion_state"].text == "dwelling")
        }

        // 4b. 36-minute continuous stay (2160s > 30-min SQL window so recentFootprintPoints is EMPTY!):
        //     liveDwellEvidence MUST still report dwelling=true and dwell_sec >= 2160!
        for step in 18...72 { // up to 2160s (36 min)
            let t = base + Double(step * 30)
            _ = engine.ingest([
                FootprintRawSample(latitude: 52.9500, longitude: -1.1500, accuracyMeters: 8, measuredAt: t, precise: true, speedMps: 0.0)
            ], now: t + 1, makeID: nextID)
        }
        let chatAt36m = LocationSnapshot(latitude: 52.9500, longitude: -1.1500, accuracyMeters: 8, measuredAt: base + 2165, precise: true, speedMps: 0.0)
        let ctx36m = LocationRequestContext(
            snapshot: chatAt36m,
            availability: .available,
            settings: chatSettings,
            device: "iPhone",
            recentFootprintPoints: [], // aged beyond 30-min SQL query window
            liveDwellEvidence: engine.liveDwellEvidence
        )
        let tray36m = try! ctx36m.forAgent("alice").tray(at: base + 2166)
        let json36m = try! JSONDecoder().decode(JSONValue.self, from: Data(tray36m.split(separator: "\n").first(where: { $0.hasPrefix("{") })!.utf8))
        #expect(json36m["dwelling"].bool == true)
        #expect((json36m["dwell_sec"].number ?? 0) >= 2160)

        // 4c. Real >120s measurement gap OR reduced new segment MUST NOT fabricate dwell!
        let chatAfterGap = LocationSnapshot(latitude: 52.9500, longitude: -1.1500, accuracyMeters: 8, measuredAt: base + 2160 + 180, precise: true, speedMps: 0.0)
        let ctxGap = LocationRequestContext(
            snapshot: chatAfterGap,
            availability: .available,
            settings: chatSettings,
            device: "iPhone",
            recentFootprintPoints: [],
            liveDwellEvidence: engine.liveDwellEvidence
        )
        let trayGap = try! ctxGap.forAgent("alice").tray(at: base + 2160 + 181)
        let jsonGap = try! JSONDecoder().decode(JSONValue.self, from: Data(trayGap.split(separator: "\n").first(where: { $0.hasPrefix("{") })!.utf8))
        #expect(jsonGap["dwelling"].bool == false)

        // Reduced sample starts a reduced segment -> engine.liveDwellEvidence MUST become nil so it never bridges old full segment!
        _ = engine.ingest([
            FootprintRawSample(latitude: 52.9500, longitude: -1.1500, accuracyMeters: 2500, measuredAt: base + 2190, precise: false)
        ], now: base + 2191, makeID: nextID)
        #expect(engine.liveDwellEvidence == nil)

        // 5. 70s cadence stationary test: t=350 confirms dwell, t=420 thinned, chat at t=475 (only 55s since t=420!)
        //    MUST report dwelling=true and dwell_sec >= 475!
        var slowEngine = FootprintIngestionEngine()
        var slowPoints: [FootprintPoint] = []
        for step in 0...6 { // 0, 70, 140, 210, 280, 350, 420
            let t = base + 20_000 + Double(step * 70)
            slowPoints.append(contentsOf: slowEngine.ingest([
                FootprintRawSample(latitude: 52.9500, longitude: -1.1500, accuracyMeters: 8, measuredAt: t, precise: true, speedMps: 0.0)
            ], now: t + 1, makeID: nextID))
        }
        #expect(slowPoints.count == 2) // t=0 and t=350 only
        let chatAt475 = LocationSnapshot(latitude: 52.9500, longitude: -1.1500, accuracyMeters: 8, measuredAt: base + 20_475, precise: true, speedMps: 0.0)
        let slowCtx = LocationRequestContext(
            snapshot: chatAt475,
            availability: .available,
            settings: chatSettings,
            device: "iPhone",
            recentFootprintPoints: slowPoints,
            liveDwellEvidence: slowEngine.liveDwellEvidence
        )
        let slowTray = try! slowCtx.forAgent("alice").tray(at: base + 20_476)
        let slowLines = slowTray.split(separator: "\n", omittingEmptySubsequences: true)
        let slowJSON = try! JSONDecoder().decode(JSONValue.self, from: Data(slowLines.first(where: { $0.hasPrefix("{") })!.utf8))
        #expect(slowJSON["dwelling"].bool == true)
        #expect((slowJSON["dwell_sec"].number ?? 0) >= 475)
    }

    @Test("Full clear increments clear_epoch + T+60s watermark and blocks stale backfill resurrection")
    func clearHistoryWatermarkBlocksResurrection() async throws {
        let dir = makeTempDir("clear-watermark")
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = try await FootprintStore.open(directoryURL: dir)

        let t0: Int64 = 1_795_200_000_000
        let p1 = FootprintPoint(pointID: "p1", segmentID: "s1", measuredAtMs: t0 - 5000, latitude: 52.95, longitude: -1.15, accuracyMeters: 10, accuracyAuth: .full)
        let inserted = try await store.append([p1], enqueueForSync: true, destinationKey: "https://server-a.example.com", nowMs: t0)
        #expect(inserted == 1)
        #expect(try await store.pendingOutboxCount() == 1)

        try await store.setPendingStateUpdate(FootprintPendingStateUpdate(clearEpoch: 0, accuracyAuth: .reduced, status: "reduced_accuracy", measuredAtMs: t0 - 1000))
        let meta = try await store.clearHistory(beforeMs: nil, nowMs: t0)
        #expect(meta.clearEpoch == 1)
        #expect(meta.deletedBeforeMs == t0 + 60_000)
        #expect(try await store.totalPointCount() == 0)
        #expect(try await store.pendingOutboxCount() == 0)
        // P2-1: Full clear MUST also clear stale-epoch pending_state_update!
        #expect(try await store.pendingStateUpdate() == nil)

        // P2-4: Strict `< cutoff` prune where a 2-point segment has endMs == cutoff MUST recompute its summary!
        let pruneDir = makeTempDir("prune-boundary")
        defer { try? FileManager.default.removeItem(at: pruneDir) }
        let pruneStore = try await FootprintStore.open(directoryURL: pruneDir)
        let cutoffNowMs: Int64 = 1_800_000_000_000
        let cutoffMs = cutoffNowMs - Int64(7) * 86_400_000
        let b1 = FootprintPoint(pointID: "b1", segmentID: "bseg", measuredAtMs: cutoffMs - 100_000, latitude: 52.95, longitude: -1.15, accuracyMeters: 8, accuracyAuth: .full)
        let b2 = FootprintPoint(pointID: "b2", segmentID: "bseg", measuredAtMs: cutoffMs, latitude: 52.96, longitude: -1.16, accuracyMeters: 8, accuracyAuth: .full)
        _ = try await pruneStore.append([b1, b2], enqueueForSync: false, nowMs: cutoffMs)
        let pruned = try await pruneStore.pruneExpired(retentionDays: 7, nowMs: cutoffNowMs)
        #expect(pruned == 1)
        let postPruneSummary = try await pruneStore.summary(fromMs: 0, toMs: cutoffNowMs)
        #expect(postPruneSummary.pointCount == 1)
        #expect(postPruneSummary.totalDistanceMeters == 0)

        // P2-5: BST local day count (Europe/London 00:30 BST = 23:30 UTC prev day, 12:30 BST = 11:30 UTC same day -> 1 local active day!)
        var londonCal = Calendar(identifier: .gregorian)
        londonCal.timeZone = TimeZone(identifier: "Europe/London")!
        let bstDir = makeTempDir("bst-days")
        defer { try? FileManager.default.removeItem(at: bstDir) }
        let bstStore = try await FootprintStore.open(directoryURL: bstDir)
        let july10Start = londonCal.date(from: DateComponents(year: 2026, month: 7, day: 10, hour: 0, minute: 0))!
        let bst0030 = Int64(july10Start.addingTimeInterval(30 * 60).timeIntervalSince1970 * 1000.0)
        let bst1230 = Int64(july10Start.addingTimeInterval(12 * 3600 + 30 * 60).timeIntervalSince1970 * 1000.0)
        let bp1 = FootprintPoint(pointID: "bp1", segmentID: "s-bst", measuredAtMs: bst0030, latitude: 52.95, longitude: -1.15, accuracyMeters: 8, accuracyAuth: .full)
        let bp2 = FootprintPoint(pointID: "bp2", segmentID: "s-bst", measuredAtMs: bst1230, latitude: 52.951, longitude: -1.151, accuracyMeters: 8, accuracyAuth: .full)
        _ = try await bstStore.append([bp1, bp2], enqueueForSync: false, nowMs: bst1230)
        let (dayFrom, dayTo) = FootprintTimelineScope.day.rangeMs(around: july10Start, calendar: londonCal)
        let bstSummary = try await bstStore.summary(fromMs: dayFrom, toMs: dayTo, calendar: londonCal)
        #expect(bstSummary.activeDays == 1)
        // Wide range query (fromMs=0) MUST NOT truncate active days to 0!
        let wideSummary = try await bstStore.summary(fromMs: 0, toMs: bst1230 + 1000, calendar: londonCal)
        #expect(wideSummary.activeDays == 1)

        // Out-of-order rowids in a segment (t=0,100 inserted first, then t=10..90) with budget=5 MUST sample interior points (>2)!
        let oooDir = makeTempDir("ooo-sampling")
        defer { try? FileManager.default.removeItem(at: oooDir) }
        let oooStore = try await FootprintStore.open(directoryURL: oooDir)
        let oooTimes: [Int64] = [0, 100, 10, 20, 30, 40, 50, 60, 70, 80, 90]
        let oooPoints = oooTimes.enumerated().map { idx, sec in
            FootprintPoint(pointID: "ooo-\(idx)", segmentID: "seg-ooo", measuredAtMs: 1_795_000_000_000 + sec * 1000, latitude: 52.95 + Double(sec) * 0.0001, longitude: -1.15, accuracyMeters: 6, accuracyAuth: .full)
        }
        _ = try await oooStore.append(oooPoints, enqueueForSync: false, nowMs: 1_795_000_200_000)
        let oooPayload = try await oooStore.timelinePayload(fromMs: 1_795_000_000_000, toMs: 1_795_000_100_000, maxTotalPoints: 5)
        let oooRendered = oooPayload.segments.reduce(0) { $0 + $1.points.count }
        #expect(oooRendered >= 4 && oooRendered <= 5)

        // Sparse year (5000 pts in Jan + 1 lone point 364 days later, budget=4000) MUST NOT undersample Jan segment to 3 points!
        let sparseDir = makeTempDir("sparse-year")
        defer { try? FileManager.default.removeItem(at: sparseDir) }
        let sparseStore = try await FootprintStore.open(directoryURL: sparseDir)
        let janStart: Int64 = 1_767_225_600_000
        var sparseBatch: [FootprintPoint] = []
        sparseBatch.reserveCapacity(5001)
        for i in 0..<5000 {
            sparseBatch.append(FootprintPoint(pointID: "sp-\(i)", segmentID: "seg-jan", measuredAtMs: janStart + Int64(i) * 10_000, latitude: 52.95 + Double(i) * 0.00001, longitude: -1.15, accuracyMeters: 6, accuracyAuth: .full))
        }
        let decEnd = janStart + Int64(364) * 86_400_000
        sparseBatch.append(FootprintPoint(pointID: "sp-dec", segmentID: "seg-dec", measuredAtMs: decEnd, latitude: 53.00, longitude: -1.20, accuracyMeters: 6, accuracyAuth: .full))
        _ = try await sparseStore.append(sparseBatch, enqueueForSync: false, nowMs: decEnd)
        let sparsePayload = try await sparseStore.timelinePayload(fromMs: janStart, toMs: decEnd, maxTotalPoints: 4000)
        let sparseRendered = sparsePayload.segments.reduce(0) { $0 + $1.points.count }
        #expect(sparseRendered >= 3500 && sparseRendered <= 4000)

        // 2,000 single-point segments + ONE 5,000-point long route (positioned 2nd chronologically!), budget=4,000:
        // The sole long route MUST NEVER be skipped; both singles AND ~2,000 route points are rendered!
        let mixedDir = makeTempDir("mixed-singles-and-route")
        defer { try? FileManager.default.removeItem(at: mixedDir) }
        let mixedStore = try await FootprintStore.open(directoryURL: mixedDir)
        var mixedBatch: [FootprintPoint] = []
        mixedBatch.reserveCapacity(7000)
        // Segment 0: single point
        mixedBatch.append(FootprintPoint(pointID: "ms-0", segmentID: "single-0", measuredAtMs: janStart, latitude: 52.90, longitude: -1.10, accuracyMeters: 6, accuracyAuth: .full))
        // Segment 1 (index 1 — would be skipped by naive stride=2!): 5,000-point long route!
        let routeStart = janStart + 600_000
        for i in 0..<5000 {
            mixedBatch.append(FootprintPoint(pointID: "mr-\(i)", segmentID: "sole-long-route", measuredAtMs: routeStart + Int64(i) * 5_000, latitude: 52.95 + Double(i) * 0.00001, longitude: -1.15, accuracyMeters: 6, accuracyAuth: .full))
        }
        // Segments 2..2000: 1,999 more single-point segments
        let singlesStart = routeStart + Int64(5000) * 5_000 + 600_000
        for i in 1..<2000 {
            mixedBatch.append(FootprintPoint(pointID: "ms-\(i)", segmentID: "single-\(i)", measuredAtMs: singlesStart + Int64(i) * 600_000, latitude: 52.91, longitude: -1.11, accuracyMeters: 6, accuracyAuth: .full))
        }
        let mixedEnd = singlesStart + Int64(2000) * 600_000
        _ = try await mixedStore.append(mixedBatch, enqueueForSync: false, nowMs: mixedEnd)
        let mixedPayload = try await mixedStore.timelinePayload(fromMs: janStart, toMs: mixedEnd, maxTotalPoints: 4000)
        let longRouteSegment = mixedPayload.segments.first { $0.id == "sole-long-route" }
        #expect(longRouteSegment != nil)
        #expect((longRouteSegment?.points.count ?? 0) >= 1800)
        let mixedTotalRendered = mixedPayload.segments.reduce(0) { $0 + $1.points.count }
        #expect(mixedTotalRendered <= 4000 && mixedTotalRendered >= 3800)

        // P2-2: 3,999 2-point segments FIRST + ONE 5,000-point long route LAST, budget=4,000:
        // The last long route MUST receive actual reserved drawing slots (endpoints + interior points, NEVER 0)!
        let tailRouteDir = makeTempDir("tail-long-route")
        defer { try? FileManager.default.removeItem(at: tailRouteDir) }
        let tailRouteStore = try await FootprintStore.open(directoryURL: tailRouteDir)
        var tailBatch: [FootprintPoint] = []
        tailBatch.reserveCapacity(13_000)
        for i in 0..<3999 {
            let sTime = janStart + Int64(i) * 60_000
            tailBatch.append(FootprintPoint(pointID: "t2-\(i)-a", segmentID: "short-\(i)", measuredAtMs: sTime, latitude: 52.90, longitude: -1.10, accuracyMeters: 6, accuracyAuth: .full))
            tailBatch.append(FootprintPoint(pointID: "t2-\(i)-b", segmentID: "short-\(i)", measuredAtMs: sTime + 10_000, latitude: 52.901, longitude: -1.101, accuracyMeters: 6, accuracyAuth: .full))
        }
        let tailLongStart = janStart + Int64(4000) * 60_000
        for i in 0..<5000 {
            tailBatch.append(FootprintPoint(pointID: "tl-\(i)", segmentID: "final-long-route", measuredAtMs: tailLongStart + Int64(i) * 5_000, latitude: 52.95 + Double(i) * 0.00001, longitude: -1.15, accuracyMeters: 6, accuracyAuth: .full))
        }
        let tailEnd = tailLongStart + Int64(5000) * 5_000
        _ = try await tailRouteStore.append(tailBatch, enqueueForSync: false, nowMs: tailEnd)
        let tailPayload = try await tailRouteStore.timelinePayload(fromMs: janStart, toMs: tailEnd, maxTotalPoints: 4000)
        let finalLongSeg = tailPayload.segments.first { $0.id == "final-long-route" }
        #expect(finalLongSeg != nil)
        #expect((finalLongSeg?.points.count ?? 0) >= 400)
        #expect(tailPayload.segments.reduce(0) { $0 + $1.points.count } <= 4000)

        // P2-2 Straddling cross-year segment (5,001 pts total, ONLY 1 pt inside target year) + 3,998 2-pt segments +
        // 5,000-pt true in-year long route, budget=4,000 -> true in-year long route MUST win the longest-route reservation!
        let straddleDir = makeTempDir("straddle-cross-year")
        defer { try? FileManager.default.removeItem(at: straddleDir) }
        let straddleStore = try await FootprintStore.open(directoryURL: straddleDir)
        var straddleBatch: [FootprintPoint] = []
        straddleBatch.reserveCapacity(18_000)
        // 5,000 points in previous year + 1 point on Jan 1 of target year = 5,001 total points, only 1 in-window!
        for i in 0..<5000 {
            let ts = janStart - Int64(5000 - i) * 5_000
            straddleBatch.append(FootprintPoint(pointID: "cy-\(i)", segmentID: "cross-year-seg", measuredAtMs: ts, latitude: 52.80, longitude: -1.20, accuracyMeters: 6, accuracyAuth: .full))
        }
        straddleBatch.append(FootprintPoint(pointID: "cy-5000", segmentID: "cross-year-seg", measuredAtMs: janStart, latitude: 52.801, longitude: -1.201, accuracyMeters: 6, accuracyAuth: .full))
        for i in 0..<3998 {
            let sTime = janStart + Int64(i + 1) * 60_000
            straddleBatch.append(FootprintPoint(pointID: "sy-\(i)-a", segmentID: "short-y-\(i)", measuredAtMs: sTime, latitude: 52.90, longitude: -1.10, accuracyMeters: 6, accuracyAuth: .full))
            straddleBatch.append(FootprintPoint(pointID: "sy-\(i)-b", segmentID: "short-y-\(i)", measuredAtMs: sTime + 10_000, latitude: 52.901, longitude: -1.101, accuracyMeters: 6, accuracyAuth: .full))
        }
        let trueLongStart = janStart + Int64(4000) * 60_000
        for i in 0..<5000 {
            straddleBatch.append(FootprintPoint(pointID: "ty-\(i)", segmentID: "true-in-year-route", measuredAtMs: trueLongStart + Int64(i) * 5_000, latitude: 52.95 + Double(i) * 0.00001, longitude: -1.15, accuracyMeters: 6, accuracyAuth: .full))
        }
        let straddleEnd = trueLongStart + Int64(5000) * 5_000
        _ = try await straddleStore.append(straddleBatch, enqueueForSync: false, nowMs: straddleEnd)
        let straddlePayload = try await straddleStore.timelinePayload(fromMs: janStart, toMs: straddleEnd, maxTotalPoints: 4000)
        let trueInYearSeg = straddlePayload.segments.first { $0.id == "true-in-year-route" }
        #expect(trueInYearSeg != nil)
        #expect((trueInYearSeg?.points.count ?? 0) >= 400)
        #expect(straddlePayload.segments.reduce(0) { $0 + $1.points.count } <= 4000)

        // Single-transaction appendBatch preserves per-point sync eligibility & destinationKey atomically
        let batchDir = makeTempDir("atomic-batch")
        defer { try? FileManager.default.removeItem(at: batchDir) }
        let batchStore = try await FootprintStore.open(directoryURL: batchDir)
        let bpLocalOnly = FootprintPoint(pointID: "ab-local", segmentID: "s-ab", measuredAtMs: t0 + 10_000, latitude: 52.95, longitude: -1.15, accuracyMeters: 6, accuracyAuth: .full)
        let bpForB = FootprintPoint(pointID: "ab-b", segmentID: "s-ab", measuredAtMs: t0 + 20_000, latitude: 52.96, longitude: -1.16, accuracyMeters: 6, accuracyAuth: .full)
        let insertedAtomic = try await batchStore.appendBatch([
            FootprintAnnotatedWrite(point: bpLocalOnly, enqueueForSync: false, destinationKey: ""),
            FootprintAnnotatedWrite(point: bpForB, enqueueForSync: true, destinationKey: "https://server-b.example.com")
        ], nowMs: t0 + 25_000)
        #expect(insertedAtomic == 2)
        #expect(try await batchStore.totalPointCount() == 2)
        let bQueue = try await batchStore.dequeueReadyOutboxBatch(limit: 10, nowMs: t0 + 25_000, destinationKey: "https://server-b.example.com")
        #expect(bQueue?.items.map(\.pointID) == ["ab-b"])

        // Unbound samples remain local and never enter any destination queue.
        let unboundPt = FootprintPoint(pointID: "unbound-1", segmentID: "su", measuredAtMs: t0 + 120_000, latitude: 52.95, longitude: -1.15, accuracyMeters: 8, accuracyAuth: .full)
        _ = try await store.append([unboundPt], enqueueForSync: true, destinationKey: "", nowMs: t0 + 120_000)
        #expect(try await store.pendingOutboxCount() == 0)
        #expect(try await store.dequeueReadyOutboxBatch(limit: 10, nowMs: t0 + 120_000, destinationKey: "https://server-a.example.com") == nil)
        #expect(try await store.dequeueReadyOutboxBatch(limit: 10, nowMs: t0 + 120_000, destinationKey: "https://server-b.example.com") == nil)

        // Attempt to backfill old point or point inside T+60s window or old clear_epoch -> must be blocked!
        let stalePoint = FootprintPoint(pointID: "p2", segmentID: "s1", measuredAtMs: t0 + 30_000, latitude: 52.95, longitude: -1.15, accuracyMeters: 10, accuracyAuth: .full)
        #expect(try await store.append([stalePoint], enqueueForSync: true, nowMs: t0 + 35_000) == 0)

        let oldEpochPoint = FootprintPoint(pointID: "p3", segmentID: "s2", measuredAtMs: t0 + 120_000, latitude: 52.95, longitude: -1.15, accuracyMeters: 10, accuracyAuth: .full)
        #expect(try await store.append([oldEpochPoint], enqueueForSync: true, expectedClearEpoch: 0, nowMs: t0 + 120_000) == 0)

        // Fresh point after T+60s with current clear_epoch succeeds.
        #expect(try await store.append([oldEpochPoint], enqueueForSync: true, expectedClearEpoch: 1, nowMs: t0 + 120_000) == 1)
        #expect(try await store.pendingOutboxCount() == 0)
    }

    @Test("Sliding-window tray semantics enforce allowlist, omit, reduced-accuracy, and per-agent home ACL")
    func slidingWindowSemanticsAndPrivacyBoundaries() throws {
        let now = 1_795_300_000.0
        let homeCoord = LocationSnapshot(latitude: 52.9500, longitude: -1.1500, accuracyMeters: 10, measuredAt: now - 3600, precise: true)
        let homePlace = LocationPlace(id: "home-1", name: "家", aliases: ["home"], address: "Nottingham", coordinate: homeCoord, sharedAgentIDs: ["alice"])

        var settings = LocationSharingSettings()
        settings.enabled = true
        settings.agentIDs = ["alice", "charlie"] // charlie is allowlisted for location, NOT for homePlace!
        settings.places = [homePlace]

        // Recent walking trajectory moving closer to home (returning)
        let recent: [FootprintPoint] = [
            FootprintPoint(pointID: "r1", segmentID: "segA", measuredAtMs: Int64((now - 180) * 1000), latitude: 52.9540, longitude: -1.1500, accuracyMeters: 8, speedMps: 1.4, accuracyAuth: .full),
            FootprintPoint(pointID: "r2", segmentID: "segA", measuredAtMs: Int64((now - 90) * 1000), latitude: 52.9525, longitude: -1.1500, accuracyMeters: 8, speedMps: 1.4, accuracyAuth: .full)
        ]
        let currentPrecise = LocationSnapshot(latitude: 52.9512, longitude: -1.1500, accuracyMeters: 7, measuredAt: now - 5, precise: true, speedMps: 1.5)

        let ctx = LocationRequestContext(
            snapshot: currentPrecise,
            availability: .available,
            settings: settings,
            device: "iPhone",
            recentFootprintPoints: recent
        )

        // 1. Alice (allowlisted + has home ACL) gets motion_state=walking, heading_to_home=returning, recent_movement
        let aliceJSON = try extractTrayJSON(ctx.forAgent("alice").tray(at: now))
        #expect(aliceJSON["motion_state"].text == "walking")
        #expect(aliceJSON["heading_to_home"].text == "returning")
        #expect(aliceJSON["distance_to_home_m"].number != nil)
        #expect(aliceJSON["recent_movement"]["distance_m"].number ?? 0 >= 250)

        // 2. Charlie (allowlisted for location, NOT in homePlace.sharedAgentIDs) gets walking, NEVER heading_to_home/distance_to_home_m!
        let charlieJSON = try extractTrayJSON(ctx.forAgent("charlie").tray(at: now))
        #expect(charlieJSON["motion_state"].text == "walking")
        #expect(charlieJSON["heading_to_home"] == .null)
        #expect(charlieJSON["distance_to_home_m"] == .null)

        // 3. Bob (NOT in agentIDs allowlist) gets strictly omitted tray!
        let bobTray = try ctx.forAgent("bob").tray(at: now)
        #expect(bobTray == LocationRequestContext.omittedTray)

        // 4. Reduced accuracy snapshot MUST NEVER backfill precise footprint semantics or home intent!
        let reducedSnap = LocationSnapshot(latitude: 52.95, longitude: -1.15, accuracyMeters: 3000, measuredAt: now - 5, precise: false)
        let reducedCtx = LocationRequestContext(
            snapshot: reducedSnap,
            availability: .available,
            settings: settings,
            device: "iPhone",
            recentFootprintPoints: recent
        )
        let reducedJSON = try extractTrayJSON(reducedCtx.forAgent("alice").tray(at: now))
        #expect(reducedJSON["accuracy_authorization"].text == "reduced")
        #expect(reducedJSON["motion_state"] == .null)
        #expect(reducedJSON["heading_to_home"] == .null)
        #expect(reducedJSON["recent_movement"] == .null)

        // 5. Missing/unavailable chat snapshot MUST NEVER backfill from recentFootprintPoints!
        let unavailableCtx = LocationRequestContext(
            snapshot: nil,
            availability: .unavailable,
            settings: settings,
            device: "iPhone",
            recentFootprintPoints: recent
        )
        let unavailableJSON = try extractTrayJSON(unavailableCtx.forAgent("alice").tray(at: now))
        #expect(unavailableJSON["status"].text == "unavailable")
        #expect(unavailableJSON["latitude"] == .null)
        #expect(unavailableJSON["motion_state"] == .null)

        // 6. P1-1: One-off .include to a non-allowlisted agent (guest) shares current coordinate ONLY,
        //    EVEN IF guest is listed in an individual place's sharedAgentIDs — NEVER saved_places, near_saved_places, or semantics!
        var settingsWithGuestPlace = settings
        settingsWithGuestPlace.places.append(
            LocationPlace(id: "cafe-guest", name: "Cafe", address: "Secret St", coordinate: currentPrecise, sharedAgentIDs: ["guest"])
        )
        let oneOffCtx = LocationRequestContext(
            snapshot: currentPrecise,
            availability: .available,
            settings: settingsWithGuestPlace,
            device: "iPhone",
            recipients: ["guest"],
            recentFootprintPoints: recent
        )
        let guestJSON = try extractTrayJSON(oneOffCtx.forAgent("guest").tray(at: now))
        #expect(guestJSON["latitude"].number == currentPrecise.latitude)
        #expect(guestJSON["saved_places"] == .null)
        #expect(guestJSON["near_saved_places"] == .null)
        #expect(guestJSON["motion_state"] == .null)
        #expect(guestJSON["dwelling"] == .null)
        #expect(guestJSON["dwell_sec"] == .null)
        #expect(guestJSON["recent_movement"] == .null)
        #expect(guestJSON["heading_to_home"] == .null)

        // 7. P2-2: Two stationary observations 20 minutes apart (>120s gap) MUST NOT infer 20-minute continuous dwell!
        let oldSameSpot = FootprintPoint(
            pointID: "old-spot",
            segmentID: "old-seg",
            measuredAtMs: Int64((now - 1200) * 1000),
            latitude: currentPrecise.latitude,
            longitude: currentPrecise.longitude,
            accuracyMeters: 8,
            accuracyAuth: .full
        )
        let gappedSemantics = LocalMovementSemanticCalculator.compute(
            current: LocationSnapshot(latitude: currentPrecise.latitude, longitude: currentPrecise.longitude, accuracyMeters: 8, measuredAt: now - 2, precise: true),
            recentPoints: [oldSameSpot],
            sharedPlaces: [],
            now: now
        )
        #expect(gappedSemantics?.dwelling == false)
        #expect((gappedSemantics?.dwellSeconds ?? 999) == 0)

        // 8. P2-2: Chat fix <1s from the first point of a NEW segment must lock onto the new segment
        //    and NEVER bleed into the previous segment's 5-minute dwell!
        let crossSegRecent: [FootprintPoint] = [
            FootprintPoint(pointID: "old-1", segmentID: "seg-old", measuredAtMs: Int64((now - 360) * 1000), latitude: currentPrecise.latitude, longitude: currentPrecise.longitude, accuracyMeters: 6, accuracyAuth: .full),
            FootprintPoint(pointID: "old-2", segmentID: "seg-old", measuredAtMs: Int64((now - 260) * 1000), latitude: currentPrecise.latitude, longitude: currentPrecise.longitude, accuracyMeters: 6, accuracyAuth: .full),
            FootprintPoint(pointID: "old-3", segmentID: "seg-old", measuredAtMs: Int64((now - 160) * 1000), latitude: currentPrecise.latitude, longitude: currentPrecise.longitude, accuracyMeters: 6, accuracyAuth: .full),
            FootprintPoint(pointID: "old-4", segmentID: "seg-old", measuredAtMs: Int64((now - 60) * 1000), latitude: currentPrecise.latitude, longitude: currentPrecise.longitude, accuracyMeters: 6, accuracyAuth: .full),
            FootprintPoint(pointID: "new-1", segmentID: "seg-new", measuredAtMs: Int64((now - 2.2) * 1000), latitude: currentPrecise.latitude, longitude: currentPrecise.longitude, accuracyMeters: 6, accuracyAuth: .full)
        ]
        let crossSegSemantics = LocalMovementSemanticCalculator.compute(
            current: LocationSnapshot(latitude: currentPrecise.latitude, longitude: currentPrecise.longitude, accuracyMeters: 6, measuredAt: now - 2.0, precise: true),
            recentPoints: crossSegRecent,
            sharedPlaces: [],
            now: now
        )
        #expect(crossSegSemantics?.dwelling == false)
        #expect((crossSegSemantics?.dwellSeconds ?? 999) == 0)
    }

    @Test("GeoJSON exports distinct LineStrings per segment without bridging gaps and Point features for reduced accuracy")
    func geoJSONRespectsSegmentsAndReducedAccuracy() throws {
        let s1 = FootprintSegment(id: "seg-1", points: [
            FootprintPoint(pointID: "a1", segmentID: "seg-1", measuredAtMs: 1_000, latitude: 52.95, longitude: -1.15, accuracyMeters: 8, accuracyAuth: .full),
            FootprintPoint(pointID: "a2", segmentID: "seg-1", measuredAtMs: 60_000, latitude: 52.951, longitude: -1.151, accuracyMeters: 8, accuracyAuth: .full)
        ])
        let s2 = FootprintSegment(id: "seg-2", points: [
            FootprintPoint(pointID: "b1", segmentID: "seg-2", measuredAtMs: 500_000, latitude: 52.96, longitude: -1.16, accuracyMeters: 8, accuracyAuth: .full),
            FootprintPoint(pointID: "b2", segmentID: "seg-2", measuredAtMs: 560_000, latitude: 52.961, longitude: -1.161, accuracyMeters: 8, accuracyAuth: .full)
        ])
        let sReduced = FootprintSegment(id: "seg-reduced", points: [
            FootprintPoint(pointID: "c1", segmentID: "seg-reduced", measuredAtMs: 600_000, latitude: 52.97, longitude: -1.17, accuracyMeters: 2500, accuracyAuth: .reduced),
            FootprintPoint(pointID: "c2", segmentID: "seg-reduced", measuredAtMs: 650_000, latitude: 52.971, longitude: -1.171, accuracyMeters: 2500, accuracyAuth: .reduced)
        ])

        let data = try FootprintGeoJSONExporter.export(segments: [s1, s2, sReduced])
        let json = try JSONDecoder().decode(JSONValue.self, from: data)
        #expect(json["type"].text == "FeatureCollection")
        let features = json["features"].array
        // 2 LineStrings (seg-1, seg-2) + 2 Point features (reduced points never drawn as polyline)
        #expect(features.count == 4)
        #expect(features[0]["geometry"]["type"].text == "LineString")
        #expect(features[0]["properties"]["segment_id"].text == "seg-1")
        #expect(features[1]["geometry"]["type"].text == "LineString")
        #expect(features[1]["properties"]["segment_id"].text == "seg-2")
        #expect(features[2]["geometry"]["type"].text == "Point")
        #expect(features[3]["geometry"]["type"].text == "Point")
    }

    @Test("Locked persistent Keychain before first unlock throws protectedDataUnavailable and NEVER creates a new device_id")
    func lockedKeychainDoesNotGenerateNewIdentity() async throws {
        let store = MockSecretStore()
        await store.setLocked(true)

        do {
            _ = try await FootprintIdentityStore.resolveDeviceID(from: store, allowingInteraction: false)
            Issue.record("Expected protectedDataUnavailable when locked")
        } catch let err as FootprintIdentityError {
            #expect(err == .protectedDataUnavailable)
        }
        #expect(await store.getSaveCount() == 0)

        // Once unlocked, existing identity is preserved or created once.
        await store.setLocked(false)
        await store.setValues([PersistentFootprintKeychain.deviceIDAccount: "existing-device-id"])
        let resolved = try await FootprintIdentityStore.resolveDeviceID(from: store, allowingInteraction: false)
        #expect(resolved == "existing-device-id")
        #expect(await store.getSaveCount() == 0)
    }

    @Test("Optional HTTPS sync enforces HTTPS, gzip batch JSON, OwnTracks format, zero-stationary heartbeat, and downgrade drop")
    func optionalHTTPSSyncAndScheduler() async throws {
        let dir = makeTempDir("sync")
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = try await FootprintStore.open(directoryURL: dir)
        let transport = MockHTTPTransport()
        let client = FootprintSyncClient(transport: transport)

        // Scheduler: stationary with no transition -> STRICTLY 0 wakeups even when pendingCount >= 15; transition -> immediate
        let scheduler = FootprintUploadScheduler(lastUploadAt: 1000)
        let stationaryPt = FootprintPoint(pointID: "st1", segmentID: "s1", measuredAtMs: 1_050_000, latitude: 52.95, longitude: -1.15, accuracyMeters: 10, accuracyAuth: .full, motionState: .stationary)
        #expect(scheduler.shouldUploadNow(pendingCount: 25, latestPoint: stationaryPt, now: 1500) == false)

        let transitionPt = FootprintPoint(pointID: "tr1", segmentID: "s1", measuredAtMs: 1_060_000, latitude: 52.95, longitude: -1.15, accuracyMeters: 10, accuracyAuth: .full, motionState: .walking, transitionEvent: FootprintTransitionEvent.leftHome.rawValue)
        #expect(scheduler.shouldUploadNow(pendingCount: 1, latestPoint: transitionPt, now: 1060) == true)
        #expect(scheduler.shouldUploadNow(pendingCount: 1, latestPoint: stationaryPt, hasTransitionEvent: true, now: 1060) == true)

        // Destination-scoped Keychain accounts isolate credentials across different URLs AND case-sensitive paths!
        #expect(FootprintIdentityStore.writeTokenAccount(for: "https://a.example.com") != FootprintIdentityStore.writeTokenAccount(for: "https://b.example.com"))
        #expect(FootprintIdentityStore.writeTokenAccount(for: "https://host.example.com/TeamA/pub") != FootprintIdentityStore.writeTokenAccount(for: "https://host.example.com/teama/pub"))
        #expect(FootprintIdentityStore.writeTokenAccount(for: "HTTPS://HOST.example.com/TeamA/pub") == FootprintIdentityStore.writeTokenAccount(for: "https://host.example.com/TeamA/pub"))

        // Plain HTTP URL is rejected
        var httpSettings = FootprintSettings(enabled: true, syncEnabled: true, syncEndpointURL: "http://insecure.example.com")
        #expect(httpSettings.validatedHTTPSURL() == nil)
        _ = try await store.append([transitionPt], enqueueForSync: true, destinationKey: "https://track.example.com", nowMs: 1_060_000)
        do {
            _ = try await client.flushOutbox(store: store, settings: httpSettings, deviceID: "dev-1", writeToken: "tok", nowMs: 1_060_000)
            Issue.record("Expected invalidHTTPSURL")
        } catch let err as FootprintSyncError {
            #expect(err == .invalidHTTPSURL)
        }
        #expect(await transport.recordedRequests().isEmpty)

        // Disabled sync sends zero requests
        httpSettings.syncEnabled = false
        httpSettings.syncEndpointURL = "https://track.example.com"
        #expect(try await client.flushOutbox(store: store, settings: httpSettings, deviceID: "dev-1", writeToken: "tok", nowMs: 1_060_000) == nil)
        #expect(await transport.recordedRequests().isEmpty)

        // P2-3: Empty 200 body MUST NOT be treated as whole-batch ACK!
        var batchSettings = FootprintSettings(enabled: true, syncEnabled: true, syncEndpointURL: "https://track.example.com", syncFormat: .batchJSON)
        await transport.setHandler { _ in FootprintHTTPResponse(statusCode: 200, body: Data()) }
        do {
            _ = try await client.flushOutbox(store: store, settings: batchSettings, deviceID: "dev-1", writeToken: "secret-tok", nowMs: 1_060_000)
            Issue.record("Expected invalidServerAck on empty 200 body")
        } catch let err as FootprintSyncError {
            #expect(err == .invalidServerAck)
        }
        #expect(try await store.pendingOutboxCount() == 1)

        // Valid HTTPS batch JSON with gzip header & RFC 1952 magic bytes 0x1F 0x8B (after backoff window passes)
        await transport.setHandler { _ in
            let ack = Data("{\"acked_point_ids\":[\"tr1\"],\"rejected\":[]}".utf8)
            return FootprintHTTPResponse(statusCode: 200, body: ack)
        }
        let batchResult = try await client.flushOutbox(store: store, settings: batchSettings, deviceID: "dev-1", writeToken: "secret-tok", nowMs: 1_200_000)
        #expect(batchResult?.ackedPointIDs == ["tr1"])
        #expect(try await store.pendingOutboxCount() == 0)

        let reqs = await transport.recordedRequests()
        #expect(reqs.count == 2)
        #expect(reqs[1].url.absoluteString == "https://track.example.com/ingest/batch")
        #expect(reqs[1].headers["Authorization"] == "Bearer secret-tok")
        #expect(reqs[1].headers["Content-Encoding"] == "gzip")
        #expect(reqs[1].body.prefix(2) == Data([0x1F, 0x8B]))

        // OwnTracks: P1-3 & P2-3 -> stopping mid-batch via shouldContinue MUST halt before sending point 2,
        // and point 1 is already acknowledged so it is NEVER resent!
        batchSettings.syncFormat = .owntracks
        let ot1 = FootprintPoint(pointID: "ot1", segmentID: "s2", measuredAtMs: 1_210_000, latitude: 52.952, longitude: -1.152, accuracyMeters: 9, speedMps: 2.0, courseDegrees: 90, accuracyAuth: .full)
        let ot2 = FootprintPoint(pointID: "ot2", segmentID: "s2", measuredAtMs: 1_220_000, latitude: 52.953, longitude: -1.153, accuracyMeters: 9, speedMps: 2.0, courseDegrees: 90, accuracyAuth: .full)
        _ = try await store.append([ot1, ot2], enqueueForSync: true, destinationKey: "https://track.example.com", nowMs: 1_220_000)
        await transport.setHandler { _ in FootprintHTTPResponse(statusCode: 200, body: Data("[]".utf8)) }
        actor GateCounter {
            var checks = 0
            // Check 1 = before POST #1, Check 2 = after POST #1 before ACK, Check 3 = before POST #2 (halt!)
            func allow() -> Bool { checks += 1; return checks <= 2 }
        }
        let gate = GateCounter()
        do {
            _ = try await client.flushOutbox(
                store: store,
                settings: batchSettings,
                deviceID: "ab-1234",
                writeToken: "secret-tok",
                nowMs: 1_220_000,
                shouldContinue: { await gate.allow() }
            )
            Issue.record("Expected cancelledByStateChange before 2nd OwnTracks POST")
        } catch let err as FootprintSyncError {
            #expect(err == .cancelledByStateChange)
        }
        // Exactly 1 OwnTracks POST went out; ot1 was immediately acked, only ot2 remains queued!
        #expect(await transport.recordedRequests().count == 3)
        #expect(try await store.pendingOutboxCount() == 1)
        let remaining = try await store.dequeueReadyOutbox(limit: 10, nowMs: 1_220_000)
        #expect(remaining.map(\.pointID) == ["ot2"])
        let otReq = try #require(await transport.recordedRequests().last)
        #expect(otReq.url.absoluteString == "https://track.example.com/ingest/owntracks")
        let otPayload = try JSONDecoder().decode(JSONValue.self, from: otReq.body)
        #expect(otPayload["_type"].text == "location")
        #expect(otPayload["lat"].number == 52.952)
        #expect(otPayload["lon"].number == -1.152)

        // Downgrade drops all pending precise outbox items (ot2 + pr1 = 2) & coordinate-free state update contains no lat/lng
        let pendingPrecise = FootprintPoint(pointID: "pr1", segmentID: "s3", measuredAtMs: 1_230_000, latitude: 52.953, longitude: -1.153, accuracyMeters: 5, accuracyAuth: .full)
        _ = try await store.append([pendingPrecise], enqueueForSync: true, destinationKey: "https://track.example.com", nowMs: 1_230_000)
        let dropped = try await store.dropPendingPreciseOutbox()
        #expect(dropped == 2)
        #expect(try await store.pendingOutboxCount() == 0)

        let stateUpdateRes = try await client.sendCoordinateFreeStateUpdate(
            settings: batchSettings,
            deviceID: "dev-1",
            writeToken: "secret-tok",
            clearEpoch: 0,
            accuracyAuth: .reduced,
            status: "reduced_accuracy",
            measuredAtMs: 1_085_000
        )
        #expect(stateUpdateRes.sentStateUpdateOnly == true)

        // P2-3: OwnTracks format MUST NOT block on /ingest/batch 404 when pendingStateUpdate exists;
        //       subsequent reduced points upload cleanly to /ingest/owntracks.
        try await store.setPendingStateUpdate(FootprintPendingStateUpdate(clearEpoch: 0, accuracyAuth: .reduced, status: "reduced_accuracy", measuredAtMs: 1_240_000))
        let reducedOT = FootprintPoint(pointID: "ot-red", segmentID: "s4", measuredAtMs: 1_250_000, latitude: 52.95, longitude: -1.15, accuracyMeters: 2500, accuracyAuth: .reduced)
        _ = try await store.append([reducedOT], enqueueForSync: true, destinationKey: "https://track.example.com", nowMs: 1_250_000)
        await transport.setHandler { req in
            if req.url.path.hasSuffix("/ingest/batch") {
                return FootprintHTTPResponse(statusCode: 404, body: Data())
            }
            return FootprintHTTPResponse(statusCode: 200, body: Data("[]".utf8))
        }
        let otAfterDowngrade = try await client.flushOutbox(
            store: store,
            settings: batchSettings,
            deviceID: "ab-1234",
            writeToken: "secret-tok",
            currentAccuracyAuth: .reduced,
            nowMs: 1_250_000
        )
        #expect(otAfterDowngrade?.ackedPointIDs == ["ot-red"])
        #expect(try await store.pendingStateUpdate() == nil)
    }

    @Test("100k annual dataset indexed range query and day summary finish well within 200ms")
    func annualDatasetQueryPerformance() async throws {
        let dir = makeTempDir("perf-100k")
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = try await FootprintStore.open(directoryURL: dir)

        let startMs: Int64 = 1_767_225_600_000 // 2026-01-01
        let total = 100_000
        let batchSize = 5_000
        for batchStart in stride(from: 0, to: total, by: batchSize) {
            var batch: [FootprintPoint] = []
            batch.reserveCapacity(batchSize)
            for i in batchStart..<(batchStart + batchSize) {
                let seg = "seg-\(i / 200)"
                batch.append(FootprintPoint(
                    pointID: "p-\(i)",
                    segmentID: seg,
                    measuredAtMs: startMs + Int64(i) * 300_000,
                    latitude: 52.95 + Double(i % 100) * 0.0001,
                    longitude: -1.15 + Double(i % 100) * 0.0001,
                    accuracyMeters: 10,
                    accuracyAuth: .full
                ))
            }
            _ = try await store.append(batch, enqueueForSync: false, nowMs: startMs)
        }
        #expect(try await store.totalPointCount() == total)

        let fullYearEnd = startMs + Int64(total) * 300_000

        // Single-pass FULL YEAR (100k points) timeline query + exact summary + strict 4000-point render budget
        let clock = ContinuousClock()
        let elapsed = try await clock.measure {
            let payload = try await store.timelinePayload(fromMs: startMs, toMs: fullYearEnd, maxTotalPoints: 4000)
            #expect(payload.summary.pointCount == total)
            #expect(payload.summary.segmentCount == total / 200)
            let renderedPoints = payload.segments.reduce(0) { $0 + $1.points.count }
            #expect(renderedPoints <= 4000)
            #expect(renderedPoints > 0)
        }
        #expect(elapsed < .milliseconds(200))
    }
}