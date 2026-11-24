import Foundation
import GRDB

public enum FootprintTrackingMode: String, Codable, Sendable, CaseIterable {
    case powerSaver = "power_saver"
    case continuous = "continuous"

    public var title: String {
        switch self {
        case .powerSaver: return "省电档（到访 + 大位移）"
        case .continuous: return "连续档（街道级轨迹）"
        }
    }

    public var detail: String {
        switch self {
        case .powerSaver: return "使用系统 CLVisit 与基站级大位移，近零耗电，适合记录去过哪、停留多久与离家/到家。"
        case .continuous: return "使用 iOS 17 系统连续定位与静止自动暂停，记录完整步行/乘车轨迹。"
        }
    }
}

public enum FootprintSyncFormat: String, Codable, Sendable, CaseIterable {
    case batchJSON = "batch_json"
    case owntracks = "owntracks"

    public var title: String {
        switch self {
        case .batchJSON: return "批量 JSON（VCP 足迹服务）"
        case .owntracks: return "OwnTracks HTTP JSON"
        }
    }
}

public enum FootprintAccuracyAuth: String, Codable, Sendable, Equatable {
    case full
    case reduced
}

public enum FootprintMotionState: String, Codable, Sendable, Equatable {
    case stationary
    case walking
    case vehicle
    case dwelling
}

public enum FootprintHeadingToHome: String, Codable, Sendable, Equatable {
    case atHome = "at_home"
    case leaving
    case returning
    case passing
    case stationary
}

public enum FootprintTransitionEvent: String, Codable, Sendable, Equatable {
    case leftHome = "left_home"
    case arrivedHome = "arrived_home"
    case startedMoving = "started_moving"
    case dwelled5m = "dwelled_5m"
    case visitArrival = "visit_arrival"
    case visitDeparture = "visit_departure"
}

public struct FootprintSettings: Codable, Sendable, Equatable {
    public var enabled: Bool
    public var mode: FootprintTrackingMode
    public var syncEnabled: Bool
    public var syncEndpointURL: String
    public var syncFormat: FootprintSyncFormat
    public var syncEligibleSince: Double?
    public var retentionDays: Int
    public var recoverableBackgroundSession: Bool
    public var deviceName: String

    public init(
        enabled: Bool = false,
        mode: FootprintTrackingMode = .powerSaver,
        syncEnabled: Bool = false,
        syncEndpointURL: String = "",
        syncFormat: FootprintSyncFormat = .batchJSON,
        syncEligibleSince: Double? = nil,
        retentionDays: Int = 365,
        recoverableBackgroundSession: Bool = false,
        deviceName: String = ""
    ) {
        self.enabled = enabled
        self.mode = mode
        self.syncEnabled = syncEnabled
        self.syncEndpointURL = syncEndpointURL
        self.syncFormat = syncFormat
        self.syncEligibleSince = syncEligibleSince
        self.retentionDays = max(7, min(3650, retentionDays))
        self.recoverableBackgroundSession = recoverableBackgroundSession
        self.deviceName = deviceName
    }

    private enum CodingKeys: String, CodingKey {
        case enabled, mode, syncEnabled, syncEndpointURL, syncFormat, syncEligibleSince, retentionDays, recoverableBackgroundSession, deviceName
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            enabled: try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? false,
            mode: try c.decodeIfPresent(FootprintTrackingMode.self, forKey: .mode) ?? .powerSaver,
            syncEnabled: try c.decodeIfPresent(Bool.self, forKey: .syncEnabled) ?? false,
            syncEndpointURL: try c.decodeIfPresent(String.self, forKey: .syncEndpointURL) ?? "",
            syncFormat: try c.decodeIfPresent(FootprintSyncFormat.self, forKey: .syncFormat) ?? .batchJSON,
            syncEligibleSince: try c.decodeIfPresent(Double.self, forKey: .syncEligibleSince),
            retentionDays: try c.decodeIfPresent(Int.self, forKey: .retentionDays) ?? 365,
            recoverableBackgroundSession: try c.decodeIfPresent(Bool.self, forKey: .recoverableBackgroundSession) ?? false,
            deviceName: try c.decodeIfPresent(String.self, forKey: .deviceName) ?? ""
        )
    }

    public func validatedHTTPSURL() -> URL? {
        let trimmed = syncEndpointURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              !trimmed.unicodeScalars.contains(where: { $0.value <= 31 }),
              !trimmed.contains("#"),
              let url = URL(string: trimmed),
              url.scheme?.lowercased() == "https",
              let host = url.host, !host.isEmpty,
              url.user == nil, url.password == nil else {
            return nil
        }
        return url
    }
}

public struct FootprintPoint: Codable, Sendable, Equatable, FetchableRecord, PersistableRecord, Identifiable {
    public static let databaseTableName = "footprint_points"

    public var pointID: String
    public var segmentID: String
    public var measuredAtMs: Int64
    public var latitude: Double
    public var longitude: Double
    public var accuracyMeters: Double
    public var speedMps: Double?
    public var courseDegrees: Double?
    public var accuracyAuth: FootprintAccuracyAuth
    public var motionState: FootprintMotionState?
    public var transitionEvent: String?
    public var source: String
    public var receivedAtMs: Int64

    public var id: String { pointID }

    public init(
        pointID: String = UUID().uuidString.lowercased(),
        segmentID: String,
        measuredAtMs: Int64,
        latitude: Double,
        longitude: Double,
        accuracyMeters: Double,
        speedMps: Double? = nil,
        courseDegrees: Double? = nil,
        accuracyAuth: FootprintAccuracyAuth,
        motionState: FootprintMotionState? = nil,
        transitionEvent: String? = nil,
        source: String = "live",
        receivedAtMs: Int64? = nil
    ) {
        self.pointID = pointID
        self.segmentID = segmentID
        self.measuredAtMs = measuredAtMs
        self.latitude = latitude
        self.longitude = longitude
        self.accuracyMeters = accuracyMeters
        self.speedMps = speedMps.flatMap { $0.isFinite && $0 >= 0 ? $0 : nil }
        self.courseDegrees = courseDegrees.flatMap { $0.isFinite && $0 >= 0 && $0 <= 360 ? $0 : nil }
        self.accuracyAuth = accuracyAuth
        self.motionState = motionState
        self.transitionEvent = transitionEvent
        self.source = source
        self.receivedAtMs = receivedAtMs ?? measuredAtMs
    }

    public var measuredAtSeconds: Double { Double(measuredAtMs) / 1000.0 }

    public var valid: Bool {
        latitude.isFinite && longitude.isFinite && accuracyMeters.isFinite
            && (-90...90).contains(latitude) && (-180...180).contains(longitude)
            && accuracyMeters >= 0
    }

    public func distance(to other: Self) -> Double {
        Self.haversineMeters(lat1: latitude, lon1: longitude, lat2: other.latitude, lon2: other.longitude)
    }

    public static func haversineMeters(lat1: Double, lon1: Double, lat2: Double, lon2: Double) -> Double {
        let radians = Double.pi / 180.0
        let a = lat1 * radians
        let b = lat2 * radians
        let dLat = (lat2 - lat1) * radians
        let dLon = (lon2 - lon1) * radians
        let h = pow(sin(dLat / 2), 2) + cos(a) * cos(b) * pow(sin(dLon / 2), 2)
        return 6_371_000.0 * 2.0 * asin(sqrt(min(1.0, max(0.0, h))))
    }

    public static func bearingDegrees(lat1: Double, lon1: Double, lat2: Double, lon2: Double) -> Double {
        let rad = Double.pi / 180.0
        let phi1 = lat1 * rad
        let phi2 = lat2 * rad
        let dLon = (lon2 - lon1) * rad
        let y = sin(dLon) * cos(phi2)
        let x = cos(phi1) * sin(phi2) - sin(phi1) * cos(phi2) * cos(dLon)
        let deg = atan2(y, x) * 180.0 / Double.pi
        return (deg + 360.0).truncatingRemainder(dividingBy: 360.0)
    }
}

public struct FootprintOutboxItem: Codable, Sendable, Equatable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "footprint_outbox"

    public var pointID: String
    public var segmentID: String
    public var measuredAtMs: Int64
    public var clearEpoch: Int64
    public var accuracyAuth: FootprintAccuracyAuth
    public var destinationKey: String
    public var payloadJSON: Data
    public var attempts: Int
    public var nextRetryAtMs: Int64
    public var createdAtMs: Int64

    public init(
        pointID: String,
        segmentID: String,
        measuredAtMs: Int64,
        clearEpoch: Int64,
        accuracyAuth: FootprintAccuracyAuth,
        destinationKey: String,
        payloadJSON: Data,
        attempts: Int = 0,
        nextRetryAtMs: Int64 = 0,
        createdAtMs: Int64
    ) {
        self.pointID = pointID
        self.segmentID = segmentID
        self.measuredAtMs = measuredAtMs
        self.clearEpoch = clearEpoch
        self.accuracyAuth = accuracyAuth
        self.destinationKey = destinationKey
        self.payloadJSON = payloadJSON
        self.attempts = attempts
        self.nextRetryAtMs = nextRetryAtMs
        self.createdAtMs = createdAtMs
    }
}

public struct FootprintSegment: Sendable, Equatable, Identifiable {
    public let id: String
    public let points: [FootprintPoint]
    public let startMs: Int64
    public let endMs: Int64
    public let distanceMeters: Double
    public let accuracyAuth: FootprintAccuracyAuth

    public var isPolylineDrawable: Bool {
        accuracyAuth == .full && points.count >= 2
    }

    public init(id: String, points: [FootprintPoint], precomputedDistance: Double? = nil) {
        self.id = id
        self.points = points
        self.startMs = points.first?.measuredAtMs ?? 0
        self.endMs = points.last?.measuredAtMs ?? 0
        self.accuracyAuth = points.first?.accuracyAuth ?? .reduced
        if let precomputedDistance {
            self.distanceMeters = precomputedDistance
        } else if self.accuracyAuth == .full && points.count >= 2 {
            var total = 0.0
            for index in 1..<points.count {
                total += points[index - 1].distance(to: points[index])
            }
            self.distanceMeters = total
        } else {
            self.distanceMeters = 0
        }
    }
}

public struct FootprintPeriodSummary: Sendable, Equatable {
    public let pointCount: Int
    public let segmentCount: Int
    public let activeDays: Int
    public let totalDistanceMeters: Double

    public init(pointCount: Int, segmentCount: Int, activeDays: Int, totalDistanceMeters: Double) {
        self.pointCount = pointCount
        self.segmentCount = segmentCount
        self.activeDays = activeDays
        self.totalDistanceMeters = totalDistanceMeters
    }
}

public enum FootprintTimelineScope: String, Codable, Sendable, CaseIterable {
    case day
    case month
    case year

    public var title: String {
        switch self {
        case .day: return "按天"
        case .month: return "按月"
        case .year: return "全年"
        }
    }

    public func rangeMs(around anchor: Date, calendar: Calendar = .current) -> (fromMs: Int64, toMs: Int64) {
        let start: Date
        let end: Date
        switch self {
        case .day:
            start = calendar.startOfDay(for: anchor)
            end = calendar.date(byAdding: .day, value: 1, to: start) ?? start.addingTimeInterval(86_400)
        case .month:
            let comps = calendar.dateComponents([.year, .month], from: anchor)
            start = calendar.date(from: comps) ?? calendar.startOfDay(for: anchor)
            end = calendar.date(byAdding: .month, value: 1, to: start) ?? start.addingTimeInterval(86_400 * 31)
        case .year:
            let comps = calendar.dateComponents([.year], from: anchor)
            start = calendar.date(from: comps) ?? calendar.startOfDay(for: anchor)
            end = calendar.date(byAdding: .year, value: 1, to: start) ?? start.addingTimeInterval(86_400 * 366)
        }
        return (Int64((start.timeIntervalSince1970 * 1000.0).rounded()), Int64((end.timeIntervalSince1970 * 1000.0).rounded()) - 1)
    }
}

public enum FootprintGeoJSONExporter {
    /// Exports segments strictly without connecting across segment_id boundaries.
    /// Reduced-accuracy points are emitted as Point features, never as road polylines.
    public static func export(segments: [FootprintSegment]) throws -> Data {
        let iso = ISO8601DateFormatter()
        var features: [JSONValue] = []
        for segment in segments where !segment.points.isEmpty {
            if segment.isPolylineDrawable {
                let coords: [JSONValue] = segment.points.map { pt in
                    .array([.number(pt.longitude), .number(pt.latitude)])
                }
                let props: [String: JSONValue] = [
                    "segment_id": .string(segment.id),
                    "accuracy_auth": .string(segment.accuracyAuth.rawValue),
                    "point_count": .number(Double(segment.points.count)),
                    "distance_m": .number(segment.distanceMeters.rounded()),
                    "start_at": .string(iso.string(from: Date(timeIntervalSince1970: Double(segment.startMs) / 1000.0))),
                    "end_at": .string(iso.string(from: Date(timeIntervalSince1970: Double(segment.endMs) / 1000.0)))
                ]
                features.append(.object([
                    "type": .string("Feature"),
                    "geometry": .object([
                        "type": .string("LineString"),
                        "coordinates": .array(coords)
                    ]),
                    "properties": .object(props)
                ]))
            } else {
                for pt in segment.points {
                    var props: [String: JSONValue] = [
                        "point_id": .string(pt.pointID),
                        "segment_id": .string(pt.segmentID),
                        "accuracy_auth": .string(pt.accuracyAuth.rawValue),
                        "accuracy_m": .number(pt.accuracyMeters),
                        "measured_at": .string(iso.string(from: Date(timeIntervalSince1970: pt.measuredAtSeconds))),
                        "source": .string(pt.source)
                    ]
                    if let motion = pt.motionState { props["motion_state"] = .string(motion.rawValue) }
                    if let event = pt.transitionEvent { props["transition_event"] = .string(event) }
                    features.append(.object([
                        "type": .string("Feature"),
                        "geometry": .object([
                            "type": .string("Point"),
                            "coordinates": .array([.number(pt.longitude), .number(pt.latitude)])
                        ]),
                        "properties": .object(props)
                    ]))
                }
            }
        }
        let root: JSONValue = .object([
            "type": .string("FeatureCollection"),
            "features": .array(features)
        ])
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(root)
    }
}