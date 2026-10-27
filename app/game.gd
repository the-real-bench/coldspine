extends Node2D
## Playable single-car loop: TurnManager + CarView + OpsHUD + InputIntent wired into
## one operator session. Loads the §19 MVP scenario (flood_aquaria_01) from content;
## if that can't parse, falls back to the POC car layout. Mouse drives the two-tap
## commit (§17.6); the same intents are what touch/gamepad would feed.
##
## Controls (desktop):
##   Left-click a player unit  -> select
##   1..5 keys                 -> MOVE / SHOOT / SHOVE / SLAM / THROW
##   Left-click a tile/target  -> PREVIEW (dry-run ghost)
##   Enter / left-click again  -> COMMIT
##   Esc                       -> cancel preview / deselect
##   U                         -> undo last movement
##   Space                     -> end player phase (runs enemy + environment)
##   S                         -> toggle scanlines

const SimState = preload("res://core/sim_state.gd")
const SimEntity = preload("res://core/sim_entity.gd")
const IntRng = preload("res://core/int_rng.gd")
const E = preload("res://core/sim_enums.gd")
const TurnManager = preload("res://core/turn_manager.gd")
const EnemyAI = preload("res://ai/enemy_ai.gd")

const CarView = preload("res://render/car_view.gd")
const EventPlayer = preload("res://render/event_player.gd")
const PreviewGhost = preload("res://render/preview_ghost.gd")
const OpsHUD = preload("res://render/ops_hud.gd")
const Iso = preload("res://render/iso.gd")
const Pal = preload("res://render/palette.gd")

const CarLoader = preload("res://app/car_loader.gd")
const InputIntent = preload("res://app/input_intent.gd")

const VIEW_SIZE := Vector2(1280, 720)
const CAR_ID := "flood_aquaria_01"

var state
var turn
var ai
var view: CarView
var player: EventPlayer
var ghost: PreviewGhost
var hud: OpsHUD
var intent: InputIntent


func _ready() -> void:
	state = CarLoader.load_car(CAR_ID)
	var car_name := "AQUARIA HOLD"
	var car_tag := "CAR 08"
	if state == null:
		state = _build_poc_car()
		car_name = "COOLANT BAY"
		car_tag = "CAR 07"

	turn = TurnManager.new(state)
	turn.start()
	ai = EnemyAI.new()

	view = CarView.new()
	view.setup(state, VIEW_SIZE)
	ghost = PreviewGhost.new()
	view.preview = ghost
	add_child(view)

	hud = OpsHUD.new()
	add_child(hud)
	hud.set_camera_id(car_tag, car_name)

	player = EventPlayer.new(view, _is_headless())
	add_child(player)
	player.comms.connect(func(line): hud.push_comms(line))

	intent = InputIntent.new(turn)
	intent.preview_requested.connect(_on_preview_requested)
	intent.preview_cleared.connect(_on_preview_cleared)
	intent.committed.connect(_on_committed)
	intent.selection_changed.connect(_on_selection_changed)
	intent.rejected.connect(func(reason): hud.push_comms("! " + reason))

	hud.push_comms("> OPERATOR ONLINE. Feed locked: %s." % car_name)
	hud.push_comms("> Click a unit, pick an order, click a target, confirm.")
	_refresh_hud_for_selection()

	if _is_headless():
		# In headless we just prove the scene composes; no input loop.
		await get_tree().process_frame
		print("[game] headless compose OK — tokens=%d" % view.tokens.size())
		get_tree().quit()

func _is_headless() -> bool:
	return OS.has_feature("headless") or DisplayServer.get_name() == "headless"

# ============================ INPUT ============================================
func _unhandled_input(ev: InputEvent) -> void:
	if ev is InputEventMouseButton and ev.pressed and ev.button_index == MOUSE_BUTTON_LEFT:
		_on_click(view.to_local(ev.position))
	elif ev is InputEventKey and ev.pressed:
		_on_key(ev.keycode)

func _on_click(local_pos: Vector2) -> void:
	var cell := Iso.screen_to_tile(local_pos, view.origin)
	if not state.in_bounds(cell):
		return
	# If previewing and clicking the same target intent, treat as commit; otherwise
	# select a unit under the cursor, or point at a tile.
	var occ = state.occupant_at(cell)
	if occ != null and occ.is_unit and occ.faction == E.Faction.PLAYER and intent.mode == InputIntent.Mode.NONE:
		intent.select_unit(occ.id)
		return
	if intent.phase == InputIntent.Phase.PREVIEWING:
		intent.confirm()
	else:
		intent.point_tile(cell)

func _on_key(code: int) -> void:
	match code:
		KEY_1: intent.choose_action(InputIntent.Mode.MOVE)
		KEY_2: intent.choose_action(InputIntent.Mode.SHOOT)
		KEY_3: intent.choose_action(InputIntent.Mode.SHOVE)
		KEY_4: intent.choose_action(InputIntent.Mode.SLAM)
		KEY_5: intent.choose_action(InputIntent.Mode.THROW)
		KEY_ENTER, KEY_KP_ENTER: intent.confirm()
		KEY_ESCAPE: intent.cancel()
		KEY_U: if intent.undo(): _after_state_change("> UNDO movement.")
		KEY_SPACE: _end_player_phase()
		KEY_S: hud.toggle_scanlines()

# ============================ INTENT CALLBACKS =================================
func _on_selection_changed(unit_id: int) -> void:
	hud.push_comms("> Unit %d selected." % unit_id)
	_refresh_hud_for_selection()

func _on_preview_requested(kind: String, payload: Dictionary) -> void:
	ghost.clear()
	if kind == "physics":
		ghost.compute(state, payload.target, payload.dir, payload.force, Pal.FAC_PLAYER)
		hud.push_comms("> PREVIEW %s force %d — confirm to commit." % [InputIntent.mode_name(intent.mode), payload.force])
	elif kind == "shoot":
		hud.push_comms("> PREVIEW shot %d%% to hit — confirm to fire." % payload.get("chance", 0))
	elif kind == "move":
		hud.push_comms("> PREVIEW move %d tiles — confirm to walk." % payload.path.size())
	view.queue_redraw()

func _on_preview_cleared() -> void:
	ghost.clear()
	view.queue_redraw()

func _on_committed(events: Array) -> void:
	ghost.clear()
	# Adopt happened inside the command for physics; for move the state is already
	# mutated. Re-sync the visual tokens to the live state, then animate the events.
	view.sync_tokens()
	player.play(events)
	view.sync_tokens()
	view.queue_redraw()
	_refresh_hud_for_selection()
	_check_end()

# ============================ TURN FLOW =======================================
func _end_player_phase() -> void:
	hud.push_comms("> Ending player phase.")
	# advance PLAYER -> ENEMY
	var t1: Array = turn.advance_phase()
	player.play(t1)
	# enemy acts
	var e_ev: Array = ai.take_phase(turn)
	view.sync_tokens()
	player.play(e_ev)
	# ENEMY -> ENVIRONMENT (ticks world)
	var t2: Array = turn.advance_phase()
	player.play(t2)
	# ENVIRONMENT -> PLAYER (new round, AP refresh)
	var t3: Array = turn.advance_phase()
	player.play(t3)
	view.sync_tokens()
	view.queue_redraw()
	intent.reset()
	_refresh_hud_for_selection()
	_check_end()

func _after_state_change(msg: String) -> void:
	hud.push_comms(msg)
	view.sync_tokens()
	view.queue_redraw()
	_refresh_hud_for_selection()

func _check_end() -> void:
	var v: int = turn.check_victory()
	if v == 1:
		hud.push_comms("*** CAR CLEARED — all hostiles down. ***")
	elif v == 2:
		hud.push_comms("*** SQUAD LOST. ***")

func _refresh_hud_for_selection() -> void:
	if intent.selected_id >= 0 and turn.state.entities.has(intent.selected_id):
		hud.set_ap(turn.ap_for(intent.selected_id), E.AP_PER_TURN)
	else:
		hud.set_ap(0, E.AP_PER_TURN)

# ============================ POC FALLBACK CAR =================================
func _build_poc_car():
	var s := SimState.new()
	s.init_grid(10, 5)
	s.rng = IntRng.new(0xC01D5)
	_unit(s, 1, 2, E.Mass.HEAVY, 12, E.Faction.PLAYER, "bruiser")
	_unit(s, 3, 2, E.Mass.LIGHT, 4, E.Faction.ENEMY, "truncheon_guard")
	_unit(s, 4, 2, E.Mass.LIGHT, 4, E.Faction.ENEMY, "truncheon_guard")
	_unit(s, 7, 1, E.Mass.MEDIUM, 8, E.Faction.ENEMY, "enforcer")
	_obj(s, 5, 2, E.Mass.MEDIUM, 3, true, E.OnBreak.FLOOD, 3, "fish_tank_large")
	var j = _obj(s, 5, 3, E.Mass.ANCHORED, 99, false, E.OnBreak.NONE, 0, "junction_box")
	j.is_power_source = true
	s.tile(Vector2i(8, 1)).hazard = E.Hazard.GAP
	return s

func _unit(s, x, y, mass, hp, fac, nm):
	var e := SimEntity.new()
	e.is_unit = true; e.pos = Vector2i(x, y); e.mass = mass; e.hp = hp
	e.integrity = -1; e.faction = fac; e.name = nm
	s.add_entity(e)
	return e

func _obj(s, x, y, mass, integ, mv, ob, bp, nm):
	var o := SimEntity.new()
	o.is_unit = false; o.pos = Vector2i(x, y); o.mass = mass; o.integrity = integ
	o.movable = mv; o.on_break = ob; o.break_param = bp
	o.faction = E.Faction.OBJECT; o.hp = -1; o.name = nm
	s.add_entity(o)
	return o
