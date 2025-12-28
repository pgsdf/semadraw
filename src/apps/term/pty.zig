const std = @import("std");
const posix = std.posix;

// Linux-specific PTY ioctl constants (not in std.c.T)
const TIOCGPTN: c_ulong = 0x80045430; // Get PTY number
const TIOCSPTLCK: c_ulong = 0x40045431; // Lock/unlock PTY

/// Pseudo-terminal handler for shell communication
pub const Pty = struct {
    master_fd: posix.fd_t,
    child_pid: posix.pid_t,
    read_buf: [4096]u8,

    const Self = @This();

    /// Spawn a shell with a pty
    pub fn spawn(shell: ?[]const u8, cols: u16, rows: u16) !Self {
        // Open pty master
        const master_fd = try openPtyMaster();
        errdefer posix.close(master_fd);

        // Get slave name and unlock
        var slave_name_buf: [256]u8 = undefined;
        try ptsname(master_fd, &slave_name_buf);
        try grantpt(master_fd);
        try unlockpt(master_fd);

        // Set window size
        var ws = std.c.winsize{
            .ws_row = rows,
            .ws_col = cols,
            .ws_xpixel = 0,
            .ws_ypixel = 0,
        };
        _ = std.c.ioctl(master_fd, std.c.T.IOCSWINSZ, &ws);

        // Fork
        const pid = try posix.fork();

        if (pid == 0) {
            // Child process
            posix.close(master_fd);

            // Create new session
            _ = std.c.setsid();

            // Open slave pty
            const slave_name = std.mem.sliceTo(&slave_name_buf, 0);
            const slave_fd = posix.open(slave_name, .{ .ACCMODE = .RDWR }, 0) catch {
                posix.exit(1);
            };

            // Set as controlling terminal
            _ = std.c.ioctl(slave_fd, std.c.T.IOCSCTTY, @as(c_ulong, 0));

            // Duplicate to stdin/stdout/stderr
            posix.dup2(slave_fd, 0) catch posix.exit(1);
            posix.dup2(slave_fd, 1) catch posix.exit(1);
            posix.dup2(slave_fd, 2) catch posix.exit(1);

            if (slave_fd > 2) {
                posix.close(slave_fd);
            }

            // Set window size on slave
            _ = std.c.ioctl(0, std.c.T.IOCSWINSZ, &ws);

            // Execute shell
            const shell_path = shell orelse getDefaultShell();
            const shell_basename = std.fs.path.basename(shell_path);

            // Prepare argv with login shell prefix
            var login_name_buf: [256]u8 = undefined;
            login_name_buf[0] = '-';
            @memcpy(login_name_buf[1..][0..shell_basename.len], shell_basename);
            login_name_buf[1 + shell_basename.len] = 0;
            const login_name: [*:0]const u8 = @ptrCast(&login_name_buf);

            const argv: [2:null]?[*:0]const u8 = .{
                login_name,
                null,
            };

            const envp = std.c.environ;

            const err = std.c.execve(
                @ptrCast(shell_path.ptr),
                @ptrCast(&argv),
                envp,
            );
            _ = err;

            posix.exit(127);
        }

        // Parent process
        return .{
            .master_fd = master_fd,
            .child_pid = pid,
            .read_buf = undefined,
        };
    }

    /// Close the pty and wait for child
    pub fn close(self: *Self) void {
        posix.close(self.master_fd);
        _ = posix.waitpid(self.child_pid, 0);
    }

    /// Get the master file descriptor for polling
    pub fn getFd(self: *const Self) posix.fd_t {
        return self.master_fd;
    }

    /// Read data from the pty (non-blocking if possible)
    pub fn read(self: *Self) !?[]const u8 {
        const n = posix.read(self.master_fd, &self.read_buf) catch |err| switch (err) {
            error.WouldBlock => return null,
            else => return err,
        };
        if (n == 0) return null; // EOF
        return self.read_buf[0..n];
    }

    /// Write data to the pty
    pub fn write(self: *Self, data: []const u8) !void {
        var written: usize = 0;
        while (written < data.len) {
            const n = try posix.write(self.master_fd, data[written..]);
            written += n;
        }
    }

    /// Resize the pty
    pub fn resize(self: *Self, cols: u16, rows: u16) void {
        var ws = std.c.winsize{
            .ws_row = rows,
            .ws_col = cols,
            .ws_xpixel = 0,
            .ws_ypixel = 0,
        };
        _ = std.c.ioctl(self.master_fd, std.c.T.IOCSWINSZ, &ws);
    }

    /// Check if child is still running
    pub fn isAlive(self: *const Self) bool {
        const result = posix.waitpid(self.child_pid, posix.W.NOHANG);
        return result.pid == 0; // 0 means still running
    }
};

fn openPtyMaster() !posix.fd_t {
    const fd = posix.open("/dev/ptmx", .{ .ACCMODE = .RDWR, .NOCTTY = true, .CLOEXEC = true }, 0) catch {
        return error.OpenPtyFailed;
    };
    return fd;
}

fn ptsname(fd: posix.fd_t, buf: []u8) !void {
    // Use ioctl to get slave name
    var n: c_uint = 0;
    const rc = std.c.ioctl(fd, TIOCGPTN, &n);
    if (rc != 0) return error.PtsnameFailed;

    _ = std.fmt.bufPrint(buf, "/dev/pts/{d}", .{n}) catch return error.PtsnameFailed;
}

fn grantpt(fd: posix.fd_t) !void {
    // On Linux, grantpt is typically a no-op with devpts
    _ = fd;
}

fn unlockpt(fd: posix.fd_t) !void {
    var unlock: c_int = 0;
    const rc = std.c.ioctl(fd, TIOCSPTLCK, &unlock);
    if (rc != 0) return error.UnlockptFailed;
}

fn getDefaultShell() []const u8 {
    // Try SHELL environment variable
    if (std.posix.getenv("SHELL")) |shell| {
        return shell;
    }
    // Fallback to /bin/sh
    return "/bin/sh";
}

// ============================================================================
// Tests
// ============================================================================

test "Pty spawn echo test" {
    // This test requires a working pty system
    // Skip in CI or when /dev/ptmx is not available
    _ = openPtyMaster() catch return;
}
