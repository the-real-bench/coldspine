class_name EventPlayer
extends Node
## Replays an ordered GameEvent list onto a CarView as an animated timeline. The
## ORDER of the list IS the timeline (Sub-Spec A9 / GameEvent) — never reorder.
##
## On-screen: each event tweens the relevant token (slide on MOVE/MOVE_STEP, flash on
## HIT, fade on UNIT_DEATH/EJECT) and pushes a line to the comms log. Headless: the
## same mutations apply INSTANTLY (no tween), so the smoke test sees final positions
## immediately. The authoritative state is the SimState the CarView already holds;
## this layer only animates the VISUAL token table toward it.

const E = preload("res://core/sim_enums.gd")
const Iso = preload("res://render/iso.gd")

signal comms(line: String)
signal finished()

var view                       # CarView
var headless: bool = false
var step_time: float = 0.18    # seconds per animated event on-screen (base pacing)

# --- on-screen animation controls (never touched by the synchronous headless path) ---
var speed_scale: float = 1.0   # >1 = faster (a long run can be fast-forwarded); clamps below
var instant_skip: bool = false # when true, play_animated applies instantly (skip the wait)

func _init(p_view = null, p_headless: bool = false) -> void:
	view = p_view
	headless = p_headless

## Apply an event stream — SYNCHRONOUS + INSTANT (the headless contract). On-screen this
## still snaps the token table to its final state; play_animated() is the on-screen path
## that paces + tweens the SAME mutations. This function is byte-identical to before so the
## five headless suites stay stable.
func play(events: Array) -> void:
	for ev in events:
		_apply(ev)
	emit_signal("finished")


## ON-SCREEN ANIMATED PLAYBACK (await-able). Replays the SAME event stream as play(), but
## paces successive events and tweens token motion/flash/fade so the run PLAYS rather than
## snaps. NEVER call this headless — it awaits SceneTreeTimers / tweens that only progress
## with a running main loop. The authoritative SimState is already committed before we get
## here; this only animates the VISUAL token table toward it, so it can't change the sim.
##
## Pacing: each "beat" event (move/attack/impact/death) waits ~step_time / speed_scale before
## the next, so the eye can follow the chain. `instant_skip` (set by the AUTO/fast-forward
## control) collapses the whole stream to an instant apply — identical end-state, no waiting.
func play_animated(events: Array) -> void:
	if instant_skip or view == null or not is_inside_tree():
		play(events)
		return
	var beat: float = max(0.02, step_time / max(0.05, speed_scale))
	for ev in events:
		var paced: bool = await _apply_animated(ev, beat)
		if paced:
			await _wait(beat)
	emit_signal("finished")


# Wait `t` seconds on the scene-tree clock (only valid inside the tree, on-screen).
func _wait(t: float) -> void:
	var tree := get_tree()
	if tree == null:
		return
	await tree.create_timer(t).timeout

func _apply(ev) -> void:
	match ev.type:
		E.Ev.MOVE, E.Ev.MOVE_STEP:
			_move_token(ev.data.get("id", -1), ev.data.get("to", null))
			_log("MOVE  unit %s -> %s" % [ev.data.get("id"), str(ev.data.get("to"))])
		E.Ev.STAND_UP:
			_clear_status(ev.data.get("id", -1), E.S_PRONE)
			_log("STAND unit %s" % ev.data.get("id"))
		E.Ev.ATTACK_SHOOT:
			_log("FIRE  %s -> %s  (%d%% to hit)" % [ev.data.get("actor"), ev.data.get("target"), ev.data.get("chance", 0)])
		E.Ev.HIT:
			_log("HIT   target %s  -%d hp (%d left)" % [ev.data.get("target"), ev.data.get("dmg", 0), ev.data.get("hp_left", 0)])
			_set_hp(ev.data.get("target", -1), ev.data.get("hp_left", -1))
		E.Ev.MISS:
			_log("MISS  %s -> %s" % [ev.data.get("actor"), ev.data.get("target")])
		E.Ev.IMPACT_WALL:
			_log("SLAM  unit %s into wall  -%d hp%s" % [ev.data.get("id"), ev.data.get("dmg", 0), (" PRONE" if ev.data.get("prone") else "")])
		E.Ev.COLLIDE_BODY:
			_log("BILLIARDS %s -> %s  -%d hp" % [ev.data.get("a_id"), ev.data.get("b_id"), ev.data.get("dmg", 0)])
		E.Ev.OBJECT_DAMAGED:
			_log("DMG   obj %s  (%d integ left)" % [ev.data.get("id"), ev.data.get("integrity_left", 0)])
		E.Ev.OBJECT_BREAK:
			_kill_token(ev.data.get("id", -1))
			_log("SHATTER obj %s @ %s" % [ev.data.get("id"), str(ev.data.get("pos"))])
		E.Ev.FLOOD_TILE:
			pass  # tile layers come from the committed state; logged in bulk below
		E.Ev.SHOCK:
			_log("SHOCK chain  unit %s  -%d hp" % [ev.data.get("id"), ev.data.get("dmg", 0)])
		E.Ev.HAZARD_FURNACE, E.Ev.HAZARD_RAIL, E.Ev.HAZARD_PISTON:
			_log("HAZARD unit %s  -%d hp" % [ev.data.get("id"), ev.data.get("dmg", 0)])
		E.Ev.EJECT:
			_kill_token(ev.data.get("id", -1))
			_log("EJECT unit %s off the train" % ev.data.get("id"))
		E.Ev.STATUS_APPLY:
			_set_status(ev.data.get("id", -1), ev.data.get("status", 0))
		E.Ev.STATUS_CLEAR:
			_clear_status(ev.data.get("id", -1), ev.data.get("status", 0))
		E.Ev.UNIT_DOWNED:
			# A genuine bleed-out down (carries a `bleed` window) stays visible as a body (combat-ux #2);
			# a down with no window is a plain death handled by the following UNIT_DEATH.
			_down_token(ev.data.get("id", -1), int(ev.data.get("bleed", 0)))
			_log("DOWN  unit %s" % ev.data.get("id"))
		E.Ev.UNIT_DEATH, E.Ev.UNIT_PERMADEATH:
			_kill_token(ev.data.get("id", -1))
			_log("DEAD  unit %s" % ev.data.get("id"))
		E.Ev.BLEED_TICK:
			_set_bleed(ev.data.get("id", -1), int(ev.data.get("left", 0)))
			_log("BLEED unit %s  (%d left)" % [ev.data.get("id"), ev.data.get("left", 0)])
		E.Ev.UNIT_STABILIZED:
			_stabilize_token(ev.data.get("id", -1))
			_log("STAB  unit %s" % ev.data.get("id"))
		E.Ev.TURN_PHASE:
			_log("--- %s  (round %d) ---" % [phase_name(int(ev.data.get("phase", 0))), ev.data.get("round", 0)])
		E.Ev.BETRAYAL:
			# The faction flip is already committed in the sim; sync_tokens recolors the ring.
			_log("BETRAY unit %s (%s) DEFECTS — Conductor's Kin!" % [ev.data.get("id"), str(ev.data.get("name", "?"))])
		E.Ev.RUN_WIN:
			_log("*** CAR CLEARED ***")
		E.Ev.RUN_LOSE:
			_log("*** SQUAD LOST ***")
		# --- Phase 6 finale beats (Sub-Spec B). Previously ALL of these fell through `_: pass`, so the
		# Engine-Vault climax was mute on the feed: a shielded shot did nothing, no klaxon on the breach,
		# no relay/countdown narration (W4-4 / W4-5). The comms line IS the tell on the instant path; the
		# animated path below adds the flash / glitch juice. Data keys mirror core/finale + ai/conductor_ai.
		E.Ev.DAMAGE_SHIELDED:
			_log(_shielded_line(ev))
		E.Ev.RELAY_DISABLED:
			_log("RELAY %s DOWN — %d relay(s) still online" % [str(ev.data.get("relay", "?")), int(ev.data.get("online_left", 0))])
		E.Ev.CONDUCTOR_POWER_DISABLED:
			_log("POWER SEVERED — %s offline with its relay" % str(ev.data.get("power", "?")))
		E.Ev.CORE_SHIELD:
			_log("CORE SHIELD HOLDS — a relay still powers it")
		E.Ev.CORE_SHIELD_DROP:
			_log("*** CORE SHIELD DOWN — THE CORE IS EXPOSED ***")
		E.Ev.CORE_DAMAGED:
			_log("SABOTAGE — core -%d  (%d integ left)" % [int(ev.data.get("dmg", 0)), int(ev.data.get("integrity_left", 0))])
		E.Ev.CORE_SABOTAGED:
			_log("*** CORE SABOTAGED — THE ENGINE IS STOPPING ***")
		E.Ev.VAULT_PHASE:
			_log("== ENGINE VAULT :: PHASE %d ==" % int(ev.data.get("phase", 0)))
		E.Ev.VAULT_ESCALATE:
			_log("!! ESCALATION +%d — the vault turns hostile" % int(ev.data.get("level", 0)))
		E.Ev.COUNTDOWN_TICK:
			_log(_countdown_line(ev))
		E.Ev.COUNTDOWN_EXPIRED:
			_log("!! BRIDGE BREACHED — POINT OF NO RETURN")
		E.Ev.CONDUCTOR_TELEGRAPH:
			_log("! CONDUCTOR winds up — brace for its next move")
		E.Ev.CONDUCTOR_ACT:
			_log("CONDUCTOR strikes")
		E.Ev.DISPENSER_SPAWN:
			_log("DISPENSER — a security robot drops onto the deck")
		_:
			pass

# ---- ANIMATED per-event apply (on-screen only; awaits tweens/flashes) ----
## Animate one event, mirroring _apply's mutations but with motion/flash/fade tweens. Returns
## true if this is a visible "beat" the caller should pace after (so silent bookkeeping events
## don't stall the timeline). Always emits the same comms line _apply does (parity for the log).
func _apply_animated(ev, beat: float) -> bool:
	# AUDIO (release-readiness #4): the single on-screen SFX choke point. AudioDirector maps this
	# event type to a named SFX slot and plays it if a real file is present (silent no-op otherwise,
	# and a total no-op headless). Resolved via the tree (NOT the autoload global) so this script
	# still compiles when run under a `--script` test harness where autoload globals aren't bound.
	# Render-only — play_animated never runs in the suites, and the director writes nothing back to
	# the sim, so determinism / byte-identical stdout hold.
	var ad := get_node_or_null(^"/root/AudioDirector")
	if ad != null:
		ad.event_sfx(ev.type)
	match ev.type:
		E.Ev.MOVE, E.Ev.MOVE_STEP:
			_log("MOVE  unit %s -> %s" % [ev.data.get("id"), str(ev.data.get("to"))])
			await _tween_move(ev.data.get("id", -1), ev.data.get("to", null), beat)
			return true
		E.Ev.STAND_UP:
			_clear_status(ev.data.get("id", -1), E.S_PRONE)
			_log("STAND unit %s" % ev.data.get("id"))
			return true
		E.Ev.ATTACK_SHOOT:
			_log("FIRE  %s -> %s  (%d%% to hit)" % [ev.data.get("actor"), ev.data.get("target"), ev.data.get("chance", 0)])
			return true
		E.Ev.HIT:
			_log("HIT   target %s  -%d hp (%d left)" % [ev.data.get("target"), ev.data.get("dmg", 0), ev.data.get("hp_left", 0)])
			_flash(ev.data.get("target", -1))
			_set_hp(ev.data.get("target", -1), ev.data.get("hp_left", -1))
			_float_dmg(ev.data.get("target", -1), int(ev.data.get("dmg", 0)))
			return true
		E.Ev.MISS:
			_log("MISS  %s -> %s" % [ev.data.get("actor"), ev.data.get("target")])
			return true
		E.Ev.IMPACT_WALL:
			_log("SLAM  unit %s into wall  -%d hp%s" % [ev.data.get("id"), ev.data.get("dmg", 0), (" PRONE" if ev.data.get("prone") else "")])
			_flash(ev.data.get("id", -1))
			_float_dmg(ev.data.get("id", -1), int(ev.data.get("dmg", 0)))
			return true
		E.Ev.COLLIDE_BODY:
			_log("BILLIARDS %s -> %s  -%d hp" % [ev.data.get("a_id"), ev.data.get("b_id"), ev.data.get("dmg", 0)])
			_flash(ev.data.get("a_id", -1)); _flash(ev.data.get("b_id", -1))
			_float_dmg(ev.data.get("b_id", -1), int(ev.data.get("dmg", 0)))
			return true
		E.Ev.OBJECT_DAMAGED:
			_log("DMG   obj %s  (%d integ left)" % [ev.data.get("id"), ev.data.get("integrity_left", 0)])
			_flash(ev.data.get("id", -1))
			return true
		E.Ev.OBJECT_BREAK:
			_log("SHATTER obj %s @ %s" % [ev.data.get("id"), str(ev.data.get("pos"))])
			await _tween_fade(ev.data.get("id", -1), beat)
			return true
		E.Ev.FLOOD_TILE:
			return false
		E.Ev.SHOCK:
			_log("SHOCK chain  unit %s  -%d hp" % [ev.data.get("id"), ev.data.get("dmg", 0)])
			_flash(ev.data.get("id", -1))
			_float_dmg(ev.data.get("id", -1), int(ev.data.get("dmg", 0)))
			return true
		E.Ev.HAZARD_FURNACE, E.Ev.HAZARD_RAIL, E.Ev.HAZARD_PISTON:
			_log("HAZARD unit %s  -%d hp" % [ev.data.get("id"), ev.data.get("dmg", 0)])
			_flash(ev.data.get("id", -1))
			_float_dmg(ev.data.get("id", -1), int(ev.data.get("dmg", 0)))
			return true
		E.Ev.EJECT:
			_log("EJECT unit %s off the train" % ev.data.get("id"))
			await _tween_fade(ev.data.get("id", -1), beat)
			return true
		E.Ev.STATUS_APPLY:
			_set_status(ev.data.get("id", -1), ev.data.get("status", 0))
			return false
		E.Ev.STATUS_CLEAR:
			_clear_status(ev.data.get("id", -1), ev.data.get("status", 0))
			return false
		E.Ev.UNIT_DOWNED:
			var bleed: int = int(ev.data.get("bleed", 0))
			_log("DOWN  unit %s" % ev.data.get("id"))
			if bleed > 0:
				# A savable body stays on the board (combat-ux #2) — no fade-out; drop to the downed pose.
				_down_token(ev.data.get("id", -1), bleed)
				return true
			# No revive window — a plain death; fade it out (the following UNIT_DEATH, if any, is a no-op).
			await _tween_fade(ev.data.get("id", -1), beat)
			return true
		E.Ev.UNIT_DEATH, E.Ev.UNIT_PERMADEATH:
			_log("DEAD  unit %s" % ev.data.get("id"))
			await _tween_fade(ev.data.get("id", -1), beat)
			return true
		E.Ev.BLEED_TICK:
			_set_bleed(ev.data.get("id", -1), int(ev.data.get("left", 0)))
			_log("BLEED unit %s  (%d left)" % [ev.data.get("id"), ev.data.get("left", 0)])
			return false
		E.Ev.UNIT_STABILIZED:
			_stabilize_token(ev.data.get("id", -1))
			_log("STAB  unit %s" % ev.data.get("id"))
			return true
		E.Ev.TURN_PHASE:
			_log("--- %s  (round %d) ---" % [phase_name(int(ev.data.get("phase", 0))), ev.data.get("round", 0)])
			return false
		E.Ev.BETRAYAL:
			_log("BETRAY unit %s (%s) DEFECTS — Conductor's Kin!" % [ev.data.get("id"), str(ev.data.get("name", "?"))])
			_flash(ev.data.get("id", -1))
			return true
		E.Ev.RUN_WIN:
			_log("*** CAR CLEARED ***")
			return true
		E.Ev.RUN_LOSE:
			_log("*** SQUAD LOST ***")
			return true
		# --- Phase 6 finale beats (Sub-Spec B) — same comms lines as _apply plus the on-screen juice:
		# a shielded shot flashes + floats a "SHIELDED" deflect tell (W4-4); the shield drop / breach /
		# escalation / sabotage tear the feed with a glitch-split (W4-5). Render-only; never runs headless.
		E.Ev.DAMAGE_SHIELDED:
			_log(_shielded_line(ev))
			var stid: int = int(ev.data.get("target", -1))
			_flash(stid)
			_float_shielded(stid)
			return true
		E.Ev.RELAY_DISABLED:
			_log("RELAY %s DOWN — %d relay(s) still online" % [str(ev.data.get("relay", "?")), int(ev.data.get("online_left", 0))])
			_glitch(0.6)
			return true
		E.Ev.CONDUCTOR_POWER_DISABLED:
			_log("POWER SEVERED — %s offline with its relay" % str(ev.data.get("power", "?")))
			return false
		E.Ev.CORE_SHIELD:
			_log("CORE SHIELD HOLDS — a relay still powers it")
			return false
		E.Ev.CORE_SHIELD_DROP:
			_log("*** CORE SHIELD DOWN — THE CORE IS EXPOSED ***")
			_glitch(1.0)
			return true
		E.Ev.CORE_DAMAGED:
			_log("SABOTAGE — core -%d  (%d integ left)" % [int(ev.data.get("dmg", 0)), int(ev.data.get("integrity_left", 0))])
			return true
		E.Ev.CORE_SABOTAGED:
			_log("*** CORE SABOTAGED — THE ENGINE IS STOPPING ***")
			_glitch(1.0)
			return true
		E.Ev.VAULT_PHASE:
			_log("== ENGINE VAULT :: PHASE %d ==" % int(ev.data.get("phase", 0)))
			return false
		E.Ev.VAULT_ESCALATE:
			_log("!! ESCALATION +%d — the vault turns hostile" % int(ev.data.get("level", 0)))
			_glitch(0.8)
			return true
		E.Ev.COUNTDOWN_TICK:
			_log(_countdown_line(ev))
			return false
		E.Ev.COUNTDOWN_EXPIRED:
			_log("!! BRIDGE BREACHED — POINT OF NO RETURN")
			_glitch(0.8)
			return true
		E.Ev.CONDUCTOR_TELEGRAPH:
			_log("! CONDUCTOR winds up — brace for its next move")
			return false
		E.Ev.CONDUCTOR_ACT:
			_log("CONDUCTOR strikes")
			return true
		E.Ev.DISPENSER_SPAWN:
			_log("DISPENSER — a security robot drops onto the deck")
			return true
		_:
			return false


## Tween a token from its current vis_pos to the screen-space center of `to`, over ~beat secs.
func _tween_move(id: int, to, beat: float) -> void:
	if view == null or id < 0 or to == null or not view.tokens.has(id):
		return
	var target: Vector2 = view.cell_to_screen(to)
	var tree := get_tree()
	if tree == null:
		view.set_token_vis_pos(id, target)
		return
	var tw := tree.create_tween()
	# tween_method passes the interpolated value as arg 1; set_token_vis_pos wants id first, p second,
	# so wrap in a lambda (a trailing .bind(id) would shove the Vector2 onto the int `id` slot).
	tw.tween_method(func(p): view.set_token_vis_pos(id, p), Vector2(view.tokens[id]["vis_pos"]), target, beat)
	await tw.finished


## Tween a token's alpha to 0 (death / break / eject), then drop it from the table.
func _tween_fade(id: int, beat: float) -> void:
	if view == null or id < 0 or not view.tokens.has(id):
		return
	var tree := get_tree()
	if tree == null:
		_kill_token(id)
		return
	var tw := tree.create_tween()
	# Same arg-order fix as _tween_move: id first, interpolated alpha second (the bad .bind(id) was silent
	# here because float<->int auto-converts, but it faded the wrong token).
	tw.tween_method(func(a): view.set_token_fade(id, a), 1.0, 0.0, beat)
	await tw.finished
	_kill_token(id)


func _flash(id: int) -> void:
	if view != null and id >= 0 and view.tokens.has(id) and view.has_method("flash_token"):
		view.flash_token(id, 1.0)


## Float a "SHIELDED" deflect tell over a token whose incoming damage was gated (W4-4) — the on-screen
## companion to the comms line so the player SEES why a turn-ending shot did nothing. Render-only.
func _float_shielded(id: int) -> void:
	if view != null and id >= 0 and view.has_method("float_shielded"):
		view.float_shielded(id)


## Fire a screen-space glitch-tear on a big finale beat (shield drop / breach / escalation / sabotage,
## W4-5). Render-only, on-screen only (the CarView owns the cosmetic timer; headless never ticks it).
func _glitch(strength: float) -> void:
	if view != null and view.has_method("glitch"):
		view.glitch(strength)


## Human-readable TURN phase name (W5-4). The sim TURN_PHASE event carries an E.Phase int (0/1/2); the
## comms/turn banner must read PLAYER/ENEMY/ENVIRONMENT for the operator, never a raw internal "PHASE 0".
## PURE + static so both play paths and the headless test share one mapping. Unknown ints fall back to a
## labeled form (never silently blank).
static func phase_name(phase: int) -> String:
	match phase:
		E.Phase.PLAYER:      return "PLAYER PHASE"
		E.Phase.ENEMY:       return "ENEMY PHASE"
		E.Phase.ENVIRONMENT: return "ENVIRONMENT PHASE"
		_: return "PHASE %d" % phase


# --- finale comms-line builders (shared by _apply + _apply_animated for log parity) ---
## The DAMAGE_SHIELDED feed line (W4-4): a sealed Core reads differently from a relay-shielded body,
## and both spell out the counterplay (drop the shield / disable the relays) so the tell teaches.
func _shielded_line(ev) -> String:
	if bool(ev.data.get("core", false)):
		return "! CORE SEALED — drop the shield (disable the relays) first"
	return "! SHIELDED — the relays must fall before this hit lands"


## The COUNTDOWN_TICK feed line (W4-5): the arming tick reads as a klaxon; later ticks are a terse
## T-minus so the comms log narrates the bridge clock the boss HUD shows.
func _countdown_line(ev) -> String:
	var cd: int = int(ev.data.get("countdown", 0))
	if bool(ev.data.get("started", false)):
		return "!! BRIDGE COUNTDOWN ARMED — T-%02d TO THE POINT OF NO RETURN" % cd
	return "BRIDGE  T-%02d" % cd


# ---- token mutation (visual table on the CarView) ----
func _move_token(id: int, to) -> void:
	if view == null or id < 0 or to == null or not view.tokens.has(id):
		return
	var target: Vector2 = Iso.tile_to_screen(to, view.origin)
	view.tokens[id]["vis_pos"] = target
	view.queue_redraw()

func _set_status(id: int, flag: int) -> void:
	if view == null or not view.tokens.has(id):
		return
	if flag == E.S_DOWNED:
		_kill_token(id)
		return
	view.tokens[id]["vis_status"] |= flag
	view.queue_redraw()

func _clear_status(id: int, flag: int) -> void:
	if view == null or not view.tokens.has(id):
		return
	view.tokens[id]["vis_status"] &= ~flag
	view.queue_redraw()

func _kill_token(id: int) -> void:
	if view == null or not view.tokens.has(id):
		return
	view.tokens[id]["alive"] = false
	view.tokens[id]["downed"] = false   # a killed token is not a savable body
	view.queue_redraw()

## Drop a token into the visible DOWNED (bleeding-out) pose (combat-ux #2): keep it on the board with
## a bleed countdown instead of vanishing it. alive stays false (it can't act), but `downed` keeps it
## drawn. Visual table only — never read by debug_ascii.
func _down_token(id: int, bleed: int) -> void:
	if view == null or id < 0 or bleed <= 0 or not view.tokens.has(id):
		return
	view.tokens[id]["downed"] = true
	view.tokens[id]["bleed"] = bleed
	view.tokens[id]["hp"] = 0
	view.queue_redraw()

## Update a downed token's bleed-out countdown pips (combat-ux #2). Visual table only.
func _set_bleed(id: int, left: int) -> void:
	if view == null or not view.tokens.has(id):
		return
	view.tokens[id]["bleed"] = max(0, left)
	view.queue_redraw()

## A stabilized ally is still Downed (a body on the ground) but no longer bleeding — drop the countdown.
func _stabilize_token(id: int) -> void:
	if view == null or not view.tokens.has(id):
		return
	if bool(view.tokens[id].get("downed", false)):
		view.tokens[id]["bleed"] = 0
	view.queue_redraw()

## Reflect a hit's remaining HP on the token so its bar drops as the comms log reports it (combat-ux #5).
## Visual table only — never read by debug_ascii.
func _set_hp(id: int, hp_left: int) -> void:
	if view == null or hp_left < 0 or not view.tokens.has(id):
		return
	view.tokens[id]["hp"] = hp_left
	view.queue_redraw()

## Spawn a floating damage number over a struck token (combat-ux #5) — animated path only.
func _float_dmg(id: int, amount: int) -> void:
	if view != null and id >= 0 and amount > 0 and view.has_method("float_damage"):
		view.float_damage(id, amount)

func _log(line: String) -> void:
	emit_signal("comms", line)
