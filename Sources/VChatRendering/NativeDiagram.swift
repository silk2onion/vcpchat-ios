import SwiftUI
import CoreGraphics
import MermaidRender
import VChatCore
public struct DiagramRaster: Sendable,Equatable {
    public let image: CGImage?
    public let issue: String?
    public static func ==(lhs: Self,rhs: Self) -> Bool { lhs.image === rhs.image && lhs.issue == rhs.issue }
}
/// Called only by MessageRenderer's actor, never by a SwiftUI body.
struct DiagramCache {
    private var items: [String:DiagramRaster] = [:]
    private var recent: [String] = []
    private var bytes = 0
    mutating func render(_ source: String,dark: Bool) -> DiagramRaster {
        let key = (dark ? "dark\0" : "light\0") + source
        if let value = items[key] { recent.removeAll { $0 == key }; recent.append(key); return value }
        let result: DiagramRaster
        do {
            guard source.utf8.count <= 50_000,source.split(separator: "\n").count <= 500 else { throw ClientError.server("图表过大，请拆成较小的图") }
            guard let image = MermaidRenderer.boundedCGImage(source: source,dark: dark) else { throw ClientError.server("无法绘制图表") }
            result = DiagramRaster(image: image,issue: nil)
        } catch { result = DiagramRaster(image: nil,issue: "此图表暂不能原生绘制，源码完整保留") }
        let cost = result.image.map { $0.bytesPerRow*$0.height } ?? 0
        while (!recent.isEmpty) && (recent.count >= 6 || bytes+cost > 24_000_000) { let old = recent.removeFirst(); if let image = items.removeValue(forKey: old)?.image { bytes -= image.bytesPerRow*image.height } }
        if cost <= 24_000_000 { items[key] = result; recent.append(key); bytes += cost }; return result
    }
}
struct NativeDiagram: View {
    var source: String; var raster: DiagramRaster
    @State private var expanded = false
    var body: some View {
        if let image = raster.image {
            Button { expanded = true } label: { Image(decorative: image,scale: 2).resizable().scaledToFit().frame(maxWidth: .infinity).padding(12).background(.secondary.opacity(0.05),in: RoundedRectangle(cornerRadius: 12)) }.buttonStyle(.plain).accessibilityLabel("打开图表，可放大查看")
                .sheet(isPresented: $expanded) { RasterViewer(image: image) }
        } else { Label(raster.issue ?? "图表未完成",systemImage: "doc.text").font(.caption).foregroundStyle(.secondary) }
    }
}
struct RasterViewer: View {
    var image: CGImage
    var title = "图表"
    var animation: Data?
    var animations = true
    @Environment(\.scenePhase) private var phase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var zoom: CGFloat = 1
    @GestureState private var pinch: CGFloat = 1
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                GeometryReader { g in
                    let ratio = CGFloat(image.height)/CGFloat(image.width)
                    let width = max(80,min(g.size.width-32,(g.size.height-32)/ratio)),height = width*ratio,scale = min(6,max(0.5,zoom*pinch))
                    ScrollView([.horizontal,.vertical]) { MediaImage(raster: MediaRaster(image: image,animation: animation),animating: animations && !reduceMotion && phase == .active).frame(width: width*scale,height: height*scale).frame(minWidth: g.size.width-32,minHeight: g.size.height-32).padding(16) }
                        .gesture(MagnifyGesture().updating($pinch) { value,state,_ in state = value.magnification }.onEnded { zoom = min(6,max(0.5,zoom*$0.magnification)) })
                }
                Divider()
                HStack(spacing: 20) { Button("缩小",systemImage: "minus.magnifyingglass") { zoom = max(0.5,zoom/1.5) }; Button("还原") { zoom = 1 }; Button("放大",systemImage: "plus.magnifyingglass") { zoom = min(6,zoom*1.5) } }.padding(12)
            }.navigationTitle(title).toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } } }
        }.frame(minWidth: 350,minHeight: 450)
    }
}
