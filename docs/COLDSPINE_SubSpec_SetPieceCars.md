# COLDSPINE — Sub-Spec E: Set-Piece Cars & Biomes

> Companion to COLDSPINE_GDD.md (§8.3) and Sub-Specs **A** (resolver), **D** (hazards), **C** (roster/betrayer).
> Build target: **content** layered on the existing engine — most of a car is data (`CarTemplate`) + a few shared system extensions (E1). Schedule after the systems they lean on exist.
> Theme: these are the elite's **absurd luxuries** aboard a train circling a frozen dead world — a ski slope and a spa while the tail starves. The contrast *is* the politics; lean into it. They cluster in **Sections 3–4**, so decadence intensifies as you near the Engine.

---

## E0. How to read a car entry

Each car below specifies: **Fiction**, **Section**, **Terrain & cover**, **Hazards** (which Sub-Spec D systems it uses), **Signature physics** (the standout interaction, on the Sub-Spec A resolver), **Encounter & moral beat** (incl. betrayer hooks — Sub-Spec C3.5), and **Recon tell** (what the operator sees coming, §8.2). Anything genuinely new is defined once in **E1 — System Extensions** and merely referenced by the cars.

---

## E1. System Extensions (fold these into A / D / §5.5)

A handful of small, reusable mechanics that several set-pieces share. Defining them once keeps the cars as pure content.

### E1.1 Terrain physics — friction & slope *(extends Sub-Spec A)*
Tiles gain two optional integer fields the resolver already has hooks for:
- **`friction`** — modifies the per-tile momentum cost during forced movement.
  - Normal floor: cost = mover's `mass` (Sub-Spec A2).
  - **Ice:** `friction = 0` → moving costs **no momentum** → entities **slide the full length** until they hit something. Long slides, brutal billiards, board impacts.
  - **Deep snow / soft soil:** `friction = +1` → costs `mass + 1` → shoves travel **shorter**; also **+1 Move cost** to walk through (difficult terrain).
- **`slope`** — a unit vector (e.g., `(1,0)` downhill) that **adds momentum when moving with it, subtracts when moving against it**.
  - Resolve per step: moving **downhill** → `M += 1` before paying the tile cost (amplifies the slam); moving **uphill** → `M -= 1` (saps it). On a steep stretch, an unsupported entity may **slide downhill on its own** at the start of the environment phase (a gentle gravity tick).
- Both are pure integer additions to the existing momentum loop; preview (A7) shows the amplified/extended trajectory. **Determinism preserved.**

### E1.2 Cold & heat statuses *(extends §5.5 / Sub-Spec D)*
- **Chilled** — −Move, −accuracy. Applied by cold air (snow guns), standing on snow/ice, or falling through ice. **Stacks**; at `FROZEN_THRESHOLD` stacks → **Frozen**.
- **Frozen** — skips its turn (hard stun) until **thawed** by heat/fire (a Fire tile, Furnace, Fire Vent, or a Steward warming ability clears it). The cold-biome answer to "lock a target down."
- **Scalded** — a one-off **hot-tile** effect (sauna coals, scalding pools, boiling kitchen water): damage on enter/stand; *cancels Chilled/Frozen* (heat). Not a lingering DoT — just a painful tile.

### E1.3 Toppling tall objects *(extends Sub-Spec A `on_break`)*
A new `on_break` type: **`TOPPLE`** — instead of vanishing, a tall destructible **falls in a direction** (its `fall_dir`, usually away from the impact) as a **line crush**: every tile along its `height` length takes impact damage and a knock to **Prone**; movable entities in the line get a perpendicular shove off the falling mass. Used by **trees** (forest), **chandeliers** (dining — falls *downward* onto its floor tiles), and **hedge sculptures** (maze). A felled tree dropping across a lane of guards is one of the game's best one-shots.

### E1.4 Concealment & in-car fog *(extends Sub-Spec A LoS + §8.2 recon)*
- **Concealment tiles** (underbrush, hanging vines, steam, low topiary): **block line of sight** but are **passable** (unlike full-cover walls). They enable **ambush** and break sniper/overwatch lines.
- **In-car fog (operator blind spots):** some cars (notably the **Hedge Maze**, heavy **Steam** rooms) **reduce the operator's own visibility** — you can only see tiles within line of sight of a unit or a working camera, the rest is fog until revealed. This is a deliberate twist on the omniscient camera (§3.1): the maze defeats your surveillance, so foreknowledge shrinks exactly where the train wants it to. (Tune per-car; default cars remain fully visible.)

### E1.5 Conveyor / treadmill hazard *(new cycling-ish hazard, Sub-Spec D)*
A **moving surface** (ski-sim belt, baggage line) that **applies a fixed 1-tile shove in its direction to every entity on it at the start of the environment phase** — continuous, predictable forced movement. Stack with slope/ice for chaos. Disableable at a control panel.

### E1.6 Avalanche / snow-sweep *(reuses the Flood machinery, Sub-Spec A6, snow-flavored)*
A triggerable **snow mass** (overhead bank, snow-gun reservoir). On trigger (shot, slammed, explosion, loud Order spike), it **sweeps** like a flood wave but: knocks standing units **Prone**, applies **Chilled** (not Soaked), and **buries** caught entities → **immobilized** for a turn (dig out = 1 AP). Recedes as packed snow (difficult terrain) instead of receding water.

### E1.7 Ambush state & neutral creatures *(optional, content-level)*
- **Ambush start:** some cars begin with enemies **Unaware** (relaxing in a spa, lost in a maze) — the operator sees this on the feed (§3.1), granting a **free-action first strike** / guaranteed-flank opening round before combat "wakes." A stealth-flavored advantage that rewards reading recon.
- **Neutral creatures (optional):** released game animals (forest/hunting car) or vermin — a **third faction** that attacks whoever is nearest, both sides. Pure chaos agent; flag as optional flavor, not core.

---

## E2. Ski Simulator *(snow/ice — the slope car)*

- **Fiction:** an indoor artificial alpine slope for first-class recreation: real snow guns, a sloped run, a moving lift belt. Obscene.
- **Section:** 4 (First Class). Peak decadence.
- **Terrain & cover:** a **sloped surface** (E1.1 `slope`) running down-car; **deep snow** patches (E1.1 friction, difficult terrain, **Chilled**); lift pylons and snow-gun housings as Anchored cover; a **conveyor lift belt** (E1.5) running uphill.
- **Hazards:** **cold** snow-gun blasts apply **Chilled** in a cone (E1.2); a triggerable **avalanche** reservoir up-slope (E1.6); a **Gap/ledge** at the down-slope end (eject).
- **Signature physics:** **slope-momentum.** Shove an enemy **downhill** and they travel far and hit hard — slide them into the lift machinery, into the avalanche trigger, or **off the down-slope ledge** for an eject. The conveyor belt drags the careless uphill into the snow guns. Trigger the avalanche to **bury and Chill** a whole cluster.
- **Encounter & moral beat:** ski-patrol security (mobile, comfortable on snow); first-class skiers (Bourgeois spare/kill). A planted recruit (**Conductor's Kin**, C3.5) who "knows the slope" is a natural betrayer here.
- **Recon tell:** `CAR ## — ALPINE SIM` + a SLOPE/COLD tag → bring something that doesn't rely on holding ground; consider a Saboteur to weaponize the avalanche.

---

## E3. Ice Rink *(snow/ice — the friction car)*

- **Fiction:** a mirror-smooth luxury skating rink, boards and all.
- **Section:** 3–4.
- **Terrain & cover:** the whole floor is **ice** (E1.1 `friction = 0`); **boards/barriers** ring it (Anchored, hard cover — and the thing everything slides *into*); benches/players' boxes as light cover; a center stretch of **thin ice**.
- **Hazards:** **thin ice** — a destructible floor that **cracks from weight/impact** and **drops** units into freezing water below: an **eject-style drop** dealing heavy damage + **Soaked + Chilled** (and possibly toward **Frozen**). Cracks **spread** from impacts (a small spreading floor hazard).
- **Signature physics:** **frictionless slides.** A single shove sends an enemy **sliding the length of the rink** into the boards (a big delayed impact) or onto the **thin ice**, which cracks and drops them. Billiards chains are devastating on ice (nothing decays the slide but collisions). Curling-with-bodies. The skill is aiming slides; the danger is **your** units slide too.
- **Encounter & moral beat:** off-balance security (everyone's on ice — levels the field); a recruit who's a **figure skater** (high Move, *Sure-Footed* trait) is great flavor.
- **Recon tell:** `CAR ## — ICE RINK` + ICE tag → expect long slides and board impacts; a Bruiser turns this car into a shooting gallery.

---

## E4. Forest Biome *(the hunting preserve)*

- **Fiction:** a cultivated indoor forest — the elite's private nature preserve and hunting park.
- **Section:** 3–4.
- **Terrain & cover:** **dense trees** (Anchored full cover, many **fellable** — `TOPPLE`, E1.3); **underbrush** (concealment, E1.4 — breaks sniper lines, enables ambush); soft soil (difficult terrain). A **tinderbox**: lots of flammable material.
- **Hazards:** **Fire spreads fast and far** here (Sub-Spec D1.2 — the fire biome); optional **neutral game animals** (E1.7) released into the fight.
- **Signature physics:** **fell a tree** (chop, slam, or explosion) to **topple it across a lane** of enemies — line crush + Prone (E1.3). Use **underbrush concealment** to slip a flanker past overwatch. Beware: a stray incendiary can ignite the **whole car**, and fire doesn't pick sides.
- **Encounter & moral beat:** "hunters" (first-class with hunting rifles — real ranged threat) plus wardens; sparing the **gamekeeper** (a laborer) is a recruit/Order beat. If you use neutral animals, the moral read is messy on purpose.
- **Recon tell:** `CAR ## — PRESERVE` + FLAMMABLE/CONCEAL tag → fire discipline matters; concealment cuts both ways.

---

## E5. Hedge Maze *(with hedge sculptures — the labyrinth)*

- **Fiction:** an ornate topiary maze, a first-class garden game, dotted with sculpted hedge animals and figures.
- **Section:** 4.
- **Terrain & cover:** **hedge walls** form a **labyrinth** — full cover **and** LoS blockers, but **destructible** (cuttable/burnable). **Hedge sculptures** are **Heavy `TOPPLE` objects** (shove a topiary lion onto a guard), and **some are rigged** — a sculpture conceals a **cycling trap** (laser emitter or gas vent, Sub-Spec D). **In-car fog (E1.4):** the maze **defeats your surveillance** — you see only what your units can.
- **Hazards:** **rigged sculptures** (hidden vents/lasers); **fire** (hedges burn — torch a wall to make a path, but the fire **spreads through the maze** and reshapes it dangerously).
- **Signature physics:** **reshape the maze.** **Burn or smash hedge walls** to carve new flanks, escape routes, and sightlines — turning a defensive labyrinth into a kill-funnel of your design. **Topple sculptures** onto enemies. Navigate (and exploit) the limited LoS.
- **Encounter & moral beat:** patrols that **lose you in the maze** (hide-and-seek; ambush openings, E1.7). **The premier betrayer car:** a planted recruit (**Conductor's Kin**) "guiding" you through the maze can lead you into a rigged dead-end or spring the trap — the fog (E1.4) means you can't see the betrayal coming, which is exactly the point. Strong payoff for the mechanic you loved.
- **Recon tell:** `CAR ## — TOPIARY MAZE` + LOW-VISIBILITY/RIGGED tag → your recon goes dark inside; vet your recruits (Saboteur scan, C3.5) **before** you enter.

---

## E6. Garden / Greenhouse *(the food car — combo playground)*

- **Fiction:** the agricultural greenhouse — where the train's food is grown. Working, vital, contested.
- **Section:** 2–3 (sustenance, lower than the pure amenities).
- **Terrain & cover:** **planters and trellises** (destructible half/full cover); **hanging vines** (concealment, E1.4); soft soil (difficult terrain). Crucially, the car holds **multiple Sub-Spec D hazard sources at once**.
- **Hazards:** **irrigation water** (easy **floods**, Sub-Spec D1.1); **pesticide gas** tanks (a **Poison Gas** source, D1.3); dry sections that **burn** (D1.2). A natural **combo arena** — water, gas, and fire all present.
- **Signature physics:** the **Saboteur's dream car.** **Flood** with irrigation, **gas** with pesticide, then **ignite** for the marquee explosion (Sub-Spec D4), or **electrify** the flood. Layer the hazards the enemy can't.
- **Encounter & moral beat:** **garden workers** (laborers, sympathetic) → prime **recruitment**; sparing them keeps the food supply and reads well on the Order meter (§9). Killing for a quick resource grab here is especially cold.
- **Recon tell:** `CAR ## — GREENHOUSE` + WATER+GAS tag → push the Saboteur forward; this is where combos pay out biggest.

---

## E7. Dining Room *(the banquet — physics sandbox + social)*

- **Fiction:** the opulent first-class restaurant: long banquet tables, chandeliers, fine china, an attached kitchen.
- **Section:** 4.
- **Terrain & cover:** **furniture-dense** — long tables, chairs, serving carts: a wealth of **movable cover and throwables** (the richest physics-toy car; Bruiser heaven — flip a table for instant cover, hurl a chair, ram the dessert cart through a line). **Chandeliers** overhead (**`TOPPLE` downward**, E1.3 — shoot the rig to **drop one** onto enemies). The **kitchen** is a hazard cluster.
- **Hazards:** **kitchen fire / grease** (fast-spreading Fire, D1.2); **gas ranges** (Poison/explosive gas source, D1.3); **steam** (D2.5, Blinded); scalding/boiling surfaces (**Scalded** tiles, E1.2).
- **Signature physics:** **furniture warfare** — flip, throw, and shove the densest object set in the game; **drop the chandelier**; **ignite the kitchen** (gas + grease) for a banquet-ending blast.
- **Encounter & moral beat:** a **Bourgeois Lounge** at its purest — first-class diners to **spare (gear/intel) or kill (resources + Order)**. A **defector among the diners** is a clean betrayer plant (C3.5): they blend in perfectly until they don't.
- **Recon tell:** `CAR ## — GRAND DINING` + FURNITURE/KITCHEN-FIRE tag → bring a Bruiser; expect a moral choice and a possible plant.

---

## E8. Spa / Bathhouse *(steam, water, ambush)*

- **Fiction:** a luxury spa — hot pools, steam rooms, saunas, massage tables.
- **Section:** 4.
- **Terrain & cover:** **water everywhere** (pools and baths — built-in **flood/Soaked**, D1.1); **steam rooms** (dense **Steam**, D2.5 — Blinded + LoS-block + E1.4 fog); **slippery wet tile** near pools (E1.1 light friction); lockers and massage tables as light cover. **Hot pools and sauna coals** are **Scalded** hazard tiles (E1.2).
- **Hazards:** **scalding water/steam**; **electrified-water** potential (a junction + the standing water = Shock chain, D4); **slippery floors**.
- **Signature physics:** the **wet-room combo:** **steam to Blind**, **flood to Soak**, **spark to Shock** — or simply **shove enemies into a scalding pool**. Slippery tile makes shoves slide a little further near the water.
- **Encounter & moral beat:** **enemies start Unaware** (security literally in robes — **Ambush start**, E1.7): the operator sees they're off-guard via the camera and gets a **first-strike** opening. A clean "are they even armed?" mercy beat — and a tempting, brutal flood-and-shock on people who never saw it coming (Order cost).
- **Recon tell:** `CAR ## — SPA` + STEAM/WATER/AMBUSH tag → a Saboteur turns this into a one-round wipe; the morality of doing so is on you.

---

## E9. Artist House / Atelier *(statues, giant art, easels, pottery, kiln)*

- **Fiction:** a first-class art salon and working atelier — marble sculptures, oversized canvases, easels mid-painting, a pottery wheel and **kiln**. The elite's cultural vanity, on rails.
- **Section:** 4.
- **Terrain & cover:** **stone statues** (Heavy **`TOPPLE`** objects + full cover — topple a marble figure onto a guard); **giant canvases / installations** (large but flimsy **concealment** you can **slash through** to open surprise sightlines, E1.4); **easels, plinths, sculpture stands** (light cover / throwables); **pottery & vases** (light destructibles → shatter to **debris**, difficult-terrain area denial). A **kiln** in the pottery corner = a **Furnace/ignition** source (D) + **Scalded** tiles (E1.2).
- **Hazards:** **kiln fire** (ignition + fire spread across canvases, wood, paint); **solvent/turpentine** spills (flammable → fire, mild fumes); wet clay/glaze (minor slip).
- **Signature physics:** **topple the statues** (marble-as-bowling-ball line crush, E1.3); **slash through the giant canvases** to see and shoot where the enemy can't (concealment manipulation); shatter pottery for instant cover / area denial; or **torch the solvent-soaked studio** via the kiln. Smashing the elite's culture is power-fantasy *and* theme.
- **Encounter & moral beat:** a celebrated **artist** (Bourgeois — spare for a unique "masterpiece" item / patron gear, or destroy their life's work for resources + Order); art patrons. An apprentice "sympathizer" is a tidy **betrayer** plant (C3.5).
- **Recon tell:** `CAR ## — ATELIER` + STATUES/FLAMMABLE tag → bring a Bruiser for the topples; mind the kiln.

---

## E10. Gym / Athletic Car *(dense throwables, treadmills, rack topples)*

- **Fiction:** a first/second-class fitness center — free weights, machines, a boxing ring, treadmills, a climbing wall.
- **Section:** 3–4.
- **Terrain & cover:** **weight racks & machines** (Heavy cover; loaded racks **`TOPPLE`**); **free weights / medicine balls / kettlebells** = the game's **densest throwables** (high **mass** → big impact, short throws — Bruiser **Heave** heaven, distinct from Dining's *furniture* in that gym objects hit *harder* but fly *shorter*); a **boxing ring** (roped duel space); **treadmills** (**conveyor** hazard, E1.5 — drag the careless into hazards); a **climbing wall** (height → fall hazard).
- **Hazards:** **treadmill conveyors** (E1.5); falling loaded equipment; minor slip (sweat).
- **Signature physics:** the **high-mass throwable car** — hurl medicine balls and dumbbells as heavy projectiles; **topple loaded weight racks** onto clustered enemies; **ride the treadmills** to drag enemies into pistons/walls/hazards. Pure kinetic theme made mechanical.
- **Encounter & moral beat:** fitness-obsessed security (jacked, melee-heavy, **Tough**); a **trainer/athlete** recruit (high HP/Move) reads perfectly.
- **Recon tell:** `CAR ## — FITNESS` + HEAVY-THROWABLES/CONVEYOR tag → a Bruiser dominates here.

---

## E11. Summary table — designed set-pieces (9)

| Car | Section | Signature mechanic | Hazards (Sub-Spec D) | New systems used (E1) |
|---|---|---|---|---|
| **Ski Simulator** | 4 | Slope-momentum + avalanche + conveyor | Cold, avalanche, gap | Friction/slope, Chilled/Frozen, conveyor, snow-sweep |
| **Ice Rink** | 3–4 | Frictionless slides into boards / thin-ice drops | Thin-ice drop, cold | Friction(ice), Chilled/Frozen |
| **Forest** | 3–4 | Fell trees (topple line-crush) + concealment | Fire (fast spread), neutrals | Topple, concealment, neutral creatures |
| **Hedge Maze** | 4 | Reshape the maze (burn/cut walls) + rigged sculptures | Fire, rigged vents/lasers | Topple, concealment, **in-car fog**, ambush |
| **Garden** | 2–3 | Water+gas+fire combo arena | Water, Poison gas, fire | Concealment |
| **Dining Room** | 4 | Furniture warfare + chandelier drop + kitchen blast | Fire/grease, gas, steam, scald | Topple, Scalded |
| **Spa** | 4 | Steam-blind + flood + shock; scalding pools | Water, steam, scald, (electrify) | Friction(wet), Scalded, ambush, in-car fog |
| **Artist House** | 4 | Topple statues + slash-through canvases + kiln burn | Fire, scald, solvent | Topple, concealment, Scalded |
| **Gym** | 3–4 | High-mass throwables + rack topples + treadmill drags | Conveyor, falling gear | Topple, conveyor |

**Section read:** amenities pile up in 3–4 by design — the closer to the Engine, the more grotesque the luxury, the sharper the contrast with the freezing tail. The **Garden** and **Gym** dip to 2–3 (food and labor, not pure leisure) — that's where the sympathetic recruits and cleanest moral choices live.

---

## E12. Content target — how many set-pieces? *(variety math)*

**The team's answer: a library of ~30 themed set-pieces (plus ~10 functional car types ≈ ~40 room types total, excluding the unique Conductor finale). Ship ~15 at launch and gate the rest behind meta-unlocks so discovery is *paced* across the full 20 hours.**

**The Blue Prince benchmark (you asked):** Blue Prince — whose *entire* loop is room-drafting — has ~6 colour-coded room *type categories*, ~46 core numbered rooms, and **~110 total unique room floorplans** in the full directory; crucially, **not all are available from the start** — many unlock through play. (Fittingly, its own guides note some rooms "may not click until you're 20 hours in.")

**Why COLDSPINE needs fewer than Blue Prince:** in Blue Prince the rooms basically *are* the game. In COLDSPINE, rooms are **one variety axis among four** — tactical physics combat, the roster/draft/traits/build, the hazard combos, and enemy composition all refresh a repeated room. So the *base* count can be lower while perceived variety stays high.

**The 20-hour math (transparent — adjust the assumptions):**
- Avg run ≈ 30 min → **~40 runs** in 20 h.
- ~20 cars/run → **~800 car-encounters**; ~40% are themed set-pieces → **~300 set-piece encounters**.
- With **~25 set-pieces in rotation**, each is seen ~12× — but **modifiers × hazards × enemy comp × your evolving build** make almost none of those repeats *feel* identical.
- **Discovery pacing (the real lever):** seeing all ~25 once takes ~15 runs (~7–8 h, coupon-collector). So *pure room discovery* lasts ~8 h; after that, **combinatorial freshness + paced meta-unlocks + build variety** carry hours 8–20.

**Recommendation, concretely:**
- **~10 functional car types** (combat, elite/captain, workshop/upgrade, armory, bourgeois, sanctuary/recruit, event, med/rest, black-market/shop, + a combat-hazard variant).
- **~30 themed set-pieces** in the full library — **~15 unlocked at launch**, the rest gated by meta-progression so *new rooms keep appearing well past hour 10*.
- **Sweet spot for the first 20 h specifically: ~20–24 set-pieces in rotation within that window.** Below ~15 and repetition shows by ~hour 12; above ~25 and you're building rooms many players won't see in 20 h (great long-tail content, just not *required* for the 20-h goal).
- Keep investing in the **multipliers** (more modifiers, hazard combos, enemy comps) — they're cheaper than new rooms and refresh everything you already have.

> **Build guidance:** do **not** build 30 rooms before launch. Build the **E1 extensions once**, ship **~15 set-pieces** (the 9 designed here + ~6 from the backlog), and add the rest as **content + unlocks** post-launch. The architecture makes each new car mostly data + layout.

---

## E13. The full set-piece library (target ~30)

The 9 designed above + a backlog of ~21, each with theme / section / signature / hazards. Backlog entries are **well-specified stubs** ready to be expanded to full E-entries on demand. ⭐ = recommended launch-15.

| # | Car | Sec. | Signature mechanic | Hazards / systems | Status |
|---|---|---|---|---|---|
| 1 | **Ski Simulator** ⭐ | 4 | Slope-momentum, avalanche, conveyor | cold, snow-sweep | Designed |
| 2 | **Ice Rink** ⭐ | 3–4 | Frictionless slides, thin-ice drops | ice, cold | Designed |
| 3 | **Forest** ⭐ | 3–4 | Fell trees, concealment | fire, neutrals | Designed |
| 4 | **Hedge Maze** ⭐ | 4 | Carve walls, in-car fog, rigged topiary | fire, fog, ambush | Designed |
| 5 | **Garden / Greenhouse** ⭐ | 2–3 | Water+gas+fire combo arena | water, gas, fire | Designed |
| 6 | **Dining Room** ⭐ | 4 | Furniture warfare, chandelier drop, kitchen blast | fire, gas, steam | Designed |
| 7 | **Spa / Bathhouse** ⭐ | 4 | Steam-blind + flood + shock, scald pools | water, steam, ambush | Designed |
| 8 | **Artist House** ⭐ | 4 | Topple statues, slash canvases, kiln burn | fire, scald | Designed |
| 9 | **Gym** ⭐ | 3–4 | High-mass throwables, rack topples, treadmills | conveyor | Designed |
| 10 | **Aquarium** ⭐ | 3 | The flagship flood/electrify car — wall-to-wall tanks | water, electrify | Backlog |
| 11 | **Library / Archive** ⭐ | 4 | Topple shelves as **dominoes**; flammable paper; ambush | fire, topple, concealment | Backlog |
| 12 | **Nightclub / Lounge** ⭐ | 3–4 | Strobe (Blinded), loud (Order), bottle molotovs, dance floor | fire, blind, noise | Backlog |
| 13 | **Boiler / Engine Annex** ⭐ | 4 | Industrial hazard-dense combat (bridges toward the Engine) | steam, pistons, furnace | Backlog |
| 14 | **Cold Storage / Meat Locker** ⭐ | 3–4 | Interior **freeze** biome; hanging carcasses (concealment/swing); frost slip | cold, ice | Backlog |
| 15 | **Server / Control Hub** ⭐ | 4 | Tech combat; **hack to disable hazards in the next car**; electrified floors | shock, robots, cold | Backlog |
| 16 | **Casino** | 4 | Gaming tables (cover/throwables); slot machines (shock/destruct); high-roller bourgeois | shock | Backlog |
| 17 | **Theater / Opera** | 4 | Drop the **rigging / sandbags**; curtains (fire/concealment); trapdoors | fire, topple | Backlog |
| 18 | **Observatory** | 4 | Shatter the **glass dome** → catastrophic cold/exposure event; telescopes | cold, gap/void | Backlog |
| 19 | **Wine Cellar / Distillery** | 3–4 | Volatile **alcohol barrels** (fire/explosion); racks topple | fire, explosion | Backlog |
| 20 | **Prison / Brig** | 2–3 | **Free prisoners → recruits**; riot control | gas, shock | Backlog |
| 21 | **Cryo / Stasis Bay** | 4 | Frozen passengers in pods (cover/destruct); coolant floods; eerie | cold, water | Backlog |
| 22 | **Chapel / Shrine** | 3–4 | Candles (ignition); statues (topple); stained glass (shatter/light) | fire, topple | Backlog |
| 23 | **Solarium / Pool Deck** | 4 | Deep-water pool (drown/eject); sun-lamps (heat/scald) | water, scald | Backlog |
| 24 | **Bazaar / Market** | 2–3 | Crowded stalls (cover/civilians); shop+bourgeois hybrid; stall fires | fire | Backlog |
| 25 | **Menagerie / Zoo** | 3–4 | Release caged **animals** (neutral chaos); enclosures | neutrals | Backlog |
| 26 | **Laundry / Service Tunnels** | 2–3 | Steam + machinery (pistons/conveyors); laborer recruits | steam, conveyor | Backlog |
| 27 | **Ballroom** | 4 | Vast **open floor** (exposure); chandeliers; grand staircase (slope) | topple, slope | Backlog |
| 28 | **Medical Bay** | 2–3 | **Oxygen tanks = mobile bombs**; surgical lasers; flavored Rest car | explosion, lasers | Backlog |
| 29 | **Conservatory (exotic)** | 3–4 | Poisonous / **carnivorous plants** (gas + immobilize-grab) | gas, neutrals | Backlog |
| 30 | **Overgrowth (derelict)** | any | Abandoned car reclaimed by plants; concealment-heavy wildcard | concealment, neutrals | Backlog |

> The backlog is intentionally over-target (30) so you can cut the weakest and still hit ~25–28. Each stub names a **distinct signature** so no two cars feel like reskins — that distinctness, not raw count, is what sustains surprise.

---

## E14. Acceptance criteria & scope note

1. The **E1 extensions** are implemented as reusable engine additions: tile `friction`/`slope` (A), `TOPPLE` `on_break`, **Chilled/Frozen/Scalded** statuses, concealment + optional in-car fog, conveyor, snow-sweep, ambush-start.
2. Each car ships as a **`CarTemplate`** composing those extensions — **no per-car bespoke physics**.
3. Each **signature mechanic** is reachable and **previewable** (A7).
4. **Betrayer integration:** Maze, Dining, Ski Sim, and Artist House support a planted **Conductor's Kin** (C3.5); the Maze's **in-car fog** hides the betrayal.
5. Cars place via the **seeded linear line** (§8.2) with correct **section clustering** and **recon tells**.
6. **Content target met:** ~10 functional types + a set-piece library trending toward ~30, with **~15 at launch** and the rest **meta-gated** to pace discovery across the first 20 hours (E12).

> **Scope reality:** mostly **content + seven small shared systems (E1)**. Build E1 once, ship ~15 set-pieces, and grow the library as data + unlocks — variety without growing the engine.
