const std = @import("std");

/// Backend capabilities reported during initialization
pub const Capabilities = struct {
    /// Backend name for logging/debugging
    name: []const u8,
    /// Maximum supported framebuffer width
    max_width: u32,
    /// Maximum supported framebuffer height
    max_height: u32,
    /// Supports anti-aliasing
    supports_aa: bool,
    /// Supports GPU acceleration
    hardware_accelerated: bool,
    /// Can output to display directly
    can_present: bool,
};

/// Framebuffer pixel format
pub const PixelFormat = enum(u8) {
    /// 8-bit RGBA (4 bytes per pixel)
    rgba8 = 0,
    /// 8-bit BGRA (4 bytes per pixel)
    bgra8 = 1,
    /// 8-bit RGB (3 bytes per pixel, no alpha)
    rgb8 = 2,
};

/// Framebuffer configuration
pub const FramebufferConfig = struct {
    width: u32,
    height: u32,
    format: PixelFormat = .rgba8,
    /// Scale factor for HiDPI (1.0 = no scaling)
    scale: f32 = 1.0,
};

/// Render request sent to backend
pub const RenderRequest = struct {
    /// Surface ID being rendered
    surface_id: u32,
    /// SDCS command data
    sdcs_data: []const u8,
    /// Destination framebuffer config
    framebuffer: FramebufferConfig,
    /// Clear color before rendering (null = don't clear)
    clear_color: ?[4]f32 = null,
};

/// Render result returned from backend
pub const RenderResult = struct {
    /// Surface ID that was rendered
    surface_id: u32,
    /// Frame number
    frame_number: u64,
    /// Render time in nanoseconds
    render_time_ns: u64,
    /// Error message if failed (null = success)
    error_msg: ?[]const u8 = null,

    pub fn success(surface_id: u32, frame: u64, time_ns: u64) RenderResult {
        return .{
            .surface_id = surface_id,
            .frame_number = frame,
            .render_time_ns = time_ns,
        };
    }

    pub fn failure(surface_id: u32, msg: []const u8) RenderResult {
        return .{
            .surface_id = surface_id,
            .frame_number = 0,
            .render_time_ns = 0,
            .error_msg = msg,
        };
    }
};

/// Backend interface - all backends must implement this
pub const Backend = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        /// Get backend capabilities
        getCapabilities: *const fn (ctx: *anyopaque) Capabilities,
        /// Initialize framebuffer with given config
        initFramebuffer: *const fn (ctx: *anyopaque, config: FramebufferConfig) anyerror!void,
        /// Render SDCS commands to framebuffer
        render: *const fn (ctx: *anyopaque, request: RenderRequest) anyerror!RenderResult,
        /// Get pointer to framebuffer pixels (for composition/output)
        getPixels: *const fn (ctx: *anyopaque) ?[]u8,
        /// Resize framebuffer
        resize: *const fn (ctx: *anyopaque, width: u32, height: u32) anyerror!void,
        /// Cleanup and free resources
        deinit: *const fn (ctx: *anyopaque) void,
    };

    pub fn getCapabilities(self: Backend) Capabilities {
        return self.vtable.getCapabilities(self.ptr);
    }

    pub fn initFramebuffer(self: Backend, config: FramebufferConfig) !void {
        return self.vtable.initFramebuffer(self.ptr, config);
    }

    pub fn render(self: Backend, request: RenderRequest) !RenderResult {
        return self.vtable.render(self.ptr, request);
    }

    pub fn getPixels(self: Backend) ?[]u8 {
        return self.vtable.getPixels(self.ptr);
    }

    pub fn resize(self: Backend, width: u32, height: u32) !void {
        return self.vtable.resize(self.ptr, width, height);
    }

    pub fn deinit(self: Backend) void {
        self.vtable.deinit(self.ptr);
    }
};

/// Backend type enumeration
pub const BackendType = enum(u8) {
    /// Software renderer (CPU-based)
    software = 0,
    /// Headless (no output, for testing)
    headless = 1,
    /// Vulkan GPU renderer (future)
    vulkan = 2,
    /// KMS/DRM direct output (future)
    kms = 3,
};

/// Create a backend of the specified type
pub fn createBackend(allocator: std.mem.Allocator, backend_type: BackendType) !Backend {
    switch (backend_type) {
        .software => {
            const software = @import("software");
            return software.create(allocator);
        },
        .headless => {
            // Headless is just software without display
            const software = @import("software");
            return software.create(allocator);
        },
        .kms => {
            const drm = @import("drm");
            return drm.create(allocator);
        },
        else => return error.NotSupported,
    }
}

// ============================================================================
// Tests
// ============================================================================

test "RenderResult success" {
    const result = RenderResult.success(1, 100, 1000000);
    try std.testing.expectEqual(@as(u32, 1), result.surface_id);
    try std.testing.expectEqual(@as(u64, 100), result.frame_number);
    try std.testing.expectEqual(@as(?[]const u8, null), result.error_msg);
}

test "RenderResult failure" {
    const result = RenderResult.failure(2, "test error");
    try std.testing.expectEqual(@as(u32, 2), result.surface_id);
    try std.testing.expect(result.error_msg != null);
}
