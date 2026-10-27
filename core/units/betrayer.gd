class_name Betrayer
## The hidden betrayer mechanic (Conductor's Kin, Sub-Spec C3.5). A unit can secretly
## carry a hidden-loyalty trait that turns under a DEFINED condition. Three pieces:
##   - reveal()   : a Saboteur scan / vetting event exposes the hidden loyalty early,
##                  letting the player act before the beat fires (vetting = a resource).
##   - should_fire(): the defection CONDITION — an unrevealed Kin at a scripted beat.
##   - fire()     : the defection itself — the unit defects to the ENEMY faction (the
##                  cleanest mechanical realization of "sabotage or defect"), once.
##
## DENSITY (how many recruits are plants) is governed by E.BETRAYER_DENSITY_PCT in the
## recruitment roll — OWNER-FLAGGED, not tuned here. This file owns only the MECHANIC.
## Deterministic, integer, no rng (the condition is scripted, not random), no SceneTree.

const E = preload("res://core/sim_enums.gd")
const GE = preload("res://core/game_event.gd")


## Expose a unit's hidden loyalty (Saboteur scan / vetting). Returns true if it WAS a
## hidden betrayer (now revealed). A revealed Kin will NOT fire its beat — the player
## can bench/execute/vet them first.
static func reveal(entity, events: Array) -> bool:
	if entity == null or not entity.hidden_betrayer:
		return false
	if entity.betrayer_revealed:
		return false
	entity.betrayer_revealed = true
	return true


## The defection CONDITION (C3.5): the unit is a hidden, unrevealed, un-fired betrayer,
## still in play, and the scripted story beat has triggered. Pass `beat_active` from the
## run/event layer (e.g. a sabotaged-door beat, an alarm, a Section break).
static func should_fire(entity, beat_active: bool) -> bool:
	if entity == null or not entity.is_unit or not entity.alive:
		return false
	if not entity.hidden_betrayer:
		return false
	if entity.betrayer_revealed or entity.betrayed:
		return false
	return beat_active


## Fire the betrayal: the plant defects to the ENEMY faction (raising the alarm). Marks
## it fired (once per unit) and reveals the loyalty after the fact. Returns events.
static func fire(state, entity, events: Array) -> Array:
	var out: Array = []
	if not should_fire(entity, true):
		return out
	entity.betrayed = true
	entity.betrayer_revealed = true
	entity.faction = E.Faction.ENEMY            # defect — now hostile to the cell
	out.push_back(GE.new(E.Ev.BETRAYAL, {
		"id": entity.id, "name": entity.name, "action": "defect",
	}))
	# A defection is a loud breach: it raises the Order meter (§9), if the run threads it.
	if state != null and "order" in state:
		var OrderSystem = load("res://core/order_system.gd")
		OrderSystem.apply(state, "loud_breach", out)
	for ev in out:
		events.push_back(ev)
	return out


## Convenience: scan every unit in the squad for the beat and fire any that qualify.
## Stable entity_ids_sorted() order. Returns the combined events.
static func check_beat(state, beat_active: bool) -> Array:
	var events: Array = []
	if not beat_active:
		return events
	for id in state.entity_ids_sorted():
		var e = state.entities.get(id)
		if e == null:
			continue
		if should_fire(e, beat_active):
			fire(state, e, events)
	return events
