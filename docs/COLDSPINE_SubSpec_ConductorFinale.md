# COLDSPINE — Sub-Spec B: The Conductor's Chamber (Finale)

> Companion to COLDSPINE_GDD.md (§13). The climactic set-piece.
> Build target: **Phase 6**. Depends on the Physics Resolver (Sub-Spec A) being complete.
> Design stance: an **objective fight**, not an HP sponge. The room is the boss; the Conductor controls the room; **physics is the win button.**

---

## B0. Design goal

The whole game has taught one lesson — *displace, don't out-damage* — and the finale is its exam. The Conductor is physically fragile but shielded behind the Engine's systems. You cannot simply shoot them down. You win by **turning the Engine's own architecture against itself**: shoving robots into pistons, flooding the vault and electrifying it, and slamming debris into the exposed Core. It must feel like the payoff of every physics combo the player has learned, under a tightening clock, with permadeath stakes at their highest.

Two strategic paths exist so the fight has replay and player expression:
- **Methodical** — knock out the three **Relays** to drop the Core's shield, then sabotage the Core.
- **Decapitation** — rush the dais and kill the Conductor directly (hard, exposed), which drops everything at once.

---

## B1. The arena — the Engine Vault

A **set-piece, hand-authored car** (`CarTemplate.type = ENGINE`), larger than a normal car. Suggested ~**20×12**, optionally two linked chambers (antechamber → inner vault).

### B1.1 Architecture (Anchored, built-in hazards)
| Element | Type | Behavior | How the player exploits it |
|---|---|---|---|
| **Piston Rams** | Anchored hazard lanes (along walls) | Telegraph 1 turn; fire every **2 turns**; slam outward 2–3 tiles, dealing damage **and an outward impulse** to anything in-lane | Shove a Security Robot (or the Conductor, if Soaked) into a piston lane → massive damage / instant destroy |
| **Electrified Floor Plates** | Tiles, cycle on/off on a visible timer | When LIVE: Shock to anything standing on them; combine with WATER for an AoE chain | Herd robots onto plates; flood the plates and trigger them for a room-wide chain |
| **Steam Vents** | Rotating hazard tiles | DoT + **Burning**; emit steam clouds that block line of sight while active | Use steam to break enemy turret/Conductor sightlines; note steam *boils off* water (Sub-Spec A6) |
| **Coolant Tanks** | Destructible (Heavy), `on_break = FLOOD r3` | The vault's water source | Break to flood the floor → enables every electric combo; the Saboteur's playground |
| **The Core** | Anchored objective object, has **integrity** | Shielded while any Relay is online; the sabotage target | Damage it once exposed — best via **slamming a robot/debris into it** or a Saboteur charge |
| **Control Dais** | Elevated Anchored platform | Where the Conductor stands; protected (see B4) | Reaching it enables decapitation |

### B1.2 Interactive objectives (destructible Anchored, with `on_destroy` hooks)
- **3× Relay** — destroying a Relay (a) removes one **Core shield stack**, and (b) **disables one of the Conductor's room powers** (see mapping in B3). The relay you kill *first* shapes the fight.
- **2× Robot Dispenser** — spawns Security Robots each round until destroyed. A sub-objective: shut off the adds.

---

## B2. Win/lose, phases, and the Bridge Countdown

### B2.1 The objective
**Stop the train = reduce the Core's integrity to 0.** The Core is **shielded** (immune) while **any Relay is online**. So:
```
disable all 3 Relays  ->  Core shield drops  ->  damage Core to 0  ->  WIN (ending varies)
        OR
kill the Conductor    ->  Core shield drops immediately  ->  damage Core to 0  ->  WIN
```

### B2.2 The Bridge Countdown (pressure, not instant-fail)
A visible round counter (default **10 rounds**) representing the train accelerating toward the Bridge / point of no return.
- **Core sabotaged BEFORE the countdown expires** → a **good ending** is on the table (Hard Stop / Seize the Engine, gated by Order — see B6).
- **Countdown reaches 0** → the train passes the Bridge: the **good endings lock out**, and each subsequent round adds an **escalating hazard** (extra piston bank, faster plate cycle, double Deploy) to stop the player stalling forever. You can *still* win, but only the **Pyrrhic** ending remains.
- **Squad wipe** at any point → **loss** (run over; meta-progression continues).

> This makes the clock steer *ending quality and difficulty*, not a binary game-over — more interesting and less feel-bad than a hard timer, while still creating urgency. The only hard failure is losing your whole squad.

### B2.3 Phase structure
- **Phase 1 — Breach the Vault (antechamber).** Enter under **Sentry Turret** fire; built-in hazards (pistons/plates/steam) are already live; **robots patrol**. The Conductor is shielded on the dais and **not yet active** (no abilities, countdown not started). *Phase goal:* cross the antechamber and destroy the **first Relay** + the entry turrets, learning the hazard timers. This phase **teaches the room** at lower pressure.
- **Phase 2 — The Conductor Active.** Crossing into the inner vault (or destroying Relay 1) **activates the Conductor**: full ability kit comes online and the **Bridge Countdown begins**. Dispensers start producing robots. The relay→core (or decapitation) loop plays out here. This is the bulk of the fight.
- **Phase 3 — Core Exposed (endgame).** With all Relays down (or the Conductor dead), the **Core shield drops**. The Conductor (if alive) enters **Lockdown** (enrage): faster hazard cycles, double Deploy, and may spam **Accelerate** on the countdown. Final push to damage the Core to 0 → triggers the ending.

---

## B3. The Conductor — kit & AI

A unique `SimEntity` (fragile body, high "shield" via room systems) driven by an **ability pattern table**. Each turn the Conductor **telegraphs** next turn's action (shown to the player), then resolves the previously telegraphed action — so the player always has one turn of warning (anti-frustration, and it lets physics counterplay exist).

### B3.1 Ability kit
| Ability | Effect | Counterplay |
|---|---|---|
| **Re-Route** | Toggles a hazard bank on/off (arms a piston lane / electrifies a plate cluster / opens steam vents) | Reposition out of the telegraphed lane; or *use* the newly-armed hazard against the robots |
| **Deploy** | Active Dispensers each emit a Security Robot | Destroy the Dispensers to stop it |
| **Overcharge** | A Core-system strike on the player's **most exposed / lowest-HP** unit (telegraphed 1 turn) | Break LoS, get into full cover, or stop leaving someone low and in the open |
| **Accelerate** | Advances the Bridge Countdown by 1 | Tradeoff for the Conductor: a turn spent here isn't Deploy/Overcharge — pressures you but eases the onslaught |
| **Lockdown** (phase trigger) | On Relay-count / HP / Phase-3 thresholds: faster hazard cycles + double Deploy | Burst the Core down fast; don't let the fight drag into Lockdown spirals |

### B3.2 Relay → power mapping (the player's strategic lever)
Destroying a Relay removes one shield stack **and** disables the linked power:
- **Relay A (Pistons)** → disables **Re-Route(piston)** + freezes piston lanes.
- **Relay B (Plates)** → disables electrified-plate cycling + the electrify half of Re-Route.
- **Relay C (Dispensers)** → disables **Deploy** + powers down both Dispensers.

So the player chooses: kill **C first** to stop the robot flood, **A first** to make melee/positioning safe, or **B first** to deny electric AoE. There is no single correct order — it depends on squad composition and current threats. (A Saboteur-heavy squad may *want* the plates alive to electrify their own floods, and kill A/C instead.)

### B3.3 AI implementation
- **Pattern table** keyed by phase + thresholds; the AI scores available abilities by a simple utility (is a unit exposed → favor Overcharge; many player units clustered in a lane → favor Re-Route into that lane; Dispensers alive and few robots on field → favor Deploy; countdown high and player near Core → favor Accelerate).
- **Telegraph system:** the chosen action is stored as `pending_action` and surfaced to the renderer as a telegraph event this turn; it **resolves at the start of the Conductor's next phase**. Thresholds (Relay count, Core-exposed, countdown==0) swap the active pattern set.
- Reuse the standard enemy command pipeline; the Conductor's "abilities" are just scripted Commands (some emit impulses via the Sub-Spec A resolver — e.g., Re-Route arming a piston that later fires an impulse).

---

## B4. Reaching & killing the Conductor (the decapitation path)

The dais is **protected** so decapitation is a real but costly alternative, and so it teaches the full kit:
- The Conductor has the **"unshovable until Soaked"** trait (the capstone callback to the Section-Captain trait in GDD §12): you **cannot** shove/slam them off the dais or into a hazard **until they are Soaked**. To Soak them you must **flood the dais** (break a coolant tank positioned to reach it, or carry water via the electrified-plate interplay).
- Once Soaked, the Conductor can be shoved like anything else — e.g., **Soak → shove into a piston lane / off the dais into the Core pit** for a burst of damage or an outright kill. This is the single most satisfying solve in the game and should be **previewable and reliable** (it runs entirely on the deterministic resolver).
- Killing the Conductor drops **all** shield stacks at once and disables every room power — but doing it means fighting onto the exposed, hazard-ringed dais under Overcharge/Deploy pressure. High risk, high reward.

---

## B5. Physics combos the finale is built around (call these out for tuning & tutorials)

1. **Robot → Piston.** Shove a Heavy Security Robot into an armed piston lane → the piston's impulse + damage destroys it. Turning the room's defenses on its own enforcers.
2. **Flood → Electrify (room-scale).** Break a Coolant Tank to flood the floor, herd robots/enemies into the water (or they're knocked Prone + Soaked by the wave), then **trigger a live floor plate** (or a Saboteur junction) → the electrify chain (Sub-Spec A6) sweeps every Soaked entity in the connected water. The marquee combo, scaled up to a boss arena.
3. **Slam-the-Core.** With the Core exposed, **slam a robot or thrown debris into it** (Sub-Spec A: a body/object carrying high `M_impact` deals integrity damage on collision) for a big chunk — physics as the literal finishing move on the boss objective. The Saboteur's planted charge is the alternative (2-AP heavy action, big flat integrity damage).
4. **Soak-then-Shove the Conductor.** (B4) Flood the dais → Soak the Conductor → shove into a hazard. The decapitation capstone.
5. **Steam screens.** Open a steam vent to **break a Sentry Turret's or the Conductor's line of sight** during a dangerous Overcharge telegraph — but remember steam boils off your water, so don't undo your own flood setup.

---

## B6. Endings (gated)

Determined by **(Order level) × (beat the Bridge Countdown?) × (survivors / key choices)**:

| Ending | Gate | Tone |
|---|---|---|
| **Hard Stop** | Low Order + Core sabotaged before countdown | You stop the train. The system ends; the cold outside is lethal. The faithful, bleak *Snowpiercer* resolution. |
| **Seize the Engine** | Low Order + a specific choice to **capture, not kill** the Conductor + survive | You take control of the Engine rather than destroy it. Ambiguous new order. |
| **Pyrrhic** | High Order, OR missed the countdown, OR heavy squad losses | You win, but gutted; the uprising barely survives, the cost was brutal. |
| **Liberation** *(hidden / stretch)* | Fully-merciful run: low Order + full surviving squad + enough citizens recruited across the run | The rare best ending — the train's people freed, not just its engine stopped. |
| **Loss** | Squad wipe at any point | The uprising is crushed. (Run over → meta-progression and Legacy continue; a fallen hero can be enshrined.) |

The kindest path and the strongest path **diverge** — exactly as designed in GDD §9. Show the player, at the moment of sabotage, which ending their run earned, so the moral economy lands.

---

## B7. Implementation & data notes (Godot)

- **Authored, not generated.** The Vault is a hand-built `CarTemplate` with scripted spawn points, the 3 Relays, 2 Dispensers, Coolant Tanks, piston lanes, plate clusters, steam vents, the Dais, and the Core. It is a set-piece scene, not procedural.
- **Hazards as timer-ticked entities/tiles.** Pistons/plates/steam carry a `cycle_timer` advanced in the **environment phase**; telegraphs are events the renderer shows **one turn ahead**. When a piston fires, it issues a scripted **impulse through the Sub-Spec A resolver** (it's just another impulse source) — no bespoke physics.
- **Objectives as destructibles with hooks.** Relay / Dispenser / Core are Anchored destructibles with `integrity` and an `on_destroy` callback:
  - Relay `on_destroy` → `remove_core_shield_stack()` + `disable_conductor_power(relay.power_id)` + freeze the linked hazard bank.
  - Dispenser `on_destroy` → stop its spawns.
  - Core `on_destroy` (integrity 0) → `trigger_ending(resolve_ending(order, beat_clock, survivors, choices))`.
- **Core shield** = an integer stack count = number of online Relays (+ a flag if Conductor alive on the decapitation rule — decide: either the 3 relays *are* the shield, and killing the Conductor force-zeroes it; recommended: `core_shielded = (online_relays > 0) and conductor_alive`; killing the Conductor sets `conductor_alive = false` → shield drops even with relays up). Pick the second form so decapitation works cleanly.
- **Bridge Countdown** = an int on the encounter state, decremented each round (or by **Accelerate**); hooks at `==0` (lock good endings, begin escalation).
- **Conductor** = unique `SimEntity` + an `AIPatternController` (pattern table + telegraph `pending_action` + threshold-driven pattern swaps). The **"unshovable until Soaked"** trait is the same flag used by Section Captains (§12) — reuse it.
- **Everything physical reuses Sub-Spec A.** Pistons, floods, electrify, slams, ejects, the Soak-then-shove on the Conductor — all run on the existing deterministic resolver. The finale adds **bespoke objects and an AI controller**, not new physics. That is what keeps a climactic set-piece actually implementable.

### B7.1 Acceptance criteria (Phase 6 "done")
1. The Vault loads as an authored encounter with 3 Relays, 2 Dispensers, coolant tanks, working piston/plate/steam hazards, the Dais, and the Core.
2. Core is immune while any Relay is online; dropping all 3 (or killing the Conductor) exposes it; Core integrity → 0 wins.
3. The Conductor runs a telegraphed ability kit; relay-kill order disables the mapped powers (B3.2).
4. The decapitation path works: the Conductor is unshovable until Soaked, and a Soak-then-shove into a hazard is reliable and **previewable**.
5. The Bridge Countdown gates endings and triggers escalation at 0; squad wipe is the only hard loss.
6. `resolve_ending()` returns the correct ending across the Order × clock × survivors matrix (B6), shown at the moment of sabotage.
7. All physics in the fight runs through the Sub-Spec A resolver (no parallel physics code).
