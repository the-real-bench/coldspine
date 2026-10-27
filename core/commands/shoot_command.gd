class_name ShootCommand
extends Command
## Ranged attack — the ONLY action that draws from the RNG (GDD §5.4).
##   HitChance = BASE_ACCURACY − CoverPenalty − RangeFalloff + FlankBonus + StatusMods
## Rolled via state.rng.chance(hit). Soaked/Stunned/Prone targets get big hit
## bonuses (Prone ≈ guaranteed). Damage is fixed + a small rng variance band.
## 1 AP, ENDS the actor's turn (§5.2 "most attacks end the turn").
##
## Static helpers (in_los / has_range / hit_chance) are reused by the enemy AI so
## the AI and the resolved action agree on what is shootable.

const CaptainSystem = preload("res://core/captain_system.gd")
const Physics = preload("res://core/physics_resolver.gd")

var target_id: int = -1

func _init(p_actor_id: int = -1, p_target_id: int = -1) -> void:
	super(p_actor_id)
	target_id = p_target_id
	ap_cost = 1
	ends_turn = true

func validate(state, _turn) -> Dictionary:
	var a = state.entities.get(actor_id)
	if a == null or not a.alive or not a.is_unit:
		return _fail("actor missing/dead")
	var t = state.entities.get(target_id)
	if t == null or not t.alive:
		return _fail("target missing/dead")
	# Objects ARE legal targets when destructible ("shoot the barrel" — the volatile
	# trigger surface the physics game is built on). Indestructible props are not.
	if not t.is_unit and t.integrity <= 0:
		return _fail("target not destructible")
	if t.faction == a.faction:
		return _fail("cannot shoot own faction")
	if not has_range(a.pos, t.pos):
		return _fail("out of weapon range")
	if not in_los(state, a.pos, t.pos):
		return _fail("no line of sight")
	return _ok()

func execute(state, turn) -> Array:
	var events: Array = []
	var a = state.entities.get(actor_id)
	var t = state.entities.get(target_id)
	if a == null or t == null:
		return events

	# Steady (Marksman): the FIRST action of a fresh phase (full AP = has not moved yet)
	# fired as a shot does not end the turn. Flipped BEFORE settle() reads ends_turn.
	if a.steady_shot and turn != null and turn.ap_for(actor_id) >= E.AP_PER_TURN:
		ends_turn = false

	# Objects: a static target is a GUARANTEED, rng-free hit — drawing NOTHING from the
	# seeded stream keeps every unit-combat roll byte-identical ("RNG only for to-hit").
	# Integrity damage; at 0 the object breaks through the SAME resolver chain physics
	# contact uses, so on_break (EXPLODE/FLOOD/...) fires with full events.
	if not t.is_unit:
		events.push_back(GE.new(E.Ev.ATTACK_SHOOT, {
			"actor": actor_id, "target": target_id, "chance": E.MAX_HIT_CHANCE,
		}))
		# Demolition tools make object-busting real: flat bonus, then multiplier.
		var obj_dmg: int = (E.SHOOT_DAMAGE_BASE + a.object_damage_bonus) * max(1, a.object_damage_mult)
		t.take_damage(obj_dmg)
		_apply_recoil(state, a, events)
		if t.integrity > 0:
			events.push_back(GE.new(E.Ev.OBJECT_DAMAGED, {
				"id": t.id, "dmg": obj_dmg, "integrity_left": t.integrity,
			}))
		else:
			var rr = Physics.resolve_break(state, t.id)
			state.adopt(rr.state)
			for ev in rr.events:
				events.push_back(ev)
		return events

	# Vanguard (Firebrand capstone): an armed first-strike autocrit is a GUARANTEED, rng-free hit.
	# Consumed here; rng is NOT drawn on the autocrit path (short-circuit below), so a normal shot's
	# roll order — and every existing fixture, where no Firebrand holds momentum — is byte-identical.
	var autocrit: bool = a.first_attack_autocrit
	if autocrit:
		a.first_attack_autocrit = false
	var chance: int = E.MAX_HIT_CHANCE if autocrit else hit_chance(state, a, t)
	events.push_back(GE.new(E.Ev.ATTACK_SHOOT, {
		"actor": actor_id, "target": target_id, "chance": chance,
	}))

	var hit: bool = autocrit or state.rng.chance(chance)
	if not hit:
		events.push_back(GE.new(E.Ev.MISS, {"actor": actor_id, "target": target_id}))
		_apply_recoil(state, a, events)
		return events

	# Phase 6 damage-gate (Sub-Spec B): a shielded target (the Conductor's relay-shield, a
	# gated Section Captain) shrugs off the hit. The shot still LANDS (rng consumed above,
	# so determinism + the 570 baseline hold for non-gated targets) but deals no damage.
	if not CaptainSystem.can_take_damage(state, t):
		events.push_back(GE.new(E.Ev.DAMAGE_SHIELDED, {"actor": actor_id, "target": target_id}))
		_apply_recoil(state, a, events)
		return events

	# Fixed damage + small deterministic variance band off the run PRNG, plus the
	# shooter's flat/conditional bonuses (Bloodthirsty/Reckless; Opportunist).
	var dmg: int = E.SHOOT_DAMAGE_BASE + state.rng.randi_range(0, E.SHOOT_DAMAGE_VAR)
	dmg += a.damage_bonus
	if autocrit:
		dmg += E.MOMENTUM_CRIT_BONUS   # Vanguard: the guaranteed first strike hits harder
	if a.dmg_vs_status_bits != 0 and (t.status & a.dmg_vs_status_bits) != 0:
		dmg += a.dmg_vs_status_amt
	if a.dmg_vs_flank != 0 and is_flanked(state, a, t):
		dmg += a.dmg_vs_flank
	# Hardened / Riot Plate: the first hit taken this fight is blunted, once.
	if t.first_hit_reduced > 0:
		dmg = max(0, dmg - t.first_hit_reduced)
		t.first_hit_reduced = 0
	t.take_damage(dmg)
	events.push_back(GE.new(E.Ev.HIT, {
		"actor": actor_id, "target": target_id, "dmg": dmg, "hp_left": t.hp, "crit": autocrit,
	}))
	_apply_recoil(state, a, events)

	if t.hp <= 0:
		# Thread the killer + turn so the death funnel can fire Inspire (an ally's kill grants the
		# Firebrand AP) on an ordinary shot-kill, exactly as an ability-driven kill does.
		_down_target(state, t, events, actor_id, turn)
		# Overrun (Firebrand T3): the actor's own shot-kill refunds an action (a free follow-up),
		# granted before settle() spends this action's AP.
		if a.refund_lunge_on_kill and turn != null and a.alive:
			turn.ap[actor_id] = turn.ap_for(actor_id) + 1
			events.push_back(GE.new(E.Ev.GRANT_AP, {"id": actor_id, "amount": 1, "refund": true}))
	return events


## Reckless: every attack costs the shooter self_recoil HP (evented — never silent).
func _apply_recoil(state, a, events: Array) -> void:
	if a.self_recoil <= 0 or not a.alive:
		return
	a.take_damage(a.self_recoil)
	events.push_back(GE.new(E.Ev.HIT, {
		"actor": a.id, "target": a.id, "dmg": a.self_recoil, "hp_left": a.hp, "recoil": true,
	}))
	if a.hp <= 0:
		_down_target(state, a, events)

# --- death / downing -----------------------------------------------------------
const BleedoutSystem = preload("res://core/bleedout_system.gd")

func _down_target(state, t, events: Array, killer_id: int = -1, turn = null) -> void:
	# Phase 4 (Sub-Spec C §7.4): the bleed-out seam. BleedoutSystem decides whether the
	# unit enters the Downed (Bleeding) revive window or is removed outright. With
	# state.bleedout_enabled == false (the default), it removes immediately — identical
	# to the original Phase 0-i behavior every pre-Phase-4 test relies on.
	# killer_id/turn (default -1/null → the pre-momentum behavior) let the funnel fire Inspire;
	# a self-inflicted recoil kill passes neither, so a shooter never "inspires" off its own death.
	BleedoutSystem.down_or_kill(state, t, events, killer_id, turn)

# ============================ STATIC COMBAT MATH (shared with AI) ===============

## Weapon range gate (Manhattan tiles within WEAPON_RANGE).
static func has_range(from: Vector2i, to: Vector2i) -> bool:
	return _manhattan(from, to) <= E.WEAPON_RANGE

## Tile-traced line of sight (GDD §5.3): blocked by WALL terrain and full cover
## (cover == 2) on any tile strictly between shooter and target. Integer Bresenham.
static func in_los(state, from: Vector2i, to: Vector2i) -> bool:
	for p in _line(from, to):
		if p == from or p == to:
			continue
		if not state.in_bounds(p):
			return false
		var t = state.tile(p)
		if t.terrain == E.Terrain.WALL:
			return false
		if t.cover == 2:
			return false
		if t.has_layer(E.L_STEAM):
			return false   # a steam cloud breaks line of sight (Sub-Spec D2.5)
		if t.has_layer(E.L_CONCEAL):
			return false   # concealment (underbrush/vines/canvas) blocks LoS, passable (E1.4)
		# A body standing between us also blocks the shot.
		var occ = state.occupant_at(p)
		if occ != null:
			return false
	return true

## To-hit per §5.4. Pure of RNG (the roll happens in execute()).
## Starts from the SHOOTER's authored accuracy stat (archetype/enemy stats + trait/gear
## mods, stamped on the SimEntity at spawn); E.BASE_ACCURACY only when unset (-1).
static func hit_chance(state, a, t) -> int:
	var chance: int = a.accuracy if a.accuracy > 0 else E.BASE_ACCURACY
	# Timed buffs (Rally) + car-wide sight modifier (Flickering Lights) + conditional
	# trait mods (Shaky: -acc while the SHOOTER carries a status).
	chance += a.acc_buff + state.accuracy_mod
	for m in a.acc_status_mods:
		if a.has_status(int(m.get("bit", 0))):
			chance += int(m.get("amount", 0))

	# Range falloff beyond the free band.
	var dist: int = _manhattan(a.pos, t.pos)
	if dist > E.RANGE_FREE_TILES:
		chance -= (dist - E.RANGE_FREE_TILES) * E.RANGE_FALLOFF

	# Directional cover (Phase 2): cover protects only from the side(s) it faces.
	# A shot from an unprotected angle = FLANKED -> cover removed + flank bonus (§5.4).
	var cover: int = cover_against(state, a, t)
	# Pierce (ignore_cover_level) shaves cover; Sabotaged Security strips ENEMY cover.
	cover = max(0, cover - a.ignore_cover_level)
	if t.faction == E.Faction.ENEMY and state.enemy_cover_mod != 0:
		cover = max(0, cover + state.enemy_cover_mod)
	if is_flanked(state, a, t):
		chance += E.FLANK_BONUS
	else:
		if cover == 1:
			chance -= E.HALF_COVER_PEN
		elif cover >= 2:
			chance -= E.FULL_COVER_PEN

	# Target-status mods — the physics → damage payoff (§5.4 / §5.5).
	if t.has_status(E.S_PRONE):
		chance += E.PRONE_HIT_BONUS    # prone ≈ guaranteed
	if t.has_status(E.S_STUNNED):
		chance += E.STUN_HIT_BONUS
	if t.has_status(E.S_SOAKED):
		chance += E.SOAKED_HIT_BONUS

	# Shooter-status penalties (§5.5): a hindered shooter aims worse.
	if a.has_status(E.S_BLINDED):
		chance += E.BLIND_HIT_PENALTY
	if a.has_status(E.S_SUPPRESSED):
		chance += E.SUPPRESS_HIT_PENALTY
	if a.has_status(E.S_POISONED):
		chance += E.POISON_ACC_PENALTY
	if a.has_status(E.S_CHILLED):
		chance += E.CHILL_HIT_PENALTY

	return clamp(chance, E.MIN_HIT_CHANCE, E.MAX_HIT_CHANCE)

## Omnidirectional cover value (kept for callers/tests that want the raw best cover):
## max of the unit's own cover and the tile's cover.
static func effective_cover(state, t) -> int:
	var c: int = t.cover
	if state.in_bounds(t.pos):
		c = max(c, state.tile(t.pos).cover)
	return c

## Directional cover (§5.4): the cover the target actually enjoys against THIS shot.
##   - Personal cover (the unit's own `cover` field) protects a frontal, orthogonally
##     aligned shot, but is bypassed by a diagonal/flanking approach.
##   - Object/terrain cover is earned from a blocker sitting between target and shooter
##     (the tile adjacent to the target on the shooter's side). It faces only that side.
## Returns the better of the two that actually apply to this shot vector.
static func cover_against(state, a, t) -> int:
	var c: int = 0
	# Personal cover counts only on a non-flanking (orthogonally-aligned) approach.
	if not _is_diagonal(a.pos, t.pos):
		c = max(c, t.cover)
		if state.in_bounds(t.pos):
			c = max(c, state.tile(t.pos).cover)  # the tile the target stands on
	# Directional cover from a blocker on the shooter's side of the target.
	c = max(c, _facing_cover(state, a.pos, t.pos))
	return c

## True if, for THIS shot, the target HAS cover but the shot comes from an angle that
## cover doesn't face — i.e. the flank bypasses real protection (§5.4). A target with
## no cover at all isn't "flanked" (there's nothing to bypass) — it's a plain shot.
static func is_flanked(state, a, t) -> bool:
	# Does the target have ANY cover (personal/tile/facing-object) at all?
	var personal: int = t.cover
	if state.in_bounds(t.pos):
		personal = max(personal, state.tile(t.pos).cover)
	var facing: int = _facing_cover(state, a.pos, t.pos)
	if personal == 0 and facing == 0:
		return false   # nothing to flank
	# A facing blocker between us protects this shot — not a flank.
	if facing > 0:
		return false
	# The target has personal cover, but a diagonal approach bypasses it -> flank.
	return _is_diagonal(a.pos, t.pos)

## Cover granted by a blocker (wall, full-cover tile, or cover-granting object)
## sitting on the tile adjacent to the target toward the shooter — the side it faces.
static func _facing_cover(state, from: Vector2i, to: Vector2i) -> int:
	var step: Vector2i = _approach_step(from, to)   # one tile from target toward shooter
	if step == Vector2i.ZERO:
		return 0
	var bp: Vector2i = to + step
	if not state.in_bounds(bp):
		return 0
	var tile = state.tile(bp)
	if tile.terrain == E.Terrain.WALL:
		return 2   # a wall to your back-toward-them is full cover from that side
	var c: int = tile.cover
	var occ = state.occupant_at(bp)
	if occ != null and not occ.is_unit:
		c = max(c, occ.cover)   # a barricade/furniture object grants its cover
	return c

## The single orthogonal step from `to` toward `from` (dominant axis; ties -> x).
static func _approach_step(from: Vector2i, to: Vector2i) -> Vector2i:
	var dx: int = from.x - to.x
	var dy: int = from.y - to.y
	if dx == 0 and dy == 0:
		return Vector2i.ZERO
	if abs(dx) >= abs(dy):
		return Vector2i(sign(dx), 0)
	return Vector2i(0, sign(dy))

static func _is_diagonal(from: Vector2i, to: Vector2i) -> bool:
	return (from.x != to.x) and (from.y != to.y)

## Back-compat shim: the old name. Flank = strict diagonal approach.
static func is_flanking(from: Vector2i, to: Vector2i) -> bool:
	return _is_diagonal(from, to)

# --- integer Bresenham line (stable, deterministic) ----------------------------
static func _line(from: Vector2i, to: Vector2i) -> Array:
	var points: Array = []
	var x0: int = from.x
	var y0: int = from.y
	var x1: int = to.x
	var y1: int = to.y
	var dx: int = abs(x1 - x0)
	var dy: int = -abs(y1 - y0)
	var sx: int = 1 if x0 < x1 else -1
	var sy: int = 1 if y0 < y1 else -1
	var err: int = dx + dy
	while true:
		points.push_back(Vector2i(x0, y0))
		if x0 == x1 and y0 == y1:
			break
		var e2: int = 2 * err
		if e2 >= dy:
			err += dy
			x0 += sx
		if e2 <= dx:
			err += dx
			y0 += sy
	return points
