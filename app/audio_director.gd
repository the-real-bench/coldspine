extends Node
## AUDIO DIRECTOR (release-readiness #4) — the drop-in audio pipeline, the exact analog of the
## texture-manifest ART pipeline (assets/placeholders/MANIFEST.md). It maps GAME EVENT TYPES from
## the committed event stream to NAMED SFX SLOTS, and plays a slot's stream if a real audio file is
## present at the documented path. Add a real .ogg at that path and it Just Works — zero code churn,
## the same file-by-file drop-in contract as final art.
##
## AUTOLOAD (`AudioDirector` in project.godot). Buses: Master -> Music / SFX / UI
## (default_bus_layout.tres). Volume comes from the settings sliders via set_volume().
##
## PUBLIC API:
##   AudioDirector.event_sfx(ev_type: int)   — combat/finale choke point (EventPlayer._apply_animated).
##   AudioDirector.play_sfx(slot: String)    — play a named SFX slot (SFX bus).
##   AudioDirector.play_ui(slot: String)     — play a named UI slot (UI bus): select/confirm/back/buy.
##   AudioDirector.play_music(track: String) — start/loop a music track (Music bus); "" stops music.
##   AudioDirector.set_volume(key, 0..100)   — key "sfx_volume"|"music_volume"|"ui_volume" -> bus dB.
##
## SILENCE CONTRACT (mirrors SessionLog): NEVER prints to stdout, never push_error()s on its own
## behalf, and is a total NO-OP when headless (no display / dummy audio) — so the headless suites
## parse byte-identical stdout and the determinism guards (render_smoke / interactive_smoke) hold.
## Determinism is untouched: audio reads the event stream but writes nothing back to the sim.

const E = preload("res://core/sim_enums.gd")
const SaveSystem = preload("res://core/meta/save_system.gd")   # W6-7: read the persisted volumes at boot

const AUDIO_MAP_PATH := "res://content/audio_map.json"   # slot -> stream path (the drop-in manifest)
const SFX_BUS := "SFX"
const MUSIC_BUS := "Music"
const UI_BUS := "UI"
const SFX_POOL := 8            # concurrent one-shot SFX voices (overlapping shots/impacts)

# Enabled only with a real display+audio server. Headless = total no-op (silent, byte-stable).
var _enabled: bool = false
var _slots: Dictionary = {}                 # slot name -> stream path (from AUDIO_MAP_PATH)
var _stream_cache: Dictionary = {}          # path -> AudioStream (loaded once)
var _sfx_pool: Array = []                   # AudioStreamPlayer ring for one-shot SFX
var _sfx_next: int = 0
var _ui_player: AudioStreamPlayer = null
var _music_player: AudioStreamPlayer = null
var _music_track: String = ""

# ---- EVENT -> SFX SLOT MAP -------------------------------------------------------------------
# The full, TOTAL map from every emitted GameEvent type (core/sim_enums.gd::Ev) to a named SFX slot.
# Commission audio against these slot names; drop the file at content/audio_map.json's path and it
# plays. Events with no distinct audible moment (turn bookkeeping, XP/currency ledger lines, UI-layer
# flow that gets its own play_ui/play_music cue) live in SILENT_EVENTS instead — never a missing key.
# tests/audio_smoke.gd asserts EVERY Ev member is in exactly one of these two sets (fails loud on drift).
const EVENT_SFX := {
	# --- movement / locomotion ---
	E.Ev.MOVE: "step", E.Ev.MOVE_STEP: "step", E.Ev.STAND_UP: "stand",
	E.Ev.BELT_DRIFT: "belt", E.Ev.SLOPE_SLIDE: "slide", E.Ev.DIG_OUT: "dig_out",
	# --- gunfire ---
	E.Ev.ATTACK_SHOOT: "gunshot", E.Ev.HIT: "impact", E.Ev.MISS: "ricochet",
	# --- physics displacement / collision ---
	E.Ev.IMPACT_WALL: "slam", E.Ev.COLLIDE_BODY: "billiards", E.Ev.SHOVE_RESISTED: "shove_resisted",
	E.Ev.TOPPLE: "topple", E.Ev.CRUSH: "crush", E.Ev.EJECT: "eject",
	E.Ev.AVALANCHE: "avalanche", E.Ev.BURY: "bury",
	# --- destructibles ---
	E.Ev.OBJECT_DAMAGED: "crack", E.Ev.OBJECT_BREAK: "shatter",
	# --- flood / electrify chain ---
	E.Ev.FLOOD_TILE: "water", E.Ev.SHOCK: "zap",
	E.Ev.EXTINGUISH: "steam_hiss", E.Ev.DISPERSE: "steam_hiss",
	# --- fire / gas / explosion ---
	E.Ev.IGNITE: "ignite", E.Ev.EXPLOSION: "boom", E.Ev.FIRE_SPREAD: "fire", E.Ev.FIRE_OUT: "fire_out",
	E.Ev.BURN_TICK: "burn", E.Ev.SCALD: "scald",
	E.Ev.GAS_SPREAD: "gas_hiss", E.Ev.GAS_CLEAR: "gas_clear", E.Ev.POISON_TICK: "poison",
	E.Ev.FREEZE: "freeze", E.Ev.THAW: "thaw",
	# --- static hazards ---
	E.Ev.HAZARD_FURNACE: "furnace", E.Ev.HAZARD_RAIL: "rail_zap", E.Ev.HAZARD_PISTON: "piston",
	E.Ev.TRAP_TELEGRAPH: "trap_arm", E.Ev.TRAP_FIRE: "trap_fire", E.Ev.TRAPS_DISABLED: "traps_off",
	E.Ev.EXPOSURE_TICK: "cold_gust",
	# --- overwatch / control ---
	E.Ev.OVERWATCH_SET: "overwatch_set", E.Ev.OVERWATCH_TRIGGER: "overwatch_fire",
	E.Ev.SUPPRESS: "suppress", E.Ev.NET: "net",
	# --- down / death / bleed-out ---
	E.Ev.UNIT_DOWNED: "down", E.Ev.UNIT_DEATH: "death", E.Ev.UNIT_PERMADEATH: "permadeath",
	E.Ev.BLEED_TICK: "bleed", E.Ev.UNIT_STABILIZED: "stabilize", E.Ev.MEMORIAL_ADD: "memorial",
	E.Ev.GEAR_DROP: "gear_drop",
	# --- abilities / support ---
	E.Ev.ABILITY_USE: "ability", E.Ev.HEAL: "heal", E.Ev.GRANT_AP: "grant_ap", E.Ev.CLEANSE: "cleanse",
	E.Ev.ITEM_USED: "item", E.Ev.HACKED: "hacked",
	E.Ev.CHARGE_PLACED: "charge_place", E.Ev.CHARGE_DETONATED: "boom",
	E.Ev.BUFF_APPLY: "buff", E.Ev.BUFF_EXPIRE: "buff_drop",
	E.Ev.STATUS_APPLY: "status_on", E.Ev.STATUS_CLEAR: "status_off",
	# --- spawns / reinforcements ---
	E.Ev.SPAWNED: "spawn", E.Ev.BOT_DEPLOY: "bot_deploy",
	E.Ev.DISPENSER_SPAWN: "dispenser", E.Ev.DISPENSER_DOWN: "dispenser_down",
	E.Ev.RECRUIT_JOIN: "recruit",
	# --- captains / gates / betrayal ---
	E.Ev.CAPTAIN_BUFF: "captain_buff", E.Ev.CAPTAIN_BUFF_DROP: "captain_buff_drop",
	E.Ev.CAPTAIN_SHIELD: "shield_up", E.Ev.CAPTAIN_SHIELD_DROP: "shield_down",
	E.Ev.DAMAGE_SHIELDED: "shield_deflect", E.Ev.BETRAYAL: "betrayal",
	E.Ev.ORDER_THRESHOLD: "order_threshold",
	# --- fog / concealment ---
	E.Ev.FOG_REVEAL: "fog_reveal", E.Ev.CONCEAL_BLOCK: "conceal",
	# --- level-up / progression cues that get an audible sting ---
	E.Ev.LEVEL_UP: "level_up",
	# --- finale (Engine Vault) ---
	E.Ev.VAULT_PHASE: "vault_phase", E.Ev.VAULT_ESCALATE: "vault_escalate",
	E.Ev.RELAY_DISABLED: "relay_down", E.Ev.CONDUCTOR_POWER_DISABLED: "power_down",
	E.Ev.CONDUCTOR_TELEGRAPH: "conductor_tell", E.Ev.CONDUCTOR_ACT: "conductor_act",
	E.Ev.CORE_SHIELD: "shield_up", E.Ev.CORE_SHIELD_DROP: "shield_down",
	E.Ev.CORE_DAMAGED: "core_hit", E.Ev.CORE_SABOTAGED: "core_sabotage",
	E.Ev.COUNTDOWN_TICK: "countdown", E.Ev.COUNTDOWN_EXPIRED: "countdown_end",
	E.Ev.ENDING_RESOLVED: "ending",
	# --- economy stings that land on the feed ---
	E.Ev.REWARD_GRANT: "reward", E.Ev.REST_HEAL: "rest",
	# --- run outcome ---
	E.Ev.RUN_WIN: "car_clear", E.Ev.RUN_COMPLETE: "run_win", E.Ev.RUN_LOSE: "run_lose",
}

# Bookkeeping / ledger / UI-flow events with no distinct combat SFX. They are audibly served (if at
# all) by play_ui() / play_music() cues at their own surfaces, not by the combat choke point.
# Listed EXPLICITLY so the totality test can prove no Ev member was simply forgotten.
const SILENT_EVENTS := [
	E.Ev.TURN_PHASE, E.Ev.XP_GAIN, E.Ev.ABILITY_PICKED,
	E.Ev.DRAFT_OFFER, E.Ev.DRAFT_TAKE, E.Ev.DRAFT_DECLINE, E.Ev.DRAFT_DONE,
	E.Ev.ORDER_CHANGE, E.Ev.RUN_GENERATED, E.Ev.CAR_ENTER, E.Ev.CAR_RESOLVED,
	E.Ev.RUN_ADVANCE, E.Ev.RECON_REVEAL, E.Ev.DEEP_SCAN, E.Ev.CURRENCY_CHANGE,
	E.Ev.SHOP_BUY, E.Ev.WORKSHOP_UPGRADE, E.Ev.MARKET_BUY,
	E.Ev.MOMENTUM_CHANGED,   # Wave 3b: the Firebrand meter ticks silently (loss shares the somber death beat)
]

# Named UI slots (UI bus) — wired at the menu/HUD surfaces via play_ui().
const UI_SLOTS := ["select", "confirm", "back", "buy", "error"]
# Named music tracks (Music bus) — the biome/boss score, driven by play_music().
const MUSIC_TRACKS := ["theme", "section_1", "section_2", "section_3", "section_4", "vault", "memorial"]


func _ready() -> void:
	_enabled = _has_audio()
	if not _enabled:
		return   # headless / no display: stay a silent, allocation-free no-op
	_load_map()
	_build_pool()
	_apply_saved_volumes()   # W6-7: a saved 65% must actually attenuate the bus at startup, not only on a slider drag


## Apply the persisted SFX/Music/UI volumes to the buses at boot (W6-7). Before this, the buses booted
## at 0 dB (100%) and the saved settings were only ever applied on a live slider drag (menu.gd) — so a
## player who set 65% last session heard 100% until they re-opened Settings. Reads the profile through
## the same SaveSystem the menu uses (sandbox-aware in tests). No-op headless: set_volume already bails
## when `_enabled` is false, so this never touches a bus (and never errors) in the byte-stable suites.
func _apply_saved_volumes() -> void:
	var p = SaveSystem.load_profile()
	if p == null:
		return
	set_volume("sfx_volume", int(p.get_setting("sfx_volume", 100)))
	set_volume("music_volume", int(p.get_setting("music_volume", 80)))
	set_volume("ui_volume", int(p.get_setting("ui_volume", 100)))


## True only with a real display AND a real (non-dummy) audio driver — the on-screen path. Headless
## and the test harness fail this, so nothing is ever allocated or played there (byte-stable stdout).
func _has_audio() -> bool:
	if OS.has_feature("headless") or DisplayServer.get_name() == "headless":
		return false
	return AudioServer.get_bus_count() > 0


# ---- public API ------------------------------------------------------------------------------
## Combat/finale choke point: play the SFX slot mapped to `ev_type` (called from
## EventPlayer._apply_animated, on-screen only). Unmapped/silent events are a no-op.
func event_sfx(ev_type: int) -> void:
	if not _enabled:
		return
	var slot: String = EVENT_SFX.get(ev_type, "")
	if slot != "":
		play_sfx(slot)


## Play a named one-shot SFX slot on the SFX bus. Silent no-op if disabled or the slot has no file
## on disk yet (the drop-in contract: the slot exists in the map, audio arrives later).
func play_sfx(slot: String) -> void:
	if not _enabled or slot == "":
		return
	var stream = _stream_for(slot)
	if stream == null:
		return
	var p: AudioStreamPlayer = _sfx_pool[_sfx_next]
	_sfx_next = (_sfx_next + 1) % _sfx_pool.size()
	p.stream = stream
	p.play()


## Play a named UI slot on the UI bus (menu/HUD select/confirm/back/buy). Silent if no file yet.
func play_ui(slot: String) -> void:
	if not _enabled or _ui_player == null or slot == "":
		return
	var stream = _stream_for(slot)
	if stream == null:
		return
	_ui_player.stream = stream
	_ui_player.play()


## Start (or switch) the looping music track on the Music bus; "" stops music. Idempotent on the
## same track. Silent no-op if disabled or the track has no file yet.
func play_music(track: String) -> void:
	if not _enabled or _music_player == null:
		return
	if track == _music_track:
		return
	_music_track = track
	if track == "":
		_music_player.stop()
		return
	var stream = _stream_for(track)
	if stream == null:
		_music_player.stop()
		return
	_music_player.stream = stream
	_music_player.play()


## Drive a bus volume from a 0..100 settings value (the SFX/Music sliders). `key` is the profile
## setting id: "sfx_volume"|"music_volume"|"ui_volume". 0 -> muted (-80 dB), 100 -> 0 dB. No-op headless.
func set_volume(key: String, value_0_100: int) -> void:
	if not _enabled:
		return
	var bus := ""
	match key:
		"sfx_volume": bus = SFX_BUS
		"music_volume": bus = MUSIC_BUS
		"ui_volume": bus = UI_BUS
		_: return
	var idx := AudioServer.get_bus_index(bus)
	if idx < 0:
		return
	var v: int = clampi(value_0_100, 0, 100)
	if v <= 0:
		AudioServer.set_bus_mute(idx, true)
	else:
		AudioServer.set_bus_mute(idx, false)
		AudioServer.set_bus_volume_db(idx, linear_to_db(float(v) / 100.0))


# ---- internals -------------------------------------------------------------------------------
## Load the slot -> stream-path manifest (best-effort; a missing/garbage file just leaves the map
## empty, so every slot is silent until real audio is authored). Never fails loudly.
func _load_map() -> void:
	if not FileAccess.file_exists(AUDIO_MAP_PATH):
		return
	var f := FileAccess.open(AUDIO_MAP_PATH, FileAccess.READ)
	if f == null:
		return
	var parsed = JSON.parse_string(f.get_as_text())
	if typeof(parsed) != TYPE_DICTIONARY:
		return
	var slots = parsed.get("slots", {})
	if typeof(slots) == TYPE_DICTIONARY:
		for k in slots.keys():
			_slots[String(k)] = String(slots[k])
	var music = parsed.get("music", {})
	if typeof(music) == TYPE_DICTIONARY:
		for k in music.keys():
			_slots[String(k)] = String(music[k])


## Resolve a slot name to a loaded AudioStream (cached), or null if the manifest has no path for it
## or the file is not on disk yet (the placeholder-absent case — silent, not an error).
func _stream_for(slot: String):
	var path: String = _slots.get(slot, "")
	if path == "":
		return null
	if _stream_cache.has(path):
		return _stream_cache[path]
	var stream = null
	if ResourceLoader.exists(path):
		stream = ResourceLoader.load(path)
	_stream_cache[path] = stream   # cache the null too, so we probe each missing file only once
	return stream


func _build_pool() -> void:
	for i in range(SFX_POOL):
		var p := AudioStreamPlayer.new()
		p.bus = SFX_BUS
		add_child(p)
		_sfx_pool.append(p)
	_ui_player = AudioStreamPlayer.new()
	_ui_player.bus = UI_BUS
	add_child(_ui_player)
	_music_player = AudioStreamPlayer.new()
	_music_player.bus = MUSIC_BUS
	add_child(_music_player)
