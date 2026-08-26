# Zig Idioms & Patterns Audit — hana

Read-only analysis of all `.zig` files under `src/`.  
Each finding: **file:line**, description, idiomatic alternative, severity.

---

## 1. Non-Idiomatic Patterns

### 1.1 Global mutable `var state: ?State = null` pattern (repeated 5+ times)

| File | Line |
|------|------|
| `src/core/core.zig` | 66 |
| `src/window/window.zig` | 84 |
| `src/window/focus.zig` | 58 |
| `src/bar/bar.zig` | (State struct) |
| `src/core/input/input.zig` | 43 (`xkb_state: ?xkbcommon.XkbState = null`) |

**Current:** Each module has its own `var state: ?State = null` with a getter that `@panic`s if called before `init()`.

**Idiomatic Zig:** This is acceptable for process-global singletons with explicit init/deinit, but the pattern is **repeated manually** everywhere. The idiomatic improvement is to use a comptime-generated singleton helper or a module-level `threadlocal` if the process could ever be multi-threaded (it currently can't, but the pattern would future-proof it). At minimum, the `?T` + `@panic` dance is verbose — a wrapper function would cut boilerplate.

**Severity:** Low — the pattern works, just verbose. No correctness issue.

### 1.2 `inline fn` overuse on non-hot paths

| File | Line |
|------|------|
| `src/model/model.zig` | 23 (`bit`) |
| `src/core/utils/utils.zig` | 68, 80, 86, 92 (`eql`, `doubledBorder`, `toXcbCoord`, `normalizeModifiers`) |
| `src/sync/sync.zig` | 67–93 (all `Sink` methods) |
| `src/window/borders.zig` | 17, 27, 39, 52 (`color`, `width`, `applyWidth`, `apply`) |

**Current:** Most public functions are marked `inline fn`.

**Idiomatic Zig:** `inline` forces inlining at every call site; Zig's optimizer already inlines small functions when profitable. `inline` is appropriate for:
- comptime-known-constant expressions (e.g. `bit`, `toXcbCoord`)
- trampolines through `*anyopaque` vtables (the `Sink` methods)

But unnecessary on functions like `color()`, `width()`, `borders.apply()` which do non-trivial work (config lookup, conditional logic). The Zig style guide says: prefer letting the optimizer decide; use `inline` only when there is a concrete reason (performance, comptime requirement).

**Severity:** Low — no correctness issue, but adds compile-time cost and can pessimize codegen by bloating instruction cache.

### 1.3 `_ =` discarding return values of fallible C calls without checking

| File | Line |
|------|------|
| `src/core/utils/x11wire.zig` | 33, 43, 47, 56, 67, 80 |
| `src/sync/wire.zig` | 27, 35, 56, 67, 80, 85 |
| `src/window/window.zig` | 303 (`xcb_send_event`) |
| `src/main.zig` | 85 (`xcb_flush`) |

**Current:** `_ = xcb.xcb_configure_window(...)` — ignores the error cookie.

**Idiomatic Zig:** XCB's `xcb_*` functions return `xcb_void_cookie_t` which is a sequence number, not a true error. The protocol is asynchronous; errors arrive as `xcb_generic_error_t` later. So `_ =` is actually correct for fire-and-forget XCB requests. **No action needed.**

**Severity:** None (correct pattern for XCB).

---

## 2. Comptime Misuse

### 2.1 `ALL_MASK` comptime block — could be a simple formula

| File | Line |
|------|------|
| `src/model/model.zig` | 35–39 |

**Current:**
```zig
pub const ALL_MASK: Mask = blk: {
    var m: Mask = 0;
    for (0..MAX_WS) |i| m |= @as(Mask, 1) << @intCast(i);
    break :blk m;
};
```

**Idiomatic:** A comptime loop is fine here, but the result is just `(1 << MAX_WS) - 1`:
```zig
pub const ALL_MASK: Mask = (@as(Mask, 1) << MAX_WS) - 1;
```
This is simpler, clearer, and avoids the mutable variable. The loop version is more future-proof if `MAX_WS` ever exceeds 64 (Mask bit width), but that's an absurd scenario for a window manager.

**Severity:** Low — the loop works; the formula is cleaner.

### 2.2 `asHandler` comptime validation — well done

| File | Line |
|------|------|
| `src/core/events.zig` | 40–49 |

**Assessment:** The `asHandler` comptime function correctly validates handler signatures at compile time. This is an excellent use of `comptime` — wrong-signature handlers fail at build time, not runtime. No issue.

### 2.3 `initAtomCache` — `inline for` over struct fields

| File | Line |
|------|------|
| `src/core/utils/x11wire.zig` | 113–130 |

**Assessment:** Uses `inline for` over `std.meta.fields(AtomCache)` to build cookie arrays and drain replies at comptime. This is the textbook Zig pattern for batch-atom interning. Correct and idiomatic.

---

## 3. Memory Patterns

### 3.1 Manual `BoundedList` instead of `std.BoundedArray`

| File | Line |
|------|------|
| `src/core/utils/bounded.zig` | 15–103 |
| Used by: `window.zig:72`, `window.zig:76`, `input.zig`, `minimize.zig` |

**Current:** Custom `BoundedList(T, capacity)` with linear-scan `indexOf`, `indexOfById`, `append`, `swapRemove`, `orderedRemove`.

**Idiomatic Zig:** `std.BoundedArray(T, N)` exists since Zig 0.12+ and provides `slice()`, `append()`, `swapRemove()`, `set()`, `get()`. However, `BoundedList` adds `indexOf` with a comptime predicate and `indexOfById`, which `std.BoundedArray` does not provide. The custom type is justified.

**Severity:** None — the custom collection is a legitimate extension of the standard library's offering.

### 3.2 `std.ArrayList` / `std.ArrayListUnmanaged` usage

| File | Line |
|------|------|
| `src/window/window.zig` | 64 (`spawn_queue: std.ArrayListUnmanaged(SpawnEntry)`) |
| `src/config/parser.zig` | 25, 96 |

**Assessment:** Uses `Unmanaged` variants where the allocator is passed per-call, avoiding storing the allocator. This is idiomatic Zig for modules that want explicit allocator control.

### 3.3 Stack-allocated fixed arrays in hot paths

| File | Line |
|------|------|
| `src/sync/sync.zig` | 216–217 (`order_buf`, `hints_buf` of `store_capacity` each) |
| `src/bar/segments/title/title.zig` | 46 (`max_visible_windows: usize = 128`) |

**Current:** Stack arrays sized by `model.store_capacity` (200) are declared locally in `reconcile()`.

**Idiomatic:** Acceptable for single-threaded WM; `store_capacity` is bounded. However, each `reconcile` call allocates 200 × 4 + 200 × 24 ≈ 5.6 KiB on the stack per pass. This is fine for typical stack sizes (8 MiB default) but worth noting.

**Severity:** Low — bounded and safe in practice.

### 3.4 `defer std.c.free(reply)` — manual C free

| File | Line |
|------|------|
| `src/core/utils/x11wire.zig` | 126 |
| `src/window/window.zig` | 102, 174, 201, 345 |
| `src/bar/drawing.zig` | (Pango metrics) |

**Current:** XCB replies are heap-allocated by libxcb and freed with `std.c.free`.

**Idiomatic Zig:** This is the only correct way to free XCB reply memory. No alternative exists.

**Severity:** None.

---

## 4. Type Usage

### 4.1 `model.WSId = u16` vs `core.WorkspaceId = struct { index: u8 }`

| File | Line |
|------|------|
| `src/model/model.zig` | 20 (`pub const WSId = u16;`) |
| `src/core/core.zig` | 34–44 (`WorkspaceId` wrapper struct) |

**Current:** Two parallel types for workspace IDs: model uses raw `u16`, core wraps `u8` in a struct. The model doc comment says "Local alias so model never imports core. Convert core.WorkspaceId via `.index` at entry points."

**Idiomatic:** This is a deliberate layering choice (model layer must not import core). The conversion at the boundary (`core.WorkspaceId.index` → `model.WSId`) is explicit and safe. The `u16` vs `u8` mismatch is intentional: model uses `u16` for bit-mask operations (`bit()` shifts by workspace ID), while core uses `u8` because workspace IDs are byte-sized.

**Assessment:** Intentional and documented. Not a bug, but the type divergence means boundary conversion must happen at every call site — a comptime constraint or shared type would reduce friction.

**Severity:** Low — the layering is correct; the friction is a known tradeoff.

### 4.2 `Mask = u64` — only supports 64 workspaces

| File | Line |
|------|------|
| `src/model/model.zig` | 21 (`pub const Mask = u64;`) |

**Current:** `Mask` is `u64`, limiting workspaces to 64. `MAX_WS` comes from `constants.max_workspaces`.

**Idiomatic:** For a window manager, 64 workspaces is more than sufficient. The `ALL_MASK` comptime formula works correctly up to 64 bits. No issue.

**Severity:** None.

### 4.3 `parser.Value` union — `array: std.ArrayList(Value)` (recursive heap type)

| File | Line |
|------|------|
| `src/config/parser.zig` | 25 |

**Current:** `Value` is a tagged union where `.array` owns a heap-allocated `ArrayList(Value)`. The `deinit` recurses into nested arrays.

**Idiomatic:** Recursive self-referencing heap types in Zig unions are tricky; the `ArrayList` indirection (pointer + len + capacity) avoids infinite comptime expansion. The manual `deinit` recursion is correct.

**Severity:** None — correct pattern for recursive parse trees.

---

## 5. Error Handling Idioms

### 5.1 Silent `catch` swallowing on non-critical paths

| File | Line |
|------|------|
| `src/window/focus.zig` | 63 (`net_active_window = utils.getAtomCached(...) catch 0`) |
| `src/bar/segments/title/title.zig` | 68–69 (`getAtomCached(...) catch null`) |
| `src/config/types.zig` | 134, 136 (`map.put(...) catch {}`, `seen.put(...) catch {}`) |
| `src/main.zig` | 82 (`bar.init() catch |err| debug.err(...)`) |

**Current:** Various `catch` clauses swallow errors, either returning a sentinel (`0`, `null`) or logging and continuing.

**Assessment:** Each case is deliberate:
- Atom cache not ready → return 0/null, caller checks `!= 0` before using
- HashMap insert fails → log and continue (config reload is best-effort)
- Bar init fails → log, continue without bar

These are all correct "degrade gracefully" patterns for a window manager where crashing is worse than partial functionality.

**Severity:** None — intentional degradation.

### 5.2 `errdefer` usage — generally correct

| File | Line |
|------|------|
| `src/main.zig` | 45 (`errdefer alloc.destroy(config_ptr)`) |
| `src/config/config.zig` | 80, 87 (`errdefer allocator.free(buf)`) |

**Assessment:** `errdefer` is used correctly to clean up on error paths. The `config.zig` file-reader is particularly careful with double `errdefer` on different allocation strategies.

### 5.3 `error.StoreFull` vs `error.OutOfMemory` naming

| File | Line |
|------|------|
| `src/model/store.zig` | 19 (`pub const Error = error{StoreFull};`) |
| `src/sync/sync.zig` | 164 (`return error.OutOfMemory`) |

**Current:** `store.zig` defines `StoreFull` (a bounded-array-full error), while `sync.zig:164` uses `error.OutOfMemory` for the same condition (sent ledger full at `store_capacity`).

**Idiomatic:** `OutOfMemory` is semantically wrong here — the error is "too many tracked windows", not "malloc failed". It should be a domain-specific error like `LedgerFull` or `CapacityExceeded`. Using `error.OutOfMemory` can confuse callers into thinking heap allocation failed.

**Severity:** Medium — misleading error name on a real (though rare) capacity boundary.

### 5.4 `catch return` pattern for optional early-exit

| File | Line |
|------|------|
| `src/window/window.zig` | 159, 164, 189 |
| `src/bar/segments/title/title.zig` | 68 |

**Current:** `utils.getAtomCached("X") catch return` — when the atom isn't available, silently return from the enclosing function.

**Idiomatic:** This is concise and correct for "best-effort" paths where the function's purpose can't be fulfilled without the atom. The alternative (`if (getAtomCached(...) catch null) |atom|`) is more verbose with no benefit.

**Severity:** None.

---

## 6. Algorithm Patterns

### 6.1 `BoundedList.indexOf` — linear scan is appropriate

| File | Line |
|------|------|
| `src/core/utils/bounded.zig` | 34–39 |

**Current:** Linear scan over up to 512 entries (`max_window_cache`).

**Assessment:** The doc comment at `window.zig:138-141` correctly justifies this: "At realistic window counts (<=100 typical, <=300 extreme) a linear scan over u32 IDs in a flat array is cache-local and allocation-free." Hash map or binary search would add allocator dependency and pointer-chasing overhead.

**Severity:** None — correct tradeoff.

### 6.2 `Store` binary search — well implemented

| File | Line |
|------|------|
| `src/model/store.zig` | 26–53 |

**Assessment:** Binary search on sorted keys with O(log n) lookup, O(n) insert/remove via shift. Correct for a bounded, stack-allocated store. The `search`/`insertPos` split avoids redundant comparisons.

### 6.3 `sentGetOrPut` linear scan + manual append

| File | Line |
|------|------|
| `src/sync/sync.zig` | 157–170 |

**Current:** `sentGetOrPut` does a linear scan, then appends if not found. `sentSwapRemove` does linear scan + swap-remove. `sentGet` does linear scan.

**Assessment:** This is a hand-rolled mini hash-set using parallel arrays (`sent_keys`, `sent_vals`). It duplicates the `Store` concept without binary search (keys aren't kept sorted). This works because the sent ledger is small (bounded by `store_capacity`), but it's an opportunity to reuse `Store(model.WindowId, SentEntry, store_capacity)` for consistency.

**Severity:** Low — works correctly; minor duplication of the Store pattern.

### 6.4 `HintsView.forWin` — linear scan by value

| File | Line |
|------|------|
| `src/tiling/engine.zig` | 37–43 |

**Current:** Linear scan over order+hints slices, returns `SizeHints` by value.

**Assessment:** Doc comment at `engine.zig:23-31` explicitly justifies: O(n²) across all `emit()` calls is ~40K comparisons for 200 windows — negligible. Adding a hash map would break the zero-allocation `compute()` path.

**Severity:** None.

---

## 7. String Handling

### 7.1 `std.mem.join` for font list building

| File | Line |
|------|------|
| `src/bar/drawing.zig` | 43 |

**Current:** `std.mem.join(self.allocator, ",", font_names)` — allocates a comma-separated font string.

**Idiomatic:** `std.mem.join` is the correct stdlib function for this. No issue.

### 7.2 `allocator.dupeZ` for null-terminated C strings

| File | Line |
|------|------|
| `src/bar/drawing.zig` | 52 |

**Current:** `self.allocator.dupeZ(u8, converted)` — creates a null-terminated copy for C interop (Pango).

**Idiomatic:** `dupeZ` is the idiomatic way to get a `[:0]const u8` from a slice for C API calls.

### 7.3 `config_parser` string ownership

| File | Line |
|------|------|
| `src/config/parser.zig` | 83–92 (`Value.deinit`) |

**Current:** `Value.deinit` frees `.string` variants and recurses into `.array` variants. String ownership transfers from parser to config on parse.

**Assessment:** Consistent ownership model: parser allocates, config owns after `load()`, `deinit` on config tears everything down. Correct.

---

## 8. Struct/Enum Patterns

### 8.1 `config.Action` union — 30+ variants, no `else` catch-all

| File | Line |
|------|------|
| `src/config/types.zig` | 16–77 |

**Current:** `Action` is a 30+ variant tagged union. `deinit` uses an `else => {}` catch-all.

**Idiomatic Zig:** For tagged unions, the compiler warns on missing prongs if you don't use `else`. The `else => {}` in `deinit` is correct because most action variants don't own heap memory (only `.exec` and `.sequence` do). Adding every variant explicitly would be verbose with no benefit.

**Assessment:** Correct and idiomatic.

### 8.2 `model.Mode` union — recursive payload types

| File | Line |
|------|------|
| `src/model/model.zig` | 83–94 |

**Current:** `Mode = union(enum) { base: BaseMode, fullscreen: FullscreenPayload, minimized: MinimizedPayload }`. `MinimizedPayload.prev` is `PrevMode`, which contains `BaseMode` — not recursive back to `Mode`.

**Assessment:** The doc comment at line 82 explains: "a by-value recursive `prev: Mode` cannot compile, and the recursion depth is provably ≤ 1." This is the correct Zig pattern for bounded recursion in tagged unions.

### 8.3 `engine.Placement` vs `model.Entry` — clean separation

| File | Line |
|------|------|
| `src/tiling/engine.zig` | 9–13 |
| `src/model/model.zig` | 96–100 |

**Assessment:** `Placement` (output of layout compute) is a lean struct with `win`, `rect`, `visible`. `Entry` (model storage) carries `mask`, `mode`, `size_hints`, `home_ws`. Clean separation of concerns: the engine never sees XCB types, the model never sees layout output.

### 8.4 `sync.Sink` vtable pattern — manual polymorphism

| File | Line |
|------|------|
| `src/sync/sync.zig` | 51–93 |
| `src/sync/wire.zig` | 18–97 |

**Current:** `Sink` is a manual vtable: `ptr: *anyopaque` + `vt: *const VTable`. Production wires `XcbSink`; tests wire a recorder.

**Idiomatic Zig:** This is the standard Zig pattern for runtime polymorphism (no OOP inheritance). `anyopaque` + vtable is exactly how the stdlib implements allocator, reader, writer interfaces. Correct.

---

## Summary by Severity

| Severity | Count | Key Findings |
|----------|-------|-------------|
| **Critical** | 0 | — |
| **High** | 0 | — |
| **Medium** | 1 | `error.OutOfMemory` misname in `sync.zig:164` |
| **Low** | 5 | `ALL_MASK` formula simplification, `inline` overuse, two workspace-ID types, sent-ledger duplication of Store, global-state boilerplate |
| **None** | 15+ | XCB `_ =` discards, C free for XCB replies, linear scans (justified), BoundedList (justified), vtable pattern, etc. |

## Conclusion

The codebase is **well-structured and largely idiomatic Zig**. The architecture (model/core/window/sync layers, comptime build flags, vtable polymorphism for testability) follows Zig best practices. The main areas for improvement are minor:

1. **`sync.zig:164`** — change `error.OutOfMemory` to a domain-specific error name (medium).
2. **`model.zig:35`** — simplify `ALL_MASK` to a bit-shift formula (low).
3. **Widespread `inline`** — remove from non-trivial functions and let the optimizer decide (low).
4. **`sync.zig` sent ledger** — consider reusing `Store(WindowId, SentEntry, capacity)` instead of hand-rolled parallel arrays (low, consistency improvement).
5. **Global state boilerplate** — the `var state: ?State = null` + `getState()` pattern is repeated verbatim in 5 modules; a generic helper could reduce duplication (low).

No critical or high-severity issues were found.
