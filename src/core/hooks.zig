//! Central hook registry for optional modules (bar, tiling, floating, drag, vim).
//!
//! Defines shared types and function pointers that allow optional modules to be
//! compiled out entirely. When an optional module's source is absent, its hooks
//! stay null and callers silently skip the functionality via convenience
//! accessors that return safe defaults.

const std = @import("std");
const core = @import("core");
const xcb = core.xcb;
const utils = @import("utils");
const types = @import("types");
const tracking = @import("tracking");
const layouts = @import("layouts");
const constants = @import("constants");
const focus = @import("focus");
const fullscreen = @import("fullscreen");

// -- Shared types ---------------------------------------------------------------

pub const TilingLayout = types.Layout;
pub const MasterVariant = types.MasterVariant;
pub const MonocleVariant = types.MonocleVariant;
pub const GridVariant = types.GridVariant;

pub const TilingLayoutVariants = struct {
    master: MasterVariant = .lifo,
    monocle: MonocleVariant = .gapless,
    grid: GridVariant = .rigid,
};

pub const TilingLayoutConfig = struct {
    layout: TilingLayout = .master,
    layout_variants: TilingLayoutVariants = .{},
    master_side: types.MasterSide = .left,
    master_width: f32 = 0.5,
    master_count: u8 = 1,
    stack_balance: f32 = 0.0,
    gap_width: u16 = 0,
    border_width: u16 = 1,
    border_focused: u32 = 0xffffff,
    border_unfocused: u32 = 0x888888,
    min_window_dim: u16 = 50,
    enabled_layouts: [types.LAYOUT_TABLE.len]TilingLayout = init: {
        var result: [types.LAYOUT_TABLE.len]TilingLayout = undefined;
        for (&result, 0..) |*slot, i| slot.* = types.LAYOUT_TABLE[i].tag;
        break :init result;
    },
    enabled_layout_count: u8 = types.LAYOUT_TABLE.len,
};

pub const TilingScrollState = struct {
    offset: i32 = 0,
    prev_n: usize = 0,
    prev_focused: ?u32 = null,
};

pub const TilingGeomCache = struct {
    workspace_geom_valid_bits: u64 = 0,
    last_retile_area: utils.Rect = .{ .x = 0, .y = 0, .width = 0, .height = 0 },
};

pub const TilingState = struct {
    is_enabled: bool = false,
    is_dirty: bool = false,
    config: TilingLayoutConfig = .{},
    windows: tracking.Tracking = .{},
    geom: TilingGeomCache = .{},
    scroll: TilingScrollState = .{},

    pub inline fn margins(self: *const TilingState) utils.Margins {
        return .{ .gap = self.config.gap_width, .border = self.config.border_width };
    }

    pub inline fn borderColor(self: *const TilingState, win: u32) u32 {
        if (fullscreen.isFullscreen(win)) return 0;
        return if (focus.getFocused() == win) self.config.border_focused else self.config.border_unfocused;
    }
};

pub const TilingRetileOpts = struct {
    for_ws: ?u8 = null,
    defer_win: ?u32 = null,
    focus_override: ?u32 = null,
};

pub const BarAction = enum { toggle, hide_fullscreen, show_fullscreen };

pub const DragMode = enum { move, resize };
pub const ResizeCorner = enum { top_left, top_right, bottom_left, bottom_right };
pub const DragState = struct {
    active: bool = false,
    window: core.WindowId = 0,
    mode: DragMode = .move,
    resize_corner: ResizeCorner = .bottom_right,
    start_x: i16 = 0,
    start_y: i16 = 0,
    start_win_x: i16 = 0,
    start_win_y: i16 = 0,
    start_win_width: u16 = 0,
    start_win_height: u16 = 0,
    last_rect: utils.Rect = .{ .x = 0, .y = 0, .width = 0, .height = 0 },
    snap_px: i32 = 0,
};

// -- Static defaults ------------------------------------------------------------

var static_tiling_state: TilingState = .{};

fn fullScreenRect() utils.Rect {
    return .{
        .x = 0,
        .y = 0,
        .width = @intCast(core.getState().screen.width_in_pixels),
        .height = @intCast(core.getState().screen.height_in_pixels),
    };
}

var static_drag_last_rect: utils.Rect = .{ .x = 0, .y = 0, .width = 0, .height = 0 };
var static_empty_windows: [0]u32 = .{};

// -- Global hooks ---------------------------------------------------------------

pub const Hooks = struct {
    // -- Bar hooks --------------------------------------------------------------
    bar_init: ?*const fn () anyerror!void = null,
    bar_deinit: ?*const fn () void = null,
    bar_reload: ?*const fn () void = null,
    bar_submit_draw: ?*const fn () void = null,
    bar_toggle_segment_anchor: ?*const fn () void = null,
    bar_schedule_focus_redraw: ?*const fn (?u32) void = null,
    bar_is_bar_window: ?*const fn (u32) bool = null,
    bar_get_bar_height: ?*const fn () u16 = null,
    bar_work_area_rect: ?*const fn () utils.Rect = null,
    bar_schedule_redraw: ?*const fn () void = null,
    bar_schedule_full_redraw: ?*const fn () void = null,
    bar_schedule_title_redraw: ?*const fn () void = null,
    bar_is_visible: ?*const fn () bool = null,
    bar_redraw_inside_grab: ?*const fn () void = null,
    bar_commit_inside_grab: ?*const fn () void = null,
    bar_raise_bar: ?*const fn () void = null,
    bar_present_for_prompt: ?*const fn () void = null,
    bar_dismiss_after_prompt: ?*const fn () void = null,
    bar_set_bar_state: ?*const fn (BarAction) void = null,
    bar_update_if_dirty: ?*const fn () anyerror!void = null,
    bar_update_clock: ?*const fn () bool = null,
    bar_tick_carousel: ?*const fn () void = null,
    bar_handle_expose: ?*const fn (*const xcb.xcb_expose_event_t) void = null,
    bar_handle_property_notify: ?*const fn (*const xcb.xcb_property_notify_event_t) void = null,
    bar_handle_button_press: ?*const fn (*const xcb.xcb_button_press_event_t) void = null,

    // -- Carousel hooks ---------------------------------------------------------
    carousel_set_enabled: ?*const fn (bool) void = null,
    carousel_set_scroll_speed: ?*const fn (f64) void = null,
    carousel_set_refresh_rate_override: ?*const fn (f64) void = null,
    carousel_notify_focus_changed: ?*const fn (?u32) void = null,

    // -- Prompt hooks -----------------------------------------------------
    prompt_blink_poll_timeout_ms: ?*const fn () i32 = null,
    prompt_blink_tick: ?*const fn () void = null,
    prompt_handle_keypress: ?*const fn (*const xcb.xcb_key_press_event_t, ?*const types.Action) bool = null,
    prompt_toggle: ?*const fn () void = null,

    // -- Tiling hooks -----------------------------------------------------
    tiling_init: ?*const fn () void = null,
    tiling_deinit: ?*const fn () void = null,
    tiling_reload_config: ?*const fn () void = null,
    tiling_cache_size_hints: ?*const fn (u32, layouts.SizeHints) void = null,
    tiling_add_window: ?*const fn (u32) void = null,
    tiling_remove_window: ?*const fn (u32) void = null,
    tiling_toggle_window_float: ?*const fn (u32) void = null,
    tiling_get_window_filtered_index: ?*const fn (u32) ?usize = null,
    tiling_add_window_at_filtered_index: ?*const fn (u32, usize) void = null,
    tiling_save_window_geom: ?*const fn (u32, utils.Rect) void = null,
    tiling_get_window_geom: ?*const fn (u32) ?utils.Rect = null,
    tiling_invalidate_geom_cache: ?*const fn (u32) void = null,
    tiling_invalidate_ws_geom_bit: ?*const fn (u8) void = null,
    tiling_mark_dirty: ?*const fn () void = null,
    tiling_retile_current_workspace_with_opts: ?*const fn (TilingRetileOpts) void = null,
    tiling_retile_current_workspace: ?*const fn () void = null,
    tiling_retile_if_dirty: ?*const fn () void = null,
    tiling_retile_inactive_workspace: ?*const fn (u8) void = null,
    tiling_retile_for_restore: ?*const fn () void = null,
    tiling_restore_workspace_geom: ?*const fn () bool = null,
    tiling_toggle_layout: ?*const fn () void = null,
    tiling_toggle_layout_reverse: ?*const fn () void = null,
    tiling_step_layout_variant: ?*const fn () void = null,
    tiling_step_layout_variant_reverse: ?*const fn () void = null,
    tiling_apply_workspace_layout: ?*const fn (*const anyopaque) void = null,
    tiling_default_layout: ?*const fn () TilingLayout = null,
    tiling_layout_from_string: ?*const fn ([]const u8) ?TilingLayout = null,
    tiling_adjust_master_count: ?*const fn (i8) void = null,
    tiling_adjust_master_width: ?*const fn (f32) void = null,
    tiling_adjust_stack_balance: ?*const fn (f32) void = null,
    tiling_step_scroll_view: ?*const fn (i32) void = null,
    tiling_snap_scroll_to_focused: ?*const fn () void = null,
    tiling_swap_with_master: ?*const fn () ?u32 = null,
    tiling_swap_windows_by_id: ?*const fn (u32, u32) void = null,
    tiling_is_window_tiled: ?*const fn (u32) bool = null,
    tiling_is_floating_layout: ?*const fn () bool = null,
    tiling_is_window_active_tiled: ?*const fn (u32) bool = null,
    tiling_update_window_focus: ?*const fn (?u32, ?u32) void = null,
    tiling_take_prev_focused_for_scroll: ?*const fn () ?u32 = null,
    tiling_send_border_color_if_changed: ?*const fn (u32, u32) bool = null,

    // -- Drag hooks -------------------------------------------------------
    drag_start: ?*const fn (u32, u8, i16, i16) void = null,
    drag_update: ?*const fn (i16, i16) void = null,
    drag_stop: ?*const fn () void = null,
    drag_cancel_for_window: ?*const fn (u32) void = null,
    drag_is_dragging: ?*const fn () bool = null,
    drag_is_resizing_window: ?*const fn (u32) bool = null,
    drag_get_last_rect: ?*const fn () utils.Rect = null,

    // -- Floating hooks ---------------------------------------------------
    floating_tile_with_offset: ?*const fn (*const layouts.LayoutCtx, *const anyopaque, []const u32, u16, u16, u16) void = null,
};

pub var h: Hooks = .{};

// -- Auto-registration ---------------------------------------------------------

/// Registers hooks from a mapping struct into the global hook table.
///
/// `hook_map` is a struct whose field names must match `Hooks` struct field
/// names exactly. Each value is the function pointer to assign. This keeps
/// hook registration co-located with the providing module; adding a hook
/// requires touching only the module (export in `hook_map`) and `hooks.zig`
/// (struct field + accessor), never `main.zig`.
///
/// Example module export:
///   pub const hook_map = .{
///       .bar_init = init,
///       .bar_deinit = deinit,
///       .bar_set_bar_state = @ptrCast(&setBarState),
///   };
pub fn registerHooks(comptime hook_map: anytype) void {
    const map_fields = @typeInfo(@TypeOf(hook_map)).@"struct".fields;
    inline for (map_fields) |map_field| {
        if (@hasField(Hooks, map_field.name)) {
            @field(h, map_field.name) = @field(hook_map, map_field.name);
        }
    }
}

// -- Bar convenience accessors ------------------------------------------------

pub inline fn barInit() !void {
    if (h.bar_init) |f| try f();
}

pub inline fn barDeinit() void {
    if (h.bar_deinit) |f| f();
}

pub inline fn barReload() void {
    if (h.bar_reload) |f| f();
}

pub inline fn barSubmitDraw() void {
    if (h.bar_submit_draw) |f| f();
}

pub inline fn barToggleSegmentAnchor() void {
    if (h.bar_toggle_segment_anchor) |f| f();
}

pub inline fn barScheduleFocusRedraw(new_win: ?u32) void {
    if (h.bar_schedule_focus_redraw) |f| f(new_win);
}

pub inline fn isBarWindow(win: u32) bool {
    if (h.bar_is_bar_window) |f| return f(win);
    return false;
}

pub inline fn barGetBarHeight() u16 {
    if (h.bar_get_bar_height) |f| return f();
    return 0;
}

pub inline fn barWorkAreaRect() utils.Rect {
    if (h.bar_work_area_rect) |f| return f();
    return fullScreenRect();
}

pub inline fn barScheduleRedraw() void {
    if (h.bar_schedule_redraw) |f| f();
}

pub inline fn barScheduleFullRedraw() void {
    if (h.bar_schedule_full_redraw) |f| f();
}

pub inline fn barScheduleTitleRedraw() void {
    if (h.bar_schedule_title_redraw) |f| f();
}

pub inline fn barIsVisible() bool {
    if (h.bar_is_visible) |f| return f();
    return false;
}

pub inline fn barRedrawInsideGrab() void {
    if (h.bar_redraw_inside_grab) |f| f();
}

pub inline fn barCommitInsideGrab() void {
    if (h.bar_commit_inside_grab) |f| f();
}

pub inline fn barRaiseBar() void {
    if (h.bar_raise_bar) |f| f();
}

pub inline fn barPresentForPrompt() void {
    if (h.bar_present_for_prompt) |f| f();
}

pub inline fn barDismissAfterPrompt() void {
    if (h.bar_dismiss_after_prompt) |f| f();
}

pub inline fn barSetBarState(action: BarAction) void {
    if (h.bar_set_bar_state) |f| f(action);
}

pub inline fn barUpdateIfDirty() !void {
    if (h.bar_update_if_dirty) |f| try f();
}

pub inline fn barUpdateClock() bool {
    if (h.bar_update_clock) |f| return f();
    return false;
}

pub inline fn barTickCarousel() void {
    if (h.bar_tick_carousel) |f| f();
}

pub inline fn barHandleExpose(event: *const xcb.xcb_expose_event_t) void {
    if (h.bar_handle_expose) |f| f(event);
}

pub inline fn barHandlePropertyNotify(event: *const xcb.xcb_property_notify_event_t) void {
    if (h.bar_handle_property_notify) |f| f(event);
}

pub inline fn barHandleButtonPress(event: *const xcb.xcb_button_press_event_t) void {
    if (h.bar_handle_button_press) |f| f(event);
}

// -- Carousel convenience accessors -------------------------------------------

pub inline fn carouselSetEnabled(enabled: bool) void {
    if (h.carousel_set_enabled) |f| f(enabled);
}

pub inline fn carouselSetScrollSpeed(speed: f64) void {
    if (h.carousel_set_scroll_speed) |f| f(speed);
}

pub inline fn carouselSetRefreshRateOverride(rate: f64) void {
    if (h.carousel_set_refresh_rate_override) |f| f(rate);
}

pub inline fn carouselNotifyFocusChanged(win: ?u32) void {
    if (h.carousel_notify_focus_changed) |f| f(win);
}

// -- Prompt convenience accessors ---------------------------------------------

pub inline fn promptBlinkPollTimeoutMs() i32 {
    if (h.prompt_blink_poll_timeout_ms) |f| return f();
    return -1;
}

pub inline fn promptBlinkTick() void {
    if (h.prompt_blink_tick) |f| f();
}

pub inline fn promptHandleKeypress(event: *const xcb.xcb_key_press_event_t, matched: ?*const types.Action) bool {
    if (h.prompt_handle_keypress) |f| return f(event, matched);
    return false;
}

pub inline fn promptToggle() void {
    if (h.prompt_toggle) |f| f();
}

// -- Tiling convenience accessors ---------------------------------------------

pub inline fn tilingInit() void {
    if (h.tiling_init) |f| f();
}

pub inline fn tilingDeinit() void {
    if (h.tiling_deinit) |f| f();
}

pub inline fn tilingReloadConfig() void {
    if (h.tiling_reload_config) |f| f();
}

pub inline fn tilingCacheSizeHints(win: u32, hints: layouts.SizeHints) void {
    if (h.tiling_cache_size_hints) |f| f(win, hints);
}

pub inline fn tilingAddWindow(window_id: u32) void {
    if (h.tiling_add_window) |f| f(window_id);
}

pub inline fn tilingRemoveWindow(window_id: u32) void {
    if (h.tiling_remove_window) |f| f(window_id);
}

pub inline fn tilingToggleWindowFloat(window_id: u32) void {
    if (h.tiling_toggle_window_float) |f| f(window_id);
}

pub inline fn tilingGetWindowFilteredIndex(win: u32) ?usize {
    if (h.tiling_get_window_filtered_index) |f| return f(win);
    return null;
}

pub inline fn tilingAddWindowAtFilteredIndex(win: u32, idx: usize) void {
    if (h.tiling_add_window_at_filtered_index) |f| f(win, idx);
}

pub inline fn tilingSaveWindowGeom(window_id: u32, rect: utils.Rect) void {
    if (h.tiling_save_window_geom) |f| f(window_id, rect);
}

pub inline fn tilingGetWindowGeom(window_id: u32) ?utils.Rect {
    if (h.tiling_get_window_geom) |f| return f(window_id);
    return null;
}

pub inline fn tilingInvalidateGeomCache(window_id: u32) void {
    if (h.tiling_invalidate_geom_cache) |f| f(window_id);
}

pub inline fn tilingInvalidateWsGeomBit(ws_idx: u8) void {
    if (h.tiling_invalidate_ws_geom_bit) |f| f(ws_idx);
}

pub inline fn tilingMarkDirty() void {
    if (h.tiling_mark_dirty) |f| f();
}

pub inline fn tilingRetileCurrentWorkspaceWithOpts(opts: TilingRetileOpts) void {
    if (h.tiling_retile_current_workspace_with_opts) |f| f(opts);
}

pub inline fn tilingRetileCurrentWorkspace() void {
    if (h.tiling_retile_current_workspace) |f| f();
}

pub inline fn tilingRetileIfDirty() void {
    if (h.tiling_retile_if_dirty) |f| f();
}

pub inline fn tilingRetileInactiveWorkspace(ws_idx: u8) void {
    if (h.tiling_retile_inactive_workspace) |f| f(ws_idx);
}

pub inline fn tilingRetileForRestore() void {
    if (h.tiling_retile_for_restore) |f| f();
}

pub inline fn tilingRestoreWorkspaceGeom() bool {
    if (h.tiling_restore_workspace_geom) |f| return f();
    return false;
}

pub inline fn tilingToggleLayout() void {
    if (h.tiling_toggle_layout) |f| f();
}

pub inline fn tilingToggleLayoutReverse() void {
    if (h.tiling_toggle_layout_reverse) |f| f();
}

pub inline fn tilingStepLayoutVariant() void {
    if (h.tiling_step_layout_variant) |f| f();
}

pub inline fn tilingStepLayoutVariantReverse() void {
    if (h.tiling_step_layout_variant_reverse) |f| f();
}

pub inline fn tilingApplyWorkspaceLayout(ws_ptr: *const anyopaque) void {
    if (h.tiling_apply_workspace_layout) |f| f(ws_ptr);
}

pub inline fn tilingDefaultLayout() TilingLayout {
    if (h.tiling_default_layout) |f| return f();
    return .master;
}

pub inline fn tilingLayoutFromString(name: []const u8) ?TilingLayout {
    if (h.tiling_layout_from_string) |f| return f(name);
    return null;
}

pub inline fn tilingAdjustMasterCount(delta: i8) void {
    if (h.tiling_adjust_master_count) |f| f(delta);
}

pub inline fn tilingAdjustMasterWidth(delta: f32) void {
    if (h.tiling_adjust_master_width) |f| f(delta);
}

pub inline fn tilingAdjustStackBalance(delta: f32) void {
    if (h.tiling_adjust_stack_balance) |f| f(delta);
}

pub inline fn tilingStepScrollView(delta: i32) void {
    if (h.tiling_step_scroll_view) |f| f(delta);
}

pub inline fn tilingSnapScrollToFocused() void {
    if (h.tiling_snap_scroll_to_focused) |f| f();
}

pub inline fn tilingSwapWithMaster() ?u32 {
    if (h.tiling_swap_with_master) |f| return f();
    return null;
}

pub inline fn tilingSwapWindowsById(win_a: u32, win_b: u32) void {
    if (h.tiling_swap_windows_by_id) |f| f(win_a, win_b);
}

pub inline fn tilingIsWindowTiled(window_id: u32) bool {
    if (h.tiling_is_window_tiled) |f| return f(window_id);
    return false;
}

pub inline fn tilingIsFloatingLayout() bool {
    if (h.tiling_is_floating_layout) |f| return f();
    return false;
}

pub inline fn tilingIsWindowActiveTiled(window_id: u32) bool {
    if (h.tiling_is_window_active_tiled) |f| return f(window_id);
    return false;
}

pub inline fn tilingUpdateWindowFocus(old_focused: ?u32, new_focused: ?u32) void {
    if (h.tiling_update_window_focus) |f| f(old_focused, new_focused);
}

pub inline fn tilingTakePrevFocusedForScroll() ?u32 {
    if (h.tiling_take_prev_focused_for_scroll) |f| return f();
    return null;
}

pub inline fn tilingSendBorderColorIfChanged(win: u32, color: u32) bool {
    if (h.tiling_send_border_color_if_changed) |f| return f(win, color);
    return false;
}

/// Returns a pointer to the live tiling state, or a pointer to a static
/// empty state when tiling is not compiled in.
pub inline fn tilingGetStateOpt() ?*TilingState {
    if (h.tiling_is_window_active_tiled != null) return &static_tiling_state;
    return null;
}

pub inline fn tilingGetState() *TilingState {
    return &static_tiling_state;
}

// -- Drag convenience accessors -----------------------------------------------

pub inline fn dragStart(win: u32, button: u8, x: i16, y: i16) void {
    if (h.drag_start) |f| f(win, button, x, y);
}

pub inline fn dragUpdate(x: i16, y: i16) void {
    if (h.drag_update) |f| f(x, y);
}

pub inline fn dragStop() void {
    if (h.drag_stop) |f| f();
}

pub inline fn dragCancelForWindow(win: u32) void {
    if (h.drag_cancel_for_window) |f| f(win);
}

pub inline fn isDragging() bool {
    if (h.drag_is_dragging) |f| return f();
    return false;
}

pub inline fn isResizingWindow(win: u32) bool {
    if (h.drag_is_resizing_window) |f| return f(win);
    return false;
}

pub inline fn dragGetLastRect() utils.Rect {
    if (h.drag_get_last_rect) |f| return f();
    return static_drag_last_rect;
}

// -- Floating convenience accessors -------------------------------------------

pub inline fn floatingTileWithOffset(
    ctx: *const layouts.LayoutCtx,
    state: *const anyopaque,
    windows: []const u32,
    master_count: u16,
    stack_count: u16,
    master_width: u16,
) void {
    if (h.floating_tile_with_offset) |f| f(ctx, state, windows, master_count, stack_count, master_width);
}
