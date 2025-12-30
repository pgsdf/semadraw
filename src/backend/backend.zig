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
    /// Surface position offset in pixels (where to render in framebuffer)
    offset_x: i32 = 0,
    offset_y: i32 = 0,
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

/// Key event from backend (keyboard input)
pub const KeyEvent = struct {
    /// Key code (evdev code on Linux)
    key_code: u32,
    /// Modifier state: bit 0=shift, bit 1=alt, bit 2=ctrl, bit 3=meta
    modifiers: u8,
    /// True if key pressed, false if released
    pressed: bool,
};

/// Maximum number of key events that can be queued
pub const MAX_KEY_EVENTS = 32;

/// Mouse button identifiers
pub const MouseButton = enum(u8) {
    left = 0,
    middle = 1,
    right = 2,
    scroll_up = 3,
    scroll_down = 4,
    scroll_left = 5,
    scroll_right = 6,
    button4 = 7,
    button5 = 8,
};

/// Mouse event type
pub const MouseEventType = enum(u8) {
    press = 0,
    release = 1,
    motion = 2,
};

/// Mouse event from backend
pub const MouseEvent = struct {
    /// X coordinate in pixels
    x: i32,
    /// Y coordinate in pixels
    y: i32,
    /// Button involved (for press/release)
    button: MouseButton,
    /// Event type
    event_type: MouseEventType,
    /// Modifier state: bit 0=shift, bit 1=alt, bit 2=ctrl, bit 3=meta
    modifiers: u8,
};

/// Maximum number of mouse events that can be queued
pub const MAX_MOUSE_EVENTS = 64;

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
        /// Process pending events (keyboard, window, etc.)
        /// Returns false if backend should stop (e.g., window closed)
        pollEvents: *const fn (ctx: *anyopaque) bool,
        /// Get pending key events (empties the queue)
        /// Returns slice of events, caller should not free
        getKeyEvents: ?*const fn (ctx: *anyopaque) []const KeyEvent = null,
        /// Get pending mouse events (empties the queue)
        /// Returns slice of events, caller should not free
        getMouseEvents: ?*const fn (ctx: *anyopaque) []const MouseEvent = null,
        /// Set clipboard content (selection: 0=CLIPBOARD, 1=PRIMARY)
        setClipboard: ?*const fn (ctx: *anyopaque, selection: u8, text: []const u8) anyerror!void = null,
        /// Request clipboard content (async - data available after pollEvents)
        requestClipboard: ?*const fn (ctx: *anyopaque, selection: u8) void = null,
        /// Get clipboard data (returns null if not available or not supported)
        getClipboardData: ?*const fn (ctx: *anyopaque, selection: u8) ?[]const u8 = null,
        /// Check if clipboard request is pending
        isClipboardPending: ?*const fn (ctx: *anyopaque) bool = null,
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

    /// Process pending events (keyboard, window, etc.)
    /// Returns false if backend should stop (e.g., window closed)
    pub fn pollEvents(self: Backend) bool {
        return self.vtable.pollEvents(self.ptr);
    }

    /// Get pending key events (empties the queue)
    /// Returns empty slice if backend doesn't support keyboard input
    pub fn getKeyEvents(self: Backend) []const KeyEvent {
        if (self.vtable.getKeyEvents) |func| {
            return func(self.ptr);
        }
        return &[_]KeyEvent{};
    }

    /// Get pending mouse events (empties the queue)
    /// Returns empty slice if backend doesn't support mouse input
    pub fn getMouseEvents(self: Backend) []const MouseEvent {
        if (self.vtable.getMouseEvents) |func| {
            return func(self.ptr);
        }
        return &[_]MouseEvent{};
    }

    /// Set clipboard content (selection: 0=CLIPBOARD, 1=PRIMARY)
    pub fn setClipboard(self: Backend, selection: u8, text: []const u8) !void {
        if (self.vtable.setClipboard) |func| {
            return func(self.ptr, selection, text);
        }
        return error.ClipboardNotSupported;
    }

    /// Request clipboard content (async - data available after pollEvents)
    pub fn requestClipboard(self: Backend, selection: u8) void {
        if (self.vtable.requestClipboard) |func| {
            func(self.ptr, selection);
        }
    }

    /// Get clipboard data (returns null if not available or not supported)
    pub fn getClipboardData(self: Backend, selection: u8) ?[]const u8 {
        if (self.vtable.getClipboardData) |func| {
            return func(self.ptr, selection);
        }
        return null;
    }

    /// Check if clipboard request is pending
    pub fn isClipboardPending(self: Backend) bool {
        if (self.vtable.isClipboardPending) |func| {
            return func(self.ptr);
        }
        return false;
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
    /// Vulkan GPU renderer (X11 presentation)
    vulkan = 2,
    /// KMS/DRM direct output
    kms = 3,
    /// X11 windowed output
    x11 = 4,
    /// Wayland windowed output
    wayland = 5,
    /// Vulkan console backend (VK_KHR_display, no X11/Wayland)
    vulkan_console = 6,
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
        .x11 => {
            const x11 = @import("x11");
            return x11.create(allocator);
        },
        .vulkan => {
            const vulkan = @import("vulkan");
            return vulkan.create(allocator);
        },
        .wayland => {
            const wayland = @import("wayland");
            return wayland.create(allocator);
        },
        .vulkan_console => {
            const vulkan_console = @import("vulkan_console");
            return vulkan_console.create(allocator);
        },
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
