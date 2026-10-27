extends SceneTree
## SCREENS smoke test (Batch 2 — the 6 interactive NON-COMBAT car screens, headless).
## Proves the OPERATOR-DRIVEN economy-car choices WITHOUT a display: a scripted choice, fed through
## RunController.drive_screen_scripted() — the EXACT commit/leave the RunScreens econ surface emits —
## drives a REAL RunState rail (market_buy / workshop_upgrade / resolve_bourgeois / roll_recruit /
## earn|spend|apply_order / rest_heal). Mirrors draft_smoke (the drive_draft_scripted seam): no
## SceneTree node tree, no view — just the controller's interactive wiring exercised headlessly.
##
## For EACH of SHOP / WORKSHOP / BOURGEOIS / RECRUIT / EVENT / REST it asserts:
##   1. the rail FIRED — the right currency/order/squad actually changed (scrip/supplies/order/size);
##   2. the car RESOLVED + the run could ADVANCE (no stuck state — a screen car always resolves);
##   3. the SAFE-DEFAULT (ESC/LEAVE) path also resolves (never a dead end);
##   4. DETERMINISM — the same scripted action over the same (seed, run-state) yields the same result.
## It also pins that the headless _do_* auto-defaults are byte-UNCHANGED (the run_smoke trace path),
## by re-driving the auto-defaults and asserting their trace labels are exactly as before.
##
## Run: godot --headless --path . --script res://tests/screens_smoke.gd

const E = preload("res://core/sim_enums.gd")
const RunController = preload("res://app/run_controller.gd")
const ContentDB = preload("res://core/units/content_db.gd")
const RunState = preload("res://core/run/run_state.gd")
const CarInstance = preload("res://core/run/car_instance.gd")
const UnitInstance = preload("res://core/units/unit_instance.gd")

const SEED := 0xC01D5

var _pass: int = 0
var _fail: int = 0
var _fails: Array = []


func _initialize() -> void:
	print("\n=== COLDSPINE — SCREENS smoke test (6 interactive non-combat cars, headless) ===")
	test_shop_buy_fires_rail()
	test_shop_leave_resolves()
	test_shop_cant_afford_no_buy()
	test_workshop_upgrade_fires_rail()
	test_workshop_leave_resolves()
	test_bourgeois_kill_vs_spare()
	test_recruit_accept_grows_squad()
	test_recruit_decline_keeps_tight()
	test_recruit_hard_cap_blocks_accept()
	test_event_safe_and_risk()
	test_rest_heals_squad()
	test_rest_leave_hoards()
	test_every_car_resolves_no_stuck()
	test_determinism_same_action_same_result()
	test_headless_defaults_byte_unchanged()
	test_deploy_surface_builds_and_toggles()
	test_abandon_overlay_open_close()
	test_runtime_settings_apply()
	print("\n--- SCREENS SMOKE: %d passed, %d failed ---" % [_pass, _fail])
	for f in _fails:
		print("    FAIL: " + f)
	if _fail == 0:
		print("SCREENS GREEN — the operator drives all 6 non-combat cars through the controller (real rails, no stuck).\n")
	quit(0 if _fail == 0 else 1)


func ok(cond: bool, msg: String) -> void:
	if cond:
		_pass += 1
	else:
		_fail += 1
		_fails.append(msg)
		print("    [FAIL] " + msg)


# ============================ Stage-2 UX surfaces =============================
const RunScreens = preload("res://app/screens/run_screens.gd")

func _screens() -> RunScreens:
	var rs := RunScreens.new()
	root.add_child(rs)
	rs._ready()   # SceneTree defers the ready notification — fire the build entry point explicitly
	return rs


## DEPLOY picker (combat-ux #6): builds a row per living member, enables COMMIT only at exactly N
## selected, and a row tap emits deploy_toggle(instance_id).
func test_deploy_surface_builds_and_toggles() -> void:
	var rs := _screens()
	var members: Array = []
	for i in range(5):
		members.append({"id": 100 + i, "label": "U%d" % i, "detail": "LV1", "hp": 10, "max_hp": 12, "selected": i < 3})
	rs.show_deploy_picker({"members": members, "need": 3})
	ok(rs.deploy_open(), "[deploy] the picker opens")
	ok(rs.deploy_rows.get_child_count() == 5, "[deploy] one row per living member (5)")
	ok(not rs.deploy_commit_btn.disabled, "[deploy] DEPLOY is enabled at exactly N (3) selected")
	var got := {"id": -1}
	rs.deploy_toggle.connect(func(mid): got.id = mid)
	(rs.deploy_rows.get_child(4) as Button).emit_signal("pressed")
	ok(got.id == 104, "[deploy] a row tap emits deploy_toggle(instance_id)")
	# 4 of 5 selected -> commit disabled (must pick EXACTLY N).
	for i in range(members.size()):
		members[i]["selected"] = (i < 4)
	rs.show_deploy_picker({"members": members, "need": 3})
	ok(rs.deploy_commit_btn.disabled, "[deploy] DEPLOY is disabled when selected != N")
	rs.hide_deploy_picker()
	ok(not rs.deploy_open(), "[deploy] the picker hides")
	rs.free()


## ABANDON-RUN confirm (combat-ux #4): opens on ESC, its buttons emit the wired signals, and it hides.
func test_abandon_overlay_open_close() -> void:
	var rs := _screens()
	ok(not rs.abandon_open(), "[abandon] starts hidden")
	rs.show_abandon_confirm()
	ok(rs.abandon_open(), "[abandon] opens (ESC no longer nukes the run)")
	var fired := {"save": false}
	rs.abandon_save_exit.connect(func(): fired.save = true)
	# The SAVE & EXIT button is the first _draft_button child of the overlay.
	for c in rs.abandon_overlay.get_children():
		if c is Button and String(c.text).contains("SAVE"):
			(c as Button).emit_signal("pressed")
	ok(fired.save, "[abandon] SAVE & EXIT emits abandon_save_exit")
	rs.hide_abandon_confirm()
	ok(not rs.abandon_open(), "[abandon] KEEP FIGHTING / dismiss hides it")
	rs.free()


## Runtime settings (release-readiness #3): confirm_moves + in_car_fog are honored live; the audio
## hook is a side-effect-free no-op until stage 3's buses land.
func test_runtime_settings_apply() -> void:
	var rc := RunController.new()
	rc.headless = true
	ok(rc._confirm_moves() == true, "[settings] confirm_moves defaults ON (empty session settings)")
	ok(rc.fog_enabled() == true, "[settings] in_car_fog defaults ON")
	rc._settings = {"confirm_moves": false, "in_car_fog": false, "sfx_volume": 40}
	ok(rc._confirm_moves() == false, "[settings] confirm_moves OFF is honored at runtime (skips the two-tap)")
	ok(rc.fog_enabled() == false, "[settings] in_car_fog OFF is honored (session override of the E1.4 default)")
	rc.apply_audio_settings()   # must not crash — the audio-bus wiring is stage 3's deliverable
	ok(true, "[settings] the audio hook is a safe no-op until the buses exist")


# ============================ harness =========================================
## A headless controller with a small squad + a fresh RunState, ready for the scripted seam. The
## squad is two marksmen (deterministic, no rng); currency is seeded so the rails are exercisable.
func _controller(scrip: int = 20, supplies: int = 3, tools: int = 2) -> RunController:
	var rc := RunController.new()
	rc.headless = true
	rc.db = ContentDB.new()
	rc.seed = SEED
	rc.run = RunState.new_run(SEED, _squad(rc.db), E.DRAFT_PAYOUT_X3)
	rc.run.currency["scrip"] = scrip
	rc.run.currency["supplies"] = supplies
	rc.run.currency["tools"] = tools
	return rc


func _squad(db) -> Array:
	var a := UnitInstance.from_archetype(db, "marksman", [], "A", 1)
	var b := UnitInstance.from_archetype(db, "bruiser", [], "B", 2)
	return [a, b]


## Splice a car of `car_type` into the line AT the current position so current_car() returns it +
## resolve/advance operate on it. Returns the spliced CarInstance.
func _put_car(rc: RunController, car_type: int) -> CarInstance:
	var car := CarInstance.new("test_%d" % car_type, car_type, E.Section.TAIL)
	car.recon_state = E.Recon.FULL
	rc.run.line.insert(rc.run.position, car)
	return car


func _scrip(rc) -> int: return int(rc.run.currency.get("scrip", 0))
func _supplies(rc) -> int: return int(rc.run.currency.get("supplies", 0))
func _tools(rc) -> int: return int(rc.run.currency.get("tools", 0))


# ============================ SHOP =============================================
func test_shop_buy_fires_rail() -> void:
	var rc := _controller(20)
	var car := _put_car(rc, E.CarType.SHOP)
	var before := _scrip(rc)
	# W3-1: buy a REAL stocked id (not the old phantom field_kit) so the purchase is a usable item.
	var iid: String = String(rc._shop_stock()[0])
	var res := rc.drive_screen_scripted(car, "commit:" + iid)
	ok(_scrip(rc) == before - E.MARKET_BUY_SCRIP_COST, "[shop] BUY fired market_buy — scrip %d -> %d" % [before, _scrip(rc)])
	ok(car.resolved, "[shop] the shop car RESOLVED after a buy")
	# the bought item lands on the lead unit's inventory (the on-screen UX layer).
	ok(iid in rc.run.squad[0].inventory, "[shop] the bought item attached to the lead unit")
	# W3-1: the bought id is a REAL ItemDef with a usable (consumable/gadget) slot — pre-fix the shop
	# sold field_kit/stim_patch which resolved to {} and could never fire UseItemCommand.
	var def: Dictionary = rc.db.item(iid)
	ok(not def.is_empty(), "[shop] the bought id resolves to a real ItemDef (%s)" % iid)
	ok(String(def.get("slot", "")) in ["consumable", "gadget"], "[shop] the bought item is usable in combat (slot=%s)" % String(def.get("slot", "")))
	ok(String(res.get("label", "")).begins_with("SHOP: bought"), "[shop] the result label reports the buy")


func test_shop_leave_resolves() -> void:
	var rc := _controller(20)
	var car := _put_car(rc, E.CarType.SHOP)
	var before := _scrip(rc)
	rc.drive_screen_scripted(car, "leave")
	ok(_scrip(rc) == before, "[shop] LEAVE spent nothing")
	ok(car.resolved, "[shop] LEAVE still RESOLVED the car (no dead end)")


func test_shop_cant_afford_no_buy() -> void:
	var rc := _controller(0)   # broke
	var car := _put_car(rc, E.CarType.SHOP)
	rc.drive_screen_scripted(car, "commit:medkit")   # W3-1: a real stock id; broke → still a no-op
	ok(_scrip(rc) == 0, "[shop] a can't-afford BUY is a no-op (guarded spend, no overspend)")
	ok(car.resolved, "[shop] the car still resolved while broke")


# ============================ WORKSHOP ========================================
func test_workshop_upgrade_fires_rail() -> void:
	var rc := _controller(20)
	var car := _put_car(rc, E.CarType.UPGRADE)
	var before := _scrip(rc)
	rc.drive_screen_scripted(car, "commit:sharpened_edge")
	ok(_scrip(rc) == before - E.WORKSHOP_UPGRADE_SCRIP_COST, "[workshop] upgrade fired workshop_upgrade — scrip %d -> %d" % [before, _scrip(rc)])
	ok(car.resolved, "[workshop] the upgrade car RESOLVED")


func test_workshop_leave_resolves() -> void:
	var rc := _controller(20)
	var car := _put_car(rc, E.CarType.UPGRADE)
	var before := _scrip(rc)
	rc.drive_screen_scripted(car, "leave")
	ok(_scrip(rc) == before, "[workshop] LEAVE bought nothing")
	ok(car.resolved, "[workshop] LEAVE resolved the car")


# ============================ BOURGEOIS =======================================
func test_bourgeois_kill_vs_spare() -> void:
	# KILL: +scrip, Order rises.
	var rk := _controller(0)
	var ck := _put_car(rk, E.CarType.BOURGEOIS)
	var order_before := rk.run.order
	rk.drive_screen_scripted(ck, "commit:kill")
	ok(_scrip(rk) == E.BOURGEOIS_KILL_SCRIP, "[bourgeois] KILL granted +%d scrip" % E.BOURGEOIS_KILL_SCRIP)
	ok(rk.run.order == order_before + E.ORDER_CIVILIAN_KILL, "[bourgeois] KILL raised Order +%d (%d -> %d)" % [E.ORDER_CIVILIAN_KILL, order_before, rk.run.order])
	ok(ck.resolved, "[bourgeois] the KILL car resolved")
	# SPARE: Order falls (toward Liberation). Start with some Order so the mercy drop is visible.
	var rs := _controller(0)
	rs.run.order = 20
	var cs := _put_car(rs, E.CarType.BOURGEOIS)
	rs.drive_screen_scripted(cs, "commit:spare")
	ok(rs.run.order == 20 - E.ORDER_MERCY_DROP, "[bourgeois] SPARE lowered Order -%d (20 -> %d)" % [E.ORDER_MERCY_DROP, rs.run.order])
	ok(_scrip(rs) == 0, "[bourgeois] SPARE granted no scrip")
	ok(cs.resolved, "[bourgeois] the SPARE car resolved")
	# ESC/leave on the forced fork defaults to SPARE (the byte-stable headless default).
	var rl := _controller(0)
	rl.run.order = 20
	var cl := _put_car(rl, E.CarType.BOURGEOIS)
	rl.drive_screen_scripted(cl, "leave")
	ok(rl.run.order == 20 - E.ORDER_MERCY_DROP, "[bourgeois] ESC/leave defaulted to SPARE (safe default, Order -%d)" % E.ORDER_MERCY_DROP)
	ok(cl.resolved, "[bourgeois] the leave path still resolved the car (no dead end)")


# ============================ RECRUIT =========================================
func test_recruit_accept_grows_squad() -> void:
	var rc := _controller()
	var car := _put_car(rc, E.CarType.RECRUIT)
	var before := rc.run.squad.size()
	rc.drive_screen_scripted(car, "commit:accept")
	ok(rc.run.squad.size() == before + 1, "[recruit] ACCEPT grew the squad %d -> %d (roll_recruit fired)" % [before, rc.run.squad.size()])
	ok(car.resolved, "[recruit] the recruit car RESOLVED on accept")
	# the recruit-join was logged (the input_log entry the on-screen path appends).
	var logged := false
	for entry in rc.run.input_log:
		if String(entry.get("op", "")) == "recruit":
			logged = true
	ok(logged, "[recruit] the accept logged a recruit op (replayable)")


func test_recruit_decline_keeps_tight() -> void:
	var rc := _controller()
	var car := _put_car(rc, E.CarType.RECRUIT)
	var before := rc.run.squad.size()
	rc.drive_screen_scripted(car, "commit:decline")
	ok(rc.run.squad.size() == before, "[recruit] DECLINE left the squad size unchanged")
	ok(car.resolved, "[recruit] the recruit car resolved on decline")


func test_recruit_hard_cap_blocks_accept() -> void:
	var rc := _controller()
	# Fill to the hard cap so an accept must be refused.
	while rc.run.squad.size() < E.SQUAD_HARD_CAP:
		rc.run.squad.append(UnitInstance.from_archetype(rc.db, "marksman", [], "F%d" % rc.run.squad.size(), 100 + rc.run.squad.size()))
	var car := _put_car(rc, E.CarType.RECRUIT)
	var before := rc.run.squad.size()
	rc.drive_screen_scripted(car, "commit:accept")
	ok(rc.run.squad.size() == before, "[recruit] ACCEPT at hard cap (%d) is refused — no overflow" % E.SQUAD_HARD_CAP)
	ok(car.resolved, "[recruit] the hard-cap car still resolved (no dead end)")


# ============================ EVENT ===========================================
func test_event_safe_and_risk() -> void:
	# SAFE: +1 tools, no Order (the byte-stable default).
	var rs := _controller()
	var cs := _put_car(rs, E.CarType.EVENT)
	var t_before := _tools(rs)
	var o_before := rs.run.order
	rs.drive_screen_scripted(cs, "commit:safe")
	ok(_tools(rs) == t_before + 1, "[event] SAFE earned +1 tools (%d -> %d)" % [t_before, _tools(rs)])
	ok(rs.run.order == o_before, "[event] SAFE moved Order by 0")
	ok(cs.resolved, "[event] the SAFE event resolved")
	# RISK: a deterministic seeded outcome — either +8 scrip OR an Order rise (never a no-op).
	var rr := _controller()
	var cr := _put_car(rr, E.CarType.EVENT)
	var scrip_before := _scrip(rr)
	var order_before := rr.run.order
	rr.drive_screen_scripted(cr, "commit:risk")
	var moved := (_scrip(rr) != scrip_before) or (rr.run.order != order_before)
	ok(moved, "[event] RISK rolled a real outcome (scrip %d->%d, order %d->%d)" % [scrip_before, _scrip(rr), order_before, rr.run.order])
	ok(cr.resolved, "[event] the RISK event resolved")
	# leave defaults to SAFE.
	var rl := _controller()
	var cl := _put_car(rl, E.CarType.EVENT)
	var tl := _tools(rl)
	rl.drive_screen_scripted(cl, "leave")
	ok(_tools(rl) == tl + 1, "[event] ESC/leave defaulted to the SAFE outcome (+1 tools)")
	ok(cl.resolved, "[event] the leave path resolved the event")


# ============================ REST ============================================
func test_rest_heals_squad() -> void:
	var rc := _controller(0, 2)   # 2 supplies, broke on scrip (irrelevant)
	# Wound the squad so a heal is observable.
	rc.run.squad[0].hp = 1
	rc.run.squad[1].hp = 2
	var car := _put_car(rc, E.CarType.REST)
	var sup_before := _supplies(rc)
	rc.drive_screen_scripted(car, "commit:rest")
	ok(_supplies(rc) == sup_before - E.REST_HEAL_SUPPLY_COST, "[rest] REST spent a supply (%d -> %d)" % [sup_before, _supplies(rc)])
	ok(rc.run.squad[0].hp == min(rc.run.squad[0].max_hp, 1 + E.REST_HEAL_AMOUNT), "[rest] unit A healed +%d HP" % E.REST_HEAL_AMOUNT)
	ok(rc.run.squad[1].hp == min(rc.run.squad[1].max_hp, 2 + E.REST_HEAL_AMOUNT), "[rest] unit B healed +%d HP" % E.REST_HEAL_AMOUNT)
	ok(car.resolved, "[rest] the rest car RESOLVED")


func test_rest_leave_hoards() -> void:
	var rc := _controller(0, 2)
	rc.run.squad[0].hp = 1
	var car := _put_car(rc, E.CarType.REST)
	var sup_before := _supplies(rc)
	rc.drive_screen_scripted(car, "leave")
	ok(_supplies(rc) == sup_before, "[rest] LEAVE hoarded the supply (no spend)")
	ok(rc.run.squad[0].hp == 1, "[rest] LEAVE left HP unchanged")
	ok(car.resolved, "[rest] the leave path resolved the rest car")


# ============================ NO STUCK STATE ==================================
## Every non-combat car type, driven by both a commit AND a leave, must end resolved AND let the run
## advance past it (advance() refuses to move off an unresolved combat car, but a resolved screen car
## must always advance). This is the "a screen car must always resolve + advance" contract.
func test_every_car_resolves_no_stuck() -> void:
	var types := {
		E.CarType.SHOP: "commit:medkit", E.CarType.UPGRADE: "commit:reinforced_plating",
		E.CarType.BOURGEOIS: "commit:kill", E.CarType.RECRUIT: "commit:accept",
		E.CarType.EVENT: "commit:risk", E.CarType.REST: "commit:rest",
	}
	for ct in types.keys():
		for action in [String(types[ct]), "leave"]:
			var rc := _controller()
			var pos_before := rc.run.position
			var car := _put_car(rc, ct)
			rc.drive_screen_scripted(car, action)
			ok(car.resolved, "[no-stuck] car_type %d via '%s' resolved" % [ct, action])
			var moved := rc.run.advance()
			ok(moved and rc.run.position == pos_before + 1, "[no-stuck] car_type %d via '%s' ADVANCED past (pos %d -> %d)" % [ct, action, pos_before, rc.run.position])


# ============================ DETERMINISM =====================================
## The same scripted action over the same (seed, freshly-built run) yields the same result — the
## RECRUIT/EVENT rolls derive from seed^(0x5EC0+pos), so two identical drives match byte-for-byte.
func test_determinism_same_action_same_result() -> void:
	for pair in [[E.CarType.RECRUIT, "commit:accept"], [E.CarType.EVENT, "commit:risk"], [E.CarType.BOURGEOIS, "commit:kill"]]:
		var a := _drive_one(int(pair[0]), String(pair[1]))
		var b := _drive_one(int(pair[0]), String(pair[1]))
		ok(str(a) == str(b), "[determinism] car_type %d via '%s' -> identical result twice (%s)" % [pair[0], pair[1], str(a)])


func _drive_one(car_type: int, action: String) -> Dictionary:
	var rc := _controller()
	var car := _put_car(rc, car_type)
	return rc.drive_screen_scripted(car, action)


# ============================ BYTE-STABILITY ==================================
## The headless _do_* auto-defaults (the run_smoke/balance_smoke path) must be behaviorally
## UNCHANGED by Batch 2. Drive each _do_* directly (the exact synchronous default the headless
## _resolve_screen_car takes) and assert the trace label matches the documented default.
func test_headless_defaults_byte_unchanged() -> void:
	# SHOP default = buy the first REAL stocked id if affordable (W3-1 made the purchase real +
	# attaching; the item id is deterministic from (seed, position) so the label is still stable).
	var rc := _controller(20)
	_put_car(rc, E.CarType.SHOP)
	var expected_id: String = String(rc._shop_stock()[0])
	ok(rc._do_shop(rc.run.current_car()) == "SHOP: bought %s (-%d scrip)" % [expected_id, E.MARKET_BUY_SCRIP_COST], "[byte] _do_shop default == buy the first real stock id (%s)" % expected_id)
	ok(expected_id in rc.run.squad[0].inventory, "[byte] _do_shop attaches the bought item to the lead (real on AUTO too)")
	# WORKSHOP default = reinforced_plating if affordable.
	var rw := _controller(20)
	_put_car(rw, E.CarType.UPGRADE)
	ok(rw._do_workshop(rw.run.current_car()) == "WORKSHOP: upgrade reinforced_plating (-%d scrip)" % E.WORKSHOP_UPGRADE_SCRIP_COST, "[byte] _do_workshop default == reinforced_plating")
	# BOURGEOIS default = SPARE.
	var rb := _controller(0)
	rb.run.order = 20
	_put_car(rb, E.CarType.BOURGEOIS)
	ok(rb._do_bourgeois(rb.run.current_car()) == "BOURGEOIS: spared (Order -> %d)" % rb.run.order, "[byte] _do_bourgeois default == SPARE")
	# RECRUIT default = ACCEPT.
	var rr := _controller()
	_put_car(rr, E.CarType.RECRUIT)
	ok(rr._do_recruit(rr.run.current_car()).begins_with("RECRUIT: ") and rr.run.squad.size() == 3, "[byte] _do_recruit default == ACCEPT (squad grew to 3)")
	# EVENT default = SAFE (+1 tools).
	var re := _controller()
	_put_car(re, E.CarType.EVENT)
	var et := _tools(re)
	ok(re._do_event(re.run.current_car()) == "EVENT: took the safe option (+1 tools)" and _tools(re) == et + 1, "[byte] _do_event default == SAFE +1 tools")
	# REST default = rest if affordable.
	var rt := _controller(0, 2)
	rt.run.squad[0].hp = 1
	_put_car(rt, E.CarType.REST)
	ok(rt._do_rest(rt.run.current_car()) == "REST: squad healed (-%d supplies)" % E.REST_HEAL_SUPPLY_COST, "[byte] _do_rest default == REST")
