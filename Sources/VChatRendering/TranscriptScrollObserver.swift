import SwiftUI

public enum TranscriptScrollEvent: Equatable, Sendable {
    case began
    case ended(atLatest: Bool)
}

/// Observe the existing scroll view. Never replace its delegate or add a competing pan gesture.
public struct TranscriptScrollObserver: View {
    private let action: @MainActor (TranscriptScrollEvent) -> Void
    public init(action: @escaping @MainActor (TranscriptScrollEvent) -> Void) { self.action = action }
    public var body: some View { NativeScrollObserver(action: action).frame(width: 0,height: 0).accessibilityHidden(true) }
}

#if os(iOS)
import UIKit

private struct NativeScrollObserver: UIViewRepresentable {
    let action: @MainActor (TranscriptScrollEvent) -> Void
    func makeUIView(context: Context) -> ScrollProbe { let view = ScrollProbe(); view.isUserInteractionEnabled = false; view.action = action; return view }
    func updateUIView(_ uiView: ScrollProbe, context: Context) { uiView.action = action; uiView.connect() }
    static func dismantleUIView(_ uiView: ScrollProbe, coordinator: ()) { uiView.disconnect() }
}
@MainActor private final class ScrollProbe: UIView {
    var action: ((TranscriptScrollEvent) -> Void)?
    private weak var scroll: UIScrollView?
    private var observation: NSKeyValueObservation?
    private var displayLink: CADisplayLink?
    private var active = false
    override func didMoveToWindow() { super.didMoveToWindow(); if window == nil { disconnect() } else { connect() } }
    override func didMoveToSuperview() { super.didMoveToSuperview(); connect() }
    func connect() {
        guard window != nil,scroll == nil else { return }
        var parent = superview
        while let view = parent {
            if let target = view as? UIScrollView {
                scroll = target
                target.panGestureRecognizer.addTarget(self,action: #selector(panned(_:)))
                observation = target.observe(\.contentOffset,options: [.new]) { [weak self] _,_ in
                    // UIKit scroll geometry and this target are confined to the main run loop.
                    MainActor.assumeIsolated {
                        if let view = self?.scroll,view.isTracking || view.isDragging || view.isDecelerating { self?.begin() }
                    }
                }
                return
            }
            parent = view.superview
        }
    }
    func disconnect() {
        observation?.invalidate(); observation = nil
        scroll?.panGestureRecognizer.removeTarget(self,action: #selector(panned(_:)))
        displayLink?.invalidate(); displayLink = nil; scroll = nil; active = false
    }
    @objc private func panned(_ gesture: UIPanGestureRecognizer) {
        if gesture.state == .began || gesture.state == .changed { begin() }
    }
    private func begin() {
        if !active { active = true; action?(.began) }
        if displayLink == nil {
            let link = CADisplayLink(target: self,selector: #selector(checkForIdle))
            displayLink = link; link.add(to: .main,forMode: .common)
        }
    }
    @objc private func checkForIdle() {
        guard let scroll else { disconnect(); return }
        let pan = scroll.panGestureRecognizer.state
        guard !scroll.isTracking,!scroll.isDragging,!scroll.isDecelerating,pan != .began,pan != .changed else { return }
        displayLink?.invalidate(); displayLink = nil
        if active {
            active = false
            let remaining = scroll.contentSize.height + scroll.adjustedContentInset.bottom - scroll.bounds.height - scroll.contentOffset.y
            action?(.ended(atLatest: remaining <= 24))
        }
    }
}
#else
import AppKit

private struct NativeScrollObserver: NSViewRepresentable {
    let action: @MainActor (TranscriptScrollEvent) -> Void
    func makeNSView(context: Context) -> ScrollProbe { let view = ScrollProbe(); view.action = action; return view }
    func updateNSView(_ nsView: ScrollProbe, context: Context) { nsView.action = action; nsView.connect() }
    static func dismantleNSView(_ nsView: ScrollProbe, coordinator: ()) { nsView.disconnect() }
}
@MainActor private final class ScrollProbe: NSView {
    var action: ((TranscriptScrollEvent) -> Void)?
    private weak var scroll: NSScrollView?
    private var tokens: [NSObjectProtocol] = []
    private var active = false
    private var live = false
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); if window == nil { disconnect() } else { connect() } }
    override func viewDidMoveToSuperview() { super.viewDidMoveToSuperview(); connect() }
    func connect() {
        guard window != nil,scroll == nil,let target = enclosingScrollView else { return }
        scroll = target
        let center = NotificationCenter.default
        for name in [NSScrollView.willStartLiveScrollNotification,NSScrollView.didLiveScrollNotification,NSScrollView.didEndLiveScrollNotification] {
            tokens.append(center.addObserver(forName: name,object: target,queue: .main) { [weak self] note in
                let eventName = note.name
                MainActor.assumeIsolated { self?.observe(eventName) }
            })
        }
    }
    func disconnect() {
        for token in tokens { NotificationCenter.default.removeObserver(token) }
        tokens = []; scroll = nil; active = false; live = false
    }
    private func begin() { if !active { active = true; action?(.began) } }
    private func finish() {
        guard active,let scroll,let document = scroll.documentView else { return }
        active = false
        let visible = scroll.documentVisibleRect
        let remaining = document.isFlipped ? document.bounds.maxY - visible.maxY : visible.minY - document.bounds.minY
        action?(.ended(atLatest: remaining <= 24))
    }
    private func observe(_ name: Notification.Name) {
        if name == NSScrollView.willStartLiveScrollNotification { live = true; begin() }
        else if name == NSScrollView.didEndLiveScrollNotification { live = false; finish() }
        else {
            begin()
            // Legacy mouse wheels send didLiveScroll without a start/end pair.
            if !live { DispatchQueue.main.async { [weak self] in if self?.live == false { self?.finish() } } }
        }
    }
}
#endif
