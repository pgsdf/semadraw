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

## In progress

* Miter limit (miter clamp fallback to bevel)

## Next
* Miter limit (miter clamp fallback to bevel)
* Curves v1 (quadratic and cubic)
* Stroke path v1 (polyline)
* Text v1 (simple glyph atlas)

## Later

* Deterministic anti aliasing strategy (coverage masks)
* semadrawd service and host bridge
* Vulkan backend
* DRM KMS presentation backend
* Toolkit bridges and remote transport
