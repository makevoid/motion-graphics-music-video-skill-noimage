# MotionGraphics — native Swift graphics for music videos

A macOS 14+ Swift package with an object-oriented scene graph, deterministic animation, Quartz/Core Text drawing, Metal particle/compute stages, Core Image composition, and AVFoundation video I/O. No third-party Swift dependencies. `MotionGraphics` is the library; `mgraphics` is the CLI.

[Capability and migration map](../../../../../../docs/processing-native-map.md) · [Swift sources](Sources/MotionGraphics) · [Tests](Tests/MotionGraphicsTests)

## Run

From this directory:

```sh
swift build -c release
.build/release/mgraphics examples/futuristic.json --out futuristic.mp4 --frames 192
.build/release/mgraphics examples/overlay.json --out frames --width 320 --height 180 --frames 48 --only 0,24,47
.build/release/mgraphics examples/overlay.json --out overlay.mov --codec prores4444 --width 320 --height 180 --frames 48
.build/release/mgraphics examples/overlay.json --plate plate.mp4 --out composed.mp4 --width 320 --height 180 --frames 48
.build/release/mgraphics examples/particles.json --benchmark --width 1920 --height 1080 --frames 120
.build/release/mgraphics --analyze song.wav --out features.json --fps 24
swift test
```

From the containing `scripts` directory:

```sh
ruby mv.rb 'graphics:build'
ruby mv.rb 'graphics:render[tools/graphics/examples/futuristic.json,output/native.mp4,192,1920,1080,24]'
ruby mv.rb 'graphics:benchmark[tools/graphics/examples/particles.json,120,1920,1080,24]'
ruby mv.rb 'anim:render[tools/graphics/examples/overlay.json,output/frames,48,320,180]'
```

`Media::Anim` accepts native `.json` scenes only. Browser rendering and its dependencies have been removed. A project's `05_overlay.json` works with `anim:preview` and `anim:overlay`, including cue data and native audio. `anim:overlay` writes one final movie; it does not generate PNG layers or an intermediate still-plate movie. Only explicit previews/PNG exports create images. Keep only one `05_overlay.*` file per run. `graphics:render` also accepts `PLATE`, `AUDIO`, `CODEC`, and `ONLY` environment variables. New video files are never silently overwritten.

## Scene files

See the executable [overlay](examples/overlay.json), [complete futuristic scene](examples/futuristic.json), and [20,000-particle scene](examples/particles.json). The reference coordinate system is pixels with top-left origin, positive y down, clockwise positive rotation in radians, seconds for animation, and frame time `frame / fps`. Rectangles use their upper-left corner; circles/ellipses use their center; text uses its left baseline. Dimensions do not automatically rescale the scene; wrap it in a scaled group when needed.

Root keys:

| Key | Meaning |
| --- | --- |
| `version` | `1` (also the default) |
| `background` | Hex color; omitted means transparent |
| `nodes` | Ordered, nested drawing nodes; later siblings draw on top |
| `fonts` | Font files to register once; relative to the scene file |
| `particles` | Metal fields composited above all nodes; count, seed, color, size, speed, life |
| `effects` | Ordered Core Image filters: `name` plus `parameters`; applied to graphics before the plate |

Common node fields: `type`, `name`, `x`, `y`, `rotation`, `scale` or `scaleX`/`scaleY`, `anchor: [x,y]`, `opacity`, `start`, `end`, `blend`, `clip: [x,y,w,h]`, `tracks`, `children`. Visibility is `[start,end)`. Group opacity is isolated: overlapping children fade together. Blend modes: normal, screen, add, multiply, overlay, difference, exclusion, lighten, darken, erase.

Tracks have the form `"x": [[0, 100], [2, 800, "outCubic"]]`. Times must strictly increase. The destination key selects the segment's easing. Supported properties: x, y, rotation, scaleX, scaleY, opacity. Easing: linear, inCubic, outCubic, inOutCubic, outExpo, outBack, outElastic, smooth. Values clamp to endpoint keys. Swift `Track` additionally supports repeat periods. `entrance: "pop"|"slap"|"slam"` installs scale/opacity tracks starting at the node's `start`; it replaces tracks for those properties.

| Node | Additional fields |
| --- | --- |
| group | children |
| rect, square | width, height (rect), radius (corner rounding) |
| circle, ellipse | radius (circle), width/height (ellipse) |
| point | strokeWidth (diameter), fill |
| line, triangle, quad, polygon | points: `[[x,y],...]`; polygon accepts closed |
| spline | points (Catmull–Rom interpolation) |
| path | commands: `["M",x,y]`, `["L",x,y]`, `["Q",cx,cy,x,y]`, `["C",c1x,c1y,c2x,c2y,x,y]`, `["Z"]`; use multiple M commands for contours |
| arc | radius, arcStart, arcEnd, arcMode (open, chord, pie); nonuniform node scale makes elliptical arcs |
| star | radius, inner, rays |
| paper | width, height, seed, roughness |
| text | text, font (PostScript name), size, fill, outline, outlineWidth, reveal (track; spatial wipe) |
| image | path, width, height |
| sprite | path (directory of 0000.png...), frames, fps, width, height, loop, audioAt; alternatively clipName/clipData from external clip metadata |
| trace | points, color, strokeWidth, progress (track) |
| grid | width, height, spacing, color |
| reticle, flare | radius, color |
| waveform | samples or samplesData (external numeric array), width, height, color, progress |
| karaoke | words or wordsData (external `[{w,s,e},...]`), font, size |

All shape nodes accept `fill`/`stroke` (hex, or null to disable), `strokeWidth`, `dash`, `evenOdd`, and `gradient`. A linear gradient specifies `colors`, `from`, `to`; a radial gradient specifies `colors`, `center`, `radius`. Paths and gradients are constructed once. Unknown keys, node types, effects, and animated properties fail with an error. Fields belonging to other valid node types are not a strict per-type schema; consult this table.

Asset paths are relative to the scene JSON. External `--data name=file.json` paths are relative to the process working directory. Pipeline clip metadata `dir` is also relative to that working directory. Sprite `audio_at` is honored; use x/y/width/height for placement (automatic `src`/`box` placement is available via Swift arithmetic, not a JSON option).

Filters use native Core Image input names, e.g. `{"name":"CIBloom","parameters":{"inputRadius":12,"inputIntensity":0.5}}`. Numeric arrays become CIVectors, hex strings become CIColors. `{"name":"signal","parameters":{"grain":0.15,"scanlines":0.12,"chromaticPixels":2}}` runs a fused Metal pass. The filter chain is cropped to the original canvas; leave padding if glow must extend around the edges. Unsupported Metal features fail explicitly; there is no silent CPU particle fallback.

## Swift authoring

Add this directory as a local SwiftPM dependency and depend on the `MotionGraphics` product:

```swift
import MotionGraphics
import CoreGraphics
import CoreImage

let canvas = try Canvas(width: 1920, height: 1080)
let scene = Scene()
let hud = try Designs.reticle(radius: 200)
hud.position = CGPoint(x: 960, y: 540)
hud.tracks["rotation"] = try Track([
    Keyframe(0, 0), Keyframe(8, .pi * 2)
], repeatDuration: 8)
try scene.root.add(hud)
let label = TextNode("TRANSMISSION", font: "Menlo", size: 48)
label.position = CGPoint(x: 80, y: 120)
try Designs.entrance(label, start: 0.2, kind: "slap")
try scene.root.add(label)
try scene.draw(on: canvas, at: FrameTime(frame: 48, fps: 24))
try canvas.writePNG(to: URL(fileURLWithPath: "frame.png"))
```

Subclass `Node` and override `draw(on:at:)` for new instruments, charts, generative geometry or characters. `update` supports analytic animation from absolute time; avoid accumulating position per frame if sparse previews must match sequential output. Mutate/render each scene on one thread. A node has one parent and cycles are rejected. Share immutable `Path`, `TextLayout`, `ImageAsset` and Gradient objects between nodes; build or explicitly invalidate them outside the frame loop.

`Canvas` also supports immediate drawing, `withState`, affine transforms, shear, clips and arbitrary native CGContext operations. `Path` supports cubic/quadratic curves, splines, contour subpaths, Bézier evaluation/tangents, stars and seeded paper outlines. `TextLayout` exposes cached Core Text shaping, metrics, and glyph paths; `Motion.typed` reveals Unicode graphemes. `Color` supports RGBA, HSB, interpolation and hex. `Random`/`Noise` are seeded native algorithms, not bit-identical p5 implementations. Swift `simd` supplies vectors, matrices and quaternions without a wrapper allocation per point.

Compose independently rendered layers with `Composition` and its ordered `VectorLayer`, `StillLayer`, `MovieLayer`, and `GeneratedLayer` objects. These build a lazy Core Image graph entirely in memory; `GeneratedLayer` directly wraps Metal/3D texture producers without a CPU readback. Each layer has timing, a top-left affine transform, opacity, blend mode, alpha mask, effects, and an update callback. Consume `composition.image(at:)` with `VideoWriter.append` using `composition.compositor`. Multiple MovieLayers keep independent bounded streaming readers. Use `ImageAsset.rasterize` to explicitly cache a static vector subtree once. `Compositor.composite` also supports direct alpha masks and opacity. `EffectChain` accepts any `ImageEffect`. `MetalEffect` compiles custom MSL once: read source texture(0), write destination texture(1), read float4(width,height,time,0) at buffer(0); bounds-check your grid coordinates. Its output texture, the particle texture, and the 3D texture are reused: **consume each returned CIImage before rendering the next frame on that object**. The current GPU stages wait at stage boundaries for safe resource reuse; they do not promise asynchronous multi-frame GPU pipelining.

For direct movie output from the `scene` above, use an async Swift entry point. This writes one movie and keeps its layers and frame buffers in memory:

```swift
let composition = try Composition(width: 1920, height: 1080)
composition.background = .black
composition.layers = [try VectorLayer(scene, width: 1920, height: 1080)]
let writer = try VideoWriter(url: URL(fileURLWithPath: "scene.mp4"),
                             width: 1920, height: 1080, fps: 24)
for frame in 0..<192 {
    let image = try autoreleasepool {
        try composition.image(at: FrameTime(frame: frame, fps: 24))
    }
    try await writer.append(image, frame: frame, compositor: composition.compositor)
}
try await writer.finish()
```

`Scene3D` exposes SCNScene/SCNNode, camera, geometry, lights, materials, model loading and a retained Metal target. Use `.box`, `.sphere`, `.ellipsoid`, `.plane`, `.cone`, `.cylinder`, `.torus`, or native SCNGeometry. Animate transforms explicitly; SceneKit actions are stateful, and imported animations need scene-time timing for deterministic seeking. SceneKit is deprecated in new SDKs, so this adapter is isolated from the 2D renderer. It is a Swift API, not a JSON node. GPU renderer tests verify it on the current macOS host.

## Video, audio and performance

PNG and ProRes 4444 MOV preserve transparency. H.264/HEVC are opaque and flatten graphics over black when no plate exists. AVAssetWriter chooses the available encoder; hardware encoding is not guaranteed. Output is SDR sRGB/Rec.709 with 8-bit BGRA encoder buffers; Metal intermediates are half-float, but this is not an HDR mastering pipeline.

`VideoSource` streams with one-frame lookahead, honors orientation, center-crops to fill, and holds the last frame after EOF. It requires nondecreasing times; reopen to seek backward. `VideoWriter` requires contiguous frame indices starting at zero. Fractional fps timestamps use a 600,000-unit timebase. `AudioSource` interleaves audio in the same writer as video: AAC passes through when starting at zero; trimmed ranges and other formats including WAV decode to PCM and encode to AAC in memory. Audio and picture are fed independently with bounded writer backpressure. Longer audio is trimmed and remaining video after shorter audio is silent. `AudioMuxer` remains an optional utility for already-existing movies; the default workflow does not need a second mux file. Explicit `--audio` replaces inherited plate audio.

`AudioAnalyzer` streams PCM and uses Accelerate for RMS, peaks and spectral bands, with absolute sample boundaries to prevent frame-rate drift. DFT output is a visual control signal, not calibrated loudness. `samplesData` accepts a numeric array: extract `rms` from analyzer output for a whole-song waveform or use Swift to select per-frame bands. Existing Python beat/onset tools remain available; automatic beat detection is not part of the native analyzer.

Quartz bitmap paths/text still rasterize on the CPU. The compositor and particles use Metal when available. Reuse a canvas, compositor, filters, fonts, geometry, and textures; sprite caches are bounded (8 frames by default). There is one object per logical scene node, **not one object per particle**. Direct movie output avoids PNG compression, base64, browser RPC, and image-file round trips. No frames are accumulated before export.

`--benchmark` forces rendering but omits file encoding; its reported fps excludes startup and scene preparation. The historical comparison used matching 500-circle geometry through both export paths before the browser backend was deleted. `examples/benchmark.json` remains for native regressions; rasterization was not pixel-identical. See the repository capability map for measured results and limits.

Tests cover alpha/orientation, isolated groups, clipping/contours, state restoration, graph ownership, frame seeking, sprites, text, noise, JSON errors, Metal compute/particles, native 3D, H.264 frame count, ProRes alpha, fractional fps and audio analysis. Tests also check in-memory layer transforms, AAC passthrough, shorter audio, PCM trimming and color-preserving video round trips. Metal/video tests need access to macOS graphics/codec services; a restrictive sandbox may hide those services even on a supported Mac.
