import Foundation
import AVFAudio
public enum SpeechMode: String, Codable, Sendable, CaseIterable { case sovits, mimo }
public struct SpeechSettings: Codable, Sendable, Equatable {
    public var mode = SpeechMode.sovits
    public var server = ""
    public var voice = ""
    public var model = "mimo-v2.5-tts"
    public var speed = 1.0
    public var director = ""
    public init() {}
}
public struct SpeechVoice: Sendable, Identifiable, Equatable { public var id: String; public var name: String }
public struct SpeechRequest: Sendable { public var url: URL; public var body: JSONValue }
public enum SpeechText {
    public static func plain(_ source: String) -> String {
        var text = VCPMarkup.parse(source).compactMap { if case .text(let s) = $0 { s } else { nil } }.joined(separator: "\n")
        for (pattern,replacement) in [("```[\\s\\S]*?(?:```|$)|~~~[\\s\\S]*?(?:~~~|$)",""),("(?i)<style\\b[\\s\\S]*?</style>|<script\\b[\\s\\S]*?</script>",""),("(?i)</?[a-z][^>]*>",""),("!\\[[^\\]]*\\]\\([^)]*\\)",""),("\\[([^\\]]+)\\]\\([^)]*\\)","$1"),("[*#_`~]","")] { text = text.replacingOccurrences(of: pattern,with: replacement,options: .regularExpression) }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    public static func segments(_ source: String) -> [String] {
        let text = plain(source); var chunks: [String] = []; var pending = ""
        for char in text { pending.append(char); if pending.count >= 800 { chunks.append(pending); pending = "" } }
        if !pending.isEmpty { chunks.append(pending) }; return chunks
    }
}
public actor SpeechClient {
    let http = VCPHTTP()
    let session: URLSession
    public init() { let config = URLSessionConfiguration.ephemeral; config.httpShouldSetCookies = false; config.urlCache = nil; config.timeoutIntervalForRequest = 60; session = URLSession(configuration: config) }
    public static let mimoVoices = ["mimo_default","冰糖","茉莉","苏打","白桦","Mia","Chloe","Milo","Dean","mimo:natural-control"].map { SpeechVoice(id: $0,name: $0 == "mimo_default" ? "默认音色" : ($0 == "mimo:natural-control" ? "自然语言导演" : $0)) }
    private static func base(_ raw: String) throws -> URL {
        guard let url = URL(string: raw.trimmingCharacters(in: .whitespacesAndNewlines)),["http","https"].contains(url.scheme),url.host != nil,url.user == nil,url.password == nil else { throw ClientError.server("请填写完整的 HTTP 或 HTTPS 语音服务地址") }; return url
    }
    public func voices(_ settings: SpeechSettings,key: String) async throws -> [SpeechVoice] {
        if settings.mode == .mimo { return Self.mimoVoices }
        let value = try await http.json(Self.base(settings.server).appendingPathComponent("models"),method: "POST",authorization: key.isEmpty ? "" : "Bearer " + key,body: .object(["version": .string("v2ProPlus")]))
        guard value["msg"].text == "获取成功", value["models"] != .null else { throw ClientError.server("语音服务未返回 VChat 兼容的音色列表") }
        var voices: [SpeechVoice] = []
        if case .array(let rows) = value["models"] { for row in rows { let id = ["voice","uri","id"].map { row[$0].text }.first(where: { !$0.isEmpty }) ?? ""; let name = ["displayName","customName","name","voice","uri","id"].map { row[$0].text }.first(where: { !$0.isEmpty }) ?? id; if !id.isEmpty { voices.append(.init(id: id,name: name)) } } }
        else { voices = value["models"].object.keys.sorted().map { .init(id: $0,name: $0) } }
        var seen: Set<String> = []; return voices.filter { seen.insert($0.id).inserted }
    }
    public static func request(_ settings: SpeechSettings,key: String,text: String,agent: VCPAgent? = nil) throws -> SpeechRequest {
        let voice = agent?.voice.isEmpty == false ? agent!.voice : settings.voice
        let speed = agent.map { $0.speechSpeedInherited ? settings.speed : $0.speechSpeed } ?? settings.speed
        let director = agent?.speechDirector.isEmpty == false ? agent!.speechDirector : settings.director
        let base = try base(settings.server)
        if settings.mode == .mimo {
            guard !key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw ClientError.server("请填写 MiMo 语音 API Key") }
            guard voice != "mimo:natural-control" || !director.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw ClientError.server("自然语言导演音色需要填写导演提示词") }
            let model = settings.model.isEmpty ? "mimo-v2.5-tts" : settings.model
            var messages: [JSONValue] = []
            if !director.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { messages.append(.object(["role": .string("user"),"content": .string(director.trimmingCharacters(in: .whitespacesAndNewlines))])) }
            messages.append(.object(["role": .string("assistant"),"content": .string(text)]))
            var audio: [String: JSONValue] = ["format": .string("pcm16")]
            if voice != "mimo:natural-control" { audio["voice"] = .string(voice.isEmpty ? "mimo_default" : voice) }
            return SpeechRequest(url: base.path.lowercased().hasSuffix("/chat/completions") ? base : base.appendingPathComponent("chat/completions"),body: .object(["model": .string(voice == "mimo:natural-control" ? model + "-voicedesign" : model),"messages": .array(messages),"audio": .object(audio),"stream": .bool(true)]))
        }
        guard !voice.isEmpty else { throw ClientError.server("先选择一个 SoVITS 音色") }
        return SpeechRequest(url: base.appendingPathComponent("v1/audio/speech"),body: .object(["model": .string("tts-v2ProPlus"),"input": .string(text),"voice": .string(voice),"response_format": .string("mp3"),"speed": .number(speed),"other_params": .object(["text_lang": .string(voice.contains("日语") ? "日语" : "中英混合"),"prompt_lang": .string(voice.contains("日语") ? "日语" : "中文"),"emotion": .string("默认"),"text_split_method": .string("按标点符号切")])]))
    }
    public func synthesize(_ settings: SpeechSettings,key: String,text: String,agent: VCPAgent? = nil) async throws -> Data {
        let call = try Self.request(settings,key: key,text: text,agent: agent)
        var request = URLRequest(url: call.url); request.httpMethod = "POST"; request.httpBody = try JSONEncoder().encode(call.body); request.setValue("application/json",forHTTPHeaderField: "Content-Type"); if !key.isEmpty { request.setValue("Bearer " + key,forHTTPHeaderField: "Authorization") }
        let (bytes,response) = try await session.bytes(for: request)
        guard let response = response as? HTTPURLResponse else { throw ClientError.invalidResponse }
        guard (200..<300).contains(response.statusCode) else { throw ClientError.http(response.statusCode) }
        let type = response.value(forHTTPHeaderField: "Content-Type") ?? ""
        guard type.hasPrefix("audio/") || type.contains("text/event-stream") else { throw ClientError.server("语音服务没有返回音频") }
        var data = Data(); for try await byte in bytes { try Task.checkCancellation(); data.append(byte); guard data.count <= 16_000_000 else { throw ClientError.server("语音超过 16 MB，请分段朗读") } }
        if settings.mode == .mimo { return try Self.mimoAudio(data,key: key) }; return data
    }
    public static func mimoAudio(_ data: Data,key: String = "") throws -> Data {
        var pcm = Data()
        for line in String(decoding: data,as: UTF8.self).components(separatedBy: .newlines) where line.hasPrefix("data:") {
            let value = line.dropFirst(5).trimmingCharacters(in: .whitespacesAndNewlines)
            if value.isEmpty || value == "[DONE]" { continue }
            guard let event = try? JSONDecoder().decode(JSONValue.self,from: Data(value.utf8)) else { continue }
            if event["error"] != .null { throw ClientError.server("MiMo 音频合成失败") }
            let encoded = event["choices"].array.first?["delta"]["audio"]["data"].text ?? ""
            if !encoded.isEmpty { guard let bytes = Data(base64Encoded: encoded) else { throw ClientError.server("MiMo 返回无效的音频编码") }; pcm.append(bytes) }
            guard pcm.count <= 16_000_000 else { throw ClientError.server("语音超过 16 MB") }
        }
        guard !pcm.isEmpty, pcm.count % 2 == 0 else { throw ClientError.server("MiMo 返回的流里没有有效音频") }
        return wav(pcm)
    }
    public static func wav(_ pcm: Data) -> Data {
        var data = Data("RIFF".utf8)
        func little<T: FixedWidthInteger>(_ value: T) -> Data { withUnsafeBytes(of: value.littleEndian) { Data($0) } }
        data += little(UInt32(36 + pcm.count)); data += Data("WAVEfmt ".utf8); data += little(UInt32(16)); data += little(UInt16(1)); data += little(UInt16(1)); data += little(UInt32(24000)); data += little(UInt32(48000)); data += little(UInt16(2)); data += little(UInt16(16)); data += Data("data".utf8); data += little(UInt32(pcm.count)); data += pcm; return data
    }
}
public struct SpeechAudioState: Sendable { public var elapsed: Double; public var duration: Double; public var phase: String }
public actor SpeechAudioEngine {
    private var player: AVAudioPlayer?
    private var owner: UUID?
    private var paused = false
    public init() {}
    public func start(_ data: Data,owner: UUID) throws {
        player?.stop(); player = nil; self.owner = owner; paused = false
        #if os(iOS)
        try AVAudioSession.sharedInstance().setCategory(.playback,mode: .spokenAudio); try AVAudioSession.sharedInstance().setActive(true)
        #endif
        let audio = try AVAudioPlayer(data: data); audio.prepareToPlay()
        guard audio.play() else { throw ClientError.server("音频无法播放，请检查输出设备") }; player = audio
    }
    public func snapshot(owner: UUID) -> SpeechAudioState {
        guard self.owner == owner, let player else { return .init(elapsed: 0,duration: 0,phase: "idle") }
        return .init(elapsed: player.currentTime,duration: player.duration,phase: paused ? "paused" : player.isPlaying ? "playing" : "ended")
    }
    public func toggle(owner: UUID) throws {
        guard self.owner == owner, let player else { return }
        if paused { guard player.play() else { throw ClientError.server("点播放重新开始朗读") }; paused = false } else { player.pause(); paused = true }
    }
    public func stop(owner: UUID) { guard self.owner == owner else { return }; player?.stop(); player = nil; self.owner = nil; paused = false
        #if os(iOS)
        try? AVAudioSession.sharedInstance().setActive(false,options: .notifyOthersOnDeactivation)
        #endif
    }
}
