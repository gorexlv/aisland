import Cocoa
import Speech
import AVFoundation

struct VoiceTranscriptEntry: Codable, Identifiable, Equatable {
    var id = UUID()
    let recordedAt: Date
    let text: String
}
struct VoiceTimedToken {
    let range: NSRange
    let offset: TimeInterval
}
func timedVoiceTranscript(_ text:String,tokens:[VoiceTimedToken],startedAt:Date) -> [VoiceTranscriptEntry] {
    let source = text as NSString
    var result:[VoiceTranscriptEntry] = []
    var group:[VoiceTimedToken] = []
    func appendGroup() {
        guard let first = group.first, let last = group.last else { return }
        let range = NSRange(location:first.range.location,length:NSMaxRange(last.range)-first.range.location)
        result.append(VoiceTranscriptEntry(recordedAt:startedAt.addingTimeInterval(first.offset),text:source.substring(with:range)))
    }
    for token in tokens where token.range.location != NSNotFound && token.range.location >= 0 && token.range.length >= 0 && token.range.location <= source.length && token.range.length <= source.length-token.range.location && token.offset.isFinite && token.offset >= 0 {
        if let first = group.first, token.offset-first.offset >= 3 { appendGroup(); group = [] }
        if let last = group.last, token.range.location < last.range.location { continue }
        group.append(token)
    }
    appendGroup()
    return result
}

struct VoiceInputDevice: Identifiable {
    let id: String
    let name: String
}
func voiceCaptureDevice(_ id:String?) -> AVCaptureDevice? {
    if let id { return AVCaptureDevice.devices(for:.audio).first(where:{$0.uniqueID == id}) }
    return AVCaptureDevice.default(for:.audio)
}

// All microphone start/stop and sample delivery run on one queue, independent of output routing.
final class VoiceMicrophoneCapture: NSObject, AVCaptureAudioDataOutputSampleBufferDelegate, @unchecked Sendable {
    private static let queue = DispatchQueue(label:"mo.review.microphone")
    private var session: AVCaptureSession?
    private var output: AVCaptureAudioDataOutput?
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var level: (@Sendable (CGFloat)->Void)?
    private var failure: (@Sendable (String)->Void)?
    private var errorObserver: NSObjectProtocol?
    func start(request:SFSpeechAudioBufferRecognitionRequest,deviceID:String?,level:@escaping @Sendable (CGFloat)->Void,failure:@escaping @Sendable (String)->Void) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            Self.queue.async {
                do {
                    guard let device = voiceCaptureDevice(deviceID) else { throw NotesFailure(detail:"选定的麦克风不可用，请重新选择输入设备") }
                    let input = try AVCaptureDeviceInput(device:device)
                    let session = AVCaptureSession(), output = AVCaptureAudioDataOutput()
                    session.beginConfiguration()
                    guard session.canAddInput(input), session.canAddOutput(output) else {
                        session.commitConfiguration(); throw NotesFailure(detail:"无法使用默认麦克风："+device.localizedName)
                    }
                    session.addInput(input); session.addOutput(output); session.commitConfiguration()
                    self.request = request; self.level = level; self.failure = failure
                    self.session = session; self.output = output
                    output.setSampleBufferDelegate(self,queue:Self.queue)
                    self.errorObserver = NotificationCenter.default.addObserver(forName:AVCaptureSession.runtimeErrorNotification,object:session,queue:nil) { notification in
                        let message = (notification.userInfo?[AVCaptureSessionErrorKey] as? NSError)?.localizedDescription ?? "麦克风采集会话失败"
                        failure(message)
                    }
                    session.startRunning()
                    guard session.isRunning else { throw NotesFailure(detail:"默认麦克风启动失败："+device.localizedName) }
                    continuation.resume(returning:device.localizedName)
                } catch {
                    self.stopOnQueue(); continuation.resume(throwing:error)
                }
            }
        }
    }
    func captureOutput(_ output:AVCaptureOutput,didOutput sample:CMSampleBuffer,from connection:AVCaptureConnection) {
        guard CMSampleBufferDataIsReady(sample), CMSampleBufferGetNumSamples(sample) > 0 else { return }
        request?.appendAudioSampleBuffer(sample); level?(audioLevel(sample))
    }
    func stop(completion:@escaping @Sendable ()->Void = {}) {
        Self.queue.async { self.stopOnQueue(); completion() }
    }
    private func stopOnQueue() {
        output?.setSampleBufferDelegate(nil,queue:nil)
        session?.stopRunning()
        if let errorObserver { NotificationCenter.default.removeObserver(errorObserver) }
        errorObserver = nil; output = nil; session = nil; request = nil; level = nil; failure = nil
    }
}

@MainActor final class VoiceInput: ObservableObject {
    @Published var unavailableReason: String?
    @Published var draft = ""
    private(set) var draftID = UUID()
    @Published var timedTranscript: [VoiceTranscriptEntry] = []
    @Published var dictating = false
    @Published var inputLevel: CGFloat = 0
    @Published var voicePreparing = false
    @Published var voiceFinishing = false
    @Published var needsVoicePermission = false
    @Published var status = "点击麦克风录入"
    @Published var inputDeviceName = "系统默认输入"
    @Published private(set) var selectedInputID: String? = UserDefaults.standard.string(forKey:"ReviewInputDeviceID")
    @Published var inputDevices: [VoiceInputDevice] = []
    func refreshInputDevices() {
        inputDevices = AVCaptureDevice.devices(for:.audio).map { VoiceInputDevice(id:$0.uniqueID,name:$0.localizedName) }
        if !voiceActive { inputDeviceName = voiceCaptureDevice(selectedInputID)?.localizedName ?? "输入设备不可用" }
    }
    func setInputDevice(_ id:String?) throws {
        guard !voiceActive else { throw NotesFailure(detail:"请等待录音收尾") }
        guard let device = voiceCaptureDevice(id) else { throw NotesFailure(detail:"输入设备已断开") }
        selectedInputID = id
        UserDefaults.standard.set(id,forKey:"ReviewInputDeviceID")
        inputDeviceName = device.localizedName; lastError = nil
    }
    @Published var hasAudioInput = false
    @Published var lastError: String?
    private var microphone: VoiceMicrophoneCapture?
    private var speechTask: SFSpeechRecognitionTask?
    private var speechRequest: SFSpeechAudioBufferRecognitionRequest?
    private var speechRecognizer: SFSpeechRecognizer?
    private var voiceToken = UUID()
    private var voicePrefix = ""
    private var timingPrefix: [VoiceTranscriptEntry] = []
    private var voiceStartedAt: Date?
    var voiceActive: Bool { dictating || voicePreparing || voiceFinishing }
    func loadDraft(_ text:String,transcript:[VoiceTranscriptEntry] = []) {
        draftID = UUID()
        draft = text; timedTranscript = transcript; timingPrefix = transcript
        voiceStartedAt = nil; voicePrefix = ""
    }
    func prepareRecognitionDraft(startedAt:Date = Date()) {
        voicePrefix = draft.isEmpty ? "" : draft + " "
        timingPrefix = timedTranscript; voiceStartedAt = startedAt
    }
    func toggleVoice() {
        guard unavailableReason == nil else { status = unavailableReason!; return }
        if dictating { finishVoice(cancel:false); return }
        guard !voiceActive else { return }
        draftID = UUID()
        lastError = nil; hasAudioInput = false
        inputDeviceName = voiceCaptureDevice(selectedInputID)?.localizedName ?? "输入设备不可用"
        voicePreparing = true; let token = UUID(); voiceToken = token
        Task {
            defer { if token == voiceToken { voicePreparing = false } }
            let mic = await AVCaptureDevice.requestAccess(for:.audio)
            let speech: SFSpeechRecognizerAuthorizationStatus = await withCheckedContinuation { continuation in
                SFSpeechRecognizer.requestAuthorization { continuation.resume(returning:$0) }
            }
            guard token == voiceToken else { return }
            guard mic, speech == .authorized else { needsVoicePermission = true; status = "请允许麦克风和语音识别权限后重试"; lastError = status; return }
            do {
                guard let recognizer = SFSpeechRecognizer(locale:Locale(identifier:"zh-CN")), recognizer.isAvailable else { throw NotesFailure(detail:"中文语音识别暂不可用") }
                let request = SFSpeechAudioBufferRecognitionRequest(); request.shouldReportPartialResults = true
                if recognizer.supportsOnDeviceRecognition { request.requiresOnDeviceRecognition = true }
                prepareRecognitionDraft()
                speechRequest = request; speechRecognizer = recognizer
                speechTask = recognizer.recognitionTask(with:request) { [weak self] result, error in
                    Task { @MainActor in
                        guard let self, token == self.voiceToken else { return }
                        let transcription = result?.bestTranscription
                        let timings = transcription.flatMap { transcription in
                            self.voiceStartedAt.map { startedAt in
                                timedVoiceTranscript(transcription.formattedString,tokens:transcription.segments.map { VoiceTimedToken(range:$0.substringRange,offset:$0.timestamp) },startedAt:startedAt)
                            }
                        }
                        self.receiveTranscript(transcription?.formattedString, final:result?.isFinal == true, failed:error != nil, timings:timings, errorDescription:error?.localizedDescription)
                    }
                }
                let microphone = VoiceMicrophoneCapture(); self.microphone = microphone
                let deviceName = try await microphone.start(request:request,deviceID:selectedInputID,level:{ [weak self] level in
                    Task { @MainActor [weak self] in
                        guard let self, token == self.voiceToken, self.voiceActive else { return }
                        self.inputLevel = level; self.hasAudioInput = true
                    }
                },failure:{ [weak self] message in
                    Task { @MainActor [weak self] in
                        guard let self, token == self.voiceToken else { return }
                        self.finishVoice(cancel:true); self.lastError = message; self.status = "录音失败："+message
                    }
                })
                guard token == voiceToken else { microphone.stop(); return }
                inputDeviceName = deviceName; dictating = true
                needsVoicePermission = false; status = "正在录音 · \(deviceName)"
                Task {
                    try? await Task.sleep(nanoseconds:4_000_000_000)
                    if token == self.voiceToken && self.dictating && !self.hasAudioInput {
                        self.status = "未收到音频 · \(self.inputDeviceName)，请检查系统输入设备"
                    }
                }
                Task { try? await Task.sleep(nanoseconds:55_000_000_000); if token == self.voiceToken && self.dictating { self.finishVoice(cancel:false) } }
            } catch {
                guard token == voiceToken else { return }
                finishVoice(cancel:true); lastError = error.localizedDescription; status = "录音失败："+error.localizedDescription
            }
        }
    }
    // Called only after the recognition callback's session-token check.
    func receiveTranscript(_ text: String?, final: Bool, failed: Bool, timings:[VoiceTranscriptEntry]? = nil, errorDescription:String? = nil) {
        // Speech may emit an empty final/error callback after valid partial results.
        // Such a callback must not erase the text already accepted for this opinion.
        let recognized = text?.trimmingCharacters(in:.whitespacesAndNewlines)
        let segmentText = timings?.map(\.text).joined(separator:" ").trimmingCharacters(in:.whitespacesAndNewlines)
        if let text = (recognized?.isEmpty == false ? text : segmentText), !text.isEmpty {
            draft = voicePrefix + text
        }
        if let timings, !timings.isEmpty { timedTranscript = timingPrefix + timings }
        if final || failed {
            finishVoice(cancel:true)
            if failed { lastError = errorDescription ?? "语音识别失败" }
            status = failed ? "语音识别失败：\(lastError ?? "未知错误")" : "语音已转为文字，检查后发送"
        }
    }
    /// Drain the current request before a caller changes the draft's owner.
    func finishAndWait() async {
        if voicePreparing { finishVoice(cancel:true); return }
        if dictating { finishVoice(cancel:false) }
        while voiceFinishing { try? await Task.sleep(nanoseconds:20_000_000) }
    }
    func finishVoice(cancel: Bool) {
        let microphone = self.microphone; self.microphone = nil
        dictating = false; inputLevel = 0
        if cancel {
            microphone?.stop()
            voiceToken = UUID(); voicePreparing = false; voiceFinishing = false
            speechTask?.cancel(); speechTask = nil; speechRequest = nil; speechRecognizer = nil
        } else {
            voiceFinishing = true; status = "正在完成语音输入…"
            let token = voiceToken
            let endAudio: @Sendable ()->Void = { [weak self] in
                Task { @MainActor [weak self] in
                    guard let self, token == self.voiceToken else { return }
                    self.speechRequest?.endAudio()
                    Task {
                        try? await Task.sleep(nanoseconds:2_000_000_000)
                        if token == self.voiceToken { self.finishVoice(cancel:true); self.status = "录音已结束" }
                    }
                }
            }
            if let microphone { microphone.stop(completion:endAudio) } else { endAudio() }
        }
    }
}

// Read PCM synchronously while the audio callback owns the buffer.
func voiceInputLevel(_ buffer: AVAudioPCMBuffer) -> CGFloat {
    guard let samples = buffer.floatChannelData?[0], buffer.frameLength > 0 else { return 0 }
    var sum: Float = 0
    let stride = buffer.stride
    for index in 0..<Int(buffer.frameLength) {
        let value = samples[index*stride]
        sum += value*value
    }
    return min(1,CGFloat(sqrt(sum/Float(buffer.frameLength)))*12)
}
