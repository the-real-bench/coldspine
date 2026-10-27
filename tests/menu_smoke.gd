extends SceneTree
## MENU smoke test (Batch 6 — the ops-console main menu, headless). Proves the Batch-6 cosmetic
## polish on app/menu.gd is correct AND headless-safe WITHOUT a display:
##
##   #25 BOOT/UPLINK — headless never builds the boot cutscene (no _boot node, _booting stays false,
##       no scanline overlay, set_process off); HOME is shown immediately so the menu-load + suites
##       stay byte-clean. Skippability is asserted at the unit level (the skip predicate cuts to HOME).
##   #26 HOME CHROME — the menu builds; HOME populates the 7 command rows; the header REC/timecode +
##       cyan status telemetry exist; CONTINUE's empty state (no save) disables the button + tags it.
##   #27 UNLOCKS/SETTINGS UX — affordable/owned/can't-afford logic is correct (a too-cheap-only buy
##       enables only the affordable rows; an OWNED entry stops being a buy); a purchase persists +
##       decrements currency; the CRT toggle re-applies the (absent, headless) overlay without error;
##       a volume slider write keeps the INT model (set_setting coerces, round-trips int).
##   SIM PATH — `_wants_sim()` reads the flag; the New-Run handoff stages the unlocked content +
##       legacy WITHOUT needing a display (the self-play launch path is exercised up to _goto).
##
## The menu is NEVER instanced by the other suites; this is the only headless menu coverage. It
## instances the REAL menu.tscn into the tree (so _ready fires) and pokes its public state.
##
## Run: godot --headless --path . --script res://tests/menu_smoke.gd

const Menu = preload("res://app/menu.gd")
const MetaProfile = preload("res://core/meta/meta_profile.gd")
const Unlocks = preload("res://core/meta/unlocks.gd")
const Legacy = preload("res://core/meta/legacy.gd")
const Pal = preload("res://render/palette.gd")

var _pass: int = 0
var _fail: int = 0
var _fails: Array = []


func _initialize() -> void:
	print("\n=== COLDSPINE — MENU smoke test (ops-console main menu, headless) ===")
	test_menu_builds_and_home_populates()
	test_boot_is_headless_safe()
	test_skip_predicate_cuts_to_home()
	test_header_telemetry_present()
	test_continue_empty_state_disabled()
	test_continue_enabled_with_save()
	test_unlocks_affordability_states()
	test_purchase_persists_and_decrements()
	test_crt_toggle_reapplies_overlay_no_error()
	test_volume_keeps_int_model()
	test_sim_flag_detection()
	# W1 wave additions (overflow/ESC, seed policy, legacy staging). The sim handoff test stays
	# LAST (its _on_new_run may end in a deferred scene change — see its note).
	test_panel_scrolls_and_esc_backs_out()
	test_ascii_poc_feed_and_back_edge()
	test_run_seed_policy()
	test_new_run_stages_legacy_without_burning()
	test_sim_path_stages_handoff()
	print("\n--- MENU SMOKE: %d passed, %d failed ---" % [_pass, _fail])
	for f in _fails:
		print("    FAIL: " + f)
	if _fail == 0:
		print("MENU GREEN — ops-console menu builds, boot is headless-safe + skippable, unlock/settings logic correct, --sim still launches.\n")
	quit(0 if _fail == 0 else 1)


func ok(cond: bool, msg: String) -> void:
	if cond:
		_pass += 1
	else:
		_fail += 1
		_fails.append(msg)
		print("    [FAIL] " + msg)


# ============================ harness =========================================
## Instance the REAL menu into the tree so _ready fires (loads the profile, builds the UI, takes the
## headless HOME path). Returns the live menu Control. Caller frees it.
func _menu() -> Control:
	var m := Control.new()
	m.set_script(Menu)
	root.add_child(m)
	# In SceneTree._initialize the node-ready notification is deferred, so _ready hasn't fired yet —
	# invoke it explicitly (the menu's build + profile-load entry point). Single call, no double-build.
	m._ready()
	return m


## Count the buttons currently in the menu's panel host (the live command/row list).
func _panel_buttons(m) -> Array:
	var out: Array = []
	if m._panel_host == null:
		return out
	for c in m._panel_host.get_children():
		if c is Button:
			out.append(c)
	return out


func _find_button(m, substr: String) -> Button:
	for b in _panel_buttons(m):
		if String(b.text).contains(substr):
			return b
	return null


# ============================ #26 HOME builds =================================
func test_menu_builds_and_home_populates() -> void:
	var m := _menu()
	ok(m.profile != null, "menu builds: profile loaded on entry")
	ok(m._root != null and m._panel_host != null, "menu builds: root + panel host constructed")
	ok(m._active_panel == "home", "menu builds: HOME is the active panel after _ready")
	# HOME has the 8 command rows (NEW RUN / CONTINUE / MEMORIAL / RUN HISTORY / UNLOCKS / SETTINGS /
	# ASCII POC / QUIT). RUN HISTORY was added in W7-2 (run summary/log surface).
	ok(_panel_buttons(m).size() == 8, "HOME populates 8 command buttons (got %d)" % _panel_buttons(m).size())
	ok(_find_button(m, "NEW RUN") != null, "HOME has a NEW RUN button")
	ok(_find_button(m, "RUN HISTORY") != null, "HOME has a RUN HISTORY button")
	ok(_find_button(m, "SETTINGS") != null, "HOME has a SETTINGS button")
	m.free()


# ============================ #25 BOOT headless-safe ==========================
func test_boot_is_headless_safe() -> void:
	var m := _menu()
	ok(not m._has_display(), "headless: _has_display() is false")
	ok(not m._booting, "BOOT: headless never enters the booting state")
	ok(m._boot == null, "BOOT: headless builds NO boot cutscene node")
	ok(m._scanlines == null, "CHROME: headless builds NO scanline overlay (display-gated)")
	ok(not m.is_processing(), "BOOT: headless leaves _process OFF (no timecode tick)")
	m.free()


## The skip predicate (#25): a key/click press while booting must cut to HOME. We assert the
## decision logic directly (the same branch _input uses) so the headless test needs no real input.
func test_skip_predicate_cuts_to_home() -> void:
	var m := _menu()
	# Simulate the booting state, then drive _finish_boot (the skip target) and confirm it settles.
	m._booting = true
	m._finish_boot()
	ok(not m._booting, "SKIP: _finish_boot clears the booting state (cut to HOME)")
	ok(m._active_panel == "home", "SKIP: settling lands on HOME")
	# Idempotent — a second finish (auto-complete racing the skip) is a no-op, not a crash.
	m._finish_boot()
	ok(not m._booting, "SKIP: _finish_boot is idempotent (skip + auto-complete can't double-fire)")
	m.free()


# ============================ #26 header telemetry ============================
func test_header_telemetry_present() -> void:
	var m := _menu()
	ok(m._rec_label != null and String(m._rec_label.text).contains("REC"), "HEADER: REC dot present")
	ok(m._timecode_label != null, "HEADER: timecode label present")
	ok(m._status_line != null and String(m._status_line.text).contains("META-CURRENCY"),
		"HEADER: cyan status telemetry populated")
	m.free()


func test_continue_empty_state_disabled() -> void:
	# A fresh profile with NO mid-run save: CONTINUE is disabled + tagged NO SAVE (empty state).
	var m := _menu()
	var cont := _find_button(m, "CONTINUE")
	ok(cont != null, "CONTINUE: button present on HOME")
	if cont != null and not SaveSystem_has_save():
		ok(cont.disabled, "CONTINUE: disabled when no resumable save (empty state)")
		ok(String(cont.text).contains("NO SAVE"), "CONTINUE: empty state tagged 'NO SAVE'")
	else:
		# A save exists on this dev box — assert the inverse so the test is still meaningful.
		ok(cont != null and not cont.disabled, "CONTINUE: enabled when a save exists")
	m.free()


func test_continue_enabled_with_save() -> void:
	# Drive the HOME builder under a profile and assert the gate is exactly has_run_save() — the
	# logic is consumed from SaveSystem (we don't write a save here to avoid touching user://).
	var m := _menu()
	var cont := _find_button(m, "CONTINUE")
	ok(cont != null and cont.disabled == (not SaveSystem_has_save()),
		"CONTINUE: enabled-state tracks SaveSystem.has_run_save() exactly")
	m.free()


# ============================ #27 UNLOCKS states =============================
func test_unlocks_affordability_states() -> void:
	var m := _menu()
	# Stage a known wallet: enough for the cheapest unlock (Conductor's Log @15) but not the dearest.
	m.profile = MetaProfile.new()
	m.profile.meta_currency = 15
	m._show_unlocks()
	var cheap := _find_button(m, "Conductor's Log")
	var dear := _find_button(m, "Firebrand")   # cost 60 — unaffordable at 15
	ok(cheap != null and not cheap.disabled, "UNLOCKS: an affordable buy is enabled")
	ok(dear != null and dear.disabled, "UNLOCKS: an unaffordable buy is disabled (can't-afford state)")
	m.free()
	# OWNED (fresh menu — _clear_panel's queue_free is deferred, so a re-render in the same
	# synchronous frame would leave stale buy-buttons in the tree; a clean instance avoids the race).
	var m2 := _menu()
	m2.profile = MetaProfile.new()
	m2.profile.meta_currency = 15
	m2.profile.unlocked_content.append("narrative_conductor_log")
	m2._show_unlocks()
	ok(_find_button(m2, "Conductor's Log") == null, "UNLOCKS: an OWNED entry is no longer a buy button")
	# It IS present as a DIM OWNED stamp Label (not a dead end).
	var owned_label := false
	for c in m2._panel_host.get_children():
		if c is Label and String(c.text).contains("Conductor's Log") and String(c.text).contains("OWNED"):
			owned_label = true
	ok(owned_label, "UNLOCKS: the OWNED entry renders as an OWNED stamp")
	m2.free()


func test_purchase_persists_and_decrements() -> void:
	var m := _menu()
	m.profile = MetaProfile.new()
	m.profile.meta_currency = 100
	var before: int = m.profile.meta_currency
	# Buy the cheapest unlock through the menu's own _on_buy (the real purchase rail).
	m._on_buy("narrative_conductor_log")
	ok(m.profile.is_unlocked("narrative_conductor_log"), "PURCHASE: the unlock is recorded")
	ok(m.profile.meta_currency == before - Unlocks.cost("narrative_conductor_log"),
		"PURCHASE: currency decremented by the cost")
	ok(m._purchase_flash_id == "", "PURCHASE: the success flash is consumed on re-render (not sticky)")
	m.free()


func test_crt_toggle_reapplies_overlay_no_error() -> void:
	var m := _menu()
	# Flipping crt_filter must re-apply the (headless: absent) overlay without erroring.
	m.profile = MetaProfile.new()
	m._on_toggle("crt_filter")
	ok(m.profile.get_setting("crt_filter") == false, "SETTINGS: CRT toggle flipped the setting")
	ok(m._scanlines == null, "SETTINGS: CRT toggle is headless-safe (no overlay to drive)")
	m.free()


func test_volume_keeps_int_model() -> void:
	var m := _menu()
	m.profile = MetaProfile.new()
	# The slider hands a float; the row coercer must store an INT (the preserved value model).
	m._on_slider_changed("sfx_volume", 65, null)
	var v = m.profile.get_setting("sfx_volume")
	ok(typeof(v) == TYPE_INT and v == 65, "SLIDER: volume write keeps the INT model (got %s)" % str(v))
	# Clamp guard: out-of-range coerces into 0..100.
	m._on_slider_changed("music_volume", 250, null)
	ok(int(m.profile.get_setting("music_volume")) == 100, "SLIDER: volume clamps to 100")
	m.free()


# ============================ W1-2 overflow + ESC =============================
## Long panels must SCROLL inside the 720px canvas (stretch canvas_items/keep can never reveal
## overflow by resizing) and ESC/ui_cancel must return every sub-panel to HOME — no dead-end
## panels, and ESC NEVER quits the app.
func test_panel_scrolls_and_esc_backs_out() -> void:
	var m := _menu()
	# Structural guard: the panel host lives inside an EXPAND_FILL ScrollContainer.
	ok(m._panel_scroll != null and m._panel_host.get_parent() == m._panel_scroll,
		"W1-2: the panel host lives inside a ScrollContainer")
	ok(m._panel_scroll.size_flags_vertical == Control.SIZE_EXPAND_FILL,
		"W1-2: the scroll region EXPAND_FILLs the leftover canvas height")
	# Row-count vs canvas math: a fresh profile's UNLOCKS panel (header + 14 rows + BACK at
	# 40px + 8px separation) outgrows the ~520px left under the header block — the exact
	# overflow that used to push `< BACK` off the 720px canvas.
	m.profile = MetaProfile.new()
	m._show_unlocks()
	var rows: int = 0
	for c in m._panel_host.get_children():
		if not c.is_queued_for_deletion():   # _clear_panel's queue_free is deferred
			rows += 1
	ok(rows * 48 > 720 - 196,
		"W1-2: the UNLOCKS panel needs the scroll (%d rows x 48px vs ~524px window)" % rows)
	ok(_find_button(m, "< BACK") != null, "W1-2: UNLOCKS keeps a < BACK row (reachable via scroll)")
	# ESC policy: any sub-panel -> HOME; HOME -> a deliberate no-op (never quit from a key).
	ok(m._handle_cancel(), "W1-2: ESC from UNLOCKS navigates")
	ok(m._active_panel == "home", "W1-2: ESC lands on HOME")
	m._show_memorial()
	ok(m._handle_cancel() and m._active_panel == "home", "W1-2: ESC from MEMORIAL returns HOME")
	m._show_settings()
	ok(m._handle_cancel() and m._active_panel == "home", "W1-2: ESC from SETTINGS returns HOME")
	ok(not m._handle_cancel(), "W1-2: ESC on HOME is a no-op (does NOT quit the app)")
	m.free()


# ============================ W1-4 ASCII POC back edge ========================
## The ASCII POC is no longer a blank-window dead end: the feed mirrors into an on-screen
## buffer (stdout stays byte-identical) and a back edge to the menu exists. Headless proof:
## run_poc on an UN-TREED instance (_ready — and its headless quit — never fires).
func test_ascii_poc_feed_and_back_edge() -> void:
	var Main = load("res://app/main.gd")
	var poc = Main.new()   # not added to the tree
	poc.run_poc()
	ok(poc._feed_lines.size() > 20,
		"W1-4: the POC feed mirrors into the on-screen buffer (%d lines)" % poc._feed_lines.size())
	var joined := "\n".join(PackedStringArray(poc._feed_lines))
	ok(joined.contains("CAR CLEARED"), "W1-4: the POC still clears the car by displacement")
	ok(String(Main.MENU_SCENE) == "res://app/menu.tscn" and ResourceLoader.exists(Main.MENU_SCENE),
		"W1-4: the back edge targets the real menu scene (FLOW: ASCII_POC -> S1_01_HOME)")
	ok(poc.has_method("_build_onscreen_feed") and poc.has_method("_input"),
		"W1-4: the on-screen feed panel + back input affordances exist")
	poc.free()


# ============================ W1-5 run-seed policy ============================
## Headless/--sim stagings keep run_seed -1 (the controller's fixed DEFAULT_SEED stays
## byte-stable for every suite), while the simulated player path rolls fresh distinct seeds.
func test_run_seed_policy() -> void:
	var m := _menu()
	m.profile = MetaProfile.new()
	m._on_new_run()
	ok(Menu.MenuHandoff.run_seed == -1,
		"W1-5: a headless NEW RUN stages run_seed -1 (controller keeps 0xC01D5)")
	ok(Menu.pick_run_seed(false) == -1, "W1-5: no display -> keep the default seed")
	var s1: int = Menu.pick_run_seed(true)
	var s2: int = Menu.pick_run_seed(true)
	ok(s1 >= 0 and s1 <= 0xFFFFFFFF, "W1-5: the player path rolls a real 32-bit seed")
	ok(s1 != s2, "W1-5: two player-path NEW RUN stagings get DIFFERENT seeds")
	var seen: Dictionary = {}
	for i in range(8):
		seen[Menu.roll_fresh_seed()] = true
	ok(seen.size() >= 2, "W1-5: fresh rolls vary (the second playthrough is not the first)")
	# m intentionally not freed: _on_new_run ends in _goto (a headless no-op) — same pattern as
	# test_sim_path_stages_handoff; quit() tears everything down at suite end.


# ============================ W1-7 legacy staging =============================
## NEW RUN stages the armed Legacy (payload + Memorial hero id) WITHOUT burning it — the burn
## happens at BREACH finalize in the controller, so an ESC-abandoned draft leaves the profile
## untouched and the hero re-armable (FLOW: the pre-breach exit is safe).
func test_new_run_stages_legacy_without_burning() -> void:
	var m := _menu()
	m.profile = MetaProfile.new()
	var stored: Dictionary = Legacy.enshrine(m.profile, {"id": 9, "instance_id": 9,
		"name": "Vasquez", "archetype": "bruiser", "traits": ["tough"], "inventory": ["field_kit"]})
	var lid := String(stored["legacy_id"])
	m._chosen_legacy_id = lid
	m._on_new_run()
	ok(String(Menu.MenuHandoff.legacy_payload.get("id", "")) == "field_kit",
		"W1-7: NEW RUN stages the legacy payload")
	ok(Menu.MenuHandoff.legacy_id == lid,
		"W1-7: NEW RUN stages the Memorial hero id for the BREACH burn")
	ok(Legacy.available(m.profile).size() == 1,
		"W1-7: the hero is NOT burned at NEW RUN click (abandon costs nothing)")
	ok(String(Legacy.inherit(m.profile, lid).get("id", "")) == "field_kit",
		"W1-7: the legacy stays re-armable after an abandoned draft")
	# m intentionally not freed (same _on_new_run pattern as above).


# ============================ --sim path =====================================
func test_sim_flag_detection() -> void:
	var m := _menu()
	# The real process wasn't launched with --sim, so _wants_sim is false here; assert the API exists
	# and is false (the menu-load test path), proving it doesn't spuriously auto-launch a run.
	ok(not m._wants_sim(), "SIM: _wants_sim false without the flag (menu-load never auto-launches)")
	m.free()


## The --sim self-play proof: even though we can't pass the CLI flag mid-test, the launch path the
## sim takes (_on_new_run) must stage the handoff from the profile WITHOUT a display. We call it
## directly and assert the static MenuHandoff was populated (the run will read it). _goto no-ops on
## a missing scene, so this is safe headlessly (run.tscn exists, but change_scene is deferred).
func test_sim_path_stages_handoff() -> void:
	var m := _menu()
	m.profile = MetaProfile.new()
	m.profile.unlocked_content = ["setpiece_aquarium", "firebrand"]
	m._chosen_legacy_id = ""
	m._on_new_run()
	ok(Menu.MenuHandoff.unlocked_car_ids == ["setpiece_aquarium"],
		"SIM: NEW RUN staged the unlocked CAR allow-list from the profile")
	ok(Menu.MenuHandoff.unlocked_class_ids.has("firebrand"),
		"SIM: NEW RUN staged the unlocked CLASS pool from the profile")
	ok(Menu.MenuHandoff.resume_run == null, "SIM: NEW RUN clears any stale resume save")
	# NOTE: _on_new_run ends in _goto -> change_scene_to_file (DEFERRED). We do NOT free the menu
	# here: freeing would null its tree before that deferred call runs. run.tscn exists, so the
	# deferred change is harmless; quit() tears everything down at suite end. (Run this test LAST.)


# ============================ helpers =========================================
## SaveSystem.has_run_save() proxy (the menu consumes it; we read it the same way for the assertions).
func SaveSystem_has_save() -> bool:
	var ss = load("res://core/meta/save_system.gd")
	return ss.has_run_save()
