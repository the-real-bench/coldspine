extends SceneTree
## BALANCE smoke test (Playability & Balance closeout). Proves the game is WINNABLE end-to-end via
## the NATURAL combat path — no fast-forward, no stall-as-clear loophole. Drives a full run through
## RunController on a NAMED seed and asserts:
##
##   1. The run reaches a NON-LOSS ending (a real victory: HARD STOP / SEIZE / PYRRHIC / LIBERATION).
##   2. EVERY combat/captain car on the line was GENUINELY WON (the trace shows "WON", never
##      "STALLED" or "LOST"). A stall or loss does NOT clear a car — the controller treats it as a
##      run loss — so a non-LOSS ending here means the cell actually fought through every gate.
##   3. All four Section Captains were beaten on the way to the Engine.
##   4. Determinism: the same seed reproduces the identical ending AND the identical car-by-car trace.
##
## The win is earned by the auto-pilot's competence (skilled draft, focus fire, melee slams, an
## opening-round overwatch hold that blunts the alpha-strike) plus the between-cars regroup breather
## (POST_COMBAT_REGROUP_HP) — NOT by weakening enemies (their stats are untouched; most seeds still
## lose). This is a deliberately HARD roguelite: 0x683 is a clean line the skilled cell clears.
##
## RE-PIN (Stage C, 2026-07-02): was 0x4333. Stage A wired real per-unit accuracy + passives +
## modifiers, which shifted every to-hit roll, so the old pin no longer wins (it encoded pre-Stage-A
## balance). 0x683 was found by an honest full-line seed scan (tests/_seed_search.gd, 2000 seeds):
## the auto-pilot clears all 29 cars, beats all 4 Section Captains, and reaches LIBERATION with NO
## enemy weakened and NO squad buff. Only ~0.45% of seeds win (9/2000) — the game stays brutally
## hard. NOTE: this remains a full-heal-regroup win; see POST_COMBAT_REGROUP_HP in core/sim_enums.gd
## for the measured deadlock (the bot wins 0% of lines at any reduced regroup).
##
## RE-PIN (Wave 3b momentum-live, 2026-07-04): was 0x300. Wave 3b made the Firebrand momentum meter
## LIVE (accrues +1/car, grants +dmg/move/acc, Vanguard autocrit fires on real shots) — a real,
## deterministic combat change that RESHUFFLES which seeds the auto-pilot clears (the meter helps:
## telemetry shows more runs reaching 2 captains, 13 vs 5). The old pin 0x300 no longer resolves to a
## win under the new deterministic trace (NO content weakened — momentum only strengthens the squad).
## An honest full-line sweep (tests/_seed_search_w3b.gd, seeds 0x385..) found 0x71B: the auto-pilot
## clears all 29 cars, beats all 4 Section Captains, and reaches HARD STOP. (0x62E → PYRRHIC also wins.)
##
## RE-PIN (Wave 2 enemy-AI true-to-design, 2026-07-04): was 0x61E. Wave 2 fixed enemies that were
## behaving WEAKER than designed (a harmless Net Gunner, a walking Sentry Turret, an inverted Riot
## Shield block, ambush enemies that never woke, the Majordomo's missing cover gate, the Foreman's
## un-dropped guard buff, the Conductor's body chasing the squad while immune). Enemies are now
## CORRECTLY harder, so the old pin 0x61E no longer wins — NOT because any stat was weakened (none
## were). An honest full-line sweep (tests/_seed_search_w2.gd, 800 seeds) found 0x300: the auto-pilot
## clears all 29 cars, beats all 4 Section Captains, and reaches HARD STOP with no enemy weakened and
## no squad buff. Win-rate fell to ~0.125% (1/800) from ~0.45% — the corrected enemies made the
## brutal roguelite harder, and the toolless proxy bot pays for it; a human plays far above the bot.
## The natural win still EXISTS, so the game stays validated-winnable at Wave-2 enemy stats.
## (The gardener's gas-shroud gate remains an OPEN owner-gate content item — see captain_system.gd —
## so she is not yet part of the gate difficulty; the win above is with the other 3 captains gating.)
##
## RE-PIN (Batch 5 / Stage 1, 2026-07-02): was 0x683. Stage 1 gave the auto-pilot ordinary-combat
## competence — focus-fire threat targeting, a damage-avoidant (cover-hugging) advance, and a narrow
## flee-or-die low-HP retreat-to-cover — which changes EVERY deterministic AUTO trace (a smarter pilot
## plays each fight differently). 200-seed telemetry confirmed the intended shift vs the verified
## baseline: combat_security_01 losses 23->15, combat_security_02 40->31, bunk_stacks 18->15, and runs
## reaching 2 captains rose 7->20 — real ordinary-survival gains, NOT a weakening of enemies. The old
## fragile line 0x683 no longer resolves to a win under the new play; 0x61E was found by the same
## honest full-line scan and clears all 29 cars + all 4 Section Captains to a non-LOSS ending (HARD
## STOP) with no enemy weakened. (Final win-rate is a touch lower than baseline — the toolless proxy
## bot pays a turn of fire when it takes cover; a human retreats then heals/uses abilities the bot has
## no access to, so this is a floor, per audit balance-ai. See tests/balance_telemetry.gd.)
##
## Run: godot --headless --path . --script res://tests/balance_smoke.gd

const E = preload("res://core/sim_enums.gd")
const RunController = preload("res://app/run_controller.gd")
const ContentDB = preload("res://core/units/content_db.gd")

# A named seed whose line the skilled auto-pilot clears end-to-end (found via a seed scan; the win
# is reproducible + deterministic). Most seeds LOSE — this is not a trivialized game.
const WIN_SEED := 0x71B

var _pass: int = 0
var _fail: int = 0
var _fails: Array = []


func _initialize() -> void:
	print("\n=== COLDSPINE — BALANCE smoke test (natural-win proof) ===")
	test_natural_run_is_winnable()
	test_every_combat_genuinely_won()
	test_all_captains_beaten()
	test_win_is_deterministic()
	print("\n--- BALANCE SMOKE: %d passed, %d failed ---" % [_pass, _fail])
	for f in _fails:
		print("    FAIL: " + f)
	if _fail == 0:
		print("BALANCE GREEN — a natural full run wins end-to-end via real combat, deterministically.\n")
	quit(0 if _fail == 0 else 1)


func ok(cond: bool, msg: String) -> void:
	if cond:
		_pass += 1
	else:
		_fail += 1
		_fails.append(msg)
		print("    [FAIL] " + msg)


func eq(a, b, msg: String) -> void:
	ok(a == b, "%s (got %s, want %s)" % [msg, str(a), str(b)])


func _drive(seed: int) -> RunController:
	var rc := RunController.new()
	rc.headless = true
	rc.db = ContentDB.new()
	rc.seed = seed
	rc.drive_full_run(seed, 3)
	return rc


# ============================ TESTS ===========================================
func test_natural_run_is_winnable() -> void:
	var rc := _drive(WIN_SEED)
	ok(rc.run != null, "[balance] run state was created")
	ok(rc.ending != -1, "[balance] the natural run resolved an ending")
	ok(rc.ending != E.EndingId.LOSS, "[balance] the natural run reached a NON-LOSS ending (a real win)")
	ok(rc.run.position >= rc.run.line.size() - 1, "[balance] the run reached the Engine (full line)")
	# Print the full proof trace for the lead.
	print("\n[balance_smoke] NATURAL WIN trace (seed 0x%X — every fight fought for real):" % WIN_SEED)
	for t in rc.trace:
		print("    " + str(t))
	print("    ENDING REACHED: %s" % rc._ending_name(rc.ending))


func test_every_combat_genuinely_won() -> void:
	var rc := _drive(WIN_SEED)
	# No combat car may have STALLED or been LOST — a non-win never clears a car, so if the run
	# reached the Engine, the trace must contain no failure markers on any combat line.
	var stalled := 0
	var lost := 0
	var combats_won := 0
	for t in rc.trace:
		var s := str(t)
		if s.find(": STALLED") >= 0:
			stalled += 1
		if s.find(": LOST") >= 0:
			lost += 1
		if s.find(": WON") >= 0:
			combats_won += 1
	eq(stalled, 0, "[balance] no combat STALLED (every fight was closed out)")
	eq(lost, 0, "[balance] no combat was LOST")
	ok(combats_won >= 8, "[balance] the cell genuinely WON many fights across the line (>=8)")


func test_all_captains_beaten() -> void:
	var rc := _drive(WIN_SEED)
	var caps_won := 0
	for t in rc.trace:
		var s := str(t)
		if s.find("[CAPTAIN/") >= 0 and s.find(": WON") >= 0:
			caps_won += 1
	ok(caps_won >= 4, "[balance] all four Section Captains were genuinely beaten (got %d)" % caps_won)


func test_win_is_deterministic() -> void:
	var a := _drive(WIN_SEED)
	var b := _drive(WIN_SEED)
	eq(a.ending, b.ending, "[balance] same seed -> identical ending")
	eq(str(a.trace), str(b.trace), "[balance] same seed -> byte-identical car-by-car trace")
