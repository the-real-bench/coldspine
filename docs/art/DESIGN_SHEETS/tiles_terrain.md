# Design Sheet — Tiles & Terrain

> Obeys `ART_BIBLE.md` §3.1–§3.2 (color language) and §7 (sizing). Iso 2:1 diamond,
> `128 × 64` footprint. These are the floor of every car; they read first and read most.

## Intent
At a glance the player must know: **can I stand here** (floor), **is this blocked**
(wall), **does this protect me** (half / full cover), and **will this hurt me** (gap /
furnace / live rail / piston). Function must survive scanline grain at phone size. Terrain
color is **constant across all 5 sections**; only surface texture/ambience re-skins (§4).

## Final-look image-gen prompt(s)

**Floor + wall set (per section):**
> "Stylized isometric game tile set, 2:1 diamond floor tiles and tall wall blocks, flat-shaded
> with a single soft rim light, chunky low-detail. Render five surface variants: (1) THE TAIL —
> grimy riveted scrap metal, rust streaks, soot, dim amber worklight, palette `#2A2420`/`#7A4A2C`;
> (2) THIRD CLASS — greasy industrial steel deckplate with hazard-yellow stripes, `#33392F`/`#C2A03A`;
> (3) SECOND CLASS — verdigris copper and wet tiled floor near glass, `#27433C`/`#2E8BC0`;
> (4) FIRST CLASS — polished marble with gold inlay seams, `#3A332A`/`#C9A24A`;
> (5) THE ENGINE — clinical white-blue brushed steel with cyan signal seams, `#2C3640`/`#3FC6D4`.
> Top-down isometric, single fixed camera, crisp readable edges, faint grid seam between tiles,
> security-camera-feed mood with subtle scanline grain. No characters, tileable."

**Cover + hazard tiles:**
> "Isometric 2:1 diamond hazard and cover tiles, flat-shaded, instantly readable:
> a half-cover crate with a low chevron lip (olive `#6E7B66`), a full-cover slab casting a small
> shadow (deep olive `#566B4F`), an open coupling GAP showing black void with a warning down-arrow,
> a glowing open FURNACE pit (`#FF7A18` core, ember rim, flame tongues), a live electrified RAIL with
> a yellow zigzag bolt band and arcing sparks (`#FFE14D`), and an armed steel PISTON with red down-slam
> warning arrows. Surveillance-feed grain, high contrast, mobile-legible, game-asset style."

**Cycling-trap hazard tiles (Phase-2/5 — telegraph the danger one turn ahead):**
> "Seven more isometric 2:1 diamond hazard tiles, each unmistakably dangerous on a security feed:
> a FIRE VENT grille jetting orange flame (`#FF7A18`); a LASER GRID of crossing red tripwire beams
> with emitter nodes (`#FF3B3B`); an ELECTRIFIED PLATE — a steel plate crawling with a yellow electric
> arc (`#FFE14D`); a STEAM VENT gushing a white-grey blinding cloud (`#C9CDD2`); a CONVEYOR belt with
> directional slats + a drift arrow (`#9AA3AD`); a sweeping LASER arc dashed around a pivot emitter
> (`#FF3B3B`); and a SCALD hot-tile glowing red with heat-shimmer (`#FF5A1F`). Surveillance grain,
> high contrast, mobile-legible, game-asset style."

## Placeholder spec (shipping now)
Flat fills, 1–2px `#0B0E11` outlines, one rim highlight. Colors are literal from §3.

- **Floor** — diamond `#3A4048`, faint inner seam `#2F343B`, top-edge rim `#4A525C`.
- **Wall** — diamond top face `#22262C`, raised body, hard top highlight `#4A525C`, no seam.
- **Half cover** — floor diamond + a `#6E7B66` half-height chevron bar on the front edge.
- **Full cover** — floor diamond + a `#566B4F` upright slab glyph + drop shadow.
- **Water tile** — `L_WATER` wash `#2E8BC0` @ 60% over floor, foam edge `#7EC8E3`, ripple line.
- **Fire tile** — `L_FIRE` `#FF5A1F` glow over floor, three flame tongues, ember dots.
- **Electrified tile** — water wash + `#FFE14D` zigzag arc lattice + `#E8FBFF` arc highlights.
- **Gap** — black `#0A0C0F` diamond, ragged inner ring, `⚠` down-arrow.
- **Furnace** — `#7A2400` rim ring → `#FF7A18` core radial → `#FFD08A` hot center, flame tongues.
- **Rail (live)** — steel diamond `#3A4048` + central `#2A2A12` band + `#FFE14D` zigzag bolt + arc dots.
- **Piston** — steel diamond + `#9AA3AD` plate + `#FF3B3B` down-slam arrows + warn ring.

## Asset list
| File | What it is |
|---|---|
| `tile_floor.svg` | Walkable floor diamond (`#3A4048`) |
| `tile_wall.svg` | Blocking anchored wall block (`#22262C`) |
| `tile_cover_half.svg` | Half-cover tile, olive chevron (`#6E7B66`) |
| `tile_cover_full.svg` | Full-cover tile, deep-olive slab (`#566B4F`) |
| `tile_water.svg` | Flood/water layer tile (`L_WATER` `#2E8BC0`) — **REFERENCE-ONLY**: layers are procedural runtime overlays, never loaded; do not commission |
| `tile_fire.svg` | Fire layer tile (`L_FIRE` `#FF5A1F`) — **REFERENCE-ONLY**, as above |
| `tile_electrified.svg` | Electrified water tile (`L_WATER`+`L_ELECTRIFIED`) — **REFERENCE-ONLY**, as above |
| `tile_gap.svg` | Gap / coupling eject hazard (`Hazard.GAP`) |
| `tile_furnace.svg` | Open furnace hazard (`Hazard.FURNACE`) |
| `tile_rail.svg` | Live electrified rail (`Hazard.RAIL_LIVE`) |
| `tile_piston.svg` | Crush piston hazard (`Hazard.PISTON`) |
| `tile_vent.svg` | Fire vent — grille jets fire on its cycle (`Hazard.VENT`) |
| `tile_laser.svg` | Laser grid — live red tripwire beams (`Hazard.LASER`) |
| `tile_plate.svg` | Electrified plate — shocks on its cycle (`Hazard.PLATE`) |
| `tile_steam.svg` | Steam vent — blinds + blocks LoS (`Hazard.STEAM`) |
| `tile_conveyor.svg` | Conveyor belt — drifts a unit 1 tile/phase (`Hazard.CONVEYOR`) |
| `tile_laser_sweep.svg` | Laser sweep — arc steps around each cycle (`Hazard.LASER_SWEEP`) |
| `tile_scald.svg` | Scald hot-tile — damage on enter/stand (`Hazard.SCALD`) |

> **Render wiring note:** all 7 are mapped in `render/car_view.gd::_terrain_tex_stem` (fire 9) — they
> previously fell through to `tile_floor` (danger invisible on the textured feed). The ascii path
> (`_tile_glyph`) is intentionally left unchanged to keep the headless suites byte-stable.

> **Section-variant filenames (for the 5-variant floor/wall prompt above):** deliver the five
> surface variants as `tile_floor__s1..__s5` and `tile_wall__s1..__s5` (`__s1` = Tail …
> `__s5` = Engine) into `assets/final/` at 2x (`256×128`+). The renderer prefers the car's
> section variant and falls back to the plain stem — see `ART_BIBLE.md` §4/§8.1. The layer
> tiles marked REFERENCE-ONLY above are runtime-drawn and need no variants.
