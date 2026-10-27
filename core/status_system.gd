class_name StatusSystem
## The §5.5 status set as a deterministic, headless, integer-only system.
## RefCounted statics only — ZERO SceneTree, NO rng (status is never random).
##
## Two entry points the rest of the sim uses:
##   - apply_*()        : helpers that set a status + its timer + emit a STATUS_APPLY
##   - tick_dots()      : per-environment-phase DoT + linger countdown (Burning, Poisoned)
##   - thaw_check()     : called when heat/fire reaches a Frozen unit (clears Frozen)
##
## Chilled→Frozen and the AP consequences of Stunned/Frozen live in TurnManager's
## AP refresh (they happen at the START of a faction's phase, not mid-environment).
## This file owns the COUNTDOWN/EXPIRY of every transient status and the DoT damage.

const E = preload("res://core/sim_enums.gd")
const GE = preload("res://core/game_event.gd")
const CaptainSystem = preload("res://core/captain_system.gd")


# ============================ APPLY HELPERS ====================================
# Each helper is idempotent on the bitflag and refreshes the backing timer. Burn /
# poison carry a linger so they persist after the unit leaves the tile/cloud.

static func apply_burning(e, events: Array) -> void:
	if e.temp_resist_timer > 0:
		return   # Rebreather Kit: timed burn immunity (progression-real batch)
	# Fire cancels Soaked (a burning unit is no longer wet) — §5.5 / D1.2.
	if e.has_status(E.S_SOAKED):
		e.clear_status(E.S_SOAKED)
		events.push_back(GE.new(E.Ev.STATUS_CLEAR, {"id": e.id, "status": E.S_SOAKED}))
	e.burn_timer = E.BURNING_LINGER + 1   # +1 so it still burns the turn it leaves the tile
	_set_status(e, E.S_BURNING, events)


static func apply_poison(e, events: Array) -> void:
	if e.poison_immune or e.temp_resist_timer > 0:
		return
	e.poison_timer = E.POISON_LINGER + 1
	_set_status(e, E.S_POISONED, events)


static func apply_chill(e, events: Array) -> void:
	if e.chill_immune:
		return   # Thermal Suit (gear-stamped)
	# Chilled stacks; reaching FROZEN_THRESHOLD freezes the unit (skip-turn until thawed).
	e.chill_stacks += 1
	_set_status(e, E.S_CHILLED, events)
	if e.chill_stacks >= E.FROZEN_THRESHOLD and not e.has_status(E.S_FROZEN):
		_set_status(e, E.S_FROZEN, events)
		events.push_back(GE.new(E.Ev.FREEZE, {"id": e.id}))


static func apply_blind(e, events: Array) -> void:
	e.blind_timer = 1   # a turn of blindness (§5.5)
	_set_status(e, E.S_BLINDED, events)


static func apply_suppress(e, events: Array) -> void:
	e.suppress_timer = 1
	_set_status(e, E.S_SUPPRESSED, events)
	events.push_back(GE.new(E.Ev.SUPPRESS, {"id": e.id}))


## Heat reaching a Frozen/Chilled unit thaws it (fire / steam / scald). Deterministic.
static func thaw(e, events: Array) -> void:
	var changed: bool = false
	if e.has_status(E.S_FROZEN):
		e.clear_status(E.S_FROZEN)
		events.push_back(GE.new(E.Ev.STATUS_CLEAR, {"id": e.id, "status": E.S_FROZEN}))
		changed = true
	if e.chill_stacks > 0:
		e.chill_stacks = 0
		changed = true
	if e.has_status(E.S_CHILLED):
		e.clear_status(E.S_CHILLED)
		events.push_back(GE.new(E.Ev.STATUS_CLEAR, {"id": e.id, "status": E.S_CHILLED}))
		changed = true
	if changed:
		events.push_back(GE.new(E.Ev.THAW, {"id": e.id}))


# ============================ DOT + EXPIRY TICK ================================
# Called once per ENVIRONMENT phase, in entity_ids_sorted() order. Applies Burning
# and Poisoned damage, then decrements every transient timer and clears expired
# statuses. The on-tile refresh (standing in fire/gas) happens in HazardSystem
# BEFORE this, so a unit still on a hazard keeps a full timer here.
static func tick_dots(state, events: Array) -> void:
	for id in state.entity_ids_sorted():
		var e = state.entities.get(id)
		if e == null or not e.is_unit or not e.alive:
			continue

		# Phase 6 damage-gate: a shielded unit (Conductor relay-shield / gated Captain) takes
		# no DoT damage, but its status timers still count down below so statuses expire
		# identically. Non-gated units are unaffected -> the 570 baseline is untouched.
		var shielded: bool = not CaptainSystem.can_take_damage(state, e)

		# Burning DoT.
		if e.burn_timer > 0 and not shielded:
			var bdmg: int = E.FIRE_DAMAGE
			if e.fireproof:
				bdmg = max(1, bdmg / 2)
			e.take_damage(bdmg)
			events.push_back(GE.new(E.Ev.BURN_TICK, {"id": id, "dmg": bdmg}))
			_check_death(state, e, events)
			if not e.alive:
				continue

		# Poison DoT (not instantly lethal — small, attritional).
		if e.poison_timer > 0 and not shielded:
			e.take_damage(E.POISON_DAMAGE)
			events.push_back(GE.new(E.Ev.POISON_TICK, {"id": id, "dmg": E.POISON_DAMAGE}))
			_check_death(state, e, events)
			if not e.alive:
				continue

		# Countdown + expiry (after the damage for this turn was applied).
		if e.burn_timer > 0:
			e.burn_timer -= 1
			if e.burn_timer <= 0 and e.has_status(E.S_BURNING):
				e.clear_status(E.S_BURNING)
				events.push_back(GE.new(E.Ev.STATUS_CLEAR, {"id": id, "status": E.S_BURNING}))
		if e.poison_timer > 0:
			e.poison_timer -= 1
			if e.poison_timer <= 0 and e.has_status(E.S_POISONED):
				e.clear_status(E.S_POISONED)
				events.push_back(GE.new(E.Ev.STATUS_CLEAR, {"id": id, "status": E.S_POISONED}))
		if e.blind_timer > 0:
			e.blind_timer -= 1
			if e.blind_timer <= 0 and e.has_status(E.S_BLINDED):
				e.clear_status(E.S_BLINDED)
				events.push_back(GE.new(E.Ev.STATUS_CLEAR, {"id": id, "status": E.S_BLINDED}))
		if e.suppress_timer > 0:
			e.suppress_timer -= 1
			if e.suppress_timer <= 0 and e.has_status(E.S_SUPPRESSED):
				e.clear_status(E.S_SUPPRESSED)
				events.push_back(GE.new(E.Ev.STATUS_CLEAR, {"id": id, "status": E.S_SUPPRESSED}))


# ------------------------------------------------------------------ internals --
static func _set_status(e, s: int, events: Array) -> void:
	if not e.has_status(s):
		e.add_status(s)
		events.push_back(GE.new(E.Ev.STATUS_APPLY, {"id": e.id, "status": s}))


const BleedoutSystem = preload("res://core/bleedout_system.gd")

static func _check_death(state, e, events: Array) -> void:
	# Phase 4: funnel DoT lethality through the bleed-out gate. With bleedout_enabled
	# false (default) this erases the unit and emits the identical UNIT_DOWNED+UNIT_DEATH
	# pair the pre-Phase-4 tests assert; with it on, the unit enters the revive window.
	if e.is_unit and e.alive and e.hp <= 0:
		BleedoutSystem.down_or_kill(state, e, events)
