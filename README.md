# SemaDraw

SemaDraw is a semantic graphics foundation for FreeBSD.

It defines graphics as a deterministic, resolution independent system based on meaning rather than pixels, GPU APIs, or display servers.

SemaDraw sits above kernel graphics subsystems and below toolkits and environments. It provides a stable semantic contract that remains valid even as hardware, drivers, and rendering backends evolve.

SemaDraw is not a window system.
SemaDraw is not a toolkit.
SemaDraw is a foundation.

## Core ideas

1. Graphics are semantic operations, not pixel pipelines
2. Resolution independence is mandatory, not optional
3. Rendering must be deterministic and inspectable
4. Meaning is separated from acceleration
5. The same command stream can be replayed locally, remotely, or headless

## Components

1. libsemadraw  
   Zig module used by applications and toolkits to construct semantic command streams

2. SDCS  
   SemaDraw Command Stream, the canonical binary representation of graphics intent

3. semadrawd  
   Userland service responsible for surface ownership, composition, and presentation

4. Backends  
   Software, Vulkan, DRM KMS, and host bridges

5. Tooling
   Command recording, dumping, replay, and golden image testing

6. Applications
   Terminal emulator (semadraw-term), graphics demo (semadraw-demo)

## Build

Requires Zig 0.15 or newer.

```sh
zig build
zig build test
```

Tools and libraries produced:

1. libsemadraw_client.a - Client library for connecting to semadrawd
2. semadrawd - Compositor daemon
3. sdcs_dump - SDCS file inspector
4. sdcs_replay - Software renderer
5. sdcs_make_demo - Demo showcase generator
6. sdcs_make_* - Various test generators
7. semadraw-term - VT100 terminal emulator
8. semadraw-demo - Animated graphics demo

Rendering options supported by the encoder and replay tool:

* StrokeJoin: 0 = Miter, 1 = Bevel, 2 = Round
* StrokeCap: 0 = Butt, 1 = Square, 2 = Round

## Installation

### Prerequisites

**Required:**
- Zig 0.15 or newer
- POSIX-compatible OS (FreeBSD, Linux)
- C library (libc)

**Optional (for specific backends):**
- X11: libX11, libXext (for X11 backend)
- Vulkan: Vulkan SDK, libvulkan (for GPU-accelerated rendering)
- Wayland: libwayland-client (for Wayland backend)
- DRM/KMS: Linux kernel with DRM support (for console output)

### Build from Source

```sh
# Clone the repository
git clone https://github.com/pgsdf/semadraw.git
cd semadraw

# Build all components
zig build

# Run tests
zig build test
```

### Install

```sh
# Install to /usr/local (default)
sudo zig build install --prefix /usr/local

# Or install to custom location
zig build install --prefix ~/.local
```

This installs:
- `/usr/local/bin/semadrawd` - Compositor daemon
- `/usr/local/bin/semadraw-term` - Terminal emulator
- `/usr/local/bin/semadraw-demo` - Animated graphics demo
- `/usr/local/bin/sdcs_dump` - SDCS file inspector
- `/usr/local/bin/sdcs_replay` - Software renderer
- `/usr/local/lib/libsemadraw_client.a` - Client library

**Create socket directory (if using default socket path):**

```sh
sudo mkdir -p /var/run/semadraw
sudo chmod 755 /var/run/semadraw
```

## Demo

Generate and view a 1280x1080 showcase of SemaDraw capabilities:

```sh
sdcs_make_demo /tmp/demo.sdcs
sdcs_replay /tmp/demo.sdcs /tmp/demo.ppm 1280 1080
feh /tmp/demo.ppm
```

The demo showcases:

* Anti-aliased Bezier curves (cubic and quadratic)
* Stroked paths with round and miter joins
* Overlapping rectangles with alpha transparency
* Additive blend mode for glow effects
* Diagonal lines with smooth edges
* AA vs non-AA comparison

## Run Tests

```sh
bash tests/run.sh
```

This runs unit tests, malformed input validation, golden image tests, and determinism verification.

## Status

Active development.

The SDCS format is executable and replayable.
The software backend provides deterministic reference behavior.

The semadrawd compositor daemon is functional with:
* Unix socket IPC with binary protocol
* Client session management with resource limits
* Surface registry with z-ordering
* Damage tracking and frame scheduling
* Backend abstraction with process isolation
* DRM/KMS backend for direct display output

## Usage Guide

### Console Use (DRM/KMS) - Linux

For running SemaDraw directly on the Linux console without X11 or Wayland (CPU rendering):

```sh
# Switch to a virtual console (Ctrl+Alt+F2) or boot without display manager

# Start semadrawd with KMS backend (requires root or video group membership)
sudo semadrawd --backend kms

# In another terminal/session, run the terminal emulator
semadraw-term
```

**Requirements:**
- Linux kernel with DRM support
- Access to `/dev/dri/card0` (usually requires root or `video` group)
- Access to `/dev/input/event*` for keyboard and mouse (root or `input` group)
- No active X11/Wayland session on the target display

**Input Support:**
- Keyboard and mouse input via evdev (`/dev/input/event*`)
- Mouse chording and text selection work the same as X11/Wayland
- Automatic detection of keyboard and mouse devices

**Notes:**
- The KMS backend takes exclusive control of the display
- Use Ctrl+Alt+F1 to return to your previous console
- For multi-monitor setups, the first available display is used
- If input doesn't work, ensure user is in the `input` group: `sudo usermod -aG input $USER`

### Console Use (Vulkan Console) - Linux & FreeBSD

For GPU-accelerated console rendering without X11 or Wayland:

```sh
# Switch to a virtual console (Ctrl+Alt+F2) or boot without display manager

# Start semadrawd with Vulkan console backend
sudo semadrawd --backend vulkan_console

# In another terminal/session, run the terminal emulator
semadraw-term
```

**Requirements:**
- Vulkan-capable GPU with VK_KHR_display extension support
- Vulkan SDK and drivers installed
- No active X11/Wayland session on the target display
- Root privileges or appropriate device permissions

**Linux Input:**
- Keyboard and mouse via evdev (`/dev/input/event*`)
- Requires root or `input` group membership

**FreeBSD Input:**
- Mouse via sysmouse (`/dev/sysmouse`) - requires `moused` daemon
- Keyboard via `/dev/kbdmux0`, `/dev/ukbd0`, or `/dev/atkbd0`

**FreeBSD Setup:**
```sh
# Ensure moused is running for mouse input
sudo service moused start

# Add to /etc/rc.conf to start on boot:
# moused_enable="YES"

# Start semadrawd
sudo semadrawd --backend vulkan_console
```

**Notes:**
- Uses VK_KHR_display for direct display output (no windowing system)
- GPU-accelerated rendering with CPU-based SDCS execution
- Input is optional - backend works without input devices for testing
- If input fails to initialize, rendering still works

### X11 Use

For running SemaDraw as a window inside an X11 session:

```sh
# Start semadrawd with X11 backend
semadrawd --backend x11

# Run the terminal emulator (in another terminal)
semadraw-term
```

**For GPU-accelerated rendering with Vulkan:**

```sh
# Start with Vulkan backend (requires Vulkan-capable GPU)
semadrawd --backend vulkan

# Run the terminal emulator
semadraw-term
```

**Requirements:**
- Running X11 session
- DISPLAY environment variable set
- For Vulkan: Vulkan SDK and compatible GPU drivers

### Wayland Use

For running SemaDraw as a window inside a Wayland session:

```sh
# Start semadrawd with Wayland backend
semadrawd --backend wayland

# Run the terminal emulator (in another terminal)
semadraw-term
```

**Requirements:**
- Running Wayland compositor (Sway, GNOME Wayland, KDE Wayland, etc.)
- WAYLAND_DISPLAY environment variable set
- libwayland-client

### Quick Start Examples

**Example 1: Terminal on X11**
```sh
# Terminal 1: Start daemon
semadrawd --backend x11

# Terminal 2: Run terminal emulator with custom size
semadraw-term --cols 120 --rows 40 --shell /bin/bash
```

**Example 2: Terminal on Wayland**
```sh
# Terminal 1: Start daemon
semadrawd --backend wayland

# Terminal 2: Run terminal
semadraw-term
```

**Example 3: Graphics demo on X11**
```sh
# Terminal 1: Start daemon
semadrawd --backend x11

# Terminal 2: Run animated graphics demo
semadraw-demo
```

**Example 4: GPU-accelerated on X11 (Vulkan)**
```sh
# Terminal 1: Start daemon with Vulkan acceleration
semadrawd --backend vulkan

# Terminal 2: Run terminal
semadraw-term
```

**Example 5: GPU-accelerated console (no X11/Wayland)**
```sh
# From a virtual console (Ctrl+Alt+F2)
# Requires: no display server running, Vulkan drivers

# Start daemon with Vulkan console backend
sudo semadrawd --backend vulkan_console

# In another session, run terminal
semadraw-term
```

**Example 6: FreeBSD console**
```sh
# Ensure moused is running
sudo service moused start

# Start with Vulkan console
sudo semadrawd --backend vulkan_console

# Run terminal
semadraw-term
```

**Example 7: Headless testing**
```sh
# Start headless (no display output)
semadrawd --backend headless

# Connect terminal for testing
semadraw-term
```

## semadrawd Reference

Start the compositor daemon:

```sh
semadrawd [OPTIONS]
```

**Options:**

| Option | Description |
|--------|-------------|
| `-b, --backend TYPE` | Backend: software, headless, kms, x11, vulkan, vulkan_console, wayland |
| `-s, --socket PATH` | Unix socket path (default: /var/run/semadraw/semadraw.sock) |
| `-t, --tcp PORT` | Enable TCP server on PORT for remote connections |
| `--tcp-addr ADDR` | Bind TCP to specific address (default: 0.0.0.0) |
| `-h, --help` | Show help |

**Backend Comparison:**

| Backend | Acceleration | Display | Platform | Use Case |
|---------|-------------|---------|----------|----------|
| software | CPU | Varies | Any | Reference, debugging |
| headless | CPU | None | Any | Testing, CI/CD |
| kms | CPU | Console | Linux | Framebuffer, embedded |
| x11 | CPU | X11 Window | Linux, FreeBSD | Desktop development |
| vulkan | GPU | X11 Window | Linux, FreeBSD | High performance (X11) |
| vulkan_console | GPU | Console | Linux, FreeBSD | High performance (no X11) |
| wayland | CPU | Wayland Window | Linux | Wayland desktops |

### Remote Connections

semadrawd supports TCP connections for remote SDCS streaming:

```sh
# Enable TCP on port 7234
semadrawd --backend x11 --tcp 7234

# Bind to specific address
semadrawd --tcp 7234 --tcp-addr 192.168.1.100
```

Remote clients use inline buffer transfer instead of shared memory.

## semadraw-term Reference

Terminal emulator for running shell sessions:

```sh
semadraw-term [OPTIONS]
```

**Options:**

| Option | Description |
|--------|-------------|
| `-c, --cols N` | Terminal columns (default: 80) |
| `-r, --rows N` | Terminal rows (default: 24) |
| `-e, --shell PATH` | Shell to execute (default: $SHELL or /bin/sh) |
| `-s, --socket PATH` | Daemon socket path |
| `-h, --help` | Show help |

**Features:**
- VT100/ANSI escape sequence support
- Full UTF-8 with wide character handling (CJK double-width)
- 256-color palette with RGB extensions (OSC 4/10/11)
- Mouse tracking (X10, VT200, SGR, URXVT modes)
- Alternative screen buffer (vim, htop, less, nano)
- Scrollback buffer with Shift+PageUp/PageDown navigation
- Cursor styles (block, underline, bar) with blink support
- Box drawing characters (U+2500-U+257F)
- Text decorations (bold, italic, underline, strikethrough)
- Text selection with mouse (click and drag)

**Keyboard shortcuts:**
- Ctrl+Shift+C: Copy selection to system clipboard
- Ctrl+Shift+V: Paste from system clipboard
- Shift+PageUp: Scroll up in history
- Shift+PageDown: Scroll down in history

**Mouse:**
- Left click and drag: Select text (highlighted with inverted colors)
- Left release: Copies selection to PRIMARY clipboard
- Middle click: Paste from PRIMARY clipboard

**Plan 9-style mouse chording with menus:**
- Hold left button, then press middle or right to show a chord menu
- Move mouse to highlight an option, release left to execute
- Text selection is preserved when initiating a chord (small movements ignored)

**Left + Middle chord** (Edit menu):
- Copy: Copy selection to system clipboard
- Clear: Clear the current selection

**Left + Right chord** (Paste menu):
- Paste: Paste from system clipboard
- Paste Primary: Paste from X11 PRIMARY selection

**Chord workflow example:**
1. Select text by dragging with left button
2. Release left button (selection stays highlighted)
3. Press and hold left button again
4. Press middle button to show Edit menu
5. Move to highlight "Copy", release left to copy

The menu stays open while left button is held, allowing easy selection.

## semadraw-demo Reference

Animated graphics demonstration:

```sh
semadraw-demo [OPTIONS]
```

**Options:**

| Option | Description |
|--------|-------------|
| `-s, --socket PATH` | Daemon socket path |
| `-h, --help` | Show help |

**Features:**
- Real-time animated graphics using SemaDraw API
- Rotating bezier curves with rainbow colors
- Orbiting shapes with alpha blending
- Pulsing center with additive blend mode
- Anti-aliased rendering

**Controls:**
- ESC or Q: Quit the demo
- Close window: Quit the demo

This demo showcases SemaDraw's immediate-mode graphics API including:
- Quadratic bezier curves
- Alpha blending and additive blending
- Anti-aliased rendering
- Real-time animation at ~30 FPS
- Resolution-independent graphics

## License

BSD 2-Clause License

Copyright (c) 2025, Pacific Grove Software Distribution Foundation

## Author

Vester "Vic" Thacker, Principal Scientist, Pacific Grove Software Distribution Foundation

