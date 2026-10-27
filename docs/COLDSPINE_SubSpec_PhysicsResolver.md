# COLDSPINE — Sub-Spec A: The Physics Resolver

> Companion to COLDSPINE_GDD.md (§6). This is the load-bearing system.
> Build target: **Phase 1** (vertical slice / proof-of-fun gate).
> Engine: **Godot 4.x, GDScript**. Sim is engine-agnostic (`RefCounted`, no SceneTree).
> Hard rule: **integer math only, fully deterministic, fully previewable.**

---

## A0. What this system is (and isn't)

It is a **deterministic impulse-and-collision resolver** that models forced movement on a tile grid: shoves, slams, throws, billiards-style chain reactions, wall impacts, destructibles, floods, and hazard ejections. It is the engine that makes "the environment is the weapon" real.

It is **not** a real-time physics engine. There is no continuous rigid-body simulation, no floats, no frame-by-frame integration. Everything is resolved instantly in integer tile-space the moment a player commits an action, and the **same function** that resolves the action can be run in *dry-run mode* to produce the preview. This guarantees the Into-the-Breach property: **what the preview shows is exactly what happens.**

Three invariants govern every line of this system:
1. **Deterministic** — same `(state, impulse)` → same `ResolutionResult`, on every platform, forever.
2. **Pure** — `resolve_impulse()` does not mutate the live game state; it operates on a clone and returns a result + diffs. Commit applies the diffs.
3. **Terminating** — every chain provably ends (momentum strictly decreases; breakables are finite).

---

## A1. Data model (sim-side)

All on plain `RefCounted`. Positions are `Vector2i`. No floats anywhere in here.

```gdscript
# Mass tiers (also used as the per-tile travel cost — see A3)
enum Mass { LIGHT = 1, MEDIUM = 2, HEAVY = 3, ANCHORED = 99 }

class SimEntity extends RefCounted:
    var id: int
    var pos: Vector2i
    var mass: int            # one of Mass.*
    var movable: bool        # false when mass == ANCHORED
    var hp: int              # units use hp; objects use integrity (treat uniformly via take_damage)
    var integrity: int       # objects only; -1 for pure units
    var faction: int         # PLAYER / ENEMY / NEUTRAL / OBJECT
    var cover: int           # 0 none / 1 half / 2 full
    var status: int          # bitflags: PRONE | SOAKED | STUNNED | BURNING | SHOCKED ...
    var on_break: int        # NONE | FLOOD | EXPLODE | COLLAPSE | SPILL_FIRE
    var break_param: int     # e.g. flood radius; explosion radius
    var is_unit: bool

class SimTile extends RefCounted:
    var terrain: int         # FLOOR / WALL(=anchored-blocking) / ...
    var cover: int
    var hazard: int          # NONE | GAP | FURNACE | RAIL_LIVE | PISTON_LANE ...
    var occupant_id: int     # -1 if empty
    var status_layer: int    # bitflags: WATER | FIRE | ELECTRIFIED | DEBRIS
    var status_timer: int    # turns remaining for transient layers (water/fire)

class SimState extends RefCounted:
    var grid: Array           # 2D Array[Array[SimTile]] indexed [y][x]
    var entities: Dictionary  # id -> SimEntity
    var width: int
    var height: int
    var rng: IntRng           # hand-rolled seeded integer PRNG (NOT used by physics)
    func clone() -> SimState  # DEEP copy — required for dry-run previews
```

> **Why mass doubles as travel cost:** it gives one clean integer model where heavier = shorter throw, with no separate "friction" constant to balance. See A3.

---

## A2. The unit of currency: **Momentum (M)**

Forced movement uses a single integer, **momentum**, denoted `M`.

- An impulse hands the target an initial `M = force`.
- Traversing one tile costs the **moving entity's `mass`** in momentum. So free travel distance with no collision = `floor(force / mass)`:
  - Light (1) travels the full `force`. Medium (2) travels half. Heavy (3) a third. Anchored never moves.
- **`M_impact`** = the momentum the entity *still carries at the instant it tries to enter a blocked tile*. All collision damage, knockdown, and momentum transfer scale off `M_impact`. (Intuition: hitting a wall while you still had a lot of "go" left hurts; coasting to a gentle stop doesn't.)

This is the whole physical model. Everything below is rules for what happens when a moving entity meets something.

---

## A3. Tunable constants (starting values — balance in playtest)

```gdscript
const IMPACT_DIVISOR   := 2   # wall impact dmg = floor(M_impact / 2)
const COLLISION_DIVISOR:= 2   # body-vs-body: both take floor(M_impact / 2)
const OBJECT_DIVISOR   := 1   # destructible takes floor(M_impact / 1) integrity dmg
const COLLISION_DECAY  := 1   # momentum lost per body-to-body transfer (keeps chains finite)
const BREAK_COST       := 2   # momentum lost smashing THROUGH a broken destructible
const PRONE_THRESHOLD  := 2   # M_impact >= 2  -> target knocked Prone
const STUN_THRESHOLD   := 4   # M_impact >= 4  -> target also Stunned

const FLOOD_RADIUS_DEFAULT := 3   # tiles
const WATER_DURATION       := 3   # turns of standing water before it fully recedes
const SHOCK_DAMAGE         := 4   # per Soaked entity in an electrified body
const FURNACE_DAMAGE       := 6
const RAIL_DAMAGE          := 4

# Reference force values for designers
# Bruiser basic shove .......... 3
# Bruiser charged slam ......... 5
# Thrown Light furniture ....... 3 + thrower_bonus
# Thrown Medium furniture ...... 4 + thrower_bonus
# Grapple-pull (reverse dir) ... 2
```

---

## A4. Collision outcomes (the rules)

When a moving entity **A** (carrying `M_impact`) tries to enter the **next tile** in its travel direction, classify that tile and resolve:

### A4.1 Out of bounds / WALL / ANCHORED blocking object
- A **stops** at its current tile (cannot enter).
- A takes `impact_dmg = floor(M_impact / IMPACT_DIVISOR)`.
- If `M_impact >= PRONE_THRESHOLD` → A gains **Prone**. If `>= STUN_THRESHOLD` → also **Stunned**.
- If the blocker is a **destructible anchored object** (e.g., a wall-mounted tank), it still takes `floor(M_impact / OBJECT_DIVISOR)` integrity damage and may **break** (→ A4.4) even though A stops.
- Emit `EV_IMPACT_WALL`.

### A4.2 Another movable entity **B** (the billiards combo)
- A **stops** one tile back (at its current tile; it cannot overlap B).
- **Both** A and B take `floor(M_impact / COLLISION_DIVISOR)` collision damage.
- B receives a **new impulse**: same direction, `force_B = max(0, M_impact - COLLISION_DECAY)`.
  - If `force_B >= B.mass` → **enqueue** B's impulse (it will move; recurse via the chain loop, A5). Heavier B → shorter onward travel (its own mass divides its displacement), so absorption is automatic.
  - If `force_B < B.mass` → B doesn't move; it just took the collision damage (a "thud").
- A may itself become **Prone/Stunned** off `M_impact` (same thresholds) — slamming into a body at speed staggers you too.
- Emit `EV_COLLIDE_BODY`.

### A4.3 Destructible object **B** (movable or anchored), surviving the hit
- B takes `floor(M_impact / OBJECT_DIVISOR)` integrity damage.
- If B **survives**: treat as A4.2 if B is movable (push it), or as A4.1 if B is anchored (A stops). Emit `EV_OBJECT_DAMAGED`.

### A4.4 Destructible object **B** that **breaks** (integrity ≤ 0)
- Remove B from the grid (`occupant_id = -1`, drop from `entities`).
- **Enqueue B's `on_break` effect** onto the *effect queue* (A5): FLOOD (origin = B.pos, radius = B.break_param), EXPLODE, COLLAPSE, or SPILL_FIRE.
- A **continues** into the now-empty tile with `M -= BREAK_COST` (smashing through costs momentum). If `M <= 0`, A stops in that tile (no further travel) — but it *did* pass into it.
- Emit `EV_OBJECT_BREAK` (carries the on_break type so VFX can react).

### A4.5 Hazard tile (the tile A is entering has a `hazard`)
Resolve as A **enters** the tile (before any further travel):
- **GAP / off-train** → A is **ejected**. Units: this is a **kill** (removed from play, gear drops on the *last in-bounds tile*). Objects: removed. A's chain ends. Emit `EV_EJECT`. *(This is the "shove them off the train" win — make it feel huge.)*
- **FURNACE** → A takes `FURNACE_DAMAGE` + **Burning**; A continues if `M > 0`. Emit `EV_HAZARD_FURNACE`.
- **RAIL_LIVE** → A takes `RAIL_DAMAGE` + **Shocked**; if A is **Soaked**, this *also* seeds an electrify event on any connected water (A5 effect). Emit `EV_HAZARD_RAIL`.
- **PISTON_LANE (when armed)** → handled by the finale's scripted hazard timers, but mechanically: A takes piston damage + a fresh outward impulse (a hazard can itself *start a new chain*). Emit `EV_HAZARD_PISTON`.

### A4.6 Empty traversable tile
- A moves into it. Decrement `M -= A.mass`. If `M >= A.mass` (can afford another step) → continue; else A stops here (ran out of momentum, gentle stop, no impact damage). Emit `EV_MOVE_STEP`.

> **Edge cases to encode as tests:** zero-distance shove (force < mass → no move, optional 0 "brace" damage); shove directly into an adjacent wall (M_impact = force, big hit); a chain that loops back toward the shover (allowed — friendly fire is real, see GDD §20); two entities that would resolve into the same tile in one effect pass (resolve in queue order — A5).

---

## A5. Resolution order & the two-queue loop (determinism backbone)

Resolution uses **two FIFO queues** and a strict order. This is what makes chains deterministic and terminating.

```
ResolutionResult resolve_impulse(live_state, entity_id, dir: Vector2i, force: int, dry_run: bool):
    state   := live_state.clone()        # PURE: never touch the original until commit
    events  := []
    impulse_q := Queue()                 # pending forced-movement impulses
    effect_q  := Queue()                 # pending on_break effects (flood/explode/...)

    impulse_q.push({ id: entity_id, dir: dir, M: force })

    # ---- Main loop: drain impulses, then effects, repeat until both empty ----
    while not impulse_q.empty() or not effect_q.empty():

        while not impulse_q.empty():
            imp := impulse_q.pop()
            _resolve_one_impulse(state, imp, impulse_q, effect_q, events)
            # _resolve_one_impulse walks the entity tile-by-tile per A4,
            # pushing billiards impulses (A4.2) and on_break effects (A4.4) as it goes.

        while not effect_q.empty():
            eff := effect_q.pop()
            _resolve_effect(state, eff, impulse_q, effect_q, events)
            # effects may PUSH NEW IMPULSES (e.g. flood wave knocks units prone,
            # drifting light objects) and even new effects -> loop continues.

    return ResolutionResult.new(events, state.diff_against(live_state))
```

**Ordering rules (must be stable):**
- Both queues are **FIFO**. Insertion order = resolution order. Document and never rely on dictionary iteration order for anything that affects outcomes (sort by `id` when needed).
- **All impulses drain before effects each pass.** A break enqueues an effect; that effect (flood) is only processed after the current wave of movement settles. This makes "the slam finishes, *then* the tank floods, *then* the flood knocks people down" read cleanly and identically every time.
- **Termination proof:** each impulse step strictly reduces `M` (by `mass ≥ 1`) or ends the entity (eject/stop); body transfers lose `COLLISION_DECAY ≥ 1`; each break removes one finite object and costs `BREAK_COST`; floods touch each tile at most once per effect. No infinite loop is possible.

---

## A6. The Flood effect (marquee — detailed algorithm)

`on_break = FLOOD` enqueues an effect `{ kind: FLOOD, origin: Vector2i, radius: R }`. `_resolve_effect` for FLOOD:

```
1. WAVE (the break turn):
   reached := flood_fill(origin, R)        # BFS over FLOOR tiles; WALL/full-cover blocks water
   for tile in reached:
       tile.status_layer |= WATER
       tile.status_timer  = WATER_DURATION
       if tile.occupant_id != -1:
           occ := entities[tile.occupant_id]
           apply SOAKED to occ
           if occ.is_unit and not (occ.status & PRONE) and occ_is_standing(occ):
               apply PRONE to occ            # the wave knocks standing units down
           if occ.mass == LIGHT and occ.movable:
               impulse_q.push({ id: occ.id, dir: away_from(origin, occ.pos), M: 1 })  # drift
       emit EV_FLOOD_TILE
2. ELECTRIFY CHECK:
   if any reached tile is adjacent to a LIVE power source
      (RAIL_LIVE hazard, a Saboteur junction entity, or a shorted robot):
        enqueue effect { kind: ELECTRIFY, body: connected_water_component(reached) }
```

**ELECTRIFY effect** (`_resolve_effect` for ELECTRIFY):
```
component := all WATER tiles connected to the source (flood_fill over WATER)
for tile in component:
    tile.status_layer |= ELECTRIFIED      # transient, clears end of round
    if tile.occupant_id != -1:
        occ := entities[tile.occupant_id]
        if occ.status & SOAKED:
            occ.take_damage(SHOCK_DAMAGE)
            apply SHOCKED (heavy stun) to occ
        emit EV_SHOCK
# Source grounding: a one-shot junction is consumed; a persistent source (live rail) re-triggers
# only if NEW water connects on a later turn.
```

**Standing water lifecycle** (ticked in the **environment phase**, not in the resolver):
```
each round, for every WATER tile:
    tile.status_timer -= 1
    if tile.status_timer <= 0: clear WATER (recede)   # edges empty first since they were filled... 
                                                       # (optional: recede outermost-first for nicer visuals)
    units standing in WATER remain SOAKED; units that leave lose SOAKED next turn
    clear ELECTRIFIED at end of round (it is a momentary burst, re-seeded only by a fresh source)
```

**Fire × Water precedence** (keep simple, document it):
- Applying WATER to a FIRE tile → removes FIRE (extinguish). Applying FIRE to shallow WATER → removes WATER (boils off). **On a tie within the same effect pass, WATER wins.** Burning entities entering water lose **Burning**; Soaked entities entering fire lose **Soaked** (and may catch Burning).

> **The Saboteur fantasy this enables:** break a tank → flood → herd enemies into the water (or they're already Soaked from the wave) → spark it (junction / live rail / shorted robot) → chain-Shock the whole room. This combo is the system's signature; make sure the preview shows the full electrified component lighting up before commit.

---

## A7. The preview guarantee (UX-critical)

The preview is **not a separate code path** — that's the whole point. To preview:
```
result := resolve_impulse(live_state, id, dir, force, dry_run = true)   # runs on a clone
render_ghost(result)   # trajectory arrows, predicted end-positions (ghost sprites),
                       # break/flood/electrify overlays, prone/stun/soak icons on affected units
```
To commit (on confirm tap/click):
```
result := resolve_impulse(live_state, id, dir, force, dry_run = false)
live_state.apply(result.diffs)
animation_player.play_from_events(result.events)   # tween along the SAME trajectories
```
Because the function is **pure and deterministic**, the previewed `result` and the committed `result` are identical for the same inputs. **Players must never be surprised by physics.** If you ever find a discrepancy between preview and outcome, it is a determinism bug (a float crept in, or an unstable iteration order) — treat as P0.

---

## A8. Worked examples (use these as golden-file tests)

### Example 1 — Shove into a wall
Bruiser shoves a **Light guard A** (mass 1) with **force 5**, toward a wall **2 tiles away**.
- Step 1: enter empty tile → M = 5 − 1 = **4**, A at +1.
- Step 2: enter empty tile → M = 4 − 1 = **3**, A at +2.
- Step 3: next tile is WALL → **stop**. `M_impact = 3`.
  - impact_dmg = floor(3/2) = **1**.
  - 3 ≥ PRONE_THRESHOLD(2) → **Prone**. 3 < STUN_THRESHOLD(4) → not Stunned.
- Events: `MOVE_STEP, MOVE_STEP, IMPACT_WALL(dmg 1, prone)`.

### Example 2 — Billiards into a tank, into a flood
Layout (→ = shove direction): `Bruiser  [A:guard m1]  [B:guard m1]  [Tank: integrity 3, on_break FLOOD r3]  ...`
Bruiser shoves **A** with **force 6**.
- A tries to enter B's tile immediately (B adjacent). `M_impact = 6`.
  - A and B each take floor(6/2) = **3** dmg. A **stops** at its start tile.
  - B gets new impulse force = 6 − COLLISION_DECAY(1) = **5**, same dir. 5 ≥ B.mass(1) → enqueue B.
- Resolve **B** (mass 1, force 5):
  - B tries to enter the **Tank** tile. `M_impact = 5`. Tank takes floor(5/1) = **5** integrity → 3 − 5 < 0 → **BREAKS**.
    - Enqueue effect `FLOOD(origin = tank tile, r = 3)`.
    - B continues into the now-empty tank tile with M = 5 − BREAK_COST(2) = **3**, moves there (M 3 − 1 = 2), continues until momentum runs out or it hits something.
- Impulse queue empties → process **FLOOD**: BFS r3 from tank tile, set WATER + SOAKED on everyone in range; any standing unit caught (A, B if in range and standing) → **Prone**. If a live junction/rail borders the water → enqueue ELECTRIFY → Soaked units take SHOCK_DAMAGE + **Shocked**.
- This single 1-AP shove produced: 2 staggered guards, a destroyed tank, a flooded room, and (with a spark) a chain-shock. **This is the depth.**

### Example 3 — Eject off the train
Bruiser shoves a **Medium enforcer** (mass 2) with **force 5**, standing 1 tile from a **GAP** hazard (open coupling).
- displacement budget = floor(5/2) = 2 tiles, but the GAP is at +1.
- Step 1: next tile is GAP hazard → enforcer **ejected** = **killed/removed**; gear drops on the enforcer's prior tile. Chain ends.
- Events: `HAZARD_GAP, EJECT(kill)`. Costs 1 AP. Removing a dangerous Medium enemy for one action — high skill expression, position-dependent.

---

## A9. Event vocabulary (resolver → renderer)

Emit a flat, ordered list the renderer replays as an animation timeline:

```
EV_MOVE_STEP     { id, from, to }
EV_IMPACT_WALL   { id, dmg, prone, stunned }
EV_COLLIDE_BODY  { a_id, b_id, dmg, b_pushed: bool }
EV_OBJECT_DAMAGED{ id, dmg, integrity_left }
EV_OBJECT_BREAK  { id, pos, on_break }     # render shatter / explosion start
EV_FLOOD_TILE    { pos }
EV_SHOCK         { id, dmg }
EV_HAZARD_FURNACE{ id, dmg }
EV_HAZARD_RAIL   { id, dmg }
EV_HAZARD_PISTON { id, dmg }
EV_EJECT         { id, kill: bool, gear_drop_pos }
EV_STATUS_APPLY  { id, status }            # prone / soaked / stunned / burning / shocked
EV_STATUS_CLEAR  { id, status }
```
Renderer rules: animate `MOVE_STEP`s as tweens along the path; trigger VFX on break/flood/shock; pop status icons on `STATUS_APPLY`. Ordering of the list **is** the timeline — never reorder it.

---

## A10. Build order for THIS system (Phase 1 internal milestones)

1. **Single-target shove** — A4.1 (wall) + A4.6 (empty) + A2 momentum. Wall impact, prone/stun thresholds. Tests = Example 1.
2. **Billiards** — A4.2 body transfer + the impulse queue (A5). Tests = chain of 2–3 bodies; decay terminates.
3. **Destructibles** — A4.3 / A4.4 + the effect queue. Generic break (collapse/explode). Tests = Example 2 minus flood.
4. **Flood** — A6 wave + soak + prone; standing-water lifecycle; then electrify chain. Tests = Example 2 full.
5. **Hazards** — A4.5 gap eject / furnace / rail. Tests = Example 3.
6. **Throw** — Bruiser throws a movable object as a projectile = "create an impulse on an object the thrower isn't standing in." Reuses everything above.
7. **Preview wiring** — A7. The dry-run/commit parity assertion becomes a permanent test.

**Exit (proof-of-fun gate):** a hand-built car the player can clear *primarily through displacement and a flood*, with a working preview, running headless under tests. If this is fun, the game is fun.
