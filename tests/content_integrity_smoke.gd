extends SceneTree
## CONTENT INTEGRITY smoke — the DATA analog of tex_coverage_smoke. Validates that every
## cross-reference between content/ data files resolves to a real definition, so a typo'd id
## (the data-layer version of the barrel_explosive/captain texture bugs) fails loudly instead of
## silently spawning nothing / dropping no reward / doing nothing at runtime.
##
## Checks (all data-only, headless, can't shift balance):
##   A. every car enemySpawns[].enemy            -> roster.json / captains.json id
##   B. every car cover[].object + objects[].object -> objects.json id
##      (an ENEMY or HAZARD id in cover[]/objects[] is now a HARD FAIL — the loaders build
##       those as inert generic props; enemies go in enemySpawns[], hazards in hazards[])
##   C. every car allowedModifiers[]             -> modifiers.json id
##   D. every car hazards[].hazard + tileFields[].hazard -> hazards.json id
##   E. every modifier effect hazard/object ref  -> hazards.json / objects.json id
##   F. every enemy/captain abilities[]          -> an abilities/*.json id
##   G. every ability spawn_enemy.enemy ref      -> roster.json / captains.json id
##   H. every car-placed hazard (hazards[]/tileFields[].hazard/rigged) is LOADER-MAPPED
##      (SetpieceLoader.PLACEABLE_HAZARDS) so an authored hazard can't silently no-op;
##      every onBreakOverride names a SetpieceLoader.ONBREAK_MAP category
##   I. no objects[]/cover[]/enemySpawns[] placement sits ON a layout.hazards[] tile
##      (the finale coolant-tank-on-plate / robot-on-steam-vent class)
##   J. finale: >=2 sentry_turret in enemySpawns[]; the_conductor NOT in enemySpawns[]
##      (EngineVault instantiates it — authoring it too would double-spawn)
##   K. section theming: every car type that has a Section-4 template also has Section-1
##      AND Section-2 templates, so RunGenerator's any-section fallback can never pull a
##      First-class set-piece into the Tail; Section 1 has a real combat backbone (>=3)
##
## Run: godot --headless --path . --script res://tests/content_integrity_smoke.gd

var _pass: int = 0
var _fail: int = 0
var _fails: Array = []
var _findings: Array = []   # cross-registry placements: valid ids, but semantically suspect (not failures)

# onBreak categories (objects.json onBreak / loader ONBREAK_MAP) — a modifier effect may name one of
# these in its "hazard" field (e.g. overpressure: destructible_break_triggers hazard "flood"), which is
# an onBreak directive, NOT a hazards.json id. Accept both so that isn't a false positive.
const ONBREAK_CATS := {"none": true, "flood": true, "explode": true, "collapse": true, "spill_fire": true, "topple": true}

# The engine-side loader — source of truth for which hazard names an authored placement can
# actually map (check H) and which onBreak categories exist.
const SetpieceLoader = preload("res://core/setpiece_loader.gd")
const AbilitySystem = preload("res://core/ability_system.gd")
const ModifierSystem = preload("res://core/run/modifier_system.gd")
const E = preload("res://core/sim_enums.gd")

# Every car type CarTemplate may declare (GDD §21 / content README schema) — check K.
const CAR_TYPES := {
	"combat": true, "flood": true, "upgrade": true, "bourgeois": true, "recruit": true,
	"event": true, "rest": true, "shop": true, "captain": true, "engine": true,
}

var enemy_ids: Dictionary = {}
var object_ids: Dictionary = {}
var modifier_ids: Dictionary = {}
var hazard_ids: Dictionary = {}
var ability_ids: Dictionary = {}
var trait_ids: Dictionary = {}


func _initialize() -> void:
	print("\n=== COLDSPINE — CONTENT INTEGRITY smoke (cross-reference guard) ===")
	enemy_ids = _id_set("res://content/enemies/roster.json", "enemies")
	_merge(enemy_ids, _id_set("res://content/enemies/captains.json", "enemies"))
	object_ids = _id_set("res://content/objects/objects.json", "objects")
	modifier_ids = _id_set("res://content/modifiers/modifiers.json", "modifiers")
	hazard_ids = _id_set("res://content/hazards/hazards.json", "hazards")
	ability_ids = _ability_id_set()
	trait_ids = _id_set("res://content/traits/traits.json", "traits")
	ok(enemy_ids.size() >= 15 and object_ids.size() >= 20 and modifier_ids.size() >= 12
		and hazard_ids.size() >= 12 and ability_ids.size() >= 15 and trait_ids.size() >= 15,
		"[content] registries loaded (enemies %d, objects %d, mods %d, hazards %d, abilities %d, traits %d)" % [
			enemy_ids.size(), object_ids.size(), modifier_ids.size(), hazard_ids.size(), ability_ids.size(), trait_ids.size()])

	check_cars()
	check_modifiers()
	check_enemy_abilities()
	check_archetypes()
	check_finale_defenders()
	check_section_theming()
	check_effect_kind_registry()

	if not _findings.is_empty():
		print("\n--- FINDINGS (valid ids placed in the wrong registry — NOT failures; owner's call, balance-shifting to fix) ---")
		for w in _findings:
			print("    [FINDING] " + w)
	print("\n--- CONTENT INTEGRITY: %d passed, %d failed, %d findings ---" % [_pass, _fail, _findings.size()])
	for f in _fails:
		print("    FAIL: " + f)
	if _fail == 0:
		print("CONTENT INTEGRITY GREEN — every cross-reference resolves (findings are advisory, see above).")
	quit(0 if _fail == 0 else 1)


func _finding(msg: String) -> void:
	_findings.append(msg)


func ok(cond: bool, msg: String) -> void:
	if cond:
		_pass += 1
	else:
		_fail += 1
		_fails.append(msg)
		print("    [FAIL] " + msg)


# ============================ CHECKS ==========================================
func check_cars() -> void:
	var d = DirAccess.open("res://content/cars")
	if d == null:
		ok(false, "[content] content/cars dir opens")
		return
	d.list_dir_begin()
	var fn: String = d.get_next()
	var car_count := 0
	while fn != "":
		if fn.ends_with(".json"):
			car_count += 1
			var car = JSON.parse_string(FileAccess.get_file_as_string("res://content/cars/" + fn))
			if typeof(car) == TYPE_DICTIONARY:
				_check_car(fn, car)
		fn = d.get_next()
	d.list_dir_end()
	ok(car_count >= 20, "[content] swept the car library (%d cars)" % car_count)


func _check_car(fn: String, car: Dictionary) -> void:
	for sp in _arr(car, "enemySpawns"):
		if typeof(sp) == TYPE_DICTIONARY and sp.has("enemy"):
			ok(enemy_ids.has(str(sp["enemy"])), "[content] %s: enemySpawn '%s' is a real enemy/captain" % [fn, sp["enemy"]])
	var layout: Dictionary = _dict(car, "layout")
	for grp in ["cover", "objects"]:
		for o in _arr(layout, grp):
			if typeof(o) != TYPE_DICTIONARY:
				continue
			if o.has("object"):
				_check_object_ref(fn, grp, str(o["object"]))
			# H: a rigged sculpture's hidden trap must be a real, loader-mapped hazard.
			if o.has("rigged") and str(o["rigged"]) != "":
				var rg: String = str(o["rigged"])
				ok(hazard_ids.has(rg), "[content] %s: rigged '%s' exists in hazards.json" % [fn, rg])
				ok(SetpieceLoader.PLACEABLE_HAZARDS.has(rg),
					"[content] %s: rigged '%s' is loader-mapped (SetpieceLoader.PLACEABLE_HAZARDS)" % [fn, rg])
			# H: an onBreakOverride must name a real loader onBreak category.
			if o.has("onBreakOverride"):
				ok(SetpieceLoader.ONBREAK_MAP.has(str(o["onBreakOverride"])),
					"[content] %s: onBreakOverride '%s' is a loader onBreak category" % [fn, o["onBreakOverride"]])
	for h in _arr(layout, "hazards"):
		if typeof(h) == TYPE_DICTIONARY and h.has("hazard"):
			ok(hazard_ids.has(str(h["hazard"])), "[content] %s: hazard '%s' exists" % [fn, h["hazard"]])
			# H: the id must also be one SetpieceLoader can PLACE — a valid-but-unmapped id
			# (e.g. "explosion") would silently no-op at load time.
			ok(SetpieceLoader.PLACEABLE_HAZARDS.has(str(h["hazard"])),
				"[content] %s: hazard '%s' is loader-mapped (SetpieceLoader.PLACEABLE_HAZARDS)" % [fn, h["hazard"]])
	for tf in _arr(layout, "tileFields"):
		if typeof(tf) == TYPE_DICTIONARY and tf.has("hazard"):
			ok(hazard_ids.has(str(tf["hazard"])), "[content] %s: tileField hazard '%s' exists" % [fn, tf["hazard"]])
			ok(SetpieceLoader.PLACEABLE_HAZARDS.has(str(tf["hazard"])),
				"[content] %s: tileField hazard '%s' is loader-mapped" % [fn, tf["hazard"]])
	for m in _arr(car, "allowedModifiers"):
		ok(modifier_ids.has(str(m)), "[content] %s: allowedModifier '%s' exists" % [fn, m])
	_check_hazard_overlaps(fn, car, layout)


## I: nothing may be PLACED on a layout.hazards[] tile — an object parked on a cycling plate
## blocks the bank, an enemy spawned on a vent eats it on turn 1 (the finale had both).
func _check_hazard_overlaps(fn: String, car: Dictionary, layout: Dictionary) -> void:
	var haz_tiles: Dictionary = {}
	for h in _arr(layout, "hazards"):
		if typeof(h) != TYPE_DICTIONARY:
			continue
		var hname: String = str(h.get("hazard", ""))
		if h.has("region") and typeof(h["region"]) == TYPE_DICTIONARY:
			var r: Dictionary = h["region"]
			for yy in range(int(r.get("y", 0)), int(r.get("y", 0)) + int(r.get("h", 1))):
				for xx in range(int(r.get("x", 0)), int(r.get("x", 0)) + int(r.get("w", 1))):
					haz_tiles[Vector2i(xx, yy)] = hname
		else:
			var at: Dictionary = h.get("at", {"x": int(h.get("x", 0)), "y": int(h.get("y", 0))})
			haz_tiles[Vector2i(int(at.get("x", 0)), int(at.get("y", 0)))] = hname
	if haz_tiles.is_empty():
		return
	for grp in ["cover", "objects"]:
		for o in _arr(layout, grp):
			if typeof(o) != TYPE_DICTIONARY:
				continue
			for yy in range(int(o.get("y", 0)), int(o.get("y", 0)) + int(o.get("h", 1))):
				for xx in range(int(o.get("x", 0)), int(o.get("x", 0)) + int(o.get("w", 1))):
					var p := Vector2i(xx, yy)
					ok(not haz_tiles.has(p), "[content] %s: %s '%s' at %s sits on hazard '%s' tile" % [
						fn, grp, o.get("object", "?"), str(p), haz_tiles.get(p, "")])
	for sp in _arr(car, "enemySpawns"):
		if typeof(sp) != TYPE_DICTIONARY:
			continue
		var a: Dictionary = _dict(sp, "at")
		var ep := Vector2i(int(a.get("x", 0)), int(a.get("y", 0)))
		ok(not haz_tiles.has(ep), "[content] %s: enemySpawn '%s' at %s sits on hazard '%s' tile" % [
			fn, sp.get("enemy", "?"), str(ep), haz_tiles.get(ep, "")])


func _check_object_ref(fn: String, grp: String, oid: String) -> void:
	# A real object id passes. A valid HAZARD/ENEMY id placed in objects[] is now a HARD FAIL —
	# the loaders build it as an inert medium-mass prop (no hazard cycling, no turret fire); that
	# is exactly how the finale antechamber turrets shipped unarmed. Hazards belong in
	# layout.hazards[], enemies in enemySpawns[]. A totally-unknown id is a typo — also a FAIL.
	if object_ids.has(oid):
		ok(true, "[content] %s: %s object '%s' exists" % [fn, grp, oid])
	elif hazard_ids.has(oid):
		ok(false, "[content] %s: %s names HAZARD '%s' — would load as an INERT object; move it to layout.hazards[]" % [fn, grp, oid])
	elif enemy_ids.has(oid):
		ok(false, "[content] %s: %s names ENEMY '%s' — would load as an INERT object (no fire); move it to enemySpawns[]" % [fn, grp, oid])
	else:
		ok(false, "[content] %s: %s object '%s' resolves to NO definition (typo / missing content)" % [fn, grp, oid])


## J: the finale's scripted Phase-1 defenders are REAL — data side AND build side. Data: >=2
## sentry_turret authored in enemySpawns[] (objects[] builds them inert — how they originally
## shipped unarmed) and the_conductor NOT authored (EngineVault._add_conductor instantiates it
## on the dais; authoring it too would double-spawn now that the finale paths keep scripted
## spawns via _strip_starters). Build: the SetpieceLoader state the finale starts from actually
## contains the armed defenders as anchored ENEMY units plus the antechamber elite.
func check_finale_defenders() -> void:
	var car = JSON.parse_string(FileAccess.get_file_as_string("res://content/cars/engine_conductor_vault.json"))
	if typeof(car) != TYPE_DICTIONARY:
		ok(false, "[finale] engine_conductor_vault.json parses")
		return
	var turret_spawns := 0
	var conductor_spawns := 0
	for sp in _arr(car, "enemySpawns"):
		if typeof(sp) == TYPE_DICTIONARY:
			match str(sp.get("enemy", "")):
				"sentry_turret": turret_spawns += 1
				"the_conductor": conductor_spawns += 1
	ok(turret_spawns >= 2, "[finale] >=2 sentry_turret authored in enemySpawns[] (found %d)" % turret_spawns)
	ok(conductor_spawns == 0, "[finale] the_conductor NOT authored in enemySpawns[] (EngineVault adds it; found %d)" % conductor_spawns)
	var s = SetpieceLoader.load_car("engine_conductor_vault")
	if s == null:
		ok(false, "[finale] SetpieceLoader builds engine_conductor_vault")
		return
	var turrets := 0
	var chiefs := 0
	var conductors := 0
	for id in s.entity_ids_sorted():
		var e = s.entities.get(id)
		if e == null or not e.is_unit or int(e.faction) != E.Faction.ENEMY:
			continue
		match str(e.name):
			"sentry_turret":
				turrets += 1
				ok(not e.movable, "[finale] built turret (entity %d) is anchored (movable=false)" % id)
			"captain_chief_of_security":
				chiefs += 1
			"the_conductor":
				conductors += 1
	ok(turrets >= 2, "[finale] built state has >=2 ENEMY sentry_turret UNITS (found %d)" % turrets)
	ok(chiefs == 1, "[finale] built state keeps the antechamber elite captain_chief_of_security (found %d)" % chiefs)
	ok(conductors == 0, "[finale] built state has NO pre-spawned the_conductor (found %d)" % conductors)


## K: section theming — the deck census RunGenerator draws from. Every car declares a known
## type and a section in 1..5 (engine = Section 5 only); any type that has a Section-4
## (First-class) template must ALSO have Section-1 and Section-2 templates, so
## RunGenerator._pick_template's any-section fallback can never pull a First-class set-piece
## into the Tail; and Section 1 keeps a real combat backbone (>=3 templates) so early runs
## aren't the same fight on repeat.
func check_section_theming() -> void:
	var by_type: Dictionary = {}   # type -> {section -> template count}
	var d = DirAccess.open("res://content/cars")
	if d == null:
		ok(false, "[theming] content/cars dir opens")
		return
	d.list_dir_begin()
	var fn: String = d.get_next()
	while fn != "":
		if fn.ends_with(".json"):
			var car = JSON.parse_string(FileAccess.get_file_as_string("res://content/cars/" + fn))
			if typeof(car) == TYPE_DICTIONARY:
				var t: String = str(car.get("type", ""))
				var sec: int = int(car.get("section", -1))
				ok(CAR_TYPES.has(t), "[theming] %s: type '%s' is a known car type" % [fn, t])
				ok(sec >= 1 and sec <= 5, "[theming] %s: section %d is in 1..5" % [fn, sec])
				if t == "engine":
					ok(sec == 5, "[theming] %s: engine car is Section 5 (found %d)" % [fn, sec])
				if not by_type.has(t):
					by_type[t] = {}
				by_type[t][sec] = int(by_type[t].get(sec, 0)) + 1
		fn = d.get_next()
	d.list_dir_end()
	var types: Array = by_type.keys()
	types.sort()
	for t in types:
		var secs: Dictionary = by_type[t]
		if secs.has(4):
			ok(secs.has(1) and secs.has(2),
				"[theming] type '%s' has a Section-4 template AND Section-1+2 templates (fallback can't pull First class into the Tail)" % t)
	var s1_combat: int = int(_dict(by_type, "combat").get(1, 0))
	ok(s1_combat >= 3, "[theming] Section 1 combat backbone has >=3 templates (found %d)" % s1_combat)


func check_modifiers() -> void:
	var data = JSON.parse_string(FileAccess.get_file_as_string("res://content/modifiers/modifiers.json"))
	if typeof(data) != TYPE_DICTIONARY:
		return
	for mod in _arr(data, "modifiers"):
		if typeof(mod) != TYPE_DICTIONARY:
			continue
		var mid: String = str(mod.get("id", "?"))
		for eff in _arr(mod, "effects"):
			if typeof(eff) != TYPE_DICTIONARY:
				continue
			if eff.has("hazard"):
				var hz: String = str(eff["hazard"])
				ok(hazard_ids.has(hz) or ONBREAK_CATS.has(hz), "[content] modifier '%s' effect hazard/onBreak '%s' is valid" % [mid, hz])
			if eff.has("object"):
				ok(object_ids.has(str(eff["object"])), "[content] modifier '%s' effect object '%s' exists" % [mid, eff["object"]])
			if eff.has("withSource"):
				ok(object_ids.has(str(eff["withSource"])), "[content] modifier '%s' withSource '%s' exists" % [mid, eff["withSource"]])


func check_enemy_abilities() -> void:
	# F + G: enemy/captain abilities resolve, and abilities that spawn an enemy reference a real one.
	for path in ["res://content/enemies/roster.json", "res://content/enemies/captains.json"]:
		var data = JSON.parse_string(FileAccess.get_file_as_string(path))
		if typeof(data) != TYPE_DICTIONARY:
			continue
		for e in _arr(data, "enemies"):
			if typeof(e) != TYPE_DICTIONARY:
				continue
			var eid: String = str(e.get("id", "?"))
			for ab in _arr(e, "abilities"):
				ok(ability_ids.has(str(ab)), "[content] enemy '%s' ability '%s' is defined" % [eid, ab])
	# G: scan every ability effect for spawn_enemy references.
	var d = DirAccess.open("res://content/abilities")
	if d == null:
		return
	d.list_dir_begin()
	var fn: String = d.get_next()
	while fn != "":
		if fn.ends_with(".json"):
			var data = JSON.parse_string(FileAccess.get_file_as_string("res://content/abilities/" + fn))
			_scan_spawn_refs(fn, data)
		fn = d.get_next()
	d.list_dir_end()


func check_archetypes() -> void:
	# Every archetype's startingAbilities / abilityTree picks / capstone must resolve to a real ability
	# (a level-up offering a phantom ability = a runtime bug), and traitAffinity / innateTrait to real traits.
	var d = DirAccess.open("res://content/archetypes")
	if d == null:
		ok(false, "[content] content/archetypes dir opens")
		return
	d.list_dir_begin()
	var fn: String = d.get_next()
	var n := 0
	while fn != "":
		if fn.ends_with(".json"):
			n += 1
			var a = JSON.parse_string(FileAccess.get_file_as_string("res://content/archetypes/" + fn))
			if typeof(a) == TYPE_DICTIONARY:
				_check_archetype(fn, a)
		fn = d.get_next()
	d.list_dir_end()
	ok(n >= 5, "[content] swept the archetypes (%d)" % n)


func _check_archetype(fn: String, a: Dictionary) -> void:
	var aid: String = str(a.get("id", "?"))
	var ab_refs: Array = []
	for x in _arr(a, "startingAbilities"):
		ab_refs.append(str(x))
	if a.has("capstone") and a["capstone"] != null:
		ab_refs.append(str(a["capstone"]))
	for tier in _arr(a, "abilityTree"):
		if typeof(tier) == TYPE_ARRAY:
			for opt in tier:
				ab_refs.append(str(opt))
	for ab in ab_refs:
		ok(ability_ids.has(ab), "[content] archetype '%s' ability '%s' is defined" % [aid, ab])
	for t in _arr(a, "traitAffinity"):
		ok(trait_ids.has(str(t)), "[content] archetype '%s' traitAffinity '%s' is a real trait" % [aid, t])
	if a.has("innateTrait") and a["innateTrait"] != null:
		var it: String = str(a["innateTrait"])
		if trait_ids.has(it):
			ok(true, "[content] archetype '%s' innateTrait '%s' is a real trait" % [aid, it])
		else:
			# Not in traits.json — may be a special archetype MECHANIC marker (e.g. firebrand 'momentum',
			# driven by momentum_grants ability effects) rather than a trait. Advisory, not a hard fail.
			_finding("%s: innateTrait '%s' is not in traits.json — likely a special archetype mechanic (firebrand 'momentum'), else a missing trait. Confirm intent." % [aid, it])


func _scan_spawn_refs(fn: String, node) -> void:
	# Recursively find any {"kind":"spawn_enemy","enemy":<id>} and validate the id.
	if typeof(node) == TYPE_DICTIONARY:
		if str(node.get("kind", "")) == "spawn_enemy" and node.has("enemy"):
			ok(enemy_ids.has(str(node["enemy"])), "[content] %s: spawn_enemy '%s' is a real enemy" % [fn, node["enemy"]])
		for k in node.keys():
			_scan_spawn_refs(fn, node[k])
	elif typeof(node) == TYPE_ARRAY:
		for v in node:
			_scan_spawn_refs(fn, v)


# ============================ HELPERS =========================================
# L. Every effect "kind" authored anywhere in content must be accounted for by a handler
# set — ACTIVE/PASSIVE/NATIVE/DEFERRED (AbilitySystem) or MODIFIER_KINDS/DEFERRED (ModifierSystem).
# This is the guard that a newly-authored effect kind can never silently do nothing at runtime:
# either it is implemented, or it is on a LOUD deferred allowlist. (Progression-real batch.)
func check_effect_kind_registry() -> void:
	var handled: Dictionary = {}
	for src in [AbilitySystem.ACTIVE_KINDS, AbilitySystem.PASSIVE_KINDS,
			AbilitySystem.NATIVE_KINDS, AbilitySystem.DEFERRED_KINDS,
			ModifierSystem.MODIFIER_KINDS, ModifierSystem.DEFERRED_MODIFIER_KINDS]:
		for k in src.keys():
			handled[str(k)] = true
	var referenced: Dictionary = {}
	for dir in ["res://content/abilities", "res://content/traits",
			"res://content/modifiers", "res://content/items"]:
		_collect_effect_kinds(dir, referenced)
	ok(referenced.size() >= 20,
		"[content] effect-kind registry swept content (%d distinct kinds)" % referenced.size())
	for kind in referenced.keys():
		ok(handled.has(kind),
			"[content] effect kind '%s' is handled or on a loud deferred allowlist" % kind)


# Recursively walk every JSON in `dir`, collecting the "kind" of each entry inside any
# "effects" array (the only place an effect kind is authored — avoids reward/car "kind" noise).
func _collect_effect_kinds(dir: String, out: Dictionary) -> void:
	var d = DirAccess.open(dir)
	if d == null:
		return
	d.list_dir_begin()
	var fn: String = d.get_next()
	while fn != "":
		if fn.ends_with(".json"):
			var data = JSON.parse_string(FileAccess.get_file_as_string(dir + "/" + fn))
			_walk_for_effects(data, out)
		fn = d.get_next()
	d.list_dir_end()


func _walk_for_effects(node, out: Dictionary) -> void:
	if typeof(node) == TYPE_DICTIONARY:
		for key in node.keys():
			var v = node[key]
			if key == "effects" and typeof(v) == TYPE_ARRAY:
				for eff in v:
					if typeof(eff) == TYPE_DICTIONARY and eff.has("kind"):
						out[str(eff["kind"])] = true
			_walk_for_effects(v, out)
	elif typeof(node) == TYPE_ARRAY:
		for item in node:
			_walk_for_effects(item, out)


func _id_set(path: String, list_key: String) -> Dictionary:
	var out: Dictionary = {}
	if not FileAccess.file_exists(path):
		ok(false, "[content] registry file missing: " + path)
		return out
	var data = JSON.parse_string(FileAccess.get_file_as_string(path))
	if typeof(data) == TYPE_DICTIONARY and data.has(list_key):
		for entry in data[list_key]:
			if typeof(entry) == TYPE_DICTIONARY and entry.has("id"):
				out[str(entry["id"])] = true
	return out


func _ability_id_set() -> Dictionary:
	var out: Dictionary = {}
	var d = DirAccess.open("res://content/abilities")
	if d == null:
		return out
	d.list_dir_begin()
	var fn: String = d.get_next()
	while fn != "":
		if fn.ends_with(".json"):
			var data = JSON.parse_string(FileAccess.get_file_as_string("res://content/abilities/" + fn))
			if typeof(data) == TYPE_DICTIONARY:
				if data.has("abilities") and typeof(data["abilities"]) == TYPE_ARRAY:
					for a in data["abilities"]:
						if typeof(a) == TYPE_DICTIONARY and a.has("id"):
							out[str(a["id"])] = true
				else:
					for k in data.keys():
						if k == "_schema":
							continue
						out[str(k)] = true
						if typeof(data[k]) == TYPE_DICTIONARY and data[k].has("id"):
							out[str(data[k]["id"])] = true
		fn = d.get_next()
	d.list_dir_end()
	return out


func _merge(into: Dictionary, other: Dictionary) -> void:
	for k in other.keys():
		into[k] = true


func _arr(d, key: String) -> Array:
	if typeof(d) == TYPE_DICTIONARY and d.has(key) and typeof(d[key]) == TYPE_ARRAY:
		return d[key]
	return []


func _dict(d, key: String) -> Dictionary:
	if typeof(d) == TYPE_DICTIONARY and d.has(key) and typeof(d[key]) == TYPE_DICTIONARY:
		return d[key]
	return {}
