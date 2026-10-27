class_name CombatTips
extends RefCounted
## COMBAT ONBOARDING (combat-ux #7) — the lightweight, deterministic, dismissible tip layer that
## teaches a first-time human the core loop the auto-pilot already "knows": the DISPLACE verb (the
## physics-first pitch — shove/slam an enemy INTO a wall/hazard/another body), the deterministic
## PREVIEW (what you see is what happens), cover, overwatch, the flood->electrify CHAIN, and (now
## that Stage 1 wired them) unit ABILITIES + combat ITEMS. Each tip fires ONCE, the first time it is
## relevant, then never again.
##
## This object is PURE (RefCounted, no SceneTree, no rng, no sim access): it owns only the tip
## CATALOG + the seen/enabled bookkeeping so the whole decision is unit-testable headless. The
## RunController calls should_fire()/mark_fired() at the trigger points and the OpsHUD renders the
## text — none of which touches the integer sim or the event stream (byte-identical headless).
##
## Persistence lives on MetaProfile (seen_tips[] + the `tips_enabled` setting); this wraps a snapshot
## of both. mark_fired() mutates the in-memory seen set; the controller reads seen_list() back out to
## persist via SaveSystem. A global "tips off" (tips_enabled == false) suppresses every tip; a "reset
## tutorial" clears the profile's seen_tips so they teach again.

# The tip catalog, in stable teaching order. Each entry: a short { title, body } from the design
# vocabulary (GDD §5 combat / §6.7 preview / §7.4 ally-aid). APPEND-ONLY — a new tip adds an id here
# and a trigger call in the controller; removing one would resurrect it on old saves that never saw it.
const TIPS := {
	"select": {
		"title": "SELECT A UNIT",
		"body": "Tap a squad unit, then pick an action from the palette. The % shown over an enemy is your chance to hit it.",
	},
	"displace": {
		"title": "DISPLACE — THE CORE VERB",
		"body": "COLDSPINE is won by PUSHING. SHOVE or SLAM an enemy into a wall, a gap, a hazard, or another body for free damage — positioning beats out-shooting.",
	},
	"preview": {
		"title": "PREVIEW = OUTCOME",
		"body": "The cyan ghost shows EXACTLY where bodies will land. What you preview is what happens — you are never surprised. Tap again to commit.",
	},
	"shoot": {
		"title": "SHOOTING ENDS THE TURN",
		"body": "A shot (the * mark) ENDS this unit's turn. Enemies behind cover are harder to hit — move, flank, or displace them out of cover first.",
	},
	"overwatch": {
		"title": "OVERWATCH",
		"body": "Hold fire to react: an overwatching unit shoots the first enemy that moves into its line during the enemy phase. Lock down a doorway.",
	},
	"combo": {
		"title": "CHAIN — WATER CONDUCTS",
		"body": "Flood or soak an enemy, then ELECTRIFY the tile: soaked targets take heavy shock damage. Fire, gas and water interactions chain — set them up.",
	},
	"ability": {
		"title": "UNIT ABILITIES",
		"body": "Each unit's kit adds charges, floods, hacks and heavy slams. Tap ABILITY to spend AP on one — this is your depth layer, not just guns.",
	},
	"item": {
		"title": "COMBAT ITEMS",
		"body": "Carried consumables — medkits, grenades, gadgets — are one-use. Tap ITEM to spend one this fight. Scarce, so time them.",
	},
	"stabilize": {
		"title": "A UNIT IS DOWN",
		"body": "A downed ally bleeds out in a couple of turns but is not dead yet. Stand a unit adjacent and STABILIZE (S) to buy the window to save them.",
	},
	# --- W6-5: the run-layer concepts the combat-basics set never taught (fire once, at the moment
	# they first become relevant; the RunController owns the trigger call site per concept). ---
	"order": {
		"title": "ORDER — THE MORALE METER",
		"body": "ORDER is the uprising's discipline. Reckless kills and civilian cost drop it; a low bar hardens enemies and darkens your ending. Fight clean — spare where you can.",
	},
	"captain": {
		"title": "SECTION CAPTAIN — A GATED FIGHT",
		"body": "A Captain hides behind a gimmick: hard cover, a buff aura, a sealed hatch. Break the GATE — topple the statue, flood the main, drop the buffer — and the shield falls with it.",
	},
	"betrayer": {
		"title": "A TRAITOR MAY WALK WITH YOU",
		"body": "One recruit can be the Conductor's Kin, turning at the worst moment. VET a dossier before you trust it — a Kin you expose ahead of time never gets to betray you.",
	},
	"fog": {
		"title": "IN-CAR FOG — LIMITED EYES",
		"body": "This car jams your camera net — you only see the tiles near your squad. Advance carefully; enemies wait in the dark. You can turn fog off in Settings.",
	},
	"finale": {
		"title": "THE ENGINE VAULT",
		"body": "The Conductor is shielded — shots just bounce (SHIELDED). Disable the RELAYS to drop the shield, then strike the core before the Bridge Countdown hits zero.",
	},
}

# Stable iteration order for the catalog (serialization + tests read this, not TIPS.keys()).
# APPEND-ONLY (see the header): the 9 combat-basics first, then the W6-5 run-layer concepts.
const ORDER := ["select", "displace", "preview", "shoot", "overwatch", "combo", "ability", "item", "stabilize",
	"order", "captain", "betrayer", "fog", "finale"]

var enabled: bool = true          # the global "combat tips" setting (tips_enabled); false = all off
var _seen: Dictionary = {}        # id -> true, the tips already shown (from profile.seen_tips)


## Build from a persisted seen-list + the global enabled flag (both off MetaProfile). A tip fires
## iff it is enabled AND not already in `seen`.
func _init(seen: Array = [], p_enabled: bool = true) -> void:
	enabled = p_enabled
	for s in seen:
		var id := String(s)
		if TIPS.has(id):
			_seen[id] = true


## Should this tip surface right now? True iff tips are globally enabled, the id is a real tip, and
## it has not been shown before. Pure — safe to call every palette refresh.
func should_fire(id: String) -> bool:
	return enabled and TIPS.has(id) and not _seen.has(id)


## Mark a tip as shown (== seen). Idempotent; a bogus id is ignored. The controller persists the new
## seen_list() to the profile immediately so a crash/quit never re-nags.
func mark_fired(id: String) -> void:
	if TIPS.has(id):
		_seen[id] = true


## True once every catalog tip has been shown (the tutorial is complete — nothing left to teach).
func all_seen() -> bool:
	for id in ORDER:
		if not _seen.has(id):
			return false
	return true


## The persisted seen-list, in stable catalog order (what the controller writes back to the profile).
func seen_list() -> Array:
	var out: Array = []
	for id in ORDER:
		if _seen.has(id):
			out.append(id)
	return out


func title(id: String) -> String:
	return String(TIPS.get(id, {}).get("title", ""))


func body(id: String) -> String:
	return String(TIPS.get(id, {}).get("body", ""))


## A one-line comms breadcrumb ("TIP: DISPLACE — THE CORE VERB") for the log alongside the banner.
func short(id: String) -> String:
	return title(id)
