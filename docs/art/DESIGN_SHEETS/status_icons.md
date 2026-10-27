# Design Sheet — Status Icons

> Obeys `ART_BIBLE.md` §3.4 (status color+shape contract) and §6.1 (badge conventions).
> One icon per `S_*` bitflag (`core/sim_enums.gd`, GDD §5.5). `24 × 24` viewBox, badge ~20px.
> **Color AND shape are both load-bearing** — a color-blind player or a grainy feed must still
> tell them apart. Badges ring the unit token clockwise from 1 o'clock (§6.1).

## Intent
A unit may carry several statuses at once (Soaked + Prone, Chilled stacking toward Frozen).
Each badge must be identifiable in isolation AND in a cluster of three. The §3.4 "family logic"
makes the set learnable: water→blue, fire→orange, cold→ice-white, disable→yellow/brown, toxic→
green, vision→grey, death-window→blood-red.

## Final-look image-gen prompt(s)

> "A set of fourteen small flat status-effect icons for a tactics game HUD, each a rounded badge with
> a 2px dark outline and a white inner glyph on a colored fill, readable at 20px:
> PRONE — amber-tan (`#C8A24A`) down-chevron / fallen figure;
> STUNNED — yellow (`#F2D14E`) orbiting-stars spiral;
> SOAKED — water-blue (`#2E8BC0`) teardrop;
> BURNING — fire-orange (`#FF5A1F`) triple flame tongue;
> SHOCKED — electric-yellow (`#FFE14D`) lightning bolt;
> POISONED — sick-green (`#7FBF3F`) biohazard trefoil / skull-bubble;
> BLINDED — fog-grey (`#C9CDD2`) crossed/struck-through eye;
> CHILLED — pale-ice (`#8FD4E8`) thin snowflake;
> FROZEN — frost white-blue (`#BFEFFF`) solid ice cube;
> BLEEDING/DOWNED — blood-red (`#C0354A`) medical cross with a drip;
> SUPPRESSED — dull orange-brown (`#B07A2E`) downward pinning arrows;
> BURIED — debris-brown (`#8A7C64`) head peeking above a rubble/snow mound;
> NETTED — rope-tan (`#B98A4A`) crosshatch net mesh;
> OVERWATCH — cyan (`#3FC6D4`) watching eye (lens + pupil; the render-only #21 'holding' tell, not a sim DoT).
> Crisp, high-contrast, game-UI icon style, distinct silhouettes, consistent badge shape."

## Placeholder spec (shipping now)
Rounded-square badge, fill = §3.4 color, 2px `#0B0E11` outline, white `#F2F4F6` glyph.

| Status | Bitflag | Fill | Glyph |
|---|---|---|---|
| Prone | `S_PRONE` | `#C8A24A` | Down-chevron `⌄` over a horizontal bar |
| Stunned | `S_STUNNED` | `#F2D14E` | Spiral with two orbiting star dots |
| Soaked | `S_SOAKED` | `#2E8BC0` | Teardrop |
| Burning | `S_BURNING` | `#FF5A1F` | Triple flame tongue |
| Shocked | `S_SHOCKED` | `#FFE14D` | Lightning bolt (zigzag) |
| Poisoned | `S_POISONED` | `#7FBF3F` | Trefoil biohazard |
| Blinded | `S_BLINDED` | `#C9CDD2` | Eye with a slash |
| Chilled | `S_CHILLED` | `#8FD4E8` | Thin 6-point snowflake |
| Frozen | `S_FROZEN` | `#BFEFFF` | Solid ice cube (filled) |
| Bleeding (Downed) | `S_DOWNED` | `#C0354A` | Medical cross + drip |
| Suppressed | `S_SUPPRESSED` | `#B07A2E` | Two downward pinning arrows |
| Buried | `S_BURIED` | `#8A7C64` | Head peeking above a rubble/snow mound |
| Netted | `S_NETTED` | `#B98A4A` | Crosshatch net mesh (diamond grid) |
| Overwatch | `R_OVERWATCH` | `#3FC6D4` | Watching eye (lens + pupil) — render-only #21 tell |

> **Bitflag coverage note:** `S_DOWNED (1<<10)` and `S_BLEEDING (1<<11)` are the same death-window family
> and intentionally share `status_bleeding.svg` (blood-red cross). `R_OVERWATCH` is a render-only pseudo-status
> (`render/palette.gd:R_OVERWATCH = 1<<20`), not a sim DoT, but it gets an icon because the HUD surfaces it
> as a badge. **Render gap CLOSED 2026-06-28:** `S_BURIED`/`S_NETTED` are now wired into `Pal.STATUS_ORDER`
> (`"u"`/`"t"`) + `Pal.status_color` (`#8A7C64`/`#B98A4A`), so a Buried/Netted unit draws an on-screen badge.
> The `STATUS_ORDER` glyph is a legend label (not the board read — `debug_ascii` composes by faction), so the
> change was byte-stable: all 13 suites stayed green (1055 checks, zero regressions).

> **Registry wired / draw gap OPEN (colorblind):** all 14 icons are now registered in
> `render/car_view.gd::STATUS_TEX` (S_* flag → stem; `S_DOWNED`+`S_BLEEDING` share
> `status_bleeding`) and guarded by `tex_coverage_smoke`, so they resolve through the standard
> final-art contract. BUT the on-feed badges still draw as **hue-only procedural circles**
> (`_draw_status_badges`) — Stunned `#F2D14E` vs Shocked `#FFE14D` vs Prone `#C8A24A` are
> near-indistinguishable on a grainy feed, violating §6.1's "never rely on hue alone".
> Swapping the badge draw to these icons is scheduled with the HUD pass; the art side is done.

## Asset list
| File | What it is |
|---|---|
| `status_prone.svg` | Prone — knocked down, no cover, costs AP to stand |
| `status_stunned.svg` | Stunned — skips/loses next action |
| `status_soaked.svg` | Soaked — easier to hit, chains electricity |
| `status_burning.svg` | Burning — DoT, spreads, cancels Soaked |
| `status_shocked.svg` | Shocked — AoE chain through soaked water, heavy stun |
| `status_poisoned.svg` | Poisoned — DoT + accuracy down, lingers |
| `status_blinded.svg` | Blinded — accuracy/LoS down for a turn |
| `status_chilled.svg` | Chilled — −Move/−accuracy, stacks toward Frozen |
| `status_frozen.svg` | Frozen — skips turn until thawed by heat |
| `status_bleeding.svg` | Bleeding/Downed — revive window before permadeath |
| `status_suppressed.svg` | Suppressed — movement-restricted, accuracy down |
| `status_buried.svg` | Buried — caught by an avalanche, immobilized 1 turn (E1.6) |
| `status_netted.svg` | Netted — Net Gunner immobilized this unit a turn (§12) |
| `status_overwatch.svg` | Overwatch — the render-only "holding this lane" eye tell (#21) |
