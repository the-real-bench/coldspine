class_name CarView
extends Node2D
## Renders a SimState as an iso car (ART_BIBLE §3 color language, §7 sizing).
##
## Two-layer render:
##   - Tiles: terrain SVG texture if it imports, else a procedural diamond. Status
##     LAYERS (water/fire/electrified/debris) are ALWAYS procedural overlays — there
##     is no per-tile composited SVG, they stack on whatever terrain is under them.
##   - Entities: a token = faction ring (procedural) + archetype glyph (SVG texture
##     if one matches its name, else a procedural body) + status badges (procedural).
##
## EventPlayer drives animation by mutating each token's `vis_pos` (a float screen
## position) and `vis_status`; CarView reads the SimState for the authoritative
## layout and the token table for in-flight visual state. `debug_ascii()` composes a
## glyph map of the CURRENT visual scene — the headless proof of correct composition.

const E = preload("res://core/sim_enums.gd")
const Iso = preload("res://render/iso.gd")
const Pal = preload("res://render/palette.gd")
const SetpieceFog = preload("res://core/setpiece_fog.gd")

const ASSET_DIR := "res://assets/placeholders/"
# Final-art drop-in contract (ART_BIBLE §8 / MANIFEST): user-supplied final art in FINAL_DIR wins
# over the placeholder behind the same stem, and a raster .png wins over a .svg at the same stem.
# Drop `assets/final/<stem>.png` (then run --import once) and the game uses it; delete it and the
# placeholder returns. Zero code churn per delivered file.
const FINAL_DIR := "res://assets/final/"
const TEX_EXTS := [".png", ".svg"]   # probe order — raster final art beats a vector at the same stem

# Section-palette re-skin convention (ART_BIBLE §4): a terrain stem may ship per-section variants
# named `<stem>__s<N>` (N = 1..5, e.g. tile_floor__s2). When `section` is set, the variant wins;
# a missing variant falls back to the plain stem, so the 5-variant set can land file-by-file.
const SECTION_MIN := 1
const SECTION_MAX := 5

# The car's section (1..5) for the §4 surface re-skin; 0 = no section variant lookup (default,
# byte-stable with the pre-section pipeline). Set by the owner when it builds the car view.
var section: int = 0

# ART_BIBLE §7 logical token box: unit/enemy/object glyph art is drawn INTO this square (centered
# on the tile) regardless of the texture's native resolution — the binding size is this constant,
# not the file's pixel size, so 2x/hi-dpi final art needs no layout change.
const TOKEN_LOGICAL := 96.0

var state                       # SimState (authoritative layout)
var origin: Vector2 = Vector2.ZERO
var use_textures: bool = true   # set false to force the procedural path (smoke test toggles it)

# Per-entity visual token: { vis_pos:Vector2, vis_status:int, faction:int, is_unit:bool,
#                            name:String, alive:bool, vis_flash:float, vis_fade:float,
#                            vis_overwatch:bool }. Keyed by id.
#   vis_flash 0..1 : a transient white impact flash (decays to 0; on-screen animation only).
#   vis_fade  1..0 : a death/break fade-out (1 = solid, 0 = gone; on-screen animation only).
#   vis_overwatch  : render-only OVERWATCH eye tell (#21) — the live SimEntity.overwatch mirror.
# All default neutral (0 flash, 1 fade, no overwatch) so the headless composition + debug_ascii are
# unchanged (none of these are ever read by debug_ascii / sync, so the smoke read stays byte-stable).
var tokens: Dictionary = {}

# The currently-selected player unit (on-screen interactive highlight). -1 = none.
# Purely a draw-time pulse ring; never read by debug_ascii / sync, so headless stays byte-stable.
var highlight_id: int = -1
var _hl_t: float = 0.0   # highlight pulse phase (advanced by the owner each frame)

# --- COMBAT TARGETING LEGIBILITY (#16; render-only, ART_BIBLE §3). A purely-visual highlight layer
# the owner (RunController) recomputes whenever a unit+action is armed, then draws over the feed:
#   reach    : Array[Vector2i] reachable MOVE tiles (faint CYAN rings, from MoveCommand reachability)
#   push     : Array[Vector2i] the 4 adjacent SHOVE/SLAM push tiles (faint CYAN brackets)
#   shoot    : Array[{ cell:Vector2i, pct:int, shield:int }] shootable enemies — pct = to-hit %,
#              shield = 0 none / 1 half cover / 2 full cover (the cover/flank shield glyph)
#   armed    : the InputIntent.Mode currently armed (drives which layer is emphasized), -1 = none
# All elements are <=50% opacity and NEVER ALERT_RED (these are predicted outcomes, not live danger —
# the §3 reserved-red gate). Headless never instances CarView, so this never touches the test path; it
# is also never read by debug_ascii/sync_tokens, so the smoke composition stays byte-stable.
const HL_MAX_OPACITY := 0.5      # ART_BIBLE §6.7 preview opacity ceiling — honored on every element
var hl_reach: Array = []
var hl_push: Array = []
var hl_shoot: Array = []
var hl_armed: int = -1

# --- MOVE PREVIEW (#22; render-only, ART_BIBLE §6.7 never-surprised). A lightweight path overlay the
# owner pushes when MOVE is armed + a destination is pointed: a dotted line from the unit to the
# destination + a destination ring (reuses the PreviewGhost dotted style/opacity). Pure draw-data —
# never read by debug_ascii/sync, so the headless composition stays byte-stable. <=50% opacity, CYAN
# (a predicted move, never ALERT_RED). Empty path = nothing drawn.
var move_path: Array = []         # Array[Vector2i] cells the move steps through (incl. destination)
var move_dest: Vector2i = Vector2i(-9999, -9999)   # the destination cell (drawn as a ring), or sentinel = none

# --- COMBAT JUICE (#23; render-only screen-space FX, ART_BIBLE §2 glitch-on-event, §3 chroma/scan-tear).
# All purely cosmetic timers the owner pokes (camera-cut into a car, OBJECT_BREAK / SHOCK in the committed
# stream, a car-clear win). Ticked by tick_visuals, drawn as a full-rect overlay in _draw. Headless never
# instances CarView, so none of this touches the byte-stable test path; nothing here is read by debug_ascii.
var _glitch_t: float = 0.0        # remaining glitch-tear/chroma-split time (0 = none)
var _glitch_dur: float = 0.0      # the glitch's full duration (for the fade ratio)
var _redout_t: float = 0.0        # remaining win redout-wipe time (a brief AMBER flash-to-clear)
var _redout_dur: float = 0.0
var _clear_stamp_t: float = 0.0   # remaining "CAR CLEAR" stamp time (an on-feed AMBER stamp on a win)
const GLITCH_DUR := 0.18          # ~2-4 frames at 60fps reads as a 0.12-0.20s tear; on-theme, cheap
const REDOUT_DUR := 0.55          # the win redout/clear wipe duration
const CLEAR_STAMP_DUR := 1.6      # how long the CAR CLEAR stamp holds on the feed

# --- FLOATING DAMAGE NUMBERS (combat-ux #5; render-only screen FX). A small pool of rising "-N"
# labels spawned on damage events by the animated EventPlayer path, decayed in tick_visuals, drawn on
# top. Purely cosmetic; headless never spawns them (the sync play() path does not) and nothing here is
# read by debug_ascii. Each entry: { pos:Vector2, text:String, col:Color, t:float }.
var _floats: Array = []
const FLOAT_DUR := 0.9        # seconds a damage number lives
const FLOAT_RISE := 46.0      # pixels it drifts up over its life
const FLOAT_MAX := 24         # hard cap so a long chain can't unbounded-grow the pool

# Texture cache: logical name -> Texture2D (or null if absent/failed).
var _tex_cache: Dictionary = {}

# Diamond-point cache (release-readiness #6): the 4 iso corners of a cell depend ONLY on the cell +
# origin, and origin changes once per car (setup). Caching them keys off Vector2i so the per-frame
# board redraw (fired every frame while a unit is selected — the highlight pulse) stops re-allocating
# a PackedVector2Array per tile per frame. Cleared whenever origin is (re)set. Zero change to WHAT is
# drawn — same points, just memoized.
var _diamond_cache: Dictionary = {}

# name -> texture filename stem mapping for entities (units/objects).
const UNIT_TEX := {
	"bruiser": "unit_bruiser", "marksman": "unit_marksman", "saboteur": "unit_saboteur",
	"steward": "unit_steward", "firebrand": "unit_firebrand",
}
const ENEMY_TEX := {
	"truncheon_guard": "enemy_truncheon", "riot_shield": "enemy_riot_shield",
	"net_gunner": "enemy_net_gunner", "enforcer": "enemy_enforcer", "hound": "enemy_hound",
	"sniper": "enemy_sniper", "drone_operator": "enemy_drone_op",
	"security_robot": "enemy_security_robot", "sentry_turret": "enemy_sentry_turret",
	# Section Captains + Conductor — keyed by the captains.json id (entities are named by id in
	# car_loader._place_enemy), each a distinct boss token whose mote tells its physics key. The bare
	# "captain" stays as a generic fallback for any unmapped/future captain.
	"captain_tail_warden": "enemy_captain_tail_warden",
	"captain_foreman": "enemy_captain_foreman",
	"captain_gardener": "enemy_captain_gardener",
	"captain_majordomo": "enemy_captain_majordomo",
	"captain_chief_of_security": "enemy_captain_chief",
	"the_conductor": "enemy_conductor",
	"captain": "enemy_captain",
}
const OBJ_TEX := {
	"fish_tank_large": "obj_fish_tank", "fish_tank_small": "obj_fish_tank",
	"tank": "obj_fish_tank", "junction": "obj_junction", "junction_box": "obj_junction",
	"barrel": "obj_barrel", "crate": "obj_crate", "table": "obj_table",
	"glass_partition": "obj_glass_partition",
	# Volatile objects keyed by their objects.json id (entities are named by id in
	# car_loader._place_object). Same-onBreak-role objects reuse the role EXEMPLAR art per the
	# §3.5 role-color contract; the distinct hazard sources get their own token. Without these the
	# id fell through to the obj_crate fallback — e.g. barrel_explosive (objects.json id) rendered
	# as a CRATE, not a barrel, in combat rooms.
	"barrel_explosive": "obj_barrel", "oxygen_tank": "obj_barrel", "alcohol_barrel": "obj_barrel",
	"coolant_tank": "obj_coolant_tank", "water_main": "obj_water_main", "gas_main": "obj_gas_main",
	# Light furniture reuses the table/crate exemplars (better than the bare crate fallback).
	"serving_cart": "obj_table", "bench": "obj_table", "chair": "obj_table", "locker": "obj_crate",
	# Topple props + remaining decor — each now has its own token (clears the guard's FALLBACK_OK).
	"weight_rack": "obj_weight_rack", "marble_statue": "obj_marble_statue", "chandelier": "obj_chandelier",
	"tree": "obj_tree", "hedge_wall": "obj_hedge_wall", "hedge_sculpture": "obj_hedge_sculpture",
	"bookshelf": "obj_bookshelf", "pottery_vase": "obj_pottery_vase", "planter": "obj_planter",
	"thin_ice": "obj_thin_ice",
}
# Status-badge icon registry: S_* bitflag (+ Pal.R_OVERWATCH) -> status_*.svg stem. The 14 icon
# SVGs carry the §6.1 color+shape contract (colorblind-safe silhouettes) that the current hue-only
# procedural badges do not; this map makes every icon resolvable through _tex() and guarded by
# tex_coverage_smoke. NOTE: badges still DRAW procedurally in _draw_status_badges — swapping the
# draw to these textures is the HUD pass's call, not the texture layer's.
# S_DOWNED and S_BLEEDING are the same death-window family and share status_bleeding.svg (sheet rule).
const STATUS_TEX := {
	E.S_PRONE: "status_prone", E.S_STUNNED: "status_stunned", E.S_SOAKED: "status_soaked",
	E.S_BURNING: "status_burning", E.S_SHOCKED: "status_shocked", E.S_POISONED: "status_poisoned",
	E.S_BLINDED: "status_blinded", E.S_CHILLED: "status_chilled", E.S_FROZEN: "status_frozen",
	E.S_DOWNED: "status_bleeding", E.S_BLEEDING: "status_bleeding",
	E.S_SUPPRESSED: "status_suppressed", E.S_BURIED: "status_buried", E.S_NETTED: "status_netted",
	Pal.R_OVERWATCH: "status_overwatch",
}

# Optional external preview overlay (PreviewGhost) drawn on top of the scene.
var preview = null

# ============================ IN-CAR FOG (Sub-Spec E1.4) =======================
# Render-only operator-vision limit for fog cars (Hedge Maze / heavy Steam rooms). The SIM knows the
# whole board; this ONLY filters what is DRAWN, so the operator loses omniscience: tiles outside the
# squad's line-of-sight draw as REMEMBERED terrain (a dark veil, with the live hazard layers on them
# suppressed), and enemy / object tokens standing in that fog are HIDDEN until a squad member sees
# them. Your own units (and their downed bodies) always draw. `fog_on` is set by the owner =
# (per-car inCarFog AND the operator's in_car_fog session toggle); when false, everything draws
# exactly as before — the byte-stable default path. NONE of this is read by debug_ascii / sync_tokens
# (the headless composition), so the smoke suites stay byte-identical.
var fog_on: bool = false
var _fog_visible: Dictionary = {}   # {Vector2i: true} tiles the operator currently SEES (fog_on only)


func setup(p_state, view_size: Vector2 = Vector2(1280, 720)) -> void:
	state = p_state
	origin = Iso.centering_origin(state.width, state.height, view_size)
	_diamond_cache.clear()   # origin moved — drop the memoized iso corners (release-readiness #6)
	_rebuild_tokens()
	refresh_fog()            # seed the E1.4 visible-tile set for the initial squad vantage (render-only)
	queue_redraw()


## Recompute the operator's visible-tile set from the LIVE sim (SetpieceFog.visible_tiles). Call on
## setup and after every token sync — units moving changes line-of-sight, so the fog re-forms as the
## squad advances (the event-driven recompute the spec asks for). Pure read of the sim (no mutation).
## When fog_on is false the set stays empty and every tile/token draws as today. Never touches the
## headless composition (debug_ascii / sync read it never). On-screen-only effect.
func refresh_fog() -> void:
	if not fog_on or state == null:
		_fog_visible = {}
		return
	_fog_visible = SetpieceFog.visible_tiles(state, true)


## Is `cell` currently fogged from the operator (fog_on AND outside the squad's sightline)? Render-only.
func fog_tile_hidden(cell: Vector2i) -> bool:
	return fog_on and not _fog_visible.has(cell)


## Should the entity `id`'s token be hidden by fog? Enemies / objects on a fogged tile are hidden
## until seen; the operator's OWN units (and their downed bodies) always draw — you always see your
## squad. Uses the entity's authoritative sim cell (the fog set is computed from those positions), so
## the sim keeps tracking a hidden enemy while the renderer simply does not paint it. Render-only.
func fog_entity_hidden(id: int) -> bool:
	if not fog_on:
		return false
	if state == null or not state.entities.has(id):
		return false
	var e = state.entities[id]
	if e.faction == E.Faction.PLAYER:
		return false
	return not _fog_visible.has(e.pos)

## Memoized iso diamond corners for a cell (release-readiness #6). Same points as Iso.diamond_points,
## cached so the per-frame board redraw stops re-allocating one PackedVector2Array per tile per frame.
func _diamond(cell: Vector2i) -> PackedVector2Array:
	var hit = _diamond_cache.get(cell)
	if hit != null:
		return hit
	var pts := Iso.diamond_points(cell, origin)
	_diamond_cache[cell] = pts
	return pts

## (Re)build the token table from the current SimState — call after a full state swap.
func _rebuild_tokens() -> void:
	tokens.clear()
	for id in state.entity_ids_sorted():
		var e = state.entities[id]
		tokens[id] = {
			"vis_pos": Iso.tile_to_screen(e.pos, origin),
			"vis_status": e.status,
			"faction": e.faction,
			"is_unit": e.is_unit,
			"name": e.name,
			"archetype_id": e.archetype_id,
			"alive": e.alive,
			"vis_flash": 0.0,
			"vis_fade": 1.0,
			"vis_overwatch": (e.is_unit and e.overwatch),
			"downed": e.downed,
			"bleed": e.bleed_timer,
			"hp": e.hp,
			"max_hp": e.max_hp,
		}
	queue_redraw()

## Sync tokens to the live state without resetting in-flight tween positions for
## survivors (used after a committed physics resolve adopts a new state). New ids
## are added; vanished ids are dropped.
func sync_tokens() -> void:
	# drop dead/removed
	for id in tokens.keys():
		if not state.entities.has(id):
			tokens.erase(id)
	for id in state.entity_ids_sorted():
		var e = state.entities[id]
		if tokens.has(id):
			tokens[id]["vis_pos"] = Iso.tile_to_screen(e.pos, origin)
			tokens[id]["vis_status"] = e.status
			tokens[id]["alive"] = e.alive
			tokens[id]["vis_overwatch"] = (e.is_unit and e.overwatch)
			tokens[id]["downed"] = e.downed
			tokens[id]["bleed"] = e.bleed_timer
			tokens[id]["hp"] = e.hp
			tokens[id]["max_hp"] = e.max_hp
		else:
			tokens[id] = {
				"vis_pos": Iso.tile_to_screen(e.pos, origin),
				"vis_status": e.status, "faction": e.faction,
				"is_unit": e.is_unit, "name": e.name, "archetype_id": e.archetype_id, "alive": e.alive,
				"vis_flash": 0.0, "vis_fade": 1.0,
				"vis_overwatch": (e.is_unit and e.overwatch),
				"downed": e.downed, "bleed": e.bleed_timer, "hp": e.hp, "max_hp": e.max_hp,
			}
	refresh_fog()   # E1.4 — units moved, so re-form the operator's sightline (render-only, no-op off fog)
	queue_redraw()

# ============================ ANIMATION SUPPORT ================================
## Advance the per-frame visual decays (impact flashes fade out, the highlight ring
## pulses). The on-screen driver calls this every _process; headless never does, so the
## token table the smoke test reads is untouched. Returns true if a redraw is warranted.
func tick_visuals(delta: float) -> bool:
	_hl_t += delta
	var dirty := false
	for id in tokens.keys():
		var tok: Dictionary = tokens[id]
		var f: float = float(tok.get("vis_flash", 0.0))
		if f > 0.0:
			tok["vis_flash"] = max(0.0, f - delta * 4.0)   # ~0.25s decay
			dirty = true
	if highlight_id >= 0:
		dirty = true
	# Combat-juice timers (#23) — glitch-tear / redout / CAR-CLEAR stamp decays.
	if _tick_juice(delta):
		dirty = true
	# Floating damage numbers (#5) — rise + fade, then reap.
	if not _floats.is_empty():
		var kept: Array = []
		for fl in _floats:
			fl["t"] = float(fl["t"]) - delta
			if fl["t"] > 0.0:
				kept.append(fl)
		_floats = kept
		dirty = true
	if dirty:
		queue_redraw()
	return dirty

## Set a token's screen position directly (the tween target setter). Safe if the id is gone.
func set_token_vis_pos(id: int, p: Vector2) -> void:
	if tokens.has(id):
		tokens[id]["vis_pos"] = p
		queue_redraw()

## Light a token's impact flash (1.0 = full white wash; decays via tick_visuals).
func flash_token(id: int, amount: float = 1.0) -> void:
	if tokens.has(id):
		tokens[id]["vis_flash"] = clampf(amount, 0.0, 1.0)
		queue_redraw()

## Set a token's death/break fade (1.0 solid → 0.0 gone). The tween drives this toward 0.
func set_token_fade(id: int, a: float) -> void:
	if tokens.has(id):
		tokens[id]["vis_fade"] = clampf(a, 0.0, 1.0)
		queue_redraw()

## The screen-space center of a grid cell in this view (for tween targets).
func cell_to_screen(cell) -> Vector2:
	return Iso.tile_to_screen(cell, origin)


# ============================ ISO DIRECTION RECONCILIATION (W7-iso-labels) =====
## The ON-SCREEN direction (normalized) for a SIM-SPACE unit direction, under the FLIPPED iso
## projection. The projection climbs forward (+x) UP the screen, so sim +x maps up-and-right and sim
## -x maps down-and-left — a setpiece JSON "left"/"right" (a sim-space belt/slope vector) therefore no
## longer means screen-left/right. Any renderer that orients a directional setpiece token MUST route
## through this (not the raw sim vector) so what draws matches the token's intended on-screen side.
## PURE (no instance state) — derived straight from Iso, so it is headless-testable. Zero(dir) -> Zero.
static func screen_dir(sim_dir: Vector2i) -> Vector2:
	if sim_dir == Vector2i.ZERO:
		return Vector2.ZERO
	var d: Vector2 = Iso.tile_to_screen(sim_dir, Vector2.ZERO) - Iso.tile_to_screen(Vector2i.ZERO, Vector2.ZERO)
	if d.length() < 0.0001:
		return Vector2.ZERO
	return d.normalized()


## A human ON-SCREEN side label ("UP" / "DOWN" / "LEFT" / "RIGHT" / "UP-RIGHT" …) for a sim-space
## direction under the flip — the reconciliation of a JSON "left"/"right" token to the side it actually
## renders. Godot screen-y is DOWN-positive, so a negative screen-y reads "UP". PURE + headless-testable.
static func screen_side_label(sim_dir: Vector2i) -> String:
	var sd: Vector2 = screen_dir(sim_dir)
	if sd == Vector2.ZERO:
		return "NONE"
	var parts: Array = []
	if sd.y < -0.35:
		parts.append("UP")
	elif sd.y > 0.35:
		parts.append("DOWN")
	if sd.x > 0.35:
		parts.append("RIGHT")
	elif sd.x < -0.35:
		parts.append("LEFT")
	return "-".join(parts) if not parts.is_empty() else "NONE"

## Set/clear the selected-unit highlight ring.
func set_highlight(id: int) -> void:
	highlight_id = id
	queue_redraw()

## Push the combat-legibility highlight layer (#16). `layer` is a pure draw-data dict the owner
## computed off the live state WITHOUT mutating it:
##   { reach:[Vector2i], push:[Vector2i], shoot:[{cell,pct,shield}], armed:InputIntent.Mode }
## Render-only — nothing here changes any sim/command outcome. On-screen-only.
func set_targeting_layer(layer: Dictionary) -> void:
	hl_reach = layer.get("reach", [])
	hl_push = layer.get("push", [])
	hl_shoot = layer.get("shoot", [])
	hl_armed = int(layer.get("armed", -1))
	queue_redraw()

## Clear the legibility layer (no unit/action armed). On-screen-only.
func clear_targeting_layer() -> void:
	hl_reach = []
	hl_push = []
	hl_shoot = []
	hl_armed = -1
	queue_redraw()

# ============================ MOVE PREVIEW (#22) ===============================
## Push the move-path overlay (#22): `path` is the Array[Vector2i] cells the move steps through and
## `dest` is the destination cell (drawn as a ring). Render-only — nothing here changes any sim/command
## outcome (the path is the owner's pure read of MoveCommand reachability). On-screen-only.
func set_move_preview(path: Array, dest: Vector2i) -> void:
	move_path = path
	move_dest = dest
	queue_redraw()

## Clear the move-path overlay (move disarmed / committed / cancelled). On-screen-only.
func clear_move_preview() -> void:
	move_path = []
	move_dest = Vector2i(-9999, -9999)
	queue_redraw()

# ============================ FLOATING DAMAGE NUMBERS (#5) =====================
## Spawn a rising damage number at a token's current screen pos (combat-ux #5). Called by the animated
## EventPlayer on HIT / IMPACT_WALL / COLLIDE_BODY / SHOCK / HAZARD_* so a struck token shows a "-N".
## Render-only, pooled + capped; never spawned on the headless play() path. On-screen-only.
func float_damage(id: int, amount: int, col: Color = Pal.ALERT_RED) -> void:
	if amount <= 0 or not tokens.has(id):
		return
	var p: Vector2 = tokens[id]["vis_pos"] + Vector2(0, -30)
	_floats.append({"pos": p, "text": "-%d" % amount, "col": col, "t": FLOAT_DUR})
	while _floats.size() > FLOAT_MAX:
		_floats.pop_front()
	queue_redraw()

## Spawn a rising "SHIELDED" deflect tell over a token whose incoming damage was GATED (finale
## relay-shield / sealed Core, W4-4). CYAN (data, "no effect") so it reads distinctly from the
## ALERT_RED damage floats — the on-feed answer to "why did my turn-ending shot do nothing?". Reuses
## the pooled + capped float system; never spawned on the headless play() path. On-screen-only.
func float_shielded(id: int) -> void:
	if not tokens.has(id):
		return
	var p: Vector2 = tokens[id]["vis_pos"] + Vector2(0, -30)
	_floats.append({"pos": p, "text": "SHIELDED", "col": Pal.CYAN, "t": FLOAT_DUR})
	while _floats.size() > FLOAT_MAX:
		_floats.pop_front()
	queue_redraw()

# ============================ COMBAT JUICE (#23) ===============================
## Fire a one-time glitch-tear / chroma-split (#23 — ART_BIBLE §2 glitch-on-event). The owner pokes
## this on the camera-cut INTO a car and on OBJECT_BREAK / SHOCK in the committed event stream.
## `strength` scales the tear amplitude (a camera-cut is gentler than a wall-shattering break). Purely
## cosmetic + decays in tick_visuals; never read by debug_ascii. On-screen-only.
func glitch(strength: float = 1.0) -> void:
	_glitch_dur = GLITCH_DUR
	_glitch_t = GLITCH_DUR * clampf(strength, 0.2, 2.0)
	queue_redraw()

## Fire the on-WIN flourish (#23): an AMBER "CAR CLEAR" stamp + a brief redout/clear wipe over the feed.
## Purely cosmetic; decays in tick_visuals. On-screen-only.
func win_flourish() -> void:
	_redout_dur = REDOUT_DUR
	_redout_t = REDOUT_DUR
	_clear_stamp_t = CLEAR_STAMP_DUR
	queue_redraw()

## Advance the combat-juice timers (called from tick_visuals). Returns TRUE if anything is still live
## (so the owner keeps redrawing). On-screen-only — headless never ticks this.
func _tick_juice(delta: float) -> bool:
	var live := false
	if _glitch_t > 0.0:
		_glitch_t = max(0.0, _glitch_t - delta)
		live = true
	if _redout_t > 0.0:
		_redout_t = max(0.0, _redout_t - delta)
		live = true
	if _clear_stamp_t > 0.0:
		_clear_stamp_t = max(0.0, _clear_stamp_t - delta)
		live = true
	return live

# ============================ TEXTURE LOADING ==================================
## Candidate resource paths for a stem, in win order: final art beats placeholder,
## .png beats .svg at the same stem (the drop-in contract — see FINAL_DIR above).
static func tex_candidate_paths(stem: String) -> Array:
	var out: Array = []
	for dir in [FINAL_DIR, ASSET_DIR]:
		for ext in TEX_EXTS:
			out.append(dir + stem + ext)
	return out

func _tex(stem: String):
	if not use_textures:
		return null
	if _tex_cache.has(stem):
		return _tex_cache[stem]
	var t = null
	for path in tex_candidate_paths(stem):
		if ResourceLoader.exists(path):
			var r = load(path)
			if r is Texture2D:
				t = r
				break
	_tex_cache[stem] = t
	return t

## Terrain-tile texture with the §4 section re-skin lookup: `<stem>__s<section>` wins when the
## variant file exists, else the plain stem (so section art can land file-by-file). section = 0
## skips the variant probe entirely (byte-stable default).
func _tile_tex(stem: String):
	if section >= SECTION_MIN and section <= SECTION_MAX:
		var v = _tex(stem + "__s%d" % section)
		if v != null:
			return v
	return _tex(stem)

func _terrain_tex_stem(t) -> String:
	if t.terrain == E.Terrain.WALL:
		return "tile_wall"
	if t.hazard == E.Hazard.GAP:
		return "tile_gap"
	if t.hazard == E.Hazard.FURNACE:
		return "tile_furnace"
	if t.hazard == E.Hazard.RAIL_LIVE:
		return "tile_rail"
	if t.hazard == E.Hazard.PISTON:
		return "tile_piston"
	# Phase-2/5 cycling-hazard tiles — previously unmapped, so they rendered as plain FLOOR (a
	# survival-critical legibility bug: lasers/steam/scald invisible on the textured feed). The ascii
	# path (_tile_glyph / debug_ascii) is deliberately left unchanged to keep the headless suites byte-stable.
	if t.hazard == E.Hazard.VENT:
		return "tile_vent"
	if t.hazard == E.Hazard.LASER:
		return "tile_laser"
	if t.hazard == E.Hazard.PLATE:
		return "tile_plate"
	if t.hazard == E.Hazard.STEAM:
		return "tile_steam"
	if t.hazard == E.Hazard.CONVEYOR:
		return "tile_conveyor"
	if t.hazard == E.Hazard.LASER_SWEEP:
		return "tile_laser_sweep"
	if t.hazard == E.Hazard.SCALD:
		return "tile_scald"
	if t.cover == 2:
		return "tile_cover_full"
	if t.cover == 1:
		return "tile_cover_half"
	return "tile_floor"

func _entity_tex_stem(tok: Dictionary) -> String:
	var nm: String = tok.name
	if tok.is_unit:
		if tok.faction == E.Faction.PLAYER:
			# Run-deployed player bodies are named by draft CALLSIGN (UnitInstance.to_sim_entity sets
			# e.name = the callsign), so key off archetype_id first; fall back to name for the
			# fixed-cell starters (_place_starters names them by archetype id). Else the bruiser stem.
			var arch: String = tok.get("archetype_id", "")
			if UNIT_TEX.has(arch):
				return UNIT_TEX[arch]
			if UNIT_TEX.has(nm):
				return UNIT_TEX[nm]
		if ENEMY_TEX.has(nm):
			return ENEMY_TEX[nm]
		# generic fallbacks by faction
		return "unit_bruiser" if tok.faction == E.Faction.PLAYER else "enemy_truncheon"
	if OBJ_TEX.has(nm):
		return OBJ_TEX[nm]
	return "obj_crate"

# ============================ DRAW =============================================
func _draw() -> void:
	if state == null:
		return
	_draw_tiles()
	_draw_targeting_rings()    # reach/push rings sit on the floor, UNDER the tokens (#16)
	_draw_move_preview()       # the move-path dotted line + destination ring (#22), under the tokens
	_draw_entities()
	_draw_targeting_shields()  # cover/flank shields + hit-% ride ON the enemy tokens (#16)
	if preview != null and preview.has_method("draw_into"):
		preview.draw_into(self)
	_draw_floats()             # rising damage numbers over the tokens (#5)
	_draw_combat_juice()       # screen-space glitch-tear / redout / CAR-CLEAR stamp, on TOP (#23)


# ============================ MOVE PREVIEW (#22) ===============================
## Draw the move-path overlay: a dotted CYAN line through the path cells + a destination ring (the
## §6.7 never-surprised tell — MOVE now matches SHOVE/SLAM's previewed bar). Reuses the ghost dotted
## idiom (short dashes) at <=50% opacity; never ALERT_RED (a predicted move, not live danger).
func _draw_move_preview() -> void:
	if move_path.is_empty() and move_dest == Vector2i(-9999, -9999):
		return
	var col := Pal.CYAN
	col.a = 0.45   # under the 0.5 ceiling
	# HONEST PATH (combat-ux #3 / critic #6): the committed MoveCommand walks x-then-y and STOPS at the
	# first blocker (input_intent._orthogonal_path). The controller hands us a BFS route that can round
	# corners the commit never takes — so re-derive the true x-then-y walk here and draw THAT, with the
	# destination ring on the ACTUAL landing cell. Render-only: a pure read of state, zero sim change,
	# and it can never invalidate a golden fixture (the command path is untouched). §6.7 never-surprised.
	var start: Vector2i = move_path[0] if not move_path.is_empty() else move_dest
	var honest: Array = xy_move_path(start, move_dest)
	# Dotted polyline through the screen-space centers of each honest cell (incl. the unit's start).
	if honest.size() >= 2:
		for i in range(honest.size() - 1):
			var a: Vector2 = Iso.tile_to_screen(honest[i], origin)
			var b: Vector2 = Iso.tile_to_screen(honest[i + 1], origin)
			_draw_dotted_segment(a, b, col)
	# Destination ring on the REAL landing cell. If it falls short of the pointed tile (a blocked/partial
	# route), a dim AMBER ghost ring on the pointed tile shows the difference — the operator sees the
	# stop, not a lie.
	var landing: Vector2i = honest.back() if not honest.is_empty() else start
	var d: Vector2 = Iso.tile_to_screen(landing, origin)
	draw_arc(d, 22.0, 0, TAU, 24, col, 2.0)
	var inner := Pal.CYAN; inner.a = 0.12
	draw_circle(d, 20.0, inner)
	if move_dest != Vector2i(-9999, -9999) and landing != move_dest:
		var g: Vector2 = Iso.tile_to_screen(move_dest, origin)
		var ghost := Pal.AMBER; ghost.a = 0.30   # under the ceiling; the "can't reach here" tell
		draw_arc(g, 20.0, 0, TAU, 22, ghost, 1.5)


## The exact x-then-y committed MOVE path (combat-ux #3): mirrors input_intent._orthogonal_path — walk
## x first then y, cap at MOVE_RANGE steps, STOP at the first non-walkable cell (wall/gap/occupant),
## returning the valid prefix INCLUDING `from` at index 0 (for drawing). PURE read of state; the render
## test pins it against the real commit path so the two can never drift. On-screen-only helper.
func xy_move_path(from: Vector2i, to: Vector2i) -> Array:
	var path: Array = [from]
	if state == null or to == Vector2i(-9999, -9999):
		return path
	var cur := from
	var steps := 0
	var sx: int = signi(to.x - from.x)
	while cur.x != to.x and steps < E.MOVE_RANGE:
		cur = Vector2i(cur.x + sx, cur.y)
		if not _preview_walkable(cur):
			return path
		path.append(cur)
		steps += 1
	var sy: int = signi(to.y - from.y)
	while cur.y != to.y and steps < E.MOVE_RANGE:
		cur = Vector2i(cur.x, cur.y + sy)
		if not _preview_walkable(cur):
			return path
		path.append(cur)
		steps += 1
	return path


## Walkability for the move preview (mirrors input_intent._walkable / _tile_move_legal): in-bounds,
## not a wall/gap, and unoccupied. PURE read of the live SimState — never mutates. On-screen-only.
func _preview_walkable(p: Vector2i) -> bool:
	if not state.in_bounds(p):
		return false
	var t = state.tile(p)
	if t.terrain == E.Terrain.WALL or t.hazard == E.Hazard.GAP:
		return false
	return state.occupant_at(p) == null


## Draw the pooled floating damage numbers, rising + fading over their lifetime (#5). On-screen-only.
func _draw_floats() -> void:
	if _floats.is_empty():
		return
	var font := ThemeDB.fallback_font
	var fsize := 18
	for fl in _floats:
		var life: float = clampf(float(fl["t"]) / FLOAT_DUR, 0.0, 1.0)   # 1 -> 0
		var rise: float = (1.0 - life) * FLOAT_RISE
		var pos: Vector2 = Vector2(fl["pos"]) + Vector2(0, -rise)
		var col: Color = fl["col"]; col.a = life
		var txt: String = fl["text"]
		var tw: float = font.get_string_size(txt, HORIZONTAL_ALIGNMENT_LEFT, -1, fsize).x
		# a faint dark outline plate keeps the number legible over any tile
		draw_string(font, pos + Vector2(-tw * 0.5 + 1, 1), txt, HORIZONTAL_ALIGNMENT_LEFT, -1, fsize, Color(0, 0, 0, life * 0.7))
		draw_string(font, pos + Vector2(-tw * 0.5, 0), txt, HORIZONTAL_ALIGNMENT_LEFT, -1, fsize, col)


## A short-dash dotted segment between two screen points (the ghost dotted idiom — §6.7 preview style).
func _draw_dotted_segment(a: Vector2, b: Vector2, col: Color) -> void:
	var d: Vector2 = b - a
	var len: float = d.length()
	if len < 0.001:
		return
	var dir: Vector2 = d / len
	var dash: float = 8.0
	var gap: float = 6.0
	var t: float = 0.0
	while t < len:
		var seg_end: float = min(t + dash, len)
		draw_line(a + dir * t, a + dir * seg_end, col, 2.0)
		t = seg_end + gap


# ============================ COMBAT JUICE (#23) ===============================
## Draw the screen-space combat juice on TOP of the feed: the glitch-tear/chroma-split bands while a
## glitch is live, then the win redout/clear wipe + the AMBER "CAR CLEAR" stamp. All purely cosmetic,
## cheap (a handful of rects + two strings), ART_BIBLE §2/§3. Never read by debug_ascii.
func _draw_combat_juice() -> void:
	var vw: float = 1280.0
	var vh: float = 720.0
	# --- glitch-tear + chroma-split (camera-cut / OBJECT_BREAK / SHOCK) ---
	if _glitch_t > 0.0 and _glitch_dur > 0.0:
		var g: float = _glitch_t / _glitch_dur          # 1 -> 0 fade
		var amp: float = 14.0 * g
		# A few horizontal scan-tear slices, offset; a faint cyan/red chroma fringe sells the split.
		var bands: int = 5
		for i in range(bands):
			var y: float = vh * (float(i) + 0.5) / float(bands)
			var off: float = amp * (1.0 if (i % 2 == 0) else -1.0)
			var bh: float = 10.0
			var cyan := Pal.CYAN; cyan.a = 0.10 * g
			var red := Pal.ALERT_RED; red.a = 0.10 * g
			draw_rect(Rect2(off, y - bh * 0.5, vw, bh), cyan)
			draw_rect(Rect2(-off, y - bh * 0.5 + 3.0, vw, 2.0), red)
		# A thin top/bottom black flicker so the whole feed "jumps" for the tear.
		var blk := Color(0, 0, 0, 0.12 * g)
		draw_rect(Rect2(0, 0, vw, vh), blk)
	# --- win redout / clear wipe (a quick AMBER flash that wipes top-to-bottom) ---
	if _redout_t > 0.0 and _redout_dur > 0.0:
		var r: float = _redout_t / _redout_dur          # 1 -> 0
		var wash := Pal.AMBER
		wash.a = 0.28 * r
		draw_rect(Rect2(0, 0, vw, vh), wash)
	# --- CAR CLEAR stamp (on-feed AMBER stamp, holds then fades) ---
	if _clear_stamp_t > 0.0:
		var s: float = clampf(_clear_stamp_t / 0.5, 0.0, 1.0)   # fade out over the last 0.5s
		var font := ThemeDB.fallback_font
		var fsize := 64
		var txt := "CAR CLEAR"
		var tw: float = font.get_string_size(txt, HORIZONTAL_ALIGNMENT_LEFT, -1, fsize).x
		var pos := Vector2((vw - tw) * 0.5, vh * 0.42)
		# a faint plate behind the stamp
		var plate := Color(0, 0, 0, 0.45 * s)
		draw_rect(Rect2(pos.x - 24, pos.y - fsize, tw + 48, fsize + 28), plate)
		var stamp := Pal.AMBER; stamp.a = s
		draw_string(font, pos, txt, HORIZONTAL_ALIGNMENT_LEFT, -1, fsize, stamp)
		# a bracketed camera-UI tick under it
		var sub := Pal.CYAN; sub.a = 0.85 * s
		draw_string(font, Vector2((vw - 0.0) * 0.5 - 110, vh * 0.42 + 28), "» SECTOR SECURE «", HORIZONTAL_ALIGNMENT_LEFT, -1, 18, sub)


# ============================ COMBAT LEGIBILITY (#16) ==========================
## Draw the floor-level targeting rings: reachable MOVE tiles (faint CYAN diamond rings) and the
## adjacent SHOVE/SLAM push tiles (faint CYAN corner brackets). ART_BIBLE §3: CYAN data color,
## <=50% opacity, NEVER ALERT_RED (these are predicted affordances, not live danger). Render-only.
func _draw_targeting_rings() -> void:
	# Reachable-move rings (shown when MOVE is armed, or unarmed-with-unit as a default affordance).
	for cell in hl_reach:
		var pts := _diamond(cell)
		var col := Pal.CYAN
		col.a = 0.22 * HL_MAX_OPACITY / 0.5   # well under the ceiling — a faint floor wash
		draw_colored_polygon(pts, Color(col.r, col.g, col.b, 0.10))
		var edge := Pal.CYAN; edge.a = 0.40
		draw_polyline(_closed(pts), edge, 1.5)
	# Push tiles (the 4 orthogonally-adjacent SHOVE/SLAM destinations) — corner brackets, brighter.
	for cell in hl_push:
		var c: Vector2 = Iso.tile_to_screen(cell, origin)
		var col := Pal.CYAN; col.a = 0.45   # under the 0.5 ceiling
		draw_arc(c, 18.0, 0, TAU, 20, col, 2.0)


## Draw the per-enemy shoot legibility: a cover/flank SHIELD glyph (half/full arc) + the to-hit %
## tag floating above each shootable enemy. ART_BIBLE §3: CYAN/AMBER data, <=50% opacity, NEVER
## ALERT_RED for a predicted outcome (the to-hit % is a prediction, not an alarm). Render-only.
func _draw_targeting_shields() -> void:
	for s in hl_shoot:
		var cell: Vector2i = s.get("cell", Vector2i.ZERO)
		var pct: int = int(s.get("pct", 0))
		var shield: int = int(s.get("shield", 0))
		var c: Vector2 = Iso.tile_to_screen(cell, origin)
		# Shootable marker: a thin CYAN target ring (under the 0.5 ceiling).
		var ring := Pal.CYAN; ring.a = 0.45
		draw_arc(c, 38.0, 0, TAU, 36, ring, 2.0)
		# Cover/flank SHIELD glyph (§16): a half/full arc on the cover-facing side. AMBER (not red).
		if shield > 0:
			var sc := Pal.AMBER; sc.a = 0.45
			# full cover = a thicker, fuller shield arc; half = a thinner half arc.
			var span: float = TAU * (0.5 if shield >= 2 else 0.28)
			draw_arc(c, 30.0, -span * 0.5 - PI * 0.5, span * 0.5 - PI * 0.5, 24, sc, 3.0 if shield >= 2 else 2.0)
		# To-hit % tag floating above the token. CYAN data; never the reserved alarm red.
		var txt := "%d%%" % clampi(pct, 0, 100)
		var font := ThemeDB.fallback_font
		var fsize := 16
		var tw := font.get_string_size(txt, HORIZONTAL_ALIGNMENT_LEFT, -1, fsize).x
		var tpos := c + Vector2(-tw * 0.5, -44.0)
		var tcol := Pal.CYAN; tcol.a = 0.95
		# a faint dark plate so the % reads over any tile (the plate itself stays under the ceiling)
		draw_rect(Rect2(tpos + Vector2(-3, -fsize + 2), Vector2(tw + 6, fsize + 4)), Color(0, 0, 0, 0.45))
		draw_string(font, tpos, txt, HORIZONTAL_ALIGNMENT_LEFT, -1, fsize, tcol)

func _draw_tiles() -> void:
	# Painter's order: iso back-to-front. The projection flips +x/+y UP the screen, so the far/back
	# corner is now MAX (x+y); iterate DESCENDING so nearer (lower-on-screen) tiles paint over farther.
	for y in range(state.height - 1, -1, -1):
		for x in range(state.width - 1, -1, -1):
			_draw_one_tile(Vector2i(x, y))

func _draw_one_tile(cell: Vector2i) -> void:
	var t = state.tile(cell)
	var center: Vector2 = Iso.tile_to_screen(cell, origin)
	var stem := _terrain_tex_stem(t)
	var tex = _tile_tex(stem)
	if tex != null:
		# Logical-rect draw — art resolution is decoupled from layout: always TILE_W logical wide,
		# height from the art's aspect ratio, bottom edge pinned to the diamond's bottom vertex.
		# A 2x (256×128) deliverable lands pixel-identical to the 1x placeholder, and tall wall
		# art (§7 "walls extend upward") grows UP past the top vertex, never down.
		var sz: Vector2 = tex.get_size()
		var h_logical: float = (Iso.TILE_W * sz.y / sz.x) if sz.x > 0.0 else float(Iso.TILE_H)
		draw_texture_rect(tex, Rect2(center + Vector2(-Iso.HALF_W, Iso.HALF_H - h_logical),
			Vector2(Iso.TILE_W, h_logical)), false)
	else:
		_draw_tile_procedural(cell, t)
	# In-car fog (E1.4): a tile outside the squad's sightline draws its REMEMBERED terrain under a dark
	# veil, and its LIVE status layers are SUPPRESSED (the operator does not see hazards forming in the
	# fog). Render-only — the sim still tracks the tile fully; this only limits what is DRAWN.
	if fog_tile_hidden(cell):
		_draw_fog_veil(cell)
		return
	# Status layers are ALWAYS procedural overlays (they stack on the terrain).
	_draw_tile_layers(cell, t)
	# W7-iso-labels: a CONVEYOR belt's flow arrow, oriented through the FLIPPED projection so it points
	# its intended on-screen side (a sim-space belt_dir no longer means screen-left/right). Render-only.
	_draw_flow_arrow(cell, t)


## Paint the E1.4 fog veil over a hidden tile: a dark translucent diamond so the remembered terrain
## reads faintly through, but the operator plainly sees "out of sight here". Uses the raw Iso corners
## (self-contained; independent of the memoized _diamond path). Render-only — never in debug_ascii.
func _draw_fog_veil(cell: Vector2i) -> void:
	var pts := Iso.diamond_points(cell, origin)
	var veil := Pal.FOG_VEIL; veil.a = 0.72
	draw_colored_polygon(pts, veil)

func _draw_tile_procedural(cell: Vector2i, t) -> void:
	var pts := _diamond(cell)
	var fill := Pal.FLOOR
	if t.terrain == E.Terrain.WALL:
		fill = Pal.WALL
	elif t.hazard == E.Hazard.GAP:
		fill = Pal.GAP
	elif t.hazard == E.Hazard.FURNACE:
		fill = Pal.FURNACE_CORE
	elif t.hazard == E.Hazard.RAIL_LIVE:
		fill = Pal.RAIL_BG
	elif t.hazard == E.Hazard.PISTON:
		fill = Pal.PISTON_STEEL
	elif t.cover == 2:
		fill = Pal.COVER_FULL
	elif t.cover == 1:
		fill = Pal.COVER_HALF
	draw_colored_polygon(pts, fill)
	draw_polyline(_closed(pts), Pal.OUTLINE, 2.0)
	# rim highlight on the top two edges
	draw_line(pts[3], pts[0], Pal.FLOOR_RIM, 1.5)
	draw_line(pts[0], pts[1], Pal.FLOOR_RIM, 1.5)
	if t.hazard == E.Hazard.RAIL_LIVE:
		_draw_zigzag(Iso.tile_to_screen(cell, origin), Pal.RAIL_BOLT)

func _draw_tile_layers(cell: Vector2i, t) -> void:
	if t.status_layer == 0:
		return
	var pts := _diamond(cell)
	if t.has_layer(E.L_WATER):
		var w := Pal.L_WATER; w.a = 0.60
		draw_colored_polygon(pts, w)
		draw_polyline(_closed(pts), Pal.L_WATER_FOAM, 1.5)
	if t.has_layer(E.L_DEBRIS):
		var d := Pal.L_DEBRIS; d.a = 0.70
		draw_colored_polygon(pts, d)
	if t.has_layer(E.L_FIRE):
		var f := Pal.L_FIRE; f.a = 0.75
		draw_colored_polygon(pts, f)
	if t.has_layer(E.L_ELECTRIFIED):
		# The marquee combo: yellow arc lattice over the blue wash. Bright + unmistakable.
		_draw_zigzag(Iso.tile_to_screen(cell, origin), Pal.L_ELECTRIFIED)
		_draw_zigzag(Iso.tile_to_screen(cell, origin) + Vector2(0, 6), Pal.L_ELEC_ARC)
	# --- Phase-2/5 hazard-cloud layers (combat-ux #0). Each carries a COLOR *and* a distinct
	# silhouette (§6.1 colorblind rule) so it never relies on hue alone. Ground tints paint first,
	# then the airborne clouds, then the trap TELEGRAPH border on top (it is the live danger tell).
	var center: Vector2 = Iso.tile_to_screen(cell, origin)
	if t.has_layer(E.L_SCORCHED):
		var sc := Pal.L_SCORCHED; sc.a = 0.55
		draw_colored_polygon(pts, sc)
	if t.has_layer(E.L_SNOW):
		var sn := Pal.L_SNOW; sn.a = 0.55
		draw_colored_polygon(pts, sn)
		_draw_tile_flecks(center, Pal.GLYPH_WHITE, 5)   # snow flecks — pale specks
	if t.has_layer(E.L_CONCEAL):
		var cn := Pal.L_CONCEAL; cn.a = 0.55
		draw_colored_polygon(pts, cn)
		_draw_tile_hatch(center, Pal.L_CONCEAL.lightened(0.25), true)  # dappled cross-hatch
	if t.has_layer(E.L_GAS):
		var g := Pal.L_GAS; g.a = 0.55
		draw_colored_polygon(pts, g)
		_draw_tile_flecks(center, Pal.L_GAS_STIPPLE, 7)  # drifting gas motes (stipple)
	if t.has_layer(E.L_STEAM):
		var st := Pal.L_STEAM; st.a = 0.50
		draw_colored_polygon(pts, st)
		_draw_tile_waves(center, Pal.GLYPH_WHITE)        # rising steam curls
	if t.has_layer(E.L_TELEGRAPH):
		# A cycling trap will FIRE here NEXT env phase — the one layer that reads alarm-adjacent.
		# A bold AMBER diamond border + inner X hatch: unmistakable by shape alone, never ALERT_RED
		# (still a prediction, §3 reserved-red gate). Static (no per-frame pulse — mobile-cheap).
		var tg := Pal.L_TELEGRAPH; tg.a = 0.85
		draw_polyline(_closed(pts), tg, 3.0)
		draw_line(pts[0], pts[2], tg, 2.0)   # vertical of the X (top<->bottom)
		draw_line(pts[3], pts[1], tg, 2.0)   # horizontal of the X (left<->right)

## W7-iso-labels — draw a small flow arrow for a directional CONVEYOR belt, pointing the correct
## ON-SCREEN way. The sim stores `belt_dir` in SIM SPACE; the flipped projection sends forward (+x) UP
## the screen, so a naive "the belt drags right" read is wrong. We map the sim-space direction through
## the projection (screen_dir) so the arrow matches the belt's intended on-screen side — the drift the
## flip introduced. Only drawn where belt_dir is genuinely set (localized belt rows),
## never per-slope-tile (would carpet a whole floor). Render-only: never in debug_ascii / sync.
func _draw_flow_arrow(cell: Vector2i, t) -> void:
	if t.belt_dir == Vector2i.ZERO:
		return
	var sd: Vector2 = CarView.screen_dir(t.belt_dir)
	if sd == Vector2.ZERO:
		return
	var c: Vector2 = Iso.tile_to_screen(cell, origin)
	var col := Pal.CYAN; col.a = 0.6
	var tip: Vector2 = c + sd * 22.0
	var tail: Vector2 = c - sd * 22.0
	draw_line(tail, tip, col, 2.5)
	# arrowhead — two short barbs off the tip, back along the flow
	var perp := Vector2(-sd.y, sd.x)
	draw_line(tip, tip - sd * 9.0 + perp * 6.0, col, 2.5)
	draw_line(tip, tip - sd * 9.0 - perp * 6.0, col, 2.5)


func _draw_entities() -> void:
	# Draw in iso depth order so nearer tokens overlap farther ones.
	var ids: Array = tokens.keys()
	ids.sort_custom(func(a, b):
		var pa: Vector2 = tokens[a].vis_pos
		var pb: Vector2 = tokens[b].vis_pos
		return pa.y < pb.y)
	for id in ids:
		var tok: Dictionary = tokens[id]
		# A DOWNED (bleeding-out) ally is alive=false in the sim but must stay on the board as a body
		# to reach + stabilize (combat-ux #2) — draw it, distinctly, instead of vanishing it.
		if not tok.alive and not bool(tok.get("downed", false)):
			continue
		# In-car fog (E1.4): an enemy / object lurking in the operator's blind spots is not drawn until
		# a squad member sees it; your own units always show. Render-only (the sim still tracks it).
		if fog_entity_hidden(id):
			continue
		_draw_token(tok)

func _draw_token(tok: Dictionary) -> void:
	var c: Vector2 = tok.vis_pos
	# On-screen animation modulation (both default neutral, so the headless path is unchanged):
	#   fade  : a dying/breaking token shrinks its alpha toward 0 during the death/break tween.
	#   flash : an impact paints a brief white wash over the token.
	var fade: float = float(tok.get("vis_fade", 1.0))
	var flash: float = float(tok.get("vis_flash", 0.0))
	# DOWNED body (combat-ux #2): a distinct prone token — dimmed glyph, ALERT_RED bleed-ring, and a
	# bleed-out countdown pip row — so a savable ally reads as "on the ground, reach me" not "gone".
	if bool(tok.get("downed", false)):
		_draw_downed_token(tok, c)
		return
	# Selected-unit highlight: a pulsing amber ring under the token (interactive on-screen only).
	if tok.is_unit and highlight_id >= 0 and tokens.has(highlight_id) and tokens[highlight_id] == tok:
		var pulse: float = 0.5 + 0.5 * sin(_hl_t * 6.0)
		var hl := Pal.AMBER; hl.a = (0.25 + 0.35 * pulse) * fade
		draw_arc(c, 50.0, 0, TAU, 52, hl, 3.0)
	# Faction ring (procedural — overlay independent of the glyph texture). §3.5
	var ring := Pal.faction_ring(tok.faction); ring.a *= fade
	if tok.is_unit:
		var glow := ring; glow.a = 0.18 * fade
		draw_circle(c, 44.0, glow)
		draw_arc(c, 44.0, 0, TAU, 48, ring, 4.0)
	# Archetype/object glyph — drawn into the fixed §7 96-logical token box centered on the tile,
	# so token art of any resolution (2x 192×192 final art) lands exactly where the 1x placeholder did.
	var tex = _tex(_entity_tex_stem(tok))
	if tex != null:
		var half := TOKEN_LOGICAL * 0.5
		draw_texture_rect(tex, Rect2(c - Vector2(half, half), Vector2(TOKEN_LOGICAL, TOKEN_LOGICAL)),
			false, Color(1, 1, 1, fade))
	else:
		_draw_token_procedural(tok, fade)
	# Impact flash — a white wash over the token while it decays.
	if flash > 0.001:
		var fc := Color(1, 1, 1, clampf(flash, 0.0, 1.0) * 0.7 * fade)
		draw_circle(c, 30.0, fc)
	# Status badges ring the token clockwise from 1 o'clock. §6.1. The OVERWATCH eye (#21) is composed
	# in render-side as R_OVERWATCH (a render-only flag, never a core sim status) so a holding unit reads
	# on the feed alongside its real statuses.
	if tok.is_unit:
		var composed: int = int(tok.vis_status)
		if bool(tok.get("vis_overwatch", false)):
			composed |= Pal.R_OVERWATCH
		_draw_status_badges(c, composed)
		# HP bar under every living unit token (combat-ux #5) — the focus-fire read the log hides.
		_draw_hp_bar(c, int(tok.get("hp", -1)), int(tok.get("max_hp", -1)), fade)

func _draw_token_procedural(tok: Dictionary, fade: float = 1.0) -> void:
	var c: Vector2 = tok.vis_pos
	if tok.is_unit:
		var body := Color("2A3038"); body.a *= fade
		draw_circle(c, 26.0, body)
		var ol := Pal.OUTLINE; ol.a *= fade
		draw_arc(c, 26.0, 0, TAU, 32, ol, 2.0)
	else:
		# inert grey square (object)
		var r := Rect2(c - Vector2(28, 28), Vector2(56, 56))
		var fill := Pal.FAC_OBJECT; fill.a *= fade
		var ol2 := Pal.OUTLINE; ol2.a *= fade
		draw_rect(r, fill)
		draw_rect(r, ol2, false, 2.0)


# ============================ HP BARS + DOWNED (combat-ux #2/#5) ================
const HP_BAR_W := 42.0        # logical width of the under-token HP bar
const HP_BAR_H := 5.0
const HP_BAR_DY := 34.0       # drop below the token center

## A segmented HP bar under a unit token. Data comes from the synced token (hp/max_hp) so it is
## exactly the sim's health; it drops as the comms log reports a hit (event_player updates hp too).
## Render-only — never read by debug_ascii. Skips units with no known max (-1, legacy uncapped).
func _draw_hp_bar(center: Vector2, hp: int, max_hp: int, fade: float = 1.0) -> void:
	if max_hp <= 0 or fade <= 0.01:
		return
	var cur: int = clampi(hp, 0, max_hp)
	var frac: float = float(cur) / float(max_hp)
	var origin_x: float = center.x - HP_BAR_W * 0.5
	var top: float = center.y + HP_BAR_DY
	# backplate
	draw_rect(Rect2(origin_x - 1, top - 1, HP_BAR_W + 2, HP_BAR_H + 2), Color(0, 0, 0, 0.55 * fade))
	draw_rect(Rect2(origin_x, top, HP_BAR_W, HP_BAR_H), Color(Pal.FRAME_BORDER.r, Pal.FRAME_BORDER.g, Pal.FRAME_BORDER.b, 0.9 * fade))
	# fill — green healthy -> amber -> red as it drops (a legibility gradient, not the reserved alarm)
	var fill_col: Color = Pal.STATUS_POISONED.lerp(Pal.AMBER, clampf((1.0 - frac) * 1.6, 0.0, 1.0))
	if frac <= 0.34:
		fill_col = Pal.ALERT_RED
	fill_col.a = fade
	draw_rect(Rect2(origin_x, top, HP_BAR_W * frac, HP_BAR_H), fill_col)

## The DOWNED body pose (combat-ux #2): a dimmed prone glyph, an ALERT_RED bleed-ring, and a row of
## bleed-out countdown pips (one per env phase left before permadeath). A stabilized ally (bleed 0)
## drops the countdown but keeps the prone red body — still down, no longer dying. Render-only.
func _draw_downed_token(tok: Dictionary, c: Vector2) -> void:
	var a := 0.5
	# prone body: a flattened ellipse (a fallen silhouette), dimmed
	var body := Color("2A3038"); body.a = a
	draw_circle(c, 22.0, body)
	# ALERT_RED bleed-ring (this IS live danger to the squad — a body under the bleed clock, §3 red)
	var ring := Pal.ALERT_RED; ring.a = 0.85
	draw_arc(c, 26.0, 0, TAU, 32, ring, 3.0)
	# a downed cross-mark (distinct silhouette from any standing token)
	draw_line(c + Vector2(-12, -12), c + Vector2(12, 12), ring, 2.0)
	draw_line(c + Vector2(12, -12), c + Vector2(-12, 12), ring, 2.0)
	# glyph, dimmed, to keep identity
	var tex = _tex(_entity_tex_stem(tok))
	if tex != null:
		var half := TOKEN_LOGICAL * 0.5
		draw_texture_rect(tex, Rect2(c - Vector2(half, half), Vector2(TOKEN_LOGICAL, TOKEN_LOGICAL)),
			false, Color(1, 1, 1, a))
	# bleed-out countdown pips above the body (BLEED_OUT_TURNS at down, ticking to 0).
	var bleed: int = int(tok.get("bleed", 0))
	if bleed > 0:
		for i in range(bleed):
			draw_circle(c + Vector2(-8.0 + i * 10.0, -34.0), 4.0, Pal.ALERT_RED)
			draw_arc(c + Vector2(-8.0 + i * 10.0, -34.0), 4.0, 0, TAU, 10, Pal.OUTLINE, 1.0)

func _draw_status_badges(center: Vector2, status: int) -> void:
	# W5-17: the OVERWATCH eye is a PRIORITY tell drawn in its OWN reserved slot (~11 o'clock), so a
	# unit carrying MAX_BADGES real statuses AND holding still reads as watching — it is no longer
	# squeezed out of the capped fan. Pal.status_badge_plan owns the "eye vs the up-to-3 fan" decision
	# (one source of truth, headless-testable); this only paints it. Render-only (never runs headless).
	var plan: Dictionary = Pal.status_badge_plan(status)
	if bool(plan.get("eye", false)):
		var eang: float = deg_to_rad(-100.0)               # its own slot, clear of the 1-o'clock fan
		var ebp: Vector2 = center + Vector2(cos(eang), sin(eang)) * 48.0
		_draw_overwatch_eye(ebp, Pal.status_color(Pal.R_OVERWATCH))
	var shown := 0
	for pair in (plan.get("badges", []) as Array):
		var flag: int = pair[0]
		var ang: float = deg_to_rad(-60.0 + shown * 40.0)  # ~1 o'clock, clockwise
		var bp: Vector2 = center + Vector2(cos(ang), sin(ang)) * 48.0
		# Colored backplate (COLOR) + a distinct SHAPE on top — the icon silhouette if its SVG
		# resolves, else the status's legend GLYPH as text. Satisfies ART_BIBLE §6.1 "each status
		# owns both a color AND a distinct silhouette — never hue alone" (art-pipeline #4). Render-only.
		draw_circle(bp, 10.0, Pal.status_color(flag))
		draw_arc(bp, 10.0, 0, TAU, 16, Pal.OUTLINE, 2.0)
		_draw_status_symbol(bp, flag, String(pair[1]))
		shown += 1


## Draw the distinct-silhouette layer of a status badge: the status_*.svg icon if it loads (the
## colorblind-safe shape that ships on disk), else the single legend glyph as text so shape survives
## even on the procedural path. Render-only — never touches debug_ascii.
func _draw_status_symbol(bp: Vector2, flag: int, glyph: String) -> void:
	var tex = null
	if STATUS_TEX.has(flag):
		tex = _tex(STATUS_TEX[flag])
	if tex != null:
		var s := 16.0   # inside the 20px badge
		draw_texture_rect(tex, Rect2(bp - Vector2(s * 0.5, s * 0.5), Vector2(s, s)), false)
	elif glyph != "":
		var font := ThemeDB.fallback_font
		var fsize := 13
		var gw: float = font.get_string_size(glyph, HORIZONTAL_ALIGNMENT_LEFT, -1, fsize).x
		draw_string(font, bp + Vector2(-gw * 0.5, 5.0), glyph, HORIZONTAL_ALIGNMENT_LEFT, -1, fsize, Pal.OUTLINE)


## A small "eye" badge for the OVERWATCH tell (#21): an outlined lens with a pupil — reads as
## "holding / watching this lane" at a glance, distinct from the round status fills. Render-only.
func _draw_overwatch_eye(bp: Vector2, col: Color) -> void:
	# lens backplate
	draw_circle(bp, 10.0, Color(Pal.OUTLINE.r, Pal.OUTLINE.g, Pal.OUTLINE.b, 0.85))
	# lens outline (the eye ring)
	draw_arc(bp, 10.0, 0, TAU, 16, col, 2.0)
	# almond lids — two short arcs top + bottom for the eye shape
	draw_arc(bp + Vector2(0, 3), 8.0, PI * 1.15, PI * 1.85, 10, col, 1.5)
	draw_arc(bp + Vector2(0, -3), 8.0, PI * 0.15, PI * 0.85, 10, col, 1.5)
	# pupil
	draw_circle(bp, 3.0, col)

# ---- small procedural helpers ----
func _closed(pts: PackedVector2Array) -> PackedVector2Array:
	var out := PackedVector2Array(pts)
	out.push_back(pts[0])
	return out

# A scatter of small specks inside a tile diamond (snow flecks / gas motes) — a stipple silhouette
# distinct from any flat wash. Deterministic layout (hashed off no rng) so it never churns per frame.
func _draw_tile_flecks(center: Vector2, col: Color, count: int) -> void:
	var offs := [Vector2(-18, -4), Vector2(10, -10), Vector2(22, 2), Vector2(-8, 8),
		Vector2(2, 4), Vector2(-24, 6), Vector2(16, 12)]
	for i in range(min(count, offs.size())):
		draw_circle(center + offs[i], 2.0, col)

# A short cross-hatch inside a tile (concealment dapple) — a woven silhouette, not a flat fill.
func _draw_tile_hatch(center: Vector2, col: Color, _dapple: bool) -> void:
	var w: float = Iso.HALF_W * 0.5
	for dx in [-w * 0.5, 0.0, w * 0.5]:
		draw_line(center + Vector2(dx - 6, -8), center + Vector2(dx + 6, 8), col, 1.5)
		draw_line(center + Vector2(dx + 6, -8), center + Vector2(dx - 6, 8), col, 1.5)

# Two stacked wavy curls (rising steam) — a cloud silhouette over the pale steam wash.
func _draw_tile_waves(center: Vector2, col: Color) -> void:
	var c := col; c.a = 0.6
	for row in [-6.0, 4.0]:
		var p := PackedVector2Array([
			center + Vector2(-20, row), center + Vector2(-8, row - 5),
			center + Vector2(4, row), center + Vector2(16, row - 5),
			center + Vector2(24, row)])
		draw_polyline(p, c, 1.5)

func _draw_zigzag(center: Vector2, col: Color) -> void:
	var w: float = Iso.HALF_W * 0.7
	var p := PackedVector2Array([
		center + Vector2(-w, 0), center + Vector2(-w * 0.4, -10),
		center + Vector2(0, 2), center + Vector2(w * 0.4, -10),
		center + Vector2(w, 0),
	])
	draw_polyline(p, col, 2.5)

# ============================ DEBUG ASCII ======================================
## A textual glyph map of the CURRENTLY-COMPOSED scene (tiles under tokens). This is
## how the headless smoke test proves composition without a display. One char per
## tile; tokens take priority over terrain/layer glyphs. Reads token `vis_pos` so it
## reflects animated/committed positions, mapping each token back to its grid cell.
func debug_ascii() -> String:
	if state == null:
		return ""
	# Map each living token to the nearest grid cell from its CURRENT visual pos.
	var token_at: Dictionary = {}   # Vector2i -> tok
	for id in tokens.keys():
		var tok: Dictionary = tokens[id]
		if not tok.alive:
			continue
		var cell := Iso.screen_to_tile(tok.vis_pos, origin)
		token_at[cell] = tok
	var lines: Array = []
	for y in range(state.height):
		var row := ""
		for x in range(state.width):
			var cell := Vector2i(x, y)
			if token_at.has(cell):
				row += _token_glyph(token_at[cell])
			else:
				row += _tile_glyph(state.tile(cell))
		lines.append(row)
	return "\n".join(lines)

func _tile_glyph(t) -> String:
	if t.terrain == E.Terrain.WALL:
		return "#"
	if t.hazard == E.Hazard.GAP:
		return "X"
	if t.hazard == E.Hazard.FURNACE:
		return "F"
	if t.hazard == E.Hazard.RAIL_LIVE:
		return "R"
	if t.hazard == E.Hazard.PISTON:
		return "P"
	# status layers (electrified water is the marquee — show '%')
	if t.has_layer(E.L_ELECTRIFIED):
		return "%"
	if t.has_layer(E.L_WATER):
		return "~"
	if t.has_layer(E.L_FIRE):
		return "f"
	if t.has_layer(E.L_DEBRIS):
		return ","
	if t.cover == 2:
		return "B"
	if t.cover == 1:
		return "b"
	return "."

func _token_glyph(tok: Dictionary) -> String:
	if not tok.is_unit:
		return "o"   # object
	if tok.faction == E.Faction.PLAYER:
		return "@"
	if tok.faction == E.Faction.ENEMY:
		return "g"
	if tok.faction == E.Faction.NEUTRAL:
		return "n"
	return "?"
