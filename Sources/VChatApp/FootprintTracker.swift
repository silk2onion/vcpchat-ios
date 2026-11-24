import CoreLocation
import Foundation
import Observation
import VChatCore
#if os(iOS)
import UIKit
#endif

public enum BackgroundRestoreOutcome: Sendable, Equatable {
    case skippedDisabled
    case skippedAuthorizationNotAlways
    case skippedNoRecoverableSession
    case deferredUntilFirstUnlock
    case failedStorageError(String)
    case restored(FootprintTrackingMode)
}

public enum FootprintLiveStreamEvent: Sendable, Equatable {
    case location(FootprintRawSample, isStationary: Bool)
    case ended
}

@MainActor protocol FootprintLiveStreamDriver: AnyObject {
    var active: Bool { get }
    var hasBackgroundSession: Bool { get }
    func start(
        backgroundAllowed: Bool,
        accuracyProvider: @escaping @MainActor () -> CLAccuracyAuthorization,
        onEvent: @escaping @MainActor (FootprintLiveStreamEvent) -> Void
    )
    func stop()
}

@MainActor protocol FootprintPowerSaverDriver: AnyObject {
    var active: Bool { get }
    var visitsMonitoring: Bool { get }
    var slcMonitoring: Bool { get }
    var allowsBackgroundUpdates: Bool { get }
    var authorizationStatus: CLAuthorizationStatus { get }
    var accuracyAuthorization: CLAccuracyAuthorization { get }
    func observeAuthorization(_ handler: @escaping @MainActor () -> Void)
    func requestAlwaysAuthorization()
    func start(
        backgroundAllowed: Bool,
        onSamples: @escaping @MainActor ([FootprintRawSample]) -> Void,
        onAuthorizationChanged: @escaping @MainActor () -> Void
    )
    func stop()
}

// MARK: - Production Drivers

@MainActor final class SystemFootprintLiveStreamDriver: FootprintLiveStreamDriver {
    private(set) var active = false
    private(set) var hasBackgroundSession = false
    private var streamToken = UUID()
    private var streamTask: Task<Void, Never>?
    #if os(iOS)
    private var backgroundSession: CLBackgroundActivitySession?
    #endif

    func start(
        backgroundAllowed: Bool,
        accuracyProvider: @escaping @MainActor () -> CLAccuracyAuthorization,
        onEvent: @escaping @MainActor (FootprintLiveStreamEvent) -> Void
    ) {
        stop()
        let token = UUID()
        streamToken = token
        active = true
        #if os(iOS)
        if backgroundAllowed {
            backgroundSession = CLBackgroundActivitySession()
            hasBackgroundSession = true
        }
        streamTask = Task { @MainActor [weak self] in
            defer {
                // Token guard: an exiting old task can NEVER invalidate a newly started session.
                if let self, self.streamToken == token, self.active {
                    self.active = false
                    self.backgroundSession?.invalidate()
                    self.backgroundSession = nil
                    self.hasBackgroundSession = false
                    onEvent(.ended)
                }
            }
            do {
                for try await update in CLLocationUpdate.liveUpdates(.default) {
                    guard !Task.isCancelled, self?.streamToken == token, self?.active == true else { break }
                    if let loc = update.location {
                        // Always derive precision from live system CLAccuracyAuthorization, never from horizontalAccuracy heuristic.
                        let isPrecise = accuracyProvider() == .fullAccuracy
                        let stationaryFlag: Bool
                        if #available(iOS 18.0, *) {
                            stationaryFlag = update.stationary
                        } else {
                            stationaryFlag = update.isStationary
                        }
                        let sample = FootprintRawSample(
                            latitude: loc.coordinate.latitude,
                            longitude: loc.coordinate.longitude,
                            accuracyMeters: loc.horizontalAccuracy,
                            measuredAt: loc.timestamp.timeIntervalSince1970,
                            precise: isPrecise,
                            speedMps: loc.speed >= 0 ? loc.speed : nil,
                            courseDegrees: loc.course >= 0 ? loc.course : nil,
                            source: "live"
                        )
                        onEvent(.location(sample, isStationary: stationaryFlag))
                    }
                }
            } catch {
                // Handled by token-guarded defer.
            }
        }
        #else
        hasBackgroundSession = false
        #endif
    }

    func stop() {
        streamToken = UUID()
        active = false
        streamTask?.cancel()
        streamTask = nil
        #if os(iOS)
        backgroundSession?.invalidate()
        backgroundSession = nil
        #endif
        hasBackgroundSession = false
    }
}

@MainActor final class SystemFootprintPowerSaverDriver: NSObject, FootprintPowerSaverDriver, @preconcurrency CLLocationManagerDelegate {
    private let manager: CLLocationManager
    private(set) var active = false
    private(set) var visitsMonitoring = false
    private(set) var slcMonitoring = false
    private(set) var allowsBackgroundUpdates = false
    private var onSamples: (@MainActor ([FootprintRawSample]) -> Void)?
    private var onAuthorizationChanged: (@MainActor () -> Void)?

    init(manager: CLLocationManager = CLLocationManager()) {
        self.manager = manager
        super.init()
        self.manager.delegate = self
    }

    var authorizationStatus: CLAuthorizationStatus { manager.authorizationStatus }
    var accuracyAuthorization: CLAccuracyAuthorization { manager.accuracyAuthorization }

    func observeAuthorization(_ handler: @escaping @MainActor () -> Void) {
        self.onAuthorizationChanged = handler
    }

    func requestAlwaysAuthorization() {
        manager.requestAlwaysAuthorization()
    }

    func start(
        backgroundAllowed: Bool,
        onSamples: @escaping @MainActor ([FootprintRawSample]) -> Void,
        onAuthorizationChanged: @escaping @MainActor () -> Void
    ) {
        self.onSamples = onSamples
        self.onAuthorizationChanged = onAuthorizationChanged
        active = true
        #if os(iOS)
        manager.pausesLocationUpdatesAutomatically = true
        manager.allowsBackgroundLocationUpdates = backgroundAllowed
        allowsBackgroundUpdates = backgroundAllowed
        manager.startMonitoringVisits()
        visitsMonitoring = true
        manager.startMonitoringSignificantLocationChanges()
        slcMonitoring = true
        #else
        allowsBackgroundUpdates = false
        visitsMonitoring = false
        manager.startMonitoringSignificantLocationChanges()
        slcMonitoring = true
        #endif
    }

    func stop() {
        active = false
        #if os(iOS)
        if visitsMonitoring {
            manager.stopMonitoringVisits()
            visitsMonitoring = false
        }
        if manager.allowsBackgroundLocationUpdates {
            manager.allowsBackgroundLocationUpdates = false
        }
        #endif
        if slcMonitoring {
            manager.stopMonitoringSignificantLocationChanges()
            slcMonitoring = false
        }
        allowsBackgroundUpdates = false
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        guard manager === self.manager else { return }
        onAuthorizationChanged?()
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard manager === self.manager, active else { return }
        let precise = manager.accuracyAuthorization == .fullAccuracy
        let samples = locations.map { loc in
            FootprintRawSample(
                latitude: loc.coordinate.latitude,
                longitude: loc.coordinate.longitude,
                accuracyMeters: loc.horizontalAccuracy,
                measuredAt: loc.timestamp.timeIntervalSince1970,
                precise: precise,
                speedMps: loc.speed >= 0 ? loc.speed : nil,
                courseDegrees: loc.course >= 0 ? loc.course : nil,
                source: "slc"
            )
        }
        onSamples?(samples)
    }

    #if os(iOS)
    func locationManager(_ manager: CLLocationManager, didVisit visit: CLVisit) {
        guard manager === self.manager, active else { return }
        let precise = manager.accuracyAuthorization == .fullAccuracy
        let hasDeparture = visit.departureDate != Date.distantFuture
        let timestamp = hasDeparture ? visit.departureDate.timeIntervalSince1970 : visit.arrivalDate.timeIntervalSince1970
        let event = hasDeparture
            ? FootprintTransitionEvent.visitDeparture.rawValue
            : FootprintTransitionEvent.visitArrival.rawValue
        let sample = FootprintRawSample(
            latitude: visit.coordinate.latitude,
            longitude: visit.coordinate.longitude,
            accuracyMeters: max(15.0, visit.horizontalAccuracy),
            measuredAt: timestamp,
            precise: precise,
            source: "visit",
            transitionEvent: event,
            forceKeep: true
        )
        onSamples?([sample])
    }
    #endif
}

// MARK: - Track A: Local Annual Footprint Tracker

/// Owns Track A (local annual footprint storage, power-saver/continuous acquisition,
/// 3-condition non-UI background restoration, and optional HTTPS/OwnTracks sync).
/// Completely isolated from Track B (chat location).
@MainActor @Observable final class FootprintTracker {
    static let settingsDefaultsKey = "vchat.footprint.settings.v1"

    static var exportDirectoryURL: URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("vchat-footprint-exports", isDirectory: true)
    }

    private(set) var settings: FootprintSettings
    private(set) var running = false
    private(set) var foreground = false
    private(set) var waitingForFirstUnlock = false
    private(set) var lastStorageError: String?
    private(set) var lastRestoreOutcome: BackgroundRestoreOutcome?
    private(set) var lastRecordedPoint: FootprintPoint?
    private(set) var pendingSyncCount = 0
    private(set) var lastSyncError: String?
    private(set) var lastSyncAt: Double?
    private(set) var deviceID: String?

    private(set) var footprintHistoryGeneration = UUID()
    private var activeClearCount = 0
    var isClearingHistory: Bool { activeClearCount > 0 }

    @ObservationIgnored private var store: FootprintStore?
    @ObservationIgnored var onClearInProgressHook: (@MainActor () async -> Void)?
    @ObservationIgnored private var reconcileTask: Task<Void, Never>?
    @ObservationIgnored private var syncGeneration = UUID()
    @ObservationIgnored private var isSwitchingDestination = false
    @ObservationIgnored private var syncEligibleSince: Double?
    @ObservationIgnored private var accuracyChangedAt: Double = 0
    @ObservationIgnored private var engine = FootprintIngestionEngine(markColdStart: true)
    @ObservationIgnored private var uploadScheduler = FootprintUploadScheduler()
    @ObservationIgnored private var previousAccuracyAuth: CLAccuracyAuthorization?
    @ObservationIgnored private var wasStationaryInLiveStream = false
    @ObservationIgnored private var lastLaunchHadLocationKey = false
    @ObservationIgnored private var homePlaceProvider: @MainActor () -> LocationPlace? = { nil }
    @ObservationIgnored private var onRawSampleObserved: (@MainActor (FootprintRawSample) -> Void)?

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let directoryURL: URL?
    @ObservationIgnored private let protector: any FootprintStorageProtector
    @ObservationIgnored private let secretStore: any FootprintSecretStore
    @ObservationIgnored private let syncClient: FootprintSyncClient
    @ObservationIgnored private let powerSaverDriver: any FootprintPowerSaverDriver
    @ObservationIgnored private let liveStreamDriver: any FootprintLiveStreamDriver
    @ObservationIgnored private let now: () -> Double

    init(
        defaults: UserDefaults = .standard,
        directoryURL: URL? = nil,
        protector: (any FootprintStorageProtector)? = nil,
        secretStore: (any FootprintSecretStore)? = nil,
        syncClient: FootprintSyncClient? = nil,
        powerSaverDriver: (any FootprintPowerSaverDriver)? = nil,
        liveStreamDriver: (any FootprintLiveStreamDriver)? = nil,
        now: @escaping () -> Double = { Date().timeIntervalSince1970 }
    ) {
        self.defaults = defaults
        self.directoryURL = directoryURL
        self.protector = protector ?? SystemFootprintStorageProtector()
        self.secretStore = secretStore ?? PersistentFootprintKeychain()
        self.syncClient = syncClient ?? FootprintSyncClient()
        let resolvedPowerSaver = powerSaverDriver ?? SystemFootprintPowerSaverDriver()
        self.powerSaverDriver = resolvedPowerSaver
        self.liveStreamDriver = liveStreamDriver ?? SystemFootprintLiveStreamDriver()
        self.now = now
        if let data = defaults.data(forKey: Self.settingsDefaultsKey),
           let saved = try? JSONDecoder().decode(FootprintSettings.self, from: data) {
            self.settings = saved
        } else {
            self.settings = FootprintSettings()
        }
        // Legacy config upgrade: if syncEnabled==true but syncEligibleSince is missing, establish and persist
        // a cutoff immediately so pre-upgrade late callbacks cannot leak to the sync endpoint while preserving
        // already-queued outbox items.
        if self.settings.syncEnabled && self.settings.syncEligibleSince == nil {
            let upgradeCutoff = now()
            self.settings.syncEligibleSince = upgradeCutoff
            if let encoded = try? JSONEncoder().encode(self.settings) {
                defaults.set(encoded, forKey: Self.settingsDefaultsKey)
            }
        }
        // Restore persisted syncEligibleSince across process restarts so pre-enable late callbacks remain local-only.
        self.syncEligibleSince = self.settings.syncEnabled ? self.settings.syncEligibleSince : Double.infinity
        self.previousAccuracyAuth = resolvedPowerSaver.accuracyAuthorization
        resolvedPowerSaver.observeAuthorization { [weak self] in
            Task { @MainActor in await self?.handleAuthorizationChanged() }
        }
    }

    var authorizationStatus: CLAuthorizationStatus { powerSaverDriver.authorizationStatus }
    var accuracyAuthorization: CLAccuracyAuthorization { powerSaverDriver.accuracyAuthorization }
    var liveDwellEvidence: FootprintLiveDwellEvidence? { settings.enabled ? engine.liveDwellEvidence : nil }
    var hasAlwaysAuthorization: Bool { authorizationStatus == .authorizedAlways }
    var hasForegroundAuthorization: Bool {
        #if os(iOS)
        return authorizationStatus == .authorizedAlways || authorizationStatus == .authorizedWhenInUse
        #else
        return authorizationStatus == .authorizedAlways
        #endif
    }

    var statusText: String {
        if !settings.enabled { return "本地足迹已关闭" }
        if waitingForFirstUnlock { return "等待首次解锁后恢复记录" }
        if let lastStorageError { return "本机足迹库异常：\(lastStorageError)" }
        if running {
            let scope = hasAlwaysAuthorization ? "后台已就绪" : "仅前台记录（需始终允许才可后台记录）"
            return "\(settings.mode == .powerSaver ? "省电档" : "连续档")运行中 · \(scope)"
        }
        switch authorizationStatus {
        case .denied: return "系统未允许定位"
        case .restricted: return "定位受系统限制"
        case .notDetermined: return "等待授予位置权限"
        default: return hasAlwaysAuthorization ? "已开启，待启动" : "仅前台可用（后台已暂停）"
        }
    }

    func setHomePlaceProvider(_ provider: @escaping @MainActor () -> LocationPlace?) {
        homePlaceProvider = provider
    }

    func setRawSampleObserver(_ observer: @escaping @MainActor (FootprintRawSample) -> Void) {
        onRawSampleObserved = observer
    }

    func persistSettings(_ next: FootprintSettings) {
        reconcileTask?.cancel()
        reconcileTask = Task { @MainActor [weak self] in
            await self?.applySettings(next)
        }
    }

    func applySettings(_ next: FootprintSettings) async {
        let wasEnabled = settings.enabled
        let wasSyncEnabled = settings.syncEnabled
        let oldEndpoint = FootprintIdentityStore.canonicalEndpointKey(settings.syncEndpointURL)
        let newEndpoint = FootprintIdentityStore.canonicalEndpointKey(next.syncEndpointURL)
        let endpointChanged = oldEndpoint != newEndpoint
        let modeChanged = settings.mode != next.mode

        // Isolate old outbox BEFORE activating a new destination or disabling sync,
        // completely independent of whether local tracking (`next.enabled`) is on or off.
        if (wasSyncEnabled && !next.syncEnabled) || endpointChanged {
            isSwitchingDestination = true
            syncGeneration = UUID()
            // Discard any buffered in-memory collinear point from the old destination so it can never be tagged with the new destination!
            engine.markSegmentBreak(.trackingRestarted)
            defer {
                isSwitchingDestination = false
                syncGeneration = UUID()
            }
            do {
                try await stopSyncAndClearOutboxStrict()
            } catch {
                // If isolating the previous destination's outbox failed, refuse to switch to the new endpoint.
                if endpointChanged {
                    lastSyncError = error.localizedDescription
                    return
                }
            }
        }

        var updated = next
        if !updated.syncEnabled {
            syncEligibleSince = Double.infinity
            updated.syncEligibleSince = nil
        } else if (!wasSyncEnabled && updated.syncEnabled) || endpointChanged {
            // Persist exact measurement cutoff across restarts so pre-enable/pre-switch late callbacks NEVER enter outbox!
            let cutoff = now()
            syncEligibleSince = cutoff
            updated.syncEligibleSince = cutoff
        } else {
            updated.syncEligibleSince = settings.syncEligibleSince
            syncEligibleSince = settings.syncEligibleSince
        }

        settings = updated
        saveSettingsToDefaults()

        if !next.enabled {
            stopDrivers()
            if wasEnabled || settings.recoverableBackgroundSession {
                settings.recoverableBackgroundSession = false
                saveSettingsToDefaults()
            }
            return
        }

        if !wasEnabled || modeChanged {
            engine.markSegmentBreak(.trackingRestarted)
        }
        await reconcileAcquisition(allowingInteraction: foreground)
    }

    /// Commits user-edited sync destination & format atomically in a single isolation pass.
    /// Switching URLs clears the previous destination's outbox ONCE (throwing on failure so UI never reports false success),
    /// writes destination-scoped Keychain credentials, and updates settings without redundant second cleanup.
    func commitSyncConfiguration(
        endpointURL: String,
        format: FootprintSyncFormat,
        writeToken: String? = nil
    ) async throws {
        let trimmedURL = endpointURL.trimmingCharacters(in: .whitespacesAndNewlines)
        let oldKey = FootprintIdentityStore.canonicalEndpointKey(settings.syncEndpointURL)
        let newKey = FootprintIdentityStore.canonicalEndpointKey(trimmedURL)
        let endpointChanged = oldKey != newKey

        if endpointChanged {
            isSwitchingDestination = true
            syncGeneration = UUID()
            // Discard any buffered in-memory collinear point captured under the previous destination!
            engine.markSegmentBreak(.trackingRestarted)
            defer {
                isSwitchingDestination = false
                syncGeneration = UUID()
            }
            try await stopSyncAndClearOutboxStrict()
            if let writeToken {
                try await FootprintIdentityStore.saveWriteToken(writeToken, for: trimmedURL, to: secretStore)
            }
            if settings.syncEnabled {
                let cutoff = now()
                syncEligibleSince = cutoff
                settings.syncEligibleSince = cutoff
            } else {
                syncEligibleSince = Double.infinity
                settings.syncEligibleSince = nil
            }
            settings.syncEndpointURL = trimmedURL
            settings.syncFormat = format
            saveSettingsToDefaults()
        } else {
            if let writeToken {
                try await FootprintIdentityStore.saveWriteToken(writeToken, for: trimmedURL, to: secretStore)
            }
            settings.syncEndpointURL = trimmedURL
            settings.syncFormat = format
            saveSettingsToDefaults()
        }

        if settings.enabled {
            await reconcileAcquisition(allowingInteraction: foreground)
        }
    }

    func setEnabled(_ enabled: Bool) {
        var next = settings
        next.enabled = enabled
        if !enabled {
            next.recoverableBackgroundSession = false
        } else {
            #if os(iOS)
            if authorizationStatus == .notDetermined || authorizationStatus == .authorizedWhenInUse {
                powerSaverDriver.requestAlwaysAuthorization()
            }
            #else
            if authorizationStatus == .notDetermined {
                powerSaverDriver.requestAlwaysAuthorization()
            }
            #endif
        }
        persistSettings(next)
    }

    func setForeground(_ active: Bool) {
        foreground = active
        reconcileTask?.cancel()
        guard settings.enabled else {
            stopDrivers()
            return
        }
        if active {
            reconcileTask = Task { @MainActor [weak self] in
                await self?.reconcileAcquisition(allowingInteraction: true)
            }
        } else {
            // Background continuation requires the exact same 3-condition AND gate;
            // NEVER synthesize recoverableBackgroundSession while transitioning to background.
            if !(hasAlwaysAuthorization && settings.recoverableBackgroundSession && running) {
                stopDrivers()
            }
        }
    }

    /// Non-UI background restore invoked from AppDelegate.didFinishLaunching.
    /// Strict 3-condition AND gate (never bypassed by launchOptions[.location]):
    ///   1. Persisted settings.enabled == true
    ///   2. System authorization == .authorizedAlways
    ///   3. Foreground previously established recoverableBackgroundSession == true
    /// Uses direct capability probing (store open + non-interactive Keychain read),
    /// NEVER relying on UIApplication.shared.isProtectedDataAvailable.
    @discardableResult
    func attemptBackgroundRestore(launchHadLocationKey: Bool) async -> BackgroundRestoreOutcome {
        reconcileTask?.cancel()
        lastLaunchHadLocationKey = launchHadLocationKey
        guard settings.enabled else {
            lastRestoreOutcome = .skippedDisabled
            stopDrivers()
            return .skippedDisabled
        }
        guard authorizationStatus == .authorizedAlways else {
            lastRestoreOutcome = .skippedAuthorizationNotAlways
            stopDrivers()
            return .skippedAuthorizationNotAlways
        }
        guard settings.recoverableBackgroundSession else {
            lastRestoreOutcome = .skippedNoRecoverableSession
            stopDrivers()
            return .skippedNoRecoverableSession
        }

        do {
            try await probeStorageAndIdentity(allowingInteraction: false)
            waitingForFirstUnlock = false
            lastStorageError = nil
        } catch FootprintStoreError.protectedDataUnavailable, FootprintIdentityError.protectedDataUnavailable {
            // Device rebooted before first unlock: do NOT generate identity or overwrite queue.
            waitingForFirstUnlock = true
            lastStorageError = nil
            lastRestoreOutcome = .deferredUntilFirstUnlock
            return .deferredUntilFirstUnlock
        } catch {
            waitingForFirstUnlock = false
            lastStorageError = error.localizedDescription
            lastRestoreOutcome = .failedStorageError(error.localizedDescription)
            stopDrivers()
            return .failedStorageError(error.localizedDescription)
        }

        // Strictly re-verify the ORIGINAL 3-condition background restore gate + cancellation after async probe.
        // Never allow a foreground+WhenInUse state to pass this background restore path with backgroundAllowed=true.
        guard !Task.isCancelled else {
            stopDrivers()
            return .skippedNoRecoverableSession
        }
        guard settings.enabled else {
            stopDrivers()
            lastRestoreOutcome = .skippedDisabled
            return .skippedDisabled
        }
        guard authorizationStatus == .authorizedAlways else {
            stopDrivers()
            lastRestoreOutcome = .skippedAuthorizationNotAlways
            return .skippedAuthorizationNotAlways
        }
        guard settings.recoverableBackgroundSession else {
            stopDrivers()
            lastRestoreOutcome = .skippedNoRecoverableSession
            return .skippedNoRecoverableSession
        }

        engine.markSegmentBreak(.coldStart)
        startActiveDriver(backgroundAllowed: true)
        lastRestoreOutcome = .restored(settings.mode)
        await flushPendingStateUpdateIfNeeded()
        return .restored(settings.mode)
    }

    /// Invoked when UIApplication.protectedDataDidBecomeAvailableNotification fires.
    @discardableResult
    func handleProtectedDataBecameAvailable() async -> BackgroundRestoreOutcome? {
        guard waitingForFirstUnlock else { return nil }
        if foreground {
            await reconcileAcquisition(allowingInteraction: true)
            return nil
        }
        return await attemptBackgroundRestore(launchHadLocationKey: lastLaunchHadLocationKey)
    }

    func handleAuthorizationChanged() async {
        let currentAcc = powerSaverDriver.accuracyAuthorization
        if previousAccuracyAuth != currentAcc {
            accuracyChangedAt = now()
        }
        previousAccuracyAuth = currentAcc

        // SYNCHRONOUSLY invalidate in-flight uploads & in-memory candidates BEFORE any async DB await,
        // so an already-dequeued precise batch can NEVER pass the pre-POST check while calibration is running.
        if currentAcc == .reducedAccuracy {
            syncGeneration = UUID()
            engine.discardPendingOnDowngrade()
        }

        if let opened = try? await ensureStoreOpen() {
            do {
                try await reconcileAccuracyAuthorization(in: opened)
            } catch {
                lastStorageError = error.localizedDescription
            }
        }

        if !hasAlwaysAuthorization && settings.recoverableBackgroundSession {
            settings.recoverableBackgroundSession = false
            saveSettingsToDefaults()
        }

        await reconcileAcquisition(allowingInteraction: foreground)
    }

    /// Reads recent precise points (<= 30 min, max 15) strictly for Requirement 1 sliding window semantics.
    func recentPreciseWindow(at nowSeconds: Double? = nil) async -> [FootprintPoint] {
        guard settings.enabled else { return [] }
        guard let store = try? await ensureStoreOpen() else { return [] }
        let tsMs = Int64(((nowSeconds ?? now()) * 1000.0).rounded())
        return (try? await store.recentPrecisePoints(withinSeconds: 1800, maxCount: 15, at: tsMs)) ?? []
    }

    func openStoreForUI() async throws -> FootprintStore {
        try await ensureStoreOpen()
    }

    func saveWriteToken(_ token: String, for endpointURL: String? = nil) async throws {
        let target = endpointURL ?? settings.syncEndpointURL
        try await FootprintIdentityStore.saveWriteToken(token, for: target, to: secretStore)
    }

    func readWriteToken(for endpointURL: String? = nil, allowingInteraction: Bool = true) async throws -> String {
        let target = endpointURL ?? settings.syncEndpointURL
        return try await FootprintIdentityStore.readWriteToken(for: target, from: secretStore, allowingInteraction: allowingInteraction)
    }

    @discardableResult
    func clearHistory(beforeMs: Int64? = nil) async throws -> FootprintStoreMeta {
        // Ref-counted clearing gate: overlapping clears keep isClearingHistory==true
        // until the LAST active clear commits and resets the engine.
        activeClearCount += 1
        syncGeneration = UUID()
        footprintHistoryGeneration = UUID()
        defer {
            activeClearCount = max(0, activeClearCount - 1)
            footprintHistoryGeneration = UUID()
        }
        if let hook = onClearInProgressHook {
            await hook()
        }
        let store = try await ensureStoreOpen()
        let nowMs = Int64((now() * 1000.0).rounded())
        let meta = try await store.clearHistory(beforeMs: beforeMs, nowMs: nowMs)
        // Invalidate in-memory dwell evidence whenever history is fully cleared or the cleared range covers the anchor!
        if beforeMs == nil {
            engine.resetForClear()
        } else if let cutoffMs = beforeMs,
                  let ev = engine.liveDwellEvidence,
                  Int64((ev.anchorStartedAt * 1000.0).rounded()) <= cutoffMs {
            engine.resetForClear()
        } else {
            engine.markSegmentBreak(.trackingRestarted)
        }
        lastRecordedPoint = try await store.lastPoint()
        pendingSyncCount = try await store.pendingOutboxCount()
        Self.removeTemporaryExports()
        return meta
    }

    static func removeTemporaryExports() {
        try? FileManager.default.removeItem(at: exportDirectoryURL)
    }

    @discardableResult
    func syncNow() async -> FootprintBatchSyncResult? {
        guard settings.syncEnabled, !isSwitchingDestination else { return nil }
        let activeGeneration = syncGeneration
        let activeSettings = settings
        let activeDestKey = FootprintIdentityStore.canonicalEndpointKey(activeSettings.syncEndpointURL)
        do {
            try await probeStorageAndIdentity(allowingInteraction: foreground)
            guard syncGeneration == activeGeneration, settings.syncEnabled, !isSwitchingDestination else { return nil }
            guard let store, let deviceID else { return nil }
            let token = try await FootprintIdentityStore.readWriteToken(
                for: activeSettings.syncEndpointURL,
                from: secretStore,
                allowingInteraction: foreground
            )
            let nowSec = now()
            let liveAuth: FootprintAccuracyAuth = powerSaverDriver.accuracyAuthorization == .fullAccuracy ? .full : .reduced
            let result = try await syncClient.flushOutbox(
                store: store,
                settings: activeSettings,
                deviceID: deviceID,
                writeToken: token,
                currentAccuracyAuth: liveAuth,
                nowMs: Int64((nowSec * 1000.0).rounded()),
                shouldContinue: { [weak self] in
                    await MainActor.run {
                        guard let self else { return false }
                        guard self.syncGeneration == activeGeneration,
                              self.settings.syncEnabled,
                              !self.isSwitchingDestination,
                              FootprintIdentityStore.canonicalEndpointKey(self.settings.syncEndpointURL) == activeDestKey else {
                            return false
                        }
                        // Live system accuracy guard: if this flush began under .full and system is now .reduced, halt immediately!
                        if liveAuth == .full && self.powerSaverDriver.accuracyAuthorization != .fullAccuracy {
                            return false
                        }
                        return true
                    }
                },
                allowStateUpdateDrain: { [weak self] in
                    await MainActor.run {
                        guard let self else { return false }
                        return self.settings.syncEnabled
                            && !self.isSwitchingDestination
                            && self.settings.syncFormat == .batchJSON
                            && FootprintIdentityStore.canonicalEndpointKey(self.settings.syncEndpointURL) == activeDestKey
                    }
                }
            )
            guard syncGeneration == activeGeneration, settings.syncEnabled else { return nil }
            pendingSyncCount = try await store.pendingOutboxCount()
            if result != nil {
                uploadScheduler.recordUpload(at: nowSec)
                lastSyncAt = nowSec
                lastSyncError = nil
            }
            return result
        } catch FootprintSyncError.cancelledByStateChange {
            return nil
        } catch {
            lastSyncError = error.localizedDescription
            return nil
        }
    }

    /// Exposed internally for deterministic testing and ingestion hooks.
    func ingestRawSamples(_ samples: [FootprintRawSample], isStationary: Bool? = nil) async {
        guard settings.enabled, !samples.isEmpty else { return }
        // Reject NaN/Infinite/overflowing timestamps & invalid coordinates BEFORE any Int64 conversion!
        let finiteSamples = samples.filter(\.valid)
        guard !finiteSamples.isEmpty else { return }

        let liveIsPrecise = (powerSaverDriver.accuracyAuthorization == .fullAccuracy)
        // Drop any late-arriving precise callbacks OR pre-downgrade measurements relabeled as reduced after downgrade.
        let validSamples = liveIsPrecise
            ? finiteSamples
            : finiteSamples.filter { !$0.precise && $0.measuredAt >= accuracyChangedAt }
        guard !validSamples.isEmpty else { return }

        if let isStationary {
            if wasStationaryInLiveStream && !isStationary {
                engine.markSegmentBreak(.systemResume)
            }
            wasStationaryInLiveStream = isStationary
        }
        for sample in validSamples {
            onRawSampleObserved?(sample)
        }
        guard let store = try? await ensureStoreOpen() else { return }
        // Abort batch if deletion watermark cannot be read (never fall back to 0, which could rebuild cleared dwell!).
        guard let storeMeta = try? await store.meta() else { return }
        let deletedBeforeMs = storeMeta.deletedBeforeMs
        // Re-check live system accuracy after awaiting store open to prevent race with mid-flight downgrade.
        let postOpenIsPrecise = (powerSaverDriver.accuracyAuthorization == .fullAccuracy)
        let finalSamples = (postOpenIsPrecise
            ? validSamples
            : validSamples.filter { !$0.precise && $0.measuredAt >= accuracyChangedAt }
        ).filter { sample in
            guard sample.valid else { return false }
            return Int64((sample.measuredAt * 1000.0).rounded()) > deletedBeforeMs
        }
        guard !finalSamples.isEmpty else { return }

        let nowSec = now()
        let nowMs = Int64((nowSec * 1000.0).rounded())
        let currentDestKey = FootprintIdentityStore.canonicalEndpointKey(settings.syncEndpointURL)
        let sampleSyncDest: String? = (settings.syncEnabled && !isSwitchingDestination && !currentDestKey.isEmpty) ? currentDestKey : nil
        let boundAccepted = engine.ingestBound(
            finalSamples,
            syncDestinationKey: sampleSyncDest,
            syncEligibleSince: syncEligibleSince,
            homePlace: homePlaceProvider(),
            now: nowSec
        )
        guard !boundAccepted.isEmpty else { return }
        let hasTransition = boundAccepted.contains { $0.point.transitionEvent != nil }
        let writes: [FootprintAnnotatedWrite] = boundAccepted.map { item in
            let itemCanSync = (item.syncDestinationKey != nil)
                && settings.syncEnabled
                && !isSwitchingDestination
                && (item.syncDestinationKey == currentDestKey)
            return FootprintAnnotatedWrite(
                point: item.point,
                enqueueForSync: itemCanSync,
                destinationKey: item.syncDestinationKey
            )
        }
        do {
            // Single atomic write transaction preserving per-point sync eligibility and destinationKey.
            _ = try await store.appendBatch(writes, nowMs: nowMs)
            lastRecordedPoint = boundAccepted.last?.point
            pendingSyncCount = try await store.pendingOutboxCount()
            if settings.syncEnabled,
               uploadScheduler.shouldUploadNow(
                pendingCount: pendingSyncCount,
                latestPoint: boundAccepted.last?.point,
                hasTransitionEvent: hasTransition,
                now: nowSec
               ) {
                _ = await syncNow()
            }
        } catch {
            // Storage failure (e.g., disk full): mark segment break for recovery.
            engine.markSegmentBreak(.diskRecovery)
        }
    }

    // MARK: - Unified Gate & Internal Helpers

    /// Single gate shared by ALL acquisition start paths.
    private func canStartDriversNow() -> Bool {
        guard settings.enabled else { return false }
        if foreground {
            return hasForegroundAuthorization
        }
        // Background strictly requires the 3-condition AND gate.
        return authorizationStatus == .authorizedAlways && settings.recoverableBackgroundSession
    }

    private func reconcileAcquisition(allowingInteraction: Bool) async {
        guard canStartDriversNow() else {
            stopDrivers()
            return
        }

        do {
            try await probeStorageAndIdentity(allowingInteraction: allowingInteraction)
            waitingForFirstUnlock = false
            lastStorageError = nil
        } catch FootprintStoreError.protectedDataUnavailable, FootprintIdentityError.protectedDataUnavailable {
            waitingForFirstUnlock = true
            lastStorageError = nil
            stopDrivers()
            return
        } catch {
            waitingForFirstUnlock = false
            lastStorageError = error.localizedDescription
            stopDrivers()
            return
        }

        // Critical race guard: re-check cancellation & gate AFTER async probe returns
        // (e.g., WhenInUse app moved to background while probe was in flight).
        guard !Task.isCancelled, canStartDriversNow() else {
            stopDrivers()
            return
        }

        let bgAllowed = hasAlwaysAuthorization && (foreground || settings.recoverableBackgroundSession)
        startActiveDriver(backgroundAllowed: bgAllowed)

        // Only record recoverableBackgroundSession AFTER an active foreground session is actually established with Always.
        if foreground && hasAlwaysAuthorization && running && !settings.recoverableBackgroundSession {
            settings.recoverableBackgroundSession = true
            saveSettingsToDefaults()
        }
        await flushPendingStateUpdateIfNeeded()
    }

    private func flushPendingStateUpdateIfNeeded() async {
        guard settings.syncEnabled, settings.syncFormat == .batchJSON,
              let store, (try? await store.pendingStateUpdate()) != nil else { return }
        _ = await syncNow()
    }

    private func startActiveDriver(backgroundAllowed: Bool) {
        switch settings.mode {
        case .powerSaver:
            liveStreamDriver.stop()
            if !powerSaverDriver.active || powerSaverDriver.allowsBackgroundUpdates != backgroundAllowed {
                powerSaverDriver.start(
                    backgroundAllowed: backgroundAllowed,
                    onSamples: { [weak self] samples in
                        Task { @MainActor in await self?.ingestRawSamples(samples) }
                    },
                    onAuthorizationChanged: { [weak self] in
                        Task { @MainActor in await self?.handleAuthorizationChanged() }
                    }
                )
            }
        case .continuous:
            powerSaverDriver.stop()
            if !liveStreamDriver.active || liveStreamDriver.hasBackgroundSession != backgroundAllowed {
                liveStreamDriver.start(
                    backgroundAllowed: backgroundAllowed,
                    accuracyProvider: { [weak self] in
                        self?.powerSaverDriver.accuracyAuthorization ?? .reducedAccuracy
                    },
                    onEvent: { [weak self] event in
                        Task { @MainActor in
                            guard let self else { return }
                            switch event {
                            case .location(let sample, let isStationary):
                                await self.ingestRawSamples([sample], isStationary: isStationary)
                            case .ended:
                                self.running = false
                            }
                        }
                    }
                )
            }
        }
        running = (settings.mode == .powerSaver ? powerSaverDriver.active : liveStreamDriver.active)
    }

    private func stopDrivers() {
        powerSaverDriver.stop()
        liveStreamDriver.stop()
        running = false
    }

    private func stopSyncAndClearOutboxStrict() async throws {
        let opened = try await ensureStoreOpen()
        try await opened.clearOutbox()
        try await opened.setPendingStateUpdate(nil)
        pendingSyncCount = (try? await opened.pendingOutboxCount()) ?? 0
    }

    /// Single-transaction accuracy authorization calibration shared by cold-start probe AND live auth callbacks.
    /// Purges stale precise outbox, discards in-memory collinear candidates, invalidates in-flight sync batches,
    /// and schedules single-flight batchJSON coordinate-free state update (without bypassing syncClient's single-flight lock).
    private func reconcileAccuracyAuthorization(in opened: FootprintStore, triggerUpload: Bool = true) async throws {
        let liveAuth: FootprintAccuracyAuth = powerSaverDriver.accuracyAuthorization == .fullAccuracy ? .full : .reduced
        if liveAuth == .reduced {
            // Establish cutoff IMMEDIATELY before any DB transaction so even a failed calibration cannot admit pre-launch points!
            if accuracyChangedAt == 0 {
                accuracyChangedAt = now()
            }
            engine.discardPendingOnDowngrade()
        }
        let shouldEnqueueStateUpdate = settings.syncEnabled && settings.syncFormat == .batchJSON
        do {
            let downgraded = try await opened.reconcileAccuracyAuthorization(
                liveAuth,
                enqueueBatchStateUpdate: shouldEnqueueStateUpdate,
                nowMs: Int64((now() * 1000.0).rounded())
            )
            if downgraded {
                accuracyChangedAt = max(accuracyChangedAt, now())
                syncGeneration = UUID()
                pendingSyncCount = (try? await opened.pendingOutboxCount()) ?? 0
                if triggerUpload && shouldEnqueueStateUpdate {
                    _ = await syncNow()
                }
            }
        } catch {
            // Propagate calibration failure so restore/reconcile aborts instead of clearing error & starting drivers!
            syncGeneration = UUID()
            lastStorageError = error.localizedDescription
            throw error
        }
    }

    private func ensureStoreOpen() async throws -> FootprintStore {
        if let store { return store }
        let dir = try directoryURL ?? FootprintStore.defaultDirectoryURL()
        let opened = try await FootprintStore.open(directoryURL: dir, protector: protector)
        self.store = opened
        let last = try? await opened.lastPoint()
        self.lastRecordedPoint = last
        if self.engine.lastCommitted == nil, let last {
            // Cold process start ALWAYS marks a segment break even if <120s elapsed.
            self.engine = FootprintIngestionEngine(lastCommitted: last, markColdStart: true)
        }
        self.pendingSyncCount = (try? await opened.pendingOutboxCount()) ?? 0
        return opened
    }

    private func probeStorageAndIdentity(allowingInteraction: Bool) async throws {
        let opened = try await ensureStoreOpen()
        let resolvedID = try await FootprintIdentityStore.resolveDeviceID(
            from: secretStore,
            allowingInteraction: allowingInteraction
        )
        self.deviceID = resolvedID

        // Calibrate accuracy in one DB transaction; propagate failure so restore/reconcile never starts drivers uncalibrated.
        try await reconcileAccuracyAuthorization(in: opened, triggerUpload: false)

        _ = try? await opened.pruneExpired(retentionDays: settings.retentionDays, nowMs: Int64((now() * 1000.0).rounded()))
    }

    private func saveSettingsToDefaults() {
        if let data = try? JSONEncoder().encode(settings) {
            defaults.set(data, forKey: Self.settingsDefaultsKey)
        }
    }
}