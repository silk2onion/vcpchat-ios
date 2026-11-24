#if os(iOS)
import Foundation
import CryptoKit
import OSLog
import VChatCore

/// One server-owned generation. Only the initial, user-initiated path may PUT.
/// Reattachment, network retries and cold starts only GET the existing job.
@MainActor final class ServerReplyClient: NSObject, URLSessionTaskDelegate {
    static let preference = "native.server-reply-sync"
    static let marker = "server-sync-v1"
    static let archiveName = "server-result.json"
    static let taskPrefix = "server-result:"
    private static let limit = 16 * 1024 * 1024

    // Diagnostic events exist only in a synthetic simulator relaunch. Log no
    // endpoint, grant, IDs or message content, even for the fixture.
    static func trace(_ message: @autoclosure () -> String) {
        #if DEBUG && targetEnvironment(simulator)
        if UserDefaults.standard.data(forKey: SimulatorReplyFixture.key) != nil {
            let line = message()
            Logger(subsystem: "app.vcpchat.native.fixture", category: "recovery").notice("\(line, privacy: .public)")
        }
        #endif
    }
    struct Access: Codable, Sendable {
        var url: URL, key: String, proof: String
        func request(method: String, suffix: String = "", offset: Int? = nil) -> URLRequest {
            let base = suffix.isEmpty ? url : url.appendingPathComponent(suffix)
            var dest = URLComponents(url:base,resolvingAgainstBaseURL:false)!
            if let offset { dest.queryItems = [.init(name:"offset",value:String(offset))] }
            var req = URLRequest(url:dest.url!, cachePolicy:.reloadIgnoringLocalCacheData, timeoutInterval:25)
            req.httpMethod = method
            req.setValue("Bearer " + key, forHTTPHeaderField:"Authorization")
            req.setValue(proof, forHTTPHeaderField:"X-VChat-Proof")
            req.setValue("application/json", forHTTPHeaderField:"Accept")
            return req
        }
    }
    struct Page: Decodable, Sendable { let id: String, state: String, reason: String?, offset: Int, next: Int, data: Data }
    private enum Failure: Error { case http(Int), invalid }
    private let id: String, directory: URL, vault: CredentialVault
    private let changed: () -> Void
    private let finish: (BackgroundReplyTransfers.Receipt) -> Void
    private let scheduleDownload: (URLRequest) -> Void
    private var worker: Task<Void,Never>?
    private var access: Access?
    private var done = false, stopping = false, scheduled = false, accepted = false
    private var epoch = UUID()
    private var replyFile: URL { directory.appendingPathComponent("response") }
    static func account(_ id: String) -> String { "server-reply-v1." + id }
    private lazy var network: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.urlCredentialStorage = nil; config.httpShouldSetCookies = false; config.urlCache = nil
        return URLSession(configuration:config, delegate:self, delegateQueue:nil)
    }()
    init(id: String, directory: URL, vault: CredentialVault, changed: @escaping () -> Void,
         scheduleDownload: @escaping (URLRequest) -> Void, finish: @escaping (BackgroundReplyTransfers.Receipt) -> Void) {
        self.id=id; self.directory=directory; self.vault=vault; self.changed=changed
        self.scheduleDownload=scheduleDownload; self.finish=finish
    }
    nonisolated func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                                newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil) // Never forward the per-job grant or chat key to another URL.
    }
    private func check(_ response: URLResponse) throws {
        guard let http=response as? HTTPURLResponse else { throw Failure.invalid }
        guard http.statusCode == 200 else { throw Failure.http(http.statusCode) }
    }
    private func cursor() throws -> Int {
        if !FileManager.default.fileExists(atPath:replyFile.path) { return 0 }
        guard let size = try FileManager.default.attributesOfItem(atPath:replyFile.path)[.size] as? NSNumber else { throw Failure.invalid }
        return size.intValue
    }
    private func complete(_ error: String? = nil, stopped: Bool = false) {
        guard !done else { return }; done=true; worker?.cancel()
        finish(.init(error:error,stopped:stopped))
    }
    private func apply(_ page: Page, archive: Bool = false) throws {
        guard !done, !stopping else { return }
        let position = try cursor()
        guard page.id.lowercased()==id.lowercased(), ["running","complete","stopped","interrupted"].contains(page.state),
              page.offset >= 0, page.next >= page.offset, page.next <= Self.limit,
              page.next - page.offset == page.data.count else { throw Failure.invalid }
        Self.trace("apply archive=\(archive) state=\(page.state) position=\(position) offset=\(page.offset) next=\(page.next)")
        if archive {
            guard page.offset==0, page.state != "running", position<=page.next else { throw Failure.invalid }
        } else if page.offset != position { throw Failure.invalid }
        if position < page.next {
            if position == 0 { try Data().write(to:replyFile,options:.completeFileProtectionUntilFirstUserAuthentication) }
            let handle=try FileHandle(forWritingTo:replyFile); defer { try? handle.close() }
            try handle.seekToEnd(); try handle.write(contentsOf:page.data.dropFirst(position-page.offset))
            changed()
        }
        switch page.state {
        case "complete": complete()
        case "stopped": complete(stopped:true)
        case "interrupted": complete("VCP 生成中断，已保留此前收到的内容。" + (page.reason.map { "（" + String($0.prefix(80)) + "）" } ?? ""))
        default: break
        }
    }
    nonisolated private static func decodeArchive(_ url: URL) async throws -> Page {
        let size = try url.resourceValues(forKeys:[.fileSizeKey]).fileSize ?? 0
        guard size <= 24*1024*1024 else { throw ClientError.tooLarge }
        return try JSONDecoder().decode(Page.self,from:Data(contentsOf:url,options:.mappedIfSafe))
    }
    func acceptArchive() async {
        guard !done, !stopping else { return }
        let url=directory.appendingPathComponent(Self.archiveName)
        guard FileManager.default.fileExists(atPath:url.path) else { return }
        do { let page=try await Self.decodeArchive(url); try apply(page,archive:true) }
        catch { try? FileManager.default.removeItem(at:url) } // authoritative GET can still recover
    }
    func prepare(_ request: ChatRequest) async throws {
        let root=try request.configuration.endpoint("api/plugins/VChatReplySync/jobs")
        // A shared VCP key does not grant access to another device's job, even if its UUID is known.
        let secret=SymmetricKey(size:.bits256).withUnsafeBytes { $0.map { String(format:"%02x",$0) }.joined() }
        let grant=Access(url:root.appendingPathComponent(id.lowercased()),key:request.apiKey,proof:secret)
        try Data().write(to:directory.appendingPathComponent(Self.marker),options:[.atomic,.completeFileProtectionUntilFirstUserAuthentication])
        try await vault.save(String(decoding:try JSONEncoder().encode(grant),as:UTF8.self),name:Self.account(id))
        access=grant
    }
    func start(initial: (@Sendable () async throws -> URLRequest)? = nil, route: String = "chatvcp", downloadExists: Bool = false) {
        scheduled=downloadExists; accepted=downloadExists
        let own=epoch
        worker=Task { [self] in
            var create=initial, tries=0
            await acceptArchive()
            if FileManager.default.fileExists(atPath:directory.appendingPathComponent("stop").path) { stop(); return }
            while !done && !Task.isCancelled && epoch==own {
                do {
                    if access == nil {
                        let value=try await vault.read(Self.account(id),allowingInteraction:false)
                        Self.trace("grant loaded=\(!value.isEmpty)")
                        guard !value.isEmpty else { complete("这条回复的本机凭据已丢失；不会自动重发。"); return }
                        access=try JSONDecoder().decode(Access.self,from:Data(value.utf8))
                    }
                    guard let access, !done, !Task.isCancelled, epoch==own else { return }
                    if let initial=create {
                        create=nil // even a lost acknowledgement must not replay the POST
                        let call = try await initial()
                        guard !done, !stopping, !Task.isCancelled, epoch == own else { return }
                        var req=access.request(method:"PUT"); req.httpBody=call.httpBody
                        req.setValue(route,forHTTPHeaderField:"X-VChat-Route")
                        req.setValue("application/json",forHTTPHeaderField:"Content-Type")
                        let (data,response)=try await network.data(for:req); try check(response)
                        struct Ack: Decodable { let id:String, version:Int }
                        let ack=try JSONDecoder().decode(Ack.self,from:data)
                        guard ack.id.lowercased()==id.lowercased(), ack.version==1 else { throw Failure.invalid }
                        accepted=true; retryDownloadOnReturn()
                    }
                    guard !done, !Task.isCancelled, epoch==own else { return }
                    let req=access.request(method:"GET",offset:try cursor())
                    let (data,response)=try await network.data(for:req); try check(response)
                    guard !done, !Task.isCancelled, epoch==own else { return }
                    guard data.count < 256*1024 else { throw Failure.invalid }
                    try apply(JSONDecoder().decode(Page.self,from:data))
                    if !accepted { accepted=true; retryDownloadOnReturn() }
                    tries=0
                } catch {
                    guard !done, !Task.isCancelled, epoch==own else { return }
                    Self.trace("reader error type=\(type(of: error)) code=\((error as NSError).code)")
                    if case Failure.http(let status) = error, (400..<500).contains(status), status != 429 {
                        if status != 404 || tries >= 2 {
                            complete("VCP 续传服务返回 HTTP \(status)。请检查插件、密钥或记录保留时间；不会自动重发。"); return
                        }
                    } else {
                        switch error {
                        case is URLError, is CredentialVault.AccessError, Failure.http: break
                        default: complete("无法读取 VCP 续传数据，已保留本机接收的部分。"); return
                        }
                    }
                    tries=min(tries+1,5)
                    do { try await Task.sleep(for:.seconds(1 << (tries-1))) } catch { return }
                }
            }
        }
    }
    func retryDownloadOnReturn() {
        if accepted, !done, !stopping, !scheduled, let access { scheduled=true; scheduleDownload(access.request(method:"GET",suffix:"result")) }
    }
    func downloadFailed() { scheduled=false }
    func stop() {
        guard !done, !stopping else { return }
        stopping=true; epoch=UUID(); worker?.cancel()
        try? Data().write(to:directory.appendingPathComponent("stop"),options:.atomic)
        worker=Task {
            do {
                let grant: Access
                if let access { grant=access } else {
                    let value=try await vault.read(Self.account(id),allowingInteraction:false)
                    grant=try JSONDecoder().decode(Access.self,from:Data(value.utf8))
                }
                let (_,response)=try await network.data(for:grant.request(method:"DELETE")); try check(response)
                complete(stopped:true)
            } catch { complete("已停止本机接收，未能确认服务端已停止。",stopped:true) }
        }
    }
    func close() { done=true; epoch=UUID(); worker?.cancel(); network.invalidateAndCancel() }
}
#endif
