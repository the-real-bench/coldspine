class_name SimTile
extends RefCounted
## One grid cell. Integer fields only.

const E = preload("res://core/sim_enums.gd")

var terrain: int = E.Terrain.FLOOR
var cover: int = 0                 # 0 none / 1 half / 2 full
var hazard: int = E.Hazard.NONE
var occupant_id: int = -1          # -1 = empty
var status_layer: int = 0          # L_WATER | L_FIRE | L_ELECTRIFIED | L_DEBRIS | L_GAS | ...
var status_timer: int = 0          # turns remaining for transient layers (water/fire/steam)
var gas_timer: int = 0             # density/duration timer for the gas layer (independent of fire)
var flammable: bool = false        # tile carries fuel: fire spreads onto it (oil/cloth/wood deck)

# --- Cycling-trap state (Sub-Spec D2). Only meaningful when hazard is a cycling type. ---
var trap_period: int = 0           # cycle length in turns (0 = not a cycling trap)
var trap_phase: int = 0            # position within the cycle [0 .. trap_period-1]
var trap_dir: int = 0              # orientation for line/row/sweep shapes (0=row +x, 1=col +y, ...)
var trap_active: bool = false      # the trap is enabled (Saboteur Hack can disable it)

# --- Phase 5: Sub-Spec E1 set-piece tile extensions. APPEND ONLY. Integer fields. ---
# friction modifies the per-tile momentum cost during forced movement (E1.1):
#   < 0  = unset (default: cost = mover's mass)
#     0  = ICE: a forced move costs NO momentum -> slides full length until it hits
#   >=1  = SNOW/soft soil: cost = mass + (friction-?) ; also difficult terrain on walk
var friction: int = -1
# slope is a unit vector (E1.1): moving WITH it adds momentum, AGAINST saps it; an
# unsupported entity slides downhill at the start of the environment phase.
var slope: Vector2i = Vector2i.ZERO
# beltDir (E1.5 conveyor): a fixed 1-tile drift applied to occupants each env phase.
var belt_dir: Vector2i = Vector2i.ZERO

func has_layer(l: int) -> bool:
	return (status_layer & l) != 0

func clone() -> SimTile:
	var t := SimTile.new()
	t.terrain = terrain
	t.cover = cover
	t.hazard = hazard
	t.occupant_id = occupant_id
	t.status_layer = status_layer
	t.status_timer = status_timer
	t.gas_timer = gas_timer
	t.flammable = flammable
	t.trap_period = trap_period
	t.trap_phase = trap_phase
	t.trap_dir = trap_dir
	t.trap_active = trap_active
	t.friction = friction
	t.slope = slope
	t.belt_dir = belt_dir
	return t
