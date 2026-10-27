class_name Recon
## Recon (GDD §8.2) — the operator's camera read over the FIXED line. NOT a graph
## traversal: a pure read of `recon_state` across the Array[CarInstance], driven by the
## current `position` and a `recon_depth`.
##   - the NEXT car (position+1) is FULL — type, enemies, hazards, modifiers, reward.
##   - the car AFTER (position+2) is PARTIAL — type + one threat tag, no full enemy detail.
##   - everything beyond is HIDDEN (dark) until you advance.
##   - DEEP SCAN spends Tools to push `recon_depth` out one, revealing one MORE car at FULL.
## The current car (position) is always FULL (you're standing in it).
##
## Static, integer-only, no rng, no SceneTree. Operates on a RunState-like object exposing
## `line` (Array[CarInstance]), `position` (int), `recon_depth` (int), `currency` (Dict).

const E = preload("res://core/sim_enums.gd")
const GE = preload("res://core/game_event.gd")


## Recompute recon_state for every car on the line from `position` + `recon_depth`.
## FULL window = the current car and the next `recon_depth` cars; then exactly ONE PARTIAL
## car; the rest HIDDEN. Emits a RECON_REVEAL event per car whose state changed. Idempotent.
static func refresh(run, events: Array = []) -> void:
	var line: Array = run.line
	var pos: int = run.position
	var depth: int = max(E.RECON_BASE_DEPTH, run.recon_depth)
	var full_through: int = pos + depth         # cars [pos .. full_through] are FULL
	var partial_at: int = full_through + 1       # exactly one PARTIAL beyond the full window
	for i in range(line.size()):
		var car = line[i]
		var want: int
		if i <= full_through:
			want = E.Recon.FULL
		elif i == partial_at:
			want = E.Recon.PARTIAL
		else:
			want = E.Recon.HIDDEN
		# Resolved cars behind us stay FULL (already seen) — never re-darken history.
		if i < pos:
			want = E.Recon.FULL
		if car.recon_state != want:
			car.recon_state = want
			events.push_back(GE.new(E.Ev.RECON_REVEAL, {"index": i, "state": want, "template": car.template_id}))


## Deep Scan (GDD §8.2): spend DEEP_SCAN_TOOL_COST Tools to reveal one MORE car at FULL by
## pushing recon_depth out by one, then refreshing. Returns { ok, reason?, events }.
## Refuses if Tools are insufficient or there is nothing further to reveal.
static func deep_scan(run, events: Array = []) -> Dictionary:
	var depth: int = max(E.RECON_BASE_DEPTH, run.recon_depth)
	var next_full: int = run.position + depth + 1   # the index Deep Scan would light up
	if next_full >= run.line.size():
		return {"ok": false, "reason": "nothing further to scan", "events": events}
	var tools: int = int(run.currency.get("tools", 0))
	if tools < E.DEEP_SCAN_TOOL_COST:
		return {"ok": false, "reason": "not enough tools", "events": events}
	run.currency["tools"] = tools - E.DEEP_SCAN_TOOL_COST
	run.recon_depth = depth + 1
	events.push_back(GE.new(E.Ev.DEEP_SCAN, {"cost": E.DEEP_SCAN_TOOL_COST, "revealedIndex": next_full, "tools": run.currency["tools"]}))
	events.push_back(GE.new(E.Ev.CURRENCY_CHANGE, {"kind": "tools", "delta": -E.DEEP_SCAN_TOOL_COST, "tools": run.currency["tools"]}))
	refresh(run, events)
	return {"ok": true, "revealedIndex": next_full, "events": events}


## A read for the UI/AI: the indices currently FULL and the (at most one) PARTIAL index.
static func visibility(run) -> Dictionary:
	var full: Array = []
	var partial: int = -1
	for i in range(run.line.size()):
		match run.line[i].recon_state:
			E.Recon.FULL: full.append(i)
			E.Recon.PARTIAL: partial = i
			_: pass
	return {"full": full, "partial": partial}
