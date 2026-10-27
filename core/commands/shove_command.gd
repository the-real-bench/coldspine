class_name ShoveCommand
extends Command
## A physics action: apply an impulse to a target entity and commit the resolved
## clone. Wraps PhysicsResolver.resolve_impulse(state, id, dir, force, false) then
## state.adopt(result.state), returning the resolver's own event timeline.
## 1 AP, does NOT end the turn — physics actions never end the turn (§5.2).
##
## Slam and Throw are thin variants:
##   - SlamCommand  : same shape, higher force (SLAM_FORCE).
##   - ThrowCommand : shoves a *grabbed* light object/body along a vector.

const Physics = preload("res://core/physics_resolver.gd")

var target_id: int = -1
var dir: Vector2i = Vector2i.ZERO
var force: int = E.SHOVE_FORCE

func _init(p_actor_id: int = -1, p_target_id: int = -1, p_dir: Vector2i = Vector2i.ZERO, p_force: int = E.SHOVE_FORCE) -> void:
	super(p_actor_id)
	target_id = p_target_id
	dir = p_dir
	force = p_force
	ap_cost = 1
	ends_turn = false

func validate(state, _turn) -> Dictionary:
	var a = state.entities.get(actor_id)
	if a == null or not a.alive:
		return _fail("actor missing/dead")
	var t = state.entities.get(target_id)
	if t == null or not t.alive:
		return _fail("target missing")
	if not t.movable:
		return _fail("target is anchored / immovable")
	if abs(dir.x) + abs(dir.y) != 1:
		return _fail("shove dir must be one orthogonal step")
	# Must be adjacent to the target to shove it (melee-range physics action).
	if _manhattan(a.pos, t.pos) != 1:
		return _fail("target not adjacent")
	# And shoving it AWAY from us (the contact direction).
	if t.pos - a.pos != dir:
		return _fail("must shove the target directly away from the actor")
	if force <= 0:
		return _fail("non-positive force")
	return _ok()

func execute(state, _turn) -> Array:
	var result = Physics.resolve_impulse(state, target_id, dir, force, false)
	state.adopt(result.state)
	return result.events
