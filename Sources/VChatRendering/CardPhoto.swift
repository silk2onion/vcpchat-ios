#if os(iOS)
import SwiftUI
import WebKit
import VChatCore

/// Hit-test the rendered document only after UIKit receives a real long press.
/// The bubble cannot invoke a Photos operation or open a native sheet by script.
struct CardPhoto: Identifiable {
    let id = UUID()
    let source: String
    let title: String
    static let hitTest = #"""
        const width = document.documentElement.clientWidth;
        const node = document.elementFromPoint(x * width, y * width);
        if (!node) return null;
        const img = node.closest('img');
        if (img && img.complete && img.naturalWidth) {
            const src = img.currentSrc || img.src;
            return src.length <= 28000000 ? [src, (img.alt || '图片').slice(0,80)] : null;
        }
        // A caret alone snaps to nearby whitespace. Require an actual character rectangle.
        const px = x * width, py = y * width, caret = document.caretRangeFromPoint(px, py);
        if (typeof allowSelection !== 'undefined' && allowSelection && caret && caret.startContainer.nodeType === Node.TEXT_NODE) {
            const text = caret.startContainer, at = caret.startOffset;
            for (const i of [at - 1, at]) {
                if (i < 0 || i >= text.length) continue;
                const char = document.createRange(); char.setStart(text, i); char.setEnd(text, i + 1);
                if ([...char.getClientRects()].some(r => r.left <= px && px <= r.right && r.top <= py && py <= r.bottom)) {
                    const selection = window.getSelection();
                    if (!selection) return null;
                    if (selection.isCollapsed || !selection.containsNode(text, true)) {
                        const word = new Intl.Segmenter(undefined, {granularity:'word'}).segment(text.data).containing(i);
                        char.setStart(text, word.index); char.setEnd(text, word.index + word.segment.length);
                        selection.removeAllRanges(); selection.addRange(char);
                    }
                    return {selected: selection.toString()};
                }
            }
        }
        for (let el = node; el && el !== document.documentElement; el = el.parentElement) {
            const bg = getComputedStyle(el).backgroundImage.match(/^url\(["']?(.+?)["']?\)$/);
            if (bg && bg[1].length <= 28000000) return [bg[1], '背景图片'];
        }
        return null;
        """#
    init?(hit: [String]) {
        guard hit.count == 2 else { return nil }
        let locator = hit[0], raw: String
        if locator.hasPrefix("vchat-image://asset?") {
            let escaped = locator.dropFirst("vchat-image://asset?".count)
            guard escaped.utf8.count <= 32000, let value = escaped.removingPercentEncoding else { return nil }
            raw = value
        } else { raw = locator }
        guard (raw.lowercased().hasPrefix("https://") || raw.lowercased().hasPrefix("data:image/") || MessageMedia.relativeSticker(raw)),
              let media = MessageMedia(source: raw), media.kind == "image" else { return nil }
        source = raw; title = hit[1].isEmpty ? "图片" : String(hit[1].prefix(80))
    }
    func load(stickers: StickerContext) async throws -> MediaRaster {
        if source.lowercased().hasPrefix("data:image/") { return try await NativeMediaLoader.shared.image(source) }
        guard let url = await StickerResolver.shared.url(source, in: stickers), url.scheme?.lowercased() == "https" else { throw URLError(.unsupportedURL) }
        return try await NativeMediaLoader.shared.image(url.absoluteString)
    }
}
struct CardPhotoPreview: View {
    let photo: CardPhoto, stickers: StickerContext
    @Environment(\.dismiss) private var dismiss
    @State private var image: MediaRaster?
    @State private var failed = false
    var body: some View {
        Group {
            if let image { RasterViewer(image: image.image, title: photo.title, animation: image.animation, original: image.original) }
            else {
                NavigationStack {
                    Group {
                        if failed { ContentUnavailableView("无法读取原图", systemImage: "photo", description: Text("图片可能已过期，请检查网络后重试。")) }
                        else { ProgressView("正在读取原图…") }
                    }.navigationTitle("图片").toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } } }
                }
            }
        }.task(id: photo.id) {
            do { let value = try await photo.load(stickers: stickers); try Task.checkCancellation(); image = value }
            catch { if !Task.isCancelled { failed = true } }
        }
    }
}
#endif
