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

## semadrawd daemon

The daemon is the central authority for surface management and composition.

### IPC layer
* Unix domain socket at `/var/run/semadraw/semadraw.sock`
* Binary message protocol with 16-byte headers
* FD passing for shared memory buffers

### Client sessions
* Per-client resource tracking and limits
* Surface ownership enforcement
* Automatic cleanup on disconnect

### Surface registry
* Unique surface IDs across all clients
* Z-order management for composition
* Visibility and position tracking

### Compositor
* Damage tracking with region accumulation
* Frame scheduling with vsync alignment
* Adaptive refresh rate based on performance

### Backend abstraction
* Vtable-based interface for backend implementations
* Process isolation via fork for untrusted backends
* Software renderer as reference implementation

## Backend layer

Backends translate semantic intent into execution.

Examples include a reference software renderer, a Vulkan accelerated renderer, a DRM KMS presentation backend, and host bridges such as X11 or Wayland.

Backends must not alter semantics.
They are interchangeable implementations.

## Key property

No backend specific concept appears in the public API.
