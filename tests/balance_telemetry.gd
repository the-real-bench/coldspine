extends SceneTree
## BALANCE TELEMETRY — a seed-sweep failure-localization harness (tooling, NOT a pass/fail suite).
##
## Converts the opaque "the auto-pilot wins ~1 seed in 80" backlog number into a DATA TABLE that
## says *where* the run dies: which car index, which car type, and — when it dies at a Section
## Captain — which captain and which physics KEY was the wall. This is the measurement step that
## makes the "smarter auto-pilot / captain-key solver" work measurable instead of guesswork
## (the owner's stated alternative to the POST_COMBAT_REGROUP_HP pillar change).
##
## It is ADDITIVE-ONLY: it drives full runs through RunController exactly like balance_smoke.gd and
## reads only public, already-exposed fields (rc.trace, rc.ending, rc.run.position). It changes NO
## production code and asserts nothing — so it can never make the 1055-check baseline go red. It is
## deterministic: seed N always produces the same line, so the whole table is reproducible.
##
## Run (default sweep = 80 seeds, base 0):
##   godot --headless --path . --script res://tests/balance_telemetry.gd
## Run with a custom sweep size / base (args after `--`):
##   godot --headless --path . --script res://tests/balance_telemetry.gd -- 200 1000
##     -> 200 seeds starting at base 1000.

const E = preload("res://core/sim_enums.gd")
const RunController = preload("res://app/run_controller.gd")
const ContentDB = preload("res://core/units/content_db.gd")

const DEFAULT_SWEEP_N := 80
const DEFAULT_BASE := 0

# template-id substring -> [key, damage-state]. Sourced from content/enemies/captains.json +
# core/captain_system.gd: only the gas + cover keys are damage-IMMUNE; the soak keys stay shootable.
const CAPTAIN_KEYS := {
	"tail_warden": ["unshovable_until_soaked", "shootable (shove-gated)"],
	"foreman": ["kill_to_drop_guard_buff", "shootable (buff threat)"],
	"gardener": ["gas_shroud_must_be_dispersed", "DAMAGE-IMMUNE until gas dispersed"],
	"majordomo": ["destroy_his_cover_then_flank", "SHIELDED until cover stripped"],
	"chief": ["soak_then_into_a_trap", "shootable (shove-gated)"],
	"conductor": ["flood_the_dais_then_shove", "finale: relay-shielded"],
}


func _initialize() -> void:
	var n := DEFAULT_SWEEP_N
	var base := DEFAULT_BASE
	var uargs := OS.get_cmdline_user_args()
	if uargs.size() >= 1 and uargs[0].is_valid_int():
		n = int(uargs[0])
	if uargs.size() >= 2 and uargs[1].is_valid_int():
		base = int(uargs[1])

	print("\n=== COLDSPINE — BALANCE TELEMETRY (failure-localization sweep) ===")
	print("Sweeping %d seeds (base 0x%X)..." % [n, base])

	# Aggregates.
	var wins := 0
	var ending_hist := {}          # ending name -> count
	var death_type_hist := {}      # car TYPE at death -> count (COMBAT / CAPTAIN / FINALE / ...)
	var death_template_hist := {}  # template_id at death -> count
	var caps_cleared_hist := {}    # captains beaten before death (0..4+) -> count of runs
	var deepest := 0

	for i in range(n):
		var seed := base + i
		var rc := _drive(seed)
		var won: bool = rc.ending != -1 and rc.ending != E.EndingId.LOSS
		if won:
			wins += 1
		_bump(ending_hist, rc._ending_name(rc.ending))

		var pos: int = rc.run.position if rc.run != null else 0
		if pos > deepest:
			deepest = pos

		# Localize the death car from the trace (last combat/captain car marked LOST or STALLED).
		var d := _death_car(rc.trace)
		_bump(death_type_hist, d.type)
		if d.template != "":
			_bump(death_template_hist, d.template)

		# How many captains did the cell beat before the run ended?
		var caps_won := _captains_won(rc.trace)
		_bump(caps_cleared_hist, str(caps_won))

	# ---- Report ----
	var losses := n - wins
	var permille := (wins * 1000) / n
	print("\n--- TELEMETRY SUMMARY (%d seeds) ---" % n)
	print("WIN-RATE: %d/%d  (%d.%d%%  ~ 1 in %s)" % [
		wins, n, permille / 10, permille % 10,
		("%.0f" % (float(n) / float(wins))) if wins > 0 else "inf"])

	print("\nENDING DISTRIBUTION:")
	for k in _sorted_keys(ending_hist):
		print("    %-18s %4d  (%d%%)" % [k, ending_hist[k], (int(ending_hist[k]) * 100) / n])

	print("\nDEATH CAR-TYPE (where the %d losses occurred):" % losses)
	for k in _sorted_keys(death_type_hist):
		if k == "WON":
			continue
		print("    %-12s %4d" % [k, death_type_hist[k]])

	print("\nDEATH BY TEMPLATE (loss cluster — captain keys annotated):")
	for k in _sorted_keys(death_template_hist):
		var ann := _annotate(k)
		print("    %4d x  %-30s %s" % [death_template_hist[k], k, ann])

	print("\nCAPTAINS BEATEN BEFORE RUN END (0..4; a win clears all 4):")
	for k in _sorted_keys(caps_cleared_hist):
		print("    %s captains: %4d runs" % [k, caps_cleared_hist[k]])

	print("\nDeepest car index any run reached: %d" % deepest)

	# ---- computed headline (data-driven, never an assumed cause) ----
	var cap_losses := int(death_type_hist.get("CAPTAIN", 0))
	var noncap_losses := losses - cap_losses
	var zero_caps := int(caps_cleared_hist.get("0", 0))
	var dl: int = losses if losses > 0 else 1
	print("\n--- BOTTOM LINE ---")
	print("Non-captain cars cause %d/%d losses (%d%%); captain gates %d/%d (%d%%)." % [
		noncap_losses, losses, (noncap_losses * 100) / dl,
		cap_losses, losses, (cap_losses * 100) / dl])
	print("%d/%d runs (%d%%) die having beaten ZERO captains — the cell often loses ordinary fights" % [
		zero_caps, n, (zero_caps * 100) / n])
	print("before any captain gate, so AI work should target standard-combat survival first, then keys.")
	print("Deadliest rooms:")
	for pair in _top_n_desc(death_template_hist, 4):
		print("    %4d losses  %-30s %s" % [pair[0], pair[1], _annotate(pair[1])])
	print("=== END TELEMETRY ===\n")
	quit(0)


func _drive(seed: int) -> RunController:
	var rc := RunController.new()
	rc.headless = true
	rc.db = ContentDB.new()
	rc.seed = seed
	rc.drive_full_run(seed, 3)
	return rc


# Last combat/captain car in the trace that was LOST or STALLED -> {type, template}.
# Falls back to FINALE / NONE when the run wiped in the finale or won.
func _death_car(trace: Array) -> Dictionary:
	var best := {"type": "WON", "template": ""}
	var saw_finale_loss := false
	for t in trace:
		var s := str(t)
		if s.begins_with("CAR ") and (s.find(": LOST") >= 0 or s.find(": STALLED") >= 0):
			best = {"type": _bracket_type(s), "template": _bracket_template(s)}
		if s.find("FINALE:") >= 0 and (s.find("ending=LOSS") >= 0 or s.find("core_sabotaged=false") >= 0):
			saw_finale_loss = true
		if s.begins_with("ENDING: LOSS") and best.type == "WON" and not saw_finale_loss:
			best = {"type": "LINE-WIPE", "template": ""}
	if best.type == "WON" and saw_finale_loss:
		return {"type": "FINALE", "template": "engine_conductor_vault"}
	return best


func _captains_won(trace: Array) -> int:
	var c := 0
	for t in trace:
		var s := str(t)
		if s.find("[CAPTAIN/") >= 0 and s.find(": WON") >= 0:
			c += 1
	return c


# "CAR 7 [CAPTAIN/captain_s3_head_gardener]: LOST (round 5)" -> "CAPTAIN"
func _bracket_type(s: String) -> String:
	var lb := s.find("[")
	var slash := s.find("/", lb)
	if lb < 0 or slash < 0:
		return "?"
	return s.substr(lb + 1, slash - lb - 1)


# ... -> "captain_s3_head_gardener"
func _bracket_template(s: String) -> String:
	var slash := s.find("/")
	var rb := s.find("]", slash)
	if slash < 0 or rb < 0:
		return "?"
	return s.substr(slash + 1, rb - slash - 1)


func _annotate(template: String) -> String:
	for sub in CAPTAIN_KEYS.keys():
		if template.findn(sub) >= 0:
			var pair = CAPTAIN_KEYS[sub]
			return "[%s — %s]" % [pair[0], pair[1]]
	return ""


func _top_n_desc(d: Dictionary, n: int) -> Array:
	var arr := []
	for k in d.keys():
		arr.append([int(d[k]), k])
	arr.sort()       # ascending by count
	arr.reverse()    # -> descending
	return arr.slice(0, n)


func _bump(d: Dictionary, k) -> void:
	d[k] = int(d.get(k, 0)) + 1


func _sorted_keys(d: Dictionary) -> Array:
	var keys := d.keys()
	keys.sort()
	return keys
