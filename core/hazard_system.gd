class_name HazardSystem
## Sub-Spec D — the environment-phase engine: cycling traps, spreading hazards
## (fire / gas / water), the D4 interaction matrix, and DoT application, in the
## fixed D5 order. RefCounted statics only — ZERO SceneTree, NO rng (every hazard
## outcome is purely deterministic; only to-hit ever touches the PRNG).
##
## TurnManager calls HazardSystem.tick(state) at the ENVIRONMENT phase. Iteration is
## always in explicit (y, x) tile order or entity_ids_sorted() so the whole phase is
## reproducible from (seed, state).
##
## D5 environment-phase order (do NOT reorder — preview == outcome depends on it):
##   1. tick cycling traps   (advance timers; fire telegraphed tiles; set telegraphs)
##   2. propagate spreading  (water recede; fire spread+burndown; gas expand+thin)
##   3. resolve interactions (water↔fire, water↔gas, fire↔gas→explosion, spark→shock)
##   4. apply DoTs           (Burning, Poisoned)
##   5. clear momentary      (electrified, expired steam, scorched bookkeeping)

const E = preload("res://core/sim_enums.gd")
const GE = preload("res://core/game_event.gd")
const Physics = preload("res://core/physics_resolver.gd")
const Status = preload("res://core/status_system.gd")
const Bleedout = preload("res://core/bleedout_system.gd")
const Ability = preload("res://core/ability_system.gd")
const SimEntityScript = preload("res://core/sim_entity.gd")

# Stable orthogonal neighbours (N, E, S, W) — matches the resolver's DIRS4.
const DIRS4 := [Vector2i(0, -1), Vector2i(1, 0), Vector2i(0, 1), Vector2i(-1, 0)]


## Full environment phase. Mutates `state` in place; returns the ordered event list.
static func tick(state) -> Array:
	var events: Array = []
	_tick_charges(state, events)           # Saboteur rigs: fuse countdown -> detonate
	_tick_setpiece_terrain(state, events)  # E1 (pre): slope gravity + scald-on-stand
	_tick_cycling_traps(state, events)     # D5.1 (now incl. conveyor belts + laser sweep)
	_propagate(state, events)              # D5.2
	_resolve_interactions(state, events)   # D5.3
	Status.tick_dots(state, events)        # D5.4
	_clear_momentary(state, events)        # D5.5
	_tick_setpiece_timers(state, events)   # E1 (post): buried/net dig-out countdown
	_tick_modifier_rules(state, events)    # car modifiers: exposure DoT + reinforcements
	_tick_buffs(state, events)             # timed buffs (Rally/Warcry/Rebreather) count down
	# Soaked wears off once a unit is no longer standing in water (kept from A6).
	for id in state.entity_ids_sorted():
		var e = state.entities.get(id)
		if e != null and e.has_status(E.S_SOAKED):
			if not (state.in_bounds(e.pos) and state.tile(e.pos).has_layer(E.L_WATER)):
				e.clear_status(E.S_SOAKED)
				events.push_back(GE.new(E.Ev.STATUS_CLEAR, {"id": id, "status": E.S_SOAKED}))
	return events


# ===== Progression-real batch (2026-07-02): charges, buffs, car-modifier rules =====

## Saboteur demolition charges: fuses burn down each env phase; at 0 the charge fires
## through the SAME resolver blast Remote Detonate uses. Stable placement order.
static func _tick_charges(state, events: Array) -> void:
	if state.charges.is_empty():
		return
	var still_armed: Array = []
	for ch in state.charges:
		ch["fuse"] = int(ch.get("fuse", 1)) - 1
		if ch["fuse"] <= 0:
			Ability.detonate_charge(state, ch, events)
		else:
			still_armed.push_back(ch)
	state.charges = still_armed


## Timed stat buffs (Rally / Warcry) + Rebreather resistance count down and expire.
static func _tick_buffs(state, events: Array) -> void:
	for id in state.entity_ids_sorted():
		var e = state.entities.get(id)
		if e == null or not e.is_unit:
			continue
		if e.acc_buff_timer > 0:
			e.acc_buff_timer -= 1
			if e.acc_buff_timer <= 0 and e.acc_buff != 0:
				e.acc_buff = 0
				events.push_back(GE.new(E.Ev.BUFF_EXPIRE, {"id": id, "stat": "accuracy"}))
		if e.move_buff_timer > 0:
			e.move_buff_timer -= 1
			if e.move_buff_timer <= 0 and e.move_buff != 0:
				e.move_buff = 0
				events.push_back(GE.new(E.Ev.BUFF_EXPIRE, {"id": id, "stat": "move"}))
		if e.temp_resist_timer > 0:
			e.temp_resist_timer -= 1
			if e.temp_resist_timer <= 0:
				events.push_back(GE.new(E.Ev.BUFF_EXPIRE, {"id": id, "stat": "resist"}))


## Car-modifier per-turn rules: Open Roof exposure (DoT + status on EVERY unit) and
## Lockdown timed reinforcements (a fresh guard through the rear door). Deterministic,
## rng-free — the reinforcement uses fixed tier-1 truncheon_guard stats (kept in sync
## with content/enemies/roster.json) on the first open authored spawn tile.
static func _tick_modifier_rules(state, events: Array) -> void:
	# System Seizure countdown lives here too (its gate is read by _tick_cycling_traps).
	if state.traps_disabled_timer > 0:
		state.traps_disabled_timer -= 1
	if state.env_dot > 0 or state.env_status_bit != 0:
		for id in state.entity_ids_sorted():
			var e = state.entities.get(id)
			if e == null or not e.is_unit or not e.alive:
				continue
			if state.env_dot > 0:
				e.take_damage(state.env_dot)
				events.push_back(GE.new(E.Ev.EXPOSURE_TICK, {"id": id, "dmg": state.env_dot}))
				_kill_if_dead(state, e, events)
				if not e.alive:
					continue
			if state.env_status_bit == E.S_CHILLED:
				Status.apply_chill(e, events)
			elif state.env_status_bit != 0 and not e.has_status(state.env_status_bit):
				e.add_status(state.env_status_bit)
				events.push_back(GE.new(E.Ev.STATUS_APPLY, {"id": id, "status": state.env_status_bit}))
	if state.reinforce_every > 0:
		state.reinforce_timer -= 1
		if state.reinforce_timer <= 0:
			state.reinforce_timer = state.reinforce_every
			_spawn_reinforcement(state, events)


static func _spawn_reinforcement(state, events: Array) -> void:
	# W2-9: tier the rear-door reinforcement to the car's SECTION. SimState has no section
	# field (out of this lane), but the car is already populated with section-scaled enemies,
	# so we MIRROR a section-appropriate template: the strongest MOBILE ordinary enemy present
	# (captains, anchored turrets and deployed bots are never templates). A S4/S5 lockdown thus
	# reinforces with S4/S5 troops, not tail chaff. Deterministic (stable entity_ids_sorted scan,
	# strict > keeps the lowest id on a tie); rng-free. Falls back to a tier-1 truncheon_guard
	# only when no mobile ordinary enemy remains (mirrors the previous hardcoded behavior).
	var tmpl = _reinforcement_template(state)
	for sp in state.reinforce_spawns:
		if state.in_bounds(sp) and state.occupant_at(sp) == null \
				and state.tile(sp).terrain != E.Terrain.WALL:
			var g = SimEntityScript.new()
			g.is_unit = true
			g.pos = sp
			g.integrity = -1
			g.faction = E.Faction.ENEMY
			if tmpl != null:
				g.name = tmpl.name
				g.mass = tmpl.mass
				g.hp = tmpl.max_hp if tmpl.max_hp > 0 else tmpl.hp
				g.movable = tmpl.movable
				g.accuracy = tmpl.accuracy
				g.move_range = tmpl.move_range
				g.ai_profile = tmpl.ai_profile
				g.phys_trait = tmpl.phys_trait
			else:
				g.name = "truncheon_guard"
				g.mass = E.Mass.MEDIUM
				g.hp = 6
				g.accuracy = 55
				g.move_range = 4
			state.add_entity(g)
			events.push_back(GE.new(E.Ev.SPAWNED, {"id": g.id, "pos": sp, "what": "reinforcement"}))
			return


## The section-appropriate reinforcement template: the toughest MOBILE ordinary ENEMY unit
## currently in play (by max_hp/hp; stable id tiebreak). Excludes captains, anchored turrets
## and deployed bots. Returns null when none qualifies (caller falls back to a tier-1 guard).
static func _reinforcement_template(state):
	var best = null
	var best_cap: int = -1
	for id in state.entity_ids_sorted():
		var e = state.entities.get(id)
		if e == null or not e.is_unit or not e.alive or e.faction != E.Faction.ENEMY:
			continue
		if e.captain_key != "" or not e.movable or e.mass == E.Mass.ANCHORED:
			continue
		if e.name == "" or e.name == "deployed_bot":
			continue
		var cap: int = e.max_hp if e.max_hp > 0 else e.hp
		if cap > best_cap:
			best_cap = cap
			best = e
	return best


# ============================ D5.1 — CYCLING TRAPS =============================
# Each cycling-trap tile owns (trap_period, trap_phase, trap_active). Phase 0 == FIRE.
# We telegraph the tiles that will fire NEXT turn (phase wraps to 0), so the renderer
# shows danger one turn ahead. A disabled trap (trap_active=false) does nothing.
static func _tick_cycling_traps(state, events: Array) -> void:
	# Clear last turn's telegraphs first; we re-stamp the ones still pending below.
	for y in range(state.height):
		for x in range(state.width):
			var t = state.grid[y][x]
			if t.has_layer(E.L_TELEGRAPH):
				t.status_layer &= ~E.L_TELEGRAPH

	# System Seizure (Saboteur): every cycling trap holds frozen — no advance, no fire,
	# no telegraph — while the disable window is open (counted down in _tick_modifier_rules).
	if state.traps_disabled_timer > 0:
		return

	# Advance + fire, in stable (y, x) order.
	for y in range(state.height):
		for x in range(state.width):
			var p := Vector2i(x, y)
			var t = state.grid[y][x]
			if t.trap_period <= 0 or not _is_cycling(t.hazard) or not t.trap_active:
				continue
			t.trap_phase = (t.trap_phase + 1) % t.trap_period
			if t.trap_phase == 0:
				_fire_trap(state, p, t, events)

	# Re-stamp telegraphs for traps that will fire NEXT env phase.
	for y in range(state.height):
		for x in range(state.width):
			var t2 = state.grid[y][x]
			if t2.trap_period <= 0 or not _is_cycling(t2.hazard) or not t2.trap_active:
				continue
			if t2.hazard == E.Hazard.CONVEYOR:
				continue   # a belt is continuous (telegraphTurns: 0) — never telegraphs
			var next_phase: int = (t2.trap_phase + 1) % t2.trap_period
			if next_phase == 0:
				for fp in _trap_fire_tiles(state, Vector2i(x, y), t2):
					if state.in_bounds(fp):
						state.tile(fp).status_layer |= E.L_TELEGRAPH
						events.push_back(GE.new(E.Ev.TRAP_TELEGRAPH, {"origin": Vector2i(x, y), "tile": fp, "hazard": t2.hazard}))


static func _is_cycling(hz: int) -> bool:
	return hz == E.Hazard.VENT or hz == E.Hazard.LASER or hz == E.Hazard.PLATE \
		or hz == E.Hazard.PISTON or hz == E.Hazard.STEAM \
		or hz == E.Hazard.LASER_SWEEP or hz == E.Hazard.CONVEYOR


## The set of tiles a trap affects when it fires (shape per hazard type).
static func _trap_fire_tiles(state, origin: Vector2i, t) -> Array:
	var tiles: Array = []
	match t.hazard:
		E.Hazard.VENT, E.Hazard.PLATE, E.Hazard.STEAM, E.Hazard.CONVEYOR:
			tiles.append(origin)
		E.Hazard.LASER, E.Hazard.LASER_SWEEP:
			# A beam straight along trap_dir until a WALL stops it (the lane it cuts).
			# A SWEEP uses the same trace; its trap_dir rotates one facing per fire (D2.2).
			var dir: Vector2i = _dir_from_code(t.trap_dir)
			var cur: Vector2i = origin
			var guard: int = 0
			while guard < 64:
				guard += 1
				cur = cur + dir
				if not state.in_bounds(cur) or state.tile(cur).terrain == E.Terrain.WALL:
					break
				tiles.append(cur)
		E.Hazard.PISTON:
			# Slams a short line outward along trap_dir.
			var pdir: Vector2i = _dir_from_code(t.trap_dir)
			for i in range(1, 3):
				tiles.append(origin + pdir * i)
	return tiles


static func _fire_trap(state, origin: Vector2i, t, events: Array) -> void:
	events.push_back(GE.new(E.Ev.TRAP_FIRE, {"origin": origin, "hazard": t.hazard}))
	var tiles: Array = _trap_fire_tiles(state, origin, t)
	match t.hazard:
		E.Hazard.VENT:
			# Fire burst: ignites the tile (fire layer) + Burning on any occupant.
			for p in tiles:
				if not state.in_bounds(p):
					continue
				_light_fire(state, p, events)
		E.Hazard.LASER, E.Hazard.LASER_SWEEP:
			# Damages everything in the beam + ignites fire layer (so it ignites GAS in D3).
			for p in tiles:
				if not state.in_bounds(p):
					continue
				var occ = state.occupant_at(p)
				if occ != null:
					occ.take_damage(E.FIRE_DAMAGE + 1)
					_kill_if_dead(state, occ, events)
				_light_fire(state, p, events)
			# A SWEEP rotates its emitter one cardinal facing per fire (the arc steps, D2.2).
			if t.hazard == E.Hazard.LASER_SWEEP:
				t.trap_dir = (t.trap_dir + 1) % 4
		E.Hazard.CONVEYOR:
			# A belt drifts its occupant one tile in belt_dir (continuous forced movement).
			_belt_drift(state, origin, t, events)
		E.Hazard.STEAM:
			# Steam cloud: blinds occupant + blocks LoS; boils off water on its tile.
			for p in tiles:
				if not state.in_bounds(p):
					continue
				var tile = state.tile(p)
				if tile.has_layer(E.L_WATER):
					tile.status_layer &= ~E.L_WATER  # steam dries water (D4)
				tile.status_layer |= E.L_STEAM
				tile.status_timer = max(tile.status_timer, E.STEAM_DURATION)
				var so = state.occupant_at(p)
				if so != null and so.is_unit:
					Status.apply_blind(so, events)
					Status.thaw(so, events)  # steam is hot -> thaws chill
		E.Hazard.PLATE:
			# Electrified plate: shock to anything standing on it; chains through water.
			for p in tiles:
				if not state.in_bounds(p):
					continue
				var tile2 = state.tile(p)
				tile2.status_layer |= E.L_ELECTRIFIED
				var po = state.occupant_at(p)
				if po != null and po.is_unit:
					po.take_damage(E.SHOCK_DAMAGE)
					_apply(po, E.S_SHOCKED, events)
					events.push_back(GE.new(E.Ev.SHOCK, {"id": po.id, "dmg": E.SHOCK_DAMAGE}))
					_kill_if_dead(state, po, events)
		E.Hazard.PISTON:
			# Slam outward: impact damage + an outward impulse that starts a new chain.
			for p in tiles:
				if not state.in_bounds(p):
					continue
				var occ2 = state.occupant_at(p)
				if occ2 != null and occ2.movable:
					var pdir: Vector2i = _dir_from_code(t.trap_dir)
					var rr = Physics.resolve_impulse(state, occ2.id, pdir, E.PISTON_DAMAGE, false)
					state.adopt(rr.state)
					for ev in rr.events:
						events.push_back(ev)


# ============================ D5.2 — PROPAGATION ==============================
static func _propagate(state, events: Array) -> void:
	# (a) Water recedes (kept from Sub-Spec A6).
	for y in range(state.height):
		for x in range(state.width):
			var t = state.grid[y][x]
			if t.has_layer(E.L_WATER):
				t.status_timer -= 1
				if t.status_timer <= 0:
					t.status_layer &= ~E.L_WATER

	# (b) Fire spreads to adjacent flammables, refreshes Burning on occupants, burns down.
	_propagate_fire(state, events)

	# (c) Gas expands fuel-free up to its radius, refreshes Poisoned, thins at edges.
	_propagate_gas(state, events)


static func _propagate_fire(state, events: Array) -> void:
	# Snapshot the current fire frontier so spread this turn is a single deterministic
	# wave (newly-lit tiles don't cascade further in the same turn).
	var burning: Array = []
	for y in range(state.height):
		for x in range(state.width):
			if state.grid[y][x].has_layer(E.L_FIRE):
				burning.append(Vector2i(x, y))

	# Spread onto flammable neighbours (in stable order).
	var to_light: Array = []
	for p in burning:
		for dd in DIRS4:
			var np: Vector2i = p + dd
			if not state.in_bounds(np):
				continue
			var nt = state.tile(np)
			if nt.has_layer(E.L_FIRE):
				continue
			if nt.terrain == E.Terrain.WALL or nt.has_layer(E.L_WATER):
				continue   # non-flammable / wet blocks the front
			if _tile_is_flammable(state, np):
				to_light.append(np)
	for np in to_light:
		_light_fire(state, np, events)
		events.push_back(GE.new(E.Ev.FIRE_SPREAD, {"pos": np}))

	# Refresh Burning on occupants of fire tiles; burn down each original fire tile.
	for p in burning:
		var occ = state.occupant_at(p)
		if occ != null and occ.is_unit:
			Status.apply_burning(occ, events)
			Status.thaw(occ, events)   # fire is hot — thaws Frozen/Chilled (§5.5)
		var t = state.tile(p)
		t.status_timer -= 1
		if t.status_timer <= 0:
			t.status_layer &= ~E.L_FIRE
			t.status_layer |= E.L_SCORCHED   # leaves a passable scorched tile
			t.flammable = false              # fuel consumed
			events.push_back(GE.new(E.Ev.FIRE_OUT, {"pos": p}))


static func _propagate_gas(state, events: Array) -> void:
	# Snapshot current gas tiles; expand by one ring (fuel-free) within max radius of
	# the densest origin, then thin edges. We track radius via the gas_timer field:
	# a freshly-spread tile starts at GAS_DURATION; edges (timer low) clear first.
	var gas: Array = []
	for y in range(state.height):
		for x in range(state.width):
			if state.grid[y][x].has_layer(E.L_GAS):
				gas.append(Vector2i(x, y))
	if gas.is_empty():
		return

	# Expand: each gas tile seeds its open orthogonal neighbours (one tile/turn).
	var to_fill: Array = []
	for p in gas:
		var src = state.tile(p)
		if src.gas_timer <= 1:
			continue  # an exhausted tile doesn't seed new gas
		for dd in DIRS4:
			var np: Vector2i = p + dd
			if not state.in_bounds(np):
				continue
			var nt = state.tile(np)
			if nt.has_layer(E.L_GAS) or nt.terrain == E.Terrain.WALL:
				continue
			if nt.has_layer(E.L_WATER):
				continue  # water disperses / blocks the cloud
			if to_fill.find(np) == -1:
				to_fill.append(np)
	for np in to_fill:
		var nt2 = state.tile(np)
		nt2.status_layer |= E.L_GAS
		nt2.gas_timer = E.GAS_DURATION - 1   # newly spread, slightly less dense
		events.push_back(GE.new(E.Ev.GAS_SPREAD, {"pos": np}))

	# Refresh Poisoned on occupants; thin every pre-existing gas tile.
	for p in gas:
		var occ = state.occupant_at(p)
		if occ != null and occ.is_unit:
			Status.apply_poison(occ, events)
		var t = state.tile(p)
		t.gas_timer -= 1
		if t.gas_timer <= 0:
			t.status_layer &= ~E.L_GAS
			events.push_back(GE.new(E.Ev.GAS_CLEAR, {"pos": p}))


# ============================ D5.3 — INTERACTION MATRIX =======================
# D4 as one deterministic pass over tiles in (y, x) order. Precedence:
#   Water beats Fire (extinguish); Fire+Gas beats everything (ignite→explosion);
#   Water disperses Gas; spark+water electrifies. Explosions enqueue impulses that
#   run NOW through the Sub-Spec A resolver (state.adopt) so bodies fly + chain.
static func _resolve_interactions(state, events: Array) -> void:
	var explosions: Array = []   # collected, then resolved in stable order
	for y in range(state.height):
		for x in range(state.width):
			var p := Vector2i(x, y)
			var t = state.grid[y][x]
			var has_water: bool = t.has_layer(E.L_WATER)
			var has_fire: bool = t.has_layer(E.L_FIRE)
			var has_gas: bool = t.has_layer(E.L_GAS)
			var has_spark: bool = _tile_has_spark(state, p)

			# Fire + Gas (or Gas + any ignition) -> IGNITE -> explosion over the volume.
			if has_gas and (has_fire or has_spark):
				events.push_back(GE.new(E.Ev.IGNITE, {"pos": p}))
				explosions.append(p)
				continue
			# Water beats Fire on the tile (extinguish / boil-off).
			if has_water and has_fire:
				t.status_layer &= ~E.L_FIRE
				events.push_back(GE.new(E.Ev.EXTINGUISH, {"pos": p}))
			# Water disperses Gas.
			if has_water and has_gas:
				t.status_layer &= ~E.L_GAS
				events.push_back(GE.new(E.Ev.DISPERSE, {"pos": p}))

	# Resolve every ignite as a one-shot blast through the resolver (radial impulse).
	for origin in explosions:
		_explode(state, origin, events)


static func _explode(state, origin: Vector2i, events: Array) -> void:
	# Clear the ignited gas across the blast volume + seed residual fire on flammables;
	# then run the radial impulse through the pure resolver and adopt the result.
	var r: int = E.EXPLOSION_RADIUS
	for y in range(state.height):
		for x in range(state.width):
			var d: int = abs(x - origin.x) + abs(y - origin.y)
			if d > r:
				continue
			var t = state.grid[y][x]
			if t.has_layer(E.L_GAS):
				t.status_layer &= ~E.L_GAS          # explosion consumes the gas (D4)
				t.gas_timer = 0
			if t.flammable and not t.has_layer(E.L_WATER):
				_light_fire(state, Vector2i(x, y), events)  # residual fire on fuel
	var rr = Physics.resolve_explosion(state, origin, r, E.EXPLOSION_DAMAGE, E.EXPLOSION_FORCE)
	state.adopt(rr.state)
	for ev in rr.events:
		events.push_back(ev)


# ============================ D5.5 — CLEAR MOMENTARY ==========================
static func _clear_momentary(state, events: Array) -> void:
	for y in range(state.height):
		for x in range(state.width):
			var t = state.grid[y][x]
			if t.has_layer(E.L_ELECTRIFIED):
				t.status_layer &= ~E.L_ELECTRIFIED   # one-burst, gone next phase
			if t.has_layer(E.L_STEAM):
				t.status_timer -= 1
				if t.status_timer <= 0:
					t.status_layer &= ~E.L_STEAM


# ============================ E1 — SET-PIECE TERRAIN ==========================
# Pre-step (E1.1 / E1.2): an unsupported entity on a steep tile slides downhill one
# tile (a gentle gravity tick), and a unit standing on a SCALD tile takes scald damage
# (cancelling cold). Both deterministic, no rng. Slope-slide routes through the resolver
# so the slide can chain/impact like any shove.
static func _tick_setpiece_terrain(state, events: Array) -> void:
	# Scald-on-stand (static hot tile). Sorted entity order for determinism.
	for id in state.entity_ids_sorted():
		var e = state.entities.get(id)
		if e == null or not e.is_unit or not e.alive:
			continue
		if state.in_bounds(e.pos) and state.tile(e.pos).hazard == E.Hazard.SCALD:
			e.take_damage(E.SCALD_DAMAGE)
			events.push_back(GE.new(E.Ev.SCALD, {"id": id, "dmg": E.SCALD_DAMAGE}))
			Status.thaw(e, events)   # heat cancels Chilled/Frozen (E1.2)
			_kill_if_dead(state, e, events)

	# Slope gravity tick (E1.1): an entity on a sloped tile drifts one tile downhill.
	# Buried/netted/anchored entities stay put. Stable (y, x) scan; route each slide
	# through the resolver so it can hit walls/bodies/the ledge.
	var sliders: Array = []
	for y in range(state.height):
		for x in range(state.width):
			var t = state.grid[y][x]
			if t.slope == Vector2i.ZERO:
				continue
			var occ = state.occupant_at(Vector2i(x, y))
			if occ == null or not occ.movable or not occ.alive:
				continue
			if occ.has_status(E.S_BURIED) or occ.has_status(E.S_NETTED):
				continue
			sliders.append(occ.id)
	for sid in sliders:
		var occ2 = state.entities.get(sid)
		if occ2 == null or not occ2.alive:
			continue
		var sdir: Vector2i = state.tile(occ2.pos).slope
		events.push_back(GE.new(E.Ev.SLOPE_SLIDE, {"id": sid, "dir": sdir}))
		# Gentle gravity tick: force == mass drifts ~one tile; the slope's own +1 carries
		# it a little further (the "amplify" of E1.1) and ICE underfoot lets it run.
		var rr = Physics.resolve_impulse(state, sid, sdir, occ2.mass, false)
		state.adopt(rr.state)
		for ev in rr.events:
			events.push_back(ev)


# Post-step (E1.6 / Net Gunner): buried + netted units count down their immobilize
# timers; when a timer hits 0 the unit digs/breaks free (S_BURIED / S_NETTED clear).
static func _tick_setpiece_timers(state, events: Array) -> void:
	for id in state.entity_ids_sorted():
		var e = state.entities.get(id)
		if e == null or not e.is_unit or not e.alive:
			continue
		if e.buried_timer > 0:
			e.buried_timer -= 1
			if e.buried_timer <= 0 and e.has_status(E.S_BURIED):
				e.clear_status(E.S_BURIED)
				events.push_back(GE.new(E.Ev.DIG_OUT, {"id": id}))
		# NOTE (W2-1): the Net immobilize timer is NO LONGER decayed here. It is consumed at
		# the victim's own faction AP refresh (TurnManager._refresh_ap_for), so a player netted
		# during the ENEMY phase keeps S_NETTED across this ENVIRONMENT phase and actually loses
		# its next activation. Decaying it here cleared it one phase too early (the net-vs-player
		# no-op). Buried above is applied IN the env phase, so it still counts down here.


# E1.5 — drift the occupant of a belt tile one tile along belt_dir (continuous force).
static func _belt_drift(state, origin: Vector2i, t, events: Array) -> void:
	if t.belt_dir == Vector2i.ZERO:
		return
	var occ = state.occupant_at(origin)
	if occ == null or not occ.movable or not occ.alive:
		return
	if occ.has_status(E.S_BURIED) or occ.has_status(E.S_NETTED):
		return
	events.push_back(GE.new(E.Ev.BELT_DRIFT, {"id": occ.id, "dir": t.belt_dir}))
	# A belt drifts exactly one tile on normal floor: force == mass enters one tile then
	# stops (m = mass - mass = 0). On ICE the frictionless tile lets the slide run on —
	# belts stack with ice/slope for chaos (E1.5), and that falls out of the resolver.
	var rr = Physics.resolve_impulse(state, occ.id, t.belt_dir, occ.mass, false)
	state.adopt(rr.state)
	for ev in rr.events:
		events.push_back(ev)


# ============================ HELPERS =========================================
## Light a fire on a tile + Burning on its occupant. A unit standing here is burnt now.
static func _light_fire(state, p: Vector2i, events: Array) -> void:
	if not state.in_bounds(p):
		return
	var t = state.tile(p)
	if t.terrain == E.Terrain.WALL or t.has_layer(E.L_WATER):
		return  # fire never establishes on a wall or wet tile
	t.status_layer |= E.L_FIRE
	t.status_layer &= ~E.L_SCORCHED
	t.status_timer = max(t.status_timer, E.FIRE_DURATION)
	var occ = state.occupant_at(p)
	if occ != null and occ.is_unit:
		Status.apply_burning(occ, events)
		Status.thaw(occ, events)  # fire thaws Frozen/Chilled (heat)


## A tile carries fuel for fire if explicitly flammable, or a flammable object sits on it.
static func _tile_is_flammable(state, p: Vector2i) -> bool:
	if not state.in_bounds(p):
		return false
	var t = state.tile(p)
	if t.flammable:
		return true
	var occ = state.occupant_at(p)
	if occ != null and not occ.is_unit and occ.flammable:
		return true
	return false


## A tile sees an ignition spark if it is/borders a live rail, furnace, power source,
## an active electrified plate (electrified layer), or an active fire/laser trap tile.
static func _tile_has_spark(state, p: Vector2i) -> bool:
	if not state.in_bounds(p):
		return false
	var t = state.tile(p)
	if t.has_layer(E.L_ELECTRIFIED):
		return true
	if t.hazard == E.Hazard.FURNACE or t.hazard == E.Hazard.RAIL_LIVE:
		return true
	for dd in DIRS4:
		var np: Vector2i = p + dd
		if not state.in_bounds(np):
			continue
		var nt = state.tile(np)
		if nt.hazard == E.Hazard.FURNACE or nt.hazard == E.Hazard.RAIL_LIVE:
			return true
		if nt.has_layer(E.L_ELECTRIFIED):
			return true
		var occ = state.occupant_at(np)
		if occ != null and occ.is_power_source:
			return true
	return false


static func _dir_from_code(code: int) -> Vector2i:
	match code:
		0: return Vector2i(1, 0)
		1: return Vector2i(0, 1)
		2: return Vector2i(-1, 0)
		3: return Vector2i(0, -1)
	return Vector2i(1, 0)


static func _apply(e, s: int, events: Array) -> void:
	if not e.has_status(s):
		e.add_status(s)
		events.push_back(GE.new(E.Ev.STATUS_APPLY, {"id": e.id, "status": s}))


static func _kill_if_dead(state, e, events: Array) -> void:
	if e.is_unit and e.alive and e.hp <= 0:
		# §7.4: hazard lethality funnels through the SAME decision every death path uses —
		# the bleed-out window opens (and permadeath is RECORDED) when the gate is on. With
		# bleedout_enabled false, down_or_kill erases + emits UNIT_DOWNED/UNIT_DEATH exactly
		# like the old inline branch, so pre-Phase-4 fixtures are byte-identical.
		Bleedout.down_or_kill(state, e, events)
	elif not e.is_unit and e.integrity <= 0 and e.alive:
		# A hazard-destroyed object breaks through the SAME on_break chain physics contact
		# uses (OBJECT_BREAK + FLOOD/EXPLODE/... effects) — no more silent vanishing, and
		# a laser CAN detonate a barrel / burst a tank (Sub-Spec A4.4 chain contract).
		var rr = Physics.resolve_break(state, e.id)
		state.adopt(rr.state)
		for ev in rr.events:
			events.push_back(ev)
