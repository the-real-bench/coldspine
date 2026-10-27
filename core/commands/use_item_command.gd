class_name UseItemCommand
extends Command
## Routes a data-defined COMBAT item (a consumable or an active gadget) through the command
## layer so USING an item validates -> applies -> emits like every other action (ARCHITECTURE.md
## invariant #4). The item's effects resolve through the SAME AbilitySystem effect handlers
## abilities use (heal / spawn_hazard / status / pull / deploy_power_source / explosion), so a
## bought consumable and a level-up ability share one deterministic execution path.
##
## Only ACTIVE items take this path — those with slot `consumable` (one-shot, spent on use) or
## `gadget` (reusable field kit, costs only AP). Armor/weapons are PASSIVE equipment wired onto
## the body at spawn (UnitInstance._apply_gear_to_entity) and are never routed here.
##
## Targeting kinds mirror AbilityDef (Sub-Spec C / §11):
##   enemy  -> target_id is a hostile unit within range
##   ally   -> target_id is a friendly unit within range (medkit)
##   tile   -> target_pos is a tile within range (grenades / smoke / breaching charge)
##   direction -> dir is one orthogonal step
##   self   -> no target
## Integer-only, RefCounted, ZERO SceneTree deps.

const AbilitySystem = preload("res://core/ability_system.gd")

## Item slots a human may ACTIVELY use in combat (everything else is passive equipment).
const USABLE_SLOTS := {"consumable": true, "gadget": true}

var item: Dictionary = {}          # the resolved ItemDef (content/items/*.json)
var item_id: String = ""           # the gear id carried on SimEntity.gear
var target_id: int = -1
var target_pos: Vector2i = Vector2i.ZERO
var dir: Vector2i = Vector2i.ZERO


func _init(p_actor_id: int = -1, p_item: Dictionary = {}, p_item_id: String = "", p_target_id: int = -1, p_target_pos: Vector2i = Vector2i.ZERO, p_dir: Vector2i = Vector2i.ZERO) -> void:
	super(p_actor_id)
	item = p_item
	item_id = p_item_id
	target_id = p_target_id
	target_pos = p_target_pos
	dir = p_dir
	ap_cost = int(item.get("apCost", 1))
	ends_turn = bool(item.get("endsTurn", false))


func validate(state, _turn) -> Dictionary:
	var a = state.entities.get(actor_id)
	if a == null or not a.alive or not a.is_unit:
		return _fail("actor missing/dead")
	if item.is_empty():
		return _fail("no item def")
	if not USABLE_SLOTS.has(String(item.get("slot", ""))):
		return _fail("that item is passive equipment, not usable in combat")
	if not a.gear.has(item_id):
		return _fail("unit is not carrying that item")
	var targeting: String = item.get("targeting", "self")
	var rng_tiles: int = int(item.get("range", 0))
	match targeting:
		"enemy":
			var t = state.entities.get(target_id)
			if t == null or not t.alive or not t.is_unit:
				return _fail("target missing/dead")
			if t.faction == a.faction:
				return _fail("enemy-target item cannot hit own faction")
			if _manhattan(a.pos, t.pos) > rng_tiles:
				return _fail("target out of item range")
		"ally":
			var t2 = state.entities.get(target_id)
			if t2 == null or not t2.is_unit:
				return _fail("ally target missing")
			if t2.faction != a.faction:
				return _fail("ally-target item needs a friendly target")
			if _manhattan(a.pos, t2.pos) > rng_tiles:
				return _fail("ally out of item range")
		"tile":
			if not state.in_bounds(target_pos):
				return _fail("target tile out of bounds")
			if _manhattan(a.pos, target_pos) > rng_tiles:
				return _fail("tile out of item range")
		"direction":
			if abs(dir.x) + abs(dir.y) != 1:
				return _fail("direction item needs one orthogonal step")
		_:
			pass   # self items always validate
	return _ok()


func execute(state, turn) -> Array:
	var events: Array = []
	var a = state.entities.get(actor_id)
	if a == null:
		return events
	var slot: String = item.get("slot", "")
	events.push_back(GE.new(E.Ev.ITEM_USED, {
		"item": item_id, "actor": actor_id, "slot": slot,
	}))
	var ctx := {
		"actor": actor_id, "target_id": target_id,
		"target_pos": target_pos, "dir": dir, "turn": turn,
	}
	# The item's effects run through the shared AbilitySystem handlers (emit_use=false — the
	# ITEM_USED marker above already tags this stream; no duplicate ABILITY_USE).
	var evs: Array = AbilitySystem.execute(state, item, ctx, false)
	for ev in evs:
		events.push_back(ev)
	# A one-shot consumable is spent from the carrier's gear; a reusable gadget is not.
	if slot == "consumable":
		a.gear.erase(item_id)
	return events
