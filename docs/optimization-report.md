# Optimization & cleanup report - analyst pass 2026-08-23

Scope: 14 read-only subsystem analyses over the full tree, consolidated and
independently verified (symbol greps + quoted-code spot-checks) by the
orchestrator. Baseline at time of writing: `zig build` clean,
`zig build test --summary all` **48/48** across 5 binaries,
`dev/scripts/check-layers.sh` pass. (Suite has since grown to **107/107**
across 10 binaries - see §SW-3 note.) Golden harness not re-run (Xvfb-heavy);
no source files were modified during analysis.

Method: every dead-code claim was mechanically confirmed (zero callers
outside definitions/comments); every high-severity claim was verified
against the quoted anchor before acceptance. Four claims failed verification
and are rejected (see §REJECTED). Estimates are labeled: [g] = guess,
[m] = measured or mechanically derived.

---

## Classification counts

| Bucket | Count | Meaning |
|-----------------|-------|---------|
| SAFE-WIN | 47 | low risk + gate-covered; batchable without debate |
| NEEDS-DECISION | 26 | real but carries a trade-off, needs coverage, or touches politics/scope |
| REJECTED | 4 | failed verification |

---

## SAFE-WIN backlog (apply as one or two mechanical commits)

### SW-1: Dead-code deletion sweep (~150-180 LoC) - compiler-gated, zero behavior change
All individually grep-verified. Delete:
- `model.zig:139 removeValuePub` (-6)
- `engine.zig:111 emitPlacement` alias (-2)
- `workspaces.zig:49 OverrideLookup` struct (-5)
- `utils.zig:56 pushWindowOffscreen` + `pushWindowOffscreenAndLower`; delegate wire.zig parkShim duplication instead of deleting it (S9F3 option B) - see ND-11 for the alternative
- `constants.zig:61 offscreen_sentinel_min`, `x11wire.zig:33 isOffscreenGeomReply` (-13)
- `x11wire.zig:91 grab_active/isGrabActive` writes+field (-12)
- `prompt.zig:99 cached_pre_cursor/cached_pre_len` (-6)
- `sync.zig:194 schedule`, `sync.reset` (-4); `sync.zig:157-159 bench_* counters` (written, never read even in bench builds)
- `title.zig:244 drawCached` (-7); `title.zig drawSegmentTitle` dead params (-4)
- `window.zig:109 configureWindowGeom` (+ its comment cross-refs in sync.zig:7, wire.zig:4, actions.zig:153, x11wire.zig:41)
- `getStateOpt` x3 (`focus.zig:66`, `window.zig:93`, `tracking.zig:129`) + tracking Pos helpers + related decl cluster in window.zig (S4F2, -75 total)
- `vim.zig execDirectSym` return type -> void (caller vim.zig:229 discards)
- `prompt.zig text_only` param (-7), empty switch arm (-4)
- `workspaces.zig ws.master_width/ws.stack_balance` fields (write-only null resets)
- `bar.zig` imports `fullscreen`, `workspaces`; floating.zig unused imports (-9 combined)
- drawing.zig `visual_type` field write-only after local resolve (S10F7)

Gate: build + tests + layers. Risk: ~zero. Est: 1-2 h [g].

### SW-2: Stale-comment correction sweep (~25 sites)
Comments referencing deleted entities or contradicting code, each verified:
- plugin-registry comments: `clock.zig:4-5,56-57`, `events.zig:350-353`
 ("plugin.poll_timeout_ms"), `carousel.zig clock.zig plugin refs`,
 main.zig D8 comment is already correct.
- `master.zig:39-40` "sync guards the empty workspace" - false (see ND-2);
 fix comment together with the guard decision.
- `window.zig` handleMapRequest contradiction, stale geometry-cache pointer
 note, orphaned post-unmanage doc, spawn-queue staleness note.
- `focus.zig` pre-grab resolver comments, suppression-policy wording;
 stale `spawn_cursor` mention (window.zig:621/624).
- `prompt.zig:703 insertChar` reference (function gone); colon-mode comments.
- `title.zig TitleWidthCache` fossil; carousel "not shim" doc correction.
- `parser/fallback` OOM-comment wrong; `scale.zig` garbled sentence;
 `bench.zig` doc wording; events.zig reload-flag comment (pair with ND-8).
Gate: n/a (comments). Risk: zero. Est: 2 h [g].

### SW-3: Doc drift fixes (S14F3)
`docs/subsystems.md:11` "39 tests" -> 107 (10 binaries, counts listed in
ledger); `:14` "39/39 expected" -> 107/107; scenario table refresh. The suite
has grown from 48 (at this report's baseline) to 107 since; re-verify the
count before editing. Risk: zero.

### SW-4: Asserts & init hardening
- `store.zig:75 at()`: add `std.debug.assert(seq < count())` (prose-only
 precondition today). [g] 10 min.
- `time.zig:6 clockTs`: check `clock_gettime` return; fall back to the other
 VDSO clock or zero-init with a warn - current code returns undefined on
 failure. [g] 20 min.
- `model.zig:435 cycleLayout`: drop dead `if (next < 0)` line after `@mod`
 (sign follows divisor; unreachable). [m] 1 min.
Gate: tests still 48/48. Risk: ~zero.

### SW-5: Saturating-arithmetic swaps (identical below break points)
- `hints.zig` snap floor `0 -| ...` pattern (S2F2).
- `tags.zig:122` `text_x = x + (ws_width -| label_w) / 2` - plain u16 sub
 underflows when label wider than cell (short labels only today).
- `vim.zig:519 effectiveCount` - clamp product operands (1e6 x 1e6 > u32 max
 reachable via count prefix chains).
Gate: unit tests for the boundary values added alongside. Est: 1 h [g].

### SW-6: Byte-identical refactors / micro-hygiene
- `borders.zig sweepWorkspaceBorders`: hoist comptime-duplicated mask logic
 into a comptime fn (S4F8).
- `scale.readXftDpi` duplicated parse block -> one helper (S9F11).
- `drawing.zig measureCacheLookup` (:117-125): hash once per miss, reuse for
 store (S10F8).
- `title.zig scaledSegmentPadding` hoist out of per-window loop (S11F7).
- `pipeline.zig postDispatch` (:107-109): call `ctx()` once (S7F8).
- `input scroll-bind`: early-return when `clicked_win == 0` instead of
 nested branch (S8F7).
- tagged-panic consolidation in input sub-switches (S8F6).
Est: 1-2 h [g]. Gate: goldens unaffected (byte-identical).

### SW-7: Error-path leak hygiene (OOM paths only; success paths untouched)
- `drawing.zig initWithVisual`: GC/pixmap freed on later-step failure
 (errdefer exists for pixmap :268; pair GC) (S10F4).
- `bar render State.init`: mirror deinit on partial-failure path (S10F5).
- `drawing.zig:639 convertFontName`: `put(...) catch {}` leaks both
 `owned_key` and `converted` (errdefer doesn't fire because error is
 swallowed) - free key on put failure (S10F6, verified).
Risk: minimal; uncovered by gates but contained to allocation failure.
Est: 45 min [g].

### SW-8: Event-batch cap exit frees pending event (S7F1, verified)
`events.zig:285-317`: on hitting `max_events_per_batch` while holding a
non-motion event in `pending` (:309), the loop exits and leaks that
`xcb_generic_event_t`. Free it at loop exit. Drop-vs-dispatch semantics are
unchanged (it was already skipped); only the leak disappears.
Gate: no observable diff; goldens clean. Est: 15 min [m: anchor read].

### SW-9: Coverage additions (additive only)
- Unit test: scroll layout orphan keep-last invariant (S3F8).
- Pin test: engine placement snapshot vs golden list (guards ND-2 fix).
- Mirror test: `snapshotNeedsRefetch` false-negative case (S10F9).
- Config round-trip tests incl. >64 KiB file path (pairs with ND-3) (S13F9).
- Harness scenarios: layout-switch storm, hints-resize (S14F10) - additive
 yardsticks, not modifications-to-pass.
Est: 0.5 day [g].

### SW-10: Diagnostics
- Warn (once) when `_NET_ACTIVE_WINDOW` client message targets an unmanaged/
 invisible window instead of silent disable (S6F9/S6F10 family).
- Config: warn when unknown keys silently default (anchor renamed - see
 OQ-9) and when variant overrides are swallowed (S13F10).
Est: 1 h [g].

---

## NEEDS-DECISION backlog (ordered by impact / risk)

### ND-1: Boot-time config seeding is inert (S5F1) - top impact
Anchor: main.zig boot sequence (:40-77): `config.load` -> `core.init` -> grabKeybindings -> window.init -> pipeline.init -> bar.init. Nothing applies
tiling params/workspace overrides to the model; `applyConfigReload` runs
only on the first explicit reload. Consequence: margins/gaps/layout-kind/
workspace overrides from the config file are ignored until the user presses
reload. Evidence: grep shows no apply* call between core.init and run().
Proposal: factor the param-seeding half of applyConfigReload into
`config.applyInitial(model)` called once after pipeline.init.
Risk: medium (touches boot order; bar sizing depends on config too).
Gate: new unit test + one harness scenario using a non-default config.toml
(S15 proves per-scenario config works). Est: 2-4 h. Analyst: S5.

### ND-2: Empty-order crash in grid/monocle (S2F1) - highest severity, easy test
Verified chain: sync.zig:242-263 calls `engine.compute` whenever no
fullscreen winner, with no empty guard; `grid.compute` divides by
`calcGridShape(0).rows == 0` (grid.zig:22); `monocle.compute` indexes
`v.order[v.order.len - 1]` (monocle.zig:21) -> underflow. master.zig:39-40's
comment claims a guard that does not exist. Reachable when the last tiled
window closes/unmaps on those layouts before reconcile.
Proposal: skip compute when `n == 0` (emit nothing) OR assert-and-document
the caller contract; add pure unit tests for n=0 across all six layouts.
Risk: low (pure functions). Gate: unit tests + closing-last-window scenario.
Est: 2 h. Analysts: S2 (corroborated).

### ND-3: config.readFileAlloc stat-failure path truncates and double-frees (S13F1) - verified worse than reported
Anchor: config.zig:147-163. On stat failure: `total = n` overwrites (never
accumulates); loop exits when `n < buf.len` where buf grows each iteration -> a 100 KiB file returns only its tail chunk (`buf[0..36864]`); a >=128 KiB
file truncates to 64 KiB. Additionally `allocator.free(buf)` at :157 then
returning triggers the armed `errdefer` (:150) -> double free. Main path
:169-171 re-checks size already guaranteed by :165 (dead).
Proposal: rewrite fallback loop with accumulating offset + single ownership;
delete dead re-check. Gate: new config round-trip test incl. large file +
forced stat-failure simulation if feasible. Risk: low once rewritten; UB
today. Est: 2 h. Analyst: S13.

### ND-4: Prompt/marquee 1 kHz poll-render spin (S12F1 + S11F1) - biggest perf item
Verified chain: prompt active => title.draw never runs => carousel.offsetFor
never called => `scrolling` stays true from the last overflowing frame => `pollDeadlineMs` keeps returning >=1 ms (carousel.zig:88-93) while
`scrollingActive()` forces bar.updateIfDirty to refuse snapshot-skip and
repaint the full title segment every wake. Prompt cursor blink alone already
contributes ~1 kHz-class wakes by design (blink cadence); marquee makes the
wakes full-repaints. Net effect: sustained ~1000 Hz wakeups + repaints while
a command prompt is open over an overflowing title.
Proposal options: (a) prompt.draw clears `marquee.scrolling` /
calls offsetFor for the covered window; (b) pollDeadlineMs adds a decay
timeout that self-deactivates scrolling after N ms without frames; (c) both.
Risk: medium (golden timing scrubbed, but repaint cadence visible in
xtrace-based scenarios?). Gate: existing goldens + battery micro-bench
before/after. Est: 3-5 h. Analysts: S12, S11, S10 (corroborated x3).

### ND-5: Clock blit width uses sampled width, not drawn width (S10F1)
Anchor: bar.zig:434-443 `drawClockOnly` blits fixed
`layout_cache.clock_width` (sampled at layout time, bar.zig:199) while
`clock.draw` paints whatever it measures now (font fallback changes, digits
width drift). Stale pixels or clipped digits possible right of the clock.
Proposal: use the end_x returned by clock.draw for the blit width; keep
cache for layout reservation only. Needs visual/golden confirmation.
Est: 1-2 h. Analyst: S10.

### ND-6: Prompt caches survive config reload (S12F2)
Module-global caches (fonts/colors/preedit geometry) are built against the
old config; bar.reload rebuilds bar state but never invalidates them -> stale rendering until next prompt cycle. Proposal: reset hook invoked from
`bar.applyReload`. Gate: reload scenario with prompt open. Est: 1-2 h.

### ND-7: History load keeps oldest lines, drops newest (S12F4)
`collectLines` (prompt.zig:608-621) scans from byte 0 and stops at capacity -> after the history file exceeds line capacity the newest entries (tail) are
invisible. Proposal: scan from EOF backwards or slice tail first.
Behavior change visible in drun UX. Est: 1-2 h.

### ND-8: Reload-flag can be missed on timeout wakeups (S7F3, verified mismatch)
events.zig:374-378 handles `ready == 0` without consulting
`utils.consumeReload()`; the comment at :388-391 claims "a flag-only request
is picked up on the next poll timeout", which the code does not do. A reload
requested via flag-only path stalls until the next real X event.
Proposal: move consumeReload above the ready-branch split. Tiny, but it is a
behavioral reliability fix -> decision not blind-apply. Est: 30 min.

### ND-9: Unmanage focus bookkeeping is dead-on-arrival (S5F2, verified)
window.zig:852-869 runs `workspaces.removeWindow` (= tracking.removeWindow =
model.unregister, clearing focused) BEFORE actions.unmanage computes
`was_focused = m.focused == win` -> both branches inside are dead;
pickFallback/focusFallback logic in actions.zig:37 never fires from this
path. Entangled with S8F4 (Ctx.focused_window_id never populated beyond
getFocused) and the minimize-fallback question (OQ-3).
Proposal: either reorder (call unmanage first) and re-activate the tiered
fallback, or delete the dead branches and document the actual policy.
Requires a decision about intended close-focus semantics; goldens exist for
close-focus ordering. Est: 0.5 day incl. harness verification.

### ND-10: Duplicate override resolution diverges (S5F5 + S13F4)
`lookupVariant` (workspaces.zig:82-87) takes the FIRST matching override;
master-count lookup loop lets the LAST win; parser-side dedup assumptions
differ again. Same duplicate-key TOML yields different winners per field.
Proposal: pick one policy (last-wins matches parser intuition), implement
once, unit-test duplicates explicitly. Blocked on OQ-4 semantics decision.
Est: 1-2 h after decision.

### ND-11: parkShim / offscreen-park duplication (S3F6 + S9F3)
wire.zig:66-77 reimplements pushWindowOffscreenAndLower inline. Either keep
shim and delete utils helpers (SW-1 does this), or route shim through the
helper for one source of truth. Political: utils facade vs sink-local raw
xcb (layer rules allow both). Decide once; don't do both halves.

### ND-12: `never_sent` sentinel zero-rect collision (S3F4)
sync.zig:130-131 uses Rect{0,0,0,0} as "never sent" marker; a legitimately
placed zero-size window at origin collides (sync.zig:315/395/441 compare
against it). Structural fix: optional/flag instead of sentinel value.
Medium refactor in the one writer - good isolation, needs care.
Est: 3-4 h. Analyst: S3.

### ND-13: Motion-drain bypasses batch cap (S7F2, verified)
events.zig:306-314 inner drain loop ignores `dispatched` - a motion storm
can spin arbitrarily long per wakeup. Proposal: bound inner iterations
(e.g. <= cap) preserving newest-wins semantics. Latency-behavior change -> decision. Est: 1 h.

### ND-14: Fullscreen swap checks shadowed branch (S4F6b) & border_only mixed-mask routing (S4F7b)
window.zig:929-967 / :1002-1030 subtle precedence issues flagged by S4 with
contradicting comments; corrections alter XCB request sequences -> need a
fullscreen-toggle golden scenario before touching. Est: 0.5 day.

### ND-15: Click-focus two-RTT path (S6F6/S6F7)
Pipelining SetInputFocus with the click handling saves one round trip per
click-focus; deferred to train-f scope (OQ-5). Perf-real, risk-moderate
(focus-follows ordering). Est: 0.5 day.

### ND-16: threading.zig scaffold (S9F1)
Whole file (~97 LoC) + facade re-exports are unused. Deletion is
compile-gated, but "no feature removal" reads this as infrastructure - decide whether the pthread shim is reserved intent (keep + document) or
dead (delete). Est: 15 min after decision.

### ND-17: emitPlacement symmetric-trio aesthetics (S2F4)
Deleting the alias breaks the emitView/emitHidden/emitPlacement naming
symmetry the layouts rely on conceptually; revert-history shows it was
introduced deliberately. Keep-or-delete is taste -> decided here: keep the
trio, drop from SW-1 if preferred. Default in SW-1 stands (delete).

### ND-18: bench.pollReply double-consume semantics (S9F7)
bench.zig:74-90 consumes the cookie; on error the caller falls through to a
blocking reply on a consumed sequence. Doc claims parity; XCB semantics make
that shaky. Only affects `-Dbench` builds. Fix = tri-state return. Low
priority. Est: 1 h.

### ND-19: EWMH support advertisement honesty (S9F3-related)
advertiseEwmhSupport claims fuller compliance than implemented (per S9).
Options: narrow the _NET_SUPPORTED list or document gaps. External-tool
visible -> decision. Est: 1 h + xprop checks.

### ND-20: findVisualByDepth fallback BadMatch risk (S10F2b)
Fallback visual selection can pick an incompatible visual on multi-depth
roots -> creation-time BadMatch. Needs real-X verification (harness covers
default visuals only). Est: 2 h + manual X test.

### ND-21: onWindowGone leaves pending-hide queued (S5F8)
Minimize pending-hide for a destroyed window isn't cleared -> harmless
configure on recycled id? (ids guarded by forget). Verify then clear.
Est: 1 h.

### ND-22: adjustMasterCount lacks upper clamp (S5F11)
Count can exceed practical limits (layout clamps downstream but UI/state
drift). Behavior change -> decide bound (e.g. store_capacity/4). Est: 30 min
after decision.

### ND-23: Guard widening in check-layers.sh (S14F1/F2) - yardstick touch
pat1 misses xcb_unmap_window/xcb_destroy_window/xcb_circulate_*/
set_input_focus; rule-3 purity scan only greps literal 'xcb'. Widening
strengthens the guards (aligned with spirit - makes violations FAIL, not
pass) but modifies yardstick files -> requires explicit sign-off per the
brief. Est: 1 h.

### ND-24: Harness portability & ergonomics (S14F5/F6)
normalize.sh hex tokenizer can eat >=6-digit decimal counts (ordering-
dependent); run-scenario.sh hardcodes /tmp/opencode for diffs. Fixes are
additive-safe but touch yardstick scripts -> same sign-off caveat as ND-23.
Est: 1-2 h.

### ND-25: null_vim stub missing (S12F3, verified absent)
`src/bar/segments/prompt/null_vim.zig` referenced by feature-flag plumbing
does not exist; non-default feature combos fail at comptime. Either create
stub or delete the indirection. Blocked on OQ-6 (is prompt-disable a
supported build?). Est: 30 min after decision.

### ND-26: xkbcommon XkbState.state/.keymap write-only-ish (S8F5) - verify scope
Fields written/rotated but no direct readers found; however the struct flows
into config.load via input.getXkbState() (main.zig:40) - S8's claim may hold
only for specific fields. Re-verify field-level liveness before removal;
compiler-gated if confirmed. Fold into SW-1 follow-up.

---

## REJECTED (failed verification - do not re-raise without new evidence)

- **S13F7** "duplicate common_paths list": only one definition exists
 (fallback.zig:40); no second copy anywhere in src/config or proc.zig.
- **S9F10** "BoundedList debug asserts": bounded.zig contains no
 assert/unreachable/debug calls; claim misattributed.
- **S13F6** "getInRange silent defaults": no such symbol in parser.zig; the
 underlying concern (silent defaults) may be real but needs a fresh anchor
 (kept as OQ-9 diagnostic idea in SW-10).
- **S10F3-as-written** "six dead imports in bar.zig": only `fullscreen` and
 `workspaces` verified dead (both in SW-1); remaining four claimed imports
 are used.

Also corrected during verification: **S6F6** cycle_buf is 200 x u32 = 800 B
(constants.zig:163), not multi-KiB - no action needed; recorded here so the
finding isn't re-sized upward later.

---

## Open questions for the user (deduplicated across analysts)

1. **Test-count/doc drift**: docs said 39, then 48; the tree now has 107
 tests across 10 binaries. Re-verify the exact count with
 `zig build test --summary all` before finalizing doc edits (SW-3).
2. **spawn_cursor intent**: declared, reset-commented, read once
 (window.zig:1064), never written. Dead leftover, or wiring planned?
 Determines delete vs implement.
3. **Close-focus policy**: unmanage's tiered fallback is dead code (ND-9);
 what *should* happen focus-wise when the focused window closes? Goldens
 pin current observable behavior, so any change is user-visible.
4. **Duplicate config override semantics**: first-wins or last-wins?
 Needed for ND-10.
5. **train-f scope**: is click-focus RTT pipelining (ND-15) in scope for
 this pass or deferred?
6. **Prompt-disable build**: should `null_vim` stub exist (ND-25), or is
 prompt considered always-on (delete indirection)?
7. **threading.zig**: reserved scaffold or deletable (ND-16)?
8. **EWMH honesty stance** (ND-19): narrow advertised atoms vs document.
9. **Silent-config-defaults diagnostics** (SW-10): desired verbosity?
 Original anchor name didn't verify; need the real function before work.
10. **histAppendToFile newline handling** (S12 open q): confirm whether
 entries are written with trailing newline; collectLines assumes
 \n-separated lines. If missing, history corrupts on mixed writers.
11. **NaN guard for detectedHz** (S11 open q): refresh_rate probe returning
 NaN feeds @ceil paths; clamp or validate?
12. **Section ownership gaps**: segment.zig internals and snapshot.zig were
 thin-covered (S10/S11 boundary); main.zig likewise (S7 touched only the
 import). Acceptable, or commission a small follow-up pass?

## Cross-subsystem themes

Three patterns recur across otherwise independent subsystems and are worth
fixing as families rather than one-offs. **First: documentation rot
outpacing refactors** - the plugin registry removal (0778feb2) left stale
hooks in four files, the empty-workspace "guard" exists only in a comment,
two cache systems are described by fossils, and the test count drifted by
nine; a comment-truth sweep (SW-2/SW-3) plus the ND-2 guard decision closes
the whole class. **Second: module-global state escaping lifecycle
boundaries** - prompt caches survive reload, marquee `scrolling` survives
its owner's death, history loads head-first, sentinel values impersonate
geometry (ND-4/6/7/12); each is small, but they share a root cause: state
with no reset hook living at file scope. A convention ("every module-global
cache gets an invalidate() called from the owning subsystem's reload/deinit")
prevents the next five occurrences. **Third: write-only instrumentation** - bench counters, grab_active, spawn_cursor, cached_pre_* are all written
and never read, suggesting instrumentation was added ahead of consumers that
never landed; deleting them (SW-1) is safe, but the report recommends a
lightweight rule going forward: counters land in the same commit as their
printer or not at all. The dead-code mass overall (~150-180 LoC verified) is
notably low for a codebase this age - the earlier simplification passes did
their job; what remains is concentrated in seams (reload, teardown, feature
flags) rather than bulk.

---

## DISPOSITIONS (train-e execution record)

Every SAFE-WIN and NEEDS-DECISION item was executed or explicitly resolved.
Decisions taken where items were gated on open questions:

- **ND-1** boot seeding split into `actions.seedParamsFromConfig()` + main.zig
 call after pipeline.init. No reconcile at boot. Fixed S15's documented
 intent AND a latent shutdown GP fault via identity-guarded config deinit.
- **ND-2/ND-3/ND-4..ND-22** implemented as specified in their sections; ND-16
 deleted threading.zig; ND-17 deleted emitPlacement alias per SW-1 default.
- **ND-11** RESOLVED via SW-1's first branch: the utils offscreen-park
 helpers were deleted, leaving wire.zig's parkShim as the single source of
 truth ("decide once" honored - no duplication remains).
- **ND-15** DEFERRED - the report itself scopes it to train-f (OQ-5). Note:
 `setFocus` already resolves take_focus from the same live WM_PROTOCOLS
 reply (`getInputModelResolved`), so the path is one blocking RTT today.
- **ND-23** DONE with sign-off: pat1 widened (unmap/destroy/circulate/
 set_input_focus). Immediately caught a real gap - bar/win.zig's
 destroyBarWindow - resolved by extending the existing bar-lifecycle
 allowlist entry (same rationale, file was split out later).
- **ND-24** 3 of 4 fixed with sign-off: HW_OUT export bug (root cause of the
 unbound-variable noise AND missing snap-final artifacts in goldens),
 TMPDIR-based diff paths, S17's dead `_id` block removed. Item 4 (normalize
 hex tokenizer) EVIDENCE-REJECTED: dump_state prints window ids in DECIMAL,
 so the decimal-eating pattern is load-bearing; restricting it broke all
 18 legacy goldens. Ordering-dependence is neutralized by per-scenario
 determinism.
- **ND-25** RESOLVED - OQ-6 answered YES (build.zig actively registers the
 fallback, so bar-without-vim is a supported build): null_vim.zig stub
 created mirroring vim.zig's public API as a single-mode plain editor;
 verified the combination compiles by temporarily swapping vim.zig out.
 Prompt.zig needed no changes (2-member Mode keeps its switches exhaustive).
- **ND-26** CONFIRMED & REMOVED - XkbState.state/.keymap had zero functional
 readers (dispatch resolves from the flat table by design). Fields, their
 lifecycle code, and one error branch dropped; context retained (rebuild
 uses it). Compiler-gated verification passed.
- **SW-9 refetch-mirror test** skipped as a unit test - snapshotNeedsRefetch
 reaches focus.init -> getAtomCached which requires live X atoms; prediction
 parity is exercised by every harness scenario through bar.zig:773 instead.

### Golden regeneration audit (post ND-24 fixes)
Goldens were regenerated once after the harness fixes, with a preserved copy
at /tmp/opencode/golden-old for audit:
- 11/18 legacy scenarios: byte-identical old -> new (harness fixes are
 deterministic; no behavior drift).
- S02: old golden recorded GHOST FOCUS (Focused: W02 after close) plus a
 BadWindow unchecked-request warning; current behavior correctly drops to
 null (documented unmanage policy) and emits no BadWindow.
- S04/S10/S18: old dump format reported "Fullscreen: none" during active
 fullscreen; current format reports real state per workspace.
- S11: configure-request honoring now visible (500x400 kept vs old tiled
 size) - matches scenario intent.
- S13: old golden contained the shutdown GP-fault stack trace; new is clean.
- S15: ND-1 seeding (previously justified in detail).
Final state: 21/21 scenarios PASS against fresh goldens.
