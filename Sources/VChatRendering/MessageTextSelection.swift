import SwiftUI

private struct MessageTextSelectionKey: EnvironmentKey {
    static let defaultValue = true
}
private struct MessageLongPressKey: EnvironmentKey {
    static let defaultValue: (@MainActor @Sendable () -> Void)? = nil
}
extension EnvironmentValues {
    public var messageTextSelectionEnabled: Bool {
        get { self[MessageTextSelectionKey.self] }
        set { self[MessageTextSelectionKey.self] = newValue }
    }
    public var messageLongPressAction: (@MainActor @Sendable () -> Void)? {
        get { self[MessageLongPressKey.self] }
        set { self[MessageLongPressKey.self] = newValue }
    }
}

private struct AskSelectionKey: EnvironmentKey {
    static let defaultValue: (@MainActor @Sendable (String) -> Void)? = nil
}
public extension EnvironmentValues {
    var askAboutSelection: (@MainActor @Sendable (String) -> Void)? {
        get { self[AskSelectionKey.self] }
        set { self[AskSelectionKey.self] = newValue }
    }
}

/// Use UIKit's range handles and standard edit menu in the transcript.
/// Other readers retain their existing SwiftUI layout and link handling.
public struct MessageProse: View {
    public enum Style { case body, heading(Int), note, code, tableHeader }
    let value: AttributedString
    let style: Style
    @Environment(\.askAboutSelection) private var ask
    public init(_ value: AttributedString, style: Style = .body) { self.value = value; self.style = style }
    public var body: some View {
        #if os(iOS)
        if let ask { RangeText(value: value, style: style, ask: ask) }
        else { Text(value).modifier(MessageTextSelection()) }
        #else
        Text(value).modifier(MessageTextSelection())
        #endif
    }
}

#if os(iOS)
import UIKit

private struct RangeText: UIViewRepresentable {
    let value: AttributedString
    let style: MessageProse.Style
    let ask: @MainActor @Sendable (String) -> Void
    @Environment(\.openURL) private var openURL
    @Environment(\.dynamicTypeSize) private var typeSize
    @Environment(\.colorScheme) private var scheme
    func makeCoordinator() -> Delegate { Delegate() }
    func makeUIView(context: Context) -> UITextView {
        let view = UITextView()
        view.isEditable = false; view.isSelectable = true; view.isScrollEnabled = false
        view.showsVerticalScrollIndicator = false; view.showsHorizontalScrollIndicator = false
        view.backgroundColor = .clear; view.textContainerInset = .zero
        view.textContainer.lineFragmentPadding = 0
        view.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        view.delegate = context.coordinator
        return view
    }
    func updateUIView(_ view: UITextView, context: Context) {
        let delegate = context.coordinator
        delegate.ask = ask; delegate.open = openURL
        let base: UIFont, color: UIColor
        switch style {
        case .heading(let level): base = .boldSystemFont(ofSize: level == 1 ? 22 : level == 2 ? 20 : 17); color = .label
        case .code: base = .monospacedSystemFont(ofSize: 15, weight: .regular); color = .label
        case .tableHeader: base = .systemFont(ofSize: 16, weight: .semibold); color = .label
        case .note: base = .systemFont(ofSize: 15); color = .secondaryLabel
        case .body: base = .systemFont(ofSize: 16); color = .label
        }
        let font = UIFontMetrics.default.scaledFont(for: base, compatibleWith: view.traitCollection)
        guard delegate.value != value || delegate.font != font || delegate.scheme != scheme || delegate.size != typeSize else { return }
        delegate.value = value; delegate.font = font; delegate.scheme = scheme; delegate.size = typeSize
        let result = NSMutableAttributedString()
        let paragraph = NSMutableParagraphStyle(); paragraph.lineSpacing = 4
        for run in value.runs {
            var face = font
            let intent = run.inlinePresentationIntent ?? []
            if intent.contains(.code) { face = .monospacedSystemFont(ofSize: font.pointSize, weight: .regular) }
            var traits = face.fontDescriptor.symbolicTraits
            if intent.contains(.stronglyEmphasized) { traits.insert(.traitBold) }
            if intent.contains(.emphasized) { traits.insert(.traitItalic) }
            if let descriptor = face.fontDescriptor.withSymbolicTraits(traits) { face = UIFont(descriptor: descriptor, size: face.pointSize) }
            var attributes: [NSAttributedString.Key: Any] = [.font: face, .foregroundColor: run.swiftUI.foregroundColor.map { UIColor($0) } ?? color, .paragraphStyle: paragraph]
            if intent.contains(.strikethrough) { attributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue }
            if let link = run.link, ["http","https","mailto"].contains(link.scheme?.lowercased()) { attributes[.link] = link }
            result.append(NSAttributedString(string: String(value[run.range].characters), attributes: attributes))
        }
        view.attributedText = result
        delegate.naturalWidth = ceil(result.size().width); delegate.measured = nil
    }
    func sizeThatFits(_ proposal: ProposedViewSize, uiView: UITextView, context: Context) -> CGSize? {
        let cache = context.coordinator, natural = cache.naturalWidth
        let width = max(1, min(proposal.width ?? natural, natural))
        if let measured = cache.measured, measured.width == width { return measured }
        let height = uiView.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude)).height
        let measured = CGSize(width: width, height: ceil(height)); cache.measured = measured; return measured
    }

    @MainActor final class Delegate: NSObject, UITextViewDelegate {
        var ask: (@MainActor @Sendable (String) -> Void)?
        var open: OpenURLAction?
        var naturalWidth: CGFloat = 0, measured: CGSize?
        var value: AttributedString?, font: UIFont?, scheme: ColorScheme?, size: DynamicTypeSize?
        func textView(_ view: UITextView, editMenuForTextIn range: NSRange, suggestedActions: [UIMenuElement]) -> UIMenu? {
            guard range.length > 0, let selected = Range(range, in: view.text), let ask else { return nil }
            let quote = String(view.text[selected])
            let action = UIAction(title: "单独追问", image: UIImage(systemName: "text.bubble")) { _ in ask(quote) }
            return UIMenu(children: [action] + suggestedActions)
        }
        func textView(_ textView: UITextView, primaryActionFor textItem: UITextItem, defaultAction: UIAction) -> UIAction? {
            guard case .link(let url) = textItem.content else { return defaultAction }
            return UIAction { [weak self] _ in self?.open?(url) }
        }
    }
}
#endif

/// Selection for standalone readers and non-interactive previews.
struct MessageTextSelection: ViewModifier {
    @Environment(\.messageTextSelectionEnabled) private var enabled
    @ViewBuilder func body(content: Content) -> some View {
        if enabled { content.textSelection(.enabled) }
        else { content.textSelection(.disabled) }
    }
}
