const std = @import("std");

/// Frame timing statistics
pub const FrameStats = struct {
    /// Total frames composed
    total_frames: u64 = 0,
    /// Frames that missed their deadline
    missed_frames: u64 = 0,
    /// Last frame duration in nanoseconds
    last_frame_ns: u64 = 0,
    /// Average frame duration (exponential moving average)
    avg_frame_ns: u64 = 0,
    /// Maximum frame duration observed
    max_frame_ns: u64 = 0,
    /// Minimum frame duration observed
    min_frame_ns: u64 = std.math.maxInt(u64),

    pub fn update(self: *FrameStats, duration_ns: u64, missed: bool) void {
        self.total_frames += 1;
        if (missed) self.missed_frames += 1;

        self.last_frame_ns = duration_ns;
        self.max_frame_ns = @max(self.max_frame_ns, duration_ns);
        self.min_frame_ns = @min(self.min_frame_ns, duration_ns);

        // Exponential moving average (alpha = 0.1)
        if (self.avg_frame_ns == 0) {
            self.avg_frame_ns = duration_ns;
        } else {
            self.avg_frame_ns = (self.avg_frame_ns * 9 + duration_ns) / 10;
        }
    }

    pub fn getMissRate(self: *const FrameStats) f64 {
        if (self.total_frames == 0) return 0.0;
        return @as(f64, @floatFromInt(self.missed_frames)) /
            @as(f64, @floatFromInt(self.total_frames));
    }

    pub fn getAverageFps(self: *const FrameStats) f64 {
        if (self.avg_frame_ns == 0) return 0.0;
        return 1_000_000_000.0 / @as(f64, @floatFromInt(self.avg_frame_ns));
    }
};

/// Frame scheduler - manages timing for vsync-aligned composition
pub const FrameScheduler = struct {
    /// Target refresh rate in Hz
    target_hz: u32,
    /// Target frame interval in nanoseconds
    frame_interval_ns: u64,
    /// Next frame deadline
    next_deadline_ns: i128,
    /// Current frame number
    frame_number: u64,
    /// Whether scheduler is running
    running: bool,
    /// Frame timing statistics
    stats: FrameStats,
    /// Callback for frame events
    frame_callback: ?*const fn (frame: u64, deadline_ns: i128) void,

    const Self = @This();

    /// Initialize with target refresh rate
    pub fn init(target_hz: u32) Self {
        const interval = @divFloor(1_000_000_000, @as(u64, target_hz));
        return .{
            .target_hz = target_hz,
            .frame_interval_ns = interval,
            .next_deadline_ns = 0,
            .frame_number = 0,
            .running = false,
            .stats = .{},
            .frame_callback = null,
        };
    }

    /// Start the scheduler
    pub fn start(self: *Self) void {
        self.running = true;
        self.next_deadline_ns = std.time.nanoTimestamp() + @as(i128, self.frame_interval_ns);
        self.frame_number = 0;
    }

    /// Stop the scheduler
    pub fn stop(self: *Self) void {
        self.running = false;
    }

    /// Set frame callback
    pub fn setCallback(self: *Self, callback: *const fn (u64, i128) void) void {
        self.frame_callback = callback;
    }

    /// Get time until next frame deadline
    pub fn getTimeUntilDeadline(self: *const Self) i64 {
        const now = std.time.nanoTimestamp();
        const remaining = self.next_deadline_ns - now;
        return @intCast(@max(0, remaining));
    }

    /// Check if it's time for a new frame
    pub fn shouldComposite(self: *const Self) bool {
        if (!self.running) return false;
        const now = std.time.nanoTimestamp();
        return now >= self.next_deadline_ns;
    }

    /// Begin a new frame (call before compositing)
    pub fn beginFrame(self: *Self) FrameHandle {
        const start_time = std.time.nanoTimestamp();
        return .{
            .scheduler = self,
            .start_time = start_time,
            .frame_number = self.frame_number,
        };
    }

    /// Advance to next frame (called automatically by FrameHandle.end)
    fn advanceFrame(self: *Self, duration_ns: u64) void {
        const now = std.time.nanoTimestamp();
        const missed = now > self.next_deadline_ns + @as(i128, self.frame_interval_ns / 2);

        self.stats.update(duration_ns, missed);
        self.frame_number += 1;

        // Calculate next deadline
        // If we're behind, snap to next interval rather than accumulating debt
        if (now > self.next_deadline_ns) {
            const intervals_behind = @divFloor(
                @as(u128, @intCast(now - self.next_deadline_ns)),
                self.frame_interval_ns,
            );
            self.next_deadline_ns += @as(i128, @intCast((intervals_behind + 1) * self.frame_interval_ns));
        } else {
            self.next_deadline_ns += @as(i128, self.frame_interval_ns);
        }

        // Invoke callback if set
        if (self.frame_callback) |cb| {
            cb(self.frame_number, self.next_deadline_ns);
        }
    }

    /// Wait for next frame deadline (blocking)
    pub fn waitForDeadline(self: *Self) void {
        const wait_ns = self.getTimeUntilDeadline();
        if (wait_ns > 0) {
            std.time.sleep(@intCast(wait_ns));
        }
    }

    /// Get current frame number
    pub fn getFrameNumber(self: *const Self) u64 {
        return self.frame_number;
    }

    /// Get frame statistics
    pub fn getStats(self: *const Self) FrameStats {
        return self.stats;
    }

    /// Set target refresh rate
    pub fn setTargetHz(self: *Self, hz: u32) void {
        self.target_hz = hz;
        self.frame_interval_ns = @divFloor(1_000_000_000, @as(u64, hz));
    }

    /// Calculate presentation timestamp for a frame
    pub fn getPresentationTime(self: *const Self, frame_offset: u64) i128 {
        return self.next_deadline_ns + @as(i128, frame_offset * self.frame_interval_ns);
    }
};

/// Handle for an active frame (RAII-style timing)
pub const FrameHandle = struct {
    scheduler: *FrameScheduler,
    start_time: i128,
    frame_number: u64,

    /// End the frame and record timing
    pub fn end(self: *FrameHandle) void {
        const end_time = std.time.nanoTimestamp();
        const duration: u64 = @intCast(end_time - self.start_time);
        self.scheduler.advanceFrame(duration);
    }

    /// Get elapsed time since frame start
    pub fn getElapsed(self: *const FrameHandle) u64 {
        const now = std.time.nanoTimestamp();
        return @intCast(now - self.start_time);
    }

    /// Get remaining time until deadline
    pub fn getRemaining(self: *const FrameHandle) i64 {
        return self.scheduler.getTimeUntilDeadline();
    }
};

/// Adaptive frame pacing - adjusts target based on actual performance
pub const AdaptiveScheduler = struct {
    scheduler: FrameScheduler,
    /// Minimum acceptable refresh rate
    min_hz: u32,
    /// Maximum refresh rate (native)
    max_hz: u32,
    /// Number of frames to sample before adjusting
    sample_window: u32,
    /// Current sample count
    sample_count: u32,
    /// Accumulated miss count in window
    window_misses: u32,

    pub fn init(min_hz: u32, max_hz: u32) AdaptiveScheduler {
        return .{
            .scheduler = FrameScheduler.init(max_hz),
            .min_hz = min_hz,
            .max_hz = max_hz,
            .sample_window = 60, // Sample every 60 frames
            .sample_count = 0,
            .window_misses = 0,
        };
    }

    pub fn start(self: *AdaptiveScheduler) void {
        self.scheduler.start();
        self.sample_count = 0;
        self.window_misses = 0;
    }

    pub fn stop(self: *AdaptiveScheduler) void {
        self.scheduler.stop();
    }

    pub fn beginFrame(self: *AdaptiveScheduler) FrameHandle {
        return self.scheduler.beginFrame();
    }

    /// Update adaptive pacing after frame completion
    pub fn endFrame(self: *AdaptiveScheduler, handle: *FrameHandle) void {
        const start_stats = self.scheduler.stats;
        handle.end();

        // Track misses
        if (self.scheduler.stats.missed_frames > start_stats.missed_frames) {
            self.window_misses += 1;
        }

        self.sample_count += 1;

        // Check if we should adjust
        if (self.sample_count >= self.sample_window) {
            self.adjustRate();
            self.sample_count = 0;
            self.window_misses = 0;
        }
    }

    fn adjustRate(self: *AdaptiveScheduler) void {
        const miss_rate = @as(f32, @floatFromInt(self.window_misses)) /
            @as(f32, @floatFromInt(self.sample_window));

        if (miss_rate > 0.1 and self.scheduler.target_hz > self.min_hz) {
            // Too many misses, reduce rate
            const new_hz = @max(self.min_hz, self.scheduler.target_hz - 10);
            self.scheduler.setTargetHz(new_hz);
        } else if (miss_rate < 0.02 and self.scheduler.target_hz < self.max_hz) {
            // Running smoothly, try increasing
            const new_hz = @min(self.max_hz, self.scheduler.target_hz + 5);
            self.scheduler.setTargetHz(new_hz);
        }
    }

    pub fn shouldComposite(self: *const AdaptiveScheduler) bool {
        return self.scheduler.shouldComposite();
    }

    pub fn waitForDeadline(self: *AdaptiveScheduler) void {
        self.scheduler.waitForDeadline();
    }

    pub fn getStats(self: *const AdaptiveScheduler) FrameStats {
        return self.scheduler.getStats();
    }

    pub fn getCurrentHz(self: *const AdaptiveScheduler) u32 {
        return self.scheduler.target_hz;
    }
};

// ============================================================================
// Tests
// ============================================================================

test "FrameScheduler basic" {
    var sched = FrameScheduler.init(60);
    sched.start();

    try std.testing.expect(sched.running);
    try std.testing.expectEqual(@as(u64, 16_666_666), sched.frame_interval_ns);

    var handle = sched.beginFrame();
    std.time.sleep(1_000_000); // 1ms
    handle.end();

    try std.testing.expectEqual(@as(u64, 1), sched.stats.total_frames);
    try std.testing.expect(sched.stats.last_frame_ns >= 1_000_000);
}

test "FrameStats update" {
    var stats = FrameStats{};

    stats.update(16_000_000, false); // 16ms
    try std.testing.expectEqual(@as(u64, 1), stats.total_frames);
    try std.testing.expectEqual(@as(u64, 0), stats.missed_frames);

    stats.update(20_000_000, true); // 20ms, missed
    try std.testing.expectEqual(@as(u64, 2), stats.total_frames);
    try std.testing.expectEqual(@as(u64, 1), stats.missed_frames);
}

test "AdaptiveScheduler init" {
    const adaptive = AdaptiveScheduler.init(30, 60);
    try std.testing.expectEqual(@as(u32, 30), adaptive.min_hz);
    try std.testing.expectEqual(@as(u32, 60), adaptive.max_hz);
    try std.testing.expectEqual(@as(u32, 60), adaptive.scheduler.target_hz);
}
