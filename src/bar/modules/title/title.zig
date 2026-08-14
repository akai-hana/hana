//! Title bar segment
//! Displays the focused window title on the status bar, with a split view when minimized windows are present.

const std = @import("std");

const core = @import("core");
const xcb = core.xcb;
const utils = @import("utils");
const scale = @import("scale");
const debug = @import("debug");

const constants = @import("constants");
const bench = @import("bench");

const types = @import("types");

const drawing = @import("drawing");
const carousel = @import("carousel");
const tiling = @import("tiling");

// Module constants

/// Fixed left indent applied inside every title cell, independent of
/// `scaledSegmentPadding`.  Provides visual breathing room between the
/// segment edge and the title text.
const title_lead_px: u16 = 4;

/// Maximum number of windows rendered in split-view.
/// Stack-allocated arrays in `drawSegmentedTitles` are bounded by this value.
/// Windows beyond this index are silently omitted from the bar.
/// 128 covers any practical workspace size while keeping stack usage bounded.
const max_visible_windows: usize = 128;

/// Maximum windows addressed by the batch pre-fetch scratch arrays at once.
/// `bar.captureStateIntoSlot` hands over the full workspace list, bounded by
/// `constants.Limits.MAX_TILED_WINDOWS` — larger than `max_visible_windows`,
/// as the snapshot carries a title/geometry entry per window regardless.
const max_batch_windows: usize = constants.Limits.MAX_TILED_WINDOWS;

/// Off-screen sentinel geometry for minimized or otherwise unresolvable
/// windows: position sorting places it last, and drawing is skipped.
pub const offscreen_rect: utils.Rect = .{ .x = std.math.maxInt(i16), .y = std.math.maxInt(i16), .width = 0, .height = 0 };

// Atom cache

const Atoms = struct {
    /// null until successfully resolved, to avoid XCB_ATOM_NONE's sentinel (0).
    net_wm_name: ?u32 = null,
    utf8_string: ?u32 = null,
    is_initialized: bool = false,

    /// Resolves and caches the X11 atoms needed for title fetching.
    /// Subsequent calls are a no-op.
    fn ensureResolved(self: *Atoms) void {
        if (self.is_initialized) return;
        self.is_initialized = true;
        self.net_wm_name = utils.getAtomCached("_NET_WM_NAME") catch null;
        self.utf8_string = utils.getAtomCached("UTF8_STRING") catch null;
    }

    /// Returns the UTF-8 atom when available, falling back to XCB_ATOM_STRING.
    inline fn utf8AtomType(self: *const Atoms) u32 {
        return self.utf8_string orelse xcb.XCB_ATOM_STRING;
    }
};

var atoms: Atoms = .{};

// Internal types

const WindowInfo = struct {
    window: u32,
    x: i16,
    y: i16,
    title: []const u8,
    minimized: bool,
};

// Public input types

/// Stable per-call rendering context: geometry, draw state, connection, and
/// (on the `draw()` path) the bar slot's title cache.
///
/// Constructed once per bar frame and shared between `draw()` and
/// `drawCached()`. `cached_title`/`cached_title_window` stay null on the
/// `drawCached()` path, which never updates the cache — only `draw()` passes
/// them. Folding the cache fields in avoids a separate `TitleCache` struct
/// every caller would otherwise have to construct and pass.
pub const TitleRenderContext = struct {
    dc: *drawing.DrawContext,
    config: types.BarConfig,
    height: u16,
    start_x: u16,
    width: u16,
    conn: *xcb.xcb_connection_t,

    /// Backing buffer updated by `draw()` on each full render; the bar passes
    /// its contents as `snapshot.focused_title` in subsequent `drawCached()`
    /// calls. Null on the `drawCached()` path (read-only; no cache update).
    cached_title: ?*std.ArrayListUnmanaged(u8) = null,
    /// Window ID `cached_title` was fetched for; used to detect when
    /// `focused_title` belongs to a new window. Null alongside `cached_title`.
    cached_title_window: ?*?u32 = null,
};

/// Per-frame volatile snapshot captured before drawing.
///
/// `focused_title` and `minimized_title` must be pre-fetched via
/// `fetchWindowTitleInto` before `draw()` runs, so `draw()` itself never
/// issues X11 property fetches.
///
/// `minimized_title` is used only in the single-window-minimized case; pass an
/// empty slice when that case can't occur (e.g. the `drawCached` fast path).
pub const TitleSnapshot = struct {
    focused_window: ?u32,
    focused_title: []const u8,
    minimized_title: []const u8,
    current_ws_wins: []const u32,
    minimized_set: *const std.AutoHashMapUnmanaged(u32, void),

    /// Pre-fetched window titles, indexed parallel to `current_ws_wins`
    /// (`titles[i]` is the title of `current_ws_wins[i]`). Empty when no
    /// pre-fetched data is available (e.g. the drawCached fast path before the
    /// title cache has multi-window data).
    titles: []const []const u8 = &.{},

    /// Pre-fetched window geometry (see `fetchWindowGeom`), indexed like
    /// `titles`. Non-blocking fallback for windows the tiling cache doesn't
    /// cover (e.g. floating), so this path — including the drawCached fast
    /// path on the carousel thread — never issues an xcb_get_geometry
    /// round-trip. Empty means no pre-fetched data; fall back to live.
    geoms: []const utils.Rect = &.{},
};

// Title width cache

/// Bounded cache of measured title text widths, indexed by window ID.
///
/// `drawSegmentedTitles` used to re-measure every visible segment on every
/// call — including the `drawCached()` fast path, which can run once per
/// carousel tick — but most segments' text doesn't change between ticks, so
/// that was wasted Pango/cairo work. Mirrors the text_w recovery
/// `carousel.drawScrollingTitle` does for the single-window case, generalised
/// to the N-window split view.
///
/// A hit requires both the window ID and the title slice's identity (pointer +
/// length) to match what was measured; anything else falls back to a fresh
/// measurement, so a stale entry costs an extra measurement, never a wrong
/// width.
const TitleWidthCache = struct {
    const Entry = struct {
        window: u32,
        title_ptr: [*]const u8,
        title_len: usize,
        width: u16,
    };

    /// Direct storage, not a hash map: bounded by `max_visible_windows` and
    /// process-lifetime, so no per-frame alloc/init cost. A linear scan is
    /// fine at realistic window counts — even the 128-window worst case is
    /// far cheaper than the Pango call it replaces.
    entries: [max_visible_windows]?Entry = @splat(null),

    fn widthFor(self: *TitleWidthCache, dc: *drawing.DrawContext, window: u32, title: []const u8) u16 {
        var free_slot: ?usize = null;
        for (&self.entries, 0..) |*slot, i| {
            if (slot.*) |e| {
                if (e.window == window) {
                    if (e.title_ptr == title.ptr and e.title_len == title.len) return e.width;
                    const w = dc.measureTextWidth(title);
                    slot.* = .{ .window = window, .title_ptr = title.ptr, .title_len = title.len, .width = w };
                    return w;
                }
            } else if (free_slot == null) {
                free_slot = i;
            }
        }
        // No entry for this window: measure and store in a free slot, or
        // evict slot 0 if full (only when `max_visible_windows` are visible —
        // more misses, still correct).
        const w = dc.measureTextWidth(title);
        self.entries[free_slot orelse 0] = .{ .window = window, .title_ptr = title.ptr, .title_len = title.len, .width = w };
        return w;
    }
};

var title_width_cache: TitleWidthCache = .{};

// Private helpers

/// Extract a UTF-8 string from an XCB get_property reply and dupe it into
/// `allocator`. Returns null when the reply carries no bytes. Shared by
/// Phase 2 and Phase 3 of drawSegmentedTitles instead of duplicating an
/// identical three-line extract-and-dupe block in each.
fn extractPropertyString(
    r: *xcb.xcb_get_property_reply_t,
    allocator: std.mem.Allocator,
) !?[]const u8 {
    const len = xcb.xcb_get_property_value_length(r);
    if (len == 0) return null;
    const ptr: [*]const u8 = @ptrCast(xcb.xcb_get_property_value(r));
    return try allocator.dupe(u8, ptr[0..@intCast(len)]);
}

/// Shared body for draw() and drawCached(). `ctx.cached_title` is non-null
/// only on the draw() path, so this works unmodified for both callers.
fn drawInner(
    ctx: TitleRenderContext,
    snapshot: TitleSnapshot,
    allocator: std.mem.Allocator,
    title_invalidated: bool,
) !u16 {
    scale.ensureRefreshRateDetected(ctx.conn);
    const window_count = snapshot.current_ws_wins.len;
    if (emptyWorkspace(ctx, window_count)) |end_x| return end_x;

    if (window_count == 1) {
        try drawSingleWindow(ctx, snapshot, allocator, title_invalidated);
    } else {
        try drawSegmentedTitles(ctx, snapshot, allocator, title_invalidated);
    }

    return ctx.start_x + ctx.width;
}

// Public API — draw entry points

/// Draw the title segment.
///
/// Updates `ctx.cached_title`/`ctx.cached_title_window` so `drawCached()` has
/// a valid slice next tick; caller must set both non-null (see
/// `TitleRenderContext`). `title_invalidated` must be true when the focused
/// window's title changed since the last draw.
pub fn draw(
    ctx: TitleRenderContext,
    snapshot: TitleSnapshot,
    allocator: std.mem.Allocator,
    title_invalidated: bool,
) !u16 {
    return drawInner(ctx, snapshot, allocator, title_invalidated);
}

/// Draw the title segment using already-cached state.
///
/// Called from a fast-path redraw (focus-only or carousel tick) on the main
/// thread (scheduleFocusRedraw) or the carousel thread, serialized by
/// bar.zig's draw_mutex. Unlike `draw()`, this function:
///   - uses `snapshot.focused_title` as a read-only slice (the caller passes
///     the bar slot's cached buffer contents).
///   - never updates the title cache: `ctx.cached_title`/`cached_title_window`
///     must be left null (`draw()` keeps the cache current).
///   - always passes `title_invalidated = false` — it only re-renders existing
///     state.
///   - passes `minimized_title = ""` (the minimized title isn't cached by the
///     bar slot; the full `draw()` path handles it).
pub fn drawCached(
    ctx: TitleRenderContext,
    snapshot: TitleSnapshot,
    allocator: std.mem.Allocator,
) !u16 {
    return drawInner(ctx, snapshot, allocator, false);
}

// Public API — click hit-testing

/// A window resolved from a click inside the title segment, along with
/// whether it was minimized at the time of the click.
pub const ClickTarget = struct {
    window: u32,
    minimized: bool,
};

/// Resolves which window (if any) is displayed at `offset_x` pixels into the
/// title segment — relative to the segment's start_x (`click_x - ctx.start_x`,
/// in `[0, ctx.width)`).
///
/// Handles both single-window and split-view layouts: split-view replicates
/// the exact sort order and pixel-perfect tiling `drawSegmentedTitles` uses,
/// so the click resolves to whichever window's title is visually under the
/// cursor. Built from the bar's cached title state like `drawCached`/
/// `drawTitleOnly`, this makes no blocking X11 round-trip when the cache is
/// populated; a miss falls back to the same live calls `drawSegmentedTitles`
/// would make.
///
/// Returns null when the segment shows no window (empty workspace) — callers
/// distinguish "clicked an empty title segment" from "clicked a window's".
pub fn hitTest(
    ctx: TitleRenderContext,
    snapshot: TitleSnapshot,
    allocator: std.mem.Allocator,
    offset_x: u16,
) !?ClickTarget {
    const windows = snapshot.current_ws_wins;
    if (windows.len == 0) return null;

    if (windows.len == 1) {
        const win = windows[0];
        return .{ .window = win, .minimized = snapshot.minimized_set.contains(win) };
    }

    if (ctx.width == 0) return null;
    const win_count = @min(windows.len, max_visible_windows);

    // Same outlive requirement as drawSegmentedTitles: a WindowInfo's
    // `.title` may point into `owned_titles`' memory.
    var window_info_buf: [max_visible_windows]WindowInfo = undefined;
    var owned_titles: [max_visible_windows]?[]const u8 = undefined;
    for (owned_titles[0..win_count]) |*t| t.* = null;
    defer for (owned_titles[0..win_count]) |t| if (t) |s| allocator.free(s);

    const info_count = try gatherWindowInfos(ctx, snapshot, allocator, windows[0..win_count], &window_info_buf, &owned_titles);
    if (info_count == 0) return null;

    // Same sort as drawSegmentedTitles, so segment index i corresponds to the
    // same on-screen position: [i*W/n, (i+1)*W/n).
    const window_infos = window_info_buf[0..info_count];
    std.mem.sort(WindowInfo, window_infos, {}, compareWindows);

    const n: u32 = @intCast(window_infos.len);
    // Inverse of the pixel-perfect tiling formula drawSegmentedTitles uses
    // (x0(i) = floor(i*W/n)): floor(offset*n/W) lands in the same segment.
    const idx: usize = @intCast(@min(n - 1, @divFloor(@as(u32, offset_x) * n, @as(u32, ctx.width))));
    const info = window_infos[idx];
    return .{ .window = info.window, .minimized = info.minimized };
}

// Public API — title pre-fetch (main thread only)

/// Fetch the title of `win` into `buf`, reusing its existing capacity.
///
/// Must be called on the MAIN THREAD — used for focused and minimized windows
/// so drawing never makes blocking X11 round-trips itself.
///
/// `bar.captureStateIntoSlot` calls this once for the focused window and, when
/// the workspace has exactly one minimized window, once for it — storing the
/// results in `TitleSnapshot.focused_title`/`minimized_title`.
pub fn fetchWindowTitleInto(
    conn: *xcb.xcb_connection_t,
    win: u32,
    buf: *std.ArrayListUnmanaged(u8),
    allocator: std.mem.Allocator,
) !void {
    atoms.ensureResolved();
    const utf_type = atoms.utf8AtomType();

    if (atoms.net_wm_name) |na| {
        if (utils.fetchPropertyToBuffer(conn, win, na, utf_type, buf, allocator) catch null) |t| {
            if (t.len > 0) return;
        }
    }
    _ = utils.fetchPropertyToBuffer(
        conn,
        win,
        xcb.XCB_ATOM_WM_NAME,
        xcb.XCB_ATOM_STRING,
        buf,
        allocator,
    ) catch {};
}

/// Fetch the geometry of `win`, preferring the tiling cache (zero round-trips)
/// and falling back to a blocking xcb_get_geometry on a miss; returns an
/// offscreen sentinel if the reply can't be read.
///
/// Must be called on the MAIN THREAD (same contract as `fetchWindowTitleInto`).
/// Called once per non-minimized workspace window so `drawSegmentedTitles` —
/// including the carousel-thread `drawCached` fast path — never issues its own
/// xcb_get_geometry for windows the tiling cache doesn't cover.
pub fn fetchWindowGeom(conn: *xcb.xcb_connection_t, win: u32) utils.Rect {
    if (tiling.getWindowGeom(win)) |cached| return cached;
    return collectGeometryReply(conn, xcb.xcb_get_geometry(conn, win));
}

/// Collect the reply for a fired `xcb_get_geometry` request without a blocking
/// wait when the reply is already buffered (see `bench.pollReply`). In a
/// non-bench build this reduces to a single blocking reply call.
fn collectGeometryReply(conn: *xcb.xcb_connection_t, cookie: xcb.xcb_get_geometry_cookie_t) utils.Rect {
    if (bench.pollReply(conn, cookie.sequence)) |rep| {
        const r: *xcb.xcb_get_geometry_reply_t = @ptrCast(@alignCast(rep));
        defer std.c.free(r);
        return geometryFromReply(r);
    }
    const r = xcb.xcb_get_geometry_reply(conn, cookie, null) orelse return offscreen_rect;
    defer std.c.free(r);
    return geometryFromReply(r);
}

fn geometryFromReply(r: *xcb.xcb_get_geometry_reply_t) utils.Rect {
    return .{
        .x = @intCast(r.*.x),
        .y = @intCast(r.*.y),
        .width = r.*.width,
        .height = r.*.height,
    };
}

/// Batch pre-fetch of title and geometry for every window in `wins`, writing
/// one entry per window into `out_titles`/`out_geoms` in parallel order.
/// Replaces the sequential `fetchWindowTitleInto` + `fetchWindowGeom` loop in
/// `bar.captureStateIntoSlot`.
///
/// Same Phase 1-3 cookie-batching as `gatherWindowInfos`: all X11 requests are
/// fired before any reply is collected, so N windows cost ~2 round-trips
/// (plus one per window needing a `WM_NAME` fallback) instead of up to 2N
/// blocking waits.
///
/// `focused_idx` is the focused window's index; its already-fetched
/// `focused_title` is duped in with no X11 traffic. Geometry prefers the
/// tiling cache; minimized windows get the `offscreen_rect` sentinel; only
/// cache-missing, non-minimized windows get a batched get_geometry.
///
/// Each title dupe is owned by `out_titles`, allocated from `title_allocator`
/// (the caller's per-batch arena); freed in bulk via `WindowTitles.clear`.
pub fn batchFetchWindowInfosInto(
    conn: *xcb.xcb_connection_t,
    wins: []const u32,
    focused_idx: ?usize,
    focused_title: []const u8,
    minimized: *const std.AutoHashMapUnmanaged(u32, void),
    out_titles: *std.ArrayListUnmanaged([]const u8),
    out_geoms: *std.ArrayListUnmanaged(utils.Rect),
    title_allocator: std.mem.Allocator,
    allocator: std.mem.Allocator,
) void {
    const win_count = wins.len;
    std.debug.assert(win_count <= max_batch_windows);

    atoms.ensureResolved();
    const net_atom = atoms.net_wm_name;
    const utf_type = atoms.utf8AtomType();

    var net_wm_cookies: [max_batch_windows]xcb.xcb_get_property_cookie_t = undefined;
    var fallback_cookies: [max_batch_windows]xcb.xcb_get_property_cookie_t = undefined;
    var needs_fallback: [max_batch_windows]bool = undefined;
    var owned_titles: [max_batch_windows]?[]const u8 = undefined;
    var geom_cookies: [max_batch_windows]xcb.xcb_get_geometry_cookie_t = undefined;
    var needs_xcb_geometry: [max_batch_windows]bool = undefined;
    var tiling_geoms: [max_batch_windows]?utils.Rect = undefined;

    // Phase 1 — fire every request up front: _NET_WM_NAME for windows whose
    // title isn't already known, get_geometry for windows the tiling cache
    // doesn't cover. Minimized windows are skipped — never positioned on screen.
    for (wins, 0..) |win, i| {
        const is_focused = focused_idx == i;
        if (net_atom != null and !is_focused)
            net_wm_cookies[i] = xcb.xcb_get_property(conn, 0, win, net_atom.?, utf_type, 0, 8192);

        needs_xcb_geometry[i] = false;
        tiling_geoms[i] = null;
        if (!minimized.contains(win)) {
            tiling_geoms[i] = tiling.getWindowGeom(win);
            if (tiling_geoms[i] == null) {
                geom_cookies[i] = xcb.xcb_get_geometry(conn, win);
                needs_xcb_geometry[i] = true;
            }
        }
    }

    // Phase 2 — collect _NET_WM_NAME replies; queue WM_NAME fallbacks.
    for (wins, 0..) |win, i| {
        owned_titles[i] = null;
        needs_fallback[i] = false;
        if (focused_idx == i) continue;
        got: {
            if (net_atom != null) {
                owned_titles[i] = collectPropertyReply(conn, net_wm_cookies[i], title_allocator);
                if (owned_titles[i] != null) break :got;
            }
            fallback_cookies[i] = xcb.xcb_get_property(conn, 0, win, xcb.XCB_ATOM_WM_NAME, xcb.XCB_ATOM_STRING, 0, 8192);
            needs_fallback[i] = true;
        }
    }

    // Phase 3 — collect WM_NAME fallback replies.
    for (wins, 0..) |_, i| {
        if (focused_idx == i or !needs_fallback[i]) continue;
        owned_titles[i] = collectPropertyReply(conn, fallback_cookies[i], title_allocator);
    }

    // Build parallel output lists, collecting geometry as we go.
    for (wins, 0..) |win, i| {
        if (focused_idx == i) {
            // Duped like every other title: `focused_title` lives in the
            // snapshot's separate buffer, freed independently of
            // window_titles — an alias would dangle once that deinit's.
            const owned = title_allocator.dupe(u8, focused_title) catch null;
            if (owned) |t|
                out_titles.append(allocator, t) catch {}
            else
                out_titles.append(allocator, "") catch {};
        } else if (owned_titles[i]) |t| {
            out_titles.append(allocator, t) catch {};
        }

        const geom: utils.Rect = if (minimized.contains(win))
            offscreen_rect
        else if (tiling_geoms[i]) |cached|
            cached
        else if (needs_xcb_geometry[i])
            collectGeometryReply(conn, geom_cookies[i])
        else
            offscreen_rect;
        out_geoms.append(allocator, geom) catch {};
    }
}

/// Collect the reply for a fired `xcb_get_property` request without a blocking
/// wait when the reply is already buffered (see `bench.pollReply`); the reply's
/// string value is duped into `allocator`. In a non-bench build this reduces to
/// a single blocking reply call.
fn collectPropertyReply(
    conn: *xcb.xcb_connection_t,
    cookie: xcb.xcb_get_property_cookie_t,
    allocator: std.mem.Allocator,
) ?[]const u8 {
    if (bench.pollReply(conn, cookie.sequence)) |rep| {
        const r: *xcb.xcb_get_property_reply_t = @ptrCast(@alignCast(rep));
        defer std.c.free(r);
        return extractPropertyString(r, allocator) catch null;
    }
    const r = xcb.xcb_get_property_reply(conn, cookie, null) orelse return null;
    defer std.c.free(r);
    return extractPropertyString(r, allocator) catch null;
}

// Empty workspace fast path

/// If `count` is zero: tears down the carousel, fills the segment background,
/// and returns the segment's end x so the caller can return immediately.
/// Returns null when there are windows present and rendering should proceed.
inline fn emptyWorkspace(ctx: TitleRenderContext, count: usize) ?u16 {
    if (count != 0) return null;
    // No windows — tear down any live carousel so it doesn't keep scrolling
    // invisibly. Runs under draw_mutex, so use the non-locking teardown;
    // deinitCarousel() would recursively re-lock (not a recursive mutex).
    carousel.deinitCarouselLocked();
    ctx.dc.fillRect(ctx.start_x, 0, ctx.width, ctx.height, ctx.config.bg);
    return ctx.start_x + ctx.width;
}

// Single-window rendering

/// Shared rendering logic for both `draw()` and `drawCached()`.
///
/// `ctx.cached_title` is non-null only on the `draw()` path (updated as a
/// side-effect); null on `drawCached()` (read-only). `title_invalidated` is
/// always false on the `drawCached()` path.
fn drawSingleWindow(
    ctx: TitleRenderContext,
    snapshot: TitleSnapshot,
    allocator: std.mem.Allocator,
    title_invalidated: bool,
) !void {
    // Free the segmented carousel: the single and segmented paths are
    // mutually exclusive. Leaving render.seg alive keeps isCarouselActive()
    // true, so the carousel thread keeps calling drawCached every tick;
    // drawCached passes minimized_title = "" (no cache for it), so the
    // single-window draw would blank the minimized title. Mirrors
    // deinitSingleCarousel() in drawSegmentedTitles.
    carousel.deinitSegmentedCarousel();

    const single_win = snapshot.current_ws_wins[0];
    const is_minimized = snapshot.minimized_set.contains(single_win);
    // `has_focus` is true when any window on this workspace is focused,
    // meaning the segment gets the accent colour rather than plain bg.
    const has_focus = snapshot.focused_window != null;

    const accent = if (is_minimized)
        ctx.config.title_minimized_accent
    else if (has_focus)
        ctx.config.title_accent_color
    else
        ctx.config.bg;
    ctx.dc.fillRect(ctx.start_x, 0, ctx.width, ctx.height, accent);

    const scaled_padding = ctx.config.scaledSegmentPadding(ctx.height);
    const baseline_y = ctx.dc.baselineY(ctx.height);
    const text_x = ctx.start_x + scaled_padding + title_lead_px;
    // Saturating arithmetic guards against extreme padding values before the
    // saturating subtraction, preventing a u16 wrap in the intermediate result.
    const avail_w = ctx.width -| scaled_padding *| 2 -| title_lead_px;
    const geom = carousel.SegmentGeometry{
        .seg_x = ctx.start_x,
        .seg_w = ctx.width,
        .text_x = text_x,
        .avail_w = avail_w,
    };

    if (is_minimized) {
        // Pre-fetched on the main thread via fetchWindowTitleInto — zero X11
        // I/O here, keeping this call free of blocking round-trips.
        if (snapshot.minimized_title.len > 0)
            try carousel.drawScrollingTitle(
                ctx.dc,
                baseline_y,
                geom,
                snapshot.minimized_title,
                accent,
                ctx.config.fg,
                single_win,
                false,
            );
        return;
    }

    if (snapshot.focused_title.len == 0) return;

    // Update the bar slot's title cache for the next drawCached() tick.
    // Only the draw() path passes non-null cache fields.
    if (ctx.cached_title) |buf| {
        const window_slot = ctx.cached_title_window.?;
        if (title_invalidated or window_slot.* != snapshot.focused_window) {
            buf.clearRetainingCapacity();
            buf.appendSlice(allocator, snapshot.focused_title) catch {};
            window_slot.* = snapshot.focused_window;
        }
    }

    const fg = if (has_focus) ctx.config.selected_fg else ctx.config.fg;
    try carousel.drawScrollingTitle(
        ctx.dc,
        baseline_y,
        geom,
        snapshot.focused_title,
        accent,
        fg,
        snapshot.focused_window,
        title_invalidated,
    );
}

// Split-view segmented titles

/// Renders one title segment per window in a horizontal split-view layout.
/// Windows are sorted spatially so each segment position is stable across focus changes.
fn drawSegmentedTitles(
    ctx: TitleRenderContext,
    snapshot: TitleSnapshot,
    allocator: std.mem.Allocator,
    title_invalidated: bool,
) !void {
    const windows = snapshot.current_ws_wins;
    if (windows.len == 0) return;

    if (windows.len > max_visible_windows)
        debug.warn("Workspace has {} windows; only the first {} are rendered in split-view", .{ windows.len, max_visible_windows });
    const win_count = @min(windows.len, max_visible_windows);

    // Free the single-window carousel: the single and segmented paths are
    // mutually exclusive.  Leaving it alive would cause the carousel timer
    // to blit the stale single-window pixmap over the correct split view.
    carousel.deinitSingleCarousel();

    // Prune the seg-carousel if its window has left the workspace so we never
    // blit a title for a window that was closed or moved to another workspace.
    if (carousel.getSegmentedCarouselWindow()) |tracked_win| {
        if (std.mem.indexOfScalar(u32, windows[0..win_count], tracked_win) == null)
            carousel.deinitSegmentedCarousel();
    }

    // `window_info_buf`/`owned_titles` must outlive gatherWindowInfos — a
    // WindowInfo's `.title` may point into `owned_titles'` memory — so they
    // live here, while gatherWindowInfos' own scratch (XCB cookies, bool
    // flags, several KB) is reclaimed when it returns.
    var window_info_buf: [max_visible_windows]WindowInfo = undefined;
    // Only the first `win_count` slots are read, so only those are
    // initialized — previously this zero-filled all `max_visible_windows`
    // slots every call regardless of how many windows were visible.
    var owned_titles: [max_visible_windows]?[]const u8 = undefined;
    for (owned_titles[0..win_count]) |*t| t.* = null;
    defer for (owned_titles[0..win_count]) |t| if (t) |s| allocator.free(s);

    const info_count = try gatherWindowInfos(
        ctx,
        snapshot,
        allocator,
        windows[0..win_count],
        &window_info_buf,
        &owned_titles,
    );
    if (info_count == 0) return;

    const window_infos = window_info_buf[0..info_count];
    // void context: sort order is purely spatial + window ID, never dependent
    // on focus (see `compareWindows`).  This prevents segment reordering on
    // focus changes, which would be visually jarring.
    std.mem.sort(WindowInfo, window_infos, {}, compareWindows);

    const window_count: u32 = @intCast(window_infos.len);
    const scaled_padding = ctx.config.scaledSegmentPadding(ctx.height);
    const baseline_y = ctx.dc.baselineY(ctx.height);

    for (window_infos, 0..) |info, i| {
        // Pixel-perfect tiling: segment i spans [i*W/n, (i+1)*W/n).
        const x0: u16 = @intCast(@divFloor(@as(u32, @intCast(i)) * ctx.width, window_count));
        const x1: u16 = @intCast(@divFloor(@as(u32, @intCast(i + 1)) * ctx.width, window_count));
        const segment_x: u16 = ctx.start_x + x0;
        const segment_width: u16 = x1 - x0;
        if (segment_width == 0) continue;

        const is_focused_win = snapshot.focused_window == info.window;

        const accent = if (is_focused_win) ctx.config.title_accent_color else if (info.minimized) ctx.config.title_minimized_accent else ctx.config.title_unfocused_accent;

        ctx.dc.fillRect(segment_x, 0, segment_width, ctx.height, accent);

        if (info.title.len == 0 or segment_width <= scaled_padding *| 2) continue;

        const text_x = segment_x + scaled_padding + title_lead_px;
        const avail_w = segment_width -| scaled_padding *| 2 -| title_lead_px;
        const text_fg = if (is_focused_win) ctx.config.selected_fg else ctx.config.fg;
        const text_w = title_width_cache.widthFor(ctx.dc, info.window, info.title);
        const geom = carousel.SegmentGeometry{
            .seg_x = segment_x,
            .seg_w = segment_width,
            .text_x = text_x,
            .avail_w = avail_w,
        };

        var scrolled = false;
        if (is_focused_win and carousel.isCarouselEnabled()) {
            // Focused + carousel enabled: pass full segment bounds so
            // the scroll covers the entire segment width. Returns false
            // exactly when the text fits.
            scrolled = try carousel.drawSegmentedCarousel(
                ctx.dc,
                baseline_y,
                geom,
                text_w,
                info.title,
                accent,
                text_fg,
                info.window,
                title_invalidated,
            );
        }
        if (!scrolled) {
            // Text fits (or carousel disabled / not focused): ellipsis on overflow.
            if (text_w <= avail_w)
                try ctx.dc.drawText(text_x, baseline_y, info.title, text_fg)
            else
                try ctx.dc.drawTextEllipsis(text_x, baseline_y, info.title, avail_w, text_fg);
        }
    }
}

/// Phase 1-3 of drawSegmentedTitles: resolves each window in `windows` to a
/// WindowInfo (position, title, minimized state), writing up to `windows.len`
/// entries into `out_infos` and returning the count written. A window is
/// skipped (not padded) if its live xcb_get_geometry reply fails — see the
/// `orelse continue` below — so the count can be less than `windows.len`.
///
/// Live-fetched title strings are duped into `out_owned_titles[i]` (parallel
/// to `windows`, pre-sized by the caller) because `out_infos[*].title` may
/// point into that memory; the caller frees its entries once done reading
/// `out_infos`.
///
/// Kept separate from drawSegmentedTitles so its scratch arrays (XCB cookies,
/// per-window bool flags — several KB) leave the stack as soon as it returns,
/// rather than coexisting with drawSegmentedTitles' locals for the whole call.
fn gatherWindowInfos(
    ctx: TitleRenderContext,
    snapshot: TitleSnapshot,
    allocator: std.mem.Allocator,
    windows: []const u32,
    out_infos: *[max_visible_windows]WindowInfo,
    out_owned_titles: *[max_visible_windows]?[]const u8,
) !usize {
    const win_count = windows.len;

    // Pre-fetched title/geometry data available? When `titles`/`geoms` carry
    // the full count, all N round-trips were already done in
    // captureStateIntoSlot and are skipped here.
    const has_prefetched_titles = snapshot.titles.len >= win_count;
    const has_prefetched_geoms = snapshot.geoms.len >= win_count;

    atoms.ensureResolved();
    const net_atom = atoms.net_wm_name;
    const utf_type = atoms.utf8AtomType();

    // XCB cookie arrays — populated only for windows whose titles aren't in
    // the pre-fetched snapshot data.
    //
    // Left `undefined` rather than zero-filled: every slot read (0..win_count)
    // is unconditionally written by the loops below, so the remaining slots
    // never need initializing — previously `@splat`-filled on every call.
    var net_wm_cookies: [max_visible_windows]xcb.xcb_get_property_cookie_t = undefined;
    var geom_cookies: [max_visible_windows]xcb.xcb_get_geometry_cookie_t = undefined;
    var needs_xcb_geometry: [max_visible_windows]bool = undefined;
    var is_minimized: [max_visible_windows]bool = undefined;
    // Tiling-cache lookup result per window, resolved once in Phase 1 and
    // reused by the "Build WindowInfo list" loop below.
    var tiling_geom: [max_visible_windows]?utils.Rect = undefined;

    // Phase 1 — fire only the cookies we actually need.
    // Tiled windows: geometry comes from the tiling CacheMap (zero round-trips).
    // Pre-fetched titles: skip xcb_get_property entirely.
    for (windows, 0..) |win, i| {
        is_minimized[i] = snapshot.minimized_set.contains(win);

        if (!has_prefetched_titles) {
            if (net_atom) |na|
                net_wm_cookies[i] = xcb.xcb_get_property(ctx.conn, 0, win, na, utf_type, 0, 8192);
        }

        needs_xcb_geometry[i] = false;
        tiling_geom[i] = null;
        if (!is_minimized[i]) {
            // Prefer the tiling cache, then pre-fetched snapshot data (captured
            // on the main thread) over a live round-trip — what keeps this path
            // (including the carousel-thread drawCached call) free of blocking
            // X11 I/O.
            tiling_geom[i] = tiling.getWindowGeom(win);
            if (tiling_geom[i] == null and !has_prefetched_geoms) {
                geom_cookies[i] = xcb.xcb_get_geometry(ctx.conn, win);
                needs_xcb_geometry[i] = true;
            }
        }
    }

    // Phase 2 — collect _NET_WM_NAME replies; queue WM_NAME fallbacks.
    var fallback_cookies: [max_visible_windows]xcb.xcb_get_property_cookie_t = undefined;
    var needs_fallback: [max_visible_windows]bool = undefined;

    if (!has_prefetched_titles) {
        for (windows, 0..) |win, i| {
            needs_fallback[i] = false;
            got: {
                if (net_atom != null) {
                    const r = xcb.xcb_get_property_reply(ctx.conn, net_wm_cookies[i], null) orelse break :got;
                    defer std.c.free(r);
                    if (try extractPropertyString(r, allocator)) |title| {
                        out_owned_titles[i] = title;
                        break :got;
                    }
                }
                fallback_cookies[i] = xcb.xcb_get_property(ctx.conn, 0, win, xcb.XCB_ATOM_WM_NAME, xcb.XCB_ATOM_STRING, 0, 8192);
                needs_fallback[i] = true;
            }
        }

        // Phase 3 — collect WM_NAME fallback replies.
        for (0..win_count) |i| {
            if (!needs_fallback[i]) continue;
            const r = xcb.xcb_get_property_reply(ctx.conn, fallback_cookies[i], null) orelse continue;
            defer std.c.free(r);
            out_owned_titles[i] = try extractPropertyString(r, allocator);
        }
    }

    // Build WindowInfo list.
    // Geometry: tiling cache → xcb_get_geometry reply → pre-fetched snapshot data → offscreen sentinel.
    var info_count: usize = 0;

    for (windows, 0..) |win, i| {
        const geom: utils.Rect = if (is_minimized[i])
            offscreen_rect
        else if (tiling_geom[i]) |cached|
            cached
        else if (needs_xcb_geometry[i]) blk: {
            const r = xcb.xcb_get_geometry_reply(ctx.conn, geom_cookies[i], null) orelse continue;
            defer std.c.free(r);
            break :blk utils.Rect{
                .x = @intCast(r.*.x),
                .y = @intCast(r.*.y),
                .width = r.*.width,
                .height = r.*.height,
            };
        } else if (has_prefetched_geoms)
            snapshot.geoms[i]
        else
            offscreen_rect;

        const title_str: []const u8 = if (has_prefetched_titles)
            snapshot.titles[i]
        else
            out_owned_titles[i] orelse "";

        out_infos[info_count] = .{
            .window = win,
            .x = geom.x,
            .y = geom.y,
            .title = title_str,
            .minimized = is_minimized[i],
        };
        info_count += 1;
    }

    return info_count;
}

/// Sort order for the split-view segment layout:
///
///   1. Non-minimized windows first (minimized shown last/rightmost, matching
///      their visual demotion in tiling).
///   2. On-screen before off-screen.  Negative-x windows (monocle background)
///      are off-screen; demoting them stops artificial coordinates overriding
///      real spatial ordering.
///   3. Left-to-right by x, then top-to-bottom by y — keeps each window's
///      segment stable across focus changes.
///   4. Tie-break by window ID for deterministic ordering.
///
/// Focus is intentionally NOT a sort key: using it as a tie-break would
/// reorder segments when two windows share coordinates, making the bar jump
/// on focus changes. The focused window is highlighted via accent colour.
fn compareWindows(_: void, a: WindowInfo, b: WindowInfo) bool {
    if (a.minimized != b.minimized) return !a.minimized;
    const a_offscreen = a.x < 0;
    const b_offscreen = b.x < 0;
    if (a_offscreen != b_offscreen) return !a_offscreen;
    if (a.x != b.x) return a.x < b.x;
    if (a.y != b.y) return a.y < b.y;
    return a.window < b.window;
}