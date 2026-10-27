class_name Leveling
## XP + the 1-of-2 ability pick on level-up (Sub-Spec C §7.3). Data-driven: the choice
## offered at each level is the archetype's abilityTree tier (then the capstone). The
## engine exposes the CHOICE; the renderer/UI presents it later. Deterministic, integer,
## no rng (XP and the tier are fixed by the archetype data), no SceneTree.
##
## Tier mapping: level 1 = base (signatures only). Each level-up reaching level N (>=2)
## offers tier index N-2 of abilityTree; once the tree is exhausted, the capstone.

const E = preload("res://core/sim_enums.gd")
const GE = preload("res://core/game_event.gd")
const ContentDB = preload("res://core/units/content_db.gd")


## Award XP to a UnitInstance; returns the events (XP_GAIN, and LEVEL_UP per level
## gained). Does NOT auto-pick — the level-up leaves a pending choice the caller
## resolves with choose_ability(). Levels are capped at MAX_LEVEL.
static func grant_xp(unit, amount: int, events: Array) -> void:
	if unit == null or amount <= 0:
		return
	unit.xp += amount
	events.push_back(GE.new(E.Ev.XP_GAIN, {"id": unit.id, "amount": amount, "xp": unit.xp}))
	while unit.level < E.MAX_LEVEL and unit.xp >= xp_to_next(unit.level):
		unit.xp -= xp_to_next(unit.level)
		unit.level += 1
		events.push_back(GE.new(E.Ev.LEVEL_UP, {"id": unit.id, "level": unit.level}))


## XP needed to go from `level` to `level+1` (level N -> N+1 costs N*XP_PER_LEVEL).
static func xp_to_next(level: int) -> int:
	return level * E.XP_PER_LEVEL


## The 1-of-2 choice offered for a unit that just reached `level` (>=2). Returns the
## pair of ability ids the player picks between, or [capstone] / [] when the tree is
## exhausted. Pure data lookup over the archetype.
static func choice_for_level(db: ContentDB, arch_id: String, level: int) -> Array:
	var arch: Dictionary = db.archetype(arch_id)
	var tree: Array = arch.get("abilityTree", [])
	var tier: int = level - 2          # level 2 -> tier 0
	if tier >= 0 and tier < tree.size():
		var pair = tree[tier]
		if pair is Array:
			return pair.duplicate()
	# Past the tree: the capstone is the final pick.
	if tier == tree.size():
		var cap = arch.get("capstone", "")
		if cap != "":
			return [cap]
	return []


## Resolve a level-up pick: record `ability_id` into the unit's chosenAbilities, if it
## was one of the offered options. Returns true on a valid pick.
static func choose_ability(db: ContentDB, unit, ability_id: String, events: Array) -> bool:
	var options: Array = choice_for_level(db, unit.archetype_id, unit.level)
	if not options.has(ability_id):
		return false
	if not unit.chosen_abilities.has(ability_id):
		unit.chosen_abilities.append(ability_id)
	events.push_back(GE.new(E.Ev.ABILITY_PICKED, {"id": unit.id, "ability": ability_id, "level": unit.level}))
	return true
