import SwiftUI
import Testing
import WebKit
@testable import VChatRendering

@MainActor
struct HTMLBubbleActionTests {
    @Test func delegatedClicksInWebKitDOM() async throws {
        let stream = try #require(IslandScripts.load(["bubble-stream"]))
        let web = WKWebView()
        // WebKit marks dispatched events untrusted. Adapt only that bit for simulated
        // taps; target selection, capture/bubbling, CSS and child identity use the DOM.
        let setup = """
        const messages = [], bridge = {VCPBubbleEpoch:'A', webkit:{messageHandlers:{
            vcpAction:{postMessage: m => messages.push(m)}
        }}};
        let simulateTap = true;
        const add = document.addEventListener.bind(document);
        document.addEventListener = (type, fn, capture) => {
            if (type !== 'click') return add(type, fn, capture);
            if (capture !== true) throw Error('not a capture listener');
            add(type, e => fn(simulateTap ? {isTrusted:true, target:e.target,
                preventDefault:()=>e.preventDefault(), stopPropagation:()=>e.stopPropagation()} : e), capture);
        };
        """
        let assertions = """
        const host = document.querySelector('[data-vcp-island-host]');
        function check(ok, label) { if (!ok) throw Error(label); }
        let bubbled = 0;
        host.addEventListener('click', () => bubbled++);
        function click(el, handled) {
            const before = bubbled, count = messages.length;
            const allowed = el.dispatchEvent(new MouseEvent('click', {bubbles:true, cancelable:true}));
            check(allowed !== handled && bubbled === before + (handled ? 0 : 1) &&
                messages.length === count + (handled ? 1 : 0), 'event routing: ' + el.outerHTML);
        }
        for (const tag of ['button','div','span','a']) {
            host.innerHTML = '<' + tag + ' data-send="  继续  "><b>显示</b></' + tag + '>';
            const el = host.firstChild, b = el.firstChild;
            check(getComputedStyle(el).cursor === 'pointer' && getComputedStyle(el).touchAction === 'manipulation', 'tap style');
            el.style.cursor = 'help';
            check(getComputedStyle(el).cursor === 'help', 'authored cursor');
            simulateTap = false; click(b, false);
            simulateTap = true; click(b, true);
            const m = messages.at(-1);
            check(m.epoch === 'A' && m.type === 'send' && m.text === '[[点击按钮:继续]]', 'action payload');
            check(el.firstChild === b && el.textContent === '显示 ✓' && el.disabled &&
                el.getAttribute('aria-disabled') === 'true', 'one-shot DOM mark');
            click(b, false);
        }
        for (const markup of [
            '<button data-vcp-system-control="false">系统</button>',
            '<button class="code-copy-btn">复制</button>', '<button class="mermaid-viewer-btn">图表</button>',
            '<button class="vcp-tool-result-delete-btn">删除</button>', '<button disabled>禁用</button>',
            '<span data-send="忽略" aria-disabled="true">禁用</span>', '<button>   </button>',
            ...['vcp-tool-result-header','code-copy-toolbar','mermaid-viewer-toolbar'].map(c =>
                '<div class="'+c+'"><button>工具</button></div>'),
            '<button data-vcp-system-control><span data-send="忽略">工具</span></button>'
        ]) {
            host.innerHTML = markup;
            click(host.querySelector(':last-child:not(:has(*))'), false);
        }
        const prefix = '[[点击按钮:';
        for (const [raw, expected] of [
            [' fallback ', prefix+'fallback]]'], [prefix+'原样]]', prefix+'原样]]'],
            ['x'.repeat(600), prefix+'x'.repeat(498-prefix.length)+']]'],
            [prefix+'y'.repeat(600)+']]', prefix+'y'.repeat(498-prefix.length)+']]'],
            ['z'.repeat(497-prefix.length)+'😀end', prefix+'z'.repeat(497-prefix.length)+']]']
        ]) {
            host.innerHTML = '<button></button>';
            host.firstChild.textContent = raw; click(host.firstChild, true);
            check(messages.at(-1).text === expected, 'format/length');
        }
        """
        try await web.runIslandScript(setup + "\n((window) => {\n" + stream + "\n})(bridge);\n" + assertions, arguments: [:])
    }

    @Test func isolatedHandlerDeliversOnlyCurrentSends() async throws {
        let controller = IslandController()
        defer { controller.unmount() }
        var environment = EnvironmentValues()
        #expect(environment.messageSendAction == nil)
        var received: [String] = []
        environment.messageSendAction = { received.append($0) }
        controller.onSendAction = environment.messageSendAction
        let document = HTMLIslandPolicy.document("", motion: false, media: false, dark: false)
        controller.mount(document, source: "<div style='height:60px'>Ready</div>",
                         streaming: false, media: false, stickers: .init())
        let web = try #require(controller.view)
        let deadline = ContinuousClock.now + .seconds(10)
        while controller.height == 180 && !controller.failed && .now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        try #require(controller.height != 180 && !controller.failed)
        try await web.runIslandScript("""
            const epoch = window.VCPBubbleEpoch;
            const post = body => window.webkit.messageHandlers.vcpAction.postMessage(body);
            post({type:'send',text:'stale',epoch:'retired'});
            post({type:'other',text:'wrong-type',epoch});
            post({type:'send',text:'   ',epoch});
            post({type:'send',text:'accepted',epoch});
            """, arguments: [:])
        let deliveryDeadline = ContinuousClock.now + .seconds(5)
        while !received.contains("accepted") && .now < deliveryDeadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(received == ["accepted"])
    }
}
