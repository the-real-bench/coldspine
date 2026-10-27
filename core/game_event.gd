class_name GameEvent
extends RefCounted
## A flat, ordered event the renderer replays as an animation timeline (Sub-Spec A9).
## The ORDER of the event list IS the timeline — never reorder it.

var type: int
var data: Dictionary

func _init(t: int, d: Dictionary = {}) -> void:
	type = t
	data = d

func _to_string() -> String:
	return "EV(%d, %s)" % [type, str(data)]
