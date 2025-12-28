# API overview

The Zig module exposes a small semantic API and SDCS helpers.

## SDCS Encoding

The primary entry point for stream creation is `semadraw.Encoder`.

```zig
const encoder = try Encoder.init(allocator);
defer encoder.deinit();

try encoder.fillRect(x, y, w, h, color);
try encoder.strokeRect(x, y, w, h, color, stroke_width);

const sdcs_data = try encoder.finalize();
```

## IPC Protocol

Clients communicate with semadrawd via Unix domain sockets.

### Message format

All messages use a 16-byte header:

| Offset | Size | Field |
|--------|------|-------|
| 0 | 4 | Magic (0x53454D41) |
| 4 | 2 | Message type |
| 6 | 2 | Flags |
| 8 | 4 | Payload length |
| 12 | 4 | Reserved |

### Message types

| Type | Value | Description |
|------|-------|-------------|
| HELLO | 0x0001 | Client handshake |
| HELLO_REPLY | 0x0002 | Server handshake response |
| CREATE_SURFACE | 0x0010 | Create a new surface |
| DESTROY_SURFACE | 0x0011 | Destroy a surface |
| COMMIT | 0x0020 | Commit surface contents |
| FRAME_COMPLETE | 0x0021 | Frame rendered notification |
| SET_VISIBLE | 0x0030 | Set surface visibility |
| SET_Z_ORDER | 0x0031 | Set surface stacking order |
| ERROR | 0x00FF | Error response |

### Shared memory

SDCS data is passed via shared memory buffers:

1. Client creates shm region with `shm_open()`
2. Client writes SDCS data to the region
3. Client sends FD to daemon via `SCM_RIGHTS`
4. Daemon maps and validates the SDCS data
5. Daemon renders to its output

## Backend Interface

Backends implement a vtable interface:

```zig
pub const VTable = struct {
    getCapabilities: *const fn (ctx: *anyopaque) Capabilities,
    initFramebuffer: *const fn (ctx: *anyopaque, config: FramebufferConfig) anyerror!void,
    render: *const fn (ctx: *anyopaque, request: RenderRequest) anyerror!RenderResult,
    getPixels: *const fn (ctx: *anyopaque) ?[]u8,
    resize: *const fn (ctx: *anyopaque, width: u32, height: u32) anyerror!void,
    deinit: *const fn (ctx: *anyopaque) void,
};
```

Current backends:
* `software` - CPU-based reference renderer
* `headless` - No output, for testing

## Client Library

The `semadraw_client` library provides a high-level API for applications.

### Connection

```zig
const client = @import("semadraw_client");

// Connect to daemon
var conn = try client.Connection.connect(allocator);
defer conn.disconnect();

// Create a surface
const surface_id = try conn.createSurface(800, 600);

// Set visibility and commit
try conn.setVisible(surface_id, true);
try conn.commit(surface_id);

// Poll for events
while (try conn.poll()) |event| {
    switch (event) {
        .frame_complete => |fc| {
            // Frame was presented
        },
        .disconnected => break,
        else => {},
    }
}
```

### Surface Wrapper

```zig
const client = @import("semadraw_client");

var conn = try client.Connection.connect(allocator);
defer conn.disconnect();

// Create surface with wrapper
var surface = try client.Surface.create(conn, 800, 600);
defer surface.destroy();

// Set frame callback for animation
surface.setFrameCallback(struct {
    fn callback(s: *client.Surface, frame: u64, ts: u64) void {
        // Render next frame
        _ = s;
        _ = frame;
        _ = ts;
    }
}.callback);

try surface.show();
try surface.commit();
```

### Surface Manager

```zig
var manager = client.SurfaceManager.init(conn);
defer manager.deinit();

var surface1 = try manager.createSurface(400, 300);
var surface2 = try manager.createSurface(400, 300);

// Process events and dispatch to surfaces
try manager.processEvents();
```
