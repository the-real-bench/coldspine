extends SceneTree
## HUD-MENU WAVE 5 smoke test (presentation / UX polish, headless). One headless-checkable assertion per
## Wave-5 hud-menu fix: it CONSTRUCTS the on-screen nodes (OpsHUD / menu are never built in the normal
## suites) and asserts their node/state contract — the level the note allows headless (sizes, colors,
## child structure, which panels build, stylebox states), NOT pixels (the lead's windowed tour eyeballs
## those). Imports ONLY OpsHUD / palette / EventPlayer / menu — none pull run_screens/run_controller, so
## this suite stays byte-stable + SCRIPT-ERROR-clean regardless of the other lanes' in-flight edits.
##
## Covers: W5-12 STABILIZE palette button · W5-6 picker effect/AP/range hint · W5-8 menu initial focus +
## traversal · W5-10 tip banner clears the top-center action zone · W5-11 action row fits its frame ·
## W5-13 status legend within the viewport · W5-17 overwatch eye priority · W5-4 named phase labels.
##
## Run: godot --headless --path . --script res://tests/hud_menu_wave5_smoke.gd

const OpsHUD = preload("res://render/ops_hud.gd")
const Pal = preload("res://render/palette.gd")
const EventPlayer = preload("res://render/event_player.gd")
const Menu = preload("res://app/menu.gd")
const GE = preload("res://core/game_event.gd")
const E = preload("res://core/sim_enums.gd")

const VIEWPORT := Vector2(1280, 720)

var _pass: int = 0
var _fail: int = 0
var _fails: Array = []


func _initialize() -> void:
	print("\n=== COLDSPINE — HUD-MENU WAVE 5 smoke test (presentation polish, headless) ===")
	test_stabilize_palette_button()            # W5-12
	test_stabilize_button_arms_intent()        # W5-12
	test_picker_effect_hint_is_readable()      # W5-6-hud
	test_picker_row_carries_effect_and_ap()    # W5-6-hud
	test_action_row_fits_its_frame()           # W5-11
	test_tip_banner_clears_top_center()        # W5-10
	test_status_legend_within_viewport()       # W5-13
	test_overwatch_eye_survives_full_badges()  # W5-17
	test_phase_labels_are_named()              # W5-4-comms
	test_menu_initial_focus_and_traversal()    # W5-8
	print("\n--- HUD-MENU WAVE 5 SMOKE: %d passed, %d failed ---" % [_pass, _fail])
	for f in _fails:
		print("    FAIL: " + f)
	if _fail == 0:
		print("HUD-MENU WAVE 5 GREEN — stabilize button, picker hints, menu focus, tip/action/legend layout, overwatch eye, named phases.\n")
	quit(0 if _fail == 0 else 1)


func ok(cond: bool, msg: String) -> void:
	if cond:
		_pass += 1
	else:
		_fail += 1
		_fails.append(msg)
		print("    [FAIL] " + msg)


# ---- OpsHUD headless instancing (the render_smoke pattern: add + fire the deferred _ready) ----
func _hud() -> OpsHUD:
	var hud := OpsHUD.new()
	root.add_child(hud)
	hud._ready()
	return hud


func _saboteur_defs() -> Dictionary:
	return JSON.parse_string(FileAccess.get_file_as_string("res://content/abilities/saboteur_abilities.json"))


# ============================ W5-12 STABILIZE palette button ==================
func test_stabilize_palette_button() -> void:
	var hud := _hud()
	var b: Button = hud._stab_button
	ok(b != null, "[W5-12] the palette builds a STABILIZE button")
	ok(b != null and b.get_parent() == hud.action_row, "[W5-12] STAB sits inside the framed action row (not floating)")
	# EMPTY state: hidden + disabled until a stabilize target exists.
	ok(b != null and not b.visible and b.disabled, "[W5-12] STAB starts hidden/disabled (no downed ally)")
	# Interactive states: it carries hover / pressed / disabled styleboxes (house rule — not just default).
	ok(b != null and b.has_theme_stylebox_override("hover") and b.has_theme_stylebox_override("pressed")
		and b.has_theme_stylebox_override("disabled"), "[W5-12] STAB has hover/pressed/disabled stylebox states")
	# A stabilize target exists -> shown + enabled; then gone -> hidden again.
	hud.set_stabilize_available(true)
	ok(b.visible and not b.disabled, "[W5-12] set_stabilize_available(true) shows + enables STAB")
	hud.set_stabilize_available(false)
	ok(not b.visible and b.disabled, "[W5-12] set_stabilize_available(false) hides STAB again")
	# It carries a real onboarding tooltip (the audit flagged there was none).
	ok(hud.ACTION_TOOLTIPS.has("STAB") and String(b.tooltip_text) != "", "[W5-12] STAB carries a help tooltip")
	hud.free()


func test_stabilize_button_arms_intent() -> void:
	var hud := _hud()
	# Pressing STAB emits the SAME action name the keyboard path uses — action_pressed("STAB"), which the
	# controller routes to InputIntent.Mode.STABILIZE (run_controller._on_hud_action, verified in code).
	var got := {"name": ""}
	hud.action_pressed.connect(func(n): got.name = n)
	hud.set_stabilize_available(true)
	hud._stab_button.emit_signal("pressed")
	ok(got.name == "STAB", "[W5-12] pressing STAB arms the stabilize intent (emits action_pressed('STAB'))")
	hud.free()


# ============================ W5-6-hud picker effect/AP/range hint ============
func test_picker_effect_hint_is_readable() -> void:
	var defs := _saboteur_defs()
	var gas: Dictionary = defs.get("gas_tap", {})
	ok(not gas.is_empty(), "[W5-6] loaded the real gas_tap ability def")
	var hint: String = OpsHUD.effect_hint(gas)
	# A new player must read WHAT it does + its cost + its reach — not just the id.
	ok(hint.to_lower().contains("gas") or hint.to_lower().contains("poison"),
		"[W5-6] the Gas Tap hint states the effect (a poison/gas cloud), got: %s" % hint)
	ok(hint.contains("1 AP"), "[W5-6] the hint carries the AP cost, got: %s" % hint)
	ok(hint.contains("range 4") or hint.contains("tile"), "[W5-6] the hint carries the range/targeting, got: %s" % hint)
	# Every active ability produces a non-empty, non-id hint (never blank).
	for aid in defs.keys():
		var h: String = OpsHUD.effect_hint(defs[aid])
		ok(h.length() > 4 and h.contains("AP"), "[W5-6] %s yields a readable effect+AP hint (%s)" % [aid, h])


func test_picker_row_carries_effect_and_ap() -> void:
	var hud := _hud()
	var gas: Dictionary = _saboteur_defs().get("gas_tap", {})
	var entry := {"id": "gas_tap", "label": "Gas Tap  (1 AP)", "enabled": true, "hint": OpsHUD.effect_hint(gas)}
	# Direct row build.
	var row: Button = hud._choice_row(entry)
	var sub = row.find_child("choice_hint", true, false)
	ok(sub != null, "[W5-6] the enriched picker row builds a hint sub-label (not just the id row)")
	ok(sub != null and String((sub as Label).text).to_lower().contains("gas")
		and String((sub as Label).text).contains("AP"),
		"[W5-6] the built row label carries the effect + AP text")
	# Through the real popup entry point.
	hud.open_choice_menu("ability", "ABILITIES", [entry])
	ok(hud._choice_list.get_child_count() == 1, "[W5-6] open_choice_menu built one row")
	var built := hud._choice_list.get_child(0)
	var sub2 = built.find_child("choice_hint", true, false)
	ok(sub2 != null and String((sub2 as Label).text).contains("AP"),
		"[W5-6] the popup row (via open_choice_menu) carries the effect+AP hint")
	# Backward-compat: an entry with NO hint still renders a plain single-line row (no crash).
	var plain: Button = hud._choice_row({"id": "x", "label": "Plain", "enabled": true})
	ok(String(plain.text) == "Plain", "[W5-6] a hint-less entry still renders its plain label")
	hud.free()


# ============================ W5-11 action row fits its frame =================
func test_action_row_fits_its_frame() -> void:
	var hud := _hud()
	ok(hud.action_row is GridContainer, "[W5-11] the action row is a wrapping GridContainer")
	var cols: int = hud.action_row.columns
	ok(cols >= 2, "[W5-11] the grid wraps to multiple columns (cols=%d)" % cols)
	# Worst case: STAB visible -> 12 buttons. The widest row (the `cols` widest buttons + separations)
	# must fit inside the framed SELECTED-UNIT panel — no unframed float over the feed.
	hud.set_stabilize_available(true)
	var hsep: int = hud.action_row.get_theme_constant("h_separation")
	var widths: Array = []
	for c in hud.action_row.get_children():
		if c is Button and c.visible:
			widths.append((c as Button).custom_minimum_size.x)
	widths.sort()
	widths.reverse()
	var n: int = min(cols, widths.size())
	var row_w: float = 0.0
	for i in range(n):
		row_w += float(widths[i])
	row_w += float(max(0, n - 1) * hsep)
	var right_edge: float = hud.action_row.position.x + row_w
	ok(right_edge <= hud.ap_panel.size.x,
		"[W5-11] the widest button row (%.0fpx from x=%.0f) fits inside the %0.fpx panel" % [row_w, hud.action_row.position.x, hud.ap_panel.size.x])
	# And the panel itself is on-screen at 1280x720.
	ok(hud.ap_panel.position.x + hud.ap_panel.size.x <= VIEWPORT.x
		and hud.ap_panel.position.y + hud.ap_panel.size.y <= VIEWPORT.y,
		"[W5-11] the SELECTED-UNIT frame stays within the 1280x720 viewport")
	hud.free()


# ============================ W5-10 tip banner placement =====================
func test_tip_banner_clears_top_center() -> void:
	var hud := _hud()
	hud.show_tip("DISPLACE", "shove an enemy into a hazard for free damage")
	var tip := Rect2(hud._tip_panel.position, hud._tip_panel.size)
	# The action-row rect (the SELECTED-UNIT palette the item names) — the tip must not cover it.
	var arow := Rect2(hud.ap_panel.position + hud.action_row.position, Vector2(hud.ap_panel.size.x, 60))
	ok(not tip.intersects(arow), "[W5-10] the tip banner does not intersect the action-row rect")
	# The top-center action/telegraph zone — the finale COUNTDOWN clock is the canonical element there, and
	# the board now climbs UP so that band is live combat. The tip must clear it (the reported overlap).
	var top_center := Rect2(470, 58, 340, 64)
	ok(not tip.intersects(top_center), "[W5-10] the tip banner clears the top-center action/telegraph zone")
	# And it stays on-screen.
	ok(tip.position.x >= 0 and tip.position.y >= 0
		and tip.position.x + tip.size.x <= VIEWPORT.x and tip.position.y + tip.size.y <= VIEWPORT.y,
		"[W5-10] the tip banner stays within the viewport")
	# Regression witness: the OLD y=66 slot DID cover the top-center (so this test would have caught it).
	ok(Rect2(300, 66, 680, 104).intersects(top_center), "[W5-10] (witness) the pre-fix y=66 slot overlapped the top-center")
	hud.free()


# ============================ W5-13 status legend within the viewport ========
func test_status_legend_within_viewport() -> void:
	var hud := _hud()
	ok(hud.legend_box != null, "[W5-13] the status legend builds a bounded text column")
	var right_edge: float = hud.legend_panel.position.x + hud.legend_box.position.x + hud.legend_box.custom_minimum_size.x
	ok(right_edge <= VIEWPORT.x, "[W5-13] the legend text column right edge (%.0fpx) is within the 1280px viewport" % right_edge)
	# Every legend row word-wraps (so no glyph is ever clipped at the panel edge).
	var rows := 0
	for c in hud.legend_box.get_children():
		if c is Label:
			rows += 1
			ok((c as Label).autowrap_mode != TextServer.AUTOWRAP_OFF, "[W5-13] legend row '%s' word-wraps" % String((c as Label).text).substr(0, 12))
	ok(rows >= 3, "[W5-13] the legend still carries all its rows (%d)" % rows)
	# The legend panel stays on-screen at 1280x720.
	ok(hud.legend_panel.position.x + hud.legend_panel.size.x <= VIEWPORT.x
		and hud.legend_panel.position.y + hud.legend_panel.size.y <= VIEWPORT.y,
		"[W5-13] the legend frame stays within the viewport")
	hud.free()


# ============================ W5-17 overwatch eye priority ====================
func test_overwatch_eye_survives_full_badges() -> void:
	# An overwatcher buffed/afflicted with MAX_BADGES real statuses STILL shows the eye (its own slot).
	var full: int = E.S_PRONE | E.S_STUNNED | E.S_BURNING | Pal.R_OVERWATCH
	var plan: Dictionary = Pal.status_badge_plan(full)
	ok(bool(plan.get("eye", false)), "[W5-17] an overwatcher with 3 statuses STILL shows the overwatch eye")
	ok((plan.get("badges", []) as Array).size() == Pal.MAX_BADGES, "[W5-17] the real-status fan still caps at MAX_BADGES")
	# The eye is never one of the capped fan badges (drawn separately).
	for pair in (plan.get("badges", []) as Array):
		ok(int(pair[0]) != Pal.R_OVERWATCH, "[W5-17] the eye is never counted in the capped badge fan")
	# No overwatch -> no eye; overwatch alone -> eye + empty fan.
	var p2: Dictionary = Pal.status_badge_plan(E.S_PRONE | E.S_STUNNED)
	ok(not bool(p2.get("eye", false)) and (p2.get("badges", []) as Array).size() == 2, "[W5-17] non-overwatchers show no eye")
	var p3: Dictionary = Pal.status_badge_plan(Pal.R_OVERWATCH)
	ok(bool(p3.get("eye", false)) and (p3.get("badges", []) as Array).is_empty(), "[W5-17] a bare overwatcher shows only the eye")


# ============================ W5-4-comms named phase labels ===================
func test_phase_labels_are_named() -> void:
	ok(EventPlayer.phase_name(E.Phase.PLAYER) == "PLAYER PHASE", "[W5-4] phase 0 -> PLAYER PHASE")
	ok(EventPlayer.phase_name(E.Phase.ENEMY) == "ENEMY PHASE", "[W5-4] phase 1 -> ENEMY PHASE")
	ok(EventPlayer.phase_name(E.Phase.ENVIRONMENT) == "ENVIRONMENT PHASE", "[W5-4] phase 2 -> ENVIRONMENT PHASE")
	# The built TURN_PHASE comms line reads the human name, never the raw internal "PHASE 1".
	var ep := EventPlayer.new(null, true)
	var lines: Array = []
	ep.comms.connect(func(l): lines.append(l))
	ep.play([GE.new(E.Ev.TURN_PHASE, {"phase": E.Phase.ENEMY, "round": 2})])
	var named := false
	var raw := false
	for l in lines:
		if String(l).contains("ENEMY PHASE"):
			named = true
		if String(l).contains("PHASE 1"):
			raw = true
	ok(named, "[W5-4] the TURN_PHASE comms line renders the named phase")
	ok(not raw, "[W5-4] the comms line no longer shows the raw internal 'PHASE 1'")


# ============================ W5-8 menu initial focus + traversal =============
func test_menu_initial_focus_and_traversal() -> void:
	var m := Menu.new()
	root.add_child(m)
	m._ready()   # headless -> _show_home -> _focus_panel_column (grab_focus is display-gated; wiring is not)
	ok(m._first_focus != null, "[W5-8] an initial focus target is chosen on menu build (was zero grab_focus)")
	ok(m._first_focus is Button, "[W5-8] the initial focus target is a button in the column")
	ok(m._first_focus != null and m._first_focus.focus_neighbor_bottom != NodePath(""),
		"[W5-8] Down-traversal is wired (focus_neighbor_bottom set)")
	ok(m._first_focus != null and m._first_focus.focus_neighbor_top != NodePath(""),
		"[W5-8] Up-traversal is wired (focus_neighbor_top set)")
	# A sub-panel swap re-establishes focus + wiring (no dead keyboard state after navigating).
	m._show_settings()
	ok(m._first_focus != null and m._first_focus is Button
		and m._first_focus.focus_neighbor_bottom != NodePath(""),
		"[W5-8] the SETTINGS panel also focuses its first control + wires traversal")
	m.free()
