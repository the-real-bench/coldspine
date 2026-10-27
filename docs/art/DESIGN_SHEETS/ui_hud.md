# Design Sheet — UI / HUD (the ops console)

> Obeys `ART_BIBLE.md` §2 (operator/CRT framing), §5 (chrome treatment), §6 (telegraphs).
> The whole UI is the **surveillance / ops console** (GDD §3.1, §16). The mock ships as
> `ui_ops_console_frame.svg` (`0 0 1280 720`). Diegetic, cheap, and it *is* the fiction.

## Intent
Every panel must read as a **hijacked security feed**: the operator watches one car, issues
orders down comms, runs the physics angles before committing. The chrome is the constant frame;
only the feed contents shift palette by section. Must scale from desktop down to a ~5–6" phone
(GDD §17.6) — anchor-based, large touch targets, the preview overlay and status icons legible.

## Layout (the binding regions)
1. **Camera-ID header** (top bar): `CAR 07 — COOLANT BAY`, `● REC` blink, timecode, signal bars,
   section tag (`SEC 2 · THIRD CLASS`). Amber `#FFB000` mono on `#0B0E11`.
2. **The feed** (center): the iso car render with scanlines + grain over it. The play space.
3. **Recon strip** (right rail, §8.2): the **next car** in full (type icon, enemy count, hazard
   tags, modifiers, reward) and the car-after as a **partial silhouette**; a **Deep Scan** button
   (spend Tools). No path-choice UI — the line is fixed; this is preparation, not routing.
4. **Comms log** (bottom-left panel): scrolling orders + unit barks, terminal type.
5. **AP / order strip** (bottom-center): selected unit's 2 AP pips, action buttons
   (Move / Shoot / Shove / Slam / Throw / Item / Overwatch), the **two-tap commit** (§17.6).
6. **Order meter** (top-right, §9): a labeled gauge, always visible, color from calm cyan
   `#3FC6D4` → alarm red `#FF3B3B` as it rises.
7. **Status / cover indicators**: ride on tokens in the feed (see `status_icons.md`, bible §3.6).

## Final-look image-gen prompt(s)

> "A full tactical-game HUD styled as a hijacked security-surveillance operations console, dark
> near-black panels (`#0B0E11`) with thin steel borders and corner bracket ticks, amber monospace
> terminal type (`#FFB000`) and dim cyan data (`#3FC6D4`), CRT scanlines and faint grain over the
> whole screen. Top bar: a camera ID 'CAR 07 — COOLANT BAY', a blinking red REC dot, a timecode,
> signal bars, and a section tag. Center: an isometric tactical car viewed top-down as the camera
> feed. Right rail: a RECON strip showing the next car in full detail and the car after as a dim
> silhouette, with a 'DEEP SCAN' button. Bottom-left: a scrolling COMMS LOG of orders and unit
> barks. Bottom-center: an action bar with two AP pips and order buttons (Move, Shove, Slam, Throw,
> Shoot, Overwatch). Top-right: an ORDER meter gauge from cyan to alarm-red. Cold, diegetic, lo-fi
> sci-fi, Snowpiercer mood, mobile-responsive, game-UI concept art."

## Placeholder spec (shipping now)
`ui_ops_console_frame.svg` — a single `1280×720` mock with all regions blocked in using bible
colors: `#0B0E11` panels, `#1C2630` borders, `#FFB000` headers, `#3FC6D4` data, a stand-in iso
feed area (a few placeholder tiles + tokens), a recon strip with next/after cards, a comms log
with two lines, an AP/order strip with 2 pips + 6 buttons, and an Order gauge. Scanline overlay
drawn as repeating lines so the intended treatment is visible.

## Asset list
| File | What it is |
|---|---|
| `ui_ops_console_frame.svg` | Full ops-console HUD mock: camera-ID header, comms log, AP/order strip, recon strip, Order meter, scanline overlay |
