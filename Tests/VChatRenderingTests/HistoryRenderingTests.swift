import Foundation
import Testing
@testable import VChatRendering

struct HistoryRenderingTests {
    private let first = #"<style>p{color:red}</style><div id="vcp-root">你好</div>"#
    private let second = #"<style>p{color:blue}</style><div id="vcp-root">☕</div>"#

    @Test(arguments: [
        ("中文**“加粗”**继续", "中文“加粗”继续", "“加粗”"),
        ("😀**加粗**", "😀加粗", "加粗"),
        ("**加粗**👨‍👩‍👧‍👦", "加粗👨‍👩‍👧‍👦", "加粗")
    ])
    func historicalBold(_ example: (input: String, text: String, bold: String)) async throws {
        let blocks = try await MessageRenderer().render(example.input, options: .init(), dark: false)
        let inline = try #require(blocks.first)
        guard case .paragraph(let runs) = inline else { Issue.record("Expected a paragraph"); return }
        let attributed = runs.compactMap { run in
            if case .text(let text) = run { return text }
            return nil
        }
        #expect(attributed.map { String($0.characters) }.joined() == example.text)
        let bold = attributed.flatMap { text in
            text.runs.filter { $0.inlinePresentationIntent?.contains(.stronglyEmphasized) == true }
                .map { String(text[$0.range].characters) }
        }
        #expect(bold.joined() == example.bold)
    }

    @Test(arguments: ["继续", "", "查看 **详情** 👀", "<div>显示原文</div>"])
    func standaloneUserButtonReceipt(_ title: String) async throws {
        let token = "[[点击按钮:" + title + "]]"
        let blocks = try await MessageRenderer().render(token, options: .init(), dark: false, role: "user")
        #expect(blocks == [.buttonReceipt(title)])
    }

    @Test func buttonExamplesAndPlainTextKeepTheirMeaning() async throws {
        let renderer = MessageRenderer(), token = "[[点击按钮:继续]]"
        for (role, text) in [("assistant", token), ("user", "示例：" + token), ("user", "[[点击按钮:未闭合")] {
            let blocks = try await renderer.render(text, options: .init(), dark: false, role: role)
            #expect(blocks == [.paragraph([.text(AttributedString(text))])])
        }
        var plain = RenderOptions()
        plain.enabled = false
        #expect(try await renderer.render(token, options: plain, dark: false, role: "user") == [.literal(token)])
    }

    @Test func receiptUsesMarkdownWithLiteralHTML() async throws {
        let input = """
        | 标题 | 结果 |
        | --- | --- |
        | 甲 | `a|b` |

        2. [查看](https://example.org)
        3. <b>原文</b>

        ```html
        <div id="vcp-root">不执行</div>
        ```

        <script>alert(1)</script>
        """
        var options = RenderOptions(); options.media = false; options.code = false
        let blocks = try await MessageRenderer().receiptBlocks(input, options: options, dark: false)
        #expect(blocks.count == 4)
        guard case .table(let rows) = blocks[0], case .list(let items, 2) = blocks[1],
              case .paragraph(let first) = items[0][0], case .paragraph(let second) = items[1][0],
              case .code("html", let code, _) = blocks[2], case .literal(let raw) = blocks[3] else { Issue.record("wrong receipt structure"); return }
        #expect(rows.count == 2)
        #expect(first.contains { if case .text(let s) = $0 { s.link?.host == "example.org" } else { false } })
        #expect(second.compactMap { if case .text(let s) = $0 { String(s.characters) } else { nil } }.joined() == "<b>原文</b>")
        #expect(code.contains("<div")); #expect(raw.contains("<script>"))
    }

    @Test func historicalTableKeepsEmptyAndOmittedCells() async throws {
        let source = """
        | 项目 |      | 状态 |
        | ---- | ---- | ---- |
        | 甲   |      | 完成 |
        | 乙   |
        """
        let blocks = try await MessageRenderer().render(source, options: .init(), dark: false)
        func cell(_ value: String) -> [InlineRun] { [.text(AttributedString(value))] }
        #expect(blocks == [.table([
            [cell("项目"), [], cell("状态")],
            [cell("甲"), [], cell("完成")],
            [cell("乙"), [], []]
        ])])
    }

    @Test func severalStyledCardsDoNotShareOffsetsOrConsumeProse() async throws {
        let source = first + "\n\n" + second
        let renderer = MessageRenderer()
        let options = RenderOptions()
        let blocks = try await renderer.render(source, options: options, dark: false)
        #expect(blocks == [.html(first), .html(second)])
        let isolated = "<style>p{color:green}</style>"
        #expect(HTMLIslandPolicy.extractSections(from: first + "\n\n正文\n\n" + isolated + "\n\n后文\n\n" + second) == [
            .island(first), .markdown("\n\n正文\n\n" + isolated + "\n\n后文\n\n"), .island(second)
        ])
    }

    @Test func fencedExamplesAndExistingScriptsKeepTheirMeaning() async throws {
        let script = "<script>window.counter = 1;</script>"
        let bare = #"<div id="vcp-root">你好</div>"#
        let renderer = MessageRenderer()
        let single = try await renderer.render(bare + script, options: .init(), dark: false)
        #expect(single == [.html(bare + script)])
        let multiple = try await renderer.render(first + script + "\n\n" + second, options: .init(), dark: false)
        #expect(multiple == [.html(first + script), .html(second)])
        let code = "```html\n" + first + "\n```"
        #expect(HTMLIslandPolicy.extractSections(from: code) == [.markdown(code)])
        let fakeID = #"<div title='id="vcp-root"'>伪造根节点</div>"#
        #expect(HTMLIslandPolicy.extractSections(from: fakeID) == [.markdown(fakeID)])
    }
}
