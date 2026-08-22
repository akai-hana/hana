//! Dual-path dispatch during migration (REARCHITECTURE_PLAN.md §E.7).
//! Flag OFF ⇒ byte-identical legacy behavior: every entry point returns
//! before touching any new-pipeline state.
//!
//! Call sites (all marked `// PIPELINE:`):
//!   core/main.zig   startup        → init(alloc)
//!   events.zig      dispatch tail  → postDispatch()
//!   input.zig       finishTilingOp → tilingOpFinished()
//!   floating.zig    updateDrag     → dragTick()

const std = @import("std");
const model_mod = @import("model");
const sync = @import("sync");
const layouts = @import("layouts");
const core = @import("core");
const utils = @import("utils");
const borders = @import("borders");
const focus = @import("focus");
const xcb_sink = @import("xcb_sink");
const build_options = @import("build_options");
const bar = if (build_options.has_bar) @import("bar") else null;

pub var enabled: bool = false; // init(): getenv("HANA_MODEL_PIPELINE")=="1"

var instance: model_mod.Model = undefined;
pub fn init(gpa: std.mem.Allocator) void {
    instance = .{ .gpa = gpa };
    if (std.c.getenv("HANA_MODEL_PIPELINE")) |v| enabled = std.mem.eql(u8, std.mem.span(v), "1");
    if (enabled) sync.init(gpa);
}
pub inline fn model() *model_mod.Model {
    return &instance;
}

var g_sink: ?xcb_sink.XcbSink = null;
var g_ctx: sync.Ctx = undefined;

/// Builds the per-retile Ctx from live state exactly as invokeLayout resolved
/// its inputs (§7.4 step 3): workarea via bar's helper, margins/min_dim and
/// variant booleans from config, border width from borders.width(), colors
/// from config.tiling. Only valid after init() when enabled.
fn ctx() *sync.Ctx {
    const cs = core.getState();
    if (g_sink == null) g_sink = .{ .conn = cs.conn };
    const screen_h = cs.screen.height_in_pixels;
    g_ctx = .{
        .sink = (&g_sink.?).sink(),
        .screen = .{
            .x = 0,
            .y = 0,
            .width = cs.screen.width_in_pixels,
            .height = screen_h,
        },
        .workarea = if (build_options.has_bar) bar.workAreaRect() else .{
            .x = 0,
            .y = 0,
            .width = cs.screen.width_in_pixels,
            .height = screen_h,
        },
        .cfg_bw = borders.width(),
        .env = .{
            .margins = .{
                .gap = utils.scaling.scaleBorderWidth(cs.config.tiling.gap_width, screen_h),
                .border = utils.scaling.scaleBorderWidth(cs.config.tiling.border_width, screen_h),
            },
            .min_dim = cs.config.tiling.min_window_dim,
            .master_on_right = cs.config.tiling.master_side == .right,
            .grid_relaxed = cs.config.tiling.grid_variant == .relaxed,
            .monocle_gaps = cs.config.tiling.monocle_variant == .gaps,
        },
        .color_of = colorOf,
        .bar_win = if (build_options.has_bar and bar.isVisible()) bar.getBarWindow() else null,
    };
    return &g_ctx;
}

/// Ported from borders.color minus its fullscreen check: fullscreen windows
/// get bw=0/pixel=0 through the fullscreen branch policy in sync instead.
fn colorOf(win: model_mod.WindowId, m: *const model_mod.Model) u32 {
    _ = m;
    const cfg = &core.getState().config.tiling;
    return if (focus.getFocused() == win) cfg.border_focused else cfg.border_unfocused;
}

/// Field-by-field conversion; delete both sides in WP6.
pub fn convertHints(src: layouts.SizeHints) model_mod.SizeHints {
    var d: model_mod.SizeHints = .{};
    d.max_width = src.max_width;
    d.max_height = src.max_height;
    d.inc_width = src.inc_width;
    d.inc_height = src.inc_height;
    d.min_aspect = src.min_aspect;
    d.max_aspect = src.max_aspect;
    return d;
}

pub inline fn postDispatch() void {
    if (!enabled) return;
    sync.schedule(ctx());
}
pub inline fn tilingOpFinished() void {
    if (enabled) reconcileUnderGrabNow(.{});
}
pub inline fn dragTick() void {
    if (enabled) reconcileNow();
}

/// WP5: grab server → reconcileUnderGrab(ctx, opts) → ungrabAndFlush.
pub inline fn reconcileUnderGrabNow(o: sync.ReconcileOpts) void {
    _ = o;
}

/// WP5: flushless reconcile against the current ctx.
pub inline fn reconcileNow() void {}
