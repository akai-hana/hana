# `focus.zig` — Pre-Refactor Issues Catalogue

All issues are grouped by category and ordered by severity within each group.
"Behaviour" is defined as the full observable effect on the X server, the XCB
connection queue, and all downstream module state.  No issue below changes
behaviour; every fix is a quality improvement only.

---

## Category A — Redundant / Inefficient XCB Usage

**A1. `wmHintsNeverFocus` issues a blocking round-trip on every FocusIn.**  
`handleFocusIn` calls `dwmSetFocus`, which calls `wmHintsNeverFocus`.
`wmHintsNeverFocus` fires `xcb_get_property` + `xcb_get_property_reply`
synchronously, stalling the event loop until the X server replies.  The
information it fetches — whether `WM_HINTS.input` is zero — is semantically
identical to `utils.getInputModelCached(conn, win) == .no_input`, which the
cache already holds for any managed window.  `handleFocusIn` is called on
every `FocusIn` event (which can arrive dozens of times per second during
window transitions); each call pays a full round-trip penalty for data that
is already cached.

**A2. `drainPendingConfirm` collects the reply in three separate branches.**  
There are three distinct early-exit paths (null `win`, invalid window,
`no_input` model) and each independently contains:
```zig
if (xcb.xcb_get_input_focus_reply(core.conn, cookie, null)) |r| std.c.free(r);
return;
```
The reply must always be drained regardless of which branch is taken.
Draining it once at the top of the function, before any branching logic,
eliminates the duplication and makes the invariant ("the cookie is always
consumed") immediately obvious.

**A3. `isWindowMapped` always makes a blocking `xcb_get_window_attributes` call.**  
`setFocus` guards `mouse_click` and `user_command` with `isWindowMapped`,
which fires `xcb_get_window_attributes` + a synchronous reply.  The call
site already contains a compile-time comment explaining that
`mouse_enter`, `window_spawn`, `tiling_operation`, and `workspace_switch`
are safe to skip.  However, the condition is expressed as an `if (switch
(...))` that evaluates `isWindowMapped` eagerly for every call and returns
`false` for most reasons, discarding the result without using it.  The
blocking call should be guarded by the `reason` check first so it is only
issued when the result is actually needed.

**A4. `beginPointerSync` drains a stale pointer reply synchronously.**  
When a previous `g_pointer_cookie` is pending, `beginPointerSync` drains it
with `xcb_query_pointer_reply` — a blocking call — to prevent queue growth.
For tiling operations that fire in rapid succession this re-introduces the
latency that the async split was meant to eliminate.  The correct pattern
is to store only the sequence number and let the reply expire naturally, or
to mark it as "superseded" so `drainPointerSync` discards it without
blocking.  (The current approach is safe but undoes the async benefit for
burst scenarios.)

---

## Category B — Structural / Spaghetti Logic

**B1. `dwmFocus` duplicates the full state-transition sequence from `commitFocusTransition`.**  
`dwmFocus` manually performs: history update → global-state write → button
grabs → tiling notify → carousel notify → bar redraw — the same seven steps,
in the same order, as `commitFocusTransition`.  Any future change to
`commitFocusTransition` (e.g. adding a new observer) must also be applied
manually to `dwmFocus`, or the two paths will silently diverge.
`dwmFocus` should express its distinctions (no `_NET_ACTIVE_WINDOW` update
via `dwmSetFocus` being called separately, suppress cleared) through
`CommitFlags` and delegate to `commitFocusTransition`.

**B2. `bruteForceMouseEnterFocus` duplicates the state-transition sequence a second time.**  
`bruteForceMouseEnterFocus` is a third independent copy of the same
seven-step transition, further complicated by an outer `if (g_focused_window
!= win)` guard that skips the state steps but not the X protocol sends.
This split — "conditionally update bookkeeping, always send protocol" — is a
legitimate semantic distinction, but it should be expressed by calling
`commitFocusTransition` for the bookkeeping half and then unconditionally
issuing the X calls, not by inlining a third copy.

**B3. Two hover-focus entry points (`dwmFocus` and `bruteForceMouseEnterFocus`) with overlapping responsibilities.**  
Both functions are called from `EnterNotify`-adjacent paths and both focus a
window on mouse-enter.  Their behavioural differences are subtle
(brute-force re-sends protocol when already focused; dwmFocus does not) and
require reading both function bodies to understand.  The current split
makes it unclear at the call site which path is correct for a given caller.
The two should be unified into a single entry point with a parameter or
collapsed into `setFocus(.mouse_enter)` with the relevant flag set.

**B4. `syncPointerFocusNow` passes a tautological `send_wm_take_focus` flag.**  
The flag is set to `input_model != .no_input`.  But two lines above, the
function already returns early when `input_model == .no_input`.  By the
time the flag expression is evaluated, `input_model` is guaranteed to not
be `.no_input`, so the expression always evaluates to `true`.  The intent
(send WM_TAKE_FOCUS for any focusable window) should be written as the
literal `true`, making it explicit and removing the false implication that
there is a conditional here.

**B5. `drainPendingConfirm` uses a labeled block as a quasi-`goto`.**  
The `confirm:` label combined with `break :confirm` is used to jump past the
retry block on success.  This pattern is legal Zig but it obscures the
control flow when reading top-to-bottom.  Extracting the reply-check and
retry into a small private `retryFocusIfNeeded(win, cookie)` helper with
normal early returns would make the logic easier to follow and test in
isolation.

**B6. `dwmSetFocus` has a misleading name and ambiguous ownership.**  
The function is called from both `dwmFocus` (which performs full WM
bookkeeping) and `handleFocusIn` (which performs no bookkeeping).  Its name
implies it is an internal implementation detail of `dwmFocus`, but its
primary responsibility is "send the X protocol atoms for focus" regardless
of bookkeeping.  A name like `sendFocusProtocol` would accurately describe
what it does and remove the DWM provenance from the API surface of the
module.

---

## Category C — Idiomatic Zig

**C1. `wmHintsNeverFocus` uses a raw `@ptrCast(@alignCast(...))` to index property data.**  
The function casts the return of `xcb_get_property_value` to `[*]const u32`
and indexes it manually.  Zig's `std.mem.bytesAsSlice` or
`std.mem.bytesToValue` would express the same read with explicit bounds and
alignment intent, and would catch misalignment in debug builds rather than
silently producing undefined behaviour.

**C2. The `if (xcb...) |r| std.c.free(r)` pattern is repeated six times.**  
The pattern of collecting an optional XCB reply and immediately freeing it
(used in `cancelPendingConfirm` and three branches of `drainPendingConfirm`
and two branches of `drainPointerSync`) is written out verbatim each time.
A two-line `inline fn drainAndFree(comptime T: type, cookie: T) void` helper
would eliminate the repetition and make the "drain without acting" intent
named and searchable.

**C3. `advertiseActiveWindow` takes a mutable local copy to obtain a pointer.**  
```zig
var val = win;
_ = xcb.xcb_change_property(..., 1, &val);
```
`win` is a `u32` parameter; creating a `var` copy to satisfy `xcb_change_property`'s
`*const anyopaque` data argument is unnecessary noise.  A `const` binding or
a pointer cast from the parameter directly avoids the mutation-implication of `var`.

**C4. `setFocus` uses a non-obvious `if (switch (...))` for the map-check guard.**  
```zig
if (switch (reason) {
    .mouse_click, .user_command => !isWindowMapped(core.conn, win),
    ...                         => false,
}) return;
```
The logic (return if the window is not mapped, but only for certain reasons)
reads more clearly as a standard `switch` with explicit early-return arms, or
as a named predicate `fn requiresMapCheck(reason: Reason) bool`.  The
current form looks like an error at a glance because the `if` condition is a
multi-line block.

**C5. `recordInHistory`'s `std.debug.assert` tests `g_focused_window != @as(?u32, win)`.**  
The explicit `@as(?u32, win)` coercion is needed because `g_focused_window`
is `?u32` and `win` is `u32`, but the intent of the assertion is to verify
that `win` is not the currently-focused window.  Writing it as
`std.debug.assert(g_focused_window != win)` with Zig's implicit optional
coercion is cleaner and communicates the same invariant without the cast
noise.

**C6. Module-level globals use inconsistent spacing/alignment style.**  
The `var` declarations at the top of the file use column-aligned `=` signs
in some blocks and left-aligned in others (compare `g_focused_window` /
`g_suppress_reason` / `g_last_event_time` against `g_history` /
`g_allocator`).  Consistent formatting throughout would match `zig fmt`
output and make diffs cleaner.

---

## Category D — Comments (Debugging Diary Artefacts)

**D1. "Improvement #N" labels appear throughout doc comments and inline comments.**  
`recordInHistory`, `commitFocusTransition`, `drainPendingConfirm`,
`syncPointerFocusNow`, and the `g_confirm_win` declaration all contain
comments like `// Improvement #2:`, `// Improvement #4:`, `// Improvement
#6:`, `// Improvement #15:`.  These are debugging-session breadcrumbs; they
carry no meaning for a future reader who does not have the debugging session
context.  All should be replaced with professional rationale comments.

**D2. `dwmSetFocus`'s doc comment and first function line both say the same thing.**  
The doc comment ends with `"// DWM's setfocus(c) — verbatim translation."` and
the very first line of the function body repeats it as a C-style block
comment.  The doc comment is the correct place; the duplicate inline comment
should be removed.

**D3. Inline `// DWM:` cross-reference comments in `commitFocusTransition` are leftover debug markers.**  
```zig
// DWM: XSetInputFocus(dpy, c->win, RevertToPointerRoot, CurrentTime)
// DWM: ev.xclient.data.l[1] = CurrentTime
```
These are correct rationale but expressed as file-local archaeology notes
rather than protocol explanations.  They should be rewritten to describe the
_why_ (CurrentTime bypasses the server's timestamp ordering check) rather
than citing the DWM source location.

**D4. `clearFocus` has a dangling DWM inline citation on a code line.**  
```zig
_ = xcb.xcb_set_input_focus(...); // CurrentTime — DWM: XSetInputFocus(...)
```
The comment mixes two things: a protocol note (`CurrentTime`) and a DWM
cross-reference.  These should be separate: the protocol note belongs as a
short comment; the DWM rationale, if kept at all, belongs in the function
doc comment.

**D5. `setFocus` flag comments are a mix of correct rationale and debug-era hedging.**  
The per-flag comments inside the `commitFocusTransition` call in `setFocus`
contain useful protocol rationale but are padded with observations like
"Attempt WM_TAKE_FOCUS for any focusable window, not just cached
locally_active/globally_active. sendWMTakeFocus now performs a live
WM_PROTOCOLS check..."  This is history about a bug fix, not an explanation
of why the flag is set.  The comments should be trimmed to state the
invariant being enforced, not the journey that led to it.

**D6. `recordInHistory` doc comment contains implementation change notes rather than a specification.**  
The block starting "The original code called removeFromHistory (scan +
orderedRemove, which shifts the tail left)..." documents a previous
implementation that no longer exists.  Future readers will never see the old
code, so the comparison adds noise without value.  The doc comment should
describe only the current algorithm and its complexity, not the prior one.
