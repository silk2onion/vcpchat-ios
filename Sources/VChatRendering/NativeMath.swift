import SwiftUI
import SwiftMath

#if os(iOS)
public struct NativeMath: UIViewRepresentable {
    public var source: String
    public var size: CGFloat
    public init(_ source: String, size: CGFloat = 19) { self.source = source; self.size = size }
    public func makeUIView(context: Context) -> MTMathUILabel { MTMathUILabel() }
    public func updateUIView(_ view: MTMathUILabel, context: Context) {
        if view.latex != source { view.latex = source }
        if view.fontSize != size { view.fontSize = size }; view.textColor = .label; view.textAlignment = .left; view.labelMode = .display
    }
    public func sizeThatFits(_ proposal: ProposedViewSize, uiView: MTMathUILabel, context: Context) -> CGSize? {
        let size = uiView.intrinsicContentSize
        return CGSize(width: max(1, size.width), height: max(24, size.height + 5))
    }
}
#else
public struct NativeMath: NSViewRepresentable {
    public var source: String
    public var size: CGFloat
    public init(_ source: String, size: CGFloat = 19) { self.source = source; self.size = size }
    public func makeNSView(context: Context) -> MTMathUILabel { MTMathUILabel() }
    public func updateNSView(_ view: MTMathUILabel, context: Context) {
        if view.latex != source { view.latex = source }
        if view.fontSize != size { view.fontSize = size }; view.textColor = .labelColor; view.textAlignment = .left; view.labelMode = .display
    }
    public func sizeThatFits(_ proposal: ProposedViewSize, nsView: MTMathUILabel, context: Context) -> CGSize? {
        let size = nsView.fittingSize
        return CGSize(width: max(1, size.width), height: max(24, size.height + 5))
    }
}
#endif
