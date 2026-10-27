class_name ModifierSystem
extends RefCounted
## Progression-real batch (2026-07-02) — makes the rolled car modifiers REAL.
## RunGenerator rolls 0-2 modifier ids per car (shown in recon, GDD §8.2); this system
## applies their effects to the BUILT combat SimState so recon foreknowledge is honest.
##
## Called once at car build (run_controller._build_car_state, after the squad is placed).
## DETERMINISM: integer-only, RefCounted, stable iteration order; all placement draws come
## from a LOCAL IntRng derived from (run seed, car position) — state.rng (the to-hit
## stream) is NEVER touched, so combat rolls stay byte-identical with/without modifiers.
##
## Implemented kinds (MODIFIER_KINDS) mutate either SimState rule fields (move_mod /
## accuracy_mod / enemy_cover_mod / displacement_mult / env_dot / env_status_bit /
## reinforce_*) that the commands + HazardSystem already read, or the world itself
## (seeded hazard tiles, extra objects, flood-rigged breakables, sympathizer allies,
## supply-drop consumables). Unimplemented kinds warn LOUDLY once (AbilitySystem).

const E = preload("res://core/sim_enums.gd")
const IntRng = preload("res://core/int_rng.gd")
const SimEntity = preload("res://core/sim_entity.gd")
const SetpieceLoader = preload("res://core/setpiece_loader.gd")
const Ability = preload("res://core/ability_system.gd")

const MODIFIERS_PATH := "res://content/modifiers/modifiers.json"

## Modifier effect kinds this system implements (the run_tests registry check unions
## these with AbilitySystem's sets — every content-referenced kind must land somewhere).
const MODIFIER_KINDS := {
	"move_mod": true,                    # Cramped: flat Move-range delta, every unit
	"sight_mod": true,                   # Flickering Lights: flat to-hit delta, all shooters
	"seed_hazard": true,                 # Steam Vents / Gas Leak / Laser Sec-Grid / Furnace Row / Live Rails
	"dot_each_turn": true,               # Open Roof: exposure damage each env phase
	"status_each_turn": true,            # Open Roof: exposure status each env phase
	"timed_reinforcements": true,        # Lockdown: a fresh guard every N env phases
	"destructible_break_triggers": true, # Overpressure: breakables burst into floods
	"destructible_count_mod": true,      # Sealed Bulkheads: fewer destructibles
	"extra_movable_objects": true,       # Loose Cargo / Coolant Bank: +N movable objects
	"spawn_ally": true,                  # Sympathizers: a neutral-assist fighter joins
	"enemy_cover_mod": true,             # Sabotaged Security: enemy cover stripped
	"field_consumables": true,           # Supply Drop: consumables stocked on the lead body
	"displacement_mult": true,           # Zero-Stabilizer Section: impulses hit harder
}

## Content-referenced modifier kinds DELIBERATELY deferred (loud, allowlisted).
const DEFERRED_MODIFIER_KINDS := {
	"ambush_risk": true,   # Flickering Lights rider: needs the E1.7 unaware/ambush AI hook
}


## Apply every rolled modifier id to a built combat state. `car_data` is the parsed
## CarTemplate dict (spawn candidates); `mseed` derives the LOCAL placement rng.
static func apply(state, modifier_ids: Array, car_data: Dictionary, mseed: int) -> void:
	if modifier_ids.is_empty():
		return
	var defs := _load_defs()
	var rng = IntRng.new(mseed & 0xFFFFFFFF)
	for mid in modifier_ids:
		var md: Dictionary = defs.get(String(mid), {})
		if md.is_empty():
			Ability.warn_unhandled(String(mid), "modifier id (no def)")
			continue
		for eff in md.get("effects", []):
			_apply_effect(state, eff, car_data, rng)


static func _apply_effect(state, eff: Dictionary, car_data: Dictionary, rng) -> void:
	var kind: String = eff.get("kind", "")
	match kind:
		"move_mod":
			state.move_mod += int(eff.get("amount", 0))
		"sight_mod":
			state.accuracy_mod += int(eff.get("amount", 0))
		"enemy_cover_mod":
			state.enemy_cover_mod += int(eff.get("amount", 0))
		"displacement_mult":
			state.displacement_mult = max(state.displacement_mult, int(eff.get("value", 1)))
		"dot_each_turn":
			state.env_dot += int(eff.get("amount", 0))
		"status_each_turn":
			state.env_status_bit |= int(Ability.STATUS_MAP.get(eff.get("status", ""), 0))
		"seed_hazard":
			_seed_hazard(state, eff, rng)
		"timed_reinforcements":
			_arm_reinforcements(state, eff, car_data)
		"destructible_break_triggers":
			_rig_breakables_to_flood(state, eff)
		"destructible_count_mod":
			_thin_destructibles(state, eff)
		"extra_movable_objects":
			_add_objects(state, eff, rng)
		"spawn_ally":
			_spawn_sympathizers(state, eff, rng)
		"field_consumables":
			_stock_lead_body(state, eff)
		_:
			if kind != "" and not DEFERRED_MODIFIER_KINDS.has(kind):
				Ability.warn_unhandled(kind, "modifier effect")
			elif DEFERRED_MODIFIER_KINDS.has(kind):
				Ability.warn_unhandled(kind, "modifier effect (deferred)")


# --- world-shaping effects -------------------------------------------------------

## Seed `count` hazard tiles of the named kind on open floor (SetpieceLoader's shared
## hazard pipeline, so a seeded steam_vent cycles exactly like an authored one).
static func _seed_hazard(state, eff: Dictionary, rng) -> void:
	var name: String = eff.get("hazard", "")
	var count: int = int(eff.get("count", 1))
	if name == "" or count <= 0:
		return
	var tiles := _pick_open_tiles(state, count, rng)
	for p in tiles:
		SetpieceLoader._apply_hazard_name(state.tile(p), name)
	# A sourced leak (Gas Leak's gas_main) also places the source object beside the cloud.
	var src: String = eff.get("withSource", "")
	if src != "" and not tiles.is_empty():
		var extra := _pick_open_tiles(state, 1, rng)
		if not extra.is_empty():
			var objs := SetpieceLoader._index(SetpieceLoader._read_json(SetpieceLoader.OBJ_PATH), "objects")
			if objs.has(src):
				SetpieceLoader._place_object(state, objs, {"object": src, "x": extra[0].x, "y": extra[0].y})


## Lockdown: arm the HazardSystem's reinforcement timer; candidates = the car's authored
## enemy spawn tiles (stable authored order — the rear door the guards came through).
static func _arm_reinforcements(state, eff: Dictionary, car_data: Dictionary) -> void:
	var every: int = int(eff.get("everyTurns", 3))
	if every <= 0:
		return
	var spawns: Array = []
	for es in car_data.get("enemySpawns", []):
		var at: Dictionary = es.get("at", {})
		spawns.push_back(Vector2i(int(at.get("x", 0)), int(at.get("y", 0))))
	if spawns.is_empty():
		return
	state.reinforce_every = every
	state.reinforce_timer = every
	state.reinforce_spawns = spawns


## Overpressure: every plain breakable now bursts into a flood (Sub-Spec A5 chain).
static func _rig_breakables_to_flood(state, eff: Dictionary) -> void:
	var radius: int = int(eff.get("floodRadius", 2))
	for id in state.entity_ids_sorted():
		var e = state.entities[id]
		if e.is_unit or e.integrity <= 0 or e.on_break != E.OnBreak.NONE:
			continue
		e.on_break = E.OnBreak.FLOOD
		e.break_param = radius


## Sealed Bulkheads: remove |pct|% of the plain destructibles (never cover-granting or
## on_break-chained ones — their tile mirrors / chains must stay authored-consistent).
static func _thin_destructibles(state, eff: Dictionary) -> void:
	var pct: int = abs(int(eff.get("amount_pct", 0)))
	if pct <= 0:
		return
	var candidates: Array = []
	for id in state.entity_ids_sorted():
		var e = state.entities[id]
		if not e.is_unit and e.integrity > 0 and e.movable \
				and e.cover == 0 and e.on_break == E.OnBreak.NONE:
			candidates.push_back(e)
	var to_remove: int = candidates.size() * pct / 100
	for i in range(to_remove):
		var e = candidates[i]
		if state.in_bounds(e.pos) and state.tile(e.pos).occupant_id == e.id:
			state.tile(e.pos).occupant_id = -1
		state.entities.erase(e.id)


## Loose Cargo / Coolant Bank: +N movable objects (default crates) on open floor.
static func _add_objects(state, eff: Dictionary, rng) -> void:
	var count: int = int(eff.get("count", 1))
	var obj_id: String = eff.get("object", "crate")
	if count <= 0:
		return
	var objs := SetpieceLoader._index(SetpieceLoader._read_json(SetpieceLoader.OBJ_PATH), "objects")
	if not objs.has(obj_id):
		return
	for p in _pick_open_tiles(state, count, rng):
		SetpieceLoader._place_object(state, objs, {"object": obj_id, "x": p.x, "y": p.y})


## Sympathizers: a citizen picks up a pipe and joins THIS fight. PLAYER faction so the
## turn loop drives it, instance_id -1 so it never absorbs into the persistent squad
## (it stays behind when the cell moves on — no free permanent recruit).
static func _spawn_sympathizers(state, eff: Dictionary, rng) -> void:
	var count: int = int(eff.get("count", 1))
	for i in range(count):
		var tiles := _pick_open_tiles(state, 1, rng)
		if tiles.is_empty():
			return
		var u = SimEntity.new()
		u.is_unit = true
		u.pos = tiles[0]
		u.mass = E.Mass.MEDIUM
		u.hp = E.SYMPATHIZER_HP
		u.integrity = -1
		u.faction = E.Faction.PLAYER
		u.name = "sympathizer"
		u.accuracy = E.SYMPATHIZER_ACCURACY
		state.add_entity(u)


## Supply Drop: stock the lead (lowest-id living player) body's gear with consumables —
## usable mid-fight through UseItemCommand, absorbed into inventory if unspent.
static func _stock_lead_body(state, eff: Dictionary) -> void:
	var count: int = int(eff.get("count", 1))
	for id in state.entity_ids_sorted():
		var e = state.entities[id]
		if e.is_unit and e.alive and e.faction == E.Faction.PLAYER:
			for i in range(count):
				e.gear.push_back(E.SUPPLY_DROP_ITEM)
			return


# --- shared helpers ---------------------------------------------------------------

## Pick `count` DISTINCT open floor tiles (no wall / occupant / hazard / live layer /
## player-spawn adjacency constraint), drawing indices from the LOCAL rng over a stable
## (y, x)-ordered candidate list. Deterministic for a fixed (state, rng-stream) pair.
static func _pick_open_tiles(state, count: int, rng) -> Array:
	var candidates: Array = []
	for y in range(state.height):
		for x in range(state.width):
			var p := Vector2i(x, y)
			var t = state.tile(p)
			if t.terrain == E.Terrain.WALL or t.hazard != E.Hazard.NONE:
				continue
			if t.status_layer != 0 or t.occupant_id != -1:
				continue
			candidates.push_back(p)
	var out: Array = []
	while out.size() < count and not candidates.is_empty():
		var i: int = rng.randi_range(0, candidates.size() - 1)
		out.push_back(candidates[i])
		candidates.remove_at(i)
	return out


static func _load_defs() -> Dictionary:
	var parsed = SetpieceLoader._read_json(MODIFIERS_PATH)
	var out: Dictionary = {}
	if parsed != null:
		for m in parsed.get("modifiers", []):
			if typeof(m) == TYPE_DICTIONARY and m.has("id"):
				out[m["id"]] = m
	return out
