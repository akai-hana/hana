//! Centralized logging for debugging and status messages.

const std = @import("std");
const builtin = @import("builtin");
const colors = @import("colors");

pub inline fn isDebug() bool {
    return builtin.mode == .Debug;
}

// ============================================================================
// CONFIG LOGGING
// ============================================================================

pub fn configReloaded() void {
    std.log.info("[config] Reloaded", .{});
}

pub fn configReloadFailed(err: anyerror) void {
    std.log.err("[config] Reload failed: {}", .{err});
}

pub fn configLoaded(path: []const u8) void {
    std.log.info("[config] Loaded: {s}", .{path});
}

pub fn configNotFound(path: []const u8) void {
    std.log.info("[config] Not found: {s}, using defaults", .{path});
}

pub fn validateRange(comptime T: type, value: T, min: T, max: T, comptime field: []const u8) bool {
    if (value < min or value > max) {
        std.log.warn("[config] {s} {} out of range ({}-{})", .{ field, value, min, max });
        return false;
    }
    return true;
}

pub fn validateColor(color: u32, comptime field: []const u8) bool {
    if (color > 0xFFFFFF) {
        std.log.warn("[config] {s} 0x{x} exceeds RGB range", .{ field, color });
        return false;
    }
    return true;
}

// ============================================================================
// PARSER LOGGING
// ============================================================================

pub fn parserInvalidSection(line: usize, err: anyerror) void {
    std.log.warn("[parser] Invalid section at line {}: {}", .{ line, err });
}

pub fn parserDuplicateSection(line: usize) void {
    std.log.warn("[parser] Duplicate section at line {}", .{line});
}

pub fn parserInvalidKeyValue(line: usize, err: anyerror) void {
    std.log.warn("[parser] Invalid key-value at line {}: {}", .{ line, err });
}

pub fn parserDuplicateKey(key: []const u8, line: usize) void {
    std.log.warn("[parser] Duplicate key '{s}' at line {}", .{ key, line });
}

pub fn parserUnexpectedChar(line: usize) void {
    std.log.warn("[parser] Unexpected character at line {}", .{line});
}

pub fn parserInvalidColor(value: []const u8, line: usize) void {
    std.log.warn("[parser] Invalid color '{s}' at line {}", .{ value, line });
}

// ============================================================================
// XKB LOGGING
// ============================================================================

pub fn xkbInitializing() void {
    if (isDebug()) std.log.debug("[xkb] Initializing", .{});
}

pub fn xkbDeviceId(device_id: i32) void {
    if (isDebug()) std.log.debug("[xkb] Device ID: {}", .{device_id});
}

pub fn xkbInitComplete() void {
    if (isDebug()) std.log.debug("[xkb] Initialization complete", .{});
}

pub fn xkbKeycodeNotFound(keysym: u32) void {
    if (isDebug()) std.log.warn("[xkb] Keycode not found for keysym: 0x{x}", .{keysym});
}

// ============================================================================
// FOCUS LOGGING
// ============================================================================

pub fn focusChanged(old: ?u32, new: u32, reason: []const u8) void {
    if (isDebug()) std.log.debug("[focus] {?x} → 0x{x} ({s})", .{ old, new, reason });
}

pub fn focusSuppressed(elapsed_ms: u64) void {
    if (isDebug()) std.log.debug("[focus] Suppressing mouse focus ({}ms since layout)", .{elapsed_ms});
}

pub fn focusLayoutMarked() void {
    if (isDebug()) std.log.debug("[focus] Layout operation marked", .{});
}

pub fn focusClear() void {
    if (isDebug()) std.log.debug("[focus] Focus cleared", .{});
}

pub fn focusAttempt(old: ?u32, new: u32, reason: []const u8) void {
    if (isDebug()) std.log.debug("[focus] {?x} → 0x{x} ({s})", .{ old, new, reason });
}

// ============================================================================
// WINDOW MANAGEMENT LOGGING
// ============================================================================

pub fn windowDestroyed(win: u32) void {
    if (isDebug()) std.log.debug("[window] Destroyed: 0x{x}", .{win});
}

pub fn windowMapped(win: u32) void {
    if (isDebug()) std.log.debug("[window] Mapped: 0x{x}", .{win});
}

pub fn windowUnmapped(win: u32) void {
    if (isDebug()) std.log.debug("[window] Unmapped: 0x{x}", .{win});
}

pub fn windowConfigureRequest(win: u32, x: i16, y: i16, w: u16, h: u16) void {
    if (isDebug()) std.log.debug("[window] Configure request: 0x{x} ({}x{}+{}+{})", .{ win, w, h, x, y });
}

// ============================================================================
// WINDOW DESTRUCTION DEBUG
// ============================================================================

pub fn debugDestroyWindow(win: u32, root: u32, total: usize, is_focused: bool) void {
    std.log.warn("[DEBUG] Attempting to destroy window: 0x{x}", .{win});
    std.log.warn("[DEBUG] Root window: 0x{x}", .{root});
    std.log.warn("[DEBUG] Total managed windows: {}", .{total});
    std.log.warn("[DEBUG] Is focused: {}", .{is_focused});
}

pub fn debugDestroyWindowComplete(win: u32) void {
    std.log.warn("[DEBUG] xcb_kill_client called for 0x{x}", .{win});
}

pub fn debugNoFocusedWindow() void {
    std.log.warn("[DEBUG] close_window called but no focused window", .{});
}

pub fn debugWindowDestroyNotify(win: u32, was_focused: bool, total_before: usize, total_after: usize) void {
    std.log.warn("[DEBUG DestroyNotify] Window 0x{x} destroyed", .{win});
    std.log.warn("[DEBUG DestroyNotify] Was focused: {}", .{was_focused});
    std.log.warn("[DEBUG DestroyNotify] Total windows before: {}", .{total_before});
    std.log.warn("[DEBUG DestroyNotify] Total windows after: {}", .{total_after});
}

// ============================================================================
// CURSOR DEBUG
// ============================================================================

pub fn debugCursorQuery(x: i16, y: i16, child: u32) void {
    if (isDebug()) std.log.debug("[cursor] Position: ({}, {}) over window 0x{x}", .{ x, y, child });
}

pub fn debugCursorNoWindow() void {
    if (isDebug()) std.log.debug("[cursor] No window under cursor", .{});
}

// ============================================================================
// DRAG LOGGING
// ============================================================================

pub fn dragStarted(action: []const u8, window: u32, x: i16, y: i16) void {
    if (isDebug()) std.log.info("[drag] {s} window 0x{x} at ({}, {})", .{ action, window, x, y });
}

pub fn dragStopped(window: u32) void {
    if (isDebug()) std.log.info("[drag] Stopped window 0x{x}", .{window});
}

// ============================================================================
// LAYOUT LOGGING
// ============================================================================

pub fn debugLayoutTiling(layout: []const u8, count: usize, cols: u16, rows: u16) void {
    if (isDebug()) std.log.debug("[layout:{s}] {} windows ({}x{})", .{ layout, count, cols, rows });
}

pub fn debugLayoutTilingSimple(layout: []const u8, count: usize) void {
    if (isDebug()) std.log.debug("[layout:{s}] {} windows", .{ layout, count });
}

pub fn debugLayoutMasterLeft(total: usize, master_count: usize, actual_master: u16, stack: u16, screen_w: u16) void {
    if (isDebug()) std.log.debug("[layout:master_left] {} windows (master_count={}, actual_master={}, stack={}, width={})", .{
        total, master_count, actual_master, stack, screen_w,
    });
}

pub fn debugLayoutWindowGeometry(idx: usize, x: u16, y: u16, w: u16, h: u16, is_master: bool) void {
    if (isDebug()) {
        const area = if (is_master) "master" else "stack";
        std.log.debug("[layout] Window {}: {}x{}+{}+{} ({})", .{ idx, w, h, x, y, area });
    }
}

pub fn debugMasterSide(side: []const u8) void {
    if (isDebug()) std.log.debug("[master_layout] master_side value: '{s}' (len={})", .{ side, side.len });
}

pub fn debugMasterPosition(master_on_right: bool, master_x: u16) void {
    if (isDebug()) std.log.debug("[master_layout] master_on_right={}, master_x will be: {}", .{ master_on_right, master_x });
}

pub fn debugLayoutOverflow(max_fit: u16) void {
    if (isDebug()) std.log.debug("[layout:master_left] Overflow mode: max_fit={}", .{max_fit});
}

pub fn debugLayoutRow(row: u16, cols: u16) void {
    if (isDebug()) std.log.debug("[layout:master_left] Row {} has {} columns", .{ row, cols });
}

pub fn debugLayoutWindowIndex(win_idx: usize, row: u16, col: u16) void {
    if (isDebug()) std.log.debug("[layout:master_left] Window idx={} → row={} col={}", .{ win_idx, row, col });
}

// ============================================================================
// FULLSCREEN LOGGING
// ============================================================================

pub fn fullscreenEntered(win: u32) void {
    if (isDebug()) std.log.debug("[fullscreen] Entered for window 0x{x}", .{win});
}

pub fn fullscreenExited(win: u32) void {
    if (isDebug()) std.log.debug("[fullscreen] Exited for window 0x{x}", .{win});
}

// ============================================================================
// INPUT/ACTION LOGGING
// ============================================================================

pub fn actionCloseWindow(win: u32) void {
    if (isDebug()) std.log.debug("[action] Close window: 0x{x}", .{win});
}

pub fn actionToggleLayout() void {
    if (isDebug()) std.log.debug("[action] Toggle layout", .{});
}

pub fn actionToggleTiling() void {
    if (isDebug()) std.log.debug("[action] Toggle tiling", .{});
}

pub fn actionToggleFullscreen(win: u32) void {
    if (isDebug()) std.log.debug("[action] Toggle fullscreen: 0x{x}", .{win});
}

pub fn actionSwitchWorkspace(ws: usize) void {
    if (isDebug()) std.log.debug("[action] Switch to workspace {}", .{ws + 1});
}

pub fn actionMoveToWorkspace(win: u32, ws: usize) void {
    if (isDebug()) std.log.debug("[action] Move window 0x{x} to workspace {}", .{ win, ws + 1 });
}

pub fn actionExec(cmd: []const u8) void {
    if (isDebug()) std.log.debug("[action] Exec: {s}", .{cmd});
}

// ============================================================================
// WORKSPACE LOGGING
// ============================================================================

pub fn workspaceSwitched(from: usize, to: usize) void {
    if (isDebug()) std.log.debug("[workspace] Switched: {} → {}", .{ from + 1, to + 1 });
}

pub fn workspaceWindowAdded(win: u32, ws: usize) void {
    if (isDebug()) std.log.debug("[workspace] Added window 0x{x} to workspace {}", .{ win, ws + 1 });
}

pub fn workspaceWindowRemoved(win: u32, ws: usize) void {
    if (isDebug()) std.log.debug("[workspace] Removed window 0x{x} from workspace {}", .{ win, ws + 1 });
}

// ============================================================================
// WM LIFECYCLE LOGGING
// ============================================================================

pub fn wmStarted() void {
    std.log.info("[hana] Started", .{});
}

pub fn wmShuttingDown() void {
    std.log.info("[hana] Shutting down", .{});
}

// ============================================================================
// STATE DUMP LOGGING
// ============================================================================

pub fn dumpStateSeparator() void {
    std.log.info("========== STATE ==========", .{});
}

pub fn dumpStateEnd() void {
    std.log.info("===========================", .{});
}

pub fn dumpStateFocused(win: ?u32) void {
    std.log.info("Focused: {?x}", .{win});
}

pub fn dumpStateTotalWindows(count: usize) void {
    std.log.info("Total windows: {}", .{count});
}

pub fn dumpStateCurrentWorkspace(ws: usize) void {
    std.log.info("Current workspace: {}", .{ws + 1});
}

pub fn dumpStateWorkspace(idx: usize, count: usize) void {
    std.log.info("  WS{}: {} windows", .{ idx + 1, count });
}

pub fn dumpStateTiling(enabled: bool, count: usize) void {
    std.log.info("Tiling: {} ({} windows)", .{ enabled, count });
}

pub fn emergencyRecoveryStart() void {
    std.log.warn("========== RECOVERY ==========", .{});
}

pub fn emergencyRecoveryComplete() void {
    std.log.warn("Recovery complete", .{});
}
