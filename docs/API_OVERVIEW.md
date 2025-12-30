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
| SET_POSITION | 0x0032 | Set surface position |
| CLIPBOARD_SET | 0x0050 | Set clipboard content |
| CLIPBOARD_REQUEST | 0x0051 | Request clipboard content |
| CLIPBOARD_DATA | 0x9050 | Clipboard data response |
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
    pollEvents: *const fn (ctx: *anyopaque) bool,
    getKeyEvents: ?*const fn (ctx: *anyopaque) []const KeyEvent,
    getMouseEvents: ?*const fn (ctx: *anyopaque) []const MouseEvent,
    setClipboard: ?*const fn (ctx: *anyopaque, selection: u8, text: []const u8) anyerror!void,
    requestClipboard: ?*const fn (ctx: *anyopaque, selection: u8) void,
    getClipboardData: ?*const fn (ctx: *anyopaque, selection: u8) ?[]const u8,
    deinit: *const fn (ctx: *anyopaque) void,
};
```

Current backends:
* `software` - CPU-based reference renderer
* `headless` - No output, for testing
* `kms` - DRM/KMS direct display output (Linux/FreeBSD)
* `x11` - X11 windowed output with clipboard support
* `vulkan` - GPU-accelerated Vulkan renderer
* `wayland` - Wayland windowed output

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

### Clipboard

The client library provides clipboard support for copy/paste operations:

```zig
const client = @import("semadraw_client");

var conn = try client.Connection.connect(allocator);
defer conn.disconnect();

// Set clipboard content (CLIPBOARD selection)
try conn.setClipboard(.clipboard, "Hello, World!");

// Set primary selection (mouse selection)
try conn.setClipboard(.primary, "Selected text");

// Request clipboard content (async)
try conn.requestClipboard(.clipboard);

// Handle clipboard data in event loop
while (try conn.poll()) |event| {
    switch (event) {
        .clipboard_data => |clip| {
            // clip.selection: .clipboard or .primary
            // clip.data: clipboard text content
            std.debug.print("Clipboard: {s}\n", .{clip.data});
        },
        else => {},
    }
}
```

Selection types:
- `.clipboard` - System clipboard (Ctrl+C/V)
- `.primary` - Primary selection (X11 mouse selection)

## Terminal Emulator (semadraw-term)

The terminal emulator demonstrates a complete SDCS client application with text rendering, input handling, and Plan 9-style mouse chording.

### Mouse State Tracking

The terminal tracks mouse button state for chord detection and selection:

```zig
const MouseState = struct {
    left_down: bool = false,
    middle_down: bool = false,
    right_down: bool = false,
    chord_handled: bool = false,  // Prevents repeat actions while held
    // Delayed selection start (preserves existing selection for chords)
    left_press_col: u32 = 0,
    left_press_row: u32 = 0,
    drag_started: bool = false,   // True once user drags past threshold
};
```

**Selection preservation**: When initiating a chord, small mouse movements are ignored (threshold: 2 cells). This prevents accidental selection reset and allows users to chord on existing selections.

### Chord Menu System

Plan 9-style chording displays context menus based on button combinations:

```zig
pub const ChordMenu = struct {
    visible: bool = false,
    menu_type: MenuType = .edit,
    x: i32 = 0,
    y: i32 = 0,
    selected: ?usize = null,

    pub const MenuType = enum {
        edit,   // Left+Middle: Copy, Clear
        paste,  // Left+Right: Paste, Paste Primary
    };

    pub fn show(self: *ChordMenu, px: i32, py: i32, mtype: MenuType) void;
    pub fn hide(self: *ChordMenu) void;
    pub fn getLabels(self: *const ChordMenu) []const []const u8;
    pub fn updateSelection(self: *ChordMenu, px: i32, py: i32) void;
};
```

Chord detection:
- **Left + Middle**: Shows Edit menu (Copy, Clear)
- **Left + Right**: Shows Paste menu (Paste, Paste Primary)
- Menu stays visible while left button is held
- Selection executes on left button release
- Immediate render triggered when menu shown to ensure visibility

### Renderer Overlay

The renderer supports menu overlays for chord menus:

```zig
pub const MenuOverlay = struct {
    x: i32,
    y: i32,
    width: u32,
    height: u32,
    item_height: u32,
    labels: []const []const u8,
    selected_idx: ?usize,
};

// Render with optional menu overlay
pub fn renderWithOverlay(self: *Self, menu: ?MenuOverlay) ![]u8;
```

The overlay is composited on top of the terminal content during rendering, allowing transient UI elements without modifying the screen buffer.
