class_name MetaProfile
extends RefCounted
## The cross-run META PROFILE (GDD §14 + §7.4) — everything that survives permadeath and
## persists between runs. Distinct from RunState (the per-run record): the profile is the
## *rebellion that persists* when an attempt ends.
##
##   meta_currency     : earned every run (win OR lose), spent on permanent unlocks (§14).
##   unlocked_content  : the ids of everything purchased — classes / gear / cars / recruit
##                       pools / Tail upgrades / narrative beats. SAME SHAPE the run layer
##                       already consumes: passing the FULL list (or a CarType-id subset) to
##                       RunGenerator.generate_run / Draft gates content (RunGenerator._is_unlocked
##                       treats an Array of ids as the allow-list; an EMPTY list = "everything").
##   memorial          : the Legacy roll — fallen heroes enshrined across runs (Legacy.enshrine),
##                       each carrying a name + archetype + the traits/inventory available at death.
##                       A future run may inherit ONE Legacy item or trait (Legacy.inherit, §7.4).
##   settings          : persisted options (incl. the owner-flagged in-car-fog exposure).
##   stats             : lightweight lifetime counters (runs / wins / best ending) for the menu.
##
## Pure data + serialization — RefCounted, NO SceneTree, NO rng. Meta lives OUTSIDE the integer
## sim (res://core sim invariant), so it may use Strings / Dictionaries / JSON freely; nothing
## here ever leaks a float back into RunState (the run layer coerces its own ints on load).

const SCHEMA_VERSION := 1

# Default settings. The in-car-fog exposure DEFAULTS TO ON to mirror the engine's owner-flagged
# SetpieceFog.IN_CAR_FOG_ENABLED (true) — this is the SETTINGS *exposure* of that toggle, not a
# new default. Do NOT change `in_car_fog` here without owner sign-off (ARCHITECTURE.md §67 / E1.4).
const DEFAULT_SETTINGS := {
	"in_car_fog": true,       # OWNER-FLAGGED exposure — mirrors SetpieceFog.IN_CAR_FOG_ENABLED; do not change default
	"sfx_volume": 100,        # 0..100
	"music_volume": 80,       # 0..100
	"crt_filter": true,       # the §16 ops-console CRT/scanline treatment
	"confirm_moves": true,    # require a confirm tap before committing a previewed action
	"colorblind_mode": 0,     # 0 = off; 1/2/3 = palette variants (§15 readability)
	"text_speed": 2,          # comms-log scroll speed (1 slow .. 3 fast)
	"tips_enabled": true,     # combat onboarding tips (combat-ux #7) — the global "show tips" switch
}

## Roguelite RUN HISTORY (W7-2). A small, capped log of the last runs — each a lightweight dict
## the menu's RUN HISTORY panel reads. best_ending already lives in `stats`; this adds the per-run
## record roguelite players expect. Newest is appended to the END; the log is trimmed to the last
## RUN_LOG_MAX so the profile never grows unbounded. Pure data (no sim, no rng).
const RUN_LOG_MAX := 20

var meta_currency: int = 0
var unlocked_content: Array = []   # ids unlocked (classes/gear/cars/pools/tail/narrative)
var memorial: Array = []           # Array[Dictionary] — enshrined Legacy candidates (cross-run)
var seen_tips: Array = []          # combat-onboarding tip ids already shown (combat-ux #7); reset by "reset tutorial"
var run_log: Array = []            # Array[Dictionary] — the last runs (W7-2 run history); newest last
var settings: Dictionary = {}      # persisted options
var stats: Dictionary = {          # lifetime counters (menu chrome; not sim)
	"runs": 0, "wins": 0, "best_ending": -1, "fallen": 0,
}


func _init() -> void:
	settings = DEFAULT_SETTINGS.duplicate(true)


# --- settings helpers ----------------------------------------------------------
## Read a setting with a fallback to its documented default (robust to a partial/old save).
func get_setting(key: String, fallback = null):
	if settings.has(key):
		return settings[key]
	if DEFAULT_SETTINGS.has(key):
		return DEFAULT_SETTINGS[key]
	return fallback


## Set a setting (free-form value). The menu routes every option change through here so a
## save captures the full settings dict.
func set_setting(key: String, value) -> void:
	settings[key] = value


# --- unlock helpers ------------------------------------------------------------
func is_unlocked(id: String) -> bool:
	return unlocked_content.has(id)


# --- combat-onboarding tips (combat-ux #7) -------------------------------------
## The global "combat tips" switch (a plain setting; ON by default).
func tips_enabled() -> bool:
	return bool(get_setting("tips_enabled", true))


## True if this onboarding tip has already been shown (so it never re-nags on a replay).
func tip_seen(id: String) -> bool:
	return seen_tips.has(id)


## Record that a tip has been shown. Idempotent — stored once, in first-seen order.
func mark_tip_seen(id: String) -> void:
	if not seen_tips.has(id):
		seen_tips.append(id)


## "Reset tutorial" — clear the seen set so every tip teaches again next combat.
func reset_tips() -> void:
	seen_tips.clear()


# --- run history (W7-2) --------------------------------------------------------
## Append one finished-run record to the run history (roguelite run summary/log). Called ONCE at
## end-of-run reconciliation (the run controller's _apply_finalize, after the award/enshrine/stats
## bump) so every attempt — win or loss — leaves a durable trace the menu RUN HISTORY panel reads.
## Pure append + trim-to-cap; it does NOT touch runs/wins/best_ending (those stay owned by the
## existing finalize path — no double count). `ending_id` is an E.EndingId (or LOSS/-1).
func record_run(ending_id: int, won: bool, cars: int = 0, survivors: int = 0, squad: int = 0, order: int = 0) -> void:
	run_log.append({
		"ending": int(ending_id),
		"won": bool(won),
		"cars": int(cars),
		"survivors": int(survivors),
		"squad": int(squad),
		"order": int(order),
	})
	# Trim to the last RUN_LOG_MAX (drop the oldest from the front).
	while run_log.size() > RUN_LOG_MAX:
		run_log.pop_front()


## The last `n` run records, NEWEST FIRST (the order the menu history panel lists them). A pure read.
func recent_runs(n: int = RUN_LOG_MAX) -> Array:
	var out: Array = []
	var start: int = max(0, run_log.size() - n)
	for i in range(run_log.size() - 1, start - 1, -1):
		out.append(run_log[i])
	return out


# --- serialization (round-trips identically) -----------------------------------
func to_dict() -> Dictionary:
	return {
		"schema": SCHEMA_VERSION,
		"meta_currency": meta_currency,
		"unlocked_content": unlocked_content.duplicate(),
		"memorial": memorial.duplicate(true),
		"seen_tips": seen_tips.duplicate(),
		"run_log": run_log.duplicate(true),
		"settings": settings.duplicate(true),
		"stats": stats.duplicate(true),
	}


static func from_dict(d: Dictionary) -> MetaProfile:
	var p: MetaProfile = new()
	if d == null or typeof(d) != TYPE_DICTIONARY:
		return p
	p.meta_currency = int(d.get("meta_currency", 0))
	p.unlocked_content = (d.get("unlocked_content", []) as Array).duplicate()
	p.memorial = (d.get("memorial", []) as Array).duplicate(true)
	# seen_tips are plain string ids (coerce, so a stray non-string in an old/hand-edited save is safe).
	p.seen_tips = []
	for t in (d.get("seen_tips", []) as Array):
		p.seen_tips.append(str(t))
	# Run history (W7-2) — coerce each entry's ints back (JSON round-trips numbers as float); keep only
	# the last RUN_LOG_MAX so a hand-edited/older save can never bloat the profile.
	p.run_log = []
	for r in (d.get("run_log", []) as Array):
		if typeof(r) != TYPE_DICTIONARY:
			continue
		p.run_log.append({
			"ending": int(r.get("ending", -1)),
			"won": bool(r.get("won", false)),
			"cars": int(r.get("cars", 0)),
			"survivors": int(r.get("survivors", 0)),
			"squad": int(r.get("squad", 0)),
			"order": int(r.get("order", 0)),
		})
	while p.run_log.size() > RUN_LOG_MAX:
		p.run_log.pop_front()
	# Start from the documented defaults, then overlay the saved values — so a save written by
	# an older build (missing a key we added since) still loads with every option populated.
	p.settings = DEFAULT_SETTINGS.duplicate(true)
	for k in (d.get("settings", {}) as Dictionary):
		p.settings[k] = d["settings"][k]
	# Coerce the integer-valued settings back to int (JSON round-trips numbers as float).
	for k in ["sfx_volume", "music_volume", "colorblind_mode", "text_speed"]:
		if p.settings.has(k):
			p.settings[k] = int(p.settings[k])
	var st = d.get("stats", {})
	if typeof(st) == TYPE_DICTIONARY:
		for k in ["runs", "wins", "best_ending", "fallen"]:
			if st.has(k):
				p.stats[k] = int(st[k])
	return p


## Deterministic textual fingerprint (round-trip parity, mirrors RunState.fingerprint style).
func fingerprint() -> String:
	var parts: Array = []
	parts.append("mc=%d" % meta_currency)
	var un := unlocked_content.duplicate()
	un.sort()
	parts.append("unlocked=[%s]" % ",".join(un))
	parts.append("memorial=%d" % memorial.size())
	var tp := seen_tips.duplicate()
	tp.sort()
	parts.append("tips=[%s]" % ",".join(tp))
	parts.append("runlog=%d" % run_log.size())
	var sk: Array = settings.keys()
	sk.sort()
	var sp: Array = []
	for k in sk:
		sp.append("%s=%s" % [k, str(settings[k])])
	parts.append("settings={%s}" % ",".join(sp))
	parts.append("stats=r%d/w%d/b%d/f%d" % [int(stats.get("runs",0)), int(stats.get("wins",0)), int(stats.get("best_ending",-1)), int(stats.get("fallen",0))])
	return " | ".join(parts)
