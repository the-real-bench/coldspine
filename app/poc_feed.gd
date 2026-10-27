extends Node2D
## Phase-0 entry point + a tiny ASCII "operator feed" renderer.
## Runs the proof-of-concept car as a scripted, physics-only playthrough so the
## win-by-displacement gate (GDD §19) is VISIBLE, not just asserted in tests.
## Run headless:  godot --headless --path .

const SimState = preload("res://core/sim_state.gd")
const SimEntity = preload("res://core/sim_entity.gd")
const IntRng = preload("res://core/int_rng.gd")
const Enums = preload("res://core/sim_enums.gd")
const Physics = preload("res://core/physics_resolver.gd")

func _ready() -> void:
	print("\n############################################################")
	print("#  COLDSPINE — CAR 07: COOLANT BAY   [OPERATOR FEED]        #")
	print("#  Proof-of-concept: clear the car with ZERO gunfire.       #")
	print("############################################################")

	var s := _build_poc_car()
	_render(s, "INITIAL FEED — 3 guards, a coolant tank (~), a rigged junction (=), an open coupling (X)")

	# ACTION 1 — Bruiser shoves G1 east (force 6).
	print("\n>>> ORDER 1: Bruiser SHOVES guard g1 east (force 6)")
	print("    predicted chain: g1 -> g2 -> tank shatters -> FLOOD -> junction ELECTRIFIES")
	var g1_id := _find(s, "g1")
	var preview = Physics.resolve_impulse(s, g1_id, Vector2i(1, 0), 6, true)
	_print_events(preview.events, s)
	var commit = Physics.resolve_impulse(s, g1_id, Vector2i(1, 0), 6, false)
	s.adopt(commit.state)
	_render(s, "AFTER ORDER 1 — water (.) floods the bay; soaked guards chain-shocked")

	# ACTION 2 — Bruiser shoves G3 off the train through the coupling gap.
	print("\n>>> ORDER 2: Bruiser SHOVES guard g3 east (force 3) — into the open coupling")
	var g3_id := _find(s, "g3")
	if g3_id != -1:
		var c2 = Physics.resolve_impulse(s, g3_id, Vector2i(1, 0), 3, false)
		_print_events(c2.events, s)
		s.adopt(c2.state)
	_render(s, "AFTER ORDER 2 — coupling vented")

	var enemies := _count_enemies(s)
	print("\n############################################################")
	if enemies == 0:
		print("#  CAR CLEARED. Enemies remaining: 0. Shots fired: 0.       #")
		print("#  PROOF-OF-FUN GATE: PASSED — won purely by displacement.  #")
	else:
		print("#  CAR NOT CLEARED. Enemies remaining: %d                    #" % enemies)
	print("############################################################\n")

	if OS.has_feature("headless") or DisplayServer.get_name() == "headless":
		get_tree().quit()

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
	print("\n  " + caption)
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
		print(row)

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
		print("      - %s %s" % [label, str(ev.data)])
	if floods > 0:
		print("      - flood spread across %d tiles" % floods)
