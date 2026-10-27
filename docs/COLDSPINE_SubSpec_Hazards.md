# COLDSPINE — Sub-Spec D: Hazards & Room Traps

> Companion to COLDSPINE_GDD.md (§5.5, §6, §8.4) and **Sub-Spec A** (the resolver these run on).
> Build target: layered across **Phase 2** (status + fire/water) and **Phase 5** (gas, vents, lasers as content). The finale (Sub-Spec B) consumes all of it.
> Principle: hazards are not set dressing — they are **area control, tempo pressure, and combo fuel**, and they cut both ways (enemies suffer them too).

---

## D0. Three hazard classes

| Class | Defined by | Examples | Resolves in |
|---|---|---|---|
| **Spreading / Volume** | occupies tiles, **propagates**, **dissipates** over time | Water/Flood, **Fire**, **Poison Gas** | environment phase, via the Sub-Spec A effect queue |
| **Cycling Trap** | Anchored feature, **fires on a timer**, **telegraphs** ~1 turn ahead, does not spread | **Fire Vents**, **Lasers**, Pistons, Electrified Plates, Steam Vents | environment phase, timer-ticked |
| **Static** | always-on **tile property**, no timer, no spread | Gap, Furnace, Live Rail, Debris | on entry, via the resolver (Sub-Spec A4.5) |

Everything physical (blasts, knockbacks, ejects) routes through the **Sub-Spec A resolver** — hazards never implement their own physics.

---

## D1. Spreading hazards

All three share machinery: a tile carries a hazard layer + a **density/duration timer**; each environment phase the hazard **propagates**, **thins**, applies **status** to occupants, and checks the **interaction matrix** (D4) which may enqueue effects (e.g., an explosion → radial impulses).

### D1.1 Water / Flood *(recap — full algorithm in Sub-Spec A6)*
- **Trigger:** a water/coolant tank breaks. **Wave** knocks standing units **Prone** + **Soaked**; **standing water** lingers `WATER_DURATION` then recedes.
- **Interactions:** + power source → **electrify** (Shock chain); **extinguishes Fire**; **disperses Gas**; boiled off by active Steam.

### D1.2 Fire *(new — spreading, fuel-bound)*
- **Trigger:** incendiary gear, Furnace, **Fire Vent**, **ignited Gas**, certain explosions, ruptured fuel.
- **Effect:** damage each turn to entities on FIRE tiles; applies **Burning** (DoT that persists ~2 turns after leaving the tile; **cancels Soaked**).
- **Spread:** each environment phase, FIRE spreads to **adjacent flammable** tiles/objects (wood furniture, oil, gas, cloth). **Non-flammable** (metal, stone, water) **blocks** it — so the metal Engine (Section 5) is fire-resistant by construction.
- **Dissipate:** burns `FIRE_DURATION` turns per tile (fuel consumed), then goes out, leaving **scorched** (passable) tiles.
- **Interactions:** **WATER extinguishes**; **igniting GAS → EXPLOSION** (D4); fire on a **Soaked** unit removes Soaked but may still Burn.

### D1.3 Poison Gas *(new — spreading, fuel-free; the headline addition)*
- **Trigger:** ruptured gas main, Saboteur **Gas Tap**, enemy gas grenade, toxic coolant breach.
- **Effect:** entities in GAS tiles gain **Poisoned** (DoT each turn in gas **+ a few turns after leaving**) and **−accuracy**. **Not immediately lethal** — gas is **area denial and attrition**: it forces movement, punishes camping in cover, and herds enemies into kill positions. **Negated** by gas masks (gear), **Iron Lungs** (trait), or Steward **Rebreather Kit**.
- **Spread:** a **cloud expands** outward ~`GAS_SPREAD_RATE` tile/turn up to `GAS_MAX_RADIUS`; optional **drift** along a vent direction. Unlike fire it needs **no fuel** — it fills available space, then thins.
- **Dissipate:** each tile has a **density timer**; edges **thin first**; the cloud clears after `GAS_DURATION`. **Water disperses it**, an **explosion or opened vent/door clears** it, and **fire/spark ignites it**.
- **Interactions (marquee):** **GAS + any ignition (Fire / Fire Vent / Laser / spark / Saboteur Pyro Loop) → EXPLOSION** — a one-time blast over the gas volume: damage + **radial impulse** (Sub-Spec A) to everything inside, the gas is **consumed**, and it may leave **residual Fire**. Bait enemies into the cloud, then light it. **GAS + WATER → disperse.**

> The Saboteur's two signature loops live here: **flood → electrify** (water) and **gas → ignite** (gas). The preview (Sub-Spec A7) must show the full ignited-volume blast before commit.

---

## D2. Cycling traps

Anchored features with a `cycle_timer` and a phase (`armed → telegraph → fire → cooldown`), advanced in the environment phase. **Telegraph one turn ahead** (renderer shows the danger tiles). They **do not spread**. Most are **disableable** (Saboteur **Hack** / destroy the emitter) and most can be **weaponized** (shove an enemy into the active tiles).

### D2.1 Fire Vents *(new)*
- Floor/wall jets. **Fires** a fire burst on its tile (and optionally a 1-tile line) → fire damage + **Burning** + **ignites GAS** in those tiles → cooldown → repeat (default **every 2 turns**).
- **Use:** shove an enemy onto a vent on its fire turn; use a vent as an **ignition source** for a gas cloud; path around telegraphed tiles. Disable to make a room traversable.

### D2.2 Lasers *(new)*
- An emitter projects a **beam along a line/row** (or a **sweeping** beam that rotates through a tile set) on a timer; **telegraphed**. When active, the beam **damages everything in its line**, **ignites GAS** along its path, and at **Engine-tier** can cut/instakill.
- **Variants:**
  - **Grid** — multiple beams toggle on/off in a pattern: a moving maze you time your movement through.
  - **Sweep** — one beam rotates across an arc: time your crossings.
- **Use:** positioning/timing puzzle; **shove an enemy into an active beam**; break the beam's line with **cover or a Steam cloud**; disable the emitter to shut a lane. *(No reflection in v1 — flagged as a stretch toy.)*

### D2.3 Pistons *(recap — Sub-Spec A4.5 / B1.1)*
- Telegraph → **slam outward 2–3 tiles**: impact damage **+ an outward impulse** (a hazard that **starts a new chain** through the resolver). Shove robots/enemies into the lane.

### D2.4 Electrified Plates *(recap)*
- Cycle **on/off** (telegraphed). When **live**: **Shock** to anything standing on them. **+ Water → AoE chain** across the connected flooded tiles. Herd enemies on, flood, trigger.

### D2.5 Steam Vents *(recap)*
- Cycle → emit a **steam cloud**: minor DoT + **Blinded** / **blocks line of sight** for a turn. **Boils off Water** on its tiles (don't undo your own flood). Useful to break a Sniper's or the Conductor's LoS during a dangerous telegraph.

---

## D3. Static hazards *(recap — Sub-Spec A4.5)*

| Hazard | On entry |
|---|---|
| **Gap / Open Coupling** | **Eject** = kill/remove; gear drops on the last in-bounds tile. The "shove them off the train" win. |
| **Furnace** | Fire damage + **Burning**; entity may continue. |
| **Live Rail** | Shock damage; **+ Soaked → chain**. |
| **Debris / Rubble** | Difficult terrain (extra Move cost); provides low cover. Produced by `collapse` breaks. |

---

## D4. Interaction matrix *(implement as one lookup; deterministic)*

The combo grid is the soul of the hazard system. Resolve interactions in the environment phase **after** propagation, **before** DoT application, in stable order.

| A ↘ meets B → | **Water** | **Fire** | **Gas** | **Power source / spark** |
|---|---|---|---|---|
| **Water** | merge | **extinguish Fire** | **disperse Gas** | **electrify → Shock chain** |
| **Fire** | (Water wins: boil) | merge/spread | **IGNITE → Explosion** | already hot |
| **Gas** | **dispersed** | **IGNITE → Explosion** | merge/expand | **IGNITE → Explosion** |
| **Steam** | **boils Water off tile** | — | — | — |
| **Explosion (result)** | — | may leave residual Fire | **consumes Gas** | — |

**Explosion** (produced by any IGNITE, or by explosive `on_break` objects): a one-time effect over its volume → **damage + radial impulse to all entities** (via Sub-Spec A — bodies fly, can chain, can break further objects), **clears Gas**, may seed **residual Fire**. This is the single highest-payoff line in the hazard system; make it readable and previewable.

**Precedence rule of thumb:** *Water beats Fire on a tile; Fire+Gas beats everything (explodes); Water disperses Gas; Steam dries Water.* Document the exact tie-break so preview == outcome (Sub-Spec A7).

---

## D5. Environment-phase resolution order *(must be fixed for determinism)*

Each round's **environment phase** (GDD §5.1) resolves in this exact order:
1. **Tick cycling traps** — advance `cycle_timer`s; resolve any `fire` phases (vents, lasers, pistons, plates, steam). Piston/blast impulses go through the Sub-Spec A resolver; set next-turn telegraphs.
2. **Propagate spreading hazards** — Water recedes; Fire spreads to flammables and burns down fuel; Gas expands/drifts and thins.
3. **Resolve interactions** (D4) — extinguish / disperse / electrify / **ignite→explosion**; explosions enqueue impulses (Sub-Spec A) resolved now.
4. **Apply DoTs** — Burning, Poisoned tick on affected entities.
5. **Clear momentary layers** — Electrified (one-burst), expired telegraphs, dissipated edges.

Stable iteration order (sort by tile index / entity id where outcomes depend on it). The whole phase is reproducible from the seed + state.

---

## D6. Tunable constants (starting values)

```gdscript
const FIRE_DURATION       := 3    # turns a tile burns before fuel is spent
const FIRE_DAMAGE         := 3
const BURNING_LINGER      := 2    # turns Burning persists off-tile

const GAS_SPREAD_RATE     := 1    # tiles/turn the cloud expands
const GAS_MAX_RADIUS      := 4
const GAS_DURATION        := 5    # turns before the cloud fully thins
const POISON_DAMAGE       := 2
const POISON_LINGER       := 2    # turns Poisoned persists after leaving gas
const POISON_ACC_PENALTY  := -15  # to-hit while Poisoned

const VENT_PERIOD         := 2    # fire-vent cycle
const LASER_PERIOD        := 2    # laser cycle (grid toggle / sweep step)
const TRAP_TELEGRAPH      := 1    # turns of warning (all cycling traps)

const EXPLOSION_DAMAGE    := 6
const EXPLOSION_FORCE     := 4    # radial impulse magnitude (fed to Sub-Spec A)
const EXPLOSION_RADIUS     := 2
```

---

## D7. Authoring & placement

- Hazards are placed two ways: **baked into a `CarTemplate.layout`** (set-piece rooms — e.g., a laser-grid security car, a furnace row, the Engine vault) **and** **rolled by modifiers** (GDD §8.4): e.g.
  - *Gas Leak* — seeds a gas main + initial cloud.
  - *Laser Sec-Grid* — adds beam emitters in a pattern.
  - *Furnace Row* / *Coolant Bank* / *Live Rails* — seed the matching hazards.
  - *Overpressure* (existing) — every destructible break triggers a **flood**.
- **Section flavor:** Gas/Fire/aquaria cluster in 2nd/3rd class (services, kitchens, gardens); **Lasers/Plates/Pistons/robots** dominate 1st class and the Engine (automated security). This makes the **recon** (§8.2) readout meaningful — seeing "CAR 19 — LASER GRID + GAS" two cars out tells you to bring the Saboteur forward and hold a flood.

---

## D8. Data schema

```typescript
interface HazardDef {
  id: string;                         // "poison_gas"
  name: string;
  klass: "spreading" | "cycling" | "static";
  damageType: "fire" | "poison" | "shock" | "impact" | "kinetic";
  baseDamage: number;
  appliesStatus: Array<"prone"|"soaked"|"burning"|"poisoned"|"shocked"|"stunned"|"blinded">;

  // spreading only:
  spreadRule?: "wave" | "expand" | "expand_drift";
  spreadRate?: number;                // tiles/turn
  maxRadius?: number;
  needsFuel?: boolean;                // fire = true, gas = false
  dissipateTurns?: number;

  // cycling only:
  cyclePeriod?: number;               // turns between firings
  telegraphTurns?: number;            // default 1
  fireShape?: "tile" | "line" | "arc" | "row" | "sweep";

  // interaction flags (matrix in D4 does the rest):
  ignitable?: boolean;                // gas
  ignites?: boolean;                  // fire / vent / laser / spark
  disableable?: boolean;              // Saboteur hack / destroy emitter
}
```

---

## D9. Acceptance criteria (this system "done")

1. **Three spreading hazards** work: Water (Sub-Spec A6), **Fire** (spreads on flammables, fuel-bound, extinguished by water), **Poison Gas** (expands fuel-free, applies **Poisoned**, dispersed by water).
2. **Cycling traps** work with **1-turn telegraphs**: **Fire Vents**, **Lasers** (grid + sweep), Pistons, Plates, Steam — all disableable and weaponizable (shove enemies into active tiles).
3. The **interaction matrix** (D4) resolves correctly, and **Gas + ignition → Explosion** produces a previewable radial blast through the Sub-Spec A resolver.
4. Static hazards (Gap/Furnace/Rail/Debris) resolve on entry per Sub-Spec A4.5.
5. The **environment phase** resolves in the fixed order (D5) and is **deterministic**/reproducible.
6. Resistances connect: gas masks / **Iron Lungs** / Steward **Rebreather** negate Poison; **Fireproof** reduces Fire — closing the loop with Sub-Spec C.
7. Hazards place via both **CarTemplate layouts** and **modifier rolls**, and read correctly in **recon** (§8.2).
