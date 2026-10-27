class_name SimState
extends RefCounted
## The full deterministic world: tile grid + entities + RNG. Deep-cloneable for
## dry-run previews (Sub-Spec A1). Grid indexed [y][x]; coords are Vector2i.

const E = preload("res://core/sim_enums.gd")

var width: int = 0
var height: int = 0
var grid: Array = []           # Array[Array[SimTile]] indexed [y][x]
var entities: Dictionary = {}  # id -> SimEntity
var rng: IntRng = null
var next_id: int = 1

# --- Phase 4: bleed-out gate (Sub-Spec C §7.4) ---
# When false (default), a unit hitting 0 HP is removed from play immediately (the
# Phase 0-i / physics behavior every existing test relies on). When true, a UNIT
# hitting 0 HP becomes Downed (Bleeding) instead of being erased — the revive
# window opens. Enemy units always die outright unless DOWN_ENEMIES is on too.
var bleedout_enabled: bool = false
var down_enemies_too: bool = false   # if true, enemies also down+bleed (else they just die)
var order: int = 0                   # the Order meter (run-wide; §9), lives on the run not here
var memorial: Array = []             # ids/snapshots of permadead heroes (Legacy candidates)
var gear_drops: Dictionary = {}      # Vector2i tile -> Array[gear id] dropped by the dead

# --- Progression-real batch (2026-07-02): car-modifier rules + Saboteur charges. ---
# Set once at car build (ModifierSystem.apply) or by abilities; all integer, all cloned.
var move_mod: int = 0                # Cramped: flat Move-range delta for EVERY unit this car
var displacement_mult: int = 1       # Zero-Stabilizer: multiplies top-level impulse force
var enemy_cover_mod: int = 0         # Sabotaged Security: delta to ENEMY effective cover
var accuracy_mod: int = 0            # Flickering Lights (sight_mod): flat to-hit delta, all shooters
var env_dot: int = 0                 # Open Roof: damage every unit takes each env phase
var env_status_bit: int = 0          # Open Roof: status bit applied to every unit each env phase
var reinforce_every: int = 0         # Lockdown: spawn a reinforcement every N env phases (0 = off)
var reinforce_timer: int = 0         # countdown to the next reinforcement
var reinforce_spawns: Array = []     # Array[Vector2i] candidate spawn tiles (stable order)
var traps_disabled_timer: int = 0    # System Seizure: cycling traps hold while > 0
var charges: Array = []              # Saboteur rigs: [{pos:Vector2i, dmg,force,radius,fuse:int}]

func init_grid(w: int, h: int) -> void:
	width = w
	height = h
	grid = []
	for y in range(h):
		var row: Array = []
		for x in range(w):
			row.append(SimTile.new())
		grid.append(row)

func in_bounds(p: Vector2i) -> bool:
	return p.x >= 0 and p.y >= 0 and p.x < width and p.y < height

func tile(p: Vector2i) -> SimTile:
	return grid[p.y][p.x]

func set_wall(p: Vector2i) -> void:
	if in_bounds(p):
		tile(p).terrain = E.Terrain.WALL

func add_entity(e: SimEntity) -> int:
	if e.id <= 0:
		e.id = next_id
		next_id += 1
	# Stamp the heal ceiling at spawn: a unit entering play caps at its entry HP.
	# Sites that spawn already-damaged bodies (UnitInstance.to_sim_entity) set max_hp first.
	if e.is_unit and e.max_hp <= 0:
		e.max_hp = e.hp
	entities[e.id] = e
	if in_bounds(e.pos):
		tile(e.pos).occupant_id = e.id
	return e.id

func occupant_at(p: Vector2i) -> SimEntity:
	if not in_bounds(p):
		return null
	var oid: int = tile(p).occupant_id
	if oid == -1:
		return null
	return entities.get(oid)

## Stable, sorted-by-id iteration — never rely on Dictionary order for outcomes.
func entity_ids_sorted() -> Array:
	var ids: Array = entities.keys()
	ids.sort()
	return ids

func clone() -> SimState:
	var s := SimState.new()
	s.width = width
	s.height = height
	s.next_id = next_id
	s.grid = []
	for y in range(height):
		var row: Array = []
		for x in range(width):
			row.append(grid[y][x].clone())
		s.grid.append(row)
	s.entities = {}
	for id in entities:
		s.entities[id] = entities[id].clone()
	if rng != null:
		s.rng = rng.clone()
	# Phase 4+ run-layer state: EVERY field must ride along so a resolver clone sees
	# the live rules (bleed-out gating) and writes made during resolution (Memorial /
	# gear drops) survive the commit — permadeath is sacred (§7.4).
	s.bleedout_enabled = bleedout_enabled
	s.down_enemies_too = down_enemies_too
	s.order = order
	s.memorial = memorial.duplicate(true)
	s.gear_drops = gear_drops.duplicate(true)
	s.move_mod = move_mod
	s.displacement_mult = displacement_mult
	s.enemy_cover_mod = enemy_cover_mod
	s.accuracy_mod = accuracy_mod
	s.env_dot = env_dot
	s.env_status_bit = env_status_bit
	s.reinforce_every = reinforce_every
	s.reinforce_timer = reinforce_timer
	s.reinforce_spawns = reinforce_spawns.duplicate()
	s.traps_disabled_timer = traps_disabled_timer
	s.charges = charges.duplicate(true)
	return s

## Commit: overwrite self with a resolved clone's world.
func adopt(other: SimState) -> void:
	width = other.width
	height = other.height
	next_id = other.next_id
	grid = []
	for y in range(height):
		var row: Array = []
		for x in range(width):
			row.append(other.grid[y][x].clone())
		grid.append(row)
	entities = {}
	for id in other.entities:
		entities[id] = other.entities[id].clone()
	if other.rng != null:
		rng = other.rng.clone()
	# Mirror clone(): the run-layer fields commit too (see clone() note).
	bleedout_enabled = other.bleedout_enabled
	down_enemies_too = other.down_enemies_too
	order = other.order
	memorial = other.memorial.duplicate(true)
	gear_drops = other.gear_drops.duplicate(true)
	move_mod = other.move_mod
	displacement_mult = other.displacement_mult
	enemy_cover_mod = other.enemy_cover_mod
	accuracy_mod = other.accuracy_mod
	env_dot = other.env_dot
	env_status_bit = other.env_status_bit
	reinforce_every = other.reinforce_every
	reinforce_timer = other.reinforce_timer
	reinforce_spawns = other.reinforce_spawns.duplicate()
	traps_disabled_timer = other.traps_disabled_timer
	charges = other.charges.duplicate(true)

## Deterministic textual fingerprint for golden / parity tests.
## NOTE: the leading "E.. hp int st" + "T.. L=" tokens are kept verbatim for the
## existing golden fixtures; Phase-2 status timers / gas+steam layers are appended.
func snapshot() -> String:
	var parts: Array = []
	for id in entity_ids_sorted():
		var e: SimEntity = entities[id]
		parts.append("E%d@%d,%d hp=%d int=%d st=%d" % [id, e.pos.x, e.pos.y, e.hp, e.integrity, e.status])
		if e.burn_timer != 0 or e.poison_timer != 0 or e.chill_stacks != 0 or e.blind_timer != 0 or e.suppress_timer != 0:
			parts.append("e%d b=%d p=%d c=%d bl=%d sup=%d" % [id, e.burn_timer, e.poison_timer, e.chill_stacks, e.blind_timer, e.suppress_timer])
		# Appended (only when non-default, so untouched fixtures keep their strings):
		# later-phase entity state — downed/bleed-out, set-piece timers, overwatch,
		# cover/facing, finale flags — so parity/determinism gates SEE divergence here.
		var fc_def := Vector2i(-1, 0)
		if e.downed or e.bleed_timer != 0 or e.buried_timer != 0 or e.net_timer != 0 \
				or e.overwatch or e.overwatch_used or e.cover != 0 or e.facing != fc_def \
				or e.pending_action != E.ConductorAction.NONE or e.conductor_shielded \
				or e.captain_gate_open:
			parts.append("x%d d=%d bl=%d bu=%d nt=%d ow=%d cv=%d fc=%d,%d pa=%d cs=%d gg=%d" % [
				id, int(e.downed), e.bleed_timer, e.buried_timer, e.net_timer,
				int(e.overwatch) + 2 * int(e.overwatch_used), e.cover,
				e.facing.x, e.facing.y, e.pending_action, int(e.conductor_shielded),
				int(e.captain_gate_open)])
		# Appended (only when non-default): progression-real combat-mutable fields —
		# timed buffs, per-fight consumables — so clone/adopt/parity gates SEE them.
		if e.acc_buff != 0 or e.acc_buff_timer != 0 or e.move_buff != 0 \
				or e.move_buff_timer != 0 or e.temp_resist_timer != 0 or e.first_hit_reduced != 0:
			parts.append("p%d ab=%d/%d mb=%d/%d tr=%d fh=%d" % [
				id, e.acc_buff, e.acc_buff_timer, e.move_buff, e.move_buff_timer,
				e.temp_resist_timer, e.first_hit_reduced])
		# Wave 3b (Firebrand momentum meter): emitted ONLY when a Firebrand carries stacks / an
		# armed Vanguard autocrit / a Last-Stand body — so every pre-momentum state is byte-identical.
		var mtok: String = e.momentum_fingerprint()
		if mtok != "":
			parts.append(mtok)
	for y in range(height):
		for x in range(width):
			var t: SimTile = grid[y][x]
			if t.status_layer != 0:
				parts.append("T%d,%d L=%d" % [x, y, t.status_layer])
			# Appended (only when non-default): terrain/hazard/occupancy/trap/gas/
			# set-piece tile state, so a clone/adopt hole in ANY tile field fails the gate.
			if t.terrain != E.Terrain.FLOOR or t.hazard != E.Hazard.NONE \
					or t.occupant_id != -1 or t.cover != 0 or t.flammable \
					or t.status_timer != 0 or t.gas_timer != 0 \
					or t.trap_period != 0 or t.trap_phase != 0 or t.trap_dir != 0 or t.trap_active \
					or t.friction != -1 or t.slope != Vector2i.ZERO or t.belt_dir != Vector2i.ZERO:
				parts.append("H%d,%d tr=%d hz=%d occ=%d cv=%d st=%d g=%d fl=%d tp=%d/%d/%d/%d fr=%d sl=%d,%d bd=%d,%d" % [
					x, y, t.terrain, t.hazard, t.occupant_id, t.cover, t.status_timer,
					t.gas_timer, int(t.flammable), t.trap_period, t.trap_phase, t.trap_dir,
					int(t.trap_active), t.friction, t.slope.x, t.slope.y, t.belt_dir.x, t.belt_dir.y])
	# Run-layer state (only when non-default): bleed-out gating, Order, Memorial, gear drops.
	if bleedout_enabled or down_enemies_too or order != 0:
		parts.append("RUN be=%d de=%d o=%d" % [int(bleedout_enabled), int(down_enemies_too), order])
	if not memorial.is_empty():
		var mm: Array = []
		for m in memorial:
			mm.append("%s:%s" % [str(m.get("instance_id", -1)), str(m.get("id", -1))])
		parts.append("MEM=" + ",".join(mm))
	if not gear_drops.is_empty():
		var gks: Array = gear_drops.keys()
		gks.sort()
		var gg: Array = []
		for k in gks:
			gg.append("%s=%d" % [str(k), (gear_drops[k] as Array).size()])
		parts.append("GEAR=" + ";".join(gg))
	# Appended (only when non-default): car-modifier rules + live charges, so a
	# clone/adopt hole in the progression-real state fails the determinism gates.
	if move_mod != 0 or displacement_mult != 1 or enemy_cover_mod != 0 or accuracy_mod != 0 \
			or env_dot != 0 or env_status_bit != 0 or reinforce_every != 0 \
			or traps_disabled_timer != 0 or not charges.is_empty():
		parts.append("CMOD mv=%d dm=%d ec=%d am=%d ed=%d es=%d rf=%d/%d td=%d ch=%d" % [
			move_mod, displacement_mult, enemy_cover_mod, accuracy_mod, env_dot,
			env_status_bit, reinforce_every, reinforce_timer, traps_disabled_timer,
			charges.size()])
	return " | ".join(parts)

## Environment phase: recede standing water, clear momentary electrification (Sub-Spec A6).
func tick_environment() -> void:
	for y in range(height):
		for x in range(width):
			var t: SimTile = grid[y][x]
			if t.has_layer(E.L_ELECTRIFIED):
				t.status_layer &= ~E.L_ELECTRIFIED
			if t.has_layer(E.L_WATER):
				t.status_timer -= 1
				if t.status_timer <= 0:
					t.status_layer &= ~E.L_WATER
	# Units no longer standing in water lose Soaked next turn.
	for id in entity_ids_sorted():
		var e: SimEntity = entities[id]
		if e.has_status(E.S_SOAKED):
			if not (in_bounds(e.pos) and tile(e.pos).has_layer(E.L_WATER)):
				e.clear_status(E.S_SOAKED)
