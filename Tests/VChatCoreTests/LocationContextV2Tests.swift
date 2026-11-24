import Foundation
import Testing
@testable import VChatCore

@Suite("LocationContext v2.0 TTL & Zero-Unavailable Degradation")
struct LocationContextV2Tests {
    private func extractDeviceLocationJSON(from tray: String) throws -> JSONValue {
        let lines = tray.split(separator: "\n", omittingEmptySubsequences: true)
        guard let jsonLine = lines.first(where: { $0.hasPrefix("{") && $0.hasSuffix("}") }) else {
            throw ClientError.invalidResponse
        }
        return try JSONDecoder().decode(JSONValue.self, from: Data(jsonLine.utf8))
    }

    @Test("Fresh fix within 60s reports available with stale=false and sensor telemetry")
    func freshSnapshotReportsNonStale() throws {
        let now = 1_795_000_100.0
        let snap = LocationSnapshot(
            latitude: 52.954589,
            longitude: -1.160351,
            accuracyMeters: 6.2,
            measuredAt: now - 12,
            precise: true,
            speedMps: 1.346,
            courseDegrees: 248.44
        )
        var settings = LocationSharingSettings()
        settings.enabled = true
        settings.agentIDs = ["amadeus"]

        let ctx = LocationRequestContext(snapshot: snap, availability: .available, settings: settings, device: "iPhone").forAgent("amadeus")
        let payload = try extractDeviceLocationJSON(from: ctx.tray(at: now))

        #expect(payload["type"].text == "device_location")
        #expect(payload["schema_version"].number == 2)
        #expect(payload["status"].text == "available")
        #expect(payload["stale"].bool == false)
        #expect(payload["age_sec"].number == 12)
        #expect(payload["speed_mps"].number == 1.35)
        #expect(payload["course_deg"].number == 248.4)
    }

    @Test("Transient GPS loss or background suspension within 15m TTL never flaps to unavailable")
    func ttlFallbackPreventsUnavailableFlapping() throws {
        let now = 1_795_001_000.0
        let snap = LocationSnapshot(
            latitude: 52.954589,
            longitude: -1.160351,
            accuracyMeters: 8.5,
            measuredAt: now - 420,
            precise: true
        )
        var settings = LocationSharingSettings()
        settings.enabled = true
        settings.agentIDs = ["amadeus"]

        for transientState in [LocationAvailability.unavailable, .background, .available] {
            let ctx = LocationRequestContext(snapshot: snap, availability: transientState, settings: settings, device: "iPhone").forAgent("amadeus")
            let payload = try extractDeviceLocationJSON(from: ctx.tray(at: now))
            #expect(payload["status"].text == "available")
            #expect(payload["stale"].bool == true)
            #expect(payload["age_sec"].number == 420)
            #expect(payload["latitude"].number == 52.954589)
        }
    }

    @Test("Snapshot older than 15m TTL honestly degrades to unavailable")
    func expiredBeyondFifteenMinutesDegradesToUnavailable() throws {
        let now = 1_795_002_000.0
        let expired = LocationSnapshot(
            latitude: 52.954589,
            longitude: -1.160351,
            accuracyMeters: 7.0,
            measuredAt: now - 901,
            precise: true
        )
        let ctx = LocationRequestContext(snapshot: expired, availability: .unavailable, settings: .init(), device: "iPhone", recipients: ["amadeus"]).forAgent("amadeus")
        let payload = try extractDeviceLocationJSON(from: ctx.tray(at: now))

        #expect(payload["status"].text == "unavailable")
        #expect(payload["latitude"] == .null)
        #expect(payload["stale"] == .null)
    }

    @Test("Revoked permission or explicit omit never leaks cached coordinates")
    func permissionDeniedBlocksCachedSnapshot() throws {
        let now = 1_795_003_000.0
        let fresh = LocationSnapshot(latitude: 52.95, longitude: -1.16, accuracyMeters: 5, measuredAt: now - 5, precise: true)
        let deniedCtx = LocationRequestContext(snapshot: fresh, availability: .denied, settings: .init(), device: "iPhone", recipients: ["amadeus"]).forAgent("amadeus")
        let payload = try extractDeviceLocationJSON(from: deniedCtx.tray(at: now))

        #expect(payload["status"].text == "denied")
        #expect(payload["latitude"] == .null)

        let omitted = try extractDeviceLocationJSON(from: LocationRequestContext.omittedTray)
        #expect(omitted["status"].text == "omitted")
        #expect(omitted["latitude"] == .null)
    }

    @Test("One message can share a coordinate, never a place outside the recipient ACL")
    func recipientBoundary() throws {
        let now = 1_795_004_000.0
        let point = LocationSnapshot(latitude: 52, longitude: -1, accuracyMeters: 5, measuredAt: now, precise: true)
        var settings = LocationSharingSettings()
        settings.enabled = true
        settings.places = [LocationPlace(name: "private-home", coordinate: point),
                           LocationPlace(name: "shared-station", coordinate: point, sharedAgentIDs: ["alice"])]
        #expect(!settings.shares(with: "alice"))
        #expect(settings.shares(with: "bob", preference: .include))
        #expect(!settings.shares(with: "bob", preference: .include, inGroup: true))
        let empty = LocationRequestContext(snapshot: point, availability: .available, settings: settings, device: "iPhone")
        #expect(try empty.forAgent("alice").tray(at: now) == LocationRequestContext.omittedTray)
        settings.agentIDs = ["alice"]
        #expect(settings.shares(with: "alice", preference: .include, inGroup: true))
        #expect(!settings.shares(with: "alice", preference: .omit))
        let ctx = LocationRequestContext(snapshot: point, availability: .available, settings: settings, device: "iPhone")
        let alice = try extractDeviceLocationJSON(from: ctx.forAgent("alice").tray(at: now))
        let bob = try extractDeviceLocationJSON(from: ctx.forAgent("bob").tray(at: now))
        #expect(alice["saved_places"].array.map { $0["name"].text } == ["shared-station"])
        #expect(bob["status"].text == "omitted")
        let single = LocationRequestContext(snapshot: point, availability: .available, settings: settings,
                                            device: "iPhone", recipients: ["bob"])
        let once = try extractDeviceLocationJSON(from: single.forAgent("bob").tray(at: now))
        #expect(once["latitude"].number == point.latitude && once["saved_places"] == .null)
        #expect(bob["saved_places"] == .null)
        #expect(bob["near_saved_places"] == .null)
    }
}
