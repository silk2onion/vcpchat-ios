import Foundation
import Testing
import VChatCore
@testable import VChatRendering

struct ToolPresentationTests {
    typealias P = ToolPresentation

    private func call(_ name: String, _ command: String = "ReadFile", closed: Bool = true) -> RenderBlock {
        .vcp(.tool(name, command, "path:「始」目录/文件「末」", closed))
    }

    private func receipt(_ name: String, _ status: String, _ body: String) -> String {
        """
        [[VCP调用结果信息汇总:
        - 工具名称: \(name)
        - 执行状态: \(status)
        - 返回内容: \(body)
        VCP调用结果结束]]
        """
    }

    private func result(_ name: String, _ status: String, _ body: String = "原样输出") throws -> RenderBlock {
        .vcp(try #require(VCPMarkup.parse(receipt(name, status, body)).first))
    }

    private func project(_ source: [RenderBlock], _ mode: ToolPresentationMode,
                         _ expansion: ToolDefaultExpansion = .attention, streaming: Bool = false, media: Bool = true) -> [P.Item] {
        P.project(source, display: .init(mode: mode, expansion: expansion), streaming: streaming, media: media)
    }

    private func rows(_ items: [P.Item]) -> [P.Row] {
        items.flatMap { item -> [P.Row] in
            switch item {
            case .row(let row): [row]
            case .group(let group): rows(group.members)
            case .block: []
            }
        }
    }

    @Test func oldAndPartialPreferences() throws {
        let old = #"{"theme":"paper","wallpaper":"custom","wallpaperCustom":"wall","wallpaperDim":21,"wallpaperBlur":7}"#
        let settings = try JSONDecoder().decode(AppearanceSettings.self, from: Data(old.utf8))
        #expect(settings.theme == .paper && settings.wallpaper == .custom && settings.wallpaperCustom == "wall")
        #expect(settings.wallpaperDim == 21 && settings.wallpaperBlur == 7)
        #expect(settings.tools == ToolDisplay(mode: .legacy, expansion: .attention))
        for (json, expected) in [
            ("{}", ToolDisplay()),
            (#"{"mode":"inline"}"#, ToolDisplay(mode: .inline)),
            (#"{"expansion":"all"}"#, ToolDisplay(expansion: .all))
        ] {
            #expect(try JSONDecoder().decode(ToolDisplay.self, from: Data(json.utf8)) == expected)
        }
        for mode in ToolPresentationMode.allCases {
            for policy in ToolDefaultExpansion.allCases {
                var saved = settings; saved.tools = .init(mode: mode, expansion: policy)
                #expect(try JSONDecoder().decode(AppearanceSettings.self, from: JSONEncoder().encode(saved)) == saved)
            }
        }
    }

    @Test(arguments: ToolPresentationMode.allCases)
    func modeProjectsOnlyAdjacentTools(_ mode: ToolPresentationMode) throws {
        let blocks: [RenderBlock] = [.literal("开头"), call("A"), try result("A","成功"),
                                     call("B"), try result("B","失败"), .html("<div>保留位置</div>"),
                                     call("C"), .literal("结尾")]
        let items = project(blocks, mode)
        let plain = items.compactMap { item -> RenderBlock? in
            if case .block(let block) = item { return block.value }; return nil
        }
        if mode == .legacy {
            #expect(plain == blocks)
            return
        }
        #expect(plain == [.literal("开头"), .html("<div>保留位置</div>"), .literal("结尾")])
        #expect(items.map(\.id).sorted() == items.map(\.id))
        let groups = items.compactMap { item -> P.Group? in if case .group(let g) = item { g } else { nil } }
        switch mode {
        case .compact: #expect(groups.isEmpty && rows(items).count == 5)
        case .grouped: #expect(groups.map(\.style) == [.grouped, .grouped] && groups.map { $0.members.count } == [4, 1])
        case .inline: #expect(groups.map(\.style) == [.inline] && groups[0].members.count == 2)
        case .process: #expect(groups.map(\.style) == [.turn] && groups[0].members.count == 2)
        case .legacy: break
        }
        let recovered = rows(items).flatMap { row -> [RenderBlock] in
            [row.block.value] + (row.partner.map { [.vcp($0)] } ?? [])
        }
        #expect(recovered == [blocks[1],blocks[2],blocks[3],blocks[4],blocks[6]])
    }

    @Test(arguments: ToolDefaultExpansion.allCases)
    func statusAndAttention(_ expansion: ToolDefaultExpansion) throws {
        for (word, expected) in [("✅ 成功", P.Status.success), ("❌ 失败", .failed),
                                 ("pending_approval", .waiting), ("执行中", .running)] {
            let source = [call("A"), try result("A",word), call("B")]
            for mode: ToolPresentationMode in [.compact,.grouped,.inline,.process] {
                let items = project(source, mode, expansion)
                let row = try #require(rows(items).first(where: { $0.hasResult }))
                #expect(row.status == expected)
                let open = expansion == .all || expansion == .attention && (expected == .failed || expected == .waiting)
                #expect(row.startsOpen(expansion) == open)
                for item in items { if case .group(let group) = item { #expect(group.startsOpen == open) } }
            }
        }
    }

    @Test(arguments: ToolPresentationMode.allCases.filter { $0 != .legacy })
    func batchOwnsEachDetailExactlyOnce(_ mode: ToolPresentationMode) async throws {
        let image = "![截图](https://example.org/result.png)"
        let source = """
        前文
        <<<[VCP_TOOL_BATCH_START:t]>>>
        \(receipt("绘图", "成功", image))
        \(receipt("检查", "待确认", "需确认"))
        [本轮工具调用摘要:]
        已返回两份
        [本轮工具调用摘要结束]
        \(receipt("独立", "成功", "单独输出"))
        额外的原始回执文本
        <<<[VCP_TOOL_BATCH_END:t]>>>
        后文
        """
        let renderer = MessageRenderer()
        let blocks = try await renderer.render(source, options: .init(), dark: false)
        let items = project(blocks, mode, .none)
        let visible = rows(items)
        #expect(visible.count == 3)
        let summary = try #require(visible.first { $0.isSummary })
        #expect(summary.block.results.map(\.content) == [image, "需确认"])
        #expect(summary.block.results.map(\.tool) == ["绘图", "检查"])
        #expect(summary.status == .waiting && summary.media && !summary.startsOpen(.none) && summary.startsOpen(.attention))
        let detail = try #require(visible.first { $0.name == "独立" })
        #expect(detail.block.receipt && detail.block.results.isEmpty && detail.preview == "单独输出")
        #expect(visible.last?.preview == "额外的原始回执文本")
        #expect(rows(project(blocks, mode, media: false)).allSatisfy { !$0.media })
        #expect(items.first?.id == 0 && items.last?.id == 5 + 1)
        let payload = try await renderer.receiptBlocks(image, media: true)
        guard case .paragraph(let runs) = payload.first, case .media(let photo) = runs.first else {
            Issue.record("摘要内的 Markdown 图片必须交给原生图片预览"); return
        }
        #expect(photo.kind == "image" && photo.caption == "截图")
    }

    @Test func streamChoiceSurvivesPairGroupAndSummary() throws {
        let open = try #require(rows(project([call("A",closed: false)], .process, streaming: true)).first)
        #expect(open.status == .running)
        let partial = [call("A"), try result("A","成功"), call("B")]
        let liveItems = project(partial, .process, streaming: true)
        let live = try #require(rows(liveItems).first)
        #expect(live.partner != nil && live.id == open.id)
        let finished = project(partial, .process)
        guard case .group(let group) = finished.first else { Issue.record("结束后应按轮折叠"); return }
        let first = try #require(rows(group.members).first)
        #expect(first.choice(in: [open.id: true]) == true && first.choice(in: [open.id: false]) == false)
        let start = "<<<[VCP_TOOL_BATCH_START:1]>>>\n" + receipt("A","成功","一") + "\n" + receipt("B","失败","二")
        let end = "\n[本轮工具调用摘要:]\n结束\n[本轮工具调用摘要结束]\n<<<[VCP_TOOL_BATCH_END:1]>>>"
        let before = rows(project(VCPMarkup.parse(start, streaming: true).map(RenderBlock.vcp), .compact, streaming: true))
        let after = rows(project(VCPMarkup.parse(start + end).map(RenderBlock.vcp), .compact))
        #expect(before.count == 2 && after.count == 1)
        let second = try #require(before.last), summary = try #require(after.first)
        #expect(summary.choice(in: [second.id: true]) == true)
        #expect(summary.block.results.map(\.content) == ["一","二"])
    }

    @Test func collapsedMediaEntriesUseTheNativePayload() throws {
        let clip = "https://example.org/clip.mp4"
        let source = "[回放](\(clip))\n\n`https://example.org/example.mp4`\n\n\(clip)"
        #expect(ToolReceiptVideos.extract(source).map(\.source) == [clip])
        #expect(ToolPresentation.directMedia("https://example.org/out.png?size=2")?.kind == "image")
        #expect(ToolPresentation.directMedia(clip)?.kind == "video")
        let output = try result("视频", "成功", source)
        for mode: ToolPresentationMode in [.compact, .grouped, .inline, .process] {
            let items = project([call("视频"), output, call("B")], mode, .none)
            let row = try #require(rows(items).first { $0.hasResult })
            #expect(row.media && !row.startsOpen(.none))
            for case .group(let group) in items where group.members.contains(where: { $0.id == row.id }) {
                #expect(!group.startsOpen && group.mediaRows.contains(row.id))
            }
        }
    }

    @Test func roleBoundariesAndNonToolBlocksRemainInOrder() throws {
        let output = try result("A", "成功")
        let shell: [RenderBlock] = [.vcp(.divider("user", false)), output, .vcp(.divider("user", true))]
        #expect(rows(project([call("A")] + shell, .inline)).first?.partner != nil)
        let prose: [RenderBlock] = [.vcp(.divider("user", false)), .literal("正文"), output, .vcp(.divider("user", true))]
        let nonTools: [RenderBlock] = [.vcp(.think("思考","想法",true)), .code("swift","代码",[]), .vcp(.push("推送", true))]
        for mode: ToolPresentationMode in [.compact,.grouped,.inline,.process] {
            let items = project([call("A")] + prose + nonTools + [call("B")], mode)
            #expect(rows(items).allSatisfy { $0.partner == nil })
            #expect(items.compactMap { if case .block(let b) = $0 { b.value } else { nil } } == [prose[0],prose[1],prose[3]] + nonTools)
        }
    }
}
