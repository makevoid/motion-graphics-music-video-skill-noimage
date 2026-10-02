# Scene cookbook: examples for the native renderer

Copy-ready recipes for a scene generator built from [scene-template.rb](../assets/scene-template.rb); the process is in
[native-workflow.md](native-workflow.md). Snippets are Ruby hashes that become scene JSON verbatim. They run inside a section method
`(s, e, bars)` and use the template's helpers:

| Helper | Returns |
|---|---|
| `b(bar, beat)` | a beat time |
| `f(t)` | `t` snapped to the frame |
| `hits(kind, s, e)` | drum attacks |
| `rand` | a seeded random value |
| `group` / `text` / `rect` / `bg` | nodes |
| `event` | records a picture event |
| `accent` | records a camera hit |
| `sample_track` | a track sampled from a Ruby function |
| `beat_phase` | a beat phase track |
| `neon` | adds glow to nodes |

Every key below is checked by the renderer; unknown keys fail. The full schema is in `tools/graphics/README.md`.

Coordinates are pixels, top-left origin, y down, rotation in radians (clockwise), times in seconds. Rects use their top-left corner,
circles and polygons their centre (`x`/`y` offsets the points), and text its left baseline (`align` centre/right about `x`). `start`/`end`
make visibility `[start, end)`; groups isolate opacity and pass time to their children.

## Tracks and easing

`"prop": [[t, value], [t, value, "easing"], ...]`. Times strictly increase, and a key's easing shapes the segment that arrives at it.
Easings: `linear inCubic outCubic inOutCubic inExpo outExpo outBack outElastic smooth hold`. `hold` keeps the previous value until the key:
use it for hard cuts, strobes and hold-frame (on-twos) motion. Animatable everywhere: `x y rotation scaleX scaleY opacity skewX skewY`. Shapes
add `trimStart trimEnd strokeWidth dashPhase` (and `glow`); text adds `reveal`; type-specific ones are listed below.

```ruby
# Beat-stepped growth: a notch per beat (outExpo), held between beats
steps = [[s, 0.2]]
(0..7).each { |i| t = b(bars[0] + i / 4, i % 4); steps << [t, steps.last[1]] if t > steps.last[0] + 0.01; steps << [t + 0.15, 0.2 + 0.1 * (i + 1), "outExpo"] }
{ type: "circle", radius: 200, fill: HOT, x: CX, y: CY, start: f(s), end: f(e), tracks: { scaleX: steps, scaleY: steps } }

# Strobe: on/off on eighth notes with hold
strobe = (0...16).map { |i| [b(bars[0], i * 0.5), i.even? ? 1 : 0, "hold"] }
rect(PAPER, f(strobe[0][0]), f(e), tracks: { opacity: strobe })
```

## Line art that draws itself

```ruby
# Draw on, then erase from the tail (trimEnd leads, trimStart chases); boil = hand-drawn jitter redrawn 12x/s
{ type: "polygon", points: star_points(300, 120), fill: nil, stroke: PAPER, strokeWidth: 2, boil: 2, boilRate: 12, seed: 3,
  x: CX, y: CY, start: f(s), end: f(e), glow: 9, glowCore: 0.55,
  tracks: { trimEnd: [[s, 0], [b(bars[1]), 1, "outCubic"]], trimStart: [[e - 0.8, 0], [e, 1, "inCubic"]] } }

# A spline path drawn on bar by bar; dashes marching via dashPhase
{ type: "spline", points: [[200, 800], [600, 300], [1100, 700], [1700, 250]], fill: nil, stroke: COOL, strokeWidth: 2, dash: [14, 10],
  start: f(s), end: f(e), tracks: { trimEnd: bars.each_with_index.map { |bar, i| [b(bar), (i + 1.0) / bars.size, "inOutCubic"] }.unshift([s, 0]),
                                    dashPhase: [[s, 0], [e, -240]] } }

# Arbitrary path: M/L/Q/C/Z commands (an eye)
{ type: "path", commands: [["M", -60, 0], ["Q", 0, -45, 60, 0], ["Q", 0, 45, -60, 0], ["Z"]], fill: nil, stroke: PAPER, strokeWidth: 3, x: CX, y: CY }
```

## Neon

`glow` (halo px, animatable) and `glowCore` (0–1 whitened core) on any node apply to its whole subtree. Strokes, small fills (dots, stars)
and small type glow in their own colour; big fills and poster type never do. Use thin strokes (1–3 px) with glow 8–12, and render finals at
`SUPERSAMPLE=2`. To make a section neon, call `neon(@nodes[first..])` after drawing it.

```ruby
{ type: "circle", radius: 320, fill: nil, stroke: HOT, strokeWidth: 1.5, x: CX, y: CY, glow: 10, glowCore: 0.6,
  tracks: { glow: [[s, 4], [b(bars[0], 1), 18, "outExpo"], [b(bars[0], 2), 8]] } }
```

## Type

```ruby
# Word slam on a beat (entrance: pop | slap | slam; slap/slam are opaque on their first frame so the hit lands)
text("DROP", font: DISPLAY, size: 420, x: CX, y: CY + 150, fill: HOT, start: f(b(bars[0])), end: f(b(bars[1])), entrance: "slam")

# Outline-only echo stack: the template's echo_word / words helpers
words([["EVERY", b(bars[0])], ["STAR", b(bars[0], 2), { fill: HOT, echo: PAPER }], ["IS A", b(bars[1])], ["CLOCK", b(bars[1], 2)]], f(e))

# Typewriter with a block cursor (reveal track = fraction of glyphs, "hold" per key) + typing SFX events
@nodes.concat typed("SIGNAL ACQUIRED", b(bars[0]), b(bars[0], 2), stop: f(e), size: 30)

# Spatial wipe on big type (reveal with smooth easing)
text("STILL SHINING", font: DISPLAY, size: 160, x: CX, y: CY, start: f(s), end: f(e), reveal: [[s, 0], [s + 0.6, 1, "outCubic"]])

# Text on a circle, scrolling (offset px along the path; a closed loop wraps)
{ type: "textpath", text: "LOOKBACK TIME · LIGHT-YEARS · " * 4, font: MONO, size: 22, radius: 300, fill: PAPER, tracking: 2,
  x: CX, y: CY, start: f(s), end: f(e), tracks: { offset: [[s, 0], [e, 700]] } }

# Rolling odometer digit: a clipped group whose strip rolls (clip: [x, y, w, h] in the parent's space)
strip = (0..10).map { |k| text((k % 10).to_s, font: MONO, size: 100, x: 900, y: 600 + k * 115, align: "left") }
group([group(strip, tracks: { y: [[s, 0], [s + 1.2, -10 * 115, "outCubic"]] })], start: f(s), end: f(e), clip: [896, 505, 68, 125])
```

Size poster words to fit: about `1700 / (letters * 0.52)` px for Impact, `0.78` per letter for Arial Black and `0.42` for DIN Condensed.

## Geometry generators

```ruby
# Flowing concentric rings / hex tunnel (phase moves every ring out one spacing and wraps: endless flow)
{ type: "rings", count: 16, radius: 50, spacing: 52, sides: 6, twist: 0.25, stroke: PAPER, strokeWidth: 1.5, dash: [6, 10], fade: 0.08,
  x: CX, y: CY, start: f(s), end: f(e), tracks: { phase: [[s, 0], [e, 4]], twist: [[s, 0], [e, 1.2]] } }

# Gravity-well grid that tightens into a black hole
{ type: "warpgrid", width: W + 400, height: H + 400, x: -200, y: -200, spacing: 64, color: "#EDE6D8AA", strokeWidth: 1.5, falloff: 420,
  center: [CX + 200, CY + 200], resolution: 10, start: f(s), end: f(e),
  tracks: { strength: [[s, 0.1], [e, 0.92, "inCubic"]], twist: [[s, 0], [e, 1.6, "inCubic"]] } }

# 3D floor grid running under the camera (plane: rotationX ~1.5 rad + panY; the vanishing point is the anchor)
{ type: "plane", x: CX, y: 600, anchor: [CX, 600], rotationX: 1.5, panY: 420, start: f(s), end: f(e),
  children: [{ type: "grid", x: CX - 5000, y: -5400, width: 10_000, height: 6300, spacing: 90, color: "#FF5A1F99",
               tracks: { y: [[s, -5400], [e, -5040]] } }] }   # scrolling one spacing per loop reads as forward motion

# Polygon shards / radial rays on a hit (template helpers)
@nodes.concat shards(t, count: 60, colors: [HOT, PAPER, GOLD], speed: 1300)
@nodes.concat rays(t, count: 24, inner: 140, outer: 1200, colors: [GOLD, HOT, PAPER], width: 4)
@nodes << ring_burst(t, r: 60, to: 8, color: GOLD)
```

## Metal shaders as pictures

```ruby
# Nebula: domain-warped gas inside a ragged disc that grows (reveal), with ridged filaments, a blue core, sparse stars
{ type: "shader", shader: "nebula", x: 0, y: 0, width: W, height: H, center: [CX, CY], radius: 620, seed: 1811, detail: 2.2, swirl: 3.0,
  colors: ["#3A1060", "#FF5A1F", "#FFC531"], filaments: 1.2, core: 0.8, stars: 0.6, drift: 0.25, start: f(s), end: f(e),
  tracks: { reveal: [[s, 0], [s + 1.2, 1, "outCubic"]], brightness: [[s, 0.6], [e, 1.0]] } }

# Starfield that swells on every beat and sends a light ring out from `center` (beat = phase 0 -> 1 between beats)
beats = bars.flat_map { |bar| (0..3).map { |p| b(bar, p) } } + [e]
{ type: "shader", shader: "starfield", x: -120, y: -120, width: W + 240, height: H + 240, center: [CX + 120, CY + 120], seed: 11,
  colors: [PAPER, HOT, COOL], stars: 0.85, twinkle: 0.6, pulse: 0.7, drift: 0.4, start: f(s), end: f(e),
  tracks: { beat: beat_phase(beats), brightness: [[s, 0], [s + 1, 0.9, "smooth"]] } }
```

Shader nodes blend straight into the frame on the GPU. Inside a fading group, a clip, a 3D plane or a blend mode, they fall back to a
slower path. To add a new look, add a kernel to `ShaderNode.swift`.

## Motion from physics or maths

Tracks can be sampled from any Ruby function of time. A dot spiralling in on a tilted disc, faster as it falls:

```ruby
t0, life, a0, r0 = s, 1.4, rand(TAU), rand(380, 1050)
pos = lambda do |t|
  u = ((t - t0) / life).clamp(0.0, 1.0)
  r = r0 * (1 - u)**1.4 + 30
  a = a0 + 2.2 * (Math.sqrt(r0 / r) - 1)
  [CX + Math.cos(a) * r, CY + Math.sin(a) * r * 0.42]
end
{ type: "circle", radius: 3, fill: GOLD, glow: 6, start: f(t0), end: t0 + life,
  tracks: { x: sample_track(t0, t0 + life) { |t| pos.(t)[0].round(1) }, y: sample_track(t0, t0 + life) { |t| pos.(t)[1].round(1) } } }
```

Sample at 1/30 s (1/60 s for fast moves): the renderer interpolates linearly between samples.

## Whole-frame layers

```ruby
# Camera: the template's camera(@nodes) wraps everything; accent(t, amp) adds a hit (shake + scale punch)
hits("kick", s, e).each { |t| accent(t, 14) }
accent(b(bars[0]), 34)                      # a big landing

# One-frame flash (records a :flash event, so the finish adds a punch + impact)
flash(b(bars[2]), PAPER)

# Light/dark spans: invert type colours while a light background is up (the template's bg + your own colour choice)
bg(PAPER, b(bars[1]), b(bars[1], 2))
text("INVERT", font: DISPLAY, size: 300, fill: INK, start: f(b(bars[1])), end: f(b(bars[1], 2)))
```

Root keys run after the nodes: `"particles": [{"count": 20000, "seed": 7, "color": "#30cbffb0", "size": 3, "speed": 100, "life": 7}]`
(a Metal field over everything), and `"effects": [{"name": "CIBloom", "parameters": {"inputRadius": 10, "inputIntensity": 0.35}}]` or
`{"name": "signal", "parameters": {"grain": 0.15, "scanlines": 0.12, "chromaticPixels": 2}}`. Prefer section-level grain and RGB through
the VFX finish instead of a global `signal`.

## Structure patterns from deadstar

- **A refine pass per section:** after a line-art section draws, scale its stroke widths by 0.5, shrink small type about its own centre,
  and add `glow`/`glowCore`, so the same section reads finely at 60 fps SS2 while poster sections keep their weight.
- **A prepended intro:** author the new opening at negative times (`-PRE..0`), then shift every `start`/`end`, track key and `reveal` key in
  the tree by `PRE` at the end of `build`. All earlier cue maths stays on the original clock.

  ```ruby
  def shift(n, dt, seen = {}.compare_by_identity)
    return if !n.is_a?(Hash) || seen[n]
    seen[n] = true
    %i[start end].each { |k| n[k] += dt if n[k].is_a?(Numeric) }
    n[:reveal] = n[:reveal].map { |t, *r| [t + dt, *r] } if n[:reveal].is_a?(Array)
    n[:tracks] = n[:tracks].transform_values { |keys| keys.map { |t, *r| [t + dt, *r] } } if n[:tracks]
    (n[:children] || []).each { |c| shift(c, dt, seen) }
  end
  ```

- **A timecode/HUD:** one small mono text node per 2 frames (`start: fr / FPS, end: (fr + 2) / FPS`), coloured by whether a light
  background is up. Keep it outside the camera group so it never shakes.
- **A recurring motif:** *deadstar*'s five-point star opens the video, becomes a constellation, shatters into shards at the first drop,
  returns as a stamp and a phone icon, and undraws in the last frame. Plan the motif's beats in `docs/PLAN.md`.
- **Calm beats:** leave a bar or two with one slow element before each peak. A constant blizzard of hits reads as noise.
