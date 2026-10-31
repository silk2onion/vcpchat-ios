import SwiftUI
import VChatCore
import SDWebImage

/// UIKit/AppKit image views provide lazy GIF frame decoding without a web view.
public struct NativeRaster: View {
    var source: String
    var animations: Bool
    var fill: Bool
    @State private var raster: EmbeddedRaster?
    @State private var visible = false
    @Environment(\.scenePhase) private var phase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    public init(_ source: String, animations: Bool = true, fill: Bool = true) { self.source = source; self.animations = animations; self.fill = fill }
    public var body: some View {
        GeometryReader { geometry in
            if let raster {
                let scale = fill ? max(geometry.size.width / raster.width, geometry.size.height / raster.height) : min(geometry.size.width / raster.width, geometry.size.height / raster.height)
                RasterImageView(data: raster.data, animating: animations && !reduceMotion && visible && phase == .active)
                    .frame(width: raster.width * scale, height: raster.height * scale)
                    .position(x: geometry.size.width / 2, y: geometry.size.height / 2)
            }
        }.clipped()
        .task(id: source) { let value = await EmbeddedImages.shared.raster(source); if !Task.isCancelled { raster = value } }
        .onAppear { visible = true }.onDisappear { visible = false }
    }
}
#if os(iOS)
struct RasterImageView: UIViewRepresentable {
    var data: Data; var animating: Bool
    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeUIView(context: Context) -> SDAnimatedImageView { let view = SDAnimatedImageView(); view.contentMode = .scaleAspectFill; view.clipsToBounds = true; view.autoPlayAnimatedImage = false; view.maxBufferSize = 8_000_000; view.clearBufferWhenStopped = true; return view }
    func updateUIView(_ view: SDAnimatedImageView, context: Context) {
        if context.coordinator.data != data { context.coordinator.data = data; view.image = SDAnimatedImage(data: data) }
        view.autoPlayAnimatedImage = animating
        if animating { if !view.isAnimating { view.startAnimating() } } else { view.stopAnimating() }
    }
    @MainActor final class Coordinator { var data: Data? }
}
#else
struct RasterImageView: NSViewRepresentable {
    var data: Data; var animating: Bool
    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeNSView(context: Context) -> SDAnimatedImageView { let view = SDAnimatedImageView(); view.imageScaling = .scaleAxesIndependently; view.autoPlayAnimatedImage = false; view.maxBufferSize = 8_000_000; view.clearBufferWhenStopped = true; return view }
    func updateNSView(_ view: SDAnimatedImageView, context: Context) {
        if context.coordinator.data != data { context.coordinator.data = data; view.image = SDAnimatedImage(data: data) }
        view.autoPlayAnimatedImage = animating
        if view.animates != animating { view.animates = animating }
    }
    @MainActor final class Coordinator { var data: Data? }
}
#endif
