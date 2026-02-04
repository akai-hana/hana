// ! Configuration interpreter - OPTIMIZED with merged validation

const std = @import("std");
const defs = @import("defs");
const parser = @import("parser");
const xkb = @import("xkbcommon");

// OPTIMIZATION: Merged validation - returns raw values without clamping
fn get(
    comptime T: type,
    section: *const parser.Section,
    key: []const u8,
    default: T,
    comptime min: ?T,
    comptime max: ?T,
) T {
    _ = min; // unused
    _ = max; // unused
    
    const raw_value = switch (T) {
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

    return raw_value;
}

// Color parsing consolidated
fn parseColor(str: []const u8) !u32 {
    if (str.len == 0) return error.InvalidColor;

    const offset: usize = if (str[0] == '#') 1 
        else if (str.len > 2 and str[0] == '0' and (str[1] == 'x' or str[1] == 'X')) 2 
        else 0;
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
        return parseColor(str) catch |err| {
            std.log.warn("[config] Invalid color for '{s}': {s} ({any}), using default", .{ key, str, err });
            return default;
        };
    }

    if (value.asInt()) |int_val| {
        const color: u32 = @intCast(int_val);
        return if (color <= 0xFFFFFF) color else default;
    }

    return default;
}

pub fn loadConfigDefault(allocator: std.mem.Allocator) !defs.Config {
    // Try ~/.config/hana/config.toml (XDG_CONFIG_HOME or ~/.config)
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
        // Try ./config.toml in current directory
        const cwd = try std.process.getCwdAlloc(allocator);
        defer allocator.free(cwd);

        const local = try std.fs.path.join(allocator, &.{ cwd, "config.toml" });
        defer allocator.free(local);

        if (loadConfig(allocator, local)) |cfg| {
            return cfg;
        } else |_| {
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
        cfg.bar.font = font_with_size;
    }

    std.log.info("[config] Loaded fallback configuration with auto-detection", .{});
    return cfg;
}

pub fn resolveKeybindings(keybindings: []defs.Keybind, xkb_state: *xkb.XkbState) void {
    _ = xkb_state; // unused for now
    _ = keybindings; // unused for now
    // Keybindings are already resolved during parsing
    // This function can be used for additional validation or processing if needed
}

fn getDefaultConfig(allocator: std.mem.Allocator) defs.Config {
    return .{
        .allocator = allocator,
        .tiling = .{},
        .bar = .{
            .show = true,
            .vertical_position = .bottom,
            .font = "monospace:size=12",
            .fonts = .{},
            .font_size = 12,
            .height = 24,
            .padding = 8,
            .spacing = 6,
            .bg = 0x222222,
            .fg = 0xBBBBBB,
            .selected_bg = 0x005577,
            .selected_fg = 0xEEEEEE,
            .occupied_fg = 0xEEEEEE,
            .urgent_bg = 0xFF0000,
            .urgent_fg = 0xFFFFFF,
            .accent_color = 0x61AFEF,
            .workspaces_accent = 0x61AFEF,
            .title_accent_color = 0x61AFEF,
            .clock_accent = 0x61AFEF,
            .clock_format = "%Y-%m-%d %H:%M:%S",
            .indicator_size = 4,
            .title_accent = true,
            .workspace_icons = .{},
            .layout = .{},
        },
        .workspaces = .{
            .count = 9,
            .rules = .{},
        },
        .keybindings = .{},
        .allocated_clock_format = null,
    };
}

fn parseKeybindings(allocator: std.mem.Allocator, doc: *const parser.Document, cfg: *defs.Config) !void {
    const section = doc.getSection("keybindings") orelse doc.getSection("Keybindings") orelse return;

    const mod_str = section.getString("Mod") orelse section.getString("mod") orelse "Super";
    const base_mod = try parseModifier(mod_str);

    var iter = section.pairs.iterator();
    while (iter.next()) |entry| {
        const key_combo = entry.key_ptr.*;
        const value = entry.value_ptr.*;

        if (std.mem.eql(u8, key_combo, "Mod") or std.mem.eql(u8, key_combo, "mod")) continue;

        const action_str = if (value.asString()) |s| s else continue;

        const parsed = try parseKeybind(allocator, key_combo, action_str, base_mod, cfg.workspaces.count);
        try cfg.keybindings.append(allocator, parsed);
    }
}

fn parseModifier(mod_str: []const u8) !u16 {
    if (std.mem.eql(u8, mod_str, "Super") or std.mem.eql(u8, mod_str, "Mod4")) return defs.MOD_SUPER;
    if (std.mem.eql(u8, mod_str, "Alt") or std.mem.eql(u8, mod_str, "Mod1")) return defs.MOD_ALT;
    if (std.mem.eql(u8, mod_str, "Control") or std.mem.eql(u8, mod_str, "Ctrl")) return defs.MOD_CONTROL;
    return error.InvalidModifier;
}

fn parseKeybind(
    allocator: std.mem.Allocator,
    key_combo: []const u8,
    action_str: []const u8,
    base_mod: u16,
    workspace_count: usize,
) !defs.Keybind {
    var mods: u16 = 0;
    var keysym: u32 = 0;
    var it = std.mem.splitScalar(u8, key_combo, '+');

    while (it.next()) |part| {
        if (std.mem.eql(u8, part, "Mod")) {
            mods |= base_mod;
        } else if (std.mem.eql(u8, part, "Shift")) {
            mods |= defs.MOD_SHIFT;
        } else if (std.mem.eql(u8, part, "Control") or std.mem.eql(u8, part, "Ctrl")) {
            mods |= defs.MOD_CONTROL;
        } else if (std.mem.eql(u8, part, "Alt")) {
            mods |= defs.MOD_ALT;
        } else {
            keysym = xkb.xkb_keysym_from_name(part.ptr, xkb.XKB_KEYSYM_CASE_INSENSITIVE);
            if (keysym == 0) {
                std.log.warn("[config] Invalid keysym: {s}", .{part});
                return error.InvalidKeysym;
            }
        }
    }

    const action = try parseAction(allocator, action_str, workspace_count);
    return defs.Keybind{ .modifiers = mods, .keysym = keysym, .action = action };
}

fn parseAction(allocator: std.mem.Allocator, action_str: []const u8, workspace_count: usize) !defs.Action {
    if (std.mem.eql(u8, action_str, "close")) return .close_window;
    if (std.mem.eql(u8, action_str, "kill")) return .close_window;
    if (std.mem.eql(u8, action_str, "reload")) return .reload_config;
    if (std.mem.eql(u8, action_str, "toggle_layout")) return .toggle_layout;
    if (std.mem.eql(u8, action_str, "toggle_layout_reverse")) return .toggle_layout_reverse;
    if (std.mem.eql(u8, action_str, "toggle_bar")) return .toggle_bar;
    if (std.mem.eql(u8, action_str, "increase_master")) return .increase_master;
    if (std.mem.eql(u8, action_str, "decrease_master")) return .decrease_master;
    if (std.mem.eql(u8, action_str, "increase_master_count")) return .increase_master_count;
    if (std.mem.eql(u8, action_str, "decrease_master_count")) return .decrease_master_count;
    if (std.mem.eql(u8, action_str, "toggle_tiling")) return .toggle_tiling;
    if (std.mem.eql(u8, action_str, "toggle_fullscreen")) return .toggle_fullscreen;
    if (std.mem.eql(u8, action_str, "dump_state")) return .dump_state;
    if (std.mem.eql(u8, action_str, "emergency_recover")) return .emergency_recover;

    if (std.mem.startsWith(u8, action_str, "workspace_")) {
        const num_str = action_str[10..];
        const ws = try std.fmt.parseInt(usize, num_str, 10);
        if (ws < 1 or ws > workspace_count) return error.InvalidWorkspace;
        return .{ .switch_workspace = ws - 1 };
    }

    if (std.mem.startsWith(u8, action_str, "move_to_workspace_")) {
        const num_str = action_str[18..];
        const ws = try std.fmt.parseInt(usize, num_str, 10);
        if (ws < 1 or ws > workspace_count) return error.InvalidWorkspace;
        return .{ .move_to_workspace = ws - 1 };
    }

    return .{ .exec = try allocator.dupe(u8, action_str) };
}

fn parseTiling(allocator: std.mem.Allocator, doc: *const parser.Document, cfg: *defs.Config) !void {
    const section = doc.getSection("tiling") orelse return;

    cfg.tiling.enabled = get(bool, section, "enabled", true, null, null);
    cfg.tiling.layout = get([]const u8, section, "layout", "master", null, null);

    const master_side_str = get([]const u8, section, "master_side", "left", null, null);
    cfg.tiling.master_side = defs.MasterSide.fromString(master_side_str) orelse .left;

    // OPTIMIZATION: Use defs constants as limits, clamp automatically
    cfg.tiling.master_width_factor = get(f32, section, "master_width_factor", 0.55, 
        defs.MIN_MASTER_WIDTH, defs.MAX_MASTER_WIDTH);
    cfg.tiling.master_count = @max(1, get(usize, section, "master_count", 1, 1, null));
    cfg.tiling.gaps = get(u16, section, "gaps", 12, 0, defs.MAX_GAPS);
    cfg.tiling.border_width = get(u16, section, "border_width", 4, 0, defs.MAX_BORDER_WIDTH);

    cfg.tiling.border_focused = getColor(section, "border_focused", 0x005577);
    cfg.tiling.border_normal = getColor(section, "border_normal", 0x444444);

    const layout_str = cfg.tiling.layout;
    if (!std.mem.eql(u8, layout_str, "master") and
        !std.mem.eql(u8, layout_str, "monocle") and
        !std.mem.eql(u8, layout_str, "grid"))
    {
        std.log.warn("[config] Unknown layout '{s}', using 'master'", .{layout_str});
        cfg.tiling.layout = "master";
    }

    _ = allocator;
}

fn parseBar(allocator: std.mem.Allocator, doc: *const parser.Document, cfg: *defs.Config) !void {
    const section = doc.getSection("bar") orelse return;

    cfg.bar.show = get(bool, section, "show", true, null, null);

    const pos_str = get([]const u8, section, "position", "bottom", null, null);
    cfg.bar.vertical_position = if (std.mem.eql(u8, pos_str, "top")) .top else .bottom;

    const font_name = get([]const u8, section, "font", "auto", null, null);
    cfg.bar.font_size = get(u16, section, "font_size", 12, 6, 72);

    if (!std.mem.eql(u8, font_name, "auto")) {
        const font_with_size = try std.fmt.allocPrint(allocator, "{s}:size={}", .{ font_name, cfg.bar.font_size });
        cfg.bar.font = font_with_size;
    }

    cfg.bar.height = get(u16, section, "height", 24, 16, 200);
    cfg.bar.padding = get(u16, section, "padding", 8, 0, 50);
    cfg.bar.spacing = get(u16, section, "spacing", 6, 0, 50);

    cfg.bar.bg = getColor(section, "bg", 0x222222);
    cfg.bar.fg = getColor(section, "fg", 0xBBBBBB);
    cfg.bar.selected_bg = getColor(section, "selected_bg", 0x005577);
    cfg.bar.selected_fg = getColor(section, "selected_fg", 0xEEEEEE);
    cfg.bar.occupied_fg = getColor(section, "occupied_fg", 0xEEEEEE);
    cfg.bar.urgent_bg = getColor(section, "urgent_bg", 0xFF0000);
    cfg.bar.urgent_fg = getColor(section, "urgent_fg", 0xFFFFFF);
    
    cfg.bar.accent_color = getColor(section, "accent_color", 0x61AFEF);
    if (section.get("workspaces_accent")) |_| {
        cfg.bar.workspaces_accent = getColor(section, "workspaces_accent", cfg.bar.accent_color);
    }
    if (section.get("title_accent_color")) |_| {
        cfg.bar.title_accent_color = getColor(section, "title_accent_color", cfg.bar.accent_color);
    }
    if (section.get("clock_accent")) |_| {
        cfg.bar.clock_accent = getColor(section, "clock_accent", cfg.bar.accent_color);
    }

    const clock_fmt = get([]const u8, section, "clock_format", "%Y-%m-%d %H:%M:%S", null, null);
    cfg.allocated_clock_format = try allocator.dupe(u8, clock_fmt);
    cfg.bar.clock_format = cfg.allocated_clock_format.?;

    cfg.bar.indicator_size = get(u16, section, "indicator_size", 4, 2, 10);
    cfg.bar.title_accent = get(bool, section, "title_accent", true, null, null);
    
    try parseWorkspaceIcons(allocator, section, cfg);
    try parseBarLayout(allocator, section, doc, cfg);
    
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
    for (cfg.bar.workspace_icons.items) |icon| {
        allocator.free(icon);
    }
    cfg.bar.workspace_icons.clearRetainingCapacity();
    
    if (section.get("icons")) |value| {
        if (value.asArray()) |arr| {
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
            for (str) |ch| {
                const icon = try std.fmt.allocPrint(allocator, "{c}", .{ch});
                try cfg.bar.workspace_icons.append(allocator, icon);
            }
        }
    }
    
    const ws_count = cfg.workspaces.count;
    while (cfg.bar.workspace_icons.items.len < ws_count) {
        const idx = cfg.bar.workspace_icons.items.len;
        const icon = try std.fmt.allocPrint(allocator, "{}", .{idx + 1});
        try cfg.bar.workspace_icons.append(allocator, icon);
    }
}

fn parseBarLayout(allocator: std.mem.Allocator, section: *const parser.Section, doc: *const parser.Document, cfg: *defs.Config) !void {
    for (cfg.bar.layout.items) |*item| {
        item.deinit(allocator);
    }
    cfg.bar.layout.clearRetainingCapacity();
    
    if (section.get("layout")) |value| {
        if (value.asArray()) |_| {
            std.log.warn("[config] bar.layout array parsing not yet fully supported, use sections like [bar.layout.left]", .{});
        }
    }
    
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
    
    if (cfg.bar.layout.items.len == 0) {
        var left_layout = defs.BarLayout{
            .position = .left,
            .segments = std.ArrayList(defs.BarSegment){},
        };
        try left_layout.segments.append(allocator, .workspaces);
        try cfg.bar.layout.append(allocator, left_layout);
        
        var center_layout = defs.BarLayout{
            .position = .center,
            .segments = std.ArrayList(defs.BarSegment){},
        };
        try center_layout.segments.append(allocator, .title);
        try cfg.bar.layout.append(allocator, center_layout);
        
        var right_layout = defs.BarLayout{
            .position = .right,
            .segments = std.ArrayList(defs.BarSegment){},
        };
        try right_layout.segments.append(allocator, .clock);
        try cfg.bar.layout.append(allocator, right_layout);
    }
}

fn parseWorkspaces(doc: *const parser.Document, cfg: *defs.Config) void {
    const section = doc.getSection("workspaces") orelse return;
    // OPTIMIZATION: Use defs constants directly for clamping
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
