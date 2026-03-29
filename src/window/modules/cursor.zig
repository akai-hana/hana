//! C bindings for libxcb-cursor.
//!
//! xcb-cursor provides named X11 cursor loading for XCB callers, replacing
//! the older Xcursor/Xlib API.  These bindings are used by the floating
//! window layer to set the pointer shape during drag and resize operations.
//!
//! Link with: -lxcb-cursor

const core = @import("core");
const xcb  = core.xcb;

const xcb_connection_t = xcb.xcb_connection_t;

pub const xcb_cursor_context_t = opaque {};

/// Initialises a cursor context for the given connection and screen.
/// Returns a non-zero error code on failure.
pub extern fn xcb_cursor_context_new(
    conn:   *xcb_connection_t,
    screen: *anyopaque,
    ctx:    **xcb_cursor_context_t,
) c_int;

/// Loads a named cursor (e.g. `"fleur"`, `"left_ptr"`) and returns its XID.
/// Returns `XCB_CURSOR_NONE` (0) if the name is not found.
pub extern fn xcb_cursor_load_cursor(
    ctx:  *xcb_cursor_context_t,
    name: [*:0]const u8,
) u32;

pub extern fn xcb_cursor_context_free(ctx: *xcb_cursor_context_t) void;
