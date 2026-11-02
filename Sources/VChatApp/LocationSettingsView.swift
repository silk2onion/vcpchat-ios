import SwiftUI
import VChatCore
import VChatRendering
#if os(iOS)
import UIKit
#endif

struct LocationSettingsView: View {
    @Bindable var model: ChatViewModel
    @State private var editingPlace: PlaceKind?
    private var palette: WorkspacePalette { .init(theme: model.appearance.theme) }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading,spacing: 22) {
                VStack(alignment: .leading,spacing: 12) {
                    Label("位置与出行",systemImage: "location.fill").font(.title2.bold())
                    Text("聊天时让选定的 Agent 知道你在哪，结合目的地查询附近地点与出行方案。").font(.callout).foregroundStyle(palette.muted)
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
                sectionTitle("常用行程")
                VStack(spacing: 0) {
                    placeRow(.home,place: model.locationSettings.home,icon: "house")
                    WorkspaceSeparator(palette: palette)
                    placeRow(.school,place: model.locationSettings.school,icon: "graduationcap")
                    WorkspaceSeparator(palette: palette)
                    VStack(alignment: .leading,spacing: 8) {
                        Text("常坐线路").font(.headline)
                        TextField("例如 34、35、36",text: $model.locationSettings.preferredLines).textFieldStyle(.roundedBorder)
                    }.padding(17)
                    WorkspaceSeparator(palette: palette)
                    Toggle("出行时主动查车",isOn: $model.locationSettings.commuteAssistance).toggleStyle(.switch).padding(17)
                }.workspaceGlass(palette)
                Text("“家”和“学校”只作为目的地；当前位置以当次测量为准。实时查车由 VCP 已提供的公交或地图工具完成。").font(.footnote).foregroundStyle(palette.muted)
            }.padding(20).frame(maxWidth: 760).frame(maxWidth: .infinity)
        }.navigationTitle("位置与出行").foregroundStyle(palette.ink).tint(palette.accent)
            .background(ThemeWallpaper(model.appearance,animations: model.renderOptions.motion).ignoresSafeArea())
            .onChange(of: model.locationSettings) { _,_ in Task { await model.saveLocationSettings() } }
            .sheet(item: $editingPlace) { kind in LocationPlaceEditor(model: model,kind: kind,place: kind == .home ? model.locationSettings.home : model.locationSettings.school) }
    }
    private func sectionTitle(_ text: String) -> some View { Text(text).font(.system(size: 14,weight: .medium)).foregroundStyle(palette.muted).padding(.leading,6) }
    private func placeRow(_ kind: PlaceKind,place: LocationPlace,icon: String) -> some View {
        Button { editingPlace = kind } label: {
            HStack(spacing: 12) { Image(systemName: icon).frame(width: 28); VStack(alignment: .leading,spacing: 4) { Text(kind.title).font(.headline); Text(place.address.isEmpty ? (place.coordinate == nil ? "设置地址或保存当前位置" : "已保存地点坐标") : place.address).font(.caption).foregroundStyle(palette.muted).lineLimit(2) }; Spacer(); Image(systemName: "chevron.right").foregroundStyle(palette.muted) }
                .padding(17).frame(maxWidth: .infinity,minHeight: 62,alignment: .leading).contentShape(Rectangle())
        }.buttonStyle(WorkspacePress()).accessibilityLabel("设置\(kind.title)")
    }
}
private enum PlaceKind: String, Identifiable { case home, school
    var id: String { rawValue }
    var title: String { self == .home ? "家" : "学校" }
}
private struct LocationPlaceEditor: View {
    @Bindable var model: ChatViewModel
    let kind: PlaceKind
    @State var place: LocationPlace
    @State private var reading = false
    @State private var notice: String?
    @Environment(\.dismiss) private var dismiss
    private var palette: WorkspacePalette { .init(theme: model.appearance.theme) }
    var body: some View {
        VStack(spacing: 0) {
            HStack { Text("设置\(kind.title)").font(.title2.bold()); Spacer(); Button { dismiss() } label: { Image(systemName: "xmark").frame(width: 44,height: 44).contentShape(Rectangle()) }.accessibilityLabel("关闭地点编辑") }.padding(20)
            ScrollView {
                VStack(alignment: .leading,spacing: 18) {
                    TextField("地点名称",text: $place.name).textFieldStyle(.roundedBorder)
                    TextField("地址或地点说明",text: Binding(get: { place.address },set: { place.address = $0; place.coordinate = nil }),axis: .vertical).textFieldStyle(.roundedBorder)
                    Text("填写地址，或在到达这里时保存当前位置。").font(.callout).foregroundStyle(palette.muted)
                    Button {
                        reading = true
                        Task { defer { reading = false }; if let point = await model.location.requestUserLocation() { place.coordinate = point; place.address = ""; notice = nil } else { notice = model.location.statusText } }
                    } label: { Label(reading ? "正在获取位置…" : "使用当前位置",systemImage: "location").frame(maxWidth: .infinity,minHeight: 48).contentShape(Rectangle()) }.buttonStyle(.bordered).disabled(reading)
                    if let point = place.coordinate {
                        Label("已选择地点坐标",systemImage: "mappin.circle.fill").font(.headline)
                        Text(String(format: "%.5f, %.5f · 约 %.0f 米",point.latitude,point.longitude,point.accuracyMeters)).font(.caption).foregroundStyle(palette.muted)
                        Button(role: .destructive) { place.coordinate = nil } label: { Text("移除坐标").frame(maxWidth: .infinity,minHeight: 44).contentShape(Rectangle()) }.buttonStyle(.bordered)
                    }
                    if let notice { Text(notice).foregroundStyle(palette.muted) }
                }.padding(20)
            }
            HStack(spacing: 12) {
                Button { dismiss() } label: { Text("取消").frame(maxWidth: .infinity,minHeight: 48).contentShape(Rectangle()) }.buttonStyle(.bordered)
                Button {
                    if place.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { place.name = kind.title }
                    if kind == .home { model.locationSettings.home = place } else { model.locationSettings.school = place }
                    Task { await model.saveLocationSettings() }; dismiss()
                } label: { Text("保存").fontWeight(.semibold).frame(maxWidth: .infinity,minHeight: 48).contentShape(Rectangle()) }.buttonStyle(.borderedProminent)
            }.padding(20)
        }.foregroundStyle(palette.ink).tint(palette.accent).frame(minWidth: 340,minHeight: 450).background(palette.surface)
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
