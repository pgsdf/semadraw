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

## In Progress

* Miter limit (miter clamp fallback to bevel)

## Next

### Code Quality

* Code style cleanup (fix indentation inconsistencies in encoder.zig)
* Consistent method visibility and struct organization in encoder module

### Error Reporting

* Enhanced validation error context (file offsets, opcode names, field values)
* Structured error types with diagnostic details for debugging

### Testing Infrastructure

* Fuzzing harness for SDCS parser and validator
* Unit tests for core validation logic
* Error condition test cases (malformed inputs, boundary conditions)
* Cross-platform determinism verification

### Features

* Stroke line v2 (non-axis-aligned lines with proper rasterization)
* BLIT_IMAGE implementation (encoder, replay, tests)
* Curves v1 (quadratic and cubic Bezier)
* Stroke path v1 (polyline with arbitrary segments)
* DRAW_GLYPH_RUN / Text v1 (simple glyph atlas)

## Later

* Deterministic anti-aliasing strategy (coverage masks)
* Performance optimization (SIMD vectorization for rasterization)
* semadrawd service and host bridge
* Vulkan backend
* DRM KMS presentation backend
* Toolkit bridges and remote transport
