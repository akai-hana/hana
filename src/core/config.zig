// Configuration parser for Hana window manager
// Reads TOML config files and converts them into our internal Config struct

const std = @import("std");
const defs = @import("defs");
const toml = @import("toml");

const Config = defs.Config;

/// Errors that can occur when validating configuration
pub const ValidationError = error{
    InvalidKeybinding,     // Keybinding string couldn't be parsed
    DuplicateKeybinding,   // Same key combo defined twice
};

/// Map of modifier key names to their internal bitflag values
/// Supports multiple names for the same modifier (e.g., both "Ctrl" and "Control")
const MODIFIER_MAP = std.StaticStringMap(u16).initComptime(.{
    .{ "Mod4", defs.MOD_SUPER },      // Windows/Super key
    .{ "Super", defs.MOD_SUPER },
    .{ "Mod1", defs.MOD_ALT },        // Alt key
    .{ "Alt", defs.MOD_ALT },
    .{ "Shift", defs.MOD_SHIFT },     // Shift key
    .{ "Control", defs.MOD_CONTROL }, // Control key
    .{ "Ctrl", defs.MOD_CONTROL },
});

/// Get XDG-compliant config file path
/// Checks XDG_CONFIG_HOME, falls back to ~/.config/hana/config.toml
/// Caller must free the returned string
pub fn getConfigPath(allocator: std.mem.Allocator) ![]const u8 {
    // Get home directory from environment (use current dir as fallback)
    const home = std.posix.getenv("HOME") orelse ".";
    
    // Check if user has custom XDG_CONFIG_HOME, otherwise use ~/.config
    const config_home = std.posix.getenv("XDG_CONFIG_HOME") orelse
        try std.fmt.allocPrint(allocator, "{s}/.config", .{home});
    
    // Free the allocated string if we created it (not if it came from environment)
    defer if (std.posix.getenv("XDG_CONFIG_HOME") == null) allocator.free(config_home);
    
    // Build full path: $XDG_CONFIG_HOME/hana/config.toml
    return try std.fs.path.join(allocator, &.{config_home, "hana", "config.toml"});
}

/// Load configuration from the default XDG path
/// Convenience wrapper around loadConfig() that finds the config file automatically
pub fn loadConfigDefault(allocator: std.mem.Allocator) !Config {
    const path = try getConfigPath(allocator);
    defer allocator.free(path);
    return loadConfig(allocator, path);
}

/// Load configuration from a specific TOML file
/// Falls back to defaults if file doesn't exist
/// Missing sections/keys use defaults, but invalid values log warnings
pub fn loadConfig(allocator: std.mem.Allocator, path: []const u8) !Config {
    // Try to read the config file
    const content = readConfigFile(allocator, path) catch |err| switch (err) {
        // If file doesn't exist, that's fine - just use all defaults
        error.FileNotFound => {
            std.log.info("Config file not found, using defaults", .{});
            return getDefaultConfig();
        },
        // Other errors (permissions, I/O) should propagate up
        else => return err,
    };
    defer allocator.free(content); // Free the file content when we're done

    // Parse TOML syntax - any syntax errors will return an error
    var doc = try toml.parse(allocator, content);
    defer doc.deinit(); // Clean up the parsed document

    // Start with default config, then override with values from file
    var config = getDefaultConfig();
    
    // Parse keybindings section
    try parseKeybindings(allocator, &doc, &config);
    
    // Validate that all values are reasonable
    try validateConfig(allocator, &config);
    
    return config;
}

/// Read entire config file into memory - uses Zig master std.Io API
fn readConfigFile(allocator: std.mem.Allocator, path: []const u8) ![]const u8 {
    // Create I/O interface for file operations
    var threaded: std.Io.Threaded = .init_single_threaded;
    defer threaded.deinit();
    const io = threaded.io();
    
    // Read entire file with 10MB safety limit (config files should be tiny)
    const max_size = 10 * 1024 * 1024; // 10MB
    return try std.Io.Dir.cwd().readFileAlloc(io, path, allocator, @enumFromInt(max_size));
}

/// Parse the [keybindings.exec] section
/// Converts strings like "Mod4+Return = alacritty" into executable keybindings
fn parseKeybindings(allocator: std.mem.Allocator, doc: *const toml.Document, config: *Config) !void {
    // If there's no [keybindings.exec] section, no keybindings will be set
    const exec_section = doc.getSection("keybindings.exec") orelse return;
    
    // Iterate through all key = value pairs in the section
    var iter = exec_section.pairs.iterator();
    while (iter.next()) |entry| {
        const binding_str = entry.key_ptr.*;    // e.g., "Mod4+Return"
        
        // Value must be a string (the command to execute)
        const command = entry.value_ptr.*.asString() orelse {
            std.log.warn("Keybinding value must be a string: {s}", .{binding_str});
            continue;
        };
        
        // Parse the keybinding string into modifiers and keycode
        const keybind_parts = parseKeybindString(binding_str) catch |err| {
            std.log.warn("Invalid keybinding '{s}': {}", .{binding_str, err});
            continue;
        };
        
        // Create the keybind struct
        const keybind = defs.Keybind{
            .modifiers = keybind_parts.modifiers,
            .keycode = keybind_parts.keycode,
            .action = .{ .exec = try allocator.dupe(u8, command) }, // Copy command string
        };
        
        // Add to config's keybinding list
        try config.keybindings.append(allocator, keybind);
    }
}

/// Parse a keybinding string like "Mod4+Shift+Return" into parts
/// Returns the modifier flags and the actual keycode
fn parseKeybindString(str: []const u8) !struct { modifiers: u16, keycode: u8 } {
    var modifiers: u16 = 0;      // Bitfield of modifier flags
    var keycode: ?u8 = null;     // The actual key (only one allowed)
    
    // Split by '+' character (e.g., "Mod4+Shift+Return" -> ["Mod4", "Shift", "Return"])
    var parts = std.mem.splitScalar(u8, str, '+');
    while (parts.next()) |part| {
        const trimmed = std.mem.trim(u8, part, " \t");
        
        // Check if this part is a modifier key
        if (MODIFIER_MAP.get(trimmed)) |mod| {
            modifiers |= mod; // Set the corresponding bit flag
        } else {
            // This is the actual key being pressed
            // Only one key is allowed per binding
            if (keycode != null) {
                return error.MultipleKeysInBinding;
            }
            keycode = try keyNameToKeycode(trimmed);
        }
    }
    
    return .{ 
        .modifiers = modifiers, 
        .keycode = keycode orelse return error.NoKeycodeFound,
    };
}

/// Convert key name (like "Return", "a", "F1") to X11 keycode
/// This is a static mapping - a real implementation might use xkbcommon
fn keyNameToKeycode(name: []const u8) !u8 {
    // Convert to lowercase for case-insensitive matching
    var buf: [32]u8 = undefined;
    if (name.len > buf.len) return error.KeyNameTooLong;
    
    const lower = std.ascii.lowerString(&buf, name);
    
    // Static map of key names to X11 keycodes
    // These are standard X11 keycode values
    const key_map = std.StaticStringMap(u8).initComptime(.{
        // Letters (a-z)
        .{ "a", 38 }, .{ "b", 56 }, .{ "c", 54 }, .{ "d", 40 },
        .{ "e", 26 }, .{ "f", 41 }, .{ "g", 42 }, .{ "h", 43 },
        .{ "i", 31 }, .{ "j", 44 }, .{ "k", 45 }, .{ "l", 46 },
        .{ "m", 58 }, .{ "n", 57 }, .{ "o", 32 }, .{ "p", 33 },
        .{ "q", 24 }, .{ "r", 27 }, .{ "s", 39 }, .{ "t", 28 },
        .{ "u", 30 }, .{ "v", 55 }, .{ "w", 25 }, .{ "x", 53 },
        .{ "y", 29 }, .{ "z", 52 },
        
        // Numbers (0-9)
        .{ "0", 19 }, .{ "1", 10 }, .{ "2", 11 }, .{ "3", 12 },
        .{ "4", 13 }, .{ "5", 14 }, .{ "6", 15 }, .{ "7", 16 },
        .{ "8", 17 }, .{ "9", 18 },
        
        // Special keys with common alternative names
        .{ "return", 36 }, .{ "enter", 36 },   // Enter/Return key
        .{ "escape", 9 }, .{ "esc", 9 },       // Escape key
        .{ "tab", 23 },                        // Tab key
        .{ "backspace", 22 },                  // Backspace key
        .{ "space", 65 },                      // Space bar
        
        // Function keys (F1-F12)
        .{ "f1", 67 }, .{ "f2", 68 }, .{ "f3", 69 }, .{ "f4", 70 },
        .{ "f5", 71 }, .{ "f6", 72 }, .{ "f7", 73 }, .{ "f8", 74 },
        .{ "f9", 75 }, .{ "f10", 76 }, .{ "f11", 95 }, .{ "f12", 96 },
        
        // Arrow keys
        .{ "left", 113 }, .{ "right", 114 },
        .{ "up", 111 }, .{ "down", 116 },
    });
    
    // Look up the keycode, return error if key name is unknown
    return key_map.get(lower) orelse return error.UnknownKeyName;
}

/// Validate the entire configuration for consistency and safety
/// Uses sorting for better cache locality than HashMap (faster for small configs)
pub fn validateConfig(allocator: std.mem.Allocator, config: *const Config) !void {
    // Nothing to validate if we have 0 or 1 keybindings
    if (config.keybindings.items.len < 2) return;
    
    // Sort keybindings by (modifiers, keycode) for O(n log n) duplicate detection
    // This is faster than HashMap for small configs due to better cache locality
    const Context = struct {
        pub fn lessThan(_: @This(), a: defs.Keybind, b: defs.Keybind) bool {
            if (a.modifiers != b.modifiers) return a.modifiers < b.modifiers;
            return a.keycode < b.keycode;
        }
    };
    
    var sorted = try allocator.dupe(defs.Keybind, config.keybindings.items);
    defer allocator.free(sorted);
    
    std.mem.sort(defs.Keybind, sorted, Context{}, Context.lessThan);
    
    // Check for adjacent duplicates (O(n) after sort)
    for (sorted[0..sorted.len-1], sorted[1..]) |a, b| {
        if (a.modifiers == b.modifiers and a.keycode == b.keycode) {
            std.log.err("Duplicate keybinding found: mod={x} key={d}", .{a.modifiers, a.keycode});
            return ValidationError.DuplicateKeybinding;
        }
    }
}

/// Create a config with all default values
/// Used as base config before applying user overrides
fn getDefaultConfig() Config {
    return Config{
        .keybindings = .{}, // Empty list of keybindings
    };
}

/// Clean up configuration resources
/// Must be called when done with a Config to avoid memory leaks
pub fn deinit(self: *Config, allocator: std.mem.Allocator) void {
    // Free all command strings from keybindings
    for (self.keybindings.items) |*kb| {
        kb.action.deinit(allocator);
    }
    // Free the keybindings list itself
    self.keybindings.deinit(allocator);
}
