# Roadmap

This roadmap tracks the incremental execution order used by the golden test suite.
Each feature is implemented end to end (encoder, SDCS, replay, tests, docs) before moving on.

## Completed

* Core container format (SDCS v1) and validator
* Replay tool (software backend) and golden test harness
* Transform 2D
* Clip rects v1
* Blend modes v1 (Src, SrcOver, Multiply, Screen)
* Stroke rect v1 (axis aligned)
* Stroke line v1
* Joins v1 (miter, bevel)
* Caps v1 (butt, square)
* Caps v2 (round)
* Joins v2 (round join)
* Code style cleanup (encoder.zig indentation, struct organization)
* Enhanced validation diagnostics (opcodeName, ValidationDiagnostics, validateFileWithDiagnostics)
* Unit tests for core validation logic (sdcs.zig)
* Malformed input test suite (sdcs_test_malformed)
* Fuzzing harness (sdcs_fuzz with AFL/libFuzzer support)
* Determinism verification in test suite
* Miter limit (SET_MITER_LIMIT opcode, miter-to-bevel fallback for 90° joins)
* Stroke line v2 (non-axis-aligned lines with proper rasterization)
* BLIT_IMAGE implementation (encoder, replay, tests)
* Curves v1 (quadratic and cubic Bezier strokes)
* Stroke path v1 (polyline with arbitrary segments)
* DRAW_GLYPH_RUN / Text v1 (simple glyph atlas)
* Deterministic anti-aliasing (SET_ANTIALIAS opcode, 4x4 sub-pixel coverage sampling)
* AA test suite (sdcs_make_aa test generator with golden hash verification)

### semadrawd daemon
* IPC protocol (Unix domain socket with message framing)
* Client session management with resource limits
* Surface registry (creation, ownership, z-ordering)
* Shared memory buffer attachment
* SDCS validation before execution
* Backend abstraction layer (vtable-based interface)
* Software renderer backend
* Process isolation for backends (fork-based)
* Compositor with damage tracking
* Frame scheduler with vsync timing
* Client library (Connection and Surface wrappers)
* DRM/KMS presentation backend (direct framebuffer output)
* SIMD vectorization for rasterization (SSE/AVX, NEON)
* X11 backend for windowed display
* Vulkan backend (GPU-accelerated rendering with X11 presentation)
* Remote transport (TCP server, inline buffer transfer, remote client library)

### Applications
* Terminal emulator (semadraw-term) for console environment

## Next

### Backends
* Wayland backend for windowed display (implemented, pending testing)

### semadraw-term Improvements

#### Critical (Blocks Basic Functionality)
* ~~Connect keyboard input handling~~ (DONE - full pipeline from X11 backend through daemon to terminal)
* Alternative screen buffer support (required for vim, htop, less, nano)
* Missing VT100 escape sequences (RIS, IND, NEL, HTS, RI, DECSC/DECRC)

#### High Priority (Major Features)
* Scrollback buffer (saved line history above visible window)
* Fix double encoder reset bug in renderer.zig
* Extended character support (currently ASCII 32-126 only, Unicode shows "?")
* OSC escape sequence processing (terminal title, color palette)

#### Medium Priority (Enhancements)
* Mouse input support (tracking, selection, copy/paste)
* Additional SGR codes (strikethrough, overline, double underline)
* Cursor style variations (beam, underline, blinking animation)
* Dirty region tracking (avoid full screen re-render every frame)

#### Performance Optimizations
* Compile-time or cached font atlas generation
* Reuse glyph ArrayList instead of allocating per row
* Cell caching for glyph index lookups
* Optimize screen scrolling with block operations

#### Code Quality
* Remove or connect dead handleKeyPress code
* Replace magic numbers with named constants
* Add logging for silently dropped events
* Terminal state validation improvements

