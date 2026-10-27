class_name OverwatchCommand
extends Command
## Arm a reaction (GDD §5.5 / Phase 2). Spends the actor's REMAINING AP and ends the
## turn; the unit now watches its fire lane. During the ENEMY phase, the first hostile
## that enters its line of fire (range + LoS) triggers one reaction shot through the
## normal Shoot path. Emits OVERWATCH_SET on arm; the shot events fire on trigger.
##
## Cost: takes all remaining AP (>=1) and ends the turn. A unit with 0 AP cannot arm.

func _init(p_actor_id: int = -1) -> void:
	super(p_actor_id)
	ap_cost = 1            # at least 1 AP; the turn manager ends the turn (forfeits the rest)
	ends_turn = true

func validate(state, turn) -> Dictionary:
	var a = state.entities.get(actor_id)
	if a == null or not a.alive or not a.is_unit:
		return _fail("actor missing/dead")
	if turn != null and turn.ap_for(actor_id) < 1:
		return _fail("no AP to arm overwatch")
	# A unit too impaired to shoot can't meaningfully overwatch.
	if a.has_status(E.S_FROZEN) or a.has_status(E.S_PRONE):
		return _fail("cannot overwatch while frozen/prone")
	return _ok()

func execute(state, _turn) -> Array:
	var events: Array = []
	var a = state.entities.get(actor_id)
	if a == null:
		return events
	a.overwatch = true
	a.overwatch_used = false
	events.push_back(GE.new(E.Ev.OVERWATCH_SET, {"id": actor_id}))
	return events
