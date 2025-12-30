const std = @import("std");
const posix = std.posix;
const backend = @import("backend");

const log = std.log.scoped(.bsd_input);

// ============================================================================
// FreeBSD input support (sysmouse + console keyboard)
// ============================================================================

/// Maximum number of input devices to track
pub const MAX_INPUT_DEVICES = 4;

/// Input device types
pub const InputDeviceType = enum {
    keyboard,
    mouse,
    unknown,
};

/// BSD input handler - manages keyboard and mouse input on FreeBSD
pub const BsdInput = struct {
    allocator: std.mem.Allocator,

    // Input device file descriptors
    mouse_fd: posix.fd_t,
    kbd_fd: posix.fd_t,

    // Mouse state
    mouse_x: i32,
    mouse_y: i32,
    mouse_buttons: u8, // Bit flags: 0=left, 1=middle, 2=right
    screen_width: u32,
    screen_height: u32,

    // Modifier key state
    modifiers: u8, // Bit flags: 0=shift, 1=alt, 2=ctrl, 3=meta

    // Event queues
    key_events: [backend.MAX_KEY_EVENTS]backend.KeyEvent,
    key_event_count: usize,
    mouse_events: [backend.MAX_MOUSE_EVENTS]backend.MouseEvent,
    mouse_event_count: usize,

    // Sysmouse packet buffer
    mouse_buf: [5]u8,
    mouse_buf_len: usize,

    const Self = @This();

    /// Sysmouse button masks (active low in protocol, we invert)
    const MOUSE_LEFT: u8 = 0x01;
    const MOUSE_MIDDLE: u8 = 0x02;
    const MOUSE_RIGHT: u8 = 0x04;

    /// Initialize BSD input handler
    pub fn init(allocator: std.mem.Allocator, screen_width: u32, screen_height: u32) !*Self {
        const self = try allocator.create(Self);
        errdefer allocator.destroy(self);

        self.* = .{
            .allocator = allocator,
            .mouse_fd = -1,
            .kbd_fd = -1,
            .mouse_x = @intCast(screen_width / 2),
            .mouse_y = @intCast(screen_height / 2),
            .mouse_buttons = 0,
            .screen_width = screen_width,
            .screen_height = screen_height,
            .modifiers = 0,
            .key_events = undefined,
            .key_event_count = 0,
            .mouse_events = undefined,
            .mouse_event_count = 0,
            .mouse_buf = undefined,
            .mouse_buf_len = 0,
        };

        // Open sysmouse for mouse input
        self.mouse_fd = posix.open("/dev/sysmouse", .{ .ACCMODE = .RDONLY, .NONBLOCK = true }, 0) catch |err| blk: {
            log.warn("failed to open /dev/sysmouse: {} (is moused running?)", .{err});
            break :blk -1;
        };

        if (self.mouse_fd >= 0) {
            log.info("opened /dev/sysmouse for mouse input", .{});
        }

        // Try to open keyboard device
        // FreeBSD provides several options: kbdmux0, ukbd0, atkbd0
        const kbd_paths = [_][:0]const u8{
            "/dev/kbdmux0",
            "/dev/ukbd0",
            "/dev/atkbd0",
        };

        for (kbd_paths) |path| {
            self.kbd_fd = posix.open(path, .{ .ACCMODE = .RDONLY, .NONBLOCK = true }, 0) catch continue;
            log.info("opened {s} for keyboard input", .{path});
            break;
        }

        if (self.kbd_fd < 0) {
            log.warn("no keyboard device found - keyboard input disabled", .{});
        }

        if (self.mouse_fd < 0 and self.kbd_fd < 0) {
            log.warn("no input devices available on FreeBSD", .{});
            log.warn("for mouse: ensure moused is running (service moused start)", .{});
            log.warn("for keyboard: ensure running as root or in operator group", .{});
        }

        return self;
    }

    /// Cleanup and close all input devices
    pub fn deinit(self: *Self) void {
        if (self.mouse_fd >= 0) {
            posix.close(self.mouse_fd);
        }
        if (self.kbd_fd >= 0) {
            posix.close(self.kbd_fd);
        }
        self.allocator.destroy(self);
    }

    /// Update screen dimensions (for mouse clamping)
    pub fn setScreenSize(self: *Self, width: u32, height: u32) void {
        self.screen_width = width;
        self.screen_height = height;
        self.mouse_x = @max(0, @min(self.mouse_x, @as(i32, @intCast(width)) - 1));
        self.mouse_y = @max(0, @min(self.mouse_y, @as(i32, @intCast(height)) - 1));
    }

    /// Poll for input events and fill event queues
    pub fn poll(self: *Self) bool {
        self.key_event_count = 0;
        self.mouse_event_count = 0;

        self.pollMouse();
        self.pollKeyboard();

        return true;
    }

    /// Poll sysmouse for mouse events
    fn pollMouse(self: *Self) void {
        if (self.mouse_fd < 0) return;

        var buf: [64]u8 = undefined;
        while (true) {
            const n = posix.read(self.mouse_fd, &buf) catch break;
            if (n == 0) break;

            // Process bytes through packet state machine
            for (buf[0..n]) |byte| {
                self.processSysmouseByte(byte);
            }
        }
    }

    /// Process a single byte from sysmouse (MouseSystems protocol)
    /// Packet format: 5 bytes
    ///   Byte 0: 0x80 | button_status (buttons are active LOW)
    ///   Byte 1: X delta (signed)
    ///   Byte 2: Y delta (signed)
    ///   Byte 3: X delta continued
    ///   Byte 4: Y delta continued
    fn processSysmouseByte(self: *Self, byte: u8) void {
        // Check for packet start (bit 7 set, bits 0-2 are inverted button state)
        if (self.mouse_buf_len == 0) {
            if ((byte & 0xF8) == 0x80) {
                self.mouse_buf[0] = byte;
                self.mouse_buf_len = 1;
            }
            return;
        }

        self.mouse_buf[self.mouse_buf_len] = byte;
        self.mouse_buf_len += 1;

        // Complete packet?
        if (self.mouse_buf_len >= 5) {
            self.processMousePacket();
            self.mouse_buf_len = 0;
        }
    }

    /// Process a complete 5-byte sysmouse packet
    fn processMousePacket(self: *Self) void {
        const status = self.mouse_buf[0];
        const dx1: i32 = @as(i32, @as(i8, @bitCast(self.mouse_buf[1])));
        const dy1: i32 = @as(i32, @as(i8, @bitCast(self.mouse_buf[2])));
        const dx2: i32 = @as(i32, @as(i8, @bitCast(self.mouse_buf[3])));
        const dy2: i32 = @as(i32, @as(i8, @bitCast(self.mouse_buf[4])));

        const dx = dx1 + dx2;
        const dy = dy1 + dy2;

        // Update mouse position with clamping
        self.mouse_x = @max(0, @min(self.mouse_x + dx, @as(i32, @intCast(self.screen_width)) - 1));
        self.mouse_y = @max(0, @min(self.mouse_y - dy, @as(i32, @intCast(self.screen_height)) - 1)); // Y is inverted

        // Decode buttons (active LOW in protocol - bit set means NOT pressed)
        const new_buttons: u8 = (~status) & 0x07;

        // Check for button changes
        const changed = self.mouse_buttons ^ new_buttons;

        if (changed != 0) {
            // Left button
            if (changed & MOUSE_LEFT != 0) {
                self.queueMouseEvent(.left, if (new_buttons & MOUSE_LEFT != 0) .press else .release);
            }
            // Middle button
            if (changed & MOUSE_MIDDLE != 0) {
                self.queueMouseEvent(.middle, if (new_buttons & MOUSE_MIDDLE != 0) .press else .release);
            }
            // Right button
            if (changed & MOUSE_RIGHT != 0) {
                self.queueMouseEvent(.right, if (new_buttons & MOUSE_RIGHT != 0) .press else .release);
            }

            self.mouse_buttons = new_buttons;
        }

        // Queue motion event if we moved
        if (dx != 0 or dy != 0) {
            self.queueMouseEvent(.left, .motion);
        }
    }

    /// Queue a mouse event
    fn queueMouseEvent(self: *Self, button: backend.MouseButton, event_type: backend.MouseEventType) void {
        if (self.mouse_event_count >= backend.MAX_MOUSE_EVENTS) return;

        self.mouse_events[self.mouse_event_count] = .{
            .x = self.mouse_x,
            .y = self.mouse_y,
            .button = button,
            .event_type = event_type,
            .modifiers = self.modifiers,
        };
        self.mouse_event_count += 1;
    }

    /// Poll keyboard for key events
    fn pollKeyboard(self: *Self) void {
        if (self.kbd_fd < 0) return;

        var buf: [64]u8 = undefined;
        while (true) {
            const n = posix.read(self.kbd_fd, &buf) catch break;
            if (n == 0) break;

            // Process scancodes
            for (buf[0..n]) |scancode| {
                self.processScancode(scancode);
            }
        }
    }

    /// Process AT keyboard scancode
    fn processScancode(self: *Self, scancode: u8) void {
        // AT scancodes: bit 7 set = key release
        const pressed = (scancode & 0x80) == 0;
        const code: u32 = scancode & 0x7F;

        // Update modifier state
        self.updateModifiers(code, pressed);

        // Queue key event
        if (self.key_event_count >= backend.MAX_KEY_EVENTS) return;

        self.key_events[self.key_event_count] = .{
            .key_code = code,
            .modifiers = self.modifiers,
            .pressed = pressed,
        };
        self.key_event_count += 1;
    }

    /// Update modifier key state
    fn updateModifiers(self: *Self, code: u32, pressed: bool) void {
        const shift_mask: u8 = 0x01;
        const alt_mask: u8 = 0x02;
        const ctrl_mask: u8 = 0x04;

        // AT scancode values for modifiers
        const LSHIFT: u32 = 0x2A;
        const RSHIFT: u32 = 0x36;
        const LCTRL: u32 = 0x1D;
        const LALT: u32 = 0x38;

        switch (code) {
            LSHIFT, RSHIFT => {
                if (pressed) self.modifiers |= shift_mask else self.modifiers &= ~shift_mask;
            },
            LCTRL => {
                if (pressed) self.modifiers |= ctrl_mask else self.modifiers &= ~ctrl_mask;
            },
            LALT => {
                if (pressed) self.modifiers |= alt_mask else self.modifiers &= ~alt_mask;
            },
            else => {},
        }
    }

    /// Get queued key events (clears queue)
    pub fn getKeyEvents(self: *Self) []const backend.KeyEvent {
        const count = self.key_event_count;
        self.key_event_count = 0;
        return self.key_events[0..count];
    }

    /// Get queued mouse events (clears queue)
    pub fn getMouseEvents(self: *Self) []const backend.MouseEvent {
        const count = self.mouse_event_count;
        self.mouse_event_count = 0;
        return self.mouse_events[0..count];
    }
};
