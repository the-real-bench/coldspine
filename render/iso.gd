class_name Iso
## Isometric projection helpers (ART_BIBLE §7): 2:1 diamond, 128×64 logical tile.
## Pure math — no SceneTree deps so the smoke test can call it headless.
##
## Screen layout: tile (gx,gy) maps to the CENTER of its diamond. The Y projection is
## FLIPPED so the forward/Engine direction (+x) climbs UP the screen: neighbours in +x
## go UP-right, +y go UP-left. The squad (low-x tail) therefore enters from the BOTTOM
## of the screen and advances UPWARD toward the Engine (high-x). Standard 2:1 iso lozenge
## grid; the whole field is offset by `origin` (world-space anchor of tile (0,0)'s center).

const TILE_W: int = 128   # diamond footprint width  (ART_BIBLE §7)
const TILE_H: int = 64    # diamond footprint height (2:1)
const HALF_W: float = 64.0
const HALF_H: float = 32.0

## Grid cell (Vector2i) -> screen-space center of that tile's diamond.
static func tile_to_screen(cell: Vector2i, origin: Vector2 = Vector2.ZERO) -> Vector2:
	var sx: float = (cell.x - cell.y) * HALF_W
	var sy: float = -(cell.x + cell.y) * HALF_H   # flipped: +x/+y climb UP the screen (forward = up)
	return origin + Vector2(sx, sy)

## Screen-space point -> grid cell whose diamond contains it (inverse projection).
## Rounded to the nearest cell; callers should bounds-check the result.
static func screen_to_tile(point: Vector2, origin: Vector2 = Vector2.ZERO) -> Vector2i:
	var p: Vector2 = point - origin
	# Exact inverse of the flipped tile_to_screen (sy = -(x+y)*HALF_H).
	var fx: float = (p.x / HALF_W - p.y / HALF_H) * 0.5
	var fy: float = (-p.x / HALF_W - p.y / HALF_H) * 0.5
	return Vector2i(int(round(fx)), int(round(fy)))

## The four corner points of a tile's diamond (top, right, bottom, left) in screen
## space — used to draw floor polygons procedurally when no texture is present.
static func diamond_points(cell: Vector2i, origin: Vector2 = Vector2.ZERO) -> PackedVector2Array:
	var c: Vector2 = tile_to_screen(cell, origin)
	return PackedVector2Array([
		c + Vector2(0, -HALF_H),   # top
		c + Vector2(HALF_W, 0),    # right
		c + Vector2(0, HALF_H),    # bottom
		c + Vector2(-HALF_W, 0),   # left
	])

## Pixel size of the whole field for a w×h grid (used to center the camera). The
## iso field spans (w+h) half-widths across and (w+h) half-heights tall.
static func field_size(w: int, h: int) -> Vector2:
	return Vector2((w + h) * HALF_W, (w + h) * HALF_H)

## World-space origin that centers a w×h grid inside a viewport of `view` pixels.
## With the FLIPPED Y projection, tile(0,0) sits at the BOTTOM apex and (w-1,h-1) at the top;
## this shifts the field so its bbox stays centered.
static func centering_origin(w: int, h: int, view: Vector2) -> Vector2:
	# Field x ranges [-(h-1)*HALF_W .. (w-1)*HALF_W]; flipped y ranges [-(w+h-2)*HALF_H .. 0].
	var min_x: float = -float(h - 1) * HALF_W
	var max_x: float = float(w - 1) * HALF_W
	var span_x: float = (max_x - min_x) + TILE_W
	var span_y: float = float(w + h - 1) * HALF_H + TILE_H
	var ox: float = (view.x - span_x) * 0.5 - min_x + HALF_W
	# Y is flipped (forward climbs up), so the field now occupies NEGATIVE sy; push the origin down
	# by the field's sy-span so the bottom-anchored field stays centered in the viewport.
	var oy: float = (view.y - span_y) * 0.5 + HALF_H + float(w + h - 2) * HALF_H
	return Vector2(ox, oy)
