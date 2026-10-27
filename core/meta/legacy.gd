class_name Legacy
## LEGACY / MEMORIAL (GDD §7.4 + §14) — "loss becomes continuity." Permadeath is SACRED: nobody
## comes back. What a future run may inherit is a fallen hero's ITEM or TRAIT — the gear they
## carried or the temperament they embodied — carried forward and applied to a LIVING unit at run
## start. The person stays dead; their legacy is one object or one trait.
##
## FLOW:
##   1. On permadeath the run records a memorial entry in RunState.memorial (BleedoutSystem does
##      this with {id, instance_id, name, archetype}; the run/UI may enrich it with the unit's
##      traits + inventory at death). enshrine() harvests one such entry into the PROFILE memorial
##      so it survives the run that produced it.
##   2. Between runs the player picks ONE enshrined hero. inherit(profile, hero_id) returns the
##      single {item|trait} payload to apply — chosen deterministically: a carried item if the
##      hero had one, else a trait. NO UnitInstance is ever produced (no resurrection).
##   3. The run applies that payload to a drafted/living unit at start (apply_to_unit) — ONE
##      Legacy per run. The hero is marked `inherited` so the same legacy isn't double-spent.
##
## RefCounted statics, NO SceneTree, NO rng. Pure data — meta lives outside the integer sim.

const E = preload("res://core/sim_enums.gd")


## Enshrine a fallen-hero memorial dict (from RunState.memorial) into the persistent profile
## Memorial so it survives across runs. Accepts the BleedoutSystem shape {id, instance_id, name,
## archetype} and any enrichment (traits[], inventory[]). De-dupes on the cross-run legacy_id so
## the same fall isn't enshrined twice. Returns the stored legacy entry (or {} if invalid).
##   stored entry := { legacy_id, name, archetype, traits[], inventory[], inherited:false }
static func enshrine(profile, hero: Dictionary) -> Dictionary:
	if profile == null or hero == null or typeof(hero) != TYPE_DICTIONARY:
		return {}
	var legacy_id := _legacy_id(profile, hero)
	# Already enshrined? return the existing entry untouched.
	for m in profile.memorial:
		if String(m.get("legacy_id", "")) == legacy_id:
			return m
	var entry := {
		"legacy_id": legacy_id,
		"name": String(hero.get("name", "Unknown")),
		"archetype": String(hero.get("archetype", hero.get("archetype_id", ""))),
		"traits": (hero.get("traits", []) as Array).duplicate(),
		"inventory": (hero.get("inventory", []) as Array).duplicate(),
		"inherited": false,
	}
	profile.memorial.append(entry)
	profile.stats["fallen"] = int(profile.stats.get("fallen", 0)) + 1
	return entry


## Harvest EVERY fallen hero on a finished run into the profile Memorial (the meta layer reaping
## the run's losses). Returns the number newly enshrined.
static func harvest_run(profile, run_state) -> int:
	if profile == null or run_state == null or not ("memorial" in run_state):
		return 0
	var before: int = profile.memorial.size()
	for hero in run_state.memorial:
		if typeof(hero) == TYPE_DICTIONARY:
			enshrine(profile, hero)
	return profile.memorial.size() - before


## The enshrined heroes still AVAILABLE to inherit from (not yet spent). Stable order.
static func available(profile) -> Array:
	var out: Array = []
	if profile == null:
		return out
	for m in profile.memorial:
		if not bool(m.get("inherited", false)):
			out.append(m)
	return out


## Resolve the single Legacy PAYLOAD a chosen hero passes forward — WITHOUT resurrecting them.
## Returns {kind:"item", id:<gear id>} if the hero carried gear, else {kind:"trait", id:<trait
## id>} if they had a trait, else {} (nothing to inherit). Deterministic: first inventory item,
## else first NON-HIDDEN trait (a betrayer's hidden Conductor's Kin is never inheritable — loss
## doesn't pass on treachery). Does NOT mutate the profile (call mark_inherited to spend it).
static func inherit(profile, hero_id: String) -> Dictionary:
	var hero := _find(profile, hero_id)
	if hero.is_empty():
		return {}
	var inv: Array = (hero.get("inventory", []) as Array)
	if not inv.is_empty():
		return {"kind": "item", "id": String(inv[0]), "from": String(hero.get("name", ""))}
	for tid in hero.get("traits", []):
		if String(tid) == "conductors_kin":
			continue   # treachery is not a legacy — never inheritable
		return {"kind": "trait", "id": String(tid), "from": String(hero.get("name", ""))}
	return {}


## Spend a Legacy: mark the chosen hero `inherited` so it can't be re-used (ONE Legacy per run).
## Returns true if it flipped a still-available hero.
static func mark_inherited(profile, hero_id: String) -> bool:
	if profile == null:
		return false
	for m in profile.memorial:
		if String(m.get("legacy_id", "")) == hero_id and not bool(m.get("inherited", false)):
			m["inherited"] = true
			return true
	return false


## Apply a resolved Legacy payload to a LIVING UnitInstance at run start — the only place a
## legacy touches a run. An "item" payload is added to the unit's inventory; a "trait" payload is
## added to its traits (and revealed). It NEVER creates a unit and NEVER revives the dead — the
## fallen hero is gone; only the object/trait moves on. Returns true if it applied something.
static func apply_to_unit(unit, payload: Dictionary) -> bool:
	if unit == null or payload == null or payload.is_empty():
		return false
	var pid := String(payload.get("id", ""))
	if pid == "":
		return false
	match String(payload.get("kind", "")):
		"item":
			if not unit.inventory.has(pid):
				unit.inventory.append(pid)
			return true
		"trait":
			if not unit.traits.has(pid):
				unit.traits.append(pid)
			if not unit.revealed_traits.has(pid):
				unit.revealed_traits.append(pid)
			return true
		_:
			return false


# --- internals -----------------------------------------------------------------
## A stable cross-run id for a memorial entry. Prefer an explicit legacy_id; else compose from
## the hero's persistent instance_id (+ name) so the same fall maps to the same legacy across a
## save/load. Names are stable per run (the Draft's deterministic counter).
static func _legacy_id(profile, hero: Dictionary) -> String:
	if hero.has("legacy_id"):
		return String(hero["legacy_id"])
	var iid := int(hero.get("instance_id", hero.get("id", -1)))
	var nm := String(hero.get("name", "?"))
	if iid >= 0:
		return "%s#%d" % [nm, iid]
	# No instance id — fall back to name + an ordinal so two same-named falls stay distinct.
	var ordinal: int = 0
	if profile != null:
		ordinal = profile.memorial.size()
	return "%s@%d" % [nm, ordinal]


static func _find(profile, hero_id: String) -> Dictionary:
	if profile == null:
		return {}
	for m in profile.memorial:
		if String(m.get("legacy_id", "")) == hero_id:
			return m
	return {}
