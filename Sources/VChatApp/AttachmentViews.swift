import SwiftUI
import PhotosUI
import UniformTypeIdentifiers
import VChatCore
import VChatRendering
#if os(iOS)
import UIKit
import AVFoundation
#endif

@MainActor
struct AttachmentComposer: View {
    let model: ChatViewModel
    @State private var importing = false
    @State private var photos: [PhotosPickerItem] = []
    @State private var choosingPhotos = false
    @State private var photoTopic = ""
    @State private var importTopic = ""
    @State private var loading = false
    #if os(iOS)
    @State private var camera: CameraRequest?
    @State private var cameraNotice: CameraNotice?
    #endif
    var body: some View {
        Menu {
            Button("图库", systemImage: "photo.on.rectangle") { photoTopic = model.activeTopicID; choosingPhotos = true }
            Button("文件", systemImage: "folder") { importTopic = model.activeTopicID; importing = true }
            #if os(iOS)
            Button("相机", systemImage: "camera") { beginCamera() }
            #endif
        } label: { Image(systemName: loading ? "hourglass" : "plus").frame(width: 44, height: 44).contentShape(Rectangle()) }
        .buttonStyle(.plain).disabled(loading || model.busy).accessibilityLabel("添加附件")
        .photosPicker(isPresented: $choosingPhotos, selection: $photos, maxSelectionCount: max(1, 4 - (model.room?.attachments.count ?? 0)), matching: .images)
        .fileImporter(isPresented: $importing, allowedContentTypes: [.image, .text, .json, .xml, .data], allowsMultipleSelection: true) { result in
            if case .success(let urls) = result {
                let topic = importTopic; loading = true
                Task { defer { loading = false }; do { try AttachmentImporter.assertCount(model.rooms[topic]?.attachments.count ?? 0, adding: urls.count); var items: [ChatAttachment] = []; let reader = AttachmentImporter(); for url in urls { items.append(try await reader.read(url)) }; await model.attach(items, to: topic) } catch { model.rooms[topic]?.error = error.localizedDescription } }
            }
        }
        .onChange(of: photos) { _, selection in
            guard !selection.isEmpty else { return }
            let topic = photoTopic; loading = true
            Task {
                defer { loading = false; photos = [] }
                do {
                    try AttachmentImporter.assertCount(model.rooms[topic]?.attachments.count ?? 0, adding: selection.count)
                    var items: [ChatAttachment] = []; let reader = AttachmentImporter()
                    for (index, item) in selection.enumerated() {
                        guard let data = try await item.loadTransferable(type: Data.self) else { throw ClientError.server("无法读取照片") }
                        let type = item.supportedContentTypes.first ?? .image
                        items.append(try await reader.prepare(data, name: "照片\(index + 1).\(type.preferredFilenameExtension ?? "jpg")", mime: type.preferredMIMEType ?? "image/jpeg"))
                    }
                    await model.attach(items, to: topic)
                } catch { model.rooms[topic]?.error = error.localizedDescription }
            }
        }
        #if os(iOS)
        .fullScreenCover(item: $camera) { request in
            CameraCapture { result in
                camera = nil
                guard let result else { return }
                loading = true
                Task {
                    defer { loading = false }
                    do {
                        let photo = try result.get()
                        let attachment = try await AttachmentImporter().prepareCameraPhoto(photo.image, orientation: photo.orientation, name: "拍照-\(request.id.uuidString.prefix(8)).jpg")
                        await model.attach([attachment], to: request.topicID)
                    } catch { model.rooms[request.topicID]?.error = error.localizedDescription }
                }
            }.ignoresSafeArea()
        }
        .alert(cameraNotice?.title ?? "相机", isPresented: Binding(get: { cameraNotice != nil }, set: { if !$0 { cameraNotice = nil } }), presenting: cameraNotice) { notice in
            if notice.openSettings {
                Button("去设置") {
                    if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
                }
            }
            Button("取消", role: .cancel) { }
        } message: { Text($0.message) }
        #endif
    }
    #if os(iOS)
    private func beginCamera() {
        let topic = model.activeTopicID
        do { try AttachmentImporter.assertCount(model.rooms[topic]?.attachments.count ?? 0, adding: 1) }
        catch { model.rooms[topic]?.error = error.localizedDescription; return }
        guard UIImagePickerController.isSourceTypeAvailable(.camera) else {
            cameraNotice = CameraNotice(title: "相机不可用", message: "此设备没有可用相机，请使用图库或文件添加图片。")
            return
        }
        loading = true
        Task {
            defer { loading = false }
            let status = AVCaptureDevice.authorizationStatus(for: .video)
            var authorized = status == .authorized
            if status == .notDetermined { authorized = await AVCaptureDevice.requestAccess(for: .video) }
            guard authorized else {
                cameraNotice = CameraNotice(title: "无法使用相机", message: status == .restricted ? "相机受系统限制，请使用图库或文件添加图片。" : "请在系统设置中允许 VChat 使用相机，也可以从图库或文件添加图片。", openSettings: status != .restricted)
                return
            }
            camera = CameraRequest(topicID: topic)
        }
    }
    #endif
}

#if os(iOS)
private struct CameraRequest: Identifiable {
    let id = UUID()
    let topicID: String
}
private struct CameraNotice {
    let title: String
    let message: String
    var openSettings = false
}
private struct CapturedPhoto: Sendable {
    let image: CGImage
    let orientation: UInt32
}
@MainActor
private struct CameraCapture: UIViewControllerRepresentable {
    let completion: @MainActor (Result<CapturedPhoto, Error>?) -> Void
    func makeCoordinator() -> Coordinator { Coordinator(completion: completion) }
    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.sourceType = .camera
        picker.mediaTypes = [UTType.image.identifier]
        picker.cameraCaptureMode = .photo
        picker.allowsEditing = false
        picker.delegate = context.coordinator
        return picker
    }
    func updateUIViewController(_ controller: UIImagePickerController, context: Context) { }
    static func dismantleUIViewController(_ controller: UIImagePickerController, coordinator: Coordinator) { controller.delegate = nil }
    @MainActor
    final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        let completion: @MainActor (Result<CapturedPhoto, Error>?) -> Void
        private var finished = false
        init(completion: @escaping @MainActor (Result<CapturedPhoto, Error>?) -> Void) { self.completion = completion }
        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) { finish(nil) }
        func imagePickerController(_ picker: UIImagePickerController, didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
            guard let image = info[.originalImage] as? UIImage, let pixels = image.cgImage else {
                finish(.failure(ClientError.server("无法读取拍摄的照片，请重试"))); return
            }
            let orientation: UInt32
            switch image.imageOrientation {
            case .up: orientation = 1
            case .upMirrored: orientation = 2
            case .down: orientation = 3
            case .downMirrored: orientation = 4
            case .leftMirrored: orientation = 5
            case .right: orientation = 6
            case .rightMirrored: orientation = 7
            case .left: orientation = 8
            @unknown default: finish(.failure(ClientError.server("无法识别照片方向"))); return
            }
            finish(.success(CapturedPhoto(image: pixels, orientation: orientation)))
        }
        private func finish(_ result: Result<CapturedPhoto, Error>?) {
            guard !finished else { return }; finished = true
            completion(result)
        }
    }
}
#endif
struct AttachmentStrip: View {
    let attachments: [ChatAttachment]
    var remove: ((String) -> Void)?
    @State private var preview: ChatAttachment?
    var body: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 10) {
                ForEach(attachments) { item in
                    HStack(spacing: 8) {
                        Button { preview = item } label: {
                            HStack(spacing: 8) {
                                if let source = item.dataUrl { NativeRaster(source).frame(width: 46, height: 46).clipShape(RoundedRectangle(cornerRadius: 8)) }
                                else { Image(systemName: item.desktopOnly == true ? "icloud.and.arrow.down" : "doc.text").font(.title3) }
                                VStack(alignment: .leading) { Text(item.name).lineLimit(1); if item.desktopOnly == true { Text("原文件待下载").font(.caption2).foregroundStyle(.secondary) } }
                            }
                        }.buttonStyle(.plain)
                        if let remove { Button { remove(item.id) } label: { Image(systemName: "xmark.circle.fill") }.buttonStyle(.plain).accessibilityLabel("移除附件 \(item.name)") }
                    }.padding(10).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
                }
            }
        }.sheet(item: $preview) { AttachmentPreview(item: $0) }
    }
}
struct AttachmentPreview: View {
    let item: ChatAttachment
    @State private var exporting = false
    @State private var error: String?
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            Group {
                if let source = item.dataUrl { NativeRaster(source, fill: false) }
                else if let text = item.text { ScrollView { Text(text).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading).padding(20) } }
                else { ContentUnavailableView("原文件尚未下载", systemImage: "icloud.and.arrow.down", description: Text("在文件库导入对应原文件后可重新关联。")) }
            }.safeAreaInset(edge: .bottom) { if let error { Text(error).foregroundStyle(.red).padding() } }.navigationTitle(item.name).toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("关闭") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("导出原文件", systemImage: "square.and.arrow.up") { exporting = true }.disabled(item.bytes == nil) }
            }
        }.frame(minWidth: 360, minHeight: 450)
        .fileExporter(isPresented: $exporting, document: BinaryExportDocument(data: item.bytes ?? Data()), contentType: UTType(mimeType: item.mime) ?? .data, defaultFilename: item.name) { result in if case .failure(let failure) = result, (failure as? CocoaError)?.code != .userCancelled { error = failure.localizedDescription } }
    }
}
struct BinaryExportDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.data] }
    var data: Data
    init(data: Data) { self.data = data }
    init(configuration: ReadConfiguration) throws { data = configuration.file.regularFileContents ?? Data() }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper { FileWrapper(regularFileWithContents: data) }
}
