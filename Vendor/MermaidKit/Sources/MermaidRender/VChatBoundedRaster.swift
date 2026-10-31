import CoreGraphics
import MermaidLayout
#if os(macOS)
import AppKit
#else
import UIKit
#endif

extension MermaidRenderer {
    /// VChat's Actor calls this synchronous, bounded raster path. It reuses the
    /// original parser/layout/drawing plan without an NSImage/UIImage, attachment,
    /// library render cache or any MainActor hop.
    public static func boundedCGImage(source: String,dark: Bool) -> CGImage? {
        guard let (diagram,metadata) = MermaidParser.parseWithMetadata(source) else { return nil }
        let theme = DiagramTheme(prefersDark: dark),spacing = DiagramSpacing.regular
        let plan = DiagramRenderer.captionedPlan(DiagramRenderer.renderPlan(for: diagram,theme: theme,spacing: spacing),caption: metadata.title,diagram: diagram,theme: theme,textScale: spacing.textScale)
        guard let (size,x,y) = DiagramRenderer.paddedCanvas(size: plan.size,edgePolylines: plan.edgePolylines),size.width.isFinite,size.height.isFinite else { return nil }
        let scale = min(2,4096/max(size.width,size.height),sqrt(4_000_000/(size.width*size.height)))
        let width = max(1,Int(floor(size.width*scale))),height = max(1,Int(floor(size.height*scale)))
        guard let context = CGContext(data: nil,width: width,height: height,bitsPerComponent: 8,bytesPerRow: width*4,space: CGColorSpaceCreateDeviceRGB(),bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.translateBy(x: 0,y: CGFloat(height)); context.scaleBy(x: scale,y: -scale); context.translateBy(x: x,y: y)
        #if os(macOS)
        let appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        if let appearance { appearance.performAsCurrentDrawingAppearance { plan.draw(context) } } else { plan.draw(context) }
        #else
        UITraitCollection(userInterfaceStyle: dark ? .dark : .light).performAsCurrent { plan.draw(context) }
        #endif
        return context.makeImage()
    }
}
