# Design Sheet — Enemies

> Obeys `ART_BIBLE.md` §3.5 (enemy = hostile red ring `#E0432E`; robots tint toward Engine
> steel) and §7. Roster from GDD §12. **The silhouette must telegraph the physics counter-design**
> (the rock-paper-scissors): a Riot Shield reads "frontal block," a Hound reads "fast flanker."

## Intent
At a glance: **threat** (red ring) + **how do I beat it physically**. Each enemy's silhouette
carries its counter (GDD §12): Riot Shield shows a frontal shield (flank it / soak-then-shove),
Net Gunner shows a net (priority kill), Hound is low/fast (bait into hazards), robots read
metallic + hackable (Saboteur target / shove into pistons). Captains get a heavier ring + a
gimmick mote. Unaware enemies (Sub-Spec E1.7) dim the ring + add a `Zzz` mote.

## Final-look image-gen prompt(s)

**Human/security tier:**
> "Stylized isometric enemy tokens for a train-uprising tactics game, seen top-down through a
> security camera, all with a hostile red faction ring (`#E0432E`) and flat-shaded riot-security
> bodies: (1) TRUNCHEON GUARD — basic guard with a baton, plain; (2) RIOT SHIELD — guard behind a
> big frontal slab shield, the shield exaggerated and clearly facing one direction; (3) NET GUNNER
> — lighter guard aiming a net launcher, a webbed net glyph; (4) ENFORCER — armored ranged trooper,
> heavy pauldrons and a carbine; (5) HOUND — fast low-crouched attack-dog handler, lean and angular,
> motion-blur lean; (6) SNIPER — distant figure with a very long rifle and a laser sight line; (7)
> DRONE OPERATOR — backpack control rig launching small bots; (8) generic CAPTAIN — elite officer
> with a heavier double red ring and a gold rank mark. Chunky low-detail, dark outline, single rim
> light, readable silhouettes, surveillance grain, game-asset style."

**Engine/robot tier:**
> "Stylized isometric robotic enemy tokens, cold Engine-steel bodies (`#2C3640`/`#3FC6D4`) with a
> red threat ring and a small cyan 'hackable' indicator node: (1) SECURITY ROBOT — heavy bipedal
> enforcer bot, blocky, slow, an exposed junction port; (2) SENTRY TURRET — static floor-mounted
> twin-barrel turret on a base, no legs, a glowing targeting eye. Clinical, mechanical,
> flat-shaded, dark outline, mobile-legible, security-feed mood."

> **No DRONE asset:** an earlier draft of this prompt included a "DRONE — tiny hovering quad
> bot", but no drone entity, spawnable id, or filename exists anywhere in the game (the Drone
> Operator's bots are flavor on HIS token only). Do not produce a drone asset.

**Section Captains + Conductor (bosses) — each carries a DOUBLE red ring + gold rank AND a key-tell mote:**
> "Six elite boss tokens for a train-uprising tactics game, each with a heavier DOUBLE hostile-red
> ring (`#E0432E`), a gold rank chevron, and a single corner 'key' mote colored to the physics puzzle
> that beats it: (1) THE TAIL WARDEN — broad heavy jailer hefting a maul, blue SOAK mote (`#2E8BC0`)
> = unshovable until soaked; (2) THE FOREMAN — hard-hatted industrial boss with a wrench inside a
> radiating gold BUFF aura (`#FFE14D`) = kill him to drop the guard buff; (3) THE HEAD GARDENER —
> figure wreathed in a green GAS shroud (`#7FBF3F`) holding shears = damage-immune until the gas is
> dispersed; (4) THE MAJORDOMO — tall formal butler behind a grey COVER slab (`#9AA3AD`) = shielded
> until his cover is destroyed, then flank; (5) CHIEF OF SECURITY — blocky Engine-steel robot-chief
> with a cyan visor and a security badge, blue SOAK mote = soak then shove into a trap; (6) THE
> CONDUCTOR (finale boss) — imposing draped figure in a peaked conductor's cap with a cyan RELAY glow
> (`#3FC6D4`) and a dashed cyan inner ring = relay-shielded, flood the dais then shove. Chunky
> low-detail, dark outline, single rim light, distinct silhouettes, surveillance grain, game-asset style."

## Placeholder spec (shipping now)
Outer red ring `#E0432E` (robots add a `#3FC6D4` hack-node dot), dark body `#3A2A2A`
(robots `#2C3640`), white threat glyph, accent mark per the counter-design.

| Enemy | Ring | Body | Distinguishing glyph |
|---|---|---|---|
| **Truncheon Guard** | `#E0432E` | `#3A2A2A` | Short baton bar; plain round body |
| **Riot Shield** | `#E0432E` | `#3A2A2A` | Big rectangle shield on ONE facing (frontal) |
| **Net Gunner** | `#E0432E` | `#3A2A2A` | Crosshatch net diamond glyph |
| **Enforcer** | `#E0432E` | `#4A2A2A` (armored darker) | Heavy pauldron shoulders + carbine line |
| **Hound** | `#E0432E` | `#3A2A2A` | Low elongated body + speed-streak (flanker) |
| **Sniper** | `#E0432E` | `#3A2A2A` | Long thin rifle line + red laser dot |
| **Drone Operator** | `#E0432E` | `#3A2A2A` | Backpack rig + two small bot dots |
| **Security Robot** | `#E0432E` | `#2C3640` | Blocky bipedal + cyan hack-node `#3FC6D4` |
| **Sentry Turret** | `#E0432E` | `#2C3640` | Static base + twin barrels + targeting eye |
| **Captain (generic)** | `#E0432E` double ring | `#4A2A2A` | Gold `#C9A24A` rank chevron + gimmick mote |
| **Tail Warden** (S1) | double ring | `#3A2E2E` | Maul + blue SOAK mote `#2E8BC0` (unshovable-until-soaked) |
| **Foreman** (S2) | double ring | `#3A2E2E` | Hard hat + wrench inside a gold BUFF aura `#FFE14D` (kill-to-drop) |
| **Head Gardener** (S3) | double ring | `#2E3A2A` | Green GAS shroud `#7FBF3F` + shears (damage-immune until dispersed) |
| **Majordomo** (S4) | double ring | `#26262E` | Grey COVER slab `#9AA3AD` (shielded until cover stripped) |
| **Chief of Security** (S5) | double ring | `#2C3640` steel | Cyan visor + badge + blue SOAK mote (soak-then-trap) |
| **The Conductor** (boss) | double ring + cyan inner | `#1C2630` | Peaked cap + cyan RELAY glow `#3FC6D4` (flood-the-dais) |

## Asset list
| File | What it is |
|---|---|
| `enemy_truncheon.svg` | Truncheon Guard — basic melee, easy to slam |
| `enemy_riot_shield.svg` | Riot Shield — blocks frontal shoves/fire; flank it |
| `enemy_net_gunner.svg` | Net Gunner — immobilizes; priority kill |
| `enemy_enforcer.svg` | Enforcer — armored ranged; strip cover then flank |
| `enemy_hound.svg` | Hound — fast flanker; bait into hazards |
| `enemy_sniper.svg` | Sniper — overwatch threat; break LoS |
| `enemy_drone_op.svg` | Drone Operator — deploys bots; kill operator |
| `enemy_security_robot.svg` | Security Robot — heavy, hackable; shove into pistons |
| `enemy_sentry_turret.svg` | Sentry Turret — static, destructible |
| `enemy_captain.svg` | Generic Section Captain — elite gate, gimmick mote (fallback) |
| `enemy_captain_tail_warden.svg` | The Tail Warden (S1) — soak key; heavy melee/slam |
| `enemy_captain_foreman.svg` | The Foreman (S2) — buff key; kill to drop the guard buff |
| `enemy_captain_gardener.svg` | The Head Gardener (S3) — gas key; damage-immune until dispersed |
| `enemy_captain_majordomo.svg` | The Majordomo (S4) — cover key; strip cover then flank |
| `enemy_captain_chief.svg` | Chief of Security (S5) — soak key; robot/heavy |
| `enemy_conductor.svg` | The Conductor — finale boss; flood-the-dais, relay-shielded |
