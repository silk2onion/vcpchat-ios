import Foundation
import SwiftUI
import VChatCore

private struct ToolDisplayKey: EnvironmentKey { static let defaultValue = ToolDisplay() }
public extension EnvironmentValues {
    var toolDisplay: ToolDisplay {
        get { self[ToolDisplayKey.self] }
        set { self[ToolDisplayKey.self] = newValue }
    }
}

/// A display-only projection. The message source, protocol blocks and result
/// payloads are never rewritten when combining adjacent rows.
enum ToolPresentation {
    enum Status: String, CaseIterable {
        case failed = "失败", waiting = "待确认", running = "执行中", stopped = "已停止"
        case unknown = "状态未知", success = "成功", request = "请求", summary = "摘要"

        init(_ raw: String) {
            switch raw.trimmingCharacters(in: CharacterSet(charactersIn: "✅❌⚠️").union(.whitespacesAndNewlines)).lowercased() {
            case "success", "succeeded", "成功": self = .success
            case "failed", "failure", "error", "失败", "错误": self = .failed
            case "running", "in_progress", "执行中": self = .running
            case "pendingapproval", "pending_approval", "待确认": self = .waiting
            case "stopped", "cancelled", "canceled", "已停止", "已取消": self = .stopped
            default: self = .unknown
            }
        }
        var needsAttention: Bool { self == .failed || self == .waiting }
    }

    enum Family { case explore, terminal }
    enum Kind: CaseIterable {
        case read, search, edit, command, web, media, plan, other
        var icon: String {
            switch self {
            case .read: "doc.text"; case .search: "magnifyingglass"; case .edit: "pencil"
            case .command: "terminal"; case .web: "globe"; case .media: "photo"
            case .plan: "checklist"; case .other: "wrench.and.screwdriver"
            }
        }
        var words: (idle: String, running: String, done: String)? {
            switch self {
            case .read: ("读取","正在读取","已读取")
            case .search: ("搜索","正在搜索","已搜索")
            case .edit: ("编辑","正在编辑","已编辑")
            case .command: ("执行","正在执行","已执行")
            case .web: ("浏览","正在浏览","已浏览")
            case .media: ("生成","正在生成","已生成")
            case .plan: ("更新计划","正在更新计划","已更新计划")
            case .other: nil
            }
        }
        var family: Family? {
            switch self { case .read, .search: .explore; case .command: .terminal; default: nil }
        }
        init(command: String, name: String) {
            switch command {
            case "GetCode", "ReadCode", "ReadFile", "Outline", "ListWorkspaces", "ListProjects", "GetProject", "GetNodeDiff": self = .read
            case "SearchProjects", "FindSymbol", "Trace", "SearchHistory": self = .search
            case "EditCode", "CreateFile", "RemoveFile", "MoveFile", "MoveCode", "CopyCode", "ResolveEdit", "Rollback": self = .edit
            case "ExecutePowerShell", "StartInteractive", "SendInteractiveKey", "PasteInteractiveText", "RunInteractiveSequence", "QueryVisible", "InterruptPowerShell", "EndInteractive": self = .command
            case "UpdateTodos", "SubmitReport": self = .plan
            case "get_page_info": self = .web
            default:
                let name = name.lowercased()
                if name.contains("search") { self = .search }
                else if ["chrome","browser","web","fetch","url"].contains(where: { name.contains($0) }) { self = .web }
                else if ["flux","image","draw","comfy"].contains(where: { name.contains($0) }) { self = .media }
                else { self = .other }
            }
        }
    }
    struct Block: Identifiable {
        var id: Int
        var value: RenderBlock
        var receipt = false
        var results: [VCPMarkup.Result] = []
    }
    struct Row: Identifiable {
        var block: Block
        var segment: VCPMarkup.Segment
        var name: String
        var status: Status
        var kind: Kind
        var resource = ""
        var preview = ""
        var detail = ""
        var media = false
        var partner: VCPMarkup.Segment?
        var partnerReceipt = false
        var partnerID: Int?
        var isSummary: Bool { if case .summary = segment { true } else { false } }
        var id: Int { block.id - block.results.count }
        // A later summary inherits a choice made on one of its still-independent details.
        func choice(in choices: [Int: Bool]) -> Bool? {
            if let value = choices[id] { return value }
            if let partnerID, let value = choices[partnerID] { return value }
            guard !block.results.isEmpty else { return nil }
            return ((id + 1)...block.id).compactMap { choices[$0] }.first
        }
        var title: String {
            name
        }
        var isRequest: Bool { if case .tool = segment { true } else { false } }
        var hasResult: Bool { if case .result = segment { true } else { partner != nil } }
        func startsOpen(_ expansion: ToolDefaultExpansion) -> Bool {
            expansion == .all || expansion == .attention && status.needsAttention
        }
        func lineTitle(_ mode: ToolPresentationMode, streaming: Bool) -> String {
            guard isRequest, mode == .inline || mode == .process, let words = kind.words else { return title }
            if mode == .process || (hasResult && status != .success && status != .running) { return words.idle }
            if hasResult && status == .success { return words.done }
            return streaming || status == .running ? words.running : words.idle
        }
    }
    struct Group: Identifiable {
        enum Style: Hashable { case grouped, inline, turn }
        var style: Style
        var members: [Item]
        var title: String
        var stats: String
        var icon: String
        var startsOpen: Bool
        var id: Int { members[0].id }
        var mediaRows: [Int] { members.compactMap { if case .row(let row) = $0, row.media { row.id } else { nil } } }
    }
    enum Item: Identifiable {
        case block(Block), row(Row), group(Group)
        var id: Int {
            switch self { case .block(let block): block.id; case .row(let row): row.id; case .group(let group): group.id }
        }
    }

    static func project(_ blocks: [RenderBlock], display: ToolDisplay, streaming: Bool, media: Bool) -> [Item] {
        guard display.mode != .legacy else { return blocks.enumerated().map { .block(Block(id: $0.offset, value: $0.element)) } }
        let visible = withoutResultWrappers(receiptBlocks(blocks))
        let pairResults = display.mode == .inline || display.mode == .process
        var items: [Item] = []
        var index = 0
        while index < visible.count {
            let block = visible[index]
            index += 1
            guard var row = row(block, streaming: streaming, media: media) else { items.append(.block(block)); continue }
            if pairResults, row.isRequest, index < visible.count,
               case .vcp(.result(let result, _)) = visible[index].value,
               !result.tool.isEmpty, result.tool == row.name,
               let output = self.row(visible[index], streaming: streaming, media: media) {
                row.partner = output.segment
                row.partnerReceipt = output.block.receipt
                row.partnerID = output.id
                row.status = output.status
                row.preview = output.preview
                row.media = output.media
                index += 1
            }
            items.append(.row(row))
        }
        switch display.mode {
        case .grouped, .inline:
            return foldRuns(items, display: display)
        case .process where !streaming:
            return foldTurn(items, expansion: display.expansion)
        default:
            return items
        }
    }

    struct ReceiptRow: Identifiable {
        let id: Int
        let part: VCPMarkup.Receipt
        var results: [VCPMarkup.Result] = []
    }
    // VCP sends detail records immediately before their summary. Give each
    // record exactly one home; keep standalone or unfinished results visible.
    static func receiptRows(for parts: [VCPMarkup.Receipt]) -> [ReceiptRow] {
        var rows: [ReceiptRow] = [], pending: [ReceiptRow] = []
        for (index, part) in parts.enumerated() {
            var row = ReceiptRow(id: index, part: part)
            switch part {
            case .result(_, true):
                pending.append(row); continue
            case .summary:
                row.results = pending.compactMap { if case .result(let result, _) = $0.part { return result }; return nil }
            default:
                rows.append(contentsOf: pending)
            }
            pending.removeAll(keepingCapacity: true)
            rows.append(row)
        }
        return rows + pending
    }
    // Allocate IDs to protocol slots, including details owned by a summary.
    // Completing an envelope changes neither its earlier slots nor their choices.
    private static func receiptBlocks(_ blocks: [RenderBlock]) -> [Block] {
        var next = 0, output: [Block] = []
        for block in blocks {
            guard case .vcp(.batch(let parts, let closed)) = block, !parts.isEmpty else {
                output.append(Block(id: next, value: block)); next += 1; continue
            }
            for row in receiptRows(for: parts) {
                let segment: VCPMarkup.Segment
                switch row.part {
                case .result(let value, let done): segment = .result(value, done)
                case .summary(let entries, let done): segment = .summary(entries, done)
                case .note(let text): segment = .batch([.note(text)], closed)
                }
                output.append(Block(id: next + row.id, value: .vcp(segment), receipt: true, results: row.results))
            }
            next += parts.count
        }
        return output
    }

    /// A role wrapper containing exclusively results/summaries is transport
    /// framing. A genuine role boundary with prose or a request stays visible.
    private static func withoutResultWrappers(_ blocks: [Block]) -> [Block] {
        var result: [Block] = []
        var i = 0
        while i < blocks.count {
            if case .vcp(.divider(let role,false)) = blocks[i].value {
                var j = i + 1
                while j < blocks.count {
                    if case .vcp(.result) = blocks[j].value { j += 1 }
                    else if case .vcp(.summary) = blocks[j].value { j += 1 }
                    else { break }
                }
                if j > i + 1, j < blocks.count, case .vcp(.divider(role,true)) = blocks[j].value {
                    result.append(contentsOf: blocks[(i + 1)..<j]); i = j + 1; continue
                }
            }
            result.append(blocks[i]); i += 1
        }
        return result
    }

    private static func row(_ block: Block, streaming: Bool, media: Bool) -> Row? {
        guard case .vcp(let segment) = block.value else { return nil }
        switch segment {
        case .tool(let name, let command, let body, let closed):
            let command = command.isEmpty ? VCPMarkup.field(body, "command1") : command
            let kind = Kind(command: command, name: name)
            let target = ["powershell","text","keys","path","paths","filePath","file","glob","query","url","prompt"].lazy
                .map { VCPMarkup.field(body, $0) }.first { !$0.isEmpty } ?? ""
            return Row(block: block, segment: segment, name: name,
                       status: closed ? .request : (streaming ? .running : .stopped), kind: kind,
                       resource: firstLine(target), detail: firstLine(command))
        case .result(let result, let closed):
            let name = result.tool.isEmpty ? "工具结果" : result.tool
            let status: Status = closed || !result.status.isEmpty ? Status(result.status) : (streaming ? .running : .stopped)
            return Row(block: block, segment: segment, name: name, status: status,
                       kind: Kind(command: "", name: name), preview: firstLine(result.content),
                       media: media && hasMedia(result))
        case .summary(let entries, let closed):
            let statuses = block.results.map { Status($0.status) }
            let issue = statuses.contains(.failed) || entries.contains {
                $0.range(of: "❌|失败|错误|拒绝|超时|error|failed|timeout|rejected", options: [.regularExpression, .caseInsensitive]) != nil
            }
            let waiting = statuses.contains(.waiting) || entries.contains { $0.contains("待确认") }
            return Row(block: block, segment: segment, name: "本轮工具调用摘要",
                       status: issue ? .failed : waiting ? .waiting : .summary, kind: .plan,
                       preview: closed ? "\(block.results.isEmpty ? entries.count : block.results.count) 项" : (streaming ? "接收中" : "已中断"),
                       media: media && block.results.contains(where: hasMedia))
        case .batch(let parts, let closed):
            if case .note(let text) = parts.first {
                return Row(block: block, segment: segment, name: "工具回执", status: .summary, kind: .other,
                           preview: firstLine(text), media: media && hasMedia(text))
            }
            return Row(block: block, segment: segment, name: "工具回执",
                       status: closed ? .summary : (streaming ? .running : .stopped), kind: .other)
        case .text, .think, .diary, .divider, .push: return nil
        }
    }
    static func directMedia(_ value: String, caption: String = "") -> MessageMedia? {
        let source = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !source.contains(where: \.isWhitespace) else { return nil }
        let data = source.hasPrefix("data:")
        guard data || MessageMedia.isVideo(source) || caption.lowercased() == "image" ||
                ["png","jpg","jpeg","gif","webp","avif","heic"].contains(URL(string: source)?.pathExtension.lowercased() ?? "") else { return nil }
        return MessageMedia(source: source, caption: caption)
    }
    private static func hasMedia(_ value: String, caption: String = "") -> Bool {
        directMedia(value, caption: caption) != nil || mediaMarkup.firstMatch(in: value, range: NSRange(value.startIndex..., in: value)) != nil
    }
    private static func hasMedia(_ result: VCPMarkup.Result) -> Bool {
        hasMedia(result.content) || result.fields.contains { hasMedia($0.value, caption: $0.key) }
    }
    private static let mediaMarkup = try! NSRegularExpression(pattern: #"(?i)!\[[^\]]*\]\(|<(?:img|video)\b|https?://[^\s<>]+\.(?:mp4|mov|m4v|webm|ogv)(?=[?#\s)>]|$)"#)
    private static func firstLine(_ value: String) -> String {
        let line = value.split(whereSeparator: \.isNewline).lazy.map { $0.trimmingCharacters(in: .whitespaces) }
            .first { !$0.isEmpty && !$0.hasPrefix("```") && !$0.hasPrefix("~~~") } ?? ""
        return String(line.prefix(180))
    }
    private static func foldRuns(_ items: [Item], display: ToolDisplay) -> [Item] {
        var output: [Item] = [], run: [Row] = []
        func flush() {
            if !run.isEmpty, display.mode == .grouped || run.count > 1 {
                let members = run.map(Item.row)
                let issues = run.filter { $0.status == .failed }.count
                let attention = run.contains { $0.status.needsAttention }
                let open = display.expansion == .all || display.expansion == .attention && attention
                if display.mode == .grouped {
                    let resultCount = run.reduce(0) { $0 + $1.block.results.count + ($1.hasResult ? 1 : 0) }
                    let parts = [(run.filter(\.isRequest).count,"请求"),(resultCount,"结果")]
                        .compactMap { $0.0 == 0 ? nil : "\($0.0) \($0.1)" }
                    let stats = Status.allCases.lazy.filter { $0 != .request && $0 != .summary }
                        .compactMap { status -> String? in
                            let count = run.filter { $0.status == status }.count
                            return count == 0 ? nil : "\(count) \(status.rawValue)"
                        }.joined(separator: " · ")
                    let title = parts.isEmpty ? "工具调用摘要" : "工具过程 · " + parts.joined(separator: "  ")
                    output.append(.group(Group(style: .grouped, members: members, title: title,
                                               stats: stats, icon: "wrench.and.screwdriver", startsOpen: open)))
                } else {
                    let terminal = run[0].kind.family == .terminal
                    let read = run.filter { $0.kind == .read }.count
                    let counts = terminal ? "\(run.count) 个命令" : [(read,"个文件"),(run.count - read,"次搜索")]
                        .compactMap { $0.0 == 0 ? nil : "\($0.0) \($0.1)" }.joined(separator: "，")
                    output.append(.group(Group(style: .inline, members: members, title: terminal ? "终端" : "查阅",
                                               stats: counts + (issues == 0 ? "" : "，\(issues) 个失败"),
                                               icon: terminal ? "terminal" : "folder", startsOpen: open)))
                }
            } else { output.append(contentsOf: run.map(Item.row)) }
            run.removeAll(keepingCapacity: true)
        }
        for item in items {
            guard case .row(let row) = item, display.mode == .grouped || row.kind.family != nil else {
                flush(); output.append(item); continue
            }
            if display.mode == .inline, let first = run.first, first.kind.family != row.kind.family { flush() }
            run.append(row)
        }
        flush()
        return output
    }
    private static func foldTurn(_ items: [Item], expansion: ToolDefaultExpansion) -> [Item] {
        var output: [Item] = [], run: [Row] = []
        func flush() {
            let calls = run.filter { !$0.isSummary && $0.status != .summary }
            if calls.count < 2 {
                output.append(contentsOf: run.map(Item.row))
            } else {
                let failed = run.filter { $0.status == .failed }.count
                output.append(.group(Group(style: .turn, members: run.map(Item.row),
                    title: "已处理 · \(calls.count) 次工具调用", stats: failed == 0 ? "" : "\(failed) 个失败",
                    icon: "checkmark.circle", startsOpen: run.contains { $0.startsOpen(expansion) })))
            }
            run.removeAll(keepingCapacity: true)
        }
        for item in items {
            if case .row(let row) = item { run.append(row) }
            else { flush(); output.append(item) }
        }
        flush()
        return output
    }
}
