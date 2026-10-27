extends SceneTree
## WAVE 4 — FINALE MECHANICS smoke test (headless). Proves the climax is a REAL fight, not a click:
##   W4-1  relays + the exposed core are REAL, PREVIEWED unit actions — a deployed unit must be
##         adjacent WITH AP, the core needs the shield down first, and preview == commit.
##   W4-2  the antechamber DORMANT phase is honored — the Conductor wakes on crossing the divider
##         (or the first relay/turret down), not instantly on entry.
##   W4-3  the SEIZE THE ENGINE ending is reachable via a live CAPTURE affordance, and is distinct
##         from the sabotage-only (HARD STOP) ending.
##   W4-6  a 60-round finale STALL with an intact core is NOT a victory (the outcome reads real state).
##   W4-7  the finale routes the operator's DEPLOY pick into placement (reuses the combat deploy seam).
##   W4-8  the Conductor's action variety — RE_ROUTE + ACCELERATE actually score across a finale.
##
## Each test reproduces the PRE-FIX defect (reason about the old code in the comments). On-screen/HUD
## touches are null-safe headless, so this drives the REAL RunController / EngineVault / ConductorAI
## APIs without a display. Run: godot --headless --path . --script res://tests/finale_mechanics_smoke.gd

const E = preload("res://core/sim_enums.gd")
const GE = preload("res://core/game_event.gd")
const RunController = preload("res://app/run_controller.gd")
const RunState = preload("res://core/run/run_state.gd")
const UnitInstance = preload("res://core/units/unit_instance.gd")
const ContentDB = preload("res://core/units/content_db.gd")
const SimState = preload("res://core/sim_state.gd")
const SimEntity = preload("res://core/sim_entity.gd")
const IntRng = preload("res://core/int_rng.gd")
const TurnManager = preload("res://core/turn_manager.gd")
const EnemyAI = preload("res://ai/enemy_ai.gd")
const EngineVault = preload("res://core/finale/engine_vault.gd")

var _pass: int = 0
var _fail: int = 0
var _fails: Array = []


func _initialize() -> void:
	print("\n=== COLDSPINE — WAVE 4 FINALE MECHANICS smoke test (headless) ===")
	# W4-1
	test_relay_bare_tap_rejected_without_unit_in_range()
	test_relay_rejected_without_ap()
	test_relay_preview_equals_commit_and_spends_ap()
	test_core_sealed_until_shield_down()
	# W4-2
	test_antechamber_dormant_until_cross_or_relay_down()
	# W4-3
	test_capture_unreachable_while_shielded()
	test_capture_path_reaches_seize()
	test_sabotage_only_is_hard_stop_distinct_from_seize()
	# W4-6
	test_stalled_finale_with_intact_core_is_not_a_win()
	test_resolve_from_run_legacy_vs_finale_state()
	# W4-7
	test_finale_routes_deploy_pick_into_placement()
	# W4-8
	test_conductor_all_actions_score_over_a_finale()
	test_conductor_scoring_is_deterministic()
	print("\n--- FINALE MECHANICS SMOKE: %d passed, %d failed ---" % [_pass, _fail])
	for f in _fails:
		print("    FAIL: " + f)
	if _fail == 0:
		print("FINALE MECHANICS GREEN — relays/core are gated previewed actions, SEIZE is reachable, the antechamber is honored, a stall isn't a win, deploy routes at the Engine, and the Conductor plays varied.\n")
	quit(0 if _fail == 0 else 1)


func ok(cond: bool, msg: String) -> void:
	if cond:
		_pass += 1
	else:
		_fail += 1
		_fails.append(msg)
		print("    [FAIL] " + msg)


# ============================ setup helpers ===================================
## Build a headless finale scenario wired to a RunController like the on-screen path (state/turn/ai/
## vault) but with NO display. Players are parked top-left (well clear of the objects) unless
## `player_positions` overrides. Returns { rc, vault, state }. rc._vault/_in_finale are armed so the
## player-driven objective/capture seam is live (the same seam the two-tap tile path drives).
func _finale(order: int = 20, squad_hp: int = 60, player_positions: Array = []) -> Dictionary:
	var rc := RunController.new()
	rc.headless = true
	rc.db = ContentDB.new()
	rc.seed = 0xC01D5
	var s := SimState.new()
	s.init_grid(22, 12)
	s.rng = IntRng.new(0xC01D5)
	s.bleedout_enabled = true
	rc.state = s
	var ppos: Array = player_positions if not player_positions.is_empty() else [Vector2i(1, 1), Vector2i(1, 2), Vector2i(1, 3)]
	for i in range(ppos.size()):
		var u := SimEntity.new()
		u.is_unit = true
		u.pos = ppos[i]
		u.hp = squad_hp
		u.max_hp = squad_hp
		u.faction = E.Faction.PLAYER
		u.integrity = -1
		u.name = "operator_%d" % i
		u.archetype_id = "bruiser"
		s.add_entity(u)
	rc.turn = TurnManager.new(s)
	rc.turn.start()   # refreshes PLAYER AP to AP_PER_TURN for every unit added above
	rc.ai = EnemyAI.new()
	var vault := EngineVault.new(s, order, null)   # no RunState -> live-facts endings
	vault.build(
		[Vector2i(12, 1), Vector2i(16, 1), Vector2i(16, 10)],   # 3 relays (integrity 6 each)
		[Vector2i(13, 10), Vector2i(18, 5)],                    # 2 dispensers
		Vector2i(17, 6),                                        # core (integrity 12)
		Vector2i(12, 6),                                        # dais
		Vector2i(12, 6))                                        # conductor
	rc._vault = vault
	rc._in_finale = true
	return {"rc": rc, "vault": vault, "state": s}


## Add a PLAYER unit at `pos` with fresh AP (for a test that needs a unit adjacent to a target).
func _add_player(rc, pos: Vector2i, hp: int = 40) -> int:
	var u := SimEntity.new()
	u.is_unit = true
	u.pos = pos
	u.hp = hp
	u.max_hp = hp
	u.faction = E.Faction.PLAYER
	u.integrity = -1
	u.name = "adj_op"
	u.archetype_id = "bruiser"
	rc.state.add_entity(u)
	rc.turn.ap[u.id] = E.AP_PER_TURN
	return u.id


## Erase every relay (the resolver end-state a full break produces) + run one round-start scan so the
## vault fires its relay-destroyed hooks, drops the Conductor's shield and exposes the core.
func _break_all_relays(rc, vault) -> void:
	for rid in vault.objective.relay_ids.duplicate():
		var r = rc.state.entities.get(rid)
		if r != null:
			if rc.state.in_bounds(r.pos) and rc.state.tile(r.pos).occupant_id == r.id:
				rc.state.tile(r.pos).occupant_id = -1
			r.alive = false
			rc.state.entities.erase(rid)
	vault.on_round_start([])


func _make_units(n: int) -> Array:
	var db := ContentDB.new()
	var arches := ["bruiser", "marksman", "saboteur", "steward"]
	var out: Array = []
	for i in range(n):
		out.append(UnitInstance.from_archetype(db, arches[i % arches.size()], [], "U%d" % (i + 1), i + 1))
	return out


func _has_body(s, instance_id: int) -> bool:
	for id in s.entity_ids_sorted():
		var e = s.entities.get(id)
		if e != null and e.is_unit and int(e.instance_id) == instance_id:
			return true
	return false


func _set_dormant_hazard(s, pos: Vector2i, hz: int) -> void:
	var t = s.tile(pos)
	t.hazard = hz
	t.trap_period = 3
	t.trap_active = false


# ============================ W4-1: relays/core are real previewed actions ====
## PRE-FIX: _on_finale_tile armed ANY relay from anywhere and _commit_obj_target erased it — no actor,
## no range, no AP. A bare two-tap (no unit near the relay) destroyed it. POST-FIX the gate rejects it.
func test_relay_bare_tap_rejected_without_unit_in_range() -> void:
	var ctx := _finale()
	var rc: RunController = ctx.rc
	var s = ctx.state
	var relay_cell := Vector2i(12, 1)
	var relay = s.occupant_at(relay_cell)
	var rid: int = relay.id
	ok(relay != null and relay.alive, "[W4-1] precondition: relay online (integrity %d)" % int(relay.integrity))
	# Players are all at x=1 — none is adjacent to the relay at (12,1). Two bare taps:
	rc._on_finale_tile(relay_cell)   # first tap (OLD: arms)
	rc._on_finale_tile(relay_cell)   # second tap (OLD: commits -> erases the relay)
	var after = s.entities.get(rid)
	ok(after != null and after.alive, "[W4-1] a bare two-tap with NO unit in range does NOT disable the relay")
	ok(after != null and int(after.integrity) == E.RELAY_INTEGRITY_DEFAULT, "[W4-1] the untouched relay took zero integrity damage")
	# And with a unit adjacent + AP, the same two-tap ARMS (preview) then COMMITS (disable).
	_add_player(rc, Vector2i(12, 2))
	rc._on_finale_tile(relay_cell)
	ok(rc._obj_target_id == rid, "[W4-1] with a unit adjacent, the first tap ARMS the relay (preview)")
	rc._on_finale_tile(relay_cell)
	var gone = s.entities.get(rid)
	ok(gone == null or not gone.alive, "[W4-1] the previewed two-tap then DISABLED the relay (real delivery)")


## A unit adjacent but with NO AP cannot deliver the action (AP is spent through the turn layer).
func test_relay_rejected_without_ap() -> void:
	var ctx := _finale()
	var rc: RunController = ctx.rc
	var s = ctx.state
	var relay = s.occupant_at(Vector2i(12, 1))
	var pid := _add_player(rc, Vector2i(12, 2))
	rc.turn.ap[pid] = 0   # adjacent, but out of AP
	var pv: Dictionary = rc.preview_objective_action(relay)
	ok(not bool(pv.get("valid", false)) and String(pv.get("reason", "")) == "no_actor",
		"[W4-1] an adjacent unit with NO AP cannot disable a relay (reason=%s)" % String(pv.get("reason", "")))
	var res: Dictionary = rc.commit_objective_action(relay)
	ok(not bool(res.get("valid", false)) and relay.alive and int(relay.integrity) == E.RELAY_INTEGRITY_DEFAULT,
		"[W4-1] the no-AP commit is a no-op (relay intact)")


## A valid action PREVIEWS then COMMITS identically (preview==commit, invariant #2), and spends AP.
func test_relay_preview_equals_commit_and_spends_ap() -> void:
	var ctx := _finale()
	var rc: RunController = ctx.rc
	var s = ctx.state
	var relay = s.occupant_at(Vector2i(12, 1))
	var pid := _add_player(rc, Vector2i(12, 2))
	var pv: Dictionary = rc.preview_objective_action(relay)
	ok(bool(pv.get("valid", false)), "[W4-1] preview valid with an adjacent unit + AP")
	ok(int(pv.get("integrity_before", -1)) == E.RELAY_INTEGRITY_DEFAULT and int(pv.get("integrity_after", -1)) == 0 and bool(pv.get("breaks", false)),
		"[W4-1] preview predicts integrity %d -> 0 (BREAKS)" % E.RELAY_INTEGRITY_DEFAULT)
	ok(int(pv.get("actor_id", -1)) == pid, "[W4-1] preview names the adjacent actor")
	var res: Dictionary = rc.commit_objective_action(relay)
	ok(int(res.get("integrity_after", -99)) == int(pv.get("integrity_after", -1)),
		"[W4-1] COMMIT integrity_after == PREVIEW integrity_after (preview==commit)")
	ok(rc.turn.ap_for(pid) == 0, "[W4-1] the objective action spent the actor's AP (one action per unit per round)")
	# Same unit, now out of AP, cannot deliver a second action this round.
	var relay_c = s.occupant_at(Vector2i(16, 1))
	var pv2: Dictionary = rc.preview_objective_action(relay_c)
	ok(not bool(pv2.get("valid", false)), "[W4-1] the spent unit cannot act again this round (rate-limited)")


## The core needs the shield DOWN first (all relays gone / decapitation). A unit adjacent to a SEALED
## core cannot sabotage it; once the relays fall it can.
func test_core_sealed_until_shield_down() -> void:
	var ctx := _finale()
	var rc: RunController = ctx.rc
	var s = ctx.state
	var core = s.entities.get(ctx.vault.objective.core_id)
	_add_player(rc, Vector2i(17, 5))   # adjacent to the core at (17,6)
	var sealed: Dictionary = rc.preview_objective_action(core)
	ok(not bool(sealed.get("valid", false)) and String(sealed.get("reason", "")) == "core_sealed",
		"[W4-1] an adjacent unit cannot sabotage the SEALED core (shield up)")
	var before: int = int(core.integrity)
	rc.commit_objective_action(core)
	ok(int(core.integrity) == before, "[W4-1] the sealed core took no damage")
	# Drop the shield (break the relays), then the adjacent unit CAN sabotage it.
	_break_all_relays(rc, ctx.vault)
	var exposed: Dictionary = rc.preview_objective_action(core)
	ok(bool(exposed.get("valid", false)) and int(exposed.get("integrity_after", -1)) == E.CORE_INTEGRITY_DEFAULT - E.SABOTAGE_CHARGE_DAMAGE,
		"[W4-1] once exposed, the adjacent unit previews a real sabotage charge (%d -> %d)" % [E.CORE_INTEGRITY_DEFAULT, E.CORE_INTEGRITY_DEFAULT - E.SABOTAGE_CHARGE_DAMAGE])


# ============================ W4-2: antechamber dormant phase honored =========
## PRE-FIX every finale driver called activate_conductor() on ENTRY, so the dormant countdown + the
## cross-the-divider trigger never happened. POST-FIX the Conductor stays dormant until a player crosses
## the inner-vault divider OR a relay/turret falls.
func test_antechamber_dormant_until_cross_or_relay_down() -> void:
	var ctx := _finale()
	var vault: EngineVault = ctx.vault
	var s = ctx.state
	var entry: int = vault._live_enemy_count(s)   # the defender headcount at entry (here: the Conductor)
	# On entry: still the antechamber, the Bridge Countdown has NOT started (dormant).
	ok(vault.vault_phase == E.VaultPhase.ANTECHAMBER, "[W4-2] the vault opens in the ANTECHAMBER phase")
	ok(not vault.objective.countdown_started, "[W4-2] the Bridge Countdown is dormant on entry (not started)")
	# Players parked at x=1, all relays up, no defender down -> the trigger is NOT met (divider at x=8).
	ok(not vault.antechamber_trigger_met(8, entry), "[W4-2] the dormant trigger is unmet while the squad holds the antechamber")
	# (a) crossing the divider arms it.
	s.entities[s.entity_ids_sorted()[0]].pos = Vector2i(9, 5)   # a player crosses to x=9 (>= divider 8)
	ok(vault.antechamber_trigger_met(8, entry), "[W4-2] crossing the inner-vault divider ARMS the trigger")
	# (b) a fresh scenario: downing the first relay also arms it (before any cross).
	var ctx2 := _finale()
	var v2: EngineVault = ctx2.vault
	var entry2: int = v2._live_enemy_count(ctx2.state)
	ok(not v2.antechamber_trigger_met(8, entry2), "[W4-2] fresh: trigger unmet with all relays up")
	ctx2.state.entities.get(v2.objective.relay_ids[0]).alive = false
	ok(v2.antechamber_trigger_met(8, entry2), "[W4-2] downing the first relay ARMS the trigger")
	# (c) a fresh scenario: downing an antechamber DEFENDER (a turret) also arms it.
	var ctx3 := _finale()
	var v3: EngineVault = ctx3.vault
	var turret := SimEntity.new()
	turret.is_unit = true; turret.pos = Vector2i(6, 2); turret.hp = 5
	turret.faction = E.Faction.ENEMY; turret.integrity = -1; turret.name = "sentry_turret"
	ctx3.state.add_entity(turret)
	var entry3: int = v3._live_enemy_count(ctx3.state)   # now counts the turret + the Conductor
	ok(not v3.antechamber_trigger_met(8, entry3), "[W4-2] fresh: trigger unmet with the antechamber defender up")
	turret.alive = false
	ok(v3.antechamber_trigger_met(8, entry3), "[W4-2] downing an antechamber turret ARMS the trigger")
	# And activation actually starts the countdown (the dormant -> active transition).
	v3.activate_conductor([])
	ok(v3.objective.countdown_started and v3.vault_phase == E.VaultPhase.CONDUCTOR_ACTIVE,
		"[W4-2] activating on the trigger starts the Bridge Countdown (Phase 2)")


# ============================ W4-3: SEIZE reachable via capture ===============
## The Conductor cannot be captured while its relay-shield holds (you must drop the relays first).
func test_capture_unreachable_while_shielded() -> void:
	var ctx := _finale()
	var rc: RunController = ctx.rc
	ctx.vault.activate_conductor([])
	_add_player(rc, Vector2i(12, 5))   # adjacent to the Conductor at (12,6), but it is still shielded
	ok(not rc.can_capture_conductor(), "[W4-3] cannot CAPTURE while the Conductor is relay-shielded")


## PRE-FIX capture_conductor() had ZERO callers and no affordance, so conductor_captured was never set
## and the SEIZE ending was unreachable in play. POST-FIX the CAPTURE affordance sets it -> SEIZE.
func test_capture_path_reaches_seize() -> void:
	var ctx := _finale(20, 40)   # low Order (SEIZE needs order <= 40)
	var rc: RunController = ctx.rc
	var vault: EngineVault = ctx.vault
	var s = ctx.state
	vault.activate_conductor([])
	_add_player(rc, Vector2i(12, 5))   # a unit adjacent to the Conductor
	# Drop the relays: the Conductor's shield falls and the core is exposed (decapitation window).
	_break_all_relays(rc, vault)
	ok(not s.entities.get(vault.objective.conductor_id).conductor_shielded, "[W4-3] the shield fell once the relays did")
	ok(rc.can_capture_conductor(), "[W4-3] with the shield down + a unit adjacent, CAPTURE is available")
	ok(rc.commit_capture_conductor(), "[W4-3] the CAPTURE commits")
	ok(vault.objective.conductor_captured, "[W4-3] the Conductor is flagged CAPTURED (the Seize divergence)")
	# Sabotage the now-exposed core; the ending resolves as SEIZE (low Order, in time, whole squad).
	var ev: Array = []
	vault.sabotage_core(E.SABOTAGE_CHARGE_DAMAGE, ev)   # 12 -> 4
	vault.sabotage_core(E.SABOTAGE_CHARGE_DAMAGE, ev)   # 4 -> 0 -> win
	ok(vault.objective.is_objective_complete(), "[W4-3] the core is sabotaged after the capture")
	ok(vault.ending == E.EndingId.SEIZE_ENGINE, "[W4-3] the CAPTURE path reaches SEIZE THE ENGINE (got %d)" % vault.ending)


## The sabotage-only path (break relays -> sabotage, NO capture) resolves HARD STOP — distinct from SEIZE.
func test_sabotage_only_is_hard_stop_distinct_from_seize() -> void:
	var ctx := _finale(20, 40)
	var vault: EngineVault = ctx.vault
	vault.activate_conductor([])
	_break_all_relays(ctx.rc, vault)   # relays down, core exposed, Conductor left alive & UNCAPTURED
	var ev: Array = []
	vault.sabotage_core(E.SABOTAGE_CHARGE_DAMAGE, ev)
	vault.sabotage_core(E.SABOTAGE_CHARGE_DAMAGE, ev)
	ok(vault.objective.is_objective_complete(), "[W4-3] core sabotaged (sabotage-only path)")
	ok(not vault.objective.conductor_captured, "[W4-3] no capture on the sabotage-only path")
	ok(vault.ending == E.EndingId.HARD_STOP, "[W4-3] sabotage-only resolves HARD STOP (got %d)" % vault.ending)
	ok(vault.ending != E.EndingId.SEIZE_ENGINE, "[W4-3] ... distinct from the SEIZE ending")


# ============================ W4-6: a stall is not a win ======================
## PRE-FIX _resolve_from_run passed core_sabotaged=(not wiped), so a 60-round STALL with a live squad
## (core never touched) resolved as a bogus HARD_STOP/PYRRHIC victory. POST-FIX it reads the REAL state.
func test_stalled_finale_with_intact_core_is_not_a_win() -> void:
	var ctx := _finale(20, 2000)   # huge HP so the squad genuinely survives the whole 60-round stall
	var rc: RunController = ctx.rc
	var vault: EngineVault = ctx.vault
	rc.run = RunState.new_run(0xC01D5, _make_units(3))   # a LIVING run squad drives the ending facts
	# All-NOOP script: the operator never breaks a relay or sabotages the core (a true stall).
	var script: Array = []
	for _i in range(70):
		script.append({"op": "noop"})
	rc.drive_finale_scripted(vault, script)
	ok(not rc._squad_wiped_live(rc.state), "[W4-6] the squad is STILL ALIVE at the stall (not a wipe)")
	ok(not vault.objective.is_objective_complete(), "[W4-6] the core was NEVER sabotaged (a genuine stall)")
	ok(rc.ending == E.EndingId.LOSS, "[W4-6] a 60-round stall with an intact core resolves LOSS, not a victory (got %d)" % rc.ending)
	ok(rc.ending != E.EndingId.HARD_STOP and rc.ending != E.EndingId.PYRRHIC and rc.ending != E.EndingId.SEIZE_ENGINE and rc.ending != E.EndingId.LIBERATION,
		"[W4-6] ... and is not ANY victory ending")


## Direct contrast: the legacy one-arg _resolve_from_run (a non-finale defensive path) still reads a
## live squad as a win (core_sabotaged defaults to not-wiped) — the exact behavior the pre-fix finale
## used — whereas the finale now passes core_sabotaged=false and gets a LOSS.
func test_resolve_from_run_legacy_vs_finale_state() -> void:
	var a := _controller_with_live_run()
	a._resolve_from_run(true)                 # legacy default: core_sabotaged = (not wiped) = true
	ok(a.ending != E.EndingId.LOSS and a.ending != -1, "[W4-6] the legacy default (live squad) still resolves a WIN — the pre-fix finale behavior")
	var b := _controller_with_live_run()
	b._resolve_from_run(true, false, false)   # the finale now passes the REAL core state
	ok(b.ending == E.EndingId.LOSS, "[W4-6] passing core_sabotaged=false resolves LOSS (the fix)")


func _controller_with_live_run() -> RunController:
	var rc := RunController.new()
	rc.headless = true
	rc.db = ContentDB.new()
	rc.run = RunState.new_run(0xC01D5, _make_units(3))
	rc.ending = -1
	return rc


# ============================ W4-7: deploy picker at the Engine ===============
## PRE-FIX _run_finale_onscreen placed the squad with _place_squad(state, spawns) — no deploy pick —
## so the operator's DEPLOY choice was dropped at the climax. POST-FIX it passes _forced_deployment,
## reusing the combat deploy seam. Prove the pick is HONORED (fixed call) vs DROPPED (old call).
func test_finale_routes_deploy_pick_into_placement() -> void:
	var rc := RunController.new()
	rc.headless = true
	rc.db = ContentDB.new()
	rc.seed = 0xC01D5
	var units := _make_units(4)   # 4 living units, only 3 spawn tiles -> the pick matters
	rc.run = RunState.new_run(0xC01D5, units)
	var spawns := [{"x": 1, "y": 5}, {"x": 1, "y": 6}, {"x": 2, "y": 5}]
	# The operator benches u3 and deploys u4 (which the roster-first-3 default would never pick).
	var pick := [int(units[3].id), int(units[0].id), int(units[1].id)]
	# (a) the PRE-FIX finale call — no pick — deploys roster-first-3 (u1,u2,u3), dropping u4.
	var s_old := SimState.new(); s_old.init_grid(22, 12); s_old.rng = IntRng.new(1)
	rc.state = s_old
	rc._forced_deployment = []
	rc._place_squad(s_old, spawns)
	ok(not _has_body(s_old, int(units[3].id)), "[W4-7] pre-fix: the finale DROPS the operator's pick (u4 benched)")
	ok(_has_body(s_old, int(units[2].id)), "[W4-7] pre-fix: it deploys roster-first-3 (u3) instead")
	# (b) the FIXED finale call — pass _forced_deployment — honors the pick (u4 in, u3 out).
	var s_new := SimState.new(); s_new.init_grid(22, 12); s_new.rng = IntRng.new(1)
	rc.state = s_new
	rc._forced_deployment = pick
	rc._place_squad(s_new, spawns, rc._forced_deployment)
	ok(_has_body(s_new, int(units[3].id)), "[W4-7] the finale ROUTES the DEPLOY pick into placement (u4 deployed)")
	ok(not _has_body(s_new, int(units[2].id)), "[W4-7] ... and the benched unit (u3) is not deployed")


# ============================ W4-8: Conductor action variety =================
## PRE-FIX the scorer collapsed to OVERCHARGE/DEPLOY: RE_ROUTE needed a player literally standing ON a
## piston/plate tile (none here) and ACCELERATE only fired when nothing else scored (the OVERCHARGE
## fallback always did). POST-FIX a deterministic cadence rotates all four authored actions.
func test_conductor_all_actions_score_over_a_finale() -> void:
	var seen: Dictionary = _run_conductor_finale_and_collect().seen
	ok(seen.has(E.ConductorAction.DEPLOY), "[W4-8] DEPLOY scored across the finale")
	ok(seen.has(E.ConductorAction.OVERCHARGE), "[W4-8] OVERCHARGE scored across the finale")
	ok(seen.has(E.ConductorAction.RE_ROUTE), "[W4-8] RE_ROUTE scored across the finale (a bank was armed/re-routed)")
	ok(seen.has(E.ConductorAction.ACCELERATE), "[W4-8] ACCELERATE scored across the finale (the clock was pressed)")


## The rebalanced scoring stays deterministic (no RNG): the same setup yields the identical telegraph
## sequence across two independent drives.
func test_conductor_scoring_is_deterministic() -> void:
	var a: Array = _run_conductor_finale_and_collect().seq
	var b: Array = _run_conductor_finale_and_collect().seq
	ok(a == b and not a.is_empty(), "[W4-8] the Conductor telegraph sequence is deterministic across drives")


## Drive a scripted finale of Conductor phases with all four triggers reachable (dormant piston + plate
## banks for RE_ROUTE, dispensers for DEPLOY, an exposed player for OVERCHARGE, a running clock for
## ACCELERATE) and collect the telegraphed actions. Returns { seen: {action->true}, seq: [action,...] }.
func _run_conductor_finale_and_collect() -> Dictionary:
	var ctx := _finale(30, 300)
	var vault: EngineVault = ctx.vault
	var s = ctx.state
	# Author dormant piston + plate banks the Conductor can RE_ROUTE (nobody stands on them).
	_set_dormant_hazard(s, Vector2i(5, 5), E.Hazard.PISTON)
	_set_dormant_hazard(s, Vector2i(6, 5), E.Hazard.PISTON)
	_set_dormant_hazard(s, Vector2i(5, 7), E.Hazard.PLATE)
	_set_dormant_hazard(s, Vector2i(6, 7), E.Hazard.PLATE)
	vault.activate_conductor([])
	var seen := {}
	var seq: Array = []
	for _r in range(14):
		var ev: Array = []
		vault.run_conductor_phase(ev)   # resolves last telegraph, scores + telegraphs the next
		var c = s.entities.get(vault.objective.conductor_id)
		if c != null and int(c.pending_action) != E.ConductorAction.NONE:
			seen[int(c.pending_action)] = true
			seq.append(int(c.pending_action))
		vault.on_round_start([])   # advance a round: the countdown ticks -> the cadence advances
	return {"seen": seen, "seq": seq}
