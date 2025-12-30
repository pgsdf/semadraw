const std = @import("std");
const posix = std.posix;
const backend = @import("backend");

const log = std.log.scoped(.bsd_input);

// Link libc for ioctl
const c = @cImport({
    @cInclude("sys/ioctl.h");
    @cInclude("termios.h");
});

// ============================================================================
// FreeBSD input support (sysmouse + console keyboard via /dev/tty)
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
    tty_fd: posix.fd_t,

    // Original terminal settings (for restoration)
    orig_termios: ?c.struct_termios,

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

    // Escape sequence buffer for keyboard
    esc_buf: [16]u8,
    esc_buf_len: usize,
    esc_timeout: i64, // Timestamp when escape started

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
            .tty_fd = -1,
            .orig_termios = null,
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
            .esc_buf = undefined,
            .esc_buf_len = 0,
            .esc_timeout = 0,
        };

        // Open sysmouse for mouse input
        self.mouse_fd = posix.open("/dev/sysmouse", .{ .ACCMODE = .RDONLY, .NONBLOCK = true }, 0) catch |err| blk: {
            log.warn("failed to open /dev/sysmouse: {} (is moused running?)", .{err});
            break :blk -1;
        };

        if (self.mouse_fd >= 0) {
            log.info("opened /dev/sysmouse for mouse input", .{});
        }

        // Open /dev/tty for keyboard input (the controlling terminal)
        self.tty_fd = posix.open("/dev/tty", .{ .ACCMODE = .RDONLY, .NONBLOCK = true }, 0) catch |err| blk: {
            log.warn("failed to open /dev/tty: {}", .{err});
            break :blk -1;
        };

        if (self.tty_fd >= 0) {
            // Save original termios and set raw mode
            if (self.setRawMode()) {
                log.info("opened /dev/tty for keyboard input (raw mode)", .{});
            } else {
                log.warn("failed to set raw mode on /dev/tty", .{});
            }
        }

        if (self.mouse_fd < 0 and self.tty_fd < 0) {
            log.warn("no input devices available on FreeBSD", .{});
            log.warn("for mouse: ensure moused is running (service moused start)", .{});
        }

        return self;
    }

    /// Set terminal to raw mode for keyboard input
    fn setRawMode(self: *Self) bool {
        if (self.tty_fd < 0) return false;

        var t: c.struct_termios = undefined;

        // Get current settings using tcgetattr
        if (c.tcgetattr(self.tty_fd, &t) < 0) return false;

        // Save original settings
        self.orig_termios = t;

        // Modify for raw mode - disable canonical mode, echo, signals
        t.c_lflag &= ~@as(c_uint, c.ICANON | c.ECHO | c.ISIG | c.IEXTEN);
        t.c_cc[c.VMIN] = 0; // Non-blocking
        t.c_cc[c.VTIME] = 0;

        // Apply new settings
        return c.tcsetattr(self.tty_fd, c.TCSANOW, &t) >= 0;
    }

    /// Restore original terminal mode
    fn restoreMode(self: *Self) void {
        if (self.tty_fd >= 0 and self.orig_termios != null) {
            _ = c.tcsetattr(self.tty_fd, c.TCSANOW, &self.orig_termios.?);
        }
    }

    /// Cleanup and close all input devices
    pub fn deinit(self: *Self) void {
        // Restore terminal mode before closing
        self.restoreMode();

        if (self.mouse_fd >= 0) {
            posix.close(self.mouse_fd);
        }
        if (self.tty_fd >= 0) {
            posix.close(self.tty_fd);
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
    fn processSysmouseByte(self: *Self, byte: u8) void {
        if (self.mouse_buf_len == 0) {
            if ((byte & 0xF8) == 0x80) {
                self.mouse_buf[0] = byte;
                self.mouse_buf_len = 1;
            }
            return;
        }

        self.mouse_buf[self.mouse_buf_len] = byte;
        self.mouse_buf_len += 1;

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

        self.mouse_x = @max(0, @min(self.mouse_x + dx, @as(i32, @intCast(self.screen_width)) - 1));
        self.mouse_y = @max(0, @min(self.mouse_y - dy, @as(i32, @intCast(self.screen_height)) - 1));

        const new_buttons: u8 = (~status) & 0x07;
        const changed = self.mouse_buttons ^ new_buttons;

        if (changed != 0) {
            if (changed & MOUSE_LEFT != 0) {
                self.queueMouseEvent(.left, if (new_buttons & MOUSE_LEFT != 0) .press else .release);
            }
            if (changed & MOUSE_MIDDLE != 0) {
                self.queueMouseEvent(.middle, if (new_buttons & MOUSE_MIDDLE != 0) .press else .release);
            }
            if (changed & MOUSE_RIGHT != 0) {
                self.queueMouseEvent(.right, if (new_buttons & MOUSE_RIGHT != 0) .press else .release);
            }
            self.mouse_buttons = new_buttons;
        }

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

    /// Poll keyboard for key events (from /dev/tty in raw mode)
    fn pollKeyboard(self: *Self) void {
        if (self.tty_fd < 0) return;

        var buf: [64]u8 = undefined;
        while (true) {
            const n = posix.read(self.tty_fd, &buf) catch break;
            if (n == 0) break;

            for (buf[0..n]) |byte| {
                self.processKeyByte(byte);
            }
        }

        // Check for escape sequence timeout
        self.checkEscapeTimeout();
    }

    /// Process a byte from keyboard input
    fn processKeyByte(self: *Self, byte: u8) void {
        const now = std.time.milliTimestamp();

        // Handle escape sequences
        if (self.esc_buf_len > 0) {
            // Check for timeout (50ms)
            if (now - self.esc_timeout > 50) {
                // Timeout - emit escape and reset
                self.queueKeyEvent(27, true); // ESC key
                self.esc_buf_len = 0;
            }
        }

        if (byte == 0x1B) { // ESC
            if (self.esc_buf_len == 0) {
                self.esc_buf[0] = byte;
                self.esc_buf_len = 1;
                self.esc_timeout = now;
                return;
            }
        }

        if (self.esc_buf_len > 0) {
            if (self.esc_buf_len < self.esc_buf.len) {
                self.esc_buf[self.esc_buf_len] = byte;
                self.esc_buf_len += 1;
            }

            // Try to parse escape sequence
            if (self.parseEscapeSequence()) {
                self.esc_buf_len = 0;
            }
            return;
        }

        // Regular key - convert to key code and queue
        const key_code = self.byteToKeyCode(byte);
        self.queueKeyEvent(key_code, true);
    }

    /// Check for escape sequence timeout
    fn checkEscapeTimeout(self: *Self) void {
        if (self.esc_buf_len > 0) {
            const now = std.time.milliTimestamp();
            if (now - self.esc_timeout > 50) {
                // Timeout - emit escape and clear buffer
                if (self.esc_buf_len == 1) {
                    self.queueKeyEvent(1, true); // ESC key code
                }
                self.esc_buf_len = 0;
            }
        }
    }

    /// Parse ANSI escape sequences and emit key events
    fn parseEscapeSequence(self: *Self) bool {
        if (self.esc_buf_len < 2) return false;

        // CSI sequences: ESC [
        if (self.esc_buf[1] == '[') {
            if (self.esc_buf_len < 3) return false;

            const final_byte = self.esc_buf[self.esc_buf_len - 1];

            // Arrow keys: ESC [ A/B/C/D
            switch (final_byte) {
                'A' => { self.queueKeyEvent(103, true); return true; }, // Up
                'B' => { self.queueKeyEvent(108, true); return true; }, // Down
                'C' => { self.queueKeyEvent(106, true); return true; }, // Right
                'D' => { self.queueKeyEvent(105, true); return true; }, // Left
                'H' => { self.queueKeyEvent(102, true); return true; }, // Home
                'F' => { self.queueKeyEvent(107, true); return true; }, // End
                '~' => {
                    // Extended keys: ESC [ n ~
                    if (self.esc_buf_len >= 4) {
                        const num = self.esc_buf[2];
                        switch (num) {
                            '1' => { self.queueKeyEvent(102, true); return true; }, // Home
                            '2' => { self.queueKeyEvent(110, true); return true; }, // Insert
                            '3' => { self.queueKeyEvent(111, true); return true; }, // Delete
                            '4' => { self.queueKeyEvent(107, true); return true; }, // End
                            '5' => { self.queueKeyEvent(104, true); return true; }, // PgUp
                            '6' => { self.queueKeyEvent(109, true); return true; }, // PgDn
                            else => {},
                        }
                    }
                    return true;
                },
                else => {},
            }

            // If we have a complete-ish sequence, consume it
            if (final_byte >= 0x40 and final_byte <= 0x7E) {
                return true;
            }

            return false;
        }

        // SS3 sequences: ESC O (for F1-F4 on some terminals)
        if (self.esc_buf[1] == 'O') {
            if (self.esc_buf_len < 3) return false;

            switch (self.esc_buf[2]) {
                'P' => { self.queueKeyEvent(59, true); return true; }, // F1
                'Q' => { self.queueKeyEvent(60, true); return true; }, // F2
                'R' => { self.queueKeyEvent(61, true); return true; }, // F3
                'S' => { self.queueKeyEvent(62, true); return true; }, // F4
                else => return true,
            }
        }

        // Alt+key: ESC followed by printable char
        if (self.esc_buf_len == 2 and self.esc_buf[1] >= 0x20) {
            self.modifiers |= 0x02; // Alt
            const key_code = self.byteToKeyCode(self.esc_buf[1]);
            self.queueKeyEvent(key_code, true);
            self.modifiers &= ~@as(u8, 0x02);
            return true;
        }

        return false;
    }

    /// Convert ASCII byte to key code (simplified mapping)
    fn byteToKeyCode(self: *Self, byte: u8) u32 {
        _ = self;

        // Control characters
        if (byte < 32) {
            return switch (byte) {
                0x01 => 30, // Ctrl+A -> A
                0x02 => 48, // Ctrl+B -> B
                0x03 => 46, // Ctrl+C -> C
                0x04 => 32, // Ctrl+D -> D
                0x05 => 18, // Ctrl+E -> E
                0x06 => 33, // Ctrl+F -> F
                0x07 => 34, // Ctrl+G -> G
                0x08 => 14, // Backspace
                0x09 => 15, // Tab
                0x0A, 0x0D => 28, // Enter
                0x0B => 37, // Ctrl+K -> K
                0x0C => 38, // Ctrl+L -> L
                0x0E => 49, // Ctrl+N -> N
                0x0F => 24, // Ctrl+O -> O
                0x10 => 25, // Ctrl+P -> P
                0x11 => 16, // Ctrl+Q -> Q
                0x12 => 19, // Ctrl+R -> R
                0x13 => 31, // Ctrl+S -> S
                0x14 => 20, // Ctrl+T -> T
                0x15 => 22, // Ctrl+U -> U
                0x16 => 47, // Ctrl+V -> V
                0x17 => 17, // Ctrl+W -> W
                0x18 => 45, // Ctrl+X -> X
                0x19 => 21, // Ctrl+Y -> Y
                0x1A => 44, // Ctrl+Z -> Z
                0x1B => 1,  // ESC
                else => byte,
            };
        }

        // Printable ASCII - use the byte value directly
        // The application should handle character mapping
        return byte;
    }

    /// Queue a key event
    fn queueKeyEvent(self: *Self, key_code: u32, pressed: bool) void {
        if (self.key_event_count >= backend.MAX_KEY_EVENTS) return;

        self.key_events[self.key_event_count] = .{
            .key_code = key_code,
            .modifiers = self.modifiers,
            .pressed = pressed,
        };
        self.key_event_count += 1;
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
