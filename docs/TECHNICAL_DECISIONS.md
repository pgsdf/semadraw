# Technical Decisions


## Stroke decomposition in reference renderer

The reference renderer implements STROKE_RECT by decomposing the stroke into four filled rectangles. This reuses the fill path so clipping, blending, and transforms behave consistently.


## STROKE_LINE v1 axis aligned constraint

STROKE_LINE is introduced with an axis aligned constraint to keep reference semantics simple and deterministic. Arbitrary angles will be supported after path primitives are introduced.


## Stroke join as protocol state

Join style is represented as an explicit state opcode (SET_STROKE_JOIN) to keep stroke geometry deterministic across backends.


## Stroke cap as protocol state

Cap style is represented as an explicit state opcode (SET_STROKE_CAP) to keep stroke endpoint geometry deterministic across backends.


## Round cap rasterization

Round caps are rasterized in the replay tool using an ellipse test derived from the current affine transform. This keeps the semantic result deterministic without depending on an external graphics backend.
