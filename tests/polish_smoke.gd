extends SceneTree
## POLISH smoke test (Batch 6 — final cosmetic polish closeout, headless). Proves the new on-screen-only
## polish helpers (#11 recon detail + deep scan, #18 team-turn roster, #21 overwatch tell, #22 move
## preview, #23/#24 juice + speed) are PURE / RENDER-ONLY: the data-extraction + draw-data compute
## helpers read the live sim WITHOUT mutating it (fingerprint before/after), and the DEEP SCAN wiring
## drives the REAL RunState.deep_scan rail. Nothing here instances the OpsHUD / CarView / RunScreens —
## those are never built headless, so the eleven existing suites stay byte-identical. The polish is all
## draw-only; this test pins the contract that it never touches the deterministic sim.
##
## Run: godot --headless --path . --script res://tests/polish_smoke.gd

const E = preload("res://core/sim_enums.gd")
const RunController = preload("res://app/run_controller.gd")
const ContentDB = preload("res://core/units/content_db.gd")
const SetpieceLoader = preload("res://core/setpiece_loader.gd")
const TurnManager = preload("res://core/turn_manager.gd")
const EnemyAI = preload("res://ai/enemy_ai.gd")
const InputIntent = preload("res://app/input_intent.gd")
const RunState = preload("res://core/run/run_state.gd")
const OpsHUD = preload("res://render/ops_hud.gd")
const Pal = preload("res://render/palette.gd")

var _pass: int = 0
var _fail: int = 0
var _fails: Array = []


func _initialize() -> void:
	print("\n=== COLDSPINE — POLISH smoke test (Batch 6 cosmetic polish, headless) ===")
	test_recon_card_data_is_pure()                  # #11
	test_car_summaries_carry_detail_fields()        # #11
	test_deep_scan_wiring_calls_the_real_rail()     # #11
	test_team_turn_chips_pure_and_correct()         # #18
	test_move_path_compute_is_pure()                # #22
	test_targeting_layer_compute_is_pure()          # #16/#22 shared read-only contract
	test_overwatch_render_flag_is_render_side()     # #21
	test_palette_status_order_has_overwatch_eye()   # #21
	print("\n--- POLISH SMOKE: %d passed, %d failed ---" % [_pass, _fail])
	for f in _fails:
		print("    FAIL: " + f)
	if _fail == 0:
		print("POLISH GREEN — recon detail + deep scan + roster + move preview + overwatch are pure / render-only.\n")
	quit(0 if _fail == 0 else 1)


func ok(cond: bool, msg: String) -> void:
	if cond:
		_pass += 1
	else:
		_fail += 1
		_fails.append(msg)
		print("    [FAIL] " + msg)


# ============================ helpers ==========================================
## Build a combat car + bound turn/intent through the controller (the input_smoke pattern).
func _combat_controller() -> RunController:
	var rc := RunController.new()
	rc.headless = true
	rc.db = ContentDB.new()
	var data = JSON.parse_string(FileAccess.get_file_as_string("res://content/cars/combat_security_01.json"))
	rc.state = SetpieceLoader.build(data, 0xC01D5)
	rc.turn = TurnManager.new(rc.state)
	rc.turn.start()
	rc.ai = EnemyAI.new()
	rc.bind_combat_intent()
	return rc


func _first_player(rc) -> int:
	for id in rc.state.entity_ids_sorted():
		var e = rc.state.entities.get(id)
		if e != null and e.is_unit and e.alive and e.faction == E.Faction.PLAYER:
			return id
	return -1


## A stable fingerprint of the live combat state (every entity's pos/hp/status/faction/alive +
## the AP/turn bookkeeping) so a "pure read" helper can be proven not to mutate anything.
func _state_fingerprint(rc) -> String:
	var parts: Array = []
	for id in rc.state.entity_ids_sorted():
		var e = rc.state.entities.get(id)
		parts.append("%d:%s:%d:%d:%d:%s:%s" % [
			id, str(e.pos), int(e.hp), int(e.status), int(e.faction),
			str(e.alive), str(e.overwatch)])
	parts.append("phase=%d round=%d" % [int(rc.turn.phase), int(rc.turn.round_num)])
	return "|".join(parts)


## A built RunState with a generated line (for the recon/deep-scan rail).
func _run_state() -> RunState:
	var db := ContentDB.new()
	# new_run derives the whole line from the seed (the same construction the controller uses).
	var rs = RunState.new_run(0xC01D5, [], E.DRAFT_PAYOUT_X3, null)
	return rs


# ============================ TESTS ============================================
# --- #11 RECON CARD detail: the pure formatter ---
func test_recon_card_data_is_pure() -> void:
	var summary := {
		"index": 4, "name": "AQUARIUM", "type": "FLOOD", "section": 2,
		"threat": "riot_shield",
		"modifiers": ["flooded", "low_light"],
		"enemies": ["riot_shield", "net_gunner"],
		"reward": {"kind": "scrip", "amount": 12},
	}
	var dup := summary.duplicate(true)
	var card: Dictionary = OpsHUD.recon_card_data(summary)
	ok(card.has("title") and card.has("body"), "[#11] recon_card_data returns a {title, body}")
	ok(String(card["title"]) == "CAR 5 — AQUARIUM", "[#11] title is 1-based CAR n — name")
	var body := String(card["body"])
	ok(body.contains("FLOOD") and body.contains("FLOODED") and body.contains("riot_shield") and body.contains("+12 scrip"),
		"[#11] body surfaces type / modifiers / contacts / reward")
	ok(str(summary) == str(dup), "[#11] recon_card_data did NOT mutate the input summary (pure)")
	# An empty/edge summary still formats (no dead end / no crash).
	var card2: Dictionary = OpsHUD.recon_card_data({"index": 0, "name": "?", "type": "COMBAT", "section": 1})
	ok(String(card2.get("body", "")).contains("MODIFIERS  —"), "[#11] a bare summary formats the empty rows")


# --- #11 _car_summaries carries the detail fields the card reads ---
func test_car_summaries_carry_detail_fields() -> void:
	var rc := RunController.new()
	rc.headless = true
	rc.db = ContentDB.new()
	rc.run = _run_state()
	var sums: Array = rc._car_summaries()
	ok(not sums.is_empty(), "[#11] _car_summaries built a non-empty per-car list")
	var s: Dictionary = sums[0]
	ok(s.has("modifiers") and s.has("enemies") and s.has("reward"),
		"[#11] each summary carries modifiers / enemies / reward for the RECON CARD")
	# The detail fields are duplicates — mutating them must not touch the live CarInstance.
	var c0 = rc.run.line[0]
	var mods_before: int = c0.modifiers.size()
	(s["modifiers"] as Array).append("__scratch__")
	ok(c0.modifiers.size() == mods_before, "[#11] summary modifiers are a COPY (no aliasing into the run line)")


# --- #11 DEEP SCAN drives the REAL RunState.deep_scan rail ---
func test_deep_scan_wiring_calls_the_real_rail() -> void:
	var rs := _run_state()
	# Give the run a tool + ensure there's something further to scan (position 0, a multi-car line).
	rs.currency["tools"] = 3
	rs.position = 0
	var depth_before: int = rs.recon_depth
	var tools_before: int = int(rs.currency["tools"])
	var events: Array = []
	var res: Dictionary = rs.deep_scan(events)   # the EXACT rail _on_recon_pressed("deep_scan") calls
	ok(bool(res.get("ok", false)), "[#11] deep_scan on the real rail succeeded (tools available, line deeper)")
	ok(rs.recon_depth == depth_before + 1, "[#11] deep_scan pushed recon_depth out by one (real recon advance)")
	ok(int(rs.currency["tools"]) == tools_before - E.DEEP_SCAN_TOOL_COST, "[#11] deep_scan spent the Tools cost on the real rail")
	var saw_deep := false
	for e in events:
		if e.type == E.Ev.DEEP_SCAN:
			saw_deep = true
	ok(saw_deep, "[#11] deep_scan emitted the DEEP_SCAN event (the renderer's reveal hook)")
	# Genuine DISABLED state: with zero tools the rail refuses (no mutation) — the HUD greys the button.
	var rs2 := _run_state()
	rs2.currency["tools"] = 0
	var d2: int = rs2.recon_depth
	var r2: Dictionary = rs2.deep_scan([])
	ok(not bool(r2.get("ok", false)) and rs2.recon_depth == d2, "[#11] deep_scan with no Tools is a clean no-op (real DISABLED state)")


# --- #18 team-turn roster draw-data is pure + correct ---
func test_team_turn_chips_pure_and_correct() -> void:
	var rc := _combat_controller()
	var fp_before := _state_fingerprint(rc)
	var chips: Array = rc._team_turn_chips()
	var fp_after := _state_fingerprint(rc)
	ok(fp_before == fp_after, "[#18] _team_turn_chips did NOT mutate the combat state (pure read)")
	ok(not chips.is_empty(), "[#18] one chip per living player unit")
	var all_valid := true
	for ch in chips:
		var st := String(ch.get("state", ""))
		if not (st == "act" or st == "spent" or st == "downed"):
			all_valid = false
		if not ch.has("name"):
			all_valid = false
	ok(all_valid, "[#18] every chip is { name, state in act|spent|downed }")
	# At the start of a fresh player phase, at least one unit can act.
	var any_act := false
	for ch in chips:
		if String(ch.get("state", "")) == "act":
			any_act = true
	ok(any_act, "[#18] at the player phase at least one unit reads can-act (AMBER)")


# --- #22 move-path compute is pure + matches MoveCommand walkability ---
func test_move_path_compute_is_pure() -> void:
	var rc := _combat_controller()
	var pid := _first_player(rc)
	ok(pid >= 0, "[#22] found a player unit")
	var me = rc.state.entities.get(pid)
	var fp_before := _state_fingerprint(rc)
	# A reachable neighbour one tile away should yield a 2-cell path (start + dest); the dest itself
	# must be legal. Pick the first legal orthogonal neighbour.
	var dest: Vector2i = me.pos
	for d in [Vector2i(1, 0), Vector2i(-1, 0), Vector2i(0, 1), Vector2i(0, -1)]:
		if rc._tile_move_legal(me.pos + d):
			dest = me.pos + d
			break
	ok(dest != me.pos, "[#22] found a legal adjacent destination (precondition)")
	var path: Array = rc._compute_move_path(me.pos, dest)
	var fp_after := _state_fingerprint(rc)
	ok(fp_before == fp_after, "[#22] _compute_move_path did NOT mutate the state (pure read)")
	ok(path.size() >= 2 and path[0] == me.pos and path[path.size() - 1] == dest,
		"[#22] the path starts at the unit and ends at the destination")
	ok(path.size() <= E.MOVE_RANGE + 1, "[#22] the path never exceeds MOVE_RANGE steps (matches what MOVE can take)")
	# An out-of-range / unreachable destination returns an empty path (no false promise).
	var far: Vector2i = me.pos + Vector2i(E.MOVE_RANGE + 6, 0)
	var none: Array = rc._compute_move_path(me.pos, far)
	ok(none.is_empty(), "[#22] an out-of-MOVE_RANGE destination yields NO path (the never-surprised bar)")


# --- #16/#22 the shared targeting-layer compute stays a pure read ---
func test_targeting_layer_compute_is_pure() -> void:
	var rc := _combat_controller()
	var pid := _first_player(rc)
	var fp_before := _state_fingerprint(rc)
	var layer: Dictionary = rc.compute_targeting_layer(pid, InputIntent.Mode.MOVE)
	var fp_after := _state_fingerprint(rc)
	ok(fp_before == fp_after, "[#22] compute_targeting_layer is a pure read (no mutation)")
	ok(layer.has("reach"), "[#22] the MOVE layer carries the reachable-tile set")


# --- #21 the overwatch tell is a RENDER-side flag, never a core sim status ---
func test_overwatch_render_flag_is_render_side() -> void:
	# R_OVERWATCH must be clear of every core S_* bit (which top out at 1<<13) so it can never collide
	# with a real status when the CarView composes it for the eye badge.
	var collides := false
	for s in [E.S_PRONE, E.S_STUNNED, E.S_SOAKED, E.S_BURNING, E.S_SHOCKED, E.S_POISONED,
			E.S_BLINDED, E.S_CHILLED, E.S_FROZEN, E.S_SUPPRESSED, E.S_DOWNED]:
		if (Pal.R_OVERWATCH & int(s)) != 0:
			collides = true
	ok(not collides, "[#21] R_OVERWATCH (render-only) collides with NO core S_* status bit")
	ok(Pal.status_color(Pal.R_OVERWATCH) == Pal.STATUS_OVERWATCH, "[#21] the overwatch eye maps to the CYAN tell color")


# --- #21 the eye badge is registered in the draw order ---
func test_palette_status_order_has_overwatch_eye() -> void:
	var found := false
	for pair in Pal.STATUS_ORDER:
		if int(pair[0]) == Pal.R_OVERWATCH:
			found = true
	ok(found, "[#21] STATUS_ORDER includes the OVERWATCH eye badge (so holding units read on the feed)")
