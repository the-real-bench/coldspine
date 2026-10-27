# COLDSPINE — `content/` data layer

The entire data-driven content layer for COLDSPINE, authored as JSON per GDD §21 and Sub-Specs C / D / E / B. The engine (`res://core`, `res://ai`, `res://render`) reads these files; **adding content = adding data, not editing systems** (GDD §17.3, invariant #3). All ids are globally unique, snake_case, and cross-referenced.

> **DATA ONLY.** No code here. Numbers are first-pass balance values grounded in the sub-specs; where a sub-spec was silent, sane values were chosen and flagged in §"Invented values" below.

---

## Counts

| Category | Files | Entries |
|---|---|---|
| Archetypes | 5 | **5** |
| Abilities | 8 | **67** (player: 47, enemy: 10, captain: 7, conductor: 5; minus shared none — see note) |
| Traits | 1 | **29** |
| Enemies | 2 | **15** (10 roster + 5 captains; the Conductor is the 6th captain-file entry, finale boss) |
| Items | 3 | **24** (9 weapons, 6 armor, 9 gadgets/consumables) |
| Objects | 1 | **26** |
| Modifiers | 1 | **17** |
| Hazards | 2 | **17** + interaction matrix + D6/E1 constants |
| Cars | 36 | **36** (16 functional + 15 set-pieces + 4 captain gates + 1 engine finale) |

> Ability count (67) is the number of distinct ability ids across all 8 ability files. Player-castable abilities = 47 (signatures + trees + capstones for the 5 archetypes). Enemy/captain/Conductor abilities make up the rest.

---

## Schema reference (mirrors GDD §21 + Sub-Spec C5 / D8, adapted TS → JSON)

### ClassDef / ArchetypeDef — `archetypes/*.json`
```
id, name, role(frontline|ranged|tech|support|momentum),
baseStats{ hp, move, accuracy, mass(light|medium|heavy) },
innateTrait (nullable), startingAbilities[], abilityTree[ [a,b], ... ] (1-of-2 per tier),
capstone, traitAffinity[]
```

### AbilityDef — `abilities/*.json` (keyed by id within each file)
```
id, name, apCost, endsTurn, targeting(self|ally|enemy|tile|direction), range, effects[]
```
`effects[]` entries are `{ kind, ... }`. Kinds used: `impulse`(force), `throw`(force), `damage`(amount),
`status`(status), `clear_status`, `ranged_attack`/`melee_attack`, `heal`, `stabilize`, `hack`,
`electrify`, `spawn_hazard`, `spawn_enemy`, `buff`, `move`, `pull`, `reaction`, plus passive/meta kinds
(`damage_bonus_vs_status`, `momentum_grants`, `disable_all_cycling_traps`, etc.).

### TraitDef — `traits/traits.json` (under `traits[]`)
```
id, name, category(combat|physics|utility|social|risk|hidden),
polarity(positive|negative|mixed|hidden), effects[],
archetypeAffinity[]?, hidden?, revealCondition?, gainable?
```

### EnemyDef — `enemies/*.json` (under `enemies[]`)
```
id, name, tier(1-5), stats{ hp, move, accuracy, mass }, physicsTrait(nullable),
abilities[], aiProfile(melee_rush|ranged_hold|flanker|support|robot)
```
Captains add `section`, `physicsKey` (their unique physics solve), and the Conductor adds `isFinaleBoss`.

### Item — `items/*.json` (under `items[]`)
```
id, name, slot(weapon|armor|gadget|consumable), tier, effects[], physicsRiders[]
weapons add: wclass(melee|ranged), range, damageBand[min,max]
gadgets/consumables add: apCost, targeting, range
```

### ObjectDef — `objects/objects.json` (under `objects[]`)
```
id, name, mass(light|medium|heavy|anchored), integrity, coverValue(0|1|2),
onBreak(none|flood|explode|collapse|spill_fire|topple), floodRadius?, break_param?,
topple extras: fall_dir, height; flags: flammable?, blocksLoS?, isPowerSource?
```

### ModifierDef — `modifiers/modifiers.json` (under `modifiers[]`)
```
id, name, polarity(positive|negative), effects[]
```

### HazardDef — `hazards/hazards.json` (under `hazards[]`, plus `constants{}`)
```
id, name, klass(spreading|cycling|static), damageType, baseDamage, appliesStatus[],
spreading: spreadRule, spreadRate, maxRadius, needsFuel, dissipateTurns
cycling: cyclePeriod, telegraphTurns, fireShape; flags: ignitable, ignites, disableable
```
`hazards/interaction_matrix.json` encodes the Sub-Spec D4 combo grid as a deterministic lookup.

### CarTemplate — `cars/*.json`
```
id, name, type(combat|flood|upgrade|bourgeois|recruit|event|rest|shop|captain|engine),
section(1-5), gridSize{w,h},
layout{ terrain, walls[], cover[], objects[], tileFields[]?, hazards[]?, spawnPoints{} },
enemySpawns[{enemy, at}], rewardTable, allowedModifiers[]
```
Set-pieces add `reconTell`, `reconTags[]`, and (where applicable) `inCarFog`, `ambushStart`,
`betrayerHook`, `moralBeat`. `tileFields[]` carries the E1 extensions (`friction`, `slope`,
`concealment`, `status`, `beltDir` for conveyors). The engine finale adds `objectives[]`,
`phases[]`, `endings[]`, `bridgeCountdown`.

---

## File index

### `archetypes/` (5)
`bruiser` · `marksman` · `saboteur` · `steward` · `firebrand` (Sub-Spec C2).

### `abilities/` (8 files, 67 ids)
- `bruiser_abilities.json` — slam, heave, bull_rush, bracing, pin, sweep, bodyguard, demolition, juggernaut
- `marksman_abilities.json` — aimed_shot, overwatch, opportunist, steady, lattice, pierce, killzone, soaked_spark, deadeye
- `saboteur_abilities.json` — rig, hack, junction, gas_tap, remote_detonate, overclock_hack, pyro_loop, coolant_master, system_seizure
- `steward_abilities.json` — stabilize, patch, cleanse, field_medic, adrenaline, rebreather_kit, triage, rally_banner, last_stand, guardian_protocol
- `firebrand_abilities.json` — lunge, rally, zeal, reckless_ability, inspire, martyrs_wake, warcry, overrun, vanguard
- `enemy_abilities.json` — truncheon_strike, shield_bash, net_shot, enforcer_volley, hound_pounce, sniper_shot, sniper_overwatch, deploy_bot, robot_ram, turret_burst
- `captain_abilities.json` — buff_guards, shield_wall, captain_slam, summon_hounds, gas_grenade, marking_call
- `conductor_abilities.json` — re_route, deploy, overcharge, accelerate, lockdown (Sub-Spec B3.1)

### `traits/traits.json` (29)
Full Sub-Spec C3.4 starter set incl. required ids `steady_hands`, `coward`, `informant`, `iron_lungs`,
and the hidden-loyalty `conductors_kin` (`hidden:true`). Hidden traits: `conductors_kin`, `survivors_guilt`.

### `enemies/` (2 files, 15)
- `roster.json` — truncheon_guard, riot_shield, net_gunner, enforcer, hound, sniper, drone_operator, security_robot, sentry_turret (§12)
- `captains.json` — 5 Section Captains (each a unique `physicsKey`) + `the_conductor` finale boss

### `items/` (3 files, 24)
- `weapons.json` (9) — melee/ranged with physics riders (knockback, shove-on-hit, pull-on-hit, ignites_gas)
- `armor.json` (6) — incl. `magnetic_boots` (shove resist), `gas_mask`, `thermal_suit`
- `gadgets.json` (9) — grapple (pull), portable_junction_box (on-demand electrify), breaching_charge, + consumables

### `objects/objects.json` (26)
fish_tank_large/small, coolant_tank, water_main, gas_main, barrel_explosive, oxygen_tank, crate, table,
chair, serving_cart, glass_partition, junction_box, weight_rack, marble_statue, chandelier, tree,
hedge_wall, hedge_sculpture, bookshelf, pottery_vase, alcohol_barrel, planter, bench, locker, thin_ice.
(`topple` on_break = Sub-Spec E1.3 extension.)

### `modifiers/modifiers.json` (17)
All 12 GDD §8.4 modifiers + 5 hazard-seeding rolls from Sub-Spec D7 (gas_leak, laser_sec_grid, furnace_row, coolant_bank, live_rails).

### `hazards/` (2 files, 17 + matrix)
- `hazards.json` — 3 spreading (water/fire/poison_gas), 6 cycling (fire_vent/laser_grid/laser_sweep/piston/electrified_plate/steam_vent) + conveyor, 4 static (gap/furnace/live_rail/debris), plus explosion/avalanche/scald_tile; D6 + E1 `constants{}`.
- `interaction_matrix.json` — the Sub-Spec D4 combo grid + explosion spec + ignition sources.

### `cars/` (36)
| Group | Files |
|---|---|
| Functional (16) | combat_security_01/02, combat_bunk_stacks_01, combat_scrap_market_01, flood_aquaria_01, flood_water_ration_01, upgrade_workshop_01, bourgeois_lounge_01, bourgeois_galley_01, bourgeois_steerage_01, sanctuary_recruit_01, event_01, med_rest_01, rest_bunkhouse_01, black_market_shop_01, shop_rag_market_01 |
| Set-pieces — launch-15 (15) | setpiece_ski_simulator, setpiece_ice_rink, setpiece_forest, setpiece_hedge_maze, setpiece_garden, setpiece_dining_room, setpiece_spa, setpiece_artist_house, setpiece_gym, setpiece_aquarium, setpiece_library, setpiece_nightclub, setpiece_boiler_annex, setpiece_cold_storage, setpiece_server_hub |
| Captain gates (4) | captain_s1_tail_warden, captain_s2_foreman, captain_s3_head_gardener, captain_s4_majordomo (s5 Chief folded into the finale antechamber) |
| Engine finale (1) | engine_conductor_vault |

> The 10-type target is met by type coverage (combat, flood, upgrade, bourgeois, recruit, event, rest, shop, captain, engine). **Section theming rule** (guarded by `tests/content_integrity_smoke.gd` check K): any car type with a Section-4 template must also have Section-1 AND Section-2 templates, so the run generator's any-section fallback can never pull a First-class set-piece into the Tail; Section 1 keeps >=3 combat templates so early runs don't repeat one fight.

---

## Cross-reference integrity
- Every archetype `startingAbilities` / `abilityTree` / `capstone` names a real ability id.
- Every `traitAffinity` names a real trait id.
- Every enemy/captain `abilities[]` names a real ability id.
- Every car `enemySpawns[].enemy` names a real enemy id; every `allowedModifiers[]` names a real modifier id.
- Car `layout.cover/objects` must reference **`objects.json` ids ONLY** — a hazard or enemy id placed there loads as an INERT generic prop (no cycling, no fire; exactly how the finale turrets originally shipped unarmed) and is a **hard FAIL** in `content_integrity_smoke`. Hazards go in `layout.hazards[]`, enemies in `enemySpawns[]`.
- Every car-placed hazard id (`layout.hazards[]`, `tileFields[].hazard`, `rigged`) must be **loader-mapped** (`SetpieceLoader.PLACEABLE_HAZARDS`) — a valid-but-unmapped id (`explosion`, `avalanche`: instantaneous events, not placeable tile states) would silently no-op and fails the suite.
- Finale `objectives[]` use bespoke object ids (`relay`, `robot_dispenser`, `engine_core`, `control_dais`) that the engine instantiates from Sub-Spec B (not in `objects.json` — they are scripted Anchored destructibles, B7). Their `integrity`/`onDestroy` fields are design documentation — the engine builds them from `E.*_INTEGRITY_DEFAULT` constants + scripted hooks. `bridgeCountdown` IS read (both finale paths in `run_controller`, falling back to `E.BRIDGE_COUNTDOWN_DEFAULT`). The Conductor is deliberately NOT in the finale's `enemySpawns[]` (EngineVault instantiates it on the dais); the 2 `sentry_turret`s + `captain_chief_of_security` ARE, and survive into the fight (guarded by check J).

---

## Invented / first-pass values (not specified by the sub-specs — flag for balancing)

The sub-specs gave relative slants (▲/●/▼), not raw numbers, for most stats. These concrete values are first-pass and meant to be tuned:

- **Archetype baseStats** — all hp/move/accuracy numbers are invented from the C2 slants (e.g. Bruiser hp 12 / acc 55, Marksman acc 80 / hp 9). `mass` strings follow C2 exactly.
- **Ability numbers** — apCost/range/force/damage/cooldown are first-pass (e.g. Slam force 4, Aimed Shot dmg 4 / range 8, Deadeye dmg 7 / cd 4). Force values lean on Sub-Spec A constants (PRONE_THRESHOLD 2, STUN_THRESHOLD 4) so impacts cross thresholds sensibly.
- **Enemy stats** — hp/move/accuracy invented per tier; mass strings chosen to fit the physics counter-design (riot_shield medium, enforcer heavy, hound light).
- **Captain `physicsKey` strings** — invented machine-readable keys for the unique solves (only the Tail Warden / Chief / Conductor `unshovable_until_soaked` is canon from §12 / B4; Foreman/Gardener/Majordomo keys are designed to fit their §12 archetype hints "buffs nearby guards" etc.).
- **Item stats** — all damageBand / tier / effect amounts invented; physics riders grounded in §11 examples (maul knockback, shotgun shove-on-hit, magnetic boots shove resist, grapple pull, portable junction box).
- **Object integrity / coverValue / floodRadius** — invented; fish_tank/coolant use FLOOD_RADIUS_DEFAULT=3 from sim_enums. `topple` height/fall_dir invented per E1.3.
- **Modifier effect magnitudes** — invented (e.g. displacement_mult 2 is canon from §21 example; cramped −1 move, sympathizers +1 ally are first-pass).
- **Hazard constants** — copied verbatim from Sub-Spec D6 and E1.2 where given; FROZEN_THRESHOLD 3 / CHILL penalties / SCALD_DAMAGE 4 are first-pass (E1 gave names, not numbers).
- **Car layouts** — all tile coordinates, wall runs, cover/object/spawn placements, and grid sizes are invented within the §5.3 / E guidance (12×8–18×10; finale 20×12). Enemy compositions per car are first-pass and should be balanced against squad power curves.

---

## Notes for the engine lead (cross-reference gaps the resolver may not yet execute)

These are **effect kinds / fields the data references that the current `res://core` resolver does not yet implement** — content is ahead of engine here, by design (data-driven). Track as you build Phases 2–6:

1. **Status not yet in `sim_enums.gd`** — `chilled`, `frozen`, `scalded` are referenced by cold-biome cars/hazards (Sub-Spec E1.2) but not in the `S_*` bitflags (only `S_CHILLED`/`S_FROZEN` exist; **`scalded` has no bitflag** — E1.2 says it's a one-off tile effect, not a lingering status, so it may stay a tile property, not a status). Confirm.
2. **on_break = `topple`** — ~~not in the enum yet~~ DONE: `E.OnBreak.TOPPLE` (+ `AVALANCHE`) exist and `SetpieceLoader.ONBREAK_MAP` maps them; only the legacy Phase-0 `app/car_loader.gd` debug path still falls back to `collapse`.
3. **Tile fields `friction` / `slope` / `concealment` / `beltDir`** — E1.1/E1.4/E1.5 extensions; `sim_tile.gd` must gain these fields for ski/ice/forest/maze/gym cars to play as designed.
4. **Hazard kinds beyond the resolver** — `fire`, `poison_gas`, `laser_grid/sweep`, `conveyor`, `avalanche` are Phase-2/5 (Sub-Spec D); the Phase-1 resolver only does water/flood/electrify + static gap/furnace/rail/piston. Cars referencing these hazards are forward-content.
5. **Ability effect kinds** — many passive/meta kinds (`momentum_grants`, `damage_bonus_vs_status`, `intercept_overwatch`, `disable_all_cycling_traps`, `hacked_units_extra_action`, `survive_at_1hp`, etc.) are Phase-4 squad-system content; the Phase-0/1 engine executes only the physical kinds (impulse/throw/damage/status/electrify). The data is complete and waiting.
6. **Finale objective objects** (`relay`, `robot_dispenser`, `engine_core`, `control_dais`) are Sub-Spec B7 scripted destructibles, not generic `ObjectDef`s — the engine instantiates them in Phase 6; they are intentionally absent from `objects.json`.
7. **`captains.json` carries 6 entries** (5 gate captains + the Conductor) under one `enemies[]` array so the loader reads it like `roster.json`. The Conductor is flagged `isFinaleBoss:true`.
