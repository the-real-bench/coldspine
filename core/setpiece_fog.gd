class_name SetpieceFog
## Phase 5 — in-car fog (Sub-Spec E1.4): some cars (Hedge Maze, heavy Steam rooms) reduce
## the OPERATOR's own visibility, so the omniscient camera (§3.1) only sees tiles within
## line of sight of a friendly unit or a working camera; everything else is fog until
## revealed. Default cars stay fully visible (per E1.4). RefCounted statics, integer-only,
## ZERO SceneTree, NO rng — visibility is a pure deterministic function of the sim state.
##
## OWNER-FLAGGED toggle (ARCHITECTURE.md / Sub-Spec E1.4): in-car fog is a revisitable design
## switch. It is implemented and exposed as the single clearly-named const below; the
## DEFAULT is exactly what E1.4 specifies — fog is honored only for cars that request it
## (`inCarFog: true`), and every other car is fully visible. Do not tune without sign-off.
const IN_CAR_FOG_ENABLED := true   # OWNER-FLAGGED — honor per-car `inCarFog`; default per E1.4

const E = preload("res://core/sim_enums.gd")
const ShootCommand = preload("res://core/commands/shoot_command.gd")

# Tiles within this Manhattan radius of a friendly unit are always considered seen (the
# unit's immediate surroundings), in addition to its traced line of sight.
const VISION_RADIUS := 6


## Compute the set of tiles the operator can currently SEE in a fogged car.
## Returns a Dictionary {Vector2i: true} of visible tiles. If `fog_on` is false (a normal
## car) OR the global toggle is off, EVERY in-bounds tile is visible (full omniscience).
static func visible_tiles(state, fog_on: bool) -> Dictionary:
	var seen: Dictionary = {}
	if not (IN_CAR_FOG_ENABLED and fog_on):
		# Default car (E1.4): the operator sees everything.
		for y in range(state.height):
			for x in range(state.width):
				seen[Vector2i(x, y)] = true
		return seen
	# Fogged car: union of each friendly unit's line-of-sight + immediate vision radius.
	for id in state.entity_ids_sorted():
		var u = state.entities.get(id)
		if u == null or not u.is_unit or not u.alive or u.faction != E.Faction.PLAYER:
			continue
		seen[u.pos] = true
		for y in range(state.height):
			for x in range(state.width):
				var p := Vector2i(x, y)
				if seen.has(p):
					continue
				if _manhattan(u.pos, p) > VISION_RADIUS:
					continue
				# A tile is seen if the unit has clear LoS to it (concealment/steam/walls
				# block the operator's camera exactly as they block a shot).
				if ShootCommand.in_los(state, u.pos, p):
					seen[p] = true
	return seen


## Is `tile_pos` hidden from the operator right now in this car?
static func is_fogged(state, fog_on: bool, tile_pos: Vector2i) -> bool:
	if not (IN_CAR_FOG_ENABLED and fog_on):
		return false
	return not visible_tiles(state, fog_on).has(tile_pos)


static func _manhattan(a: Vector2i, b: Vector2i) -> int:
	return abs(a.x - b.x) + abs(a.y - b.y)
