extends SceneTree
## Wave 3b — ITEM REACHABILITY (W3-2, the P1 the Wave-3 verifier flagged INCOMPLETE). NEW suite.
##
## PRE-FIX GAP (Wave 3): the Black-Market shop stocked ONLY consumables/gadgets (SHOP_POOL) and no
## reward table dropped equipment, so the run reached just 9 of 23 authored items. ALL 9 WEAPONS
## (fire_axe/harpoon_gun/incendiary_launcher/marksman_rifle/maul/pipe_wrench/riot_baton/scrap_pistol/
## shove_shotgun) and 5 of 6 ARMOR (gas_mask/magnetic_boots/riot_plate/scrap_vest/thermal_suit) had
## ZERO acquisition path — a player could never obtain or equip them, so their stat/rider never
## reached combat.
##
## THE FIX (in-lane, app/run_controller.gd): a deterministic rotating EQUIPMENT stock
## (_shop_equipment_stock) keyed off an INDEPENDENT (seed^position) IntRng stream offers weapons/armor
## ALONGSIDE the consumable stock in the on-screen shop. A purchase rides the SAME commit rail
## (market_buy -> _attach_item_to_lead), auto-equips onto the lead, and confers its passive stat/armor
## effect in combat via UnitInstance.to_sim_entity -> _apply_gear_to_entity.
##
## Every test below REPRODUCES the pre-fix gap: it exercises _shop_equipment_stock / the widened
## _shop_spec (neither existed pre-fix) or asserts equipment reaches a real combat body — so a test
## that would pass against the OLD build is worthless by construction. The one boundary test
## (test_on_hit_riders_are_not_yet_passive) pins the HONEST limit: triggered on-hit riders
## (maul knockback etc.) are still skipped by the equip path, which lives OUTSIDE this lane.
##
## Run: godot --headless --path . --script res://tests/item_reachability_smoke.gd

const E = preload("res://core/sim_enums.gd")
const RunController = preload("res://app/run_controller.gd")
const ContentDB = preload("res://core/units/content_db.gd")
const RunState = preload("res://core/run/run_state.gd")
const UnitInstance = preload("res://core/units/unit_instance.gd")
const SaveSystem = preload("res://core/meta/save_system.gd")

const SEED := 0xC01D5

var _pass: int = 0
var _fail: int = 0
var _fails: Array = []


func _initialize() -> void:
	SaveSystem.force_sandbox = true   # harness safety — never touch the owner's real profile
	print("\n=== COLDSPINE — ITEM REACHABILITY smoke (Wave 3b: weapons/armor acquisition + equip) ===")
	test_pre_fix_consumable_shop_never_reached_equipment()
	test_equipment_stock_generator_covers_the_catalog()
	test_equipment_stock_is_deterministic()
	test_equipment_and_consumable_streams_are_disjoint()
	test_shop_spec_lists_equipment_options()
	test_bought_weapon_equips_and_raises_accuracy()
	test_bought_armor_equips_and_raises_hp_and_soak()
	test_reachable_gear_confers_physics_riders()
	test_on_hit_riders_are_not_yet_passive()
	print("\n--- ITEM REACHABILITY: %d passed, %d failed ---" % [_pass, _fail])
	for f in _fails:
		print("    FAIL: " + f)
	if _fail == 0:
		print("REACHABILITY GREEN — weapons/armor are obtainable and equip into combat.\n")
	quit(0 if _fail == 0 else 1)


# ---- assertion kit (mirrors economy_wave3_smoke.gd) ----
func ok(cond: bool, msg: String) -> void:
	if cond:
		_pass += 1
	else:
		_fail += 1
		_fails.append(msg)
		print("    [FAIL] " + msg)

func eq(a, b, msg: String) -> void:
	ok(a == b, "%s (got %s, want %s)" % [msg, str(a), str(b)])


# ---- harness ----
func _controller(scrip: int = 400) -> RunController:
	var rc := RunController.new()
	rc.headless = true
	rc.db = ContentDB.new()
	rc.seed = SEED
	rc.run = RunState.new_run(SEED, _squad(rc.db), E.DRAFT_PAYOUT_X3)
	rc.run.currency["scrip"] = scrip
	return rc

## Lead is a marksman (accuracy 80 > 0) so the marksman_rifle's +accuracy rider is measurable; the
## armor stat tests do not depend on the lead's class.
func _squad(db) -> Array:
	return [
		UnitInstance.from_archetype(db, "marksman", [], "Lead", 1),
		UnitInstance.from_archetype(db, "bruiser", [], "Two", 2),
		UnitInstance.from_archetype(db, "steward", [], "Three", 3),
	]

func _first_combat_car(run):
	for c in run.line:
		if c.is_combat():
			return c
	return null

func _slot_of(rc: RunController, iid) -> String:
	return String(rc.db.item(String(iid)).get("slot", ""))

## The DEPLOYED combat body for the lead (squad[0]) — headless deployment is roster-order first-N,
## so the lead always occupies a spawn tile.
func _lead_body(rc: RunController, s):
	if s == null:
		return null
	var lead_id: int = int(rc.run.squad[0].id)
	for id in s.entity_ids_sorted():
		var e = s.entities.get(id)
		if e != null and e.is_unit and e.faction == E.Faction.PLAYER and int(e.instance_id) == lead_id:
			return e
	return null


# ============================ pre-fix repro: the consumable path never reached equipment ========
func test_pre_fix_consumable_shop_never_reached_equipment() -> void:
	# The ONLY pre-fix acquisition rail was _shop_stock() (SHOP_POOL — consumables/gadgets). Across
	# EVERY shop position it yields ZERO weapons/armor: that is the exact reachability gap this wave
	# closes. (This assertion is the contrast the strengthened reachability tests below build on.)
	var rc := _controller()
	var leaked: int = 0
	for i in range(rc.run.line.size()):
		rc.run.position = i
		for iid in rc._shop_stock():
			if _slot_of(rc, iid) in ["weapon", "armor"]:
				leaked += 1
	rc.run.position = 0
	eq(leaked, 0, "[reach] the pre-fix consumable-only shop offered ZERO weapons/armor (the gap)")


# ==================== equipment-stock GENERATOR coverage (NOT per-run reachability) =============
# HONEST SCOPE (corrected after adversarial review): iterating positions here measures the STOCK
# GENERATOR's rotation coverage — that a shop, WHENEVER one is reached, can surface any of the
# weapon/armor catalog — NOT that a given run reaches 3+ equipment. Actual per-run acquisition
# depends on shop frequency (a shopless line yields none today); RELIABLE reachability via combat/
# captain reward-drops is a tracked W7 content item, not claimed here.
func test_equipment_stock_generator_covers_the_catalog() -> void:
	# Calls _shop_equipment_stock (did NOT exist pre-fix) — cannot pass against the old build.
	var rc := _controller()
	var weapons: Dictionary = {}
	var armor: Dictionary = {}
	for i in range(rc.run.line.size()):
		rc.run.position = i
		for iid in rc._shop_equipment_stock():
			match _slot_of(rc, iid):
				"weapon": weapons[String(iid)] = true
				"armor":  armor[String(iid)] = true
				_:
					ok(false, "[reach] equipment stock offered a non-weapon/armor id '%s'" % iid)
	rc.run.position = 0
	var distinct: int = weapons.size() + armor.size()
	ok(distinct >= 3, "[reach] the stock GENERATOR's rotation surfaces >=3 distinct WEAPON/ARMOR across positions (%d: %dW/%dA) — coverage, not per-run count" % [distinct, weapons.size(), armor.size()])
	ok(weapons.size() >= 1, "[reach] the generator can surface a WEAPON (0 reachable pre-fix)")
	ok(armor.size() >= 1, "[reach] at least one ARMOR is obtainable")
	for iid in weapons.keys() + armor.keys():
		ok(not rc.db.item(String(iid)).is_empty(), "[reach] obtainable equipment id '%s' is a real authored ItemDef" % iid)


# ============================ determinism: no randi, reproduces from (seed, pos) ================
func test_equipment_stock_is_deterministic() -> void:
	# Two independent controllers on the same seed produce byte-identical equipment stock at every
	# position (the (seed^position) IntRng stream — never randi/wall-clock).
	var a := _controller()
	var b := _controller()
	var n: int = min(10, a.run.line.size())
	for i in range(n):
		a.run.position = i
		b.run.position = i
		eq(str(a._shop_equipment_stock()), str(b._shop_equipment_stock()), "[det] equip stock @pos %d reproduces byte-identically" % i)
	a.run.position = 0
	b.run.position = 0
	# Different positions generally rotate the stock (proves it is position-keyed, not a fixed pair).
	a.run.position = 0
	var s0: String = str(a._shop_equipment_stock())
	a.run.position = 3
	var s3: String = str(a._shop_equipment_stock())
	a.run.position = 0
	ok(s0 != s3, "[det] different line positions rotate the equipment stock")


# ============================ independent stream: no collision with the consumable stock ========
func test_equipment_and_consumable_streams_are_disjoint() -> void:
	var rc := _controller()
	var n: int = min(10, rc.run.line.size())
	for i in range(n):
		rc.run.position = i
		var eqs: Array = rc._shop_equipment_stock()
		var cons: Array = rc._shop_stock()
		for iid in eqs:
			ok(not (String(iid) in cons), "[stream] equip id '%s' never collides with the consumable stock @pos %d" % [iid, i])
			ok(_slot_of(rc, iid) in ["weapon", "armor"], "[stream] equip id '%s' is weapon/armor (slot=%s)" % [iid, _slot_of(rc, iid)])
	rc.run.position = 0


# ============================ the on-screen shop actually PRESENTS equipment ====================
func test_shop_spec_lists_equipment_options() -> void:
	# The widened _shop_spec surfaces weapon AND armor rows (pre-fix it listed only consumables), so a
	# player can pick them; the consumable rows the W3-1 suite pins are still present.
	var rc := _controller()
	rc.run.position = 0
	var spec: Dictionary = rc._shop_spec()
	var has_weapon := false
	var has_armor := false
	var has_consumable := false
	for opt in spec.get("options", []):
		match _slot_of(rc, opt.get("id", "")):
			"weapon":     has_weapon = true
			"armor":      has_armor = true
			"consumable", "gadget": has_consumable = true
	ok(has_weapon, "[spec] the on-screen SHOP lists a WEAPON option (pre-fix: none)")
	ok(has_armor, "[spec] the on-screen SHOP lists an ARMOR option (pre-fix: none)")
	ok(has_consumable, "[spec] the shop still lists its consumable/gadget stock (W3-1 preserved)")


# ============================ buy -> auto-equip -> confers a combat stat (weapon) ===============
func test_bought_weapon_equips_and_raises_accuracy() -> void:
	# End-to-end: at a shop that OFFERS marksman_rifle, buy it through the REAL commit rail, then
	# rebuild the SAME combat car (same seed/position -> identical modifiers) and confirm the deployed
	# lead's accuracy rose by exactly +10. Pre-fix the weapon was unreachable, so this rider never
	# landed on a combat body.
	var rc := _controller()
	var car = _first_combat_car(rc.run)
	ok(car != null, "[weapon] the line has a combat car to deploy into")
	rc.run.position = 0
	ok("marksman_rifle" in rc._shop_equipment_stock(), "[weapon] the shop at pos 0 OFFERS marksman_rifle (reachable)")
	# BARE control (before the purchase) at the SAME position -> identical car modifiers both builds.
	var bare = _lead_body(rc, rc._build_car_state(car))
	ok(bare != null, "[weapon] the lead deployed (control)")
	var acc0: int = bare.accuracy if bare != null else -1
	# Buy through the on-screen shop seam (commit rail -> market_buy -> _attach_item_to_lead).
	var res: Dictionary = rc.drive_screen_scripted(_put_shop_car(rc), "commit:marksman_rifle")
	ok(String(res.get("label", "")).begins_with("SHOP: bought"), "[weapon] the shop rail took the purchase")
	ok("marksman_rifle" in rc.run.squad[0].inventory, "[weapon] the bought weapon auto-equipped onto the lead")
	rc.run.position = 0
	var geared = _lead_body(rc, rc._build_car_state(car))
	ok(geared != null, "[weapon] the equipped lead re-deployed")
	if geared != null:
		eq(geared.accuracy - acc0, 10, "[weapon] the equipped marksman_rifle raised the deployed lead's accuracy by +10")


# ============================ buy -> auto-equip -> confers combat HP + soak (armor) =============
func test_bought_armor_equips_and_raises_hp_and_soak() -> void:
	var rc := _controller()
	var car = _first_combat_car(rc.run)
	ok(car != null, "[armor] the line has a combat car")
	rc.run.position = 0
	ok("riot_plate" in rc._shop_equipment_stock(), "[armor] the shop at pos 0 OFFERS riot_plate (reachable)")
	var bare = _lead_body(rc, rc._build_car_state(car))
	ok(bare != null, "[armor] the lead deployed (control)")
	var hp0: int = bare.max_hp if bare != null else -1
	var soak0: int = bare.first_hit_reduced if bare != null else -1
	var res: Dictionary = rc.drive_screen_scripted(_put_shop_car(rc), "commit:riot_plate")
	ok("riot_plate" in rc.run.squad[0].inventory, "[armor] the bought armor auto-equipped onto the lead")
	rc.run.position = 0
	var geared = _lead_body(rc, rc._build_car_state(car))
	ok(geared != null, "[armor] the equipped lead re-deployed")
	if geared != null:
		eq(geared.max_hp - hp0, 4, "[armor] equipped riot_plate raised the deployed lead's combat max HP by +4")
		eq(geared.first_hit_reduced - soak0, 2, "[armor] equipped riot_plate added its first-hit damage soak (+2)")


# ============================ reachable gear confers passive physics riders =====================
func test_reachable_gear_confers_physics_riders() -> void:
	# fire_axe (+3 object-integrity damage / destructible-buster) and magnetic_boots (+2 shove resist)
	# are both reachable now (offered somewhere on the line); once equipped they measurably change the
	# body. Gated on reachability (via _shop_equipment_stock scan) so the test fails on the old build.
	var rc := _controller()
	ok(_offered_somewhere(rc, "fire_axe"), "[rider] fire_axe is reachable in the shop somewhere on the line")
	ok(_offered_somewhere(rc, "magnetic_boots"), "[rider] magnetic_boots is reachable in the shop somewhere on the line")
	var u = rc.run.squad[1]   # the bruiser
	var bare = u.to_sim_entity(rc.db, Vector2i(1, 1))
	var obj0: int = bare.object_damage_bonus
	var sr0: int = bare.shove_resist
	u.inventory = ["fire_axe", "magnetic_boots"]
	var geared = u.to_sim_entity(rc.db, Vector2i(1, 1))
	eq(geared.object_damage_bonus - obj0, 3, "[rider] an equipped fire_axe adds +3 object-integrity damage (destructible buster)")
	eq(geared.shove_resist - sr0, 2, "[rider] equipped magnetic_boots add +2 shove resist")


# ============================ HONEST BOUNDARY: triggered on-hit riders are NOT passive ==========
func test_on_hit_riders_are_not_yet_passive() -> void:
	# The equip path (UnitInstance._apply_gear_to_entity — OUTSIDE this lane) applies only UNtriggered
	# passive effects; triggered on_hit riders (maul impulse, shove_shotgun/harpoon force, riot_baton
	# stun, incendiary fire) are SKIPPED, and a weapon's damageBand/range is not folded into the body
	# either. This pins that honest limit so it can't silently change: a maul confers no passive slam
	# bonus, and a scrap_pistol (pure damageBand, no effects) changes nothing measurable when carried.
	var rc := _controller()
	var u = rc.run.squad[1]
	var bare = u.to_sim_entity(rc.db, Vector2i(1, 1))
	var slam0: int = bare.slam_force_bonus
	u.inventory = ["maul"]           # maul's impulse is an on_hit trigger -> not a passive stat
	var mauled = u.to_sim_entity(rc.db, Vector2i(1, 1))
	eq(mauled.slam_force_bonus, slam0, "[boundary] a carried maul's on_hit impulse is NOT a passive slam bonus (flagged out-of-lane)")
	u.inventory = ["scrap_pistol"]   # pure damageBand, no effects -> nothing to confer via the equip path
	var pistoled = u.to_sim_entity(rc.db, Vector2i(1, 1))
	eq(pistoled.accuracy, bare.accuracy, "[boundary] a carried scrap_pistol's damageBand is not folded into the body (flagged)")


# ---- helpers ----
func _offered_somewhere(rc: RunController, iid: String) -> bool:
	var saved: int = rc.run.position
	var found := false
	for i in range(rc.run.line.size()):
		rc.run.position = i
		if iid in rc._shop_equipment_stock():
			found = true
			break
	rc.run.position = saved
	return found

## Splice a SHOP car at the current line position so drive_screen_scripted resolves against it.
func _put_shop_car(rc: RunController):
	var CarInstance = load("res://core/run/car_instance.gd")
	var car = CarInstance.new("test_shop", E.CarType.SHOP, E.Section.TAIL)
	car.recon_state = E.Recon.FULL
	rc.run.line.insert(rc.run.position, car)
	return car
