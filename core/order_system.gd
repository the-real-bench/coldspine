class_name OrderSystem
## The Order meter (GDD §9) — a run-wide integer gauge of the train's alarm/response.
## RAISED by killing civilians, loud breaches, and cruelty; LOWERED by mercy and clean
## fights. Crossing data-driven thresholds gates difficulty (tougher reinforcements,
## earlier lockdowns, elites sooner). Deterministic, integer, no rng, no SceneTree.
##
## Lives on the RunState (the meter is a run fact, not a per-combat one). Here it reads
## and writes `state.order` so a SimState used in a headless test can exercise it; a
## real run threads the same field through RunState.

const E = preload("res://core/sim_enums.gd")
const GE = preload("res://core/game_event.gd")

# Cause -> Order delta (positive raises, negative lowers). Data-driven thresholds below.
const CAUSE_DELTA := {
	"civilian_kill":  E.ORDER_CIVILIAN_KILL,
	"loud_breach":    E.ORDER_LOUD_BREACH,
	"cruelty":        E.ORDER_CRUELTY,        # executing / finishing a Downed enemy
	"mercy":         -E.ORDER_MERCY_DROP,
	"clean_fight":   -E.ORDER_CLEAN_FIGHT_DROP,
}

# Thresholds, ascending. Each is { at, tag } — crossing UP fires ORDER_THRESHOLD.
const THRESHOLDS := [
	{"at": E.ORDER_THRESHOLD_REINFORCE, "tag": "reinforce"},
	{"at": E.ORDER_THRESHOLD_LOCKDOWN,  "tag": "lockdown"},
	{"at": E.ORDER_THRESHOLD_ELITES,    "tag": "elites"},
]


## Apply a named cause to the meter on `state`. Returns the events: ORDER_CHANGE always,
## plus one ORDER_THRESHOLD per threshold newly crossed upward this change.
static func apply(state, cause: String, events: Array) -> int:
	var delta: int = int(CAUSE_DELTA.get(cause, 0))
	return adjust(state, delta, cause, events)


## Apply a raw delta (for content that doesn't map to a named cause). Clamped to
## [0, ORDER_MAX]. Emits ORDER_CHANGE and any newly-crossed thresholds.
static func adjust(state, delta: int, cause: String, events: Array) -> int:
	var before: int = state.order
	var after: int = clamp(before + delta, 0, E.ORDER_MAX)
	state.order = after
	events.push_back(GE.new(E.Ev.ORDER_CHANGE, {"cause": cause, "delta": after - before, "order": after}))
	if after > before:
		for th in THRESHOLDS:
			if before < th["at"] and after >= th["at"]:
				events.push_back(GE.new(E.Ev.ORDER_THRESHOLD, {"tag": th["tag"], "at": th["at"], "order": after}))
	return after


## The currently-active difficulty tags (every threshold the meter is at or above), in
## ascending order. The run/AI layer reads this to scale reinforcements/lockdowns/elites.
static func active_thresholds(state) -> Array:
	var out: Array = []
	for th in THRESHOLDS:
		if state.order >= th["at"]:
			out.append(th["tag"])
	return out


## Resolve a Bourgeois encounter (§9): spare for the long game vs kill for the grab.
## Returns a result dict the run layer acts on. Mutates state.order + emits events.
##   spare -> { reward: "gear|intel|buff", order_delta<0 }
##   kill  -> { resource: scrip/supplies grab, order_delta>0 }
static func resolve_bourgeois(state, spare: bool, events: Array) -> Dictionary:
	if spare:
		apply(state, "mercy", events)
		return {"action": "spare", "reward": "gear", "order": state.order}
	else:
		apply(state, "civilian_kill", events)
		return {"action": "kill", "resource": "scrip", "amount": 12, "order": state.order}
