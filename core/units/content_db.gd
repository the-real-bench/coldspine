class_name ContentDB
## Small data loader for the squad/progression layer (Sub-Spec C). Reads the authored
## JSON in res://content (archetypes / abilities / traits) into typed Dictionaries so
## the engine LOADS and EXECUTES data — adding a unit/ability/trait is a new file, not
## new code (ARCHITECTURE.md invariant #3). Engine-agnostic, RefCounted, no SceneTree.
##
## Mirrors CarLoader's _read_json style. Caches per-instance so repeated lookups in a
## run don't re-hit the disk. Tests construct one and reuse it.

const E = preload("res://core/sim_enums.gd")

const ARCH_DIR  := "res://content/archetypes/"
const ABIL_DIR  := "res://content/abilities/"
const TRAITS    := "res://content/traits/traits.json"
const ENEMY_ROSTER   := "res://content/enemies/roster.json"
const ENEMY_CAPTAINS := "res://content/enemies/captains.json"
const ITEMS_DIR := "res://content/items/"

const ARCH_IDS := ["bruiser", "marksman", "saboteur", "steward", "firebrand"]
const ABIL_FILES := [
	"bruiser_abilities", "marksman_abilities", "saboteur_abilities",
	"steward_abilities", "firebrand_abilities",
]
const ITEM_FILES := ["armor", "gadgets", "weapons"]

const MASS_MAP := {"light": E.Mass.LIGHT, "medium": E.Mass.MEDIUM, "heavy": E.Mass.HEAVY, "anchored": E.Mass.ANCHORED}

var archetypes: Dictionary = {}   # id -> ArchetypeDef dict
var abilities: Dictionary = {}    # id -> AbilityDef dict
var traits: Dictionary = {}       # id -> TraitDef dict
var enemies: Dictionary = {}      # id -> EnemyDef dict (roster + captains, Phase 5)
var items: Dictionary = {}        # id -> ItemDef dict (armor/gadgets/weapons, §11)
var _loaded: bool = false


func _init() -> void:
	load_all()


func load_all() -> void:
	if _loaded:
		return
	for aid in ARCH_IDS:
		var d = _read_json(ARCH_DIR + aid + ".json")
		if d != null and d.has("id"):
			archetypes[d["id"]] = d
	for f in ABIL_FILES:
		var d = _read_json(ABIL_DIR + f + ".json")
		if d != null:
			for key in d.keys():
				var ab = d[key]
				if typeof(ab) == TYPE_DICTIONARY and ab.has("id"):
					abilities[ab["id"]] = ab
	var t = _read_json(TRAITS)
	if t != null and t.has("traits"):
		for tr in t["traits"]:
			if typeof(tr) == TYPE_DICTIONARY and tr.has("id"):
				traits[tr["id"]] = tr
	# Phase 5: the enemy roster + the Section Captains (one merged id->def map).
	for ep in [ENEMY_ROSTER, ENEMY_CAPTAINS]:
		var ed = _read_json(ep)
		if ed != null and ed.has("enemies"):
			for en in ed["enemies"]:
				if typeof(en) == TYPE_DICTIONARY and en.has("id"):
					enemies[en["id"]] = en
	# Progression-real batch: items (armor/gadgets/weapons) so gear + shop stock are real.
	for f in ITEM_FILES:
		var idd = _read_json(ITEMS_DIR + f + ".json")
		if idd != null and idd.has("items"):
			for it in idd["items"]:
				if typeof(it) == TYPE_DICTIONARY and it.has("id"):
					items[it["id"]] = it
	_loaded = true


# --- lookups -------------------------------------------------------------------
func archetype(id: String) -> Dictionary:
	return archetypes.get(id, {})

func ability(id: String) -> Dictionary:
	return abilities.get(id, {})

func trait_def(id: String) -> Dictionary:
	return traits.get(id, {})

func enemy_def(id: String) -> Dictionary:
	return enemies.get(id, {})

func item(id: String) -> Dictionary:
	return items.get(id, {})

func item_ids() -> Array:
	var ids: Array = items.keys()
	ids.sort()
	return ids

func enemy_ids() -> Array:
	var ids: Array = enemies.keys()
	ids.sort()
	return ids


## Phase 5 — write an EnemyDef's Phase-5 fields (aiProfile, physicsTrait, captain key)
## onto a built SimEntity so the engine LOADS data, not hardcodes it (invariant #3).
## Idempotent; safe to call after the loader places the bare body. Captains route through
## CaptainSystem.setup() so their gate state is initialized. Returns the entity.
const CaptainSystem = preload("res://core/captain_system.gd")
static func apply_enemy_def(entity, def: Dictionary):
	if def == null or def.is_empty():
		return entity
	# Progression-real batch: authored stats feed real combat math (accuracy -> to-hit,
	# move -> Move range). -1 = unset keeps the E.BASE_ACCURACY / E.MOVE_RANGE fallback.
	var stats: Dictionary = def.get("stats", {})
	if stats.has("accuracy"):
		entity.accuracy = int(stats["accuracy"])
	if stats.has("move") and int(stats["move"]) > 0:
		entity.move_range = int(stats["move"])
	entity.ai_profile = int(E.AI_PROFILE_NAMES.get(def.get("aiProfile", "melee_rush"), E.AIProfile.MELEE_RUSH))
	var pt = def.get("physicsTrait", null)
	if pt != null and E.PHYS_TRAIT_NAMES.has(pt):
		entity.phys_trait = int(E.PHYS_TRAIT_NAMES[pt])
	# A Riot Shield's frontal block must face the ADVANCING SQUAD (W2-3). The squad charges
	# from the tail (-x) and shoves enemies toward +x, so a canonical frontal shove has
	# dir=(+1,0); the resolver blocks when dir == facing, hence facing=(+1,0). (The old
	# (-1,0) inverted it — head-on shoves folded the shield, only rear shoves were blocked.)
	# The AI re-faces it toward the nearest player each activation so it tracks a flank.
	if entity.phys_trait == E.PhysTrait.BLOCKS_FRONTAL_SHOVE:
		entity.facing = Vector2i(1, 0)
	# Section Captains carry a physicsKey gate.
	var key = def.get("physicsKey", "")
	if typeof(key) == TYPE_STRING and key != "":
		CaptainSystem.setup(entity, key)
	return entity

func archetype_ids() -> Array:
	var ids: Array = archetypes.keys()
	ids.sort()   # stable, deterministic iteration
	return ids

func trait_ids() -> Array:
	var ids: Array = traits.keys()
	ids.sort()
	return ids

## Map an archetype's "light/medium/heavy" mass string to the integer Mass enum.
static func mass_to_int(s: String) -> int:
	return int(MASS_MAP.get(s, E.Mass.MEDIUM))

## Trait ids that prefer/allow this archetype (affinity), in sorted order. A trait
## with no archetypeAffinity is allowed on anyone.
func traits_for_archetype(arch_id: String, include_hidden: bool) -> Array:
	var out: Array = []
	for tid in trait_ids():
		var td: Dictionary = traits[tid]
		if td.get("hidden", false) and not include_hidden:
			continue
		var aff = td.get("archetypeAffinity", null)
		if aff == null or (aff is Array and aff.has(arch_id)) or (aff is Array and aff.is_empty()):
			out.append(tid)
	return out


# --- json ----------------------------------------------------------------------
static func _read_json(path: String):
	if not FileAccess.file_exists(path):
		return null
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return null
	var txt := f.get_as_text()
	f.close()
	return JSON.parse_string(txt)
