class_name OpsHUD
extends CanvasLayer
## The surveillance / ops console (ART_BIBLE §2, §5; GDD §16). Built in code so it is
## hand-authorable and diffable. Regions (ui_hud.md): camera-ID header, comms log,
## AP pips + order strip, Order meter, status legend, recon strip, and a screen-space
## CRT/scanline + vignette overlay (toggleable, mobile-cheap). Chrome is the constant
## frame; only the feed (the CarView under it) re-skins per section.

const Pal = preload("res://render/palette.gd")
const E = preload("res://core/sim_enums.gd")

## Hover/long-press help text (combat-ux #7) for every palette + control button, from the design
## vocabulary (GDD §5 / §6.7). Godot shows these on desktop hover automatically; on touch they back a
## long-press. Keyed by the LOGICAL action name. Pure strings — no sim effect, never headless-critical.
const ACTION_TOOLTIPS := {
	"MOVE":    "Move up to a few tiles. 1 AP. Preview the path, tap again to commit.",
	"SHOOT":   "Ranged attack — ENDS this unit's turn. Cover lowers the hit chance.",
	"SHOVE":   "Push an adjacent target 1-2 tiles — into a gap, hazard, wall, or another body for free damage. 1 AP.",
	"SLAM":    "A heavier shove: more force, knocks the target further and harder. 1 AP.",
	"THROW":   "Hurl an adjacent object or body across the car along your facing. 1 AP.",
	"ABILITY": "Use one of this unit's active abilities — charges, floods, hacks, heavy slams. Costs AP.",
	"ITEM":    "Use a carried consumable or gadget (medkit, grenade, gadget). One-use.",
	"OVR":     "Overwatch — hold fire and shoot the first enemy that moves into view this enemy phase.",
	"STAB":    "Stabilize a downed ally — stop its bleed-out so you can save it. Stand adjacent, then tap the body. 1 AP.",
	"UNDO":    "Undo the last move (movement only). Refunds the spent AP.",
	"CANCEL":  "Cancel the armed action and clear the preview.",
	"END":     "End this unit's turn and move to the next.",
}
const CONTROL_TOOLTIPS := {
	"AUTO":  "Hand the fight to the auto-pilot, or take manual control back.",
	"SPEED": "Cycle animation speed: 1x / 2x / 4x.",
}

## Emitted when the operator clicks an action button (MOVE/SHOOT/SHOVE/SLAM/THROW/OVERWATCH/END)
## or a control button (AUTO/SPEED). The RunController wires these to InputIntent / sim_mode.
signal action_pressed(name: String)
signal control_pressed(name: String)

## STATUS-LEGEND text column width (W5-13): the legend panel is 280px; its rows wrap inside this bound
## (10px inset each side) so no glyph is ever cut at the 1280px viewport edge.
const LEGEND_TEXT_W := 258

## Emitted when the operator picks a specific ability / consumable from the ABILITY / ITEM popup
## (Batch 6 depth toolkit). `id` is the AbilityDef id or the item/gear id. The RunController arms it
## on the bound InputIntent (arm_ability / arm_item). On-screen-only (headless never instances OpsHUD).
signal ability_chosen(id: String)
signal item_chosen(id: String)

## Emitted when the operator dismisses a combat-onboarding tip banner (combat-ux #7 — the [ GOT IT ]
## button or ESC). The RunController clears the banner + re-focuses combat. On-screen-only.
signal tip_dismissed()

## Emitted when the operator taps a recon affordance (#11). `kind` is "car" (a FULL recon row — opens
## the RECON CARD detail overlay) or "deep_scan" (the [ DEEP SCAN ] affordance — the controller spends
## Tools via RunState.deep_scan). `index` is the line index for a car row, or -1 for deep_scan. The
## RunController wires this exactly like action_pressed; on-screen-only (headless never instances OpsHUD).
signal recon_pressed(kind: String, index: int)

var camera_label: Label
var rec_label: Label             # the "● REC" tally — repositioned in finale so the long header can't overlap it (W4-9)
var timecode_label: Label
var order_label: Label
var order_bar: ColorRect
var comms_box: RichTextLabel
var ap_row: HBoxContainer
var ap_panel: Panel              # SELECTED UNIT frame (W5-11 — sized to hold the wrapped action grid)
var action_row: GridContainer    # W5-11 — the action palette wraps to 2 rows so it never overflows
var control_row: HBoxContainer   # AUTO / SPEED / END toggles (interactive on-screen)
var _stab_button: Button = null  # W5-12 — STABILIZE palette button (hidden unless a downed ally exists)
var recon_box: VBoxContainer
var legend_panel: Panel              # STATUS LEGEND frame (W5-13 — grown to hold the wrapped rows)
var legend_box: VBoxContainer        # W5-13 — the legend rows, WORD-wrapped inside LEGEND_TEXT_W
var scanlines: ColorRect
var currency_label: Label        # Scrip / Supplies / Tools readout (§10)
var deepscan_button: Button      # the Deep Scan affordance (spends Tools, §8.2) — tappable (#11)
var hint_label: Label            # interactive prompt ("SELECT A UNIT" / "PICK A TARGET TILE")
var roster_strip: HBoxContainer  # #18 — a chip per living squad unit (can-act / spent / downed)
var phase_banner: Label          # #18 — the read-only ENEMY/ENVIRONMENT phase + ROUND n banner

# --- RECON CARD detail overlay (#11). A centered panel raised when a FULL recon row is tapped — shows
# the car's type / section / modifiers / threat-enemies / reward, with a DISMISS affordance (no dead end).
# Built lazily; on-screen-only (headless never instances OpsHUD). ---
var _recon_card_panel: Panel
var _recon_card_title: Label
var _recon_card_body: RichTextLabel
var _recon_card_dismiss: Button
var _action_buttons: Dictionary = {}   # action name -> Button (for enable/disable per AP)
var _auto_button: Button = null
var _vet_button: Button = null         # W6-11 — betrayer VET/SCAN palette button (emits action "VET")
var _scope_button: Button = null       # W6-2 — AUTO SCOPE indicator + whole-run toggle (emits "SCOPE")
var _auto_scope: String = "run"        # W6-2 — mirror of the controller's AUTO scope for the indicator

# --- ABILITY / ITEM choice popup (Batch 6). A compact centered list the ABILITY / ITEM palette
# buttons raise so the operator picks WHICH ability/consumable to arm. Built lazily; on-screen-only.
var _choice_panel: Panel = null
var _choice_title: Label = null
var _choice_list: VBoxContainer = null
var _choice_kind: String = ""          # "ability" | "item" — which signal a row emits
var _speed_button: Button = null       # #24 — the SPEED button (reads "SPEED 2x" via set_speed_label)

# --- COMBAT ONBOARDING TIP BANNER (combat-ux #7). A top-center, dismissible teaching card raised by
# show_tip() the first time a verb/situation is relevant. Non-blocking (it covers only its own rect;
# combat continues underneath), skippable ([ GOT IT ] / ESC), and globally suppressible (tips_enabled).
# Built lazily; on-screen-only (headless never instances OpsHUD, so no tip ever renders in a suite).
var _tip_panel: Panel = null
var _tip_title: Label = null
var _tip_body: Label = null
var _tip_dismiss: Button = null

var _comms_lines: Array = []
var _max_comms: int = 12
var _recon_by_index: Dictionary = {}   # #11 — line index -> the extended summary dict (for the RECON CARD)
var _t: float = 0.0
var _running: bool = true   # while true the "● REC" timecode advances; frozen at run end
var scanlines_on: bool = true

# Order-meter placeholder value 0..100 (Phase 3 wires the real meter, §9).
var order_value: int = 0

# ============================ FINALE BOSS HUD (Batch 3) =======================
# Batch-3 boss-HUD chrome (the Engine Vault). All of this is INERT until enter_finale_mode()
# raises it on-screen — the recon rail swaps for an OBJECTIVE/relay/core panel, the COUNTDOWN
# CLOCK detonates over the top bar, a telegraph banner sits above comms, a LOCKDOWN bezel frames
# the feed. Headless never instances OpsHUD, so none of this touches the byte-stable test path.
# ART_BIBLE: the finale is the one place ALERT_RED goes from a reserved accent to a PERVASIVE
# structural color (countdown, alarm bezel, lockdown wash). Preview ghosts stay cyan (§6.7) —
# that gate lives in the renderer/InputIntent, not here.
# Top-bar REC/timecode placement (W4-9). Default sits just right of the camera-ID header; in the
# finale the header grows long ("ENGINE — CONDUCTOR'S CHAMBER · PHASE n/3") and collided with these,
# so enter_finale_mode slides the REC/timecode cluster into the empty gap before the Order meter.
const REC_POS_DEFAULT := Vector2(360, 13)
const TC_POS_DEFAULT  := Vector2(440, 13)
const REC_POS_FINALE  := Vector2(868, 13)   # clear of the long finale header AND the currency readout
const TC_POS_FINALE   := Vector2(948, 13)   # ends before the Order meter (x≈1060)

const ENGINE_SURFACE := Color("2C3640")   # ART_BIBLE §4 Section 5 engine.surface
const ENGINE_ACCENT  := Color("3FC6D4")   # engine.accent (== CYAN family)
const ENGINE_LIGHT   := Color("E6F2F5")   # engine.light
const ENGINE_GLOW    := Color("FF3B3B")   # engine.glow (alarm red)
const BRIDGE_FULL    := 10                 # BRIDGE_COUNTDOWN_DEFAULT — full draining-bar reference

var _finale_mode: bool = false            # TRUE once enter_finale_mode raised the boss chrome
var _countdown_panel: Panel               # the prime center-top COUNTDOWN CLOCK panel
var _countdown_label: Label               # "BRIDGE :: T-07" / "BRIDGE :: BREACHED"
var _countdown_sub: Label                 # "◣ POINT OF NO RETURN" sub-label (expired only)
var _countdown_bar_bg: ColorRect          # the draining-bar background
var _countdown_bar: ColorRect             # the draining T-minus bar
var _countdown_n: int = BRIDGE_FULL       # last countdown value pushed (drives the urgency blink)
var _countdown_expired: bool = false      # latched once the bridge breaches (steady alarm, no blink)
var _blink_t: float = 0.0                 # urgency-blink accumulator (T-3..T-1)
var _telegraph_panel: Panel               # the AMBER-on-dark telegraph strip above comms
var _telegraph_label: Label               # "⚠ CONDUCTOR → OVERCHARGE — next turn"
var _objective_box: VBoxContainer         # the OBJECTIVE / relay / core panel (in the recon slot)
var _objective_header: Label              # "OBJECTIVE — STOP THE TRAIN" / "CORE SHIELD :: UP"
var _lockdown_bezel: Control              # the ALERT_RED inset frame (Phase-3 only)
var _escalation_label: Label              # the transient "ESC +N :: TRAPS FASTER" ticker
var _esc_flash_t: float = 0.0             # escalation-ticker flash timer (fades after a beat)
var _objective_box_panel: Panel           # the OBJECTIVE panel container (for show/hide consistency)


func _ready() -> void:
	layer = 5
	_build()
	set_camera_id("CAR 07", "COOLANT BAY")
	set_process(true)

func _process(delta: float) -> void:
	if _finale_mode:
		_tick_finale_chrome(delta)
	if not _running:
		return   # run over — freeze the timecode (see set_running)
	_t += delta
	if timecode_label != null:
		var secs := int(_t)
		timecode_label.text = "%02d:%02d:%02d" % [secs / 3600, (secs / 60) % 60, secs % 60]


## Per-frame boss-chrome animation: the countdown-clock urgency blink (T-3..T-1), the LOCKDOWN
## bezel slow-pulse, and the escalation-ticker fade. On-screen-only — never runs headless (no
## OpsHUD there) and only while the finale chrome is raised. Cheap (a couple of alpha lerps).
func _tick_finale_chrome(delta: float) -> void:
	# Countdown urgency blink: pulse the clock label between full ALERT_RED and dim once it is
	# urgent (T-3..T-1) and still running. The expired BREACHED state is steady (no blink).
	if _countdown_label != null:
		if not _countdown_expired and _running and _countdown_n <= 3 and _countdown_n > 0:
			_blink_t += delta
			var on: bool = fmod(_blink_t, 0.7) < 0.35
			_countdown_label.modulate.a = 1.0 if on else 0.4
		else:
			_countdown_label.modulate.a = 1.0
	# LOCKDOWN bezel slow-pulse (Phase 3 only — _lockdown_bezel.visible set by set_lockdown).
	if _lockdown_bezel != null and _lockdown_bezel.visible:
		_blink_t += delta
		var pulse: float = 0.55 + 0.25 * sin(_blink_t * 3.0)
		_lockdown_bezel.modulate.a = clamp(pulse, 0.0, 1.0)
	# Escalation ticker: flash for ~1.5s after a push, then settle to a small persistent badge.
	if _escalation_label != null and _esc_flash_t > 0.0:
		_esc_flash_t = max(0.0, _esc_flash_t - delta)
		_escalation_label.modulate.a = 1.0 if fmod(_esc_flash_t, 0.4) < 0.2 else 0.55


## Freeze/resume the "● REC" recording timecode. Called false at run end so the clock stops
## advancing on the sticky ending screen (the runaway-timer bug). On-screen-only — the headless
## suites never instance OpsHUD, so this never runs in tests.
func set_running(running: bool) -> void:
	_running = running
	if not running:
		if timecode_label != null:
			timecode_label.text = "FEED ENDED"
		# W4-10: the run is over — freeze the bridge countdown and HIDE the finale boss chrome + any
		# combat tip banner so nothing keeps ticking or drawing behind the ENDING / PAYOUT card. The
		# countdown value is pushed by the controller (never self-advanced here), and _running=false
		# also gates the urgency-blink in _tick_finale_chrome, so hiding the panels freezes it cleanly.
		_freeze_finale_chrome()


## Hide + freeze every finale overlay at run end (W4-10). Null-guarded so a non-finale ending (LOSS
## mid-line, where the boss chrome was never built) is a harmless no-op. On-screen-only.
func _freeze_finale_chrome() -> void:
	if _countdown_panel != null:
		_countdown_panel.visible = false
	if _objective_box_panel != null:
		_objective_box_panel.visible = false
	if _telegraph_panel != null:
		_telegraph_panel.visible = false
	if _lockdown_bezel != null:
		_lockdown_bezel.visible = false
	if _tip_panel != null:
		_tip_panel.visible = false

# ============================ BUILD ============================================
func _build() -> void:
	var root := Control.new()
	root.set_anchors_preset(Control.PRESET_FULL_RECT)
	root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(root)

	# --- Top bar: camera-ID header + Order meter ---
	var top := _panel(Vector2(8, 8), Vector2(1264, 44))
	root.add_child(top)
	camera_label = _label("CAR 07 — COOLANT BAY", Pal.AMBER, 20)
	camera_label.position = Vector2(16, 10)
	top.add_child(camera_label)
	rec_label = _label("● REC", Pal.ALERT_RED, 16)
	rec_label.position = REC_POS_DEFAULT
	top.add_child(rec_label)
	timecode_label = _label("00:00:00", Pal.CYAN, 16)
	timecode_label.position = TC_POS_DEFAULT
	top.add_child(timecode_label)
	# Order meter (top-right), §9 placeholder
	order_label = _label("ORDER", Pal.CYAN, 14)
	order_label.position = Vector2(1060, 5)
	top.add_child(order_label)
	var order_bg := ColorRect.new()
	order_bg.color = Pal.FRAME_BG
	order_bg.position = Vector2(1060, 24)
	order_bg.size = Vector2(180, 12)
	top.add_child(order_bg)
	order_bar = ColorRect.new()
	order_bar.color = Pal.CYAN
	order_bar.position = Vector2(1060, 24)
	order_bar.size = Vector2(0, 12)
	top.add_child(order_bar)
	# Currency readout (§10): Scrip / Supplies / Tools, center-right of the top bar.
	currency_label = _label("SCR 0   SUP 0   TLS 0", Pal.AMBER, 14)
	currency_label.position = Vector2(560, 13)
	top.add_child(currency_label)

	# --- Comms log (bottom-left) ---
	var comms_panel := _panel(Vector2(8, 520), Vector2(520, 192))
	root.add_child(comms_panel)
	var ch := _label("COMMS", Pal.DIM, 13)
	ch.position = Vector2(10, 4)
	comms_panel.add_child(ch)
	comms_box = RichTextLabel.new()
	comms_box.bbcode_enabled = false
	comms_box.scroll_following = true
	comms_box.position = Vector2(10, 24)
	comms_box.size = Vector2(500, 160)
	comms_box.add_theme_color_override("default_color", Pal.AMBER)
	comms_box.add_theme_font_size_override("normal_font_size", 13)
	comms_panel.add_child(comms_box)

	# --- AP / order strip (bottom-center) ---
	# W5-11: the 11-(now 12-)button palette overflowed the old 440x112 frame — buttons floated unframed
	# over the feed. The frame is grown taller and the action palette WRAPS into a 6-col GridContainer
	# (2 rows) so every button sits inside the panel at 1280x720. The team strip slides up to make room.
	ap_panel = _panel(Vector2(540, 566), Vector2(440, 146))
	root.add_child(ap_panel)
	var ah := _label("SELECTED UNIT", Pal.DIM, 13)
	ah.position = Vector2(10, 6)
	ap_panel.add_child(ah)
	ap_row = HBoxContainer.new()
	ap_row.position = Vector2(10, 28)
	ap_row.add_theme_constant_override("separation", 8)
	ap_panel.add_child(ap_row)
	# Interactive prompt line (what the operator should do next).
	hint_label = _label("AUTO — operator standing by", Pal.DIM, 12)
	hint_label.position = Vector2(120, 8)
	ap_panel.add_child(hint_label)
	# Action buttons — REAL clickable Buttons that emit action_pressed(name). MOVE/SHOOT/SHOVE/
	# SLAM/THROW/OVERWATCH/END drive the bound InputIntent; disabled until a unit is selected. Laid out
	# in a 6-column grid so the row wraps instead of overflowing the frame (W5-11).
	action_row = GridContainer.new()
	action_row.columns = 6
	action_row.position = Vector2(10, 60)
	action_row.add_theme_constant_override("h_separation", 6)
	action_row.add_theme_constant_override("v_separation", 4)
	ap_panel.add_child(action_row)
	for a in ["MOVE", "SHOOT", "SHOVE", "SLAM", "THROW", "ABILITY", "ITEM", "OVR", "UNDO", "CANCEL", "END"]:
		var b := _action_button(a)
		_action_buttons[a] = b
		action_row.add_child(b)
	# W5-12: the STABILIZE verb (revive a downed ally) was keyboard-only (KEY_S) with no touch recourse.
	# Give it a real palette button that emits action_pressed("STAB") — the SAME command the key path arms
	# (RunController._on_hud_action routes "STAB" -> InputIntent.Mode.STABILIZE). It stays HIDDEN until a
	# stabilize target exists (set_stabilize_available), so it never clutters the palette in normal play.
	_stab_button = _action_button("STAB")
	_stab_button.add_theme_stylebox_override("hover", _action_stylebox(true))
	_stab_button.add_theme_stylebox_override("pressed", _action_stylebox(true))
	_stab_button.add_theme_stylebox_override("disabled", _action_stylebox(false))
	_stab_button.add_theme_color_override("font_color", Pal.CYAN)
	_stab_button.add_theme_color_override("font_color_disabled", Pal.DIM)
	_stab_button.visible = false
	_stab_button.disabled = true
	action_row.add_child(_stab_button)
	# Control row — AUTO toggle (flips sim_mode) + SPEED (fast-forward) + SCAN toggle.
	control_row = HBoxContainer.new()
	control_row.position = Vector2(10, 120)
	control_row.add_theme_constant_override("separation", 6)
	ap_panel.add_child(control_row)
	_auto_button = _control_button("AUTO")
	control_row.add_child(_auto_button)
	_speed_button = _control_button("SPEED")
	control_row.add_child(_speed_button)
	# W6-2: AUTO SCOPE indicator + whole-run toggle. The button's LABEL is the indicator (THIS FIGHT vs
	# WHOLE RUN); pressing it emits control_pressed("SCOPE"), which the controller routes to its existing
	# _set_auto_whole_run / scope-flip path — so an AUTO operator can SEE and change the scope instead of
	# a hidden keyboard-only toggle. set_auto_scope() keeps the label in sync with the controller.
	_scope_button = _control_button("SCOPE")
	_scope_button.custom_minimum_size = Vector2(158, 26)
	control_row.add_child(_scope_button)
	set_auto_scope(_auto_scope)
	# W6-11: the betrayer VET / SCAN palette button. It emits action_pressed("VET") — the action name the
	# controller ALREADY routes to scan_for_betrayer() (run_controller._on_hud_action) — so the one-per-run
	# counterplay is finally reachable by touch, not just the keyboard "VET". set_vet_available reflects the
	# one-per-run availability; it defaults to available so the button works even before the controller wires it.
	_vet_button = _action_button("VET")
	_vet_button.custom_minimum_size = Vector2(64, 26)
	_vet_button.tooltip_text = "SCAN the squad for a Conductor's Kin plant — one per run. Exposes + defuses a betrayer if one is aboard."
	control_row.add_child(_vet_button)
	set_actions_enabled(false)
	set_ap(0, 2)

	# --- TEAM-TURN ROSTER STRIP + phase banner (#18) — a slim panel above the AP strip: a chip per
	# living squad unit (can-act AMBER / spent DIM / downed red) + the read-only phase + ROUND n banner.
	var team_panel := _panel(Vector2(540, 506), Vector2(440, 54))
	root.add_child(team_panel)
	var th := _label("TEAM TURN", Pal.DIM, 12)
	th.position = Vector2(10, 2)
	team_panel.add_child(th)
	phase_banner = _label("ROUND 1 — PLAYER PHASE", Pal.AMBER, 13)
	phase_banner.position = Vector2(110, 2)
	team_panel.add_child(phase_banner)
	roster_strip = HBoxContainer.new()
	roster_strip.position = Vector2(10, 24)
	roster_strip.add_theme_constant_override("separation", 6)
	team_panel.add_child(roster_strip)

	# --- Recon strip (right rail) ---
	var recon_panel := _panel(Vector2(992, 60), Vector2(280, 430))
	root.add_child(recon_panel)
	var rh := _label("RECON — NEXT", Pal.CYAN, 14)
	rh.position = Vector2(10, 4)
	recon_panel.add_child(rh)
	recon_box = VBoxContainer.new()
	recon_box.position = Vector2(10, 28)
	recon_box.size = Vector2(260, 360)
	recon_panel.add_child(recon_box)
	recon_box.add_child(_label("(awaiting run feed)", Pal.DIM, 12))
	deepscan_button = _recon_scan_button(false, false, 0)
	recon_box.add_child(deepscan_button)
	# RECON CARD detail overlay (#11) — built lazily on first open.
	_build_recon_card(root)

	# --- Status legend (right rail, lower) ---
	# W5-13: the hazard-legend line ran off the right edge of the 1280px viewport (it drew unbounded at
	# font 10 from x=1002). The lines now live in a VBox bounded to the panel interior (LEGEND_TEXT_W) and
	# WORD-WRAP, so no glyph is ever clipped; the frame is grown to hold the wrapped rows.
	legend_panel = _panel(Vector2(992, 500), Vector2(280, 132))
	root.add_child(legend_panel)
	var lh := _label("STATUS LEGEND", Pal.DIM, 12)
	lh.position = Vector2(10, 2)
	legend_panel.add_child(lh)
	legend_box = VBoxContainer.new()
	legend_box.position = Vector2(10, 20)
	legend_box.custom_minimum_size = Vector2(LEGEND_TEXT_W, 0)
	legend_box.size = Vector2(LEGEND_TEXT_W, 0)
	legend_box.add_theme_constant_override("separation", 3)
	legend_panel.add_child(legend_box)
	var leg := _wrap_label("~soaked  p prone  z stun  * shock  f burn", Pal.CYAN, 11)
	_with_tooltip(leg, "Status tells on a body: ~ soaked (conducts shock), p prone, z stunned, * shocked, f burning.")
	legend_box.add_child(leg)
	var leg2 := _wrap_label("@ player   g enemy   o object", Pal.AMBER, 11)
	_with_tooltip(leg2, "Board glyphs: @ your squad, g an enemy, o a movable object (shove or slam it into a body).")
	legend_box.add_child(leg2)
	# Hazard-layer + downed legibility tells (combat-ux #0/#2) — the on-feed shapes now drawn per tile.
	var leg3 := _wrap_label("gas·green  steam·pale  snow·flecks  TRAP·amber-X  down·red-body", Pal.DIM, 10)
	_with_tooltip(leg3, "Tile hazards: green gas (poison), pale steam (blinds), snow flecks (slows), an amber X is a TRAP firing next turn — don't stand on it. A red body is a downed ally.")
	legend_box.add_child(leg3)

	# --- CRT scanline + vignette overlay (screen-space post pass) ---
	scanlines = ColorRect.new()
	scanlines.set_anchors_preset(Control.PRESET_FULL_RECT)
	scanlines.mouse_filter = Control.MOUSE_FILTER_IGNORE
	scanlines.material = _scanline_material()
	root.add_child(scanlines)

func _scanline_material() -> ShaderMaterial:
	var sh := Shader.new()
	# Cheap, mobile-sane: dark horizontal line every 3px + soft corner vignette.
	# Screen-space (UV over the rect), never baked into sprites (ART_BIBLE §2).
	sh.code = """
shader_type canvas_item;
uniform float strength : hint_range(0.0, 1.0) = 0.45;
uniform vec2 screen_px = vec2(1280.0, 720.0);
void fragment() {
	float line = mod(UV.y * screen_px.y, 3.0) < 1.0 ? (1.0 - strength) : 1.0;
	vec2 d = UV - vec2(0.5);
	float vig = 1.0 - dot(d, d) * 0.5;
	float a = (1.0 - line) + (1.0 - vig) * 0.18;
	COLOR = vec4(0.0, 0.0, 0.0, clamp(a, 0.0, 0.7));
}
"""
	var m := ShaderMaterial.new()
	m.shader = sh
	return m

# ============================ PUBLIC API =======================================
func set_camera_id(car: String, name: String) -> void:
	if camera_label != null:
		camera_label.text = "%s — %s" % [car, name]

func push_comms(line: String) -> void:
	_comms_lines.append(line)
	while _comms_lines.size() > _max_comms:
		_comms_lines.pop_front()
	if comms_box != null:
		comms_box.text = "\n".join(_comms_lines)

func set_ap(current: int, total: int) -> void:
	if ap_row == null:
		return
	for c in ap_row.get_children():
		c.queue_free()
	for i in range(total):
		var pip := ColorRect.new()
		pip.size = Vector2(28, 28)
		pip.custom_minimum_size = Vector2(28, 28)
		pip.color = Pal.AMBER if i < current else Pal.FRAME_BORDER
		ap_row.add_child(pip)

func set_order(value: int) -> void:
	order_value = clampi(value, 0, 100)
	if order_bar != null:
		order_bar.size.x = 180.0 * (float(order_value) / 100.0)
		# calm cyan -> alarm red as it rises (§9)
		order_bar.color = Pal.CYAN.lerp(Pal.ALERT_RED, float(order_value) / 100.0)

func toggle_scanlines() -> void:
	scanlines_on = not scanlines_on
	if scanlines != null:
		scanlines.visible = scanlines_on

## §10 currency readout — Scrip / Supplies / Tools. `currency` is the RunState.currency dict.
func set_currency(currency: Dictionary) -> void:
	if currency_label == null:
		return
	currency_label.text = "SCR %d   SUP %d   TLS %d" % [
		int(currency.get("scrip", 0)), int(currency.get("supplies", 0)), int(currency.get("tools", 0))]

## §8.2 recon strip — rebuild the right-rail feed from the live run. `summaries` is an
## Array of { index,name,type,section,recon,threat,resolved,current } the RunController builds.
## FULL cars show name+type+threat; the single PARTIAL car shows a threat silhouette; HIDDEN
## cars are dark. The Deep Scan affordance shows whether Tools can buy one more FULL reveal.
func set_recon(run, summaries: Array) -> void:
	if recon_box == null:
		return
	for c in recon_box.get_children():
		c.queue_free()
	_recon_by_index.clear()
	var shown: int = 0
	for s in summaries:
		var idx: int = int(s.get("index", -1))
		_recon_by_index[idx] = s
		if idx < int(run.position):
			continue                       # don't list cars already behind us
		var rec: int = int(s.get("recon", E.Recon.HIDDEN))
		if rec == E.Recon.HIDDEN:
			continue                       # dark — not on the camera feed
		if shown >= 5:
			break
		shown += 1
		var here: bool = bool(s.get("current", false))
		if rec == E.Recon.FULL:
			# A FULL row is TAPPABLE (#11) — opens the RECON CARD detail overlay for this car.
			recon_box.add_child(_recon_row(idx, s, here))
		else:
			# PARTIAL silhouette — not tappable (nothing deeper to show yet); a plain dim label.
			recon_box.add_child(_label("  CAR %d — [%s]" % [idx + 1, s.get("threat", "silhouette")], Pal.DIM, 12))
	if shown == 0:
		recon_box.add_child(_label("(line clear)", Pal.DIM, 12))
	# DEEP SCAN affordance — a genuine tappable Button with a real DISABLED state (#11): greyed + a
	# reason when Tools are short OR there is nothing further on the line to reveal.
	var tools: int = int(run.currency.get("tools", 0))
	var nothing_deeper: bool = int(run.position) + int(run.recon_depth) + 1 >= run.line.size()
	var can_scan: bool = tools >= E.DEEP_SCAN_TOOL_COST and not nothing_deeper
	deepscan_button = _recon_scan_button(can_scan, nothing_deeper, tools)
	recon_box.add_child(deepscan_button)


## A tappable FULL recon row (#11) — CAR n — name / type · sec — that emits recon_pressed("car", idx)
## to open the RECON CARD. The current car reads AMBER with a » marker; others read CYAN. Styled as a
## flat ops row so the tap target is obvious without breaking the §2 chrome.
func _recon_row(idx: int, s: Dictionary, here: bool) -> Button:
	var b := Button.new()
	b.focus_mode = Control.FOCUS_NONE
	b.custom_minimum_size = Vector2(252, 40)
	b.clip_text = false
	b.add_theme_stylebox_override("normal", _action_stylebox(false))
	b.add_theme_stylebox_override("hover", _action_stylebox(here))
	b.add_theme_stylebox_override("pressed", _action_stylebox(true))
	b.pressed.connect(func(): emit_signal("recon_pressed", "car", idx))
	b.pressed.connect(play_ui_cue.bind("select"))   # W6-6 run-layer UI SFX
	var content := Control.new()
	content.position = Vector2(8, 3)
	content.mouse_filter = Control.MOUSE_FILTER_IGNORE
	b.add_child(content)
	var head_col: Color = Pal.AMBER if here else Pal.CYAN
	var prefix := "» " if here else "  "
	var head := _label("%sCAR %d — %s" % [prefix, idx + 1, s.get("name", "?")], head_col, 13)
	head.position = Vector2(0, 0)
	content.add_child(head)
	var sub := _label("    %s   sec %d   ›" % [s.get("type", "?"), int(s.get("section", 0))], Pal.DIM, 11)
	sub.position = Vector2(0, 18)
	content.add_child(sub)
	return b


## The DEEP SCAN Button (#11): tappable + a GENUINE disabled state. Enabled = CYAN, emits
## recon_pressed("deep_scan", -1). Disabled = DIM with the reason inline (no Tools / nothing deeper).
func _recon_scan_button(can_scan: bool, nothing_deeper: bool, tools: int) -> Button:
	var b := Button.new()
	b.focus_mode = Control.FOCUS_NONE
	b.custom_minimum_size = Vector2(252, 28)
	b.clip_text = false
	b.disabled = not can_scan
	b.add_theme_stylebox_override("normal", _action_stylebox(false))
	b.add_theme_stylebox_override("hover", _action_stylebox(can_scan))
	b.add_theme_stylebox_override("pressed", _action_stylebox(true))
	b.add_theme_stylebox_override("disabled", _action_stylebox(false))
	var label := "[ DEEP SCAN ]  -%d tools" % E.DEEP_SCAN_TOOL_COST
	if not can_scan:
		if nothing_deeper:
			label = "[ DEEP SCAN ]  — line fully scanned"
		else:
			label = "[ DEEP SCAN ]  — need %d tools (have %d)" % [E.DEEP_SCAN_TOOL_COST, tools]
	b.text = label
	b.add_theme_font_size_override("font_size", 13)
	b.add_theme_color_override("font_color", Pal.CYAN if can_scan else Pal.DIM)
	b.add_theme_color_override("font_color_disabled", Pal.DIM)
	if can_scan:
		b.pressed.connect(func(): emit_signal("recon_pressed", "deep_scan", -1))
		b.pressed.connect(play_ui_cue.bind("buy"))   # W6-6 run-layer UI SFX (spending Tools)
	return b


# ============================ RECON CARD detail overlay (#11) ==================
## Build the centered RECON CARD detail overlay once (hidden until a FULL row is tapped). A §2-chrome
## panel: a title (CAR n — name), a body (type/section/modifiers/threat-enemies/reward), and a DISMISS
## affordance (no dead end). On-screen-only — headless never instances OpsHUD.
func _build_recon_card(root: Control) -> void:
	_recon_card_panel = _panel(Vector2(360, 180), Vector2(560, 340))
	# Make the card panel block clicks (it is a modal detail), unlike the IGNORE-by-default chrome panels.
	_recon_card_panel.mouse_filter = Control.MOUSE_FILTER_STOP
	_recon_card_panel.visible = false
	root.add_child(_recon_card_panel)
	_recon_card_title = _label("RECON CARD", Pal.AMBER, 20)
	_recon_card_title.position = Vector2(18, 14)
	_recon_card_panel.add_child(_recon_card_title)
	var rule := ColorRect.new()
	rule.color = Pal.FRAME_BORDER
	rule.position = Vector2(18, 46)
	rule.size = Vector2(524, 2)
	_recon_card_panel.add_child(rule)
	_recon_card_body = RichTextLabel.new()
	_recon_card_body.bbcode_enabled = false
	_recon_card_body.position = Vector2(18, 58)
	_recon_card_body.size = Vector2(524, 220)
	_recon_card_body.add_theme_color_override("default_color", Pal.CYAN)
	_recon_card_body.add_theme_font_size_override("normal_font_size", 15)
	_recon_card_panel.add_child(_recon_card_body)
	_recon_card_dismiss = _control_button("[ DISMISS ]")
	_recon_card_dismiss.position = Vector2(18, 292)
	_recon_card_dismiss.pressed.connect(dismiss_recon_card)
	_recon_card_panel.add_child(_recon_card_dismiss)


## Open the RECON CARD for a line index (#11). Reads the stashed extended summary, formats it via the
## PURE recon_card_data() helper, and raises the overlay. No-op if the index has no FULL summary (the
## row would not have been tappable). On-screen-only.
func show_recon_card(index: int) -> void:
	if _recon_card_panel == null or not _recon_by_index.has(index):
		return
	var data: Dictionary = recon_card_data(_recon_by_index[index])
	_recon_card_title.text = String(data.get("title", "RECON CARD"))
	_recon_card_body.text = String(data.get("body", ""))
	_recon_card_panel.visible = true


## Dismiss the RECON CARD overlay (the no-dead-end exit). On-screen-only.
func dismiss_recon_card() -> void:
	if _recon_card_panel != null:
		_recon_card_panel.visible = false


## True while the RECON CARD detail overlay is up (the controller routes ESC to dismiss it).
func recon_card_open() -> bool:
	return _recon_card_panel != null and _recon_card_panel.visible


## PURE recon-card formatter (#11) — turns an extended car summary dict into { title, body } display
## strings. No node touches / no mutation, so the headless polish_smoke can assert the extraction
## directly. `s` is a _car_summaries() entry extended with modifiers/enemies/reward:
##   { index, name, type, section, threat, modifiers:[id], enemies:[tag], reward:{kind,amount} }
static func recon_card_data(s: Dictionary) -> Dictionary:
	var idx: int = int(s.get("index", -1))
	var title := "CAR %d — %s" % [idx + 1, String(s.get("name", "?"))]
	var lines: Array = []
	lines.append("TYPE     %s" % String(s.get("type", "?")))
	lines.append("SECTION  %d" % int(s.get("section", 0)))
	var mods: Array = s.get("modifiers", [])
	if not mods.is_empty():
		var mnames: Array = []
		for m in mods:
			mnames.append(String(m).to_upper())
		lines.append("MODIFIERS  %s" % ", ".join(mnames))
	else:
		lines.append("MODIFIERS  —")
	# Enemies: prefer an explicit enemies list, else fall back to the threat tags.
	var enemies: Array = s.get("enemies", [])
	if enemies.is_empty():
		var threat := String(s.get("threat", ""))
		if threat != "":
			enemies = [threat]
	if not enemies.is_empty():
		var enames: Array = []
		for e in enemies:
			enames.append(String(e))
		lines.append("CONTACTS   %s" % ", ".join(enames))
	else:
		lines.append("CONTACTS   none flagged")
	var reward: Dictionary = s.get("reward", {})
	if not reward.is_empty() and int(reward.get("amount", 0)) != 0:
		lines.append("REWARD     +%d %s" % [int(reward.get("amount", 0)), String(reward.get("kind", "scrip"))])
	else:
		lines.append("REWARD     —")
	lines.append("")
	lines.append("[ DEEP SCAN ] the rail to push the camera one car deeper.")
	return {"title": title, "body": "\n".join(lines)}


# ============================ TEAM-TURN ROSTER STRIP (#18) =====================
## Render the team-turn roster strip + phase banner (#18). `chips` is the controller's PURE per-unit
## draw-data (one entry per LIVING squad member, stable roster order):
##   { name:String, state:"act"|"spent"|"downed" }
## can-act = AMBER, spent = DIM, downed = ALERT_RED. `round_num`/`phase_name` drive the banner. The
## ENEMY/ENVIRONMENT banners read as a read-only "their move" tell (no actions live then). On-screen-only.
func set_team_turn(chips: Array, round_num: int, phase_name: String) -> void:
	if roster_strip == null:
		return
	for c in roster_strip.get_children():
		c.queue_free()
	for ch in chips:
		roster_strip.add_child(_roster_chip(String(ch.get("name", "?")), String(ch.get("state", "act"))))
	if phase_banner != null:
		phase_banner.text = "ROUND %d — %s" % [max(1, round_num), phase_name]
		# PLAYER phase reads AMBER (your move); ENEMY/ENVIRONMENT read DIM/CYAN (read-only, their move).
		var col := Pal.AMBER if phase_name.begins_with("PLAYER") else (Pal.ALERT_RED if phase_name.begins_with("ENEMY") else Pal.CYAN)
		phase_banner.add_theme_color_override("font_color", col)


## A single roster chip: a small bordered panel with the callsign, colored by state (can-act AMBER /
## spent DIM / downed ALERT_RED). Render-only.
func _roster_chip(name: String, state: String) -> Panel:
	var col := Pal.AMBER
	match state:
		"spent":  col = Pal.DIM
		"downed": col = Pal.ALERT_RED
		_:        col = Pal.AMBER
	var p := Panel.new()
	p.custom_minimum_size = Vector2(72, 22)
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(Pal.FRAME_INSET.r, Pal.FRAME_INSET.g, Pal.FRAME_INSET.b, 0.12)
	sb.border_color = col
	sb.set_border_width_all(1)
	sb.set_corner_radius_all(2)
	p.add_theme_stylebox_override("panel", sb)
	p.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var l := _label(name.substr(0, 8), col, 11)
	l.position = Vector2(5, 3)
	p.add_child(l)
	return p


# ============================ SPEED LABEL (#24) ===============================
## Set the SPEED button label to read the active multiplier (#24 — "SPEED 1x" / "SPEED 2x" / "SPEED 4x").
## Today the SPEED hint was only a transient comms line; this makes the button itself carry the state.
## On-screen-only.
func set_speed_label(mult: int) -> void:
	if _speed_button != null:
		_speed_button.text = "SPEED %dx" % max(1, mult)

# ============================ FINALE BOSS HUD API (Batch 3) ===================
## Raise the Engine-Vault boss chrome (F1+ — ART_BIBLE §4 Section 5 ENGINE / ALARM). RE-SKINS the
## console: swaps the now-meaningless RECON rail for the OBJECTIVE / relay-shield / core panel, raises
## the dormant COUNTDOWN CLOCK over the top bar (DIM "BRIDGE LOCK :: ARMED" until set_bridge_countdown
## detonates it), arms the telegraph strip above comms, and inks the chrome to the alarm palette. Lazy:
## the boss widgets are built ONCE on first entry, then just shown. On-screen-only (no OpsHUD headless).
func enter_finale_mode() -> void:
	if _finale_mode:
		return
	_finale_mode = true
	if _countdown_panel == null:
		_build_finale_chrome()
	# Re-skin: the recon strip becomes the OBJECTIVE panel; the dormant lock + telegraph appear.
	if recon_box != null:
		recon_box.visible = false
	if _objective_box_panel != null:
		_objective_box_panel.visible = true
	if _countdown_panel != null:
		_countdown_panel.visible = true
	if _telegraph_panel != null:
		_telegraph_panel.visible = true
	# F1 antechamber readouts: the clock is DORMANT (armed, not ticking) and the objective checklist
	# shows step 1. The Conductor is shielded, so the core header reads UP.
	_countdown_expired = false
	if _countdown_label != null:
		_countdown_label.text = "BRIDGE LOCK :: ARMED"
		_countdown_label.add_theme_color_override("font_color", Pal.DIM)
		_countdown_label.modulate.a = 1.0
	if _countdown_sub != null:
		_countdown_sub.visible = false
	if _countdown_bar != null:
		_countdown_bar.size.x = 0.0
	set_conductor_telegraph(-1, "")
	# W4-9: the finale header ("ENGINE — CONDUCTOR'S CHAMBER · PHASE n/3") is far longer than a normal
	# car ID and overran the REC/timecode at their default slot. Slide that cluster into the empty gap
	# before the Order meter so the phase label and the ● REC tally never overlap at 1280x720.
	if rec_label != null:
		rec_label.position = REC_POS_FINALE
	if timecode_label != null:
		timecode_label.position = TC_POS_FINALE
	# The §2 chrome stays constant; we tint the top bar + objective header to ENGINE accent so the
	# room reads as "the antagonist" without rebuilding any region.
	if camera_label != null:
		camera_label.add_theme_color_override("font_color", Pal.AMBER)


## Lower the boss chrome back to the normal car console (used if a finale is abandoned without
## resolving — defensive; the normal flow ends at F5). Restores the recon rail.
func exit_finale_mode() -> void:
	if not _finale_mode:
		return
	_finale_mode = false
	# Restore the default top-bar REC/timecode slot (W4-9 reposition is finale-scoped).
	if rec_label != null:
		rec_label.position = REC_POS_DEFAULT
	if timecode_label != null:
		timecode_label.position = TC_POS_DEFAULT
	if recon_box != null:
		recon_box.visible = true
	if _objective_box_panel != null:
		_objective_box_panel.visible = false
	if _countdown_panel != null:
		_countdown_panel.visible = false
	if _telegraph_panel != null:
		_telegraph_panel.visible = false
	if _lockdown_bezel != null:
		_lockdown_bezel.visible = false


## The BRIDGE COUNTDOWN CLOCK (F2/F4): a big mono ALERT_RED `BRIDGE :: T-{n}` with a draining bar,
## distinct from the small CYAN `● REC` timecode. `expired` flips it to the steady, non-blinking
## `BRIDGE :: BREACHED` hazard state (F4 — the point of no return; good endings locked). While
## running, the bar drains full->empty over BRIDGE_FULL rounds and lerps CYAN->ALERT_RED; at T-3..T-1
## the clock blinks (driven in _tick_finale_chrome). Idempotent; on-screen-only.
func set_bridge_countdown(n: int, expired: bool) -> void:
	_countdown_n = n
	_countdown_expired = expired
	if _countdown_label == null:
		return
	if expired:
		_countdown_label.text = "BRIDGE :: BREACHED"
		_countdown_label.add_theme_color_override("font_color", ENGINE_GLOW)
		_countdown_label.modulate.a = 1.0
		if _countdown_sub != null:
			_countdown_sub.visible = true
		if _countdown_bar != null:
			_countdown_bar.color = ENGINE_GLOW
			_countdown_bar.size.x = _countdown_bar_bg.size.x   # static hazard-stripe fill
		return
	if _countdown_sub != null:
		_countdown_sub.visible = false
	_countdown_label.text = "BRIDGE :: T-%02d" % max(0, n)
	# CYAN at T-10 lerping to ALERT_RED as it drains; hard ALERT_RED in the urgency band.
	var frac: float = clamp(float(n) / float(BRIDGE_FULL), 0.0, 1.0)
	var col: Color = ENGINE_GLOW if n <= 3 else Pal.CYAN.lerp(ENGINE_GLOW, 1.0 - frac)
	_countdown_label.add_theme_color_override("font_color", col)
	if _countdown_bar != null and _countdown_bar_bg != null:
		_countdown_bar.size.x = _countdown_bar_bg.size.x * frac
		_countdown_bar.color = col


## The RELAY / SHIELD STATUS BLOCK (F2). `rows` is an Array of per-relay dicts the controller builds
## from the live objective/state:
##   { tag:"A", power:"PISTONS", cur:<integrity>, max:<integrity>, online:bool, targeted:bool }
## A fallen relay flips to a DIM strikethrough row + its mapped power greyed. On-screen-only.
func set_relay_status(rows: Array) -> void:
	if _objective_box == null:
		return
	_clear_objective_body()
	for r in rows:
		var online: bool = bool(r.get("online", true))
		var tag: String = String(r.get("tag", "?"))
		var power: String = String(r.get("power", ""))
		var cur: int = int(r.get("cur", 0))
		var mx: int = int(r.get("max", 0))
		var targeted: bool = bool(r.get("targeted", false))
		var col: Color = Pal.CYAN if online else Pal.DIM
		if targeted and online:
			col = ENGINE_LIGHT
		var pips := _pip_bar(cur, mx) if online else "▒▒▒▒"
		var state := ("ONLINE" if online else "DISABLED")
		var line := "RELAY %s [%s]" % [tag, power]
		var row := _label(line, col, 12)
		_objective_box.add_child(row)
		var sub := _label("   %s  %s%s" % [pips, state, ("  ◂AIM" if targeted and online else "")], col, 11)
		_objective_box.add_child(sub)


## The CORE SHIELD header (F2): UP (ALERT_RED — the room is protecting the Conductor) vs DROPPED.
## Sets the objective header; the relay rows are set separately by set_relay_status. On-screen-only.
func set_core_shield(up: bool) -> void:
	if _objective_header == null:
		return
	if up:
		_objective_header.text = "CORE SHIELD :: UP"
		_objective_header.add_theme_color_override("font_color", ENGINE_GLOW)
	else:
		_objective_header.text = "CORE SHIELD :: DOWN"
		_objective_header.add_theme_color_override("font_color", Pal.CYAN)


## The CORE INTEGRITY GAUGE (F3): replaces the relay block with a big pip bar draining as the Core
## takes sabotage hits. `cur`/`max` are the live core integrity (CORE_INTEGRITY_DEFAULT=12). The
## CYAN gauge is the one "go" signal in the red room; it blinks at <=2 pips (critical). On-screen-only.
func set_core_integrity(cur: int, mx: int) -> void:
	if _objective_box == null or _objective_header == null:
		return
	_objective_header.text = "ENGINE CORE :: EXPOSED"
	_objective_header.add_theme_color_override("font_color", Pal.CYAN)
	_clear_objective_body()
	var pips := _pip_bar(cur, mx)
	var crit: bool = cur <= 2
	var col: Color = ENGINE_GLOW if crit else Pal.CYAN
	_objective_box.add_child(_label("CORE  %s" % pips, col, 14))
	_objective_box.add_child(_label("INTEGRITY %d / %d" % [max(0, cur), mx], col, 12))
	_objective_box.add_child(_label("[ SABOTAGE — TAP THE CORE ]", Pal.CYAN, 12))


## The CONDUCTOR TELEGRAPH BANNER (F2/F3): the one-turn warning (B3.3). `action` is a ConductorAction
## id (or -1 for none); `target` is an optional unit name. Empty -> the DIM "— CONDUCTOR STANDBY —"
## state; armed -> AMBER "⚠ CONDUCTOR → {ACTION} (targets {TARGET}) — next turn". On-screen-only.
func set_conductor_telegraph(action: int, target: String) -> void:
	if _telegraph_label == null:
		return
	if action < 0:
		_telegraph_label.text = "— CONDUCTOR STANDBY —"
		_telegraph_label.add_theme_color_override("font_color", Pal.DIM)
		return
	var name := _conductor_action_name(action)
	var tgt := ("  (targets %s)" % target) if target != "" else ""
	_telegraph_label.text = "⚠ CONDUCTOR → %s%s — next turn" % [name, tgt]
	_telegraph_label.add_theme_color_override("font_color", Pal.AMBER)


## The Phase-3 LOCKDOWN BEZEL (F3): an ALERT_RED inset frame around the feed, slow-pulsing — the
## single strongest "this is the boss" visual. Toggled on entering CORE_EXPOSED. On-screen-only.
func set_lockdown(on: bool) -> void:
	if _lockdown_bezel == null:
		return
	_lockdown_bezel.visible = on
	if camera_label != null and on:
		# Phase 3/3 alarm: the header gains the lockdown wash.
		pass


## The ESCALATION TICKER (F4): a transient strip that flashes "ESC +{level} :: {cause}" each
## VAULT_ESCALATE, then settles to a small persistent badge. On-screen-only.
func push_escalation(level: int, cause: String) -> void:
	if _escalation_label == null:
		return
	_escalation_label.text = "ESC +%d :: %s" % [level, cause]
	_escalation_label.add_theme_color_override("font_color", ENGINE_GLOW)
	_escalation_label.visible = true
	_esc_flash_t = 1.5


# ============================ finale chrome build + helpers ===================
## Build the boss-HUD widgets ONCE (lazy, on first enter_finale_mode). All start hidden; the
## re-skin in enter_finale_mode reveals them. Built in code, ART_BIBLE-grounded, cheap.
func _build_finale_chrome() -> void:
	var root: Control = null
	# Re-use the same Control root the regular regions live under (first child Control).
	for c in get_children():
		if c is Control:
			root = c
			break
	if root == null:
		return
	# --- COUNTDOWN CLOCK (prime center-top, over the feed, below the top bar) ---
	_countdown_panel = _panel(Vector2(470, 58), Vector2(340, 64))
	_countdown_panel.visible = false
	root.add_child(_countdown_panel)
	_countdown_label = _label("BRIDGE LOCK :: ARMED", Pal.DIM, 26)
	_countdown_label.position = Vector2(16, 6)
	_countdown_panel.add_child(_countdown_label)
	_countdown_sub = _label("◣ POINT OF NO RETURN", ENGINE_GLOW, 12)
	_countdown_sub.position = Vector2(18, 40)
	_countdown_sub.visible = false
	_countdown_panel.add_child(_countdown_sub)
	_countdown_bar_bg = ColorRect.new()
	_countdown_bar_bg.color = Pal.FRAME_BG
	_countdown_bar_bg.position = Vector2(16, 44)
	_countdown_bar_bg.size = Vector2(308, 8)
	_countdown_panel.add_child(_countdown_bar_bg)
	_countdown_bar = ColorRect.new()
	_countdown_bar.color = Pal.CYAN
	_countdown_bar.position = Vector2(16, 44)
	_countdown_bar.size = Vector2(0, 8)
	_countdown_panel.add_child(_countdown_bar)
	# Escalation ticker — under the clock, right-aligned, hidden until a VAULT_ESCALATE.
	_escalation_label = _label("", ENGINE_GLOW, 12)
	_escalation_label.position = Vector2(180, 26)
	_escalation_label.visible = false
	_countdown_panel.add_child(_escalation_label)

	# --- OBJECTIVE / relay-shield / core panel (in the RECON rail slot, swaps the recon strip) ---
	var obj_panel := _panel(Vector2(992, 60), Vector2(280, 430))
	obj_panel.visible = false
	root.add_child(obj_panel)
	_objective_box_panel = obj_panel
	_objective_header = _label("OBJECTIVE — STOP THE TRAIN", Pal.CYAN, 14)
	_objective_header.position = Vector2(10, 4)
	obj_panel.add_child(_objective_header)
	_objective_box = VBoxContainer.new()
	_objective_box.position = Vector2(10, 30)
	_objective_box.size = Vector2(260, 392)
	obj_panel.add_child(_objective_box)
	# F1 default body: the 3-step checklist (step 1 highlighted) until the relay block takes over.
	_objective_default_body()

	# --- TELEGRAPH BANNER (1-line strip above the comms log) ---
	_telegraph_panel = _panel(Vector2(8, 494), Vector2(520, 24))
	_telegraph_panel.visible = false
	root.add_child(_telegraph_panel)
	_telegraph_label = _label("— CONDUCTOR STANDBY —", Pal.DIM, 12)
	_telegraph_label.position = Vector2(10, 2)
	_telegraph_panel.add_child(_telegraph_label)

	# --- LOCKDOWN BEZEL (Phase-3 inset frame around the feed) — drawn as a thin bordered Control ---
	_lockdown_bezel = Control.new()
	_lockdown_bezel.set_anchors_preset(Control.PRESET_FULL_RECT)
	_lockdown_bezel.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_lockdown_bezel.visible = false
	var bezel_style := Panel.new()
	bezel_style.set_anchors_preset(Control.PRESET_FULL_RECT)
	bezel_style.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(0, 0, 0, 0)
	sb.border_color = ENGINE_GLOW
	sb.set_border_width_all(6)
	bezel_style.add_theme_stylebox_override("panel", sb)
	_lockdown_bezel.add_child(bezel_style)
	root.add_child(_lockdown_bezel)


## The F1 OBJECTIVE checklist body (3 steps, step 1 highlighted AMBER). Shown until the relay
## block replaces it (set_relay_status) once the Conductor is active.
func _objective_default_body() -> void:
	if _objective_box == null:
		return
	_clear_objective_body()
	_objective_box.add_child(_label("1 DISABLE RELAYS", Pal.AMBER, 13))
	_objective_box.add_child(_label("2 EXPOSE CORE", Pal.DIM, 13))
	_objective_box.add_child(_label("3 SABOTAGE", Pal.DIM, 13))


func _clear_objective_body() -> void:
	if _objective_box == null:
		return
	for c in _objective_box.get_children():
		c.queue_free()


## A 4..N-pip integrity bar string (filled █ vs empty ░), clamped sensibly for the rail width.
func _pip_bar(cur: int, mx: int) -> String:
	var n: int = clampi(mx, 1, 12)
	var filled: int = clampi(cur, 0, n)
	return "█".repeat(filled) + "░".repeat(n - filled)


## ConductorAction id -> a short display name for the telegraph banner.
func _conductor_action_name(action: int) -> String:
	match action:
		E.ConductorAction.RE_ROUTE:   return "RE-ROUTE"
		E.ConductorAction.DEPLOY:     return "DEPLOY"
		E.ConductorAction.OVERCHARGE: return "OVERCHARGE"
		E.ConductorAction.ACCELERATE: return "ACCELERATE"
		E.ConductorAction.LOCKDOWN:   return "LOCKDOWN"
		_: return "STANDBY"


# ============================ widget helpers ===================================
func _panel(pos: Vector2, sz: Vector2) -> Panel:
	var p := Panel.new()
	p.position = pos
	p.size = sz
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(Pal.FRAME_BG.r, Pal.FRAME_BG.g, Pal.FRAME_BG.b, 0.85)
	sb.border_color = Pal.FRAME_BORDER
	sb.set_border_width_all(1)
	sb.border_width_top = 2
	p.add_theme_stylebox_override("panel", sb)
	p.mouse_filter = Control.MOUSE_FILTER_IGNORE
	return p

func _label(text: String, col: Color, size: int) -> Label:
	var l := Label.new()
	l.text = text
	l.add_theme_color_override("font_color", col)
	l.add_theme_font_size_override("font_size", size)
	l.mouse_filter = Control.MOUSE_FILTER_IGNORE
	return l


## A word-wrapping legend label (W5-13): bounded to LEGEND_TEXT_W so long lines wrap inside the panel
## instead of running off the right edge of the viewport. In the legend VBox the width is honored via
## custom_minimum_size; autowrap breaks the row onto extra lines as needed. Render-only.
func _wrap_label(text: String, col: Color, size: int) -> Label:
	var l := _label(text, col, size)
	l.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	l.custom_minimum_size = Vector2(LEGEND_TEXT_W, 0)
	l.size = Vector2(LEGEND_TEXT_W, 0)
	return l


## Attach a hover/long-press tooltip to an otherwise click-through label (combat-ux #7). A tooltip
## needs a hit-testable control, so we flip the label's mouse_filter IGNORE -> PASS: it now reports a
## tooltip on hover but still lets clicks fall through to the feed underneath (no combat input eaten).
func _with_tooltip(l: Label, text: String) -> void:
	l.tooltip_text = text
	l.mouse_filter = Control.MOUSE_FILTER_PASS

## A real action Button that emits action_pressed(name) on click. Restyled to the ops look. SHOOT
## carries a static end-turn tell (⏻) in its label — shooting always ends the actor's turn (§5.2),
## a palette-state cue (#19) the operator reads before committing the irreversible shot.
func _action_button(text: String) -> Button:
	var b := Button.new()
	b.text = ("SHOOT⏻" if text == "SHOOT" else text)
	b.focus_mode = Control.FOCUS_NONE
	b.add_theme_font_size_override("font_size", 13)
	b.add_theme_color_override("font_color", Pal.CYAN)
	b.custom_minimum_size = Vector2(54, 26)
	b.add_theme_stylebox_override("normal", _action_stylebox(false))
	# Onboarding help (combat-ux #7): a hover/long-press tooltip from the design vocabulary. Enabling
	# tooltip_text also makes touch long-press surface it; keyed by the logical name, not the label.
	if ACTION_TOOLTIPS.has(text):
		b.tooltip_text = String(ACTION_TOOLTIPS[text])
	# The signal carries the LOGICAL action name (text), not the decorated label.
	b.pressed.connect(func(): emit_signal("action_pressed", text))
	# W6-6 run-layer UI SFX: a commit action fires "confirm"; CANCEL/UNDO fire the "back" slot.
	b.pressed.connect(play_ui_cue.bind("back" if (text == "CANCEL" or text == "UNDO") else "confirm"))
	return b


## A control Button (AUTO / SPEED) that emits control_pressed(name).
func _control_button(text: String) -> Button:
	var b := Button.new()
	b.text = text
	b.focus_mode = Control.FOCUS_NONE
	b.add_theme_font_size_override("font_size", 13)
	b.add_theme_color_override("font_color", Pal.AMBER)
	b.custom_minimum_size = Vector2(70, 26)
	if CONTROL_TOOLTIPS.has(text):
		b.tooltip_text = String(CONTROL_TOOLTIPS[text])
	b.pressed.connect(func(): emit_signal("control_pressed", text))
	b.pressed.connect(play_ui_cue.bind("select"))   # W6-6 run-layer UI SFX
	return b


## Enable/disable the action buttons (greyed out until a unit with AP is selected).
func set_actions_enabled(on: bool) -> void:
	for k in _action_buttons.keys():
		_action_buttons[k].disabled = not on
	if not on:
		set_armed_mode("")   # clear any selected-tint when the whole palette goes inactive
		set_stabilize_available(false)   # no selection -> no stabilize target either


## Show/enable the STABILIZE palette button (W5-12) only when a stabilize target exists. `available`
## comes from the controller (a downed, bleeding player ally is in reach). Hidden = the EMPTY state: the
## verb is irrelevant, so the button never clutters the palette; shown = an armed, tappable revive. The
## button emits action_pressed("STAB"), which the controller routes to the exact keyboard STABILIZE path.
## On-screen-only (headless never instances OpsHUD).
func set_stabilize_available(available: bool) -> void:
	if _stab_button == null:
		return
	_stab_button.visible = available
	_stab_button.disabled = not available


# ============================ ACTION-PALETTE STATES (#19; Batch 5) =============
## The currently armed action mode name (the selected-tint target), "" = none.
var _armed_mode: String = ""

## Selected-tint the active action button (#19 — S4-03). `mode_name` is one of MOVE/SHOOT/SHOVE/
## SLAM/THROW (or "" for none). The armed button gains a solid AMBER border + brightened label; all
## others fall back to the default ops look. Idempotent; on-screen-only (no OpsHUD headless).
func set_armed_mode(mode_name: String) -> void:
	_armed_mode = mode_name
	for k in _action_buttons.keys():
		var b: Button = _action_buttons[k]
		var sel: bool = (String(k) == mode_name and mode_name != "")
		b.add_theme_stylebox_override("normal", _action_stylebox(sel))
		b.add_theme_stylebox_override("hover", _action_stylebox(sel))
		b.add_theme_stylebox_override("pressed", _action_stylebox(true))
		if not b.disabled:
			b.add_theme_color_override("font_color", Pal.AMBER if sel else Pal.CYAN)


## Per-button palette states (#19): affordability disable + the OVR overwatch state + the UNDO
## availability + the SHOOT ends-turn tell. `states` is a dict keyed by action name, each a small
## dict the controller built off the live turn/intent:
##   MOVE/SHOVE/SLAM/THROW : { enabled:bool }            (false when out of AP / no legal target)
##   SHOOT                 : { enabled:bool }            (label carries the ⏻ end-turn tell always)
##   OVR                   : { enabled:bool, selected:bool }  (selected/disabled when already overwatching)
##   UNDO                  : { enabled:bool }            (off InputIntent._undo_stack)
##   CANCEL                : { enabled:bool }            (a mode is armed / a preview is up)
## Buttons absent from `states` keep their current enabled flag. On-screen-only.
func set_palette_states(states: Dictionary) -> void:
	for k in states.keys():
		if not _action_buttons.has(k):
			continue
		var b: Button = _action_buttons[k]
		var st: Dictionary = states[k]
		b.disabled = not bool(st.get("enabled", true))
		# OVR shows a SELECTED tint when the unit is already overwatching (a latched state, #19).
		if String(k) == "OVR":
			var ovr_sel: bool = bool(st.get("selected", false))
			b.add_theme_stylebox_override("normal", _action_stylebox(ovr_sel))
			b.add_theme_stylebox_override("hover", _action_stylebox(ovr_sel))
			b.text = "OVR●" if ovr_sel else "OVR"
		# Affordable buttons read CYAN; disabled read DIM (unless armed — set_armed_mode owns AMBER).
		if not b.disabled and String(k) != _armed_mode:
			b.add_theme_color_override("font_color", Pal.CYAN)
		elif b.disabled:
			b.add_theme_color_override("font_color", Pal.DIM)


# ============================ ABILITY / ITEM CHOICE POPUP (Batch 6) ============
## Raise the compact ability/item picker (#depth-toolkit). `kind` is "ability" or "item"; `entries`
## is the controller's PURE draw-data, one row per candidate, in stable order:
##   { id:String, label:String, enabled:bool, reason:String }
## Enabled rows are tappable (emit ability_chosen/item_chosen(id) + close); disabled rows read DIM
## with their reason inline (out of AP / no target). An EMPTY list shows a dim "(none)" row so the
## popup is never a dead end. Touch-friendly 40px rows. On-screen-only (headless never builds OpsHUD).
func open_choice_menu(kind: String, title: String, entries: Array) -> void:
	_choice_kind = kind
	if _choice_panel == null:
		_build_choice_menu()
	_choice_title.text = title
	for c in _choice_list.get_children():
		c.queue_free()
	if entries.is_empty():
		_choice_list.add_child(_label("(none available)", Pal.DIM, 13))
	else:
		for e in entries:
			_choice_list.add_child(_choice_row(e))
	_choice_panel.visible = true


## Close the picker (also the row-tap and DISMISS path). Idempotent. On-screen-only.
func close_choice_menu() -> void:
	if _choice_panel != null:
		_choice_panel.visible = false


## True while the ability/item picker is up (the controller routes ESC to close it, not abandon).
func choice_menu_open() -> bool:
	return _choice_panel != null and _choice_panel.visible


func _build_choice_menu() -> void:
	var root: Control = null
	for c in get_children():
		if c is Control:
			root = c
			break
	if root == null:
		# Defensive: the popup can be raised before _ready ran the main _build (or in a headless
		# harness that never processes a frame) — give it its own full-rect Control parent.
		root = Control.new()
		root.set_anchors_preset(Control.PRESET_FULL_RECT)
		root.mouse_filter = Control.MOUSE_FILTER_IGNORE
		add_child(root)
	_choice_panel = _panel(Vector2(470, 300), Vector2(340, 300))
	_choice_panel.mouse_filter = Control.MOUSE_FILTER_STOP   # modal — blocks feed clicks behind it
	_choice_panel.visible = false
	root.add_child(_choice_panel)
	_choice_title = _label("ABILITIES", Pal.AMBER, 18)
	_choice_title.position = Vector2(16, 12)
	_choice_panel.add_child(_choice_title)
	var rule := ColorRect.new()
	rule.color = Pal.FRAME_BORDER
	rule.position = Vector2(16, 40)
	rule.size = Vector2(308, 2)
	_choice_panel.add_child(rule)
	_choice_list = VBoxContainer.new()
	_choice_list.position = Vector2(16, 50)
	_choice_list.size = Vector2(308, 196)
	_choice_list.add_theme_constant_override("separation", 4)
	_choice_panel.add_child(_choice_list)
	var dismiss := _control_button("[ CLOSE ]")
	dismiss.position = Vector2(16, 258)
	dismiss.pressed.connect(close_choice_menu)
	_choice_panel.add_child(dismiss)


## A single picker row: a tappable Button when enabled (emits the kind's chosen signal + closes),
## or a DIM disabled row carrying its reason. When the entry carries a `hint` (W5-6 — the one-line
## effect + AP + range/targeting), the row renders TWO lines: the name/AP on top, a DIM effect hint
## under it, so a new player learns what "Gas Tap" does without leaving the popup. Interactive states:
## default / hover / pressed via the shared action stylebox; disabled greyed. Render-only.
func _choice_row(e: Dictionary) -> Button:
	var b := Button.new()
	b.focus_mode = Control.FOCUS_NONE
	b.clip_text = false
	b.disabled = not bool(e.get("enabled", true))
	var id: String = String(e.get("id", ""))
	var label: String = String(e.get("label", id))
	var reason: String = String(e.get("reason", ""))
	var hint: String = String(e.get("hint", ""))
	var head_text: String = label if reason == "" else "%s  — %s" % [label, reason]
	b.add_theme_font_size_override("font_size", 13)
	b.add_theme_color_override("font_color", Pal.CYAN if not b.disabled else Pal.DIM)
	b.add_theme_color_override("font_color_disabled", Pal.DIM)
	b.add_theme_stylebox_override("normal", _action_stylebox(false))
	b.add_theme_stylebox_override("hover", _action_stylebox(true))
	b.add_theme_stylebox_override("pressed", _action_stylebox(true))
	b.add_theme_stylebox_override("disabled", _action_stylebox(false))
	if hint != "":
		# Two-line row: the button text stays empty and child labels render (mirrors _recon_row) so the
		# name/AP and the DIM effect/range hint read as distinct lines. `choice_hint` is on the sub-label
		# so a headless test can read it back off the built row.
		b.custom_minimum_size = Vector2(300, 46)
		var content := Control.new()
		content.position = Vector2(10, 4)
		content.mouse_filter = Control.MOUSE_FILTER_IGNORE
		b.add_child(content)
		var head := _label(head_text, Pal.CYAN if not b.disabled else Pal.DIM, 13)
		head.position = Vector2(0, 0)
		content.add_child(head)
		var sub := _label(hint, Pal.DIM, 11)
		sub.name = "choice_hint"
		sub.position = Vector2(0, 18)
		content.add_child(sub)
	else:
		b.custom_minimum_size = Vector2(300, 40)
		b.text = head_text
	if not b.disabled:
		b.pressed.connect(_on_choice_row.bind(id))
	return b


## A one-line, player-facing EFFECT hint for an ability/item def (W5-6): "<what it does> · <AP> AP ·
## <targeting/range>", e.g. Gas Tap -> "release a poison gas cloud · 1 AP · tile, range 4". PURE +
## static so the controller builds it into each picker entry (`hint`) and the headless test asserts it.
## Reads only the def's first ACTIVE-shaped effect + apCost/targeting/range; unmapped kinds humanize the
## raw kind so it is never blank. Render-only vocabulary (never touches the sim).
static func effect_hint(def: Dictionary) -> String:
	var effs: Array = def.get("effects", [])
	var phrase: String = ""
	for eff in effs:
		phrase = _effect_phrase(eff)
		if phrase != "":
			break
	if phrase == "":
		phrase = "special action" if effs.is_empty() else String(effs[0].get("kind", "act")).replace("_", " ")
	var ap: int = int(def.get("apCost", 1))
	var tgt: String = String(def.get("targeting", "self"))
	var rng: int = int(def.get("range", 0))
	return "%s · %d AP · %s" % [phrase, ap, _target_phrase(tgt, rng)]


## Map one effect dict -> a short verb phrase (or "" if it has no player-facing verb). Covers the active
## ability/gadget kinds; params (hazard/status) fill the blank so "Gas Tap" reads as poison, not "spawn".
static func _effect_phrase(eff: Dictionary) -> String:
	var kind: String = String(eff.get("kind", ""))
	match kind:
		"spawn_hazard":  return "release a %s cloud" % String(eff.get("hazard", "gas")).replace("_", " ")
		"place_charge":  return "plant a timed charge"
		"detonate_all_charges": return "detonate all planted charges"
		"hack":          return "hijack a robot / turret / junction"
		"deploy_power_source":  return "drop a power source"
		"electrify":     return "electrify connected water"
		"ignite_gas":    return "ignite a standing gas cloud"
		"rupture_tank":  return "burst a tank at range (flood)"
		"impulse":       return "shove with an impulse"
		"throw":         return "hurl the target"
		"pull":          return "reel the target in"
		"status":        return "apply %s" % String(eff.get("status", "a status"))
		"damage":        return "deal damage"
		"heal":          return "restore HP"
		"stabilize":     return "stop a downed ally's bleed-out"
		"clear_status":  return "clear a status"
		"grant_ap":      return "grant extra AP"
		"ranged_attack": return "ranged attack"
		"melee_attack":  return "melee attack"
		"immobilize":    return "pin the target in place"
		"move":          return "reposition"
		"hacked_units_extra_action": return "hacked units act again"
		"disable_all_cycling_traps": return "freeze cycling traps"
		"downed_fights_one_turn":    return "a downed ally fights one last turn"
		_: return ""


## Short targeting/range phrase for the effect hint (W5-6).
static func _target_phrase(targeting: String, rng: int) -> String:
	match targeting:
		"self":      return "self"
		"direction": return "adjacent"
		"enemy":     return ("enemy, range %d" % rng) if rng > 0 else "enemy"
		"ally":      return ("ally, range %d" % rng) if rng > 0 else "ally"
		"tile":      return ("tile, range %d" % rng) if rng > 0 else "tile"
		_:           return ("range %d" % rng) if rng > 0 else targeting


## A picker row was tapped — emit the kind's chosen signal and close the popup. Bound per-row (id).
func _on_choice_row(id: String) -> void:
	if _choice_kind == "item":
		emit_signal("item_chosen", id)
	else:
		emit_signal("ability_chosen", id)
	close_choice_menu()


# ============================ COMBAT ONBOARDING TIP BANNER (combat-ux #7) ======
## Raise the teaching banner with a title + body (the first-time-relevant tip). Top-center over the
## feed, clear of the palette and comms. Non-blocking: the panel STOPs clicks only over its own rect,
## so combat continues underneath; its [ GOT IT ] button and ESC both emit tip_dismissed. Built once
## (lazy), then reused. Idempotent text refresh. On-screen-only (headless never instances OpsHUD).
func show_tip(title: String, body: String) -> void:
	if _tip_panel == null:
		_build_tip_banner()
	if _tip_title != null:
		_tip_title.text = "TIP — " + title
	if _tip_body != null:
		_tip_body.text = body
	_tip_panel.visible = true


## Hide the tip banner (the [ GOT IT ] / ESC / dismiss path). Idempotent. On-screen-only.
func hide_tip() -> void:
	if _tip_panel != null:
		_tip_panel.visible = false


## True while a tip banner is up (the controller routes ESC to dismiss it, not to abandon the run).
func tip_open() -> bool:
	return _tip_panel != null and _tip_panel.visible


func _build_tip_banner() -> void:
	var root: Control = null
	for c in get_children():
		if c is Control:
			root = c
			break
	if root == null:
		root = Control.new()
		root.set_anchors_preset(Control.PRESET_FULL_RECT)
		root.mouse_filter = Control.MOUSE_FILTER_IGNORE
		add_child(root)
	# W5-10: the board now climbs UPWARD, so the top-center of the feed is the LIVE action/telegraph zone
	# (the front line + the finale COUNTDOWN clock at y58-122). The tip card used to sit at y66 and covered
	# it. It now sits in the lower-center feed band — clear of the top bar, the top-center action/telegraph,
	# AND the bottom SELECTED-UNIT / comms / recon panels — a wide short teaching card.
	_tip_panel = _panel(Vector2(300, 386), Vector2(680, 104))
	_tip_panel.mouse_filter = Control.MOUSE_FILTER_STOP   # blocks clicks over the card only (not the feed)
	# AMBER accent border so it reads as guidance, not alarm (ART_BIBLE reserves ALERT_RED).
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(Pal.FRAME_BG.r, Pal.FRAME_BG.g, Pal.FRAME_BG.b, 0.94)
	sb.border_color = Pal.AMBER
	sb.set_border_width_all(2)
	sb.set_corner_radius_all(3)
	_tip_panel.add_theme_stylebox_override("panel", sb)
	_tip_panel.visible = false
	root.add_child(_tip_panel)
	_tip_title = _label("TIP", Pal.AMBER, 16)
	_tip_title.position = Vector2(16, 8)
	_tip_panel.add_child(_tip_title)
	_tip_body = _label("", Pal.CYAN, 13)
	_tip_body.position = Vector2(16, 32)
	_tip_body.size = Vector2(648, 40)
	_tip_body.custom_minimum_size = Vector2(648, 40)
	_tip_body.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_tip_panel.add_child(_tip_body)
	var foot := _label("(combat tips can be turned off in Settings)", Pal.DIM, 10)
	foot.position = Vector2(16, 82)
	_tip_panel.add_child(foot)
	_tip_dismiss = _control_button("[ GOT IT ]")
	_tip_dismiss.position = Vector2(560, 78)
	_tip_dismiss.pressed.connect(func():
		hide_tip()
		emit_signal("tip_dismissed"))
	_tip_panel.add_child(_tip_dismiss)


## The action-button stylebox: default = FRAME_BORDER edge; armed/selected = solid AMBER 2px + a
## faint inset wash (mirrors the draft/econ selected-row tell for a consistent §3 language).
func _action_stylebox(selected: bool) -> StyleBoxFlat:
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(Pal.FRAME_INSET.r, Pal.FRAME_INSET.g, Pal.FRAME_INSET.b, 0.20 if selected else 0.06)
	sb.border_color = Pal.AMBER if selected else Pal.FRAME_BORDER
	sb.set_border_width_all(2 if selected else 1)
	sb.set_corner_radius_all(2)
	return sb


## Update the interactive prompt line.
func set_hint(text: String) -> void:
	if hint_label != null:
		hint_label.text = text


## Reflect the current control mode on the AUTO button label + selected-state tint (#24): AUTO engaged
## reads "AUTO ▶" with a solid AMBER selected frame; MANUAL reads "MANUAL" with the default ops look.
func set_auto_label(is_auto: bool) -> void:
	if _auto_button == null:
		return
	_auto_button.text = "AUTO ▶" if is_auto else "MANUAL"
	_auto_button.add_theme_stylebox_override("normal", _action_stylebox(is_auto))
	_auto_button.add_theme_stylebox_override("hover", _action_stylebox(is_auto))
	_auto_button.add_theme_stylebox_override("pressed", _action_stylebox(true))
	_auto_button.add_theme_color_override("font_color", Pal.AMBER if is_auto else Pal.AMBER)


## W6-2 — reflect the AUTO SCOPE on the toggle button (the indicator). `scope` is "run" (auto plays
## the WHOLE run) or "fight" (auto plays THIS fight only, then hands back). The button label IS the
## indicator; whole-run reads AMBER (a committed, persistent auto), this-fight reads CYAN. Idempotent;
## on-screen-only (headless never instances OpsHUD).
func set_auto_scope(scope: String) -> void:
	_auto_scope = scope
	if _scope_button == null:
		return
	var whole: bool = (scope == "run")
	_scope_button.text = "SCOPE ▸ WHOLE RUN" if whole else "SCOPE ▸ THIS FIGHT"
	_scope_button.add_theme_color_override("font_color", Pal.AMBER if whole else Pal.CYAN)


## True while the AUTO scope is the whole run (a read the controller/test can use). On-screen-only.
func auto_scope_is_whole_run() -> bool:
	return _auto_scope == "run"


## W6-11 — reflect the one-per-run VET/SCAN availability on the palette button. `available` = the scan
## is still unused this run: enabled + CYAN "VET". Once spent it stays SHOWN but disabled + DIM "VET ✓"
## so the operator sees the counterplay exists and that it has been consumed. On-screen-only.
func set_vet_available(available: bool) -> void:
	if _vet_button == null:
		return
	_vet_button.disabled = not available
	_vet_button.text = "VET" if available else "VET ✓"
	_vet_button.add_theme_color_override("font_color", Pal.CYAN if available else Pal.DIM)


# ============================ RUN-LAYER UI SFX (W6-6) =========================
## Resolve the AudioDirector autoload (on-screen only). Guarded by is_inside_tree() so a headless
## test-instanced OpsHUD that never entered the active tree no-ops cleanly (an absolute /root path only
## resolves from inside the tree) instead of erroring. Mirrors the menu-lane resolver.
func _audio_director() -> Node:
	if not is_inside_tree():
		return null
	return get_node_or_null("/root/AudioDirector")


## Fire a named UI cue through the AudioDirector (UI bus): select / confirm / back / buy / error. This
## is the RUN-LAYER half of the UI SFX (W6-6) — the menu lane wired its own surfaces; this wires the
## ops_hud buttons. Silent + no-op headless (the director bails without a display), so the suites stay
## byte-stable. Public so the controller can route a rejected action to the "error" slot.
func play_ui_cue(cue: String) -> void:
	var ad := _audio_director()
	if ad != null:
		ad.play_ui(cue)


func _button_label(text: String) -> Label:
	var l := _label(" " + text + " ", Pal.CYAN, 13)
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(Pal.FRAME_BG.r, Pal.FRAME_BG.g, Pal.FRAME_BG.b, 0.9)
	sb.border_color = Pal.FRAME_BORDER
	sb.set_border_width_all(1)
	sb.content_margin_left = 6
	sb.content_margin_right = 6
	sb.content_margin_top = 4
	sb.content_margin_bottom = 4
	l.add_theme_stylebox_override("normal", sb)
	return l
