class_name FinaleEndings
extends RefCounted
## Sub-Spec B6 — the ending selector. A PURE, deterministic function over the run facts:
##   resolve_ending(run_state) -> EndingId
## RefCounted statics, ZERO SceneTree, integer-only, NO rng. The same inputs always pick the
## same ending, so the moral economy is reproducible from (seed, input_log).
##
## The endings (B6), and the gate each one needs:
##   LOSS         — the squad wiped at any point (the only HARD failure). Highest precedence.
##   LIBERATION   — hidden / best: a fully-merciful run — low Order + the FULL surviving squad +
##                  enough citizens recruited across the run. The kindest path.
##   SEIZE_ENGINE — low Order + the Conductor was CAPTURED (not killed) + the squad survived.
##   HARD_STOP    — low Order + the Core was sabotaged BEFORE the countdown (the bleak win).
##   PYRRHIC      — high Order, OR the countdown was missed, OR heavy squad losses. You win,
##                  but gutted. The strongest play and the kindest play diverge (B6 / §9).
##
## Inputs are read off a small facts dict so the resolver is trivially unit-testable AND can
## be driven from a real RunState. build_facts() adapts a RunState/EngineVault into that dict.

const E = preload("res://core/sim_enums.gd")
const GE = preload("res://core/game_event.gd")


## The pure resolver. `facts` is a Dictionary with integer/bool fields:
##   order            (int)  — the run-wide Order meter (§9)
##   beat_clock       (bool) — sabotaged the Core before the Bridge Countdown expired
##   core_sabotaged   (bool) — the objective was met at all
##   squad_wiped      (bool) — the squad is fully dead (LOSS)
##   survivors        (int)  — living squad members at the finale's end
##   squad_size       (int)  — the squad's full size (for "full surviving squad")
##   losses           (int)  — squad members permanently dead this run
##   conductor_captured (bool) — the decapitation path chose capture over kill (Seize)
##   citizens_recruited (int) — sympathetic citizens recruited across the run (Liberation gate)
static func resolve_ending(facts: Dictionary) -> int:
	var order: int = int(facts.get("order", 0))
	var beat_clock: bool = bool(facts.get("beat_clock", false))
	var core_sabotaged: bool = bool(facts.get("core_sabotaged", false))
	var squad_wiped: bool = bool(facts.get("squad_wiped", false))
	var survivors: int = int(facts.get("survivors", 0))
	var squad_size: int = int(facts.get("squad_size", 0))
	var losses: int = int(facts.get("losses", 0))
	var captured: bool = bool(facts.get("conductor_captured", false))
	var recruits: int = int(facts.get("citizens_recruited", 0))

	# 1. Squad wipe — the only hard failure (highest precedence). Even if the Core somehow
	#    fell, a dead squad cannot claim a victory ending.
	if squad_wiped or survivors <= 0:
		return E.EndingId.LOSS

	# If the objective was never met, the only way to be here is a wipe (handled above);
	# defensively, a non-sabotage finish with survivors is still not a win — treat as LOSS.
	if not core_sabotaged:
		return E.EndingId.LOSS

	var low_order: bool = order <= E.ENDING_LOW_ORDER_MAX
	var full_squad: bool = squad_size > 0 and survivors >= squad_size
	var heavy_losses: bool = losses >= E.ENDING_PYRRHIC_LOSSES

	# 2. LIBERATION (hidden best): the fully-merciful run — low Order, the WHOLE squad alive,
	#    enough citizens freed across the run, and you beat the clock. The rarest outcome.
	if low_order and full_squad and not heavy_losses and beat_clock \
			and recruits >= E.ENDING_LIBERATION_RECRUITS:
		return E.EndingId.LIBERATION

	# 3. SEIZE THE ENGINE: low Order + captured the Conductor + survived + beat the clock.
	if low_order and captured and beat_clock and not heavy_losses:
		return E.EndingId.SEIZE_ENGINE

	# 4. HARD STOP: low Order + you beat the clock + light losses — the bleak, faithful win.
	if low_order and beat_clock and not heavy_losses:
		return E.EndingId.HARD_STOP

	# 5. PYRRHIC: everything else that still won — high Order, missed the clock, or gutted.
	return E.EndingId.PYRRHIC


## Resolve + emit the ENDING_RESOLVED event (so the renderer can surface the ending at the
## moment of sabotage, B6). Returns the EndingId.
static func resolve_and_emit(facts: Dictionary, events: Array) -> int:
	var ending: int = resolve_ending(facts)
	events.push_back(GE.new(E.Ev.ENDING_RESOLVED, {"ending": ending, "facts": facts.duplicate()}))
	return ending


## Adapt a RunState (+ optional finale facts) into the facts dict resolve_ending() reads.
## Squad survivorship/losses come off the RunState squad; the finale facts (beat_clock,
## core_sabotaged, conductor_captured) come off the FinaleObjective. `citizens_recruited`
## is counted from the run's input_log (RECRUIT_JOIN ops), defaulting to 0.
static func build_facts(run_state, beat_clock: bool, core_sabotaged: bool, conductor_captured: bool, squad_wiped: bool) -> Dictionary:
	var survivors: int = 0
	var losses: int = 0
	var squad_size: int = 0
	if run_state != null:
		for u in run_state.squad:
			if u == null:
				continue
			squad_size += 1
			if u.dead:
				losses += 1
			else:
				survivors += 1
	return {
		"order": (run_state.order if run_state != null else 0),
		"beat_clock": beat_clock,
		"core_sabotaged": core_sabotaged,
		"squad_wiped": squad_wiped,
		"survivors": survivors,
		"squad_size": squad_size,
		"losses": losses,
		"conductor_captured": conductor_captured,
		"citizens_recruited": _count_recruits(run_state),
	}


static func _count_recruits(run_state) -> int:
	if run_state == null:
		return 0
	var n: int = 0
	for entry in run_state.input_log:
		if typeof(entry) == TYPE_DICTIONARY and entry.get("op", "") == "recruit":
			n += 1
	return n
