# Design Sheet — Cars & Biomes

> Obeys `ART_BIBLE.md` §4 (the 5-section palette escalation) and the surveillance framing (§2).
> Source: Sub-Spec E (Set-Piece Cars & Biomes) + GDD §8.1, §8.3. Each car is a **`CarTemplate`**
> composing shared systems — **no per-car bespoke art either**: a car is its section palette (§4)
> + a small set of themed objects/hazards reusing the §3 language. The theme is the politics:
> **grotesque elite luxury vs. a freezing tail** (Sub-Spec E preamble).

## Intent
A car must read its **section** (palette → how deep am I), its **type** (combat / flood / bourgeois
/ recon tell), and its **signature hazard** (what physics toy is here) the instant the feed comes
up. The escalation is the story: grimy Tail → industrial Third → wet/green Second → opulent First →
sterile Engine. Amenity cars (ski slope, spa, dining) cluster in Sections 3–4 so decadence sharpens
toward the Engine.

## Final-look image-gen prompt(s)

**Section establishing set (one per act):**
> "Five isometric tactical-game train-car interiors viewed top-down through a fixed security camera,
> a Snowpiercer-style train circling a frozen dead world, escalating front-to-back from grimy to
> sterile: (1) THE TAIL — dark cramped scavenged scrap-metal car, rust, soot, one failing amber
> worklight (`#2A2420`/`#7A4A2C`/`#C24A2A`); (2) THIRD CLASS — crowded greasy industrial car, pipes,
> hazard-yellow stripes, sickly fluorescent buzz (`#33392F`/`#C2A03A`); (3) SECOND CLASS — a wet
> verdigris aquarium/greenhouse car, glass tanks of glowing blue water, planted green, breakable
> (`#27433C`/`#2E8BC0`/`#5FB89A`); (4) FIRST CLASS — opulent sterile marble-and-gold dining/spa car,
> velvet crimson, cold chandelier light, grotesque luxury (`#3A332A`/`#C9A24A`/`#8E1F3A`); (5) THE
> ENGINE — clinical white-blue automated machine chamber, signal cyan, alarm red, hostile inhuman
> architecture (`#2C3640`/`#3FC6D4`/`#FF3B3B`). Flat-shaded, chunky low-detail, CRT scanline grain,
> single fixed camera, readable tactical layout, game-asset style."

**Signature biome cars (Sub-Spec E — the amenities):**
> "Isometric set-piece tactical car interiors, top-down security-feed view, elite luxuries aboard a
> frozen train, each with one clear physics gimmick: an ALPINE SKI SIM (sloped artificial snow run,
> snow guns, a lift conveyor belt, a down-slope ledge — `slope`+`ice`+`cold`); an ICE RINK (mirror-
> smooth ice floor ringed by boards, a center patch of cracking thin ice — `friction=0`); a HEDGE
> MAZE (topiary labyrinth walls, sculpted hedge animals, low operator-visibility fog); a GREENHOUSE
> (planters, irrigation water, pesticide-gas tanks, dry flammable patches — water+gas+fire combo); a
> GRAND DINING ROOM (long banquet tables, overhead chandeliers to drop, a hazardous kitchen); a SPA
> (hot pools, dense blinding steam rooms, slippery wet tile); an INDOOR FOREST PRESERVE (fellable
> trees, underbrush concealment, fast-spreading fire); an AQUARIUM (wall-to-wall glass tanks of
> glowing water, the flagship flood/electrify car). Flat-shaded, chunky, palette per First/Second
> Class, scanline grain, game-asset style."

## Placeholder spec (shipping now)
**No standalone car SVGs ship now** — a car is rendered at runtime from a `CarTemplate` (tiles +
objects from the existing placeholder set, re-tinted by section palette §4). The renderer composes:
section palette (§4) applied to floors/walls/ambient + the themed objects (`obj_*` placeholders) +
the car's hazards (`tile_*` hazard placeholders) + the camera-ID header naming it (`cars_biomes`
recon tells below). This sheet is the **palette + recon-tell + signature-object contract** for that
composition; it adds no new files.

**Recon-tell + palette mapping (binding for `render/` car composition):**
| Car | Section / palette | Camera-ID tell | Signature objects / hazards (from existing placeholders) |
|---|---|---|---|
| Tail combat | 1 `tail.*` | `CAR ## — TAIL` | crates, barrels; gap (coupling) |
| Third-class security | 2 `third.*` | `CAR ## — TRANSIT` | crates, rail, piston |
| Aquarium | 3 `second.*` | `CAR ## — AQUARIUM` | fish tanks (flood), junction (electrify), water tiles |
| Greenhouse | 3 `second.*` | `CAR ## — GREENHOUSE` | tables/crates as planters, water + (gas/fire) tiles |
| Ice Rink | 3–4 `second/first` | `CAR ## — ICE RINK` | walls as boards, ice/water tiles, gap (thin-ice drop) |
| Ski Sim | 4 `first.*` | `CAR ## — ALPINE SIM` | crates as pylons, water(snow) tiles, gap (down-slope ledge) |
| Grand Dining | 4 `first.*` | `CAR ## — GRAND DINING` | tables (throwables), barrels (kitchen), fire tiles |
| Spa | 4 `first.*` | `CAR ## — SPA` | glass partitions, water tiles, junction (shock) |
| Indoor Forest | 3–4 `second/first` | `CAR ## — PRESERVE` | crates as trees, fire tiles |
| Engine / Conductor | 5 `engine.*` | `CAR ## — ENGINE CORE` | piston, rail, furnace, security robots/turrets |

> Per Sub-Spec E14: each car is **content (CarTemplate) + the shared E1 systems**, never bespoke
> physics — and, here, never bespoke art. A new themed car = a new palette pick + object/hazard
> selection + a recon tell. The texture pass later re-skins the *section palette and themed objects*,
> not the layout, so it stays a drop-in.

## Asset list
*(No standalone SVGs — cars compose from `tile_*` and `obj_*` placeholders re-tinted by the §4
section palette at runtime. The mapping table above is the renderer's car-composition contract.)*

> **Section re-skin mechanism (implemented in `render/car_view.gd`):** the surface re-skin lands
> as per-section terrain variants named `<stem>__s<N>` (N = 1..5, e.g. `tile_floor__s3.png`) —
> the resolver prefers the car's section variant and falls back to the plain stem, so the
> 5-variant floor/wall commission (`tiles_terrain.md`, `ART_SHOPPING_LIST.md` §1b) is displayable
> the moment each file lands. Until variants ship, every section renders the neutral set.
