extends SceneTree
## INTERACTIVE smoke test (FINAL build wave — the on-screen interactive-combat closeout, headless).
## Proves the PLAYER-DRIVEN combat loop logic WITHOUT a display: a human's tap sequence, fed as
## scripted intents through RunController.play_player_turn() + settle_round_after_player(), drives
## a REAL combat car to resolution via the REAL command path — never the auto-pilot. Extends
## input_smoke (which proved a single MOVE/SHOOT commits) to a FULL player-driven car: scripted
## SHOOTs across multiple settled rounds clear the enemy and WIN the car, with the squad absorbed.
##
## Also pins two contracts the on-screen animated path depends on:
##   - EventPlayer.play_animated(instant_skip=true) == play() (the fast-forward / skip is byte-equal
##     to the instant headless apply — same final token table), so AUTO/skip can never desync.
##   - sim_mode still defaults TRUE (the from-seed/headless drivers + the AUTO button auto-pilot).
##
## Run: godot --headless --path . --script res://tests/interactive_smoke.gd

const E = preload("res://core/sim_enums.gd")
const RunController = preload("res://app/run_controller.gd")
const ContentDB = preload("res://core/units/content_db.gd")
const SimState = preload("res://core/sim_state.gd")
const SimEntity = preload("res://core/sim_entity.gd")
const IntRng = preload("res://core/int_rng.gd")
const TurnManager = preload("res://core/turn_manager.gd")
const EnemyAI = preload("res://ai/enemy_ai.gd")
const SetpieceLoader = preload("res://core/setpiece_loader.gd")
const ShootCommand = preload("res://core/commands/shoot_command.gd")
const InputIntent = preload("res://app/input_intent.gd")
const CarView = preload("res://render/car_view.gd")
const EventPlayer = preload("res://render/event_player.gd")

var _pass: int = 0
var _fail: int = 0
var _fails: Array = []


func _initialize() -> void:
	print("\n=== COLDSPINE — INTERACTIVE smoke test (on-screen loop logic, headless) ===")
	test_scripted_move_then_round_settles()
	test_player_driven_car_won_without_autopilot()
	test_animated_instant_skip_matches_play()
	test_sim_mode_default_is_true()
	print("\n--- INTERACTIVE SMOKE: %d passed, %d failed ---" % [_pass, _fail])
	for f in _fails:
		print("    FAIL: " + f)
	if _fail == 0:
		print("INTERACTIVE GREEN — a human drives a full combat car through the controller (not auto-pilot).\n")
	quit(0 if _fail == 0 else 1)


func ok(cond: bool, msg: String) -> void:
	if cond:
		_pass += 1
	else:
		_fail += 1
		_fails.append(msg)
		print("    [FAIL] " + msg)


func _first_player(rc) -> int:
	for id in rc.state.entity_ids_sorted():
		var e = rc.state.entities.get(id)
		if e != null and e.is_unit and e.alive and e.faction == E.Faction.PLAYER:
			return id
	return -1


# Build a real combat car (the loader's starter pair) bound to a controller + intent, headless.
func _combat_controller() -> RunController:
	var rc := RunController.new()
	rc.headless = true
	rc.db = ContentDB.new()
	var data = JSON.parse_string(FileAccess.get_file_as_string("res://content/cars/combat_security_01.json"))
	rc.state = SetpieceLoader.build(data, 0xC01D5)
	rc.state.bleedout_enabled = true
	rc.turn = TurnManager.new(rc.state)
	rc.turn.start()
	rc.ai = EnemyAI.new()
	rc._active_combat = true
	rc.bind_combat_intent()
	return rc


# ============================ TESTS ===========================================
## A scripted MOVE commits through InputIntent AND the round fully settles (enemy + environment
## phases run) via settle_round_after_player() — i.e. the human-driven turn advances the turn loop
## exactly like the auto-pilot path, with no auto-pilot involved.
func test_scripted_move_then_round_settles() -> void:
	var rc := _combat_controller()
	var pid := _first_player(rc)
	ok(pid >= 0, "[interactive] found a player unit to drive")
	var before: Vector2i = rc.state.entities.get(pid).pos
	var round_before: int = rc.turn.round_num
	var committed: bool = rc.play_player_turn([
		{"op": "select", "id": pid},
		{"op": "action", "mode": InputIntent.Mode.MOVE},
		{"op": "point", "cell": before + Vector2i(1, 0)},
		{"op": "confirm"},
		{"op": "end"},
	])
	ok(committed, "[interactive] the scripted MOVE committed through InputIntent (real command path)")
	ok(rc.state.entities.get(pid).pos == before + Vector2i(1, 0), "[interactive] the unit moved to the pointed tile")
	# Settle the round: PLAYER -> ENEMY -> ENVIRONMENT -> PLAYER. The round counter advances.
	var v: int = rc.settle_round_after_player()
	ok(v in [0, 1, 2], "[interactive] settle_round_after_player returned a valid victory code")
	ok(rc.turn.round_num == round_before + 1, "[interactive] the round advanced after the player phase settled (%d -> %d)" % [round_before, rc.turn.round_num])
	ok(rc.turn.phase == E.Phase.PLAYER, "[interactive] control returned to the PLAYER phase for the next turn")


## A FULL player-driven combat car: a controlled clean-lane scenario where scripted SHOOT intents,
## settled round by round through the controller, clear the enemy and WIN the car — proving a human
## resolves an entire combat car through the controller without the auto-pilot ever running.
func test_player_driven_car_won_without_autopilot() -> void:
	var rc := RunController.new()
	rc.headless = true
	rc.db = ContentDB.new()
	rc.state = SimState.new()
	rc.state.init_grid(12, 5)
	rc.state.rng = IntRng.new(0xC01D5)
	rc.state.bleedout_enabled = true
	# One player marksman vs one low-HP enemy on a clear horizontal lane (guaranteed clean LoS).
	var shooter := SimEntity.new()
	shooter.is_unit = true; shooter.pos = Vector2i(2, 2); shooter.hp = 9
	shooter.faction = E.Faction.PLAYER; shooter.integrity = -1; shooter.name = "marksman"
	shooter.archetype_id = "marksman"
	rc.state.add_entity(shooter)
	var foe := SimEntity.new()
	foe.is_unit = true; foe.pos = Vector2i(5, 2); foe.hp = 5
	foe.faction = E.Faction.ENEMY; foe.integrity = -1; foe.name = "truncheon_guard"
	foe.archetype_id = "truncheon_guard"
	rc.state.add_entity(foe)
	rc.turn = TurnManager.new(rc.state)
	rc.turn.start()
	rc.ai = EnemyAI.new()
	rc._active_combat = true
	rc.bind_combat_intent()

	var sid: int = shooter.id
	var fid: int = foe.id
	ok(ShootCommand.has_range(shooter.pos, foe.pos) and ShootCommand.in_los(rc.state, shooter.pos, foe.pos),
		"[interactive] the scenario gives the shooter a clean line (precondition)")

	# Drive the human's turns: each round, select -> SHOOT -> point the foe -> confirm, then settle.
	# Loop a bounded number of rounds; a few shots reliably clear a 5-HP target (4 base + 0..var dmg).
	var outcome: int = 0
	var shots_committed: int = 0
	var guard: int = 0
	while outcome == 0 and guard < 30:
		guard += 1
		if not rc.state.entities.has(fid):
			break
		if rc.turn.can_act(sid):
			var did: bool = rc.play_player_turn([
				{"op": "select", "id": sid},
				{"op": "action", "mode": InputIntent.Mode.SHOOT},
				{"op": "point", "cell": rc.state.entities.get(fid).pos},
				{"op": "confirm"},
			])
			if did:
				shots_committed += 1
		outcome = rc.settle_round_after_player()

	ok(shots_committed >= 1, "[interactive] the operator committed real SHOOT commands across the car (%d shots)" % shots_committed)
	ok(outcome == 1, "[interactive] the player-driven car was WON through the controller (no auto-pilot) — code %d" % outcome)
	# The enemy is gone (cleared), and the shooter never auto-acted: every action came from play_player_turn.
	var foe_gone: bool = (not rc.state.entities.has(fid)) or (not rc.state.entities.get(fid).alive)
	ok(foe_gone, "[interactive] the enemy was cleared by the human-issued shots")


## The on-screen fast-forward / skip path (play_animated with instant_skip) must produce the EXACT
## same final token table as the instant headless play() — so AUTO/skip can never desync the view.
func test_animated_instant_skip_matches_play() -> void:
	# A controlled MOVE+HIT event stream applied to two CarViews: one via play(), one via the
	# instant-skip animated path. The resulting visual token tables (positions + alive) must match.
	var GE = preload("res://core/game_event.gd")
	var s := SimState.new()
	s.init_grid(8, 5)
	var u := SimEntity.new()
	u.is_unit = true; u.pos = Vector2i(1, 2); u.hp = 9; u.faction = E.Faction.PLAYER
	u.integrity = -1; u.name = "marksman"
	s.add_entity(u)
	var o := SimEntity.new()
	o.is_unit = false; o.pos = Vector2i(4, 2); o.integrity = 3; o.name = "crate"
	s.add_entity(o)
	var events: Array = [
		GE.new(E.Ev.MOVE, {"id": u.id, "to": Vector2i(2, 2)}),
		GE.new(E.Ev.OBJECT_BREAK, {"id": o.id, "pos": Vector2i(4, 2)}),
	]

	var view_a := CarView.new()
	view_a.use_textures = false
	view_a.setup(s, Vector2(1280, 720))
	var pa := EventPlayer.new(view_a, false)
	pa.play(events)

	var view_b := CarView.new()
	view_b.use_textures = false
	view_b.setup(s, Vector2(1280, 720))
	var pb := EventPlayer.new(view_b, false)
	pb.instant_skip = true
	# instant_skip short-circuits to play() even without a tree, so this never awaits.
	pb.play_animated(events)

	ok(view_a.tokens[u.id]["vis_pos"] == view_b.tokens[u.id]["vis_pos"],
		"[interactive] instant-skip moves the token to the same screen pos as play()")
	ok(view_a.tokens[o.id]["alive"] == view_b.tokens[o.id]["alive"] and not view_b.tokens[o.id]["alive"],
		"[interactive] instant-skip breaks the object exactly like play() (token dead in both)")
	ok(view_a.debug_ascii() == view_b.debug_ascii(),
		"[interactive] the composed scene is byte-identical between play() and instant-skip animated")

	view_a.free()
	view_b.free()


func test_sim_mode_default_is_true() -> void:
	var rc := RunController.new()
	ok(rc.sim_mode == true, "[interactive] sim_mode defaults TRUE (headless drivers + the AUTO button auto-pilot)")
