class_name Command
extends RefCounted
## Base class for every player/AI action (GDD §17.2 command pattern).
## Contract: validate(state, turn) -> {ok:bool, reason:String}
##           execute(state, turn) -> Array[GameEvent]   (mutates `state` in place)
## Subclasses set `ap_cost` and `ends_turn`. INTEGER-ONLY; ZERO SceneTree deps.
##
## `turn` is a TurnManager (may be null in pure-physics unit tests that only need
## the world mutated). Commands never spend AP themselves — the caller (the turn
## loop) checks affordability via the TurnManager and spends on success.

const E = preload("res://core/sim_enums.gd")
const GE = preload("res://core/game_event.gd")

var actor_id: int = -1        # the unit issuing the action
var ap_cost: int = 1          # AP this action costs
var ends_turn: bool = false   # does committing this action end the actor's turn?

func _init(p_actor_id: int = -1) -> void:
	actor_id = p_actor_id

## Validate against the live state. Override in subclasses. Default: actor exists & alive.
func validate(state, _turn) -> Dictionary:
	var e = state.entities.get(actor_id)
	if e == null or not e.alive:
		return _fail("actor missing or dead")
	return _ok()

## Apply the action, mutating `state`, returning the ordered event list it emitted.
## Override in subclasses.
func execute(_state, _turn) -> Array:
	return []

# --- small helpers shared by subclasses ---
func _ok() -> Dictionary:
	return {"ok": true, "reason": ""}

func _fail(reason: String) -> Dictionary:
	return {"ok": false, "reason": reason}

static func _manhattan(a: Vector2i, b: Vector2i) -> int:
	return abs(a.x - b.x) + abs(a.y - b.y)
