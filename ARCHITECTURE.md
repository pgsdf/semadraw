# Architecture

SemaDraw is structured as a semantic system with strict layering.

## Client layer

Applications and toolkits link against libsemadraw.

They do not render pixels.
They construct semantic command streams describing intent.

Examples include filling a rectangle, stroking a path, drawing glyph runs, and blitting an image.

## Semantic core

The semantic core consumes SDCS streams and enforces invariants.

Responsibilities include validation of command streams, surface lifetime management, state tracking, composition, and deterministic ordering.

This layer defines behavior. It does not optimize.

## Backend layer

Backends translate semantic intent into execution.

Examples include a reference software renderer, a Vulkan accelerated renderer, a DRM KMS presentation backend, and host bridges such as X11 or Wayland.

Backends must not alter semantics.
They are interchangeable implementations.

## Key property

No backend specific concept appears in the public API.
