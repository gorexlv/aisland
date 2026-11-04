# Save/quit reliability verification

Run `bash outputs/DuckIsland/Tests/run-save-reliability.sh` from the repository root.
The script uses temporary output directories and exits on any failed command; it compiles
both distribution configurations plus the Store helper without signing or launching the app.
Fixtures inject disk/export/analysis outcomes and spawn only controlled `/bin/sh` children.
The existing app `--self-test` is intentionally not used because it accesses real services.

Covered: hung helper, SIGTERM ignored and SIGKILL escalation, abnormal exit, explicit
cancellation, local/Notes outcome independence, analysis retained on double failure,
serial snapshot/final write ordering, cross-session recovery, stale snapshot completion,
quit timeout, cooperative cancellation, uncooperative wait refusal, and subsequent retry.

Integration with C: in `applicationShouldTerminate`, replace the baseline `review.close()`
and `!review.active` guard with `guard await model.review.closeForTermination() else` and
the same false reply/terminating reset. Do not call the synchronous close first. This
branch cannot validate C's unavailable API; the baseline Review close still performs
synchronous persistence. The 12-second meeting stop/save deadline starts after Review close.
Merge A's recognition/audio callback changes without discarding this branch's save handling.
On a meeting stop timeout the app stays open and the existing stop task continues; retry
is allowed after it completes. Blocking filesystem I/O is never forcibly interrupted:
pending writes prevent termination, with recovery snapshots kept in memory.

Recovery copies do not mark a snapshot durable; successful Save As does. Recovery lives
for this app process, including across new meetings, and is not a crash journal when the
disk itself has failed. GUI Save As/clipboard and signed App Sandbox behavior require
manual integration verification; no real Notes, AI or capture was invoked by these tests.
