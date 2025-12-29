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
    .log_level = .info,
};

/// Terminal emulator configuration
const Config = struct {
    cols: u32 = 80,
    rows: u32 = 24,
    shell: ?[]const u8 = null,
    socket_path: ?[]const u8 = null,
};

/// Poll file descriptor struct
const PollFd = extern struct {
    fd: posix.fd_t,
    events: i16,
    revents: i16,
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

    // Main event loop
    var running = true;
    while (running) {
        // Poll for events
        var poll_fds = [_]PollFd{
            .{ .fd = shell.getFd(), .events = std.posix.POLL.IN, .revents = 0 },
            .{ .fd = conn.getFd(), .events = std.posix.POLL.IN, .revents = 0 },
        };

        const poll_slice: []posix.pollfd = @ptrCast(&poll_fds);
        const n = posix.poll(poll_slice, 16) catch continue; // 16ms timeout for ~60fps

        if (n == 0) {
            // Timeout - check for render needs
            if (scr.dirty) {
                try renderAndCommit(allocator, &rend, surface);
                scr.dirty = false;
            }
            continue;
        }

        // Check PTY output
        if (poll_fds[0].revents & std.posix.POLL.IN != 0) {
            if (shell.read() catch null) |data| {
                parser.feedSlice(data);
            }
        }
        if (poll_fds[0].revents & (std.posix.POLL.HUP | std.posix.POLL.ERR) != 0) {
            log.info("shell exited", .{});
            running = false;
        }

        // Check daemon events
        if (poll_fds[1].revents & std.posix.POLL.IN != 0) {
            while (true) {
                const event = conn.poll() catch break;
                if (event == null) break;
                switch (event.?) {
                    .disconnected => {
                        log.info("daemon disconnected", .{});
                        running = false;
                    },
                    .error_reply => |err| {
                        log.err("daemon error: {}", .{err.code});
                    },
                    .key_press => |key| {
                        // Only process key presses (not releases)
                        if (key.pressed == 1) {
                            handleKeyPress(&shell, &scr, key.key_code, key.modifiers);
                        }
                    },
                    else => {},
                }
            }
        }

        // Render if dirty
        if (scr.dirty) {
            try renderAndCommit(allocator, &rend, surface);
            scr.dirty = false;
        }
    }

    log.info("semadraw-term exiting", .{});
}

fn renderAndCommit(allocator: std.mem.Allocator, rend: *renderer.Renderer, surface: *client.Surface) !void {
    const sdcs_data = try rend.render();
    defer allocator.free(sdcs_data);
    try surface.attachAndCommit(sdcs_data);
}

fn handleKeyPress(shell: *pty.Pty, scr: *screen.Screen, key_code: u32, modifiers: u8) void {
    const ctrl = (modifiers & 0x04) != 0;
    const shift = (modifiers & 0x01) != 0;

    // Handle scrollback navigation (Shift+PageUp/PageDown)
    if (shift) {
        switch (key_code) {
            104 => { // PageUp
                _ = scr.scrollViewUp(scr.rows / 2); // Scroll up half a screen
                return;
            },
            109 => { // PageDown
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
        // Letters A-Z (16-50 are Q,W,E,R,T,Y,U,I,O,P, A,S,D,F,G,H,J,K,L, Z,X,C,V,B,N,M)
        16 => { // Q
            buf[0] = getChar('q', shift, ctrl);
            len = 1;
        },
        17 => {
            buf[0] = getChar('w', shift, ctrl);
            len = 1;
        },
        18 => {
            buf[0] = getChar('e', shift, ctrl);
            len = 1;
        },
        19 => {
            buf[0] = getChar('r', shift, ctrl);
            len = 1;
        },
        20 => {
            buf[0] = getChar('t', shift, ctrl);
            len = 1;
        },
        21 => {
            buf[0] = getChar('y', shift, ctrl);
            len = 1;
        },
        22 => {
            buf[0] = getChar('u', shift, ctrl);
            len = 1;
        },
        23 => {
            buf[0] = getChar('i', shift, ctrl);
            len = 1;
        },
        24 => {
            buf[0] = getChar('o', shift, ctrl);
            len = 1;
        },
        25 => {
            buf[0] = getChar('p', shift, ctrl);
            len = 1;
        },
        30 => {
            buf[0] = getChar('a', shift, ctrl);
            len = 1;
        },
        31 => {
            buf[0] = getChar('s', shift, ctrl);
            len = 1;
        },
        32 => {
            buf[0] = getChar('d', shift, ctrl);
            len = 1;
        },
        33 => {
            buf[0] = getChar('f', shift, ctrl);
            len = 1;
        },
        34 => {
            buf[0] = getChar('g', shift, ctrl);
            len = 1;
        },
        35 => {
            buf[0] = getChar('h', shift, ctrl);
            len = 1;
        },
        36 => {
            buf[0] = getChar('j', shift, ctrl);
            len = 1;
        },
        37 => {
            buf[0] = getChar('k', shift, ctrl);
            len = 1;
        },
        38 => {
            buf[0] = getChar('l', shift, ctrl);
            len = 1;
        },
        44 => {
            buf[0] = getChar('z', shift, ctrl);
            len = 1;
        },
        45 => {
            buf[0] = getChar('x', shift, ctrl);
            len = 1;
        },
        46 => {
            buf[0] = getChar('c', shift, ctrl);
            len = 1;
        },
        47 => {
            buf[0] = getChar('v', shift, ctrl);
            len = 1;
        },
        48 => {
            buf[0] = getChar('b', shift, ctrl);
            len = 1;
        },
        49 => {
            buf[0] = getChar('n', shift, ctrl);
            len = 1;
        },
        50 => {
            buf[0] = getChar('m', shift, ctrl);
            len = 1;
        },

        // Numbers 0-9 (keys 2-11)
        2...11 => |k| {
            buf[0] = @intCast('0' + ((k + 8) % 10));
            len = 1;
        },

        // Special keys
        1 => { // Escape
            buf[0] = 0x1B;
            len = 1;
        },
        14 => { // Backspace
            buf[0] = 0x7F;
            len = 1;
        },
        15 => { // Tab
            buf[0] = 0x09;
            len = 1;
        },
        28 => { // Enter
            buf[0] = 0x0D;
            len = 1;
        },
        57 => { // Space
            buf[0] = ' ';
            len = 1;
        },

        // Arrow keys
        103 => { // Up
            @memcpy(buf[0..3], "\x1b[A");
            len = 3;
        },
        108 => { // Down
            @memcpy(buf[0..3], "\x1b[B");
            len = 3;
        },
        106 => { // Right
            @memcpy(buf[0..3], "\x1b[C");
            len = 3;
        },
        105 => { // Left
            @memcpy(buf[0..3], "\x1b[D");
            len = 3;
        },

        // Home/End/PageUp/PageDown
        102 => { // Home
            @memcpy(buf[0..3], "\x1b[H");
            len = 3;
        },
        107 => { // End
            @memcpy(buf[0..3], "\x1b[F");
            len = 3;
        },
        104 => { // PageUp
            @memcpy(buf[0..4], "\x1b[5~");
            len = 4;
        },
        109 => { // PageDown
            @memcpy(buf[0..4], "\x1b[6~");
            len = 4;
        },
        110 => { // Insert
            @memcpy(buf[0..4], "\x1b[2~");
            len = 4;
        },
        111 => { // Delete
            @memcpy(buf[0..4], "\x1b[3~");
            len = 4;
        },

        else => {},
    }

    if (len > 0) {
        shell.write(buf[0..len]) catch {};
    }
}
