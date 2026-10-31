import SwiftUI
import VChatCore
import VChatRendering
struct ActivityView: View {
    let model: ChatViewModel
    var close: (() -> Void)?
    @State private var section = 0
    @State private var filter = ActivityKind.all
    @State private var clearing = false
    @State private var limit = 30
    @State private var connection = false
    init(model: ChatViewModel,initialSection: Int = 0,initialFilter: ActivityKind = .all,close: (() -> Void)? = nil) {
        self.model = model; self.close = close; _section = State(initialValue: initialSection); _filter = State(initialValue: initialFilter)
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
    private var palette: WorkspacePalette { .init(theme: model.appearance.theme) }
    var body: some View {
        VStack(spacing: 0) {
            if let close { HStack { Text("通知中心").font(.system(size: 23,weight: .bold)); Spacer(); Button(action: close) { WorkspaceGlyph("close",size: 20).foregroundStyle(palette.muted).frame(width: 44,height: 44) }.accessibilityLabel("关闭通知中心") }.padding(.horizontal,20).padding(.top,12).padding(.bottom,10).overlay(alignment: .bottom) { palette.line.frame(height: 0.5) } }
            HStack(spacing: 10) {
                ForEach(PushChannel.allCases,id: \.self) { channel in
                    VStack(alignment: .leading,spacing: 5) { HStack(spacing: 5) { Circle().fill(model.activity.statuses[channel] == "已连接" ? palette.accent : palette.muted).frame(width: 6,height: 6); Text(channel.title).font(.system(size: 12)) }; Text(model.activity.statuses[channel] ?? "未连接").font(.system(size: 11)).foregroundStyle(palette.muted).padding(.leading,11) }.frame(maxWidth: .infinity,alignment: .leading)
                }
                Button { model.connectPush() } label: { WorkspaceGlyph("history",size: 18).frame(width: 36,height: 36).background(palette.input,in: Circle()) }.accessibilityLabel("重新连接通知")
                Menu { Button("连接设置") { connection = true }; Button("全部标为已读") { Task { await model.activity.markRead() } }; Button("清理已处理日志",role: .destructive) { clearing = true }; Button("断开连接") { Task { await model.activity.disconnect() } } } label: { WorkspaceGlyph("more",size: 18).frame(width: 32,height: 36) }.menuStyle(.borderlessButton).buttonStyle(.plain).fixedSize().accessibilityLabel("通知选项")
            }.padding(.horizontal,18).padding(.vertical,12)
            HStack(spacing: 4) {
                ForEach(0..<3) { index in
                    Button { withAnimation(model.renderOptions.motion ? .easeOut(duration: 0.16) : nil) { section = index } } label: { HStack(spacing: 6) { WorkspaceGlyph(["bell","logs","database"][index],size: 18); Text(["通知","VCPLog","RAG 监视器"][index]).font(.system(size: 13,weight: .semibold)); if index == 0,!model.activity.pending.isEmpty { Text("\(model.activity.pending.count)").font(.system(size: 10,weight: .semibold)).padding(4).background(.orange.opacity(0.6),in: Capsule()) } }.frame(maxWidth: .infinity).frame(minHeight: 41).foregroundStyle(section == index ? palette.ink : palette.muted).background(section == index ? palette.muted.opacity(0.15) : .clear,in: RoundedRectangle(cornerRadius: 11)) }.accessibilityAddTraits(section == index ? [.isSelected] : [])
                }
            }.padding(4).background(palette.muted.opacity(0.08),in: RoundedRectangle(cornerRadius: 14)).padding(.horizontal,16).padding(.bottom,13)
            if section != 1 {
                ScrollView(.horizontal,showsIndicators: false) { HStack(spacing: 7) { ForEach(filters,id: \.self) { kind in Button { filter = kind } label: { Text(kind.title + (kind == .approval && !model.activity.pending.isEmpty ? " \(model.activity.pending.count)" : "")).font(.system(size: 13)).foregroundStyle(filter == kind ? palette.accent : palette.muted).padding(.horizontal,12).frame(minHeight: 32).background(filter == kind ? palette.accent.opacity(0.09) : .clear,in: Capsule()) }.accessibilityAddTraits(filter == kind ? [.isSelected] : []) } }.padding(.horizontal,18) }.padding(.bottom,15)
            }
            if let error = model.activity.error { Text(error).font(.system(size: 13)).foregroundStyle(.red).padding(.horizontal,18) }
            if entries.isEmpty { empty.frame(maxWidth: .infinity,maxHeight: .infinity) }
            else { ScrollView { LazyVStack(alignment: .leading,spacing: 14) { ForEach(entries.prefix(limit)) { ActivityCard(entry: $0,model: model) }; if entries.count > limit { Button("再显示 30 条") { limit += 30 }.workspaceAction(palette) } }.padding(.horizontal,16).padding(.bottom,25) } }
        }.buttonStyle(WorkspacePress()).foregroundStyle(palette.ink).background { if close != nil { palette.solid.ignoresSafeArea() } else { ThemeWallpaper(model.appearance,animations: model.renderOptions.motion).ignoresSafeArea() } }.navigationTitle("通知中心")
        .onChange(of: section) { _,_ in filter = .all; limit = 30 }.onChange(of: filter) { _,_ in limit = 30 }
        .task { await model.activity.markRead() }
        .sheet(isPresented: $connection) { ConnectionView(model: model,focusLogs: true) }
        .confirmationDialog("清理已处理的日志？待审批和等待回执的项目会保留。",isPresented: $clearing,titleVisibility: .visible) { Button("清理日志",role: .destructive) { Task { await model.activity.clear() } } }
    }
    private var empty: some View {
        VStack(spacing: 12) {
            ZStack {
                Circle().stroke(palette.line,lineWidth: 1).frame(width: 110,height: 110)
                Circle().stroke(palette.line,style: StrokeStyle(lineWidth: 1,dash: [3,5])).frame(width: 82,height: 82)
                WorkspaceGlyph(section == 2 ? "database" : filter == .approval ? "shield" : "bell",size: 35).foregroundStyle(palette.accent)
                Circle().fill(palette.accent).frame(width: 8,height: 8).offset(x: 43,y: -29)
                Circle().fill(Color(rgb: 0x88b8d5)).frame(width: 5,height: 5).offset(x: -49,y: 21)
                Circle().fill(Color(rgb: 0xb6a6e0)).frame(width: 5,height: 5).offset(x: 3,y: 52)
            }.frame(height: 130)
            Text(filter == .approval ? "没有待处理的审批" : section == 2 ? "等待信息流接入" : "这里暂时很安静").font(.system(size: 18,weight: .semibold))
            Text(section == 2 ? "知识库、元思考链和 Agent 事件会在这里展开。" : filter == .approval ? "需要你决定的工具调用会优先显示。" : "新事件到来时，右上角会亮起提示。").font(.system(size: 13)).foregroundStyle(palette.muted).multilineTextAlignment(.center).frame(maxWidth: 255)
            Button("连接日志通道") { connection = true }.font(.system(size: 13,weight: .semibold)).padding(.horizontal,18).frame(minHeight: 44).background(palette.input,in: RoundedRectangle(cornerRadius: 14)).padding(.top,10)
        }.padding(28).padding(.bottom,40)
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
        }.padding(16).background(Color(rgb: 0x809bb1).opacity(0.065),in: RoundedRectangle(cornerRadius: 19)).overlay(RoundedRectangle(cornerRadius: 19).stroke(WorkspacePalette(theme: model.appearance.theme).line,lineWidth: 0.6))
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
