class_name Recruitment
## In-run recruitment (GDD §8.4 / Sub-Spec C4) — the UNCONTROLLED counterpart to the
## Draft. A sympathetic citizen joins as a rolled archetype + 1-2 traits, with hidden
## traits possible and only partially shown. Recruits fill open starter slots first, then
## count toward the soft cap (4) / hard cap (5). This is the cost of drafting fewer (C1.2).
##
## The BETRAYER (Conductor's Kin, C3.5) enters the squad almost entirely through this
## path: each recruit has a BETRAYER_DENSITY_PCT chance of secretly carrying the hidden
## loyalty trait. That density constant is OWNER-FLAGGED and must not be tuned here.
##
## Deterministic: every roll draws from `rng` (state.rng). Integer-only, no SceneTree.

const E = preload("res://core/sim_enums.gd")
const GE = preload("res://core/game_event.gd")
const ContentDB = preload("res://core/units/content_db.gd")
const UnitInstance = preload("res://core/units/unit_instance.gd")


## Roll a recruit. `squad` is the current Array[UnitInstance]; refuses past the hard cap.
## Returns { ok, unit, events }. The unit may secretly carry Conductor's Kin (hidden).
static func roll_recruit(db: ContentDB, rng, squad: Array, next_id: int) -> Dictionary:
	var events: Array = []
	if squad.size() >= E.SQUAD_HARD_CAP:
		return {"ok": false, "reason": "squad at hard cap", "unit": null, "events": events}
	var arch_ids: Array = db.archetype_ids()
	var arch: String = arch_ids[rng.randi_range(0, arch_ids.size() - 1)]
	# 1-2 visible traits from the affinity pool.
	var pool: Array = db.traits_for_archetype(arch, false)
	var picked: Array = []
	if not pool.is_empty():
		picked.append(pool[rng.randi_range(0, pool.size() - 1)])
		if rng.randi_range(0, 1) == 0 and pool.size() > 1:
			for _try in range(4):
				var t2: String = pool[rng.randi_range(0, pool.size() - 1)]
				if not picked.has(t2):
					picked.append(t2)
					break
	# OWNER-FLAGGED betrayer roll: a low-density chance this recruit is a plant (C3.5).
	# DO NOT change BETRAYER_DENSITY_PCT without sign-off.
	var is_betrayer: bool = rng.chance(E.BETRAYER_DENSITY_PCT)
	if is_betrayer and not picked.has("conductors_kin"):
		picked.append("conductors_kin")
	var nm := "%s_R%02d" % [arch.capitalize(), next_id]
	var u := UnitInstance.from_archetype(db, arch, picked, nm, next_id)
	u.faction = E.Faction.PLAYER
	squad.append(u)
	events.push_back(GE.new(E.Ev.RECRUIT_JOIN, {
		"id": u.id, "name": u.name, "archetype": arch,
		"revealedTraits": u.revealed_traits.duplicate(),
		"squadSize": squad.size(),
		# NOTE: hidden_betrayer intentionally NOT surfaced in the event payload — the
		# player learns it only via a Saboteur scan / vetting / the story beat.
	}))
	return {"ok": true, "unit": u, "events": events}


## At soft cap? (a recruitment beyond this is a harder decision; still allowed to hard cap.)
static func at_soft_cap(squad: Array) -> bool:
	return squad.size() >= E.SQUAD_SOFT_CAP
