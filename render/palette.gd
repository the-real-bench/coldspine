class_name Palette
## The ART_BIBLE §3 color language as Color constants (THE CONTRACT). Procedural
## `_draw()` paths use these exact hexes so the look matches the placeholder SVGs.
## Chrome colors from §2/§5. Pure data — no SceneTree deps.

# --- Chrome / CRT framing (ART_BIBLE §2, §5) ---
const FRAME_BG       := Color("0B0E11")
const FRAME_BORDER   := Color("1C2630")
const FRAME_INSET    := Color("243240")
const AMBER          := Color("FFB000")   # primary terminal type
const CYAN           := Color("3FC6D4")   # secondary / data
const ALERT_RED      := Color("FF3B3B")   # alerts ONLY (reserved — never preview)
const DIM            := Color("5A6470")   # inactive

# --- Terrain & cover (§3.1) ---
const FLOOR          := Color("3A4048")
const FLOOR_SEAM     := Color("2F343B")
const FLOOR_RIM      := Color("4A525C")
const WALL           := Color("22262C")
const WALL_TOP       := Color("4A525C")
const COVER_HALF     := Color("6E7B66")
const COVER_FULL     := Color("566B4F")
const SPAWN_PLAYER   := Color("2E6E9E")
const SPAWN_ENEMY    := Color("9E3A2E")

# --- Hazard tiles (§3.2) ---
const GAP            := Color("0A0C0F")
const FURNACE_CORE   := Color("FF7A18")
const FURNACE_RIM    := Color("7A2400")
const RAIL_BOLT      := Color("FFE14D")
const RAIL_BG        := Color("2A2A12")
const PISTON_STEEL   := Color("9AA3AD")

# --- Hazard tile LAYERS (§3.3) — overlays, drawn procedurally over the tile ---
const L_WATER        := Color("2E8BC0")   # @ 60%
const L_WATER_FOAM   := Color("7EC8E3")
const L_FIRE         := Color("FF5A1F")   # @ 75%
const L_ELECTRIFIED  := Color("FFE14D")   # @ 80%
const L_ELEC_ARC     := Color("E8FBFF")
const L_DEBRIS       := Color("7A6E5A")   # @ 70%
# Phase-2/5 hazard-cloud LAYERS (Sub-Spec D/E) — previously undrawn, so gas/steam/snow/conceal/
# scorched tiles and the trap TELEGRAPH were invisible on the feed (combat-ux #0). Each gets a
# color AND a distinct silhouette in _draw_tile_layers (§6.1 color+shape, colorblind-safe).
const L_GAS          := Color("8FB03A")   # poison cloud — sickly green-yellow wash (D1.3)
const L_GAS_STIPPLE  := Color("C6E070")   # gas motes (the stipple dots over the wash)
const L_STEAM        := Color("D8E4E8")   # steam cloud — pale white wash, blinds/blocks LoS (D2.5)
const L_SNOW         := Color("C9DCE6")   # packed snow — pale blue-white, difficult terrain (E1.6)
const L_CONCEAL      := Color("2C3A2A")   # concealment (underbrush/canvas) — dark dappled (E1.4)
const L_SCORCHED     := Color("3A2C24")   # burnt-out tile fire left behind (D1.2)
const L_TELEGRAPH    := Color("FFB000")   # a cycling trap FIRES here next env phase (D2) — AMBER warning

# --- IN-CAR FOG (Sub-Spec E1.4) — the operator-vision veil over UNSEEN tiles in a fog car (Hedge
# Maze / heavy Steam). A dark translucent wash the CarView paints on tiles outside the squad's
# sightline (render-only). It is a VISION limit, not a §3.3 tile state, so it lives here and is NOT
# in DRAWN_LAYERS. Painted at partial alpha so the REMEMBERED terrain still reads faintly through.
const FOG_VEIL       := Color("05070A")   # near-black fog-of-war veil (drawn ~72% over remembered terrain)

# --- Faction rings (§3.5) ---
const FAC_PLAYER     := Color("2EA7E0")
const FAC_ENEMY      := Color("E0432E")
const FAC_NEUTRAL    := Color("E0B72E")
const FAC_OBJECT     := Color("9AA3AD")

# --- Status badge fills (§3.4), keyed by S_* bitflag ---
const STATUS_PRONE      := Color("C8A24A")
const STATUS_STUNNED    := Color("F2D14E")
const STATUS_SOAKED     := Color("2E8BC0")
const STATUS_BURNING    := Color("FF5A1F")
const STATUS_SHOCKED    := Color("FFE14D")
const STATUS_POISONED   := Color("7FBF3F")
const STATUS_BLINDED    := Color("C9CDD2")
const STATUS_CHILLED    := Color("8FD4E8")
const STATUS_FROZEN     := Color("BFEFFF")
const STATUS_DOWNED     := Color("C0354A")
const STATUS_SUPPRESSED := Color("B07A2E")
const STATUS_BURIED     := Color("8A7C64")   # avalanche debris/snow — immobilize family (E1.6)
const STATUS_NETTED     := Color("B98A4A")   # Net Gunner rope-tan — immobilize family (§12)
const STATUS_OVERWATCH  := Color("3FC6D4")   # #21 — the "holding/overwatch" eye tell reads CYAN (data, not alarm)

const GLYPH_WHITE    := Color("F2F4F6")
const OUTLINE        := Color("0B0E11")

# --- RENDER-SIDE pseudo-status (#21; render-only — NOT a core sim flag) ---------
# Overwatch is a bool on the sim entity (SimEntity.overwatch), not a status bitflag, so it has no
# core S_* bit. The CarView surfaces it as an on-feed eye badge by OR-ing this render-only flag into
# a COMPOSED status int it builds at draw time (never read back by debug_ascii / the headless suites).
# Bit 20 is well clear of every core S_* bit (which top out at 1<<13), so it can never collide.
const R_OVERWATCH := 1 << 20

const E = preload("res://core/sim_enums.gd")

# Every tile status-layer bit the renderer draws (combat-ux #0). ORDER = paint order in
# _draw_tile_layers. Ground tints first, airborne clouds next, the trap TELEGRAPH border last.
const DRAWN_LAYERS := [
	E.L_SCORCHED, E.L_SNOW, E.L_CONCEAL, E.L_WATER, E.L_DEBRIS, E.L_FIRE,
	E.L_ELECTRIFIED, E.L_GAS, E.L_STEAM, E.L_TELEGRAPH,
]

## The canonical wash color for a tile status-layer bit (L_*). One place so the draw path and the
## legend/tests agree. Returns AMBER for an unmapped bit (never silently invisible).
static func layer_color(flag: int) -> Color:
	match flag:
		E.L_WATER:       return L_WATER
		E.L_FIRE:        return L_FIRE
		E.L_ELECTRIFIED: return L_ELECTRIFIED
		E.L_DEBRIS:      return L_DEBRIS
		E.L_GAS:         return L_GAS
		E.L_STEAM:       return L_STEAM
		E.L_SNOW:        return L_SNOW
		E.L_CONCEAL:     return L_CONCEAL
		E.L_SCORCHED:    return L_SCORCHED
		E.L_TELEGRAPH:   return L_TELEGRAPH
		_: return AMBER

## Faction enum -> ring Color.
static func faction_ring(faction: int) -> Color:
	match faction:
		E.Faction.PLAYER: return FAC_PLAYER
		E.Faction.ENEMY:  return FAC_ENEMY
		E.Faction.NEUTRAL: return FAC_NEUTRAL
		_: return FAC_OBJECT

## S_* bitflag -> badge fill Color (returns AMBER for unknown).
static func status_color(flag: int) -> Color:
	match flag:
		E.S_PRONE:      return STATUS_PRONE
		E.S_STUNNED:    return STATUS_STUNNED
		E.S_SOAKED:     return STATUS_SOAKED
		E.S_BURNING:    return STATUS_BURNING
		E.S_SHOCKED:    return STATUS_SHOCKED
		E.S_POISONED:   return STATUS_POISONED
		E.S_BLINDED:    return STATUS_BLINDED
		E.S_CHILLED:    return STATUS_CHILLED
		E.S_FROZEN:     return STATUS_FROZEN
		E.S_DOWNED:     return STATUS_DOWNED
		E.S_SUPPRESSED: return STATUS_SUPPRESSED
		E.S_BURIED:     return STATUS_BURIED
		E.S_NETTED:     return STATUS_NETTED
		R_OVERWATCH:    return STATUS_OVERWATCH
		_: return AMBER

## Status bitflags in clockwise badge order (§6.1), as (flag, single-char-glyph) pairs.
## The second element is the per-status legend glyph (status-icon sheet + a future ascii legend);
## debug_ascii() composes the board by FACTION (@/g/n/o), so this glyph is a label, not the board read.
## Order also caps which 3 badges show on a crowded token (first-listed win the slots).
## R_OVERWATCH is the render-side OVERWATCH eye tell (#21) — last in the order so a real status
## (burn/stun/etc.) always wins the limited badge slots; the eye only shows when there's room.
const STATUS_ORDER := [
	[E.S_PRONE, "p"], [E.S_STUNNED, "z"], [E.S_SOAKED, "~"], [E.S_BURNING, "f"],
	[E.S_SHOCKED, "*"], [E.S_POISONED, "x"], [E.S_BLINDED, "o"], [E.S_CHILLED, "c"],
	[E.S_FROZEN, "C"], [E.S_DOWNED, "d"], [E.S_SUPPRESSED, "v"],
	[E.S_BURIED, "u"], [E.S_NETTED, "t"], [R_OVERWATCH, "e"],
]

# The token can only fit a few round status badges before they overlap the ring; the fan caps here.
const MAX_BADGES := 3

## The status-badge DRAW PLAN for a token (#21 / W5-17). The OVERWATCH eye is a PRIORITY tell drawn
## in its OWN reserved slot, so a buffed/afflicted overwatcher (MAX_BADGES real statuses) STILL reads as
## holding — previously the eye was last in STATUS_ORDER and got squeezed out by the 3-badge cap. Returns
## { eye:bool, badges:Array-of-[flag,glyph] }: `eye` = draw the separate overwatch lens; `badges` = the up
## -to-MAX_BADGES NON-overwatch status fills (the clockwise fan). PURE — one source of truth shared by
## CarView._draw_status_badges and the headless test; never read by debug_ascii / the sim.
static func status_badge_plan(status: int) -> Dictionary:
	var eye: bool = (status & R_OVERWATCH) != 0
	var badges: Array = []
	for pair in STATUS_ORDER:
		var flag: int = pair[0]
		if flag == R_OVERWATCH:
			continue                       # priority tell — drawn separately, never in the capped fan
		if (status & flag) == 0:
			continue
		if badges.size() >= MAX_BADGES:
			break
		badges.append(pair)
	return {"eye": eye, "badges": badges}
