# Placeholder Asset Manifest

> 79 standalone SVG placeholders implementing the `docs/art/ART_BIBLE.md` §3 color language.
> (73 board/tile/status/UI + 5 draft-character portraits `portrait_<archetype>` [W5-1] + 1 econ
> flavor art `car_flavor` [W5-15] — the Wave-5 presentation art layer, larger than the 64px tokens.)
> Format: SVG only (diffable, Godot-importable). Filenames + viewBoxes are the **contract** —
> a texture artist swaps the file behind the same name/footprint and the game keeps working
> (`ART_BIBLE.md` §8). Colors are literal hex from the bible's gameplay color language, NOT
> section re-skins, so they read identically in any car.
>
> viewBoxes: tiles `0 0 128 64` · tokens `0 0 96 96` · status `0 0 24 24` · UI `0 0 1280 720`.

## Texture resolution contract (binding — `render/car_view.gd::_tex`)

For each stem the renderer probes, in win order:

1. `assets/final/<stem>.png`   — **final art drop zone**: a raster here overrides the placeholder
2. `assets/final/<stem>.svg`
3. `assets/placeholders/<stem>.png`
4. `assets/placeholders/<stem>.svg` — the shipped placeholder (this manifest)

So final art lands **file-by-file with zero code churn**: drop `assets/final/unit_bruiser.png`,
run the import scan, and the game uses it; delete it and the placeholder returns.

- **After ANY texture file lands or moves, run the import scan once:**
  `godot --headless --path . --import` — an SVG/PNG without its `.import` sidecar is INVISIBLE
  to `ResourceLoader` and the token silently falls back (that bug class shipped once: 29 files
  green-on-disk but unloadable at runtime). `tests/tex_coverage_smoke.gd` now fails loud on it.
- **Resolution is decoupled from layout**: the renderer draws tiles/tokens into fixed logical
  rects (tile `128×64` bottom-anchored, token `96×96` centered), so deliver final art at **2x**
  (tiles `256×128`, tokens `192×192`, status `48×48`) for crisp hi-dpi with identical layout.
  Tile art taller than its 2:1 diamond grows **upward** past the top vertex (walls, §7).
- **Section re-skin variants** (`ART_BIBLE` §4): terrain stems may ship per-section variants
  `<stem>__s<N>` (N = 1..5), e.g. `tile_floor__s2.png`. When the car view's `section` is set the
  variant wins; a missing variant falls back to the plain stem.
- **Reference-only files** (tagged below): drawn procedurally at runtime by design — do NOT
  spend final-art hours on them (`tile_water`, `tile_fire`, `tile_electrified`,
  `ui_ops_console_frame`).

## Terrain & hazard tiles (18) — iso 2:1 diamond, `128×64`
| File | Description | Primary color |
|---|---|---|
| `tile_floor.svg` | Walkable floor diamond (`Terrain.FLOOR`) | `#3A4048` |
| `tile_wall.svg` | Blocking anchored wall block (`Terrain.WALL`) | `#22262C` |
| `tile_cover_half.svg` | Half-cover tile, olive chevron lip (coverValue 1) | `#6E7B66` |
| `tile_cover_full.svg` | Full-cover tile, upright deep-olive slab (coverValue 2) | `#566B4F` |
| `tile_water.svg` | Flood/water layer (`L_WATER`), foam edge — **REFERENCE-ONLY, not runtime-loaded** (layers are procedural overlays in `car_view.gd::_draw_tile_layers`) | `#2E8BC0` |
| `tile_fire.svg` | Fire layer (`L_FIRE`), flame tongues + embers — **REFERENCE-ONLY, not runtime-loaded** | `#FF5A1F` |
| `tile_electrified.svg` | Electrified water (`L_WATER`+`L_ELECTRIFIED`) — marquee combo — **REFERENCE-ONLY, not runtime-loaded** | `#2E8BC0` + `#FFE14D` |
| `tile_gap.svg` | Gap/coupling eject hazard (`Hazard.GAP`) | `#0A0C0F` |
| `tile_furnace.svg` | Open furnace fire pit (`Hazard.FURNACE`) | `#FF7A18` / `#7A2400` |
| `tile_rail.svg` | Live electrified rail (`Hazard.RAIL_LIVE`) | `#FFE14D` on `#2A2A12` |
| `tile_piston.svg` | Crush piston, armed warn ring (`Hazard.PISTON`) | `#9AA3AD` / `#FF3B3B` |
| `tile_vent.svg` | Fire vent grille + flame jet (`Hazard.VENT`) | `#FF7A18` |
| `tile_laser.svg` | Laser grid, crossing tripwire beams (`Hazard.LASER`) | `#FF3B3B` |
| `tile_plate.svg` | Electrified plate, arc lattice (`Hazard.PLATE`) | `#FFE14D` |
| `tile_steam.svg` | Steam vent, blinding LoS-block cloud (`Hazard.STEAM`) | `#C9CDD2` |
| `tile_conveyor.svg` | Conveyor belt + drift arrow (`Hazard.CONVEYOR`) | `#9AA3AD` |
| `tile_laser_sweep.svg` | Sweeping laser arc on a pivot (`Hazard.LASER_SWEEP`) | `#FF3B3B` |
| `tile_scald.svg` | Scald hot-tile, heat shimmer (`Hazard.SCALD`) | `#FF5A1F` |

## Unit tokens (5) — `96×96`, player faction ring `#2EA7E0`
| File | Description | Accent |
|---|---|---|
| `unit_bruiser.svg` | Bruiser — frontline displacement engine, hammer | `#C26A2A` (rust) |
| `unit_marksman.svg` | Marksman — ranged DPS, long rifle + scope | `#5FA86A` (green) |
| `unit_saboteur.svg` | Saboteur — hazard/tech, gear + antenna | `#FFE14D` (yellow) |
| `unit_steward.svg` | Steward — support/medic, cross | `#7EC8E3` (teal) |
| `unit_firebrand.svg` | Firebrand — momentum/morale, torch flame | `#FF5A1F` (crimson) |

## Enemy + boss tokens (16) — `96×96`, enemy faction ring `#E0432E`
| File | Description | Physics-counter tell |
|---|---|---|
| `enemy_truncheon.svg` | Truncheon Guard — basic melee | Baton; easy to slam |
| `enemy_riot_shield.svg` | Riot Shield — frontal block | Big shield one facing; flank/soak |
| `enemy_net_gunner.svg` | Net Gunner — immobilizer | Net glyph; priority kill |
| `enemy_enforcer.svg` | Enforcer — armored ranged | Pauldrons + carbine; strip & flank |
| `enemy_hound.svg` | Hound — fast flanker | Low body + speed streaks; bait to hazard |
| `enemy_sniper.svg` | Sniper — overwatch threat | Long rifle + red laser; break LoS |
| `enemy_drone_op.svg` | Drone Operator — deploys bots | Backpack rig + bot dots; kill operator |
| `enemy_security_robot.svg` | Security Robot — heavy, hackable | Steel body + cyan hack-node `#3FC6D4` |
| `enemy_sentry_turret.svg` | Sentry Turret — static, destructible | Base + twin barrels + eye |
| `enemy_captain.svg` | Section Captain (generic) — elite gate / fallback | Double ring + gold rank + gimmick mote |
| `enemy_captain_tail_warden.svg` | The Tail Warden (S1) — soak key | Maul + blue SOAK mote `#2E8BC0` |
| `enemy_captain_foreman.svg` | The Foreman (S2) — buff key | Hard hat + wrench + gold BUFF aura `#FFE14D` |
| `enemy_captain_gardener.svg` | The Head Gardener (S3) — gas key | Green GAS shroud `#7FBF3F` + shears |
| `enemy_captain_majordomo.svg` | The Majordomo (S4) — cover key | Grey COVER slab `#9AA3AD` + tailcoat |
| `enemy_captain_chief.svg` | Chief of Security (S5) — soak key | Steel `#2C3640` + cyan visor + badge |
| `enemy_conductor.svg` | The Conductor — finale boss | Peaked cap + cyan RELAY glow `#3FC6D4` + dashed inner ring |

## Interactive objects (19) — `96×96`, object tint `#9AA3AD` (no glow), integrity pips
| File | Description | onBreak / role |
|---|---|---|
| `obj_fish_tank.svg` | Aquarium full of blue water + crack line | FLOOD (`#2E8BC0`) — marquee trigger |
| `obj_junction.svg` | Power junction, yellow zigzag + contacts | ELECTRIFY (`L_ELECTRIFIED` `#FFE14D`) |
| `obj_barrel.svg` | Fuel drum, red bands + flammable mark | EXPLODE (`#FF5A1F`) |
| `obj_crate.svg` | Supply crate, plank seams | COLLAPSE to debris; half cover |
| `obj_table.svg` | Iso table, flippable | Throwable + relocatable half cover (LIGHT) |
| `obj_glass_partition.svg` | Frosted glass pane | Shatters to nothing; full cover (LIGHT) |
| `obj_coolant_tank.svg` | Steel coolant cylinder + frost | FLOOD r3 (`#2E8BC0`) — Spa/Cold Storage source |
| `obj_water_main.svg` | Wall pipe + valve wheel + leak | FLOOD r4 (`#2E8BC0`) — biggest flood source |
| `obj_gas_main.svg` | Wall pipe + valve + green gas puffs | spill POISON_GAS (`#7FBF3F`) |
| `obj_weight_rack.svg` | Steel frame + weight plates | TOPPLE (Gym) |
| `obj_marble_statue.svg` | White figure on a pedestal | TOPPLE (First class) |
| `obj_chandelier.svg` | Gold hanging arms + flames | TOPPLE straight DOWN |
| `obj_tree.svg` | Trunk + green canopy + flame mark | TOPPLE, flammable |
| `obj_hedge_wall.svg` | Dense foliage barrier | COLLAPSE, blocksLoS, flammable |
| `obj_hedge_sculpture.svg` | Topiary cone | TOPPLE, flammable |
| `obj_bookshelf.svg` | Shelves + colored book spines | TOPPLE, flammable (Library) |
| `obj_pottery_vase.svg` | Terracotta vase | COLLAPSE (shatters) |
| `obj_planter.svg` | Soil box + greenery | COLLAPSE; half cover |
| `obj_thin_ice.svg` | Pale cracked-ice diamond | FLOOD r1 — drops occupants (Soaked+Chilled) |

## Status icons (14) — `24×24` rounded badge, white glyph, color = `S_*` per bible §3.4

> All 14 are registered in `car_view.gd::STATUS_TEX` (S_* flag → stem, guarded by
> `tex_coverage_smoke`) so they resolve through the same final-art contract as every token.
> The on-feed badges still DRAW as procedural colored circles for now — swapping the badge draw
> to these icons (closing the §6.1 hue-only colorblind gap) is scheduled with the HUD pass.
> `S_DOWNED` and `S_BLEEDING` share `status_bleeding.svg` (same death-window family).
| File | Status (`S_*`) | Fill |
|---|---|---|
| `status_prone.svg` | Prone (`S_PRONE`) — down-chevron + bar | `#C8A24A` |
| `status_stunned.svg` | Stunned (`S_STUNNED`) — spiral + stars | `#F2D14E` |
| `status_soaked.svg` | Soaked (`S_SOAKED`) — teardrop | `#2E8BC0` |
| `status_burning.svg` | Burning (`S_BURNING`) — flame tongue | `#FF5A1F` |
| `status_shocked.svg` | Shocked (`S_SHOCKED`) — lightning bolt | `#FFE14D` |
| `status_poisoned.svg` | Poisoned (`S_POISONED`) — biohazard trefoil | `#7FBF3F` |
| `status_blinded.svg` | Blinded (`S_BLINDED`) — slashed eye | `#C9CDD2` |
| `status_chilled.svg` | Chilled (`S_CHILLED`) — thin snowflake | `#8FD4E8` |
| `status_frozen.svg` | Frozen (`S_FROZEN`) — solid ice cube | `#BFEFFF` |
| `status_bleeding.svg` | Bleeding/Downed (`S_DOWNED`) — cross + drip | `#C0354A` |
| `status_suppressed.svg` | Suppressed (`S_SUPPRESSED`) — pinning arrows | `#B07A2E` |
| `status_buried.svg` | Buried (`S_BURIED`) — head over a rubble/snow mound | `#8A7C64` |
| `status_netted.svg` | Netted (`S_NETTED`) — crosshatch net mesh | `#B98A4A` |
| `status_overwatch.svg` | Overwatch (`R_OVERWATCH`, render-only #21) — watching eye | `#3FC6D4` |

## UI mock (1) — `1280×720`
| File | Description | Colors |
|---|---|---|
| `ui_ops_console_frame.svg` | Full ops-console HUD: camera-ID header, comms log, AP/order strip, recon strip (next-full / after-partial / Deep Scan), Order meter, physics-preview ghost, scanline + vignette overlay — **REFERENCE-ONLY mock, not runtime-loaded** (OpsHUD is code-built, `render/ops_hud.gd`) | chrome `#0B0E11`, amber `#FFB000`, cyan `#3FC6D4`, alert `#FF3B3B` |

---

**Total: 73 SVG files** (18 tiles · 5 units · 10 enemies · 6 captains · 19 objects · 14 status · 1 UI).
All well-formed XML, flat-fill, ≤2px dark outlines (`#0B0E11`), on-palette per `ART_BIBLE.md` §3.
