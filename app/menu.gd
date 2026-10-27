extends Control
## THE MAIN MENU — the ops-console front-end (GDD §16 "surveillance/ops console"). It is the
## project's `run/main_scene`: the first thing the game shows. From here the operator can:
##   - NEW RUN   : start a fresh run (launch run.tscn) with the profile's unlocked_content + any
##                 chosen Legacy handed off to the run (via MENU_HANDOFF, below).
##   - CONTINUE  : resume a mid-run save (SaveSystem.load_run) — enabled only when one exists.
##   - MEMORIAL  : view the fallen + pick ONE Legacy to inherit into the next run (§7.4).
##   - UNLOCKS   : spend meta-currency on permanent unlocks (§14).
##   - SETTINGS  : options, including the owner-flagged in-car-fog EXPOSURE (default unchanged).
##   - ASCII POC : the original ASCII proof-of-concept stays reachable.
##   - QUIT.
##
## It loads the persistent MetaProfile on entry and saves it on every mutation (purchase /
## settings change / legacy pick), so the disk is always current. Runs CLEAN HEADLESS: _ready
## builds the UI and loads the profile without ever touching a display server in a way that
## errors (a headless SceneTree instances Controls fine; we only avoid input/render assumptions).
##
## BATCH 6 cosmetic polish (FLOW Segment 1, ART_BIBLE §2/§5):
##   #25 BOOT/UPLINK — a short typed-line uplink cutscene on the comms cadence before HOME, with a
##       scanline overlay + REC/timecode + a one-shot "uplink established" glitch; SKIPPABLE by any
##       input. Gated behind not-headless/has-display so the menu-load test + suites stay byte-clean,
##       and it NEVER blocks the --sim self-play auto-run (the sim path launches after BOOT settles,
##       or immediately when headless).
##   #26 HOME CHROME — ops-console chrome: live scanline overlay (driven off crt_filter), a REC dot +
##       running timecode header reading as the in-run OpsHUD, panel StyleBox + corner ticks, and a
##       shared button StyleBox helper giving every row default/hover/focus/pressed/disabled states.
##       The cyan status string is promoted to header telemetry. CONTINUE stays disabled with no save.
##   #27 UNLOCKS/SETTINGS UX — Unlocks gains affordable/owned/can't-afford visual states, a price-color
##       affordance, and a purchase-success flash. Settings replaces the tap-cycle volumes with a real
##       draggable Slider (keeping the int model + headless-safety) and drives the menu's OWN scanline
##       overlay live off the crt_filter toggle.
##
## All Batch-6 additions are ON-SCREEN-ONLY: the headless suites never instance the menu, and every
## visual/animation path is gated behind `_has_display()`. The MetaProfile/SaveSystem/Unlocks/Legacy
## APIs are CONSUMED, never changed; the in-car-fog setting default is untouched.
##
## OWNERSHIP: app/menu.gd + app/menu.tscn + project.godot main_scene. It CONSUMES core/meta +
## reaches run.tscn; it never edits the run controller or core sim APIs.

const Pal = preload("res://render/palette.gd")
const E = preload("res://core/sim_enums.gd")

const SaveSystem = preload("res://core/meta/save_system.gd")
const MetaProfile = preload("res://core/meta/meta_profile.gd")
const Unlocks = preload("res://core/meta/unlocks.gd")
const Legacy = preload("res://core/meta/legacy.gd")

const RUN_SCENE   := "res://app/run.tscn"
const ASCII_SCENE := "res://app/main.tscn"

# The handoff from the menu to the next run: the unlocked content the line/draft should honor,
# and the single Legacy payload to apply at run start (or {} for none). A static holder so the
# run scene (now or once wired) can read the player's menu choices WITHOUT the menu editing the
# run controller. Set on NEW RUN / CONTINUE; read by the run when it starts.
class MenuHandoff:
	static var unlocked_car_ids: Array = []      # OWNED car unlock ids (additive gate; [] = none owned)
	static var unlocked_class_ids: Array = []    # widened starting-class pool
	static var legacy_payload: Dictionary = {}   # {kind:item|trait, id, from} or {} for none
	static var legacy_id: String = ""            # the Memorial hero id backing the payload — BURNED
	                                             # at BREACH finalize, never at NEW RUN click (W1-7)
	static var resume_run = null                 # a loaded RunState to continue, or null
	static var settings: Dictionary = {}         # live session settings the run consumes
	                                             # (confirm_moves, in_car_fog, sfx/music volume)
	static var run_seed: int = -1                # fresh player-path seed, or -1 = keep the
	                                             # controller's DEFAULT_SEED (headless/--sim, W1-5)

	static func reset() -> void:
		unlocked_car_ids = []
		unlocked_class_ids = []
		legacy_payload = {}
		legacy_id = ""
		resume_run = null
		settings = {}
		run_seed = -1


var profile                       # MetaProfile (loaded on entry)
var _chosen_legacy_id: String = ""  # the Memorial pick to inherit next run ("" = none)

# UI roots (built in code so the .tscn stays a 1-line script holder, matching run.tscn's style).
var _root: VBoxContainer
var _status_line: Label
var _panel_scroll: ScrollContainer   # W1-2 — long panels scroll inside the 720px canvas
var _panel_host: Control
var _active_panel: String = "home"
var _first_focus: Control = null     # W5-8 — the control that grabs initial focus on each panel build

# --- Batch-6 ops-console chrome (on-screen-only; never instanced headless) ---
var _scanlines: ColorRect      # the live CRT/scanline overlay (gated by crt_filter + has-display)
var _rec_label: Label          # the "● REC" dot (ALERT_RED) in the header
var _timecode_label: Label     # the running CYAN timecode (advances in _process, on-screen only)
var _boot: Control = null      # the transient BOOT/uplink cutscene root ("" once settled)
var _booting: bool = false     # TRUE while the boot cutscene owns the screen (input -> skip)
var _t: float = 0.0            # header timecode accumulator (real seconds, display-only)

# Header timecode + REC are display-only; never read by any test. Const here so the look matches
# the in-run OpsHUD header (ART_BIBLE §2 — the menu and the game are visibly the same machine).


func _ready() -> void:
	profile = SaveSystem.load_profile()
	MenuHandoff.reset()
	_build_ui()
	# AUDIO (W6-6): the console theme is the FIRST music cue — every entry to the menu starts the score
	# (play_music was dead-on-arrival before this: zero call sites, all 7 tracks silent). No-op headless
	# (AudioDirector no-ops without a display), so the byte-stable suites are unaffected.
	_play_music("theme")
	# DISPLAY (W6-8): honor the persisted fullscreen / vsync choices at boot (on-screen only; the
	# DisplayServer call is gated behind _has_display so headless never touches the window).
	_apply_display_setting("fullscreen")
	_apply_display_setting("vsync")
	# BOOT/UPLINK (#25): on a real display, play the cold-start uplink cutscene first, THEN reveal
	# HOME (and, if --sim, auto-launch). Headless skips straight to HOME so the menu-load test +
	# suites stay byte-clean and the --sim self-play proof still fires immediately.
	if _has_display():
		set_process(true)
		_start_boot()
	else:
		_show_home()
		_maybe_autostart_sim()


## True if the process was launched with the --sim / coldspine_sim flag (auto-run for the proof).
func _wants_sim() -> bool:
	return wants_sim_flag()


## Static form of the --sim detection so the run controller's [N] restage (W1-8) shares the
## exact launch-flag policy without duplicating it.
static func wants_sim_flag() -> bool:
	for a in OS.get_cmdline_args() + OS.get_cmdline_user_args():
		var s := String(a).to_lower()
		if s == "--sim" or s == "sim" or s.contains("coldspine_sim"):
			return true
	return false


# ============================ run-seed policy (W1-5) ==========================
## An explicit `--seed=N` launch arg, or -1 when absent. Lets a reported seed be replayed
## (including under --sim) — the ONLY way a flagged launch diverges from DEFAULT_SEED.
static func cli_seed() -> int:
	for a in OS.get_cmdline_args() + OS.get_cmdline_user_args():
		var s := String(a)
		if s.begins_with("--seed="):
			return int(s.substr(7)) & 0xFFFFFFFF
	return -1


static var _seed_nonce: int = 0   # roll_fresh_seed disambiguator (same-microsecond rolls)


## Roll a fresh 32-bit run seed from OS entropy. APP LAYER ONLY — core never touches
## wall-clock/randi (invariant #1); the seed enters the sim as plain data. A monotonically
## bumped nonce guarantees back-to-back rolls differ even inside one microsecond.
static func roll_fresh_seed() -> int:
	_seed_nonce += 1
	return (int(Time.get_ticks_usec()) ^ (randi() << 8) ^ (_seed_nonce * 0x9E3779B9)) & 0xFFFFFFFF


## The run seed to stage for a player-launched run (W1-5): an explicit --seed=N always wins
## (reproducible reruns); headless and the --sim proof keep -1 (= the controller's
## DEFAULT_SEED, byte-stable for every suite); a real windowed player launch rolls fresh.
static func pick_run_seed(display: bool) -> int:
	var cli := cli_seed()
	if cli >= 0:
		return cli
	if not display or wants_sim_flag():
		return -1
	return roll_fresh_seed()


## True when a real display server is present (NOT headless). Every Batch-6 animation/overlay path
## gates behind this so the headless menu-load (`--quit-after 2`) + the suites never build the boot
## cutscene, never run the timecode, and never instance the scanline shader — keeping them byte-stable.
func _has_display() -> bool:
	return not (OS.has_feature("headless") or DisplayServer.get_name() == "headless")


## Kick off a NEW RUN if launched with --sim. Deferred so the scene is fully in the tree first.
## Called AFTER boot settles (on-screen) or immediately (headless) — the self-play proof must run
## either way; BOOT must never block it (FLOW S1-00 TRANSITIONS OUT).
func _maybe_autostart_sim() -> void:
	if _wants_sim():
		call_deferred("_on_new_run")


# ============================ UI construction =================================
func _build_ui() -> void:
	set_anchors_preset(Control.PRESET_FULL_RECT)
	var bg := ColorRect.new()
	bg.color = Pal.FRAME_BG
	bg.set_anchors_preset(Control.PRESET_FULL_RECT)
	bg.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(bg)

	var pad := MarginContainer.new()
	pad.set_anchors_preset(Control.PRESET_FULL_RECT)
	pad.add_theme_constant_override("margin_left", 48)
	pad.add_theme_constant_override("margin_top", 36)
	pad.add_theme_constant_override("margin_right", 48)
	pad.add_theme_constant_override("margin_bottom", 36)
	add_child(pad)

	_root = VBoxContainer.new()
	_root.add_theme_constant_override("separation", 10)
	pad.add_child(_root)

	# Header row: camera-ID title on the left, the REC dot + running timecode on the right (the
	# same surveillance header as the in-run OpsHUD, ART_BIBLE §2). The header is the constant chrome.
	var header := HBoxContainer.new()
	header.add_theme_constant_override("separation", 16)
	_root.add_child(header)
	var title := _make_label("COLDSPINE  //  OPERATOR CONSOLE", Pal.AMBER, 28)
	title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	header.add_child(title)
	_rec_label = _make_label("● REC", Pal.ALERT_RED, 16)
	_rec_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	header.add_child(_rec_label)
	_timecode_label = _make_label("00:00:00", Pal.CYAN, 16)
	_timecode_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	header.add_child(_timecode_label)

	var sub := _make_label("uplink established — tail-section command", Pal.DIM, 14)
	_root.add_child(sub)

	# Promoted to header telemetry (#26): the cyan console-vitals readout sits right under the header.
	_status_line = _make_label("", Pal.CYAN, 16)
	_root.add_child(_status_line)

	var rule := ColorRect.new()
	rule.color = Pal.FRAME_BORDER
	rule.custom_minimum_size = Vector2(0, 2)
	_root.add_child(rule)

	# The panel host swaps between home / memorial / unlocks / settings views. It lives inside
	# a ScrollContainer (W1-2): a long panel (14 unlock rows, a deep Memorial) SCROLLS within
	# the 720px canvas instead of pushing its last rows + `< BACK` off-screen — the fixed
	# canvas_items/keep stretch can never reveal overflow by resizing, so the scroll is the
	# only escape hatch. Headless-safe (a ScrollContainer is a plain Control).
	_panel_scroll = ScrollContainer.new()
	_panel_scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_panel_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	_root.add_child(_panel_scroll)
	_panel_host = VBoxContainer.new()
	_panel_host.add_theme_constant_override("separation", 8)
	_panel_host.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_panel_scroll.add_child(_panel_host)

	# CRT/scanline overlay (#26) — the EXACT OpsHUD post-pass shader, screen-space, mouse-transparent
	# so it never eats clicks. Built only on a real display; visibility tracks the crt_filter setting
	# (so SETTINGS can flip it live, #27). Added LAST so it sits over the whole console.
	if _has_display():
		_scanlines = ColorRect.new()
		_scanlines.set_anchors_preset(Control.PRESET_FULL_RECT)
		_scanlines.mouse_filter = Control.MOUSE_FILTER_IGNORE
		_scanlines.material = _scanline_material()
		add_child(_scanlines)
		_apply_scanline_setting()


## Reflect the live `crt_filter` setting on the menu's own scanline overlay (#27 — the CRT toggle
## drives the very overlay you look through). On-screen-only (the overlay only exists on a display).
func _apply_scanline_setting() -> void:
	if _scanlines != null:
		_scanlines.visible = bool(profile.get_setting("crt_filter", true))


## The OpsHUD CRT post-pass shader (reused verbatim, ART_BIBLE §2/§5): a dark horizontal line every
## 3px + a soft corner vignette, screen-space over the rect. On-screen-only.
func _scanline_material() -> ShaderMaterial:
	var sh := Shader.new()
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


## Per-frame: advance the header timecode (the "● REC" recording clock, display-only) so the menu
## reads as a live feed like the in-run OpsHUD. ON-SCREEN-ONLY — set_process is only enabled on a
## real display, so this never runs headless (no test reads it; the suites stay byte-stable).
func _process(delta: float) -> void:
	_t += delta
	if _timecode_label != null:
		var secs := int(_t)
		_timecode_label.text = "%02d:%02d:%02d" % [secs / 3600, (secs / 60) % 60, secs % 60]


func _make_label(text: String, color: Color, size: int) -> Label:
	var l := Label.new()
	l.text = text
	l.add_theme_color_override("font_color", color)
	l.add_theme_font_size_override("font_size", size)
	return l


## A console button with the shared ops-console StyleBox states (#26): default/hover/focus/pressed/
## disabled, plus corner-tick chrome. Every menu row (home buttons, memorial dossiers, unlock buys,
## settings toggles, BACK) routes through here so the visual language is one place. Headless-safe —
## StyleBoxes are pure resources; no display needed to build them.
func _make_button(text: String, handler: Callable, enabled: bool = true, ui_cue: String = "select") -> Button:
	var b := Button.new()
	b.text = text
	b.custom_minimum_size = Vector2(360, 40)
	b.disabled = not enabled
	b.add_theme_font_size_override("font_size", 18)
	_style_button(b)
	if enabled:
		b.pressed.connect(handler)
		# AUDIO (W6-6): a UI cue on every menu press (UI bus). The cue is per-row so the four dead UI
		# slots (confirm/back/buy/error) actually get call sites — before this only "select" fired
		# anywhere. No-op headless and silent until real ui/*.ogg drops in (menu is never in the suites).
		b.pressed.connect(_ui_click.bind(ui_cue))
	return b


## Fire a named UI cue through the AudioDirector autoload if present (on-screen only). `cue` is one of
## the UI_SLOTS (select/confirm/back/buy/error); defaults to "select" for plain navigation rows.
func _ui_click(cue: String = "select") -> void:
	var ad := _audio_director()
	if ad != null:
		ad.play_ui(cue)


## Fire the "error" UI cue directly (used off the button path — a failed purchase / no-save Continue).
func _ui_error() -> void:
	var ad := _audio_director()
	if ad != null:
		ad.play_ui("error")


## Start (or switch) a music track through the AudioDirector autoload if present (Music bus, on-screen
## only). play_music was DEAD ON ARRIVAL before Wave 6 (zero call sites). No-op headless.
func _play_music(track: String) -> void:
	var ad := _audio_director()
	if ad != null:
		ad.play_music(track)


## Resolve the AudioDirector autoload. Guarded by is_inside_tree(): an absolute /root path only resolves
## from a node in the active tree, which the menu always is in real play (it is the current scene) but a
## headless test-instanced menu is NOT until it enters the tree — the guard keeps that case a clean no-op
## (no spurious "absolute path from outside the tree" error) instead of erroring.
func _audio_director() -> Node:
	if not is_inside_tree():
		return null
	return get_node_or_null("/root/AudioDirector")


## Apply the shared ops-console button skin to `b` for ALL interactive states (#26). `accent` tints
## the default text/border (defaults to AMBER like the in-run action buttons); disabled falls to DIM.
## Idempotent — re-callable to re-skin a row (e.g. an armed Memorial dossier). Pure-resource; headless-safe.
func _style_button(b: Button, accent: Color = Pal.AMBER) -> void:
	b.add_theme_stylebox_override("normal", _btn_stylebox("normal"))
	b.add_theme_stylebox_override("hover", _btn_stylebox("hover"))
	b.add_theme_stylebox_override("focus", _btn_stylebox("focus"))
	b.add_theme_stylebox_override("pressed", _btn_stylebox("pressed"))
	b.add_theme_stylebox_override("disabled", _btn_stylebox("disabled"))
	b.add_theme_color_override("font_color", accent)
	b.add_theme_color_override("font_hover_color", Pal.AMBER)
	b.add_theme_color_override("font_focus_color", Pal.AMBER)
	b.add_theme_color_override("font_pressed_color", Pal.FRAME_BG)   # invert: dark text on amber fill
	b.add_theme_color_override("font_disabled_color", Pal.DIM)


## The shared button StyleBox per visual state (ART_BIBLE §5 chrome panels): FRAME_BG@85% fill, a
## 1px FRAME_BORDER edge + 2px FRAME_INSET top highlight, corner ticks (expand_margin) reading as the
## camera-UI bracket marks. States re-tint the edge/fill:
##   default  — FRAME_BORDER edge, faint inset wash;
##   hover    — AMBER edge + a brighter inset top-glow;
##   focus    — AMBER edge + corner-tick expand (the bracket-tick focus tell);
##   pressed  — AMBER fill / dark text (the 1-frame invert);
##   disabled — DIM edge, no inset highlight.
func _btn_stylebox(state: String) -> StyleBoxFlat:
	var sb := StyleBoxFlat.new()
	var wash := 0.06
	var edge := Pal.FRAME_BORDER
	var fill := Color(Pal.FRAME_BG.r, Pal.FRAME_BG.g, Pal.FRAME_BG.b, 0.85)
	var top := 2
	var tick := 0
	match state:
		"hover":
			edge = Pal.AMBER
			wash = 0.14
		"focus":
			edge = Pal.AMBER
			wash = 0.10
			tick = 3   # corner-tick bracket marks pop out on focus (the keyboard/gamepad tell)
		"pressed":
			# Invert: solid AMBER fill, dark text (set via font_pressed_color in _style_button).
			fill = Pal.AMBER
			edge = Pal.AMBER
			wash = 0.0
			top = 0
		"disabled":
			edge = Pal.DIM
			wash = 0.0
			top = 0
	if state != "pressed":
		# A faint FRAME_INSET wash over the panel fill (the §5 inset top highlight), brighter on hover.
		fill = fill.lerp(Pal.FRAME_INSET, wash)
	sb.bg_color = fill
	sb.border_color = edge
	sb.set_border_width_all(1)
	sb.border_width_top = top
	sb.set_corner_radius_all(2)
	# Corner ticks: an outward expand on focus reads as the camera-UI bracket (no extra nodes).
	sb.set_expand_margin_all(tick)
	sb.content_margin_left = 12
	sb.content_margin_right = 12
	sb.content_margin_top = 6
	sb.content_margin_bottom = 6
	return sb


func _clear_panel() -> void:
	for c in _panel_host.get_children():
		c.queue_free()


## W5-8 — initial focus + keyboard/gamepad traversal. Godot's arrow/Tab navigation and Enter-to-press
## are built in, but they do NOTHING until (a) some control HAS focus and (b) the focus neighbors are
## wired (the project had zero grab_focus calls). This designates the first enabled button as the initial
## focus target (`_first_focus`) and chains the panel's button column top<->bottom (wrapping) so Up/Down
## and Tab walk it; Enter/Space fire the focused button via the engine's ui_accept. Called at the end of
## every panel build so navigation survives a home/memorial/unlocks/settings swap. The actual grab_focus
## only fires on a real display (headless never needs a live focus owner, keeping the menu-load test off
## the display path); the target + neighbor wiring are set either way, so a headless test can assert them.
func _focus_panel_column() -> void:
	var btns: Array = []
	for c in _panel_host.get_children():
		if c is Button and not (c as Button).disabled and (c as Button).focus_mode != Control.FOCUS_NONE:
			btns.append(c)
	_first_focus = null
	if btns.is_empty():
		return
	for i in range(btns.size()):
		var b: Button = btns[i]
		var nxt: Button = btns[(i + 1) % btns.size()]
		var prv: Button = btns[(i - 1 + btns.size()) % btns.size()]
		b.focus_neighbor_bottom = b.get_path_to(nxt)
		b.focus_neighbor_top = b.get_path_to(prv)
		b.focus_next = b.get_path_to(nxt)
		b.focus_previous = b.get_path_to(prv)
	_first_focus = btns[0]
	if _has_display() and _first_focus.is_inside_tree():
		_first_focus.grab_focus()


func _set_status(text: String) -> void:
	if _status_line != null:
		_status_line.text = text


# ============================ BOOT / UPLINK (#25) =============================
## The cold-start UPLINK cutscene (FLOW S1-00): the console "seizes the camera net" via a typed-line
## boot log on the comms cadence, then a one-shot "uplink established" glitch settles into HOME. Built
## as a transient full-rect overlay OVER the (already-built) menu; ON-SCREEN-ONLY (only reached when
## _has_display()). SKIPPABLE — any key/click cuts straight to HOME. Preserves the --sim auto-run: the
## run launches only after BOOT settles, so the self-play proof still plays itself to an ending.
const _BOOT_LINES := [
	"COLDSPINE // OPERATOR CONSOLE",
	"establishing uplink . . .",
	"seizing camera nodes . . .",
	"47 feeds live",
	"uplink established",
]
const _BOOT_LINE_INTERVAL := 0.42   # comms cadence between typed lines (seconds)

var _boot_log: VBoxContainer
var _boot_timer: Timer
var _boot_glitch: ColorRect
var _boot_idx: int = 0


func _start_boot() -> void:
	_booting = true
	_show_home()   # build HOME underneath so the skip-cut is instant (no rebuild flash)
	_boot = Control.new()
	_boot.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(_boot)
	# Opaque black wash so the warming console reads as a dark CRT coming up over HOME.
	var black := ColorRect.new()
	black.color = Pal.FRAME_BG
	black.set_anchors_preset(Control.PRESET_FULL_RECT)
	black.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_boot.add_child(black)
	# The one-shot chroma-split/scan-tear glitch flash (ART_BIBLE §2), hidden until "uplink established".
	_boot_glitch = ColorRect.new()
	_boot_glitch.color = Color(Pal.CYAN.r, Pal.CYAN.g, Pal.CYAN.b, 0.0)
	_boot_glitch.set_anchors_preset(Control.PRESET_FULL_RECT)
	_boot_glitch.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_boot.add_child(_boot_glitch)
	# The typed boot-log column (AMBER mono), center-left.
	var pad := MarginContainer.new()
	pad.set_anchors_preset(Control.PRESET_FULL_RECT)
	pad.add_theme_constant_override("margin_left", 64)
	pad.add_theme_constant_override("margin_top", 120)
	_boot.add_child(pad)
	_boot_log = VBoxContainer.new()
	_boot_log.add_theme_constant_override("separation", 6)
	pad.add_child(_boot_log)
	# A DIM "new operator profile initialized" tell when the load fell back to a fresh profile
	# (FLOW S1-00 empty/error — never an error wall, SaveSystem never throws).
	if not SaveSystem.has_profile():
		_boot_log.add_child(_make_label("NEW OPERATOR PROFILE INITIALIZED", Pal.DIM, 13))
	# Re-skin the scanline overlay onto the boot screen (sits over _boot via tree order? keep simple:
	# the existing _scanlines is already a sibling added before _boot, so move it to the top).
	if _scanlines != null:
		move_child(_scanlines, get_child_count() - 1)
	_boot_idx = 0
	_boot_timer = Timer.new()
	_boot_timer.one_shot = false
	_boot_timer.wait_time = _BOOT_LINE_INTERVAL
	_boot_timer.timeout.connect(_boot_tick)
	add_child(_boot_timer)
	_boot_timer.start()


## Append the next boot-log line on the comms cadence; the LAST line ("uplink established") fires the
## one-shot glitch then settles into HOME. On-screen-only.
func _boot_tick() -> void:
	if not _booting:
		return
	if _boot_idx >= _BOOT_LINES.size():
		_finish_boot()
		return
	var line: String = _BOOT_LINES[_boot_idx]
	var is_last := _boot_idx == _BOOT_LINES.size() - 1
	var col: Color = Pal.AMBER if not is_last else Pal.CYAN
	_boot_log.add_child(_make_label("> " + line, col, 15))
	_boot_idx += 1
	if is_last:
		_boot_glitch_flash()
		# Hold the "established" line a beat, then settle.
		_boot_timer.stop()
		var done := get_tree().create_timer(0.55)
		done.timeout.connect(_finish_boot)


## The one-shot "uplink established" glitch (ART_BIBLE §2 idiom): a brief chroma wash that fades out.
## On-screen-only — a couple of alpha lerps via a tween; never headless.
func _boot_glitch_flash() -> void:
	if _boot_glitch == null:
		return
	_boot_glitch.color.a = 0.5
	var tw := create_tween()
	tw.tween_property(_boot_glitch, "color:a", 0.0, 0.45)


## Tear down the boot cutscene and reveal HOME; THEN honor --sim (the self-play launch waits for
## boot to settle so the proof always plays). Idempotent — a skip and the auto-complete can't
## double-fire. On-screen-only.
func _finish_boot() -> void:
	if not _booting:
		return
	_booting = false
	if _boot_timer != null:
		_boot_timer.stop()
		_boot_timer.queue_free()
		_boot_timer = null
	if _boot != null:
		_boot.queue_free()
		_boot = null
	# HOME was already built under the boot wash; just refresh its telemetry and proceed.
	_show_home()
	_maybe_autostart_sim()


## Any key / click while booting -> SKIP straight to HOME (no half-state, FLOW S1-00). Once
## settled, ESC/ui_cancel from any SUB-PANEL returns to HOME (W1-2 — no dead-end panels; ESC
## NEVER quits the app). On-screen-only (headless never gets _input).
func _input(event: InputEvent) -> void:
	if _booting:
		var skip := false
		if event is InputEventKey and event.pressed and not event.echo:
			skip = true
		elif event is InputEventMouseButton and event.pressed:
			skip = true
		elif event is InputEventScreenTouch and event.pressed:
			skip = true
		if skip:
			get_viewport().set_input_as_handled()
			_finish_boot()
		return
	var esc := event.is_action_pressed("ui_cancel")
	if not esc and event is InputEventKey and event.pressed and not event.echo:
		esc = event.keycode == KEY_ESCAPE
	if esc and _handle_cancel():
		get_viewport().set_input_as_handled()


## The ESC/ui_cancel policy (W1-2): from any sub-panel (memorial/unlocks/settings) return to
## HOME; on HOME it is a deliberate no-op (never quit the app from a keypress). Returns true
## when it navigated. Display-independent so menu_smoke can assert the BACK-reachability guard.
func _handle_cancel() -> bool:
	if _active_panel == "home":
		return false
	_ui_click("back")   # W6-6: ESC-to-home is a "back" navigation cue too
	_show_home()
	return true


# ============================ HOME view =======================================
func _show_home() -> void:
	_active_panel = "home"
	_clear_panel()
	_set_status("META-CURRENCY: %d   |   UNLOCKS: %d   |   FALLEN: %d   |   RUNS: %d  WINS: %d"
		% [profile.meta_currency, profile.unlocked_content.size(), Legacy.available(profile).size(),
			int(profile.stats.get("runs", 0)), int(profile.stats.get("wins", 0))])
	_panel_host.add_child(_make_button("NEW RUN", _on_new_run, true, "confirm"))
	# CONTINUE (FLOW S1-01): three states, gated on a resumable AND schema-compatible save (W7-3).
	#   compatible save -> enabled "CONTINUE";
	#   no save         -> disabled "CONTINUE — NO SAVE" (empty state);
	#   incompatible    -> disabled "CONTINUE — SAVE INCOMPATIBLE" (a save from another build's schema:
	#                      NEVER a silent resume into a divergent run) + a DIM one-line explanation.
	var has_save: bool = SaveSystem.has_run_save()
	var save_ok: bool = SaveSystem.run_save_compatible()
	var cont_label := "CONTINUE"
	if not has_save:
		cont_label = "CONTINUE — NO SAVE"
	elif not save_ok:
		cont_label = "CONTINUE — SAVE INCOMPATIBLE"
	_panel_host.add_child(_make_button(cont_label, _on_continue, save_ok, "confirm"))
	if has_save and not save_ok:
		_panel_host.add_child(_make_label(
			"Saved run is from an incompatible version — start a NEW RUN.", Pal.DIM, 13))
	_panel_host.add_child(_make_button("MEMORIAL  (Legacy)", _show_memorial))
	_panel_host.add_child(_make_button("RUN HISTORY", _show_history))
	_panel_host.add_child(_make_button("UNLOCKS", _show_unlocks))
	_panel_host.add_child(_make_button("SETTINGS", _show_settings))
	_panel_host.add_child(_make_button("ASCII POC", _on_ascii_poc))
	_panel_host.add_child(_make_button("QUIT", _on_quit))
	if _chosen_legacy_id != "":
		var p := Legacy.inherit(profile, _chosen_legacy_id)
		if not p.is_empty():
			_panel_host.add_child(_make_label(
				"LEGACY ARMED: %s '%s' from %s" % [String(p.get("kind","")), String(p.get("id","")), String(p.get("from",""))],
				Pal.AMBER, 14))
	_focus_panel_column()


# ============================ NEW RUN / CONTINUE ==============================
## Start a fresh run: stage the handoff (unlocked content + the chosen Legacy), clear any stale
## resume save, then launch run.tscn. The owned car ids gate the line ADDITIVELY (only catalog
## setpieces gate on ownership — RunGenerator._is_unlocked); the armed Legacy is staged by id +
## payload but NOT burned here — the controller marks it inherited only at BREACH finalize, so
## an ESC-abandoned draft leaves the profile untouched (W1-7, FLOW "safe until BREACH").
func _on_new_run() -> void:
	var car_ids: Array = Unlocks.unlocked_car_ids(profile)
	MenuHandoff.unlocked_car_ids = car_ids
	MenuHandoff.unlocked_class_ids = Unlocks.unlocked_class_ids(profile)
	MenuHandoff.legacy_payload = {}
	MenuHandoff.legacy_id = ""
	if _chosen_legacy_id != "":
		var payload := Legacy.inherit(profile, _chosen_legacy_id)
		if not payload.is_empty():
			MenuHandoff.legacy_payload = payload
			MenuHandoff.legacy_id = _chosen_legacy_id
	MenuHandoff.resume_run = null
	MenuHandoff.settings = profile.settings.duplicate(true)
	# W1-5: a real player launch rolls a FRESH run seed (app-layer entropy); headless + --sim
	# keep -1 so the controller's DEFAULT_SEED path stays byte-stable for every suite/proof.
	MenuHandoff.run_seed = pick_run_seed(_has_display())
	_goto(RUN_SCENE)


func _on_continue() -> void:
	var run = SaveSystem.load_run()
	if run == null:
		_set_status("NO RESUMABLE RUN — start a new run.")
		_ui_error()   # W6-6: the "error" UI slot finally has a call site
		return
	MenuHandoff.resume_run = run
	MenuHandoff.unlocked_car_ids = Unlocks.unlocked_car_ids(profile)
	MenuHandoff.unlocked_class_ids = Unlocks.unlocked_class_ids(profile)
	MenuHandoff.settings = profile.settings.duplicate(true)
	_goto(RUN_SCENE)


# ============================ MEMORIAL view ===================================
## The fallen, and a one-pick Legacy selector (§7.4). Picking arms a single item/trait to inherit
## into the next run; it does NOT resurrect anyone (Legacy.inherit yields a payload, never a unit).
func _show_memorial() -> void:
	_active_panel = "memorial"
	_clear_panel()
	_panel_host.add_child(_make_label("MEMORIAL — the fallen (pick ONE Legacy to carry forward)", Pal.AMBER, 20))
	var fallen: Array = Legacy.available(profile)
	if fallen.is_empty():
		_panel_host.add_child(_make_label("No fallen yet. Their legacies will appear here.", Pal.DIM, 15))
	for hero in fallen:
		var lid := String(hero.get("legacy_id", ""))
		var payload := Legacy.inherit(profile, lid)
		var desc := "nothing to pass on"
		var armable: bool = not payload.is_empty()
		if armable:
			desc = "%s: %s" % [String(payload.get("kind","")), String(payload.get("id",""))]
		var armed: bool = lid == _chosen_legacy_id
		var marker := "  [ARMED]" if armed else ""
		var arche := String(hero.get("archetype",""))
		var line := "%s (%s) — %s%s" % [String(hero.get("name","?")), arche, desc, marker]
		# A hero with nothing to pass on is a non-armable DIM dossier (disabled); an armed pick wears
		# a persistent AMBER border (the one genuinely persistent selected state in the segment, #26).
		# W5-16: the row is LEFT-aligned + indented to make room for the enshrine glyph at its left edge.
		var row := _make_button("     " + line, _on_pick_legacy.bind(lid), armable)
		row.alignment = HORIZONTAL_ALIGNMENT_LEFT
		if armable:
			_style_button(row, Pal.AMBER if armed else Pal.CYAN)
			if armed:
				row.add_theme_stylebox_override("normal", _btn_stylebox("focus"))   # persistent selected tell
		# W5-16: an archetype glyph inside a FAC_NEUTRAL ring, added as a CHILD of the row button — the
		# row stays a DIRECT child of _panel_host, so _focus_panel_column still finds it and the W5-8
		# keyboard traversal is untouched (no container wrap that would hide the button from the column).
		var glyph := _enshrine_glyph(arche)
		glyph.position = Vector2(8, 6)
		row.add_child(glyph)
		_panel_host.add_child(row)
	_panel_host.add_child(_make_button("CLEAR LEGACY", _on_clear_legacy, true, "back"))
	_panel_host.add_child(_make_button("< BACK", _show_home, true, "back"))
	_focus_panel_column()


## Archetype -> a single-char memorial glyph (W5-16). Distinct per class; steward reads as the medic
## cross, firebrand the torch initial. Unknown/blank falls to the capitalized initial (never blank).
const _ARCHETYPE_GLYPH := {
	"bruiser": "B", "marksman": "M", "saboteur": "S", "steward": "+", "firebrand": "F",
}


func _archetype_glyph(archetype: String) -> String:
	var a := archetype.to_lower()
	if _ARCHETYPE_GLYPH.has(a):
		return String(_ARCHETYPE_GLYPH[a])
	return a.substr(0, 1).to_upper() if a != "" else "?"


## The enshrine glyph node (W5-16): a small FAC_NEUTRAL ring holding the archetype glyph. Built as a
## Panel (the ring, via a rounded StyleBox) + a centered Label (the glyph) so it is pure-resource and
## headless-safe. Named "enshrine_glyph" so a test can find it on the built row. Click-through
## (MOUSE_FILTER_IGNORE) so it never eats the row button's press.
func _enshrine_glyph(archetype: String) -> Control:
	var box := Panel.new()
	box.name = "enshrine_glyph"
	box.custom_minimum_size = Vector2(28, 28)
	box.size = Vector2(28, 28)
	box.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(Pal.FAC_NEUTRAL.r, Pal.FAC_NEUTRAL.g, Pal.FAC_NEUTRAL.b, 0.14)
	sb.border_color = Pal.FAC_NEUTRAL           # the FAC_NEUTRAL ring (§3.5 neutral faction color)
	sb.set_border_width_all(2)
	sb.set_corner_radius_all(14)                # full round -> reads as a ring
	box.add_theme_stylebox_override("panel", sb)
	var g := _make_label(_archetype_glyph(archetype), Pal.FAC_NEUTRAL, 15)
	g.mouse_filter = Control.MOUSE_FILTER_IGNORE
	g.set_anchors_preset(Control.PRESET_FULL_RECT)
	g.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	g.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	box.add_child(g)
	return box


func _on_pick_legacy(legacy_id: String) -> void:
	_chosen_legacy_id = legacy_id
	_show_memorial()


func _on_clear_legacy() -> void:
	_chosen_legacy_id = ""
	_show_memorial()


# ============================ RUN HISTORY view (W7-2) =========================
## The roguelite run summary + history (W7-2): the BEST ENDING reached (tracked in profile.stats but
## surfaced nowhere before this) + the last N runs from the profile run-log (record_run, appended at
## finalize). Read-only records render as DIM labels so they never disturb the W5-8 keyboard column
## (the panel's only focusable control is < BACK). Consumes MetaProfile — never mutates it.
func _show_history() -> void:
	_active_panel = "history"
	_clear_panel()
	_panel_host.add_child(_make_label("RUN HISTORY", Pal.AMBER, 20))
	var best: int = int(profile.stats.get("best_ending", -1))
	var best_txt := ("BEST ENDING — %s" % _ending_label(best)) if best >= 0 else "BEST ENDING — none yet"
	_panel_host.add_child(_make_label(best_txt, Pal.CYAN, 16))
	_panel_host.add_child(_make_label(
		"LIFETIME — runs %d   ·   wins %d   ·   fallen %d"
		% [int(profile.stats.get("runs", 0)), int(profile.stats.get("wins", 0)), int(profile.stats.get("fallen", 0))],
		Pal.DIM, 14))
	var recent: Array = profile.recent_runs(12)
	if recent.is_empty():
		_panel_host.add_child(_make_label("No runs recorded yet — breach a run to write the log.", Pal.DIM, 15))
	else:
		_panel_host.add_child(_make_label("RECENT RUNS (newest first)", Pal.DIM, 13))
		var n: int = recent.size()
		for i in range(n):
			var r: Dictionary = recent[i]
			var verdict := "WIN" if bool(r.get("won", false)) else "LOSS"
			var line := "%2d.  %-16s  ·  cars %d  ·  crew %d/%d  ·  order %d  [%s]" % [
				n - i, _ending_label(int(r.get("ending", -1))),
				int(r.get("cars", 0)), int(r.get("survivors", 0)), int(r.get("squad", 0)),
				int(r.get("order", 0)), verdict]
			_panel_host.add_child(_make_label(line, Pal.AMBER if bool(r.get("won", false)) else Pal.DIM, 13))
	_panel_host.add_child(_make_button("< BACK", _show_home, true, "back"))
	_focus_panel_column()


## Humanize an EndingId for the history panel (mirrors RunController._ending_name — kept local so the
## menu never imports the run controller). "—" for a no-run/unresolved sentinel.
func _ending_label(e: int) -> String:
	match e:
		E.EndingId.LOSS:         return "LOSS"
		E.EndingId.HARD_STOP:    return "HARD STOP"
		E.EndingId.SEIZE_ENGINE: return "SEIZE THE ENGINE"
		E.EndingId.PYRRHIC:      return "PYRRHIC VICTORY"
		E.EndingId.LIBERATION:   return "LIBERATION"
		_:                       return "—"


# ============================ UNLOCKS view (#27) =============================
## Spend meta-currency on permanent unlocks (§14). Each catalog entry reads its visual state at a
## glance (FLOW S1-03): OWNED = a DIM stamp; AFFORDABLE = an active buy with an AMBER price; CAN'T
## AFFORD = a DIM, disabled row with a DIM price (the price-color affordance). A purchase persists
## the profile immediately and flashes a brief success tell before the re-render.
var _purchase_flash_id: String = ""   # the id just bought (drives the one-shot success tint)
var _tips_reset_flash: bool = false   # one-shot "tutorial tips reset ✓" confirmation on the reset button


func _show_unlocks() -> void:
	_active_panel = "unlocks"
	_clear_panel()
	_panel_host.add_child(_make_label("UNLOCKS — meta-currency: %d" % profile.meta_currency, Pal.AMBER, 20))
	for id in Unlocks.catalog_ids():
		var e := Unlocks.entry(id)
		var owned: bool = profile.is_unlocked(id)
		var c: int = int(e.get("cost", 0))
		var nm := String(e.get("name", id))
		if owned:
			# OWNED stamp: a static DIM label (not a button). A just-bought row flashes AMBER once.
			var flashed: bool = id == _purchase_flash_id
			var stamp := _make_label("%s  —  ✓ OWNED" % nm, Pal.AMBER if flashed else Pal.DIM, 15)
			_panel_host.add_child(stamp)
			if flashed:
				_flash_label(stamp)
		else:
			var afford: bool = profile.meta_currency >= c
			# Price-color affordance: AMBER price when affordable, DIM when not (#27).
			var price_tag := "[%d]" % c
			var label := "%s  %s" % [nm, price_tag]
			var row := _make_button(label, _on_buy.bind(id), afford, "buy")
			# Affordable buys read CYAN name; unaffordable fall to the DIM disabled skin.
			_style_button(row, Pal.CYAN if afford else Pal.DIM)
			_panel_host.add_child(row)
	_purchase_flash_id = ""   # consume the one-shot flash
	_panel_host.add_child(_make_button("< BACK", _show_home, true, "back"))
	_focus_panel_column()


## Fade an AMBER success stamp back toward DIM (the brief purchase-success tell, #27). On-screen-only
## — gated behind _has_display() so the headless purchase logic (menu_smoke) never spins a tween.
func _flash_label(l: Label) -> void:
	if not _has_display():
		return
	l.modulate.a = 1.0
	var tw := create_tween()
	tw.tween_property(l, "modulate:a", 0.55, 0.6)


func _on_buy(id: String) -> void:
	if Unlocks.purchase(profile, id):
		SaveSystem.save_profile(profile)
		_purchase_flash_id = id   # arm the one-shot success flash for the re-render
	else:
		_ui_error()   # W6-6: an unaffordable/failed purchase plays the "error" slot
	_show_unlocks()


# ============================ SETTINGS view (#27) ============================
## Options. The in-car-fog row EXPOSES the owner-flagged toggle (E1.4) — it surfaces the current
## value and lets the player flip it for their own session, but its DEFAULT is unchanged
## (MetaProfile.DEFAULT_SETTINGS.in_car_fog mirrors SetpieceFog.IN_CAR_FOG_ENABLED = true). We do
## not editorialize the default; we only expose the switch.
##
## Volumes are now DRAGGABLE Sliders (#27) keeping the int value model — see _slider_row. The CRT
## toggle drives the menu's OWN scanline overlay live (_on_toggle re-applies the setting).
func _show_settings() -> void:
	_active_panel = "settings"
	_clear_panel()
	_panel_host.add_child(_make_label("SETTINGS", Pal.AMBER, 20))
	_panel_host.add_child(_toggle_row("In-car fog (operator vision limit)", "in_car_fog"))
	_panel_host.add_child(_toggle_row("CRT / scanline filter", "crt_filter"))
	_panel_host.add_child(_toggle_row("Confirm before committing a move", "confirm_moves"))
	# Combat onboarding (combat-ux #7): the global tips switch + a "reset tutorial" that clears the
	# seen-set so every tip teaches again. The reset button confirms with a one-shot label flash.
	_panel_host.add_child(_toggle_row("Combat tips (onboarding)", "tips_enabled"))
	var reset_label: String = "Tutorial tips reset ✓" if _tips_reset_flash else "Reset tutorial tips"
	var reset_btn := _make_button(reset_label, _on_reset_tips)
	if _tips_reset_flash:
		_style_button(reset_btn, Pal.AMBER)
	_panel_host.add_child(reset_btn)
	_tips_reset_flash = false   # consume the one-shot confirmation
	_panel_host.add_child(_slider_row("SFX volume", "sfx_volume"))
	_panel_host.add_child(_slider_row("Music volume", "music_volume"))
	# DISPLAY (W6-8): the standard-desktop toggles the settings menu was missing. Fullscreen defaults
	# OFF (windowed); VSync defaults ON (Godot's own default) — the explicit default keeps the row's
	# state honest before the key is ever written. Both apply via DisplayServer on toggle + at boot.
	_panel_host.add_child(_toggle_row("Fullscreen", "fullscreen", false))
	_panel_host.add_child(_toggle_row("VSync", "vsync", true))
	# ACCESSIBILITY (W6-9 / W6-10). Reduced flash damps the flash-heavy combat FX (hit flashes,
	# explosions, electrify, boot glitch) for photosensitivity; the renderer reads the flag from the
	# session settings (see the FLAG in the wave report). Colorblind mode selects a palette variant.
	_panel_host.add_child(_toggle_row("Reduced flash (photosensitivity)", "reduced_flash", false))
	_panel_host.add_child(_cblind_row("Colorblind mode", "colorblind_mode"))
	_panel_host.add_child(_make_button("< BACK", _show_home, true, "back"))
	_focus_panel_column()


func _toggle_row(label: String, key: String, default_on: bool = false) -> Button:
	var on: bool = bool(profile.get_setting(key, default_on))
	# ON reads AMBER, OFF reads DIM — the value's color IS the state (the toggle affordance, #27).
	var b := _make_button("%s : %s" % [label, ("ON" if on else "OFF")], _on_toggle.bind(key, default_on))
	_style_button(b, Pal.AMBER if on else Pal.DIM)
	return b


## `default_on` is the value used when the key is not yet in the profile (or its DEFAULT_SETTINGS) — it
## keeps a row like VSync reading ON before the first toggle writes it. For keys that already live in
## MetaProfile.DEFAULT_SETTINGS (fog/crt/confirm/tips) it is inert (get_setting resolves them first).
func _on_toggle(key: String, default_on: bool = false) -> void:
	profile.set_setting(key, not bool(profile.get_setting(key, default_on)))
	SaveSystem.save_profile(profile)
	# The CRT toggle takes effect LIVE on the menu's own overlay (#27).
	if key == "crt_filter":
		_apply_scanline_setting()
	# W6-8: fullscreen / vsync take effect immediately via the DisplayServer (on-screen only).
	elif key == "fullscreen" or key == "vsync":
		_apply_display_setting(key)
	_show_settings()


# ---- W6-10: colorblind mode (a 4-state cycle, not a boolean) -------------------
const _CBLIND_NAMES := ["Off", "Deuteranopia", "Protanopia", "Tritanopia"]


## A colorblind-mode row: cycles 0 (off) -> 1 -> 2 -> 3 -> 0. The mode selects a render palette variant
## (§15 "palette variants") — the renderer read is FLAGGED in the wave report (render/palette.gd is out
## of this lane). The value persists + flows to the run via MenuHandoff.settings (profile.settings dup).
func _cblind_row(label: String, key: String) -> Button:
	var mode: int = clampi(int(profile.get_setting(key, 0)), 0, _CBLIND_NAMES.size() - 1)
	var b := _make_button("%s : %s" % [label, _CBLIND_NAMES[mode]], _on_cblind_cycle.bind(key))
	_style_button(b, Pal.AMBER if mode > 0 else Pal.DIM)
	return b


func _on_cblind_cycle(key: String) -> void:
	var mode: int = clampi(int(profile.get_setting(key, 0)), 0, _CBLIND_NAMES.size() - 1)
	mode = (mode + 1) % _CBLIND_NAMES.size()
	profile.set_setting(key, mode)
	SaveSystem.save_profile(profile)
	_show_settings()


# ---- W6-8: fullscreen / vsync apply --------------------------------------------
# Test hook (headless-observable): the last {key, mode} _apply_display_setting resolved. The literal
# DisplayServer call is on-screen-only (gated behind _has_display), but the mode DECISION is computed
# and recorded either way, so a headless test can prove the toggle targets the right window API value.
var _last_display_apply: Dictionary = {}


## Resolve + apply a display setting to the window (W6-8). Fullscreen -> WINDOW_MODE_FULLSCREEN/WINDOWED;
## vsync -> VSYNC_ENABLED/DISABLED. The chosen mode is recorded in `_last_display_apply` before the call,
## and the DisplayServer call itself only fires on a real display (headless has no window to mode-switch).
func _apply_display_setting(key: String) -> void:
	if key == "fullscreen":
		var on: bool = bool(profile.get_setting("fullscreen", false))
		var mode: int = DisplayServer.WINDOW_MODE_FULLSCREEN if on else DisplayServer.WINDOW_MODE_WINDOWED
		_last_display_apply = {"key": key, "mode": mode}
		if _has_display():
			DisplayServer.window_set_mode(mode)
	elif key == "vsync":
		var on: bool = bool(profile.get_setting("vsync", true))
		var mode: int = DisplayServer.VSYNC_ENABLED if on else DisplayServer.VSYNC_DISABLED
		_last_display_apply = {"key": key, "mode": mode}
		if _has_display():
			DisplayServer.window_set_vsync_mode(mode)


## "Reset tutorial tips" (combat-ux #7): clear the seen-set so the onboarding tips teach again next
## combat, persist, and re-render Settings with a one-shot confirmation flash.
func _on_reset_tips() -> void:
	profile.reset_tips()
	SaveSystem.save_profile(profile)
	_tips_reset_flash = true
	_show_settings()


## A volume row as a REAL draggable Slider (#27), keeping the INT value model + headless-safety. The
## slider is a discrete 0..100 step-5 control; on `value_changed` we coerce back to int and persist
## via set_setting + save_profile (the exact int contract the tap-cycle used). A CYAN % readout
## tracks the thumb. Built code-only; a Slider instances fine headless, but the menu is never
## instanced headless anyway, so this stays off the byte-stable path.
func _slider_row(label: String, key: String) -> Control:
	var v: int = clampi(int(profile.get_setting(key, 100)), 0, 100)
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 12)
	row.custom_minimum_size = Vector2(360, 36)
	var name_l := _make_label(label, Pal.CYAN, 16)
	name_l.custom_minimum_size = Vector2(220, 0)
	name_l.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	row.add_child(name_l)
	var slider := HSlider.new()
	slider.min_value = 0
	slider.max_value = 100
	slider.step = 5
	slider.value = v
	slider.custom_minimum_size = Vector2(220, 28)
	slider.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	# AMBER fill to value, CYAN thumb, FRAME_BORDER track (the §5/ FLOW S1-04 slider tokens).
	_style_slider(slider)
	row.add_child(slider)
	var val_l := _make_label("%d%%" % v, Pal.AMBER, 16)
	val_l.custom_minimum_size = Vector2(56, 0)
	val_l.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	row.add_child(val_l)
	# Drag-to-set: coerce to int, update the readout live, persist on change. KEEPS the int model.
	slider.value_changed.connect(func(nv: float): _on_slider_changed(key, int(round(nv)), val_l))
	return row


## Persist a slider's new INT value (#27). Coerced to int (the existing model), clamped 0..100,
## saved immediately — the same set_setting + save_profile contract the tap-cycle used. The live %
## readout follows the thumb. Headless-safe (no display needed; pure model write).
func _on_slider_changed(key: String, value: int, readout: Label) -> void:
	var v: int = clampi(value, 0, 100)
	profile.set_setting(key, v)
	SaveSystem.save_profile(profile)
	if readout != null:
		readout.text = "%d%%" % v
	# AUDIO (release-readiness #4): drive the live bus volume now that the AudioDirector autoload +
	# Master->Music/SFX/UI bus layout exist. set_volume no-ops headless, so this stays byte-stable in
	# the suites; on a real display the slider changes loudness immediately. Routed through the guarded
	# _audio_director() (W6-6) so a not-in-tree test-instanced menu no-ops cleanly instead of erroring.
	var ad := _audio_director()
	if ad != null:
		ad.set_volume(key, v)


## Skin an HSlider to the ops console (#27): a dark FRAME_BG track, an AMBER grabber-area fill, a
## CYAN thumb. Pure StyleBox resources — headless-safe.
func _style_slider(slider: HSlider) -> void:
	var track := StyleBoxFlat.new()
	track.bg_color = Color(Pal.FRAME_BG.r, Pal.FRAME_BG.g, Pal.FRAME_BG.b, 0.9)
	track.border_color = Pal.FRAME_BORDER
	track.set_border_width_all(1)
	track.set_corner_radius_all(2)
	track.content_margin_top = 6
	track.content_margin_bottom = 6
	slider.add_theme_stylebox_override("slider", track)
	var fill := StyleBoxFlat.new()
	fill.bg_color = Color(Pal.AMBER.r, Pal.AMBER.g, Pal.AMBER.b, 0.55)
	fill.set_corner_radius_all(2)
	fill.content_margin_top = 6
	fill.content_margin_bottom = 6
	slider.add_theme_stylebox_override("grabber_area", fill)
	slider.add_theme_stylebox_override("grabber_area_highlight", fill)
	# The thumb: a small CYAN square drawn via a StyleBox (no texture needed).
	var thumb := StyleBoxFlat.new()
	thumb.bg_color = Pal.CYAN
	thumb.set_corner_radius_all(3)
	thumb.content_margin_left = 7
	thumb.content_margin_right = 7
	thumb.content_margin_top = 10
	thumb.content_margin_bottom = 10
	slider.add_theme_stylebox_override("grabber", thumb)
	slider.add_theme_stylebox_override("grabber_highlight", thumb)


# ============================ misc actions ====================================
func _on_ascii_poc() -> void:
	_goto(ASCII_SCENE)


func _on_quit() -> void:
	get_tree().quit()


## Change scene safely. No-op-safe headless: when the menu is instanced directly into the tree by a
## test (no `current_scene` set), a scene change is meaningless and would error on the deferred swap,
## so we stage the handoff (already done by the caller) and skip the switch. The normal launch
## (main_scene -> menu.tscn) always has a current_scene, so live play is unaffected.
func _goto(scene_path: String) -> void:
	if not ResourceLoader.exists(scene_path):
		_set_status("MISSING SCENE: %s" % scene_path)
		return
	if not is_inside_tree():
		return   # test harness (_initialize): no live tree pointer — handoff is staged, swap is a no-op
	var tree := get_tree()
	if tree == null or tree.current_scene == null:
		return   # headless/test harness: handoff is staged, the scene swap is a no-op
	tree.change_scene_to_file(scene_path)
