class_name SimEntity
extends RefCounted
## A unit OR an interactive object. Plain RefCounted, no SceneTree deps.
## Units use `hp` (integrity = -1); objects use `integrity` (hp = -1).

const E = preload("res://core/sim_enums.gd")

var id: int = 0
var name: String = ""
var pos: Vector2i = Vector2i.ZERO
var mass: int = E.Mass.MEDIUM
var movable: bool = true
var hp: int = 1
var integrity: int = -1            # objects only; -1 for pure units
var faction: int = E.Faction.NEUTRAL
var cover: int = 0                 # 0 none / 1 half / 2 full
var status: int = 0                # status bitflags (S_*)
var on_break: int = E.OnBreak.NONE
var break_param: int = 0           # e.g. flood radius / explosion radius
var is_unit: bool = false
var is_power_source: bool = false  # a live junction the Saboteur can rig
var alive: bool = true

# --- Phase 2 state (status timers, resistances, overwatch). All integer/bool. ---
var burn_timer: int = 0            # turns of Burning left (refreshed on a fire tile; lingers off it)
var poison_timer: int = 0          # turns of Poisoned left (lingers POISON_LINGER off the cloud)
var chill_stacks: int = 0          # Chilled stacks; reaching FROZEN_THRESHOLD -> Frozen
var blind_timer: int = 0           # turns of Blinded left
var suppress_timer: int = 0        # turns of Suppressed left
var poison_immune: bool = false    # gas mask / Iron Lungs / Rebreather (Sub-Spec C)
var fireproof: bool = false        # reduced fire damage (Sub-Spec C)
var flammable: bool = false        # objects: wood/cloth/oil — fire spreads onto them (D1.2)
var overwatch: bool = false        # armed reaction: fires during the ENEMY phase on lane entry
var overwatch_used: bool = false   # one reaction shot per arming

# --- Phase 4 state (squad + progression, Sub-Spec C). Integer/bool only. ---
var instance_id: int = -1          # back-link to the persistent UnitInstance (-1 = transient)
var archetype_id: String = ""      # which archetype kit this combat body came from
var traits: Array = []             # the persistent unit's trait ids, stamped on by UnitInstance.to_sim_entity so the bleed-out/Memorial site can enshrine a real trait legacy (§7.4)
var downed: bool = false           # at 0 HP but not yet permanently dead (revive window)
var bleed_timer: int = 0           # env phases left before permadeath (BLEED_OUT_TURNS at down)
var dead: bool = false             # permadeath confirmed (Memorial candidate)
var gear: Array = []               # equipped gear ids; dropped on the tile on permadeath
var hidden_betrayer: bool = false  # secretly carries Conductor's Kin (unrevealed)
var betrayer_revealed: bool = false# a Saboteur scan / vetting exposed the loyalty risk
var betrayed: bool = false         # has already fired its defection beat (once per unit)
var shove_immune: bool = false     # Bruiser Bracing / Juggernaut etc. (set by passives)
var prone_immune: bool = false     # Juggernaut: immune to Prone
var slam_force_bonus: int = 0      # Juggernaut: +force on this unit's slams (passive hook)
var guardian_protocol: bool = false# Steward capstone: survive a lethal hit at 1 HP once/fight

# --- Phase 5: enemy roster + captains + set-piece objects (Sub-Spec D/E). APPEND ONLY. ---
var ai_profile: int = E.AIProfile.MELEE_RUSH   # which ai/ai_profiles policy drives this enemy
var phys_trait: int = E.PhysTrait.NONE         # data-driven shove-resistance / robot trait
var facing: Vector2i = Vector2i(-1, 0)  # the way a unit faces (Riot Shield frontal block); default toward the tail (-x)
var captain_key: String = ""        # a Section Captain's physicsKey (its puzzle gate)
var captain_gate_open: bool = false # the captain's gate has been resolved (key met)
var buried_timer: int = 0           # turns immobilized by an avalanche (E1.6)
var net_timer: int = 0              # turns immobilized by a Net Gunner
var unaware: bool = false           # E1.7 ambush-start: hasn't woken to the fight yet
# Toppling objects (E1.3): a felled tall destructible crushes a line of `topple_height`.
var fall_dir: Vector2i = Vector2i.ZERO  # the direction it falls (ZERO = away-from-impact)
var topple_height: int = 0          # length of the line-crush; 0 = a normal break

# --- Phase 6: the Conductor's Chamber finale (Sub-Spec B). APPEND ONLY. ---
var conductor_shielded: bool = false  # the Conductor's relay-shield: TRUE => can_take_damage gates damage off
var is_finale_boss: bool = false      # this entity is the Conductor (the AIPatternController drives it)
var pending_action: int = E.ConductorAction.NONE  # the telegraphed action that resolves next Conductor phase
var captured: bool = false            # the Conductor was captured (not killed) — the Seize-the-Engine path

# --- Sim-correctness fix batch (2026-07-01). APPEND ONLY. ---
var max_hp: int = -1                  # heal ceiling; stamped at spawn (SimState.add_entity / UnitInstance.to_sim_entity); -1 = unset (legacy uncapped)
var buffed_by_captain_id: int = -1    # which captain's guard-buff HP this unit carries (-1 = none) — a real field, never a gear tag that could leak into drops

# --- Progression-real batch (2026-07-02): authored stats + passives on the body. APPEND ONLY. ---
var accuracy: int = -1             # authored to-hit base (archetype/enemy stats + trait/gear mods); -1 = unset -> E.BASE_ACCURACY
var move_range: int = -1           # authored Move range (stats.move); -1 = unset -> E.MOVE_RANGE
var damage_bonus: int = 0          # flat bonus weapon damage (Bloodthirsty/Reckless traits, Reckless ability)
var self_recoil: int = 0           # damage the shooter takes per attack (Reckless ability)
var ignore_cover_level: int = 0    # Pierce: subtracted from the target's effective cover level
var first_hit_reduced: int = 0     # Hardened / Riot Plate: the FIRST hit taken this fight is reduced by this, then spent
var impact_damage_mod: int = 0     # Glass Jaw: extra damage taken from physics impacts (walls/collisions)
var impact_resist_pct: int = 0     # Ablative Harness: % reduction of physics impact damage
var shove_resist: int = 0          # Magnetic Boots ITEM: subtracted from incoming impulse force
var flood_prone_immune: bool = false  # Sure-Footed / Magnetic Boots: a flood wave cannot knock this unit Prone
var chill_immune: bool = false     # Thermal Suit: immune to Chilled stacks
var acc_status_mods: Array = []    # [{bit:int, amount:int}] Shaky: accuracy mod while the SHOOTER has a status
var dmg_vs_status_bits: int = 0    # Opportunist: bonus damage vs targets carrying any of these status bits
var dmg_vs_status_amt: int = 0
var dmg_vs_flank: int = 0          # Opportunist: bonus damage on a flanking shot
var steady_shot: bool = false      # Steady: the first shot of a fresh phase does not end the turn
var object_damage_bonus: int = 0   # Demolitions Expert / Fire Axe: +integrity damage vs objects
var object_damage_mult: int = 1    # Demolition (Bruiser): multiplies integrity damage vs objects
var acc_buff: int = 0              # timed accuracy buff (Rally); expires with acc_buff_timer
var acc_buff_timer: int = 0        # env phases the accuracy buff persists
var move_buff: int = 0             # timed move buff (Warcry); expires with move_buff_timer
var move_buff_timer: int = 0
var temp_resist_timer: int = 0     # Rebreather Kit: poison+burn immunity while > 0 (env-phase countdown)
var triage_field: bool = false     # Triage (Steward passive): downed squadmates get +1 bleed-out window

# --- Wave 3b: Firebrand momentum meter (Sub-Spec C2.5) + Steward Last Stand. APPEND ONLY. ---
# Determinism guard: `momentum`, `first_attack_autocrit`, and `last_stand` are the only MUTABLE
# state fields here and enter the fingerprint ONLY when non-default (see momentum_fingerprint()),
# so every non-Firebrand / pre-momentum state stays byte-identical. The rest are static config
# (the picked-ability markers), cloned but never fingerprinted — like the other passive flags.
var momentum: int = 0              # Firebrand momentum stacks (0..MOMENTUM_MAX); MUTABLE state
var first_attack_autocrit: bool = false  # Vanguard: an armed guaranteed first-strike crit; MUTABLE (consumed on use)
var last_stand: int = 0            # Steward Last Stand: env phases a revived-defiant body has left; MUTABLE
var has_momentum: bool = false     # this body carries the momentum mechanic (Firebrand innateTrait) — config marker
var momentum_acc: bool = false     # Zeal picked: momentum also raises accuracy — config marker
var momentum_martyr: bool = false  # Martyr's Wake picked: an ally's death grants stacks instead of losing them
var martyr_gain: int = 0           # Martyr's Wake burst size (authored amount) — config
var vanguard_crit: bool = false    # Vanguard picked: arm the first-strike autocrit at MAX momentum — config
var inspire_ap: int = 0            # Inspire picked: AP this Firebrand gains when an ally kills — config
var refund_lunge_on_kill: bool = false  # Overrun picked: this actor's kill refunds an action — config

func has_status(s: int) -> bool:
	return (status & s) != 0

func add_status(s: int) -> void:
	status |= s

func clear_status(s: int) -> void:
	status &= ~s

func take_damage(d: int) -> void:
	if is_unit:
		hp -= d
	else:
		integrity -= d

func clone() -> SimEntity:
	var e := SimEntity.new()
	e.id = id
	e.name = name
	e.pos = pos
	e.mass = mass
	e.movable = movable
	e.hp = hp
	e.integrity = integrity
	e.faction = faction
	e.cover = cover
	e.status = status
	e.on_break = on_break
	e.break_param = break_param
	e.is_unit = is_unit
	e.is_power_source = is_power_source
	e.alive = alive
	e.burn_timer = burn_timer
	e.poison_timer = poison_timer
	e.chill_stacks = chill_stacks
	e.blind_timer = blind_timer
	e.suppress_timer = suppress_timer
	e.poison_immune = poison_immune
	e.fireproof = fireproof
	e.flammable = flammable
	e.overwatch = overwatch
	e.overwatch_used = overwatch_used
	e.instance_id = instance_id
	e.archetype_id = archetype_id
	e.traits = traits.duplicate()
	e.downed = downed
	e.bleed_timer = bleed_timer
	e.dead = dead
	e.gear = gear.duplicate()
	e.hidden_betrayer = hidden_betrayer
	e.betrayer_revealed = betrayer_revealed
	e.betrayed = betrayed
	e.shove_immune = shove_immune
	e.prone_immune = prone_immune
	e.slam_force_bonus = slam_force_bonus
	e.guardian_protocol = guardian_protocol
	e.ai_profile = ai_profile
	e.phys_trait = phys_trait
	e.captain_key = captain_key
	e.captain_gate_open = captain_gate_open
	e.buried_timer = buried_timer
	e.net_timer = net_timer
	e.unaware = unaware
	e.facing = facing
	e.fall_dir = fall_dir
	e.topple_height = topple_height
	e.conductor_shielded = conductor_shielded
	e.is_finale_boss = is_finale_boss
	e.pending_action = pending_action
	e.captured = captured
	e.max_hp = max_hp
	e.buffed_by_captain_id = buffed_by_captain_id
	e.accuracy = accuracy
	e.move_range = move_range
	e.damage_bonus = damage_bonus
	e.self_recoil = self_recoil
	e.ignore_cover_level = ignore_cover_level
	e.first_hit_reduced = first_hit_reduced
	e.impact_damage_mod = impact_damage_mod
	e.impact_resist_pct = impact_resist_pct
	e.shove_resist = shove_resist
	e.flood_prone_immune = flood_prone_immune
	e.chill_immune = chill_immune
	e.acc_status_mods = acc_status_mods.duplicate(true)
	e.dmg_vs_status_bits = dmg_vs_status_bits
	e.dmg_vs_status_amt = dmg_vs_status_amt
	e.dmg_vs_flank = dmg_vs_flank
	e.steady_shot = steady_shot
	e.object_damage_bonus = object_damage_bonus
	e.object_damage_mult = object_damage_mult
	e.acc_buff = acc_buff
	e.acc_buff_timer = acc_buff_timer
	e.move_buff = move_buff
	e.move_buff_timer = move_buff_timer
	e.temp_resist_timer = temp_resist_timer
	e.triage_field = triage_field
	# Wave 3b momentum + Last Stand (every field rides the clone so a resolver clone/adopt
	# roundtrip preserves a Firebrand's stacks / an armed autocrit / a defiant body — else
	# preview would diverge from commit, a P0 determinism bug).
	e.momentum = momentum
	e.first_attack_autocrit = first_attack_autocrit
	e.last_stand = last_stand
	e.has_momentum = has_momentum
	e.momentum_acc = momentum_acc
	e.momentum_martyr = momentum_martyr
	e.martyr_gain = martyr_gain
	e.vanguard_crit = vanguard_crit
	e.inspire_ap = inspire_ap
	e.refund_lunge_on_kill = refund_lunge_on_kill
	return e


## Fingerprint contribution for the momentum meter + Last Stand — emitted by SimState.snapshot()
## ONLY when non-default, so every pre-momentum / non-Firebrand state stays byte-identical to the
## golden fixtures (the determinism guard this whole lane hinges on).
func momentum_fingerprint() -> String:
	if momentum == 0 and not first_attack_autocrit and last_stand == 0:
		return ""
	return "m%d mo=%d vc=%d ls=%d" % [id, momentum, int(first_attack_autocrit), last_stand]
