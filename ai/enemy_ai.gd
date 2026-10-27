class_name EnemyAI
extends RefCounted
## Deterministic rule-based enemy controller over the command layer (GDD §17.1).
## NO SceneTree, integer-only, all randomness via state.rng (none used here — the
## policy is fully deterministic; only the Shoot it issues touches the rng).
##
## Policy, per enemy unit in entity_ids_sorted() order, while it has AP:
##   1. Pick the nearest living PLAYER unit (ties → lowest id).
##   2. If a player is adjacent AND can be shoved advantageously (into a hazard,
##      gap, or wall) → Shove (physics cuts both ways, §12). Does not end turn.
##   3. Else if in weapon range with line of sight → Shoot (ends this unit's turn).
##   4. Else → Move one step toward the target (toward, not through).

const E = preload("res://core/sim_enums.gd")
const ShootCommand = preload("res://core/commands/shoot_command.gd")
const MoveCommand = preload("res://core/commands/move_command.gd")
const ShoveCommand = preload("res://core/commands/shove_command.gd")
const OverwatchSystem = preload("res://core/overwatch_system.gd")
const AIProfiles = preload("res://ai/ai_profiles.gd")

# Stable orthogonal step order (N, E, S, W) — never reorder (matches resolver DIRS4).
const DIRS4 := [Vector2i(0, -1), Vector2i(1, 0), Vector2i(0, 1), Vector2i(-1, 0)]

# Standing / cycling hazard emitters an enemy must not path through (physics cuts both ways, §12).
# Mirrors RunController.PILOT_HAZARD_BLOCK; plain L_WATER stays passable (soak-walkable).
const HAZARD_BLOCK := [E.Hazard.SCALD, E.Hazard.FURNACE, E.Hazard.RAIL_LIVE,
	E.Hazard.VENT, E.Hazard.LASER, E.Hazard.LASER_SWEEP, E.Hazard.PLATE, E.Hazard.PISTON]

## Run the whole enemy phase against `turn` (a TurnManager). Returns the flat list
## of events emitted by every enemy action, in resolution order.
func take_phase(turn) -> Array:
	var events: Array = []
	var state = turn.state
	for id in state.entity_ids_sorted():
		var e = state.entities.get(id)
		if e == null or not e.is_unit or not e.alive or e.faction != E.Faction.ENEMY:
			continue
		# The Conductor's body is driven ONLY by the ConductorAI pattern controller
		# (run_conductor_phase), never the generic enemy policy — otherwise the shielded,
		# damage-immune boss abandons the dais and chases/shoves the squad as a melee rusher
		# (W2-7). This is the robust guard; the `unaware` hint in engine_vault is belt-and-braces
		# but is cleared by the ambush-wake rule the moment a player steps adjacent, so the skip
		# must live here at the dispatch, keyed on the entity's own is_finale_boss flag.
		if e.is_finale_boss:
			continue
		# Act repeatedly until this unit is out of AP or has nothing useful to do.
		var guard: int = 0
		while turn.can_act(id) and guard < 8:
			guard += 1
			var acted: bool = _act_once(turn, id, events)
			if not acted:
				turn.end_unit(id)  # nothing productive — yield the rest of its AP
				break
	return events

## One action for enemy `id`. Returns true if it issued a command, false if idle.
## Phase 5: dispatches to the per-`aiProfile` policy in ai/ai_profiles.gd. The default
## (melee_rush) preserves the Phase-0i shove→shoot→move behavior the fixtures expect.
func _act_once(turn, id: int, events: Array) -> bool:
	var state = turn.state
	var me = state.entities.get(id)
	if me == null or not me.alive:
		return false
	return AIProfiles.act(self, turn, id, events)

# --- target selection ----------------------------------------------------------
func _nearest_player(state, me):
	var best = null
	var best_d: int = 1 << 30
	for pid in state.entity_ids_sorted():
		var p = state.entities[pid]
		if not p.is_unit or not p.alive or p.faction != E.Faction.PLAYER:
			continue
		var d: int = _manhattan(me.pos, p.pos)
		if d < best_d:
			best_d = d
			best = p
		# ties broken by lowest id: entity_ids_sorted() ascends, so the first
		# (lowest id) at a given distance is kept (strict < above).
	return best

# --- movement ------------------------------------------------------------------
## Obstacle-aware one-tile step toward `dst` (W2-8). A deterministic breadth-first search
## routes AROUND walls / body-blocked corridors and returns the FIRST tile of a shortest
## route — replacing the old greedy stepper that STALLED with full AP the instant the direct
## step was blocked (and, worse, a naive perpendicular detour oscillated on an axis-aligned
## single-wall corridor because the next greedy step snapped straight back into the pocket).
## `dst` is usually the player's tile (occupied) → we path to a tile orthogonally ADJACENT to
## it. The neighbour scan AND the path reconstruction both use the fixed N,E,S,W order, so the
## chosen route is fully reproducible; `_passable` keeps it off walls/gaps/bodies/live hazards.
## Returns `here` when the unit is genuinely boxed in.
func _step_toward(state, me, dst: Vector2i) -> Vector2i:
	var here: Vector2i = me.pos
	if here == dst:
		return here
	var goal_walkable: bool = _passable(state, dst)
	var came: Dictionary = {here: here}
	var q: Array = [here]
	var head: int = 0
	var goal: Vector2i = here
	var found: bool = false
	while head < q.size():
		var cur: Vector2i = q[head]
		head += 1
		if goal_walkable:
			if cur == dst:
				goal = cur
				found = true
				break
		elif cur != here and _manhattan(cur, dst) == 1:
			goal = cur
			found = true
			break
		for d in DIRS4:
			var np: Vector2i = cur + d
			if came.has(np) or not _passable(state, np):
				continue
			came[np] = cur
			q.push_back(np)
	if not found:
		return here
	# Walk the goal back to the tile whose predecessor is `here` — that first hop is our step.
	var step: Vector2i = goal
	while came[step] != here:
		step = came[step]
	return step

func _passable(state, p: Vector2i) -> bool:
	if not state.in_bounds(p):
		return false
	var t = state.tile(p)
	if t.terrain == E.Terrain.WALL:
		return false
	if t.hazard == E.Hazard.GAP:
		return false  # enemies don't volunteer to walk off the train
	if state.occupant_at(p) != null:
		return false
	if t.hazard in HAZARD_BLOCK:
		return false  # a standing/cycling hazard emitter — don't path onto it (§12)
	# Don't stand on a telegraphed cycling hazard (it fires next env phase) or on an
	# already-burning / gassed / electrified tile — physics cuts both ways (§12, D2).
	if t.has_layer(E.L_TELEGRAPH) or t.has_layer(E.L_FIRE) or t.has_layer(E.L_ELECTRIFIED) or t.has_layer(E.L_GAS):
		return false
	return true

# --- opportunistic shove -------------------------------------------------------
## Returns the orthogonal dir to shove `target` directly away from `me` IF that
## push sends it into a gap/hazard or pins it against a wall (advantageous). Else
## ZERO. Must shove directly away (matches ShoveCommand's contract).
func _advantageous_shove_dir(state, me, target) -> Vector2i:
	if not target.movable:
		return Vector2i.ZERO
	var dir: Vector2i = target.pos - me.pos
	if abs(dir.x) + abs(dir.y) != 1:
		return Vector2i.ZERO  # only when target is directly orthogonally adjacent
	var ahead: Vector2i = target.pos + dir
	# Off the train, or onto a damaging hazard tile → great.
	if not state.in_bounds(ahead):
		return dir
	var t = state.tile(ahead)
	if t.hazard == E.Hazard.GAP or t.hazard == E.Hazard.FURNACE or t.hazard == E.Hazard.RAIL_LIVE or t.hazard == E.Hazard.PISTON:
		return dir
	# Onto a cycling hazard emitter, a telegraphed danger tile, or active fire/gas/
	# electrified — physics cuts both ways: shove the player onto the hot square (D2).
	if t.hazard == E.Hazard.VENT or t.hazard == E.Hazard.LASER or t.hazard == E.Hazard.PLATE or t.hazard == E.Hazard.STEAM:
		return dir
	if t.has_layer(E.L_TELEGRAPH) or t.has_layer(E.L_FIRE) or t.has_layer(E.L_GAS) or t.has_layer(E.L_ELECTRIFIED):
		return dir
	# Into a wall → bonk for impact damage + possible Prone/Stun.
	if t.terrain == E.Terrain.WALL:
		return dir
	# Into standing water while a power source is near → set up an electrify.
	if t.has_layer(E.L_WATER):
		return dir
	return Vector2i.ZERO

# --- helpers -------------------------------------------------------------------
static func _manhattan(a: Vector2i, b: Vector2i) -> int:
	return abs(a.x - b.x) + abs(a.y - b.y)

func _append(dst: Array, src: Array) -> void:
	for ev in src:
		dst.push_back(ev)
