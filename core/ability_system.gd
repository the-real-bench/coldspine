class_name AbilitySystem
## Executes a data-defined AbilityDef (content/abilities/*.json) by translating its
## effects[] into the engine primitives that already exist (Sub-Spec C2 kits):
##   - impulse / throw           -> PhysicsResolver (preview==commit clone machinery)
##   - status                    -> StatusSystem
##   - damage / heal / ranged    -> direct hp math (ranged reuses ShootCommand to-hit)
##   - electrify / hack          -> resolver effect / direct conversion
##   - stabilize                 -> BleedoutSystem (the §7.4 revive window)
##   - clear_status / grant_ap   -> support outcomes
## PASSIVE / META kinds (damage_bonus_vs_status, intercept_overwatch, survive_at_1hp,
## momentum_grants, shove_immune, status_immune, slam_force_bonus, object_damage_mult,
## ignore_cover ...) are not executed inline — they are HOOKS evaluated at the right
## moment (on-pick, on-hit). apply_passives() wires the ones the 5 trees use onto the
## SimEntity so the resolver/combat math reads them.
##
## Integer-only; rolls ONLY via state.rng; no SceneTree. Active abilities run through
## AbilityCommand (validate->execute->emit) so they flow like every other action.

const E = preload("res://core/sim_enums.gd")
const GE = preload("res://core/game_event.gd")
const Physics = preload("res://core/physics_resolver.gd")
const StatusSystem = preload("res://core/status_system.gd")
const SimEntityScript = preload("res://core/sim_entity.gd")
const BleedoutSystem = preload("res://core/bleedout_system.gd")
const ShootCommand = preload("res://core/commands/shoot_command.gd")
const CaptainSystem = preload("res://core/captain_system.gd")

# status string -> bitflag (data uses lowercase names).
const STATUS_MAP := {
	"prone": E.S_PRONE, "stunned": E.S_STUNNED, "soaked": E.S_SOAKED,
	"burning": E.S_BURNING, "shocked": E.S_SHOCKED, "poisoned": E.S_POISONED,
	"blinded": E.S_BLINDED, "chilled": E.S_CHILLED, "frozen": E.S_FROZEN,
	"suppressed": E.S_SUPPRESSED, "downed": E.S_DOWNED,
}

# The active effect kinds this system executes inline (everything else is a passive hook).
const ACTIVE_KINDS := {
	"impulse": true, "throw": true, "status": true, "damage": true, "heal": true,
	"ranged_attack": true, "melee_attack": true, "electrify": true, "hack": true,
	"stabilize": true, "clear_status": true, "grant_ap": true, "move": true,
	"immobilize": true,   # Phase 5: Net Gunner — pin a unit (S_NETTED) for durationTurns
	# --- Wave 3b: Steward Last Stand — a downed ally you reach fights one defiant turn (C2 T3). ---
	"downed_fights_one_turn": true,
	# --- Progression-real batch (2026-07-02): the Saboteur/Firebrand/item kit. ---
	"spawn_hazard": true,          # gas_tap / gas_grenade / smoke / incendiary / breaching_charge
	"ignite_gas": true,            # pyro_loop: detonate a standing gas cloud
	"rupture_tank": true,          # coolant_master: burst a FLOOD-onBreak object at range
	"place_charge": true,          # rig: arm a demolition charge on a tile (fuse = next env phase)
	"detonate_all_charges": true,  # remote_detonate: fire every armed charge now
	"deploy_power_source": true,   # junction: drop a live junction box (completes flood->electrify)
	"buff": true,                  # rally / warcry: timed area stat buff (accuracy / move)
	"pull": true,                  # grapple / harpoon: impulse TOWARD the actor
	"disable_all_cycling_traps": true,  # system_seizure: freeze the trap banks for N env phases
	"squad_resist": true,          # rebreather_kit: timed poison+burn immunity, whole squad
	"extend_bleedout_window": true,# triage (active form): +turns on downed allies' windows
	"hacked_units_extra_action": true,  # overclock_hack (Saboteur): grant each hacked ally an extra action now
}

## Passive/meta kinds apply_passives() wires onto the SimEntity at spawn/on-pick.
const PASSIVE_KINDS := {
	"shove_immune": true, "status_immune": true, "slam_force_bonus": true,
	"object_damage_mult": true, "object_integrity_damage_mod": true,
	"damage_bonus_vs_status": true, "damage_bonus_vs_flank": true,
	"intercept_overwatch": true, "survive_at_1hp": true, "momentum_grants": true,
	"damage_bonus": true, "self_recoil": true, "ignore_cover": true,
	"no_end_turn_first_shot": true,
	# --- Wave 3b: Firebrand momentum tree — passive markers wired onto the SimEntity so the
	# momentum meter, the kill/death hooks, and the Vanguard autocrit read them (Sub-Spec C2.5). ---
	"ap_on_ally_kill": true,             # Inspire: ally kills grant this Firebrand AP
	"refund_ability": true,              # Overrun: this actor's kill refunds an action
	"momentum_gain_on_ally_death": true, # Martyr's Wake: an ally's death grants stacks instead of losing them
	"guaranteed_crit": true,             # Vanguard: arm the first-strike autocrit at MAX momentum
}

## Content-referenced kinds DELIBERATELY not implemented yet (loud, allowlisted —
## the run_tests registry check fails on any kind that is neither handled nor here).
## Each entry is a real authored effect that currently push_warning()s once per process.
const DEFERRED_KINDS := {
	# (Wave 3b WIRED the Firebrand momentum tree + Steward Last Stand: momentum_gain_on_ally_death,
	#  ap_on_ally_kill, refund_ability, guaranteed_crit -> PASSIVE_KINDS; downed_fights_one_turn ->
	#  ACTIVE_KINDS. They are no longer inert, so they left this loud allowlist.)
	# Trait kinds with no sim hook yet (draft value-banding, run-layer economy, AI behavior):
	"crit_chance_on_flank": true, "skips_cover_chance": true, "flee_below_hp_pct": true,
	"must_attack_if_able": true, "priority_target": true, "aura": true,
	"aura_self_buff_near_bonded": true, "morale_immune": true, "bond_gain_mod": true,
	"grief_debuff_on_bonded_death": true, "spare_reward_mod": true, "kill_order_mod": true,
	"kill_resource_mod": true, "block_recruit_while_present": true, "recon_depth_mod": true,
	"loot_mod": true, "starting_resource": true, "tool_cost_mod": true,
	"consumable_slot_mod": true, "extra_ability_pick": true,
	"temp_debuff_after_ally_death": true, "no_self_burning_spread": true,
	"stat_mod_while_status_nonacc": true,   # only the accuracy form is wired
}

## Kinds executed NATIVELY by other systems (not through this executor) — allowlisted
## for the registry check: overwatch/killzone reactions (OverwatchSystem), captain kit
## (CaptainSystem), the Conductor pattern deck (ai/conductor_ai.gd), betrayal (C3.5).
const NATIVE_KINDS := {
	"reaction": true, "betrayal_beat": true, "stat_mod": true, "effective_mass_mod": true,
	"damage_resist": true, "status_immune_from_source": true, "first_hit_reduced": true,
	"shove_force_mod": true, "melee_force_mod": true, "shove_resist": true,
	"impact_damage_taken_mod": true, "stat_mod_while_status": true,
	# Captain / Conductor kit (CaptainSystem gates + conductor_ai pattern deck):
	"apply_trait_temp": true, "grant_cover": true, "spawn_enemy": true,
	"targeted_strike": true, "advance_bridge_countdown": true, "dispensers_emit": true,
	"double_deploy": true, "faster_hazard_cycles": true, "toggle_hazard_bank": true,
}

# Warn-once bookkeeping so an unimplemented authored kind is LOUD but not spammy.
static var _warned_kinds := {}

static func warn_unhandled(kind: String, where: String) -> void:
	if kind == "" or _warned_kinds.has(kind):
		return
	_warned_kinds[kind] = true
	push_warning("COLDSPINE: effect kind '%s' (%s) is authored in content but NOT implemented — it does nothing at runtime (see AbilitySystem.DEFERRED_KINDS)." % [kind, where])


## Execute an AbilityDef's active effects against a target. `ctx` carries:
##   { actor, target_id, target_pos, dir, turn (optional, for grant_ap) }
## Returns the ordered event list. Passive-only abilities (Bracing, Demolition, etc.)
## emit a single ABILITY_USE and register their flag via apply_passives().
## `emit_use` prepends the ABILITY_USE marker (default). UseItemCommand passes false — it emits
## its own ITEM_USED marker so an item's effect stream is not double-tagged as an ability.
static func execute(state, ability: Dictionary, ctx: Dictionary, emit_use: bool = true) -> Array:
	var events: Array = []
	var actor = state.entities.get(ctx.get("actor", -1))
	if emit_use:
		events.push_back(GE.new(E.Ev.ABILITY_USE, {
			"ability": ability.get("id", "?"), "actor": ctx.get("actor", -1),
		}))
	# Resolve the target (entity for enemy/ally targeting, tile for tile/direction).
	var target = null
	if ctx.has("target_id") and ctx["target_id"] != -1:
		target = state.entities.get(ctx["target_id"])

	var did_impact := {"value": false}   # boxed so on-impact-only effects can read the impulse result
	for eff in ability.get("effects", []):
		var kind: String = eff.get("kind", "")
		if not ACTIVE_KINDS.has(kind):
			# passive/meta — handled by apply_passives() at the right moment. Anything
			# neither active, passive, nor natively-handled is a dead authored effect: LOUD.
			if not PASSIVE_KINDS.has(kind) and not NATIVE_KINDS.has(kind):
				warn_unhandled(kind, "ability %s" % str(ability.get("id", "?")))
			continue
		match kind:
			"impulse":
				_do_impulse(state, actor, target, ctx, eff, events, did_impact)
			"throw":
				_do_throw(state, actor, ctx, eff, events, did_impact)
			"status":
				_do_status(state, target, eff, events, did_impact)
			"damage":
				_do_damage(state, actor, target, eff, events, ctx)
			"heal":
				_do_heal(state, actor, target, eff, events)
			"ranged_attack", "melee_attack":
				_do_attack(state, actor, target, eff, events, ctx)
				if target != null and not target.alive:
					target = null   # killed mid-ability; later effects no-op
			"electrify":
				_do_electrify(state, ctx, eff, events)
			"hack":
				_do_hack(state, target, eff, events)
			"stabilize":
				_do_stabilize(state, target, events)
			"clear_status":
				_do_clear_status(state, target, eff, events)
			"grant_ap":
				_do_grant_ap(ctx, target, eff, events)
			"immobilize":
				_do_immobilize(state, target, eff, events)
			"downed_fights_one_turn":
				_do_last_stand(state, target, events)
			"spawn_hazard":
				_do_spawn_hazard(state, ctx, eff, events)
			"ignite_gas":
				_do_ignite_gas(state, ctx, eff, events)
			"rupture_tank":
				_do_rupture_tank(state, ctx, eff, events)
			"place_charge":
				_do_place_charge(state, actor, ctx, eff, events)
			"detonate_all_charges":
				_do_detonate_all_charges(state, events)
			"deploy_power_source":
				_do_deploy_power_source(state, ctx, events)
			"buff":
				_do_buff(state, actor, ctx, eff, events)
			"pull":
				_do_pull(state, actor, target, eff, events, did_impact)
			"disable_all_cycling_traps":
				_do_disable_traps(state, eff, events)
			"squad_resist":
				_do_squad_resist(state, actor, eff, events)
			"extend_bleedout_window":
				_do_extend_bleedout(state, actor, eff, events)
			"hacked_units_extra_action":
				_do_overclock(state, ctx, eff, events)
			"move":
				pass   # movement is handled by the AbilityCommand placement, not here
			_:
				pass
	return events


# --- effect handlers -----------------------------------------------------------
static func _do_impulse(state, actor, target, ctx: Dictionary, eff: Dictionary, events: Array, did_impact: Dictionary) -> void:
	if target == null or not target.movable:
		return
	var force: int = int(eff.get("force", E.SHOVE_FORCE))
	# Slam-force bonus (Juggernaut) lives on the actor as a passive hook.
	if actor != null:
		force += actor.slam_force_bonus
	var dir: Vector2i = ctx.get("dir", Vector2i.ZERO)
	if dir == Vector2i.ZERO and actor != null:
		dir = _dir_from_to(actor.pos, target.pos)
	if dir == Vector2i.ZERO:
		return
	var before: Vector2i = target.pos
	var res = Physics.resolve_impulse(state, target.id, dir, force, false)
	state.adopt(res.state)
	for ev in res.events:
		events.push_back(ev)
		if ev.type == E.Ev.IMPACT_WALL or ev.type == E.Ev.COLLIDE_BODY:
			did_impact["value"] = true
	# If the body changed tile, the shove "landed".
	if state.entities.has(target.id) and state.entities[target.id].pos != before:
		did_impact["value"] = did_impact["value"]   # impact flag stays; movement alone isn't "impact"


static func _do_throw(state, actor, ctx: Dictionary, eff: Dictionary, events: Array, did_impact: Dictionary) -> void:
	var thrown_id: int = ctx.get("target_id", -1)
	var thrown = state.entities.get(thrown_id)
	if thrown == null or not thrown.movable or thrown.mass != E.Mass.LIGHT:
		return
	var dir: Vector2i = ctx.get("dir", Vector2i.ZERO)
	if dir == Vector2i.ZERO:
		return
	var force: int = int(eff.get("force", E.THROW_FORCE))
	var res = Physics.resolve_impulse(state, thrown_id, dir, force, false)
	state.adopt(res.state)
	for ev in res.events:
		events.push_back(ev)
		if ev.type == E.Ev.IMPACT_WALL or ev.type == E.Ev.COLLIDE_BODY:
			did_impact["value"] = true


static func _do_status(state, target, eff: Dictionary, events: Array, did_impact: Dictionary) -> void:
	if target == null:
		return
	# onImpactOnly / onWallImpactOnly gate on the prior impulse result.
	if eff.get("onImpactOnly", false) and not did_impact["value"]:
		return
	if eff.get("onWallImpactOnly", false) and not did_impact["value"]:
		return
	var sname: String = eff.get("status", "")
	var bit: int = int(STATUS_MAP.get(sname, 0))
	if bit == 0:
		return
	# Respect Prone-immunity (Juggernaut / Sure-Footed) for prone.
	if bit == E.S_PRONE and target.prone_immune:
		return
	if not target.has_status(bit):
		target.add_status(bit)
		events.push_back(GE.new(E.Ev.STATUS_APPLY, {"id": target.id, "status": bit}))


static func _do_damage(state, actor, target, eff: Dictionary, events: Array, ctx: Dictionary = {}) -> void:
	if target == null or not target.alive:
		return
	if eff.get("onImpactOnly", false):
		return   # impact-gated direct damage is handled with the impulse, skip standalone
	var amt: int = int(eff.get("amount", 0))
	if amt <= 0:
		return
	# Phase 6 damage-gate: a shielded target (Conductor relay-shield / gated Captain) shrugs it off.
	if not CaptainSystem.can_take_damage(state, target):
		events.push_back(GE.new(E.Ev.DAMAGE_SHIELDED, {"target": target.id}))
		return
	target.take_damage(amt)
	events.push_back(GE.new(E.Ev.HIT, {"target": target.id, "dmg": amt, "hp_left": target.hp}))
	if target.is_unit and target.hp <= 0:
		# Killer + turn thread through so the death funnel can fire Inspire (ap_on_ally_kill).
		BleedoutSystem.down_or_kill(state, target, events, actor.id if actor != null else -1, ctx.get("turn", null))


static func _do_heal(state, actor, target, eff: Dictionary, events: Array) -> void:
	var who = target if target != null else actor
	if who == null or not who.is_unit:
		return
	var amt: int = int(eff.get("amount", 0))
	if amt <= 0 or who.downed or who.dead:
		return
	# Heals cap at max_hp (§10 scarcity: no banking HP above the ceiling). max(hp, max_hp)
	# protects externally-granted bonus HP (captain guard buff) from being clipped; an
	# unstamped legacy entity (max_hp <= 0) keeps the old uncapped behavior.
	var before: int = who.hp
	if who.max_hp > 0:
		who.hp = min(who.hp + amt, max(who.hp, who.max_hp))
	else:
		who.hp += amt
	events.push_back(GE.new(E.Ev.HEAL, {"id": who.id, "amount": who.hp - before, "hp": who.hp}))


static func _do_attack(state, actor, target, eff: Dictionary, events: Array, ctx: Dictionary = {}) -> void:
	if actor == null or target == null or not target.alive:
		return
	# Vanguard (Firebrand capstone): consume an armed first-strike autocrit — a guaranteed hit
	# that crits. rng is NOT drawn on the autocrit path (guaranteed), so a non-Vanguard attack's
	# roll order is byte-identical to pre-fix.
	var autocrit: bool = actor.first_attack_autocrit
	if autocrit:
		actor.first_attack_autocrit = false
	var guaranteed: bool = eff.get("guaranteedHit", false) or autocrit
	var chance: int = E.MAX_HIT_CHANCE
	if not guaranteed:
		chance = ShootCommand.hit_chance(state, actor, target)
		chance = clamp(chance + int(eff.get("accuracyBonus", 0)), E.MIN_HIT_CHANCE, E.MAX_HIT_CHANCE)
	events.push_back(GE.new(E.Ev.ATTACK_SHOOT, {"actor": actor.id, "target": target.id, "chance": chance}))
	var hit: bool = guaranteed or state.rng.chance(chance)
	if not hit:
		events.push_back(GE.new(E.Ev.MISS, {"actor": actor.id, "target": target.id}))
		return
	# Phase 6 damage-gate: a shielded target shrugs off the landed shot (no damage).
	if not CaptainSystem.can_take_damage(state, target):
		events.push_back(GE.new(E.Ev.DAMAGE_SHIELDED, {"actor": actor.id, "target": target.id}))
		return
	# Base ranged damage; the AbilityDef's own {kind:damage} adds the rest. The actor's
	# flat/conditional bonuses (Bloodthirsty/Reckless; Opportunist) apply here too.
	var dmg: int = E.SHOOT_DAMAGE_BASE + actor.damage_bonus
	if autocrit:
		dmg += E.MOMENTUM_CRIT_BONUS   # Vanguard: the guaranteed first strike hits harder
	if actor.dmg_vs_status_bits != 0 and (target.status & actor.dmg_vs_status_bits) != 0:
		dmg += actor.dmg_vs_status_amt
	if target.first_hit_reduced > 0:
		dmg = max(0, dmg - target.first_hit_reduced)
		target.first_hit_reduced = 0
	target.take_damage(dmg)
	events.push_back(GE.new(E.Ev.HIT, {"actor": actor.id, "target": target.id, "dmg": dmg, "hp_left": target.hp, "crit": autocrit}))
	if target.is_unit and target.hp <= 0:
		var turn = ctx.get("turn", null)
		BleedoutSystem.down_or_kill(state, target, events, actor.id, turn)   # funnels Inspire (ally-kill AP)
		# Overrun (Firebrand T3): the actor's own kill refunds an action (a bonus Lunge). Granted
		# BEFORE settle() spends the ability's AP, so the net effect is a free follow-up.
		if actor.refund_lunge_on_kill and turn != null and actor.alive:
			turn.ap[actor.id] = turn.ap_for(actor.id) + 1
			events.push_back(GE.new(E.Ev.GRANT_AP, {"id": actor.id, "amount": 1, "refund": true}))


static func _do_electrify(state, ctx: Dictionary, eff: Dictionary, events: Array) -> void:
	# On-demand electrify (Saboteur Junction / Marksman Soaked-Spark): shock every Soaked
	# unit standing in water. Direct, deterministic — no rng, no impulse.
	for id in state.entity_ids_sorted():
		var e = state.entities[id]
		if e.is_unit and e.has_status(E.S_SOAKED) and state.in_bounds(e.pos) and state.tile(e.pos).has_layer(E.L_WATER):
			e.take_damage(E.SHOCK_DAMAGE)
			if not e.has_status(E.S_SHOCKED):
				e.add_status(E.S_SHOCKED)
			events.push_back(GE.new(E.Ev.SHOCK, {"id": e.id, "dmg": E.SHOCK_DAMAGE}))
			if e.hp <= 0:
				BleedoutSystem.down_or_kill(state, e, events, ctx.get("actor", -1), ctx.get("turn", null))


static func _do_hack(state, target, eff: Dictionary, events: Array) -> void:
	# Convert a robot/turret enemy to the player's side (or disable). Mechanically: flip
	# faction for a robot target. Content gates which enemies are hackable.
	if target == null or not target.is_unit:
		return
	target.faction = E.Faction.PLAYER
	events.push_back(GE.new(E.Ev.HACKED, {"id": target.id}))


static func _do_stabilize(state, target, events: Array) -> void:
	if target == null:
		return
	BleedoutSystem.stabilize(state, target, events)


static func _do_clear_status(state, target, eff: Dictionary, events: Array) -> void:
	if target == null:
		return
	var names = eff.get("status", [])
	if typeof(names) != TYPE_ARRAY:
		names = [names]
	var cleared := false
	for sname in names:
		var bit: int = int(STATUS_MAP.get(sname, 0))
		if bit != 0 and target.has_status(bit):
			target.clear_status(bit)
			cleared = true
			events.push_back(GE.new(E.Ev.STATUS_CLEAR, {"id": target.id, "status": bit}))
	if cleared:
		events.push_back(GE.new(E.Ev.CLEANSE, {"id": target.id}))


## Phase 5 — Net Gunner immobilize: pin the target (S_NETTED) for durationTurns. The
## TurnManager hands a netted unit 0 AP; HazardSystem counts the timer down. Deterministic.
static func _do_immobilize(state, target, eff: Dictionary, events: Array) -> void:
	if target == null or not target.is_unit or not target.alive:
		return
	target.net_timer = int(eff.get("durationTurns", E.NET_TURNS))
	if not target.has_status(E.S_NETTED):
		target.add_status(E.S_NETTED)
	events.push_back(GE.new(E.Ev.NET, {"id": target.id, "turns": target.net_timer}))


static func _do_grant_ap(ctx: Dictionary, target, eff: Dictionary, events: Array) -> void:
	var turn = ctx.get("turn", null)
	if turn == null or target == null:
		return
	var amt: int = int(eff.get("amount", 1))
	turn.ap[target.id] = turn.ap_for(target.id) + amt
	events.push_back(GE.new(E.Ev.GRANT_AP, {"id": target.id, "amount": amt}))


# ============ Progression-real batch (2026-07-02): Saboteur/Firebrand/item kit ============

## spawn_hazard: seed a live hazard layer at target_pos (radius = Manhattan diamond).
## "poison_gas" -> gas cloud (HazardSystem spreads/ignites it), "fire" -> burning tiles,
## "steam_vent"/"steam" -> LoS-blocking steam, "explosion" -> an immediate blast through
## the resolver (breaching_charge). Deterministic, rng-free.
static func _do_spawn_hazard(state, ctx: Dictionary, eff: Dictionary, events: Array) -> void:
	var origin: Vector2i = ctx.get("target_pos", Vector2i(-1, -1))
	if not state.in_bounds(origin):
		return
	var name: String = eff.get("hazard", "")
	var radius: int = int(eff.get("radius", 0))
	if name == "explosion":
		var rr = Physics.resolve_explosion(state, origin, max(1, radius), E.EXPLOSION_DAMAGE, E.EXPLOSION_FORCE)
		state.adopt(rr.state)
		for ev in rr.events:
			events.push_back(ev)
		return
	for p in _diamond(state, origin, radius):
		var t = state.tile(p)
		if t.terrain == E.Terrain.WALL:
			continue
		match name:
			"poison_gas":
				t.status_layer |= E.L_GAS
				t.gas_timer = max(t.gas_timer, E.GAS_DURATION)
				events.push_back(GE.new(E.Ev.GAS_SPREAD, {"pos": p}))
				var occ_g = state.occupant_at(p)
				if occ_g != null and occ_g.is_unit:
					StatusSystem.apply_poison(occ_g, events)
			"fire":
				t.status_layer |= E.L_FIRE
				t.status_timer = max(t.status_timer, E.FIRE_DURATION)
				events.push_back(GE.new(E.Ev.FIRE_SPREAD, {"pos": p}))
				var occ_f = state.occupant_at(p)
				if occ_f != null and occ_f.is_unit:
					StatusSystem.apply_burning(occ_f, events)
			"steam_vent", "steam":
				t.status_layer |= E.L_STEAM
				t.status_timer = max(t.status_timer, E.STEAM_DURATION)
				events.push_back(GE.new(E.Ev.GAS_SPREAD, {"pos": p, "steam": true}))
			_:
				pass


## ignite_gas: detonate a standing gas cloud at target_pos (Pyro Loop). No gas = no-op.
static func _do_ignite_gas(state, ctx: Dictionary, eff: Dictionary, events: Array) -> void:
	var origin: Vector2i = ctx.get("target_pos", Vector2i(-1, -1))
	if not state.in_bounds(origin) or not state.tile(origin).has_layer(E.L_GAS):
		return
	events.push_back(GE.new(E.Ev.IGNITE, {"pos": origin}))
	var radius: int = int(eff.get("explosionRadius", E.EXPLOSION_RADIUS))
	var dmg: int = int(eff.get("explosionDamage", E.EXPLOSION_DAMAGE))
	var force: int = int(eff.get("explosionForce", E.EXPLOSION_FORCE))
	# The blast consumes the cloud around the ignition point.
	for p in _diamond(state, origin, radius):
		var t = state.tile(p)
		if t.has_layer(E.L_GAS):
			t.status_layer &= ~E.L_GAS
			t.gas_timer = 0
	var rr = Physics.resolve_explosion(state, origin, radius, dmg, force)
	state.adopt(rr.state)
	for ev in rr.events:
		events.push_back(ev)


## rupture_tank: burst a FLOOD-onBreak object (coolant tank / water main) at range —
## through the SAME resolver break chain gunfire uses, so preview == commit holds.
static func _do_rupture_tank(state, ctx: Dictionary, eff: Dictionary, events: Array) -> void:
	var pos: Vector2i = ctx.get("target_pos", Vector2i(-1, -1))
	var obj = state.occupant_at(pos)
	if obj == null and ctx.get("target_id", -1) != -1:
		obj = state.entities.get(ctx["target_id"])
	if obj == null or obj.is_unit or obj.on_break != E.OnBreak.FLOOD:
		return
	obj.break_param += int(eff.get("floodRadiusBonus", 0))
	var rr = Physics.resolve_break(state, obj.id)
	state.adopt(rr.state)
	for ev in rr.events:
		events.push_back(ev)


## place_charge (Rig): arm a demolition charge on the tile. It fires on the NEXT env
## phase (fuse) or immediately via detonate_all_charges (Remote Detonate).
static func _do_place_charge(state, actor, ctx: Dictionary, eff: Dictionary, events: Array) -> void:
	var pos: Vector2i = ctx.get("target_pos", Vector2i(-1, -1))
	if not state.in_bounds(pos):
		return
	state.charges.push_back({
		"pos": pos,
		"dmg": int(eff.get("explosionDamage", E.EXPLOSION_DAMAGE)),
		"force": int(eff.get("explosionForce", E.EXPLOSION_FORCE)),
		"radius": int(eff.get("explosionRadius", E.EXPLOSION_RADIUS)),
		"fuse": E.CHARGE_FUSE_TURNS,
	})
	events.push_back(GE.new(E.Ev.CHARGE_PLACED, {
		"pos": pos, "by": actor.id if actor != null else -1, "count": state.charges.size(),
	}))


## detonate_all_charges (Remote Detonate): fire every armed charge, in placement order.
static func _do_detonate_all_charges(state, events: Array) -> void:
	var armed: Array = state.charges
	state.charges = []
	for ch in armed:
		detonate_charge(state, ch, events)


## Shared with HazardSystem's fuse expiry: one charge -> one resolver blast.
static func detonate_charge(state, ch: Dictionary, events: Array) -> void:
	var pos: Vector2i = ch.get("pos", Vector2i.ZERO)
	events.push_back(GE.new(E.Ev.CHARGE_DETONATED, {"pos": pos}))
	var rr = Physics.resolve_explosion(state, pos, int(ch.get("radius", E.EXPLOSION_RADIUS)),
		int(ch.get("dmg", E.EXPLOSION_DAMAGE)), int(ch.get("force", E.EXPLOSION_FORCE)))
	state.adopt(rr.state)
	for ev in rr.events:
		events.push_back(ev)


## deploy_power_source (Junction): drop a live junction box on an open tile — the
## flood -> electrify loop's missing half. Anchored, destructible, OBJECT faction.
static func _do_deploy_power_source(state, ctx: Dictionary, events: Array) -> void:
	var pos: Vector2i = ctx.get("target_pos", Vector2i(-1, -1))
	if not state.in_bounds(pos) or state.occupant_at(pos) != null:
		return
	if state.tile(pos).terrain == E.Terrain.WALL:
		return
	var box = SimEntityScript.new()
	box.is_unit = false
	box.pos = pos
	box.mass = E.Mass.ANCHORED
	box.movable = false
	box.integrity = 2
	box.hp = -1
	box.faction = E.Faction.OBJECT
	box.name = "junction_box"
	box.is_power_source = true
	state.add_entity(box)
	events.push_back(GE.new(E.Ev.SPAWNED, {"id": box.id, "pos": pos, "what": "junction_box"}))


## buff (Rally / Warcry): a TIMED stat buff on every ally in the area. accuracy -> to-hit;
## move -> Move range. Expires in the env phase countdown (HazardSystem).
static func _do_buff(state, actor, ctx: Dictionary, eff: Dictionary, events: Array) -> void:
	if actor == null:
		return
	var center: Vector2i = ctx.get("target_pos", actor.pos)
	if not state.in_bounds(center):
		center = actor.pos
	var area: int = int(eff.get("area", 0))
	var stat: String = eff.get("stat", "")
	var amount: int = int(eff.get("amount", 0))
	var duration: int = int(eff.get("durationTurns", 1))
	if amount == 0 or (stat != "accuracy" and stat != "move"):
		return
	for id in state.entity_ids_sorted():
		var e = state.entities[id]
		if not e.is_unit or not e.alive or e.faction != actor.faction:
			continue
		if _manhattan(e.pos, center) > area:
			continue
		if stat == "accuracy":
			e.acc_buff = amount
			e.acc_buff_timer = duration
		else:
			e.move_buff = amount
			e.move_buff_timer = duration
		events.push_back(GE.new(E.Ev.BUFF_APPLY, {"id": id, "stat": stat, "amount": amount, "turns": duration}))


## pull (Grapple / Harpoon): an impulse TOWARD the actor — same resolver machinery.
static func _do_pull(state, actor, target, eff: Dictionary, events: Array, did_impact: Dictionary) -> void:
	if actor == null or target == null or not target.movable:
		return
	var dir: Vector2i = _dir_from_to(target.pos, actor.pos)
	if dir == Vector2i.ZERO:
		return
	var force: int = int(eff.get("force", E.SHOVE_FORCE))
	var res = Physics.resolve_impulse(state, target.id, dir, force, false)
	state.adopt(res.state)
	for ev in res.events:
		events.push_back(ev)
		if ev.type == E.Ev.IMPACT_WALL or ev.type == E.Ev.COLLIDE_BODY:
			did_impact["value"] = true


## disable_all_cycling_traps (System Seizure): the trap banks hold for N env phases.
static func _do_disable_traps(state, eff: Dictionary, events: Array) -> void:
	var turns: int = int(eff.get("durationTurns", 2))
	state.traps_disabled_timer = max(state.traps_disabled_timer, turns)
	events.push_back(GE.new(E.Ev.TRAPS_DISABLED, {"turns": state.traps_disabled_timer}))


## squad_resist (Rebreather Kit): timed poison+burn immunity for the caster's faction.
static func _do_squad_resist(state, actor, eff: Dictionary, events: Array) -> void:
	if actor == null:
		return
	var turns: int = int(eff.get("durationTurns", 3))
	for id in state.entity_ids_sorted():
		var e = state.entities[id]
		if e.is_unit and e.alive and e.faction == actor.faction:
			e.temp_resist_timer = max(e.temp_resist_timer, turns)
			events.push_back(GE.new(E.Ev.BUFF_APPLY, {"id": id, "stat": "resist", "amount": 1, "turns": turns}))


## overclock_hack (Saboteur T2 pick): grant each currently-HACKED ally an extra action
## this phase. A "hacked" ally is a converted enemy/robot/turret now on the PLAYER faction
## (Saboteur `hack`) — it has NO persistent roster instance, so `instance_id == -1` is the
## documented "transient body" sentinel that separates it from a drafted hero (instance_id
## = its roster id). Reuses the AP economy (turn.ap) exactly like _do_grant_ap; deterministic,
## rng-free. No hacked units in play -> a harmless no-op cast (0 AP ability).
static func _do_overclock(state, ctx: Dictionary, eff: Dictionary, events: Array) -> void:
	var turn = ctx.get("turn", null)
	if turn == null:
		return
	var count: int = int(eff.get("count", 1))
	if count <= 0:
		return
	for id in state.entity_ids_sorted():
		var e = state.entities[id]
		if e.is_unit and e.alive and e.faction == E.Faction.PLAYER and e.instance_id == -1:
			turn.ap[e.id] = turn.ap_for(e.id) + count
			events.push_back(GE.new(E.Ev.GRANT_AP, {"id": e.id, "amount": count}))


## extend_bleedout_window (Triage, active cast): +turns on every downed ally's window.
static func _do_extend_bleedout(state, actor, eff: Dictionary, events: Array) -> void:
	if actor == null:
		return
	var turns: int = int(eff.get("turns", 1))
	for id in state.entity_ids_sorted():
		var e = state.entities[id]
		if e.is_unit and e.faction == actor.faction and e.downed and e.bleed_timer > 0:
			e.bleed_timer += turns
			events.push_back(GE.new(E.Ev.BUFF_APPLY, {"id": id, "stat": "bleedout", "amount": turns, "turns": e.bleed_timer}))


## Manhattan diamond (incl. center) clipped to the grid, stable scan order.
static func _diamond(state, origin: Vector2i, radius: int) -> Array:
	var out: Array = []
	for dy in range(-radius, radius + 1):
		for dx in range(-radius, radius + 1):
			if abs(dx) + abs(dy) > radius:
				continue
			var p := Vector2i(origin.x + dx, origin.y + dy)
			if state.in_bounds(p):
				out.push_back(p)
	return out


static func _manhattan(a: Vector2i, b: Vector2i) -> int:
	return abs(a.x - b.x) + abs(a.y - b.y)


# ============================ PASSIVE / META HOOKS =============================
## Wire the passive/meta effects of a unit's CHOSEN abilities onto its SimEntity so the
## resolver/combat math reads them. Called at spawn / on-pick. The hooks the 5 trees use:
##   - shove_immune / status_immune(prone)  -> Bracing, Juggernaut
##   - slam_force_bonus                      -> Juggernaut
##   - object_damage_mult                    -> Demolition (stored for the resolver caller)
##   - prone immunity                        -> Juggernaut, Sure-Footed (flood)
##   - damage_bonus_vs_status / vs_flank     -> Opportunist (read at hit time)
##   - intercept_overwatch                   -> Bodyguard (read by the overwatch system)
##   - survive_at_1hp                        -> Guardian Protocol (read at lethal-damage time)
## Returns a small dict of computed modifiers for callers that need them at action time.
static func apply_passives(db, unit, entity) -> Dictionary:
	var mods := {
		"object_damage_mult": 1, "slam_force_bonus": 0,
		"damage_bonus_vs_status": [], "damage_bonus_vs_flank": 0,
		"intercept_overwatch": false, "survive_at_1hp": false,
		"momentum_grants": false,
	}
	for aid in unit.chosen_abilities:
		var ab: Dictionary = db.ability(aid)
		for eff in ab.get("effects", []):
			var kind: String = eff.get("kind", "")
			match kind:
				"shove_immune":
					entity.shove_immune = true
				"status_immune":
					if eff.get("status", "") == "prone":
						entity.prone_immune = true
				"slam_force_bonus":
					mods["slam_force_bonus"] += int(eff.get("value", 0))
					entity.slam_force_bonus += int(eff.get("value", 0))
				"object_damage_mult":
					mods["object_damage_mult"] = max(mods["object_damage_mult"], int(eff.get("value", 1)))
					entity.object_damage_mult = max(entity.object_damage_mult, int(eff.get("value", 1)))
				"object_integrity_damage_mod":
					mods["object_damage_mult"] += 1
					entity.object_damage_bonus += int(eff.get("amount", 1))
				"damage_bonus_vs_status":
					mods["damage_bonus_vs_status"] = eff.get("status", [])
					var bits: int = 0
					var names = eff.get("status", [])
					if typeof(names) != TYPE_ARRAY:
						names = [names]
					for sn in names:
						bits |= int(STATUS_MAP.get(sn, 0))
					entity.dmg_vs_status_bits |= bits
					entity.dmg_vs_status_amt = max(entity.dmg_vs_status_amt, int(eff.get("amount", 0)))
				"damage_bonus_vs_flank":
					mods["damage_bonus_vs_flank"] = int(eff.get("amount", 0))
					entity.dmg_vs_flank += int(eff.get("amount", 0))
				"damage_bonus":
					entity.damage_bonus += int(eff.get("amount", 0))
				"self_recoil":
					entity.self_recoil += int(eff.get("amount", 0))
				"ignore_cover":
					entity.ignore_cover_level = max(entity.ignore_cover_level, int(eff.get("coverLevel", 1)))
				"no_end_turn_first_shot":
					entity.steady_shot = true
				"extend_bleedout_window":
					entity.triage_field = true   # passive form: +window for downed squadmates
				"intercept_overwatch":
					mods["intercept_overwatch"] = true
				"survive_at_1hp":
					mods["survive_at_1hp"] = true
					entity.guardian_protocol = true
				"momentum_grants":
					mods["momentum_grants"] = true
					if eff.get("stat", "") == "accuracy":
						entity.momentum_acc = true   # Zeal: momentum also raises to-hit
				"ap_on_ally_kill":
					entity.inspire_ap += int(eff.get("amount", 1))       # Inspire
				"refund_ability":
					entity.refund_lunge_on_kill = true                   # Overrun
				"momentum_gain_on_ally_death":
					entity.momentum_martyr = true                        # Martyr's Wake
					entity.martyr_gain = max(entity.martyr_gain, int(eff.get("amount", E.MARTYRS_WAKE_GAIN)))
				"guaranteed_crit":
					entity.vanguard_crit = true                          # Vanguard
				_:
					# A chosen pick whose kind is neither passive-wired, active (fires via
					# AbilityCommand), nor natively handled is a DEAD pick: warn LOUDLY.
					if kind != "" and not ACTIVE_KINDS.has(kind) and not NATIVE_KINDS.has(kind):
						warn_unhandled(kind, "passive pick %s" % str(aid))
	return mods


# ============================ FIREBRAND MOMENTUM METER =========================
## Sub-Spec C2.5: the Firebrand's tempo dividend, made integer + deterministic. Momentum lives
## on the SimEntity as an int (0..MOMENTUM_MAX); it is GAINED per car cleared (run layer), LOST
## when an ally permadies (bleedout funnel), and BAKED into a car's combat stats at spawn via
## apply_momentum_combat_mods(). Every mutation routes through _set_momentum so the change is
## clamped and EVENTED (MOMENTUM_CHANGED) for the renderer. No rng, ever.

## Bake the entry-momentum combat bonuses onto a freshly spawned combat body. Called right after
## apply_passives() by UnitInstance.to_sim_entity. A no-op for non-momentum bodies and for a
## Firebrand at 0 stacks — so a fresh/non-Firebrand spawn stays byte-identical to pre-fix.
static func apply_momentum_combat_mods(db, unit, entity) -> void:
	var arch: Dictionary = db.archetype(unit.archetype_id)
	if arch.get("innateTrait", "") != "momentum":
		return   # not a momentum unit — leave the body untouched
	entity.has_momentum = true   # marker the bleedout death-funnel reads (data-driven, no hardcoded id)
	var m: int = entity.momentum
	if m <= 0:
		return   # 0 stacks: no bonus yet (byte-identical to a pre-momentum Firebrand)
	entity.damage_bonus += m * E.MOMENTUM_DMG_PER_STACK          # +damage per stack
	if m >= E.MOMENTUM_MOVE_THRESHOLD and entity.move_range > 0:
		entity.move_range += E.MOMENTUM_MOVE_BONUS               # +Move at/above the threshold
	if entity.momentum_acc and entity.accuracy > 0:
		entity.accuracy += m * E.MOMENTUM_ACC_PER_STACK          # Zeal: +to-hit per stack
	if entity.vanguard_crit and m >= E.MOMENTUM_MAX:
		entity.first_attack_autocrit = true                      # Vanguard: arm the first-strike crit


## Clamp + set a body's momentum, emitting MOMENTUM_CHANGED only on a real change (so a no-op
## reset on a 0-stack Firebrand emits nothing and stays byte-identical).
static func _set_momentum(e, value: int, events: Array) -> void:
	var v: int = clamp(value, 0, E.MOMENTUM_MAX)
	if v == e.momentum:
		return
	var before: int = e.momentum
	e.momentum = v
	events.push_back(GE.new(E.Ev.MOMENTUM_CHANGED, {"id": e.id, "momentum": v, "delta": v - before}))


## Add `amount` stacks (clamped), evented. The public momentum-gain decider.
static func gain_momentum(e, amount: int, events: Array) -> void:
	_set_momentum(e, e.momentum + amount, events)


## Car-clear accrual (run layer): every living Firebrand gains a stack when the cell clears a car.
## Operates on the PERSISTENT roster (UnitInstances, which carry their own `momentum`), rng-free.
## FLAGGED hook — run_controller must call this on a car clearance (see the wave report for the
## exact call site); it is NOT wired into run_controller here (that file is the item lane's).
static func grant_car_clear_momentum(db, squad: Array, events: Array = []) -> void:
	for u in squad:
		if u == null or u.dead:
			continue
		if db.archetype(u.archetype_id).get("innateTrait", "") != "momentum":
			continue
		var before: int = u.momentum
		u.momentum = min(E.MOMENTUM_MAX, u.momentum + E.MOMENTUM_PER_CAR)
		if u.momentum != before:
			events.push_back(GE.new(E.Ev.MOMENTUM_CHANGED, {"id": u.id, "momentum": u.momentum, "delta": u.momentum - before}))


## Ally-kill hook (Inspire): called from the single death funnel down_or_kill. A strict no-op
## unless a killer + turn are supplied (physics / hazard / env kills pass neither -> byte-identical),
## so it never perturbs the golden fixtures. When an ally kills an enemy, each Firebrand that picked
## Inspire gains AP (needs the turn to touch the AP economy).
static func on_unit_died(state, victim, killer_id: int, turn, events: Array) -> void:
	if turn == null or killer_id < 0 or victim == null:
		return
	if victim.faction != E.Faction.ENEMY:
		return   # only an ENEMY kill inspires
	var killer = state.entities.get(killer_id)
	if killer == null or killer.faction != E.Faction.PLAYER:
		return
	for id in state.entity_ids_sorted():
		var e = state.entities.get(id)
		if e == null or not e.is_unit or not e.alive or e.faction != E.Faction.PLAYER:
			continue
		if e.inspire_ap > 0:
			turn.ap[e.id] = turn.ap_for(e.id) + e.inspire_ap
			events.push_back(GE.new(E.Ev.GRANT_AP, {"id": e.id, "amount": e.inspire_ap, "inspire": true}))


## Ally-permadeath hook (Momentum downside / Martyr's Wake): called from bleedout.permadeath on a
## PLAYER death. Each surviving Firebrand loses ALL stacks — UNLESS it picked Martyr's Wake, which
## flips the loss into a burst. Data-driven Firebrand detection (has_momentum marker), stable order.
static func on_ally_permadeath(state, dead_e, events: Array) -> void:
	if dead_e == null or dead_e.faction != E.Faction.PLAYER:
		return
	for id in state.entity_ids_sorted():
		var e = state.entities.get(id)
		if e == null or not e.is_unit or not e.alive or e.faction != E.Faction.PLAYER:
			continue
		if not e.has_momentum:
			continue
		if e.momentum_martyr:
			gain_momentum(e, max(1, e.martyr_gain), events)   # the fallen fuel the fire
		else:
			_set_momentum(e, 0, events)                        # a lost comrade breaks the tempo


## Steward Last Stand (C2 T3): a downed ally you reach fights one defiant turn before dying. Revive
## the body to act (hp 1, no longer downed) and arm its borrowed-time counter; bleedout.tick counts
## it down and permadies it after its action. Permadeath stays sacred — this buys a final turn, not
## immortality (the ally still dies; it is never healed above this defiant breath).
static func _do_last_stand(state, target, events: Array) -> void:
	if target == null or not target.is_unit or target.dead or not target.downed:
		return
	target.downed = false
	target.alive = true
	target.hp = max(1, target.hp)
	target.bleed_timer = 0
	target.clear_status(E.S_DOWNED)
	target.clear_status(E.S_BLEEDING)
	target.last_stand = E.LAST_STAND_TURNS
	events.push_back(GE.new(E.Ev.STAND_UP, {"id": target.id, "last_stand": true}))


# --- helpers -------------------------------------------------------------------
static func _dir_from_to(a: Vector2i, b: Vector2i) -> Vector2i:
	var dx: int = b.x - a.x
	var dy: int = b.y - a.y
	if abs(dx) >= abs(dy):
		if dx == 0:
			return Vector2i.ZERO
		return Vector2i(sign(dx), 0)
	return Vector2i(0, sign(dy))
