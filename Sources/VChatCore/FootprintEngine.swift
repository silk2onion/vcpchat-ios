import Foundation

public enum FootprintSegmentBreakReason: String, Sendable, Equatable {
    case none
    case coldStart
    case systemResume
    case trackingRestarted
    case diskRecovery
}

public struct FootprintRawSample: Sendable, Equatable {
    public var latitude: Double
    public var longitude: Double
    public var accuracyMeters: Double
    public var measuredAt: Double
    public var precise: Bool
    public var speedMps: Double?
    public var courseDegrees: Double?
    public var source: String
    public var transitionEvent: String?
    public var forceKeep: Bool

    public init(
        latitude: Double,
        longitude: Double,
        accuracyMeters: Double,
        measuredAt: Double,
        precise: Bool,
        speedMps: Double? = nil,
        courseDegrees: Double? = nil,
        source: String = "live",
        transitionEvent: String? = nil,
        forceKeep: Bool = false
    ) {
        self.latitude = latitude
        self.longitude = longitude
        self.accuracyMeters = accuracyMeters
        self.measuredAt = measuredAt
        self.precise = precise
        self.speedMps = speedMps.flatMap { $0.isFinite && $0 >= 0 ? $0 : nil }
        self.courseDegrees = courseDegrees.flatMap { $0.isFinite && $0 >= 0 && $0 <= 360 ? $0 : nil }
        self.source = source
        self.transitionEvent = transitionEvent
        self.forceKeep = forceKeep
    }

    public var valid: Bool {
        guard latitude.isFinite, longitude.isFinite, accuracyMeters.isFinite, measuredAt.isFinite else { return false }
        let ms = (measuredAt * 1000.0).rounded()
        return ms.isFinite && ms >= -9_000_000_000_000_000 && ms <= 9_000_000_000_000_000
            && (-90...90).contains(latitude) && (-180...180).contains(longitude) && accuracyMeters >= 0
    }
}

/// Deterministic batch filtering, drift suppression, corner-preserving simplification, and >120s segment splitting engine.
public struct FootprintIngestionEngine: Sendable {
    public static let maxGapSeconds: Double = 120.0
    public static let maxFutureSkewSeconds: Double = 60.0
    public static let maxPreciseAccuracyMeters: Double = 100.0
    public static let maxReducedAccuracyMeters: Double = 50_000.0
    public static let minDriftFloorMeters: Double = 12.0
    public static let driftAccuracyRatio: Double = 0.7
    public static let cornerDeviationThresholdMeters: Double = 6.0
    public static let collinearTimeCapSeconds: Double = 30.0
    public static let collinearDistanceCapMeters: Double = 45.0

    public static let cornerTurnAngleThresholdDegrees: Double = 18.0

    public struct IngestedPoint: Sendable, Equatable {
        public let point: FootprintPoint
        public let syncDestinationKey: String?

        public init(point: FootprintPoint, syncDestinationKey: String?) {
            self.point = point
            self.syncDestinationKey = syncDestinationKey
        }
    }

    public private(set) var currentSegmentID: String?
    public private(set) var lastCommitted: FootprintPoint?
    public private(set) var lastValidMeasuredAtMs: Int64?
    private var previousCommittedInSegment: FootprintPoint?
    private var pendingCollinearPoint: FootprintPoint?
    private var pendingCollinearSyncDestinationKey: String?
    private var pendingBreak: FootprintSegmentBreakReason = .none
    private var lastDwellAnchor: FootprintPoint?
    private var emittedDwell5mForAnchor = false
    private var wasAtHome: Bool?

    /// Strong-typed live dwell evidence bound strictly to the active precise segment.
    /// Returns nil whenever the active segment is reduced-accuracy or has no active anchor.
    public var liveDwellEvidence: FootprintLiveDwellEvidence? {
        guard let segID = currentSegmentID,
              let last = lastCommitted,
              last.segmentID == segID,
              last.accuracyAuth == .full,
              let anchor = lastDwellAnchor,
              anchor.segmentID == segID,
              anchor.accuracyAuth == .full,
              let lastValidMs = lastValidMeasuredAtMs else {
            return nil
        }
        return FootprintLiveDwellEvidence(
            segmentID: segID,
            accuracyAuth: .full,
            anchorLatitude: anchor.latitude,
            anchorLongitude: anchor.longitude,
            anchorAccuracyMeters: anchor.accuracyMeters,
            anchorStartedAt: anchor.measuredAtSeconds,
            lastValidMeasuredAt: Double(lastValidMs) / 1000.0,
            confirmedDwelled5m: emittedDwell5mForAnchor
        )
    }

    public init(lastCommitted: FootprintPoint? = nil, markColdStart: Bool = false) {
        self.lastCommitted = lastCommitted
        self.lastValidMeasuredAtMs = lastCommitted?.measuredAtMs
        self.currentSegmentID = lastCommitted?.segmentID
        self.lastDwellAnchor = lastCommitted
        if markColdStart {
            self.pendingBreak = .coldStart
        }
    }

    public mutating func markSegmentBreak(_ reason: FootprintSegmentBreakReason) {
        guard reason != .none else { return }
        pendingBreak = reason
        pendingCollinearPoint = nil
        pendingCollinearSyncDestinationKey = nil
    }

    /// Discards any buffered in-memory precise candidate on full -> reduced accuracy downgrade
    /// so it can never be flushed into storage or outbox on the next segment break.
    public mutating func discardPendingOnDowngrade() {
        pendingCollinearPoint = nil
        pendingCollinearSyncDestinationKey = nil
        pendingBreak = .trackingRestarted
    }

    /// Completely invalidates all in-memory segment, collinear buffer, and live dwell evidence
    /// upon history clear so deleted dwell history can never leak into subsequent chats.
    public mutating func resetForClear() {
        currentSegmentID = nil
        lastCommitted = nil
        lastValidMeasuredAtMs = nil
        previousCommittedInSegment = nil
        pendingCollinearPoint = nil
        pendingCollinearSyncDestinationKey = nil
        lastDwellAnchor = nil
        emittedDwell5mForAnchor = false
        wasAtHome = nil
        pendingBreak = .trackingRestarted
    }

    public mutating func ingest(
        _ samples: [FootprintRawSample],
        homePlace: LocationPlace? = nil,
        now: Double = Date().timeIntervalSince1970,
        makeID: () -> String = { UUID().uuidString.lowercased() }
    ) -> [FootprintPoint] {
        ingestBound(samples, syncDestinationKey: nil, homePlace: homePlace, now: now, makeID: makeID).map(\.point)
    }

    /// Evaluates a batch in chronological order and binds EVERY point (including buffered in-memory
    /// collinear corner candidates) to the exact `syncDestinationKey` active AT THAT POINT'S MEASUREMENT TIME.
    /// Any sample with `measuredAt < syncEligibleSince` (e.g., measured while sync was OFF or before switching to B,
    /// delivered late via callback after enabling B) carries `syncDestinationKey == nil` and is stored locally ONLY.
    public mutating func ingestBound(
        _ samples: [FootprintRawSample],
        syncDestinationKey: String?,
        syncEligibleSince: Double? = nil,
        homePlace: LocationPlace? = nil,
        now: Double = Date().timeIntervalSince1970,
        makeID: () -> String = { UUID().uuidString.lowercased() }
    ) -> [IngestedPoint] {
        let activeDest: String? = syncDestinationKey.flatMap { raw in
            let canonical = FootprintIdentityStore.canonicalEndpointKey(raw)
            return canonical.isEmpty ? nil : canonical
        }
        let filtered = samples.filter { sample in
            guard sample.valid else { return false }
            guard sample.measuredAt <= now + Self.maxFutureSkewSeconds else { return false }
            if sample.precise {
                return sample.accuracyMeters <= Self.maxPreciseAccuracyMeters
            } else {
                return sample.accuracyMeters <= Self.maxReducedAccuracyMeters
            }
        }.sorted { lhs, rhs in
            if lhs.measuredAt != rhs.measuredAt { return lhs.measuredAt < rhs.measuredAt }
            return lhs.accuracyMeters < rhs.accuracyMeters
        }

        var accepted: [IngestedPoint] = []
        for sample in filtered {
            let boundDest: String? = {
                guard let activeDest else { return nil }
                if let cutoff = syncEligibleSince, sample.measuredAt < cutoff {
                    return nil
                }
                return activeDest
            }()
            let sampleMs = Int64((sample.measuredAt * 1000.0).rounded())
            if let lastSeen = lastValidMeasuredAtMs, sampleMs < lastSeen {
                continue
            }
            if let last = lastCommitted, sampleMs == last.measuredAtMs, sample.accuracyMeters >= last.accuracyMeters, !sample.forceKeep {
                continue
            }

            let auth: FootprintAccuracyAuth = sample.precise ? .full : .reduced
            let mustSplit = shouldSplitSegment(nextMs: sampleMs, nextAuth: auth)
            // Update lastValidMeasuredAtMs for every valid measurement (even if later drift-suppressed)
            // so stationary periodic fixes every 30s never trigger a false >120s gap split.
            lastValidMeasuredAtMs = sampleMs

            if mustSplit || currentSegmentID == nil {
                // Flush any buffered straight-line endpoint BEFORE breaking the old segment with ITS OWN
                // original syncDestinationKey, EXCEPT on full -> reduced downgrade where it MUST be discarded.
                if let pending = pendingCollinearPoint {
                    let pendingDest = pendingCollinearSyncDestinationKey
                    pendingCollinearPoint = nil
                    pendingCollinearSyncDestinationKey = nil
                    if !(pending.accuracyAuth == .full && auth == .reduced) {
                        commit(pending, syncDestinationKey: pendingDest, into: &accepted, resetDwellIfMoved: true)
                    }
                }
                currentSegmentID = makeID()
                previousCommittedInSegment = nil
                pendingBreak = .none
                if mustSplit {
                    lastDwellAnchor = nil
                    emittedDwell5mForAnchor = false
                }
            }
            let segID = currentSegmentID!

            // Drift suppression within the same segment for non-forced points.
            if !mustSplit, let last = lastCommitted, !sample.forceKeep, sample.transitionEvent == nil {
                let reference = pendingCollinearPoint ?? last
                let dist = FootprintPoint.haversineMeters(
                    lat1: reference.latitude, lon1: reference.longitude,
                    lat2: sample.latitude, lon2: sample.longitude
                )
                let dt = Double(sampleMs - reference.measuredAtMs) / 1000.0
                let driftThreshold = max(Self.minDriftFloorMeters, Self.driftAccuracyRatio * sample.accuracyMeters)

                // Emit `dwelled_5m` ONCE per stationary anchor (strictly zero stationary heartbeats afterwards).
                var dwellTransition: String?
                if let anchor = lastDwellAnchor {
                    let anchorDist = FootprintPoint.haversineMeters(
                        lat1: anchor.latitude, lon1: anchor.longitude,
                        lat2: sample.latitude, lon2: sample.longitude
                    )
                    if anchorDist <= max(35.0, sample.accuracyMeters * 1.2) {
                        if !emittedDwell5mForAnchor && Double(sampleMs - anchor.measuredAtMs) >= 300_000 {
                            emittedDwell5mForAnchor = true
                            dwellTransition = FootprintTransitionEvent.dwelled5m.rawValue
                        }
                    }
                }

                if dist <= driftThreshold && dwellTransition == nil {
                    continue
                }

                var computedMotion = inferMotionState(sample: sample, previous: reference, dt: dt, distance: dist)
                var event = dwellTransition
                if event == nil, reference.motionState == .stationary || reference.motionState == .dwelling,
                   computedMotion == .walking || computedMotion == .vehicle {
                    event = FootprintTransitionEvent.startedMoving.rawValue
                }
                if dwellTransition != nil {
                    computedMotion = .dwelling
                }
                if let homeEvent = detectHomeTransition(sample: sample, homePlace: homePlace) {
                    event = homeEvent.rawValue
                }

                let candidate = FootprintPoint(
                    pointID: makeID(),
                    segmentID: segID,
                    measuredAtMs: sampleMs,
                    latitude: sample.latitude,
                    longitude: sample.longitude,
                    accuracyMeters: sample.accuracyMeters,
                    speedMps: sample.speedMps,
                    courseDegrees: sample.courseDegrees,
                    accuracyAuth: auth,
                    motionState: computedMotion,
                    transitionEvent: event,
                    source: sample.source,
                    receivedAtMs: Int64((now * 1000.0).rounded())
                )

                // 1-point lookahead corner-preserving simplification:
                // Never drop a candidate prematurely; buffer it WITH its sampling-time syncDestinationKey
                // and flush it as a corner vertex if the subsequent fix turns sharply.
                if auth == .full, event == nil, let prev2 = previousCommittedInSegment {
                    let lineEnd = pendingCollinearPoint ?? last
                    let perp = Self.perpendicularDistanceMeters(
                        point: (candidate.latitude, candidate.longitude),
                        lineStart: (prev2.latitude, prev2.longitude),
                        lineEnd: (lineEnd.latitude, lineEnd.longitude)
                    )
                    let bearing1 = FootprintPoint.bearingDegrees(
                        lat1: prev2.latitude, lon1: prev2.longitude,
                        lat2: lineEnd.latitude, lon2: lineEnd.longitude
                    )
                    let bearing2 = FootprintPoint.bearingDegrees(
                        lat1: lineEnd.latitude, lon1: lineEnd.longitude,
                        lat2: candidate.latitude, lon2: candidate.longitude
                    )
                    let rawTurn = abs(bearing2 - bearing1)
                    let turnAngle = min(rawTurn, 360.0 - rawTurn)
                    let dtFromCommitted = Double(candidate.measuredAtMs - last.measuredAtMs) / 1000.0
                    let distFromCommitted = last.distance(to: candidate)
                    let speedDelta = abs((candidate.speedMps ?? 0) - (lineEnd.speedMps ?? 0))

                    let isCollinear = perp < Self.cornerDeviationThresholdMeters
                        && turnAngle < Self.cornerTurnAngleThresholdDegrees
                        && dtFromCommitted < Self.collinearTimeCapSeconds
                        && distFromCommitted < Self.collinearDistanceCapMeters
                        && speedDelta < 1.5

                    if isCollinear {
                        pendingCollinearPoint = candidate
                        pendingCollinearSyncDestinationKey = boundDest
                        continue
                    } else if let pending = pendingCollinearPoint {
                        let pendingDest = pendingCollinearSyncDestinationKey
                        pendingCollinearPoint = nil
                        pendingCollinearSyncDestinationKey = nil
                        commit(pending, syncDestinationKey: pendingDest, into: &accepted, resetDwellIfMoved: true)
                    }
                } else if let pending = pendingCollinearPoint {
                    let pendingDest = pendingCollinearSyncDestinationKey
                    pendingCollinearPoint = nil
                    pendingCollinearSyncDestinationKey = nil
                    commit(pending, syncDestinationKey: pendingDest, into: &accepted, resetDwellIfMoved: true)
                }

                commit(candidate, syncDestinationKey: boundDest, into: &accepted, resetDwellIfMoved: dist > max(35.0, sample.accuracyMeters * 1.2))
                continue
            }

            // First point of a segment or forced/visit sample.
            if let pending = pendingCollinearPoint {
                let pendingDest = pendingCollinearSyncDestinationKey
                pendingCollinearPoint = nil
                pendingCollinearSyncDestinationKey = nil
                commit(pending, syncDestinationKey: pendingDest, into: &accepted, resetDwellIfMoved: true)
            }
            var event = sample.transitionEvent
            if let homeEvent = detectHomeTransition(sample: sample, homePlace: homePlace), event == nil {
                event = homeEvent.rawValue
            }
            let motion: FootprintMotionState = {
                if let speed = sample.speedMps {
                    if speed >= 4.0 { return .vehicle }
                    if speed >= 0.5 { return .walking }
                }
                return .stationary
            }()
            let point = FootprintPoint(
                pointID: makeID(),
                segmentID: segID,
                measuredAtMs: sampleMs,
                latitude: sample.latitude,
                longitude: sample.longitude,
                accuracyMeters: sample.accuracyMeters,
                speedMps: sample.speedMps,
                courseDegrees: sample.courseDegrees,
                accuracyAuth: auth,
                motionState: motion,
                transitionEvent: event,
                source: sample.source,
                receivedAtMs: Int64((now * 1000.0).rounded())
            )
            commit(point, syncDestinationKey: boundDest, into: &accepted, resetDwellIfMoved: true)
        }

        return accepted
    }

    private func shouldSplitSegment(nextMs: Int64, nextAuth: FootprintAccuracyAuth) -> Bool {
        if pendingBreak != .none { return true }
        guard let last = lastCommitted else { return true }
        if last.accuracyAuth != nextAuth { return true }
        let referenceMs = lastValidMeasuredAtMs ?? last.measuredAtMs
        let dtSeconds = Double(nextMs - referenceMs) / 1000.0
        return dtSeconds > Self.maxGapSeconds
    }

    private mutating func commit(
        _ point: FootprintPoint,
        syncDestinationKey: String?,
        into accepted: inout [IngestedPoint],
        resetDwellIfMoved: Bool
    ) {
        if let last = lastCommitted, last.segmentID == point.segmentID {
            previousCommittedInSegment = last
        } else {
            previousCommittedInSegment = nil
        }
        lastCommitted = point
        // Advance dwell anchor whenever the point actually leaves the current anchor radius (not only single-step distance),
        // so walking 200m in 20m steps then stopping always establishes a fresh anchor at the stop location.
        if let anchor = lastDwellAnchor {
            let anchorDist = anchor.distance(to: point)
            let anchorRadius = max(35.0, point.accuracyMeters * 1.2)
            if anchor.segmentID != point.segmentID || anchorDist > anchorRadius || resetDwellIfMoved {
                lastDwellAnchor = point
                emittedDwell5mForAnchor = false
            }
        } else {
            lastDwellAnchor = point
            emittedDwell5mForAnchor = false
        }
        accepted.append(IngestedPoint(point: point, syncDestinationKey: syncDestinationKey))
    }

    private func inferMotionState(sample: FootprintRawSample, previous: FootprintPoint, dt: Double, distance: Double) -> FootprintMotionState {
        let inferredSpeed = sample.speedMps ?? (dt > 0 ? distance / dt : 0)
        if inferredSpeed >= 4.0 { return .vehicle }
        if inferredSpeed >= 0.5 && distance > max(Self.minDriftFloorMeters, sample.accuracyMeters * 0.7) { return .walking }
        return .stationary
    }

    private mutating func detectHomeTransition(sample: FootprintRawSample, homePlace: LocationPlace?) -> FootprintTransitionEvent? {
        guard sample.precise, let homeCoord = homePlace?.coordinate, homeCoord.valid else { return nil }
        let dist = FootprintPoint.haversineMeters(
            lat1: sample.latitude, lon1: sample.longitude,
            lat2: homeCoord.latitude, lon2: homeCoord.longitude
        )
        let threshold = max(80.0, sample.accuracyMeters + homeCoord.accuracyMeters)
        let isNowAtHome = dist <= threshold
        defer { wasAtHome = isNowAtHome }
        guard let prev = wasAtHome, prev != isNowAtHome else { return nil }
        return isNowAtHome ? .arrivedHome : .leftHome
    }

    /// Equirectangular local projection distance from `point` to the line defined by `lineStart` and `lineEnd` (meters).
    public static func perpendicularDistanceMeters(
        point: (Double, Double),
        lineStart: (Double, Double),
        lineEnd: (Double, Double)
    ) -> Double {
        let rad = Double.pi / 180.0
        let refLat = lineStart.0 * rad
        let metersPerLat = 111_132.0
        let metersPerLon = 111_320.0 * cos(refLat)

        let px = (point.1 - lineStart.1) * metersPerLon
        let py = (point.0 - lineStart.0) * metersPerLat
        let ex = (lineEnd.1 - lineStart.1) * metersPerLon
        let ey = (lineEnd.0 - lineStart.0) * metersPerLat

        let lineLen = hypot(ex, ey)
        guard lineLen > 0.001 else { return hypot(px, py) }
        return abs(ex * py - ey * px) / lineLen
    }
}

// MARK: - Local 30-minute Sliding Window Semantic Calculator (Requirement 1)

public struct FootprintLiveDwellEvidence: Sendable, Equatable {
    public let segmentID: String
    public let accuracyAuth: FootprintAccuracyAuth
    public let anchorLatitude: Double
    public let anchorLongitude: Double
    public let anchorAccuracyMeters: Double
    public let anchorStartedAt: Double
    public let lastValidMeasuredAt: Double
    public let confirmedDwelled5m: Bool

    public init(
        segmentID: String,
        accuracyAuth: FootprintAccuracyAuth,
        anchorLatitude: Double,
        anchorLongitude: Double,
        anchorAccuracyMeters: Double,
        anchorStartedAt: Double,
        lastValidMeasuredAt: Double,
        confirmedDwelled5m: Bool
    ) {
        self.segmentID = segmentID
        self.accuracyAuth = accuracyAuth
        self.anchorLatitude = anchorLatitude
        self.anchorLongitude = anchorLongitude
        self.anchorAccuracyMeters = anchorAccuracyMeters
        self.anchorStartedAt = anchorStartedAt
        self.lastValidMeasuredAt = lastValidMeasuredAt
        self.confirmedDwelled5m = confirmedDwelled5m
    }
}

public struct RecentMovementSummary: Sendable, Equatable {
    public let distanceMeters: Double
    public let startedAt: Double
    public let pointCount: Int

    public init(distanceMeters: Double, startedAt: Double, pointCount: Int) {
        self.distanceMeters = distanceMeters
        self.startedAt = startedAt
        self.pointCount = pointCount
    }
}

public struct LocalMovementSemantics: Sendable, Equatable {
    public let motionState: FootprintMotionState
    public let speedMps: Double?
    public let courseDegrees: Double?
    public let dwelling: Bool
    public let dwellSeconds: Int
    public let headingToHome: FootprintHeadingToHome?
    public let distanceToHomeMeters: Double?
    public let recentMovement: RecentMovementSummary?

    public init(
        motionState: FootprintMotionState,
        speedMps: Double?,
        courseDegrees: Double?,
        dwelling: Bool,
        dwellSeconds: Int,
        headingToHome: FootprintHeadingToHome?,
        distanceToHomeMeters: Double?,
        recentMovement: RecentMovementSummary?
    ) {
        self.motionState = motionState
        self.speedMps = speedMps
        self.courseDegrees = courseDegrees
        self.dwelling = dwelling
        self.dwellSeconds = dwellSeconds
        self.headingToHome = headingToHome
        self.distanceToHomeMeters = distanceToHomeMeters
        self.recentMovement = recentMovement
    }
}

public enum LocalMovementSemanticCalculator {
    public static let windowSeconds: Double = 1800.0
    public static let recentSummaryWindowSeconds: Double = 900.0
    public static let maxWindowPoints: Int = 15
    public static let dwellThresholdSeconds: Double = 300.0

    /// Computes movement semantics strictly from precise foreground snapshot + recent precise window
    /// + already ACL-filtered sharedPlaces for the target agent.
    public static func compute(
        current: LocationSnapshot,
        recentPoints: [FootprintPoint],
        sharedPlaces: [LocationPlace],
        liveDwellEvidence: FootprintLiveDwellEvidence? = nil,
        now: Double = Date().timeIntervalSince1970
    ) -> LocalMovementSemantics? {
        guard current.valid, current.precise else { return nil }

        let minTime = now - windowSeconds
        var window: [FootprintPoint] = recentPoints
            .filter { pt in
                pt.valid && pt.accuracyAuth == .full
                    && pt.measuredAtSeconds >= minTime
                    && pt.measuredAtSeconds <= current.measuredAt
            }
            .sorted { $0.measuredAtMs < $1.measuredAtMs }

        if window.count > maxWindowPoints - 1 {
            window = Array(window.suffix(maxWindowPoints - 1))
        }

        let currentPoint = FootprintPoint(
            pointID: "current",
            segmentID: window.last?.segmentID ?? liveDwellEvidence?.segmentID ?? "current",
            measuredAtMs: Int64((current.measuredAt * 1000.0).rounded()),
            latitude: current.latitude,
            longitude: current.longitude,
            accuracyMeters: current.accuracyMeters,
            speedMps: current.speedMps,
            courseDegrees: current.courseDegrees,
            accuracyAuth: .full,
            source: "chat"
        )

        // Validate live dwell evidence strictly by segment ID, full accuracy, <=120s real measurement gap,
        // and dwell radius — so 36+ min continuous stays remain dwelling=true even after stored points age out
        // of the 30-min SQL window, while a reduced/different segment or >120s measurement gap NEVER bridges!
        let validLiveEvidence: FootprintLiveDwellEvidence? = {
            guard let ev = liveDwellEvidence,
                  ev.accuracyAuth == .full,
                  ev.lastValidMeasuredAt >= ev.anchorStartedAt,
                  (current.measuredAt - ev.lastValidMeasuredAt) <= FootprintIngestionEngine.maxGapSeconds,
                  (current.measuredAt - ev.lastValidMeasuredAt) >= -10.0 else {
                return nil
            }
            // If stored window has a newer/different segment, refuse cross-segment bleed!
            if let last = window.last, last.segmentID != ev.segmentID {
                return nil
            }
            let distToAnchor = FootprintPoint.haversineMeters(
                lat1: ev.anchorLatitude, lon1: ev.anchorLongitude,
                lat2: current.latitude, lon2: current.longitude
            )
            let radius = max(35.0, max(ev.anchorAccuracyMeters, current.accuracyMeters) * 1.2)
            return distToAnchor <= radius ? ev : nil
        }()

        let continuousStationaryBridge: Bool
        if let last = window.last,
           let ev = validLiveEvidence,
           last.segmentID == ev.segmentID,
           ev.lastValidMeasuredAt >= last.measuredAtSeconds {
            continuousStationaryBridge = true
        } else {
            continuousStationaryBridge = false
        }

        // Lock the active segment ID BEFORE optionally replacing the newest stored point (<1s away),
        // so replacing the first point of a new segment can never bleed into the previous segment.
        let activeSegmentID: String?
        if let last = window.last,
           (current.measuredAt - last.measuredAtSeconds) <= FootprintIngestionEngine.maxGapSeconds || continuousStationaryBridge {
            activeSegmentID = last.segmentID
        } else {
            activeSegmentID = validLiveEvidence?.segmentID
        }

        let priorPoints: [FootprintPoint]
        var effectiveCurrentPoint = currentPoint
        var confirmedDwellFloorSeconds = 0.0
        if let last = window.last, abs(last.measuredAtSeconds - current.measuredAt) < 1.0 {
            if last.transitionEvent == FootprintTransitionEvent.dwelled5m.rawValue,
               last.distance(to: currentPoint) <= max(35.0, max(last.accuracyMeters, current.accuracyMeters) * 1.2) {
                effectiveCurrentPoint.transitionEvent = FootprintTransitionEvent.dwelled5m.rawValue
                confirmedDwellFloorSeconds = max(
                    confirmedDwellFloorSeconds,
                    dwellThresholdSeconds + max(0, current.measuredAt - last.measuredAtSeconds)
                )
            }
            priorPoints = Array(window.dropLast())
        } else {
            priorPoints = window
        }

        // Restrict sliding window strictly to `activeSegmentID` with no >120s real measurement gaps.
        var continuousWindow: [FootprintPoint] = [effectiveCurrentPoint]
        if let activeSegmentID {
            var cursor = effectiveCurrentPoint
            for pt in priorPoints.reversed() {
                guard pt.segmentID == activeSegmentID else { break }
                let dt = cursor.measuredAtSeconds - pt.measuredAtSeconds
                let withinRadius = pt.distance(to: cursor) <= max(35.0, max(pt.accuracyMeters, cursor.accuracyMeters) * 1.2)
                let bridgedByLiveStationary = (cursor.pointID == "current" && continuousStationaryBridge && withinRadius && dt >= 0)
                let bridgedByConfirmedDwell = (cursor.transitionEvent == FootprintTransitionEvent.dwelled5m.rawValue)
                    && dt >= 0 && dt <= windowSeconds && withinRadius
                guard (dt >= 0 && dt <= FootprintIngestionEngine.maxGapSeconds) || bridgedByLiveStationary || bridgedByConfirmedDwell else { break }
                continuousWindow.append(pt)
                cursor = pt
            }
        }
        window = continuousWindow.reversed()

        // Compute dwell cluster backward from current point within the continuous segment only.
        var dwellStart = currentPoint.measuredAtSeconds
        for pt in window.dropLast().reversed() {
            let d = pt.distance(to: currentPoint)
            let radius = max(35.0, max(pt.accuracyMeters, current.accuracyMeters) * 1.2)
            if d <= radius {
                dwellStart = pt.measuredAtSeconds
                if pt.transitionEvent == FootprintTransitionEvent.dwelled5m.rawValue {
                    confirmedDwellFloorSeconds = max(
                        confirmedDwellFloorSeconds,
                        dwellThresholdSeconds + max(0, current.measuredAt - pt.measuredAtSeconds)
                    )
                }
            } else {
                break
            }
        }
        if let ev = validLiveEvidence {
            dwellStart = min(dwellStart, ev.anchorStartedAt)
            if ev.confirmedDwelled5m {
                confirmedDwellFloorSeconds = max(confirmedDwellFloorSeconds, current.measuredAt - ev.anchorStartedAt)
            }
        }
        let rawDwellSeconds = max(current.measuredAt - dwellStart, confirmedDwellFloorSeconds)
        let dwellSec = max(0, Int(rawDwellSeconds.rounded()))
        let isDwelling = rawDwellSeconds >= dwellThresholdSeconds

        // Compute speed and course from sensor or last two points.
        var resolvedSpeed = current.speedMps
        var resolvedCourse = current.courseDegrees
        var recentStepDistance = 0.0
        var recentStepSpeed = 0.0
        if window.count >= 2 {
            let prev = window[window.count - 2]
            let dt = currentPoint.measuredAtSeconds - prev.measuredAtSeconds
            let dist = prev.distance(to: currentPoint)
            recentStepDistance = dist
            if dt > 0.5 && dt <= 600 {
                recentStepSpeed = dist / dt
                if resolvedSpeed == nil {
                    resolvedSpeed = recentStepSpeed
                }
                if resolvedCourse == nil && dist >= 10.0 {
                    resolvedCourse = FootprintPoint.bearingDegrees(
                        lat1: prev.latitude, lon1: prev.longitude,
                        lat2: currentPoint.latitude, lon2: currentPoint.longitude
                    )
                }
            }
        }

        let effectiveSpeed = resolvedSpeed ?? recentStepSpeed
        let motionState: FootprintMotionState
        if isDwelling && effectiveSpeed < 0.8 {
            motionState = .dwelling
        } else if effectiveSpeed >= 4.0 {
            motionState = .vehicle
        } else if effectiveSpeed >= 0.5 && (current.speedMps != nil || recentStepDistance >= 15.0) {
            motionState = .walking
        } else {
            motionState = .stationary
        }

        // Strict ACL: only compute heading_to_home if a "home" place exists in THIS agent's sharedPlaces.
        let homePlace = findHomePlace(in: sharedPlaces)
        var headingToHome: FootprintHeadingToHome?
        var distanceToHomeMeters: Double?
        if let homeCoord = homePlace?.coordinate, homeCoord.valid {
            let dNow = FootprintPoint.haversineMeters(
                lat1: current.latitude, lon1: current.longitude,
                lat2: homeCoord.latitude, lon2: homeCoord.longitude
            )
            distanceToHomeMeters = dNow.rounded()
            let homeRadius = max(80.0, current.accuracyMeters + homeCoord.accuracyMeters)
            if dNow <= homeRadius {
                headingToHome = .atHome
            } else if motionState == .stationary || motionState == .dwelling {
                headingToHome = .stationary
            } else if let anchor = window.first(where: { currentPoint.measuredAtSeconds - $0.measuredAtSeconds <= 900 && $0.pointID != currentPoint.pointID }) {
                let dPrev = FootprintPoint.haversineMeters(
                    lat1: anchor.latitude, lon1: anchor.longitude,
                    lat2: homeCoord.latitude, lon2: homeCoord.longitude
                )
                let delta = dNow - dPrev
                let moved = anchor.distance(to: currentPoint)
                if moved >= 20.0 {
                    if delta <= -15.0 {
                        headingToHome = .returning
                    } else if delta >= 15.0 {
                        headingToHome = .leaving
                    } else {
                        headingToHome = .passing
                    }
                } else {
                    headingToHome = .stationary
                }
            } else {
                headingToHome = .passing
            }
        }

        // Recent 15-minute cumulative movement summary.
        let recentMinTime = now - recentSummaryWindowSeconds
        let recentSlice = window.filter { $0.measuredAtSeconds >= recentMinTime }
        var recentMovement: RecentMovementSummary?
        if recentSlice.count >= 2 {
            var totalDist = 0.0
            for idx in 1..<recentSlice.count {
                let a = recentSlice[idx - 1]
                let b = recentSlice[idx]
                // Never sum across >120s gaps or different segments.
                if a.segmentID == b.segmentID && (b.measuredAtSeconds - a.measuredAtSeconds) <= FootprintIngestionEngine.maxGapSeconds {
                    totalDist += a.distance(to: b)
                }
            }
            if totalDist >= 20.0, let first = recentSlice.first {
                recentMovement = RecentMovementSummary(
                    distanceMeters: totalDist.rounded(),
                    startedAt: first.measuredAtSeconds,
                    pointCount: recentSlice.count
                )
            }
        }

        return LocalMovementSemantics(
            motionState: motionState,
            speedMps: resolvedSpeed,
            courseDegrees: resolvedCourse,
            dwelling: isDwelling,
            dwellSeconds: dwellSec,
            headingToHome: headingToHome,
            distanceToHomeMeters: distanceToHomeMeters,
            recentMovement: recentMovement
        )
    }

    public static func findHomePlace(in places: [LocationPlace]) -> LocationPlace? {
        places.first { place in
            guard place.configured, place.coordinate?.valid == true else { return false }
            let candidates = [place.name] + place.aliases
            return candidates.contains { raw in
                let normalized = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                return normalized == "家" || normalized == "home" || normalized == "家里" || normalized == "回家"
            }
        }
    }
}