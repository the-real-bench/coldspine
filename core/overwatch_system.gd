class_name OverwatchSystem
## Overwatch / reaction shots (Phase 2). Deterministic, headless. The only RNG it
## touches is the to-hit roll inside the reaction Shoot (via state.rng) — same as any
## shot. RefCounted statics; ZERO SceneTree.
##
## Trigger rule: when a hostile unit ENTERS an armed overwatcher's line of fire
## (within weapon range AND with line of sight), the overwatcher takes ONE reaction
## shot through the normal Shoot path. One reaction per arming (overwatch_used), so a
## single overwatcher can't machine-gun a whole conga line. Multiple overwatchers
## react in entity_ids_sorted() order. The reaction also Suppresses the mover.

const E = preload("res://core/sim_enums.gd")
const GE = preload("res://core/game_event.gd")
const ShootCommand = preload("res://core/commands/shoot_command.gd")
const Status = preload("res://core/status_system.gd")


## Call after a unit `mover_id` finishes a move/action. Every armed overwatcher whose
## faction is hostile to the mover, that can now see+range the mover, fires once.
## Returns the ordered events from any reaction shots (possibly empty). Mutates state.
static func check_entry(state, mover_id: int) -> Array:
	var events: Array = []
	var mover = state.entities.get(mover_id)
	if mover == null or not mover.is_unit or not mover.alive:
		return events
	for wid in state.entity_ids_sorted():
		var w = state.entities.get(wid)
		if w == null or not w.is_unit or not w.alive:
			continue
		if not w.overwatch or w.overwatch_used:
			continue
		if w.faction == mover.faction:
			continue   # only watch hostiles
		# The mover must now be inside the watcher's fire lane.
		if not ShootCommand.has_range(w.pos, mover.pos):
			continue
		if not ShootCommand.in_los(state, w.pos, mover.pos):
			continue
		# Fire one reaction shot through the normal path (consumes overwatch).
		w.overwatch_used = true
		w.overwatch = false
		events.push_back(GE.new(E.Ev.OVERWATCH_TRIGGER, {"watcher": wid, "target": mover_id}))
		var sh := ShootCommand.new(wid, mover_id)
		var v: Dictionary = sh.validate(state, null)
		if v.ok:
			var evs: Array = sh.execute(state, null)
			for ev in evs:
				events.push_back(ev)
			# Overwatch / area fire pins the survivor (§5.5 Suppressed).
			var still = state.entities.get(mover_id)
			if still != null and still.alive:
				Status.apply_suppress(still, events)
	return events
