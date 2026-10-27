# Design Sheet — Hazards & VFX

> Obeys `ART_BIBLE.md` §3.2 (hazard tiles), §3.3 (hazard layers), §6 (telegraph conventions).
> Covers the **animated** side of hazards (the tile bases live in `tiles_terrain.md`): the flood
> wave, electrify arc chain, fire spread, the physics-preview overlay, and event-driven juice
> tied to the `Ev.*` event vocabulary (`core/sim_enums.gd`).

## Intent
Hazards must be **legible one turn ahead** (GDD §16) and **never surprise** the operator
(GDD §6.7). The player must distinguish *what WILL happen next turn* (telegraph, ~50% opacity,
dashed) from *what IS happening now* (live, solid, animated). The Flood→Soak→Electrify chain
(§6.6) is the marquee — its VFX must read as a single readable cause-chain: blue wave knocks
prone, leaves blue standing water, yellow arcs leap across it.

## Final-look image-gen prompt(s)

**Flood / electrify chain:**
> "Stylized isometric VFX sheet for a tactics game, top-down security-camera view: a FLOOD WAVE
> radiating outward from a shattered tank as a translucent blue crescent (`#2E8BC0`) with white foam
> (`#7EC8E3`), knocking figures prone; STANDING WATER as a calm blue tile wash with ripple lines;
> an ELECTRIFY CHAIN as bright cyan-white lightning arcs (`#FFE14D`/`#E8FBFF`) leaping tile-to-tile
> across the connected water, crackling nodes at each soaked figure. Flat-shaded, glowing, juicy,
> mobile-readable, dark background, game-asset style."

**Fire / gas / impact:**
> "Stylized isometric hazard VFX: FIRE as orange flame licks (`#FF5A1F`) with rising embers and a
> dashed advancing spread-front line one tile ahead; POISON GAS as a translucent sick-green cloud
> (`#7FBF3F`) with a soft drifting edge; STEAM as a pale-grey blinding puff (`#C9CDD2`); a WALL-IMPACT
> star-burst marker (`#FFE14D`) where a slammed body hits; a flat translucent GHOST TOKEN (50% opacity)
> showing a unit's predicted landing position with tiny Prone/Soaked result icons. Flat-shaded, juicy,
> high-contrast, security-feed grain, game-asset style."

## Placeholder spec (shipping now)
The hazard *tile bases* ship in `tiles_terrain.md` (water/fire/electrified/gap/furnace/rail/
piston). This sheet's VFX (waves, arcs, ghosts, impact stars, gas/steam clouds, spread fronts)
are **renderer-drawn at runtime from the `Ev.*` event stream**, not static SVGs — so no new SVG
files ship here. The renderer reuses tile-layer colors from §3.3 and the telegraph rules in §6.

**Renderer cues (binding):**
| Event (`Ev.*`) | VFX | Color |
|---|---|---|
| `FLOOD_TILE` | Expanding wave crescent + foam, then standing-water wash | `#2E8BC0` / `#7EC8E3` |
| `SHOCK` | Arc lattice leaping across connected water, screen glitch | `#FFE14D` / `#E8FBFF` |
| `IMPACT_WALL` | Impact star-burst marker + dust + chroma spike | `#FFE14D` |
| `COLLIDE_BODY` | Small impact spark at contact tile | `#F2D14E` |
| `OBJECT_BREAK` | Shatter shards (glass) / debris puff + chroma spike | per object |
| `HAZARD_FURNACE` | Flame flare-up | `#FF7A18` |
| `HAZARD_RAIL` | Bolt arc flash | `#FFE14D` |
| `HAZARD_PISTON` | Slam-down arrows + crush flash | `#FF3B3B` |
| `EJECT` | Token falls into gap dark + fade | `#0A0C0F` |
| `STATUS_APPLY` / `STATUS_CLEAR` | Status badge pop-in / fade-out (see `status_icons.md`) | per status |

**Preview overlay (the #1 UI feature, §6.7):** dotted trajectory (faction-tinted), impact-star
markers at collision points, translucent ghost tokens at end positions with inline result icons,
faded flood/fire/debris fills where hazards will spawn. Never uses alarm-red. ~50% opacity.

## Asset list
*(No standalone SVGs — all runtime VFX. Telegraph/preview swatches are defined in the bible §3.3
and §6.2; the static hazard tiles are in `tiles_terrain.md`. This sheet is the renderer's VFX
contract.)*
