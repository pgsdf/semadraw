const std = @import("std");
const damage = @import("damage");
const frame_scheduler = @import("frame_scheduler");
const backend_mod = @import("backend");
const surface_registry = @import("surface_registry");

const log = std.log.scoped(.compositor);

/// Compositor output configuration
pub const OutputConfig = struct {
    /// Output width in pixels
    width: u32 = 1920,
    /// Output height in pixels
    height: u32 = 1080,
    /// Pixel format
    format: backend_mod.PixelFormat = .rgba8,
    /// Target refresh rate
    refresh_hz: u32 = 60,
    /// Background color (RGBA, 0.0-1.0)
    background_color: [4]f32 = .{ 0.0, 0.0, 0.0, 1.0 },
    /// Backend type to use
    backend_type: backend_mod.BackendType = .software,
};

/// Composition state for a single output
pub const Output = struct {
    /// Output ID
    id: u32,
    /// Configuration
    config: OutputConfig,
    /// Backend for rendering
    be: backend_mod.Backend,
    /// Last composed frame
    last_frame: u64,
};

/// Compositor - orchestrates surface composition
pub const Compositor = struct {
    allocator: std.mem.Allocator,
    /// Surface registry reference
    surfaces: *surface_registry.SurfaceRegistry,
    /// Damage tracker
    damage_tracker: damage.DamageTracker,
    /// Frame scheduler
    scheduler: frame_scheduler.FrameScheduler,
    /// Primary output
    output: ?Output,
    /// Composition state
    composing: bool,
    /// Statistics
    total_composites: u64,
    total_surfaces_composed: u64,

    const Self = @This();

    pub fn init(
        allocator: std.mem.Allocator,
        surfaces: *surface_registry.SurfaceRegistry,
    ) Self {
        return .{
            .allocator = allocator,
            .surfaces = surfaces,
            .damage_tracker = damage.DamageTracker.init(allocator),
            .scheduler = frame_scheduler.FrameScheduler.init(60),
            .output = null,
            .composing = false,
            .total_composites = 0,
            .total_surfaces_composed = 0,
        };
    }

    pub fn deinit(self: *Self) void {
        if (self.output) |*out| {
            out.be.deinit();
        }
        self.damage_tracker.deinit();
    }

    /// Initialize output with given configuration
    pub fn initOutput(self: *Self, id: u32, config: OutputConfig) !void {
        // Create backend
        var be = try backend_mod.createBackend(self.allocator, config.backend_type);
        errdefer be.deinit();

        // Initialize framebuffer
        try be.initFramebuffer(.{
            .width = config.width,
            .height = config.height,
            .format = config.format,
        });

        self.output = .{
            .id = id,
            .config = config,
            .be = be,
            .last_frame = 0,
        };

        self.scheduler.setTargetHz(config.refresh_hz);
        self.damage_tracker.markFullRepaint();
    }

    /// Start composition loop
    pub fn start(self: *Self) void {
        self.scheduler.start();
        self.composing = true;
    }

    /// Stop composition loop
    pub fn stop(self: *Self) void {
        self.composing = false;
        self.scheduler.stop();
    }

    /// Check if composition is needed
    pub fn needsComposite(self: *Self) bool {
        if (!self.composing) return false;
        if (self.output == null) return false;

        const has_damage = self.damage_tracker.hasDamage();
        const should_composite = self.scheduler.shouldComposite();
        if (has_damage and should_composite) {
            log.debug("needsComposite: damage={} scheduler={}", .{ has_damage, should_composite });
        }
        return has_damage and should_composite;
    }

    /// Perform composition
    pub fn composite(self: *Self) !CompositeResult {
        const output = &(self.output orelse return error.NoOutput);

        var frame = self.scheduler.beginFrame();
        defer frame.end();

        self.damage_tracker.beginFrame();

        // Lock surfaces during composition to prevent use-after-free
        self.surfaces.beginComposition();
        defer self.surfaces.endComposition();

        // Get surfaces in composition order
        const composition_order = try self.surfaces.getCompositionOrder();

        log.debug("composite: {} surfaces in composition order, full_repaint={}", .{
            composition_order.len,
            self.damage_tracker.needs_full_repaint,
        });

        var surfaces_rendered: u32 = 0;
        var total_render_time: u64 = 0;

        // Clear with background color if full repaint
        const clear_color: ?[4]f32 = if (self.damage_tracker.needs_full_repaint)
            output.config.background_color
        else
            null;

        // Render each visible surface
        for (composition_order) |surface| {
            if (!surface.visible) {
                log.debug("  surface {}: skipped (not visible)", .{surface.id});
                continue;
            }

            // Check if surface has damage
            const surface_damaged = self.damage_tracker.needs_full_repaint or
                (self.damage_tracker.getSurfaceDamage(surface.id) != null and
                self.damage_tracker.getSurfaceDamage(surface.id).?.hasDamage());

            if (!surface_damaged) {
                log.debug("  surface {}: skipped (no damage)", .{surface.id});
                continue;
            }

            // Get SDCS data from attached buffer
            const sdcs_data = if (surface.buffer) |*buf| buf.map() catch |err| blk: {
                log.warn("  surface {}: buffer map failed: {}", .{ surface.id, err });
                break :blk null;
            } else blk: {
                log.debug("  surface {}: no buffer attached", .{surface.id});
                break :blk null;
            };
            if (sdcs_data == null) continue;

            log.debug("  surface {}: rendering {} bytes SDCS data", .{ surface.id, sdcs_data.?.len });

            // Render surface at its position
            const result = try output.be.render(.{
                .surface_id = surface.id,
                .sdcs_data = sdcs_data.?,
                .framebuffer = .{
                    .width = output.config.width,
                    .height = output.config.height,
                    .format = output.config.format,
                },
                .clear_color = if (surfaces_rendered == 0) clear_color else null,
                .offset_x = @intFromFloat(surface.position_x),
                .offset_y = @intFromFloat(surface.position_y),
            });

            if (result.error_msg == null) {
                surfaces_rendered += 1;
                total_render_time += result.render_time_ns;
                self.damage_tracker.clearSurfaceDamage(surface.id);
                log.debug("  surface {}: rendered successfully in {}ns", .{ surface.id, result.render_time_ns });
            } else {
                log.warn("  surface {}: render failed: {s}", .{ surface.id, result.error_msg.? });
            }
        }

        // Clear global damage
        self.damage_tracker.clearAll();

        self.total_composites += 1;
        self.total_surfaces_composed += surfaces_rendered;
        output.last_frame = frame.frame_number;

        return .{
            .frame_number = frame.frame_number,
            .surfaces_rendered = surfaces_rendered,
            .total_render_time_ns = total_render_time,
            .frame_time_ns = frame.getElapsed(),
        };
    }

    /// Mark surface as damaged (full surface)
    pub fn damageSurface(self: *Self, surface_id: u32) !void {
        try self.damage_tracker.markSurfaceFullDamage(surface_id);
    }

    /// Mark rectangular region as damaged
    pub fn damageRegion(self: *Self, surface_id: u32, rect: damage.Rect) !void {
        try self.damage_tracker.addSurfaceDamage(surface_id, rect);
    }

    /// Mark entire output as needing repaint
    pub fn damageAll(self: *Self) void {
        self.damage_tracker.markFullRepaint();
    }

    /// Handle surface creation
    pub fn onSurfaceCreated(self: *Self, surface_id: u32) !void {
        try self.damage_tracker.markSurfaceFullDamage(surface_id);
    }

    /// Handle surface destruction
    pub fn onSurfaceDestroyed(self: *Self, surface_id: u32) void {
        self.damage_tracker.removeSurface(surface_id);
        // Damage the area where surface was (would need position tracking)
        self.damage_tracker.markFullRepaint();
    }

    /// Handle surface commit
    pub fn onSurfaceCommit(self: *Self, surface_id: u32) !void {
        // Full surface damage on commit (could be optimized with explicit damage)
        try self.damage_tracker.markSurfaceFullDamage(surface_id);
    }

    /// Get output framebuffer pixels
    pub fn getPixels(self: *Self) ?[]u8 {
        if (self.output) |*out| {
            return out.be.getPixels();
        }
        return null;
    }

    /// Get frame scheduler statistics
    pub fn getStats(self: *const Self) CompositorStats {
        return .{
            .frame_stats = self.scheduler.getStats(),
            .total_composites = self.total_composites,
            .total_surfaces_composed = self.total_surfaces_composed,
            .damage_regions = @intCast(self.damage_tracker.output_damage.items.len),
        };
    }

    /// Wait for next vsync deadline
    pub fn waitForVsync(self: *Self) void {
        self.scheduler.waitForDeadline();
    }

    /// Get time until next vsync
    pub fn getTimeUntilVsync(self: *const Self) i64 {
        return self.scheduler.getTimeUntilDeadline();
    }

    /// Poll backend for events (keyboard, window close, etc.)
    /// Returns false if backend should stop (e.g., X11 window closed)
    pub fn pollEvents(self: *Self) bool {
        if (self.output) |*out| {
            return out.be.pollEvents();
        }
        return true;
    }

    /// Get pending key events from backend
    pub fn getKeyEvents(self: *Self) []const backend_mod.KeyEvent {
        if (self.output) |*out| {
            return out.be.getKeyEvents();
        }
        return &[_]backend_mod.KeyEvent{};
    }

    /// Get pending mouse events from backend
    pub fn getMouseEvents(self: *Self) []const backend_mod.MouseEvent {
        if (self.output) |*out| {
            return out.be.getMouseEvents();
        }
        return &[_]backend_mod.MouseEvent{};
    }
};

/// Result of a composite operation
pub const CompositeResult = struct {
    frame_number: u64,
    surfaces_rendered: u32,
    total_render_time_ns: u64,
    frame_time_ns: u64,
};

/// Compositor statistics
pub const CompositorStats = struct {
    frame_stats: frame_scheduler.FrameStats,
    total_composites: u64,
    total_surfaces_composed: u64,
    damage_regions: u32,
};

// ============================================================================
// Tests
// ============================================================================

test "Compositor init" {
    var surfaces = surface_registry.SurfaceRegistry.init(std.testing.allocator);
    defer surfaces.deinit();

    var comp = Compositor.init(std.testing.allocator, &surfaces);
    defer comp.deinit();

    try std.testing.expect(!comp.composing);
    try std.testing.expect(comp.output == null);
}

test "Compositor output init" {
    var surfaces = surface_registry.SurfaceRegistry.init(std.testing.allocator);
    defer surfaces.deinit();

    var comp = Compositor.init(std.testing.allocator, &surfaces);
    defer comp.deinit();

    try comp.initOutput(0, .{
        .width = 800,
        .height = 600,
        .format = .rgba8,
        .refresh_hz = 60,
    });

    try std.testing.expect(comp.output != null);
    try std.testing.expectEqual(@as(u32, 800), comp.output.?.config.width);
}

test "Compositor damage tracking" {
    var surfaces = surface_registry.SurfaceRegistry.init(std.testing.allocator);
    defer surfaces.deinit();

    var comp = Compositor.init(std.testing.allocator, &surfaces);
    defer comp.deinit();

    // Initial state has full repaint
    try std.testing.expect(comp.damage_tracker.hasDamage());

    comp.damage_tracker.clearAll();
    try std.testing.expect(!comp.damage_tracker.hasDamage());

    try comp.damageSurface(1);
    try std.testing.expect(comp.damage_tracker.hasDamage());
}
