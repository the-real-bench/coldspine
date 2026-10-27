# COLDSPINE — Game Design Document

> *Working title: **COLDSPINE** (alternates: TAILWARD, TERMINUS LINE)*
> Version 1.0 — Build spec
> Author: Design Council (synthesized) for ptbench Studios

---

## 0. How to read this document

This GDD is written as a **build spec**, not as a marketing pitch. It is opinionated on purpose: you asked the team to fill the gaps without your input, so every contested decision has been resolved and the rationale is recorded in §2 so you can revisit any of them later. Systems are specified in enough detail to start implementation; §17–§21 give the technical architecture, the phased build order, and concrete data schemas. **Implementation starts at §18 (Build Roadmap) and §21 (Schemas); §6 (Physics) is the load-bearing differentiator.**

---

## 1. The pitch

**COLDSPINE** is a squad-based, turn-based tactical roguelite. You lead a tail-section uprising aboard a globe-circling train, fighting car by car from the freezing rear toward the Engine. Combat is **physics-first**: you win less by out-damaging the enemy and more by *moving* them — slamming bodies into walls, shoving furniture to shatter cover, and breaking aquariums to flood whole cars. Every survivor you keep gets stronger; every death is permanent. Reach the Conductor's chamber and stop the train.

| Field | Value |
|---|---|
| **Genre** | Turn-based tactics × roguelite (deck-of-rooms run structure) |
| **Core verb** | *Displace* (move enemies and the environment as the primary tactic) |
| **Camera / view** | Isometric, tile-based, single-screen-per-car encounters |
| **Run length** | ~25–45 min per full attempt; ~15–25 cars |
| **Players** | Single-player |
| **Primary platform** | **Mobile (Android + iOS) and PC (Win/Mac/Linux)** — shared codebase. Touch-first UI, mouse/gamepad on desktop. |
| **Reference DNA** | XCOM (squad, cover, classes, permadeath attachment) + **Into the Breach** (deterministic previewed physics) + FTL / Slay the Spire (branching run, modifiers, meta) + *Snowpiercer* (theme, forward-only progression, class-war morality) |
| **Tone** | Grimy industrial revolt escalating into sterile, hostile opulence |

---

## 2. Design Council & key decisions

You asked for the concept to be "run through a team." Here are the five voices that shaped it and the seven contested calls they resolved. Each decision is **revisitable** — this section exists so you know *why* before you change anything.

**The council**
- **Systems Designer** — owns the run structure, economy, and meta-progression.
- **Combat / Encounter Designer** — owns turn flow, cover, and the physics ruleset.
- **Narrative Designer** — owns the moral economy, recruitment, and endings.
- **Technical Director** — owns determinism, architecture, and what is actually buildable.
- **"The Gamer"** (playtester voice) — owns *feel*: anti-frustration, readability, attachment.

**Resolved decisions**

| # | The debate | Decision | Rationale |
|---|---|---|---|
| D1 | XCOM-style hit-chance RNG vs. fully deterministic combat | **Hybrid**: ranged attacks roll to-hit (cover/flank matter); **all physics is deterministic and previewed** | Keeps XCOM's gunfight tension, but makes *physics the tool you use to defeat the RNG*. Mastery = converting uncertain shots into certain kills via positioning. The Gamer vetoed "95% miss" feel-bad on the systems you have most control over. |
| D2 | Real-time physics engine vs. deterministic resolver | **Deterministic impulse resolver** (Into the Breach model), integer/fixed-point math, no live rigid-body sim | Readability, perfect-information previews, reproducible seeds, and it is dramatically more buildable by an agent than wiring a physics engine. |
| D3 | Fixed starting squad vs. drafted squad | **Draft 1–3 starters**, shown 3 candidates at a time, no repeats; soft cap 4, hard cap 5 via recruitment (full system: Sub-Spec C) | Player-authored starts → variety and ownership from turn one. Choosing *how many* to draft is itself a risk dial (see §7.1). Growth-by-recruitment still models the uprising. |
| D4 | Roguelike (pure permadeath) vs. roguelite (meta-progression) | **Roguelite** (Hades/Dead Cells model) + a **Legacy** hook | Retention and the emotional payoff of carrying a fallen hero's gear/trait forward. |
| D5 | Branching map vs. single linear line | **Single linear line + foreknowledge** — the train is one track; you *cannot* choose the path, but you can **recon** what's coming (§8.2) | A train is a single line — branching breaks the fiction and the camera framing (D8). Replay comes from the seeded sequence, modifiers, and your draft/build, not routing. The decision shifts from *which door* to *how do I prepare for what I can see coming*. |
| D6 | Should sparing vs. killing actually matter? | **Yes — a run-wide Order meter** plus gear/recruit tradeoffs | Cruelty is a short-term resource grab that raises difficulty; mercy is the long game. Gives the *Snowpiercer* morality real teeth. |
| D7 | Final car = boss stat-check vs. objective | **Objective-based multi-phase finale** ("stop the train"), not a pure HP sponge | A climactic, mechanically distinct encounter that uses the whole toolset and pays off the theme. |
| D8 | The player's role / POV | **You are a remote operator** who breached the train's surveillance grid and directs the uprising via the security cameras (§3.1) | Diegetically justifies the top-down single-room view, turn-based pacing, perfect-information physics preview, and "see-but-don't-choose-the-path" recon. The abstraction *becomes the story*. |

---

## 3. Design pillars

1. **Forward-only pressure.** The train goes one way. You advance or you die — no backtracking, no farming. This is the engine of roguelite tension and the soul of the *Snowpiercer* premise.
2. **The environment is the weapon.** Positioning and forced movement matter as much as damage. Furniture, glass, water, and walls are all tools. A clever shove beats a big gun.
3. **Readable determinism.** Physics is always previewed and always plays out as shown. No physics RNG. Players plan slams like chess moves. (RNG lives only in gunfire — and physics is how you remove it.)
4. **Mercy is a resource.** Sparing, recruiting, and killing each carry mechanical weight. The kindest path and the strongest path are not always the same.
5. **The squad is the story.** Permadeath makes each survivor accrue history — names, scars, kills, the friends they outlived. Attachment is generated through play, then weaponized by loss.
6. **You are the eye, not the hand.** You never touch a rebel directly — you watch through hijacked security cameras and *direct*. Every UI abstraction is something the camera grid can actually show you. You can see what's coming; you cannot reach through the screen to stop it.

### 3.1 The player's role (framing)

You are a **remote operator** — a sympathizer (or rogue AI; left open) who has **breached the train's surveillance grid**. You do not control a body on the train. You watch the uprising through **hijacked security cameras**, one car at a time, and issue orders to the rebels over comms. This single conceit pays for the whole design:

- **One fixed camera per car** → the top-down, single-screen-per-room view is *literally the feed*.
- **Turn-based** → you issue orders down a comms line; you are a tactician, not a twitch player.
- **Perfect-information physics preview (§6.7)** → you are reading the feed and running the angles before you commit an order; what you predict is what plays out.
- **Recon, but no path choice (§8.2)** → you can hack the **next** camera down the line to see what's coming, but the train is a single track — you cannot reroute it, only prepare.
- **Drafting your cell (§7.1)** → before the breach you recruit volunteers from the tail over the same network, vetting them three at a time.
- **Distance + attachment** → you grow attached to people you can only ever see through a screen and can never physically save. Permadeath hits through glass.

Recommended visual register (see §15): a **surveillance/ops console** — CRT scanlines, camera IDs (`CAR 14 — AQUARIUM`), feed grain, a comms log. Stylish, cheap to render, and it *is* the fiction.

---

## 4. Core loops

**Moment-to-moment (a single encounter)**
Assess the car → read cover, hazards, destructibles, and enemy positions → set up physics (shove furniture, soak enemies, shatter cover) → convert setups into kills → manage AP, reactions, and downed allies → clear or bypass → loot.

**Run-to-run (one attempt, tail → engine)**
Draft your cell (§7.1) → **recon the next car(s)** (§8.2: see type + hazards + modifiers + reward, but the path is fixed) → prepare accordingly → resolve the car (fight / trade / recruit / event / rest) → spend resources, level up, equip loot, manage the Order meter → advance down the single line through 5 sections → confront the Conductor's chamber → win, or wipe.

**Meta (across attempts)**
Spend earned currency on permanent unlocks (new classes, recruit pools, gear in the pool, new car types, Tail upgrades) → inherit a fallen hero's Legacy → start a stronger, more varied next run.

---

## 5. Combat system

### 5.1 Turn structure
- **Team-based turns** (XCOM-faithful): the player moves **all** units, then the enemy moves all units. Simple, readable, good for setups.
- A round = player phase + enemy phase + environment phase (floods spread/recede, hazards tick, fires burn, traps cycle).

### 5.2 Action economy
- Each unit has **2 Action Points (AP)** per turn.
- **Move** = 1 AP (up to the unit's Move range). A unit may move twice (Dash).
- **Attack / shove / slam / throw / use item** = generally 1 AP. Most *attacks* end the turn unless a trait says otherwise; *physics actions do not* end the turn — you can shove then shoot, or move then slam.
- **Heavy actions** (some abilities, big sabotage) cost 2 AP.
- **Overwatch / reaction** = spend remaining AP to set a reaction trigger (fires on enemy entering line of fire). Some classes get physics reactions ("counter-shove anyone who melees me").
- **Free chains:** physics chain reactions cost no extra AP. One shove that knocks an enemy into two others, into a fish tank, is a single 1-AP action — *this is where the depth lives.* Reward setup, not button count.

### 5.3 Grid, movement, line of sight
- Tile grid per car (suggested ~12×8 to ~18×10). Tiles carry: terrain type, cover value, integrity, hazard flag, occupancy, and a "wet/onfire/etc." status layer.
- **Line of sight** is tile-traced and blocked by full cover and tall objects. Flanking = attacking a target whose cover doesn't protect against your angle.

### 5.4 Attack resolution (the only RNG)
`HitChance = BaseAccuracy − CoverPenalty − RangeFalloff + FlankBonus + StatusMods`
- **Cover**: Half cover (−20 to be hit) / Full cover (−40). Destructible — see §6.5.
- **Flanking** removes the target's cover bonus entirely.
- **Status** (§5.5): *Soaked*, *Prone*, and *Stunned* targets are far easier to hit (prone ≈ guaranteed; this is the physics→damage payoff).
- Damage is mostly fixed with a small variance band; crits on flanks. All randomness draws from the **single seeded run PRNG** so runs are reproducible.

### 5.5 Status effects (core set)
| Status | Cause | Effect |
|---|---|---|
| **Prone** | Slammed, knocked down by a flood wave, certain abilities | Loses cover; very high incoming hit chance; must spend 1 AP to stand |
| **Stunned** | Wall impact above a force threshold, stun gear | Skips next action / reduced AP |
| **Soaked** | Standing in flood water | +incoming hit; **chains electricity**; reduced accuracy; can be swept by current |
| **Burning** | Fire hazards, incendiary, ignited gas | DoT; spreads to adjacent flammable tiles/objects; *cancels Soaked* |
| **Poisoned** | Standing in gas; lingers a few turns after leaving | DoT + reduced accuracy; *not* immediately lethal — area-denial/attrition. Negated by masks / *Iron Lungs* / Steward Rebreather (Sub-Spec D) |
| **Shocked** | Electrified water + power source | AoE chain through all connected soaked tiles; heavy stun |
| **Blinded** | Steam clouds, flashbangs | Sharply reduced accuracy / broken line of sight for a turn |
| **Chilled** | Cold air, snow, ice, falling through ice | −Move and −accuracy; stacks toward Frozen (snow/ice biome — Sub-Spec E) |
| **Frozen** | Chilled stacks reaching threshold; deep cold | Skips its turn (like a hard Stun) until thawed (heat/fire clears it) |
| **Bleeding (Downed)** | Unit hits 0 HP | See §7.4 — a revive window before permanent death |
| **Suppressed** | Enemy overwatch / area fire | Movement-restricted; accuracy down |

---

## 6. Physics system *(the centerpiece — build this carefully)*

This is the load-bearing differentiator. Model it as a **deterministic impulse resolver**, *not* a real-time physics engine. Everything previews; everything is reproducible.

### 6.1 Entities and properties
Every interactive object — units, furniture, barrels, fish tanks, robots, debris — carries:
- `mass` (integer class: Light / Medium / Heavy / Anchored)
- `position` (tile coords)
- `movable` (bool; Anchored objects never move — walls, the Engine core)
- `integrity` (HP for objects; at 0 → break, triggering `onBreak`)
- `coverValue` (what it grants as cover)
- `onBreak` effect (none / shatter-to-flood / explode / collapse-to-debris / spill-hazard)

### 6.2 Impulse & forced movement
A shove/slam/throw applies an **impulse**: a `direction` + `force` (in tiles).
- **Effective displacement** = `force − massResistance(target)`. A Light object flies; a Heavy one barely budges.
- The target travels tile-by-tile along the vector until displacement is spent **or** it collides.

### 6.3 Collision resolution
When a moving entity enters an occupied/blocked tile:
- **Wall / Anchored object** → entity stops; takes **impact damage = remaining force × impactScalar**; if remaining force ≥ stun threshold → **Stunned + Prone**.
- **Another movable entity (the billiards combo)** → momentum transfer: both take collision damage; the struck entity is pushed with `remainingForce − absorption(mass)`; the chain continues recursively. One shove can ripple through a crowd.
- **Destructible object** → object takes integrity damage; if it breaks, fire its `onBreak` (flood/explosion/collapse); the moving entity may stop or pass depending on remaining force.
- **Hazard tile** (gap between cars, open furnace, electrified rail) → environmental kill or heavy damage. Shoving an enemy off the train is a legitimate, satisfying win condition.

### 6.4 Knockdown & prone
Any entity that hits a wall above a low force threshold, or is caught by a flood wave, is knocked **Prone** (and **Stunned** above a higher threshold). Prone strips cover and makes the next attack near-automatic — the explicit bridge from §6 physics to §5.4 damage.

### 6.5 Destructibles & cover dynamism
- Cover is **not static**. Crates, tables, glass partitions, and railings have integrity and can be destroyed by gunfire, explosions, or physics. Shooting away an enemy's cover, or shoving a table to *create* cover for yourself, are core plays.
- Furniture can be **pushed to relocate cover** or **thrown** (by Bruisers) as a projectile that damages and knocks down on impact.

### 6.6 The Flood *(marquee mechanic)*
- **Trigger:** a fish tank / water main / coolant tank breaks (shot, slammed into, or a body thrown through it).
- **Wave turn:** on the turn it breaks, a wave radiates outward N tiles, knocking **standing** units **Prone** and **Soaking** them (seated/anchored cover may resist). Light objects float and drift with the current.
- **Standing water:** flooded tiles persist for a few turns then **recede**. Units standing in water are **Soaked** (§5.5).
- **Electrify:** if water connects to a live power source (shoot a junction box, a robot shorts out, the Saboteur rigs it) → **Shocked** chains through every connected soaked tile. The Saboteur's signature combo: flood the room, herd enemies in, electrify.
- **Fire interaction:** water extinguishes fire; fire boils off water. Layered hazards create emergent puzzles.

### 6.7 Deterministic preview (non-negotiable UX)
Before committing any physics action, the UI shows the **full resolved outcome**: trajectory, every collision, who ends up where, what breaks, who goes Prone, and floods/explosions spawned — in the Into the Breach tradition. **Players must never be surprised by physics.** RNG belongs to bullets, not bodies.

### 6.8 Why physics + RNG synergize
The whole combat design is one loop: *gunfire is uncertain; physics is certain; you use the certain thing to make the uncertain thing reliable.* Shove an enemy out of cover → flank bonus. Knock them Prone → near-guaranteed hit. Soak them → easier to hit and one spark from death. Throw a table to make your own cover → safer next turn. This is the skill ceiling and the thing to protect in every balance pass.

---

## 7. Squad system

### 7.1 The Draft (starting squad)
You **draft your starting cell** before the run. Candidates are presented **three at a time**; you take one and three new ones replace them; **no candidate ever repeats**. You may draft **1–3 starters**, then breach. Each candidate shows their **archetype** and **traits** up front (full system: **Sub-Spec C — Roster**).
- **Choosing how many to draft is a risk dial:**
  - **Draft 3** → a known, controlled, resilient start; you've spent your guaranteed picks.
  - **Draft 1–2** → fewer bodies now, **open slots** you must fill via in-run **recruitment** (uncontrolled — you take who the train gives you), in exchange for a **meta-currency multiplier** (solo/duo runs pay out more). High risk, high reward, high flex.
- **Caps:** soft cap **4**, hard cap **5** (raised by meta-unlocks). Grow by recruiting **sympathetic citizens** (§8.4, §9). The cell swells across a successful run and is thinned by death — the literal shape of the uprising.

### 7.2 Archetypes & traits (summary — full detail in Sub-Spec C)
Every character is an **archetype** (their role/kit) **+ 1–2 traits** (modifiers that make two of the same archetype play differently). Archetypes each interact with the physics system distinctly:

| Archetype | Role | Physics identity | Signature |
|---|---|---|---|
| **Bruiser** | Frontline / tank | The displacement engine — best shoves, slams, and **throws furniture/bodies** | Grab-and-slam; charge that knocks a line Prone |
| **Marksman** | Ranged DPS | *Cashes in* physics setups — bonus vs. Prone/Soaked/flanked | Aimed shot; overwatch lattice |
| **Saboteur** | Tech / environment | Rigs destructibles, **hacks robots**, electrifies floods, sets traps | Remote-detonate; turn an enemy bot to your side |
| **Steward** | Support / medic | Stabilizes Downed allies, heals, buffs; light crowd-shove | Revive-window extender; cleanse Soaked/Burning/Poisoned |
| **Firebrand** | Momentum / morale | Glass cannon that **grows stronger the further forward you push** | Squad rally; reckless lunge |

**Traits** attach to drafted *and* recruited characters — positive, negative, or mixed (e.g., *Steady Hands* +accuracy; *Coward* may break at low HP; *Informant* extends your recon; *Iron Lungs* immune to gas; *Conductor's Kin* a hidden loyalty risk). Recruits roll their archetype + traits on join. The **full archetype kits, the trait taxonomy, and a large starter trait list are in Sub-Spec C.**

### 7.3 Leveling & abilities
- Units earn XP from kills, objectives, and mercy outcomes. On level-up, **pick 1 of 2** abilities (lightweight XCOM-style tree). Keep branches expressive but small.
- Abilities are **data-defined** (§21) so the agent can add content without touching the engine.

### 7.4 Permadeath, bleed-out, revive, legacy
- At 0 HP a unit is **Downed (Bleeding)** for *X* turns. A Steward or adjacent ally can **stabilize** within the window. Unstabilized — or finished off by the enemy — the unit dies **permanently** for the run.
- Dead units **drop their gear** on the tile; survivors can recover it (a tactical "reach the body" objective under fire).
- **Total squad wipe = run over.**
- **Legacy (meta):** a fallen hero can be enshrined in the **Memorial**; a future run may inherit one Legacy item or trait from them. Loss becomes continuity.

---

## 8. The Train — run structure

### 8.1 Sections (acts)
The train is five escalating **Sections**, mapping to *Snowpiercer*'s class strata. Each ends in a **Section Captain** (elite mini-boss / gate).

| # | Section | Vibe | Difficulty |
|---|---|---|---|
| 1 | **The Tail** | Dark, cramped, scavenged | Tutorialized intro |
| 2 | **Third Class** | Industrial, crowded, utilitarian | Rising |
| 3 | **Second Class** | Services, gardens, aquaria (flood-rich) | Mid |
| 4 | **First Class** | Opulent, sterile, well-guarded | Hard |
| 5 | **The Engine** | Metal, automated, hostile architecture | Finale (§13) |

~3–5 cars per section → ~15–25 cars per run.

### 8.2 The Line & Recon (no path choice)
**The train is a single track.** A run is a **fixed linear sequence** of cars, generated from the run seed — varied run-to-run, but *immutable within a run*. **You never choose the path.** What you choose is how to *prepare* for it.
- **Recon (camera hijack):** you can always see the **next car** in **full** — type, enemy composition, hazards/traps, modifiers, and reward. The car **after that** shows as a **partial** preview: its type and a single threat/hazard tag, but not full enemy detail. Everything beyond is dark until you advance.
- **Deep Scan (optional spend):** spend **Tools** to hijack a camera **two cars out** for full detail — buy down uncertainty when you can afford it.
- **The decision space** is therefore *preparation, not routing*: you see a Poison-Gas car with heavy security coming in two rooms, so you spend this Workshop's upgrade on filters, hold your AoE, top up HP at the Med car now, and decide whether to recruit the Steward you can see ahead. Foreknowledge + permadeath = tense planning without a branching map.
- **Replayability** comes from the seeded sequence, the modifier rolls, your **draft**, and your build — not from picking doors. (This is the deliberate revision of decision **D5**; it also keeps faith with the camera framing in §3.1.)

> Implementation: the run is a `CarInstance[]` line + a `position` index + a `recon_depth` (default: next = full, +1 = partial, Deep Scan = +1 full). See §17.2 and the updated `RunState` schema in §21.

### 8.3 Car types (what the line is built from)
| Car | Function |
|---|---|
| **Security (Combat)** | Main-path fight; guards block advancement |
| **Flood / Destructible** | Combat built around a marquee hazard (aquaria, coolant, gas mains) |
| **Workshop / Armory (Upgrade)** | No guards; pick an upgrade, weapon, or mod |
| **Bourgeois Lounge** | Wealthy citizens — spare for **gear/intel/buff**, or kill for an instant resource grab (raises Order — §9) |
| **Sanctuary (Recruit)** | A sympathetic citizen wants to join — accept for a new squadmate (sometimes at a cost) |
| **Event** | FTL-style branching text choice with mechanical outcomes |
| **Med Car (Rest)** | Heal, stabilize, sometimes revive — scarce |
| **Black Market (Shop)** | Spend currency on gear/consumables/services |
| **Section Captain** | Elite gate at each section break |
| **Conductor's Chamber** | The Engine — final encounter (§13) |

> **Set-piece / amenity cars** layer *theme + bespoke mechanics* on top of these base types — the elite's absurd luxuries (ski slope, ice rink, spa, hedge maze, dining hall, greenhouse, indoor forest). Their full designs and the small physics/hazard extensions they require are in **Sub-Spec E — Set-Piece Cars & Biomes**. They cluster in Sections 3–4, so the decadence sharpens exactly as you near the Engine.

### 8.4 Room modifiers (positive / negative)
Rolled per car, **visible during recon** (§8.2). Modifiers tune difficulty and flavor; **hazards and cycling room traps are specified in full in Sub-Spec D**. A starter library:

**Negative**
- *Cramped* — reduced Move range.
- *Flickering Lights* — reduced sight; ambush risk.
- *Steam Vents* — rotating hazard tiles.
- *Open Roof* — cold DoT each turn; pushes a tempo race.
- *Lockdown* — timed reinforcements arrive.
- *Overpressure* — every destructible break triggers a flood.
- *Sealed Bulkheads* — fewer destructibles; physics-light.

**Positive**
- *Loose Cargo* — extra movable furniture (more physics toys).
- *Sympathizers* — a civilian assists you mid-fight.
- *Sabotaged Security* — enemies start with degraded cover.
- *Supply Drop* — free consumables on the field.
- *Zero-Stabilizer Section* — **displacement doubled** (chaos mode; high risk/reward).

Modifiers are **data-defined and stackable**; treat them as a content lever for difficulty and flavor.

---

## 9. Moral economy — spare / kill / recruit + the Order meter

- **The Order meter** is a run-wide gauge of the train's alarm/response. Killing civilians, loud breaches, and cruelty raise it; mercy and clean fights keep it low.
- **High Order** → tougher reinforcements, earlier lockdowns, the Conductor deploys elites sooner, and the finale gets harder. The system fights back when you escalate — thematically and mechanically.
- **Bourgeois citizens:** **Spare** → gear / intel / one-time buff (the long game). **Kill** → instant scrip/supplies but +Order and you forfeit what they were holding (the greedy play).
- **Recruits:** sympathetic citizens join your cause — but some carry **risky traits** (§7.2), and a rare event recruit may be a plant. Trust is textured, not free.
- **Endings hook:** cumulative Order and key moral choices steer the §13 ending. The kindest run and the strongest run diverge — by design.

---

## 10. Economy & resources

| Resource | Use |
|---|---|
| **HP** (per unit) | Survival; gated by permadeath |
| **Armor / Integrity** | Soaks damage (unit armor and tile cover) |
| **AP** (2/turn) | Action economy |
| **Scrip** | Currency for the Black Market |
| **Supplies** | Heals / stabilizes / some consumables |
| **Tools** | Sabotage, hacking, trap-setting |
| **Grenades / Consumables** | One-shot tactical items (incendiary, flashbang, breach charge) |
| **Order** | Run-wide difficulty + morality gauge (§9) |
| **XP** | Per-unit leveling |

Scarcity is the point: you cannot have everything, and the train never lets you go back for more.

---

## 11. Loot & gear

- **Weapons** (melee/ranged) with stat and physics riders (e.g., a maul with high knockback; a shotgun with a built-in shove-on-hit).
- **Armor** (HP/Integrity, sometimes physics resistance — "magnetic boots" resist being shoved).
- **Gadgets** (grapple to *pull* enemies, breaching charges, portable junction box for on-demand electrified water).
- Gear is **equipped per unit**, recoverable from the dead, and **data-defined** for easy expansion. Gear that interacts with physics is the most interesting tier — bias the loot pool toward it.

---

## 12. Enemies

Each enemy has a **physics interaction** that creates the rock-paper-scissors.

| Tier | Enemy | Behavior | Physics counter-design |
|---|---|---|---|
| Tail / 3rd | **Truncheon Guard** | Basic melee | Standard — easy to slam |
| Tail / 3rd | **Riot Shield** | Blocks **frontal** shoves/fire | Must flank, soak-to-Prone, or hit from the side with an object |
| 3rd / 2nd | **Net Gunner** | Immobilizes a unit | Priority kill; break LoS with thrown cover |
| 2nd / 1st | **Enforcer** | Armored ranged | Strip cover, then flank; flood to remove armor's footing |
| 2nd / 1st | **Hound** | Fast flanker | Reaction-shove on approach; bait into hazards |
| 1st | **Sniper** | Overwatch threat | Break LoS; close distance via thrown cover |
| 1st | **Drone Operator** | Deploys small bots | Kill operator; Saboteur hacks the bots |
| Gate | **Section Captain** | Unique gimmick (e.g., *unshovable until Soaked*, or *buffs nearby guards*) | Each is a physics puzzle with a specific "key" |
| Engine | **Security Robot** | Heavy, **hackable** | Saboteur converts; shove into traps/pistons |
| Engine | **Sentry Turret** | Static, destructible | Destroy or block LoS; reposition cover |

AI: start **rule-based** (target selection → use cover → use physics when advantageous → call reinforcements at thresholds), with a **utility-scoring** upgrade path later. Enemies should *occasionally* shove the player too — physics cuts both ways.

---

## 13. The Conductor's Chamber — finale

A large, hostile, multi-phase arena in the Engine. The room itself is an antagonist.

- **Phase 1 — The Antechamber.** Automated defenses: **sentry turrets**, patrolling **security robots**, and **trap tiles** (pistons, electrified floor plates, steam jets) that cycle on a visible timer. Physics is survival: shove robots into pistons, herd them onto plates, use the room against itself.
- **Phase 2 — The Conductor.** A unique antagonist who is **physically fragile but shielded by the Engine's systems** — they re-route the train to spawn hazards, summon robots, and trigger traps. You can't simply out-DPS them; you must **disable the Engine's defenses** (the Saboteur's moment) while surviving the onslaught.
- **Objective, not a sponge — "Stop the Train."** The win condition is reaching and sabotaging the **Engine core** under a pressure timer (XCOM-2-style objective), not draining an HP bar. The whole toolset converges here.
- **Endings (steered by §9 Order + key choices):**
  - *Hard Stop* — you stop the train. The world outside is lethal cold; the system ends, but at a cost. (The bleak, faithful ending.)
  - *Seize the Engine* — you take control rather than destroy it; a different, ambiguous future.
  - *Pyrrhic* — you win with a gutted squad (heavy losses / high Order); the uprising survives but barely.
  - Stretch: a hidden ending gated by a fully-merciful, low-Order run.

---

## 14. Meta-progression

Permadeath ends the attempt; the **rebellion persists**.
- Spend a meta-currency (earned per run, win or lose) on permanent unlocks: **new starting classes, expanded recruit pools, new gear in the loot pool, new car types, Tail upgrades** (better starting squad/resources), and **narrative unlocks**.
- **Legacy / Memorial** (§7.4): inherit a fallen hero's item or trait into a future run.
- Roguelite, not roguelike: each run starts from a stronger, more varied baseline (Hades/Dead Cells retention model).

---

## 15. Art direction & audio (brief — programmer art is fine for MVP)

- **Visual escalation front-to-back:** Tail = dark, grimy, claustrophobic → Engine = sterile, bright, metallic and inhuman. The journey is legible in the palette alone.
- **Style:** stylized isometric — chunky low-poly or crisp pixel-iso both work and are solo-buildable. (A dithered, crushed-black, low-saturation grade would slot neatly into an existing lo-fi pipeline if desired — optional.)
- **Readability first:** cover, hazards, water, fire, and Prone/Soaked states must read instantly at a glance. Clarity beats fidelity.
- **Audio:** rhythmic industrial clatter of the rails as a constant bed; impact/slam/shatter/flood need juicy, distinct feedback — physics is the fantasy, so *sell every collision*.
- **For MVP:** flat-colored tiles and simple sprites/primitives. Do not block engineering on art.

---

## 16. UX / UI essentials

- **Frame the whole UI as a surveillance/ops console** (§3.1): camera ID labels (`CAR 14 — AQUARIUM`), CRT/scanline treatment, a comms log for orders and barks. Diegetic and cheap to render.
- **Physics preview is the #1 UI feature** (§6.7): full resolved outcome before commit — "the operator running the angles on the feed."
- **Cover & flank indicators** on every targetable enemy (shield icons à la XCOM).
- **Recon strip** (§8.2): the **next car** shown in full (type, enemies, hazards, modifiers, reward) and the car after as a **partial** silhouette; a **Deep Scan** button (spend Tools) reveals one more. *No path-choice UI — the line is fixed; this strip is for preparation, not routing.*
- **Status iconography:** Prone / Soaked / Stunned / Burning / Shocked / **Poisoned** / Bleeding at a glance.
- **Hazard telegraphs:** cycling-trap timers (fire vents, lasers, pistons, plates) and spreading-hazard fronts (fire, gas, water) shown one turn ahead (Sub-Spec D).
- **Order meter** always visible with a clear cause-and-effect tooltip.
- **Undo for movement only** (not for committed attacks/physics) to reduce misclick frustration without removing consequence — The Gamer's anti-frustration line.

---

## 17. Technical architecture

**Engine decision: Godot 4.x, GDScript primary. Unity (C#) is the documented fallback.** Target: one shared codebase exporting to **Android, iOS, Windows, macOS, Linux**.

### 17.0 Engine decision & rationale
This game does **not** use the engine's built-in physics — combat runs on our own deterministic integer resolver (§6 / Physics Resolver sub-spec). So the engine's job is rendering, input (touch + mouse + gamepad), UI, audio, scene flow, and the **mobile export pipeline**. That reframes the choice around *what an agent can drive from text files* and *what ships to phones cleanly*.

| Factor | Godot 4 (chosen) | Unity (fallback) |
|---|---|---|
| **Text-first authoring** | Scenes `.tscn`, resources `.tres`, scripts `.gd` are **plain text, diffable, hand-authorable**. Scenes/UI/data can be built and reviewed as code. | Scripts (C#) are fine, but scenes/prefabs are GUID-laden YAML meant for the GUI — painful to author or review as text. **This is the deciding factor.** |
| **Mobile + PC export** | One project → all five targets. Free, MIT, no royalties/runtime fee. | Most mature mobile pipeline (iOS provisioning, ad/IAP SDKs, device perf tooling). Policy volatility is a real cost. |
| **2D isometric tactics** | First-class 2D (`TileMapLayer`), pleasant for iso. | Capable (Tilemap), historically more bolted-on. |
| **Determinism** | We own the integer sim → engine physics irrelevant. GDScript is fine if the sim uses **integers only + a hand-rolled seeded PRNG**. | Same — we own the sim in C#. |
| **Cost / licensing** | Free, MIT, royalty-free. | Free under revenue thresholds; 2023 runtime-fee whiplash hurt trust. |

**Pick Unity instead only if** the plan leans on aggressive mobile monetization (ads/IAP networks), you need the smoothest possible iOS store path, or you already have deep Unity muscle memory. For a premium-leaning tactics roguelite built largely via an agent, **Godot wins on the authoring workflow you're optimizing for.**

> **Language note (Godot):** GDScript for the whole project keeps it single-language, hot-reloadable, and smoothest to export to iOS/Android. The catch is that the deterministic sim must be written under a strict *integer-only, no-float, seeded-PRNG* discipline (enforced by convention + golden tests). If you want stronger typing for `/core`, you may write the sim in **C#** and keep glue in GDScript — but C# export to iOS is newer/rougher, so only do this if the type-safety is worth the build friction. **Default recommendation: GDScript throughout.**

### 17.1 Separation of concerns
Keep the sim engine-agnostic (plain `RefCounted` classes, **no `Node`/SceneTree dependencies**) so it runs headless in tests and the renderer stays swappable.
```
res://core/      — deterministic simulation (RefCounted only, ZERO SceneTree deps, fully tested)
res://content/   — data-defined classes, enemies, abilities, items, cars, modifiers (.tres / .json)
res://ai/        — enemy decision layer over the command system
res://render/    — Godot scenes/nodes: read sim state + event stream, animate (TileMapLayer 2D-iso)
res://meta/      — persistence: unlocks, Legacy/Memorial, settings (user:// saves)
res://app/       — wiring, input (touch/mouse/gamepad), scene/run flow, main menu
res://tests/     — GUT (Godot Unit Test) suites; golden-file fixtures
```

### 17.2 Core simulation model
- **Entity model:** pragmatic component-style typed objects on plain `RefCounted` (full ECS is over-scoped here). Fields: `Position`, `Health`, `Mass`, `Cover`, `Faction`, `AbilitySet`, `StatusSet`, `Inventory`.
- **Grid:** `Tile { terrain, coverValue, integrity, hazard, occupantId, statusLayer }`; a `Car` owns a tile grid + entity list + modifier list. Tile coords are **`Vector2i`** (integer).
- **Turn manager:** team-based phases (player → enemy → environment).
- **Command pattern:** every action is a `Command` (`Move`, `Shoot`, `Shove`, `Slam`, `Throw`, `UseItem`, `Overwatch`, `Hack`). Commands **validate → apply → emit events**. Deterministic, replayable, testable; the renderer animates from the emitted event list.
- **Physics resolver** (§6 + sub-spec): pure function `resolve_impulse(state, entity_id, dir, force) → ResolutionResult{events, diffs}`. **Integer math only — no floats in `/core`.**
- **Combat resolver** (§5.4): to-hit and damage, drawing exclusively from the seeded PRNG.
- **RNG:** one **hand-rolled integer PRNG** (e.g., xoshiro128** or mulberry32 ported to GDScript) threaded through state. Do **not** use the global `randi()`. (Godot's `RandomNumberGenerator` is seedable, but a hand-rolled integer PRNG guarantees identical streams across platforms — preferred for `/core`.) Same seed → same run. Physics never touches RNG.
- **Run generator:** `generate_run(seed, unlocked_content) → CarLine` (a **single linear sequence** of car instances across the 5 sections — no branching, per §8.2); rolls each car's modifiers, hazards, and rewards. Recon visibility is a read over this line, not a graph traversal.

### 17.3 Data-driven content
All classes, abilities, enemies, items, car templates, and modifiers are **external data** (custom `Resource` `.tres` files, or `.json` loaded into typed objects — see §21 schemas). The engine reads data; adding content = adding data files, not editing systems. This is what lets an agent expand the game safely and fast.

### 17.4 Determinism checklist (hard requirements)
- No floats in `/core` (positions `Vector2i`, all math integer). Seeded integer PRNG only — no `randi()`, no wall-clock, no frame-time. Iterate collections in **stable, explicit order** (sort by id where iteration affects outcome). Commands fully replayable from `(seed, inputLog)`. **A run must be reproducible from its seed + input log** — this underpins testing, bug repro, and daily-seed/leaderboard features later.

### 17.5 Testing
- The sim runs **headless** (run a CLI/headless Godot scene, or pure-script GUT tests with no rendering). Write unit tests for the **physics resolver first** (collision chains, wall impact, flood spread, electrify — the worked examples in the Physics sub-spec double as fixtures), then combat resolution, then run generation. Golden-file tests on `(seed → resolved encounter event list)` catch regressions.

### 17.6 Mobile + PC UX layer
- **Input abstraction:** route everything through an `InputIntent` layer so touch, mouse, and gamepad map to the same commands. Tap-to-select, tap-target-to-preview, tap-confirm-to-commit (the two-tap commit pairs naturally with the §6.7 physics preview).
- **Responsive UI:** anchor-based UI that scales from phone portrait/landscape to desktop; large touch targets; the physics-preview overlay and status icons must read on a ~5–6" screen.
- **Performance:** turn-based + 2D + our lightweight sim is trivial for mobile; budget is dominated by VFX (floods, shatter, electrify) — keep particle counts mobile-sane and pool them.
- **Single-screen-per-car** framing keeps the camera simple and touch-friendly (no fiddly scrolling mid-decision where avoidable).

---

## 18. Build roadmap *(start here)*

Phased so the agent always has a runnable build and the differentiator (physics) lands early.

- **Phase 0 — Core skeleton.** Grid, entities, team-based turns, Move + basic ranged attack (with to-hit), one combat car, win/lose. Headless + a minimal renderer. Seeded PRNG in place. *Exit:* you can clear a single hand-built car.
- **Phase 1 — Physics layer (vertical slice).** Shove / slam / throw, collision chains, wall impact, Prone, destructible objects, and the **Flood** (wave → soak → electrify → recede). Full **trajectory preview**. *Exit:* you can win a fight primarily through displacement and a flood. **This is the proof-of-fun gate.**
- **Phase 2 — Tactics depth.** Cover tied to destructibility, flanking, overwatch/reactions, the full status set, fire×water interactions.
- **Phase 3 — Run structure.** Section→car node map, branching, scouting + modifiers, the car-type deck (combat / upgrade / bourgeois / recruit / event / rest / shop), currency + resources.
- **Phase 4 — Squad & progression.** Classes, leveling (1-of-2 abilities), gear/loot, recruitment, permadeath + bleed-out/revive, the Order meter.
- **Phase 5 — Content & enemies.** Full enemy roster, Section Captains, modifier library, items, events.
- **Phase 6 — Finale.** Conductor's Chamber multi-phase, traps, robots, objective-based "stop the train," endings.
- **Phase 7 — Meta & polish.** Unlocks, persistence, Legacy/Memorial, balance passes, feedback/juice, audio, art pass.

---

## 19. MVP definition (first milestone acceptance criteria)

The MVP = **Phase 0 + Phase 1**. It is "done" when:
1. A single combat car is fully playable with a 2-unit squad, 2-AP turns, and team-based phases.
2. Ranged attacks resolve with cover/flank to-hit from a **seeded** PRNG (reproducible).
3. Shove, slam, and throw work with **deterministic, previewed** trajectories and billiards-style collision chains.
4. At least one **fish tank** can be broken to trigger a flood that knocks enemies **Prone**, **Soaks** them, and can be **electrified** for a chain.
5. The encounter is **winnable primarily through physics** (a player who never fires a gun can still win a designed scenario).
6. The whole encounter runs **headless** and is covered by physics unit tests.

If the MVP is fun, the game is fun. Everything after Phase 1 is content and structure around a proven core.

---

## 20. Open questions / stretch (revisitable, non-blocking)

- **Initiative variant:** team-based now; consider per-unit initiative later for tempo variety.
- **Daily seed / leaderboards:** determinism makes this cheap to add post-launch.
- **Friendly-fire physics:** do player units take collision damage too? (Lean yes, for stakes — tune carefully.)
- **Verticality:** single-plane cars for MVP; multi-level cars (catwalks, drop-shoves) as a stretch.
- **Co-op / async:** out of scope for v1; the deterministic core wouldn't fight it later.
- **Narrative depth:** how authored vs. emergent should events be? (Start emergent + templated; author set-pieces for Section Captains and the finale.)

---

## 21. Appendix — example data schemas

Representative shapes for the data-driven content layer. Treat as a starting contract, not final.

```typescript
// ---- Class ----
interface ClassDef {
  id: string;                 // "bruiser"
  name: string;
  role: "frontline" | "ranged" | "tech" | "support" | "momentum";
  baseStats: { hp: number; move: number; accuracy: number; mass: "light"|"medium"|"heavy" };
  startingAbilities: string[];      // ability ids
  abilityTree: Array<[string, string]>; // per level: 1-of-2 choices
}

// ---- Ability ----
interface AbilityDef {
  id: string;                 // "grab_and_slam"
  name: string;
  apCost: number;
  endsTurn: boolean;
  targeting: "self" | "ally" | "enemy" | "tile" | "direction";
  range: number;
  effects: EffectDef[];       // e.g. {kind:"impulse", force:4}, {kind:"status", status:"prone"}
}

// ---- Enemy ----
interface EnemyDef {
  id: string;                 // "riot_shield"
  name: string;
  tier: 1 | 2 | 3 | 4 | 5;
  stats: { hp: number; move: number; accuracy: number; mass: string };
  physicsTrait?: "blocks_frontal_shove" | "unshovable_until_soaked" | "magnetic_boots" | null;
  abilities: string[];
  aiProfile: "melee_rush" | "ranged_hold" | "flanker" | "support" | "robot";
}

// ---- Interactive Object ----
interface ObjectDef {
  id: string;                 // "fish_tank_large"
  mass: "light" | "medium" | "heavy" | "anchored";
  integrity: number;
  coverValue: 0 | 1 | 2;       // none / half / full
  onBreak: "none" | "flood" | "explode" | "collapse" | "spill_fire";
  floodRadius?: number;        // if onBreak === "flood"
}

// ---- Car template ----
interface CarTemplate {
  id: string;
  type: "combat" | "flood" | "upgrade" | "bourgeois" | "recruit" | "event" | "rest" | "shop" | "captain" | "engine";
  section: 1 | 2 | 3 | 4 | 5;
  gridSize: { w: number; h: number };
  layout: TileSpec[];          // terrain, cover, objects, spawn points
  enemySpawns?: EnemySpawn[];
  rewardTable?: string;        // id into loot/reward tables
  allowedModifiers: string[];  // modifier ids eligible to roll here
}

// ---- Modifier ----
interface ModifierDef {
  id: string;                 // "zero_stabilizer"
  name: string;
  polarity: "positive" | "negative";
  effects: EffectDef[];       // e.g. {kind:"displacement_mult", value:2}
}

// ---- Run state (serializable, reproducible) ----
interface RunState {
  seed: number;
  inputLog: Command[];         // full replay from seed + this log
  order: number;               // the Order meter
  currency: { scrip: number; supplies: number; tools: number };
  squad: UnitInstance[];       // includes Downed/dead status + inventory
  memorial: FallenHero[];      // Legacy candidates
  line: CarInstance[];         // the FIXED linear train (no branching) — generated from seed
  position: number;            // index into `line` (current car)
  reconDepth: number;          // how many cars ahead are revealed (next=full, +1 partial; Deep Scan +1 full)
  draftPayoutMult: number;     // meta-currency multiplier set by how few starters were drafted (§7.1)
}
```

---

## 22. Glossary

- **AP** — Action Points (2 per unit per turn).
- **Anchored** — an object that never moves (walls, Engine core).
- **Billiards combo** — a chain where one shoved body strikes others, transferring momentum.
- **Downed / Bleeding** — a unit at 0 HP with a revive window before permanent death.
- **Flood / Soaked / Shocked** — the marquee water hazard chain (§6.6).
- **Legacy** — a fallen hero's item/trait inherited into a future run.
- **Order** — the run-wide alarm/morality meter (§9).
- **Prone** — knocked down; no cover, near-guaranteed to be hit, costs AP to stand.
- **Draft** — the pre-run selection of 1–3 starters, shown 3 non-repeating candidates at a time (§7.1, Sub-Spec C).
- **Operator** — the player: a remote presence directing the uprising through hijacked security cameras (§3.1).
- **Recon / Deep Scan** — seeing the fixed upcoming car(s) without being able to choose the path (§8.2).
- **Section** — one of five escalating acts of the train.
- **Spreading vs. cycling hazards** — gas/fire/water that propagate vs. fire-vents/lasers/pistons that fire on a timer (Sub-Spec D).

---

*End of GDD v1.0. Build the MVP (§19), prove the physics is fun, then grow outward along the roadmap (§18).*
