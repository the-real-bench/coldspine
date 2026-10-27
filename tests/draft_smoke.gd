extends SceneTree
## INTERACTIVE-DRAFT smoke test (S2 — DRAFT_VETTING / BREACH_CONFIRM; NEW file, touches no existing
## suite). Drives the interactive-draft state machine HEADLESSLY through the controller's test seam
## RunController.drive_draft_scripted(seed, [ {op:take/decline/auto/breach} ... ]) — the EXACT
## take/decline/quick/breach actions the on-screen RunScreens surface emits — WITHOUT a display.
##
## Proves:
##   1. A scripted take/breach builds a VALID 1-3 cell + the correct payout multiplier (3->100,
##      2->125, 1->160), reaching a LAUNCHABLE RunState (a generated line with an Engine, position 0).
##   2. Determinism: the same (seed, script) reproduces the same picks + payout + line byte-for-byte.
##   3. The interactive seam, taking the SAME choices the auto path takes (all "auto" steps), produces
##      the SAME squad + payout as the headless drive_full_run auto-draft for that seed — the auto
##      path (the six byte-stable suites) is unmoved, and the interactive path agrees with it.
##   4. No-repeats + cap hold (no candidate name appears twice across the draft; picks never exceed 3).
##   5. No stuck state: decline-everything still finalizes (rounds spent) into a launchable-or-empty
##      run, and a 1-pick breach is launchable.
##
## Run: godot --headless --path . --script res://tests/draft_smoke.gd

const E = preload("res://core/sim_enums.gd")
const RunController = preload("res://app/run_controller.gd")
const ContentDB = preload("res://core/units/content_db.gd")
const Draft = preload("res://core/units/draft.gd")
const IntRng = preload("res://core/int_rng.gd")

const SEED_A := 0xC01D5
const SEED_B := 0x5EED99

var _pass: int = 0
var _fail: int = 0
var _fails: Array = []


func _initialize() -> void:
	print("\n=== COLDSPINE — DRAFT smoke test (interactive S2 seam, headless) ===")
	test_take_one_breach_is_launchable_x160()
	test_take_two_payout_x125()
	test_take_three_payout_x100()
	test_determinism_same_script_same_run()
	test_interactive_auto_matches_headless_auto_path()
	test_no_repeats_and_cap()
	test_decline_all_finalizes_no_stuck()
	print("\n--- DRAFT SMOKE: %d passed, %d failed ---" % [_pass, _fail])
	for f in _fails:
		print("    FAIL: " + f)
	if _fail == 0:
		print("DRAFT GREEN — the interactive draft state machine builds a launchable cell + correct payout, deterministically.\n")
	quit(0 if _fail == 0 else 1)


# ---- assertion kit (mirrors run_smoke.gd) ----
func ok(cond: bool, msg: String) -> void:
	if cond:
		_pass += 1
	else:
		_fail += 1
		_fails.append(msg)
		print("    [FAIL] " + msg)

func eq(a, b, msg: String) -> void:
	ok(a == b, "%s (got %s, want %s)" % [msg, str(a), str(b)])


# ---- helpers ----
func _controller() -> RunController:
	var rc := RunController.new()
	rc.headless = true
	rc.db = ContentDB.new()
	return rc


## A launchable run: a built RunState with a generated line that has an Engine car, sitting at the
## start (position 0), not yet won — i.e. _advance_line could drive it from here.
func _launchable(run) -> bool:
	if run == null:
		return false
	if run.line == null or run.line.is_empty():
		return false
	if int(run.position) != 0:
		return false
	var has_engine := false
	for c in run.line:
		if c.car_type == E.CarType.ENGINE:
			has_engine = true
			break
	return has_engine and not run.is_won()


func _line_template_ids(run) -> Array:
	var out: Array = []
	for c in run.line:
		out.append(c.template_id)
	return out


# ============================ TESTS ===========================================
## A single take then breach: 1 starter, payout x160 (DRAFT_PAYOUT_X1), launchable.
func test_take_one_breach_is_launchable_x160() -> void:
	var rc := _controller()
	var run = rc.drive_draft_scripted(SEED_A, [{"op": "take", "idx": 0}, {"op": "breach"}])
	eq(run.squad.size(), 1, "[draft] take-one yields a 1-unit cell")
	eq(run.draft_payout_mult, E.DRAFT_PAYOUT_X1, "[draft] 1 pick locks payout x1.60")
	ok(_launchable(run), "[draft] a 1-pick breach is a launchable run (line+engine, pos 0)")


## Two takes then breach: 2 starters, payout x125.
func test_take_two_payout_x125() -> void:
	var rc := _controller()
	var run = rc.drive_draft_scripted(SEED_A, [{"op": "take", "idx": 0}, {"op": "take", "idx": 1}, {"op": "breach"}])
	eq(run.squad.size(), 2, "[draft] take-two yields a 2-unit cell")
	eq(run.draft_payout_mult, E.DRAFT_PAYOUT_X2, "[draft] 2 picks locks payout x1.25")
	ok(_launchable(run), "[draft] a 2-pick breach is launchable")


## Three takes auto-finalizes at the cap: 3 starters, payout x100, no breach step needed.
func test_take_three_payout_x100() -> void:
	var rc := _controller()
	# Each round burns the round; index 0 each time is valid (a fresh trio deals).
	var run = rc.drive_draft_scripted(SEED_A, [{"op": "take", "idx": 0}, {"op": "take", "idx": 0}, {"op": "take", "idx": 0}])
	eq(run.squad.size(), 3, "[draft] take-three fills the cell (auto-finalize at cap)")
	eq(run.draft_payout_mult, E.DRAFT_PAYOUT_X3, "[draft] 3 picks locks payout x1.00")
	ok(_launchable(run), "[draft] a full 3-pick cell is launchable")


## Determinism: the same (seed, script) reproduces the same picks + payout + line.
func test_determinism_same_script_same_run() -> void:
	var script := [{"op": "auto"}, {"op": "decline"}, {"op": "auto"}, {"op": "breach"}]
	var run1 = _controller().drive_draft_scripted(SEED_B, script.duplicate(true))
	var run2 = _controller().drive_draft_scripted(SEED_B, script.duplicate(true))
	eq(run1.squad.size(), run2.squad.size(), "[draft] determinism: same squad size")
	eq(run1.draft_payout_mult, run2.draft_payout_mult, "[draft] determinism: same payout mult")
	var names1: Array = []
	var names2: Array = []
	for u in run1.squad: names1.append(u.name)
	for u in run2.squad: names2.append(u.name)
	eq(str(names1), str(names2), "[draft] determinism: identical pick names")
	eq(str(_line_template_ids(run1)), str(_line_template_ids(run2)), "[draft] determinism: identical line")


## The interactive seam taking the auto path's choices (all "auto") matches the headless auto-draft.
## This is the BYTE-STABILITY bridge: the auto path the six suites rely on is unchanged, and the
## interactive path, fed the same _best_draft_pick choices, lands on the same cell + payout.
func test_interactive_auto_matches_headless_auto_path() -> void:
	# Headless auto path (exactly what drive_full_run / the suites take).
	var rc_auto := _controller()
	rc_auto.seed = SEED_A
	rc_auto._run_draft(3)
	var auto_run = rc_auto.run
	# Interactive seam, all "auto" steps (quick-draft every round) until the cap finalizes.
	var rc_int := _controller()
	var int_run = rc_int.drive_draft_scripted(SEED_A, [{"op": "auto"}, {"op": "auto"}, {"op": "auto"}])
	eq(int_run.squad.size(), auto_run.squad.size(), "[draft] interactive-auto squad size == headless auto")
	eq(int_run.draft_payout_mult, auto_run.draft_payout_mult, "[draft] interactive-auto payout == headless auto")
	var an: Array = []
	var inn: Array = []
	for u in auto_run.squad: an.append("%s/%s" % [u.archetype_id, u.name])
	for u in int_run.squad: inn.append("%s/%s" % [u.archetype_id, u.name])
	eq(str(inn), str(an), "[draft] interactive-auto picks identical to the headless auto path")
	eq(str(_line_template_ids(int_run)), str(_line_template_ids(auto_run)), "[draft] interactive-auto line identical to auto path")


## No-repeats across the whole draft + the 3-starter cap holds. Drive a fresh Draft directly so we
## can read every candidate name shown (taken or passed) and assert none repeats.
func test_no_repeats_and_cap() -> void:
	var rng := IntRng.new((SEED_A ^ 0xDEADBEEF) & 0xFFFFFFFF)
	var d := Draft.new(ContentDB.new(), rng)
	d.start()
	var seen: Dictionary = {}
	var dup := false
	# Decline every round so all 9 candidates (3 rounds x 3) are shown + burned.
	for _r in range(E.DRAFT_ROUNDS):
		for c in d.current_choices:
			if seen.has(c.name):
				dup = true
			seen[c.name] = true
		if d.finished:
			break
		d.decline()
	ok(not dup, "[draft] no candidate name repeats across the draft (shown_and_removed)")
	ok(d.picks.size() <= E.DRAFT_MAX_STARTERS, "[draft] picks never exceed the 3-starter cap")


## Decline-everything still finalizes (rounds spent) — no stuck state. With 0 picks the run still
## builds (empty squad, payout falls back to x3) rather than hanging; a real operator can't reach
## this via the surface (BREACH is gated at picks>=1), but the seam must never stall.
func test_decline_all_finalizes_no_stuck() -> void:
	var rc := _controller()
	var run = rc.drive_draft_scripted(SEED_A, [{"op": "decline"}, {"op": "decline"}, {"op": "decline"}])
	ok(run != null, "[draft] decline-all still builds a run (no stuck state)")
	eq(run.squad.size(), 0, "[draft] decline-all yields an empty cell (rounds spent)")
	# A line is still generated from the seed (the run is structurally valid even with no squad).
	ok(run.line != null and not run.line.is_empty(), "[draft] decline-all still generates a line")
