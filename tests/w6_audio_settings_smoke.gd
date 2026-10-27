extends SceneTree
## Wave 6 — AUDIO + SETTINGS + ONBOARDING smoke test (lane: audio-settings). Proves the six W6
## audio/settings items are REAL in a live drive, not just present in a helper:
##   W6-5  the 5 run-layer onboarding tips (order/captain/betrayer/fog/finale) exist AND fire under
##         their trigger condition (driving the ACTUAL CombatTips decision object, gated by enabled/seen).
##   W6-6  play_music has a real caller (menu theme) AND the four dead UI slots (confirm/back/buy/error)
##         are invoked from the menu paths — asserted by a SPY AudioDirector that records the calls.
##   W6-7  saved SFX/Music volumes are applied to the buses at boot (a saved 65% actually attenuates).
##   W6-8  Fullscreen + VSync settings rows exist, persist, and the toggle targets the right window API.
##   W6-9  Reduced-flash setting persists AND the flag reaches the run layer via MenuHandoff.settings.
##   W6-10 Colorblind-mode row cycles + persists + reaches the run; text_speed is NOT surfaced (removed
##         promise — no comms-typing mechanism exists to consume it).
## Run: godot --headless --path . --script res://tests/w6_audio_settings_smoke.gd
##
## Every assertion drives the SAME code the game runs (the real Menu node, the real AudioDirector
## set_volume, the pure CombatTips object). Byte-stable: the menu/audio layers are on-screen-only and
## no-op headless, and this suite touches no sim/RNG — it never runs in any determinism guard.

const CombatTips = preload("res://app/combat_tips.gd")
const MenuScript = preload("res://app/menu.gd")
const AudioDirectorScript = preload("res://app/audio_director.gd")
const MetaProfile = preload("res://core/meta/meta_profile.gd")
const SaveSystem = preload("res://core/meta/save_system.gd")

var _pass: int = 0
var _fail: int = 0
var _fails: Array = []


# A recording stand-in for the AudioDirector autoload: menu code calls /root/AudioDirector.play_*();
# this captures every call so the test can prove the menu actually reaches the audio layer.
class SpyAudio:
	extends Node
	var music: Array = []
	var ui: Array = []
	var vol: Array = []
	func play_music(track: String) -> void: music.append(track)
	func play_ui(slot: String) -> void: ui.append(slot)
	func play_sfx(_slot: String) -> void: pass
	func event_sfx(_ev: int) -> void: pass
	func set_volume(key: String, v: int) -> void: vol.append([key, v])


func _initialize() -> void:
	SaveSystem.force_sandbox = true   # never touch the owner's real profile/run saves (W1-9b contract)
	print("\n=== COLDSPINE — Wave 6 audio/settings smoke test ===")
	test_new_tips_exist_and_fire()                 # W6-5
	await test_music_and_ui_slots_reach_the_director()   # W6-6 (async: needs the menu inside the tree)
	test_saved_volumes_applied_at_boot()           # W6-7
	test_fullscreen_vsync_rows_persist_and_apply() # W6-8
	test_reduced_flash_persists_and_reaches_run()  # W6-9
	test_colorblind_row_and_text_speed_removed()   # W6-10
	print("\n--- W6 AUDIO/SETTINGS SMOKE: %d passed, %d failed ---" % [_pass, _fail])
	for f in _fails:
		print("    FAIL: " + f)
	if _fail == 0:
		print("W6 GREEN — music/UI cues wired, volumes applied at boot, display+a11y settings live, run-layer tips added.\n")
	quit(0 if _fail == 0 else 1)


# ---- assertion kit (matches audio_smoke) ----
func ok(cond: bool, msg: String) -> void:
	if cond:
		_pass += 1
	else:
		_fail += 1
		_fails.append(msg)
		print("    [FAIL] " + msg)

func eq(a, b, msg: String) -> void:
	ok(a == b, "%s (got %s, want %s)" % [msg, str(a), str(b)])

func approx(a: float, b: float, msg: String) -> void:
	ok(absf(a - b) < 0.02, "%s (got %f, want %f)" % [msg, a, b])


# ---- shared menu harness (mirrors menu_smoke._menu) ----
## Instance the REAL menu into the tree so _ready fires (loads the profile, builds the UI, takes the
## headless HOME path). The menu's /root/AudioDirector lookups no-op here (not inside the active tree —
## it never calls _ready via the deferred notification), which is exactly what the settings tests want:
## they poke the profile/model directly, no audio. The spy test (W6-6) uses the await path instead.
func _menu() -> Control:
	var m := Control.new()
	m.set_script(MenuScript)
	get_root().add_child(m)
	m._ready()   # the deferred READY notification hasn't fired yet in _initialize; run the entry point once
	return m


## Recursively collect the text of every Label/Button under `host` (settings rows mix both).
func _panel_texts(host: Node) -> Array:
	var out: Array = []
	for c in host.get_children():
		if c is Button:
			out.append((c as Button).text)
		elif c is Label:
			out.append((c as Label).text)
		out.append_array(_panel_texts(c))
	return out


## Find the first Button under `host` whose text contains `needle` (case-sensitive).
func _find_button(host: Node, needle: String) -> Button:
	for c in host.get_children():
		if c is Button and (c as Button).text.find(needle) != -1:
			return c
		var deep := _find_button(c, needle)
		if deep != null:
			return deep
	return null


func _texts_contain(texts: Array, needle: String) -> bool:
	for t in texts:
		if String(t).to_lower().find(needle.to_lower()) != -1:
			return true
	return false


# ============================ W6-5 — run-layer onboarding tips =================
## The 5 new tips exist, are non-empty, and FIRE under their trigger condition through the same pure
## CombatTips object the RunController drives. Reproduces the gap: a player who has already seen all 9
## combat-basics still gets taught these run-layer concepts (they were absent from the catalog before).
func test_new_tips_exist_and_fire() -> void:
	var new_ids := ["order", "captain", "betrayer", "fog", "finale"]
	var tips: Dictionary = CombatTips.TIPS
	var order: Array = CombatTips.ORDER
	var ct := CombatTips.new()
	for id in new_ids:
		ok(tips.has(id), "[W6-5] tip '%s' exists in the catalog" % id)
		ok(order.has(id), "[W6-5] tip '%s' is in the stable teaching ORDER" % id)
		ok(ct.title(id) != "" and ct.body(id) != "", "[W6-5] tip '%s' has a title + body" % id)
	# ORDER still covers exactly the TIPS entries (catalog stays consistent after the append).
	eq(order.size(), tips.size(), "[W6-5] ORDER covers exactly the TIPS entries after the append")
	# Trigger behaviour: a fresh, enabled tips object FIRES each new id; marking it suppresses it.
	var fresh := CombatTips.new([], true)
	for id in new_ids:
		ok(fresh.should_fire(id), "[W6-5] new tip '%s' fires when enabled + unseen (trigger condition)" % id)
		fresh.mark_fired(id)
		ok(not fresh.should_fire(id), "[W6-5] new tip '%s' is suppressed after firing once" % id)
	# The gap it reproduces: seeing every combat-basic does NOT pre-suppress the run-layer tips.
	var veteran := CombatTips.new(["select", "displace", "preview", "shoot", "overwatch", "combo", "ability", "item", "stabilize"], true)
	for id in new_ids:
		ok(veteran.should_fire(id), "[W6-5] '%s' still fires for a player who saw all 9 basics (was untaught pre-fix)" % id)
	# Globally-off suppresses them too (respects tips_enabled, like the rest of the catalog).
	var off := CombatTips.new([], false)
	var any_off := false
	for id in new_ids:
		if off.should_fire(id):
			any_off = true
	ok(not any_off, "[W6-5] tips-off suppresses every new run-layer tip")


# ============================ W6-6 — music + UI cues reach the director ========
## A SPY AudioDirector proves the menu actually CALLS play_music("theme") at boot and fires the four
## previously-dead UI slots (confirm/back/buy/error) from the real button paths. Async: the menu must be
## INSIDE the tree for its /root/AudioDirector lookups to resolve (an absolute path resolves only from the
## active tree). We install the spy, add the menu, and await a process frame so the deferred tree-entry +
## the engine's _ready fire — exactly the state real play is always in (the menu is the current scene).
func test_music_and_ui_slots_reach_the_director() -> void:
	SaveSystem.clear_run()   # ensure CONTINUE has no save so the error path is reachable
	var spy := SpyAudio.new()
	# Install the spy at /root/AudioDirector (renaming the real autoload aside) BEFORE the menu enters.
	var real = get_root().get_node_or_null("AudioDirector")
	if real != null:
		real.name = "AudioDirector_real"
	spy.name = "AudioDirector"
	get_root().add_child(spy)
	var m := Control.new()
	m.set_script(MenuScript)
	get_root().add_child(m)
	await process_frame   # flush the deferred tree-entry so _ready fires with the menu inside the tree
	# (a) MUSIC: _ready fired the theme cue (play_music had ZERO callers before Wave 6).
	ok(spy.music.has("theme"), "[W6-6] menu boot calls play_music('theme') — music has a real caller")
	# (b) UI 'confirm': pressing NEW RUN fires the confirm cue (in addition to staging the handoff).
	var new_run := _find_button(m, "NEW RUN")
	ok(new_run != null, "[W6-6] NEW RUN button exists")
	if new_run != null:
		new_run.pressed.emit()
	ok(spy.ui.has("confirm"), "[W6-6] NEW RUN press reaches play_ui('confirm')")
	# (c) UI 'buy': an affordable unlock purchase fires the buy cue.
	m.profile.meta_currency = 99999
	m._show_unlocks()
	var buy := _find_button(m, "[")   # buy rows carry the "[cost]" price tag; OWNED are plain labels
	ok(buy != null, "[W6-6] at least one affordable buy row exists")
	if buy != null:
		buy.pressed.emit()
	ok(spy.ui.has("buy"), "[W6-6] a buy press reaches play_ui('buy')")
	# (d) UI 'back': the settings BACK row fires the back cue.
	m._show_settings()
	var back := _find_button(m, "< BACK")
	ok(back != null, "[W6-6] settings BACK button exists")
	if back != null:
		back.pressed.emit()
	ok(spy.ui.has("back"), "[W6-6] a BACK press reaches play_ui('back')")
	# (e) UI 'error': Continue with no resumable save fires the error cue.
	m._on_continue()
	ok(spy.ui.has("error"), "[W6-6] Continue-with-no-save reaches play_ui('error')")
	m.free()
	# restore the real autoload name so nothing downstream in the process is surprised
	if spy.is_inside_tree():
		spy.get_parent().remove_child(spy)
	spy.free()
	var stashed = get_root().get_node_or_null("AudioDirector_real")
	if stashed != null:
		stashed.name = "AudioDirector"


# ============================ W6-7 — saved volumes applied at boot =============
## A profile saved at music=65 / sfx=30 must attenuate the buses at startup. Drives the real
## AudioDirector._apply_saved_volumes (the method _ready calls) with _enabled forced on (headless
## normally disables audio), and reads the bus dB back. Reproduces the gap: before the fix, _ready
## never applied the profile, so the buses stayed at 0 dB (100%) regardless of the saved value.
func test_saved_volumes_applied_at_boot() -> void:
	var p := MetaProfile.new()
	p.set_setting("music_volume", 65)
	p.set_setting("sfx_volume", 30)
	SaveSystem.save_profile(p)
	var ad = AudioDirectorScript.new()
	ad._enabled = true   # buses exist even headless (4-bus layout); force the on-screen path for the read
	ad._apply_saved_volumes()
	var mi := AudioServer.get_bus_index("Music")
	var si := AudioServer.get_bus_index("SFX")
	ok(mi >= 0 and si >= 0, "[W6-7] Music + SFX buses exist")
	ok(not AudioServer.is_bus_mute(mi), "[W6-7] a 65% music save leaves the Music bus unmuted")
	approx(AudioServer.get_bus_volume_db(mi), linear_to_db(0.65), "[W6-7] Music bus reflects the saved 65%")
	approx(AudioServer.get_bus_volume_db(si), linear_to_db(0.30), "[W6-7] SFX bus reflects the saved 30%")
	# 0% mutes the bus (the muted branch of set_volume).
	ad.set_volume("music_volume", 0)
	ok(AudioServer.is_bus_mute(mi), "[W6-7] set_volume(0) mutes the bus")
	ad.set_volume("music_volume", 80)
	ok(not AudioServer.is_bus_mute(mi), "[W6-7] a non-zero volume unmutes it again")
	ad.free()


# ============================ W6-8 — fullscreen / vsync ========================
## The rows exist, persist, and the toggle targets the correct DisplayServer window mode. The literal
## window call is on-screen-only, but the mode DECISION (_last_display_apply) is computed headless too,
## so the test proves the toggle would call the window API with the right value.
func test_fullscreen_vsync_rows_persist_and_apply() -> void:
	var m := _menu()
	m._show_settings()
	var texts := _panel_texts(m._panel_host)
	ok(_texts_contain(texts, "fullscreen"), "[W6-8] a Fullscreen settings row exists")
	ok(_texts_contain(texts, "vsync"), "[W6-8] a VSync settings row exists")
	# Fullscreen defaults OFF; toggling ON persists + targets WINDOW_MODE_FULLSCREEN.
	ok(not bool(m.profile.get_setting("fullscreen", false)), "[W6-8] fullscreen defaults OFF")
	m._on_toggle("fullscreen", false)
	ok(bool(m.profile.get_setting("fullscreen", false)), "[W6-8] toggling fullscreen persists ON")
	eq(m._last_display_apply, {"key": "fullscreen", "mode": DisplayServer.WINDOW_MODE_FULLSCREEN},
		"[W6-8] fullscreen ON resolves to WINDOW_MODE_FULLSCREEN")
	m._on_toggle("fullscreen", false)
	eq(int(m._last_display_apply.get("mode", -1)), DisplayServer.WINDOW_MODE_WINDOWED,
		"[W6-8] fullscreen OFF resolves to WINDOW_MODE_WINDOWED")
	# VSync defaults ON (engine default) — the explicit default keeps the row honest before first write.
	ok(bool(m.profile.get_setting("vsync", true)), "[W6-8] vsync defaults ON")
	m._on_toggle("vsync", true)
	ok(not bool(m.profile.get_setting("vsync", true)), "[W6-8] toggling vsync persists OFF")
	eq(int(m._last_display_apply.get("mode", -1)), DisplayServer.VSYNC_DISABLED,
		"[W6-8] vsync OFF resolves to VSYNC_DISABLED")
	# Persistence round-trips through the profile save/load.
	SaveSystem.save_profile(m.profile)
	var reloaded = SaveSystem.load_profile()
	ok(bool(reloaded.get_setting("fullscreen", false)) == false, "[W6-8] fullscreen state survives save/load")
	ok(bool(reloaded.get_setting("vsync", true)) == false, "[W6-8] vsync state survives save/load")
	m.free()


# ============================ W6-9 — reduced flash ============================
## The Reduced-flash row exists, persists, AND the flag reaches the run layer via MenuHandoff.settings
## (the snapshot the renderer reads its damping flag from). Reproduces the gap: no such setting existed,
## so the flash-heavy FX had no photosensitivity damper anywhere.
func test_reduced_flash_persists_and_reaches_run() -> void:
	var m := _menu()
	m._show_settings()
	var texts := _panel_texts(m._panel_host)
	ok(_texts_contain(texts, "reduced flash"), "[W6-9] a Reduced-flash settings row exists")
	ok(not bool(m.profile.get_setting("reduced_flash", false)), "[W6-9] reduced_flash defaults OFF")
	m._on_toggle("reduced_flash", false)
	ok(bool(m.profile.get_setting("reduced_flash", false)), "[W6-9] toggling reduced_flash persists ON")
	# The flag must FLOW to the run (render reads it off the session-settings snapshot). Pressing NEW RUN
	# stages MenuHandoff.settings = profile.settings, so reduced_flash rides along to the RunController.
	m._on_new_run()
	ok(bool(MenuScript.MenuHandoff.settings.get("reduced_flash", false)),
		"[W6-9] reduced_flash reaches the run via MenuHandoff.settings (the renderer's read source)")
	m.free()


# ============================ W6-10 — colorblind row / text_speed removed ======
## Colorblind mode gets a real cycling row that persists + reaches the run; text_speed is NOT surfaced
## (no comms-typing cadence exists to consume it — surfacing it would be a fresh dead promise).
func test_colorblind_row_and_text_speed_removed() -> void:
	var m := _menu()
	m._show_settings()
	var texts := _panel_texts(m._panel_host)
	ok(_texts_contain(texts, "colorblind"), "[W6-10] a Colorblind-mode settings row exists")
	ok(not _texts_contain(texts, "text speed") and not _texts_contain(texts, "typing"),
		"[W6-10] text_speed is NOT surfaced (no consumer/mechanism — flagged for removal)")
	# Cycle 0 -> 1 -> 2 -> 3 -> 0, persisting each step.
	eq(int(m.profile.get_setting("colorblind_mode", 0)), 0, "[W6-10] colorblind_mode starts at 0 (off)")
	for expect in [1, 2, 3, 0]:
		m._on_cblind_cycle("colorblind_mode")
		eq(int(m.profile.get_setting("colorblind_mode", -1)), expect, "[W6-10] cycle lands on %d" % expect)
	# Set a non-zero mode and confirm it reaches the run (render selects the palette variant from it).
	m._on_cblind_cycle("colorblind_mode")   # -> 1
	m._on_new_run()
	eq(int(MenuScript.MenuHandoff.settings.get("colorblind_mode", -1)), 1,
		"[W6-10] colorblind_mode reaches the run via MenuHandoff.settings")
	m.free()
