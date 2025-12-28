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
* Wayland backend for windowed display

## Next

### Integration
* Remote transport (SDCS streaming over network)

## Later

* (items move here as new features are identified)
