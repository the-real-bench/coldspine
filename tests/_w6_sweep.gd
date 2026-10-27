extends SceneTree
## SCRATCH sweep harness (Wave-6 balance gate). Prints each NATURAL-WIN seed in a range so the gate
## can re-pin balance_smoke. Additive-only, reads public rc fields exactly like balance_smoke/telemetry.
## TEMPORARY — created + deleted by the balance gate; not part of the suite battery.
## Run: godot --headless --path . --script res://tests/_w6_sweep.gd -- <base> <count> [maxwins]
const E = preload("res://core/sim_enums.gd")
const RunController = preload("res://app/run_controller.gd")
const ContentDB = preload("res://core/units/content_db.gd")

func _initialize() -> void:
	var base := 1
	var count := 4096
	var maxwins := 999999
	var uargs := OS.get_cmdline_user_args()
	if uargs.size() >= 1 and uargs[0].is_valid_int(): base = int(uargs[0])
	if uargs.size() >= 2 and uargs[1].is_valid_int(): count = int(uargs[1])
	if uargs.size() >= 3 and uargs[2].is_valid_int(): maxwins = int(uargs[2])
	print("=== W6 SWEEP base=0x%X count=%d (POST_COMBAT_REGROUP_HP=%d PCT=%d) ===" % [base, count, E.POST_COMBAT_REGROUP_HP, E.POST_COMBAT_REGROUP_PCT])
	var wins := 0
	for i in range(count):
		var seed := base + i
		var rc := RunController.new()
		rc.headless = true
		rc.db = ContentDB.new()
		rc.seed = seed
		rc.drive_full_run(seed, 3)
		var won: bool = rc.ending != -1 and rc.ending != E.EndingId.LOSS
		if won:
			# count genuine combat wins + captains to confirm it is a real full-line win
			var caps := 0
			var stalled := 0
			var lost := 0
			for t in rc.trace:
				var s := str(t)
				if s.find("[CAPTAIN/") >= 0 and s.find(": WON") >= 0: caps += 1
				if s.find(": STALLED") >= 0: stalled += 1
				if s.find(": LOST") >= 0: lost += 1
			wins += 1
			print("WIN 0x%X ending=%s caps=%d stalled=%d lost=%d pos=%d" % [seed, rc._ending_name(rc.ending), caps, stalled, lost, rc.run.position])
			if wins >= maxwins:
				print("=== reached maxwins=%d at seed 0x%X ===" % [maxwins, seed])
				break
		if i > 0 and i % 256 == 0:
			print("  ...progress i=%d seed=0x%X wins=%d" % [i, seed, wins])
	print("=== SWEEP DONE wins=%d / scanned ===" % wins)
	quit(0)
