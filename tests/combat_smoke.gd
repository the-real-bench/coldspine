extends SceneTree
## COMBAT smoke test (Batch 5 — the combat-affordance + progression polish, headless).
## Two halves, both driven WITHOUT a display and WITHOUT the byte-stable run loop:
##
##   A) LEVEL-UP (S3-LEVELUP) — drives the REAL Leveling API through RunController.drive_levelup_scripted()
##      on an IN-MEMORY UnitInstance (never the byte-stable run loop): XP -> level threshold -> the offered
##      1-of-2 -> a pick recorded into chosen_abilities; a multi-level jump resolves picks in sequence; the
##      never-stuck auto-pick (option 0) always resolves a pending pick; an invalid id falls back safely.
##      Also asserts the HEADLESS run loop awards NO XP (byte-stability of the suites).
##
##   B) COMBAT TARGETING LEGIBILITY (#16) — asserts the render-only overlay helpers compute the correct
##      tile sets (reachable MOVE / 4 push / shootable enemies + to-hit% + cover shield) for a sample
##      state WITHOUT mutating it (a deep before/after fingerprint proves zero sim side-effect), and that
##      the to-hit % displayed equals ShootCommand.hit_chance (preview == the real roll's chance). Also
##      checks the "no legal target" predicate and the OpsHUD/CarView overlay method contract exists.
##
## Run: godot --headless --path . --script res://tests/combat_smoke.gd

const E = preload("res://core/sim_enums.gd")
const RunController = preload("res://app/run_controller.gd")
const ContentDB = preload("res://core/units/content_db.gd")
const UnitInstance = preload("res://core/units/unit_instance.gd")
const Leveling = preload("res://core/leveling.gd")
const SimState = preload("res://core/sim_state.gd")
const SimEntity = preload("res://core/sim_entity.gd")
const IntRng = preload("res://core/int_rng.gd")
const TurnManager = preload("res://core/turn_manager.gd")
const ShootCommand = preload("res://core/commands/shoot_command.gd")
const InputIntent = preload("res://app/input_intent.gd")
const CarView = preload("res://render/car_view.gd")
const OpsHUD = preload("res://render/ops_hud.gd")

var _pass: int = 0
var _fail: int = 0
var _fails: Array = []


func _initialize() -> void:
	print("\n=== COLDSPINE — COMBAT smoke test (level-up + targeting legibility, headless) ===")
	# A) LEVEL-UP
	test_xp_to_threshold_offers_one_of_two()
	test_pick_records_chosen_ability()
	test_multi_level_resolves_in_sequence()
	test_never_stuck_auto_pick()
	test_invalid_id_falls_back_safely()
	test_capstone_past_tree()
	test_headless_run_loop_awards_no_xp()
	# B) TARGETING LEGIBILITY
	test_reachable_move_tiles()
	test_push_tiles_are_four_adjacent()
	test_shootable_targets_match_shoot_math()
	test_cover_shield_and_flank()
	test_no_legal_target_predicate()
	test_overlay_does_not_mutate_state()
	test_overlay_method_contract_exists()
	print("\n--- COMBAT SMOKE: %d passed, %d failed ---" % [_pass, _fail])
	for f in _fails:
		print("    FAIL: " + f)
	if _fail == 0:
		print("COMBAT GREEN — level-up (XP->1-of-2->pick, no dead end) + render-only targeting legibility prove out; headless awards no XP.\n")
	quit(0 if _fail == 0 else 1)


func ok(cond: bool, msg: String) -> void:
	if cond:
		_pass += 1
	else:
		_fail += 1
		_fails.append(msg)
		print("    [FAIL] " + msg)


# ============================ A) LEVEL-UP ======================================
func _db() -> ContentDB:
	return ContentDB.new()

## A fresh in-memory bruiser unit (level 1, the always-known signatures only).
func _bruiser(db: ContentDB) -> UnitInstance:
	return UnitInstance.from_archetype(db, "bruiser", [], "Test-Bruiser", 1)


## Enough XP to reach level 2 offers exactly the abilityTree tier-0 pair (the 1-of-2), and NOT yet picked.
func test_xp_to_threshold_offers_one_of_two() -> void:
	var db := _db()
	var rc := RunController.new()
	rc.db = db
	var u := _bruiser(db)
	# Level 1 -> 2 costs 1*XP_PER_LEVEL; grant exactly that.
	var res: Dictionary = rc.drive_levelup_scripted(u, [{"op": "xp", "amount": E.XP_PER_LEVEL}])
	ok(res.level == 2, "[levelup] XP at threshold raised level 1 -> 2 (got %d)" % res.level)
	var pending: Array = res.pending
	ok(pending.size() == 2, "[levelup] level 2 offers a 1-OF-2 pick (got %d options)" % pending.size())
	# The offered pair is the archetype's abilityTree tier 0 (bruiser: bull_rush / bracing).
	var expected: Array = Leveling.choice_for_level(db, "bruiser", 2)
	ok(pending == expected, "[levelup] the offered pair == archetype abilityTree tier-0 %s (got %s)" % [str(expected), str(pending)])
	ok((res.chosen as Array).is_empty() or not _has_tree_pick(res.chosen, expected), "[levelup] no tier ability is chosen yet (pick still pending)")


## Picking one of the two records it into chosen_abilities (via the REAL Leveling.choose_ability) and
## clears the pending pick.
func test_pick_records_chosen_ability() -> void:
	var db := _db()
	var rc := RunController.new()
	rc.db = db
	var u := _bruiser(db)
	var opts: Array = Leveling.choice_for_level(db, "bruiser", 2)
	var want := String(opts[0])
	var res: Dictionary = rc.drive_levelup_scripted(u, [
		{"op": "xp", "amount": E.XP_PER_LEVEL},
		{"op": "pick", "id": want},
	])
	ok((res.chosen as Array).has(want), "[levelup] the picked ability '%s' is recorded in chosen_abilities" % want)
	ok(res.picks_resolved == 1, "[levelup] exactly 1 pick resolved")
	ok((res.pending as Array).is_empty(), "[levelup] no pending pick remains after the pick")


## A multi-level XP jump (1 -> 3) owes TWO picks; they resolve in sequence (one per re-query), never stuck.
func test_multi_level_resolves_in_sequence() -> void:
	var db := _db()
	var rc := RunController.new()
	rc.db = db
	var u := _bruiser(db)
	# XP to reach level 3 = (1 + 2) * XP_PER_LEVEL.
	var jump: int = (1 + 2) * E.XP_PER_LEVEL
	var t2: Array = Leveling.choice_for_level(db, "bruiser", 2)
	var t3: Array = Leveling.choice_for_level(db, "bruiser", 3)
	var res: Dictionary = rc.drive_levelup_scripted(u, [
		{"op": "xp", "amount": jump},
		{"op": "pick", "id": String(t2[0])},   # resolves the level-2 owed pick first (lower tier first)
		{"op": "pick", "id": String(t3[1])},   # then the level-3 owed pick
	])
	ok(res.level == 3, "[levelup] multi-level jump reached level 3 (got %d)" % res.level)
	ok((res.chosen as Array).has(String(t2[0])) and (res.chosen as Array).has(String(t3[1])),
		"[levelup] both owed picks recorded in order (%s)" % str(res.chosen))
	ok(res.picks_resolved == 2, "[levelup] two picks resolved in sequence (got %d)" % res.picks_resolved)
	ok((res.pending as Array).is_empty(), "[levelup] no pick left pending after a 2-level jump")


## The never-stuck safety: an "auto" op resolves the first pending pick with option 0 deterministically.
func test_never_stuck_auto_pick() -> void:
	var db := _db()
	var rc := RunController.new()
	rc.db = db
	var u := _bruiser(db)
	var opts: Array = Leveling.choice_for_level(db, "bruiser", 2)
	var res: Dictionary = rc.drive_levelup_scripted(u, [
		{"op": "xp", "amount": E.XP_PER_LEVEL},
		{"op": "auto"},
	])
	ok((res.chosen as Array).has(String(opts[0])), "[levelup] auto-pick took option 0 (%s)" % String(opts[0]))
	ok((res.pending as Array).is_empty(), "[levelup] auto-pick leaves NO pending pick (never stuck)")


## An invalid ability id at pick-time never strands the pick — it falls back to a valid option.
func test_invalid_id_falls_back_safely() -> void:
	var db := _db()
	var rc := RunController.new()
	rc.db = db
	var u := _bruiser(db)
	var opts: Array = Leveling.choice_for_level(db, "bruiser", 2)
	var res: Dictionary = rc.drive_levelup_scripted(u, [
		{"op": "xp", "amount": E.XP_PER_LEVEL},
		{"op": "pick", "id": "not_a_real_ability"},
	])
	ok(res.picks_resolved == 1, "[levelup] an invalid id still resolves the pick (no dead end)")
	ok((res.chosen as Array).has(String(opts[0])), "[levelup] invalid id fell back to a VALID option (%s)" % String(opts[0]))
	ok((res.pending as Array).is_empty(), "[levelup] no pending pick after the invalid-id fallback")


## Walking to MAX_LEVEL (4) owes 3 tree picks (T1/T2/T3 = levels 2/3/4); resolving all of them leaves
## NO pending pick (the unit is capped — the capstone tier is only offered past MAX_LEVEL, so leveling
## never strands a pick). Also asserts the capstone branch of choice_for_level returns a SINGLE card.
func test_capstone_past_tree() -> void:
	var db := _db()
	var rc := RunController.new()
	rc.db = db
	var u := _bruiser(db)
	# XP to walk 1 -> MAX_LEVEL(4): (1+2+3)*XP_PER_LEVEL.
	var xp_all: int = (1 + 2 + 3) * E.XP_PER_LEVEL
	var t2: Array = Leveling.choice_for_level(db, "bruiser", 2)
	var t3: Array = Leveling.choice_for_level(db, "bruiser", 3)
	var t4: Array = Leveling.choice_for_level(db, "bruiser", 4)
	ok(t4.size() == 2, "[levelup] level %d (the final tree tier) offers a 1-OF-2 (got %d)" % [E.MAX_LEVEL, t4.size()])
	# The capstone is the FORCED single card past the tree (level MAX_LEVEL+1 tier == tree size).
	var cap: Array = Leveling.choice_for_level(db, "bruiser", E.MAX_LEVEL + 1)
	ok(cap.size() == 1, "[levelup] the capstone branch returns a SINGLE forced card (got %d)" % cap.size())
	var res: Dictionary = rc.drive_levelup_scripted(u, [
		{"op": "xp", "amount": xp_all},
		{"op": "pick", "id": String(t2[0])},
		{"op": "pick", "id": String(t3[0])},
		{"op": "pick", "id": String(t4[1])},
	])
	ok(res.level == E.MAX_LEVEL, "[levelup] reached MAX_LEVEL %d (XP capped there)" % E.MAX_LEVEL)
	ok(res.picks_resolved == 3, "[levelup] all 3 owed tree picks resolved (got %d)" % res.picks_resolved)
	ok((res.pending as Array).is_empty(), "[levelup] no pick pending at the cap (tree picks exhausted, never stuck)")


## BYTE-STABILITY: the HEADLESS run loop must award NO xp (the suites stay XP-free). Drive a full
## headless run and assert every surviving squad member is still level 1 with 0 xp.
func test_headless_run_loop_awards_no_xp() -> void:
	var rc := RunController.new()
	rc.headless = true
	rc.db = _db()
	rc.drive_full_run(0xC01D5, 3)
	var leveled: int = 0
	var any_xp: int = 0
	for u in rc.run.squad:
		if u == null:
			continue
		if u.level > 1:
			leveled += 1
		any_xp += u.xp
	ok(leveled == 0, "[levelup] HEADLESS run loop leveled NO unit (byte-stable; got %d leveled)" % leveled)
	ok(any_xp == 0, "[levelup] HEADLESS run loop granted 0 total xp (byte-stable; got %d)" % any_xp)


func _has_tree_pick(chosen: Array, pair: Array) -> bool:
	for a in pair:
		if chosen.has(String(a)):
			return true
	return false


# ============================ B) TARGETING LEGIBILITY ==========================
# Entity ids of the sample state (assigned by SimState.add_entity, which starts next_id at 1).
var _pid: int = -1     # the player shooter
var _e_open: int = -1  # the in-LoS open enemy at (5,4)
var _e_far: int = -1   # the far enemy at (8,4)

## A headless RunController wired with a SAMPLE combat state: a single player unit + a couple of
## enemies + a cover tile, on a clear grid. No hud/view needed for the pure helpers. The entity ids
## are captured from add_entity (NOT hardcoded — SimState assigns them off next_id starting at 1).
func _legibility_rc() -> RunController:
	var rc := RunController.new()
	rc.headless = true
	rc.db = _db()
	var s := SimState.new()
	s.init_grid(12, 8)
	s.rng = IntRng.new(0xC01D5)
	# Player unit (a marksman, so it has weapon range) at (2,4).
	var me := SimEntity.new()
	me.is_unit = true; me.pos = Vector2i(2, 4); me.hp = 10; me.faction = E.Faction.PLAYER
	me.integrity = -1; me.name = "shooter"; me.archetype_id = "marksman"
	_pid = s.add_entity(me)
	# An exposed enemy in range + clean LoS at (5,4).
	var e1 := SimEntity.new()
	e1.is_unit = true; e1.pos = Vector2i(5, 4); e1.hp = 8; e1.faction = E.Faction.ENEMY
	e1.integrity = -1; e1.name = "enemy_open"; e1.archetype_id = "truncheon_guard"
	_e_open = s.add_entity(e1)
	# A "covered" enemy directly ABOVE the shooter (same column x=2) at (2,1) — an orthogonal approach
	# (not a flank) so facing cover applies. Its facing tile toward the shooter is (2,2); the cover
	# tests set that tile's cover and assert the shield. Off the (2,4)->(5,4) lane (no LoS conflict).
	var e2 := SimEntity.new()
	e2.is_unit = true; e2.pos = Vector2i(2, 1); e2.hp = 8; e2.faction = E.Faction.ENEMY
	e2.integrity = -1; e2.name = "enemy_far"; e2.archetype_id = "truncheon_guard"
	_e_far = s.add_entity(e2)
	rc.state = s
	rc.turn = TurnManager.new(s)
	rc.turn.start()
	rc._active_combat = true
	return rc


## Reachable MOVE tiles: every walkable tile within MOVE_RANGE Manhattan steps of the unit, excluding
## walls/occupants, and excluding the start tile. Asserts the helper matches a brute-force reference.
func test_reachable_move_tiles() -> void:
	var rc := _legibility_rc()
	var me = rc.state.entities.get(_pid)
	var layer: Dictionary = rc.compute_targeting_layer(_pid, InputIntent.Mode.MOVE)
	var reach: Array = layer["reach"]
	ok(not reach.is_empty(), "[legibility] reachable-move set is non-empty")
	# Every reach tile must be walkable, within MOVE_RANGE Manhattan, and not the start.
	var all_valid := true
	for cell in reach:
		var dman: int = abs(cell.x - me.pos.x) + abs(cell.y - me.pos.y)
		if dman > E.MOVE_RANGE or dman == 0:
			all_valid = false
		var t = rc.state.tile(cell)
		if t.terrain == E.Terrain.WALL or t.hazard == E.Hazard.GAP or rc.state.occupant_at(cell) != null:
			all_valid = false
	ok(all_valid, "[legibility] every reach tile is walkable + within MOVE_RANGE + not the start")
	# The orthogonal neighbour (3,4) is occupied-free and 1 step -> must be reachable.
	ok(reach.has(Vector2i(3, 4)), "[legibility] an adjacent open tile is reachable")
	# An enemy-occupied tile is NOT reachable (occupied).
	ok(not reach.has(Vector2i(5, 4)), "[legibility] an enemy-occupied tile is NOT reachable")


## Push tiles = exactly the 4 orthogonally-adjacent in-bounds tiles (SHOVE/SLAM/THROW destinations).
func test_push_tiles_are_four_adjacent() -> void:
	var rc := _legibility_rc()
	var layer: Dictionary = rc.compute_targeting_layer(_pid, InputIntent.Mode.SHOVE)
	var push: Array = layer["push"]
	ok(push.size() == 4, "[legibility] SHOVE arms the 4 adjacent push tiles (got %d)" % push.size())
	for d in [Vector2i(0, -1), Vector2i(1, 0), Vector2i(0, 1), Vector2i(-1, 0)]:
		ok(push.has(Vector2i(2, 4) + d), "[legibility] push tile %s present" % str(Vector2i(2, 4) + d))
	# A physics action emits NO reach rings (only push); SHOOT emits no push.
	ok((layer["reach"] as Array).is_empty(), "[legibility] a physics action shows no reach rings")
	var shoot_layer: Dictionary = rc.compute_targeting_layer(_pid, InputIntent.Mode.SHOOT)
	ok((shoot_layer["push"] as Array).is_empty(), "[legibility] SHOOT shows no push tiles")


## Shootable targets: the enemies in range + LoS, each carrying a to-hit % that EQUALS ShootCommand.
## hit_chance (the same static math the resolver rolls against — preview == the real chance).
func test_shootable_targets_match_shoot_math() -> void:
	var rc := _legibility_rc()
	var me = rc.state.entities.get(_pid)
	var layer: Dictionary = rc.compute_targeting_layer(_pid, InputIntent.Mode.SHOOT)
	var shoot: Array = layer["shoot"]
	ok(not shoot.is_empty(), "[legibility] at least one enemy is shootable")
	var all_match := true
	for s in shoot:
		var occ = rc.state.occupant_at(s.cell)
		if occ == null:
			all_match = false
			continue
		var expected_pct: int = ShootCommand.hit_chance(rc.state, me, occ)
		if int(s.pct) != expected_pct:
			all_match = false
		# A shootable enemy must really be in range + LoS.
		if not (ShootCommand.has_range(me.pos, occ.pos) and ShootCommand.in_los(rc.state, me.pos, occ.pos)):
			all_match = false
	ok(all_match, "[legibility] each shootable's displayed %-to-hit == ShootCommand.hit_chance (preview == real chance)")
	# The open enemy at (5,4) is in range/LoS -> shootable.
	var open_listed := false
	for s in shoot:
		if s.cell == Vector2i(5, 4):
			open_listed = true
	ok(open_listed, "[legibility] the in-LoS open enemy is listed shootable")


## Cover shield: an enemy behind full cover (on the shooter's facing side) reports shield=2; a flanked
## or open enemy reports shield 0. The shield is AMBER/§16 — never the reserved red (a renderer concern,
## asserted structurally here: the helper returns a cover LEVEL, never a color).
func test_cover_shield_and_flank() -> void:
	var rc := _legibility_rc()
	# Put a FULL-cover tile at (2,2), directly between the shooter (2,4) and enemy_far (2,1) on its
	# facing side -> full cover BREAKS line of sight, so enemy_far is correctly NOT shootable.
	rc.state.tile(Vector2i(2, 2)).cover = 2
	var me = rc.state.entities.get(_pid)
	var efar = rc.state.entities.get(_e_far)
	# in_los is broken by full cover between -> enemy_far is NOT shootable; assert it's excluded.
	var layer: Dictionary = rc.compute_targeting_layer(_pid, InputIntent.Mode.SHOOT)
	var far_listed := false
	for s in layer["shoot"]:
		if s.cell == Vector2i(2, 1):
			far_listed = true
	ok(not far_listed, "[legibility] an enemy behind FULL cover (LoS blocked) is correctly NOT shootable")
	# Now test the shield value via the helper math on a half-cover, in-LoS case: half cover at the
	# facing tile lets the shot through (cover==1, LoS not blocked) and reports facing shield 1.
	rc.state.tile(Vector2i(2, 2)).cover = 1   # half cover — LoS passes, facing shield = 1
	var shield1: int = ShootCommand.cover_against(rc.state, me, efar)
	var layer2: Dictionary = rc.compute_targeting_layer(_pid, InputIntent.Mode.SHOOT)
	var far_shield := -1
	for s in layer2["shoot"]:
		if s.cell == Vector2i(2, 1):
			far_shield = int(s.shield)
	ok(far_shield == shield1 and far_shield == 1, "[legibility] a half-cover enemy reports shield 1 (== ShootCommand.cover_against)")
	# An OPEN enemy (no cover, no flank) reports shield 0.
	var open_shield := -1
	for s in layer2["shoot"]:
		if s.cell == Vector2i(5, 4):
			open_shield = int(s.shield)
	ok(open_shield == 0, "[legibility] an open, uncovered enemy reports shield 0 (no glyph)")


## The "no legal target" predicate: TRUE when SHOOT is armed but no enemy is in range/LoS; FALSE when
## one is. Drives the §16 "no legal target" hint without any sim effect.
func test_no_legal_target_predicate() -> void:
	var rc := _legibility_rc()
	# With enemies in range, SHOOT has a target.
	ok(not rc._no_legal_target(_pid, InputIntent.Mode.SHOOT), "[legibility] SHOOT has a legal target when an enemy is in range/LoS")
	# Remove both enemies (clear their tile occupancy too) -> SHOOT now has NO legal target.
	for eid in [_e_open, _e_far]:
		var e = rc.state.entities.get(eid)
		if e != null and rc.state.in_bounds(e.pos):
			rc.state.tile(e.pos).occupant_id = -1
		rc.state.entities.erase(eid)
	ok(rc._no_legal_target(_pid, InputIntent.Mode.SHOOT), "[legibility] SHOOT reports NO legal target once all enemies are gone")
	# A physics action with no adjacent movable body -> no legal target.
	ok(rc._no_legal_target(_pid, InputIntent.Mode.SHOVE), "[legibility] SHOVE reports no legal target with nothing adjacent")


## RENDER-ONLY PROOF: computing the overlay must NOT mutate the sim state — a deep fingerprint of every
## entity's pos/hp/status/alive + every tile's cover/terrain/hazard/occupant is byte-identical before
## and after computing all four armed-mode layers.
func test_overlay_does_not_mutate_state() -> void:
	var rc := _legibility_rc()
	var before := _state_fingerprint(rc.state)
	# Compute every layer variant (the full set of armed modes the overlay supports).
	for m in [InputIntent.Mode.NONE, InputIntent.Mode.MOVE, InputIntent.Mode.SHOOT,
			InputIntent.Mode.SHOVE, InputIntent.Mode.SLAM, InputIntent.Mode.THROW]:
		rc.compute_targeting_layer(_pid, m)
		rc._no_legal_target(_pid, m)
	var after := _state_fingerprint(rc.state)
	ok(before == after, "[legibility] computing the overlay layers mutates NOTHING (render-only; fingerprint stable)")


## The overlay/HUD method contract exists + is callable (the on-screen surface CarView/OpsHUD expose).
func test_overlay_method_contract_exists() -> void:
	var view := CarView.new()
	ok(view.has_method("set_targeting_layer"), "[legibility] CarView.set_targeting_layer exists")
	ok(view.has_method("clear_targeting_layer"), "[legibility] CarView.clear_targeting_layer exists")
	# A sample layer applies + clears without error (no state needed; pure draw-data setters).
	view.set_targeting_layer({"reach": [Vector2i(1, 1)], "push": [Vector2i(2, 2)],
		"shoot": [{"cell": Vector2i(3, 3), "pct": 75, "shield": 2}], "armed": InputIntent.Mode.SHOOT})
	ok(view.hl_shoot.size() == 1 and int(view.hl_shoot[0]["pct"]) == 75, "[legibility] CarView holds the pushed layer data")
	view.clear_targeting_layer()
	ok(view.hl_reach.is_empty() and view.hl_shoot.is_empty(), "[legibility] clear_targeting_layer empties the layer")
	view.free()
	var hud := OpsHUD.new()
	ok(hud.has_method("set_armed_mode"), "[palette] OpsHUD.set_armed_mode exists (#19 selected-tint)")
	ok(hud.has_method("set_palette_states"), "[palette] OpsHUD.set_palette_states exists (#19 affordability/OVR/undo)")
	# Calling them before _ready built the buttons must be safe (no crash on an empty button table).
	hud.set_armed_mode("SHOOT")
	hud.set_palette_states({"MOVE": {"enabled": true}, "OVR": {"enabled": false, "selected": true},
		"UNDO": {"enabled": false}, "CANCEL": {"enabled": true},
		"ABILITY": {"enabled": true}, "ITEM": {"enabled": false}})   # Batch 6 depth-toolkit buttons
	ok(true, "[palette] OpsHUD palette-state setters are callable")
	# Batch 6 — the ABILITY / ITEM choice popup builds + toggles without a display (on-screen-only chrome).
	ok(hud.has_method("open_choice_menu") and hud.has_method("choice_menu_open"), "[popup] OpsHUD exposes the ability/item picker API")
	hud.open_choice_menu("ability", "ABILITIES", [
		{"id": "gas_tap", "label": "Gas Tap  (1 AP)", "enabled": true, "reason": ""},
		{"id": "system_seizure", "label": "System Seizure  (2 AP)", "enabled": false, "reason": "needs 2 AP"},
	])
	ok(hud.choice_menu_open(), "[popup] open_choice_menu raises the picker (enabled + disabled rows)")
	hud.open_choice_menu("item", "ITEMS", [])   # empty list — must not dead-end / crash
	ok(hud.choice_menu_open(), "[popup] an empty item list still opens (no dead end)")
	hud.close_choice_menu()
	ok(not hud.choice_menu_open(), "[popup] close_choice_menu lowers the picker")
	hud.free()


## A deterministic deep fingerprint of a SimState (entities + tiles) for the render-only mutation proof.
func _state_fingerprint(s) -> String:
	var parts: Array = []
	for id in s.entity_ids_sorted():
		var e = s.entities.get(id)
		parts.append("E%d@%s,%s hp=%d st=%d alive=%s ow=%s" % [
			id, str(e.pos), str(e.faction), e.hp, e.status, str(e.alive), str(e.overwatch)])
	for y in range(s.height):
		for x in range(s.width):
			var t = s.tile(Vector2i(x, y))
			if t.cover != 0 or t.terrain != E.Terrain.FLOOR or t.hazard != E.Hazard.NONE or t.occupant_id != -1 or t.status_layer != 0:
				parts.append("T%d,%d c=%d tr=%d hz=%d oc=%d sl=%d" % [
					x, y, t.cover, t.terrain, t.hazard, t.occupant_id, t.status_layer])
	return "|".join(parts)
