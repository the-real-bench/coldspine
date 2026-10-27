extends SceneTree
## Task #11 run-integration smoke test (NEW file — does NOT touch run_tests.gd / render_smoke.gd).
## Drives a FULL run HEADLESSLY through the RunController with a fixed seed, two ways:
##
##   1. drive_full_run  — the REAL playable path: draft a squad -> generate the line -> advance
##      car-by-car auto-resolving combats via the real TurnManager + command path (the player
##      auto-pilot moves/shoots/shoves through the same commands the UI issues) + EnemyAI, take
##      default choices on the non-combat economy cars -> resolve an ending. Proves the line /
##      combat / economy / advance wiring + determinism.
##
##   2. drive_to_finale — the FINALE verification harness: the same draft + line + REAL non-combat
##      economy cars, but combat cars are fast-forwarded as assumed-cleared (squad preserved) so
##      the run reaches the Engine and runs the REAL EngineVault + resolve_ending regardless of
##      combat balance. Proves the finale + endings wiring end-to-end. (See the controller note:
##      the launch content's combat is lethal to a fragile 3-unit cell over a ~20-car line, so a
##      natural run ends in LOSS before the Engine — a balance finding for the lead, not a wiring
##      bug. This harness isolates the finale wiring so it is provably exercised.)
##
## Asserts: no runtime errors; both paths resolve a valid ending; the finale path reaches the
## Engine + runs the vault + resolves a VICTORY ending; same seed -> identical ending + line
## (determinism). Prints a full textual trace of one run so the lead can read end-to-end play.
## Run: godot --headless --path . --script res://tests/run_smoke.gd

const E = preload("res://core/sim_enums.gd")
const RunController = preload("res://app/run_controller.gd")
const ContentDB = preload("res://core/units/content_db.gd")
const SaveSystem = preload("res://core/meta/save_system.gd")
const RunState = preload("res://core/run/run_state.gd")
const UnitInstance = preload("res://core/units/unit_instance.gd")

const SEED_A := 0xC01D5
const SEED_B := 0x5EED99

var _pass: int = 0
var _fail: int = 0
var _fails: Array = []


func _initialize() -> void:
	# Harness safety (W1-9b): arm the save sandbox so this suite's mid-run save/resume test writes
	# user://sandbox_coldspine_run.json, never the owner's real Continue slot.
	SaveSystem.force_sandbox = true
	print("\n=== COLDSPINE — RUN smoke test (task #11 integration) ===")
	test_full_run_reaches_ending()
	test_full_run_determinism()
	test_finale_path_reaches_victory()
	test_finale_determinism()
	test_line_shape_and_finale_present()
	test_mid_run_save_resume_identical()
	test_deploy_best3_picks_and_benches()
	test_deploy_scripted_seam_resolves_ids()
	print("\n--- RUN SMOKE: %d passed, %d failed ---" % [_pass, _fail])
	for f in _fails:
		print("    FAIL: " + f)
	if _fail == 0:
		print("RUN GREEN — a full run drives Draft -> line -> finale -> ending headless.\n")
	quit(0 if _fail == 0 else 1)


# ---- assertion kit (mirrors render_smoke.gd) ----
func ok(cond: bool, msg: String) -> void:
	if cond:
		_pass += 1
	else:
		_fail += 1
		_fails.append(msg)
		print("    [FAIL] " + msg)


func eq(a, b, msg: String) -> void:
	ok(a == b, "%s (got %s, want %s)" % [msg, str(a), str(b)])


# ---- drivers ----
func _drive_full(seed: int) -> RunController:
	var rc := RunController.new()
	rc.headless = true
	rc.db = ContentDB.new()
	rc.seed = seed
	rc.drive_full_run(seed, 3)
	return rc


func _drive_finale(seed: int) -> RunController:
	var rc := RunController.new()
	rc.headless = true
	rc.db = ContentDB.new()
	rc.seed = seed
	rc.drive_to_finale(seed, 3)
	return rc


func _valid_ending(e: int) -> bool:
	return e in [E.EndingId.LOSS, E.EndingId.HARD_STOP, E.EndingId.SEIZE_ENGINE, E.EndingId.PYRRHIC, E.EndingId.LIBERATION]


# ============================ TESTS ===========================================
func test_full_run_reaches_ending() -> void:
	var rc := _drive_full(SEED_A)
	ok(rc.run != null, "[full] run state was created")
	ok(rc.ending != -1, "[full] the run resolved an ending id")
	ok(_valid_ending(rc.ending), "[full] the ending is one of the 5 valid EndingIds")
	ok(rc.run.squad.size() >= 1, "[full] the draft produced at least one starter")
	ok(rc.trace.size() >= 3, "[full] the run produced a multi-step trace (draft + cars + ending)")
	# Print the full natural-run trace for the lead.
	print("\n[run_smoke] NATURAL full-run trace (seed 0x%X — real combat auto-pilot):" % SEED_A)
	for t in rc.trace:
		print("    " + str(t))
	print("    ENDING REACHED: %s" % rc._ending_name(rc.ending))


func test_full_run_determinism() -> void:
	var a := _drive_full(SEED_A)
	var b := _drive_full(SEED_A)
	eq(a.ending, b.ending, "[full] same seed -> identical ending")
	eq(_line_fingerprint(a.run), _line_fingerprint(b.run), "[full] same seed -> byte-identical line")
	eq(str(a.trace), str(b.trace), "[full] same seed -> identical car-by-car trace")


func test_finale_path_reaches_victory() -> void:
	var rc := _drive_finale(SEED_A)
	ok(rc.ending != -1, "[finale] the finale path resolved an ending")
	ok(_valid_ending(rc.ending), "[finale] the finale ending is valid")
	# The finale path preserves the squad, so it must reach a VICTORY ending (not LOSS).
	ok(rc.ending != E.EndingId.LOSS, "[finale] reached a victory ending (squad survived to the Engine)")
	# The trace must show the vault being built + the finale running (the wiring we're proving).
	var saw_vault := false
	var saw_finale_round := false
	for t in rc.trace:
		if str(t).begins_with("FINALE: vault built"):
			saw_vault = true
		if str(t).begins_with("FINALE: rounds="):
			saw_finale_round = true
	ok(saw_vault, "[finale] the EngineVault was built (relays/dispensers/core/conductor)")
	ok(saw_finale_round, "[finale] the finale arena ran to resolution")
	ok(rc.run.position >= rc.run.line.size() - 1, "[finale] the run reached the Engine")
	print("\n[run_smoke] FINALE-VERIFY trace (seed 0x%X — combats fast-forwarded, REAL finale):" % SEED_A)
	for t in rc.trace:
		print("    " + str(t))
	print("    ENDING REACHED: %s" % rc._ending_name(rc.ending))


func test_finale_determinism() -> void:
	var a := _drive_finale(SEED_A)
	var b := _drive_finale(SEED_A)
	eq(a.ending, b.ending, "[finale] same seed -> identical ending")
	eq(str(a.trace), str(b.trace), "[finale] same seed -> identical trace")
	# A different seed still reaches a valid finale ending, and generates a different line.
	var c := _drive_finale(SEED_B)
	ok(c.ending != -1, "[finale] a different seed also resolves a valid ending")
	ok(_line_fingerprint(a.run) != _line_fingerprint(c.run), "[finale] different seeds -> different lines (seed matters)")


func test_line_shape_and_finale_present() -> void:
	var rc := _drive_finale(SEED_A)
	var line: Array = rc.run.line
	ok(line.size() >= 5, "the line spans the run (>=5 cars across the sections)")
	ok(line[line.size() - 1].car_type == E.CarType.ENGINE, "the line ends on the Engine car")
	var captains: int = 0
	var engines: int = 0
	for c in line:
		if c.car_type == E.CarType.CAPTAIN:
			captains += 1
		elif c.car_type == E.CarType.ENGINE:
			engines += 1
	ok(captains >= 1, "the line has Section Captain gate(s)")
	eq(engines, 1, "the line has exactly one Engine car")


# ============================ mid-run SAVE / RESUME (release-readiness #0) =====
func test_mid_run_save_resume_identical() -> void:
	# Build a live mid-run: draft + line, then advance through any leading non-combat cars via the
	# REAL rails (deterministic, no wipe risk) so `position` is genuinely mid-flight. Then prove
	# SAVE -> RELOAD is byte-identical AND that CONTINUE from the reloaded save reproduces the same
	# ending as continuing the uninterrupted state — the determinism contract for the Continue slot.
	var rc := RunController.new()
	rc.headless = true
	rc.db = ContentDB.new()
	rc.seed = SEED_A
	rc._run_draft(3)
	_advance_past_screens(rc)
	var mid_fp: String = rc.run.fingerprint()
	var mid_dict: Dictionary = rc.run.to_dict()
	# An independent in-memory twin of the SAME state = the "uninterrupted" control.
	var control = RunState.from_dict(mid_dict)
	# The actual disk round-trip the between-car checkpoint performs.
	ok(SaveSystem.save_run(rc.run), "[save] a mid-run save is written to the Continue slot")
	ok(SaveSystem.has_run_save(), "[save] CONTINUE can see the save (menu button lights up)")
	var reloaded = SaveSystem.load_run()
	ok(reloaded != null, "[save] the mid-run save loads back")
	eq(reloaded.fingerprint(), mid_fp, "[save] save->reload is byte-identical (RunState fingerprint)")
	# Field-level round-trip (the fingerprint is the canonical check; JSON re-orders dict keys so a
	# raw str(to_dict()) compare is not meaningful — assert the load-bearing fields instead).
	eq(reloaded.seed, rc.run.seed, "[save] seed survives the round-trip")
	eq(reloaded.position, rc.run.position, "[save] the current-car position survives (resume re-enters it)")
	eq(str(reloaded.currency), str(rc.run.currency), "[save] currency survives")
	eq(reloaded.squad.size(), rc.run.squad.size(), "[save] the full squad survives")
	eq(reloaded.line.size(), rc.run.line.size(), "[save] the generated line survives")
	# CONTINUE both to the end; identical ending (resume == uninterrupted).
	var e_reload: int = _resume_to_end(reloaded)
	var e_control: int = _resume_to_end(control)
	ok(_valid_ending(e_reload), "[save] the resumed run resolves a valid ending")
	eq(e_reload, e_control, "[save] resume(reloaded) == resume(uninterrupted) — identical run")
	SaveSystem.clear_run()
	ok(not SaveSystem.has_run_save(), "[save] clear_run wipes the slot (permadeath stays sacred on run end)")


# ============================ DEPLOY-BEST-3 (combat-ux #6 / balance-ai #6) =====
func test_deploy_best3_picks_and_benches() -> void:
	var rc := _five_member_controller()
	var car = _first_combat_car(rc.run)
	ok(car != null, "[deploy] the line has a combat car with player spawn tiles")
	# HEADLESS DEFAULT (W6-3, re-pinned): with no explicit DEPLOY pick the auto-pilot now fields the
	# deterministic BEST-3 by health/level/role rank (was roster-first-3 [100,101,102]) — so the
	# crippled 2-HP starter (id 100) is benched for a full-HP recruit. Balance-shifting BY DESIGN
	# (BalanceGate); the headless default now matches the picker's best-3 seam below.
	rc._forced_deployment = []
	var headless_deploy: Array = _deployed_instance_ids(rc._build_car_state(car))
	headless_deploy.sort()
	eq(str(headless_deploy), "[101, 103, 104]", "[deploy] W6-3: headless auto-pilot fields the BEST-3 (benches the 2-HP starter, not roster-first-3)")
	# BEST-3 AUTO-PICK (the picker default, via the seam): benches the WEAKEST (2-HP id 100), keeps
	# the two full-HP recruits (103,104) + the first half-HP body (101).
	rc.deploy_pick_scripted([])
	var deployed_auto: Array = _deployed_instance_ids(rc._build_car_state(car))
	eq(deployed_auto.size(), 3, "[deploy] the best-3 auto-pick deploys exactly 3 of the 5")
	ok(not (100 in deployed_auto), "[deploy] best-3 benches the 2-HP starter (id 100), not a fresh recruit")
	ok(103 in deployed_auto and 104 in deployed_auto, "[deploy] the two full-HP recruits (103,104) deploy")
	# EXPLICIT PICK: {100,103,104} -> those exact three occupy the tiles (even the 2-HP body).
	rc.deploy_pick_scripted([100, 103, 104])
	var deployed_pick: Array = _deployed_instance_ids(rc._build_car_state(car))
	deployed_pick.sort()
	eq(str(deployed_pick), "[100, 103, 104]", "[deploy] an explicit DEPLOY pick places exactly the chosen 3")
	# FIT CASE: <=3 living -> deploys EVERYONE in roster order (no benching, either path).
	rc.run.squad = [rc.run.squad[0], rc.run.squad[3], rc.run.squad[4]]   # ids 100,103,104
	rc._forced_deployment = []
	var d3: Array = _deployed_instance_ids(rc._build_car_state(car))
	eq(d3.size(), 3, "[deploy] a 3-member cell deploys all three (no benching)")
	ok(100 in d3, "[deploy] the 2-HP member still deploys when the cell fits the tiles (no auto-bench)")


func test_deploy_scripted_seam_resolves_ids() -> void:
	# The headless seam mirrors drive_screen_scripted: deploy_pick_scripted returns the resolved
	# deploy order and stores it for the next car build. Determinism: the same inputs -> same ids.
	var rc := _five_member_controller()
	var picked: Array = rc.deploy_pick_scripted([104, 100, 103])
	picked.sort()
	eq(str(picked), "[100, 103, 104]", "[deploy] the seam resolves exactly the scripted living ids")
	# Empty seam -> the deterministic auto-pick (top-3 by HP desc); stable across calls.
	var auto1: Array = rc.deploy_pick_scripted([])
	var auto2: Array = rc.deploy_pick_scripted([])
	eq(str(auto1), str(auto2), "[deploy] auto-pick is a STABLE deterministic rule (repeatable)")
	ok(not (100 in auto1), "[deploy] auto-pick seam benches the 2-HP member")


# A controller with a controlled 5-member cell (ids 100..104): 100 crippled at 2 HP, 101/102 at
# half HP, 103/104 at full HP. Built on a real drafted line so _build_car_state has cars to build.
func _five_member_controller() -> RunController:
	var rc := RunController.new()
	rc.headless = true
	rc.db = ContentDB.new()
	rc.seed = SEED_A
	rc._run_draft(3)
	var squad: Array = []
	for i in range(5):
		var u = UnitInstance.from_archetype(rc.db, "bruiser", [], "U%d" % i, 100 + i)
		squad.append(u)
	squad[0].hp = 2
	squad[1].hp = max(1, squad[1].max_hp / 2)
	squad[2].hp = max(1, squad[2].max_hp / 2)
	rc.run.squad = squad
	return rc


func _first_combat_car(run):
	for c in run.line:
		if c.is_combat():
			return c
	return null


func _deployed_instance_ids(s) -> Array:
	var ids: Array = []
	if s == null:
		return ids
	for id in s.entity_ids_sorted():
		var e = s.entities.get(id)
		if e != null and e.is_unit and e.faction == E.Faction.PLAYER:
			ids.append(int(e.instance_id))
	return ids


func _advance_past_screens(rc) -> void:
	var guard: int = 0
	while guard < 64:
		guard += 1
		var car = rc.run.current_car()
		if car == null or car.is_combat() or car.car_type == E.CarType.ENGINE:
			break
		rc._resolve_screen_car(car)
		rc.run.collect_reward()
		rc.run.advance()


func _resume_to_end(run) -> int:
	var rc := RunController.new()
	rc.headless = true
	rc.db = ContentDB.new()
	rc.resume_run = run
	rc.seed = run.seed
	return rc.drive_full_run(-1, 3)


# ---- helpers ----
func _line_fingerprint(run) -> String:
	var parts: Array = []
	for i in range(run.line.size()):
		var c = run.line[i]
		parts.append("%d:%s/t%d/s%d" % [i, c.template_id, c.car_type, c.section])
	return "|".join(parts)
