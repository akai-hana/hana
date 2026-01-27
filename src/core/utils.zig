//! Core utilities

const std = @import("std");
const defs = @import("defs");
const xcb = defs.xcb;

// Time utilities

pub inline fn getTimestampNs() i64 {
    const ts = std.posix.clock_gettime(std.posix.CLOCK.REALTIME) catch return 0;
    return ts.sec * std.time.ns_per_s + ts.nsec;
}

pub inline fn sleepNs(ns: u64) void {
    std.posix.nanosleep(0, ns);
}

// XCB utilities - consolidated

pub inline fn flush(conn: *xcb.xcb_connection_t) void {
    _ = xcb.xcb_flush(conn);
}

pub inline fn setBorder(conn: *xcb.xcb_connection_t, win: u32, color: u32) void {
    _ = xcb.xcb_change_window_attributes(conn, win, xcb.XCB_CW_BORDER_PIXEL, &[_]u32{color});
}

pub inline fn setBorderWidth(conn: *xcb.xcb_connection_t, win: u32, width: u16) void {
    _ = xcb.xcb_configure_window(conn, win, xcb.XCB_CONFIG_WINDOW_BORDER_WIDTH, &[_]u32{width});
}

pub inline fn configureBorder(conn: *xcb.xcb_connection_t, win: u32, width: u16, color: u32) void {
    setBorderWidth(conn, win, width);
    setBorder(conn, win, color);
}

// Window attributes helper

pub const WindowAttrs = struct {
    x: ?i16 = null,
    y: ?i16 = null,
    width: ?u16 = null,
    height: ?u16 = null,
    border_width: ?u16 = null,
    border_color: ?u32 = null,
    event_mask: ?u32 = null,
    stack_mode: ?u32 = null,

    pub fn configure(self: WindowAttrs, conn: *xcb.xcb_connection_t, win: u32) void {
        var mask: u32 = 0;
        var values: [8]u32 = undefined;
        var idx: usize = 0;

        if (self.x) |x| {
            mask |= xcb.XCB_CONFIG_WINDOW_X;
            values[idx] = @bitCast(@as(i32, x));
            idx += 1;
        }
        if (self.y) |y| {
            mask |= xcb.XCB_CONFIG_WINDOW_Y;
            values[idx] = @bitCast(@as(i32, y));
            idx += 1;
        }
        if (self.width) |w| {
            mask |= xcb.XCB_CONFIG_WINDOW_WIDTH;
            values[idx] = w;
            idx += 1;
        }
        if (self.height) |h| {
            mask |= xcb.XCB_CONFIG_WINDOW_HEIGHT;
            values[idx] = h;
            idx += 1;
        }
        if (self.border_width) |bw| {
            mask |= xcb.XCB_CONFIG_WINDOW_BORDER_WIDTH;
            values[idx] = bw;
            idx += 1;
        }
        if (self.stack_mode) |sm| {
            mask |= xcb.XCB_CONFIG_WINDOW_STACK_MODE;
            values[idx] = sm;
            idx += 1;
        }

        if (mask != 0) {
            _ = xcb.xcb_configure_window(conn, win, @intCast(mask), &values);
        }

        if (self.border_color) |bc| {
            setBorder(conn, win, bc);
        }

        if (self.event_mask) |em| {
            _ = xcb.xcb_change_window_attributes(conn, win, xcb.XCB_CW_EVENT_MASK, &[_]u32{em});
        }
    }
};

// Geometry utilities

pub const Rect = struct {
    x: i16,
    y: i16,
    width: u16,
    height: u16,

    pub fn fromXcb(geom: *const xcb.xcb_get_geometry_reply_t) Rect {
        return .{ .x = geom.x, .y = geom.y, .width = geom.width, .height = geom.height };
    }

    pub inline fn clamp(self: Rect) Rect {
        return .{
            .x = self.x,
            .y = self.y,
            .width = std.math.clamp(self.width, defs.MIN_WINDOW_DIM, defs.MAX_WINDOW_DIM),
            .height = std.math.clamp(self.height, defs.MIN_WINDOW_DIM, defs.MAX_WINDOW_DIM),
        };
    }

    pub inline fn isValid(self: Rect) bool {
        return self.width >= defs.MIN_WINDOW_DIM and self.width <= defs.MAX_WINDOW_DIM and
            self.height >= defs.MIN_WINDOW_DIM and self.height <= defs.MAX_WINDOW_DIM;
    }
};

pub const Margins = struct {
    gap: u16,
    border: u16,

    pub inline fn total(self: Margins) u16 {
        return 2 * self.gap + 2 * self.border;
    }

    pub inline fn innerRect(self: Margins, outer_w: u16, outer_h: u16) Rect {
        const margin = self.total();
        return .{
            .x = @intCast(self.gap),
            .y = @intCast(self.gap),
            .width = if (outer_w > margin) outer_w - margin else defs.MIN_WINDOW_DIM,
            .height = if (outer_h > margin) outer_h - margin else defs.MIN_WINDOW_DIM,
        };
    }
};

pub inline fn configureWindow(conn: *xcb.xcb_connection_t, win: u32, rect: Rect) void {
    const r = rect.clamp();
    const values = [_]u32{
        @bitCast(@as(i32, r.x)),
        @bitCast(@as(i32, r.y)),
        r.width,
        r.height,
    };
    _ = xcb.xcb_configure_window(conn, win,
        xcb.XCB_CONFIG_WINDOW_X | xcb.XCB_CONFIG_WINDOW_Y |
            xcb.XCB_CONFIG_WINDOW_WIDTH | xcb.XCB_CONFIG_WINDOW_HEIGHT,
        &values);
}

pub fn getGeometry(conn: *xcb.xcb_connection_t, win: u32) ?Rect {
    const cookie = xcb.xcb_get_geometry(conn, win);
    const reply = xcb.xcb_get_geometry_reply(conn, cookie, null) orelse return null;
    defer std.c.free(reply);
    return Rect.fromXcb(reply);
}

// Layout calculations

pub inline fn calcGridDims(n: usize) struct { cols: u16, rows: u16 } {
    if (n == 0) return .{ .cols = 1, .rows = 1 };
    const cols = @as(u16, @intFromFloat(@ceil(@sqrt(@as(f32, @floatFromInt(n))))));
    return .{ .cols = cols, .rows = @intCast((n + cols - 1) / cols) };
}

pub inline fn calcColumnLayout(total_h: u16, count: u16, margins: Margins) struct { item_h: u16, spacing: u16 } {
    if (count == 0) return .{ .item_h = 0, .spacing = 0 };

    const overhead = margins.gap * (count + 1) + margins.border * 2 * count;
    const available = if (total_h > overhead) total_h - overhead else count * defs.MIN_WINDOW_DIM;
    const item_h = @max(defs.MIN_WINDOW_DIM, available / count);

    return .{ .item_h = item_h, .spacing = item_h + 2 * margins.border + margins.gap };
}

// Modifier utilities

pub inline fn normalizeModifiers(state: u16) u16 {
    return state & defs.MOD_MASK_RELEVANT;
}

// Atom cache (reduce repeated queries)

const AtomCache = struct {
    wm_protocols: ?u32 = null,
    wm_delete: ?u32 = null,
    net_wm_name: ?u32 = null,
    utf8_string: ?u32 = null,
};

var atom_cache: AtomCache = .{};

pub fn getAtom(conn: *xcb.xcb_connection_t, name: []const u8) !u32 {
    const cookie = xcb.xcb_intern_atom(conn, 0, @intCast(name.len), name.ptr);
    const reply = xcb.xcb_intern_atom_reply(conn, cookie, null) orelse return error.AtomFailed;
    defer std.c.free(reply);
    return reply.*.atom;
}

pub fn getAtomCached(conn: *xcb.xcb_connection_t, comptime name: []const u8) !u32 {
    const field_name = comptime blk: {
        if (std.mem.eql(u8, name, "WM_PROTOCOLS")) break :blk "wm_protocols";
        if (std.mem.eql(u8, name, "WM_DELETE_WINDOW")) break :blk "wm_delete";
        if (std.mem.eql(u8, name, "_NET_WM_NAME")) break :blk "net_wm_name";
        if (std.mem.eql(u8, name, "UTF8_STRING")) break :blk "utf8_string";
        @compileError("Atom not cacheable: " ++ name);
    };

    if (@field(atom_cache, field_name)) |atom| return atom;

    const atom = try getAtom(conn, name);
    @field(atom_cache, field_name) = atom;
    return atom;
}

// Window property utilities

pub const WMClass = struct {
    instance: []const u8,
    class: []const u8,

    pub fn deinit(self: WMClass, allocator: std.mem.Allocator) void {
        allocator.free(self.instance);
        allocator.free(self.class);
    }
};

pub fn getWMClass(conn: *xcb.xcb_connection_t, win: u32, allocator: std.mem.Allocator) ?WMClass {
    const cookie = xcb.xcb_get_property(
        conn,
        0,
        win,
        xcb.XCB_ATOM_WM_CLASS,
        xcb.XCB_ATOM_STRING,
        0,
        256,
    );

    const reply = xcb.xcb_get_property_reply(conn, cookie, null) orelse return null;
    defer std.c.free(reply);

    if (reply.*.format != 8 or reply.*.value_len == 0) return null;

    const data: [*]const u8 = @ptrCast(xcb.xcb_get_property_value(reply));
    const len: usize = @intCast(reply.*.value_len);

    // WM_CLASS format: instance\0class\0
    var instance_end: usize = 0;
    while (instance_end < len and data[instance_end] != 0) : (instance_end += 1) {}

    if (instance_end >= len) return null;

    const instance = allocator.dupe(u8, data[0..instance_end]) catch return null;
    errdefer allocator.free(instance);

    const class_start = instance_end + 1;
    var class_end = class_start;
    while (class_end < len and data[class_end] != 0) : (class_end += 1) {}

    if (class_start >= len) {
        allocator.free(instance);
        return null;
    }

    const class = allocator.dupe(u8, data[class_start..class_end]) catch {
        allocator.free(instance);
        return null;
    };

    return WMClass{
        .instance = instance,
        .class = class,
    };
}
