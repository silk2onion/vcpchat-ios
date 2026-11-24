import XCTest
import UIKit

final class MessageDisclosureTests: XCTestCase {
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
        for value in ["小雨", "九点"] { XCTAssertEqual(app.staticTexts.matching(identifier: value).count, 1) }
        XCTAssertFalse(app.staticTexts["单独的结果"].exists)
        tap(3); tap(4); check([4]); XCTAssertTrue(app.staticTexts["单独的结果"].exists)
        XCTAssertFalse(app.staticTexts["小雨"].exists)
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
        guard app.staticTexts["首段"].waitForExistence(timeout:20) else { XCTFail("First chunk was not visible before completion"); return }
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
        guard app.staticTexts["首段补齐"].waitForExistence(timeout:20) else { XCTFail("Missing background chunk before completion"); return }
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
        guard app.staticTexts["首段"].waitForExistence(timeout:20) else { XCTFail("Missing live server prefix"); return }
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
        guard app.staticTexts["首段后台完成"].waitForExistence(timeout:25) else {
            XCTFail("Recovery failed: author=\(app.staticTexts[original].exists), composer=\(send.exists), busy=\(app.buttons["停止生成"].exists), prefix=\(app.staticTexts["首段"].exists), interrupted=\(app.staticTexts["已中断 · 内容已保留"].exists)")
            return
        }
        XCTAssertTrue(send.waitForExistence(timeout:15))
        XCTAssertEqual(app.staticTexts.matching(NSPredicate(format:"label == %@", "首段后台完成")).count,1)
        XCTAssertEqual(authors.count, 1)
        XCTAssertEqual(authors.firstMatch.identifier, original)
        app.terminate(); app.launchEnvironment["VCHAT_TEST_END_SYNC_SESSION"] = id; app.launch()
        XCTAssertTrue(app.staticTexts["首段后台完成"].waitForExistence(timeout: 20), "The restored reply must also be committed to disk")
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
