import Cocoa
import Speech
import AVFoundation

@MainActor final class VoiceInput: ObservableObject {
    @Published var draft = ""
    @Published var dictating = false
    @Published var voicePreparing = false
    @Published var voiceFinishing = false
    @Published var needsVoicePermission = false
    @Published var status = "点击麦克风录入"
    private var engine: AVAudioEngine?
    private var speechTask: SFSpeechRecognitionTask?
    private var speechRequest: SFSpeechAudioBufferRecognitionRequest?
    private var speechRecognizer: SFSpeechRecognizer?
    private var voiceToken = UUID()
    private var voicePrefix = ""
    var voiceActive: Bool { dictating || voicePreparing || voiceFinishing }
    func toggleVoice() {
        if dictating { finishVoice(cancel:false); return }
        guard !voiceActive else { return }
        voicePreparing = true; let token = UUID(); voiceToken = token
        Task {
            defer { if token == voiceToken { voicePreparing = false } }
            let mic = await AVCaptureDevice.requestAccess(for:.audio)
            let speech: SFSpeechRecognizerAuthorizationStatus = await withCheckedContinuation { continuation in
                SFSpeechRecognizer.requestAuthorization { continuation.resume(returning:$0) }
            }
            guard token == voiceToken else { return }
            guard mic, speech == .authorized else { needsVoicePermission = true; status = "请允许麦克风和语音识别权限后重试"; return }
            do {
                guard let recognizer = SFSpeechRecognizer(locale:Locale(identifier:"zh-CN")), recognizer.isAvailable else { throw NotesFailure(detail:"中文语音识别暂不可用") }
                let request = SFSpeechAudioBufferRecognitionRequest(); request.shouldReportPartialResults = true
                if recognizer.supportsOnDeviceRecognition { request.requiresOnDeviceRecognition = true }
                let engine = AVAudioEngine(); let input = engine.inputNode
                let format = input.outputFormat(forBus:0)
                guard format.sampleRate > 0, format.channelCount > 0 else { throw NotesFailure(detail:"没有可用的麦克风") }
                voicePrefix = draft.isEmpty ? "" : draft + " "
                self.engine = engine; speechRequest = request; speechRecognizer = recognizer
                input.installTap(onBus:0, bufferSize:1024, format:format) { buffer, _ in request.append(buffer) }
                speechTask = recognizer.recognitionTask(with:request) { [weak self] result, error in
                    Task { @MainActor in
                        guard let self, token == self.voiceToken else { return }
                        self.receiveTranscript(result?.bestTranscription.formattedString, final:result?.isFinal == true, failed:error != nil)
                    }
                }
                engine.prepare(); try engine.start(); dictating = true
                needsVoicePermission = false; status = "正在听…再次点击麦克风结束"
                Task { try? await Task.sleep(nanoseconds:55_000_000_000); if token == self.voiceToken && self.dictating { self.finishVoice(cancel:false) } }
            } catch { finishVoice(cancel:true); status = error.localizedDescription }
        }
    }
    // Called only after the recognition callback's session-token check.
    func receiveTranscript(_ text: String?, final: Bool, failed: Bool) {
        if let text { draft = voicePrefix + text }
        if final || failed {
            finishVoice(cancel:true)
            status = failed ? "语音识别已结束，可编辑文字后发送" : "语音已转为文字，检查后发送"
        }
    }
    /// Drain the current request before a caller changes the draft's owner.
    func finishAndWait() async {
        if voicePreparing { finishVoice(cancel:true); return }
        if dictating { finishVoice(cancel:false) }
        while voiceFinishing { try? await Task.sleep(nanoseconds:20_000_000) }
    }
    func finishVoice(cancel: Bool) {
        if let engine { engine.stop(); engine.inputNode.removeTap(onBus:0) }; engine = nil; dictating = false
        if cancel {
            voiceToken = UUID(); voicePreparing = false; voiceFinishing = false
            speechTask?.cancel(); speechTask = nil; speechRequest = nil; speechRecognizer = nil
        } else {
            voiceFinishing = true; speechRequest?.endAudio(); status = "正在完成语音输入…"
            let token = voiceToken
            Task { try? await Task.sleep(nanoseconds:2_000_000_000); if token == self.voiceToken { self.finishVoice(cancel:true); self.status = "语音已转为文字，检查后发送" } }
        }
    }
}
