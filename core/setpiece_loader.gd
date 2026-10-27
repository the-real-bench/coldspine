class_name SetpieceLoader
## Phase 5 — the engine-side CarTemplate loader that honors the Sub-Spec E1 set-piece
## fields the cars compose: tile friction / slope / concealment / belt direction, the new
## hazards (conveyor / scald / laser-sweep), object onBreak "topple" + "onBreakOverride",
## rigged sculptures (hidden cycling traps), built-in water layers, and the ambush-start /
## in-car-fog flags. RefCounted, integer-only, ZERO SceneTree — it returns a deterministic
## SimState the headless sim drives directly.
##
## This is the E1-composition spine: NO per-car bespoke physics. Every car is data layered
## over the shared engine. This is the deterministic core loader the sim + tests use;
## `app/car_loader.gd` (the Phase-0 debug/render path) delegates its hazard parsing here
## so the two loaders can never diverge on the hazard schema.

const SimState = preload("res://core/sim_state.gd")
const SimEntity = preload("res://core/sim_entity.gd")
const IntRng = preload("res://core/int_rng.gd")
const E = preload("res://core/sim_enums.gd")
const ContentDB = preload("res://core/units/content_db.gd")

const CARS_DIR := "res://content/cars/"
const OBJ_PATH := "res://content/objects/objects.json"

const MASS_MAP := {"light": E.Mass.LIGHT, "medium": E.Mass.MEDIUM, "heavy": E.Mass.HEAVY, "anchored": E.Mass.ANCHORED}
const ONBREAK_MAP := {
	"none": E.OnBreak.NONE, "flood": E.OnBreak.FLOOD, "explode": E.OnBreak.EXPLODE,
	"collapse": E.OnBreak.COLLAPSE, "spill_fire": E.OnBreak.SPILL_FIRE,
	"topple": E.OnBreak.TOPPLE, "avalanche": E.OnBreak.AVALANCHE,   # Phase 5 (E1.3 / E1.6)
}

# Every hazard name an authored placement can map (_apply_hazard_name: the _set_hazard_on_tile
# trap kinds + synonyms, plus the water/fire/poison_gas/debris layer seeds). KEEP IN SYNC with
# those matches — content_integrity_smoke asserts every car-authored hazard id is in this set,
# so an unmapped id fails loudly instead of silently no-oping. "explosion" and "avalanche" are
# deliberately absent: they are instantaneous EVENTS (onBreak/interaction outcomes), not
# placeable tile states — authoring them in layout.hazards[] is a content error.
const PLACEABLE_HAZARDS := {
	"conveyor": true, "scald_tile": true, "scald": true, "laser_sweep": true,
	"laser_grid": true, "laser": true, "fire_vent": true, "steam_vent": true,
	"electrified_plate": true, "plate": true, "piston": true, "gap": true,
	"furnace": true, "live_rail": true, "rail_live": true,
	"water": true, "fire": true, "poison_gas": true, "debris": true,
}


## Load a set-piece car by id into a deterministic SimState. Returns null on hard failure.
static func load_car(car_id: String, seed: int = 0xC01D5) -> SimState:
	var data = _read_json(CARS_DIR + car_id + ".json")
	if data == null:
		return null
	return build(data, seed)


## Build a SimState from a parsed CarTemplate dict.
static func build(data: Dictionary, seed: int = 0xC01D5) -> SimState:
	var objs := _index(_read_json(OBJ_PATH), "objects")
	var db := ContentDB.new()

	var s := SimState.new()
	var gs: Dictionary = data.get("gridSize", {"w": 12, "h": 8})
	s.init_grid(int(gs.get("w", 12)), int(gs.get("h", 8)))
	s.rng = IntRng.new(seed)

	var layout: Dictionary = data.get("layout", {})

	# 1. Walls.
	for w in layout.get("walls", []):
		var x0 := int(w.get("x", 0)); var y0 := int(w.get("y", 0))
		var ww := int(w.get("w", 1)); var hh := int(w.get("h", 1))
		for yy in range(y0, y0 + hh):
			for xx in range(x0, x0 + ww):
				s.set_wall(Vector2i(xx, yy))

	# 2. Tile fields (E1) — friction / slope / concealment / belt / built-in water / scald.
	for tf in layout.get("tileFields", []):
		_apply_tile_field(s, tf)

	# 3. Cover objects (may be multi-tile via h/w, e.g. hedge walls).
	for c in layout.get("cover", []):
		_place_cover_run(s, objs, c)

	# 4. Breakable / interactive objects (topple, rigged sculptures, onBreakOverride).
	for o in layout.get("objects", []):
		_place_object(s, objs, o)

	# 5. Hazard tiles (cycling + static) — conveyor / scald / laser-sweep / gap / etc.
	for hz in layout.get("hazards", []):
		_place_hazard(s, hz)

	# 6. Enemies (with Phase-5 aiProfile / physicsTrait / captain keys + ambush flags).
	for es in data.get("enemySpawns", []):
		_place_enemy(s, db, es, data.get("ambushStart", false))

	# 7. Player starters on the player spawn points.
	_place_starters(s, layout.get("spawnPoints", {}).get("player", []))

	return s


# ---- tile fields (E1) ---------------------------------------------------------
static func _apply_tile_field(s: SimState, tf: Dictionary) -> void:
	var region: Dictionary = tf.get("region", {})
	var x0 := int(region.get("x", 0)); var y0 := int(region.get("y", 0))
	var rw := int(region.get("w", 1)); var rh := int(region.get("h", 1))
	var has_friction: bool = tf.has("friction")
	var friction := int(tf.get("friction", -1))
	var slope := _vec(tf.get("slope", null))
	var conceal: bool = tf.get("concealment", false)
	var water: bool = tf.get("waterLayer", false)
	var hazard_name: String = tf.get("hazard", "")
	var belt := _vec(tf.get("beltDir", null))
	var status_name: String = tf.get("status", "")
	for yy in range(y0, y0 + rh):
		for xx in range(x0, x0 + rw):
			var p := Vector2i(xx, yy)
			if not s.in_bounds(p):
				continue
			var t := s.tile(p)
			if t.terrain == E.Terrain.WALL:
				continue
			if has_friction:
				t.friction = friction
			if slope != Vector2i.ZERO:
				t.slope = slope
			if conceal:
				t.status_layer |= E.L_CONCEAL
			if water:
				t.status_layer |= E.L_WATER
				t.status_timer = max(t.status_timer, E.WATER_DURATION)
			if belt != Vector2i.ZERO:
				t.belt_dir = belt
				t.hazard = E.Hazard.CONVEYOR
				t.trap_period = 1
				t.trap_active = true
			if hazard_name != "":
				_apply_hazard_name(t, hazard_name)
			# A status tag on a tile field (e.g. snow patch "chilled") seeds a snow layer so
			# units that stand here get Chilled via the cold path; modeled as packed snow.
			if status_name == "chilled":
				t.status_layer |= E.L_SNOW


static func _set_hazard_on_tile(t, name: String) -> void:
	match name:
		"conveyor": t.hazard = E.Hazard.CONVEYOR; t.trap_period = 1; t.trap_active = true
		"scald_tile", "scald": t.hazard = E.Hazard.SCALD
		"laser_sweep": t.hazard = E.Hazard.LASER_SWEEP; t.trap_period = E.LASER_PERIOD; t.trap_active = true
		"laser_grid", "laser": t.hazard = E.Hazard.LASER; t.trap_period = E.LASER_PERIOD; t.trap_active = true
		"fire_vent": t.hazard = E.Hazard.VENT; t.trap_period = E.VENT_PERIOD; t.trap_active = true
		"steam_vent": t.hazard = E.Hazard.STEAM; t.trap_period = E.STEAM_PERIOD; t.trap_active = true
		"electrified_plate", "plate": t.hazard = E.Hazard.PLATE; t.trap_period = E.PLATE_PERIOD; t.trap_active = true
		"piston": t.hazard = E.Hazard.PISTON; t.trap_period = E.PISTON_PERIOD; t.trap_active = true
		"gap": t.hazard = E.Hazard.GAP
		"furnace": t.hazard = E.Hazard.FURNACE
		"live_rail", "rail_live": t.hazard = E.Hazard.RAIL_LIVE
		_: pass


## Authored hazard placement (layout.hazards[] / tileFields[].hazard): the trap kinds above,
## PLUS the spreading/static LAYER hazards (Sub-Spec D1/D8) seeded as live standing tile state
## exactly the way the hazard system seeds them. Rigged sculptures do NOT come through here —
## a dormant rig only makes sense for cycling-trap kinds (_set_hazard_on_tile).
static func _apply_hazard_name(t, name: String) -> void:
	match name:
		"water":
			t.status_layer |= E.L_WATER
			t.status_timer = max(t.status_timer, E.WATER_DURATION)
		"fire":
			t.status_layer |= E.L_FIRE
			t.status_timer = max(t.status_timer, E.FIRE_DURATION)
		"poison_gas":
			t.status_layer |= E.L_GAS
			t.gas_timer = max(t.gas_timer, E.GAS_DURATION)
		"debris":
			# Rubble: a render-visible debris layer + half cover (hazards.json coverValue 1).
			# difficultTerrain is not modeled by the sim yet — cover + marker only.
			t.status_layer |= E.L_DEBRIS
			t.cover = max(t.cover, 1)
		_:
			_set_hazard_on_tile(t, name)


# ---- objects ------------------------------------------------------------------
static func _place_cover_run(s: SimState, objs: Dictionary, c: Dictionary) -> void:
	# Cover entries may span a vertical/horizontal run (hedge walls: x,y + h/w).
	var x0 := int(c.get("x", 0)); var y0 := int(c.get("y", 0))
	var rw := int(c.get("w", 1)); var rh := int(c.get("h", 1))
	for yy in range(y0, y0 + rh):
		for xx in range(x0, x0 + rw):
			var cc := c.duplicate()
			cc["x"] = xx; cc["y"] = yy
			cc.erase("w"); cc.erase("h")
			_place_object(s, objs, cc)


static func _place_object(s: SimState, objs: Dictionary, o: Dictionary) -> SimEntity:
	var pos := Vector2i(int(o.get("x", 0)), int(o.get("y", 0)))
	if not s.in_bounds(pos):
		return null
	var obj_id: String = o.get("object", "crate")
	var def: Dictionary = objs.get(obj_id, {})
	var mass: int = int(MASS_MAP.get(def.get("mass", "medium"), E.Mass.MEDIUM))
	var anchored: bool = (mass == E.Mass.ANCHORED)

	# An onBreakOverride on the placement wins over the object's default (e.g. avalanche).
	var on_break_name: String = o.get("onBreakOverride", def.get("onBreak", "none"))
	var on_break: int = int(ONBREAK_MAP.get(on_break_name, E.OnBreak.NONE))

	var ent := SimEntity.new()
	ent.is_unit = false
	ent.pos = pos
	ent.mass = mass
	ent.movable = not anchored
	ent.integrity = int(def.get("integrity", 3))
	ent.hp = -1
	ent.cover = int(def.get("coverValue", 0))
	ent.on_break = on_break
	ent.break_param = int(def.get("floodRadius", 0))
	if def.has("break_param"):
		ent.break_param = int(def.get("break_param", 0))
	ent.faction = E.Faction.OBJECT
	ent.name = obj_id
	ent.is_power_source = bool(def.get("isPowerSource", o.get("isPowerSource", false)))
	ent.flammable = bool(def.get("flammable", false))
	# Topple geometry (E1.3): height + fall direction. "down"/"away_from_impact" are codes.
	if on_break == E.OnBreak.TOPPLE:
		ent.topple_height = int(def.get("height", 2))
		ent.fall_dir = _fall_dir_code(def.get("fall_dir", "away_from_impact"))
	s.add_entity(ent)

	# Mirror cover + a blocksLoS concealment onto the tile.
	if ent.cover > 0:
		s.tile(pos).cover = ent.cover
	if bool(def.get("blocksLoS", false)):
		s.tile(pos).status_layer |= E.L_CONCEAL

	# Rigged sculpture (E5): the object conceals a hidden cycling trap on its own tile that
	# arms when the sculpture is destroyed — modeled by pre-placing a DISABLED trap here that
	# the breaker's resolver can later enable. For determinism + testability we place the
	# trap armed-but-dormant and tag the tile; the trap fires once the object is gone.
	var rigged = o.get("rigged", "")
	if typeof(rigged) == TYPE_STRING and rigged != "":
		_set_hazard_on_tile(s.tile(pos), rigged)
		s.tile(pos).trap_active = false   # dormant until the sculpture is destroyed
	return ent


static func _fall_dir_code(code) -> Vector2i:
	match str(code):
		"down": return Vector2i(0, 1)      # a chandelier topples DOWN onto its floor tiles
		"up": return Vector2i(0, -1)
		"left": return Vector2i(-1, 0)
		"right": return Vector2i(1, 0)
		_: return Vector2i.ZERO            # "away_from_impact" — resolved at break time


# ---- hazards (layout.hazards) -------------------------------------------------
static func _place_hazard(s: SimState, hz: Dictionary) -> void:
	# A hazard may be a single tile ("at": {x,y}) or a rectangular region.
	var name: String = hz.get("hazard", "")
	if name == "":
		return
	if hz.has("region"):
		var r: Dictionary = hz["region"]
		var x0 := int(r.get("x", 0)); var y0 := int(r.get("y", 0))
		var rw := int(r.get("w", 1)); var rh := int(r.get("h", 1))
		for yy in range(y0, y0 + rh):
			for xx in range(x0, x0 + rw):
				if s.in_bounds(Vector2i(xx, yy)):
					_apply_hazard_name(s.tile(Vector2i(xx, yy)), name)
	else:
		var at: Dictionary = hz.get("at", {"x": int(hz.get("x", 0)), "y": int(hz.get("y", 0))})
		var p := Vector2i(int(at.get("x", 0)), int(at.get("y", 0)))
		if s.in_bounds(p):
			_apply_hazard_name(s.tile(p), name)


# ---- enemies ------------------------------------------------------------------
static func _place_enemy(s: SimState, db, es: Dictionary, ambush_default: bool) -> void:
	var at: Dictionary = es.get("at", {})
	var pos := Vector2i(int(at.get("x", 0)), int(at.get("y", 0)))
	if not s.in_bounds(pos):
		return
	var enemy_id: String = es.get("enemy", "truncheon_guard")
	var def: Dictionary = db.enemy_def(enemy_id)
	var stats: Dictionary = def.get("stats", {})
	var e := SimEntity.new()
	e.is_unit = true
	e.pos = pos
	e.mass = int(MASS_MAP.get(stats.get("mass", "medium"), E.Mass.MEDIUM))
	e.hp = int(stats.get("hp", 6))
	e.integrity = -1
	e.faction = E.Faction.ENEMY
	e.name = enemy_id
	# Anchored enemies (Sentry Turret) cannot be displaced.
	if e.mass == E.Mass.ANCHORED:
		e.movable = false
	ContentDB.apply_enemy_def(e, def)
	# Ambush start (E1.7): an Unaware enemy holds until the fight wakes (per-spawn or car-wide).
	if bool(es.get("startsUnaware", false)) or ambush_default:
		e.unaware = true
	s.add_entity(e)


static func _place_starters(s: SimState, spawns: Array) -> void:
	var squad := [
		{"name": "bruiser", "mass": E.Mass.HEAVY, "hp": 12},
		{"name": "marksman", "mass": E.Mass.MEDIUM, "hp": 9},
	]
	for i in range(min(squad.size(), spawns.size())):
		var sp: Dictionary = spawns[i]
		var pos := Vector2i(int(sp.get("x", 0)), int(sp.get("y", 0)))
		if not s.in_bounds(pos):
			continue
		var u := SimEntity.new()
		u.is_unit = true
		u.pos = pos
		u.mass = squad[i]["mass"]
		u.hp = squad[i]["hp"]
		u.integrity = -1
		u.faction = E.Faction.PLAYER
		u.name = squad[i]["name"]
		s.add_entity(u)


# ---- data helpers -------------------------------------------------------------
static func _vec(v) -> Vector2i:
	if v == null or typeof(v) != TYPE_ARRAY or v.size() < 2:
		return Vector2i.ZERO
	return Vector2i(int(v[0]), int(v[1]))

static func _read_json(path: String):
	if not FileAccess.file_exists(path):
		return null
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return null
	var txt := f.get_as_text()
	f.close()
	return JSON.parse_string(txt)

static func _index(data, key: String) -> Dictionary:
	var out: Dictionary = {}
	if data == null:
		return out
	var arr: Array = []
	if data is Dictionary and data.has(key):
		arr = data[key]
	elif data is Array:
		arr = data
	for item in arr:
		if item is Dictionary and item.has("id"):
			out[item["id"]] = item
	return out
