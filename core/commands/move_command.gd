class_name MoveCommand
extends Command
## Walk the actor along an orthogonal path of tiles (GDD §5.2 — 1 AP, does NOT
## end the turn; a unit may Move twice = Dash). Path is validated to be within the
## unit's Move range, each step orthogonal, passable (FLOOR, no WALL), and
## unoccupied. Updates tile occupancy (clear old, set new) + entity pos, emitting
## one MOVE event per step.
##
## Standing up from Prone is a Move-adjacent action: pass `path = []` with
## `stand_up = true` to clear S_PRONE for 1 AP and emit STAND_UP instead of moving.

const MOVE_RANGE: int = E.MOVE_RANGE
const OverwatchSystem = preload("res://core/overwatch_system.gd")

var path: Array = []          # Array[Vector2i]: ordered destination tiles (not incl. start)
var stand_up: bool = false    # if true, this is a stand-from-prone action

## The unit's EFFECTIVE Move range: authored stats.move (stamped on the SimEntity at
## spawn; E.MOVE_RANGE when unset) + timed buffs (Warcry) + the car's Cramped modifier.
## Shared with the reach overlay / path preview so preview == commit exactly.
static func move_range_of(state, e) -> int:
	var mr: int = e.move_range if e.move_range > 0 else E.MOVE_RANGE
	mr += e.move_buff + state.move_mod
	return max(1, mr)

func _init(p_actor_id: int = -1, p_path: Array = [], p_stand_up: bool = false) -> void:
	super(p_actor_id)
	path = p_path
	stand_up = p_stand_up
	ap_cost = 1
	ends_turn = false

func validate(state, _turn) -> Dictionary:
	var e = state.entities.get(actor_id)
	if e == null or not e.alive:
		return _fail("actor missing or dead")
	if not e.is_unit:
		return _fail("only units move")

	if stand_up:
		if not e.has_status(E.S_PRONE):
			return _fail("not prone")
		return _ok()

	# Anchored / immovable units (a Sentry Turret, move 0) NEVER walk — they fire or hold.
	# A hard guard at the command layer (W2-2) so no AI profile or future caller can emit a
	# MOVE for a bolted-down unit; physics can't displace it either (STATIC_DESTRUCTIBLE).
	if not e.movable:
		return _fail("anchored / immovable unit cannot move")

	if path.is_empty():
		return _fail("empty path")
	if e.has_status(E.S_PRONE):
		return _fail("prone: must stand up first")
	if path.size() > move_range_of(state, e):
		return _fail("path exceeds Move range")

	var prev: Vector2i = e.pos
	for step in path:
		var d: Vector2i = step - prev
		if abs(d.x) + abs(d.y) != 1:
			return _fail("non-orthogonal / non-adjacent step")
		if not state.in_bounds(step):
			return _fail("step out of bounds")
		var t = state.tile(step)
		if t.terrain == E.Terrain.WALL:
			return _fail("step into wall")
		if t.hazard == E.Hazard.GAP:
			return _fail("step into gap")
		var occ = state.occupant_at(step)
		if occ != null and occ.id != actor_id:
			return _fail("step into occupied tile")
		prev = step
	return _ok()

func execute(state, _turn) -> Array:
	var events: Array = []
	var e = state.entities.get(actor_id)
	if e == null:
		return events

	if stand_up:
		e.clear_status(E.S_PRONE)
		events.push_back(GE.new(E.Ev.STAND_UP, {"id": actor_id, "pos": e.pos}))
		return events

	for step in path:
		var from: Vector2i = e.pos
		if state.in_bounds(from) and state.tile(from).occupant_id == actor_id:
			state.tile(from).occupant_id = -1
		e.pos = step
		if state.in_bounds(step):
			state.tile(step).occupant_id = actor_id
		events.push_back(GE.new(E.Ev.MOVE, {"id": actor_id, "from": from, "to": step}))
		# §5.5 reaction fire — WALKING into an armed hostile watcher's lane draws the
		# shot at the step it happens (physics displacement never triggers overwatch).
		# This is the single command-layer seam, so player and enemy movement react
		# identically (the enemy-AI's own post-move check_entry stays a safe no-op:
		# an armed watcher is consumed here first).
		var reactions: Array = OverwatchSystem.check_entry(state, actor_id)
		for ev in reactions:
			events.push_back(ev)
		# A mover downed/erased by the reaction stops walking.
		var still = state.entities.get(actor_id)
		if still == null or not still.alive:
			break
	return events
