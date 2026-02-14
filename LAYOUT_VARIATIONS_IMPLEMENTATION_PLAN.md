# Layout Variations Implementation Plan

## Overview

This document details the implementation plan for adding per-layout behavioral variations to the tiling window manager. Each layout will have its own set of variations that modify its behavior, displayed via 3-character visual indicators alongside the layout icon.

---

## Goals & Objectives

### Primary Objectives

**1. Per-Layout Variation System**
- Each layout can have multiple behavioral variations
- Variations are specific to each layout type (master has LIFO/FIFO, monocle has gaps/gapless, etc.)
- Users can cycle through variations independently of cycling through layouts

**2. Visual Indicator System**
- Each variation gets a unique 3-character visual indicator
- Indicators display alongside the layout icon in the status bar
- Indicators use ASCII art/box-drawing characters for visual clarity

**3. User Control**
- Add keybinding to cycle through current layout's variations
- Persist variation preferences in config file
- Each layout remembers its last-used variation when switching back to it

**4. Layout-Specific Behaviors**
- **Master Layout**: LIFO vs FIFO window placement order
- **Monocle Layout**: Gapless (true fullscreen) vs With Gaps (honor gap settings)
- **Grid Layout**: Rigid (strict grid with empty cells) vs Relaxed (fill available space)
- **Fibonacci Layout**: No variations (displays null indicator)

---

## Visual Indicators (3-Character)

### Master Layout `[]=`

**LIFO** (old stays master, new goes to stack):
- `]->` - Master bracket stable, arrow shows rightward flow

**FIFO** (new → master, old goes to stack):
- `<-[` - Arrow flows into master bracket

### Monocle Layout `[M]`

**Gapless** (true fullscreen, no gaps):
- **`(M)`** - no gaps, complete coverage

**With Gaps** (honor gap settings):
- **`)M(`** - gaps, just like any other layout

### Grid Layout `[+]`

**Rigid** (strict grid, leaves empty cells):
- **`[#]`** - Hash symbol = strict grid structure

**Relaxed** (fill available space):
- **`[~]`** - Wavy line = flexible, adaptive

### Fibonacci Layout `[@]`

**No Variations Available**:
- **`NUL`** - Three dashes = not applicable/no variation available
- When no variations are available to any given layout, this "NUL" should be represented in place.

---

## Configuration File Structure

### Config Fields Detail

```toml
# Master layout variation
master_variation = "lifo"
# - "lifo": Last In First Out - new windows go to stack, old stays in master
# - "fifo": First In First Out - new windows take master, old moves to stack

# Monocle layout variation  
monocle_variation = "gapless"
# - "gapless": True fullscreen, windows ignore gap settings
# - "gaps": Honor gap settings even in monocle mode

# Grid layout variation
grid_variation = "rigid"
# - "rigid": Strict grid structure, may leave empty cells
# - "relaxed": Last window in incomplete row expands to fill space
```

---

## Features to Implement

### Feature 1: Variation Type System

**What**: Define the variation types for each layout as enums and create a unified variation state.

**Why**: Provides type-safe way to represent and store variation preferences per layout.

**Implementation**:
- Create `MasterVariation`, `MonocleVariation`, `GridVariation` enums
- Create `LayoutVariation` tagged union that maps each layout to its variation type
- Ensures only valid variations can be set for each layout

### Feature 2: State Management

**What**: Add variation tracking to tiling state, separate from layout selection.

**Why**: Each layout needs to remember its own variation independently.

**Implementation**:
- Add `layout_variation: LayoutVariation` field to tiling State
- Initialize with sensible defaults (lifo, gapless, rigid)
- Update variation when cycling, preserve when switching layouts

### Feature 3: Variation Cycling

**What**: Allow users to cycle through the current layout's available variations.

**Why**: Provides runtime control over behavior without switching layouts.

**Implementation**:
- Add `cycleLayoutVariation()` function that switches to next variation
- Pattern matches on current layout to cycle appropriate variation type
- Triggers retiling with new variation applied
- Marks bar dirty to update indicator

### Feature 4: Keybinding Integration

**What**: Add keyboard shortcut to cycle variations.

**Why**: Quick access to toggle between behaviors.

**Implementation**:
- Add `cycle_layout_variation` action to input handler
- Suggested keybinding: `Super+V` for "Variation"
- Calls `tiling.cycleLayoutVariation()`

### Feature 5: Master Layout LIFO/FIFO

**What**: Control whether new windows take master position or go to stack.

**Why**: Different workflows prefer different window placement behaviors.

**Implementation**:
- Modify `addWindow()` to check master variation
- LIFO: append new window to end (existing behavior) via `windows.add()`
- FIFO: prepend new window to front via `windows.addFront()`
- Only applies when layout is master, others use default behavior

### Feature 6: Monocle Layout Gap Handling

**What**: Toggle between fullscreen and gap-respecting monocle.

**Why**: Pure monocle ignores gaps for true fullscreen, but some users want consistent gaps.

**Implementation**:
- Modify monocle layout tiling function
- Gapless: position windows at (0, screen_y) with full screen dimensions
- With Gaps: apply outer gaps like other layouts
- Switch statement on `layout_variation.monocle`

### Feature 7: Grid Layout Rigid/Relaxed

**What**: Control whether incomplete grid rows leave empty cells or expand.

**Why**: Aesthetic preference and space utilization.

**Implementation**:
- Modify grid layout calculation
- Rigid: Calculate strict cell size, position each window in its grid cell
- Relaxed: Check if window is last in incomplete row, expand width to screen edge
- Maintains grid for complete rows, only affects last incomplete row

### Feature 8: Bar Indicator Display

**What**: Show current variation indicator next to layout icon.

**Why**: Visual feedback of current variation state.

**Implementation**:
- Add `getVariationIndicator()` function returning indicator string
- Pattern matches on layout and its variation
- Update bar layout segment to display both icons
- Format: `[]=·[>>` or `[M]·═══` (use middle dot or space as separator)

### Feature 9: Config Parsing

**What**: Load variation preferences from config file.

**Why**: Persist user preferences across restarts.

**Implementation**:
- Add variation fields to `TilingConfig` struct
- Parse string values from TOML ("lifo"/"fifo", etc.)
- Use `std.meta.stringToEnum()` for parsing
- Apply to state during initialization

### Feature 10: Config Defaults

**What**: Sensible default variations when not specified in config.

**Why**: Works out of box without requiring config changes.

**Implementation**:
- Default master to LIFO (traditional behavior)
- Default monocle to gapless (pure monocle)
- Default grid to rigid (strict grid)
- Document defaults in config comments

---

## Implementation Phases

### Phase 1: Core Data Structures

**Goal**: Establish the type system and state management for variations.

**Files to Modify**:
- `src/tiling/tiling.zig`
- `src/defs.zig`

**Steps**:

1. **Define Variation Enums** (`tiling.zig`)
   ```zig
   pub const MasterVariation = enum {
       lifo,  // Last In First Out - old stays master, new → stack
       fifo,  // First In First Out - new → master, old → stack
   };

   pub const MonocleVariation = enum {
       gapless,  // True fullscreen, ignore gaps
       gaps,     // Honor gap settings
   };

   pub const GridVariation = enum {
       rigid,    // Strict grid, leave empty cells
       relaxed,  // Fill available space in incomplete rows
   };
   ```

2. **Create Variation Union** (`tiling.zig`)
   ```zig
   pub const LayoutVariation = union(Layout) {
       master: MasterVariation,
       monocle: MonocleVariation,
       grid: GridVariation,
       fibonacci: void,  // No variations
   };
   ```

3. **Add to State Struct** (`tiling.zig`)
   ```zig
   pub const State = struct {
       // ... existing fields ...
       layout: Layout,
       layout_variation: LayoutVariation,  // NEW
       
       // ... rest of struct ...
   };
   ```

4. **Initialize Default Variations** (`tiling.zig` in `State.init()` or wherever state is created)
   ```zig
   .layout = parseLayout(config.layout),
   .layout_variation = .{
       .master = .lifo,
       .monocle = .gapless,
       .grid = .rigid,
       .fibonacci = {},
   },
   ```

5. **Add to Config Struct** (`defs.zig`)
   ```zig
   pub const TilingConfig = struct {
       enabled: bool = true,
       layout: []const u8 = "master",
       border_width: u16 = 2,
       // ... existing fields ...
       
       // NEW: Variation preferences
       master_variation: []const u8 = "lifo",
       monocle_variation: []const u8 = "gapless",
       grid_variation: []const u8 = "rigid",
   };
   ```

### Phase 2: Variation Cycling Logic

**Goal**: Allow users to cycle through current layout's variations at runtime.

**Files to Modify**:
- `src/tiling/tiling.zig`
- `src/input/input.zig`

**Steps**:

1. **Add Cycling Function** (`tiling.zig`)
   ```zig
   /// Cycle to next variation for the current layout
   pub fn cycleLayoutVariation(wm: *WM) void {
       const s = StateManager.get(true) orelse return;
       
       // Switch to next variation based on current layout
       s.layout_variation = switch (s.layout) {
           .master => .{ .master = switch (s.layout_variation.master) {
               .lifo => .fifo,
               .fifo => .lifo,
           }},
           .monocle => .{ .monocle = switch (s.layout_variation.monocle) {
               .gapless => .gaps,
               .gaps => .gapless,
           }},
           .grid => .{ .grid = switch (s.layout_variation.grid) {
               .rigid => .relaxed,
               .relaxed => .rigid,
           }},
           .fibonacci => s.layout_variation,  // No change for fibonacci
       };
       
       // Re-tile with new variation
       s.markDirty();
       retileCurrentWorkspace(wm, true);
       
       // Update bar display
       @import("bar").markDirty();
   }
   ```

2. **Add Action Enum Value** (`input.zig` or wherever actions are defined)
   ```zig
   pub const Action = enum {
       // ... existing actions ...
       cycle_layout,
       cycle_layout_variation,  // NEW
       // ... rest of actions ...
   };
   ```

3. **Add Action Handler** (`input.zig` in `executeAction()`)
   ```zig
   .cycle_layout_variation => {
       const tiling = @import("tiling");
       tiling.cycleLayoutVariation(wm);
   },
   ```

4. **Add Keybinding** (in config parsing or default keybindings)
   ```zig
   // Example: Super+V for variation cycling
   { .modifiers = MOD_SUPER, .key = "v", .action = .cycle_layout_variation }
   ```

### Phase 3: Master Layout LIFO/FIFO Implementation

**Goal**: Control window placement order in master layout based on variation.

**Files to Modify**:
- `src/tiling/tiling.zig`

**Steps**:

1. **Modify addWindow Function** (`tiling.zig`)
   ```zig
   pub fn addWindow(wm: *WM, window_id: u32) void {
       std.debug.assert(window_id != 0);
       const s = StateManager.get(true) orelse return;
       if (!s.enabled) return;

       // Add window to tracking based on master variation
       if (s.layout == .master) {
           switch (s.layout_variation.master) {
               .lifo => {
                   // LIFO: new window goes to end (stack)
                   s.windows.add(window_id) catch |err| {
                       debug.logError(err, window_id);
                       return;
                   };
               },
               .fifo => {
                   // FIFO: new window goes to front (master)
                   s.windows.addFront(window_id) catch |err| {
                       debug.logError(err, window_id);
                       return;
                   };
               },
           }
       } else {
           // Other layouts use default append behavior
           s.windows.add(window_id) catch |err| {
               debug.logError(err, window_id);
               return;
           };
       }

       // ... rest of addWindow logic (borders, events, etc.) ...
   }
   ```

2. **Verify Window Order** 
   - Test with multiple windows
   - LIFO: First spawned stays in master area
   - FIFO: Most recently spawned takes master area

### Phase 4: Monocle Layout Gap Handling

**Goal**: Toggle between fullscreen and gap-respecting monocle rendering.

**Files to Modify**:
- `src/tiling/layouts/monocle.zig`

**Steps**:

1. **Add State Parameter** (if not already passed)
   ```zig
   pub fn tile(
       conn: *xcb.xcb_connection_t,
       s: *State,  // Need State reference for variation
       windows: []const u32,
       screen_w: u16,
       screen_h: u16,
       screen_y: u16
   ) void {
   ```

2. **Conditional Gap Application**
   ```zig
   pub fn tile(conn: *xcb.xcb_connection_t, s: *State, windows: []const u32, 
               screen_w: u16, screen_h: u16, screen_y: u16) void {
       
       const variation = s.layout_variation.monocle;
       
       for (windows) |win| {
           const rect = switch (variation) {
               .gapless => utils.Rect{
                   .x = 0,
                   .y = screen_y,
                   .width = screen_w,
                   .height = screen_h,
               },
               .gaps => utils.Rect{
                   .x = @intCast(s.gaps.outer),
                   .y = screen_y + @as(i16, @intCast(s.gaps.outer)),
                   .width = screen_w - 2 * s.gaps.outer,
                   .height = screen_h - 2 * s.gaps.outer,
               },
           };
           
           layouts.configure(conn, win, rect);
       }
   }
   ```

3. **Update Function Signature** (in `tiling.zig` where monocle is called)
   ```zig
   // In retile() function
   .monocle => monocle_layout.tile(wm.conn, s, ws_windows, w, h, y),
   ```

### Phase 5: Grid Layout Rigid/Relaxed Implementation

**Goal**: Control whether grid fills incomplete rows or leaves strict grid cells.

**Files to Modify**:
- `src/tiling/layouts/grid.zig`

**Steps**:

1. **Add Variation Check** (in grid layout calculation)
   ```zig
   pub fn tile(conn: *xcb.xcb_connection_t, s: *State, windows: []const u32,
               screen_w: u16, screen_h: u16, screen_y: u16) void {
       
       const variation = s.layout_variation.grid;
       
       // Calculate grid dimensions
       const win_count = windows.len;
       const cols = calculateColumns(win_count);
       const rows = calculateRows(win_count, cols);
       
       for (windows, 0..) |win, i| {
           const col = i % cols;
           const row = i / cols;
           
           // Calculate base cell dimensions
           const base_cell_w = screen_w / cols;
           const base_cell_h = screen_h / rows;
           
           // Determine if this is last window in incomplete last row
           const is_last = i == win_count - 1;
           const in_incomplete_row = win_count % cols != 0;
           
           const cell_w = switch (variation) {
               .rigid => base_cell_w,  // Always use strict cell size
               .relaxed => if (is_last and in_incomplete_row)
                   // Expand to fill remaining width
                   screen_w - (col * base_cell_w)
               else
                   base_cell_w,
           };
           
           const rect = utils.Rect{
               .x = @intCast(col * base_cell_w + s.gaps.outer),
               .y = screen_y + @as(i16, @intCast(row * base_cell_h + s.gaps.outer)),
               .width = cell_w - 2 * s.gaps.inner,
               .height = base_cell_h - 2 * s.gaps.inner,
           };
           
           layouts.configure(conn, win, rect);
       }
   }
   ```

2. **Handle Edge Cases**
   - Single window: Both variations behave the same (fullscreen)
   - Complete grid: Both variations look identical
   - Incomplete last row: Relaxed expands, Rigid maintains cell size

### Phase 6: Visual Indicator System

**Goal**: Display variation indicators in status bar alongside layout icons.

**Files to Modify**:
- `src/tiling/tiling.zig`
- `src/bar/segments/layout.zig` (or wherever layout indicator is drawn)

**Steps**:

1. **Add Indicator Function** (`tiling.zig`)
   ```zig
   /// Get 3-character indicator for current variation
   pub fn getVariationIndicator(s: *const State) []const u8 {
       return switch (s.layout) {
           .master => switch (s.layout_variation.master) {
               .lifo => "[>>",  // Old stays master, new → stack
               .fifo => "<<]",  // New → master, old → stack
           },
           .monocle => switch (s.layout_variation.monocle) {
               .gapless => "═══",  // No gaps, solid bars
               .gaps => "┼─┼",     // With gaps, plus and bars
           },
           .grid => switch (s.layout_variation.grid) {
               .rigid => "[#]",    // Hash = strict grid
               .relaxed => "[~]",  // Wavy = flexible
           },
           .fibonacci => "---",  // No variation
       };
   }
   
   /// Get combined layout indicator (layout icon + variation)
   pub fn getFullLayoutIndicator(s: *const State) struct { 
       layout: []const u8, 
       variation: []const u8 
   } {
       return .{
           .layout = getLayoutIndicator(s),      // Existing function: []=, [M], etc.
           .variation = getVariationIndicator(s),
       };
   }
   ```

2. **Update Bar Layout Segment** (`bar/segments/layout.zig`)
   ```zig
   pub fn draw(dc: *drawing.DrawContext, config: defs.BarConfig, 
               height: u16, x: u16) !u16 {
       const tiling_state = @import("tiling").getState() orelse {
           // No tiling state, don't draw
           return x;
       };
       
       const indicators = @import("tiling").getFullLayoutIndicator(tiling_state);
       const layout_icon = indicators.layout;      // e.g., "[]=", "[M]"
       const variation_icon = indicators.variation;  // e.g., "[>>", "═══"
       
       const scaled_padding = config.scaledPadding();
       const fg = config.fg;
       const bg = config.bg;
       
       // Calculate total width (both icons + separator + padding)
       const separator = " ";  // Could use "·" or other separator
       const total_text = try std.fmt.allocPrint(
           dc.allocator,
           "{s}{s}{s}",
           .{ layout_icon, separator, variation_icon }
       );
       defer dc.allocator.free(total_text);
       
       const text_width = dc.textWidth(total_text);
       const segment_width = text_width + 2 * scaled_padding;
       
       // Draw background
       dc.rect(x, 0, segment_width, height, bg);
       
       // Draw text
       const text_x = x + scaled_padding;
       const text_y = @divTrunc(height, 2);
       dc.text(total_text, text_x, text_y, fg);
       
       return x + segment_width;
   }
   ```

3. **Alternative: Side-by-Side Display**
   ```zig
   // If you prefer layout and variation as separate visual blocks:
   // Draw layout icon
   dc.rect(x, 0, layout_width, height, bg);
   dc.text(layout_icon, x + padding, y, fg);
   
   // Small gap
   const gap = 2;
   
   // Draw variation icon  
   dc.rect(x + layout_width + gap, 0, variation_width, height, bg_alt);
   dc.text(variation_icon, x + layout_width + gap + padding, y, fg);
   ```

### Phase 7: Config File Integration

**Goal**: Parse and apply variation preferences from config file.

**Files to Modify**:
- `src/config/config.zig` (or wherever TOML parsing happens)
- `src/tiling/tiling.zig`

**Steps**:

1. **Parse Config Strings** (in config parser)
   ```zig
   // Assuming you have a TOML parser that gives you a struct
   // Parse master variation
   const master_var_str = config_table.get("master_variation") orelse "lifo";
   const master_variation = std.meta.stringToEnum(
       tiling.MasterVariation, 
       master_var_str
   ) orelse .lifo;
   
   // Parse monocle variation
   const monocle_var_str = config_table.get("monocle_variation") orelse "gapless";
   const monocle_variation = std.meta.stringToEnum(
       tiling.MonocleVariation,
       monocle_var_str
   ) orelse .gapless;
   
   // Parse grid variation
   const grid_var_str = config_table.get("grid_variation") orelse "rigid";
   const grid_variation = std.meta.stringToEnum(
       tiling.GridVariation,
       grid_var_str
   ) orelse .rigid;
   ```

2. **Apply to State** (when initializing tiling state)
   ```zig
   // In State creation or applyConfigToState
   s.layout_variation = switch (s.layout) {
       .master => .{ .master = config.master_variation },
       .monocle => .{ .monocle = config.monocle_variation },
       .grid => .{ .grid = config.grid_variation },
       .fibonacci => .{ .fibonacci = {} },
   };
   ```

3. **Handle Invalid Config Values**
   ```zig
   // Use `orelse` to fall back to defaults
   const master_variation = std.meta.stringToEnum(
       tiling.MasterVariation,
       config.master_variation
   ) orelse blk: {
       debug.warn("Invalid master_variation '{s}', using default 'lifo'", 
           .{config.master_variation});
       break :blk .lifo;
   };
   ```

4. **Config Reloading**
   ```zig
   // In reloadConfig() function
   pub fn reloadConfig(wm: *WM) void {
       const s = StateManager.get(true) orelse return;
       applyConfigToState(wm, s);
       
       // Re-apply variations from new config
       s.layout_variation = switch (s.layout) {
           .master => .{ .master = wm.config.tiling.master_variation },
           .monocle => .{ .monocle = wm.config.tiling.monocle_variation },
           .grid => .{ .grid = wm.config.tiling.grid_variation },
           .fibonacci => .{ .fibonacci = {} },
       };
       
       if (s.enabled) retileCurrentWorkspace(wm, true);
   }
   ```

### Phase 8: Testing & Validation

**Goal**: Ensure all variations work correctly and handle edge cases.

**Steps**:

1. **Master LIFO Testing**
   - Start with empty workspace
   - Spawn window A → should be in master
   - Spawn window B → should be in stack, A stays in master
   - Spawn window C → should be in stack after B, A still in master
   - Close A → B should move to master

2. **Master FIFO Testing**
   - Start with empty workspace
   - Spawn window A → should be in master
   - Spawn window B → should be in master, A moves to stack
   - Spawn window C → should be in master, B and A in stack
   - Close C → B should be in master

3. **Monocle Gapless Testing**
   - Set gaps to non-zero (e.g., 10px)
   - Switch to monocle gapless
   - Window should occupy entire screen (no gaps visible)
   - Switch back to master → gaps should reappear

4. **Monocle With Gaps Testing**
   - Set gaps to non-zero (e.g., 10px)
   - Switch to monocle with gaps
   - Window should have gaps on all sides
   - Gap size should match configured gap values

5. **Grid Rigid Testing**
   - Open 3 windows in grid layout
   - Should form 2×2 grid with bottom-right cell empty
   - Each window should maintain equal cell size
   - Bottom-left window should not expand

6. **Grid Relaxed Testing**
   - Open 3 windows in grid layout
   - Should form 2×2 grid arrangement
   - Bottom-left window should expand to fill bottom row
   - Takes up 50% width (left half) of screen

7. **Variation Cycling Testing**
   - Press variation keybind in master → should toggle LIFO/FIFO
   - Press variation keybind in monocle → should toggle gapless/gaps
   - Press variation keybind in grid → should toggle rigid/relaxed
   - Press variation keybind in fibonacci → should do nothing (or show message)

8. **Bar Indicator Testing**
   - Verify correct indicator shows for each variation
   - Indicators update immediately when cycling
   - Indicators persist when switching between layouts and back

9. **Config Persistence Testing**
   - Set variations in config file
   - Restart WM
   - Verify variations are applied from config
   - Invalid config values fall back to defaults

10. **Edge Cases**
    - Single window: all variations should work
    - Zero windows: no crashes
    - Maximum windows: performance acceptable
    - Rapid variation cycling: no visual glitches
    - Window spawn during layout switch: correct placement

---

## File Modification Summary

### Files to Create
- None (all modifications to existing files)

### Files to Modify

1. **`src/tiling/tiling.zig`**
   - Add variation enum types
   - Add `LayoutVariation` union
   - Add `layout_variation` to State
   - Add `cycleLayoutVariation()` function
   - Add `getVariationIndicator()` function
   - Modify `addWindow()` for LIFO/FIFO

2. **`src/tiling/layouts/monocle.zig`**
   - Modify `tile()` to check variation
   - Apply gaps conditionally

3. **`src/tiling/layouts/grid.zig`**
   - Modify `tile()` to check variation
   - Implement relaxed width expansion

4. **`src/bar/segments/layout.zig`**
   - Import variation indicator function
   - Draw both layout and variation icons
   - Format with separator

5. **`src/input/input.zig`**
   - Add `cycle_layout_variation` action
   - Add action handler
   - Add default keybinding

6. **`src/defs.zig`**
   - Add variation fields to `TilingConfig`
   - Set default values

7. **`src/config/config.zig`** (or config parser)
   - Parse variation strings from TOML
   - Convert to enum values
   - Handle invalid values

8. **User's `config.toml`**
   - Add variation preference fields
   - Document options in comments

---

## Implementation Checklist

### Phase 1: Core Data Structures
- [ ] Define `MasterVariation` enum
- [ ] Define `MonocleVariation` enum
- [ ] Define `GridVariation` enum
- [ ] Create `LayoutVariation` union
- [ ] Add `layout_variation` to State
- [ ] Initialize default variations
- [ ] Add fields to `TilingConfig`

### Phase 2: Variation Cycling
- [ ] Implement `cycleLayoutVariation()` function
- [ ] Add `cycle_layout_variation` action enum
- [ ] Add action handler
- [ ] Add keybinding (Super+V)
- [ ] Test cycling through all layouts

### Phase 3: Master LIFO/FIFO
- [ ] Modify `addWindow()` for master layout
- [ ] Implement LIFO behavior (append)
- [ ] Implement FIFO behavior (prepend)
- [ ] Test with multiple windows
- [ ] Verify window order in both modes

### Phase 4: Monocle Gaps
- [ ] Modify `monocle.zig` tile function
- [ ] Implement gapless calculation
- [ ] Implement gaps calculation
- [ ] Test both variations visually
- [ ] Verify gap sizes match config

### Phase 5: Grid Rigid/Relaxed
- [ ] Modify `grid.zig` tile function
- [ ] Implement rigid cell sizing
- [ ] Implement relaxed expansion
- [ ] Test with various window counts
- [ ] Verify incomplete row behavior

### Phase 6: Visual Indicators
- [ ] Implement `getVariationIndicator()`
- [ ] Test all indicator strings
- [ ] Modify bar layout segment
- [ ] Test indicator display
- [ ] Verify update on variation change

### Phase 7: Config Integration
- [ ] Parse variation strings from TOML
- [ ] Convert to enum values
- [ ] Apply to state on init
- [ ] Handle invalid config values
- [ ] Test config reload

### Phase 8: Testing
- [ ] Master LIFO edge cases
- [ ] Master FIFO edge cases
- [ ] Monocle gapless verification
- [ ] Monocle gaps verification
- [ ] Grid rigid verification
- [ ] Grid relaxed verification
- [ ] Variation cycling in all layouts
- [ ] Bar indicator accuracy
- [ ] Config persistence
- [ ] Performance with many windows

---

## Expected Behavior Summary

### Master Layout `[]=`

**LIFO Mode** `[>>`
```
Initial: [Window1]
Spawn 2: [Window1] [Window2]
Spawn 3: [Window1] [Window2][Window3]
         ^master   ^------ stack ------^
```

**FIFO Mode** `<<]`
```
Initial: [Window1]
Spawn 2: [Window2] [Window1]
Spawn 3: [Window3] [Window2][Window1]
         ^master   ^------ stack ------^
```

### Monocle Layout `[M]`

**Gapless Mode** `═══`
```
┌─────────────────────┐
│                     │  ← No gaps, true fullscreen
│      Window         │
│                     │
└─────────────────────┘
```

**With Gaps Mode** `┼─┼`
```
    ┌───────────┐
    │           │  ← Gaps on all sides
    │  Window   │
    │           │
    └───────────┘
```

### Grid Layout `[+]`

**Rigid Mode** `[#]` (3 windows)
```
┌─────────┬─────────┐
│ Window1 │ Window2 │
├─────────┼─────────┤
│ Window3 │ (empty) │  ← Empty cell preserved
└─────────┴─────────┘
```

**Relaxed Mode** `[~]` (3 windows)
```
┌─────────┬─────────┐
│ Window1 │ Window2 │
├─────────┴─────────┤
│     Window3       │  ← Expands to fill row
└───────────────────┘
```

### Fibonacci Layout `[@]`

**No Variation** `---`
```
No behavioral variations available
Indicator shows "---" to signify N/A
```

---

## Notes & Considerations

### Design Decisions

1. **Why Tagged Union for LayoutVariation?**
   - Type-safe: Can only assign valid variation to each layout
   - Self-documenting: Clear which variations belong to which layout
   - Compiler-enforced: Impossible to set wrong variation type

2. **Why Independent Variation State?**
   - Each layout remembers its last variation
   - Switching between layouts preserves variation preferences
   - User doesn't lose settings when cycling layouts

3. **Why These Default Variations?**
   - LIFO: Traditional tiling WM behavior, least surprising
   - Gapless: Pure monocle aesthetic, true fullscreen
   - Rigid: Maintains visual grid structure

4. **Per-Workspace Variations**
   - Each workspace could have independent variation settings
   - Would require more complex state management

### Common Pitfalls

1. **Forgetting to Retile**
   - Always call `retileCurrentWorkspace()` after changing variation
   - Otherwise visual state won't update

2. **Layout Switch vs Variation Cycle**
   - Ensure keybindings are distinct
   - User should be able to cycle layouts and variations independently

3. **Config Parsing Errors**
   - Always provide fallback defaults
   - Log warnings for invalid values but don't crash

4. **Bar Width Calculation**
   - Account for both layout and variation indicator widths
   - Test with longest possible indicator combinations

---

## Success Criteria

Implementation is complete when:

1. ✅ All four layouts have their defined variations implemented
2. ✅ User can cycle variations with keybinding
3. ✅ Correct 3-character indicators display in status bar
4. ✅ Variations persist in config file
5. ✅ Each layout remembers its variation when switching back
6. ✅ All variations behave as specified
7. ✅ No crashes with edge cases (0 windows, 1 window, many windows)
8. ✅ Visual indicators update immediately on variation change
9. ✅ Config reload applies new variation settings
