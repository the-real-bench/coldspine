class_name EngineVault
extends RefCounted
## Sub-Spec B1/B2 — the multi-phase Engine Vault arena controller. Owns the finale's
## encounter-side flow over a SimState: it INSTANTIATES the §B7 scripted objects (relays,
## dispensers, core, dais, the Conductor) as engine-side SimEntities, advances the arena
## PHASE (Antechamber -> Conductor Active -> Core Exposed), runs the Bridge Countdown, drives
## the ConductorAI cadence, and resolves the ending the instant the Core is sabotaged.
##
## RefCounted, ZERO SceneTree, integer-only, NO rng (the whole finale is deterministic — only
## gunfire ever touches the PRNG). Everything PHYSICAL (pistons, shoves into the Core, floods,
## the Soak-then-shove on the Conductor) reuses the Phase-1 resolver + Phase-2/5 hazards — this
## file adds bespoke OBJECTS + an arena state machine, NOT new physics (B7).
##
## Composition: a real encounter wires the vault to a TurnManager — call on_round_start() at
## the top of each player phase and run_conductor_phase() in the enemy phase. A headless test
## drives those directly. The relay/core/conductor destruction hooks are checked each tick.

const E = preload("res://core/sim_enums.gd")
const GE = preload("res://core/game_event.gd")
const SimEntity = preload("res://core/sim_entity.gd")
const FinaleObjective = preload("res://core/finale/objective.gd")
const FinaleEndings = preload("res://core/finale/endings.gd")
const ConductorAI = preload("res://ai/conductor_ai.gd")
const CaptainSystem = preload("res://core/captain_system.gd")

var state                              # SimState
var objective: FinaleObjective = null
var vault_phase: int = E.VaultPhase.ANTECHAMBER
var order: int = 0                     # the run-wide Order meter (steers escalation + endings)
var run_state = null                   # optional RunState (squad survivorship for the ending)
var ending: int = -1                   # the resolved EndingId once the Core falls (-1 = unresolved)
var _relays_seen_dead: Array = []      # relay ids already processed as destroyed (idempotent hooks)
var _escalations: int = 0              # how many post-countdown escalations have fired


func _init(p_state = null, p_order: int = 0, p_run_state = null) -> void:
	state = p_state
	order = p_order
	run_state = p_run_state
	objective = FinaleObjective.new()


# ============================ build the arena (B7) ============================
## Instantiate the scripted objective objects into `state` at the given positions and bind
## the objective to them. Anchored + destructible per the spec. `relay_pos` is 3 tiles,
## `dispenser_pos` is 2, plus the core/dais/conductor tiles. Returns nothing; reads via
## `objective`. The cycling hazards (pistons/plates/steam) are authored by the caller onto
## the grid (set_piston_lane / set_plate / set_steam below) — this file just adds the OBJECTS.
func build(relay_pos: Array, dispenser_pos: Array, core_pos: Vector2i, dais_pos: Vector2i, conductor_pos: Vector2i) -> void:
	var relay_ids: Array = []
	for rp in relay_pos:
		relay_ids.append(_add_anchored_object(rp, E.RELAY_INTEGRITY_DEFAULT, E.OBJ_RELAY).id)
	var disp_ids: Array = []
	for dp in dispenser_pos:
		disp_ids.append(_add_anchored_object(dp, E.DISPENSER_INTEGRITY_DEFAULT, E.OBJ_ROBOT_DISPENSER).id)
	var core := _add_anchored_object(core_pos, E.CORE_INTEGRITY_DEFAULT, E.OBJ_ENGINE_CORE)
	var dais := _add_anchored_object(dais_pos, 999, E.OBJ_CONTROL_DAIS)   # the dais is structure, not a kill target
	# NOTE: the Conductor stands ON the dais (B4), and SimState.add_entity blindly overwrites
	# tile.occupant_id — so the dais entity is SHADOWED by whoever occupies its tile and is
	# invisible to occupant_at() while anything stands there. Everything here finds the dais by
	# entity id (objective.dais_id), never via tile occupancy; keep it that way.
	var conductor := _add_conductor(conductor_pos)
	objective.bind(relay_ids, disp_ids, core.id, dais.id, conductor.id)
	# Phase 1 opens shielded: relays online + Conductor alive -> the Conductor's body is immune.
	var events: Array = []
	objective.sync_shields(state, events)


## Add an Anchored destructible objective object (integrity-based, immovable). `tag` is the
## §B7 role string carried on `name` so the objective/vault can find it.
func _add_anchored_object(p: Vector2i, integrity: int, tag: String) -> SimEntity:
	var o := SimEntity.new()
	o.is_unit = false
	o.pos = p
	o.mass = E.Mass.ANCHORED
	o.movable = false
	o.integrity = integrity
	o.hp = -1
	o.faction = E.Faction.OBJECT
	o.name = tag
	state.add_entity(o)
	return o


## Add the Conductor: a fragile (light) unit, the finale boss. Reuses the Section-Captain
## soak shove-gate (so the Soak-then-shove decapitation works, B4) AND carries the relay
## damage-shield (`conductor_shielded`, set by the objective). aiProfile is irrelevant — the
## ConductorAI pattern controller drives it, not the standard EnemyAI.
func _add_conductor(p: Vector2i) -> SimEntity:
	var c := SimEntity.new()
	c.is_unit = true
	c.pos = p
	c.mass = E.Mass.LIGHT
	c.hp = 14
	c.integrity = -1
	c.faction = E.Faction.ENEMY
	c.name = "the_conductor"
	c.is_finale_boss = true
	# W2-7: the ConductorAI pattern controller drives this body (run_conductor_phase) — NOT the
	# generic EnemyAI. But the body defaults to ai_profile MELEE_RUSH and EnemyAI.take_phase iterates
	# EVERY alive ENEMY unit with no finale-boss guard, so without this the shielded, damage-immune
	# Conductor was ALSO driven as a generic melee chaser (it abandoned the dais and shoved/slammed
	# the squad every enemy phase). `unaware` is the one lever EnemyAI/AIProfiles honor as "do not
	# act" (ai_profiles.gd), so the body holds the dais and acts ONLY through its telegraphed cadence.
	# Re-asserted every enemy phase in run_conductor_phase() so it survives any ambush-wake logic.
	c.unaware = true
	# The capstone shove-gate (B4): unshovable until Soaked — flood the dais to shove it.
	CaptainSystem.setup(c, "flood_the_dais_then_shove_into_a_hazard")
	state.add_entity(c)
	return c


# ============================ arena phase flow ===============================
## Transition into Phase 2 (Conductor Active): full ability kit online + the Bridge Countdown
## starts + dispensers begin producing (B2.3). Triggered by crossing into the inner vault OR
## destroying Relay 1. Idempotent.
func activate_conductor(events: Array) -> void:
	if vault_phase != E.VaultPhase.ANTECHAMBER:
		return
	vault_phase = E.VaultPhase.CONDUCTOR_ACTIVE
	objective.start_countdown(events)
	events.push_back(GE.new(E.Ev.VAULT_PHASE, {"phase": vault_phase}))


## B2.3 antechamber trigger — is the DORMANT phase's arming condition met yet? The Conductor stays
## inactive (no Bridge Countdown, no cadence) in the antechamber until the squad either (a) crosses
## the inner-vault divider (a living PLAYER unit at/past `divider_x`) or (b) has knocked down the
## first relay or antechamber turret (any objective relay dead, or fewer live enemies than at entry).
## Returns true once the caller should activate_conductor(). Pure read, integer-only, deterministic.
## `enemies_at_entry` is the live scripted-defender count when the vault was entered (turrets/chief/
## robot); a drop means the squad has started clearing the antechamber (the "first turret down" beat).
func antechamber_trigger_met(divider_x: int, enemies_at_entry: int = -1) -> bool:
	if vault_phase != E.VaultPhase.ANTECHAMBER:
		return true   # already active — nothing left to arm
	# (a) a living player unit has crossed the divider into the inner vault.
	for id in state.entity_ids_sorted():
		var e = state.entities.get(id)
		if e != null and e.is_unit and e.alive and e.faction == E.Faction.PLAYER and e.pos.x >= divider_x:
			return true
	# (b) the first relay has fallen (a relay-kill beat).
	if objective.relays_online(state) < objective.relay_ids.size():
		return true
	# (c) an antechamber defender (turret/elite) has gone down since entry.
	if enemies_at_entry >= 0 and _live_enemy_count(state) < enemies_at_entry:
		return true
	return false


## Live (alive) ENEMY unit count in the arena — the antechamber-defender headcount the trigger reads.
func _live_enemy_count(s) -> int:
	var n: int = 0
	for id in s.entity_ids_sorted():
		var e = s.entities.get(id)
		if e != null and e.is_unit and e.alive and e.faction == E.Faction.ENEMY:
			n += 1
	return n


## Recompute the arena phase from the objective state. Once the Core is exposed (all relays
## down OR the Conductor dead/captured) we enter Phase 3 (Core Exposed / Lockdown). Emits
## VAULT_PHASE on a transition. Call after any relay/conductor change.
func update_phase(events: Array) -> void:
	if vault_phase == E.VaultPhase.ANTECHAMBER:
		return   # Phase 1 only leaves via activate_conductor()
	if vault_phase == E.VaultPhase.CONDUCTOR_ACTIVE and objective.core_exposed(state):
		vault_phase = E.VaultPhase.CORE_EXPOSED
		events.push_back(GE.new(E.Ev.VAULT_PHASE, {"phase": vault_phase}))


# ============================ per-round driving ==============================
## Call at the top of each round (player phase). Scans for relay/core destruction the player
## caused last round, advances the Bridge Countdown, fires post-countdown escalations, and
## re-syncs shields/phase. Returns the events. Deterministic.
func on_round_start(events: Array) -> void:
	_scan_destruction(events)
	# Advance the Bridge Countdown one round (only once the Conductor is active).
	if vault_phase != E.VaultPhase.ANTECHAMBER and not objective.countdown_expired:
		objective.advance_countdown(events, 1)
	# Post-countdown escalation (B2.2): each round past 0 adds an escalating hazard.
	if objective.countdown_expired and not objective.is_objective_complete():
		_escalate(events)
	objective.sync_shields(state, events)
	update_phase(events)


## Run the Conductor's enemy-phase cadence (telegraph/resolve), if its body is active. Then
## re-scan for any destruction the resolution caused and re-sync. Returns the events.
func run_conductor_phase(events: Array) -> void:
	if vault_phase == E.VaultPhase.ANTECHAMBER:
		return   # the Conductor is dormant in the antechamber (B2.3)
	# W2-7: keep the boss inert to the generic EnemyAI (it is pattern-driven only). Re-assert each
	# enemy phase — the generic ai.take_phase(turn) runs right after this call in the finale loop, so
	# even if some ambush-wake cleared it during the player/env phase, the Conductor never chases.
	var c = state.entities.get(objective.conductor_id)
	if c != null and c.alive:
		c.unaware = true
	ConductorAI.take_phase(state, objective, vault_phase, order, events)
	_scan_destruction(events)
	objective.sync_shields(state, events)
	update_phase(events)


# ============================ destruction hooks ==============================
## Detect relays / the core / the conductor that died since the last scan, fire the matching
## objective hooks (drop shield stacks, disable powers, resolve the ending). Idempotent.
func _scan_destruction(events: Array) -> void:
	# Relays: an integrity-0 relay was erased by the resolver -> fire on_relay_destroyed once.
	for rid in objective.relay_ids:
		if _relays_seen_dead.has(rid):
			continue
		var r = state.entities.get(rid)
		if r == null or not r.alive:
			_relays_seen_dead.append(rid)
			objective.on_relay_destroyed(state, rid, events)
			update_phase(events)
	# Dispensers: emit DISPENSER_DOWN once each (their spawns just stop — the ConductorAI
	# skips dead dispensers, so no further wiring is needed).
	for did in objective.dispenser_ids:
		var d = state.entities.get(did)
		if d == null or not d.alive:
			# (no per-id dedupe needed: the event is informational; ConductorAI reads liveness)
			pass
	# The Conductor: if its body was killed in combat, fire the decapitation hook.
	if not objective.conductor_killed and not objective.conductor_captured:
		var c = state.entities.get(objective.conductor_id)
		if (c == null or not c.alive) and objective.conductor_id != -1:
			objective.on_conductor_killed(state, events)
			update_phase(events)
	# The Core: if it was sabotaged (by a physics slam routed through damage_core, or its
	# integrity erased), resolve the ending.
	if objective.is_objective_complete() and ending == -1:
		_resolve_ending(events)


# ============================ winning the objective ==========================
## Apply sabotage damage to the Core (a Saboteur charge, or a physics slam's integrity hit).
## Routes through the objective's exposure gate; resolves the ending if the Core falls.
func sabotage_core(amount: int, events: Array) -> bool:
	var done: bool = objective.damage_core(state, amount, events)
	if done:
		_resolve_ending(events)
	return done


## The player chose to CAPTURE the Conductor rather than kill it (the Seize-the-Engine path,
## B6). Drops the shields like a kill but flags the ending divergence.
func capture_conductor(events: Array) -> void:
	objective.on_conductor_captured(state, events)
	update_phase(events)


## Resolve + record the ending at the moment of sabotage (B6: shown to the player then).
func _resolve_ending(events: Array) -> void:
	if ending != -1:
		return
	var wiped: bool = _squad_wiped()
	var facts: Dictionary = FinaleEndings.build_facts(
		run_state, objective.beat_clock(), objective.is_objective_complete(),
		objective.conductor_captured, wiped)
	# When there's no RunState (a minimal headless test), fall back to live SimState survivors.
	if run_state == null:
		facts = _live_facts(wiped)
	ending = FinaleEndings.resolve_and_emit(facts, events)


# ============================ post-countdown escalation ======================
## Each round past the expired countdown adds an escalating hazard (B2.2): we speed up every
## cycling trap and arm one more dormant bank, to stop the player stalling forever. Bounded.
func _escalate(events: Array) -> void:
	_escalations += 1
	# Speed up cycling traps (shorter period = fires more often), floor at 1.
	for y in range(state.height):
		for x in range(state.width):
			var t = state.grid[y][x]
			if t.trap_period > 1 and _is_cycling(t.hazard):
				t.trap_period = max(1, t.trap_period - 1)
			# Arm one dormant bank per escalation (the "extra piston bank").
			if not t.trap_active and t.trap_period > 0 and _is_cycling(t.hazard):
				t.trap_active = true
	events.push_back(GE.new(E.Ev.VAULT_ESCALATE, {"level": _escalations}))


# ============================ helpers ==========================================
func _squad_wiped() -> bool:
	# A wipe = no living PLAYER unit remains in the encounter (downed-not-dead still counts as
	# in the fight, mirroring TurnManager.check_victory's distinction).
	for id in state.entity_ids_sorted():
		var e = state.entities.get(id)
		if e == null or not e.is_unit:
			continue
		if e.faction == E.Faction.PLAYER and (e.alive or (e.downed and not e.dead)):
			return false
	return true


## Live-state ending facts when no RunState is bound (headless objective tests).
func _live_facts(wiped: bool) -> Dictionary:
	var survivors: int = 0
	var squad_size: int = 0
	for id in state.entity_ids_sorted():
		var e = state.entities.get(id)
		if e == null or not e.is_unit or e.faction != E.Faction.PLAYER:
			continue
		squad_size += 1
		if e.alive or (e.downed and not e.dead):
			survivors += 1
	return {
		"order": order, "beat_clock": objective.beat_clock(),
		"core_sabotaged": objective.is_objective_complete(), "squad_wiped": wiped,
		"survivors": survivors, "squad_size": squad_size, "losses": squad_size - survivors,
		"conductor_captured": objective.conductor_captured, "citizens_recruited": 0,
	}


static func _is_cycling(hz: int) -> bool:
	return hz == E.Hazard.VENT or hz == E.Hazard.LASER or hz == E.Hazard.PLATE \
		or hz == E.Hazard.PISTON or hz == E.Hazard.STEAM \
		or hz == E.Hazard.LASER_SWEEP or hz == E.Hazard.CONVEYOR
