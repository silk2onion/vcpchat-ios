import XCTest
import UIKit

final class MessageDisclosureTests: XCTestCase {
    @MainActor func testGroupParallelDiaryAndCalculatorAfterRelaunch() throws {
        continueAfterFailure = false
        let base = try XCTUnwrap(ProcessInfo.processInfo.environment["VCHAT_STREAM_FIXTURE"])
        let app = XCUIApplication()
        app.launchEnvironment["VCHAT_TEST_LIVE_ENDPOINT"] = base + "/group-fc"
        app.launchEnvironment["VCHAT_TEST_SYNC_SESSION"] = UUID().uuidString
        app.launchArguments = ["-native.background-replies", "NO", "-native.server-reply-sync", "NO"]
        app.launch()
        let send = app.buttons["发送消息"], card = app.staticTexts["海边手记"]
        XCTAssertTrue(send.waitForExistence(timeout: 20)); send.tap()
        XCTAssertTrue(card.waitForExistence(timeout: 20), app.debugDescription)
        XCTAssertTrue(app.buttons["函数调用 · Calculator"].exists)
        XCTAssertTrue(prose("已收到两份回执。", in: app).waitForExistence(timeout: 8))
        let shot = XCTAttachment(screenshot: app.screenshot()); shot.name = "Group DailyNote"; shot.lifetime = .keepAlways; add(shot)
        app.terminate(); app.launch()
        XCTAssertTrue(card.waitForExistence(timeout: 15))
        // Reopening follows the newest reply. Scroll back to A's card on compact
        // phones; its Markdown body is mounted and rendered after its heading.
        let diary = app.descendants(matching: .any).matching(
            NSPredicate(format: "value == %@ OR label == %@", "今天在海边记录了潮位。", "今天在海边记录了潮位。")
        ).firstMatch
        if !diary.waitForExistence(timeout: 3) { app.collectionViews.firstMatch.swipeDown() }
        XCTAssertTrue(diary.waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertTrue(send.waitForExistence(timeout: 10)); send.tap()
        XCTAssertTrue(prose("日记编号 note-407，计算结果 323。", in: app).waitForExistence(timeout: 15), app.debugDescription)
    }
    @MainActor func testHostedCallReloadAndReplay() throws { try hostedRound(background: false) }
    @MainActor func testHostedCallDurableTransferAndReplay() throws { try hostedRound(background: true) }
    @MainActor private func hostedRound(background: Bool) throws {
        continueAfterFailure = false
        guard let base = ProcessInfo.processInfo.environment["VCHAT_STREAM_FIXTURE"] else { throw XCTSkip("Requires slow-reply.py on loopback") }
        let app = XCUIApplication()
        app.launchEnvironment["VCHAT_TEST_LIVE_ENDPOINT"] = base + "/fc"
        app.launchEnvironment["VCHAT_TEST_SYNC_SESSION"] = UUID().uuidString
        app.launchArguments = ["-native.background-replies", background ? "YES" : "NO", "-native.server-reply-sync", "NO"]
        app.launch()
        let send = app.buttons["发送消息"], card = app.buttons["函数调用 · 天气"]
        XCTAssertTrue(send.waitForExistence(timeout: 20)); send.tap()
        XCTAssertTrue(card.waitForExistence(timeout: 20))
        XCTAssertTrue(prose("青岛今天晴。", in: app).waitForExistence(timeout: 8))
        XCTAssertEqual(card.value as? String, "已收起"); card.tap()
        XCTAssertTrue(app.textViews.matching(NSPredicate(format: "value CONTAINS %@", "<em>原文</em>")).firstMatch.waitForExistence(timeout: 4))
        XCTAssertFalse(app.webViews.firstMatch.exists)
        let shot = XCTAttachment(screenshot: app.screenshot()); shot.name = "Hosted function detail"; shot.lifetime = .keepAlways; add(shot)
        app.terminate(); app.launch()
        XCTAssertTrue(card.waitForExistence(timeout: 15)); XCTAssertEqual(card.value as? String, "已收起")
        XCTAssertTrue(send.waitForExistence(timeout: 8)); send.tap()
        XCTAssertTrue(prose("历史配对成功", in: app).waitForExistence(timeout: 15))
    }
    @MainActor func testSelectWordAndAskWithoutLeavingTranscript() {
        continueAfterFailure = false
        let app = XCUIApplication()
        let sample = "Orbit velocity describes a route."
        app.launchEnvironment["VCHAT_TEST_DISCLOSURE_MESSAGE"] = sample
        app.launchEnvironment["VCHAT_TEST_LATER_MESSAGE"] = "Later route"
        app.launch()
        let body = app.descendants(matching: .any).matching(NSPredicate(format: "value == %@ OR label == %@", sample, sample)).firstMatch
        XCTAssertTrue(body.waitForExistence(timeout: 15))
        let word = body.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: 16, dy: 10))
        word.press(forDuration: 0.9)
        let ask = app.menuItems["单独追问"].firstMatch
        XCTAssertTrue(ask.waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertTrue(app.menuItems.matching(NSPredicate(format: "label IN %@", ["复制","Copy"])).firstMatch.exists)
        let originalY = body.frame.minY
        ask.tap()
        XCTAssertTrue(app.navigationBars["单独追问"].waitForExistence(timeout: 4))
        XCTAssertTrue(app.staticTexts["Orbit"].exists)
        let screenshot = XCTAttachment(screenshot: app.screenshot()); screenshot.name = "Selected quote"; screenshot.lifetime = .keepAlways; add(screenshot)
        app.buttons["完成"].tap()
        XCTAssertTrue(body.waitForExistence(timeout: 4))
        XCTAssertEqual(body.frame.minY, originalY, accuracy: 1)
        XCTAssertTrue(app.staticTexts["Later route"].exists)
        body.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: -8, dy: 8)).press(forDuration: 0.8)
        let branch = app.buttons["从这里另开话题"].firstMatch
        XCTAssertTrue(branch.waitForExistence(timeout: 5)); branch.tap()
        XCTAssertTrue(app.staticTexts["新对话 · 分支"].waitForExistence(timeout: 5))
        XCTAssertTrue(body.exists); XCTAssertFalse(app.staticTexts["Later route"].exists)
    }
    @MainActor func testIslandTextHasSelectionInsteadOfMessageMenu() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchEnvironment["VCHAT_TEST_DISCLOSURE_MESSAGE"] = "<div id='vcp-root'><p>Orbit velocity describes a route.</p></div>"
        app.launch()
        let text = app.webViews.staticTexts["Orbit velocity describes a route."].firstMatch
        XCTAssertTrue(text.waitForExistence(timeout: 15))
        text.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: 14,dy: 9)).press(forDuration: 1)
        let ask = app.menuItems["单独追问"].firstMatch
        XCTAssertTrue(ask.waitForExistence(timeout: 4), app.debugDescription); ask.tap()
        XCTAssertTrue(app.navigationBars["单独追问"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Orbit"].exists)
    }
    @MainActor private func prose(_ value: String, in app: XCUIApplication) -> XCUIElement {
        app.textViews.matching(NSPredicate(format: "value == %@", value)).firstMatch
    }

    @MainActor private func openDisclosure(_ header: XCUIElement, in app: XCUIApplication,
                                           file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(header.waitForExistence(timeout: 10), app.debugDescription, file: file, line: line)
        XCTAssertEqual(header.value as? String, "已收起", file: file, line: line)
        if header.isHittable {
            header.tap()
        } else {
            // XCTest can report no activation point for an on-screen SwiftUI
            // List button. Exercise the same physical tap a reader would make.
            let frame = header.frame
            let center = CGPoint(x: frame.midX, y: frame.midY)
            let list = app.collectionViews.firstMatch
            XCTAssertTrue(list.frame.contains(center), app.debugDescription, file: file, line: line)
            let origin = app.coordinate(withNormalizedOffset: .zero)
            origin.withOffset(CGVector(dx: center.x - app.frame.minX, dy: center.y - app.frame.minY)).tap()
        }
        XCTAssertEqual(header.value as? String, "已展开", app.debugDescription, file: file, line: line)
    }

    @MainActor func testReceiptTableAndLiteralHTMLShareOneDisclosure() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchEnvironment["VCHAT_TEST_DISCLOSURE_MESSAGE"] = """
        <<<[VCP_TOOL_BATCH_START:table]>>>
        [[VCP调用结果信息汇总:
        工具名称: 路线比较
        返回内容:
        | 方案 | 时间 |
        | --- | --- |
        | 步行 | 12 分钟 |

        - [路线详情](https://example.org/map)

        <div id="vcp-root">原文</div>
        VCP调用结果结束]]
        [本轮工具调用摘要:]
        查询完成
        [本轮工具调用摘要结束]
        <<<[VCP_TOOL_BATCH_END:table]>>>
        """
        app.launch()
        let summary = app.buttons["本轮工具调用摘要"].firstMatch
        openDisclosure(summary, in: app)
        XCTAssertTrue(prose("12 分钟", in: app).waitForExistence(timeout: 5))
        XCTAssertTrue(prose("方案", in: app).exists)
        XCTAssertTrue(app.textViews.matching(NSPredicate(format: "value CONTAINS %@", #"<div id="vcp-root">"#)).firstMatch.exists)
        XCTAssertFalse(app.webViews.firstMatch.exists)
        let shot = XCTAttachment(screenshot: app.screenshot()); shot.name = "Rich tool receipt"; shot.lifetime = .keepAlways; add(shot)
    }

    @MainActor func testSendQuotedFollowUpInItsOwnRoom() throws {
        continueAfterFailure = false
        guard let base = ProcessInfo.processInfo.environment["VCHAT_STREAM_FIXTURE"] else { throw XCTSkip("Requires slow-reply.py on loopback") }
        let app = XCUIApplication(), sample = "Orbit velocity describes a route."
        app.launchEnvironment["VCHAT_TEST_LIVE_ENDPOINT"] = base + "/quote"
        app.launchEnvironment["VCHAT_TEST_DISCLOSURE_MESSAGE"] = sample
        app.launchArguments = ["-native.background-replies", "NO"]
        app.launch()
        let body = prose(sample, in: app)
        XCTAssertTrue(body.waitForExistence(timeout: 12))
        body.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: 16,dy: 10)).press(forDuration: 0.85)
        app.menuItems["单独追问"].tap()
        let input = app.descendants(matching: .any)["side-question-input"].firstMatch
        XCTAssertTrue(input.waitForExistence(timeout: 5)); input.tap(); input.typeText("Explain.")
        app.buttons["发送追问"].tap()
        // The fixture responds only to the selected word plus the question, with no parent history.
        XCTAssertTrue(app.staticTexts["Quote received"].waitForExistence(timeout: 15), app.debugDescription)
        app.buttons["完成"].tap()
        XCTAssertTrue(body.exists); XCTAssertFalse(app.staticTexts["Quote received"].exists)
        XCTAssertEqual(app.textViews["发消息"].value as? String, "本机测试")
    }
    // The fixture provides an isolated, paired desktop and legacy checkpoints in the simulator.
    @MainActor func testScrollAfterBidirectionalSyncWithExistingCheckpoints() throws {
        guard let n = ProcessInfo.processInfo.environment["VCHAT_SYNC_CHECKPOINT_COUNT"].flatMap(Int.init) else {
            throw XCTSkip("Requires seeded MobileSync simulator and loopback peer")
        }
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launch()
        app.buttons["我"].tap()
        app.staticTexts["桌面同步"].firstMatch.tap()
        let list = app.scrollViews.firstMatch, rows = app.buttons.matching(identifier: "恢复此前状态")
        XCTAssertTrue(list.waitForExistence(timeout: 10))
        let indexed = NSPredicate { _,_ in rows.count == n }
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate:indexed,object:nil)], timeout:120), .completed)
        let token = app.secureTextFields["桌面同步 Token"]
        if (token.value as? String ?? "").isEmpty || token.value as? String == "桌面同步 Token" {
            token.tap(); token.typeText("index-fixture\n")
        }
        let sync = app.buttons["双向同步"]
        if !sync.isHittable { list.swipeUp() }
        sync.tap(); app.buttons["开始双向同步"].tap()
        let done = app.descendants(matching:.any).matching(NSPredicate(format:"label CONTAINS %@", "同步完成，恢复点已保存")).firstMatch
        XCTAssertTrue(done.waitForExistence(timeout:90), app.debugDescription)
        XCTAssertEqual(rows.count,n + 1)
        for _ in 0..<3 { list.swipeUp(velocity:.fast); list.swipeDown(velocity:.fast) }
        list.swipeUp()
        XCTAssertEqual(app.state,.runningForeground)
        XCTAssertEqual(rows.count,n + 1)
        let shot = XCTAttachment(screenshot:app.screenshot()); shot.name = "滚动后的恢复点列表"; shot.lifetime = .keepAlways; add(shot)
        let newest = rows.element(boundBy:0)
        if !newest.isHittable { list.swipeDown() }
        newest.tap()
        let restore = app.buttons["保留当前副本并恢复"]
        XCTAssertTrue(restore.waitForExistence(timeout:5))
        restore.tap()
        let restored = app.descendants(matching:.any).matching(NSPredicate(format:"label CONTAINS %@", "已恢复；恢复前内容仍在恢复点中")).firstMatch
        XCTAssertTrue(restored.waitForExistence(timeout:30),app.debugDescription)
        XCTAssertEqual(rows.count,n + 2)
    }
    @MainActor func testSettingsLastRowClearsBottomTabs() {
        let app = XCUIApplication()
        app.launch()
        app.buttons["我"].tap()
        app.staticTexts["设置"].firstMatch.tap()
        let list = app.scrollViews.firstMatch
        XCTAssertTrue(list.waitForExistence(timeout: 5))
        let last = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "关于 VCPChat")).firstMatch
        list.swipeUp(velocity: .fast)
        XCTAssertTrue(last.isHittable)
        let tabTop = app.buttons["我"].frame.minY
        XCTAssertLessThanOrEqual(list.frame.maxY, tabTop)
        XCTAssertLessThanOrEqual(last.frame.maxY, tabTop)
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "Settings bottom"; screenshot.lifetime = .keepAlways; add(screenshot)
        last.tap()
        XCTAssertTrue(app.navigationBars["关于 VChat"].waitForExistence(timeout: 5))

        app.navigationBars.buttons.firstMatch.tap()
        XCUIDevice.shared.orientation = .landscapeLeft
        defer { XCUIDevice.shared.orientation = .portrait }
        let rotated = NSPredicate { _, _ in list.frame.width > list.frame.height }
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: rotated, object: nil)], timeout: 10), .completed)
        for _ in 0..<4 {
            if last.isHittable && last.frame.maxY <= app.buttons["我"].frame.minY { break }
            list.swipeUp(velocity: .fast)
        }
        XCTAssertTrue(last.isHittable)
        XCTAssertLessThanOrEqual(list.frame.maxY, app.buttons["我"].frame.minY)
        XCTAssertLessThanOrEqual(last.frame.maxY, app.buttons["我"].frame.minY)
        XCTAssertLessThanOrEqual(app.buttons["我"].frame.maxY, app.frame.maxY)
    }

    @MainActor func testJEVDisclosureKeepsOriginalRequest() {
        let app = XCUIApplication()
        app.launchEnvironment["VCHAT_TEST_DISCLOSURE_MESSAGE"] = "<<<[TOOL_REQUEST]>>>\nJEV:「始」用 {联网搜索} 查询天气「末」\n<<<[END_TOOL_REQUEST]>>>"
        app.launch()
        let tool = app.buttons["联网搜索"].firstMatch
        openDisclosure(tool, in: app)
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "用 {联网搜索} 查询天气")).firstMatch.waitForExistence(timeout: 5), app.debugDescription)
    }

    @MainActor func testHistoricalButtonReceipt() {
        let app = XCUIApplication()
        let token = "[[点击按钮:继续探索]]"
        app.launchEnvironment["VCHAT_TEST_DISCLOSURE_MESSAGE"] = token
        app.launchEnvironment["VCHAT_TEST_MESSAGE_ROLE"] = "user"
        app.launch()
        let receipt = app.descendants(matching: .any).matching(NSPredicate(format: "label == %@", "已点击按钮：继续探索")).firstMatch
        XCTAssertTrue(receipt.waitForExistence(timeout: 20))
        XCTAssertFalse(app.staticTexts[token].exists)
    }

    @MainActor func testTappingOneHeaderChangesOnlyThatSection() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchEnvironment["VCHAT_TEST_DISCLOSURE_MESSAGE"] = """
        这里的 `<script>` 是代码示例。
        <<<[TOOL_REQUEST]>>>
        tool_name:「始」天气「末」
        command:「始」查询「末」
        <<<[END_TOOL_REQUEST]>>>
        <<<[TOOL_REQUEST]>>>
        tool_name:「始」时钟「末」
        <<<[END_TOOL_REQUEST]>>>
        <<<[VCP_TOOL_BATCH_START:example]>>>
        [[VCP调用结果信息汇总:
        - 工具名称: 天气
        - 执行状态: 成功
        - 返回内容: 小雨
        VCP调用结果结束]]
        [[VCP调用结果信息汇总:
        - 工具名称: 时钟
        - 执行状态: 成功
        - 返回内容: 九点
        VCP调用结果结束]]
        [本轮工具调用摘要:]
        两次调用成功
        [本轮工具调用摘要结束]
        <<<[VCP_TOOL_BATCH_END:example]>>>
        [[VCP调用结果信息汇总:
        - 工具名称: 独立回执
        - 返回内容: 单独的结果
        VCP调用结果结束]]
        [--- VCP元思考链: "推理片段" ---]
        独立的一段思考
        [--- 元思考链结束 ---]
        """
        app.launch()
        let titles = ["思考过程","天气","时钟","本轮工具调用摘要","工具结果 · 独立回执","推理片段"]
        let buttons = titles.map { app.buttons[$0].firstMatch }
        XCTAssertTrue(buttons[3].waitForExistence(timeout:20))
        func check(_ open: Set<Int>, file: StaticString = #filePath, line: UInt = #line) {
            for (index, button) in buttons.enumerated() {
                XCTAssertEqual(button.value as? String, open.contains(index) ? "已展开" : "已收起", titles[index], file:file,line:line)
            }
        }
        func tap(_ index: Int) {
            let b = buttons[index]
            if !b.isHittable {
                let list = app.collectionViews.firstMatch
                if b.frame.midY < list.frame.midY { list.swipeDown() } else { list.swipeUp() }
            }
            b.tap()
        }
        check([])
        tap(5); check([5]); tap(5); check([])
        tap(1); check([1])
        tap(0); check([0,1])
        tap(1); check([0])
        tap(0); check([])
        XCTAssertFalse(app.buttons["工具结果 · 天气"].exists)
        XCTAssertFalse(app.buttons["工具结果 · 时钟"].exists)
        tap(3); check([3]); XCTAssertTrue(app.staticTexts["两次调用成功"].exists)
        for value in ["小雨", "九点"] { XCTAssertTrue(prose(value, in: app).exists) }
        XCTAssertFalse(prose("单独的结果", in: app).exists)
        tap(3); tap(4); check([4]); XCTAssertTrue(prose("单独的结果", in: app).exists)
        XCTAssertFalse(prose("小雨", in: app).exists)
    }
    @MainActor func testSaveMarkdownAndHTMLPhotosFromChat() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        let bounds = CGRect(x: 0, y: 0, width: 180, height: 70)
        let png = UIGraphicsImageRenderer(bounds: bounds).pngData { ctx in UIColor.orange.setFill(); ctx.fill(bounds) }
        let src = "data:image/png;base64," + png.base64EncodedString()
        for html in [false, true] {
            app.launchEnvironment["VCHAT_TEST_DISCLOSURE_MESSAGE"] = html
                ? "<div id='vcp-root'><picture><source srcset='\(src) 1x'><img alt='卡片测试图' style='display:block;width:100%' src='\(src)'></picture></div>"
                : "![测试图片](\(src))"
            app.launch()
            if html {
                let web = app.webViews.firstMatch
                XCTAssertTrue(web.images["卡片测试图"].firstMatch.waitForExistence(timeout: 25))
                web.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).press(forDuration: 0.9)
            } else {
                let image = app.buttons["打开图片：测试图片"].firstMatch
                XCTAssertTrue(image.waitForExistence(timeout: 20)); image.tap()
            }
            let save = app.buttons["保存到照片"].firstMatch
            XCTAssertTrue(save.waitForExistence(timeout: 15)); save.tap()
            let permission = XCUIApplication(bundleIdentifier: "com.apple.springboard").alerts.buttons
                .matching(NSPredicate(format: "label IN %@", ["Allow", "Allow Add Only", "允许", "只允许添加照片"])).firstMatch
            if permission.waitForExistence(timeout: 2) { permission.tap() }
            let saved = app.alerts.containing(.staticText, identifier: "已保存到照片").firstMatch
            guard saved.waitForExistence(timeout: 20) else {
                let alerts = app.state == .runningForeground ? app.alerts.allElementsBoundByIndex.map(\.label) : []
                XCTFail("Photo write failed (HTML=\(html), appState=\(app.state.rawValue), alerts=\(alerts))")
                return
            }
            app.alerts.buttons["好"].tap()
        }
    }

    @MainActor func testHomeDuringStreamThenReturnBeforeFinish() async throws {
        // Use explicit guards instead of unwinding an async XCTest via an ObjC exception.
        continueAfterFailure = true
        guard let endpoint = ProcessInfo.processInfo.environment["VCHAT_STREAM_FIXTURE"],
              let url = URL(string:endpoint)?.appendingPathComponent("ui") else { throw XCTSkip("Requires the gated loopback server") }
        let app = XCUIApplication()
        app.launchEnvironment["VCHAT_TEST_LIVE_ENDPOINT"] = url.absoluteString
        app.launchArguments = ["-native.background-replies", "YES"]
        app.launch()
        let send = app.buttons["发送消息"]
        guard send.waitForExistence(timeout:20) else { XCTFail("Chat did not open"); return }
        send.tap()
        guard prose("首段", in: app).waitForExistence(timeout:20) else { XCTFail("First chunk was not visible before completion"); return }
        XCUIDevice.shared.press(.home)
        func hasLeftChat() -> Bool { app.state == .runningBackground || app.state == .runningBackgroundSuspended }
        if !hasLeftChat() && !app.wait(for:.runningBackground,timeout:5) && !hasLeftChat() {
            // iOS can spend the first press dismissing a system presentation.
            // Explicitly switch apps and require actual background state.
            XCUIApplication(bundleIdentifier:"com.apple.Preferences").activate()
        }
        guard hasLeftChat() || app.wait(for:.runningBackground,timeout:15) || hasLeftChat()
        else { XCTFail("The chat app never entered the background"); return }
        // The server emits nothing else until *after* the old background lease
        // would have ended. It still cannot finish until after we return.
        try await Task.sleep(for:.seconds(32))
        _ = try await URLSession.shared.data(from:url.appendingPathComponent("next"))
        try await Task.sleep(for:.seconds(2))
        app.activate()
        guard prose("首段补齐", in: app).waitForExistence(timeout:20) else { XCTFail("Missing background chunk before completion"); return }
        XCTAssertTrue(app.buttons["停止生成"].exists)
        let (body,_) = try await URLSession.shared.data(from:url.appendingPathComponent("finish"))
        XCTAssertEqual(String(decoding:body,as:UTF8.self),"1")
        XCTAssertTrue(send.waitForExistence(timeout:20))
    }

    @MainActor func testServerReplySurvivesProcessLossWithoutSecondGeneration() async throws {
        guard let base=ProcessInfo.processInfo.environment["VCHAT_REPLY_SYNC_FIXTURE"],let url=URL(string:base) else {
            throw XCTSkip("Requires the companion plugin with its local synthetic VCP endpoint")
        }
        let id=UUID().uuidString, app=XCUIApplication()
        app.launchEnvironment["VCHAT_TEST_LIVE_ENDPOINT"]=base
        app.launchEnvironment["VCHAT_TEST_SYNC_SESSION"]=id
        app.launchArguments=["-native.background-replies","YES","-native.server-reply-sync","YES"]
        app.launch()
        let send=app.buttons["发送消息"]
        guard send.waitForExistence(timeout:20) else { XCTFail("Missing composer"); return }
        send.tap()
        guard prose("首段", in: app).waitForExistence(timeout:20) else { XCTFail("Missing live server prefix"); return }
        let authors = app.staticTexts.matching(NSPredicate(format: "identifier BEGINSWITH %@", "assistant-author-"))
        let original = authors.firstMatch.identifier
        XCTAssertFalse(original.isEmpty)
        app.terminate()
        // Model a system cold launch: no XCTest-only endpoint, DB identifier,
        // or preference arguments will be available to a background wake.
        app.launchEnvironment = [:]; app.launchArguments = []
        let (body,_)=try await URLSession.shared.data(from:url.appendingPathComponent("release").appendingPathComponent(id))
        XCTAssertEqual(String(decoding:body,as:UTF8.self),"1")
        app.launch()
        guard prose("首段后台完成", in: app).waitForExistence(timeout:25) else {
            XCTFail("Recovery failed: author=\(app.staticTexts[original].exists), composer=\(send.exists), busy=\(app.buttons["停止生成"].exists), prefix=\(app.staticTexts["首段"].exists), interrupted=\(app.staticTexts["已中断 · 内容已保留"].exists)")
            return
        }
        XCTAssertTrue(send.waitForExistence(timeout:15))
        XCTAssertEqual(app.textViews.matching(NSPredicate(format:"value == %@", "首段后台完成")).count,1)
        XCTAssertEqual(authors.count, 1)
        XCTAssertEqual(authors.firstMatch.identifier, original)
        app.terminate(); app.launchEnvironment["VCHAT_TEST_END_SYNC_SESSION"] = id; app.launch()
        XCTAssertTrue(prose("首段后台完成", in: app).waitForExistence(timeout: 20), "The restored reply must also be committed to disk")
        XCTAssertEqual(authors.firstMatch.identifier, original)
        let (count,_)=try await URLSession.shared.data(from:url.appendingPathComponent("count").appendingPathComponent(id))
        XCTAssertEqual(String(decoding:count,as:UTF8.self),"1")
    }

    @MainActor func testScrolledMessageDoesNotPaintBehindChatHeader() throws {
        let app = XCUIApplication()
        app.launchEnvironment["VCHAT_TEST_DISCLOSURE_MESSAGE"] = #"<div id="vcp-root" style="height:2100px;background:#ff00ff">色带</div>"#
        app.launch()
        let list = app.collectionViews.firstMatch, bar = app.navigationBars.firstMatch
        XCTAssertTrue(list.waitForExistence(timeout:20)); XCTAssertTrue(bar.waitForExistence(timeout:10))
        guard app.webViews.staticTexts["色带"].firstMatch.waitForExistence(timeout:20) else {
            XCTFail("The tall message did not render"); return
        }
        list.swipeUp()
        let screen = app.screenshot()
        let image = try XCTUnwrap(screen.image.cgImage)
        let bounds = app.frame, top = bar.frame.maxY, scale = CGFloat(image.width) / bounds.width
        // The saturated test card must fill the viewport immediately below the
        // header. Look for that same ink leaking into the navigation or status bar.
        func ink(from y: CGFloat, height: CGFloat) throws -> Double {
            let strip = CGRect(x:bounds.width*0.2,y:y,width:bounds.width*0.6,height:height)
            let cropped = try XCTUnwrap(image.cropping(to:strip.applying(.init(scaleX:scale,y:scale))))
            let ctx = try XCTUnwrap(CGContext(data:nil,width:32,height:32,bitsPerComponent:8,bytesPerRow:128,
                space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGImageAlphaInfo.noneSkipLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue))
            ctx.draw(cropped,in:CGRect(x:0,y:0,width:32,height:32))
            let bytes = try XCTUnwrap(ctx.data).assumingMemoryBound(to:UInt8.self)
            return Double((0..<1024).filter { i in bytes[i*4]>190 && bytes[i*4+1]<65 && bytes[i*4+2]>190 }.count)/1024
        }
        let attachment = XCTAttachment(screenshot:screen); attachment.name = "Scrolled-chat-header"; add(attachment)
        XCTAssertGreaterThan(try ink(from:top+4,height:60),0.6, "Fixture must actually be under the header edge")
        XCTAssertLessThan(try ink(from:bounds.minY,height:top-bounds.minY-1),0.01)
        XCTAssertTrue(bar.buttons["历史话题"].firstMatch.isHittable)
    }
}
