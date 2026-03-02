//! drun — dwm-style command runner for the status bar.
//!
//! When active, the title segment area becomes a text input field. The user can
//! type a shell command and press Return to execute it via sh(1). A full
//! vim-style modal editing layer is built in.
//!
//! ── Vim-mode reference ───────────────────────────────────────────────────────
//!
//!  drun opens in INSERT mode. A mode label is pinned to the right edge of the
//!  field and updates live:
//!
//!    [INSERT]   normal typing
//!    [NORMAL]   motion / operator commands
//!    [VISUAL]   charwise visual selection
//!    [REPLACE]  overtype (R)
//!
//!  ┌─ INSERT mode ────────────────────────────────────────────────────────────┐
//!  │  Escape        → NORMAL mode (cursor clamps to last char)               │
//!  │  Return        → execute command and close                               │
//!  │  Ctrl+C        → close without executing                                 │
//!  │  Backspace     → delete char before cursor                               │
//!  │  Delete        → delete char at cursor                                   │
//!  │  ← → Home End  → move cursor                                             │
//!  │  Ctrl+W        → delete word before cursor                               │
//!  │  Ctrl+U        → delete from cursor to start of line                     │
//!  └──────────────────────────────────────────────────────────────────────────┘
//!
//!  ┌─ NORMAL mode — mode transitions ────────────────────────────────────────┐
//!  │  i             → INSERT at cursor                                        │
//!  │  I             → INSERT at first non-blank                               │
//!  │  a             → INSERT after cursor (append)                            │
//!  │  A             → INSERT at end of line                                   │
//!  │  s             → substitute [count] chars (= cl)                        │
//!  │  S             → substitute line (= cc)                                  │
//!  │  R             → REPLACE (overtype) mode                                 │
//!  │  v             → VISUAL mode (charwise selection)                        │
//!  │  Return        → execute and close                                       │
//!  │  Escape        → cancel partial command; or close if already clean       │
//!  │  Ctrl+C        → close without executing                                 │
//!  └──────────────────────────────────────────────────────────────────────────┘
//!
//!  ┌─ NORMAL mode — motions (all accept a [count] prefix) ───────────────────┐
//!  │  h / ←         → char left                                               │
//!  │  l / →         → char right                                              │
//!  │  w             → next word start (exclusive)                             │
//!  │  W             → next WORD start (exclusive)                             │
//!  │  b             → prev word start (exclusive)                             │
//!  │  B             → prev WORD start (exclusive)                             │
//!  │  e             → word end forward (inclusive)                            │
//!  │  E             → WORD end forward (inclusive)                            │
//!  │  ge            → word end backward (inclusive)                           │
//!  │  gE            → WORD end backward (inclusive)                           │
//!  │  0 / Home      → line start                                              │
//!  │  ^             → first non-blank                                         │
//!  │  $ / End       → line end                                                │
//!  │  f{c}          → find char forward (inclusive)                           │
//!  │  F{c}          → find char backward (inclusive)                          │
//!  │  t{c}          → till char forward (exclusive)                           │
//!  │  T{c}          → till char backward (exclusive)                          │
//!  │  ;             → repeat last f/F/t/T                                     │
//!  │  ,             → repeat last f/F/t/T reversed                            │
//!  │  %             → jump to matching bracket  ( ) [ ] { }                  │
//!  └──────────────────────────────────────────────────────────────────────────┘
//!
//!  ┌─ NORMAL mode — operators (combine with any motion or double for line) ──┐
//!  │  d{motion}     → delete range                                            │
//!  │  dd            → delete line                                             │
//!  │  D             → delete to end of line (= d$)                            │
//!  │  c{motion}     → change range (delete + INSERT)                          │
//!  │  cc            → change line                                             │
//!  │  C             → change to end of line (= c$)                            │
//!  │  y{motion}     → yank range to register                                  │
//!  │  yy            → yank line                                               │
//!  │  p             → paste register after cursor                             │
//!  │  P             → paste register before cursor                            │
//!  └──────────────────────────────────────────────────────────────────────────┘
//!
//!  ┌─ NORMAL mode — text objects (operator + i/a + delimiter) ───────────────┐
//!  │  iw / aw       → inner / a word                                          │
//!  │  iW / aW       → inner / a WORD                                          │
//!  │  i" / a"       → inner / a double-quoted string                          │
//!  │  i' / a'       → inner / a single-quoted string                          │
//!  │  i` / a`       → inner / a backtick string                               │
//!  │  i( / a(  (b)  → inner / a parenthesised block                           │
//!  │  i[ / a[       → inner / a square-bracket block                          │
//!  │  i{ / a{  (B)  → inner / a curly-brace block                             │
//!  │  i< / a<       → inner / a angle-bracket block                           │
//!  └──────────────────────────────────────────────────────────────────────────┘
//!
//!  ┌─ NORMAL mode — single-key edit commands ─────────────────────────────────┐
//!  │  x             → delete char at cursor ([count] chars)                   │
//!  │  X             → delete char before cursor ([count] chars)               │
//!  │  r{c}          → replace [count] chars at cursor with c                  │
//!  │  ~             → toggle case of [count] chars                            │
//!  │  u             → undo                                                     │
//!  │  Ctrl+R        → redo                                                     │
//!  │  .             → repeat last change                                       │
//!  │  m{a-z}        → set mark                                                 │
//!  │  '{a-z}        → jump to mark (or use in operator range)                  │
//!  │  Ctrl+A        → increment number under cursor by [count]                │
//!  │  Ctrl+X        → decrement number under cursor by [count]                │
//!  └──────────────────────────────────────────────────────────────────────────┘
//!
//!  ┌─ VISUAL mode ────────────────────────────────────────────────────────────┐
//!  │  All motions   → extend / shrink selection                               │
//!  │  d / x         → delete selection                                        │
//!  │  c             → change selection (delete + INSERT)                      │
//!  │  y             → yank selection                                           │
//!  │  ~             → toggle case of selection                                │
//!  │  Escape / v    → back to NORMAL mode                                     │
//!  └──────────────────────────────────────────────────────────────────────────┘
//!
//!  ┌─ REPLACE mode ───────────────────────────────────────────────────────────┐
//!  │  Printable     → overwrite char under cursor, advance                    │
//!  │  Backspace     → restore original char (within replaced range)           │
//!  │  Escape        → return to NORMAL mode                                   │
//!  │  Return        → execute and close                                       │
//!  └──────────────────────────────────────────────────────────────────────────┘
//!
//!  Count combining: [op-count] operator [motion-count] motion
//!  Effective count = max(1, op-count) × max(1, motion-count)
//!  Example: 2d3w  →  delete 6 words
//!
//! ── Integration checklist ────────────────────────────────────────────────────
//!
//!  1. bar.zig  — In drawSegment(), replace the `.title` arm dispatch so that
//!                when drun.isActive() is true, drun.draw() is called instead
//!                of title_segment.draw(). Both share the same signature:
//!
//!                  .title => if (drun.isActive())
//!                      try drun.draw(self.dc, self.config, self.height, x,
//!                          width orelse 100, self.conn, snap.focused_window,
//!                          snap.current_ws_wins.items, snap.minimized.items,
//!                          &self.cached_title, &self.cached_title_window,
//!                          snap.title_invalidated, self.allocator)
//!                  else
//!                      try title_segment.draw(...)
//!
//!                Also guard drawTitleOnly() with `if (!drun.isActive())`.
//!
//!  2. event loop — Call drun.handleKeyPress() *before* normal keybind dispatch:
//!
//!                  const kp: *xcb.xcb_key_press_event_t = @ptrCast(event);
//!                  if (drun.handleKeyPress(kp, wm)) {
//!                      bar.submitDrawAsync(wm);
//!                      continue;
//!                  }
//!
//!  3. action dispatch — Add a "drun_toggle" action calling drun.toggle(wm).
//!
//!  4. bar init / deinit — drun.init(conn) / drun.deinit().
//!
//! ── config.toml ──────────────────────────────────────────────────────────────
//!
//!   Mod+Shift+Tab = "drun_toggle"
//!
//! ─────────────────────────────────────────────────────────────────────────────

const std     = @import("std");
const defs    = @import("defs");
const xcb     = defs.xcb;
const drawing = @import("drawing");
const title   = @import("title");
const debug   = @import("debug");

const c = @cImport({
    @cInclude("unistd.h");
    @cInclude("stdlib.h");
    @cInclude("stdio.h");
    @cInclude("fcntl.h");
    @cInclude("dirent.h");
    @cInclude("sys/stat.h");
    @cInclude("sys/wait.h");
});

// ── xcb-keysyms bindings (link with -lxcb-keysyms) ───────────────────────────

const xcb_key_symbols_t = opaque {};

extern fn xcb_key_symbols_alloc(conn: *xcb.xcb_connection_t) ?*xcb_key_symbols_t;
extern fn xcb_key_symbols_free(syms: *xcb_key_symbols_t) void;
extern fn xcb_key_symbols_get_keysym(syms: *xcb_key_symbols_t, code: xcb.xcb_keycode_t, col: c_int) xcb.xcb_keysym_t;

// ── X11 keysym constants ──────────────────────────────────────────────────────

const XK_BackSpace : xcb.xcb_keysym_t = 0xff08;
const XK_Tab       : xcb.xcb_keysym_t = 0xff09;
const XK_Return    : xcb.xcb_keysym_t = 0xff0d;
const XK_Escape    : xcb.xcb_keysym_t = 0xff1b;
const XK_Delete    : xcb.xcb_keysym_t = 0xffff;
const XK_Left      : xcb.xcb_keysym_t = 0xff51;
const XK_Right     : xcb.xcb_keysym_t = 0xff53;
const XK_Home      : xcb.xcb_keysym_t = 0xff50;
const XK_End       : xcb.xcb_keysym_t = 0xff57;

// ── Constants ─────────────────────────────────────────────────────────────────

const MAX_INPUT    : usize = 512;
const MIN_CURSOR_PX: u16   = 8;
const CURSOR_WIDTH : u16   = 2;    // caret width in pixels (insert mode)
const CURSOR_BLINK_MS: i64 = 530;  // half-period: on for 530 ms, off for 530 ms
const CURSOR_V_PAD : u16   = 2;
const UNDO_MAX     : usize = 32;
const MARK_COUNT   : usize = 26; // marks a–z
const MAX_COMPLETIONS: usize = 4096;  // max executables stored
const MAX_COMP_LEN   : usize = 64;    // max length of a single executable name
const MAX_HIST       : usize = 512;   // history entries kept in memory
const MAX_HIST_LINE  : usize = MAX_INPUT; // max chars per history entry

// ── Helper types ──────────────────────────────────────────────────────────────

/// Editing modes, reflected live in the mode label.
/// The integer value is the index into DrunState.cached_mode_w.
const Mode = enum(u2) {
    insert  = 0,
    normal  = 1,
    visual  = 2,
    replace = 3,

    fn label(self: Mode) []const u8 {
        return switch (self) {
            .insert  => "[INSERT]",
            .normal  => "[NORMAL]",
            .visual  => "[VISUAL]",
            .replace => "[REPLACE]",
        };
    }
};

/// What the last change was — used by `.` to replay.
const DotKind = enum { none, direct, op_motion, op_line, insert_session };

/// Record of the last atomic change for `.` repeat.
const DotRecord = struct {
    kind:         DotKind              = .none,
    // op_motion / op_line:
    op:           u8                   = 0,
    op_count:     u32                  = 1,
    // op_motion only:
    motion_sym:   xcb.xcb_keysym_t    = 0,
    motion_count: u32                  = 1,
    g_prefix:     bool                 = false,  // ge / gE
    find_kind:    u8                   = 0,       // f/F/t/T motion
    find_ch:      u8                   = 0,
    tobj_kind:    u8                   = 0,       // 'i'/'a' for text objects
    tobj_delim:   u8                   = 0,
    // direct (x/X/D/C/~/r/p/P/s/S):
    direct_sym:   xcb.xcb_keysym_t    = 0,
    direct_count: u32                  = 1,
    direct_ch:    u8                   = 0,       // for r
    // insert text (for insert_session, c-op, s/S/C/cc):
    insert_buf:   [MAX_INPUT]u8        = undefined,
    insert_len:   usize                = 0,
};

/// Result returned by motion functions.
/// `pos`           — destination cursor position.
/// `inclusive`     — when true the char at `pos` is included in operator ranges.
/// `from_override` — when set (text objects), this is the range start instead of g.cursor.
const MotionResult = struct {
    pos:           usize,
    inclusive:     bool   = false,
    from_override: ?usize = null,
};

/// A single undo/redo snapshot.
const UndoEntry = struct {
    buf:    [MAX_INPUT]u8 = undefined,
    len:    usize         = 0,
    cursor: usize         = 0,
};

// ── Module state ──────────────────────────────────────────────────────────────

const DrunState = struct {
    active:           bool                 = false,
    mode:             Mode                 = .insert,

    buf:              [MAX_INPUT]u8        = undefined,
    len:              usize                = 0,
    cursor:           usize                = 0,

    key_syms:         ?*xcb_key_symbols_t  = null,
    cached_prompt_w:  ?u16                 = null,
    cached_mode_w:    [4]?u16              = .{ null, null, null, null },

    // ── Normal-mode sub-state ─────────────────────────────────────────────────
    n_count:          u32                  = 0,   // digit accumulator
    n_op:             u8                   = 0,   // pending operator ('d'/'c'/'y')
    n_op_count:       u32                  = 0,   // count when operator was armed
    n_find_kind:      u8                   = 0,   // pending f/F/t/T
    n_pending_r:      bool                 = false,
    n_pending_g:      bool                 = false,
    n_text_obj_kind:  u8                   = 0,   // pending 'i'/'a' for text object
    n_pending_m:      bool                 = false, // 'm' pressed, waiting for letter
    n_pending_apos:   bool                 = false, // "'" pressed, waiting for letter

    // Last f/F/t/T for ';' / ',' repeat.
    last_find_kind:   u8                   = 0,
    last_find_ch:     u8                   = 0,

    // ── Yank / delete register ────────────────────────────────────────────────
    yank_buf:         [MAX_INPUT]u8        = undefined,
    yank_len:         usize                = 0,

    // ── Visual mode ───────────────────────────────────────────────────────────
    vis_anchor:       usize                = 0,

    // ── Replace mode ──────────────────────────────────────────────────────────
    replace_orig_buf: [MAX_INPUT]u8        = undefined,
    replace_orig_len: usize                = 0,
    replace_orig_cur: usize                = 0,   // cursor position when R was pressed

    // ── Marks a–z ─────────────────────────────────────────────────────────────
    marks:            [MARK_COUNT]?usize   = [_]?usize{null} ** MARK_COUNT,

    // ── Undo / redo ───────────────────────────────────────────────────────────
    undo_stack:       [UNDO_MAX]UndoEntry  = undefined,
    undo_top:         usize                = 0,
    redo_stack:       [UNDO_MAX]UndoEntry  = undefined,
    redo_top:         usize                = 0,

    // ── Dot repeat ────────────────────────────────────────────────────────────
    dot:              DotRecord            = .{},
    in_dot_replay:    bool                 = false,
    recording_insert: bool                 = false,
    insert_rec_buf:   [MAX_INPUT]u8        = undefined,
    insert_rec_len:   usize                = 0,

    // ── PATH completion ───────────────────────────────────────────────────────
    // comp_names is a flat array of fixed-size slots: comp_names[i * (MAX_COMP_LEN+1)]
    // is the start of the i-th null-terminated executable name.
    comp_names: [(MAX_COMP_LEN + 1) * MAX_COMPLETIONS]u8 = undefined,
    comp_count: usize = 0,

    // Ghost text (the completion suffix shown dimmed after the cursor).
    ghost_buf:  [MAX_COMP_LEN]u8 = undefined,
    ghost_len:  usize            = 0,

    // timerfd used to drive cursor blink redraws (-1 = not open).
    blink_fd:   i32              = -1,

    // ── Command history (newest at index 0) ───────────────────────────────────
    // Flat array: hist_entries[i * (MAX_HIST_LINE+1)] starts the i-th entry.
    hist_entries:   [(MAX_HIST_LINE + 1) * MAX_HIST]u8 = undefined,
    hist_count:     usize = 0,
    hist_loaded:    bool  = false,
};

var g: DrunState = .{};

// ── Public API ────────────────────────────────────────────────────────────────

pub fn isActive() bool { return g.active; }

/// Returns true when drun is active in insert mode, signalling that the bar
/// should schedule a periodic redraw so the cursor blink animation runs.
pub fn needsRedraw() bool { return g.active and g.mode == .insert; }

/// Returns the blink timerfd (or -1 if not active / not supported).
/// The main event loop should add this fd to its poll set and call
/// bar.submitDrawAsync() whenever it fires, so the cursor actually blinks
/// between keystrokes.  The fd is automatically opened/closed by
/// activate()/deactivate().
pub fn blinkFd() i32 { return g.blink_fd; }

pub fn init(conn: *xcb.xcb_connection_t) void {
    if (g.key_syms != null) return;
    g.key_syms = xcb_key_symbols_alloc(conn);
    if (g.key_syms == null)
        debug.warn("drun: xcb_key_symbols_alloc failed — key input will not work", .{});
}

pub fn deinit() void {
    if (g.key_syms) |ks| {
        xcb_key_symbols_free(ks);
        g.key_syms = null;
    }
}

pub fn toggle(wm: *defs.WM) void {
    if (g.active) deactivate(wm) else activate(wm);
}

pub fn handleKeyPress(event: *const xcb.xcb_key_press_event_t, wm: *defs.WM) bool {
    if (!g.active) return false;

    const syms = g.key_syms orelse return true;

    const shift_held = event.state & xcb.XCB_MOD_MASK_SHIFT   != 0;
    const ctrl_held  = event.state & xcb.XCB_MOD_MASK_CONTROL != 0;
    const col: c_int = if (shift_held) 1 else 0;
    const sym        = xcb_key_symbols_get_keysym(syms, event.detail, col);

    // ── Ctrl-modified keys (all modes) ────────────────────────────────────────
    if (ctrl_held) {
        switch (sym) {
            'c' => deactivate(wm),
            'r' => if (g.mode == .normal or g.mode == .visual) { undoRedo(); },
            'w' => if (g.mode == .insert) { ctrlW(); },
            'u' => if (g.mode == .insert) { ctrlU(); },
            'a' => if (g.mode == .normal) { ctrlAdjustNumber(1);  resetNormalSub(); },
            'x' => if (g.mode == .normal) { ctrlAdjustNumber(-1); resetNormalSub(); },
            else => {},
        }
        return true;
    }

    switch (g.mode) {
        .insert  => handleInsert(sym, wm),
        .normal  => handleNormal(sym, wm),
        .visual  => handleVisual(sym, wm),
        .replace => handleReplace(sym, wm),
    }
    updateGhost();
    return true;
}

pub fn draw(
    dc:                  *drawing.DrawContext,
    config:              defs.BarConfig,
    height:              u16,
    start_x:             u16,
    width:               u16,
    conn:                *xcb.xcb_connection_t,
    focused_window:      ?u32,
    current_ws_wins:     []const u32,
    minimized:           []const u32,
    cached_title:        *std.ArrayList(u8),
    cached_title_window: *?u32,
    title_invalidated:   bool,
    allocator:           std.mem.Allocator,
) !u16 {
    if (!g.active) {
        return title.draw(
            dc, config, height, start_x, width,
            conn, focused_window, current_ws_wins, minimized,
            cached_title, cached_title_window, title_invalidated, allocator,
        );
    }
    return drawActive(dc, config, height, start_x, width);
}

// ── Activate / deactivate ─────────────────────────────────────────────────────

fn activate(wm: *defs.WM) void {
    g.len              = 0;
    g.cursor           = 0;
    g.mode             = .insert;
    g.yank_len         = 0;
    g.undo_top         = 0;
    g.redo_top         = 0;
    g.last_find_kind   = 0;
    g.last_find_ch     = 0;
    g.vis_anchor       = 0;
    g.marks            = [_]?usize{null} ** MARK_COUNT;
    g.dot              = .{};
    g.in_dot_replay    = false;
    g.recording_insert = false;
    g.insert_rec_len   = 0;
    g.ghost_len        = 0;
    resetNormalSub();
    // Load completions and history on first activation.
    if (g.comp_count == 0) loadCompletions();
    if (!g.hist_loaded) loadHistory();
    g.active = true;

    // Open a timerfd that fires every CURSOR_BLINK_MS so the caret blinks
    // even when no keystrokes arrive.
    if (g.blink_fd == -1) {
        if (std.posix.timerfd_create(.MONOTONIC, .{ .NONBLOCK = true, .CLOEXEC = true })) |fd| {
            const ms: u64 = @intCast(CURSOR_BLINK_MS);
            const spec = std.os.linux.itimerspec{
                .it_interval = .{ .sec = @intCast(ms / 1000), .nsec = @intCast((ms % 1000) * 1_000_000) },
                .it_value    = .{ .sec = @intCast(ms / 1000), .nsec = @intCast((ms % 1000) * 1_000_000) },
            };
            std.posix.timerfd_settime(fd, .{}, &spec, null) catch {};
            g.blink_fd = fd;
        } else |_| {}
    }

    const cookie = xcb.xcb_grab_keyboard(
        wm.conn, 0, wm.root, xcb.XCB_CURRENT_TIME,
        xcb.XCB_GRAB_MODE_ASYNC, xcb.XCB_GRAB_MODE_ASYNC,
    );
    xcb.xcb_discard_reply(wm.conn, cookie.sequence);
    _ = xcb.xcb_flush(wm.conn);
}

fn deactivate(wm: *defs.WM) void {
    g.active           = false;
    g.in_dot_replay    = false;
    g.recording_insert = false;
    g.cached_prompt_w  = null;
    g.cached_mode_w    = .{ null, null, null, null };
    resetNormalSub();
    if (g.blink_fd >= 0) {
        _ = c.close(g.blink_fd);
        g.blink_fd = -1;
    }
    _ = xcb.xcb_ungrab_keyboard(wm.conn, xcb.XCB_CURRENT_TIME);
    _ = xcb.xcb_flush(wm.conn);
}

// ── INSERT mode handler ───────────────────────────────────────────────────────

fn handleInsert(sym: xcb.xcb_keysym_t, wm: *defs.WM) void {
    switch (sym) {
        XK_Escape => {
            // Finalise dot record insert text.
            if (g.recording_insert) {
                g.recording_insert = false;
                @memcpy(g.dot.insert_buf[0..g.insert_rec_len], g.insert_rec_buf[0..g.insert_rec_len]);
                g.dot.insert_len = g.insert_rec_len;
            }
            // Clamp cursor: in normal mode cursor must sit on a character.
            if (g.len > 0 and g.cursor == g.len) g.cursor = g.len - 1;
            g.mode = .normal;
            resetNormalSub();
        },

        XK_Return => {
            const cmd = g.buf[0..g.len];
            if (cmd.len > 0) spawnCommand(cmd);
            deactivate(wm);
        },

        XK_Tab => {
            // Accept ghost completion if one is shown; otherwise ignore.
            if (g.ghost_len > 0 and g.cursor == g.len) {
                const n = @min(g.ghost_len, MAX_INPUT - 1 - g.len);
                if (n > 0) {
                    @memcpy(g.buf[g.len .. g.len + n], g.ghost_buf[0..n]);
                    g.len    += n;
                    g.cursor  = g.len;
                    g.ghost_len = 0;
                }
            }
        },

        XK_BackSpace => deleteBefore(),
        XK_Delete    => deleteAfter(),
        XK_Left      => { if (g.cursor > 0) g.cursor -= 1; },
        XK_Right     => { if (g.cursor < g.len) g.cursor += 1; },
        XK_Home      => g.cursor = 0,
        XK_End       => g.cursor = g.len,

        else => {
            if (sym >= 0x20 and sym <= 0x7e) {
                const ch: u8 = @truncate(sym);
                insertChar(ch);
                // Record for dot repeat.
                if (g.recording_insert and g.insert_rec_len < MAX_INPUT - 1) {
                    g.insert_rec_buf[g.insert_rec_len] = ch;
                    g.insert_rec_len += 1;
                }
            }
        },
    }
}

// ── NORMAL mode handler ───────────────────────────────────────────────────────

fn handleNormal(sym: xcb.xcb_keysym_t, wm: *defs.WM) void {

    // ── 1. Pending r{c} ───────────────────────────────────────────────────────
    if (g.n_pending_r) {
        if (sym >= 0x20 and sym <= 0x7e and g.cursor < g.len) {
            const ch: u8   = @truncate(sym);
            const cnt: u32 = effCount();
            g.dot = .{ .kind = .direct, .direct_sym = 'r', .direct_count = cnt, .direct_ch = ch };
            undoPush();
            var i: usize = 0;
            while (i < cnt and g.cursor + i < g.len) : (i += 1) g.buf[g.cursor + i] = ch;
            g.cursor = @min(g.cursor + cnt - 1, g.len -| 1);
        }
        resetNormalSub();
        return;
    }

    // ── 2. Pending f/F/t/T char ───────────────────────────────────────────────
    if (g.n_find_kind != 0) {
        if (sym >= 0x20 and sym <= 0x7e) {
            const ch: u8   = @truncate(sym);
            const cnt: u32 = effCount();
            const kind     = g.n_find_kind;
            const mr       = motionFind(kind, ch, cnt);
            g.last_find_kind = kind;
            g.last_find_ch   = ch;
            if (g.n_op != 0) {
                g.dot = DotRecord{
                    .kind = .op_motion, .op = g.n_op, .op_count = g.n_op_count,
                    .motion_count = g.n_count, .find_kind = kind, .find_ch = ch,
                };
                doOp(g.n_op, mr);
            } else {
                setCursor(mr);
            }
        }
        resetNormalSub();
        return;
    }

    // ── 3. Pending g-prefix ───────────────────────────────────────────────────
    if (g.n_pending_g) {
        const cnt = effCount();
        const mr_opt: ?MotionResult = switch (sym) {
            'e'     => MotionResult{ .pos = motionWordEndBack(false, cnt), .inclusive = true },
            'E'     => MotionResult{ .pos = motionWordEndBack(true,  cnt), .inclusive = true },
            'g', '0', XK_Home => MotionResult{ .pos = 0 },
            '$', XK_End       => MotionResult{ .pos = g.len },
            else    => null,
        };
        if (mr_opt) |mr| {
            if (g.n_op != 0) {
                g.dot = DotRecord{
                    .kind = .op_motion, .op = g.n_op, .op_count = g.n_op_count,
                    .motion_count = g.n_count, .motion_sym = sym,
                    .g_prefix = true,
                };
                doOp(g.n_op, mr);
            } else {
                setCursor(mr);
            }
        }
        resetNormalSub();
        return;
    }

    // ── 3.5. Pending text-object delimiter ────────────────────────────────────
    if (g.n_text_obj_kind != 0) {
        if (sym >= 0x20 and sym <= 0x7e) {
            const ch: u8 = @truncate(sym);
            if (resolveTextObject(g.n_text_obj_kind, ch)) |mr| {
                g.dot = DotRecord{
                    .kind = .op_motion, .op = g.n_op, .op_count = g.n_op_count,
                    .motion_count = g.n_count,
                    .tobj_kind = g.n_text_obj_kind, .tobj_delim = ch,
                };
                doOp(g.n_op, mr);
            }
        }
        resetNormalSub();
        return;
    }

    // ── 3.6. Pending mark set (m{a-z}) ───────────────────────────────────────
    if (g.n_pending_m) {
        if (sym >= 'a' and sym <= 'z')
            g.marks[@as(usize, @intCast(sym - 'a'))] = g.cursor;
        resetNormalSub();
        return;
    }

    // ── 3.7. Pending mark jump ('{a-z}) ──────────────────────────────────────
    if (g.n_pending_apos) {
        if (sym >= 'a' and sym <= 'z') {
            if (g.marks[@as(usize, @intCast(sym - 'a'))]) |pos| {
                const mr = MotionResult{ .pos = pos };
                if (g.n_op != 0) doOp(g.n_op, mr) else setCursor(mr);
            }
        }
        resetNormalSub();
        return;
    }

    // ── 4. Digit accumulation ─────────────────────────────────────────────────
    if (sym >= '1' and sym <= '9') {
        g.n_count = g.n_count *% 10 +% @as(u32, @truncate(sym - '0'));
        return;
    }
    if (sym == '0' and g.n_count > 0) {
        g.n_count = g.n_count *% 10;
        return;
    }

    // ── 5. ; / , (repeat last find) ──────────────────────────────────────────
    if (sym == ';' or sym == ',') {
        if (g.last_find_kind != 0) {
            const cnt  = effCount();
            const kind = if (sym == ',') reverseFindKind(g.last_find_kind) else g.last_find_kind;
            const mr   = motionFind(kind, g.last_find_ch, cnt);
            if (g.n_op != 0) doOp(g.n_op, mr) else setCursor(mr);
        }
        resetNormalSub();
        return;
    }

    // ── 6. Simple motions ─────────────────────────────────────────────────────
    if (resolveSimpleMotion(sym, effCount())) |mr| {
        if (g.n_op != 0) {
            g.dot = DotRecord{
                .kind = .op_motion, .op = g.n_op, .op_count = g.n_op_count,
                .motion_count = g.n_count, .motion_sym = sym,
            };
            doOp(g.n_op, mr);
        } else {
            setCursor(mr);
        }
        resetNormalSub();
        return;
    }

    // ── 7. Operator arming / text-object detection ────────────────────────────
    // When an operator is already armed, i/a become text-object prefix.
    if ((sym == 'i' or sym == 'a') and g.n_op != 0) {
        g.n_text_obj_kind = @truncate(sym);
        return; // wait for delimiter
    }
    if (sym == 'd' or sym == 'c' or sym == 'y') {
        const op: u8 = @truncate(sym);
        if (g.n_op == 0) {
            g.n_op       = op;
            g.n_op_count = g.n_count;
            g.n_count    = 0;
            return;
        }
        if (g.n_op == op) {
            // Doubling: dd / cc / yy.
            g.dot = DotRecord{ .kind = .op_line, .op = op, .op_count = g.n_op_count, .motion_count = g.n_count };
            doOpLine(op);
        }
        resetNormalSub();
        return;
    }

    // ── 8. Prefix arming ─────────────────────────────────────────────────────
    if (sym == 'f' or sym == 'F' or sym == 't' or sym == 'T') {
        g.n_find_kind = @truncate(sym);
        return;
    }
    if (sym == 'g')                        { g.n_pending_g    = true; return; }
    if (sym == 'r' and g.n_op == 0)        { g.n_pending_r    = true; return; }
    if (sym == 'm' and g.n_op == 0)        { g.n_pending_m    = true; return; }
    if (sym == 0x27)                        { g.n_pending_apos = true; return; } // apostrophe / single-quote

    // ── 9. Single-key commands ────────────────────────────────────────────────
    const cnt = effCount();

    switch (sym) {

        XK_Escape => {
            if (g.n_op != 0 or g.n_count != 0) {
                // Cancel partial command, stay in normal mode.
            } else {
                deactivate(wm);
            }
            resetNormalSub();
            return;
        },

        XK_Return => {
            const cmd = g.buf[0..g.len];
            if (cmd.len > 0) spawnCommand(cmd);
            deactivate(wm);
            return;
        },

        'x' => {
            g.dot = .{ .kind = .direct, .direct_sym = 'x', .direct_count = cnt };
            doOp('d', MotionResult{ .pos = charRight(cnt) });
        },
        'X' => {
            g.dot = .{ .kind = .direct, .direct_sym = 'X', .direct_count = cnt };
            doOp('d', MotionResult{ .pos = charLeft(cnt) });
        },

        'D' => {
            g.dot = .{ .kind = .direct, .direct_sym = 'D', .direct_count = cnt };
            doOp('d', MotionResult{ .pos = g.len });
        },
        'C' => {
            g.dot = .{ .kind = .direct, .direct_sym = 'C', .direct_count = cnt };
            doOp('c', MotionResult{ .pos = g.len });
        },

        'p' => {
            if (g.yank_len > 0) {
                g.dot = .{ .kind = .direct, .direct_sym = 'p', .direct_count = cnt };
                undoPush();
                var i: u32 = 0;
                while (i < cnt) : (i += 1) pasteAfter();
            }
        },
        'P' => {
            if (g.yank_len > 0) {
                g.dot = .{ .kind = .direct, .direct_sym = 'P', .direct_count = cnt };
                undoPush();
                var i: u32 = 0;
                while (i < cnt) : (i += 1) pasteBefore();
            }
        },

        '~' => {
            g.dot = .{ .kind = .direct, .direct_sym = '~', .direct_count = cnt };
            undoPush();
            var i: u32 = 0;
            while (i < cnt) : (i += 1) toggleCaseOnce();
        },

        's' => {
            g.dot = .{ .kind = .direct, .direct_sym = 's', .direct_count = cnt };
            doOp('c', MotionResult{ .pos = charRight(cnt) });
        },
        'S' => {
            g.dot = .{ .kind = .direct, .direct_sym = 'S', .direct_count = cnt };
            undoPush();
            yankRange(0, g.len);
            g.len    = 0;
            g.cursor = 0;
            startInsertMode();
        },

        'i' => { g.dot = .{ .kind = .insert_session }; enterInsert(); },
        'I' => { g.cursor = firstNonBlank(); g.dot = .{ .kind = .insert_session }; enterInsert(); },
        'a' => { if (g.cursor < g.len) g.cursor += 1; g.dot = .{ .kind = .insert_session }; enterInsert(); },
        'A' => { g.cursor = g.len; g.dot = .{ .kind = .insert_session }; enterInsert(); },

        'v' => {
            g.vis_anchor = g.cursor;
            g.mode = .visual;
            resetNormalSub();
            return;
        },

        'R' => {
            undoPush();
            @memcpy(g.replace_orig_buf[0..g.len], g.buf[0..g.len]);
            g.replace_orig_len = g.len;
            g.replace_orig_cur = g.cursor;
            g.mode = .replace;
            resetNormalSub();
            return;
        },

        '%' => {
            const pos = motionMatchBracket();
            if (g.n_op != 0) {
                doOp(g.n_op, MotionResult{ .pos = pos, .inclusive = true });
            } else {
                setCursor(MotionResult{ .pos = pos });
            }
        },

        'u' => undoUndo(),
        '.' => { dotReplay(wm); resetNormalSub(); return; },

        else => {},
    }

    resetNormalSub();
}

// ── VISUAL mode handler ───────────────────────────────────────────────────────

fn handleVisual(sym: xcb.xcb_keysym_t, wm: *defs.WM) void {

    // Resolve pending find in visual mode.
    if (g.n_find_kind != 0) {
        if (sym >= 0x20 and sym <= 0x7e) {
            const ch: u8  = @truncate(sym);
            const cnt     = effCount();
            const kind    = g.n_find_kind;
            const mr      = motionFind(kind, ch, cnt);
            g.last_find_kind = kind;
            g.last_find_ch   = ch;
            setCursorVisual(mr.pos);
        }
        resetNormalSub();
        return;
    }

    // Resolve pending g-prefix in visual mode.
    if (g.n_pending_g) {
        const cnt = effCount();
        const pos: ?usize = switch (sym) {
            'e'     => motionWordEndBack(false, cnt),
            'E'     => motionWordEndBack(true,  cnt),
            'g', '0', XK_Home => @as(usize, 0),
            '$', XK_End       => g.len,
            else    => null,
        };
        if (pos) |p| setCursorVisual(p);
        resetNormalSub();
        return;
    }

    // Digit accumulation.
    if (sym >= '1' and sym <= '9') { g.n_count = g.n_count *% 10 +% @as(u32, @truncate(sym - '0')); return; }
    if (sym == '0' and g.n_count > 0) { g.n_count = g.n_count *% 10; return; }

    // ; / , repeat find.
    if (sym == ';' or sym == ',') {
        if (g.last_find_kind != 0) {
            const cnt  = effCount();
            const kind = if (sym == ',') reverseFindKind(g.last_find_kind) else g.last_find_kind;
            setCursorVisual(motionFind(kind, g.last_find_ch, cnt).pos);
        }
        resetNormalSub();
        return;
    }

    // Simple motions extend selection.
    if (resolveSimpleMotion(sym, effCount())) |mr| {
        setCursorVisual(mr.pos);
        resetNormalSub();
        return;
    }

    // Prefix arming for visual mode.
    if (sym == 'g')                  { g.n_pending_g = true; return; }
    if (sym == 'f' or sym == 'F' or sym == 't' or sym == 'T') { g.n_find_kind = @truncate(sym); return; }

    // Operator and other keys.
    switch (sym) {

        XK_Escape, 'v' => {
            g.mode = .normal;
            resetNormalSub();
        },

        XK_Return => {
            const cmd = g.buf[0..g.len];
            if (cmd.len > 0) spawnCommand(cmd);
            deactivate(wm);
        },

        'd', 'x' => {
            const sel = visualRange();
            undoPush();
            yankRange(sel[0], sel[1]);
            deleteRange(sel[0], sel[1]);
            g.mode = .normal;
            resetNormalSub();
        },

        'c' => {
            const sel = visualRange();
            g.dot = .{ .kind = .op_line, .op = 'c' }; // simplified — treats as line-level for dot
            undoPush();
            yankRange(sel[0], sel[1]);
            deleteRange(sel[0], sel[1]);
            g.mode = .normal;
            resetNormalSub();
            startInsertMode();
        },

        'y' => {
            const sel = visualRange();
            yankRange(sel[0], sel[1]);
            g.cursor = sel[0];
            g.mode = .normal;
            resetNormalSub();
        },

        '~' => {
            const sel = visualRange();
            undoPush();
            var i = sel[0];
            while (i < sel[1]) : (i += 1) {
                const ch = g.buf[i];
                g.buf[i] = if (std.ascii.isLower(ch)) std.ascii.toUpper(ch)
                           else if (std.ascii.isUpper(ch)) std.ascii.toLower(ch)
                           else ch;
            }
            g.cursor = sel[0];
            g.mode = .normal;
            resetNormalSub();
        },

        else => resetNormalSub(),
    }
}

// ── REPLACE mode handler ──────────────────────────────────────────────────────

fn handleReplace(sym: xcb.xcb_keysym_t, wm: *defs.WM) void {
    switch (sym) {
        XK_Escape => {
            if (g.len > 0 and g.cursor == g.len) g.cursor = g.len - 1;
            g.mode = .normal;
        },

        XK_Return => {
            const cmd = g.buf[0..g.len];
            if (cmd.len > 0) spawnCommand(cmd);
            deactivate(wm);
        },

        XK_BackSpace => {
            if (g.cursor > g.replace_orig_cur) {
                g.cursor -= 1;
                if (g.cursor < g.replace_orig_len) {
                    // Restore original character (we overwrote it).
                    g.buf[g.cursor] = g.replace_orig_buf[g.cursor];
                    // len is unchanged (we overwrote, not inserted).
                } else {
                    // We had extended the buffer; delete the appended char.
                    if (g.cursor < g.len - 1) {
                        std.mem.copyForwards(u8, g.buf[g.cursor .. g.len - 1], g.buf[g.cursor + 1 .. g.len]);
                    }
                    g.len -= 1;
                }
            }
        },

        else => {
            if (sym >= 0x20 and sym <= 0x7e) {
                const ch: u8 = @truncate(sym);
                if (g.cursor < g.len) {
                    // Overwrite.
                    g.buf[g.cursor] = ch;
                    g.cursor += 1;
                } else if (g.len < MAX_INPUT - 1) {
                    // Extend.
                    g.buf[g.len] = ch;
                    g.len    += 1;
                    g.cursor += 1;
                }
            }
        },
    }
}

// ── Motion resolvers ──────────────────────────────────────────────────────────

fn resolveSimpleMotion(sym: xcb.xcb_keysym_t, cnt: u32) ?MotionResult {
    return switch (sym) {
        'h', XK_Left  => MotionResult{ .pos = charLeft(cnt)             },
        'l', XK_Right => MotionResult{ .pos = charRight(cnt)            },
        'w'           => MotionResult{ .pos = motionWordNext(false, cnt) },
        'W'           => MotionResult{ .pos = motionWordNext(true,  cnt) },
        'b'           => MotionResult{ .pos = motionWordPrev(false, cnt) },
        'B'           => MotionResult{ .pos = motionWordPrev(true,  cnt) },
        'e'           => MotionResult{ .pos = motionWordEnd(false, cnt),  .inclusive = true },
        'E'           => MotionResult{ .pos = motionWordEnd(true,  cnt),  .inclusive = true },
        '0', XK_Home  => MotionResult{ .pos = 0                          },
        '^'           => MotionResult{ .pos = firstNonBlank()             },
        '$', XK_End   => MotionResult{ .pos = g.len                      },
        else          => null,
    };
}

// ── Primitive motion functions ────────────────────────────────────────────────

inline fn isWordChar(ch: u8) bool {
    return std.ascii.isAlphanumeric(ch) or ch == '_';
}

fn charLeft(cnt: u32) usize {
    return g.cursor -| @as(usize, cnt);
}

fn charRight(cnt: u32) usize {
    return @min(g.cursor + @as(usize, cnt), g.len);
}

fn motionWordNext(big: bool, cnt: u32) usize {
    var p = g.cursor;
    var i: u32 = 0;
    while (i < cnt) : (i += 1) {
        if (p >= g.len) break;
        if (big) {
            while (p < g.len and g.buf[p] != ' ') p += 1;
        } else {
            if (isWordChar(g.buf[p])) {
                while (p < g.len and  isWordChar(g.buf[p])) p += 1;
            } else if (g.buf[p] != ' ') {
                while (p < g.len and !isWordChar(g.buf[p]) and g.buf[p] != ' ') p += 1;
            }
        }
        while (p < g.len and g.buf[p] == ' ') p += 1;
    }
    return p;
}

fn motionWordPrev(big: bool, cnt: u32) usize {
    var p = g.cursor;
    var i: u32 = 0;
    while (i < cnt) : (i += 1) {
        if (p == 0) break;
        while (p > 0 and g.buf[p - 1] == ' ') p -= 1;
        if (p == 0) break;
        if (big) {
            while (p > 0 and g.buf[p - 1] != ' ') p -= 1;
        } else {
            if (isWordChar(g.buf[p - 1])) {
                while (p > 0 and isWordChar(g.buf[p - 1])) p -= 1;
            } else {
                while (p > 0 and !isWordChar(g.buf[p - 1]) and g.buf[p - 1] != ' ') p -= 1;
            }
        }
    }
    return p;
}

fn motionWordEnd(big: bool, cnt: u32) usize {
    var p = g.cursor;
    var i: u32 = 0;
    while (i < cnt) : (i += 1) {
        if (p >= g.len) break;
        p += 1;
        while (p < g.len and g.buf[p] == ' ') p += 1;
        if (p >= g.len) { p = g.len; break; }
        if (big) {
            while (p + 1 < g.len and g.buf[p + 1] != ' ') p += 1;
        } else {
            if (isWordChar(g.buf[p])) {
                while (p + 1 < g.len and isWordChar(g.buf[p + 1])) p += 1;
            } else {
                while (p + 1 < g.len and !isWordChar(g.buf[p + 1]) and g.buf[p + 1] != ' ') p += 1;
            }
        }
    }
    return @min(p, g.len -| 1);
}

fn motionWordEndBack(big: bool, cnt: u32) usize {
    var p = g.cursor;
    var i: u32 = 0;
    while (i < cnt) : (i += 1) {
        if (p == 0) break;
        if (g.buf[p] != ' ') {
            if (big) {
                while (p > 0 and g.buf[p - 1] != ' ') p -= 1;
            } else {
                if (isWordChar(g.buf[p])) {
                    while (p > 0 and isWordChar(g.buf[p - 1])) p -= 1;
                } else {
                    while (p > 0 and !isWordChar(g.buf[p - 1]) and g.buf[p - 1] != ' ') p -= 1;
                }
            }
        }
        if (p == 0) break;
        p -= 1;
        while (p > 0 and g.buf[p] == ' ') p -= 1;
    }
    return p;
}

fn motionFind(kind: u8, ch: u8, cnt: u32) MotionResult {
    var p  = g.cursor;
    var i: u32 = 0;
    while (i < cnt) : (i += 1) {
        switch (kind) {
            'f' => {
                var q = p + 1;
                while (q < g.len and g.buf[q] != ch) q += 1;
                if (q < g.len) p = q else break;
            },
            'F' => {
                if (p == 0) break;
                var q = p - 1;
                while (g.buf[q] != ch) {
                    if (q == 0) { q = g.len; break; }
                    q -= 1;
                }
                if (q < g.len) p = q else break;
            },
            't' => {
                var q = p + 1;
                while (q < g.len and g.buf[q] != ch) q += 1;
                if (q < g.len and q > 0) p = q - 1 else break;
            },
            'T' => {
                if (p == 0) break;
                var q = p - 1;
                while (g.buf[q] != ch) {
                    if (q == 0) { q = g.len; break; }
                    q -= 1;
                }
                if (q < g.len and q + 1 <= g.cursor) p = q + 1 else break;
            },
            else => {},
        }
    }
    return .{ .pos = p, .inclusive = (kind == 'f' or kind == 'F') };
}

fn reverseFindKind(kind: u8) u8 {
    return switch (kind) {
        'f' => 'F', 'F' => 'f',
        't' => 'T', 'T' => 't',
        else => kind,
    };
}

fn firstNonBlank() usize {
    var p: usize = 0;
    while (p < g.len and g.buf[p] == ' ') p += 1;
    return p;
}

/// Jump to the bracket that matches the one under the cursor.
fn motionMatchBracket() usize {
    if (g.cursor >= g.len) return g.cursor;
    const ch = g.buf[g.cursor];
    const open: u8  = switch (ch) { '(' => '(', '[' => '[', '{' => '{', ')' => '(', ']' => '[', '}' => '{', else => 0 };
    const close: u8 = switch (ch) { '(' => ')', '[' => ']', '{' => '}', ')' => ')', ']' => ']', '}' => '}', else => 0 };
    if (open == 0) return g.cursor;

    const forward = (ch == '(' or ch == '[' or ch == '{');
    var depth: i32 = 0;

    if (forward) {
        var p = g.cursor;
        while (p < g.len) : (p += 1) {
            if      (g.buf[p] == open)  { depth += 1; }
            else if (g.buf[p] == close) { depth -= 1; if (depth == 0) return p; }
        }
    } else {
        var p = g.cursor;
        while (true) {
            if      (g.buf[p] == close) { depth += 1; }
            else if (g.buf[p] == open)  { depth -= 1; if (depth == 0) return p; }
            if (p == 0) break;
            p -= 1;
        }
    }
    return g.cursor;
}

// ── Text object resolver ──────────────────────────────────────────────────────

fn resolveTextObject(kind: u8, delim: u8) ?MotionResult {
    const inner = (kind == 'i');
    return switch (delim) {
        'w'           => textObjWord(false, inner),
        'W'           => textObjWord(true,  inner),
        '"', '\'', '`' => textObjQuote(delim, inner),
        '(', ')', 'b' => textObjBracket('(', ')', inner),
        '[', ']'       => textObjBracket('[', ']', inner),
        '{', '}', 'B'  => textObjBracket('{', '}', inner),
        '<', '>'       => textObjBracket('<', '>', inner),
        else           => null,
    };
}

fn textObjWord(big: bool, inner: bool) ?MotionResult {
    if (g.len == 0) return null;
    var lo = g.cursor;
    var hi = g.cursor;

    const on_word = if (big) g.buf[g.cursor] != ' ' else isWordChar(g.buf[g.cursor]);

    if (on_word) {
        // Extend left to start of current word.
        if (big) {
            while (lo > 0 and g.buf[lo - 1] != ' ') lo -= 1;
        } else {
            while (lo > 0 and isWordChar(g.buf[lo - 1])) lo -= 1;
        }
        // Extend right to end of current word (exclusive).
        if (big) {
            while (hi < g.len and g.buf[hi] != ' ') hi += 1;
        } else {
            while (hi < g.len and isWordChar(g.buf[hi])) hi += 1;
        }
        // For 'a', consume trailing space (or leading if at end of buffer).
        if (!inner) {
            if (hi < g.len and g.buf[hi] == ' ') {
                while (hi < g.len and g.buf[hi] == ' ') hi += 1;
            } else {
                while (lo > 0 and g.buf[lo - 1] == ' ') lo -= 1;
            }
        }
    } else {
        // On whitespace: select the whitespace run.
        while (lo > 0 and g.buf[lo - 1] == ' ') lo -= 1;
        while (hi < g.len and g.buf[hi]     == ' ') hi += 1;
    }

    if (lo >= hi) return null;
    return MotionResult{ .pos = hi, .inclusive = false, .from_override = lo };
}

fn textObjQuote(q: u8, inner: bool) ?MotionResult {
    // Find balanced quote pairs left-to-right; pick the one containing cursor.
    var i: usize = 0;
    while (i < g.len) {
        if (g.buf[i] == q) {
            const start = i;
            i += 1;
            while (i < g.len and g.buf[i] != q) i += 1;
            if (i >= g.len) break;
            const stop = i;
            i += 1;
            if (g.cursor >= start and g.cursor <= stop) {
                const lo: usize = if (inner) start + 1 else start;
                const hi: usize = if (inner) stop       else stop + 1;
                if (lo >= hi) return null;
                return MotionResult{ .pos = hi, .inclusive = false, .from_override = lo };
            }
        } else {
            i += 1;
        }
    }
    return null;
}

fn textObjBracket(open: u8, close: u8, inner: bool) ?MotionResult {
    // Scan left for an unmatched opening bracket.
    var lo: ?usize = null;
    var depth: i32 = 0;
    var p = g.cursor;
    while (true) {
        if      (g.buf[p] == close) { depth += 1; }
        else if (g.buf[p] == open)  {
            if (depth == 0) { lo = p; break; }
            depth -= 1;
        }
        if (p == 0) break;
        p -= 1;
    }
    const lv = lo orelse return null;

    // Scan right from lv for the matching closing bracket.
    var hi: ?usize = null;
    depth = 0;
    p = lv + 1;
    while (p < g.len) : (p += 1) {
        if      (g.buf[p] == open)  { depth += 1; }
        else if (g.buf[p] == close) {
            if (depth == 0) { hi = p; break; }
            depth -= 1;
        }
    }
    const hv = hi orelse return null;

    if (inner) {
        if (lv + 1 >= hv) return null;
        return MotionResult{ .pos = hv,     .inclusive = false, .from_override = lv + 1 };
    } else {
        return MotionResult{ .pos = hv + 1, .inclusive = false, .from_override = lv };
    }
}

// ── Operator application ──────────────────────────────────────────────────────

fn doOp(op: u8, mr: MotionResult) void {
    var from: usize = undefined;
    var to:   usize = undefined;

    if (mr.from_override) |fo| {
        // Text object: explicit range start.
        from = fo;
        to   = @min(mr.pos, g.len);
    } else if (mr.pos >= g.cursor) {
        from = g.cursor;
        to   = @min(mr.pos + @as(usize, @intFromBool(mr.inclusive)), g.len);
    } else {
        from = mr.pos;
        to   = g.cursor;
    }

    if (from >= to) return;

    switch (op) {
        'd' => { undoPush(); yankRange(from, to); deleteRange(from, to); },
        'c' => { undoPush(); yankRange(from, to); deleteRange(from, to); startInsertMode(); },
        'y' => { yankRange(from, to); g.cursor = from; },
        else => {},
    }
}

fn doOpLine(op: u8) void {
    switch (op) {
        'd' => {
            undoPush();
            yankRange(0, g.len);
            g.cursor = 0; g.len = 0;
        },
        'c' => {
            undoPush();
            yankRange(0, g.len);
            g.cursor = 0; g.len = 0;
            startInsertMode();
        },
        'y' => {
            yankRange(0, g.len);
            g.cursor = 0;
        },
        else => {},
    }
}

// ── Edit helpers ──────────────────────────────────────────────────────────────

/// Enter INSERT mode from a standalone command (i/a/I/A).
/// Pushes an undo snapshot and begins recording for dot repeat.
fn enterInsert() void {
    if (!g.in_dot_replay) {
        undoPush();
        g.insert_rec_len   = 0;
        g.recording_insert = true;
    }
    g.mode = .insert;
}

/// Switch to INSERT mode without an undo push (used by c-operators that
/// already called undoPush before the deletion).
fn startInsertMode() void {
    if (!g.in_dot_replay) {
        g.insert_rec_len   = 0;
        g.recording_insert = true;
    }
    g.mode = .insert;
}

/// Move cursor (normal mode: clamp to last valid position).
fn setCursor(mr: MotionResult) void {
    const max_pos: usize = if (g.len > 0) g.len - 1 else 0;
    g.cursor = @min(mr.pos, max_pos);
}

/// Move cursor in visual mode (clamp to [0, len-1]).
fn setCursorVisual(pos: usize) void {
    g.cursor = @min(pos, if (g.len > 0) g.len - 1 else 0);
}

/// Return [lo, hi) covering the visual selection (exclusive upper bound).
fn visualRange() [2]usize {
    const lo = @min(g.vis_anchor, g.cursor);
    const hi = @min(@max(g.vis_anchor, g.cursor) + 1, g.len);
    return .{ lo, hi };
}

fn insertChar(ch: u8) void {
    if (g.len >= MAX_INPUT - 1) return;
    if (g.cursor < g.len) {
        std.mem.copyBackwards(u8,
            g.buf[g.cursor + 1 .. g.len + 1],
            g.buf[g.cursor     .. g.len]);
    }
    g.buf[g.cursor] = ch;
    g.len    += 1;
    g.cursor += 1;
}

fn insertSlice(slice: []const u8) void {
    const n = @min(slice.len, MAX_INPUT - 1 - g.len);
    if (n == 0) return;
    if (g.cursor < g.len) {
        std.mem.copyBackwards(u8,
            g.buf[g.cursor + n .. g.len + n],
            g.buf[g.cursor     .. g.len]);
    }
    @memcpy(g.buf[g.cursor .. g.cursor + n], slice[0..n]);
    g.len    += n;
    g.cursor += n;
}

fn deleteBefore() void {
    if (g.cursor == 0) return;
    g.cursor -= 1;
    deleteAfter();
}

fn deleteAfter() void {
    if (g.cursor >= g.len) return;
    if (g.cursor < g.len - 1) {
        std.mem.copyForwards(u8,
            g.buf[g.cursor     .. g.len - 1],
            g.buf[g.cursor + 1 .. g.len]);
    }
    g.len -= 1;
}

fn deleteRange(from: usize, to: usize) void {
    if (from >= to or to > g.len) return;
    const n = to - from;
    std.mem.copyForwards(u8, g.buf[from .. g.len - n], g.buf[to .. g.len]);
    g.len    -= n;
    g.cursor  = from;
    if (g.mode == .normal and g.len > 0 and g.cursor >= g.len)
        g.cursor = g.len - 1;
}

fn yankRange(from: usize, to: usize) void {
    if (from >= to or to > g.len) return;
    const n = to - from;
    @memcpy(g.yank_buf[0..n], g.buf[from..to]);
    g.yank_len = n;
}

fn pasteAfter() void {
    if (g.yank_len == 0) return;
    if (g.cursor < g.len) g.cursor += 1;
    insertSlice(g.yank_buf[0..g.yank_len]);
}

fn pasteBefore() void {
    if (g.yank_len == 0) return;
    insertSlice(g.yank_buf[0..g.yank_len]);
}

fn toggleCaseOnce() void {
    if (g.cursor >= g.len) return;
    const ch = g.buf[g.cursor];
    g.buf[g.cursor] =
        if      (std.ascii.isLower(ch)) std.ascii.toUpper(ch)
        else if (std.ascii.isUpper(ch)) std.ascii.toLower(ch)
        else ch;
    if (g.cursor + 1 < g.len) g.cursor += 1;
}

fn ctrlW() void {
    if (g.cursor == 0) return;
    undoPush();
    var p = g.cursor;
    while (p > 0 and g.buf[p - 1] == ' ') p -= 1;
    if (p > 0) {
        if (isWordChar(g.buf[p - 1])) {
            while (p > 0 and isWordChar(g.buf[p - 1])) p -= 1;
        } else {
            while (p > 0 and !isWordChar(g.buf[p - 1]) and g.buf[p - 1] != ' ') p -= 1;
        }
    }
    deleteRange(p, g.cursor);
}

fn ctrlU() void {
    if (g.cursor == 0) return;
    undoPush();
    yankRange(0, g.cursor);
    deleteRange(0, g.cursor);
}

/// Ctrl+A / Ctrl+X: find the nearest number at/after cursor and increment by delta.
fn ctrlAdjustNumber(delta: i64) void {
    if (g.len == 0) return;

    // Find first digit at or after cursor.
    var digit_pos = g.cursor;
    while (digit_pos < g.len and !std.ascii.isDigit(g.buf[digit_pos])) digit_pos += 1;
    if (digit_pos >= g.len) return;

    // Walk left to include optional leading minus.
    var num_start = digit_pos;
    if (num_start > 0 and g.buf[num_start - 1] == '-') num_start -= 1;

    // Walk right to end of digit run.
    var num_end = digit_pos;
    while (num_end < g.len and std.ascii.isDigit(g.buf[num_end])) num_end += 1;

    // Parse, adjust, format.
    const old_str = g.buf[num_start..num_end];
    const old_val = std.fmt.parseInt(i64, old_str, 10) catch return;
    const cnt_val: i64 = @intCast(effCount());
    const new_val = old_val + delta * cnt_val;

    var new_str_buf: [32]u8 = undefined;
    const new_str = std.fmt.bufPrint(&new_str_buf, "{}", .{new_val}) catch return;

    undoPush();

    const old_len = num_end - num_start;
    const new_len = new_str.len;

    if (new_len > old_len) {
        const expand = new_len - old_len;
        if (g.len + expand >= MAX_INPUT) return;
        std.mem.copyBackwards(u8, g.buf[num_end + expand .. g.len + expand], g.buf[num_end .. g.len]);
        g.len += expand;
    } else if (new_len < old_len) {
        const shrink = old_len - new_len;
        std.mem.copyForwards(u8, g.buf[num_start + new_len .. g.len - shrink], g.buf[num_end .. g.len]);
        g.len -= shrink;
    }

    @memcpy(g.buf[num_start .. num_start + new_len], new_str);
    g.cursor = if (num_start + new_len > 0) num_start + new_len - 1 else 0;
}

// ── Undo / redo ───────────────────────────────────────────────────────────────

fn undoPush() void {
    if (g.in_dot_replay) return; // dot replay manages its own single undo entry
    if (g.undo_top < UNDO_MAX) {
        const e = &g.undo_stack[g.undo_top];
        @memcpy(e.buf[0..g.len], g.buf[0..g.len]);
        e.len = g.len; e.cursor = g.cursor;
        g.undo_top += 1;
    } else {
        std.mem.copyForwards(UndoEntry, g.undo_stack[0 .. UNDO_MAX - 1], g.undo_stack[1..UNDO_MAX]);
        const e = &g.undo_stack[UNDO_MAX - 1];
        @memcpy(e.buf[0..g.len], g.buf[0..g.len]);
        e.len = g.len; e.cursor = g.cursor;
    }
    g.redo_top = 0;
}

fn undoUndo() void {
    if (g.undo_top == 0) return;
    if (g.redo_top < UNDO_MAX) {
        const e = &g.redo_stack[g.redo_top];
        @memcpy(e.buf[0..g.len], g.buf[0..g.len]);
        e.len = g.len; e.cursor = g.cursor;
        g.redo_top += 1;
    }
    g.undo_top -= 1;
    const e = &g.undo_stack[g.undo_top];
    @memcpy(g.buf[0..e.len], e.buf[0..e.len]);
    g.len = e.len; g.cursor = e.cursor;
}

fn undoRedo() void {
    if (g.redo_top == 0) return;
    if (g.undo_top < UNDO_MAX) {
        const e = &g.undo_stack[g.undo_top];
        @memcpy(e.buf[0..g.len], g.buf[0..g.len]);
        e.len = g.len; e.cursor = g.cursor;
        g.undo_top += 1;
    }
    g.redo_top -= 1;
    const e = &g.redo_stack[g.redo_top];
    @memcpy(g.buf[0..e.len], e.buf[0..e.len]);
    g.len = e.len; g.cursor = e.cursor;
}

// ── Dot repeat ────────────────────────────────────────────────────────────────

fn dotReplay(wm: *defs.WM) void {
    _ = wm;
    if (g.dot.kind == .none) return;

    // Push a single undo snapshot for the whole replay.
    if (g.undo_top < UNDO_MAX) {
        const e = &g.undo_stack[g.undo_top];
        @memcpy(e.buf[0..g.len], g.buf[0..g.len]);
        e.len = g.len; e.cursor = g.cursor;
        g.undo_top += 1;
    }
    g.redo_top = 0;

    g.in_dot_replay = true;
    defer g.in_dot_replay = false;

    switch (g.dot.kind) {
        .none => {},

        .direct => {
            const cnt = g.dot.direct_count;
            switch (g.dot.direct_sym) {
                'x' => doOp('d', MotionResult{ .pos = charRight(cnt) }),
                'X' => doOp('d', MotionResult{ .pos = charLeft(cnt)  }),
                'D' => doOp('d', MotionResult{ .pos = g.len }),
                'C' => {
                    doOp('c', MotionResult{ .pos = g.len });
                    insertSlice(g.dot.insert_buf[0..g.dot.insert_len]);
                },
                'p' => { var i: u32 = 0; while (i < cnt) : (i += 1) pasteAfter(); },
                'P' => { var i: u32 = 0; while (i < cnt) : (i += 1) pasteBefore(); },
                '~' => { var i: u32 = 0; while (i < cnt) : (i += 1) toggleCaseOnce(); },
                's' => {
                    doOp('c', MotionResult{ .pos = charRight(cnt) });
                    insertSlice(g.dot.insert_buf[0..g.dot.insert_len]);
                },
                'S' => {
                    yankRange(0, g.len);
                    g.len = 0; g.cursor = 0;
                    insertSlice(g.dot.insert_buf[0..g.dot.insert_len]);
                },
                'r' => {
                    const ch = g.dot.direct_ch;
                    var i: usize = 0;
                    while (i < cnt and g.cursor + i < g.len) : (i += 1) g.buf[g.cursor + i] = ch;
                    g.cursor = @min(g.cursor + cnt - 1, g.len -| 1);
                },
                else => {},
            }
        },

        .op_motion => {
            const cnt: u32 = (if (g.dot.op_count == 0) @as(u32, 1) else g.dot.op_count) *
                             (if (g.dot.motion_count == 0) @as(u32, 1) else g.dot.motion_count);

            const mr_opt: ?MotionResult =
                if (g.dot.find_kind != 0)
                    motionFind(g.dot.find_kind, g.dot.find_ch, cnt)
                else if (g.dot.tobj_kind != 0)
                    resolveTextObject(g.dot.tobj_kind, g.dot.tobj_delim)
                else if (g.dot.g_prefix) blk: {
                    break :blk switch (g.dot.motion_sym) {
                        'e'  => MotionResult{ .pos = motionWordEndBack(false, cnt), .inclusive = true },
                        'E'  => MotionResult{ .pos = motionWordEndBack(true,  cnt), .inclusive = true },
                        else => null,
                    };
                } else resolveSimpleMotion(g.dot.motion_sym, cnt);

            if (mr_opt) |mr| {
                doOp(g.dot.op, mr);
                if (g.dot.op == 'c')
                    insertSlice(g.dot.insert_buf[0..g.dot.insert_len]);
            }
        },

        .op_line => {
            doOpLine(g.dot.op);
            if (g.dot.op == 'c')
                insertSlice(g.dot.insert_buf[0..g.dot.insert_len]);
        },

        .insert_session => {
            insertSlice(g.dot.insert_buf[0..g.dot.insert_len]);
        },
    }
}

// ── Normal-mode sub-state management ─────────────────────────────────────────

fn resetNormalSub() void {
    g.n_count         = 0;
    g.n_op            = 0;
    g.n_op_count      = 0;
    g.n_find_kind     = 0;
    g.n_pending_r     = false;
    g.n_pending_g     = false;
    g.n_text_obj_kind = 0;
    g.n_pending_m     = false;
    g.n_pending_apos  = false;
}

fn effCount() u32 {
    const mc: u32 = if (g.n_count    == 0) 1 else g.n_count;
    const oc: u32 = if (g.n_op_count == 0) 1 else g.n_op_count;
    return mc * oc;
}

// ── PATH completion ──────────────────────────────────────────────────────────

/// Scan every directory in $PATH and collect executable names into the static
/// comp_names table.  Called once on first activation.  Duplicates (same name
/// in multiple PATH dirs) are stored but don't affect correctness.
fn loadCompletions() void {
    g.comp_count = 0;
    const path_env_ptr = c.getenv("PATH") orelse return;
    const path_env = std.mem.span(path_env_ptr);

    // Use a null-terminated path buffer for opendir.
    var dir_buf: [std.fs.max_path_bytes]u8 = undefined;

    var dir_it = std.mem.splitScalar(u8, path_env, ':');
    outer: while (dir_it.next()) |dir_path| {
        if (dir_path.len == 0 or dir_path.len >= dir_buf.len) continue;
        @memcpy(dir_buf[0..dir_path.len], dir_path);
        dir_buf[dir_path.len] = 0;

        const dirp = c.opendir(&dir_buf) orelse continue;
        defer _ = c.closedir(dirp);

        while (c.readdir(dirp)) |entry| {
            const d_name: [*:0]const u8 = @ptrCast(&entry.*.d_name);
            const name = std.mem.span(d_name);
            if (name.len == 0 or name.len > MAX_COMP_LEN) continue;
            if (name[0] == '.') continue; // skip hidden / . / ..

            // d_type: DT_REG=8, DT_LNK=10, DT_UNKNOWN=0 — accept all three.
            const dt = entry.*.d_type;
            if (dt != 0 and dt != 8 and dt != 10) continue;

            const slot = g.comp_count * (MAX_COMP_LEN + 1);
            @memcpy(g.comp_names[slot .. slot + name.len], name);
            g.comp_names[slot + name.len] = 0;
            g.comp_count += 1;
            if (g.comp_count >= MAX_COMPLETIONS) break :outer;
        }
    }
}

/// Recompute the ghost-text suggestion based on the current buffer.
/// Priority: history (newest first) → any executable match.
/// Only operates in INSERT mode with cursor at end and no spaces typed.
fn updateGhost() void {
    g.ghost_len = 0;

    if (g.mode != .insert) return;
    if (g.len == 0 or g.cursor != g.len) return;

    // Only complete the bare command token (no spaces yet).
    for (g.buf[0..g.len]) |ch| {
        if (ch == ' ') return;
    }

    const prefix = g.buf[0..g.len];

    // ── 1. History-based suggestion (newest first) ──────────────────────────
    // Walk history; for each entry extract its first token and check:
    //   a) it starts with `prefix`
    //   b) it exists as a known executable in comp_names
    var hi: usize = 0;
    while (hi < g.hist_count) : (hi += 1) {
        const hslot = hi * (MAX_HIST_LINE + 1);
        const entry = std.mem.sliceTo(g.hist_entries[hslot .. hslot + MAX_HIST_LINE + 1], 0);
        if (entry.len == 0) continue;

        // Extract first token (up to first space or end).
        const cmd_end = std.mem.indexOfScalar(u8, entry, ' ') orelse entry.len;
        const cmd_tok = entry[0..cmd_end];

        if (cmd_tok.len <= prefix.len) continue;
        if (!std.mem.startsWith(u8, cmd_tok, prefix)) continue;

        // Verify the token is an actual executable we know about.
        var ei: usize = 0;
        const tok_is_exec = blk: {
            while (ei < g.comp_count) : (ei += 1) {
                const eslot = ei * (MAX_COMP_LEN + 1);
                const ename = std.mem.sliceTo(g.comp_names[eslot .. eslot + MAX_COMP_LEN + 1], 0);
                if (std.mem.eql(u8, ename, cmd_tok)) break :blk true;
            }
            break :blk false;
        };
        if (!tok_is_exec) continue;

        // Found a history-backed suggestion.
        const suffix = cmd_tok[prefix.len..];
        const n = @min(suffix.len, MAX_COMP_LEN);
        @memcpy(g.ghost_buf[0..n], suffix[0..n]);
        g.ghost_len = n;
        return;
    }

    // ── 2. Fallback: any executable that starts with prefix ─────────────────
    // Pick the shortest match (most specific).
    var best_extra: usize = std.math.maxInt(usize);
    var best_slot:  usize = 0;
    var found = false;

    var i: usize = 0;
    while (i < g.comp_count) : (i += 1) {
        const slot = i * (MAX_COMP_LEN + 1);
        const name = std.mem.sliceTo(g.comp_names[slot .. slot + MAX_COMP_LEN + 1], 0);
        if (name.len <= prefix.len) continue;
        if (!std.mem.startsWith(u8, name, prefix)) continue;
        const extra = name.len - prefix.len;
        if (extra < best_extra) {
            best_extra = extra;
            best_slot  = slot;
            found      = true;
        }
    }

    if (!found) return;

    const name   = std.mem.sliceTo(g.comp_names[best_slot .. best_slot + MAX_COMP_LEN + 1], 0);
    const suffix = name[prefix.len..];
    const n      = @min(suffix.len, MAX_COMP_LEN);
    @memcpy(g.ghost_buf[0..n], suffix[0..n]);
    g.ghost_len = n;
}

// ── History ──────────────────────────────────────────────────────────────────

/// Prepend `cmd` to the in-memory history (newest at index 0).
/// Shifts existing entries down, dropping the oldest if full.
fn histPrepend(cmd: []const u8) void {
    if (cmd.len == 0 or cmd.len > MAX_HIST_LINE) return;

    // Shift everything down one slot, dropping the last if full.
    const keep = @min(g.hist_count, MAX_HIST - 1);
    var i: usize = keep;
    while (i > 0) : (i -= 1) {
        const src = (i - 1) * (MAX_HIST_LINE + 1);
        const dst =  i      * (MAX_HIST_LINE + 1);
        @memcpy(g.hist_entries[dst .. dst + MAX_HIST_LINE + 1],
                g.hist_entries[src .. src + MAX_HIST_LINE + 1]);
    }
    // Write new entry at slot 0.
    @memcpy(g.hist_entries[0..cmd.len], cmd);
    g.hist_entries[cmd.len] = 0;
    if (g.hist_count < MAX_HIST) g.hist_count += 1;
}

/// Append `cmd` to drun's own history file (~/.local/share/drun/history).
fn histAppendToDrunFile(cmd: []const u8) void {
    if (cmd.len == 0) return;
    var path_buf: [512]u8 = undefined;
    const home = std.mem.span(c.getenv("HOME") orelse return);
    const dir_path = std.fmt.bufPrint(&path_buf, "{s}/.local/share/drun", .{home}) catch return;

    // Ensure directory exists.
    var dir_buf: [512]u8 = undefined;
    @memcpy(dir_buf[0..dir_path.len], dir_path);
    dir_buf[dir_path.len] = 0;
    _ = c.mkdir(&dir_buf, 0o700);

    const file_path = std.fmt.bufPrint(&path_buf, "{s}/.local/share/drun/history", .{home}) catch return;
    var file_buf: [512]u8 = undefined;
    @memcpy(file_buf[0..file_path.len], file_path);
    file_buf[file_path.len] = 0;

    const fd = c.open(&file_buf, c.O_WRONLY | c.O_CREAT | c.O_APPEND, @as(c_int, 0o600));
    if (fd < 0) return;
    defer _ = c.close(fd);
    _ = c.write(fd, cmd.ptr, cmd.len);
    _ = c.write(fd, "\n", 1);
}

/// Parse one line from a shell history file into `out`, returning its length.
/// Returns 0 to skip the line.
/// Formats understood:
///   fish   : "- cmd: <command>"   (YAML block)
///   zsh    : ": <ts>:<elapsed>;<command>"  OR bare line
///   bash   : bare line (may have "#<timestamp>" markers which are skipped)
///   drun   : bare line
fn histParseLine(line: []const u8, out: []u8) usize {
    if (line.len == 0) return 0;

    var cmd = line;

    // Fish format: "- cmd: <command>"
    if (std.mem.startsWith(u8, cmd, "- cmd: ")) {
        cmd = cmd["- cmd: ".len..];
    }
    // Zsh extended format: ": <timestamp>:<elapsed>;<command>"
    else if (cmd.len > 2 and cmd[0] == ':' and cmd[1] == ' ') {
        if (std.mem.indexOfScalar(u8, cmd, ';')) |semi| {
            cmd = cmd[semi + 1..];
        }
    }
    // Bash timestamp comment: skip lines starting with '#'
    else if (cmd[0] == '#') {
        return 0;
    }

    // Trim leading/trailing whitespace.
    var start: usize = 0;
    while (start < cmd.len and (cmd[start] == ' ' or cmd[start] == '\t')) : (start += 1) {}
    var end = cmd.len;
    while (end > start and (cmd[end-1] == ' ' or cmd[end-1] == '\t' or cmd[end-1] == '\r')) : (end -= 1) {}
    cmd = cmd[start..end];

    if (cmd.len == 0 or cmd.len > MAX_HIST_LINE) return 0;
    const n = @min(cmd.len, out.len);
    @memcpy(out[0..n], cmd[0..n]);
    return n;
}

/// Load history from a file, appending lines oldest-first so that after
/// loading, newer entries are at lower indices (caller reverses / prepends).
/// We read the whole file and process lines in reverse so newest ends up at 0.
fn histLoadFile(fp: *c.FILE) void {
    // Read entire file into a temporary stack buffer (up to 256 KB).
    const FBUF_SIZE = 256 * 1024;
    const fbuf: []u8 = blk: {
        const ptr = c.malloc(FBUF_SIZE) orelse return;
        break :blk @as([*]u8, @ptrCast(ptr))[0..FBUF_SIZE];
    };
    defer c.free(fbuf.ptr);

    const n_read = c.fread(fbuf.ptr, 1, FBUF_SIZE - 1, fp);
    if (n_read == 0) return;
    const text = fbuf[0..n_read];

    // Collect line offsets (we'll iterate in reverse for newest-first).
    const MAX_LINES = MAX_HIST * 2; // more than enough
    const line_starts: []usize = blk: {
        const ptr = c.malloc(@sizeOf(usize) * MAX_LINES) orelse return;
        break :blk @as([*]usize, @ptrCast(@alignCast(ptr)))[0..MAX_LINES];
    };
    defer c.free(line_starts.ptr);
    const line_ends: []usize = blk: {
        const ptr = c.malloc(@sizeOf(usize) * MAX_LINES) orelse return;
        break :blk @as([*]usize, @ptrCast(@alignCast(ptr)))[0..MAX_LINES];
    };
    defer c.free(line_ends.ptr);

    var n_lines: usize = 0;
    var pos: usize = 0;
    while (pos < text.len and n_lines < MAX_LINES) {
        const line_start = pos;
        while (pos < text.len and text[pos] != '\n') : (pos += 1) {}
        const line_end = pos;
        if (pos < text.len) pos += 1; // skip newline
        line_starts[n_lines] = line_start;
        line_ends[n_lines]   = line_end;
        n_lines += 1;
    }

    // Iterate lines in reverse (newest first), prepend to history.
    var out_line: [MAX_HIST_LINE]u8 = undefined;
    var li: usize = n_lines;
    while (li > 0) {
        li -= 1;
        if (g.hist_count >= MAX_HIST) break;
        const line = text[line_starts[li]..line_ends[li]];
        const len = histParseLine(line, &out_line);
        if (len == 0) continue;
        // Avoid consecutive duplicates.
        if (g.hist_count > 0) {
            const prev = std.mem.sliceTo(g.hist_entries[0 .. MAX_HIST_LINE + 1], 0);
            if (std.mem.eql(u8, prev, out_line[0..len])) continue;
        }
        histPrepend(out_line[0..len]);
    }
}

/// Load history from fish → zsh → bash → drun (in priority order).
/// The highest-priority source that exists wins; we try all and merge newest-first.
/// In practice we load drun first (as baseline), then overlay the shell history
/// on top so the shell's recent commands take precedence.
fn loadHistory() void {
    g.hist_loaded = true;

    var path_buf: [512]u8 = undefined;
    const home = std.mem.span(c.getenv("HOME") orelse return);

    // Helper: try to fopen a formatted path.
    const tryOpen = struct {
        fn f(buf: []u8, comptime fmt: []const u8, args: anytype) ?*c.FILE {
            const s = std.fmt.bufPrint(buf[0..buf.len-1], fmt, args) catch return null;
            buf[s.len] = 0;
            return c.fopen(@ptrCast(buf.ptr), "r");
        }
    }.f;

    // Load drun's own history first (oldest baseline).
    if (tryOpen(&path_buf, "{s}/.local/share/drun/history", .{home})) |fp| {
        defer _ = c.fclose(fp);
        histLoadFile(fp);
    }

    // Overlay bash history (older than zsh/fish in typical setups).
    if (tryOpen(&path_buf, "{s}/.bash_history", .{home})) |fp| {
        defer _ = c.fclose(fp);
        histLoadFile(fp);
    }

    // Overlay zsh history.
    if (tryOpen(&path_buf, "{s}/.zsh_history", .{home})) |fp| {
        defer _ = c.fclose(fp);
        histLoadFile(fp);
    }

    // Overlay fish history (highest priority — read last so it sits at top).
    if (tryOpen(&path_buf, "{s}/.local/share/fish/fish_history", .{home})) |fp| {
        defer _ = c.fclose(fp);
        histLoadFile(fp);
    }
}

// ── Spawn ─────────────────────────────────────────────────────────────────────

fn spawnCommand(cmd: []const u8) void {
    // Record in history before spawning.
    histPrepend(cmd);
    histAppendToDrunFile(cmd);

    var buf: [MAX_INPUT + 1]u8 = undefined;
    if (cmd.len >= buf.len) return;
    @memcpy(buf[0..cmd.len], cmd);
    buf[cmd.len] = 0;
    const cmd_z: [*:0]const u8 = buf[0..cmd.len :0];

    const pid = c.fork();
    if (pid == 0) {
        const pid2 = c.fork();
        if (pid2 == 0) {
            _ = c.setsid();
            _ = c.execvp("/bin/sh", @ptrCast(&[_:null]?[*:0]const u8{ "/bin/sh", "-c", cmd_z, null }));
            std.process.exit(1);
        }
        std.process.exit(0);
    } else if (pid > 0) {
        var status: c_int = 0;
        _ = c.waitpid(pid, &status, 0);
    }
}

// ── Rendering ─────────────────────────────────────────────────────────────────

/// Render the active input UI.
///
/// Layout:
///
///   [ pad | scrollable: PROMPT | pre | CURSOR/SELECTION | post | MODE_LABEL | pad ]
///
/// The mode label is pinned to the right edge (does not scroll).
/// The scrollable region keeps the cursor in view.
fn drawActive(
    dc:      *drawing.DrawContext,
    config:  defs.BarConfig,
    height:  u16,
    start_x: u16,
    width:   u16,
) !u16 {
    const end_x  = start_x + width;
    const pad    = config.scaledSegmentPadding(height);
    const accent = config.getDrunPromptColor();
    const bg     = config.getDrunBg();
    const fg     = config.getDrunFg();
    const prompt = config.drun_prompt;

    dc.fillRect(start_x, 0, width, height, bg);

    const baseline    = dc.baselineY(height);
    const text_left_x = start_x + pad;
    const text_end_x  = end_x   -| pad;
    if (text_left_x >= text_end_x) return end_x;

    // ── Mode label (pinned right) ─────────────────────────────────────────────
    const mode_label = g.mode.label();
    const mode_idx: usize = @intFromEnum(g.mode);

    const mode_w: u16 = g.cached_mode_w[mode_idx] orelse blk: {
        const w = dc.textWidth(mode_label);
        g.cached_mode_w[mode_idx] = w;
        break :blk w;
    };

    if (mode_w > 0 and text_end_x >= mode_w) {
        const label_x = text_end_x - mode_w;
        if (label_x >= text_left_x)
            try dc.drawText(label_x, baseline, mode_label, accent);
    }

    const scroll_end_x: u16 = if (text_end_x >= mode_w) text_end_x - mode_w else text_left_x;
    if (text_left_x >= scroll_end_x) return end_x;

    const max_scroll_px: u16 = scroll_end_x - text_left_x;

    // ── Measure prompt ────────────────────────────────────────────────────────
    const prompt_w: u16 = g.cached_prompt_w orelse blk: {
        const w = dc.textWidth(prompt);
        g.cached_prompt_w = w;
        break :blk w;
    };

    // ── Compute scroll offset (keep cursor visible) ───────────────────────────
    //
    // In INSERT mode the cursor is a thin 2-px caret; the character it sits on
    // is NOT consumed, so post_text starts at g.cursor (not g.cursor+1) and the
    // caret_w used for layout is CURSOR_WIDTH.
    // In all other modes we keep the traditional full-character block model.
    const pre_cur_text = g.buf[0..g.cursor];
    const pre_w_cur    = dc.textWidth(pre_cur_text);

    const caret_w: u16 = if (g.mode == .insert) CURSOR_WIDTH
                         else @max(
                             dc.textWidth(if (g.cursor < g.len) g.buf[g.cursor..g.cursor+1] else " "),
                             MIN_CURSOR_PX);

    const post_text: []const u8 = if (g.mode == .insert)
        g.buf[g.cursor..g.len]
    else
        (if (g.cursor < g.len) g.buf[g.cursor + 1 .. g.len] else "");

    const post_w    = dc.textWidth(post_text);
    const content_w: u16 = prompt_w + pre_w_cur + caret_w + post_w;

    var scroll_x: u16 = 0;
    if (content_w > max_scroll_px) {
        const cursor_right = prompt_w + pre_w_cur + caret_w;
        if (cursor_right > max_scroll_px)
            scroll_x = cursor_right -| max_scroll_px +| caret_w;
    }

    // ── Draw prompt ───────────────────────────────────────────────────────────
    var px: i32 = @as(i32, text_left_x) - @as(i32, scroll_x);

    if (px + @as(i32, prompt_w) > @as(i32, text_left_x) and px < @as(i32, scroll_end_x)) {
        const draw_x: u16 = @intCast(@max(px, @as(i32, text_left_x)));
        try dc.drawText(draw_x, baseline, prompt, accent);
    }
    px += @intCast(prompt_w);

    // ── Mode-specific text rendering ──────────────────────────────────────────
    if (g.mode == .visual) {
        // Visual mode: split buffer into pre-selection, selection, post-selection.
        const sel      = visualRange();
        const sel_lo   = sel[0];
        const sel_hi   = sel[1];

        const pre_sel  = g.buf[0..sel_lo];
        const sel_text = g.buf[sel_lo..sel_hi];
        const post_sel = g.buf[sel_hi..g.len];

        const pre_sel_w  = dc.textWidth(pre_sel);
        const sel_w      = @max(dc.textWidth(sel_text), MIN_CURSOR_PX);
        const post_sel_w = dc.textWidth(post_sel);
        _ = post_sel_w;

        // Pre-selection text (fg).
        if (pre_sel.len > 0) {
            if (px + @as(i32, pre_sel_w) > @as(i32, text_left_x) and px < @as(i32, scroll_end_x)) {
                const draw_x: u16 = @intCast(@max(px, @as(i32, text_left_x)));
                try dc.drawText(draw_x, baseline, pre_sel, fg);
            }
            px += @intCast(pre_sel_w);
        }

        // Selection background + text (inverted: accent bg, bg text).
        if (px + @as(i32, sel_w) > @as(i32, text_left_x) and px < @as(i32, scroll_end_x)) {
            const draw_x: u16 = @intCast(@max(px, @as(i32, text_left_x)));
            const vis_w: u16 = @intCast(@min(
                @as(i32, sel_w),
                @as(i32, scroll_end_x) - px,
            ));
            if (vis_w > 0) {
                dc.fillRect(draw_x, CURSOR_V_PAD, vis_w, height -| CURSOR_V_PAD * 2, accent);
                if (sel_text.len > 0)
                    try dc.drawText(draw_x, baseline, sel_text, bg);
            }
        }
        px += @intCast(sel_w);

        // Post-selection text (fg).
        if (post_sel.len > 0 and px < @as(i32, scroll_end_x)) {
            const draw_x: u16 = @intCast(@max(px, @as(i32, text_left_x)));
            const remaining: u16 = scroll_end_x -| draw_x;
            if (remaining > 0)
                try dc.drawTextEllipsis(draw_x, baseline, post_sel, remaining, fg);
        }

    } else if (g.mode == .insert) {
        // ── INSERT mode: blinking 2-px caret, text NOT consumed by cursor ────
        const pre_text = g.buf[0..g.cursor];
        const pre_w    = dc.textWidth(pre_text);

        // Text before cursor.
        if (pre_text.len > 0) {
            if (px + @as(i32, pre_w) > @as(i32, text_left_x) and px < @as(i32, scroll_end_x)) {
                const draw_x: u16 = @intCast(@max(px, @as(i32, text_left_x)));
                try dc.drawText(draw_x, baseline, pre_text, fg);
            }
            px += @intCast(pre_w);
        }

        // Blinking caret — visible in the first half of each CURSOR_BLINK_MS period.
        // Drain the timerfd if it has fired so we stay in sync.
        if (g.blink_fd >= 0) {
            var discard: u64 = 0;
            _ = c.read(g.blink_fd, &discard, @sizeOf(u64));
        }
        const now_ms: i64 = blk: {
            const ts = std.posix.clock_gettime(.MONOTONIC) catch break :blk 0;
            break :blk @as(i64, ts.sec) * 1000 + @divFloor(@as(i64, ts.nsec), 1_000_000);
        };
        const blink_on = @mod(@divFloor(now_ms, CURSOR_BLINK_MS), 2) == 0;

        // Caret height: derive from baseline rather than using full bar height.
        // For vertically centred text the gap above glyphs ≈ height - baseline,
        // so the caret runs from that point down through the baseline plus a
        // small descender allowance (≈ 20 % of the cap-height estimate).
        const baseline_u16: u16 = @intCast(@min(baseline, height));
        const caret_top: u16    = height -| baseline_u16;
        const cap_h: u16        = baseline_u16 -| caret_top;
        const caret_h: u16      = cap_h + cap_h / 5; // cap + ~20 % for descenders

        if (blink_on and px >= @as(i32, text_left_x) and px < @as(i32, scroll_end_x)) {
            dc.fillRect(@intCast(px), caret_top, CURSOR_WIDTH, caret_h, accent);
        }

        // Ghost text starts immediately at the caret (only when cursor is at end).
        if (g.ghost_len > 0 and g.cursor == g.len and px < @as(i32, scroll_end_x)) {
            const ghost = g.ghost_buf[0..g.ghost_len];
            const draw_x: u16 = @intCast(@max(px, @as(i32, text_left_x)));
            const remaining: u16 = scroll_end_x -| draw_x;
            if (remaining > 0)
                try dc.drawTextEllipsis(draw_x, baseline, ghost, remaining, accent);
        }

        // Text from cursor onwards (the caret sits on top, doesn't consume it).
        if (post_text.len > 0 and px < @as(i32, scroll_end_x)) {
            const draw_x: u16 = @intCast(@max(px, @as(i32, text_left_x)));
            const remaining: u16 = scroll_end_x -| draw_x;
            if (remaining > 0)
                try dc.drawTextEllipsis(draw_x, baseline, post_text, remaining, fg);
        }

    } else {
        // ── NORMAL / REPLACE: full-character block cursor ─────────────────────
        const pre_text = g.buf[0..g.cursor];
        const cur_text = if (g.cursor < g.len) g.buf[g.cursor .. g.cursor + 1] else " ";
        const pre_w    = dc.textWidth(pre_text);
        const cur_w    = @max(dc.textWidth(cur_text), MIN_CURSOR_PX);

        // Text before cursor.
        if (pre_text.len > 0) {
            if (px + @as(i32, pre_w) > @as(i32, text_left_x) and px < @as(i32, scroll_end_x)) {
                const draw_x: u16 = @intCast(@max(px, @as(i32, text_left_x)));
                try dc.drawText(draw_x, baseline, pre_text, fg);
            }
            px += @intCast(pre_w);
        }

        // Block cursor.
        if (px + @as(i32, cur_w) > @as(i32, text_left_x) and px < @as(i32, scroll_end_x)) {
            const draw_x: u16 = @intCast(@max(px, @as(i32, text_left_x)));
            const vis_w: u16  = @intCast(@min(
                @as(i32, cur_w),
                @as(i32, scroll_end_x) - px,
            ));
            if (vis_w > 0) {
                dc.fillRect(draw_x, CURSOR_V_PAD, vis_w, height -| CURSOR_V_PAD * 2, accent);
                if (g.cursor < g.len)
                    try dc.drawText(draw_x, baseline, cur_text, bg);
            }
        }
        px += @intCast(cur_w);

        // Text after cursor.
        if (post_text.len > 0 and px < @as(i32, scroll_end_x)) {
            const draw_x: u16 = @intCast(@max(px, @as(i32, text_left_x)));
            const remaining: u16 = scroll_end_x -| draw_x;
            if (remaining > 0)
                try dc.drawTextEllipsis(draw_x, baseline, post_text, remaining, fg);
        }
    }

    return end_x;
}
