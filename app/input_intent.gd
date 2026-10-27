class_name InputIntent
extends RefCounted
## The §17.6 input-abstraction layer. Touch, mouse, and gamepad all funnel into the
## SAME small set of intents so one code path serves every platform:
##   - select_unit(id)           : pick the acting unit
##   - choose_action(mode)       : MOVE / SHOOT / SHOVE / SLAM / THROW
##   - point_tile(cell)          : tap a target tile/unit -> builds + shows a PREVIEW
##   - confirm()                 : commit the previewed action (two-tap commit, §16)
##   - cancel()                  : drop the preview / deselect
##   - undo()                    : undo the last *movement* (movement only, §16)
##
## This object owns no rendering; it emits signals the game layer reacts to. It holds
## a snapshot of pre-move state so movement (and ONLY movement) is undoable pre-commit.
## Committed attacks/physics are never undoable (§16).

const E = preload("res://core/sim_enums.gd")
const MoveCommand = preload("res://core/commands/move_command.gd")
const ShootCommand = preload("res://core/commands/shoot_command.gd")
const ShoveCommand = preload("res://core/commands/shove_command.gd")
const SlamCommand = preload("res://core/commands/slam_command.gd")
const ThrowCommand = preload("res://core/commands/throw_command.gd")
const AbilityCommand = preload("res://core/commands/ability_command.gd")
const UseItemCommand = preload("res://core/commands/use_item_command.gd")

enum Mode { NONE, MOVE, SHOOT, SHOVE, SLAM, THROW, STABILIZE, ABILITY, USE_ITEM }

## §7.4 ally-aid: the manual STABILIZE verb. A synthetic ability def (owned by no archetype —
## any standing player unit can stabilize an adjacent Downed comrade, exactly as the AUTO triage
## _stabilize_downed_allies does for free) routed through the command layer so it validates ->
## applies -> emits like every other action (invariant #4). 1 AP, does NOT end the turn.
const STABILIZE_ABILITY := {
	"id": "stabilize", "targeting": "ally", "range": 1, "apCost": 1, "endsTurn": false,
	"effects": [{"kind": "stabilize"}],
}
enum Phase { IDLE, UNIT_SELECTED, PREVIEWING }

signal selection_changed(unit_id: int)
signal mode_changed(mode: int)
signal preview_requested(kind: String, payload: Dictionary)   # game runs the dry-run
signal preview_cleared()
signal committed(events: Array)
signal rejected(reason: String)

var turn                          # TurnManager
var phase: int = Phase.IDLE
var mode: int = Mode.NONE
var selected_id: int = -1

# Pending previewed action (built on point_tile, consumed on confirm).
var _pending_kind: String = ""    # "move" | "physics" | "ability" | "item"
var _pending_cmd = null           # a Command ready to try_command()
var _pending_payload: Dictionary = {}

# The active-ability / consumable currently ARMED (Mode.ABILITY / Mode.USE_ITEM). The operator
# picks WHICH from the HUD popup; point_tile then targets it per the def's targeting kind. Cleared
# whenever the mode changes away.
var _armed_ability: Dictionary = {}
var _armed_item: Dictionary = {}
var _armed_item_id: String = ""

# Movement undo: snapshot of the selected unit's pos before the last committed move.
var _undo_stack: Array = []       # Array[{id, pos}]


func _init(p_turn = null) -> void:
	turn = p_turn

func reset() -> void:
	phase = Phase.IDLE
	mode = Mode.NONE
	selected_id = -1
	_clear_armed()
	_clear_pending()
	_undo_stack.clear()

# ============================ INTENTS ==========================================
func select_unit(id: int) -> bool:
	var e = turn.state.entities.get(id)
	if e == null or not e.alive or not e.is_unit or e.faction != E.Faction.PLAYER:
		emit_signal("rejected", "not a selectable player unit")
		return false
	selected_id = id
	phase = Phase.UNIT_SELECTED
	mode = Mode.NONE
	_clear_armed()
	_clear_pending()
	emit_signal("selection_changed", id)
	return true

func choose_action(p_mode: int) -> void:
	if selected_id < 0:
		emit_signal("rejected", "select a unit first")
		return
	mode = p_mode
	phase = Phase.UNIT_SELECTED
	_clear_armed()
	_clear_pending()
	emit_signal("mode_changed", mode)


## Arm a specific ACTIVE ability (Mode.ABILITY). The operator chose WHICH from the HUD popup; the
## next point_tile targets it per the def's targeting kind, then confirm() commits an AbilityCommand
## (validate->apply->emit, exactly like STABILIZE). A `self` ability has no tile to point, so it is
## prepared immediately here and a confirm() commits it straight away. Returns true if armed.
func arm_ability(ability_def: Dictionary) -> bool:
	if selected_id < 0:
		emit_signal("rejected", "select a unit first")
		return false
	if ability_def.is_empty():
		emit_signal("rejected", "no ability to arm")
		return false
	mode = Mode.ABILITY
	phase = Phase.UNIT_SELECTED
	_clear_pending()
	_armed_ability = ability_def
	_armed_item = {}
	_armed_item_id = ""
	emit_signal("mode_changed", mode)
	if String(ability_def.get("targeting", "self")) == "self":
		var actor = turn.state.entities.get(selected_id)
		if actor != null:
			_prepare_ability(actor, actor.pos)
	return true


## Arm a specific COMBAT item (Mode.USE_ITEM) — a consumable or an active gadget the unit carries.
## Same two-tap flow as arm_ability; a `self` item is prepared immediately. Returns true if armed.
func arm_item(item_def: Dictionary, item_id: String) -> bool:
	if selected_id < 0:
		emit_signal("rejected", "select a unit first")
		return false
	if item_def.is_empty():
		emit_signal("rejected", "no item to arm")
		return false
	mode = Mode.USE_ITEM
	phase = Phase.UNIT_SELECTED
	_clear_pending()
	_armed_item = item_def
	_armed_item_id = item_id
	_armed_ability = {}
	emit_signal("mode_changed", mode)
	if String(item_def.get("targeting", "self")) == "self":
		var actor = turn.state.entities.get(selected_id)
		if actor != null:
			_prepare_item(actor, actor.pos)
	return true

## Point at a target cell (or the unit on it). Builds the pending command and asks the
## game to render its preview (the dry-run). Does NOT commit — that's confirm().
func point_tile(cell: Vector2i) -> void:
	if selected_id < 0 or mode == Mode.NONE:
		emit_signal("rejected", "no unit/action chosen")
		return
	var actor = turn.state.entities.get(selected_id)
	if actor == null:
		return
	match mode:
		Mode.MOVE:
			_prepare_move(actor, cell)
		Mode.SHOOT:
			_prepare_shoot(actor, cell)
		Mode.SHOVE, Mode.SLAM, Mode.THROW:
			_prepare_physics(actor, cell)
		Mode.STABILIZE:
			_prepare_stabilize(actor, cell)
		Mode.ABILITY:
			_prepare_ability(actor, cell)
		Mode.USE_ITEM:
			_prepare_item(actor, cell)
		_:
			emit_signal("rejected", "unknown mode")

func confirm() -> bool:
	if phase != Phase.PREVIEWING or _pending_cmd == null:
		emit_signal("rejected", "nothing to confirm")
		return false
	# record movement undo BEFORE the move mutates the unit
	if _pending_kind == "move":
		var a = turn.state.entities.get(selected_id)
		if a != null:
			_undo_stack.append({"id": selected_id, "pos": a.pos})
	var res: Dictionary = turn.try_command(_pending_cmd)
	if not res.ok:
		emit_signal("rejected", res.reason)
		if _pending_kind == "move" and not _undo_stack.is_empty():
			_undo_stack.pop_back()
		return false
	# physics/attacks are non-undoable; only movement stays on the undo stack
	if _pending_kind != "move":
		_undo_stack.clear()
	var ev: Array = res.events
	phase = Phase.UNIT_SELECTED
	_clear_pending()
	emit_signal("committed", ev)
	return true

func cancel() -> void:
	_clear_pending()
	if phase == Phase.PREVIEWING:
		phase = Phase.UNIT_SELECTED
	emit_signal("preview_cleared")

## Undo the last committed MOVEMENT (movement only, §16). Restores the unit's tile.
## Returns true if something was undone.
func undo() -> bool:
	if _undo_stack.is_empty():
		emit_signal("rejected", "nothing to undo")
		return false
	var rec: Dictionary = _undo_stack.pop_back()
	var e = turn.state.entities.get(rec.id)
	if e == null:
		return false
	# clear new tile, restore old
	if turn.state.in_bounds(e.pos) and turn.state.tile(e.pos).occupant_id == e.id:
		turn.state.tile(e.pos).occupant_id = -1
	e.pos = rec.pos
	if turn.state.in_bounds(e.pos):
		turn.state.tile(e.pos).occupant_id = e.id
	# refund 1 AP for the undone Move
	turn.ap[rec.id] = turn.ap_for(rec.id) + 1
	turn.ended[rec.id] = false
	emit_signal("preview_cleared")
	return true

# ============================ PREP (build pending cmd + preview) ================
func _prepare_move(actor, cell: Vector2i) -> void:
	var path := _orthogonal_path(actor.pos, cell)
	if path.is_empty():
		emit_signal("rejected", "no straight path to that tile")
		return
	var cmd := MoveCommand.new(selected_id, path)
	var v: Dictionary = cmd.validate(turn.state, turn)
	if not v.ok:
		emit_signal("rejected", v.reason)
		return
	_pending_kind = "move"
	_pending_cmd = cmd
	_pending_payload = {"path": path, "to": cell}
	phase = Phase.PREVIEWING
	emit_signal("preview_requested", "move", _pending_payload)

func _prepare_shoot(actor, cell: Vector2i) -> void:
	var target = turn.state.occupant_at(cell)
	if target == null or not target.is_unit:
		emit_signal("rejected", "no unit there to shoot")
		return
	var cmd := ShootCommand.new(selected_id, target.id)
	var v: Dictionary = cmd.validate(turn.state, turn)
	if not v.ok:
		emit_signal("rejected", v.reason)
		return
	_pending_kind = "attack"
	_pending_cmd = cmd
	_pending_payload = {"target": target.id, "chance": ShootCommand.hit_chance(turn.state, actor, target)}
	phase = Phase.PREVIEWING
	emit_signal("preview_requested", "shoot", _pending_payload)

func _prepare_physics(actor, cell: Vector2i) -> void:
	var target = turn.state.occupant_at(cell)
	if target == null:
		emit_signal("rejected", "no entity there to push")
		return
	var dir := Vector2i(sign(cell.x - actor.pos.x), sign(cell.y - actor.pos.y))
	# physics commands want a single orthogonal contact dir
	if abs(dir.x) + abs(dir.y) != 1:
		emit_signal("rejected", "target must be orthogonally adjacent")
		return
	var force: int = E.SHOVE_FORCE
	var cmd
	match mode:
		Mode.SLAM:
			force = E.SLAM_FORCE
			cmd = SlamCommand.new(selected_id, target.id, dir, force)
		Mode.THROW:
			force = E.THROW_FORCE
			cmd = ThrowCommand.new(selected_id, target.id, dir, force)
		_:
			cmd = ShoveCommand.new(selected_id, target.id, dir, force)
	var v: Dictionary = cmd.validate(turn.state, turn)
	if not v.ok:
		emit_signal("rejected", v.reason)
		return
	_pending_kind = "physics"
	_pending_cmd = cmd
	_pending_payload = {"target": target.id, "dir": dir, "force": force}
	phase = Phase.PREVIEWING
	emit_signal("preview_requested", "physics", _pending_payload)

## §7.4 STABILIZE: point at an adjacent Downed player ally to stop its bleed-out clock. Builds an
## AbilityCommand (the synthetic STABILIZE_ABILITY) so it validates -> applies -> emits UNIT_STABILIZED
## through the same command path as everything else. Non-undoable (an ability), 1 AP, no end-turn.
func _prepare_stabilize(actor, cell: Vector2i) -> void:
	var target = turn.state.occupant_at(cell)
	if target == null or not target.is_unit or target.faction != E.Faction.PLAYER:
		emit_signal("rejected", "no ally there to stabilize")
		return
	if not target.downed or not target.has_status(E.S_BLEEDING):
		emit_signal("rejected", "that ally is not bleeding out")
		return
	var cmd := AbilityCommand.new(selected_id, STABILIZE_ABILITY, target.id)
	var v: Dictionary = cmd.validate(turn.state, turn)
	if not v.ok:
		emit_signal("rejected", v.reason)
		return
	_pending_kind = "ability"
	_pending_cmd = cmd
	_pending_payload = {"target": target.id, "ability": "stabilize"}
	phase = Phase.PREVIEWING
	emit_signal("preview_requested", "stabilize", _pending_payload)

## Mode.ABILITY: target the armed ability per its targeting kind (self/ally/enemy/tile/direction),
## build the AbilityCommand, validate, and request its preview. A physics-flavored ability (an
## impulse/throw/pull effect) rides a `phys` payload so the ghost draws the SAME deterministic
## resolver preview SHOVE/SLAM use (preview == commit). Mirrors _prepare_physics/_prepare_stabilize.
func _prepare_ability(actor, cell: Vector2i) -> void:
	if _armed_ability.is_empty():
		emit_signal("rejected", "no ability armed")
		return
	var targeting: String = _armed_ability.get("targeting", "self")
	var tid: int = -1
	var tpos: Vector2i = actor.pos
	var adir: Vector2i = Vector2i.ZERO
	match targeting:
		"enemy", "ally":
			var target = turn.state.occupant_at(cell)
			if target == null or not target.is_unit:
				emit_signal("rejected", "no unit there to target")
				return
			tid = target.id
			tpos = target.pos
		"tile":
			tpos = cell
		"direction":
			adir = Vector2i(sign(cell.x - actor.pos.x), sign(cell.y - actor.pos.y))
			if abs(adir.x) + abs(adir.y) != 1:
				emit_signal("rejected", "pick an orthogonally adjacent direction")
				return
			var occ = turn.state.occupant_at(cell)
			if occ != null:
				tid = occ.id
			tpos = cell
		_:
			tid = selected_id            # self
	var cmd := AbilityCommand.new(selected_id, _armed_ability, tid, tpos, adir)
	var v: Dictionary = cmd.validate(turn.state, turn)
	if not v.ok:
		emit_signal("rejected", v.reason)
		return
	_pending_kind = "ability"
	_pending_cmd = cmd
	_pending_payload = {"ability": _armed_ability.get("id", "?"), "target": tid, "target_pos": tpos, "dir": adir}
	var phys: Dictionary = _physics_preview(actor, _armed_ability, tid, adir)
	if not phys.is_empty():
		_pending_payload["phys"] = phys
	phase = Phase.PREVIEWING
	emit_signal("preview_requested", "ability", _pending_payload)


## Mode.USE_ITEM: target the armed consumable/gadget per its targeting kind, build the UseItemCommand,
## validate, and request its preview (a physics-flavored item — e.g. Grapple's pull — rides `phys`).
func _prepare_item(actor, cell: Vector2i) -> void:
	if _armed_item.is_empty():
		emit_signal("rejected", "no item armed")
		return
	var targeting: String = _armed_item.get("targeting", "self")
	var tid: int = -1
	var tpos: Vector2i = actor.pos
	var adir: Vector2i = Vector2i.ZERO
	match targeting:
		"enemy", "ally":
			var target = turn.state.occupant_at(cell)
			if target == null or not target.is_unit:
				emit_signal("rejected", "no unit there to target")
				return
			tid = target.id
			tpos = target.pos
		"tile":
			tpos = cell
		"direction":
			adir = Vector2i(sign(cell.x - actor.pos.x), sign(cell.y - actor.pos.y))
			if abs(adir.x) + abs(adir.y) != 1:
				emit_signal("rejected", "pick an orthogonally adjacent direction")
				return
			var occ = turn.state.occupant_at(cell)
			if occ != null:
				tid = occ.id
			tpos = cell
		_:
			tid = selected_id            # self
	var cmd := UseItemCommand.new(selected_id, _armed_item, _armed_item_id, tid, tpos, adir)
	var v: Dictionary = cmd.validate(turn.state, turn)
	if not v.ok:
		emit_signal("rejected", v.reason)
		return
	_pending_kind = "item"
	_pending_cmd = cmd
	_pending_payload = {"item": _armed_item_id, "target": tid, "target_pos": tpos, "dir": adir}
	var phys: Dictionary = _physics_preview(actor, _armed_item, tid, adir)
	if not phys.is_empty():
		_pending_payload["phys"] = phys
	phase = Phase.PREVIEWING
	emit_signal("preview_requested", "item", _pending_payload)


## Build the physics-ghost preview payload for an ability/item that displaces a body (impulse / throw
## / pull), or {} if it has no such effect. On-screen-only cue — the ghost is a clone dry-run, so it
## never touches sim state. Mirrors AbilitySystem's dir/force resolution so preview == commit.
func _physics_preview(actor, def: Dictionary, tid: int, adir: Vector2i) -> Dictionary:
	var pushed = turn.state.entities.get(tid)
	if pushed == null:
		return {}
	for eff in def.get("effects", []):
		var kind: String = eff.get("kind", "")
		match kind:
			"impulse", "throw":
				var f: int = int(eff.get("force", E.SHOVE_FORCE if kind == "impulse" else E.THROW_FORCE))
				var d: Vector2i = adir if adir != Vector2i.ZERO else _dir_from_to(actor.pos, pushed.pos)
				if d != Vector2i.ZERO:
					return {"id": tid, "dir": d, "force": f}
			"pull":
				var d2: Vector2i = _dir_from_to(pushed.pos, actor.pos)
				if d2 != Vector2i.ZERO:
					return {"id": tid, "dir": d2, "force": int(eff.get("force", E.SHOVE_FORCE))}
	return {}


static func _dir_from_to(a: Vector2i, b: Vector2i) -> Vector2i:
	var dx: int = b.x - a.x
	var dy: int = b.y - a.y
	if abs(dx) >= abs(dy):
		if dx == 0:
			return Vector2i.ZERO
		return Vector2i(sign(dx), 0)
	return Vector2i(0, sign(dy))


# ============================ helpers ==========================================
func _clear_armed() -> void:
	_armed_ability = {}
	_armed_item = {}
	_armed_item_id = ""

func _clear_pending() -> void:
	_pending_kind = ""
	_pending_cmd = null
	_pending_payload = {}

## An orthogonal Manhattan path (x-first then y) from `from` to `to`, capped at the
## Move range, stopping if it would hit a wall/occupant (returns the valid prefix).
func _orthogonal_path(from: Vector2i, to: Vector2i) -> Array:
	var path: Array = []
	var cur := from
	var sx: int = sign(to.x - from.x)
	while cur.x != to.x and path.size() < E.MOVE_RANGE:
		cur = Vector2i(cur.x + sx, cur.y)
		if not _walkable(cur):
			return path
		path.append(cur)
	var sy: int = sign(to.y - from.y)
	while cur.y != to.y and path.size() < E.MOVE_RANGE:
		cur = Vector2i(cur.x, cur.y + sy)
		if not _walkable(cur):
			return path
		path.append(cur)
	return path

func _walkable(p: Vector2i) -> bool:
	if not turn.state.in_bounds(p):
		return false
	var t = turn.state.tile(p)
	if t.terrain == E.Terrain.WALL or t.hazard == E.Hazard.GAP:
		return false
	var occ = turn.state.occupant_at(p)
	return occ == null or occ.id == selected_id

static func mode_name(m: int) -> String:
	match m:
		Mode.MOVE: return "MOVE"
		Mode.SHOOT: return "SHOOT"
		Mode.SHOVE: return "SHOVE"
		Mode.SLAM: return "SLAM"
		Mode.THROW: return "THROW"
		Mode.STABILIZE: return "STAB"
		Mode.ABILITY: return "ABILITY"
		Mode.USE_ITEM: return "ITEM"
		_: return "NONE"
