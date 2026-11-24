#if os(iOS)
import SwiftUI
import Photos

/// Write the encoded source so Photos receives the original dimensions, EXIF
/// orientation and animation. No access to existing photos is needed.
private enum ChatPhotoLibrary {
    nonisolated static func save(_ data: Data) async throws {
        var auth = PHPhotoLibrary.authorizationStatus(for: .addOnly)
        if auth == .notDetermined { auth = await PHPhotoLibrary.requestAuthorization(for: .addOnly) }
        guard auth == .authorized || auth == .limited else { throw SaveError.permission }
        // PhotoKit executes the change block on its own queue. Keep it free of
        // MainActor isolation even when a SwiftUI button initiates the save.
        let change: @Sendable () -> Void = {
            PHAssetCreationRequest.forAsset().addResource(with: .photo, data: data, options: nil)
        }
        try await PHPhotoLibrary.shared().performChanges(change)
    }
    enum SaveError: Error { case permission }
}

@MainActor @Observable private final class PhotoSaveState {
    var saving = false
    var notice: String?
    func save(_ data: Data) {
        guard !saving else { return }
        saving = true
        Task {
            defer { saving = false }
            do { try await ChatPhotoLibrary.save(data); notice = "已保存到照片" }
            catch ChatPhotoLibrary.SaveError.permission { notice = "未允许添加照片。请在系统设置中允许 VChat 添加照片后再试。" }
            catch { notice = "保存失败：" + error.localizedDescription }
        }
    }
}
private extension View {
    func photoSaveNotice(_ state: PhotoSaveState) -> some View {
        alert(state.notice ?? "", isPresented: Binding(get: { state.notice != nil }, set: { if !$0 { state.notice = nil } })) {
            Button("好") { state.notice = nil }
        }
    }
}
struct PhotoSaveButton: View {
    let data: Data
    @State private var state = PhotoSaveState()
    var body: some View {
        Button { state.save(data) } label: {
            Label(state.saving ? "正在保存…" : "保存到照片", systemImage: "square.and.arrow.down")
        }.disabled(state.saving).photoSaveNotice(state)
    }
}
struct PhotoPressMenu: ViewModifier {
    let data: Data?
    @State private var state = PhotoSaveState()
    func body(content: Content) -> some View {
        content.contextMenu {
            if let data { Button("保存到照片", systemImage: "square.and.arrow.down") { state.save(data) }.disabled(state.saving) }
        }.photoSaveNotice(state)
    }
}
#endif
