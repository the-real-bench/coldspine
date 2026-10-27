# COLDSPINE — Sub-Spec C: Roster (Draft, Archetypes & Traits)

> Companion to COLDSPINE_GDD.md (§7). Defines who you command and how you assemble them.
> Build target: **Phase 4** (squad & progression), but the **Draft** is the very first thing the player does each run, so prototype it early.
> Framing (§3.1): you are the **operator**; the draft is you **vetting volunteers from the tail over the camera/comms network** before the breach.

---

## C0. Three pieces

1. **The Draft** — how you pick your starting cell (1–3 from 3-at-a-time, no repeats, with a risk dial).
2. **Archetypes** — the five role-kits, each with base stats, signature actions, and a small 1-of-2 ability tree.
3. **Traits** — 1–2 modifiers per character that make two of the same archetype play differently; positive, negative, mixed, or hidden.

A character = **one Archetype + 1–2 Traits + a name/portrait**. That triple is the atom of the roster.

---

## C1. The Draft

### C1.1 Flow
- Up to **3 draft rounds**. Each round shows **3 candidates** drawn from the run's candidate pool.
- Per round you may **Take one** (adds to the cell, advances to the next round) **or Decline** (take none this round, advance).
- You may **Stop drafting** at any point. You end with **1–3 starters**.
- **No candidate ever repeats:** every candidate shown (taken *or* passed) is removed from the pool. Passing burns them — choices have weight.
- Each candidate card shows: **Archetype**, **Traits** (hidden traits are *not* shown — see C3.5), name, portrait, and a one-line readout of their stat slant.

### C1.2 The risk dial (why draft fewer?)
Drafting fewer starters is a deliberate self-handicap with two payoffs:
- **Open slots** — every starter slot you *don't* fill must be filled by **in-run recruitment** (§9 / C4), which is **uncontrolled**: you take who the train offers, traits and all (including risk/hidden traits). More flex and surprise, more danger.
- **Meta-currency multiplier** — `draftPayoutMult` scales with how few you start with. Suggested: **3 starters ×1.0, 2 starters ×1.25, 1 starter ×1.6**. Solo/duo runs are harder and pay out more toward meta-unlocks.

> Design intent: a **3-draft** is the controlled, resilient default; a **1–2 draft** is the expressive, high-variance, high-reward line. Both are valid; neither is strictly better.

### C1.3 Candidate pool generation (deterministic)
From the **run seed** + unlocked content:
- The pool is **mostly procedural**: roll an **Archetype** (weighted by what's unlocked) + **1–2 Traits** (C3) + a generated name/portrait.
- A seeded chance surfaces a **Signature Character** — a named, fixed Archetype+Trait combo unlocked via meta-progression (flavor + a known quantity among the randoms).
- **Value variety is enforced**, not left to chance: the generator aims for a spread so a round can offer, e.g., a strong Archetype saddled with a bad trait next to a humble Archetype carrying a stellar trait. Flat all-good or all-bad rounds are the failure case — the draft should pose *tradeoffs*. (Implement as a simple value-banding pass over generated candidates.)

### C1.4 Determinism
The entire draft is reproducible from `(seed, player picks)`. Candidate generation draws only from the seeded integer PRNG (per GDD §17.4). `DraftState` (C5) is part of the replay log.

---

## C2. Archetypes

Five role-kits. **Base stats, signatures, and trees below are starting values — data-defined (C5), tune in playtest.** Each archetype has a distinct relationship to the physics system (Sub-Spec A) and the hazard system (Sub-Spec D). Ability tiers offer **1-of-2** picks on level-up (GDD §7.3); the **Capstone** is the final pick.

> Stat slants are relative (▲ high / ● medium / ▼ low). `mass` feeds the physics resolver (heavier = harder to shove).

### C2.1 Bruiser — *the displacement engine*
- **Slant:** HP ▲ · Move ● · Accuracy ▼ · **mass MEDIUM**
- **Signatures:** **Slam** (high-force shove, 1 AP) · **Heave** (throw a movable object or grappled body as a projectile, 1 AP)
- **Tree:**
  - **T1:** *Bull Rush* (moving into an enemy triggers a free shove) **/** *Bracing* (cannot be shoved unless **Soaked**)
  - **T2:** *Pin* (a Slam that ends on a wall also **Stuns**) **/** *Sweep* (Slam affects a 3-tile arc, knocking multiple **Prone**)
  - **T3:** *Bodyguard* (intercept overwatch aimed at an adjacent ally) **/** *Demolition* (×2 integrity damage to destructibles — pop tanks/walls fast)
  - **Capstone:** *Juggernaut* (immune to Prone; Slam force **+2**)
- **Reads against:** Riot Shields (flank or Soak-then-shove), Heavy robots (shove into pistons/hazards).

### C2.2 Marksman — *cashes in the setup*
- **Slant:** HP ● · Move ● · Accuracy ▲ · **mass LIGHT**
- **Signatures:** **Aimed Shot** (high-accuracy ranged, 1 AP, ends turn) · **Overwatch** (reaction)
- **Tree:**
  - **T1:** *Opportunist* (bonus damage vs **Prone/Soaked/flanked**) **/** *Steady* (don't end turn after the first shot if you didn't move)
  - **T2:** *Lattice* (Overwatch covers a cone, can fire on several targets) **/** *Pierce* (shots ignore half cover)
  - **T3:** *Killzone* (Overwatch triggers on **any** action in the cone, not just movement) **/** *Soaked-Spark* (shooting a **Soaked** target chains a small shock)
  - **Capstone:** *Deadeye* (a guaranteed-hit, high-damage shot on a long cooldown — the answer to the worst RNG moments)
- **Synergy:** the payoff unit for every physics setup — Prone/Soaked/flank from the Bruiser or a flood becomes near-certain damage here.

### C2.3 Saboteur — *the hazard wizard*
- **Slant:** HP ● · Move ● · Accuracy ● · **mass LIGHT**
- **Signatures:** **Rig** (set a charge/trap on a tile or object) · **Hack** (convert a robot, disable a turret, or energize a water junction)
- **Tree:**
  - **T1:** *Junction* (deploy a portable power source to **electrify water on demand**) **/** *Gas Tap* (vent a **poison-gas** cloud from a pipe/main — Sub-Spec D)
  - **T2:** *Remote Detonate* (your charges fire on command) **/** *Overclock Hack* (hacked robots act **twice**)
  - **T3:** *Pyro Loop* (**ignite gas clouds** for chain explosions) **/** *Coolant Master* (rupture tanks at range; **larger floods**)
  - **Capstone:** *System Seizure* (briefly **disable all cycling traps** in the car; in the finale, knocks out a hazard bank)
- **Identity:** the master key to Sub-Spec D. The flood→electrify and gas→ignite combos are this archetype's reason to exist.

### C2.4 Steward — *keeps the cell alive*
- **Slant:** HP ● · Move ▲ · Accuracy ▼ · **mass LIGHT**
- **Signatures:** **Stabilize** (stop a Downed ally bleeding out) · **Patch** (heal) · **Cleanse** (remove Soaked / Burning / **Poisoned** / Stunned)
- **Tree:**
  - **T1:** *Field Medic* (Stabilize at range) **/** *Adrenaline* (grant an ally **+1 AP**, once per fight)
  - **T2:** *Rebreather Kit* (grant the squad **gas/fire resistance** for N turns — the answer to a previewed Gas car) **/** *Triage* (extend the bleed-out window for the whole squad)
  - **T3:** *Rally Banner* (AoE Cleanse + small heal) **/** *Last Stand* (a Downed ally you reach fights one more turn before dying)
  - **Capstone:** *Guardian Protocol* (the **first** time each fight an ally would hit 0 HP, they survive at 1 instead — clutch, but does **not** break permadeath)
- **Note:** permadeath stays sacred — no archetype resurrects the permanently dead. The Steward buys *windows*, not immortality.

### C2.5 Firebrand — *momentum made flesh*
- **Slant:** HP ●▼ · Move ▲ · Accuracy ● · **mass LIGHT**
- **Core trait (innate):** **Momentum** — gains a stack each time the cell **advances a car** (buffs damage/move); **loses stacks when an ally dies**. A glass cannon that snowballs across a clean run.
- **Signatures:** **Lunge** (charge + attack) · **Rally** (buff nearby allies)
- **Tree:**
  - **T1:** *Zeal* (Momentum also raises accuracy) **/** *Reckless* (more damage, minor self-recoil)
  - **T2:** *Inspire* (ally kills grant the Firebrand AP) **/** *Martyr's Wake* (an ally's death grants a **burst of stacks** instead of losing them — flips the downside)
  - **T3:** *Warcry* (AoE that clears Suppressed/fear and grants Move) **/** *Overrun* (kills refund **Lunge**)
  - **Capstone:** *Vanguard* (at max Momentum, the first strike each turn is a guaranteed crit)
- **Identity:** the run's tempo dividend — rewards aggression and keeping everyone alive, punishes losses doubly (fiction + stacks).

---

## C3. Traits

### C3.1 What a trait is
A **modifier** attached to a character that alters stats, abilities, behavior, recon, economy, or morale. **1–2 traits** per character at creation. Traits are the texture that makes two Bruisers feel different and makes a draft choice a *judgment*, not a stat-compare.

### C3.2 How traits attach
- **Drafted** characters: traits are **rolled at pool generation** and **shown on the card** (except Hidden — C3.5).
- **Recruited** characters: traits are **rolled on join** and partially shown (a recruit may surprise you — C4).
- **Gained mid-run:** events, level-ups, and surviving an ally's death can **add** a trait (scars, bonds, grudges). Rarely, a Med-car/event can **remove** one.
- **Stacking:** a character holds at most **3** traits total (2 starting + room for 1 gained); design content so gained traits are meaningful, not spam.

### C3.3 Categories & polarity
- **Polarity:** `positive` / `negative` / `mixed` (a real upside *and* downside) / `hidden` (effect concealed until revealed).
- **Categories:** **Combat**, **Physics**, **Utility/Recon**, **Social/Morale**, **Risk**, **Hidden**.
- **Archetype affinity:** some traits only (or preferentially) roll on certain archetypes (`archetypeAffinity`).

### C3.4 Starter trait list

| Trait | Cat. | Polarity | Effect (starting) |
|---|---|---|---|
| **Steady Hands** | Combat | + | +accuracy |
| **Brawler** | Combat | + | +shove/melee force |
| **Crack Shot** | Combat | + | +crit chance on flanks |
| **Tough** | Combat | + | +max HP |
| **Hardened** | Combat | + | first hit taken each fight does reduced damage |
| **Glass Jaw** | Combat | – | −max HP; +damage taken from impacts |
| **Shaky** | Combat | – | −accuracy while Suppressed |
| **Planted** | Physics | + | harder to shove (effective mass +1) |
| **Sure-Footed** | Physics | + | immune to **Prone** from floods (still Soaked) |
| **Demolitions Expert** | Physics | + | +integrity damage to objects/destructibles *(affinity: Bruiser/Saboteur)* |
| **Featherweight** | Physics | ± | +Move, but easier to shove (both directions) |
| **Informant** | Utility | + | recon reveals **one extra** car (stacks with Deep Scan) |
| **Scavenger** | Utility | + | +scrip/loot from cleared cars |
| **Tinkerer** | Utility | + | +1 starting Tools; Tool costs reduced *(affinity: Saboteur)* |
| **Quartermaster** | Utility | + | squad carries +1 consumable slot |
| **Iron Lungs** | Utility | + | immune to **Poison gas** |
| **Fireproof** | Utility | + | reduced fire damage; no self-Burning spread |
| **Inspiring** | Social | + | adjacent allies +accuracy *(affinity: Firebrand/Steward)* |
| **Loyal** | Social | + | never breaks morale; +bond gain |
| **Merciful** | Social | ± | sparing yields extra rewards, but this unit's kills raise **Order** more |
| **Hardliner** | Social | ± | kills grant extra resources, but +Order and you **can't recruit** while they're in the cell |
| **Bonded: <name>** | Social | ± | buffed near the bonded ally; **grief debuff** if that ally dies |
| **Coward** | Risk | – | may flee/skip its turn below 25% HP |
| **Bloodthirsty** | Risk | ± | +damage, but **must attack** if able (can't freely hold/overwatch) |
| **Reckless** | Risk | ± | +Move/+damage, but won't always take cover |
| **Frail Veteran** | Risk | ± | high accuracy + an extra ability, but low HP (skilled glass cannon) |
| **Conductor's Kin** | Hidden | – | *secretly loyal to the system* — may sabotage or defect at a scripted beat (C3.5) |
| **Survivor's Guilt** | Hidden/Gained | ± | after outliving an ally: a temporary debuff that **hardens into a permanent resilience buff** if the unit survives long enough |
| **Marked** | Risk/Gained | – | the train's security flags this unit; snipers and **Overcharge** (finale) prioritize them |

> This list is the **seed set**, not the ceiling — it's data (C5); add freely. Aim to keep roughly a 60/25/15 split of positive / mixed / negative-or-hidden so drafts feel like opportunities with teeth.

### C3.5 Hidden traits & the betrayal hook
- Hidden traits (e.g., **Conductor's Kin**) are **not shown** on the draft/recruit card. They surface via:
  - a **Saboteur scan** ability or a Med-car/event "vetting" option (spend resources to reveal a unit's hidden trait early), or
  - a **scripted story beat** where the trait fires (a defection, a sabotaged door, an alarm raised).
- This makes **vetting a resource** and turns recruitment into a calculated risk — exactly the texture the moral economy (GDD §9) wants. A cheaply-recruited body might be a plant; the Saboteur earns part of their keep by exposing them.
- Keep hidden-negative density **low** (most recruits are honest) so betrayal is a memorable spike, not a tax.

---

## C4. Recruitment (in-run) — how it differs from the draft

When you accept a **sympathetic citizen** (Sanctuary car / event / *Sympathizers* modifier):
- They join as a **rolled Archetype + 1–2 Traits** (weighted by section/pool), with **hidden traits possible** and only **partially shown** — recruitment is the *uncontrolled* counterpart to the draft (this is the cost of drafting fewer starters, C1.2).
- **Special recruits** appear occasionally: named defectors with fixed combos (a turncoat guard = Marksman with light armor; a First-Class defector = Saboteur with **Informant**). These are pool content, unlockable via meta.
- Recruits fill **open starter slots** first, then count toward the soft cap (4) / hard cap (5).

---

## C5. Data schemas

Extends the §21 schemas in the main GDD.

```typescript
// ---- Archetype (extends ClassDef from GDD §21) ----
interface ArchetypeDef {
  id: string;                        // "bruiser"
  name: string;
  role: "frontline" | "ranged" | "tech" | "support" | "momentum";
  baseStats: { hp: number; move: number; accuracy: number; mass: "light"|"medium"|"heavy" };
  innateTrait?: string;              // e.g. Firebrand "momentum"
  signatures: string[];             // ability ids always available
  tree: Array<[string, string]>;     // per tier: the 1-of-2 ability choice
  capstone: string;                  // final pick
  traitAffinity?: string[];          // traits that preferentially roll on this archetype
}

// ---- Trait ----
interface TraitDef {
  id: string;                        // "iron_lungs"
  name: string;
  category: "combat" | "physics" | "utility" | "social" | "risk" | "hidden";
  polarity: "positive" | "negative" | "mixed" | "hidden";
  effects: EffectDef[];             // stat/behavior/recon/economy modifiers
  archetypeAffinity?: string[];      // restrict/weight which archetypes can roll it
  hidden?: boolean;                  // concealed on cards until revealed
  revealCondition?: string;          // "saboteur_scan" | "vetting_event" | "story_beat"
  gainable?: boolean;                // can be added mid-run via events/level-up
}

// ---- A concrete character (drafted or recruited) ----
interface CharacterInstance {
  id: string;
  name: string;
  portraitId: string;
  archetype: string;                 // ArchetypeDef id
  traits: string[];                 // 1–3 TraitDef ids (some may be hidden/unrevealed)
  revealedTraits: string[];          // subset currently visible to the player
  level: number;
  chosenAbilities: string[];         // picks made down the tree
  // runtime: hp, status, inventory, momentumStacks, bonds, etc.
}

// ---- Draft state (part of the replay log) ----
interface DraftState {
  poolSeedCursor: number;            // deterministic draw position
  shownAndRemoved: string[];         // candidate ids burned (taken or passed)
  currentChoices: CharacterInstance[]; // the 3 on offer this round
  picksTaken: number;
  picksAllowed: number;              // 3
  draftPayoutMult: number;           // set on finalize (C1.2)
}
```

---

## C6. Acceptance criteria (this system "done")

1. A run opens with a **Draft**: 3 candidates per round, **no repeats**, Take/Decline, **1–3 starters**, Stop-anytime.
2. Each card shows **Archetype + visible Traits + stat slant**; **hidden traits are concealed**.
3. Drafting fewer sets **`draftPayoutMult`** and leaves **open slots** that recruitment fills.
4. All five **Archetypes** exist with base stats, signatures, a working **1-of-2 tree**, and a Capstone; `mass` feeds the physics resolver and the gas/fire resistances feed Sub-Spec D.
5. The **Trait** system attaches 1–2 traits at creation, supports **gaining** one mid-run, and applies effects via the data-driven `EffectDef` pipeline.
6. **Hidden traits** can be **revealed** by a Saboteur scan / vetting event / story beat, and **Conductor's Kin** fires a defection beat when unrevealed.
7. The whole draft is **deterministic** from `(seed, picks)` and serialized in the replay log.
8. **Recruitment** produces partially-shown, hidden-trait-capable joiners distinct from the controlled draft.
