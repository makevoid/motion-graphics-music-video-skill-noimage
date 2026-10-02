# Native workflow: a music video drawn entirely in Swift

This is the production path for this macOS skill. It makes a complete video from the song alone: no image or video models, no
paid calls and no API key. Every picture is vector or Metal graphics drawn by the bundled Swift renderer (`tools/graphics`).
Ruby services run every stage, and the Swift synth and VFX finish it. The steps below are the process that made the
*deadstar* video (117.5 s of beat-synced neon line art, 60 fps 1080p), written generically for a new song.

Run every command through the resolved absolute `scripts/mv.rb` from SKILL.md. The examples below abbreviate it as
`mv` and assume `--project /abs/project` (`P`).

| Stage | Tool (through `mv.rb`) | Output |
|---|---|---|
| 1 Project | `init`, `setup`, `doctor` | self-contained project with its own `lib/` and `tools/` |
| 2 Listen and map | `audio:analyze`, `media:stems_local`, `audio:map`, `audio:excerpt` | `audio/song.wav`, `audio/map/*.json`, `audio/excerpt.wav`, `docs/TIMING.md` |
| 3 Research and plan | web search, `assets/plan-template.md` | `docs/RESEARCH.md`, `docs/PLAN.md`, user approval |
| 4 Fonts | `fonts:list`, `fonts:copy` | `tools/graphics/fonts/*.ttf` |
| 5 Scene | `scenes/<name>.rb` (from [scene-template.rb](../assets/scene-template.rb)) | `scenes/<name>.json`, `scenes/<name>.events.json` |
| 6 Preview loop | `graphics:preview`, `media:frame`, `media:sheet` | drafts of the changed range |
| 7 Final | `graphics:render` (`SUPERSAMPLE=2`, delivery fps) | `output/<name>_clean.mp4` |
| 8 Finish | `scenes/finish_cues.rb` (from [finish-cues-template.rb](../assets/finish-cues-template.rb)), `sfx:gen`, `sfx:mix`, `vfx:render` | `_clean_sfx`, `_clean_finished_plain`, `_clean_finished` |
| 9 Review and deliver | `media:sheet`, `media:montage`, `media:twitter`/`media:youtube` | contact sheets, `docs/REVIEW.md`, a delivery folder |

## 1. Project

```sh
mv init --project /abs/project --song /abs/song.mp3 --prompt-file /abs/brief.md
mv --project /abs/project setup        # bundler, Python venv, both Swift packages (~30 s warm)
mv --project /abs/project doctor
```

`init` copies the Ruby runtime and Swift tools into the project, and `mv.rb --project` runs **the project's copies**. If you change the skill's
`scripts/lib` or `scripts/tools` afterwards, copy those files into the project as well (rsync `tools/graphics/Sources/`) and check that
`mv --project P -T` lists any new task.

## 2. Listen and map the music

```sh
mv --project P 'audio:analyze[audio/source.mp3,audio]'            # decode to audio/song.wav, rough beats/energy
mv --project P 'media:stems_local[audio/song.wav,audio/stems,0,0]' # Demucs: vocals, drums, bass, other, no_vocals (free, ~1 min)
mv --project P 'audio:map[audio/song.wav,audio/map,audio/stems]'  # beatmap, hits, vocals, sections (~2 s)
mv --project P 'audio:excerpt[audio/song.wav,audio/excerpt.wav,23,30,1.5]'  # from 23 s, 30 s long, 1.5 s fade-out
```

- **`beatmap.json`**: a drift-following beat grid with bar numbers and downbeats. Generated songs move a fraction of a BPM at section
  joins, which a single global grid turns into 100+ ms of error, so key every cue to this map and never to `60/bpm * n`.
- **`hits.json`**: kick, snare and hat attack times with strength `s`, plus a 16-step pattern for each bar.
  - Use the attacks for flashes and camera hits.
  - Kicks fused with an 808 may be missing; then use strong snares or the `bass` notes.
- **`vocals.json`**: lyric lines, phrases and onsets. Put word slams on vocal onsets.
- **`sections.json`**: drop/build/breakdown/groove labels per bar, with energy. These are heuristics, so confirm them by listening.

Listen to the whole song and choose the excerpt at musical boundaries: start on a downbeat or a pickup, and end after a phrase with a fade.
The excerpt `from` becomes `SONG_START` in the scene, and its length becomes `DURATION`. Record the song times, bars, BPM drift and key
moments (drop, peaks, breaks, last hit) in `docs/TIMING.md`.

For lyric copy, use the user's lyrics or `audio:transcribe_local` (mlx-whisper). Check the words by listening, because sung words get hallucinated.

## 3. Research, plan, approval

Search the web for the song's subject and phrases. Collect concrete facts, metaphors and visual jokes in `docs/RESEARCH.md` with URLs.
*deadstar* used real astronomy: lookback time, the gold in a phone coming from a kilonova, and Betelgeuse's distance. Each fact became a
section with an on-screen line.

Write `docs/PLAN.md` from [the plan template](../assets/plan-template.md). It should cover:
- the style bible: palette hex values, line weights, glow, typography, and texture rules;
- a section-by-section storyboard keyed to bars;
- the recurring motif and its payoff;
- the opening hook and the core peak;
- calm beats;
- the SFX/VFX approach;
- the deliverables.

The native path has no generation budget, but a new creative direction still needs the user's approval before the full build. Show a
preview of the opening section with the plan when that helps the decision.

## 4. Fonts

```sh
mv --project P fonts:list                      # installed TTF/OTF only (no .ttc)
# write config/fonts.json: {"display.ttf": "/System/Library/Fonts/Supplemental/Impact.ttf", "mono.ttf": "/System/Library/Fonts/Supplemental/Andale Mono.ttf"}
mv --project P 'fonts:copy[config/fonts.json]'
```

Register the files in the scene's `fonts` array (`../tools/graphics/fonts/<file>` from `scenes/`) and use their **PostScript names** in text nodes
(for example `Impact`, `AndaleMono`, `Arial-Black`, `DINCondensed-Bold`). An unknown name fails the render; it never silently falls back.

## 5. Write the scene generator

Do not hand-write thousands of JSON nodes. Write a Ruby generator that emits them:

```sh
mkdir -p P/scenes && cp P/.skill/assets/scene-template.rb P/scenes/video.rb   # init also copies the skill's assets/ into P/.skill/
# edit SONG_START, DURATION, palette, fonts, PLAN and the section methods
cd P && ruby scenes/video.rb          # -> scenes/video.json + scenes/video.events.json
```

The template runs as-is on any mapped song: a starfield intro, word slams, a nebula and an outro. Use it as the skeleton:

- **Clock.** All times are video seconds (0 = `SONG_START` in the song). `MusicMap` shifts the map once. `b(bar, beat)` returns the time
  of a beat in **the song's own bar numbers** (fractional beats work: `b(40, 2.5)`), and `hits("snare", s, e)` lists attacks.
- **Snap to frames.** Wrap `start` and `end` in `f(t)`, which floors them to the delivery-fps frame, so an element appears on the frame
  that contains the beat rather than one frame late.
- **Sections.** Each section is a method `(s, e, bars)` that draws only inside `[s, e)` and starts with its own background. `PLAN` lists
  them in order with bar lengths. Sections start on downbeats.
- **Events.** Call `event(kind, t, ...)` for every picture event that should get sound or VFX: `flash`, `word`, `typed` with key times,
  `accent`, and `section` with `big:`/`neon:` flags. `finish_cues.rb` reads them, so sound and VFX follow the picture automatically.
- **Camera.** `accent(t, amp)` records a hit. `camera(@nodes)` wraps everything in one group with a decaying hold-frame shake and a
  scale punch. Backgrounds are oversized rects (`rect`), so the shake never shows an edge.
- **Determinism.** Use the seeded `rand` only. Every frame is a pure function of time, which makes parallel chunks, sparse stills and
  previews match the master exactly.
- **Line art for 60 fps.** Draw thin strokes (1–3 px), then call `neon(nodes, glow: 9, core: 0.55)`. Render finals at `SUPERSAMPLE=2`.
  Poster type and big fills never glow.
- **Safety.** If the video flashes or strobes, keep `epilepsy_warning` in the opening seconds. Keep strobes under 3 per second.

Grow the helpers as the video needs them. *deadstar* added photon type (letters flying into a typebox on cues), odometers, stamps, wire
globes, a timecode HUD, and a `refine` pass that thins a whole section for the 60 fps master. Recipes are in
[scene-cookbook.md](scene-cookbook.md). The node schema and every key are in `tools/graphics/README.md` in the project. Unknown keys and
types fail loudly.

## 6. Preview loop (every iteration)

```sh
cd P && ruby scenes/video.rb
AUDIO=audio/excerpt.wav mv --project P 'graphics:preview[scenes/video.json,output/preview.mp4,7.4,14.1]'   # only the changed section
mv --project P 'media:frame[output/preview.mp4,2.5,output/check.png]'      # a still, then look at it (Read the PNG)
mv --project P 'media:sheet[output/preview.mp4,output/sheet.jpg]'          # 5x2 contact sheet
```

- A preview renders at 1×, 30 fps, with the soundtrack cut to the range.
  - It is about 4–6× faster than a final: *deadstar*'s whole 117.5 s preview took 50 s, and a 30 s template preview takes ~10 s.
  - Times inside a preview restart at 0, so a still at `t` in the preview is scene time `from + t`.
- For exact single frames of the master, use `ONLY=1440,1441 mv … 'graphics:render[scenes/video.json,output/stills,…,1920,1080,60]'`.
- Check, at minimum:
  - every hit lands on its beat (watch with sound);
  - type is readable and nothing overlaps text;
  - nothing leaves the frame by accident;
  - section boundaries are clean;
  - the motif carries through;
  - there are calm beats;
  - no unintended white frames.
- Render the final only when the user approves the previews or asks for it.
- Never render over a delivered final; use a new output name. Ask before re-rendering if a delivered master might be overwritten.

## 7. Final master

```sh
# frames = DURATION * fps (117.5 s at 60 fps = 7050)
JOBS=8 AUDIO=audio/excerpt.wav SUPERSAMPLE=2 BITRATE=15000000 \
  mv --project P 'graphics:render[scenes/video.json,output/video_clean.mp4,1800,1920,1080,60]'
```

- `JOBS` splits the render into parallel chunks and joins them by stream copy. Rendering uses the GPU by default (`GLOW=cg` is for an
  A/B check).
- Measured on *deadstar*: 7050 frames at SS2 in 230 s. The finish chain adds ~1.5 min.
- The same JSON renders 24, 30 or 60 fps, because nothing in the scene is frame-based.

## 8. Finish: SFX and VFX from the picture's own events

```sh
cp P/.skill/assets/finish-cues-template.rb P/scenes/finish_cues.rb
cd P && ruby scenes/finish_cues.rb output/video_clean.mp4          # writes prompts/finish-sfx, finish-vfx, finish-vfx-plain
SFX=finish-sfx mv --project P sfx:gen                               # Swift SoundSynth: free, deterministic, cached
SFX=finish-sfx mv --project P sfx:mix                               # -> output/video_clean_sfx.mp4
VFX=finish-vfx-plain mv --project P vfx:render                      # -> output/video_clean_finished_plain.mp4
VFX=finish-vfx mv --project P vfx:render                            # -> output/video_clean_finished.mp4 (with Metal shaders)
```

- The template maps events to sound and picture:

  | Event | Sound | Picture |
  |---|---|---|
  | Section change | whoosh cresting on the downbeat | — |
  | Big landing | riser → impact + sub drop | zoom creep, then an RGB kick, a shockwave and a lens kick |
  | Flash | soft impact | punch, then glow 2 frames later |
  | Word slam | — | stretch |
  | Typing | quiet keys | — |
  | Neon section | — | streaks for its length |
  | End | — | a dark fade |

- After `sfx:gen` writes each sound's `peak_at` sidecar, rerun `finish_cues.rb` and `sfx:mix`, so whooshes crest exactly on the beat.
- VFX `f`/`dur` are frames on a 24 fps cue grid at any video rate.
- Spot-check with `VFX=finish-vfx mv --project P 'vfx:stills[168,170]'` or `'vfx:clip[150,200]'` before a full render.
- The knobs for every effect and synth are in [animation-audio-vfx.md](animation-audio-vfx.md).
- Keep whooshes at −10 to −14 dB relative to the music. Never put bloom on a flash frame. Put texture (grain, bands, RGB) on a few
  chosen sections, not everywhere.

## 9. Review and deliver

- Make contact sheets of the finished file (`media:sheet`; or `media:montage` for frame-exact strips around a hit).
- Watch the opening, the peak and the ending with sound.
- Log each version in `docs/REVIEW.md`: what changed, render times, known issues.
- Deliver into a folder:
  - `<name>_vN_60fps_shaders.mp4`: finished, with shaders;
  - `<name>_vN_60fps.mp4`: plain finish;
  - `<name>_vN_60fps_clean.mp4`: no SFX/VFX;
  - a contact sheet, plus `PLAN.md`/`RESEARCH.md`/`REVIEW.md`.
- Use `media:twitter` (any source to X spec: H.264 High, ≤ 60 fps, ≤ 25 Mb/s, AAC, faststart; see [tasks.md](tasks.md)) or `media:youtube` for platform encodes. Save them under new names next to the finals.

## Gotchas

- Rake runs a task once per process: run each differently parameterized call in its own `mv` invocation.
- Quote bracket tasks in zsh.
- Scene asset/font paths are relative to the scene JSON. `--data` paths are relative to the working directory.
- A shader inside a fading group, clip, 3D plane or blend mode falls back to the slower CPU path. That is correct, only slower.
- The renderer keeps no state between frames. Animate from absolute time (tracks, `sample_track`), never by accumulating per frame.
- For a prepended intro, author it at negative times and shift every time in the tree once at the end (*deadstar*'s `shift`;
  see the cookbook), so the cue math stays on the original clock.
