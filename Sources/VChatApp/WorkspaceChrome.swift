import SwiftUI
import VChatCore
import VChatRendering

struct WorkspacePalette {
    var theme: AppTheme
    var canvas: Color { theme == .paper ? Color(white: 0.93) : (theme == .aurora ? Color(red: 0.06,green: 0.10,blue: 0.13) : Color(white: 0.07)) }
    var surface: Color { theme == .paper ? .white : (theme == .aurora ? Color(red: 0.09,green: 0.14,blue: 0.17) : Color(white: 0.11)) }
    var chrome: Color { theme == .paper ? Color(white: 0.97) : surface }
    var pinned: Color { theme == .paper ? Color(white: 0.96) : Color(white: 0.14) }
    var accent: Color { theme == .aurora ? theme.tint : Color(red: 0.03,green: 0.76,blue: 0.38) }
    var line: Color { theme == .paper ? .black.opacity(0.07) : .white.opacity(0.07) }
}
struct WorkspaceHeader<Actions: View>: View {
    let title: String; let palette: WorkspacePalette
    @ViewBuilder var actions: () -> Actions
    var body: some View {
        ZStack {
            Text(title).font(.system(size: 18,weight: .semibold))
            HStack(spacing: 0) { Spacer(); actions() }.buttonStyle(.plain)
        }.frame(maxWidth: .infinity).frame(height: 50).padding(.horizontal,10).background(palette.chrome)
    }
}
struct WorkspaceSearch: View {
    @Binding var query: String
    @Binding var showing: Bool
    let prompt: String
    let palette: WorkspacePalette
    @FocusState private var focused: Bool
    var body: some View {
        HStack(spacing: 12) {
            HStack(spacing: 7) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField(prompt,text: $query).textFieldStyle(.plain).focused($focused).font(.system(size: 16))
                if !query.isEmpty { Button { query = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }.accessibilityLabel("清空搜索") }
            }.padding(.horizontal,10).frame(height: 36).background(palette.surface,in: RoundedRectangle(cornerRadius: 7))
            Button("取消") { query = ""; focused = false; showing = false }.foregroundStyle(palette.accent)
        }.buttonStyle(.plain).padding(.horizontal,14).padding(.vertical,8).background(palette.chrome)
        .onAppear { focused = true }
    }
}
struct WorkspaceSeparator: View {
    var palette: WorkspacePalette
    var inset: CGFloat = 72
    var body: some View { palette.line.frame(height: 0.5).padding(.leading,inset) }
}
struct WorkspaceMenuRow: View {
    let title: String; let icon: String; let color: Color
    var detail = ""
    var chevron = true
    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: icon).font(.system(size: 22,weight: .regular)).foregroundStyle(color).frame(width: 28,height: 30)
            Text(title).font(.system(size: 17)).foregroundStyle(.primary)
            Spacer(minLength: 8)
            if !detail.isEmpty { Text(detail).font(.system(size: 13)).foregroundStyle(.secondary) }
            if chevron { Image(systemName: "chevron.right").font(.system(size: 13,weight: .semibold)).foregroundStyle(.tertiary) }
        }.padding(.horizontal,18).frame(minHeight: 56).contentShape(Rectangle())
    }
}
extension View {
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
