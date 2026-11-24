import CoreLocation
import Foundation
import Testing
@testable import VChatApp
import VChatCore

// The fake never starts an OS service, prompts for access, or writes real preferences.
private final class Manager: CLLocationManager {
    var status = CLAuthorizationStatus.authorizedAlways
    var precision = CLAccuracyAuthorization.fullAccuracy
    var starts = 0, stops = 0, slcStops = 0, prompts = 0, seedReads = 0
    var backgroundAllowed = true
    override var authorizationStatus: CLAuthorizationStatus { status }
    override var accuracyAuthorization: CLAccuracyAuthorization { precision }
    override var location: CLLocation? { seedReads += 1; return CLLocation(latitude: 8, longitude: 9) }
    override var allowsBackgroundLocationUpdates: Bool {
        get { backgroundAllowed }
        set { backgroundAllowed = newValue }
    }
    override func requestWhenInUseAuthorization() { prompts += 1 }
    override func startUpdatingLocation() { starts += 1 }
    override func stopUpdatingLocation() { stops += 1 }
    override func stopMonitoringSignificantLocationChanges() { slcStops += 1 }
}
private final class MemoryDefaults: UserDefaults {
    var bytes: [String: Data] = [:]
    override func set(_ value: Any?, forKey key: String) { bytes[key] = value as? Data }
    override func data(forKey key: String) -> Data? { bytes[key] }
    override func removeObject(forKey key: String) { bytes.removeValue(forKey: key) }
}
@MainActor private final class Fixture {
    var time = Date().timeIntervalSince1970
    let defaults = MemoryDefaults()
    var managers: [Manager] = []
    lazy var service = DeviceLocationService(defaults: defaults, makeManager: { [unowned self] in
        let m = Manager()
        if let authority = self.managers.first { m.precision = authority.precision; m.status = authority.status }
        self.managers.append(m); return m
    }, now: { [unowned self] in self.time }, captureBudget: .milliseconds(120))
    func point(_ error: Double, age: Double = 0) -> CLLocation {
        CLLocation(coordinate: .init(latitude: 52, longitude: -1), altitude: 0,
                   horizontalAccuracy: error, verticalAccuracy: 0, timestamp: Date(timeIntervalSince1970: time - age))
    }
    func wait(for count: Int) async throws {
        for _ in 0..<1000 {
            if service.activeDemandCount == count { return }
            await Task.yield()
        }
        throw ClientError.timeout
    }
}

@MainActor struct LocationSharingTests {
    private struct WireBody: Decodable { let messages: [ChatTurn] }

    @Test func backgroundBodyRechecksRecipientAtSubmission() async throws {
        let f = Fixture(), model = ChatViewModel(location: f.service)
        let alice = VCPAgent(id: "a", name: "A")
        model.locationSettings.enabled = true
        model.locationSettings.agentIDs = [alice.id]
        f.service.setContinuous(true)
        let run = try #require(f.managers.last)
        f.time += 2
        f.service.locationManager(run, didUpdateLocations: [f.point(5)])
        let context = try #require(await model.prepareLocation(for: [alice], preference: .automatic, group: nil))
        let turns = [ChatTurn(role: "system", content: "agent rules"), ChatTurn(role: "user", content: "hi")]
        let request = ChatRequest(configuration: .init(server: "https://example.invalid", model: "fixture"), apiKey: "fixture", messages: turns)
        let resolve: ChatRequest.LocationText = { try model.outboundLocation(context, for: alice.id, preference: .automatic) }
        func body() async throws -> [ChatTurn] {
            let call = try await request.urlRequest(streaming: true, locationText: resolve)
            return try JSONDecoder().decode(WireBody.self, from: #require(call.httpBody)).messages
        }
        let allowed = try await body()
        #expect(allowed.count == 2 && allowed[0].content.hasPrefix("agent rules\n\n"))
        #expect(allowed[0].content.contains("\"latitude\"") && allowed[1] == turns[1])
        model.locationSettings.agentIDs.removeAll()
        let revoked = try await body()
        #expect(revoked == [ChatTurn(role: "system", content: "agent rules\n\n" + LocationRequestContext.omittedTray), turns[1]])
        #expect(request.messages == turns)
    }

    @Test func backgroundBodyPreservesMultipartSystemAndNilLocation() async throws {
        var first = ChatTurn(role: "system", content: "keep")
        first.parts = [.text("keep"), .image("https://example.invalid/picture")]
        let request = ChatRequest(configuration: .init(server: "https://example.invalid", model: "fixture"), apiKey: "fixture", messages: [first])
        let added = try await request.urlRequest(streaming: true, locationText: { "location" })
        let plain = try await request.urlRequest(streaming: true, locationText: { nil })
        let decoder = JSONDecoder()
        #expect(try decoder.decode(WireBody.self, from: #require(added.httpBody)).messages == [ChatTurn(role: "system", content: "location"), first])
        #expect(try decoder.decode(WireBody.self, from: #require(plain.httpBody)).messages == [first])
    }

    @Test func downgradeRetiresRunCacheAndOutboundContext() async throws {
        let f = Fixture(), alice = VCPAgent(id: "a", name: "A"), bob = VCPAgent(id: "b", name: "B")
        let s = f.service, model = ChatViewModel(location: s)
        let group = VCPGroup(name: "test", memberIds: ["a","b"]); model.groups = [group]
        model.locationSettings.enabled = true; model.locationSettings.agentIDs = ["a"]
        let empty = await model.prepareLocation(for: [bob], preference: .include, group: group)
        #expect(empty == nil)
        s.setContinuous(true)
        let old = try #require(f.managers.last)
        f.time += 2
        s.locationManager(old, didUpdateLocations: [f.point(5)])
        let context = try #require(await model.prepareLocation(for: [alice,bob], preference: .include, group: group))
        #expect(try model.outboundLocation(context, for: "a", preference: .include)?.contains("\"latitude\"") == true)
        #expect(try model.outboundLocation(context, for: "b", preference: .include) == nil)
        #expect(try model.outboundLocation(context, for: "a", preference: .omit)?.contains("\"latitude\"") == false)
        model.groups = []
        #expect(try model.outboundLocation(context, for: "a", preference: .include) == LocationRequestContext.omittedTray)
        model.groups = [group]
        let pending = Task { await s.requestUserLocation() }; try await f.wait(for: 1)
        f.time += 10
        f.managers[0].precision = .reducedAccuracy
        // No delegate notification yet: the HTTP body check must see the live system grant.
        let stripped = try model.outboundLocation(context, for: "a", preference: .automatic)
        #expect(stripped?.contains("\"latitude\"") == false)
        #expect(stripped?.contains("\"omitted\"") == true)
        #expect(await pending.value == nil)
        #expect(s.snapshot == nil && f.defaults.data(forKey: DeviceLocationService.cacheDefaultsKey) == nil)
        let next = try #require(f.managers.last)
        s.locationManager(old, didUpdateLocations: [f.point(5)])
        s.locationManager(next, didUpdateLocations: [f.point(5, age: 1)])
        #expect(s.snapshot == nil)
        f.time += 2
        s.locationManager(next, didUpdateLocations: [f.point(2400)])
        #expect(s.snapshot?.precise == false && s.snapshot?.accuracyMeters == 2400)
        f.managers[0].precision = .fullAccuracy; s.locationManagerDidChangeAuthorization(f.managers[0])
        #expect(s.snapshot == nil && f.managers.allSatisfy { $0.seedReads == 0 })
    }

    @Test func removingLastRecipientStopsAutomaticSamplingButNotLocalCapture() async throws {
        let f = Fixture(), s = f.service, model = ChatViewModel(location: s)
        let a = VCPAgent(id: "a", name: "A")
        let topic = ChatTopic(id: "legacy", ownerId: a.id, title: "test")
        model.agents = [a]; model.topics = [topic]; model.rooms[topic.id] = ChatRoom(id: topic.id, messages: [])
        model.locationSettings.enabled = true
        #expect(!s.locating)
        model.locationSettings.agentIDs = ["a"]
        let run = try #require(f.managers.last)
        #expect(run.starts == 1)
        let save = Task { await s.captureFreshPoint() }
        try await f.wait(for: 1)
        model.locationSettings.agentIDs.removeAll()
        #expect(s.locating && run.stops == 0)
        save.cancel()
        guard case .unavailable = await save.value else { Issue.record("cancelled save returned a point"); return }
        #expect(!s.locating && run.stops == 1)
        let empty = await model.prepareLocation(for: [a], preference: .automatic, group: nil)
        #expect(empty == nil && f.managers.count == 2)
    }

    @Test func noNewReadingEvenWithRecentCacheNeedsConfirmation() async throws {
        let f = Fixture(), s = f.service
        s.setContinuous(true); f.time += 1
        let run = try #require(f.managers.last)
        s.locationManager(run, didUpdateLocations: [f.point(5)])
        s.setContinuous(false)
        guard case .confirm(let fix) = await s.captureFreshPoint() else {
            Issue.record("timeout silently promoted a cached point"); return
        }
        #expect(fix.point.accuracyMeters == 5 && !s.locating)
    }

    @Test func independentWaitersFilterBatchAndStopAfterLastDemand() async throws {
        let f = Fixture(), s = f.service
        let save = Task { await s.captureFreshPoint() }, chat = Task { await s.refresh() }
        try await f.wait(for: 2)
        let run = try #require(f.managers.last)
        f.time += 5
        s.locationManager(run, didUpdateLocations: [f.point(80, age: 1), f.point(2000)])
        let accepted = await chat.value
        #expect(accepted?.point == s.snapshot && accepted?.point.accuracyMeters == 80)
        #expect(run.starts == 1 && run.stops == 0 && s.activeDemandCount == 1)
        f.time += 1
        s.locationManager(run, didUpdateLocations: [f.point(20)])
        guard case .ready(let fix) = await save.value else { Issue.record("missing strict fix"); return }
        #expect(fix.point == s.snapshot && run.stops == 1)
    }

    @Test func oldFixNeedsConsentAndBackgroundRetiresEvenAlways() async throws {
        let f = Fixture(), s = f.service
        s.setContinuous(true)
        let run = try #require(f.managers.last)
        f.time += 1; s.locationManager(run, didUpdateLocations: [f.point(5)])
        f.time += 120
        let capture = Task { await s.captureFreshPoint() }, refresh = Task { await s.refresh() }
        try await f.wait(for: 2)
        guard case .confirm(let fix) = await capture.value else { Issue.record("silently accepted old point"); return }
        #expect(fix.point.ageSeconds(at: f.time) == 120)
        #expect(s.activeDemandCount == 1)
        s.setForeground(false)
        #expect(await refresh.value == nil)
        #expect(run.stops == 1 && run.slcStops == 1 && !run.backgroundAllowed)
        let count = f.managers.count
        s.locationManagerDidChangeAuthorization(f.managers[0])
        s.setContinuous(true)
        s.locationManager(run, didUpdateLocations: [f.point(2)])
        #expect(f.managers.count == count && !s.locating && s.snapshot == fix.point)
    }
}
