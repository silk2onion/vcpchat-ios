import SwiftUI
import VChatCore
import VChatRendering
#if os(iOS)
import UIKit
#endif

struct LocationSettingsView: View {
    @Bindable var model: ChatViewModel
    private var palette: WorkspacePalette { .init(theme: model.appearance.theme) }
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
                    Text("仅在前台按需获取，不持续追踪。发送时的位置会交给你配置的 VCP 和模型服务，不写入本机聊天正文。").font(.footnote).foregroundStyle(palette.muted)
                }.padding(18).workspaceGlass(palette)
                sectionTitle("自动共享给谁")
                VStack(spacing: 0) {
                    ForEach(model.agents) { agent in
                        Button {
                            if model.locationSettings.agentIDs.contains(agent.id) { model.locationSettings.agentIDs.remove(agent.id) }
                            else { model.locationSettings.agentIDs.insert(agent.id); model.prefetchLocation() }
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
                        Task { defer { reading = false }; if let point = await model.location.requestUserLocation() { place.coordinate = point; notice = nil } else { notice = model.location.statusText } }
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
