class_name AbilityCommand
extends Command
## Routes a data-defined AbilityDef through the command layer so abilities validate ->
## apply -> emit like every other action (ARCHITECTURE.md invariant #4). Reads apCost / endsTurn
## / targeting / range straight off the AbilityDef and hands the effects to AbilitySystem.
##
## Targeting kinds (Sub-Spec C abilities):
##   enemy  -> target_id is a hostile unit within range + LoS
##   ally   -> target_id is a friendly unit within range
##   tile   -> target_pos is a tile within range
##   direction -> dir is an orthogonal step; target is the first thing hit (or a tile)
##   self   -> no target (passive/self abilities)
## A `move`/`toAdjacent` effect (Lunge, Bull Rush) steps the actor adjacent to the target
## before the rest of the effects resolve.

const AbilitySystem = preload("res://core/ability_system.gd")

var ability: Dictionary = {}      # the resolved AbilityDef
var target_id: int = -1
var target_pos: Vector2i = Vector2i.ZERO
var dir: Vector2i = Vector2i.ZERO


func _init(p_actor_id: int = -1, p_ability: Dictionary = {}, p_target_id: int = -1, p_target_pos: Vector2i = Vector2i.ZERO, p_dir: Vector2i = Vector2i.ZERO) -> void:
	super(p_actor_id)
	ability = p_ability
	target_id = p_target_id
	target_pos = p_target_pos
	dir = p_dir
	ap_cost = int(ability.get("apCost", 1))
	ends_turn = bool(ability.get("endsTurn", false))


func validate(state, _turn) -> Dictionary:
	var a = state.entities.get(actor_id)
	if a == null or not a.alive or not a.is_unit:
		return _fail("actor missing/dead")
	if ability.is_empty():
		return _fail("no ability def")
	var targeting: String = ability.get("targeting", "self")
	var rng_tiles: int = int(ability.get("range", 0))
	match targeting:
		"enemy":
			var t = state.entities.get(target_id)
			if t == null or not t.alive or not t.is_unit:
				return _fail("target missing/dead")
			if t.faction == a.faction:
				return _fail("enemy-target ability cannot hit own faction")
			if _manhattan(a.pos, t.pos) > rng_tiles:
				return _fail("target out of ability range")
		"ally":
			var t2 = state.entities.get(target_id)
			if t2 == null or not t2.is_unit:
				return _fail("ally target missing")
			if t2.faction != a.faction:
				return _fail("ally-target ability needs a friendly target")
			# Downed allies are valid targets for stabilize/last_stand.
			if _manhattan(a.pos, t2.pos) > rng_tiles:
				return _fail("ally out of ability range")
		"tile":
			if not state.in_bounds(target_pos):
				return _fail("target tile out of bounds")
			if _manhattan(a.pos, target_pos) > rng_tiles:
				return _fail("tile out of ability range")
		"direction":
			if abs(dir.x) + abs(dir.y) != 1:
				return _fail("direction ability needs one orthogonal step")
		_:
			pass   # self abilities always validate
	return _ok()


func execute(state, turn) -> Array:
	var events: Array = []
	var a = state.entities.get(actor_id)
	if a == null:
		return events
	# A `move`/`toAdjacent` effect repositions the actor adjacent to the target first.
	for eff in ability.get("effects", []):
		if eff.get("kind", "") == "move" and eff.get("toAdjacent", false):
			var t = state.entities.get(target_id)
			if t != null:
				_step_adjacent_to(state, a, t, events)
	var ctx := {
		"actor": actor_id, "target_id": target_id,
		"target_pos": target_pos, "dir": dir, "turn": turn,
	}
	var evs: Array = AbilitySystem.execute(state, ability, ctx)
	for ev in evs:
		events.push_back(ev)
	return events


# Move the actor onto the closest open orthogonal tile adjacent to `t` (Lunge/Bull Rush).
func _step_adjacent_to(state, a, t, events: Array) -> void:
	if _manhattan(a.pos, t.pos) == 1:
		return
	var best: Vector2i = a.pos
	var best_d: int = 1 << 30
	for d in [Vector2i(0, -1), Vector2i(1, 0), Vector2i(0, 1), Vector2i(-1, 0)]:
		var np: Vector2i = t.pos + d
		if not state.in_bounds(np):
			continue
		var tile = state.tile(np)
		if tile.terrain == E.Terrain.WALL or state.occupant_at(np) != null:
			continue
		var dd: int = _manhattan(a.pos, np)
		if dd < best_d:
			best_d = dd
			best = np
	if best != a.pos:
		var from: Vector2i = a.pos
		if state.in_bounds(from) and state.tile(from).occupant_id == a.id:
			state.tile(from).occupant_id = -1
		a.pos = best
		if state.in_bounds(best):
			state.tile(best).occupant_id = a.id
		events.push_back(GE.new(E.Ev.MOVE, {"id": a.id, "from": from, "to": best}))
