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

## BLIT_IMAGE

Payload: 16 + (img_w × img_h × 4) bytes

Fields:
- dst_x, dst_y (f32): destination position
- img_w, img_h (u32): image dimensions in pixels
- pixels: RGBA pixel data (img_w × img_h × 4 bytes)

Blits an RGBA image at the specified destination position.
The image is drawn at 1:1 scale, affected by the current transform, clip, and blend state.
Transparent pixels (alpha = 0) are skipped.
