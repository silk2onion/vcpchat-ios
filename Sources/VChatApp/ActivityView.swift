import SwiftUI
import VChatCore
import VChatRendering
struct ActivityView: View {
    let model: ChatViewModel
    @State private var section = 0
    @State private var filter = ActivityKind.all
    @State private var clearing = false
    init(model: ChatViewModel,initialSection: Int = 0,initialFilter: ActivityKind = .all) {
        self.model = model; _section = State(initialValue: initialSection); _filter = State(initialValue: initialFilter)
    }
    private let ragKinds: Set<ActivityKind> = [.rag,.thinking,.agent,.memory,.dream]
    var filters: [ActivityKind] { section == 2 ? [.all,.rag,.thinking,.agent,.memory,.dream] : [.all,.approval,.notification,.error,.handled] }
    var entries: [ActivityEntry] {
        model.activity.entries.filter { entry in
            if section == 1 { return entry.channel == .log }
            if section == 2 { return ragKinds.contains(entry.kind) && (filter == .all || entry.kind == filter) }
            if ragKinds.contains(entry.kind) { return false }
            if filter == .approval || filter == .handled { let pending = entry.approvalStatus(in: model.activity.entries,now: model.activity.now) == "待审批"; return entry.data["type"].text == "tool_approval_request" && (filter == .approval ? pending : !pending) }
            return filter == .all || entry.kind == filter
        }
    }
    var body: some View {
        VStack(spacing: 0) {
            HStack { ForEach(PushChannel.allCases,id: \.self) { channel in Label(channel.title + " · " + (model.activity.statuses[channel] ?? "未连接"),systemImage: "circle.fill").font(.caption).foregroundStyle(model.activity.statuses[channel] == "已连接" ? .green : .secondary).accessibilityLabel(channel.title + " · " + (model.activity.statuses[channel] ?? "未连接")) } }.padding(14)
            Picker("分区",selection: $section) { Text("通知 \(model.activity.pending.count)").tag(0); Text("VCPLog").tag(1); Text("RAG 监视器").tag(2) }.pickerStyle(.segmented).labelsHidden().padding(.horizontal,16).padding(.bottom,8).onChange(of: section) { _, _ in filter = .all }
            if section != 1 { ScrollView(.horizontal) { HStack { ForEach(filters,id: \.self) { kind in Button { filter = kind } label: { Text(kind.title + (kind == .approval ? " \(model.activity.pending.count)" : "")).font(.callout.weight(.medium)).padding(.horizontal,14).frame(minHeight: 40).background(filter == kind ? model.appearance.theme.tint.opacity(0.2) : .clear,in: Capsule()) }.buttonStyle(.plain) } }.padding(.horizontal,16) }.padding(.bottom,8) }
            ScrollView { LazyVStack(alignment: .leading,spacing: 14) {
                if let error = model.activity.error { Text(error).foregroundStyle(.red) }
                if entries.isEmpty { ContentUnavailableView("暂无\(filter == .all ? "事件" : filter.title)",systemImage: filter.icon) }
                ForEach(entries) { ActivityCard(entry: $0,model: model) }
            }.padding(16) }
        }.background(ThemeWallpaper(model.appearance).ignoresSafeArea()).navigationTitle("通知与监视")
        .toolbar { Button { model.connectPush() } label: { Image(systemName: "arrow.clockwise") }.accessibilityLabel("重新连接通知"); Menu { Button("全部标为已读") { Task { await model.activity.markRead() } }; Button("清理已处理日志",role: .destructive) { clearing = true }; Button("断开连接") { Task { await model.activity.disconnect() } } } label: { Image(systemName: "ellipsis") } }
        .task { await model.activity.markRead() }
        .confirmationDialog("清理已处理的日志？待审批和等待回执的项目会保留。",isPresented: $clearing,titleVisibility: .visible) { Button("清理日志",role: .destructive) { Task { await model.activity.clear() } } }
    }
}
private struct ActivityCard: View {
    let entry: ActivityEntry; let model: ChatViewModel
    @State private var reason = ""
    @State private var argumentsOpen = true
    @State private var sending = false
    @State private var error: String?
    var data: JSONValue { entry.data }
    var safeOptions: RenderOptions { var value = model.renderOptions; value.html = false; return value }
    var bodyText: String { for key in ["extractedMemories","narrative","error","content","message","text","summary","result","reason","query"] { if data[key] != .null { return data[key].text.isEmpty ? data[key].pretty : data[key].text } }; return "" }
    var body: some View {
        VStack(alignment: .leading,spacing: 12) {
            HStack(spacing: 10) { Image(systemName: entry.kind.icon).foregroundStyle(model.appearance.theme.tint); VStack(alignment: .leading) { Text(entry.kind == .approval ? "工具审批" : entry.kind.title).font(.caption).foregroundStyle(.secondary); Text(entry.title).font(.headline).lineLimit(2) }; Spacer(); Text(Date(timeIntervalSince1970: entry.createdAt),style: .time).font(.caption2).foregroundStyle(.secondary) }
            if entry.kind == .approval && data["type"].text == "tool_approval_request" {
                TimelineView(.periodic(from: .now,by: 1)) { context in Text(entry.approvalStatus(in: model.activity.entries,now: context.date.timeIntervalSince1970)).font(.caption.weight(.semibold)).foregroundStyle(.secondary) }
                Text(data["reason"].text.isEmpty ? data["aiReason"].text : data["reason"].text)
                Text([first(data,["maid","agentName"]),data["args"]["command"].text].filter { !$0.isEmpty }.joined(separator: " · ")).font(.caption).foregroundStyle(.secondary)
                let target = first(data["args"],["path","filePath","url"])
                if !target.isEmpty { Text(target).font(.callout.monospaced()).textSelection(.enabled) }
                DisclosureGroup("调用参数",isExpanded: $argumentsOpen) { Text(data["args"].pretty).font(.caption.monospaced()).textSelection(.enabled) }
                if data["changePreview"] != .null { DisclosureGroup("变更预览") { Text(data["changePreview"].pretty).font(.caption.monospaced()).textSelection(.enabled) } }
                TimelineView(.periodic(from: .now,by: 1)) { context in
                    if entry.approvalStatus(in: model.activity.entries,now: context.date.timeIntervalSince1970) == "待审批" {
                        TextField("给 Agent 的说明（可选）",text: $reason,axis: .vertical).lineLimit(2...4)
                        HStack { Button("拒绝",role: .destructive) { respond(false) }; Spacer(); Button(sending ? "正在发送…" : "允许一次") { respond(true) }.buttonStyle(.borderedProminent) }.disabled(sending)
                    }
                }
                if let decision = entry.decision { Text((decision.approved ? "允许" : "拒绝") + (decision.reason.isEmpty ? "" : "：" + decision.reason)).font(.caption) }
            } else if entry.kind == .rag {
                let flags = ["useRerank": "ReRank","useBM25": "BM25","useRiverMemo": "RiverMemo","useTagMemo": "TagBoost","fromCache": "缓存命中","useTime": "时间检索"].filter { data[$0.key].bool == true }.map(\.value).sorted()
                Text(([data["k"].text.isEmpty ? "" : "K " + data["k"].text] + flags + data["coreTags"].array.map(\.text)).filter { !$0.isEmpty }.joined(separator: " · ")).font(.caption).foregroundStyle(.secondary)
                if !data["query"].text.isEmpty { RichMessageBody(data["query"].text,options: safeOptions) }
                Text("\(data["results"].array.count) 条相关记录").font(.subheadline.weight(.semibold))
                ForEach(Array(data["results"].array.enumerated()),id: \.offset) { index,result in
                    NativeRAGResult(index: index,result: result,options: safeOptions)
                }
            } else {
                if !bodyText.isEmpty { RichMessageBody(bodyText,options: safeOptions) }
                let messages = data["messages"].array.isEmpty && data["type"].text == "AGENT_PRIVATE_CHAT_PREVIEW" ? [JSONValue.object(["role": .string("USER"),"content": data["query"]]),.object(["role": .string("AI RESPONSE"),"content": data["response"]])] : data["messages"].array
                ForEach(Array(messages.enumerated()),id: \.offset) { _,message in VStack(alignment: .leading) { Text(first(message,["name","role"])).font(.caption).foregroundStyle(.secondary); RichMessageBody(message["content"].text,options: safeOptions) } }
                ForEach(Array(data["stages"].array.enumerated()),id: \.offset) { index,stage in VStack(alignment: .leading) { Text("阶段 \(stage["stage"].text.isEmpty ? String(index + 1) : stage["stage"].text) · \(stage["clusterName"].text)").font(.subheadline.weight(.semibold)); ForEach(Array(stage["results"].array.enumerated()),id: \.offset) { _,result in Text(result["source"].text).font(.caption); RichMessageBody(result["text"].text,options: safeOptions) } } }
                ForEach(Array(data["seeds"].array.enumerated()),id: \.offset) { _,seed in Text(seed["file"].text).font(.caption); RichMessageBody(seed["snippet"].text,options: safeOptions) }
                ForEach(["associations","operations"],id: \.self) { key in if !data[key].array.isEmpty { DisclosureGroup(key == "associations" ? "联想记录" : "操作记录") { Text(data[key].pretty).font(.caption.monospaced()).textSelection(.enabled) } } }
            }
            if let error { Text(error).foregroundStyle(.red).font(.callout) }
            DisclosureGroup("原始数据") { Text(entry.payload.pretty).font(.caption.monospaced()).textSelection(.enabled); ShareLink(item: entry.payload.pretty) { Label("分享 JSON",systemImage: "square.and.arrow.up") } }
        }.padding(16).background(.regularMaterial,in: RoundedRectangle(cornerRadius: 18))
    }
    func first(_ value: JSONValue,_ keys: [String],fallback: String = "") -> String { keys.map { value[$0].text }.first(where: { !$0.isEmpty }) ?? fallback }
    func respond(_ approved: Bool) { sending = true; error = nil; Task { defer { sending = false }; do { try await model.activity.respond(entry,approved: approved,reason: reason) } catch { self.error = error.localizedDescription } } }
}

private struct NativeRAGResult: View {
    let index: Int; let result: JSONValue; let options: RenderOptions
    @State private var expanded: Bool
    init(index: Int,result: JSONValue,options: RenderOptions) { self.index = index; self.result = result; self.options = options; _expanded = State(initialValue: index < 2) }
    private func first(_ keys: [String],fallback: String = "") -> String { keys.map { result[$0].text }.first(where: { !$0.isEmpty }) ?? fallback }
    var body: some View {
        DisclosureGroup(isExpanded: $expanded) {
            if let score = result["originalScore"].number { Text("原始分数 \(score.formatted(.number.precision(.fractionLength(3))))").font(.caption).foregroundStyle(.secondary) }
            RichMessageBody(first(["text","content","pageContent"]),options: options).padding(.top,6)
        } label: { HStack { Text("\(index + 1). " + first(["source","fileName","title"],fallback: "知识片段")); Spacer(); if let score = result["score"].number { Text(score.formatted(.number.precision(.fractionLength(3)))).font(.caption.monospacedDigit()) } } }
    }
}
