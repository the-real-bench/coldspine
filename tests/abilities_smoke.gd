extends SceneTree
## Wave 3 (abilities lane) — progression-real ability wiring.
## Run: godot --headless --path . --script res://tests/abilities_smoke.gd
##
## Guards the ONE level-up ability this wave wires end-to-end inside the ability system:
##   overclock_hack (Saboteur T2)  — grants each currently-HACKED ally an extra action.
## Every check below FAILS against the pre-fix build (where `hacked_units_extra_action`
## sat in AbilitySystem.DEFERRED_KINDS and casting the pick only push_warning()'d and did
## nothing), so the test genuinely reproduces the placebo it replaces.
##
## The other five picks (inspire / martyrs_wake / overrun / vanguard / last_stand) and the
## whole Firebrand momentum meter need per-entity SimEntity state + kill/death trigger hooks
## in bleedout/turn_manager + car-clear accrual in run_controller — all OUT of the abilities
## lane — so they are FLAGGED in the wave report, not implemented here.

const SimState = preload("res://core/sim_state.gd")
const SimEntity = preload("res://core/sim_entity.gd")
const IntRng = preload("res://core/int_rng.gd")
const Enums = preload("res://core/sim_enums.gd")
const TurnManager = preload("res://core/turn_manager.gd")
const ContentDB = preload("res://core/units/content_db.gd")
const AbilityCommand = preload("res://core/commands/ability_command.gd")
const AbilitySystem = preload("res://core/ability_system.gd")

var _pass: int = 0
var _fail: int = 0
var _fails: Array = []

func _initialize() -> void:
	print("\n=== COLDSPINE — abilities smoke (Wave 3: progression-real ability wiring) ===")
	test_overclock_kind_is_wired_not_deferred()
	test_overclock_grants_hacked_ally_extra_action()
	test_overclock_spares_roster_heroes()
	test_overclock_no_hacked_units_is_noop()
	test_flagged_kinds_now_genuinely_wired()
	print("\n--- RESULTS: %d passed, %d failed ---" % [_pass, _fail])
	for f in _fails:
		print("    FAIL: " + f)
	if _fail == 0:
		print("ALL GREEN — abilities lane wiring proven.\n")
	quit(0 if _fail == 0 else 1)

# ---- tiny assertion kit (mirrors run_tests.gd) ----
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

## A combat body. `instance_id` defaults to -1 (a transient body — what a hacked enemy is);
## pass a roster id (>=0) to model a drafted hero.
func add_unit(s: SimState, x: int, y: int, faction: int, nm: String, instance_id: int = -1) -> SimEntity:
	var e := SimEntity.new()
	e.is_unit = true
	e.pos = Vector2i(x, y)
	e.mass = Enums.Mass.MEDIUM
	e.hp = 8
	e.integrity = -1
	e.faction = faction
	e.name = nm
	e.instance_id = instance_id
	s.add_entity(e)
	return e

# --- registry: the kind moved from "deferred/inert" to "handled" -----------------
func test_overclock_kind_is_wired_not_deferred() -> void:
	print("[overclock] the kind is now a handled ACTIVE effect, no longer a loud no-op")
	ok(AbilitySystem.ACTIVE_KINDS.has("hacked_units_extra_action"),
		"hacked_units_extra_action is in ACTIVE_KINDS")
	ok(not AbilitySystem.DEFERRED_KINDS.has("hacked_units_extra_action"),
		"hacked_units_extra_action is no longer on the DEFERRED (do-nothing) allowlist")

# --- the real effect: a hacked unit gets an extra action -------------------------
func test_overclock_grants_hacked_ally_extra_action() -> void:
	print("[overclock] casting overclock_hack grants each hacked ally +1 AP (an extra action)")
	var db := ContentDB.new()
	var s := new_state(8, 3)
	var sab := add_unit(s, 1, 1, Enums.Faction.PLAYER, "saboteur", 100)  # roster hero
	sab.archetype_id = "saboteur"
	var bot := add_unit(s, 3, 1, Enums.Faction.ENEMY, "sentry_turret")   # transient (instance_id -1)

	# Convert the turret with the Saboteur's real `hack` ability (shipped JSON).
	AbilitySystem.execute(s, db.ability("hack"), {"actor": sab.id, "target_id": bot.id})
	eq(bot.faction, Enums.Faction.PLAYER, "hack flipped the turret onto the player faction")

	var tm := TurnManager.new(s)
	tm.start()   # PLAYER phase: both PLAYER-faction bodies get AP_PER_TURN
	var before_bot: int = tm.ap_for(bot.id)
	eq(before_bot, Enums.AP_PER_TURN, "the hacked turret refreshed to base AP")

	# Cast the real overclock_hack pick through the command layer (apCost 0, self, no end-turn).
	var cmd := AbilityCommand.new(sab.id, db.ability("overclock_hack"))
	var res: Dictionary = tm.try_command(cmd)
	ok(res.ok, "overclock_hack cast accepted: " + str(res.reason))

	# PRE-FIX PLACEBO: before this wave the kind was deferred → this AP was unchanged.
	eq(tm.ap_for(bot.id), before_bot + 1, "the hacked turret gained an extra action (+1 AP)")
	var saw_grant := false
	for ev in res.events:
		if ev.type == Enums.Ev.GRANT_AP and int(ev.data.get("id", -1)) == bot.id:
			saw_grant = true
	ok(saw_grant, "a GRANT_AP event was emitted for the hacked turret")

# --- the transient-body gate: roster heroes never receive the grant --------------
func test_overclock_spares_roster_heroes() -> void:
	print("[overclock] the caster + drafted allies (roster heroes) do NOT get the extra action")
	var db := ContentDB.new()
	var s := new_state(8, 3)
	var sab := add_unit(s, 1, 1, Enums.Faction.PLAYER, "saboteur", 100)
	var ally := add_unit(s, 2, 1, Enums.Faction.PLAYER, "bruiser", 101)   # roster hero
	var bot := add_unit(s, 3, 1, Enums.Faction.ENEMY, "sentry_turret")
	AbilitySystem.execute(s, db.ability("hack"), {"actor": sab.id, "target_id": bot.id})

	var tm := TurnManager.new(s)
	tm.start()
	var before_sab: int = tm.ap_for(sab.id)
	var before_ally: int = tm.ap_for(ally.id)
	var res: Dictionary = tm.try_command(AbilityCommand.new(sab.id, db.ability("overclock_hack")))
	ok(res.ok, "overclock_hack cast accepted")
	eq(tm.ap_for(sab.id), before_sab, "the Saboteur caster (roster hero) kept its normal AP")
	eq(tm.ap_for(ally.id), before_ally, "the drafted ally (roster hero) got no extra action")
	eq(tm.ap_for(bot.id), Enums.AP_PER_TURN + 1, "only the hacked (transient) turret was overclocked")

# --- no hacked units in play: a harmless no-op cast ------------------------------
func test_overclock_no_hacked_units_is_noop() -> void:
	print("[overclock] with no hacked units, the cast is a harmless no-op (never buffs heroes)")
	var db := ContentDB.new()
	var s := new_state(8, 3)
	var sab := add_unit(s, 1, 1, Enums.Faction.PLAYER, "saboteur", 100)
	var ally := add_unit(s, 2, 1, Enums.Faction.PLAYER, "bruiser", 101)
	var tm := TurnManager.new(s)
	tm.start()
	var before_ally: int = tm.ap_for(ally.id)
	var res: Dictionary = tm.try_command(AbilityCommand.new(sab.id, db.ability("overclock_hack")))
	ok(res.ok, "overclock_hack cast accepted even with nothing to overclock")
	eq(tm.ap_for(ally.id), before_ally, "no hacked units -> no AP granted to anyone")

# --- Wave 3b: the previously-flagged kinds are now GENUINELY wired ------------------
# The 5 picks + the momentum meter were deferred pending out-of-lane state/hooks; Wave 3b added the
# SimEntity fields + death-funnel/turn/shoot hooks, so they left the DEFERRED allowlist for real.
# This guard is the INVERSE of the old one: it now fails if any kind regresses back to deferred /
# unhandled, so the wiring can't silently rot.
func test_flagged_kinds_now_genuinely_wired() -> void:
	print("[flag] the momentum/trigger-gated kinds are now GENUINELY wired (Wave 3b)")
	ok(AbilitySystem.ACTIVE_KINDS.has("downed_fights_one_turn"),
		"downed_fights_one_turn (Last Stand) is a wired ACTIVE effect")
	for kind in ["ap_on_ally_kill", "momentum_gain_on_ally_death", "refund_ability", "guaranteed_crit"]:
		ok(AbilitySystem.PASSIVE_KINDS.has(kind), "%s is a wired PASSIVE marker" % kind)
	for kind in ["ap_on_ally_kill", "momentum_gain_on_ally_death", "refund_ability",
			"guaranteed_crit", "downed_fights_one_turn"]:
		ok(not AbilitySystem.DEFERRED_KINDS.has(kind), "%s left the DEFERRED allowlist" % kind)
