//! Thin action wrappers used by entry points (REARCHITECTURE_PLAN.md §7.2,
//! Appendix E.6). One action ≙ one §7.2 transition + one sync entry per the
//! §7.6 scheduling table. Train step a: minimize / restore / restoreAll.
//!
//! Division of labor while the strangler runs:
//!   model.*   — state transitions (tiled_order, modes, focus bookkeeping)
//!   sync.*    — geometry/border/stack/park requests (via pipeline slots)
//!   legacy    — X11 focus protocol + input-model resolve stay untouched
//!               until train f (R2); actions dispatch through window.focus.

const std = @import("std");
const model_mod = @import("model");
const pipeline = @import("pipeline");
const sync = @import("sync");
const focus = @import("focus");

pub const Ctx = struct {
    focused_window_id: ?model_mod.WindowId = null,
};

/// Current workspace as seen by the model (single source of truth).
pub inline fn currentWs() model_mod.WSId {
    return pipeline.model().current;
}

// ---------------------------------------------------------------- minimize

/// BC06 atomicity: minimize + fallback-focus + retile land under one grab.
pub fn minimize(ctx: *Ctx, win: model_mod.WindowId) void {
    const m = pipeline.model();
    model_mod.minimize(m, win) catch return; // BC26 pre-refusal (CapacityFull)
    m.setFocus(null);
    if (ctx.focused_window_id == win) focusFallback(m, ctx);
    pipeline.reconcileUnderGrabNow(.{ .force_restack = true }); // BC06 atomicity
}

/// BC06 fallback: own-workspace scope only. Order: current ws focus_mru ->
/// reversed tiled_order -> any floating on ws. First visibleOn(current) wins.
/// Protocol layer untouched until train f (R2): winner goes through the
/// legacy take-focus dispatch; null winner clears focus.
pub fn focusFallback(m: *const model_mod.Model, ctx: *Ctx) void {
    _ = ctx;
    if (pickFallback(m)) |winner| {
        focus.setFocus(winner, .tiling_operation);
    } else {
        focus.clearFocus();
    }
}

fn pickFallback(m: *const model_mod.Model) ?model_mod.WindowId {
    const ws = m.current;
    // 1. current-ws focus MRU, newest first, skipping the minimized window
    //    (it is already mode=.minimized here so visibleOn would skip it too).
    const mru = &m.ws[ws].focus_mru;
    var i = mru.items.len;
    while (i > 0) {
        i -= 1;
        const cand = mru.items[i];
        if (model_mod.visibleOn(m, cand, ws)) return cand;
    }
    // 2. reversed tiled_order of the current workspace.
    const order = &m.ws[ws].tiled_order;
    var j = order.items.len;
    while (j > 0) {
        j -= 1;
        const cand = order.items[j];
        if (model_mod.visibleOn(m, cand, ws)) return cand;
    }
    // 3. any floating window on ws (base mode, not in tiled_order).
    for (0..m.store.count()) |k| {
        const it = m.store.at(k);
        if (it.val.mode != .base) continue;
        if (!model_mod.visibleOn(m, it.key, ws)) continue;
        var tiled = false;
        for (order.items) |t| if (t == it.key) {
            tiled = true;
            break;
        };
        if (!tiled) return it.key;
    }
    return null;
}

// ----------------------------------------------------------------- restore

/// Restores a specific minimized window (title-bar click path).
pub fn restore(ctx: *Ctx, win: model_mod.WindowId) void {
    const m = pipeline.model();
    if (!isMinimizedOnAnyWs(m, win)) return;
    model_mod.restore(m, win);
    focus.setFocus(win, .window_spawn); // protocol untouched until train f
    pipeline.reconcileUnderGrabNow(.{ .force_restack = true });
}

pub fn restoreLifo(ctx: *Ctx) void {
    restoreOrdered(ctx, .lifo);
}

pub fn restoreFifo(ctx: *Ctx) void {
    restoreOrdered(ctx, .fifo);
}

fn restoreOrdered(ctx: *Ctx, order: model_mod.RestoreOrder) void {
    const m = pipeline.model();
    const win = model_mod.restoreCandidate(m, currentWs(), order) orelse return;
    model_mod.restore(m, win);
    focus.setFocus(win, .window_spawn);
    pipeline.reconcileUnderGrabNow(.{ .force_restack = true });
}

/// BC09: slot-ordered bulk restore of the current workspace; LIFO focus on
/// the last-restored plain window emerges from model.restoreAllOnWs + the
/// explicit focus below. Fullscreen-prev windows replay through the same
/// reconcile's fullscreen branch (BC08 straight-back-into-fullscreen).
pub fn restoreAll(ctx: *Ctx) void {
    const m = pipeline.model();
    const target = model_mod.restoreCandidate(m, currentWs(), .lifo) orelse return;
    model_mod.restoreAllOnWs(m, currentWs());
    focus.setFocus(target, .window_spawn);
    pipeline.reconcileUnderGrabNow(.{ .force_restack = true });
}

fn isMinimizedOnAnyWs(m: *const model_mod.Model, win: model_mod.WindowId) bool {
    const e = m.store.get(win) orelse return false;
    return e.mode == .minimized;
}
