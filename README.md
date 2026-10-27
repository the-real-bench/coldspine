# COLDSPINE

A physics-first, turn-based tactical roguelite set on an armored train circling a frozen world. You command a small squad car by car toward the engine. Guns are unreliable; the real weapons are **shoves, slams, throws, floods and electrified water**. Every physics move is deterministic and previewed before you commit, so what you see is exactly what happens.

Fully playable start to finish. Final textures and audio are placeholders.

## Run it

Requires [Godot 4.7](https://godotengine.org/) (4.6 also works).

```bash
godot --path .            # play
godot --path . --sim      # watch the auto-pilot play a seeded run
```

## Tests

The simulation runs headless, so the whole game is testable without a window. 31 suites, 3,406 checks:

```bash
godot --headless --path . --script res://tests/run_tests.gd          # core sim: 803 checks
godot --headless --path . --script res://tests/combat_smoke.gd       # any single suite
```

Runs are reproducible from `(seed, input log)`: the suites, the smoke runs and the balance telemetry are byte-identical across repeated runs. Tests run against a sandboxed save, never a real player profile.

## How it's built

See [ARCHITECTURE.md](ARCHITECTURE.md). The short version:

- `core/` is a deterministic **integer** simulation: no floats, no engine physics, no scene tree, one seeded PRNG.
- The physics resolver is a pure function over a cloned state; the same call produces the preview and the committed result.
- Every action is a command that validates, applies and emits events; the renderer only animates the event list.
- Content (archetypes, traits, enemies, abilities, items, cars, hazards) is data, not code.

Design specs are in `docs/`: the game design document plus sub-specs for the physics resolver, hazards, roster, set-piece cars and the finale.

## License

Copyright © ptbench Studios. All rights reserved. The code is public to read; no license is granted to copy, modify or distribute it.
