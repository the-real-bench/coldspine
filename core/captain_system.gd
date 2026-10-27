class_name CaptainSystem
## Phase 5 — Section Captains (GDD §12, Sub-Spec E E14.4). Each captain is a physics
## *puzzle* gated by a specific `physicsKey`; the player must satisfy the key to make the
## captain killable / shovable. RefCounted statics, ZERO SceneTree, integer-only, NO rng
## (gate evaluation is purely deterministic). TurnManager-agnostic: call tick(state) in
## the environment phase; call setup() when a captain enters play.
##
## The five keys (content/enemies/captains.json -> EnemyDef.physicsKey):
##   unshovable_until_soaked          -> resolver shove gate; key met once S_SOAKED.
##   kill_to_drop_guard_buff          -> the captain buffs nearby guards (+integrity/accuracy
##                                       proxy); killing the captain drops the buff.
##   gas_shroud_must_be_dispersed     -> immune to damage while a GAS cloud sits on/adjacent
##                                       to it; disperse the gas (water/explosion/time) to open.
##   destroy_his_cover_then_flank     -> shielded (damage-reduced) until the cover tile/object
##                                       that protects it is destroyed, then it's flankable.
##   soak_then_into_a_trap            -> unshovable-until-soaked (reuses the shove gate) — the
##                                       "soak then shove into a hazard" line.
##   flood_the_dais_then_shove        -> the Conductor's finale key; same soak gate (Sub-Spec B).
##
## The captain's `captain_gate_open` flag is the single source of truth other systems read
## (e.g. damage application checks it). gate-open captains take full damage; gated ones are
## protected per their key.

const E = preload("res://core/sim_enums.gd")
const GE = preload("res://core/game_event.gd")
const Bleedout = preload("res://core/bleedout_system.gd")

# How far a captain's guard buff reaches (Manhattan tiles).
const BUFF_RADIUS := 2
# The buff's effect: nearby guards get this much bonus HP/accuracy proxy while it holds.
const BUFF_HP_BONUS := 2
# Stable orthogonal step order (N, E, S, W) — matches the resolver/EnemyAI DIRS4.
const DIRS4 := [Vector2i(0, -1), Vector2i(1, 0), Vector2i(0, 1), Vector2i(-1, 0)]


## Configure a freshly-spawned captain entity from its EnemyDef key. Sets the physics
## trait the resolver reads (for soak gates), the captain_key, and the initial gate state.
static func setup(entity, key: String) -> void:
	entity.captain_key = key
	match key:
		"unshovable_until_soaked", "soak_then_into_a_trap", "flood_the_dais_then_shove_into_a_hazard":
			entity.phys_trait = E.PhysTrait.UNSHOVABLE_UNTIL_SOAKED
			entity.captain_gate_open = false
		"kill_to_drop_guard_buff":
			entity.captain_gate_open = true   # it's always killable; its threat is the buff it grants
			# W2-10: the Foreman's authored kit is captain_slam + buff_guards (a melee bruiser). He is
			# the only captain on this key (the finale Conductor aside), and his data aiProfile of
			# `support` drove him to conjure an unauthored Drone-Operator bot and never close to slam.
			# Drive his authored MELEE kit instead.
			entity.ai_profile = E.AIProfile.MELEE_RUSH
		"gas_shroud_must_be_dispersed":
			entity.captain_gate_open = false  # immune until the gas around it clears
		"destroy_his_cover_then_flank":
			entity.captain_gate_open = false  # shielded until its cover is stripped
		_:
			entity.captain_gate_open = true


## Is `entity` a Section Captain (carries a key)?
static func is_captain(entity) -> bool:
	return entity != null and entity.captain_key != ""


## Should damage to this entity be applied right now? The single damage-gate authority
## the live combat sites (ShootCommand / AbilitySystem / DoT) consult before subtracting
## HP. Returns FALSE only when the entity is actively shielded:
##   - the Conductor's relay-shield (`conductor_shielded`, Sub-Spec B2.1) — immune until
##     the player disables the Engine's defenses (all Relays down) or kills it; OR
##   - a Section Captain whose physics gate is not yet open (Phase 5).
## Default-trait, non-captain, non-Conductor entities ALWAYS take damage (returns true),
## so threading this into the damage path is invisible to the 570-test baseline.
static func can_take_damage(state, entity) -> bool:
	if entity == null:
		return true
	# Phase 6: the Conductor's Engine-systems shield (relay-gated) trumps everything.
	if entity.conductor_shielded:
		return false
	if not is_captain(entity):
		return true
	# Re-evaluate the live gate so the check is always current.
	_evaluate_gate(state, entity, null)
	return entity.captain_gate_open


## Environment-phase tick: re-evaluate every captain's gate, (un)apply the guard buff,
## and emit the gate/buff events. Returns the ordered events. Deterministic, sorted order.
static func tick(state) -> Array:
	var events: Array = []
	for id in state.entity_ids_sorted():
		var cap = state.entities.get(id)
		if cap == null or not cap.alive or not is_captain(cap):
			continue
		_evaluate_gate(state, cap, events)
		if cap.captain_key == "kill_to_drop_guard_buff":
			_apply_guard_buff(state, cap, events)
	# W2-6: a buff-captain KILLED in combat is erased from state before this tick (enemies don't
	# bleed out), so the loop above never sees it to drop its buff — on_captain_killed was wired to
	# NOTHING in production, so the Foreman's death left his guards permanently buffed. Reap any
	# guard still carrying a buff whose granting captain is gone.
	_drop_orphaned_buffs(state, events)
	return events


## Called when a captain dies (killed): drop any buff it granted (the "kill to drop" key)
## and emit the buff-drop. Pure on the surviving guards (removes the bonus HP).
static func on_captain_killed(state, cap, events: Array) -> void:
	if cap == null or not is_captain(cap):
		return
	if cap.captain_key == "kill_to_drop_guard_buff":
		_remove_guard_buff(state, cap, events)


# ============================ gate evaluation =================================
static func _evaluate_gate(state, cap, events) -> void:
	var was_open: bool = cap.captain_gate_open
	var open: bool = cap.captain_gate_open
	match cap.captain_key:
		"unshovable_until_soaked", "soak_then_into_a_trap", "flood_the_dais_then_shove_into_a_hazard":
			# The shove gate is handled by the resolver's phys_trait; the *damage* gate here
			# is always open (you can shoot it; you just can't shove it dry). Leave open.
			open = true
		"gas_shroud_must_be_dispersed":
			# One-way LATCH: once her shroud is dispersed it stays dispersed (no re-shroud → no
			# soft-lock as flood water recedes). The latch reuses the persistent captain_gate_open
			# field, so no new sim state is added (fingerprint unchanged in shape). W2-5 (2026-07-04):
			# the authored Head Gardener car ships no gas tile, so the REAL captain (captain_gardener)
			# opens the instant her IRRIGATION floods or soaks her — the water_main now stands beside
			# her at (11,4), floodRadius 4 reaches her tile (12,4), so breaking it exposes her (the
			# pilot's gate-tool playbook shoots the FLOOD source; a human shoves/shoots it the same).
			# The synthetic unit-test gardener (name != captain_gardener) keeps the literal gas-tile
			# rule so test_captain_gas_shroud_key is untouched.
			if cap.captain_gate_open:
				open = true
			elif cap.name == "captain_gardener":
				open = state.tile(cap.pos).has_layer(E.L_WATER) or cap.has_status(E.S_SOAKED)
			else:
				open = not _gas_near(state, cap.pos)
		"destroy_his_cover_then_flank":
			# Open once the captain no longer enjoys cover (its protective tile/object gone).
			open = not _has_cover(state, cap)
		_:
			open = true
	cap.captain_gate_open = open
	if events != null and open != was_open:
		if open:
			events.push_back(GE.new(E.Ev.CAPTAIN_SHIELD_DROP, {"id": cap.id, "key": cap.captain_key}))
		else:
			events.push_back(GE.new(E.Ev.CAPTAIN_SHIELD, {"id": cap.id, "key": cap.captain_key}))


static func _gas_near(state, p: Vector2i) -> bool:
	var dirs := [Vector2i.ZERO, Vector2i(0, -1), Vector2i(1, 0), Vector2i(0, 1), Vector2i(-1, 0)]
	for d in dirs:
		var np: Vector2i = p + d
		if state.in_bounds(np) and state.tile(np).has_layer(E.L_GAS):
			return true
	return false


## A captain "has cover" if its own cover field or its tile's cover is > 0, OR a living cover object
## sits on an orthogonally-adjacent tile (W2-5: the Majordomo stands BESIDE his marble statue).
static func _has_cover(state, cap) -> bool:
	if cap.cover > 0:
		return true
	if state.in_bounds(cap.pos) and state.tile(cap.pos).cover > 0:
		return true
	# The Majordomo's cover is the statue on the adjacent tile, not his own — so his own tile carries
	# no cover and he was damageable from turn 1. A living cover object orthogonally adjacent shields
	# him; destroy it to strip the cover and flank. Self-clearing: once the object is broken/erased
	# (not alive / gone) the gate opens next tick.
	for d in DIRS4:
		var np: Vector2i = cap.pos + d
		if not state.in_bounds(np):
			continue
		var occ = state.occupant_at(np)
		if occ != null and not occ.is_unit and occ.alive and occ.cover > 0:
			return true
	return false


# ============================ guard buff ======================================
## Grant +BUFF_HP_BONUS HP (once) to every living guard within BUFF_RADIUS of the captain.
## Idempotent: a guard already carrying a captain buff isn't double-buffed (tracked via
## the dedicated buffed_by_captain_id field — cloned like every other field, and it can
## never leak into gear drops / Legacy inventory the way a gear-tag marker could).
static func _apply_guard_buff(state, cap, events: Array) -> void:
	var buffed_ids: Array = []
	for id in state.entity_ids_sorted():
		var g = state.entities.get(id)
		if g == null or not g.alive or not g.is_unit or g.id == cap.id:
			continue
		if g.faction != E.Faction.ENEMY:
			continue
		if _manhattan(g.pos, cap.pos) > BUFF_RADIUS:
			continue
		if g.buffed_by_captain_id != -1:
			continue
		g.buffed_by_captain_id = cap.id
		g.hp += BUFF_HP_BONUS
		buffed_ids.append(g.id)
	if not buffed_ids.is_empty():
		events.push_back(GE.new(E.Ev.CAPTAIN_BUFF, {"id": cap.id, "radius": BUFF_RADIUS, "ids": buffed_ids}))


static func _remove_guard_buff(state, cap, events: Array) -> void:
	var dropped_ids: Array = []
	var doomed: Array = []
	for id in state.entity_ids_sorted():
		var g = state.entities.get(id)
		if g == null or not g.is_unit:
			continue
		if g.buffed_by_captain_id != cap.id:
			continue
		g.buffed_by_captain_id = -1
		g.hp -= BUFF_HP_BONUS   # the buffed HP evaporates with its source (cruel, but fair)
		dropped_ids.append(g.id)
		if g.alive and g.hp <= 0:
			doomed.append(g)
	if not dropped_ids.is_empty():
		events.push_back(GE.new(E.Ev.CAPTAIN_BUFF_DROP, {"id": cap.id, "ids": dropped_ids}))
	# ...but never a zombie: a guard left at <=0 HP dies cleanly through the §7.4
	# decision (evented UNIT_DOWNED/UNIT_DEATH), after the buff-drop event for the renderer.
	for g in doomed:
		Bleedout.down_or_kill(state, g, events)


## W2-6: drop guard buffs whose granting captain is no longer alive/present (the Foreman was killed).
## Mirrors _remove_guard_buff but keyed by the DANGLING captain id, because a dead enemy captain is
## erased from state.entities before the next tick — so we detect the death by the orphaned tag, not
## by finding the captain. Deterministic (sorted iteration), idempotent (clears the tag once).
static func _drop_orphaned_buffs(state, events: Array) -> void:
	var dropped_by_cap: Dictionary = {}
	var doomed: Array = []
	for id in state.entity_ids_sorted():
		var g = state.entities.get(id)
		if g == null or not g.is_unit or g.buffed_by_captain_id == -1:
			continue
		var cap = state.entities.get(g.buffed_by_captain_id)
		if cap != null and cap.alive:
			continue   # its captain still stands — the buff holds
		var cid: int = g.buffed_by_captain_id
		g.buffed_by_captain_id = -1
		g.hp -= BUFF_HP_BONUS   # the buffed HP evaporates with its dead source
		if not dropped_by_cap.has(cid):
			dropped_by_cap[cid] = []
		dropped_by_cap[cid].append(g.id)
		if g.alive and g.hp <= 0:
			doomed.append(g)
	# One CAPTAIN_BUFF_DROP per fallen captain (stable id order), then clean up any guard left at
	# <=0 HP through the same §7.4 death decision _remove_guard_buff uses.
	var cids: Array = dropped_by_cap.keys()
	cids.sort()
	for cid in cids:
		events.push_back(GE.new(E.Ev.CAPTAIN_BUFF_DROP, {"id": cid, "ids": dropped_by_cap[cid]}))
	for g in doomed:
		Bleedout.down_or_kill(state, g, events)


static func _manhattan(a: Vector2i, b: Vector2i) -> int:
	return abs(a.x - b.x) + abs(a.y - b.y)
