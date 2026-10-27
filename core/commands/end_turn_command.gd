class_name EndTurnCommand
extends Command
## End the acting unit's turn voluntarily (forfeit remaining AP). 0 AP, ends turn.

func _init(p_actor_id: int = -1) -> void:
	super(p_actor_id)
	ap_cost = 0
	ends_turn = true

func validate(_state, _turn) -> Dictionary:
	return _ok()

func execute(state, turn) -> Array:
	if turn != null:
		turn.end_unit(actor_id)
	return []
