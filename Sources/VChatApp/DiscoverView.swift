import SwiftUI
import VChatCore

struct DiscoverView: View {
    enum Screen: Hashable { case notifications,log,rag,memory }
    let model: ChatViewModel
    @Binding var atRoot: Bool
    @State private var path: [Screen] = []
    var body: some View {
        NavigationStack(path: $path) {
            List {
                Section {
                    HStack(spacing: 14) {
                        Image(systemName: "bubble.left.and.bubble.right").foregroundStyle(.orange).frame(width: 26)
                        Text("VCP 论坛")
                        Spacer()
                        Text("后续接入").font(.caption).foregroundStyle(.secondary)
                    }.padding(.vertical,8)
                }
                Section {
                    NavigationLink(value: Screen.memory) { Label("记忆动态",systemImage: "brain.head.profile") }
                    NavigationLink(value: Screen.rag) { Label("RAG 监视器",systemImage: "cylinder.split.1x2") }
                } footer: { Text("查看 VCP 推送到本机的检索与记忆记录。") }
                Section {
                    NavigationLink(value: Screen.notifications) { HStack { Label("通知与审批",systemImage: "bell"); Spacer(); if model.activity.unread > 0 { Text("\(model.activity.unread)").font(.caption).foregroundStyle(.secondary) } } }
                    NavigationLink(value: Screen.log) { Label("VCPLog",systemImage: "waveform.path") }
                }
            }.navigationTitle("发现")
            .navigationDestination(for: Screen.self) { screen in
                switch screen {
                case .notifications: ActivityView(model: model)
                case .log: ActivityView(model: model,initialSection: 1)
                case .rag: ActivityView(model: model,initialSection: 2)
                case .memory: ActivityView(model: model,initialSection: 2,initialFilter: .memory)
                }
            }
        }.onChange(of: path) { _,value in atRoot = value.isEmpty }
        .onAppear { atRoot = path.isEmpty }
    }
}
