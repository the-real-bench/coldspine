class_name SlamCommand
extends ShoveCommand
## Slam = a heavier Shove (higher force). Thin variant: same validate/execute,
## just a bigger default impulse. 1 AP, does NOT end the turn (§5.2 physics).

func _init(p_actor_id: int = -1, p_target_id: int = -1, p_dir: Vector2i = Vector2i.ZERO, p_force: int = -1) -> void:
	var f: int = p_force if p_force > 0 else E.SLAM_FORCE
	super(p_actor_id, p_target_id, p_dir, f)
