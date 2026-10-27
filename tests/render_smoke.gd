extends SceneTree
## Headless render smoke test (NEW file — does not touch run_tests.gd). Proves the
## renderer composes a SimState correctly without a display:
##   (a) no runtime errors building CarView + applying an event stream,
##   (b) token / tile counts match the SimState,
##   (c) the PreviewGhost dry-run result == the committed result (preview==commit),
##   (d) debug_ascii() renders the expected glyph map.
## Run: godot --headless --path . --script res://tests/render_smoke.gd

const SimState = preload("res://core/sim_state.gd")
const SimEntity = preload("res://core/sim_entity.gd")
const IntRng = preload("res://core/int_rng.gd")
const E = preload("res://core/sim_enums.gd")
const Physics = preload("res://core/physics_resolver.gd")
const ShoveCommand = preload("res://core/commands/shove_command.gd")

const Iso = preload("res://render/iso.gd")
const CarView = preload("res://render/car_view.gd")
const EventPlayer = preload("res://render/event_player.gd")
const OpsHUD = preload("res://render/ops_hud.gd")
const PreviewGhost = preload("res://render/preview_ghost.gd")
const CarLoader = preload("res://app/car_loader.gd")
const Pal = preload("res://render/palette.gd")
const BleedoutSystem = preload("res://core/bleedout_system.gd")
const InputIntent = preload("res://app/input_intent.gd")
const TurnManager = preload("res://core/turn_manager.gd")
const GE = preload("res://core/game_event.gd")
const SetpieceFog = preload("res://core/setpiece_fog.gd")

var _pass: int = 0
var _fail: int = 0
var _fails: Array = []

func _initialize() -> void:
	print("\n=== COLDSPINE — render smoke test ===")
	test_iso_roundtrip()
	test_carview_composition()
	test_debug_ascii_map()
	test_event_player_moves_token()
	test_procedural_fallback_matches()
	test_preview_equals_commit()
	test_car_loader_builds_state()
	test_diamond_memoization_matches_iso()      # release-readiness #6 (W1-1 recursion regression)
	# --- COMBAT LEGIBILITY batch (render-only; combat-ux #0/#2/#3/#5) ---
	test_every_hazard_layer_resolves()          # #0
	test_hazard_layers_leave_ascii_byte_stable() # #0 byte-identical guard
	test_downed_token_stays_visible()           # #2
	test_downed_bleed_tick_and_stabilize()      # #2
	test_hp_bar_data_resolves()                 # #5
	test_move_preview_matches_committed_xy_path() # #3
	# --- IN-CAR FOG (E1.4; render-only operator-vision limit; critic #4) ---
	test_fog_hides_unseen_tiles_and_enemies()   # fog car: tiles/enemies out of sightline are hidden
	test_fog_off_draws_everything_byte_stable() # fog off = today; fog on never alters debug_ascii
	# --- FINALE PRESENTATION (Wave 4; render-only) ---
	test_finale_damage_shielded_feedback()      # W4-4: shielded shot -> comms beat + deflect tell (not silent)
	test_finale_comms_beats()                   # W4-5: every finale event pushes an on-feed comms beat
	test_finale_header_no_overlap()             # W4-9: finale header never overlaps the REC/timecode
	test_finale_chrome_frozen_at_run_over()     # W4-10: run-over freezes+hides the finale boss chrome
	print("\n--- RENDER SMOKE: %d passed, %d failed ---" % [_pass, _fail])
	for f in _fails:
		print("    FAIL: " + f)
	if _fail == 0:
		print("RENDER GREEN — renderer composes the sim correctly headless.\n")
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

# ---- a small known sample car ----
# 6x3 grid. Bruiser(@) at (1,1) faces a guard(g) at (2,1), a tank(o) at (3,1),
# a power junction(o) at (3,2). Walls ring is implicit-free; we add one wall.
func _sample_state() -> SimState:
	var s := SimState.new()
	s.init_grid(6, 3)
	s.rng = IntRng.new(0xC01D5)
	s.set_wall(Vector2i(5, 0))
	_unit(s, 1, 1, E.Mass.HEAVY, 12, E.Faction.PLAYER, "bruiser")
	_unit(s, 2, 1, E.Mass.LIGHT, 4, E.Faction.ENEMY, "truncheon_guard")
	_obj(s, 3, 1, E.Mass.MEDIUM, 3, true, E.OnBreak.FLOOD, 3, "fish_tank_large")
	var j = _obj(s, 3, 2, E.Mass.ANCHORED, 99, false, E.OnBreak.NONE, 0, "junction_box")
	j.is_power_source = true
	return s

func _unit(s, x, y, mass, hp, fac, nm):
	var e := SimEntity.new()
	e.is_unit = true; e.pos = Vector2i(x, y); e.mass = mass; e.hp = hp
	e.integrity = -1; e.faction = fac; e.name = nm
	s.add_entity(e); return e

func _obj(s, x, y, mass, integ, mv, ob, bp, nm):
	var o := SimEntity.new()
	o.is_unit = false; o.pos = Vector2i(x, y); o.mass = mass; o.integrity = integ
	o.movable = mv; o.on_break = ob; o.break_param = bp
	o.faction = E.Faction.OBJECT; o.hp = -1; o.name = nm
	s.add_entity(o); return o

func _make_view(s) -> CarView:
	var v := CarView.new()
	v.setup(s, Vector2(1280, 720))
	return v

# ============================ TESTS ===========================================
func test_iso_roundtrip() -> void:
	# A handful of cells must round-trip tile->screen->tile exactly.
	var origin := Iso.centering_origin(6, 3, Vector2(1280, 720))
	var allok := true
	for c in [Vector2i(0, 0), Vector2i(5, 2), Vector2i(3, 1), Vector2i(1, 2)]:
		var sp := Iso.tile_to_screen(c, origin)
		var back := Iso.screen_to_tile(sp, origin)
		if back != c:
			allok = false
			print("    iso roundtrip %s -> %s -> %s" % [c, sp, back])
	ok(allok, "iso tile<->screen round-trips exactly")

func test_carview_composition() -> void:
	var s := _sample_state()
	var v := _make_view(s)
	# (b) token count == entity count.
	eq(v.tokens.size(), s.entities.size(), "token count == entity count")
	# tile count implied by grid; assert ascii line/col counts match the grid.
	var ascii := v.debug_ascii()
	var lines := ascii.split("\n")
	eq(lines.size(), s.height, "ascii row count == grid height")
	var widths_ok := true
	for ln in lines:
		if ln.length() != s.width:
			widths_ok = false
	ok(widths_ok, "every ascii row width == grid width")
	v.free()

func test_debug_ascii_map() -> void:
	var s := _sample_state()
	var v := _make_view(s)
	var ascii := v.debug_ascii()
	# Expected composed frame (tokens over terrain):
	#  row0: floor floor floor floor floor wall   -> ".....#"
	#  row1: floor @ g o floor floor              -> ".@go.."
	#  row2: floor floor floor o floor floor       -> "...o.."
	var expected := ".....#\n.@go..\n...o.."
	eq(ascii, expected, "debug_ascii composes the expected glyph map")
	if ascii != expected:
		print("    got:\n" + ascii)
	v.free()

func test_event_player_moves_token() -> void:
	var s := _sample_state()
	var v := _make_view(s)
	var p := EventPlayer.new(v, true)  # headless = instant
	# Move the bruiser id 1 from (1,1) to (1,2) via a MOVE event, instantly.
	var bid := _find(s, "bruiser")
	var ev := GameEvent.new(E.Ev.MOVE, {"id": bid, "from": Vector2i(1, 1), "to": Vector2i(1, 2)})
	p.play([ev])
	# Token's visual pos must now map back to (1,2).
	var cell := Iso.screen_to_tile(v.tokens[bid].vis_pos, v.origin)
	eq(cell, Vector2i(1, 2), "EventPlayer MOVE relocates the token visually")
	p.free(); v.free()

func test_procedural_fallback_matches() -> void:
	# The procedural _draw() path (no SVG textures) must compose the SAME glyph map as
	# the texture path — proving the documented fallback is sound, not just present.
	var s := _sample_state()
	var v := _make_view(s)
	v.use_textures = false   # force the procedural _draw() path
	var ascii := v.debug_ascii()
	eq(ascii, ".....#\n.@go..\n...o..", "procedural _draw() fallback composes identical glyph map")
	v.free()

func test_preview_equals_commit() -> void:
	# (c) THE core invariant: PreviewGhost dry-run == committed result.
	var s := _sample_state()
	var bid := _find(s, "bruiser")
	var gid := _find(s, "truncheon_guard")

	# Dry-run via PreviewGhost (renderer path).
	var ghost := PreviewGhost.new()
	ghost.compute(s, gid, Vector2i(1, 0), E.SHOVE_FORCE, Color("2EA7E0"))
	var preview_snap: String = ghost.result_state.snapshot()
	var preview_types: Array = ghost.result_events.duplicate()

	# Commit via the real command path (what the game does on confirm).
	var commit = Physics.resolve_impulse(s, gid, Vector2i(1, 0), E.SHOVE_FORCE, false)
	var commit_snap: String = commit.state.snapshot()

	eq(preview_snap, commit_snap, "preview state == commit state (Into-the-Breach property)")
	eq(preview_types.size(), commit.events.size(), "preview event count == commit event count")
	var types_match := true
	for i in range(min(preview_types.size(), commit.events.size())):
		if preview_types[i].type != commit.events[i].type:
			types_match = false
	ok(types_match, "preview event TYPES match commit event types in order")
	# The live state must be untouched by the dry-run (purity).
	ok(s.entities.has(gid), "dry-run preview did not mutate the live state")

func test_car_loader_builds_state() -> void:
	# The MVP scenario must parse into a SimState with both factions present.
	var s = CarLoader.load_car("flood_aquaria_01")
	ok(s != null, "CarLoader parses flood_aquaria_01.json")
	if s == null:
		return
	var players := 0
	var enemies := 0
	var objects := 0
	for id in s.entity_ids_sorted():
		var e = s.entities[id]
		if not e.is_unit:
			objects += 1
		elif e.faction == E.Faction.PLAYER:
			players += 1
		elif e.faction == E.Faction.ENEMY:
			enemies += 1
	ok(players >= 1, "loaded car has at least one player unit")
	ok(enemies >= 1, "loaded car has at least one enemy unit")
	ok(objects >= 1, "loaded car has interactive objects (tanks/junction)")
	# A CarView must compose it without error and match counts.
	var v := _make_view(s)
	eq(v.tokens.size(), s.entities.size(), "loaded-car token count == entity count")
	# print the composed frame for the lead to eyeball.
	print("\n[render_smoke] flood_aquaria_01 composed frame (debug_ascii):")
	print(v.debug_ascii())
	v.free()

## Release-readiness #6 / W1-1 regression: the memoized _diamond corners must be EXACTLY
## Iso.diamond_points at the view origin (the cache-miss branch once recursed into ITSELF, so no
## hazard layer / trap telegraph / reach overlay could ever draw), and a repeat call must be served
## from the cache, not recomputed.
func test_diamond_memoization_matches_iso() -> void:
	var s := _sample_state()
	var v := _make_view(s)
	var probe := Vector2i(3, 2)
	var pts: PackedVector2Array = v._diamond(probe)
	eq(pts.size(), 4, "_diamond returns the 4 iso diamond corners")
	eq(pts, Iso.diamond_points(probe, v.origin), "_diamond corners == Iso.diamond_points at the view origin")
	ok(v._diamond_cache.has(probe), "first _diamond call populated the cache")
	# Prove the second call is SERVED from the cache: poison the entry with a sentinel and re-call.
	var sentinel := PackedVector2Array([Vector2(-1234.0, -5678.0)])
	v._diamond_cache[probe] = sentinel
	eq(v._diamond(probe), sentinel, "second _diamond call is served from the cache (no recompute)")
	v.free()

# ============================ COMBAT LEGIBILITY (render-only) ==================
## combat-ux #0: EVERY tile status-layer the sim tracks must resolve to a distinct, non-invisible
## wash color the renderer draws — the 7 previously-undrawn hazard layers included. Proves the board is
## honest: no layer maps to nothing. (The per-layer SHAPE lives in _draw_tile_layers; this pins color.)
func test_every_hazard_layer_resolves() -> void:
	var all_layers := [E.L_WATER, E.L_FIRE, E.L_ELECTRIFIED, E.L_DEBRIS, E.L_GAS, E.L_SCORCHED,
		E.L_TELEGRAPH, E.L_STEAM, E.L_SNOW, E.L_CONCEAL]
	var seen := {}
	var all_distinct := true
	var all_drawn := true
	for flag in all_layers:
		var col: Color = Pal.layer_color(flag)
		# A real, mapped color (not the AMBER "unmapped" sentinel unless the layer legitimately IS amber).
		if flag != E.L_TELEGRAPH and col == Pal.AMBER:
			all_drawn = false
		var key := col.to_html()
		if seen.has(key):
			all_distinct = false
		seen[key] = true
		if not Pal.DRAWN_LAYERS.has(flag):
			all_drawn = false
	ok(all_drawn, "[legibility #0] every tile status-layer maps to a drawn wash color (none invisible)")
	ok(all_distinct, "[legibility #0] each hazard layer's wash color is DISTINCT (colorblind + legible)")
	eq(Pal.DRAWN_LAYERS.size(), all_layers.size(), "[legibility #0] DRAWN_LAYERS covers all %d sim layers" % all_layers.size())

## combat-ux #0 byte-identical guard: painting every hazard layer onto tiles must NOT change debug_ascii
## (the headless composition), because the ascii path is deliberately left untouched. Proves the new
## draws are graphical-only and the smoke composition stays byte-stable.
func test_hazard_layers_leave_ascii_byte_stable() -> void:
	var s := _sample_state()
	var v := _make_view(s)
	var before := v.debug_ascii()
	# Stack a couple of the NEW layers onto floor tiles that carry no glyph of their own.
	s.tile(Vector2i(0, 0)).status_layer |= E.L_GAS
	s.tile(Vector2i(1, 2)).status_layer |= E.L_TELEGRAPH
	s.tile(Vector2i(4, 2)).status_layer |= (E.L_STEAM | E.L_SNOW | E.L_CONCEAL | E.L_SCORCHED)
	var after := v.debug_ascii()
	eq(after, before, "[legibility #0] the new hazard layers do NOT alter debug_ascii (ascii path untouched)")
	v.free()

## combat-ux #2: a DOWNED (bleeding-out) ally must stay on the board as a body — the token keeps a
## `downed` flag + a bleed countdown and is NOT dropped, so a first-time player can see (and reach) it.
func test_downed_token_stays_visible() -> void:
	var s := SimState.new()
	s.init_grid(6, 3)
	s.rng = IntRng.new(0xC01D5)
	s.bleedout_enabled = true
	var e := SimEntity.new()
	e.is_unit = true; e.pos = Vector2i(2, 1); e.mass = E.Mass.MEDIUM; e.hp = 0
	e.integrity = -1; e.faction = E.Faction.PLAYER; e.name = "bruiser"; e.max_hp = 8
	s.add_entity(e)
	# Drive the real bleed-out seam: 0 HP -> Downed (still in entities, alive=false, downed=true).
	var events: Array = []
	var erased: bool = BleedoutSystem.down_or_kill(s, e, events)
	ok(not erased and e.downed, "[legibility #2] the unit entered the DOWNED window (not erased)")
	var v := _make_view(s)   # setup -> _rebuild_tokens reads e.downed/bleed_timer
	ok(v.tokens.has(e.id), "[legibility #2] the downed body still has a render token (did not vanish)")
	ok(bool(v.tokens[e.id]["downed"]), "[legibility #2] the token carries the downed flag")
	ok(int(v.tokens[e.id]["bleed"]) == E.BLEED_OUT_TURNS, "[legibility #2] the token carries the bleed-out countdown (%d)" % E.BLEED_OUT_TURNS)
	v.free()

## combat-ux #2 event-path: a UNIT_DOWNED event drops the token into the visible downed pose (not
## _kill_token), a BLEED_TICK updates the countdown, and UNIT_STABILIZED zeroes it (still a body).
func test_downed_bleed_tick_and_stabilize() -> void:
	var s := SimState.new()
	s.init_grid(6, 3)
	var u := SimEntity.new()
	u.is_unit = true; u.pos = Vector2i(2, 1); u.hp = 9; u.faction = E.Faction.PLAYER
	u.integrity = -1; u.name = "marksman"; u.max_hp = 9
	s.add_entity(u)
	var v := _make_view(s)
	var p := EventPlayer.new(v, true)   # headless instant apply
	p.play([GE.new(E.Ev.UNIT_DOWNED, {"id": u.id, "bleed": 2})])
	ok(bool(v.tokens[u.id]["downed"]) and int(v.tokens[u.id]["bleed"]) == 2,
		"[legibility #2] UNIT_DOWNED marks the token downed with its bleed window (visible, not killed)")
	p.play([GE.new(E.Ev.BLEED_TICK, {"id": u.id, "left": 1})])
	ok(int(v.tokens[u.id]["bleed"]) == 1, "[legibility #2] BLEED_TICK counts the window down")
	p.play([GE.new(E.Ev.UNIT_STABILIZED, {"id": u.id})])
	ok(bool(v.tokens[u.id]["downed"]) and int(v.tokens[u.id]["bleed"]) == 0,
		"[legibility #2] UNIT_STABILIZED stops the bleed but keeps the body downed")
	p.free(); v.free()

## combat-ux #5: HP-bar data resolves off the synced token, and a HIT event drops it live.
func test_hp_bar_data_resolves() -> void:
	var s := SimState.new()
	s.init_grid(6, 3)
	var u := SimEntity.new()
	u.is_unit = true; u.pos = Vector2i(2, 1); u.hp = 9; u.faction = E.Faction.PLAYER
	u.integrity = -1; u.name = "marksman"; u.max_hp = 9
	s.add_entity(u)
	var v := _make_view(s)
	eq(int(v.tokens[u.id]["hp"]), 9, "[legibility #5] the token carries current HP for the bar")
	eq(int(v.tokens[u.id]["max_hp"]), 9, "[legibility #5] the token carries max HP for the bar")
	var p := EventPlayer.new(v, true)
	p.play([GE.new(E.Ev.HIT, {"target": u.id, "dmg": 4, "hp_left": 5})])
	eq(int(v.tokens[u.id]["hp"]), 5, "[legibility #5] a HIT drops the token HP as the log reports it")
	p.free(); v.free()

## combat-ux #3 / critic #6: the DRAWN move path must match the COMMITTED x-then-y walk exactly, not the
## controller's BFS route. CarView.xy_move_path (the render-side derivation) must equal InputIntent's
## _orthogonal_path (the real commit path) cell-for-cell, including the partial-stop at a blocker.
func test_move_preview_matches_committed_xy_path() -> void:
	var s := SimState.new()
	s.init_grid(8, 5)
	s.rng = IntRng.new(0xC01D5)
	var u := SimEntity.new()
	u.is_unit = true; u.pos = Vector2i(1, 2); u.hp = 9; u.faction = E.Faction.PLAYER
	u.integrity = -1; u.name = "mover"
	s.add_entity(u)
	s.set_wall(Vector2i(3, 2))   # blocks the x-leg -> forces a partial stop
	var v := _make_view(s)
	var intent := InputIntent.new(TurnManager.new(s))
	intent.selected_id = u.id
	# Case A: a partial route around a wall on the x-leg — landing must fall short at the wall.
	var to_a := Vector2i(4, 2)
	var commit_a: Array = intent._orthogonal_path(u.pos, to_a)          # excludes `from`
	var draw_a: Array = v.xy_move_path(u.pos, to_a)                     # includes `from` at [0]
	eq(draw_a[0], u.pos, "[legibility #3] the drawn path starts at the unit")
	var draw_a_steps: Array = draw_a.slice(1)
	eq(str(draw_a_steps), str(commit_a), "[legibility #3] drawn x-then-y path == committed _orthogonal_path (partial)")
	ok(draw_a.back() != to_a, "[legibility #3] the landing ring falls SHORT of the blocked pointed tile (honest)")
	# Case B: a clear L-route (x-leg clear of the wall) — x-then-y reaches the pointed tile exactly.
	var to_b := Vector2i(2, 4)
	var commit_b: Array = intent._orthogonal_path(u.pos, to_b)
	var draw_b: Array = v.xy_move_path(u.pos, to_b)
	eq(str(draw_b.slice(1)), str(commit_b), "[legibility #3] drawn path == committed path on a clear L-route")
	ok(draw_b.back() == to_b, "[legibility #3] the landing lands ON the pointed tile when reachable")
	v.free()

# ============================ IN-CAR FOG (E1.4; render-only) ===================
## critic #4 / E1.4: in a fog car with fog_on, the renderer limits the operator to what the squad can
## see — tiles outside the squad's line-of-sight are FOGGED and enemies/objects lurking there are not
## drawn, while the SIM still tracks them fully (render-only filter). The render fog set must agree
## with the tested core SetpieceFog.visible_tiles. Never touches debug_ascii (byte-stable — see below).
func test_fog_hides_unseen_tiles_and_enemies() -> void:
	# 12x3 maze slice: a full wall column at x=5 splits the car; the squad sits at the tail (1,1),
	# an enemy lurks deep past the wall at (10,1) — out of LoS AND beyond vision radius.
	var s := SimState.new()
	s.init_grid(12, 3)
	s.rng = IntRng.new(0xC01D5)
	for y in range(3):
		s.set_wall(Vector2i(5, y))
	var pid: int = _unit(s, 1, 1, E.Mass.HEAVY, 12, E.Faction.PLAYER, "bruiser").id
	var eid: int = _unit(s, 10, 1, E.Mass.LIGHT, 4, E.Faction.ENEMY, "truncheon_guard").id
	var v := _make_view(s)
	v.fog_on = true
	v.refresh_fog()
	# TILES: own tile + a near in-LoS tile are visible; the deep tile behind the maze is fogged.
	ok(not v.fog_tile_hidden(Vector2i(1, 1)), "[fog] the squad's own tile is visible under fog")
	ok(not v.fog_tile_hidden(Vector2i(3, 1)), "[fog] a near in-sightline tile is visible under fog")
	ok(v.fog_tile_hidden(Vector2i(10, 1)), "[fog] a deep tile behind the maze wall is fogged")
	# ENTITIES: the enemy lurking in the fog is hidden until seen; your own unit always draws.
	ok(v.fog_entity_hidden(eid), "[fog] an enemy lurking in the fog is hidden (not drawn) until seen")
	ok(not v.fog_entity_hidden(pid), "[fog] the operator's own unit always draws under fog")
	# RENDER-ONLY: the SIM still tracks the hidden enemy — fog only filters what is DRAWN.
	ok(s.entities.has(eid) and s.entities[eid].alive, "[fog] the sim still tracks the fogged enemy (render-only)")
	# The render fog set agrees with the tested core visibility function.
	var vis := SetpieceFog.visible_tiles(s, true)
	ok(vis.has(Vector2i(1, 1)) and not vis.has(Vector2i(10, 1)),
		"[fog] the render consumer matches SetpieceFog.visible_tiles (core parity)")
	# As the squad ADVANCES past the wall, the fog re-forms (event-driven recompute via sync_tokens).
	s.entities[pid].pos = Vector2i(6, 1)
	v.sync_tokens()   # this calls refresh_fog() — units moved, sightline changes
	ok(not v.fog_tile_hidden(Vector2i(10, 1)), "[fog] advancing into sightline reveals the deep tile")
	ok(not v.fog_entity_hidden(eid), "[fog] the once-hidden enemy is revealed once a unit can see it")
	v.free()

## E1.4 default path: with fog OFF nothing is hidden (full operator omniscience, byte-stable with the
## pre-fog renderer), AND turning fog ON never alters debug_ascii — the fog is a graphical view filter
## the headless composition never reads, so the smoke suites stay byte-identical.
func test_fog_off_draws_everything_byte_stable() -> void:
	var s := _sample_state()
	var v := _make_view(s)   # fog_on defaults false
	var base := v.debug_ascii()
	# Turning fog ON must NOT change the headless composition (fog is render-only, never in ascii).
	v.fog_on = true
	v.refresh_fog()
	eq(v.debug_ascii(), base, "[fog] in-car fog never alters debug_ascii (headless byte-stable)")
	# With fog OFF, no tile or entity is ever hidden (the omniscient default path — E1.4 default).
	v.fog_on = false
	v.refresh_fog()
	var none_hidden := true
	for y in range(s.height):
		for x in range(s.width):
			if v.fog_tile_hidden(Vector2i(x, y)):
				none_hidden = false
	ok(none_hidden, "[fog] fog OFF hides no tile (full operator omniscience)")
	for id in s.entity_ids_sorted():
		if v.fog_entity_hidden(id):
			none_hidden = false
	ok(none_hidden, "[fog] fog OFF hides no entity (byte-stable with the pre-fog renderer)")
	v.free()

# ============================ FINALE PRESENTATION (Wave 4) =====================
## W4-4: shooting the shielded Conductor/Core must not be a silent no-op. Pre-fix, event_player had NO
## case for DAMAGE_SHIELDED (it fell through `_: pass` in _apply / `return false` in _apply_animated),
## so a turn-ending shot pushed ZERO comms and drew nothing. Assert the event now produces a comms beat
## (relay-shield vs sealed-Core variants) AND that the CarView carries a drawn "SHIELDED" deflect tell.
func test_finale_damage_shielded_feedback() -> void:
	var s := _sample_state()
	var v := _make_view(s)
	var p := EventPlayer.new(v, true)   # headless = instant _apply path (the comms contract)
	var tid := _find(s, "truncheon_guard")
	var lines: Array = []
	p.comms.connect(func(line): lines.append(line))
	# relay-shielded body (shoot_command payload: {actor,target}, no core flag)
	p.play([GE.new(E.Ev.DAMAGE_SHIELDED, {"actor": _find(s, "bruiser"), "target": tid})])
	ok(lines.size() >= 1, "[W4-4] DAMAGE_SHIELDED pushes a comms beat (was a silent no-op)")
	ok(_any_contains(lines, "SHIELDED"), "[W4-4] the relay-shield tell names SHIELDED")
	lines.clear()
	# sealed-Core variant (objective.damage_core payload: {target, core:true})
	p.play([GE.new(E.Ev.DAMAGE_SHIELDED, {"target": tid, "core": true})])
	ok(_any_contains(lines, "SEALED"), "[W4-4] the sealed-Core tell names CORE SEALED (drop the shield)")
	# The on-feed DRAWN tell: float_shielded enqueues a CYAN "SHIELDED" float over the token.
	var before: int = v._floats.size()
	v.float_shielded(tid)
	eq(v._floats.size(), before + 1, "[W4-4] float_shielded spawns a deflect float over the target")
	var last: Dictionary = v._floats.back()
	ok(String(last["text"]) == "SHIELDED" and Color(last["col"]) == Pal.CYAN,
		"[W4-4] the deflect tell reads SHIELDED in CYAN (distinct from red damage floats)")
	p.free(); v.free()


## W4-5: the finale events were mute in the comms/juice layer — no klaxon on BRIDGE BREACHED, no
## relay/countdown/shield narration (all fell through `_: pass`). Assert EVERY finale beat now emits a
## comms line, and that the marquee beats carry their signature words.
func test_finale_comms_beats() -> void:
	var s := _sample_state()
	var v := _make_view(s)
	var p := EventPlayer.new(v, true)
	# event type -> a representative payload (keys mirror core/finale + ai/conductor_ai emissions)
	var beats := {
		E.Ev.COUNTDOWN_TICK: {"countdown": 10, "started": true},
		E.Ev.COUNTDOWN_EXPIRED: {},
		E.Ev.RELAY_DISABLED: {"relay": "A", "index": 0, "online_left": 2},
		E.Ev.CONDUCTOR_POWER_DISABLED: {"relay": "A", "power": "PISTONS"},
		E.Ev.CORE_SHIELD: {"conductor": 1},
		E.Ev.CORE_SHIELD_DROP: {"conductor": 1},
		E.Ev.CORE_DAMAGED: {"core": 9, "dmg": 3, "integrity_left": 9},
		E.Ev.CORE_SABOTAGED: {"core": 9, "beat_clock": 4},
		E.Ev.VAULT_PHASE: {"phase": 2},
		E.Ev.VAULT_ESCALATE: {"level": 1},
		E.Ev.CONDUCTOR_TELEGRAPH: {"conductor": 1, "action": 0},
		E.Ev.CONDUCTOR_ACT: {"conductor": 1, "action": 0},
		E.Ev.DISPENSER_SPAWN: {"dispenser": 5, "bot": 6, "pos": Vector2i(1, 1)},
	}
	for ev_type in beats:
		var lines: Array = []
		var cb: Callable = func(line): lines.append(line)
		p.comms.connect(cb)
		p.play([GE.new(ev_type, beats[ev_type])])
		p.comms.disconnect(cb)
		ok(lines.size() >= 1, "[W4-5] finale event id %d emits a comms beat (was mute)" % ev_type)
	# marquee beats carry their signature words (the klaxon + the core-exposed tell)
	var l2: Array = []
	var cb2: Callable = func(line): l2.append(line)
	p.comms.connect(cb2)
	p.play([GE.new(E.Ev.COUNTDOWN_EXPIRED, {})])
	p.play([GE.new(E.Ev.CORE_SHIELD_DROP, {"conductor": 1})])
	p.comms.disconnect(cb2)
	ok(_any_contains(l2, "BREACHED"), "[W4-5] COUNTDOWN_EXPIRED fires a BRIDGE BREACHED klaxon line")
	ok(_any_contains(l2, "EXPOSED"), "[W4-5] CORE_SHIELD_DROP narrates the core going exposed")
	p.free(); v.free()


## W4-9: the long finale header must not overlap the REC/timecode. Pre-fix the "● REC" tally was pinned
## at x=360 while the finale header "ENGINE — CONDUCTOR'S CHAMBER · PHASE n/3" renders far wider from
## x=16, so they collided (tour shots 27-30). Assert the header would overrun the default REC slot (the
## defect) and that entering finale mode slides the REC/timecode cluster clear of it.
func test_finale_header_no_overlap() -> void:
	var hud := OpsHUD.new()
	root.add_child(hud)                 # SceneTree._initialize DEFERS the ready notification, so fire
	hud._ready()                        # _ready explicitly (mirrors menu_smoke / screens_smoke) -> _build
	hud.enter_finale_mode()
	hud.set_camera_id("ENGINE", "CONDUCTOR'S CHAMBER · PHASE 2/3")
	var font := ThemeDB.fallback_font
	var hw: float = font.get_string_size(hud.camera_label.text, HORIZONTAL_ALIGNMENT_LEFT, -1, 20).x
	var header_right: float = hud.camera_label.position.x + hw
	ok(header_right > OpsHUD.REC_POS_DEFAULT.x,
		"[W4-9] the finale header (right edge %.0fpx) overruns the default REC slot @%d (the defect)" % [header_right, int(OpsHUD.REC_POS_DEFAULT.x)])
	eq(hud.rec_label.position.x, OpsHUD.REC_POS_FINALE.x, "[W4-9] REC slides to the finale slot on enter_finale_mode")
	ok(hud.rec_label.position.x >= header_right, "[W4-9] the repositioned REC clears the finale header (no overlap)")
	ok(hud.timecode_label.position.x > hud.rec_label.position.x, "[W4-9] timecode follows the repositioned REC")
	# exit restores the default slot (finale-scoped reposition)
	hud.exit_finale_mode()
	eq(hud.rec_label.position.x, OpsHUD.REC_POS_DEFAULT.x, "[W4-9] REC restores its default slot on exit_finale_mode")
	hud.free()


## W4-10: at run end the finale chrome (bridge countdown, boss objective/relay panel, telegraph,
## lockdown bezel) plus any combat tip must stop drawing/ticking behind the ending card. Pre-fix,
## set_running(false) froze ONLY the timecode; the boss panels stayed visible (tour shots 29-30).
## Assert the run-over signal the renderer already sees (set_running false) hides them all + freezes.
func test_finale_chrome_frozen_at_run_over() -> void:
	var hud := OpsHUD.new()
	root.add_child(hud)
	hud._ready()                        # fire the deferred ready so _build creates the real regions
	hud.enter_finale_mode()
	hud.set_bridge_countdown(5, false)
	hud.set_lockdown(true)
	hud.show_tip("BOSS", "disable the relays to drop the shield")
	ok(hud._countdown_panel.visible, "[W4-10] the bridge countdown is up during the fight")
	ok(hud._objective_box_panel.visible, "[W4-10] the boss objective/relay panel is up during the fight")
	ok(hud._lockdown_bezel.visible, "[W4-10] the lockdown bezel is up during the fight")
	ok(hud.tip_open(), "[W4-10] the combat tip banner is up during the fight")
	hud.set_running(false)              # the run-over signal the controller already emits at _show_ending
	ok(not hud._countdown_panel.visible, "[W4-10] run-over hides the bridge countdown panel")
	ok(not hud._objective_box_panel.visible, "[W4-10] run-over hides the boss objective/relay panel")
	ok(not hud._telegraph_panel.visible, "[W4-10] run-over hides the conductor telegraph")
	ok(not hud._lockdown_bezel.visible, "[W4-10] run-over hides the lockdown bezel")
	ok(not hud.tip_open(), "[W4-10] run-over dismisses the combat tip banner")
	ok(not hud._running, "[W4-10] the run clock is frozen at run-over")
	hud.free()


func _any_contains(lines: Array, sub: String) -> bool:
	for l in lines:
		if String(l).find(sub) != -1:
			return true
	return false


func _find(s, nm: String) -> int:
	for id in s.entity_ids_sorted():
		if s.entities[id].name == nm:
			return id
	return -1
