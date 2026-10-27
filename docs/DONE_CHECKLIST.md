# COLDSPINE — DONE CHECKLIST (frozen 2026-07-04)

> The finite finish line for the "done except textures" push. **This list only shrinks.**
> New discoveries mid-push go to §Post-texture backlog unless they are P0/P1 defects.
> **DONE =** every box below checked **+** full screenshot tour visually reviewed by the lead
> **+** all suites green with counts re-parsed from real stdout **+** determinism byte-identical
> **+** the §Owner-gates surfaced with evidence (not silently decided).
>
> Sources: 8-dimension adversarially-verified audit (46 confirmed P0/P1, 61 P2/P3), the lead's
> visual review of 25 windowed screenshots (build/screens/), owner asks
> (draft sprite space, enemy logic, auto-play, UI/gameflow perfection).
> Full finding evidence: session scratchpad `audit_confirmed_full.json` (+ workflow journal).
> Wave protocol: snapshot → implement → adversarial verify → lead re-parses suites + re-tours pixels.
> Balance-shifting items [B] require a before/after telemetry sweep; seed re-pins are never silent.

## Wave 1 — P0 foundations ✅ DONE (both lanes adversarially verified + lead re-ran all suites; 2026-07-04)
- [x] W1-1 [P0] `car_view._diamond()` self-recursion → real `Iso.diamond_points` (restores ALL hazard layers, trap telegraphs, move/push overlays) — car_view.gd:238 · render_smoke +4
- [x] W1-2 [P0] UNLOCKS/MEMORIAL menu panels: ScrollContainer + ESC-to-home from any sub-panel — menu.gd:229/541 · menu_smoke +check
- [x] W1-3 [P0][B] Car-unlock gate made additive — non-catalog templates (base/captains/engine) always admitted; new decisive test = owned unlock ⇒ full Tail→Engine line w/ 4 captains + engine — run_generator.gd:253 / unlocks.gd:95 · run_tests +10
- [x] W1-4 [P0] ASCII POC back edge (any key/click → menu; stdout byte-identical) — main.gd:80/114
- [x] W1-5 [P1][B] NEW RUN / [N] rolls a fresh seed; `--seed=N` override; headless keeps 0xC01D5; seed echoed to comms+log — menu.gd:126 / run_controller.gd:257
- [x] W1-6 [P1] Stale-preview two-tap fixed: rejected re-point clears armed intent (preview==outcome held) — run_controller.gd:2362/5357
- [x] W1-7 [P1] Legacy consumed at BREACH not NEW RUN; draft abandon leaves profile untouched — menu.gd:580 / run_controller.gd:438
- [x] W1-8 [P1][B] [N] restages MenuHandoff from profile (gate + classes + settings) — run_controller.gd:2721
- [x] W1-9 Harness save sandbox: `--save-sandbox` / `COLDSPINE_SAVE_SANDBOX=1` → sandbox_ files; tour aborts loudly if unarmed — save_system.gd:32 / screenshot_tour.gd:47
- [x] W1-9b [P1] Sandbox completed at root: `SaveSystem.force_sandbox` static armed by run_tests + run_smoke `_initialize`; run_tests raw-const profile refs routed through `profile_path()` — **stops every headless test run from deleting the owner's real profile** (the true recurring-corruption source, not just the tour) — save_system.gd:38 / run_tests.gd:63,2948 / run_smoke.gd:39 / meta_smoke +4

## Wave 2 — Enemy AI true-to-design ✅ DONE (2 lanes adversarially verified; lead fixed 2 verifier-caught gaps + re-pinned balance; 2026-07-04)
- [x] W2-1 [P1] Net Gunner net works on players (net now immobilizes 1 turn, consumed at victim's AP refresh) — ai_profiles.gd + turn_manager.gd:146
- [x] W2-2 [P1] Sentry Turret anchored (ranged_hold no-move branch + hard `not movable` MoveCommand guard) — move_command.gd:45 / ai_profiles.gd:122
- [x] W2-3 [P1] Riot Shield block un-inverted: spawn facing +x + per-turn reface to nearest player (resolver rule untouched); golden test blocks frontal, folds flank, preview==commit — content_db.gd:128 / ai_profiles.gd:64. Frontal FIRE-block deferred (needs cover-stat/shoot_command).
- [x] W2-4 [P1] Ambush/unaware enemies wake on damage or adjacency (free opening round preserved) — ai_profiles.gd:52. WAKE render-tell deferred (no Ev.WAKE).
- [x] W2-5 [P1] **Majordomo cover gate DONE** (adjacent-statue detection). **Gardener gas-shroud DONE (owner-approved fix, 2026-07-04):** moved her water_main to (11,4) beside her (floodRadius 4 reaches her tile 12,4) + shroud LATCHES open once flooded/soaked (one-way, reuses captain_gate_open → no new sim state, no soft-lock). Faithful puzzle (break the irrigation) AND bot-solvable (the pilot's gate-tool playbook shoots the flood source) — balance_smoke 0x300 stays green with her gating. — captain_system.gd:122 / captain_s3_head_gardener.json
- [x] W2-6 [P1] Foreman death drops his guard buff (`_drop_orphaned_buffs` reaps via real Bleedout.down_or_kill funnel) — captain_system.gd:100
- [x] W2-7 [P0] Conductor body no longer generic-rushes while immune — **`is_finale_boss` skip in the enemy_ai dispatch** (lead's fix after the verifier proved the lanes' `unaware`-only fix folded when a player stepped adjacent); test now places a player adjacent — enemy_ai.gd:36 / finale_smoke.gd
- [x] W2-8 [P2] Pathing: greedy stepper → deterministic BFS (routes around walls/corridors); ranged_hold repositions toward LoS — enemy_ai.gd:84
- [x] W2-9 [P2] Reinforcements mirror the toughest mobile ordinary enemy in the car (no S4/S5 tail chaff) — hazard_system.gd:163
- [x] W2-10 [P2] Foreman uses his authored melee kit (no unauthored drone spawn) — captain_system.gd:44. Conductor RE_ROUTE/ACCELERATE variety → **deferred to W4-8** (finale wave).
- [x] W2-G Balance gate: full battery green + determinism byte-identical; balance_smoke honestly RE-PINNED 0x61E→**0x300** (natural HARD-STOP win, all 4 captains, NO enemy weakened; win-rate 0.45%→0.125% = correctly-harder). +30 enemy_ai_wave2 tests. Fixed a pre-existing 24× SCRIPT-ERROR in a run_tests helper (test-only guard, byte-stable).

## Wave 3 + 3b — Economy & progression made real ✅ (adversarially verified across 2 workflows + lead integration; 2026-07-04)
- [x] W3-1 [P1][B] Shop sells real usable items from content/items (phantom field_kit/stim_patch gone; AUTO inherits) — run_controller.gd
- [~] W3-2 [P1][B] EQUIP MECHANISM done (bought weapon/armor confers its stat, proven); shop stocks a rotating weapon/armor pool. **RELIABLE per-run acquisition still open** (shop-only → shopless runs get none; verifier caught the phantom-count test, now reframed honestly) → **reward-table drops = W7 content pass**
- [x] W3-3 [P1][B] Workshop upgrades apply to combat bodies (_apply_upgrades_to_body at _place_squad) — run_controller.gd:5008
- [x] W3-4 [P1][B] All 6 no-op level-up abilities wired (overclock_hack + inspire/overrun/last_stand/martyrs_wake/vanguard); lead threaded inspire/overrun/vanguard-autocrit into the REAL ShootCommand path (verifier caught they were ability-path-only) — ability_system.gd + shoot_command.gd
- [x] W3-5 [P1][B] Class unlocks gate the draft (allowed_archetypes from unlocked_class_ids) — draft.gd:145 / run_controller.gd:275
- [x] W3-6 [P1][O] gear/tail/narrative unlocks implemented; recruit-pool TRIMMED (overlapped class unlocks) — unlocks.gd. [G3 resolved: implement-3/trim-1]
- [x] W3-7 [P1][B] Firebrand momentum meter LIVE: SimEntity.momentum (snapshot-gated → determinism-safe), +1/car (grafted both clear paths), +dmg/move/acc mods, Vanguard autocrit on real shots, reset-on-permadeath w/ Martyr's-Wake — ability_system.gd/sim_entity.gd/bleedout/turn_manager/shoot_command
- [ ] W3-8 [P2] Event system eventBeat contract (trait_gain/ambush/shortcut) — DEFERRED (touches run traversal; own pass) → W7
- [ ] W3-9 [P2][B] Scrip faucet/sink re-measure — W7 (after reward-drops land)
- Regroup decoupling (design G2) implemented byte-neutral; balance_smoke RE-PINNED 0x300→**0x71B** (HARD STOP, 4 captains) after momentum-live reshuffle. **24/24 suites green, 2851/0, 0 SCRIPT errors, determinism byte-identical.** Snapshot wave3b-DONE.

## Wave 4 — Finale done right ✅ DONE (both lanes CONFIRMED_FIXED, verifiers found no defect, balance GREEN-HELD; 2026-07-05)
- [x] W4-1 [P1][B] Relays/core are real previewed unit actions (deployed unit at Chebyshev-1 + AP + integrity; preview==commit) — run_controller.gd:1451/1511
- [x] W4-2 [P2] Antechamber dormant phase honored on-screen (arms on cross-divider / first relay|turret down; headless keeps instant for byte-stability) — engine_vault.gd:132
- [x] W4-3 [P1][O] SEIZE reachable: capture_conductor wired (commit_capture_conductor), reaches EndingId.SEIZE_ENGINE, distinct from HARD_STOP; ending-tone map already correct — engine_vault.gd:247
- [x] W4-4 [P1] DAMAGE_SHIELDED render feedback: CYAN "SHIELDED"/"SEALED" float + comms line — event_player.gd/car_view.gd:401
- [x] W4-5 [P2] Finale comms/juice beats for 13 event types (BREACHED klaxon, CORE-EXPOSED glitch-tear, relay/countdown narration) — event_player.gd
- [x] W4-6 [P2] 60-round stall with intact core = LOSS (outcome reads real is_objective_complete()) — run_controller.gd:5566
- [x] W4-7 [P2] Deploy picker at the Engine (on-screen; headless byte-stable) — run_controller.gd:957
- [x] W4-8 [P2] Conductor action variety: all 4 actions (DEPLOY/RE_ROUTE/OVERCHARGE/ACCELERATE) score across a finale, deterministic — conductor_ai.gd:67
- [x] W4-9 [P2] Finale header overlap fixed (REC/timecode slides to x868, clears the 463px header) — ops_hud.gd
- [x] W4-10 [P2] Finale chrome freezes at run-over (set_running(false) → _freeze_finale_chrome hides countdown/boss panels; uses existing run-over signal) — ops_hud.gd:185
- Balance GREEN-HELD (0x71B still wins through the new finale); SEIZE reachable via capture test (no natural bot-win seed known — optional low-Order sweep, non-blocking)

## Wave 5 — Presentation: sprites where characters are chosen + UI states + copy
✅ WAVE 5 DONE (both lanes verified + lead grafts + lead visual tour review; 27/27 green, 3051/0, determinism byte-identical, snapshot wave5-DONE, 2026-07-05). Draft portraits confirmed on-screen (owner ask).
- [x] W5-1 [P1] **Draft cards have character PORTRAITS** (owner ask ✓) — 140x168 faction-ringed region below the stat block, distinct per-archetype placeholder silhouettes (marksman+rifle, steward+cross, firebrand+torch...), `assets/final/portrait_<archetype>.png` drop-in + ART_SHOPPING_LIST §2b — run_screens.gd. Visually reviewed in the windowed tour.
- [x] W5-2 recruit dossier portrait · [x] W5-3 roster mini-glyph · [x] W5-5 level-up portrait + queue-count copy
- [x] W5-4 no raw IDs (level-up/shop humanized; comms phase names) · [x] W5-6 picker rows show effect+AP+range hint (STABILIZE + ability/item feed grafted by lead into run_controller) · [x] W5-7 full button StyleBox states
- [x] W5-8 menu focus + keyboard traversal · [x] W5-9 ending/payout panel click forwards · [x] W5-10 tip banner off the action zone · [x] W5-11 action row fits (framed 2-row) · [x] W5-12 STABILIZE palette button (lead grafted `set_stabilize_available` in run_controller) · [x] W5-13 status legend wraps · [x] W5-14 deploy glyph (no tofu) · [x] W5-15 econ flavor-art region · [x] W5-18 bruiser token redrawn as a person
- [ ] W5-16 [P2] Memorial enshrine glyph — DEFERRED to W7 (row restructuring risks the new W5-8 focus wiring; archetype already shown in text)
- [x] W5-17 overwatch badge priority raised

## Wave 6 — Auto-play, onboarding, audio, settings ✅ DONE + G2 REGROUP FLIP LANDED (2026-07-05; 29/29 green, 3195/0, snapshot wave6-DONE)
- [x] W6-1 pilot uses abilities+items+retreat-heal (proven firing gas_tap + medkit in a real drive) · [x] W6-2 AUTO fight-scope (no silent picks; stall→MANUAL) · [x] W6-3 AUTO deploy best-N · [x] W6-4 pilot stabilize AP parity · [x] W6-12 pilot honors Steady · [x] W6-11 betrayer VET scan (keyboard "VET"; touch button → W7)
- [x] W6-6 music wired (menu theme + section/vault/memorial via lead graft) + menu UI SFX (run-layer SFX → W7) · [x] W6-7 saved volumes at boot · [x] W6-8 fullscreen+vsync · [x] W6-9 reduced-flash · [x] W6-10 colorblind+text_speed rows · [x] W6-5 tips for order/captains/betrayer/fog/finale
- [x] **G2 REGROUP FLIP LANDED**: between-car heal now ceil(max_hp*50/100) + downed stand at 2 HP (scarcity pillar in); 0x71B still wins at 50% (HARD STOP), determinism byte-identical, no re-pin needed — sim_enums.gd / run_controller.gd:1086,3309

## Wave 6-old-anchor — Auto-play, onboarding, audio, settings
- [ ] W6-1 [P1][B] Pilot uses abilities + items (plan attached in audit) — the honest lever for the regroup pillar — run_controller.gd:3097
- [ ] W6-2 [P1] AUTO scope choice (this-fight vs whole-run); no silent permanent picks; stall/wipe hands back to MANUAL with a pause — run_controller.gd:849
- [ ] W6-3 [P2] AUTO deploy = real best-3 (not roster-first-N)
- [ ] W6-4 [P2] Stabilize AP parity (AUTO's free stab vs manual 1 AP)
- [ ] W6-5 [P2] Tips for ORDER meter, captains, betrayer, fog, finale (catalog covers only combat basics)
- [ ] W6-6 [P1] Music triggers wired (menu/run/combat/finale/ending) + UI audio slots across the run layer — audio_director.gd:182
- [ ] W6-7 [P2] Saved volumes applied at boot (stale `pass` stub)
- [ ] W6-8 [P2] Fullscreen + vsync toggles in Settings
- [ ] W6-9 [P2] Reduced-flash / photosensitivity toggle (flash-heavy combat)
- [ ] W6-10 [P2] colorblind_mode + text_speed keys: implement or remove (dead promises today)
- [ ] W6-11 [P1][B] Betrayer pre-emptive scan surface (who scans, cost, where) — run_controller.gd:4360
- [ ] W6-12 [P2] Pilot honors Marksman "Steady" (no force-end after first shot)

## Wave 7 — Content, meta, harness, closeout ✅ DONE (both lanes verified + lead grafts; 31/31 green, 3406/0, 0 SCRIPT errors, snapshot wave7-DONE; 2026-07-05)
- [x] W3-2-drops [P1][B] Equipment reward-drops — reliable acquisition (riot_plate at the mandatory S1 captain gate every run; 12/12 seeds gear up); confers stat — run_generator.gd:184 / run_state.gd:216
- [x] W7-1 [P1][B] +3 new S2 combat templates (gantry-shove-into-gap, cistern-flood-electrify, boiler-shove-into-vent); deck draws all 4 (46/60 lines non-security_02)
- [x] W3-8 [P2] Event system data-driven: 4 distinct events w/ trait_gain/shortcut/ambush outcomes (ambush injects combat, shortcut skips a car), resume-safe, byte-stable headless
- [x] W7-2 [P2] Run history: run_log in profile + menu RUN HISTORY panel; **lead grafted record_run into _apply_finalize** (verifier caught it was dead in live play) — meta_profile.gd / run_controller.gd:6442
- [x] W7-3 [P2] Save schema gate (run_save_compatible reads schema; CONTINUE 3-state disables an incompatible save with a message) — save_system.gd:144
- [x] W7-4 [P2] Boot splash (bg + icon) + window title "COLDSPINE" — project.godot
- [x] W7-6 [P3] All .gd have .uid (lead ran editor import pass; the new gameplay test's missing sidecar that reddened w7_presentation_meta is fixed)
- [x] W7-7 [P3] Stale in-code/doc claims corrected
- [x] W7-8 post-win resume doesn't re-fight a resolved car · [x] W7-9 mid-phase win releases the phase · [x] W7-10 60-round guard warns + honest cause · [x] W7-11 bourgeois ESC ≠ silent SPARE · [x] W7-13 betrayal state survives save/resume
- [x] W6-11-button betrayer VET palette button (lead grafted set_vet_available sync) · [x] W6-2-indicator AUTO-scope button (lead grafted the "SCOPE" control route) · [x] W6-6-uisfx run-layer UI SFX · [x] W5-16 Memorial glyph
- [x] W7-iso-labels setpiece left/right reconciled to the flipped orientation
- [ ] W7-12 [P2] Recon/Order/currency peek during econ takeovers — remaining polish (non-blocking; econ screens are deliberate full takeovers)
- Balance GREEN-HELD (0x71B still wins at 50% regroup through reward-drops + new cars); determinism byte-identical

## Design decisions (made by the design-team panel 2026-07-04 — implement, don't defer)
- [x] G1 Iso projection → **KEEP the 2:1 isometric** (panel 4/5, high conf). Dimetric would regress DISPLACE-vector symmetry + re-cut every tile for nil legibility gain. Follow-ons (not the projection): (a) buy "climb" feel in camera pitch/parallax + car-transition VFX + a car-progress rail [→ W5/W7 juice]; (b) reconcile setpiece JSON "left"/"right" token labels to the flipped on-screen orientation (the real logged friction, workbench.md:31) [→ W7]; (c) OPTIONAL ~1-day render-only dimetric spike to close it with evidence before final tiles are commissioned — skipped for now (call is confident), available if wanted.
- [~] G2 POST_COMBAT_REGROUP → **50% of max HP** target; captain/Engine heal-free; NEVER flat 4. **Decoupling IMPLEMENTED 2026-07-04** (byte-neutral): `_regroup_squad` split into `_regroup_heal(amount)` (living, clamped) + `_stand_up_downed(revive_hp)` (unconditional — a downed comrade always gets up); constants `POST_COMBAT_REGROUP_PCT=50` + `REGROUP_STANDUP_HP=2` added; 22/22 green, 0x300 held. **REMAINING (→ W6-1 with the armed bot):** flip the two call sites to `_regroup_heal(ceil(max_hp*50/100))` + `_stand_up_downed(E.REGROUP_STANDUP_HP)`, re-sweep, re-pin balance_smoke. Human playtest at 50% can start now.
- [ ] G3 Unlock catalog: confirm smallest-real implementations vs trims (W3-6 output) — decide from the Wave-3 report
- [ ] G4 Econ-screen left-half art direction (W5-15 proposal) — design-panel it in W5, don't defer
- [ ] G5 In-car fog default + BETRAYER_DENSITY_PCT — hold at spec unless a design reason surfaces
- [x] ~~G-gardener~~ RESOLVED 2026-07-04: water_main moved to (11,4) + one-way shroud latch. Faithful + bot-solvable + balance_smoke green.

## Post-texture backlog (recorded, out of scope for this push)
Touch-first reflow; gamepad + key rebinding + InputMap; AUTO fog-honesty; ending-tone presentation extras (LOSS scan-tear, ledger count-up, boot chroma-glitch, breach cosmetics); relay pip max mismatch; scanline toggle binding in run scene; out-of-range SHOOT arm UX; zero-enemy-car comms beats; ending-tone color mapping (HARD_STOP/SEIZE swap — folded into W4-3); ENEMY-PHASE banner red vs reserved-red rule; UI-bus volume slider; Steward legacy-heir tap-to-pick polish beyond W1-7; per-run seed display/share.
