class_name PreviewGhost
extends RefCounted
## The §6.7 deterministic preview. Given a candidate physics action (entity, dir,
## force) it runs PhysicsResolver.resolve_impulse(dry_run=true) — the SAME function
## that commits — and produces an overlay describing where everything ends up, what
## breaks, who goes Prone, and the hazards it spawns.
##
## INVARIANT (ART_BIBLE §6.7 / GDD invariant #2): the dry-run result is byte-identical
## to the commit's, because the resolver always runs on a clone. `result_state` here
## IS what the commit will adopt. Overlay opacity ≤50%, and it NEVER uses alarm-red
## (that hue is reserved for live danger) so "what WILL happen" never reads as "what
## IS happening."

const E = preload("res://core/sim_enums.gd")
const Iso = preload("res://render/iso.gd")
const Pal = preload("res://render/palette.gd")
const Physics = preload("res://core/physics_resolver.gd")

const MAX_OPACITY: float = 0.5

var active: bool = false
var origin: Vector2 = Vector2.ZERO

# Computed preview payload (also the data the smoke test inspects):
var result_events: Array = []        # the dry-run event timeline (== commit's)
var result_state = null              # the resolved clone (== what commit adopts)
var trajectory: Array = []           # Array[Vector2i] tiles the actor traversed
var end_positions: Dictionary = {}   # entity id -> Vector2i final cell (predicted)
var impacts: Array = []              # Array[Vector2i] collision/impact cells
var broken: Array = []               # Array[Vector2i] cells where an object shattered
var flooded: Array = []              # Array[Vector2i] cells that gain water
var prone_ids: Array = []            # ids knocked Prone by this action
var faction_tint: Color = Pal.FAC_PLAYER


## Compute the preview from the LIVE state (never mutates it — resolver clones).
func compute(live_state, entity_id: int, dir: Vector2i, force: int, tint: Color = Pal.FAC_PLAYER) -> void:
	faction_tint = tint
	origin_from(live_state)
	var res = Physics.resolve_impulse(live_state, entity_id, dir, force, true)
	result_events = res.events
	result_state = res.state
	_extract(live_state, entity_id, res)
	active = true

func origin_from(_live_state) -> void:
	# origin is set by the owner (it knows the view); kept here for completeness.
	pass

func _extract(live_state, entity_id: int, res) -> void:
	trajectory.clear(); end_positions.clear(); impacts.clear()
	broken.clear(); flooded.clear(); prone_ids.clear()
	# Trajectory: every MOVE_STEP for the prime actor, in order.
	for ev in res.events:
		match ev.type:
			E.Ev.MOVE_STEP:
				if ev.data.get("id", -1) == entity_id:
					trajectory.append(ev.data.get("to"))
			E.Ev.IMPACT_WALL, E.Ev.COLLIDE_BODY:
				var who: int = ev.data.get("id", ev.data.get("a_id", -1))
				if res.state.entities.has(who):
					impacts.append(res.state.entities[who].pos)
			E.Ev.OBJECT_BREAK:
				broken.append(ev.data.get("pos"))
			E.Ev.FLOOD_TILE:
				flooded.append(ev.data.get("pos"))
			E.Ev.STATUS_APPLY:
				if ev.data.get("status", 0) == E.S_PRONE:
					var pid: int = ev.data.get("id", -1)
					if not prone_ids.has(pid):
						prone_ids.append(pid)
	# Predicted end positions for every entity that still exists post-resolve.
	for id in res.state.entity_ids_sorted():
		end_positions[id] = res.state.entities[id].pos

func clear() -> void:
	active = false
	result_events = []
	result_state = null
	trajectory.clear(); end_positions.clear(); impacts.clear()
	broken.clear(); flooded.clear(); prone_ids.clear()

## Draw the overlay onto a CarView (called from CarView._draw via preview hook).
## Everything is faction-tinted, ≤50% opacity, never alarm-red.
func draw_into(view) -> void:
	if not active:
		return
	origin = view.origin
	var faint := faction_tint
	faint.a = MAX_OPACITY
	# 1. Trajectory: dotted line along the travel vector.
	if trajectory.size() > 0:
		var prev: Vector2 = _start_center(view)
		for cell in trajectory:
			var c: Vector2 = Iso.tile_to_screen(cell, origin)
			_dotted(view, prev, c, faint)
			prev = c
	# 2. Spawned-hazard fill (faded water where the flood lands).
	var water := Pal.L_WATER; water.a = 0.30
	for cell in flooded:
		view.draw_colored_polygon(Iso.diamond_points(cell, origin), water)
	# 3. Impact-star markers at collisions.
	for cell in impacts:
		_impact_star(view, Iso.tile_to_screen(cell, origin), faint)
	# 4. Break markers.
	var brk := Pal.DIM; brk.a = MAX_OPACITY
	for cell in broken:
		_x_mark(view, Iso.tile_to_screen(cell, origin), brk)
	# 5. Ghost tokens at predicted end positions (translucent ring).
	var ghost := faction_tint; ghost.a = 0.35
	for id in end_positions.keys():
		var cell: Vector2i = end_positions[id]
		var c: Vector2 = Iso.tile_to_screen(cell, origin)
		view.draw_arc(c, 40.0, 0, TAU, 40, ghost, 3.0)
		if prone_ids.has(id):
			# tiny inline 'prone' tell (amber-tan chevron), still ≤50% opacity.
			var pcol := Pal.STATUS_PRONE; pcol.a = MAX_OPACITY
			view.draw_line(c + Vector2(-12, -4), c + Vector2(0, 8), pcol, 3.0)
			view.draw_line(c + Vector2(0, 8), c + Vector2(12, -4), pcol, 3.0)

func _start_center(view) -> Vector2:
	# best-effort: the first trajectory tile minus one step is unknown here, so anchor
	# the dotted line at the first traversed cell.
	return Iso.tile_to_screen(trajectory[0], view.origin)

func _dotted(view, a: Vector2, b: Vector2, col: Color) -> void:
	var n := 8
	for i in range(n):
		if i % 2 == 0:
			var t0: float = float(i) / n
			var t1: float = float(i + 1) / n
			view.draw_line(a.lerp(b, t0), a.lerp(b, t1), col, 2.5)

func _impact_star(view, c: Vector2, col: Color) -> void:
	for k in range(4):
		var ang: float = deg_to_rad(45.0 * k)
		var d: Vector2 = Vector2(cos(ang), sin(ang)) * 12.0
		view.draw_line(c - d, c + d, col, 2.5)

func _x_mark(view, c: Vector2, col: Color) -> void:
	view.draw_line(c + Vector2(-10, -10), c + Vector2(10, 10), col, 2.5)
	view.draw_line(c + Vector2(-10, 10), c + Vector2(10, -10), col, 2.5)
