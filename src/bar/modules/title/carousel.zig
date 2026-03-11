//! Carousel / ticker logic for the title segment.
//!
//! A "carousel" is a pre-rendered XCB pixmap that is wider than the available
//! area.  Every frame, a window into that pixmap is blitted via xcb_copy_area
//! using a time-derived offset, producing a smooth horizontal scroll.
//!
//! V-sync alignment
//! ────────────────
//! The scroll offset is quantised to monitor frame boundaries so that the
//! destination pixels change at most once per frame.  This eliminates the
//! sub-pixel drift that occurs when the bar redraws mid-frame and ensures
//! that every visible update coincides with a v-blank interval.
//!
//!   frame_duration = 1 000 ms / hz
//!   pixels_per_frame = CAROUSEL_PX_PER_S / hz
//!   frame_number = floor(elapsed_ms / frame_duration)
//!   offset = (frame_number × pixels_per_frame)  mod  cycle_w
//!
//! The pixmap is only rebuilt when the window ID changes or the title is
//! invalidated — the hot path is always two xcb_copy_area blits.
//!
//! Leapfrog wrap
//! ─────────────
//! Two logical copies of the text sit `cycle_w` apart in the pixmap.  As
//! `offset` advances 0 → cycle_w the first copy exits left while the second
//! enters right.  At cycle_w the state is identical to 0 → seamless loop.
//!
//!   cycle_w = text_w + CAROUSEL_GAP_PX

const std     = @import("std");
const defs    = @import("defs");
const drawing = @import("drawing");
const hertz   = @import("hertz");

// ─────────────────────────────────────────────────────────────────────────────
// Constants
// ─────────────────────────────────────────────────────────────────────────────

/// Horizontal scroll speed in pixels per second (≈ 90 px/s).
/// Divided by the monitor Hz to get pixels-per-frame at detection time.
pub const CAROUSEL_PX_PER_S: f64 = 90.0;

/// Pixel gap between the end of one text copy and the start of the next.
pub const CAROUSEL_GAP_PX: u16 = 60;

// ─────────────────────────────────────────────────────────────────────────────
// Types
// ─────────────────────────────────────────────────────────────────────────────

/// Pre-rendered title pixmap for the single-window carousel.
const CarouselCache = struct {
    cp:      drawing.CarouselPixmap,
    window:  ?u32,
    cycle_w: u16,
};

/// Pre-rendered title pixmap for the focused segment in split-view.
const SegCarousel = struct {
    cp:       drawing.CarouselPixmap,
    window:   u32,
    cycle_w:  u16,
    /// Monotonic timestamp (ms) when the focused window gained focus or the
    /// pixmap was first built.  The scroll offset is derived from `now -
    /// start_ms` so the animation always starts from position 0 on focus
    /// change.
    start_ms: i64,
};

// ─────────────────────────────────────────────────────────────────────────────
// Module state
// ─────────────────────────────────────────────────────────────────────────────

var g_carousel:            ?CarouselCache = null;
var g_carousel_active:     bool           = false;
var g_seg_carousel:        ?SegCarousel   = null;
var g_seg_carousel_active: bool           = false;

// ─────────────────────────────────────────────────────────────────────────────
// Public API — lifecycle
// ─────────────────────────────────────────────────────────────────────────────

pub fn isCarouselActive() bool {
    return g_carousel_active or g_seg_carousel_active;
}

/// Free all carousel pixmaps.  Call on bar deinit or config reload.
pub fn deinitCarousel() void {
    if (g_carousel)     |*cc| { cc.cp.deinit(); g_carousel     = null; }
    if (g_seg_carousel) |*sc| { sc.cp.deinit(); g_seg_carousel = null; }
    g_carousel_active     = false;
    g_seg_carousel_active = false;
}

// ─────────────────────────────────────────────────────────────────────────────
// Public API — hot-path tick
// ─────────────────────────────────────────────────────────────────────────────

/// Fast per-tick single-window carousel redraw.
///
/// Skips Pango, Cairo surface flush, and the full-bar blit.
/// Returns false when no carousel is active (caller must fall back to a full
/// title draw).
///
/// Hot path:
///   fillRect          — one xcb_poly_fill_rectangle
///   blitFrame         — at most two xcb_copy_area
///   flushRect         — one targeted xcb_copy_area, no cairo_surface_flush
pub fn drawCarouselTick(
    dc:      *drawing.DrawContext,
    bg:      u32,
    height:  u16,
    x:       u16,
    avail_w: u16,
) bool {
    const cc = g_carousel orelse return false;
    dc.fillRect(x, 0, avail_w, height, bg);
    const offset = carouselOffset(0, cc.cycle_w);
    cc.cp.blitFrame(dc.drawable, dc.gc, x, avail_w, offset, cc.cycle_w);
    dc.flushRect(x, avail_w);
    return true;
}

// ─────────────────────────────────────────────────────────────────────────────
// Public API — single-window title rendering
// ─────────────────────────────────────────────────────────────────────────────

/// Render `text` into `avail_w` pixels starting at (`x`, `y`).
///
/// If the text fits it is drawn normally via Pango/Cairo.
/// If it overflows, a CarouselPixmap is built (or reused) and blitted with a
/// v-synced scroll offset.
///
/// The pixmap is rebuilt only when `window` changes or `title_invalidated` is
/// true, keeping the hot path allocation-free.
pub fn drawOrScrollTitle(
    dc:                *drawing.DrawContext,
    x:                 u16,
    y:                 u16,
    avail_w:           u16,
    text:              []const u8,
    bg:                u32,
    fg:                u32,
    window:            ?u32,
    title_invalidated: bool,
) !void {
    const text_w = dc.textWidth(text);

    if (text_w <= avail_w) {
        // Text fits — release any stale pixmap and draw normally.
        if (g_carousel != null) deinitCarousel();
        g_carousel_active = false;
        try dc.drawText(x, y, text, fg);
        return;
    }

    g_carousel_active = true;

    const stale = g_carousel == null
        or g_carousel.?.window != window
        or title_invalidated;

    if (stale) {
        if (g_carousel) |*cc| { cc.cp.deinit(); g_carousel = null; }

        var cp = try drawing.CarouselPixmap.init(dc, text_w);
        errdefer cp.deinit();
        try cp.render(dc, text, bg, fg, y);
        const cycle_w: u16 = text_w + CAROUSEL_GAP_PX;
        g_carousel = .{ .cp = cp, .window = window, .cycle_w = cycle_w };
    }

    const cc     = g_carousel.?;
    const offset = carouselOffset(0, cc.cycle_w);
    cc.cp.blitFrame(dc.drawable, dc.gc, x, avail_w, offset, cc.cycle_w);
}

// ─────────────────────────────────────────────────────────────────────────────
// Public API — split-view segmented carousel
// ─────────────────────────────────────────────────────────────────────────────

/// Call at the top of a segmented-titles draw pass.
///
/// If the window that owns the current seg-carousel is no longer in the
/// workspace window list, the pixmap is freed so we don't blit a title that
/// is no longer on-screen.
/// Also resets the `g_seg_carousel_active` flag; the draw loop sets it again
/// if a carousel is actually needed this frame.
pub fn prepareSegCarousel(win_items: []const u32) void {
    if (g_seg_carousel) |sc| {
        var still_present = false;
        for (win_items) |w| {
            if (w == sc.window) { still_present = true; break; }
        }
        if (!still_present) {
            g_seg_carousel.?.cp.deinit();
            g_seg_carousel = null;
        }
    }
    g_seg_carousel_active = false;
}

/// Render the focused window's title for a split-view segment.
///
/// If `text` fits in `avail_w` the caller should draw it normally and pass
/// `was_built = false`.  Returns true when a carousel blit was performed.
///
/// The pixmap is rebuilt only when the focused window changes
/// (sc.window != window), the title is invalidated, or the cycle_w changes
/// (meaning the available area changed).  On focus change start_ms is reset
/// so the scroll animation begins from position 0.
pub fn blitSegCarousel(
    dc:                *drawing.DrawContext,
    text_x:            u16,
    baseline_y:        u16,
    avail_w:           u16,
    text_w:            u16,
    text:              []const u8,
    accent:            u32,
    text_fg:           u32,
    window:            u32,
    title_invalidated: bool,
) !bool {
    if (text_w <= avail_w) return false; // fits — caller draws normally

    g_seg_carousel_active = true;

    const expected_cycle_w: u16 = text_w + CAROUSEL_GAP_PX;

    const stale = if (g_seg_carousel) |sc|
        sc.window != window or
        title_invalidated    or
        sc.cycle_w != expected_cycle_w
    else
        true;

    if (stale) {
        if (g_seg_carousel) |*sc| { sc.cp.deinit(); g_seg_carousel = null; }
        var cp = try drawing.CarouselPixmap.init(dc, text_w);
        errdefer cp.deinit();
        try cp.render(dc, text, accent, text_fg, baseline_y);
        g_seg_carousel = .{
            .cp       = cp,
            .window   = window,
            .cycle_w  = expected_cycle_w,
            .start_ms = nowMs(),
        };
    }

    const sc     = g_seg_carousel.?;
    const offset = carouselOffset(sc.start_ms, sc.cycle_w);
    sc.cp.blitFrame(dc.drawable, dc.gc, text_x, avail_w, offset, sc.cycle_w);
    return true;
}

// ─────────────────────────────────────────────────────────────────────────────
// Internal helpers
// ─────────────────────────────────────────────────────────────────────────────

fn nowMs() i64 {
    const ts = std.posix.clock_gettime(.MONOTONIC) catch return 0;
    return ts.sec * 1000 + @divTrunc(ts.nsec, 1_000_000);
}

/// Compute the v-synced scroll offset for a carousel with the given cycle width.
///
/// The offset is quantised to monitor frame boundaries:
///
///   frame_duration_ms = 1000.0 / hz
///   px_per_frame      = CAROUSEL_PX_PER_S / hz
///   frame_num         = floor(elapsed_ms / frame_duration_ms)
///   offset            = (frame_num × px_per_frame) mod cycle_w
///
/// Quantising to frames means the blit source changes at most once per
/// display refresh cycle, aligning visual updates with v-blank and preventing
/// the partial-frame tearing that arises when the bar redraws at an arbitrary
/// sub-frame moment.
///
/// Pass `start_ms = 0` for the absolute-time (single-window) behaviour where
/// the scroll position is derived from wall-clock time rather than from the
/// moment a window gained focus.
fn carouselOffset(start_ms: i64, cycle_w: u16) u16 {
    const hz           = hertz.getCached();
    const frame_ms     = 1000.0 / hz;
    const px_per_frame = CAROUSEL_PX_PER_S / hz;

    const elapsed_ms = @as(f64, @floatFromInt(nowMs() - start_ms));
    const frame_num  = @floor(elapsed_ms / frame_ms);
    const raw_px     = frame_num * px_per_frame;
    const cycle_f    = @as(f64, @floatFromInt(cycle_w));
    const offset_f   = @mod(raw_px, cycle_f);

    const offset: u64 = @intFromFloat(offset_f);
    return @intCast(@min(offset, @as(u64, cycle_w - 1)));
}
