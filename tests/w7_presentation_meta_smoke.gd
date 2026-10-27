extends SceneTree
## WAVE 7 — PRESENTATION-META smoke test (headless). One headless-checkable assertion per Wave-7
## presentation-meta fix, each reproducing the pre-fix gap. It CONSTRUCTS the on-screen nodes (Menu /
## OpsHUD / CarView are never built in the normal suites) and asserts their node/state contract + the
## meta model (MetaProfile / SaveSystem) — NOT pixels (the lead's windowed tour eyeballs those).
##
## Covers:
##   W7-2  run summary/history       — MetaProfile.record_run + round-trip; menu RUN HISTORY panel
##   W7-3  save schema gate          — an incompatible run save is refused (CONTINUE disabled + message)
##   W7-4  boot splash + title       — project.godot carries the title + a boot splash config
##   W6-11 betrayer VET button       — the HUD builds a VET button that emits action "VET"
##   W6-2  AUTO SCOPE indicator      — the indicator/toggle builds + reflects scope + emits "SCOPE"
##   W6-6  run-layer UI SFX          — an ops_hud button press routes a play_ui cue to the director
##   W5-16 memorial enshrine glyph   — a memorial row builds a glyph node AND focus traversal survives
##   W7-iso setpiece direction       — a setpiece token's render orientation matches its intended side
##   W7-6  .uid sidecars             — every .gd under core/app/render/tests has a .uid sidecar
##   W7-7  stale-claim sweep         — the stale "no config/icon" shopping-list claim is corrected
##
## Run: godot --headless --path . --script res://tests/w7_presentation_meta_smoke.gd

const OpsHUD = preload("res://render/ops_hud.gd")
const Pal = preload("res://render/palette.gd")
const Menu = preload("res://app/menu.gd")
const MetaProfile = preload("res://core/meta/meta_profile.gd")
const SaveSystem = preload("res://core/meta/save_system.gd")
const RunState = preload("res://core/run/run_state.gd")
const CarView = preload("res://render/car_view.gd")
const E = preload("res://core/sim_enums.gd")

var _pass: int = 0
var _fail: int = 0
var _fails: Array = []


# A recording stand-in for the AudioDirector autoload (mirrors w6_audio_settings_smoke.SpyAudio):
# ops_hud code calls /root/AudioDirector.play_ui(); this captures the calls so the test proves the
# button press actually reaches the audio layer.
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
	print("\n=== COLDSPINE — Wave 7 presentation-meta smoke test (headless) ===")
	test_run_log_record_and_roundtrip()   # W7-2 model
	test_history_panel_builds_from_log()  # W7-2 menu
	test_save_schema_gate()               # W7-3
	test_project_splash_and_title()       # W7-4
	test_vet_button_emits_action()        # W6-11
	test_auto_scope_indicator()           # W6-2
	await test_ops_hud_ui_sfx_reaches_director() # W6-6 (async: the hud must be INSIDE the tree for /root lookups)
	test_memorial_glyph_and_focus()       # W5-16
	test_iso_direction_reconciliation()   # W7-iso-labels
	test_uid_sidecars_present()           # W7-6
	test_stale_claims_corrected()         # W7-7
	print("\n--- W7 PRESENTATION-META SMOKE: %d passed, %d failed ---" % [_pass, _fail])
	for f in _fails:
		print("    FAIL: " + f)
	if _fail == 0:
		print("W7 PRESENTATION-META GREEN — run history, schema gate, boot splash, VET/SCOPE/UI-SFX HUD, memorial glyph, iso reconciliation, uid hygiene.\n")
	quit(0 if _fail == 0 else 1)


func ok(cond: bool, msg: String) -> void:
	if cond:
		_pass += 1
	else:
		_fail += 1
		_fails.append(msg)
		print("    [FAIL] " + msg)


# ---- node harness (the render_smoke / hud_menu_wave5 pattern) ----
func _hud() -> OpsHUD:
	var hud := OpsHUD.new()
	root.add_child(hud)
	hud._ready()
	return hud


func _menu() -> Control:
	var m := Control.new()
	m.set_script(Menu)
	root.add_child(m)
	m._ready()
	return m


func _find_button(node: Node, query: String) -> Button:
	for c in node.get_children():
		if c is Button and String((c as Button).text).contains(query):
			return c
		var r := _find_button(c, query)
		if r != null:
			return r
	return null


func _labels_under(node: Node, out: Array) -> void:
	for c in node.get_children():
		if c is Label:
			out.append(String((c as Label).text))
		elif c is Button:
			out.append(String((c as Button).text))
		_labels_under(c, out)


func _panel_texts(m) -> String:
	var out: Array = []
	_labels_under(m._panel_host, out)
	return "\n".join(out)


# ============================ W7-2 run history ================================
func test_run_log_record_and_roundtrip() -> void:
	var p := MetaProfile.new()
	# PRE-FIX GAP: best_ending was tracked, but there was NO per-run history at all.
	ok(p.run_log.is_empty(), "[W7-2] a fresh profile has an empty run log (the pre-fix gap: no run history existed)")
	p.record_run(E.EndingId.LIBERATION, true, 8, 3, 3, 20)
	p.record_run(E.EndingId.LOSS, false, 2, 0, 3, 55)
	ok(p.run_log.size() == 2, "[W7-2] record_run appends one entry per finished run")
	var recent := p.recent_runs(5)
	ok(recent.size() == 2 and int(recent[0].get("ending", -1)) == E.EndingId.LOSS,
		"[W7-2] recent_runs lists newest-first")
	ok(int(recent[0].get("cars", -1)) == 2 and int(recent[0].get("survivors", -1)) == 0,
		"[W7-2] a run-log entry carries the run facts (cars / survivors)")
	# record_run does NOT double-count stats (the finalize path owns runs/wins/best_ending).
	ok(int(p.stats.get("runs", 0)) == 0, "[W7-2] record_run does not touch stats.runs (no double count with finalize)")
	# to_dict -> from_dict round-trip (ints coerced).
	var d := p.to_dict()
	ok(d.has("run_log") and (d["run_log"] as Array).size() == 2, "[W7-2] to_dict serializes the run log")
	var p2 := MetaProfile.from_dict(d)
	ok(p2.run_log.size() == 2 and int(p2.run_log[0].get("ending", -1)) == E.EndingId.LIBERATION,
		"[W7-2] from_dict restores the run log")
	# a REAL disk round-trip through the save layer (auto-sandboxed).
	SaveSystem.save_profile(p)
	var pl = SaveSystem.load_profile()
	ok(pl.run_log.size() == 2, "[W7-2] the run log survives a save_profile -> load_profile disk round-trip")
	# the log caps (never grows unbounded) and keeps the NEWEST.
	var p3 := MetaProfile.new()
	for i in range(MetaProfile.RUN_LOG_MAX + 6):
		p3.record_run(E.EndingId.HARD_STOP, true, i, 1, 3, 0)
	ok(p3.run_log.size() == MetaProfile.RUN_LOG_MAX, "[W7-2] the run log caps at RUN_LOG_MAX")
	ok(int(p3.run_log.back().get("cars", -1)) == MetaProfile.RUN_LOG_MAX + 5, "[W7-2] the cap keeps the newest entries")


func test_history_panel_builds_from_log() -> void:
	var m := _menu()
	m.profile = MetaProfile.new()
	m.profile.stats["best_ending"] = E.EndingId.SEIZE_ENGINE
	m.profile.stats["runs"] = 4
	m.profile.record_run(E.EndingId.LIBERATION, true, 8, 3, 3, 15)
	m.profile.record_run(E.EndingId.LOSS, false, 2, 0, 3, 60)
	m._show_history()
	ok(m._active_panel == "history", "[W7-2] the RUN HISTORY panel activates")
	var txt := _panel_texts(m)
	ok(txt.contains("BEST ENDING") and txt.contains("SEIZE THE ENGINE"),
		"[W7-2] the panel surfaces best_ending (tracked in stats but shown NOWHERE before W7-2)")
	ok(txt.contains("LIBERATION") and txt.contains("LOSS"), "[W7-2] the panel lists the logged runs")
	ok(_find_button(m, "< BACK") != null, "[W7-2] RUN HISTORY has a < BACK control (no dead end)")
	m.free()
	# EMPTY state (no runs logged) is not a dead panel.
	var m2 := _menu()
	m2.profile = MetaProfile.new()
	m2._show_history()
	ok(_panel_texts(m2).contains("No runs recorded"), "[W7-2] an empty run log shows the empty state")
	m2.free()


# ============================ W7-3 save schema gate ==========================
func test_save_schema_gate() -> void:
	SaveSystem.clear_run()
	# Write a run save carrying a WRONG schema straight into the (sandboxed) run slot.
	var bad := {"seed": 123, "schema": RunState.SCHEMA_VERSION + 999, "line": [], "position": 0}
	SaveSystem.save_slot(SaveSystem.run_path(), bad)
	ok(SaveSystem.has_run_save(), "[W7-3] a (bad-schema) mid-run save exists on disk")
	ok(SaveSystem.run_save_schema() == RunState.SCHEMA_VERSION + 999,
		"[W7-3] run_save_schema READS the on-disk schema (SCHEMA_VERSION was written but never read pre-fix)")
	ok(not SaveSystem.run_save_compatible(), "[W7-3] a mismatched-schema save reads as INCOMPATIBLE")
	ok(SaveSystem.load_run() == null,
		"[W7-3] load_run REFUSES the incompatible save (null — never a silent divergent resume)")
	# The menu reflects it: CONTINUE disabled + an explanatory message.
	var m := _menu()
	var cont := _find_button(m, "CONTINUE")
	ok(cont != null and cont.disabled, "[W7-3] CONTINUE is DISABLED for an incompatible save")
	ok(cont != null and String(cont.text).contains("INCOMPATIBLE"), "[W7-3] CONTINUE is tagged SAVE INCOMPATIBLE")
	ok(_panel_texts(m).to_lower().contains("incompatible"), "[W7-3] a HOME message explains the incompatible save")
	m.free()
	# A CURRENT-schema save is NOT over-rejected (W1 resume stays intact).
	SaveSystem.clear_run()
	var good := {"seed": 123, "schema": RunState.SCHEMA_VERSION, "line": [], "position": 0}
	SaveSystem.save_slot(SaveSystem.run_path(), good)
	ok(SaveSystem.run_save_compatible(), "[W7-3] a current-schema save reads as compatible (no over-rejection)")
	ok(SaveSystem.load_run() != null, "[W7-3] load_run accepts a current-schema save")
	var m2 := _menu()
	var cont2 := _find_button(m2, "CONTINUE")
	ok(cont2 != null and not cont2.disabled, "[W7-3] CONTINUE is ENABLED for a compatible save")
	m2.free()
	SaveSystem.clear_run()


# ============================ W7-4 boot splash + title =======================
func test_project_splash_and_title() -> void:
	var txt := FileAccess.get_file_as_string("res://project.godot")
	ok(txt.contains("config/name=\"COLDSPINE\""),
		"[W7-4] project.godot sets the window title to COLDSPINE (config/name)")
	ok(txt.contains("boot_splash/image="),
		"[W7-4] project.godot configures a boot splash image (replaces the stock Godot-logo splash)")
	ok(txt.contains("boot_splash/bg_color="), "[W7-4] the boot splash carries a branded background color")
	# the configured splash image resolves to a real asset on disk.
	var splash := _ini_value(txt, "boot_splash/image=")
	ok(splash != "" and FileAccess.file_exists(splash), "[W7-4] the boot splash image path resolves to a real asset (%s)" % splash)
	ok(txt.contains("config/icon="), "[W7-4] project.godot carries an app-icon config")


func _ini_value(txt: String, key: String) -> String:
	for line in txt.split("\n"):
		if String(line).begins_with(key):
			return String(line).substr(key.length()).strip_edges().trim_prefix("\"").trim_suffix("\"")
	return ""


# ============================ W6-11 betrayer VET button ======================
func test_vet_button_emits_action() -> void:
	var hud := _hud()
	ok(hud._vet_button != null, "[W6-11] the HUD builds a VET/SCAN palette button")
	var got := {"n": ""}
	hud.action_pressed.connect(func(n): got.n = n)
	hud._vet_button.emit_signal("pressed")
	ok(got.n == "VET", "[W6-11] pressing VET emits action_pressed('VET') — the name run_controller routes to scan_for_betrayer")
	# one-per-run availability display.
	hud.set_vet_available(true)
	ok(not hud._vet_button.disabled, "[W6-11] VET is enabled while the scan is unused (available)")
	hud.set_vet_available(false)
	ok(hud._vet_button.disabled and String(hud._vet_button.text).contains("✓"),
		"[W6-11] a spent VET reads disabled + used (its one-per-run availability)")
	hud.free()


# ============================ W6-2 AUTO SCOPE indicator ======================
func test_auto_scope_indicator() -> void:
	var hud := _hud()
	ok(hud._scope_button != null, "[W6-2] the HUD builds an AUTO SCOPE indicator/toggle")
	hud.set_auto_scope("fight")
	ok(String(hud._scope_button.text).contains("THIS FIGHT"), "[W6-2] the indicator reflects fight-scope")
	ok(not hud.auto_scope_is_whole_run(), "[W6-2] auto_scope_is_whole_run() is false in fight scope")
	hud.set_auto_scope("run")
	ok(String(hud._scope_button.text).contains("WHOLE RUN"), "[W6-2] the indicator reflects whole-run scope")
	ok(hud.auto_scope_is_whole_run(), "[W6-2] auto_scope_is_whole_run() is true in whole-run scope")
	var got := {"n": ""}
	hud.control_pressed.connect(func(n): got.n = n)
	hud._scope_button.emit_signal("pressed")
	ok(got.n == "SCOPE", "[W6-2] pressing the scope toggle emits control_pressed('SCOPE') (the _set_auto_whole_run path)")
	hud.free()


# ============================ W6-6 run-layer UI SFX ==========================
func test_ops_hud_ui_sfx_reaches_director() -> void:
	# Install a spy at /root/AudioDirector (renaming the real autoload aside) so the ops_hud lookups resolve to it.
	var real = root.get_node_or_null("AudioDirector")
	if real != null:
		real.name = "AudioDirector_real"
	var spy := SpyAudio.new()
	spy.name = "AudioDirector"
	root.add_child(spy)
	var hud := OpsHUD.new()
	root.add_child(hud)
	await process_frame   # flush the deferred tree-entry so _ready fires with the hud INSIDE the tree
	hud.set_actions_enabled(true)   # arm the palette so END/CANCEL are pressable
	# An action commit -> "confirm"; a control press -> "select"; CANCEL -> "back"; DEEP SCAN -> "buy".
	hud._action_buttons["END"].emit_signal("pressed")
	ok(spy.ui.has("confirm"), "[W6-6] an ops_hud action press reaches play_ui('confirm')")
	hud._auto_button.emit_signal("pressed")
	ok(spy.ui.has("select"), "[W6-6] an ops_hud control press reaches play_ui('select')")
	hud._action_buttons["CANCEL"].emit_signal("pressed")
	ok(spy.ui.has("back"), "[W6-6] CANCEL reaches play_ui('back')")
	var scan := hud._recon_scan_button(true, false, 99)
	scan.emit_signal("pressed")
	ok(spy.ui.has("buy"), "[W6-6] a DEEP SCAN press reaches play_ui('buy')")
	hud.free()
	spy.free()
	var stashed = root.get_node_or_null("AudioDirector_real")
	if stashed != null:
		stashed.name = "AudioDirector"


# ============================ W5-16 memorial enshrine glyph ==================
func test_memorial_glyph_and_focus() -> void:
	var m := _menu()
	m.profile = MetaProfile.new()
	# Two fallen: an ARMABLE marksman (a trait to pass on) + a non-armable steward.
	m.profile.memorial = [
		{"legacy_id": "L1", "name": "ASH", "archetype": "marksman", "traits": ["steady"], "inventory": [], "inherited": false},
		{"legacy_id": "L2", "name": "VERA", "archetype": "steward", "traits": [], "inventory": [], "inherited": false},
	]
	m._show_memorial()
	# GLYPH: a memorial row builds an enshrine glyph node (in a FAC_NEUTRAL ring).
	var row := _find_button(m, "ASH")
	ok(row != null, "[W5-16] the memorial lists the fallen hero row")
	var glyph = row.find_child("enshrine_glyph", true, false) if row != null else null
	ok(glyph != null, "[W5-16] a memorial row builds an enshrine glyph node (was bare text)")
	# FOCUS: the W5-8 keyboard column survives — the row is still a DIRECT child of the panel column,
	# an initial focus target is chosen, and traversal neighbors are wired (no container-wrap that hides it).
	ok(row != null and row.get_parent() == m._panel_host,
		"[W5-16] the glyph is a CHILD of the row button, so the row stays a direct panel-column child (W5-8 intact)")
	ok(m._first_focus != null and m._first_focus is Button, "[W5-16] an initial focus target is still chosen after the glyph add")
	ok(m._first_focus != null and m._first_focus.get_parent() == m._panel_host,
		"[W5-16] the focus target is a direct child of the panel column")
	ok(m._first_focus != null and m._first_focus.focus_neighbor_bottom != NodePath(""),
		"[W5-16] Down-traversal is still wired after adding the glyph")
	m.free()


# ============================ W7-iso setpiece direction ======================
func test_iso_direction_reconciliation() -> void:
	# The projection FLIPS forward (+x) UP the screen, so a sim-space direction no longer means
	# screen-left/right. screen_dir is the render-only reconciliation any directional token must use.
	var fwd := CarView.screen_dir(Vector2i(1, 0))
	ok(fwd.y < 0.0, "[W7-iso] sim +x (forward) renders toward the UP side of the screen (the flip honored)")
	var back := CarView.screen_dir(Vector2i(-1, 0))
	ok(back.y > 0.0, "[W7-iso] sim -x renders toward the DOWN side of the screen")
	ok(CarView.screen_side_label(Vector2i(1, 0)).contains("UP"), "[W7-iso] the on-screen side label of +x contains UP")
	# WITNESS: the naive pre-flip read (sim +x == pure screen-horizontal, y==0) is contradicted.
	ok(absf(fwd.y) > 0.01, "[W7-iso] (witness) +x is NOT pure screen-horizontal — the naive left/right label mismatched the flip")
	# REAL setpiece data: the gym treadmill belt drags toward +x; its arrow must point the UP-side on screen.
	var gym = JSON.parse_string(FileAccess.get_file_as_string("res://content/cars/setpiece_gym.json"))
	var belt := _find_dir_field(gym, "beltDir")
	ok(belt != Vector2i.ZERO, "[W7-iso] the gym car authors a real conveyor beltDir (sim %s)" % str(belt))
	ok(belt != Vector2i.ZERO and CarView.screen_dir(belt).y < 0.0,
		"[W7-iso] the gym belt renders toward its intended UP-side (matches 'drags forward', not screen-right)")
	# The ski down-slope [-1,0] must render toward the DOWN side of the screen.
	var ski = JSON.parse_string(FileAccess.get_file_as_string("res://content/cars/setpiece_ski_simulator.json"))
	var slope := _find_dir_field(ski, "slope")
	ok(slope != Vector2i.ZERO and CarView.screen_dir(slope).y > 0.0,
		"[W7-iso] the ski down-slope (sim %s) renders toward the DOWN side (matches 'down-slope')" % str(slope))


func _find_dir_field(car: Dictionary, key: String) -> Vector2i:
	var layout: Dictionary = car.get("layout", {})
	for arr_key in ["hazards", "tileFields"]:
		for e in layout.get(arr_key, []):
			if e is Dictionary and e.has(key):
				var v = e[key]
				if v is Array and v.size() >= 2:
					return Vector2i(int(v[0]), int(v[1]))
	return Vector2i.ZERO


# ============================ W7-6 .uid sidecars =============================
func test_uid_sidecars_present() -> void:
	var missing: Array = []
	for dir in ["res://core", "res://app", "res://render", "res://tests"]:
		_collect_missing_uids(dir, missing)
	ok(missing.is_empty(), "[W7-6] every .gd under core/app/render/tests has a .uid sidecar (missing: %s)" % str(missing))


func _collect_missing_uids(dir: String, out: Array) -> void:
	var da := DirAccess.open(dir)
	if da == null:
		return
	da.list_dir_begin()
	var nm := da.get_next()
	while nm != "":
		var full := dir.path_join(nm)
		if da.current_is_dir():
			if not nm.begins_with("."):
				_collect_missing_uids(full, out)
		elif nm.ends_with(".gd"):
			if not FileAccess.file_exists(full + ".uid"):
				out.append(full)
		nm = da.get_next()
	da.list_dir_end()


# ============================ W7-7 stale-claim sweep ========================
func test_stale_claims_corrected() -> void:
	var sl := FileAccess.get_file_as_string("res://docs/art/ART_SHOPPING_LIST.md")
	# PRE-FIX stale claim: "project.godot has no config/icon" — corrected (the icon exists + is configured).
	ok(not sl.contains("`project.godot` has no `config/icon`"),
		"[W7-7] the stale 'no config/icon' shopping-list claim is corrected")
	var pg := FileAccess.get_file_as_string("res://project.godot")
	ok(pg.contains("config/icon="), "[W7-7] project.godot genuinely carries config/icon (the claim was stale)")
	ok(ResourceLoader.exists("res://assets/icon.svg") or FileAccess.file_exists("res://assets/icon.svg"),
		"[W7-7] the configured app icon actually exists on disk")
