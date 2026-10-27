class_name RunGenerator
## Builds the single linear line of a run (GDD §8.2 / §17.2 `generate_run`). NO branching:
## the output is an Array[CarInstance] — a list, not a graph. The line runs across the 5
## Sections in order (Tail -> Third -> Second -> First -> Engine), ~3-5 functional cars per
## section drawn from a car-type deck, a Section Captain gating each section break, and the
## Conductor's Chamber (engine) as the final car.
##
## Everything — car selection, modifier rolls, reward rolls, threat-tag picks — draws from
## ONE dedicated IntRng seeded off the run seed, so the SAME (seed, unlocked_content)
## reproduces an identical line with identical modifier/reward rolls (GDD §17.4). Stable,
## sorted iteration throughout. Integer-only, RefCounted/static, no SceneTree.
##
## Reads the static CarTemplates from content/cars/*.json (the data the content engineer
## authored) — adding a car = adding a file, not editing this generator (invariant #3).

const E = preload("res://core/sim_enums.gd")
const IntRng = preload("res://core/int_rng.gd")
const CarInstance = preload("res://core/run/car_instance.gd")
const Unlocks = preload("res://core/meta/unlocks.gd")   # catalog_car_ids — the ownership-gated set

const CARS_DIR := "res://content/cars/"
const ITEMS_DIR := "res://content/items/"

# A salt mixed into the line seed so the run generator's stream is independent of any
# other seeded stream sharing the run seed (combat to-hit, the Draft, etc.).
const LINE_SEED_SALT := 0x5CA1AB1E

# The non-combat "amenity" deck a section can roll between its required combat cars. The
# combat backbone (combat/flood) is guaranteed; these add texture. Stable order.
const AMENITY_TYPES := [
	E.CarType.UPGRADE, E.CarType.BOURGEOIS, E.CarType.RECRUIT,
	E.CarType.EVENT, E.CarType.REST, E.CarType.SHOP,
]

# Threat-tag vocabulary for PARTIAL recon (GDD §8.2 "a single threat/hazard tag"). Picked
# deterministically per car from its type + rolled modifiers.
const TYPE_THREAT := {
	E.CarType.COMBAT: "guards",
	E.CarType.FLOOD: "flood",
	E.CarType.CAPTAIN: "elite",
	E.CarType.ENGINE: "engine_core",
	E.CarType.BOURGEOIS: "civilians",
	E.CarType.RECRUIT: "unknown_ally",
	E.CarType.EVENT: "uncertain",
	E.CarType.REST: "safe",
	E.CarType.SHOP: "merchant",
	E.CarType.UPGRADE: "workshop",
}


## Generate the full line. `seed` is the run seed; `unlocked_content` is the OWNED set of
## purchasable car ids (additive — see _is_unlocked); pass {} / null for "everything
## authored is available". Returns Array[CarInstance], Tail..Engine, captain at each break,
## engine last.
static func generate_run(seed: int, unlocked_content = null) -> Array:
	var rng := IntRng.new((seed ^ LINE_SEED_SALT) & 0xFFFFFFFF)
	var templates := _load_templates()
	var decks := _index_by_type_and_section(templates, unlocked_content)
	var line: Array = []

	# Sections 1..4: functional cars + a Section Captain gate. Section 5 = the Engine only.
	for sec in E.SECTION_ORDER:
		if sec == E.Section.ENGINE:
			var eng := _make_instance(rng, decks, E.CarType.ENGINE, sec)
			if eng != null:
				line.append(eng)
			continue
		var count: int = rng.randi_range(E.CARS_PER_SECTION_MIN, E.CARS_PER_SECTION_MAX)
		for i in range(count):
			var ctype: int = _roll_car_type(rng, decks, sec, i, count)
			var inst := _make_instance(rng, decks, ctype, sec)
			if inst != null:
				line.append(inst)
		# Section break: the Captain gate.
		var cap := _make_instance(rng, decks, E.CarType.CAPTAIN, sec)
		if cap != null:
			line.append(cap)

	return line


# --- car-type selection --------------------------------------------------------
## Choose the type for functional car `i` of `count` in `sec`. The first car of every
## section is a guaranteed fight (combat or flood) so the section opens with resistance;
## the rest mix combat backbone with amenity cars. Deterministic from rng.
static func _roll_car_type(rng, decks: Dictionary, sec: int, i: int, count: int) -> int:
	var have_flood := _deck_has(decks, E.CarType.FLOOD, sec)
	# The opener is always a fight.
	if i == 0:
		if have_flood and rng.randi_range(0, 2) == 0:
			return E.CarType.FLOOD
		return E.CarType.COMBAT
	# Otherwise: ~50% another fight, ~50% an amenity that exists for this section.
	if rng.randi_range(0, 1) == 0:
		if have_flood and rng.randi_range(0, 2) == 0:
			return E.CarType.FLOOD
		return E.CarType.COMBAT
	var avail: Array = []
	for t in AMENITY_TYPES:
		if _deck_has(decks, t, sec):
			avail.append(t)
	if avail.is_empty():
		return E.CarType.COMBAT
	return avail[rng.randi_range(0, avail.size() - 1)]


# --- instance construction (rolls modifiers + reward + threat tags) -------------
static func _make_instance(rng, decks: Dictionary, ctype: int, sec: int) -> CarInstance:
	var tmpl := _pick_template(rng, decks, ctype, sec)
	if tmpl.is_empty():
		return null
	var inst := CarInstance.new(String(tmpl.get("id", "")), ctype, sec)
	inst.name = String(tmpl.get("name", inst.template_id))
	inst.modifiers = _roll_modifiers(rng, tmpl)
	inst.reward = _roll_reward(rng, tmpl)
	inst.threat_tags = _roll_threat_tags(tmpl, ctype, inst.modifiers)
	inst.recon_state = E.Recon.HIDDEN
	return inst


## Pick a template of `ctype` for `sec`. Prefer one authored for this exact section; fall
## back to any of that type. Deterministic (sorted candidate ids, rng index).
static func _pick_template(rng, decks: Dictionary, ctype: int, sec: int) -> Dictionary:
	var by_sec: Dictionary = decks.get(ctype, {})
	var cands: Array = (by_sec.get(sec, []) as Array)
	if cands.is_empty():
		# Fall back to any section's template of this type (stable, sorted merge).
		var merged: Array = []
		var secs: Array = by_sec.keys()
		secs.sort()
		for s in secs:
			for t in by_sec[s]:
				merged.append(t)
		cands = merged
	if cands.is_empty():
		return {}
	# cands are template dicts already sorted by id (see _index). Pick deterministically.
	return cands[rng.randi_range(0, cands.size() - 1)]


## Roll 0..2 modifiers from the template's allowedModifiers (GDD §8.4). Deterministic;
## no duplicates; stable input order (allowedModifiers is authored, kept as-is then the
## rng selects indices). The Engine car rolls none (authored finale, allowedModifiers []).
static func _roll_modifiers(rng, tmpl: Dictionary) -> Array:
	var allowed: Array = (tmpl.get("allowedModifiers", []) as Array)
	if allowed.is_empty():
		return []
	# How many to roll: 0, 1, or (if 2+ available) up to 2.
	var n: int = rng.randi_range(0, min(2, allowed.size()))
	if n <= 0:
		return []
	# Selection without replacement over a copy, indices from rng.
	var pool: Array = allowed.duplicate()
	var out: Array = []
	for _k in range(n):
		if pool.is_empty():
			break
		var idx: int = rng.randi_range(0, pool.size() - 1)
		out.append(String(pool[idx]))
		pool.remove_at(idx)
	out.sort()   # stable stored order
	return out


## Roll a concrete reward from the template's rewardTable id (GDD §11 pending → symbolic).
## Deterministic {table, kind, amount}. Different table strings give different streams via
## a salt folded from the table id, so two cars with the same table reward consistently.
static func _roll_reward(rng, tmpl: Dictionary) -> Dictionary:
	var table: String = String(tmpl.get("rewardTable", ""))
	if table == "":
		return {}
	# W3-2: an EQUIPMENT reward table (any table id containing "equip") drops a real weapon/armor id
	# the run auto-equips onto a squad member at collect (RunState.collect_reward). The id is picked
	# deterministically from the authored item pool via the SAME seeded generator rng — no randi, no
	# wall-clock — so a fixed (seed, unlocked_content) reproduces the exact drop. This is the reliable
	# per-run acquisition path a shopless line previously lacked (shop-only left it with zero gear).
	if table.findn("equip") >= 0:
		var pool: Array = _equipment_pool()
		if pool.is_empty():
			return {}
		# Consume EXACTLY the same one rng word a scrip band would (REWARD_SCRIP_MIN..MAX), then derive
		# the item index from it — so swapping a car's reward table to equipment does NOT shift the shared
		# generation stream (downstream picks stay byte-identical; only THIS car's reward changes).
		var roll: int = rng.randi_range(E.REWARD_SCRIP_MIN, E.REWARD_SCRIP_MAX)
		var item: String = String(pool[roll % pool.size()])
		return {"table": table, "kind": "equipment", "amount": 1, "item": item}
	# Kind by table flavor; amount by band. Stable mapping, rng for the amount.
	var kind := "scrip"
	if table.findn("rest") >= 0 or table.findn("supply") >= 0:
		kind = "supplies"
	elif table.findn("upgrade") >= 0 or table.findn("event") >= 0:
		kind = "tools"
	elif table.findn("recruit") >= 0:
		kind = "recruit"
	var amount := 0
	match kind:
		"supplies": amount = rng.randi_range(E.REWARD_SUPPLY_MIN, E.REWARD_SUPPLY_MAX)
		"tools":    amount = rng.randi_range(E.REWARD_TOOL_MIN, E.REWARD_TOOL_MAX)
		"recruit":  amount = 1
		_:          amount = rng.randi_range(E.REWARD_SCRIP_MIN, E.REWARD_SCRIP_MAX)
	return {"table": table, "kind": kind, "amount": amount}


## W3-2 EQUIPMENT drop pool: every authored WEAPON + ARMOR id, sorted (so the rng index is stable
## regardless of file/JSON order). Consumables/gadgets are NOT drop rewards — they ride the shop rail.
## Loaded from the item JSONs so adding an item = adding data (invariant #3). Integer/RefCounted, no rng.
static func _equipment_pool() -> Array:
	var out: Array = []
	for fn in ["weapons.json", "armor.json"]:
		var d = _read_json(ITEMS_DIR + fn)
		if d != null and d is Dictionary and d.has("items"):
			for it in d["items"]:
				if it is Dictionary and it.has("id"):
					var slot := String(it.get("slot", ""))
					if slot == "weapon" or slot == "armor":
						out.append(String(it["id"]))
	out.sort()
	return out


## The threat tags a PARTIAL recon exposes (GDD §8.2): the type's headline threat, plus a
## hazard hint if a hazard-seeding modifier rolled. Deterministic (no rng — derived).
static func _roll_threat_tags(tmpl: Dictionary, ctype: int, mods: Array) -> Array:
	var tags: Array = [String(TYPE_THREAT.get(ctype, "unknown"))]
	for m in mods:
		var ms := String(m)
		if ms in ["overpressure", "gas_leak", "furnace_row", "live_rails", "steam_vents", "laser_sec_grid", "open_roof", "lockdown"]:
			if not tags.has(ms):
				tags.append(ms)
			break   # one extra hazard tag is enough for a partial silhouette
	return tags


# --- template loading + indexing -----------------------------------------------
## Load every content/cars/*.json into Array[Dictionary], sorted by id (stable order so
## the generator's pick indices are reproducible regardless of filesystem ordering).
static func _load_templates() -> Array:
	var out: Array = []
	var dir := DirAccess.open(CARS_DIR)
	if dir == null:
		return out
	dir.list_dir_begin()
	var names: Array = []
	var fn := dir.get_next()
	while fn != "":
		if not dir.current_is_dir() and fn.ends_with(".json"):
			names.append(fn)
		fn = dir.get_next()
	dir.list_dir_end()
	names.sort()
	for n in names:
		var d = _read_json(CARS_DIR + n)
		if d != null and d is Dictionary and d.has("id") and d.has("type"):
			out.append(d)
	return out


## decks[CarType][Section] -> Array[template dict], each inner array sorted by id.
## `unlocked` (Array or Dictionary of allowed ids, or null) gates eligibility.
static func _index_by_type_and_section(templates: Array, unlocked) -> Dictionary:
	var decks: Dictionary = {}
	for t in templates:
		var tid := String(t.get("id", ""))
		if not _is_unlocked(tid, unlocked):
			continue
		var ctype: int = int(E.CAR_TYPE_NAMES.get(String(t.get("type", "combat")), E.CarType.COMBAT))
		var sec: int = int(t.get("section", E.Section.TAIL))
		if not decks.has(ctype):
			decks[ctype] = {}
		if not decks[ctype].has(sec):
			decks[ctype][sec] = []
		decks[ctype][sec].append(t)
	# Sort each leaf by id for deterministic indexing.
	for ctype in decks:
		for sec in decks[ctype]:
			(decks[ctype][sec] as Array).sort_custom(func(a, b): return String(a.get("id","")) < String(b.get("id","")))
	return decks


## ADDITIVE unlock gating (W1-3): `unlocked` is the OWNED set of purchasable car ids, not a
## strict allow-list. Only templates sold in the Unlocks catalog (kind=="car") gate on
## ownership — every non-catalog template (base combat cars, the captains, the engine) is
## ALWAYS admitted, so owning one setpiece can never collapse the line to copies of it.
## null / empty keep the historical "everything authored" behavior (fresh profile, tests).
static func _is_unlocked(tid: String, unlocked) -> bool:
	if unlocked == null:
		return true
	if unlocked is Array or unlocked is Dictionary:
		if unlocked.is_empty():
			return true
		if not Unlocks.catalog_car_ids().has(tid):
			return true   # base content — never ownership-gated
		return unlocked.has(tid)
	return true


static func _deck_has(decks: Dictionary, ctype: int, sec: int) -> bool:
	if not decks.has(ctype):
		return false
	var by_sec: Dictionary = decks[ctype]
	if by_sec.has(sec) and not (by_sec[sec] as Array).is_empty():
		return true
	# any-section fallback counts as "available" for selection.
	for s in by_sec:
		if not (by_sec[s] as Array).is_empty():
			return true
	return false


static func _read_json(path: String):
	if not FileAccess.file_exists(path):
		return null
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return null
	var txt := f.get_as_text()
	f.close()
	return JSON.parse_string(txt)
