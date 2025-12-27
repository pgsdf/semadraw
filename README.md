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

Tools produced:

1. sdcs_make_test
2. sdcs_make_transform
3. sdcs_make_clip
4. sdcs_make_blend
5. sdcs_make_overlap
6. sdcs_make_fractional
7. sdcs_make_stroke
8. sdcs_make_line
9. sdcs_make_join
10. sdcs_make_join_round
11. sdcs_make_cap
12. sdcs_make_cap_round
13. sdcs_dump
14. sdcs_replay

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

Early implementation.
The SDCS format is executable and replayable.
The software backend provides deterministic reference behavior.

## License

BSD 2-Clause License

Copyright (c) 2025, Pacific Grove Software Distribution Foundation

## Author

Vester "Vic" Thacker, Principal Scientist, Pacific Grove Software Distribution Foundation

