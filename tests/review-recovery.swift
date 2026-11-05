import Cocoa

struct NotesFailure: LocalizedError { let detail: String; var errorDescription: String? { detail } }
func htmlEscape(_ text: String) -> String { text }
class IslandPanel: NSPanel {}

@main struct ReviewRecoveryTests {
    @MainActor static func main() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("review-tests-"+UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:root) }
        let store = ReviewStore(), folder = root.appendingPathComponent("2026-test")
        let image = NSImage(size:CGSize(width:100,height:100),flipped:false) { bounds in NSColor.white.setFill(); bounds.fill(); return true }
        let png = try reviewPNG(image), shotID = UUID()
        var region = ReviewRegion(snapshotID:shotID,number:1,rect:CGRect(x:0.1,y:0.1,width:0.5,height:0.5),feedback:"first")
        func payload() -> ReviewSavePayload {
            ReviewSavePayload(session:StoredReviewSession(target:nil,shots:[StoredReviewShot(id:shotID,frame:CGRect(x:1,y:2,width:100,height:100))],regions:[region],selectedID:region.id),originals:[shotID:png],text:region.feedback)
        }
        try await store.save(payload(),folder:folder)
        let original = folder.appendingPathComponent("original-\(shotID).png")
        let marked = folder.appendingPathComponent("01-\(shotID).png")
        let firstMarked = try Data(contentsOf:marked)
        let bitmap = NSBitmapImageRep(data:firstMarked)!
        let badgeColor = bitmap.colorAt(x:15,y:15)!.usingColorSpace(.deviceRGB)!
        let outsideColor = bitmap.colorAt(x:90,y:90)!.usingColorSpace(.deviceRGB)!
        assert(badgeColor.blueComponent > badgeColor.redComponent && badgeColor.blueComponent > badgeColor.greenComponent)
        assert(outsideColor.redComponent > 0.95 && outsideColor.greenComponent > 0.95 && outsideColor.blueComponent > 0.95)
        let exportedRegions = try JSONDecoder().decode([ReviewRegion].self,from:Data(contentsOf:folder.appendingPathComponent("regions.json")))
        assert(exportedRegions.first?.id == region.id)
        let oldDate = Date(timeIntervalSince1970:100)
        try FileManager.default.setAttributes([.modificationDate:oldDate],ofItemAtPath:original.path)
        try FileManager.default.setAttributes([.modificationDate:oldDate],ofItemAtPath:marked.path)
        region.feedback = "updated"
        try await store.save(payload(),folder:folder)
        let originalDate = try FileManager.default.attributesOfItem(atPath:original.path)[.modificationDate] as? Date; assert(originalDate == oldDate)
        let markedDate = try FileManager.default.attributesOfItem(atPath:marked.path)[.modificationDate] as? Date; assert(markedDate == oldDate)
        let restored = try await store.load(folder:folder)
        assert(restored.originals[shotID] == png && restored.session.regions.first?.feedback == "updated")
        assert(restored.session.selectedID == region.id)
        let latest = try await store.latest(root:root); assert(latest?.standardizedFileURL.resolvingSymlinksInPath().path == folder.standardizedFileURL.resolvingSymlinksInPath().path)
        region = ReviewRegion(snapshotID:shotID,number:2,rect:CGRect(x:0.2,y:0.2,width:0.3,height:0.3),feedback:"geometry")
        try await store.save(payload(),folder:folder)
        let changedDate = try FileManager.default.attributesOfItem(atPath:marked.path)[.modificationDate] as? Date; assert(changedDate != oldDate)
        let secondMarked = try Data(contentsOf:marked)
        assert(secondMarked != firstMarked)

        let blocker = root.appendingPathComponent("file"); try Data().write(to:blocker)
        do { try await store.save(payload(),folder:blocker.appendingPathComponent("bad")); fatalError("accepted failed save") } catch {}
        try Data("broken".utf8).write(to:folder.appendingPathComponent("session.json"))
        do { _ = try await store.load(folder:folder); fatalError("accepted corrupt session") } catch {}
        try await store.save(payload(),folder:folder)
        try Data("not a png".utf8).write(to:original)
        do { _ = try await store.load(folder:folder); fatalError("accepted corrupt original") } catch {}
        try FileManager.default.removeItem(at:original)
        do { _ = try await store.load(folder:folder); fatalError("accepted missing original") } catch {}
        let failedModel = ReviewModel(storageRoot:blocker)
        failedModel.active = true
        failedModel.snapshots = [ReviewSnapshot(id:shotID,image:image,png:png,frame:.zero)]
        failedModel.regions = [region]; failedModel.selectedID = region.id
        failedModel.voice.draft = "retain unsaved feedback"
        let failedClose = await failedModel.closeForTermination()
        assert(!failedClose && failedModel.active && failedModel.snapshots.count == 1)
        assert(failedModel.status.contains("保存失败"))
        assert(failedModel.regions.first?.feedback == "retain unsaved feedback")
        let ocr = screenCaptureSize(CGSize(width:1920,height:1080),scale:2,purpose:.ocr)
        assert(ocr == CGSize(width:3840,height:2160))
        for purpose in [ScreenCapturePurpose.ocr,.review] {
            let size = screenCaptureSize(CGSize(width:100000,height:200000),scale:2,purpose:purpose)
            assert(size.width * size.height <= (purpose == .ocr ? 12_000_000 : 6_000_000))
        }
        let recoveryFolder = root.appendingPathComponent("multi-shot")
        let laterShotID = UUID()
        let multi = ReviewSavePayload(session:StoredReviewSession(target:nil,shots:[StoredReviewShot(id:shotID,frame:CGRect(x:0,y:0,width:100,height:100)),StoredReviewShot(id:laterShotID,frame:CGRect(x:0,y:0,width:100,height:100))],regions:[region],selectedID:region.id),originals:[shotID:png,laterShotID:png],text:region.feedback)
        try await store.save(multi,folder:recoveryFolder)
        let recoveredModel = ReviewModel(storageRoot:root)
        try await recoveredModel.restore(folder:recoveryFolder,presentPanels:false)
        assert(recoveredModel.current?.id == shotID && recoveredModel.snapshots.count == 2)
        assert(recoveredModel.selectedID == region.id && recoveredModel.voice.draft == region.feedback)
        recoveredModel.voice.draft = "debounced edit"
        try await Task.sleep(nanoseconds:700_000_000)
        let autosaved = try await store.load(folder:recoveryFolder)
        assert(autosaved.session.regions.first?.feedback == "debounced edit")
        try Data("corrupt".utf8).write(to:recoveryFolder.appendingPathComponent("session.json"))
        do { try await recoveredModel.restore(folder:recoveryFolder,presentPanels:false); fatalError("accepted corrupt restore") } catch {}
        assert(recoveredModel.snapshots.count == 2 && recoveredModel.regions.first?.feedback == "debounced edit")
        let recoveredClosed = await recoveredModel.closeForTermination(); assert(recoveredClosed)
        let smallText = screenCaptureSize(CGSize(width:1440,height:900),scale:2,purpose:.ocr)
        assert(smallText == CGSize(width:2880,height:1800))
        let reviewSize = screenCaptureSize(CGSize(width:1920,height:1080),scale:2,purpose:.review)
        assert(reviewSize.width * reviewSize.height <= 6_000_000 && reviewSize.width < ocr.width)
        let model = ReviewModel()
        let first = ReviewRegion(snapshotID:shotID,number:1,rect:.zero), second = ReviewRegion(snapshotID:shotID,number:2,rect:.zero,feedback:"second")
        model.regions = [first,second]; model.selectedID = first.id
        model.voice.dictating = true
        model.select(second.id)
        try await Task.sleep(nanoseconds:50_000_000)
        assert(model.selectedID == first.id)
        assert(model.voice.voiceFinishing)
        model.voice.receiveTranscript("late final",final:true,failed:false)
        while model.busy { try await Task.sleep(nanoseconds:10_000_000) }
        assert(model.regions[0].feedback == "late final" && model.regions[1].feedback == "second")
        model.voice.dictating = true
        let closing = Task { await model.closeForTermination() }
        try await Task.sleep(nanoseconds:50_000_000)
        assert(model.voice.voiceFinishing)
        model.voice.receiveTranscript("close final",final:true,failed:false)
        let closed = await closing.value; assert(closed)
        assert(model.regions[1].feedback == "close final")
        print("PASS: incremental original/marked files, annotation consistency, multi-shot restore, debounce autosave, corruption, save failure retention, OCR Retina budget, late voice switching and close")
    }
}
