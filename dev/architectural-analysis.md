Architectural analysis: tiling subsystem
Module boundary and ownership model

The subsystem splits across two files that have a genuine circular dependency: tiling.zig imports layouts.zig for LayoutCtx, CacheMap, and configureWithHints, while every layout module imports both layouts and tiling — specifically tiling.State. layouts.zig also defines Region, splitH, splitV, halveH, halveV, and toRect, which are not used by any layout module. The split is therefore not clean: layouts.zig carries infrastructure that half-belongs to a geometry utility layer that does not yet exist, and tiling.State functions as a god object that mixes rendering config, per-window tracking, scroll state, workspace validity bits, and a scratch buffer into one struct.
Critical flaws
1. Region is dead code — and it reveals a missing abstraction layer

layouts.zig defines a fully-realized Region struct with fromScreen, inset, splitH, splitV, halveH, halveV, and toRect. Not a single layout module calls any of these. Every module instead performs its own raw gap/border arithmetic inline. This is the most structurally damaging issue in the codebase because it simultaneously means:

    Duplication: All six layout modules have independent gap-stripping prologues, independent border subtraction at leaf nodes, and independent min-dimension fallbacks. A gap value change touches six files.
    Incoherence: The gap model is actually different across modules. master.zig uses gap/2 for the inner pane boundary. scroll.zig uses gap_half = gap/2 on interior slots but gap on edge slots. fibonacci.zig strips gap from both halves at each split step, so the effective inter-window gap compounds as the spiral deepens. leaf.zig strips the outer gap once at the top then adds one gap per recursive seam. These produce visibly different window-spacing results for the same gap_width setting.

Fix: Region is the right abstraction; make modules actually use it. Each layout's tileWithOffset should begin with:
zig

const r = layouts.Region.fromScreen(screen_w, screen_h, y_offset).inset(m.gap);

then call splitH/splitV/halveH/halveV for all subdivision. The border subtraction happens once in Region.toRect. Gap semantics become a single implementation — one gap at each seam, full gap on outer edges — and all six modules share it.
2. tiling.State is a god object

State owns: enabled flag, layout enum, prev_layout, layout variants, master side/width/count, gap and border pixel values, border colours, the full window tracking list, a dirty flag, enabled layouts array, ScrollState, workspace_geom_valid_bits, last_retile_area, CacheMap, and a scratch window buffer. This conflates at least four distinct responsibilities:

    Layout config (master_width, gap_width, border_width, border_focused, etc.)
    Window tracking (windows, is_dirty)
    Workspace geometry cache (cache, workspace_geom_valid_bits, last_retile_area, scratch_wins)
    Scroll runtime state (ScrollState)

Any function that needs to touch one of these concerns gets handed a *State and can touch all of them. retileImpl does not need access to ScrollState. snapScrollOffsetToWindow does not need access to border_focused. The god object creates invisible coupling and makes the type-checker unable to enforce concern separation.

Fix: Decompose State into typed sub-structs passed by pointer only where needed:
zig

pub const LayoutConfig = struct {
    layout: Layout, prev_layout: Layout,
    master_side: MasterSide, master_width: f32, master_count: u8,
    gap_width: u16, border_width: u16,
    border_focused: u32, border_unfocused: u32,
    layout_variants: LayoutVariants,
    enabled_layouts: [6]Layout, enabled_layout_count: u8,
};

pub const GeomCache = struct {
    cache: CacheMap,
    workspace_geom_valid_bits: u64,
    last_retile_area: utils.Rect,
    scratch_wins: [max_workspace_windows]u32,
};

pub const State = struct {
    is_enabled: bool, is_dirty: bool,
    config: LayoutConfig,
    tracking: tracking.Tracking,
    geom: GeomCache,
    scroll: ScrollState,
};

retileImpl takes *LayoutConfig and *GeomCache. invokeLayout takes *LayoutConfig. snapScrollOffsetToWindow takes only *ScrollState and *GeomCache.
3. All geometry uses integer arithmetic on u16 widths — no f32 geometry pipeline

master_width is an f32 ratio applied exactly once (in tileWithOffset for master) via @as(f32, @floatFromInt(screen_w)) * state.master_width. The result is immediately cast back to u16 and every subsequent subdivision is integer arithmetic. This means:

    Pixel-remainder distribution is ad-hoc in each layout. master.zig's windowHeight uses the cumulative formula ((i+1)*avail/count) - (i*avail/count), which is correct. leaf.zig's recursive halving uses (w - gap) / 2 with no remainder propagation — the second half always gets the rounding pixel but there is no guarantee remainders don't accumulate across recursion levels.
    The fibonacci spiral's (w.* -| gap) / 2 at each step compounds integer truncation. On a 1920-wide screen with gap=8, the first window gets 956px, the remainder is 956px. Second split: 474 and 474. But with gap=10: 955 and 955, then 472 and 473. The spiral dimensions drift in ways that depend on whether (w - gap) is even, and there is no systematic remainder accounting.

Fix: Represent all geometry internally as f32 throughout the layout pass. Convert to integers only at toRect time:
zig

pub const FRegion = struct {
    x: f32, y: f32, w: f32, h: f32,
    pub fn toRegion(r: FRegion) Region { ... } // single rounding step
    pub fn halveH(r: FRegion, gap: f32) struct { l: FRegion, r: FRegion } {
        const lw = (r.w - gap) / 2.0;
        return .{ .l = .{.x=r.x, .y=r.y, .w=lw, .h=r.h},
                  .r = .{.x=r.x+lw+gap, .y=r.y, .w=r.w-lw-gap, .h=r.h} };
    }
};

This eliminates all integer-division remainder bugs in one change, makes the spiral exact, and lets master_width be applied without a round-trip through float→int→float.
Major flaws
4. The gap model is incoherent across layouts

As described above, five layouts compute gaps differently. The visible result is that switching from master to grid to fibonacci with the same gap_width produces different-sized inter-window gaps. There is no single spec for what a "gap" means at the boundary between two windows.

The correct model: the gap between two adjacent windows is exactly gap_width pixels measured from one window's outer border edge to the next window's outer border edge. The outer screen edge margin is also gap_width. This gives a layout-independent visual contract. Region.splitH and splitV already implement this correctly. Using them everywhere solves this.
5. scroll.zig hardcodes slot width as screen_w / 2

The entire scroll layout is built around a fixed slot width of exactly half the screen. This is an unexplained magic number embedded as const slot_w: i32 = @intCast(screen_w / 2). There is no config key, no justification in comments. The consequence: on an ultrawide (3440px), each "slot" is 1720px — massively oversized. On a small monitor (1366px), slots are 683px — fine, but still arbitrary. The scroll offset snap (snapScrollOffsetToWindow) and the viewport calculations both depend on this constant, making the layout impossible to customize without touching source.

Fix: Expose scroll_slot_width in LayoutConfig as either a pixel value or a ratio of screen width, defaulting to 0.5. The slot calculation becomes:
zig

const slot_w: i32 = if (state.config.scroll_slot_ratio > 0)
    @intFromFloat(@as(f32, @floatFromInt(screen_w)) * state.config.scroll_slot_ratio)
else
    state.config.scroll_slot_px;

6. max_workspace_windows = 128 is a hard limit with silent truncation

collectWorkspaceWindows silently drops windows beyond index 128 with if (n >= buf.len) break. The user gets no indication that their 129th window on a workspace was dropped from the layout. The hasWindowBufCapacity function exists but is only called in moveWindowToIndex, not in collectWorkspaceWindows. The scratch buffer lives in State (BSS), so it cannot grow.

Fix: At minimum, log a warning on truncation inside collectWorkspaceWindows the same way hasWindowBufCapacity does. The deeper fix: replace the fixed BSS scratch buffer with a comptime upper bound that is validated and surfaced:
zig

const max_workspace_windows: usize = 256; // doubled; still BSS
// in collectWorkspaceWindows:
if (n >= buf.len) {
    debug.warn("workspace has >{} windows; excess dropped", .{buf.len});
    break;
}

Alternatively, since the tracking list has its own cap, compute max_workspace_windows from that cap to keep them in sync.
7. ICCCM min_size hint intentionally ignored — but tiling and floating are now inconsistent

applyHintsToRect intentionally skips Pass 1 (min-size enforcement) because "honouring it would pin the effective rect to the minimum on every retile, preventing mod_h/mod_l from resizing". The comment notes this matches floating behaviour. But floating drag does respect the X server's response — when you drag a window smaller than its min-size, the client resizes itself to its minimum and the resulting window is larger than the drag target. The WM does not reject the geometry. The tiling engine not enforcing the minimum means a terminal tiled into a very small slot might receive a geometry its min_size constraint prohibits, causing the X server to silently ignore the configure request and leaving the terminal at a stale geometry that does not match the cache.

Fix: Enforce min-size but account for it in the layout's available-space calculation. Before distributing space among N windows in a column, compute the total minimum space required and reduce available space accordingly, distributing the remainder. This is how dwm and i3 handle it.
8. CacheMap overflow sentinel is per-instance but shared within a single call chain

When count >= cache_capacity, getOrPut returns a pointer to self.overflow_sentinel. The comment correctly notes this is per-instance to avoid aliasing between different call sites. However, within a single retileImpl call, multiple windows could trigger the overflow — they all write to and receive a pointer to the same overflow_sentinel. The last writer wins. Earlier callers hold a now-stale pointer and their cache updates are silently discarded. Since configureWithHints does gop.value_ptr.border = color and gop.value_ptr.rect = effective, all overflow windows share a single cache entry. If two overflow windows have different border colours, the second write corrupts the first window's dedup state.

Fix: The capacity is 256 entries with a 512-slot table (load factor ≤ 0.5). In practice a WM managing 256+ windows per workspace is unusual, but the correct fix is to return a sentinel that indicates overflow rather than a shared writable slot:
zig

pub fn getOrPut(self: *CacheMap, win: u32) GetOrPutResult {
    // ... probe loop ...
    if (self.count >= cache_capacity) {
        debug.err("CacheMap: overflow for 0x{x}", .{win});
        // Return a fresh temporary on the caller's stack — impossible here since
        // we return a pointer. Use a per-call local in configureWithHintsImpl instead:
        return .{ .found_existing = false, .value_ptr = &self.overflow_sentinel, .is_overflow = true };
    }
    // ...
}

configureWithHintsImpl should check .is_overflow and skip the cache write, falling back to an unconditional XCB send. This prevents the aliased-write corruption.
Moderate flaws
9. fibonacci.zig stacks overflow windows at the same position

When w < gap*2 + border2 or h < gap*2 + border2, all remaining windows are placed at identical geometry via a loop for (windows[i..]) |overflow_win|. This means the 5th through Nth windows on a small screen are all stacked at the same coordinates with no visual differentiation — worse than monocle, which at least raises the top window. Users see one window and have no indication that more are hidden.

Fix: Fall through to monocle behaviour for overflow windows — use configureWithHintsAndRaise on the focused window, push the rest offscreen. Alternatively, forward the overflow slice to monocle's tileWithOffset directly.
10. grid.zig's calcGridShape special-cases n=3 but no other values

calcGridShape returns {cols:3, rows:1} for n=3 specifically. The comment says this avoids "a 2×2 grid with a dead cell." But n=5 produces a 3×2 grid with one dead cell, n=7 produces a 3×3 with two dead cells, n=10 produces a 4×3 with two dead cells — none of these are special-cased. The fix for n=3 is also inconsistent with n=4 (which produces a 2×2 with no dead cells — correct) and n=6 (which produces a 3×2 with no dead cells — also correct). The real issue is that the ceiling-sqrt algorithm always produces square or nearly-square grids, ignoring screen aspect ratio entirely. A 1920×1080 screen would benefit from more columns than rows.

Fix: Factor in screen aspect ratio:
zig

fn calcGridShape(n: usize, screen_w: u16, screen_h: u16) struct { cols: u16, rows: u16 } {
    const aspect: f32 = @as(f32, @floatFromInt(screen_w)) / @as(f32, @floatFromInt(screen_h));
    // cols/rows ≈ sqrt(n * aspect), rounded to minimize dead cells
    const cols_f = @sqrt(@as(f32, @floatFromInt(n)) * aspect);
    var cols: u16 = @max(1, @intFromFloat(@round(cols_f)));
    var rows: u16 = @intCast((n + cols - 1) / cols);
    // Tighten: reduce cols if doing so eliminates dead cells without changing rows
    while (cols > 1 and (cols-1)*rows >= n) cols -= 1;
    return .{ .cols = cols, .rows = rows };
}

11. master.zig uses f32 for master_width ratio but converts to u16 immediately, discarding sub-pixel precision on every adjustMasterWidth call

adjustMasterWidth accumulates ±0.025 steps in f32. The width is applied as @as(f32, @floatFromInt(screen_w)) * state.master_width → @intFromFloat(...) → u16. For a 1920-wide screen, 0.025 steps produce 48px increments — acceptable. But at 1280px, 0.025 produces 32px — still coarse but tolerable. The issue is that after ~40 steps the f32 accumulation is 1.0 even though max_master_width_ratio = 0.95 should clamp it — but the clamp is applied correctly in adjustMasterWidth. The real problem is that master_width persists its f32 value but the layout renders a pixelated integer version, so two very close ratios (0.500 and 0.501) may render identically, making adjustMasterWidth feel like it "skips" visually.

This is the correct place to move to the f32 geometry pipeline (flaw #3). Once geometry stays in f32 through subdivision, master_width applies without precision loss.
12. monocle.zig scans the window list twice for top_win

pushBackgroundWindowsOffscreen iterates all windows. The focused-window search in tileWithOffset also iterates all windows. These are two separate O(n) scans on the same slice. For typical workspace sizes (5–15 windows) this is negligible but the pattern is inconsistent with the rest of the codebase, which goes to considerable effort to fuse scans (see findFocusMasterPos using a single fused O(n) pass for three values).

Fix: Single pass — find top_win index during the initial scan, then iterate the list once marking non-top windows for offscreen push.
13. workspace_geom_valid_bits is a u64 — hard limit of 64 workspaces

max_workspaces = 64 is enforced by the u64 bitmask width. The tracking module's workspace count is a separate value. If the user configures more than 64 workspaces, markWorkspaceGeomValid silently does nothing for workspaces ≥64 (the if (ws_idx < max_workspaces) guard), meaning their geometry cache is never marked valid and every switch to those workspaces forces a full retile. This is correct but silent — there is no warning that cache validation is disabled for high-index workspaces.

Fix: Use a std.bit_set.IntegerBitSet(max_workspaces) which makes the 64-workspace limit explicit in the type, or replace with a u128 and double the limit. More correctly, decouple the validity tracking from the bitmask entirely:
zig

// Per-workspace validity array — zero-cost for up to 255 workspaces
workspace_geom_valid: [max_workspaces]bool = [_]bool{false} ** max_workspaces,

This is 64 bytes of BSS vs. 8 bytes, but removes the arbitrary 64-workspace ceiling without changing any call sites.
14. scroll.zig has a dead branch in the offscreen-parking logic
zig

if (x >= sw_i32 or right <= 0) {
    if (x < I16_MIN or x > I16_MAX) {
        // raw xcb call, bypasses cache
    } else {
        // uses defer_slot — but this is inside the "offscreen" branch
    }
    continue;
}

The inner else branch places a window that is off-screen but within i16 range using the normal defer_slot path with the window's actual computed offscreen coordinates. This means the cache receives an "onscreen" rect (within i16 range) for a window the user cannot see. On the next retile, if the scroll offset changes slightly and this window comes into view, its cached position matches the computed position exactly — cache hit, no XCB send. This is correct behaviour, but it means the "park offscreen" comment is misleading: the window is not parked at a sentinel; it is placed at its real computed position which happens to be outside the visible area. The path that hits I16_MIN/MAX also bypasses the DeferredConfigure mechanism and the normal cache, directly calling xcb_configure_window and then writing zero_rect to the cache. This inconsistency between the two sub-paths creates a subtle state divergence.

Fix: Unify both cases under the normal defer_slot path. The i16 overflow guard should clamp the x coordinate to OFFSCREEN_X_POSITION and enter the normal path rather than bypassing it. The cache inconsistency is then impossible by construction.
Minor flaws
15. DeferredConfigure.init ignores its argument
zig

pub inline fn init(_: *const LayoutCtx) DeferredConfigure { return .{}; }

The ctx parameter is accepted and immediately discarded. The deferred window check only happens inside capture. This means the init function is misleading — it suggests the slot is initialized from context, but it always produces an inert empty slot. The signature creates a fake dependency. Remove the parameter: pub inline fn init() DeferredConfigure { return .{}; }.
16. retileAllWorkspaces is O(workspaces × all_windows), not noted at call sites

The comment in retileAllWorkspaces acknowledges this tradeoff but the function is called from workspace-switch paths which also call retileCurrentWorkspace — meaning the current workspace is tiled twice in a workspace switch. The per-inactive-workspace retile involves re-calling collectWorkspaceWindows for each workspace, which iterates the full s.windows.items() list each time. With 64 workspaces and 128 windows, this is 64 × 128 = 8,192 iterations of the window list. In practice, most workspaces are empty — if (n == 0) continue short-circuits — but worst-case is genuinely O(W × N).

Fix: Build a single workspace→window multimap in one O(N) pass at the start of retileAllWorkspaces, then iterate that map per workspace. Total cost: O(N + W) instead of O(W × N).
17. applyHintsToRect runs floating-point aspect ratio code on every retile for windows that have no aspect hints
zig

if (h.min_aspect > 0.0 and h.max_aspect > 0.0) {
    const fw: f32 = @floatFromInt(w);
    // ...
}

The guard is correct. But applyHintsToRect is called for every window on every retile. For windows with hints = .{} (the default — all zeros), the inc_width == 0 and inc_height == 0 checks in snapDimToIncrement return early, and the aspect guard is false. The function is effectively a series of guarded no-ops. This is fine — the compiler should optimize this to near zero. But isEmptySizeHints exists and is called in cacheHints — it is not called before applyHintsToRect. An early return for the all-zeros case would make the zero-hint path a single branch:
zig

fn applyHintsToRect(rect: utils.Rect, h: SizeHints) utils.Rect {
    if (isEmptySizeHints(h)) return rect; // fast path for unconstrained windows
    // ... hint logic ...
}

18. scroll.zig's prev_n comparison for new-window snap is fragile
zig

if (n > state.scroll.prev_n) {
    state.scroll.offset = max_off;
}
state.scroll.prev_n = n;

If two windows are added in the same retile cycle (e.g., a terminal launches a child window before the first retile), n > prev_n fires once for the net change. This is fine. But if a window is added and a different window is simultaneously removed (net count unchanged), n == prev_n and the new window is not snapped to. The new window could be anywhere in the list order depending on LIFO/FIFO, and the user would not see it. The correct trigger is not n > prev_n but rather "a new window was added to the scroll layout since the last retile" — which requires tracking the window ID, not just the count.
19. enabled_layouts vs layout_cycle — two parallel sources of truth for layout ordering

layout_cycle is a comptime constant slice of all available layouts. enabled_layouts is a runtime array parsed from config. stepLayout uses enabled_layouts if non-empty, else falls back to layout_cycle. isLayoutAvailable checks comptime build flags. parseEnabledLayouts filters by both config order and isLayoutAvailable. This means there are three different orderings a layout can appear in, and stepLayout's fallback to layout_cycle produces a different traversal order than the config-specified enabled_layouts. If the user's config specifies layouts = ["fibonacci", "master", "grid"] but the config parsing fails to produce enabled_layouts (unlikely but possible if all names are misspelled), the fallback silently uses layout_cycle order (master, monocle, grid, fibonacci, leaf, scroll) — a different sequence with different layouts.

Fix: Remove the fallback. If parseEnabledLayouts produces an empty list, use layout_cycle as the default at init time, storing it into enabled_layouts. stepLayout then only ever consults enabled_layouts, eliminating the dual-path.
Structural recommendations (drastic)
A. Replace the tileWithOffset signature with a LayoutInput struct

Every layout module receives six positional parameters:
zig

fn tileWithOffset(ctx, state, windows, screen_w, screen_h, y_offset)

A Region already encodes (x=0, y=y_offset, w=screen_w, h=screen_h). The ctx contains the cache and connection. state is the god object. The right signature is:
zig

pub fn tile(ctx: *const LayoutCtx, config: *const LayoutConfig, windows: []const u32, area: Region) void

This passes only what the layout actually needs: the rendering context, the config it reads (gap, border, master_width, variants), the window list, and the screen area. State is not passed — layouts have no reason to touch scroll state, workspace bits, or the tracking list. The comptime signature verification in tiling.zig ensures all modules conform, so this is a safe drastic change.
B. Move the geometry cache out of the hot path and into a write-behind structure

Currently configureWithHints does a CacheMap.getOrPut on every window on every retile. For N windows on a workspace, that is N hash probes per retile, N XCB rect comparisons, and N border color comparisons. The cache is write-through: every geometry change is immediately reflected. A write-behind model would batch cache updates and apply them after the layout completes, allowing the layout to operate on pure geometry without touching the hash table at all:
zig

// Layout produces a []const WindowGeom slice (win + rect pairs)
// A post-pass compares against CacheMap in bulk and emits only XCB calls for changes
// This decouples the layout algorithm from the XCB emission entirely

This also enables a clean testing model: the layout function becomes a pure geometry computation that can be tested without an XCB connection.
C. Make layouts return geometry slices, not emit XCB directly

The deepest architectural flaw is that layout modules are impure — they reach through ctx to call xcb_configure_window. This makes them untestable without a live X connection or a mock, prevents deferred batching, and mixes geometry computation with protocol emission. The correct model:
zig

// Layout outputs into a caller-supplied buffer
pub fn tile(config: *const LayoutConfig, windows: []const u32, area: Region, out: []WindowGeom) usize
// tiling.zig collects all outputs, applies hints, deduplicates against cache, emits XCB

DeferredConfigure disappears because ordering is controlled by the caller during the emit pass, not by each layout module independently. configureWithHintsImpl becomes a single post-pass function rather than being called N times during layout. The Region-based geometry pipeline (recommendations A + C combined) would reduce the total code in all six layout modules by roughly 40% while making them pure, testable, and gap-model-consistent.

