class_name SimEnums
## Shared enums, status bitflags, and tunable constants for the deterministic sim.
## INTEGER-ONLY. No floats anywhere in res://core (GDD §17.4, Sub-Spec A).

# --- Mass tiers; the value doubles as per-tile travel cost (Sub-Spec A2/A3) ---
enum Mass { LIGHT = 1, MEDIUM = 2, HEAVY = 3, ANCHORED = 99 }

# --- Factions ---
enum Faction { PLAYER = 0, ENEMY = 1, NEUTRAL = 2, OBJECT = 3 }

# --- Terrain ---
enum Terrain { FLOOR = 0, WALL = 1 }

# --- Hazard tile types (Sub-Spec A4.5; Phase-2 cycling traps appended) ---
# APPEND ONLY — existing ordinals are load-bearing for content + the renderer.
# Phase 5 (Sub-Spec D/E) appends: CONVEYOR (E1.5 belt), LASER_SWEEP (D2.2 arc),
# SCALD (E1.2 hot tile). All > the Phase-2 ordinals so existing data is unchanged.
enum Hazard { NONE = 0, GAP = 1, FURNACE = 2, RAIL_LIVE = 3, PISTON = 4,
	VENT = 5, LASER = 6, PLATE = 7, STEAM = 8,
	CONVEYOR = 9, LASER_SWEEP = 10, SCALD = 11 }

# --- on_break effects (Sub-Spec A1 / A4.4) ---
# Phase 5 appends: TOPPLE (E1.3 line-crush), AVALANCHE (E1.6 snow-sweep trigger).
enum OnBreak { NONE = 0, FLOOD = 1, EXPLODE = 2, COLLAPSE = 3, SPILL_FIRE = 4,
	TOPPLE = 5, AVALANCHE = 6 }

# --- Effect-queue kinds (Sub-Spec A5; Phase-2 IGNITE appended) ---
# Phase 5 appends: TOPPLE (resolve a fall line-crush), AVALANCHE (snow-sweep wave).
enum Effect { FLOOD = 0, ELECTRIFY = 1, EXPLODE = 2, COLLAPSE = 3, SPILL_FIRE = 4,
	IGNITE = 5, TOPPLE = 6, AVALANCHE = 7 }

# --- Status bitflags (GDD §5.5) ---
const S_NONE       := 0
const S_PRONE      := 1 << 0
const S_STUNNED    := 1 << 1
const S_SOAKED     := 1 << 2
const S_BURNING    := 1 << 3
const S_SHOCKED    := 1 << 4
const S_POISONED   := 1 << 5
const S_BLINDED    := 1 << 6
const S_CHILLED    := 1 << 7
const S_FROZEN     := 1 << 8
const S_SUPPRESSED := 1 << 9
const S_DOWNED     := 1 << 10
const S_BLEEDING   := 1 << 11   # Phase 4: Downed AND bleeding out (revive window open, §7.4)
const S_BURIED     := 1 << 12   # Phase 5: caught by an avalanche — immobilized 1 turn (E1.6)
const S_NETTED     := 1 << 13   # Phase 5: Net Gunner immobilized this unit a turn (§12)

# --- Tile status-layer bitflags (Sub-Spec A1; Phase-2 hazard layers appended) ---
# APPEND ONLY — the renderer reads L_WATER/L_FIRE/L_ELECTRIFIED/L_DEBRIS by these bits.
const L_NONE        := 0
const L_WATER       := 1 << 0
const L_FIRE        := 1 << 1
const L_ELECTRIFIED := 1 << 2
const L_DEBRIS      := 1 << 3
const L_GAS         := 1 << 4   # poison-gas cloud (Sub-Spec D1.3)
const L_SCORCHED    := 1 << 5   # passable burnt-out tile fire leaves behind (D1.2)
const L_TELEGRAPH   := 1 << 6   # a cycling trap will FIRE here next env phase (D2)
const L_STEAM       := 1 << 7   # steam cloud: blinds + blocks LoS for a turn (D2.5)
const L_SNOW        := 1 << 8   # Phase 5: packed snow an avalanche leaves — difficult terrain (E1.6)
const L_CONCEAL     := 1 << 9   # Phase 5: concealment (underbrush/vines/canvas/steam) — blocks LoS, passable (E1.4)

# --- Tunable constants (Sub-Spec A3 — first-pass balance values) ---
const IMPACT_DIVISOR    := 2   # wall impact dmg  = M_impact / 2
const COLLISION_DIVISOR := 2   # body-vs-body dmg = M_impact / 2 (both)
const OBJECT_DIVISOR    := 1   # destructible integrity dmg = M_impact / 1
const COLLISION_DECAY   := 1   # momentum lost per body transfer (chains stay finite)
const BREAK_COST        := 2   # momentum lost smashing THROUGH a broken destructible
const PRONE_THRESHOLD   := 2   # M_impact >= 2 -> Prone
const STUN_THRESHOLD    := 4   # M_impact >= 4 -> also Stunned

const FLOOD_RADIUS_DEFAULT := 3
const WATER_DURATION       := 3
const SHOCK_DAMAGE         := 4
const FURNACE_DAMAGE       := 6
const RAIL_DAMAGE          := 4
const PISTON_DAMAGE        := 4

# --- To-hit / combat constants (GDD §5.4 — first-pass balance values) ---
# HitChance = BASE_ACCURACY − CoverPenalty − RangeFalloff + FlankBonus + StatusMods
const BASE_ACCURACY      := 75   # base % to hit at point-blank, no cover, no mods
const HALF_COVER_PEN      := 20   # half cover: −20 to be hit (§5.4)
const FULL_COVER_PEN      := 40   # full cover: −40 to be hit (§5.4)
const FLANK_BONUS         := 25   # flanking removes cover AND adds confidence
const RANGE_FALLOFF       := 5    # −per tile beyond the falloff-free band
const RANGE_FREE_TILES    := 3    # tiles within which there is no falloff penalty
const SOAKED_HIT_BONUS    := 20   # Soaked targets are easier to hit
const STUN_HIT_BONUS      := 30   # Stunned targets are easier to hit
const PRONE_HIT_BONUS     := 80   # Prone ≈ guaranteed (§5.4 "prone ≈ guaranteed")
const MIN_HIT_CHANCE      := 5    # never below 5%
const MAX_HIT_CHANCE      := 99   # never a literal certainty (unless prone-floored)
const SHOOT_DAMAGE_BASE   := 4    # fixed core ranged damage
const SHOOT_DAMAGE_VAR    := 2    # +[0..VAR] small variance band off the rng
const WEAPON_RANGE        := 6    # default ranged weapon reach (tiles)
const MOVE_RANGE          := 4    # default Move range (tiles per Move action)
const AP_PER_TURN         := 2    # base AP each unit gets per phase (§5.2)
const AP_WHEN_STUNNED     := 1    # Stunned units get reduced AP, then clear Stunned (§5.5)
const STUN_AP_PENALTY     := 1    # AP removed by being Stunned at refresh
const SHOVE_FORCE         := 5    # default Shove impulse force
const SLAM_FORCE          := 7    # Slam = higher force than Shove
const THROW_FORCE         := 5    # default Throw impulse force

# --- Phase 2: status to-hit / AP mods (GDD §5.5) ---
const SUPPRESS_HIT_PENALTY := -20  # a Suppressed SHOOTER fires with reduced accuracy
const BLIND_HIT_PENALTY    := -40  # a Blinded shooter can barely aim (§5.5)
const CHILL_HIT_PENALTY    := -10  # Chilled shooter: cold, shaky aim
const SOAKED_SELF_PENALTY  := 0    # (Soaked only helps the SHOOTER hitting a soaked target)

# --- Sub-Spec D6: hazard tunables (first-pass balance values) ---
const FIRE_DURATION       := 3    # turns a tile burns before fuel is spent
const FIRE_DAMAGE         := 3
const BURNING_LINGER      := 2    # turns Burning persists off-tile
const GAS_SPREAD_RATE     := 1    # tiles/turn the cloud expands
const GAS_MAX_RADIUS      := 4
const GAS_DURATION        := 5    # turns before the cloud fully thins
const POISON_DAMAGE       := 2
const POISON_LINGER       := 2    # turns Poisoned persists after leaving gas
const POISON_ACC_PENALTY  := -15  # to-hit while Poisoned (the SHOOTER's penalty)
const VENT_PERIOD         := 2    # fire-vent cycle
const LASER_PERIOD        := 2    # laser cycle (grid toggle / sweep step)
const STEAM_PERIOD        := 2    # steam-vent cycle
const PLATE_PERIOD        := 2    # electrified-plate on/off cycle
const PISTON_PERIOD       := 2    # piston slam cycle
const TRAP_TELEGRAPH      := 1    # turns of warning (all cycling traps)
const EXPLOSION_DAMAGE    := 6
const EXPLOSION_FORCE     := 4    # radial impulse magnitude (fed to Sub-Spec A)
const EXPLOSION_RADIUS    := 2
const FROZEN_THRESHOLD    := 2    # Chilled stacks reaching this -> Frozen (skip-turn)
const STEAM_DURATION      := 2    # turns a steam cloud lingers on a tile

# --- Phase 5: Sub-Spec E set-piece extensions (E1) + new hazards (D). First-pass. ---
# Terrain physics (E1.1): friction modifies per-tile momentum cost; slope adds/saps it.
const FRICTION_ICE        := 0    # ice: a forced move costs 0 momentum -> slides full length
const FRICTION_NORMAL     := 1    # sentinel for "no friction field set" (cost = mass, default)
const FRICTION_SNOW       := 2    # deep snow/soft soil: +1 momentum cost + difficult terrain
const SLOPE_MOMENTUM      := 1    # downhill: +M before paying tile cost; uphill: -M (E1.1)
const SCALD_DAMAGE        := 4    # Scalded hot-tile: damage on enter/stand; cancels cold (E1.2)
const AVALANCHE_RADIUS    := 3    # snow-sweep wave radius (reuses flood machinery, E1.6)
const AVALANCHE_DAMAGE    := 2    # impact of the snow front
const BURIED_TURNS        := 1    # turns an avalanche-buried unit is immobilized (dig out = 1 AP)
const NET_TURNS           := 1    # turns a Net Gunner immobilizes a unit
const CONVEYOR_FORCE      := 1    # the 1-tile drift a belt applies each env phase (E1.5)
const TOPPLE_DAMAGE       := 4    # line-crush impact damage along a felled object's length (E1.3)
const CHILL_MOVE_PENALTY  := -1   # Chilled: -Move (read by movement; first-pass)

# --- Phase 5: enemy AI profile codes (string<->int bridge; data uses the strings). ---
# aiProfile in content/enemies decides the per-unit policy in ai/ai_profiles.gd.
enum AIProfile {
	MELEE_RUSH = 0, RANGED_HOLD = 1, FLANKER = 2, SUPPORT = 3, ROBOT = 4,
}
const AI_PROFILE_NAMES := {
	"melee_rush": AIProfile.MELEE_RUSH, "ranged_hold": AIProfile.RANGED_HOLD,
	"flanker": AIProfile.FLANKER, "support": AIProfile.SUPPORT, "robot": AIProfile.ROBOT,
}

# --- Phase 5: enemy physics-trait codes (data-driven off EnemyDef.physicsTrait). ---
# These hook the resolver's impulse path (shove resistance) and combat math.
enum PhysTrait {
	NONE = 0,
	BLOCKS_FRONTAL_SHOVE = 1,    # Riot Shield: resists impulse coming at its facing
	UNSHOVABLE_UNTIL_SOAKED = 2, # immovable unless S_SOAKED (Tail Warden / Chief / Conductor key)
	MAGNETIC_BOOTS = 3,          # shove resistance (force reduced before it moves them)
	HACKABLE = 4,                # Security Robot: convertible via Hack
	STATIC_DESTRUCTIBLE = 5,     # Sentry Turret: immobile, destructible, LoS-deniable
}
const PHYS_TRAIT_NAMES := {
	"blocks_frontal_shove": PhysTrait.BLOCKS_FRONTAL_SHOVE,
	"unshovable_until_soaked": PhysTrait.UNSHOVABLE_UNTIL_SOAKED,
	"magnetic_boots": PhysTrait.MAGNETIC_BOOTS,
	"hackable": PhysTrait.HACKABLE,
	"static_destructible": PhysTrait.STATIC_DESTRUCTIBLE,
	# Captain keys that reuse the shove gate / their own gate behaviors:
	"buffs_nearby_guards": PhysTrait.NONE,
	"immune_until_gas_cleared": PhysTrait.NONE,
	"shielded_until_cover_stripped": PhysTrait.NONE,
}

const MAGNETIC_BOOTS_RESIST := 2   # magnetic boots subtract this from an incoming shove force

# --- Event vocabulary (Sub-Spec A9): resolver -> renderer timeline ---
# NOTE: APPEND ONLY. The physics members must keep their existing ordinals so the
# golden physics fixtures stay stable; new Phase 0-i members are added at the end.
enum Ev {
	MOVE_STEP, IMPACT_WALL, COLLIDE_BODY, OBJECT_DAMAGED, OBJECT_BREAK,
	FLOOD_TILE, SHOCK, HAZARD_FURNACE, HAZARD_RAIL, HAZARD_PISTON,
	EJECT, STATUS_APPLY, STATUS_CLEAR,
	# --- Command / turn events (Phase 0-i) ---
	MOVE, ATTACK_SHOOT, HIT, MISS, UNIT_DOWNED, UNIT_DEATH, STAND_UP,
	OVERWATCH_SET, TURN_PHASE, RUN_WIN, RUN_LOSE,
	# --- Phase 2: tactics + Sub-Spec D hazards (APPEND ONLY) ---
	OVERWATCH_TRIGGER,        # an armed overwatcher reacts to an enemy entering its fire lane
	FIRE_SPREAD, FIRE_OUT,    # fire propagates to a flammable tile / a tile burns out
	GAS_SPREAD, GAS_CLEAR,    # gas cloud expands into a tile / a tile thins clear
	IGNITE, EXPLOSION,        # gas+ignition marker; the resulting one-shot blast over a volume
	EXTINGUISH, DISPERSE,     # water beats fire on a tile / water disperses gas on a tile
	BURN_TICK, POISON_TICK,   # per-turn DoT applications during the environment phase
	FREEZE, THAW,             # Chilled stacked to Frozen / heat thawed a Frozen unit
	TRAP_TELEGRAPH, TRAP_FIRE,# a cycling trap warns / fires this env phase
	SUPPRESS,                 # area/overwatch fire pins a unit (S_SUPPRESSED)
	# --- Phase 4: squad + progression (Sub-Spec C). APPEND ONLY. ---
	ABILITY_USE,              # a data-defined AbilityDef fired (validate->apply->emit)
	BLEED_TICK,               # a Downed (Bleeding) unit lost a turn off its bleed-out window
	UNIT_STABILIZED,          # a Steward/ally stopped the bleed; the unit survives Downed
	UNIT_PERMADEATH,          # bleed-out expired / finished off -> permanent death (run)
	GEAR_DROP,                # a dead unit's gear dropped on its tile (recoverable)
	MEMORIAL_ADD,             # a fallen hero enshrined as a Legacy candidate
	XP_GAIN, LEVEL_UP,        # XP awarded / a unit leveled and must pick 1-of-2
	ABILITY_PICKED,           # the level-up choice was resolved into chosenAbilities
	DRAFT_OFFER, DRAFT_TAKE, DRAFT_DECLINE, DRAFT_DONE,  # the Draft flow (§7.1)
	RECRUIT_JOIN,             # an in-run recruit joined the cell (§8.4 / C4)
	ORDER_CHANGE, ORDER_THRESHOLD,  # the Order meter moved / crossed a data-driven threshold
	BETRAYAL,                 # a Conductor's Kin defected/sabotaged under its trigger (C3.5)
	HEAL, GRANT_AP, CLEANSE,  # support ability outcomes
	# --- Phase 3: run structure + economy (GDD §8 / §10). APPEND ONLY. ---
	RUN_GENERATED,            # the linear line was generated from the seed (§8.2)
	CAR_ENTER,                # the run advanced INTO a car (position moved onto it)
	CAR_RESOLVED,             # the current car was marked resolved (cleared / traded / skipped)
	RUN_ADVANCE,             # position moved to the next car (post-resolve)
	RUN_COMPLETE,             # position advanced past the Engine — the run is won
	RECON_REVEAL,             # a car's recon_state changed (next=full / +1=partial / Deep Scan)
	DEEP_SCAN,                # Tools spent to reveal one more car at FULL (§8.2)
	CURRENCY_CHANGE,          # scrip/supplies/tools earned or spent (§10)
	REWARD_GRANT,             # a car's rolled reward was collected into the run
	SHOP_BUY, WORKSHOP_UPGRADE, MARKET_BUY, REST_HEAL,  # economy rails (§10)
	# --- Phase 5: enemies + set-piece cars (Sub-Spec D/E). APPEND ONLY. ---
	TOPPLE,                   # a tall destructible fell (E1.3) — a line-crush follows
	CRUSH,                    # a toppled object crushed a tile (impact + Prone)
	AVALANCHE,                # a snow-sweep front swept the car (E1.6)
	BURY, DIG_OUT,            # avalanche buried a unit / a buried unit dug free
	SCALD,                    # a unit took scald damage on a hot tile (E1.2)
	BELT_DRIFT,               # a conveyor belt drifted an entity one tile (E1.5)
	SLOPE_SLIDE,              # an unsupported entity slid downhill on the gravity tick (E1.1)
	CONCEAL_BLOCK,            # a concealment tile broke a line of sight (E1.4)
	NET,                      # a Net Gunner immobilized a unit
	SHOVE_RESISTED,           # a physics trait (frontal-block / unshovable / magnetic) ate a shove
	CAPTAIN_BUFF, CAPTAIN_BUFF_DROP,  # a captain buffed nearby guards / lost the buff (key resolved)
	CAPTAIN_SHIELD, CAPTAIN_SHIELD_DROP,  # a captain's gate is up / was opened (its physicsKey met)
	BOT_DEPLOY,               # a support enemy deployed a bot / turret
	FOG_REVEAL,               # in-car fog lifted on a tile the squad can now see (E1.4)
	# --- Phase 6: the Conductor's Chamber finale (Sub-Spec B). APPEND ONLY. ---
	DAMAGE_SHIELDED,          # a gated entity shrugged off damage (its key condition unmet) — the Conductor's relay shield, captain gates
	VAULT_PHASE,             # the Engine Vault advanced an arena phase (antechamber -> conductor -> core-exposed)
	RELAY_DISABLED,           # a Relay was destroyed: drops one Core shield stack + disables its mapped Conductor power (B3.2)
	CONDUCTOR_POWER_DISABLED, # a Conductor room-power was disabled by its mapped Relay falling
	CONDUCTOR_TELEGRAPH,      # the Conductor surfaced next turn's pending action (one-turn warning, B3.3)
	CONDUCTOR_ACT,            # the Conductor resolved its previously-telegraphed action
	CORE_SHIELD, CORE_SHIELD_DROP,  # the Engine Core's shield is up (a Relay online) / dropped (all down or Conductor dead)
	CORE_DAMAGED, CORE_SABOTAGED,   # the exposed Core took integrity damage / hit 0 = the train is stopped (objective met)
	COUNTDOWN_TICK,           # the Bridge Countdown advanced one round (toward the point of no return)
	COUNTDOWN_EXPIRED,        # the Bridge Countdown hit 0: good endings lock out, escalation begins (B2.2)
	VAULT_ESCALATE,           # a post-countdown escalation fired (extra piston bank / faster cycles / double Deploy)
	DISPENSER_SPAWN, DISPENSER_DOWN,  # a Robot Dispenser emitted a Security Robot / was destroyed (its spawns stop)
	ENDING_RESOLVED,          # the finale resolved an ending id from (Order x clock x survivors x choices), B6
	# --- Sim-correctness fix batch (2026-07-01). APPEND ONLY. ---
	HACKED,                   # a hack converted a robot/turret (a real event, not a STATUS_APPLY pseudo-event)
	# --- Progression-real batch (2026-07-02). APPEND ONLY. ---
	CHARGE_PLACED,            # a Saboteur rigged a demolition charge on a tile
	CHARGE_DETONATED,         # a rigged charge fired (fuse expiry or Remote Detonate)
	BUFF_APPLY, BUFF_EXPIRE,  # a timed stat buff (rally/warcry) landed on / wore off a unit
	SPAWNED,                  # a unit/object entered play mid-combat (junction, reinforcement, sympathizer)
	ITEM_USED,                # a consumable item resolved through UseItemCommand (validate->apply->emit)
	TRAPS_DISABLED,           # System Seizure froze every cycling trap for N env phases
	EXPOSURE_TICK,            # a car-modifier per-turn exposure (Open Roof cold) ticked the squad
	# --- Wave 3b: Firebrand momentum meter (Sub-Spec C2.5). APPEND ONLY. ---
	MOMENTUM_CHANGED,         # a Firebrand's momentum stacks moved (car-clear gain / ally-death loss or burst)
}

# --- Turn phases (Phase 0-i) ---
enum Phase { PLAYER = 0, ENEMY = 1, ENVIRONMENT = 2 }

# ============================================================================
# Phase 4 — Squad & progression (Sub-Spec C). First-pass balance values.
# ============================================================================

# --- Permadeath / bleed-out (§7.4) ---
# A unit at 0 HP becomes Downed (Bleeding) for BLEED_OUT_TURNS environment phases.
# A Steward/adjacent ally may Stabilize within that window; otherwise it permadies,
# drops gear, and goes to the Memorial. The Steward buys WINDOWS, not immortality.
const BLEED_OUT_TURNS   := 2     # named const X (§7.4 "Downed (Bleeding) for X turns")
const TRIAGE_BONUS_TURNS := 1    # Steward "Triage" extends the window squad-wide

# --- XP / leveling (§7.3) ---
const XP_PER_KILL       := 10
const XP_PER_OBJECTIVE  := 15
const XP_PER_MERCY      := 8     # XP from sparing / a mercy outcome (§9)
const XP_PER_LEVEL      := 20    # XP threshold per level (level N needs N*XP_PER_LEVEL)
const MAX_LEVEL         := 4     # 3 tree tiers + capstone (Sub-Spec C2)

# --- The Draft (§7.1 / C1) ---
const DRAFT_ROUNDS         := 3   # up to 3 rounds, 3 candidates each
const DRAFT_CANDIDATES     := 3   # candidates per round
const DRAFT_MAX_STARTERS   := 3   # 1..3 starters
# draftPayoutMult by starters drafted (×100 to stay integer): 3->100, 2->125, 1->160.
const DRAFT_PAYOUT_X3      := 100
const DRAFT_PAYOUT_X2      := 125
const DRAFT_PAYOUT_X1      := 160

# --- Recruitment (§8.4 / C4) ---
const SQUAD_SOFT_CAP       := 4
const SQUAD_HARD_CAP       := 5

# --- The Order meter (§9). A run-wide int; thresholds gate difficulty. ---
const ORDER_MAX                  := 100
const ORDER_CIVILIAN_KILL        := 15   # killing a civilian / Bourgeois (loud, cruel)
const ORDER_LOUD_BREACH          := 8    # a loud breach (gunfire-heavy / explosive entry)
const ORDER_CRUELTY              := 10   # an execution / finishing a Downed enemy
const ORDER_MERCY_DROP           := 6    # mercy / sparing lowers Order
const ORDER_CLEAN_FIGHT_DROP     := 3    # a clean (physics-only, no-civ-kill) car
const ORDER_THRESHOLD_REINFORCE  := 30   # >= : tougher reinforcements
const ORDER_THRESHOLD_LOCKDOWN   := 60   # >= : earlier lockdowns
const ORDER_THRESHOLD_ELITES     := 85   # >= : the Conductor deploys elites sooner

# --- OWNER-FLAGGED, DO-NOT-TUNE toggle (ARCHITECTURE.md §67 / Sub-Spec C3.5) ---
# Betrayer (Conductor's Kin) DENSITY: the per-recruit probability (in PERCENT) that a
# rolled recruit secretly carries the hidden Conductor's Kin trait. This is the single
# clearly-named constant the owner flagged as revisitable. DO NOT TUNE without asking.
# (The drafted pool keeps it lower-or-equal; recruits are the uncontrolled path.)
const BETRAYER_DENSITY_PCT := 8   # OWNER-FLAGGED — do not change without sign-off

# ============================================================================
# Phase 3 — Run structure & economy (GDD §8 + §10). APPEND ONLY.
# First-pass balance values; all generation/rolls draw from a seeded IntRng.
# ============================================================================

# --- Car types (GDD §8.3 / §21 CarTemplate.type). String<->enum bridge below. ---
# The ordinals are stable; CAR_TYPE_NAMES maps to the content/cars JSON "type" string.
enum CarType {
	COMBAT = 0, FLOOD = 1, UPGRADE = 2, BOURGEOIS = 3, RECRUIT = 4,
	EVENT = 5, REST = 6, SHOP = 7, CAPTAIN = 8, ENGINE = 9,
}
const CAR_TYPE_NAMES := {
	"combat": CarType.COMBAT, "flood": CarType.FLOOD, "upgrade": CarType.UPGRADE,
	"bourgeois": CarType.BOURGEOIS, "recruit": CarType.RECRUIT, "event": CarType.EVENT,
	"rest": CarType.REST, "shop": CarType.SHOP, "captain": CarType.CAPTAIN,
	"engine": CarType.ENGINE,
}

# --- Sections (GDD §8.1). 1..5; Tail -> Engine. Captain gates each break. ---
enum Section { TAIL = 1, THIRD = 2, SECOND = 3, FIRST = 4, ENGINE = 5 }
const SECTION_ORDER := [Section.TAIL, Section.THIRD, Section.SECOND, Section.FIRST, Section.ENGINE]

# --- Recon visibility of a car on the line (GDD §8.2). ---
# HIDDEN = dark; PARTIAL = type + one threat tag; FULL = type+enemies+hazards+mods+reward.
enum Recon { HIDDEN = 0, PARTIAL = 1, FULL = 2 }

# --- Run generation shape (GDD §8.1 "~3-5 cars/section -> ~15-25 total"). ---
const RUN_SECTIONS              := 5    # Tail / Third / Second / First / Engine
const CARS_PER_SECTION_MIN      := 3    # functional cars before the Section Captain
const CARS_PER_SECTION_MAX      := 5    # inclusive; the Engine section is the finale car only
const RECON_BASE_DEPTH          := 1    # next car FULL; the car after is PARTIAL (read over line)

# --- Economy (GDD §10). Integer currency; earn/spend rails. ---
const DEEP_SCAN_TOOL_COST       := 1    # Tools to hijack one more camera at FULL (§8.2)
const REST_HEAL_SUPPLY_COST     := 1    # Supplies a Med-car rest spends to heal the squad
const REST_HEAL_AMOUNT          := 4    # HP restored per unit by a rest (first-pass)
# Post-combat "regroup": after CLEARING a non-captain fight, the surviving cell catches its
# breath between cars — each living unit recovers up to this much HP (clamped to max) and a
# stabilized-Downed comrade is helped back to its feet, free of Supplies. Balance lever
# (Playability pass): the launch line has no guaranteed Rest before a Section-Captain gate, so
# without between-fight recovery a cell spirals on cumulative attrition and wipes regardless of
# how each fight went. A near-full regroup makes EACH ENCOUNTER the real test (per-fight
# difficulty) instead of attrition-roulette — it does NOT touch enemy stats (every fight is just
# as lethal; many seeds still lose individual fights), and CAPTAIN + ENGINE cars grant NO regroup
# so the gates stay punishing. 99 == "heal to full" (clamped to max_hp). Set to 0 to disable.
# BALANCE DIAL (Batch-5 Stage 2, 2026-07-02) — HELD at 99; PROXY-BOT FLOOR CONFIRMED, escalated.
# Intent was 99 -> 4 (restore scarcity; 4 == REST_HEAL_AMOUNT). Re-swept 200 seeds each AFTER the
# Batch-5 Stage-1 ordinary-combat competence landed (real balance_telemetry.gd stdout, base 0,
# re-run twice byte-identical):
#     regroup 99 -> 0/200 (0.0%)   [2 caps reached by 19 runs, 3 caps by 6]
#     regroup  8 -> 0/200 (0.0%)   [2 caps by 17, 3 caps by 5 — strictly shallower]
#     regroup  4 -> 0/200 (0.0%)   [2 caps by 11, 3 caps by  2 — shallower still]
# Lowering regroup monotonically REDUCES captain-depth and never lifts the win-rate, so the
# contingent dial cannot drop. The 8% acceptance gate is unreachable by the PROXY auto-pilot at ANY
# regroup, so per the Stage-2 mandate the value is HELD at 99 (keeps balance_smoke's honest natural
# win seed 0x61E alive — a full-line LIBERATION/HARD-STOP with NO enemy weakened).
# Stage-1 DID improve ordinary survival vs the Batch-4 baseline (real telemetry, same window):
# tail_warden 71->58, combat_security_02 40->31, combat_security_01 23->15, bunk_stacks 18->15,
# and runs reaching >=2 captains rose. But 109/200 still die at 0 captains and captain_s1_tail_warden
# is still the single deadliest room (58) — the cell arrives at the S1 gate already DEPLETED (units
# dead upstream; regroup heals HP, cannot resurrect), so it loses a gate it clears ~90% fresh.
# WHY THE FLOOR IS BOT-DUMBNESS, NOT OVER-TUNED ENEMIES (crisp verdict for owner):
#   (a) A genuine natural full-line win EXISTS at these EXACT enemy stats (balance_smoke 0x61E) —
#       the content is provably winnable, not impossible.
#   (b) Audit balance-ai #7: the authored S1->S4 curve is "sane on paper"; section-1 losses are a
#       "bot-skill artifact, not data mistuning"; the only real authored spike is setpiece_spa.
#   (c) Audit balance-ai #0: the pilot issues ZERO AbilityCommand/ThrowCommand, makes no volatile-
#       object physics plays into enemies, and has no captain-key solve for the gas/cover captains —
#       four whole capability classes a human uses that the proxy lacks; it also pays a turn of fire
#       to take cover. THIS is the residual gap, not enemy stats.
# So combat is VALIDATED-WINNABLE; the ~0% proxy win-rate is a bot-capability FLOOR. The honest next
# lever is teaching the pilot abilities/items/throws + captain-key physics (audit balance-ai #0, M),
# NOT weakening enemies or inflating the squad (both forbidden here) and NOT dropping the regroup.
# DESIGN-PANEL DECISION (2026-07-04) — LANDED at W6-1 (2026-07-05): the between-car regroup is now a
# PARTIAL heal (POST_COMBAT_REGROUP_PCT % of each unit's max), and the standup is DECOUPLED from it —
# a stabilized-Downed comrade ALWAYS gets back up at REGROUP_STANDUP_HP (independent of the heal, so 0
# can never strand them). Attrition now COMPOUNDS forward (the scarcity/forward-only pillar). The flip
# waited for the W6-1 pilot arming (abilities/items) so balance_smoke could re-green; 0x71B wins at 50%.
# POST_COMBAT_REGROUP_HP is LEGACY (the old full-heal value) — kept for reference; not the active heal.
const POST_COMBAT_REGROUP_HP    := 99   # LEGACY (old full heal); superseded by POST_COMBAT_REGROUP_PCT
const POST_COMBAT_REGROUP_PCT   := 50   # ACTIVE between-car heal: ceil(max_hp*PCT/100) per living unit
const REGROUP_STANDUP_HP        := 2    # a revived stabilized-Downed comrade stands at this fixed HP
const WORKSHOP_UPGRADE_SCRIP_COST := 6  # Workshop/Armory upgrade base price (scrip)
const MARKET_BUY_SCRIP_COST     := 5    # Black-Market default purchase price (scrip)
const BOURGEOIS_KILL_SCRIP      := 12   # scrip grabbed by killing a Bourgeois (raises Order)
const STARTING_SCRIP            := 0
const STARTING_SUPPLIES         := 1
const STARTING_TOOLS            := 1

# --- Reward roll bands (deterministic from a car's rewardTable id + the run seed). ---
# Rewards are symbolic (no authored reward-table data files yet, GDD §11 pending) — a
# rolled {kind, amount} keyed off the table id. Content can later swap in real tables.
const REWARD_SCRIP_MIN          := 4
const REWARD_SCRIP_MAX          := 12
const REWARD_SUPPLY_MIN         := 1
const REWARD_SUPPLY_MAX         := 3
const REWARD_TOOL_MIN           := 1
const REWARD_TOOL_MAX           := 2

# Map an engine threshold tag (OrderSystem) to a reinforcement scaling step the run
# generator / AI reads to make high-Order runs tougher (§9). Integer multipliers ×100.
const RUN_REINFORCE_MULT_BASE   := 100  # < reinforce threshold
const RUN_REINFORCE_MULT_HIGH   := 125  # >= reinforce
const RUN_LOCKDOWN_TURN_BASE    := 99   # no forced lockdown
const RUN_LOCKDOWN_TURN_EARLY   := 4    # >= lockdown threshold: reinforcements by this turn

# ============================================================================
# Phase 6 — The Conductor's Chamber finale (Sub-Spec B). APPEND ONLY.
# Integer-only, first-pass balance values. Determinism: every cadence/timer below
# is purely deterministic (no rng); only gunfire ever touches the PRNG.
# ============================================================================

# --- The Bridge Countdown (B2.2 — pressure, not instant-fail) ---
const BRIDGE_COUNTDOWN_DEFAULT := 10    # rounds before the train passes the point of no return
const ACCELERATE_STEP          := 1     # the Conductor's Accelerate ability advances the clock by this

# --- The Engine Core objective (B1/B2) ---
const CORE_INTEGRITY_DEFAULT   := 12    # the Core's integrity; reduce to 0 (once exposed) to win
const RELAY_INTEGRITY_DEFAULT  := 6     # each of the 3 Relays' integrity
const DISPENSER_INTEGRITY_DEFAULT := 5  # each of the 2 Robot Dispensers' integrity
const SABOTAGE_CHARGE_DAMAGE   := 8     # a Saboteur charge's flat Core integrity damage (heavy action)

# --- The Vault arena phases (B2.3) ---
enum VaultPhase { ANTECHAMBER = 0, CONDUCTOR_ACTIVE = 1, CORE_EXPOSED = 2 }

# --- The Conductor's room-power ids (B3.2 relay->power mapping). String<->int bridge. ---
# Relay A (Pistons) disables RE_ROUTE_PISTON; Relay B (Plates) disables RE_ROUTE_PLATE;
# Relay C (Dispensers) disables DEPLOY. Killing the Conductor disables them all.
enum ConductorPower { RE_ROUTE_PISTON = 0, RE_ROUTE_PLATE = 1, DEPLOY = 2, OVERCHARGE = 3, ACCELERATE = 4 }

# --- The Conductor's telegraphed actions (B3.1 ability kit) ---
enum ConductorAction { NONE = 0, RE_ROUTE = 1, DEPLOY = 2, OVERCHARGE = 3, ACCELERATE = 4, LOCKDOWN = 5 }

const OVERCHARGE_DAMAGE        := 6     # the Core-system strike on the most-exposed unit (telegraphed)
const ROBOT_SPAWN_HP           := 6     # a dispenser-spawned Security Robot's HP
const ROBOT_SPAWN_INTEGRITY    := -1    # spawned robots are units (hp-based), not objects

# --- B7 scripted-object role tags (engine instantiates these as SimEntities). ---
# Carried on entity.name so the vault/objective can find them without new fields.
const OBJ_RELAY            := "relay"
const OBJ_ROBOT_DISPENSER  := "robot_dispenser"
const OBJ_ENGINE_CORE      := "engine_core"
const OBJ_CONTROL_DAIS     := "control_dais"

# --- The endings (B6). resolve_ending() returns one of these. ---
enum EndingId {
	LOSS = 0,           # squad wipe at any point — the only hard failure
	HARD_STOP = 1,      # low Order + Core sabotaged before the countdown (the bleak, faithful resolution)
	SEIZE_ENGINE = 2,   # low Order + captured (not killed) the Conductor + survived (ambiguous new order)
	PYRRHIC = 3,        # high Order, OR missed the countdown, OR heavy squad losses (won, but gutted)
	LIBERATION = 4,     # hidden: fully-merciful run (low Order + full surviving squad + enough citizens recruited)
}

# --- Ending gate thresholds (B6 / §9). First-pass; integer-only. ---
const ENDING_LOW_ORDER_MAX     := 40    # Order at/below this counts as a "low-Order" (merciful-leaning) run
const ENDING_LIBERATION_RECRUITS := 2   # citizens recruited across the run needed for the hidden Liberation ending
const ENDING_PYRRHIC_LOSSES    := 2     # squad members lost (dead) at/above this -> the win is Pyrrhic

# --- Progression-real batch (2026-07-02): authored stats + upgrades made real. ---
# Workshop upgrades (run.upgrades ids applied to every deployed body at car build):
const WORKSHOP_PLATING_HP      := 2     # reinforced_plating: +max HP (and +current) per body
const WORKSHOP_EDGE_FORCE      := 1     # sharpened_edge: +slam/shove force per body
# Saboteur demolition charges (rig / remote_detonate):
const CHARGE_FUSE_TURNS        := 1     # env phases before a rigged charge auto-fires
# Car-modifier reinforcements (Lockdown) + sympathizer stats (conservative first-pass):
const SYMPATHIZER_HP           := 6     # spawned neutral-assist fighter (Sympathizers modifier)
const SYMPATHIZER_ACCURACY     := 55
const SUPPLY_DROP_ITEM         := "medkit"  # what a Supply Drop modifier stocks (per count)

# ============================================================================
# Wave 3b — Firebrand momentum meter + Steward Last Stand (Sub-Spec C2.5 / C2 T3).
# Integer-only, deterministic; first-pass balance values. Momentum is a per-Firebrand
# tempo dividend: gained each car cleared, buffs damage/move (and accuracy via Zeal),
# lost when an ally permadies (UNLESS Martyr's Wake flips the loss into a burst), and at
# MAX arms the Vanguard first-strike autocrit. All state is int/bool on the SimEntity.
# ============================================================================
const MOMENTUM_MAX            := 3    # cap on a Firebrand's momentum stacks
const MOMENTUM_PER_CAR        := 1    # stacks gained per car the cell clears (each living Firebrand)
const MOMENTUM_DMG_PER_STACK  := 1    # +weapon damage per stack (baked at car entry)
const MOMENTUM_MOVE_THRESHOLD := 2    # stacks needed before the +Move bonus kicks in
const MOMENTUM_MOVE_BONUS     := 1    # +Move range once at/above the threshold
const MOMENTUM_ACC_PER_STACK  := 5    # Zeal: +to-hit per stack (only if Zeal is picked)
const MOMENTUM_CRIT_BONUS     := 4    # Vanguard: extra damage on the guaranteed first-strike crit
const MARTYRS_WAKE_GAIN       := 3    # Martyr's Wake default burst on an ally's death (data may override)
const LAST_STAND_TURNS        := 2    # env phases a Last-Stand-revived body survives to take its one action
