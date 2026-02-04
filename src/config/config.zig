//! Configuration interpreter

const std = @import("std");
const defs = @import("defs");
const parser = @import("parser");
const xkb = @import("xkbcommon");

// Consolidated color parsing
pub fn parseColor(str: []const u8) !u32 {
    if (str.len == 0) return error.InvalidColor;

    const offset: usize = if (str[0] == '#') 1 else if (str.len > 2 and str[0] == '0' and (str[1] == 'x' or str[1] == 'X')) 2 else 0;
    const hex_part = str[offset..];

    if (hex_part.len == 0) return error.InvalidColor;

    const color = std.fmt.parseInt(u32, hex_part, 16) catch return error.InvalidColor;
    if (color > 0xFFFFFF) return error.InvalidColor;

    return color;
}

fn getColor(section: *const parser.Section, key: []const u8, default: u32) u32 {
    const value = section.get(key) orelse return default;

    if (value.asColor()) |color| {
        return if (color <= 0xFFFFFF) color else default;
    }

    if (value.asString()) |str| {
        const color = parseColor(str) catch {
            std.log.warn("[config] Invalid color for {s}: '{s}'", .{ key, str });
            return default;
        };
        return color;
    }

    if (value.asInt()) |int_val| {
        const color: u32 = @intCast(int_val);
        return if (color <= 0xFFFFFF) color else default;
    }

    return default;
}

// Simplified getter with inline validation and logging
fn get(
    comptime T: type,
    section: *const parser.Section,
    key: []const u8,
    default: T,
    comptime min: ?T,
    comptime max: ?T,
) T {
    const value = switch (T) {
        bool => section.getBool(key) orelse return default,
        []const u8 => section.getString(key) orelse return default,
        f32 => blk: {
            if (section.getInt(key)) |i| {
                break :blk @as(f32, @floatFromInt(i)) / 100.0;
            }
            return default;
        },
        u16, u32, usize => blk: {
            const i = section.getInt(key) orelse return default;
            break :blk @as(T, @intCast(i));
        },
        else => @compileError("Unsupported type"),
    };

    // Validate bounds and warn if out of range
    if (comptime min != null or max != null) {
        var out_of_bounds = false;
        
        if (comptime min) |m| {
            if (value < m) {
                std.log.warn("[config] Value for '{s}' ({any}) below minimum ({any}), using default ({any})", 
                    .{key, value, m, default});
                out_of_bounds = true;
            }
        }
        
        if (comptime max) |m| {
            if (value > m) {
                std.log.warn("[config] Value for '{s}' ({any}) above maximum ({any}), using default ({any})", 
                    .{key, value, m, default});
                out_of_bounds = true;
            }
        }
        
        if (out_of_bounds) return default;
    }

    return value;
}

pub fn loadConfigDefault(allocator: std.mem.Allocator) !defs.Config {
    // First, try ~/.config/hana/config.toml (XDG_CONFIG_HOME or ~/.config)
    const home = if (std.c.getenv("HOME")) |h| std.mem.span(h) else ".";
    const config_home = if (std.c.getenv("XDG_CONFIG_HOME")) |ch|
        std.mem.span(ch)
    else
        try std.fmt.allocPrint(allocator, "{s}/.config", .{home});
    defer if (std.c.getenv("XDG_CONFIG_HOME") == null) allocator.free(config_home);

    const xdg_path = try std.fs.path.join(allocator, &.{ config_home, "hana", "config.toml" });
    defer allocator.free(xdg_path);

    if (loadConfig(allocator, xdg_path)) |cfg| {
        return cfg;
    } else |_| {
        // Second, try ./config.toml in current directory
        const cwd = try std.process.getCwdAlloc(allocator);
        defer allocator.free(cwd);

        const local = try std.fs.path.join(allocator, &.{ cwd, "config.toml" });
        defer allocator.free(local);

        if (loadConfig(allocator, local)) |cfg| {
            return cfg;
        } else |_| {
            // Finally, use embedded fallback with auto-detection
            std.log.info("[config] No config.toml found, using fallback with auto-detection", .{});
            return try loadFallbackConfig(allocator);
        }
    }
}

pub fn loadConfig(allocator: std.mem.Allocator, path: []const u8) !defs.Config {
    const path_z = try allocator.dupeZ(u8, path);
    defer allocator.free(path_z);

    const fd = std.posix.open(path_z, .{ .ACCMODE = .RDONLY }, 0) catch |err| {
        if (err == error.FileNotFound) {
            std.log.info("[config] Not found: {s}", .{path});
            return err;
        }
        return err;
    };
    defer std.posix.close(fd);

    var content: std.ArrayList(u8) = .{};
    defer content.deinit(allocator);
    try content.ensureTotalCapacity(allocator, 4096);

    var buf: [4096]u8 = undefined;
    while (true) {
        const bytes_read = try std.posix.read(fd, &buf);
        if (bytes_read == 0) break;
        try content.appendSlice(allocator, buf[0..bytes_read]);
        if (content.items.len > 1024 * 1024) return error.FileTooLarge;
    }

    // Check if file is empty
    if (content.items.len == 0) {
        std.log.info("[config] Empty config file: {s}, using fallback", .{path});
        return try loadFallbackConfig(allocator);
    }

    var doc = try parser.parse(allocator, content.items);
    defer doc.deinit();

    var cfg = getDefaultConfig(allocator);

    parseWorkspaces(&doc, &cfg);
    try parseKeybindings(allocator, &doc, &cfg);
    try parseTiling(allocator, &doc, &cfg);
    try parseBar(allocator, &doc, &cfg);
    try parseRules(allocator, &doc, &cfg);

    std.log.info("[config] Loaded: {s}", .{path});
    return cfg;
}

/// Load fallback configuration with auto-detection of terminal and font
fn loadFallbackConfig(allocator: std.mem.Allocator) !defs.Config {
    const fallback = @import("fallback");
    const fallback_toml = fallback.getFallbackToml();
    
    var doc = try parser.parse(allocator, fallback_toml);
    defer doc.deinit();

    var cfg = getDefaultConfig(allocator);

    parseWorkspaces(&doc, &cfg);
    try parseKeybindings(allocator, &doc, &cfg);
    try parseTiling(allocator, &doc, &cfg);
    try parseBar(allocator, &doc, &cfg);
    try parseRules(allocator, &doc, &cfg);

    // Auto-detect terminal and replace "auto_terminal" action
    const terminal = try fallback.detectTerminal(allocator);
    for (cfg.keybindings.items) |*kb| {
        if (kb.action == .exec) {
            if (std.mem.eql(u8, kb.action.exec, "auto_terminal")) {
                allocator.free(kb.action.exec);
                kb.action.exec = try allocator.dupe(u8, terminal);
            }
        }
    }

    // Auto-detect font if set to "auto"
    if (std.mem.eql(u8, cfg.bar.font, "auto")) {
        const detected_font = try fallback.detectFont(allocator);
        const font_with_size = try std.fmt.allocPrint(allocator, "{s}:size={}", .{detected_font, cfg.bar.font_size});
        // Note: the default font string will be freed by Config.deinit, so we don't allocate it in getDefaultConfig
        cfg.bar.font = font_with_size;
    }

    std.log.info("[config] Loaded fallback configuration with auto-detection", .{});
    return cfg;
}

fn getDefaultConfig(allocator: std.mem.Allocator) defs.Config {
    // Use struct defaults from defs.zig, only initialize allocator-based fields
    return defs.Config.init(allocator);
}

fn parseKeybindings(allocator: std.mem.Allocator, doc: *const parser.Document, cfg: *defs.Config) !void {
    const section = doc.getSection("Keybindings") orelse return;

    const mod_str = get([]const u8, section, "Mod", "Super", null, null);
    const mod_mask = try parseModifier(mod_str);

    var iter = section.pairs.iterator();
    while (iter.next()) |entry| {
        const key = entry.key_ptr.*;
        const value = entry.value_ptr.*;

        if (std.mem.eql(u8, key, "Mod")) continue;

        const action_str = value.asString() orelse continue;
        const parts = parseKeybindingSpec(allocator, key) catch |err| {
            std.log.warn("[config] Failed to parse keybind '{s}': {}", .{ key, err });
            continue;
        };

        const modifiers = mod_mask | parts.mods;
        const action = try parseAction(allocator, action_str);
        
        const kb = defs.Keybind{
            .modifiers = modifiers,
            .keysym = parts.keysym,
            .action = action,
        };
        try cfg.keybindings.append(allocator, kb);
    }
}

const KeybindingSpec = struct {
    mods: u16,
    keysym: u32,
};

fn parseKeybindingSpec(allocator: std.mem.Allocator, spec: []const u8) !KeybindingSpec {
    _ = allocator;
    var mods: u16 = 0;
    var keysym: ?u32 = null;

    var it = std.mem.splitScalar(u8, spec, '+');
    while (it.next()) |part| {
        const trimmed = std.mem.trim(u8, part, " \t");

        if (std.ascii.eqlIgnoreCase(trimmed, "Mod")) {
            continue;
        } else if (std.ascii.eqlIgnoreCase(trimmed, "Shift")) {
            mods |= defs.MOD_SHIFT;
        } else if (std.ascii.eqlIgnoreCase(trimmed, "Control") or std.ascii.eqlIgnoreCase(trimmed, "Ctrl")) {
            mods |= defs.MOD_CONTROL;
        } else if (std.ascii.eqlIgnoreCase(trimmed, "Alt")) {
            mods |= defs.MOD_ALT;
        } else if (std.ascii.eqlIgnoreCase(trimmed, "Super")) {
            mods |= defs.MOD_SUPER;
        } else {
            if (keysym != null) return error.MultipleKeys;
            
            if (trimmed.len >= 64) {
                std.log.warn("[config] Key name too long: {s}", .{trimmed});
                return error.KeyNameTooLong;
            }
            
            var buf: [64]u8 = undefined;
            @memcpy(buf[0..trimmed.len], trimmed);
            buf[trimmed.len] = 0;
            
            const ks = xkb.xkb_keysym_from_name(@ptrCast(&buf), xkb.XKB_KEYSYM_CASE_INSENSITIVE);
            if (ks == xkb.XKB_KEY_NoSymbol) {
                std.log.warn("[config] Unknown key: {s}", .{trimmed});
                return error.UnknownKeyName;
            }
            keysym = ks;
        }
    }

    return KeybindingSpec{
        .mods = mods,
        .keysym = keysym orelse return error.NoKeysym,
    };
}

/// Resolve keybindings using the xkb state (called at runtime)
pub fn resolveKeybindings(keybindings: []const defs.Keybind, xkb_state: *xkb.XkbState) void {
    _ = keybindings;
    _ = xkb_state;
    // Keybindings are already resolved during parsing via parseKeybindingSpec
    // This function exists for runtime operations if needed in the future
}

fn parseModifier(str: []const u8) !u16 {
    if (std.ascii.eqlIgnoreCase(str, "Super")) return defs.MOD_SUPER;
    if (std.ascii.eqlIgnoreCase(str, "Alt")) return defs.MOD_ALT;
    if (std.ascii.eqlIgnoreCase(str, "Control") or std.ascii.eqlIgnoreCase(str, "Ctrl")) return defs.MOD_CONTROL;
    if (std.ascii.eqlIgnoreCase(str, "Shift")) return defs.MOD_SHIFT;
    return error.InvalidModifier;
}

fn parseAction(allocator: std.mem.Allocator, str: []const u8) !defs.Action {
    // Handle workspace switching
    if (std.mem.startsWith(u8, str, "workspace_")) {
        const num_str = str[10..];
        const num = std.fmt.parseInt(usize, num_str, 10) catch {
            // Fall through to exec if not a valid number
            return .{ .exec = try allocator.dupe(u8, str) };
        };
        if (num < 1 or num > defs.MAX_WORKSPACES) return error.InvalidWorkspace;
        return .{ .switch_workspace = num - 1 };
    }
    
    // Handle move to workspace
    if (std.mem.startsWith(u8, str, "move_to_workspace_")) {
        const num_str = str[18..];
        const num = std.fmt.parseInt(usize, num_str, 10) catch {
            // Fall through to exec if not a valid number
            return .{ .exec = try allocator.dupe(u8, str) };
        };
        if (num < 1 or num > defs.MAX_WORKSPACES) return error.InvalidWorkspace;
        return .{ .move_to_workspace = num - 1 };
    }
    
    // Handle named actions
    if (std.mem.eql(u8, str, "close") or std.mem.eql(u8, str, "close_window")) {
        return .close_window;
    }
    if (std.mem.eql(u8, str, "kill") or std.mem.eql(u8, str, "kill_window")) {
        return .close_window;
    }
    if (std.mem.eql(u8, str, "reload") or std.mem.eql(u8, str, "reload_config")) {
        return .reload_config;
    }
    if (std.mem.eql(u8, str, "toggle_layout")) {
        return .toggle_layout;
    }
    if (std.mem.eql(u8, str, "toggle_layout_reverse")) {
        return .toggle_layout_reverse;
    }
    if (std.mem.eql(u8, str, "toggle_bar")) {
        return .toggle_bar;
    }
    if (std.mem.eql(u8, str, "increase_master") or std.mem.eql(u8, str, "inc_master")) {
        return .increase_master;
    }
    if (std.mem.eql(u8, str, "decrease_master") or std.mem.eql(u8, str, "dec_master")) {
        return .decrease_master;
    }
    if (std.mem.eql(u8, str, "increase_master_count") or std.mem.eql(u8, str, "inc_master_count")) {
        return .increase_master_count;
    }
    if (std.mem.eql(u8, str, "decrease_master_count") or std.mem.eql(u8, str, "dec_master_count")) {
        return .decrease_master_count;
    }
    if (std.mem.eql(u8, str, "toggle_tiling")) {
        return .toggle_tiling;
    }
    if (std.mem.eql(u8, str, "toggle_fullscreen") or std.mem.eql(u8, str, "fullscreen")) {
        return .toggle_fullscreen;
    }
    if (std.mem.eql(u8, str, "dump_state")) {
        return .dump_state;
    }
    if (std.mem.eql(u8, str, "emergency_recover")) {
        return .emergency_recover;
    }
    
    // Default: treat as exec command
    return .{ .exec = try allocator.dupe(u8, str) };
}

fn parseTiling(allocator: std.mem.Allocator, doc: *const parser.Document, cfg: *defs.Config) !void {
    const section = doc.getSection("tiling") orelse return;

    cfg.tiling.enabled = get(bool, section, "enabled", true, null, null);
    cfg.tiling.master_count = get(usize, section, "master_count", 1, 0, defs.MAX_WINDOWS);
    cfg.tiling.master_width_factor = get(f32, section, "master_width_factor", 0.50, defs.MIN_MASTER_WIDTH, defs.MAX_MASTER_WIDTH);
    cfg.tiling.gaps = get(u16, section, "gaps", 10, 0, defs.MAX_GAPS);
    cfg.tiling.border_width = get(u16, section, "border_width", 2, 0, defs.MAX_BORDER_WIDTH);

    cfg.tiling.border_focused = getColor(section, "border_focused", 0x5294E2);
    cfg.tiling.border_normal = getColor(section, "border_normal", 0x383C4A);

    if (section.getString("layout")) |layout_str| {
        cfg.allocated_layout = try allocator.dupe(u8, layout_str);
        cfg.tiling.layout = cfg.allocated_layout.?;
    }

    if (section.getString("master_side")) |side_str| {
        if (defs.MasterSide.fromString(side_str)) |side| {
            cfg.tiling.master_side = side;
        }
    }
}

// PHASE 2 REFACTORING: Generic color application helper
fn applyColors(section: *const parser.Section, bar: *defs.BarConfig) void {
    const ColorMap = struct {
        key: []const u8,
        field: *u32,
        default: u32,
    };

    const colors = [_]ColorMap{
        .{ .key = "bg", .field = &bar.bg, .default = 0x222222 },
        .{ .key = "fg", .field = &bar.fg, .default = 0xBBBBBB },
        .{ .key = "selected_bg", .field = &bar.selected_bg, .default = 0x005577 },
        .{ .key = "selected_fg", .field = &bar.selected_fg, .default = 0xEEEEEE },
        .{ .key = "occupied_fg", .field = &bar.occupied_fg, .default = 0xEEEEEE },
        .{ .key = "urgent_bg", .field = &bar.urgent_bg, .default = 0xFF0000 },
        .{ .key = "urgent_fg", .field = &bar.urgent_fg, .default = 0xFFFFFF },
        .{ .key = "accent_color", .field = &bar.accent_color, .default = 0x61AFEF },
    };

    inline for (colors) |c| {
        c.field.* = getColor(section, c.key, c.default);
    }

    // Optional accent overrides (null if not specified)
    bar.workspaces_accent = if (section.get("workspaces_accent")) |_|
        getColor(section, "workspaces_accent", bar.accent_color)
    else
        null;

    bar.title_accent_color = if (section.get("title_accent_color")) |_|
        getColor(section, "title_accent_color", bar.accent_color)
    else
        null;

    bar.clock_accent = if (section.get("clock_accent")) |_|
        getColor(section, "clock_accent", bar.accent_color)
    else
        null;
}

fn parseBar(allocator: std.mem.Allocator, doc: *const parser.Document, cfg: *defs.Config) !void {
    const section = doc.getSection("bar") orelse return;

    cfg.bar.show = get(bool, section, "show", true, null, null);
    cfg.bar.height = if (section.getInt("height")) |h| @as(u16, @intCast(h)) else null;
    cfg.bar.padding = get(u16, section, "padding", 8, 0, 100);
    cfg.bar.spacing = get(u16, section, "spacing", 12, 0, 100);
    cfg.bar.font_size = get(u16, section, "font_size", 10, 6, 72);

    if (section.getString("position")) |pos_str| {
        if (defs.BarVerticalPosition.fromString(pos_str)) |pos| {
            cfg.bar.vertical_position = pos;
        }
    }

    if (section.getString("font")) |font_str| {
        cfg.allocated_font = try allocator.dupe(u8, font_str);
        cfg.bar.font = cfg.allocated_font.?;
    }

    // PHASE 2 REFACTORING: Use generic color helper
    applyColors(section, &cfg.bar);

    // Clock format
    const clock_fmt = get([]const u8, section, "clock_format", "%Y-%m-%d %H:%M:%S", null, null);
    cfg.allocated_clock_format = try allocator.dupe(u8, clock_fmt);
    cfg.bar.clock_format = cfg.allocated_clock_format.?;

    cfg.bar.indicator_size = get(u16, section, "indicator_size", 4, 2, 10);
    cfg.bar.title_accent = get(bool, section, "title_accent", true, null, null);
    
    // Parse workspace icons
    try parseWorkspaceIcons(allocator, section, cfg);
    
    // Parse bar layout
    try parseBarLayout(allocator, section, doc, cfg);
    
    // Parse per-segment colors from bar.colors section
    if (doc.getSection("bar.colors")) |colors_section| {
        if (colors_section.get("workspaces")) |_| {
            cfg.bar.workspaces_accent = getColor(colors_section, "workspaces", cfg.bar.accent_color);
        }
        if (colors_section.get("title")) |_| {
            cfg.bar.title_accent_color = getColor(colors_section, "title", cfg.bar.accent_color);
        }
        if (colors_section.get("clock")) |_| {
            cfg.bar.clock_accent = getColor(colors_section, "clock", cfg.bar.accent_color);
        }
    }
}

fn parseWorkspaceIcons(allocator: std.mem.Allocator, section: *const parser.Section, cfg: *defs.Config) !void {
    // Clear defaults
    for (cfg.bar.workspace_icons.items) |icon| {
        allocator.free(icon);
    }
    cfg.bar.workspace_icons.clearRetainingCapacity();
    
    if (section.get("icons")) |value| {
        if (value.asArray()) |arr| {
            // Array of strings
            for (arr) |item| {
                if (item.asString()) |str| {
                    const icon = try allocator.dupe(u8, str);
                    try cfg.bar.workspace_icons.append(allocator, icon);
                } else if (item.asInt()) |num| {
                    const icon = try std.fmt.allocPrint(allocator, "{}", .{num});
                    try cfg.bar.workspace_icons.append(allocator, icon);
                }
            }
        } else if (value.asString()) |str| {
            // String of characters (old format)
            for (str) |ch| {
                const icon = try std.fmt.allocPrint(allocator, "{c}", .{ch});
                try cfg.bar.workspace_icons.append(allocator, icon);
            }
        }
    }
    
    // Fill remaining with numbers if needed
    const ws_count = cfg.workspaces.count;
    while (cfg.bar.workspace_icons.items.len < ws_count) {
        const idx = cfg.bar.workspace_icons.items.len;
        const icon = try std.fmt.allocPrint(allocator, "{}", .{idx + 1});
        try cfg.bar.workspace_icons.append(allocator, icon);
    }
}

// PHASE 2 REFACTORING: Helper to create a bar layout with segments
fn makeLayout(allocator: std.mem.Allocator, pos: defs.BarPosition, segments: []const defs.BarSegment) !defs.BarLayout {
    var layout = defs.BarLayout{
        .position = pos,
        .segments = std.ArrayList(defs.BarSegment){},
    };
    try layout.segments.appendSlice(allocator, segments);
    return layout;
}

fn parseBarLayout(allocator: std.mem.Allocator, section: *const parser.Section, doc: *const parser.Document, cfg: *defs.Config) !void {
    // Clear defaults
    for (cfg.bar.layout.items) |*item| {
        item.deinit(allocator);
    }
    cfg.bar.layout.clearRetainingCapacity();
    
    // Try to parse layout array
    if (section.get("layout")) |value| {
        if (value.asArray()) |layout_arr| {
            for (layout_arr) |_| {
                // Each item should be a table with position and segments
                // Since we can't easily parse inline tables, we'll use a workaround
                // Users can define [bar.layout.0], [bar.layout.1], etc.
                std.log.warn("[config] bar.layout array parsing not yet fully supported, use sections like [bar.layout.left]", .{});
            }
        }
    }
    
    // Try to parse layout sections: [bar.layout.left], [bar.layout.center], [bar.layout.right]
    const positions = [_]struct { name: []const u8, pos: defs.BarPosition }{
        .{ .name = "bar.layout.left", .pos = .left },
        .{ .name = "bar.layout.center", .pos = .center },
        .{ .name = "bar.layout.right", .pos = .right },
    };
    
    for (positions) |p| {
        if (doc.getSection(p.name)) |layout_section| {
            var bar_layout = defs.BarLayout{
                .position = p.pos,
                .segments = std.ArrayList(defs.BarSegment){},
            };
            
            if (layout_section.get("segments")) |seg_value| {
                if (seg_value.asArray()) |seg_arr| {
                    for (seg_arr) |seg_item| {
                        if (seg_item.asString()) |seg_str| {
                            if (defs.BarSegment.fromString(seg_str)) |segment| {
                                try bar_layout.segments.append(allocator, segment);
                            }
                        }
                    }
                }
            }
            
            if (bar_layout.segments.items.len > 0) {
                try cfg.bar.layout.append(allocator, bar_layout);
            } else {
                bar_layout.deinit(allocator);
            }
        }
    }
    
    // PHASE 2 REFACTORING: Simplified default layout creation using helper
    if (cfg.bar.layout.items.len == 0) {
        try cfg.bar.layout.append(allocator, try makeLayout(allocator, .left, &.{.workspaces}));
        try cfg.bar.layout.append(allocator, try makeLayout(allocator, .center, &.{.title}));
        try cfg.bar.layout.append(allocator, try makeLayout(allocator, .right, &.{.clock}));
    }
}

fn parseWorkspaces(doc: *const parser.Document, cfg: *defs.Config) void {
    const section = doc.getSection("workspaces") orelse return;
    cfg.workspaces.count = get(usize, section, "count", 9, defs.MIN_WORKSPACES, defs.MAX_WORKSPACES);
}

fn parseRules(allocator: std.mem.Allocator, doc: *const parser.Document, cfg: *defs.Config) !void {
    if (doc.getSection("rules")) |section| {
        var iter = section.pairs.iterator();
        while (iter.next()) |entry| {
            const ws_num = entry.value_ptr.*.asInt() orelse continue;

            if (ws_num < 1 or ws_num > cfg.workspaces.count) {
                std.log.warn("[config] Rule workspace {} for '{s}' exceeds count {}, skipping", .{ ws_num, entry.key_ptr.*, cfg.workspaces.count });
                continue;
            }

            const rule = defs.Rule{
                .class_name = try allocator.dupe(u8, entry.key_ptr.*),
                .workspace = @intCast(ws_num - 1),
            };
            try cfg.workspaces.rules.append(allocator, rule);
        }
    }

    var section_iter = doc.sections.iterator();
    while (section_iter.next()) |entry| {
        const name = entry.key_ptr.*;
        const ws_str = if (std.mem.startsWith(u8, name, "workspace.rules."))
            name[16..]
        else if (std.mem.startsWith(u8, name, "rules."))
            name[6..]
        else
            continue;

        const ws_num = std.fmt.parseInt(usize, ws_str, 10) catch continue;

        if (ws_num < 1 or ws_num > cfg.workspaces.count) {
            std.log.warn("[config] Section '{s}' workspace {} exceeds count {}, skipping", .{ name, ws_num, cfg.workspaces.count });
            continue;
        }

        var iter = entry.value_ptr.pairs.iterator();
        while (iter.next()) |class_entry| {
            const rule = defs.Rule{
                .class_name = try allocator.dupe(u8, class_entry.key_ptr.*),
                .workspace = ws_num - 1,
            };
            try cfg.workspaces.rules.append(allocator, rule);
        }
    }
}
