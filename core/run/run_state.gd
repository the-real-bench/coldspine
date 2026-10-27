class_name RunState
extends RefCounted
## The serializable, reproducible per-run record (GDD §21 RunState). It embeds the squad
## (Array[UnitInstance], the Phase-4 layer) + the Order meter + the linear line generated
## from the seed. The whole run is reproducible from (seed, input_log): regenerate the line
## from the seed, then replay the logged decisions.
##
## EXPOSES `order` as a plain int so OrderSystem.apply(run, cause, events) operates on a
## RunState directly (its `"order" in state` check + `state.order` read/write). The economy
## rails (§10) earn/spend currency with overspend guards and route moral choices through
## OrderSystem. Deep Scan / recon delegate to Recon over the line.
##
## Integer-only, RefCounted, no SceneTree. No rng is stored on the run record itself — the
## seed is the single source; subsystems (RunGenerator, Draft, combat) derive their own
## IntRng streams from it so each is independent and reproducible.

const E = preload("res://core/sim_enums.gd")
const GE = preload("res://core/game_event.gd")
const CarInstance = preload("res://core/run/car_instance.gd")
const RunGenerator = preload("res://core/run/run_generator.gd")
const Recon = preload("res://core/run/recon.gd")
const OrderSystem = preload("res://core/order_system.gd")
const UnitInstance = preload("res://core/units/unit_instance.gd")

const SCHEMA_VERSION := 1

var seed: int = 0
var input_log: Array = []              # full replay log of run decisions (Dictionaries)
var order: int = 0                     # the Order meter (§9) — OrderSystem reads/writes this
var currency: Dictionary = {           # §10 resources
	"scrip": E.STARTING_SCRIP,
	"supplies": E.STARTING_SUPPLIES,
	"tools": E.STARTING_TOOLS,
}
var squad: Array = []                  # Array[UnitInstance] (Phase-4); the living cell
var memorial: Array = []               # Array[Dictionary] — fallen heroes (Legacy candidates)
var line: Array = []                   # Array[CarInstance] — the FIXED linear train
var position: int = 0                  # index into `line` (current car)
var recon_depth: int = E.RECON_BASE_DEPTH  # how far the camera sees (next=full; Deep Scan +1)
var draft_payout_mult: int = E.DRAFT_PAYOUT_X3  # ×100 meta-currency multiplier (§7.1)
var upgrades: Array = []               # workshop upgrade ids bought this run (applied to every
                                       # deployed body at car build — progression-real batch)
var defectors: Array = []              # W7-13: Conductor's Kin that DEFECTED at a captain car
                                       # (Array[Dictionary]: unit snapshot + template_id + body x/y).
                                       # The combat state is not serialized, so a save taken mid-
                                       # betrayal persists the defection HERE; resume re-injects it
                                       # as the enemy it became (run_controller._apply_betrayal_beat).


# --- construction --------------------------------------------------------------
## Build a fresh run: generate the line from the seed, place the squad/draft payout, set
## the starting recon view. `unlocked_content` gates generation (see RunGenerator). The
## input_log starts empty — every subsequent decision appends to it for replay.
static func new_run(p_seed: int, p_squad: Array = [], p_payout_mult: int = E.DRAFT_PAYOUT_X3, unlocked_content = null) -> RunState:
	var r: RunState = new()
	r.seed = p_seed
	r.squad = p_squad.duplicate()
	r.draft_payout_mult = p_payout_mult
	r.line = RunGenerator.generate_run(p_seed, unlocked_content)
	r.position = 0
	r.recon_depth = E.RECON_BASE_DEPTH
	Recon.refresh(r)   # light up the opening recon window
	return r


# --- line / position -----------------------------------------------------------
## The car the cell is currently in (null if the run is already past the Engine = won).
func current_car():
	if position < 0 or position >= line.size():
		return null
	return line[position]


## True once `position` has advanced PAST the last car (the Engine) — the run is won.
func is_won() -> bool:
	return position >= line.size() and not line.is_empty()


## How many cars remain ahead (not counting the current one). 0 at the Engine.
func remaining() -> int:
	return max(0, line.size() - position - 1)


## Mark the current car resolved (cleared / traded / skipped). Idempotent. Logs it.
func resolve_current(events: Array = []) -> void:
	var car = current_car()
	if car == null or car.resolved:
		return
	car.resolved = true
	_log({"op": "resolve", "pos": position, "template": car.template_id})
	events.push_back(GE.new(E.Ev.CAR_RESOLVED, {"index": position, "template": car.template_id, "type": car.car_type}))


## W3-8 (event SHORTCUT): drop the immediate NEXT car from the line — a maintenance-tunnel bypass so
## advancement rolls straight past it. NEVER skips a Section-Captain gate or the Engine (both mandatory).
## Returns the skipped car's template_id, or "" if nothing was skipped. Deterministic; mutates `line`
## (serialized, so a save/resume restores the shortened line). Logs the decision for replay.
func skip_next_car(events: Array = []) -> String:
	var nxt := position + 1
	if nxt >= line.size():
		return ""
	var c = line[nxt]
	if c.car_type == E.CarType.CAPTAIN or c.car_type == E.CarType.ENGINE:
		return ""   # gates are mandatory — never bypassable
	var tid := String(c.template_id)
	line.remove_at(nxt)
	events.push_back(GE.new(E.Ev.RUN_ADVANCE, {"shortcut": tid, "position": position}))
	_log({"op": "event_shortcut", "skipped": tid, "pos": position})
	return tid


## W3-8 (event AMBUSH): route the cell into a fight NOW by injecting a real combat CarInstance directly
## after the current event car, so advancement walks straight into it. The injected car carries NO rolled
## reward (an ambush is not a payday). `section` defaults to the current car's section. Deterministic;
## mutates `line` (serialized). Returns the injected template_id. Logs the decision for replay.
func inject_combat_after_current(template_id: String, section: int = -1, events: Array = []) -> String:
	var sec := section
	if sec < 0:
		var cur = current_car()
		sec = (cur.section if cur != null else E.Section.TAIL)
	var inst := CarInstance.new(template_id, E.CarType.COMBAT, sec)
	inst.name = template_id
	inst.recon_state = E.Recon.FULL
	var at := position + 1
	if at > line.size():
		at = line.size()
	line.insert(at, inst)
	events.push_back(GE.new(E.Ev.CAR_ENTER, {"ambush": template_id, "index": at}))
	_log({"op": "event_ambush", "combat": template_id, "pos": position})
	return template_id


## Advance to the next car. Refuses to move off an unresolved combat-ish car (a fight gates
## advancement, GDD §8.3). Emits CAR_ENTER / RUN_ADVANCE, or RUN_COMPLETE when moving past
## the Engine. Refreshes recon for the new window. Returns true if it moved.
func advance(events: Array = []) -> bool:
	var car = current_car()
	if car != null and car.is_combat() and not car.resolved:
		return false   # must clear the fight first
	position += 1
	_log({"op": "advance", "pos": position})
	if position >= line.size():
		events.push_back(GE.new(E.Ev.RUN_COMPLETE, {"position": position, "cars": line.size()}))
		return true
	events.push_back(GE.new(E.Ev.RUN_ADVANCE, {"position": position}))
	events.push_back(GE.new(E.Ev.CAR_ENTER, {"index": position, "template": line[position].template_id, "type": line[position].car_type, "section": line[position].section}))
	Recon.refresh(self, events)
	return true


# --- recon delegation ----------------------------------------------------------
func refresh_recon(events: Array = []) -> void:
	Recon.refresh(self, events)

func deep_scan(events: Array = []) -> Dictionary:
	var res := Recon.deep_scan(self, events)
	if res.get("ok", false):
		_log({"op": "deep_scan", "pos": position})
	return res

func recon_visibility() -> Dictionary:
	return Recon.visibility(self)


# --- economy (§10) — earn / spend with overspend guards ------------------------
## Earn currency (positive only). Emits CURRENCY_CHANGE. `kind` in scrip/supplies/tools.
func earn(kind: String, amount: int, events: Array = []) -> void:
	if amount <= 0 or not currency.has(kind):
		return
	currency[kind] = int(currency[kind]) + amount
	events.push_back(GE.new(E.Ev.CURRENCY_CHANGE, {"kind": kind, "delta": amount, kind: currency[kind]}))


## True if the run can afford `amount` of `kind`.
func can_afford(kind: String, amount: int) -> bool:
	return currency.has(kind) and int(currency[kind]) >= amount


## Spend currency — REFUSES to overspend (returns false, no mutation). Emits
## CURRENCY_CHANGE on success. The single guard for every spend rail below.
func spend(kind: String, amount: int, events: Array = []) -> bool:
	if amount <= 0 or not can_afford(kind, amount):
		return false
	currency[kind] = int(currency[kind]) - amount
	events.push_back(GE.new(E.Ev.CURRENCY_CHANGE, {"kind": kind, "delta": -amount, kind: currency[kind]}))
	return true


## Collect the current car's rolled reward into the run (GDD §11 symbolic). draft_payout
## does NOT apply here (that multiplies META currency at run end, §7.1); in-run currency is
## granted flat. Returns the reward dict, or {} if none / already taken.
func collect_reward(events: Array = []) -> Dictionary:
	var car = current_car()
	if car == null or car.reward.is_empty():
		return {}
	var rw: Dictionary = car.reward
	var kind := String(rw.get("kind", "scrip"))
	var amount := int(rw.get("amount", 0))
	var item := String(rw.get("item", ""))
	events.push_back(GE.new(E.Ev.REWARD_GRANT, {"table": rw.get("table", ""), "kind": kind, "amount": amount, "item": item}))
	if kind in ["scrip", "supplies", "tools"]:
		earn(kind, amount, events)
	elif kind == "equipment":
		# W3-2: hand the dropped weapon/armor to the cell (auto-equipped/carried). Its passive stat /
		# rider takes effect in combat via UnitInstance.to_sim_entity -> _apply_gear_to_entity — the
		# SAME rail a shop purchase rides — so a shopless line still gears up.
		_grant_equipment(item, events)
	# "recruit" rewards are handled by the recruitment system, not the currency rail.
	_log({"op": "collect_reward", "pos": position})
	return rw


## W3-2: append a dropped equipment id to a living squad member's inventory (auto-equip/carry). The
## recipient is the FIRST living member in stable roster order (deterministic). No-op if the id is
## empty or nobody is left to carry it. Permadeath-safe (never grants to a dead member).
func _grant_equipment(item_id: String, events: Array = []) -> void:
	if item_id == "":
		return
	for u in squad:
		if u != null and not u.dead:
			u.inventory.append(item_id)
			events.push_back(GE.new(E.Ev.GEAR_DROP, {"item": item_id, "to": u.id, "reward": true}))
			return


# --- economy rails (§10) -------------------------------------------------------
## Black-Market purchase (Shop): spend scrip for a gear/consumable id. Guarded.
func market_buy(item_id: String, price: int = E.MARKET_BUY_SCRIP_COST, events: Array = []) -> bool:
	if not spend("scrip", price, events):
		return false
	events.push_back(GE.new(E.Ev.MARKET_BUY, {"item": item_id, "price": price}))
	_log({"op": "market_buy", "item": item_id, "price": price})
	return true


## Workshop/Armory upgrade: spend scrip for a squad-wide upgrade id. REAL (progression-
## real batch): the id lands in `upgrades` and run_controller._place_squad applies it to
## every deployed body (reinforced_plating +max HP; sharpened_edge +slam/shove force).
func workshop_upgrade(upgrade_id: String, price: int = E.WORKSHOP_UPGRADE_SCRIP_COST, events: Array = []) -> bool:
	if not spend("scrip", price, events):
		return false
	upgrades.append(upgrade_id)
	events.push_back(GE.new(E.Ev.WORKSHOP_UPGRADE, {"upgrade": upgrade_id, "price": price}))
	_log({"op": "workshop_upgrade", "upgrade": upgrade_id, "price": price})
	return true


## Med-car rest: spend Supplies to heal the living squad (GDD §10 / §8.3). Returns true if
## it could afford the rest. Heals each non-dead unit by REST_HEAL_AMOUNT (clamped to max).
func rest_heal(events: Array = []) -> bool:
	if not spend("supplies", E.REST_HEAL_SUPPLY_COST, events):
		return false
	var healed: int = 0
	for u in squad:
		if u != null and not u.dead:
			var before: int = u.hp
			u.hp = min(u.max_hp, u.hp + E.REST_HEAL_AMOUNT)
			healed += (u.hp - before)
	events.push_back(GE.new(E.Ev.REST_HEAL, {"healed": healed, "amount": E.REST_HEAL_AMOUNT}))
	_log({"op": "rest_heal"})
	return true


## Bourgeois encounter (§9): spare for the long game (Order down) or kill for the grab
## (scrip + Order up). Routes the Order change through OrderSystem; grants scrip on a kill.
## Returns OrderSystem's result dict.
func resolve_bourgeois(spare: bool, events: Array = []) -> Dictionary:
	var res := OrderSystem.resolve_bourgeois(self, spare, events)
	if not spare:
		earn("scrip", E.BOURGEOIS_KILL_SCRIP, events)
		res["amount"] = E.BOURGEOIS_KILL_SCRIP
	_log({"op": "bourgeois", "spare": spare})
	return res


# --- Order meter threading (§9) ------------------------------------------------
## Apply a named Order cause through OrderSystem (raises/lowers + fires thresholds).
func apply_order(cause: String, events: Array = []) -> int:
	var after := OrderSystem.apply(self, cause, events)
	_log({"op": "order", "cause": cause})
	return after


## The active difficulty tags the run scales by (reinforce / lockdown / elites), §9.
func active_order_tags() -> Array:
	return OrderSystem.active_thresholds(self)


## The reinforcement scaling the current Order implies — a ×100 multiplier + an optional
## forced-lockdown turn. The combat/AI layer reads this to make high-Order runs harder
## (GDD §9 "the system fights back when you escalate"). Integer-only.
func reinforcement_profile() -> Dictionary:
	var tags := active_order_tags()
	var mult: int = E.RUN_REINFORCE_MULT_BASE
	var lockdown_turn: int = E.RUN_LOCKDOWN_TURN_BASE
	if tags.has("reinforce"):
		mult = E.RUN_REINFORCE_MULT_HIGH
	if tags.has("lockdown"):
		lockdown_turn = E.RUN_LOCKDOWN_TURN_EARLY
	return {"reinforce_mult": mult, "lockdown_turn": lockdown_turn, "elites": tags.has("elites")}


# --- serialization (round-trips identically) -----------------------------------
func to_dict() -> Dictionary:
	var sd: Array = []
	for u in squad:
		sd.append(_unit_to_dict(u))
	var ld: Array = []
	for c in line:
		ld.append(c.to_dict())
	var out: Dictionary = {
		"schema": SCHEMA_VERSION,
		"seed": seed,
		"input_log": input_log.duplicate(true),
		"order": order,
		"currency": currency.duplicate(true),
		"squad": sd,
		"memorial": memorial.duplicate(true),
		"line": ld,
		"position": position,
		"recon_depth": recon_depth,
		"draft_payout_mult": draft_payout_mult,
		"upgrades": upgrades.duplicate(),
	}
	# W7-13: only emitted when a defection has actually happened, so every pre-existing (no-betrayal)
	# save serializes byte-identically to before.
	if not defectors.is_empty():
		out["defectors"] = defectors.duplicate(true)
	return out


static func from_dict(d: Dictionary) -> RunState:
	var r: RunState = new()
	r.seed = int(d.get("seed", 0))
	r.input_log = (d.get("input_log", []) as Array).duplicate(true)
	r.order = int(d.get("order", 0))
	r.currency = (d.get("currency", {}) as Dictionary).duplicate(true)
	# JSON text round-trips numbers as floats; currency is integer in core (no floats —
	# invariant #1). Coerce every currency value back to int on load.
	for k in ["scrip", "supplies", "tools"]:
		r.currency[k] = int(r.currency.get(k, 0))
	r.squad = []
	for ud in d.get("squad", []):
		r.squad.append(_unit_from_dict(ud))
	r.memorial = (d.get("memorial", []) as Array).duplicate(true)
	r.line = []
	for cd in d.get("line", []):
		r.line.append(CarInstance.from_dict(cd))
	r.position = int(d.get("position", 0))
	r.recon_depth = int(d.get("recon_depth", E.RECON_BASE_DEPTH))
	r.draft_payout_mult = int(d.get("draft_payout_mult", E.DRAFT_PAYOUT_X3))
	r.upgrades = (d.get("upgrades", []) as Array).duplicate()
	r.defectors = (d.get("defectors", []) as Array).duplicate(true)   # W7-13 (default [] — legacy saves)
	return r


## Deterministic textual fingerprint (golden / round-trip parity, mirrors SimState.snapshot
## style). Captures the line shape, recon, currency, order, position, squad identity.
func fingerprint() -> String:
	var parts: Array = []
	parts.append("seed=%d pos=%d depth=%d order=%d mult=%d" % [seed, position, recon_depth, order, draft_payout_mult])
	parts.append("cur=s%d/u%d/t%d" % [int(currency.get("scrip",0)), int(currency.get("supplies",0)), int(currency.get("tools",0))])
	for i in range(line.size()):
		var c = line[i]
		parts.append("C%d:%s/t%d/s%d/r%d/%s/%s/res%d" % [
			i, c.template_id, c.car_type, c.section, c.recon_state,
			str(c.modifiers), str(c.reward.get("kind","")) + str(c.reward.get("amount","")),
			1 if c.resolved else 0])
	for u in squad:
		parts.append("U%d:%s/L%d/hp%d" % [int(u.id), u.archetype_id, int(u.level), int(u.hp)])
	# Appended only when non-empty so pre-upgrade golden fixtures stay byte-identical.
	if not upgrades.is_empty():
		parts.append("UPG=" + ",".join(upgrades))
	# W7-13: only appended once a defection has persisted, so no-betrayal fingerprints are unchanged.
	if not defectors.is_empty():
		var dids: Array = []
		for dd in defectors:
			dids.append("%s@%s" % [str(dd.get("template_id", "")), str(dd.get("unit", {}).get("id", -1))])
		parts.append("DEF=" + ",".join(dids))
	return " | ".join(parts)


# --- internals -----------------------------------------------------------------
func _log(entry: Dictionary) -> void:
	input_log.append(entry)


## Snapshot a UnitInstance to plain data (self-contained — no ContentDB needed to restore
## the persistent record; combat re-derivation happens via to_sim_entity at car build time).
static func _unit_to_dict(u) -> Dictionary:
	if u == null:
		return {}
	return {
		"id": u.id, "name": u.name, "archetype_id": u.archetype_id,
		"traits": u.traits.duplicate(), "revealed_traits": u.revealed_traits.duplicate(),
		"level": u.level, "xp": u.xp, "chosen_abilities": u.chosen_abilities.duplicate(),
		"inventory": u.inventory.duplicate(), "max_hp": u.max_hp, "hp": u.hp,
		"downed": u.downed, "dead": u.dead, "faction": u.faction,
		"hidden_betrayer": u.hidden_betrayer, "betrayer_revealed": u.betrayer_revealed,
	}


static func _unit_from_dict(d: Dictionary):
	var u := UnitInstance.new()
	u.id = int(d.get("id", -1))
	u.name = String(d.get("name", ""))
	u.archetype_id = String(d.get("archetype_id", ""))
	u.traits = (d.get("traits", []) as Array).duplicate()
	u.revealed_traits = (d.get("revealed_traits", []) as Array).duplicate()
	u.level = int(d.get("level", 1))
	u.xp = int(d.get("xp", 0))
	u.chosen_abilities = (d.get("chosen_abilities", []) as Array).duplicate()
	u.inventory = (d.get("inventory", []) as Array).duplicate()
	u.max_hp = int(d.get("max_hp", 1))
	u.hp = int(d.get("hp", 1))
	u.downed = bool(d.get("downed", false))
	u.dead = bool(d.get("dead", false))
	u.faction = int(d.get("faction", E.Faction.PLAYER))
	u.hidden_betrayer = bool(d.get("hidden_betrayer", false))
	u.betrayer_revealed = bool(d.get("betrayer_revealed", false))
	return u
