# Review recovery validation

Scope: ReviewModel/Export/Panels, VoiceInput, ScreenReader/Windows and isolated tests. No real recording, Notes automation, external AI, signing scripts, push or main merge performed.

## Commands

- `sh tests/run-review-recovery.sh`: independent executable with assertions enabled; checks late final transcript delivery through the production result handler while switching/closing, correct region ownership, original and marked PNG mtime stability for feedback edits, geometry-triggered redraw, orange badge and unchanged background pixels, legacy regions JSON, manifest/original corruption and missing originals, failed close preserving images/feedback, multi-shot selected-image restoration, debounced autosave, and Retina OCR/review pixel budgets.
- Direct release, from `outputs/DuckIsland`: `swiftc -O main.swift MeetingCapture.swift MeetingRecognition.swift NotesExport.swift MeetingAnalysis.swift SpeechProbe.swift ScreenWindows.swift ScreenReader.swift VoiceInput.swift ReviewModel.swift ReviewPanels.swift ReviewExport.swift SelfTests.swift -o /tmp/duck-review-direct-release -framework Cocoa -framework SwiftUI -framework Speech -framework AVFoundation -framework ScreenCaptureKit -framework Vision -target arm64-apple-macosx15.0`.
- Store release: `xcodebuild -project outputs/DuckIsland/DuckIsland.xcodeproj -scheme DuckIsland -configuration Release -derivedDataPath /tmp/duck-review-store-build CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO build`.
- `git diff --check`.

The ordinary release uses build.sh's source list without its signing/run steps, adding optimization. An exploratory Xcode build overriding APP_STORE globally failed because NotesHelper then referenced analyzeMeeting outside its source list; that is not the ordinary release build route. The supported direct compiler route and Store Xcode route are verified separately. Xcode may emit its existing AppIntents metadata warning.

## Format and recovery

The original `01-<UUID>.png` annotated-image naming, `regions.json` shape and `review.txt` output are retained. The serial store adds immutable `original-<UUID>.png`, version-1 `session.json` and sorted geometry fingerprints. Feedback edits update metadata/text without re-encoding images; geometry changes redraw only the affected marked image using Core Graphics/Core Text. Individual files are atomic and the manifest is committed last; the directory as a whole is not a multi-file atomic transaction.

Recovery offers the most recently saved session, including after single-window automatic selection, until the new session has captured an image. It restores all original screenshots, regions, feedback and selection, showing the selected region's screenshot; it stops/invalidate old window tracking. Legacy exports lacking session.json and originals remain readable exports but are not editable recovery sessions. Corrupt newest sessions surface an error without replacing memory; the UI does not browse older sessions or silently skip the corrupt newest one. File-write errors retain current memory and block successful close.

## Integration and limits

B/PM must await `review.closeForTermination() async -> Bool` in the termination lifecycle and cancel termination on false (including busy state). `close()` remains a fire-and-forget asynchronous sidebar compatibility wrapper and cannot guarantee process-exit persistence. Baseline main.swift is intentionally untouched by this task and still requires that integration.

Speech tests inject delayed results without hardware or permission prompts. The existing two-second speech finish timeout remains: callbacks accepted before finalization belong to the original region, and callbacks after timeout are rejected by the session token. Real microphone timing, actual OCR recognition of small text, Retina/multi-monitor visuals, sidebar recovery-button interaction, export typography, disk throughput and memory/performance on real devices have not been measured. OCR preserves up to 2x scale subject to 12 MP/8192-edge limits; review uses 6 MP/4096-edge limits.
