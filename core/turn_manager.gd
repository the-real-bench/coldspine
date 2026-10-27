class_name TurnManager
extends RefCounted
## Team-based turn loop (GDD §5.1): player phase → enemy phase → environment phase
## → back to player. Owns a SimState reference; tracks the current phase, the round
## counter, and per-unit AP for the acting faction. AP refreshes to AP_PER_TURN at
## phase start; a Stunned unit refreshes to reduced AP and clears Stunned (§5.5).
## INTEGER-ONLY; ZERO SceneTree deps.

const E = preload("res://core/sim_enums.gd")
const GE = preload("res://core/game_event.gd")
const HazardSystem = preload("res://core/hazard_system.gd")
const BleedoutSystem = preload("res://core/bleedout_system.gd")
const CaptainSystem = preload("res://core/captain_system.gd")

var state                          # SimState
var phase: int = E.Phase.PLAYER
var round_num: int = 1
var ap: Dictionary = {}            # entity id -> remaining AP (acting faction only)
var ended: Dictionary = {}         # entity id -> bool (manually ended this phase)
var events: Array = []             # event log accumulated across the run

func _init(p_state = null) -> void:
	state = p_state

## Begin the run: open on the PLAYER phase with fresh AP.
func start() -> void:
	phase = E.Phase.PLAYER
	round_num = 1
	for ev in _refresh_ap_for(E.Faction.PLAYER):
		events.push_back(ev)

# --- AP / acting bookkeeping ---------------------------------------------------
func ap_for(id: int) -> int:
	return ap.get(id, 0)

func can_act(id: int) -> bool:
	if ended.get(id, false):
		return false
	var e = state.entities.get(id)
	if e == null or not e.alive:
		return false
	return ap_for(id) > 0

func spend(id: int, n: int) -> void:
	ap[id] = max(0, ap_for(id) - n)

## Mark a unit as finished for this phase (used by attacks that end the turn,
## and the EndTurn command).
func end_unit(id: int) -> void:
	ended[id] = true
	ap[id] = 0

## Apply a validated command's bookkeeping: spend its AP, and if it ends the turn,
## end the actor. Returns the command (for chaining). The caller runs validate +
## execute; this just settles AP/turn state afterward.
func settle(cmd) -> void:
	spend(cmd.actor_id, cmd.ap_cost)
	if cmd.ends_turn:
		end_unit(cmd.actor_id)

## Convenience: validate → (if ok) execute → settle. Returns
## {ok:bool, reason:String, events:Array}. Caller checks affordability is implied
## by the AP check here.
func try_command(cmd) -> Dictionary:
	if not can_act(cmd.actor_id) and cmd.ap_cost > 0:
		return {"ok": false, "reason": "actor cannot act (no AP / ended)", "events": []}
	if ap_for(cmd.actor_id) < cmd.ap_cost:
		return {"ok": false, "reason": "not enough AP", "events": []}
	var v: Dictionary = cmd.validate(state, self)
	if not v.ok:
		return {"ok": false, "reason": v.reason, "events": []}
	var evs: Array = cmd.execute(state, self)
	settle(cmd)
	for ev in evs:
		events.push_back(ev)
	return {"ok": true, "reason": "", "events": evs}

# --- phase progression ---------------------------------------------------------
## PLAYER → ENEMY → ENVIRONMENT → PLAYER. The ENVIRONMENT phase ticks the world
## and bumps the round; entering PLAYER/ENEMY refreshes that faction's AP.
## Returns the events emitted by this transition (TURN_PHASE, plus any win/lose).
func advance_phase() -> Array:
	var out: Array = []
	match phase:
		E.Phase.PLAYER:
			phase = E.Phase.ENEMY
			var refreshed: Array = _refresh_ap_for(E.Faction.ENEMY)
			out.push_back(GE.new(E.Ev.TURN_PHASE, {"phase": phase, "round": round_num}))
			for ev in refreshed:
				out.push_back(ev)
		E.Phase.ENEMY:
			phase = E.Phase.ENVIRONMENT
			# Sub-Spec D environment phase (cycling traps → spread → interactions →
			# DoT → clear). Supersedes the old SimState.tick_environment() (which is
			# kept for back-compat). Its events join this phase's timeline.
			var env: Array = HazardSystem.tick(state)
			out.push_back(GE.new(E.Ev.TURN_PHASE, {"phase": phase, "round": round_num}))
			for ev in env:
				out.push_back(ev)
			# Phase 5: re-evaluate Section-Captain gates (shield up/down, guard buff) after
			# the world settles. No-op in cars without a captain (the common case).
			var caps: Array = CaptainSystem.tick(state)
			for ev in caps:
				out.push_back(ev)
			# Phase 4 (§7.4): bleed-out windows tick down in the environment phase.
			# Unstabilized Downed units permadie here (gear drop + Memorial).
			var bleed: Array = BleedoutSystem.tick(state)
			for ev in bleed:
				out.push_back(ev)
		E.Phase.ENVIRONMENT:
			phase = E.Phase.PLAYER
			round_num += 1
			var refreshed_p: Array = _refresh_ap_for(E.Faction.PLAYER)
			out.push_back(GE.new(E.Ev.TURN_PHASE, {"phase": phase, "round": round_num}))
			for ev in refreshed_p:
				out.push_back(ev)
	for ev in out:
		events.push_back(ev)
	# Surface victory/defeat as soon as a phase boundary is crossed.
	var v: int = check_victory()
	if v == 1:
		out.push_back(_log(GE.new(E.Ev.RUN_WIN, {})))
	elif v == 2:
		out.push_back(_log(GE.new(E.Ev.RUN_LOSE, {})))
	return out

## Refresh AP for every living unit of `faction`. Stunned units get reduced AP and
## shed Stunned this turn (§5.5 "skips next action / reduced AP"). Returns the events
## it emitted (stun wear-off is EVENTED so the renderer can animate it, not diff it).
func _refresh_ap_for(faction: int) -> Array:
	var evs: Array = []
	ap.clear()
	ended.clear()
	for id in state.entity_ids_sorted():
		var e = state.entities[id]
		if not e.is_unit or not e.alive or e.faction != faction:
			continue
		if e.has_status(E.S_STUNNED):
			ap[id] = max(0, E.AP_PER_TURN - E.STUN_AP_PENALTY)  # reduced AP
			e.clear_status(E.S_STUNNED)                          # then it wears off
			evs.push_back(GE.new(E.Ev.STATUS_CLEAR, {"id": id, "status": E.S_STUNNED}))
		elif e.has_status(E.S_FROZEN):
			ap[id] = 0                                            # frozen skips entirely
		elif e.has_status(E.S_BURIED) or e.has_status(E.S_NETTED):
			ap[id] = 0                                            # avalanche-buried / netted: immobilized this phase (Phase 5)
			# W2-1: CONSUME the Net immobilize HERE, at the victim's own faction refresh (mirrors
			# the Stunned wear-off above), NOT in the ENVIRONMENT phase. A player netted during
			# the ENEMY phase must keep S_NETTED across the intervening env phase so this refresh
			# sees it and hands out 0 AP; the old env-phase decay cleared it first, so a Net Gunner
			# never cost a player a turn. Buried is applied IN the env phase, so it still counts
			# down in HazardSystem — only the net (enemy-phase-applied) moves here.
			if e.has_status(E.S_NETTED) and e.net_timer > 0:
				e.net_timer -= 1
				if e.net_timer <= 0:
					e.clear_status(E.S_NETTED)
					evs.push_back(GE.new(E.Ev.STATUS_CLEAR, {"id": id, "status": E.S_NETTED}))
		else:
			ap[id] = E.AP_PER_TURN
		# Vanguard (Firebrand capstone, Sub-Spec C2.5): re-arm the first-strike autocrit each of
		# the Firebrand's own phases while it holds MAX momentum, so "the first strike EACH turn"
		# crits. Touches only a Vanguard-at-MAX body; every other unit is unaffected -> byte-identical.
		if e.vanguard_crit and e.momentum >= E.MOMENTUM_MAX and not e.first_attack_autocrit:
			e.first_attack_autocrit = true
	return evs

# --- victory check -------------------------------------------------------------
## 0 = ongoing, 1 = player win (no enemy left), 2 = loss (squad wiped).
## Phase 4 distinction (§7.4): a DOWNED-but-not-dead unit is NOT yet gone — it can
## still be stabilized. So a player is "lost" only once permanently DEAD, and an enemy
## is "cleared" once it is no longer a live threat (dead OR downed-out-of-the-fight).
func check_victory() -> int:
	var players: int = 0   # players still in the run (alive OR downed, i.e. not dead)
	var enemies: int = 0   # enemies still a live threat (alive and not downed)
	for id in state.entity_ids_sorted():
		var e = state.entities[id]
		if not e.is_unit:
			continue
		if e.faction == E.Faction.PLAYER:
			if e.alive or (e.downed and not e.dead):
				players += 1
		elif e.faction == E.Faction.ENEMY:
			if e.alive and not e.downed:
				enemies += 1
	if players == 0:
		return 2
	if enemies == 0:
		return 1
	return 0

func _log(ev) -> GameEvent:
	events.push_back(ev)
	return ev
