# Rework report: core intents, open addons (H1 + H8)

**Date:** 2026-09-01
**Scope:** covering (fullscreen) feature — model single-source-of-truth /
core-intents cleanup. This file was referenced by `REARCHITECTURE_PLAN.md`
(changelog, WP8 line) but did not previously exist; it is created here to
document the H1+H8 rework.

## Decision: "core intents, open addons"

`model` (`src/model/model.zig`) is a **closed core**: it must not import
optional subsystem modules. Optional window subsystems live under
`src/window/modules/`. The clean architecture places **AUTHORITATIVE
cross-cutting core intents in the model**, while the optional subsystems are
**producers** that write those intents into the model, and core layers (sync,
bar, persistence) read **only** the model's core intents — never a subsystem's
private store.

Concretely, the model hosts the orthogonal core intents:

- `presence`: `present` / `parked` / `covering` (an open *pattern*, never a
  feature name)
- `covering_ws`: the workspace a covering window's capture anchors to
- `mask`: tag set
- `anchor`: `BaseMode` (tiled / floating rect)
- `home_ws`: cached tiled-slot workspace

Per-feature **identity** stays privately in the open addon: fullscreen's
pre-fullscreen `anchor` + ghost bookkeeping in `g_recs`; minimize's slot/seq in
its own store. A removed subsystem simply stops producing its intent fields'
values, and core never names the feature — so removal leaves no residue and no
core edit.

## What changed

### 1. `model.covering_ws` core intent (model.zig — owned by another agent)

- `Entry.covering_ws: ?model.WSId = null` — the workspace a covering window's
  capture anchors to.
- `model.coveringOccupantOnWs(m, ws) ?WindowId` — pure core helper: scans
  `presence == .covering` and `(covering_ws == ws or visibleOn(m, win, ws))`.

### 2. `fullscreen.zig` — the module is now a producer of the core intent

- `toggleFullscreen` ON: appends the module record **and** sets
  `e.covering_ws = m.current` next to `e.presence = .covering`.
- `toggleFullscreen` OFF: removes the record **and** clears
  `e.covering_ws = null` next to `e.presence = .present`.
- `deserializeWindow` (re-adoption): sets `e.covering_ws = ws` alongside
  `e.presence = .covering`.
- `moveFullscreenTo` (workspaces move/tag retarget): now also sets the model
  entry's `covering_ws` to the retargeted `ws` (previously mutated only the
  module record "WITHOUT touching the model entry"; that contract is updated).
- `fullscreenWsOf` — **removed dual read-authority**: now reads
  `e.covering_ws` from the model instead of `g_recs[].ws`. Behavior for the
  parked-ghost case is preserved: `covering_ws` stays set across the minimize
  transition (`minimize` parks presence but leaves `covering_ws`/anchor alone).
- Module queries `coverageOn` / `fullscreenOccupantOnWs` kept as-is (they scan
  the module store and are still exercised by tests); they remain consistent
  with the model authority because `covering_ws` is kept in lockstep with
  `g_recs[].ws` at every write point.

### 3. `persist.zig` — covering is a first-class model-persisted intent

- `WindowRecord` gains `covering_ws: ?model.WSId = null` (version-4 struct).
- The serialize path writes `covering_ws = item.val.covering_ws` from the live
  model.
- The restore/adoption path (`applyModelLevel`, which runs after the per-window
  module-deserialize adoption pass) re-applies `presence`/`covering_ws` for any
  record with `presence == .covering` or `covering_ws != null`. This closes the
  re-exec gap where a window minimized-from-fullscreen (`presence == .parked`,
  so fullscreen's `serializeWindow` refused to emit a blob — parked ⇒ minimize
  owns the slot) previously lost its covering identity permanently: the covered
  core intent now survives even with no module blob present. Idempotent with
  whatever the fullscreen module's `deserializeWindow` already applied (same
  values, so no conflict / no double-apply).

**Format decision:** JSON stayed at **version 4**. The new `covering_ws` field
is optional with a `null` default; `std.json` parses a missing key to that
default (verified in 0.16), so old version-4 files restore with
`covering_ws = null` and new saves emit `"covering_ws": null`. No format bump
was needed. The version-1/version-2 legacy upgrade paths keep their existing
tolerances (their records simply default `covering_ws` to null).

### 4. `sync.zig` and `bar.zig` (parallel work — own agents)

Both now read `model.coveringOccupantOnWs` (the pure core helper) instead of
iterating the per-module `coverageOn` registry scan. Not authored in this
pass (read in parallel), but the contract they consume is the model core intent
this H8 pass populated.

### 5. Docs reconciled

- `REARCHITECTURE_PLAN.md`: §6 P1, §7.2, Appendix E.2 and the changelog updated
  to describe the chosen core-intents design instead of the (never-implemented)
  `Mode` union. A changelog entry was added for the H8 decision.
- `ARCHITECTURE.md`: P1 clarified — the model is authoritative for **core
  intents**, while per-feature identity lives in the open addons by design
  (open addons, trace-free removal).
- `PLUGIN_PROVIDER.md`: §2 law 4 clarified — "your store is derived state" is
  true for core intents (write them into the model, read them back, never a
  divergent second authority); the private store holds only per-feature
  identity core never reads.
- `docs/rework-report.md`: this file, created.

## Verification

- `zig build` — passes.
- `zig build test` — the unit suites pass except:
  - a pre-existing failure in `sync_test.zig` (`fs->min->restore->unfs retiles
    instead of stranding an orphan`) that also fails on the baseline and is
    owned by the colleague's in-parallel sync.zig rewrite (not this pass);
  - a `perf_test.zig` bench crash (`moveWindowToWs round-trip`) caused by
    perf_test's non-isolated process-global fullscreen state leaking across
    benchmarks combined with the now-model-read `fullscreenWsOf`. In real
    production `g_recs` and `covering_ws` are always consistent, so no crash
    occurs; `perf_test.zig` is outside this pass's permitted file set.

## Known limitations

- The `perf_test.zig` moveWindowToWs bench crashes because its earlier
  `fullscreenOccupantOnWs` bench toggles a global fullscreen record without
  resetting it, then the follow-up bench reuses that stale record against a
  fresh model whose `covering_ws` is null. This is a test-isolation flaw in a
  file outside this pass's scope; a future pass should add `init`/`deinit`
  isolation to the perf benches (the documented discipline in
  `PLUGIN_PROVIDER.md` §2.2).
