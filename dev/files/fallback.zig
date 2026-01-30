///! Fallback configuration logic - terminal and font detection
const std = @import("std");

// Terminal detection - ordered by preference
const TERMINALS = [_][]const u8{
    "ghostty",
    "alacritty",
    "kitty",
    "wezterm",
    "foot",
    "st",
    "urxvt",
    "rxvt",
    "xterm",
    "konsole",
    "gnome-terminal",
    "xfce4-terminal",
    "mate-terminal",
    "lxterminal",
    "terminator",
};

// Font detection - ordered by preference
const FONTS = [_][]const u8{
    "FiraCode Nerd Font Ret",
    "FiraCode Retina",
    "FiraCode Nerd Font",
    "FiraCode",
    "JetBrains Mono Nerd Font",
    "JetBrains Mono",
    "Terminus",
    "monospace", // System fallback
};

/// Detect first available terminal from the system
pub fn detectTerminal(allocator: std.mem.Allocator) ![]const u8 {
    for (TERMINALS) |terminal| {
        if (isCommandAvailable(allocator, terminal)) {
            std.log.info("[fallback] Detected terminal: {s}", .{terminal});
            return terminal;
        }
    }
    
    // Ultimate fallback
    std.log.warn("[fallback] No preferred terminal found, using 'xterm'", .{});
    return "xterm";
}

/// Detect first available font from the system
pub fn detectFont(allocator: std.mem.Allocator) ![]const u8 {
    for (FONTS) |font| {
        if (isFontAvailable(allocator, font)) {
            std.log.info("[fallback] Detected font: {s}", .{font});
            return font;
        }
    }
    
    // Ultimate fallback
    std.log.warn("[fallback] No preferred font found, using 'monospace'", .{});
    return "monospace";
}

/// Check if a command is available in PATH
fn isCommandAvailable(allocator: std.mem.Allocator, command: []const u8) bool {
    const result = std.process.Child.run(.{
        .allocator = allocator,
        .argv = &[_][]const u8{ "which", command },
    }) catch return false;
    
    defer {
        allocator.free(result.stdout);
        allocator.free(result.stderr);
    }
    
    return result.term.Exited == 0;
}

/// Check if a font is available using fc-list
fn isFontAvailable(allocator: std.mem.Allocator, font: []const u8) bool {
    // Special case for monospace - always available
    if (std.mem.eql(u8, font, "monospace")) return true;
    
    const result = std.process.Child.run(.{
        .allocator = allocator,
        .argv = &[_][]const u8{ "fc-list", font },
    }) catch return false;
    
    defer {
        allocator.free(result.stdout);
        allocator.free(result.stderr);
    }
    
    // If fc-list returns any output, the font exists
    return result.term.Exited == 0 and result.stdout.len > 0;
}

/// Load fallback TOML embedded in binary
pub fn getFallbackToml() []const u8 {
    return @embedFile("fallback.toml");
}
