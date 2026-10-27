extends SceneTree
## FINALE smoke test (Batch 3 — the player-driven Engine Vault + boss HUD, headless).
## Proves the PLAYER-DRIVEN finale loop WITHOUT a display: the operator's objective-targeting
## (break the 3 relays -> the core shield drops -> sabotage the exposed core -> WIN) drives the
## REAL EngineVault/FinaleObjective API via RunController.drive_finale_scripted() — never the
## scripted auto-pilot (_break_one_relay/_try_sabotage). It also asserts:
##   - decapitation alt-path: killing the Conductor exposes the core even with relays up (shield drops);
##   - the SEALED core gate: a sabotage attempt while shielded deals no damage (DAMAGE_SHIELDED);
##   - NO STUCK STATE: the Bridge Countdown expiring ESCALATES (VAULT_ESCALATE) rather than hard-failing,
##     and a PYRRHIC-class resolution is still reachable after expiry; a squad wipe -> LOSS;
##   - the headless _drive_finale path is BYTE-UNCHANGED (same ending + trace shape for a fixed seed,
##     across two processes' worth of determinism via two in-process drives).
##   - the OpsHUD boss-HUD methods all exist + are callable (the on-screen surface contract).
##
## Run: godot --headless --path . --script res://tests/finale_smoke.gd

const E = preload("res://core/sim_enums.gd")
const GE = preload("res://core/game_event.gd")
const RunController = preload("res://app/run_controller.gd")
const ContentDB = preload("res://core/units/content_db.gd")
const SimState = preload("res://core/sim_state.gd")
const SimEntity = preload("res://core/sim_entity.gd")
const IntRng = preload("res://core/int_rng.gd")
const TurnManager = preload("res://core/turn_manager.gd")
const EnemyAI = preload("res://ai/enemy_ai.gd")
const EngineVault = preload("res://core/finale/engine_vault.gd")
const OpsHUD = preload("res://render/ops_hud.gd")

var _pass: int = 0
var _fail: int = 0
var _fails: Array = []


func _initialize() -> void:
	print("\n=== COLDSPINE — FINALE smoke test (player-driven boss vault, headless) ===")
	test_player_breaks_relays_then_sabotages_core_to_win()
	test_core_sealed_until_shield_drops()
	test_decapitation_exposes_core()
	test_countdown_expiry_escalates_not_hardfail()
	test_squad_wipe_is_loss()
	test_shielded_conductor_holds_dais_not_generic_rusher()
	test_headless_drive_finale_byte_unchanged()
	test_boss_hud_methods_exist()
	print("\n--- FINALE SMOKE: %d passed, %d failed ---" % [_pass, _fail])
	for f in _fails:
		print("    FAIL: " + f)
	if _fail == 0:
		print("FINALE GREEN — the operator breaks relays -> drops the shield -> sabotages the core (player-driven), and the headless path stays byte-stable.\n")
	quit(0 if _fail == 0 else 1)


func ok(cond: bool, msg: String) -> void:
	if cond:
		_pass += 1
	else:
		_fail += 1
		_fails.append(msg)
		print("    [FAIL] " + msg)


# Build a minimal player-driven finale scenario on a clear grid: a 3-unit squad far from harm, the
# 3 relays + 2 dispensers + core + dais + conductor, wired to a RunController like the on-screen path
# (turn/ai/vault) but HEADLESS (no hud/view). Returns {rc, vault}.
func _finale_controller(squad_hp: int = 30) -> Dictionary:
	var rc := RunController.new()
	rc.headless = true
	rc.db = ContentDB.new()
	rc.seed = 0xC01D5
	var s := SimState.new()
	s.init_grid(22, 12)
	s.rng = IntRng.new(0xC01D5)
	s.bleedout_enabled = true
	rc.state = s
	# 3 player units parked top-left, well clear of the vault objects (won't be shot down quickly).
	for i in range(3):
		var u := SimEntity.new()
		u.is_unit = true
		u.pos = Vector2i(1, 1 + i)
		u.hp = squad_hp
		u.faction = E.Faction.PLAYER
		u.integrity = -1
		u.name = "operator_%d" % i
		u.archetype_id = "bruiser"
		s.add_entity(u)
	rc.turn = TurnManager.new(s)
	rc.turn.start()
	rc.ai = EnemyAI.new()
	var vault := EngineVault.new(s, 20, null)   # mid Order; no RunState (live-facts endings)
	# Relays / dispensers / core / dais / conductor on the right half, away from the squad.
	vault.build(
		[Vector2i(12, 1), Vector2i(16, 1), Vector2i(16, 10)],   # 3 relays
		[Vector2i(13, 10), Vector2i(18, 5)],                    # 2 dispensers
		Vector2i(17, 6),                                        # core
		Vector2i(12, 6),                                        # dais
		Vector2i(12, 6))                                        # conductor
	return {"rc": rc, "vault": vault}


# ============================ TESTS ===========================================
## The headline: the operator breaks all 3 relays (shield drops) then sabotages the exposed core to a
## WIN — driven entirely through the player-driven seam, never the scripted auto-pilot.
func test_player_breaks_relays_then_sabotages_core_to_win() -> void:
	var ctx := _finale_controller(40)
	var rc: RunController = ctx.rc
	var vault: EngineVault = ctx.vault

	# Precondition: the core is shielded (relays online + conductor alive) and NOT yet exposed.
	ok(vault.objective.core_shielded(rc.state), "[finale] core starts SHIELDED (relays + conductor up)")
	ok(not vault.objective.core_exposed(rc.state), "[finale] core starts SEALED (not exposed)")
	ok(vault.objective.relays_online(rc.state) == 3, "[finale] all 3 relays start online")

	# Script: 3 rounds breaking relays, then sabotage rounds until the core falls. The core has
	# integrity 12 and a sabotage charge is 8, so 2 charges drop it.
	var script: Array = [
		{"op": "break_relay"}, {"op": "break_relay"}, {"op": "break_relay"},
		{"op": "sabotage_core"}, {"op": "sabotage_core"}, {"op": "sabotage_core"},
	]
	var res: Dictionary = rc.drive_finale_scripted(vault, script)

	ok(res.relays_online == 0, "[finale] the operator broke all 3 relays (0 online)")
	ok(res.core_sabotaged, "[finale] the exposed core was SABOTAGED by the operator's charges")
	ok(res.ending != -1 and res.ending != E.EndingId.LOSS, "[finale] resolved a VICTORY ending (player-driven, not auto-pilot) -> %d" % res.ending)
	# The win must funnel onto the controller's `ending` (so the on-screen path would reach _show_ending).
	ok(rc.ending == res.ending, "[finale] the controller recorded the resolved ending (funnels to _show_ending on-screen)")
	# Mid-sequence: after the relays fell the shield must have dropped (exposed before sabotage).
	ok(not res.shield_up, "[finale] the core shield was DOWN once the relays fell (relay -> shield drop)")


## The core SEALED gate: while any relay is online + the conductor lives, a sabotage attempt is shrugged
## off (DAMAGE_SHIELDED) and the core takes no integrity damage. The shield must drop first.
func test_core_sealed_until_shield_drops() -> void:
	var ctx := _finale_controller(40)
	var rc: RunController = ctx.rc
	var vault: EngineVault = ctx.vault
	vault.activate_conductor([])
	# Try to sabotage the SEALED core directly via the real objective API (what the player tap routes to).
	var core = rc.state.entities.get(vault.objective.core_id)
	var before: int = int(core.integrity)
	var ev: Array = []
	var done: bool = vault.sabotage_core(E.SABOTAGE_CHARGE_DAMAGE, ev)
	ok(not done, "[finale] sabotaging the SEALED core does NOT complete the objective")
	ok(int(core.integrity) == before, "[finale] the sealed core took NO integrity damage (gate held)")
	var shielded_ev := false
	for e in ev:
		if e.type == E.Ev.DAMAGE_SHIELDED:
			shielded_ev = true
	ok(shielded_ev, "[finale] the sealed-core hit emitted DAMAGE_SHIELDED (the '! CORE SEALED' tell)")


## Decapitation alt-path: killing the Conductor drops the shield even with all relays up — the core
## becomes exposed and sabotage-able without breaking a single relay.
func test_decapitation_exposes_core() -> void:
	var ctx := _finale_controller(40)
	var rc: RunController = ctx.rc
	var vault: EngineVault = ctx.vault
	vault.activate_conductor([])
	ok(vault.objective.relays_online(rc.state) == 3 and not vault.objective.core_exposed(rc.state),
		"[finale] precondition: relays up, core sealed")
	# Kill the conductor's body, then run a destruction scan (on_round_start) — the decapitation hook fires.
	var c = rc.state.entities.get(vault.objective.conductor_id)
	c.alive = false
	var ev: Array = []
	vault.on_round_start(ev)
	ok(vault.objective.core_exposed(rc.state), "[finale] decapitation EXPOSES the core (shield bypassed, relays still up)")
	# Now a sabotage charge lands (the core is exposed via decapitation).
	var charges := 0
	var guard := 0
	while not vault.objective.is_objective_complete() and guard < 5:
		guard += 1
		var e2: Array = []
		if vault.sabotage_core(E.SABOTAGE_CHARGE_DAMAGE, e2):
			pass
		charges += 1
	ok(vault.objective.is_objective_complete(), "[finale] the decapitation-exposed core can be sabotaged to a win (%d charges)" % charges)


## NO STUCK STATE: if the operator stalls past the Bridge Countdown, it EXPIRES (good endings lock,
## beat_clock=false) and the room ESCALATES (VAULT_ESCALATE) instead of hard-failing — and a win is
## still reachable after expiry (a PYRRHIC-class resolution).
func test_countdown_expiry_escalates_not_hardfail() -> void:
	var ctx := _finale_controller(80)   # beefy squad so it survives a long stall
	var rc: RunController = ctx.rc
	var vault: EngineVault = ctx.vault
	# Stall: many "noop" rounds (no objective action) drains the 10-round countdown, then break+sabotage.
	var script: Array = []
	for _i in range(12):
		script.append({"op": "noop"})
	script.append_array([
		{"op": "break_relay"}, {"op": "break_relay"}, {"op": "break_relay"},
		{"op": "sabotage_core"}, {"op": "sabotage_core"},
	])
	# We need to see the escalation events: drive manually so we can scan the streams.
	vault.activate_conductor([])
	var saw_expired := false
	var saw_escalate := false
	var rounds := 0
	var si := 0
	rc._in_finale = true
	rc._vault = vault
	while rounds < 60 and vault.ending == -1:
		rounds += 1
		var rs: Array = []
		vault.on_round_start(rs)
		for e in rs:
			if e.type == E.Ev.COUNTDOWN_EXPIRED:
				saw_expired = true
			if e.type == E.Ev.VAULT_ESCALATE:
				saw_escalate = true
		if vault.ending != -1:
			break
		if si < script.size():
			var step = script[si]
			si += 1
			match String(step.get("op", "")):
				"break_relay":
					var r = rc._first_online_relay(vault)
					if r != null:
						rc._commit_obj_target(r)
				"sabotage_core":
					var core = rc.state.entities.get(vault.objective.core_id)
					if core != null and core.alive:
						rc._commit_obj_target(core)
		if vault.ending != -1:
			break
		rc._play(rc.turn.advance_phase())
		var cev: Array = []
		vault.run_conductor_phase(cev)
		rc._play(cev)
		rc._play(rc.ai.take_phase(rc.turn))
		rc._play(rc.turn.advance_phase())
		rc._play(rc.turn.advance_phase())
	rc._in_finale = false
	rc._vault = null
	ok(saw_expired, "[finale] the Bridge Countdown EXPIRED after the stall (COUNTDOWN_EXPIRED fired)")
	ok(saw_escalate, "[finale] expiry ESCALATED the room (VAULT_ESCALATE fired) — menace, not a hard fail")
	ok(not vault.objective.beat_clock(), "[finale] good endings locked out (beat_clock == false after expiry)")
	ok(vault.objective.is_objective_complete(), "[finale] the core was STILL sabotage-able after expiry (no stuck state)")
	ok(vault.ending != -1 and vault.ending != E.EndingId.LOSS, "[finale] resolved a (pyrrhic-class) victory after the clock expired -> %d" % vault.ending)


## A squad wipe in the vault resolves as a LOSS (the only hard failure) — never a stall.
func test_squad_wipe_is_loss() -> void:
	var ctx := _finale_controller(40)
	var rc: RunController = ctx.rc
	var vault: EngineVault = ctx.vault
	vault.activate_conductor([])
	rc._in_finale = true
	rc._vault = vault
	# Wipe the squad outright (every player body gone), then the finale's wipe check must trip.
	for id in rc.state.entity_ids_sorted():
		var e = rc.state.entities.get(id)
		if e != null and e.is_unit and e.faction == E.Faction.PLAYER:
			e.alive = false
			e.dead = true
	ok(rc._squad_wiped_live(rc.state), "[finale] a fully-downed squad reads as wiped (the LOSS trigger)")
	rc._in_finale = false
	rc._vault = null
	# The on-screen loop breaks on _squad_wiped_live -> _run_finale_onscreen resolves via _resolve_from_run
	# which builds a LOSS when the squad is all dead. Assert the facts that drive that branch.
	ok(not vault.objective.is_objective_complete(), "[finale] a wipe leaves the objective unmet (-> LOSS, not a win)")


## W2-7: the shielded Conductor's BODY must NOT be driven by the generic melee_rush EnemyAI (abandon
## the dais + chase/slam the squad while damage-immune). It holds the dais and acts ONLY via its
## ConductorAI cadence. This drives the EXACT production enemy-phase call (ai.take_phase) the finale
## loop uses. PRE-FIX the Conductor stepped off the dais toward the squad; POST-FIX it stays put.
func test_shielded_conductor_holds_dais_not_generic_rusher() -> void:
	var ctx := _finale_controller(40)
	var rc: RunController = ctx.rc
	var vault: EngineVault = ctx.vault
	vault.activate_conductor([])   # Phase 2: body active, still relay-shielded
	var cid: int = vault.objective.conductor_id
	var c = rc.state.entities.get(cid)
	ok(c.conductor_shielded, "[W2-7] precondition: the Conductor is relay-shielded (damage-immune)")
	var start_pos: Vector2i = c.pos
	# CRITICAL (W2-7 regression from the concurrent W2-4 ambush-wake work): teleport a player
	# ORTHOGONALLY ADJACENT to the shielded Conductor. This is the exact case that defeated the
	# `unaware`-only fix — `_fight_joined` wakes on adjacency, so without the is_finale_boss skip in
	# enemy_ai.take_phase the generic policy re-drives the immune boss and shoves the operator. A
	# free adjacent tile is guaranteed on the open dais.
	var adj_player := -1
	for id in rc.state.entity_ids_sorted():
		var e = rc.state.entities.get(id)
		if e != null and e.is_unit and e.faction == E.Faction.PLAYER and e.alive:
			adj_player = id
			break
	ok(adj_player != -1, "[W2-7] precondition: found a player to place beside the Conductor")
	for step in [Vector2i(-1, 0), Vector2i(1, 0), Vector2i(0, -1), Vector2i(0, 1)]:
		var np: Vector2i = start_pos + step
		if rc.state.in_bounds(np) and rc.state.occupant_at(np) == null:
			rc.state.entities[adj_player].pos = np
			break
	# Snapshot squad HP, then run the generic enemy phase exactly as the finale loop does.
	var before_hp: Dictionary = {}
	for id in rc.state.entity_ids_sorted():
		var e = rc.state.entities.get(id)
		if e != null and e.is_unit and e.faction == E.Faction.PLAYER:
			before_hp[id] = e.hp
	rc.turn.advance_phase()                 # PLAYER -> ENEMY: refreshes enemy AP (Conductor gets AP)
	var evs: Array = rc.ai.take_phase(rc.turn)
	# 1. It did not abandon the dais.
	ok(rc.state.entities.get(cid).pos == start_pos, "[W2-7] the shielded Conductor held the dais (did not chase)")
	# 2. It dealt no generic melee/shove/slam/shot damage to the squad.
	var harmed: bool = false
	for id in before_hp:
		var e = rc.state.entities.get(id)
		if e != null and e.hp < before_hp[id]:
			harmed = true
	ok(not harmed, "[W2-7] the shielded Conductor dealt no generic-AI damage to the squad")
	# 3. No generic-AI action event was attributed to the Conductor's body.
	var conductor_acted: bool = false
	for ev in evs:
		var d = ev.data
		if typeof(d) == TYPE_DICTIONARY and (int(d.get("actor", -1)) == cid or int(d.get("id", -999)) == cid):
			conductor_acted = true
	ok(not conductor_acted, "[W2-7] no generic-AI action event was attributed to the Conductor")


## The headless _drive_finale (run_smoke/balance_smoke) path is BYTE-UNCHANGED: drive_to_finale twice
## for the same seed yields the IDENTICAL ending + finale trace shape (the byte-stable contract Batch 3
## must not move). This is the same determinism run_smoke asserts, re-pinned here against Batch-3 edits.
func test_headless_drive_finale_byte_unchanged() -> void:
	var a := RunController.new()
	a.headless = true
	a.db = ContentDB.new()
	a.drive_to_finale(0xC01D5, 3)
	var b := RunController.new()
	b.headless = true
	b.db = ContentDB.new()
	b.drive_to_finale(0xC01D5, 3)
	ok(a.ending != -1 and a.ending == b.ending, "[finale] headless drive_to_finale is deterministic (same ending: %d == %d)" % [a.ending, b.ending])
	ok(a.ending != E.EndingId.LOSS, "[finale] the headless finale-verify path still reaches a victory (squad preserved)")
	# The finale trace lines must be byte-identical (the scripted _break_one_relay/_try_sabotage path).
	var a_fin := _finale_trace(a)
	var b_fin := _finale_trace(b)
	ok(a_fin == b_fin and not a_fin.is_empty(), "[finale] the headless finale trace is byte-identical across drives (scripted path unchanged)")
	# The scripted auto path (NOT the player-driven seam) is what the headless run uses — its trace line
	# must NOT carry the [player-driven] tag (that tag only appears on the on-screen MANUAL path).
	var tagged_player := false
	for t in a_fin:
		if String(t).find("[player-driven]") != -1:
			tagged_player = true
	ok(not tagged_player, "[finale] the headless path uses the SCRIPTED finale resolve (no [player-driven] tag)")


func _finale_trace(rc) -> Array:
	var out: Array = []
	for t in rc.trace:
		if String(t).begins_with("FINALE:"):
			out.append(String(t))
	return out


## The OpsHUD boss-HUD surface contract: every new method the player-driven finale drives must exist
## and be callable on a real OpsHUD instance (the on-screen-only chrome). We can't assert pixels
## headless, but we CAN prove the methods exist + don't crash (enter/exit/countdown/relay/core/telegraph).
func test_boss_hud_methods_exist() -> void:
	var hud := OpsHUD.new()
	# OpsHUD builds its regions in _ready; force it by adding to the scene root so _ready fires.
	root.add_child(hud)
	for m in ["enter_finale_mode", "exit_finale_mode", "set_bridge_countdown", "set_relay_status",
			"set_core_shield", "set_core_integrity", "set_conductor_telegraph", "set_lockdown", "push_escalation"]:
		ok(hud.has_method(m), "[finale] OpsHUD exposes the boss-HUD method %s()" % m)
	# Call them in a plausible F1->F2->F3->F4 sequence — must not crash.
	hud.enter_finale_mode()
	hud.set_bridge_countdown(7, false)
	hud.set_relay_status([
		{"tag": "A", "power": "PISTONS", "cur": 4, "max": 6, "online": true, "targeted": true},
		{"tag": "B", "power": "PLATES", "cur": 0, "max": 6, "online": false, "targeted": false},
		{"tag": "C", "power": "DISPENSERS", "cur": 6, "max": 6, "online": true, "targeted": false},
	])
	hud.set_core_shield(true)
	hud.set_conductor_telegraph(E.ConductorAction.OVERCHARGE, "operator_1")
	hud.set_core_shield(false)
	hud.set_core_integrity(8, 12)
	hud.set_lockdown(true)
	hud.set_bridge_countdown(0, true)   # BREACHED state
	hud.push_escalation(2, "TRAPS FASTER")
	hud.exit_finale_mode()
	ok(true, "[finale] the full F1->F4 boss-HUD call sequence ran without crashing")
	hud.free()
