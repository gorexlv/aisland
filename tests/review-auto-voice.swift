// Synthetic test: voice is deliberately unavailable; never opens the microphone.
import Cocoa
let app = NSApplication.shared
app.setActivationPolicy(.prohibited)
Task { @MainActor in
    let model = ReviewModel()
    let image = NSImage(size:NSSize(width:100,height:100))
    let shot = ReviewSnapshot(id:UUID(),image:image,png:Data(),frame:CGRect(x:0,y:0,width:100,height:100))
    model.paused = true; model.current = shot; model.snapshots = [shot]
    model.voice.unavailableReason = "fixture: automatic voice requested"
    model.addRegion(CGRect(x:0.1,y:0.1,width:0.3,height:0.3))
    while model.busy { try await Task.sleep(nanoseconds:1_000_000) }
    precondition(model.selectedID == model.regions.first?.id)
    precondition(model.voice.status == model.voice.unavailableReason, "New selection must automatically request voice")
    model.voice.dictating = true
    model.addRegion(CGRect(x:0.5,y:0.5,width:0.3,height:0.3))
    while !model.voice.voiceFinishing { try await Task.sleep(nanoseconds:1_000_000) }
    model.voice.receiveTranscript("previous region final words",final:true,failed:false)
    while model.busy { try await Task.sleep(nanoseconds:1_000_000) }
    precondition(model.regions[0].feedback == "previous region final words")
    precondition(model.regions[1].feedback.isEmpty)
    precondition(model.selectedID == model.regions[1].id)
    precondition(model.voice.status == model.voice.unavailableReason, "Next region must also request voice")
    print("PASS: auto voice after selection, final words stay on previous region, next region auto starts")
    exit(0)
}
app.run()
