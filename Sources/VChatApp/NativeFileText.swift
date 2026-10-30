import SwiftUI
#if os(iOS)
import UIKit
/// TextKit 2 lays out a scrollable document instead of creating a giant SwiftUI Text.
struct NativeFileText: UIViewRepresentable {
    var text: String
    func makeUIView(context: Context) -> UITextView {
        let view = UITextView(usingTextLayoutManager: true)
        view.isEditable = false; view.isSelectable = true; view.backgroundColor = .clear
        view.font = .preferredFont(forTextStyle: .body); view.adjustsFontForContentSizeCategory = true
        view.textContainerInset = UIEdgeInsets(top: 16,left: 16,bottom: 16,right: 16); view.text = text
        view.accessibilityLabel = "原文件内容"; return view
    }
    func updateUIView(_ view: UITextView,context: Context) { if view.text != text { view.text = text } }
}
#else
import AppKit
struct NativeFileText: NSViewRepresentable {
    var text: String
    func makeNSView(context: Context) -> NSScrollView {
        let view = NSTextView(usingTextLayoutManager: true)
        view.frame = NSRect(x: 0,y: 0,width: 340,height: 400)
        view.autoresizingMask = [.width]; view.isEditable = false; view.isSelectable = true; view.isRichText = false
        view.isVerticallyResizable = true; view.isHorizontallyResizable = false; view.textContainer?.widthTracksTextView = true
        view.font = .systemFont(ofSize: 16); view.textColor = .labelColor; view.drawsBackground = false
        view.textContainerInset = NSSize(width: 16,height: 16); view.string = text; view.setAccessibilityLabel("原文件内容")
        let scroll = NSScrollView(); scroll.hasVerticalScroller = true; scroll.drawsBackground = false; scroll.documentView = view
        return scroll
    }
    func updateNSView(_ view: NSScrollView,context: Context) { if let textView = view.documentView as? NSTextView,textView.string != text { textView.string = text } }
}
#endif
