const std = @import("std");
const posix = std.posix;
const client = @import("semadraw_client");
const screen = @import("screen");
const vt100 = @import("vt100");
const pty = @import("pty");
const renderer = @import("renderer");
const font = @import("font");

const log = std.log.scoped(.semadraw_term);

pub const std_options = std.Options{
    .log_level = .debug,
};

/// Terminal emulator configuration
const Config = struct {
    cols: u32 = 80,
    rows: u32 = 24,
    shell: ?[]const u8 = null,
    socket_path: ?[]const u8 = null,
};

/// Keyboard modifier masks
const Modifiers = struct {
    const SHIFT: u8 = 0x01;
    const ALT: u8 = 0x02;
    const CTRL: u8 = 0x04;
};

/// ASCII control codes
const Ascii = struct {
    const TAB: u8 = 0x09;
    const CR: u8 = 0x0D; // Carriage return (Enter)
    const ESC: u8 = 0x1B;
    const DEL: u8 = 0x7F; // Delete (Backspace)
};

/// Linux evdev key codes
const Key = struct {
    const ESC: u32 = 1;
    const @"1": u32 = 2;
    const @"2": u32 = 3;
    const @"3": u32 = 4;
    const @"4": u32 = 5;
    const @"5": u32 = 6;
    const @"6": u32 = 7;
    const @"7": u32 = 8;
    const @"8": u32 = 9;
    const @"9": u32 = 10;
    const @"0": u32 = 11;
    const BACKSPACE: u32 = 14;
    const TAB: u32 = 15;
    const Q: u32 = 16;
    const W: u32 = 17;
    const E: u32 = 18;
    const R: u32 = 19;
    const T: u32 = 20;
    const Y: u32 = 21;
    const U: u32 = 22;
    const I: u32 = 23;
    const O: u32 = 24;
    const P: u32 = 25;
    const ENTER: u32 = 28;
    const A: u32 = 30;
    const S: u32 = 31;
    const D: u32 = 32;
    const F: u32 = 33;
    const G: u32 = 34;
    const H: u32 = 35;
    const J: u32 = 36;
    const K: u32 = 37;
    const L: u32 = 38;
    const Z: u32 = 44;
    const X: u32 = 45;
    const C: u32 = 46;
    const V: u32 = 47;
    const B: u32 = 48;
    const N: u32 = 49;
    const M: u32 = 50;
    const SPACE: u32 = 57;
    const HOME: u32 = 102;
    const UP: u32 = 103;
    const PAGE_UP: u32 = 104;
    const LEFT: u32 = 105;
    const RIGHT: u32 = 106;
    const END: u32 = 107;
    const DOWN: u32 = 108;
    const PAGE_DOWN: u32 = 109;
    const INSERT: u32 = 110;
    const DELETE: u32 = 111;
};

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    var config = Config{};

    // Parse arguments
    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "-c") or std.mem.eql(u8, arg, "--cols")) {
            i += 1;
            if (i >= args.len) {
                log.err("missing argument for {s}", .{arg});
                return error.InvalidArgument;
            }
            config.cols = std.fmt.parseInt(u32, args[i], 10) catch {
                log.err("invalid cols: {s}", .{args[i]});
                return error.InvalidArgument;
            };
        } else if (std.mem.eql(u8, arg, "-r") or std.mem.eql(u8, arg, "--rows")) {
            i += 1;
            if (i >= args.len) {
                log.err("missing argument for {s}", .{arg});
                return error.InvalidArgument;
            }
            config.rows = std.fmt.parseInt(u32, args[i], 10) catch {
                log.err("invalid rows: {s}", .{args[i]});
                return error.InvalidArgument;
            };
        } else if (std.mem.eql(u8, arg, "-e") or std.mem.eql(u8, arg, "--shell")) {
            i += 1;
            if (i >= args.len) {
                log.err("missing argument for {s}", .{arg});
                return error.InvalidArgument;
            }
            config.shell = args[i];
        } else if (std.mem.eql(u8, arg, "-s") or std.mem.eql(u8, arg, "--socket")) {
            i += 1;
            if (i >= args.len) {
                log.err("missing argument for {s}", .{arg});
                return error.InvalidArgument;
            }
            config.socket_path = args[i];
        } else if (std.mem.eql(u8, arg, "-h") or std.mem.eql(u8, arg, "--help")) {
            const stdout_file = std.fs.File{ .handle = posix.STDOUT_FILENO };
            stdout_file.writeAll(
                \\semadraw-term - Terminal emulator for SemaDraw
                \\
                \\Usage: semadraw-term [OPTIONS]
                \\
                \\Options:
                \\  -c, --cols N      Terminal columns (default: 80)
                \\  -r, --rows N      Terminal rows (default: 24)
                \\  -e, --shell PATH  Shell to execute (default: $SHELL or /bin/sh)
                \\  -s, --socket PATH Socket path (default: /var/run/semadraw.sock)
                \\  -h, --help        Show this help
                \\
            ) catch {};
            return;
        } else {
            log.err("unknown argument: {s}", .{arg});
            return error.InvalidArgument;
        }
    }

    try run(allocator, config);
}

fn run(allocator: std.mem.Allocator, config: Config) !void {
    log.info("starting semadraw-term {}x{}", .{ config.cols, config.rows });

    // Calculate pixel dimensions
    const width_px = config.cols * font.Font.GLYPH_WIDTH;
    const height_px = config.rows * font.Font.GLYPH_HEIGHT;

    // Connect to semadrawd
    var conn = if (config.socket_path) |path|
        try client.connectTo(allocator, path)
    else
        try client.connect(allocator);
    defer conn.disconnect();

    log.info("connected to semadrawd", .{});

    // Create surface
    var surface = try client.Surface.create(conn, @floatFromInt(width_px), @floatFromInt(height_px));
    defer surface.destroy();

    try surface.show();
    log.info("surface created {}x{}", .{ width_px, height_px });

    // Initialize terminal components
    var scr = try screen.Screen.init(allocator, config.cols, config.rows);
    defer scr.deinit();

    var parser = vt100.Parser.init(&scr);
    var rend = renderer.Renderer.init(allocator, &scr);
    defer rend.deinit();

    // Spawn shell
    var shell = try pty.Pty.spawn(config.shell, @intCast(config.cols), @intCast(config.rows));
    defer shell.close();

    log.info("shell spawned", .{});

    // Initial render
    try renderAndCommit(allocator, &rend, surface);

    // Cursor blink state
    const blink_interval_ms: i64 = 500; // Toggle every 500ms
    var last_blink_time = std.time.milliTimestamp();
    var cursor_blink_visible = true;

    // Main event loop
    var running = true;
    var loop_count: u64 = 0;
    while (running) {
        loop_count += 1;

        // Poll for events
        var poll_fds = [_]posix.pollfd{
            .{ .fd = shell.getFd(), .events = posix.POLL.IN, .revents = 0 },
            .{ .fd = conn.getFd(), .events = posix.POLL.IN, .revents = 0 },
        };

        const n = posix.poll(&poll_fds, 16) catch continue; // 16ms timeout for ~60fps

        // Log poll results periodically or when there's activity
        if (n > 0 or loop_count % 100 == 0) {
            log.debug("loop {}: poll returned {}, revents[0]=0x{x} revents[1]=0x{x}", .{
                loop_count, n,
                @as(u16, @bitCast(poll_fds[0].revents)),
                @as(u16, @bitCast(poll_fds[1].revents))
            });
        }

        // Check cursor blink timing
        const current_time = std.time.milliTimestamp();
        if (scr.shouldCursorBlink() and current_time - last_blink_time >= blink_interval_ms) {
            cursor_blink_visible = !cursor_blink_visible;
            last_blink_time = current_time;
            scr.dirty = true; // Need to re-render for blink state change
        }

        // For non-blinking cursors, always show
        if (!scr.shouldCursorBlink()) {
            cursor_blink_visible = true;
        }

        if (n == 0) {
            // Timeout - check for render needs
            if (scr.dirty) {
                try renderAndCommitWithBlink(allocator, &rend, surface, cursor_blink_visible);
                scr.dirty = false;
            }
            continue;
        }

        // Check PTY output
        if (poll_fds[0].revents & posix.POLL.IN != 0) {
            log.debug("PTY has data, reading...", .{});
            if (shell.read() catch |err| blk: {
                log.debug("PTY read error: {}", .{err});
                break :blk null;
            }) |data| {
                log.debug("PTY read {} bytes: {s}", .{ data.len, data[0..@min(data.len, 64)] });
                parser.feedSlice(data);
                log.debug("VT100 parser fed, screen dirty={}", .{scr.dirty});
            }
        }
        if (poll_fds[0].revents & (posix.POLL.HUP | posix.POLL.ERR) != 0) {
            // Get child exit status for diagnostics
            // Use WNOHANG and store result so close() doesn't try to wait again
            const wait_result = posix.waitpid(shell.child_pid, posix.W.NOHANG);
            if (wait_result.pid != 0) {
                // Mark as reaped so close() won't waitpid again
                shell.child_pid = 0;
                const status = wait_result.status;
                if (posix.W.IFEXITED(status)) {
                    const exit_code = posix.W.EXITSTATUS(status);
                    if (exit_code == 127) {
                        log.err("shell exited with code 127 - execve failed (shell not found or not executable)", .{});
                        log.err("on FreeBSD, bash is at /usr/local/bin/bash, not /bin/bash", .{});
                    } else {
                        log.info("shell exited with code {}", .{exit_code});
                    }
                } else if (posix.W.IFSIGNALED(status)) {
                    const signal = posix.W.TERMSIG(status);
                    log.info("shell killed by signal {}", .{signal});
                } else {
                    log.info("shell exited (status=0x{x})", .{status});
                }
            } else {
                log.info("shell exited (no status available)", .{});
            }
            running = false;
        }

        // Check daemon events
        if (poll_fds[1].revents & posix.POLL.IN != 0) {
            log.debug("daemon fd has data, polling for events", .{});
            while (true) {
                const event = conn.poll() catch |err| {
                    log.debug("conn.poll error: {}", .{err});
                    break;
                };
                if (event == null) {
                    log.debug("conn.poll returned null, no more events", .{});
                    break;
                }
                log.debug("received event from daemon", .{});
                switch (event.?) {
                    .disconnected => {
                        log.info("daemon disconnected", .{});
                        running = false;
                    },
                    .error_reply => |err| {
                        log.err("daemon error: {}", .{err.code});
                    },
                    .key_press => |key| {
                        log.debug("received key_press: code={} pressed={}", .{ key.key_code, key.pressed });
                        // Only process key presses (not releases)
                        if (key.pressed == 1) {
                            handleKeyPress(&shell, &scr, key.key_code, key.modifiers);
                        }
                    },
                    .mouse_event => |mouse| {
                        handleMouseEvent(&shell, &scr, mouse);
                    },
                    else => |tag| {
                        log.debug("unhandled event type: {}", .{tag});
                    },
                }
            }
        }

        // Render if dirty
        if (scr.dirty) {
            log.debug("screen dirty, rendering...", .{});
            try renderAndCommitWithBlink(allocator, &rend, surface, cursor_blink_visible);
            scr.dirty = false;
            log.debug("render complete", .{});
        }
    }

    log.info("semadraw-term exiting", .{});
}

fn renderAndCommit(allocator: std.mem.Allocator, rend: *renderer.Renderer, surface: *client.Surface) !void {
    const sdcs_data = try rend.render();
    defer allocator.free(sdcs_data);
    try surface.attachAndCommit(sdcs_data);
}

fn renderAndCommitWithBlink(allocator: std.mem.Allocator, rend: *renderer.Renderer, surface: *client.Surface, cursor_blink_visible: bool) !void {
    // Temporarily hide cursor if blinking and in "off" phase
    const original_visible = rend.scr.cursor_visible;
    if (!cursor_blink_visible) {
        rend.scr.cursor_visible = false;
    }
    defer rend.scr.cursor_visible = original_visible;

    const sdcs_data = try rend.render();
    defer allocator.free(sdcs_data);
    try surface.attachAndCommit(sdcs_data);
}

fn handleKeyPress(shell: *pty.Pty, scr: *screen.Screen, key_code: u32, modifiers: u8) void {
    const ctrl = (modifiers & Modifiers.CTRL) != 0;
    const shift = (modifiers & Modifiers.SHIFT) != 0;

    // Handle scrollback navigation (Shift+PageUp/PageDown)
    if (shift) {
        switch (key_code) {
            Key.PAGE_UP => {
                _ = scr.scrollViewUp(scr.rows / 2); // Scroll up half a screen
                return;
            },
            Key.PAGE_DOWN => {
                _ = scr.scrollViewDown(scr.rows / 2); // Scroll down half a screen
                return;
            },
            else => {},
        }
    }

    // Any other key press resets scroll view to bottom
    if (scr.isViewingScrollback()) {
        scr.resetScrollView();
    }

    // Map key codes to terminal sequences
    // These are Linux evdev key codes
    var buf: [16]u8 = undefined;
    var len: usize = 0;

    // Helper to get letter with shift support
    const getChar = struct {
        fn get(lower: u8, is_shift: bool, is_ctrl: bool) u8 {
            if (is_ctrl) {
                // Ctrl+letter = ASCII 1-26
                return lower - 'a' + 1;
            } else if (is_shift) {
                return lower - 32; // Convert to uppercase
            } else {
                return lower;
            }
        }
    }.get;

    switch (key_code) {
        // Letters A-Z
        Key.Q => {
            buf[0] = getChar('q', shift, ctrl);
            len = 1;
        },
        Key.W => {
            buf[0] = getChar('w', shift, ctrl);
            len = 1;
        },
        Key.E => {
            buf[0] = getChar('e', shift, ctrl);
            len = 1;
        },
        Key.R => {
            buf[0] = getChar('r', shift, ctrl);
            len = 1;
        },
        Key.T => {
            buf[0] = getChar('t', shift, ctrl);
            len = 1;
        },
        Key.Y => {
            buf[0] = getChar('y', shift, ctrl);
            len = 1;
        },
        Key.U => {
            buf[0] = getChar('u', shift, ctrl);
            len = 1;
        },
        Key.I => {
            buf[0] = getChar('i', shift, ctrl);
            len = 1;
        },
        Key.O => {
            buf[0] = getChar('o', shift, ctrl);
            len = 1;
        },
        Key.P => {
            buf[0] = getChar('p', shift, ctrl);
            len = 1;
        },
        Key.A => {
            buf[0] = getChar('a', shift, ctrl);
            len = 1;
        },
        Key.S => {
            buf[0] = getChar('s', shift, ctrl);
            len = 1;
        },
        Key.D => {
            buf[0] = getChar('d', shift, ctrl);
            len = 1;
        },
        Key.F => {
            buf[0] = getChar('f', shift, ctrl);
            len = 1;
        },
        Key.G => {
            buf[0] = getChar('g', shift, ctrl);
            len = 1;
        },
        Key.H => {
            buf[0] = getChar('h', shift, ctrl);
            len = 1;
        },
        Key.J => {
            buf[0] = getChar('j', shift, ctrl);
            len = 1;
        },
        Key.K => {
            buf[0] = getChar('k', shift, ctrl);
            len = 1;
        },
        Key.L => {
            buf[0] = getChar('l', shift, ctrl);
            len = 1;
        },
        Key.Z => {
            buf[0] = getChar('z', shift, ctrl);
            len = 1;
        },
        Key.X => {
            buf[0] = getChar('x', shift, ctrl);
            len = 1;
        },
        Key.C => {
            buf[0] = getChar('c', shift, ctrl);
            len = 1;
        },
        Key.V => {
            buf[0] = getChar('v', shift, ctrl);
            len = 1;
        },
        Key.B => {
            buf[0] = getChar('b', shift, ctrl);
            len = 1;
        },
        Key.N => {
            buf[0] = getChar('n', shift, ctrl);
            len = 1;
        },
        Key.M => {
            buf[0] = getChar('m', shift, ctrl);
            len = 1;
        },

        // Numbers 0-9
        Key.@"1"...Key.@"0" => |k| {
            buf[0] = @intCast('0' + ((k + 8) % 10));
            len = 1;
        },

        // Special keys
        Key.ESC => {
            buf[0] = Ascii.ESC;
            len = 1;
        },
        Key.BACKSPACE => {
            buf[0] = Ascii.DEL;
            len = 1;
        },
        Key.TAB => {
            buf[0] = Ascii.TAB;
            len = 1;
        },
        Key.ENTER => {
            buf[0] = Ascii.CR;
            len = 1;
        },
        Key.SPACE => {
            buf[0] = ' ';
            len = 1;
        },

        // Arrow keys
        Key.UP => {
            @memcpy(buf[0..3], "\x1b[A");
            len = 3;
        },
        Key.DOWN => {
            @memcpy(buf[0..3], "\x1b[B");
            len = 3;
        },
        Key.RIGHT => {
            @memcpy(buf[0..3], "\x1b[C");
            len = 3;
        },
        Key.LEFT => {
            @memcpy(buf[0..3], "\x1b[D");
            len = 3;
        },

        // Home/End/PageUp/PageDown
        Key.HOME => {
            @memcpy(buf[0..3], "\x1b[H");
            len = 3;
        },
        Key.END => {
            @memcpy(buf[0..3], "\x1b[F");
            len = 3;
        },
        Key.PAGE_UP => {
            @memcpy(buf[0..4], "\x1b[5~");
            len = 4;
        },
        Key.PAGE_DOWN => {
            @memcpy(buf[0..4], "\x1b[6~");
            len = 4;
        },
        Key.INSERT => {
            @memcpy(buf[0..4], "\x1b[2~");
            len = 4;
        },
        Key.DELETE => {
            @memcpy(buf[0..4], "\x1b[3~");
            len = 4;
        },

        else => {
            log.debug("unhandled key code: {}", .{key_code});
        },
    }

    if (len > 0) {
        log.debug("writing to PTY: {} bytes", .{len});
        shell.write(buf[0..len]) catch |err| {
            log.warn("shell write failed: {}", .{err});
        };
    }
}

fn handleMouseEvent(shell: *pty.Pty, scr: *screen.Screen, mouse: client.protocol.MouseEventMsg) void {
    // Check if mouse tracking is enabled
    const tracking = scr.getMouseTracking();
    if (tracking == .none) return;

    const encoding = scr.getMouseEncoding();
    const event_type = mouse.event_type;

    // Check if this event type should be reported based on tracking mode
    const should_report = switch (tracking) {
        .none => false,
        .x10 => event_type == .press, // X10 only reports button presses
        .vt200, .vt200_highlight => event_type == .press or event_type == .release,
        .btn_event => event_type == .press or event_type == .release or
            (event_type == .motion and isButtonPressed(mouse.button)),
        .any_event => true, // Report all events
    };

    if (!should_report) return;

    // Convert pixel coordinates to cell coordinates
    const cell_x = @divFloor(mouse.x, @as(i32, font.Font.GLYPH_WIDTH)) + 1;
    const cell_y = @divFloor(mouse.y, @as(i32, font.Font.GLYPH_HEIGHT)) + 1;

    // Clamp to valid range (cols/rows are u32 but always fit in i32 for reasonable terminals)
    const max_col: i32 = @intCast(scr.cols);
    const max_row: i32 = @intCast(scr.rows);
    const x: u32 = @intCast(@max(1, @min(cell_x, max_col)));
    const y: u32 = @intCast(@max(1, @min(cell_y, max_row)));

    // Generate the mouse report based on encoding mode
    var buf: [32]u8 = undefined;
    var len: usize = 0;

    switch (encoding) {
        .sgr => {
            // SGR extended mode: CSI < Pb ; Px ; Py M/m
            // Pb = button number (0=left, 1=middle, 2=right) + modifiers
            // Px, Py = 1-based coordinates
            // M = press, m = release
            const btn = getButtonCode(mouse.button, mouse.modifiers, event_type == .motion);
            const terminator: u8 = if (event_type == .release) 'm' else 'M';
            len = formatSgrMouse(&buf, btn, x, y, terminator);
        },
        .urxvt => {
            // URXVT mode: CSI Pb ; Px ; Py M
            const btn = getButtonCode(mouse.button, mouse.modifiers, event_type == .motion) + 32;
            len = formatUrxvtMouse(&buf, btn, x, y);
        },
        .x10, .utf8 => {
            // X10/UTF-8 mode: CSI M Cb Cx Cy
            // Cb = 32 + button + modifiers
            // Cx, Cy = 32 + coordinate (1-based)
            const btn = getButtonCode(mouse.button, mouse.modifiers, event_type == .motion);
            // For release in X10 mode, use button 3 (release indicator)
            const cb: u8 = if (event_type == .release) 32 + 3 else 32 + btn;
            const cx: u8 = @intCast(@min(x + 32, 255));
            const cy: u8 = @intCast(@min(y + 32, 255));
            buf[0] = Ascii.ESC;
            buf[1] = '[';
            buf[2] = 'M';
            buf[3] = cb;
            buf[4] = cx;
            buf[5] = cy;
            len = 6;
        },
    }

    if (len > 0) {
        shell.write(buf[0..len]) catch |err| {
            log.warn("mouse event write failed: {}", .{err});
        };
    }
}

fn isButtonPressed(button: client.protocol.MouseButtonId) bool {
    return switch (button) {
        .left, .middle, .right => true,
        .scroll_up, .scroll_down, .scroll_left, .scroll_right, .button4, .button5 => false,
    };
}

fn getButtonCode(button: client.protocol.MouseButtonId, modifiers: u8, is_motion: bool) u8 {
    // Base button code: 0=left, 1=middle, 2=right
    var code: u8 = switch (button) {
        .left => 0,
        .middle => 1,
        .right => 2,
        .scroll_up => 64, // Scroll up
        .scroll_down => 65, // Scroll down
        .scroll_left => 66,
        .scroll_right => 67,
        .button4, .button5 => 0,
    };

    // Add modifier bits
    if (modifiers & Modifiers.SHIFT != 0) code |= 4; // Shift
    if (modifiers & Modifiers.ALT != 0) code |= 8; // Alt/Meta
    if (modifiers & Modifiers.CTRL != 0) code |= 16; // Ctrl

    // Add motion bit
    if (is_motion) code |= 32;

    return code;
}

fn formatSgrMouse(buf: []u8, btn: u8, x: u32, y: u32, terminator: u8) usize {
    // Format: CSI < btn ; x ; y M/m
    var i: usize = 0;
    buf[i] = Ascii.ESC;
    i += 1;
    buf[i] = '[';
    i += 1;
    buf[i] = '<';
    i += 1;

    // Button
    i += formatDecimal(buf[i..], btn);
    buf[i] = ';';
    i += 1;

    // X coordinate
    i += formatDecimal(buf[i..], @intCast(x));
    buf[i] = ';';
    i += 1;

    // Y coordinate
    i += formatDecimal(buf[i..], @intCast(y));

    // Terminator
    buf[i] = terminator;
    i += 1;

    return i;
}

fn formatUrxvtMouse(buf: []u8, btn: u8, x: u32, y: u32) usize {
    // Format: CSI btn ; x ; y M
    var i: usize = 0;
    buf[i] = Ascii.ESC;
    i += 1;
    buf[i] = '[';
    i += 1;

    // Button
    i += formatDecimal(buf[i..], btn);
    buf[i] = ';';
    i += 1;

    // X coordinate
    i += formatDecimal(buf[i..], @intCast(x));
    buf[i] = ';';
    i += 1;

    // Y coordinate
    i += formatDecimal(buf[i..], @intCast(y));

    // Terminator
    buf[i] = 'M';
    i += 1;

    return i;
}

fn formatDecimal(buf: []u8, value: u32) usize {
    if (value == 0) {
        buf[0] = '0';
        return 1;
    }

    var v = value;
    var len: usize = 0;

    // Count digits
    var temp = value;
    while (temp > 0) : (temp /= 10) {
        len += 1;
    }

    // Write digits in reverse order
    var i = len;
    while (v > 0) : (v /= 10) {
        i -= 1;
        buf[i] = @intCast('0' + (v % 10));
    }

    return len;
}
