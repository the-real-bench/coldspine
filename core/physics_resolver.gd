class_name PhysicsResolver
## The load-bearing differentiator (GDD §6, Sub-Spec A).
## A deterministic, PURE, integer impulse-and-collision resolver.
##   - Deterministic: same (state, impulse) -> same ResolutionResult, forever.
##   - Pure: never mutates `live`; works on a clone, returns events + resolved state.
##   - Terminating: every chain provably ends (momentum strictly decreases).
## The SAME function produces the preview (dry_run) and the committed result, so
## what the player previews is exactly what happens (Into-the-Breach property).

const E = preload("res://core/sim_enums.gd")
const GE = preload("res://core/game_event.gd")
const RR = preload("res://core/resolution_result.gd")
const BleedoutSystem = preload("res://core/bleedout_system.gd")

# Orthogonal neighbours in a fixed, stable order (N, E, S, W) — never reorder.
const DIRS4 := [Vector2i(0, -1), Vector2i(1, 0), Vector2i(0, 1), Vector2i(-1, 0)]


## Public entry point. `dir` is a unit step vector; `force` is the initial momentum M.
## `dry_run` is cosmetic — the computation is identical either way (that's the guarantee).
static func resolve_impulse(live, entity_id: int, dir: Vector2i, force: int, _dry_run: bool = true):
	var state = live.clone()
	var events: Array = []
	var impulse_q: Array = []   # FIFO of {id, dir, M}
	var effect_q: Array = []    # FIFO of {kind, ...}

	# Zero-Stabilizer Section (car modifier): every top-level impulse hits harder.
	# Default (displacement_mult == 1) is byte-identical to the original behavior.
	force *= max(1, state.displacement_mult)

	# Phase 5 (§12) — enemy physics traits gate an INCOMING shove before it starts moving.
	# All default-trait (NONE) entities keep the original behavior exactly, so the 494
	# pre-Phase-5 fixtures are untouched (they never set phys_trait).
	var seed_e = state.entities.get(entity_id)
	if seed_e != null:
		force = _apply_shove_resistance(seed_e, dir, force, events)
		if force <= 0:
			return RR.new(events, state)

	impulse_q.push_back({"id": entity_id, "dir": dir, "M": force})

	# Main loop (Sub-Spec A5): drain ALL impulses, then ALL effects, repeat.
	while not impulse_q.is_empty() or not effect_q.is_empty():
		while not impulse_q.is_empty():
			_resolve_one_impulse(state, impulse_q.pop_front(), impulse_q, effect_q, events)
		while not effect_q.is_empty():
			_resolve_effect(state, effect_q.pop_front(), impulse_q, effect_q, events)

	return RR.new(events, state)


# --- Phase 5 (§12) enemy physics traits: gate / soften an INCOMING shove force ------
# Pure + deterministic. Returns the effective force (0 => the shove is fully resisted,
# which emits a SHOVE_RESISTED event and the entity does not move). Default-trait
# entities (PhysTrait.NONE) return `force` unchanged — preserving every prior fixture.
static func _apply_shove_resistance(e, dir: Vector2i, force: int, events: Array) -> int:
	match e.phys_trait:
		E.PhysTrait.BLOCKS_FRONTAL_SHOVE:
			# A Riot Shield resists a shove that hits its FACING (attacker stands in front,
			# i.e. the push direction equals the shield's facing). Hit from flank/behind it
			# folds like anyone else.
			if dir == e.facing:
				events.push_back(GE.new(E.Ev.SHOVE_RESISTED, {"id": e.id, "trait": e.phys_trait}))
				return 0
			return force
		E.PhysTrait.UNSHOVABLE_UNTIL_SOAKED:
			# Immovable until you Soak it (the captain "key"): a dry target eats the shove.
			if not e.has_status(E.S_SOAKED):
				events.push_back(GE.new(E.Ev.SHOVE_RESISTED, {"id": e.id, "trait": e.phys_trait}))
				return 0
			return force
		E.PhysTrait.MAGNETIC_BOOTS:
			# Boots bleed momentum off an incoming shove; a weak shove fizzles.
			var reduced: int = force - E.MAGNETIC_BOOTS_RESIST
			if reduced <= 0:
				events.push_back(GE.new(E.Ev.SHOVE_RESISTED, {"id": e.id, "trait": e.phys_trait}))
				return 0
			return reduced
		E.PhysTrait.STATIC_DESTRUCTIBLE:
			# A bolted-down Sentry Turret never slides (it is destroyed, not displaced).
			events.push_back(GE.new(E.Ev.SHOVE_RESISTED, {"id": e.id, "trait": e.phys_trait}))
			return 0
		_:
			# Magnetic Boots as a worn ITEM (gear-stamped shove_resist) — same math as
			# the enemy trait: bleed momentum off the shove; a weak one fizzles.
			if e.shove_resist > 0:
				var reduced_item: int = force - e.shove_resist
				if reduced_item <= 0:
					events.push_back(GE.new(E.Ev.SHOVE_RESISTED, {"id": e.id, "trait": e.phys_trait}))
					return 0
				return reduced_item
			return force


## Public explosion entry (Sub-Spec D4 IGNITE / explosive on_break): a one-time blast
## over a volume — damage + outward radial impulse to every entity inside, resolved
## through the SAME pure clone+queue machinery, so preview == commit holds for the
## hazard system too. Returns a ResolutionResult; caller adopts result.state.
static func resolve_explosion(live, origin: Vector2i, radius: int, damage: int, force: int):
	var state = live.clone()
	var events: Array = []
	var impulse_q: Array = []
	var effect_q: Array = []
	effect_q.push_back({"kind": E.Effect.EXPLODE, "origin": origin, "radius": radius,
		"damage": damage, "force": force})
	while not impulse_q.is_empty() or not effect_q.is_empty():
		while not impulse_q.is_empty():
			_resolve_one_impulse(state, impulse_q.pop_front(), impulse_q, effect_q, events)
		while not effect_q.is_empty():
			_resolve_effect(state, effect_q.pop_front(), impulse_q, effect_q, events)
	return RR.new(events, state)


## Public break entry: an object destroyed OUTSIDE the impulse path (hazard damage,
## gunfire) breaks through the SAME on_break chain physics contact uses — OBJECT_BREAK
## event + FLOOD/EXPLODE/TOPPLE/... effects on the same pure clone+queue machinery, so
## nothing ever vanishes silently. Returns a ResolutionResult; caller adopts result.state.
static func resolve_break(live, obj_id: int):
	var state = live.clone()
	var events: Array = []
	var impulse_q: Array = []
	var effect_q: Array = []
	var obj = state.entities.get(obj_id)
	if obj == null or obj.is_unit or not obj.alive:
		return RR.new(events, state)
	_break_object(state, obj, effect_q, events)
	while not impulse_q.is_empty() or not effect_q.is_empty():
		while not impulse_q.is_empty():
			_resolve_one_impulse(state, impulse_q.pop_front(), impulse_q, effect_q, events)
		while not effect_q.is_empty():
			_resolve_effect(state, effect_q.pop_front(), impulse_q, effect_q, events)
	return RR.new(events, state)


# --- One forced-movement impulse: walk tile-by-tile per A4 ----------------------
static func _resolve_one_impulse(state, imp: Dictionary, impulse_q: Array, effect_q: Array, events: Array) -> void:
	var e = state.entities.get(imp.id)
	if e == null or not e.alive or not e.movable:
		return
	var dir: Vector2i = imp.dir
	var m: int = imp.M

	while m > 0:
		var nxt: Vector2i = e.pos + dir
		# Phase 5 E1.1 — slope amplifies (downhill) / saps (uphill) momentum at the
		# instant of entering `nxt`. ZERO-slope tiles (every prior fixture) are a no-op.
		m = _slope_adjust(state, e.pos, dir, m)
		if m <= 0:
			return  # the climb sapped the last of the momentum — gentle stop
		var m_impact: int = m   # momentum carried at the instant of trying to enter `nxt`

		# A4.1 — out of bounds / WALL
		if not state.in_bounds(nxt) or state.tile(nxt).terrain == E.Terrain.WALL:
			_impact_wall(state, e, m_impact, events)
			return

		var occ = state.occupant_at(nxt)
		if occ != null:
			if occ.is_unit:
				# A4.2 — billiards body collision
				_collide_body(state, e, occ, m_impact, dir, impulse_q, events)
				return
			else:
				# A4.3 / A4.4 — destructible object
				var outcome: String = _hit_object(state, e, occ, m_impact, dir, impulse_q, effect_q, events)
				if outcome == "through":
					m = m_impact - E.BREAK_COST
					_advance(state, e, nxt, events)   # smash into the now-empty tile
					if m <= 0:
						return
					continue
				else:
					return  # "stop" (anchored) or "pushed" (movable survivor) — A halts

		# A4.5 — hazard tile
		var hz: int = state.tile(nxt).hazard
		if hz != E.Hazard.NONE:
			if hz == E.Hazard.GAP:
				_eject(state, e, events)
				return
			if not _hazard_enter(state, e, nxt, hz, effect_q, events):
				return  # died in the hazard
			m = m_impact - _move_cost(state, e, nxt)
			continue

		# A4.6 — empty traversable tile
		var cost: int = _move_cost(state, e, nxt)
		if m < cost:
			return  # not enough momentum to enter — gentle stop, no impact damage
		_advance(state, e, nxt, events)
		m = m_impact - cost
	# fell out of loop: momentum spent, gentle stop.


# --- Phase 5 E1.1 — per-tile forced-move momentum cost (friction) --------------
# Default (friction == -1, every prior fixture): cost = mover's mass — UNCHANGED.
#   friction == 0 (ICE):   cost 0 → the move is free → slides the full length.
#   friction >= 2 (SNOW):  cost = mass + 1 → shoves travel shorter.
static func _move_cost(state, e, nxt: Vector2i) -> int:
	if not state.in_bounds(nxt):
		return e.mass
	var f: int = state.tile(nxt).friction
	if f < 0:
		return e.mass
	if f == E.FRICTION_ICE:
		return 0
	return e.mass + (f - 1)   # f==1 → mass (neutral); f>=2 → mass + extra


# --- Phase 5 E1.1 — slope amplifies a slam downhill, saps it uphill -------------
# `from` is the tile being LEFT; its slope vector points downhill. Moving WITH it
# (dir == slope) adds SLOPE_MOMENTUM; moving AGAINST (dir == -slope) subtracts it.
# ZERO-slope tiles (every prior fixture) return `m` unchanged.
static func _slope_adjust(state, from: Vector2i, dir: Vector2i, m: int) -> int:
	if not state.in_bounds(from):
		return m
	var s: Vector2i = state.tile(from).slope
	if s == Vector2i.ZERO:
		return m
	if dir == s:
		return m + E.SLOPE_MOMENTUM
	if dir == -s:
		return m - E.SLOPE_MOMENTUM
	return m


# --- A4.1 wall / anchored impact -----------------------------------------------
## Trait/gear adjustment of physics-impact damage TAKEN (Glass Jaw +flat; Ablative -%).
## Defaults (0/0) return dmg unchanged — integer-only.
static func _impact_dmg_taken(e, dmg: int) -> int:
	if dmg <= 0:
		return dmg
	if e.impact_resist_pct != 0:
		dmg = dmg * (100 - e.impact_resist_pct) / 100
	return max(0, dmg + e.impact_damage_mod)


static func _impact_wall(state, e, m_impact: int, events: Array) -> void:
	var dmg: int = _impact_dmg_taken(e, m_impact / E.IMPACT_DIVISOR)
	if dmg > 0:
		e.take_damage(dmg)
	var prone: bool = m_impact >= E.PRONE_THRESHOLD
	var stunned: bool = m_impact >= E.STUN_THRESHOLD
	# Primary event first, THEN the resulting status events (clean renderer timeline).
	events.push_back(GE.new(E.Ev.IMPACT_WALL, {"id": e.id, "dmg": dmg, "prone": prone, "stunned": stunned}))
	if e.is_unit and prone:
		_apply_status(e, E.S_PRONE, events)
	if e.is_unit and stunned:
		_apply_status(e, E.S_STUNNED, events)
	_check_death(state, e, events)


# --- A4.2 billiards body collision ---------------------------------------------
static func _collide_body(state, a, b, m_impact: int, dir: Vector2i, impulse_q: Array, events: Array) -> void:
	var dmg: int = m_impact / E.COLLISION_DIVISOR
	if dmg > 0:
		a.take_damage(_impact_dmg_taken(a, dmg))
		b.take_damage(_impact_dmg_taken(b, dmg))
	var force_b: int = max(0, m_impact - E.COLLISION_DECAY)
	var pushed: bool = b.movable and force_b >= b.mass
	# Primary event first, then the slammer's stagger statuses.
	events.push_back(GE.new(E.Ev.COLLIDE_BODY, {"a_id": a.id, "b_id": b.id, "dmg": dmg, "b_pushed": pushed}))
	if a.is_unit:
		if m_impact >= E.PRONE_THRESHOLD:
			_apply_status(a, E.S_PRONE, events)
		if m_impact >= E.STUN_THRESHOLD:
			_apply_status(a, E.S_STUNNED, events)
	if pushed:
		impulse_q.push_back({"id": b.id, "dir": dir, "M": force_b})
	_check_death(state, a, events)
	_check_death(state, b, events)
	# A stops one tile back (never enters B's tile) — caller returns.


# --- A4.3 / A4.4 destructible object -> "through" | "pushed" | "stop" -----------
static func _hit_object(state, a, obj, m_impact: int, dir: Vector2i, impulse_q: Array, effect_q: Array, events: Array) -> String:
	var dmg: int = m_impact / E.OBJECT_DIVISOR
	obj.integrity -= dmg

	if obj.integrity <= 0:
		# A4.4 — breaks. Pass the impact direction so a TOPPLE with fall_dir "away from
		# impact" (authored as ZERO) falls the way the breaker was pushing.
		_break_object(state, obj, effect_q, events, dir)
		if obj.movable:
			return "through"   # A smashes on through the vacated tile
		else:
			_impact_wall(state, a, m_impact, events)  # anchored: A still stops & bonks
			return "stop"

	# A4.3 — survives
	events.push_back(GE.new(E.Ev.OBJECT_DAMAGED, {"id": obj.id, "dmg": dmg, "integrity_left": obj.integrity}))
	if obj.movable:
		# treat as a body: A takes collision damage, object is shoved onward
		var admg: int = m_impact / E.COLLISION_DIVISOR
		if admg > 0:
			a.take_damage(admg)
		if a.is_unit:
			if m_impact >= E.PRONE_THRESHOLD:
				_apply_status(a, E.S_PRONE, events)
			if m_impact >= E.STUN_THRESHOLD:
				_apply_status(a, E.S_STUNNED, events)
		var force_o: int = max(0, m_impact - E.COLLISION_DECAY)
		if force_o >= obj.mass:
			impulse_q.push_back({"id": obj.id, "dir": dir, "M": force_o})
		_check_death(state, a, events)
		return "pushed"
	else:
		_impact_wall(state, a, m_impact, events)  # anchored survivor: A stops
		return "stop"


# --- A4.4 break: drop object, enqueue its on_break effect -----------------------
static func _break_object(state, obj, effect_q: Array, events: Array, impact_dir: Vector2i = Vector2i.ZERO) -> void:
	var pos: Vector2i = obj.pos
	if state.in_bounds(pos) and state.tile(pos).occupant_id == obj.id:
		state.tile(pos).occupant_id = -1
	obj.alive = false
	state.entities.erase(obj.id)
	events.push_back(GE.new(E.Ev.OBJECT_BREAK, {"id": obj.id, "pos": pos, "on_break": obj.on_break}))
	# Phase 5 (E5) — a rigged sculpture conceals a DORMANT cycling trap on its tile; smashing
	# the sculpture ARMS it (it now cycles + telegraphs + fires). Detected by an inactive
	# cycling-trap hazard sitting where the object stood.
	if state.in_bounds(pos):
		var rt = state.tile(pos)
		if rt.trap_period > 0 and not rt.trap_active and _is_cycling_hazard(rt.hazard):
			rt.trap_active = true
	match obj.on_break:
		E.OnBreak.FLOOD:
			var r: int = obj.break_param if obj.break_param > 0 else E.FLOOD_RADIUS_DEFAULT
			effect_q.push_back({"kind": E.Effect.FLOOD, "origin": pos, "radius": r})
		E.OnBreak.EXPLODE:
			var er: int = obj.break_param if obj.break_param > 0 else 1
			effect_q.push_back({"kind": E.Effect.EXPLODE, "origin": pos, "radius": er})
		E.OnBreak.COLLAPSE:
			if state.in_bounds(pos):
				state.tile(pos).status_layer |= E.L_DEBRIS
		E.OnBreak.SPILL_FIRE:
			if state.in_bounds(pos):
				state.tile(pos).status_layer |= E.L_FIRE
				state.tile(pos).status_timer = E.WATER_DURATION
		E.OnBreak.TOPPLE:
			# E1.3 — a tall destructible FALLS as a line-crush. fall_dir==ZERO means
			# "away from the impact" (the direction the breaker was pushing): we read the
			# last MOVE_STEP/where the breaker stands relative to `pos`. The break path
			# passes the fall direction via the object's fall_dir (set at author/break time).
			var fdir: Vector2i = obj.fall_dir
			if fdir == Vector2i.ZERO:
				# "away from impact" — the way the breaker was pushing. Falls in the impact
				# direction; if there is none (e.g. a chandelier "down"), keep a stable +x.
				fdir = impact_dir if impact_dir != Vector2i.ZERO else Vector2i(1, 0)
			var height: int = obj.topple_height if obj.topple_height > 0 else 1
			effect_q.push_back({"kind": E.Effect.TOPPLE, "origin": pos, "dir": fdir, "height": height})
		E.OnBreak.AVALANCHE:
			# E1.6 — a snow reservoir bursts: a directional snow front (reuses flood mach.).
			var ar: int = obj.break_param if obj.break_param > 0 else E.AVALANCHE_RADIUS
			effect_q.push_back({"kind": E.Effect.AVALANCHE, "origin": pos, "radius": ar})
		_:
			pass


# --- A4.5 non-gap hazard entry -> false if the entity died ----------------------
static func _hazard_enter(state, e, nxt: Vector2i, hz: int, effect_q: Array, events: Array) -> bool:
	_advance(state, e, nxt, events)
	match hz:
		E.Hazard.FURNACE:
			e.take_damage(E.FURNACE_DAMAGE)
			_apply_status(e, E.S_BURNING, events)
			events.push_back(GE.new(E.Ev.HAZARD_FURNACE, {"id": e.id, "dmg": E.FURNACE_DAMAGE}))
		E.Hazard.RAIL_LIVE:
			e.take_damage(E.RAIL_DAMAGE)
			_apply_status(e, E.S_SHOCKED, events)
			events.push_back(GE.new(E.Ev.HAZARD_RAIL, {"id": e.id, "dmg": E.RAIL_DAMAGE}))
			if e.has_status(E.S_SOAKED):
				effect_q.push_back({"kind": E.Effect.ELECTRIFY, "origin": nxt})
		E.Hazard.PISTON:
			e.take_damage(E.PISTON_DAMAGE)
			events.push_back(GE.new(E.Ev.HAZARD_PISTON, {"id": e.id, "dmg": E.PISTON_DAMAGE}))
		_:
			pass
	_check_death(state, e, events)
	return e.alive


# --- A4.5 GAP eject (shove them off the train) ---------------------------------
static func _eject(state, e, events: Array) -> void:
	var gear_pos: Vector2i = e.pos  # gear drops on the last in-bounds tile
	if state.in_bounds(e.pos) and state.tile(e.pos).occupant_id == e.id:
		state.tile(e.pos).occupant_id = -1
	var kill: bool = e.is_unit
	e.alive = false
	state.entities.erase(e.id)
	events.push_back(GE.new(E.Ev.EJECT, {"id": e.id, "kill": kill, "gear_drop_pos": gear_pos}))
	# §7.4: an ejected hero is INSTANT permadeath (no revive window off the train) but it
	# must be RECORDED — gear drops on the last in-bounds tile and the Memorial gets the
	# entry, so the run layer marks the instance dead (no resurrection by bookkeeping).
	# Gated on bleedout_enabled: the Phase 0-i default (bare EJECT) is preserved verbatim.
	if kill and state.bleedout_enabled and e.faction != E.Faction.ENEMY:
		BleedoutSystem.permadeath(state, e, events)


# --- movement helper -----------------------------------------------------------
static func _advance(state, e, nxt: Vector2i, events: Array) -> void:
	var from: Vector2i = e.pos
	if state.in_bounds(from) and state.tile(from).occupant_id == e.id:
		state.tile(from).occupant_id = -1
	e.pos = nxt
	if state.in_bounds(nxt):
		state.tile(nxt).occupant_id = e.id
	events.push_back(GE.new(E.Ev.MOVE_STEP, {"id": e.id, "from": from, "to": nxt}))


static func _apply_status(e, s: int, events: Array) -> void:
	if not e.has_status(s):
		e.add_status(s)
		events.push_back(GE.new(E.Ev.STATUS_APPLY, {"id": e.id, "status": s}))


static func _check_death(state, e, events: Array) -> void:
	if e.is_unit and e.alive and e.hp <= 0:
		# Phase 4 bleed-out: only when explicitly enabled (and the unit is downable) does
		# physics lethality open the revive window. The DEFAULT path is preserved verbatim
		# — the golden physics fixtures depend on this exact single STATUS_APPLY(S_DOWNED).
		if state.bleedout_enabled and not e.downed:
			var downable: bool = e.faction != E.Faction.ENEMY or state.down_enemies_too
			if downable:
				BleedoutSystem.down_or_kill(state, e, events)
				return
		e.alive = false
		if state.in_bounds(e.pos) and state.tile(e.pos).occupant_id == e.id:
			state.tile(e.pos).occupant_id = -1
		state.entities.erase(e.id)
		events.push_back(GE.new(E.Ev.STATUS_APPLY, {"id": e.id, "status": E.S_DOWNED}))


# ============================ EFFECTS (A6) =====================================
static func _resolve_effect(state, eff: Dictionary, impulse_q: Array, effect_q: Array, events: Array) -> void:
	match eff.kind:
		E.Effect.FLOOD:
			_effect_flood(state, eff, impulse_q, effect_q, events)
		E.Effect.ELECTRIFY:
			_effect_electrify(state, eff, events)
		E.Effect.EXPLODE:
			_effect_explode(state, eff, impulse_q, events)
		E.Effect.TOPPLE:
			_effect_topple(state, eff, impulse_q, events)
		E.Effect.AVALANCHE:
			_effect_avalanche(state, eff, impulse_q, events)
		_:
			pass


# --- A6 Flood: wave -> soak -> prone -> drift, then electrify check -------------
static func _effect_flood(state, eff: Dictionary, impulse_q: Array, effect_q: Array, events: Array) -> void:
	var origin: Vector2i = eff.origin
	var radius: int = eff.radius
	var reached: Array = _flood_fill(state, origin, radius)
	for p in reached:
		var t = state.tile(p)
		t.status_layer |= E.L_WATER
		t.status_timer = E.WATER_DURATION
		var occ = state.occupant_at(p)
		if occ != null:
			_apply_status(occ, E.S_SOAKED, events)
			# Sure-Footed / Magnetic Boots: the wave cannot knock this unit down.
			if occ.is_unit and not occ.has_status(E.S_PRONE) and not occ.flood_prone_immune:
				_apply_status(occ, E.S_PRONE, events)  # the wave knocks standing units down
			if occ.mass == E.Mass.LIGHT and occ.movable:
				var d: Vector2i = _away_dir(origin, occ.pos)
				if d != Vector2i.ZERO:
					impulse_q.push_back({"id": occ.id, "dir": d, "M": 1})  # light objects drift
		events.push_back(GE.new(E.Ev.FLOOD_TILE, {"pos": p}))
	if _water_touches_power(state, reached):
		effect_q.push_back({"kind": E.Effect.ELECTRIFY, "origin": origin})


# --- A6 Electrify: chain shock through every connected soaked entity ------------
static func _effect_electrify(state, eff: Dictionary, events: Array) -> void:
	var component: Array = _connected_water(state, eff.origin)
	for p in component:
		var t = state.tile(p)
		t.status_layer |= E.L_ELECTRIFIED
		var occ = state.occupant_at(p)
		if occ != null and occ.has_status(E.S_SOAKED):
			occ.take_damage(E.SHOCK_DAMAGE)
			_apply_status(occ, E.S_SHOCKED, events)
			events.push_back(GE.new(E.Ev.SHOCK, {"id": occ.id, "dmg": E.SHOCK_DAMAGE}))
			_check_death(state, occ, events)


# --- explosion: radial damage + outward knockback ------------------------------
# Back-compat: an on_break EXPLODE (no `damage`/`force` keys) keeps the original
# falloff model exactly. The hazard system (D4 IGNITE) passes explicit damage+force
# for a flat, readable blast over the gas volume.
static func _effect_explode(state, eff: Dictionary, impulse_q: Array, events: Array) -> void:
	var origin: Vector2i = eff.origin
	var radius: int = eff.radius
	var has_dmg: bool = eff.has("damage")
	var flat_dmg: int = eff.get("damage", 0)
	var flat_force: int = eff.get("force", radius)
	# EVERY blast is evented (renderer completeness): the gas path reports its flat
	# damage; an on_break EXPLODE reports damage 0 = "falloff model" (per-target dmg
	# still arrives via the usual damage/knockback events).
	events.push_back(GE.new(E.Ev.EXPLOSION, {"origin": origin, "radius": radius, "damage": flat_dmg}))
	for id in state.entity_ids_sorted():
		var e = state.entities[id]
		var d: int = abs(e.pos.x - origin.x) + abs(e.pos.y - origin.y)
		if d <= radius and d > 0:
			var dmg: int = flat_dmg if has_dmg else max(1, radius - d + 1)
			e.take_damage(dmg)
			if e.movable:
				var dir: Vector2i = _away_dir(origin, e.pos)
				if dir != Vector2i.ZERO:
					var m: int = flat_force if has_dmg else radius
					impulse_q.push_back({"id": e.id, "dir": dir, "M": m})
			_check_death(state, e, events)


# --- Phase 5 E1.3 — TOPPLE: a felled tall object crushes a line ----------------
# Every tile along `height` from origin+dir takes impact damage + Prone; a movable
# unit/object caught in the line is shoved PERPENDICULAR off the falling mass.
static func _effect_topple(state, eff: Dictionary, impulse_q: Array, events: Array) -> void:
	var origin: Vector2i = eff.origin
	var dir: Vector2i = eff.get("dir", Vector2i(1, 0))
	var height: int = max(1, int(eff.get("height", 1)))
	events.push_back(GE.new(E.Ev.TOPPLE, {"origin": origin, "dir": dir, "height": height}))
	# Perpendicular shove direction (stable: rotate the fall dir 90° clockwise).
	var perp: Vector2i = Vector2i(-dir.y, dir.x)
	for i in range(1, height + 1):
		var p: Vector2i = origin + dir * i
		if not state.in_bounds(p) or state.tile(p).terrain == E.Terrain.WALL:
			break  # the falling mass stops at a wall
		events.push_back(GE.new(E.Ev.CRUSH, {"pos": p}))
		var occ = state.occupant_at(p)
		if occ != null:
			occ.take_damage(E.TOPPLE_DAMAGE)
			if occ.is_unit:
				_apply_status(occ, E.S_PRONE, events)
			# Shoved perpendicular off the line if it can move.
			if occ.movable and perp != Vector2i.ZERO:
				impulse_q.push_back({"id": occ.id, "dir": perp, "M": occ.mass + 1})
			_check_death(state, occ, events)


# --- Phase 5 E1.6 — AVALANCHE: a snow front (flood machinery, snow-flavored) ----
# Sweeps like a flood wave but: knocks standing units Prone, applies Chilled (not
# Soaked), BURIES caught entities (immobilized buried_timer turns), and leaves packed
# snow (L_SNOW = difficult terrain) instead of receding water.
static func _effect_avalanche(state, eff: Dictionary, impulse_q: Array, events: Array) -> void:
	var origin: Vector2i = eff.origin
	var radius: int = eff.radius
	var reached: Array = _flood_fill(state, origin, radius)
	events.push_back(GE.new(E.Ev.AVALANCHE, {"origin": origin, "radius": radius}))
	for p in reached:
		var t = state.tile(p)
		t.status_layer |= E.L_SNOW   # packed snow (difficult terrain) lingers
		var occ = state.occupant_at(p)
		if occ != null:
			occ.take_damage(E.AVALANCHE_DAMAGE)
			if occ.is_unit:
				if not occ.has_status(E.S_PRONE):
					_apply_status(occ, E.S_PRONE, events)
				_apply_chill(occ, events)
				occ.buried_timer = E.BURIED_TURNS
				_apply_status(occ, E.S_BURIED, events)
				events.push_back(GE.new(E.Ev.BURY, {"id": occ.id}))
			_check_death(state, occ, events)


## Chill helper local to the resolver (mirrors StatusSystem.apply_chill; kept here so
## the resolver stays dependency-light and deterministic). Stacks → Frozen.
static func _apply_chill(e, events: Array) -> void:
	if e.chill_immune:
		return   # Thermal Suit (gear-stamped)
	e.chill_stacks += 1
	_apply_status(e, E.S_CHILLED, events)
	if e.chill_stacks >= E.FROZEN_THRESHOLD and not e.has_status(E.S_FROZEN):
		_apply_status(e, E.S_FROZEN, events)
		events.push_back(GE.new(E.Ev.FREEZE, {"id": e.id}))


# --- BFS over floodable FLOOR tiles (WALL / full-cover block water) -------------
static func _flood_fill(state, origin: Vector2i, radius: int) -> Array:
	var result: Array = []
	if not state.in_bounds(origin) or state.tile(origin).terrain == E.Terrain.WALL:
		return result
	var visited: Dictionary = {origin: true}
	var q: Array = [{"p": origin, "d": 0}]
	while not q.is_empty():
		var cur: Dictionary = q.pop_front()
		var p: Vector2i = cur.p
		result.push_back(p)
		if cur.d >= radius:
			continue
		for dd in DIRS4:
			var np: Vector2i = p + dd
			if state.in_bounds(np) and not visited.has(np):
				var nt = state.tile(np)
				if nt.terrain != E.Terrain.WALL and nt.cover != 2:
					visited[np] = true
					q.push_back({"p": np, "d": cur.d + 1})
	return result


# --- all WATER tiles connected to a power source -------------------------------
static func _connected_water(state, origin: Vector2i) -> Array:
	var seeds: Array = []
	if state.in_bounds(origin) and state.tile(origin).has_layer(E.L_WATER):
		seeds.append(origin)
	for dd in DIRS4:
		var np: Vector2i = origin + dd
		if state.in_bounds(np) and state.tile(np).has_layer(E.L_WATER):
			seeds.append(np)
	var result: Array = []
	var visited: Dictionary = {}
	var q: Array = []
	for s in seeds:
		if not visited.has(s):
			visited[s] = true
			q.push_back(s)
	while not q.is_empty():
		var p: Vector2i = q.pop_front()
		result.push_back(p)
		for dd in DIRS4:
			var np: Vector2i = p + dd
			if state.in_bounds(np) and not visited.has(np) and state.tile(np).has_layer(E.L_WATER):
				visited[np] = true
				q.push_back(np)
	return result


static func _water_touches_power(state, reached: Array) -> bool:
	for p in reached:
		if state.tile(p).hazard == E.Hazard.RAIL_LIVE:
			return true
		for dd in DIRS4:
			var np: Vector2i = p + dd
			if not state.in_bounds(np):
				continue
			if state.tile(np).hazard == E.Hazard.RAIL_LIVE:
				return true
			var occ = state.occupant_at(np)
			if occ != null and occ.is_power_source:
				return true
	return false


## Is this a cycling-trap hazard kind (for arming a rigged sculpture's hidden emitter)?
static func _is_cycling_hazard(hz: int) -> bool:
	return hz == E.Hazard.VENT or hz == E.Hazard.LASER or hz == E.Hazard.PLATE \
		or hz == E.Hazard.PISTON or hz == E.Hazard.STEAM \
		or hz == E.Hazard.LASER_SWEEP or hz == E.Hazard.CONVEYOR


static func _away_dir(origin: Vector2i, pos: Vector2i) -> Vector2i:
	var dx: int = pos.x - origin.x
	var dy: int = pos.y - origin.y
	if abs(dx) >= abs(dy):
		if dx == 0:
			return Vector2i.ZERO
		return Vector2i(sign(dx), 0)
	return Vector2i(0, sign(dy))
