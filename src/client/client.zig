//! SemaDraw Client Library
//!
//! High-level API for connecting to semadrawd and managing surfaces.
//!
//! ## Usage
//!
//! ```zig
//! const client = @import("semadraw_client");
//!
//! // Connect to daemon
//! var conn = try client.Connection.connect(allocator);
//! defer conn.disconnect();
//!
//! // Create a surface
//! var surface = try client.Surface.create(conn, 800, 600);
//! defer surface.destroy();
//!
//! // Show and commit
//! try surface.show();
//! try surface.commit();
//! ```

pub const Connection = @import("connection").Connection;
pub const ConnectionState = @import("connection").ConnectionState;
pub const Event = @import("connection").Event;

pub const Surface = @import("surface").Surface;
pub const SurfaceState = @import("surface").SurfaceState;
pub const SurfaceManager = @import("surface").SurfaceManager;
pub const FrameCallback = @import("surface").FrameCallback;

pub const protocol = @import("protocol");

/// Connect to the daemon using default settings
pub fn connect(allocator: std.mem.Allocator) !*Connection {
    return Connection.connect(allocator);
}

/// Connect to the daemon at a specific socket path
pub fn connectTo(allocator: std.mem.Allocator, socket_path: []const u8) !*Connection {
    return Connection.connectTo(allocator, socket_path);
}

const std = @import("std");

test {
    _ = @import("connection");
    _ = @import("surface");
}
