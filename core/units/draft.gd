class_name Draft
extends RefCounted
## The Draft (Sub-Spec C1 / GDD §7.1) — the first thing a run does: vet volunteers over
## the comms net before the breach. Up to DRAFT_ROUNDS rounds; each round offers
## DRAFT_CANDIDATES (3) candidates rolled from the seeded PRNG. Per round: Take one (adds
## to the cell, advance) or Decline (advance). Stop anytime. End with 1..3 starters.
## NO candidate repeats — every candidate shown (taken or passed) is removed from the
## pool. Drafting fewer sets a meta-currency multiplier (draftPayoutMult) and leaves open
## slots for in-run recruitment. Fully reproducible from (seed, picks).
##
## All rolls draw from `state.rng` (the seeded IntRng). Integer-only, no SceneTree.

const E = preload("res://core/sim_enums.gd")
const GE = preload("res://core/game_event.gd")
const ContentDB = preload("res://core/units/content_db.gd")
const UnitInstance = preload("res://core/units/unit_instance.gd")

var db: ContentDB
var rng                              # IntRng (state.rng) — the single deterministic source
var rounds_total: int = E.DRAFT_ROUNDS
var round_idx: int = 0               # current round [0..rounds_total)
var current_choices: Array = []      # the DRAFT_CANDIDATES on offer this round (UnitInstance)
var shown_and_removed: Array = []    # names burned (taken or passed) — no repeats
var picks: Array = []                # UnitInstance taken (the starting cell)
var finished: bool = false
var draft_payout_mult: int = E.DRAFT_PAYOUT_X3   # ×100; finalized on stop
var _next_id: int = 1                # roster id allocator for drafted/recruited units
var _name_counter: int = 0
# W3-5: the unlocked starting-class pool (archetype ids). EMPTY = every archetype is draftable
# (the byte-stable headless/auto default). A non-empty list GATES candidate rolls to only those
# classes, so a class locked behind a meta unlock (saboteur/firebrand) never appears in the draft
# until it is bought. Set by RunController from MenuHandoff.unlocked_class_ids (Unlocks.unlocked_
# class_ids: baseline bruiser/marksman/steward + owned). Deterministic — the smaller pool just
# re-indexes the same rng draw; it never introduces a new rng source.
var allowed_archetypes: Array = []


func _init(p_db: ContentDB, p_rng) -> void:
	db = p_db
	rng = p_rng


## Begin the draft: deal the first round of candidates.
func start() -> Array:
	round_idx = 0
	current_choices = _deal_round()
	return [GE.new(E.Ev.DRAFT_OFFER, {"round": round_idx, "count": current_choices.size()})]


## Deal DRAFT_CANDIDATES fresh, non-repeating candidates for the current round, applying
## a value-banding pass so a round poses tradeoffs (strong-archetype+bad-trait next to
## humble-archetype+good-trait) rather than flat all-good / all-bad (C1.3).
func _deal_round() -> Array:
	var out: Array = []
	# Value bands to spread across the 3 cards (deterministic order).
	var bands := ["strong_arch_weak_trait", "humble_arch_strong_trait", "balanced"]
	for i in range(E.DRAFT_CANDIDATES):
		var band: String = bands[i % bands.size()]
		out.append(_roll_candidate(band))
	return out


## Take the candidate at `idx` from the current round; advance to the next round (or
## finish if the cap is hit / rounds run out).
func take(idx: int) -> Array:
	if finished or idx < 0 or idx >= current_choices.size():
		return []
	var evs: Array = []
	var cand: UnitInstance = current_choices[idx]
	picks.append(cand)
	shown_and_removed.append(cand.name)
	evs.push_back(GE.new(E.Ev.DRAFT_TAKE, {"name": cand.name, "archetype": cand.archetype_id, "round": round_idx}))
	_advance(evs)
	return evs


## Decline this round (take none); advance.
func decline() -> Array:
	var evs: Array = []
	for c in current_choices:
		shown_and_removed.append(c.name)
	evs.push_back(GE.new(E.Ev.DRAFT_DECLINE, {"round": round_idx}))
	_advance(evs)
	return evs


## Stop drafting now with whatever was taken (1..3). Finalizes draftPayoutMult.
func stop() -> Array:
	return _finalize()


func _advance(evs: Array) -> void:
	# Burn any un-taken candidates this round so nothing repeats.
	for c in current_choices:
		if not shown_and_removed.has(c.name):
			shown_and_removed.append(c.name)
	round_idx += 1
	if picks.size() >= E.DRAFT_MAX_STARTERS or round_idx >= rounds_total:
		var fin := _finalize()
		for e in fin:
			evs.push_back(e)
		return
	current_choices = _deal_round()
	evs.push_back(GE.new(E.Ev.DRAFT_OFFER, {"round": round_idx, "count": current_choices.size()}))


func _finalize() -> Array:
	if finished:
		return []
	finished = true
	current_choices = []
	# Payout multiplier (×100) by how few you started with (C1.2): 3->100, 2->125, 1->160.
	match picks.size():
		3: draft_payout_mult = E.DRAFT_PAYOUT_X3
		2: draft_payout_mult = E.DRAFT_PAYOUT_X2
		1: draft_payout_mult = E.DRAFT_PAYOUT_X1
		_: draft_payout_mult = E.DRAFT_PAYOUT_X3
	# Assign roster ids in pick order (stable).
	for u in picks:
		u.id = _next_id
		_next_id += 1
	return [GE.new(E.Ev.DRAFT_DONE, {"starters": picks.size(), "payoutMult": draft_payout_mult})]


# --- candidate generation (deterministic; draws only from rng) -----------------
func _roll_candidate(band: String) -> UnitInstance:
	var arch_ids: Array = _draftable_archetypes()
	var arch: String = arch_ids[rng.randi_range(0, arch_ids.size() - 1)]
	# Roll 1-2 traits honoring the band's value slant + archetype affinity. Hidden traits
	# are NOT rolled into the visible draft pool here (betrayer enters via recruitment by
	# default, C3.5 — keeps drafted starters honest).
	var pool: Array = db.traits_for_archetype(arch, false)
	var picked: Array = []
	if not pool.is_empty():
		picked = _pick_traits_for_band(pool, band)
	# Generate a unique name (deterministic counter; no rng so the same picks reproduce).
	var nm := _gen_name(arch)
	var u := UnitInstance.from_archetype(db, arch, picked, nm, -1)
	return u


## The archetype ids a candidate may roll (W3-5): the full sorted set, gated to `allowed_archetypes`
## when that pool is set. Falls back to the full set if the gate would empty the pool (never deal an
## empty draft). Stable order preserved so a fixed (seed, pool) reproduces identical rolls.
func _draftable_archetypes() -> Array:
	var all: Array = db.archetype_ids()
	if allowed_archetypes.is_empty():
		return all
	var out: Array = []
	for a in all:
		if allowed_archetypes.has(a):
			out.append(a)
	return out if not out.is_empty() else all


func _pick_traits_for_band(pool: Array, band: String) -> Array:
	# Partition the pool by polarity for value banding.
	var good: Array = []
	var bad: Array = []
	var mixed: Array = []
	for tid in pool:
		var pol: String = db.trait_def(tid).get("polarity", "positive")
		if pol == "positive":
			good.append(tid)
		elif pol == "negative":
			bad.append(tid)
		else:
			mixed.append(tid)
	var out: Array = []
	match band:
		"humble_arch_strong_trait":
			if not good.is_empty():
				out.append(good[rng.randi_range(0, good.size() - 1)])
		"strong_arch_weak_trait":
			if not bad.is_empty():
				out.append(bad[rng.randi_range(0, bad.size() - 1)])
			elif not mixed.is_empty():
				out.append(mixed[rng.randi_range(0, mixed.size() - 1)])
		_:
			if not pool.is_empty():
				out.append(pool[rng.randi_range(0, pool.size() - 1)])
	# A 1-in-3 second trait, no duplicate.
	if rng.randi_range(0, 2) == 0 and pool.size() > 1:
		for _try in range(4):
			var t2: String = pool[rng.randi_range(0, pool.size() - 1)]
			if not out.has(t2):
				out.append(t2)
				break
	return out


func _gen_name(arch: String) -> String:
	_name_counter += 1
	return "%s_%02d" % [arch.capitalize(), _name_counter]
