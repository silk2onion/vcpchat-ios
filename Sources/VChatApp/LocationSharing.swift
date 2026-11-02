import Foundation
import CoreLocation
import Observation
import VChatCore

/// Core Location requires the creating thread's live RunLoop. Only this thin
/// adapter is MainActor-isolated; requests and token parsing stay in their actors.
@MainActor @Observable final class DeviceLocationService: NSObject, @preconcurrency CLLocationManagerDelegate {
    private(set) var snapshot: LocationSnapshot?
    private(set) var availability: LocationAvailability = .notAuthorized
    private(set) var locating = false
    private(set) var foreground = true
    @ObservationIgnored private var manager: CLLocationManager?
    @ObservationIgnored private var wanted = false
    @ObservationIgnored private var inFlight: (UUID, Task<LocationSnapshot?,Never>)?
    @ObservationIgnored private var reply: CheckedContinuation<LocationSnapshot?,Never>?
    @ObservationIgnored private var deadline: Task<Void,Never>?
    @ObservationIgnored private var permissionReplies: [CheckedContinuation<Bool,Never>] = []
    init(manager: CLLocationManager? = nil) {
        self.manager = manager
        super.init()
        manager?.delegate = self
    }
    var device: String {
        #if os(iOS)
        "iPhone"
        #else
        "Mac"
        #endif
    }
    var statusText: String {
        if locating { return "正在获取位置…" }
        if availability == .available, let snapshot, snapshot.fresh() { return snapshot.precise ? "位置已更新 · 约 \(Int(snapshot.accuracyMeters.rounded(.up))) 米" : "大致位置已更新" }
        switch availability {
        case .available: return "位置需要更新"
        case .notAuthorized: return "尚未授权位置"
        case .denied: return "系统未允许定位"
        case .restricted: return "定位受系统限制"
        case .background: return "回到前台后更新位置"
        case .unavailable: return "暂时无法获取位置"
        }
    }
    private func locationManager() -> CLLocationManager {
        if let manager { return manager }
        let manager = CLLocationManager(); self.manager = manager
        manager.desiredAccuracy = kCLLocationAccuracyNearestTenMeters
        manager.delegate = self
        return manager
    }
    func authorize() {
        guard foreground else { return }
        wanted = true
        let manager = locationManager()
        if manager.authorizationStatus == .notDetermined { manager.requestWhenInUseAuthorization() }
        else { updateAuthorization(manager); if availability == .available { Task { await refresh() } } }
    }
    func requestUserLocation() async -> LocationSnapshot? {
        guard foreground else { return nil }
        let manager = locationManager()
        if manager.authorizationStatus == .notDetermined {
            wanted = true
            let allowed = await withCheckedContinuation { continuation in
                permissionReplies.append(continuation)
                if permissionReplies.count == 1 { manager.requestWhenInUseAuthorization() }
            }
            guard allowed else { return nil }
        }
        return await refresh(force: true)
    }
    private func resolvePermission(_ allowed: Bool) {
        let replies = permissionReplies; permissionReplies = []
        for reply in replies { reply.resume(returning: allowed) }
    }
    private func updateAuthorization(_ manager: CLLocationManager) {
        switch manager.authorizationStatus {
        case .authorizedAlways, .authorizedWhenInUse:
            if let snapshot, snapshot.precise != (manager.accuracyAuthorization == .fullAccuracy) { self.snapshot = nil }
            availability = foreground ? .available : .background
        case .denied: availability = .denied; snapshot = nil
        case .restricted: availability = .restricted; snapshot = nil
        case .notDetermined: availability = .notAuthorized
        @unknown default: availability = .unavailable; snapshot = nil
        }
    }
    func refresh(force: Bool = false) async -> LocationSnapshot? {
        guard foreground else { availability = .background; return nil }
        wanted = true
        let manager = locationManager(); updateAuthorization(manager)
        guard availability == .available else { return nil }
        if !force, let snapshot, snapshot.fresh() { return snapshot }
        if let inFlight { return await inFlight.1.value }
        let id = UUID()
        let task = Task<LocationSnapshot?,Never> { @MainActor in
            guard foreground,!Task.isCancelled else { return nil }
            return await withCheckedContinuation { continuation in
                reply = continuation; locating = true
                manager.requestLocation()
                deadline = Task { @MainActor in
                    do { try await Task.sleep(for: .seconds(4)) } catch { return }
                    finish(nil,status: .unavailable)
                }
            }
        }
        inFlight = (id,task)
        let value = await task.value
        if inFlight?.0 == id { inFlight = nil }
        return value
    }
    private func finish(_ value: LocationSnapshot?,status: LocationAvailability) {
        deadline?.cancel(); deadline = nil; manager?.stopUpdatingLocation()
        locating = false; availability = status; wanted = false
        if let value { snapshot = value }
        let continuation = reply; reply = nil; continuation?.resume(returning: value)
    }
    func clear() { inFlight?.1.cancel(); inFlight = nil; snapshot = nil; finish(nil,status: .notAuthorized); resolvePermission(false) }
    func setForeground(_ active: Bool) {
        foreground = active
        if !active { inFlight?.1.cancel(); inFlight = nil; finish(nil,status: .background); resolvePermission(false) }
        else if let manager { updateAuthorization(manager) }
    }
    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        updateAuthorization(manager)
        if availability != .notAuthorized { resolvePermission(availability == .available) }
        if availability == .available { if wanted { Task { await refresh() } } }
        else if availability != .notAuthorized { finish(nil,status: availability) }
    }
    func locationManager(_ manager: CLLocationManager,didUpdateLocations locations: [CLLocation]) {
        guard foreground, reply != nil else { return }
        let precise = manager.accuracyAuthorization == .fullAccuracy
        let candidate = locations.map { LocationSnapshot(latitude: $0.coordinate.latitude,longitude: $0.coordinate.longitude,accuracyMeters: $0.horizontalAccuracy,measuredAt: $0.timestamp.timeIntervalSince1970,precise: precise) }.filter { $0.fresh() }.max { $0.measuredAt < $1.measuredAt }
        guard let candidate else { return } // Wait for a fresh fix until the deadline.
        finish(candidate,status: .available)
    }
    func locationManager(_ manager: CLLocationManager,didFailWithError error: any Error) {
        guard reply != nil else { return }
        updateAuthorization(manager)
        finish(nil,status: availability == .available ? .unavailable : availability)
    }
}

extension ChatViewModel {
    var locationEnabledInChat: Bool {
        guard let room else { return false }
        if room.locationPreference == .include { return true }
        if room.locationPreference == .omit { return false }
        if let group = activeGroup { return group.memberIds.contains { locationSettings.shares(with: $0) } }
        return activeAgent.map { locationSettings.shares(with: $0.id) } ?? false
    }
    func prefetchLocation() {
        guard !backgrounded,locationEnabledInChat else { return }
        Task { await location.refresh() }
    }
    func locationForeground(_ active: Bool) {
        location.setForeground(active)
        if active { prefetchLocation() }
    }
    func setLocationSharing(_ enabled: Bool) {
        locationSettings.enabled = enabled
        if enabled {
            if locationSettings.agentIDs.isEmpty,let mainAgent { locationSettings.agentIDs.insert(mainAgent.id) }
            location.authorize()
        } else {
            for room in rooms.values { room.locationPreference = .automatic }
            location.clear()
        }
    }
    func includeLocationOnce() {
        guard let room,!room.busy else { return }
        room.locationPreference = .include; location.authorize(); prefetchLocation()
    }
    func omitLocationOnce() { guard let room,!room.busy else { return }; room.locationPreference = .omit }
    func saveLocationSettings() async {
        do { try await store?.put(locationSettings,kind: "location-options",id: "sharing") }
        catch { self.error = error.localizedDescription }
    }
    func prepareLocation(for agents: [VCPAgent],preference: LocationMessagePreference) async -> LocationRequestContext? {
        let settings = locationSettings
        let revision = locationSettingsRevision
        guard agents.contains(where: { settings.shares(with: $0.id,preference: preference) }) else { return nil }
        let snapshot = await location.refresh()
        // A permission/settings change while waiting also revokes saved-place
        // facts, not just the GPS coordinate. Send the message without context.
        guard revision == locationSettingsRevision else { return nil }
        return LocationRequestContext(snapshot: snapshot,availability: location.availability,settings: settings,device: location.device)
    }
}
