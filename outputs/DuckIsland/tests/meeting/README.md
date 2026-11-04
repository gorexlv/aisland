# Meeting recognition regression checks

Run `zsh outputs/DuckIsland/tests/meeting/run.sh` from the repository root on macOS.
The executable uses synthetic PCM and an injected recognizer; it does not start
capture, real Speech recognition, Notes, or external AI. Any failed assertion
exits nonzero. Coverage includes slow recognition, exact chunk/byte capacity,
overflow rejection, accepted-tail drain, partial preservation on error/timeout,
stop/restart, stale callbacks and delayed publications, and chronological merging
of two sources during both preview and final rendering.

Production defaults admit at most 12 outstanding chunks and 16 MiB of queued PCM
payload retained by this application. The active request is fed directly to Speech;
Speech, ScreenCaptureKit, buffer-object overhead, and OS internal memory are not
measured or bounded by that byte counter. The capture callback synchronously admits
buffers on the recognition queue, avoiding an additional async audio backlog.
Recognition remains serialized for compatibility; overload explicitly stops capture
and marks lost audio. No raw audio files or recovery mechanism are introduced.

Each ended chunk gets 20 seconds after activation to finalize; stop drains all
accepted chunks rather than dropping the tail at a global 120-second deadline.
With 12 stalled chunks, finalization can take about four minutes after capture
stops (scheduler/framework stalls can add time). The UI shows the remaining count.
Level publications are capped at 20 Hz and text is coalesced at about 3 Hz; formatted
historical lines are cached and merged with previews in timestamp order.

Real long-meeting RSS, Speech throughput, main-thread responsiveness, device/network
variations, and ScreenCaptureKit stop latency remain hardware acceptance work.
These deterministic checks do not establish framework-level memory bounds.
