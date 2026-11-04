import Cocoa
import Speech
import AVFoundation

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

@main struct IntegrationTerminationTests {
    @MainActor static func until(_ condition: () -> Bool) async throws {
        let deadline = ProcessInfo.processInfo.systemUptime + 3
        while !condition() && ProcessInfo.processInfo.systemUptime < deadline {
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        precondition(condition(), "lifecycle fixture timed out")
    }
    @MainActor static func main() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let blocked = root.appendingPathComponent("blocked")
        try Data().write(to: blocked)
        let review = ReviewModel(storageRoot: blocked)
        let image = NSImage(size: CGSize(width: 20, height: 20), flipped: false) { bounds in
            NSColor.white.setFill(); bounds.fill(); return true
        }
        let shot = ReviewSnapshot(id: UUID(), image: image, png: try reviewPNG(image), frame: .zero)
        let region = ReviewRegion(snapshotID: shot.id, number: 1, rect: CGRect(x: 0.1, y: 0.1, width: 0.5, height: 0.5))
        review.snapshots = [shot]; review.regions = [region]; review.selectedID = region.id
        review.active = true; review.voice.dictating = true
        let fake = FakeRecognizer()
        let recognition = MeetingRecognition(taskFactory: fake.factory)
        try recognition.start()
        recognition.append(sample(), source: .system)
        recognition.append(sample(), source: .microphone)
        let ocrRoot = root.appendingPathComponent("ocr-blocked")
        try Data().write(to: ocrRoot)
        let ocr = ScreenReader(storageRoot: ocrRoot)
        ocr.accept(ScreenReadResult(text: "Fixture OCR", image: try reviewPNG(image)),
            target: ScreenTarget(id: 42, pid: 123, app: "Fixture", bundleID: "fixture", title: "Fixture window"), region: .zero)
        ocr.text = "Edited fixture OCR"
        let recorder = Recorder(recognition: recognition, review: review, screenReader: ocr)
        recorder.recording = true
        let delegate = AppDelegate(model: recorder)
        var ocrReplies: [Bool] = []
        precondition(delegate.requestTermination(reply: { ocrReplies.append($0) }) == .terminateLater)
        try await until { !ocrReplies.isEmpty }
        precondition(ocrReplies == [false] && recorder.recording && review.active && review.voice.dictating)
        precondition(ocr.dirty && !recorder.terminationRequested && fake.cancellations == 0)
        try FileManager.default.removeItem(at: ocrRoot)
        var replies: [Bool] = []
        precondition(delegate.requestTermination(timeout: 0.05, reply: { replies.append($0) }) == .terminateLater)
        try await until { review.voice.voiceFinishing }
        precondition(replies.isEmpty && recorder.recording)
        review.voice.receiveTranscript("closing final feedback", final: true, failed: false)
        try await until { replies.count == 1 }
        precondition(replies == [false] && review.active && !recorder.terminationRequested)
        precondition(recorder.recording && fake.cancellations == 0)
        precondition(review.regions[0].feedback == "closing final feedback")
        // Fix the disk and retry through exactly the production delegate path.
        try FileManager.default.removeItem(at: blocked)
        precondition(delegate.requestTermination(timeout: 0.05, reply: { replies.append($0) }) == .terminateLater)
        precondition(delegate.requestTermination(timeout: 0.05, reply: { _ in fatalError("duplicate reply") }) == .terminateLater)
        try await until { replies.count == 2 }
        precondition(replies == [false, false] && recorder.busy && !recorder.recording)
        precondition(!recorder.terminationRequested && recognition.pending && fake.cancellations == 0)
        precondition(delegate.requestTermination(reply: { _ in fatalError("busy reply") }) == .terminateCancel)
        // No cancellation was sent to recognition when the application's wait expired.
        // Empty fake results avoid invoking Notes/AI; both accepted chunks still drain.
        fake.result(0, [])
        try await until { fake.count == 2 }
        fake.result(1, [])
        try await until { !recorder.busy }
        precondition(!recognition.pending && fake.count == 2)
        let latest = try await ReviewStore().latest(root: blocked)!
        let restored = try await ReviewStore().load(folder: latest)
        precondition(restored.session.regions[0].feedback == "closing final feedback")
        precondition(delegate.requestTermination(timeout: 0.2, reply: { replies.append($0) }) == .terminateLater)
        try await until { replies.count == 3 }
        precondition(replies == [false, false, true] && !recorder.terminationRequested && fake.count == 2)
        precondition(!ocr.dirty)
        let ocrText = try String(contentsOf: ocr.savedFile!, encoding: .utf8)
        precondition(ocrText == "Edited fixture OCR")
        // A's timeout marker/partial text survives B's final save and independent outcomes.
        let partialDriver = FakeRecognizer()
        var limits = MeetingRecognition.Limits(); limits.finalTimeout = 0.03
        let partial = MeetingRecognition(limits: limits, taskFactory: partialDriver.factory)
        try partial.start(); partial.append(sample(), source: .system)
        partialDriver.result(0, [TranscriptLine(time: 0, source: .system, text: "accepted partial")], final: false)
        partial.finish()
        try await until { !partial.pending }
        let finalText = partial.finalText()
        precondition(finalText.contains("accepted partial") && finalText.contains("转写不完整"))
        let writer = MeetingBackupWriter(), backup = root.appendingPathComponent("final.txt")
        let warning = "转写不完整：原音未保存"
        for failDisk in [false, true] {
            let saved = finishMeetingInBackground(title: "fixture", transcript: finalText, warning: warning,
                backupURL: backup, existingID: nil, analyze: false, previousAnalysis: "", previousError: "",
                exporter: { _, body, _ in
                    precondition(body.contains(finalText) && body.contains(warning))
                    return NoteReceipt(id: "fixture", name: "fixture", folder: "fixture")
                }, backupWriter: { text, url in
                    if failDisk { throw NotesFailure(detail: "fixture disk failure") }
                    try writer.writeFinal(text, to: url)
                })
            precondition(saved.presentationMessage(warning: warning).contains("转写不完整"))
            precondition(saved.localBackup.succeeded != failDisk)
            if failDisk { precondition(!saved.presentationMessage(warning: warning).contains("本地备份已保存")) }
        }
        let backedUp = try String(contentsOf: backup, encoding: .utf8)
        precondition(backedUp.contains(finalText) && backedUp.contains(warning))
        partial.cancel()
        print("PASS: recognition partial/deadline warning survives final disk/Notes fixture saves and honest disk-failure status")
        print("PASS: actual delegate + Recorder + recognition + review: voice/disk failure refuses quit; retry saves final voice; quit timeout preserves accepted drain; duplicate/busy quit does not restart stop; later quit succeeds")
    }
}
