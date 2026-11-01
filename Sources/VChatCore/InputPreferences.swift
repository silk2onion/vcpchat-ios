import Foundation
public struct InputPreferences: Codable, Sendable, Equatable {
    public var enterSends = false
    public init() {}
}

/// Request policy, independent of the display renderer. Existing installations opt in.
public struct OutputPreferences: Codable, Sendable, Equatable {
    public var animatedBubbles = false
    public init() {}
}
