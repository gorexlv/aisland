import Speech
import AVFoundation

enum AudioSource: String, CaseIterable {
    case system = "会议声音"
    case microphone = "我的麦克风"
}
struct TranscriptLine {
    let time: TimeInterval
    let source: AudioSource
    let text: String
}
func renderTranscript(_ lines: [TranscriptLine]) -> String {
    lines.sorted {
        if $0.time == $1.time { return $0.source.rawValue < $1.source.rawValue }
        return $0.time < $1.time
    }.map {
        let seconds = max(0, Int($0.time))
        return String(format: "[%02d:%02d] %@：%@", seconds / 60, seconds % 60, $0.source.rawValue, $0.text)
    }.joined(separator: "\n")
}
final class RecognitionChunk {
    let id = UUID()
    let source: AudioSource
    let offset: TimeInterval
    let request = SFSpeechAudioBufferRecognitionRequest()
    var task: SFSpeechRecognitionTask?
    var lines: [TranscriptLine] = []
    var done = false
    var ending = false
    var started = false
    var samples: [CMSampleBuffer] = []
    var lastVoice = Date()
    init(source: AudioSource, offset: TimeInterval) { self.source = source; self.offset = offset }
}

// All recognition state is confined to the main queue. Sources never share an audio request:
// the system and microphone can have different sample rates and independent clocks.
final class MeetingRecognition {
    private var recognizers: [AudioSource: SFSpeechRecognizer] = [:]
    private var current: [AudioSource: RecognitionChunk] = [:]
    private var active: RecognitionChunk?
    private var chunks: [RecognitionChunk] = []
    private var origin = Date()
    private var accepting = false
    private var session = UUID()
    private var lastPublish = Date.distantPast
    var onDiagnostic: ((String) -> Void)?
    private var sampleCounts: [AudioSource: Int] = [:]
    private var peaks: [AudioSource: CGFloat] = [:]
    private var lastSound: [AudioSource: Date] = [:]
    private var lastErrors: [AudioSource: String] = [:]
    private var lastStatus = Date.distantPast
    var onAudioStatus: ((String) -> Void)?
    var emptyResultReason: String {
        if sampleCounts.values.reduce(0, +) == 0 { return "没有接收到音频数据，请检查系统音频和麦克风输入。" }
        let active = AudioSource.allCases.filter { peaks[$0, default: 0] >= 0.012 }
        if active.isEmpty { return "已接入音频，但输入一直静音；请确认会议声音正在播放且麦克风未静音。" }
        let detail = active.compactMap { lastErrors[$0] }.joined(separator: "；")
        return active.map { $0.rawValue }.joined(separator: "、") + "已收到声音，但没有转写结果。" + (detail.isEmpty ? "请检查声音语言是否为中文，或再试一段清晰讲话。" : detail)
    }
    var diagnosticSummary: String {
        AudioSource.allCases.map { "\($0.rawValue): buffers=\(sampleCounts[$0, default: 0]), peak=\(peaks[$0, default: 0])" }.joined(separator: "; ") + "; chunks=\(chunks.count); errors=\(lastErrors)"
    }
    var onText: ((String) -> Void)?
    var onWarning: ((String) -> Void)?
    var onLevel: ((CGFloat) -> Void)?
    var local = false
    var pending: Bool { chunks.contains { !$0.done } }
    var pendingCount: Int { chunks.filter { !$0.done }.count }

    func start() throws {
        cancel()
        for source in AudioSource.allCases {
            guard let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "zh-CN")), recognizer.isAvailable else {
                throw NotesFailure(detail: "中文语音识别暂不可用，请检查网络或系统语音资源后重试")
            }
            recognizers[source] = recognizer
        }
        local = recognizers.values.allSatisfy { $0.supportsOnDeviceRecognition }
        sampleCounts = [:]; peaks = [:]; lastSound = [:]; lastErrors = [:]; lastStatus = .distantPast
        origin = Date(); accepting = true
    }
    func append(_ sample: CMSampleBuffer, source: AudioSource) {
        guard accepting else { return }
        let volume = audioLevel(sample)
        sampleCounts[source, default: 0] += 1
        peaks[source] = max(peaks[source, default: 0], volume)
        if volume >= 0.012 { lastSound[source] = Date() }
        if Date().timeIntervalSince(lastStatus) > 0.3 {
            lastStatus = Date()
            onAudioStatus?(AudioSource.allCases.map { source in
                let label = source == .system ? "系统声音" : "麦克风"
                let state = sampleCounts[source, default: 0] == 0 ? "未接入" : (Date().timeIntervalSince(lastSound[source] ?? .distantPast) < 1.5 ? "有声音" : "静音")
                return label + "：" + state
            }.joined(separator: "   ·   "))
        }
        onLevel?(volume)
        let elapsed = Date().timeIntervalSince(origin)
        if let chunk = current[source], elapsed - chunk.offset > 3 {
            end(chunk)
            current[source] = nil
        }
        // Silence does not continually open recognition sessions. Keep the current request
        // alive briefly so the recognizer receives trailing silence and punctuation.
        if let chunk = current[source], volume < 0.012, Date().timeIntervalSince(chunk.lastVoice) > 1.5 {
            end(chunk); current[source] = nil
        }
        if current[source] == nil, volume < 0.012 { return }
        if current[source] == nil { current[source] = makeChunk(source: source, offset: elapsed) }
        guard let chunk = current[source] else { return }
        if volume >= 0.012 { chunk.lastVoice = Date() }
        if chunk.started { chunk.request.appendAudioSampleBuffer(sample) }
        else { chunk.samples.append(sample) }
    }
    private func end(_ chunk: RecognitionChunk) {
        guard !chunk.ending else { return }
        chunk.ending = true
        if chunk.started { finishInput(chunk) }
    }
    private func finishInput(_ chunk: RecognitionChunk) {
        chunk.request.endAudio()
        DispatchQueue.main.asyncAfter(deadline: .now() + 20) { [weak self, weak chunk] in
            guard let self, let chunk, !chunk.done else { return }
            self.lastErrors[chunk.source] = "语音识别等待最终结果超时"
            chunk.done = true; chunk.task?.cancel(); chunk.task = nil
            if self.active?.id == chunk.id { self.active = nil }
            self.publish()
            self.activateNext()
        }
    }
    private func makeChunk(source: AudioSource, offset: TimeInterval) -> RecognitionChunk {
        let chunk = RecognitionChunk(source: source, offset: offset)
        chunks.append(chunk)
        onDiagnostic?("queued recognition chunk: \(source.rawValue)")
        activateNext()
        return chunk
    }
    private func activateNext() {
        guard active == nil, let chunk = chunks.first(where: { !$0.started && !$0.done }) else { return }
        active = chunk; chunk.started = true
        let source = chunk.source
        let offset = chunk.offset
        let token = session
        chunk.request.shouldReportPartialResults = true
        chunk.request.addsPunctuation = true
        chunk.request.requiresOnDeviceRecognition = local
        chunk.task = recognizers[source]?.recognitionTask(with: chunk.request) { [weak self, weak chunk] result, error in
            DispatchQueue.main.async {
                guard let self, let chunk, self.session == token, !chunk.done else { return }
                if let result {
                    chunk.lines = self.lines(result.bestTranscription, source: source, offset: offset)
                    self.publish()
                }
                if let error {
                    let failure = error as NSError
                    self.lastErrors[source] = "\(source.rawValue)：\(failure.localizedDescription)（\(failure.code)）"
                    self.onDiagnostic?("recognition error (ending=\(chunk.ending)): \(error)")
                }
                if result?.isFinal == true || error != nil {
                    chunk.done = true; chunk.task = nil
                    if self.current[source]?.id == chunk.id { self.current[source] = nil }
                    if self.active?.id == chunk.id { self.active = nil }
                    if let error = error as NSError?, self.accepting,
                       ![1110, 203, 216, 301].contains(error.code) {
                        self.onWarning?("\(source.rawValue)识别中断：\(error.localizedDescription)")
                    }
                    DispatchQueue.main.async { [weak self] in
                        guard let self, self.session == token else { return }
                        self.activateNext()
                    }
                }
            }
        }
        for sample in chunk.samples { chunk.request.appendAudioSampleBuffer(sample) }
        chunk.samples.removeAll()
        if chunk.ending { finishInput(chunk) }
    }
    private func lines(_ transcription: SFTranscription, source: AudioSource, offset: TimeInterval) -> [TranscriptLine] {
        let segments = transcription.segments
        let text = transcription.formattedString as NSString
        guard !segments.isEmpty else {
            return text.length == 0 ? [] : [TranscriptLine(time: offset, source: source, text: text as String)]
        }
        var result: [TranscriptLine] = []
        var start = 0
        for i in segments.indices {
            let next = i + 1
            let end = next < segments.count ? segments[next].substringRange.location : text.length
            let rangeStart = segments[start].substringRange.location
            guard rangeStart <= end, end <= text.length else { continue }
            let piece = text.substring(with: NSRange(location: rangeStart, length: end - rangeStart)).trimmingCharacters(in: .whitespacesAndNewlines)
            let gap = next < segments.count ? segments[next].timestamp - (segments[i].timestamp + segments[i].duration) : 0
            if next == segments.count || gap > 0.8 || piece.last.map({ "。！？.!?".contains($0) }) == true {
                if !piece.isEmpty { result.append(TranscriptLine(time: offset + segments[start].timestamp, source: source, text: piece)) }
                start = next
            }
        }
        return result
    }
    private func publish() { onText?(renderTranscript(chunks.flatMap { $0.lines })) }
    func finish() {
        accepting = false
        for chunk in chunks where !chunk.done { end(chunk) }
        current.removeAll()
    }
    func cancel() {
        session = UUID(); accepting = false
        for chunk in chunks { chunk.task?.cancel() }
        chunks.removeAll(); current.removeAll(); active = nil; recognizers.removeAll()
    }
}
