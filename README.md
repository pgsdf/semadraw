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

Rendering options supported by the encoder and replay tool:

* StrokeJoin: 0 = Miter, 1 = Bevel, 2 = Round
* StrokeCap: 0 = Butt, 1 = Square, 2 = Round

## Demo

Generate and view a 1280x1080 showcase of SemaDraw capabilities:

```sh
./zig-out/bin/sdcs_make_demo /tmp/demo.sdcs
./zig-out/bin/sdcs_replay /tmp/demo.sdcs /tmp/demo.ppm 1280 1080
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

## semadrawd Usage

Start the compositor daemon:

```sh
# Default (software backend)
./zig-out/bin/semadrawd

# With DRM/KMS backend for direct display
./zig-out/bin/semadrawd --backend kms

# Custom socket path
./zig-out/bin/semadrawd --socket /tmp/mysocket.sock

# Verbose logging
./zig-out/bin/semadrawd --verbose
```

Available backends:
* `software` - CPU-based reference renderer (default)
* `headless` - No output, for testing
* `kms` - DRM/KMS direct framebuffer output (Linux/FreeBSD)
* `x11` - X11 windowed output

The daemon listens on `/var/run/semadraw/semadraw.sock` by default.

## License

BSD 2-Clause License

Copyright (c) 2025, Pacific Grove Software Distribution Foundation

## Author

Vester "Vic" Thacker, Principal Scientist, Pacific Grove Software Distribution Foundation

