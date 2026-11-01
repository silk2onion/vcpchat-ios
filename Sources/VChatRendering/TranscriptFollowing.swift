import Foundation

/// Only user scroll completion, not content reflow, can resume following.
public struct TranscriptFollowing: Equatable, Sendable {
    public enum Mode: Sendable { case following, reading, paused }
    public private(set) var mode = Mode.following
    public private(set) var interacting = false
    public var canScrollToLatest: Bool { mode == .following && !interacting }
    public init() {}
    public mutating func beginInteraction() {
        interacting = true
        if mode == .following { mode = .reading }
    }
    public mutating func endInteraction(atLatest: Bool) {
        interacting = false
        if mode != .paused { mode = atLatest ? .following : .reading }
    }
    public mutating func pause() { mode = .paused }
    public mutating func resume() { mode = .following }
    public mutating func reset() { self = Self() }
}
