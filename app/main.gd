extends Node2D
## Phase-0 entry point + a tiny ASCII "operator feed" renderer.
## Runs the proof-of-concept car as a scripted, physics-only playthrough so the
## win-by-displacement gate (GDD §19) is VISIBLE, not just asserted in tests.
## Run headless:  godot --headless --path .
##
## W1-4: reachable from the menu (ASCII POC button), so a WINDOWED launch must not be a blank
## dead end — the feed now also renders into an on-screen text panel with a visible back
## affordance, and ANY key/click/touch returns to the menu (FLOW "ASCII_POC --> S1_01_HOME:
## back"). All of it is gated behind not-headless: the headless path prints the identical
## stdout feed and quits exactly as before, so the suites stay byte-stable.

const SimState = preload("res://core/sim_state.gd")
const SimEntity = preload("res://core/sim_entity.gd")
const IntRng = preload("res://core/int_rng.gd")
const Enums = preload("res://core/sim_enums.gd")
const Physics = preload("res://core/physics_resolver.gd")
const Pal = preload("res://render/palette.gd")

const MENU_SCENE := "res://app/menu.tscn"   # the W1-4 back edge target

var _feed_lines: Array = []   # every feed line, mirrored from stdout (drives the on-screen panel)

func _ready() -> void:
	run_poc()
	if OS.has_feature("headless") or DisplayServer.get_name() == "headless":
		get_tree().quit()
	else:
		_build_onscreen_feed()

## The scripted POC playthrough (extracted from _ready so a headless test can drive it on an
## un-treed instance). Prints the operator feed AND mirrors it into _feed_lines — stdout is
## byte-identical to the pre-W1-4 output.
func run_poc() -> void:
	_out("\n############################################################")
	_out("#  COLDSPINE — CAR 07: COOLANT BAY   [OPERATOR FEED]        #")
	_out("#  Proof-of-concept: clear the car with ZERO gunfire.       #")
	_out("############################################################")

	var s := _build_poc_car()
	_render(s, "INITIAL FEED — 3 guards, a coolant tank (~), a rigged junction (=), an open coupling (X)")

	# ACTION 1 — Bruiser shoves G1 east (force 6).
	_out("\n>>> ORDER 1: Bruiser SHOVES guard g1 east (force 6)")
	_out("    predicted chain: g1 -> g2 -> tank shatters -> FLOOD -> junction ELECTRIFIES")
	var g1_id := _find(s, "g1")
	var preview = Physics.resolve_impulse(s, g1_id, Vector2i(1, 0), 6, true)
	_print_events(preview.events, s)
	var commit = Physics.resolve_impulse(s, g1_id, Vector2i(1, 0), 6, false)
	s.adopt(commit.state)
	_render(s, "AFTER ORDER 1 — water (.) floods the bay; soaked guards chain-shocked")

	# ACTION 2 — Bruiser shoves G3 off the train through the coupling gap.
	_out("\n>>> ORDER 2: Bruiser SHOVES guard g3 east (force 3) — into the open coupling")
	var g3_id := _find(s, "g3")
	if g3_id != -1:
		var c2 = Physics.resolve_impulse(s, g3_id, Vector2i(1, 0), 3, false)
		_print_events(c2.events, s)
		s.adopt(c2.state)
	_render(s, "AFTER ORDER 2 — coupling vented")

	var enemies := _count_enemies(s)
	_out("\n############################################################")
	if enemies == 0:
		_out("#  CAR CLEARED. Enemies remaining: 0. Shots fired: 0.       #")
		_out("#  PROOF-OF-FUN GATE: PASSED — won purely by displacement.  #")
	else:
		_out("#  CAR NOT CLEARED. Enemies remaining: %d                    #" % enemies)
	_out("############################################################\n")

## Print a feed line AND keep it for the on-screen panel. The print is verbatim — the headless
## stdout proof stays byte-identical.
func _out(line: String) -> void:
	print(line)
	_feed_lines.append(line)

# ---- on-screen feed panel (W1-4; never built headless) ----
## Render the accumulated feed into a scrollable mono panel with the back affordance. The
## whole panel is display chrome only — the POC already ran; this just makes it visible.
func _build_onscreen_feed() -> void:
	var layer := CanvasLayer.new()
	add_child(layer)
	var bg := ColorRect.new()
	bg.color = Pal.FRAME_BG
	bg.set_anchors_preset(Control.PRESET_FULL_RECT)
	layer.add_child(bg)
	var pad := MarginContainer.new()
	pad.set_anchors_preset(Control.PRESET_FULL_RECT)
	pad.add_theme_constant_override("margin_left", 32)
	pad.add_theme_constant_override("margin_top", 20)
	pad.add_theme_constant_override("margin_right", 32)
	pad.add_theme_constant_override("margin_bottom", 52)
	layer.add_child(pad)
	var scroll := ScrollContainer.new()
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	pad.add_child(scroll)
	var feed := Label.new()
	feed.text = "\n".join(PackedStringArray(_feed_lines))
	feed.add_theme_color_override("font_color", Pal.AMBER)
	feed.add_theme_font_size_override("font_size", 12)
	scroll.add_child(feed)
	# The visible BACK affordance (bottom bar) — the dead-end killer.
	var hint := Label.new()
	hint.text = "[ ANY KEY / CLICK ]  BACK TO CONSOLE"
	hint.add_theme_color_override("font_color", Pal.CYAN)
	hint.add_theme_font_size_override("font_size", 16)
	hint.set_anchors_preset(Control.PRESET_BOTTOM_LEFT)
	hint.position = Vector2(32, -40)
	hint.grow_vertical = Control.GROW_DIRECTION_BEGIN
	layer.add_child(hint)

## W1-4 back edge: any key / click / touch returns to the operator console. On-screen only —
## headless quit already happened in _ready, so this never fires in the suites.
func _input(event: InputEvent) -> void:
	if OS.has_feature("headless") or DisplayServer.get_name() == "headless":
		return
	var back := false
	if event is InputEventKey and event.pressed and not event.echo:
		back = true
	elif event is InputEventMouseButton and event.pressed:
		back = true
	elif event is InputEventScreenTouch and event.pressed:
		back = true
	if back:
		get_viewport().set_input_as_handled()
		get_tree().change_scene_to_file(MENU_SCENE)

# ---- POC car layout ----
func _build_poc_car() -> SimState:
	var s := SimState.new()
	s.init_grid(10, 5)
	s.rng = IntRng.new(0xC01D5)
	_unit(s, 1, 2, Enums.Mass.HEAVY, 12, Enums.Faction.PLAYER, "bruiser")
	_unit(s, 3, 2, Enums.Mass.LIGHT, 4, Enums.Faction.ENEMY, "g1")
	_unit(s, 4, 2, Enums.Mass.LIGHT, 4, Enums.Faction.ENEMY, "g2")
	_unit(s, 7, 1, Enums.Mass.MEDIUM, 8, Enums.Faction.ENEMY, "g3")
	_obj(s, 5, 2, Enums.Mass.MEDIUM, 3, true, Enums.OnBreak.FLOOD, 3, "tank")
	var j := _obj(s, 5, 3, Enums.Mass.ANCHORED, 99, false, Enums.OnBreak.NONE, 0, "junction")
	j.is_power_source = true
	s.tile(Vector2i(8, 1)).hazard = Enums.Hazard.GAP
	return s

func _unit(s: SimState, x: int, y: int, mass: int, hp: int, fac: int, nm: String) -> SimEntity:
	var e := SimEntity.new()
	e.is_unit = true; e.pos = Vector2i(x, y); e.mass = mass; e.hp = hp
	e.integrity = -1; e.faction = fac; e.name = nm
	s.add_entity(e)
	return e

func _obj(s: SimState, x: int, y: int, mass: int, integ: int, mv: bool, ob: int, bp: int, nm: String) -> SimEntity:
	var o := SimEntity.new()
	o.is_unit = false; o.pos = Vector2i(x, y); o.mass = mass; o.integrity = integ
	o.movable = mv; o.on_break = ob; o.break_param = bp
	o.faction = Enums.Faction.OBJECT; o.hp = -1; o.name = nm
	s.add_entity(o)
	return o

func _find(s: SimState, nm: String) -> int:
	for id in s.entity_ids_sorted():
		if s.entities[id].name == nm:
			return id
	return -1

func _count_enemies(s: SimState) -> int:
	var n := 0
	for id in s.entity_ids_sorted():
		var e: SimEntity = s.entities[id]
		if e.is_unit and e.faction == Enums.Faction.ENEMY:
			n += 1
	return n

# ---- ASCII feed ----
func _render(s: SimState, caption: String) -> void:
	_out("\n  " + caption)
	for y in range(s.height):
		var row := "  "
		for x in range(s.width):
			var t: SimTile = s.tile(Vector2i(x, y))
			var occ := s.occupant_at(Vector2i(x, y))
			var ch := "."  if t.has_layer(Enums.L_WATER) else " "
			if t.terrain == Enums.Terrain.WALL:
				ch = "#"
			elif t.hazard == Enums.Hazard.GAP:
				ch = "X"
			if occ != null:
				ch = _glyph(occ)
			row += ch + " "
		_out(row)

func _glyph(e: SimEntity) -> String:
	if not e.is_unit:
		if e.is_power_source: return "="
		if e.on_break == Enums.OnBreak.FLOOD: return "~"
		return "o"
	if e.faction == Enums.Faction.PLAYER: return "@"
	return "g"

func _print_events(events: Array, s: SimState) -> void:
	var names := {
		Enums.Ev.MOVE_STEP: "move", Enums.Ev.IMPACT_WALL: "WALL-IMPACT",
		Enums.Ev.COLLIDE_BODY: "BILLIARDS", Enums.Ev.OBJECT_BREAK: "SHATTER",
		Enums.Ev.FLOOD_TILE: "flood", Enums.Ev.SHOCK: "SHOCK!",
		Enums.Ev.EJECT: "EJECT-OFF-TRAIN", Enums.Ev.STATUS_APPLY: "status",
		Enums.Ev.OBJECT_DAMAGED: "obj-dmg", Enums.Ev.HAZARD_RAIL: "rail",
	}
	var floods := 0
	for ev in events:
		if ev.type == Enums.Ev.FLOOD_TILE:
			floods += 1
			continue
		var label: String = names.get(ev.type, str(ev.type))
		_out("      - %s %s" % [label, str(ev.data)])
	if floods > 0:
		_out("      - flood spread across %d tiles" % floods)
