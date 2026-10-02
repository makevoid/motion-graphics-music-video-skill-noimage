# Animation, audio and effects recipes

## Separation of work

H3 supplies expressive, self-contained characters on chroma green; Swift graphics supplies the world around them: exact timing, camera movement, environments, props, text, diagrams and layer order. A full-frame H3 plate is a justified exception, not an equal option (see "Self-contained characters" in [prompts.md](prompts.md)). Python removes backgrounds, measures audio and composites sound. Swift applies final frame-cued camera, light and signal effects. Ruby services own all execution and manifests.

## Native Swift scenes and overlays

Use `tools/graphics` for native macOS drawing and composition. Its `MotionGraphics` library provides retained paths, Core Text, scene nodes, keyframes, sprite caching, Metal particles/compute effects, 3D, Core Image layers and AVFoundation export. See `tools/graphics/README.md` in the runtime for the full API and scene-file reference.

Use `05_overlay.json` with `anim:preview` / `anim:overlay`. Final rendering streams layers and audio directly into one movie; preview images are written only on request. `--data` word, tracking and clip JSON remains available to the native scene loader; `wordsData` and `clipName` consume captions/sprites directly, while tracking arrays require custom Swift logic. JavaScript scenes must be ported; no browser runtime remains.

For a complete scene or direct native movie export:

```sh
ruby scripts/mv.rb 'graphics:build'
ruby scripts/mv.rb 'graphics:render[tools/graphics/examples/futuristic.json,output/native.mp4,192,1920,1080,24]'
```

`PLATE=plate.mp4` composes over a source video and inherits its audio. `AUDIO=song.m4a` replaces audio. `CODEC=prores4444` with a `.mov` output preserves alpha; H.264/HEVC are opaque. Scene JSON paths are relative to the scene file. Font files register once through the scene's `fonts` array; text uses the registered PostScript font name. Choose assets, colors and typography to suit the approved direction; the futuristic examples are optional demonstrations.

### Project fonts

Just before rendering the video, scan installed macOS fonts and copy only the selected faces into the initialized video workspace:

```sh
ruby scripts/mv.rb --project /absolute/video-workspace fonts:list
```

This recursively lists `.ttf` and `.otf` files under `/System/Library/Fonts` (including `/System/Library/Fonts/Supplemental`), `/Library/Fonts`, and `~/Library/Fonts`. Choose actual files from the results for the approved typography and required characters. Font collections (`.ttc`) are excluded; do not rename a collection to `.ttf`. On another OS, select installed TTF/OTF files from that system's font directories.

Write `config/fonts.json` in the video workspace, mapping each project filename to its selected absolute source path. For example, **only if this file appeared in the scan**:

```json
{"title.ttf": "/System/Library/Fonts/Supplemental/Arial Bold.ttf"}
```

```sh
ruby scripts/mv.rb --project /absolute/video-workspace 'fonts:copy[config/fonts.json]'
```

The task copies the selected files to that workspace's `tools/graphics/fonts/`, reports source paths and SHA-256 hashes, and refuses to replace different existing font bytes. JSON preserves source paths containing spaces or commas. Record the selection in `docs/PLAN.md`, retain applicable license notices, and keep local font files out of the plugin repository. No font installation or download happens during `setup`.

Register the copied font paths once through the scene JSON `fonts` array (paths relative to that JSON file), and use their PostScript names in text nodes. Preview representative lyrics, punctuation and non-Latin characters before rendering.

A sprite node uses `clipName` to read the pipeline's clip metadata, preserves its `audio_at`, and keeps only a bounded cache of decoded frames. Place it with x/y/width/height; use metadata `box`/`src` to calculate original-source framing. Keyframe tracks animate position, scale, rotation and opacity. Draw background → distant graphics → behind-character text → sprite → foreground captions. See `tools/graphics/README.md` for the complete schema, node types, filters and Swift extension APIs.

```json
{"version":1,"nodes":[
  {"type":"sprite","clipName":"sing","x":1000,"y":150,"width":600,"height":820,
   "tracks":{"x":[[0,1000],[2,1100,"outCubic"]]}},
  {"type":"karaoke","wordsData":"words","x":200,"y":1000,"size":48}
]}
```

The library includes cached glyph outlines, starbursts, traces, paper shapes, misregistration, deterministic shake, entrance tracks, waveform drawing, captions, reticles, gradients, flares and GPU grain. Keep the lead's mouth large enough to review. Render only selected event frames for diagnostics; do not export every intermediate layer to disk.

Choreography recipes: a mascot runs at the head of a curve leaving a trail; a fall accelerates the camera/world while holding the character in the focal area; a reveal zoom shows the whole diagram; a crowd pose swap ripples outward; a word appears behind hair via layer order. Tie entrances to actual words and beat accents. When text is used, check spacing and readability with the selected font and treatment. Check all important event frames with `anim:preview`, then watch the complete section.

## Character cutouts and lipsync

Remove detached generated captions from an existing alpha sequence with `media:keep_component[source_dir,new_out_dir,seed_x,seed_y]` through the Ruby CLI. It keeps exact RGBA values of the four-connected nonzero-alpha silhouette containing the seed; no dilation joins text back to hair or props. Choose a torso pixel occupied in every frame. Missing/transparent seeds fail explicitly, and sources remain unchanged. This cannot remove lettering touching the body, instrument or hair: use a deliberate mask or revise the asset. Inspect all motion afterward, including semi-transparent edges and moving limbs.

Use chroma green for cream/white faces/clothes; paper keying can erase them. Inspect the alpha matte, hair, hands, feet and spill over light/dark backgrounds. `media:sprite_box` helps estimate source-pixel bounds; `box` is a crop and `seed` chooses the connected paper-key component. Recut locally before paying to regenerate a good H3 performance.

H3 may invent captions or interface elements even when the prompt forbids text. Inspect the entire performance, including initially empty space. Disconnected text in a keyed sprite can be removed locally with a reviewed mask/component filter; check moving fingers, hair and instrument tips before accepting the cleanup. A deliberately designed opaque Swift graphics panel can cover unwanted background UI when it preserves the subject and fits the composition. If unwanted text intersects the face/body and cannot be repaired cleanly, use the approved regeneration allowance. Keep lyric typography under Swift graphics control.

Use Demucs vocals aligned to the full song, not separately offset clips. Set `audio_at` in section-local seconds; the service adds `music_offset`. Gate modestly only if instrumental bleed causes mouthing in pauses. Short tail audio must be padded to meet H3's two-second input minimum. Use visible lips, jaw motion, brows, head/shoulder acting, anticipation and follow-through. At song peaks synchronize articulation and the acting accent, then add Swift graphics camera/graphics around it.

`media:mouth` correlates darkness in a mouth crop against vocal energy at 24fps, checking lags from -6 to +6 frames. Supply a mouth ROI in the **cutout image's coordinates** and the full-song audio start. It is a heuristic for static framing and sufficiently visible dark mouth shapes. Moving faces, low contrast and synthetic silence can make it inconclusive. Verify phonemes/visemes and pauses by watching with audio. Fix timing errors at the source; never stretch the master song or speed-change visible singing.

## Sound and assembly

Keep `audio/song.wav` as the full master. Use integer frame sections; unbroken-song assembly validates each section's frame count and contiguity, joins picture and muxes one continuous song. Do not concatenate independently encoded/faded audio segments. Preserve the original input and derived vocals separately. Keep a clean render before sound effects.

`prompts/finish-sfx/sfx.yml`:

```yaml
source: output/clean.mp4
out: output/with-sfx.mp4
rel_db: -6
peak_db: -6
max_gain_db: 18
sounds:
  pop: {prompt: "One short dry cartoon cork pop, isolated, no music or voice", duration: 2, seed: 7}
  flatline: {tone: 1000, duration: 1}
  swoosh: {synth: whoosh, duration: 0.7, peak: 0.75, from: 300, to: 4200, seed: 2}
  boom: {synth: impact, duration: 0.9, freq: 48}
cues:
  - {at: 1.25, sound: pop, rel_db: -5, len: 0.25, fade: 0.03}
  - {at: 3.475, sound: swoosh, rel_db: -12}   # 3.475 = hit 4.0 - peak 0.525 s: the whoosh crests on the hit
  - {at: 4.0, sound: boom, rel_db: -8}
```

Stable Audio SFX is paid; a steady tone and `synth:` sounds are made locally for free. `synth:` is the Swift `SoundSynth` (`mgraphics --sfx`, [Synth.swift](../scripts/tools/graphics/Sources/MotionGraphics/Synth.swift)): whoosh, riser, reverse, impact, subdrop, tick, type, zap, glitch and shimmer, each with `duration`, `seed` and its own knobs (frequencies, `peak`, `pan`, `q`). It is deterministic, and the cached sidecar records `peak_at`, the loudest moment. A cue's `at` is where the sound starts (leading silence is trimmed), so start a whoosh at `hit - peak_at`, and a riser or reverse at `hit - duration`. Keep whooshes subtle (`rel_db` around -10 to -14) so they sit under the music. SFX are cached by prompt, duration, seed and negative prompt. Mix trims leading silence, sets cue loudness relative to music in that window, caps gain and peak-limits. Use exact song times, not cut-relative times. Check dialogue intelligibility, silence jokes and audible but subordinate effects. The final mux can add codec peaks, so listen and measure the delivered file if close to full scale.

## Swift VFX and native light layers

`prompts/finish-vfx/cues.yml`:

```yaml
source: output/with-sfx.mp4
out: output/finished.mp4
cues:
  - {fx: punch, f: 24, dur: 8, amt: 0.05, radius: 2}
  - {fx: glow, f: 27, dur: 12, amt: 0.4, radius: 12}
  - {fx: dark, f: 144, dur: 3, hold: 1, amt: 0.8}
```

Core Image supports `punch`, `zoom`, `shake`, `whip`, `mblur`, `edgeblur`, `glow`, `flash`, `dark`, `rgb`, `glitch`, `tv`, `grain`. `f`/`dur` are integer frames; `pre` starts a transition early. See `tools/vfx/Sources/mvfx/Effects.swift` for exact knobs. `leak`, `flare`, `glints` are built-in native light cues. Their cached paths/gradients are sampled in memory and screen-blended directly; no light-frame PNGs are produced. Optional `lights: path/to/scene.json` adds a custom native light scene.

The Swift service builds the package through Ruby, uses AVFoundation decode/encode and streams audio into the same writer. Inspect a short clip and stills before the full render. Use distinct output paths for every finish revision. Effects should follow onsets/cuts/lyrics; start glow after a flash to avoid whiteouts, avoid double grain if Swift graphics already draws it, and preserve deliberate quiet frames. A no-cue VFX render should resemble the clean encode; cued frames should differ measurably, which RSpec checks.
