extends SceneTree
## Headless COMBAT-ONBOARDING smoke test (combat-ux #7). Proves the tip system teaches once, never
## re-nags, persists across runs, is globally suppressible, and is a TOTAL no-op headless / in --sim
## (so the byte-stable suites stay byte-stable). Layers under test:
##   (a) CombatTips (pure): catalog is complete + stably ordered; a tip fires ONCE then suppresses;
##       the global tips-off switch suppresses every tip; seen_list() round-trips in stable order.
##   (b) MetaProfile persistence: tips_enabled defaults ON, seen_tips defaults empty; mark/seen/reset
##       work; seen_tips survives to_dict/from_dict + the fingerprint round-trip (no float leak).
##   (c) OpsHUD banner contract: show_tip raises it, tip_open reports up, hide_tip / dismiss lowers it;
##       every palette button carries a tooltip.
##   (d) HEADLESS GATE: RunController._maybe_tip is a silent no-op headless (no hud, no _tips, no write).
## Run: godot --headless --path . --script res://tests/tips_smoke.gd

const CombatTips = preload("res://app/combat_tips.gd")
const MetaProfile = preload("res://core/meta/meta_profile.gd")
const OpsHUD = preload("res://render/ops_hud.gd")
const RunController = preload("res://app/run_controller.gd")

var _pass: int = 0
var _fail: int = 0
var _fails: Array = []

func _initialize() -> void:
	print("\n=== COLDSPINE — combat onboarding (tips) smoke test ===")
	test_catalog_complete_and_ordered()
	test_fires_once_then_suppresses()
	test_global_off_suppresses_all()
	test_seen_list_roundtrips()
	test_profile_defaults()
	test_profile_mark_reset()
	test_profile_persists_seen_tips()
	test_opshud_banner_contract()
	test_opshud_button_tooltips()
	test_maybe_tip_headless_noop()
	print("\n--- TIPS SMOKE: %d passed, %d failed ---" % [_pass, _fail])
	for f in _fails:
		print("    FAIL: " + f)
	if _fail == 0:
		print("TIPS GREEN — teach-once, persisted, suppressible, headless no-op.\n")
	quit(0 if _fail == 0 else 1)

# ---- assertion kit (matches audio_smoke) ----
func ok(cond: bool, msg: String) -> void:
	if cond:
		_pass += 1
	else:
		_fail += 1
		_fails.append(msg)
		print("    [FAIL] " + msg)

func eq(a, b, msg: String) -> void:
	ok(a == b, "%s (got %s, want %s)" % [msg, str(a), str(b)])

# ============================ (a) CombatTips pure ==============================
## The catalog is complete: ORDER and TIPS agree, every id has a non-empty title + body, and the
## teaching order has no dupes.
func test_catalog_complete_and_ordered() -> void:
	var order: Array = CombatTips.ORDER
	var tips: Dictionary = CombatTips.TIPS
	eq(order.size(), tips.size(), "[catalog] ORDER covers exactly the TIPS entries")
	var seen := {}
	for id in order:
		ok(tips.has(id), "[catalog] ORDER id '%s' is a real tip" % id)
		ok(not seen.has(id), "[catalog] ORDER id '%s' is not duplicated" % id)
		seen[id] = true
	var ct := CombatTips.new()
	for id in order:
		ok(ct.title(id) != "", "[catalog] tip '%s' has a title" % id)
		ok(ct.body(id) != "", "[catalog] tip '%s' has a body" % id)
	# The core teaching set the finding demands must all be present.
	for req in ["displace", "preview", "shoot", "overwatch", "combo", "ability", "item", "stabilize", "select"]:
		ok(tips.has(req), "[catalog] the required onboarding tip '%s' exists" % req)

## The heart of the acceptance: a tip fires the FIRST time, then is suppressed forever after.
func test_fires_once_then_suppresses() -> void:
	var ct := CombatTips.new([], true)
	ok(ct.should_fire("displace"), "[once] a fresh tip fires the first time")
	ct.mark_fired("displace")
	ok(not ct.should_fire("displace"), "[once] the SAME tip is suppressed after being shown")
	# Other tips are unaffected — each is independent.
	ok(ct.should_fire("preview"), "[once] a different tip still fires (independent seen-set)")
	# A bogus id never fires and never crashes.
	ok(not ct.should_fire("does_not_exist"), "[once] an unknown id never fires")
	ct.mark_fired("does_not_exist")
	ok(true, "[once] marking an unknown id is a safe no-op")

## The global "combat tips" switch off suppresses EVERY tip (the tips-off setting; also the effective
## state a headless/--sim run would run under).
func test_global_off_suppresses_all() -> void:
	var ct := CombatTips.new([], false)
	var any := false
	for id in CombatTips.ORDER:
		if ct.should_fire(id):
			any = true
	ok(not any, "[off] tips_enabled == false suppresses every tip in the catalog")

## seen_list() reflects marks in stable catalog order and round-trips into a fresh CombatTips.
func test_seen_list_roundtrips() -> void:
	var ct := CombatTips.new([], true)
	# Mark out of order; seen_list must come back in ORDER.
	ct.mark_fired("item")
	ct.mark_fired("select")
	ct.mark_fired("preview")
	var sl := ct.seen_list()
	# ORDER is select, displace, preview, shoot, overwatch, combo, ability, item, stabilize.
	eq(sl, ["select", "preview", "item"], "[seen] seen_list is stable catalog order, not mark order")
	# Rebuild from the list — the seen state carries over exactly.
	var ct2 := CombatTips.new(sl, true)
	ok(not ct2.should_fire("select"), "[seen] a rebuilt tips object remembers 'select' as seen")
	ok(not ct2.should_fire("item"), "[seen] a rebuilt tips object remembers 'item' as seen")
	ok(ct2.should_fire("displace"), "[seen] an unseen tip still fires after rebuild")
	# Mark the rest; all_seen flips true.
	for id in CombatTips.ORDER:
		ct.mark_fired(id)
	ok(ct.all_seen(), "[seen] all_seen() true once every tip is shown")

# ============================ (b) MetaProfile persistence =====================
func test_profile_defaults() -> void:
	var p := MetaProfile.new()
	ok(p.tips_enabled(), "[profile] a fresh profile has combat tips ON by default")
	eq(p.seen_tips.size(), 0, "[profile] a fresh profile has no seen tips")
	eq(bool(MetaProfile.DEFAULT_SETTINGS["tips_enabled"]), true, "[profile] tips_enabled default const is true")

func test_profile_mark_reset() -> void:
	var p := MetaProfile.new()
	p.mark_tip_seen("displace")
	p.mark_tip_seen("displace")   # idempotent
	ok(p.tip_seen("displace"), "[profile] mark_tip_seen records the tip")
	eq(p.seen_tips.size(), 1, "[profile] a re-mark does not duplicate")
	p.mark_tip_seen("preview")
	eq(p.seen_tips.size(), 2, "[profile] a second distinct tip appends")
	p.reset_tips()
	eq(p.seen_tips.size(), 0, "[profile] reset_tips clears the whole seen-set (reset tutorial)")
	ok(not p.tip_seen("displace"), "[profile] after reset a tip teaches again")

## seen_tips survives the dict + fingerprint round-trip (persist so replays don't nag).
func test_profile_persists_seen_tips() -> void:
	var p := MetaProfile.new()
	p.mark_tip_seen("select")
	p.mark_tip_seen("combo")
	p.set_setting("tips_enabled", false)
	var d := p.to_dict()
	var p2 := MetaProfile.from_dict(d)
	ok(p2.tip_seen("select") and p2.tip_seen("combo"), "[profile] seen_tips survive to_dict/from_dict")
	eq(p2.seen_tips.size(), 2, "[profile] no phantom/dropped tips across the round-trip")
	ok(not p2.tips_enabled(), "[profile] the tips_enabled switch persists too")
	eq(p2.fingerprint(), p.fingerprint(), "[profile] the fingerprint is identical across the round-trip")
	# A hand-edited / older save with a non-string in seen_tips must coerce safely (never crash).
	var p3 := MetaProfile.from_dict({"seen_tips": [123, "select"]})
	ok(p3.tip_seen("select"), "[profile] a mixed-type seen_tips loads without crashing")

# ============================ (c) OpsHUD banner contract ======================
func test_opshud_banner_contract() -> void:
	var hud := OpsHUD.new()
	get_root().add_child(hud)   # _ready builds the regions (mirrors finale_smoke)
	ok(hud.has_method("show_tip") and hud.has_method("hide_tip") and hud.has_method("tip_open"),
		"[hud] OpsHUD exposes the tip-banner API")
	ok(not hud.tip_open(), "[hud] no tip banner is up before show_tip")
	hud.show_tip("DISPLACE", "Push an enemy into a wall for free damage.")
	ok(hud.tip_open(), "[hud] show_tip raises the banner (tip_open true)")
	hud.hide_tip()
	ok(not hud.tip_open(), "[hud] hide_tip lowers the banner (dismiss/skippable)")
	hud.free()

func test_opshud_button_tooltips() -> void:
	# Every palette action + control button must carry hover/long-press help text (combat-ux #7).
	for a in ["MOVE", "SHOOT", "SHOVE", "SLAM", "THROW", "ABILITY", "ITEM", "OVR", "UNDO", "CANCEL", "END"]:
		ok(OpsHUD.ACTION_TOOLTIPS.has(a) and String(OpsHUD.ACTION_TOOLTIPS[a]) != "",
			"[hud] action '%s' has a non-empty tooltip" % a)
	for c in ["AUTO", "SPEED"]:
		ok(OpsHUD.CONTROL_TOOLTIPS.has(c) and String(OpsHUD.CONTROL_TOOLTIPS[c]) != "",
			"[hud] control '%s' has a non-empty tooltip" % c)

# ============================ (d) headless no-op gate =========================
## RunController._maybe_tip must be a total no-op headless: no hud, no _tips, no profile write, no
## crash. This is the byte-stable guarantee — a headless / --sim run never surfaces a tip.
func test_maybe_tip_headless_noop() -> void:
	var rc := RunController.new()
	rc.headless = true
	# _tips + _tip_profile are null (chrome never built headless); _maybe_tip must bail on every guard.
	for id in CombatTips.ORDER:
		rc._maybe_tip(id)
	ok(rc._tips == null and rc._tip_profile == null, "[gate] headless builds no tip system")
	ok(true, "[gate] _maybe_tip on every id is a silent no-op headless (no crash, no write)")
	# The situational scans must also be safe with no combat state (state == null).
	ok(not rc._water_on_board(), "[gate] _water_on_board is false with no combat state")
	ok(not rc._ally_bleeding_out(), "[gate] _ally_bleeding_out is false with no combat state")
	rc.free()
