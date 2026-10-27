class_name ResolutionResult
extends RefCounted
## Output of PhysicsResolver.resolve_impulse(): the ordered event timeline plus
## the fully-resolved (cloned) state. Preview renders from these; commit adopts
## `state`. Because resolve runs purely on a clone, preview == commit always.

var events: Array          # Array[GameEvent], in resolution order
var state: SimState        # the resolved clone

func _init(ev: Array, st) -> void:
	events = ev
	state = st

func event_types() -> Array:
	var out := []
	for e in events:
		out.append(e.type)
	return out

func count_type(t: int) -> int:
	var n := 0
	for e in events:
		if e.type == t:
			n += 1
	return n
