import SwiftUI
import WebKit
import Observation

public enum IslandSection: Sendable, Equatable {
    case markdown(String)
    case island(String)
}
public enum HTMLIslandPolicy {
    public static let root = "<div id=\"vcp-root\">"
    public static func accepts(_ source: String) -> Bool {
        // Read just the first opening tag. Attribute order and CSS do not change
        // a root's identity; attribute text containing a fake id does not count.
        let prefix = String(source.prefix(8192))
        let scanner = Scanner(string: prefix)
        scanner.charactersToBeSkipped = nil; scanner.caseSensitive = false
        let whitespace = CharacterSet.whitespacesAndNewlines
        _ = scanner.scanCharacters(from: whitespace.union(CharacterSet(charactersIn: "\u{FEFF}")))
        let indentation = prefix[..<scanner.currentIndex].components(separatedBy: .newlines).last ?? ""
        guard !indentation.contains("\t"),indentation.filter({ $0 != "\u{FEFF}" }).count < 4,
              scanner.scanString("<") != nil,scanner.scanString("div") != nil else { return false }
        let names = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_:-.")
        let unquoted = whitespace.union(CharacterSet(charactersIn: "\"'`=<>")).inverted
        var rootID: String?
        while !scanner.isAtEnd {
            let separator = scanner.scanCharacters(from: whitespace)
            if scanner.scanString(">") != nil { return rootID == "vcp-root" }
            guard separator != nil,let name = scanner.scanCharacters(from: names) else { return false }
            let afterName = scanner.currentIndex
            _ = scanner.scanCharacters(from: whitespace)
            var value: String?
            if scanner.scanString("=") != nil {
                _ = scanner.scanCharacters(from: whitespace)
                if let quote = scanner.scanString("\"") ?? scanner.scanString("'") {
                    value = scanner.scanUpToString(quote) ?? ""
                    guard scanner.scanString(quote) != nil else { return false }
                } else {
                    guard let raw = scanner.scanCharacters(from: unquoted) else { return false }
                    value = raw
                }
            } else { scanner.currentIndex = afterName }
            if name.lowercased() == "id" {
                guard rootID == nil,let value else { return false }
                rootID = value
            }
        }
        return false
    }
    public static func containsIsland(_ source: String) -> Bool {
        guard source.localizedCaseInsensitiveContains("<div") else { return false }
        let sections = extractSections(from: source)
        return sections.contains { if case .island = $0 { return true }; return false }
    }

    /// Extract mixed markdown and embedded HTML visual islands from prose.
    public static func extractSections(from source: String) -> [IslandSection] {
        guard source.localizedCaseInsensitiveContains("<div") else { return [.markdown(source)] }
        let s = source as NSString
        let literalRanges = (codeFences(source) + opaqueDomains.matches(in:source,range:NSRange(location:0,length:s.length)).map(\.range)).sorted { $0.location < $1.location }
        var literalIndex = 0
        let matches = openingDiv.matches(in:source,range:NSRange(location:0,length:s.length))
        var sections: [IslandSection] = []
        var cursor = 0
        for m in matches {
            let divStart = m.range.location
            if divStart < cursor { continue }
            if divStart > 0, s.character(at:divStart-1) == 92 { continue }
            var precedingSpace=divStart
            while precedingSpace > 0, [9,32].contains(s.character(at:precedingSpace-1)) { precedingSpace -= 1 }
            if precedingSpace == 0 || s.character(at:precedingSpace-1) == 10 {
                let indentation=s.substring(with:NSRange(location:precedingSpace,length:divStart-precedingSpace))
                if indentation.contains("\t") || indentation.count >= 4 { continue }
            }
            // Skip root divs inside code fences
            while literalIndex < literalRanges.count, NSMaxRange(literalRanges[literalIndex]) <= divStart { literalIndex += 1 }
            if literalIndex < literalRanges.count, NSLocationInRange(divStart,literalRanges[literalIndex]) { continue }
            let opening=s.substring(with:m.range)
            let explicit=accepts(opening)
            let startOfLine = divStart==0 || s.character(at:divStart-1)==10
            guard explicit || startOfLine else { continue }

            // Pull in preceding <style>...</style> if tightly attached
            let islandStart = findStylePrefix(in: s, after: cursor, before: divStart)

            // Balance <div> depth starting from after this root div opening tag
            let divOpenEnd = NSMaxRange(m.range)
            let divEnd = balanceDiv(in: s, from: divOpenEnd)
            let islandEnd = attachedAssetsEnd(in: s, from: divEnd)
            if !explicit {
                guard islandEnd-divStart <= 256*1024 else { continue }
                let card=s.substring(with:NSRange(location: divStart,length:islandEnd-divStart))
                guard card.utf8.count<=256*1024,
                      card.range(of:#"(?i)<(?:canvas|script|style|img|svg)\b"#,options:.regularExpression) != nil else { continue }
            }

            let preceding = s.substring(with: NSRange(location: cursor, length: islandStart - cursor))
            if !preceding.isEmpty {
                sections.append(.markdown(preceding))
            }

            let islandHtml = s.substring(with: NSRange(location: islandStart, length: islandEnd - islandStart))
            sections.append(.island(islandHtml))
            cursor = islandEnd
        }

        if cursor < s.length {
            let trailing = s.substring(from: cursor)
            if !trailing.isEmpty {
                sections.append(.markdown(trailing))
            }
        }
        return sections.isEmpty ? [.markdown(source)] : sections
    }

    private static let opaqueDomains = try! NSRegularExpression(pattern: #"(?is)<!--.*?(?:-->|$)|<(script|style|code|pre|textarea)\b(?:"[^"]*"|'[^']*'|[^'">])*>.*?(?:</\1\s*>|$)|(`+)(?!`).*?\2(?!`)"#)
    private static let openingDiv = try! NSRegularExpression(pattern: #"(?i)<div\b(?:"[^"]*"|'[^']*'|[^'">])*>"#)
    static func codeFences(_ source: String) -> [NSRange] {
        var ranges: [NSRange] = []; var opened: (Int, String, Int)?; var offset = 0
        let s = source as NSString
        for raw in source.components(separatedBy: "\n") {
            let line = raw.hasSuffix("\r") ? String(raw.dropLast()) : raw
            if let (start, marker, count) = opened {
                if let m = matchPattern("^ {0,3}(`+|~+)[ \\t]*$", line), m.count > 1, m[1].hasPrefix(marker), m[1].count >= count {
                    ranges.append(NSRange(location: start, length: min(s.length, offset + raw.utf16.count + 1) - start))
                    opened = nil
                }
            } else if let m = matchPattern("^ {0,3}(`{3,}|~{3,})(.*)$", line), m.count > 2, !(m[1].hasPrefix("`") && m[2].contains("`")) {
                opened = (offset, String(m[1].prefix(1)), m[1].count)
            }
            offset += raw.utf16.count + 1
        }
        if let (start, _, _) = opened { ranges.append(NSRange(location: start, length: s.length - start)) }
        return ranges
    }

    private static func matchPattern(_ pattern: String, _ text: String) -> [String]? {
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let m = regex.firstMatch(in: text, range: NSRange(location: 0, length: text.utf16.count)) else { return nil }
        let s = text as NSString
        return (0..<m.numberOfRanges).map { m.range(at: $0).location == NSNotFound ? "" : s.substring(with: m.range(at: $0)) }
    }

    private static func findStylePrefix(in s: NSString, after lowerBound: Int, before divIndex: Int) -> Int {
        guard lowerBound < divIndex,
              let regex = try? NSRegularExpression(pattern: #"(?is)<style\b[^>]*>.*?</style\s*>"#) else { return divIndex }
        let searchRange = NSRange(location: lowerBound, length: divIndex - lowerBound)
        var cursor = divIndex
        for match in regex.matches(in: s as String, range: searchRange).reversed() {
            let end = NSMaxRange(match.range)
            let gap = NSRange(location: end, length: cursor - end)
            guard s.rangeOfCharacter(from: CharacterSet.whitespacesAndNewlines.inverted, range: gap).location == NSNotFound else { break }
            cursor = match.range.location
        }
        return cursor
    }

    private static func balanceDiv(in s: NSString, from start: Int) -> Int {
        let tagPattern = #"(?is)<!--[\s\S]*?(?:-->|$)|<(script|style|pre|code|textarea)\b(?:"[^"]*"|'[^']*'|[^'">])*>[\s\S]*?(?:</\1\s*>|$)|<(/?)([a-z][a-z0-9:-]*)(?:"[^"]*"|'[^']*'|[^'">])*>"#
        guard let regex = try? NSRegularExpression(pattern: tagPattern) else { return s.length }
        var depth = 1
        var cursor = start
        while cursor < s.length {
            guard let m = regex.firstMatch(in: s as String, range: NSRange(location: cursor, length: s.length - cursor)) else { break }
            let matchedTag = s.substring(with: m.range)
            cursor = NSMaxRange(m.range)
            // Skip comments and raw containers
            if matchedTag.hasPrefix("<!--") || m.range(at: 1).location != NSNotFound { continue }
            guard m.range(at: 3).location != NSNotFound else { continue }
            let tagName = s.substring(with: m.range(at: 3)).lowercased()
            if tagName == "div" {
                let isClosing = m.range(at: 2).location != NSNotFound && s.substring(with: m.range(at: 2)) == "/"
                depth += isClosing ? -1 : 1
                if depth <= 0 { return cursor }
            }
        }
        return s.length
    }

    private static let trailingAsset = try! NSRegularExpression(
        pattern: #"(?is)\s*<(script|style)(?=[\s>])(?:"[^"]*"|'[^']*'|[^'">])*>.*?</\1\s*>"#
    )
    private static func attachedAssetsEnd(in text: NSString, from start: Int) -> Int {
        var end = start
        var stylePrefix: Int?
        while end < text.length,
              let match = trailingAsset.firstMatch(in: text as String, options: .anchored,
                                                   range: NSRange(location: end, length: text.length - end)) {
            if text.substring(with: match.range(at: 1)).lowercased() == "style" {
                stylePrefix = stylePrefix ?? end
            } else { stylePrefix = nil }
            end = NSMaxRange(match.range)
        }
        // Styles immediately before the next card belonged to that card before tail assets were supported.
        if let stylePrefix, end < text.length {
            let rest = NSRange(location: end, length: text.length - end)
            let next = text.rangeOfCharacter(from: CharacterSet.whitespacesAndNewlines.inverted, range: rest).location
            if next != NSNotFound, let tag = openingDiv.firstMatch(in: text as String, options: .anchored,
                range: NSRange(location: next, length: text.length - next)), accepts(text.substring(with: tag.range)) {
                return stylePrefix
            }
        }
        return end
    }

    public static func document(_ source: String, motion: Bool, media: Bool, dark: Bool, emphasisColor: String? = nil) -> String {
        let color = dark ? "dark" : "light"
        let image = media ? "https: data: vchat-image:" : "'none'"
        let emphasis = emphasisColor ?? (dark ? "#88d6b0" : "#278752")
        let noMotion = motion ? "" : "*,*::before,*::after{animation:none!important;transition:none!important;scroll-behavior:auto!important}"
        return """
        <!doctype html><html data-vcp-host-theme="\(color)"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1,maximum-scale=1,user-scalable=no"><meta http-equiv="Content-Security-Policy" content="default-src 'none'; script-src 'unsafe-inline'; style-src 'unsafe-inline'; img-src \(image); media-src \(media ? "https: data:" : "'none'"); font-src data:; connect-src 'none'; frame-src 'none'; object-src 'none'; base-uri 'none'; form-action 'none'"><style>:root{color-scheme:\(color)}html,body{background:transparent;color:CanvasText;margin:0;padding:0;font:16px -apple-system;overflow-wrap:anywhere}#vcp-root{max-width:100%;box-sizing:border-box}img,video,svg,canvas{max-width:100%}img{-webkit-touch-callout:none}img.vcp-standalone-photo{display:block;width:100%!important;height:auto!important;max-height:720px;object-fit:contain}pre{white-space:pre-wrap}:root{--vcp-md-emphasis:\(emphasis)}strong.vcp-md-strong{color:var(--vcp-md-emphasis);font-weight:700}\(noMotion)</style></head><body>\(source)</body></html>
        """
    }
}

extension WKWebView {
    /// Xcode 16.4's Swift WebKit overlay isn't present on every supported simulator runtime.
    @MainActor func runIslandScript(_ script: String, arguments: [String: Any]) async throws {
        try await withCheckedThrowingContinuation { (reply: CheckedContinuation<Void, any Error>) in
            self.__callAsyncJavaScript(script, arguments: arguments, inFrame: nil, in: .defaultClient) { _, error in
                if let error { reply.resume(throwing: error) } else { reply.resume() }
            }
        }
    }
}

enum IslandScripts {
    static let runtime: String? = load(["marked.min", "morphdom.min", "bubble-markdown", "bubble-stream"])
    static func load(_ names: [String]) -> String? {
        var scripts: [String] = []
        for name in names {
            guard let url = Bundle.module.url(forResource: name,withExtension: "js"),let source = try? String(contentsOf: url,encoding: .utf8) else { return nil }
            scripts.append(source)
        }
        return scripts.joined(separator: "\n;\n")
    }
}

private struct ViewportKey: EnvironmentKey { static let defaultValue: CGRect? = nil }
extension EnvironmentValues { public var messageViewport: CGRect? { get { self[ViewportKey.self] } set { self[ViewportKey.self] = newValue } } }
@MainActor @Observable private final class IslandPool {
    static let shared = IslandPool()
    private var idle: [WKWebView] = []
    private var active: [UUID: WKWebView] = [:]
    var revision = 0
    func take(_ id: UUID) -> WKWebView? {
        if let view = active[id] { return view }
        guard active.count < 3 else { return nil }
        let view: WKWebView
        if let reusable = idle.popLast() { view = reusable }
        else {
            let config = WKWebViewConfiguration(); config.websiteDataStore = .nonPersistent()
            config.setURLSchemeHandler(IslandImageScheme(),forURLScheme:IslandImageScheme.name)
            config.preferences.javaScriptCanOpenWindowsAutomatically = false
            #if os(iOS)
            config.allowsInlineMediaPlayback = true; config.mediaTypesRequiringUserActionForPlayback = .all
            #endif
            view = WKWebView(frame: .zero, configuration: config)
            #if os(iOS)
            view.isOpaque = false; view.backgroundColor = .clear; view.scrollView.isScrollEnabled = false
            view.scrollView.showsVerticalScrollIndicator = false
            view.scrollView.pinchGestureRecognizer?.isEnabled = false
            #else
            view.underPageBackgroundColor = .clear
            #endif
        }
        active[id] = view
        return view
    }
    func release(_ id: UUID) {
        guard let view = active.removeValue(forKey: id) else { return }
        view.stopLoading(); (view.configuration.urlSchemeHandler(forURLScheme:IslandImageScheme.name) as? IslandImageScheme)?.invalidate(); view.setAllMediaPlaybackSuspended(true)
        view.navigationDelegate = nil; view.uiDelegate = nil
        view.configuration.userContentController.removeAllScriptMessageHandlers()
        view.configuration.userContentController.removeAllUserScripts()
        view.loadHTMLString("", baseURL: nil)
        if idle.count < 3 { idle.append(view) }
        revision += 1
    }
}
@MainActor @Observable private final class IslandController: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
    private struct Input: Equatable { var source: String; var streaming: Bool }
    let id = UUID()
    var view: WKWebView?
    var height: CGFloat = 180
    var failed = false
    var failureMessage = "气泡已暂停，重新进入可加载"
    @ObservationIgnored private var document = ""
    @ObservationIgnored private var generation = UUID()
    @ObservationIgnored private var navigation: WKNavigation?
    @ObservationIgnored private var ready = false
    @ObservationIgnored private var latest: Input?
    @ObservationIgnored private var pending: Input?
    @ObservationIgnored private var updateTask: Task<Void,Never>?
    func mount(_ document: String, source: String, streaming: Bool, media: Bool, stickers: StickerContext) {
        guard let runtime = IslandScripts.runtime else { failed = true; failureMessage = "气泡渲染组件缺失，请更新 App"; return }
        guard let web = view ?? IslandPool.shared.take(id) else { return }
        let imageScheme=web.configuration.urlSchemeHandler(forURLScheme:IslandImageScheme.name) as? IslandImageScheme
        let contextChanged=imageScheme?.stickers != stickers
        imageScheme?.stickers=stickers;imageScheme?.mediaEnabled=media
        let input = Input(source: source,streaming: streaming)
        let editingCompleted = latest.map { $0.source != input.source && (!$0.streaming || !input.source.hasPrefix($0.source)) } ?? false
        if view != nil,self.document == document,!editingCompleted,!contextChanged {
            if latest != input { latest = input; pending = input; drain() }
            return
        }
        updateTask?.cancel(); updateTask = nil; generation = UUID(); ready = false
        view = web; self.document = document; latest = input; pending = input; failed = false
        web.configuration.userContentController.removeAllScriptMessageHandlers()
        web.configuration.userContentController.removeAllUserScripts()
        web.configuration.userContentController.add(self,contentWorld: .defaultClient,name: "vcpHeight")
        // The isolated host world exposes only measured height, never native commands.
        let epoch = generation.uuidString
        let script = "window.VCPBubbleEpoch='" + epoch + "';\n" + runtime + "\n;" + """
        (()=>{let previous=0;const epoch='\(epoch)';const measure=()=>{let h=Math.ceil(document.body.getBoundingClientRect().height);if(h!==previous){previous=h;window.webkit.messageHandlers.vcpHeight.postMessage({height:h,epoch})}};new ResizeObserver(measure).observe(document.body);measure()})();
        """
        web.configuration.userContentController.addUserScript(WKUserScript(source: script,injectionTime: .atDocumentEnd,forMainFrameOnly: true,in: .defaultClient))
        web.navigationDelegate = self; web.setAllMediaPlaybackSuspended(!media)
        navigation = web.loadHTMLString(document,baseURL: nil)
    }
    func webView(_ webView: WKWebView,didFinish navigation: WKNavigation!) {
        guard webView === view,navigation === self.navigation else { return }
        ready = true; drain()
    }
    private func drain() {
        guard ready,updateTask == nil,let web = view,pending != nil else { return }
        let own = generation
        updateTask = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled,generation == own,let input = pending {
                pending = nil
                do {
                    try await web.runIslandScript("window.VCPBubbleStream.update(source,streaming,epoch)",
                        arguments: ["source":input.source, "streaming":input.streaming, "epoch":own.uuidString])
                } catch {
                    if generation == own,!Task.isCancelled { failed = true; failureMessage = "气泡更新失败，重新进入可加载"; unmount() }
                    break
                }
            }
            if generation == own { updateTask = nil }
        }
    }
    func unmount() {
        generation = UUID(); updateTask?.cancel(); updateTask = nil; pending = nil; latest = nil; ready = false; navigation = nil
        view = nil; document = ""; IslandPool.shared.release(id)
    }
    func userContentController(_ userContentController: WKUserContentController,didReceive message: WKScriptMessage) {
        guard message.frameInfo.isMainFrame,let payload = message.body as? [String:Any],payload["epoch"] as? String == generation.uuidString,let number = payload["height"] as? NSNumber else { return }
        let value = number.doubleValue
        if value.isFinite { height = max(44,value) }
    }
    func webView(_ webView: WKWebView,decidePolicyFor navigationAction: WKNavigationAction,decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void) {
        decisionHandler(navigationAction.request.url?.absoluteString == "about:blank" && navigationAction.navigationType == .other ? .allow : .cancel)
    }
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) { failed = true; unmount() }
}

struct HTMLIsland: View {
    @Environment(\.self) private var environment
    @Environment(\.messageEmphasisColor) private var emphasisColor
    var source: String
    var options: RenderOptions
    var streaming = false
    @State private var controller = IslandController()
    @State private var bounds = CGRect.zero
    #if os(iOS)
    @State private var selectedPhoto: CardPhoto?
    #endif
    @State private var appeared = false
    @Environment(\.messageViewport) private var viewport
    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var phase
    @Environment(\.stickerContext) private var stickers
    @Environment(\.messageLongPressAction) private var showMessageActions
    private var visible: Bool { appeared && phase == .active && (viewport?.intersects(bounds) ?? true) }
    private var document: String {
        let color = emphasisColor.resolve(in: environment)
        let hex = String(format: "#%02x%02x%02x",Int(min(1,max(0,color.red)) * 255),Int(min(1,max(0,color.green)) * 255),Int(min(1,max(0,color.blue)) * 255))
        return HTMLIslandPolicy.document("",motion: options.motion && !reduceMotion,media: options.media,dark: scheme == .dark,emphasisColor: hex)
    }
    #if os(iOS)
    private var selectCardPhoto: (@MainActor (CardPhoto) -> Void)? {
        guard options.media else { return nil }
        return { (photo: CardPhoto) in selectedPhoto = photo }
    }
    #endif
    @ViewBuilder private var surface: some View {
        if let view = controller.view {
            #if os(iOS)
            IslandNativeView(view: view, showActions: showMessageActions, selectPhoto: selectCardPhoto)
                .id(ObjectIdentifier(view)).frame(height: controller.height)
            #else
            IslandNativeView(view: view, showActions: showMessageActions)
                .id(ObjectIdentifier(view)).frame(height: controller.height)
            #endif
        } else if controller.failed {
            Label(controller.failureMessage, systemImage: "arrow.clockwise").font(.callout).frame(height: controller.height)
        } else {
            Label(visible ? "等待加载视觉气泡" : "视觉气泡已暂停", systemImage: "rectangle.inset.filled").font(.caption).foregroundStyle(.secondary).frame(maxWidth: .infinity).frame(height: controller.height)
        }
    }
    private var photoSurface: some View {
        #if os(iOS)
        surface.sheet(item: $selectedPhoto) { (photo: CardPhoto) in
            CardPhotoPreview(photo: photo, stickers: stickers)
        }
        #else
        surface
        #endif
    }
    var body: some View {
        photoSurface
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .onGeometryChange(for: CGRect.self,of: { $0.frame(in: .named("vcp-message-viewport")) }) { bounds = $0 }
        .onAppear { appeared = true; refresh() }.onDisappear { appeared = false; controller.unmount() }
        .onChange(of: visible) { _, _ in refresh() }
        .onChange(of: stickers) { _, _ in refresh() }
        .onChange(of: document) { _, _ in refresh() }
        .onChange(of: source) { _, _ in refresh() }
        .onChange(of: streaming) { _, _ in refresh() }
        .onChange(of: IslandPool.shared.revision) { _, _ in if visible && controller.view == nil && !controller.failed { refresh() } }
    }
    private func refresh() { if visible { controller.mount(document,source: source,streaming: streaming,media: options.media,stickers: stickers) } else { controller.unmount() } }
}
// WebKit consumes SwiftUI ancestor gestures. Keep the recognizer native and
// remove only this host's recognizer when the pooled view is released.
#if os(iOS)
private struct IslandNativeView: UIViewRepresentable {
    var view: WKWebView
    var showActions: (@MainActor @Sendable () -> Void)?
    var selectPhoto: (@MainActor (CardPhoto) -> Void)?
    func makeCoordinator() -> IslandPressHandler { IslandPressHandler() }
    func makeUIView(context: Context) -> WKWebView { context.coordinator.attach(to: view); return view }
    func updateUIView(_ uiView: WKWebView, context: Context) { context.coordinator.showActions = showActions; context.coordinator.selectPhoto = selectPhoto; context.coordinator.gesture?.isEnabled = showActions != nil || selectPhoto != nil }
    static func dismantleUIView(_ uiView: WKWebView, coordinator: IslandPressHandler) { coordinator.detach(from: uiView) }
}
@MainActor private final class IslandPressHandler: NSObject, UIGestureRecognizerDelegate {
    var showActions: (@MainActor @Sendable () -> Void)?
    var selectPhoto: (@MainActor (CardPhoto) -> Void)?
    var gesture: UILongPressGestureRecognizer?
    func attach(to view: WKWebView) {
        let press = UILongPressGestureRecognizer(target: self,action: #selector(pressed(_:)))
        press.minimumPressDuration = 0.5; press.allowableMovement = 10; press.delegate = self
        gesture = press; view.addGestureRecognizer(press)
    }
    func detach(from view: WKWebView) { if let gesture { view.removeGestureRecognizer(gesture) }; gesture = nil; showActions = nil; selectPhoto = nil }
    @objc private func pressed(_ press: UILongPressGestureRecognizer) {
        guard press.state == .began, let web = press.view as? WKWebView else { return }
        guard selectPhoto != nil, web.bounds.width > 0 else { showActions?(); return }
        let location = press.location(in: web), width = web.bounds.width
        web.__callAsyncJavaScript(CardPhoto.hitTest, arguments: ["x": location.x / width, "y": location.y / width],
                                  inFrame: nil, in: .defaultClient) { [weak self, weak press] value, _ in
            guard let self, let press, self.gesture === press else { return }
            if let hit = value as? [String], let photo = CardPhoto(hit: hit) { self.selectPhoto?(photo) }
            else { self.showActions?() }
        }
    }
    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool { true }
}
#else
private struct IslandNativeView: NSViewRepresentable {
    var view: WKWebView
    var showActions: (@MainActor @Sendable () -> Void)?
    func makeCoordinator() -> IslandPressHandler { IslandPressHandler() }
    func makeNSView(context: Context) -> WKWebView { context.coordinator.attach(to: view); return view }
    func updateNSView(_ nsView: WKWebView, context: Context) { context.coordinator.showActions = showActions; context.coordinator.gesture?.isEnabled = showActions != nil }
    static func dismantleNSView(_ nsView: WKWebView, coordinator: IslandPressHandler) { coordinator.detach(from: nsView) }
}
@MainActor private final class IslandPressHandler: NSObject, NSGestureRecognizerDelegate {
    var showActions: (@MainActor @Sendable () -> Void)?
    var gesture: NSPressGestureRecognizer?
    func attach(to view: WKWebView) {
        let press = NSPressGestureRecognizer(target: self,action: #selector(pressed(_:)))
        press.minimumPressDuration = 0.5; press.allowableMovement = 10; press.delegate = self
        gesture = press; view.addGestureRecognizer(press)
    }
    func detach(from view: WKWebView) { if let gesture { view.removeGestureRecognizer(gesture) }; gesture = nil; showActions = nil }
    @objc private func pressed(_ gesture: NSPressGestureRecognizer) { if gesture.state == .began { showActions?() } }
    func gestureRecognizer(_ gestureRecognizer: NSGestureRecognizer, shouldRecognizeSimultaneouslyWith otherGestureRecognizer: NSGestureRecognizer) -> Bool { true }
}
#endif
