Final plan (all items, benchmark-probe verification). Still read-only until you approve.
P0 — Batch title/geometry fetches in bar.captureStateIntoSlot
File: src/bar/bar.zig:686-702
- Phase 1: fire get_property cookies (UTF8 _NET_WM_NAME, plus WM_NAME fallback cookie only when the UTF8 reply comes back empty — keep the two-property logic) for all non-focused workspace windows; fire get_geometry cookies only for windows the tiling cache misses (floating).
- Phase 2: collect replies, fill snap.window_titles / snap.window_geoms.
- Reuse the cookie-array idiom from title.gatherWindowInfos (title.zig:600+); fetchWindowTitleInto/fetchWindowGeom stay as single-window helpers for the focused/minimized cases.
- Expected: title_changed redraw drops from up to 2N sequential RTTs to ~2.
P1 — Redraw-cost reductions
- syncTitleCache (bar.zig:584): replace window_titles.replaceWith with an ownership relay (swap a replacement list like swapAlloc does for geoms), so unchanged titles aren't re-duped on full draws. Only rebuild the copy when titles actually changed.
- swapWindowsInList (tiling.zig:1213): instead of bar.scheduleFullRedraw(), add a "geometry changed" bar signal that marks the title segment dirty without refetching every title (title set and focus are unchanged — only on-screen positions moved).
P2 — Memory + lifecycle
- Per-batch scratch arena: introduce a std.heap.ArenaAllocator reset each event batch in core/events.zig, used for event-scoped temporaries (e.g. title fetch buffers, snapshot scratch). Long-lived allocations keep using c_allocator. Audit that no arena pointer escapes the batch.
- clock.stopThread (clock.zig): replace the up-to-1s join with a self-pipe/timestamp wakeup so reload doesn't block.
Verification — benchmark probe (temporary, disabled by default)
- Gate behind a build option (e.g. -Dbench) or env var, default off.
- Counter module (src/bench.zig): atomics counting xcb_*_reply calls at the touched sites + captureStateIntoSlot duration (nanoseconds) and window count.
- Emit a one-line summary per full bar redraw to stderr.
- Measure before/after on: workspace with 10–20 windows → focus-cycle → master swap → title-change (minimize) — report RTT count and redraw latency delta.
- Probe code is removed (or left inert) at the end unless you want to keep it.
Acceptance
- zig build + zig build test pass.
- No xcb_*_reply calls added inside any grabServer region (keeps atomic-grab invariant).
- Benchmark shows the P0 redraw RTT count drop to ~2 and title re-dupe elimination.
Approve to switch to execute mode and I'll start with P0 + the probe.
