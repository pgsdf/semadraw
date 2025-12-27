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

v2: supports arbitrary angle lines with proper oriented quad rasterization.

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

## STROKE_QUAD_BEZIER

Payload: 44 bytes

Fields: x0, y0, cx, cy, x1, y1, stroke_width, r, g, b, a (all f32)

Strokes a quadratic Bezier curve from (x0,y0) through control point (cx,cy) to (x1,y1).
The curve is affected by the current transform, clip, and blend state.

## STROKE_CUBIC_BEZIER

Payload: 52 bytes

Fields: x0, y0, cx1, cy1, cx2, cy2, x1, y1, stroke_width, r, g, b, a (all f32)

Strokes a cubic Bezier curve from (x0,y0) through control points (cx1,cy1) and (cx2,cy2) to (x1,y1).
The curve is affected by the current transform, clip, and blend state.

## BLIT_IMAGE

Payload: 16 + (img_w × img_h × 4) bytes

Fields:
- dst_x, dst_y (f32): destination position
- img_w, img_h (u32): image dimensions in pixels
- pixels: RGBA pixel data (img_w × img_h × 4 bytes)

Blits an RGBA image at the specified destination position.
The image is drawn at 1:1 scale, affected by the current transform, clip, and blend state.
Transparent pixels (alpha = 0) are skipped.

## STROKE_PATH

Payload: 24 + (N × 8) bytes

Fields:
- stroke_width (f32): line thickness in pixels
- r, g, b, a (f32): stroke color
- point_count (u32): number of points in the path (N)
- points: N × (x, y) pairs as f32

Strokes a polyline path connecting all points in sequence.
The path is affected by the current transform, clip, blend state, join mode, and cap mode.
Joins are applied between consecutive segments; caps are applied at the endpoints.
