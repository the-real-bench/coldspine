# COLDSPINE — Final-Art Shopping List

> The single consolidated commission list for the final-art pass. Hand this file (plus
> `ART_BIBLE.md` and `DESIGN_SHEETS/`) to an artist or an image-gen pass as-is.
> Counts verified against `assets/placeholders/` (79 SVGs: 18 tiles · 5 units · 16 enemies ·
> 19 objects · 14 status · 1 UI · **5 draft portraits · 1 econ flavor** [Wave-5 presentation layer])
> and the renderer registries in `render/car_view.gd`.

## How to deliver (the drop-in contract — `ART_BIBLE.md` §8.1)

- **One PNG per row below**, named `assets/final/<file>` (same stem as the placeholder it
  replaces). The game prefers `assets/final/<stem>.png` over the placeholder automatically;
  deleting a file reverts to the placeholder. No code changes per file.
- **Resolution: 2x logical** — tiles `256×128`, tokens `192×192`, status icons `48×48`.
  The renderer scales art into fixed logical rects, so 2x is free crispness.
- Straight-alpha PNG. **No baked scanlines/grain** (the CRT look is a post pass).
- Unit/enemy tokens **keep the baked faction ring** at the placeholder's diameter (~88px of
  the 96 logical box) — the renderer draws its own ring at the same radius.
- Tile art may be **taller than 2:1** (walls): keep the diamond footprint in the bottom
  2:1 slice; overflow grows upward past the top vertex.
- After every drop: `godot --headless --path . --import`, then run
  `tests/tex_coverage_smoke.gd` (fails loud if a file didn't import).

Anchors used below: **tile** = bottom-anchored to the diamond's bottom vertex, 128-logical
wide (extra height grows up) · **token** = centered on the tile, 96-logical box ·
**badge** = centered, 24-logical viewBox drawn ~20px.

---

## 1. Terrain & hazard tiles (18 files, 15 to commission) — 2:1 diamond, deliver `256×128`

Sheet: [`DESIGN_SHEETS/tiles_terrain.md`](DESIGN_SHEETS/tiles_terrain.md) — per-file specs + prompts.

| Deliver as | Logical size | Anchor | Sheet | Status |
|---|---|---|---|---|
| `tile_floor.png` | 128×64 | tile | tiles_terrain.md | has sheet |
| `tile_wall.png` | 128×64+ (may grow up) | tile | tiles_terrain.md | has sheet |
| `tile_cover_half.png` | 128×64 | tile | tiles_terrain.md | has sheet |
| `tile_cover_full.png` | 128×64+ | tile | tiles_terrain.md | has sheet |
| `tile_gap.png` | 128×64 | tile | tiles_terrain.md | has sheet |
| `tile_furnace.png` | 128×64 | tile | tiles_terrain.md | has sheet |
| `tile_rail.png` | 128×64 | tile | tiles_terrain.md | has sheet |
| `tile_piston.png` | 128×64 | tile | tiles_terrain.md | has sheet |
| `tile_vent.png` | 128×64 | tile | tiles_terrain.md | has sheet |
| `tile_laser.png` | 128×64 | tile | tiles_terrain.md | has sheet |
| `tile_plate.png` | 128×64 | tile | tiles_terrain.md | has sheet |
| `tile_steam.png` | 128×64 | tile | tiles_terrain.md | has sheet |
| `tile_conveyor.png` | 128×64 | tile | tiles_terrain.md | has sheet |
| `tile_laser_sweep.png` | 128×64 | tile | tiles_terrain.md | has sheet |
| `tile_scald.png` | 128×64 | tile | tiles_terrain.md | has sheet |
| ~~`tile_water`~~ | — | — | tiles_terrain.md | **DO NOT COMMISSION** — reference-only, water layer is a runtime overlay |
| ~~`tile_fire`~~ | — | — | tiles_terrain.md | **DO NOT COMMISSION** — reference-only |
| ~~`tile_electrified`~~ | — | — | tiles_terrain.md | **DO NOT COMMISSION** — reference-only |

### 1b. Section-palette floor/wall variants (10 files) — the §4 escalation, per-section surfaces

Same specs as `tile_floor`/`tile_wall`; palettes + the 5-variant image-gen prompt are in
`tiles_terrain.md` ("Floor + wall set (per section)") and `ART_BIBLE.md` §4. The renderer
prefers the car's section variant and falls back to the plain stem, so these can ship in any
order, one file at a time.

| Deliver as | Section / palette | Status |
|---|---|---|
| `tile_floor__s1.png` / `tile_wall__s1.png` | 1 THE TAIL — rusty scrap metal `#2A2420`/`#7A4A2C` | has sheet |
| `tile_floor__s2.png` / `tile_wall__s2.png` | 2 THIRD CLASS — industrial deckplate `#33392F`/`#C2A03A` | has sheet |
| `tile_floor__s3.png` / `tile_wall__s3.png` | 3 SECOND CLASS — verdigris/wet tile `#27433C`/`#2E8BC0` | has sheet |
| `tile_floor__s4.png` / `tile_wall__s4.png` | 4 FIRST CLASS — marble + gold inlay `#3A332A`/`#C9A24A` | has sheet |
| `tile_floor__s5.png` / `tile_wall__s5.png` | 5 THE ENGINE — clinical steel + cyan `#2C3640`/`#3FC6D4` | has sheet |

## 2. Player unit tokens (5 files) — deliver `192×192`

Sheet: [`DESIGN_SHEETS/unit_archetypes.md`](DESIGN_SHEETS/unit_archetypes.md). Player ring `#2EA7E0`.

| Deliver as | Serves (content id) | Logical | Anchor | Status |
|---|---|---|---|---|
| `unit_bruiser.png` | `bruiser` (+ generic player fallback) | 96×96 | token | has sheet |
| `unit_marksman.png` | `marksman` | 96×96 | token | has sheet |
| `unit_saboteur.png` | `saboteur` | 96×96 | token | has sheet |
| `unit_steward.png` | `steward` | 96×96 | token | has sheet |
| `unit_firebrand.png` | `firebrand` | 96×96 | token | has sheet |

### 2b. Draft / character portraits (5 files) — the presentation art layer (W5-1) — deliver `280×360`

A NEW, LARGER character-art layer (NOT the 64px board token above) shown where the player CHOOSES
people: the `DRAFT_CANDIDATE_CARD` portrait region, the SANCTUARY recruit dossier, and the LEVEL-UP
header. Rendered on-screen in `app/screens/run_screens.gd` (`_portrait_frame` / `_portrait_texture`),
gated `not headless`. Drop-in contract mirrors the tokens: `assets/final/portrait_<archetype>.png`
wins over the placeholder, `.png` over `.svg` — one PNG per row, no code change.

- **Logical rect:** the card seats it at **140×168**; the recruit dossier at **130×160**; the level-up
  header at **120×150**. All scale `KEEP_ASPECT_CENTERED` into the rect, so deliver at **2x (280×360)**
  portrait aspect and it reads crisp everywhere.
- **Framing:** a chest-up character bust, front-on, filling the frame. Straight-alpha PNG, **no baked
  ring** (the card draws the faction ring: `FAC_PLAYER #2EA7E0` on the draft/level-up, `FAC_NEUTRAL
  #E0B72E` on the recruit dossier) and **no baked scanlines/grain** (CRT is a post pass).
- Match each archetype's board-token accent (unit_archetypes.md): bruiser rust `#C26A2A`, marksman
  green `#5FA86A`, saboteur electric-yellow `#FFE14D`, steward teal `#7EC8E3`, firebrand crimson
  `#FF5A1F`. Missing archetype → the loader falls back to `portrait_bruiser` (generic player).

| Deliver as | Serves (archetype id) | Logical | Anchor | Status |
|---|---|---|---|---|
| `portrait_bruiser.png` | `bruiser` (+ generic player fallback) | 140×168 | portrait bust | placeholder shipped |
| `portrait_marksman.png` | `marksman` | 140×168 | portrait bust | placeholder shipped |
| `portrait_saboteur.png` | `saboteur` | 140×168 | portrait bust | placeholder shipped |
| `portrait_steward.png` | `steward` | 140×168 | portrait bust | placeholder shipped |
| `portrait_firebrand.png` | `firebrand` | 140×168 | portrait bust | placeholder shipped |

### 2c. Econ-screen car / flavor art (1 generic + up to 5 optional per-car) — deliver `1024×344`

Fills the empty LEFT half of the SHOP / WORKSHOP / BOURGEOIS / EVENT / REST takeovers (W5-15) with a
framed "surveillance feed into the current car" so the screen never reads half-empty. Built in
`run_screens.gd::_build_econ_surface` (a 512×172 framed region; the car NAME is overlaid in code).
Drop-in: a per-screen `assets/final/car_<screen>.png` (`car_shop`/`car_workshop`/`car_bourgeois`/
`car_event`/`car_rest`) wins; else the generic `car_flavor` placeholder shows for all five.

| Deliver as | Serves | Logical | Anchor | Status |
|---|---|---|---|---|
| `car_flavor.png` | generic econ-car feed (all 5 fallback) | 240×140 (in a 512×172 frame) | left-inset | placeholder shipped |
| `car_shop.png` … `car_rest.png` | per-car feed (optional, override the generic) | 240×140 | left-inset | optional, no sheet |

## 3. Enemy + boss tokens (16 files) — deliver `192×192`

Sheet: [`DESIGN_SHEETS/enemies.md`](DESIGN_SHEETS/enemies.md). Enemy ring `#E0432E`; the
silhouette must telegraph the physics counter. NOTE: the sheet's old "DRONE" prompt line is
retired — no drone asset exists or is wanted.

| Deliver as | Serves (content id) | Logical | Anchor | Status |
|---|---|---|---|---|
| `enemy_truncheon.png` | `truncheon_guard` (+ generic enemy fallback) | 96×96 | token | has sheet |
| `enemy_riot_shield.png` | `riot_shield` | 96×96 | token | has sheet |
| `enemy_net_gunner.png` | `net_gunner` | 96×96 | token | has sheet |
| `enemy_enforcer.png` | `enforcer` | 96×96 | token | has sheet |
| `enemy_hound.png` | `hound` | 96×96 | token | has sheet |
| `enemy_sniper.png` | `sniper` | 96×96 | token | has sheet |
| `enemy_drone_op.png` | `drone_operator` | 96×96 | token | has sheet |
| `enemy_security_robot.png` | `security_robot` | 96×96 | token | has sheet |
| `enemy_sentry_turret.png` | `sentry_turret` | 96×96 | token | has sheet |
| `enemy_captain.png` | generic/future captain fallback | 96×96 | token | has sheet |
| `enemy_captain_tail_warden.png` | `captain_tail_warden` (S1, soak key) | 96×96 | token | has sheet |
| `enemy_captain_foreman.png` | `captain_foreman` (S2, buff key) | 96×96 | token | has sheet |
| `enemy_captain_gardener.png` | `captain_gardener` (S3, gas key) | 96×96 | token | has sheet |
| `enemy_captain_majordomo.png` | `captain_majordomo` (S4, cover key) | 96×96 | token | has sheet |
| `enemy_captain_chief.png` | `captain_chief_of_security` (S5, soak key) | 96×96 | token | has sheet |
| `enemy_conductor.png` | `the_conductor` (finale boss) | 96×96 | token | has sheet |

## 4. Interactive object tokens (19 files) — deliver `192×192`

Sheet: [`DESIGN_SHEETS/interactive_objects.md`](DESIGN_SHEETS/interactive_objects.md). Object
tint `#9AA3AD`, no glow; mass reads via silhouette scale WITHIN the 96 box (§7).

| Deliver as | Serves (content ids) | Logical | Anchor | Status |
|---|---|---|---|---|
| `obj_fish_tank.png` | `fish_tank_large`, `fish_tank_small`, `tank` | 96×96 | token | has sheet |
| `obj_junction.png` | `junction`, `junction_box` | 96×96 | token | has sheet |
| `obj_barrel.png` | `barrel`, `barrel_explosive`, `oxygen_tank`, `alcohol_barrel` | 96×96 | token | has sheet |
| `obj_crate.png` | `crate`, `locker` (+ generic object fallback) | 96×96 | token | has sheet |
| `obj_table.png` | `table`, `serving_cart`, `bench`, `chair` | 96×96 | token | has sheet |
| `obj_glass_partition.png` | `glass_partition` | 96×96 | token | has sheet |
| `obj_coolant_tank.png` | `coolant_tank` | 96×96 | token | has sheet |
| `obj_water_main.png` | `water_main` | 96×96 | token | has sheet |
| `obj_gas_main.png` | `gas_main` | 96×96 | token | has sheet |
| `obj_weight_rack.png` | `weight_rack` | 96×96 | token | has sheet |
| `obj_marble_statue.png` | `marble_statue` | 96×96 | token | has sheet |
| `obj_chandelier.png` | `chandelier` | 96×96 | token | has sheet |
| `obj_tree.png` | `tree` | 96×96 | token | has sheet |
| `obj_hedge_wall.png` | `hedge_wall` | 96×96 | token | has sheet |
| `obj_hedge_sculpture.png` | `hedge_sculpture` | 96×96 | token | has sheet |
| `obj_bookshelf.png` | `bookshelf` | 96×96 | token | has sheet |
| `obj_pottery_vase.png` | `pottery_vase` | 96×96 | token | has sheet |
| `obj_planter.png` | `planter` | 96×96 | token | has sheet |
| `obj_thin_ice.png` | `thin_ice` | 96×96 | token | has sheet |

## 5. Status icons (14 files) — deliver `48×48`

Sheet: [`DESIGN_SHEETS/status_icons.md`](DESIGN_SHEETS/status_icons.md). **Color AND shape are
both load-bearing** (colorblind rule, §6.1). Registered in `car_view.gd::STATUS_TEX`.

| Deliver as | Serves (flag) | Logical | Anchor | Status |
|---|---|---|---|---|
| `status_prone.png` | `S_PRONE` | 24×24 | badge | has sheet |
| `status_stunned.png` | `S_STUNNED` | 24×24 | badge | has sheet |
| `status_soaked.png` | `S_SOAKED` | 24×24 | badge | has sheet |
| `status_burning.png` | `S_BURNING` | 24×24 | badge | has sheet |
| `status_shocked.png` | `S_SHOCKED` | 24×24 | badge | has sheet |
| `status_poisoned.png` | `S_POISONED` | 24×24 | badge | has sheet |
| `status_blinded.png` | `S_BLINDED` | 24×24 | badge | has sheet |
| `status_chilled.png` | `S_CHILLED` | 24×24 | badge | has sheet |
| `status_frozen.png` | `S_FROZEN` | 24×24 | badge | has sheet |
| `status_bleeding.png` | `S_DOWNED` + `S_BLEEDING` (shared) | 24×24 | badge | has sheet |
| `status_suppressed.png` | `S_SUPPRESSED` | 24×24 | badge | has sheet |
| `status_buried.png` | `S_BURIED` | 24×24 | badge | has sheet |
| `status_netted.png` | `S_NETTED` | 24×24 | badge | has sheet |
| `status_overwatch.png` | `R_OVERWATCH` (render-only tell) | 24×24 | badge | has sheet |

## 6. UI (1 file — do not commission)

| File | Status |
|---|---|
| ~~`ui_ops_console_frame`~~ | **DO NOT COMMISSION** — reference-only mock; the OpsHUD is code-built (`render/ops_hud.gd`, per §5) |

---

## 7. Non-token art that STAYS PROCEDURAL (do NOT commission)

Renderer-drawn at runtime by contract (`DESIGN_SHEETS/hazards_vfx.md`); commissioning these
would waste spend:

- Tile status-layer washes: water / fire / debris / electrify arc lattice (`car_view.gd::_draw_tile_layers`).
- Faction rings + selection glow (tokens also bake a ring — final token art must keep the
  baked ring at the placeholder's ~88px diameter or the double-ring look breaks).
- Physics-preview ghosts, dotted trajectories, destination rings (`preview_ghost.gd`).
- Targeting rings, cover/flank shields, to-hit % tags (#16 overlay).
- Combat juice: glitch-tear, redout, "CAR CLEAR" stamp.
- All OpsHUD chrome panels/buttons/meters (code-built, §5).
- Biome ambience/backdrops: currently the §4 story is carried by the per-section floor/wall
  variants (§1b above) — no separate backdrop paintings are commissioned for the prototype.

## 8. Genuinely missing assets (no file + no sheet yet)

| Item | Spec | Status |
|---|---|---|
| **Monospace terminal font** | §5 mandates monospace throughout; every `draw_string` currently uses the non-mono engine fallback. Pick an OFL face (JetBrains Mono / IBM Plex Mono) — the single cheapest whole-game look upgrade. Not drawn art. | needs sheet (license pick, no art) |
| **Application icon** | ✅ DONE (W7-7 corrected a stale "no `config/icon`" claim) — `project.godot` carries `config/icon="res://assets/icon.svg"` (+ `assets/icon.png` / `assets/icon_192.png` for Android); the stock Godot icon no longer ships. COLDSPINE mark: amber-on-near-black, CRT/spine motif. A full export-size raster set (iOS/Windows) is optional polish. | delivered (final polish optional) |
| **Boot splash** | W7-4 — a branded `boot_splash` (near-black FRAME_BG `#0B0E11`, app mark centered) now replaces the stock Godot-logo splash (`project.godot` `[application] boot_splash/*`). Placeholder = the app icon (`assets/icon.png`); **swap `boot_splash/image` for a 1280×720 boot frame** (train exterior / ops-console cold open) when it lands — same key art as "Title / boot key art" below. | placeholder in (icon); final frame needed |
| **Title / boot key art** | `menu.tscn` is text-only. One 1280×720 key image (train exterior / ops-console cold open) — doubles as the W7-4 boot-splash frame above. Optional for prototype, first thing a player sees. | needs sheet |
| **5 ending tone cards + Memorial backdrop** | The 5-tone endings + Memorial screen are text-only. 5 + 1 images, 1280×720. Optional. | needs sheet |
| **Neutral-faction token (`unit_neutral`)** | Content authors neutral spawns (setpiece_forest, `spawn_ally` modifier) but no loader consumes them yet; if wired, a neutral unit would today render the RED enemy glyph under an amber ring — actively misleading. One 96×96 amber-ring civilian token, **contingent on the neutral-spawn wiring decision**. | needs sheet + owner decision |
| **CRT post shader** | §2/§5 screen-space scanline+grain+vignette+chroma shader with per-section strength — a `render/` CODE task, not art. Current approximation is a ColorRect. | code task |
| **Audio** | Architecture now BUILT (bus layout + AudioDirector autoload + total event→slot map). Commission the sound files against the drop-in contract in §9 below. | ready to commission (see §9) |

---

## 9. AUDIO — the drop-in sound pipeline (release-readiness #4)

> Audio is built the **same way as art**: a name→file manifest + one event-driven choke point,
> so a real sound file dropped at the documented path Just Works with **zero code changes**. The
> engine (bus layout + `AudioDirector` autoload) is done; only the sound files are missing. Until a
> file is present every cue is a **silent no-op** — nothing breaks, the game just plays quiet.

### 9.1 How to deliver (the drop-in contract — mirrors §8.1 for textures)

- **One file per slot below.** Drop it at the path in `content/audio_map.json` (the audio manifest,
  the analog of `assets/placeholders/MANIFEST.md`):
  - SFX  → `res://audio/sfx/<slot>.ogg`
  - UI   → `res://audio/ui/<slot>.ogg`
  - Music→ `res://audio/music/<track>.ogg`
- **Format:** `.ogg` Vorbis (looping tracks: set the loop in the `.import` after first import).
  Short SFX are one-shots; the SFX bus has an 8-voice pool so overlapping shots/impacts don't cut.
- **No code changes.** `AudioDirector` loads `content/audio_map.json` at boot; a present file plays,
  a missing one is silent. To rename/move a slot's file, edit only the manifest path.
- **Buses:** `default_bus_layout.tres` — `Master → Music / SFX / UI`. The Settings **SFX volume**
  and **Music volume** sliders drive the SFX/Music bus dB live (0 → muted, 100 → 0 dB). A `ui_volume`
  key is reserved for a future UI-volume slider.
- **Headless is always silent** (the director no-ops without a display), so the test suites stay
  byte-identical. After adding files, sanity-check with `tests/audio_smoke.gd`.

### 9.2 Event → SFX slot map (the commission list)

Every emitted game event (`core/sim_enums.gd::Ev`) maps to a named SFX slot in
`app/audio_director.gd::EVENT_SFX`; `tests/audio_smoke.gd` proves the map is **total** (no event is
ever unmapped). Distinct slots (commission one sound each — reuse a file across rows by pointing
multiple manifest entries at it):

| Slot | Fired by (events) | Feel |
|---|---|---|
| `step` / `stand` | MOVE, MOVE_STEP / STAND_UP | footfall on metal deck / grunt up |
| `belt` / `slide` / `dig_out` / `bury` | BELT_DRIFT / SLOPE_SLIDE / DIG_OUT / BURY | conveyor drag / scrape / snow dig / muffled thud |
| `gunshot` / `impact` / `ricochet` | ATTACK_SHOOT / HIT / MISS | shot / body hit / ping-off-metal |
| `slam` / `billiards` / `crush` / `topple` | IMPACT_WALL / COLLIDE_BODY / CRUSH / TOPPLE | wall slam / body-into-body / crush / heavy fall |
| `eject` / `avalanche` | EJECT / AVALANCHE | wind-whoosh off the train / snow roar |
| `shove_resisted` | SHOVE_RESISTED | braced grunt, no displacement |
| `crack` / `shatter` | OBJECT_DAMAGED / OBJECT_BREAK | material crack / glass-crate shatter |
| `water` / `zap` | FLOOD_TILE / SHOCK | water surge / electric arc |
| `ignite` / `boom` / `fire` / `fire_out` | IGNITE, (CHARGE_DETONATED, EXPLOSION→`boom`) / FIRE_SPREAD / FIRE_OUT | whoomph / explosion / crackle / sizzle-out |
| `burn` / `scald` / `poison` | BURN_TICK / SCALD / POISON_TICK | flesh burn / steam scald / gas cough |
| `gas_hiss` / `gas_clear` / `steam_hiss` | GAS_SPREAD / GAS_CLEAR / EXTINGUISH, DISPERSE | gas jet / thin-out / steam vent |
| `freeze` / `thaw` | FREEZE / THAW | ice crackle / drip-thaw |
| `furnace` / `rail_zap` / `piston` | HAZARD_FURNACE / HAZARD_RAIL / HAZARD_PISTON | furnace roar / live-rail zap / piston slam |
| `trap_arm` / `trap_fire` / `traps_off` | TRAP_TELEGRAPH / TRAP_FIRE / TRAPS_DISABLED | warning tick / trap discharge / power-down |
| `cold_gust` | EXPOSURE_TICK | open-roof cold gust |
| `overwatch_set` / `overwatch_fire` / `suppress` / `net` | OVERWATCH_SET / OVERWATCH_TRIGGER / SUPPRESS / NET | ready-click / reaction shot / pinned / net-fling |
| `down` / `death` / `permadeath` / `bleed` / `stabilize` / `memorial` / `gear_drop` | UNIT_DOWNED / UNIT_DEATH / UNIT_PERMADEATH / BLEED_TICK / UNIT_STABILIZED / MEMORIAL_ADD / GEAR_DROP | body-drop / kill sting / final permadeath sting / heartbeat pip / stabilize breath / memorial chime / gear clatter |
| `ability` / `heal` / `grant_ap` / `cleanse` / `item` / `hacked` | ABILITY_USE / HEAL / GRANT_AP / CLEANSE / ITEM_USED / HACKED | generic cast / heal shimmer / AP surge / cleanse / item use / hack-convert |
| `charge_place` | CHARGE_PLACED | demolition charge stick + arm beep |
| `buff` / `buff_drop` | BUFF_APPLY, ORDER_THRESHOLD, CAPTAIN_BUFF / BUFF_EXPIRE, CAPTAIN_BUFF_DROP | rally-up / buff wears off |
| `status_on` / `status_off` | STATUS_APPLY / STATUS_CLEAR | status applied / cleared |
| `spawn` / `bot_deploy` / `dispenser` / `dispenser_down` / `recruit` | SPAWNED / BOT_DEPLOY / DISPENSER_SPAWN / DISPENSER_DOWN / RECRUIT_JOIN | unit-in / bot deploy / robot dispense / dispenser destroyed / recruit joins |
| `captain_buff` / `captain_buff_drop` | CAPTAIN_BUFF / CAPTAIN_BUFF_DROP | captain rallies guards / key resolved |
| `shield_up` / `shield_down` / `shield_deflect` | CAPTAIN_SHIELD, CORE_SHIELD / CAPTAIN_SHIELD_DROP, CORE_SHIELD_DROP / DAMAGE_SHIELDED | gate raises / gate drops / deflect clang |
| `betrayal` | BETRAYAL | betrayer sting |
| `fog_reveal` / `conceal` | FOG_REVEAL / CONCEAL_BLOCK | fog lifts / sightline broken |
| `level_up` | LEVEL_UP | promotion chime |
| `vault_phase` / `vault_escalate` / `relay_down` / `power_down` / `conductor_tell` / `conductor_act` | finale (Engine Vault) | phase shift / escalation alarm / relay destroyed / power dies / Conductor telegraph / Conductor act |
| `core_hit` / `core_sabotage` | CORE_DAMAGED / CORE_SABOTAGED | core integrity hit / core dies (objective) |
| `countdown` / `countdown_end` | COUNTDOWN_TICK / COUNTDOWN_EXPIRED | bridge-clock tick / point-of-no-return |
| `ending` | ENDING_RESOLVED | ending tone |
| `reward` / `rest` | REWARD_GRANT / REST_HEAL | loot pickup / rest breath |
| `car_clear` / `run_win` / `run_lose` | RUN_WIN / RUN_COMPLETE / RUN_LOSE | car-clear sting / run victory / squad lost |

**Explicitly silent events** (bookkeeping / ledger / their own UI-or-music cue, `SILENT_EVENTS`):
TURN_PHASE, XP_GAIN, ABILITY_PICKED, DRAFT_OFFER/TAKE/DECLINE/DONE, ORDER_CHANGE, RUN_GENERATED,
CAR_ENTER, CAR_RESOLVED, RUN_ADVANCE, RECON_REVEAL, DEEP_SCAN, CURRENCY_CHANGE, SHOP_BUY,
WORKSHOP_UPGRADE, MARKET_BUY.

### 9.3 UI slots & music tracks

- **UI** (`UI_SLOTS`, played via `AudioDirector.play_ui()` — `select` is already wired to every menu
  button): `select` · `confirm` · `back` · `buy` · `error`.
- **Music** (`MUSIC_TRACKS`, via `AudioDirector.play_music()`): `theme` (menu) · `section_1..4`
  (biome score, one per section) · `vault` (finale) · `memorial`. Music playback calls are the
  remaining wire-up (owner backlog) — the tracks are named and ready in the manifest.
