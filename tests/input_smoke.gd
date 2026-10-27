extends SceneTree
## PLAYER-INPUT smoke test (Playability closeout, P1). Proves a HUMAN drives a combat turn through
## RunController via the InputIntent abstraction — select unit -> choose action -> point tile
## (preview) -> confirm — resolving the REAL command path, NOT the auto-pilot. Also proves the
## sim/skip toggle (sim_mode) still drives the auto-pilot for the test/skip path.
##
## Run: godot --headless --path . --script res://tests/input_smoke.gd

const E = preload("res://core/sim_enums.gd")
const RunController = preload("res://app/run_controller.gd")
const ContentDB = preload("res://core/units/content_db.gd")
const SetpieceLoader = preload("res://core/setpiece_loader.gd")
const TurnManager = preload("res://core/turn_manager.gd")
const EnemyAI = preload("res://ai/enemy_ai.gd")
const InputIntent = preload("res://app/input_intent.gd")
const UnitInstance = preload("res://core/units/unit_instance.gd")
const RunState = preload("res://core/run/run_state.gd")
const Menu = preload("res://app/menu.gd")
const MetaProfile = preload("res://core/meta/meta_profile.gd")
const Unlocks = preload("res://core/meta/unlocks.gd")
const Legacy = preload("res://core/meta/legacy.gd")

var _pass: int = 0
var _fail: int = 0
var _fails: Array = []


func _initialize() -> void:
	print("\n=== COLDSPINE — PLAYER-INPUT smoke test (P1) ===")
	test_scripted_move_resolves_through_intent()
	test_scripted_shoot_through_intent()
	test_scripted_stabilize_through_intent()
	test_stabilize_rejects_non_downed_target()
	# Batch 6 — human ability + item combat use (the depth toolkit)
	test_scripted_ability_through_intent()
	test_ability_entries_gate_on_ap()
	test_scripted_use_item_through_intent()
	test_item_entries_gate_on_ap_and_inventory()
	test_passive_equipment_is_not_usable()
	test_sim_mode_default_is_true()
	# W1 wave — app-seam guards (stale preview, seed policy, [N] restage, legacy burn).
	test_stale_preview_never_commits()
	test_staged_seed_consumed_and_default_kept()
	test_quick_restart_restages_handoff()
	test_legacy_burn_at_breach_seam()
	print("\n--- INPUT SMOKE: %d passed, %d failed ---" % [_pass, _fail])
	for f in _fails:
		print("    FAIL: " + f)
	if _fail == 0:
		print("INPUT GREEN — a human resolves combat turns through the controller (not auto-pilot).\n")
	quit(0 if _fail == 0 else 1)


func ok(cond: bool, msg: String) -> void:
	if cond:
		_pass += 1
	else:
		_fail += 1
		_fails.append(msg)
		print("    [FAIL] " + msg)


# Build a combat car with the loader's starter pair, bind a turn + intent through the controller.
func _combat_controller() -> RunController:
	var rc := RunController.new()
	rc.headless = true
	rc.db = ContentDB.new()
	var data = JSON.parse_string(FileAccess.get_file_as_string("res://content/cars/combat_security_01.json"))
	rc.state = SetpieceLoader.build(data, 0xC01D5)
	rc.turn = TurnManager.new(rc.state)
	rc.turn.start()
	rc.ai = EnemyAI.new()
	rc.bind_combat_intent()
	return rc


func _first_player(rc) -> int:
	for id in rc.state.entity_ids_sorted():
		var e = rc.state.entities.get(id)
		if e != null and e.is_unit and e.alive and e.faction == E.Faction.PLAYER:
			return id
	return -1


# ============================ TESTS ===========================================
func test_scripted_move_resolves_through_intent() -> void:
	var rc := _combat_controller()
	var pid := _first_player(rc)
	ok(pid >= 0, "[input] found a player unit to drive")
	var before: Vector2i = rc.state.entities.get(pid).pos
	# A human taps: select the unit -> choose MOVE -> point one tile to the right -> confirm.
	var dest: Vector2i = before + Vector2i(1, 0)
	var committed: bool = rc.play_player_turn([
		{"op": "select", "id": pid},
		{"op": "action", "mode": InputIntent.Mode.MOVE},
		{"op": "point", "cell": dest},
		{"op": "confirm"},
	])
	ok(committed, "[input] the scripted MOVE committed through InputIntent (real command path)")
	var after: Vector2i = rc.state.entities.get(pid).pos
	ok(after == dest, "[input] the unit actually moved to the pointed tile (%s -> %s)" % [str(before), str(after)])
	ok(after != before, "[input] state changed via player input, not the auto-pilot")


func test_scripted_shoot_through_intent() -> void:
	# Controlled scenario: a player marksman and an enemy placed 4 tiles apart on a clear lane, so a
	# scripted SHOOT intent has a guaranteed in-range line of sight. Proves the SHOOT path commits a
	# ranged attack through InputIntent (the rng-consuming action) — not the auto-pilot.
	var SimState = preload("res://core/sim_state.gd")
	var SimEntity = preload("res://core/sim_entity.gd")
	var IntRng = preload("res://core/int_rng.gd")
	var ShootCommand = preload("res://core/commands/shoot_command.gd")
	var rc := RunController.new()
	rc.headless = true
	rc.db = ContentDB.new()
	rc.state = SimState.new()
	rc.state.init_grid(10, 5)
	rc.state.rng = IntRng.new(0xC01D5)
	var shooter := SimEntity.new()
	shooter.is_unit = true; shooter.pos = Vector2i(1, 2); shooter.hp = 9
	shooter.faction = E.Faction.PLAYER; shooter.integrity = -1; shooter.name = "marksman"
	rc.state.add_entity(shooter)
	var foe := SimEntity.new()
	foe.is_unit = true; foe.pos = Vector2i(5, 2); foe.hp = 6
	foe.faction = E.Faction.ENEMY; foe.integrity = -1; foe.name = "truncheon_guard"
	rc.state.add_entity(foe)
	rc.turn = TurnManager.new(rc.state)
	rc.turn.start()
	rc.ai = EnemyAI.new()
	rc.bind_combat_intent()
	ok(ShootCommand.has_range(shooter.pos, foe.pos) and ShootCommand.in_los(rc.state, shooter.pos, foe.pos),
		"[input] the scenario gives the shooter a clean line (precondition)")
	var foe_hp_before: int = foe.hp
	# A human taps: select -> SHOOT -> point the enemy -> confirm.
	var did: bool = rc.play_player_turn([
		{"op": "select", "id": shooter.id},
		{"op": "action", "mode": InputIntent.Mode.SHOOT},
		{"op": "point", "cell": foe.pos},
		{"op": "confirm"},
	])
	ok(did, "[input] a SHOOT committed through InputIntent (the real ranged command path)")
	# The shot either hit (foe took damage / died) or missed — both are valid resolutions; what we
	# assert is that the COMMAND RESOLVED (the shooter's turn ended, an attack was issued).
	ok(rc.turn.ended.get(shooter.id, false), "[input] the SHOOT ended the shooter's turn (attack resolved, §5.2)")


func test_scripted_stabilize_through_intent() -> void:
	# combat-ux #2 (input-half): a HUMAN stabilizes a downed comrade through the input path — the
	# manual parity for the AUTO pilot's free triage (§7.4). Scenario: a standing player unit next to
	# a Downed+Bleeding player ally; select -> STABILIZE -> point the ally -> confirm.
	var SimState = preload("res://core/sim_state.gd")
	var SimEntity = preload("res://core/sim_entity.gd")
	var IntRng = preload("res://core/int_rng.gd")
	var rc := RunController.new()
	rc.headless = true
	rc.db = ContentDB.new()
	rc.state = SimState.new()
	rc.state.init_grid(8, 5)
	rc.state.rng = IntRng.new(0xC01D5)
	rc.state.bleedout_enabled = true
	var medic := SimEntity.new()
	medic.is_unit = true; medic.pos = Vector2i(2, 2); medic.hp = 9
	medic.faction = E.Faction.PLAYER; medic.integrity = -1; medic.name = "bruiser"
	rc.state.add_entity(medic)
	var downed := SimEntity.new()
	downed.is_unit = true; downed.pos = Vector2i(3, 2); downed.hp = 0
	downed.faction = E.Faction.PLAYER; downed.integrity = -1; downed.name = "firebrand"
	downed.downed = true
	downed.add_status(E.S_BLEEDING)
	downed.bleed_timer = 2
	rc.state.add_entity(downed)
	rc.turn = TurnManager.new(rc.state)
	rc.turn.start()
	rc.ai = EnemyAI.new()
	rc.bind_combat_intent()
	ok(downed.downed and downed.has_status(E.S_BLEEDING), "[input] the ally starts Downed + Bleeding (precondition)")
	var did: bool = rc.play_player_turn([
		{"op": "select", "id": medic.id},
		{"op": "action", "mode": InputIntent.Mode.STABILIZE},
		{"op": "point", "cell": downed.pos},
		{"op": "confirm"},
	])
	ok(did, "[input] the STABILIZE committed through InputIntent (the real ability command path)")
	ok(not downed.has_status(E.S_BLEEDING), "[input] the downed ally is no longer bleeding out (stabilized)")
	ok(downed.bleed_timer == 0, "[input] the bleed-out clock stopped (the §7.4 window held)")
	ok(downed.downed and not downed.dead, "[input] still Downed but saved — permadeath stays a WINDOW, not a wipe")


func test_stabilize_rejects_non_downed_target() -> void:
	# Guard: STABILIZE only targets a Downed+Bleeding ally — pointing a healthy ally rejects (no commit).
	var SimState = preload("res://core/sim_state.gd")
	var SimEntity = preload("res://core/sim_entity.gd")
	var IntRng = preload("res://core/int_rng.gd")
	var rc := RunController.new()
	rc.headless = true
	rc.db = ContentDB.new()
	rc.state = SimState.new()
	rc.state.init_grid(8, 5)
	rc.state.rng = IntRng.new(1)
	var a := SimEntity.new()
	a.is_unit = true; a.pos = Vector2i(2, 2); a.hp = 9; a.faction = E.Faction.PLAYER; a.integrity = -1
	rc.state.add_entity(a)
	var b := SimEntity.new()
	b.is_unit = true; b.pos = Vector2i(3, 2); b.hp = 9; b.faction = E.Faction.PLAYER; b.integrity = -1
	rc.state.add_entity(b)
	rc.turn = TurnManager.new(rc.state)
	rc.turn.start()
	rc.ai = EnemyAI.new()
	rc.bind_combat_intent()
	var did: bool = rc.play_player_turn([
		{"op": "select", "id": a.id},
		{"op": "action", "mode": InputIntent.Mode.STABILIZE},
		{"op": "point", "cell": b.pos},
		{"op": "confirm"},
	])
	ok(not did, "[input] STABILIZE on a healthy ally is rejected (no bleed to stop)")


# ============================ BATCH 6 — ABILITY + ITEM USE =====================
## A HUMAN casts a level-up ACTIVE ability through the input path (combat-ux #1: the pick is now
## castable end-to-end). A saboteur with a picked gas_tap (spawn_hazard) selects -> opens its ability
## list -> targets a tile -> commits an AbilityCommand; the gas lands on the tile and AP is spent.
func test_scripted_ability_through_intent() -> void:
	var SimState = preload("res://core/sim_state.gd")
	var IntRng = preload("res://core/int_rng.gd")
	var rc := RunController.new()
	rc.headless = true
	rc.db = ContentDB.new()
	rc.state = SimState.new()
	rc.state.init_grid(10, 5)
	rc.state.rng = IntRng.new(0xC01D5)
	# A persistent saboteur with a PICKED active ability (gas_tap) — the level-up pick made real.
	var inst := UnitInstance.from_archetype(rc.db, "saboteur", [], "saboteur-1", 1)
	if not inst.chosen_abilities.has("gas_tap"):
		inst.chosen_abilities.append("gas_tap")
	var body := inst.to_sim_entity(rc.db, Vector2i(2, 2))
	rc.state.add_entity(body)
	rc.run = RunState.new()
	rc.run.squad = [inst]
	rc.turn = TurnManager.new(rc.state)
	rc.turn.start()
	rc.ai = EnemyAI.new()
	rc.bind_combat_intent()
	# The controller resolves the unit's castable kit from the run.squad back-link (the ABILITY popup).
	var entries: Array = rc._usable_ability_entries(body.id)
	var has_gas := false
	for e in entries:
		if String(e.get("id", "")) == "gas_tap" and bool(e.get("enabled", false)):
			has_gas = true
	ok(has_gas, "[ability] the picked gas_tap shows as an enabled, castable ability for the unit")
	var target := Vector2i(4, 2)
	var ap_before: int = rc.turn.ap_for(body.id)
	var did: bool = rc.play_player_turn([
		{"op": "select", "id": body.id},
		{"op": "ability", "ability": rc.db.ability("gas_tap")},
		{"op": "point", "cell": target},
		{"op": "confirm"},
	])
	ok(did, "[ability] the AbilityCommand committed through InputIntent (the real ability path)")
	ok(rc.state.tile(target).has_layer(E.L_GAS), "[ability] the ability's effect LANDED (gas spawned on the target tile)")
	ok(rc.turn.ap_for(body.id) == ap_before - 1, "[ability] the ability spent its 1 AP (economy honesty)")


## The ABILITY popup gates on AP: at 0 AP the picked ability shows DISABLED and the palette predicate
## reports nothing castable (the button greys out).
func test_ability_entries_gate_on_ap() -> void:
	var SimState = preload("res://core/sim_state.gd")
	var IntRng = preload("res://core/int_rng.gd")
	var rc := RunController.new()
	rc.headless = true
	rc.db = ContentDB.new()
	rc.state = SimState.new()
	rc.state.init_grid(10, 5)
	rc.state.rng = IntRng.new(1)
	var inst := UnitInstance.from_archetype(rc.db, "saboteur", [], "saboteur-2", 2)
	if not inst.chosen_abilities.has("gas_tap"):
		inst.chosen_abilities.append("gas_tap")
	var body := inst.to_sim_entity(rc.db, Vector2i(2, 2))
	rc.state.add_entity(body)
	rc.run = RunState.new()
	rc.run.squad = [inst]
	rc.turn = TurnManager.new(rc.state)
	rc.turn.start()
	rc.ai = EnemyAI.new()
	rc.bind_combat_intent()
	ok(rc._has_usable_ability(body.id, rc.turn.ap_for(body.id)), "[ability] a full-AP unit has at least one castable ability")
	rc.turn.ap[body.id] = 0
	ok(not rc._has_usable_ability(body.id, 0), "[ability] at 0 AP the ABILITY palette predicate reports nothing castable (button disables)")
	var entries: Array = rc._usable_ability_entries(body.id)
	var any_enabled := false
	for e in entries:
		if bool(e.get("enabled", false)):
			any_enabled = true
	ok(not entries.is_empty() and not any_enabled, "[ability] the ability rows still LIST but all read disabled at 0 AP (no silent hiding)")


## A HUMAN uses a bought CONSUMABLE through the input path (combat-ux #1: shop items are now usable).
## A medic carrying a medkit selects -> opens its item list -> targets a wounded ally -> commits a
## UseItemCommand; the ally heals, the medkit is consumed from gear, and AP is spent.
func test_scripted_use_item_through_intent() -> void:
	var SimState = preload("res://core/sim_state.gd")
	var SimEntity = preload("res://core/sim_entity.gd")
	var IntRng = preload("res://core/int_rng.gd")
	var rc := RunController.new()
	rc.headless = true
	rc.db = ContentDB.new()
	rc.state = SimState.new()
	rc.state.init_grid(8, 5)
	rc.state.rng = IntRng.new(0xC01D5)
	var medic := SimEntity.new()
	medic.is_unit = true; medic.pos = Vector2i(2, 2); medic.hp = 9; medic.max_hp = 9
	medic.faction = E.Faction.PLAYER; medic.integrity = -1; medic.name = "steward"
	medic.gear = ["medkit"]
	rc.state.add_entity(medic)
	var hurt := SimEntity.new()
	hurt.is_unit = true; hurt.pos = Vector2i(3, 2); hurt.hp = 4; hurt.max_hp = 12
	hurt.faction = E.Faction.PLAYER; hurt.integrity = -1; hurt.name = "bruiser"
	rc.state.add_entity(hurt)
	rc.turn = TurnManager.new(rc.state)
	rc.turn.start()
	rc.ai = EnemyAI.new()
	rc.bind_combat_intent()
	# The controller lists the carried consumable (the ITEM popup) off SimEntity.gear.
	var items: Array = rc._usable_item_entries(medic.id)
	var has_medkit := false
	for e in items:
		if String(e.get("id", "")) == "medkit" and bool(e.get("enabled", false)):
			has_medkit = true
	ok(has_medkit, "[item] the carried medkit shows as an enabled, usable consumable")
	var hp_before: int = hurt.hp
	var ap_before: int = rc.turn.ap_for(medic.id)
	var did: bool = rc.play_player_turn([
		{"op": "select", "id": medic.id},
		{"op": "use_item", "item": rc.db.item("medkit"), "id": "medkit"},
		{"op": "point", "cell": hurt.pos},
		{"op": "confirm"},
	])
	ok(did, "[item] the UseItemCommand committed through InputIntent (the real item path)")
	ok(hurt.hp > hp_before, "[item] the consumable's effect LANDED (the wounded ally healed %d -> %d)" % [hp_before, hurt.hp])
	ok(not medic.gear.has("medkit"), "[item] the one-shot consumable was spent from the unit's gear")
	ok(rc.turn.ap_for(medic.id) == ap_before - 1, "[item] the item spent its 1 AP (economy honesty)")


## The ITEM popup gates on AP and on inventory: 0 AP -> rows disabled; empty gear -> no rows at all.
func test_item_entries_gate_on_ap_and_inventory() -> void:
	var SimState = preload("res://core/sim_state.gd")
	var SimEntity = preload("res://core/sim_entity.gd")
	var IntRng = preload("res://core/int_rng.gd")
	var rc := RunController.new()
	rc.headless = true
	rc.db = ContentDB.new()
	rc.state = SimState.new()
	rc.state.init_grid(8, 5)
	rc.state.rng = IntRng.new(2)
	var u := SimEntity.new()
	u.is_unit = true; u.pos = Vector2i(2, 2); u.hp = 9; u.max_hp = 9
	u.faction = E.Faction.PLAYER; u.integrity = -1; u.name = "steward"
	u.gear = ["medkit"]
	rc.state.add_entity(u)
	rc.turn = TurnManager.new(rc.state)
	rc.turn.start()
	rc.ai = EnemyAI.new()
	rc.bind_combat_intent()
	ok(rc._has_usable_item(u.id, rc.turn.ap_for(u.id)), "[item] a full-AP unit carrying a medkit has a usable item")
	rc.turn.ap[u.id] = 0
	ok(not rc._has_usable_item(u.id, 0), "[item] at 0 AP the ITEM palette predicate reports nothing usable (button disables)")
	# Empty the inventory entirely -> zero rows (the button disables with nothing to use).
	u.gear = []
	rc.turn.ap[u.id] = 2
	ok(rc._usable_item_entries(u.id).is_empty(), "[item] an empty inventory yields no usable-item rows")
	ok(not rc._has_usable_item(u.id, 2), "[item] the ITEM palette predicate is false with an empty inventory")


## Passive equipment (armor/weapons) is NEVER offered on the ITEM popup nor accepted by UseItemCommand
## — it is stat gear wired at spawn, not an active-use consumable.
func test_passive_equipment_is_not_usable() -> void:
	var SimState = preload("res://core/sim_state.gd")
	var SimEntity = preload("res://core/sim_entity.gd")
	var IntRng = preload("res://core/int_rng.gd")
	var UseItemCommand = preload("res://core/commands/use_item_command.gd")
	var rc := RunController.new()
	rc.headless = true
	rc.db = ContentDB.new()
	rc.state = SimState.new()
	rc.state.init_grid(8, 5)
	rc.state.rng = IntRng.new(3)
	var u := SimEntity.new()
	u.is_unit = true; u.pos = Vector2i(2, 2); u.hp = 9; u.max_hp = 9
	u.faction = E.Faction.PLAYER; u.integrity = -1; u.name = "bruiser"
	u.gear = ["scrap_vest", "pipe_wrench"]   # armor + weapon — both PASSIVE equipment
	rc.state.add_entity(u)
	rc.turn = TurnManager.new(rc.state)
	rc.turn.start()
	rc.ai = EnemyAI.new()
	rc.bind_combat_intent()
	ok(rc._usable_item_entries(u.id).is_empty(), "[item] armor + weapons never appear on the ITEM popup (passive equipment)")
	# Even a hand-built UseItemCommand on a passive item is rejected at validate().
	var cmd = UseItemCommand.new(u.id, rc.db.item("scrap_vest"), "scrap_vest")
	var v: Dictionary = cmd.validate(rc.state, rc.turn)
	ok(not v.ok, "[item] UseItemCommand rejects passive equipment (%s)" % v.get("reason", ""))


func test_sim_mode_default_is_true() -> void:
	var rc := RunController.new()
	ok(rc.sim_mode == true, "[input] sim_mode defaults TRUE (headless drivers + the skip button auto-pilot)")


# ============================ W1-6 stale-preview guard =========================
## Preview == outcome is the house P0 (invariant #2): after a REJECTED re-point, a second tap
## on the rejected cell must never commit the PREVIOUS preview at a different target. Drives
## the controller's real tap router (_route_tile_tap — the exact seam _on_tile_clicked uses
## on-screen), not InputIntent alone.
func test_stale_preview_never_commits() -> void:
	var SimState = preload("res://core/sim_state.gd")
	var SimEntity = preload("res://core/sim_entity.gd")
	var IntRng = preload("res://core/int_rng.gd")
	var rc := RunController.new()
	rc.headless = true
	rc.db = ContentDB.new()
	rc.state = SimState.new()
	rc.state.init_grid(10, 6)
	rc.state.rng = IntRng.new(0xC01D5)
	var bruiser := SimEntity.new()
	bruiser.is_unit = true; bruiser.pos = Vector2i(2, 2); bruiser.hp = 12
	bruiser.faction = E.Faction.PLAYER; bruiser.integrity = -1; bruiser.name = "bruiser"
	rc.state.add_entity(bruiser)
	var foe_a := SimEntity.new()
	foe_a.is_unit = true; foe_a.pos = Vector2i(3, 2); foe_a.hp = 6
	foe_a.faction = E.Faction.ENEMY; foe_a.integrity = -1; foe_a.name = "guard_a"
	rc.state.add_entity(foe_a)
	var foe_b := SimEntity.new()
	foe_b.is_unit = true; foe_b.pos = Vector2i(4, 3); foe_b.hp = 6   # DIAGONAL -> a SHOVE re-point rejects
	foe_b.faction = E.Faction.ENEMY; foe_b.integrity = -1; foe_b.name = "guard_b"
	rc.state.add_entity(foe_b)
	rc.turn = TurnManager.new(rc.state)
	rc.turn.start()
	rc.ai = EnemyAI.new()
	rc.bind_combat_intent()
	var commits: Array = []
	rc.intent.committed.connect(func(ev): commits.append(ev))
	# NOTE: physics commits ADOPT a resolved clone, so held SimEntity refs go stale — always
	# re-read positions from the authoritative rc.state by id.
	var a_id: int = foe_a.id
	var a_pos: Vector2i = foe_a.pos
	rc.intent.select_unit(bruiser.id)
	rc.intent.choose_action(InputIntent.Mode.SHOVE)
	# Tap 1: preview A (valid, orthogonally adjacent).
	rc._route_tile_tap(a_pos)
	ok(rc.intent.phase == InputIntent.Phase.PREVIEWING, "[stale] tap A arms a valid SHOVE preview")
	# Tap 2: re-point B (diagonal) -> REJECTED. The guard must clear the armed pending action.
	rc._route_tile_tap(foe_b.pos)
	ok(rc.intent.phase == InputIntent.Phase.UNIT_SELECTED,
		"[stale] a rejected re-point CLEARS the stale preview (no armed pending action)")
	# Tap 3: B again — the old bug confirmed the SHOVE ON A here. Nothing may commit.
	rc._route_tile_tap(foe_b.pos)
	ok(commits.is_empty(), "[stale] tapping the rejected cell again commits NOTHING")
	ok(rc.state.entities[a_id].pos == a_pos, "[stale] enemy A never moved (the stale action did not fire)")
	# Recovery: a fresh VALID preview then a second tap commits normally (two-tap intact).
	rc._route_tile_tap(a_pos)
	ok(rc.intent.phase == InputIntent.Phase.PREVIEWING, "[stale] a fresh valid preview re-arms")
	rc._route_tile_tap(a_pos)
	ok(commits.size() == 1, "[stale] the two-tap commit still works after the guard")
	ok(rc.state.entities[a_id].pos != a_pos, "[stale] the committed SHOVE displaced enemy A (preview == outcome)")


# ============================ W1-5 controller seed seam ========================
## A staged fresh seed (the real player path) is consumed by consume_handoff; the reset holder
## (-1 — headless/tests/--sim) keeps DEFAULT_SEED, so every suite stays byte-stable.
func test_staged_seed_consumed_and_default_kept() -> void:
	Menu.MenuHandoff.reset()
	Menu.MenuHandoff.run_seed = 0xBEEF
	var rc := RunController.new()
	rc.headless = true
	rc.consume_handoff()
	ok(rc.seed == 0xBEEF, "[seed] a staged player seed overrides DEFAULT_SEED")
	ok(Menu.MenuHandoff.run_seed == -1, "[seed] the handoff drains after consumption")
	var rc2 := RunController.new()
	rc2.headless = true
	rc2.consume_handoff()
	ok(rc2.seed == RunController.DEFAULT_SEED and rc2.seed == 0xC01D5,
		"[seed] an empty handoff keeps the fixed DEFAULT_SEED (headless stays 0xC01D5)")


# ============================ W1-8 [N] quick-restart restage ===================
## The [N] restage must equal a menu NEW RUN staging: the additive unlock gate + session
## settings carry from the persisted profile; headless keeps the byte-stable default seed.
func test_quick_restart_restages_handoff() -> void:
	var rc := RunController.new()
	rc.headless = true
	var p := MetaProfile.new()
	p.meta_currency = 100
	Unlocks.purchase(p, "setpiece_aquarium")
	p.set_setting("confirm_moves", false)
	p.set_setting("in_car_fog", false)
	rc.restage_handoff_from_profile(p)
	var H = Menu.MenuHandoff
	ok(H.unlocked_car_ids == ["setpiece_aquarium"], "[restart] the unlock gate restages from the profile")
	ok(H.unlocked_class_ids.has("bruiser"), "[restart] the class pool restages")
	ok(bool(H.settings.get("confirm_moves", true)) == false and bool(H.settings.get("in_car_fog", true)) == false,
		"[restart] the session settings carry into the [N] run")
	ok(H.run_seed == -1, "[restart] a headless restage keeps the byte-stable default seed")
	# A second controller consuming the restage equals a menu-launched run.
	var rc2 := RunController.new()
	rc2.headless = true
	rc2.consume_handoff()
	ok(rc2.allow_list == ["setpiece_aquarium"], "[restart] the consumed gate matches a menu launch")
	ok(rc2._confirm_moves() == false, "[restart] confirm_moves survives the [N] restart")
	ok(rc2.fog_enabled() == false, "[restart] in_car_fog survives the [N] restart")


# ============================ W1-7 legacy burn seam ============================
## The Legacy burn moved from NEW RUN click to BREACH finalize: an abandoned draft never
## consumes (nothing reaches the seam), the breach consumption burns exactly once, and a
## second call is a no-op (the staged id drains).
func test_legacy_burn_at_breach_seam() -> void:
	var rc := RunController.new()
	rc.headless = true
	var p := MetaProfile.new()
	var stored: Dictionary = Legacy.enshrine(p, {"id": 4, "instance_id": 4, "name": "Okafor",
		"archetype": "steward", "traits": ["tough"], "inventory": ["field_kit"]})
	var lid := String(stored["legacy_id"])
	rc.legacy_source_id = lid
	# ESC-abandon: the draft never reaches _finalize_run_from_draft -> the hero stays available.
	ok(Legacy.available(p).size() == 1, "[legacy] an abandoned draft leaves the hero un-burned (re-armable)")
	# BREACH: the consumption seam burns the hero exactly once.
	ok(rc.apply_legacy_consumption(p), "[legacy] the breach seam burns the armed hero")
	ok(Legacy.available(p).is_empty(), "[legacy] the burned hero leaves the Memorial pick list")
	ok(not rc.apply_legacy_consumption(p), "[legacy] a second consumption is a no-op (id drained)")
	ok(rc.legacy_source_id == "", "[legacy] the staged id drains on consumption")
