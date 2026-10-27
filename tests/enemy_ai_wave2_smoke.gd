extends SceneTree
## WAVE 2 — ENEMY AI true-to-design golden smoke (NEW file; does NOT touch run_tests.gd).
## Each test reproduces the EXACT pre-fix broken behavior, so it would FAIL without the fix:
##
##   W2-1  Net Gunner's net immobilizes a PLAYER across the live phase order (it lost a turn);
##         pre-fix the env-phase decay cleared S_NETTED before the player's refresh -> a no-op.
##   W2-2  Sentry Turret (anchored, ranged_hold) never MOVEs — it fires or holds; pre-fix it
##         kited/crawled toward the player.
##   W2-3  Riot Shield faces the advancing squad: a head-on shove is BLOCKED (no prone,
##         preview==commit), a flank/rear shove FOLDS, and the AI re-faces to track a flank;
##         pre-fix the frontal facing was inverted so head-on shoves folded it.
##   W2-4  Unaware (ambush-start) enemies WAKE when the fight reaches them (adjacency / damage)
##         and act; pre-fix nothing ever cleared `unaware` (permanently inert Spa car).
##   W2-8  Obstacle-aware BFS stepping closes distance AROUND a wall instead of stalling with
##         full AP; deterministic (stable N,E,S,W tiebreak).
##   W2-9  Lockdown reinforcements are tiered to the car's section (mirror the toughest mobile
##         ordinary enemy present) — a high-section car no longer spawns tail chaff.
##
## Run: godot --headless --path . --script res://tests/enemy_ai_wave2_smoke.gd

const E = preload("res://core/sim_enums.gd")
const SimState = preload("res://core/sim_state.gd")
const SimEntity = preload("res://core/sim_entity.gd")
const IntRng = preload("res://core/int_rng.gd")
const TurnManager = preload("res://core/turn_manager.gd")
const EnemyAI = preload("res://ai/enemy_ai.gd")
const ContentDB = preload("res://core/units/content_db.gd")
const Physics = preload("res://core/physics_resolver.gd")
const MoveCommand = preload("res://core/commands/move_command.gd")
const HazardSystem = preload("res://core/hazard_system.gd")

var _pass: int = 0
var _fail: int = 0
var _fails: Array = []


func _initialize() -> void:
	print("\n=== COLDSPINE — WAVE 2 enemy-AI golden smoke (headless) ===")
	test_net_gunner_immobilizes_player_live_order()   # W2-1
	test_sentry_turret_never_moves()                  # W2-2
	test_sentry_turret_still_fires_in_range()         # W2-2
	test_riot_shield_faces_the_squad_at_spawn()       # W2-3
	test_riot_shield_blocks_frontal_folds_flank()     # W2-3
	test_riot_shield_reface_tracks_flank()            # W2-3
	test_unaware_wakes_when_player_adjacent()         # W2-4
	test_unaware_wakes_on_damage()                    # W2-4
	test_unaware_holds_when_fight_not_joined()        # W2-4 (guard: free opening round kept)
	test_enemy_paths_around_a_wall()                  # W2-8
	test_enemy_pathing_is_deterministic()             # W2-8 (stable tiebreak)
	test_reinforcement_is_section_tiered()            # W2-9
	test_reinforcement_falls_back_when_no_template()  # W2-9 (guard: fallback kept)
	print("\n--- WAVE 2 ENEMY AI: %d passed, %d failed ---" % [_pass, _fail])
	for f in _fails:
		print("    FAIL: " + f)
	if _fail == 0:
		print("WAVE 2 GREEN — net immobilize, anchored turret, shield facing, ambush wake, obstacle pathing, tiered reinforcements all prove out.\n")
	quit(0 if _fail == 0 else 1)


# ---- assertion kit ----
func ok(cond: bool, msg: String) -> void:
	if cond:
		_pass += 1
	else:
		_fail += 1
		_fails.append(msg)
		print("    [FAIL] " + msg)

func eq(a, b, msg: String) -> void:
	ok(a == b, "%s (got %s, want %s)" % [msg, str(a), str(b)])


# ---- scaffolding ----
func _state(w: int, h: int) -> SimState:
	var s := SimState.new()
	s.init_grid(w, h)
	s.rng = IntRng.new(0xC01D5)
	return s

func _mk(s: SimState, x: int, y: int, mass: int, hp: int, faction: int, nm: String,
		profile: int = E.AIProfile.MELEE_RUSH, phys: int = E.PhysTrait.NONE) -> SimEntity:
	var e := SimEntity.new()
	e.is_unit = true
	e.pos = Vector2i(x, y)
	e.mass = mass
	e.hp = hp
	e.integrity = -1
	e.faction = faction
	e.name = nm
	e.ai_profile = profile
	e.phys_trait = phys
	s.add_entity(e)
	return e

func _shield(s: SimState, x: int, y: int) -> SimEntity:
	var db := ContentDB.new()
	var e := SimEntity.new()
	e.is_unit = true
	e.pos = Vector2i(x, y)
	e.mass = E.Mass.MEDIUM
	e.hp = 8
	e.integrity = -1
	e.faction = E.Faction.ENEMY
	e.name = "riot_shield"
	ContentDB.apply_enemy_def(e, db.enemy_def("riot_shield"))   # stamps trait + facing (+x)
	s.add_entity(e)
	return e

func _run_enemy_phase(s: SimState) -> Array:
	var tm := TurnManager.new(s)
	tm.start()
	tm.advance_phase()   # -> ENEMY phase, fresh enemy AP
	return EnemyAI.new().take_phase(tm)

func _has(events: Array, t: int) -> bool:
	for ev in events:
		if ev.type == t:
			return true
	return false

func _manh(a: Vector2i, b: Vector2i) -> int:
	return abs(a.x - b.x) + abs(a.y - b.y)

func _count_enemies(s: SimState) -> int:
	var n: int = 0
	for id in s.entity_ids_sorted():
		var e = s.entities.get(id)
		if e != null and e.is_unit and e.alive and e.faction == E.Faction.ENEMY:
			n += 1
	return n


# ============================ W2-1 — NET GUNNER ================================
func test_net_gunner_immobilizes_player_live_order() -> void:
	print("[W2-1] a Net Gunner's net costs a player its next activation (live PLAYER->ENEMY->ENV->PLAYER order)")
	var s := _state(10, 3)
	var p := _mk(s, 3, 1, E.Mass.MEDIUM, 12, E.Faction.PLAYER, "p")
	_mk(s, 6, 1, E.Mass.LIGHT, 6, E.Faction.ENEMY, "net_gunner", E.AIProfile.RANGED_HOLD)
	var tm := TurnManager.new(s)
	tm.start()                       # round 1 PLAYER phase
	tm.advance_phase()               # -> ENEMY phase
	var evs: Array = EnemyAI.new().take_phase(tm)
	ok(_has(evs, E.Ev.NET), "the net gunner fired its NET (its only attack)")
	ok(s.entities[p.id].has_status(E.S_NETTED), "the player is netted right after the enemy phase")
	tm.advance_phase()               # -> ENVIRONMENT phase
	ok(s.entities[p.id].has_status(E.S_NETTED), "the net SURVIVES the environment phase (pre-fix it was cleared here)")
	tm.advance_phase()               # -> round 2 PLAYER phase refresh
	eq(tm.ap_for(p.id), 0, "the netted player gets 0 AP -> cannot move next turn (pre-fix: full AP no-op)")
	var mv := MoveCommand.new(p.id, [Vector2i(3, 0)])
	ok(not tm.try_command(mv).ok, "the netted player's Move is rejected (immobilized)")
	ok(not s.entities[p.id].has_status(E.S_NETTED), "the net is consumed at that refresh (exactly one lost turn, not permanent)")


# ============================ W2-2 — SENTRY TURRET ============================
func test_sentry_turret_never_moves() -> void:
	print("[W2-2] an anchored Sentry Turret (ranged_hold) holds instead of crawling toward a distant player")
	var s := _state(14, 3)
	_mk(s, 1, 1, E.Mass.MEDIUM, 12, E.Faction.PLAYER, "p")
	var turret := _mk(s, 10, 1, E.Mass.ANCHORED, 8, E.Faction.ENEMY, "sentry_turret",
			E.AIProfile.RANGED_HOLD, E.PhysTrait.STATIC_DESTRUCTIBLE)
	turret.movable = false           # setpiece_loader stamps this for anchored mass
	var start: Vector2i = turret.pos   # d=9 > WEAPON_RANGE(6): no shot -> pre-fix it walked
	_run_enemy_phase(s)
	eq(s.entities[turret.id].pos, start, "the anchored turret did NOT move (pre-fix: crawled toward the player)")

func test_sentry_turret_still_fires_in_range() -> void:
	print("[W2-2] the turret still FIRES when a player is in range (fires or holds — never walks)")
	var s := _state(10, 3)
	_mk(s, 5, 1, E.Mass.MEDIUM, 12, E.Faction.PLAYER, "p")
	var turret := _mk(s, 8, 1, E.Mass.ANCHORED, 8, E.Faction.ENEMY, "sentry_turret",
			E.AIProfile.RANGED_HOLD, E.PhysTrait.STATIC_DESTRUCTIBLE)
	turret.movable = false
	var start: Vector2i = turret.pos
	var evs := _run_enemy_phase(s)
	eq(s.entities[turret.id].pos, start, "the turret held its tile")
	ok(_has(evs, E.Ev.ATTACK_SHOOT), "the turret fired at the in-range player")


# ============================ W2-3 — RIOT SHIELD =============================
func test_riot_shield_faces_the_squad_at_spawn() -> void:
	print("[W2-3] a Riot Shield spawns facing the advancing squad (+x), not inverted (-x)")
	var db := ContentDB.new()
	var e := SimEntity.new()
	e.is_unit = true
	e.faction = E.Faction.ENEMY
	ContentDB.apply_enemy_def(e, db.enemy_def("riot_shield"))
	eq(e.phys_trait, E.PhysTrait.BLOCKS_FRONTAL_SHOVE, "riot_shield carries the frontal-block trait")
	eq(e.facing, Vector2i(1, 0), "facing = +x so a head-on tail->engine shove blocks (pre-fix: -x, inverted)")

func test_riot_shield_blocks_frontal_folds_flank() -> void:
	print("[W2-3] a head-on shove is BLOCKED (no prone, preview==commit); a flank shove FOLDS")
	var s := _state(9, 3)
	var shield := _shield(s, 4, 1)
	# Frontal: the tail-charging squad shoves toward +x == facing -> BLOCKED.
	var fp = Physics.resolve_impulse(s, shield.id, Vector2i(1, 0), E.SHOVE_FORCE, true)
	var fc = Physics.resolve_impulse(s, shield.id, Vector2i(1, 0), E.SHOVE_FORCE, false)
	eq(fp.state.entities[shield.id].pos, Vector2i(4, 1), "a head-on (+x) shove did NOT displace the shield")
	ok(not fp.state.entities[shield.id].has_status(E.S_PRONE), "and did not knock it prone")
	ok(_has(fp.events, E.Ev.SHOVE_RESISTED), "a SHOVE_RESISTED event fired for the frontal block")
	eq(fp.state.entities[shield.id].pos, fc.state.entities[shield.id].pos, "preview == commit for the blocked shove (SACRED)")
	# Flank: a shove perpendicular to facing (dir (0,1)) folds it.
	var fl = Physics.resolve_impulse(s, shield.id, Vector2i(0, 1), E.SHOVE_FORCE, true)
	ok(fl.state.entities[shield.id].pos.y > 1, "a flank (perpendicular) shove folds the shield (it slides)")

func test_riot_shield_reface_tracks_flank() -> void:
	print("[W2-3] the shield re-faces the nearest player each activation (tracks a flanking squad)")
	var s := _state(7, 5)
	var shield := _shield(s, 3, 2)   # spawns facing +x
	_mk(s, 3, 1, E.Mass.MEDIUM, 12, E.Faction.PLAYER, "p")   # player to the NORTH (a flank)
	_run_enemy_phase(s)
	eq(s.entities[shield.id].facing, Vector2i(0, 1), "the shield re-faced the north player (facing left +x, now the push-dir from the north)")
	# A head-on shove from that now-flanking north player is blocked at the new facing.
	var ns = Physics.resolve_impulse(s, shield.id, Vector2i(0, 1), E.SHOVE_FORCE, true)
	ok(_has(ns.events, E.Ev.SHOVE_RESISTED), "a head-on shove from the re-faced direction is now blocked")


# ============================ W2-4 — AMBUSH WAKE =============================
func test_unaware_wakes_when_player_adjacent() -> void:
	print("[W2-4] an Unaware ambusher WAKES when a player steps adjacent, and acts")
	var s := _state(8, 3)
	_mk(s, 4, 1, E.Mass.MEDIUM, 12, E.Faction.PLAYER, "p")
	var e := _mk(s, 5, 1, E.Mass.MEDIUM, 8, E.Faction.ENEMY, "sleeper", E.AIProfile.MELEE_RUSH)
	e.unaware = true
	var evs := _run_enemy_phase(s)
	ok(not s.entities[e.id].unaware, "the ambusher woke (a player was adjacent)")
	ok(evs.size() > 0, "it took an action the same enemy phase (pre-fix: permanently inert)")

func test_unaware_wakes_on_damage() -> void:
	print("[W2-4] a damaged Unaware ambusher wakes and closes on the player")
	var s := _state(10, 3)
	_mk(s, 1, 1, E.Mass.MEDIUM, 12, E.Faction.PLAYER, "p")
	var e := _mk(s, 6, 1, E.Mass.MEDIUM, 8, E.Faction.ENEMY, "sleeper", E.AIProfile.MELEE_RUSH)
	e.unaware = true
	e.hp = 5                          # it took a hit (max_hp was stamped at 8 on spawn)
	var evs := _run_enemy_phase(s)
	ok(not s.entities[e.id].unaware, "a damaged ambusher woke (the fight reached it)")
	ok(evs.size() > 0, "and it acted — engaged the player (pre-fix: permanently inert, zero events)")

func test_unaware_holds_when_fight_not_joined() -> void:
	print("[W2-4] an un-engaged Unaware enemy stays asleep (the operator keeps the free opening round)")
	var s := _state(10, 3)
	_mk(s, 1, 1, E.Mass.MEDIUM, 12, E.Faction.PLAYER, "p")
	var e := _mk(s, 6, 1, E.Mass.MEDIUM, 8, E.Faction.ENEMY, "sleeper", E.AIProfile.MELEE_RUSH)
	e.unaware = true                  # player 5 tiles away, full HP -> not joined
	var start: Vector2i = e.pos
	_run_enemy_phase(s)
	ok(s.entities[e.id].unaware, "the ambusher stays asleep (no adjacency, no damage)")
	eq(s.entities[e.id].pos, start, "and does not move")


# ============================ W2-8 — OBSTACLE PATHING =======================
func test_enemy_paths_around_a_wall() -> void:
	print("[W2-8] an enemy with a WALL between it and the player routes AROUND to reach it")
	# Drive EnemyAI._step_toward directly (isolating pathing from the shoot-when-in-range policy):
	# the old greedy stepper returned `here` — a full-AP stall — the instant the direct step hit
	# the wall. The BFS routes around and reaches a tile adjacent to the player.
	var end_d := _walk_step_toward()
	ok(end_d == 1, "the enemy routed around the wall to the player (adjacent); pre-fix greedy stalled at the wall (got d=%d)" % end_d)

func test_enemy_pathing_is_deterministic() -> void:
	print("[W2-8] the obstacle-aware step is deterministic (stable N,E,S,W tiebreak)")
	var a := _walk_step_toward_path()
	var b := _walk_step_toward_path()
	eq(a, b, "the same wall-routing scenario yields a byte-identical step sequence")

# Walk _step_toward tile-by-tile around a central wall; returns the final manhattan distance.
func _walk_step_toward() -> int:
	return _manh(_walk_step_toward_path()[-1], Vector2i(1, 2))

func _walk_step_toward_path() -> Array:
	var s := _state(7, 5)
	var p := _mk(s, 1, 2, E.Mass.MEDIUM, 12, E.Faction.PLAYER, "p")
	var e := _mk(s, 5, 2, E.Mass.MEDIUM, 8, E.Faction.ENEMY, "rusher", E.AIProfile.MELEE_RUSH)
	s.set_wall(Vector2i(3, 2))        # dead-center on the greedy line -> the old stepper stalled here
	var ai := EnemyAI.new()
	var path: Array = [e.pos]
	var guard: int = 0
	while _manh(e.pos, p.pos) > 1 and guard < 40:
		guard += 1
		var step: Vector2i = ai._step_toward(s, e, p.pos)
		if step == e.pos:
			break   # stalled — no progress
		s.tile(e.pos).occupant_id = -1
		e.pos = step
		s.tile(e.pos).occupant_id = e.id
		path.append(e.pos)
	return path


# ============================ W2-9 — TIERED REINFORCEMENTS ===================
func test_reinforcement_is_section_tiered() -> void:
	print("[W2-9] a high-section lockdown spawns a section-appropriate reinforcement, not tail chaff")
	var s := _state(8, 5)
	_mk(s, 1, 2, E.Mass.MEDIUM, 12, E.Faction.PLAYER, "p")
	var robot := _mk(s, 6, 2, E.Mass.HEAVY, 12, E.Faction.ENEMY, "security_robot", E.AIProfile.ROBOT)
	robot.accuracy = 60
	robot.move_range = 4
	s.reinforce_every = 3
	s.reinforce_timer = 1            # due on this env tick
	s.reinforce_spawns = [Vector2i(7, 0)]
	var before: int = _count_enemies(s)
	var evs := HazardSystem.tick(s)
	ok(_has(evs, E.Ev.SPAWNED), "a reinforcement spawned")
	ok(_count_enemies(s) > before, "a fresh enemy entered play")
	var g = s.occupant_at(Vector2i(7, 0))
	ok(g != null and g.name == "security_robot",
		"the reinforcement mirrors the section's troops (security_robot), not a tier-1 truncheon_guard")

func test_reinforcement_falls_back_when_no_template() -> void:
	print("[W2-9] with no mobile ordinary enemy present, the reinforcement falls back to a tier-1 guard")
	var s := _state(8, 5)
	_mk(s, 1, 2, E.Mass.MEDIUM, 12, E.Faction.PLAYER, "p")
	s.reinforce_every = 3
	s.reinforce_timer = 1
	s.reinforce_spawns = [Vector2i(7, 0)]
	HazardSystem.tick(s)
	var g = s.occupant_at(Vector2i(7, 0))
	ok(g != null and g.name == "truncheon_guard", "no template present -> tier-1 truncheon_guard fallback")
