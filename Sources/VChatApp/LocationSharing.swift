import Foundation
import CoreLocation
import Observation
import VChatCore

struct MeasuredLocation {
    let point: LocationSnapshot
    let generation: UUID
    let fromCurrentDelivery: Bool

    func readyToSave(at now: Double) -> Bool {
        fromCurrentDelivery && point.precise && (0...10).contains(now - point.measuredAt) && point.accuracyMeters <= 20
    }
}

enum PlaceCapture {
    case ready(MeasuredLocation), confirm(MeasuredLocation), unavailable
}

/// One foreground sampler for all demands, with independent deadlines and cancellation.
/// A new manager for each sampling run identifies callbacks still queued by a retired run.
@MainActor @Observable final class DeviceLocationService: NSObject, @preconcurrency CLLocationManagerDelegate {
    private struct Grant: Equatable, Codable {
        let status: Int32
        let precise: Bool
    }
    private struct Cache: Codable { let grant: Grant; let point: LocationSnapshot }
    private enum Purpose { case chat, update, place }
    private struct Demand {
        let purpose: Purpose
        let continuation: CheckedContinuation<MeasuredLocation?, Never>
        let budget: Duration
        var deadline: Task<Void, Never>?
    }

    static let cacheDefaultsKey = "vchat.location.foreground.v3"
    private(set) var snapshot: LocationSnapshot?
    private(set) var availability: LocationAvailability = .notAuthorized
    private(set) var foreground = true
    private(set) var generation = UUID()
    private(set) var locating = false
    @ObservationIgnored private var grant: Grant?
    @ObservationIgnored private var samplingSince = 0.0
    @ObservationIgnored private var continuous = false
    @ObservationIgnored private var demands: [UUID: Demand] = [:]
    @ObservationIgnored private var requestedPermission = false
    @ObservationIgnored private var sampler: CLLocationManager?
    @ObservationIgnored private let authority: CLLocationManager
    @ObservationIgnored private let makeManager: () -> CLLocationManager
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let now: () -> Double
    @ObservationIgnored private let captureBudget: Duration

    init(defaults: UserDefaults = .standard, makeManager: @escaping () -> CLLocationManager = { CLLocationManager() },
         now: @escaping () -> Double = { Date().timeIntervalSince1970 }, captureBudget: Duration = .seconds(8)) {
        self.defaults = defaults; self.makeManager = makeManager; self.now = now
        self.captureBudget = captureBudget; authority = makeManager()
        super.init()
        // v2 could persist an originally precise fix relabelled as reduced.
        defaults.removeObject(forKey: "vchat.location.last-known.v2")
        stopLegacyServices(authority)
        authority.delegate = self
        syncGrant()
    }

    var device: String {
        #if os(iOS)
        "iPhone"
        #else
        "Mac"
        #endif
    }
    var statusText: String {
        if let point = snapshot, point.withinTTL(at: now()) {
            return "\(point.fresh(at: now()) ? "最近位置" : "缓存位置") · \(Int(point.ageSeconds(at: now()))) 秒前 · \(point.precise ? "约 \(Int(point.accuracyMeters)) 米" : "大致位置")"
        }
        if locating { return "正在获取位置…" }
        switch availability {
        case .denied: return "系统未允许定位"
        case .restricted: return "定位受系统限制"
        case .notAuthorized: return "尚未授权位置"
        case .background: return "后台已停止定位"
        default: return "暂无可用位置"
        }
    }

    private func stopLegacyServices(_ manager: CLLocationManager) {
        manager.stopUpdatingLocation()
        manager.stopMonitoringSignificantLocationChanges()
        if manager.allowsBackgroundLocationUpdates { manager.allowsBackgroundLocationUpdates = false }
    }

    private func persistSnapshot(_ point: LocationSnapshot?) {
        snapshot = point
        if let point, let grant, let data = try? JSONEncoder().encode(Cache(grant: grant, point: point)) {
            defaults.set(data, forKey: Self.cacheDefaultsKey)
        } else { defaults.removeObject(forKey: Self.cacheDefaultsKey) }
    }
    private var authorized: Bool {
        #if os(iOS)
        return authority.authorizationStatus == .authorizedAlways || authority.authorizationStatus == .authorizedWhenInUse
        #else
        return authority.authorizationStatus == .authorizedAlways
        #endif
    }

    @discardableResult func syncGrant() -> UUID {
        let status = authority.authorizationStatus
        let next = Grant(status: status.rawValue, precise: authority.accuracyAuthorization == .fullAccuracy)
        guard grant != next else { return generation }
        let previous = grant
        grant = next; generation = UUID()
        stopSampler()
        if previous == nil, authorized, let data = defaults.data(forKey: Self.cacheDefaultsKey),
           let cache = try? JSONDecoder().decode(Cache.self, from: data), cache.grant == next,
           cache.point.precise == next.precise, cache.point.withinTTL(at: now()) {
            snapshot = cache.point
        } else { persistSnapshot(nil) }
        // A first grant starts waiting demands; no old authorized fix exists to invalidate.
        if previous?.status != CLAuthorizationStatus.notDetermined.rawValue || !authorized {
            finishAll()
        } else {
            for (id, demand) in demands { armDeadline(id, after: demand.budget) }
        }
        if status != .notDetermined { requestedPermission = false }
        switch status {
        case .denied: availability = .denied
        case .restricted: availability = .restricted
        default: availability = authorized ? (foreground ? .available : .background) : .notAuthorized
        }
        reconcile()
        return generation
    }

    private func stopSampler() {
        guard let old = sampler else { return }
        sampler = nil; old.delegate = nil; stopLegacyServices(old); locating = false
    }

    private func reconcile() {
        guard foreground, continuous || !demands.isEmpty else { stopSampler(); requestedPermission = false; return }
        if authority.authorizationStatus == .notDetermined {
            if !requestedPermission { requestedPermission = true; authority.requestWhenInUseAuthorization() }
            return
        }
        guard authorized, sampler == nil else { return }
        let manager = makeManager()
        manager.desiredAccuracy = kCLLocationAccuracyNearestTenMeters
        manager.distanceFilter = demands.isEmpty ? 25 : kCLDistanceFilterNone
        samplingSince = now()
        sampler = manager; manager.delegate = self; locating = true
        manager.startUpdatingLocation()
    }

    var activeDemandCount: Int { demands.count }
    func cancelChatDemands() {
        for (id, demand) in demands where demand.purpose == .chat { finish(id, with: nil) }
        adjustSampler()
    }
    func setContinuous(_ required: Bool) {
        continuous = required
        syncGrant(); reconcile()
    }
    func setForeground(_ active: Bool) {
        foreground = active
        if !active {
            continuous = false; finishAll(); stopSampler(); stopLegacyServices(authority)
        }
        syncGrant()
        if authorized { availability = active ? .available : .background }
    }
    func clearChatCache() {
        continuous = false
        cancelChatDemands()
        persistSnapshot(nil)
    }
    private func accepted() -> MeasuredLocation? {
        guard authorized, let snapshot, snapshot.withinTTL(at: now()) else { return nil }
        return .init(point: snapshot, generation: generation, fromCurrentDelivery: false)
    }
    func current(_ fix: MeasuredLocation) -> Bool {
        syncGrant() == fix.generation && authorized && fix.point.withinTTL(at: now())
    }
    private func finish(_ id: UUID, with value: MeasuredLocation?) {
        guard let demand = demands.removeValue(forKey: id) else { return }
        demand.deadline?.cancel(); demand.continuation.resume(returning: value)
    }
    private func finishAll() { for id in Array(demands.keys) { finish(id, with: nil) } }
    private func adjustSampler() {
        reconcile()
        sampler?.distanceFilter = demands.isEmpty ? 25 : kCLDistanceFilterNone
    }

    private func armDeadline(_ id: UUID, after budget: Duration) {
        demands[id]?.deadline?.cancel()
        demands[id]?.deadline = Task { @MainActor in
            do { try await Task.sleep(for: budget) } catch { return }
            syncGrant()
            guard !Task.isCancelled else { return } // a first grant just rearmed this demand
            finish(id, with: accepted()); adjustSampler()
        }
    }

    private func measure(_ purpose: Purpose) async -> MeasuredLocation? {
        syncGrant()
        guard !Task.isCancelled else { return nil }
        if purpose == .chat, let cached = accepted(), cached.point.fresh(at: now()) { return cached }
        guard foreground else { return purpose == .chat ? accepted() : nil }
        guard authorized || authority.authorizationStatus == .notDetermined else { return nil }
        let id = UUID()
        let budget: Duration = purpose == .place ? captureBudget :
            (purpose == .chat && accepted() != nil ? .milliseconds(1500) : .seconds(4))
        let value: MeasuredLocation? = await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                demands[id] = Demand(purpose: purpose, continuation: continuation, budget: budget)
                armDeadline(id, after: authorized ? budget : .seconds(60))
                adjustSampler()
            }
        } onCancel: {
            Task { @MainActor in self.finish(id, with: nil); self.adjustSampler() }
        }
        guard !Task.isCancelled, let value, current(value) else { return nil }
        return value
    }

    func refresh() async -> MeasuredLocation? { await measure(.chat) }
    func requestUserLocation() async -> MeasuredLocation? { await measure(.update) }
    func captureFreshPoint() async -> PlaceCapture {
        guard let fix = await measure(.place), current(fix) else { return .unavailable }
        return fix.readyToSave(at: now()) ? .ready(fix) : .confirm(fix)
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        guard manager === authority || manager === sampler else { return }
        syncGrant()
    }
    func acceptSharedLiveSensorReading(
        latitude: Double,
        longitude: Double,
        accuracyMeters: Double,
        measuredAt: Double,
        precise: Bool,
        speedMps: Double?,
        courseDegrees: Double?
    ) {
        syncGrant()
        guard sampler != nil, foreground, authorized, let grant, grant.precise == precise else { return }
        let point = LocationSnapshot(
            latitude: latitude,
            longitude: longitude,
            accuracyMeters: accuracyMeters,
            measuredAt: measuredAt,
            precise: grant.precise,
            speedMps: speedMps,
            courseDegrees: courseDegrees
        )
        evaluateDeliveredPoints([point])
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        syncGrant()
        guard manager === sampler, foreground, authorized, let grant,
              manager.accuracyAuthorization == authority.accuracyAuthorization else { return }
        let points = locations.map { item in
            LocationSnapshot(latitude: item.coordinate.latitude, longitude: item.coordinate.longitude,
                             accuracyMeters: item.horizontalAccuracy, measuredAt: item.timestamp.timeIntervalSince1970,
                             precise: grant.precise, speedMps: item.speed, courseDegrees: item.course)
        }
        evaluateDeliveredPoints(points)
    }

    private func evaluateDeliveredPoints(_ rawPoints: [LocationSnapshot]) {
        let time = now()
        let points = rawPoints.filter {
            $0.withinTTL(at: time) && $0.measuredAt >= samplingSince
                && $0.measuredAt <= time && (!$0.precise || $0.accuracyMeters <= 1000)
        }
        // Evaluate in measurement order so a bad last item cannot hide a good fix in the same batch.
        var best = snapshot
        for point in points.sorted(by: { $0.measuredAt < $1.measuredAt }) {
            if let old = best, old.withinTTL(at: time) {
                if point.measuredAt < old.measuredAt || (point.measuredAt == old.measuredAt && point.accuracyMeters >= old.accuracyMeters) { continue }
                if old.precise, old.accuracyMeters <= 20, (0...10).contains(time - old.measuredAt), point.accuracyMeters > 20 { continue }
                if old.fresh(at: time), point.accuracyMeters > max(20, old.accuracyMeters * 4),
                   point.measuredAt - old.measuredAt < 45 { continue }
            }
            best = point
        }
        guard let best, best != snapshot else { return }
        persistSnapshot(best); availability = .available
        let fix = MeasuredLocation(point: best, generation: generation, fromCurrentDelivery: true)
        for (id, demand) in demands {
            if demand.purpose == .place ? fix.readyToSave(at: time) : best.fresh(at: time) { finish(id, with: fix) }
        }
        adjustSampler()
    }
    func locationManager(_ manager: CLLocationManager, didFailWithError error: any Error) {
        syncGrant()
        guard manager === sampler else { return }
        if (error as? CLError)?.code == .locationUnknown { return }
        for id in Array(demands.keys) { finish(id, with: accepted()) }
        adjustSampler()
    }
}

struct PreparedLocation {
    let generation: UUID
    let revision: UUID
    let footprintHistoryGeneration: UUID
    let recipients: Set<String>
    let groupID: String?
    let context: LocationRequestContext
}

extension ChatViewModel {
    var locationEnabledInChat: Bool {
        guard let room else { return false }
        if let group = activeGroup {
            return group.memberIds.contains { locationSettings.shares(with: $0, preference: room.locationPreference, inGroup: true) }
        }
        return activeAgent.map { locationSettings.shares(with: $0.id, preference: room.locationPreference) } ?? false
    }

    func prefetchLocation() {
        let automatic = activeGroup.map { group in group.memberIds.contains { locationSettings.shares(with: $0) } }
            ?? (activeAgent.map { locationSettings.shares(with: $0.id) } ?? false)
        location.setContinuous(location.foreground && room != nil && room?.locationPreference != .omit && automatic)
    }
    func locationForeground(_ active: Bool) {
        locationCoordinator.markForegroundSceneActive(active)
        if active { prefetchLocation() }
    }
    func setLocationSharing(_ enabled: Bool) {
        if !enabled {
            for room in rooms.values { room.locationPreference = .automatic }
            location.clearChatCache()
        }
        locationSettings.enabled = enabled
    }
    func includeLocationOnce() {
        guard let room, !room.busy else { return }
        room.locationPreference = .include
        // Permission and the single demand belong to the send, not the lifetime of this draft.
        prefetchLocation()
    }
    func omitLocationOnce() {
        guard let room, !room.busy else { return }
        room.locationPreference = .omit; prefetchLocation()
    }

    @discardableResult func saveLocationSettings() async -> Bool {
        do { try await store?.put(locationSettings, kind: "location-options", id: "sharing"); return true }
        catch { self.error = error.localizedDescription; return false }
    }
    @discardableResult func saveLocationPlace(_ place: LocationPlace) async -> Bool {
        var next = locationSettings
        if let index = next.places.firstIndex(where: { $0.id == place.id }) { next.places[index] = place }
        else { next.places.append(place) }
        return await persistLocationSettings(next)
    }
    @discardableResult func removeLocationPlace(_ id: String) async -> Bool {
        var next = locationSettings; next.places.removeAll { $0.id == id }
        return await persistLocationSettings(next)
    }
    func persistLocationSettings(_ next: LocationSharingSettings) async -> Bool {
        do {
            guard let store else { throw ClientError.server("本机数据尚未就绪，请稍后重试") }
            try await store.put(next, kind: "location-options", id: "sharing")
            locationSettings = next; return true
        } catch { self.error = error.localizedDescription; return false }
    }

    func prepareLocation(for agents: [VCPAgent], preference: LocationMessagePreference, group: VCPGroup?) async -> PreparedLocation? {
        let settings = locationSettings, revision = locationSettingsRevision
        let recipients = Set(agents.map(\.id).filter { settings.shares(with: $0, preference: preference, inGroup: group != nil) && (group?.memberIds.contains($0) ?? true) })
        guard !recipients.isEmpty else { return nil }
        // Only agents on the persistent allowlist (when sharing is enabled and not omitted) may receive historical footprint semantics.
        let semanticRecipients: Set<String> = (preference != .omit && settings.enabled)
            ? recipients.intersection(settings.agentIDs)
            : []
        let initial = location.syncGrant()
        let fix = await location.refresh()
        let tracker = locationCoordinator.footprintTracker
        let initialFootprintGen = tracker.footprintHistoryGeneration
        let clearingAtStart = tracker.isClearingHistory
        let recentWindow = clearingAtStart ? [] : await locationCoordinator.recentPrecisePointsForChatSemantics(
            chatSnapshot: fix?.point,
            semanticRecipients: semanticRecipients
        )
        let footprintGenMatches = !clearingAtStart
            && !tracker.isClearingHistory
            && (tracker.footprintHistoryGeneration == initialFootprintGen)
        let liveDwellEvidence: FootprintLiveDwellEvidence? = (
            footprintGenMatches && !semanticRecipients.isEmpty && location.foreground && fix?.point.precise == true
        ) ? tracker.liveDwellEvidence : nil
        let generation = location.syncGrant()
        guard revision == locationSettingsRevision, (fix?.generation ?? initial) == generation, !Task.isCancelled else { return nil }
        return PreparedLocation(
            generation: generation,
            revision: revision,
            footprintHistoryGeneration: initialFootprintGen,
            recipients: recipients,
            groupID: group?.id,
            context: LocationRequestContext(
                snapshot: fix?.point,
                availability: location.availability,
                settings: settings,
                device: location.device,
                recipients: recipients,
                semanticRecipients: semanticRecipients,
                recentFootprintPoints: footprintGenMatches ? recentWindow : [],
                liveDwellEvidence: liveDwellEvidence
            )
        )
    }

    /// Resolved by the transport immediately before serializing each HTTP body,
    /// after request building, database writes and earlier group speakers.
    func outboundLocation(_ prepared: PreparedLocation?, for id: String, preference: LocationMessagePreference) throws -> String? {
        if let groupID = prepared?.groupID, !groups.contains(where: { $0.id == groupID && $0.memberIds.contains(id) }) {
            return LocationRequestContext.omittedTray
        }
        if preference != .omit, let prepared, prepared.recipients.contains(id), prepared.revision == locationSettingsRevision,
           prepared.generation == location.syncGrant() {
            let tracker = locationCoordinator.footprintTracker
            let allowSemantics = location.foreground
                && !tracker.isClearingHistory
                && prepared.footprintHistoryGeneration == tracker.footprintHistoryGeneration
            let scoped = prepared.context.forAgent(id, allowSemantics: allowSemantics)
            return scoped.policy + "\n\n" + (try scoped.tray())
        }
        if locationSettings.shares(with: id) {
            return LocationRequestContext.policy(settings: locationSettings, agentID: id) + "\n\n" + LocationRequestContext.omittedTray
        }
        return preference == .omit || prepared?.recipients.contains(id) == true ? LocationRequestContext.omittedTray : nil
    }
}
