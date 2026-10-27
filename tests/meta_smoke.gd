extends SceneTree
## BATCH 4 — META / PAYOUT smoke test (S6-2 the loop-closer + S6-1 ending tones; NEW file, touches NO
## existing suite). Drives the run-end reconciliation HEADLESSLY through the controller's test seam
## RunController.finalize_run_scripted(profile, run, ending) — the EXACT award+enshrine+stats logic the
## on-screen _finalize_run runs — against an IN-MEMORY MetaProfile, with NO disk I/O (it never calls
## SaveSystem.save_profile / clear_run, so no user:// save file is written). Also asserts the 5-tone
## ending color selection via RunScreens.ending_tone (a pure function, no SceneTree).
##
## Proves:
##   1. Award math: meta-currency awarded = (base + cars*PER_CAR) * draft_mult / 100, for x1.00 / x1.25
##      / x1.60 draft multipliers — i.e. the payout scales by run.draft_payout_mult.
##   2. WIN and LOSS both pay out (win uses PAYOUT_WIN_BASE, loss the PAYOUT_LOSS_BASE consolation).
##   3. Fallen enshrined: the run's RunState.memorial entries land in the profile Memorial (via the real
##      Legacy.harvest_run), the profile total grows, and the ledger's fallen count matches.
##   4. Stats bumped: runs +1 on every finalize, wins +1 only on a win, best_ending tracked, fallen counter.
##   5. The ledger dict carries the right verdict/survivors/order/cars + award + new total.
##   6. All 5 endings (LOSS/HARD_STOP/SEIZE_ENGINE/PYRRHIC/LIBERATION) select a tone color.
##   7. NO disk write: the seam is pure (the live save is gated behind `not headless`, never hit here).
##   8. ATOMIC SAVE-SLOT (release-readiness #5): SaveSystem.save_slot is tmp-then-swap with a .bak of
##      the previous save; a CORRUPT slot recovers from .bak (preserving the corrupt file) instead of
##      silently resetting; clear_slot removes every sidecar. Driven on a SCRATCH slot path — the
##      real profile/run saves are never touched.
##   9. SAVE SANDBOX (harness safety): the --save-sandbox / COLDSPINE_SAVE_SANDBOX=1 seam diverts
##      the profile/run save paths to sandbox_-prefixed files; without it the paths are unchanged.
##
## Run: godot --headless --path . --script res://tests/meta_smoke.gd

const E = preload("res://core/sim_enums.gd")
const RunController = preload("res://app/run_controller.gd")
const ContentDB = preload("res://core/units/content_db.gd")
const RunState = preload("res://core/run/run_state.gd")
const MetaProfile = preload("res://core/meta/meta_profile.gd")
const Unlocks = preload("res://core/meta/unlocks.gd")
const RunScreens = preload("res://app/screens/run_screens.gd")

const SEED_A := 0xC01D5

var _pass: int = 0
var _fail: int = 0
var _fails: Array = []


func _initialize() -> void:
	print("\n=== COLDSPINE — META smoke test (Batch 4: payout loop-closer + ending tones, headless) ===")
	test_award_scales_by_draft_mult()
	test_win_and_loss_both_pay_out()
	test_fallen_enshrined_to_memorial()
	test_stats_bumped()
	test_ledger_facts()
	test_all_five_endings_have_a_tone()
	test_seam_writes_no_save_file()
	test_save_sandbox_prefixes_paths()
	test_atomic_save_slot_keeps_a_backup()
	test_corrupt_slot_recovers_from_backup()
	test_corrupt_slot_without_backup_surfaces_and_returns_null()
	test_clear_slot_removes_all_sidecars()
	print("\n--- META SMOKE: %d passed, %d failed ---" % [_pass, _fail])
	for f in _fails:
		print("    FAIL: " + f)
	if _fail == 0:
		print("META GREEN — the payout loop closes (award x draft mult, enshrine, stats) + 5 ending tones, no disk write.\n")
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
	rc.headless = true   # the seam itself does no disk I/O; headless just keeps it safe
	rc.db = ContentDB.new()
	return rc


## A real RunState (generated line) with `clear` cars marked resolved, a known draft mult, order, and
## `fallen` memorial entries. Deterministic from the seed.
func _make_run(seed: int, mult: int, clear: int, order: int, fallen: int) -> RunState:
	var r: RunState = RunState.new_run(seed, [], mult)
	r.order = order
	var n: int = min(clear, r.line.size())
	for i in range(n):
		r.line[i].resolved = true
	for i in range(fallen):
		r.memorial.append({
			"id": i, "instance_id": 100 + i, "name": "Fallen-%d" % i,
			"archetype": "bruiser", "traits": ["stalwart"], "inventory": [],
		})
	return r


## How many cars the run has marked resolved (mirror of Unlocks._cars_cleared for the expectation).
func _cleared(run: RunState) -> int:
	var n: int = 0
	for c in run.line:
		if c != null and c.resolved:
			n += 1
	return n


# ============================ TESTS ===========================================
## 1. Award = (base + cars*PER_CAR) * draft_mult / 100, for each draft multiplier.
func test_award_scales_by_draft_mult() -> void:
	for mult in [E.DRAFT_PAYOUT_X3, E.DRAFT_PAYOUT_X2, E.DRAFT_PAYOUT_X1]:   # 100 / 125 / 160
		var rc := _controller()
		var run := _make_run(SEED_A, mult, 4, 10, 0)
		var profile := MetaProfile.new()
		var cleared := _cleared(run)
		var raw: int = Unlocks.PAYOUT_WIN_BASE + cleared * Unlocks.PAYOUT_PER_CAR
		var expect: int = (raw * mult) / 100
		var ledger: Dictionary = rc.finalize_run_scripted(profile, run, E.EndingId.HARD_STOP)
		eq(int(ledger.get("award", -1)), expect, "WIN award scales by draft mult x%d" % mult)
		eq(int(profile.meta_currency), expect, "profile meta_currency credited the award (mult x%d)" % mult)
	# The higher-risk (fewer-starter) multiplier must pay strictly MORE for the same cleared count.
	var rc_a := _controller(); var rc_b := _controller()
	var run_a := _make_run(SEED_A, E.DRAFT_PAYOUT_X3, 4, 10, 0)
	var run_b := _make_run(SEED_A, E.DRAFT_PAYOUT_X1, 4, 10, 0)
	var a: int = int(rc_a.finalize_run_scripted(MetaProfile.new(), run_a, E.EndingId.HARD_STOP).get("award", 0))
	var b: int = int(rc_b.finalize_run_scripted(MetaProfile.new(), run_b, E.EndingId.HARD_STOP).get("award", 0))
	ok(b > a, "x1.60 draft mult pays strictly more than x1.00 (%d > %d)" % [b, a])


## 2. WIN and LOSS both pay out (win=PAYOUT_WIN_BASE base, loss=PAYOUT_LOSS_BASE consolation).
func test_win_and_loss_both_pay_out() -> void:
	var cleared := 3
	var raw_win: int = Unlocks.PAYOUT_WIN_BASE + cleared * Unlocks.PAYOUT_PER_CAR
	var raw_loss: int = Unlocks.PAYOUT_LOSS_BASE + cleared * Unlocks.PAYOUT_PER_CAR

	var rc_w := _controller()
	var run_w := _make_run(SEED_A, E.DRAFT_PAYOUT_X3, cleared, 10, 0)
	var lw: Dictionary = rc_w.finalize_run_scripted(MetaProfile.new(), run_w, E.EndingId.LIBERATION)
	eq(int(lw.get("award", -1)), raw_win, "WIN pays the win base + per-car")
	eq(bool(lw.get("won", false)), true, "LIBERATION ledger flags won")

	var rc_l := _controller()
	var run_l := _make_run(SEED_A, E.DRAFT_PAYOUT_X3, cleared, 10, 0)
	var ll: Dictionary = rc_l.finalize_run_scripted(MetaProfile.new(), run_l, E.EndingId.LOSS)
	eq(int(ll.get("award", -1)), raw_loss, "LOSS still pays the consolation base + per-car")
	eq(bool(ll.get("won", true)), false, "LOSS ledger flags not-won")
	ok(int(ll.get("award", 0)) > 0, "a LOSS award is still positive (roguelite ratchet)")


## 3. Fallen enshrined: the run's memorial entries are harvested into the profile Memorial.
func test_fallen_enshrined_to_memorial() -> void:
	var rc := _controller()
	var run := _make_run(SEED_A, E.DRAFT_PAYOUT_X3, 2, 10, 3)   # 3 fallen on this run
	var profile := MetaProfile.new()
	eq(profile.memorial.size(), 0, "profile starts with an empty Memorial")
	var ledger: Dictionary = rc.finalize_run_scripted(profile, run, E.EndingId.PYRRHIC)
	eq(profile.memorial.size(), 3, "all 3 fallen enshrined into the profile Memorial")
	eq(int(ledger.get("fallen", -1)), 3, "ledger reports 3 enshrined")
	eq(int(profile.stats.get("fallen", 0)), 3, "stats fallen counter bumped by 3")
	# Re-finalizing the SAME run de-dupes on legacy_id (no double-enshrine).
	var ledger2: Dictionary = rc.finalize_run_scripted(profile, run, E.EndingId.PYRRHIC)
	eq(profile.memorial.size(), 3, "re-finalize does not double-enshrine (legacy_id de-dupe)")
	eq(int(ledger2.get("fallen", -1)), 0, "second finalize enshrines 0 new")


## 4. Stats: runs +1 every finalize; wins +1 only on a win; best_ending tracked.
func test_stats_bumped() -> void:
	var rc := _controller()
	var profile := MetaProfile.new()
	var run1 := _make_run(SEED_A, E.DRAFT_PAYOUT_X3, 2, 10, 0)
	rc.finalize_run_scripted(profile, run1, E.EndingId.LOSS)
	eq(int(profile.stats.get("runs", 0)), 1, "runs bumped to 1 after a loss")
	eq(int(profile.stats.get("wins", 0)), 0, "wins NOT bumped on a loss")
	eq(int(profile.stats.get("best_ending", -99)), E.EndingId.LOSS, "best_ending tracks LOSS first")
	var run2 := _make_run(SEED_A, E.DRAFT_PAYOUT_X3, 2, 10, 0)
	rc.finalize_run_scripted(profile, run2, E.EndingId.LIBERATION)
	eq(int(profile.stats.get("runs", 0)), 2, "runs bumped to 2 after a win")
	eq(int(profile.stats.get("wins", 0)), 1, "wins bumped to 1 on the win")
	eq(int(profile.stats.get("best_ending", -99)), E.EndingId.LIBERATION, "best_ending upgraded to LIBERATION")
	# A weaker later ending does NOT lower best_ending.
	var run3 := _make_run(SEED_A, E.DRAFT_PAYOUT_X3, 2, 10, 0)
	rc.finalize_run_scripted(profile, run3, E.EndingId.HARD_STOP)
	eq(int(profile.stats.get("best_ending", -99)), E.EndingId.LIBERATION, "best_ending stays at the best reached")


## 5. The ledger carries the right run facts + running total.
func test_ledger_facts() -> void:
	var rc := _controller()
	var profile := MetaProfile.new()
	profile.meta_currency = 50   # pre-existing balance
	var run := _make_run(SEED_A, E.DRAFT_PAYOUT_X2, 5, 33, 1)
	var cleared := _cleared(run)
	var ledger: Dictionary = rc.finalize_run_scripted(profile, run, E.EndingId.SEIZE_ENGINE)
	eq(String(ledger.get("verdict", "")), "SEIZE THE ENGINE", "ledger verdict name")
	eq(int(ledger.get("cars", -1)), cleared, "ledger cars cleared matches resolved count")
	eq(int(ledger.get("order", -1)), 33, "ledger carries final Order")
	eq(int(ledger.get("mult", -1)), E.DRAFT_PAYOUT_X2, "ledger carries the draft mult")
	eq(int(ledger.get("base", -1)), Unlocks.PAYOUT_WIN_BASE, "ledger base = win base")
	eq(int(ledger.get("per_car", -1)), cleared * Unlocks.PAYOUT_PER_CAR, "ledger per-car bonus")
	eq(int(ledger.get("total", -1)), int(profile.meta_currency), "ledger total = new profile balance")
	eq(int(ledger.get("total", -1)), 50 + int(ledger.get("award", 0)), "new total = old balance + award")


## 6. All five endings map to a tone color (pure RunScreens.ending_tone — no SceneTree).
func test_all_five_endings_have_a_tone() -> void:
	var screens := RunScreens.new()   # .new() does NOT run _ready (not added to the tree) — pure call
	var seen: Array = []
	for eid in [E.EndingId.LOSS, E.EndingId.HARD_STOP, E.EndingId.SEIZE_ENGINE, E.EndingId.PYRRHIC, E.EndingId.LIBERATION]:
		var col: Color = screens.ending_tone(eid)
		ok(col.a > 0.0, "ending %d selects a visible tone color" % eid)
		seen.append(col)
	eq(seen.size(), 5, "all 5 endings produced a tone")
	# LOSS must read distinctly from a winning tone (the feed dies hard vs the wins).
	ok(screens.ending_tone(E.EndingId.LOSS) != screens.ending_tone(E.EndingId.LIBERATION),
		"LOSS tone is distinct from LIBERATION (alarm vs whole)")
	screens.free()


## 7. The headless seam writes NO user:// save file (the live save is gated behind `not headless`).
## Non-destructive: snapshot the profile file's existence + modified-time BEFORE, run the seam, and
## assert it is UNCHANGED (never created, never re-written) — without deleting a real player's save.
func test_seam_writes_no_save_file() -> void:
	var path := "user://coldspine_profile.json"
	var existed_before := FileAccess.file_exists(path)
	var mtime_before := FileAccess.get_modified_time(path) if existed_before else 0
	var rc := _controller()
	var run := _make_run(SEED_A, E.DRAFT_PAYOUT_X3, 3, 10, 2)
	rc.finalize_run_scripted(MetaProfile.new(), run, E.EndingId.HARD_STOP)
	var existed_after := FileAccess.file_exists(path)
	var mtime_after := FileAccess.get_modified_time(path) if existed_after else 0
	eq(existed_after, existed_before, "finalize_run_scripted did not CREATE a profile save file")
	eq(mtime_after, mtime_before, "finalize_run_scripted did not RE-WRITE the profile save file")


## 7b. SAVE SANDBOX (harness safety, W1-9): with the sandbox armed (env seam — the same predicate
## the `--save-sandbox` cmdline flag feeds), the profile/run save paths gain the "sandbox_"
## filename prefix in the SAME user:// dir; without it, they are byte-identical to the real
## constants — so a sandboxed harness run (screenshot tour) can never touch the owner's real saves.
func test_save_sandbox_prefixes_paths() -> void:
	# SAFETY PROPERTY (W1-9b): THIS process is a res://tests/ script, so it is AUTO-sandboxed — a
	# suite can never write the owner's real profile/run slot even by driving the menu/RunController
	# game code. Assert the auto-arm holds and the live paths are the sandbox_ files.
	ok(SaveSystem.save_sandboxed(), "a res://tests/ process is auto-sandboxed (owner saves untouchable)")
	eq(SaveSystem.profile_path(), "user://sandbox_coldspine_profile.json",
		"auto-sandboxed profile path carries the sandbox_ prefix (same dir)")
	eq(SaveSystem.run_path(), "user://sandbox_coldspine_run.json",
		"auto-sandboxed run path carries the sandbox_ prefix (same dir)")
	# PURE TRANSFORM (armed-independent): sandbox_name always prefixes, so the diversion SHAPE is
	# provable without depending on this process's (already-armed) state — this is what the real
	# game applies the instant it is launched with --save-sandbox / COLDSPINE_SAVE_SANDBOX=1.
	eq(SaveSystem.sandbox_name(SaveSystem.PROFILE_PATH), "user://sandbox_coldspine_profile.json",
		"sandbox_name() prefixes the real profile constant")
	eq(SaveSystem.sandbox_name(SaveSystem.RUN_PATH), "user://sandbox_coldspine_run.json",
		"sandbox_name() prefixes the real run constant")
	eq(SaveSystem.sandbox_name(SaveSystem.PROFILE_PATH).get_base_dir(),
		SaveSystem.PROFILE_PATH.get_base_dir(), "the sandbox stays in the same user:// dir")
	# The explicit in-process arm is idempotent while auto-armed (the run_tests/run_smoke opt-in).
	SaveSystem.force_sandbox = true
	ok(SaveSystem.save_sandboxed(), "force_sandbox keeps the sandbox armed (harness opt-in)")
	SaveSystem.force_sandbox = false
	ok(SaveSystem.save_sandboxed(), "still auto-sandboxed after clearing force_sandbox (test-script seam)")


# ============================ ATOMIC SAVE-SLOT (release-readiness #5) =========
## All slot tests run on a SCRATCH path so the real profile/run saves are never touched.
const SLOT := "user://coldspine_test_slot.json"


## 8a. save_slot is tmp-then-swap: two saves leave main = newest, .bak = previous, no .tmp behind.
func test_atomic_save_slot_keeps_a_backup() -> void:
	SaveSystem.clear_slot(SLOT)
	ok(SaveSystem.save_slot(SLOT, {"gen": 1, "who": "first"}), "save_slot wrote generation 1")
	ok(SaveSystem.save_slot(SLOT, {"gen": 2, "who": "second"}), "save_slot wrote generation 2")
	ok(FileAccess.file_exists(SLOT), "the main slot file exists after the swap")
	ok(not FileAccess.file_exists(SLOT + SaveSystem.TMP_EXT), "no .tmp left behind (swap completed)")
	ok(FileAccess.file_exists(SLOT + SaveSystem.BAK_EXT), "the previous save survives as .bak")
	var main = SaveSystem.load_slot(SLOT)
	eq(int(main.get("gen", -1)), 2, "the main slot holds the NEWEST save")
	var j := JSON.new()
	ok(j.parse(FileAccess.get_file_as_string(SLOT + SaveSystem.BAK_EXT)) == OK
		and int(j.data.get("gen", -1)) == 1, "the .bak holds the PREVIOUS save (generation 1)")


## 8b. A CORRUPT main file recovers the previous save from .bak — progress is NOT silently erased —
## and the corrupt file is preserved as .corrupt while the main file is re-persisted clean.
func test_corrupt_slot_recovers_from_backup() -> void:
	SaveSystem.clear_slot(SLOT)
	SaveSystem.save_slot(SLOT, {"gen": 1, "meta_currency": 88})
	SaveSystem.save_slot(SLOT, {"gen": 2, "meta_currency": 137})
	# Simulate an OS kill mid-write of the NEXT save: the main file is truncated garbage.
	var f := FileAccess.open(SLOT, FileAccess.WRITE)
	f.store_string("{ \"gen\": 3, \"meta_curr")   # truncated JSON
	f.close()
	var d = SaveSystem.load_slot(SLOT)
	ok(d != null, "a corrupt slot still loads (recovery, not reset)")
	eq(int(d.get("gen", -1)), 1, "recovery returns the .bak payload (the previous good save)")
	eq(int(d.get("meta_currency", -1)), 88, "payout-relevant state (currency) survives the corruption")
	ok(FileAccess.file_exists(SLOT + SaveSystem.CORRUPT_EXT), "the corrupt file is kept as .corrupt (forensics)")
	var again = SaveSystem.load_slot(SLOT)
	eq(int(again.get("gen", -1)), 1, "recovery re-persisted the main file (next load is clean)")


## 8c. A corrupt slot with NO usable backup returns null (the caller falls back fresh) but still
## preserves the corrupt file — surfaced, never a silent erase-and-carry-on.
func test_corrupt_slot_without_backup_surfaces_and_returns_null() -> void:
	SaveSystem.clear_slot(SLOT)
	var f := FileAccess.open(SLOT, FileAccess.WRITE)
	f.store_string("not json at all ][")
	f.close()
	var d = SaveSystem.load_slot(SLOT)
	ok(d == null, "corrupt + no backup -> null (caller falls back fresh)")
	ok(FileAccess.file_exists(SLOT + SaveSystem.CORRUPT_EXT), "the corrupt file is still preserved as .corrupt")
	ok(not FileAccess.file_exists(SLOT), "the corrupt main file was moved aside, not left to poison the next save")


## 8d. clear_slot removes the main file AND every sidecar (permadeath: no backup may resurrect a
## cleared run slot).
func test_clear_slot_removes_all_sidecars() -> void:
	SaveSystem.clear_slot(SLOT)
	SaveSystem.save_slot(SLOT, {"gen": 1})
	SaveSystem.save_slot(SLOT, {"gen": 2})
	var f := FileAccess.open(SLOT + SaveSystem.CORRUPT_EXT, FileAccess.WRITE)
	f.store_string("junk")
	f.close()
	SaveSystem.clear_slot(SLOT)
	for p in [SLOT, SLOT + SaveSystem.TMP_EXT, SLOT + SaveSystem.BAK_EXT, SLOT + SaveSystem.CORRUPT_EXT]:
		ok(not FileAccess.file_exists(p), "clear_slot removed " + p)
