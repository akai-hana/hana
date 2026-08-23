# Clock Re-Architecture Plan

Goal: the cleanest possible clock. Simplicity and purity are the only
criteria; implementation effort is irrelevant. Status: IMPLEMENTED (2026-08-23).
Deviation from §3 during implementation: `invalidate()` was dropped --
`draw()` records the format pointer it rendered with, so config reloads
self-invalidate via the same staleness comparison as time passage.

## 1. Diagnosis -- why today's clock is complex

The clock is ~200 lines because one design decision forces everything else:
**a background thread owns timekeeping**. From that single choice follow,
necessarily:

| Forced consequence | Lines |
|---|---|
| Mutex-guarded formatted-time cache (thread publishes, draw reads) | cache trio + lock dance |
| Atomic dirty flag (thread signals, main consumes) | `clock_dirty` |
| Wakeup channel for a blocked `poll()` (a flag cannot wake poll) | `nextTickWaitMs` deadline math |
| Drain race: main wakes at boundary before thread formats | `drain_grace_ms` + `retry_ms` + retry branch in events.zig |
| Thread lifecycle (spawn/stop, owned+null-terminated format copies) | `startThread`/`stopThread`/`runClockThread` |
| Placement outside bar/ (core depends on its tick) | core/services/clock.zig |

Remove the thread and every row above loses its reason to exist.

## 2. Design principles (what "clean" means here)

- P1 **Time is a schedule, not an event stream.** The event loop already
  asks plugins "when do you next need waking?" (`hooks.Plugin.poll_timeout_ms`,
  used by prompt blink). A clock answers with pure arithmetic: ms until the
  next wall-second boundary. No producer thread is required.
- P2 **Single-threaded by construction.** All state lives on the main thread.
  No locks, no atomics, no memory ordering, no drain races -- not because they
  are handled well, but because they are impossible.
- P3 **The renderer is the sole owner of render state.** One module-level
  `rendered_sec` records what is on screen. "Second elapsed?" compares against
  it; drawing updates it. No separate dirty flag can ever disagree with it.
- P4 **Segments are self-contained under bar/.** A segment may *contribute* a
  deadline via the existing plugin hook, but nothing outside bar/ may depend
  on a segment's internals. Removing src/bar/ must remove the clock cleanly.
- P5 **Failure self-heals.** If draw fails (e.g. fonts unavailable),
  `rendered_sec` stays stale, so the next boundary retries. No error
  propagation paths beyond what drawSegment already has.

## 3. Target architecture

```
bar/segments/clock.zig                     (~90 lines, all of it trivial)
  pub const measure_string                 // width precompute (unchanged)
  pub fn tickDeadlineMs() i32              // pure: ms -> next :00 boundary
  pub fn secondElapsed() bool              // now != rendered_sec (no consume)
  pub fn invalidate() void                 // config reload / format change
  pub fn draw(dc, cfg, height, x) !u16     // format-if-stale, then drawSegment
  var rendered_sec: i64 = -1               // plain var; single-threaded (P2)
```

Data flow per idle second (the entire runtime story):

    events.zig loop
      timeout = min over plugin hooks          <- bar's hook returns tickDeadlineMs()
      poll(...) wakes at boundary
      iteration_end -> bar.updateClock()
        if clock.secondElapsed() -> drawClockOnly()
          clock.draw(): format now(), paint region, blit

Ownership table:

| Concern | Owner | Mechanism |
|---|---|---|
| When to wake | clock.zig | `tickDeadlineMs()` via bar's `poll_timeout_ms` hook |
| Is screen stale? | clock.zig | `secondElapsed()` vs `rendered_sec` |
| Rendering | clock.zig `draw()` | unchanged drawSegment path |
| Format string lifetime | config (unchanged) | borrowed for the duration of draw |

events.zig imports clock: **no longer** (both direct calls deleted; deadlines
arrive generically through the plugin interface that already exists).

## 4. Deletions (current -> target)

- `startThread`, `stopThread`, `runClockThread`, `sleepUntilNextSecond`
- `publishCurrentTime`, `consumeClockDirty`, `getOrFormatTime` lock dance
- `cache_mutex`, `last_formatted_*` trio, `clock_dirty` atomic, `CondThread`
- `drain_grace_ms`, `retry_ms`, owned + null-terminated format copies
- events.zig: direct `@import("clock")`, both `nextTickWaitMs` call sites,
  and the negative-timeout retry branch (existed only for the drain race)
- bar.zig: `clock.startThread(...)` / `clock.stopThread(...)` lifecycle calls;
  `updateClock` shrinks to guard + `secondElapsed()` + `drawClockOnly()`
- Directory lie: `core/services/clock.zig` moves to `bar/segments/clock.zig`.
  core/services keeps refresh_rate (RandR notify consumed by events.zig --
  genuinely cross-layer) and scale (DPI consumed by config/main).

## 5. Migration steps (each independently verifiable)

1. Add `tickDeadlineMs`/`secondElapsed`/`invalidate` to clock.zig alongside
   the thread implementation; route bar's `poll_timeout_ms` hook through
   `min(blink, clock.tickDeadlineMs())`. Build + harness parity must hold
   (two wake sources temporarily coexist).
2. Switch `updateClock` to `secondElapsed()`; delete `consumeClockDirty`
   usage. Harness must hold.
3. Delete thread machinery from clock.zig; inline lazy formatting into
   `draw()`; move file to `bar/segments/clock.zig`; strip events.zig retry
   branch and import; drop bar.zig lifecycle calls. Update wire_allowlist/
   README path notes (none reference clock today -- verify by grep).
4. Unit tests: new `src/test/clock_test.zig` for `tickDeadlineMs` math
   (boundary cases m=0, m=999, grace-free semantics) -- first time this
   module is testable at all (P2 removes the threads that blocked testing).

Verification after each step: `zig build`, `zig build test --summary all`
(37 -> 37+, growing in step 4), `scripts/check-layers.sh`, full harness
compare (expect 18/18 with zero golden churn -- no log lines change), plus a
one-time live Xvfb check: clock region pixels change across a >=2 s window;
workspace switches do not disturb them.

## 6. Behavior contract (unchanged, by argument)

- Display flips within milliseconds of each wall-second boundary (same wake
  cadence as today; alignment logic identical minus grace fudge).
- Idle power: exactly one wake per second, identical to current.
- Config reload with new format: width-cache reset path already exists;
  `invalidate()` covers any residual staleness.
- Timezone/locale: same strftime/localtime_r fallback code, untouched.

## 7. Non-goals

- Not touching refresh_rate/scale placement (genuine cross-layer services).
- Not changing the Plugin/hook interface (already sufficient: P1 needs
  nothing new).
- Not adding sub-second display support (format strings could ask for it;
  out of scope unless requested later -- would change tickDeadlineMs to
  parse the format's finest unit).
