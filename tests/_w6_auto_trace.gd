extends SceneTree
## SCRATCH: independent observation that the AUTO pilot issues Ability + Item commands inside the
## REAL headless auto-resolve loop (_auto_resolve_combat — the same entry every full run uses).
## Prints every ABILITY_USE / ITEM_USED event so the gate can grep the actual AUTO trace. TEMPORARY.
const E = preload("res://core/sim_enums.gd")
const RunController = preload("res://app/run_controller.gd")
const ContentDB = preload("res://core/units/content_db.gd")
const UnitInstance = preload("res://core/units/unit_instance.gd")
const RunState = preload("res://core/run/run_state.gd")
const SimState = preload("res://core/sim_state.gd")
const SimEntity = preload("res://core/sim_entity.gd")
const IntRng = preload("res://core/int_rng.gd")
const TurnManager = preload("res://core/turn_manager.gd")
const EnemyAI = preload("res://ai/enemy_ai.gd")

func _u(s, pos, hp, faction, arch) -> int:
	var e := SimEntity.new()
	e.is_unit = true; e.pos = pos; e.hp = hp; e.max_hp = max(hp, 12)
	e.integrity = -1; e.faction = faction; e.archetype_id = arch; e.name = arch
	e.accuracy = E.BASE_ACCURACY; e.move_range = E.MOVE_RANGE
	return s.add_entity(e)

func _initialize() -> void:
	var rc := RunController.new()
	rc.headless = true
	rc.db = ContentDB.new()
	rc.run = RunState.new()
	var s := SimState.new()
	s.init_grid(12, 8)
	s.rng = IntRng.new(0xC01D5)
	rc.state = s
	var sab := UnitInstance.from_archetype(rc.db, "saboteur", [], "Gasser", 1)
	sab.chosen_abilities = ["gas_tap"]
	var bru := UnitInstance.from_archetype(rc.db, "bruiser", [], "Tank", 2)
	bru.inventory = ["medkit"]
	rc.run.squad = [sab, bru]
	var pid_s := _u(s, Vector2i(2, 4), 10, E.Faction.PLAYER, "saboteur")
	s.entities[pid_s].instance_id = sab.id
	var pid_b := _u(s, Vector2i(2, 5), 4, E.Faction.PLAYER, "bruiser")
	s.entities[pid_b].instance_id = bru.id
	s.entities[pid_b].gear = ["medkit"]; s.entities[pid_b].max_hp = 12
	_u(s, Vector2i(6, 4), 6, E.Faction.ENEMY, "truncheon_guard")
	_u(s, Vector2i(6, 5), 6, E.Faction.ENEMY, "truncheon_guard")
	rc.turn = TurnManager.new(s)
	rc.turn.start()
	rc.ai = EnemyAI.new()
	rc._active_combat = true
	var outcome := rc._auto_resolve_combat()
	print("=== AUTO real-combat resolved outcome=%d ===" % outcome)
	for ev in rc.turn.events:
		if ev.type == E.Ev.ABILITY_USE:
			print("AUTO-TRACE ABILITY %s" % str(ev.data))
		if ev.type == E.Ev.ITEM_USED:
			print("AUTO-TRACE ITEM %s" % str(ev.data))
	quit(0)
