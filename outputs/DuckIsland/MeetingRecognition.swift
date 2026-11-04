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
// All state belongs to a dedicated queue. Admission is synchronous so captured
// buffers cannot accumulate in a second, unbounded DispatchQueue backlog.
final class MeetingRecognition {
    struct Limits {
        var chunks = 12
        // App-retained queued PCM only; Speech/framework memory is not measured here.
        var bufferedBytes = 16 * 1024 * 1024
        var chunkDuration: TimeInterval = 3
        var finalTimeout: TimeInterval = 20
        var publishInterval: TimeInterval = 0.3
    }
    typealias ResultHandler = ([TranscriptLine]?, Bool, Error?) -> Void
    typealias TaskFactory = (SFSpeechAudioBufferRecognitionRequest, AudioSource, TimeInterval, @escaping ResultHandler) -> (() -> Void)
    private final class Chunk {
        let id = UUID()
        let source: AudioSource
        let offset: TimeInterval
        var request: SFSpeechAudioBufferRecognitionRequest?
        var cancelTask: (() -> Void)?
        var lines: [TranscriptLine] = []
        var ending = false
        var samples: [CMSampleBuffer] = []
        var bytes = 0
        var lastVoice = Date()
        init(_ source: AudioSource, _ offset: TimeInterval) { self.source = source; self.offset = offset }
    }
    private let queue = DispatchQueue(label: "duck.meeting.recognition", qos: .userInitiated)
    private let limits: Limits
    private let injectedFactory: TaskFactory?
    private var factory: TaskFactory?
    private var current: [AudioSource: Chunk] = [:]
    private var chunks: [Chunk] = []
    private var active: Chunk?
    private var completed: [TranscriptLine] = []
    private var cachedCompleted: [(line: TranscriptLine, text: String)] = []
    private var incomplete = false
    private var completedDirty = false
    private var bufferedBytes = 0
    private var origin = Date()
    private var accepting = false
    private var session = UUID()
    private var isLocal = false
    private var publishScheduled = false
    private var lastPublished = ""
    private var sampleCounts: [AudioSource: Int] = [:]
    private var peaks: [AudioSource: CGFloat] = [:]
    private var lastSound: [AudioSource: Date] = [:]
    private var lastErrors: [AudioSource: String] = [:]
    private var lastStatus = Date.distantPast
    private var lastLevel = Date.distantPast
    var onDiagnostic: ((String) -> Void)?
    var onAudioStatus: ((String) -> Void)?
    var onText: ((String) -> Void)?
    var onWarning: ((String) -> Void)?
    var onLevel: ((CGFloat) -> Void)?
    init(limits: Limits = Limits(), taskFactory: TaskFactory? = nil) {
        precondition(limits.chunks > 0 && limits.bufferedBytes > 0 && limits.finalTimeout > 0)
        self.limits = limits; injectedFactory = taskFactory
    }
    var local: Bool { queue.sync { isLocal } }
    var isIncomplete: Bool { queue.sync { incomplete } }
    var pending: Bool { pendingCount > 0 }
    var pendingCount: Int { queue.sync { chunks.count } }
    var retainedAudioBytes: Int { queue.sync { bufferedBytes } }
    var emptyResultReason: String { queue.sync {
        if sampleCounts.values.reduce(0, +) == 0 { return "没有接收到音频数据，请检查系统音频和麦克风输入。" }
        if peaks.values.allSatisfy({ $0 < 0.012 }) { return "已接入音频，但输入一直静音。" }
        return "已收到声音，但没有转写结果。" + lastErrors.values.joined(separator: "；")
    } }
    var diagnosticSummary: String { queue.sync {
        "buffers=\(sampleCounts); peak=\(peaks); pending=\(chunks.count); bufferedBytes=\(bufferedBytes); errors=\(lastErrors)"
    } }
    // Call before final persistence: delayed UI publication is not a completion barrier.
    func finalText() -> String { queue.sync { rendered() } }
    private func deliver(_ action: @escaping (MeetingRecognition) -> Void) {
        let token = session
        DispatchQueue.main.async { [weak self] in
            guard let self, self.queue.sync(execute: { self.session == token }) else { return }
            action(self)
        }
    }
    func start() throws {
        try queue.sync {
            reset()
            if let injectedFactory { factory = injectedFactory }
            else {
                var recognizers: [AudioSource: SFSpeechRecognizer] = [:]
                for source in AudioSource.allCases {
                    guard let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "zh-CN")), recognizer.isAvailable else {
                        throw NotesFailure(detail: "中文语音识别暂不可用，请检查网络或系统语音资源后重试")
                    }
                    recognizers[source] = recognizer
                }
                isLocal = recognizers.values.allSatisfy { $0.supportsOnDeviceRecognition }
                factory = { request, source, offset, receive in
                    let task = recognizers[source]!.recognitionTask(with: request) { result, error in
                        receive(result.map { Self.lines($0.bestTranscription, source: source, offset: offset) }, result?.isFinal == true, error)
                    }
                    return { task.cancel() }
                }
            }
            origin = Date(); accepting = true
        }
    }
    func append(_ sample: CMSampleBuffer, source: AudioSource) {
        queue.sync {
            guard accepting else { return }
            let now = Date(), volume = audioLevel(sample)
            sampleCounts[source, default: 0] += 1
            peaks[source] = max(peaks[source, default: 0], volume)
            if volume >= 0.012 { lastSound[source] = now }
            if now.timeIntervalSince(lastLevel) >= 0.05 {
                lastLevel = now; deliver { $0.onLevel?(volume) }
            }
            if now.timeIntervalSince(lastStatus) >= 0.3 {
                lastStatus = now
                let status = AudioSource.allCases.map { source in
                    let label = source == .system ? "系统声音" : "麦克风"
                    let state = sampleCounts[source, default: 0] == 0 ? "未接入" : (now.timeIntervalSince(lastSound[source] ?? .distantPast) < 1.5 ? "有声音" : "静音")
                    return label + "：" + state
                }.joined(separator: "   ·   ") + "   ·   待转写 \(chunks.count) 段"
                deliver { $0.onAudioStatus?(status) }
            }
            let elapsed = now.timeIntervalSince(origin)
            if let chunk = current[source], elapsed - chunk.offset > limits.chunkDuration || (volume < 0.012 && now.timeIntervalSince(chunk.lastVoice) > 1.5) {
                end(chunk); current[source] = nil
            }
            if current[source] == nil, volume < 0.012 { return }
            if current[source] == nil {
                guard chunks.count < limits.chunks else { overload(); return }
                let chunk = Chunk(source, elapsed)
                chunks.append(chunk); current[source] = chunk; activateNext()
            }
            guard let chunk = current[source] else { return }
            if volume >= 0.012 { chunk.lastVoice = now }
            if let request = chunk.request { request.appendAudioSampleBuffer(sample) }
            else {
                let size = CMSampleBufferGetTotalSampleSize(sample)
                guard size <= limits.bufferedBytes - bufferedBytes else { overload(); return }
                chunk.samples.append(sample); chunk.bytes += size; bufferedBytes += size
            }
        }
    }
    private func overload() {
        accepting = false; incomplete = true
        let warning = "转写积压达到容量上限，已停止接收新音频；正在完成已接收片段。上限之后的声音未记录，原始音频不落盘，无法恢复。"
        completed.append(TranscriptLine(time: Date().timeIntervalSince(origin), source: .system, text: "【转写不完整：积压上限之后的音频未接收，无法恢复】")); completedDirty = true
        for chunk in chunks { end(chunk) }
        current.removeAll(); deliver { $0.onWarning?(warning) }; publish()
    }
    private func end(_ chunk: Chunk) {
        guard !chunk.ending else { return }
        chunk.ending = true
        if chunk.request != nil { finishInput(chunk) }
    }
    private func finishInput(_ chunk: Chunk) {
        chunk.request?.endAudio()
        let token = session
        queue.asyncAfter(deadline: .now() + limits.finalTimeout) { [weak self, weak chunk] in
            guard let self, let chunk, self.session == token, self.active?.id == chunk.id else { return }
            self.complete(chunk, failure: "等待最终识别结果超时")
        }
    }
    private func activateNext() {
        guard active == nil, let chunk = chunks.first else { return }
        active = chunk
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true; request.addsPunctuation = true
        request.requiresOnDeviceRecognition = isLocal; chunk.request = request
        let token = session
        chunk.cancelTask = factory?(request, chunk.source, chunk.offset) { [weak self, weak chunk] lines, final, error in
            guard let self else { return }
            self.queue.async {
                guard let chunk, self.session == token, self.active?.id == chunk.id else { return }
                if let lines { chunk.lines = lines; self.publish() }
                if final || error != nil { self.complete(chunk, failure: error?.localizedDescription) }
            }
        }
        for sample in chunk.samples { request.appendAudioSampleBuffer(sample) }
        bufferedBytes -= chunk.bytes; chunk.bytes = 0; chunk.samples.removeAll()
        if chunk.ending { finishInput(chunk) }
    }
    private func complete(_ chunk: Chunk, failure: String?) {
        if let failure {
            incomplete = true
            lastErrors[chunk.source] = failure
            chunk.lines.append(TranscriptLine(time: chunk.offset, source: chunk.source,
                text: "【本片段转写不完整：\(failure)；原音未保存，无法恢复】"))
            deliver { $0.onDiagnostic?(failure) }
        }
        completed.append(contentsOf: chunk.lines); completedDirty = true
        chunk.cancelTask?(); chunk.cancelTask = nil; chunk.request = nil
        if current[chunk.source]?.id == chunk.id { current[chunk.source] = nil }
        chunks.removeAll { $0.id == chunk.id }; active = nil
        publish(); activateNext()
    }
    private func rendered() -> String {
        // Cache formatted history, but merge previews by timestamp: a later
        // completed system line can follow an earlier microphone partial.
        func precedes(_ lhs: TranscriptLine, _ rhs: TranscriptLine) -> Bool {
            lhs.time == rhs.time ? lhs.source.rawValue < rhs.source.rawValue : lhs.time < rhs.time
        }
        if completedDirty {
            cachedCompleted = completed.sorted(by: precedes).map { ($0, renderTranscript([$0])) }
            completedDirty = false
        }
        let preview = chunks.flatMap { $0.lines }.sorted(by: precedes)
        var output: [String] = [], index = 0
        for line in preview {
            while index < cachedCompleted.count && !precedes(line, cachedCompleted[index].line) {
                output.append(cachedCompleted[index].text); index += 1
            }
            output.append(renderTranscript([line]))
        }
        output.append(contentsOf: cachedCompleted[index...].map { $0.text })
        return output.joined(separator: "\n")
    }

    private func publish() {
        guard !publishScheduled else { return }
        publishScheduled = true
        let token = session
        queue.asyncAfter(deadline: .now() + limits.publishInterval) { [weak self] in
            guard let self, self.session == token else { return }
            self.publishScheduled = false
            let text = self.rendered()
            guard text != self.lastPublished else { return }
            self.lastPublished = text; self.deliver { $0.onText?(text) }
        }
    }
    func finish() { queue.sync {
        accepting = false
        for chunk in chunks { end(chunk) }
        current.removeAll()
    } }
    func cancel() { queue.sync { reset() } }
    private func reset() {
        session = UUID(); accepting = false
        for chunk in chunks { chunk.cancelTask?() }
        chunks.removeAll(); current.removeAll(); active = nil; factory = nil
        completed.removeAll(); cachedCompleted = []; completedDirty = false; incomplete = false; bufferedBytes = 0
        publishScheduled = false; lastPublished = ""; isLocal = false
        sampleCounts = [:]; peaks = [:]; lastSound = [:]; lastErrors = [:]
        lastStatus = .distantPast; lastLevel = .distantPast
    }
    private static func lines(_ transcription: SFTranscription, source: AudioSource, offset: TimeInterval) -> [TranscriptLine] {
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
}
