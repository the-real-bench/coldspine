extends SceneTree
## PILOT AI smoke test (Batch 2 / Stage B — the auto-pilot physics-verb upgrade, headless).
##
## Proves the four pilot gaps the balance audit flagged are now closed, on hand-built mini-scenarios
## driven through the REAL command path (rc._player_act_once → turn.try_command), and that the new
## scoring is a PURE, deterministic function of state (previews on clones; byte-identical re-runs):
##
##   (a) _advantage_shove_dir shoves an enemy INTO an adjacent volatile object — detonating it.
##   (b) _best_object_play shoves/slams an adjacent volatile object into enemies (previewed harm).
##   (c) the flood→electrify combo fires an AbilityCommand when a soaked enemy stands in water.
##   (d) captain-key retarget drives the FLOOD gate tool for a damage-shielded captain, not its body.
##   (e) _walkable_for_pilot / EnemyAI._passable exclude standing hazards + gas (keep plain water).
##
## Run: godot --headless --path . --script res://tests/pilot_ai_smoke.gd

const E = preload("res://core/sim_enums.gd")
const RunController = preload("res://app/run_controller.gd")
const EnemyAI = preload("res://ai/enemy_ai.gd")
const ContentDB = preload("res://core/units/content_db.gd")
const UnitInstance = preload("res://core/units/unit_instance.gd")
const RunState = preload("res://core/run/run_state.gd")
const SimState = preload("res://core/sim_state.gd")
const SimEntity = preload("res://core/sim_entity.gd")
const IntRng = preload("res://core/int_rng.gd")
const TurnManager = preload("res://core/turn_manager.gd")
const CaptainSystem = preload("res://core/captain_system.gd")
const ShootCommand = preload("res://core/commands/shoot_command.gd")

var _pass: int = 0
var _fail: int = 0
var _fails: Array = []


func _initialize() -> void:
	print("\n=== COLDSPINE — PILOT AI smoke test (Stage B physics-verb upgrade, headless) ===")
	test_shove_enemy_into_barrel_detonates()          # (a)
	test_object_play_slams_barrel_into_enemy()         # (b)
	test_object_play_is_deterministic_preview()        # (b) determinism
	test_electrify_combo_fires()                       # (c)
	test_captain_retarget_drives_flood_tool()          # (d)
	test_soak_captain_no_wasted_divert_when_short()    # (d) reach-guard
	test_soak_wrangler_pushes_then_downs()             # (f) multi-turn soak playbook
	test_soak_playbook_is_deterministic()              # (f) determinism
	test_walkable_excludes_hazards_keeps_water()       # (e)
	test_enemy_passable_mirrors_hazard_block()         # (e) symmetry
	test_focus_fires_the_one_shot_killable()           # (g) Stage 1 focus-fire targeting
	test_low_hp_unit_retreats_to_cover()               # (h) Stage 1 damage-avoidant retreat
	test_low_hp_unit_takes_the_kill_over_retreat()     # (h) retreat defers to a guaranteed removal
	print("\n--- PILOT AI SMOKE: %d passed, %d failed ---" % [_pass, _fail])
	for f in _fails:
		print("    FAIL: " + f)
	if _fail == 0:
		print("PILOT AI GREEN — volatile-object plays, flood→electrify, captain-key retarget, and hazard-aware pathing all prove out (deterministic).\n")
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
	e.integrity = -1
	e.faction = faction
	e.archetype_id = arch
	e.name = arch
	return s.add_entity(e)

func _barrel(s: SimState, pos: Vector2i) -> int:
	var o := SimEntity.new()
	o.is_unit = false
	o.pos = pos
	o.hp = -1
	o.integrity = 2
	o.mass = E.Mass.MEDIUM
	o.movable = true
	o.faction = E.Faction.OBJECT
	o.name = "barrel_explosive"
	o.on_break = E.OnBreak.EXPLODE
	o.break_param = 2
	return s.add_entity(o)

func _water_main(s: SimState, pos: Vector2i) -> int:
	var o := SimEntity.new()
	o.is_unit = false
	o.pos = pos
	o.hp = -1
	o.integrity = 3
	o.mass = E.Mass.ANCHORED
	o.movable = false
	o.faction = E.Faction.OBJECT
	o.name = "water_main"
	o.on_break = E.OnBreak.FLOOD
	o.break_param = 4
	return s.add_entity(o)

func _start_turn(rc: RunController) -> void:
	rc.turn = TurnManager.new(rc.state)
	rc.turn.start()

func _has_ev(events: Array, t: int) -> bool:
	for ev in events:
		if ev.type == t:
			return true
	return false

func _ev_types(events: Array) -> Array:
	var out: Array = []
	for ev in events:
		out.append(ev.type)
	return out


# ============================ (a) shove enemy into barrel ======================
func test_shove_enemy_into_barrel_detonates() -> void:
	var rc := _rc()
	var s := _grid(rc, 12, 8)
	var pid := _unit(s, Vector2i(2, 4), 12, E.Faction.PLAYER, "bruiser")
	var a_id := _unit(s, Vector2i(3, 4), 6, E.Faction.ENEMY, "truncheon_guard")   # nearest, adjacent
	var b_id := _unit(s, Vector2i(5, 4), 6, E.Faction.ENEMY, "truncheon_guard")   # eats the blast
	var bar := _barrel(s, Vector2i(4, 4))                                          # behind enemy A
	_start_turn(rc)
	var b_before: int = s.entities[b_id].hp
	var events: Array = []
	var label := rc._player_act_once(pid, events)
	ok(label == "shove", "(a) pilot shoves the enemy toward the barrel (got '%s')" % label)
	ok(not s.entities.has(bar), "(a) the barrel detonated and is gone")
	ok(_has_ev(events, E.Ev.OBJECT_BREAK), "(a) OBJECT_BREAK emitted")
	ok(_has_ev(events, E.Ev.EXPLOSION), "(a) EXPLOSION emitted")
	var b_now: int = s.entities[b_id].hp if s.entities.has(b_id) else -999
	ok(b_now < b_before, "(a) the clustered enemy took blast damage (%d -> %d)" % [b_before, b_now])
	# The player id is unused past setup here; assert it survived its own play (12 HP absorbs splash).
	ok(s.entities.has(pid) and s.entities[pid].hp > 0, "(a) the shover survived the splash")


# ============================ (b) object play (slam) ===========================
func test_object_play_slams_barrel_into_enemy() -> void:
	var rc := _rc()
	var s := _grid(rc, 12, 8)
	var pid := _unit(s, Vector2i(2, 4), 12, E.Faction.PLAYER, "bruiser")
	var bar := _barrel(s, Vector2i(3, 4))                                          # adjacent to the player
	var e_id := _unit(s, Vector2i(4, 4), 2, E.Faction.ENEMY, "truncheon_guard")    # low HP, beyond the barrel
	_start_turn(rc)
	# No enemy is adjacent (distance 2) so the advantage-shove step yields; the object play must fire.
	var events: Array = []
	var label := rc._player_act_once(pid, events)
	ok(label == "object", "(b) pilot commits a volatile-object play (got '%s')" % label)
	ok(_has_ev(events, E.Ev.COLLIDE_BODY), "(b) the slammed barrel billiards into the enemy")
	var downed: bool = (not s.entities.has(e_id)) or s.entities[e_id].hp <= 0 or s.entities[e_id].downed
	ok(downed, "(b) the low-HP enemy is downed/removed by the collision")
	# The barrel absorbed the collision (billiards: the mover stops one tile back, integrity spent).
	ok(s.entities.has(bar) and s.entities[bar].integrity < 2, "(b) the slammed barrel took the collision")


func test_object_play_is_deterministic_preview() -> void:
	# The same hand-built state produces the SAME committed event timeline twice — the scoring reads
	# only state (previews on clones), draws no rng, and breaks ties by stable id/coord order.
	var t1 := _object_play_ev_types()
	var t2 := _object_play_ev_types()
	ok(t1 == t2, "(b) object-play event timeline is byte-identical across identical runs")
	ok(not t1.is_empty(), "(b) the deterministic object play actually did something")

func _object_play_ev_types() -> Array:
	var rc := _rc()
	var s := _grid(rc, 12, 8)
	var pid := _unit(s, Vector2i(2, 4), 12, E.Faction.PLAYER, "bruiser")
	_barrel(s, Vector2i(3, 4))
	_unit(s, Vector2i(4, 4), 2, E.Faction.ENEMY, "truncheon_guard")
	_start_turn(rc)
	var events: Array = []
	rc._player_act_once(pid, events)
	return _ev_types(events)


# ============================ (c) flood -> electrify ===========================
func test_electrify_combo_fires() -> void:
	var rc := _rc()
	var s := _grid(rc, 12, 8)
	# A saboteur with the Junction (electrify) ability picked, back-linked to a persistent instance.
	var inst := UnitInstance.from_archetype(rc.db, "saboteur", [], "Sparky", 1)
	inst.chosen_abilities = ["junction"]
	rc.run = RunState.new()
	rc.run.squad = [inst]
	var pid := _unit(s, Vector2i(2, 4), 10, E.Faction.PLAYER, "saboteur")
	s.entities[pid].instance_id = inst.id
	# A soaked enemy standing in water, within Junction range (3).
	var e_id := _unit(s, Vector2i(4, 4), 10, E.Faction.ENEMY, "truncheon_guard")
	s.entities[e_id].add_status(E.S_SOAKED)
	s.tile(Vector2i(4, 4)).status_layer |= E.L_WATER
	_start_turn(rc)
	var hp_before: int = s.entities[e_id].hp
	var events: Array = []
	var label := rc._player_act_once(pid, events)
	ok(label == "ability", "(c) pilot fires the electrify ability (got '%s')" % label)
	ok(_has_ev(events, E.Ev.ABILITY_USE), "(c) an AbilityCommand ran (ABILITY_USE)")
	ok(_has_ev(events, E.Ev.SHOCK), "(c) the soaked-in-water enemy was shocked (SHOCK)")
	var hp_now: int = s.entities[e_id].hp if s.entities.has(e_id) else -999
	ok(hp_now == hp_before - E.SHOCK_DAMAGE or hp_now < 0, "(c) shock dealt SHOCK_DAMAGE (%d -> %d)" % [hp_before, hp_now])


# ============================ (d) captain-key retarget =========================
func test_captain_retarget_drives_flood_tool() -> void:
	var rc := _rc()
	var s := _grid(rc, 14, 8)
	var pid := _unit(s, Vector2i(2, 4), 10, E.Faction.PLAYER, "marksman")
	# A gas-shrouded captain (damage-shielded: gate closed) — shooting its body is wasted.
	var cap_id := _unit(s, Vector2i(6, 4), 18, E.Faction.ENEMY, "captain_tail_warden")
	CaptainSystem.setup(s.entities[cap_id], "gas_shroud_must_be_dispersed")
	s.tile(Vector2i(6, 4)).status_layer |= E.L_GAS   # keep the gas gate CLOSED (immune to damage)
	# A FLOOD gate tool the marksman can shoot from spawn (in range + LoS).
	var tool := _water_main(s, Vector2i(5, 4))
	_start_turn(rc)
	ok(not CaptainSystem.can_take_damage(s, s.entities[cap_id]), "(d) the captain is damage-shielded (gate closed)")
	var events: Array = []
	var label := rc._player_act_once(pid, events)
	ok(label == "shoot", "(d) pilot works the gate tool instead of the shielded body (got '%s')" % label)
	ok(not s.entities.has(tool), "(d) the FLOOD tool was broken open")
	ok(_has_ev(events, E.Ev.OBJECT_BREAK) and _has_ev(events, E.Ev.FLOOD_TILE), "(d) breaking it floods (OBJECT_BREAK + FLOOD_TILE)")


func test_soak_captain_no_wasted_divert_when_short() -> void:
	# A SHOOTABLE soak-gated captain whose only FLOOD tool sits too far to soak it: the pilot must NOT
	# divert to the tool (that was the tail_warden regression) — it just shoots the captain's body.
	var rc := _rc()
	var s := _grid(rc, 14, 8)
	var pid := _unit(s, Vector2i(3, 4), 10, E.Faction.PLAYER, "marksman")
	var cap_id := _unit(s, Vector2i(5, 4), 16, E.Faction.ENEMY, "captain_tail_warden")
	CaptainSystem.setup(s.entities[cap_id], "unshovable_until_soaked")   # gate OPEN (shootable), shove-gated
	# A small tank far from the captain (flood radius 1 can't reach it).
	var tank := SimEntity.new()
	tank.is_unit = false; tank.pos = Vector2i(11, 1); tank.hp = -1; tank.integrity = 2
	tank.mass = E.Mass.MEDIUM; tank.movable = true; tank.faction = E.Faction.OBJECT
	tank.name = "fish_tank_small"; tank.on_break = E.OnBreak.FLOOD; tank.break_param = 1
	var tank_id := s.add_entity(tank)
	_start_turn(rc)
	ok(CaptainSystem.can_take_damage(s, s.entities[cap_id]), "(d) the soak captain is shootable (gate open)")
	ok(not rc._break_would_soak(s.entities[tank_id], s.entities[cap_id]), "(d) breaking the distant tank would NOT soak the captain")
	var events: Array = []
	var label := rc._player_act_once(pid, events)
	ok(label == "shoot", "(d) pilot shoots the captain's body, not the out-of-reach tank (got '%s')" % label)
	ok(_has_ev(events, E.Ev.ATTACK_SHOOT), "(d) the shot targeted the captain")
	ok(s.entities.has(tank_id), "(d) the far tank was left untouched")


# ============================ (f) multi-turn SOAK playbook =====================
## A MOVABLE fish tank whose flood, when broken, soaks within `radius` tiles.
func _fish_tank(s: SimState, pos: Vector2i, radius: int) -> int:
	var o := SimEntity.new()
	o.is_unit = false
	o.pos = pos
	o.hp = -1
	o.integrity = 2
	o.mass = E.Mass.MEDIUM
	o.movable = true
	o.faction = E.Faction.OBJECT
	o.name = "fish_tank_small"
	o.on_break = E.OnBreak.FLOOD
	o.break_param = radius
	return s.add_entity(o)


## Build the soak scenario: a shootable soak-gated captain, a MOVABLE tank 3 tiles from it (its flood
## can't reach the captain from spawn), the wrangler standing on the tank's push tile, plus two
## shooters. Drives PLAYER phases only (the captain holds — a controlled arena) and reports what the
## soak playbook achieved: {pushed, soaked, downed, labels}. Reused for the determinism check.
func _run_soak_scenario() -> Dictionary:
	var rc := _rc()
	var s := _grid(rc, 14, 8)
	var cap_id := _unit(s, Vector2i(8, 4), 20, E.Faction.ENEMY, "captain_tail_warden")
	CaptainSystem.setup(s.entities[cap_id], "unshovable_until_soaked")
	s.entities[cap_id].mass = E.Mass.HEAVY
	var tank_id := _fish_tank(s, Vector2i(5, 4), 2)   # radius 2 can't reach the captain at dist 3
	var bru := _unit(s, Vector2i(4, 4), 12, E.Faction.PLAYER, "bruiser")     # wrangler on the push tile
	var mk1 := _unit(s, Vector2i(3, 3), 9, E.Faction.PLAYER, "marksman")
	var mk2 := _unit(s, Vector2i(3, 5), 9, E.Faction.PLAYER, "marksman")
	# Mirror the environment phase: a soak captain's DAMAGE gate opens (it is shootable; only the
	# SHOVE is gated on Soak). Without this the freshly-setup gate reads as damage-shielded.
	CaptainSystem.tick(s)
	var pushed := false
	var soaked := false
	var labels: Array = []
	for _t in range(14):
		CaptainSystem.tick(s)
		_start_turn(rc)
		for pid in [bru, mk1, mk2]:
			var g := 0
			while rc.turn.can_act(pid) and g < 8:
				g += 1
				var events2: Array = []
				var lbl := rc._player_act_once(pid, events2)
				labels.append(lbl)
				if lbl == "object":
					pushed = true
				if lbl == "":
					break
		if s.entities.has(cap_id) and s.entities[cap_id].has_status(E.S_SOAKED):
			soaked = true
		var down: bool = (not s.entities.has(cap_id)) or s.entities[cap_id].hp <= 0 or s.entities[cap_id].downed
		if down:
			break
	var downed: bool = (not s.entities.has(cap_id)) or s.entities[cap_id].hp <= 0 or s.entities[cap_id].downed
	return {"pushed": pushed, "soaked": soaked, "downed": downed, "labels": labels}


func test_soak_wrangler_pushes_then_downs() -> void:
	var r := _run_soak_scenario()
	ok(r.pushed, "(f) the wrangler shoved the movable tank toward the captain (multi-turn push)")
	ok(r.soaked, "(f) the advancing flood eventually SOAKED the shove-gated captain")
	ok(r.downed, "(f) the soaked captain was downed after the playbook opened it up")


func test_soak_playbook_is_deterministic() -> void:
	# The whole multi-turn playbook is a pure function of board state: previews on clones, integer
	# scoring, no rng in the decision — so two identical runs produce the SAME action-label timeline.
	var a := _run_soak_scenario()
	var b := _run_soak_scenario()
	ok(a.labels == b.labels, "(f) the soak-playbook action timeline is byte-identical across identical runs")
	ok(a.soaked and a.downed, "(f) the deterministic playbook actually soaked + downed the captain")


# ============================ (g) focus-fire threat targeting ==================
func _shot_target(events: Array) -> int:
	for ev in events:
		if ev.type == E.Ev.ATTACK_SHOOT:
			return int(ev.data.get("target", -1))
	return -1


## Two enemies both shootable from the unit's tile — one is one-shot-killable (hp <= base damage),
## one is not. The pilot must FOCUS-FIRE the killable body to remove it from the board this turn
## (a dead enemy stops shooting back), not chip the tough one. Targeting is rng-free + deterministic.
func test_focus_fires_the_one_shot_killable() -> void:
	var rc := _rc()
	var s := _grid(rc, 12, 8)
	var pid := _unit(s, Vector2i(2, 4), 10, E.Faction.PLAYER, "marksman")
	var weak := _unit(s, Vector2i(4, 3), 3, E.Faction.ENEMY, "truncheon_guard")   # one-shot-killable (hp<=4)
	var tough := _unit(s, Vector2i(4, 5), 12, E.Faction.ENEMY, "riot_shield")     # NOT killable this shot
	_start_turn(rc)
	# Both must be independently shootable from spawn (so the choice is real, not forced by LoS).
	ok(_can_shoot(rc, pid, weak) and _can_shoot(rc, pid, tough), "(g) both enemies are shootable from the unit's tile")
	var events: Array = []
	var label := rc._player_act_once(pid, events)
	ok(label == "shoot", "(g) the pilot takes the shot (got '%s')" % label)
	ok(_shot_target(events) == weak, "(g) it focus-fires the one-shot-killable enemy (target=%d, want %d)" % [_shot_target(events), weak])
	ok(_shot_target(events) != tough, "(g) it does NOT chip the tough enemy while a removal is available")


## Helper: does unit `pid` have range + LoS on enemy `eid` from its current tile?
func _can_shoot(rc: RunController, pid: int, eid: int) -> bool:
	var a = rc.state.entities[pid]
	var t = rc.state.entities[eid]
	return ShootCommand.has_range(a.pos, t.pos) and ShootCommand.in_los(rc.state, a.pos, t.pos)


# ============================ (h) low-HP damage-avoidant retreat ===============
## A low-HP unit exposed to an enemy it CANNOT one-shot-kill breaks to cover instead of trading chip
## fire in the open: it moves to a tile that takes strictly less incoming fire and does not step
## toward the enemy. Deterministic (integer incoming estimate on a probe clone; no rng).
func test_low_hp_unit_retreats_to_cover() -> void:
	var rc := _rc()
	var s := _grid(rc, 12, 8)
	var pid := _unit(s, Vector2i(3, 4), 3, E.Faction.PLAYER, "marksman")            # low HP (<= PILOT_RETREAT_HP)
	var enemy := _unit(s, Vector2i(7, 4), 12, E.Faction.ENEMY, "riot_shield")       # exposes it; not one-shot-killable
	s.tile(Vector2i(2, 4)).cover = 2                                                # full cover one step back, same row (non-flanking)
	_start_turn(rc)
	var me = s.entities[pid]
	var orig: Vector2i = me.pos
	var inc_before: int = rc._incoming_at(me, orig)
	ok(inc_before > 0, "(h) the low-HP unit is exposed where it stands (incoming=%d)" % inc_before)
	var events: Array = []
	var label := rc._player_act_once(pid, events)
	ok(label == "move", "(h) the low-HP unit with no kill RETREATS rather than trading in the open (got '%s')" % label)
	var newp: Vector2i = s.entities[pid].pos
	var inc_after: int = rc._incoming_at(s.entities[pid], newp)
	ok(inc_after < inc_before, "(h) it ends on a strictly safer tile (incoming %d -> %d)" % [inc_before, inc_after])
	var d_before: int = abs(orig.x - 7) + abs(orig.y - 4)
	var d_after: int = abs(newp.x - 7) + abs(newp.y - 4)
	ok(d_after >= d_before, "(h) it did NOT advance toward the enemy (dist %d -> %d)" % [d_before, d_after])


## The SAME low-HP unit, but now the exposing enemy IS one-shot-killable: the guaranteed removal is
## worth the exposure, so the pilot takes the kill shot instead of retreating (retreat is gated on
## having NO killable shot).
func test_low_hp_unit_takes_the_kill_over_retreat() -> void:
	var rc := _rc()
	var s := _grid(rc, 12, 8)
	var pid := _unit(s, Vector2i(3, 4), 3, E.Faction.PLAYER, "marksman")
	var enemy := _unit(s, Vector2i(7, 4), 3, E.Faction.ENEMY, "truncheon_guard")   # one-shot-killable
	s.tile(Vector2i(2, 4)).cover = 2
	_start_turn(rc)
	var events: Array = []
	var label := rc._player_act_once(pid, events)
	ok(label == "shoot", "(h) a low-HP unit with a guaranteed KILL takes the shot, not a retreat (got '%s')" % label)
	ok(_shot_target(events) == enemy, "(h) the kill shot targets the killable enemy")


# ============================ (e) hazard-aware pathing =========================
func test_walkable_excludes_hazards_keeps_water() -> void:
	var rc := _rc()
	var s := _grid(rc, 8, 8)
	var pid := _unit(s, Vector2i(1, 1), 10, E.Faction.PLAYER, "bruiser")
	_start_turn(rc)
	# Standing hazards + gas are excluded; plain water and floor stay walkable.
	s.tile(Vector2i(2, 1)).hazard = E.Hazard.SCALD
	s.tile(Vector2i(3, 1)).hazard = E.Hazard.FURNACE
	s.tile(Vector2i(4, 1)).status_layer |= E.L_GAS
	s.tile(Vector2i(2, 2)).status_layer |= E.L_WATER
	ok(not rc._walkable_for_pilot(Vector2i(2, 1)), "(e) SCALD tile is not walkable")
	ok(not rc._walkable_for_pilot(Vector2i(3, 1)), "(e) FURNACE tile is not walkable")
	ok(not rc._walkable_for_pilot(Vector2i(4, 1)), "(e) L_GAS tile is not walkable")
	ok(rc._walkable_for_pilot(Vector2i(2, 2)), "(e) plain L_WATER tile stays walkable (soak-walkable)")
	ok(rc._walkable_for_pilot(Vector2i(5, 5)), "(e) plain floor stays walkable")


func test_enemy_passable_mirrors_hazard_block() -> void:
	var s := SimState.new()
	s.init_grid(8, 8)
	s.rng = IntRng.new(0xC01D5)
	var ai := EnemyAI.new()
	s.tile(Vector2i(2, 1)).hazard = E.Hazard.SCALD
	s.tile(Vector2i(3, 1)).hazard = E.Hazard.LASER_SWEEP
	s.tile(Vector2i(4, 1)).status_layer |= E.L_GAS
	s.tile(Vector2i(2, 2)).status_layer |= E.L_WATER
	ok(not ai._passable(s, Vector2i(2, 1)), "(e) enemy AI blocks SCALD too (physics cuts both ways)")
	ok(not ai._passable(s, Vector2i(3, 1)), "(e) enemy AI blocks LASER_SWEEP too")
	ok(not ai._passable(s, Vector2i(4, 1)), "(e) enemy AI blocks L_GAS too")
	ok(ai._passable(s, Vector2i(2, 2)), "(e) enemy AI keeps plain L_WATER passable")
