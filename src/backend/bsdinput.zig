const std = @import("std");
const posix = std.posix;
const backend = @import("backend");

const log = std.log.scoped(.bsd_input);

// Link libc for ioctl and console access
const c = @cImport({
    @cInclude("sys/ioctl.h");
    @cInclude("termios.h");
    @cInclude("sys/consio.h"); // For KDSKBMODE, KDGKBMODE
    @cInclude("sys/kbio.h"); // For keyboard mode constants
    @cInclude("fcntl.h");
    @cInclude("dirent.h");
});

// Evdev constants (same as Linux evdev.zig)
const EVIOCGBIT = 0x80004520; // EVIOCGBIT(0, 0) base
const EV_KEY: u16 = 0x01;
const EV_REL: u16 = 0x02;
const EV_ABS: u16 = 0x03;

// Keyboard mode constants (from sys/kbio.h)
const K_RAW: c_int = 0; // Raw scancode mode
const K_XLATE: c_int = 1; // Translated ASCII mode
const K_CODE: c_int = 2; // Key code mode

// Input event structure for evdev
const InputEvent = extern struct {
    tv_sec: isize,
    tv_usec: isize,
    type: u16,
    code: u16,
    value: i32,
};

// ============================================================================
// FreeBSD input support (evdev + sysmouse + VT console keyboard)
// ============================================================================

/// Maximum number of input devices to track
pub const MAX_INPUT_DEVICES = 4;

/// Input device types
pub const InputDeviceType = enum {
    keyboard,
    mouse,
    unknown,
};

/// Keyboard input mode
pub const KeyboardMode = enum {
    none, // No keyboard available
    evdev, // Using evdev device (/dev/input/event*)
    vt_raw, // Using VT console in raw scancode mode
    tty_cooked, // Using /dev/tty in raw termios mode (fallback)
};

/// BSD input handler - manages keyboard and mouse input on FreeBSD
pub const BsdInput = struct {
    allocator: std.mem.Allocator,

    // Input device file descriptors
    mouse_fd: posix.fd_t,
    tty_fd: posix.fd_t,

    // Evdev keyboard device (if available)
    evdev_keyboard_fd: posix.fd_t,

    // VT console device (for raw keyboard mode)
    console_fd: posix.fd_t,
    orig_kb_mode: c_int, // Original keyboard mode for restoration

    // Keyboard input mode being used
    keyboard_mode: KeyboardMode,

    // Original terminal settings (for restoration)
    orig_termios: ?c.struct_termios,

    // Mouse state
    mouse_x: i32,
    mouse_y: i32,
    mouse_buttons: u8, // Bit flags: 0=left, 1=middle, 2=right
    screen_width: u32,
    screen_height: u32,

    // Modifier key state (for scancode tracking)
    shift_pressed: bool,
    ctrl_pressed: bool,
    alt_pressed: bool,
    modifiers: u8, // Bit flags: 0=shift, 1=alt, 2=ctrl, 3=meta

    // Event queues
    key_events: [backend.MAX_KEY_EVENTS]backend.KeyEvent,
    key_event_count: usize,
    mouse_events: [backend.MAX_MOUSE_EVENTS]backend.MouseEvent,
    mouse_event_count: usize,

    // Sysmouse packet buffer
    mouse_buf: [5]u8,
    mouse_buf_len: usize,

    // Escape sequence buffer for keyboard (tty mode only)
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
            .evdev_keyboard_fd = -1,
            .console_fd = -1,
            .orig_kb_mode = K_XLATE,
            .keyboard_mode = .none,
            .orig_termios = null,
            .mouse_x = @intCast(screen_width / 2),
            .mouse_y = @intCast(screen_height / 2),
            .mouse_buttons = 0,
            .screen_width = screen_width,
            .screen_height = screen_height,
            .shift_pressed = false,
            .ctrl_pressed = false,
            .alt_pressed = false,
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

        // Try keyboard input methods in order of preference:
        // 1. evdev (if available on FreeBSD with evdev support)
        // 2. VT console raw mode (for direct console access)
        // 3. /dev/tty cooked mode (fallback)

        // Method 1: Try evdev keyboard
        if (self.tryEvdevKeyboard()) {
            log.info("keyboard: using evdev device", .{});
        }
        // Method 2: Try VT console raw keyboard mode
        else if (self.tryVtConsoleKeyboard()) {
            log.info("keyboard: using VT console raw mode", .{});
        }
        // Method 3: Fall back to /dev/tty cooked mode
        else if (self.tryTtyKeyboard()) {
            log.info("keyboard: using /dev/tty cooked mode (fallback)", .{});
            log.warn("keyboard input may not work from another terminal", .{});
        } else {
            log.warn("no keyboard input method available", .{});
        }

        // Log input device status
        const kb_available = self.keyboard_mode != .none;
        const mouse_available = self.mouse_fd >= 0;

        if (mouse_available and kb_available) {
            log.info("BSD input initialized: mouse and keyboard ({s}) available", .{@tagName(self.keyboard_mode)});
        } else if (kb_available) {
            log.info("BSD input initialized: keyboard ({s}) only", .{@tagName(self.keyboard_mode)});
            log.warn("for mouse: ensure moused is running (service moused start)", .{});
        } else if (mouse_available) {
            log.warn("BSD input: mouse available but keyboard failed", .{});
        } else {
            log.warn("no input devices available on FreeBSD", .{});
            log.warn("for mouse: ensure moused is running (service moused start)", .{});
        }

        return self;
    }

    /// Try to open an evdev keyboard device
    fn tryEvdevKeyboard(self: *Self) bool {
        // Scan /dev/input/ for event devices
        var path_buf: [64]u8 = undefined;

        var i: u32 = 0;
        while (i < 32) : (i += 1) {
            const path = std.fmt.bufPrint(&path_buf, "/dev/input/event{}", .{i}) catch continue;
            const path_z = std.fmt.bufPrintZ(&path_buf, "/dev/input/event{}", .{i}) catch continue;
            _ = path;

            const fd = posix.open(path_z, .{ .ACCMODE = .RDONLY, .NONBLOCK = true }, 0) catch continue;

            // Check if this is a keyboard device
            if (self.isEvdevKeyboard(fd)) {
                self.evdev_keyboard_fd = fd;
                self.keyboard_mode = .evdev;
                log.info("found evdev keyboard at /dev/input/event{}", .{i});
                return true;
            }

            posix.close(fd);
        }

        return false;
    }

    /// Check if an evdev device is a keyboard
    fn isEvdevKeyboard(self: *Self, fd: posix.fd_t) bool {
        _ = self;

        // Get event types supported by this device
        var ev_bits: [4]u8 = undefined;
        const ioctl_num = @as(usize, 0x80000000) | (@as(usize, ev_bits.len) << 16) | (@as(usize, 'E') << 8) | 0x20;

        const result = std.posix.system.ioctl(fd, @intCast(ioctl_num), @intFromPtr(&ev_bits));
        if (@as(isize, @bitCast(result)) < 0) return false;

        // Check for EV_KEY support (bit 1)
        const has_key = (ev_bits[0] & (1 << EV_KEY)) != 0;
        if (!has_key) return false;

        // Check for actual keyboard keys (Q, W, E keys)
        var key_bits: [64]u8 = undefined;
        const key_ioctl = @as(usize, 0x80000000) | (@as(usize, key_bits.len) << 16) | (@as(usize, 'E') << 8) | 0x21;
        const key_result = std.posix.system.ioctl(fd, @intCast(key_ioctl), @intFromPtr(&key_bits));
        if (@as(isize, @bitCast(key_result)) < 0) return false;

        // Check for KEY_Q (16) and KEY_W (17) - most keyboards have these
        const has_q = (key_bits[16 / 8] & (@as(u8, 1) << @intCast(16 % 8))) != 0;
        const has_w = (key_bits[17 / 8] & (@as(u8, 1) << @intCast(17 % 8))) != 0;

        return has_q and has_w;
    }

    /// Try to set up VT console raw keyboard mode
    fn tryVtConsoleKeyboard(self: *Self) bool {
        // Try to open the console device
        const console_paths = [_][:0]const u8{
            "/dev/ttyv0",
            "/dev/console",
        };

        for (console_paths) |path| {
            self.console_fd = posix.open(path, .{ .ACCMODE = .RDONLY, .NONBLOCK = true }, 0) catch continue;

            // Try to get current keyboard mode
            var current_mode: c_int = K_XLATE;
            const kdgkbmode_result = c.ioctl(self.console_fd, c.KDGKBMODE, &current_mode);

            if (kdgkbmode_result < 0) {
                log.debug("KDGKBMODE failed on {s} (errno={})", .{ path, std.posix.errno(kdgkbmode_result) });
                posix.close(self.console_fd);
                self.console_fd = -1;
                continue;
            }

            // Save original mode
            self.orig_kb_mode = current_mode;

            // Try to set raw scancode mode (K_CODE gives us keycodes, K_RAW gives scancodes)
            const set_result = c.ioctl(self.console_fd, c.KDSKBMODE, K_CODE);
            if (set_result < 0) {
                log.debug("KDSKBMODE K_CODE failed on {s} (errno={})", .{ path, std.posix.errno(set_result) });
                posix.close(self.console_fd);
                self.console_fd = -1;
                continue;
            }

            self.keyboard_mode = .vt_raw;
            log.info("VT console keyboard: {s} (mode {} -> K_CODE)", .{ path, current_mode });
            return true;
        }

        return false;
    }

    /// Try to open /dev/tty for keyboard input (fallback mode)
    fn tryTtyKeyboard(self: *Self) bool {
        self.tty_fd = posix.open("/dev/tty", .{ .ACCMODE = .RDONLY, .NONBLOCK = true }, 0) catch |err| {
            log.debug("failed to open /dev/tty: {}", .{err});
            return false;
        };

        if (self.setRawMode()) {
            self.keyboard_mode = .tty_cooked;
            return true;
        }

        posix.close(self.tty_fd);
        self.tty_fd = -1;
        return false;
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

    /// Restore original VT console keyboard mode
    fn restoreKbMode(self: *Self) void {
        if (self.console_fd >= 0 and self.keyboard_mode == .vt_raw) {
            const result = c.ioctl(self.console_fd, c.KDSKBMODE, self.orig_kb_mode);
            if (result < 0) {
                log.warn("failed to restore keyboard mode", .{});
            } else {
                log.debug("restored keyboard mode to {}", .{self.orig_kb_mode});
            }
        }
    }

    /// Cleanup and close all input devices
    pub fn deinit(self: *Self) void {
        // Restore terminal/keyboard modes before closing
        self.restoreMode();
        self.restoreKbMode();

        if (self.mouse_fd >= 0) {
            posix.close(self.mouse_fd);
        }
        if (self.tty_fd >= 0) {
            posix.close(self.tty_fd);
        }
        if (self.evdev_keyboard_fd >= 0) {
            posix.close(self.evdev_keyboard_fd);
        }
        if (self.console_fd >= 0) {
            posix.close(self.console_fd);
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

    /// Poll keyboard for key events based on current keyboard mode
    fn pollKeyboard(self: *Self) void {
        switch (self.keyboard_mode) {
            .evdev => self.pollEvdevKeyboard(),
            .vt_raw => self.pollVtKeyboard(),
            .tty_cooked => self.pollTtyKeyboard(),
            .none => {},
        }
    }

    /// Poll evdev keyboard device
    fn pollEvdevKeyboard(self: *Self) void {
        if (self.evdev_keyboard_fd < 0) return;

        var events: [16]InputEvent = undefined;
        const event_size = @sizeOf(InputEvent);

        while (true) {
            const buf_ptr: [*]u8 = @ptrCast(&events);
            const buf_slice = buf_ptr[0 .. events.len * event_size];
            const n = posix.read(self.evdev_keyboard_fd, buf_slice) catch break;
            if (n == 0) break;

            const num_events = n / event_size;
            for (events[0..num_events]) |ev| {
                if (ev.type == EV_KEY) {
                    // Update modifier state
                    self.updateModifiers(ev.code, ev.value != 0);

                    // Queue key event (value: 0=release, 1=press, 2=repeat)
                    if (ev.value == 1) { // Press only
                        self.queueKeyEvent(ev.code, true);
                        log.debug("evdev key: code={} pressed modifiers=0x{x:0>2}", .{ ev.code, self.modifiers });
                    } else if (ev.value == 0) { // Release
                        self.queueKeyEvent(ev.code, false);
                    }
                }
            }
        }
    }

    /// Poll VT console for raw keycodes
    fn pollVtKeyboard(self: *Self) void {
        if (self.console_fd < 0) return;

        var buf: [64]u8 = undefined;
        while (true) {
            const n = posix.read(self.console_fd, &buf) catch break;
            if (n == 0) break;

            for (buf[0..n]) |scancode| {
                self.processVtScancode(scancode);
            }
        }
    }

    /// Process a VT console scancode (K_CODE mode)
    fn processVtScancode(self: *Self, scancode: u8) void {
        // In K_CODE mode, the high bit indicates release (0x80)
        const released = (scancode & 0x80) != 0;
        const code = scancode & 0x7F;

        // Convert AT/XT scancode to evdev keycode
        const evdev_code = self.scancodeToEvdev(code);
        if (evdev_code == 0) return;

        // Update modifier state
        self.updateModifiers(@intCast(evdev_code), !released);

        // Queue key event
        self.queueKeyEvent(evdev_code, !released);

        log.debug("VT scancode: 0x{x:0>2} -> evdev {} {} modifiers=0x{x:0>2}", .{
            scancode,
            evdev_code,
            if (released) "released" else "pressed",
            self.modifiers,
        });
    }

    /// Convert AT/XT scancode to evdev keycode
    fn scancodeToEvdev(self: *Self, scancode: u8) u32 {
        _ = self;
        // Standard AT set 1 scancode to evdev keycode mapping
        // These map the basic PC keyboard scancodes to Linux evdev codes
        return switch (scancode) {
            0x01 => 1, // ESC
            0x02 => 2, // 1
            0x03 => 3, // 2
            0x04 => 4, // 3
            0x05 => 5, // 4
            0x06 => 6, // 5
            0x07 => 7, // 6
            0x08 => 8, // 7
            0x09 => 9, // 8
            0x0A => 10, // 9
            0x0B => 11, // 0
            0x0C => 12, // -
            0x0D => 13, // =
            0x0E => 14, // Backspace
            0x0F => 15, // Tab
            0x10 => 16, // Q
            0x11 => 17, // W
            0x12 => 18, // E
            0x13 => 19, // R
            0x14 => 20, // T
            0x15 => 21, // Y
            0x16 => 22, // U
            0x17 => 23, // I
            0x18 => 24, // O
            0x19 => 25, // P
            0x1A => 26, // [
            0x1B => 27, // ]
            0x1C => 28, // Enter
            0x1D => 29, // Left Ctrl
            0x1E => 30, // A
            0x1F => 31, // S
            0x20 => 32, // D
            0x21 => 33, // F
            0x22 => 34, // G
            0x23 => 35, // H
            0x24 => 36, // J
            0x25 => 37, // K
            0x26 => 38, // L
            0x27 => 39, // ;
            0x28 => 40, // '
            0x29 => 41, // `
            0x2A => 42, // Left Shift
            0x2B => 43, // \
            0x2C => 44, // Z
            0x2D => 45, // X
            0x2E => 46, // C
            0x2F => 47, // V
            0x30 => 48, // B
            0x31 => 49, // N
            0x32 => 50, // M
            0x33 => 51, // ,
            0x34 => 52, // .
            0x35 => 53, // /
            0x36 => 54, // Right Shift
            0x37 => 55, // Keypad *
            0x38 => 56, // Left Alt
            0x39 => 57, // Space
            0x3A => 58, // Caps Lock
            0x3B => 59, // F1
            0x3C => 60, // F2
            0x3D => 61, // F3
            0x3E => 62, // F4
            0x3F => 63, // F5
            0x40 => 64, // F6
            0x41 => 65, // F7
            0x42 => 66, // F8
            0x43 => 67, // F9
            0x44 => 68, // F10
            0x45 => 69, // Num Lock
            0x46 => 70, // Scroll Lock
            0x47 => 71, // Keypad 7 / Home
            0x48 => 72, // Keypad 8 / Up
            0x49 => 73, // Keypad 9 / PgUp
            0x4A => 74, // Keypad -
            0x4B => 75, // Keypad 4 / Left
            0x4C => 76, // Keypad 5
            0x4D => 77, // Keypad 6 / Right
            0x4E => 78, // Keypad +
            0x4F => 79, // Keypad 1 / End
            0x50 => 80, // Keypad 2 / Down
            0x51 => 81, // Keypad 3 / PgDn
            0x52 => 82, // Keypad 0 / Ins
            0x53 => 83, // Keypad . / Del
            0x57 => 87, // F11
            0x58 => 88, // F12
            else => 0, // Unknown
        };
    }

    /// Update modifier key state
    fn updateModifiers(self: *Self, code: u16, pressed: bool) void {
        switch (code) {
            42, 54 => { // Left/Right Shift
                self.shift_pressed = pressed;
                if (pressed) self.modifiers |= 0x01 else self.modifiers &= ~@as(u8, 0x01);
            },
            56 => { // Left Alt
                self.alt_pressed = pressed;
                if (pressed) self.modifiers |= 0x02 else self.modifiers &= ~@as(u8, 0x02);
            },
            29 => { // Left Ctrl
                self.ctrl_pressed = pressed;
                if (pressed) self.modifiers |= 0x04 else self.modifiers &= ~@as(u8, 0x04);
            },
            else => {},
        }
    }

    /// Poll /dev/tty for keyboard input (fallback cooked mode)
    fn pollTtyKeyboard(self: *Self) void {
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
                self.queueKeyEvent(1, true); // ESC key (evdev code 1)
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
        // Save current modifiers - byteToKeyCode may modify them for shifted chars
        const saved_modifiers = self.modifiers;
        const key_code = self.byteToKeyCode(byte);
        if (key_code != 0) {
            self.queueKeyEvent(key_code, true);
            log.debug("keyboard input: byte=0x{x:0>2} -> key_code={} modifiers=0x{x:0>2}", .{
                byte,
                key_code,
                self.modifiers,
            });
        }
        // Restore modifiers - the modifier flags set by byteToKeyCode are
        // only for that specific key event, not persistent state
        self.modifiers = saved_modifiers;
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

    /// Convert ASCII byte to evdev key code
    /// This maps ASCII characters to Linux evdev key codes for compatibility
    /// with the application layer which expects evdev codes
    fn byteToKeyCode(self: *Self, byte: u8) u32 {
        // Control characters
        if (byte < 32) {
            // Set ctrl modifier for Ctrl+letter combinations
            if (byte >= 1 and byte <= 26) {
                self.modifiers |= 0x04; // CTRL modifier
            }
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
                else => 0,  // Unknown control character
            };
        }

        // Space
        if (byte == ' ') return 57;

        // Numbers 0-9 (ASCII 48-57 -> evdev 11, 2-10)
        if (byte >= '0' and byte <= '9') {
            if (byte == '0') return 11;
            return @as(u32, byte - '0') + 1; // '1'->2, '2'->3, ..., '9'->10
        }

        // Lowercase letters a-z (ASCII 97-122 -> evdev key codes)
        if (byte >= 'a' and byte <= 'z') {
            return switch (byte) {
                'a' => 30, 'b' => 48, 'c' => 46, 'd' => 32, 'e' => 18,
                'f' => 33, 'g' => 34, 'h' => 35, 'i' => 23, 'j' => 36,
                'k' => 37, 'l' => 38, 'm' => 50, 'n' => 49, 'o' => 24,
                'p' => 25, 'q' => 16, 'r' => 19, 's' => 31, 't' => 20,
                'u' => 22, 'v' => 47, 'w' => 17, 'x' => 45, 'y' => 21,
                'z' => 44,
                else => 0,
            };
        }

        // Uppercase letters A-Z (ASCII 65-90 -> evdev + shift modifier)
        if (byte >= 'A' and byte <= 'Z') {
            self.modifiers |= 0x01; // SHIFT modifier
            return switch (byte) {
                'A' => 30, 'B' => 48, 'C' => 46, 'D' => 32, 'E' => 18,
                'F' => 33, 'G' => 34, 'H' => 35, 'I' => 23, 'J' => 36,
                'K' => 37, 'L' => 38, 'M' => 50, 'N' => 49, 'O' => 24,
                'P' => 25, 'Q' => 16, 'R' => 19, 'S' => 31, 'T' => 20,
                'U' => 22, 'V' => 47, 'W' => 17, 'X' => 45, 'Y' => 21,
                'Z' => 44,
                else => 0,
            };
        }

        // Punctuation and symbols (unshifted versions)
        return switch (byte) {
            '-' => 12,  // MINUS
            '=' => 13,  // EQUAL
            '[' => 26,  // LEFTBRACE
            ']' => 27,  // RIGHTBRACE
            ';' => 39,  // SEMICOLON
            '\'' => 40, // APOSTROPHE
            '`' => 41,  // GRAVE
            '\\' => 43, // BACKSLASH
            ',' => 51,  // COMMA
            '.' => 52,  // DOT
            '/' => 53,  // SLASH
            // Shifted symbols - set shift modifier and return base key
            '!' => blk: { self.modifiers |= 0x01; break :blk 2; },   // Shift+1
            '@' => blk: { self.modifiers |= 0x01; break :blk 3; },   // Shift+2
            '#' => blk: { self.modifiers |= 0x01; break :blk 4; },   // Shift+3
            '$' => blk: { self.modifiers |= 0x01; break :blk 5; },   // Shift+4
            '%' => blk: { self.modifiers |= 0x01; break :blk 6; },   // Shift+5
            '^' => blk: { self.modifiers |= 0x01; break :blk 7; },   // Shift+6
            '&' => blk: { self.modifiers |= 0x01; break :blk 8; },   // Shift+7
            '*' => blk: { self.modifiers |= 0x01; break :blk 9; },   // Shift+8
            '(' => blk: { self.modifiers |= 0x01; break :blk 10; },  // Shift+9
            ')' => blk: { self.modifiers |= 0x01; break :blk 11; },  // Shift+0
            '_' => blk: { self.modifiers |= 0x01; break :blk 12; },  // Shift+MINUS
            '+' => blk: { self.modifiers |= 0x01; break :blk 13; },  // Shift+EQUAL
            '{' => blk: { self.modifiers |= 0x01; break :blk 26; },  // Shift+LEFTBRACE
            '}' => blk: { self.modifiers |= 0x01; break :blk 27; },  // Shift+RIGHTBRACE
            ':' => blk: { self.modifiers |= 0x01; break :blk 39; },  // Shift+SEMICOLON
            '"' => blk: { self.modifiers |= 0x01; break :blk 40; },  // Shift+APOSTROPHE
            '~' => blk: { self.modifiers |= 0x01; break :blk 41; },  // Shift+GRAVE
            '|' => blk: { self.modifiers |= 0x01; break :blk 43; },  // Shift+BACKSLASH
            '<' => blk: { self.modifiers |= 0x01; break :blk 51; },  // Shift+COMMA
            '>' => blk: { self.modifiers |= 0x01; break :blk 52; },  // Shift+DOT
            '?' => blk: { self.modifiers |= 0x01; break :blk 53; },  // Shift+SLASH
            0x7F => 14, // DEL -> Backspace
            else => 0,  // Unknown character
        };
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
