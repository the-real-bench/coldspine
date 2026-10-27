extends SceneTree
## Wave 3 — ECONOMY & PROGRESSION MADE REAL (NEW suite). Every test here REPRODUCES a pre-fix
## placebo, so a test that would pass against the OLD code is worthless by construction:
##
##   W3-1  Shop sold two phantom ids (field_kit/stim_patch) that resolved to NO ItemDef — scrip
##         spent, nothing usable. Now the stock is REAL usable ItemDefs that show in the ITEM popup.
##   W3-2  22/23 authored items had no acquisition path. Shops now rotate REAL stock by (seed,pos),
##         so a run can obtain several distinct authored items.
##   W3-3  run.upgrades was written but READ by nothing — both Workshop upgrades were placebos. They
##         now measurably change the built combat body (max HP / slam force).
##   W3-5  Class unlocks were staged but the Draft dealt ALL archetypes — locked classes appeared and
##         buying the unlock changed nothing. The Draft now gates on the unlocked class pool.
##   W3-6  gear/tail/narrative catalog kinds had zero consumers. Each now has a real run-start effect
##         (start-item / +resources / intel beat). pool was TRIMMED (no faithful in-lane consumer).
##
## Run: godot --headless --path . --script res://tests/economy_wave3_smoke.gd

const E = preload("res://core/sim_enums.gd")
const RunController = preload("res://app/run_controller.gd")
const ContentDB = preload("res://core/units/content_db.gd")
const RunState = preload("res://core/run/run_state.gd")
const UnitInstance = preload("res://core/units/unit_instance.gd")
const Draft = preload("res://core/units/draft.gd")
const IntRng = preload("res://core/int_rng.gd")
const Unlocks = preload("res://core/meta/unlocks.gd")
const Menu = preload("res://app/menu.gd")
const SaveSystem = preload("res://core/meta/save_system.gd")

const SEED := 0xC01D5

var _pass: int = 0
var _fail: int = 0
var _fails: Array = []


func _initialize() -> void:
	SaveSystem.force_sandbox = true   # harness safety — never touch the owner's real profile
	print("\n=== COLDSPINE — ECONOMY wave 3 smoke ===")
	test_w3_1_shop_sells_real_usable_items()
	test_w3_1_bought_item_is_usable_in_combat()
	test_w3_2_multiple_distinct_items_obtainable()
	test_w3_3_workshop_upgrade_changes_body_stat()
	test_w3_3_upgrade_applied_via_place_squad()
	test_w3_5_draft_gates_locked_classes()
	test_w3_5_ungated_pool_leaks_locked_classes()
	test_w3_5_class_pool_threaded_end_to_end()
	test_w3_5_consume_handoff_stages_class_pool()
	test_w3_6_gear_unlock_grants_starting_item()
	test_w3_6_tail_unlock_grants_resources()
	test_w3_6_narrative_unlock_surfaces_intel()
	test_w3_6_pool_trimmed_and_gear_ids_real()
	print("\n--- ECONOMY WAVE3: %d passed, %d failed ---" % [_pass, _fail])
	for f in _fails:
		print("    FAIL: " + f)
	if _fail == 0:
		print("ECONOMY GREEN — shop/items/workshop/class-unlocks/meta-unlocks are REAL.\n")
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


# ---- harness ----
## A headless controller with a real generated run + a small drafted-style squad.
func _controller(scrip: int = 40) -> RunController:
	var rc := RunController.new()
	rc.headless = true
	rc.db = ContentDB.new()
	rc.seed = SEED
	rc.run = RunState.new_run(SEED, _squad(rc.db), E.DRAFT_PAYOUT_X3)
	rc.run.currency["scrip"] = scrip
	return rc

func _squad(db) -> Array:
	return [
		UnitInstance.from_archetype(db, "bruiser", [], "Lead", 1),
		UnitInstance.from_archetype(db, "marksman", [], "Two", 2),
		UnitInstance.from_archetype(db, "steward", [], "Three", 3),
	]

func _first_combat_car(run):
	for c in run.line:
		if c.is_combat():
			return c
	return null

func _first_player_body(s):
	if s == null:
		return null
	for id in s.entity_ids_sorted():
		var e = s.entities.get(id)
		if e != null and e.is_unit and e.faction == E.Faction.PLAYER:
			return e
	return null

func _player_body_for_instance(s, instance_id: int):
	for id in s.entity_ids_sorted():
		var e = s.entities.get(id)
		if e != null and e.is_unit and e.faction == E.Faction.PLAYER and int(e.instance_id) == instance_id:
			return e
	return null


# ============================ W3-1: shop stock is real + usable ================
func test_w3_1_shop_sells_real_usable_items() -> void:
	var rc := _controller()
	var stock: Array = rc._shop_stock()
	ok(stock.size() >= 1, "[w3-1] the shop stocks at least one item")
	for iid in stock:
		var def: Dictionary = rc.db.item(String(iid))
		# PLACEBO REPRO: pre-fix the stock was field_kit/stim_patch — db.item() -> {} (unusable).
		ok(not def.is_empty(), "[w3-1] stock id '%s' resolves to a real ItemDef" % iid)
		ok(String(def.get("slot", "")) in ["consumable", "gadget"], "[w3-1] stock id '%s' is usable (slot=%s)" % [iid, String(def.get("slot", ""))])
		ok(iid != "field_kit" and iid != "stim_patch", "[w3-1] the phantom ids are gone (%s)" % iid)


func test_w3_1_bought_item_is_usable_in_combat() -> void:
	# Buy a real stocked item, build a combat body carrying it, and confirm it appears in the ITEM
	# popup (_usable_item_entries) — the exact gate that arms UseItemCommand. Pre-fix a phantom id was
	# filtered out here (db.item() empty), so the ITEM popup never listed it and it could never fire.
	var rc := _controller()
	var car = _first_combat_car(rc.run)
	ok(car != null, "[w3-1] the line has a combat car to deploy into")
	var iid: String = ""
	for s in rc._shop_stock():
		if String(rc.db.item(String(s)).get("slot", "")) == "consumable":
			iid = String(s)
			break
	if iid == "":
		iid = String(rc._shop_stock()[0])
	# attach to the lead as a purchase would, then build the real combat body
	rc._attach_item_to_lead(iid)
	var st = rc._build_car_state(car)
	rc.state = st   # _usable_item_entries reads self.state (turn stays null -> ap 0, still listed)
	var lead = _player_body_for_instance(st, rc.run.squad[0].id)
	ok(lead != null, "[w3-1] the lead deployed into the car")
	var listed := false
	if lead != null:
		for row in rc._usable_item_entries(int(lead.id)):
			if String(row.get("id", "")) == iid:
				listed = true
				break
	ok(listed, "[w3-1] the bought item '%s' shows in the ITEM popup (UseItemCommand-armable)" % iid)


# ============================ W3-2: several items obtainable per run ===========
func test_w3_2_multiple_distinct_items_obtainable() -> void:
	var rc := _controller()
	var obtainable: Dictionary = {}
	var equipment: Dictionary = {}   # W3-2 (Wave 3b): track WEAPON/ARMOR reachability, not just consumables
	var n: int = min(8, rc.run.line.size())
	for i in range(n):
		rc.run.position = i
		for iid in rc._shop_stock():
			obtainable[String(iid)] = true
		# Wave 3b widened the shop with a rotating WEAPON/ARMOR stock — fold it into obtainability.
		for iid in rc._shop_equipment_stock():
			obtainable[String(iid)] = true
			if String(rc.db.item(String(iid)).get("slot", "")) in ["weapon", "armor"]:
				equipment[String(iid)] = true
	rc.run.position = 0
	# PLACEBO REPRO: pre-fix EVERY shop sold the same {field_kit, stim_patch} -> 0 real authored items.
	ok(obtainable.size() >= 2, "[w3-2] >1 distinct item is obtainable across the run's shops (%d)" % obtainable.size())
	for iid in obtainable.keys():
		ok(not rc.db.item(String(iid)).is_empty(), "[w3-2] obtainable id '%s' is a real authored item" % iid)
	# W3-2 (Wave 3b): the shop's WEAPON/ARMOR stock GENERATOR now surfaces equipment (pre-fix it stocked
	# only consumables/gadgets, so all 9 weapons + 5/6 armor had zero acquisition path). HONEST SCOPE
	# (corrected after review): this counts the generator's rotation coverage across positions, proving
	# a shop CAN offer equipment — NOT that every run reaches it (a shopless line yields none; reliable
	# per-run acquisition via reward-drops is tracked W7). Every offered id is a real weapon/armor.
	ok(equipment.size() >= 3, "[w3-2] the shop equipment generator surfaces >=3 distinct WEAPON/ARMOR across positions (%d) — coverage, not per-run guarantee" % equipment.size())
	for iid in equipment.keys():
		ok(String(rc.db.item(String(iid)).get("slot", "")) in ["weapon", "armor"], "[w3-2] offered equipment '%s' is a weapon/armor" % iid)


# ============================ W3-3: workshop upgrades apply ====================
func test_w3_3_workshop_upgrade_changes_body_stat() -> void:
	# Direct seam: the SAME persistent unit, built with vs without the upgrade applied.
	var rc := _controller()
	var u = UnitInstance.from_archetype(rc.db, "bruiser", [], "T", 9)
	var base = u.to_sim_entity(rc.db, Vector2i(1, 1))
	var base_hp: int = base.max_hp
	var base_slam: int = base.slam_force_bonus
	# PLACEBO REPRO: run.upgrades ALONE (as the old code left it) is inert — to_sim_entity never reads it.
	rc.run.upgrades = ["reinforced_plating"]
	var inert = u.to_sim_entity(rc.db, Vector2i(1, 1))
	eq(inert.max_hp, base_hp, "[w3-3] run.upgrades alone does NOT change the body (proves it needs the build hook)")
	# WITH the hook: the plating raises max HP (and current), sharpened edge raises slam force.
	var plated = u.to_sim_entity(rc.db, Vector2i(1, 1))
	rc._apply_upgrades_to_body(plated)
	eq(plated.max_hp, base_hp + E.WORKSHOP_PLATING_HP, "[w3-3] reinforced_plating raises max HP by WORKSHOP_PLATING_HP")
	ok(plated.hp >= base.hp, "[w3-3] reinforced_plating also bumps current HP")
	rc.run.upgrades = ["sharpened_edge"]
	var edged = u.to_sim_entity(rc.db, Vector2i(1, 1))
	rc._apply_upgrades_to_body(edged)
	eq(edged.slam_force_bonus, base_slam + E.WORKSHOP_EDGE_FORCE, "[w3-3] sharpened_edge raises slam_force_bonus by WORKSHOP_EDGE_FORCE")


func test_w3_3_upgrade_applied_via_place_squad() -> void:
	# Integration: buying at the Workshop rail then building the real car state changes the deployed
	# body's HP by exactly WORKSHOP_PLATING_HP (same car/seed -> identical modifiers both builds, so
	# the delta isolates the upgrade). Pre-fix _place_squad never read run.upgrades -> delta 0.
	var rc := _controller()
	var car = _first_combat_car(rc.run)
	ok(car != null, "[w3-3] the line has a combat car")
	var before = _first_player_body(rc._build_car_state(car))
	ok(before != null, "[w3-3] a player body deployed (control)")
	var hp_before: int = before.max_hp if before != null else -1
	ok(rc.run.workshop_upgrade("reinforced_plating"), "[w3-3] the Workshop rail took the purchase")
	var after = _first_player_body(rc._build_car_state(car))
	var hp_after: int = after.max_hp if after != null else -1
	eq(hp_after - hp_before, E.WORKSHOP_PLATING_HP, "[w3-3] the built combat body gained WORKSHOP_PLATING_HP from the purchase")


# ============================ W3-5: class-unlock gates the draft ===============
func _roll_archetypes(pool: Array, n: int) -> Dictionary:
	var db := ContentDB.new()
	var d := Draft.new(db, IntRng.new((SEED ^ 0xDEADBEEF) & 0xFFFFFFFF))
	d.allowed_archetypes = pool
	var seen: Dictionary = {}
	for _i in range(n):
		var u = d._roll_candidate("balanced")
		seen[String(u.archetype_id)] = true
	return seen

func test_w3_5_draft_gates_locked_classes() -> void:
	# With only the baseline classes unlocked, NO firebrand/saboteur candidate is ever dealt.
	var seen := _roll_archetypes(["bruiser", "marksman", "steward"], 300)
	ok(not seen.has("firebrand"), "[w3-5] a gated draft never deals a Firebrand candidate")
	ok(not seen.has("saboteur"), "[w3-5] a gated draft never deals a Saboteur candidate")
	ok(seen.has("bruiser") and seen.has("marksman") and seen.has("steward"), "[w3-5] the baseline classes still deal")

func test_w3_5_ungated_pool_leaks_locked_classes() -> void:
	# PLACEBO REPRO: the OLD draft rolled from ALL archetypes (allowed_archetypes empty) -> the locked
	# classes leaked into the draft before purchase. This proves the gate above is load-bearing.
	var seen := _roll_archetypes([], 300)
	ok(seen.has("firebrand"), "[w3-5] the ungated pool DID leak Firebrand (the pre-fix placebo)")
	ok(seen.has("saboteur"), "[w3-5] the ungated pool DID leak Saboteur (the pre-fix placebo)")

func test_w3_5_class_pool_threaded_end_to_end() -> void:
	var allowed := ["bruiser", "marksman", "steward"]
	var rc := RunController.new()
	rc.headless = true
	rc.db = ContentDB.new()
	rc.seed = SEED
	rc.class_pool = allowed
	rc._run_draft(3)
	ok(rc.run.squad.size() >= 1, "[w3-5] the gated draft still produced a squad")
	for u in rc.run.squad:
		ok(allowed.has(String(u.archetype_id)), "[w3-5] drafted %s is within the unlocked class pool" % u.archetype_id)
	# With firebrand unlocked, it CAN be drafted (proves 'unlocked -> reachable').
	var seen := _roll_archetypes(["bruiser", "marksman", "steward", "firebrand", "saboteur"], 300)
	ok(seen.has("firebrand"), "[w3-5] once unlocked, Firebrand can appear in the draft")

func test_w3_5_consume_handoff_stages_class_pool() -> void:
	Menu.MenuHandoff.reset()
	Menu.MenuHandoff.unlocked_class_ids = ["bruiser", "marksman", "steward", "saboteur"]
	var rc := RunController.new()
	rc.headless = true
	rc.db = ContentDB.new()
	rc.seed = SEED
	rc.consume_handoff()
	eq(rc.class_pool, ["bruiser", "marksman", "steward", "saboteur"], "[w3-5] consume_handoff threads unlocked_class_ids into class_pool")
	Menu.MenuHandoff.reset()


# ============================ W3-6: gear / tail / narrative unlocks ============
func test_w3_6_gear_unlock_grants_starting_item() -> void:
	var rc := _controller()
	ok(rc.run.squad[0].inventory.is_empty(), "[w3-6] the lead starts with no gear (control)")
	rc.apply_meta_unlocks_to_run(["breaching_charge"])
	ok("breaching_charge" in rc.run.squad[0].inventory, "[w3-6] a GEAR unlock grants a real starting item")
	ok(not rc.db.item("breaching_charge").is_empty(), "[w3-6] the granted gear id is a real ItemDef")

func test_w3_6_tail_unlock_grants_resources() -> void:
	var rc := _controller(10)
	var s_before: int = rc.run.currency["scrip"]
	var sup_before: int = rc.run.currency["supplies"]
	rc.apply_meta_unlocks_to_run(["tail_extra_scrip", "tail_extra_supplies"])
	eq(rc.run.currency["scrip"], s_before + RunController.TAIL_UNLOCK_SCRIP, "[w3-6] tail_extra_scrip adds starting scrip")
	eq(rc.run.currency["supplies"], sup_before + RunController.TAIL_UNLOCK_SUPPLIES, "[w3-6] tail_extra_supplies adds starting supplies")

func test_w3_6_narrative_unlock_surfaces_intel() -> void:
	var rc := _controller()
	rc.trace.clear()
	rc.apply_meta_unlocks_to_run(["narrative_conductor_log"])
	var saw := false
	for t in rc.trace:
		if String(t).begins_with("INTEL:"):
			saw = true
	ok(saw, "[w3-6] a NARRATIVE unlock surfaces an intel beat in the run trace")

func test_w3_6_pool_trimmed_and_gear_ids_real() -> void:
	# The phantom gear ids are gone; the catalog now points at real ItemDefs.
	var db := ContentDB.new()
	ok(db.item("breach_charge").is_empty(), "[w3-6] the OLD phantom gear id (breach_charge) is not a real item")
	for gid in ["breaching_charge", "ablative_harness", "grapple"]:
		eq(Unlocks.kind(gid), Unlocks.KIND_GEAR, "[w3-6] catalog gear id '%s' is a real ItemDef" % gid)
		ok(not db.item(gid).is_empty(), "[w3-6] catalog gear id '%s' resolves to an ItemDef" % gid)
	# pool_engineers/pool_medics were TRIMMED (no runtime consumer) — not in the catalog anymore.
	ok(not Unlocks.catalog_ids().has("pool_engineers"), "[w3-6] pool_engineers trimmed from the catalog")
	ok(not Unlocks.catalog_ids().has("pool_medics"), "[w3-6] pool_medics trimmed from the catalog")
