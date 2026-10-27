class_name RunScreens
extends CanvasLayer
## Task #11 — the per-car-type screens (Draft / Shop / Workshop / Bourgeois / Recruit / Event /
## Rest / Ending). Minimal but functional panels that surface the choice in the ops-console
## look (ART_BIBLE §2/§5 chrome + §3 color language). They READ a RunState and present what the
## run is doing; the RunController drives the REAL RunState rails (collect_reward / market_buy /
## workshop_upgrade / resolve_bourgeois / rest_heal / recruitment), so a screen is the visual
## surface of an already-authoritative decision, never a second source of truth.
##
## On a real handset these become tappable choice panels; for this integration pass they render
## the car, its options, and the chosen outcome (the controller's default) so the on-screen build
## visibly moves through every car type. They are no-ops headless (the controller never builds
## them). CanvasLayer above the CarView, below the OpsHUD frame.

const Pal = preload("res://render/palette.gd")
const E = preload("res://core/sim_enums.gd")

## Interactive DRAFT surface signals (S2 — DRAFT_VETTING / BREACH_CONFIRM). The RunController wires
## these exactly like OpsHUD.action_pressed: a tap on a candidate card / control button routes
## straight to the real Draft API (take/decline/stop) + the breach launch. On-screen-only — the
## headless draft path (_run_draft auto-pick) never instances RunScreens, so these never fire in
## the test suites (byte-stability of the auto path is preserved).
signal draft_take(idx: int)        # TAKE the selected candidate (draft.take(idx))
signal draft_decline()             # DECLINE this round (draft.decline())
signal draft_breach()              # STOP & BREACH (draft.stop() -> BREACH_CONFIRM); enabled at picks>=1
signal draft_auto()                # AUTO/QUICK-DRAFT this round (controller's deterministic _best_draft_pick)
signal breach_go()                 # BREACH — GO on the confirm overlay (launch the run)
signal breach_back()               # BACK on the confirm overlay (back to vetting, if not finalized)

## Interactive ECONOMY-CAR surface signals (S3 — SHOP / WORKSHOP / BOURGEOIS / RECRUIT / EVENT /
## REST). ONE reusable choice panel emits these: a FIRST tap on an OPTION ROW selects it (preview
## the consequence), a SECOND tap on the SAME row (or a CONFIRM affordance) commits it, and the
## LEAVE/back affordance exits with the safe default. The RunController wires these exactly like the
## draft signals — each handler records the operator's choice; the async per-car phase consumes it
## and drives the REAL RunState rail. On-screen-only: headless never instances RunScreens, so the
## byte-stable auto-default _do_* path is untouched.
signal choice_select(screen: String, option: String)   # FIRST tap — preview this option
signal choice_commit(screen: String, option: String)   # SECOND tap / CONFIRM — fire the rail
signal choice_leave(screen: String)                     # [ LEAVE ] / ESC — resolve with the safe default

## Interactive LEVEL-UP overlay signals (S3-LEVELUP; Batch 5). The ABILITY-CARD modal emits these:
## a FIRST tap on a card selects it (highlight + full blurb), a SECOND tap on the SAME card (or
## CONFIRM) picks it -> the controller calls Leveling.choose_ability + advances the queue. On-screen-
## only — headless never instances RunScreens, so the byte-stable run loop never raises this overlay.
signal levelup_select(ability_id: String)   # FIRST tap — preview this ability
signal levelup_pick(ability_id: String)      # SECOND tap / CONFIRM — apply the specialization

## ABANDON-RUN confirm overlay (combat-ux #4). ESC in a run no longer nukes it instantly: this
## two-choice guard offers SAVE & EXIT (progress is already checkpointed between cars) vs KEEP
## FIGHTING. On-screen-only — headless never raises it. The controller wires these like breach_go/back.
signal abandon_save_exit()   # [ SAVE & EXIT ] — persist + return to the console
signal abandon_keep()        # [ KEEP FIGHTING ] — dismiss, stay in the run

## DEPLOY picker (combat-ux #6 / balance-ai #6). Before a combat car with more living squad than
## the 3 spawn tiles, the operator picks WHO deploys. A row tap toggles a member in/out; COMMIT
## fires once exactly N are selected. On-screen-only — the headless auto-pick (top-3 by rank) never
## raises this. The controller owns the selection set + drives the real _place_squad off commit.
signal deploy_toggle(instance_id: int)   # tap a member row — toggle deploy/bench
signal deploy_commit()                   # [ DEPLOY ] — lock the selected N and enter the car

var abandon_overlay: Panel = null
var _abandon_wash: ColorRect = null

var deploy_root: Control = null
var deploy_rows: VBoxContainer = null
var deploy_footer: Label = null
var deploy_commit_btn: Button = null

var panel: Panel
var title_label: Label
var body_label: RichTextLabel
var prompt_label: Label   # actionable hint on the sticky ending panel ("[ ENTER / CLICK ] …")
var _auto_dismiss: float = 0.0

# --- ENDING TONE WASH (S6-1). A full-screen ColorRect behind the ending card, tinted to the
# ending's tone color at a low opacity (LOSS reads as an ALERT_RED alarm; the wins read CYAN/AMBER
# whole-or-bittersweet). Hidden until show_ending arms it; hide_screen clears it. On-screen-only —
# headless never builds the surface, so the tone math has no effect there. ---
var ending_wash: ColorRect

# --- interactive DRAFT surface (S2). Built lazily on first show_draft_interactive; hidden until
# then. A full-bleed takeover under the OpsHUD frame: risk dial + up to 3 candidate cards + a
# control bar + the cell-roster strip, plus the centered BREACH_CONFIRM overlay. ---
var draft_root: Control
var dial_label: Label
var dial_bar_lit: ColorRect           # the lit payout segment (grows toward fewer picks)
var dial_caption: Label
var legacy_banner: Label
var card_row: HBoxContainer
var roster_row: HBoxContainer
var ctl_take: Button
var ctl_decline: Button
var ctl_breach: Button
var ctl_auto: Button
var draft_status_label: Label         # round / "DRAFT LOCKED" state line
var _selected_idx: int = -1           # the previewed (first-tap) candidate, -1 = none
var _card_buttons: Array = []         # the 3 selectable candidate Buttons (index-aligned to choices)

# --- BREACH_CONFIRM overlay (S2) ---
var breach_overlay: Panel
var breach_body: RichTextLabel
var breach_go_btn: Button
var breach_back_btn: Button
var breach_locked_label: Label

# --- interactive ECONOMY-CHOICE surface (S3). Built lazily on first show_*_choices; hidden until
# then. A full-bleed takeover (like the draft) under the OpsHUD frame: a header + diegetic blurb, a
# DOSSIER/TRIAGE info column (RECRUIT dossier card / REST triage list), a column of OPTION ROWs each
# with a label, a cost/consequence chip + a DELTA CHIP on select, a footer (ON HAND currency) and a
# [ LEAVE ] affordance. Reused across all 6 economy car types — the controller passes the screen id,
# the option specs, and the footer; this surface only renders + emits choice signals. ---
var econ_root: Control
var econ_header: Label
var econ_blurb: Label
var econ_info: VBoxContainer        # left column: dossier / triage / scenario detail
var econ_rows: VBoxContainer        # the OPTION ROW column
var econ_footer: Label              # ON HAND … currency line
var econ_leave_btn: Button
var _econ_screen: String = ""       # the active economy screen id ("shop"/"workshop"/…)
var _econ_selected: String = ""     # the previewed (first-tap) option id, "" = none
var _econ_rows_by_opt: Dictionary = {}   # option id -> { btn, delta_label, spec } for re-skinning
var econ_portrait_holder: Control = null   # W5-2 recruit-dossier portrait (FAC_NEUTRAL ring), left column
var econ_flavor: Panel = null              # W5-15 car/flavor art region filling the empty left half
var econ_flavor_name: Label = null         # the car name overlaid on the flavor feed
var econ_flavor_tex: TextureRect = null    # the car_flavor placeholder (drop-in: assets/final/car_<screen>.png)

# --- LEVEL-UP overlay (S3-LEVELUP; Batch 5). A modal ABILITY-CARD picker above every other screen.
# Built lazily on first show_levelup; hidden until then. 1-2 faction-cyan ability cards; a first tap
# selects (full blurb + CONFIRM tell), a second tap / CONFIRM picks. A PICK 1 of N queue indicator.
# No [ LEAVE ] — a level-up must resolve (the controller auto-picks option 0 as the never-stuck valve).
var levelup_root: Control
var levelup_header: Label           # "UNIT Name — LEVEL n"
var levelup_sub: Label              # "CHOOSE A SPECIALIZATION"
var levelup_queue_label: Label      # "PICK 1 of N"
var levelup_card_row: HBoxContainer
var _levelup_selected: String = ""  # the previewed (first-tap) ability id, "" = none
var _levelup_cards_by_id: Dictionary = {}   # ability id -> { btn, spec } for re-skinning
var levelup_portrait_holder: Control = null   # W5-5 the leveling unit's portrait beside the header


func _ready() -> void:
	layer = 6   # above CarView (default 0) + below the OpsHUD frame (layer 5 is the HUD; ending sits on top)
	_build()
	hide_screen()
	set_process(true)


func _process(delta: float) -> void:
	if _auto_dismiss > 0.0:
		_auto_dismiss -= delta
		if _auto_dismiss <= 0.0:
			hide_screen()


func _build() -> void:
	# Full-screen ending-tone wash — added FIRST so it draws BEHIND the ending card (child order is
	# draw order on a CanvasLayer). Transparent + hidden until show_ending tints + reveals it.
	ending_wash = ColorRect.new()
	ending_wash.set_anchors_preset(Control.PRESET_FULL_RECT)
	ending_wash.color = Color(0, 0, 0, 0)
	ending_wash.mouse_filter = Control.MOUSE_FILTER_IGNORE
	ending_wash.visible = false
	add_child(ending_wash)

	panel = Panel.new()
	panel.position = Vector2(340, 180)
	panel.size = Vector2(600, 360)
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(Pal.FRAME_BG.r, Pal.FRAME_BG.g, Pal.FRAME_BG.b, 0.95)
	sb.border_color = Pal.FRAME_BORDER
	sb.set_border_width_all(2)
	sb.set_corner_radius_all(2)
	panel.add_theme_stylebox_override("panel", sb)
	# W5-9: the ending/payout card must NOT swallow the click the prompt advertises ("[ ENTER / CLICK ]").
	# It is a display-only surface (never interactive — the interactive takeovers are draft/econ/levelup
	# roots), so let clicks fall through to the RunController's _unhandled_input _run_over handler, which
	# advances ENDING -> PAYOUT -> console. Panel + its text children set to IGNORE so no child intercepts.
	panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(panel)

	title_label = _label("", Pal.AMBER, 22)
	title_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	title_label.position = Vector2(20, 14)
	panel.add_child(title_label)

	var rule := ColorRect.new()
	rule.color = Pal.FRAME_BORDER
	rule.position = Vector2(20, 48)
	rule.size = Vector2(560, 2)
	panel.add_child(rule)

	body_label = RichTextLabel.new()
	body_label.bbcode_enabled = false
	body_label.position = Vector2(20, 60)
	body_label.size = Vector2(560, 280)
	body_label.add_theme_color_override("default_color", Pal.CYAN)
	body_label.add_theme_font_size_override("normal_font_size", 16)
	body_label.mouse_filter = Control.MOUSE_FILTER_IGNORE   # W5-9: don't swallow the advance-click
	panel.add_child(body_label)

	# Actionable prompt on the ending panel (hidden until set_ending_prompt). Anchored to the
	# panel bottom so it reads as a control hint, not run flavor.
	prompt_label = _label("", Pal.AMBER, 15)
	prompt_label.position = Vector2(20, 326)
	prompt_label.visible = false
	prompt_label.mouse_filter = Control.MOUSE_FILTER_IGNORE   # W5-9: don't swallow the advance-click
	panel.add_child(prompt_label)

	_build_draft_surface()
	_build_econ_surface()
	_build_levelup_surface()
	_build_abandon_overlay()


# ============================ ABANDON-RUN confirm (combat-ux #4) ===============
## Build the ESC "ABANDON RUN?" guard once (hidden until shown). A full-screen dim behind a
## centered two-choice panel: SAVE & EXIT (AMBER) vs KEEP FIGHTING (DIM). Progress is already
## checkpointed between cars, so exiting never loses the run — the copy says so. On-screen-only.
func _build_abandon_overlay() -> void:
	_abandon_wash = ColorRect.new()
	_abandon_wash.set_anchors_preset(Control.PRESET_FULL_RECT)
	_abandon_wash.color = Color(Pal.FRAME_BG.r, Pal.FRAME_BG.g, Pal.FRAME_BG.b, 0.82)
	_abandon_wash.mouse_filter = Control.MOUSE_FILTER_STOP
	_abandon_wash.visible = false
	add_child(_abandon_wash)

	abandon_overlay = Panel.new()
	abandon_overlay.position = Vector2(430, 210)
	abandon_overlay.size = Vector2(420, 240)
	var asb := StyleBoxFlat.new()
	asb.bg_color = Color(Pal.FRAME_BG.r, Pal.FRAME_BG.g, Pal.FRAME_BG.b, 0.98)
	asb.border_color = Pal.ALERT_RED
	asb.set_border_width_all(2)
	asb.set_corner_radius_all(2)
	abandon_overlay.add_theme_stylebox_override("panel", asb)
	abandon_overlay.visible = false
	add_child(abandon_overlay)

	var at := _label("ABANDON RUN?", Pal.ALERT_RED, 22)
	at.position = Vector2(20, 16)
	abandon_overlay.add_child(at)
	var arule := ColorRect.new()
	arule.color = Pal.FRAME_BORDER
	arule.position = Vector2(20, 50)
	arule.size = Vector2(380, 2)
	abandon_overlay.add_child(arule)
	var abody := _label("Your progress is SAVED between cars.\nExit now and resume this run later\nfrom CONTINUE, or keep fighting.", Pal.CYAN, 15)
	abody.position = Vector2(20, 66)
	abandon_overlay.add_child(abody)
	var save_btn := _draft_button("[ SAVE & EXIT ]", Pal.AMBER, func(): emit_signal("abandon_save_exit"))
	save_btn.position = Vector2(20, 180)
	abandon_overlay.add_child(save_btn)
	var keep_btn := _draft_button("[ KEEP FIGHTING ]", Pal.DIM, func(): emit_signal("abandon_keep"))
	keep_btn.position = Vector2(210, 180)
	abandon_overlay.add_child(keep_btn)


## Raise the ABANDON RUN? guard (ESC in a run). Returns nothing; the controller awaits its signals.
func show_abandon_confirm() -> void:
	if abandon_overlay == null:
		return
	_abandon_wash.visible = true
	abandon_overlay.visible = true


func hide_abandon_confirm() -> void:
	if abandon_overlay != null:
		abandon_overlay.visible = false
	if _abandon_wash != null:
		_abandon_wash.visible = false


## True while the ABANDON guard is up (the controller routes ESC/ENTER to it instead of the run).
func abandon_open() -> bool:
	return abandon_overlay != null and abandon_overlay.visible


# ============================ DEPLOY picker (combat-ux #6) =====================
## Build the pre-combat DEPLOY takeover once (hidden until shown). Full-screen dim + a member list
## the operator toggles to pick who fights, with a footer count + a DEPLOY commit button.
func _build_deploy_surface() -> void:
	deploy_root = Control.new()
	deploy_root.set_anchors_preset(Control.PRESET_FULL_RECT)
	deploy_root.visible = false
	add_child(deploy_root)
	var dim := ColorRect.new()
	dim.color = Color(Pal.FRAME_BG.r, Pal.FRAME_BG.g, Pal.FRAME_BG.b, 1.0)
	dim.set_anchors_preset(Control.PRESET_FULL_RECT)
	dim.mouse_filter = Control.MOUSE_FILTER_STOP
	deploy_root.add_child(dim)
	var header := _label("DEPLOY — PICK YOUR CELL", Pal.AMBER, 24)
	header.position = Vector2(60, 74)
	deploy_root.add_child(header)
	var rule := ColorRect.new()
	rule.color = Pal.FRAME_BORDER
	rule.position = Vector2(60, 110)
	rule.size = Vector2(1160, 2)
	deploy_root.add_child(rule)
	var blurb := _label("Only so many can breach this car. Tap to deploy or bench — the rest sit out.", Pal.DIM, 15)
	blurb.position = Vector2(60, 120)
	deploy_root.add_child(blurb)
	deploy_rows = VBoxContainer.new()
	deploy_rows.position = Vector2(60, 160)
	deploy_rows.custom_minimum_size = Vector2(1000, 360)
	deploy_rows.add_theme_constant_override("separation", 10)
	deploy_root.add_child(deploy_rows)
	deploy_footer = _label("", Pal.CYAN, 16)
	deploy_footer.position = Vector2(60, 588)
	deploy_root.add_child(deploy_footer)
	deploy_commit_btn = _draft_button("[ DEPLOY ]", Pal.AMBER, func(): emit_signal("deploy_commit"))
	deploy_commit_btn.position = Vector2(1040, 580)
	deploy_root.add_child(deploy_commit_btn)


## Render the DEPLOY picker from a spec the controller assembles each toggle:
##   { members:[{id:int, label:String, detail:String, hp:int, max_hp:int, selected:bool}], need:int }
## A row tap emits deploy_toggle(id); the DEPLOY button (enabled only at exactly `need` selected)
## emits deploy_commit. The controller owns the selection set + re-pushes the spec on every toggle.
func show_deploy_picker(spec: Dictionary) -> void:
	if deploy_root == null:
		_build_deploy_surface()
	hide_screen()
	deploy_root.visible = true
	for c in deploy_rows.get_children():
		c.queue_free()
	var members: Array = spec.get("members", [])
	var need: int = int(spec.get("need", 3))
	var picked: int = 0
	for m in members:
		var sel: bool = bool(m.get("selected", false))
		if sel:
			picked += 1
		var mid: int = int(m.get("id", -1))
		var row := Button.new()
		row.focus_mode = Control.FOCUS_NONE
		row.custom_minimum_size = Vector2(940, 56)
		row.clip_text = false
		var accent: Color = Pal.AMBER if sel else Pal.FRAME_BORDER
		row.add_theme_stylebox_override("normal", _econ_row_stylebox(sel, accent))
		row.add_theme_stylebox_override("hover", _econ_row_stylebox(sel, accent))
		row.add_theme_stylebox_override("pressed", _econ_row_stylebox(true, accent))
		row.pressed.connect(func(): emit_signal("deploy_toggle", mid))
		var content := Control.new()
		content.position = Vector2(14, 6)
		content.mouse_filter = Control.MOUSE_FILTER_IGNORE
		row.add_child(content)
		# W5-14: real archetype mini-glyph (no tofu ▮/▯). Archetype comes from an explicit member field,
		# else it is parsed from the "<name> [<archetype>]" label the controller already passes.
		var arch := String(m.get("archetype", ""))
		if arch == "":
			arch = _arch_from_bracket(String(m.get("label", "")))
		var tok := _mini_token(arch, 40)
		tok.position = Vector2(0, 2)
		content.add_child(tok)
		var tag := "> DEPLOYING" if sel else "- benched"   # ASCII markers (the old ▮/▯ rendered as tofu)
		var lab := _label("%s   %s" % [tag, String(m.get("label", str(mid)))], Pal.AMBER if sel else Pal.DIM, 18)
		lab.position = Vector2(50, 0)
		content.add_child(lab)
		var det := _label("%s   HP %d/%d" % [String(m.get("detail", "")), int(m.get("hp", 0)), int(m.get("max_hp", 0))], Pal.CYAN if sel else Pal.DIM, 13)
		det.position = Vector2(50, 28)
		content.add_child(det)
		deploy_rows.add_child(row)
	deploy_footer.text = "DEPLOYING %d / %d   ·   %d benched" % [picked, need, max(0, members.size() - picked)]
	deploy_commit_btn.disabled = (picked != need)
	deploy_commit_btn.text = "[ DEPLOY ]" if picked == need else "[ PICK %d ]" % need


func hide_deploy_picker() -> void:
	if deploy_root != null:
		deploy_root.visible = false


func deploy_open() -> bool:
	return deploy_root != null and deploy_root.visible


# ============================ interactive ECONOMY surface (S3) =================
## Build the reusable economy-choice takeover once (hidden until shown). ART_BIBLE §3 tokens:
## FRAME_BG/FRAME_BORDER chrome, AMBER primary type, CYAN data/affordable cost, ALERT_RED reserved
## for can't-afford cost + the KILL accent + Order-rise warnings, DIM for inactive/captions. Layout
## mirrors the draft takeover (dimmer + header + left info column + right option column + footer).
func _build_econ_surface() -> void:
	econ_root = Control.new()
	econ_root.set_anchors_preset(Control.PRESET_FULL_RECT)
	econ_root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(econ_root)

	# Fully-opaque full-screen takeover (see the draft surface note) — no HUD/desktop bleed-through.
	var dim := ColorRect.new()
	dim.color = Color(Pal.FRAME_BG.r, Pal.FRAME_BG.g, Pal.FRAME_BG.b, 1.0)
	dim.set_anchors_preset(Control.PRESET_FULL_RECT)
	dim.mouse_filter = Control.MOUSE_FILTER_STOP
	econ_root.add_child(dim)

	econ_header = _label("", Pal.AMBER, 24)
	econ_header.position = Vector2(60, 74)
	econ_root.add_child(econ_header)
	var rule := ColorRect.new()
	rule.color = Pal.FRAME_BORDER
	rule.position = Vector2(60, 110)
	rule.size = Vector2(1160, 2)
	econ_root.add_child(rule)
	econ_blurb = _label("", Pal.DIM, 15)
	econ_blurb.position = Vector2(60, 120)
	econ_root.add_child(econ_blurb)

	# Left info column (dossier / triage / scenario), right option column.
	econ_info = VBoxContainer.new()
	econ_info.position = Vector2(60, 160)
	econ_info.custom_minimum_size = Vector2(520, 380)
	econ_info.add_theme_constant_override("separation", 8)
	econ_root.add_child(econ_info)

	econ_rows = VBoxContainer.new()
	econ_rows.position = Vector2(620, 160)
	econ_rows.custom_minimum_size = Vector2(600, 380)
	econ_rows.add_theme_constant_override("separation", 12)
	econ_root.add_child(econ_rows)

	econ_footer = _label("", Pal.CYAN, 15)
	econ_footer.position = Vector2(60, 588)
	econ_root.add_child(econ_footer)

	econ_leave_btn = _draft_button("[ LEAVE ]", Pal.AMBER, func(): emit_signal("choice_leave", _econ_screen))
	econ_leave_btn.position = Vector2(1070, 580)
	econ_root.add_child(econ_leave_btn)

	# W5-15: CAR / FLAVOR ART REGION — a framed live-feed panel that fills the large empty LEFT half of
	# the shop/workshop/bourgeois/event/rest takeovers with the car name + a flavor glyph, so the screen
	# never reads half-empty. Drop-in: assets/final/car_<screen>.png wins per-car; else the generic
	# car_flavor placeholder. Lower-left so it clears the dossier/triage lines above + the footer below.
	econ_flavor = Panel.new()
	econ_flavor.position = Vector2(60, 380)
	econ_flavor.custom_minimum_size = Vector2(512, 172)
	econ_flavor.size = Vector2(512, 172)
	econ_flavor.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var fsb := StyleBoxFlat.new()
	fsb.bg_color = Color(Pal.FRAME_BG.r, Pal.FRAME_BG.g, Pal.FRAME_BG.b, 0.85)
	fsb.border_color = Pal.FRAME_BORDER
	fsb.set_border_width_all(1)
	fsb.set_corner_radius_all(2)
	econ_flavor.add_theme_stylebox_override("panel", fsb)
	econ_flavor_tex = TextureRect.new()
	econ_flavor_tex.name = "Flavor"
	econ_flavor_tex.texture = _load_tex("car_flavor")
	econ_flavor_tex.position = Vector2(12, 16)
	econ_flavor_tex.size = Vector2(240, 140)
	econ_flavor_tex.custom_minimum_size = Vector2(240, 140)
	econ_flavor_tex.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	econ_flavor_tex.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	econ_flavor_tex.mouse_filter = Control.MOUSE_FILTER_IGNORE
	econ_flavor.add_child(econ_flavor_tex)
	econ_flavor_name = _label("", Pal.AMBER, 18)
	econ_flavor_name.position = Vector2(270, 44)
	econ_flavor.add_child(econ_flavor_name)
	var fcap := _label("CAM // live car feed", Pal.DIM, 12)
	fcap.position = Vector2(270, 74)
	econ_flavor.add_child(fcap)
	econ_root.add_child(econ_flavor)

	# W5-2: recruit-dossier portrait holder (populated per-screen; hidden until a portrait-bearing
	# screen shows). Sits at the top of the left column; the dossier text shifts right of it.
	econ_portrait_holder = Control.new()
	econ_portrait_holder.position = Vector2(60, 158)
	econ_portrait_holder.mouse_filter = Control.MOUSE_FILTER_IGNORE
	econ_portrait_holder.visible = false
	econ_root.add_child(econ_portrait_holder)

	econ_root.visible = false


## Render the economy-choice surface for `screen` from a spec dict the controller assembles:
##   { title, title_col, blurb, footer, info_lines:[{text,col}], options:[opt_spec], leave:bool }
## each opt_spec: { id, label, cost, consequence, affordable:bool, accent:Color(optional),
##                  delta:String(preview chip), warn:String(optional ALERT_RED warning) }.
## A FIRST tap selects an OPTION ROW (preview delta + warn); a SECOND tap on the SAME row commits.
## Can't-afford rows render DIM with the cost in ALERT_RED and reject the tap. LEAVE shows when
## spec.leave. The controller drives the REAL rail off the commit signal — this only renders + emits.
func show_econ_choices(screen: String, spec: Dictionary) -> void:
	if econ_root == null:
		return
	hide_screen()
	if draft_root != null:
		draft_root.visible = false   # the draft is long done by S3; never overlap takeovers
	_econ_screen = screen
	_econ_selected = ""
	_econ_rows_by_opt.clear()
	econ_root.visible = true
	econ_header.text = String(spec.get("title", ""))
	econ_header.add_theme_color_override("font_color", spec.get("title_col", Pal.AMBER))
	econ_blurb.text = String(spec.get("blurb", ""))
	econ_footer.text = String(spec.get("footer", ""))
	econ_leave_btn.visible = bool(spec.get("leave", true))
	if econ_flavor_name != null:
		econ_flavor_name.text = String(spec.get("title", ""))   # W5-15: name the flavor feed after the car
	_apply_econ_portrait(screen, spec)                          # W5-2: recruit dossier portrait
	_rebuild_econ_info(spec.get("info_lines", []))
	_rebuild_econ_rows(screen, spec.get("options", []))


## Rebuild the left info column (dossier / triage / scenario). Each line is { text, col }; a line
## with a `bar` key (cur,max,ghost) draws an HP bar (REST triage) instead of plain text.
func _rebuild_econ_info(lines: Array) -> void:
	for c in econ_info.get_children():
		c.queue_free()
	for ln in lines:
		if ln.has("bar"):
			econ_info.add_child(_hp_bar_row(ln))
		else:
			econ_info.add_child(_label(String(ln.get("text", "")), ln.get("col", Pal.CYAN), int(ln.get("size", 15))))


## An HP triage row (REST): callsign + a CYAN fill bar on FRAME_BG with a faint AMBER ghost segment
## for the projected heal. `ln.bar` = { cur, max, ghost } (ghost = projected hp after heal).
func _hp_bar_row(ln: Dictionary) -> Control:
	var row := Control.new()
	row.custom_minimum_size = Vector2(500, 30)
	var nm := _label(String(ln.get("text", "")), ln.get("col", Pal.AMBER), 14)
	nm.position = Vector2(0, 4)
	row.add_child(nm)
	var bar: Dictionary = ln.get("bar", {})
	var cur: int = int(bar.get("cur", 0))
	var mx: int = max(1, int(bar.get("max", 1)))
	var ghost: int = int(bar.get("ghost", cur))
	var bx := 220.0
	var bw := 260.0
	var bg := ColorRect.new()
	bg.color = Pal.FRAME_BG
	bg.position = Vector2(bx, 6)
	bg.size = Vector2(bw, 16)
	row.add_child(bg)
	# ghost (projected) segment behind the live fill, faint AMBER.
	if ghost > cur:
		var gseg := ColorRect.new()
		gseg.color = Color(Pal.AMBER.r, Pal.AMBER.g, Pal.AMBER.b, 0.45)
		gseg.position = Vector2(bx, 6)
		gseg.size = Vector2(bw * (float(min(ghost, mx)) / float(mx)), 16)
		row.add_child(gseg)
	var fill := ColorRect.new()
	fill.color = Pal.CYAN
	fill.position = Vector2(bx, 6)
	fill.size = Vector2(bw * (float(min(cur, mx)) / float(mx)), 16)
	row.add_child(fill)
	var rd := _label("%d/%d%s" % [cur, mx, ("  +%d" % (ghost - cur) if ghost > cur else "")], Pal.DIM, 12)
	rd.position = Vector2(bx + bw + 8, 5)
	row.add_child(rd)
	return row


## Rebuild the OPTION ROW column from the option specs. Each row is a Button (so touch + click are
## identical): label (AMBER, or DIM if can't-afford) + cost chip (CYAN affordable / ALERT_RED not) +
## a DIM consequence line + a hidden DELTA CHIP (shown AMBER on select). Tap routing is _on_econ_row.
func _rebuild_econ_rows(screen: String, options: Array) -> void:
	for c in econ_rows.get_children():
		c.queue_free()
	_econ_rows_by_opt.clear()
	for spec in options:
		var oid := String(spec.get("id", ""))
		var affordable: bool = bool(spec.get("affordable", true))
		var row := Button.new()
		row.focus_mode = Control.FOCUS_NONE
		row.custom_minimum_size = Vector2(580, 76)
		row.clip_text = false
		row.disabled = not affordable
		var accent: Color = spec.get("accent", Pal.FRAME_BORDER)
		row.add_theme_stylebox_override("normal", _econ_row_stylebox(false, accent))
		row.add_theme_stylebox_override("hover", _econ_row_stylebox(false, accent))
		row.add_theme_stylebox_override("pressed", _econ_row_stylebox(true, accent))
		row.add_theme_stylebox_override("disabled", _econ_row_stylebox(false, accent))
		row.pressed.connect(func(): _on_econ_row(screen, oid))
		var content := Control.new()
		content.position = Vector2(14, 8)
		content.mouse_filter = Control.MOUSE_FILTER_IGNORE
		row.add_child(content)
		var lab_txt := String(spec.get("label", ""))
		if lab_txt == "":
			lab_txt = "[ %s ]" % _humanize_id(oid)   # W5-6: never render a raw snake_case id
		var lab := _label(lab_txt, Pal.AMBER if affordable else Pal.DIM, 18)
		lab.position = Vector2(0, 0)
		content.add_child(lab)
		var cost := String(spec.get("cost", ""))
		if cost != "":
			var cost_lbl := _label(cost, Pal.CYAN if affordable else Pal.ALERT_RED, 15)
			cost_lbl.position = Vector2(400, 2)
			content.add_child(cost_lbl)
		var cons := _label(String(spec.get("consequence", "")), Pal.DIM, 13)
		cons.position = Vector2(0, 28)
		content.add_child(cons)
		# DELTA CHIP (hidden until selected).
		var delta_lbl := _label("", Pal.AMBER, 14)
		delta_lbl.position = Vector2(0, 48)
		delta_lbl.visible = false
		content.add_child(delta_lbl)
		econ_rows.add_child(row)
		_econ_rows_by_opt[oid] = {"btn": row, "delta": delta_lbl, "spec": spec, "accent": accent}


## A TAP on an OPTION ROW: first tap previews (emit choice_select; the controller may push an
## updated spec for the delta/warn), a second tap on the SAME option commits (emit choice_commit).
## Disabled rows never reach here (Button.disabled swallows the press).
func _on_econ_row(screen: String, option: String) -> void:
	if _econ_selected == option:
		emit_signal("choice_commit", screen, option)
		return
	_econ_selected = option
	_apply_econ_selection()
	emit_signal("choice_select", screen, option)


## Re-skin the option borders for the current selection (selected = solid AMBER 2px + DELTA CHIP),
## and reveal the previewed delta/warn chip on the selected row.
func _apply_econ_selection() -> void:
	for oid in _econ_rows_by_opt.keys():
		var rec: Dictionary = _econ_rows_by_opt[oid]
		var b: Button = rec["btn"]
		var sel: bool = (String(oid) == _econ_selected)
		var accent: Color = rec.get("accent", Pal.FRAME_BORDER)
		b.add_theme_stylebox_override("normal", _econ_row_stylebox(sel, accent))
		b.add_theme_stylebox_override("hover", _econ_row_stylebox(sel, accent))
		var dl: Label = rec["delta"]
		var spec: Dictionary = rec["spec"]
		if sel:
			var dtext := String(spec.get("delta", ""))
			var warn := String(spec.get("warn", ""))
			dl.text = dtext + ("   " + warn if warn != "" else "")
			dl.add_theme_color_override("font_color", Pal.ALERT_RED if warn != "" else Pal.AMBER)
			dl.visible = (dtext != "" or warn != "")
		else:
			dl.visible = false


## The currently-selected option id on the econ surface (-"" if none). Used by the controller's
## keyboard handler for ENTER-confirm-the-selected.
func econ_selected() -> String:
	return _econ_selected


## Programmatically select an option (keyboard number keys) — previews it without committing.
func econ_select_option(option: String) -> void:
	if not _econ_rows_by_opt.has(option):
		return
	var rec: Dictionary = _econ_rows_by_opt[option]
	if (rec["btn"] as Button).disabled:
		return
	_econ_selected = option
	_apply_econ_selection()
	emit_signal("choice_select", _econ_screen, option)


## The option ids currently rendered, in row order (keyboard 1/2/3 maps onto this). The Dictionary
## preserves insertion order (the spec list order rows were built from), so this is row-stable.
func econ_option_ids() -> Array:
	return _econ_rows_by_opt.keys()


func hide_econ_surface() -> void:
	if econ_root != null:
		econ_root.visible = false
	_econ_screen = ""
	_econ_selected = ""


## The OPTION ROW frame: default = `accent` edge (FRAME_BORDER, or ALERT_RED for the KILL row);
## selected = solid AMBER 2px + a faint inset wash. Disabled rows keep the accent but read DIM via
## the label colors set in _rebuild_econ_rows.
func _econ_row_stylebox(selected: bool, accent: Color) -> StyleBoxFlat:
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(Pal.FRAME_INSET.r, Pal.FRAME_INSET.g, Pal.FRAME_INSET.b, 0.16 if selected else 0.08)
	sb.border_color = Pal.AMBER if selected else accent
	sb.set_border_width_all(2 if selected else 1)
	sb.set_corner_radius_all(2)
	sb.content_margin_left = 14
	sb.content_margin_top = 8
	sb.content_margin_right = 14
	sb.content_margin_bottom = 8
	return sb


## W5-2: place the recruit-dossier portrait in the left column and shift the dossier text right of it.
## The archetype comes from an explicit spec.portrait, else (for the RECRUIT screen) it is derived from
## the dossier lines the controller already passes ("<name>  [<archetype>]"), so it works with no cross-
## lane change. FAC_NEUTRAL amber ring = a citizen offering to join (not yet the player-cyan cell).
func _apply_econ_portrait(screen: String, spec: Dictionary) -> void:
	if econ_portrait_holder == null:
		return
	for c in econ_portrait_holder.get_children():
		c.queue_free()
	var arch := String(spec.get("portrait", ""))
	var ring: Color = spec.get("portrait_ring", Pal.FAC_NEUTRAL)
	if arch == "" and screen == "recruit":
		arch = _derive_arch_from_info(spec.get("info_lines", []))
		ring = Pal.FAC_NEUTRAL
	if arch == "":
		econ_portrait_holder.visible = false
		econ_info.position.x = 60
		return
	econ_portrait_holder.add_child(_portrait_frame(arch, ring, 130, 160))
	econ_portrait_holder.visible = true
	econ_info.position.x = 214   # dossier text sits right of the portrait


## Find the first known archetype id bracketed in a dossier info line (recruit), else "".
func _derive_arch_from_info(lines: Array) -> String:
	for ln in lines:
		if typeof(ln) != TYPE_DICTIONARY:
			continue
		var a := _arch_from_bracket(String(ln.get("text", "")))
		if a != "":
			return a
	return ""


# ============================ LEVEL-UP overlay (S3-LEVELUP; Batch 5) ===========
## Build the ABILITY-CARD level-up modal once (hidden until shown). ART_BIBLE §3: FRAME_BG dimmer +
## a centered panel, AMBER header (unit+level), CYAN sub + faction-cyan ability cards, DIM captions.
## It sits ABOVE the other screens (added last on this CanvasLayer) so a pending pick is the front-
## most modal. On-screen-only — headless never instances RunScreens.
func _build_levelup_surface() -> void:
	levelup_root = Control.new()
	levelup_root.set_anchors_preset(Control.PRESET_FULL_RECT)
	levelup_root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(levelup_root)

	# Full-screen dimmer so the level-up reads as a hard modal (you must resolve it).
	var dim := ColorRect.new()
	dim.color = Color(Pal.FRAME_BG.r, Pal.FRAME_BG.g, Pal.FRAME_BG.b, 1.0)   # fully opaque hard modal
	dim.set_anchors_preset(Control.PRESET_FULL_RECT)
	dim.mouse_filter = Control.MOUSE_FILTER_STOP
	levelup_root.add_child(dim)

	var panel_w := 720.0
	var panel_x := (1280.0 - panel_w) * 0.5
	levelup_header = _label("", Pal.AMBER, 26)
	levelup_header.position = Vector2(panel_x, 120)
	levelup_root.add_child(levelup_header)
	levelup_sub = _label("CHOOSE A SPECIALIZATION", Pal.CYAN, 18)
	levelup_sub.position = Vector2(panel_x, 156)
	levelup_root.add_child(levelup_sub)
	levelup_queue_label = _label("", Pal.DIM, 14)
	levelup_queue_label.position = Vector2(panel_x, 184)
	levelup_root.add_child(levelup_queue_label)
	var rule := ColorRect.new()
	rule.color = Pal.FRAME_BORDER
	rule.position = Vector2(panel_x, 210)
	rule.size = Vector2(panel_w, 2)
	levelup_root.add_child(rule)

	levelup_card_row = HBoxContainer.new()
	levelup_card_row.position = Vector2(panel_x, 240)
	levelup_card_row.add_theme_constant_override("separation", 24)
	levelup_root.add_child(levelup_card_row)

	# W5-5: WHO is leveling — the unit's portrait to the LEFT of the header (populated per pick).
	levelup_portrait_holder = Control.new()
	levelup_portrait_holder.position = Vector2(panel_x - 168, 96)
	levelup_portrait_holder.mouse_filter = Control.MOUSE_FILTER_IGNORE
	levelup_root.add_child(levelup_portrait_holder)

	levelup_root.visible = false


## Raise the LEVEL-UP modal for one pending pick. `spec` is the controller-built dict:
##   { name, level, archetype, queue_idx, queue_total, options:[{id, name, tier, blurb}] }
## Renders the header + queue indicator + one card per option (1 = forced capstone, 2 = the 1-of-2).
## A first tap selects a card (preview blurb + CONFIRM tell), a second tap picks. On-screen-only.
func show_levelup(spec: Dictionary) -> void:
	if levelup_root == null:
		return
	hide_screen()
	if draft_root != null:
		draft_root.visible = false
	if econ_root != null:
		econ_root.visible = false   # a queued pick is the front-most modal; the econ screen yields
	_levelup_selected = ""
	_levelup_cards_by_id.clear()
	levelup_root.visible = true
	levelup_header.text = "%s — LEVEL %d" % [String(spec.get("name", "UNIT")), int(spec.get("level", 2))]
	# W5-5: show WHO is leveling (the unit portrait, FAC_PLAYER ring) beside the header.
	if levelup_portrait_holder != null:
		for c in levelup_portrait_holder.get_children():
			c.queue_free()
		levelup_portrait_holder.add_child(_portrait_frame(String(spec.get("archetype", "")), Pal.FAC_PLAYER, 120, 150))
	var qi: int = int(spec.get("queue_idx", 0)) + 1
	# W5-5: N is the QUEUED-PICK count (queue_total, the controller's _pending_levelup_picks().size()),
	# NOT the number of ability cards — "PICK 1 of N" reads as "N owed picks", not "N options".
	var qt: int = int(spec.get("queue_total", 1))
	levelup_queue_label.text = "PICK %d of %d" % [qi, qt]
	levelup_queue_label.visible = qt > 1
	var options: Array = spec.get("options", [])
	levelup_sub.text = "AUTHORIZE A SPECIALIZATION" if options.size() == 1 else "CHOOSE A SPECIALIZATION"
	_rebuild_levelup_cards(options)


## Rebuild the ability cards from the option specs. Each card is a Button (touch + click identical):
## tier tag (T1/T2/T3/CAPSTONE) + ability name (AMBER) + a CYAN/faded effect blurb. A first tap
## selects (AMBER frame + a CONFIRM tell), a second tap on the same card picks. Faction-cyan default.
func _rebuild_levelup_cards(options: Array) -> void:
	for c in levelup_card_row.get_children():
		c.queue_free()
	_levelup_cards_by_id.clear()
	for spec in options:
		var aid := String(spec.get("id", ""))
		var card := Button.new()
		card.focus_mode = Control.FOCUS_NONE
		card.custom_minimum_size = Vector2(330, 300)
		card.clip_text = false
		card.add_theme_stylebox_override("normal", _levelup_card_stylebox(false))
		card.add_theme_stylebox_override("hover", _levelup_card_stylebox(false))
		card.add_theme_stylebox_override("pressed", _levelup_card_stylebox(true))
		card.pressed.connect(func(): _on_levelup_card(aid))
		var content := Control.new()
		content.position = Vector2(16, 14)
		content.mouse_filter = Control.MOUSE_FILTER_IGNORE
		card.add_child(content)
		# Faction-cyan ring header (the §3.5 player tell).
		var ring := ColorRect.new()
		ring.color = Pal.FAC_PLAYER
		ring.position = Vector2(0, 0)
		ring.size = Vector2(296, 4)
		content.add_child(ring)
		var tier := _label(String(spec.get("tier", "")), Pal.CYAN, 14)
		tier.position = Vector2(0, 12)
		content.add_child(tier)
		var nm := _label(_scrub_ids(String(spec.get("name", aid))), Pal.AMBER, 22)   # W5-6: no raw id
		nm.position = Vector2(0, 38)
		content.add_child(nm)
		var blurb := RichTextLabel.new()
		blurb.bbcode_enabled = false
		blurb.fit_content = true
		blurb.scroll_active = false
		blurb.position = Vector2(0, 78)
		blurb.size = Vector2(290, 170)
		blurb.add_theme_color_override("default_color", Pal.CYAN)
		blurb.add_theme_font_size_override("normal_font_size", 14)
		blurb.text = _scrub_ids(String(spec.get("blurb", "")))   # W5-6: humanize any raw effect-kind id
		content.add_child(blurb)
		var confirm := _label("", Pal.AMBER, 14)
		confirm.position = Vector2(0, 256)
		confirm.visible = false
		content.add_child(confirm)
		levelup_card_row.add_child(card)
		_levelup_cards_by_id[aid] = {"btn": card, "confirm": confirm}
	_apply_levelup_selection()


## A TAP on an ability card: first tap previews (emit levelup_select; AMBER frame + CONFIRM tell), a
## second tap on the SAME ability picks it (emit levelup_pick). The controller applies the pick.
func _on_levelup_card(ability_id: String) -> void:
	if _levelup_selected == ability_id:
		emit_signal("levelup_pick", ability_id)
		return
	_levelup_selected = ability_id
	_apply_levelup_selection()
	emit_signal("levelup_select", ability_id)


## Re-skin the cards for the current selection (selected = solid AMBER frame + a "[ CONFIRM ]" tell).
func _apply_levelup_selection() -> void:
	for aid in _levelup_cards_by_id.keys():
		var rec: Dictionary = _levelup_cards_by_id[aid]
		var b: Button = rec["btn"]
		var sel: bool = (String(aid) == _levelup_selected)
		b.add_theme_stylebox_override("normal", _levelup_card_stylebox(sel))
		b.add_theme_stylebox_override("hover", _levelup_card_stylebox(sel))
		var cf: Label = rec["confirm"]
		cf.text = "[ CONFIRM — tap again ]"
		cf.visible = sel


## The currently-selected ability id on the level-up surface ("" if none) — for keyboard ENTER-confirm.
func levelup_selected() -> String:
	return _levelup_selected


## Programmatically select an ability (keyboard 1/2) — previews it without committing.
func levelup_select_ability(ability_id: String) -> void:
	if not _levelup_cards_by_id.has(ability_id):
		return
	_levelup_selected = ability_id
	_apply_levelup_selection()
	emit_signal("levelup_select", ability_id)


## The ability ids currently rendered, in card order (keyboard 1/2 maps onto this).
func levelup_option_ids() -> Array:
	return _levelup_cards_by_id.keys()


func hide_levelup() -> void:
	if levelup_root != null:
		levelup_root.visible = false
	_levelup_selected = ""


func _levelup_card_stylebox(selected: bool) -> StyleBoxFlat:
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(Pal.FRAME_INSET.r, Pal.FRAME_INSET.g, Pal.FRAME_INSET.b, 0.20 if selected else 0.10)
	sb.border_color = Pal.AMBER if selected else Pal.FAC_PLAYER
	sb.set_border_width_all(2 if selected else 1)
	sb.set_corner_radius_all(2)
	sb.content_margin_left = 16
	sb.content_margin_top = 14
	sb.content_margin_right = 16
	sb.content_margin_bottom = 14
	return sb


# ============================ interactive DRAFT surface (S2) ===================
## Build the DRAFT_VETTING takeover + the BREACH_CONFIRM overlay once (hidden until shown). All
## tokens are ART_BIBLE §3: FRAME_BG/FRAME_BORDER/FRAME_INSET chrome, AMBER primary, CYAN data,
## ALERT_RED reserved for negative trait chips + the roster-full lock, DIM for inactive/captions,
## FAC_PLAYER for the cell deploy-tile rings.
func _build_draft_surface() -> void:
	draft_root = Control.new()
	draft_root.set_anchors_preset(Control.PRESET_FULL_RECT)
	draft_root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(draft_root)

	# FULLY-OPAQUE full-screen backdrop so the draft is a clean takeover. The old 0.88-alpha 1200×600
	# rect left margins uncovered and let the combat HUD + the desktop/terminal bleed through. Full-rect
	# + opaque + STOP also blocks clicks from reaching the (covered) combat board/HUD behind.
	var dim := ColorRect.new()
	dim.color = Color(Pal.FRAME_BG.r, Pal.FRAME_BG.g, Pal.FRAME_BG.b, 1.0)
	dim.set_anchors_preset(Control.PRESET_FULL_RECT)
	dim.mouse_filter = Control.MOUSE_FILTER_STOP
	draft_root.add_child(dim)

	# Header — CAR 00 framing for the vet-before-breach beat.
	var header := _label("CAR 00 — TAIL ASSEMBLY   ·   VETTING VOLUNTEERS", Pal.AMBER, 22)
	header.position = Vector2(60, 74)
	draft_root.add_child(header)
	draft_status_label = _label("ROUND 1 / 3   ·   DRAFT 1-3 STARTERS", Pal.DIM, 14)
	draft_status_label.position = Vector2(60, 104)
	draft_root.add_child(draft_status_label)

	# RISK_DIAL_READOUT — 3-segment payout bar + live multiplier label (CYAN -> AMBER as you
	# commit fewer). ALERT_RED is reserved; the dial caps at AMBER (spec §8 component note).
	dial_label = _label("PAYOUT  x1.00", Pal.CYAN, 18)
	dial_label.position = Vector2(820, 74)
	draft_root.add_child(dial_label)
	var dial_bg := ColorRect.new()
	dial_bg.color = Pal.FRAME_BG
	dial_bg.position = Vector2(820, 104)
	dial_bg.size = Vector2(360, 14)
	draft_root.add_child(dial_bg)
	dial_bar_lit = ColorRect.new()
	dial_bar_lit.color = Pal.CYAN
	dial_bar_lit.position = Vector2(820, 104)
	dial_bar_lit.size = Vector2(120, 14)
	draft_root.add_child(dial_bar_lit)
	# segment seams (3 bands)
	for sx in [240.0, 360.0]:
		var seam := ColorRect.new()
		seam.color = Pal.FRAME_BORDER
		seam.position = Vector2(820.0 + sx - 1.0, 104)
		seam.size = Vector2(2, 14)
		draft_root.add_child(seam)
	dial_caption = _label("drafting FEWER raises the payout + leaves recruit slots", Pal.DIM, 12)
	dial_caption.position = Vector2(820, 122)
	draft_root.add_child(dial_caption)

	# LEGACY ARMED banner (hidden unless a legacy_payload is handed off).
	legacy_banner = _label("", Pal.AMBER, 14)
	legacy_banner.position = Vector2(60, 132)
	legacy_banner.visible = false
	draft_root.add_child(legacy_banner)

	# Candidate card row (up to 3 DRAFT_CANDIDATE_CARDs).
	card_row = HBoxContainer.new()
	card_row.position = Vector2(60, 168)
	card_row.add_theme_constant_override("separation", 18)
	draft_root.add_child(card_row)

	# Control bar — TAKE / DECLINE / STOP & BREACH / AUTO (mirrors OpsHUD action buttons).
	var ctl_row := HBoxContainer.new()
	ctl_row.position = Vector2(60, 540)
	ctl_row.add_theme_constant_override("separation", 10)
	draft_root.add_child(ctl_row)
	ctl_take = _draft_button("[ TAKE ]", Pal.CYAN, func(): emit_signal("draft_take", _selected_idx))
	ctl_decline = _draft_button("[ DECLINE ROUND ]", Pal.AMBER, func(): emit_signal("draft_decline"))
	ctl_breach = _draft_button("[ STOP & BREACH ]", Pal.AMBER, func(): emit_signal("draft_breach"))
	ctl_auto = _draft_button("[ QUICK DRAFT ]", Pal.CYAN, func(): emit_signal("draft_auto"))
	ctl_row.add_child(ctl_take)
	ctl_row.add_child(ctl_decline)
	ctl_row.add_child(ctl_breach)
	ctl_row.add_child(ctl_auto)

	# CELL_ROSTER_STRIP — 1-3 filling slots along the bottom.
	var rh := _label("CELL ROSTER", Pal.DIM, 13)
	rh.position = Vector2(60, 588)
	draft_root.add_child(rh)
	roster_row = HBoxContainer.new()
	roster_row.position = Vector2(180, 580)
	roster_row.add_theme_constant_override("separation", 12)
	draft_root.add_child(roster_row)

	# BREACH_CONFIRM overlay (centered; dims the draft behind it).
	breach_overlay = Panel.new()
	breach_overlay.position = Vector2(430, 200)
	breach_overlay.size = Vector2(420, 320)
	var bsb := StyleBoxFlat.new()
	bsb.bg_color = Color(Pal.FRAME_BG.r, Pal.FRAME_BG.g, Pal.FRAME_BG.b, 0.97)
	bsb.border_color = Pal.FRAME_BORDER
	bsb.set_border_width_all(2)
	bsb.set_corner_radius_all(2)
	breach_overlay.add_theme_stylebox_override("panel", bsb)
	draft_root.add_child(breach_overlay)
	var bt := _label("BREACH?", Pal.AMBER, 24)
	bt.position = Vector2(20, 16)
	breach_overlay.add_child(bt)
	var brule := ColorRect.new()
	brule.color = Pal.FRAME_BORDER
	brule.position = Vector2(20, 50)
	brule.size = Vector2(380, 2)
	breach_overlay.add_child(brule)
	breach_body = RichTextLabel.new()
	breach_body.bbcode_enabled = false
	breach_body.position = Vector2(20, 62)
	breach_body.size = Vector2(380, 180)
	breach_body.add_theme_color_override("default_color", Pal.CYAN)
	breach_body.add_theme_font_size_override("normal_font_size", 15)
	breach_overlay.add_child(breach_body)
	breach_go_btn = _draft_button("[ BREACH — GO ]", Pal.AMBER, func(): emit_signal("breach_go"))
	breach_go_btn.position = Vector2(20, 260)
	breach_overlay.add_child(breach_go_btn)
	breach_back_btn = _draft_button("[ BACK ]", Pal.DIM, func(): emit_signal("breach_back"))
	breach_back_btn.position = Vector2(230, 260)
	breach_overlay.add_child(breach_back_btn)
	breach_locked_label = _label("DRAFT LOCKED", Pal.DIM, 15)
	breach_locked_label.position = Vector2(234, 266)
	breach_locked_label.visible = false
	breach_overlay.add_child(breach_locked_label)

	draft_root.visible = false
	breach_overlay.visible = false


## Render the live DRAFT_VETTING surface from the REAL Draft model. `draft` is core/units/draft.gd
## (current_choices / picks / finished / draft_payout_mult); `db` reads archetype baseStats + trait
## polarity for each card; `legacy_payload` (or {}) drives the LEGACY ARMED banner. Rebuilds the 3
## candidate cards, the risk dial, the roster strip, and the control-bar enable states each round.
func show_draft_interactive(draft, db, legacy_payload: Dictionary = {}) -> void:
	if draft_root == null:
		return
	hide_screen()            # close any text panel
	hide_breach_confirm()
	_selected_idx = -1
	draft_root.visible = true
	# Round / lock status.
	if draft.finished:
		draft_status_label.text = "DRAFT LOCKED   ·   %d STARTER(S)" % draft.picks.size()
	else:
		draft_status_label.text = "ROUND %d / %d   ·   DRAFT 1-3 STARTERS" % [
			int(draft.round_idx) + 1, int(draft.rounds_total)]
	# Legacy banner.
	if legacy_payload != null and not legacy_payload.is_empty():
		legacy_banner.text = "LEGACY ARMED: %s '%s' from %s — joins the first drafted unit" % [
			String(legacy_payload.get("kind", "")), String(legacy_payload.get("id", "")),
			String(legacy_payload.get("from", ""))]
		legacy_banner.visible = true
	else:
		legacy_banner.visible = false
	_rebuild_cards(draft, db)
	_rebuild_roster(draft, db)
	_update_dial(draft)
	_update_draft_controls(draft)


## Live payout-multiplier preview: what the multiplier WOULD lock at if you breached now, by the
## CURRENT pick count (3->x1.00, 2->x1.25, 1->x1.60). Mirrors draft._finalize's mapping without
## mutating the model. 0 picks reads x1.00 (the floor) until at least one is taken.
func _update_dial(draft) -> void:
	var n: int = draft.picks.size()
	var mult: int = E.DRAFT_PAYOUT_X3
	match n:
		1: mult = E.DRAFT_PAYOUT_X1
		2: mult = E.DRAFT_PAYOUT_X2
		_: mult = E.DRAFT_PAYOUT_X3
	var f: float = float(mult) / 100.0
	dial_label.text = "PAYOUT  x%0.2f%s" % [f, ("  (LOCKED)" if draft.finished else "  NOW")]
	# Fewer picks => more of the bar lit; lerp CYAN->AMBER as risk climbs (capped at AMBER).
	var risk: float = 0.0
	match n:
		1: risk = 1.0
		2: risk = 0.5
		_: risk = 0.0
	dial_bar_lit.size.x = 120.0 + 240.0 * risk
	dial_bar_lit.color = Pal.CYAN.lerp(Pal.AMBER, risk)


## Enable/label the control bar for the current Draft state. TAKE enabled only with a card selected
## AND a live round; DECLINE only mid-round; STOP & BREACH only at picks>=1; QUICK DRAFT mid-round.
## When finished, the whole bar greys out (the breach overlay drives from here).
func _update_draft_controls(draft) -> void:
	var live: bool = not draft.finished and not draft.current_choices.is_empty()
	ctl_take.disabled = not (live and _selected_idx >= 0 and _selected_idx < draft.current_choices.size())
	ctl_take.add_theme_color_override("font_color", Pal.CYAN if not ctl_take.disabled else Pal.DIM)
	ctl_decline.disabled = not live
	ctl_breach.disabled = draft.picks.size() < 1
	ctl_breach.add_theme_color_override("font_color", Pal.AMBER if not ctl_breach.disabled else Pal.DIM)
	ctl_breach.tooltip_text = "" if not ctl_breach.disabled else "DRAFT AT LEAST ONE"
	ctl_auto.disabled = not live


## Rebuild the 3 DRAFT_CANDIDATE_CARDs from draft.current_choices. Each card: faction-cyan ring +
## archetype glyph header, AMBER callsign, DIM role line, a CYAN stat block (HP/MOVE/ACC/MASS), and
## TRAIT_CHIPs colored by polarity (positive=CYAN, negative=ALERT_RED, mixed=AMBER). The card body
## is a Button so a first tap previews (selected = AMBER border) and TAKE/second-tap commits.
func _rebuild_cards(draft, db) -> void:
	for c in card_row.get_children():
		c.queue_free()
	_card_buttons.clear()
	var choices: Array = draft.current_choices
	for i in range(choices.size()):
		var u = choices[i]
		var card := Button.new()
		card.focus_mode = Control.FOCUS_NONE
		card.custom_minimum_size = Vector2(228, 360)   # W5-1: taller to seat the portrait region
		card.clip_text = false
		card.add_theme_stylebox_override("normal", _card_stylebox(false))
		card.add_theme_stylebox_override("hover", _card_stylebox(false))
		card.add_theme_stylebox_override("pressed", _card_stylebox(true))
		card.add_theme_stylebox_override("disabled", _card_stylebox(false))
		var idx := i
		card.pressed.connect(func(): _on_card_pressed(idx, draft))
		# Card content (a child Control so the Button styling holds the frame).
		var content := Control.new()
		content.position = Vector2(12, 10)
		content.mouse_filter = Control.MOUSE_FILTER_IGNORE
		card.add_child(content)
		# Faction-cyan ring + archetype glyph header.
		var ring := ColorRect.new()
		ring.color = Pal.FAC_PLAYER
		ring.position = Vector2(0, 0)
		ring.size = Vector2(204, 4)
		content.add_child(ring)
		var glyph := _label("[ %s ]" % _arch_glyph(String(u.archetype_id)), Pal.FAC_PLAYER, 18)
		glyph.position = Vector2(0, 6)
		content.add_child(glyph)
		var callsign := _label(String(u.name), Pal.AMBER, 16)
		callsign.position = Vector2(0, 30)
		content.add_child(callsign)
		var role := _label(_role_line(db, String(u.archetype_id)), Pal.DIM, 11)
		role.position = Vector2(0, 50)
		content.add_child(role)
		# STAT BLOCK (HP / MOVE / ACC / MASS), CYAN.
		var base: Dictionary = db.archetype(String(u.archetype_id)).get("baseStats", {})
		var stat := _label("HP %d    MOVE %d\nACC %d    MASS %s" % [
			int(u.max_hp), int(base.get("move", 0)), int(u.effective_accuracy(db)),
			String(base.get("mass", "medium")).to_upper()], Pal.CYAN, 13)
		stat.position = Vector2(0, 66)
		content.add_child(stat)
		# W5-1 PORTRAIT REGION — the archetype character art (a NEW art layer, larger than the 64px board
		# token), filling the empty lower half of the dossier card. FAC_PLAYER ring; drop-in contract:
		# assets/final/portrait_<archetype>.png wins, else the placeholder. Fills below the stat block.
		var portrait := _portrait_frame(String(u.archetype_id), Pal.FAC_PLAYER, 140, 168)
		portrait.position = Vector2(28, 104)
		content.add_child(portrait)
		# TRAIT_CHIP stack (polarity tell) — a compact strip along the card bottom, under the portrait.
		var chips := _trait_chips(db, u)
		var cy := 286
		if chips.is_empty():
			var none := _label("NO NOTED TRAITS", Pal.DIM, 12)
			none.position = Vector2(0, cy)
			content.add_child(none)
		else:
			for chip in chips:
				chip.position = Vector2(0, cy)
				content.add_child(chip)
				cy += 18
		card_row.add_child(card)
		_card_buttons.append(card)
	_apply_card_selection()


## A TAP on a candidate card: first tap previews (selected = AMBER border, enables TAKE); a second
## tap on the SAME card commits the take (two-tap, matching InputIntent). Mirrors the spec's
## inspect->take idiom so touch + click behave identically.
func _on_card_pressed(idx: int, draft) -> void:
	if draft.finished:
		return
	if _selected_idx == idx:
		emit_signal("draft_take", idx)   # second tap = commit
		return
	_selected_idx = idx
	_apply_card_selection()
	_update_draft_controls(draft)


## Re-skin the card borders for the current selection (selected = solid AMBER 2px; others default).
func _apply_card_selection() -> void:
	for i in range(_card_buttons.size()):
		var b: Button = _card_buttons[i]
		var sel := (i == _selected_idx)
		b.add_theme_stylebox_override("normal", _card_stylebox(sel))
		b.add_theme_stylebox_override("hover", _card_stylebox(sel))


## Rebuild the CELL_ROSTER_STRIP: filled slots (glyph + callsign + HP) for each pick, dashed
## FAC_PLAYER "OPEN" slots for the remaining DRAFT_MAX_STARTERS capacity.
func _rebuild_roster(draft, db) -> void:
	for c in roster_row.get_children():
		c.queue_free()
	var picks: Array = draft.picks
	for u in picks:
		roster_row.add_child(_roster_slot_filled(u))
	for _i in range(E.DRAFT_MAX_STARTERS - picks.size()):
		roster_row.add_child(_roster_slot_open())


func _roster_slot_filled(u) -> Panel:
	var p := Panel.new()
	p.custom_minimum_size = Vector2(170, 56)
	var sb := StyleBoxFlat.new()
	sb.bg_color = Pal.FRAME_BG
	sb.border_color = Pal.FAC_PLAYER
	sb.set_border_width_all(1)
	p.add_theme_stylebox_override("panel", sb)
	# W5-3: a 40px archetype mini-token per filled slot (the board token art, not a text glyph).
	var tok := _mini_token(String(u.archetype_id), 40)
	tok.position = Vector2(8, 8)
	p.add_child(tok)
	var g := _label(String(u.name), Pal.AMBER, 13)
	g.position = Vector2(54, 6)
	p.add_child(g)
	var hp := _label("HP %d/%d" % [int(u.hp), int(u.max_hp)], Pal.CYAN, 12)
	hp.position = Vector2(54, 30)
	p.add_child(hp)
	return p


func _roster_slot_open() -> Panel:
	var p := Panel.new()
	p.custom_minimum_size = Vector2(170, 56)
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(Pal.FRAME_BG.r, Pal.FRAME_BG.g, Pal.FRAME_BG.b, 0.4)
	sb.border_color = Pal.FAC_PLAYER
	sb.set_border_width_all(1)
	sb.border_width_left = 1
	p.add_theme_stylebox_override("panel", sb)
	var g := _label("OPEN", Pal.DIM, 13)
	g.position = Vector2(8, 6)
	p.add_child(g)
	var sub := _label("recruit in-run", Pal.DIM, 11)
	sub.position = Vector2(8, 30)
	p.add_child(sub)
	return p


## Show the BREACH_CONFIRM overlay over the draft: final cell list + LOCKED payout + open-slot
## count + [BREACH — GO]/[BACK]. `finalized` true (picks==3 or rounds spent) hides BACK behind a
## DIM "DRAFT LOCKED" — the only forward exit is GO (no dead end; ESC still abandons to menu).
func show_breach_confirm(picks: Array, payout_mult: int, open_slots: int, finalized: bool) -> void:
	if breach_overlay == null:
		return
	draft_root.visible = true
	var lines: Array = ["ALL UNITS — STANDING BY. CONFIRM THE CELL:", ""]
	for u in picks:
		lines.append("  • %s  [%s]  HP %d/%d" % [String(u.name), String(u.archetype_id), int(u.hp), int(u.max_hp)])
	lines.append("")
	lines.append("PAYOUT MULTIPLIER: x%0.2f  (LOCKED)" % (float(payout_mult) / 100.0))
	if open_slots > 0:
		lines.append("OPEN SLOTS: %d — fill by recruiting in-run" % open_slots)
	breach_body.text = "\n".join(lines)
	breach_overlay.visible = true
	# BACK only when not finalized; otherwise DRAFT LOCKED.
	breach_back_btn.visible = not finalized
	breach_back_btn.disabled = finalized
	breach_locked_label.visible = finalized


## Lock the BREACH — GO button (the ~0.3s loading-lock so a double-tap can't double-fire the run).
func lock_breach() -> void:
	if breach_go_btn != null:
		breach_go_btn.disabled = true
		breach_go_btn.text = "[ BREACHING… ]"
	if breach_back_btn != null:
		breach_back_btn.disabled = true


func hide_breach_confirm() -> void:
	if breach_overlay != null:
		breach_overlay.visible = false


## Tear down the whole draft surface (called when the run begins — the camera feed takes over).
func hide_draft_surface() -> void:
	if draft_root != null:
		draft_root.visible = false
	hide_breach_confirm()


# ============================ public screens ==================================
func show_draft(run) -> void:
	var lines: Array = ["The cell, vetted over comms before the breach:", ""]
	for u in run.squad:
		lines.append("  • %s  [%s]  HP %d/%d  L%d" % [u.name, u.archetype_id, u.hp, u.max_hp, u.level])
	lines.append("")
	lines.append("Payout multiplier: x%d (drafting fewer raises it)." % run.draft_payout_mult)
	_present("DRAFT — %d STARTERS" % run.squad.size(), lines, Pal.AMBER)


func show_shop(run, stock: Array = []) -> void:
	# W3-1: render the REAL rotating stock (ids from content/items), not the old phantom
	# field_kit/stim_patch. `stock` is the controller's _shop_stock() for this car; fall back to a
	# generic line if none was passed (spectator chrome only — the interactive path uses econ choices).
	var lines: Array = ["A fence works the aisle. Scrip talks.", ""]
	if stock.is_empty():
		lines.append("  Stock rotates each car.")
	else:
		for iid in stock:
			lines.append("  [ %s ]   %d scrip" % [_humanize_id(String(iid)), E.MARKET_BUY_SCRIP_COST])   # W5-6
	lines.append("")
	lines.append("On hand: %d scrip / %d supplies / %d tools" % [_c(run, "scrip"), _c(run, "supplies"), _c(run, "tools")])
	_present("BLACK-MARKET SHOP", lines, Pal.CYAN)


func show_workshop(run) -> void:
	_present("WORKSHOP / ARMORY", [
		"Bolt on what the last car left behind.",
		"",
		"  [ reinforced_plating ]  %d scrip" % E.WORKSHOP_UPGRADE_SCRIP_COST,
		"  [ sharpened_edge ]      %d scrip" % E.WORKSHOP_UPGRADE_SCRIP_COST,
		"",
		"On hand: %d scrip" % _c(run, "scrip"),
	], Pal.CYAN)


func show_bourgeois(run) -> void:
	_present("BOURGEOIS LOUNGE", [
		"A first-class passenger, cornered. The cell watches you.",
		"",
		"  [ SPARE ]  Order falls — the long game.",
		"  [ KILL  ]  +%d scrip, Order rises." % E.BOURGEOIS_KILL_SCRIP,
		"",
		"Order: %d" % run.order,
	], Pal.AMBER)


func show_recruit(run) -> void:
	_present("SANCTUARY — RECRUIT", [
		"A sympathetic citizen offers to join the uprising.",
		"",
		"  [ ACCEPT ]  fills a slot; counts toward Liberation.",
		"  [ DECLINE ] keep the cell tight.",
		"",
		"Squad: %d" % run.squad.size(),
	], Pal.CYAN)


func show_event(run) -> void:
	# W3-8: events are now DATA-DRIVEN (each event car authors its own prompt + options with distinct
	# outcomes — a resource find, a trait a survivor teaches, a tunnel that skips a car, or a trap that
	# springs an ambush). The interactive option surface (show_econ_choices) renders the authored beat;
	# this is the flavor intro before it.
	_present("EVENT", [
		"The corridor forks on a choice.",
		"",
		"  Some paths pay in scrip or supplies; some teach the cell a trick,",
		"  cut a shortcut through the train — or spring a trap.",
		"",
		"Tools: %d" % _c(run, "tools"),
	], Pal.CYAN)


func show_rest(run) -> void:
	_present("MED-CAR — REST", [
		"A moment between cars. Patch the wounded.",
		"",
		"  [ REST ]  -%d supplies, heal the cell +%d HP each." % [E.REST_HEAL_SUPPLY_COST, E.REST_HEAL_AMOUNT],
		"",
		"Supplies: %d" % _c(run, "supplies"),
	], Pal.AMBER)


func show_ending(run, ending_id: int, ending_name: String) -> void:
	var col := ending_tone(ending_id)
	var survivors: int = 0
	for u in run.squad:
		if u != null and not u.dead:
			survivors += 1
	_present("ENDING — %s" % ending_name, [
		_ending_blurb(ending_id),
		"",
		"Survivors: %d / %d" % [survivors, run.squad.size()],
		"Final Order: %d" % run.order,
		"Cars cleared: %d" % run.position,
	], col, 0.0)   # the ending sticks (no auto-dismiss)
	_arm_ending_wash(ending_id)


## The TONE COLOR for each of the FIVE endings (S6-1; ART_BIBLE §3 color language). PURE function of
## the ending id — no node touches, so the headless meta_smoke can assert all five select a tone
## without a SceneTree. The chrome contract never changes; only the feed re-tints:
##   LOSS         — ALERT_RED, the feed dies hard (scan-tear / signal-loss alarm).
##   HARD_STOP    — cold steel CYAN, the Core dead, the train stopped — bleak, finished.
##   SEIZE_ENGINE — AMBER, a new order, captured-not-killed — ambiguous, yours.
##   PYRRHIC      — AMBER, you won but it was written in your own people — bittersweet.
##   LIBERATION   — CYAN, whole and free — the kindest ending of all.
func ending_tone(ending_id: int) -> Color:
	match ending_id:
		E.EndingId.LOSS:         return Pal.ALERT_RED
		E.EndingId.HARD_STOP:    return Pal.CYAN
		E.EndingId.SEIZE_ENGINE: return Pal.AMBER
		E.EndingId.PYRRHIC:      return Pal.AMBER
		E.EndingId.LIBERATION:   return Pal.CYAN
		_:                       return Pal.AMBER


## Tint + reveal the full-screen tone wash behind the ending card. LOSS reads as a heavier ALERT_RED
## alarm (the feed dies); the wins read as a faint CYAN/AMBER whole-or-bittersweet glow. On-screen-only
## (ending_wash is null-safe so a stray headless call is inert).
func _arm_ending_wash(ending_id: int) -> void:
	if ending_wash == null:
		return
	var tone := ending_tone(ending_id)
	# LOSS is a distinct, heavier alarm wash; the wins are a gentle low-opacity tint.
	var alpha := 0.20 if ending_id == E.EndingId.LOSS else 0.12
	ending_wash.color = Color(tone.r, tone.g, tone.b, alpha)
	ending_wash.visible = true


## S6-2 — the AFTER-ACTION PAYOUT LEDGER, shown on the same card surface AFTER the ending card on the
## first ENTER/CLICK. The controller has already run the REAL reconciliation (award + enshrine + stats
## + persist); this is pure presentation of the resulting `ledger` dict it hands over:
##   { won, verdict, survivors, squad_size, fallen, cars, order, base, per_car, mult, award, total }
## Itemizes what the run banked (BASE + PER-CAR x DRAFT MULT = TOTAL) + the new meta-currency total +
## the fallen-enshrined line, in the ops-console after-action voice. The tone wash carries over from the
## ending card (kept lit) so the verdict's color persists under the ledger. On-screen-only.
func show_payout(ledger: Dictionary) -> void:
	var won: bool = bool(ledger.get("won", false))
	var col: Color = Pal.CYAN if won else Pal.ALERT_RED
	var mult: int = int(ledger.get("mult", 100))
	var lines: Array = [
		"AFTER-ACTION — uplink dumping the ledger before it goes dark.",
		"",
		"VERDICT: %s" % String(ledger.get("verdict", "")),
		"Survivors: %d / %d    ·    Order: %d    ·    Cars cleared: %d" % [
			int(ledger.get("survivors", 0)), int(ledger.get("squad_size", 0)),
			int(ledger.get("order", 0)), int(ledger.get("cars", 0))],
		"",
		"SALVAGE RECOVERED",
		"  BASE          +%d" % int(ledger.get("base", 0)),
		"  PER-CAR       +%d   (%d cleared)" % [int(ledger.get("per_car", 0)), int(ledger.get("cars", 0))],
		"  x DRAFT       x%0.2f" % (float(mult) / 100.0),
		"  ─────────────────",
		"  TOTAL         +%d META" % int(ledger.get("award", 0)),
		"",
		"META-CURRENCY: %d" % int(ledger.get("total", 0)),
		"%d operative(s) enshrined to Memorial." % int(ledger.get("fallen", 0)),
	]
	_present("AFTER-ACTION LEDGER", lines, col, 0.0)   # sticks like the ending card
	# Keep the ending-tone wash lit under the ledger (presentation continuity); never re-hide it here.


# ============================ helpers ==========================================
func _present(title: String, lines: Array, col: Color, dismiss: float = 4.0) -> void:
	if title_label == null:
		return
	title_label.text = title
	title_label.add_theme_color_override("font_color", col)
	body_label.text = "\n".join(lines)
	if prompt_label != null:
		prompt_label.visible = false   # cleared per-screen; the ending sets its own prompt
	panel.visible = true
	_auto_dismiss = dismiss


## Show the actionable control hint on the sticky ending panel (on-screen-only; the controller
## calls this from _show_ending once the run resolves so the return-to-console exit is discoverable).
func set_ending_prompt(text: String) -> void:
	if prompt_label != null:
		prompt_label.text = text
		prompt_label.visible = true


func hide_screen() -> void:
	if panel != null:
		panel.visible = false
	if ending_wash != null:
		ending_wash.visible = false


func _label(text: String, col: Color, size: int) -> Label:
	var l := Label.new()
	l.text = text
	l.add_theme_color_override("font_color", col)
	l.add_theme_font_size_override("font_size", size)
	return l


func _c(run, kind: String) -> int:
	return int(run.currency.get(kind, 0))


# ============================ draft-surface helpers ===========================
## A control/card button restyled to the ops look, emitting via the passed Callable on press.
func _draft_button(text: String, col: Color, on_press: Callable) -> Button:
	var b := Button.new()
	b.text = text
	b.focus_mode = Control.FOCUS_NONE
	b.add_theme_font_size_override("font_size", 14)
	# W5-7: the full per-state font + StyleBox set (default/hover/focus/pressed/disabled) so a screen
	# button never falls back to the engine-default grey. ART_BIBLE tokens only (FRAME_BG@85 / FRAME_
	# BORDER / AMBER / FRAME_INSET / DIM). `col` is the resting label color the caller picks (CYAN/AMBER).
	b.add_theme_color_override("font_color", col)
	b.add_theme_color_override("font_hover_color", Pal.AMBER)
	b.add_theme_color_override("font_pressed_color", Pal.FRAME_BG)   # invert on the AMBER pressed fill
	b.add_theme_color_override("font_focus_color", Pal.AMBER)
	b.add_theme_color_override("font_disabled_color", Pal.DIM)
	b.custom_minimum_size = Vector2(150, 32)
	b.add_theme_stylebox_override("normal", _btn_state_box("normal"))
	b.add_theme_stylebox_override("hover", _btn_state_box("hover"))
	b.add_theme_stylebox_override("pressed", _btn_state_box("pressed"))
	b.add_theme_stylebox_override("focus", _btn_state_box("focus"))
	b.add_theme_stylebox_override("disabled", _btn_state_box("disabled"))
	b.pressed.connect(on_press)
	return b


## The per-state screen-button frame (W5-7). ART_BIBLE §2/§3 chrome: FRAME_BG@85 base + a 2px
## FRAME_INSET top edge (the console-panel tell); hover/focus brighten the border to AMBER; pressed
## inverts to an AMBER fill; disabled dims the base. One place so every screen button reads the same.
func _btn_state_box(state: String) -> StyleBoxFlat:
	var sb := StyleBoxFlat.new()
	sb.set_corner_radius_all(2)
	sb.content_margin_left = 12
	sb.content_margin_right = 12
	sb.content_margin_top = 6
	sb.content_margin_bottom = 6
	match state:
		"hover":
			sb.bg_color = Color(Pal.FRAME_INSET.r, Pal.FRAME_INSET.g, Pal.FRAME_INSET.b, 0.30)
			sb.border_color = Pal.AMBER
			sb.set_border_width_all(1)
			sb.border_width_top = 2
		"pressed":
			sb.bg_color = Color(Pal.AMBER.r, Pal.AMBER.g, Pal.AMBER.b, 0.90)
			sb.border_color = Pal.AMBER
			sb.set_border_width_all(1)
		"focus":
			sb.bg_color = Color(Pal.FRAME_BG.r, Pal.FRAME_BG.g, Pal.FRAME_BG.b, 0.85)
			sb.border_color = Pal.AMBER
			sb.set_border_width_all(1)
		"disabled":
			sb.bg_color = Color(Pal.FRAME_BG.r, Pal.FRAME_BG.g, Pal.FRAME_BG.b, 0.50)
			sb.border_color = Pal.FRAME_BORDER
			sb.set_border_width_all(1)
		_:  # normal
			sb.bg_color = Color(Pal.FRAME_BG.r, Pal.FRAME_BG.g, Pal.FRAME_BG.b, 0.85)
			sb.border_color = Pal.FRAME_BORDER
			sb.set_border_width_all(1)
			sb.border_width_top = 2
	return sb


# ============================ ART-LAYER helpers (Wave 5) ======================
## Portrait / mini-token / flavor art loading (W5-1/W5-2/W5-3/W5-14/W5-15) + raw-id humanizing (W5-6).
## On-screen-only (headless never instances RunScreens). The texture loader mirrors car_view.gd's
## drop-in contract WITHOUT coupling to the renderer node: final art wins over the placeholder, .png
## over .svg, so a final-art PNG dropped at res://assets/final/<stem>.png Just Works with no code churn.
const _FINAL_DIR := "res://assets/final/"
const _PLACEHOLDER_DIR := "res://assets/placeholders/"
const _TEX_EXTS := [".png", ".svg"]
const _ARCH_IDS := ["bruiser", "marksman", "saboteur", "steward", "firebrand"]

## First existing texture for `stem` in drop-in order (final-png > final-svg > placeholder-png >
## placeholder-svg), or null. Never throws.
func _load_tex(stem: String) -> Texture2D:
	for dir in [_FINAL_DIR, _PLACEHOLDER_DIR]:
		for ext in _TEX_EXTS:
			var p: String = dir + stem + ext
			if ResourceLoader.exists(p):
				var r = load(p)
				if r is Texture2D:
					return r
	return null

## The DRAFT/DOSSIER character portrait for an archetype (W5-1): portrait_<arch>, falling back to
## portrait_bruiser (the generic player portrait) so an unknown archetype never renders blank.
func _portrait_texture(arch_id: String) -> Texture2D:
	for stem in ["portrait_" + arch_id, "portrait_bruiser"]:
		var t := _load_tex(stem)
		if t != null:
			return t
	return null

## A framed character portrait: a Panel with a `ring_col` ring around a TextureRect (named "Portrait")
## sized w×h showing the archetype art. Used by draft cards (FAC_PLAYER), the recruit dossier
## (FAC_NEUTRAL) and the level-up header (FAC_PLAYER). Larger art layer than the 64px board token.
func _portrait_frame(arch_id: String, ring_col: Color, w: int, h: int) -> Panel:
	var frame := Panel.new()
	frame.custom_minimum_size = Vector2(w + 8, h + 8)
	frame.size = Vector2(w + 8, h + 8)
	frame.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(Pal.FRAME_BG.r, Pal.FRAME_BG.g, Pal.FRAME_BG.b, 0.90)
	sb.border_color = ring_col
	sb.set_border_width_all(2)
	sb.set_corner_radius_all(2)
	frame.add_theme_stylebox_override("panel", sb)
	var tr := TextureRect.new()
	tr.name = "Portrait"
	tr.texture = _portrait_texture(arch_id)
	tr.position = Vector2(4, 4)
	tr.size = Vector2(w, h)
	tr.custom_minimum_size = Vector2(w, h)
	tr.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	tr.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	tr.mouse_filter = Control.MOUSE_FILTER_IGNORE
	frame.add_child(tr)
	return frame

## A small archetype board-token glyph (W5-3/W5-14): the unit_<arch> token at `sz` px — a real
## texture (never tofu). Falls back to the generic player token so it never renders blank.
func _mini_token(arch_id: String, sz: int) -> TextureRect:
	var tr := TextureRect.new()
	tr.name = "Glyph"
	var t := _load_tex("unit_" + arch_id)
	if t == null:
		t = _load_tex("unit_bruiser")
	tr.texture = t
	tr.custom_minimum_size = Vector2(sz, sz)
	tr.size = Vector2(sz, sz)
	tr.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	tr.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	tr.mouse_filter = Control.MOUSE_FILTER_IGNORE
	return tr

## Extract a bracketed archetype id from a dossier line like "Vasquez-04   [marksman]", or "" if none
## of the known archetype ids is bracketed. Lets the recruit/deploy glyphs resolve from data already
## passed (no cross-lane change needed).
func _arch_from_bracket(text: String) -> String:
	for a in _ARCH_IDS:
		if text.contains("[" + a + "]"):
			return a
	return ""

## Human labels for the ability-effect KINDS that would otherwise leak as raw snake_case into level-up
## copy (the controller's _ability_blurb passes unknown kinds through verbatim). Anything absent is
## Title-cased by _humanize_id, so NO snake_case id ever reaches a screen (W5-6).
const _EFFECT_LABELS := {
	"damage_bonus": "bonus damage",
	"damage_bonus_vs_flank": "bonus damage when flanking",
	"damage_bonus_vs_status": "bonus damage vs afflicted",
	"melee_attack": "melee strike",
	"ranged_attack": "ranged shot",
	"guaranteed_crit": "guaranteed crit",
	"ignore_cover": "ignores cover",
	"grant_cover": "grants cover",
	"grant_ap": "grants an action",
	"ap_on_ally_kill": "action on an ally kill",
	"clear_status": "clears a status",
	"slam_force_bonus": "harder slams",
	"self_recoil": "self recoil",
	"place_charge": "place a demolition charge",
	"detonate_all_charges": "detonate all charges",
	"electrify": "electrify water",
	"ignite_gas": "ignite gas",
	"spawn_hazard": "seed a hazard",
	"spawn_enemy": "deploy a unit",
	"stabilize": "stabilize the downed",
	"immobilize": "immobilize a target",
	"hack": "hack a machine",
	"reaction": "reaction shot",
	"targeted_strike": "targeted strike",
	"momentum_grants": "momentum reward",
	"momentum_gain_on_ally_death": "momentum on an ally death",
}

## Convert a raw id token to human copy: a curated effect label if known, else Title Case (which strips
## the snake_case form). Never returns a string containing an underscore.
func _humanize_id(id: String) -> String:
	if _EFFECT_LABELS.has(id):
		return String(_EFFECT_LABELS[id])
	return id.capitalize()

## Replace every snake_case id token inside `text` with human copy (W5-6) — the last line before pixels,
## so no raw effect-kind/shop id survives into on-screen level-up / shop copy. Right-to-left rewrite so
## earlier match offsets stay valid. Pure, on-screen-only.
func _scrub_ids(text: String) -> String:
	var re := RegEx.new()
	if re.compile("[a-z][a-z0-9]*(?:_[a-z0-9]+)+") != OK:
		return text
	var out := text
	var results := re.search_all(text)
	for i in range(results.size() - 1, -1, -1):
		var m: RegExMatch = results[i]
		out = out.substr(0, m.get_start()) + _humanize_id(m.get_string()) + out.substr(m.get_end())
	return out


## The candidate-card frame: default = FRAME_BORDER edge; selected = solid AMBER 2px + faint
## AMBER inner wash (the §5 chrome panel + corner-tick bracket reading as a dossier still-frame).
func _card_stylebox(selected: bool) -> StyleBoxFlat:
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(Pal.FRAME_INSET.r, Pal.FRAME_INSET.g, Pal.FRAME_INSET.b, 0.18 if selected else 0.10)
	sb.border_color = Pal.AMBER if selected else Pal.FRAME_BORDER
	sb.set_border_width_all(2 if selected else 1)
	sb.set_corner_radius_all(2)
	sb.content_margin_left = 12
	sb.content_margin_top = 10
	sb.content_margin_right = 12
	sb.content_margin_bottom = 10
	return sb


## A short ASCII glyph stem for an archetype (mirrors the unit_<archetype> token family; placeholder
## until the final UNIT_TEX header art drops in). Stable, deterministic.
func _arch_glyph(arch_id: String) -> String:
	match arch_id:
		"bruiser":   return "BRU"
		"marksman":  return "MRK"
		"saboteur":  return "SAB"
		"steward":   return "STW"
		"firebrand": return "FBR"
		_:           return arch_id.substr(0, 3).to_upper()


## The DIM role line under the callsign, from the archetype's authored role field.
func _role_line(db, arch_id: String) -> String:
	var a: Dictionary = db.archetype(arch_id)
	var role := String(a.get("role", ""))
	if role == "":
		return arch_id.capitalize()
	return "%s — %s" % [arch_id.capitalize(), role]


## Build the TRAIT_CHIP labels for a candidate (revealed traits only; hidden betrayer never shown).
## Polarity drives the fill color: positive=CYAN, negative=ALERT_RED, mixed=AMBER (§3 color language).
func _trait_chips(db, u) -> Array:
	var out: Array = []
	var shown: Array = u.revealed_traits if not u.revealed_traits.is_empty() else u.traits
	for tid in shown:
		var td: Dictionary = db.trait_def(String(tid))
		if td.is_empty() or td.get("hidden", false):
			continue
		var pol := String(td.get("polarity", "positive"))
		var col := Pal.CYAN
		match pol:
			"negative": col = Pal.ALERT_RED
			"mixed":    col = Pal.AMBER
			_:          col = Pal.CYAN
		var chip := _label("• %s" % String(td.get("name", tid)), col, 13)
		out.append(chip)
	return out


func _ending_blurb(ending_id: int) -> String:
	match ending_id:
		E.EndingId.LOSS:
			return "The cell is gone. The train rolls on without them."
		E.EndingId.HARD_STOP:
			return "The Core is dead. The train stops — cold, bleak, finished."
		E.EndingId.SEIZE_ENGINE:
			return "The Conductor lives, captured. A new order — uncertain, yours."
		E.EndingId.PYRRHIC:
			return "You won. The cost was written in your own people."
		E.EndingId.LIBERATION:
			return "A merciful run, whole and free. The kindest ending of all."
		_:
			return "The run is resolved."
