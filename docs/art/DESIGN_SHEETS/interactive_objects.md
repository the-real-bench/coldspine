# Design Sheet — Interactive Objects

> Obeys `ART_BIBLE.md` §3.5 (object = inert steel grey ring/tint `#9AA3AD`, no glow) and §7
> (object footprint scales with mass). These are the **physics toys** — the environment-as-weapon
> (GDD §6.5–§6.6). Their silhouette must telegraph **mass** (how far it flies), **cover value**,
> and **what happens when it breaks** (`onBreak`: flood / explode / collapse / spill-fire).

## Intent
The player reads: **can I shove/throw this** (mass), **does it protect me** (cover pips), and
**what's the payoff if it breaks** (onBreak tell). A fish tank must SCREAM "flood me" (visible
water + a crack line). A barrel must read "explosive." Integrity is shown as small pips on the
token so the player knows how close it is to popping (the §6.6 marquee setup).

## Final-look image-gen prompt(s)

> "Stylized isometric destructible objects for a physics tactics game, flat-shaded, inert steel-grey
> outline (`#9AA3AD`), seen top-down through a security camera, each clearly telegraphing its break
> behavior: (1) FISH TANK — large glass aquarium full of glowing blue water and fish silhouettes,
> faint stress-crack lines, obviously floodable (`onBreak: flood`, `#2E8BC0`); (2) POWER JUNCTION —
> a wall-mounted electrical box with a yellow zigzag hazard mark and exposed contacts, the thing that
> electrifies flood water (`#FFE14D`); (3) EXPLOSIVE BARREL — red-striped fuel drum with a flammable
> symbol (`onBreak: explode`, `#FF5A1F`); (4) SUPPLY CRATE — chunky wooden/metal box, half-cover,
> stackable; (5) BANQUET TABLE — long flippable table, prime throwable/cover (Dining car); (6) GLASS
> PARTITION — a tall pane of frosted glass, full cover but shatters to nothing. Chunky low-detail,
> dark outline, single rim light, mass legible from bulk, surveillance grain, game-asset style."

**Hazard sources (the flood/gas 'mains' — distinct industrial silhouettes, grey `#9AA3AD` frame):**
> "Three industrial destructible hazard sources for a physics tactics game, flat-shaded, steel-grey
> outline, each screaming its break payoff: (1) COOLANT TANK — a heavy upright steel cylinder with a
> blue coolant level window and frost rime, cracks to FLOOD a wide area (`onBreak: flood`, `#2E8BC0`);
> (2) WATER MAIN — a thick wall pipe with a hand valve wheel, blue water jetting from a split seam,
> floods the biggest radius (`#2E8BC0`); (3) GAS MAIN — a similar pipe + valve venting sickly green
> POISON GAS clouds with a hazard triangle, fills the car with a blinding/toxic cloud (`onBreak:
> spill poison_gas`, `#7FBF3F`). Surveillance grain, dark outline, integrity pips, game-asset style."

## Placeholder spec (shipping now)
Grey object ring/outline `#9AA3AD`, body fill per type, an onBreak tell glyph, and a small
row of integrity pips. Footprint scales with mass per §7.

| Object | Mass | Cover | onBreak tell | Body / accent |
|---|---|---|---|---|
| **Fish tank** | Heavy | Full | FLOOD — blue water fill `#2E8BC0` + foam + crack line | Glass frame `#9AA3AD`, fish dots |
| **Junction box** | Anchored | None | ELECTRIFY — yellow `#FFE14D` zigzag + contacts | Steel box `#5A6470`, ⚡ mark |
| **Explosive barrel** | Medium | Half | EXPLODE — orange `#FF5A1F` + hazard stripes | Drum `#7A6E5A`, red bands |
| **Crate** | Medium | Half | COLLAPSE — debris `#7A6E5A` | Box `#6E6354`, plank seams |
| **Table** | Light | Half | none (throwable/relocatable cover) | Plank top `#8A7A5A`, legs |
| **Glass partition** | Light | Full | none (shatters, no spill) | Frosted pane `#B6C6CE` @ 50% + frame |
| **Coolant tank** | Heavy | Full | FLOOD r3 — blue `#2E8BC0` + frost rime | Steel cylinder, level window, crack |
| **Water main** | Anchored | None | FLOOD r4 — blue `#2E8BC0` jet | Wall pipe + valve wheel + leak |
| **Gas main** | Anchored | None | spill POISON_GAS — green `#7FBF3F` cloud | Wall pipe + valve + gas puffs + ⚠ |

## Asset list
| File | What it is |
|---|---|
| `obj_fish_tank.svg` | Aquarium — `onBreak: flood`, the marquee flood trigger (§6.6) |
| `obj_junction.svg` | Power junction — electrifies connected flood water (`L_ELECTRIFIED`) |
| `obj_barrel.svg` | Explosive barrel — `onBreak: explode` |
| `obj_crate.svg` | Supply crate — half cover, `onBreak: collapse` to debris |
| `obj_table.svg` | Banquet/table — light throwable + relocatable half cover |
| `obj_glass_partition.svg` | Glass partition — full cover that shatters to nothing |
| `obj_coolant_tank.svg` | Coolant tank — `onBreak: flood` r3 (Spa/Cold Storage); industrial cylinder |
| `obj_water_main.svg` | Water main — `onBreak: flood` r4; pipe + valve, biggest flood |
| `obj_gas_main.svg` | Gas main — `onBreak: spill poison_gas`; pipe + valve + green cloud |
| `obj_weight_rack.svg` | Weight rack — `onBreak: topple` (Gym); steel frame + plates |
| `obj_marble_statue.svg` | Marble statue — `onBreak: topple` (First class); white figure + pedestal |
| `obj_chandelier.svg` | Chandelier — `onBreak: topple DOWN` (falls on whoever's below); gold arms |
| `obj_tree.svg` | Tree — `onBreak: topple`, flammable (Forest/Garden); trunk + canopy |
| `obj_hedge_wall.svg` | Hedge wall — `onBreak: collapse`, blocksLoS, flammable; dense foliage |
| `obj_hedge_sculpture.svg` | Hedge sculpture (topiary) — `onBreak: topple`, flammable |
| `obj_bookshelf.svg` | Bookshelf — `onBreak: topple`, flammable (Library); book spines |
| `obj_pottery_vase.svg` | Pottery vase — `onBreak: collapse` (shatters); terracotta |
| `obj_planter.svg` | Planter — `onBreak: collapse` (spills soil); half cover + greenery |
| `obj_thin_ice.svg` | Thin ice — `onBreak: flood` r1 (cracks, drops occupants: Soaked+Chilled) |

> **Render wiring note:** `barrel_explosive` / `oxygen_tank` / `alcohol_barrel` reuse `obj_barrel`,
> and `serving_cart` / `bench` / `chair` → `obj_table`, `locker` → `obj_crate`, per the role-exemplar
> contract (`render/car_view.gd` OBJ_TEX). As of fire 10 **every objects.json id now has its own token**
> (the topple props + remaining decor were added), so the guard's `FALLBACK_OK` allowlist is empty.
