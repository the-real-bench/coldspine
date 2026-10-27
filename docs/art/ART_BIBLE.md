# COLDSPINE — Art Bible

> The single source of truth for COLDSPINE's visual direction. Everything the renderer
> draws and every placeholder in `assets/placeholders/` obeys the color language in §3.
> Final textures are OUT of scope right now — this bible plus the per-category design
> sheets (`DESIGN_SHEETS/`) describe the intended FINAL look so the texture pass later
> is a **drop-in replace, not a redesign**.
>
> Anchors: GDD §3.1 (operator framing), §5.5 (status set), §8.1 (the 5 sections),
> §15 (art direction), §16 (UX/UI). Enums: `core/sim_enums.gd`. Biomes: Sub-Spec E.

---

## 1. Visual pillars

1. **The screen IS the fiction.** You are a remote operator watching hijacked
   security cameras (GDD §3.1). The entire UI is a **surveillance / ops console** —
   CRT scanlines, feed grain, camera IDs (`CAR 14 — AQUARIUM`), a comms log. We are
   not hiding the interface; the interface *is* the story. Every abstraction (the
   physics preview, the recon strip, the fog of war) is something a camera grid can
   plausibly show.
2. **Readability over fidelity (GDD §15).** Cover, hazards, water, fire, and every
   status must read **instantly at a glance**, on a ~5–6" phone screen, through scanline
   grain. Clarity beats detail. When the two conflict, clarity wins — always.
3. **Stylized isometric, flat-shaded.** Tile-based 2.5D iso (Godot `TileMapLayer`).
   Chunky, low-detail, high-contrast silhouettes. Programmer art (flat fills + a
   single rim light) is the MVP target and a perfectly acceptable shipping floor.
4. **Palette tells the journey (GDD §8.1, §15).** Front-to-back the world escalates
   **Tail (grimy / dark / claustrophobic) → Engine (sterile / bright / metallic /
   inhuman)**. You can read how deep you are from the palette alone. The decadence of
   Sections 3–4 (Sub-Spec E amenities) is *grotesque luxury* — saturated, ornamental,
   wrong next to a starving tail.
5. **Physics is the fantasy, so telegraph it (GDD §6.7, §16).** Trajectories,
   collisions, who-ends-up-where, what breaks, what floods — all shown BEFORE commit.
   Preview ghosts, impact markers, and hazard fronts are first-class visual citizens,
   not afterthoughts.
6. **Faction reads before archetype reads.** At a glance you must know *whose* a token
   is (player / enemy / neutral / object) before you parse *what* it is. Faction is a
   ring/tint; archetype is a silhouette glyph inside it.

---

## 2. The operator / CRT framing

The diegetic layer wrapping every car:

- **CRT scanline overlay** — horizontal 1px dark lines at ~50% opacity over the whole
  feed, plus a very subtle vignette and a slow scan-flicker. Implemented as a screen-space
  shader in `render/` (placeholder mock shows static lines). Do **not** bake scanlines into
  individual sprites — it's a post pass so it survives a texture swap.
- **Camera-ID header** — top-left, monospace: `CAR 07 — COOLANT BAY`, a `● REC` blink,
  a timecode, and signal bars. This is the car title.
- **Feed grain** — light additive noise; heavier in Tail/low-light cars, cleaner in the
  sterile Engine (the system's own cameras are nicer up front — a quiet escalation tell).
- **Comms log** — bottom-left scrolling panel: orders issued and unit barks
  (`> BRUISER: copy.` / `! CONTACT, CAR 12`). Amber-on-black terminal type.
- **Glitch on shock/break** — a 2–4 frame horizontal-tear + chroma-split when something
  big happens (a flood, an electrify chain, a wall collapse). Sells the camera "feeling" the
  event. Cheap, juicy, on-theme.
- **Fog / blind spots (Sub-Spec E1.4)** — in maze/steam cars the feed goes **dead-signal
  black with a faint static** outside unit line-of-sight. The surveillance omniscience is
  taken away exactly where the train wants it gone.

**Chrome color:** the console frame is the constant; only the *feed contents* (the car)
shift palette by section. Frame = near-black `#0B0E11` panels, amber `#FFB000` primary
type, dim cyan `#3FC6D4` secondary/data, alert red `#FF3B3B`.

---

## 3. The readability color language *(THE CONTRACT)*

This table is binding. The renderer, every placeholder SVG, and every future texture
**must** map to these hues and icon shapes. Section palettes (§4) re-skin *surfaces and
ambience*; this language for **gameplay-critical** elements (terrain function, hazards,
statuses, factions) stays **constant across all sections** so the player never relearns it.

> Icon **shape** is as load-bearing as color (color-blind safety + scanline legibility).
> Shapes are simple enough to draw at 16px.

### 3.1 Terrain & cover (maps to `Terrain` enum + cover objects)

| Element | Enum / source | Hex | Icon / shape language |
|---|---|---|---|
| **Floor** (walkable) | `Terrain.FLOOR` | `#3A4048` | Flat iso diamond, faint grid seam, slight inner shade |
| **Wall** (blocking, anchored) | `Terrain.WALL` | `#22262C` | Tall iso block, hard top highlight `#4A525C`, no grid seam |
| **Half cover** | object `coverValue:1` | `#6E7B66` (olive) | Diamond + **low chevron bar** on the protected edge (½-height) |
| **Full cover** | object `coverValue:2` | `#566B4F` (deep olive) | Diamond + **full upright slab** glyph; casts a small shadow |
| **Spawn / deploy tile** | layout meta | `#2E6E9E` (player) / `#9E3A2E` (enemy) | Diamond outline only, dashed, faction-tinted |

### 3.2 Hazard tiles (maps to `Hazard` enum) — *terrain that hurts*

| Hazard | Enum | Hex | Icon / shape language |
|---|---|---|---|
| **Gap / coupling** (eject) | `Hazard.GAP` | `#0A0C0F` (void) | Black diamond, ragged inner edge, ⚠ down-arrow into dark |
| **Furnace** (open fire pit) | `Hazard.FURNACE` | `#FF7A18` core / `#7A2400` rim | Diamond with radial glow + flame tongues; pulses |
| **Live rail** (electrified) | `Hazard.RAIL_LIVE` | `#FFE14D` on `#2A2A12` | Diamond with a **zigzag bolt** band; arcing dots |
| **Piston** (crush) | `Hazard.PISTON` | `#9AA3AD` steel / `#FF3B3B` warn | Diamond + **down-slam arrows** + red active ring when armed |

### 3.3 Hazard tile *layers* (maps to `L_*` tile-status bitflags) — *overlays on any tile*

These tint/overlay the tile they sit on; they stack (water + electrified = the marquee combo).

| Layer | Bitflag | Hex | Overlay treatment |
|---|---|---|---|
| **Water / flood** | `L_WATER` | `#2E8BC0` @ 60% | Translucent blue wash, animated ripple line, lighter foam edge `#7EC8E3` |
| **Fire** | `L_FIRE` | `#FF5A1F` @ 75% | Flame licks rising off tile, ember particles, orange tile glow |
| **Electrified** | `L_ELECTRIFIED` | `#FFE14D` @ 80% | Cyan-white arc lattice `#E8FBFF` crackling across connected water |
| **Debris** | `L_DEBRIS` | `#7A6E5A` @ 70% | Scattered chunky rubble glyphs; marks difficult terrain |

> **Stacking read:** water (blue) + electrified (yellow arcs over it) is THE signature
> visual — make the arc lattice unmistakable over the blue wash. Fire over water should
> visibly *fight* (steam puffs) per GDD §6.6.

### 3.4 Status effects (maps to `S_*` unit-status bitflags, GDD §5.5)

Status icons are small badges that **ring the unit token** (clock positions). Each has a
unique **color + shape** so a stack of 3 still reads. Authored at a `24 × 24` viewBox,
drawn at ~20px (§6.1).

| Status | Bitflag | Hex | Icon shape |
|---|---|---|---|
| **Prone** | `S_PRONE` | `#C8A24A` (amber-tan) | Horizontal figure / down-chevron `⌄` |
| **Stunned** | `S_STUNNED` | `#F2D14E` (yellow) | Spiral / orbiting-stars ring `✷` |
| **Soaked** | `S_SOAKED` | `#2E8BC0` (water blue) | Droplet `💧`-glyph (teardrop) |
| **Burning** | `S_BURNING` | `#FF5A1F` (fire orange) | Flame tongue `🔥`-glyph (triple-tongue) |
| **Shocked** | `S_SHOCKED` | `#FFE14D` (electric yellow) | Lightning bolt `⚡` (zigzag) |
| **Poisoned** | `S_POISONED` | `#7FBF3F` (sick green) | Skull-bubble / trefoil `☣` |
| **Blinded** | `S_BLINDED` | `#C9CDD2` (fog grey) | Crossed-eye / hatched circle `⊘` |
| **Chilled** | `S_CHILLED` | `#8FD4E8` (pale ice) | Single snowflake `❄` (thin) |
| **Frozen** | `S_FROZEN` | `#BFEFff` (frost white-blue) | Solid ice cube / thick snowflake `❄` filled |
| **Bleeding (Downed)** | `S_DOWNED` (+`S_BLEEDING`) | `#C0354A` (blood red) | Red cross / dripping-drop on a downed figure |
| **Suppressed** | `S_SUPPRESSED` | `#B07A2E` (dull orange-brown) | Down-arrows pinning `⤓` / pinned-bracket |
| **Buried** | `S_BURIED` | `#8A7C64` (debris brown) | Head over a rubble/snow mound (E1.6) |
| **Netted** | `S_NETTED` | `#B98A4A` (rope tan) | Crosshatch net mesh (§12) |
| **Overwatch** | `R_OVERWATCH` (render-only, #21) | `#3FC6D4` (data cyan) | Watching eye (lens + pupil) — a hold tell, not a DoT |

> **Family logic** (so the palette is learnable, not arbitrary):
> - **Water family** = blue (`Soaked`) → arcs to **electric yellow** (`Shocked`).
> - **Fire family** = orange (`Burning`).
> - **Cold family** = pale-ice → frost-white (`Chilled` → `Frozen`), the snow/ice biome ramp.
> - **Disable family** = yellow `Stunned`, brown `Suppressed`, amber `Prone` — "can't act / can't move well."
> - **Toxic** = green (`Poisoned`); **Vision** = grey (`Blinded`); **Death window** = blood red (`Downed`).

### 3.5 Faction tinting (maps to `Faction` enum)

Faction is a **token ring + base tint**; the archetype/enemy glyph lives inside it.

| Faction | Enum | Ring hex | Read |
|---|---|---|---|
| **Player** | `Faction.PLAYER` | `#2EA7E0` (operator cyan-blue) | "Ours." Cool blue ring + soft inner glow |
| **Enemy** | `Faction.ENEMY` | `#E0432E` (hostile red) | "Threat." Red ring |
| **Neutral** | `Faction.NEUTRAL` | `#E0B72E` (civilian/animal amber) | "Don't have to fight." Amber ring (bourgeois, recruits, neutral creatures — Sub-Spec E1.7) |
| **Object** | `Faction.OBJECT` | `#9AA3AD` (inert steel grey) | "It's furniture." Grey, no glow; integrity pips when damageable |

> **Cold-open ambush tell (E1.7):** an *Unaware* enemy uses the red ring but **dimmed +
> a `Zzz`/eye-closed mote** so the operator reads the free first-strike opening.

### 3.6 Cover & flank indicators (GDD §16) — *not a status, a UI overlay*

- **Half cover available**: half-shield glyph, olive `#6E7B66`, on the protected facing.
- **Full cover available**: full-shield glyph, deep olive `#566B4F`.
- **Flanked / exposed**: red broken-shield `#FF3B3B` — "your shot ignores their cover" /
  "they ignore yours." This is the §6.8 physics→damage payoff made visible.

---

## 4. The 5-section palette escalation (GDD §8.1)

Each section re-skins **surfaces, ambient light, and chrome grain** — NOT the §3 gameplay
color language. Front-to-back: grimy/dark → sterile/bright/metallic. Each palette is 5
named swatches: `bg` (deepest), `surface` (floors/walls base), `accent` (section signature),
`light` (highlight/rim), `glow` (the section's emissive/signal tint).

### Section 1 — THE TAIL  *(dark, cramped, scavenged · tutorial)*
> Rust, soot, scrap-metal, a single failing worklight. Claustrophobic.

| Swatch | Hex |
|---|---|
| `tail.bg` | `#0C0A08` |
| `tail.surface` | `#2A2420` |
| `tail.accent` | `#7A4A2C` (rust) |
| `tail.light` | `#B8895A` (worklight amber) |
| `tail.glow` | `#C24A2A` (ember red) |

### Section 2 — THIRD CLASS  *(industrial, crowded, utilitarian · rising)*
> Greasy steel, hazard stripes, pipework, fluorescent buzz. Functional, grimy.

| Swatch | Hex |
|---|---|
| `third.bg` | `#10130F` |
| `third.surface` | `#33392F` |
| `third.accent` | `#C2A03A` (hazard yellow) |
| `third.light` | `#8FA08A` (sickly fluoro green-grey) |
| `third.glow` | `#D8C24A` |

### Section 3 — SECOND CLASS  *(services, gardens, aquaria · flood-rich · mid)*
> Verdigris, planted green, glass and water. The first beauty — wet, alive, breakable.

| Swatch | Hex |
|---|---|
| `second.bg` | `#0A1412` |
| `second.surface` | `#27433C` |
| `second.accent` | `#2E8BC0` (aquarium blue) |
| `second.light` | `#5FB89A` (greenhouse green) |
| `second.glow` | `#7EC8E3` (tank light) |

### Section 4 — FIRST CLASS  *(opulent, sterile, well-guarded · hard)*
> Marble, gold leaf, deep velvet, cold chandelier light. Grotesque luxury (Sub-Spec E peaks here).

| Swatch | Hex |
|---|---|
| `first.bg` | `#14100A` |
| `first.surface` | `#3A332A` (marble-shadow taupe) |
| `first.accent` | `#C9A24A` (gold leaf) |
| `first.light` | `#EFE6D2` (cream marble) |
| `first.glow` | `#8E1F3A` (velvet crimson) |

### Section 5 — THE ENGINE  *(metal, automated, hostile architecture · finale)*
> Sterile white-blue steel, signal cyan, machine-cold. Inhuman, bright, clinical.

| Swatch | Hex |
|---|---|
| `engine.bg` | `#0A0F14` |
| `engine.surface` | `#2C3640` (cold steel) |
| `engine.accent` | `#3FC6D4` (signal cyan) |
| `engine.light` | `#E6F2F5` (clinical white) |
| `engine.glow` | `#FF3B3B` (alarm red — the room is the antagonist) |

> **Escalation summary:** saturation of *threat* (glow) walks warm→cold (ember red →
> hazard yellow → tank blue → velvet crimson → alarm red) while *surfaces* go dirty→clean.
> Brightness rises front-to-back; the Tail is the only section that's genuinely dark.

> **Renderer mechanism (implemented):** section re-skins land as **per-section texture
> variants** — a terrain stem plus `__s<N>` (N = 1..5 in the order above), e.g.
> `tile_floor__s3.png` / `tile_wall__s3.png`. `render/car_view.gd` prefers the variant for the
> car's `section` and falls back to the plain stem, so the 5-variant floor/wall sets the
> tiles/terrain sheet commissions can ship incrementally (§8.1). Until variants ship, every
> section renders the neutral set.

---

## 5. CRT / scanline & UI-chrome treatment notes

For the renderer engineer (post-process layer, lives in `render/`):

- **Scanlines:** screen-space, 1px dark line every 3px, ~40–55% opacity. A separate
  `scanline_strength` per section (heavier Tail, lighter Engine).
- **Vignette:** soft radial darken, ~12% at corners. Constant.
- **Grain:** animated noise, additive, low amplitude. `grain_strength` per section
  (Tail high, Engine low).
- **Chromatic aberration:** baseline near-zero; spikes for 2–4 frames on `Ev.SHOCK`,
  `Ev.OBJECT_BREAK`, `Ev.FLOOD_TILE`, `Ev.COLLAPSE`, `Ev.IMPACT_WALL` (big hits).
- **Scan-tear glitch:** horizontal slice offset on the same big events; tie to the
  resolver event stream (`core` emits `Ev.*`, render reacts) — never random.
- **Chrome panels:** `#0B0E11` @ ~85% with a 1px `#1C2630` border and a 2px inset top
  highlight `#243240`; corner ticks (camera-UI bracket marks) on each panel.
- **Type:** monospace throughout. Amber `#FFB000` primary, cyan `#3FC6D4` data, red
  `#FF3B3B` alerts, dim `#5A6470` for inactive.

---

## 6. Status-icon & hazard-telegraph conventions

### 6.1 Status icons
- **Placement:** badges ring the token; first status at 1-o'clock, filling clockwise.
  Max 3 visible, then a `+N` chip.
- **Size:** authored at a `24 × 24` viewBox, drawn at ~20px; 2px dark outline for scanline
  legibility, the §3.4 fill color, a white inner glyph.
- **Animation:** Burning/Shocked pulse; Frozen has a static frost sheen; Downed blinks
  (urgency — the revive clock).
- **Anti-collision:** each status owns BOTH a color and a distinct silhouette so a
  color-blind player (or a grainy feed) still distinguishes them. Never rely on hue alone.

### 6.2 Hazard telegraphs (GDD §16, Sub-Spec D — "one turn ahead")
- **Cycling traps** (fire vent / laser / piston / plate): show a **next-state ghost** on
  the tiles that will be dangerous next turn — a pulsing outline in that hazard's §3.2 color
  + a small countdown pip. Armed = solid; idle = hollow.
- **Spreading fronts** (fire / gas / water): draw the **predicted spread edge** as a dashed
  advancing line in the hazard's color, one tile ahead of the current front.
- **Physics preview (THE big one, §6.7):** the committed-on-confirm outcome overlay —
  - trajectory: dotted line along the travel vector (faction-tinted),
  - collision points: small impact-star markers,
  - end positions: a translucent **ghost token** where each entity lands,
  - results: tiny inline icons at the ghost (Prone, Soaked, break, eject),
  - spawned hazards: faded flood/fire/debris fill where they'll appear.
  Preview elements are ~50% opacity and never use the alarm-red reserved for live danger,
  so "what *will* happen" never reads as "what *is* happening."

---

## 7. Token & tile sizing (binding for placeholders + renderer — see §8)

- **Iso tile:** authored in a **2:1 diamond**, footprint `128 × 64` px (logical). Floor art
  fills the diamond; walls/tall objects extend upward beyond the top vertex. The renderer
  draws tile art **bottom-anchored** to the diamond's bottom vertex at a fixed 128-logical
  width, so art taller than the 2:1 aspect grows UP past the top vertex — tall wall art works.
- **Unit / enemy token:** fits a `96 × 96` box, centered on the tile, baseline at the
  diamond's center. Faction ring is the outer ~88px circle; archetype glyph centered inside.
- **Status badge:** `24 × 24` viewBox, drawn at ~20px, ringed at radius ~48 from token center.
- **Object token:** same `96 × 96` box as units; **mass is expressed by silhouette scale
  WITHIN the box** — Light fills ~64px of it, Medium ~80px, Heavy nearly the full 96 (matching
  how the 19 shipped `obj_*` placeholders are drawn). Anchored/oversize overflow beyond the
  box is deferred until a per-object logical-size field exists on the object defs.
- **Logical vs pixel size (binding):** the renderer draws every tile/token into these fixed
  LOGICAL rects regardless of the texture's native resolution (`car_view.gd`), so deliverables
  may ship at 2x (§8) with zero layout change.
- **Naming:** all-lowercase, snake_case, category prefix (`tile_`, `unit_`, `enemy_`,
  `obj_`, `status_`, `ui_`). One concept per file. SVG `viewBox` declared (§8).

---

## 8. Placeholder conventions (for `assets/placeholders/`)

- **Format:** standalone **SVG** only (text, diffable, Godot-importable). No binary, no
  external refs, no embedded rasters.
- **Color:** every fill is a literal hex from the §3 contract or a §4 section swatch — no
  off-palette colors. (Placeholders intentionally use the *gameplay* language, not section
  re-skins, so they read identically in any car.)
- **viewBox:** tiles `0 0 128 64`; tokens `0 0 96 96`; status icons `0 0 24 24`; the UI
  mock `0 0 1280 720`. Origin top-left.
- **Style:** flat fills, 1–2px dark outlines (`#0B0E11`), one rim highlight max. No
  gradients except where a hazard glow genuinely needs it (furnace, water). Keep node
  counts low — these are stand-ins, not final art.
- **Replaceability:** filenames and viewBoxes are the contract. A texture artist swaps the
  SVG/PNG behind the same filename + footprint and the game keeps working. That is the whole
  point of doing the bible first.

### 8.1 Final-art deliverables (the drop-in contract — implemented in `render/car_view.gd`)

- **Where:** deliver `assets/final/<stem>.png` — same stem as the placeholder it replaces.
  The renderer probes `assets/final/<stem>.png` → `assets/final/<stem>.svg` →
  `assets/placeholders/<stem>.png` → `assets/placeholders/<stem>.svg` and uses the first that
  loads, so final art lands file-by-file and deleting a file reverts to the placeholder.
- **Resolution:** 2x logical — tiles `256 × 128`, tokens `192 × 192`, status icons `48 × 48`.
  The renderer scales into fixed logical rects (§7), so 2x is free crispness, not a layout risk.
- **Format:** straight-alpha PNG. **No baked scanlines/grain** (§2 — post-pass only, so the
  CRT treatment survives every texture swap).
- **Tokens keep the baked faction ring** at the placeholder's ~88px-of-96 diameter (the
  renderer ALSO draws a procedural ring — matching diameters is what avoids a double-ring look).
- **Tall art:** tile deliverables taller than 2:1 (walls, tall anchored objects) are allowed —
  keep the diamond footprint in the bottom `2:1` slice; the overflow grows upward (§7).
- **Section variants (§4):** terrain surfaces may ship per-section as `<stem>__s<N>` (N = 1..5,
  e.g. `tile_floor__s2.png`, `tile_wall__s4.png`); a missing variant falls back to the plain stem.
- **After any file lands:** run `godot --headless --path . --import` once, then
  `tests/tex_coverage_smoke.gd` — a file without its generated `.import` sidecar is invisible
  to the game and the suite fails loud on it.
- **Do not produce** the reference-only files (`tile_water`, `tile_fire`, `tile_electrified`,
  `ui_ops_console_frame`) — those visuals are renderer-drawn at runtime by design.
- The full commission list (every stem, size, anchor, sheet link, status) lives in
  **`docs/art/ART_SHOPPING_LIST.md`** — hand that file to the artist/image-gen pass.
