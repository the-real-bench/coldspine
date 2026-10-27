extends SceneTree
## TEX COVERAGE smoke — guards the entity→texture maps in render/car_view.gd against the
## SILENT-FALLBACK bug class. Twice now a spawnable content id had no entry in its *_TEX map and
## fell through to a wrong generic default, ON-SCREEN ONLY (headless draws faction glyphs, so the
## other 13 suites never caught it):
##   - Section Captains are named by id (captain_tail_warden, ...) but those ids weren't in ENEMY_TEX
##     -> every captain + the Conductor rendered as a basic Truncheon Guard.
##   - The explosive barrel's objects.json id is `barrel_explosive`, but OBJ_TEX only had key "barrel"
##     -> the barrel rendered as a CRATE in the deadliest combat room.
##
## This test fails if a spawnable enemy/captain/archetype/object id is NOT explicitly mapped (or, for
## decor, deliberately allow-listed), or if any *_TEX value points at a missing SVG. It is data-only
## and headless — it reads the const maps + the content JSON, instances nothing, and can't shift balance.
##
## Run: godot --headless --path . --script res://tests/tex_coverage_smoke.gd

const CarView = preload("res://render/car_view.gd")
const Pal = preload("res://render/palette.gd")
const E = preload("res://core/sim_enums.gd")
const PLACEHOLDERS := "res://assets/placeholders/"
# Every placeholder token/tile/status/UI SVG shipped (MANIFEST.md total) — the on-disk scan below
# must find and LOAD exactly this many. A new asset bumps this; a silently-unimported one fails loud.
const PLACEHOLDER_COUNT := 79   # 73 base + 5 draft portraits (W5-1) + 1 econ flavor (W5-15)

# Content ids that DELIBERATELY render via a role-exemplar / fallback until bespoke art ships.
# As of fire 10 this is EMPTY — every spawnable enemy/captain/archetype/object id has its own explicit
# *_TEX mapping. A NEW id that is neither mapped nor listed here FAILS the test, which is how the
# captain/barrel/player/hazard-tile fallthrough class gets caught the moment it is introduced.
const FALLBACK_OK := {}

var _pass: int = 0
var _fail: int = 0
var _fails: Array = []


func _initialize() -> void:
	print("\n=== COLDSPINE — TEX COVERAGE smoke (entity→texture map guard) ===")
	test_enemy_ids_have_explicit_tex()
	test_archetype_ids_have_explicit_tex()
	test_object_ids_mapped_or_allowlisted()
	test_every_tex_value_has_a_file()
	test_fallback_stems_exist()
	test_resolver_keys_player_by_archetype()
	test_resolver_maps_every_hazard_tile()
	test_every_placeholder_actually_imports()
	test_candidate_path_order_final_png_wins()
	test_status_icons_resolvable()
	test_section_variant_falls_back_to_base()
	print("\n--- TEX COVERAGE: %d passed, %d failed ---" % [_pass, _fail])
	for f in _fails:
		print("    FAIL: " + f)
	if _fail == 0:
		print("TEX COVERAGE GREEN — every spawnable id maps to real art (no silent fallback).")
	quit(0 if _fail == 0 else 1)


func ok(cond: bool, msg: String) -> void:
	if cond:
		_pass += 1
	else:
		_fail += 1
		_fails.append(msg)
		print("    [FAIL] " + msg)


# ============================ TESTS ===========================================
func test_enemy_ids_have_explicit_tex() -> void:
	# Every grunt (roster.json) AND every elite (captains.json) must have its OWN ENEMY_TEX entry —
	# a boss must never silently fall back to the guard token.
	var ids: Array = _ids_from("res://content/enemies/roster.json", "enemies")
	ids.append_array(_ids_from("res://content/enemies/captains.json", "enemies"))
	ok(ids.size() >= 15, "[tex] found the enemy+captain roster (got %d ids)" % ids.size())
	for id in ids:
		ok(CarView.ENEMY_TEX.has(id), "[tex] enemy/captain id '%s' has an explicit ENEMY_TEX entry (no fallback)" % id)
		if CarView.ENEMY_TEX.has(id):
			ok(CarView.ENEMY_TEX[id] != "enemy_truncheon" or id == "truncheon_guard",
				"[tex] '%s' does not map to the generic guard stem" % id)


func test_archetype_ids_have_explicit_tex() -> void:
	var ids: Array = _archetype_ids()
	ok(ids.size() >= 5, "[tex] found the player archetypes (got %d)" % ids.size())
	for id in ids:
		ok(CarView.UNIT_TEX.has(id), "[tex] archetype id '%s' has an explicit UNIT_TEX entry" % id)


func test_object_ids_mapped_or_allowlisted() -> void:
	var ids: Array = _ids_from("res://content/objects/objects.json", "objects")
	ok(ids.size() >= 20, "[tex] found the object catalog (got %d ids)" % ids.size())
	for id in ids:
		var covered: bool = CarView.OBJ_TEX.has(id) or FALLBACK_OK.has(id)
		ok(covered, "[tex] object id '%s' is mapped in OBJ_TEX or deliberately in FALLBACK_OK" % id)


func test_every_tex_value_has_a_file() -> void:
	# Any map value pointing at art the LOADER can't resolve is a silent broken-art bug — check all
	# four maps through the renderer's own resolution path (not raw file existence).
	for m in [CarView.UNIT_TEX, CarView.ENEMY_TEX, CarView.OBJ_TEX, CarView.STATUS_TEX]:
		for k in m.keys():
			var stem: String = m[k]
			ok(_stem_loads(stem), "[tex] mapped stem '%s' (key '%s') loads via the renderer's path" % [stem, str(k)])


func test_fallback_stems_exist() -> void:
	# The faction/role fallbacks the renderer reaches for when nothing matches must themselves load.
	for stem in ["unit_bruiser", "enemy_truncheon", "obj_crate", "enemy_captain"]:
		ok(_stem_loads(stem), "[tex] fallback stem '%s' loads via the renderer's path" % stem)


func test_resolver_keys_player_by_archetype() -> void:
	# Exercise the actual resolver, locking all three fallthrough fixes:
	#  - a run-deployed player body is named by CALLSIGN but must resolve by archetype_id (not bruiser);
	#  - a fixed-cell starter named by archetype id still resolves;
	#  - enemies/captains/objects resolve by their content id (name).
	var v = CarView.new()
	var cases := [
		[{"is_unit": true, "faction": E.Faction.PLAYER, "name": "Vasquez-04", "archetype_id": "marksman"}, "unit_marksman"],
		[{"is_unit": true, "faction": E.Faction.PLAYER, "name": "Reyes-02", "archetype_id": "saboteur"}, "unit_saboteur"],
		[{"is_unit": true, "faction": E.Faction.PLAYER, "name": "bruiser", "archetype_id": ""}, "unit_bruiser"],
		[{"is_unit": true, "faction": E.Faction.ENEMY, "name": "captain_gardener", "archetype_id": ""}, "enemy_captain_gardener"],
		[{"is_unit": true, "faction": E.Faction.ENEMY, "name": "truncheon_guard", "archetype_id": ""}, "enemy_truncheon"],
		[{"is_unit": false, "faction": E.Faction.OBJECT, "name": "barrel_explosive", "archetype_id": ""}, "obj_barrel"],
	]
	for c in cases:
		var got: String = v._entity_tex_stem(c[0])
		ok(got == c[1], "[tex] resolver: %s -> '%s' (got '%s')" % [str(c[0].get("name")), c[1], got])
	v.free()


func test_resolver_maps_every_hazard_tile() -> void:
	# Every Hazard enum value must map to its OWN tile texture (not the plain-floor fallback) and that
	# SVG must exist — locking the fire-9 fix (lasers/steam/scald/etc. were rendering as floor).
	var v = CarView.new()
	var hazards := {
		E.Hazard.GAP: "tile_gap", E.Hazard.FURNACE: "tile_furnace", E.Hazard.RAIL_LIVE: "tile_rail",
		E.Hazard.PISTON: "tile_piston", E.Hazard.VENT: "tile_vent", E.Hazard.LASER: "tile_laser",
		E.Hazard.PLATE: "tile_plate", E.Hazard.STEAM: "tile_steam", E.Hazard.CONVEYOR: "tile_conveyor",
		E.Hazard.LASER_SWEEP: "tile_laser_sweep", E.Hazard.SCALD: "tile_scald",
	}
	for h in hazards:
		var stem: String = v._terrain_tex_stem({"terrain": E.Terrain.FLOOR, "hazard": h, "cover": 0})
		ok(stem == hazards[h], "[tex] hazard %d -> '%s' (got '%s', not the floor fallback)" % [h, hazards[h], stem])
		ok(_stem_loads(stem), "[tex] hazard tile '%s' loads via the renderer's path" % stem)
	v.free()


func test_every_placeholder_actually_imports() -> void:
	# On-disk scan: EVERY shipped placeholder SVG must load as a Texture2D via ResourceLoader — a
	# file on disk with no .import sidecar is invisible to the renderer. That exact class shipped
	# once: 29 of 73 SVGs (all named captains, 13 objects, 7 hazard tiles, 3 status icons) had no
	# .import, this suite was GREEN on FileAccess.file_exists, and captains rendered as circles.
	# Fix a failure here with: godot --headless --path . --import
	var d = DirAccess.open(PLACEHOLDERS)
	ok(d != null, "[tex] placeholder dir opens")
	if d == null:
		return
	var n: int = 0
	d.list_dir_begin()
	var fn: String = d.get_next()
	while fn != "":
		if fn.ends_with(".svg"):
			n += 1
			var path := PLACEHOLDERS + fn
			var loads: bool = ResourceLoader.exists(path) and load(path) is Texture2D
			ok(loads, "[tex] placeholder '%s' IMPORTS + loads as Texture2D (run --import if it just landed)" % fn)
		fn = d.get_next()
	d.list_dir_end()
	ok(n == PLACEHOLDER_COUNT, "[tex] all %d placeholder SVGs found on disk (got %d — update PLACEHOLDER_COUNT + MANIFEST together)" % [PLACEHOLDER_COUNT, n])


func test_candidate_path_order_final_png_wins() -> void:
	# The drop-in contract (ART_BIBLE §8 / MANIFEST): final art beats the placeholder at the same
	# stem, and .png beats .svg — so a raster final-art pass lands file-by-file with no code churn.
	var got: Array = CarView.tex_candidate_paths("unit_bruiser")
	var want := [
		CarView.FINAL_DIR + "unit_bruiser.png", CarView.FINAL_DIR + "unit_bruiser.svg",
		PLACEHOLDERS + "unit_bruiser.png", PLACEHOLDERS + "unit_bruiser.svg",
	]
	ok(got == want, "[tex] candidate order is final-png > final-svg > placeholder-png > placeholder-svg (got %s)" % str(got))


func test_status_icons_resolvable() -> void:
	# Every status badge flag the renderer composes (Pal.STATUS_ORDER, incl. the render-only
	# OVERWATCH eye) must have a STATUS_TEX icon stem that actually loads — the §6.1 color+shape
	# (colorblind-safe) contract lives in these icon SVGs.
	for pair in Pal.STATUS_ORDER:
		var flag: int = pair[0]
		ok(CarView.STATUS_TEX.has(flag), "[tex] status flag %d ('%s') has a STATUS_TEX icon entry" % [flag, pair[1]])
		if CarView.STATUS_TEX.has(flag):
			ok(_stem_loads(CarView.STATUS_TEX[flag]), "[tex] status icon '%s' loads" % CarView.STATUS_TEX[flag])
	# S_BLEEDING shares the death-window icon with S_DOWNED (status_icons.md sheet rule).
	ok(CarView.STATUS_TEX.get(E.S_BLEEDING, "") == "status_bleeding",
		"[tex] S_BLEEDING shares status_bleeding with S_DOWNED")


func test_section_variant_falls_back_to_base() -> void:
	# §4 section re-skin convention: `<stem>__s<N>` (N=1..5) wins when the variant file ships, else
	# the plain stem. No variant files ship yet, so _tile_tex must fall back to the base texture for
	# every section, and section 0 (the default) must skip the variant probe entirely.
	var v = CarView.new()
	ok(v.section == 0, "[tex] CarView defaults to section 0 (no variant lookup)")
	var base = v._tex("tile_floor")
	ok(base is Texture2D, "[tex] base tile_floor loads")
	for s in range(1, 6):
		v.section = s
		ok(v._tile_tex("tile_floor") == base, "[tex] section %d with no variant file falls back to base tile_floor" % s)
	v.free()


# ============================ HELPERS =========================================
func _ids_from(path: String, list_key: String) -> Array:
	var ids: Array = []
	if not FileAccess.file_exists(path):
		_fail += 1
		_fails.append("[tex] content file missing: " + path)
		return ids
	var data = JSON.parse_string(FileAccess.get_file_as_string(path))
	if typeof(data) == TYPE_DICTIONARY and data.has(list_key):
		for entry in data[list_key]:
			if typeof(entry) == TYPE_DICTIONARY and entry.has("id"):
				ids.append(str(entry["id"]))
	return ids


func _archetype_ids() -> Array:
	var ids: Array = []
	var d = DirAccess.open("res://content/archetypes")
	if d == null:
		return ids
	d.list_dir_begin()
	var fn: String = d.get_next()
	while fn != "":
		if fn.ends_with(".json"):
			var data = JSON.parse_string(FileAccess.get_file_as_string("res://content/archetypes/" + fn))
			if typeof(data) == TYPE_DICTIONARY and data.has("id"):
				ids.append(str(data["id"]))
		fn = d.get_next()
	d.list_dir_end()
	return ids


## Mirrors car_view.gd `_tex()` EXACTLY: a stem resolves only if one of its candidate resource
## paths loads as a Texture2D through ResourceLoader — the renderer's actual load path. The old
## check here was FileAccess.file_exists, which stayed GREEN while 29 SVGs had no .import sidecar
## and silently failed at runtime (captains rendered as circles). Never weaken this back.
func _stem_loads(stem: String) -> bool:
	for path in CarView.tex_candidate_paths(stem):
		if ResourceLoader.exists(path):
			var r = load(path)
			if r is Texture2D:
				return true
	return false
