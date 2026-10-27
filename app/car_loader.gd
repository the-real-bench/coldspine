class_name CarLoader
## Parses a content/cars/*.json CarTemplate (GDD §21) into a deterministic SimState,
## resolving object/enemy ids against content/objects + content/enemies. Falls back
## gracefully: if a referenced def is missing, sane defaults from the schema notes are
## used. Player squad is placed on the car's player spawn points (Phase 0-i: a fixed
## starter cell of bruiser + marksman until the Draft, Sub-Spec C, lands).
##
## Engine-agnostic data → RefCounted SimState. No SceneTree deps.

const SimState = preload("res://core/sim_state.gd")
const SimEntity = preload("res://core/sim_entity.gd")
const IntRng = preload("res://core/int_rng.gd")
const E = preload("res://core/sim_enums.gd")
const SetpieceLoader = preload("res://core/setpiece_loader.gd")

const CARS_DIR := "res://content/cars/"
const OBJ_PATH := "res://content/objects/objects.json"
const ENEMY_PATHS := ["res://content/enemies/roster.json", "res://content/enemies/captains.json"]
const ARCH_DIR := "res://content/archetypes/"

const MASS_MAP := {"light": E.Mass.LIGHT, "medium": E.Mass.MEDIUM, "heavy": E.Mass.HEAVY, "anchored": E.Mass.ANCHORED}
const ONBREAK_MAP := {
	"none": E.OnBreak.NONE, "flood": E.OnBreak.FLOOD, "explode": E.OnBreak.EXPLODE,
	"collapse": E.OnBreak.COLLAPSE, "spill_fire": E.OnBreak.SPILL_FIRE,
	"topple": E.OnBreak.COLLAPSE,   # E1.3 not in the enum yet → fall back to collapse (per content README #2)
}


## Load a car by id (e.g. "flood_aquaria_01"). Returns a built SimState, or null on
## hard failure (missing file / unparseable). `seed` seeds the run PRNG.
static func load_car(car_id: String, seed: int = 0xC01D5) -> SimState:
	var path := CARS_DIR + car_id + ".json"
	var data = _read_json(path)
	if data == null:
		push_warning("CarLoader: cannot read %s" % path)
		return null
	return build_from_data(data, seed)

static func build_from_data(data: Dictionary, seed: int = 0xC01D5) -> SimState:
	var objs := _index_by_id(_read_json(OBJ_PATH), "objects")
	var enemies := {}
	for p in ENEMY_PATHS:
		var d = _read_json(p)
		if d != null:
			for k in _index_by_id(d, "enemies").keys():
				enemies[k] = _index_by_id(d, "enemies")[k]

	var s := SimState.new()
	var gs: Dictionary = data.get("gridSize", {"w": 12, "h": 8})
	s.init_grid(int(gs.get("w", 12)), int(gs.get("h", 8)))
	s.rng = IntRng.new(seed)

	var layout: Dictionary = data.get("layout", {})

	# 1. Walls (rectangular runs).
	for w in layout.get("walls", []):
		var x0 := int(w.get("x", 0)); var y0 := int(w.get("y", 0))
		var ww := int(w.get("w", 1)); var hh := int(w.get("h", 1))
		for yy in range(y0, y0 + hh):
			for xx in range(x0, x0 + ww):
				s.set_wall(Vector2i(xx, yy))

	# 2. Cover objects (placed as object entities OR tile cover, by def coverValue).
	for c in layout.get("cover", []):
		_place_object(s, objs, c.get("object", "crate"), Vector2i(int(c.get("x", 0)), int(c.get("y", 0))))

	# 3. Breakable / interactive objects.
	for o in layout.get("objects", []):
		var ent = _place_object(s, objs, o.get("object", "crate"), Vector2i(int(o.get("x", 0)), int(o.get("y", 0))))
		if ent != null and o.get("isPowerSource", false):
			ent.is_power_source = true

	# 4. Hazard tiles — delegate to the engine-side SetpieceLoader so the two loaders can
	#    never diverge on the hazard schema (the modern {"at":{x,y}} / "region" placement
	#    forms + the full hazard-kind map; the old flat x/y read landed everything at 0,0).
	for hz in layout.get("hazards", []):
		SetpieceLoader._place_hazard(s, hz)

	# 5. Enemies.
	for es in data.get("enemySpawns", []):
		var at: Dictionary = es.get("at", {})
		_place_enemy(s, enemies, es.get("enemy", "truncheon_guard"), Vector2i(int(at.get("x", 0)), int(at.get("y", 0))))

	# 6. Player squad on the player spawn points (Phase 0-i fixed starters).
	_place_starters(s, layout.get("spawnPoints", {}).get("player", []))

	return s


# ---- placement helpers --------------------------------------------------------
static func _place_object(s: SimState, objs: Dictionary, obj_id: String, pos: Vector2i):
	if not s.in_bounds(pos):
		return null
	var def: Dictionary = objs.get(obj_id, {})
	var cover_val: int = int(def.get("coverValue", 0))
	var mass: int = int(MASS_MAP.get(def.get("mass", "medium"), E.Mass.MEDIUM))
	var integ: int = int(def.get("integrity", 3))
	var on_break: int = int(ONBREAK_MAP.get(def.get("onBreak", "none"), E.OnBreak.NONE))
	var flood_r: int = int(def.get("floodRadius", 0))
	var anchored: bool = (mass == E.Mass.ANCHORED)

	var o := SimEntity.new()
	o.is_unit = false
	o.pos = pos
	o.mass = mass
	o.movable = not anchored
	o.integrity = integ
	o.hp = -1
	o.cover = cover_val
	o.on_break = on_break
	o.break_param = flood_r
	o.faction = E.Faction.OBJECT
	o.name = obj_id
	o.is_power_source = bool(def.get("isPowerSource", false))
	s.add_entity(o)
	# Mirror cover onto the tile so LoS / to-hit honor it even after the object dies.
	if cover_val > 0 and s.in_bounds(pos):
		s.tile(pos).cover = cover_val
	return o

static func _place_enemy(s: SimState, enemies: Dictionary, enemy_id: String, pos: Vector2i) -> void:
	if not s.in_bounds(pos):
		return
	var def: Dictionary = enemies.get(enemy_id, {})
	var stats: Dictionary = def.get("stats", {})
	var e := SimEntity.new()
	e.is_unit = true
	e.pos = pos
	e.mass = int(MASS_MAP.get(stats.get("mass", "medium"), E.Mass.MEDIUM))
	e.hp = int(stats.get("hp", 6))
	e.integrity = -1
	e.faction = E.Faction.ENEMY
	e.name = enemy_id
	s.add_entity(e)

static func _place_starters(s: SimState, spawns: Array) -> void:
	# Phase 0-i fixed cell: a Bruiser (displacement engine) + a Marksman. Extra spawn
	# points beyond the squad are left empty; fewer spawns clamp the squad.
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
static func _read_json(path: String):
	if not FileAccess.file_exists(path):
		return null
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return null
	var txt := f.get_as_text()
	f.close()
	var parsed = JSON.parse_string(txt)
	return parsed

static func _index_by_id(data, key: String) -> Dictionary:
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
