class_name AIProfiles
extends RefCounted
## Phase 5 — distinct deterministic per-`aiProfile` behaviors (GDD §12), layered over
## the Phase-0i EnemyAI command policy. RefCounted statics, ZERO SceneTree, integer-only,
## randomness ONLY via the Shoot command's rng (the policy itself is rng-free).
##
## EnemyAI._act_once() dispatches here on the acting unit's `ai_profile`. Each profile
## returns true if it issued a command this step (so the unit keeps acting while it has
## AP), false if it had nothing useful to do (yield the rest of its AP).
##
## Profiles:
##   melee_rush   — close the distance and slam; opportunistic advantageous shoves.
##   ranged_hold  — hold distance, shoot from cover, suppress; back away if crowded.
##   flanker      — sprint to a flank angle on the target, then strike (Hound; bait-able).
##   support      — hang back out of range and deploy bots (Drone Operator).
##   robot        — heavy bruiser-bot: ram forward, slam on contact (Security Robot /
##                  Chief); a Sentry Turret (move 0) is forced into a static hold.
##
## Net Gunner / Enforcer / Sniper are the same profiles with data-driven kit:
##   Net Gunner   — ranged_hold whose attack immobilizes (net) instead of damaging.
##   Enforcer     — ranged_hold, armored (heavy mass), holds and volleys.
##   Sniper       — ranged_hold with an overwatch threat (arms overwatch when it can't
##                  get a clean shot, per its kit).

const E = preload("res://core/sim_enums.gd")
const GE = preload("res://core/game_event.gd")
const ShootCommand = preload("res://core/commands/shoot_command.gd")
const MoveCommand = preload("res://core/commands/move_command.gd")
const ShoveCommand = preload("res://core/commands/shove_command.gd")
const SlamCommand = preload("res://core/commands/slam_command.gd")
const OverwatchCommand = preload("res://core/commands/overwatch_command.gd")
const SimEntity = preload("res://core/sim_entity.gd")
const OverwatchSystem = preload("res://core/overwatch_system.gd")

# Stable orthogonal step order (N, E, S, W) — matches the resolver/EnemyAI DIRS4.
const DIRS4 := [Vector2i(0, -1), Vector2i(1, 0), Vector2i(0, 1), Vector2i(-1, 0)]

# Distances each ranged profile tries to hold (Manhattan). Tunable, first-pass.
const HOLD_DISTANCE := 4    # ranged_hold: prefers to sit at ~this range
const SUPPORT_DISTANCE := 5 # support: hangs back further than a plain shooter


## Dispatch one action for `ai` (an EnemyAI, for its shared helpers) controlling unit
## `id`. Returns true if a command was issued.
static func act(ai, turn, id: int, events: Array) -> bool:
	var state = turn.state
	var me = state.entities.get(id)
	if me == null or not me.alive:
		return false
	# Ambush-start (E1.7 / W2-4): an Unaware enemy holds until the FIGHT REACHES IT — a player
	# steps adjacent, or it takes damage. The opening round the operator still gets a free hand
	# (enemies only act in the enemy phase); once woken the unit acts normally. Nothing cleared
	# `unaware` before this fix, so the Spa car's ambushers were permanently inert.
	if me.unaware:
		if not _fight_joined(ai, state, me):
			return false
		me.unaware = false
		# NOTE (deferred): a WAKE render event / dimmed-ring tell would fire here, but no
		# E.Ev.WAKE exists yet (sim_enums + render/ are outside this lane, and render/ has no
		# `unaware` handling today). The behavioral wake is the fix; the visual tell is follow-up.
	# Riot Shield facing (W2-3): re-orient to face the nearest player each activation so the
	# frontal block TRACKS the advancing/flanking squad. The resolver blocks a shove whose
	# dir == facing, so facing is set to the push-dir a shove FROM that player would apply.
	if me.phys_trait == E.PhysTrait.BLOCKS_FRONTAL_SHOVE:
		var foe = ai._nearest_player(state, me)
		if foe != null:
			me.facing = _face_dir(me.pos - foe.pos)
	match me.ai_profile:
		E.AIProfile.RANGED_HOLD:
			return _ranged_hold(ai, turn, me, events)
		E.AIProfile.FLANKER:
			return _flanker(ai, turn, me, events)
		E.AIProfile.SUPPORT:
			return _support(ai, turn, me, events)
		E.AIProfile.ROBOT:
			return _robot(ai, turn, me, events)
		_:
			return _melee_rush(ai, turn, me, events)


# ---------------------------------------------------------------- melee_rush ----
## Close the distance and slam; opportunistic advantageous shove when adjacent. This is
## the Phase-0i default policy (shove→shoot→move), preserved byte-for-byte so the
## existing AI fixtures stay green — with a Slam preferred over a plain Shove on contact.
static func _melee_rush(ai, turn, me, events: Array) -> bool:
	var state = turn.state
	var target = ai._nearest_player(state, me)
	if target == null:
		return false

	# Adjacent: prefer an advantageous shove (into peril); else a slam to stagger.
	if ai._manhattan(me.pos, target.pos) == 1:
		var sdir: Vector2i = ai._advantageous_shove_dir(state, me, target)
		if sdir != Vector2i.ZERO:
			if _try(turn, ShoveCommand.new(me.id, target.id, sdir, E.SHOVE_FORCE), events):
				return true
		var into: Vector2i = target.pos - me.pos
		if abs(into.x) + abs(into.y) == 1 and target.movable:
			if _try(turn, SlamCommand.new(me.id, target.id, into, E.SLAM_FORCE), events):
				return true

	# In range with LoS → shoot.
	if ShootCommand.has_range(me.pos, target.pos) and ShootCommand.in_los(state, me.pos, target.pos):
		if _try(turn, ShootCommand.new(me.id, target.id), events):
			return true

	# Otherwise step toward.
	return _step_toward(ai, turn, me, target.pos, events)


# --------------------------------------------------------------- ranged_hold ----
## Hold distance and shoot from cover; suppress. If a player gets too close, back away
## one step to re-open the range (kiting) rather than melee. Sniper arms overwatch when
## it cannot get a clean shot (data: it carries an overwatch ability).
static func _ranged_hold(ai, turn, me, events: Array) -> bool:
	var state = turn.state
	var target = ai._nearest_player(state, me)
	if target == null:
		return false
	var d: int = ai._manhattan(me.pos, target.pos)

	# Anchored / static shooter (Sentry Turret, move 0): fire if it has a shot, else HOLD.
	# It NEVER moves — enforced here (so it doesn't waste the phase on rejected MOVEs) and
	# hard-guarded at the command layer. This is the "static destructible" design (W2-2);
	# without it a `ranged_hold` turret kites adjacent players and crawls toward distant ones.
	if not me.movable:
		if _has_shot(state, me, target):
			return _shoot_or_net(turn, me, target, events)
		return false

	# Crowded (player adjacent): back away to re-open range BEFORE shooting — a shooter
	# does not want to fight in melee. If it can't retreat, it falls through and fires.
	if d <= 1:
		var away: Vector2i = _step_away(ai, state, me, target.pos)
		if away != me.pos:
			return _move_step(ai, turn, me, away, events)

	# A clean shot in range + LoS → take it (ends the turn). A Net Gunner immobilizes (nets)
	# the target instead of dealing damage — a control attack (§12).
	if _has_shot(state, me, target):
		return _shoot_or_net(turn, me, target, events)

	# No clean shot: a Sniper holds an overwatch lane instead of walking into the open.
	if _has_overwatch_kit(me) and not me.overwatch:
		if _try(turn, OverwatchCommand.new(me.id), events):
			return true

	# Still no shot → reposition toward the target to CLOSE range / SEEK line of sight
	# (obstacle-aware step) rather than idling behind a wall (W2-8). Was: only stepped when
	# d > HOLD_DISTANCE, so a ranged unit that had range but no LoS just sat uselessly.
	return _step_toward(ai, turn, me, target.pos, events)


## Does `me` have both weapon range and clear line of sight to `target`?
static func _has_shot(state, me, target) -> bool:
	return ShootCommand.has_range(me.pos, target.pos) and ShootCommand.in_los(state, me.pos, target.pos)


## Fire the shooter's attack at `target`: a Net Gunner nets (immobilize, §12); everyone
## else takes the plain shot. Returns true if a command was issued.
static func _shoot_or_net(turn, me, target, events: Array) -> bool:
	if me.name == "net_gunner":
		if _net(turn, me, target, events):
			return true
	return _try(turn, ShootCommand.new(me.id, target.id), events)


# ------------------------------------------------------------------- flanker ----
## Hound: fast approach to a FLANK angle (a tile diagonal to the target so the shot
## bypasses cover, §5.4), then strike. Bait-able into hazards — uses the same passable
## check as everyone, so a telegraphed tile is avoided (the bait works).
static func _flanker(ai, turn, me, events: Array) -> bool:
	var state = turn.state
	var target = ai._nearest_player(state, me)
	if target == null:
		return false

	# On contact: slam the target (the pounce).
	if ai._manhattan(me.pos, target.pos) == 1:
		var into: Vector2i = target.pos - me.pos
		if abs(into.x) + abs(into.y) == 1 and target.movable:
			if _try(turn, SlamCommand.new(me.id, target.id, into, E.SLAM_FORCE), events):
				return true
		if ShootCommand.has_range(me.pos, target.pos) and ShootCommand.in_los(state, me.pos, target.pos):
			if _try(turn, ShootCommand.new(me.id, target.id), events):
				return true
		return false

	# Otherwise move toward the nearest flank tile (diagonal-adjacent to the target).
	var flank: Vector2i = _best_flank_tile(state, me, target)
	if flank != me.pos:
		return _step_toward(ai, turn, me, flank, events)
	return _step_toward(ai, turn, me, target.pos, events)


# ------------------------------------------------------------------- support ----
## Drone Operator: hang back out of harm's way and DEPLOY a bot (spawns a turret-like
## ally). Deterministic: deploys at most once per fight (tracked via overwatch_used as a
## one-shot flag we don't otherwise use on this unit), then kites to keep its distance.
static func _support(ai, turn, me, events: Array) -> bool:
	var state = turn.state
	var target = ai._nearest_player(state, me)
	if target == null:
		return false
	var d: int = ai._manhattan(me.pos, target.pos)

	# Deploy a bot once, while there is AP and no bot deployed yet.
	if not me.overwatch_used:
		if _deploy_bot(state, me, events):
			me.overwatch_used = true
			turn.spend(me.id, 1)
			return true

	# Too close → back away to keep the support distance.
	if d < SUPPORT_DISTANCE:
		var away: Vector2i = _step_away(ai, state, me, target.pos)
		if away != me.pos:
			return _move_step(ai, turn, me, away, events)

	# In range with LoS → take a shot rather than waste the turn.
	if ShootCommand.has_range(me.pos, target.pos) and ShootCommand.in_los(state, me.pos, target.pos):
		if _try(turn, ShootCommand.new(me.id, target.id), events):
			return true
	return false


# --------------------------------------------------------------------- robot ----
## Security Robot: a heavy ram-bot — drives straight at the nearest player and slams on
## contact (high mass = a brutal billiards hit). A Sentry Turret (move 0) cannot move, so
## it degenerates to a static ranged hold (shoot if it can, else idle — destructible).
static func _robot(ai, turn, me, events: Array) -> bool:
	var state = turn.state
	# A turret (anchored / move-0) is static: behave as a stationary shooter.
	if me.mass == E.Mass.ANCHORED or me.phys_trait == E.PhysTrait.STATIC_DESTRUCTIBLE:
		var tt = ai._nearest_player(state, me)
		if tt != null and ShootCommand.has_range(me.pos, tt.pos) and ShootCommand.in_los(state, me.pos, tt.pos):
			if _try(turn, ShootCommand.new(me.id, tt.id), events):
				return true
		return false

	var target = ai._nearest_player(state, me)
	if target == null:
		return false
	if ai._manhattan(me.pos, target.pos) == 1:
		var into: Vector2i = target.pos - me.pos
		if abs(into.x) + abs(into.y) == 1 and target.movable:
			if _try(turn, SlamCommand.new(me.id, target.id, into, E.SLAM_FORCE + me.slam_force_bonus), events):
				return true
		if ShootCommand.has_range(me.pos, target.pos) and ShootCommand.in_los(state, me.pos, target.pos):
			if _try(turn, ShootCommand.new(me.id, target.id), events):
				return true
		return false
	return _step_toward(ai, turn, me, target.pos, events)


# ============================ shared movement / actions =======================
static func _step_toward(ai, turn, me, dst: Vector2i, events: Array) -> bool:
	var state = turn.state
	var step: Vector2i = ai._step_toward(state, me, dst)
	if step == me.pos:
		return false
	return _move_step(ai, turn, me, step, events)


static func _move_step(ai, turn, me, step: Vector2i, events: Array) -> bool:
	var state = turn.state
	if not _try(turn, MoveCommand.new(me.id, [step]), events):
		return false
	# A player overwatcher whose lane we entered gets a reaction shot (§5.5).
	var reactions: Array = OverwatchSystem.check_entry(state, me.id)
	for ev in reactions:
		turn.events.push_back(ev)
		events.push_back(ev)
	return true


static func _try(turn, cmd, events: Array) -> bool:
	var r: Dictionary = turn.try_command(cmd)
	if r.ok:
		for ev in r.events:
			events.push_back(ev)
		return true
	return false


## Net Gunner: immobilize the target (S_NETTED for NET_TURNS), Suppress it, and end the
## net-gunner's turn (the net shot is a turn-ender). Deterministic, no damage.
static func _net(turn, me, target, events: Array) -> bool:
	if turn.ap_for(me.id) < 1 or not target.is_unit or not target.alive:
		return false
	target.net_timer = E.NET_TURNS
	if not target.has_status(E.S_NETTED):
		target.add_status(E.S_NETTED)
	if not target.has_status(E.S_SUPPRESSED):
		target.add_status(E.S_SUPPRESSED)
		target.suppress_timer = 1
	events.push_back(GE.new(E.Ev.NET, {"watcher": me.id, "id": target.id, "turns": E.NET_TURNS}))
	turn.spend(me.id, 1)
	turn.end_unit(me.id)
	return true


# ============================ profile helpers =================================
## One orthogonal step that INCREASES distance from `dst` (kiting). Stable DIRS4 order.
static func _step_away(ai, state, me, dst: Vector2i) -> Vector2i:
	var here: Vector2i = me.pos
	var cur_d: int = ai._manhattan(here, dst)
	var best: Vector2i = here
	var best_d: int = cur_d
	for d in DIRS4:
		var np: Vector2i = here + d
		if not ai._passable(state, np):
			continue
		var nd: int = ai._manhattan(np, dst)
		if nd > best_d:
			best_d = nd
			best = np
	return best


## The passable tile diagonally adjacent to the target that is nearest to `me` — the
## flank position (a diagonal approach bypasses frontal cover, §5.4). Stable scan.
static func _best_flank_tile(state, me, target) -> Vector2i:
	var diags := [Vector2i(-1, -1), Vector2i(1, -1), Vector2i(-1, 1), Vector2i(1, 1)]
	var best: Vector2i = me.pos
	var best_d: int = 1 << 30
	for dg in diags:
		var fp: Vector2i = target.pos + dg
		if not state.in_bounds(fp):
			continue
		var t = state.tile(fp)
		if t.terrain == E.Terrain.WALL or t.hazard == E.Hazard.GAP:
			continue
		if state.occupant_at(fp) != null and fp != me.pos:
			continue
		var d: int = abs(me.pos.x - fp.x) + abs(me.pos.y - fp.y)
		if d < best_d:
			best_d = d
			best = fp
	return best


## Deploy a small bot ally next to the operator (Drone Operator support). Spawns a
## low-HP ranged ENEMY-faction unit on the first open orthogonal tile. Deterministic.
static func _deploy_bot(state, me, events: Array) -> bool:
	for d in DIRS4:
		var np: Vector2i = me.pos + d
		if not state.in_bounds(np):
			continue
		var t = state.tile(np)
		if t.terrain == E.Terrain.WALL or state.occupant_at(np) != null or t.hazard == E.Hazard.GAP:
			continue
		var bot := SimEntity.new()
		bot.is_unit = true
		bot.pos = np
		bot.mass = E.Mass.LIGHT
		bot.hp = 3
		bot.integrity = -1
		bot.faction = E.Faction.ENEMY
		bot.name = "deployed_bot"
		bot.ai_profile = E.AIProfile.ROBOT
		state.add_entity(bot)
		events.push_back(GE.new(E.Ev.BOT_DEPLOY, {"owner": me.id, "bot": bot.id, "pos": np}))
		return true
	return false


## Does this unit carry an overwatch-arming ability (Sniper)? Detected by name marker so
## the profile stays data-light; the content kit gives the Sniper "sniper_overwatch".
static func _has_overwatch_kit(me) -> bool:
	return me.name == "sniper"


## The cardinal (N/E/S/W) push-direction that a shove FROM the far end of `delta` would
## apply — the dominant axis of `delta` (= me.pos - foe.pos). The resolver blocks a shove
## whose dir == e.facing, so pointing facing this way BLOCKS a head-on shove from that foe
## and FOLDS to a flank/rear shove (W2-3). Integer-only, deterministic tiebreak to +x.
static func _face_dir(delta: Vector2i) -> Vector2i:
	if abs(delta.x) >= abs(delta.y):
		if delta.x > 0:
			return Vector2i(1, 0)
		if delta.x < 0:
			return Vector2i(-1, 0)
	else:
		if delta.y > 0:
			return Vector2i(0, 1)
		if delta.y < 0:
			return Vector2i(0, -1)
	return Vector2i(1, 0)


## Wake trigger for an Unaware (ambush-start) enemy (E1.7 / W2-4): the fight has reached it
## once it has TAKEN DAMAGE or a player unit is ADJACENT. Kept tight (a player merely visible
## at range does NOT wake it) so the operator's free opening round is preserved. Deterministic.
static func _fight_joined(ai, state, me) -> bool:
	if me.max_hp > 0 and me.hp < me.max_hp:
		return true
	var foe = ai._nearest_player(state, me)
	return foe != null and ai._manhattan(me.pos, foe.pos) <= 1
