import SwiftUI
import WebKit
import Observation

public enum HTMLIslandPolicy {
    public static let root = "<div id=\"vcp-root\">"
    public static func accepts(_ source: String) -> Bool { source.hasPrefix(root) }
    public static func document(_ source: String, motion: Bool, media: Bool, dark: Bool) -> String {
        let color = dark ? "dark" : "light"
        let image = media ? "https: data:" : "'none'"
        let noMotion = motion ? "" : "*,*::before,*::after{animation:none!important;transition:none!important;scroll-behavior:auto!important}"
        return """
        <!doctype html><html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1,maximum-scale=1,user-scalable=no"><meta http-equiv="Content-Security-Policy" content="default-src 'none'; script-src 'unsafe-inline'; style-src 'unsafe-inline'; img-src \(image); media-src \(image); font-src data:; connect-src 'none'; frame-src 'none'; object-src 'none'; base-uri 'none'; form-action 'none'"><style>:root{color-scheme:\(color)}html,body{margin:0;padding:0;font:16px -apple-system;overflow-wrap:anywhere}#vcp-root{max-width:100%;box-sizing:border-box}img,video,svg,canvas{max-width:100%}pre{white-space:pre-wrap}\(noMotion)</style></head><body>\(source)</body></html>
        """
    }
}

private struct ViewportKey: EnvironmentKey { static let defaultValue: CGRect? = nil }
extension EnvironmentValues { public var messageViewport: CGRect? { get { self[ViewportKey.self] } set { self[ViewportKey.self] = newValue } } }
private struct IslandBounds: PreferenceKey {
    static let defaultValue = CGRect.zero
    static func reduce(value: inout CGRect, nextValue: () -> CGRect) { value = nextValue() }
}
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
            config.preferences.javaScriptCanOpenWindowsAutomatically = false
            #if os(iOS)
            config.allowsInlineMediaPlayback = true; config.mediaTypesRequiringUserActionForPlayback = .all
            #endif
            view = WKWebView(frame: .zero, configuration: config)
            #if os(iOS)
            view.isOpaque = false; view.backgroundColor = .clear; view.scrollView.isScrollEnabled = false
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
        view.stopLoading(); view.setAllMediaPlaybackSuspended(true)
        view.navigationDelegate = nil; view.uiDelegate = nil
        view.configuration.userContentController.removeAllScriptMessageHandlers()
        view.configuration.userContentController.removeAllUserScripts()
        view.loadHTMLString("", baseURL: nil)
        if idle.count < 3 { idle.append(view) }
        revision += 1
    }
}
@MainActor @Observable private final class IslandController: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
    let id = UUID()
    var view: WKWebView?
    var height: CGFloat = 180
    var failed = false
    @ObservationIgnored private var document = ""
    func mount(_ document: String, media: Bool) {
        guard let web = view ?? IslandPool.shared.take(id) else { return }
        guard view == nil || self.document != document else { return }
        view = web; self.document = document; failed = false
        web.configuration.userContentController.removeAllScriptMessageHandlers()
        web.configuration.userContentController.removeAllUserScripts()
        web.configuration.userContentController.add(self, name: "vcpHeight")
        // The bridge accepts height only, and carries no native commands or secrets.
        let script = """
        (()=>{let previous=0;const measure=()=>{let h=Math.ceil(document.body.getBoundingClientRect().height);if(h!==previous){previous=h;window.webkit.messageHandlers.vcpHeight.postMessage(h)}};new ResizeObserver(measure).observe(document.body);measure()})();
        """
        web.configuration.userContentController.addUserScript(WKUserScript(source: script, injectionTime: .atDocumentEnd, forMainFrameOnly: true))
        web.navigationDelegate = self
        web.setAllMediaPlaybackSuspended(!media)
        web.loadHTMLString(document, baseURL: nil)
    }
    func unmount() { view = nil; document = ""; IslandPool.shared.release(id) }
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.frameInfo.isMainFrame, let number = message.body as? NSNumber else { return }
        let value = number.doubleValue
        if value.isFinite {
            height = min(1400, max(44, value))
            #if os(iOS)
            view?.scrollView.isScrollEnabled = value > 1400
            #endif
        }
    }
    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void) {
        decisionHandler(navigationAction.request.url?.absoluteString == "about:blank" && navigationAction.navigationType == .other ? .allow : .cancel)
    }
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) { failed = true; unmount() }
}
struct HTMLIsland: View {
    var source: String
    var options: RenderOptions
    @State private var controller = IslandController()
    @State private var bounds = CGRect.zero
    @State private var appeared = false
    @Environment(\.messageViewport) private var viewport
    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var phase
    private var visible: Bool { appeared && phase == .active && (viewport?.intersects(bounds) ?? true) }
    private var document: String { HTMLIslandPolicy.document(source, motion: options.motion && !reduceMotion, media: options.media, dark: scheme == .dark) }
    var body: some View {
        Group {
            if let view = controller.view { IslandNativeView(view: view).frame(height: controller.height) }
            else if controller.failed { Label("气泡已暂停，重新进入可加载", systemImage: "arrow.clockwise").font(.callout).frame(height: controller.height) }
            else { Label(visible ? "等待加载视觉气泡" : "视觉气泡已暂停", systemImage: "rectangle.inset.filled").font(.caption).foregroundStyle(.secondary).frame(maxWidth: .infinity).frame(height: controller.height) }
        }
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .background(GeometryReader { proxy in Color.clear.preference(key: IslandBounds.self, value: proxy.frame(in: .global)) })
        .onPreferenceChange(IslandBounds.self) { value in Task { @MainActor in bounds = value } }
        .onAppear { appeared = true; refresh() }.onDisappear { appeared = false; controller.unmount() }
        .onChange(of: visible) { _, _ in refresh() }
        .onChange(of: document) { _, _ in refresh() }
        .onChange(of: IslandPool.shared.revision) { _, _ in if visible && controller.view == nil && !controller.failed { refresh() } }
    }
    private func refresh() { if visible { controller.mount(document, media: options.media) } else { controller.unmount() } }
}
#if os(iOS)
private struct IslandNativeView: UIViewRepresentable {
    var view: WKWebView
    func makeUIView(context: Context) -> WKWebView { view }
    func updateUIView(_ uiView: WKWebView, context: Context) {}
}
#else
private struct IslandNativeView: NSViewRepresentable {
    var view: WKWebView
    func makeNSView(context: Context) -> WKWebView { view }
    func updateNSView(_ nsView: WKWebView, context: Context) {}
}
#endif
