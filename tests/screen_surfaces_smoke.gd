extends SceneTree
## SCREEN-SURFACES smoke (Wave 5 — PRESENTATION / UX polish for app/screens/run_screens.gd).
## On-screen-only construction checks: the RunScreens surface is instanced headless and its show_*
## builders are driven with representative specs, then the NODE STRUCTURE is asserted (portraits,
## mini-glyphs, flavor art, button StyleBox states, humanized copy, click-forwarding). RunScreens is
## never built by the headless run/balance suites, so none of this touches sim determinism — the
## on-screen path is gated `not headless` in the controller. This suite pins the Wave-5 fixes so a
## regression fails loud without a windowed screenshot pass.
##
## Run: godot --headless --path . --script res://tests/screen_surfaces_smoke.gd

const E = preload("res://core/sim_enums.gd")
const Pal = preload("res://render/palette.gd")
const RunScreens = preload("res://app/screens/run_screens.gd")
const ContentDB = preload("res://core/units/content_db.gd")
const UnitInstance = preload("res://core/units/unit_instance.gd")

const ARCHES := ["bruiser", "marksman", "saboteur", "steward", "firebrand"]

var _pass: int = 0
var _fail: int = 0
var _fails: Array = []
var _db = null


## A minimal duck-typed Draft the RunScreens draft surface reads (current_choices / picks / finished /
## round_idx / rounds_total). Avoids depending on the real draft.gd internals for a pure render check.
class _DraftStub extends RefCounted:
	var current_choices: Array = []
	var picks: Array = []
	var finished: bool = false
	var round_idx: int = 0
	var rounds_total: int = 3


## A minimal run for the spectator show_shop (reads run.currency only).
class _RunStub extends RefCounted:
	var currency: Dictionary = {"scrip": 12, "supplies": 3, "tools": 2}
	var squad: Array = []


func _initialize() -> void:
	print("\n=== COLDSPINE — SCREEN-SURFACES smoke (Wave 5 presentation, headless) ===")
	_db = ContentDB.new()
	test_w5_1_draft_card_portraits()
	test_w5_3_roster_mini_glyph()
	test_w5_2_recruit_dossier_portrait()
	test_w5_2_explicit_portrait_key()
	test_w5_5_levelup_portrait_and_queue_count()
	test_w5_6_levelup_no_raw_ids()
	test_w5_6_shop_no_raw_ids()
	test_w5_7_buttons_full_statebox_set()
	test_w5_9_ending_panel_forwards_click()
	test_w5_14_deploy_row_glyph_no_tofu()
	test_w5_15_econ_flavor_art_region()
	test_w5_18_bruiser_token_maps()
	print("\n--- SCREEN-SURFACES: %d passed, %d failed ---" % [_pass, _fail])
	for f in _fails:
		print("    FAIL: " + f)
	if _fail == 0:
		print("SCREEN-SURFACES GREEN — Wave-5 presentation nodes build as specified (portraits/glyphs/states/copy).")
	quit(0 if _fail == 0 else 1)


func ok(cond: bool, msg: String) -> void:
	if cond:
		_pass += 1
	else:
		_fail += 1
		_fails.append(msg)
		print("    [FAIL] " + msg)


# ============================ harness =========================================
func _screens() -> RunScreens:
	var rs := RunScreens.new()
	root.add_child(rs)
	rs._ready()   # SceneTree defers the ready notification — fire the build entry point explicitly
	return rs


func _unit(arch: String, nm: String, id: int) -> Variant:
	return UnitInstance.from_archetype(_db, arch, [], nm, id)


## First descendant TextureRect matching `name_pattern` (recursive, unowned), or null.
func _tex_named(n: Node, name_pattern: String) -> TextureRect:
	var arr := n.find_children(name_pattern, "TextureRect", true, false)
	return arr[0] if not arr.is_empty() else null


## Concatenated text of every Label / RichTextLabel under `n` (for copy assertions).
func _collect_text(n: Node) -> String:
	var s := ""
	if n is Label:
		s += " " + n.text
	elif n is RichTextLabel:
		s += " " + n.text
	for c in n.get_children():
		s += _collect_text(c)
	return s


## True if `text` contains a snake_case id token (a leaked raw id).
func _has_snake(text: String) -> bool:
	var re := RegEx.new()
	re.compile("[a-z][a-z0-9]*_[a-z0-9]")
	return re.search(text) != null


# ============================ W5-1 draft card portraits =======================
func test_w5_1_draft_card_portraits() -> void:
	var rs := _screens()
	var draft := _DraftStub.new()
	for arch in ARCHES:
		draft.current_choices = [_unit(arch, arch.to_upper() + "-01", 1)]
		rs.show_draft_interactive(draft, _db)
		# Assert against _card_buttons (cleared+rebuilt each call) — card_row.get_children() still holds
		# prior cards until their deferred queue_free() flushes (no frame runs between calls in a script).
		ok(rs._card_buttons.size() == 1, "[w5-1] %s: one candidate card built" % arch)
		var card: Node = rs._card_buttons[0]
		var portrait := _tex_named(card, "Portrait")
		ok(portrait != null, "[w5-1] %s: draft card builds a portrait TextureRect" % arch)
		if portrait != null:
			ok(portrait.texture is Texture2D, "[w5-1] %s: portrait has a real texture (final-or-placeholder)" % arch)
			ok(portrait.size.x >= 128 and portrait.size.y >= 150,
				"[w5-1] %s: portrait sized ~140x180 (got %dx%d, larger than the 64px token)" % [arch, int(portrait.size.x), int(portrait.size.y)])
	rs.free()


# ============================ W5-3 roster mini-glyph ==========================
func test_w5_3_roster_mini_glyph() -> void:
	var rs := _screens()
	var draft := _DraftStub.new()
	draft.picks = [_unit("bruiser", "BRU-01", 1)]
	draft.current_choices = []
	rs.show_draft_interactive(draft, _db)
	ok(rs.roster_row.get_child_count() >= 1, "[w5-3] roster strip built with the filled slot")
	var slot := rs.roster_row.get_child(0)
	var glyph := _tex_named(slot, "Glyph")
	ok(glyph != null and glyph.texture is Texture2D, "[w5-3] a filled roster slot has a 40px archetype mini-glyph texture")
	if glyph != null:
		ok(int(glyph.custom_minimum_size.x) == 40, "[w5-3] the roster mini-glyph is 40px")
	rs.free()


# ============================ W5-2 recruit dossier portrait ===================
func test_w5_2_recruit_dossier_portrait() -> void:
	var rs := _screens()
	# The recruit spec carries the candidate archetype in a dossier line ("<name>  [<archetype>]") — the
	# surface derives the portrait from it (FAC_NEUTRAL ring) with no cross-lane change.
	var spec := {
		"title": "SANCTUARY — RECRUIT", "title_col": Pal.CYAN,
		"info_lines": [
			{"text": "DOSSIER — VETTING", "col": Pal.AMBER},
			{"text": "Vasquez-07   [saboteur]", "col": Pal.AMBER},
			{"text": "HP 9/9   L1", "col": Pal.CYAN},
		],
		"options": [{"id": "accept", "label": "[ ACCEPT ]"}, {"id": "decline", "label": "[ DECLINE ]"}],
		"leave": true,
	}
	rs.show_econ_choices("recruit", spec)
	ok(rs.econ_portrait_holder != null and rs.econ_portrait_holder.visible, "[w5-2] recruit dossier shows the portrait holder")
	var p := _tex_named(rs.econ_portrait_holder, "Portrait")
	ok(p != null and p.texture is Texture2D, "[w5-2] the recruit card builds a portrait node with a real texture")
	rs.free()


func test_w5_2_explicit_portrait_key() -> void:
	var rs := _screens()
	# An explicit spec.portrait renders on ANY econ screen; a screen without one hides the holder.
	rs.show_econ_choices("event", {"title": "EVENT", "portrait": "firebrand", "portrait_ring": Pal.FAC_NEUTRAL, "options": []})
	ok(_tex_named(rs.econ_portrait_holder, "Portrait") != null, "[w5-2] an explicit portrait key renders a portrait node")
	rs.show_econ_choices("shop", {"title": "SHOP", "options": []})
	ok(not rs.econ_portrait_holder.visible, "[w5-2] a screen without a portrait hides the holder (dossier text reclaims the space)")
	rs.free()


# ============================ W5-5 level-up portrait + count ===================
func test_w5_5_levelup_portrait_and_queue_count() -> void:
	var rs := _screens()
	# queue_total = 3 owed picks, but only 1 ability card this pick — the count must read the QUEUE (3),
	# not the card count (1).
	rs.show_levelup({
		"name": "VASQUEZ-07", "level": 3, "archetype": "marksman",
		"queue_idx": 0, "queue_total": 3,
		"options": [{"id": "steady_hands", "name": "Steady Hands", "tier": "T1", "blurb": "1 AP"}],
	})
	var p := _tex_named(rs.levelup_portrait_holder, "Portrait")
	ok(p != null and p.texture is Texture2D, "[w5-5] the level-up header builds the leveling unit's portrait")
	ok(rs.levelup_queue_label.text.contains("of 3"), "[w5-5] PICK-count label reflects the queue (3 owed), not the 1 card (got '%s')" % rs.levelup_queue_label.text)
	ok(rs.levelup_queue_label.visible, "[w5-5] the queue indicator shows when >1 pick is owed")
	rs.free()


# ============================ W5-6 no raw ids in screen copy ===================
func test_w5_6_levelup_no_raw_ids() -> void:
	var rs := _screens()
	# A blurb carrying the exact raw effect-kind ids the controller leaks for unmapped kinds.
	rs.show_levelup({
		"name": "REYES-02", "level": 4, "archetype": "saboteur",
		"queue_idx": 0, "queue_total": 1,
		"options": [{"id": "gas_tap", "name": "Gas Tap", "tier": "T2",
			"blurb": "2 AP  ·  ranged_attack, damage_bonus_vs_status, ignore_cover"}],
	})
	ok(rs.levelup_card_row.get_child_count() == 1, "[w5-6] the level-up card built")
	var copy := _collect_text(rs.levelup_card_row.get_child(0))
	ok(not _has_snake(copy), "[w5-6] the built level-up card contains NO snake_case id (got: %s)" % copy.strip_edges())
	rs.free()


func test_w5_6_shop_no_raw_ids() -> void:
	var rs := _screens()
	# Spectator shop panel: raw stock ids must render as human copy.
	rs.show_shop(_RunStub.new(), ["reinforced_plating", "medkit"])
	ok(not _has_snake(rs.body_label.text), "[w5-6] the spectator shop panel contains NO snake_case item id (got: %s)" % rs.body_label.text)
	# Interactive econ row with NO label falls back to a humanized id (never the raw snake_case).
	rs.show_econ_choices("shop", {"title": "SHOP", "options": [{"id": "reinforced_plating"}], "leave": true})
	var row := rs.econ_rows.get_child(0)
	ok(not _has_snake(_collect_text(row)), "[w5-6] an econ row with no label humanizes the id (no snake_case)")
	rs.free()


# ============================ W5-7 button StyleBox states ======================
func test_w5_7_buttons_full_statebox_set() -> void:
	var rs := _screens()
	# ctl_take is built by _build_draft_surface via the shared _draft_button (every screen button).
	var b: Button = rs.ctl_take
	for st in ["normal", "hover", "pressed", "disabled", "focus"]:
		ok(b.has_theme_stylebox_override(st) and b.get_theme_stylebox(st) is StyleBoxFlat,
			"[w5-7] screen button carries a %s StyleBoxFlat override (not engine-default grey)" % st)
	# a couple of other screen buttons carry it too (LEAVE, deploy commit).
	ok(rs.econ_leave_btn.has_theme_stylebox_override("hover"), "[w5-7] the econ LEAVE button carries a hover StyleBox")
	rs.free()


# ============================ W5-9 ending panel click ==========================
func test_w5_9_ending_panel_forwards_click() -> void:
	var rs := _screens()
	# The ending/payout card must not swallow the advance click — panel + text children set to IGNORE
	# so the controller's _unhandled_input _run_over handler receives a click over the card and advances.
	ok(rs.panel.mouse_filter == Control.MOUSE_FILTER_IGNORE, "[w5-9] the ending/payout panel does not swallow the click")
	ok(rs.body_label.mouse_filter == Control.MOUSE_FILTER_IGNORE, "[w5-9] the ending body text does not swallow the click")
	ok(rs.prompt_label.mouse_filter == Control.MOUSE_FILTER_IGNORE, "[w5-9] the ending prompt does not swallow the click")
	rs.free()


# ============================ W5-14 deploy row glyph ==========================
func test_w5_14_deploy_row_glyph_no_tofu() -> void:
	var rs := _screens()
	rs.show_deploy_picker({"members": [
		{"id": 1, "label": "Reyes-02 [saboteur]", "detail": "LV 1", "hp": 8, "max_hp": 10, "selected": true},
		{"id": 2, "label": "Cole-03 [bruiser]", "detail": "LV 2", "hp": 12, "max_hp": 12, "selected": false},
	], "need": 1})
	ok(rs.deploy_rows.get_child_count() == 2, "[w5-14] a deploy row per member")
	var row := rs.deploy_rows.get_child(0)
	var glyph := _tex_named(row, "Glyph")
	ok(glyph != null and glyph.texture is Texture2D, "[w5-14] a deploy row builds a real archetype mini-glyph (no tofu)")
	var txt := _collect_text(row)
	ok(not txt.contains("▮") and not txt.contains("▯") and not txt.contains("□"), "[w5-14] the tofu glyph markers are gone from the row copy")
	rs.free()


# ============================ W5-15 econ flavor art ===========================
func test_w5_15_econ_flavor_art_region() -> void:
	var rs := _screens()
	rs.show_econ_choices("shop", {"title": "BLACK-MARKET SHOP", "options": [], "leave": true})
	ok(rs.econ_flavor != null and rs.econ_flavor.visible, "[w5-15] the econ flavor art region is present + visible")
	var ft := _tex_named(rs.econ_flavor, "Flavor")
	ok(ft != null and ft.texture is Texture2D, "[w5-15] the flavor region has a real car-art texture")
	ok(rs.econ_flavor_name.text == "BLACK-MARKET SHOP", "[w5-15] the flavor region names the car (got '%s')" % rs.econ_flavor_name.text)
	rs.free()


# ============================ W5-18 bruiser token =============================
func test_w5_18_bruiser_token_maps() -> void:
	var rs := _screens()
	# The redrawn bruiser board token still resolves to real art (tex_coverage_smoke proves the id map).
	ok(rs._load_tex("unit_bruiser") is Texture2D, "[w5-18] the redrawn unit_bruiser token still maps to a real texture")
	rs.free()
