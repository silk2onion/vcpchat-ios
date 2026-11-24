import CoreLocation
import Foundation
import Observation
import VChatCore

/// Unified dual-track coordinator enforcing strict isolation between:
/// - Track B (`chatService`): per-message foreground chat location sharing.
/// - Track A (`footprintTracker`): optional local annual footprint & background tracking.
///
/// Isolation invariants:
/// 1. Track B NEVER reads Track A's database or cached points as a coordinate fallback.
/// 2. Track B NEVER borrows Track A's `.authorizedAlways` grant to run in the background.
/// 3. Track B background release (`setForeground(false)`) ONLY releases Track B's slots and
///    NEVER stops an active Track A background session.
/// 4. Sliding-window semantic points from Track A are only read when Track B already holds
///    a valid precise foreground snapshot for an authorized allowlisted chat request.
@MainActor @Observable final class LocationAcquisitionCoordinator {
    static let shared = LocationAcquisitionCoordinator()

    let chatService: DeviceLocationService
    let footprintTracker: FootprintTracker

    init(
        chatService: DeviceLocationService? = nil,
        footprintTracker: FootprintTracker? = nil
    ) {
        self.chatService = chatService ?? DeviceLocationService()
        self.footprintTracker = footprintTracker ?? FootprintTracker()
        self.footprintTracker.setRawSampleObserver { [weak self] sample in
            // Track B may only consume the live sensor reading when Track B is already actively
            // sampling in foreground with matching grant; it never bypasses Track B's gates.
            self?.forwardLiveSensorReadingIfPermitted(sample)
        }
    }

    func setForeground(_ active: Bool) {
        // Track B: strictly foreground-only; background immediately releases Track B slots.
        chatService.setForeground(active)
        // Track A: independently manages background continuation (Always-only) without Track B interference.
        footprintTracker.setForeground(active)
    }

    private var hasReceivedForegroundScene = false

    func markForegroundSceneActive(_ active: Bool) {
        if active { hasReceivedForegroundScene = true }
        setForeground(active)
    }

    @discardableResult
    func handleDidFinishLaunching(
        launchHadLocationKey: Bool,
        isBackgroundLaunch: Bool = true
    ) async -> BackgroundRestoreOutcome {
        // Foreground UI launch is owned exclusively by ScenePhase; never invoke background restore
        // which would cancel foreground reconcile or stop an active WhenInUse foreground session.
        if !isBackgroundLaunch || hasReceivedForegroundScene || footprintTracker.foreground {
            return .skippedNoRecoverableSession
        }
        // Pure non-UI background launch must NEVER start Track B chat sampling.
        chatService.setForeground(false)
        return await footprintTracker.attemptBackgroundRestore(launchHadLocationKey: launchHadLocationKey)
    }

    @discardableResult
    func handleProtectedDataBecameAvailable() async -> BackgroundRestoreOutcome? {
        await footprintTracker.handleProtectedDataBecameAvailable()
    }

    /// Reads Track A's recent precise sliding window (<= 30 min, max 15 points) ONLY when:
    /// 1. At least one recipient is allowlisted for historical semantics (not a one-off .include non-allowlisted chat),
    /// 2. Track B is in foreground with a valid, precise snapshot within TTL.
    func recentPrecisePointsForChatSemantics(
        chatSnapshot: LocationSnapshot?,
        semanticRecipients: Set<String>,
        at now: Double = Date().timeIntervalSince1970
    ) async -> [FootprintPoint] {
        guard !semanticRecipients.isEmpty,
              chatService.foreground,
              let chatSnapshot,
              chatSnapshot.precise,
              chatSnapshot.withinTTL(at: now) else {
            return []
        }
        return await footprintTracker.recentPreciseWindow(at: now)
    }

    private func forwardLiveSensorReadingIfPermitted(_ sample: FootprintRawSample) {
        // Only forward real-time GPS/SLC fixes, NEVER delayed CLVisit arrival/departure events.
        guard sample.source != "visit", chatService.foreground, chatService.locating else { return }
        chatService.acceptSharedLiveSensorReading(
            latitude: sample.latitude,
            longitude: sample.longitude,
            accuracyMeters: sample.accuracyMeters,
            measuredAt: sample.measuredAt,
            precise: sample.precise,
            speedMps: sample.speedMps,
            courseDegrees: sample.courseDegrees
        )
    }
}