extends SceneTree
## COLDSPINE — BETRAYER smoke test (Conductor's Kin, Sub-Spec C3.5) — batch 7 completeness.
## The betrayer CORE (Betrayer.reveal/should_fire/fire/check_beat) is unit-tested in run_tests.gd;
## this suite proves the RUN-LEVEL WIRING that was previously inert: a planted Conductor's Kin,
## deployed into a CAPTAIN car, DEFECTS at the section-climax beat — flipping to the ENEMY faction,
## emitting a BETRAYAL event (the renderer's animation source), raising the run's Order meter (§9),
## and leaving the roster for good (once per plant, never re-triggers). Reveal (a Saboteur scan /
## vetting) is the counterplay: a revealed Kin does NOT turn. Everything here is deterministic and
## RNG-free at the trigger (car-type gated), and the recruit-roll density draws from the seeded run
## RNG so a fixed seed reproduces the same plants. Density constant (BETRAYER_DENSITY_PCT) UNTOUCHED.
## Run: godot --headless --path . --script res://tests/betrayer_smoke.gd

const E = preload("res://core/sim_enums.gd")
const RunController = preload("res://app/run_controller.gd")
const ContentDB = preload("res://core/units/content_db.gd")
const UnitInstance = preload("res://core/units/unit_instance.gd")
const Recruitment = preload("res://core/units/recruitment.gd")
const IntRng = preload("res://core/int_rng.gd")

const SEED_A := 0xC01D5

var _pass: int = 0
var _fail: int = 0
var _fails: Array = []


func _initialize() -> void:
	print("\n=== COLDSPINE — BETRAYER smoke test (Sub-Spec C3.5) ===")
	test_recruit_kin_roll_is_seeded_and_deterministic()
	test_kin_defects_at_captain_car()
	test_no_trigger_on_non_captain_car()
	test_no_false_trigger_without_a_kin()
	test_revealed_kin_does_not_defect()
	test_betrayal_beat_is_reproducible()
	test_defector_leaves_roster_and_never_refires()
	print("\n--- BETRAYER SMOKE: %d passed, %d failed ---" % [_pass, _fail])
	for f in _fails:
		print("    FAIL: " + f)
	if _fail == 0:
		print("BETRAYER GREEN — the Conductor's Kin defection beat fires, reveals, and persists.\n")
	quit(0 if _fail == 0 else 1)


# ---- assertion kit ----
func ok(cond: bool, msg: String) -> void:
	if cond:
		_pass += 1
	else:
		_fail += 1
		_fails.append(msg)
		print("    [FAIL] " + msg)

func eq(a, b, msg: String) -> void:
	ok(a == b, "%s (got %s, want %s)" % [msg, str(a), str(b)])


# ============================ 1) SEEDED DENSITY ROLL ==========================
## The hidden-trait assignment draws from the SEEDED run RNG (Recruitment.roll_recruit), so a fixed
## seed reproduces the same plants — and at BETRAYER_DENSITY_PCT some, but not all, recruits are Kin.
func test_recruit_kin_roll_is_seeded_and_deterministic() -> void:
	var flags_a := _kin_flags(SEED_A)
	var flags_b := _kin_flags(SEED_A)
	eq(str(flags_a), str(flags_b), "[assign] same seed -> identical Kin-roll sequence (reproducible)")
	var kin_count := 0
	for f in flags_a:
		if f:
			kin_count += 1
	ok(kin_count >= 1, "[assign] the density roll DOES plant some Kin (mechanic is live)")
	ok(kin_count < flags_a.size(), "[assign] but most recruits are honest (density is low, not a tax)")
	print("    [assign] %d / %d rolled recruits were Conductor's Kin at seed 0x%X" % [kin_count, flags_a.size(), SEED_A])


# ============================ 2) DEFECTION AT THE BEAT ========================
func test_kin_defects_at_captain_car() -> void:
	var rc := _controller_with_plant()
	var cap = _first_captain_car(rc.run)
	ok(cap != null, "[defect] the generated line has a Section Captain car (the beat)")
	if cap == null:
		return
	var squad_before: int = rc.run.squad.size()
	var order_before: int = rc.run.order
	rc.state = rc._build_car_state(cap)
	# The planted Kin must actually be DEPLOYED onto the board to turn.
	var plant_body = _body_for_instance(rc.state, 101)
	ok(plant_body != null, "[defect] the planted Kin (id 101) deployed into the captain car")
	ok(plant_body != null and plant_body.faction == E.Faction.PLAYER, "[defect] it deploys as a PLAYER unit (still hidden)")
	var ev: Array = rc._apply_betrayal_beat(cap)
	ok(_has_betrayal(ev), "[defect] the CAPTAIN beat emits a BETRAYAL event (renderer can animate it)")
	ok(plant_body != null and plant_body.faction == E.Faction.ENEMY, "[defect] the plant DEFECTS to the ENEMY faction (it now fights the cell)")
	ok(rc.run.order > order_before, "[defect] the defection raises the run Order meter (loud breach, §9)")
	eq(rc.run.squad.size(), squad_before - 1, "[defect] the traitor leaves the persistent roster")
	ok(not _instance_in_squad(rc.run, 101), "[defect] the defector (id 101) is gone from the squad")
	var saw_trace := false
	for t in rc.trace:
		if str(t).begins_with("BETRAYAL:"):
			saw_trace = true
	ok(saw_trace, "[defect] the run trace records the BETRAYAL beat")


# ============================ 3) NOT ON AN ORDINARY CAR =======================
func test_no_trigger_on_non_captain_car() -> void:
	var rc := _controller_with_plant()
	var combat = _first_combat_noncaptain_car(rc.run)
	ok(combat != null, "[timing] the line has an ordinary (non-captain) combat car")
	if combat == null:
		return
	rc.state = rc._build_car_state(combat)
	var plant_body = _body_for_instance(rc.state, 101)
	var ev: Array = rc._apply_betrayal_beat(combat)
	ok(ev.is_empty(), "[timing] NO defection fires on an ordinary combat car (beat is captain-gated)")
	ok(plant_body != null and plant_body.faction == E.Faction.PLAYER, "[timing] the plant stays a loyal-looking PLAYER unit until its beat")
	ok(_instance_in_squad(rc.run, 101), "[timing] the plant is still in the roster (has not turned)")


# ============================ 4) NO FALSE POSITIVE ============================
func test_no_false_trigger_without_a_kin() -> void:
	var rc := _controller_with_clean_squad()
	var cap = _first_captain_car(rc.run)
	if cap == null:
		ok(false, "[clean] expected a captain car")
		return
	var order_before: int = rc.run.order
	rc.state = rc._build_car_state(cap)
	var ev: Array = rc._apply_betrayal_beat(cap)
	ok(ev.is_empty(), "[clean] a squad with NO Kin never triggers a betrayal on a captain car")
	eq(rc.run.order, order_before, "[clean] Order is unchanged when nobody defects")


# ============================ 5) REVEAL IS THE COUNTERPLAY ====================
func test_revealed_kin_does_not_defect() -> void:
	var rc := _controller_with_plant(true)   # plant is REVEALED (a Saboteur scan / vetting exposed it)
	var cap = _first_captain_car(rc.run)
	if cap == null:
		ok(false, "[reveal] expected a captain car")
		return
	rc.state = rc._build_car_state(cap)
	var plant_body = _body_for_instance(rc.state, 101)
	ok(plant_body != null and plant_body.betrayer_revealed, "[reveal] the deployed plant carries the revealed flag")
	var ev: Array = rc._apply_betrayal_beat(cap)
	ok(ev.is_empty(), "[reveal] a REVEALED (vetted) Kin does NOT turn — vetting is the counterplay")
	ok(plant_body != null and plant_body.faction == E.Faction.PLAYER, "[reveal] the revealed plant stays loyal on the board")
	ok(_instance_in_squad(rc.run, 101), "[reveal] a revealed plant is retained (the operator handles it)")


# ============================ 6) REPRODUCIBILITY =============================
func test_betrayal_beat_is_reproducible() -> void:
	var a := _fire_fingerprint()
	var b := _fire_fingerprint()
	eq(a, b, "[determinism] the same (seed, plant, captain) reproduces the same defection byte-for-byte")


# ============================ 7) ONCE PER PLANT =============================
func test_defector_leaves_roster_and_never_refires() -> void:
	var rc := _controller_with_plant()
	var caps := _all_captain_cars(rc.run)
	ok(caps.size() >= 1, "[once] the line has at least one captain car")
	if caps.is_empty():
		return
	# First captain: the plant defects.
	rc.state = rc._build_car_state(caps[0])
	var ev1: Array = rc._apply_betrayal_beat(caps[0])
	ok(_has_betrayal(ev1), "[once] the plant defects at the FIRST captain car")
	# Any subsequent captain build: the plant is gone from the squad, so nothing can re-trigger.
	rc.state = rc._build_car_state(caps[0])   # rebuild the same beat car with the reduced roster
	var ev2: Array = rc._apply_betrayal_beat(caps[0])
	ok(ev2.is_empty(), "[once] no second defection — the traitor already left the roster (once per plant)")


# ============================ helpers ========================================
## Roll a deterministic sequence of recruits from one seeded RNG and report each one's Kin flag.
## Fresh squad per roll so the hard-cap refusal never masks the density roll; the RNG stream is
## shared, so this is a stable per-seed fingerprint of the hidden-trait assignment.
func _kin_flags(seed: int) -> Array:
	var db := ContentDB.new()
	var rng := IntRng.new(seed)
	var flags: Array = []
	for i in range(200):
		var squad: Array = []
		var r: Dictionary = Recruitment.roll_recruit(db, rng, squad, i + 1)
		flags.append(r.get("ok", false) and r.get("unit") != null and r.unit.hidden_betrayer)
	return flags


## A controller drafted on SEED_A, then its squad REPLACED with a controlled 3-member cell whose
## MIDDLE member (id 101) is a Conductor's Kin. All three fit a captain car's 3 spawn tiles, so the
## plant is guaranteed to deploy. `revealed` pre-exposes the plant (the reveal-counterplay case).
func _controller_with_plant(revealed: bool = false) -> RunController:
	var rc := _base_controller()
	var a = UnitInstance.from_archetype(rc.db, "bruiser", [], "Ally0", 100)
	var plant = UnitInstance.from_archetype(rc.db, "bruiser", ["conductors_kin"], "Plant", 101)
	var b = UnitInstance.from_archetype(rc.db, "bruiser", [], "Ally2", 102)
	if revealed:
		plant.betrayer_revealed = true
	rc.run.squad = [a, plant, b]
	return rc


func _controller_with_clean_squad() -> RunController:
	var rc := _base_controller()
	var s: Array = []
	for i in range(3):
		s.append(UnitInstance.from_archetype(rc.db, "bruiser", [], "Clean%d" % i, 100 + i))
	rc.run.squad = s
	return rc


func _base_controller() -> RunController:
	var rc := RunController.new()
	rc.headless = true
	rc.db = ContentDB.new()
	rc.seed = SEED_A
	rc._run_draft(3)    # generates run + line (captain cars included) without running combat
	return rc


## A compact fingerprint of one full betrayal beat: the emitted event + resulting faction + order
## delta + roster shrink. Two identical setups must produce an identical string (determinism).
func _fire_fingerprint() -> String:
	var rc := _controller_with_plant()
	var cap = _first_captain_car(rc.run)
	if cap == null:
		return "NO_CAPTAIN"
	var order_before: int = rc.run.order
	var squad_before: int = rc.run.squad.size()
	rc.state = rc._build_car_state(cap)
	var body = _body_for_instance(rc.state, 101)
	var ev: Array = rc._apply_betrayal_beat(cap)
	var parts: Array = []
	parts.append("events=%d" % ev.size())
	parts.append("betrayal=%s" % str(_has_betrayal(ev)))
	parts.append("faction=%d" % (body.faction if body != null else -1))
	parts.append("order_delta=%d" % (rc.run.order - order_before))
	parts.append("squad_delta=%d" % (rc.run.squad.size() - squad_before))
	return " | ".join(parts)


func _has_betrayal(ev: Array) -> bool:
	for e in ev:
		if e.type == E.Ev.BETRAYAL:
			return true
	return false


func _body_for_instance(s, inst_id: int):
	if s == null:
		return null
	for id in s.entity_ids_sorted():
		var e = s.entities.get(id)
		if e != null and e.is_unit and int(e.instance_id) == inst_id:
			return e
	return null


func _instance_in_squad(run, inst_id: int) -> bool:
	for u in run.squad:
		if u != null and int(u.id) == inst_id:
			return true
	return false


func _first_captain_car(run):
	for c in run.line:
		if c.car_type == E.CarType.CAPTAIN:
			return c
	return null


func _all_captain_cars(run) -> Array:
	var out: Array = []
	for c in run.line:
		if c.car_type == E.CarType.CAPTAIN:
			out.append(c)
	return out


func _first_combat_noncaptain_car(run):
	for c in run.line:
		if c.is_combat() and c.car_type != E.CarType.CAPTAIN:
			return c
	return null
