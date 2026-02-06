/// REQUIRED PATCH for Event Loop (main.zig or events.zig) - UPDATED
///
/// The dual sequence-based focus protection requires incrementing TWO counters
/// in your main event loop. Add this code to your event processing:

// Example for main.zig or wherever your event loop is:

pub fn main() !void {
    // ... your existing initialization ...
    
    while (wm.running.load(.acquire)) {
        const event = xcb.xcb_wait_for_event(wm.conn);
        if (event == null) break;
        
        // ===== ADD THIS BLOCK =====
        // Increment BOTH event counters for dual protection system
        // This allows EnterNotify to be blocked globally AND per-window
        if (wm.events_since_programmatic_action < 999) {
            wm.events_since_programmatic_action += 1;
        }
        if (wm.events_since_last_spawn < 999) {
            wm.events_since_last_spawn += 1;
        }
        // ===== END BLOCK =====
        
        // ... rest of your event handling ...
        switch (event.response_type & ~@as(u8, 0x80)) {
            xcb.XCB_MAP_REQUEST => {
                const map_event = @ptrCast(*const xcb.xcb_map_request_event_t, event);
                window.handleMapRequest(map_event, &wm);
            },
            xcb.XCB_ENTER_NOTIFY => {
                const enter_event = @ptrCast(*const xcb.xcb_enter_notify_event_t, event);
                window.handleEnterNotify(enter_event, &wm);
            },
            // ... other events ...
        }
    }
}

/// WHY TWO COUNTERS:
///
/// GLOBAL Counter (events_since_programmatic_action):
/// - Protects against EnterNotify after ANY programmatic action
/// - Covers keybindings, workspace switches, etc.
///
/// PER-WINDOW Counter (events_since_last_spawn):
/// - Extra protection specifically for newly spawned windows
/// - Prevents focus stealing even if global counter expired
/// - Tracks the most recently spawned window
///
/// COMBINED PROTECTION:
/// EnterNotify is blocked if EITHER:
/// 1. Global counter < 50 (any programmatic action within last 50 events)
/// 2. Per-window counter < 50 AND window matches last_spawned_window
///
/// This dual approach is much more robust against fast systems!
