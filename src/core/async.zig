//! Asynchronous job queue for non-blocking window manager operations.
//! Allows heavy operations like retiling to run without blocking the event loop.

const std = @import("std");
const defs = @import("defs");
const WM = defs.WM;

pub const JobType = enum {
    retile,
    workspace_switch,
    layout_change,
};

var job_counter = std.atomic.Value(u64).init(0);

pub const Job = struct {
    type: JobType,
    data: JobData,
    priority: u8 = 0,
    sequence: u64,

    pub const JobData = union(JobType) {
        retile: void,
        workspace_switch: struct { from: usize, to: usize },
        layout_change: void,
    };

    pub fn lessThan(_: void, a: Job, b: Job) std.math.Order {
        // Higher priority first, then older jobs first (lower sequence number)
        if (a.priority != b.priority) {
            return if (a.priority > b.priority) .lt else .gt;
        }
        return if (a.sequence < b.sequence) .lt else .gt;
    }
};

pub const AsyncQueue = struct {
    mutex: std.Thread.Mutex = .{},
    jobs: std.PriorityQueue(Job, void, Job.lessThan),
    pending: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) !AsyncQueue {
        return .{
            .jobs = std.PriorityQueue(Job, void, Job.lessThan).init(allocator, {}),
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *AsyncQueue) void {
        self.jobs.deinit();
    }

    /// Submit a job for asynchronous processing
    pub fn submit(self: *AsyncQueue, job_type: JobType, data: Job.JobData, priority: u8) !void {
        self.mutex.lock();
        defer self.mutex.unlock();

        const job = Job{
            .type = job_type,
            .data = data,
            .priority = priority,
            .sequence = job_counter.fetchAdd(1, .monotonic),
        };

        try self.jobs.add(job);
        self.pending.store(true, .release);
    }

    /// Try to get the next job (non-blocking)
    pub fn poll(self: *AsyncQueue) ?Job {
        if (!self.pending.load(.acquire)) return null;

        self.mutex.lock();
        defer self.mutex.unlock();

        const job = self.jobs.removeOrNull() orelse {
            self.pending.store(false, .release);
            return null;
        };

        if (self.jobs.count() == 0) {
            self.pending.store(false, .release);
        }

        return job;
    }

    /// Check if there are pending jobs without removing them
    pub fn hasPending(self: *AsyncQueue) bool {
        return self.pending.load(.acquire);
    }

    /// Clear all pending jobs
    pub fn clear(self: *AsyncQueue) void {
        self.mutex.lock();
        defer self.mutex.unlock();

        while (self.jobs.removeOrNull()) |_| {}
        self.pending.store(false, .release);
    }

    /// Get the number of pending jobs
    pub fn count(self: *AsyncQueue) usize {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.jobs.count();
    }
};

var global_queue: ?*AsyncQueue = null;

/// Initialize the global async queue
pub fn initGlobal(allocator: std.mem.Allocator) !void {
    const queue = try allocator.create(AsyncQueue);
    queue.* = try AsyncQueue.init(allocator);
    global_queue = queue;
}

/// Deinitialize the global async queue
pub fn deinitGlobal(allocator: std.mem.Allocator) void {
    if (global_queue) |queue| {
        queue.deinit();
        allocator.destroy(queue);
        global_queue = null;
    }
}

/// Get the global async queue
pub fn getGlobal() ?*AsyncQueue {
    return global_queue;
}

/// Submit a job to the global queue
pub fn submitGlobal(job_type: JobType, data: Job.JobData, priority: u8) !void {
    if (global_queue) |queue| {
        try queue.submit(job_type, data, priority);
    }
}

/// Process pending jobs from the global queue
pub fn processPending(wm: *WM) void {
    const queue = global_queue orelse return;

    // Process up to 5 jobs per tick to avoid blocking
    var processed: usize = 0;
    const max_per_tick: usize = 5;

    while (processed < max_per_tick) : (processed += 1) {
        const job = queue.poll() orelse break;

        switch (job.data) {
            .retile => {
                const tiling = @import("tiling");
                tiling.retileCurrentWorkspace(wm);
            },
            .workspace_switch => |ws| {
                const workspaces = @import("workspaces");
                workspaces.switchToImmediate(wm, ws.to);
            },
            .layout_change => {
                const tiling = @import("tiling");
                tiling.retileCurrentWorkspace(wm);
            },
        }
    }
}
