// Main WM code loop
const std = @import("std");

// core/
const config = @import("config");
const error_handling = @import("error");
const defs = @import("defs");
// modules/
const window_module = @import("window");
const input_module = @import("input");

const xcb = @cImport({
    @cInclude("xcb/xcb.h");
});

const WM = defs.WM;

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // 1. Connect to X11
    const conn = try error_handling.connectToX11();
    defer xcb.xcb_disconnect(conn);

    // 2. Get screen
    const screen = try error_handling.getX11Screen(conn);
    const root = screen.*.root;

    // 3. Try to become window manager
    const event_mask = xcb.XCB_EVENT_MASK_SUBSTRUCTURE_REDIRECT |
        xcb.XCB_EVENT_MASK_SUBSTRUCTURE_NOTIFY |
        xcb.XCB_EVENT_MASK_STRUCTURE_NOTIFY |
        xcb.XCB_EVENT_MASK_PROPERTY_CHANGE |
        xcb.XCB_EVENT_MASK_KEY_PRESS |
        xcb.XCB_EVENT_MASK_KEY_RELEASE |
        xcb.XCB_EVENT_MASK_BUTTON_PRESS |
        xcb.XCB_EVENT_MASK_BUTTON_RELEASE;

    try error_handling.becomeWindowManager(conn, root, event_mask);
    std.debug.print("hana window manager started\n", .{});

    // 4. Load config
    const user_config = try config.loadConfig(allocator, "config.toml");

    // 5. Initialize WM
    var wm = WM{
        .conn = conn,
        .screen = screen,
        .config = user_config,
        .allocator = allocator,
        .root = root,
    };

    // 6. Initialize modules
    var modules = [_]defs.Module{
        window_module.createModule(),
        input_module.createModule(),
    };

    for (&modules) |*module| {
        module.init_fn(&wm);
    }

    // 7. Build event dispatch lookup table (O(1) event routing)
    var event_dispatch = std.AutoHashMap(u8, std.ArrayList(*defs.Module)).init(allocator);
    defer {
        var iter = event_dispatch.valueIterator();
        while (iter.next()) |list| {
            list.deinit();
        }
        event_dispatch.deinit();
    }

    for (&modules) |*module| {
        for (module.events) |event_type| {
            const entry = try event_dispatch.getOrPut(event_type);
            if (!entry.found_existing) {
                entry.value_ptr.* = std.ArrayList(*defs.Module).init(allocator);
            }
            try entry.value_ptr.append(module);
        }
    }

    // 8. Main event loop
    _ = xcb.xcb_flush(conn);
    while (true) {
        const event = xcb.xcb_wait_for_event(conn);
        if (event == null) break;
        defer std.c.free(event);

        const event_type = @as(*u8, @ptrCast(event)).*;
        const response_type = event_type & ~defs.X11_SYNTHETIC_EVENT_FLAG;

        // O(1) dispatch - only call modules that handle this event
        if (event_dispatch.get(response_type)) |module_list| {
            for (module_list.items) |module| {
                module.handle_fn(event_type, event, &wm);
            }
        }

        _ = xcb.xcb_flush(conn);
    }
}
