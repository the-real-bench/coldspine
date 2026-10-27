class_name ConductorAI
extends RefCounted
## Sub-Spec B3 — the Conductor's AIPatternController. A deterministic, telegraphed
## ability cadence: each Conductor phase it RESOLVES last turn's telegraphed action,
## then SCORES + TELEGRAPHS the next one (so the player always gets one turn of warning,
## B3.3). RefCounted statics, ZERO SceneTree, integer-only, NO rng (the cadence is purely
## deterministic; only a Shoot it might issue ever touches the PRNG — it issues none).
##
## The kit (B3.1), each gated by the relay->power map (B3.2 — a fallen relay disables its
## mapped power, so the player's relay-kill ORDER shapes the fight):
##   RE_ROUTE   — toggle a hazard bank (arm a piston lane / electrify a plate cluster).
##   DEPLOY     — every online Dispenser emits a Security Robot.
##   OVERCHARGE — a Core-system strike on the most-exposed / lowest-HP player unit.
##   ACCELERATE — advance the Bridge Countdown by 1 (trades pressure for a wasted turn).
##   LOCKDOWN   — the Phase-3 enrage (Core exposed): faster cycles + double Deploy.
##
## Escalation: scoring shifts with the countdown (low clock -> favor ACCELERATE/OVERCHARGE)
## and with Order (high Order -> deploy/overcharge sooner, §9). In the CORE_EXPOSED phase the
## Conductor is in Lockdown and resolves a doubled cadence.

const E = preload("res://core/sim_enums.gd")
const GE = preload("res://core/game_event.gd")
const SimEntity = preload("res://core/sim_entity.gd")

# Stable orthogonal step order (matches the resolver/EnemyAI DIRS4).
const DIRS4 := [Vector2i(0, -1), Vector2i(1, 0), Vector2i(0, 1), Vector2i(-1, 0)]


## Run ONE Conductor phase against (state, objective, vault_phase, order). Resolves the
## telegraphed action from last phase, then scores + telegraphs the next. Returns the events.
## `order` is the run-wide Order meter (steers escalation). The Conductor only acts once its
## body is active (Phase 2+) — the EngineVault gates that and calls this in the enemy phase.
static func take_phase(state, objective, vault_phase: int, order: int, events: Array) -> void:
	var c = state.entities.get(objective.conductor_id)
	if c == null or not c.alive:
		return

	# In Lockdown (Phase 3 / Core exposed) the Conductor resolves a DOUBLED cadence.
	var resolves: int = 2 if vault_phase == E.VaultPhase.CORE_EXPOSED else 1

	for _i in range(resolves):
		# 1. Resolve last phase's telegraphed action (if any).
		if c.pending_action != E.ConductorAction.NONE:
			_resolve_action(state, objective, c, c.pending_action, order, events)
			c.pending_action = E.ConductorAction.NONE
		# A doubled cadence in Lockdown also gets to immediately re-pick once.

	# 2. Score + telegraph the NEXT action (shown to the player one turn ahead, B3.3).
	var next_action: int = _choose_action(state, objective, c, vault_phase, order)
	c.pending_action = next_action
	if next_action != E.ConductorAction.NONE:
		events.push_back(GE.new(E.Ev.CONDUCTOR_TELEGRAPH, {"conductor": c.id, "action": next_action}))


# ============================ utility scoring =================================
## The most robots the Conductor keeps on the field before it stops DEPLOYing (adds cap).
const ROBOT_CAP := 2

## Pick the next telegraphed action (B3.3). W4-8: the pre-fix scorer collapsed to OVERCHARGE/DEPLOY
## — RE_ROUTE needed a player literally standing ON a piston/plate tile and ACCELERATE only fired when
## nothing else scored, so neither showed across a real finale. This scores from a DETERMINISTIC
## CADENCE that advances every Conductor phase, rotating a 4-beat pattern over the AVAILABLE authored
## actions so the boss reads as a rhythm (deploy adds -> re-route a bank -> strike -> press the clock)
## rather than one-note pressure. Two readable spikes break the rhythm on purpose: Lockdown/high-Order
## front-loads OVERCHARGE (the enrage), and a low clock front-loads ACCELERATE (slam the door). No RNG,
## no new entity state — every input is integer sim state that changes over the fight (reproducible).
static func _choose_action(state, objective, c, vault_phase: int, order: int) -> int:
	var lockdown: bool = vault_phase == E.VaultPhase.CORE_EXPOSED
	var high_order: bool = order >= E.ORDER_THRESHOLD_LOCKDOWN
	var clock_running: bool = objective.countdown_started and not objective.countdown_expired
	var clock_low: bool = clock_running and objective.countdown <= (E.BRIDGE_COUNTDOWN_DEFAULT / 2)

	# What each authored action can do THIS phase (each has a real, reachable trigger).
	var can_overcharge: bool = _most_exposed_player(state) != null and objective.power_available(E.ConductorPower.OVERCHARGE)
	var can_deploy: bool = objective.power_available(E.ConductorPower.DEPLOY) \
		and _dispensers_online(state, objective) > 0 and _robots_on_field(state) < ROBOT_CAP
	var can_reroute: bool = (objective.power_available(E.ConductorPower.RE_ROUTE_PISTON) \
		or objective.power_available(E.ConductorPower.RE_ROUTE_PLATE)) and _has_reroutable_lane(state, objective)
	var can_accel: bool = clock_running and objective.power_available(E.ConductorPower.ACCELERATE)

	# A deterministic cadence that ADVANCES every phase (the countdown ticks down each round while it
	# runs; each relay killed adds one) — no RNG, no new entity field. It rotates the pattern below.
	var beat: int = _cadence(objective)

	# --- READABLE SPIKES (the two moments the rhythm breaks on purpose) ---
	# Phase-3 Lockdown / high Order: OVERCHARGE dominates, but only every OTHER beat so DEPLOY and
	# RE_ROUTE still surface between strikes (the enrage reads, without collapsing to one action).
	if (lockdown or high_order) and can_overcharge and (beat % 2 == 0):
		return E.ConductorAction.OVERCHARGE
	# Clock nearly out: ACCELERATE to slam the door (trades a strike for pressure) on the off-beat.
	if clock_low and can_accel and (beat % 2 == 1):
		return E.ConductorAction.ACCELERATE

	# --- BASE ROTATION: a 4-beat cycle; take the first AVAILABLE action from the rotated order so
	# each phase prefers a different verb and, across a finale, all four authored actions fire. ---
	var rotation := [E.ConductorAction.DEPLOY, E.ConductorAction.RE_ROUTE, E.ConductorAction.OVERCHARGE, E.ConductorAction.ACCELERATE]
	var avail := {
		E.ConductorAction.DEPLOY: can_deploy,
		E.ConductorAction.RE_ROUTE: can_reroute,
		E.ConductorAction.OVERCHARGE: can_overcharge,
		E.ConductorAction.ACCELERATE: can_accel,
	}
	for i in range(rotation.size()):
		var act: int = rotation[(beat + i) % rotation.size()]
		if avail[act]:
			return act
	return E.ConductorAction.NONE


## A deterministic per-phase cadence index. Advances each Conductor phase from integer sim state that
## changes over the fight — the elapsed Bridge Countdown (ticks once per round while running) plus the
## number of Conductor powers the player has knocked out (each relay kill). No RNG, no wall-clock, no
## new entity field: the same (seed, inputs) always yield the same cadence, so the pattern reproduces.
static func _cadence(objective) -> int:
	var elapsed: int = E.BRIDGE_COUNTDOWN_DEFAULT - objective.countdown
	return elapsed + objective.disabled_powers.size()


# ============================ action resolution ===============================
static func _resolve_action(state, objective, c, action: int, _order: int, events: Array) -> void:
	events.push_back(GE.new(E.Ev.CONDUCTOR_ACT, {"conductor": c.id, "action": action}))
	match action:
		E.ConductorAction.RE_ROUTE:
			_do_re_route(state, objective, events)
		E.ConductorAction.DEPLOY:
			_do_deploy(state, objective, events)
		E.ConductorAction.OVERCHARGE:
			_do_overcharge(state, objective, c, events)
		E.ConductorAction.ACCELERATE:
			objective.advance_countdown(events, E.ACCELERATE_STEP)
		_:
			pass


## Re-Route: throw more power into the hazard bank the relay-map still allows. Prefer ARMING a
## dormant cycling-trap tile (flip it on so HazardSystem telegraphs + fires it); if every controlled
## bank is already live, RE-ROUTE speeds one up instead (shorter period = fires more often), floor 1.
## Either way it is a real, telegraphed effect (no bespoke physics) — so RE_ROUTE is never a dead
## verb in the authored finale, whose piston/plate banks load already-active (setpiece_loader).
static func _do_re_route(state, objective, events: Array) -> void:
	var want_piston: bool = objective.power_available(E.ConductorPower.RE_ROUTE_PISTON)
	var want_plate: bool = objective.power_available(E.ConductorPower.RE_ROUTE_PLATE)
	# 1) Prefer arming a DORMANT controlled bank (flip it on).
	for y in range(state.height):
		for x in range(state.width):
			var t = state.grid[y][x]
			if t.trap_period <= 0 or t.trap_active:
				continue
			if (want_piston and t.hazard == E.Hazard.PISTON) or (want_plate and t.hazard == E.Hazard.PLATE):
				t.trap_active = true
				return
	# 2) All controlled banks live -> re-route MORE power into one: speed it up (floor at period 1).
	for y in range(state.height):
		for x in range(state.width):
			var t = state.grid[y][x]
			if not t.trap_active or t.trap_period <= 1:
				continue
			if (want_piston and t.hazard == E.Hazard.PISTON) or (want_plate and t.hazard == E.Hazard.PLATE):
				t.trap_period = max(1, t.trap_period - 1)
				return


## Deploy: every ONLINE Dispenser emits a Security Robot on its first open orthogonal tile.
static func _do_deploy(state, objective, events: Array) -> void:
	for did in objective.dispenser_ids:
		var disp = state.entities.get(did)
		if disp == null or not disp.alive:
			continue
		_spawn_robot_at(state, disp.pos, events, did)


## Overcharge: a Core-system strike on the most-exposed (lowest-HP) player unit. Routes
## through the damage path so its own shields/guardian apply (it's plain unit damage).
static func _do_overcharge(state, objective, c, events: Array) -> void:
	var victim = _most_exposed_player(state)
	if victim == null:
		return
	victim.take_damage(E.OVERCHARGE_DAMAGE)
	events.push_back(GE.new(E.Ev.HIT, {"actor": c.id, "target": victim.id, "dmg": E.OVERCHARGE_DAMAGE, "hp_left": victim.hp, "overcharge": true}))
	if victim.is_unit and victim.hp <= 0:
		_down(state, victim, events)


# ============================ helpers ==========================================
## The lowest-HP living player unit (the most-exposed target). Ties -> lowest id (stable).
static func _most_exposed_player(state):
	var best = null
	var best_hp: int = 1 << 30
	for id in state.entity_ids_sorted():
		var p = state.entities.get(id)
		if p == null or not p.is_unit or not p.alive or p.faction != E.Faction.PLAYER:
			continue
		if p.hp < best_hp:
			best_hp = p.hp
			best = p
	return best


static func _dispensers_online(state, objective) -> int:
	var n: int = 0
	for did in objective.dispenser_ids:
		var d = state.entities.get(did)
		if d != null and d.alive:
			n += 1
	return n


## Count Security Robots on the field (units named like a spawned robot, enemy faction).
static func _robots_on_field(state) -> int:
	var n: int = 0
	for id in state.entity_ids_sorted():
		var e = state.entities.get(id)
		if e == null or not e.is_unit or not e.alive or e.faction != E.Faction.ENEMY:
			continue
		if e.name == "security_robot" or e.name == "deployed_bot":
			n += 1
	return n


## Is there a piston/plate bank the Conductor could RE_ROUTE this phase — a DORMANT controlled tile to
## arm, OR a live one still faster-than-floor to speed up? Mirrors _do_re_route so RE_ROUTE only scores
## when it has a real effect to deliver (the authored banks load live, so the speed-up branch is what
## keeps the verb alive in the real finale; a scripted test with dormant banks exercises the arm branch).
static func _has_reroutable_lane(state, objective) -> bool:
	var want_piston: bool = objective.power_available(E.ConductorPower.RE_ROUTE_PISTON)
	var want_plate: bool = objective.power_available(E.ConductorPower.RE_ROUTE_PLATE)
	if not want_piston and not want_plate:
		return false
	for y in range(state.height):
		for x in range(state.width):
			var t = state.grid[y][x]
			if t.trap_period <= 0:
				continue
			var controlled: bool = (want_piston and t.hazard == E.Hazard.PISTON) or (want_plate and t.hazard == E.Hazard.PLATE)
			if not controlled:
				continue
			if not t.trap_active or t.trap_period > 1:   # a dormant bank to arm, or a live one to speed up
				return true
	return false


## Spawn a Security Robot at the first open orthogonal tile around `origin` (a Dispenser).
static func _spawn_robot_at(state, origin: Vector2i, events: Array, dispenser_id: int) -> bool:
	for d in DIRS4:
		var np: Vector2i = origin + d
		if not state.in_bounds(np):
			continue
		var t = state.tile(np)
		if t.terrain == E.Terrain.WALL or state.occupant_at(np) != null or t.hazard == E.Hazard.GAP:
			continue
		var bot := SimEntity.new()
		bot.is_unit = true
		bot.pos = np
		bot.mass = E.Mass.HEAVY            # a heavy ram-bot: shove it into a piston for the combo (B5.1)
		bot.hp = E.ROBOT_SPAWN_HP
		bot.integrity = E.ROBOT_SPAWN_INTEGRITY
		bot.faction = E.Faction.ENEMY
		bot.name = "security_robot"
		bot.ai_profile = E.AIProfile.ROBOT
		bot.phys_trait = E.PhysTrait.HACKABLE   # the Saboteur can convert it (§12)
		state.add_entity(bot)
		events.push_back(GE.new(E.Ev.DISPENSER_SPAWN, {"dispenser": dispenser_id, "bot": bot.id, "pos": np}))
		return true
	return false


const BleedoutSystem = preload("res://core/bleedout_system.gd")

static func _down(state, e, events: Array) -> void:
	BleedoutSystem.down_or_kill(state, e, events)
