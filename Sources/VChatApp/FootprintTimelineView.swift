import CoreLocation
import MapKit
import SwiftUI
import VChatCore
import VChatRendering

struct FootprintTimelineView: View {
    @Bindable var model: ChatViewModel
    @State private var scope: FootprintTimelineScope = .day
    @State private var anchorDate = Date()
    @State private var segments: [FootprintSegment] = []
    @State private var summary = FootprintPeriodSummary(pointCount: 0, segmentCount: 0, activeDays: 0, totalDistanceMeters: 0)
    @State private var cameraPosition: MapCameraPosition = .automatic
    @State private var loading = false
    @State private var exportURL: URL?
    @State private var exportTask: Task<Void, Never>?
    @State private var exportVersion = UUID()
    @State private var notice: String?
    @State private var confirmClearAll = false
    @State private var confirmClear30Days = false

    private var palette: WorkspacePalette { .init(theme: model.appearance.theme) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                headerControls
                mapCard
                summaryGrid
                actionCard
                if let notice {
                    Text(notice)
                        .font(.footnote)
                        .foregroundStyle(palette.muted)
                        .padding(.horizontal, 6)
                }
            }
            .padding(20)
            .frame(maxWidth: 760)
            .frame(maxWidth: .infinity)
        }
        .navigationTitle("本地足迹")
        .foregroundStyle(palette.ink)
        .tint(palette.accent)
        .background(ThemeWallpaper(model.appearance, animations: model.renderOptions.motion).ignoresSafeArea())
        .task(id: "\(scope.rawValue)-\(Int(anchorDate.timeIntervalSince1970))") {
            await reloadRange()
        }
        .confirmationDialog("清空全部本地足迹？", isPresented: $confirmClearAll, titleVisibility: .visible) {
            Button("清空全部足迹并推进防回灌水位", role: .destructive) {
                Task { await clearHistory(beforeMs: nil) }
            }
        } message: {
            Text("将删除本机全部足迹记录与待同步队列，并推进防回灌水位，避免离线旧点复活。")
        }
        .confirmationDialog("清理 30 天前的历史足迹？", isPresented: $confirmClear30Days, titleVisibility: .visible) {
            Button("删除 30 天前记录", role: .destructive) {
                let cutoff = Int64((Date().addingTimeInterval(-30 * 86_400).timeIntervalSince1970 * 1000.0).rounded())
                Task { await clearHistory(beforeMs: cutoff) }
            }
        }
    }

    private var headerControls: some View {
        VStack(alignment: .leading, spacing: 12) {
            Picker("时间范围", selection: $scope) {
                ForEach(FootprintTimelineScope.allCases, id: \.self) { item in
                    Text(item.title).tag(item)
                }
            }
            .pickerStyle(.segmented)

            HStack {
                Button { shiftAnchor(-1) } label: {
                    Image(systemName: "chevron.left")
                        .frame(width: 44, height: 36)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.bordered)
                .accessibilityLabel("上一个时间段")

                Spacer()
                Text(periodLabel)
                    .font(.headline)
                    .monospacedDigit()
                Spacer()

                Button { shiftAnchor(1) } label: {
                    Image(systemName: "chevron.right")
                        .frame(width: 44, height: 36)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.bordered)
                .disabled(isCurrentPeriod)
                .accessibilityLabel("下一个时间段")
            }
        }
        .padding(16)
        .workspaceGlass(palette)
    }

    private var mapCard: some View {
        ZStack(alignment: .topTrailing) {
            Map(position: $cameraPosition) {
                ForEach(segments) { segment in
                    if segment.isPolylineDrawable {
                        MapPolyline(
                            coordinates: segment.points.map {
                                CLLocationCoordinate2D(latitude: $0.latitude, longitude: $0.longitude)
                            }
                        )
                        .stroke(palette.accent, lineWidth: 4)
                    } else {
                        ForEach(segment.points) { pt in
                            MapCircle(
                                center: CLLocationCoordinate2D(latitude: pt.latitude, longitude: pt.longitude),
                                radius: max(25, min(pt.accuracyMeters, 2000))
                            )
                            .foregroundStyle(palette.accent.opacity(pt.accuracyAuth == .full ? 0.35 : 0.16))
                            .stroke(palette.accent.opacity(0.65), lineWidth: 1.5)
                        }
                    }
                }
            }
            .mapStyle(.standard)
            .frame(height: 360)
            .clipShape(RoundedRectangle(cornerRadius: 18))

            if loading {
                ProgressView()
                    .padding(10)
                    .background(.ultraThinMaterial, in: Circle())
                    .padding(12)
            } else if segments.isEmpty {
                Text("该时段暂无足迹")
                    .font(.caption.weight(.medium))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(.ultraThinMaterial, in: Capsule())
                    .padding(12)
            }
        }
        .workspaceGlass(palette)
    }

    private var summaryGrid: some View {
        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
            metricTile("精确里程", value: String(format: "%.2f km", summary.totalDistanceMeters / 1000.0))
            metricTile("独立路段", value: "\(summary.segmentCount) 段")
            metricTile("轨迹点数", value: "\(summary.pointCount) 点")
            metricTile("活跃天数", value: "\(summary.activeDays) 天")
        }
    }

    private func metricTile(_ title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.caption).foregroundStyle(palette.muted)
            Text(value).font(.title3.bold()).monospacedDigit()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .workspaceGlass(palette)
    }

    private var actionCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("导出与数据管理").font(.headline)
            Text("严格按 segment_id 分段导出 GeoJSON，跨缺口不拉直线，大致精度点仅以单点导出。").font(.footnote).foregroundStyle(palette.muted)

            if let exportURL {
                ShareLink(item: exportURL) {
                    Label("分享 / 保存 GeoJSON 文件", systemImage: "square.and.arrow.up")
                        .frame(maxWidth: .infinity, minHeight: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.borderedProminent)
            }

            Button {
                startGeoJSONExport()
            } label: {
                Label("生成当前时段 GeoJSON", systemImage: "doc.badge.arrow.up")
                    .frame(maxWidth: .infinity, minHeight: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.bordered)
            .disabled(segments.isEmpty)

            HStack(spacing: 12) {
                Button(role: .destructive) { confirmClear30Days = true } label: {
                    Text("清理 30 天前").frame(maxWidth: .infinity, minHeight: 44).contentShape(Rectangle())
                }
                .buttonStyle(.bordered)

                Button(role: .destructive) { confirmClearAll = true } label: {
                    Text("清空全部").frame(maxWidth: .infinity, minHeight: 44).contentShape(Rectangle())
                }
                .buttonStyle(.bordered)
            }
        }
        .padding(16)
        .workspaceGlass(palette)
    }

    private var periodLabel: String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        switch scope {
        case .day: formatter.dateFormat = "yyyy 年 M 月 d 日"
        case .month: formatter.dateFormat = "yyyy 年 M 月"
        case .year: formatter.dateFormat = "yyyy 年"
        }
        return formatter.string(from: anchorDate)
    }

    private var isCurrentPeriod: Bool {
        let cal = Calendar.current
        switch scope {
        case .day: return cal.isDate(anchorDate, inSameDayAs: Date())
        case .month: return cal.isDate(anchorDate, equalTo: Date(), toGranularity: .month)
        case .year: return cal.isDate(anchorDate, equalTo: Date(), toGranularity: .year)
        }
    }

    private func shiftAnchor(_ delta: Int) {
        let cal = Calendar.current
        let component: Calendar.Component = switch scope {
        case .day: .day
        case .month: .month
        case .year: .year
        }
        if let shifted = cal.date(byAdding: component, value: delta, to: anchorDate) {
            anchorDate = min(shifted, Date())
        }
    }

    private func invalidateExport() {
        exportTask?.cancel()
        exportTask = nil
        exportVersion = UUID()
        exportURL = nil
    }

    private func reloadRange() async {
        invalidateExport()
        loading = true
        defer { loading = false }
        do {
            let store = try await model.footprint.openStoreForUI()
            let (fromMs, toMs) = scope.rangeMs(around: anchorDate)
            let maxRenderPoints = scope == .year ? 4000 : (scope == .month ? 2500 : nil)
            let payload = try await store.timelinePayload(fromMs: fromMs, toMs: toMs, maxTotalPoints: maxRenderPoints)
            segments = payload.segments
            summary = payload.summary
            cameraPosition = .automatic
            notice = nil
        } catch {
            segments = []
            summary = FootprintPeriodSummary(pointCount: 0, segmentCount: 0, activeDays: 0, totalDistanceMeters: 0)
            notice = "读取本地足迹失败：\(error.localizedDescription)"
        }
    }

    private func startGeoJSONExport() {
        invalidateExport()
        // Snapshot scope, anchor, range, and filename at tap time so switching tabs cannot mislabel the file.
        let capturedScope = scope
        let capturedAnchor = anchorDate
        let capturedRange = capturedScope.rangeMs(around: capturedAnchor)
        let formatter = DateFormatter()
        formatter.dateFormat = capturedScope == .day ? "yyyy-MM-dd" : (capturedScope == .month ? "yyyy-MM" : "yyyy")
        let capturedFileName = "vchat-footprint-\(formatter.string(from: capturedAnchor)).geojson"
        let version = exportVersion

        exportTask = Task {
            do {
                let store = try await model.footprint.openStoreForUI()
                let fullSegments = try await store.segments(fromMs: capturedRange.fromMs, toMs: capturedRange.toMs, maxTotalPoints: nil)
                guard !Task.isCancelled, exportVersion == version else { return }
                let data = try FootprintGeoJSONExporter.export(segments: fullSegments)
                let exportDir = FootprintTracker.exportDirectoryURL
                try FileManager.default.createDirectory(at: exportDir, withIntermediateDirectories: true)
                let url = exportDir.appendingPathComponent(capturedFileName)
                guard !Task.isCancelled, exportVersion == version else { return }
                try data.write(to: url, options: [.atomic])
                guard !Task.isCancelled, exportVersion == version else {
                    try? FileManager.default.removeItem(at: url)
                    return
                }
                exportURL = url
                notice = "已生成 \(capturedFileName)（\(ByteCountFormatter.string(fromByteCount: Int64(data.count), countStyle: .file))）。"
            } catch {
                guard !Task.isCancelled, exportVersion == version else { return }
                notice = "导出 GeoJSON 失败：\(error.localizedDescription)"
            }
        }
    }

    private func clearHistory(beforeMs: Int64?) async {
        invalidateExport()
        do {
            let meta = try await model.footprint.clearHistory(beforeMs: beforeMs)
            await reloadRange()
            notice = "清理完成（clear_epoch=\(meta.clearEpoch)）。"
        } catch {
            notice = "清理失败：\(error.localizedDescription)"
        }
    }
}