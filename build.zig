// Build configuration for Hana window manager
// This file tells Zig how to compile, link, and run the project

const std = @import("std");

pub fn build(b: *std.Build) void {
    // Get compilation options from command line (e.g., -Dtarget=x86_64-linux)
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Create the root module (entry point of our program)
    const root_module = b.createModule(.{
        .root_source_file = b.path("src/core/main.zig"), // main.zig is where execution starts
        .target = target,
        .optimize = optimize,
        .link_libc = true, // We need C standard library for system calls
    });

    // Create the executable artifact (the actual binary that will be produced)
    const exe = b.addExecutable(.{
        .name = "hana",
        .root_module = root_module,
    });
    
    // Stripping for release builds (reduces binary size by ~50%)
    // Note: strip API varies by Zig version, so we do it post-install
    const install = b.addInstallArtifact(exe, .{});
    
    // Add strip step for release builds
    if (optimize != .Debug) {
        const strip_step = b.addSystemCommand(&[_][]const u8{
            "strip",
            "-s",
            b.getInstallPath(.bin, "hana"),
        });
        strip_step.step.dependOn(&install.step);
        b.getInstallStep().dependOn(&strip_step.step);
    } else {
        b.getInstallStep().dependOn(&install.step);
    }

    // Set up temporary memory allocator for build-time operations
    // Arena allocator is perfect for build scripts: fast allocation, single free at the end
    var arena = std.heap.ArenaAllocator.init(b.allocator);
    defer arena.deinit(); // Free all allocated memory when build() exits
    const allocator = arena.allocator();

    // HashMap to store all modules (both core and auto-discovered)
    // Key: module name (e.g., "input"), Value: pointer to the module
    var all_modules = std.StringHashMap(*std.Build.Module).init(allocator);

    // Register core modules manually (these live in src/core/)
    // Each tuple is: { "module_name", "path/to/file.zig" }
    inline for (.{
        .{ "defs", "src/core/defs.zig" },     // Type definitions and constants
        .{ "error", "src/core/error.zig" },   // Error handling utilities
        .{ "toml", "src/core/toml.zig" },     // TOML parser
        .{ "config", "src/core/config.zig" }, // Configuration loader
    }) |mod| {
        const module = b.addModule(mod[0], .{ .root_source_file = b.path(mod[1]) });
        all_modules.put(mod[0], module) catch unreachable; // Store in our collection
    }

    // Auto-discover and register all modules in src/ (except src/core/)
    // This finds all .zig files and creates modules for them automatically
    discoverModules(b, "src", allocator, &all_modules) catch |err| {
        std.debug.print("Fatal: Failed to discover modules: {}\n", .{err});
        std.process.exit(1);
    };

    // Connect all modules to each other (full mesh)
    // After this, any module can @import() any other module
    connectAllModules(root_module, &all_modules);

    // Link against system libraries we need
    exe.root_module.linkSystemLibrary("xcb", .{}); // X11 XCB library for window management

    // Create the "run" step (so we can use `zig build run`)
    const run_step = b.step("run", "Run hana");
    const run_cmd = b.addRunArtifact(exe); // Command to run our executable
    run_cmd.step.dependOn(b.getInstallStep()); // Make sure it's built first
    run_step.dependOn(&run_cmd.step);
}

// Connect all modules to each other in a full mesh
// Each module gets the ability to import every other module
fn connectAllModules(root: *std.Build.Module, modules: *std.StringHashMap(*std.Build.Module)) void {
    var iter = modules.iterator();
    while (iter.next()) |entry| {
        // For each module, give it imports to all other modules
        var import_iter = modules.iterator();
        while (import_iter.next()) |import| {
            // Skip self-import (a module can't import itself)
            if (!std.mem.eql(u8, entry.key_ptr.*, import.key_ptr.*)) {
                entry.value_ptr.*.addImport(import.key_ptr.*, import.value_ptr.*);
            }
        }
        // Also add each module to the root so main.zig can import them
        root.addImport(entry.key_ptr.*, entry.value_ptr.*);
    }
}

// Recursively scan directories for .zig files and register them as modules
fn discoverModules(
    b: *std.Build,
    dir_path: []const u8, // Directory to scan (e.g., "src")
    allocator: std.mem.Allocator,
    all_modules: *std.StringHashMap(*std.Build.Module),
) !void {
    // Create I/O interface for file system operations
    var io_threaded: std.Io.Threaded = .init_single_threaded;
    const io = io_threaded.io();

    // Open the directory for iteration
    var dir = b.build_root.handle.openDir(io, dir_path, .{ .iterate = true }) catch |err| {
        std.debug.print("Cannot open directory '{s}': {}\n", .{ dir_path, err });
        return err;
    };
    defer dir.close(io); // Always close directory handles when done

    // Iterate through all entries in the directory
    var iter = dir.iterate();
    while (try iter.next(io)) |entry| {
        // Skip src/core/ since we register those modules manually
        if (std.mem.eql(u8, dir_path, "src") and entry.kind == .directory and 
            std.mem.eql(u8, entry.name, "core")) continue;

        // If we found a subdirectory, scan it recursively
        if (entry.kind == .directory) {
            var buf: [std.fs.max_path_bytes]u8 = undefined;
            const subdir = try std.fmt.bufPrint(&buf, "{s}/{s}", .{ dir_path, entry.name });
            try discoverModules(b, subdir, allocator, all_modules);
            continue;
        }

        // Only process .zig files (skip other file types)
        if (entry.kind != .file or !std.mem.endsWith(u8, entry.name, ".zig")) continue;

        // Extract module name from filename (e.g., "input.zig" -> "input")
        const name = std.fs.path.stem(entry.name);
        
        // Build full path to the file
        var buf: [std.fs.max_path_bytes]u8 = undefined;
        const path = try std.fmt.bufPrint(&buf, "{s}/{s}", .{ dir_path, entry.name });

        // Check for name collisions (two files with the same name in different directories)
        if (all_modules.contains(name)) {
            std.debug.print("Error: Module name collision: '{s}' at {s}\n", .{ name, path });
            return error.ModuleNameCollision;
        }

        // Create the module and add it to our collection
        const module = b.createModule(.{ .root_source_file = b.path(path) });
        try all_modules.put(try allocator.dupe(u8, name), module);
        
        // Optionally print for debugging (comment out for faster builds)
        // std.debug.print("Registered: {s} ({s})\n", .{ name, path });
    }
}
