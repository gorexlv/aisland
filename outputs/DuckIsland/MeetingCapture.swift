import Cocoa
import ScreenCaptureKit
import AVFoundation

// Capture system output before the hardware output route, plus the current default microphone.
// No screen output is attached and no video frames are retained.
final class MeetingCapture: NSObject, SCStreamOutput, SCStreamDelegate {
    private var stream: SCStream?
    private let queue = DispatchQueue(label: "duck.meeting.audio", qos: .userInitiated)
    var onSample: ((CMSampleBuffer, AudioSource) -> Void)?
    var onFailure: ((Error) -> Void)?

    func start(includeMicrophone: Bool = true, excludeOwnAudio: Bool = false) async throws {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        guard let display = content.displays.first else { throw NotesFailure(detail: "没有可用的显示器音频源") }
        let filter = SCContentFilter(display: display, excludingApplications: [], exceptingWindows: [])
        let config = SCStreamConfiguration()
        config.width = 2; config.height = 2
        config.minimumFrameInterval = CMTime(seconds: 1, preferredTimescale: 1)
        config.showsCursor = false
        config.capturesAudio = true
        config.excludesCurrentProcessAudio = excludeOwnAudio
        config.sampleRate = 48000
        config.channelCount = 1
        config.captureMicrophone = includeMicrophone
        let stream = SCStream(filter: filter, configuration: config, delegate: self)
        try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: queue)
        if includeMicrophone { try stream.addStreamOutput(self, type: .microphone, sampleHandlerQueue: queue) }
        self.stream = stream
        do { try await stream.startCapture() }
        catch { self.stream = nil; throw error }
    }
    func stop() async throws {
        let active = stream
        stream = nil
        try await active?.stopCapture()
        await withCheckedContinuation { continuation in queue.async { continuation.resume() } }
    }
    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard CMSampleBufferDataIsReady(sampleBuffer), CMSampleBufferGetNumSamples(sampleBuffer) > 0 else { return }
        guard type == .audio || type == .microphone else { return }
        onSample?(sampleBuffer, type == .audio ? .system : .microphone)
    }
    func stream(_ stream: SCStream, didStopWithError error: Error) { onFailure?(error) }
}

func audioLevel(_ sample: CMSampleBuffer) -> CGFloat {
    guard let desc = CMSampleBufferGetFormatDescription(sample),
          let format = CMAudioFormatDescriptionGetStreamBasicDescription(desc)?.pointee,
          format.mFormatID == kAudioFormatLinearPCM else { return 0 }
    var size = 0
    CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(sample, bufferListSizeNeededOut: &size, bufferListOut: nil, bufferListSize: 0, blockBufferAllocator: nil, blockBufferMemoryAllocator: nil, flags: 0, blockBufferOut: nil)
    guard size > 0 else { return 0 }
    let memory = UnsafeMutableRawPointer.allocate(byteCount: size, alignment: MemoryLayout<AudioBufferList>.alignment)
    defer { memory.deallocate() }
    let list = memory.bindMemory(to: AudioBufferList.self, capacity: 1)
    var block: CMBlockBuffer?
    guard CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(sample, bufferListSizeNeededOut: nil, bufferListOut: list, bufferListSize: size, blockBufferAllocator: nil, blockBufferMemoryAllocator: nil, flags: 0, blockBufferOut: &block) == noErr else { return 0 }
    var sum: Float = 0
    var count = 0
    for buffer in UnsafeMutableAudioBufferListPointer(list) {
        guard let data = buffer.mData else { continue }
        if format.mFormatFlags & kAudioFormatFlagIsFloat != 0, format.mBitsPerChannel == 32 {
            let values = data.assumingMemoryBound(to: Float.self)
            let length = Int(buffer.mDataByteSize) / 4
            for i in stride(from: 0, to: length, by: 8) { sum += values[i] * values[i]; count += 1 }
        } else if format.mBitsPerChannel == 16 {
            let values = data.assumingMemoryBound(to: Int16.self)
            let length = Int(buffer.mDataByteSize) / 2
            for i in stride(from: 0, to: length, by: 8) { let value = Float(values[i]) / 32768; sum += value * value; count += 1 }
        }
    }
    return count == 0 ? 0 : CGFloat(min(1, sqrt(sum / Float(count)) * 12))
}
