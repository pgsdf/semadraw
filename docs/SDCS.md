# SDCS

SemaDraw Command Stream Specification v0.1.

## STROKE_RECT

Payload: 36 bytes

Fields: x, y, w, h, stroke_width, r, g, b, a (all f32)

Draws a rectangle outline using the current transform, clip, and blend state.

## SET_BLEND

Payload: 4 bytes

Field: mode (u32)

Modes: 0 SrcOver, 1 Src, 2 Clear, 3 Add

## STROKE_LINE

Payload: 36 bytes

Fields: x1, y1, x2, y2, stroke_width, r, g, b, a (all f32)

v1 limitation: only axis aligned lines are supported (x1 == x2 or y1 == y2). Non axis aligned lines are ignored by the reference renderer.

## SET_STROKE_JOIN

Payload: 4 bytes

Fields: join (u32)

Values:
- 0: Miter
- 1: Bevel

Join state affects subsequent stroke operations.

## SET_STROKE_CAP

Payload: 4 bytes

Fields: cap (u32)

Values:
- 0: Butt
- 1: Square
- 2: Round

Cap state affects subsequent stroke operations.
