class_name Unlocks
## The UNLOCK CATALOG + the meta-currency rails (GDD §14). Data-light by design: a flat table
## of {id, cost, kind, name} entries naming everything a player can permanently buy with
## meta-currency — new starting CLASSES, expanded RECRUIT pools, new GEAR in the loot pool,
## new CAR types/set-pieces, TAIL upgrades (a stronger starting baseline), and NARRATIVE beats.
##
## CONTRACT WITH THE RUN LAYER (the whole point of `kind`):
##   - kind == "car"  unlock ids ARE content/cars/<id>.json template ids. Passing the unlocked
##     car ids to RunGenerator.generate_run(seed, ids) gates the line ADDITIVELY: only ids sold
##     in this catalog (kind=="car" — see catalog_car_ids()) gate on ownership; every template
##     NOT in the catalog (base cars, captains, the engine) is always admitted. Use
##     `unlocked_car_ids(profile)` to get the owned subset.
##   - kind == "class" ids are archetype ids; the Draft/recruit pools widen as they unlock
##     (the squad layer reads the unlocked class set).
##   - kind == "gear" / "recruit_pool" / "tail" / "narrative" are symbolic ids the run/economy/
##     UI layers read; they live in the same flat unlocked_content list.
##
## RefCounted statics, NO SceneTree, NO rng. Meta lives outside the integer sim, so currency
## math here is plain int but never written back into RunState.

const E = preload("res://core/sim_enums.gd")

# Kind tags (stable strings; the run layer branches on these).
const KIND_CLASS    := "class"
const KIND_GEAR     := "gear"
const KIND_CAR      := "car"
const KIND_POOL     := "recruit_pool"
const KIND_TAIL     := "tail"
const KIND_NARRATIVE := "narrative"

# The catalog. Each entry: { id, cost (meta-currency), kind, name }. First-pass costs — these
# are tuning values, not load-bearing. The `id`s for kind=="car" are REAL content/cars ids so a
# purchase flows straight into generate_run; class ids are REAL archetype ids.
const CATALOG := [
	# --- new starting CLASSES (archetype ids; firebrand/saboteur gated behind meta) ---
	{"id": "saboteur",  "cost": 40,  "kind": KIND_CLASS, "name": "Class: Saboteur"},
	{"id": "firebrand", "cost": 60,  "kind": KIND_CLASS, "name": "Class: Firebrand"},
	# --- new GEAR the squad starts a run carrying (ids ARE real content/items/*.json ItemDefs so
	#     the run layer grants a usable starting item; W3-6). Previously breach_charge/ablative_vest/
	#     grapple_line — phantom ids that matched no ItemDef and had zero consumers. ---
	{"id": "breaching_charge", "cost": 25, "kind": KIND_GEAR, "name": "Gear: Breaching Charge"},
	{"id": "ablative_harness", "cost": 30, "kind": KIND_GEAR, "name": "Gear: Ablative Harness"},
	{"id": "grapple",          "cost": 35, "kind": KIND_GEAR, "name": "Gear: Grapple"},
	# --- new CARS / set-pieces in the deck (ids == content/cars/<id>.json) ---
	{"id": "setpiece_ice_rink",      "cost": 20, "kind": KIND_CAR, "name": "Car: Ice Rink"},
	{"id": "setpiece_spa",           "cost": 30, "kind": KIND_CAR, "name": "Car: Spa"},
	{"id": "setpiece_hedge_maze",    "cost": 45, "kind": KIND_CAR, "name": "Car: Hedge Maze"},
	{"id": "setpiece_aquarium",      "cost": 35, "kind": KIND_CAR, "name": "Car: Aquarium"},
	# --- expanded RECRUIT pools: TRIMMED (W3-6). pool_engineers/pool_medics had no runtime consumer
	#     and a faithful "widen the recruit archetype pool" needs core/units/recruitment.gd (a
	#     different lane); the two entries overlapped the CLASS unlocks (an engineer == Saboteur, a
	#     medic == Steward). Selling inert goods is worse than a shorter list — removed pending an
	#     owner call on whether recruit-pool widening is distinct from class unlocks (report G3). ---
	# --- TAIL upgrades (a stronger starting baseline) ---
	{"id": "tail_extra_scrip",   "cost": 30, "kind": KIND_TAIL, "name": "Tail Upgrade: Cache (+scrip)"},
	{"id": "tail_extra_supplies","cost": 30, "kind": KIND_TAIL, "name": "Tail Upgrade: Stores (+supplies)"},
	# --- NARRATIVE unlocks ---
	{"id": "narrative_conductor_log", "cost": 15, "kind": KIND_NARRATIVE, "name": "Intel: Conductor's Log"},
]

# Meta-currency payout (GDD §14: earned per run, WIN OR LOSE). A win pays the full base; a loss
# still pays a consolation so progress always advances ("roguelite, not roguelike"). Scaled by
# the run's draft_payout_mult (×100 — fewer starters drafted pays more, §7.1), plus a per-car
# clearance bonus so a deeper run earns more even on a loss. Integer-only.
const PAYOUT_WIN_BASE  := 50
const PAYOUT_LOSS_BASE := 20
const PAYOUT_PER_CAR   := 3    # meta-currency per car cleared this run


# --- catalog lookups -----------------------------------------------------------
## The catalog entry for an id, or {} if unknown.
static func entry(id: String) -> Dictionary:
	for e in CATALOG:
		if String(e.get("id", "")) == id:
			return e
	return {}


static func cost(id: String) -> int:
	return int(entry(id).get("cost", 0))


static func kind(id: String) -> String:
	return String(entry(id).get("kind", ""))


## Catalog ids in stable order (for the Unlocks menu listing).
static func catalog_ids() -> Array:
	var out: Array = []
	for e in CATALOG:
		out.append(String(e.get("id", "")))
	return out


## The catalog's kind=="car" template ids — the ONLY car templates that gate on ownership.
## The generator admits every template NOT in this list unconditionally (base combat cars,
## captains, the engine), so buying a car unlock WIDENS the deck instead of collapsing the
## line to the owned setpieces. Stable, sorted.
static func catalog_car_ids() -> Array:
	var out: Array = []
	for e in CATALOG:
		if String(e.get("kind", "")) == KIND_CAR:
			out.append(String(e.get("id", "")))
	out.sort()
	return out


# --- the rails -----------------------------------------------------------------
## Award meta-currency for a finished run — WIN OR LOSE (§14). Pays a base by outcome, a
## per-car clearance bonus, all scaled by the run's draft_payout_mult (×100). Adds it to the
## profile's meta_currency and bumps the lifetime stats. Returns the amount awarded.
## `won` decides the base; a loss still pays the consolation + per-car bonus. Pure integer math.
static func award_meta_currency(profile, run_state, won: bool) -> int:
	var base: int = PAYOUT_WIN_BASE if won else PAYOUT_LOSS_BASE
	var cleared: int = _cars_cleared(run_state)
	var raw: int = base + cleared * PAYOUT_PER_CAR
	var mult: int = 100
	if run_state != null and "draft_payout_mult" in run_state:
		mult = int(run_state.draft_payout_mult)
	var award: int = (raw * mult) / 100   # integer division — the ×100 mult divides cleanly enough
	if award < 0:
		award = 0
	if profile != null:
		profile.meta_currency = int(profile.meta_currency) + award
		profile.stats["runs"] = int(profile.stats.get("runs", 0)) + 1
		if won:
			profile.stats["wins"] = int(profile.stats.get("wins", 0)) + 1
	return award


## Purchase an unlock by id: spend meta-currency (REFUSES to overspend — returns false, no
## mutation) and add the id to the profile's unlocked_content (the same flat list the run layer
## consumes). Idempotent: re-buying an already-owned id is a no-op success (no double charge).
## Returns true on a successful (or already-owned) unlock, false if unknown or unaffordable.
static func purchase(profile, id: String) -> bool:
	if profile == null:
		return false
	var e := entry(id)
	if e.is_empty():
		return false
	if profile.unlocked_content.has(id):
		return true   # already owned — no charge, success
	var c: int = int(e.get("cost", 0))
	if int(profile.meta_currency) < c:
		return false  # cannot afford — no mutation
	profile.meta_currency = int(profile.meta_currency) - c
	profile.unlocked_content.append(id)
	return true


# --- run-layer bridges ---------------------------------------------------------
## The unlocked CAR template ids (kind=="car"). Pass this to RunGenerator.generate_run /
## RunState.new_run as the OWNED set: gating is additive (only catalog_car_ids() gate on
## ownership; base cars/captains/engine always pass). NOTE: an EMPTY result means "no car
## unlocks bought" — callers keeping the historical full-deck behavior for a fresh profile
## should pass `null` (the generator treats [] and null identically today).
static func unlocked_car_ids(profile) -> Array:
	var out: Array = []
	if profile == null:
		return out
	for id in profile.unlocked_content:
		if kind(String(id)) == KIND_CAR:
			out.append(String(id))
	out.sort()
	return out


## The unlocked starting CLASS ids (kind=="class"), plus the always-available baseline classes
## (bruiser/marksman/steward are free from the start). The Draft/recruit pools read this to
## widen the candidate archetypes. Stable, sorted, de-duplicated.
const BASELINE_CLASSES := ["bruiser", "marksman", "steward"]
static func unlocked_class_ids(profile) -> Array:
	var set: Dictionary = {}
	for c in BASELINE_CLASSES:
		set[c] = true
	if profile != null:
		for id in profile.unlocked_content:
			if kind(String(id)) == KIND_CLASS:
				set[String(id)] = true
	var out: Array = set.keys()
	out.sort()
	return out


# --- internals -----------------------------------------------------------------
## How many cars the run cleared (resolved). Counts resolved CarInstances on the line; falls
## back to `position` if the line isn't present. Drives the per-car payout bonus.
static func _cars_cleared(run_state) -> int:
	if run_state == null:
		return 0
	var n: int = 0
	if "line" in run_state and run_state.line is Array and not run_state.line.is_empty():
		for c in run_state.line:
			if c != null and ("resolved" in c) and c.resolved:
				n += 1
		return n
	if "position" in run_state:
		return max(0, int(run_state.position))
	return 0
