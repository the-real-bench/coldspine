class_name UnitInstance
extends RefCounted
## The PERSISTENT unit (Sub-Spec C5 CharacterInstance) — distinct from the in-combat
## SimEntity. It survives across cars: archetype + traits + level + XP + chosen
## abilities + inventory + hp/downed/dead. Two bridges to combat:
##   - to_sim_entity()  : spawn the combat body, applying archetype baseStats then
##                        trait/gear stat modifiers (data-driven EffectDef pipeline).
##   - absorb(entity)   : write hp / downed / dead back after combat resolves.
## NO hardcoded stats — everything comes from ContentDB (content/*.json).
## Integer-only, RefCounted, no SceneTree.

const E = preload("res://core/sim_enums.gd")
const SimEntity = preload("res://core/sim_entity.gd")
const ContentDB = preload("res://core/units/content_db.gd")
const AbilitySystem = preload("res://core/ability_system.gd")

var id: int = -1                   # persistent roster id
var name: String = ""
var archetype_id: String = ""
var traits: Array = []             # trait ids (1..3); some may be hidden/unrevealed
var revealed_traits: Array = []    # subset visible to the player (Sub-Spec C5)
var level: int = 1
var xp: int = 0
var chosen_abilities: Array = []   # ability ids picked down the tree (+ signatures known)
var inventory: Array = []          # gear ids carried (drop on permadeath)
var max_hp: int = 1
var hp: int = 1
var downed: bool = false
var dead: bool = false
var faction: int = E.Faction.PLAYER
var momentum: int = 0              # Firebrand momentum stacks (Sub-Spec C2.5); persists car-to-car

# Hidden-loyalty betrayer plumbing (C3.5). Set when the unit rolls Conductor's Kin.
var hidden_betrayer: bool = false
var betrayer_revealed: bool = false


## Build a persistent unit from an archetype id, applying baseStats then trait mods.
## `db` is a ContentDB. Signatures are always-known abilities.
static func from_archetype(db: ContentDB, arch_id: String, p_traits: Array, p_name: String, p_id: int = -1) -> UnitInstance:
	var u: UnitInstance = new()
	u.id = p_id
	u.archetype_id = arch_id
	u.name = p_name
	u.traits = p_traits.duplicate()
	# Hidden traits are NOT auto-revealed; visible ones are.
	for tid in u.traits:
		var td: Dictionary = db.trait_def(tid)
		if td.get("hidden", false):
			if tid == "conductors_kin":
				u.hidden_betrayer = true
		else:
			u.revealed_traits.append(tid)
	var arch: Dictionary = db.archetype(arch_id)
	# Signatures are always available; the tree adds picks on level-up.
	u.chosen_abilities = []
	for sig in arch.get("startingAbilities", []):
		u.chosen_abilities.append(sig)
	# Compute max HP = base + trait HP mods; start at full.
	var base: Dictionary = arch.get("baseStats", {})
	var hp_v: int = int(base.get("hp", 1))
	hp_v += u._trait_stat_sum(db, "hp")
	u.max_hp = max(1, hp_v)
	u.hp = u.max_hp
	return u


## Spawn the combat body. baseStats + trait/gear stat modifiers feed the SimEntity that
## the resolver/commands operate on. mass feeds the physics resolver; gas/fire resist
## traits feed Sub-Spec D (poison_immune / fireproof). Persistent hp/downed carry in.
func to_sim_entity(db: ContentDB, pos: Vector2i) -> SimEntity:
	var arch: Dictionary = db.archetype(archetype_id)
	var base: Dictionary = arch.get("baseStats", {})
	var e := SimEntity.new()
	e.is_unit = true
	e.pos = pos
	e.name = name
	e.faction = faction
	e.archetype_id = archetype_id
	e.instance_id = id
	# Carry the persistent trait ids onto the body so a permadeath at this car can enshrine
	# a real trait legacy (§7.4); the betrayer's hidden trait rides along but Legacy.inherit
	# filters it out (treachery is never inheritable).
	e.traits = traits.duplicate()
	e.integrity = -1
	e.mass = ContentDB.mass_to_int(base.get("mass", "medium"))
	e.hp = hp
	e.max_hp = max_hp   # the heal ceiling rides on the body (set BEFORE add_entity's full-hp stamp)
	e.gear = inventory.duplicate()
	# Carry persistent down/dead status into the body (a stabilized-Downed unit that
	# re-enters combat is still Downed until healed).
	e.downed = downed
	e.dead = dead
	e.momentum = momentum   # Firebrand momentum rides in; combat mods are baked below (after passives)
	# --- Progression-real batch (2026-07-02): authored stats land on the body ---
	# accuracy = archetype base + trait mods (effective_accuracy) + gear mods;
	# move = archetype baseStats.move + trait/gear mods. Both feed real combat math.
	e.accuracy = effective_accuracy(db)
	e.move_range = int(base.get("move", E.MOVE_RANGE)) + _trait_stat_sum(db, "move")
	# --- data-driven trait effects -> SimEntity flags ---
	for tid in traits:
		_apply_trait_to_entity(db, tid, e)
	# --- gear (armor/weapon) passive effects -> SimEntity flags + stat mods ---
	for gid in inventory:
		_apply_gear_to_entity(db, String(gid), e)
	# --- chosen-ability passives (Bracing/Juggernaut/Opportunist/Steady/...) ---
	# THE seam that makes level-up picks real: every spawn wires the picked passive
	# hooks onto the combat body (previously only tests ever called this).
	AbilitySystem.apply_passives(db, self, e)
	# Firebrand momentum meter (Sub-Spec C2.5): bake the entry-momentum combat bonuses (+dmg/stack,
	# +move, Zeal +acc, Vanguard autocrit at MAX). No-op for non-Firebrands / 0-stack Firebrands, so
	# a fresh spawn is byte-identical. MUST run AFTER apply_passives (reads the momentum-tree markers).
	AbilitySystem.apply_momentum_combat_mods(db, self, e)
	# Betrayer plumbing.
	e.hidden_betrayer = hidden_betrayer
	e.betrayer_revealed = betrayer_revealed
	return e


## Write combat results back to the persistent record after a car resolves.
func absorb(e) -> void:
	if e == null:
		return
	hp = clamp(e.hp, 0, max_hp)   # belt-and-braces: banked over-heal never persists across cars
	downed = e.downed
	dead = e.dead
	momentum = e.momentum   # a mid-car reset (ally death) or Martyr's Wake burst carries to the next car
	if dead:
		hp = 0
	# Gear the body still holds (some may have dropped on death) returns to inventory.
	if not e.dead:
		inventory = e.gear.duplicate()


# --- trait stat pipeline (data-driven EffectDef) -------------------------------
## Sum a flat stat_mod across this unit's traits for one stat (e.g. "hp", "accuracy").
func _trait_stat_sum(db: ContentDB, stat: String) -> int:
	var total: int = 0
	for tid in traits:
		var td: Dictionary = db.trait_def(tid)
		for eff in td.get("effects", []):
			if eff.get("kind", "") == "stat_mod" and eff.get("stat", "") == stat:
				total += int(eff.get("amount", 0))
	return total


## Map a trait's effects onto SimEntity flags the sim already understands.
func _apply_trait_to_entity(db: ContentDB, tid: String, e) -> void:
	var td: Dictionary = db.trait_def(tid)
	for eff in td.get("effects", []):
		_apply_effect_to_entity(eff, e, "trait %s" % tid, false)


## Apply one gear item's PASSIVE effects (armor/weapon slots). Consumables/gadgets are
## ACTIVE (UseItemCommand) and stay inert while carried.
func _apply_gear_to_entity(db: ContentDB, gid: String, e) -> void:
	var it: Dictionary = db.item(gid)
	if it.is_empty():
		return
	var slot: String = it.get("slot", "")
	if slot != "armor" and slot != "weapon":
		return
	for eff in it.get("effects", []):
		if eff.get("trigger", "") != "":
			continue   # on_hit riders (maul knockback etc.) are not passive stat mods yet
		_apply_effect_to_entity(eff, e, "item %s" % gid, true)


## The shared EffectDef -> SimEntity pipeline for traits + gear (progression-real batch).
## `from_gear`: gear stat_mods land HERE (trait hp/accuracy/move are already summed by
## from_archetype / effective_accuracy / to_sim_entity — never double-applied).
## Kinds with no sim hook yet warn LOUDLY once (AbilitySystem.DEFERRED_KINDS).
func _apply_effect_to_entity(eff: Dictionary, e, where: String, from_gear: bool) -> void:
	match eff.get("kind", ""):
		"stat_mod":
			if from_gear:
				var amt: int = int(eff.get("amount", 0))
				match eff.get("stat", ""):
					"hp":
						# Gear HP raises the in-combat ceiling (evaporates when unequipped;
						# absorb() clamps back to the persistent max_hp between cars).
						e.max_hp = max(1, e.max_hp + amt)
						e.hp = clamp(e.hp + amt, 1, e.max_hp)
					"accuracy":
						if e.accuracy > 0:
							e.accuracy += amt
					"move":
						if e.move_range > 0:
							e.move_range += amt
					_:
						pass
		"status_immune":
			match eff.get("status", ""):
				"poisoned": e.poison_immune = true
				"chilled": e.chill_immune = true
				_: pass
		"status_immune_from_source":
			if eff.get("status", "") == "prone" and eff.get("source", "") == "flood":
				e.flood_prone_immune = true
		"damage_resist":
			var dt: String = eff.get("damageType", "")
			if dt == "fire":
				e.fireproof = true
			elif dt == "impact":
				e.impact_resist_pct = max(e.impact_resist_pct, int(eff.get("amount_pct", 0)))
		"effective_mass_mod":
			# Planted (+1) makes you harder to shove; Featherweight (-1) easier.
			e.mass = clamp(e.mass + int(eff.get("amount", 0)), E.Mass.LIGHT, E.Mass.ANCHORED)
		"shove_force_mod", "melee_force_mod":
			e.slam_force_bonus += int(eff.get("amount", 0))   # Brawler: harder shoves/slams
		"shove_resist":
			e.shove_resist += int(eff.get("amount", 0))       # Magnetic Boots (item)
		"first_hit_reduced":
			e.first_hit_reduced += int(eff.get("amount", 0))  # Hardened / Riot Plate
		"impact_damage_taken_mod":
			e.impact_damage_mod += int(eff.get("amount", 0))  # Glass Jaw
		"damage_bonus":
			e.damage_bonus += int(eff.get("amount", 0))       # Bloodthirsty / Reckless
		"object_integrity_damage_mod":
			e.object_damage_bonus += int(eff.get("amount", 0))  # Demolitions Expert / Fire Axe
		"stat_mod_while_status":
			# Shaky: -accuracy while the SHOOTER carries a status. Only accuracy is wired.
			if eff.get("stat", "") == "accuracy":
				var bit: int = int(AbilitySystem.STATUS_MAP.get(eff.get("status", ""), 0))
				if bit != 0:
					e.acc_status_mods.append({"bit": bit, "amount": int(eff.get("amount", 0))})
			else:
				AbilitySystem.warn_unhandled("stat_mod_while_status_nonacc", where)
		_:
			var kind: String = eff.get("kind", "")
			if kind != "" and not AbilitySystem.ACTIVE_KINDS.has(kind) \
					and not AbilitySystem.PASSIVE_KINDS.has(kind) \
					and not AbilitySystem.NATIVE_KINDS.has(kind):
				AbilitySystem.warn_unhandled(kind, where)


# --- accuracy for the combat math (base + trait mods); used by abilities/AI ----
func effective_accuracy(db: ContentDB) -> int:
	var arch: Dictionary = db.archetype(archetype_id)
	var acc: int = int(arch.get("baseStats", {}).get("accuracy", E.BASE_ACCURACY))
	acc += _trait_stat_sum(db, "accuracy")
	return acc
