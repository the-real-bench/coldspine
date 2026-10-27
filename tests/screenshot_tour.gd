extends SceneTree
## SCREENSHOT TOUR (verification harness — ADDITIVE, edits no game file). Runs the REAL game
## WINDOWED (a display + renderer exist), drives through as many distinct screens/states as
## reachable using the SAME seams the smoke suites use (menu panel methods, the interactive
## draft/breach/econ/level-up signal handlers, InputIntent via the on-screen HUD handlers),
## and saves one PNG per state to res://build/screens/ plus a manifest.json.
##
## Run (WINDOWED — do NOT pass --headless; --save-sandbox is MANDATORY, the tour aborts without it):
##   godot --path . --script res://tests/screenshot_tour.gd --save-sandbox
##
## NOTE FOR THE LEAD: a windowed run activates real user:// writes (checkpoint saves + the
## end-of-run finalize). `--save-sandbox` (or env COLDSPINE_SAVE_SANDBOX=1) diverts ALL SaveSystem
## paths to sandbox_-prefixed files (see save_system.gd's SAVE SANDBOX seam), so the owner's real
## profile/run saves are never touched; the tour REFUSES to run without the sandbox armed.
##
## Tour shape (target-state tags TNN map to the lead's 01-27 target list; BNN = bonus states):
##   Stage 1  menu.tscn   — T01 boot mid-anim, T02 HOME, T03 MEMORIAL, T04 UNLOCKS, T05 SETTINGS
##   Stage 2  run.tscn    — T06/T07 draft, T08 breach confirm; then a SPLICED tour line (the same
##            CarInstance-splice trick screens_smoke uses) so every screen type is guaranteed
##            reachable in order: shop/recruit/event/rest (+workshop/bourgeois bonus), a security
##            combat car (entry HUD, selection, physics ghost, ability/item pickers, overwatch,
##            enemy phase, recon card, level-up), a flood car (hazards), the hedge maze (fog),
##            then the Engine Vault (antechamber, conductor countdown) -> ending card -> payout.
## Combat progression is made deterministic for the tour by thinning/erasing enemies through the
## controller's own _erase_entity seam (the run is a screenshot artifact, not a balance artifact).

const E = preload("res://core/sim_enums.gd")
const CarInstance = preload("res://core/run/car_instance.gd")
const InputIntent = preload("res://app/input_intent.gd")

const OUT_DIR := "res://build/screens"
const TOUR_DEADLINE_MS := 1200000   # 20 min hard cap — always write the manifest and exit (the deep
                                    # finale/ending/payout states need the AUTO pilot to play out several cars)

var _manifest: Array = []
var _skips: Array = []
var _shot_n: int = 0
var _t0: int = 0
var rc = null   # the live RunController (stage 2)


func _initialize() -> void:
	_t0 = Time.get_ticks_msec()
	if OS.has_feature("headless") or DisplayServer.get_name() == "headless":
		print("TOUR ABORT — this harness needs a real display (run WITHOUT --headless).")
		quit(1)
		return
	# HARNESS SAFETY (W1-9): a windowed tour writes real user:// saves. Refuse to run unless the
	# SaveSystem sandbox is armed, so a bare run can never touch the owner's real profile/run files.
	if not SaveSystem.save_sandboxed():
		print("")
		print("================================================================================")
		print("TOUR ABORT — SAVE SANDBOX NOT ARMED.")
		print("A windowed tour writes REAL user:// saves (profile + run checkpoint + seen tips).")
		print("Re-run with the flag so every save diverts to sandbox_* files:")
		print("  godot --path . --script res://tests/screenshot_tour.gd --save-sandbox")
		print("(or set the env var COLDSPINE_SAVE_SANDBOX=1)")
		print("================================================================================")
		quit(1)
		return
	_tour()


func _tour() -> void:
	await process_frame
	await process_frame
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(OUT_DIR))
	await _stage_menu()
	await _stage_run()
	_write_manifest()
	print("\nTOUR COMPLETE — %d captures, %d skips, %d ms" % [_shot_n, _skips.size(), Time.get_ticks_msec() - _t0])
	for s in _skips:
		print("TOUR-SKIP: " + s)
	quit(0)


# ============================ capture kit =====================================
func _frames(n: int) -> void:
	for i in range(n):
		await process_frame


func _secs(t: float) -> void:
	var end := Time.get_ticks_msec() + int(t * 1000.0)
	while Time.get_ticks_msec() < end:
		await process_frame


func _expired() -> bool:
	return Time.get_ticks_msec() - _t0 > TOUR_DEADLINE_MS


## Yield frames until cond() is true. Returns false (and records a skip) on timeout.
func _until(cond: Callable, timeout_s: float, what: String) -> bool:
	var end := Time.get_ticks_msec() + int(timeout_s * 1000.0)
	while Time.get_ticks_msec() < end and not _expired():
		if cond.call():
			return true
		await process_frame
	_skips.append("TIMEOUT (%ds) waiting for: %s" % [int(timeout_s), what])
	return false


## Capture the live window into NN_tag.png, self-check it (32x32 downsample, distinct colors),
## re-capture once after 10 more frames if it reads blank, and record the manifest entry.
func _capture(tag: String, desc: String) -> void:
	await _frames(5)
	_shot_n += 1
	var fname := "%02d_%s.png" % [_shot_n, tag]
	var gpath := ProjectSettings.globalize_path(OUT_DIR + "/" + fname)
	var img: Image = root.get_texture().get_image()
	img.save_png(gpath)
	var colors := _distinct_colors(gpath)
	var suspect := colors < 5
	if suspect:
		await _frames(10)
		img = root.get_texture().get_image()
		img.save_png(gpath)
		colors = _distinct_colors(gpath)
		suspect = colors < 5
	_manifest.append({
		"file": fname, "state": tag, "description": desc,
		"viewport_size": "%dx%d" % [img.get_width(), img.get_height()],
		"distinct_colors": colors, "suspect": suspect,
	})
	print("CAPTURED %s (%d distinct colors%s)" % [fname, colors, " — SUSPECT" if suspect else ""])


func _distinct_colors(gpath: String) -> int:
	var img := Image.load_from_file(gpath)
	if img == null:
		return 0
	img.resize(32, 32, Image.INTERPOLATE_BILINEAR)
	var seen: Dictionary = {}
	for y in range(32):
		for x in range(32):
			seen[img.get_pixel(x, y).to_html(false)] = true
	return seen.size()


func _write_manifest() -> void:
	var f := FileAccess.open(OUT_DIR + "/manifest.json", FileAccess.WRITE)
	if f != null:
		f.store_string(JSON.stringify(_manifest, "  "))
		f.close()
	print("MANIFEST written — %d entries." % _manifest.size())


# ============================ STAGE 1 — the ops-console menu ==================
func _stage_menu() -> void:
	var menu = load("res://app/menu.tscn").instantiate()
	root.add_child(menu)
	await _frames(2)
	if menu.get("_root") == null:
		menu._ready()   # ready was deferred (same guard menu_smoke uses)
	# T01 — the BOOT/uplink cutscene mid-animation (lines type on a 0.42s cadence).
	if bool(menu.get("_booting")):
		await _secs(1.0)
		if bool(menu.get("_booting")):
			await _capture("T01_boot_uplink", "BOOT/uplink cutscene mid-animation (typed comms lines + boot wash)")
		else:
			_skips.append("T01 boot settled before the mid-anim capture window")
	else:
		_skips.append("T01 boot never started (display gate not taken)")
	menu._finish_boot()
	await _frames(8)
	await _capture("T02_menu_home", "Menu HOME — 7 command rows, header REC/timecode, cyan status telemetry")
	menu._show_memorial()
	await _frames(4)
	await _capture("T03_memorial", "MEMORIAL — the fallen + one-pick Legacy selector (real profile data)")
	menu._show_unlocks()
	await _frames(4)
	await _capture("T04_unlocks", "UNLOCKS catalog — owned/affordable/can't-afford states from the real profile")
	menu._show_settings()
	await _frames(4)
	await _capture("T05_settings", "SETTINGS — toggles + volume sliders + CRT filter")
	menu._show_home()
	await _frames(2)
	menu.queue_free()
	await _frames(4)


# ============================ STAGE 2 — the run ===============================
func _stage_run() -> void:
	if _expired():
		return
	rc = load("res://app/run.tscn").instantiate()
	root.add_child(rc)
	await _frames(3)
	if rc.db == null:
		rc._ready()   # ready was deferred — fire the real entry point (async; it parks on the draft)
	if not await _until(func(): return rc.screens != null, 10.0, "run chrome (screens)"):
		return

	# ---- T06/T07 DRAFT + T08 BREACH ----
	if not await _until(func(): return rc._awaiting_draft, 20.0, "interactive draft surface"):
		return
	await _frames(5)
	await _capture("T06_draft_cards", "DRAFT_VETTING — 3 candidate cards, payout dial, roster slots")
	if rc.screens._card_buttons.size() > 0:
		(rc.screens._card_buttons[0] as Button).emit_signal("pressed")   # first tap = preview select
		await _frames(4)
		await _capture("T07_draft_selected", "Draft candidate SELECTED (first-tap preview highlight)")
	for i in range(3):
		if not await _until(func(): return rc._awaiting_draft, 10.0, "draft round %d" % (i + 1)):
			break
		rc._on_draft_take(0)
		await _frames(2)
	if await _until(func(): return rc._awaiting_breach, 10.0, "BREACH_CONFIRM overlay"):
		await _frames(5)
		await _capture("T08_breach_confirm", "BREACH_CONFIRM — locked 3-cell + payout x100 + GO/BACK")
		rc._on_breach_go()

	# ---- run is built: splice the tour line + stage the demo kit ----
	if not await _until(func(): return rc.run != null, 10.0, "RunState built after GO"):
		return
	_splice_line()

	# ---- econ screens (T18-T21 + bonus workshop/bourgeois) ----
	await _econ_step("shop", "T18_shop", "SHOP — black market rows with live affordability + delta chips", "commit:medkit", true)
	# a shop BUY keeps the surface open for multi-buy — leave it to resolve the car
	if await _until(func(): return rc._awaiting_econ and rc.screens._econ_screen == "shop", 10.0, "shop after the buy"):
		rc._on_choice_leave("shop")
	await _econ_step("recruit", "T19_recruit", "RECRUIT — sanctuary dossier + ACCEPT/DECLINE (accepting -> squad of 4)", "commit:accept", false)
	await _econ_step("event", "T20_event", "EVENT — scenario prompt + SAFE/RISK options", "commit:safe", true)
	await _econ_step("rest", "T21_rest", "REST — triage readout + supply-cost heal option", "commit:rest", true)
	await _econ_step("workshop", "B01_workshop", "WORKSHOP (bonus) — two upgrade rows + costs", "leave", true)
	await _econ_step("bourgeois", "B02_bourgeois", "BOURGEOIS (bonus) — the kill/spare moral fork + Order deltas", "commit:spare", false)

	# ---- first combat car: security checkpoint (T09-T15, T17, T22 + deploy bonus) ----
	await _until(func(): return rc._awaiting_deploy or (rc._active_combat and rc._awaiting_player), 40.0, "security car entry")
	if rc._awaiting_deploy:
		var lead_id: int = int(rc.run.squad[0].id)
		if not (lead_id in rc._deploy_selected) and rc._deploy_selected.size() > 0:
			rc._on_deploy_toggle(int(rc._deploy_selected[rc._deploy_selected.size() - 1]))
			rc._on_deploy_toggle(lead_id)
		await _frames(4)
		await _capture("B03_deploy_picker", "DEPLOY picker (bonus) — 4 living members for 3 tiles, commit gated at N")
		rc._on_deploy_commit()
	if not await _until(func(): return rc._active_combat and rc._awaiting_player, 30.0, "security player phase"):
		return
	await _secs(0.8)   # entry glitch + comms settle
	await _capture("T09_combat_entry", "First combat car entry — full ops HUD (recon strip, comms, palette, roster chips)")

	# T22 — recon detail card for the current car (FULL recon)
	rc.hud.show_recon_card(rc.run.position)
	await _frames(4)
	await _capture("T22_recon_card", "RECON CARD detail overlay — type/section/threats/reward for the current car")
	rc.hud.dismiss_recon_card()
	await _frames(2)

	# T10 — unit selected + action palette
	var sel_id := _lead_body_id()
	if sel_id >= 0:
		rc._select_unit_onscreen(sel_id)
		await _frames(4)
		await _capture("T10_unit_selected", "Unit selected — action palette per-AP states + targeting hint + highlight")
	else:
		_skips.append("T10: no selectable player body found")

	# T11 — physics preview ghost (shove targeting)
	await _try_ghost()

	# T12/T13 — ability + item pickers on the staged lead
	if sel_id >= 0:
		rc._select_unit_onscreen(sel_id)
		rc._on_hud_action("ABILITY")
		await _frames(4)
		await _capture("T12_ability_mode", "ABILITY picker — the unit's castable kit (gas_tap staged for the tour)")
		rc.hud.close_choice_menu()
		await _frames(2)
		rc._on_hud_action("ITEM")
		await _frames(4)
		await _capture("T13_item_mode", "ITEM picker — carried consumables (medkit staged for the tour)")
		rc.hud.close_choice_menu()
		await _frames(2)

	# T14 — overwatch armed on another unit
	var ovr_id := _first_actor_id(sel_id)
	if ovr_id < 0:
		ovr_id = sel_id
	if ovr_id >= 0:
		rc._select_unit_onscreen(ovr_id)
		rc._on_hud_action("OVR")
		await _secs(0.5)
		await _capture("T14_overwatch", "Overwatch armed — commit logged to comms, roster chip flips spent")

	# thin the fight to 1 enemy so the AUTO pilot reliably clears it, then let it play
	var foes := _live_enemies()
	for i in range(1, foes.size()):
		rc._erase_entity(rc.state, foes[i])
	rc._sync_view()
	rc._toggle_auto()   # AUTO — the deterministic pilot finishes the car (animated)
	# T15 — enemy phase mid-animation (the phase banner flips to ENEMY PHASE)
	if await _until(func(): return rc.hud.phase_banner != null and String(rc.hud.phase_banner.text).contains("ENEMY"), 25.0, "enemy phase banner"):
		await _frames(2)
		await _capture("T15_enemy_phase", "Enemy phase mid-animation — phase banner + AI acting on the feed")
	rc._cycle_speed()   # x2
	rc._cycle_speed()   # x4 — fast-forward the rest of the car
	await _until(func(): return not rc._active_combat, 120.0, "security car resolution")
	rc.sim_mode = false   # back to MANUAL before the level-up overlay / next car reads it
	if rc.hud != null:
		rc.hud.set_auto_label(false)

	# T17 — level-up pick(s) (kills + car-clear XP guarantee LV2 for the survivors)
	await _feed_levelups(true, 25.0)

	# ---- flood car (T16 hazards) ----
	await _until(func(): return rc._awaiting_deploy or (rc._active_combat and rc._awaiting_player), 40.0, "flood car entry")
	if rc._awaiting_deploy:
		rc._on_deploy_commit()
	if await _until(func(): return rc._active_combat and rc._awaiting_player, 30.0, "flood player phase"):
		await _secs(0.8)
		await _capture("T16_hazard_car", "Hazard-rich FLOOD car — standing water + water main visible on entry")
		_force_win()
	await _until(func(): return not rc._active_combat, 60.0, "flood car resolution")
	rc.sim_mode = false
	await _feed_levelups(false, 20.0)

	# ---- hedge maze (T23 in-car fog) ----
	await _until(func(): return rc._awaiting_deploy or (rc._active_combat and rc._awaiting_player), 40.0, "hedge maze entry")
	if rc._awaiting_deploy:
		rc._on_deploy_commit()
	if await _until(func(): return rc._active_combat and rc._awaiting_player, 30.0, "hedge maze player phase"):
		await _secs(0.8)
		var fog_on: bool = rc.view != null and bool(rc.view.get("fog_on"))
		await _capture("T23_fog_car", "Fog-of-war car interior (hedge maze, inCarFog=%s) — operator view limited" % str(fog_on))
		_force_win()
	await _until(func(): return not rc._active_combat, 60.0, "hedge maze resolution")
	rc.sim_mode = false
	await _feed_levelups(false, 20.0)

	# ---- the Engine Vault finale (T24/T25) -> ending (T26) -> payout (T27) ----
	if await _until(func(): return rc._in_finale and rc._awaiting_player, 60.0, "finale player phase (antechamber)"):
		await _secs(0.8)
		await _capture("T24_finale_antechamber", "Engine Vault antechamber — boss HUD, countdown clock, objective panel, turrets")
		# release round 1 so the Conductor cadence runs; catch the telegraph/countdown tick
		rc._awaiting_player = false
		var saw_telegraph: bool = await _until(func(): return rc.hud._telegraph_panel != null and rc.hud._telegraph_panel.visible, 20.0, "conductor telegraph strip")
		await _frames(3)
		await _capture("T25_conductor_countdown", "Conductor phase — bridge countdown ticking%s" % (" + telegraph strip" if saw_telegraph else " (telegraph not up this beat)"))
		rc._toggle_auto()   # AUTO resolves the vault (relays -> core) so the run always ends
	else:
		_skips.append("T24/T25: the finale phase never armed")
	if await _until(func(): return rc._run_over, 240.0, "run resolution (ending card)"):
		await _secs(1.0)
		await _capture("T26_ending_card", "Sticky ENDING CARD — tone verdict + [ENTER] after-action prompt")
		rc._advance_end_state()
		await _frames(8)
		await _capture("T27_payout_ledger", "After-action PAYOUT LEDGER — survivors/cars/order, award math, meta total")
	else:
		_skips.append("T26/T27: the run never resolved inside the tour budget")


# ============================ stage-2 helpers =================================
## Splice a guaranteed tour line at the current position (the screens_smoke _put_car trick) and
## stage a wallet + a castable ability + a usable item so every capture has real content to show.
func _splice_line() -> void:
	var specs := [
		["shop_rag_market_01", E.CarType.SHOP, "Rag Market"],
		["sanctuary_recruit_01", E.CarType.RECRUIT, "Sanctuary"],
		["event_01", E.CarType.EVENT, "Junction Fork"],
		["rest_bunkhouse_01", E.CarType.REST, "Bunkhouse"],
		["upgrade_workshop_01", E.CarType.UPGRADE, "Workshop"],
		["bourgeois_lounge_01", E.CarType.BOURGEOIS, "First-Class Lounge"],
		["combat_security_01", E.CarType.COMBAT, "Security Checkpoint"],
		["flood_water_ration_01", E.CarType.FLOOD, "Water Ration Car"],
		["setpiece_hedge_maze", E.CarType.COMBAT, "Hedge Maze"],
		["engine_conductor_vault", E.CarType.ENGINE, "Conductor's Vault"],
	]
	for i in range(specs.size()):
		var s: Array = specs[i]
		var car := CarInstance.new(String(s[0]), int(s[1]), E.Section.TAIL)
		car.name = String(s[2])
		car.recon_state = E.Recon.FULL
		if car.is_combat():
			car.threat_tags = ["security detail"]
		rc.run.line.insert(rc.run.position + i, car)
	rc.run.currency["scrip"] = 30
	rc.run.currency["supplies"] = 4
	rc.run.currency["tools"] = 3
	if rc.run.squad.size() > 0:
		var lead = rc.run.squad[0]
		if not lead.chosen_abilities.has("gas_tap"):
			lead.chosen_abilities.append("gas_tap")
		if not lead.inventory.has("medkit"):
			lead.inventory.append("medkit")
	print("TOUR: spliced %d tour cars at position %d (line now %d cars)" % [specs.size(), rc.run.position, rc.run.line.size()])


## Wait for one econ surface, optionally first-tap an option (selection re-skin), capture, then act.
func _econ_step(screen: String, tag: String, desc: String, action: String, select_first: bool) -> void:
	if not await _until(func(): return rc._awaiting_econ and rc.screens._econ_screen == screen, 30.0, screen + " surface"):
		return
	await _frames(5)
	if select_first:
		var ids: Array = rc.screens.econ_option_ids()
		if ids.size() > 0:
			rc.screens.econ_select_option(String(ids[0]))
			await _frames(3)
	await _capture(tag, desc)
	if action == "leave":
		rc._on_choice_leave(screen)
	else:
		rc._on_choice_commit(screen, action.substr(7) if action.begins_with("commit:") else action)
	await _frames(3)


func _lead_body_id() -> int:
	if rc.run.squad.size() > 0:
		var body = rc._find_body_for(rc.state, int(rc.run.squad[0].id))
		if body != null and body.alive:
			return body.id
	return _first_actor_id()


## First player body that can still act (optionally preferring one != avoid_id).
func _first_actor_id(avoid_id: int = -1) -> int:
	var fallback := -1
	for id in rc.state.entity_ids_sorted():
		var e = rc.state.entities.get(id)
		if e != null and e.is_unit and e.alive and e.faction == E.Faction.PLAYER and rc.turn.can_act(id):
			if id != avoid_id:
				return id
			fallback = id
	return fallback


func _live_enemies() -> Array:
	var out: Array = []
	for id in rc.state.entity_ids_sorted():
		var e = rc.state.entities.get(id)
		if e != null and e.is_unit and e.alive and e.faction == E.Faction.ENEMY:
			out.append(e)
	return out


## Erase every live enemy through the controller's own seam and release the player phase — the
## round settles to a clean WIN (check_victory sees no enemies). Tour-progression only.
func _force_win() -> void:
	for e in _live_enemies():
		rc._erase_entity(rc.state, e)
	rc._sync_view()
	rc._awaiting_player = false


## Feed every queued level-up pick; capture the first overlay as T17 when want_capture.
func _feed_levelups(want_capture: bool, budget_s: float) -> void:
	var captured := false
	var end := Time.get_ticks_msec() + int(budget_s * 1000.0)
	while Time.get_ticks_msec() < end and not _expired():
		if rc._awaiting_levelup:
			if want_capture and not captured:
				await _frames(5)
				await _capture("T17_levelup_pick", "LEVEL-UP overlay — 1-of-2 specialization cards for a levelled unit")
				captured = true
			var opts: Array = rc.screens.levelup_option_ids()
			if opts.size() > 0:
				rc._on_levelup_pick(String(opts[0]))
			await _frames(4)
			end = Time.get_ticks_msec() + 8000   # more picks may queue behind this one
		elif rc._awaiting_econ or rc._awaiting_deploy or rc._awaiting_player or rc._run_over or rc._in_finale:
			break   # the run moved on — no (more) picks owed
		else:
			await process_frame
	if want_capture and not captured:
		_skips.append("T17: no level-up overlay appeared inside the budget")


## T11 — arm SHOVE with a valid target so the deterministic physics preview GHOST draws.
## Tries direct adjacency first, then a one-MOVE approach to the nearest movable object/enemy,
## then falls back to capturing the MOVE targeting overlay (recorded as a partial).
func _try_ghost() -> void:
	var plan := _find_adjacent_shove()
	if plan.is_empty():
		plan = await _move_then_adjacent()
	if plan.is_empty():
		_skips.append("T11: no shovable adjacency reachable this turn — captured MOVE targeting instead")
		var pid := _first_actor_id()
		if pid >= 0:
			rc._select_unit_onscreen(pid)
			rc._on_hud_action("MOVE")
			await _frames(3)
			await _capture("T11_targeting_move", "Targeting overlay (MOVE reachable tiles) — physics ghost was unreachable this turn")
			rc._on_hud_action("CANCEL")
		return
	rc._select_unit_onscreen(int(plan.actor))
	rc._on_hud_action("SHOVE")
	await _frames(2)
	rc._on_tile_clicked(plan.cell)
	await _frames(5)
	if rc.ghost != null and rc.ghost.active:
		await _capture("T11_physics_ghost", "SHOVE targeting — the deterministic physics preview GHOST (trajectory + end cells)")
	else:
		await _capture("T11_targeting_armed", "SHOVE armed at a target (ghost inactive — preview was rejected); partial for T11")
		_skips.append("T11: shove preview did not activate the ghost (target may be anchored)")
	rc._on_hud_action("CANCEL")
	await _frames(2)


## An acting player unit already adjacent to a shovable entity (enemy unit or movable object)?
func _find_adjacent_shove() -> Dictionary:
	for id in rc.state.entity_ids_sorted():
		var me = rc.state.entities.get(id)
		if me == null or not me.is_unit or not me.alive or me.faction != E.Faction.PLAYER:
			continue
		if not rc.turn.can_act(id):
			continue
		for dir in [Vector2i(1, 0), Vector2i(-1, 0), Vector2i(0, 1), Vector2i(0, -1)]:
			var occ = rc.state.occupant_at(me.pos + dir)
			if occ != null and occ.id != id and _shovable(occ):
				return {"actor": id, "cell": occ.pos}
	return {}


func _shovable(occ) -> bool:
	if occ.is_unit:
		return occ.faction == E.Faction.ENEMY and occ.alive
	return bool(occ.get("movable"))


## MOVE one unit onto a tile adjacent to the nearest movable object/enemy (<=3 orthogonal steps),
## through the REAL on-screen click path (arm MOVE -> point -> two-tap confirm). Returns the plan.
func _move_then_adjacent() -> Dictionary:
	for id in rc.state.entity_ids_sorted():
		var me = rc.state.entities.get(id)
		if me == null or not me.is_unit or not me.alive or me.faction != E.Faction.PLAYER:
			continue
		if not rc.turn.can_act(id):
			continue
		for tid in rc.state.entity_ids_sorted():
			var tgt = rc.state.entities.get(tid)
			if tgt == null or tid == id or not _shovable(tgt):
				continue
			for dir in [Vector2i(1, 0), Vector2i(-1, 0), Vector2i(0, 1), Vector2i(0, -1)]:
				var n: Vector2i = tgt.pos + dir
				if not rc.state.in_bounds(n) or rc.state.occupant_at(n) != null:
					continue
				var d: int = abs(n.x - me.pos.x) + abs(n.y - me.pos.y)
				if d == 0:
					return {"actor": id, "cell": tgt.pos}
				if d > 3:
					continue
				rc._select_unit_onscreen(id)
				rc._on_hud_action("MOVE")
				await _frames(2)
				rc._on_tile_clicked(n)       # first tap — preview the path
				await _frames(2)
				if rc.intent.phase != InputIntent.Phase.PREVIEWING:
					rc._on_hud_action("CANCEL")
					continue
				rc._on_tile_clicked(n)       # second tap — commit (animated)
				await _secs(1.2)
				if me.pos == n:
					return {"actor": id, "cell": tgt.pos}
				rc._on_hud_action("CANCEL")
	return {}
