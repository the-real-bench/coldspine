class_name CarInstance
extends RefCounted
## A concrete car ON the line (GDD §8.2 / §21 CarInstance). A CarTemplate
## (content/cars/*.json) is the static blueprint; a CarInstance is one rolled placement
## of it in a generated run: its rolled modifiers, its rolled reward, and the recon
## visibility the operator currently has of it. Pure data + serialization — RefCounted,
## integer-only, no SceneTree, no rng (the RunGenerator does the rolling and hands the
## results in; this object just carries them).
##
## The line is an Array[CarInstance]; `position` indexes it. NO branching — a list, not a
## graph (GDD §8.2 / D5). recon_state is a read the run layer maintains over the line.

const E = preload("res://core/sim_enums.gd")

var template_id: String = ""          # which CarTemplate (content/cars/<id>.json) this is
var name: String = ""                 # human label (from the template)
var car_type: int = E.CarType.COMBAT  # CarType enum (bridged from the template "type")
var section: int = E.Section.TAIL     # Section enum (1..5)
var modifiers: Array = []             # rolled modifier ids (subset of template.allowedModifiers)
var reward: Dictionary = {}           # rolled reward { table, kind, amount }
var threat_tags: Array = []           # the single-or-few threat tags shown in a PARTIAL recon
var recon_state: int = E.Recon.HIDDEN # HIDDEN / PARTIAL / FULL (the operator's current view)
var resolved: bool = false            # has this car been cleared / traded / skipped?
var is_captain: bool = false          # a Section Captain gate (caches car_type == CAPTAIN)
var is_engine: bool = false           # the Conductor's Chamber / finale (car_type == ENGINE)


func _init(p_template_id: String = "", p_type: int = E.CarType.COMBAT, p_section: int = E.Section.TAIL) -> void:
	template_id = p_template_id
	car_type = p_type
	section = p_section
	is_captain = (car_type == E.CarType.CAPTAIN)
	is_engine = (car_type == E.CarType.ENGINE)


## Is this a "combat-ish" car (a fight blocks advancement)? combat / flood / captain /
## engine. Non-combat cars (upgrade/bourgeois/recruit/event/rest/shop) resolve by choice.
func is_combat() -> bool:
	return car_type in [E.CarType.COMBAT, E.CarType.FLOOD, E.CarType.CAPTAIN, E.CarType.ENGINE]


## What a PARTIAL recon exposes (GDD §8.2): the car type + a single threat tag, no full
## enemy detail. FULL exposes everything; HIDDEN exposes nothing. The render/UI layer
## reads this; here it is just the data contract.
func partial_view() -> Dictionary:
	return {
		"type": car_type,
		"section": section,
		"threat": (threat_tags[0] if not threat_tags.is_empty() else ""),
	}


# --- serialization (the RunState round-trips through these) ---------------------
func to_dict() -> Dictionary:
	return {
		"template_id": template_id,
		"name": name,
		"car_type": car_type,
		"section": section,
		"modifiers": modifiers.duplicate(),
		"reward": reward.duplicate(true),
		"threat_tags": threat_tags.duplicate(),
		"recon_state": recon_state,
		"resolved": resolved,
	}


static func from_dict(d: Dictionary) -> CarInstance:
	var c: CarInstance = new()
	c.template_id = String(d.get("template_id", ""))
	c.car_type = int(d.get("car_type", E.CarType.COMBAT))
	c.section = int(d.get("section", E.Section.TAIL))
	c.name = String(d.get("name", ""))
	c.modifiers = (d.get("modifiers", []) as Array).duplicate()
	c.reward = (d.get("reward", {}) as Dictionary).duplicate(true)
	# JSON text round-trips numbers as floats; the reward amount is an integer in core
	# (no floats — invariant #1). Coerce it back so the record is integer-faithful whether
	# it came from an in-memory dict or parsed JSON.
	if c.reward.has("amount"):
		c.reward["amount"] = int(c.reward["amount"])
	c.threat_tags = (d.get("threat_tags", []) as Array).duplicate()
	c.recon_state = int(d.get("recon_state", E.Recon.HIDDEN))
	c.resolved = bool(d.get("resolved", false))
	c.is_captain = (c.car_type == E.CarType.CAPTAIN)
	c.is_engine = (c.car_type == E.CarType.ENGINE)
	return c
