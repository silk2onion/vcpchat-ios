import SwiftUI
import VChatCore
import VChatRendering

struct WorkspacePalette {
    var theme: AppTheme
    private var paper: Bool { theme == .paper }
    var canvas: Color { theme.background }
    var surface: Color { theme == .aurora ? Color(rgb: 0x182831) : paper ? .white : Color(rgb: 0x1a1d20) }
    var input: Color { paper ? Color(rgb: 0xeceff1) : theme == .aurora ? Color(rgb: 0x14232b) : Color(rgb: 0x15181b) }
    var ink: Color { paper ? Color(rgb: 0x17201c) : theme == .aurora ? Color(rgb: 0xeaf4f7) : Color(rgb: 0xf2f4f5) }
    var muted: Color { paper ? Color(rgb: 0x78817d) : theme == .aurora ? Color(rgb: 0x96b2be) : Color(rgb: 0x939ba3) }
    var solid: Color { paper ? Color(rgb: 0xf7faf8) : theme == .aurora ? Color(rgb: 0x142a35) : Color(rgb: 0x172632) }
    var glass: Color { paper ? Color(rgb: 0xf8fbf9).opacity(0.90) : theme == .aurora ? Color(rgb: 0x122734).opacity(0.88) : Color(rgb: 0x14202b).opacity(0.87) }
    var soft: Color { paper ? Color(rgb: 0xf7fbf8).opacity(0.73) : theme == .aurora ? Color(rgb: 0x122734).opacity(0.63) : Color(rgb: 0x14202b).opacity(0.64) }
    var accent: Color { theme.tint }
    var accentInk: Color { paper ? .white : theme == .aurora ? Color(rgb: 0x102a32) : Color(rgb: 0x10271b) }
    var line: Color { paper ? Color(rgb: 0x1a3629).opacity(0.13) : theme == .aurora ? Color(rgb: 0xaae0f3).opacity(0.17) : Color(rgb: 0xd2ebf8).opacity(0.13) }
    var chrome: Color { glass }
}
extension Color {
    init(rgb: UInt32) { self.init(red: Double((rgb >> 16) & 255) / 255,green: Double((rgb >> 8) & 255) / 255,blue: Double(rgb & 255) / 255) }
}
private struct WorkspaceMotionKey: EnvironmentKey { static let defaultValue = true }
private struct WorkspaceThemeKey: EnvironmentKey { static let defaultValue = AppTheme.ink }
extension EnvironmentValues {
    var workspaceMotion: Bool { get { self[WorkspaceMotionKey.self] } set { self[WorkspaceMotionKey.self] = newValue } }
    var workspaceTheme: AppTheme { get { self[WorkspaceThemeKey.self] } set { self[WorkspaceThemeKey.self] = newValue } }
}
struct WorkspacePress: ButtonStyle {
    @Environment(\.workspaceMotion) private var motion
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    func makeBody(configuration: Configuration) -> some View {
        // Include the label's padded frame, not only the visible glyph, in hit testing.
        configuration.label.contentShape(Rectangle()).opacity(configuration.isPressed ? 0.82 : 1)
            .scaleEffect(configuration.isPressed && motion && !reduceMotion ? 0.985 : 1)
            .animation(motion && !reduceMotion ? .easeOut(duration: 0.18) : nil,value: configuration.isPressed)
    }
}
struct WorkspaceIconButton: View {
    let icon: String; let label: String
    var accent = false
    var action: () -> Void
    @Environment(\.workspaceTheme) private var theme
    private var palette: WorkspacePalette { .init(theme: theme) }
    var body: some View {
        Button(action: action) { WorkspaceGlyph(icon).frame(width: 42,height: 42).background(accent ? palette.accent : palette.input,in: Circle()).foregroundStyle(accent ? palette.accentInk : palette.ink).frame(minWidth: 44,minHeight: 44) }
            .buttonStyle(WorkspacePress()).accessibilityLabel(label)
    }
}
struct WorkspaceHeader<Actions: View>: View {
    let title: String; var subtitle = ""; let palette: WorkspacePalette
    @ViewBuilder var actions: () -> Actions
    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading,spacing: 5) {
                if !subtitle.isEmpty { Text(subtitle).font(.system(size: subtitle == "VCPCHAT" ? 10 : 13,weight: subtitle == "VCPCHAT" ? .bold : .regular)).tracking(subtitle == "VCPCHAT" ? 1.6 : 0).foregroundStyle(palette.muted) }
                Text(title).font(.system(size: 30,weight: .bold)).tracking(-0.7).foregroundStyle(palette.ink)
            }
            Spacer(minLength: 8)
            HStack(spacing: 6,content: actions)
        }.padding(.horizontal,20).padding(.top,22).padding(.bottom,20).frame(maxWidth: 760)
            .frame(maxWidth: .infinity).background(LinearGradient(colors: [palette.soft,.clear],startPoint: .top,endPoint: .bottom))
    }
}
struct WorkspaceSearch: View {
    @Binding var query: String
    @Binding var showing: Bool
    let prompt: String
    let palette: WorkspacePalette
    @FocusState private var focused: Bool
    var body: some View {
        HStack(spacing: 9) {
            WorkspaceGlyph("search",size: 19).foregroundStyle(palette.muted)
            TextField(prompt,text: $query).textFieldStyle(.plain).font(.system(size: 16)).focused($focused).onSubmit { focused = false }.accessibilityLabel(prompt)
            if !query.isEmpty { Button { query = "" } label: { WorkspaceGlyph("close",size: 16).frame(width: 26,height: 36) }.buttonStyle(WorkspacePress()).accessibilityLabel("清空搜索") }
            if focused { Button("取消") { focused = false }.font(.system(size: 14)).foregroundStyle(palette.accent).buttonStyle(WorkspacePress()) }
        }.padding(.horizontal,13).frame(minHeight: 46).background(palette.input,in: RoundedRectangle(cornerRadius: 13))
            .onChange(of: focused) { _,value in
                #if os(iOS)
                showing = value
                #else
                // A Mac hardware-keyboard focus does not cover the bottom navigation.
                showing = false
                #endif
            }
            .onChange(of: showing) { _,value in if !value { focused = false } }
    }
}
struct WorkspaceSection<Actions: View>: View {
    let title: String; let palette: WorkspacePalette
    @ViewBuilder var actions: () -> Actions
    var body: some View {
        HStack { Text(title).font(.system(size: 14,weight: .medium)); Spacer(); actions() }.foregroundStyle(palette.muted).padding(.top,24).padding(.bottom,10)
    }
}
struct WorkspaceSeparator: View {
    var palette: WorkspacePalette
    var inset: CGFloat = 0
    var body: some View { palette.line.frame(height: 0.5).padding(.leading,inset) }
}
struct WorkspaceMenuRow: View {
    let title: String; let icon: String; let color: Color
    var subtitle = ""
    var detail = ""
    var chevron = true
    var body: some View {
        HStack(spacing: 12) {
            WorkspaceGlyph(icon,size: 21).foregroundStyle(color).frame(width: 35,height: 35).background(color.opacity(0.12),in: RoundedRectangle(cornerRadius: 11))
            VStack(alignment: .leading,spacing: 4) {
                Text(title).font(.system(size: 15,weight: .semibold)).foregroundStyle(.primary)
                if !subtitle.isEmpty { Text(subtitle).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1) }
            }
            Spacer(minLength: 8)
            if !detail.isEmpty { Text(detail).font(.system(size: 12)).foregroundStyle(.secondary) }
            if chevron { WorkspaceGlyph("chevron",size: 18).foregroundStyle(.secondary) }
        }.padding(14).frame(minHeight: 72).contentShape(Rectangle())
    }
}
struct WorkspacePanel<Content: View,Footer: View>: View {
    let title: String; let palette: WorkspacePalette
    var close: () -> Void
    @ViewBuilder var content: () -> Content
    @ViewBuilder var footer: () -> Footer
    var body: some View {
        VStack(spacing: 0) {
            HStack { Text(title).font(.system(size: 22,weight: .bold)); Spacer(); Button(action: close) { WorkspaceGlyph("close",size: 20).foregroundStyle(palette.muted).frame(width: 44,height: 44) }.accessibilityLabel("关闭面板") }.padding(.horizontal,20).padding(.top,10).padding(.bottom,12)
            ScrollView { content().padding(.horizontal,20).padding(.bottom,20).frame(maxWidth: .infinity,alignment: .leading) }.scrollDismissesKeyboard(.interactively)
            footer().padding(.horizontal,20).padding(.vertical,14).frame(maxWidth: .infinity).overlay(alignment: .top) { palette.line.frame(height: 0.5) }
        }.foregroundStyle(palette.ink).buttonStyle(WorkspacePress()).background(palette.solid).tint(palette.accent)
        .presentationCornerRadius(24).presentationDragIndicator(.visible)
    }
}
struct WorkspaceField<Content: View>: View {
    let title: String; let palette: WorkspacePalette
    @ViewBuilder var content: () -> Content
    var body: some View { VStack(alignment: .leading,spacing: 9) { Text(title).font(.system(size: 14)).foregroundStyle(palette.muted); content().textFieldStyle(.plain).font(.system(size: 16)).padding(13).frame(minHeight: 46).background(palette.input,in: RoundedRectangle(cornerRadius: 13)) } }
}
extension View {
    func workspaceGlass(_ palette: WorkspacePalette,radius: CGFloat = 16,soft: Bool = false) -> some View {
        self.background(soft ? palette.soft : palette.glass,in: RoundedRectangle(cornerRadius: radius)).background { RoundedRectangle(cornerRadius: radius).fill(.ultraThinMaterial).opacity(soft ? 0.25 : 0.5) }.overlay(RoundedRectangle(cornerRadius: radius).stroke(palette.line,lineWidth: 0.6))
    }
    func workspaceAction(_ palette: WorkspacePalette,primary: Bool = false) -> some View {
        self.font(.system(size: 15,weight: .semibold)).frame(maxWidth: .infinity).frame(minHeight: 46).foregroundStyle(primary ? palette.accentInk : palette.ink).background(primary ? palette.accent : palette.input,in: RoundedRectangle(cornerRadius: 14)).contentShape(RoundedRectangle(cornerRadius: 14))
    }
    @ViewBuilder func workspaceRootNavigation() -> some View {
        #if os(iOS)
        self.toolbar(.hidden,for: .navigationBar)
        #else
        self.navigationTitle("VChat")
        #endif
    }
    @ViewBuilder func workspaceDetailNavigation() -> some View {
        #if os(iOS)
        self.toolbar(.visible,for: .navigationBar).navigationBarTitleDisplayMode(.inline)
        #else
        self
        #endif
    }
}

struct WorkspaceDetailHeader<Actions: View>: View {
    let title: String; let palette: WorkspacePalette
    var note = ""
    var back: (() -> Void)? = nil
    @ViewBuilder var actions: () -> Actions
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        HStack(spacing: 12) {
            WorkspaceIconButton(icon: "back",label: "返回",action: { if let back { back() } else { dismiss() } })
            Text(title).font(.system(size: 22,weight: .bold)).foregroundStyle(palette.ink).lineLimit(1)
            Spacer(minLength: 4)
            if !note.isEmpty { Text(note).font(.system(size: 11)).foregroundStyle(palette.muted) }
            actions()
        }.padding(.horizontal,20).padding(.vertical,16).background(palette.glass).background(.ultraThinMaterial)
    }
}

struct WorkspaceSegments: View {
    let titles: [String]
    @Binding var selection: Int
    let palette: WorkspacePalette
    @Environment(\.workspaceMotion) private var motion
    var body: some View {
        HStack(spacing: 4) { ForEach(Array(titles.enumerated()),id: \.offset) { index,title in Button { withAnimation(motion ? .easeOut(duration: 0.16) : nil) { selection = index } } label: { Text(title).font(.system(size: 13,weight: .semibold)).foregroundStyle(selection == index ? palette.ink : palette.muted).frame(maxWidth: .infinity).frame(minHeight: 38).background(selection == index ? palette.glass : .clear,in: RoundedRectangle(cornerRadius: 10)) }.accessibilityAddTraits(selection == index ? [.isSelected] : []) } }.padding(4).background(palette.input,in: RoundedRectangle(cornerRadius: 13)).buttonStyle(WorkspacePress())
    }
}
