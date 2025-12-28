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
            try stdout_file.writer().print(
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
            , .{});
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
    try renderAndCommit(allocator, &rend, &surface);

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
                try renderAndCommit(allocator, &rend, &surface);
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

        // Check daemon events (keyboard input)
        if (poll_fds[1].revents & std.posix.POLL.IN != 0) {
            while (conn.pollEvent()) |event| {
                switch (event) {
                    .key_press => |key| {
                        if (key.key_code) |code| {
                            handleKeyPress(&shell, code, key.modifiers);
                        }
                    },
                    .close => {
                        log.info("window closed", .{});
                        running = false;
                    },
                    .resize => |size| {
                        // Handle resize
                        const new_cols = size.width / font.Font.GLYPH_WIDTH;
                        const new_rows = size.height / font.Font.GLYPH_HEIGHT;
                        log.info("resize to {}x{}", .{ new_cols, new_rows });
                        // TODO: Resize screen buffer
                    },
                    else => {},
                }
            }
        }

        // Render if dirty
        if (scr.dirty) {
            try renderAndCommit(allocator, &rend, &surface);
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

fn handleKeyPress(shell: *pty.Pty, key_code: u32, modifiers: u8) void {
    const ctrl = (modifiers & 0x04) != 0;
    const shift = (modifiers & 0x01) != 0;
    _ = shift;

    // Map key codes to terminal sequences
    // These are Linux evdev key codes
    var buf: [16]u8 = undefined;
    var len: usize = 0;

    switch (key_code) {
        // Letters A-Z (16-50 are Q,W,E,R,T,Y,U,I,O,P, A,S,D,F,G,H,J,K,L, Z,X,C,V,B,N,M)
        16 => { // Q
            if (ctrl) {
                buf[0] = 0x11; // Ctrl+Q
                len = 1;
            } else {
                buf[0] = 'q';
                len = 1;
            }
        },
        17 => {
            buf[0] = if (ctrl) 0x17 else 'w';
            len = 1;
        },
        18 => {
            buf[0] = if (ctrl) 0x05 else 'e';
            len = 1;
        },
        19 => {
            buf[0] = if (ctrl) 0x12 else 'r';
            len = 1;
        },
        20 => {
            buf[0] = if (ctrl) 0x14 else 't';
            len = 1;
        },
        21 => {
            buf[0] = if (ctrl) 0x19 else 'y';
            len = 1;
        },
        22 => {
            buf[0] = if (ctrl) 0x15 else 'u';
            len = 1;
        },
        23 => {
            buf[0] = if (ctrl) 0x09 else 'i';
            len = 1;
        },
        24 => {
            buf[0] = if (ctrl) 0x0F else 'o';
            len = 1;
        },
        25 => {
            buf[0] = if (ctrl) 0x10 else 'p';
            len = 1;
        },
        30 => {
            buf[0] = if (ctrl) 0x01 else 'a';
            len = 1;
        },
        31 => {
            buf[0] = if (ctrl) 0x13 else 's';
            len = 1;
        },
        32 => {
            buf[0] = if (ctrl) 0x04 else 'd';
            len = 1;
        },
        33 => {
            buf[0] = if (ctrl) 0x06 else 'f';
            len = 1;
        },
        34 => {
            buf[0] = if (ctrl) 0x07 else 'g';
            len = 1;
        },
        35 => {
            buf[0] = if (ctrl) 0x08 else 'h';
            len = 1;
        },
        36 => {
            buf[0] = if (ctrl) 0x0A else 'j';
            len = 1;
        },
        37 => {
            buf[0] = if (ctrl) 0x0B else 'k';
            len = 1;
        },
        38 => {
            buf[0] = if (ctrl) 0x0C else 'l';
            len = 1;
        },
        44 => {
            buf[0] = if (ctrl) 0x1A else 'z';
            len = 1;
        },
        45 => {
            buf[0] = if (ctrl) 0x18 else 'x';
            len = 1;
        },
        46 => {
            buf[0] = if (ctrl) 0x03 else 'c'; // Ctrl+C
            len = 1;
        },
        47 => {
            buf[0] = if (ctrl) 0x16 else 'v';
            len = 1;
        },
        48 => {
            buf[0] = if (ctrl) 0x02 else 'b';
            len = 1;
        },
        49 => {
            buf[0] = if (ctrl) 0x0E else 'n';
            len = 1;
        },
        50 => {
            buf[0] = if (ctrl) 0x0D else 'm';
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
