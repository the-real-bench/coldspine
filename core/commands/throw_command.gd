class_name ThrowCommand
extends ShoveCommand
## Throw a *grabbed* light object or body along a vector. Unlike Shove, the actor
## holds the thrown entity, so it may be flung in any orthogonal direction (not
## only directly away), but the thrown thing must be adjacent and Light/movable.
## 1 AP, does NOT end the turn (§5.2 physics action). Wraps the resolver like Shove.

func _init(p_actor_id: int = -1, p_target_id: int = -1, p_dir: Vector2i = Vector2i.ZERO, p_force: int = E.THROW_FORCE) -> void:
	super(p_actor_id, p_target_id, p_dir, p_force)

func validate(state, _turn) -> Dictionary:
	var a = state.entities.get(actor_id)
	if a == null or not a.alive:
		return _fail("actor missing/dead")
	var t = state.entities.get(target_id)
	if t == null or not t.alive:
		return _fail("thrown entity missing")
	if not t.movable:
		return _fail("cannot throw an anchored entity")
	if t.mass != E.Mass.LIGHT:
		return _fail("can only throw Light entities")
	if abs(dir.x) + abs(dir.y) != 1:
		return _fail("throw dir must be one orthogonal step")
	if _manhattan(a.pos, t.pos) != 1:
		return _fail("must be grabbing an adjacent entity")
	if force <= 0:
		return _fail("non-positive force")
	return _ok()
