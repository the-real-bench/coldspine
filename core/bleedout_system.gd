class_name BleedoutSystem
## Permadeath / bleed-out / revive / Memorial (Sub-Spec C §7.4) as a deterministic,
## headless, integer-only system. RefCounted statics — ZERO SceneTree, NO rng.
##
## The §7.4 rule, in one place:
##   - A unit at 0 HP becomes DOWNED (Bleeding) for BLEED_OUT_TURNS environment phases
##     (it stays in `state.entities`, alive=false so it can't act / be shot, but is NOT
##     erased — the revive window is open).
##   - A Steward or adjacent ally can STABILIZE within the window -> survives Downed.
##   - Unstabilized (timer hits 0) or FINISHED OFF -> permanent death: gear drops on the
##     tile (recoverable), the hero is enshrined in the Memorial (Legacy candidate), and
##     the body is removed from play.
##   - Total squad wipe = run over (TurnManager.check_victory distinguishes downed vs dead).
##
## Permadeath stays sacred: the Steward buys WINDOWS, not immortality (no resurrect).
##
## down_or_kill() is the single decision every death path funnels through. When
## state.bleedout_enabled is false it preserves the Phase 0-i "erase immediately"
## behavior exactly (so the 164 pre-Phase-4 tests are untouched).

const E = preload("res://core/sim_enums.gd")
const GE = preload("res://core/game_event.gd")


## The canonical "this unit just hit 0 HP" handler. Returns true if the unit was
## erased (truly gone this instant), false if it was put Downed (still in entities).
static func down_or_kill(state, e, events: Array, killer_id: int = -1, turn = null) -> bool:
	if e == null or not e.alive:
		return false
	# Objects never bleed out — they break/erase as before.
	if not e.is_unit:
		_erase(state, e, events)
		return true
	var was_enemy: bool = e.faction == E.Faction.ENEMY   # for the Inspire ally-kill funnel below
	# Decide whether THIS unit enters the bleed-out window or dies outright.
	var can_down: bool = state.bleedout_enabled
	if e.faction == E.Faction.ENEMY and not state.down_enemies_too:
		can_down = false
	if not can_down:
		_erase(state, e, events)
		if was_enemy:
			AbilitySystem.on_unit_died(state, e, killer_id, turn, events)   # Inspire (no-op w/o killer+turn)
		return true
	# Already Downed and hit 0 again = finished off -> permadeath (an enemy already inspired at down).
	if e.downed:
		permadeath(state, e, events)
		return true
	_enter_downed(state, e, events)
	if was_enemy:
		AbilitySystem.on_unit_died(state, e, killer_id, turn, events)   # a downed enemy is a cleared threat
	return false


## Put a unit into the Downed (Bleeding) state. It keeps its tile (a body to reach),
## cannot act (alive=false), and starts a bleed-out countdown.
static func _enter_downed(state, e, events: Array) -> void:
	e.alive = false
	e.downed = true
	e.dead = false
	e.hp = 0
	e.bleed_timer = E.BLEED_OUT_TURNS
	# Triage (Steward passive): a living squadmate carrying the triage field widens
	# every ally's bleed-out window by one env phase (progression-real batch).
	if e.faction == E.Faction.PLAYER:
		for id in state.entity_ids_sorted():
			var ally = state.entities.get(id)
			if ally != null and ally.is_unit and ally.alive and ally.id != e.id \
					and ally.faction == e.faction and ally.triage_field:
				e.bleed_timer += 1
				break
	e.add_status(E.S_DOWNED)
	e.add_status(E.S_BLEEDING)
	# It stays on its tile (occupant_id keeps pointing at it) so allies can reach it.
	events.push_back(GE.new(E.Ev.UNIT_DOWNED, {"id": e.id, "bleed": e.bleed_timer}))


## Stop the bleeding (Steward Stabilize / adjacent-ally aid). The unit survives Downed:
## still out of the fight this combat, but it will NOT die. (Healing it back above 0
## via Patch/revive is a separate, content-driven step.)
static func stabilize(state, e, events: Array) -> bool:
	if e == null or not e.downed or e.dead:
		return false
	e.bleed_timer = 0
	e.clear_status(E.S_BLEEDING)
	events.push_back(GE.new(E.Ev.UNIT_STABILIZED, {"id": e.id}))
	return true


## Confirm permanent death: drop gear on the tile, enshrine in the Memorial, remove body.
static func permadeath(state, e, events: Array) -> void:
	if e == null or e.dead:
		return
	var pos: Vector2i = e.pos
	e.alive = false
	e.downed = false
	e.dead = true
	e.clear_status(E.S_BLEEDING)
	# Gear drops on the last tile (a "reach the body" objective under fire, §7.4).
	if not e.gear.is_empty():
		var key := str(pos.x) + "," + str(pos.y)
		var existing: Array = state.gear_drops.get(key, [])
		for g in e.gear:
			existing.append(g)
		state.gear_drops[key] = existing
		if state.in_bounds(pos):
			state.tile(pos).status_layer |= E.L_DEBRIS   # a visible marker the renderer reads
		events.push_back(GE.new(E.Ev.GEAR_DROP, {"id": e.id, "pos": pos, "gear": e.gear.duplicate()}))
	# Enshrine as a Legacy candidate (the run's meta layer harvests this list). The fallen
	# unit's traits + carried inventory ride along so Legacy.enshrine/inherit can offer a REAL
	# item-or-trait legacy (§7.4) — not an empty one. Deterministic (duplicated arrays, no rng)
	# and backward-compatible (extra keys; existing memorial tests only read id/name).
	state.memorial.append({
		"id": e.id, "instance_id": e.instance_id, "name": e.name,
		"archetype": e.archetype_id,
		"traits": e.traits.duplicate(),
		"inventory": e.gear.duplicate(),
	})
	events.push_back(GE.new(E.Ev.MEMORIAL_ADD, {"id": e.id, "name": e.name}))
	events.push_back(GE.new(E.Ev.UNIT_PERMADEATH, {"id": e.id}))
	# Remove the body from play.
	if state.in_bounds(pos) and state.tile(pos).occupant_id == e.id:
		state.tile(pos).occupant_id = -1
	state.entities.erase(e.id)
	# Firebrand momentum (Sub-Spec C2.5): a PLAYER permadeath resets each surviving Firebrand's
	# stacks — UNLESS it picked Martyr's Wake (a burst instead). No-op when no Firebrand is present,
	# so the pre-momentum fixtures are byte-identical. (Called AFTER the erase so the dead one is gone.)
	if e.faction == E.Faction.PLAYER:
		AbilitySystem.on_ally_permadeath(state, e, events)


## Environment-phase tick: every Downed (Bleeding) unit loses a turn off its window;
## at 0 it permadies (unstabilized -> dead). Called from TurnManager's ENVIRONMENT step.
## Stable entity_ids_sorted() order. Returns the events it emitted.
static func tick(state) -> Array:
	var events: Array = []
	for id in state.entity_ids_sorted():
		var e = state.entities.get(id)
		if e == null or not e.is_unit or e.dead:
			continue
		# Steward Last Stand: a revived-defiant body (alive, no longer downed) spends its borrowed
		# time here and permadies when it runs out — after it has had its one action. Permadeath stays
		# sacred: the ally still dies (gear drop + Memorial), Last Stand only bought the final turn.
		if e.last_stand > 0:
			e.last_stand -= 1
			events.push_back(GE.new(E.Ev.BLEED_TICK, {"id": id, "left": e.last_stand, "last_stand": true}))
			if e.last_stand <= 0:
				permadeath(state, e, events)
			continue
		if not e.downed:
			continue
		# A STABILIZED unit is Downed but no longer Bleeding — it does not bleed out.
		if not e.has_status(E.S_BLEEDING):
			continue
		e.bleed_timer -= 1
		events.push_back(GE.new(E.Ev.BLEED_TICK, {"id": id, "left": e.bleed_timer}))
		if e.bleed_timer <= 0:
			permadeath(state, e, events)
	return events


# --- internals -----------------------------------------------------------------
static func _erase(state, e, events: Array) -> void:
	e.alive = false
	if state.in_bounds(e.pos) and state.tile(e.pos).occupant_id == e.id:
		state.tile(e.pos).occupant_id = -1
	state.entities.erase(e.id)
	events.push_back(GE.new(E.Ev.UNIT_DOWNED, {"id": e.id}))
	events.push_back(GE.new(E.Ev.UNIT_DEATH, {"id": e.id}))
