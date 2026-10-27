extends SceneTree
## Headless AUDIO smoke test (release-readiness #4). Proves the audio ARCHITECTURE is sound and
## that it is a total no-op headless, so real audio drops in like the art did and the byte-stable
## suites stay byte-stable:
##   (a) the Master->Music/SFX/UI bus layout loaded (AudioServer has all 4 named buses);
##   (b) the event->slot map is TOTAL: every core/sim_enums.gd::Ev member is mapped to an SFX slot
##       OR is in the explicit SILENT set — never a missing key (fails loud on future Ev drift);
##       and the two sets are disjoint;
##   (c) every mapped slot + UI slot + music track has a path in content/audio_map.json (the drop-in
##       manifest is complete — an artist can commission every named cue);
##   (d) the director is a safe NO-OP headless: event_sfx/play_sfx/play_ui/play_music/set_volume all
##       run without allocating a player, playing a sound, or erroring (headless = silent).
## Run: godot --headless --path . --script res://tests/audio_smoke.gd

const E = preload("res://core/sim_enums.gd")
const AudioDirectorScript = preload("res://app/audio_director.gd")

const AUDIO_MAP_PATH := "res://content/audio_map.json"

var _pass: int = 0
var _fail: int = 0
var _fails: Array = []

func _initialize() -> void:
	print("\n=== COLDSPINE — audio smoke test ===")
	test_bus_layout_loaded()
	test_event_slot_map_is_total()
	test_map_and_silent_disjoint()
	test_manifest_covers_every_slot()
	test_director_is_headless_noop()
	test_slot_names_are_nonempty()
	print("\n--- AUDIO SMOKE: %d passed, %d failed ---" % [_pass, _fail])
	for f in _fails:
		print("    FAIL: " + f)
	if _fail == 0:
		print("AUDIO GREEN — bus layout + total event->slot map, silent no-op headless.\n")
	quit(0 if _fail == 0 else 1)

# ---- assertion kit (matches render_smoke) ----
func ok(cond: bool, msg: String) -> void:
	if cond:
		_pass += 1
	else:
		_fail += 1
		_fails.append(msg)
		print("    [FAIL] " + msg)

func eq(a, b, msg: String) -> void:
	ok(a == b, "%s (got %s, want %s)" % [msg, str(a), str(b)])

# ---- the full set of Ev enum values (the authoritative event vocabulary) ----
func _all_events() -> Array:
	return E.Ev.values()

# ============================ TESTS ===========================================
## (a) The default_bus_layout.tres registered in project.godot must yield the 4 named buses.
func test_bus_layout_loaded() -> void:
	eq(AudioServer.get_bus_count(), 4, "[audio] bus layout loaded: exactly 4 buses (Master/Music/SFX/UI)")
	for bus in ["Master", "Music", "SFX", "UI"]:
		ok(AudioServer.get_bus_index(bus) >= 0, "[audio] bus '%s' exists in the layout" % bus)

## (b) The event->slot map is TOTAL over the Ev enum: every event is mapped OR explicitly silent.
func test_event_slot_map_is_total() -> void:
	var mapped: Dictionary = AudioDirectorScript.EVENT_SFX
	var silent: Array = AudioDirectorScript.SILENT_EVENTS
	var missing: Array = []
	for ev in _all_events():
		if not (mapped.has(ev) or silent.has(ev)):
			missing.append(ev)
	ok(missing.is_empty(), "[audio] every Ev member maps to an SFX slot or is explicitly silent (unmapped: %s)" % str(missing))
	# And no stray keys: every EVENT_SFX key is a real Ev value.
	var ev_set := {}
	for ev in _all_events():
		ev_set[ev] = true
	var stray: Array = []
	for k in mapped.keys():
		if not ev_set.has(k):
			stray.append(k)
	ok(stray.is_empty(), "[audio] EVENT_SFX has no keys outside the Ev enum (stray: %s)" % str(stray))
	print("    [audio] map coverage: %d mapped + %d silent == %d total Ev members" % [mapped.size(), silent.size(), _all_events().size()])

## (b') A given event may not be BOTH mapped and silent (the totality proof needs disjoint sets).
func test_map_and_silent_disjoint() -> void:
	var mapped: Dictionary = AudioDirectorScript.EVENT_SFX
	var overlap: Array = []
	for ev in AudioDirectorScript.SILENT_EVENTS:
		if mapped.has(ev):
			overlap.append(ev)
	ok(overlap.is_empty(), "[audio] EVENT_SFX and SILENT_EVENTS are disjoint (overlap: %s)" % str(overlap))

## (c) Every named cue (SFX slot referenced by the map, every UI slot, every music track) must have
## a path in content/audio_map.json — so the drop-in manifest an artist commissions against is complete.
func test_manifest_covers_every_slot() -> void:
	var f := FileAccess.open(AUDIO_MAP_PATH, FileAccess.READ)
	ok(f != null, "[audio] content/audio_map.json opens")
	if f == null:
		return
	var parsed = JSON.parse_string(f.get_as_text())
	ok(typeof(parsed) == TYPE_DICTIONARY, "[audio] audio_map.json parses to a dictionary")
	if typeof(parsed) != TYPE_DICTIONARY:
		return
	var slots: Dictionary = parsed.get("slots", {})
	var music: Dictionary = parsed.get("music", {})
	# Every SFX slot referenced by the event map has a manifest path.
	var missing_sfx: Array = []
	for slot in AudioDirectorScript.EVENT_SFX.values():
		if not slots.has(slot):
			missing_sfx.append(slot)
	ok(missing_sfx.is_empty(), "[audio] every mapped SFX slot has a manifest path (missing: %s)" % str(missing_sfx))
	# Every UI slot and music track is present too.
	var missing_ui: Array = []
	for slot in AudioDirectorScript.UI_SLOTS:
		if not slots.has(slot):
			missing_ui.append(slot)
	ok(missing_ui.is_empty(), "[audio] every UI slot has a manifest path (missing: %s)" % str(missing_ui))
	var missing_music: Array = []
	for track in AudioDirectorScript.MUSIC_TRACKS:
		if not music.has(track):
			missing_music.append(track)
	ok(missing_music.is_empty(), "[audio] every music track has a manifest path (missing: %s)" % str(missing_music))

## (d) The director, instantiated headless, must be a total no-op: no crash, no player nodes, silent.
func test_director_is_headless_noop() -> void:
	var ad = AudioDirectorScript.new()
	get_root().add_child(ad)   # runs _ready under the headless SceneTree
	ok(not ad._enabled, "[audio] director reports DISABLED headless (no display/audio)")
	ok(ad.get_child_count() == 0, "[audio] director allocated NO AudioStreamPlayer nodes headless")
	# Every public entry point must run without error and without playing anything.
	for ev in _all_events():
		ad.event_sfx(ev)
	ad.play_sfx("gunshot")
	ad.play_ui("select")
	ad.play_music("theme")
	ad.play_music("")
	ad.set_volume("sfx_volume", 50)
	ad.set_volume("music_volume", 0)
	ad.set_volume("ui_volume", 100)
	ad.set_volume("bogus_key", 40)
	ok(ad.get_child_count() == 0, "[audio] director still allocated no players after every call (silent)")
	ad.free()

## Guard: no mapped slot name is empty (an empty slot would silently swallow an event's cue).
func test_slot_names_are_nonempty() -> void:
	var bad: Array = []
	for ev in AudioDirectorScript.EVENT_SFX.keys():
		if String(AudioDirectorScript.EVENT_SFX[ev]) == "":
			bad.append(ev)
	ok(bad.is_empty(), "[audio] no mapped event resolves to an empty slot name (bad: %s)" % str(bad))
