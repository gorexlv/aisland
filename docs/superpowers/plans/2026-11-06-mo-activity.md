# Shared Mo activity feedback

Approved design: share Jay avatar and lifecycle-derived activity feedback between target-window orb and island. Retain concurrent activities; never infer execution from generated text.

- [x] Define activity descriptors and pure prioritization; cover concurrent listen/summary, error badges, completed-result expiry and real action labels with offline tests.
- [x] Publish playback state/level from the audio queue, guard callbacks by session and playback generation, reset on silence/stop/failure.
- [x] Connect review replies, summaries, voice, Notes/copy/Codex actions, and meeting/reader states to one shared activity snapshot.
- [x] Reuse avatar/status visuals in orb and island; support reduced motion, input/output waveforms and concurrent badges.
- [x] Add return-to-work / status routing and hover details with island panel sizing. Move conversation tab selection to model for routing.
- [x] Run targeted offline/native regressions and independent review. No package/install or automatic commit for this implementation turn.
