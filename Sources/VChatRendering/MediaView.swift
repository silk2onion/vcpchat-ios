import SwiftUI
import Observation
import AVKit
import VChatCore
@MainActor @Observable private final class VideoState {
    var player: AVPlayer?; var error: String?; var loading = false
    @ObservationIgnored private var worker: Task<Void,Never>?
    @ObservationIgnored private var observation: NSKeyValueObservation?
    @ObservationIgnored private var resource: VideoResource?
    @ObservationIgnored private var generation = UUID()
    func play(_ source: String) {
        close(); error = nil; loading = true; let own = generation
        worker = Task {
            do {
                let resource = try await NativeMediaLoader.shared.video(source)
                guard generation == own,!Task.isCancelled else { await NativeMediaLoader.shared.release(resource); return }
                self.resource = resource
                let asset = AVURLAsset(url: resource.url)
                guard try await asset.load(.isPlayable) else { throw ClientError.server("当前设备不支持此视频格式") }
                try Task.checkCancellation(); guard generation == own else { return }
                let item = AVPlayerItem(asset: asset)
                observation = item.observe(\.status,options: [.new]) { [weak self] item,_ in
                    let failed = item.status == .failed,reason = item.error?.localizedDescription ?? "视频播放失败"
                    if failed { Task { @MainActor in if self?.generation == own { self?.error = reason; self?.loading = false } } }
                }
                player = AVPlayer(playerItem: item); player?.play(); loading = false
            } catch { if generation == own,!Task.isCancelled { loading = false; self.error = error.localizedDescription } }
        }
    }
    func close() {
        generation = UUID(); worker?.cancel(); worker = nil; loading = false; observation?.invalidate(); observation = nil
        player?.pause(); player?.replaceCurrentItem(with: nil); player = nil
        if let value = resource { resource = nil; Task { await NativeMediaLoader.shared.release(value) } }
    }
}
struct NativeMessageMedia: View {
    let item: MessageMedia; var animations: Bool
    @State private var image: MediaRaster?
    @State private var issue: String?
    @State private var appeared = false
    @State private var bounds = CGRect.zero
    @State private var viewing = false
    @State private var video = VideoState()
    @Environment(\.messageViewport) private var viewport
    @Environment(\.scenePhase) private var phase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private var visible: Bool { appeared && phase != .background && (viewport?.intersects(bounds) ?? true) }
    private struct Load: Equatable { var source: String; var visible: Bool }
    var body: some View {
        VStack(alignment: .leading,spacing: 6) {
            if item.kind == "video" {
                if let player = video.player { NativeVideoPlayer(player: player).frame(height: 220) }
                else { Button { video.play(item.source) } label: { VStack(spacing: 8) { Image(systemName: "play.circle.fill").font(.system(size: 46)); Text(video.loading ? "正在读取视频…" : "播放视频") }.frame(maxWidth: .infinity).frame(height: 180).background(.secondary.opacity(0.08),in: RoundedRectangle(cornerRadius: 12)) }.buttonStyle(.plain).disabled(video.loading || !visible) }
                if let error = video.error { Text(error).font(.caption).foregroundStyle(.secondary) }
            } else if let image {
                Button { viewing = true } label: { MediaImage(raster: image,animating: animations && !reduceMotion && visible && phase == .active).aspectRatio(image.width/image.height,contentMode: .fit).frame(maxHeight: 340) }.buttonStyle(.plain).accessibilityLabel(item.caption.isEmpty ? "打开图片" : "打开图片：" + item.caption)
            } else if let issue { Label(issue,systemImage: "photo").font(.caption).foregroundStyle(.secondary) }
            else { Label(visible ? "正在读取图片…" : "图片已暂停",systemImage: "photo").font(.caption).foregroundStyle(.secondary).frame(height: 100) }
            if !item.caption.isEmpty { Text(item.caption).font(.caption).foregroundStyle(.secondary) }
            if issue != nil || video.error != nil,let url = URL(string: item.source),["https","http"].contains(url.scheme) { Link("打开原链接",destination: url).font(.caption) }
        }.frame(maxWidth: .infinity,alignment: .leading)
            .background(GeometryReader { g in Color.clear.preference(key: MediaBounds.self,value: g.frame(in: .global)) })
            .onPreferenceChange(MediaBounds.self) { value in Task { @MainActor in bounds = value } }
            .onAppear { appeared = true }.onDisappear { appeared = false; video.close(); image = nil }
            .onChange(of: item.id) { _,_ in video.close(); image = nil; issue = nil; viewing = false }
            .onChange(of: visible) { _,v in if !v { video.close(); image = nil; issue = nil } }
            .task(id: Load(source: item.id,visible: visible)) {
                guard visible,item.kind == "image" else { return }
                do { let value = try await NativeMediaLoader.shared.image(item.source); if !Task.isCancelled { image = value; issue = nil } }
                catch { if !Task.isCancelled { issue = error.localizedDescription } }
            }
            .sheet(isPresented: $viewing) { if let image { RasterViewer(image: image.image,title: item.caption.isEmpty ? "图片" : item.caption,animation: image.animation,animations: animations) } }
    }
}
private struct MediaBounds: PreferenceKey { static let defaultValue = CGRect.zero; static func reduce(value: inout CGRect,nextValue: () -> CGRect) { value = nextValue() } }
struct MediaImage: View {
    let raster: MediaRaster; var animating: Bool
    var body: some View {
        if let data = raster.animation { RasterImageView(data: data,animating: animating) }
        else { Image(decorative: raster.image,scale: 1).resizable().scaledToFit() }
    }
}
#if os(iOS)
private struct NativeVideoPlayer: UIViewControllerRepresentable {
    let player: AVPlayer
    func makeUIViewController(context: Context) -> AVPlayerViewController { let view = AVPlayerViewController(); view.player = player; view.showsPlaybackControls = true; view.allowsPictureInPicturePlayback = false; return view }
    func updateUIViewController(_ view: AVPlayerViewController,context: Context) { if view.player !== player { view.player = player } }
    static func dismantleUIViewController(_ view: AVPlayerViewController,coordinator: ()) { view.player = nil }
}
#else
private struct NativeVideoPlayer: NSViewRepresentable {
    let player: AVPlayer
    func makeNSView(context: Context) -> AVPlayerView { let view = AVPlayerView(); view.player = player; view.controlsStyle = .inline; view.showsFullScreenToggleButton = true; view.allowsPictureInPicturePlayback = false; return view }
    func updateNSView(_ view: AVPlayerView,context: Context) { if view.player !== player { view.player = player } }
    static func dismantleNSView(_ view: AVPlayerView,coordinator: ()) { view.player = nil }
}
#endif
