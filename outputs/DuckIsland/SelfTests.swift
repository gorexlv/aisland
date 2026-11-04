#if !APP_STORE || DEBUG
import Cocoa
import AVFoundation

func runMeetingTests() {
    let transcript = renderTranscript([
        TranscriptLine(time: 10.2, source: .microphone, text: "收到。"),
        TranscriptLine(time: 2.1, source: .system, text: "我们开始开会。")
    ])
    assert(transcript == "[00:02] 会议声音：我们开始开会。\n[00:10] 我的麦克风：收到。")
    assert(htmlEscape("<b>&\"") == "&lt;b&gt;&amp;&quot;")
    let script = NSAppleScript(source: notesScript(title: "会议 \"标题\"", text: "引号\"、反斜杠\\、换行\n</div><script>test</script>"))!
    var scriptError: NSDictionary?
    assert(script.compileAndReturnError(&scriptError), "Notes script compilation failed: \(String(describing: scriptError))")

    let update = NSAppleScript(source: notesScript(title: "会议", text: "更新总结", existingID: "x-coredata://test/ICNote/p1"))!
    var updateError: NSDictionary?
    assert(update.compileAndReturnError(&updateError), "Notes update script compilation failed")

    assert(!notesScript(title: "会议", text: "原文").contains("show meetingNote"))
    let backup = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: backup) }
    #if APP_STORE
    assert(NSHomeDirectory().contains("/Containers/"), "Store self-tests must run inside App Sandbox")
    let helper = Process()
    helper.executableURL = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/NotesHelper")
    let helperInput = Pipe(), helperOutput = Pipe()
    helper.standardInput = helperInput; helper.standardOutput = helperOutput
    try! helper.run()
    helperInput.fileHandleForWriting.write(Data("invalid-json".utf8))
    try! helperInput.fileHandleForWriting.close()
    let helperResult = helperOutput.fileHandleForReading.readDataToEndOfFile()
    helper.waitUntilExit()
    assert(helper.terminationStatus == 1)
    assert((try! JSONDecoder().decode(NotesWorkerResponse.self,from:helperResult)).error != nil)
    print("Store sandbox and inherited helper checks passed")
    let basic = finishMeetingInBackground(title:"基础版",transcript:"原文",warning:"",backupURL:backup,
        existingID:nil,analyze:true,previousAnalysis:"旧总结",previousError:"旧错误",
        analyzer:{ _ in fatalError("Store build must never invoke AI") },
        exporter:{ title,body,_ in
            assert(body.contains("原文") && !body.contains("总结") && !body.contains("旧错误"))
            return NoteReceipt(id:"basic",name:title,folder:"备忘录")
        })
    assert(basic.analysis.isEmpty && basic.analysisError.isEmpty && basic.receipt != nil)
    #else
    let saved = finishMeetingInBackground(title: "会议 A", transcript: "原文 A", warning: "", backupURL: backup,
        existingID: "existing", analyze: true, previousAnalysis: "", previousError: "",
        analyzer: { text in assert(text == "原文 A"); return "总结 A 和 tickets" },
        exporter: { title, body, id in
            assert(title == "会议 A" && body.contains("原文 A") && body.contains("总结 A 和 tickets") && id == "existing")
            assert((try? String(contentsOf: backup, encoding: .utf8))?.contains(body) == true)
            return NoteReceipt(id: "existing", name: title, folder: "备忘录")
        })
    assert(saved.receipt?.name == "会议 A" && saved.error == nil)
    let fallback = finishMeetingInBackground(title: "会议 B", transcript: "原文 B", warning: "", backupURL: backup,
        existingID: nil, analyze: true, previousAnalysis: "", previousError: "",
        analyzer: { _ in throw NotesFailure(detail: "分析不可用") },
        exporter: { title, body, _ in
            assert(body.contains("原文 B") && body.contains("分析不可用") && !body.contains("原文 A"))
            return NoteReceipt(id: "B", name: title, folder: "备忘录")
        })
    assert(fallback.receipt != nil && !fallback.analysisError.isEmpty)
    #endif
    let failed = finishMeetingInBackground(title: "会议 C", transcript: "原文 C", warning: "", backupURL: backup,
        existingID: nil, analyze: false, previousAnalysis: "总结", previousError: "",
        analyzer: { _ in fatalError("Retry save must not rerun analysis") },
        exporter: { _, _, _ in throw NotesFailure(detail: "保存失败") })
    assert(failed.receipt == nil && failed.error == "保存失败")
    assert((try? String(contentsOf: backup, encoding: .utf8))?.contains("原文 C") == true)
    let ocrImage = NSImage(size:NSSize(width:900,height:400),flipped:false) { bounds in
        NSColor.white.setFill(); bounds.fill()
        let attributes: [NSAttributedString.Key:Any] = [.font:NSFont.systemFont(ofSize:32),.foregroundColor:NSColor.black]
        ("KEEP2026 中文读取" as NSString).draw(at:NSPoint(x:25,y:290),withAttributes:attributes)
        ("OUTSIDE9999" as NSString).draw(at:NSPoint(x:520,y:290),withAttributes:attributes)
        ("BOTTOM8888" as NSString).draw(at:NSPoint(x:25,y:70),withAttributes:attributes)
        return true
    }
    let ocrData = try! reviewPNG(ocrImage)
    let ocrRegion = CGRect(x:0,y:0,width:0.5,height:0.5)
    let ocr = try! recognizeScreenRegion(png:ocrData,region:ocrRegion)
    assert(ocr.text.contains("2026") && ocr.text.contains("中文"), "Must recognize mixed Chinese/English in selected region: " + ocr.text)
    assert(!ocr.text.contains("9999") && !ocr.text.contains("8888"), "Must not recognize unselected content")
    let croppedOCR = NSBitmapImageRep(data:ocr.image)!
    assert(croppedOCR.pixelsWide == 450 && croppedOCR.pixelsHigh == 200)
    let ocrFolder = FileManager.default.temporaryDirectory.appendingPathComponent("duck-ocr-test-"+UUID().uuidString)
    defer { try? FileManager.default.removeItem(at:ocrFolder) }
    let ocrTarget = ScreenTarget(id:0,pid:0,app:"Fixture",bundleID:"test.fixture",title:"OCR fixture")
    let savedOCR = try! saveScreenRead(ocr,source:ocrTarget,region:ocrRegion,root:ocrFolder)
    assert((try! String(contentsOf:savedOCR,encoding:.utf8)) == ocr.text)
    assert(FileManager.default.fileExists(atPath:savedOCR.deletingLastPathComponent().appendingPathComponent("region.png").path))
    do { _ = try recognizeScreenRegion(png:ocrData,region:CGRect(x:-1,y:0,width:1,height:1)); assertionFailure("Invalid OCR region accepted") } catch {}
    do { _ = try saveScreenRead(ScreenReadResult(text:"",image:ocr.image),source:ocrTarget,region:ocrRegion,root:ocrFolder); assertionFailure("Empty OCR saved") } catch {}
    print("Screen OCR checks passed: Chinese/English, selected-only extraction, crop orientation, persistence, invalid/empty handling")
    let normalized = reviewSelection(CGPoint(x:180,y:90),CGPoint(x:20,y:10),size:CGSize(width:200,height:100))!
    assert(normalized == CGRect(x:0.1,y:0.1,width:0.8,height:0.8))
    assert(reviewSelection(.zero,CGPoint(x:2,y:3),size:CGSize(width:200,height:100)) == nil)
    assert(reviewSelection(CGPoint(x:-20,y:-10),CGPoint(x:220,y:110),size:CGSize(width:200,height:100)) == CGRect(x:0,y:0,width:1,height:1))
    assert(reviewScreenRect(CGRect(x:-800,y:100,width:600,height:400),desktopTop:900) == CGRect(x:-800,y:400,width:600,height:400))
    let picture = NSImage(size:NSSize(width:200,height:100),flipped:false) { bounds in
        NSColor.white.setFill(); bounds.fill(); NSColor.red.setFill(); NSRect(x:0,y:50,width:100,height:50).fill(); return true
    }
    let shot = ReviewSnapshot(id:UUID(),image:picture,png:try! reviewPNG(picture),frame:CGRect(x:0,y:0,width:200,height:100))
    let region = ReviewRegion(snapshotID:shot.id,number:1,rect:CGRect(x:0,y:0,width:0.5,height:0.5),feedback:"标题需要更清楚 <&>")
    let marked = annotatedReviewImage(shot,regions:[region])
    assert(marked.size == picture.size, "Annotation must retain the complete screenshot")
    let rich = try! reviewRichText(target:"批阅测试",regions:[region],snapshots:[shot])
    let rtfd = rich.rtfd(from:NSRange(location:0,length:rich.length),documentAttributes:[:])!
    let restored = NSAttributedString(rtfd:rtfd,documentAttributes:nil)!
    assert(restored.string.contains(region.feedback))
    var attachmentCount = 0
    restored.enumerateAttribute(.attachment,in:NSRange(location:0,length:restored.length)) { value,_,_ in if value != nil { attachmentCount += 1 } }
    assert(attachmentCount == 1, "Rich text must retain review image")
    let testClipboard = NSPasteboard.withUniqueName()
    defer { testClipboard.releaseGlobally() }
    let secondRegion = ReviewRegion(snapshotID:shot.id,number:2,rect:CGRect(x:0.5,y:0.5,width:0.5,height:0.5),feedback:"第二处评审")
    try! copyReview(target:"批阅测试",regions:[region,secondRegion],snapshots:[shot],pasteboard:testClipboard)
    assert(testClipboard.data(forType:.rtfd) != nil && testClipboard.data(forType:.png) != nil)
    assert(testClipboard.string(forType:.html)!.contains("&lt;&amp;&gt;"))
    assert(testClipboard.string(forType:.string)!.contains("第二处评审"))
    let pasted = NSAttributedString(rtfd:testClipboard.data(forType:.rtfd)!,documentAttributes:nil)!
    var pastedImages = 0
    pasted.enumerateAttribute(.attachment,in:NSRange(location:0,length:pasted.length)) { value,_,_ in if value != nil { pastedImages += 1 } }
    assert(pastedImages == 1 && pasted.string.contains("第二处评审"), "One pause with two regions must export one full screenshot")
    let nextShot = ReviewSnapshot(id:UUID(),image:picture,png:shot.png,frame:shot.frame)
    let thirdRegion = ReviewRegion(snapshotID:nextShot.id,number:3,rect:region.rect,feedback:"下一次暂停的意见")
    try! copyReview(target:"批阅测试",regions:[region,secondRegion,thirdRegion],snapshots:[shot,nextShot],pasteboard:testClipboard)
    let grouped = NSAttributedString(rtfd:testClipboard.data(forType:.rtfd)!,documentAttributes:nil)!
    var groupedImages = 0
    grouped.enumerateAttribute(.attachment,in:NSRange(location:0,length:grouped.length)) { value,_,_ in
        if let attachment = value as? NSTextAttachment {
            groupedImages += 1
            let rep = NSBitmapImageRep(data:attachment.fileWrapper!.regularFileContents!)!
            assert(rep.pixelsWide == 200 && rep.pixelsHigh == 100, "Each attachment must be the complete screenshot")
        }
    }
    assert(groupedImages == 2 && grouped.string.contains("下一次暂停的意见"))
    assert(testClipboard.string(forType:.html)!.components(separatedBy:"<img ").count-1 == 2)
    let groupedText = testClipboard.string(forType:.string)!
    assert(groupedText.range(of:"第二处评审")!.lowerBound < groupedText.range(of:"画面 2")!.lowerBound)
    assert(groupedText.range(of:"下一次暂停的意见")!.lowerBound > groupedText.range(of:"画面 2")!.lowerBound)
    assert(try! JSONDecoder().decode([ReviewRegion].self,from:JSONEncoder().encode([region]))[0].rect == region.rect)
    print("Review checks passed: selection bounds, multiple-display coordinates, crop orientation, RTFD image/comment roundtrip")
    #if APP_STORE
    print("Store save checks passed: AI disabled, old analysis excluded, backup before export, export failure")
    #else
    print("Background save checks passed: isolated snapshots, backup before export, analysis fallback, export failure")
    #endif

    func sample(_ amplitude: Float) -> CMSampleBuffer {
        let length = 480
        var block: CMBlockBuffer?
        precondition(CMBlockBufferCreateWithMemoryBlock(allocator: kCFAllocatorDefault, memoryBlock: nil, blockLength: length * 4, blockAllocator: kCFAllocatorDefault, customBlockSource: nil, offsetToData: 0, dataLength: length * 4, flags: 0, blockBufferOut: &block) == noErr)
        let values = Array(repeating: amplitude, count: length)
        values.withUnsafeBytes { bytes in
            precondition(CMBlockBufferReplaceDataBytes(with: bytes.baseAddress!, blockBuffer: block!, offsetIntoDestination: 0, dataLength: bytes.count) == noErr)
        }
        var asbd = AudioStreamBasicDescription(mSampleRate: 48000, mFormatID: kAudioFormatLinearPCM, mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked, mBytesPerPacket: 4, mFramesPerPacket: 1, mBytesPerFrame: 4, mChannelsPerFrame: 1, mBitsPerChannel: 32, mReserved: 0)
        var format: CMAudioFormatDescription?
        precondition(CMAudioFormatDescriptionCreate(allocator: kCFAllocatorDefault, asbd: &asbd, layoutSize: 0, layout: nil, magicCookieSize: 0, magicCookie: nil, extensions: nil, formatDescriptionOut: &format) == noErr)
        var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: 48000), presentationTimeStamp: .zero, decodeTimeStamp: .invalid)
        var size = 4
        var sample: CMSampleBuffer?
        precondition(CMSampleBufferCreateReady(allocator: kCFAllocatorDefault, dataBuffer: block, formatDescription: format!, sampleCount: length, sampleTimingEntryCount: 1, sampleTimingArray: &timing, sampleSizeEntryCount: 1, sampleSizeArray: &size, sampleBufferOut: &sample) == noErr)
        return sample!
    }
    assert(audioLevel(sample(0)) == 0)
    assert(abs(audioLevel(sample(0.02)) - 0.24) < 0.001)
    assert(audioLevel(sample(0.8)) == 1)
    print("Meeting checks passed: chronological transcript, safe Notes script, PCM audio levels")
}

#endif
