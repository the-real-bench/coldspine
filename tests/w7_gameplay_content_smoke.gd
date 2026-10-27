extends SceneTree
## WAVE 7 — gameplay-content lane smoke. NEW suite. Each test REPRODUCES the pre-fix gap so it could
## not pass against the old build:
##   W3-2  EQUIPMENT reward-drops are reliably acquirable in a real run (shop-only left shopless runs
##         with zero weapons/armor) — reached at a REAL combat/captain car; an equipped one confers stat.
##   W7-1  Section-2 combat deck has >=3 distinct templates + a generated S2 line can draw a
##         non-security_02 combat car (was ONE template — every S2 combat the identical deadliest room).
##   W3-8  Events are DATA-DRIVEN (eventBeat contract): >=4 distinct events with distinct payloads;
##         trait_gain grants a trait; ambush routes to combat; shortcut skips a car; byte-stable resolve.
##   W7-8  A resumed checkpoint on a resolved-but-not-advanced combat car is NOT re-fought.
##   W7-9  A win mid-player-phase releases the phase (no manual END parade on a cleared board).
##   W7-10 The 60-round guard warns as it approaches + reports the REAL cause (never a silent bogus LOSS).
##   W7-11 ESC on the BOURGEOIS moral fork does NOT auto-commit SPARE.
##   W7-13 Betrayal/defection survives save/resume at a captain car (the defector is restored).
##
## Run: godot --headless --path . --script res://tests/w7_gameplay_content_smoke.gd

const E = preload("res://core/sim_enums.gd")
const RunController = preload("res://app/run_controller.gd")
const RunGenerator = preload("res://core/run/run_generator.gd")
const RunState = preload("res://core/run/run_state.gd")
const CarInstance = preload("res://core/run/car_instance.gd")
const ContentDB = preload("res://core/units/content_db.gd")
const UnitInstance = preload("res://core/units/unit_instance.gd")
const TurnManager = preload("res://core/turn_manager.gd")
const SaveSystem = preload("res://core/meta/save_system.gd")

const SEED := 0xC01D5

var _pass: int = 0
var _fail: int = 0
var _fails: Array = []


func _initialize() -> void:
	SaveSystem.force_sandbox = true   # never touch the owner's real profile/run
	print("\n=== COLDSPINE — WAVE 7 gameplay-content smoke ===")
	test_w7_1_section2_combat_deck_variety()
	test_w3_2_equipment_reward_reached_in_real_run()
	test_w3_2_equipped_item_confers_stat()
	test_w3_8_events_are_data_driven_and_distinct()
	test_w3_8_trait_gain_grants_a_trait()
	test_w3_8_ambush_routes_to_combat()
	test_w3_8_shortcut_skips_a_car()
	test_w3_8_event_resolve_is_byte_stable()
	test_w7_8_resumed_resolved_combat_is_not_refought()
	test_w7_9_midphase_win_releases_the_phase()
	test_w7_10_guard_warns_and_reports_real_cause()
	test_w7_11_bourgeois_esc_does_not_autocommit_spare()
	test_w7_13_betrayal_survives_save_resume()
	print("\n--- WAVE 7 CONTENT SMOKE: %d passed, %d failed ---" % [_pass, _fail])
	for f in _fails:
		print("    FAIL: " + f)
	if _fail == 0:
		print("WAVE 7 CONTENT GREEN — reward-drops, S2 variety, data-events, and the flow fixes all prove out.\n")
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


# ============================ W7-1: Section-2 combat variety =====================
func test_w7_1_section2_combat_deck_variety() -> void:
	# DECK: the authored library has >=3 distinct SECTION-2 combat templates (pre-fix: exactly ONE,
	# combat_security_02 — every S2 combat car was the identical deadliest room).
	var s2_combat: Dictionary = {}
	for t in RunGenerator._load_templates():
		if String(t.get("type", "")) == "combat" and int(t.get("section", -1)) == 2:
			s2_combat[String(t.get("id", ""))] = true
	ok(s2_combat.size() >= 3, "[w7-1] Section-2 combat deck has >=3 distinct templates (found %d: %s)" % [s2_combat.size(), str(s2_combat.keys())])
	ok(s2_combat.has("combat_security_02"), "[w7-1] the original deadliest room is still present")
	# REACHED: across a seed sweep a generated S2 line actually DRAWS a non-security_02 combat car (so
	# the variety is not merely authored — it reaches a real run at a real Section-2 car).
	var drawn: Dictionary = {}
	var saw_non_security := false
	for s in range(60):
		for c in RunGenerator.generate_run(0xB000 + s):
			if c.car_type == E.CarType.COMBAT and c.section == E.Section.THIRD:
				drawn[c.template_id] = true
				if c.template_id != "combat_security_02":
					saw_non_security = true
	ok(drawn.size() >= 2, "[w7-1] a seed sweep draws >=2 distinct S2 combat templates in real lines (%s)" % str(drawn.keys()))
	ok(saw_non_security, "[w7-1] a generated S2 line DRAWS a non-security_02 combat car (variety is reached)")


# ============================ W3-2: equipment reward-drops =======================
func test_w3_2_equipment_reward_reached_in_real_run() -> void:
	# A generated run REACHES an EQUIPMENT reward at a REAL combat/captain car (pre-fix: no reward table
	# dropped gear, so a shopless line got ZERO weapons/armor). Asserts AT THE ACTUAL reward car — the
	# specific car whose rolled reward is equipment — not that every position grants equipment.
	var r := RunState.new_run(SEED, _squad(), E.DRAFT_PAYOUT_X3)
	var eq_idx := -1
	for i in range(r.line.size()):
		if String(r.line[i].reward.get("kind", "")) == "equipment":
			eq_idx = i
			break
	ok(eq_idx >= 0, "[w3-2] a real generated run REACHES an equipment reward on the line")
	if eq_idx < 0:
		return
	var car = r.line[eq_idx]
	ok(car.car_type == E.CarType.COMBAT or car.car_type == E.CarType.CAPTAIN,
		"[w3-2] the equipment reward sits on a real COMBAT/CAPTAIN car (type %d, %s)" % [car.car_type, car.template_id])
	var item_id := String(car.reward.get("item", ""))
	ok(item_id != "" and _is_weapon_or_armor(item_id),
		"[w3-2] the reward names a real weapon/armor id from the pool ('%s')" % item_id)
	# COLLECT at the ACTUAL reward car (set position to it, collect once) -> a squad member carries it.
	r.position = eq_idx
	var inv_before: int = _total_inventory(r)
	var rw := r.collect_reward([])
	eq(String(rw.get("kind", "")), "equipment", "[w3-2] collecting the reward yields the equipment grant")
	ok(_total_inventory(r) == inv_before + 1, "[w3-2] the dropped item was auto-carried onto a squad member")
	ok(_squad_has_item(r, item_id), "[w3-2] the exact dropped item '%s' is now in a squad member's inventory" % item_id)


func test_w3_2_equipped_item_confers_stat() -> void:
	# An equipped drop confers its passive stat in combat (the mechanism proven end-to-end): scrap_vest
	# (+2 HP) raises the deployed body's combat max HP by exactly 2 via to_sim_entity -> _apply_gear_to_entity.
	var db := ContentDB.new()
	var u = UnitInstance.from_archetype(db, "bruiser", [], "Geared", 1)
	var bare = u.to_sim_entity(db, Vector2i(1, 1))
	var hp0: int = bare.max_hp
	u.inventory = ["scrap_vest"]
	var geared = u.to_sim_entity(db, Vector2i(1, 1))
	eq(geared.max_hp - hp0, 2, "[w3-2] an equipped scrap_vest raises the deployed body's max HP by +2")


# ============================ W3-8: data-driven events ===========================
func test_w3_8_events_are_data_driven_and_distinct() -> void:
	# The eventBeat contract is authored in DATA (content/cars/event_*.json), not 3 hardcoded identical-
	# payload prompts. >=4 distinct events, and the union of their option outcomes covers the authored
	# contract (resource / trait_gain / shortcut / ambush) with DISTINCT payloads.
	var events: Array = _event_templates()
	ok(events.size() >= 4, "[w3-8] >=4 distinct authored event cars (found %d)" % events.size())
	var outcomes: Dictionary = {}
	var prompts: Dictionary = {}
	for eb in events:
		prompts[String(eb.get("prompt", ""))] = true
		for o in eb.get("options", []):
			outcomes[String(o.get("outcome", ""))] = true
	ok(prompts.size() >= 4, "[w3-8] the events carry >=4 DISTINCT prompts/payloads (found %d)" % prompts.size())
	for want in ["resource", "trait_gain", "shortcut", "ambush"]:
		ok(outcomes.has(want), "[w3-8] the authored eventBeat contract includes the '%s' outcome" % want)


func test_w3_8_trait_gain_grants_a_trait() -> void:
	# Driving a trait_gain option through the REAL resolve seam grafts a real trait onto a squad member.
	var rc := _controller()
	var before = _first_alive(rc.run)
	ok(before != null and not ("hardened" in before.traits), "[w3-8] the lead has no Hardened trait pre-event")
	var car := _splice_event(rc, "event_wounded_loyalist")
	rc.drive_screen_scripted(car, "commit:aid")
	var who = _first_alive(rc.run)
	ok(who != null and ("hardened" in who.traits), "[w3-8] a trait_gain event grafted the authored trait onto the cell")
	ok(who != null and ("hardened" in who.revealed_traits), "[w3-8] the granted trait is revealed to the player")


func test_w3_8_ambush_routes_to_combat() -> void:
	# An ambush option injects a real combat car immediately after the event, so the run routes to a fight.
	var rc := _controller_bare([_splice_none()])
	var ev := CarInstance.new("event_silent_checkpoint", E.CarType.EVENT, E.Section.TAIL)
	ev.recon_state = E.Recon.FULL
	rc.run.line = [ev, CarInstance.new("med_rest_01", E.CarType.REST, E.Section.TAIL)]
	rc.run.position = 0
	var size_before: int = rc.run.line.size()
	rc.drive_screen_scripted(ev, "commit:push")
	ok(rc.run.line.size() == size_before + 1, "[w3-8] an ambush injected a car into the line (routes to a fight)")
	var nxt = rc.run.line[rc.run.position + 1]
	ok(nxt.car_type == E.CarType.COMBAT, "[w3-8] the injected car is a COMBAT car")
	eq(nxt.template_id, "combat_security_01", "[w3-8] the ambush injected the authored combat template")


func test_w3_8_shortcut_skips_a_car() -> void:
	# A shortcut option drops the immediate next car from the line (a maintenance-tunnel bypass).
	var rc := _controller_bare([])
	var ev := CarInstance.new("event_service_tunnel", E.CarType.EVENT, E.Section.THIRD)
	ev.recon_state = E.Recon.FULL
	var skipme := CarInstance.new("combat_security_01", E.CarType.COMBAT, E.Section.THIRD)
	var keep := CarInstance.new("med_rest_01", E.CarType.REST, E.Section.THIRD)
	rc.run.line = [ev, skipme, keep]
	rc.run.position = 0
	rc.drive_screen_scripted(ev, "commit:shortcut")
	ok(rc.run.line.size() == 2, "[w3-8] a shortcut removed one car from the line")
	ok(rc.run.line[rc.run.position + 1].template_id == "med_rest_01", "[w3-8] the SKIPPED car (combat) is gone; the one past it remains")


func test_w3_8_event_resolve_is_byte_stable() -> void:
	# The headless resolve path is deterministic — the SAME event option resolves byte-identically twice
	# (the screens/run determinism contract; the outcome is fixed DATA, no seeded coin-flip).
	var a := _resolve_event_fingerprint("commit:pry")
	var b := _resolve_event_fingerprint("commit:pry")
	eq(a, b, "[w3-8] the same event resolve is byte-identical (determinism contract held)")
	var c := _resolve_event_fingerprint("commit:force")
	ok(a != c, "[w3-8] distinct options give distinct payloads (pry != force)")


# ============================ W7-8: resume does not re-fight =====================
func test_w7_8_resumed_resolved_combat_is_not_refought() -> void:
	# A checkpoint saved on a RESOLVED-but-not-advanced combat car (a quit in the post-win level-up
	# window) must NOT re-fight it on resume (pre-fix: the loop re-entered it -> double XP / re-fired
	# moral fork). Build a resume run sitting on a resolved combat car; drive it; the car is skipped.
	var r := RunState.new()
	r.seed = SEED
	r.squad = _squad()
	var fought := CarInstance.new("combat_security_01", E.CarType.COMBAT, E.Section.TAIL)
	fought.resolved = true   # already cleared before the (simulated) quit
	r.line = [fought]
	r.position = 0
	var rc := RunController.new()
	rc.headless = true
	rc.db = ContentDB.new()
	rc.resume_run = r
	rc.seed = SEED
	rc.drive_full_run(-1, 3)
	var saw_skip := false
	var saw_refight := false
	for t in rc.trace:
		var s := str(t)
		if s.find("ALREADY-RESOLVED") != -1:
			saw_skip = true
		if s.begins_with("CAR 0 [combat/combat_security_01]:") and (s.find("WON") != -1 or s.find("LOST") != -1 or s.find("STALLED") != -1):
			saw_refight = true
	ok(saw_skip, "[w7-8] the resolved combat car is recognised as already-resolved on resume")
	ok(not saw_refight, "[w7-8] the resolved combat car is NOT re-fought (no fresh WON/LOST/STALLED entry)")
	ok(rc.run.position >= r.line.size(), "[w7-8] the run advanced PAST the resolved car and resolved an ending")


# ============================ W7-9: mid-phase win releases =======================
func test_w7_9_midphase_win_releases_the_phase() -> void:
	# When the last enemy is displaced/killed while player units still hold AP, the phase is DECIDED and
	# must release — pre-fix only `_any_player_can_act()` gated release, so the operator had to END every
	# unit on a cleared board. Build a fight, wipe the enemies, and show both conditions diverge.
	var rc := _controller()
	var car = _first_combat_car(rc.run)
	ok(car != null, "[w7-9] the line has a combat car")
	if car == null:
		return
	rc.state = rc._build_car_state(car)
	rc.turn = TurnManager.new(rc.state)
	rc.turn.start()
	# Erase every enemy -> check_victory() reports a player win, but the players still have AP.
	for id in rc.state.entity_ids_sorted():
		var e = rc.state.entities.get(id)
		if e != null and e.is_unit and e.faction == E.Faction.ENEMY:
			rc._erase_entity(rc.state, e)
	ok(rc._any_player_can_act(), "[w7-9] player units still hold AP (the OLD release condition would keep waiting)")
	eq(rc.turn.check_victory(), 1, "[w7-9] the board is a decided player WIN")
	ok(rc._combat_decided(), "[w7-9] the fix releases the phase the instant the fight is decided")


# ============================ W7-10: guard warning + honest copy =================
func test_w7_10_guard_warns_and_reports_real_cause() -> void:
	var rc := RunController.new()
	rc.headless = true
	rc.db = ContentDB.new()
	# WARNING: the guard warns as the 60-round cap approaches, and only there — never prematurely.
	ok(rc._combat_guard_warning(50) != "", "[w7-10] warns at 10 rounds remaining (round 50)")
	ok(rc._combat_guard_warning(55) != "", "[w7-10] warns at 5 rounds remaining (round 55)")
	ok(rc._combat_guard_warning(30) == "", "[w7-10] no premature warning far from the cap (round 30)")
	ok(rc._combat_guard_warning(60) == "", "[w7-10] no warning once the cap is reached (round 60)")
	# HONEST COPY: a stall-scrub reports the REAL cause, never the old silent 'squad wiped' lie.
	var stall_copy := rc._loss_reason_copy("stall")
	ok(stall_copy.findn("round") != -1 and stall_copy.findn("scrub") != -1, "[w7-10] a stall reports the real cause (round limit / scrubbed)")
	ok(stall_copy.findn("wiped") == -1, "[w7-10] a stall does NOT claim the squad was wiped")
	eq(rc._loss_reason_copy("wipe"), "squad wiped on the line", "[w7-10] a real wipe still reads honestly (byte-identical default)")
	# The resolution trace carries the real cause.
	rc.run = RunState.new_run(SEED, _squad(), E.DRAFT_PAYOUT_X3)
	rc._resolve_loss("stall")
	var saw_honest := false
	for t in rc.trace:
		if str(t).find("scrubbed") != -1:
			saw_honest = true
	ok(saw_honest, "[w7-10] the resolution reports the real cause in the run trace")


# ============================ W7-11: bourgeois ESC != spare ======================
func test_w7_11_bourgeois_esc_does_not_autocommit_spare() -> void:
	# The forced moral fork has NO walk-away exit — ESC/leave must NOT silently commit SPARE.
	var rc := RunController.new()
	rc.headless = true
	rc.db = ContentDB.new()
	rc.run = RunState.new_run(SEED, _squad(), E.DRAFT_PAYOUT_X3)
	rc.run.order = 20
	var order_before: int = rc.run.order
	var log_before: int = rc.run.input_log.size()
	var leave_label := rc._apply_bourgeois_action("leave")
	eq(leave_label, "", "[w7-11] ESC/leave does NOT resolve the fork (returns no label)")
	eq(rc.run.order, order_before, "[w7-11] ESC/leave did NOT move Order (no silent SPARE)")
	ok(not _log_has_op(rc.run, "bourgeois", log_before), "[w7-11] ESC/leave never fired the bourgeois rail")
	# An explicit choice DOES resolve.
	var spare_label := rc._apply_bourgeois_action("commit:spare")
	ok(spare_label.begins_with("BOURGEOIS: spared"), "[w7-11] an explicit SPARE resolves the fork")
	ok(rc.run.order < order_before, "[w7-11] SPARE lowered Order (the rail ran)")
	rc.run.order = 20
	var kill_label := rc._apply_bourgeois_action("commit:kill")
	ok(kill_label.begins_with("BOURGEOIS: killed"), "[w7-11] an explicit KILL resolves the fork")
	ok(rc.run.order > 20, "[w7-11] KILL raised Order (the rail ran)")


# ============================ W7-13: betrayal survives resume ====================
func test_w7_13_betrayal_survives_save_resume() -> void:
	# A defection at a captain car persists across save/resume: the checkpoint records the defector, and
	# resume re-injects it as the enemy it became (pre-fix: the resumed fight had neither ally nor traitor).
	var rc := _controller_with_plant()
	var cap = _first_captain_car(rc.run)
	ok(cap != null, "[w7-13] the line has a Section Captain car")
	if cap == null:
		return
	rc.state = rc._build_car_state(cap)
	var ev: Array = rc._apply_betrayal_beat(cap)
	ok(_has_betrayal(ev), "[w7-13] the plant defects at the captain car (first play)")
	ok(rc.run.defectors.size() == 1, "[w7-13] the defection is PERSISTED into the run record")
	# SAVE -> RESUME round-trip: the defector survives serialization.
	var reloaded = RunState.from_dict(rc.run.to_dict())
	ok(reloaded.defectors.size() == 1, "[w7-13] the defector is present in the RESUMED state (survives to_dict/from_dict)")
	ok(not _instance_in_squad(reloaded, 101), "[w7-13] the resumed roster no longer carries the traitor as an ally")
	# Rebuild the captain fight from the resumed run: the defector is RESTORED as an ENEMY.
	var rc2 := RunController.new()
	rc2.headless = true
	rc2.db = ContentDB.new()
	rc2.seed = reloaded.seed
	rc2.run = reloaded
	var cap2 = _first_captain_car(reloaded)
	rc2.state = rc2._build_car_state(cap2)
	rc2._apply_betrayal_beat(cap2)
	var body = _body_for_instance(rc2.state, 101)
	ok(body != null, "[w7-13] the defector's body is RESTORED into the resumed captain fight")
	ok(body != null and int(body.faction) == E.Faction.ENEMY, "[w7-13] the restored defector fights AS the enemy (not lost, not an ally)")


# ============================ helpers ============================================
func _squad() -> Array:
	var db := ContentDB.new()
	return [
		UnitInstance.from_archetype(db, "bruiser", [], "Lead", 1),
		UnitInstance.from_archetype(db, "marksman", [], "Two", 2),
		UnitInstance.from_archetype(db, "steward", [], "Three", 3),
	]

func _controller() -> RunController:
	var rc := RunController.new()
	rc.headless = true
	rc.db = ContentDB.new()
	rc.seed = SEED
	rc._run_draft(3)
	return rc

## A controller with a live run but a hand-set (empty) squad container so tests can install a controlled
## line/squad. `_ignored` keeps the call shape uniform.
func _controller_bare(_ignored: Array) -> RunController:
	var rc := RunController.new()
	rc.headless = true
	rc.db = ContentDB.new()
	rc.seed = SEED
	rc.run = RunState.new_run(SEED, _squad(), E.DRAFT_PAYOUT_X3)
	return rc

func _splice_none():
	return null

func _controller_with_plant() -> RunController:
	var rc := RunController.new()
	rc.headless = true
	rc.db = ContentDB.new()
	rc.seed = SEED
	rc._run_draft(3)
	var a = UnitInstance.from_archetype(rc.db, "bruiser", [], "Ally0", 100)
	var plant = UnitInstance.from_archetype(rc.db, "bruiser", ["conductors_kin"], "Plant", 101)
	var b = UnitInstance.from_archetype(rc.db, "bruiser", [], "Ally2", 102)
	rc.run.squad = [a, plant, b]
	return rc

## Splice an event car at the current position so drive_screen_scripted / _event_template resolve it.
func _splice_event(rc: RunController, template_id: String) -> CarInstance:
	var car := CarInstance.new(template_id, E.CarType.EVENT, E.Section.THIRD)
	car.recon_state = E.Recon.FULL
	rc.run.line.insert(rc.run.position, car)
	return car

func _resolve_event_fingerprint(action: String) -> String:
	var rc := _controller_bare([])
	var ev := CarInstance.new("event_01", E.CarType.EVENT, E.Section.THIRD)
	ev.recon_state = E.Recon.FULL
	rc.run.line.insert(rc.run.position, ev)
	var res := rc.drive_screen_scripted(ev, action)
	return "%s|scrip=%d|tools=%d|supplies=%d|order=%d" % [
		String(res.get("label", "")), int(res.get("scrip", 0)), int(res.get("tools", 0)),
		int(res.get("supplies", 0)), int(res.get("order", 0))]

func _event_templates() -> Array:
	var out: Array = []
	var d = DirAccess.open("res://content/cars")
	if d == null:
		return out
	d.list_dir_begin()
	var fn := d.get_next()
	while fn != "":
		if fn.begins_with("event_") and fn.ends_with(".json"):
			var data = JSON.parse_string(FileAccess.get_file_as_string("res://content/cars/" + fn))
			if typeof(data) == TYPE_DICTIONARY:
				var eb = data.get("eventBeat", {})
				if typeof(eb) == TYPE_DICTIONARY and eb.has("options"):
					out.append(eb)
		fn = d.get_next()
	d.list_dir_end()
	return out

func _is_weapon_or_armor(iid: String) -> bool:
	for path in ["res://content/items/weapons.json", "res://content/items/armor.json"]:
		var d = JSON.parse_string(FileAccess.get_file_as_string(path))
		if typeof(d) == TYPE_DICTIONARY:
			for it in d.get("items", []):
				if typeof(it) == TYPE_DICTIONARY and String(it.get("id", "")) == iid:
					return true
	return false

func _total_inventory(run) -> int:
	var n := 0
	for u in run.squad:
		if u != null:
			n += u.inventory.size()
	return n

func _squad_has_item(run, iid: String) -> bool:
	for u in run.squad:
		if u != null and iid in u.inventory:
			return true
	return false

func _first_alive(run):
	for u in run.squad:
		if u != null and not u.dead:
			return u
	return null

func _first_combat_car(run):
	for c in run.line:
		if c.is_combat() and c.car_type != E.CarType.ENGINE:
			return c
	return null

func _first_captain_car(run):
	for c in run.line:
		if c.car_type == E.CarType.CAPTAIN:
			return c
	return null

func _has_betrayal(ev: Array) -> bool:
	for e in ev:
		if e.type == E.Ev.BETRAYAL:
			return true
	return false

func _body_for_instance(s, inst_id: int):
	if s == null:
		return null
	for id in s.entity_ids_sorted():
		var e = s.entities.get(id)
		if e != null and e.is_unit and int(e.instance_id) == inst_id:
			return e
	return null

func _instance_in_squad(run, inst_id: int) -> bool:
	for u in run.squad:
		if u != null and int(u.id) == inst_id:
			return true
	return false

func _log_has_op(run, op: String, after_index: int) -> bool:
	for i in range(after_index, run.input_log.size()):
		if String(run.input_log[i].get("op", "")) == op:
			return true
	return false
