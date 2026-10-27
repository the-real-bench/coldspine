# Architecture

## Engine & platform
- **Godot 4.x, GDScript.** One codebase targeting Android, iOS, Windows, macOS and Linux. Touch-first UI; mouse/gamepad on desktop.
- The game runs on its **own deterministic integer simulation**, not Godot's physics engine.

## Layout
```
res://core/      # deterministic sim: RefCounted only, zero SceneTree deps, fully unit-tested
res://content/   # data-defined archetypes, traits, enemies, abilities, items, cars, modifiers, hazards
res://ai/        # enemy decision layer over the command system
res://render/    # Godot scenes/nodes: read sim state + event stream, animate (2D isometric)
res://meta/      # persistence: unlocks, Legacy/Memorial, settings (user://)
res://app/       # wiring, input (touch/mouse/gamepad), scene/run flow, menus
res://tests/     # headless suites + golden-file fixtures
```

## Invariants
1. **Determinism.** No floats in `res://core/`. Tile coords are `Vector2i`; all sim math is integer. One hand-rolled seeded integer PRNG (no `randi()`, no wall clock, no frame time). Collections iterate in stable, explicit order. A run is fully reproducible from `(seed, inputLog)`.
2. **Physics is deterministic and previewed; only gunfire uses RNG.** The physics resolver is a pure function over a cloned state: the same function produces the preview and the committed result, so what the player previews is exactly what happens. Preview ≠ outcome is a P0 bug.
3. **Data-driven content.** Archetypes, traits, enemies, abilities, items, cars, modifiers and hazards are external data. Adding content means adding data files. Set-piece cars are `CarTemplate`s that compose shared systems; no per-car bespoke physics.
4. **Command pattern.** Every action (`Move`, `Shoot`, `Shove`, `Slam`, `Throw`, `UseItem`, `Overwatch`, `Hack`) validates → applies → emits events. The renderer animates from the emitted event list; the sim runs headless in tests.
5. **Permadeath stays sacred.** No mechanic resurrects the permanently dead.

## Design toggles kept deliberately
Two design decisions are flagged as revisitable and must not be changed quietly: **in-car fog** (removes the operator's omniscience in the maze/steam rooms) and the **hidden-trait betrayer** density.

## Documents (`docs/`)
| File | Covers |
|---|---|
| `COLDSPINE_GDD.md` | Master design doc: pillars, combat, run structure, economy, enemies, meta, architecture (§17), roadmap (§18), schemas (§21) |
| `COLDSPINE_SubSpec_PhysicsResolver.md` | The deterministic impulse/collision resolver: momentum model, chain loop, flood/electrify, preview |
| `COLDSPINE_SubSpec_Hazards.md` | Hazard taxonomy and the interaction matrix |
| `COLDSPINE_SubSpec_Roster.md` | The Draft, 5 archetypes + ability trees, traits, the betrayer |
| `COLDSPINE_SubSpec_SetPieceCars.md` | Themed cars and biomes, the room library |
| `COLDSPINE_SubSpec_ConductorFinale.md` | The multi-phase finale and endings |
| `FLOW.md`, `DONE_CHECKLIST.md` | Screen flow and the frozen finish line |
| `art/` | Art bible, design sheets, asset shopping list |
