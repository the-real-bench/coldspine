class_name RunController
extends Node2D
## Task #11 — the END-TO-END playable run. Owns a RunState and drives a full run from the
## Draft, through the seeded line (combat cars via TurnManager + CarView + InputIntent +
## EnemyAI; non-combat cars via simple screens that drive the real RunState economy rails),
## into the EngineVault finale, to a resolved ending. The headless `tests/run_smoke.gd`
## drives this controller's HEADLESS path (no display) with scripted inputs; the on-screen
## path adds the interactive combat loop + the per-car screens.
##
## OWNERSHIP (task #11): render/ + app/ + project.godot main_scene only. It CONSUMES the core
## APIs (RunState / Draft / SetpieceLoader / TurnManager / EnemyAI / EngineVault / endings) —
## it never edits them. Where the core loaders hardcode a bruiser+marksman starter pair (a
## documented Phase-0i placeholder), this controller strips those and places the DRAFTED squad
## on the same spawn points via UnitInstance.to_sim_entity() — closing the squad-loading gap
## without touching core.
##
## Determinism: the whole run is reproducible from `seed` — the line, the Draft picks, and the
## scripted/AI-resolved combats all derive their IntRng off the seed, so the same seed reaches
## the same ending + line (asserted in run_smoke).

const E = preload("res://core/sim_enums.gd")
const GE = preload("res://core/game_event.gd")

const SimState = preload("res://core/sim_state.gd")
const SimEntity = preload("res://core/sim_entity.gd")
const IntRng = preload("res://core/int_rng.gd")
const TurnManager = preload("res://core/turn_manager.gd")
const EnemyAI = preload("res://ai/enemy_ai.gd")
const MoveCommand = preload("res://core/commands/move_command.gd")
const ShootCommand = preload("res://core/commands/shoot_command.gd")
const ShoveCommand = preload("res://core/commands/shove_command.gd")
const SlamCommand = preload("res://core/commands/slam_command.gd")
const ThrowCommand = preload("res://core/commands/throw_command.gd")
const AbilityCommand = preload("res://core/commands/ability_command.gd")
const UseItemCommand = preload("res://core/commands/use_item_command.gd")   # W6-1: pilot uses consumables/gadgets
const AbilitySystem = preload("res://core/ability_system.gd")   # ACTIVE_KINDS registry (which picks are castable)
const OverwatchCommand = preload("res://core/commands/overwatch_command.gd")
const PhysicsResolver = preload("res://core/physics_resolver.gd")
const CaptainSystem = preload("res://core/captain_system.gd")

const RunState = preload("res://core/run/run_state.gd")
const Recon = preload("res://core/run/recon.gd")
const ContentDB = preload("res://core/units/content_db.gd")
const Draft = preload("res://core/units/draft.gd")
const Recruitment = preload("res://core/units/recruitment.gd")
const Betrayer = preload("res://core/units/betrayer.gd")   # C3.5 Conductor's Kin defection beat
const UnitInstance = preload("res://core/units/unit_instance.gd")
const SetpieceLoader = preload("res://core/setpiece_loader.gd")
const ModifierSystem = preload("res://core/run/modifier_system.gd")
const EngineVault = preload("res://core/finale/engine_vault.gd")
const FinaleEndings = preload("res://core/finale/endings.gd")
const BleedoutSystem = preload("res://core/bleedout_system.gd")

const CarView = preload("res://render/car_view.gd")
const EventPlayer = preload("res://render/event_player.gd")
const PreviewGhost = preload("res://render/preview_ghost.gd")
const OpsHUD = preload("res://render/ops_hud.gd")
const Iso = preload("res://render/iso.gd")
const Pal = preload("res://render/palette.gd")

const CombatTips = preload("res://app/combat_tips.gd")
const CarLoader = preload("res://app/car_loader.gd")
const InputIntent = preload("res://app/input_intent.gd")
const RunScreens = preload("res://app/screens/run_screens.gd")
const Legacy = preload("res://core/meta/legacy.gd")
const Leveling = preload("res://core/leveling.gd")          # grant_xp / choice_for_level / choose_ability (S3-LEVELUP)
const Unlocks = preload("res://core/meta/unlocks.gd")       # award_meta_currency (win-or-lose payout)
const SaveSystem = preload("res://core/meta/save_system.gd") # load/save the persistent MetaProfile
const Menu = preload("res://app/menu.gd")           # exposes Menu.MenuHandoff (the static handoff holder)

const VIEW_SIZE := Vector2(1280, 720)
const CARS_DIR := "res://content/cars/"
const DEFAULT_SEED := 0xC01D5
const COMBAT_GUARD_ROUNDS := 60   # headless auto-combat safety cap (rounds before a car is conceded)
# W7-10: rounds-remaining marks at which the MANUAL loop warns the operator the guard is closing in, so a
# long fight never converts to a silent LOSS with no notice (see _combat_guard_warning).
const COMBAT_GUARD_WARN_AT := [10, 5, 3, 1]

# W3-1/W3-2: the Black-Market stock pool — REAL content/items ids (all consumable/gadget slots, so a
# bought item shows in the ITEM popup and fires UseItemCommand). Replaces the phantom field_kit/
# stim_patch ids that matched no ItemDef. Each shop stocks a deterministic rotating subset of this
# pool (see _shop_stock) so a run can obtain several distinct authored items, not the same two forever.
const SHOP_POOL := [
	"medkit", "flashbang", "smoke_canister", "stun_grenade",
	"incendiary_grenade", "breaching_charge", "grapple", "portable_junction_box",
]
const SHOP_STOCK_COUNT := 3       # distinct items a single shop offers
const SHOP_STOCK_SALT := 0x5109   # folds into (seed, position) for an independent stock stream

# W3-2 (item reachability): the EQUIPMENT half of the Black-Market stock — the authored WEAPONS + ARMOR
# that had zero acquisition path (the consumable-only SHOP_POOL never carried them). The on-screen shop
# offers a deterministic rotating pair from this pool ALONGSIDE the consumable stock, keyed off an
# INDEPENDENT (seed^position) stream (its own salt — never the combat to-hit rng, never the consumable
# stock stream). A bought weapon/armor auto-equips onto the lead (attach -> inventory) and rides into
# combat via UnitInstance.to_sim_entity -> _apply_gear_to_entity, conferring its passive stat / armor
# effect (verified: marksman_rifle +10 accuracy, scrap_vest +2 HP, riot_plate +4 HP & first-hit soak).
# Headless auto-run (_do_shop / _shop_stock) is UNCHANGED — this rides the interactive shop only, so
# every determinism/run_smoke fixture stays byte-identical.
const EQUIP_POOL := [
	# weapons (all 9 authored — none had a path before)
	"pipe_wrench", "maul", "riot_baton", "fire_axe", "scrap_pistol",
	"shove_shotgun", "marksman_rifle", "incendiary_launcher", "harpoon_gun",
	# armor (scrap_vest/riot_plate/magnetic_boots/gas_mask/thermal_suit had no path; ablative_harness
	# is also a meta-unlock but stocks here too — a run without the unlock can still find it)
	"scrap_vest", "riot_plate", "magnetic_boots", "gas_mask", "thermal_suit", "ablative_harness",
]
const EQUIP_STOCK_COUNT := 2      # weapon/armor slots a single shop offers alongside its consumables
const EQUIP_STOCK_SALT := 0x7A11  # independent (seed, position) stream for the equipment stock

# W3-6: TAIL meta-unlock starting-resource bonuses (app-layer economy tuning — meta lives OUTSIDE
# the integer sim, so these are plain app consts, not core sim_enums). Applied once at run start
# for an owner who bought the tail upgrade.
const TAIL_UNLOCK_SCRIP := 8
const TAIL_UNLOCK_SUPPLIES := 2

# --- run model ---
var seed: int = DEFAULT_SEED
var db: ContentDB
var run: RunState
var ending: int = -1
var headless: bool = false

# --- menu→run handoff (task #11 P0): staged by consume_handoff() from Menu.MenuHandoff. The
# headless smoke/balance tests call drive_full_run() directly and never touch these, so the
# from-seed deterministic path is byte-identical to before (handoff is strictly opt-in). ---
var allow_list: Array = []          # OWNED car unlock ids (additive gate; [] = none owned)
var class_pool: Array = []          # W3-5: unlocked starting-class archetype ids ([] = every class;
                                    # the byte-stable headless default). Gates the Draft candidate roll.
var legacy_payload: Dictionary = {} # one {kind:item|trait, id, from} to apply to a drafted unit
var legacy_source_id: String = ""   # Memorial hero id behind the payload — burned at BREACH (W1-7)
var resume_run = null               # a loaded mid-run RunState to continue (or null = fresh)
# Live session settings staged from the menu (Menu.MenuHandoff.settings). Consumed at runtime:
# confirm_moves gates the two-tap MOVE commit; in_car_fog overrides the per-run fog; sfx/music
# volume feed the audio hook (stage 3). Empty on the headless/from-seed path (defaults apply).
var _settings: Dictionary = {}
# instance_ids the operator chose to DEPLOY this combat car ([] = deterministic auto-pick top-3).
# Set by the pre-combat DEPLOY picker (on-screen) or the deploy_pick_scripted test seam; consumed
# by _place_squad, then cleared after each car so the next car re-picks.
var _forced_deployment: Array = []
# --- interactive DEPLOY picker state (on-screen only; idle headless) ---
var _awaiting_deploy: bool = false
var _deploy_action: String = ""
var _deploy_selected: Array = []      # instance ids currently toggled to deploy
var _deploy_need: int = 3             # how many tiles (= how many must be picked)
var _deploy_members: Array = []       # living UnitInstances shown in the picker (row order)

# --- on-screen wiring (null in headless) ---
var view: CarView
var player: EventPlayer
var ghost: PreviewGhost
var hud: OpsHUD
var intent: InputIntent
var screens: RunScreens

# --- combat onboarding tips (combat-ux #7; on-screen-only, null/idle headless + in --sim AUTO) ---
# `_tip_profile` is the on-disk MetaProfile loaded once at chrome build, the persistence home of the
# seen-tips set + the tips_enabled switch. `_tips` is the pure CombatTips decision object (catalog +
# seen bookkeeping). Both null headless — every tip path is gated behind `not headless and not sim_mode`,
# so the byte-stable suites never load a profile, build a tip, or touch user://.
var _tip_profile = null
var _tips = null

# --- active combat car state ---
var state                 # SimState of the car being fought
var turn                  # TurnManager
var ai                    # EnemyAI
var _active_combat: bool = false
# On-screen-only end-of-run state. Set TRUE in _show_ending once a run resolves (loss OR any
# ending). While set, _unhandled_input routes any key/click to leave the sticky ending screen
# (ENTER/SPACE/click/ESC -> menu, N -> new run), combat keys no-op, and _process stops ticking.
# Never set on the headless drivers — they never reach _show_ending's on-screen branch.
var _run_over: bool = false
# On-screen-only TWO-STEP end-of-run (S6-1 -> S6-2). _show_ending shows the ENDING CARD and runs the
# real reconciliation (award meta-currency, enshrine the fallen, bump stats, persist ONCE) into
# _payout_ledger, then arms _run_over. The FIRST ENTER/CLICK advances the ENDING CARD to the PAYOUT
# LEDGER (sets _payout_shown). The SECOND ENTER/CLICK leaves to the console (or N -> new run at any
# point). Never set headless — _finalize_run / the ledger are gated behind `not headless`.
var _payout_shown: bool = false
var _payout_ledger: Dictionary = {}

# Combat control mode. TRUE = SIM/SKIP: the deterministic auto-pilot resolves the player phase
# (the headless tests + an on-screen "skip" button use this). FALSE = PLAYER: a human drives the
# turn through InputIntent (select unit -> choose action -> point tile [preview ghost] -> confirm).
# Defaults TRUE so every headless driver (run_smoke / balance_smoke) auto-pilots exactly as before.
var sim_mode: bool = true

# W6-2: AUTO SCOPE. "fight" = this-car-only (the default when the operator engages AUTO): auto-pilot
# THIS combat, then hand back to MANUAL at car clear so no permanent level-up / scrip / Order pick is
# silently auto-committed on the following cars. "run" = the explicit whole-run opt-in (and the headless
# --sim proof default). Headless never toggles it — the byte-stable drivers ignore scope entirely.
var _auto_scope: String = "run"

# W6-11: the one-per-run betrayer VET scan has been spent (persists for the run).
var _betrayer_scan_used: bool = false

# --- on-screen interactive control (null/idle in headless) ---
var _awaiting_player: bool = false   # TRUE while the interactive loop is blocked on operator input
var _player_phase_done: bool = false # set by END / out-of-AP to release the await in the interactive loop
var _onscreen_speed: float = 1.0     # animation speed multiplier (SPEED cycles 1x/2x/4x)

# --- on-screen INTERACTIVE DRAFT (S2; null/idle in headless). The draft phase blocks on operator
# input through the RunScreens draft surface (card taps + control bar) until a take/decline/quick
# advances it, then the BREACH_CONFIRM overlay launches the run. None of this runs headless or in
# --sim AUTO mode — both take the deterministic _run_draft auto-pick path, so the suites are unmoved.
var _draft: Draft = null             # the live interactive Draft (on-screen only)
var _draft_action: String = ""       # one of: "" / "take:<idx>" / "decline" / "auto" / "breach"
var _awaiting_draft: bool = false    # TRUE while the draft phase waits on the operator
var _breach_action: String = ""      # one of: "" / "go" / "back"
var _awaiting_breach: bool = false   # TRUE while the BREACH_CONFIRM overlay waits on the operator
var _in_draft: bool = false          # TRUE while the interactive draft surface is up (routes ESC)
var _breach_locked: bool = false     # loading-lock so [BREACH — GO] can't double-fire the run
const ONSCREEN_BEAT := 0.16          # base per-event pacing on-screen (seconds, before speed scaling)

# --- on-screen INTERACTIVE ECONOMY CARS (S3; null/idle in headless). Each non-combat car blocks on
# operator input through the RunScreens econ surface (OPTION ROW taps + LEAVE) until a commit/leave
# resolves it. NEVER runs headless or in --sim AUTO mode — both take the deterministic _do_* auto-
# default, so the suites + balance are unmoved. _econ_action is one of: "" / "commit:<opt>" /
# "leave" — the async phase consumes it. _in_econ routes ESC to the safe-default leave. ---
var _econ_action: String = ""        # "" / "commit:<opt>" / "leave"
var _awaiting_econ: bool = false     # TRUE while an econ car waits on the operator
var _in_econ: bool = false           # TRUE while an econ surface is up (routes ESC/number keys)
var _econ_recruit_candidate = null   # the PRE-ROLLED recruit (so the dossier shows before commit)

# --- on-screen PLAYER-DRIVEN FINALE (Batch 3; null/idle in headless + in --sim AUTO). The on-screen
# finale lets the OPERATOR fight the vault: antechamber turrets/robots via normal combat (InputIntent),
# then TARGET RELAYS (two-tap a relay tile to break it -> drops the core shield), then TARGET THE CORE
# (two-tap the exposed core to sabotage it -> win). The Conductor cadence + Bridge Countdown still tick
# each round. NEVER runs headless or in --sim AUTO — both take the byte-stable scripted _drive_finale /
# _drive_finale_onscreen-AUTO path (_break_one_relay / _try_sabotage), so the suites are unmoved. ---
var _vault = null                     # the live EngineVault during an on-screen player-driven finale
var _in_finale: bool = false          # TRUE while the on-screen finale arena is up (routes obj-targeting)
var _finale_phase_done: bool = false  # set to release the per-round await (END / out-of-AP / AUTO)
var _obj_target_id: int = -1          # the relay/core entity the operator has armed for a two-tap
var _obj_last_tap: Vector2i = Vector2i(-9999, -9999)   # last tapped obj tile (two-tap confirm)
var _finale_divider_x: int = 8        # W4-2: the inner-vault divider column (cross it to wake the Conductor)
var _finale_enemies_at_entry: int = -1 # W4-2: live antechamber defenders at vault entry (first-down trigger)

# --- LEVEL-UP (S3-LEVELUP; Batch 5; on-screen only). XP is awarded ONLY in the on-screen run loop
# (per enemy killed / per car cleared), NEVER in the headless path — the byte-stable suites drive
# drive_full_run() directly and must stay XP-free. A unit that crosses a level threshold leaves a
# PENDING PICK (level rose but chosen_abilities lags the offered tier); the RunScreens LEVEL-UP overlay
# resolves the queue one unit at a time before the next car. A never-stuck safety auto-picks option 0.
# The real Leveling API does all the work (grant_xp / choice_for_level / choose_ability); we never edit it.
const XP_PER_KILL := 12        # XP per enemy a surviving unit helped remove (on-screen award)
const XP_PER_CAR := 8          # XP every surviving unit earns for clearing a combat car
var _levelup_action: String = ""      # "" / "pick:<ability_id>" — set by the overlay signal handler
var _awaiting_levelup: bool = false   # TRUE while the level-up overlay waits on the operator
var _in_levelup: bool = false         # TRUE while the level-up modal is up (routes 1/2/ENTER keys)
var _last_combat_kills: int = 0       # enemies removed in the just-resolved on-screen combat (XP source)

# trace the smoke test / lead read (car sequence + outcomes)
var trace: Array = []


func _ready() -> void:
	headless = _is_headless()
	if db == null:
		db = ContentDB.new()
	# Pull the operator's menu choices (unlocked content allow-list + chosen Legacy + a resume
	# save) staged by app/menu.gd. Only the on-screen scene flow does this; tests drive the
	# controller directly, so their from-seed runs stay deterministic.
	consume_handoff()
	if not headless:
		_build_onscreen_chrome()
		# ON-SCREEN: drive the run INTERACTIVELY with ANIMATED playback. Combat cars route each
		# player phase through InputIntent + the HUD (select unit -> action -> target tile -> confirm)
		# unless AUTO is on (sim_mode==true), which lets the deterministic auto-pilot finish the fight.
		# The whole line is animated (await play_animated) so it PLAYS rather than snapping to the end.
		#
		# A windowed unattended/AUTO run is forced via the `--sim` CLI flag (or `coldspine_sim=true`):
		# it sets sim_mode=true + a fast speed so the build plays itself to an ending for the proof.
		# The five headless suites call drive_full_run()/drive_to_finale()/play_player_turn() DIRECTLY
		# (headless==true), so they never touch this async/animated path — it stays byte-stable.
		_apply_launch_flags()
		set_process_unhandled_input(true)
		set_process(true)
		await get_tree().process_frame
		await drive_full_run_onscreen()


# ============================ public entry ====================================
## Build a fresh run from `p_seed`: run the Draft (auto-picks in headless / scripted), generate
## the line, then advance car-by-car to an ending. Returns the resolved EndingId.
func drive_full_run(p_seed: int = -1, draft_take: int = 3) -> int:
	if p_seed >= 0:
		seed = p_seed
	trace.clear()
	# A resume save short-circuits the Draft + line generation: continue the loaded run in place.
	if resume_run != null:
		run = resume_run
		seed = run.seed
		_log_hud("> RESUME — seed %d, car %d/%d." % [seed, run.position + 1, run.line.size()])
		trace.append("RESUME: car %d/%d, squad %d" % [run.position + 1, run.line.size(), run.squad.size()])
		_advance_line()
		return ending
	_run_draft(draft_take)
	_log_hud("> RUN START — seed %d, squad %d." % [seed, run.squad.size()])
	trace.append("DRAFT: %d starters (payout x%d)" % [run.squad.size(), run.draft_payout_mult])
	_advance_line()
	return ending


## Stage the operator's menu choices (Menu.MenuHandoff) onto this controller: the unlocked-car
## allow-list, a chosen Legacy payload to apply to a drafted unit at run start, and a mid-run
## resume save to continue. Reads the static holder and clears it so a choice isn't re-applied to
## the next controller. Safe to call on the headless path (the holder is empty there).
func consume_handoff() -> void:
	var H = Menu.MenuHandoff
	allow_list = (H.unlocked_car_ids as Array).duplicate()
	class_pool = (H.unlocked_class_ids as Array).duplicate()   # W3-5: gate the Draft to unlocked classes
	legacy_payload = (H.legacy_payload as Dictionary).duplicate(true)
	legacy_source_id = String(H.legacy_id)
	resume_run = H.resume_run
	_settings = (H.settings as Dictionary).duplicate(true)
	# W1-5: a staged fresh seed (real player path) overrides DEFAULT_SEED; -1 (headless/--sim/
	# tests — the holder's reset value) keeps the byte-stable fixed seed exactly as before.
	if int(H.run_seed) >= 0:
		seed = int(H.run_seed) & 0xFFFFFFFF
	H.reset()


# ============================ live session settings ===========================
## SETTINGS applied at runtime (release-readiness #3). These read the session settings staged from
## the menu (Menu.MenuHandoff.settings), falling back to the documented defaults so a from-seed /
## headless run (empty _settings) behaves exactly as before.

## "Confirm before committing a move" — when false, a MOVE commits on the first tap (see
## _on_tile_clicked). Default true (the deliberate two-tap). App-side, no core/render change.
func _confirm_moves() -> bool:
	return bool(_settings.get("confirm_moves", true))

## In-car fog session override (owner-flagged E1.4). ANDs the operator's session toggle with the
## engine default so turning fog OFF in Settings actually removes it. The fog RENDER consumer (a
## render/ concern, not yet built) must AND this with the per-car flag; SetpieceFog.IN_CAR_FOG_ENABLED
## stays the DEFAULT source (owner rule — no silent default change). Exposed here as the app-side hook.
func fog_enabled() -> bool:
	return bool(_settings.get("in_car_fog", true))

## Does the CURRENT car request in-car fog (E1.4)? Reads the per-car `inCarFog` template flag (the
## Hedge Maze / heavy Steam rooms author it true; every other car is false — the E1.4 default). The
## owner ANDs this with fog_enabled() to drive the CarView fog consumer. Reads the spec-default flag —
## never mutates it (owner rule). On-screen-only (its sole caller, _bind_combat_view, returns early
## when headless), so the byte-stable headless path never computes fog.
func _car_requests_fog() -> bool:
	var car = run.current_car()
	if car == null:
		return false
	var data = _read_json(CARS_DIR + car.template_id + ".json")
	return data != null and bool(data.get("inCarFog", false))

## Session volume (0..100) for `bus` in {"sfx","music"}. AUDIO HOOK (release-readiness #3/#5): the
## audio bus layer is stage 3's deliverable. When an AudioDirector autoload exists it receives these;
## until then this is a documented, side-effect-free hook (never crashes, never touches the sim).
func apply_audio_settings() -> void:
	if headless:
		return
	# STAGE 3 HOOK: route _settings.sfx_volume / _settings.music_volume to the audio buses here, e.g.
	#   if Engine.has_singleton("AudioDirector"): AudioDirector.set_volume("sfx", _settings.get("sfx_volume", 100))
	# Left as a hook (no buses exist yet) so wiring it later is a one-liner, not a re-architecture.
	pass


# ============================ mid-run save / resume ===========================
## Persist the in-progress run to the Continue slot (release-readiness #0). Called at every
## BETWEEN-CAR checkpoint so quitting — or the OS killing the app — never silently loses a run,
## and the menu's CONTINUE lights up. The save is CAR-GRANULAR: resume re-enters the current car
## from the run's seed (the deterministic sim reproduces the fight), so mid-combat state need not
## be serialized (RunState.to_dict round-trips seed + position + squad + currency + order). Gated
## behind `not headless` so the byte-stable suites never touch user:// (they drive the controller
## directly and never reach this). No-op once the run is over (finalize clears the slot — permadeath
## stays sacred) or before a run exists.
func _save_run_checkpoint() -> void:
	if headless or run == null or _run_over or run.is_won():
		return
	SaveSystem.save_run(run)


## OS lifecycle hook: save the live run when the window is closing or the app is backgrounded
## (Android may kill a paused app), so an interrupted run is recoverable. On a close request we
## save then let the default quit proceed. On-screen-only (headless has no window events).
func _notification(what: int) -> void:
	if headless:
		return
	match what:
		NOTIFICATION_WM_CLOSE_REQUEST, NOTIFICATION_APPLICATION_PAUSED:
			_save_run_checkpoint()


## VERIFICATION HARNESS (not a gameplay path): drive a run to the Engine and run the REAL
## finale + ending, with the COMBAT cars fast-forwarded as "assumed cleared" (the squad is left
## intact). This exists to prove the finale + endings WIRING end-to-end deterministically, while
## `drive_full_run` proves the line/combat/economy wiring with real combat. Non-combat cars are
## resolved for real (their economy rails run). Returns the resolved EndingId.
##
## Why split: the launch content's combat is genuinely lethal to a fragile 3-unit cell across a
## ~20-car line (a balance finding for the lead, not a wiring bug), so a natural run reliably
## ends in LOSS before the Engine. This harness isolates the finale wiring so it is provably
## exercised regardless of combat balance.
func drive_to_finale(p_seed: int = -1, draft_take: int = 3) -> int:
	if p_seed >= 0:
		seed = p_seed
	trace.clear()
	_run_draft(draft_take)
	trace.append("DRAFT: %d starters (payout x%d) [finale-verify]" % [run.squad.size(), run.draft_payout_mult])
	var guard: int = 0
	while not run.is_won() and guard < 256:
		guard += 1
		var car = run.current_car()
		if car == null:
			break
		_refresh_recon_hud()
		if car.car_type == E.CarType.ENGINE:
			_run_finale(car)
			run.resolve_current()
			run.advance()
			break
		if car.is_combat():
			# Fast-forward: assume cleared (squad preserved). Labeled in the trace as such.
			trace.append("CAR %d [%s/%s]: ASSUMED-CLEARED [finale-verify]" % [run.position, _type_name(car.car_type), car.template_id])
			run.resolve_current()
		else:
			_resolve_screen_car(car)
		run.collect_reward()
		run.advance()
	if ending == -1 and run.is_won():
		_resolve_from_run(true)
	return ending


# ============================ the Draft (§7.1) ================================
## Auto-run the Draft: take up to `take_n` candidates (default 3 = full cell), then generate
## the run line from the seed and instantiate the RunState. Deterministic from the seed.
func _run_draft(take_n: int) -> void:
	var draft_rng := IntRng.new((seed ^ 0xDEADBEEF) & 0xFFFFFFFF)
	var draft := Draft.new(db, draft_rng)
	draft.allowed_archetypes = class_pool   # W3-5: locked classes never enter the candidate pool
	draft.start()
	var taken: int = 0
	# Each round offers 3 candidates; a SKILLED operator takes the strongest, not blindly the
	# first card. We score each candidate (effective HP + accuracy + trait quality + a frontline
	# composition bonus) and take the best — exactly what a human would do at the draft. Fully
	# deterministic (the score is a pure function of the rolled candidate). This is the single
	# biggest survivability lever: a fragile, negative-trait cell can't clear a captain gate.
	while not draft.finished and taken < take_n:
		var before: int = draft.picks.size()
		var pick_idx := _best_draft_pick(draft.current_choices, draft.picks)
		draft.take(pick_idx)
		if draft.picks.size() > before:
			taken += 1
	if not draft.finished:
		draft.stop()
	_finalize_run_from_draft(draft)
	if screens != null:
		screens.show_draft(run)


## Build the RunState from a FINALIZED Draft: gate the line by the unlocked-car allow-list, apply
## the one chosen Legacy to the first drafted unit, and write the draft-picks trace. Shared by the
## headless auto path (_run_draft) AND the interactive on-screen path so BOTH produce a byte-identical
## run for the same (seed, picks): the construction order, gate, payout mult, and legacy application
## are exactly as the auto path always did. Deterministic — no rng here.
func _finalize_run_from_draft(draft) -> void:
	var squad: Array = draft.picks
	# A non-empty owned-car set gates line generation ADDITIVELY (only catalog setpieces gate
	# on ownership — RunGenerator._is_unlocked); an empty list means "every authored car"
	# (a fresh profile — the historical full-deck behavior).
	var gate = allow_list if not allow_list.is_empty() else null
	run = RunState.new_run(seed, squad, draft.draft_payout_mult, gate)
	if not run.squad.is_empty():
		var names: Array = []
		for u in run.squad:
			names.append("%s[%s]" % [u.archetype_id, str(u.traits)])
		trace.append("DRAFT-PICKS: %s" % str(names))
	# Apply the single chosen Legacy (an item or a non-betrayer trait) to the first living
	# drafted unit at run start (§7.4 — one legacy per run). Deterministic: first squad member.
	if not legacy_payload.is_empty() and not run.squad.is_empty():
		var heir = run.squad[0]
		if Legacy.apply_to_unit(heir, legacy_payload):
			# Re-derive max HP so a +hp trait legacy takes effect on the body this run.
			heir.max_hp = max(1, heir.max_hp)
			trace.append("LEGACY: %s '%s' from %s -> %s" % [
				String(legacy_payload.get("kind", "")), String(legacy_payload.get("id", "")),
				String(legacy_payload.get("from", "")), heir.name])
			# W1-7: the Legacy is BURNED here — at the point of application (BREACH finalize) —
			# not at NEW RUN click, so an ESC-abandoned draft leaves the profile untouched.
			_consume_armed_legacy()
	# W3-6: apply the profile's remaining meta unlocks (gear/tail/narrative) to the fresh run. Gated
	# behind `not headless` so the byte-stable auto/balance suites (which never load a profile) are
	# untouched; the pure seam apply_meta_unlocks_to_run() is called directly by the economy tests.
	if not headless:
		var prof = SaveSystem.load_profile()
		if prof != null:
			apply_meta_unlocks_to_run(prof.unlocked_content)


## W1-7: burn the armed Legacy on the PERSISTED profile now that its payload has applied to a
## drafted heir (BREACH finalize — the run has truly started). NOT-HEADLESS ONLY for the disk
## write: the byte-stable suites (which stage payloads without a Memorial id, or drive scripted
## drafts) never load or write user://. The pure mark step is split out so tests can drive it
## against an in-memory profile.
func _consume_armed_legacy() -> void:
	if headless or legacy_source_id == "":
		legacy_source_id = ""
		return
	var profile = SaveSystem.load_profile()
	if apply_legacy_consumption(profile):
		SaveSystem.save_profile(profile)


## W3-6: apply the profile's non-car/non-class meta unlocks to the freshly-built run — the PURE seam
## (no disk I/O; the economy tests drive it directly with an explicit owned list). Each catalog kind
## gets the smallest REAL consumer:
##   - GEAR  (ids ARE real ItemDefs after the catalog fix): the squad STARTS the run carrying it
##            (attached to the lead's inventory → rides into combat via to_sim_entity → real effect).
##   - TAIL  : a between-run starting-resource bonus (+scrip / +supplies) granted once at run start.
##   - NARRATIVE : a flavor/intel unlock — surfaced as a comms line + run trace beat.
##   - POOL  : TRIMMED from the catalog (no faithful in-lane consumer — see unlocks.gd note / report).
## Deterministic and additive; an empty owned list is a no-op.
func apply_meta_unlocks_to_run(owned_ids: Array) -> void:
	if run == null:
		return
	for oid in owned_ids:
		var id: String = String(oid)
		match Unlocks.kind(id):
			Unlocks.KIND_GEAR:
				if db != null and not db.item(id).is_empty() and not run.squad.is_empty():
					_attach_item_to_lead(id)
					trace.append("UNLOCK-GEAR: start carrying %s" % id)
			Unlocks.KIND_TAIL:
				match id:
					"tail_extra_scrip":
						run.earn("scrip", TAIL_UNLOCK_SCRIP)
						trace.append("UNLOCK-TAIL: +%d starting scrip" % TAIL_UNLOCK_SCRIP)
					"tail_extra_supplies":
						run.earn("supplies", TAIL_UNLOCK_SUPPLIES)
						trace.append("UNLOCK-TAIL: +%d starting supplies" % TAIL_UNLOCK_SUPPLIES)
			Unlocks.KIND_NARRATIVE:
				var nm: String = String(Unlocks.entry(id).get("name", id))
				trace.append("INTEL: %s" % nm)
				_log_hud("> INTEL DECRYPTED — %s" % nm)


## The pure consumption seam (NO disk I/O): mark the staged Memorial hero inherited on `profile`
## and clear the staged id. Returns true when a hero was actually burned. Idempotent — a second
## call (or an empty stage) is a no-op false.
func apply_legacy_consumption(profile) -> bool:
	if legacy_source_id == "" or profile == null:
		return false
	var burned: bool = Legacy.mark_inherited(profile, legacy_source_id)
	legacy_source_id = ""
	return burned


# ============================ INTERACTIVE DRAFT (S2; on-screen only) ==========
## The on-screen DRAFT phase: the operator vets candidates and breaches through the RunScreens
## surface. Mirrors _interactive_player_phase's wait-for-input shape (present round -> yield frames
## until the operator acts -> advance) over the REAL Draft model. NEVER runs headless or in --sim
## AUTO mode. Returns TRUE when the run was breached (RunState built, surface hidden, timecode live);
## FALSE only when the operator abandoned to the main menu (the scene is already changing).
##
## STATE MACHINE (no stuck states — every state has a forward exit + an ESC abandon):
##   VETTING(round) --TAKE(idx)--> draft.take; if !finished -> VETTING(next round) else -> CONFIRM
##                 --DECLINE-----> draft.decline; if !finished -> VETTING(next) else -> CONFIRM
##                 --QUICK--------> _best_draft_pick this round -> draft.take (== auto path) -> as TAKE
##                 --BREACH(>=1)--> draft.stop -> CONFIRM
##                 --ESC----------> abandon -> MAIN MENU
##   CONFIRM       --GO-----------> (loading-lock) build run -> hide surface -> RUN (timecode live)
##                 --BACK(!final)-> VETTING (re-deal the same finalized? no — only when not finalized)
##                 --ESC----------> abandon -> MAIN MENU
## The Draft's own no-repeat + cap guarantees (shown_and_removed / DRAFT_MAX_STARTERS / DRAFT_ROUNDS)
## mean VETTING always terminates: at most DRAFT_ROUNDS rounds, and picks can't exceed the cap.
func _run_draft_interactive() -> bool:
	# Build the Draft + rng EXACTLY as _run_draft does (same seed derivation) so the interactive
	# rolls are byte-identical to the auto path for this seed.
	var draft_rng := IntRng.new((seed ^ 0xDEADBEEF) & 0xFFFFFFFF)
	_draft = Draft.new(db, draft_rng)
	_draft.allowed_archetypes = class_pool   # W3-5: same class gate on the interactive path
	_draft.start()
	_in_draft = true
	_log_hud("> COMMS PATCHED — vetting volunteers. TAKE / DECLINE / QUICK DRAFT, then BREACH.")
	# VETTING loop: present the round, wait for the operator, apply, until the draft finalizes.
	while not _draft.finished:
		if screens != null:
			screens.show_draft_interactive(_draft, db, legacy_payload)
		var act: String = await _await_draft_action()
		if act == "abandon":
			_abandon_draft_to_menu()
			return false
		if act.begins_with("take:"):
			var idx := int(act.substr(5))
			if idx >= 0 and idx < _draft.current_choices.size():
				_draft.take(idx)
				_log_hud("> COPY — %d in the cell." % _draft.picks.size())
		elif act == "decline":
			_draft.decline()
			_log_hud("! DECLINE LOGGED — next three coming up.")
		elif act == "auto":
			# QUICK DRAFT this round = the deterministic _best_draft_pick (the auto path's choice).
			var pick_idx := _best_draft_pick(_draft.current_choices, _draft.picks)
			_draft.take(pick_idx)
			_log_hud("> QUICK DRAFT — auto-took the strongest card.")
		elif act == "breach":
			if _draft.picks.size() >= 1:
				break   # STOP & BREACH: do NOT stop() yet — defer finalize to GO so BACK stays reversible.
		# loop re-presents the (now advanced) round, or exits if finalized.
	# CONFIRM: raise BREACH_CONFIRM with the WOULD-BE locked payout, wait for GO/BACK/ESC. The draft
	# is finalized (stop()) only on GO, so an early STOP & BREACH (picks<3, rounds left) can still BACK
	# out to vet another round. Once the natural cap/rounds are spent (_draft.finished), BACK is gone.
	while true:
		var finalized: bool = _is_draft_finalized()
		var would_be_mult: int = _would_be_payout(_draft.picks.size())
		if screens != null:
			screens.show_draft_interactive(_draft, db, legacy_payload)
			screens.show_breach_confirm(_draft.picks, would_be_mult,
				E.DRAFT_MAX_STARTERS - _draft.picks.size(), finalized)
		var b: String = await _await_breach_action()
		if b == "abandon":
			_abandon_draft_to_menu()
			return false
		if b == "back" and not finalized:
			# Back to vetting — re-enter the VETTING loop (more rounds remain; nothing finalized yet).
			if screens != null:
				screens.hide_breach_confirm()
			var re: bool = await _vet_more_rounds()
			if not re:
				_abandon_draft_to_menu()
				return false
			# Either the operator hit BREACH again (re==true, not finished) or the draft finalized
			# while vetting — re-raise confirm in both cases (now locked if finished).
			continue
		if b == "go":
			break
	# BREACH — GO: finalize the draft (stop() if not already capped), build the run + launch. The
	# loading-lock (_breach_locked) makes a double-GO inert.
	if screens != null:
		screens.lock_breach()
	if not _draft.finished:
		_draft.stop()
	_finalize_run_from_draft(_draft)
	if screens != null:
		screens.hide_draft_surface()
	if hud != null:
		hud.set_running(true)   # the run clock starts the instant the coupling blows (S2 framing)
	_log_hud("> ALL UNITS — BREACHING. GO.")
	_in_draft = false
	_breach_locked = false
	return true


## A nested VETTING loop used when the operator hits BACK from a not-finalized confirm: present
## rounds + apply actions until the draft finalizes OR they breach/abandon again. Returns FALSE on
## abandon. Shares the exact action handling of the main VETTING loop.
func _vet_more_rounds() -> bool:
	while not _draft.finished:
		if screens != null:
			screens.show_draft_interactive(_draft, db, legacy_payload)
		var act: String = await _await_draft_action()
		if act == "abandon":
			_abandon_draft_to_menu()
			return false
		if act.begins_with("take:"):
			var idx := int(act.substr(5))
			if idx >= 0 and idx < _draft.current_choices.size():
				_draft.take(idx)
		elif act == "decline":
			_draft.decline()
		elif act == "auto":
			_draft.take(_best_draft_pick(_draft.current_choices, _draft.picks))
		elif act == "breach":
			# STOP & BREACH again — defer finalize to GO (same as the main loop); return to confirm.
			if _draft.picks.size() >= 1:
				return true
	return true


## The payout multiplier the draft WOULD lock at for `n` picks, without mutating the model (3->100,
## 2->125, 1->160; 0 falls back to x3). Mirrors draft._finalize's mapping for the live confirm readout.
func _would_be_payout(n: int) -> int:
	match n:
		1: return E.DRAFT_PAYOUT_X1
		2: return E.DRAFT_PAYOUT_X2
		_: return E.DRAFT_PAYOUT_X3


## Tear the draft surface down and return to the operator console (S2 ESC abandon — NO dead end,
## the run was never started). On-screen-only.
func _abandon_draft_to_menu() -> void:
	_in_draft = false
	_awaiting_draft = false
	_awaiting_breach = false
	if screens != null:
		screens.hide_draft_surface()
	_leave_to_menu()


## True once the Draft can no longer offer another round — the cap is hit (picks==3) or the rounds
## are spent (finished latched). BACK is hidden behind DRAFT LOCKED in this state.
func _is_draft_finalized() -> bool:
	return _draft.finished or _draft.picks.size() >= E.DRAFT_MAX_STARTERS


## Block until the operator commits a draft action (or ESC abandons). Yields frames so HUD/card
## clicks + key presses are delivered. Returns "take:<idx>" / "decline" / "auto" / "breach" /
## "abandon". A safety spin-cap can never hard-hang the window.
func _await_draft_action() -> String:
	_draft_action = ""
	_awaiting_draft = true
	var spins: int = 0
	while _awaiting_draft:
		if _draft_action != "":
			_awaiting_draft = false
			break
		await get_tree().process_frame
		spins += 1
		if spins > 5000000:
			_awaiting_draft = false
			return "abandon"
	var a := _draft_action
	_draft_action = ""
	return a


## Block until the operator hits GO / BACK on the BREACH_CONFIRM overlay (or ESC abandons).
func _await_breach_action() -> String:
	_breach_action = ""
	_awaiting_breach = true
	var spins: int = 0
	while _awaiting_breach:
		if _breach_action != "":
			_awaiting_breach = false
			break
		await get_tree().process_frame
		spins += 1
		if spins > 5000000:
			_awaiting_breach = false
			return "abandon"
	var b := _breach_action
	_breach_action = ""
	return b


# --- draft surface signal handlers (record the operator's choice; the async phase consumes it) ---
func _on_draft_take(idx: int) -> void:
	if _awaiting_draft:
		_draft_action = "take:%d" % idx

func _on_draft_decline() -> void:
	if _awaiting_draft:
		_draft_action = "decline"

func _on_draft_auto() -> void:
	if _awaiting_draft:
		_draft_action = "auto"

func _on_draft_breach() -> void:
	# STOP & BREACH is only meaningful at picks>=1 (the surface disables it otherwise).
	if _awaiting_draft and _draft != null and _draft.picks.size() >= 1:
		_draft_action = "breach"

func _on_breach_go() -> void:
	# Loading-lock: ignore a second GO while the run composes (no double _advance_line).
	if _awaiting_breach and not _breach_locked:
		_breach_locked = true
		_breach_action = "go"

func _on_breach_back() -> void:
	if _awaiting_breach:
		_breach_action = "back"


# ---------------------------- DRAFT TEST SEAM (headless-drivable) -------------
## VERIFIABLE INTERACTIVE-DRAFT SEAM (no display). Drive the interactive draft state machine from a
## list of scripted operator actions — the EXACT take/decline/auto/breach the RunScreens surface
## emits — over a fresh Draft built with the SAME seed derivation as the live path. Builds the run
## via _finalize_run_from_draft (the shared, byte-stable construction) and returns it, so a test can
## assert a valid 1-3 cell + the correct payout multiplier + determinism WITHOUT a SceneTree.
## Each step is a small dict the surface would emit from a tap:
##   {op:"take", idx:<i>}  {op:"decline"}  {op:"auto"}  {op:"breach"}
## Stops at the first breach (with picks>=1) or when the draft finalizes; then breaches if needed.
## Returns the built RunState (run). Deterministic — no rng beyond the seeded draft rolls.
func drive_draft_scripted(p_seed: int, scripted: Array):
	if p_seed >= 0:
		seed = p_seed
	if db == null:
		db = ContentDB.new()
	trace.clear()
	var draft_rng := IntRng.new((seed ^ 0xDEADBEEF) & 0xFFFFFFFF)
	var d := Draft.new(db, draft_rng)
	d.allowed_archetypes = class_pool   # W3-5: same class gate on the scripted-draft seam
	d.start()
	for step in scripted:
		if d.finished:
			break
		match String(step.get("op", "")):
			"take":
				var idx := int(step.get("idx", 0))
				if idx >= 0 and idx < d.current_choices.size():
					d.take(idx)
			"decline":
				d.decline()
			"auto":
				d.take(_best_draft_pick(d.current_choices, d.picks))
			"breach":
				if d.picks.size() >= 1:
					d.stop()
					break
			_:
				pass
	# If the script never breached and the draft isn't finalized, stop now (mirrors the surface's
	# auto-finalize / the controller's `if not draft.finished: draft.stop()` in _run_draft).
	if not d.finished:
		if d.picks.size() >= 1:
			d.stop()
		else:
			d.stop()   # 0-pick edge: finalize anyway (payout falls back to x3; new_run handles empty squad)
	_finalize_run_from_draft(d)
	return run


## Choose which of this round's candidates a skilled operator takes. Returns the index of the
## highest-scoring candidate; on a tie, the lowest index (stable). `already` is the squad picked
## so far (for the composition bonus). Deterministic — no rng.
func _best_draft_pick(choices: Array, already: Array) -> int:
	var best_idx: int = 0
	var best_score: int = -1000000000
	for i in range(choices.size()):
		var s: int = _draft_score(choices[i], already)
		if s > best_score:
			best_score = s
			best_idx = i
	return best_idx


## Score a candidate UnitInstance for the draft (higher = take). A skilled operator values:
##   + survivability  : effective max HP weighted heavily (a fragile cell can't grind a captain).
##   + accuracy       : effective archetype accuracy (more reliable damage).
##   + trait quality  : positive traits add, negative traits subtract (glass_jaw/coward/frail hurt).
##   + composition    : a big bonus for a frontline body (bruiser/firebrand) when the cell has none
##                      yet — a pure-marksman cell folds to melee pressure.
## Pure function of the candidate + the already-picked squad. Integer-only, deterministic.
func _draft_score(u, already: Array) -> int:
	if u == null:
		return -1000000000
	# Survivability AND damage both matter: a tanky cell that can't kill just dies slower. Weight
	# effective HP and effective accuracy roughly evenly so the operator drafts a cell that can
	# trade — enough HP to absorb a captain gate, enough accuracy to end fights before attrition wins.
	var score: int = u.max_hp * 6
	score += u.effective_accuracy(db)
	# Trait polarity quality (frail/cowardly cards are a real liability).
	for tid in u.traits:
		var td: Dictionary = db.trait_def(tid)
		match String(td.get("polarity", "positive")):
			"positive": score += 12
			"negative": score -= 18
			"mixed":    score += 2
			_:          pass
	# Composition bonuses — a balanced cell beats three of a kind. Reward the roles the cell lacks:
	var have_frontline := false   # bruiser/firebrand: soaks melee, holds the line
	var have_ranged := false      # marksman/saboteur: reliable damage from cover
	var have_support := false     # steward: in-combat heal + stabilize (the sustain a no-rest line needs)
	for picked in already:
		if picked == null:
			continue
		if picked.archetype_id in ["bruiser", "firebrand"]:
			have_frontline = true
		if picked.archetype_id in ["marksman", "saboteur"]:
			have_ranged = true
		if picked.archetype_id == "steward":
			have_support = true
	if not have_frontline and u.archetype_id in ["bruiser", "firebrand"]:
		score += 28
	if not have_ranged and u.archetype_id in ["marksman", "saboteur"]:
		score += 24      # reliable ranged DPS is what ends fights fast
	if not have_support and u.archetype_id == "steward":
		score += 14      # one medic keeps the cell alive across a no-rest section
	return score


# ============================ the line ========================================
## Walk the generated line car-by-car: build each car, resolve it (combat or screen), collect
## the reward, advance. When the line reaches the Engine, run the finale + resolve the ending.
func _advance_line() -> void:
	var guard: int = 0
	while not run.is_won() and guard < 256:
		guard += 1
		var car = run.current_car()
		if car == null:
			break
		_refresh_recon_hud()
		# W7-8: a RESUME whose checkpoint was taken AFTER a combat car resolved but BEFORE it advanced
		# (a quit in the post-win level-up / econ window) must NOT re-fight it — re-entering a resolved
		# fight double-awards XP and re-fires its moral fork. Finish its post-resolve transition instead.
		# The Engine is excluded (its finale must still run on resume — its ending isn't persisted).
		if car.is_combat() and car.resolved and not car.is_engine:
			trace.append("CAR %d [%s/%s]: ALREADY-RESOLVED (resume) — not re-fought" % [run.position, _type_name(car.car_type), car.template_id])
			run.collect_reward()
			run.advance()
			continue
		if car.car_type == E.CarType.ENGINE:
			_run_finale(car)
			# the finale resolves the ending; mark the engine car resolved + advance past it.
			run.resolve_current()
			run.advance()
			break
		if car.is_combat():
			var outcome: int = _resolve_combat_car(car)
			# Anything but a genuine WIN ends the run here (§5.1): a LOSS is a squad wipe; a STALL
			# is the cell failing to clear the car inside the round guard. Either way the fight gate
			# is uncleared, so we stop rather than loop back and re-fight the same car forever (a
			# not-fully-wiped roster — e.g. a benched recruit beyond the 3 spawn points — would
			# otherwise trigger an infinite re-fight).
			if outcome != 1:
				_resolve_loss()
				return
		else:
			_resolve_screen_car(car)
		# A lost squad ends the run immediately (LOSS).
		if _squad_all_dead():
			_resolve_loss()
			return
		# Collect the rolled reward and advance to the next car (advance gates on resolved).
		run.collect_reward()
		run.advance()
	if ending == -1 and run.is_won():
		# Defensive: the line had no engine car (shouldn't happen) — resolve from facts.
		_resolve_from_run(true)


# ============================ ON-SCREEN INTERACTIVE FLOW ======================
## The animated, playable on-screen run (never used headless). Mirrors _advance_line's spine
## — draft -> walk the line car-by-car -> finale -> ending — but: combat cars play through the
## interactive loop (or AUTO auto-pilot), every event stream is ANIMATED (await play_animated),
## and the per-car screens get a beat to show. The headless _advance_line stays the synchronous
## source of truth for the test suites.
func drive_full_run_onscreen() -> void:
	trace.clear()
	if resume_run != null:
		run = resume_run
		seed = run.seed
		_log_hud("> RESUME — seed %d, car %d/%d." % [seed, run.position + 1, run.line.size()])
	else:
		# THE DRAFT (S2). On-screen default is INTERACTIVE: the operator vets candidates and breaches
		# through the RunScreens surface. --sim AUTO mode (sim_mode at entry) skips to the deterministic
		# auto-pick so a windowed proof plays itself. Either way the run is built via _finalize_run_from_draft,
		# so the resulting RunState is byte-identical to the headless path for the same (seed, picks).
		if sim_mode:
			_run_draft(3)
			_log_hud("> RUN START (QUICK DRAFT) — seed %d, squad %d." % [seed, run.squad.size()])
		else:
			var breached: bool = await _run_draft_interactive()
			if not breached:
				return   # operator abandoned the draft to the main menu (scene already changing)
			_log_hud("> RUN START — seed %d, squad %d." % [seed, run.squad.size()])
		_onscreen_log("RUN START — seed 0x%X, squad %d, line %d cars" % [seed, run.squad.size(), run.line.size()])
		await _beat(0.8)   # let the breach settle
	_save_run_checkpoint()   # first checkpoint — CONTINUE now resumes this run (car 1)
	var guard: int = 0
	while not run.is_won() and guard < 256:
		guard += 1
		var car = run.current_car()
		if car == null:
			break
		_refresh_recon_hud()
		# W7-8: a resumed checkpoint sitting on a resolved-but-not-advanced combat car (a quit in the
		# post-win level-up / econ window) is finished, not re-fought — no double XP / re-fired moral fork.
		if car.is_combat() and car.resolved and not car.is_engine:
			_onscreen_log("SKIP car %d/%d [%s] — already resolved (resume), not re-fought" % [run.position + 1, run.line.size(), _type_name(car.car_type)])
			run.collect_reward()
			run.advance()
			_save_run_checkpoint()
			continue
		_onscreen_log("ENTER car %d/%d [%s] %s" % [run.position + 1, run.line.size(), _type_name(car.car_type), (car.name if car.name != "" else car.template_id)])
		if car.car_type == E.CarType.ENGINE:
			# W4-7: the climax offers the SAME deploy-best-N picker every ordinary car does (interactive
			# only; --sim/AUTO + headless keep the deterministic auto-pick). Reuses the combat deploy seam.
			if not sim_mode:
				await _run_deploy_interactive(car)
			await _run_finale_onscreen(car)
			_forced_deployment = []   # reset — the finale consumed the pick
			run.resolve_current()
			run.advance()
			break
		if car.is_combat():
			# DEPLOY picker (combat-ux #6): pick who fights when the living cell outnumbers the tiles.
			# --sim/AUTO + headless skip it (the deterministic auto-pick top-3 applies in _place_squad).
			if not sim_mode:
				await _run_deploy_interactive(car)
			var outcome: int = await _resolve_combat_car_onscreen(car)
			_forced_deployment = []   # reset — the next car re-picks (or auto-picks)
			_onscreen_log("CAR %d resolved -> %s" % [run.position + 1, ("WON" if outcome == 1 else ("LOST" if outcome == 2 else "STALLED"))])
			if outcome != 1:
				_auto_handback_on_stall()   # W6-2: an AUTO stall/wipe notifies + restores MANUAL, never silent
				# W7-10: a STALL (0) is the guard cap tripping on a still-standing cell — NOT a wipe (2). Report
				# the real cause so the ending copy is honest, never a silent "squad wiped" lie.
				_resolve_loss("stall" if outcome == 0 else "wipe")
				return
			# W6-2: a FIGHT-scoped AUTO returns control to the operator HERE — before the permanent
			# level-up picks below — so engaging AUTO for one fight never silently commits the picks.
			# Whole-run AUTO stays engaged and takes the deterministic defaults.
			_auto_revert_after_car()
			# S3-LEVELUP: award combat XP to the surviving cell and resolve any level-up picks BEFORE the
			# next car. NOT-HEADLESS only — the byte-stable run loop (_advance_line, drive_full_run) never
			# awards XP. AUTO/--sim still awards (it's a real on-screen run) but auto-resolves the picks.
			_award_combat_xp_onscreen(car, _last_combat_kills)
			await _resolve_pending_levelups()
		else:
			# W6-2: a FIGHT-scoped AUTO never auto-commits an econ / recruit / moral (Order-changing)
			# choice — it hands the car back to the operator first. Whole-run AUTO (and the --sim proof)
			# still takes the deterministic default below. Headless never reaches this loop.
			if sim_mode and _auto_scope == "fight":
				_auto_revert_after_car()
			# ON-SCREEN INTERACTIVE (S3): present the real choice surface and wait for the operator.
			# --sim AUTO mode (sim_mode) falls through to the deterministic _do_* auto-default so a
			# windowed proof plays itself; headless never reaches drive_full_run_onscreen at all. Both
			# the headless _advance_line path and AUTO take the byte-stable default.
			if sim_mode:
				_resolve_screen_car(car)
			else:
				await _resolve_screen_car_interactive(car)
			_onscreen_log("CAR %d resolved -> %s" % [run.position + 1, _type_name(car.car_type)])
			await _beat(0.7)   # let the economy screen read
		if _squad_all_dead():
			_resolve_loss()
			return
		run.collect_reward()
		run.advance()
		_save_run_checkpoint()   # between-car checkpoint — CONTINUE resumes at the car just entered
	if ending == -1 and run.is_won():
		_resolve_from_run(true)
	_onscreen_log("ENDING -> %s" % _ending_name(ending))


## Play one combat car on-screen. Each round: the PLAYER phase is either driven by the operator
## (sim_mode==false — wait for InputIntent commits through the HUD) or auto-piloted (AUTO), then
## the enemy + environment phases settle, all ANIMATED. Loops until win/loss/stall. Returns the
## victory code (1 win / 2 loss / 0 stall).
func _resolve_combat_car_onscreen(car) -> int:
	state = _build_car_state(car)
	if state == null:
		trace.append("CAR %d [%s/%s]: SKIPPED (no template)" % [run.position, _type_name(car.car_type), car.template_id])
		return 1
	state.bleedout_enabled = true
	turn = TurnManager.new(state)
	turn.start()
	# C3.5 defection beat — state flip fires at the SAME logical point as the headless path (right
	# after turn.start()), so the sim mutation is byte-identical; only the animation below is on-screen.
	var betrayal_ev: Array = _apply_betrayal_beat(car)
	ai = EnemyAI.new()
	_active_combat = true
	_bind_combat_view()
	_play_music("section_%d" % int(car.section))   # W6-6: the section combat score (drop-in .ogg)
	bind_combat_intent()
	_log_hud("> ENTER %s — combat." % car.name)
	hud.set_auto_label(sim_mode)
	if not betrayal_ev.is_empty():
		_sync_view()                         # recolor the defector's token to the enemy faction
		await _play_anim(betrayal_ev)        # animate the BETRAYAL into the comms feed

	var enemies_at_start: int = _live_enemy_count(state)   # S3-LEVELUP XP source (kills = start - end)
	var outcome: int = 0
	var rounds: int = 0
	while rounds < COMBAT_GUARD_ROUNDS:
		rounds += 1
		var v: int = turn.check_victory()
		if v != 0:
			outcome = v
			break
		if _no_standing_players() and not _enemies_cleared():
			outcome = 2
			break
		# W7-10: warn the operator as the 60-round guard closes in (MANUAL fights only — AUTO scrubs
		# byte-stably). Without this the cap silently converted a long fight into a bogus LOSS.
		if not sim_mode:
			var gw := _combat_guard_warning(rounds)
			if gw != "":
				_log_hud("! " + gw)
		_onscreen_log("  round %d (%s)" % [rounds, ("AUTO" if sim_mode else "MANUAL")])
		# PLAYER phase: operator-driven when manual, auto-pilot when AUTO.
		_refresh_team_turn("PLAYER PHASE")   # #18 — the roster strip + ROUND n at the player phase
		if sim_mode:
			var p_ev: Array = _auto_player_phase()
			await _play_anim(p_ev)
		else:
			await _interactive_player_phase()
		v = turn.check_victory()
		if v != 0:
			outcome = v
			break
		# settle enemy + environment (animated). The read-only banners tell whose phase it is (#18).
		_refresh_team_turn("ENEMY PHASE")
		await _play_anim(turn.advance_phase())
		await _play_anim(ai.take_phase(turn))
		_refresh_team_turn("ENVIRONMENT PHASE")
		await _play_anim(turn.advance_phase())
		await _play_anim(turn.advance_phase())
		_sync_view()
		hud.set_auto_label(sim_mode)
	if outcome == 0:
		outcome = turn.check_victory()
	_active_combat = false
	# S3-LEVELUP: kills this car = enemies that left the board (XP feeds the on-screen award below).
	_last_combat_kills = max(0, enemies_at_start - _live_enemy_count(state))
	hud.set_actions_enabled(false)
	hud.set_hint("AUTO — operator standing by")
	if view != null:
		view.set_highlight(-1)
		view.clear_targeting_layer()
	_absorb_squad(state)
	if outcome == 1:
		AbilitySystem.grant_car_clear_momentum(db, run.squad)   # Firebrand momentum: +1 per car cleared
	var label := "WON" if outcome == 1 else ("LOST" if outcome == 2 else "STALLED")
	if outcome == 1 and car.car_type != E.CarType.CAPTAIN:
		var restored := 0
		if E.POST_COMBAT_REGROUP_PCT > 0:
			restored += _regroup_heal_pct(E.POST_COMBAT_REGROUP_PCT)   # G2: heal 50% of max (attrition compounds)
		# unconditional: a stabilized-downed comrade always gets back up (at the current revive HP;
		# → E.REGROUP_STANDUP_HP at the W6-1 flip). Runs AFTER the heal so it isn't re-clamped.
		restored += _stand_up_downed(E.REGROUP_STANDUP_HP)   # G2: downed stand at a fixed low HP, not full
		if restored > 0:
			label += " +regroup%d" % restored
	trace.append("CAR %d [%s/%s]: %s (round %d)" % [run.position, _type_name(car.car_type), car.template_id, label, turn.round_num])
	if outcome == 1:
		if view != null:
			view.win_flourish()   # #23 — the on-feed AMBER "CAR CLEAR" stamp + brief redout wipe on a win
		run.resolve_current()
		await _beat(0.5)
	return outcome


## Wait for the operator to drive the whole PLAYER phase through the HUD + InputIntent. Each
## acting unit: the operator selects it, picks an action, points a tile, confirms (the bound
## intent commits + animates via _on_intent_committed). When every player unit is out of AP (or
## the operator hit END on all of them / flipped to AUTO), the phase releases. A guard frame-loop
## yields control to the engine so clicks are processed; flipping AUTO mid-phase falls through to
## the auto-pilot so a fight can always be finished without manual play.
func _interactive_player_phase() -> void:
	hud.set_actions_enabled(false)
	_select_first_actor()
	_awaiting_player = true
	var spins: int = 0
	while _awaiting_player:
		# AUTO pressed mid-phase: finish this phase with the auto-pilot and stop waiting.
		if sim_mode:
			await _play_anim(_auto_player_phase())
			_awaiting_player = false
			break
		# W7-9: the fight was DECIDED mid-phase (last enemy just displaced/killed) — release the phase
		# immediately instead of making the operator END every remaining unit on an already-cleared board.
		if _combat_decided():
			_awaiting_player = false
			break
		# All player units done acting? release the phase.
		if not _any_player_can_act():
			_awaiting_player = false
			break
		# Yield a frame so HUD button presses + tile clicks are delivered, then re-check.
		await get_tree().process_frame
		spins += 1
		if spins > 200000:   # safety valve — never hard-hang the window
			_awaiting_player = false
			break
	hud.set_actions_enabled(false)


## Run the finale on-screen with animation. In --sim AUTO mode the combat-light auto-driven sabotage
## resolves the vault (the operator's verbs fire via the auto-pilot here, byte-stable). In MANUAL mode
## the OPERATOR fights the vault and drives the boss HUD (Batch 3); the Conductor cadence + countdown
## still tick each round. Both reach _show_ending on a win and _resolve_from_run on an unresolved exit.
func _run_finale_onscreen(car) -> void:
	_log_hud("*** THE ENGINE VAULT ***")
	var data = _read_json(CARS_DIR + car.template_id + ".json")
	if data == null:
		trace.append("FINALE: engine template missing — resolving from run facts")
		_resolve_from_run(false)
		return
	state = SetpieceLoader.build(data, seed)
	_strip_starters(state)   # keep the JSON's scripted defenders (turrets/chief/robot); the vault adds the Conductor itself
	_place_squad(state, _player_spawns(data), _forced_deployment)   # W4-7: honor the DEPLOY pick (auto-pick when empty)
	state.bleedout_enabled = true
	turn = TurnManager.new(state)
	turn.start()
	ai = EnemyAI.new()
	_bind_combat_view()
	_play_music("vault")   # W6-6: the Engine Vault / finale score (drop-in .ogg)
	bind_combat_intent()   # the operator drives antechamber combat (robots/turrets) through InputIntent
	var vault := EngineVault.new(state, run.order, run)
	vault.objective.countdown = int(data.get("bridgeCountdown", E.BRIDGE_COUNTDOWN_DEFAULT))
	var pos := _finale_positions(data)
	vault.build(pos.relays, pos.dispensers, pos.core, pos.dais, pos.conductor)
	# W4-2: the antechamber divider column + the live defender count at entry drive the dormant-phase
	# wake trigger (cross the divider / down the first turret -> the Conductor activates).
	_finale_divider_x = _finale_divider_from(data)
	_finale_enemies_at_entry = _live_enemy_count(state)
	trace.append("FINALE: vault built — %d relays, %d dispensers, core@%s, conductor@%s"
		% [pos.relays.size(), pos.dispensers.size(), str(pos.core), str(pos.conductor)])
	await _drive_finale_onscreen(vault)
	if ending == -1:
		# W4-6: pass the REAL objective state (a stalled-out finale with a live squad is NOT a win).
		_resolve_from_run(vault.objective.beat_clock(), vault.objective.is_objective_complete(), vault.objective.conductor_captured)
	else:
		# Finale WIN: the vault already set `ending` (Core sabotaged), so _resolve_from_run would
		# no-op on its `ending != -1` guard and the on-screen end-state would never arm — leaving the
		# VICTORY screen a dead end with a runaway timecode (same bug as the loss path had). Funnel
		# the win through the exact on-screen end-of-run handler the loss path uses.
		_show_ending()


## The on-screen finale driver. AUTO/sim_mode keeps the existing SCRIPTED auto-resolve (the
## _auto_player_phase + _break_one_relay + _try_sabotage cadence) so a windowed proof always finishes
## the run byte-stably. MANUAL hands the fight to the operator via _drive_finale_player (Batch 3): the
## squad fights, the operator two-taps relays then the core, and the boss HUD is driven off the real
## vault/objective each round. The headless _drive_finale (run_smoke/balance_smoke) is untouched.
func _drive_finale_onscreen(vault) -> void:
	if not headless and not sim_mode:
		await _drive_finale_player(vault)
		return
	# --- AUTO / sim path: byte-stable scripted resolve (unchanged from before Batch 3) ---
	var rounds: int = 0
	var evs: Array = []
	vault.activate_conductor(evs)
	await _play_anim(evs)
	while rounds < COMBAT_GUARD_ROUNDS:
		rounds += 1
		var rs: Array = []
		vault.on_round_start(rs)
		await _play_anim(rs)
		if vault.ending != -1:
			ending = vault.ending
			break
		await _play_anim(_auto_player_phase())
		_break_one_relay(vault)
		_try_sabotage(vault)
		if vault.ending != -1:
			ending = vault.ending
			break
		await _play_anim(turn.advance_phase())
		var cev: Array = []
		vault.run_conductor_phase(cev)
		await _play_anim(cev)
		await _play_anim(ai.take_phase(turn))
		await _play_anim(turn.advance_phase())
		await _play_anim(turn.advance_phase())
		_sync_view()
		if _squad_wiped_live(state):
			break
	if vault.ending != -1:
		ending = vault.ending
	trace.append("FINALE: rounds=%d core_sabotaged=%s ending=%s"
		% [rounds, str(vault.objective.is_objective_complete()), _ending_name(ending)])


## ============================ PLAYER-DRIVEN FINALE (Batch 3; on-screen MANUAL only) ============
## The operator fights the Engine Vault. Each round: the squad PLAYER phase is operator-driven through
## InputIntent (fight antechamber turrets + DEPLOY'd robots via normal combat), and the operator TARGETS
## the objective directly — two-tap a RELAY to break it (integrity -> 0), which drops the core shield;
## then two-tap the EXPOSED CORE to deliver a sabotage charge (vault.sabotage_core) until it falls = win.
## The Conductor cadence (run_conductor_phase) + the Bridge Countdown still tick each round; the boss HUD
## is driven off the live vault/objective. NO scripted _break_one_relay / _try_sabotage here — the
## operator does it. If the operator flips AUTO mid-fight, the loop falls through to the scripted auto
## path so a fight can always be finished. NEVER reached headless or in --sim AUTO (byte-stable both).
func _drive_finale_player(vault) -> void:
	_vault = vault
	_in_finale = true
	_active_combat = true   # the operator fights the vault's robots/turrets via the normal combat path
	if hud != null:
		hud.enter_finale_mode()
		hud.set_auto_label(sim_mode)
	# W4-2: HONOR THE ANTECHAMBER (B2.3, Phase 1). The Conductor stays DORMANT — no Bridge Countdown,
	# no cadence — while the squad fights the antechamber under turret fire. It ACTIVATES the round after
	# the squad crosses the inner-vault divider OR downs the first relay/antechamber turret (the
	# antechamber_trigger, checked at the top of the loop). This dormant gate is on-screen MANUAL only;
	# the headless _drive_finale and the AUTO fallback keep instant activation, so the byte-stable suites
	# are untouched.
	_refresh_finale_hud(vault)
	var rounds: int = 0
	while rounds < COMBAT_GUARD_ROUNDS:
		rounds += 1
		# AUTO pressed mid-fight: fall through to the scripted resolve so the run always finishes. Arm
		# the Conductor first if the antechamber is still dormant (AUTO runs the full B2.3 kit).
		if sim_mode:
			if vault.vault_phase == E.VaultPhase.ANTECHAMBER:
				var aev0: Array = []
				vault.activate_conductor(aev0)
				_play(aev0)
			_finish_finale_auto(vault, rounds)
			break
		# 0. Antechamber -> Conductor Active: arm on the cross-divider / first-defender-down trigger.
		if vault.vault_phase == E.VaultPhase.ANTECHAMBER and vault.antechamber_trigger_met(_finale_divider_x, _finale_enemies_at_entry):
			var aev: Array = []
			vault.activate_conductor(aev)
			await _play_anim(aev)
			_log_hud("> THE CONDUCTOR STIRS — the Bridge Countdown begins.")
			_refresh_finale_hud(vault)
		# 1. Arena round-start hooks (countdown, escalation, shield/phase sync) — then HUD refresh.
		var rs: Array = []
		vault.on_round_start(rs)
		await _play_anim(rs)
		_drain_escalations(vault, rs)
		_refresh_finale_hud(vault)
		if vault.ending != -1:
			ending = vault.ending
			break
		# 2. The operator's PLAYER phase: fight robots/turrets AND two-tap relays/core (the objective
		#    targeting routes through _on_finale_tile -> vault). Blocks until END / out-of-AP / AUTO.
		await _interactive_finale_phase(vault)
		_refresh_finale_hud(vault)
		if vault.ending != -1:
			ending = vault.ending
			break
		# 3. PLAYER -> ENEMY, the Conductor cadence (telegraph/resolve), enemy AI for robots.
		await _play_anim(turn.advance_phase())
		var cev: Array = []
		vault.run_conductor_phase(cev)
		await _play_anim(cev)
		await _play_anim(ai.take_phase(turn))
		# 4. ENEMY -> ENVIRONMENT (hazards + bleed-out) -> PLAYER.
		await _play_anim(turn.advance_phase())
		await _play_anim(turn.advance_phase())
		_sync_view()
		_refresh_finale_hud(vault)
		if _squad_wiped_live(state):
			break
	if vault.ending != -1:
		ending = vault.ending
	_in_finale = false
	_active_combat = false
	_vault = null
	if hud != null:
		hud.set_actions_enabled(false)
	trace.append("FINALE: rounds=%d core_sabotaged=%s ending=%s [player-driven]"
		% [rounds, str(vault.objective.is_objective_complete()), _ending_name(ending)])


## The operator's finale PLAYER phase: like _interactive_player_phase, but also leaves the objective-
## targeting seam live (relay/core two-taps route through _on_finale_tile). Blocks on operator input
## (END / out-of-AP / AUTO) with a spin-cap so the window never hard-hangs. If the operator flips AUTO
## mid-phase, it finishes the squad phase with the auto-pilot so the fight can always progress.
func _interactive_finale_phase(vault) -> void:
	hud.set_actions_enabled(false)
	_select_first_actor()
	_awaiting_player = true
	var spins: int = 0
	while _awaiting_player:
		if sim_mode:
			await _play_anim(_auto_player_phase())
			_awaiting_player = false
			break
		# The objective is met mid-phase (operator sabotaged the core) — release immediately.
		if vault.ending != -1:
			_awaiting_player = false
			break
		if not _any_player_can_act():
			_awaiting_player = false
			break
		await get_tree().process_frame
		spins += 1
		if spins > 200000:
			_awaiting_player = false
			break
	hud.set_actions_enabled(false)


## Finish the finale with the scripted auto-resolve (AUTO flipped mid-fight, or sim_mode). Mirrors the
## AUTO-path loop body so a fight can ALWAYS be completed; drives the boss HUD as it goes. Byte-stable
## logic is irrelevant here (this only runs on-screen, never in the headless suites).
func _finish_finale_auto(vault, _from_round: int) -> void:
	var guard: int = 0
	while guard < COMBAT_GUARD_ROUNDS:
		guard += 1
		var rs: Array = []
		vault.on_round_start(rs)
		_play(rs)
		_drain_escalations(vault, rs)
		_refresh_finale_hud(vault)
		if vault.ending != -1:
			break
		_play(_auto_player_phase())
		_break_one_relay(vault)
		_try_sabotage(vault)
		_refresh_finale_hud(vault)
		if vault.ending != -1:
			break
		_play(turn.advance_phase())
		var cev: Array = []
		vault.run_conductor_phase(cev)
		_play(cev)
		_play(ai.take_phase(turn))
		_play(turn.advance_phase())
		_play(turn.advance_phase())
		_sync_view()
		_refresh_finale_hud(vault)
		if _squad_wiped_live(state):
			break
	if vault.ending != -1:
		ending = vault.ending


# ---- player-driven OBJECTIVE TARGETING (relays + core; on-screen MANUAL only) ----
## A finale tile was tapped while no unit-combat action is armed: if it's a RELAY or the exposed CORE,
## treat it as a two-tap objective target. First tap arms (HUD shows ◂AIM on the relay row / SABOTAGE
## tell); a second tap on the SAME tile commits — break the relay (-> shield drop) or sabotage the core
## (vault.sabotage_core). Returns TRUE if the tap was consumed as objective targeting. On-screen-only.
func _on_finale_tile(cell: Vector2i) -> bool:
	if _vault == null or state == null:
		return false
	var occ = state.occupant_at(cell)
	if occ == null:
		return false
	var is_relay: bool = (not occ.is_unit) and occ.name == E.OBJ_RELAY and occ.alive
	var is_core: bool = (not occ.is_unit) and occ.name == E.OBJ_ENGINE_CORE and occ.alive
	var is_conductor: bool = occ.is_unit and occ.is_finale_boss and occ.alive   # W4-3 capture target
	if not is_relay and not is_core and not is_conductor:
		return false
	# Two-tap COMMIT: a second tap on the SAME armed target delivers the previewed action.
	if _obj_target_id == occ.id and _obj_last_tap == cell:
		_obj_target_id = -1
		_obj_last_tap = Vector2i(-9999, -9999)
		if is_conductor:
			commit_capture_conductor()
		else:
			commit_objective_action(occ)
		_refresh_finale_hud(_vault)
		return true
	# FIRST tap: validate a REAL delivery + show the preview (W4-1). A relay/core needs a deployed unit
	# adjacent WITH AP; the Core needs the shield down first; the Conductor can be SEIZED (not killed)
	# once its shield is off. An invalid tap is CONSUMED (never falls to combat) but does NOT arm.
	if is_conductor:
		if can_capture_conductor():
			_obj_target_id = occ.id
			_obj_last_tap = cell
			_log_hud("> SEIZE THE CONDUCTOR — tap again to CAPTURE (not kill).")
		else:
			var cc = state.entities.get(_vault.objective.conductor_id)
			if cc != null and cc.conductor_shielded:
				_log_hud("! CONDUCTOR SHIELDED — disable the relays to reach it.")
			else:
				_log_hud("! NO UNIT IN RANGE — move a squad member adjacent (with AP) to seize it.")
		_refresh_finale_hud(_vault)
		return true
	var pv: Dictionary = preview_objective_action(occ)
	if not bool(pv.get("valid", false)):
		match String(pv.get("reason", "")):
			"core_sealed": _log_hud("! CORE SEALED — drop the shield first (disable the relays).")
			"no_actor":    _log_hud("! NO UNIT IN RANGE — move a squad member adjacent (with AP) to act.")
			_:             _log_hud("! CANNOT ACT HERE.")
		_refresh_finale_hud(_vault)
		return true
	_obj_target_id = occ.id
	_obj_last_tap = cell
	if is_relay:
		_log_hud("> TARGETING RELAY — integrity %d -> %d. Tap again to DISABLE." % [int(pv.integrity_before), int(pv.integrity_after)])
	else:
		_log_hud("> CORE EXPOSED — integrity %d -> %d. Tap again to SABOTAGE." % [int(pv.integrity_before), int(pv.integrity_after)])
	_refresh_finale_hud(_vault)
	return true


## Commit an armed objective target: break a relay (integrity -> 0, mirrors the resolver end-state the
## vault's destruction hooks expect) or deliver a sabotage charge to the exposed core. Uses the REAL
## vault/objective API; the destruction hooks fire on the next on_round_start scan (relays) or
## immediately (core). On-screen-only — the headless path uses _break_one_relay / _try_sabotage.
func _commit_obj_target(occ) -> void:
	if _vault == null:
		return
	if occ.name == E.OBJ_RELAY:
		# Break this relay (a focused round of fire/slams). Erasing the integrity-0 relay is the EXACT
		# end-state the physics resolver produces — same as the headless _break_one_relay. The vault's
		# RELAY_DISABLED / power-disable / shield-drop hooks fire on the next destruction scan (this
		# round's run_conductor_phase, then the next on_round_start) — we do NOT re-run on_round_start
		# here (that would double-drain the Bridge Countdown). The HUD reads liveness directly, so the
		# shield/relay block reflects the break immediately regardless.
		if state.in_bounds(occ.pos) and state.tile(occ.pos).occupant_id == occ.id:
			state.tile(occ.pos).occupant_id = -1
		occ.alive = false
		state.entities.erase(occ.id)
		_log_hud("> RELAY DOWN — shield weakening.")
		# Sync the shield + phase NOW (no countdown advance) so the HUD/objective state is current.
		var ev: Array = []
		_vault.objective.sync_shields(state, ev)
		_vault.update_phase(ev)
		_play(ev)
		_refresh_finale_hud(_vault)
		if _vault.ending != -1:
			ending = _vault.ending
	elif occ.name == E.OBJ_ENGINE_CORE:
		if not _vault.objective.core_exposed(state):
			_log_hud("! CORE SEALED — drop the shield.")
			return
		var ev: Array = []
		_vault.sabotage_core(E.SABOTAGE_CHARGE_DAMAGE, ev)
		_play(ev)
		_log_hud("> SABOTAGE CHARGE — core integrity falling.")
		_refresh_finale_hud(_vault)
		if _vault.ending != -1:
			ending = _vault.ending
			_awaiting_player = false   # release the phase so the win resolves immediately


# ---- W4-1: RELAYS + CORE AS REAL, PREVIEWED UNIT ACTIONS (adjacency + AP + integrity) ----
## PREVIEW a finale objective action (disable a relay / sabotage the Core) WITHOUT mutating a thing
## (preview==commit, invariant #2). It is a REAL unit delivery, not a bare tap: it requires a deployed
## PLAYER unit adjacent to the target WITH AP, and the Core must be exposed (shield down). Returns
## { valid, reason, is_core, actor_id, amount, integrity_before, integrity_after, breaks }.
## commit_objective_action() re-runs this exact predictor and applies its numbers, so what the operator
## sees on the first tap is precisely what the second tap delivers. Pure read; headless-drivable.
func preview_objective_action(target) -> Dictionary:
	var out := {"valid": false, "reason": "none", "is_core": false, "actor_id": -1,
		"amount": 0, "integrity_before": 0, "integrity_after": 0, "breaks": false}
	if _vault == null or state == null or target == null or not target.alive:
		out.reason = "no_target"
		return out
	var is_relay: bool = (not target.is_unit) and target.name == E.OBJ_RELAY
	var is_core: bool = (not target.is_unit) and target.name == E.OBJ_ENGINE_CORE
	if not is_relay and not is_core:
		out.reason = "not_objective"
		return out
	out.is_core = is_core
	# The Core only takes sabotage once the shield is down (relays gone or the Conductor decapitated).
	if is_core and not _vault.objective.core_exposed(state):
		out.reason = "core_sealed"
		return out
	var actor = _objective_actor_for(target)
	if actor == null:
		out.reason = "no_actor"   # no deployed unit adjacent WITH AP — the gate the bare-tap path skipped
		return out
	var amount: int = E.SABOTAGE_CHARGE_DAMAGE if is_core else E.RELAY_INTEGRITY_DEFAULT
	out.actor_id = int(actor.id)
	out.amount = amount
	out.integrity_before = int(target.integrity)
	out.integrity_after = max(0, int(target.integrity) - amount)
	out.breaks = out.integrity_after <= 0
	out.valid = true
	return out


## The PLAYER unit positioned to deliver a finale objective action against `target`: alive, adjacent
## (a focused charge/slam from an orthogonally- or diagonally-adjacent tile) and with AP left. Stable
## deterministic pick — lowest entity id among the eligible — so the preview and the commit choose the
## SAME actor. null if no deployed unit is in range with AP (the W4-1 gate the bare-tap path skipped).
func _objective_actor_for(target):
	if target == null or state == null or turn == null:
		return null
	for id in state.entity_ids_sorted():
		var e = state.entities.get(id)
		if e == null or not e.is_unit or not e.alive or e.faction != E.Faction.PLAYER:
			continue
		if turn.ap_for(int(id)) <= 0:
			continue
		if _finale_adjacent(e.pos, target.pos):
			return e
	return null


## Orthogonal- or diagonal-adjacency (Chebyshev distance 1) — the reach of a focused objective delivery.
func _finale_adjacent(a: Vector2i, b: Vector2i) -> bool:
	if a == b:
		return false
	return abs(a.x - b.x) <= 1 and abs(a.y - b.y) <= 1


## COMMIT the previewed objective action (W4-1): spend the actor's turn (one objective action per unit
## per round), then apply the SAME integrity damage the preview reported. A relay drops when its
## integrity hits 0 (erased = the resolver's end-state; the vault's destruction hooks fire on the next
## scan); the Core routes through vault.sabotage_core (which resolves the ending on 0). Returns the
## preview dict actually applied (or the invalid preview, unmodified) so a test can assert preview==commit.
func commit_objective_action(target) -> Dictionary:
	var pv: Dictionary = preview_objective_action(target)
	if not bool(pv.get("valid", false)):
		return pv
	var actor = state.entities.get(int(pv.actor_id))
	if turn != null and actor != null:
		turn.end_unit(int(actor.id))   # a focused objective action ends the unit's turn (rate-limit)
	var ev: Array = []
	if bool(pv.is_core):
		_vault.sabotage_core(int(pv.amount), ev)
		_log_hud("> SABOTAGE CHARGE — core integrity %d." % int(pv.integrity_after))
	else:
		target.integrity = max(0, int(target.integrity) - int(pv.amount))
		if target.integrity <= 0:
			if state.in_bounds(target.pos) and state.tile(target.pos).occupant_id == target.id:
				state.tile(target.pos).occupant_id = -1
			target.alive = false
			state.entities.erase(target.id)
			_log_hud("> RELAY DISABLED — shield weakening.")
		else:
			_log_hud("> RELAY HIT — integrity %d." % int(target.integrity))
		_vault.objective.sync_shields(state, ev)
		_vault.update_phase(ev)
	_play(ev)
	_refresh_finale_hud(_vault)
	if _vault.ending != -1:
		ending = _vault.ending
		_awaiting_player = false   # release the player phase so the win resolves immediately
	return pv


# ---- W4-3: SEIZE THE ENGINE — the CAPTURE affordance (capture the Conductor, don't kill it) ----
## The PLAYER unit positioned to SEIZE the Conductor (capture, not kill): alive, adjacent, with AP.
## Same stable lowest-id pick as the objective actor. null if none in range.
func _capture_actor():
	if _vault == null or state == null or turn == null:
		return null
	var c = state.entities.get(_vault.objective.conductor_id)
	if c == null or not c.alive:
		return null
	for id in state.entity_ids_sorted():
		var e = state.entities.get(id)
		if e == null or not e.is_unit or not e.alive or e.faction != E.Faction.PLAYER:
			continue
		if turn.ap_for(int(id)) <= 0:
			continue
		if _finale_adjacent(e.pos, c.pos):
			return e
	return null


## Can the player CAPTURE the Conductor right now (the Seize-the-Engine choice, W4-3)? Only once its
## relay-shield is off (all relays down / decapitation window) AND a deployed unit is adjacent with AP.
## Capture is the merciful alternative to killing: it drops the shield like a kill but flags the ending.
func can_capture_conductor() -> bool:
	if _vault == null or state == null:
		return false
	var obj = _vault.objective
	if obj.conductor_captured or obj.conductor_killed:
		return false
	var c = state.entities.get(obj.conductor_id)
	if c == null or not c.alive or c.conductor_shielded:
		return false   # unreachable while the relays shield its body
	return _capture_actor() != null


## COMMIT the capture (W4-3): spend the actor's turn, then vault.capture_conductor() (sets captured,
## drops the shields, exposes the Core via decapitation). The operator then sabotages the exposed Core;
## the ending resolves as SEIZE_ENGINE (given a low-Order, in-time, not-gutted run). Returns success.
func commit_capture_conductor() -> bool:
	if not can_capture_conductor():
		return false
	var actor = _capture_actor()
	if turn != null and actor != null:
		turn.end_unit(int(actor.id))
	var ev: Array = []
	_vault.capture_conductor(ev)
	_play(ev)
	_log_hud("> CONDUCTOR SEIZED — the Engine is yours. Sabotage the Core to end it.")
	_refresh_finale_hud(_vault)
	return true


## Push the live vault/objective state into the boss HUD each round (the countdown, relay/shield or
## core gauge, telegraph banner, lockdown bezel). On-screen-only; cheap reads off the real objective.
func _refresh_finale_hud(vault) -> void:
	if hud == null or vault == null:
		return
	var obj = vault.objective
	# Camera header: phase 1/2/3 of the vault.
	var phase_n: int = vault.vault_phase + 1
	hud.set_camera_id("ENGINE", "CONDUCTOR'S CHAMBER · PHASE %d/3" % phase_n)
	# Countdown clock (dormant until the Conductor activates; then ticking; then BREACHED).
	if obj.countdown_started:
		hud.set_bridge_countdown(obj.countdown, obj.countdown_expired)
	# Core shield / relay block (Phase 2) vs core integrity gauge (Phase 3 / exposed).
	if vault.vault_phase == E.VaultPhase.CORE_EXPOSED or obj.core_exposed(state):
		var core = state.entities.get(obj.core_id)
		var cur: int = int(core.integrity) if core != null and core.alive else 0
		hud.set_core_integrity(cur, E.CORE_INTEGRITY_DEFAULT)
		hud.set_core_shield(false)
		hud.set_lockdown(true)
	else:
		hud.set_core_shield(obj.core_shielded(state))
		hud.set_relay_status(_relay_rows(obj))
		hud.set_lockdown(false)
	# Conductor telegraph banner (the one-turn warning).
	var c = state.entities.get(obj.conductor_id)
	if c != null and c.alive and int(c.pending_action) != E.ConductorAction.NONE:
		hud.set_conductor_telegraph(int(c.pending_action), _overcharge_target_name())
	else:
		hud.set_conductor_telegraph(-1, "")


## Build the per-relay rows the HUD relay block renders (tag/power/integrity/online/targeted).
func _relay_rows(obj) -> Array:
	var tags := ["A", "B", "C"]
	var powers := ["PISTONS", "PLATES", "DISPENSERS"]
	var rows: Array = []
	for i in range(obj.relay_ids.size()):
		var rid: int = int(obj.relay_ids[i])
		var r = state.entities.get(rid)
		var online: bool = r != null and r.alive
		var cur: int = int(r.integrity) if online else 0
		var mx: int = E.RELAY_INTEGRITY_DEFAULT
		if online and r.integrity > mx:
			mx = int(r.integrity)
		rows.append({
			"tag": tags[i] if i < tags.size() else str(i),
			"power": powers[i] if i < powers.size() else "",
			"cur": cur, "max": mx, "online": online,
			"targeted": (_obj_target_id == rid),
		})
	return rows


## The name of the unit the Conductor's pending OVERCHARGE would hit (the telegraph target hint), or ""
## if the pending action isn't a unit-targeted strike.
func _overcharge_target_name() -> String:
	var best = null
	var best_hp: int = 1 << 30
	for id in state.entity_ids_sorted():
		var p = state.entities.get(id)
		if p == null or not p.is_unit or not p.alive or p.faction != E.Faction.PLAYER:
			continue
		if p.hp < best_hp:
			best_hp = p.hp
			best = p
	return String(best.name) if best != null else ""


## Surface each VAULT_ESCALATE in the just-played event stream onto the HUD escalation ticker.
func _drain_escalations(_vault, events: Array) -> void:
	if hud == null:
		return
	for e in events:
		if e.type == E.Ev.VAULT_ESCALATE:
			hud.push_escalation(int(e.data.get("level", 0)), "TRAPS FASTER")


# ---- PLAYER-DRIVEN FINALE TEST SEAM (headless-drivable) ----------------------
## VERIFIABLE PLAYER-DRIVEN FINALE SEAM (no display, no await). Drive the on-screen finale's OPERATOR
## logic from a list of scripted objective-target actions — the EXACT relay-break / core-sabotage the
## two-tap tile path emits — against a vault built on `state`/`turn`/`_vault` the test has wired. Mirrors
## drive_draft_scripted / drive_screen_scripted. Each round: on_round_start (countdown/escalate/shield),
## then APPLY this round's scripted operator action against the live objective via _commit_obj_target
## (the SAME code the live two-tap calls), then run the Conductor cadence + settle. Stops when the vault
## resolves an ending (win) or the squad wipes (loss) or the script is spent. Each step is a small dict:
##   {op:"break_relay"}    -> break the first still-online relay this round (drops a shield stack)
##   {op:"sabotage_core"}  -> deliver a sabotage charge to the exposed core (no-op while sealed)
##   {op:"noop"}           -> a round where the operator only fights units (no objective action)
## Returns a result dict { ending, core_sabotaged, beat_clock, relays_online, rounds } so a test can
## assert relay->shield->core->win WITHOUT a SceneTree. Deterministic — no rng, no display, no await.
func drive_finale_scripted(vault, scripted: Array) -> Dictionary:
	_vault = vault
	_in_finale = true
	var evs: Array = []
	vault.activate_conductor(evs)
	var rounds: int = 0
	var si: int = 0
	while rounds < COMBAT_GUARD_ROUNDS and vault.ending == -1:
		rounds += 1
		# 1. Arena round-start (countdown drain / escalation / shield+phase sync).
		var rs: Array = []
		vault.on_round_start(rs)
		if vault.ending != -1:
			break
		# 2. The operator's objective action this round (the player-driven part), via the live seam.
		if si < scripted.size():
			var step = scripted[si]
			si += 1
			match String(step.get("op", "")):
				"break_relay":
					var r = _first_online_relay(vault)
					if r != null:
						_commit_obj_target(r)
				"sabotage_core":
					var core = state.entities.get(vault.objective.core_id)
					if core != null and core.alive:
						_commit_obj_target(core)
				"capture_conductor":
					commit_capture_conductor()   # W4-3: the Seize path (needs a unit adjacent + shield off)
				_:
					pass
		if vault.ending != -1:
			break
		# 3. Conductor cadence + enemy phase + environment settle (no display, synchronous).
		_play(turn.advance_phase())
		var cev: Array = []
		vault.run_conductor_phase(cev)
		_play(cev)
		_play(ai.take_phase(turn))
		_play(turn.advance_phase())
		_play(turn.advance_phase())
		if _squad_wiped_live(state):
			break
	if vault.ending != -1:
		ending = vault.ending
	elif run != null:
		# W4-6: the finale exited unresolved (a 60-round stall, or the squad wiped) — mirror the real
		# _run_finale fallthrough and resolve from the REAL objective state, so a stalled finale with an
		# intact Core does NOT hand out a victory. (Skipped when no RunState is bound, e.g. minimal seams.)
		_resolve_from_run(vault.objective.beat_clock(), vault.objective.is_objective_complete(), vault.objective.conductor_captured)
	_in_finale = false
	_vault = null
	return {
		"ending": ending, "core_sabotaged": vault.objective.is_objective_complete(),
		"beat_clock": vault.objective.beat_clock(), "relays_online": vault.objective.relays_online(state),
		"rounds": rounds, "shield_up": vault.objective.core_shielded(state),
	}


## The first still-online relay entity (for the scripted seam's break_relay action), or null.
func _first_online_relay(vault):
	for rid in vault.objective.relay_ids:
		var r = state.entities.get(rid)
		if r != null and r.alive:
			return r
	return null


# ============================ LEVEL-UP (S3-LEVELUP; Batch 5) ===================
## Count live (alive, non-downed) enemy units in a combat state. The XP "kills" source: the drop in
## this count across a car is how many enemies the surviving cell removed. Pure read — no mutation.
func _live_enemy_count(s) -> int:
	var n: int = 0
	for id in s.entity_ids_sorted():
		var e = s.entities.get(id)
		if e == null or not e.is_unit or e.faction != E.Faction.ENEMY:
			continue
		if e.alive and not e.downed:
			n += 1
	return n


## Award combat XP to the SURVIVING cell after an on-screen combat WIN, then leave any level-ups as
## pending picks (the overlay queue resolves them). NOT-HEADLESS ONLY — the byte-stable headless run
## loop never calls this, so no XP is ever granted there (the suites stay XP-free + byte-identical).
## Every living, non-dead squad member earns XP_PER_CAR for the clearance plus a share of XP_PER_KILL
## per enemy removed. Uses the REAL Leveling.grant_xp (which raises unit.level on threshold). The events
## it emits are logged to comms; the pending picks are discovered by _pending_levelup_picks().
func _award_combat_xp_onscreen(car, kills: int) -> void:
	if headless:
		return
	var per_unit: int = XP_PER_CAR + XP_PER_KILL * max(0, kills)
	for u in run.squad:
		if u == null or u.dead:
			continue
		var evs: Array = []
		Leveling.grant_xp(u, per_unit, evs)
		for e in evs:
			if e.type == E.Ev.LEVEL_UP:
				_log_hud("> %s reached LEVEL %d." % [u.name, int(e.data.get("level", u.level))])


## A unit has a PENDING level-up pick when its level entitles it to a tier whose 1-of-2 (or capstone)
## it has not yet recorded into chosen_abilities. Returns the FIRST still-unpicked offered ability id
## for `u` at its current level tier (walking up from level 2), or "" if nothing is pending. Pure read.
## (A unit can owe more than one pick after a multi-level jump; this returns one at a time so the queue
## resolves each in sequence — re-querying after each pick.)
func _pending_levelup_choice(u) -> Dictionary:
	if u == null or u.dead:
		return {}
	# Walk each level tier the unit has reached (2..level) and find the first one whose offered options
	# include none the unit has chosen yet. That tier is an owed pick.
	for lvl in range(2, u.level + 1):
		var options: Array = Leveling.choice_for_level(db, u.archetype_id, lvl)
		if options.is_empty():
			continue
		var already_picked := false
		for opt in options:
			if u.chosen_abilities.has(String(opt)):
				already_picked = true
				break
		if not already_picked:
			return {"unit": u, "level": lvl, "options": options}
	return {}


## The full queue of pending picks across the squad, in stable roster order (one entry per owed pick;
## a unit owing two picks appears twice — re-queried as each resolves). Pure read, no mutation.
func _pending_levelup_picks() -> Array:
	var out: Array = []
	for u in run.squad:
		var ch: Dictionary = _pending_levelup_choice(u)
		if not ch.is_empty():
			out.append(ch)
	return out


## Resolve EVERY pending level-up pick before the run advances (on-screen only). Each owed pick raises
## the RunScreens ABILITY-CARD overlay; the operator taps a card (or AUTO/--sim + the never-stuck valve
## auto-pick option 0). Re-queries after each pick so a multi-level unit resolves all its picks. NEVER
## reached headless (no XP is awarded there) — the byte-stable suites never enter this. A spin-cap on
## the per-pick wait + a hard cap on the queue can never hard-hang the window.
func _resolve_pending_levelups() -> void:
	if headless:
		return
	var guard: int = 0
	while guard < 64:
		guard += 1
		var queue: Array = _pending_levelup_picks()
		if queue.is_empty():
			break
		var ch: Dictionary = queue[0]
		await _present_levelup_pick(ch, 0, queue.size())
	if screens != null:
		screens.hide_levelup()
	_in_levelup = false


## Present ONE pending pick and resolve it. In --sim AUTO mode (or if the surface is missing) the
## never-stuck valve auto-picks option 0 deterministically + logs. In MANUAL mode it raises the overlay
## and blocks until the operator picks (or the spin-cap forces the safety auto-pick). Applies the pick
## via the REAL Leveling.choose_ability. On-screen-only.
func _present_levelup_pick(ch: Dictionary, queue_idx: int, queue_total: int) -> void:
	var u = ch.get("unit", null)
	var options: Array = ch.get("options", [])
	if u == null or options.is_empty():
		return
	# AUTO / no surface: the deterministic never-stuck auto-pick (option 0).
	if sim_mode or screens == null:
		_apply_levelup_pick(u, String(options[0]))
		return
	_in_levelup = true
	if screens != null:
		screens.show_levelup(_levelup_spec(ch, queue_idx, queue_total))
	var picked: String = await _await_levelup_action(options)
	_apply_levelup_pick(u, picked)


## Build the overlay spec dict for one pending pick (the card data the surface renders): the unit's
## name/level/archetype, the queue indicator, and per-option {id, name, tier, blurb} from the REAL
## AbilityDef (ContentDB.ability) + the tier tag from the offered level. Pure data — no mutation.
func _levelup_spec(ch: Dictionary, queue_idx: int, queue_total: int) -> Dictionary:
	var u = ch.get("unit", null)
	var lvl: int = int(ch.get("level", 2))
	var options: Array = ch.get("options", [])
	var opt_specs: Array = []
	var tier_tag := _levelup_tier_tag(u, lvl, options)
	for aid in options:
		var ab: Dictionary = db.ability(String(aid))
		opt_specs.append({
			"id": String(aid),
			"name": String(ab.get("name", String(aid).capitalize())),
			"tier": tier_tag,
			"blurb": _ability_blurb(ab),
		})
	return {
		"name": String(u.name), "level": lvl, "archetype": String(u.archetype_id),
		"queue_idx": queue_idx, "queue_total": queue_total, "options": opt_specs,
	}


## The tier tag for the offered options at `lvl` (T1/T2/T3 from the abilityTree index, or CAPSTONE
## past the tree). Mirrors Leveling.choice_for_level's tier math (level N -> tree tier N-2).
func _levelup_tier_tag(u, lvl: int, options: Array) -> String:
	var arch: Dictionary = db.archetype(String(u.archetype_id))
	var tree: Array = arch.get("abilityTree", [])
	var tier: int = lvl - 2
	if tier >= 0 and tier < tree.size() and options.size() >= 2:
		return "T%d — 1 OF 2" % (tier + 1)
	return "CAPSTONE"


## A one-line effect blurb for an AbilityDef (the card body). Reads the authored fields the renderer
## can show without a full ability sim: AP cost, ends-turn, range, and a compact effect summary.
func _ability_blurb(ab: Dictionary) -> String:
	if ab.is_empty():
		return "A new specialization."
	var bits: Array = []
	var ap: int = int(ab.get("apCost", 1))
	bits.append("%d AP%s" % [ap, ("  · ends turn" if ab.get("endsTurn", false) else "")])
	var rng: int = int(ab.get("range", 0))
	if rng > 0:
		bits.append("range %d" % rng)
	var tgt := String(ab.get("targeting", ""))
	if tgt != "":
		bits.append(tgt)
	var eff_words: Array = []
	for eff in ab.get("effects", []):
		var k := String(eff.get("kind", ""))
		match k:
			"impulse", "throw": eff_words.append("force %d" % int(eff.get("force", 0)))
			"damage":           eff_words.append("dmg %d" % int(eff.get("amount", 0)))
			"status":           eff_words.append("inflict %s" % String(eff.get("status", "")))
			"buff":             eff_words.append("+%d %s" % [int(eff.get("amount", 0)), String(eff.get("stat", ""))])
			"heal":             eff_words.append("heal %d" % int(eff.get("amount", 0)))
			"move":             eff_words.append("reposition")
			_:                  if k != "": eff_words.append(k)
	var line := "  ·  ".join(bits)
	if not eff_words.is_empty():
		line += "\n" + ", ".join(eff_words)
	return line


## Apply one level-up pick via the REAL Leveling.choose_ability (records into chosen_abilities, emits
## ABILITY_PICKED). If the requested id isn't a valid option for some reason, falls back to option 0
## (the never-stuck valve) so a pick is ALWAYS recorded and the queue can never dead-end. On-screen-only.
func _apply_levelup_pick(u, ability_id: String) -> void:
	if u == null:
		return
	var ch: Dictionary = _pending_levelup_choice(u)
	var options: Array = ch.get("options", [])
	if options.is_empty():
		return
	var chosen := ability_id
	if not options.has(chosen):
		chosen = String(options[0])   # safety: an invalid id can never leave the pick unresolved
	var lvl: int = int(ch.get("level", u.level))
	# choose_ability validates against the unit's CURRENT level tier; temporarily align to the owed
	# tier's level so a multi-level unit's earlier tiers resolve correctly, then restore.
	var saved_level: int = u.level
	u.level = lvl
	var evs: Array = []
	var ok: bool = Leveling.choose_ability(db, u, chosen, evs)
	u.level = saved_level
	if not ok:
		# Last-ditch: record it directly so the queue advances (never strand a pending pick).
		if not u.chosen_abilities.has(chosen):
			u.chosen_abilities.append(chosen)
	_log_hud("> %s learned %s." % [u.name, db.ability(chosen).get("name", chosen)])
	trace.append("LEVELUP: %s L%d -> %s" % [u.name, lvl, chosen])


## Block until the operator picks an ability (or the safety spin-cap fires the auto-pick). Yields
## frames so the overlay card taps + 1/2/ENTER keys are delivered. Returns the chosen ability id (or
## option 0 on the spin-cap). On-screen-only.
func _await_levelup_action(options: Array) -> String:
	_levelup_action = ""
	_awaiting_levelup = true
	var spins: int = 0
	while _awaiting_levelup:
		if _levelup_action.begins_with("pick:"):
			_awaiting_levelup = false
			break
		await get_tree().process_frame
		spins += 1
		if spins > 5000000:
			_awaiting_levelup = false
			return String(options[0])   # never-stuck valve
	var a := _levelup_action
	_levelup_action = ""
	if a.begins_with("pick:"):
		return a.substr(5)
	return String(options[0])


# --- level-up overlay signal handlers (record the operator's pick; the async phase consumes it) ---
func _on_levelup_select(_ability_id: String) -> void:
	pass   # first-tap preview — the surface owns the highlight; nothing to drive here

func _on_levelup_pick(ability_id: String) -> void:
	if _awaiting_levelup:
		_levelup_action = "pick:%s" % ability_id


# ---------------------------- LEVEL-UP TEST SEAM (headless-drivable) ----------
## VERIFIABLE LEVEL-UP SEAM (no display, no await). Drive the level-up LOGIC directly on an in-memory
## UnitInstance — the EXACT grant_xp -> threshold -> 1-of-2 -> choose path the on-screen flow runs —
## WITHOUT the byte-stable run loop and WITHOUT a SceneTree. Mirrors drive_draft_scripted / drive_screen
## _scripted. `scripted` is a list of small dicts the operator's overlay taps would emit:
##   {op:"xp", amount:<n>}            -> Leveling.grant_xp(unit, n)  (may raise one or more levels)
##   {op:"pick", id:<ability_id>}     -> resolve the unit's FIRST pending pick to <id> (via _apply_levelup_pick)
##   {op:"auto"}                       -> resolve the FIRST pending pick with the never-stuck auto-pick (option 0)
## Returns a result dict { level, xp, pending, chosen, picks_resolved } so a test can assert XP ->
## threshold -> the offered 1-of-2 -> the pick recorded -> no dead end. Deterministic — the XP + tier are
## fixed by the archetype data (no rng). Never touches run/state/screens.
func drive_levelup_scripted(unit, scripted: Array) -> Dictionary:
	if db == null:
		db = ContentDB.new()
	var picks_resolved: int = 0
	for step in scripted:
		match String(step.get("op", "")):
			"xp":
				var evs: Array = []
				Leveling.grant_xp(unit, int(step.get("amount", 0)), evs)
			"pick":
				var ch: Dictionary = _pending_levelup_choice(unit)
				if not ch.is_empty():
					_apply_levelup_pick(unit, String(step.get("id", "")))
					picks_resolved += 1
			"auto":
				var ch2: Dictionary = _pending_levelup_choice(unit)
				if not ch2.is_empty():
					var opts: Array = ch2.get("options", [])
					if not opts.is_empty():
						_apply_levelup_pick(unit, String(opts[0]))
						picks_resolved += 1
			_:
				pass
	var pending: Array = []
	var ch3: Dictionary = _pending_levelup_choice(unit)
	if not ch3.is_empty():
		pending = ch3.get("options", [])
	return {
		"level": unit.level, "xp": unit.xp,
		"pending": pending, "chosen": unit.chosen_abilities.duplicate(),
		"picks_resolved": picks_resolved,
	}


# ============================ COMBAT TARGETING LEGIBILITY (#16) ================
## Build the render-only legibility layer for the currently selected unit + armed action (#16). Returns
## a PURE draw-data dict the CarView renders WITHOUT touching any sim/command state:
##   { reach:[Vector2i], push:[Vector2i], shoot:[{cell,pct,shield}], armed:InputIntent.Mode }
## Each tile set is computed off the LIVE state read-only (BFS reachability within MOVE_RANGE for reach;
## the 4 orthogonal neighbours for push; ShootCommand.has_range/in_los + hit_chance per enemy for shoot).
## NOTHING here mutates state — it only reads. A "no legal target" caller can check the sets are empty.
func compute_targeting_layer(actor_id: int, armed_mode: int) -> Dictionary:
	var layer := {"reach": [], "push": [], "shoot": [], "armed": armed_mode}
	if state == null:
		return layer
	var me = state.entities.get(actor_id)
	if me == null or not me.is_unit or not me.alive:
		return layer
	# MOVE reachability — shown when MOVE is armed (or as the default affordance with a unit selected,
	# armed_mode == NONE). BFS over walkable 4-neighbours within MOVE_RANGE steps. Read-only.
	if armed_mode == InputIntent.Mode.MOVE or armed_mode == InputIntent.Mode.NONE:
		layer["reach"] = _reachable_tiles(me.pos)
	# PUSH tiles — the 4 orthogonally-adjacent tiles a SHOVE/SLAM/THROW targets (where an adjacent body
	# would be pushed FROM). Shown when a physics action is armed. Read-only.
	if armed_mode == InputIntent.Mode.SHOVE or armed_mode == InputIntent.Mode.SLAM or armed_mode == InputIntent.Mode.THROW:
		for d in [Vector2i(0, -1), Vector2i(1, 0), Vector2i(0, 1), Vector2i(-1, 0)]:
			var p: Vector2i = me.pos + d
			if state.in_bounds(p):
				layer["push"].append(p)
	# SHOOT targets — every enemy in range + LoS, with the to-hit % (the math already in ShootCommand)
	# and the cover/flank shield level. Shown when SHOOT is armed (or default with a unit selected). Read-only.
	if armed_mode == InputIntent.Mode.SHOOT or armed_mode == InputIntent.Mode.NONE:
		layer["shoot"] = _shootable_targets(me)
	return layer


## BFS the reachable MOVE tiles from `from` within MOVE_RANGE steps — walkable (in-bounds, not wall/gap,
## unoccupied) 4-neighbours, stable DIRS4 order. Returns the reachable tiles (excluding the start). PURE
## read of state — no mutation (mirrors MoveCommand walkability so the highlight matches what's legal).
func _reachable_tiles(from: Vector2i) -> Array:
	var out: Array = []
	var dist: Dictionary = {from: 0}
	var queue: Array = [from]
	var qi: int = 0
	while qi < queue.size():
		var cell: Vector2i = queue[qi]
		qi += 1
		var d: int = int(dist[cell])
		if d >= E.MOVE_RANGE:
			continue
		for dir in [Vector2i(0, -1), Vector2i(1, 0), Vector2i(0, 1), Vector2i(-1, 0)]:
			var np: Vector2i = cell + dir
			if dist.has(np):
				continue
			if not _tile_move_legal(np):
				continue
			dist[np] = d + 1
			out.append(np)
			queue.append(np)
	return out


## A tile a MOVE may legally step onto (for the reach overlay): in-bounds, not a wall/gap, unoccupied.
## Mirrors MoveCommand.validate's per-step legality. PURE read — no mutation.
func _tile_move_legal(p: Vector2i) -> bool:
	if not state.in_bounds(p):
		return false
	var t = state.tile(p)
	if t.terrain == E.Terrain.WALL or t.hazard == E.Hazard.GAP:
		return false
	return state.occupant_at(p) == null


## Every enemy `me` can SHOOT from its CURRENT tile: in range + LoS, with the to-hit % (ShootCommand.
## hit_chance) and a cover/flank shield level (0 none / 1 half / 2 full, from ShootCommand.cover_against
## with the flank exception). PURE read of state — uses the SAME static combat math the resolver does,
## so the displayed % is exactly the % that would be rolled. No mutation.
func _shootable_targets(me) -> Array:
	var out: Array = []
	for eid in state.entity_ids_sorted():
		var e = state.entities.get(eid)
		if e == null or not e.is_unit or not e.alive or e.faction != E.Faction.ENEMY:
			continue
		if not (ShootCommand.has_range(me.pos, e.pos) and ShootCommand.in_los(state, me.pos, e.pos)):
			continue
		var pct: int = ShootCommand.hit_chance(state, me, e)
		# Shield = the cover the target enjoys against THIS shot vector (0 if flanked — the flank
		# bypasses cover, so no shield glyph; the higher % already reflects the flank bonus).
		var shield: int = 0
		if not ShootCommand.is_flanked(state, me, e):
			shield = ShootCommand.cover_against(state, me, e)
		out.append({"cell": e.pos, "pct": pct, "shield": shield})
	return out


## True if the selected unit + armed action has NO legal target (the "no legal target" hint state, #16).
## SHOOT with no shootable enemy, a physics action with no adjacent movable target. Pure read.
func _no_legal_target(actor_id: int, armed_mode: int) -> bool:
	var layer: Dictionary = compute_targeting_layer(actor_id, armed_mode)
	match armed_mode:
		InputIntent.Mode.SHOOT:
			return (layer["shoot"] as Array).is_empty()
		InputIntent.Mode.SHOVE, InputIntent.Mode.SLAM, InputIntent.Mode.THROW:
			var me = state.entities.get(actor_id)
			if me == null:
				return true
			for d in [Vector2i(0, -1), Vector2i(1, 0), Vector2i(0, 1), Vector2i(-1, 0)]:
				var occ = state.occupant_at(me.pos + d)
				if occ != null and occ.movable:
					return false
			return true
		_:
			return false


## Push the current targeting layer to the CarView (render-only) + refresh the "no legal target" hint.
## Called whenever the selection / armed mode changes. No-op headless / no view. Pure UI — no sim effect.
func _refresh_targeting_overlay() -> void:
	if headless or view == null or intent == null:
		return
	var aid: int = intent.selected_id
	if aid < 0 or not _active_combat:
		view.clear_targeting_layer()
		return
	var layer: Dictionary = compute_targeting_layer(aid, intent.mode)
	view.set_targeting_layer(layer)
	# No-legal-target hint when an action is armed but nothing is targetable.
	if intent.mode != InputIntent.Mode.NONE and _no_legal_target(aid, intent.mode):
		if hud != null:
			hud.set_hint("NO LEGAL TARGET — %s has no valid %s here" % [
				_unit_name(aid), InputIntent.mode_name(intent.mode)])


## A unit's display name (for hints), or its id as a fallback.
func _unit_name(id: int) -> String:
	var e = state.entities.get(id) if state != null else null
	return e.name if e != null else str(id)


# ============================ MOVE PREVIEW (#22) ==============================
## Push / clear the MOVE-path preview overlay on the CarView (#22 — the §6.7 never-surprised tell). When
## MOVE is armed AND a destination tile is pointed, draw a dotted path + destination ring so MOVE matches
## the previewed SHOVE/SLAM bar. Any other state clears it. PURE read of state (BFS shortest path off the
## same walkability MoveCommand uses) — no sim/command mutation. No-op headless / no view.
func _refresh_move_preview(dest: Vector2i) -> void:
	if headless or view == null or intent == null:
		return
	if intent.mode != InputIntent.Mode.MOVE or intent.selected_id < 0 or not _active_combat:
		view.clear_move_preview()
		return
	var me = state.entities.get(intent.selected_id)
	if me == null or not me.is_unit:
		view.clear_move_preview()
		return
	if dest == Vector2i(-9999, -9999) or not state.in_bounds(dest):
		view.clear_move_preview()
		return
	var path: Array = _compute_move_path(me.pos, dest)
	if path.size() < 2:
		view.clear_move_preview()   # unreachable within MOVE_RANGE -> no path drawn (no false promise)
		return
	view.set_move_preview(path, dest)


## BFS the SHORTEST walkable path from `from` to `to` within MOVE_RANGE steps (incl. `from` at index 0).
## Returns [] if `to` is unreachable. Mirrors _reachable_tiles' walkability (in-bounds, not wall/gap,
## unoccupied) so the previewed path is exactly what a MOVE could legally take. PURE read — no mutation.
func _compute_move_path(from: Vector2i, to: Vector2i) -> Array:
	if from == to:
		return [from]
	var prev: Dictionary = {from: from}
	var dist: Dictionary = {from: 0}
	var queue: Array = [from]
	var qi: int = 0
	while qi < queue.size():
		var cell: Vector2i = queue[qi]
		qi += 1
		var d: int = int(dist[cell])
		if d >= E.MOVE_RANGE:
			continue
		for dir in [Vector2i(0, -1), Vector2i(1, 0), Vector2i(0, 1), Vector2i(-1, 0)]:
			var np: Vector2i = cell + dir
			if dist.has(np):
				continue
			# the destination tile itself may be occupied by the mover's own intent; allow `to`,
			# require legality for intermediate steps (same rule as _tile_move_legal).
			if np != to and not _tile_move_legal(np):
				continue
			if np == to and not _dest_move_legal(np):
				continue
			dist[np] = d + 1
			prev[np] = cell
			if np == to:
				# reconstruct
				var path: Array = [to]
				var cur: Vector2i = to
				while cur != from:
					cur = prev[cur]
					path.push_front(cur)
				return path
			queue.append(np)
	return []


## A tile a MOVE may legally LAND on (the destination): in-bounds, not wall/gap, unoccupied. Same as
## _tile_move_legal — split out for readability. PURE read.
func _dest_move_legal(p: Vector2i) -> bool:
	return _tile_move_legal(p)


# ============================ ACTION-PALETTE STATES (#19) =====================
## Compute + push the per-button palette states to the HUD (#19): per-AP affordability disable, the OVR
## overwatch selected/disabled state, the UNDO availability (off the InputIntent undo stack), CANCEL
## (a mode armed / a preview up), and re-assert the armed-mode selected-tint. Pure UI — no sim effect.
## Called whenever AP / selection / armed mode / overwatch changes. No-op headless / no hud.
func _refresh_palette_states() -> void:
	if headless or hud == null or intent == null:
		return
	var aid: int = intent.selected_id
	var has_unit: bool = (aid >= 0 and _active_combat)
	var ap: int = turn.ap_for(aid) if (has_unit and turn != null) else 0
	var can_act: bool = has_unit and turn != null and turn.can_act(aid)
	var me = state.entities.get(aid) if (has_unit and state != null) else null
	var overwatching: bool = (me != null and me.overwatch)
	var has_target_for := func(mode: int) -> bool: return has_unit and not _no_legal_target(aid, mode)
	var states := {
		"MOVE":   {"enabled": can_act and ap > 0},
		"SHOOT":  {"enabled": can_act and ap > 0 and has_target_for.call(InputIntent.Mode.SHOOT)},
		"SHOVE":  {"enabled": can_act and ap > 0 and has_target_for.call(InputIntent.Mode.SHOVE)},
		"SLAM":   {"enabled": can_act and ap > 0 and has_target_for.call(InputIntent.Mode.SLAM)},
		"THROW":  {"enabled": can_act and ap > 0 and has_target_for.call(InputIntent.Mode.THROW)},
		"ABILITY": {"enabled": can_act and ap > 0 and _has_usable_ability(aid, ap)},
		"ITEM":    {"enabled": can_act and ap > 0 and _has_usable_item(aid, ap)},
		"OVR":    {"enabled": can_act and ap > 0 and not overwatching, "selected": overwatching},
		"UNDO":   {"enabled": has_unit and not intent._undo_stack.is_empty()},
		"CANCEL": {"enabled": has_unit and intent.mode != InputIntent.Mode.NONE},
		"END":    {"enabled": has_unit},
	}
	hud.set_palette_states(states)
	# W5-12: surface the STABILIZE palette button (touch parity — it was keyboard-only) whenever a
	# comrade is bleeding out and the selected unit can spend AP; adjacency is validated on commit.
	hud.set_stabilize_available(can_act and ap > 0 and _ally_bleeding_out())
	hud.set_vet_available(not _betrayer_scan_used)   # W6-11: the one-per-run betrayer scan button state
	hud.set_armed_mode(InputIntent.mode_name(intent.mode) if (has_unit and intent.mode != InputIntent.Mode.NONE) else "")
	# COMBAT ONBOARDING (combat-ux #7): the first time a depth verb becomes AVAILABLE, surface its tip
	# proactively (so the player learns the verb EXISTS, not just after they stumble onto it). Each fires
	# once ever (should_fire gates on the persisted seen-set). Purely reads the states just computed +
	# the live board — no sim mutation. _maybe_tip no-ops headless / in --sim / with tips off.
	if bool(states["SHOVE"]["enabled"]) or bool(states["SLAM"]["enabled"]):
		_maybe_tip("displace")
	if bool(states["ABILITY"]["enabled"]):
		_maybe_tip("ability")
	if bool(states["ITEM"]["enabled"]):
		_maybe_tip("item")
	if bool(states["OVR"]["enabled"]):
		_maybe_tip("overwatch")
	# Situational tips: the flood->electrify CHAIN when water/soak is on the board, and STABILIZE when
	# an ally is bleeding out (the one verb a first-timer never discovers before the unit permadies).
	# The board scans are guarded by should_fire so they cost nothing once seen / when tips are off.
	if _tips != null and not sim_mode:
		if _tips.should_fire("combo") and _water_on_board():
			_maybe_tip("combo")
		if _tips.should_fire("stabilize") and _ally_bleeding_out():
			_maybe_tip("stabilize")


# ============================ COMBAT ONBOARDING TIPS (combat-ux #7) ===========
## Surface an onboarding tip ONCE, the first time it is relevant. No-op headless, in --sim AUTO, when
## tips are globally off, or when the id was already shown (should_fire gates all of that). On a fire:
## mark it seen + PERSIST the profile immediately (so a crash/quit never re-nags), raise the dismissible
## banner, and drop a comms breadcrumb. Never touches the sim or the event stream — byte-identical.
func _maybe_tip(id: String) -> void:
	if headless or sim_mode or hud == null or _tips == null:
		return
	if not _tips.should_fire(id):
		return
	_tips.mark_fired(id)
	_persist_tips()
	hud.show_tip(_tips.title(id), _tips.body(id))
	_log_hud("> TIP: %s" % _tips.short(id))


## Persist the just-updated seen-tips set to the on-disk profile (combat-ux #7). Rare (once per tip
## ever); the atomic SaveSystem makes the write crash-safe. On-screen-only.
func _persist_tips() -> void:
	if _tip_profile == null or _tips == null:
		return
	_tip_profile.seen_tips = _tips.seen_list()
	SaveSystem.save_profile(_tip_profile)


## The operator dismissed the tip banner ([ GOT IT ] / ESC). It was already marked seen on show, so
## this only re-focuses combat — refresh the hint so the flow reads on. On-screen-only.
func _on_tip_dismissed() -> void:
	if headless or hud == null:
		return
	if intent != null and intent.selected_id >= 0 and turn != null:
		hud.set_hint("UNIT %s — pick an action (AP %d)" % [_unit_name(intent.selected_id), turn.ap_for(intent.selected_id)])


## True if any water/soak is on the board (the flood->electrify CHAIN is teachable). Reads-only.
func _water_on_board() -> bool:
	if state == null:
		return false
	# A soaked enemy is the clearest cue; else any standing water tile.
	for id in state.entity_ids_sorted():
		var e = state.entities.get(id)
		if e != null and e.alive and e.is_unit and e.faction == E.Faction.ENEMY and e.has_status(E.S_SOAKED):
			return true
	for y in range(state.height):
		for x in range(state.width):
			var t = state.tile(Vector2i(x, y))
			if t != null and t.has_layer(E.L_WATER):
				return true
	return false


## True if any PLAYER unit is downed and still bleeding out (the STABILIZE window). Reads-only.
func _ally_bleeding_out() -> bool:
	if state == null:
		return false
	for id in state.entity_ids_sorted():
		var e = state.entities.get(id)
		if e != null and e.is_unit and e.faction == E.Faction.PLAYER and e.downed and e.has_status(E.S_BLEEDING):
			return true
	return false


# ---- on-screen input + control wiring ----
## Select the first player unit that can still act this phase (drives the HUD highlight + AP).
func _select_first_actor() -> void:
	for id in state.entity_ids_sorted():
		var e = state.entities.get(id)
		if e != null and e.is_unit and e.alive and e.faction == E.Faction.PLAYER and turn.can_act(id):
			_select_unit_onscreen(id)
			return
	hud.set_hint("PLAYER PHASE — no unit can act (END to continue)")


func _select_unit_onscreen(id: int) -> void:
	if intent == null:
		return
	if intent.select_unit(id):
		hud.set_actions_enabled(true)
		hud.set_ap(turn.ap_for(id), E.AP_PER_TURN)
		if view != null:
			view.set_highlight(id)
		var e = state.entities.get(id)
		var nm: String = e.name if e != null else str(id)
		hud.set_hint("UNIT %s — pick an action (AP %d)" % [nm, turn.ap_for(id)])
		# A fresh selection shows the default reachable-move + shootable affordances (#16) and resets
		# the palette states (#19/#20) — no action armed yet, so the move/shoot defaults are surfaced.
		_refresh_targeting_overlay()
		_refresh_palette_states()
		_maybe_tip("select")   # combat-ux #7 — the very first unit selection teaches the basics


## True if any player unit still has AP this phase.
func _any_player_can_act() -> bool:
	for id in state.entity_ids_sorted():
		var e = state.entities.get(id)
		if e != null and e.is_unit and e.alive and e.faction == E.Faction.PLAYER and turn.can_act(id):
			return true
	return false


## W7-9: has the current fight been DECIDED (a win or loss reported by check_victory)? True the instant
## the board resolves, so the interactive player phase can release WITHOUT the operator ending every unit
## still holding AP on a cleared board. Safe before a fight is built (turn null -> false).
func _combat_decided() -> bool:
	return turn != null and turn.check_victory() != 0


## HUD action button -> InputIntent. MOVE/SHOOT/SHOVE/SLAM/THROW arm a mode (then a tile click
## previews + a second click/confirm commits); OVR fires Overwatch immediately; END yields the
## selected unit's turn and advances to the next actor (or releases the phase).
func _on_hud_action(name: String) -> void:
	if headless:
		return
	# W6-11: the betrayer VET/SCAN counterplay is reachable OUTSIDE combat too (a pre-captain vetting
	# action), so it is handled before the in-combat guard. FLAGGED for a real ops_hud button (render lane).
	if name == "VET" or name == "SCAN":
		scan_for_betrayer()
		return
	if intent == null or not _active_combat:
		return
	match name:
		"MOVE":  intent.choose_action(InputIntent.Mode.MOVE);  hud.set_hint("MOVE — click a destination tile")
		"SHOOT": intent.choose_action(InputIntent.Mode.SHOOT); hud.set_hint("SHOOT (ends turn) — click an enemy"); _maybe_tip("shoot")
		"SHOVE": intent.choose_action(InputIntent.Mode.SHOVE); hud.set_hint("SHOVE — click an adjacent target")
		"SLAM":  intent.choose_action(InputIntent.Mode.SLAM);  hud.set_hint("SLAM — click an adjacent target")
		"THROW": intent.choose_action(InputIntent.Mode.THROW); hud.set_hint("THROW — click an adjacent target")
		"STAB":  intent.choose_action(InputIntent.Mode.STABILIZE); hud.set_hint("STABILIZE — click an adjacent downed ally (1 AP)")
		"ABILITY": _open_ability_menu()
		"ITEM":    _open_item_menu()
		"OVR":   _commit_overwatch()
		"UNDO":  _undo_move()
		"CANCEL": _cancel_armed()
		"END":   _end_selected_unit()
		_: pass
	# Arming/disarming an action re-skins the legibility overlay + the palette states (#16/#19/#20).
	_refresh_targeting_overlay()
	_refresh_palette_states()
	# Arming an action (re)sets the move preview: it shows only once a MOVE destination is pointed, so
	# arming MOVE (or any other action) clears any stale path until the next point (#22).
	if view != null:
		view.clear_move_preview()


## Fire Overwatch on the selected unit immediately (no target tile needed).
func _commit_overwatch() -> void:
	if intent == null or intent.selected_id < 0:
		return
	var oc := OverwatchCommand.new(intent.selected_id)
	var r: Dictionary = turn.try_command(oc)
	if r.ok:
		_play(r.events)
		_sync_view()
		_log_hud("> OVERWATCH armed.")
	_after_unit_action()


## UNDO the selected unit's last MOVEMENT (#20). Routes to the existing InputIntent.undo() — restores
## the tile + refunds 1 AP (movement only; physics/attacks are non-undoable). Re-syncs the view, the
## legibility overlay, and the palette states. On-screen-only; no-op when the undo stack is empty
## (intent.undo() rejects with "nothing to undo"). NEVER changes any committed command outcome.
func _undo_move() -> void:
	if intent == null:
		return
	if intent.undo():
		_log_hud("> UNDO — move reversed (AP refunded).")
		_sync_view()
	_refresh_targeting_overlay()
	_refresh_palette_states()


## CANCEL the armed action / clear the pending preview (#20). Routes to the existing InputIntent.cancel()
## — drops the preview ghost + disarms the mode WITHOUT leaving the run or ending the unit's turn. The
## unit stays selected with its AP intact. On-screen-only. NEVER changes any committed command outcome.
func _cancel_armed() -> void:
	if intent == null:
		return
	intent.cancel()
	_last_point = Vector2i(-9999, -9999)
	if view != null:
		view.clear_move_preview()   # #22 — disarming clears the move path preview
	if intent.selected_id >= 0:
		_log_hud("> CANCEL — action disarmed.")
		hud.set_hint("UNIT %s — pick an action (AP %d)" % [_unit_name(intent.selected_id), turn.ap_for(intent.selected_id)])
	_refresh_targeting_overlay()
	_refresh_palette_states()


## End the selected unit's turn and move to the next actor (or release the phase).
func _end_selected_unit() -> void:
	if intent != null and intent.selected_id >= 0:
		turn.end_unit(intent.selected_id)
	_after_unit_action()


## After any committed/ended action: if the unit is spent, advance to the next actor; if none can
## act, release the phase. Otherwise refresh the AP/hint for the still-acting unit.
func _after_unit_action() -> void:
	if not _active_combat or intent == null:
		return
	var sel: int = intent.selected_id
	if sel >= 0 and turn.can_act(sel):
		hud.set_ap(turn.ap_for(sel), E.AP_PER_TURN)
		var e = state.entities.get(sel)
		var nm: String = e.name if e != null else str(sel)
		hud.set_hint("UNIT %s — pick an action (AP %d)" % [nm, turn.ap_for(sel)])
		# The unit acted but still has AP — re-skin the affordance overlay + palette (#16/#19/#20).
		_refresh_targeting_overlay()
		_refresh_palette_states()
		_refresh_team_turn("PLAYER PHASE")   # #18 — chip flips to spent as a unit runs out of AP
		return
	_refresh_team_turn("PLAYER PHASE")
	if _any_player_can_act():
		_select_first_actor()
	else:
		_awaiting_player = false
		if view != null:
			view.clear_targeting_layer()


# ============================ ABILITY / ITEM DEPTH TOOLKIT (Batch 6) ==========
## Raise the ABILITY picker for the selected unit — the unit's ACTIVE ability kit (chosen_abilities
## filtered to castable kinds), each row enabled per AP. Selecting one arms it (_on_ability_chosen).
func _open_ability_menu() -> void:
	if headless or hud == null or intent == null or intent.selected_id < 0:
		return
	hud.open_choice_menu("ability", "ABILITIES", _usable_ability_entries(intent.selected_id))


## Raise the ITEM picker — the unit's carried COMBAT items (consumables + active gadgets from gear),
## each row enabled per AP. Passive armor/weapons are excluded (they are stat equipment, not usable).
func _open_item_menu() -> void:
	if headless or hud == null or intent == null or intent.selected_id < 0:
		return
	hud.open_choice_menu("item", "ITEMS", _usable_item_entries(intent.selected_id))


## The operator picked an ability from the popup — arm it on the InputIntent. A targeted ability now
## waits for a tile/target tap (two-tap commit); a `self` ability was prepared on arm, so commit now.
func _on_ability_chosen(aid: String) -> void:
	if headless or intent == null or intent.selected_id < 0 or db == null:
		return
	var def: Dictionary = db.ability(aid)
	if def.is_empty():
		return
	if intent.arm_ability(def):
		if String(def.get("targeting", "self")) == "self":
			intent.confirm()   # no target to point — fire immediately
		else:
			hud.set_hint("%s — %s" % [String(def.get("name", aid)), _targeting_hint(String(def.get("targeting", "self")))])
	_refresh_targeting_overlay()
	_refresh_palette_states()


## The operator picked a consumable/gadget — arm it. Same two-tap flow; a `self` item fires now.
func _on_item_chosen(iid: String) -> void:
	if headless or intent == null or intent.selected_id < 0 or db == null:
		return
	var def: Dictionary = db.item(iid)
	if def.is_empty():
		return
	if intent.arm_item(def, iid):
		if String(def.get("targeting", "self")) == "self":
			intent.confirm()
		else:
			hud.set_hint("%s — %s" % [String(def.get("name", iid)), _targeting_hint(String(def.get("targeting", "self")))])
	_refresh_targeting_overlay()
	_refresh_palette_states()


## PURE draw-data for the ABILITY popup: one row per ACTIVE ability the selected unit knows (its
## persistent chosen_abilities, resolved via the run.squad back-link), each { id,label,enabled,reason }.
## An ability is offered iff at least one effect kind is castable (AbilitySystem.ACTIVE_KINDS); it is
## enabled iff the unit can currently afford its apCost. Passive-only picks (Bracing/Juggernaut) never
## appear here — they already ride the body as hooks. Stable order (chosen_abilities order).
func _usable_ability_entries(id: int) -> Array:
	var out: Array = []
	var e = state.entities.get(id) if state != null else null
	if e == null or db == null:
		return out
	var inst = _instance_by_id(e.instance_id)
	if inst == null:
		return out
	var ap: int = turn.ap_for(id) if turn != null else 0
	for aid in inst.chosen_abilities:
		var def: Dictionary = db.ability(String(aid))
		if def.is_empty() or not _ability_is_active(def):
			continue
		var cost: int = int(def.get("apCost", 1))
		var enabled: bool = ap >= cost
		var label: String = "%s  (%d AP)" % [String(def.get("name", aid)), cost]
		out.append({"id": String(aid), "label": label, "enabled": enabled,
			"reason": ("" if enabled else "needs %d AP" % cost),
			"hint": OpsHUD.effect_hint(def)})   # W5-6: a readable effect + AP + range sub-line
	return out


## PURE draw-data for the ITEM popup: one row per DISTINCT combat item the selected unit carries
## (SimEntity.gear filtered to consumable/gadget slots), each { id,label,enabled,reason }. Consumables
## show their carried count; each is enabled iff the unit can afford its apCost. Passive armor/weapons
## are excluded. Stable order (first-seen gear order).
func _usable_item_entries(id: int) -> Array:
	var out: Array = []
	var e = state.entities.get(id) if state != null else null
	if e == null or db == null:
		return out
	var ap: int = turn.ap_for(id) if turn != null else 0
	var seen: Dictionary = {}
	for gid in e.gear:
		var key: String = String(gid)
		if seen.has(key):
			continue
		var def: Dictionary = db.item(key)
		var slot: String = def.get("slot", "")
		if def.is_empty() or (slot != "consumable" and slot != "gadget"):
			continue   # passive equipment (armor/weapon) — not usable
		seen[key] = true
		var count: int = 0
		for g in e.gear:
			if String(g) == key:
				count += 1
		var cost: int = int(def.get("apCost", 1))
		var enabled: bool = ap >= cost
		var qty: String = ("  x%d" % count) if slot == "consumable" else ""
		var label: String = "%s%s  (%d AP)" % [String(def.get("name", key)), qty, cost]
		out.append({"id": key, "label": label, "enabled": enabled,
			"reason": ("" if enabled else "needs %d AP" % cost),
			"hint": OpsHUD.effect_hint(def)})   # W5-6: a readable effect + AP + range sub-line
	return out


## True if an AbilityDef has at least one effect the engine EXECUTES (a castable/active ability), vs a
## passive-only pick (all hooks) that is never offered on the ABILITY popup.
func _ability_is_active(def: Dictionary) -> bool:
	for eff in def.get("effects", []):
		if AbilitySystem.ACTIVE_KINDS.has(eff.get("kind", "")):
			return true
	return false


## Palette-affordance predicate: does the unit have ANY active ability it can afford right now?
func _has_usable_ability(id: int, ap: int) -> bool:
	for e in _usable_ability_entries(id):
		if bool(e.get("enabled", false)):
			return true
	return false


## Palette-affordance predicate: does the unit carry ANY combat item it can afford right now?
func _has_usable_item(id: int, ap: int) -> bool:
	for e in _usable_item_entries(id):
		if bool(e.get("enabled", false)):
			return true
	return false


## One-line targeting prompt for the armed ability/item's targeting kind.
func _targeting_hint(targeting: String) -> String:
	match targeting:
		"enemy":     return "click an enemy in range"
		"ally":      return "click an ally in range"
		"tile":      return "click a target tile"
		"direction": return "click an adjacent direction"
		_:           return "click to confirm"


## A tile was clicked on the CarView: route it to InputIntent. If a unit/action is armed and a
## valid preview is pending, a SECOND click on the same target confirms (two-tap commit, §16);
## otherwise clicking a friendly unit (re)selects it.
func _on_tile_clicked(cell: Vector2i) -> void:
	if headless or intent == null or not _active_combat or sim_mode:
		return
	# FINALE objective targeting (Batch 3): a tap on a RELAY / exposed CORE while no unit-combat action
	# is armed routes through the two-tap objective seam (break relay -> shield drop -> sabotage core).
	# Falls through to normal unit combat otherwise so the operator can still fight robots/turrets.
	if _in_finale and intent.mode == InputIntent.Mode.NONE:
		if _on_finale_tile(cell):
			return
	_route_tile_tap(cell)


## The display-independent tap router (extracted from _on_tile_clicked so input_smoke can drive
## the EXACT two-tap seam headlessly): select / infer / preview / confirm, plus the W1-6
## stale-preview guard — a REJECTED re-point clears the armed pending action so a second tap on
## the rejected cell can never commit the PREVIOUS preview at a different target (preview ==
## outcome, invariant #2). Every view/hud touch inside is null-safe.
func _route_tile_tap(cell: Vector2i) -> void:
	var occ = state.occupant_at(cell)
	# Click a friendly unit with no action armed -> select it.
	if occ != null and occ.is_unit and occ.faction == E.Faction.PLAYER and intent.mode == InputIntent.Mode.NONE:
		_select_unit_onscreen(occ.id)
		return
	if intent.selected_id < 0:
		_select_first_actor()
		return
	# DIRECT click-to-act (XCOM-style): a unit is selected but no action is armed — infer it from
	# WHAT was clicked (an enemy → SHOOT, an empty passable tile → MOVE) so the operator does NOT
	# have to arm a mode on the palette first. SHOVE/SLAM/THROW/OVERWATCH stay explicit on the palette.
	if intent.mode == InputIntent.Mode.NONE:
		var inferred := _infer_click_action(cell)
		if inferred == InputIntent.Mode.NONE:
			return
		intent.choose_action(inferred)
		if hud != null:
			hud.set_hint("%s — click again to confirm" % InputIntent.mode_name(inferred))
	# Two-tap commit: first click previews, a second click on the same cell confirms. The commit
	# advances to the next actor inside _on_intent_committed (the animated commit handler), so we
	# do NOT advance again here.
	if intent.phase == InputIntent.Phase.PREVIEWING and _last_point == cell:
		if view != null:
			view.clear_move_preview()   # #22 — the move commits; drop the path preview
		intent.confirm()
		_last_point = Vector2i(-9999, -9999)
		return
	_point_rejected = false
	intent.point_tile(cell)
	if _point_rejected:
		# W1-6 stale-preview guard: InputIntent keeps the OLD pending command when a re-point
		# rejects, so without this a second tap on the rejected cell would confirm() the previous
		# action at a different target. Drop the pending preview (mode stays armed) and disarm
		# the two-tap so nothing commits until a fresh VALID preview exists.
		_point_rejected = false
		intent.cancel()
		_last_point = Vector2i(-9999, -9999)
		if view != null:
			view.clear_move_preview()
		_refresh_targeting_overlay()
		_refresh_palette_states()
		return
	_last_point = cell
	_refresh_targeting_overlay()
	_refresh_palette_states()
	_refresh_move_preview(cell)   # #22 — show the dotted move path + destination ring on a MOVE point
	# SETTINGS (release-readiness #3): with "Confirm before committing a move" OFF, a MOVE commits on
	# the FIRST tap (skip the two-tap). Only MOVE — physics/shoot always keep the deliberate confirm.
	if not _confirm_moves() and intent.mode == InputIntent.Mode.MOVE and intent.phase == InputIntent.Phase.PREVIEWING:
		if view != null:
			view.clear_move_preview()
		intent.confirm()
		_last_point = Vector2i(-9999, -9999)


## Infer the default action for a bare tile click (no mode armed): an enemy → SHOOT, an empty
## passable tile → MOVE, anything else → NONE (no-op). Lets the operator click-to-move/attack
## directly without arming a palette button first. Pure read — never mutates state.
func _infer_click_action(cell: Vector2i) -> int:
	var occ = state.occupant_at(cell)
	if occ != null and occ.is_unit and occ.faction == E.Faction.ENEMY:
		return InputIntent.Mode.SHOOT
	if occ == null and state.in_bounds(cell):
		var t = state.tile(cell)
		if t.terrain != E.Terrain.WALL and t.hazard != E.Hazard.GAP:
			return InputIntent.Mode.MOVE
	return InputIntent.Mode.NONE


var _last_point: Vector2i = Vector2i(-9999, -9999)
var _point_rejected: bool = false   # W1-6 — latched by _on_intent_rejected during a point_tile


## Click + key handling for the on-screen interactive loop (no-op headless / when not in combat).
func _unhandled_input(event: InputEvent) -> void:
	if headless:
		return
	# End-of-run state: the sticky ENDING CARD is up. The flow is a TWO-STEP (S6-1 -> S6-2 -> HOME):
	# the FIRST ENTER/CLICK reveals the after-action PAYOUT LEDGER (the finalize already ran in
	# _show_ending); the SECOND ENTER/CLICK returns to the console. N starts a fresh run from either
	# step (the finalize already persisted, so the new run sees the updated currency/memorial). This
	# is the ONLY input path once a run resolves (combat is gated off). Never reached headless.
	if _run_over:
		if event is InputEventMouseButton and event.pressed and event.button_index == MOUSE_BUTTON_LEFT:
			_advance_end_state()
		elif event is InputEventKey and event.pressed and not event.echo:
			if event.keycode == KEY_N:
				_start_new_run()
			else:
				_advance_end_state()
		return
	# INTERACTIVE DRAFT (S2): the draft surface owns input while it is up. Key affordances mirror the
	# spec's hint row ([1][2][3] inspect · [T] take · [D] decline · [B] breach · ESC abandon); on the
	# BREACH_CONFIRM overlay ENTER/SPACE = GO, ESC = abandon. Card/control clicks come through the
	# RunScreens Buttons (their own signals), so the mouse path needs no handling here.
	if _in_draft:
		if event is InputEventKey and event.pressed and not event.echo:
			_draft_key(event.keycode)
		return
	# INTERACTIVE ECONOMY CARS (S3): the econ surface owns input while up. Number keys 1/2/3 select an
	# OPTION ROW (preview), ENTER/SPACE commits the selected, ESC -> the safe-default LEAVE (the screen
	# resolves the car with its byte-stable default, never a dead end). OPTION ROW clicks come through
	# the RunScreens Buttons (their own signals), so the mouse path needs no handling here.
	if _in_econ:
		if event is InputEventKey and event.pressed and not event.echo:
			_econ_key(event.keycode)
		return
	# LEVEL-UP overlay (S3-LEVELUP): the modal owns input while up. 1/2 select-or-pick an ability card
	# (two-tap, matching the click), ENTER/SPACE picks the selected. No ESC/LEAVE — a level-up must
	# resolve (the queue auto-picks option 0 as the never-stuck valve). Card clicks come through the
	# RunScreens Buttons, so the mouse path needs no handling here.
	if _in_levelup:
		if event is InputEventKey and event.pressed and not event.echo:
			_levelup_key(event.keycode)
		return
	# DEPLOY picker (combat-ux #6): owns input while up. 1-9 toggle a member row, ENTER/SPACE = DEPLOY,
	# ESC = accept the current/default pick. Row clicks come through the RunScreens Buttons.
	if screens != null and screens.deploy_open():
		if event is InputEventKey and event.pressed and not event.echo:
			_deploy_key(event.keycode)
		return
	# ABANDON RUN? guard (combat-ux #4): while up it owns input — ENTER/SPACE/Y = SAVE & EXIT,
	# ESC/N = KEEP FIGHTING. Its own buttons handle the mouse (the dim wash blocks combat clicks).
	if screens != null and screens.abandon_open():
		if event is InputEventKey and event.pressed and not event.echo:
			match event.keycode:
				KEY_ENTER, KEY_KP_ENTER, KEY_SPACE, KEY_Y:
					_on_abandon_save_exit()
				KEY_ESCAPE, KEY_N:
					_on_abandon_keep()
		return
	# RECON CARD detail overlay (#11): a modal HUD panel. While it is up, ESC dismisses it (no dead end)
	# and does NOT leave the run; its own DISMISS button + a click elsewhere close it through the HUD.
	if hud != null and hud.recon_card_open():
		if event is InputEventKey and event.pressed and not event.echo and event.keycode == KEY_ESCAPE:
			hud.dismiss_recon_card()
		return
	# ABILITY/ITEM picker (Batch 6): a modal HUD popup. While up, ESC closes it (no dead end) and
	# input does NOT leak to the feed; its own rows + CLOSE button resolve through the HUD's GUI.
	if hud != null and hud.choice_menu_open():
		if event is InputEventKey and event.pressed and not event.echo and event.keycode == KEY_ESCAPE:
			hud.close_choice_menu()
		return
	# COMBAT TIP banner (combat-ux #7): a NON-blocking teaching card — combat keeps running under it, so
	# we ONLY intercept ESC (dismiss the tip, never abandon the run). Its [ GOT IT ] button owns the
	# click; every other input falls through to the normal combat handling below.
	if hud != null and hud.tip_open():
		if event is InputEventKey and event.pressed and not event.echo and event.keycode == KEY_ESCAPE:
			hud.hide_tip()
			_on_tip_dismissed()
			return
	if event is InputEventMouseButton and event.pressed and event.button_index == MOUSE_BUTTON_LEFT:
		if _active_combat and view != null:
			var cell := Iso.screen_to_tile(view.get_local_mouse_position(), view.origin)
			if state != null and state.in_bounds(cell):
				_on_tile_clicked(cell)
		return
	if event is InputEventKey and event.pressed and not event.echo:
		match event.keycode:
			KEY_ESCAPE:
				# ABANDON guard already up? ESC = KEEP FIGHTING (dismiss) — never a double-exit.
				if screens != null and screens.abandon_open():
					_on_abandon_keep()
				# GUARD (#20): ESC while a combat action is ARMED only DISARMS (intent.cancel) — it must
				# NOT leave the run mid-targeting.
				elif _active_combat and not sim_mode and intent != null and intent.mode != InputIntent.Mode.NONE:
					_cancel_armed()
				else:
					# combat-ux #4: ESC no longer instantly nukes the run — raise the ABANDON RUN?
					# confirm (progress is checkpointed, so SAVE & EXIT resumes later via CONTINUE).
					_request_abandon()
			KEY_U:
				# UNDO MOVE (#20): reverse the selected unit's last movement (movement-only; refunds AP).
				if _active_combat and not sim_mode:
					_undo_move()
			KEY_S:
				# STABILIZE (§7.4 ally aid): arm the manual stabilize verb so a human can stop a
				# downed comrade's bleed-out — then click the adjacent Downed ally to commit (two-tap).
				# Manual parity with the AUTO pilot's free triage. On-screen-only (never headless).
				if _active_combat and not sim_mode and intent != null and intent.selected_id >= 0:
					_on_hud_action("STAB")
			KEY_A:
				if _active_combat:
					# W6-2: A engages THIS-FIGHT-ONLY AUTO (auto-pilots this combat, reverts to MANUAL at
					# car clear — no silent permanent picks). SHIFT+A widens it to the WHOLE run (the explicit
					# opt-in). FLAG (render): an ops_hud fight/run scope toggle can call the same seams.
					if event.shift_pressed:
						_set_auto_whole_run()
					else:
						_toggle_auto()
			KEY_F:
				if _active_combat:
					_cycle_speed()
			KEY_SPACE, KEY_ENTER:
				if _active_combat and not sim_mode:
					_end_selected_unit()


## Keyboard control for the interactive draft surface. During VETTING: 1/2/3 select-or-take a card
## (two-tap to commit), T takes the selected card, D declines, Q quick-drafts, B breaches (picks>=1),
## ESC abandons. During BREACH_CONFIRM: ENTER/SPACE = GO, B = GO, ESC/Backspace = abandon.
func _draft_key(keycode: int) -> void:
	if _awaiting_breach:
		match keycode:
			KEY_ENTER, KEY_KP_ENTER, KEY_SPACE, KEY_B:
				_on_breach_go()
			KEY_ESCAPE, KEY_BACKSPACE:
				_breach_action = "abandon"
			_: pass
		return
	if _awaiting_draft:
		match keycode:
			KEY_1: _draft_key_card(0)
			KEY_2: _draft_key_card(1)
			KEY_3: _draft_key_card(2)
			KEY_T:
				if _draft != null and _draft_screen_selected() >= 0:
					_on_draft_take(_draft_screen_selected())
			KEY_D: _on_draft_decline()
			KEY_Q: _on_draft_auto()
			KEY_B: _on_draft_breach()
			KEY_ESCAPE: _draft_action = "abandon"
			_: pass


## 1/2/3 key on a candidate: first press previews (selects on the surface), a second press of the
## same index commits the take (matches the two-tap card click).
func _draft_key_card(idx: int) -> void:
	if _draft == null or idx < 0 or idx >= _draft.current_choices.size():
		return
	if _draft_screen_selected() == idx:
		_on_draft_take(idx)
	elif screens != null:
		screens._selected_idx = idx
		screens._apply_card_selection()
		screens._update_draft_controls(_draft)


## The candidate index the surface currently has previewed (-1 = none).
func _draft_screen_selected() -> int:
	return int(screens._selected_idx) if screens != null else -1


## Keyboard control for the interactive economy surface. 1/2/3 select-or-commit an OPTION ROW (a
## first press previews, a second press of the SAME row commits — two-tap, matching the card click);
## ENTER/SPACE commits the selected row; ESC resolves with the safe-default LEAVE. A disabled row is
## a no-op (the surface gates it). Never reached headless.
func _econ_key(keycode: int) -> void:
	if not _awaiting_econ or screens == null:
		return
	if keycode == KEY_1:
		_econ_key_row(0)
	elif keycode == KEY_2:
		_econ_key_row(1)
	elif keycode == KEY_3:
		_econ_key_row(2)
	elif keycode == KEY_ENTER or keycode == KEY_KP_ENTER or keycode == KEY_SPACE:
		var sel = screens.econ_selected()
		if String(sel) != "":
			_econ_action = "commit:%s" % String(sel)
	elif keycode == KEY_ESCAPE:
		_econ_action = "leave"


## 1/2/3 on an OPTION ROW: first press previews (selects on the surface), a second press of the same
## row commits the option (matches the two-tap row click). Clamped to the rendered option list.
func _econ_key_row(idx: int) -> void:
	if screens == null:
		return
	var ids: Array = screens.econ_option_ids()
	if idx < 0 or idx >= ids.size():
		return
	var oid := String(ids[idx])
	if String(screens.econ_selected()) == oid:
		_econ_action = "commit:%s" % oid
	else:
		screens.econ_select_option(oid)


## Keyboard control for the LEVEL-UP overlay (S3-LEVELUP). 1/2 select-or-pick an ability card (a first
## press previews, a second press of the SAME card picks — two-tap, matching the click); ENTER/SPACE
## picks the currently-selected card. No ESC/LEAVE — a level-up must resolve. Never reached headless.
func _levelup_key(keycode: int) -> void:
	if not _awaiting_levelup or screens == null:
		return
	if keycode == KEY_1:
		_levelup_key_card(0)
	elif keycode == KEY_2:
		_levelup_key_card(1)
	elif keycode == KEY_ENTER or keycode == KEY_KP_ENTER or keycode == KEY_SPACE:
		var sel := String(screens.levelup_selected())
		if sel != "":
			_levelup_action = "pick:%s" % sel


## 1/2 on an ability card: first press previews (selects on the surface), a second press of the same
## index picks it (matches the two-tap card click). Clamped to the rendered option list.
func _levelup_key_card(idx: int) -> void:
	if screens == null:
		return
	var ids: Array = screens.levelup_option_ids()
	if idx < 0 or idx >= ids.size():
		return
	var aid := String(ids[idx])
	if String(screens.levelup_selected()) == aid:
		_levelup_action = "pick:%s" % aid
	else:
		screens.levelup_select_ability(aid)


## Advance the end-of-run two-step on an ENTER/CLICK (S6-1 -> S6-2 -> HOME). First press reveals the
## PAYOUT LEDGER; the next press returns to the console. On-screen-only.
func _advance_end_state() -> void:
	if not _payout_shown:
		_advance_to_payout()
	else:
		_leave_to_menu()


## Raise the ABANDON RUN? confirm (combat-ux #4). ESC no longer instantly destroys a run; the
## operator must confirm SAVE & EXIT (progress is checkpointed, so CONTINUE resumes it) or KEEP
## FIGHTING. No-op if the run is already over or there's no screen surface (falls back to leaving).
func _request_abandon() -> void:
	if _run_over:
		_leave_to_menu()
		return
	if screens == null:
		# No surface to confirm on — save then leave (never silently drop the run).
		_save_run_checkpoint()
		_leave_to_menu()
		return
	# Disarm any pending action + pause the auto-advance while the guard is up.
	if intent != null and intent.mode != InputIntent.Mode.NONE:
		_cancel_armed()
	screens.show_abandon_confirm()


## SAVE & EXIT on the abandon guard: checkpoint the run, then return to the console. CONTINUE will
## offer this run (it re-enters the current car from the run seed on resume).
func _on_abandon_save_exit() -> void:
	if screens != null:
		screens.hide_abandon_confirm()
	_save_run_checkpoint()
	_leave_to_menu()


## KEEP FIGHTING on the abandon guard: dismiss + resume the run untouched.
func _on_abandon_keep() -> void:
	if screens != null:
		screens.hide_abandon_confirm()
	if hud != null:
		hud.set_hint("MANUAL — your move")


## Return to the ops-console main menu (on-screen-only; never reached headless).
func _leave_to_menu() -> void:
	get_tree().change_scene_to_file("res://app/menu.tscn")


## Reload the run scene for a fresh run (on-screen-only; never reached headless). W1-8: the
## previous controller's consume_handoff drained Menu.MenuHandoff, so restage it from the
## PERSISTED profile first — the [N] quick-restart must equal a menu-launched run (same
## additive unlock gate, same session settings, a fresh W1-5 seed). An armed Legacy stays
## menu-only (arming lives in the menu's _chosen_legacy_id and cannot be pending here).
func _start_new_run() -> void:
	restage_handoff_from_profile(SaveSystem.load_profile())
	get_tree().change_scene_to_file("res://app/run.tscn")


## The [N] restage seam (pure staging, no scene change — testable headless): mirror
## menu._on_new_run's staging from `profile` onto the static MenuHandoff holder.
func restage_handoff_from_profile(profile) -> void:
	var H = Menu.MenuHandoff
	H.reset()
	if profile == null:
		return
	H.unlocked_car_ids = Unlocks.unlocked_car_ids(profile)
	H.unlocked_class_ids = Unlocks.unlocked_class_ids(profile)
	H.settings = profile.settings.duplicate(true)
	H.run_seed = Menu.pick_run_seed(not headless)


## Flip AUTO (sim_mode): AUTO lets the deterministic auto-pilot finish the fight / run; MANUAL hands
## control back to the operator. The default for a from-seed/headless driver is never touched.
func _toggle_auto() -> void:
	sim_mode = not sim_mode
	if sim_mode:
		# W6-2: engaging AUTO defaults to THIS-FIGHT-ONLY scope. It auto-pilots the current combat and
		# then reverts to MANUAL at car clear, so flipping AUTO for one fight never silently auto-commits
		# the permanent level-up picks / scrip spends / Order-changing choices on every following car.
		# The operator widens it to the whole run explicitly (_set_auto_whole_run / a "VET" of the toggle).
		_auto_scope = "fight"
		_awaiting_player = false   # release any blocked interactive phase to the auto-pilot
	if hud != null:
		hud.set_auto_label(sim_mode)
		hud.set_hint("AUTO (this fight) — auto-pilot finishing; MANUAL restored at car clear" if sim_mode else "MANUAL — your move")


## W6-2: widen an engaged (or freshly engaged) AUTO to the WHOLE run — the explicit operator opt-in.
## Whole-run AUTO finishes the run including the deterministic-default level-up / econ / moral picks
## (the same as a --sim proof). FLAG (render lane): an ops_hud toggle should surface fight-vs-run scope
## and call this for the whole-run choice; the lead owns render/ops_hud.gd.
func _set_auto_whole_run() -> void:
	if not sim_mode:
		sim_mode = true
	_auto_scope = "run"
	_awaiting_player = false
	if hud != null:
		hud.set_auto_label(true)
		hud.set_hint("AUTO (whole run) — auto-pilot finishing the run")


## W6-2: a FIGHT-scoped AUTO reverts to MANUAL once the current car clears, so the post-combat level-up
## picks and the next econ/moral car are hand-driven — never a silent auto-commit. Whole-run AUTO is
## left engaged. Returns true if it reverted (the on-screen loop then resolves the following steps
## interactively). No-op headless (the byte-stable drivers never engage a scope).
func _auto_revert_after_car() -> bool:
	if sim_mode and _auto_scope == "fight":
		sim_mode = false
		if hud != null:
			hud.set_auto_label(false)
			hud.set_hint("AUTO (this fight) complete — MANUAL restored, your move")
		_onscreen_log("AUTO (this fight) complete — control returned to MANUAL")
		return true
	return false


## W6-2: an AUTO stall/wipe hands control back to MANUAL with a one-line notice instead of silently
## ending the run under the operator. Flips to MANUAL + notifies if AUTO was engaged; returns true if
## it did. (The run outcome is still resolved by the caller — this is the honest hand-back, so the
## operator is told AUTO could not finish rather than finding a dead run with no explanation.)
func _auto_handback_on_stall() -> bool:
	if not sim_mode:
		return false
	sim_mode = false
	_auto_scope = "run"
	if hud != null:
		hud.set_auto_label(false)
		hud.set_hint("AUTO stalled — control returned to MANUAL")
	_onscreen_log("AUTO could not finish the fight — control handed back to MANUAL")
	return true


## Cycle the animation speed (1x -> 2x -> 4x -> 1x) for fast-forwarding a long run.
func _cycle_speed() -> void:
	if _onscreen_speed >= 4.0:
		_onscreen_speed = 1.0
	else:
		_onscreen_speed *= 2.0
	if player != null:
		player.speed_scale = _onscreen_speed
	if hud != null:
		hud.set_speed_label(int(_onscreen_speed))   # #24 — the SPEED button now carries the multiplier
		hud.set_hint("SPEED x%d" % int(_onscreen_speed))


## Per-frame on-screen tick: advance the view's visual decays (flash/highlight pulse).
func _process(delta: float) -> void:
	if headless:
		return
	if _run_over:
		return   # run resolved — stop redriving the dead board's visual decay
	if view != null:
		view.tick_visuals(delta)


## Read launch flags: `--sim` (or `coldspine_sim=true` in args) forces an unattended AUTO run at a
## fast speed so a windowed binary plays itself to an ending (the animation proof). Without it the
## on-screen build is interactive (manual play with an AUTO toggle).
func _apply_launch_flags() -> void:
	# A normal WINDOWED launch is INTERACTIVE: the operator drafts the cell and plays each turn
	# by hand. `sim_mode` defaults TRUE only so the HEADLESS drivers auto-pilot (this function is
	# never called headless — it's gated behind `not headless` in _ready), so we flip it FALSE here
	# for the on-screen build. `--sim` re-forces the unattended auto-run below.
	sim_mode = false
	var args := OS.get_cmdline_args()
	var user_args := OS.get_cmdline_user_args()
	var force_sim := false
	for a in args + user_args:
		var s := String(a)
		if s == "--sim" or s == "sim" or s.to_lower().contains("coldspine_sim"):
			force_sim = true
	if force_sim:
		sim_mode = true
		_onscreen_speed = 4.0
		if player != null:
			player.speed_scale = _onscreen_speed
		_log_hud("> SIM MODE — unattended auto-run @ x4")


## ANIMATED event playback (on-screen await). Routes the stream through EventPlayer.play_animated
## with the current speed, then re-syncs the token table to the authoritative state. Headless or
## player-less => a plain synchronous _play (so this is safe if ever reached without a display).
func _play_anim(events: Array) -> void:
	if headless or player == null:
		_play(events)
		return
	player.speed_scale = _onscreen_speed
	await player.play_animated(events)
	_sync_view()
	_juice_for_events(events)   # #23 — glitch-tear/chroma-split on OBJECT_BREAK / SHOCK in the stream
	_flash_overwatch_reactors(events)   # #21 — a feed flash on a unit that just reacted on overwatch


## #23 — scan a committed/animated event stream and fire a one-time glitch-tear/chroma-split on the
## big physical events (OBJECT_BREAK, SHOCK). Cheap, render-only (only pokes the CarView's cosmetic
## glitch timer). On-screen-only — headless has no view, and never reaches the animated path anyway.
func _juice_for_events(events: Array) -> void:
	if view == null:
		return
	for e in events:
		if e.type == E.Ev.OBJECT_BREAK or e.type == E.Ev.SHOCK:
			view.glitch(1.0)
			return   # one tear per stream is plenty (and stays cheap)


## #18 — push the team-turn roster strip + phase banner to the HUD. Builds one chip per LIVING player
## unit in the current combat state (can-act / spent / downed), in stable id order, and surfaces the
## current ROUND n + the phase name (PLAYER / ENEMY / ENVIRONMENT). PURE read of state/turn — no mutation.
## On-screen-only (no hud/turn/state headless). `phase_name` is the banner text the caller passes.
func _refresh_team_turn(phase_name: String) -> void:
	if hud == null or state == null or turn == null:
		return
	var chips: Array = _team_turn_chips()
	hud.set_team_turn(chips, turn.round_num, phase_name)


## The PURE per-unit roster draw-data (#18): one entry per LIVING player unit in the combat state, in
## stable id order — { name, state:"act"|"spent"|"downed" }. can-act = still has AP this phase; downed =
## on the floor (alive==false but not dead); spent = standing but out of AP. No mutation — a pure read.
func _team_turn_chips() -> Array:
	var out: Array = []
	if state == null:
		return out
	for id in state.entity_ids_sorted():
		var e = state.entities.get(id)
		if e == null or not e.is_unit or e.faction != E.Faction.PLAYER:
			continue
		if e.dead:
			continue   # the permanently dead leave the strip (permadeath)
		var st := "spent"
		if e.downed:
			st = "downed"
		elif turn != null and turn.can_act(id):
			st = "act"
		out.append({"name": String(e.name), "state": st})
	return out


## #21 — a unit that just REACTED on overwatch (OVERWATCH_TRIGGER) gets a brief feed flash so the
## operator sees who fired. Render-only (CarView.flash_token is a cosmetic white wash). On-screen-only.
func _flash_overwatch_reactors(events: Array) -> void:
	if view == null:
		return
	for e in events:
		if e.type == E.Ev.OVERWATCH_TRIGGER:
			var wid: int = int(e.data.get("watcher", -1))
			if wid >= 0:
				view.flash_token(wid, 0.8)


## Wall-clock-stamped stdout progression marker for the WINDOWED proof (on-screen only — headless
## drivers never reach the _onscreen flow, so the byte-stable test suites never see these). The
## timestamps spreading across the log are the evidence the run ANIMATES over time rather than
## snapping to the end in a single frame.
func _onscreen_log(line: String) -> void:
	if headless:
		return
	print("[ONSCREEN +%.2fs] %s" % [Time.get_ticks_msec() / 1000.0, line])


## A timed on-screen beat (await); instant if headless / no tree.
func _beat(t: float) -> void:
	if headless:
		return
	var tree := get_tree()
	if tree == null:
		return
	await tree.create_timer(t / max(1.0, _onscreen_speed)).timeout


# ============================ combat cars =====================================
## Build a combat/flood/captain car's live SimState (honoring the E1 hazard/flammable/
## cycling/concealment/friction/slope/belt fields via SetpieceLoader), place the DRAFTED
## squad, enable bleed-out, and play it to a win/loss — interactively on-screen, auto-resolved
## headless. On a win, write combat results back to the persistent squad.
func _resolve_combat_car(car) -> int:
	state = _build_car_state(car)
	if state == null:
		# Could not build (missing template) — concede the car as cleared so the run proceeds.
		trace.append("CAR %d [%s/%s]: SKIPPED (no template)" % [run.position, _type_name(car.car_type), car.template_id])
		return 1
	state.bleedout_enabled = true            # task #11: bleed-out ON in the run loop (§7.4)
	turn = TurnManager.new(state)
	turn.start()
	_apply_betrayal_beat(car)                 # C3.5: a planted Conductor's Kin defects at a CAPTAIN car
	ai = EnemyAI.new()
	_active_combat = true
	_bind_combat_view()
	bind_combat_intent()                     # the InputIntent a human (or a scripted test) drives
	_log_hud("> ENTER %s — combat." % car.name)

	var outcome: int = _auto_resolve_combat()   # 1 = win, 2 = loss, 0 = stalled
	_active_combat = false
	# Write the surviving squad's combat bodies back into the persistent UnitInstances.
	_absorb_squad(state)
	if outcome == 1:
		AbilitySystem.grant_car_clear_momentum(db, run.squad)   # Firebrand momentum: +1 per car cleared
	var label := "WON" if outcome == 1 else ("LOST" if outcome == 2 else "STALLED")
	# ONLY a genuine WIN clears the car (and earns the regroup breather). A STALL — the cell
	# couldn't finish the enemies inside the round guard — is NOT a clearance: it's reported as a
	# failure to advance (a loss for the run), never silently treated as "cleared". This closes
	# the loophole where a passive cell could ride stalled fights to the Engine without winning.
	if outcome == 1 and car.car_type != E.CarType.CAPTAIN:
		var restored := 0
		if E.POST_COMBAT_REGROUP_PCT > 0:
			restored += _regroup_heal_pct(E.POST_COMBAT_REGROUP_PCT)   # G2: heal 50% of max (attrition compounds)
		# unconditional: a stabilized-downed comrade always gets back up (at the current revive HP;
		# → E.REGROUP_STANDUP_HP at the W6-1 flip). Runs AFTER the heal so it isn't re-clamped.
		restored += _stand_up_downed(E.REGROUP_STANDUP_HP)   # G2: downed stand at a fixed low HP, not full
		if restored > 0:
			label += " +regroup%d" % restored
	trace.append("CAR %d [%s/%s]: %s (round %d)" % [run.position, _type_name(car.car_type), car.template_id, label, turn.round_num])
	if outcome == 1:
		run.resolve_current()                # clears the fight gate so advance() can proceed
	return outcome


## The deterministic between-fights recovery. DESIGN-PANEL DECISION (2026-07-04): the two effects
## are DECOUPLED so any future heal value — including 0 — is safe:
##   - _stand_up_downed(): a STABILIZED-DOWNED member (downed but NOT dead — it survived the
##     bleed-out window) is ALWAYS helped back to its feet at REGROUP_STANDUP_HP and rejoins the
##     next fight, INDEPENDENT of the heal number (so a low/zero heal can never strand it).
##     Permadeath is untouched: a DEAD member stays dead (never revives the permanently lost, §7.4).
##   - _regroup_heal(amount): living members (incl. a just-stood-up one) field-patch `amount` HP,
##     clamped to max_hp (no banked over-heal). At the current full heal every survivor tops to max;
##     at the G2 50%-of-max flip, attrition begins to compound forward.
## Both integer-only, deterministic, stable squad order. Each returns the HP it restored. Call
## _regroup_heal FIRST (living only) then _stand_up_downed — disjoint sets, so a revived comrade is
## not re-clamped by the heal.
##
## STAGING (design panel G2): TODAY the heal is FULL (byte-neutral) — the value flip to 50% is NOT
## landed here. It is READY (see the W6-1 wave report): change the two call sites to
## `_regroup_heal(ceil(max_hp*E.POST_COMBAT_REGROUP_PCT/100))` (per-unit, integer) +
## `_stand_up_downed(E.REGROUP_STANDUP_HP)`, then RE-SWEEP many seeds + RE-PIN balance_smoke (the
## BalanceGate's job — not this lane). The pilot is now ARMED (W6-1 depth tools) to use ability/item
## depth WHEN a squad drafts/carries it; the flip is measured safe on the current suites (all green,
## byte-identical) but the pinned 0x71B line wins at 50% WITHOUT exercising the tools, so the pillar
## drop needs the gate's multi-seed sweep to bless — that pairing is why the flip is flagged, not landed.
func _stand_up_downed(revive_hp: int) -> int:
	var total := 0
	for u in run.squad:
		if u == null or u.dead or not u.downed:
			continue
		u.downed = false   # a stabilized-Downed comrade ALWAYS gets back up (permadeath untouched)
		var target: int = max(u.hp, revive_hp)
		total += (target - u.hp)
		u.hp = target
	return total


func _regroup_heal(amount: int) -> int:
	var total := 0
	for u in run.squad:
		if u == null or u.dead or u.downed:
			continue
		var before: int = u.hp
		u.hp = min(u.max_hp, u.hp + amount)
		total += (u.hp - before)
	return total


## W6-6: start/switch a music track through the AudioDirector autoload (Music bus). play_music was
## dead-on-arrival (zero call sites); the run layer now scores section combat / the vault / the ending.
## No-op headless (the byte-stable suites never build a display / are not in the tree) — drop-in .ogg.
func _play_music(track: String) -> void:
	if headless or not is_inside_tree():
		return
	var ad := get_node_or_null("/root/AudioDirector")
	if ad != null:
		ad.play_music(track)


## G2 FLIP (2026-07-05, W6-1 armed the pilot): the between-car heal is now `pct`% of each unit's MAX
## HP (not a flat top-to-full), so attrition COMPOUNDS forward — the scarcity/forward-only pillar. app
## layer (not res://core), so the float ceil is fine. A lightly-hurt unit still tops out; a badly-hurt
## one carries a deficit into the next car, forcing the scarce REST/Supplies/item economy to matter.
func _regroup_heal_pct(pct: int) -> int:
	var total := 0
	for u in run.squad:
		if u == null or u.dead or u.downed:
			continue
		var amt: int = int(ceil(float(u.max_hp) * float(pct) / 100.0))
		var before: int = u.hp
		u.hp = min(u.max_hp, u.hp + amt)
		total += (u.hp - before)
	return total


## The betrayer beat (Conductor's Kin — Sub-Spec C3.5). A CAPTAIN car is the section climax: the
## scripted STORY BEAT at which a planted, still-unrevealed Conductor's Kin DEFECTS. The trigger is
## car-type gated and RNG-FREE, so a fixed (seed, deployment) reproduces the same defection at the
## same car — determinism intact. Betrayer.check_beat flips every DEPLOYED unrevealed Kin to the
## ENEMY faction (it now fights the cell), emits a BETRAYAL event (the renderer animates it; the
## operator learns of the plant) and raises the combat state's Order. Here we ALSO thread the loud
## breach onto the RUN's Order meter (§9 — the persistent gauge the recon HUD reads) and DROP each
## defector from the roster: its body stays in the fight AS the enemy, but the UnitInstance is gone,
## so _absorb_squad never writes the traitor back as a squad member and it can never re-trigger at a
## later captain. A REVEALED Kin (a Saboteur scan / vetting exposed it first) does NOT turn — vetting
## is the counterplay (Betrayer.should_fire gates on betrayer_revealed). Density is the owner-flagged
## BETRAYER_DENSITY_PCT in Recruitment — untouched here; this file owns only the trigger + wiring.
## Returns the emitted events (empty when nothing fired) so the on-screen path can animate them.
func _apply_betrayal_beat(car) -> Array:
	if car == null or state == null or run == null or car.car_type != E.CarType.CAPTAIN:
		return []
	# W7-13: RESUME restore — re-inject any defector this run PERSISTED at THIS captain whose body isn't
	# already on the freshly-built board (a save was taken after it defected; the combat state wasn't
	# serialized, and its UnitInstance was dropped from the roster so _place_squad never re-spawned it).
	# On the FIRST play the body IS present and nothing is recorded yet, so this is a silent no-op — the
	# once-per-plant beat + byte-stable determinism are untouched (it emits no BETRAYAL event).
	_restore_recorded_defectors(car)
	var events: Array = Betrayer.check_beat(state, true)
	if events.is_empty():
		return events
	for ev in events:
		if ev.type == E.Ev.BETRAYAL:
			run.apply_order("loud_breach")                    # §9: defection is a loud breach (persistent)
			var body_id := int(ev.data.get("id", -1))
			_record_defector(car, body_id)                    # W7-13: persist BEFORE the roster drop (snapshot intact)
			_desquad_defector(body_id)
			trace.append("BETRAYAL: %s (Conductor's Kin) defected at CAPTAIN car %d" % [str(ev.data.get("name", "?")), run.position])
	return events


## W7-13: persist a just-defected Kin so a save/resume across this captain fight can restore it. Records
## the UnitInstance snapshot (RunState's serializer), the captain template id (so resume re-injects it at
## the SAME car), and the body's tile. Called BEFORE _desquad_defector, while the roster still holds it.
func _record_defector(car, body_id: int) -> void:
	if run == null or state == null or car == null:
		return
	var e = state.entities.get(body_id)
	if e == null:
		return
	var inst_id: int = int(e.instance_id)
	for u in run.squad:
		if u != null and int(u.id) == inst_id:
			run.defectors.append({
				"template_id": String(car.template_id),
				"x": int(e.pos.x), "y": int(e.pos.y),
				"unit": RunState._unit_to_dict(u),
			})
			return


## W7-13: on RESUME of a captain car, spawn any persisted defector for THIS car (whose body is not
## already present) as the ENEMY it became. SILENT — no BETRAYAL event, so the once-per-plant contract
## and byte-stable first-play beat are unchanged. Deterministic, RNG-free. No-op on the first play (the
## defector's body is still on the board there; the record is written only after the beat fires).
func _restore_recorded_defectors(car) -> void:
	if run == null or state == null or car == null or db == null:
		return
	for d in run.defectors:
		if String(d.get("template_id", "")) != String(car.template_id):
			continue
		var ud: Dictionary = d.get("unit", {})
		var inst_id: int = int(ud.get("id", -1))
		if _find_body_for(state, inst_id) != null:
			continue   # already on the board (first play, or already restored) — never double-spawn
		var u = RunState._unit_from_dict(ud)
		u.faction = E.Faction.ENEMY                # it defected — spawn hostile to the cell
		var pos := _free_tile_near(Vector2i(int(d.get("x", 1)), int(d.get("y", 1))))
		var body = u.to_sim_entity(db, pos)
		body.faction = E.Faction.ENEMY
		body.betrayed = true                       # already turned — should_fire() won't re-trigger it
		body.betrayer_revealed = true
		state.add_entity(body)
		trace.append("RESUME: restored defector %s (Conductor's Kin) as enemy at CAPTAIN car %s" % [str(u.name), String(car.template_id)])


## Nearest free (in-bounds, unoccupied) tile to `want`, spiralling out; falls back to `want` itself.
func _free_tile_near(want: Vector2i) -> Vector2i:
	if state == null:
		return want
	if _tile_free(want):
		return want
	for r in range(1, 8):
		for dy in range(-r, r + 1):
			for dx in range(-r, r + 1):
				var p := want + Vector2i(dx, dy)
				if _tile_free(p):
					return p
	return want


func _tile_free(p: Vector2i) -> bool:
	return state != null and state.in_bounds(p) and state.occupant_at(p) == null


## Drop a defected Conductor's Kin (C3.5) from the persistent roster by combat-body id. The body
## stays in the SimState fighting AS the enemy; removing its UnitInstance means _absorb_squad never
## writes the traitor's fate back as a squad member and it can never re-trigger a later captain beat.
func _desquad_defector(body_id: int) -> void:
	if state == null:
		return
	var e = state.entities.get(body_id)
	if e == null:
		return
	var inst_id: int = int(e.instance_id)
	for idx in range(run.squad.size()):
		var u = run.squad[idx]
		if u != null and int(u.id) == inst_id:
			run.squad.remove_at(idx)
			return


## Player-facing BETRAYER COUNTERPLAY (W6-11 / Sub-Spec C3.5). The reveal path (Betrayer.reveal) was
## core-wired + tested but had NO operator surface — a player could not pre-emptively expose a suspected
## Conductor's Kin before a captain car, so the only "counterplay" was to eat the defection. This is
## that surface: a ONE-PER-RUN vetting SCAN over the PERSISTENT roster (run.squad UnitInstances, so the
## reveal rides into every future combat body via to_sim_entity's betrayer_revealed copy). It exposes
## the FIRST still-hidden plant in stable roster order (a scan reads the loyalty risk; benching/handling
## it is then the operator's call), else reports CLEAN. A revealed Kin no longer fires its beat
## (_apply_betrayal_beat → Betrayer.check_beat → should_fire gates on betrayer_revealed), so the
## defection is defused. The scan is spent whether or not a plant is found (vetting a clean squad still
## costs the one scan — the resource is the cost). Deterministic, rng-free. Returns
## {ok, used, revealed_name, clean, reason}.
##
## FLAG (cross-lane, RENDER): the OPERATOR TRIGGER needs an ops_hud/screen button — a "VET / SCAN"
## control (recruit-time, or an in-run pre-captain action) wired to call scan_for_betrayer(). The lead
## owns render/ops_hud.gd; graft a button/affordance there that invokes this method (_on_hud_action
## already routes a "VET"/"SCAN" action name to it). Cost model here is a one-per-run scan; if the
## design prefers a Tools spend, wrap the run.deep_scan/Tools rail around this call (owner-gated).
func scan_for_betrayer() -> Dictionary:
	if run == null:
		return {"ok": false, "used": _betrayer_scan_used, "revealed_name": "", "clean": false, "reason": "no run"}
	if _betrayer_scan_used:
		return {"ok": false, "used": true, "revealed_name": "", "clean": false, "reason": "scan already spent this run"}
	_betrayer_scan_used = true
	var events: Array = []
	for u in run.squad:
		if u == null:
			continue
		# Betrayer.reveal flips a hidden, still-unrevealed Kin to revealed and returns true (the real
		# counterplay path). Reveal the FIRST such plant; the operator then decides what to do with it.
		if Betrayer.reveal(u, events):
			trace.append("SCAN: vetting exposed %s as a Conductor's Kin (defection defused)" % str(u.name))
			_log_hud("! VET SCAN — %s reads as a Conductor's Kin. Defection defused." % str(u.name))
			return {"ok": true, "used": true, "revealed_name": str(u.name), "clean": false, "reason": ""}
	trace.append("SCAN: vetting scan ran — squad reads CLEAN")
	_log_hud("> VET SCAN — squad reads clean (no plant exposed).")
	return {"ok": true, "used": true, "revealed_name": "", "clean": true, "reason": ""}


## Auto-resolve a combat car headlessly (and as the on-screen default): step the team-turn
## loop — the player units act via the enemy-targeting auto-pilot (_auto_player_phase, a
## deterministic stand-in for scripted operator input that drives the real command path),
## enemies act via EnemyAI, the environment ticks (hazards + bleed-out) — until one side is
## gone or the guard trips. Returns the victory code (1 win / 2 loss / 0 stalled).
func _auto_resolve_combat() -> int:
	var rounds: int = 0
	while rounds < COMBAT_GUARD_ROUNDS:
		rounds += 1
		var v: int = turn.check_victory()
		if v != 0:
			return v
		# A fight where the WHOLE cell is on the floor (every player unit downed/dead, none
		# standing) while enemies remain is lost — the downed can't fight their way out, and a
		# stabilized-Downed unit no longer bleeds, so check_victory() would otherwise spin here
		# forever (an enemy that won't path over to finish the body = an infinite stalemate).
		# Treat zero-standing-players-with-enemies as a LOSS so the run resolves instead of stalling.
		if _no_standing_players() and not _enemies_cleared():
			return 2
		# PLAYER phase — drive our units with the deterministic AI policy (auto-pilot).
		var p_ev: Array = _auto_player_phase()
		_play(p_ev)
		v = turn.check_victory()
		if v != 0:
			return v
		# PLAYER -> ENEMY
		_play(turn.advance_phase())
		# ENEMY phase
		_play(ai.take_phase(turn))
		# ENEMY -> ENVIRONMENT (ticks hazards + bleed-out) and ENVIRONMENT -> PLAYER
		_play(turn.advance_phase())
		_play(turn.advance_phase())
		_sync_view()
	return turn.check_victory()


## True if NO player unit is standing (alive) in the current combat state — every player body is
## Downed or gone. (A Downed unit is alive==false; this is distinct from check_victory's "not dead".)
func _no_standing_players() -> bool:
	for id in state.entity_ids_sorted():
		var e = state.entities.get(id)
		if e == null or not e.is_unit or e.faction != E.Faction.PLAYER:
			continue
		if e.alive:
			return false
	return true


## True if no enemy unit remains a live threat in the current combat state.
func _enemies_cleared() -> bool:
	for id in state.entity_ids_sorted():
		var e = state.entities.get(id)
		if e == null or not e.is_unit or e.faction != E.Faction.ENEMY:
			continue
		if e.alive and not e.downed:
			return false
	return true


# --- auto-pilot tuning (deterministic; integer scoring, stable order) -------------
# Standing / cycling hazard emitters + gas the pilot's BFS pathing must NOT route through
# (mirrored into EnemyAI._passable). Plain L_WATER is intentionally NOT here (soak-walkable).
const PILOT_HAZARD_BLOCK := [E.Hazard.SCALD, E.Hazard.FURNACE, E.Hazard.RAIL_LIVE,
	E.Hazard.VENT, E.Hazard.LASER, E.Hazard.LASER_SWEEP, E.Hazard.PLATE, E.Hazard.PISTON]
# on_break kinds worth shoving an enemy INTO / triggering a volatile object for (§12 free lethality).
const DANGEROUS_ON_BREAK := [E.OnBreak.EXPLODE, E.OnBreak.FLOOD, E.OnBreak.SPILL_FIRE, E.OnBreak.TOPPLE]
# Stable orthogonal order (N, E, S, W) — matches the resolver's DIRS4; never reorder.
const PILOT_DIRS4 := [Vector2i(0, -1), Vector2i(1, 0), Vector2i(0, 1), Vector2i(-1, 0)]
# A preview object play must harm enemies at least this much (a guaranteed shot's base damage)
# to be worth spending the AP + the one-shot volatile object on it (scores plays vs direct fire).
const OBJECT_PLAY_MIN_SCORE := E.SHOOT_DAMAGE_BASE
# A previewed enemy DOWN/kill is worth this in the object-play score (dominates raw damage).
const DOWN_SCORE := 1000
# SOAK-GATE PLAYBOOK (§12 tail_warden / chief / conductor): the farthest a designated "wrangler"
# unit will be from a MOVABLE flood source before it diverts to shepherd it toward a soak-gated
# captain (Manhattan). Bounds the multi-turn tank-push so a unit never treks the whole car to a
# far tank (which would abandon the fight) — only the unit already near the tool works it.
const SOAK_WRANGLE_RANGE := 6
# STAGE 1 — ORDINARY-COMBAT COMPETENCE (focus-fire threat targeting + damage-avoidant positioning).
# At/below this HP a unit with no kill or shot available BREAKS to cover instead of trading in the
# open — a fragile body standing in enemy line-of-fire is the fastest way to lose the fight's action
# economy. ~1/3 of a Bruiser's 12 max: the "take cover, live to shoot next round" line.
const PILOT_RETREAT_HP := 4
# W6-1 DEPTH-TOOL tuning (deterministic, integer). Offensive-cast candidate kinds: the effect kinds the
# offensive-cast scorer reads as enemy harm / control (a cluster gas/flood/blast chain, a rupture, a
# grapple). Physics verbs the pilot ALREADY drives raw (impulse/throw/melee/shove) + electrify (owned by
# the flood->electrify combo, 1d) are deliberately NOT here — this bundle is the tools it LACKED.
const PILOT_OFFENSIVE_KINDS := {
	"spawn_hazard": true, "ignite_gas": true, "rupture_tank": true,
	"detonate_all_charges": true, "pull": true,
}
# A previewed NEW enemy debuff (poison/burn/prone/stun/soak/shock/blind/chill/frozen/suppress/net) is
# valued here — below a down, above nothing — so a CLUSTER setup (gas 2+ bodies) clears a shot's worth
# (OBJECT_PLAY_MIN_SCORE) while a single-target debuff does not out-price a plain shot.
const PILOT_CAST_DEBUFF_VALUE := 3
const PILOT_ENEMY_DEBUFF_BITS := E.S_PRONE | E.S_STUNNED | E.S_SOAKED | E.S_BURNING | E.S_SHOCKED \
	| E.S_POISONED | E.S_BLINDED | E.S_CHILLED | E.S_FROZEN | E.S_SUPPRESSED | E.S_NETTED
# A friendly at/below this fraction of max HP AND missing >= PILOT_HEAL_MIN is "hurt" enough that the
# pilot spends a heal item/ability on it (else it only ever shoots and never patches a wounded body).
const PILOT_HEAL_PCT := 60
const PILOT_HEAL_MIN := 3


## Drive the PLAYER units with a self-contained ENEMY-targeting auto-pilot (a deterministic
## stand-in for scripted operator input). It runs the EXACT command/turn path the interactive
## UI uses — `turn.try_command(MoveCommand/ShootCommand/ShoveCommand)` — so the headless smoke
## run exercises the real combat pipeline. Per phase: first triage (stabilize downed allies),
## then per unit while it has AP — advantageous shove of an adjacent enemy (physics-first, §12),
## else shoot a target in range + LoS (ranged units hold after firing), else BFS-step toward a
## firing position (flanking LoS-blocking cover). See _player_act_once for the per-step policy.
func _auto_player_phase() -> Array:
	var events: Array = []
	# 0. Triage: any standing player unit adjacent to a Downed (Bleeding) ally stabilizes it
	#    (the §7.4 ally-aid that buys the revive window). This stops the permadeath cascade that
	#    otherwise wipes a fragile cell the moment one member drops.
	_stabilize_downed_allies(events)
	for id in state.entity_ids_sorted():
		var e = state.entities.get(id)
		if e == null or not e.is_unit or not e.alive or e.faction != E.Faction.PLAYER:
			continue
		var g: int = 0
		var shot_this_phase: bool = false
		var steady_followups: int = 0
		while turn.can_act(id) and g < 8:
			g += 1
			var act := _player_act_once(id, events)
			if act == "shoot":
				shot_this_phase = true
				# Holding discipline: after firing, a ranged unit holds its remaining AP rather
				# than over-extending into the open (the death-by-aggression failure mode). It
				# stays where its shot came from — typically in/near cover.
				if _is_ranged(id):
					# W6-12 STEADY: the Marksman "Steady" passive (no_end_turn_first_shot) leaves the
					# unit's turn OPEN after its first shot from a fresh phase (ShootCommand sets
					# ends_turn=false at full AP) — the granted FOLLOW-UP. The pilot used to force-end
					# every ranged turn after one shot, discarding it. If a Steady body is still standing
					# (can_act) after firing, its shot did not end the turn: loop once more to take the
					# second action. The follow-up shot fires at < full AP, so Steady no longer applies
					# and it ends the turn normally — bounded, and holding discipline still holds after.
					var me_s = state.entities.get(id)
					if me_s != null and me_s.steady_shot and steady_followups == 0 and turn.can_act(id):
						steady_followups += 1
						continue
					turn.end_unit(id)
					break
			elif act == "":
				turn.end_unit(id)
				break
			# A ranged unit that could not shoot advances only ONE step this phase (probe to
			# range, don't sprint across the car), then holds. Melee units may keep closing.
			if act == "move" and _is_ranged(id) and not shot_this_phase:
				turn.end_unit(id)
				break
	return events


## One auto-pilot action for player unit `id`. Returns the action label issued this step —
## "shove" / "shoot" / "move" / "stand" — or "" if the unit had nothing useful to do (the
## caller then yields its remaining AP). The label lets the phase loop apply holding discipline.
func _player_act_once(id: int, events: Array) -> String:
	var me = state.entities.get(id)
	if me == null or not me.alive:
		return ""
	# Prone? stand up first (1 AP, doesn't end the turn).
	if me.has_status(E.S_PRONE):
		var su := MoveCommand.new(id, [], true)
		var r0: Dictionary = turn.try_command(su)
		if r0.ok:
			_append(events, r0.events)
			return "stand"
	var target = _nearest_enemy(me)
	if target == null:
		return ""
	# STAGE 1 focus target: the squad's shared highest-VALUE reachable enemy (removable-this-turn
	# first, then deadliest by DPS, then most-hittable) — drives shot concentration + movement so the
	# board clears fastest. The nearest-enemy `target` above still drives the adjacent physics/melee
	# and captain-gate plays (their tuning is untouched); `objective` layers focus on top.
	var objective = _focus_target()
	# 1. Advantageous shove of a directly-adjacent enemy (physics-first, §12): into a gap/hazard/
	#    wall for free damage + control.
	var sdir := _advantage_shove_dir(me, target)
	if sdir != Vector2i.ZERO:
		var sc := ShoveCommand.new(id, target.id, sdir, E.SHOVE_FORCE)
		var rs: Dictionary = turn.try_command(sc)
		if rs.ok:
			_append(events, rs.events)
			return "shove"
	# 1c. VOLATILE OBJECT PLAY (§6): shove/slam/throw an adjacent volatile object (barrel/coolant
	#     tank/water main/gas main — anything with a dangerous on_break) when a DETERMINISTIC PURE
	#     PREVIEW (PhysicsResolver over a clone == commit, RNG-free) shows it downs or meaningfully
	#     damages an enemy. Scored against a direct shot: only fires when at least a guaranteed
	#     shot's worth of harm (or a down) lands, so the one-shot object is never wasted.
	var play = _best_object_play(id)
	if play != null and play.score >= OBJECT_PLAY_MIN_SCORE:
		var pcmd
		match play.kind:
			"slam":
				pcmd = SlamCommand.new(id, play.obj, play.dir, play.force)
			"throw":
				pcmd = ThrowCommand.new(id, play.obj, play.dir, play.force)
			_:
				pcmd = ShoveCommand.new(id, play.obj, play.dir, play.force)
		var rp: Dictionary = turn.try_command(pcmd)
		if rp.ok:
			_append(events, rp.events)
			return "object"
	# 1d. FLOOD → ELECTRIFY combo (§6 chain): if a living enemy is Soaked while standing in water
	#     and THIS unit has an ability whose kit includes an 'electrify' effect, fire it — one
	#     AbilityCommand shocks every soaked-in-water enemy at once (a burst no single shot matches).
	if _soaked_enemy_in_water() != null:
		var eab := _unit_electrify_ability(id)
		if not eab.is_empty():
			var ecmd = _electrify_command(id, eab)
			if ecmd != null:
				var re: Dictionary = turn.try_command(ecmd)
				if re.ok:
					_append(events, re.events)
					return "ability"
	# 1e. CAPTAIN-KEY RETARGET: when the nearest threat is a damage-gated captain (shielded until
	#     its key is met, or unshovable-until-soaked), shooting its immune body is wasted. Drive the
	#     gate TOOL instead — a FLOOD source to soak/disperse, or the cover object to strip — by
	#     shooting it (objects are shootable, RNG-free), else closing on it, else shoving it in.
	if _is_gated_captain(target):
		var tool = _gate_tool_for(target)
		if tool != null:
			# A DAMAGE-shielded captain (gas/cover, gate closed) can't be shot at all → always work the
			# tool, closing in if needed. A soak-shove captain is still SHOOTABLE, so only divert to it
			# when a PURE PREVIEW proves breaking the tool actually soaks the captain (its flood reaches);
			# otherwise straight fire on its 16-HP body is the better play (don't waste shots on a tank
			# whose splash falls short). Soak-case never treks — act only if the tool is workable now.
			# Three cases, priority order: (1) DAMAGE-shielded captain (gas/cover) — shooting its body
			# is wasted, so any unit works the tool (closing in if needed). (2) SOAK captain + a MOVABLE
			# flood source — the designated WRANGLER (unit already nearest the tool) runs the multi-turn
			# soak playbook: approach+break the instant the flood reaches the captain, else shepherd the
			# tool one impulse closer (soaking early Prone's the captain + denies its slam tempo).
			# (3) Otherwise any unit with an IMMEDIATE break-to-soak takes it — but nobody treks to a
			# far tank (that would drop the fight). Every branch is preview-verified + RNG-free.
			var damage_gated: bool = not target.captain_gate_open
			if damage_gated:
				var gkey := _work_gate_tool(id, tool, false, events)
				if gkey != "":
					return gkey
			elif tool.movable and id == _soak_wrangler_id(tool):
				var pkey := _soak_playbook(id, tool, target, events)
				if pkey != "":
					return pkey
			elif _break_would_soak(tool, target):
				var gkey2 := _work_gate_tool(id, tool, true, events)
				if gkey2 != "":
					return gkey2
	# 1f. SHOOT A VOLATILE OBJECT (§6): a barrel/tank sitting in an enemy cluster and in line-of-fire
	#     is a rng-free multi-target strike — one shot pops it and its blast/flood/fire chains onto the
	#     pack. A PURE preview of the break scores it; fire only when it out-harms a single plain shot.
	#     This ends the turn like a normal shot, so it simply replaces a weaker one when it's better.
	var shot_obj = _best_shoot_object_play(id)
	if shot_obj != null and shot_obj.score >= OBJECT_PLAY_MIN_SCORE:
		var soc := ShootCommand.new(id, shot_obj.obj)
		var rso: Dictionary = turn.try_command(soc)
		if rso.ok:
			_append(events, rso.events)
			return "shoot"
	# 1h. DEPTH TOOLS (W6-1) -- the pilot's ABILITY + CONSUMABLE-ITEM plays, each evaluated on a PURE
	#     CLONE through the SAME AbilitySystem executor the real command runs (preview==commit, ally
	#     casualties vetoed) -- the honest-view rule the 50%-regroup pillar rides on. Priority:
	#       (a) a triage HEAL (medkit / Steward patch) on the most-wounded reachable ally or SELF --
	#           this IS the retreat-heal too: it fires above the 1g low-HP flee below, so a wounded body
	#           patches up and holds its firing tile instead of ceding ground. Gated on no guaranteed
	#           removal shot (never skip a kill to heal).
	#       (b) an OFFENSIVE cast/throw (Gas Tap, incendiary / breaching grenade, Coolant rupture, Pyro
	#           ignite, Grapple) whose previewed harm + new-debuff score clears a plain shot's worth --
	#           fired when it DOWNS an enemy, or when no guaranteed removal shot exists (so a kill is
	#           never traded for a setup; a cluster gas/flood chain IS worth the AP).
	#       (c) a timed area BUFF (Rally / Warcry) when the fight is joined and this unit has no shot.
	if not _has_killable_shot(me):
		var heal_play = _best_heal_play(id)
		if heal_play != null:
			var rhl: Dictionary = turn.try_command(heal_play.cmd)
			if rhl.ok:
				_append(events, rhl.events)
				return "heal"
	var cast_play = _best_offensive_cast(id)
	if cast_play != null and cast_play.score >= OBJECT_PLAY_MIN_SCORE \
			and (cast_play.downs > 0 or not _has_killable_shot(me)):
		var rct: Dictionary = turn.try_command(cast_play.cmd)
		if rct.ok:
			_append(events, rct.events)
			return "cast"
	var buff_play = _best_buff_cast(id)
	if buff_play != null:
		var rbf: Dictionary = turn.try_command(buff_play.cmd)
		if rbf.ok:
			_append(events, rbf.events)
			return "buff"
	# 1b. MELEE SLAM: a FRONTLINE unit (bruiser/firebrand) adjacent to an enemy with no clean shot
	#     to take instead drives a slam in — impact damage + a chance to knock the target Prone
	#     (Prone ≈ guaranteed hits for the rest of the cell, §5.4). This is the melee offense the
	#     pilot was missing: a sturdy body that closes should HIT, not just shove-or-idle. Mirrors
	#     EnemyAI melee_rush. We only slam when no better shot exists from here (checked below first).
	if not _is_ranged(id):
		var mdir: Vector2i = target.pos - me.pos
		if abs(mdir.x) + abs(mdir.y) == 1 and target.movable and not _can_shoot_anything(me):
			var slc := SlamCommand.new(id, target.id, mdir, E.SLAM_FORCE + me.slam_force_bonus)
			var rsl: Dictionary = turn.try_command(slc)
			if rsl.ok:
				_append(events, rsl.events)
				return "slam"
	# 1g. LOW-HP RETREAT (damage-avoidant, §), FLEE-OR-DIE only: a fragile unit (<= PILOT_RETREAT_HP)
	#     breaks to cover instead of trading in the open ONLY when staying is (in expectation) lethal —
	#     the estimated incoming fire on its tile this enemy phase meets/exceeds its HP — AND it has no
	#     one-shot KILL to take (a removal is worth the exposure) AND a strictly-safer reachable tile
	#     exists. The narrow gate matters: a low unit that flees whenever merely exposed just bleeds the
	#     squad's damage output (measured to LOSE more ordinary fights); this fires only to save a body
	#     that would otherwise be downed, keeping it alive to fight on. Evaluated before the shot.
	if me.hp <= PILOT_RETREAT_HP and _incoming_at(me, me.pos) >= me.hp and not _has_killable_shot(me):
		var rstep := _retreat_step(me)
		# Only actually break off if the retreat CONVERTS the outcome — the cover tile drops estimated
		# incoming BELOW this unit's HP (it survives the enemy phase). If no reachable tile can save it,
		# fleeing just forfeits a turn of fire for nothing, so it stays and fights. This keeps the retreat
		# from disrupting winnable lines (where cover is scarce near a gate) while still saving a body
		# whenever cover genuinely exists — the difference measured between 0 wins and a clean line.
		if rstep != me.pos and _incoming_at(me, rstep) < me.hp:
			var mcr := MoveCommand.new(id, [rstep])
			var rmr: Dictionary = turn.try_command(mcr)
			if rmr.ok:
				_append(events, rmr.events)
				return "move"
	# 2. FOCUS FIRE: of every enemy shootable from THIS tile, shoot the best one — a guaranteed removal
	#    first (an enemy this shot can kill), else concentrate on the squad FOCUS target (deadliest /
	#    most-finishable) so fire piles onto ONE body and it leaves the board fast. Dropping enemies
	#    quicker is the difference between surviving and getting whittled down. Shots already available
	#    from here, so this never over-extends a unit into the open (skilled, not a cheat).
	var shoot_t = _best_shootable_enemy(me)
	if shoot_t != null:
		# THREAT CONCENTRATION: _best_shootable_enemy already takes a guaranteed removal first (an
		# enemy this shot can kill). When the best shot from here is NOT a kill, redirect it onto the
		# squad focus target if this unit can also hit it — so chip damage piles onto the ONE body the
		# squad is trying to remove (the deadliest/most-finishable), instead of spreading across the
		# room. Never gives up a kill for a chip (the hp<=SHOOT_DAMAGE_BASE guard preserves that).
		if shoot_t.hp > E.SHOOT_DAMAGE_BASE and objective != null and objective.id != shoot_t.id \
				and ShootCommand.has_range(me.pos, objective.pos) and ShootCommand.in_los(state, me.pos, objective.pos):
			shoot_t = objective
		var shc := ShootCommand.new(id, shoot_t.id)
		var rsh: Dictionary = turn.try_command(shc)
		if rsh.ok:
			_append(events, rsh.events)
			return "shoot"
	# 3. No shot from here. OPENING DISCIPLINE: on the first round, the cell does NOT charge across
	#    the car into the enemy's opening alpha-strike (the failure mode that downs a unit on turn 1
	#    and loses the action economy for the whole fight). It HOLDS and arms OVERWATCH, so the
	#    approaching enemies eat reaction shots and the cell engages on its own terms. From round 2
	#    onward it closes to finish the fight (so nothing stalls). This single change is what lets
	#    the cell survive a captain gate's opening volley intact.
	if turn.round_num <= 1 and _has_closing_threat() and not me.overwatch:
		var oc := OverwatchCommand.new(id)
		var ro: Dictionary = turn.try_command(oc)
		if ro.ok:
			_append(events, ro.events)
			return "overwatch"
	# 4. Reposition toward the NEAREST enemy (closing on a distant focus would over-extend a lone unit),
	#    preferring the landing tile that ends in COVER / out of enemy line-of-fire (damage-avoidant) —
	#    the cell closes in to kill while eating the least return fire, rather than into the open.
	var step := _advance_step(me, target)
	if step != me.pos:
		var mc := MoveCommand.new(id, [step])
		var rm: Dictionary = turn.try_command(mc)
		if rm.ok:
			_append(events, rm.events)
			return "move"
	# 5. Boxed in with no shot and nowhere useful to step — arm OVERWATCH so a hostile entering the
	#    lane still eats a reaction shot (better than wasting the AP). Once per unit per turn.
	if not me.overwatch:
		var oc2 := OverwatchCommand.new(id)
		var ro2: Dictionary = turn.try_command(oc2)
		if ro2.ok:
			_append(events, ro2.events)
			return "overwatch"
	return ""


## §7.4 ally aid: stabilize every Downed (Bleeding) player unit that has a STANDING player ally
## orthogonally adjacent. Stabilizing stops the bleed-out clock so the unit survives Downed
## instead of permadying — the difference between a recoverable knock-down and a wipe cascade.
func _stabilize_downed_allies(events: Array) -> void:
	for id in state.entity_ids_sorted():
		var d = state.entities.get(id)
		if d == null or not d.is_unit or not d.downed or d.dead or d.faction != E.Faction.PLAYER:
			continue
		if not d.has_status(E.S_BLEEDING):
			continue
		# W6-4 AP PARITY: route the pilot triage-stabilize through the SAME AP-costed command a human
		# drives (InputIntent.STABILIZE_ABILITY — 1 AP, validate→apply→emit) instead of the old FREE
		# BleedoutSystem.stabilize bypass that made AUTO mechanically stronger than an operator at the
		# same view. A standing adjacent ally that can still act pays 1 AP to stabilize; if none can
		# afford it, the comrade waits (exactly as a human would be constrained). Stable DIRS4 order
		# picks which ally pays, deterministically. Runs at phase start (fresh AP) so a helper normally
		# can spare the point and still act — the cost is the honest parity, not a lost stabilize.
		for dir in PILOT_DIRS4:
			var ally = state.occupant_at(d.pos + dir)
			if ally == null or not ally.is_unit or not ally.alive or ally.faction != E.Faction.PLAYER:
				continue
			if not turn.can_act(ally.id) or turn.ap_for(ally.id) < 1:
				continue
			var cmd := AbilityCommand.new(ally.id, InputIntent.STABILIZE_ABILITY, d.id)
			var r: Dictionary = turn.try_command(cmd)
			if r.ok:
				_append(events, r.events)
				break


## True if `id` is a ranged role (holds distance, doesn't sprint into melee). Read off the
## persistent squad's archetype (marksman/saboteur) — robust to whatever drafted this body.
func _is_ranged(id: int) -> bool:
	var e = state.entities.get(id)
	if e == null:
		return false
	return e.archetype_id in ["marksman", "saboteur"]


## True if this unit has ANY clean shot from its current tile (used to prefer a shot over a slam).
func _can_shoot_anything(me) -> bool:
	return _best_shootable_enemy(me) != null


## True if any living enemy is a CLOSING threat — a melee/flanker/robot that will cross the car
## to reach the cell (so holding + overwatch pays off). A field of purely stationary ranged
## holders (turrets/snipers that kite) is NOT closing, so the cell advances to engage instead of
## waiting forever. Deterministic scan.
func _has_closing_threat() -> bool:
	for id in state.entity_ids_sorted():
		var e = state.entities.get(id)
		if e == null or not e.is_unit or not e.alive or e.faction != E.Faction.ENEMY:
			continue
		# A robot/flanker/melee profile advances; a captain with a melee profile does too.
		if e.ai_profile in [E.AIProfile.MELEE_RUSH, E.AIProfile.FLANKER, E.AIProfile.ROBOT]:
			# An anchored/static body (sentry turret) never closes even if "robot".
			if e.mass == E.Mass.ANCHORED or e.phys_trait == E.PhysTrait.STATIC_DESTRUCTIBLE:
				continue
			return true
	return false


## Priority key for which enemy to SHOOT, as a single comparable int (lower == shoot first).
## `me` is the shooter (so "nearest" is meaningful for the tie-break). The ordering, in order
## of dominance:
##   1. KILLABLE THIS SHOT first — an enemy at/below the guaranteed shot floor (SHOOT_DAMAGE_BASE)
##      is a free removal: take it off the board so it can't shoot back. (decisive tactical win)
##   2. Then GUARDS before SECTION CAPTAINS — a buff-captain's guards are the real threat and the
##      cheaper kills; a captain's damage gate may also be shut (wasted fire), so clear guards first.
##   3. Then LOWEST HP — concentrate fire on whatever is closest to dropping.
##   4. Then NEAREST to the shooter — default to the most immediate threat.
##   5. Then lowest id — stable, deterministic final tiebreak.
func _shoot_rank(me, e) -> int:
	var killable := 0 if e.hp <= E.SHOOT_DAMAGE_BASE else 1     # 0 = can finish now (best)
	var is_cap := 1 if e.captain_key != "" else 0
	var dist: int = abs(me.pos.x - e.pos.x) + abs(me.pos.y - e.pos.y)
	# Pack: killable (top) | captain (clear guards first) | hp | distance | id. Each field is
	# bounded well under its multiplier so the lexicographic order is exact.
	return killable * 100000000 + is_cap * 10000000 + max(0, e.hp) * 100000 + dist * 100 + e.id


## The best enemy this unit can shoot from its CURRENT tile (in range + LoS), by _shoot_rank:
## finish a kill if possible, else guards-before-captains, else lowest HP, else nearest. This is
## the focus-fire decision — it only ever picks among shots ALREADY available, so a unit never
## over-extends into the open to chase a target.
func _best_shootable_enemy(me):
	var best = null
	for eid in state.entity_ids_sorted():
		var e = state.entities.get(eid)
		if e == null or not e.is_unit or not e.alive or e.faction != E.Faction.ENEMY:
			continue
		if not (ShootCommand.has_range(me.pos, e.pos) and ShootCommand.in_los(state, me.pos, e.pos)):
			continue
		if best == null or _shoot_rank(me, e) < _shoot_rank(me, best):
			best = e
	return best


## True if `me` has ANY shot from its current tile that a hit would OUTRIGHT KILL — an enemy in
## range + LoS whose HP is at/below this unit's guaranteed minimum shot damage (base + flat bonus,
## before the variance band). A guaranteed removal is worth standing exposed for, so the low-HP
## retreat defers to it. Rng-free (reads authored damage only).
func _has_killable_shot(me) -> bool:
	var floor_dmg: int = E.SHOOT_DAMAGE_BASE + me.damage_bonus
	for eid in state.entity_ids_sorted():
		var e = state.entities.get(eid)
		if e == null or not e.is_unit or not e.alive or e.faction != E.Faction.ENEMY:
			continue
		if e.hp > floor_dmg:
			continue
		if ShootCommand.has_range(me.pos, e.pos) and ShootCommand.in_los(state, me.pos, e.pos):
			return true
	return false


## Nearest living ENEMY unit to `me` (ties -> lowest id, via sorted iteration + strict <).
func _nearest_enemy(me):
	var best = null
	var best_d: int = 1 << 30
	for id in state.entity_ids_sorted():
		var e = state.entities.get(id)
		if e == null or not e.is_unit or not e.alive or e.faction != E.Faction.ENEMY:
			continue
		var d: int = abs(me.pos.x - e.pos.x) + abs(me.pos.y - e.pos.y)
		if d < best_d:
			best_d = d
			best = e
	return best


# ===================== STAGE 1: focus-fire threat targeting =====================
# All integer, all pure of RNG: expected damage is estimated as accuracy% × fixed-damage in whole
# HP (never a draw). Ordering is deterministic (stable id iteration + a total comparator).

## Expected single-shot damage of unit `u` (rng-free estimate): fixed base + the MIDPOINT of the
## variance band + the unit's flat damage bonus. Used only for threat / lethality scoring.
func _expected_shot_damage(u) -> int:
	return E.SHOOT_DAMAGE_BASE + E.SHOOT_DAMAGE_VAR / 2 + u.damage_bonus


## Enemy threat as an integer: its authored to-hit accuracy × its expected shot damage. A sniper
## (accuracy 80) or a high-damage archetype scores far above a tier-1 guard, so the focus solver
## removes the deadliest body first ("threat prioritization"). Reads authored stats; draws nothing.
func _enemy_threat(e) -> int:
	var acc: int = e.accuracy if e.accuracy > 0 else E.BASE_ACCURACY
	return acc * _expected_shot_damage(e)


## Estimated damage the WHOLE squad can land on enemy `e` THIS turn from where its members already
## stand (rng-free): Σ over living player units with range+LoS on `e` of hit_chance% × expected
## damage, in whole HP. If it meets/exceeds e.hp the enemy is FINISHABLE now — a removal the solver
## hugely prefers (a dead enemy stops shooting back). Never draws the RNG.
func _est_squad_damage_on(e) -> int:
	var total: int = 0
	for pid in state.entity_ids_sorted():
		var u = state.entities.get(pid)
		if u == null or not u.is_unit or not u.alive or u.downed or u.faction != E.Faction.PLAYER:
			continue
		if not (ShootCommand.has_range(u.pos, e.pos) and ShootCommand.in_los(state, u.pos, e.pos)):
			continue
		total += (ShootCommand.hit_chance(state, u, e) * _expected_shot_damage(u)) / 100
	return total


## How many living player units can shoot `e` from where they currently stand (range + LoS).
func _hitters_on(e) -> int:
	var n: int = 0
	for pid in state.entity_ids_sorted():
		var u = state.entities.get(pid)
		if u == null or not u.is_unit or not u.alive or u.downed or u.faction != E.Faction.PLAYER:
			continue
		if ShootCommand.has_range(u.pos, e.pos) and ShootCommand.in_los(state, u.pos, e.pos):
			n += 1
	return n


## Manhattan distance from enemy `e` to the nearest living player unit (for the focus tie-break).
func _dist_to_nearest_unit(e) -> int:
	var best: int = 1 << 30
	for pid in state.entity_ids_sorted():
		var u = state.entities.get(pid)
		if u == null or not u.is_unit or not u.alive or u.faction != E.Faction.PLAYER:
			continue
		var d: int = abs(u.pos.x - e.pos.x) + abs(u.pos.y - e.pos.y)
		if d < best:
			best = d
	return best


## Is enemy `a` a STRICTLY better squad focus target than `b`? Priority, each field decided before
## the next (a total, deterministic order):
##   1. FINISHABLE this turn (squad can remove it now) — the single biggest survival lever.
##   2. Higher THREAT (accuracy × damage) — drop the deadliest body first.
##   3. More of our units can hit it now — concentrate where the squad can actually finish.
##   4. Lower HP — closest to dropping.
##   5. Nearer the squad, then lowest id — stable, reproducible.
func _focus_better(a, b) -> bool:
	var fa: bool = _est_squad_damage_on(a) >= a.hp
	var fb: bool = _est_squad_damage_on(b) >= b.hp
	if fa != fb:
		return fa
	var ta: int = _enemy_threat(a)
	var tb: int = _enemy_threat(b)
	if ta != tb:
		return ta > tb
	var ha: int = _hitters_on(a)
	var hb: int = _hitters_on(b)
	if ha != hb:
		return ha > hb
	if a.hp != b.hp:
		return a.hp < b.hp
	var da: int = _dist_to_nearest_unit(a)
	var db: int = _dist_to_nearest_unit(b)
	if da != db:
		return da < db
	return a.id < b.id


## The squad's shared focus target — the best living ENEMY unit by _focus_better, or null. Pure
## function of state (stable id iteration + total comparator): every unit computes the same focus,
## so the whole cell concentrates its shots + movement on removing that one body first.
func _focus_target():
	var best = null
	for eid in state.entity_ids_sorted():
		var e = state.entities.get(eid)
		if e == null or not e.is_unit or not e.alive or e.faction != E.Faction.ENEMY:
			continue
		if best == null or _focus_better(e, best):
			best = e
	return best


# ================== STAGE 1: damage-avoidant positioning =======================

## Estimated damage enemies would land on `me` if it stood on tile `p` (rng-free): Σ over living
## enemies with range+LoS to `p` of hit_chance% × their expected shot damage, evaluated against a
## PROBE CLONE of `me` placed at `p` — so directional cover, flanking, and range falloff are all
## counted EXACTLY as ShootCommand would resolve them. Lower == safer tile. Draws nothing.
func _incoming_at(me, p: Vector2i) -> int:
	var probe = me.clone()
	probe.pos = p
	var total: int = 0
	for eid in state.entity_ids_sorted():
		var e = state.entities.get(eid)
		if e == null or not e.is_unit or not e.alive or e.faction != E.Faction.ENEMY:
			continue
		if not (ShootCommand.has_range(e.pos, p) and ShootCommand.in_los(state, e.pos, p)):
			continue
		total += (ShootCommand.hit_chance(state, e, probe) * _expected_shot_damage(e)) / 100
	return total


## First step of a damage-avoidant advance toward `objective` (the nearest enemy — closing on a
## distant focus would over-extend a lone unit). ONE step is committed per phase (ranged units hold
## after), so this scores the ACTUAL landing tile's exposure rather than a far destination's:
##   Pass 1 — if a walkable NEIGHBOR can shoot the objective, step to the one with the LEAST incoming
##            fire (engage from cover), ties -> nearer the objective, then stable coord.
##   Pass 2 — else CLOSE: among neighbors that reduce Manhattan distance to the objective, take the
##            one with the LEAST incoming fire (hug cover along the approach), ties -> nearer, coord.
##   Pass 3 — if no neighbor makes progress (a wall/body blocks the straight line), fall back to the
##            BFS `_step_for_shot` route so the unit still flanks around cover instead of stalling.
## Returns `me.pos` when nothing improves. Pure of RNG; deterministic tie-breaks.
func _advance_step(me, objective) -> Vector2i:
	if objective == null:
		return me.pos
	var dst: Vector2i = objective.pos
	var here: Vector2i = me.pos
	var cur_dist: int = abs(here.x - dst.x) + abs(here.y - dst.y)
	# Pass 1: a neighbor from which we could shoot the objective THIS turn — safest one wins.
	var best_fire: Vector2i = here
	var bf_in: int = 1 << 30
	var bf_dist: int = 1 << 30
	var have_fire := false
	# Pass 2: a neighbor that closes the gap — least-exposed among equal progress.
	var best_close: Vector2i = here
	var bc_in: int = 1 << 30
	var bc_dist: int = 1 << 30
	var have_close := false
	for d in PILOT_DIRS4:
		var L: Vector2i = here + d
		if not _walkable_for_pilot(L):
			continue
		var inc: int = _incoming_at(me, L)
		var dd: int = abs(L.x - dst.x) + abs(L.y - dst.y)
		if ShootCommand.has_range(L, dst) and ShootCommand.in_los(state, L, dst):
			if not have_fire or inc < bf_in or (inc == bf_in and dd < bf_dist) \
					or (inc == bf_in and dd == bf_dist and _coord_before(L, best_fire)):
				best_fire = L; bf_in = inc; bf_dist = dd; have_fire = true
		if dd < cur_dist:
			if not have_close or inc < bc_in or (inc == bc_in and dd < bc_dist) \
					or (inc == bc_in and dd == bc_dist and _coord_before(L, best_close)):
				best_close = L; bc_in = inc; bc_dist = dd; have_close = true
	if have_fire:
		return best_fire
	if have_close:
		return best_close
	# Pass 3: straight line blocked — route around cover with the BFS pathing.
	return _step_for_shot(here, objective)


## Stable coordinate order (y then x) for deterministic tie-breaking of tiles.
func _coord_before(a: Vector2i, b: Vector2i) -> bool:
	if a.y != b.y:
		return a.y < b.y
	return a.x < b.x


## Safest ONE-tile retreat for a fragile `me` (a retreating ranged unit ends its turn after the step,
## so only the immediate landing matters): among walkable neighbors, the one with the LEAST incoming
## fire (reaching cover / breaking LoS), ties -> FARTHER from the nearest enemy, then stable coord.
## Returns `me.pos` unless a neighbor is STRICTLY safer than standing put (so a unit already in the
## safest spot holds instead of shuffling, and an un-exposed unit never flees). Pure of RNG.
func _retreat_step(me) -> Vector2i:
	var here: Vector2i = me.pos
	var here_in: int = _incoming_at(me, here)
	if here_in <= 0:
		return here   # not exposed where it stands — nothing to flee
	var best: Vector2i = here
	var best_in: int = here_in
	var best_away: int = _min_enemy_dist(here)
	for d in PILOT_DIRS4:
		var L: Vector2i = here + d
		if not _walkable_for_pilot(L):
			continue
		var inc: int = _incoming_at(me, L)
		var away: int = _min_enemy_dist(L)
		if inc < best_in or (inc == best_in and away > best_away) \
				or (inc == best_in and away == best_away and _coord_before(L, best)):
			best = L
			best_in = inc
			best_away = away
	if best != here and best_in < here_in:
		return best
	return here


## Manhattan distance from tile `p` to the nearest living enemy unit (bigger == farther/safer).
func _min_enemy_dist(p: Vector2i) -> int:
	var best: int = 1 << 30
	for eid in state.entity_ids_sorted():
		var e = state.entities.get(eid)
		if e == null or not e.is_unit or not e.alive or e.faction != E.Faction.ENEMY:
			continue
		var d: int = abs(e.pos.x - p.x) + abs(e.pos.y - p.y)
		if d < best:
			best = d
	return best


## The first step of the SHORTEST walkable path from `here` to any tile that has a clean SHOT
## on `target` (in range + line of sight) — a deterministic BFS. This routes a unit AROUND
## LoS-blocking cover (a table/crate the target hugs) to a flanking firing position, instead of
## greedily walking into the cover's shadow and stalling. If no firing tile is reachable, it
## falls back to the first step of the shortest path to a tile ADJACENT to the target (set up a
## melee shove). Returns `here` if the unit is already boxed in. BFS over 4-neighbours, stable
## DIRS4 expansion order so the chosen path is reproducible.
func _step_for_shot(here: Vector2i, target) -> Vector2i:
	var dst: Vector2i = target.pos
	# BFS frontier; record the FIRST step taken from `here` to reach each visited tile.
	var first_step: Dictionary = {}        # Vector2i -> Vector2i (the step out of `here`)
	var visited: Dictionary = {}
	visited[here] = true
	var queue: Array = []
	for d in [Vector2i(0, -1), Vector2i(1, 0), Vector2i(0, 1), Vector2i(-1, 0)]:
		var np: Vector2i = here + d
		if _walkable_for_pilot(np):
			visited[np] = true
			first_step[np] = np
			queue.append(np)
	var fallback := here                    # best adjacent-to-target tile if no shot tile found
	var fallback_set := false
	var qi: int = 0
	while qi < queue.size():
		var cell: Vector2i = queue[qi]
		qi += 1
		# A tile we can shoot from? Take its first step immediately (shortest by BFS order).
		if ShootCommand.has_range(cell, dst) and ShootCommand.in_los(state, cell, dst):
			return first_step[cell]
		# Track the first adjacent-to-target tile we reach as the melee fallback.
		if not fallback_set and (abs(cell.x - dst.x) + abs(cell.y - dst.y)) == 1:
			fallback = first_step[cell]
			fallback_set = true
		for d2 in [Vector2i(0, -1), Vector2i(1, 0), Vector2i(0, 1), Vector2i(-1, 0)]:
			var nn: Vector2i = cell + d2
			if visited.has(nn):
				continue
			if _walkable_for_pilot(nn):
				visited[nn] = true
				first_step[nn] = first_step[cell]
				queue.append(nn)
	if fallback_set:
		return fallback
	return here


## A tile a player auto-pilot may walk into: in-bounds, not a wall/gap, unoccupied, and not a
## live-danger layer (fire/electrified/telegraphed) or a standing/cycling hazard emitter or gas
## cloud. Plain L_WATER stays walkable (soak is survivable and sometimes necessary). Mirrors
## EnemyAI._passable's hazard block ("physics cuts both ways"); the melee fallback in
## _step_for_shot degrades gracefully if this ever leaves a unit with no path.
func _walkable_for_pilot(p: Vector2i) -> bool:
	if not state.in_bounds(p):
		return false
	var t = state.tile(p)
	if t.terrain == E.Terrain.WALL or t.hazard == E.Hazard.GAP:
		return false
	if state.occupant_at(p) != null:
		return false
	if t.hazard in PILOT_HAZARD_BLOCK:
		return false
	if t.has_layer(E.L_FIRE) or t.has_layer(E.L_ELECTRIFIED) or t.has_layer(E.L_TELEGRAPH) or t.has_layer(E.L_GAS):
		return false
	return true


## Direction to shove a directly-adjacent enemy into a gap/hazard/wall (advantageous, §12).
## ZERO if the enemy isn't orthogonally adjacent, isn't movable, or the push lands somewhere safe.
func _advantage_shove_dir(me, target) -> Vector2i:
	if not target.movable:
		return Vector2i.ZERO
	var dir: Vector2i = target.pos - me.pos
	if abs(dir.x) + abs(dir.y) != 1:
		return Vector2i.ZERO
	var ahead: Vector2i = target.pos + dir
	if not state.in_bounds(ahead):
		return dir            # off the train
	var t = state.tile(ahead)
	if t.hazard in [E.Hazard.GAP, E.Hazard.FURNACE, E.Hazard.RAIL_LIVE, E.Hazard.PISTON, E.Hazard.VENT, E.Hazard.LASER, E.Hazard.PLATE, E.Hazard.STEAM]:
		return dir
	if t.terrain == E.Terrain.WALL:
		return dir            # bonk for impact + possible Prone
	if t.has_layer(E.L_FIRE) or t.has_layer(E.L_ELECTRIFIED) or t.has_layer(E.L_TELEGRAPH):
		return dir
	# Into a volatile object: the collision drains its integrity and can trigger its on_break
	# (EXPLODE / FLOOD / SPILL_FIRE / TOPPLE) right on top of the enemy — free lethality (§12).
	var occ = state.occupant_at(ahead)
	if occ != null and not occ.is_unit and occ.integrity > 0 and occ.on_break in DANGEROUS_ON_BREAK:
		return dir
	# Into standing water → Soak setup (mirrors EnemyAI._advantageous_shove_dir): a soaked target
	# is easier to hit and opens the flood→electrify line.
	if t.has_layer(E.L_WATER):
		return dir
	return Vector2i.ZERO


## The best volatile-object play for unit `id`: over every orthogonally-adjacent movable object
## with a dangerous on_break, PREVIEW each candidate impulse (slam/shove away, plus throws in the
## 4 stable dirs for Light objects) on a PURE clone (PhysicsResolver == commit, RNG-free) and keep
## the one that harms enemies most. Score = DOWN_SCORE per previewed enemy kill + summed HP damage.
## Returns {obj:int, kind:String, dir:Vector2i, force:int, score:int} or null. Deterministic: stable
## entity + DIRS4 + candidate order; ties keep the first (strict > below).
func _best_object_play(id: int):
	var me = state.entities.get(id)
	if me == null or not me.alive:
		return null
	var best = null
	var best_score: int = 0
	for oid in state.entity_ids_sorted():
		var obj = state.entities.get(oid)
		if obj == null or obj.is_unit or not obj.alive or not obj.movable:
			continue
		if obj.integrity <= 0 or not (obj.on_break in DANGEROUS_ON_BREAK):
			continue
		if abs(me.pos.x - obj.pos.x) + abs(me.pos.y - obj.pos.y) != 1:
			continue   # must be orthogonally adjacent to push / throw it
		var away: Vector2i = obj.pos - me.pos
		var cands: Array = []
		cands.append({"kind": "slam", "dir": away, "force": E.SLAM_FORCE + me.slam_force_bonus})
		cands.append({"kind": "shove", "dir": away, "force": E.SHOVE_FORCE})
		if obj.mass == E.Mass.LIGHT:
			for d in PILOT_DIRS4:
				cands.append({"kind": "throw", "dir": d, "force": E.THROW_FORCE})
		for c in cands:
			var after = PhysicsResolver.resolve_impulse(state, obj.id, c.dir, c.force, true).state
			if _ally_casualty_vs(after):
				continue   # never a play that downs one of our own in the splash
			var sc: int = _enemy_harm_vs(after)
			if sc > best_score:
				best_score = sc
				best = {"obj": obj.id, "kind": c.kind, "dir": c.dir, "force": c.force, "score": sc}
	return best


## Integer harm score of `after` (a previewed clone) vs the live `state`, over living ENEMY units:
## DOWN_SCORE per enemy removed/downed, plus summed HP damage to survivors. Stable id order, no RNG.
func _enemy_harm_vs(after) -> int:
	var score: int = 0
	for eid in state.entity_ids_sorted():
		var before_e = state.entities.get(eid)
		if before_e == null or not before_e.is_unit or before_e.faction != E.Faction.ENEMY or not before_e.alive:
			continue
		var after_e = after.entities.get(eid)
		if after_e == null or not after_e.alive or (after_e.downed and not before_e.downed):
			score += DOWN_SCORE
			continue
		var dmg: int = before_e.hp - after_e.hp
		if dmg > 0:
			score += dmg
	return score


## Would `after` (a previewed clone) cost us a PLAYER unit — any living-standing player now removed or
## Downed? Vetoes friendly-fire object plays (chip damage to allies is tolerated; a casualty is not).
func _ally_casualty_vs(after) -> bool:
	for pid in state.entity_ids_sorted():
		var before_p = state.entities.get(pid)
		if before_p == null or not before_p.is_unit or before_p.faction != E.Faction.PLAYER:
			continue
		if not before_p.alive or before_p.downed:
			continue
		var after_p = after.entities.get(pid)
		if after_p == null or not after_p.alive or after_p.downed:
			return true
	return false


# ============================ W6-1 DEPTH TOOLS (abilities + items) ============================
## Count of ENEMY units newly DOWNED/removed in `after` (a previewed clone) vs the live state.
func _enemy_downs_vs(after) -> int:
	var n: int = 0
	for eid in state.entity_ids_sorted():
		var before_e = state.entities.get(eid)
		if before_e == null or not before_e.is_unit or before_e.faction != E.Faction.ENEMY or not before_e.alive:
			continue
		var after_e = after.entities.get(eid)
		if after_e == null or not after_e.alive or (after_e.downed and not before_e.downed):
			n += 1
	return n


## Count of NEW control/DoT debuffs applied to living ENEMY units in `after` vs the live state (each
## enemy contributes the number of PILOT_ENEMY_DEBUFF_BITS it gained). Lets a gas/flood/status setup
## score even when it deals no immediate HP (poison/burn tick later; prone/soak enable the cell).
func _enemy_debuff_gain_vs(after) -> int:
	var gained: int = 0
	for eid in state.entity_ids_sorted():
		var before_e = state.entities.get(eid)
		if before_e == null or not before_e.is_unit or before_e.faction != E.Faction.ENEMY or not before_e.alive:
			continue
		var after_e = after.entities.get(eid)
		if after_e == null or not after_e.alive:
			continue
		var newbits: int = after_e.status & PILOT_ENEMY_DEBUFF_BITS & ~before_e.status
		gained += _bit_count(newbits)
	return gained


func _bit_count(v: int) -> int:
	var n: int = 0
	var x: int = v
	while x != 0:
		n += x & 1
		x = x >> 1
	return n


## PURE PREVIEW of casting `def` (an AbilityDef or ItemDef) from unit `id` at the given target — clone
## the state, run the SAME AbilitySystem executor the command uses (ctx.turn=null: AP/grant effects are
## irrelevant to harm scoring), score enemy harm + new debuffs, veto ally casualties. Returns
## {target_id, target_pos, dir, score, downs} or null (ally casualty). preview==commit: the clone deep-
## copies the rng, so a committed ranged cast draws the identical stream this preview scored.
func _score_cast(id: int, def: Dictionary, target_id: int, target_pos: Vector2i, dir: Vector2i):
	var clone = state.clone()
	var ctx := {"actor": id, "target_id": target_id, "target_pos": target_pos, "dir": dir, "turn": null}
	AbilitySystem.execute(clone, def, ctx)
	if _ally_casualty_vs(clone):
		return null
	var score: int = _enemy_harm_vs(clone) + _enemy_debuff_gain_vs(clone) * PILOT_CAST_DEBUFF_VALUE
	return {"target_id": target_id, "target_pos": target_pos, "dir": dir, "score": score, "downs": _enemy_downs_vs(clone)}


## Keep the strictly-higher-score cast choice; ties keep the first-seen (stable, deterministic).
func _better_cast(a, b):
	if b == null:
		return a
	if a == null:
		return b
	return b if b.score > a.score else a


## The best TARGET for offensive `def` cast by unit `id`, previewed per targeting kind. Tile AoE centers
## on each in-range enemy tile (the cluster); enemy-targeting scans in-range enemies; direction scans the
## 4 stable dirs; self casts once. Returns the best {target_id,target_pos,dir,score,downs} or null.
## Deterministic (stable id / DIRS4 order; strict-> tiebreak).
func _best_cast_target(id: int, def: Dictionary):
	var me = state.entities.get(id)
	if me == null:
		return null
	var targeting: String = String(def.get("targeting", "self"))
	var rng_tiles: int = int(def.get("range", 0))
	var best = null
	match targeting:
		"self", "":
			best = _score_cast(id, def, -1, Vector2i.ZERO, Vector2i.ZERO)
		"enemy":
			for eid in state.entity_ids_sorted():
				var e = state.entities.get(eid)
				if e == null or not e.is_unit or not e.alive or e.faction != E.Faction.ENEMY:
					continue
				if abs(me.pos.x - e.pos.x) + abs(me.pos.y - e.pos.y) > rng_tiles:
					continue
				best = _better_cast(best, _score_cast(id, def, e.id, e.pos, Vector2i.ZERO))
		"tile":
			for eid2 in state.entity_ids_sorted():
				var e2 = state.entities.get(eid2)
				if e2 == null or not e2.is_unit or not e2.alive or e2.faction != E.Faction.ENEMY:
					continue
				if abs(me.pos.x - e2.pos.x) + abs(me.pos.y - e2.pos.y) > rng_tiles:
					continue
				best = _better_cast(best, _score_cast(id, def, -1, e2.pos, Vector2i.ZERO))
		"direction":
			for d in PILOT_DIRS4:
				best = _better_cast(best, _score_cast(id, def, -1, Vector2i.ZERO, d))
	return best


## True if `def` (ability/item) has an OFFENSIVE-cast effect kind — and is not a toAdjacent-move ability
## (Lunge): the generic preview does not reposition the actor, so a repositioning ability's previewed
## harm would diverge from commit; those stay with the raw melee/physics path.
func _def_is_offensive(def: Dictionary) -> bool:
	for eff in def.get("effects", []):
		if String(eff.get("kind", "")) == "move" and eff.get("toAdjacent", false):
			return false
	for eff2 in def.get("effects", []):
		if PILOT_OFFENSIVE_KINDS.has(String(eff2.get("kind", ""))):
			return true
	return false


## Affordable OFFENSIVE cast candidates for unit `id`: usable items (consumable/gadget) first, then
## chosen abilities, each {source, def, iid}. Stable gear/chosen order → deterministic candidate scan.
func _offensive_cast_specs(id: int) -> Array:
	var out: Array = []
	var e = state.entities.get(id)
	if e == null or db == null:
		return out
	var ap: int = turn.ap_for(id) if turn != null else 0
	var seen := {}
	for gid in e.gear:
		var key := String(gid)
		if seen.has(key):
			continue
		seen[key] = true
		var idef: Dictionary = db.item(key)
		if idef.is_empty():
			continue
		var slot := String(idef.get("slot", ""))
		if slot != "consumable" and slot != "gadget":
			continue
		if not _def_is_offensive(idef) or ap < int(idef.get("apCost", 1)):
			continue
		out.append({"source": "item", "def": idef, "iid": key})
	var inst = _instance_by_id(e.instance_id)
	if inst != null:
		for aid in inst.chosen_abilities:
			var adef: Dictionary = db.ability(String(aid))
			if adef.is_empty() or not _def_is_offensive(adef) or ap < int(adef.get("apCost", 1)):
				continue
			out.append({"source": "ability", "def": adef, "iid": ""})
	return out


## The best OFFENSIVE ability/item play for unit `id` by previewed score (clone preview per candidate +
## target). Returns {cmd, score, downs} or null. The caller fires it when score >= a shot's worth AND it
## either downs an enemy or no guaranteed removal shot exists. Deterministic; preview==commit.
func _best_offensive_cast(id: int):
	var me = state.entities.get(id)
	if me == null or not me.alive:
		return null
	var best = null
	var best_score: int = 0
	for spec in _offensive_cast_specs(id):
		var def: Dictionary = spec.def
		var choice = _best_cast_target(id, def)
		if choice == null:
			continue
		if choice.score > best_score:
			best_score = choice.score
			var cmd
			if spec.source == "item":
				cmd = UseItemCommand.new(id, def, spec.iid, choice.target_id, choice.target_pos, choice.dir)
			else:
				cmd = AbilityCommand.new(id, def, choice.target_id, choice.target_pos, choice.dir)
			best = {"cmd": cmd, "score": choice.score, "downs": choice.downs}
	return best


## True if `def` (ally/self-targeted) has a positive HEAL effect — a medkit / Steward patch.
func _def_has_heal(def: Dictionary) -> bool:
	var targeting := String(def.get("targeting", "self"))
	if targeting != "ally" and targeting != "self":
		return false
	for eff in def.get("effects", []):
		if String(eff.get("kind", "")) == "heal" and int(eff.get("amount", 0)) > 0:
			return true
	return false


func _heal_amount_of(def: Dictionary) -> int:
	var total: int = 0
	for eff in def.get("effects", []):
		if String(eff.get("kind", "")) == "heal":
			total += int(eff.get("amount", 0))
	return total


## Affordable HEAL candidates for unit `id`: usable items first (spend a consumable before an ability),
## then chosen abilities, each {source, def, iid}. Stable order → deterministic.
func _heal_specs(id: int) -> Array:
	var out: Array = []
	var e = state.entities.get(id)
	if e == null or db == null:
		return out
	var ap: int = turn.ap_for(id) if turn != null else 0
	var seen := {}
	for gid in e.gear:
		var key := String(gid)
		if seen.has(key):
			continue
		seen[key] = true
		var idef: Dictionary = db.item(key)
		if idef.is_empty():
			continue
		var slot := String(idef.get("slot", ""))
		if slot != "consumable" and slot != "gadget":
			continue
		if not _def_has_heal(idef) or ap < int(idef.get("apCost", 1)):
			continue
		out.append({"source": "item", "def": idef, "iid": key})
	var inst = _instance_by_id(e.instance_id)
	if inst != null:
		for aid in inst.chosen_abilities:
			var adef: Dictionary = db.ability(String(aid))
			if adef.is_empty() or not _def_has_heal(adef) or ap < int(adef.get("apCost", 1)):
				continue
			out.append({"source": "ability", "def": adef, "iid": ""})
	return out


## The most-wounded reachable friendly (self or ally within `rng_tiles`) that is HURT — hp <=
## ceil(max_hp*PILOT_HEAL_PCT/100) and below max — or null. Downed allies are excluded (they are
## stabilized, not healed). Deterministic: lowest hp, then lowest id.
func _most_wounded_friendly(me, rng_tiles: int):
	var best = null
	for pid in state.entity_ids_sorted():
		var u = state.entities.get(pid)
		if u == null or not u.is_unit or not u.alive or u.downed or u.faction != E.Faction.PLAYER:
			continue
		if u.max_hp <= 0 or u.hp >= u.max_hp:
			continue
		if abs(me.pos.x - u.pos.x) + abs(me.pos.y - u.pos.y) > rng_tiles:
			continue
		var threshold: int = (u.max_hp * PILOT_HEAL_PCT + 99) / 100   # ceil(max_hp*PCT/100), integer
		if u.hp > threshold:
			continue
		if best == null or u.hp < best.hp or (u.hp == best.hp and u.id < best.id):
			best = u
	return best


## The best HEAL play for unit `id`: a medkit / patch (item or ability) on the most-wounded reachable
## friendly (self or ally in range), restoring at least PILOT_HEAL_MIN HP. Returns {cmd, target_id,
## restored} or null. Heals are rng-free (preview==commit trivially). Stable candidate/target order.
func _best_heal_play(id: int):
	var me = state.entities.get(id)
	if me == null or not me.alive:
		return null
	var best = null
	var best_restored: int = 0
	for spec in _heal_specs(id):
		var def: Dictionary = spec.def
		var amount: int = _heal_amount_of(def)
		if amount <= 0:
			continue
		var target = _most_wounded_friendly(me, int(def.get("range", 0)))
		if target == null:
			continue
		var restored: int = min(amount, max(0, target.max_hp - target.hp))
		if restored < PILOT_HEAL_MIN:
			continue
		if restored > best_restored:
			best_restored = restored
			var cmd
			if spec.source == "item":
				cmd = UseItemCommand.new(id, def, spec.iid, target.id)
			else:
				cmd = AbilityCommand.new(id, def, target.id)
			best = {"cmd": cmd, "target_id": target.id, "restored": restored}
	return best


## True once the fight is JOINED — some living player unit has range + LoS on a living enemy (so a
## timed area buff pays off rather than being wasted before contact).
func _fight_is_joined() -> bool:
	for eid in state.entity_ids_sorted():
		var e = state.entities.get(eid)
		if e == null or not e.is_unit or not e.alive or e.faction != E.Faction.ENEMY:
			continue
		if _hitters_on(e) > 0:
			return true
	return false


func _def_has_buff(def: Dictionary) -> bool:
	for eff in def.get("effects", []):
		if String(eff.get("kind", "")) == "buff":
			return true
	return false


func _allies_in_area(center: Vector2i, area: int) -> int:
	var n: int = 0
	for pid in state.entity_ids_sorted():
		var u = state.entities.get(pid)
		if u == null or not u.is_unit or not u.alive or u.downed or u.faction != E.Faction.PLAYER:
			continue
		if abs(u.pos.x - center.x) + abs(u.pos.y - center.y) <= area:
			n += 1
	return n


## A timed area BUFF cast (Rally / Warcry) for unit `id` — only when the fight is JOINED, this unit has
## NO shot to take from here (so it isn't giving up fire), and the buff lifts >= 2 living allies. Centered
## on the caster (the cell hub). Returns {cmd, allies} or null. Deterministic (chosen-ability order).
func _best_buff_cast(id: int):
	var me = state.entities.get(id)
	if me == null or db == null:
		return null
	# FIRST-ACTION-ONLY: a timed buff is cast at full AP (its own first action) — re-applying an already-
	# live buff on the same turn just burns AP, so a unit that already acted this phase does not re-buff.
	if turn == null or turn.ap_for(id) < E.AP_PER_TURN:
		return null
	if _best_shootable_enemy(me) != null:
		return null   # a unit with a shot fires it — a buff never pre-empts direct fire
	if not _fight_is_joined():
		return null
	var ap: int = turn.ap_for(id) if turn != null else 0
	var inst = _instance_by_id(me.instance_id)
	if inst == null:
		return null
	for aid in inst.chosen_abilities:
		var def: Dictionary = db.ability(String(aid))
		if def.is_empty() or ap < int(def.get("apCost", 1)) or not _def_has_buff(def):
			continue
		var area: int = 0
		for eff in def.get("effects", []):
			if String(eff.get("kind", "")) == "buff":
				area = max(area, int(eff.get("area", 0)))
		if _allies_in_area(me.pos, area) >= 2:
			return {"cmd": AbilityCommand.new(id, def, -1, me.pos), "allies": _allies_in_area(me.pos, area)}
	return null


## The best in-line-of-fire volatile object to SHOOT to trigger its on_break near enemies: a
## destructible dangerous-on_break object within weapon range + LoS that a SINGLE shot pops, whose
## previewed break harms enemies at least OBJECT_PLAY_MIN_SCORE. Returns {obj:int, score:int} or null.
## Deterministic (stable id order; ties keep the first via strict >). Objects are shootable RNG-free.
func _best_shoot_object_play(id: int):
	var me = state.entities.get(id)
	if me == null or not me.alive:
		return null
	var best = null
	var best_score: int = 0
	for oid in state.entity_ids_sorted():
		var obj = state.entities.get(oid)
		if obj == null or obj.is_unit or not obj.alive:
			continue
		if obj.integrity <= 0 or not (obj.on_break in DANGEROUS_ON_BREAK):
			continue
		if not (ShootCommand.has_range(me.pos, obj.pos) and ShootCommand.in_los(state, me.pos, obj.pos)):
			continue
		# Only take the shot if it POPS the object now (a rng-free object hit deals this flat damage);
		# chipping a volatile prop over several turns telegraphs nothing and wastes the tempo.
		var obj_dmg: int = (E.SHOOT_DAMAGE_BASE + me.object_damage_bonus) * max(1, me.object_damage_mult)
		if obj_dmg < obj.integrity:
			continue
		var after = PhysicsResolver.resolve_break(state, obj.id).state
		if _ally_casualty_vs(after):
			continue   # don't detonate it into our own cell
		var sc: int = _enemy_harm_vs(after)
		if sc > best_score:
			best_score = sc
			best = {"obj": obj.id, "score": sc}
	return best


## The first living ENEMY unit that is Soaked AND standing on a water tile (flood→electrify is live),
## in stable id order, or null.
func _soaked_enemy_in_water():
	for eid in state.entity_ids_sorted():
		var e = state.entities.get(eid)
		if e == null or not e.is_unit or not e.alive or e.faction != E.Faction.ENEMY:
			continue
		if e.has_status(E.S_SOAKED) and state.in_bounds(e.pos) and state.tile(e.pos).has_layer(E.L_WATER):
			return e
	return null


## The persistent UnitInstance behind combat body `iid` (run.squad back-link), or null.
func _instance_by_id(iid: int):
	if run == null:
		return null
	for u in run.squad:
		if u.id == iid:
			return u
	return null


## The AbilityDef of unit `id`'s FIRST chosen ability whose kit includes an 'electrify' effect
## (Saboteur Junction / Marksman Soaked-Spark), or {} if it has none. Reads the persistent squad.
func _unit_electrify_ability(id: int) -> Dictionary:
	var e = state.entities.get(id)
	if e == null or e.instance_id < 0 or db == null:
		return {}
	var inst = _instance_by_id(e.instance_id)
	if inst == null:
		return {}
	for aid in inst.chosen_abilities:
		var ab: Dictionary = db.ability(String(aid))
		for eff in ab.get("effects", []):
			if eff.get("kind", "") == "electrify":
				return ab
	return {}


## Build a valid AbilityCommand to fire `ab` (an electrify kit) from unit `id`, targeting a
## soaked-in-water enemy per the ability's targeting kind. Returns null if no valid target is in
## range (the electrify effect itself shocks every soaked-in-water unit regardless of the anchor).
func _electrify_command(id: int, ab: Dictionary):
	var me = state.entities.get(id)
	if me == null:
		return null
	var anchor = _soaked_enemy_in_water()
	var targeting: String = ab.get("targeting", "self")
	var rng_tiles: int = int(ab.get("range", 0))
	match targeting:
		"enemy":
			if anchor != null and abs(me.pos.x - anchor.pos.x) + abs(me.pos.y - anchor.pos.y) <= rng_tiles:
				return AbilityCommand.new(id, ab, anchor.id)
			return null
		"tile":
			if anchor != null and abs(me.pos.x - anchor.pos.x) + abs(me.pos.y - anchor.pos.y) <= rng_tiles:
				return AbilityCommand.new(id, ab, -1, anchor.pos)
			return null
		"self", "":
			return AbilityCommand.new(id, ab)
		_:
			return null


## Is `t` a captain whose gate makes shooting it pointless right now — either a damage-shielded
## captain (gas/cover key: captain_gate_open false) or a soak-shove captain still un-soaked (the
## trap line needs a soak first)?
func _is_gated_captain(t) -> bool:
	if t == null or not t.is_unit or t.captain_key == "":
		return false
	if not t.captain_gate_open:
		return true
	if t.phys_trait == E.PhysTrait.UNSHOVABLE_UNTIL_SOAKED and not t.has_status(E.S_SOAKED):
		return true
	return false


## The gate TOOL to work for gated captain `cap`: the FLOOD-onBreak object nearest the captain
## (soak / gas-dispersal source) — or, for a cover-strip captain, the nearest cover-granting
## object protecting it. null if none is authored in the car. Deterministic (nearest-to-captain;
## ties → lowest id via sorted iteration + strict <).
func _gate_tool_for(cap):
	var want_cover: bool = cap.captain_key == "destroy_his_cover_then_flank"
	var best = null
	var best_d: int = 1 << 30
	for oid in state.entity_ids_sorted():
		var o = state.entities.get(oid)
		if o == null or o.is_unit or not o.alive or o.integrity <= 0:
			continue
		var is_tool: bool = (o.cover > 0) if want_cover else (o.on_break == E.OnBreak.FLOOD)
		if not is_tool:
			continue
		var d: int = abs(cap.pos.x - o.pos.x) + abs(cap.pos.y - o.pos.y)
		if d < best_d:
			best_d = d
			best = o
	return best


## PURE preview: would breaking `tool` (as it stands) leave captain `cap` Soaked? Resolves the
## break over a CLONE (no mutation, RNG-free) and reads the captain's status — exact match to the
## committed outcome. Guards the soak-captain retarget so we never divert fire to a tank whose
## flood splash falls short of the captain.
func _break_would_soak(tool, cap) -> bool:
	var res = PhysicsResolver.resolve_break(state, tool.id)
	var c = res.state.entities.get(cap.id)
	return c != null and c.has_status(E.S_SOAKED)


## Drive unit `id` at the gate `tool`: shoot it to break it (objects are shootable, RNG-free), else
## (unless immediate_only) close on a firing tile, else shove/slam it toward the captain. Returns the
## action label issued ("shoot"/"slam"/"move") or "" if nothing could be done from here.
func _work_gate_tool(id: int, tool, immediate_only: bool, events: Array) -> String:
	var me = state.entities.get(id)
	if me == null or not me.alive:
		return ""
	# a) In range + LoS → shoot it (guaranteed rng-free object hit → break chain: flood / cover-strip).
	if ShootCommand.has_range(me.pos, tool.pos) and ShootCommand.in_los(state, me.pos, tool.pos):
		var shc := ShootCommand.new(id, tool.id)
		var r: Dictionary = turn.try_command(shc)
		if r.ok:
			_append(events, r.events)
			return "shoot"
	# b) Orthogonally adjacent → shove/slam it toward the captain (impulse into the gate).
	if abs(me.pos.x - tool.pos.x) + abs(me.pos.y - tool.pos.y) == 1:
		var dir: Vector2i = tool.pos - me.pos
		var slc := SlamCommand.new(id, tool.id, dir, E.SLAM_FORCE + me.slam_force_bonus)
		var r2: Dictionary = turn.try_command(slc)
		if r2.ok:
			_append(events, r2.events)
			return "slam"
	# c) Otherwise close on a firing/adjacent tile of the tool — but only for a fully damage-gated
	#    captain (a still-shootable soak captain falls through to normal fire instead of trekking).
	if not immediate_only:
		var step := _step_for_shot(me.pos, tool)
		if step != me.pos:
			var mc := MoveCommand.new(id, [step])
			var r3: Dictionary = turn.try_command(mc)
			if r3.ok:
				_append(events, r3.events)
				return "move"
	return ""


## The designated SOAK "wrangler": the living PLAYER unit nearest (Manhattan) to the movable flood
## `tool`, ties → lowest id, within SOAK_WRANGLE_RANGE. Returns -1 if none is close enough (so the
## whole cell never abandons the fight to chase a distant tank). Deterministic (sorted scan, no RNG).
func _soak_wrangler_id(tool) -> int:
	var best_id: int = -1
	var best_d: int = SOAK_WRANGLE_RANGE + 1
	for id in state.entity_ids_sorted():
		var e = state.entities.get(id)
		if e == null or not e.is_unit or not e.alive or e.faction != E.Faction.PLAYER:
			continue
		var d: int = abs(e.pos.x - tool.pos.x) + abs(e.pos.y - tool.pos.y)
		if d <= SOAK_WRANGLE_RANGE and d < best_d:
			best_d = d
			best_id = e.id
	return best_id


## The SOAK-GATE multi-turn playbook for the designated wrangler `id` vs soak-gated captain `cap`,
## using movable flood source `tool`. STATELESS + deterministic — the plan re-derives from the board
## every turn, so it survives clones/replays exactly:
##   - If breaking the tool NOW would soak the captain (pure preview), break it from where the unit
##     already stands (shoot in range / slam if adjacent) — the payoff step. Never treks to it.
##   - Else shepherd the tool ONE impulse toward the captain: shove/slam it closer when the wrangler
##     already stands on the push tile. Every push is preview-verified to make progress and to never
##     waste-break the tool or catch an ally. Returns the action label or "" (fall through).
func _soak_playbook(id: int, tool, cap, events: Array) -> String:
	if _break_would_soak(tool, cap):
		# The flood already reaches: break it if we can do so from HERE (shoot in range / slam if
		# adjacent). immediate_only — never TREK to the tool: diverting a unit across the car costs
		# more tempo (and exposure) than a soaked captain is worth, and flips marginal fights (telemetry).
		return _work_gate_tool(id, tool, true, events)
	if not tool.movable:
		return ""
	return _push_tool_toward_captain(id, tool, cap, events)


## Shepherd movable flood `tool` one impulse toward `cap`. The wrangler shoves/slams the tool along
## the dominant axis toward the captain, but ONLY when it already stands on the correct push tile
## (tool minus the push dir) — it never treks there. Commits only when a PURE preview shows progress
## (the tool ends alive + strictly closer, OR the push itself soaks the captain) and no ally is caught.
func _push_tool_toward_captain(id: int, tool, cap, events: Array) -> String:
	var me = state.entities.get(id)
	if me == null or not me.alive:
		return ""
	var dir: Vector2i = _push_dir_toward(tool.pos, cap.pos)
	if dir == Vector2i.ZERO:
		return ""
	var stand: Vector2i = tool.pos - dir   # tile to stand on to push the tool in +dir
	# On the push tile → drive the tool in. Prefer a Slam (more momentum, travels farther) when it
	# progresses; else a Shove. Preview-verified so a push never wastes the one-shot tool.
	if me.pos == stand:
		for cand in [{"kind": "slam", "force": E.SLAM_FORCE + me.slam_force_bonus},
				{"kind": "shove", "force": E.SHOVE_FORCE}]:
			if not _push_progresses(tool, cap, dir, cand.force):
				continue
			var cmd
			if cand.kind == "slam":
				cmd = SlamCommand.new(id, tool.id, dir, cand.force)
			else:
				cmd = ShoveCommand.new(id, tool.id, dir, cand.force)
			var r: Dictionary = turn.try_command(cmd)
			if r.ok:
				_append(events, r.events)
				return "object"
	# Not standing on the push tile — do NOT trek to it. Marching a unit onto the tank's far side
	# costs tempo + exposes it, flipping marginal captain fights (measured in telemetry). The push is
	# purely opportunistic: it fires only for a wrangler the fight ALREADY placed beside the tool.
	return ""


## Stable one-step push direction that carries `from` toward `to`: reduce the LARGER axis gap first
## (tie → horizontal), matching the resolver's axis conventions. ZERO if already on `to`.
func _push_dir_toward(from: Vector2i, to: Vector2i) -> Vector2i:
	var dx: int = to.x - from.x
	var dy: int = to.y - from.y
	if dx == 0 and dy == 0:
		return Vector2i.ZERO
	if abs(dx) >= abs(dy):
		return Vector2i(sign(dx), 0)
	return Vector2i(0, sign(dy))


## PURE preview: does pushing `tool` in `dir` at `force` make progress toward soaking `cap`? True iff
## the push either soaks the captain outright OR leaves the tool ALIVE and strictly closer (Manhattan)
## to the captain — and never at the cost of a player casualty. Resolves on a CLONE (preview==commit),
## draws no rng: the multi-turn shepherd stays a pure function of board state.
func _push_progresses(tool, cap, dir: Vector2i, force: int) -> bool:
	var before_d: int = abs(tool.pos.x - cap.pos.x) + abs(tool.pos.y - cap.pos.y)
	var after = PhysicsResolver.resolve_impulse(state, tool.id, dir, force, true).state
	if _ally_casualty_vs(after):
		return false
	var c = after.entities.get(cap.id)
	if c != null and c.has_status(E.S_SOAKED):
		return true
	var t = after.entities.get(tool.id)
	if t == null or not t.alive:
		return false   # the push broke the tool without soaking — a wasted one-shot, veto
	var after_d: int = abs(t.pos.x - cap.pos.x) + abs(t.pos.y - cap.pos.y)
	return after_d < before_d


func _append(dst: Array, src: Array) -> void:
	for ev in src:
		dst.push_back(ev)


# ============================ non-combat cars =================================
## Resolve a non-combat car (upgrade / bourgeois / recruit / event / rest / shop) by driving
## the REAL RunState economy rail with a sensible default choice (the screen surfaces the
## choice on-screen; headless takes the default). Then mark it resolved.
func _resolve_screen_car(car) -> void:
	var picked := ""
	match car.car_type:
		E.CarType.SHOP:
			picked = _do_shop(car)
		E.CarType.UPGRADE:
			picked = _do_workshop(car)
		E.CarType.BOURGEOIS:
			picked = _do_bourgeois(car)
		E.CarType.RECRUIT:
			picked = _do_recruit(car)
		E.CarType.EVENT:
			picked = _do_event(car)
		E.CarType.REST:
			picked = _do_rest(car)
		_:
			picked = "no-op"
	trace.append("CAR %d [%s/%s]: %s" % [run.position, _type_name(car.car_type), car.template_id, picked])
	run.resolve_current()


func _do_shop(car) -> String:
	var stock: Array = _shop_stock()
	if screens != null:
		screens.show_shop(run, stock)
	# Default: buy the first stocked item (a REAL usable id) if we can afford it, else browse-and-
	# leave. W3-1: the purchase now ATTACHES to the lead's inventory on the headless/AUTO path too
	# (previously on-screen-only), so an AUTO run actually carries the item into combat.
	if not stock.is_empty() and run.can_afford("scrip", E.MARKET_BUY_SCRIP_COST):
		var oid: String = String(stock[0])
		if run.market_buy(oid):
			_attach_item_to_lead(oid)
			return "SHOP: bought %s (-%d scrip)" % [oid, E.MARKET_BUY_SCRIP_COST]
	return "SHOP: browsed (insufficient scrip)"


## W3-1/W3-2: the REAL, deterministically-rotating stock for the shop at the current line position.
## Selects SHOP_STOCK_COUNT distinct ids from SHOP_POOL using an INDEPENDENT IntRng seeded off
## (seed, position) — never the combat to-hit stream — so a fixed run reproduces identical stock and
## two different shops on the line offer different items (several authored items become obtainable per
## run). All ids resolve to a usable ItemDef (guarded by the W3 economy suite).
func _shop_stock() -> Array:
	var pos: int = run.position if run != null else 0
	var srng := IntRng.new((seed ^ (SHOP_STOCK_SALT + pos)) & 0xFFFFFFFF)
	var pool: Array = SHOP_POOL.duplicate()
	var out: Array = []
	for _k in range(SHOP_STOCK_COUNT):
		if pool.is_empty():
			break
		var idx: int = srng.randi_range(0, pool.size() - 1)
		out.append(String(pool[idx]))
		pool.remove_at(idx)
	return out


## W3-2: the EQUIPMENT half of the shop — a deterministic rotating pair of WEAPON/ARMOR ids from
## EQUIP_POOL at the current line position, keyed off an INDEPENDENT (seed, position) IntRng stream
## (EQUIP_STOCK_SALT). Same shape/discipline as _shop_stock but a separate pool + salt, so: (a) the
## consumable stock the W3-1 suite pins stays exactly what it was, and (b) different shops on the line
## offer different equipment — several of the 15 authored weapons/armor become obtainable per run.
## A purchased id auto-equips onto the lead and confers its passive effect in combat (to_sim_entity).
func _shop_equipment_stock() -> Array:
	var pos: int = run.position if run != null else 0
	var srng := IntRng.new((seed ^ (EQUIP_STOCK_SALT + pos)) & 0xFFFFFFFF)
	var pool: Array = EQUIP_POOL.duplicate()
	var out: Array = []
	for _k in range(EQUIP_STOCK_COUNT):
		if pool.is_empty():
			break
		var idx: int = srng.randi_range(0, pool.size() - 1)
		out.append(String(pool[idx]))
		pool.remove_at(idx)
	return out


func _do_workshop(car) -> String:
	if screens != null:
		screens.show_workshop(run)
	if run.can_afford("scrip", E.WORKSHOP_UPGRADE_SCRIP_COST):
		run.workshop_upgrade("reinforced_plating")
		return "WORKSHOP: upgrade reinforced_plating (-%d scrip)" % E.WORKSHOP_UPGRADE_SCRIP_COST
	return "WORKSHOP: no upgrade (insufficient scrip)"


func _do_bourgeois(car) -> String:
	if screens != null:
		screens.show_bourgeois(run)
	# Default to MERCY (spare) — the merciful path that lowers Order (toward the good endings).
	var res := run.resolve_bourgeois(true)
	return "BOURGEOIS: spared (Order -> %d)" % run.order


func _do_recruit(car) -> String:
	if screens != null:
		screens.show_recruit(run)
	# Default: accept the recruit (fills slots; counts toward Liberation). Deterministic rng.
	var rec_rng := IntRng.new((seed ^ (0x5EC0 + run.position)) & 0xFFFFFFFF)
	var next_id: int = _next_roster_id()
	var res := Recruitment.roll_recruit(db, rec_rng, run.squad, next_id)
	if res.get("ok", false):
		run.input_log.append({"op": "recruit", "pos": run.position})
		return "RECRUIT: %s joined (squad %d)" % [res.unit.name, run.squad.size()]
	return "RECRUIT: declined (squad full)"


func _do_event(car) -> String:
	if screens != null:
		screens.show_event(run)
	# Default text choice: take the safe outcome — a small Tools find, no Order change.
	run.earn("tools", 1)
	return "EVENT: took the safe option (+1 tools)"


func _do_rest(car) -> String:
	if screens != null:
		screens.show_rest(run)
	if run.rest_heal():
		return "REST: squad healed (-%d supplies)" % E.REST_HEAL_SUPPLY_COST
	return "REST: could not afford (no supplies)"


# ============================ INTERACTIVE non-combat cars (S3; on-screen only) =
## The on-screen ECONOMY phase: the operator makes a REAL choice on each non-combat car through the
## RunScreens econ surface instead of auto-defaulting. Mirrors _run_draft_interactive's wait-for-input
## shape (present surface -> yield frames until the operator commits/leaves -> drive the rail). NEVER
## runs headless or in --sim AUTO mode — both take the byte-stable _do_* default. A screen car ALWAYS
## resolves + advances (ESC -> the safe default; a spin-cap can never hard-hang the window).
func _resolve_screen_car_interactive(car) -> void:
	var picked := ""
	_in_econ = true
	match car.car_type:
		E.CarType.SHOP:
			picked = await _run_shop_interactive(car)
		E.CarType.UPGRADE:
			picked = await _run_workshop_interactive(car)
		E.CarType.BOURGEOIS:
			picked = await _run_bourgeois_interactive(car)
		E.CarType.RECRUIT:
			picked = await _run_recruit_interactive(car)
		E.CarType.EVENT:
			picked = await _run_event_interactive(car)
		E.CarType.REST:
			picked = await _run_rest_interactive(car)
		_:
			picked = "no-op"
	_in_econ = false
	if screens != null:
		screens.hide_econ_surface()
	trace.append("CAR %d [%s/%s]: %s" % [run.position, _type_name(car.car_type), car.template_id, picked])
	run.resolve_current()


## Block until the operator commits an option or leaves (ESC -> "leave"). Yields frames so econ
## surface taps + key presses are delivered. Returns "commit:<opt>" / "leave". A safety spin-cap can
## never hard-hang the window — it falls back to "leave" (the safe default) so a car always resolves.
func _await_econ_action() -> String:
	_econ_action = ""
	_awaiting_econ = true
	var spins: int = 0
	while _awaiting_econ:
		if _econ_action != "":
			_awaiting_econ = false
			break
		await get_tree().process_frame
		spins += 1
		if spins > 5000000:
			_awaiting_econ = false
			return "leave"
	var a := _econ_action
	_econ_action = ""
	return a


## SHOP (S3-SHOP): a few buyable items (BUY -> run.market_buy). Per-item affordability disables the
## row when !can_afford; multi-buy until scrip runs out; [ LEAVE ] exits. Headless default: _do_shop
## (buy the first REAL stocked item if affordable, else browse). Returns a trace label.
func _run_shop_interactive(car) -> String:
	var bought: Array = []
	_log_hud("> BLACK MARKET — scrip talks. BUY / LEAVE.")
	while true:
		if screens != null:
			screens.show_econ_choices("shop", _shop_spec())
		var act: String = await _await_econ_action()
		if act == "leave":
			break
		if act.begins_with("commit:"):
			var oid := act.substr(7)
			if run.can_afford("scrip", E.MARKET_BUY_SCRIP_COST):
				if run.market_buy(oid):
					_attach_item_to_lead(oid)
					bought.append(oid)
					_log_hud("> bought %s  -%d scrip" % [oid, E.MARKET_BUY_SCRIP_COST])
			# loop re-prices affordability; sold-out/insufficient just re-renders.
	if bought.is_empty():
		return "SHOP: browsed (on-screen, no buy)"
	return "SHOP: bought %s (-%d scrip)" % [", ".join(bought), E.MARKET_BUY_SCRIP_COST * bought.size()]


## The SHOP option spec: the REAL rotating stock (W3-1/W3-2) with live per-item affordability. Each
## row is a genuine ItemDef — its display name, and a one-line consequence pulled from the item data —
## so a purchase carries a usable item into combat (no more phantom field_kit/stim_patch).
func _shop_spec() -> Dictionary:
	var can: bool = run.can_afford("scrip", E.MARKET_BUY_SCRIP_COST)
	var opts: Array = []
	# Consumables/gadgets (W3-1) first, then the rotating WEAPON/ARMOR equipment stock (W3-2). Both
	# buy through the same commit:<id> rail, so a purchased weapon/armor auto-equips onto the lead.
	for iid in _shop_stock() + _shop_equipment_stock():
		var def: Dictionary = db.item(String(iid)) if db != null else {}
		var nm: String = String(def.get("name", iid))
		opts.append({
			"id": String(iid), "label": "[ %s ]" % nm, "cost": "%d scrip" % E.MARKET_BUY_SCRIP_COST,
			"consequence": _item_blurb(def), "affordable": can,
			"delta": "SCRIP %d -> %d" % [_c("scrip"), _c("scrip") - E.MARKET_BUY_SCRIP_COST],
		})
	return {
		"title": "BLACK-MARKET SHOP", "title_col": Pal.CYAN,
		"blurb": "A fence works the aisle. Scrip talks — buy what the road ahead needs.",
		"footer": "ON HAND:  SCR %d   SUP %d   TLS %d" % [_c("scrip"), _c("supplies"), _c("tools")],
		"options": opts, "leave": true,
	}


## A short player-facing one-liner for a shop ItemDef (from its authored data — no hardcoded copy per
## id). Reads the item's first effect kind so the row reads meaningfully even for a new player.
func _item_blurb(def: Dictionary) -> String:
	var slot: String = String(def.get("slot", ""))
	var effs: Array = def.get("effects", [])
	var k: String = String(effs[0].get("kind", "")) if not effs.is_empty() else ""
	# Equipment (weapon/armor) rides into combat as a passive stat/on-hit rider — blurb the payload.
	if slot == "weapon":
		return "+equip: %s weapon (dmg %s)" % [String(def.get("wclass", "melee")), str(def.get("damageBand", []))]
	if slot == "armor":
		return "+equip: armor (%s)" % _effect_tag(effs)
	match k:
		"heal":          return "+heal a wounded comrade"
		"status":        return "+throw: %s cloud" % String(effs[0].get("status", "a status"))
		"spawn_hazard":  return "+throw: seeds %s" % String(effs[0].get("hazard", "a hazard"))
		"pull":          return "+yank a body toward you"
		"deploy_power_source": return "+deploy a power source (electrify a flood)"
		_:               return "+a %s for the road ahead" % (slot if slot != "" else "tool")


## One-line payload tag for an equipment item's first meaningful effect (shop blurb copy only).
func _effect_tag(effs: Array) -> String:
	if effs.is_empty():
		return "protection"
	var e0: Dictionary = effs[0]
	match String(e0.get("kind", "")):
		"stat_mod":     return "+%d %s" % [int(e0.get("amount", 0)), String(e0.get("stat", "stat"))]
		"status_immune": return "immune: %s" % String(e0.get("status", "a status"))
		"shove_resist": return "shove resist"
		"damage_resist": return "%s resist" % String(e0.get("damageType", "damage"))
		_:              return "protection"


## WORKSHOP (S3-WORKSHOP): 2 distinct upgrades (run.workshop_upgrade) — SELECT-to-preview + can't-
## afford disabled; [ LEAVE ]. Headless default: _do_workshop (reinforced_plating if affordable).
func _run_workshop_interactive(car) -> String:
	_log_hud("> WORKSHOP — bolt on what the last car left behind. SELECT / CONFIRM / LEAVE.")
	while true:
		if screens != null:
			screens.show_econ_choices("workshop", _workshop_spec())
		var act: String = await _await_econ_action()
		if act == "leave":
			return "WORKSHOP: no upgrade (on-screen, left)"
		if act.begins_with("commit:"):
			var oid := act.substr(7)
			if run.workshop_upgrade(oid):
				_log_hud("> bolted on %s  -%d scrip" % [oid, E.WORKSHOP_UPGRADE_SCRIP_COST])
				return "WORKSHOP: upgrade %s (-%d scrip)" % [oid, E.WORKSHOP_UPGRADE_SCRIP_COST]
			# spend refused (shouldn't happen — affordability gates the row) — re-render.
	return "WORKSHOP: no upgrade (on-screen, left)"   # unreachable (loop only exits via return) — satisfies the analyzer


func _workshop_spec() -> Dictionary:
	var can: bool = run.can_afford("scrip", E.WORKSHOP_UPGRADE_SCRIP_COST)
	var opts: Array = [
		{"id": "reinforced_plating", "label": "[ REINFORCED PLATING ]", "cost": "%d scrip" % E.WORKSHOP_UPGRADE_SCRIP_COST,
			"consequence": "+armor — soaks a hit at a captain gate", "affordable": can,
			"delta": "SCRIP %d -> %d" % [_c("scrip"), _c("scrip") - E.WORKSHOP_UPGRADE_SCRIP_COST]},
		{"id": "sharpened_edge", "label": "[ SHARPENED EDGE ]", "cost": "%d scrip" % E.WORKSHOP_UPGRADE_SCRIP_COST,
			"consequence": "+knockback on slams — physics-first damage", "affordable": can,
			"delta": "SCRIP %d -> %d" % [_c("scrip"), _c("scrip") - E.WORKSHOP_UPGRADE_SCRIP_COST]},
	]
	return {
		"title": "WORKSHOP / ARMORY", "title_col": Pal.AMBER,
		"blurb": "One permanent upgrade — survivability vs damage. Scrip is scarce; choose for the road.",
		"footer": "ON HAND:  SCR %d" % _c("scrip"),
		"options": opts, "leave": true,
	}


## BOURGEOIS (S3-BOURGEOIS): [ SPARE ] vs [ KILL ] (run.resolve_bourgeois(spare)) with a CONSEQUENCE
## PREVIEW (Order delta + threshold warning + scrip on kill). NO leave — a forced moral fork (both
## are valid exits). Headless default: _do_bourgeois (SPARE).
func _run_bourgeois_interactive(car) -> String:
	_log_hud("> BOURGEOIS LOUNGE — a cornered passenger. The cell watches you. SPARE / KILL.")
	while true:
		if screens != null:
			screens.show_econ_choices("bourgeois", _bourgeois_spec())
		var act: String = await _await_econ_action()
		var label := _apply_bourgeois_action(act)
		if label != "":
			return label
		# W7-11: ESC / the universal leave key does NOT commit the fork — a forced moral choice has no
		# walk-away exit (the pre-fix bug silently picked SPARE). Re-prompt until KILL or SPARE is chosen.
		if act == "leave":
			_log_hud("> the cell is watching — you have to choose. KILL or SPARE.")
	return ""   # unreachable — satisfies the analyzer


## W7-11: resolve ONE bourgeois-fork action. Only an explicit commit:kill / commit:spare resolves it
## (returning the trace label + running the real OrderSystem rail); ANY non-commit ("leave"/ESC, an
## unknown option) returns "" = NOT resolved, so the caller re-prompts rather than auto-committing SPARE.
## RNG-free, deterministic. Shared by the interactive loop; drivable headlessly (no await, no display).
func _apply_bourgeois_action(action: String) -> String:
	if action.begins_with("commit:"):
		var oid := action.substr(7)
		if oid == "kill":
			run.resolve_bourgeois(false)
			_log_hud("> KILLED — +%d scrip, Order %d" % [E.BOURGEOIS_KILL_SCRIP, run.order])
			return "BOURGEOIS: killed (+%d scrip, Order -> %d)" % [E.BOURGEOIS_KILL_SCRIP, run.order]
		elif oid == "spare":
			run.resolve_bourgeois(true)
			_log_hud("> SPARED — Order %d" % run.order)
			return "BOURGEOIS: spared (Order -> %d)" % run.order
	# ESC / leave / an unknown id: the moral fork is NOT resolvable by walking away.
	return ""


func _bourgeois_spec() -> Dictionary:
	var o: int = run.order
	var spare_after: int = max(0, o - E.ORDER_MERCY_DROP)
	var kill_after: int = min(E.ORDER_MAX, o + E.ORDER_CIVILIAN_KILL)
	var opts: Array = [
		{"id": "spare", "label": "[ SPARE ]", "cost": "",
			"consequence": "gear + intel; Order falls — the long game (toward Liberation)",
			"affordable": true, "delta": "ORDER %d -> %d" % [o, spare_after]},
		{"id": "kill", "label": "[ KILL ]", "cost": "+%d scrip" % E.BOURGEOIS_KILL_SCRIP,
			"consequence": "instant scrip; Order rises (toward Pyrrhic)", "affordable": true,
			"accent": Pal.ALERT_RED, "delta": "ORDER %d -> %d   SCRIP %d -> %d" % [
				o, kill_after, _c("scrip"), _c("scrip") + E.BOURGEOIS_KILL_SCRIP],
			"warn": _order_threshold_warn(o, kill_after)},
	]
	return {
		"title": "BOURGEOIS LOUNGE", "title_col": Pal.AMBER,
		"blurb": "A first-class passenger, cornered. A forced choice — both are exits.",
		"footer": "ORDER: %d        active: %s" % [o, str(run.active_order_tags())],
		"options": opts, "leave": false,
	}


## The ALERT_RED threshold-crossing warning for a KILL's Order rise (reinforce/lockdown/elites), or
## "" if no new threshold is crossed. Lets the operator see the difficulty consequence before commit.
func _order_threshold_warn(before: int, after: int) -> String:
	var crossed: Array = []
	for th in [[E.ORDER_THRESHOLD_REINFORCE, "REINFORCEMENTS"], [E.ORDER_THRESHOLD_LOCKDOWN, "LOCKDOWN"], [E.ORDER_THRESHOLD_ELITES, "ELITES"]]:
		if before < int(th[0]) and after >= int(th[0]):
			crossed.append(String(th[1]))
	if crossed.is_empty():
		return ""
	return "! CROSSES: %s" % ", ".join(crossed)


## RECRUIT (S3-RECRUIT): PRE-ROLL the candidate (Recruitment.roll_recruit on a CLONE so the dossier
## shows archetype/traits BEFORE commit) — [ ACCEPT ] / [ DECLINE ]; hard-cap disabled + soft-cap
## warning. Headless default: _do_recruit (ACCEPT, same rec_rng derivation). The pre-roll uses the
## EXACT same seed derivation so the candidate SHOWN is the candidate ACCEPTED (determinism preserved).
func _run_recruit_interactive(car) -> String:
	# PRE-ROLL onto a clone of the squad so the dossier can show the real rolled unit before commit.
	# Same seed derivation as _do_recruit: IntRng(seed ^ (0x5EC0 + position)). On accept we re-roll the
	# SAME stream onto the live squad, so the accepted body is byte-identical to the previewed dossier.
	var preview_rng := IntRng.new((seed ^ (0x5EC0 + run.position)) & 0xFFFFFFFF)
	var clone_squad: Array = run.squad.duplicate()
	var next_id: int = _next_roster_id()
	var pre: Dictionary = Recruitment.roll_recruit(db, preview_rng, clone_squad, next_id)
	_econ_recruit_candidate = pre.get("unit", null)
	var at_hard_cap: bool = run.squad.size() >= E.SQUAD_HARD_CAP or not pre.get("ok", false)
	_log_hud("> SANCTUARY — a sympathetic citizen offers to join. ACCEPT / DECLINE.")
	while true:
		if screens != null:
			screens.show_econ_choices("recruit", _recruit_spec(_econ_recruit_candidate, at_hard_cap))
		var act: String = await _await_econ_action()
		if act == "leave":
			_econ_recruit_candidate = null
			return "RECRUIT: declined (on-screen)"
		if act.begins_with("commit:"):
			var oid := act.substr(7)
			if oid == "accept" and not at_hard_cap:
				# Re-roll the SAME stream onto the live squad — byte-identical to the previewed unit.
				var rec_rng := IntRng.new((seed ^ (0x5EC0 + run.position)) & 0xFFFFFFFF)
				var res := Recruitment.roll_recruit(db, rec_rng, run.squad, _next_roster_id())
				if res.get("ok", false):
					run.input_log.append({"op": "recruit", "pos": run.position})
					_log_hud("> %s joined — squad %d" % [res.unit.name, run.squad.size()])
					_econ_recruit_candidate = null
					return "RECRUIT: %s joined (squad %d)" % [res.unit.name, run.squad.size()]
				return "RECRUIT: declined (squad full)"
			else:
				_econ_recruit_candidate = null
				return "RECRUIT: declined (on-screen)"
	return "RECRUIT: declined (on-screen)"   # unreachable — satisfies the analyzer


func _recruit_spec(cand, at_hard_cap: bool) -> Dictionary:
	var info: Array = []
	if cand != null:
		info.append({"text": "DOSSIER — VETTING", "col": Pal.AMBER, "size": 16})
		info.append({"text": "%s   [%s]" % [String(cand.name), String(cand.archetype_id)], "col": Pal.AMBER})
		info.append({"text": "HP %d/%d   L%d" % [int(cand.hp), int(cand.max_hp), int(cand.level)], "col": Pal.CYAN})
		var shown: Array = cand.revealed_traits if not cand.revealed_traits.is_empty() else cand.traits
		if shown.is_empty():
			info.append({"text": "TRAITS: none noted", "col": Pal.DIM})
		else:
			for tid in shown:
				var td: Dictionary = db.trait_def(String(tid))
				if td.is_empty() or td.get("hidden", false):
					continue   # the hidden betrayer is NEVER surfaced here (Recruitment payload note)
				var pol := String(td.get("polarity", "positive"))
				var col := Pal.CYAN
				match pol:
					"negative": col = Pal.ALERT_RED
					"mixed": col = Pal.AMBER
				info.append({"text": "  • %s" % String(td.get("name", tid)), "col": col})
		info.append({"text": "(trust is textured — vetting shows only what they reveal)", "col": Pal.DIM, "size": 12})
	else:
		info.append({"text": "(no volunteer answered the comms)", "col": Pal.DIM})
	var soft_warn := "tight quarters — squad at soft cap" if run.squad.size() >= E.SQUAD_SOFT_CAP and not at_hard_cap else ""
	var accept_label := "[ ACCEPT ]" if not at_hard_cap else "[ ACCEPT ]  cell full %d/%d" % [run.squad.size(), E.SQUAD_HARD_CAP]
	var opts: Array = [
		{"id": "accept", "label": accept_label, "cost": "",
			"consequence": "fills a slot; +Liberation progress", "affordable": not at_hard_cap,
			"delta": ("SQUAD %d -> %d" % [run.squad.size(), run.squad.size() + 1] if not at_hard_cap else ""),
			"warn": (("! " + soft_warn) if soft_warn != "" else "")},
		{"id": "decline", "label": "[ DECLINE ]", "cost": "",
			"consequence": "keep the cell tight", "affordable": true},
	]
	return {
		"title": "SANCTUARY — RECRUIT", "title_col": Pal.CYAN,
		"blurb": "A citizen offers to join the uprising. Vet the dossier, then choose.",
		"footer": "SQUAD: %d / %d" % [run.squad.size(), E.SQUAD_HARD_CAP],
		"info_lines": info, "options": opts, "leave": true,
	}


## EVENT (S3-EVENT): 2-3 text options wired to earn/spend/apply_order with a deterministic seeded
## outcome (seed ^ (0x5EC0 + position) style). Authors 3 simple templates selected deterministically
## by the seed. Headless default: _do_event (the SAFE outcome, +1 tools, unchanged).
func _run_event_interactive(car) -> String:
	var tmpl := _event_template()
	_log_hud("> EVENT — %s" % String(tmpl.get("prompt", "the corridor forks.")))
	while true:
		if screens != null:
			screens.show_econ_choices("event", _event_spec(tmpl))
		var act: String = await _await_econ_action()
		if act == "leave":
			# Leaving an event defaults to the SAFE outcome (the byte-stable headless default).
			run.earn("tools", 1)
			return "EVENT: took the safe option (+1 tools)"
		if act.begins_with("commit:"):
			var oid := act.substr(7)
			return _apply_event_option(tmpl, oid)
	return "EVENT: took the safe option (+1 tools)"   # unreachable — satisfies the analyzer


## W3-8: DATA-DRIVEN event beat. Reads the CURRENT car's authored `eventBeat` block from
## content/cars/<template_id>.json — a prompt + a list of options, each with a distinct OUTCOME
## (resource / trait_gain / shortcut / ambush) and payload. This replaces the 3 hardcoded identical-
## payload prompts. Falls back to a minimal resource beat if the car declares no options block.
func _event_template() -> Dictionary:
	var car = run.current_car()
	if car != null:
		var data = _read_json(CARS_DIR + car.template_id + ".json")
		if data != null and data is Dictionary:
			var eb = data.get("eventBeat", {})
			if eb is Dictionary and eb.has("options") and not (eb.get("options", []) as Array).is_empty():
				return eb
	# Fallback beat for an event car that authored no options block: a safe scavenge vs a louder grab.
	return {
		"prompt": "A quiet maintenance junction — a jammed hatch, and a choice.",
		"options": [
			{"id": "safe", "label": "[ SCAVENGE QUIETLY ]", "outcome": "resource", "kind": "tools", "amount": 1, "consequence": "+1 tools, no risk"},
			{"id": "risk", "label": "[ FORCE THE HATCH ]", "outcome": "resource", "kind": "scrip", "amount": 8, "order": "loud_breach", "consequence": "a scrip cache — but it goes loud (Order rises)"},
		],
	}


func _event_spec(tmpl: Dictionary) -> Dictionary:
	var opts: Array = []
	for o in tmpl.get("options", []):
		opts.append({
			"id": String(o.get("id", "")), "label": String(o.get("label", "")),
			"cost": "", "consequence": String(o.get("consequence", "")), "affordable": true,
			"delta": _event_option_delta(o),
			"warn": _event_option_warn(o),
		})
	return {
		"title": "EVENT", "title_col": Pal.CYAN,
		"blurb": String(tmpl.get("prompt", "")),
		"footer": "TOOLS: %d   SCRIP: %d" % [_c("tools"), _c("scrip")],
		"options": opts, "leave": true,
	}


## W3-8: the on-screen DELTA chip for an event option, derived from its OUTCOME (so the player sees the
## distinct payload before committing). RNG-free, pure.
func _event_option_delta(o: Dictionary) -> String:
	match String(o.get("outcome", "resource")):
		"resource":   return "+%d %s" % [int(o.get("amount", 1)), String(o.get("kind", "tools"))]
		"trait_gain": return "+trait %s" % String(o.get("trait", ""))
		"shortcut":   return "skip a car"
		"ambush":     return "! spawns a fight"
		_:            return ""


func _event_option_warn(o: Dictionary) -> String:
	if String(o.get("outcome", "")) == "ambush":
		return "! it may be a trap"
	if o.has("order") and String(o.get("order", "")) in ["loud_breach", "cruelty", "civilian_kill"]:
		return "! raises Order"
	return ""


## W3-8: resolve a chosen event option by its authored OUTCOME. Deterministic + RNG-FREE — each option's
## payload is fixed DATA, so the headless resolve path is byte-stable (no seeded coin-flip anymore):
##   resource   — earn currency (+ an optional Order cause)
##   trait_gain — graft a real trait onto a squad member (rides into future combat bodies)
##   shortcut   — bypass the next car (run.skip_next_car — traversal)
##   ambush     — inject a combat car the cell must then fight (run.inject_combat_after_current)
## Returns a trace label. An unknown / missing option falls back to the safe +1 tools default.
func _apply_event_option(tmpl: Dictionary, oid: String) -> String:
	var opt := _find_event_option(tmpl, oid)
	if opt.is_empty():
		run.earn("tools", 1)
		return "EVENT: took the safe option (+1 tools)"
	match String(opt.get("outcome", "resource")):
		"trait_gain":
			var tid := String(opt.get("trait", ""))
			var who := _grant_event_trait(tid)
			_log_hud("> a survivor drills the cell — %s gains %s" % [who, tid])
			return "EVENT: trait_gain (%s -> %s)" % [tid, who]
		"shortcut":
			var skipped := run.skip_next_car()
			_log_hud("> a maintenance tunnel — the cell slips past a car")
			return "EVENT: shortcut (skipped %s)" % (skipped if skipped != "" else "nothing")
		"ambush":
			var amb := String(opt.get("ambush", "combat_security_01"))
			run.inject_combat_after_current(amb)
			_log_hud("> AMBUSH — it was a trap. Guards close in.")
			return "EVENT: ambush (routed to combat %s)" % amb
		_:
			var kind := String(opt.get("kind", "tools"))
			var amount := int(opt.get("amount", 1))
			if kind in ["scrip", "supplies", "tools"]:
				run.earn(kind, amount)
			if opt.has("order"):
				run.apply_order(String(opt["order"]))
			return "EVENT: resource (+%d %s)" % [amount, kind]


## Find an authored event option by id (or {} if none).
func _find_event_option(tmpl: Dictionary, oid: String) -> Dictionary:
	for o in tmpl.get("options", []):
		if o is Dictionary and String(o.get("id", "")) == oid:
			return o
	return {}


## W3-8: graft a granted trait onto the FIRST living squad member (deterministic, stable roster order).
## Adds it to the persistent traits (+ revealed) so it rides into every future combat body via
## UnitInstance.to_sim_entity. No-op if the id is empty, already held, or nobody is alive. Returns the
## recipient name (or "").
func _grant_event_trait(tid: String) -> String:
	if tid == "":
		return ""
	for u in run.squad:
		if u != null and not u.dead:
			if not (tid in u.traits):
				u.traits.append(tid)
				if not (tid in u.revealed_traits):
					u.revealed_traits.append(tid)
			return u.name
	return ""


## REST (S3-REST): the triage list + [ REST ] (run.rest_heal) / [ LEAVE ]; per-unit heal preview;
## can't-afford disabled. Headless default: _do_rest (REST if affordable). Returns a trace label.
func _run_rest_interactive(car) -> String:
	_log_hud("> MED-CAR — patch the wounded, or hoard the supply. REST / LEAVE.")
	while true:
		if screens != null:
			screens.show_econ_choices("rest", _rest_spec())
		var act: String = await _await_econ_action()
		if act == "leave":
			return "REST: hoarded the supply (on-screen, left)"
		if act.begins_with("commit:"):
			if run.rest_heal():
				_log_hud("> patched the cell +%d HP each  -%d supply" % [E.REST_HEAL_AMOUNT, E.REST_HEAL_SUPPLY_COST])
				return "REST: squad healed (-%d supplies)" % E.REST_HEAL_SUPPLY_COST
			# refused (no supplies) — affordability gates the row, so just re-render.
	return "REST: hoarded the supply (on-screen, left)"   # unreachable — satisfies the analyzer


func _rest_spec() -> Dictionary:
	var can: bool = run.can_afford("supplies", E.REST_HEAL_SUPPLY_COST)
	var info: Array = [{"text": "TRIAGE", "col": Pal.AMBER, "size": 16}]
	var any_hurt := false
	for u in run.squad:
		if u == null or u.dead:
			continue
		var ghost: int = min(int(u.max_hp), int(u.hp) + E.REST_HEAL_AMOUNT)
		if u.hp < u.max_hp:
			any_hurt = true
		var nm := "%s%s" % [String(u.name), ("  [DOWNED]" if u.downed else "")]
		info.append({"text": nm, "col": (Pal.ALERT_RED if u.downed else Pal.AMBER), "bar": {"cur": int(u.hp), "max": int(u.max_hp), "ghost": ghost}})
	if info.size() == 1:
		info.append({"text": "(no one left to patch)", "col": Pal.DIM})
	elif not any_hurt:
		info.append({"text": "the cell is already whole — hoard the supply for a captain gate", "col": Pal.DIM, "size": 12})
	var opts: Array = [
		{"id": "rest", "label": "[ REST ]", "cost": "%d supply" % E.REST_HEAL_SUPPLY_COST,
			"consequence": "heal the cell +%d HP each; stand a stabilized comrade" % E.REST_HEAL_AMOUNT,
			"affordable": can, "delta": "SUPPLIES %d -> %d" % [_c("supplies"), _c("supplies") - E.REST_HEAL_SUPPLY_COST]},
	]
	return {
		"title": "MED-CAR — REST", "title_col": Pal.AMBER,
		"blurb": "A moment between cars. Rest still matters before a captain gate (no free regroup there).",
		"footer": "SUPPLIES: %d" % _c("supplies"),
		"info_lines": info, "options": opts, "leave": true,
	}


# --- econ surface signal handlers (record the operator's choice; the async phase consumes it) -----
func _on_choice_select(_screen: String, _option: String) -> void:
	# First-tap preview. The surface already drew the DELTA CHIP from the spec; we re-render on the
	# next loop pass anyway (the spec is live), so nothing to do here beyond a comms whisper.
	pass

func _on_choice_commit(_screen: String, option: String) -> void:
	if _awaiting_econ:
		_econ_action = "commit:%s" % option

func _on_choice_leave(_screen: String) -> void:
	if _awaiting_econ:
		_econ_action = "leave"


# --- ECONOMY TEST SEAM (headless-drivable) -----------------------------------
## VERIFIABLE INTERACTIVE-ECONOMY SEAM (no display). Drive ONE non-combat car's choice from a single
## scripted operator action — the EXACT commit/leave the RunScreens econ surface emits — over the REAL
## RunState rail, WITHOUT a SceneTree. Mirrors drive_draft_scripted. `action` is one of:
##   "commit:<opt>"  (e.g. "commit:kill", "commit:accept", "commit:risk", "commit:rest")
##   "leave"         (resolve with the screen's safe default)
## Returns a small result dict { label, order, scrip, supplies, tools, squad } so a test can assert
## the rail fired (currency/order/squad changed) and the car resolved + advanced. Deterministic — the
## RECRUIT/EVENT rolls use the SAME seed derivation as the live + headless paths.
func drive_screen_scripted(car, action: String) -> Dictionary:
	var label := ""
	match car.car_type:
		E.CarType.SHOP:
			label = _scripted_shop(action)
		E.CarType.UPGRADE:
			label = _scripted_workshop(action)
		E.CarType.BOURGEOIS:
			label = _scripted_bourgeois(action)
		E.CarType.RECRUIT:
			label = _scripted_recruit(action)
		E.CarType.EVENT:
			label = _scripted_event(action)
		E.CarType.REST:
			label = _scripted_rest(action)
		_:
			label = "no-op"
	run.resolve_current()
	return {
		"label": label, "order": run.order,
		"scrip": _c("scrip"), "supplies": _c("supplies"), "tools": _c("tools"),
		"squad": run.squad.size(), "resolved": (car.resolved if car != null else true),
	}


## The scripted-seam bodies share the EXACT rail calls of the interactive phases (no display, no
## await) so the seam proves the same wiring the on-screen surface drives.
func _scripted_shop(action: String) -> String:
	if action.begins_with("commit:") and run.can_afford("scrip", E.MARKET_BUY_SCRIP_COST):
		var oid := action.substr(7)
		if run.market_buy(oid):
			_attach_item_to_lead(oid)
			return "SHOP: bought %s (-%d scrip)" % [oid, E.MARKET_BUY_SCRIP_COST]
	return "SHOP: browsed (on-screen, no buy)"

func _scripted_workshop(action: String) -> String:
	if action.begins_with("commit:"):
		var oid := action.substr(7)
		if run.workshop_upgrade(oid):
			return "WORKSHOP: upgrade %s (-%d scrip)" % [oid, E.WORKSHOP_UPGRADE_SCRIP_COST]
	return "WORKSHOP: no upgrade (on-screen, left)"

func _scripted_bourgeois(action: String) -> String:
	var kill := action == "commit:kill"
	run.resolve_bourgeois(not kill)
	if kill:
		return "BOURGEOIS: killed (+%d scrip, Order -> %d)" % [E.BOURGEOIS_KILL_SCRIP, run.order]
	return "BOURGEOIS: spared (Order -> %d)" % run.order

func _scripted_recruit(action: String) -> String:
	if action == "commit:accept" and run.squad.size() < E.SQUAD_HARD_CAP:
		var rec_rng := IntRng.new((seed ^ (0x5EC0 + run.position)) & 0xFFFFFFFF)
		var res := Recruitment.roll_recruit(db, rec_rng, run.squad, _next_roster_id())
		if res.get("ok", false):
			run.input_log.append({"op": "recruit", "pos": run.position})
			return "RECRUIT: %s joined (squad %d)" % [res.unit.name, run.squad.size()]
	return "RECRUIT: declined (on-screen)"

func _scripted_event(action: String) -> String:
	var tmpl := _event_template()
	if action.begins_with("commit:"):
		return _apply_event_option(tmpl, action.substr(7))
	run.earn("tools", 1)
	return "EVENT: took the safe option (+1 tools)"

func _scripted_rest(action: String) -> String:
	if action.begins_with("commit:") and run.rest_heal():
		return "REST: squad healed (-%d supplies)" % E.REST_HEAL_SUPPLY_COST
	return "REST: hoarded the supply (on-screen, left)"


## Attach a bought shop item to the lead (first living) squad member's inventory so a purchase MEANS
## something on-screen. market_buy only spends + emits; the inventory push is the on-screen UX layer
## (it never touches core's rail). No-op if the squad is empty.
func _attach_item_to_lead(item_id: String) -> void:
	for u in run.squad:
		if u != null and not u.dead:
			u.inventory.append(item_id)
			return


## Currency read shorthand (on-screen specs).
func _c(kind: String) -> int:
	return int(run.currency.get(kind, 0))


# ============================ the finale (Sub-Spec B) =========================
## Run the Engine Vault finale: load the engine car grid (walls + cycling hazards via
## SetpieceLoader), place the drafted squad, build the vault objects from the car JSON's
## `objectives` block, then drive the arena to a sabotaged Core — and resolve the ending.
func _run_finale(car) -> void:
	_log_hud("*** THE ENGINE VAULT ***")
	var data = _read_json(CARS_DIR + car.template_id + ".json")
	if data == null:
		trace.append("FINALE: engine template missing — resolving from run facts")
		_resolve_from_run(false)
		return
	# Build the grid (walls/hazards/cover) and KEEP the JSON's scripted defenders (the antechamber
	# turrets + chief + robot are the Phase-1 fight) — the vault instantiates only the
	# Conductor/relays/dispensers/core itself (the Conductor is deliberately not in enemySpawns).
	state = SetpieceLoader.build(data, seed)
	_strip_starters(state)                    # remove hardcoded starters; scripted enemies survive
	_place_squad(state, _player_spawns(data)) # the DRAFTED squad on the player spawn points
	state.bleedout_enabled = true
	turn = TurnManager.new(state)
	turn.start()
	ai = EnemyAI.new()
	_bind_combat_view()

	var vault := EngineVault.new(state, run.order, run)
	vault.objective.countdown = int(data.get("bridgeCountdown", E.BRIDGE_COUNTDOWN_DEFAULT))
	var pos := _finale_positions(data)
	vault.build(pos.relays, pos.dispensers, pos.core, pos.dais, pos.conductor)
	trace.append("FINALE: vault built — %d relays, %d dispensers, core@%s, conductor@%s"
		% [pos.relays.size(), pos.dispensers.size(), str(pos.core), str(pos.conductor)])

	_drive_finale(vault)
	# the ending was resolved inside _drive_finale (or here as a fallback).
	if ending == -1:
		# W4-6: a 60-round stall with the Core intact resolves from the REAL state, never a bogus win.
		_resolve_from_run(vault.objective.beat_clock(), vault.objective.is_objective_complete(), vault.objective.conductor_captured)


## Drive the finale arena to its conclusion. Each round: on_round_start (countdown/escalate),
## auto-pilot the squad (which sabotages relays/conductor/core via physics+fire as it fights),
## run the Conductor cadence, tick the environment. The vault resolves the ending the instant
## the Core falls (or the squad wipes / the run can no longer progress). Deterministic.
func _drive_finale(vault) -> void:
	var rounds: int = 0
	# Activate the Conductor immediately on entry (crossing into the vault, B2.3) so the
	# countdown runs and the fight is live from round 1.
	var evs: Array = []
	vault.activate_conductor(evs)
	_play(evs)
	while rounds < COMBAT_GUARD_ROUNDS:
		rounds += 1
		# 1. Arena round-start hooks (countdown, escalation, shield/phase sync).
		var rs: Array = []
		vault.on_round_start(rs)
		_play(rs)
		if vault.ending != -1:
			ending = vault.ending
			break
		# 2. Squad acts (auto-pilot): fight robots, break relays, then expose + sabotage the
		#    Core. The auto-pilot fights units; the objective objects (relays/core) are anchored
		#    integrity targets, so we drive the squad's relay-breaking + Core-slam deterministically
		#    here (modeling Saboteur charges + physics slams, B5) so a headless run reliably reaches
		#    the objective. Each round breaks at most one relay (a focused push).
		_play(_auto_player_phase())
		_break_one_relay(vault)
		_try_sabotage(vault)
		if vault.ending != -1:
			ending = vault.ending
			break
		# 3. PLAYER -> ENEMY, the Conductor cadence, standard enemy AI for robots.
		_play(turn.advance_phase())
		var cev: Array = []
		vault.run_conductor_phase(cev)
		_play(cev)
		_play(ai.take_phase(turn))
		# 4. ENEMY -> ENVIRONMENT (hazards + bleed-out) -> PLAYER.
		_play(turn.advance_phase())
		_play(turn.advance_phase())
		_sync_view()
		# Loss check: a full squad wipe ends the finale as a LOSS.
		if _squad_wiped_live(state):
			break
	# If the Core never fell but the squad survived, resolve from the live facts (likely PYRRHIC
	# if the countdown expired). The vault already records `ending` when the Core falls.
	if vault.ending != -1:
		ending = vault.ending
	trace.append("FINALE: rounds=%d core_sabotaged=%s ending=%s"
		% [rounds, str(vault.objective.is_objective_complete()), _ending_name(ending)])


## Break the first still-online Relay this round (the squad focus-firing / slamming it down).
## A Relay is an Anchored integrity object the EngineVault built; reducing its integrity to 0
## and erasing it is the exact end-state the physics resolver produces, so the vault's
## destruction hooks (CONDUCTOR_POWER_DISABLED / RELAY_DISABLED / shield drop) fire on the next
## on_round_start scan. Deterministic. Once all relays are down, expose-via-decapitation is
## already covered (the Core gate opens on relays==0).
func _break_one_relay(vault) -> void:
	for rid in vault.objective.relay_ids:
		var r = state.entities.get(rid)
		if r == null or not r.alive:
			continue
		# Knock it down in one focused round (the squad converging on a single relay).
		if state.in_bounds(r.pos) and state.tile(r.pos).occupant_id == r.id:
			state.tile(r.pos).occupant_id = -1
		r.alive = false
		state.entities.erase(rid)
		return


## When the Core is exposed (all relays down OR the Conductor gone), apply a deterministic
## sabotage hit so the objective is reliably reachable headlessly (models a Saboteur charge
## or a physics slam into the Core, B5). No-op while the Core is still shielded.
func _try_sabotage(vault) -> void:
	if vault.objective.is_objective_complete():
		return
	if not vault.objective.core_exposed(state):
		return
	var ev: Array = []
	vault.sabotage_core(E.SABOTAGE_CHARGE_DAMAGE, ev)
	_play(ev)
	if vault.ending != -1:
		ending = vault.ending


# ============================ car building helpers ============================
## Build a combat car's SimState via the engine-side SetpieceLoader (honors E1 fields), then
## strip its hardcoded starter pair and place the DRAFTED squad on the player spawn points.
func _build_car_state(car):
	var data = _read_json(CARS_DIR + car.template_id + ".json")
	if data == null:
		return null
	var s = SetpieceLoader.build(data, seed)
	if s == null:
		return null
	_strip_starters(s)                          # remove the loader's placeholder bruiser+marksman
	_place_squad(s, _player_spawns(data), _forced_deployment)   # DEPLOY pick (or auto-pick top-3)
	# Apply the car's rolled modifiers so recon foreknowledge is honest (GDD §8.2). Seed is
	# derived from (run seed, line position) so a fixed run reproduces identical placements;
	# ModifierSystem uses its own local IntRng and never touches the to-hit stream.
	if car.modifiers != null and not car.modifiers.is_empty():
		ModifierSystem.apply(s, car.modifiers, data, (seed ^ (run.position * 0x9E3779B1)) & 0xFFFFFFFF)
	return s


## Remove the loader's hardcoded PLAYER starter pair (keeps scripted ENEMIES + objects).
func _strip_starters(s) -> void:
	for id in s.entity_ids_sorted():
		var e = s.entities.get(id)
		if e != null and e.is_unit and e.faction == E.Faction.PLAYER:
			_erase_entity(s, e)


## Remove ALL units (player starters + scripted enemies). NO LONGER used by the finale paths —
## they keep the JSON's scripted defenders (_strip_starters) so the antechamber turret fire is
## real; the EngineVault adds only the Conductor/relays/dispensers/core. Kept as a test utility.
func _strip_units(s) -> void:
	for id in s.entity_ids_sorted():
		var e = s.entities.get(id)
		if e != null and e.is_unit:
			_erase_entity(s, e)


func _erase_entity(s, e) -> void:
	if s.in_bounds(e.pos) and s.tile(e.pos).occupant_id == e.id:
		s.tile(e.pos).occupant_id = -1
	s.entities.erase(e.id)


## Place the DEPLOYED squad members (Array[UnitInstance]) as combat SimEntities on the player
## spawn points (usually 3). `chosen_ids` is the operator's DEPLOY pick (instance ids) — empty
## means the deterministic auto-pick (see _deploy_order). Carries persistent hp/down/dead. When the
## living cell fits the tiles this is byte-identical to the pre-picker behavior (roster order).
func _place_squad(s, spawns: Array, chosen_ids: Array = []) -> void:
	var i: int = 0
	for u in _deploy_order(spawns.size(), chosen_ids):
		if i >= spawns.size():
			break
		var sp = spawns[i]
		var pos := Vector2i(int(sp.get("x", 0)), int(sp.get("y", 0)))
		if not s.in_bounds(pos) or s.occupant_at(pos) != null:
			# find the next open spawn
			var placed := false
			for sp2 in spawns:
				var p2 := Vector2i(int(sp2.get("x", 0)), int(sp2.get("y", 0)))
				if s.in_bounds(p2) and s.occupant_at(p2) == null:
					pos = p2
					placed = true
					break
			if not placed:
				continue
		var body = u.to_sim_entity(db, pos)
		_apply_upgrades_to_body(body)   # W3-3: purchased Workshop upgrades land on the real body
		s.add_entity(body)
		i += 1


## W3-3: apply every purchased Workshop/Armory upgrade (run.upgrades) to a combat body at build time.
## Previously run.upgrades was written by workshop_upgrade() but READ by nothing — the two effect
## constants had zero consumers, so both 6-scrip purchases were placebos. reinforced_plating raises
## the body's max HP (and current, clamped); sharpened_edge adds slam/shove force (the same field
## traits like Brawler feed). Applied BEFORE add_entity so the ceiling is set before the spawn stamp.
## Runs for the drafted squad on EVERY car (combat + finale). Empty upgrades = byte-identical no-op.
func _apply_upgrades_to_body(body) -> void:
	if run == null or body == null:
		return
	for uid in run.upgrades:
		match String(uid):
			"reinforced_plating":
				body.max_hp += E.WORKSHOP_PLATING_HP
				body.hp = min(body.hp + E.WORKSHOP_PLATING_HP, body.max_hp)
			"sharpened_edge":
				body.slam_force_bonus += E.WORKSHOP_EDGE_FORCE


## Order which living squad members deploy onto the `n_spawns` player tiles. `chosen_ids` (the
## operator's DEPLOY pick, or a seam) deploys EXACTLY those living members in roster order. EMPTY
## chosen_ids keeps the pre-picker behavior — living members in ROSTER ORDER, first N — so the pure
## headless auto-pilot / balance path stays BYTE-IDENTICAL (the DEPLOY picker + its best-N default
## is an on-screen affordance; it always sets an explicit chosen_ids, so the deterministic-but-
## different top-N selection only ever affects a run the operator is actually watching). Placement
## is always roster order among the chosen set for byte-stable tile assignment.
func _deploy_order(n_spawns: int, chosen_ids: Array) -> Array:
	# W6-3: an EMPTY pick (the headless / AUTO deploy default) now resolves to the deterministic
	# BEST-N by health/level/role rank (_auto_deploy_ids) instead of the old roster-first-N — so a
	# wounded or low-level front unit no longer deploys over a healthier recruit sitting behind it in
	# the roster. Balance-shifting: it changes the cell the headless bot fields WHENEVER the living
	# squad outnumbers the spawn tiles (BalanceGate). Byte-identical when the living cell fits the
	# tiles (best-N == everyone, same roster order) — the common combat-test case.
	var pick: Array = chosen_ids
	if pick.is_empty():
		pick = _auto_deploy_ids(n_spawns)
	var out: Array = []
	for u in run.squad:
		if u == null or u.dead:
			continue
		if not pick.is_empty() and not (int(u.id) in pick):
			continue
		out.append(u)
		if out.size() >= n_spawns:
			break
	return out


## The DEPLOY picker's SENSIBLE DEFAULT (combat-ux #6 / balance-ai #6): the best `n` living members
## by a STABLE deterministic rank — HP desc, then level desc, then roster index — so a fresh recruit
## never sits behind a 2-HP starter. Returned as instance ids in ROSTER ORDER (byte-stable tiles).
## This is the picker's pre-selection + the deploy_pick_scripted seam's resolution for an empty pick;
## it is NOT the headless placement default (that stays roster-first-N — see _deploy_order).
func _auto_deploy_ids(n: int) -> Array:
	var living: Array = []       # [{u, idx}] in roster order
	var idx: int = 0
	for u in run.squad:
		if u != null and not u.dead:
			living.append({"u": u, "idx": idx})
		idx += 1
	if living.size() <= n:
		var all_ids: Array = []
		for rec in living:
			all_ids.append(int(rec.u.id))
		return all_ids
	var ranked: Array = living.duplicate()
	ranked.sort_custom(Callable(self, "_deploy_rank_cmp"))
	var top: Dictionary = {}
	for k in range(min(n, ranked.size())):
		top[int(ranked[k].u.id)] = true
	var ids: Array = []          # roster order among the chosen
	for rec in living:
		if top.has(int(rec.u.id)):
			ids.append(int(rec.u.id))
	return ids


## Stable deploy rank: higher HP first; tie -> higher level; tie -> lower roster index.
func _deploy_rank_cmp(a: Dictionary, b: Dictionary) -> bool:
	if int(a.u.hp) != int(b.u.hp):
		return int(a.u.hp) > int(b.u.hp)
	if int(a.u.level) != int(b.u.level):
		return int(a.u.level) > int(b.u.level)
	return int(a.idx) < int(b.idx)


## Headless/test seam for the DEPLOY picker (mirrors drive_screen_scripted): force the deployment
## for the NEXT built car. A non-empty `chosen_ids` deploys exactly those living ids; an EMPTY list
## resolves to the deterministic best-N default (what the picker pre-selects). Stores the resolved
## explicit list on _forced_deployment and returns it (instance ids) so a suite can assert the pick.
func deploy_pick_scripted(chosen_ids: Array, n_spawns: int = 3) -> Array:
	var resolved: Array
	if chosen_ids.is_empty():
		resolved = _auto_deploy_ids(n_spawns)
	else:
		resolved = []
		for u in _deploy_order(n_spawns, chosen_ids):
			resolved.append(int(u.id))
	_forced_deployment = resolved.duplicate()
	return resolved


# ============================ interactive DEPLOY picker (S3.5) =================
## Before a combat car with MORE living squad than spawn tiles, let the operator pick who deploys
## (combat-ux #6). Defaults to the deterministic auto-pick (top-N by rank); the operator can retoggle.
## When the cell already fits the tiles this returns immediately (no picker, auto-pick == everyone).
## On-screen-only + not-sim (the byte-stable headless/AUTO path uses the auto-pick default directly).
func _run_deploy_interactive(car) -> void:
	_forced_deployment = []
	_deploy_members = []
	for u in run.squad:
		if u != null and not u.dead:
			_deploy_members.append(u)
	var n: int = 3
	var data = _read_json(CARS_DIR + car.template_id + ".json")
	if data != null:
		n = max(1, _player_spawns(data).size())
	if _deploy_members.size() <= n or screens == null:
		return   # everyone fits — no benching, no picker
	_deploy_need = n
	# Seed the selection with the deterministic best-N auto-pick (the "sensible default").
	_deploy_selected = _auto_deploy_ids(n)
	_awaiting_deploy = true
	_deploy_action = ""
	_present_deploy()
	_onscreen_log("DEPLOY — pick %d of %d for %s" % [n, _deploy_members.size(), (car.name if car.name != "" else car.template_id)])
	var spins: int = 0
	while _awaiting_deploy:
		if _deploy_action == "commit":
			break
		await get_tree().process_frame
		spins += 1
		if spins > 200000:
			break
	_awaiting_deploy = false
	screens.hide_deploy_picker()
	_forced_deployment = _deploy_selected.duplicate()


## Re-render the DEPLOY picker from the current selection set.
func _present_deploy() -> void:
	if screens == null:
		return
	var members: Array = []
	for u in _deploy_members:
		members.append({
			"id": int(u.id),
			"label": "%s [%s]" % [u.name, u.archetype_id],
			"detail": "LV %d" % int(u.level),
			"hp": int(u.hp), "max_hp": int(u.max_hp),
			"selected": int(u.id) in _deploy_selected,
		})
	screens.show_deploy_picker({"members": members, "need": _deploy_need})


## Tap a member row: toggle it in/out of the deployment (capped at `need`).
func _on_deploy_toggle(instance_id: int) -> void:
	if not _awaiting_deploy:
		return
	if instance_id in _deploy_selected:
		_deploy_selected.erase(instance_id)
	elif _deploy_selected.size() < _deploy_need:
		_deploy_selected.append(instance_id)
	else:
		if hud != null:
			hud.set_hint("CELL FULL — bench someone before deploying another")
		return
	_present_deploy()


## COMMIT the deployment (enabled only at exactly `need` selected).
func _on_deploy_commit() -> void:
	if _awaiting_deploy and _deploy_selected.size() == _deploy_need:
		_deploy_action = "commit"


## Keyboard control for the DEPLOY picker: 1-9 toggle a member row (1-based), ENTER/SPACE = DEPLOY
## (when exactly `need` selected), ESC = accept the current pick (falling back to the auto-pick).
func _deploy_key(keycode: int) -> void:
	if not _awaiting_deploy:
		return
	if keycode >= KEY_1 and keycode <= KEY_9:
		var idx: int = keycode - KEY_1
		if idx < _deploy_members.size():
			_on_deploy_toggle(int(_deploy_members[idx].id))
	elif keycode == KEY_ENTER or keycode == KEY_KP_ENTER or keycode == KEY_SPACE:
		_on_deploy_commit()
	elif keycode == KEY_ESCAPE:
		if _deploy_selected.size() != _deploy_need:
			_deploy_selected = _auto_deploy_ids(_deploy_need)   # safe default: the best-N auto-pick
		_deploy_action = "commit"


## Write each living combat body's hp/down/dead back into the persistent UnitInstance.
func _absorb_squad(s) -> void:
	for u in run.squad:
		if u == null:
			continue
		var body = _find_body_for(s, u.id)
		if body != null:
			u.absorb(body)
		elif not u.dead:
			# The body is gone from state (permadeath erased it) — mark the unit dead.
			# (A surviving unit always keeps a body; only permadeath erases one.)
			if _was_permadead(s, u.id):
				u.dead = true
				u.hp = 0


func _find_body_for(s, instance_id: int):
	for id in s.entity_ids_sorted():
		var e = s.entities.get(id)
		if e != null and e.is_unit and e.instance_id == instance_id:
			return e
	return null


func _was_permadead(s, instance_id: int) -> bool:
	for m in s.memorial:
		if int(m.get("instance_id", -1)) == instance_id:
			return true
	return false


# ============================ finale position parsing =========================
## Parse the engine car JSON's `layout.objectives` block into the positions EngineVault.build
## needs. Falls back to the spec's authored coordinates if a role is missing.
func _finale_positions(data: Dictionary) -> Dictionary:
	var relays: Array = []
	var dispensers: Array = []
	var core := Vector2i(17, 6)
	var dais := Vector2i(12, 6)
	var conductor := Vector2i(12, 6)
	var layout: Dictionary = data.get("layout", {})
	for o in layout.get("objectives", []):
		var p := Vector2i(int(o.get("x", 0)), int(o.get("y", 0)))
		var obj := String(o.get("object", ""))
		match obj:
			"relay": relays.append(p)
			"robot_dispenser": dispensers.append(p)
			"engine_core": core = p
			"control_dais": dais = p
	# Conductor from the conductor spawn point (or the dais).
	var cps: Array = layout.get("spawnPoints", {}).get("conductor", [])
	if not cps.is_empty():
		conductor = Vector2i(int(cps[0].get("x", dais.x)), int(cps[0].get("y", dais.y)))
	else:
		conductor = dais
	if relays.is_empty():
		relays = [Vector2i(12, 1), Vector2i(16, 1), Vector2i(16, 10)]
	if dispensers.is_empty():
		dispensers = [Vector2i(13, 10), Vector2i(18, 5)]
	return {"relays": relays, "dispensers": dispensers, "core": core, "dais": dais, "conductor": conductor}


func _player_spawns(data: Dictionary) -> Array:
	return data.get("layout", {}).get("spawnPoints", {}).get("player", [])


## W4-2 — the inner-vault divider column: the antechamber-divider wall's x + 1 (the first inner-vault
## tile). A living player at/past this x has crossed into the vault (waking the dormant Conductor).
## Falls back to just inside the leftmost objective column, else a sane default.
func _finale_divider_from(data: Dictionary) -> int:
	var layout: Dictionary = data.get("layout", {})
	for w in layout.get("walls", []):
		if String(w.get("note", "")).findn("divider") != -1:
			return int(w.get("x", 7)) + 1
	var min_obj_x: int = 1 << 30
	for o in layout.get("objectives", []):
		min_obj_x = min(min_obj_x, int(o.get("x", min_obj_x)))
	return (min_obj_x - 1) if min_obj_x < (1 << 30) else 8


# ============================ endings =========================================
## Resolve the ending from the current run facts. `core_sabotaged` / `conductor_captured` are the REAL
## objective state when the finale hands them in; they DEFAULT to the legacy behavior for the non-finale
## defensive callers (a line that completed with a living squad). W4-6: a finale that STALLS out (60-round
## guard, squad alive, Core never sabotaged) must pass core_sabotaged=false here, or the endings resolver
## reads a live-but-stalled squad as core_sabotaged=(not wiped)=true and hands out a bogus VICTORY.
func _resolve_from_run(beat_clock: bool, core_sabotaged = null, conductor_captured: bool = false) -> void:
	if ending != -1:
		return
	var wiped := _squad_all_dead()
	var sabotaged: bool = (not wiped) if core_sabotaged == null else bool(core_sabotaged)
	var facts := FinaleEndings.build_facts(run, beat_clock, sabotaged, conductor_captured, wiped)
	var ev: Array = []
	ending = FinaleEndings.resolve_and_emit(facts, ev)
	_play(ev)
	trace.append("ENDING: %s (from run facts)" % _ending_name(ending))
	_show_ending()


## W7-10: `cause` distinguishes a genuine wipe from a guard-scrub (the 60-round cap tripping on a
## still-standing cell). The default "wipe" reproduces the exact prior trace/copy byte-for-byte; a
## "stall" reports the REAL cause instead of the old silent "squad wiped" lie.
func _resolve_loss(cause := "wipe") -> void:
	ending = E.EndingId.LOSS
	var reason := _loss_reason_copy(cause)
	trace.append("ENDING: LOSS (%s)" % reason)
	if cause == "stall":
		_log_hud("*** OPERATION SCRUBBED — %s ***" % reason)
	_show_ending()


## W7-10: honest end-of-fight loss copy. A guard-scrub is NOT a wipe — saying "squad wiped" was a lie.
func _loss_reason_copy(cause: String) -> String:
	if cause == "stall":
		return "the fight ran past the %d-round limit — the operation was scrubbed" % COMBAT_GUARD_ROUNDS
	return "squad wiped on the line"


## W7-10: an approaching-guard warning for the MANUAL loop; "" outside the warning window. Non-empty at
## a handful of discrete rounds-remaining marks (COMBAT_GUARD_WARN_AT) so the operator gets a countdown
## toward the cap rather than a silent conversion to LOSS. RNG-free, pure.
func _combat_guard_warning(round_num: int) -> String:
	var left: int = COMBAT_GUARD_ROUNDS - round_num
	if left in COMBAT_GUARD_WARN_AT:
		return "the operation is dragging — %d round%s until it is scrubbed. Push for a finish." % [left, ("" if left == 1 else "s")]
	return ""


func _show_ending() -> void:
	_log_hud("*** ENDING: %s ***" % _ending_name(ending))
	_play_music("memorial")   # W6-6: the after-action / memorial score (drop-in .ogg)
	if screens != null:
		screens.show_ending(run, ending, _ending_name(ending))
	# On-screen-only end-of-run state: arm the input exits, freeze the live timers/ticks, and show
	# the actionable prompt. Headless never builds hud/screens (both null) so this is byte-safe.
	if not headless:
		# CLOSE THE ROGUELITE LOOP (S6-2): award meta-currency, enshrine the fallen, bump stats and
		# PERSIST the profile — exactly ONCE, on win OR loss. Gated behind `not headless` so the
		# byte-stable smoke suites (which drive drive_full_run directly) never award currency or write
		# a user:// save file. The ledger it builds is revealed on the first ENTER/CLICK (two-step).
		_finalize_run()
		_run_over = true
		_payout_shown = false
		if hud != null:
			hud.set_running(false)   # freeze the "● REC" timecode (FEED ENDED)
			hud.set_actions_enabled(false)
			hud.set_hint("[ ENTER / CLICK ] after-action ledger   ·   [ N ] new run")
		if screens != null:
			screens.set_ending_prompt("[ ENTER / CLICK ] after-action ledger   ·   [ N ] new run")


# ============================ PAYOUT / FINALIZE (S6-2; the loop-closer) =======
## Run-end reconciliation — the roguelite loop-closer. NOT-HEADLESS ONLY (the smoke suites drive
## drive_full_run directly and must NEVER award currency or write a user:// save file). Runs exactly
## once per resolved run, on WIN OR LOSS: loads the persistent MetaProfile, awards meta-currency
## (Unlocks.award_meta_currency — scaled by run.draft_payout_mult), enshrines the run's fallen into
## the profile Memorial (Legacy.harvest_run), bumps best_ending, then PERSISTS the profile ONCE
## (SaveSystem.save_profile) and clears the finished mid-run save (SaveSystem.clear_run). Stashes the
## resulting after-action ledger in _payout_ledger for the S6-2 reveal. Gated on `not headless` — NOT
## on sim_mode — so it runs for both a manual run AND an on-screen AUTO/--sim run (both are real player
## runs); the headless _show_ending path skips it entirely (byte-stable, no save side-effect).
func _finalize_run() -> void:
	if headless:
		return
	var profile = SaveSystem.load_profile()   # the canonical on-disk profile (fresh if none)
	var won: bool = (ending != E.EndingId.LOSS and ending != -1)
	# The shared award+enshrine+stats logic (also exercised headlessly by finalize_run_scripted, which
	# never touches disk). Returns the after-action ledger for the reveal.
	_payout_ledger = _apply_finalize(profile, run, ending, won)
	# Persist ONCE — the single disk write of the whole end-of-run path. Then clear the finished
	# mid-run save so CONTINUE no longer offers a resolved run.
	SaveSystem.save_profile(profile)
	SaveSystem.clear_run()
	trace.append("FINALIZE: award=+%d meta=%d fallen+%d won=%s (persisted)" % [
		int(_payout_ledger.get("award", 0)), int(_payout_ledger.get("total", 0)),
		int(_payout_ledger.get("fallen", 0)), str(won)])


## The PURE reconciliation core (NO disk I/O): award meta-currency, enshrine the run's fallen, bump
## best_ending — mutating `profile` in place — and return the after-action LEDGER dict the S6-2 reveal
## renders. Shared by the live _finalize_run (which then persists) AND the headless finalize_run_scripted
## test seam (which drives an in-memory profile and never persists). Uses the REAL meta API end-to-end
## (Unlocks.award_meta_currency / Legacy.harvest_run) — it does not re-implement award/enshrine.
func _apply_finalize(profile, run_state, ending_id: int, won: bool) -> Dictionary:
	# Award FIRST (also bumps profile.stats runs/wins) — the real rail, scaled by draft_payout_mult.
	var award: int = Unlocks.award_meta_currency(profile, run_state, won)
	# Enshrine every fallen hero on the run into the persistent Memorial (the real Legacy rail).
	var enshrined: int = Legacy.harvest_run(profile, run_state)
	# Track the best ending reached (higher EndingId = a stronger/kinder win; LOSS=0 floor).
	var prev_best: int = int(profile.stats.get("best_ending", -1))
	if ending_id > prev_best:
		profile.stats["best_ending"] = ending_id
	# Build the after-action ledger (presentation facts; mirrors Unlocks.award_meta_currency's math).
	var cleared: int = 0
	for c in run_state.line:
		if c != null and ("resolved" in c) and c.resolved:
			cleared += 1
	var survivors: int = 0
	var squad_size: int = 0
	for u in run_state.squad:
		if u == null:
			continue
		squad_size += 1
		if not u.dead:
			survivors += 1
	var base: int = Unlocks.PAYOUT_WIN_BASE if won else Unlocks.PAYOUT_LOSS_BASE
	# W7-2: append this run to the persistent RUN LOG so the menu RUN HISTORY panel is populated in
	# LIVE play (pure append — does not touch runs/wins/best_ending, so no double-count with the award
	# above). Both the live _finalize_run and the headless finalize_run_scripted seam route here.
	profile.record_run(ending_id, won, cleared, survivors, squad_size, int(run_state.order))
	return {
		"won": won,
		"verdict": _ending_name(ending_id),
		"survivors": survivors,
		"squad_size": squad_size,
		"order": int(run_state.order),
		"cars": cleared,
		"fallen": enshrined,
		"base": base,
		"per_car": cleared * Unlocks.PAYOUT_PER_CAR,
		"mult": int(run_state.draft_payout_mult),
		"award": award,
		"total": int(profile.meta_currency),
	}


## VERIFIABLE FINALIZE SEAM (no display, NO disk I/O). Drive the run-end reconciliation against an
## IN-MEMORY MetaProfile so a headless test can assert the award (= base x draft mult + per-car),
## the fallen enshrined to the profile Memorial, the stats bump, and a built ledger — WITHOUT a
## SceneTree and WITHOUT writing a user:// save file. Runs the EXACT award+enshrine+stats logic the
## live _finalize_run runs (via _apply_finalize), minus the SaveSystem.save_profile/clear_run calls.
## Returns the after-action ledger. `won` is the caller's verdict (ending != LOSS).
func finalize_run_scripted(profile, run_state, ending_id: int):
	var won: bool = (ending_id != E.EndingId.LOSS and ending_id != -1)
	return _apply_finalize(profile, run_state, ending_id, won)


## S6-1 -> S6-2: advance from the sticky ENDING CARD to the PAYOUT LEDGER (the first ENTER/CLICK while
## _run_over). Renders the after-action ledger the finalize already computed and re-arms the prompt for
## the SECOND ENTER/CLICK (return to console). On-screen-only (never reached headless — _run_over is
## never armed there).
func _advance_to_payout() -> void:
	_payout_shown = true
	if screens != null:
		screens.show_payout(_payout_ledger)
		screens.set_ending_prompt("[ ENTER / CLICK ] return to console   ·   [ N ] new run")
	if hud != null:
		hud.set_hint("[ ENTER / CLICK ] return to console   ·   [ N ] new run")


# ============================ on-screen chrome ================================
func _build_onscreen_chrome() -> void:
	hud = OpsHUD.new()
	add_child(hud)
	# Wire the HUD's interactive buttons to the controller (action -> InputIntent; control -> AUTO/SPEED).
	hud.action_pressed.connect(_on_hud_action)
	hud.control_pressed.connect(_on_hud_control)
	hud.recon_pressed.connect(_on_recon_pressed)   # #11 — recon-row detail + DEEP SCAN affordance
	hud.ability_chosen.connect(_on_ability_chosen) # Batch 6 — the depth-toolkit ability picker
	hud.item_chosen.connect(_on_item_chosen)       # Batch 6 — the consumable/gadget picker
	hud.tip_dismissed.connect(_on_tip_dismissed)   # combat-ux #7 — the onboarding tip banner dismiss
	# Combat onboarding (combat-ux #7): load the persisted profile once and build the pure tip decider
	# from its seen-set + the global tips_enabled switch. On-screen-only — never reached headless (this
	# whole method is gated behind `not headless` at its single call site in _ready).
	_tip_profile = SaveSystem.load_profile()
	_tips = CombatTips.new(_tip_profile.seen_tips, _tip_profile.tips_enabled())
	screens = RunScreens.new()
	add_child(screens)
	# Wire the interactive DRAFT surface signals (S2) -> the live Draft API + breach launch. These
	# only ever fire on-screen (headless never instances RunScreens), so the auto-draft suites are
	# byte-stable. Each handler just records the operator's choice; the async draft phase consumes it.
	screens.draft_take.connect(_on_draft_take)
	screens.draft_decline.connect(_on_draft_decline)
	screens.draft_breach.connect(_on_draft_breach)
	screens.draft_auto.connect(_on_draft_auto)
	screens.breach_go.connect(_on_breach_go)
	screens.breach_back.connect(_on_breach_back)
	# Wire the interactive ECONOMY-CAR surface signals (S3 — SHOP/WORKSHOP/BOURGEOIS/RECRUIT/EVENT/
	# REST). Like the draft, these only ever fire on-screen (headless never instances RunScreens), so
	# the byte-stable auto-default _do_* path is untouched. Each handler records the operator's choice;
	# the async per-car phase consumes it and drives the REAL RunState rail.
	screens.choice_select.connect(_on_choice_select)
	screens.choice_commit.connect(_on_choice_commit)
	screens.choice_leave.connect(_on_choice_leave)
	# Wire the LEVEL-UP overlay signals (S3-LEVELUP; Batch 5). On-screen-only (headless never builds
	# RunScreens), so the byte-stable run loop never raises the overlay or awards XP.
	screens.levelup_select.connect(_on_levelup_select)
	screens.levelup_pick.connect(_on_levelup_pick)
	# Wire the ABANDON-RUN confirm (combat-ux #4). ESC in a run raises the guard instead of nuking it.
	screens.abandon_save_exit.connect(_on_abandon_save_exit)
	screens.abandon_keep.connect(_on_abandon_keep)
	# Wire the DEPLOY picker (combat-ux #6). Raised before a combat car when living squad > spawns.
	screens.deploy_toggle.connect(_on_deploy_toggle)
	screens.deploy_commit.connect(_on_deploy_commit)
	ghost = PreviewGhost.new()
	intent = null   # built per-combat-car when the interactive loop is wired


## HUD control button -> mode/speed toggles.
func _on_hud_control(name: String) -> void:
	match name:
		"AUTO":  _toggle_auto()
		"SPEED": _cycle_speed()
		"SCOPE":
			# W6-2: toggle AUTO between whole-run and this-fight scope, and sync the HUD indicator.
			if _auto_scope == "run":
				_auto_scope = "fight"
			else:
				_set_auto_whole_run()
			if hud != null:
				hud.set_auto_scope(_auto_scope)
		_: pass


func _bind_combat_view() -> void:
	if headless:
		return
	if view != null:
		view.queue_free()
	view = CarView.new()
	view.setup(state, VIEW_SIZE)
	# In-car fog (E1.4): the render consumer only limits the operator's view when THIS car requests fog
	# (per-car inCarFog) AND the operator's session toggle allows it (fog_enabled() ANDs the setting with
	# the E1.4 default). Render-only — the sim/tests never see fog. Owner rule: neither value is mutated
	# here; we only READ the spec-default flags. refresh_fog() re-runs on every sync as the squad moves.
	view.fog_on = _car_requests_fog() and fog_enabled()
	view.refresh_fog()
	view.preview = ghost
	add_child(view)
	if player != null:
		player.queue_free()
	player = EventPlayer.new(view, false)
	player.step_time = ONSCREEN_BEAT
	player.speed_scale = _onscreen_speed
	add_child(player)
	player.comms.connect(func(line): if hud != null: hud.push_comms(line))
	view.glitch(0.5)   # #23 — a one-time glitch-tear on the camera-cut INTO a car (gentle; render-only)


## Build the InputIntent for the CURRENT combat `turn` and wire its signals: a committed action
## plays its events onto the view (and the comms HUD), a preview request drives the PreviewGhost,
## and a rejection logs to comms. This is the SAME abstraction touch/mouse/gamepad all funnel into
## (§17.6) — so a human, or a scripted test (feed_intents), drives the EXACT command path the
## auto-pilot does. Safe headless: the signal handlers no-op the view when there's no display.
func bind_combat_intent() -> void:
	intent = InputIntent.new(turn)
	intent.committed.connect(_on_intent_committed)
	intent.preview_requested.connect(_on_intent_preview)
	intent.preview_cleared.connect(_on_intent_preview_cleared)
	intent.rejected.connect(_on_intent_rejected)


## A rejected intent: log to comms and latch the flag the W1-6 stale-preview guard reads (the
## signal fires synchronously inside point_tile, so _route_tile_tap sees it on the next line).
func _on_intent_rejected(reason) -> void:
	_point_rejected = true
	_log_hud("> REJECTED: %s" % reason)


func _on_intent_committed(events: Array) -> void:
	# A human/scripted commit flows through here exactly like an auto-pilot action: play it onto
	# the view + keep tokens in sync. The events already mutated the authoritative state.
	# Headless (tests): _play no-ops, so this is the instant, synchronous path the suites rely on.
	# On-screen, during the interactive loop, animate the commit + advance to the next actor.
	if not headless and _active_combat and not sim_mode:
		if ghost != null:
			ghost.active = false
		if view != null:
			view.clear_move_preview()   # #22 — a committed action drops any pending move preview
		await _play_anim(events)
		_after_unit_action()
		return
	_play(events)
	_sync_view()


func _on_intent_preview(kind: String, payload: Dictionary) -> void:
	# Drive the deterministic preview ghost (§6.7) for a pending PHYSICS action — preview == commit
	# by construction (resolver clone). Move/shoot previews are handled by the view's own hinting.
	if ghost == null or state == null:
		return
	if kind == "physics" and payload.has("dir"):
		var aid: int = intent.selected_id
		var dir: Vector2i = payload.get("dir", Vector2i.ZERO)
		var force: int = int(payload.get("force", E.SHOVE_FORCE))
		ghost.compute(state, aid, dir, force)
		ghost.active = true
		_sync_view()
		_maybe_tip("preview")   # combat-ux #7 — the first physics ghost teaches preview == outcome
	elif (kind == "ability" or kind == "item") and payload.has("phys"):
		# A physics-flavored ability/item (impulse/throw/pull) previews the DISPLACED body through the
		# same resolver dry-run as SHOVE/SLAM — preview == commit (§6.7). Non-physics abilities/items
		# show no ghost (nothing to displace); their outcome lands on commit like STABILIZE.
		var ph: Dictionary = payload["phys"]
		ghost.compute(state, int(ph.get("id", -1)), ph.get("dir", Vector2i.ZERO), int(ph.get("force", E.SHOVE_FORCE)))
		ghost.active = true
		_sync_view()
		_maybe_tip("preview")   # combat-ux #7 — a physics-flavored ability/item ghost teaches preview too


func _on_intent_preview_cleared() -> void:
	if ghost != null:
		ghost.active = false
	_sync_view()


## PLAYER-INPUT SEAM (verifiable headless). Drive ONE player turn through the bound InputIntent
## from a list of scripted intents, then settle the rest of the round (enemy + environment phases)
## so the turn fully resolves like the auto-pilot path. Each intent is a small dict the UI would
## emit from a tap/click sequence:
##   {op:"select", id:<unit id>}
##   {op:"action", mode:<InputIntent.Mode.*>}          # MOVE / SHOOT / SHOVE / SLAM / THROW
##   {op:"point",  cell:Vector2i}                       # builds + previews the action
##   {op:"confirm"}                                     # commits the previewed action (two-tap)
##   {op:"cancel"} / {op:"undo"} / {op:"end"}           # drop preview / undo move / end the turn
## Returns true if at least one action committed. Used by tests to prove a human resolves a combat
## turn through the controller WITHOUT the auto-pilot.
func play_player_turn(scripted_intents: Array) -> bool:
	if intent == null:
		return false
	var committed_any := false
	for step in scripted_intents:
		match String(step.get("op", "")):
			"select":
				intent.select_unit(int(step.get("id", -1)))
			"action":
				intent.choose_action(int(step.get("mode", InputIntent.Mode.NONE)))
			"ability":
				# Arm a specific ACTIVE ability (Batch 6). `ability` is the resolved AbilityDef; a
				# `self`-targeted ability is prepared on arm, so a following {op:"confirm"} commits it.
				intent.arm_ability(step.get("ability", {}))
			"use_item":
				# Arm a specific combat item (Batch 6). `item` is the resolved ItemDef, `id` the gear id.
				intent.arm_item(step.get("item", {}), String(step.get("id", "")))
			"point":
				intent.point_tile(step.get("cell", Vector2i.ZERO))
			"confirm":
				if intent.confirm():
					committed_any = true
			"cancel":
				intent.cancel()
			"undo":
				intent.undo()
			"end":
				if intent.selected_id >= 0:
					turn.end_unit(intent.selected_id)
			_:
				pass
	return committed_any


## Settle the non-player phases of the current round (PLAYER->ENEMY->ENVIRONMENT->PLAYER) after a
## human/scripted player phase, so the turn advances like the auto-pilot loop. Returns the victory
## code after the round (0 ongoing / 1 win / 2 loss).
func settle_round_after_player() -> int:
	_play(turn.advance_phase())            # PLAYER -> ENEMY
	_play(ai.take_phase(turn))             # enemy phase
	_play(turn.advance_phase())            # ENEMY -> ENVIRONMENT (hazards + bleed-out)
	_play(turn.advance_phase())            # ENVIRONMENT -> PLAYER
	_sync_view()
	return turn.check_victory()


func _bind_screens() -> void:
	pass


# ============================ event playback ==================================
## Apply an event stream to the on-screen view (no-op headless beyond the trace). Keeps the
## visual token table in sync with the authoritative SimState.
func _play(events: Array) -> void:
	if headless or player == null:
		return
	player.play(events)
	_sync_view()


func _sync_view() -> void:
	if headless or view == null:
		return
	view.sync_tokens()
	view.queue_redraw()


# ============================ HUD wiring ======================================
## Push the run's recon strip + currency + Order meter into the OpsHUD (the §8.2/§9/§10 reads).
func _refresh_recon_hud() -> void:
	if hud == null:
		return
	hud.set_order(run.order)
	if hud.has_method("set_currency"):
		hud.set_currency(run.currency)
	if hud.has_method("set_recon"):
		hud.set_recon(run, _car_summaries())
	var car = run.current_car()
	if car != null:
		hud.set_camera_id("CAR %d" % (run.position + 1), car.name if car.name != "" else car.template_id)


## A compact per-car recon summary for the HUD strip (respecting recon_state). Extended (#11) with the
## car's rolled modifiers / threat-contacts / reward so the RECON CARD detail overlay can read them off
## the same summary (no extra plumbing). The threat-contacts list is the car's threat_tags (the same
## data the PARTIAL silhouette shows, surfaced in full on the FULL card). Pure read — no mutation.
func _car_summaries() -> Array:
	var out: Array = []
	for i in range(run.line.size()):
		var c = run.line[i]
		out.append({
			"index": i, "name": (c.name if c.name != "" else c.template_id),
			"type": _type_name(c.car_type), "section": c.section,
			"recon": c.recon_state, "threat": (c.threat_tags[0] if not c.threat_tags.is_empty() else ""),
			"resolved": c.resolved, "current": (i == run.position),
			"modifiers": c.modifiers.duplicate(),
			"enemies": c.threat_tags.duplicate(),
			"reward": c.reward.duplicate(true),
		})
	return out


## #11 — a recon affordance was tapped. "car" opens the RECON CARD detail overlay for that line index
## (a pure read of the stashed summary; the overlay dismisses, no dead end). "deep_scan" spends Tools via
## the REAL RunState.deep_scan rail, then re-renders the strip, logs to comms, and fires a reveal glitch.
## On-screen-only (headless never instances OpsHUD, so recon_pressed never fires there).
func _on_recon_pressed(kind: String, index: int) -> void:
	if hud == null:
		return
	if kind == "car":
		hud.show_recon_card(index)
		return
	if kind == "deep_scan":
		var events: Array = []
		var res: Dictionary = run.deep_scan(events)   # the REAL recon rail — spends Tools, pushes depth
		if bool(res.get("ok", false)):
			var ridx: int = int(res.get("revealedIndex", -1))
			_log_hud("> DEEP SCAN — camera pushed to CAR %d." % (ridx + 1))
			_refresh_recon_hud()                       # re-render the strip with the new FULL window
			if view != null:
				view.glitch(0.7)                       # a render-only reveal glitch (#23 idiom)
		else:
			_log_hud("! DEEP SCAN unavailable — %s." % String(res.get("reason", "no signal")))


func _log_hud(line: String) -> void:
	if hud != null:
		hud.push_comms(line)


# ============================ small helpers ===================================
func _is_headless() -> bool:
	return OS.has_feature("headless") or DisplayServer.get_name() == "headless"


func _squad_all_dead() -> bool:
	for u in run.squad:
		if u != null and not u.dead:
			return false
	return true


func _squad_wiped_live(s) -> bool:
	for id in s.entity_ids_sorted():
		var e = s.entities.get(id)
		if e == null or not e.is_unit or e.faction != E.Faction.PLAYER:
			continue
		if e.alive or (e.downed and not e.dead):
			return false
	return true


func _next_roster_id() -> int:
	var mx: int = 0
	for u in run.squad:
		if u != null:
			mx = max(mx, int(u.id))
	return mx + 1


func _type_name(t: int) -> String:
	for k in E.CAR_TYPE_NAMES.keys():
		if int(E.CAR_TYPE_NAMES[k]) == t:
			return k.to_upper()
	return "?"


func _ending_name(e: int) -> String:
	match e:
		E.EndingId.LOSS: return "LOSS"
		E.EndingId.HARD_STOP: return "HARD STOP"
		E.EndingId.SEIZE_ENGINE: return "SEIZE THE ENGINE"
		E.EndingId.PYRRHIC: return "PYRRHIC VICTORY"
		E.EndingId.LIBERATION: return "LIBERATION"
		_: return "UNRESOLVED"


func _read_json(path: String):
	if not FileAccess.file_exists(path):
		return null
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return null
	var txt := f.get_as_text()
	f.close()
	return JSON.parse_string(txt)
