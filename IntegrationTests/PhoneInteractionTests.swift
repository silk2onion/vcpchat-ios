import SwiftUI
import UIKit
import UserNotifications
import WebKit
import XCTest
import SQLite3
@testable import VChatCore
@testable import VChatRendering
@testable import VChat

final class PhoneInteractionTests: XCTestCase {
    @MainActor func testEndpointModeSurvivesReopenWithoutSavingDraftServerOrUnlockingKeys() throws {
        let defaults = UserDefaults.standard, modeKey = ChatViewModel.endpointModePreference
        let oldConfig = defaults.object(forKey: "native.connection"), oldMode = defaults.object(forKey: modeKey)
        defer {
            defaults.set(oldConfig, forKey: "native.connection"); defaults.set(oldMode, forKey: modeKey)
        }
        defaults.removeObject(forKey: modeKey)
        let saved = ConnectionConfiguration(server: "https://saved.invalid", model: "test", endpointMode: .vcpTools)
        defaults.set(try JSONEncoder().encode(saved), forKey: "native.connection")
        let model = ChatViewModel()
        XCTAssertEqual(model.configuration.endpointMode, .vcpTools) // existing installations
        model.configuration.server = "https://unsaved.invalid"
        model.credentialsLocked = true
        for mode in [EndpointMode.standard, .vcpTools] {
            model.selectEndpointMode(mode)
            let reopened = ChatViewModel().configuration
            XCTAssertEqual(reopened.server, saved.server)
            XCTAssertEqual(reopened.model, saved.model)
            XCTAssertEqual(try reopened.chatEndpoint().path, mode == .vcpTools ? "/v1/chatvcp/completions" : "/v1/chat/completions")
        }
    }

    @MainActor private func host<V: View>(_ content: V) throws -> UIWindow {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.rootViewController = UIHostingController(rootView: content)
        window.makeKeyAndVisible()
        window.layoutIfNeeded()
        return window
    }

    @MainActor private func find<T: UIView>(_ type: T.Type, in root: UIView) -> T? {
        if let found = root as? T { return found }
        for child in root.subviews {
            if let found = find(type, in: child) { return found }
        }
        return nil
    }

    @MainActor private func eventually(_ description: String, file: StaticString = #filePath, line: UInt = #line, _ check: @MainActor () async -> Bool) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now + .seconds(12)
        while clock.now < deadline {
            if await check() { return }
            try await Task.sleep(for: .milliseconds(60))
        }
        XCTFail("Timed out: " + description, file: file, line: line)
    }

    @MainActor private func makeReplyDatabase() async throws -> (URL, ChatStore) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return (root, try await ChatStore.open(path: root.appendingPathComponent("chat.sqlite").path))
    }

    @MainActor private func addReplyTopic(_ db: ChatStore, ownerID: String = "fixture") async throws -> ChatTopic {
        let topic = ChatTopic(ownerId: ownerID)
        try await db.put(topic, kind: "topic", id: topic.id)
        return topic
    }

    private let receiptID = "2026-11-19T22:50:25.956+08:00"
    private func batch(_ body: String, id: String, shell: Bool = true) -> String {
        let source = "<<<[VCP_TOOL_BATCH_START:\(id)]>>>\n" + body + "\n<<<[VCP_TOOL_BATCH_END:\(id)]>>>"
        return shell ? "<<<[ROLE_DIVIDE_USER]>>>\n"+source+"\n<<<[END_ROLE_DIVIDE_USER]>>>" : source
    }

    @MainActor func testStickerDirectoryAndImagesHonorDeploymentPrefix() throws {
        let model = ChatViewModel()
        for suffix in ["", "/v1", "/v1/chat/completions", "/v1/chatvcp/completions"] {
            model.configuration.server = "https://fixture.invalid/team/vcp" + suffix
            let base = try XCTUnwrap(model.stickerDeployment)
            XCTAssertEqual(base.appendingPathComponent("admin_api/emojis/list").absoluteString,
                           "https://fixture.invalid/team/vcp/admin_api/emojis/list")
            let context = StickerContext(server: base, fileKey: "fixture", catalog: nil)
            let image = try XCTUnwrap(context.resolve("images/猫表情包/笑.png"))
            XCTAssertEqual(image.path, "/team/vcp/pw=fixture/images/猫表情包/笑.png")
        }
    }

    func testLegacyTailStylesAndScriptsRemainInsideTheirCard() {
        let root = #"<div id="vcp-root">card</div>"#
        let tail = root + "\n<style>.card{color:red}</style>\n<script>window.ready=true</script><STYLE>.second{}</STYLE>"
        XCTAssertEqual(HTMLIslandPolicy.extractSections(from: tail + "\n后面的正文"),
                       [.island(tail), .markdown("\n后面的正文")])
        let second = "<style>.second{color:blue}</style>" + root
        XCTAssertEqual(HTMLIslandPolicy.extractSections(from: root + second), [.island(root), .island(second)])
        XCTAssertEqual(HTMLIslandPolicy.extractSections(from: root + "\n正文<style>.other{}</style>"),
                       [.island(root), .markdown("\n正文<style>.other{}</style>")])
    }

    func testReceiptRendersMarkdownButKeepsHTMLAndProtocolMarkersInert() async throws {
        let png = "https://fixture.invalid/image(2).png"
        let example = "`![示例](https://fixture.invalid/not-an-image.png)`"
        let prefix = "🌿 生成完毕：", suffix = "\n" + example + "\n\n<script>sample()</script>\n<<<[ROLE_DIVIDE_USER]>>>"
        let content = prefix + "![成品](" + png + ")" + suffix
        let receipt = "[[VCP调用结果信息汇总:\n工具名称: 生图\n返回内容: " + content + "\nVCP调用结果结束]]"
        let rendered = try await MessageRenderer.shared.render(batch(receipt, id: receiptID), options: .init(), dark: false)
        guard case .vcp(.batch(let parts, true)) = rendered.first, case .result(let result, true) = parts.first else {
            return XCTFail("batch lost its tool receipt")
        }
        let blocks = try await MessageRenderer.shared.receiptBlocks(result.content, options: .init(), dark: false)
        guard case .paragraph(let runs) = blocks.first else { return XCTFail("Missing receipt paragraph") }
        XCTAssertTrue(runs.contains(.media(try XCTUnwrap(MessageMedia(source: png, caption: "成品")))))
        XCTAssertTrue(runs.contains { if case .text(let v) = $0 { return v.inlinePresentationIntent == .code && String(v.characters).contains("not-an-image") }; return false })
        XCTAssertTrue(blocks.contains { if case .literal(let raw) = $0 { return raw.contains("<script>sample()</script>") }; return false })
        XCTAssertFalse(blocks.contains { if case .vcp = $0 { return true }; if case .html = $0 { return true }; return false })
        var options = RenderOptions(); options.enabled = false
        let disabled = try await MessageRenderer.shared.receiptBlocks(result.content, options: options, dark: false)
        XCTAssertEqual(disabled, [.literal(content)])
    }

    @MainActor func testIslandDelegatesRedirectAndSVGToWebKitWithoutCachingOrRetrying() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let origin = ImageOriginFixture()
        let redirect = try XCTUnwrap(URL(string: "https://fixture.invalid/cdn"))
        let svg = try XCTUnwrap(URL(string: "https://fixture.invalid/vector"))
        await origin.set(redirect, Data(), status: 302)
        await origin.set(svg, Data("<svg/>".utf8), type: "image/svg+xml; charset=utf-8")
        let handler = IslandImageScheme(store: RemoteImageStore(directory: dir) { try await origin.get($0) })
        handler.mediaEnabled = true
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        config.setURLSchemeHandler(handler, forURLScheme: IslandImageScheme.name)
        config.userContentController.addUserScript(WKUserScript(source: try XCTUnwrap(IslandScripts.runtime),
            injectionTime: .atDocumentEnd, forMainFrameOnly: true, in: .defaultClient))
        let web = WKWebView(frame: .zero, configuration: config)
        let window = try host(SchemeImageFixture(view: web))
        defer { web.stopLoading(); handler.invalidate(); window.isHidden = true }
        web.loadHTMLString(HTMLIslandPolicy.document("", motion: false, media: true, dark: false), baseURL: nil)
        try await eventually("fixture page is ready") { !web.isLoading && web.url != nil }
        let card = "<div id='vcp-root'><img id='a' src='\(redirect)'><img id='b' src='\(svg)'></div>"
        func update(_ html: String) async throws {
            try await web.runIslandScript("window.VCPBubbleStream.update(html,false,window.VCPBubbleEpoch)",
                arguments: ["html": html])
        }
        try await update(card)
        let restored = """
        return document.querySelector('#a')?.getAttribute('src') === '\(redirect)' &&
               document.querySelector('#b')?.getAttribute('src') === '\(svg)';
        """
        guard try await observeIsland(web, "original HTTPS URLs returned to WebKit", condition: restored) else { return }
        try await update(card + "<p>next</p>")
        _ = try await observeIsland(web, "next frame keeps the direct URLs", condition: restored)
        for url in [redirect, svg] {
            let n = await origin.count(url)
            XCTAssertEqual(n, 1)
        }
    }

    func testToolBatchHidesOnlyItsTransportAndKeepsSummaryAndImage() async throws {
        let tool = "<<<[TOOL_REQUEST]>>>\ntool_name:「始」NovelAIGen「末」\n<<<[END_TOOL_REQUEST]>>>"
        let summary = "[本轮工具调用摘要:]\nNovelAIGen 调用成功。\n[本轮工具调用摘要结束]"
        let picture = "![生成图](https://fixtures.invalid/generated/portrait.png)"
        let source = tool+"\n"+batch(summary,id:receiptID)+"\n"+picture
        let blocks = try await MessageRenderer().render(source, options:.init(), dark:false)
        XCTAssertEqual(blocks.count,3)
        guard blocks.count==3,
              case .vcp(.tool("NovelAIGen", _, _, true)) = blocks[0],
              case .vcp(.batch(let receipts, true)) = blocks[1], receipts.count == 1,
              case .summary(let lines,true) = receipts[0],
              case .paragraph(let runs) = blocks[2] else { return XCTFail("Expected the tool, one receipt and the assistant's image") }
        XCTAssertEqual(lines,["NovelAIGen 调用成功。"])
        XCTAssertTrue(runs.contains { if case .media(let image)=$0 { return image.caption=="生成图" };return false })
        XCTAssertFalse(SpeechText.plain(source).contains("VCP_TOOL_BATCH"))
    }

    func testBatchCloseMatchesIDAndToolPayloadStaysInert() {
        let foreign = "<<<[VCP_TOOL_BATCH_END:wrong]>>>"
        let literal = "<script>sample()</script>\n<<<[TOOL_REQUEST]>>>"
        let result = "[[VCP调用结果信息汇总:\n工具名称: Example\n执行状态: 成功\n返回内容: ok\nVCP调用结果结束]]"
        let full = batch(literal+"\n"+foreign+"\n"+result,id:receiptID,shell:false)+"\n正文"
        let items=VCPMarkup.parse(full)
        guard items.count==2,case .batch(let parts,true)=items[0],case .text(let after)=items[1] else { return XCTFail("Boundary mismatch") }
        XCTAssertEqual(after.trimmingCharacters(in:.whitespacesAndNewlines),"正文")
        XCTAssertTrue(parts.contains { if case .note(let note)=$0 { return note.contains(literal) && note.contains(foreign) };return false })
        XCTAssertTrue(parts.contains { if case .result(let r,true)=$0 { return r.tool=="Example" && r.content=="ok" };return false })
        let partial = "<<<[ROLE_DIVIDE_USER]>>>\n<<<[VCP_TOOL_BATCH_START:\(receiptID)]>>>\n等待\n<<<[VCP_TOOL_BATCH_EN"
        XCTAssertEqual(VCPMarkup.parse(partial,streaming:true),[.batch([.note("等待")],false)])
        XCTAssertEqual(VCPMarkup.parse(batch("",id:receiptID)),[])
        let other = "<<<[ROLE_DIVIDE_USER]>>>你好<<<[END_ROLE_DIVIDE_USER]>>>"
        XCTAssertEqual(VCPMarkup.parse(other),[.divider("user",false),.text("你好"),.divider("user",true)])
    }

    func testResultBodyKeepsStatusLikeLinesInsidePluginOutput() {
        let source = "- 工具名称: 天气\n- 执行状态: 成功\n- 返回内容: 详细记录\n- 执行状态: 内部记录失败\n- Result: 原始值"
        let result = VCPMarkup.resultFields(source)
        XCTAssertEqual(result.tool, "天气"); XCTAssertEqual(result.status, "成功")
        XCTAssertEqual(result.content, "详细记录\n- 执行状态: 内部记录失败\n- Result: 原始值")
        let unlabelled = VCPMarkup.resultFields("- 工具名称: 天气\n- 执行状态: 成功\n无字段名的返回正文")
        XCTAssertEqual(unlabelled.content, "无字段名的返回正文")
    }

    func testQuotedHTMLTagLeavesFollowingToolPayloadAndReceiptIntact() async throws {
        let tool = "<<<[TOOL_REQUEST]>>>", end = "<<<[END_TOOL_REQUEST]>>>"
        let payload = "tool_name:「始」示例工具「末」,command:「始」记录字符串 <script>「末」"
        let summary = "[本轮工具调用摘要:]\n已记录\n[本轮工具调用摘要结束]"
        let source = "用 `<script>` 表示标签。\n\n" + tool + payload + end + "\n" + batch(summary,id:receiptID)
        let blocks = try await MessageRenderer().render(source,options:.init(),dark:true)
        guard blocks.count == 3, case .paragraph = blocks[0],
              case .vcp(.tool("示例工具", "记录字符串 <script>", let body, true)) = blocks[1],
              case .vcp(.batch(let parts,true)) = blocks[2], parts == [.summary(["已记录"],true)] else {
            return XCTFail("Expected prose, one folded tool request, and its receipt")
        }
        XCTAssertEqual(body,payload)
        let partial = "引用 `<script>`。\n" + tool + payload
        guard case .tool(_,_,let partialBody,false) = VCPMarkup.parse(partial,protectingHTMLLiterals:true,streaming:true).last else {
            return XCTFail("The open request should be recognized while streaming")
        }
        XCTAssertEqual(partialBody,payload)
    }

    func testOnlyUnquotedToolEnvelopeBecomesACard() {
        let tool = "<<<[TOOL_REQUEST]>>>tool_name:「始」示例「末」<<<[END_TOOL_REQUEST]>>>"
        for sample in ["``含 ` 与 <script> " + tool + "``", "```html\n<script>\n"+tool+"\n```",
                       "<pre>"+tool+"</pre>", "<script>"+tool+"</script>", "<!-- "+tool+" -->"] {
            let source = sample + "\n" + tool
            XCTAssertEqual(VCPMarkup.parse(source,protectingHTMLLiterals:true),
                           [.text(sample+"\n"), .tool("示例","","tool_name:「始」示例「末」",true)])
        }
    }

    func testDocumentedBatchInMarkdownIsLiteral() async throws {
        let sample=batch("演示",id:receiptID,shell:false)
        let fence=String(repeating:"`",count:3)
        let source=fence+"text\n"+sample+"\n"+fence+"\n\n"+batch("真的回执",id:receiptID,shell:false)
        let blocks=try await MessageRenderer().render(source, options:.init(), dark:false)
        guard blocks.count==2,case .code(_,let code,_)=blocks[0],
              case .vcp(.batch(let parts,true))=blocks[1],parts == [.note("真的回执")] else { return XCTFail("Expected a code example and a separate receipt") }
        XCTAssertTrue(code.contains(sample))
        let inline = "`example <<<[VCP_TOOL_BATCH_START:sample]>>> text`"
        XCTAssertEqual(VCPMarkup.parse(inline),[.text(inline)])
    }

    @MainActor func testStandaloneRoleMarkerCannotGrowIntoAnEmptyPanel() {
        let content=VCPCardView(segment:.divider("user",false),options:.init())
        let controller=UIHostingController(rootView:content)
        let size=controller.sizeThatFits(in:CGSize(width:340,height:600))
        XCTAssertGreaterThan(size.height,5)
        XCTAssertLessThan(size.height,45)
    }

    @MainActor func testRemotePhotoFitsBubbleButStickerKeepsAuthoredWidth() throws {
        let picture=try XCTUnwrap(MessageMedia.html(#"<img src="https://fixtures.invalid/pw=fixture/images/generated/portrait.png" width="110">"#))
        let sticker=try XCTUnwrap(MessageMedia.html(#"<img src="https://fixtures.invalid/pw=fixture/images/测试表情包/笑.png" width="110">"#))
        func measure(_ media: MessageMedia,_ pixels:CGSize,_ width:CGFloat) -> CGSize {
            let layout=MessageImageLayout(pixels:pixels,widthLimit:media.inlineWidthLimit) { Color.red }
            return UIHostingController(rootView:layout).sizeThatFits(in:CGSize(width:width,height:2000))
        }
        for width in [CGFloat(248),338] {
            let size=measure(picture,CGSize(width:512,height:768),width)
            XCTAssertEqual(size.width,width,accuracy:1)
            XCTAssertEqual(size.height,width*1.5,accuracy:1)
        }
        let landscape=measure(picture,CGSize(width:1000,height:500),320)
        XCTAssertEqual(landscape.height,160,accuracy:1)
        XCTAssertEqual(measure(sticker,CGSize(width:512,height:512),320).width,110,accuracy:1)
        let tall=measure(picture,CGSize(width:500,height:5000),338)
        XCTAssertLessThanOrEqual(tall.height,721)
        XCTAssertEqual(tall.width/tall.height,0.1,accuracy:0.002)
    }

    func testBellFixedSlotsAndManualOrderSurviveReload() throws {
        func topic(_ id: String, _ created: Double) -> ChatTopic {
            var t = ChatTopic(id: id, ownerId: "a")
            t.createdAt = created
            return t
        }
        let a = topic("a", 1), b = topic("b", 2), c = topic("c", 3), d = topic("d", 4)
        let rows = [a, b, c, d], times = ["a": 10.0, "b": 9.0]
        let scope = "agent:a"
        var order = TopicOrdering()
        func ids() -> [String] { order.sorted(rows, in: scope, lastMessages: times).map(\.id) }
        XCTAssertEqual(ids(), ["a", "b", "d", "c"])
        order.togglePin("b", at: 1, in: scope)
        order.ring(in: scope)
        XCTAssertEqual(ids(), ["d", "b", "c", "a"])
        XCTAssertEqual(order.sorted(rows, in: "group:a", lastMessages: times).map(\.id), ["d", "c", "b", "a"])
        // Drag a free row across the pin. The pin stays in slot 1.
        order.saveMove([a, d, b, c], replacing: [d, b, c, a], in: scope)
        order = try JSONDecoder().decode(TopicOrdering.self, from: JSONEncoder().encode(order))
        XCTAssertTrue(order.isManual(scope))
        XCTAssertFalse(order.isManual("group:a"))
        XCTAssertEqual(ids(), ["a", "b", "d", "c"])
        XCTAssertEqual(order.sorted([c, b], in: scope, lastMessages: [:]).map(\.id), ["c", "b"])
        order.ring(in: scope)
        XCTAssertFalse(order.isManual(scope))
        XCTAssertEqual(ids(), ["d", "b", "c", "a"])
        order.togglePin("b", at: 1, in: scope)
        XCTAssertEqual(ids(), ["d", "c", "b", "a"])
    }

    @MainActor func testSyncAndReopenUseCreationAndLastUtteranceNotMetadata() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = try await ChatStore.open(path: folder.appendingPathComponent("chat.sqlite").path)
        let previous = SyncProfile(id: "test", endpoint: "fixture")
        var profile = previous
        let owner = SyncIdentity(entityType: "owner", ownerType: "agent", ownerId: "alice")
        profile.entities[owner.key] = SyncEntity(identity: owner, data: .object(["name": .string("Alice")]), updatedAt: 0)
        func add(_ name: String, created: JSONValue, revision: Double, messages: [(String, Double)]) {
            let id = SyncIdentity(entityType: "topic", ownerType: "agent", ownerId: "alice", topicId: name)
            profile.entities[id.key] = SyncEntity(identity: id, data: .object(["name": .string(name), "createdAt": created]), updatedAt: revision)
            profile.messages[id.topicKey] = messages.enumerated().map { i, item in
                .object(["id": .string(String(i)), "role": .string(item.0), "content": .string("test"), "timestamp": .number(item.1)])
            }
        }
        add("old", created: .number(10_000), revision: 999_000, messages: [("assistant", 30_000), ("system", 990_000)])
        add("active", created: .number(20_000), revision: 21_000, messages: [("user", 65_000), ("assistant", 70_000)])
        add("empty", created: .string("60000"), revision: 888_000, messages: [])
        add("branch", created: .number(50_000), revision: 50_000, messages: [("user", 1_000)])
        add("legacy", created: .null, revision: 777_000, messages: [])
        let snapshot = profile.toLocal()
        try await store.commitSync(profile: profile, previous: previous, before: SyncSnapshot(), after: snapshot)
        let model = ChatViewModel()
        model.store = store
        await model.reloadSyncSource(profile)
        func titles() -> [String] { model.recentTopics(model.topics).map(\.title) }
        let expected = ["active", "empty", "branch", "old", "legacy"]
        XCTAssertEqual(titles(), expected)
        let old = try XCTUnwrap(model.topics.first { $0.title == "old" })
        XCTAssertEqual(model.lastMessageTimes[old.id], 30)
        await model.renameTopic(old, title: "renamed")
        try await model.reloadTopicList(from: store)
        XCTAssertEqual(titles(), ["active", "empty", "branch", "renamed", "legacy"])
        let fresh = StoredMessage(topicID: old.id, role: "assistant", content: "new", createdAt: 80)
        try await store.save(fresh)
        await model.reloadTopicTools(changedID: old.id)
        XCTAssertEqual(titles().first, "renamed")
        await model.openTopic(old)
        let live = try XCTUnwrap(model.room?.messages.first { $0.id == fresh.id })
        await model.trashMessage(live)
        XCTAssertEqual(titles().first, "active")
        XCTAssertEqual(model.lastMessageTimes[old.id], 30)
    }

    @MainActor func testComposerManualDismissalAndSendDismissal() async throws {
        let state = KeyboardFixtureState()
        state.draft = ""
        let window = try host(KeyboardFixture(state: state))
        defer { window.isHidden = true }
        try await eventually("editor is mounted") { self.find(UITextView.self, in: window) != nil }
        let editor = try XCTUnwrap(find(UITextView.self, in: window))
        XCTAssertTrue(editor.becomeFirstResponder())
        editor.insertText("草稿")
        try await eventually("typed draft reached the model") { state.draft == "草稿" }
        let bar = try XCTUnwrap(editor.inputAccessoryView as? UIToolbar)
        let hide = try XCTUnwrap(bar.items?.first { $0.title == "收起键盘" })
        XCTAssertTrue(UIApplication.shared.sendAction(try XCTUnwrap(hide.action), to: hide.target, from: hide, for: nil))
        XCTAssertFalse(editor.isFirstResponder, "manual dismissal keeps the draft without sending it")
        XCTAssertEqual(editor.text, "草稿")
        XCTAssertEqual(state.draft, "草稿")
        XCTAssertTrue(state.sent.isEmpty)

        XCTAssertTrue(editor.becomeFirstResponder())
        state.acceptsSend = false
        editor.insertText("\n")
        XCTAssertTrue(editor.isFirstResponder, "rejected send should keep focus")
        XCTAssertEqual(editor.text, "草稿")
        XCTAssertTrue(state.sent.isEmpty)

        state.acceptsSend = true
        editor.selectedRange = NSRange(location: (editor.text as NSString).length, length: 0)
        editor.insertText("！")
        editor.insertText("\n")
        XCTAssertEqual(state.sent, ["草稿！"], "Return must submit the latest text exactly once")
        XCTAssertFalse(editor.isFirstResponder, "accepted send should release keyboard focus")
        try await eventually("accepted draft cleared from the visible editor") { editor.text.isEmpty }
    }

    @MainActor func testReturnCanStillInsertANewline() async throws {
        let state = KeyboardFixtureState()
        let window = try host(KeyboardFixture(state: state, enterSends: false))
        defer { window.isHidden = true }
        try await eventually("newline-mode editor is mounted") { self.find(UITextView.self, in: window) != nil }
        let editor = try XCTUnwrap(find(UITextView.self, in: window))
        XCTAssertTrue(editor.becomeFirstResponder())
        editor.selectedRange = NSRange(location: (editor.text as NSString).length, length: 0)
        editor.insertText("\n")
        XCTAssertEqual(editor.text, "草稿\n")
        XCTAssertTrue(editor.isFirstResponder)
        XCTAssertTrue(state.sent.isEmpty)
    }

    @MainActor func testComposerKeepsFocusUntilMessageAndOutboxCommit() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let path = folder.appendingPathComponent("chat.sqlite").path
        let store = try await ChatStore.open(path: path)
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(path, &db), SQLITE_OK)
        defer { sqlite3_close(db) }
        XCTAssertEqual(sqlite3_exec(db, "CREATE TRIGGER reject_outbox BEFORE INSERT ON outbox BEGIN SELECT RAISE(ABORT,'outbox unavailable'); END", nil, nil, nil), SQLITE_OK)

        let model = ChatViewModel()
        let agent = VCPAgent(), topic = ChatTopic(ownerId: agent.id, title: "本机入队")
        let room = ChatRoom(id: topic.id, messages: [])
        model.store = store; model.agents = [agent]; model.topics = [topic]
        model.activeTopicID = topic.id; model.rooms = [topic.id: room]; model.apiKey = "fixture"
        let keyboard = ComposerKeyboard()
        let composer = NativeComposer(text: Binding(get: { model.draft }, set: { model.draft = $0 }),
                                     enterSends: true, insertNewline: 0, keyboard: keyboard) {
            model.send {
                keyboard.didClearDraft()
                room.cancellation = .stopped  // Stop before network generation, after the real commit.
            }
        }
        let window = try host(composer)
        defer { window.isHidden = true }
        try await eventually("composer mounted") { self.find(UITextView.self, in: window) != nil }
        let editor = try XCTUnwrap(find(UITextView.self, in: window))
        XCTAssertTrue(editor.becomeFirstResponder())
        editor.insertText("重试"); editor.insertText("\n")
        await room.generation?.value
        let rolledBack = try await store.messages(topicID: topic.id)
        XCTAssertTrue(room.error?.contains("outbox unavailable") == true)
        XCTAssertTrue(rolledBack.isEmpty)
        XCTAssertEqual(room.draft, "重试")
        XCTAssertTrue(editor.isFirstResponder)

        XCTAssertEqual(sqlite3_exec(db, "DROP TRIGGER reject_outbox", nil, nil, nil), SQLITE_OK)
        editor.insertText("\n")
        await room.generation?.value
        let stored = try await store.messages(topicID: topic.id)
        let pending = try await store.pending()
        XCTAssertEqual(stored.map(\.content), ["重试"])
        XCTAssertEqual(pending, 1)
        XCTAssertEqual(room.draft, "")
        XCTAssertEqual(editor.text, "")
        XCTAssertFalse(editor.isFirstResponder)
    }

    func testAtlasKeepsConfiguredPrefixAndEncodedQuery() throws {
        for base in ["https://example.invalid/vcp", "https://example.invalid/vcp/v1", "https://example.invalid/vcp/v1/chat/completions"] {
            let config = ConnectionConfiguration(server: base)
            let url = try FieldAtlasClient.endpoint("/messages?q=%E6%98%A5%26%23", configuration: config)
            XCTAssertEqual(url.absoluteString, "https://example.invalid/vcp/api/plugins/WarpedFieldAtlas/messages?q=%E6%98%A5%26%23")
            XCTAssertThrowsError(try FieldAtlasClient.endpoint("/unlisted", configuration: config))
        }
    }

    func testAtlasResponseLimitCanBeRaisedOrRemoved() async throws {
        let session = URLSessionConfiguration.ephemeral
        session.protocolClasses = [AtlasResponseFixture.self]
        for limit in [FieldAtlasResponseLimit.standard, .larger, .unlimited] {
            let client = FieldAtlasClient(configuration: .init(server: "https://atlas.invalid/vcp"), key: "fixture", responseLimit: limit, sessionConfiguration: session)
            defer { client.close() }
            do {
                let body = try await client.get("/status")
                XCTAssertNotEqual(limit, .standard)
                XCTAssertEqual(body, "{}")
            } catch {
                XCTAssertEqual(limit, .standard)
                XCTAssertTrue(error.localizedDescription.contains("32 MiB"))
            }
        }
    }

    @MainActor func testBubbleHostIsTransparentInBothThemes() async throws {
        let web = WKWebView()
        let sample = #"<div id="vcp-root" style="background:#faf5ef;color:#336699;border-radius:16px">卡片</div><p>正文</p>"#
        for dark in [false, true] {
            let page = HTMLIslandPolicy.document(sample, motion: false, media: false, dark: dark)
            web.loadHTMLString(page, baseURL: nil)
            try await eventually("bubble page loaded") { !web.isLoading }
            let result = try await web.evaluateJavaScript("""
                (() => { const css = el => getComputedStyle(el), card = css(document.querySelector('#vcp-root'));
                    return [css(document.documentElement).backgroundColor, css(document.body).backgroundColor,
                            css(document.querySelector('p')).color, card.backgroundColor, card.color, card.borderRadius]; })()
                """) as? [String]
            XCTAssertEqual(result, ["rgba(0, 0, 0, 0)", "rgba(0, 0, 0, 0)", dark ? "rgb(255, 255, 255)" : "rgb(0, 0, 0)",
                                    "rgb(250, 245, 239)", "rgb(51, 102, 153)", "16px"])
        }
    }

    @MainActor func testBundledAtlasCanCallNativeBridge() async throws {
        let window = try host(FieldAtlasView(configuration: .init(server: "https://example.invalid"), key: ""))
        defer { window.isHidden = true }
        try await eventually("atlas mounts a web view") { self.find(WKWebView.self, in: window) != nil }
        let web = try XCTUnwrap(find(WKWebView.self, in: window))

        // Reading JS during provisional navigation can target the empty document. Use
        // native state while WebKit cold-starts; keep the bridge assertion separate.
        let clock = ContinuousClock()
        let loadDeadline = clock.now + .seconds(60)
        while web.isLoading || web.url?.isFileURL != true {
            guard clock.now < loadDeadline else {
                return XCTFail("Atlas navigation timed out: page=\(web.url?.lastPathComponent ?? "none"), progress=\(web.estimatedProgress), loading=\(web.isLoading)")
            }
            try await Task.sleep(for: .milliseconds(200))
        }
        XCTAssertEqual(web.url?.lastPathComponent, "index.html")

        // One WebKit call, in an isolated world, observes the visible DOM. The bundled
        // page must still call /status and render the real native client's reply.
        let observation = """
        const message = document.querySelector('.wa-message');
        if (!message) throw new Error('Atlas did not mount; document=' + document.readyState);
        const visibleText = () => message.isConnected && !message.hidden && message.textContent.trim();
        if (visibleText()) return visibleText();
        return await new Promise((resolve, reject) => {
            const observer = new MutationObserver(() => {
                const text = visibleText();
                if (text) { observer.disconnect(); clearTimeout(timer); resolve(text); }
            });
            const timer = setTimeout(() => {
                observer.disconnect();
                reject(new Error('Atlas mounted but rendered no status; hidden=' + message.hidden));
            }, 30000);
            observer.observe(message, { childList: true, subtree: true, characterData: true, attributes: true });
        });
        """
        var rendered: Result<Any, any Error>?
        web.callAsyncJavaScript(observation, arguments: [:], in: nil, in: .defaultClient) { rendered = $0 }
        let replyDeadline = clock.now + .seconds(45)
        while rendered == nil {
            guard clock.now < replyDeadline else {
                return XCTFail("WebContent did not complete the DOM observation after the local page loaded")
            }
            try await Task.sleep(for: .milliseconds(200))
        }
        switch try XCTUnwrap(rendered) {
        case .success(let value):
            let message = try XCTUnwrap(value as? String)
            XCTAssertTrue(message.contains("请先在服务器设置中填写聊天 API Key。"), "Unexpected visible status: \(message)")
        case .failure(let error):
            let detail = (error as NSError).userInfo["WKJavaScriptExceptionMessage"] as? String
            XCTFail("Atlas status observation failed: \(detail ?? error.localizedDescription)")
        }
    }

    @MainActor func testRemoteImageSurvivesReopenAndCoalescesRequests() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = try XCTUnwrap(URL(string: "https://fixtures.invalid/pw=fixture-a/images/test/card.png?revision=1"))
        let origin = ImageOriginFixture(), payload = pixelPNG(.purple)
        await origin.set(source, payload)
        let online = RemoteImageStore(directory: directory) { try await origin.get($0) }
        async let first = online.resource(source)
        async let second = online.resource(source)
        let pair = try await (first, second)
        XCTAssertEqual(pair.0.data, payload)
        XCTAssertEqual(pair.1.data, payload)
        let count = await origin.count(source)
        XCTAssertEqual(count, 1, "two views for one URL must share the download")

        let offline = ImageOriginFixture()
        let reopened = RemoteImageStore(directory: directory) { try await offline.get($0) }
        let restored = try await reopened.resource(source)
        XCTAssertEqual(restored.data, payload)
        let attempts = await offline.count(source)
        XCTAssertEqual(attempts, 0, "the second store has no memory cache and no available network")

        for changed in [
            "https://fixtures.invalid/pw=fixture-b/images/test/card.png?revision=1",
            "https://fixtures.invalid/pw=fixture-a/images/test/card.png?revision=2"
        ] {
            let url = try XCTUnwrap(URL(string: changed))
            do { _ = try await reopened.resource(url); XCTFail("a different resource must not get the first image") }
            catch { /* the fixture is offline */ }
            let requests = await offline.count(url)
            XCTAssertEqual(requests, 1)
        }
    }

    @MainActor func testInvalidResponsesAreRetriedAndNoStoreIsNotPersisted() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = try XCTUnwrap(URL(string: "https://fixtures.invalid/demo/card.png"))
        let bytes = pixelPNG(.orange), origin = ImageOriginFixture()
        let store = RemoteImageStore(directory: directory) { try await origin.get($0) }
        await origin.set(url, bytes, status: 403)
        do { _ = try await store.resource(url); XCTFail("denied content must not be cached as an image") }
        catch { }
        await origin.set(url, Data("<html>sign in</html>".utf8))
        do { _ = try await store.resource(url); XCTFail("HTTP 200 from a login page is not an image") }
        catch { }
        await origin.set(url, bytes, control: "private, no-store")
        let privateImage = try await store.resource(url)
        XCTAssertEqual(privateImage.data, bytes)
        let newProcess = RemoteImageStore(directory: directory) { try await origin.get($0) }
        _ = try await newProcess.resource(url)
        let count = await origin.count(url)
        XCTAssertEqual(count, 4, "no-store content needs the network after reopening")
    }

    @MainActor func testZeroMaxAgeOnlyPersistsVCPStickersWithoutRevalidationRestrictions() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let origin = ImageOriginFixture(), offline = ImageOriginFixture(), bytes = pixelPNG(.blue)
        let online = RemoteImageStore(directory: directory) { try await origin.get($0) }
        // All cases use valid identical images. Only URL shape and HTTP cache policy differ.
        for (path, control, shouldPersist) in [
            ("pw=fixture/images/测试表情包/固定.png", "public, max-age=0", true),
            ("pw=fixture/images/photos/plain.png", "public, max-age=0", false),
            ("images/测试表情包/无前缀.png", "public, max-age=0", false),
            ("pw=fixture/images/测试表情包/禁止保存.png", "public, max-age=0, NO-STORE", false),
            ("pw=fixture/images/测试表情包/必须验证.png", "public, No-Cache, max-age=0", false),
            ("pw=fixture/images/测试表情包/必须重验.png", "public, max-age=0, must-revalidate", false)
        ] {
            let url = try XCTUnwrap(URL(string: "https://fixtures.invalid/" + path))
            await origin.set(url, bytes, control: control)
            let live = try await online.resource(url)
            XCTAssertEqual(live.data, bytes)
            let cold = RemoteImageStore(directory: directory) { try await offline.get($0) }
            do {
                let fromDisk = try await cold.resource(url)
                XCTAssertTrue(shouldPersist, "unexpected persisted response for \(path), \(control)")
                XCTAssertEqual(fromDisk.data, bytes)
            } catch {
                XCTAssertFalse(shouldPersist, "valid VCP sticker was unavailable offline: \(error.localizedDescription)")
            }
            let networkAttempts = await offline.count(url)
            XCTAssertEqual(networkAttempts, shouldPersist ? 0 : 1, "wrong cold-load policy: \(path), \(control)")
        }
    }

    @MainActor func testStickerCatalogRepairsOnlyStickerNamesAndPackages() throws {
        let library = EmoticonCatalog(entries: ["猫表情包": ["开心.webp", "吃鱼.png"], "兔表情包": ["开心.gif"]])
        func source(_ package: String, _ filename: String) throws -> URL {
            let base = try XCTUnwrap(URL(string: "https://fixtures.invalid:8443/pw=fixture/images/"))
            return base.appendingPathComponent(package)
                .appendingPathComponent(filename)
                .appending(queryItems: [URLQueryItem(name: "revision", value: "abc")])
        }
        let missingExtension = try source("猫表情包", "开心.jpg")
        let expected = try source("猫表情包", "开心.webp")
        XCTAssertEqual(library.repair(missingExtension), expected, "same stem: choose the existing item in the named package")
        let inventedPackage = try source("虚构表情包", "吃鱼.gif")
        XCTAssertEqual(library.repair(inventedPackage), try source("猫表情包", "吃鱼.png"), "a unique stem can recover another package")
        let typo = try source("猫表情包", "吃小鱼.gif")
        XCTAssertEqual(library.repair(typo), try source("猫表情包", "吃鱼.png"), "unknown stem first searches the same package")
        let ordinary = try source("photos", "开心.jpg")
        XCTAssertEqual(library.repair(ordinary), ordinary)
        XCTAssertEqual(EmoticonCatalog(entries: [:]).repair(missingExtension), missingExtension)
    }

    @MainActor func testStickerResolutionStaysOnTheConfiguredOrigin() throws {
        let server = try XCTUnwrap(URL(string: "https://fixtures.invalid/v1/chat/completions"))
        let catalog = EmoticonCatalog(entries: ["猫表情包": ["笑.png"]])
        let context = StickerContext(server: server, fileKey: "fixture-ticket", catalog: catalog)
        let resolved = try XCTUnwrap(context.resolve("images/猫表情包/笑.gif"))
        XCTAssertEqual(resolved.host, server.host)
        XCTAssertEqual(resolved.path, "/pw=fixture-ticket/images/猫表情包/笑.png")

        let old = "https://fixtures.invalid:6005/pw=older/images/猫表情包/笑.gif?revision=5"
        let fixed = try XCTUnwrap(context.resolve(old))
        XCTAssertEqual(fixed.scheme, "https")
        XCTAssertNil(fixed.port)
        XCTAssertEqual(fixed.path, "/pw=older/images/猫表情包/笑.png")
        XCTAssertEqual(fixed.query, "revision=5")

        let foreign = try XCTUnwrap(URL(string: "https://elsewhere.invalid:6005/pw=other/images/猫表情包/笑.gif"))
        XCTAssertEqual(context.resolve(foreign.absoluteString), foreign)
        XCTAssertNil(context.resolve("//elsewhere.invalid/images/猫表情包/笑.png"))
    }

    @MainActor func testStableCodePrefixAppendsThenYieldsToTheCanonicalParser() throws {
        let prefix = "正文\n\n", opener = "~~~swift\n"
        let first = try XCTUnwrap(StreamFenceTail.split(prefix + opener + "let x"))
        let next = try XCTUnwrap(StreamFenceTail.split(prefix + opener + "let x = 1\nlet y"))
        XCTAssertEqual(first.prefix, prefix)
        XCTAssertEqual(next.prefix, first.prefix)
        XCTAssertEqual(next.language, "swift")
        XCTAssertEqual(next.body, "let x = 1\nlet y")
        XCTAssertNil(StreamFenceTail.split(prefix + opener + next.body + "\n~~~"))
        XCTAssertNil(StreamFenceTail.split(prefix + "    ~~~swift\nexample"), "indented code is not a top-level streaming fence")
    }

    @MainActor func testLooseStickerTagRendersButCodeExamplesStayLiteral() async throws {
        let source = "https://fixtures.invalid/images/sample/card.png"
        let tag = "< img src=\"\(source)\" width=\"110\" style=\"border-radius:10px;display:block;flex-shrink:0;\" alt=\"笑\">"
        let renderer = MessageRenderer(), options = RenderOptions()
        let blocks = try await renderer.render(tag, options: options, dark: false)
        let images: [MessageMedia] = blocks.flatMap { block -> [MessageMedia] in
            guard case .paragraph(let runs) = block else { return [] }
            return runs.compactMap { run in if case .media(let media) = run { return media }; return nil }
        }
        XCTAssertEqual(images.map(\.source), [source])
        XCTAssertEqual(images.first?.caption, "笑")
        XCTAssertEqual(images.first?.preferredWidth, 110)
        XCTAssertEqual(images.first?.cornerRadius, 10)

        let fence = String(repeating: "`", count: 3)
        let open = fence + "html\n" + tag
        for (frame, expected, live) in [
            (open, tag, true),
            (open + "\n第二行", tag + "\n第二行", true),
            (open + "\n第二行\n" + fence, tag + "\n第二行", false)
        ] {
            let blocks = try await renderer.render(frame, options: options, dark: false, streaming: live)
            guard case .code(let language, let literal, _) = blocks.first else { return XCTFail("expected a literal code block") }
            XCTAssertEqual(language, "html")
            XCTAssertEqual(literal.trimmingCharacters(in: .newlines), expected)
        }
        let inline = try await renderer.render("示例：`" + tag + "`", options: options, dark: false)
        guard case .paragraph(let runs) = inline.first else { return XCTFail("expected inline code") }
        let text = runs.compactMap { run -> String? in if case .text(let t) = run { return String(t.characters) }; return nil }.joined()
        XCTAssertTrue(text.contains(tag))
        XCTAssertFalse(runs.contains { if case .media = $0 { true } else { false } })
    }

    // Keep native waiting bounded even if the simulator's WebContent process stops.
    // Once the native page starts loading, one isolated-world observer per phase
    // checks actual DOM changes without repeatedly bridging arbitrary script.
    @MainActor private func observeIsland(_ web: WKWebView, _ phase: String, condition: String,
                                          file: StaticString = #filePath, line: UInt = #line) async throws -> Bool {
        let script = """
        return await new Promise((resolve, reject) => {
            const matches = () => { \(condition) };
            const observer = new MutationObserver(check);
            const timer = setTimeout(() => { observer.disconnect(); reject(new Error('island condition not reached')); }, 30000);
            function check() {
                try {
                    if (!matches()) return;
                    observer.disconnect(); clearTimeout(timer); resolve(true);
                } catch (error) { observer.disconnect(); clearTimeout(timer); reject(error); }
            }
            observer.observe(document, { attributes: true, childList: true, subtree: true, characterData: true });
            check();
        });
        """
        var rendered: Result<Any, any Error>?
        web.callAsyncJavaScript(script, arguments: [:], in: nil, in: .defaultClient) { rendered = $0 }
        let clock = ContinuousClock(), deadline = clock.now + .seconds(45)
        while rendered == nil && clock.now < deadline { try await Task.sleep(for: .milliseconds(200)) }
        guard let rendered else { XCTFail("WebContent did not finish: " + phase, file: file, line: line); return false }
        switch rendered {
        case .success(let value):
            guard value as? Bool == true else { XCTFail("Unexpected WebKit response: " + phase, file: file, line: line); return false }
            return true
        case .failure(let error):
            XCTFail(phase + ": " + error.localizedDescription, file: file, line: line)
            return false
        }
    }

    @MainActor func testStreamedIslandKeepsItsImageAndInitializesOnceThroughFinal() async throws {
        let state = IslandFixtureState(image: pixelPNG(.green))
        let window = try host(IslandFixture(state: state))
        defer { window.isHidden = true }
        try await eventually("island mounts its web view") { self.find(WKWebView.self, in: window) != nil }
        let web = try XCTUnwrap(find(WKWebView.self, in: window))
        let clock = ContinuousClock(), deadline = clock.now + .seconds(60)
        while web.isLoading || web.url == nil {
            guard clock.now < deadline else { return XCTFail("Island document did not finish navigation") }
            try await Task.sleep(for: .milliseconds(200))
        }
        guard try await observeIsland(web, "closed streaming island has started", condition: """
        const photo = document.getElementById('fixture-photo');
        if (!photo || document.documentElement.dataset.fixtureStarts !== '1') return false;
        window.__fixturePhoto = photo;
        return true;
        """) else { return }

        state.source += "\n<script>document.documentElement.dataset.fixtureNext = 'yes';</script>"
        guard try await observeIsland(web, "later frame retains the original image", condition: """
        if (document.documentElement.dataset.fixtureNext !== 'yes') return false;
        if (document.getElementById('fixture-photo') !== window.__fixturePhoto) throw new Error('image replaced during append');
        if (document.documentElement.dataset.fixtureStarts !== '1') throw new Error('script ran twice during append');
        return true;
        """) else { return }

        state.streaming = false
        _ = try await observeIsland(web, "canonical terminal retains the same image and script", condition: """
        if (document.documentElement.dataset.fixtureTerminal !== 'yes') return false;
        if (document.getElementById('fixture-photo') !== window.__fixturePhoto) throw new Error('image replaced at terminal');
        if (document.documentElement.dataset.fixtureStarts !== '1') throw new Error('script reran at terminal');
        return true;
        """)
    }

    @MainActor func testDesktopCanvasWaitsForOuterSealAndSurvivesTerminal() async throws {
        let open = """
        ### 阶段一

        <div class="desktop-stage"><style>.indicator { color: teal }</style>
        <div><canvas width="8" height="8"></canvas><span class="indicator">waiting</span></div>
        <script>
        const card = container.querySelector('.desktop-stage');
        if (!card) return;
        const canvas = card.querySelector('canvas');
        document.documentElement.dataset.starts = String(Number(document.documentElement.dataset.starts || 0) + 1);
        document.addEventListener('DOMContentLoaded', () => { document.documentElement.dataset.terminal = 'yes'; }, {once:true});
        requestAnimationFrame(() => {
            const ctx = canvas.getContext('2d');
            ctx.fillStyle = '#00ff00'; ctx.fillRect(0, 0, 8, 8);
            card.querySelector('.indicator').textContent = 'drawn';
        });
        </script>
        """
        let state = IslandFixtureState(source: open)
        let window = try host(IslandFixture(state: state))
        defer { window.isHidden = true }
        try await eventually("desktop canvas island mounts a web view") { self.find(WKWebView.self, in: window) != nil }
        let web = try XCTUnwrap(find(WKWebView.self, in: window))
        let clock = ContinuousClock(), deadline = clock.now + .seconds(60)
        while web.isLoading || web.url == nil {
            guard clock.now < deadline else { return XCTFail("Desktop island navigation never finished") }
            try await Task.sleep(for: .milliseconds(200))
        }
        guard try await observeIsland(web, "open outer DIV does not activate a closed inline script", condition: """
        const card = document.querySelector('.desktop-stage');
        if (!card?.querySelector('script') || !card.querySelector('canvas')) return false;
        if (document.documentElement.dataset.starts) throw new Error('script started before closing outer DIV');
        return card.querySelector('.indicator').textContent === 'waiting';
        """) else { return }

        state.source += "</div>"
        guard try await observeIsland(web, "complete idle island can find its own outer container and paint", condition: """
        const card = document.querySelector('.desktop-stage'), canvas = card?.querySelector('canvas');
        if (!canvas || card.querySelector('.indicator').textContent !== 'drawn') return false;
        if (document.documentElement.dataset.starts !== '1') throw new Error('early script should run once');
        if (canvas.getContext('2d').getImageData(0, 0, 1, 1).data[1] !== 255) throw new Error('canvas never painted');
        window.__fixtureCard = card; window.__fixtureCanvas = canvas;
        return true;
        """) else { return }
        state.source += "\n\n~~~swift\nlet x = 1\n~~~"
        state.streaming = false
        _ = try await observeIsland(web, "canonical final still owns the original painted canvas", condition: """
        if (document.documentElement.dataset.terminal !== 'yes') return false;
        const card = document.querySelector('.desktop-stage'), canvas = card?.querySelector('canvas');
        if (card !== window.__fixtureCard || canvas !== window.__fixtureCanvas || document.documentElement.dataset.starts !== '1')
            throw new Error('canonical pass replaced or reinitialised the mounted island');
        return canvas.getContext('2d').getImageData(0, 0, 1, 1).data[1] === 255;
        """)
    }

    @MainActor private func renderFixtureImage(_ url: URL, using store: RemoteImageStore) async throws {
        let handler = IslandImageScheme(store: store)
        handler.mediaEnabled = true
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.userContentController.removeAllUserScripts()
        configuration.setURLSchemeHandler(handler, forURLScheme: IslandImageScheme.name)
        let web = WKWebView(frame: .zero, configuration: configuration)
        let window = try host(SchemeImageFixture(view: web))
        defer { web.stopLoading(); handler.invalidate(); window.isHidden = true }

        let unreserved = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        let encoded = try XCTUnwrap(url.absoluteString.addingPercentEncoding(withAllowedCharacters: unreserved))
        let image = "<img id=\"fixture\" src=\"\(IslandImageScheme.name)://asset?\(encoded)\" onload=\"this.dataset.loaded='yes'\" onerror=\"this.dataset.failed='yes'\">"
        let html = HTMLIslandPolicy.document(image, motion: false, media: true, dark: false)
        web.loadHTMLString(html, baseURL: nil)
        let clock = ContinuousClock(), deadline = clock.now + .seconds(60)
        while web.isLoading || web.url == nil {
            guard clock.now < deadline else { return XCTFail("Image scheme fixture navigation never finished") }
            try await Task.sleep(for: .milliseconds(200))
        }
        _ = try await observeIsland(web, "WKWebView decodes the image supplied by the persistent store", condition: """
        const img = document.getElementById('fixture');
        if (img?.dataset.failed === 'yes') throw new Error('WebKit image load failed');
        return img?.dataset.loaded === 'yes' && img.complete && img.naturalWidth > 0;
        """)
    }

    @MainActor func testHTMLImagesUseTheSamePersistentStoreAsNativeRows() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = try XCTUnwrap(URL(string: "https://fixtures.invalid/img/card.png?size=2"))
        let origin = ImageOriginFixture(), payload = pixelPNG(.green)
        await origin.set(url, payload)
        let online = RemoteImageStore(directory: directory) { try await origin.get($0) }
        try await renderFixtureImage(url, using: online)
        let initialDownloads = await origin.count(url)
        XCTAssertEqual(initialDownloads, 1)

        let offline = ImageOriginFixture()
        let coldStore = RemoteImageStore(directory: directory) { try await offline.get($0) }
        try await renderFixtureImage(url, using: coldStore)
        let nativeBytes = try await coldStore.resource(url)
        XCTAssertEqual(nativeBytes.data, payload)
        let extraDownloads = await offline.count(url)
        XCTAssertEqual(extraDownloads, 0, "new ephemeral WebKit and native store must reload from disk while offline")
    }
}

@MainActor private final class KeyboardFixtureState: ObservableObject {
    @Published var draft = "草稿"
    let keyboard = ComposerKeyboard()
    var acceptsSend = true
    var sent: [String] = []

    func send() {
        guard acceptsSend, !draft.isEmpty else { return }
        sent.append(draft)
        draft = ""
        keyboard.didClearDraft()
    }
}

private struct KeyboardFixture: View {
    @ObservedObject var state: KeyboardFixtureState
    var enterSends = true
    var body: some View {
        NativeComposer(text: $state.draft, enterSends: enterSends, insertNewline: 0, keyboard: state.keyboard, onSend: state.send)
    }
}

// Use only synthetic image bytes and URLs. No server or Keychain configuration is needed.
@MainActor private func pixelPNG(_ color: UIColor) -> Data {
    UIGraphicsImageRenderer(size: CGSize(width: 2, height: 2)).pngData { context in
        color.setFill()
        context.fill(CGRect(x: 0, y: 0, width: 2, height: 2))
    }
}

private actor ImageOriginFixture {
    private var requests: [URL:Int] = [:]
    private var replies: [URL:RemoteImageReply] = [:]
    func set(_ url: URL, _ data: Data, status: Int = 200, control: String = "", type: String = "") {
        replies[url] = RemoteImageReply(data: data, status: status, cacheControl: control, contentType: type)
    }
    func count(_ url: URL) -> Int { requests[url, default: 0] }
    func get(_ url: URL) async throws -> RemoteImageReply {
        requests[url, default: 0] += 1
        guard let reply = replies[url] else { throw URLError(.notConnectedToInternet) }
        // Ensure two simultaneous views can overlap before their first response arrives.
        try await Task.sleep(for: .milliseconds(100))
        return reply
    }
}


@MainActor private final class IslandFixtureState: ObservableObject {
    @Published var source: String
    @Published var streaming = true
    init(source: String) { self.source = source }
    init(image: Data) {
        source = """
        <div id="vcp-root"><img id="fixture-photo" alt="sticker" src="data:image/png;base64,\(image.base64EncodedString())"></div>
        <script>
        document.documentElement.dataset.fixtureStarts = String(1 + Number(document.documentElement.dataset.fixtureStarts || 0));
        document.addEventListener('DOMContentLoaded', () => { document.documentElement.dataset.fixtureTerminal = 'yes'; }, { once: true });
        </script>
        """
    }
}

private struct IslandFixture: View {
    @ObservedObject var state: IslandFixtureState
    var body: some View {
        RichMessageBody(state.source, streaming: state.streaming)
            .environment(\.scenePhase, .active)
    }
}


private struct SchemeImageFixture: UIViewRepresentable {
    let view: WKWebView
    func makeUIView(context: Context) -> WKWebView { view }
    func updateUIView(_ uiView: WKWebView, context: Context) {}
}

// An advertised length exercises the preflight limit without allocating a large fixture.
private final class AtlasResponseFixture: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "atlas.invalid" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1",
                                       headerFields: ["Content-Length": String(33 * 1024 * 1024)])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data("{}".utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

private final class CompletedReplyFixture: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard request.httpMethod == "POST", request.url?.path == "/v1/chatvcp/completions",
              request.value(forHTTPHeaderField: "Authorization") == "Bearer fixture",
              request.value(forHTTPHeaderField: "Accept") == "text/event-stream" else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse)); return
        }
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: ["Content-Type":"application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(#"{"choices":[{"message":{"content":"回复"#.utf8))
        client?.urlProtocol(self, didLoad: Data(#"正文","reasoning_content":"思路"}}]}"#.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

extension PhoneInteractionTests {
    @MainActor func testBackgroundReplySurvivesLeaseExpiryAndCommitsExactlyOnce() async throws {
        let (root, db) = try await makeReplyDatabase()
        defer { try? FileManager.default.removeItem(at: root) }
        let topic = try await addReplyTopic(db)
        let user = StoredMessage(topicID: topic.id, role: "user", content: "test", status: "pending")
        let answer = StoredMessage(topicID: topic.id, role: "assistant", content: "原文", reasoning: "已有", status: "connecting")
        try await db.enqueue(user); try await db.save(answer)
        let room = ChatRoom(id: topic.id, messages: [user, answer])
        let model = ChatViewModel()
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [CompletedReplyFixture.self]
        model.replyTransfers = BackgroundReplyTransfers(configuration: config)
        model.store = db; model.rooms[room.id] = room; room.busy = true; room.receivesInBackground = true
        try await model.restoreBackgroundReplies(store: db, root: root)

        let request = ChatRequest(configuration: .init(server: "https://fixture.invalid", model: "test", endpointMode: .vcpTools),
            apiKey: "fixture", messages: [.init(role: "user", content: "test")], contextTokenLimit: 100, maxOutputTokens: 12)
        let job = BackgroundReplyJob(messageID: answer.id, topicID: topic.id, userID: user.id)
        let ticket = try await model.replyTransfers.submit(job, request: request, room: room, store: db)
        let payload = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(request.urlRequest(streaming:true).httpBody)) as? [String: Any])
        XCTAssertEqual(payload["stream"] as? Bool, true); XCTAssertEqual(payload["contextTokenLimit"] as? Int, 100)
        XCTAssertEqual(payload["max_tokens"] as? Int, 12)
        await model.interruptForBackground()
        XCTAssertFalse(room.cancelled)
        await model.collectBackgroundReply(job, ticket: ticket, room: room, store: db)
        XCTAssertEqual(room.messages.last?.text, "原文回复正文"); XCTAssertEqual(room.messages.last?.reasoning, "已有思路")
        XCTAssertEqual(room.messages.first?.status, "complete")
        let duplicate = try await db.finishBackgroundReply(job, reply: nil)
        let pending = try await db.pending()
        XCTAssertNil(duplicate); XCTAssertEqual(pending, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: ticket.directory.path))
    }

    @MainActor func testSystemTransferStreamsBeforeCompletionAndCatchesUp() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let endpoint = env["VCHAT_STREAM_FIXTURE"], let url = URL(string:endpoint) else {
            throw XCTSkip("Run with IntegrationTests/slow-reply.py to exercise a real background URLSession")
        }
        let (root, db) = try await makeReplyDatabase()
        defer { try? FileManager.default.removeItem(at:root) }
        let answer = StoredMessage(topicID:"fixture", role:"assistant", content:"前缀",status:"connecting")
        try await db.save(answer)
        let model = ChatViewModel(), room = ChatRoom(id:"fixture",messages:[answer])
        model.replyTransfers = BackgroundReplyTransfers()
        model.store = db; model.rooms[room.id] = room; room.receivesInBackground = true; room.busy = true
        try await model.restoreBackgroundReplies(store:db, root:root)
        let job = BackgroundReplyJob(messageID:answer.id,topicID:room.id,userID:nil)
        let request = ChatRequest(configuration:.init(server:endpoint,model:"fixture"), apiKey:"fixture",messages:[.init(role:"user",content:"fixture")])
        let ticket = try await model.replyTransfers.submit(job,request:request,room:room,store:db)
        let collector = Task { await model.collectBackgroundReply(job,ticket:ticket,room:room,store:db) }
        defer { model.replyTransfers.cancel(job.id) }
        try await eventually("first small frame actually shown before the server may finish") { room.messages[0].text == "前缀首段" }
        guard room.messages[0].status == "streaming" else { XCTFail("No incremental foreground delivery"); return }
        var islandBytes: [Int] = []
        model.updateReplyActivity = { id, bytes in if id == job.id { islandBytes.append(bytes) } }
        await model.enterBackground()
        _ = try await URLSession.shared.data(from:url.appendingPathComponent("next"))
        try await eventually("the same SSE stream advances the reply and island before returning") {
            room.messages[0].text == "前缀首段补齐" && islandBytes.last == "首段补齐思考".utf8.count
        }
        XCTAssertTrue(model.backgrounded)
        XCTAssertEqual(room.messages[0].status,"streaming")
        await model.enterForeground()
        try await eventually("catch up without a third frame") { room.messages[0].text == "前缀首段补齐" }
        XCTAssertEqual(room.messages[0].reasoning,"思考")
        let (count,_) = try await URLSession.shared.data(from:url.appendingPathComponent("finish"))
        await collector.value
        XCTAssertEqual(String(decoding:count,as:UTF8.self),"1")
        let record = try await db.messages(topicID:room.id).first
        XCTAssertEqual(record?.content,"前缀首段补齐"); XCTAssertEqual(record?.status,"complete")
    }

    @MainActor func testServerReplyUsesDownloadedArchiveWhenLiveReaderIsUnavailable() async throws {
        guard let endpoint=ProcessInfo.processInfo.environment["VCHAT_REPLY_SYNC_FIXTURE"],let url=URL(string:endpoint) else {
            throw XCTSkip("Requires VChatReplySync and its loopback model fixture")
        }
        let (root,db)=try await makeReplyDatabase()
        defer { try? FileManager.default.removeItem(at:root) }
        let id=UUID().uuidString, name="archive-" + id
        let model=ChatViewModel(vault:CredentialVault(service:name))
        model.replyTransfers=BackgroundReplyTransfers(backgroundIdentifier:"vchat.tests." + id)
        let answer=StoredMessage(topicID:"archive",role:"assistant",content:"前缀",status:"connecting")
        let room=ChatRoom(id:answer.topicID,messages:[answer])
        model.store=db; model.rooms[room.id]=room
        room.receivesInBackground=true; room.serverOwnsReply=true; room.busy=true
        try await db.save(answer); try await model.restoreBackgroundReplies(store:db,root:root)
        let job=BackgroundReplyJob(messageID:answer.id,topicID:room.id,userID:nil)
        let chat=ChatRequest(configuration:.init(server:endpoint,model:name),apiKey:"fixture",messages:[.init(role:"user",content:"test")])
        let ticket=try await model.replyTransfers.submit(job,request:chat,room:room,store:db)
        let reader=Task { await model.collectBackgroundReply(job,ticket:ticket,room:room,store:db) }
        defer { reader.cancel() }
        try await eventually("server accepted the request") {
            guard let (data,_)=try? await URLSession.shared.data(from:url.appendingPathComponent("count").appendingPathComponent(name)) else { return false }
            return String(decoding:data,as:UTF8.self)=="1"
        }
        _ = try await URLSession.shared.data(from:url.appendingPathComponent("release").appendingPathComponent(name))
        let deadline=ContinuousClock.now + .seconds(60)
        while ["connecting","streaming"].contains(room.messages[0].status) && ContinuousClock.now < deadline { try await Task.sleep(for:.milliseconds(150)) }
        let saved=try await db.messages(topicID:room.id).first
        XCTAssertEqual(saved?.status,"complete"); XCTAssertEqual(saved?.content,"前缀首段后台完成"); XCTAssertEqual(saved?.reasoning,"思考")
    }

    @MainActor func testStoppedTransferCannotCompleteRegeneratedMessage() async throws {
        let (root, db) = try await makeReplyDatabase()
        defer { try? FileManager.default.removeItem(at: root) }
        let user = StoredMessage(topicID: "topic", role: "user", content: "我", status: "pending")
        let answer = StoredMessage(topicID: user.topicID, role: "assistant", content: "原文", status: "connecting")
        try await db.enqueue(user); try await db.save(answer)
        let old = BackgroundReplyJob(messageID: answer.id, topicID: user.topicID, userID: user.id)
        try await db.registerBackgroundReply(old)
        let stopped = try await db.finishBackgroundReply(old, reply: nil, stopped: true)
        XCTAssertEqual(stopped?.status, "stopped"); XCTAssertEqual(stopped?.content, "原文")
        let next = BackgroundReplyJob(messageID: answer.id, topicID: user.topicID, userID: user.id)
        try await db.registerBackgroundReply(next)
        let late = try FinishedReply(data: Data(#"{"choices":[{"message":{"content":"过期结果"}}]}"#.utf8))
        let ignored = try await db.finishBackgroundReply(old, reply: late)
        let pending = try await db.pending(), jobs = try await db.backgroundReplies()
        XCTAssertNil(ignored); XCTAssertEqual(pending, 1); XCTAssertEqual(jobs.map(\.id), [next.id])
    }

    @MainActor func testRelaunchCollectsDurableReceiptAndInterruptsMissingTransfer() async throws {
        let (root, db) = try await makeReplyDatabase()
        defer { try? FileManager.default.removeItem(at: root) }
        let received = StoredMessage(topicID: "topic a/🪴", role: "assistant", content: "", status: "connecting")
        let orphan = StoredMessage(topicID: "another", role: "assistant", content: "保留", status: "connecting")
        let stream = StoredMessage(topicID: "stream", role: "assistant", content: "流", status: "streaming")
        for message in [received, orphan, stream] { try await db.save(message) }
        let job = BackgroundReplyJob(messageID: received.id, topicID: received.topicID, userID: nil)
        try await db.registerBackgroundReply(job)
        try await db.registerBackgroundReply(.init(messageID: orphan.id, topicID: orphan.topicID, userID: nil))
        let dir = root.appendingPathComponent("ReplyTransfers").appendingPathComponent(job.id)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data(#"{"choices":[{"message":{"content":"完成"}}]}"#.utf8).write(to: dir.appendingPathComponent("response"))
        try JSONEncoder().encode(BackgroundReplyTransfers.Receipt()).write(to: dir.appendingPathComponent("receipt"))
        try await db.recoverInterrupted()
        let previous = try await db.messages(topicID: received.topicID)
        XCTAssertEqual(previous.first?.status, "connecting")
        let model = ChatViewModel(); model.replyTransfers = BackgroundReplyTransfers(configuration: .ephemeral)
        try await model.restoreBackgroundReplies(store: db, root: root)
        for room in Array(model.rooms.values) { await room.generation?.value }
        let all = try await db.messages()
        XCTAssertEqual(all.first { $0.id == received.id }?.content, "完成")
        XCTAssertEqual(all.first { $0.id == orphan.id }?.status, "interrupted")
        XCTAssertEqual(all.first { $0.id == orphan.id }?.content, "保留")
        XCTAssertEqual(all.first { $0.id == stream.id }?.status, "interrupted")
        let outstanding = try await db.backgroundReplies()
        XCTAssertTrue(outstanding.isEmpty)

        let link = try XCTUnwrap(ReplyActivityAttributes(jobID: job.id, topicID: job.topicID, started: Date()).url)
        XCTAssertEqual(ReplyActivityAttributes.topic(in: link), received.topicID)
        let notification = ReplyPresentation.notification(for: job)
        XCTAssertEqual(notification.content.userInfo["topicID"] as? String, received.topicID)
        XCTAssertEqual(notification.identifier, job.id); XCTAssertEqual(notification.content.threadIdentifier, received.topicID)
        XCTAssertEqual(notification.content.body, "轻点查看这条回复。")
        let plugins = try XCTUnwrap(Bundle.main.builtInPlugInsURL)
        XCTAssertNotNil(Bundle(url: plugins.appendingPathComponent("ReplyActivity.appex")))
    }
}
