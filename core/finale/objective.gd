class_name FinaleObjective
extends RefCounted
## Sub-Spec B2 — the "Stop the Train" objective + the Bridge Countdown, as a deterministic,
## headless, integer-only state machine. RefCounted, ZERO SceneTree, NO rng (every timer
## and gate is purely deterministic — the whole finale is reproducible from (seed, inputs)).
##
## The win condition is the OBJECTIVE, not an HP bar:
##   disable all 3 Relays  -> Core shield drops  -> sabotage the Core to 0 -> WIN
##        OR kill/capture the Conductor -> shield drops immediately -> sabotage the Core -> WIN
## Squad wipe at any point = the only hard LOSS (TurnManager.check_victory handles that).
##
## This object OWNS the encounter-side bookkeeping (which it instantiates as engine-side
## SimEntities per §B7): the 3 Relays, 2 Robot Dispensers, the Engine Core, the Control Dais,
## and the Conductor. It exposes the queries the EngineVault / ConductorAI / Endings read:
##   core_shielded(), relays_online(), countdown, beat_clock(), conductor_alive().
##
## Core-shield rule (B7 recommended form): core_shielded = (online_relays > 0) and conductor_alive.
## So decapitation (kill/capture the Conductor) force-drops the shield even with Relays up.

const E = preload("res://core/sim_enums.gd")
const GE = preload("res://core/game_event.gd")
const SimEntity = preload("res://core/sim_entity.gd")

# --- the scripted objective entities (ids into state.entities) ---
var relay_ids: Array = []        # the 3 Relays (Anchored destructibles)
var dispenser_ids: Array = []    # the 2 Robot Dispensers (Anchored destructibles)
var core_id: int = -1            # the Engine Core (Anchored objective object)
var dais_id: int = -1            # the Control Dais (Anchored platform; the Conductor stands here)
var conductor_id: int = -1       # the Conductor (the finale boss SimEntity)

# --- the Bridge Countdown (B2.2) ---
var countdown: int = E.BRIDGE_COUNTDOWN_DEFAULT
var countdown_started: bool = false   # the clock only runs once the Conductor activates (Phase 2)
var countdown_expired: bool = false   # true once it hit 0 (good endings lock out, escalation begins)

# --- objective state ---
var core_sabotaged: bool = false      # the Core integrity reached 0 (the objective is met)
var conductor_killed: bool = false    # the Conductor was destroyed (decapitation)
var conductor_captured: bool = false  # the Conductor was captured, not killed (Seize path)
# relay power-id by relay index (B3.2): A->piston, B->plate, C->dispensers/deploy.
const RELAY_POWERS := [E.ConductorPower.RE_ROUTE_PISTON, E.ConductorPower.RE_ROUTE_PLATE, E.ConductorPower.DEPLOY]
var disabled_powers: Array = []       # ConductorPower ids the player has knocked out


# ============================ setup ===========================================
## Register the scripted objective entities this objective tracks. Call after the
## EngineVault has instantiated them into state. ids may be -1 (absent in a minimal test).
func bind(p_relays: Array, p_dispensers: Array, p_core: int, p_dais: int, p_conductor: int) -> void:
	relay_ids = p_relays.duplicate()
	dispenser_ids = p_dispensers.duplicate()
	core_id = p_core
	dais_id = p_dais
	conductor_id = p_conductor


# ============================ queries =========================================
## How many Relays are still online (alive in state). Deterministic; sorted-id agnostic.
func relays_online(state) -> int:
	var n: int = 0
	for rid in relay_ids:
		var r = state.entities.get(rid)
		if r != null and r.alive:
			n += 1
	return n


## Is the Conductor still alive (and not captured)? Decapitation force-drops the shield.
func conductor_alive(state) -> bool:
	if conductor_killed or conductor_captured:
		return false
	if conductor_id == -1:
		return false
	var c = state.entities.get(conductor_id)
	return c != null and c.alive


## The Core shield (B7): shielded iff a Relay is online AND the Conductor is alive.
## Killing/capturing the Conductor zeroes it even with Relays up.
func core_shielded(state) -> bool:
	return relays_online(state) > 0 and conductor_alive(state)


## Has the player beaten the Bridge Countdown (sabotaged the Core before it expired)?
## Used by Endings to gate the good endings (B6).
func beat_clock() -> bool:
	return not countdown_expired


# ============================ shield sync =====================================
## Re-evaluate the Core's shield + the Conductor's relay-shield against live state, and
## emit the shield events when they flip. Called by the EngineVault each environment phase
## (and after any relay/conductor change). Deterministic. Sets entity flags the damage-gate
## (CaptainSystem.can_take_damage) and the resolver's shove gate read.
func sync_shields(state, events: Array) -> void:
	var shielded: bool = core_shielded(state)
	# The Conductor's BODY is damage-shielded while the Core shield holds (B2.1: fragile but
	# protected by the Engine's systems). Drop it the instant the shield falls.
	var c = state.entities.get(conductor_id)
	if c != null:
		var was: bool = c.conductor_shielded
		c.conductor_shielded = shielded
		if was and not shielded:
			events.push_back(GE.new(E.Ev.CORE_SHIELD_DROP, {"conductor": conductor_id}))
		elif not was and shielded:
			events.push_back(GE.new(E.Ev.CORE_SHIELD, {"conductor": conductor_id}))
	# The Core object itself: its damage-gate is the relay count (independent of the
	# Conductor) — you cannot sabotage the Core while ANY relay is online, but once the
	# Conductor is dead the relays are bypassed (decapitation). We model that via a flag
	# the EngineVault checks in damage_core().


## Can the Core take sabotage damage right now? (All relays down, OR the Conductor is
## dead/captured.) This is the objective-side gate, separate from the Conductor's body.
func core_exposed(state) -> bool:
	if relays_online(state) == 0:
		return true
	# Decapitation bypasses the relays entirely.
	return not conductor_alive(state)


# ============================ mutations =======================================
## A Relay was destroyed (its integrity hit 0). Drops one shield stack and disables the
## mapped Conductor power (B3.2). Idempotent per-relay (a dead relay isn't re-counted).
## Returns the disabled power id (or -1 if the relay index isn't found).
func on_relay_destroyed(state, relay_id: int, events: Array) -> int:
	var idx: int = relay_ids.find(relay_id)
	if idx == -1:
		return -1
	var power: int = -1
	if idx < RELAY_POWERS.size():
		power = RELAY_POWERS[idx]
		if not disabled_powers.has(power):
			disabled_powers.append(power)
			events.push_back(GE.new(E.Ev.CONDUCTOR_POWER_DISABLED, {"relay": relay_id, "power": power}))
	events.push_back(GE.new(E.Ev.RELAY_DISABLED, {"relay": relay_id, "index": idx, "online_left": relays_online(state)}))
	sync_shields(state, events)
	return power


## The Conductor was killed (decapitation): force-drop every shield stack + disable all powers.
func on_conductor_killed(state, events: Array) -> void:
	conductor_killed = true
	for p in [E.ConductorPower.RE_ROUTE_PISTON, E.ConductorPower.RE_ROUTE_PLATE, E.ConductorPower.DEPLOY, E.ConductorPower.OVERCHARGE, E.ConductorPower.ACCELERATE]:
		if not disabled_powers.has(p):
			disabled_powers.append(p)
	sync_shields(state, events)


## The Conductor was captured rather than killed (the Seize-the-Engine choice, B6). Same
## shield consequence as a kill, but flagged distinctly so the ending diverges.
func on_conductor_captured(state, events: Array) -> void:
	conductor_captured = true
	var c = state.entities.get(conductor_id)
	if c != null:
		c.captured = true
	on_conductor_killed(state, events)   # shields fall the same way; the flag steers the ending


## Is the named Conductor power available (not disabled by a fallen relay / decapitation)?
func power_available(power: int) -> bool:
	return not disabled_powers.has(power)


# ============================ the Bridge Countdown ============================
## Start the clock (B2.3 Phase 2 — the Conductor activates). Idempotent.
func start_countdown(events: Array) -> void:
	if countdown_started:
		return
	countdown_started = true
	events.push_back(GE.new(E.Ev.COUNTDOWN_TICK, {"countdown": countdown, "started": true}))


## Advance the countdown by `steps` (1 per round, or via the Conductor's Accelerate). Emits a
## COUNTDOWN_TICK; at 0, emits COUNTDOWN_EXPIRED once (good endings lock, escalation begins).
func advance_countdown(events: Array, steps: int = 1) -> void:
	if not countdown_started or countdown_expired:
		return
	countdown = max(0, countdown - steps)
	events.push_back(GE.new(E.Ev.COUNTDOWN_TICK, {"countdown": countdown}))
	if countdown <= 0 and not countdown_expired:
		countdown_expired = true
		events.push_back(GE.new(E.Ev.COUNTDOWN_EXPIRED, {}))


# ============================ damaging the Core ===============================
## Apply `amount` integrity damage to the Core IF it is exposed (relays down / Conductor
## gone). A shielded Core shrugs it off (emit DAMAGE_SHIELDED). Sets core_sabotaged + emits
## CORE_SABOTAGED when the Core hits 0. Returns true if the Core was sabotaged this call.
## `physics_slam` damage (a robot/debris slammed into the Core) routes here too.
func damage_core(state, amount: int, events: Array) -> bool:
	var core = state.entities.get(core_id)
	if core == null or not core.alive or core_sabotaged:
		return false
	if not core_exposed(state):
		events.push_back(GE.new(E.Ev.DAMAGE_SHIELDED, {"target": core_id, "core": true}))
		return false
	core.integrity -= amount
	events.push_back(GE.new(E.Ev.CORE_DAMAGED, {"core": core_id, "dmg": amount, "integrity_left": core.integrity}))
	if core.integrity <= 0:
		core.alive = false
		core_sabotaged = true
		if state.in_bounds(core.pos) and state.tile(core.pos).occupant_id == core.id:
			state.tile(core.pos).occupant_id = -1
		events.push_back(GE.new(E.Ev.CORE_SABOTAGED, {"core": core_id, "beat_clock": beat_clock()}))
		return true
	return false


## The objective is met (the train is stopped) once the Core is sabotaged.
func is_objective_complete() -> bool:
	return core_sabotaged
