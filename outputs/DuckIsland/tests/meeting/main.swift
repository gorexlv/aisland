import Cocoa
import Speech
import AVFoundation

struct NotesFailure: Error { let detail: String }
final class FakeRecognizer {
    private let lock = NSLock()
    private var handlers: [MeetingRecognition.ResultHandler] = []
    private var cancelled = 0
    var count: Int { lock.lock(); defer { lock.unlock() }; return handlers.count }
    var cancellations: Int { lock.lock(); defer { lock.unlock() }; return cancelled }
    func factory(_ request: SFSpeechAudioBufferRecognitionRequest, _ source: AudioSource,
                 _ offset: TimeInterval, _ handler: @escaping MeetingRecognition.ResultHandler) -> (() -> Void) {
        lock.lock(); handlers.append(handler); lock.unlock()
        return { self.lock.lock(); self.cancelled += 1; self.lock.unlock() }
    }
    func result(_ index: Int, _ lines: [TranscriptLine]?, final: Bool = true, error: Error? = nil) {
        lock.lock(); let handler = handlers[index]; lock.unlock()
        handler(lines, final, error)
    }
}
func pump(_ seconds: TimeInterval) { RunLoop.main.run(until: Date().addingTimeInterval(seconds)) }
func wait(_ condition: () -> Bool) {
    let deadline = Date().addingTimeInterval(2)
    while !condition() && Date() < deadline { pump(0.005) }
    precondition(condition(), "Timed out waiting for fake recognition state")
}
func sample() -> CMSampleBuffer {
    let frames = 480
    let values = [Float](repeating: 0.2, count: frames)
    var block: CMBlockBuffer?
    precondition(CMBlockBufferCreateWithMemoryBlock(allocator: kCFAllocatorDefault, memoryBlock: nil, blockLength: frames * 4,
        blockAllocator: kCFAllocatorDefault, customBlockSource: nil, offsetToData: 0, dataLength: frames * 4, flags: 0, blockBufferOut: &block) == noErr)
    values.withUnsafeBytes { bytes in
        precondition(CMBlockBufferReplaceDataBytes(with: bytes.baseAddress!, blockBuffer: block!, offsetIntoDestination: 0, dataLength: frames * 4) == noErr)
    }
    var asbd = AudioStreamBasicDescription(mSampleRate: 48000, mFormatID: kAudioFormatLinearPCM,
        mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked, mBytesPerPacket: 4, mFramesPerPacket: 1,
        mBytesPerFrame: 4, mChannelsPerFrame: 1, mBitsPerChannel: 32, mReserved: 0)
    var desc: CMAudioFormatDescription?
    precondition(CMAudioFormatDescriptionCreate(allocator: kCFAllocatorDefault, asbd: &asbd, layoutSize: 0, layout: nil,
        magicCookieSize: 0, magicCookie: nil, extensions: nil, formatDescriptionOut: &desc) == noErr)
    var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: 48000), presentationTimeStamp: .zero, decodeTimeStamp: .invalid)
    var size = 4, buffer: CMSampleBuffer?
    precondition(CMSampleBufferCreateReady(allocator: kCFAllocatorDefault, dataBuffer: block, formatDescription: desc!, sampleCount: frames,
        sampleTimingEntryCount: 1, sampleTimingArray: &timing, sampleSizeEntryCount: 1, sampleSizeArray: &size, sampleBufferOut: &buffer) == noErr)
    return buffer!
}
let audio = sample()
let sampleBytes = CMSampleBufferGetTotalSampleSize(audio)
precondition(sampleBytes == 1920)

// Slow recognizer: a dual-source queue reaches its exact count limit, refuses new
// audio, reports the gap once, then drains every accepted chunk in order.
do {
    let fake = FakeRecognizer()
    var limits = MeetingRecognition.Limits(); limits.chunks = 2; limits.chunkDuration = 0.01; limits.publishInterval = 0.005
    let recognition = MeetingRecognition(limits: limits, taskFactory: fake.factory)
    var warnings: [String] = []
    recognition.onWarning = { precondition(Thread.isMainThread); warnings.append($0) }
    try recognition.start()
    recognition.append(audio, source: .system); recognition.append(audio, source: .microphone)
    precondition(recognition.pendingCount == 2 && recognition.retainedAudioBytes == sampleBytes && fake.count == 1)
    pump(0.02); recognition.append(audio, source: .system)
    for _ in 0..<1000 { recognition.append(audio, source: .system) }
    precondition(recognition.pendingCount == 2 && recognition.retainedAudioBytes == sampleBytes)
    wait { warnings.count == 1 }; precondition(warnings[0].contains("停止") && warnings[0].contains("无法恢复"))
    recognition.finish()
    fake.result(0, [TranscriptLine(time: 0, source: .system, text: "第一句")])
    wait { fake.count == 2 }; precondition(recognition.retainedAudioBytes == 0)
    fake.result(1, [TranscriptLine(time: 0.001, source: .microphone, text: "尾句")])
    wait { !recognition.pending }
    let text = recognition.finalText()
    precondition(text.contains("第一句") && text.contains("尾句") && text.contains("转写不完整"))
    precondition(text.range(of: "第一句")!.lowerBound < text.range(of: "尾句")!.lowerBound)
    recognition.cancel()
    print("PASS bounded slow dual-source queue, visible overload, accepted tail drain")
}
// Byte budget is independent of the chunk budget and admits the exact boundary.
do {
    let fake = FakeRecognizer()
    var limits = MeetingRecognition.Limits(); limits.bufferedBytes = sampleBytes
    let recognition = MeetingRecognition(limits: limits, taskFactory: fake.factory)
    try recognition.start(); recognition.append(audio, source: .system); recognition.append(audio, source: .microphone)
    precondition(recognition.retainedAudioBytes == sampleBytes)
    recognition.append(audio, source: .microphone)
    precondition(recognition.retainedAudioBytes == sampleBytes && recognition.pendingCount == 2)
    precondition(recognition.finalText().contains("积压上限"))
    recognition.cancel(); precondition(recognition.retainedAudioBytes == 0)
    print("PASS exact byte limit, rejected overflow, cancellation releases retained samples")
}
// Each ended chunk has its own deadline; a stalled driver cannot block the queue.
do {
    let fake = FakeRecognizer()
    var limits = MeetingRecognition.Limits(); limits.finalTimeout = 0.03
    let recognition = MeetingRecognition(limits: limits, taskFactory: fake.factory)
    try recognition.start(); recognition.append(audio, source: .system); recognition.append(audio, source: .microphone)
    fake.result(0, [TranscriptLine(time: 0, source: .system, text: "保留部分文字")], final: false)
    let start = Date(); recognition.finish(); wait { !recognition.pending }
    precondition(Date().timeIntervalSince(start) < 0.5 && fake.count == 2 && fake.cancellations == 2)
    precondition(recognition.finalText().contains("保留部分文字"))
    precondition(recognition.finalText().components(separatedBy: "本片段转写不完整").count == 3)
    recognition.append(audio, source: .system); precondition(!recognition.pending)
    recognition.cancel()
    print("PASS bounded stop deadlines, partial preservation, timeout markers, no append after stop")
}
// Errors do not discard partial text; delayed old results/publications cannot
// cross cancellation/restart, and finalText does not wait for a UI timer.
do {
    let fake = FakeRecognizer()
    var limits = MeetingRecognition.Limits(); limits.publishInterval = 0.02
    let recognition = MeetingRecognition(limits: limits, taskFactory: fake.factory)
    var publications: [String] = []
    recognition.onText = { precondition(Thread.isMainThread); publications.append($0) }
    try recognition.start(); recognition.append(audio, source: .system)
    fake.result(0, [TranscriptLine(time: 0, source: .system, text: "旧会话")], final: false)
    _ = recognition.finalText() // barrier after fake callback
    recognition.cancel(); try recognition.start(); recognition.append(audio, source: .system)
    fake.result(0, [TranscriptLine(time: 0, source: .system, text: "过期回调")])
    fake.result(1, [TranscriptLine(time: 0, source: .system, text: "新会话尾句")], final: false)
    fake.result(1, nil, final: false, error: NSError(domain: "fake", code: 1))
    wait { !recognition.pending }
    precondition(recognition.finalText().contains("新会话尾句") && recognition.finalText().contains("转写不完整"))
    precondition(!recognition.finalText().contains("旧会话") && !recognition.finalText().contains("过期回调"))
    // A RunLoop time slice is not a DispatchQueue delivery barrier on headless runners.
    // Wait for the callback; retain the exact-count/content assertions below.
    wait { !publications.isEmpty }
    precondition(publications.count == 1 && publications[0].contains("新会话尾句"), "Expected one current-session publication, got: \(publications)")
    recognition.cancel(); precondition(recognition.finalText().isEmpty)
    print("PASS error partials, stale-result/session suppression, coalesced publication, final flush")
}
// Completed source A may contain later timestamps than source B's preview.
do {
    let fake = FakeRecognizer()
    let recognition = MeetingRecognition(taskFactory: fake.factory)
    try recognition.start()
    recognition.append(audio, source: .system); recognition.append(audio, source: .microphone)
    fake.result(0, [TranscriptLine(time: 2, source: .system, text: "系统稍后"),
                    TranscriptLine(time: 0, source: .system, text: "系统最早")])
    wait { fake.count == 2 }
    fake.result(1, [TranscriptLine(time: 1, source: .microphone, text: "麦克风中间")], final: false)
    let preview = recognition.finalText()
    precondition(preview.range(of: "系统最早")!.lowerBound < preview.range(of: "麦克风中间")!.lowerBound)
    precondition(preview.range(of: "麦克风中间")!.lowerBound < preview.range(of: "系统稍后")!.lowerBound)
    // A late callback from a completed chunk must not alter the active chunk.
    fake.result(0, [TranscriptLine(time: 0, source: .system, text: "失效片段")])
    recognition.finish()
    fake.result(1, [TranscriptLine(time: 1, source: .microphone, text: "麦克风中间")])
    wait { !recognition.pending }
    precondition(recognition.finalText() == preview && !recognition.isIncomplete)
    recognition.cancel()
    print("PASS dual-source chronological preview/final merge, stale completed-chunk callback")
}
print("Meeting recognition deterministic checks passed; no real recognizer/capture/Notes/AI was invoked")
