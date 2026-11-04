#if !APP_STORE || DEBUG
import Cocoa
import Speech
import AVFoundation

func probeSpeech(path: String) {
    guard SFSpeechRecognizer.authorizationStatus() == .authorized else {
        print("PROBE: speech permission is not authorized for this process"); exit(2)
    }
    do {
        let file = try AVAudioFile(forReading: URL(fileURLWithPath: path))
        let format = file.processingFormat
        let recognition = MeetingRecognition()
        var text = ""
        var firstSample = true
        recognition.onText = { value in text = value; print("PROBE text: \(value)") }
        recognition.onWarning = { print("PROBE warning: \($0)") }
        recognition.onDiagnostic = { print("PROBE \($0)") }
        try recognition.start()
        print("PROBE rate=\(format.sampleRate), channels=\(format.channelCount), local=\(recognition.local)")
        let frameCount = AVAudioFrameCount(format.sampleRate * 0.04)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount)!
        var frames: Int64 = 0
        let timer = Timer.scheduledTimer(withTimeInterval: 0.04, repeats: true) { timer in
            do {
                if file.framePosition >= file.length {
                    timer.invalidate(); recognition.finish()
                    DispatchQueue.main.asyncAfter(deadline: .now() + 9) {
                        print("PROBE finished. \(recognition.diagnosticSummary)")
                        let expectedSources = CommandLine.arguments.contains("--dual") ? ["会议声音：", "我的麦克风："] : ["会议声音："]
                        let passed = expectedSources.allSatisfy { text.contains($0) } && !recognition.pending
                        recognition.cancel()
                        print(passed ? "PROBE PASS" : "PROBE FAIL")
                        exit(passed ? 0 : 1)
                    }
                    return
                }
                try file.read(into: buffer, frameCount: frameCount)
                var block: CMBlockBuffer?
                let byteCount = Int(buffer.frameLength) * 4
                CMBlockBufferCreateWithMemoryBlock(allocator: kCFAllocatorDefault, memoryBlock: nil, blockLength: byteCount, blockAllocator: kCFAllocatorDefault, customBlockSource: nil, offsetToData: 0, dataLength: byteCount, flags: 0, blockBufferOut: &block)
                CMBlockBufferReplaceDataBytes(with: buffer.floatChannelData![0], blockBuffer: block!, offsetIntoDestination: 0, dataLength: byteCount)
                var asbd = AudioStreamBasicDescription(mSampleRate: format.sampleRate, mFormatID: kAudioFormatLinearPCM, mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked, mBytesPerPacket: 4, mFramesPerPacket: 1, mBytesPerFrame: 4, mChannelsPerFrame: 1, mBitsPerChannel: 32, mReserved: 0)
                var desc: CMAudioFormatDescription?
                CMAudioFormatDescriptionCreate(allocator: kCFAllocatorDefault, asbd: &asbd, layoutSize: 0, layout: nil, magicCookieSize: 0, magicCookie: nil, extensions: nil, formatDescriptionOut: &desc)
                var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: Int32(format.sampleRate)), presentationTimeStamp: CMTime(value: frames, timescale: Int32(format.sampleRate)), decodeTimeStamp: .invalid)
                var size = 4
                var sample: CMSampleBuffer?
                CMSampleBufferCreateReady(allocator: kCFAllocatorDefault, dataBuffer: block, formatDescription: desc!, sampleCount: Int(buffer.frameLength), sampleTimingEntryCount: 1, sampleTimingArray: &timing, sampleSizeEntryCount: 1, sampleSizeArray: &size, sampleBufferOut: &sample)
                frames += Int64(buffer.frameLength)
                if firstSample { print("PROBE sample ready \(sample != nil)"); firstSample = false }
                recognition.append(sample!, source: .system)
                if CommandLine.arguments.contains("--dual") { recognition.append(sample!, source: .microphone) }
            } catch { print("PROBE input error: \(error)"); exit(3) }
        }
        RunLoop.main.add(timer, forMode: .common)
        RunLoop.main.run()
    } catch { print("PROBE start error: \(error)"); exit(4) }
}

func probeCapture(path: String) {
    let recognition = MeetingRecognition()
    let capture = MeetingCapture()
    var text = ""
    var first = true
    recognition.onText = { value in text = value; print("CAPTURE text: \(value)") }
    recognition.onDiagnostic = { print("CAPTURE \($0)") }
    recognition.onWarning = { print("CAPTURE warning: \($0)") }
    capture.onSample = { sample, source in
        DispatchQueue.main.async {
            if first {
                print("CAPTURE first sample: \(String(describing: CMSampleBufferGetFormatDescription(sample))), timestamp=\(CMSampleBufferGetPresentationTimeStamp(sample).seconds)")
                first = false
            }
            recognition.append(sample, source: source)
        }
    }
    capture.onFailure = { print("CAPTURE error: \($0)") }
    Task { @MainActor in
        do {
            try recognition.start()
            try await capture.start(includeMicrophone: false, excludeOwnAudio: false)
            let player = Process()
            player.executableURL = URL(fileURLWithPath: "/usr/bin/afplay")
            player.arguments = [path]
            try player.run()
            while player.isRunning { try await Task.sleep(nanoseconds: 100_000_000) }
            try await Task.sleep(nanoseconds: 1_000_000_000)
            try await capture.stop()
            recognition.finish()
            try await Task.sleep(nanoseconds: 9_000_000_000)
            print("CAPTURE finished. \(recognition.diagnosticSummary)")
            recognition.cancel()
            exit(text.isEmpty ? 1 : 0)
        } catch { print("CAPTURE failed: \(error)"); exit(2) }
    }
    RunLoop.main.run()
}

#endif
