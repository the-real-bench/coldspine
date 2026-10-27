extends SceneTree
## PILOT WAVE-6 smoke test (autoplay DEPTH — abilities + items + scope + deploy + stabilize parity +
## Steady + betrayer scan), headless. Every assertion drives the REAL auto-pilot decision path
## (rc._player_act_once / rc._auto_player_phase / rc._deploy_order / rc._stabilize_downed_allies /
## rc.scan_for_betrayer) on hand-built mini-scenarios and asserts the pilot ACTUALLY ISSUES the
## command — never that a helper merely COULD. Each test reproduces the pre-fix gap it closes.
##
##   W6-1  (a) the pilot CASTS Gas Tap (AbilityCommand) when a cluster gas out-values a shot.
##         (b) the pilot USES a Medkit (UseItemCommand) on a wounded ally.
##         (c) the retreat-heal: a fragile unit spends a heal ITEM on itself instead of only fleeing.
##         (d) the pilot throws a Breaching Charge (offensive consumable) into a cluster.
##         (e) the whole depth-tool decision is a deterministic function of state (byte-identical).
##   W6-12 a Steady marksman takes the granted SECOND action (vs a non-Steady unit holding after one).
##   W6-4  the pilot triage-stabilize now spends 1 AP through the command path (parity with manual).
##   W6-3  headless auto-deploy fields the BEST-N by rank, not roster-first-N.
##   W6-2  fight-scoped AUTO reverts to MANUAL at car clear (no silent level-up commit); whole-run
##         persists; an AUTO stall hands back to MANUAL.
##   W6-11 the betrayer VET scan reveals a planted Kin through the real Betrayer path (and defuses it).
##
## Run: godot --headless --path . --script res://tests/pilot_wave6_smoke.gd

const E = preload("res://core/sim_enums.gd")
const RunController = preload("res://app/run_controller.gd")
const ContentDB = preload("res://core/units/content_db.gd")
const UnitInstance = preload("res://core/units/unit_instance.gd")
const RunState = preload("res://core/run/run_state.gd")
const SimState = preload("res://core/sim_state.gd")
const SimEntity = preload("res://core/sim_entity.gd")
const IntRng = preload("res://core/int_rng.gd")
const TurnManager = preload("res://core/turn_manager.gd")
const Betrayer = preload("res://core/units/betrayer.gd")
const Leveling = preload("res://core/leveling.gd")
const EnemyAI = preload("res://ai/enemy_ai.gd")

var _pass: int = 0
var _fail: int = 0
var _fails: Array = []


func _initialize() -> void:
	print("\n=== COLDSPINE — PILOT WAVE-6 smoke (autoplay depth: abilities/items/scope/deploy/steady/scan) ===")
	# W6-1
	test_pilot_casts_gas_tap()
	test_pilot_uses_medkit_on_wounded_ally()
	test_pilot_retreat_heal_spends_item_on_self()
	test_pilot_throws_breaching_charge_into_cluster()
	test_depth_tool_decision_is_deterministic()
	test_pilot_holds_shot_over_single_target_gas()
	test_pilot_buffs_a_joined_fight()
	test_real_combat_pilot_uses_ability_and_item()
	# W6-12
	test_steady_marksman_takes_second_action()
	# W6-4
	test_pilot_stabilize_costs_ap()
	# W6-3
	test_auto_deploy_picks_best_not_first()
	# W6-2
	test_auto_engage_defaults_to_fight_scope()
	test_fight_scope_reverts_without_committing_levelup()
	test_whole_run_auto_persists_across_car()
	test_auto_stall_hands_back_to_manual()
	# W6-11
	test_scan_reveals_and_defuses_planted_kin()
	test_scan_reports_clean_and_spends_once()
	print("\n--- PILOT WAVE-6 SMOKE: %d passed, %d failed ---" % [_pass, _fail])
	for f in _fails:
		print("    FAIL: " + f)
	if _fail == 0:
		print("PILOT WAVE-6 GREEN — the auto-pilot uses abilities + items via the pure preview, honors Steady, AP-costs its stabilize, deploys the best-N, scopes AUTO, and vets betrayers (all deterministic).\n")
	quit(0 if _fail == 0 else 1)


func ok(cond: bool, msg: String) -> void:
	if cond:
		_pass += 1
	else:
		_fail += 1
		_fails.append(msg)
		print("    [FAIL] " + msg)


# ============================ scaffolding ======================================
func _rc() -> RunController:
	var rc := RunController.new()
	rc.headless = true
	rc.db = ContentDB.new()
	rc.run = RunState.new()
	rc.run.squad = []
	return rc

func _grid(rc: RunController, w: int, h: int) -> SimState:
	var s := SimState.new()
	s.init_grid(w, h)
	s.rng = IntRng.new(0xC01D5)
	rc.state = s
	return s

func _unit(s: SimState, pos: Vector2i, hp: int, faction: int, arch: String) -> int:
	var e := SimEntity.new()
	e.is_unit = true
	e.pos = pos
	e.hp = hp
	e.max_hp = max(hp, 12)
	e.integrity = -1
	e.faction = faction
	e.archetype_id = arch
	e.name = arch
	e.accuracy = E.BASE_ACCURACY
	e.move_range = E.MOVE_RANGE
	return s.add_entity(e)

func _start_turn(rc: RunController) -> void:
	rc.turn = TurnManager.new(rc.state)
	rc.turn.start()

func _has_ev(events: Array, t: int) -> bool:
	for ev in events:
		if ev.type == t:
			return true
	return false

func _ev_of(events: Array, t: int) -> Array:
	var out: Array = []
	for ev in events:
		if ev.type == t:
			out.append(ev)
	return out

func _ev_types(events: Array) -> Array:
	var out: Array = []
	for ev in events:
		out.append(ev.type)
	return out

func _ability_use_id(events: Array) -> String:
	for ev in events:
		if ev.type == E.Ev.ABILITY_USE:
			return String(ev.data.get("ability", ""))
	return ""

func _item_used_id(events: Array) -> String:
	for ev in events:
		if ev.type == E.Ev.ITEM_USED:
			return String(ev.data.get("item", ""))
	return ""


# ============================ W6-1 (a) cast Gas Tap =============================
func test_pilot_casts_gas_tap() -> void:
	var rc := _rc()
	var s := _grid(rc, 14, 8)
	# A saboteur that has picked Gas Tap (spawn_hazard poison_gas), back-linked to its instance.
	var inst := UnitInstance.from_archetype(rc.db, "saboteur", [], "Gasser", 1)
	inst.chosen_abilities = ["gas_tap"]
	rc.run.squad = [inst]
	var pid := _unit(s, Vector2i(2, 4), 10, E.Faction.PLAYER, "saboteur")
	s.entities[pid].instance_id = inst.id
	# TWO clustered, TOUGH enemies (not one-shot-killable) within Gas Tap range (4) — a shot removes
	# neither, but one gas cloud poisons both (a cluster setup a plain shot can't match).
	var e1 := _unit(s, Vector2i(5, 4), 12, E.Faction.ENEMY, "truncheon_guard")
	var e2 := _unit(s, Vector2i(5, 5), 12, E.Faction.ENEMY, "truncheon_guard")
	_start_turn(rc)
	var events: Array = []
	var label := rc._player_act_once(pid, events)
	ok(label == "cast", "(W6-1a) pilot CASTS an ability instead of a plain shot (got '%s')" % label)
	ok(_ability_use_id(events) == "gas_tap", "(W6-1a) the fired AbilityCommand is Gas Tap (got '%s')" % _ability_use_id(events))
	ok(_has_ev(events, E.Ev.GAS_SPREAD), "(W6-1a) a gas cloud was actually spawned (GAS_SPREAD)")
	var poisoned: bool = s.entities[e1].has_status(E.S_POISONED) and s.entities[e2].has_status(E.S_POISONED)
	ok(poisoned, "(W6-1a) BOTH clustered enemies are poisoned by the cast (real state mutation)")


# ============================ W6-1 (b) use a Medkit ============================
func test_pilot_uses_medkit_on_wounded_ally() -> void:
	var rc := _rc()
	var s := _grid(rc, 16, 8)
	# A healer carrying a Medkit, adjacent to a WOUNDED ally; a tough enemy far away (no killable shot).
	var healer := _unit(s, Vector2i(2, 4), 12, E.Faction.PLAYER, "steward")
	s.entities[healer].gear = ["medkit"]
	var ally := _unit(s, Vector2i(3, 4), 4, E.Faction.PLAYER, "bruiser")   # 4/12 HP — hurt
	s.entities[ally].max_hp = 12
	_unit(s, Vector2i(14, 1), 12, E.Faction.ENEMY, "truncheon_guard")      # far, tough: no shot to take
	_start_turn(rc)
	var hp_before: int = s.entities[ally].hp
	var events: Array = []
	var label := rc._player_act_once(healer, events)
	ok(label == "heal", "(W6-1b) pilot USES an item to heal a hurt ally (got '%s')" % label)
	ok(_item_used_id(events) == "medkit", "(W6-1b) the fired UseItemCommand is the Medkit (got '%s')" % _item_used_id(events))
	ok(_has_ev(events, E.Ev.HEAL), "(W6-1b) a HEAL event was emitted")
	ok(s.entities[ally].hp > hp_before, "(W6-1b) the wounded ally actually gained HP (%d -> %d)" % [hp_before, s.entities[ally].hp])
	ok(not (s.entities[healer].gear.has("medkit")), "(W6-1b) the consumable Medkit was spent from gear")


# ============================ W6-1 (c) retreat-heal (self) =====================
func test_pilot_retreat_heal_spends_item_on_self() -> void:
	var rc := _rc()
	var s := _grid(rc, 14, 8)
	# A FRAGILE unit under lethal incoming, carrying a Medkit, with no one-shot kill available: instead
	# of only fleeing, it spends the heal on ITSELF (the extended retreat-heal). Enemy is tough (not
	# one-shot-killable) and in fire range so incoming >= hp.
	var me := _unit(s, Vector2i(4, 4), 3, E.Faction.PLAYER, "marksman")
	s.entities[me].max_hp = 12
	s.entities[me].gear = ["medkit"]
	_unit(s, Vector2i(6, 4), 12, E.Faction.ENEMY, "riot_shield")           # exposes it, not killable
	_start_turn(rc)
	var incoming: int = rc._incoming_at(s.entities[me], s.entities[me].pos)
	ok(incoming >= s.entities[me].hp, "(W6-1c) the fragile unit faces lethal incoming where it stands (%d >= %d)" % [incoming, s.entities[me].hp])
	var hp_before: int = s.entities[me].hp
	var events: Array = []
	var label := rc._player_act_once(me, events)
	ok(label == "heal", "(W6-1c) the fragile unit SELF-HEALS with the item rather than only retreating (got '%s')" % label)
	ok(_item_used_id(events) == "medkit", "(W6-1c) it spent the Medkit on itself")
	ok(s.entities[me].hp > hp_before, "(W6-1c) it gained HP out of the lethal band (%d -> %d)" % [hp_before, s.entities[me].hp])


# ============================ W6-1 (d) offensive consumable ====================
func test_pilot_throws_breaching_charge_into_cluster() -> void:
	var rc := _rc()
	var s := _grid(rc, 14, 8)
	# A unit carrying a Breaching Charge (spawn_hazard explosion r2) with two clustered enemies in range.
	var me := _unit(s, Vector2i(2, 4), 12, E.Faction.PLAYER, "bruiser")
	s.entities[me].gear = ["breaching_charge"]
	var e1 := _unit(s, Vector2i(4, 4), 8, E.Faction.ENEMY, "truncheon_guard")
	var e2 := _unit(s, Vector2i(4, 5), 8, E.Faction.ENEMY, "truncheon_guard")
	_start_turn(rc)
	var h1: int = s.entities[e1].hp
	var events: Array = []
	var label := rc._player_act_once(me, events)
	ok(label == "cast", "(W6-1d) pilot uses an OFFENSIVE consumable (got '%s')" % label)
	ok(_item_used_id(events) == "breaching_charge", "(W6-1d) the fired UseItemCommand is the Breaching Charge (got '%s')" % _item_used_id(events))
	ok(_has_ev(events, E.Ev.EXPLOSION), "(W6-1d) the charge detonated (EXPLOSION)")
	var harmed: bool = (not s.entities.has(e1)) or s.entities[e1].hp < h1 or (s.entities.has(e2) and s.entities[e2].hp < 8)
	ok(harmed, "(W6-1d) the clustered enemies took the blast")


# ============================ W6-1 (e) determinism ============================
func test_depth_tool_decision_is_deterministic() -> void:
	var a := _gas_scenario_ev_types()
	var b := _gas_scenario_ev_types()
	ok(a == b, "(W6-1e) the depth-tool decision + cast timeline is byte-identical across identical runs")
	ok(not a.is_empty(), "(W6-1e) the deterministic cast actually did something")

func _gas_scenario_ev_types() -> Array:
	var rc := _rc()
	var s := _grid(rc, 14, 8)
	var inst := UnitInstance.from_archetype(rc.db, "saboteur", [], "Gasser", 1)
	inst.chosen_abilities = ["gas_tap"]
	rc.run.squad = [inst]
	var pid := _unit(s, Vector2i(2, 4), 10, E.Faction.PLAYER, "saboteur")
	s.entities[pid].instance_id = inst.id
	_unit(s, Vector2i(5, 4), 12, E.Faction.ENEMY, "truncheon_guard")
	_unit(s, Vector2i(5, 5), 12, E.Faction.ENEMY, "truncheon_guard")
	_start_turn(rc)
	var events: Array = []
	rc._player_act_once(pid, events)
	return _ev_types(events)


# ===== W6-1 guard: a SINGLE-target gas does not out-price a shot (kill priority preserved) =====
func test_pilot_holds_shot_over_single_target_gas() -> void:
	var rc := _rc()
	var s := _grid(rc, 14, 8)
	var inst := UnitInstance.from_archetype(rc.db, "saboteur", [], "Gasser", 1)
	inst.chosen_abilities = ["gas_tap"]
	rc.run.squad = [inst]
	var pid := _unit(s, Vector2i(2, 4), 10, E.Faction.PLAYER, "saboteur")
	s.entities[pid].instance_id = inst.id
	# ONE lone one-shot-killable enemy: a removal shot beats a single-target gas setup.
	var e1 := _unit(s, Vector2i(5, 4), 3, E.Faction.ENEMY, "truncheon_guard")
	_start_turn(rc)
	var events: Array = []
	var label := rc._player_act_once(pid, events)
	ok(label == "shoot", "(W6-1 guard) a lone killable enemy is SHOT, not gassed (got '%s')" % label)
	ok(_ability_use_id(events) == "", "(W6-1 guard) no ability was cast when a kill shot is the better play")


# ===== W6-1 (buff): a fight-joined unit with NO shot casts a timed area buff (Rally) =====
func test_pilot_buffs_a_joined_fight() -> void:
	var rc := _rc()
	var s := _grid(rc, 14, 8)
	# A firebrand that knows Rally (accuracy buff, area 2), flanked by two ally shooters within area 2.
	var fb := UnitInstance.from_archetype(rc.db, "firebrand", [], "Banner", 1)
	fb.chosen_abilities = ["rally"]
	rc.run.squad = [fb]
	var pid := _unit(s, Vector2i(2, 4), 12, E.Faction.PLAYER, "firebrand")
	s.entities[pid].instance_id = fb.id
	_unit(s, Vector2i(3, 4), 10, E.Faction.PLAYER, "marksman")   # in area 2; can shoot the enemy
	_unit(s, Vector2i(2, 5), 10, E.Faction.PLAYER, "marksman")   # in area 2
	# Enemy at Manhattan 7 from the firebrand (beyond its WEAPON_RANGE 6) but within an ally's range.
	_unit(s, Vector2i(9, 4), 12, E.Faction.ENEMY, "truncheon_guard")
	_start_turn(rc)
	ok(rc._best_shootable_enemy(s.entities[pid]) == null, "(W6-1 buff) the firebrand itself has NO shot (enemy out of range)")
	var events: Array = []
	var label := rc._player_act_once(pid, events)
	ok(label == "buff", "(W6-1 buff) a fight-joined unit with no shot casts a timed BUFF (got '%s')" % label)
	ok(_ability_use_id(events) == "rally", "(W6-1 buff) the fired AbilityCommand is Rally")
	ok(_has_ev(events, E.Ev.BUFF_APPLY), "(W6-1 buff) a BUFF_APPLY landed on the cell")
	# It does not re-buff on a second action this turn (first-action-only gate).
	var events2: Array = []
	var label2 := rc._player_act_once(pid, events2)
	ok(label2 != "buff", "(W6-1 buff) the unit does NOT re-cast the same buff on its follow-up action (got '%s')" % label2)


# ===== W6-1 REAL RUN: tools used inside the full auto-resolved combat loop (not an injected step) =====
func test_real_combat_pilot_uses_ability_and_item() -> void:
	var rc := _rc()
	var s := _grid(rc, 12, 8)
	# A saboteur that picked Gas Tap + a WOUNDED bruiser carrying a Medkit, vs a two-enemy cluster.
	var sab := UnitInstance.from_archetype(rc.db, "saboteur", [], "Gasser", 1)
	sab.chosen_abilities = ["gas_tap"]
	var bru := UnitInstance.from_archetype(rc.db, "bruiser", [], "Tank", 2)
	bru.inventory = ["medkit"]
	rc.run.squad = [sab, bru]
	var pid_s := _unit(s, Vector2i(2, 4), 10, E.Faction.PLAYER, "saboteur")
	s.entities[pid_s].instance_id = sab.id
	var pid_b := _unit(s, Vector2i(2, 5), 4, E.Faction.PLAYER, "bruiser")   # wounded 4/12
	s.entities[pid_b].instance_id = bru.id
	s.entities[pid_b].gear = ["medkit"]
	s.entities[pid_b].max_hp = 12
	_unit(s, Vector2i(6, 4), 6, E.Faction.ENEMY, "truncheon_guard")
	_unit(s, Vector2i(6, 5), 6, E.Faction.ENEMY, "truncheon_guard")
	rc.turn = TurnManager.new(s)
	rc.turn.start()
	rc.ai = EnemyAI.new()
	rc._active_combat = true
	# Drive the WHOLE headless combat loop (the same _auto_resolve_combat every full run uses): player
	# phase (auto-pilot) -> enemy phase (EnemyAI) -> env phases, round by round, until it resolves.
	var outcome := rc._auto_resolve_combat()
	var used_gas := false
	var used_medkit := false
	for ev in rc.turn.events:
		if ev.type == E.Ev.ABILITY_USE and String(ev.data.get("ability", "")) == "gas_tap":
			used_gas = true
		if ev.type == E.Ev.ITEM_USED and String(ev.data.get("item", "")) == "medkit":
			used_medkit = true
	ok(used_gas, "(W6-1 REAL) the pilot ISSUED a Gas Tap AbilityCommand inside a real multi-round auto-resolved combat")
	ok(used_medkit, "(W6-1 REAL) the pilot ISSUED a Medkit UseItemCommand inside the same real combat")
	ok(outcome == 0 or outcome == 1 or outcome == 2, "(W6-1 REAL) the real combat resolved to a definite outcome (%d)" % outcome)


# ============================ W6-12 Steady follow-up ==========================
func _shots_by(events: Array, aid: int) -> int:
	var n := 0
	for ev in events:
		if ev.type == E.Ev.ATTACK_SHOOT and int(ev.data.get("actor", -1)) == aid:
			n += 1
	return n

func test_steady_marksman_takes_second_action() -> void:
	# A Steady marksman with full AP and two shootable enemies takes TWO shots (the granted follow-up).
	var rc := _rc()
	var s := _grid(rc, 14, 8)
	var pid := _unit(s, Vector2i(2, 4), 10, E.Faction.PLAYER, "marksman")
	s.entities[pid].steady_shot = true
	_unit(s, Vector2i(5, 4), 12, E.Faction.ENEMY, "truncheon_guard")
	_unit(s, Vector2i(6, 4), 12, E.Faction.ENEMY, "truncheon_guard")
	_start_turn(rc)
	var ev := rc._auto_player_phase()
	ok(_shots_by(ev, pid) == 2, "(W6-12) a Steady marksman fires TWICE (takes the granted second action), got %d" % _shots_by(ev, pid))
	# CONTROL: the SAME setup without Steady holds after one shot (the pre-fix behavior for all ranged).
	var rc2 := _rc()
	var s2 := _grid(rc2, 14, 8)
	var pid2 := _unit(s2, Vector2i(2, 4), 10, E.Faction.PLAYER, "marksman")
	s2.entities[pid2].steady_shot = false
	_unit(s2, Vector2i(5, 4), 12, E.Faction.ENEMY, "truncheon_guard")
	_unit(s2, Vector2i(6, 4), 12, E.Faction.ENEMY, "truncheon_guard")
	_start_turn(rc2)
	var ev2 := rc2._auto_player_phase()
	ok(_shots_by(ev2, pid2) == 1, "(W6-12 control) a NON-Steady marksman holds after one shot, got %d" % _shots_by(ev2, pid2))


# ============================ W6-4 stabilize AP parity ========================
func test_pilot_stabilize_costs_ap() -> void:
	var rc := _rc()
	var s := _grid(rc, 12, 8)
	# A standing helper adjacent to a DOWNED + bleeding ally.
	var helper := _unit(s, Vector2i(2, 4), 12, E.Faction.PLAYER, "bruiser")
	var downed := _unit(s, Vector2i(3, 4), 1, E.Faction.PLAYER, "marksman")
	var d = s.entities[downed]
	d.alive = false
	d.downed = true
	d.add_status(E.S_DOWNED)
	d.add_status(E.S_BLEEDING)
	_start_turn(rc)
	var ap_before: int = rc.turn.ap_for(helper)
	ok(ap_before == E.AP_PER_TURN, "(W6-4) the helper starts a fresh phase with full AP (%d)" % ap_before)
	var events: Array = []
	rc._stabilize_downed_allies(events)
	ok(not d.has_status(E.S_BLEEDING), "(W6-4) the downed ally was stabilized (bleed-out clock stopped)")
	ok(rc.turn.ap_for(helper) == E.AP_PER_TURN - 1, "(W6-4) the stabilize SPENT the helper's 1 AP (%d -> %d), no longer free" % [ap_before, rc.turn.ap_for(helper)])


# ============================ W6-3 best-N auto-deploy =========================
func _roster_unit(id: int, hp: int, mx: int, lvl: int) -> UnitInstance:
	var u := UnitInstance.new()
	u.id = id
	u.hp = hp
	u.max_hp = mx
	u.level = lvl
	u.dead = false
	u.archetype_id = "bruiser"
	return u

func test_auto_deploy_picks_best_not_first() -> void:
	var rc := _rc()
	# Roster front loaded with the WORST units: id100 crippled (2 HP), 101/102 half, 103/104 full.
	rc.run.squad = [
		_roster_unit(100, 2, 12, 1), _roster_unit(101, 6, 12, 1), _roster_unit(102, 6, 12, 1),
		_roster_unit(103, 12, 12, 1), _roster_unit(104, 12, 12, 1),
	]
	var order := rc._deploy_order(3, [])   # empty pick = the headless / AUTO default
	var ids: Array = []
	for u in order:
		ids.append(int(u.id))
	ids.sort()
	ok(ids.size() == 3, "(W6-3) the auto-deploy fields exactly 3 of the 5")
	ok(not (100 in ids), "(W6-3) headless auto-deploy BENCHES the 2-HP front starter (best-N, not roster-first-N)")
	ok(103 in ids and 104 in ids, "(W6-3) it fields the two full-HP recruits (got %s)" % str(ids))


# ============================ W6-2 AUTO scope ================================
func test_auto_engage_defaults_to_fight_scope() -> void:
	var rc := _rc()
	rc.sim_mode = false   # on-screen MANUAL baseline
	rc._toggle_auto()
	ok(rc.sim_mode, "(W6-2) engaging AUTO turns the auto-pilot on")
	ok(rc._auto_scope == "fight", "(W6-2) AUTO defaults to THIS-FIGHT-ONLY scope (got '%s')" % rc._auto_scope)

func test_fight_scope_reverts_without_committing_levelup() -> void:
	var rc := _rc()
	# A unit OWED a level-up pick (reached level 2 without choosing its tier).
	var u := UnitInstance.from_archetype(rc.db, "bruiser", [], "Owed", 1)
	u.level = 2
	rc.run.squad = [u]
	var owed_before := not rc._pending_levelup_choice(u).is_empty()
	rc.sim_mode = false
	rc._toggle_auto()                     # engage fight-scoped AUTO for one combat
	var reverted := rc._auto_revert_after_car()
	ok(reverted, "(W6-2) a fight-scoped AUTO reverts at car clear")
	ok(not rc.sim_mode, "(W6-2) control returns to MANUAL (sim_mode off)")
	# The revert happens BEFORE the level-up resolution in the run loop, so the pick is NOT auto-committed.
	var owed_after := not rc._pending_levelup_choice(u).is_empty()
	ok(owed_before and owed_after, "(W6-2) the permanent level-up pick is left OWED (not silently auto-committed)")

func test_whole_run_auto_persists_across_car() -> void:
	var rc := _rc()
	rc.sim_mode = false
	rc._set_auto_whole_run()
	ok(rc.sim_mode and rc._auto_scope == "run", "(W6-2) whole-run AUTO engages with run scope")
	var reverted := rc._auto_revert_after_car()
	ok(not reverted and rc.sim_mode, "(W6-2) whole-run AUTO is NOT reverted at car clear (persists)")

func test_auto_stall_hands_back_to_manual() -> void:
	var rc := _rc()
	rc.sim_mode = false
	rc._toggle_auto()
	var handed := rc._auto_handback_on_stall()
	ok(handed, "(W6-2) an AUTO stall/wipe hands control back")
	ok(not rc.sim_mode, "(W6-2) after a stall handback the run is MANUAL again (not silently ended under AUTO)")


# ============================ W6-11 betrayer VET scan ========================
func test_scan_reveals_and_defuses_planted_kin() -> void:
	var rc := _rc()
	var clean := UnitInstance.from_archetype(rc.db, "bruiser", [], "Loyal", 1)
	var plant := UnitInstance.from_archetype(rc.db, "marksman", [], "Mole", 2)
	plant.hidden_betrayer = true
	rc.run.squad = [clean, plant]
	ok(not plant.betrayer_revealed, "(W6-11) the plant starts hidden")
	var res := rc.scan_for_betrayer()
	ok(res.get("ok", false) and not res.get("clean", true), "(W6-11) the scan runs and does NOT report clean (a plant was found)")
	ok(res.get("revealed_name", "") == "Mole", "(W6-11) it named the exposed Conductor's Kin (got '%s')" % res.get("revealed_name", ""))
	ok(plant.betrayer_revealed, "(W6-11) the plant is now REVEALED on the persistent roster (real Betrayer.reveal path)")
	# The reveal rides into the combat body -> the defection beat no longer fires (defused).
	var body := plant.to_sim_entity(rc.db, Vector2i(1, 1))
	ok(not Betrayer.should_fire(body, true), "(W6-11) a revealed Kin's defection beat is DEFUSED (should_fire false)")
	# One-per-run: a second scan is refused.
	var res2 := rc.scan_for_betrayer()
	ok(not res2.get("ok", true), "(W6-11) the scan is one-per-run — a second call is refused")

func test_scan_reports_clean_and_spends_once() -> void:
	var rc := _rc()
	rc.run.squad = [
		UnitInstance.from_archetype(rc.db, "bruiser", [], "A", 1),
		UnitInstance.from_archetype(rc.db, "steward", [], "B", 2),
	]
	var res := rc.scan_for_betrayer()
	ok(res.get("ok", false) and res.get("clean", false), "(W6-11) a clean squad reports CLEAN")
	ok(res.get("revealed_name", "x") == "", "(W6-11) no name is surfaced on a clean read")
	var res2 := rc.scan_for_betrayer()
	ok(not res2.get("ok", true), "(W6-11) the one scan is spent even on a clean read")
