# Design Sheet — Unit Archetypes (player tokens)

> Obeys `ART_BIBLE.md` §3.5 (player = cyan-blue ring `#2EA7E0`) and §7 (96×96 token).
> Five archetypes (Sub-Spec C2). **Faction ring reads first, archetype silhouette second.**
> Each archetype owns a distinct **silhouette glyph + secondary accent color** so a row of
> blue-ringed allies is still individually identifiable at phone size.

## Intent
Instantly answer: **whose is it** (player cyan ring) and **which role** (glyph + accent).
The five must be mutually distinguishable as pure silhouettes — a Bruiser should never be
confused with a Marksman in a grainy feed. The accent telegraphs the physics identity
(GDD §7.2): Bruiser = brute force, Marksman = precision, Saboteur = tech/hazard, Steward =
support, Firebrand = momentum/fire.

## Final-look image-gen prompt(s)

**Token set:**
> "Five stylized isometric tactical-game character tokens for a Snowpiercer-style train uprising,
> seen top-down through a security camera. All share a glowing cyan-blue faction ring (`#2EA7E0`)
> and a flat-shaded rebel-in-scavenged-winter-gear body, but each has a unique silhouette and accent:
> (1) BRUISER — broad heavy frontliner, riveted plate and a maul, rust-orange accent `#C26A2A`,
> stance wide and grounded; (2) MARKSMAN — lean figure shouldering a long rifle, steady-green accent
> `#5FA86A`, calm precise pose; (3) SABOTEUR — wiry tech with a tool-rig, cables and a detonator,
> electric-yellow accent `#FFE14D`; (4) STEWARD — medic with a satchel and a raised hand, clean
> teal-white accent `#7EC8E3`, supportive posture; (5) FIREBRAND — agile firebrand with a torch and
> banner, hot-crimson accent `#FF5A1F`, mid-lunge. Chunky low-detail, single rim light, dark outline,
> readable as silhouettes, surveillance-feed grain, game-asset style, neutral background."

## Placeholder spec (shipping now)
Each token: outer cyan ring `#2EA7E0` (88px) with soft inner glow, dark body fill
`#2A3038`, a white archetype glyph centered, and a small accent-colored shoulder/weapon mark.

| Archetype | Ring | Accent | Silhouette glyph (placeholder) |
|---|---|---|---|
| **Bruiser** | `#2EA7E0` | `#C26A2A` | Broad hexagon body + a thick hammer/fist bar (heavy, wide) |
| **Marksman** | `#2EA7E0` | `#5FA86A` | Slim body + long diagonal rifle line + scope dot |
| **Saboteur** | `#2EA7E0` | `#FFE14D` | Body + zigzag/gear glyph + antenna node |
| **Steward** | `#2EA7E0` | `#7EC8E3` | Body + a plus/cross (medic) over the chest |
| **Firebrand** | `#2EA7E0` | `#FF5A1F` | Lean body leaning forward + flame/banner tongue |

## Asset list
| File | What it is |
|---|---|
| `unit_bruiser.svg` | Bruiser token — frontline displacement engine (rust accent) |
| `unit_marksman.svg` | Marksman token — ranged DPS (green accent, rifle) |
| `unit_saboteur.svg` | Saboteur token — hazard/tech (yellow accent, gear) |
| `unit_steward.svg` | Steward token — support/medic (teal accent, cross) |
| `unit_firebrand.svg` | Firebrand token — momentum/morale (crimson accent, flame) |
