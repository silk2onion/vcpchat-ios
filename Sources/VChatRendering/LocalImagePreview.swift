import SwiftUI

public struct LocalImagePreview: View {
    var data: Data; var title: String
    @State private var raster: MediaRaster?
    @State private var error: String?
    @State private var viewing = false
    @State private var visible = false
    @Environment(\.scenePhase) private var phase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    public init(data: Data,title: String) { self.data = data; self.title = title }
    public var body: some View {
        Group {
            if let raster {
                GeometryReader { g in
                    let scale = min(g.size.width/raster.width,g.size.height/raster.height)
                    Button { viewing = true } label: {
                        MediaImage(raster: raster,animating: visible && phase == .active && !reduceMotion)
                            .frame(width: raster.width*scale,height: raster.height*scale)
                    }.buttonStyle(.plain).frame(width: g.size.width,height: g.size.height).accessibilityLabel("放大原文件图片")
                }
            } else if let error { ContentUnavailableView("无法预览图片",systemImage: "photo",description: Text(error)) }
            else { ProgressView("正在读取图片…").frame(maxWidth: .infinity,maxHeight: .infinity) }
        }.task {
            do { let value = try await NativeMediaLoader.shared.localImage(data); if !Task.isCancelled { raster = value } }
            catch { if !Task.isCancelled { self.error = error.localizedDescription } }
        }.onAppear { visible = true }.onDisappear { visible = false; raster = nil }
        .sheet(isPresented: $viewing) { if let raster { RasterViewer(image: raster.image,title: title,animation: raster.animation) } }
    }
}
