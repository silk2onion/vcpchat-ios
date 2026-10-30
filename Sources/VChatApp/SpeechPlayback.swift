import Foundation
import Observation
import VChatCore
@MainActor @Observable final class SpeechPlayback {
    var voices: [SpeechVoice] = []
    var phase = "idle"
    var speaker = ""
    var messageID = ""
    var elapsed = 0.0
    var duration = 0.0
    var segment = 0
    var totalSegments = 0
    var error: String?
    @ObservationIgnored let client = SpeechClient()
    @ObservationIgnored let engine = SpeechAudioEngine()
    @ObservationIgnored private var generation = UUID()
    @ObservationIgnored private var task: Task<Void,Never>?
    func refresh(_ settings: SpeechSettings,key: String) async throws { voices = try await client.voices(settings,key: key) }
    func stop() {
        let old = generation; generation = UUID(); task?.cancel(); task = nil
        Task { await engine.stop(owner: old) }
        phase = "idle"; messageID = ""; elapsed = 0; duration = 0; error = nil
    }
    func toggle() { let owner = generation; Task { do { try await engine.toggle(owner: owner) } catch { self.error = error.localizedDescription } } }
    func read(id: String,content: String,settings: SpeechSettings,key: String,agent: VCPAgent?) {
        stop(); let owner = generation
        messageID = id; speaker = agent?.name ?? "语音试听"; phase = "loading"
        task = Task {
            let chunks = await Task.detached { SpeechText.segments(content) }.value
            guard generation == owner else { return }
            guard !chunks.isEmpty else { phase = "error"; error = "这条消息没有可朗读的正文"; return }
            totalSegments = chunks.count
            do {
                for (index,text) in chunks.enumerated() {
                    try Task.checkCancellation(); segment = index + 1; phase = "loading"; elapsed = 0; duration = 0
                    let data = try await client.synthesize(settings,key: key,text: text,agent: agent)
                    try Task.checkCancellation(); guard generation == owner else { return }
                    try await engine.start(data,owner: owner)
                    while !Task.isCancelled {
                        let state = await engine.snapshot(owner: owner)
                        guard generation == owner else { return }
                        elapsed = state.elapsed; duration = state.duration
                        if state.phase == "ended" || state.phase == "idle" { break }
                        phase = state.phase; try await Task.sleep(for: .milliseconds(120))
                    }
                }
                if generation == owner { await engine.stop(owner: owner); phase = "idle"; messageID = "" }
            } catch {
                await engine.stop(owner: owner)
                if generation == owner && !Task.isCancelled { phase = "error"; self.error = (error as? ClientError)?.localizedDescription ?? "音频无法合成或播放，请检查语音连接与音频格式" }
            }
        }
    }
}
