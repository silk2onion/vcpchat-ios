import SwiftUI
import VChatCore
import VChatRendering
#if os(iOS)
import UIKit
#endif

struct LocationSettingsView: View {
    @Bindable var model: ChatViewModel
    @State private var syncURLDraft = ""
    @State private var syncFormatDraft: FootprintSyncFormat = .batchJSON
    @State private var syncTokenInput = ""
    @State private var syncDraftLoaded = false
    @State private var tokenLoadedForCurrentDraft = false
    @State private var tokenLoadVersion = UUID()
    @State private var syncNotice: String?
    @State private var syncingNow = false
    private var palette: WorkspacePalette { .init(theme: model.appearance.theme) }
    private var draftValidatedURL: URL? {
        FootprintSettings(syncEndpointURL: syncURLDraft).validatedHTTPSURL()
    }
    private var draftDestinationChanged: Bool {
        FootprintIdentityStore.canonicalEndpointKey(syncURLDraft) != FootprintIdentityStore.canonicalEndpointKey(model.footprint.settings.syncEndpointURL)
    }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading,spacing: 22) {
                VStack(alignment: .leading,spacing: 12) {
                    Label("位置共享",systemImage: "location.fill").font(.title2.bold())
                    Text("向选定的 Agent 分享发送消息时的位置。附近搜索、出行等用法由各个 Agent 的指引和服务器工具决定。").font(.callout).foregroundStyle(palette.muted)
                    Toggle("自动附带发送时的位置",isOn: Binding(get: { model.locationSettings.enabled },set: { model.setLocationSharing($0) })).toggleStyle(.switch)
                    Label(model.locationSettings.enabled ? model.location.statusText : "自动共享已关闭",systemImage: "location.circle").font(.footnote).foregroundStyle(palette.muted)
                    if model.locationSettings.enabled {
                        Button { Task { await model.location.requestUserLocation() } } label: { Text("更新位置").frame(maxWidth: .infinity,minHeight: 44).contentShape(Rectangle()) }.buttonStyle(.bordered)
                        #if os(iOS)
                        if model.location.availability == .denied {
                            Button { if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) } } label: { Text("前往系统设置允许定位").frame(maxWidth: .infinity,minHeight: 44).contentShape(Rectangle()) }
                        }
                        #endif
                    }
                    Text("仅在前台定位。发送消息时可使用 15 分钟内的最近位置，超过 60 秒会标记为缓存；不向设备连接推送坐标。").font(.footnote).foregroundStyle(palette.muted)
                }.padding(18).workspaceGlass(palette)
                sectionTitle("自动共享给谁")
                VStack(spacing: 0) {
                    ForEach(model.agents) { agent in
                        Button {
                            if model.locationSettings.agentIDs.contains(agent.id) { model.locationSettings.agentIDs.remove(agent.id) }
                            else { model.locationSettings.agentIDs.insert(agent.id) }
                        } label: {
                            HStack(spacing: 12) {
                                ContactAvatar(name: agent.name,image: agent.avatarUrl,kind: .agent,size: 36)
                                Text(agent.name).frame(maxWidth: .infinity,alignment: .leading)
                                Image(systemName: model.locationSettings.agentIDs.contains(agent.id) ? "checkmark.circle.fill" : "circle").foregroundStyle(model.locationSettings.agentIDs.contains(agent.id) ? palette.accent : palette.muted)
                            }.padding(15).frame(maxWidth: .infinity,minHeight: 58).contentShape(Rectangle())
                        }.buttonStyle(WorkspacePress()).accessibilityLabel("向\(agent.name)自动共享位置").accessibilityValue(model.locationSettings.agentIDs.contains(agent.id) ? "已选择" : "未选择")
                        if agent.id != model.agents.last?.id { WorkspaceSeparator(palette: palette) }
                    }
                }.workspaceGlass(palette).disabled(!model.locationSettings.enabled)
                NavigationLink { SavedPlacesView(model: model).workspaceDetailNavigation() } label: {
                    HStack { Label("常用地点",systemImage: "mappin.and.ellipse"); Spacer(); Text("\(model.locationSettings.places.count)"); Image(systemName: "chevron.right") }.padding(18).frame(maxWidth: .infinity,minHeight: 58).contentShape(Rectangle())
                }.buttonStyle(WorkspacePress()).workspaceGlass(palette)
                Text("地点名称、别名和共享对象都可自定义。到 Agent 资料中设置“位置相关指引”，例如使用哪个城市的公交或地图工具；不会自动安装服务器插件。").font(.footnote).foregroundStyle(palette.muted)

                sectionTitle("本地足迹与行程感知（独立隔离）")
                VStack(alignment: .leading, spacing: 14) {
                    Label("本地全年足迹", systemImage: "figure.walk.motion").font(.headline)
                    Text("独立保存在本机 LocationTracks/location-tracks.sqlite，默认零云端依赖，无需修改 VCPToolBox 后端。聊天定位不会借用足迹库回填坐标，仅在白名单精确发送时现场计算近 30 分钟移动与停留语义。").font(.footnote).foregroundStyle(palette.muted)
                    Toggle(
                        "开启本地足迹记录",
                        isOn: Binding(
                            get: { model.footprint.settings.enabled },
                            set: { model.footprint.setEnabled($0) }
                        )
                    ).toggleStyle(.switch)
                    Label(model.footprint.statusText, systemImage: "record.circle").font(.footnote).foregroundStyle(palette.muted)
                    if model.footprint.settings.enabled {
                        Picker(
                            "采集档位",
                            selection: Binding(
                                get: { model.footprint.settings.mode },
                                set: { mode in
                                    var next = model.footprint.settings
                                    next.mode = mode
                                    model.footprint.persistSettings(next)
                                }
                            )
                        ) {
                            ForEach(FootprintTrackingMode.allCases, id: \.self) { mode in
                                Text(mode.title).tag(mode)
                            }
                        }
                        .pickerStyle(.segmented)
                        Text(model.footprint.settings.mode.detail).font(.caption).foregroundStyle(palette.muted)
                        #if os(iOS)
                        if !model.footprint.hasAlwaysAuthorization {
                            Button {
                                if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
                            } label: {
                                Text("前往系统设置授予「始终允许」以支持后台足迹").frame(maxWidth: .infinity, minHeight: 44).contentShape(Rectangle())
                            }.buttonStyle(.bordered)
                        }
                        #endif
                    }
                    NavigationLink { FootprintTimelineView(model: model).workspaceDetailNavigation() } label: {
                        HStack {
                            Label("查看全年足迹地图与导出 GeoJSON", systemImage: "map")
                            Spacer()
                            Image(systemName: "chevron.right")
                        }
                        .padding(.vertical, 8)
                        .frame(maxWidth: .infinity, minHeight: 44)
                        .contentShape(Rectangle())
                    }.buttonStyle(WorkspacePress())
                }.padding(18).workspaceGlass(palette)

                sectionTitle("可选外部足迹同步（默认关闭）")
                VStack(alignment: .leading, spacing: 12) {
                    Toggle(
                        "开启 HTTPS 外部同步",
                        isOn: Binding(
                            get: { model.footprint.settings.syncEnabled },
                            set: { enabled in
                                var next = model.footprint.settings
                                next.syncEnabled = enabled
                                model.footprint.persistSettings(next)
                            }
                        )
                    ).toggleStyle(.switch)
                    Text("仅在状态跃迁或移动每 3–5 分钟批量推送；静止休眠态零唤醒。支持极简批量 JSON 与 OwnTracks 标准协议。").font(.footnote).foregroundStyle(palette.muted)
                    if model.footprint.settings.syncEnabled {
                        TextField(
                            "HTTPS 服务地址（例如 https://track.example.com）",
                            text: $syncURLDraft
                        )
                        .textFieldStyle(.roundedBorder)
                        #if os(iOS)
                        .textInputAutocapitalization(.never)
                        .keyboardType(.URL)
                        #endif
                        .autocorrectionDisabled()

                        if !syncURLDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && draftValidatedURL == nil {
                            Text("必须使用有效的 https:// 地址，拒绝明文 HTTP。").font(.caption).foregroundStyle(.red)
                        }

                        Picker("同步协议格式", selection: $syncFormatDraft) {
                            ForEach(FootprintSyncFormat.allCases, id: \.self) { fmt in
                                Text(fmt.title).tag(fmt)
                            }
                        }
                        .pickerStyle(.segmented)

                        SecureField("写入 Token（按服务地址隔离存入持久钥匙串）", text: $syncTokenInput)
                            .textFieldStyle(.roundedBorder)
                        if draftDestinationChanged && !syncURLDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                            Text("检测到更换服务地址：已清空旧服务器 Token 输入，请为新地址输入独立写入 Token。").font(.caption).foregroundStyle(.orange)
                        }

                        Button {
                            Task {
                                let trimmedToken = syncTokenInput.trimmingCharacters(in: .whitespacesAndNewlines)
                                if draftDestinationChanged && trimmedToken.isEmpty {
                                    syncNotice = "更换同步地址后必须输入新服务器的独立写入 Token。"
                                    return
                                }
                                do {
                                    // Same destination: if token was loaded and user explicitly cleared it, pass "" to delete from Keychain.
                                    let tokenToPersist: String? = (draftDestinationChanged || tokenLoadedForCurrentDraft || !trimmedToken.isEmpty)
                                        ? trimmedToken
                                        : nil
                                    try await model.footprint.commitSyncConfiguration(
                                        endpointURL: syncURLDraft,
                                        format: syncFormatDraft,
                                        writeToken: tokenToPersist
                                    )
                                    syncNotice = "已保存同步目标与凭据（如更换地址，旧目标待发队列已隔离清空）。"
                                } catch {
                                    syncNotice = "保存同步配置失败：\(error.localizedDescription)"
                                }
                            }
                        } label: {
                            Text("保存同步配置").frame(maxWidth: .infinity, minHeight: 40).contentShape(Rectangle())
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(draftValidatedURL == nil || (draftDestinationChanged && syncTokenInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty))

                        HStack {
                            Text("待同步队列：\(model.footprint.pendingSyncCount) 点")
                                .font(.caption)
                                .foregroundStyle(palette.muted)
                            Spacer()
                            Button(syncingNow ? "同步中…" : "立即同步") {
                                syncingNow = true
                                Task {
                                    defer { syncingNow = false }
                                    if let res = await model.footprint.syncNow() {
                                        syncNotice = "已确认 \(res.ackedPointIDs.count) 点，拒绝 \(res.rejectedPointIDs.count) 点。"
                                    } else if let err = model.footprint.lastSyncError {
                                        syncNotice = "同步失败：\(err)"
                                    } else {
                                        syncNotice = "当前无待同步记录。"
                                    }
                                }
                            }
                            .buttonStyle(.bordered)
                            .disabled(syncingNow || model.footprint.settings.validatedHTTPSURL() == nil)
                        }
                        if let syncNotice {
                            Text(syncNotice).font(.caption).foregroundStyle(palette.muted)
                        }
                    }
                }.padding(18).workspaceGlass(palette)

                if !model.locationSettings.unassignedGuidance.isEmpty {
                    VStack(alignment: .leading,spacing: 8) {
                        Text("旧版未分配指引").font(.headline)
                        Text(model.locationSettings.unassignedGuidance).textSelection(.enabled)
                        Text("已保留，可复制到某个 Agent 的位置相关指引中；不会自动发送。").font(.caption).foregroundStyle(palette.muted)
                    }.padding(18).workspaceGlass(palette)
                }
            }.padding(20).frame(maxWidth: 760).frame(maxWidth: .infinity)
        }.navigationTitle("位置共享").foregroundStyle(palette.ink).tint(palette.accent)
            .background(ThemeWallpaper(model.appearance,animations: model.renderOptions.motion).ignoresSafeArea())
            .onChange(of: model.locationSettings) { _,_ in Task { await model.saveLocationSettings() } }
            .task {
                guard !syncDraftLoaded else { return }
                syncDraftLoaded = true
                await reloadSyncDraft()
            }
            .onChange(of: syncURLDraft) { _, newValue in
                // Always clear token draft immediately on ANY URL edit (prevents A -> B(enter B token) -> paste A leakage).
                syncTokenInput = ""
                tokenLoadedForCurrentDraft = false
                let loadID = UUID()
                tokenLoadVersion = loadID
                let newKey = FootprintIdentityStore.canonicalEndpointKey(newValue)
                let savedKey = FootprintIdentityStore.canonicalEndpointKey(model.footprint.settings.syncEndpointURL)
                if !newKey.isEmpty && newKey == savedKey {
                    Task {
                        do {
                            let loaded = try await model.footprint.readWriteToken(for: newValue, allowingInteraction: false)
                            guard tokenLoadVersion == loadID,
                                  FootprintIdentityStore.canonicalEndpointKey(syncURLDraft) == newKey else { return }
                            syncTokenInput = loaded
                            tokenLoadedForCurrentDraft = true
                        } catch {
                            // Read failed (e.g., locked Keychain): keep tokenLoadedForCurrentDraft = false so saving won't erase existing token.
                            guard tokenLoadVersion == loadID else { return }
                            tokenLoadedForCurrentDraft = false
                        }
                    }
                }
            }
            .onChange(of: model.footprint.settings.syncEnabled) { _, enabled in
                tokenLoadVersion = UUID()
                tokenLoadedForCurrentDraft = false
                if !enabled {
                    syncTokenInput = ""
                    syncNotice = nil
                } else {
                    Task { await reloadSyncDraft() }
                }
            }
    }
    private func reloadSyncDraft() async {
        let loadID = UUID()
        tokenLoadVersion = loadID
        tokenLoadedForCurrentDraft = false
        let savedURL = model.footprint.settings.syncEndpointURL
        let savedKey = FootprintIdentityStore.canonicalEndpointKey(savedURL)
        syncURLDraft = savedURL
        syncFormatDraft = model.footprint.settings.syncFormat
        guard !savedKey.isEmpty else {
            if tokenLoadVersion == loadID {
                syncTokenInput = ""
                tokenLoadedForCurrentDraft = true
            }
            return
        }
        do {
            let token = try await model.footprint.readWriteToken(for: savedURL, allowingInteraction: false)
            guard tokenLoadVersion == loadID,
                  FootprintIdentityStore.canonicalEndpointKey(syncURLDraft) == savedKey else { return }
            syncTokenInput = token
            tokenLoadedForCurrentDraft = true
        } catch {
            // Do NOT mark loaded on read error; prevents silent credential deletion when user only changes format.
            if tokenLoadVersion == loadID {
                syncTokenInput = ""
                tokenLoadedForCurrentDraft = false
            }
        }
    }
    private func sectionTitle(_ text: String) -> some View { Text(text).font(.system(size: 14,weight: .medium)).foregroundStyle(palette.muted).padding(.leading,6) }
}
struct SavedPlacesView: View {
    @Bindable var model: ChatViewModel
    @State private var editing: LocationPlace?
    @State private var removing: LocationPlace?
    private var palette: WorkspacePalette { .init(theme: model.appearance.theme) }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading,spacing: 18) {
                Text("保存任何常去的地方，用别名告诉 Agent 你说的是哪里。每个地点单独选择可共享的 Agent。").font(.callout).foregroundStyle(palette.muted)
                Button { editing = LocationPlace(sharedAgentIDs: model.locationSettings.agentIDs) } label: {
                    Label("添加地点",systemImage: "plus").frame(maxWidth: .infinity,minHeight: 48).contentShape(Rectangle())
                }.buttonStyle(.borderedProminent)
                if model.locationSettings.places.isEmpty { ContentUnavailableView("还没有常用地点",systemImage: "mappin.and.ellipse",description: Text("家、公司、学校、健身房，都可以自己命名。")) }
                ForEach(model.locationSettings.places) { place in
                    Button { editing = place } label: {
                        HStack(spacing: 14) {
                            Image(systemName: "mappin.circle").font(.title2)
                            VStack(alignment: .leading,spacing: 6) {
                                Text(place.name).font(.headline)
                                Text(place.address.isEmpty ? "已保存坐标" : place.address).lineLimit(2).font(.caption).foregroundStyle(palette.muted)
                                Text("共享给 \(model.agents.filter { place.sharedAgentIDs.contains($0.id) }.count) 个 Agent").font(.caption).foregroundStyle(palette.muted)
                            }; Spacer(); Image(systemName: "chevron.right")
                        }.padding(18).frame(maxWidth: .infinity,minHeight: 72,alignment: .leading).contentShape(Rectangle())
                    }.buttonStyle(WorkspacePress()).workspaceGlass(palette)
                    .contextMenu { Button("删除地点",role: .destructive) { removing = place } }
                }
            }.padding(20).frame(maxWidth: 760).frame(maxWidth: .infinity)
        }.navigationTitle("常用地点").foregroundStyle(palette.ink).tint(palette.accent)
        .background(ThemeWallpaper(model.appearance,animations: model.renderOptions.motion).ignoresSafeArea())
        .sheet(item: $editing) { LocationPlaceEditor(model: model,place: $0) }
        .confirmationDialog("删除这个常用地点？",isPresented: Binding(get: { removing != nil },set: { if !$0 { removing = nil } }),titleVisibility: .visible,presenting: removing) { place in
            Button("删除地点",role: .destructive) { Task { await model.removeLocationPlace(place.id) } }
        }
    }
}
private struct LocationPlaceEditor: View {
    @Bindable var model: ChatViewModel
    @State var place: LocationPlace
    @State private var aliases: String
    init(model: ChatViewModel,place: LocationPlace) {
        self.model = model; _place = State(initialValue: place); _aliases = State(initialValue: place.aliases.joined(separator: "、"))
    }
    @State private var captureTask: Task<Void,Never>?
    @State private var candidate: MeasuredLocation?
    @State private var reading = false
    @State private var saving = false
    @State private var notice: String?
    @State private var deleting = false
    @Environment(\.dismiss) private var dismiss
    private var palette: WorkspacePalette { .init(theme: model.appearance.theme) }
    private var existing: Bool { model.locationSettings.places.contains { $0.id == place.id } }
    var body: some View {
        VStack(spacing: 0) {
            HStack { Text(existing ? "编辑地点" : "添加地点").font(.title2.bold()); Spacer(); Button { dismiss() } label: { Image(systemName: "xmark").frame(width: 44,height: 44).contentShape(Rectangle()) }.accessibilityLabel("关闭地点编辑") }.padding(20)
            ScrollView {
                VStack(alignment: .leading,spacing: 18) {
                    field("地点名称") { TextField("例如 公司、健身房",text: $place.name) }
                    field("别名") { TextField("用逗号分隔，例如 家、回家",text: $aliases) }
                    field("地址") { TextField("地址",text: Binding(get: { place.address },set: { place.address = $0; place.coordinate = nil }),axis: .vertical) }
                    field("地点备注") { TextField("例如 从西门出发、入口在二楼",text: $place.note,axis: .vertical) }
                    Button {
                        reading = true
                        captureTask = Task { @MainActor in
                            defer { reading = false }
                            let result = await model.location.captureFreshPoint()
                            guard !Task.isCancelled else { return }
                            switch result {
                            case .ready(let fix) where model.location.current(fix) && fix.readyToSave(at: Date().timeIntervalSince1970):
                                place.coordinate = fix.point; notice = nil
                            case .ready(let fix), .confirm(let fix):
                                if model.location.current(fix) { candidate = fix }
                            case .unavailable: notice = "未取得可用位置，原坐标未更改。"
                            }
                        }
                    } label: { Label(reading ? "正在获取位置…" : "保存当前位置坐标",systemImage: "location").frame(maxWidth: .infinity,minHeight: 48).contentShape(Rectangle()) }.buttonStyle(.bordered).disabled(reading)
                    if let point = place.coordinate {
                        Text(String(format: "%.5f, %.5f · 约 %.0f 米",point.latitude,point.longitude,point.accuracyMeters)).font(.caption).foregroundStyle(palette.muted)
                        Button(role: .destructive) { place.coordinate = nil } label: { Text("移除坐标").frame(maxWidth: .infinity,minHeight: 44).contentShape(Rectangle()) }.buttonStyle(.bordered)
                    }
                    Text("共享给谁").font(.headline)
                    Text("只有选中的 Agent 会收到这个地点；分享当前位置一次不会绕过这里的选择。").font(.caption).foregroundStyle(palette.muted)
                    ForEach(model.agents) { agent in
                        Button {
                            if place.sharedAgentIDs.contains(agent.id) { place.sharedAgentIDs.remove(agent.id) } else { place.sharedAgentIDs.insert(agent.id) }
                        } label: {
                            HStack { Text(agent.name); Spacer(); Image(systemName: place.sharedAgentIDs.contains(agent.id) ? "checkmark.circle.fill" : "circle") }.padding(.horizontal,12).frame(maxWidth: .infinity,minHeight: 48).contentShape(Rectangle())
                        }.buttonStyle(WorkspacePress())
                    }
                    if let notice { Text(notice).foregroundStyle(palette.muted) }
                    if existing { Button(role: .destructive) { deleting = true } label: { Text("删除地点").frame(maxWidth: .infinity,minHeight: 44).contentShape(Rectangle()) }.buttonStyle(.bordered) }
                }.padding(20)
            }
            HStack(spacing: 12) {
                Button { dismiss() } label: { Text("取消").frame(maxWidth: .infinity,minHeight: 48).contentShape(Rectangle()) }.buttonStyle(.bordered)
                Button {
                    place.aliases = aliases.components(separatedBy: CharacterSet(charactersIn: ",，、\n")).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
                    saving = true
                    Task {
                        defer { saving = false }
                        if await model.saveLocationPlace(place) { dismiss() } else { notice = model.error }
                    }
                } label: { Text(saving ? "正在保存…" : "保存").fontWeight(.semibold).frame(maxWidth: .infinity,minHeight: 48).contentShape(Rectangle()) }.buttonStyle(.borderedProminent)
                    .disabled(reading || saving || place.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !place.configured)
            }.padding(20)
        }.foregroundStyle(palette.ink).tint(palette.accent).frame(minWidth: 340,minHeight: 450).background(palette.surface)
        .onDisappear { captureTask?.cancel() }
        .alert("采用这个候选坐标？", isPresented: Binding(get: { candidate != nil }, set: { if !$0 { candidate = nil } }), presenting: candidate) { fix in
            Button("采用坐标") {
                if model.location.current(fix) { place.coordinate = fix.point; notice = nil }
                else { notice = "授权已更改或坐标已过期，请重新获取。" }
            }
            Button("保留原坐标", role: .cancel) {}
        } message: { fix in
            Text(String(format: "%.0f 秒前 · 误差约 %.0f 米 · %@", fix.point.ageSeconds(), fix.point.accuracyMeters, fix.point.precise ? "精确定位" : "大致定位"))
        }
        .confirmationDialog("删除这个常用地点？",isPresented: $deleting,titleVisibility: .visible) { Button("删除地点",role: .destructive) { Task { if await model.removeLocationPlace(place.id) { dismiss() } else { notice = model.error } } } }
    }
    private func field<Content: View>(_ title: String,@ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading,spacing: 8) { Text(title).font(.headline); content().textFieldStyle(.roundedBorder) }
    }
}
struct LocationSharingChip: View {
    @Bindable var model: ChatViewModel
    @State private var settings = false
    var body: some View {
        HStack(spacing: 0) {
            Button { settings = true } label: {
                Label(model.location.statusText,systemImage: "location.fill").font(.caption).lineLimit(1).frame(maxWidth: .infinity,minHeight: 44,alignment: .leading).contentShape(Rectangle())
            }.buttonStyle(.plain).accessibilityLabel("查看本条消息的位置共享")
            Button { model.omitLocationOnce() } label: { Image(systemName: "xmark").font(.caption).frame(width: 44,height: 44).contentShape(Rectangle()) }.buttonStyle(.plain).disabled(model.busy).accessibilityLabel("这条消息不附带位置")
        }.foregroundStyle(model.appearance.theme.tint).padding(.horizontal,23)
            .sheet(isPresented: $settings) { NavigationStack { LocationSettingsView(model: model).toolbar { Button("完成") { settings = false } } }.frame(minWidth: 350,minHeight: 540) }
    }
}
