extends SceneTree
## Wave 3b — FIREBRAND MOMENTUM METER + the 5 remaining level-up abilities, made REAL.
## Run: godot --headless --path . --script res://tests/momentum_smoke.gd
##
## Every check REPRODUCES a pre-fix placebo, so a test that would pass against the OLD build is
## worthless by construction. Before this wave:
##   - `momentum` did not exist on the SimEntity and no combat math read it (the innateTrait was
##     an inert marker) -> a Firebrand's stacks changed NO damage/move/accuracy, capped nothing,
##     and never armed a crit.
##   - ap_on_ally_kill / refund_ability / momentum_gain_on_ally_death / guaranteed_crit sat in
##     AbilitySystem.DEFERRED_KINDS and only push_warning()'d -> Inspire/Overrun/Martyr's Wake/
##     Vanguard were dead picks.
##   - downed_fights_one_turn was deferred -> Steward Last Stand did nothing (the downed body just
##     stayed downed).
## Each test below drives the REAL wired path and asserts the documented effect.

const E = preload("res://core/sim_enums.gd")
const SimState = preload("res://core/sim_state.gd")
const SimEntity = preload("res://core/sim_entity.gd")
const IntRng = preload("res://core/int_rng.gd")
const TurnManager = preload("res://core/turn_manager.gd")
const ContentDB = preload("res://core/units/content_db.gd")
const UnitInstance = preload("res://core/units/unit_instance.gd")
const AbilitySystem = preload("res://core/ability_system.gd")
const AbilityCommand = preload("res://core/commands/ability_command.gd")
const BleedoutSystem = preload("res://core/bleedout_system.gd")

var _pass: int = 0
var _fail: int = 0
var _fails: Array = []
var db: ContentDB


func _initialize() -> void:
    db = ContentDB.new()
    print("\n=== COLDSPINE — momentum smoke (Wave 3b: Firebrand meter + level-up abilities) ===")
    test_registry_kinds_now_handled()
    test_car_clear_gain_and_cap()
    test_combat_mods_baked_at_spawn()
    test_zeal_accuracy_per_stack()
    test_vanguard_arms_only_at_max()
    test_vanguard_autocrit_fires_and_is_consumed()
    test_vanguard_rearms_each_player_phase()
    test_momentum_resets_on_ally_permadeath()
    test_martyrs_wake_gains_instead_of_losing()
    test_inspire_ally_kill_grants_ap()
    test_overrun_kill_refunds_action()
    test_last_stand_defiant_turn_then_dies()
    test_determinism_nonfirebrand_byte_identical()
    test_determinism_momentum_survives_clone()
    print("\n--- MOMENTUM WAVE3b: %d passed, %d failed ---" % [_pass, _fail])
    for f in _fails:
        print("    FAIL: " + f)
    if _fail == 0:
        print("MOMENTUM GREEN — the Firebrand meter + all 5 level-up abilities are REAL.\n")
    quit(0 if _fail == 0 else 1)


# ---- assertion kit (mirrors the other suites) ----
func ok(cond: bool, msg: String) -> void:
    if cond:
        _pass += 1
    else:
        _fail += 1
        _fails.append(msg)
        print("    [FAIL] " + msg)

func eq(a, b, msg: String) -> void:
    ok(a == b, "%s (got %s, want %s)" % [msg, str(a), str(b)])


# ---- builders ----
func new_state(w: int, h: int) -> SimState:
    var s := SimState.new()
    s.init_grid(w, h)
    s.rng = IntRng.new(0xC01D5)
    return s

## A drafted Firebrand roster instance with optional tree picks (e.g. ["zeal"], ["vanguard"]).
func firebrand_inst(pick: Array = [], mom: int = 0, iid: int = 100) -> UnitInstance:
    var u := UnitInstance.from_archetype(db, "firebrand", [], "FB", iid)
    for a in pick:
        u.chosen_abilities.append(a)
    u.momentum = mom
    return u

## Spawn a roster instance's combat body into the state at (x,y).
func spawn(s: SimState, u: UnitInstance, x: int, y: int, faction: int = E.Faction.PLAYER) -> SimEntity:
    u.faction = faction
    var e := u.to_sim_entity(db, Vector2i(x, y))
    e.faction = faction
    s.add_entity(e)
    return e

## A plain combat body (enemy / non-Firebrand ally) built by hand.
func add_unit(s: SimState, x: int, y: int, faction: int, nm: String, hp: int = 8, iid: int = -1) -> SimEntity:
    var e := SimEntity.new()
    e.is_unit = true
    e.pos = Vector2i(x, y)
    e.mass = E.Mass.MEDIUM
    e.hp = hp
    e.integrity = -1
    e.faction = faction
    e.name = nm
    e.instance_id = iid
    s.add_entity(e)
    return e


# --- W3-4: the 5 kinds moved from inert/deferred to genuinely handled ------------
func test_registry_kinds_now_handled() -> void:
    print("[registry] the 5 dead picks are now handled (out of the DEFERRED do-nothing allowlist)")
    ok(AbilitySystem.ACTIVE_KINDS.has("downed_fights_one_turn"),
        "downed_fights_one_turn (Last Stand) is now an ACTIVE effect")
    for k in ["ap_on_ally_kill", "refund_ability", "momentum_gain_on_ally_death", "guaranteed_crit"]:
        ok(AbilitySystem.PASSIVE_KINDS.has(k), "%s is now a wired PASSIVE marker" % k)
    for k in ["ap_on_ally_kill", "refund_ability", "momentum_gain_on_ally_death",
            "guaranteed_crit", "downed_fights_one_turn"]:
        ok(not AbilitySystem.DEFERRED_KINDS.has(k),
            "%s left the loud DEFERRED (do-nothing) allowlist" % k)


# --- W3-7: momentum accrues per car cleared and caps at MAX -----------------------
func test_car_clear_gain_and_cap() -> void:
    print("[momentum] +1 per car cleared for each living Firebrand; caps at MOMENTUM_MAX; skips others/dead")
    var fb := firebrand_inst([], 0, 100)
    var other := UnitInstance.from_archetype(db, "bruiser", [], "BR", 101)  # no momentum mechanic
    var dead_fb := firebrand_inst([], 2, 102)
    dead_fb.dead = true
    var squad := [fb, other, dead_fb]
    var evs: Array = []
    for i in range(5):   # clear five cars in a row
        AbilitySystem.grant_car_clear_momentum(db, squad, evs)
    eq(fb.momentum, E.MOMENTUM_MAX, "the living Firebrand accrued a stack per car, capped at MAX")
    eq(other.momentum, 0, "a non-Firebrand never accrues momentum")
    eq(dead_fb.momentum, 2, "a dead Firebrand is skipped (no accrual)")
    # A MOMENTUM_CHANGED event fires only while the stack actually moves (MAX..MAX emits nothing).
    var changes := 0
    for ev in evs:
        if ev.type == E.Ev.MOMENTUM_CHANGED:
            changes += 1
    eq(changes, E.MOMENTUM_MAX, "one MOMENTUM_CHANGED per real stack gain (none once capped)")


# --- W3-7: entry momentum bakes damage + move onto the combat body ---------------
func test_combat_mods_baked_at_spawn() -> void:
    print("[momentum] entry stacks bake +damage/stack and +Move at the threshold onto the spawned body")
    var s := new_state(8, 4)
    var e0 := spawn(s, firebrand_inst([], 0, 100), 1, 1)   # 0 stacks — a clean baseline
    var base_move := int(db.archetype("firebrand").baseStats.get("move", E.MOVE_RANGE))
    eq(e0.damage_bonus, 0, "a 0-stack Firebrand gets NO damage bonus (byte-identical baseline)")
    eq(e0.move_range, base_move, "a 0-stack Firebrand keeps its base Move")
    ok(e0.has_momentum, "the body is tagged as a momentum unit (data-driven, from innateTrait)")

    var e3 := spawn(s, firebrand_inst([], 3, 101), 3, 1)
    eq(e3.damage_bonus, 3 * E.MOMENTUM_DMG_PER_STACK, "3 stacks -> +3 damage")
    eq(e3.move_range, base_move + E.MOMENTUM_MOVE_BONUS, "3 stacks (>= threshold) -> +Move")

    var e1 := spawn(s, firebrand_inst([], 1, 102), 5, 1)
    eq(e1.move_range, base_move, "1 stack (< threshold) -> no +Move yet")
    eq(e1.damage_bonus, 1, "1 stack -> +1 damage")


func test_zeal_accuracy_per_stack() -> void:
    print("[zeal] with Zeal picked, momentum ALSO raises accuracy (per stack); without it, it does not")
    var s := new_state(8, 4)
    var base_acc := int(db.archetype("firebrand").baseStats.get("accuracy", E.BASE_ACCURACY))
    var ez := spawn(s, firebrand_inst(["zeal"], 2, 100), 1, 1)
    eq(ez.accuracy, base_acc + 2 * E.MOMENTUM_ACC_PER_STACK, "Zeal: +accuracy per stack")
    var en := spawn(s, firebrand_inst([], 2, 101), 3, 1)  # no Zeal
    eq(en.accuracy, base_acc, "no Zeal -> momentum leaves accuracy untouched")


func test_vanguard_arms_only_at_max() -> void:
    print("[vanguard] the first-strike autocrit arms ONLY at MAX momentum (and only if Vanguard is picked)")
    var s := new_state(8, 4)
    ok(spawn(s, firebrand_inst(["vanguard"], E.MOMENTUM_MAX, 100), 1, 1).first_attack_autocrit,
        "Vanguard at MAX momentum -> autocrit armed")
    ok(not spawn(s, firebrand_inst(["vanguard"], E.MOMENTUM_MAX - 1, 101), 3, 1).first_attack_autocrit,
        "Vanguard below MAX -> not armed")
    ok(not spawn(s, firebrand_inst([], E.MOMENTUM_MAX, 102), 5, 1).first_attack_autocrit,
        "MAX momentum but no Vanguard pick -> not armed")


# --- W3-7 capstone: the Vanguard autocrit is a GUARANTEED hit that crits, then is spent ---
func test_vanguard_autocrit_fires_and_is_consumed() -> void:
    print("[vanguard] an armed autocrit skips the to-hit roll (guaranteed), adds crit damage, then is consumed")
    var s := new_state(10, 3)
    var fb := spawn(s, firebrand_inst(["vanguard"], E.MOMENTUM_MAX, 100), 1, 1)
    # A distant, hard target so a NORMAL roll could miss — the autocrit must land regardless.
    var enemy := add_unit(s, 8, 1, E.Faction.ENEMY, "guard", 40)
    ok(fb.first_attack_autocrit, "precondition: autocrit is armed")
    var base_dmg: int = E.SHOOT_DAMAGE_BASE + fb.damage_bonus   # a MAX-momentum body also carries +dmg/stack

    var rng_before: int = s.rng.state
    var evs: Array = []
    AbilitySystem._do_attack(s, fb, enemy, {"kind": "melee_attack"}, evs, {})
    eq(s.rng.state, rng_before, "the autocrit drew NOTHING from the rng (guaranteed hit — no roll)")
    ok(not fb.first_attack_autocrit, "the autocrit was consumed after the strike")
    var hit_dmg := -1
    var missed := false
    for ev in evs:
        if ev.type == E.Ev.MISS:
            missed = true
        if ev.type == E.Ev.HIT and int(ev.data.get("target", -1)) == enemy.id:
            hit_dmg = int(ev.data.get("dmg", 0))
    ok(not missed, "the guaranteed autocrit did not miss")
    eq(hit_dmg, base_dmg + E.MOMENTUM_CRIT_BONUS, "crit damage = base(+momentum dmg) + MOMENTUM_CRIT_BONUS")

    # The NEXT strike is an ordinary attack: it consults the rng (proving the first one skipped it).
    var rng_before2: int = s.rng.state
    AbilitySystem._do_attack(s, fb, enemy, {"kind": "melee_attack"}, [], {})
    ok(s.rng.state != rng_before2, "the follow-up (non-autocrit) attack DID roll the rng")


func test_vanguard_rearms_each_player_phase() -> void:
    print("[vanguard] the autocrit re-arms at the Firebrand's PLAYER-phase refresh while at MAX momentum")
    var s := new_state(6, 3)
    var fb := spawn(s, firebrand_inst(["vanguard"], E.MOMENTUM_MAX, 100), 1, 1)
    add_unit(s, 4, 1, E.Faction.ENEMY, "guard", 40)   # keep the fight going
    fb.first_attack_autocrit = false                  # pretend it was spent last turn
    var tm := TurnManager.new(s)
    tm.start()                                        # opens on the PLAYER phase
    ok(fb.first_attack_autocrit, "the PLAYER-phase refresh re-armed the autocrit at MAX momentum")
    # Drop below MAX: the refresh must NOT re-arm.
    fb.momentum = E.MOMENTUM_MAX - 1
    fb.first_attack_autocrit = false
    var tm2 := TurnManager.new(s)
    tm2.start()
    ok(not fb.first_attack_autocrit, "below MAX, the refresh does not re-arm")


# --- W3-7: an ally's permadeath saps a Firebrand's stacks ------------------------
func test_momentum_resets_on_ally_permadeath() -> void:
    print("[momentum] a PLAYER permadeath resets each surviving Firebrand's stacks to 0")
    var s := new_state(8, 3)
    var fb := spawn(s, firebrand_inst([], E.MOMENTUM_MAX, 100), 1, 1)
    var ally := add_unit(s, 2, 1, E.Faction.PLAYER, "bruiser", 8, 101)
    eq(fb.momentum, E.MOMENTUM_MAX, "precondition: the Firebrand is at MAX")
    var evs: Array = []
    BleedoutSystem.permadeath(s, ally, evs)           # the ally is permanently lost
    eq(fb.momentum, 0, "the fallen comrade broke the Firebrand's tempo -> 0 stacks")
    var saw_change := false
    for ev in evs:
        if ev.type == E.Ev.MOMENTUM_CHANGED and int(ev.data.get("id", -1)) == fb.id:
            saw_change = true
    ok(saw_change, "the reset emitted MOMENTUM_CHANGED")


func test_martyrs_wake_gains_instead_of_losing() -> void:
    print("[martyr] with Martyr's Wake picked, an ally's death grants a BURST of stacks (flips the downside)")
    var s := new_state(8, 3)
    var martyr := spawn(s, firebrand_inst(["martyrs_wake"], 0, 100), 1, 1)
    var plain := spawn(s, firebrand_inst([], E.MOMENTUM_MAX, 101), 2, 1)
    var ally := add_unit(s, 3, 1, E.Faction.PLAYER, "bruiser", 8, 102)
    ok(martyr.momentum_martyr, "precondition: Martyr's Wake marker is wired on")
    var evs: Array = []
    BleedoutSystem.permadeath(s, ally, evs)
    ok(martyr.momentum > 0, "Martyr's Wake gained stacks from the death (a burst, not a loss)")
    eq(martyr.momentum, min(E.MOMENTUM_MAX, martyr.martyr_gain), "the burst is min(MAX, authored amount)")
    eq(plain.momentum, 0, "a Firebrand WITHOUT Martyr's Wake still loses its stacks")


# --- W3-4 Inspire: ally kills grant the Firebrand AP -----------------------------
func test_inspire_ally_kill_grants_ap() -> void:
    print("[inspire] when an ally kills an enemy, a Firebrand that picked Inspire gains AP")
    var s := new_state(8, 3)
    var fb := spawn(s, firebrand_inst(["inspire"], 0, 100), 1, 1)
    eq(fb.inspire_ap, 1, "Inspire wired the AP-on-ally-kill marker onto the body")
    var ally := add_unit(s, 2, 1, E.Faction.PLAYER, "bruiser", 8, 101)
    var enemy := add_unit(s, 3, 1, E.Faction.ENEMY, "guard", 1)
    s.bleedout_enabled = true
    var tm := TurnManager.new(s)
    tm.start()
    var before: int = tm.ap_for(fb.id)
    var evs: Array = []
    enemy.hp = 0
    # The ally's killing blow funnels through the single death path with killer + turn supplied.
    BleedoutSystem.down_or_kill(s, enemy, evs, ally.id, tm)
    eq(tm.ap_for(fb.id), before + 1, "the ally's kill inspired the Firebrand (+1 AP)")
    var saw := false
    for ev in evs:
        if ev.type == E.Ev.GRANT_AP and int(ev.data.get("id", -1)) == fb.id and ev.data.get("inspire", false):
            saw = true
    ok(saw, "a GRANT_AP(inspire) event was emitted for the Firebrand")

    # Control: the SAME kill without a killer/turn (physics/env path) inspires no one.
    var s2 := new_state(8, 3)
    var fb2 := spawn(s2, firebrand_inst(["inspire"], 0, 100), 1, 1)
    var enemy2 := add_unit(s2, 3, 1, E.Faction.ENEMY, "guard", 1)
    s2.bleedout_enabled = true
    var evs2: Array = []
    enemy2.hp = 0
    BleedoutSystem.down_or_kill(s2, enemy2, evs2)   # no killer, no turn
    for ev in evs2:
        ok(ev.type != E.Ev.GRANT_AP, "an un-attributed kill (no killer/turn) grants no inspire AP")


# --- W3-4 Overrun: the actor's kill refunds an action ----------------------------
func test_overrun_kill_refunds_action() -> void:
    print("[overrun] the actor's own kill refunds an action (a bonus Lunge)")
    var s := new_state(8, 3)
    var fb := spawn(s, firebrand_inst(["overrun"], 0, 100), 1, 1)
    ok(fb.refund_lunge_on_kill, "Overrun wired the refund-on-kill marker onto the body")
    var enemy := add_unit(s, 2, 1, E.Faction.ENEMY, "guard", 1)
    var tm := TurnManager.new(s)
    tm.start()
    var before: int = tm.ap_for(fb.id)
    var evs: Array = []
    AbilitySystem._do_attack(s, fb, enemy, {"kind": "melee_attack", "guaranteedHit": true}, evs, {"turn": tm})
    ok(not enemy.alive or enemy.hp <= 0, "precondition: the attack killed the enemy")
    eq(tm.ap_for(fb.id), before + 1, "the kill refunded an action (+1 AP)")
    var saw := false
    for ev in evs:
        if ev.type == E.Ev.GRANT_AP and ev.data.get("refund", false):
            saw = true
    ok(saw, "a GRANT_AP(refund) event was emitted")

    # Control: a Firebrand WITHOUT Overrun gets no refund on a kill.
    var s2 := new_state(8, 3)
    var fb2 := spawn(s2, firebrand_inst([], 0, 101), 1, 1)
    var enemy2 := add_unit(s2, 2, 1, E.Faction.ENEMY, "guard", 1)
    var tm2 := TurnManager.new(s2)
    tm2.start()
    var b2: int = tm2.ap_for(fb2.id)
    AbilitySystem._do_attack(s2, fb2, enemy2, {"kind": "melee_attack", "guaranteedHit": true}, [], {"turn": tm2})
    eq(tm2.ap_for(fb2.id), b2, "no Overrun -> no refund")


# --- W3-4 Last Stand: a downed ally you reach fights one turn, THEN dies ----------
func test_last_stand_defiant_turn_then_dies() -> void:
    print("[last_stand] Steward Last Stand revives a downed ally for one defiant turn, then it permadies")
    var s := new_state(8, 3)
    s.bleedout_enabled = true
    var steward := add_unit(s, 1, 1, E.Faction.PLAYER, "steward", 8, 200)
    var downed := add_unit(s, 2, 1, E.Faction.PLAYER, "bruiser", 8, 201)
    # Put the ally into the Downed (Bleeding) window the honest way.
    downed.hp = 0
    BleedoutSystem.down_or_kill(s, downed, [])
    ok(downed.downed and not downed.alive, "precondition: the ally is downed and cannot act")

    var evs: Array = []
    AbilitySystem.execute(s, db.ability("last_stand"), {"actor": steward.id, "target_id": downed.id})
    # (execute() ran the wired _do_last_stand; capture nothing else.)
    ok(downed.alive, "Last Stand revived the body to fight")
    ok(not downed.downed, "the revived body is no longer flagged downed")
    ok(downed.hp >= 1, "it stands on a defiant last breath (>= 1 HP)")
    eq(downed.last_stand, E.LAST_STAND_TURNS, "its borrowed-time counter is armed")

    # It CAN act on its defiant turn: a PLAYER refresh hands it AP.
    var tm := TurnManager.new(s)
    tm.start()
    ok(tm.ap_for(downed.id) > 0, "the revived ally gets AP to take its one action")

    # Borrowed time runs out over the env phases -> it permadies (permadeath stays sacred).
    var died := false
    for i in range(E.LAST_STAND_TURNS):
        var t: Array = BleedoutSystem.tick(s)
        for ev in t:
            if ev.type == E.Ev.UNIT_PERMADEATH and int(ev.data.get("id", -1)) == downed.id:
                died = true
    ok(died, "after its defiant turn, Last Stand's body permadied (it bought a turn, not immortality)")
    ok(not s.entities.has(downed.id), "the body was removed from play on permadeath")


# --- DETERMINISM GUARD: the momentum fields never perturb a pre-momentum fingerprint ---
func test_determinism_nonfirebrand_byte_identical() -> void:
    print("[determinism] non-Firebrand / 0-stack states emit NO momentum token -> byte-identical")
    var s := new_state(6, 3)
    add_unit(s, 1, 1, E.Faction.PLAYER, "bruiser", 8, 100)
    add_unit(s, 4, 1, E.Faction.ENEMY, "guard", 6)
    ok(not s.snapshot().contains(" mo="), "a non-Firebrand state carries no momentum token")

    var s2 := new_state(6, 3)
    spawn(s2, firebrand_inst([], 0, 100), 1, 1)   # a fresh Firebrand at 0 stacks
    ok(not s2.snapshot().contains(" mo="), "a 0-stack Firebrand carries no momentum token either")

    var s3 := new_state(6, 3)
    spawn(s3, firebrand_inst([], 2, 100), 1, 1)   # 2 stacks -> the token appears
    ok(s3.snapshot().contains("mo=2"), "a Firebrand WITH stacks does surface a momentum token")


func test_determinism_momentum_survives_clone() -> void:
    print("[determinism] clone()/adopt() preserve momentum + an armed autocrit (no preview!=commit hole)")
    var s := new_state(6, 3)
    var fb := spawn(s, firebrand_inst(["vanguard"], E.MOMENTUM_MAX, 100), 1, 1)
    fb.last_stand = 1
    var before := s.snapshot()
    var c := s.clone()
    eq(c.snapshot(), before, "a clone's fingerprint matches the original (momentum/autocrit/last_stand ride along)")
    eq(c.entities[fb.id].momentum, E.MOMENTUM_MAX, "the cloned body kept its stacks")
    ok(c.entities[fb.id].first_attack_autocrit, "the cloned body kept its armed autocrit")
    eq(c.entities[fb.id].last_stand, 1, "the cloned body kept its Last Stand counter")
