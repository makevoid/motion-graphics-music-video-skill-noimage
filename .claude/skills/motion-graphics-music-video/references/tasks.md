# Ruby entry points and task recipes

## Directory layers

```text
motion-graphics-music-video/
  SKILL.md
  references/                    agent instructions
  assets/plan-template.md        planning document template
  assets/scene-template.rb       runnable scene generator skeleton (copy to <project>/scenes/)
  assets/finish-cues-template.rb SFX/VFX cue sheets from the scene's events (copy to <project>/scenes/)
  scripts/
    mv.rb                        Ruby CLI/bootstrap/project initializer
    Rakefile                     require Ruby task registry; install delegates
    Gemfile + Gemfile.lock        Ruby dependencies, including RSpec
    requirements.txt             Python dependencies installed by Ruby setup
    lib/
      tasks.rb                   thin rake declarations
      toolkit/                   task application services and test runner
      workflow/                  plan approval and wave allocation
      pipeline/                  project, steps, manifests, generation/editing
      fal/                       Ruby HTTP queue/storage/model adapters
      media/                     Ruby wrappers that shell out
    tools/
      python/                    analysis, cutouts, tracking and audio mixing
      graphics/                  Swift library/renderer, JSON examples; project fonts copied before rendering
      vfx/                       Swift package and Core Image effects
    spec/                        high-level RSpec contracts and E2E tests
```

`init` copies the executable toolkit to a new project with the same `Rakefile → lib → tools` layers and adds `config/`, `audio/`, `prompts/`, `docs/`, `output/`. It excludes installed dependencies, build caches, generated outputs and test scratch data. Each project is self-contained; install dependencies there with `setup`. Ruby 3.2+ is required by the OOP code. Run the CLI using the same Ruby used for Bundler.

All examples below are executed from the skill directory. Replace `/absolute/project` with the real initialized project path. `ruby scripts/mv.rb --project /absolute/project 'TASK[...]'` and, inside the project, `bundle exec rake 'TASK[...]'` are equivalent. CLI flags precede/follow the task; task arguments use Rake brackets. Quote bracket expressions in zsh. For file names containing commas, rename/copy the input in Ruby before using Rake's comma-separated arguments.

For plugin use, adapt Fal-facing recipes to the `music-video` server's `run_task` tool and poll `task_status`, as described in [credentials.md](credentials.md). The MCP process receives the sensitive plugin key; ordinary Bash calls do not. Local recipes keep using the resolved absolute Ruby entry path from `SKILL.md`.

## Setup and inspection

```sh
ruby scripts/mv.rb --help
ruby scripts/mv.rb -T
ruby scripts/mv.rb --project /absolute/project setup
ruby scripts/mv.rb --project /absolute/project doctor
ruby scripts/mv.rb --project /absolute/project openapi:fetch
ruby scripts/mv.rb --project /absolute/project openapi:summary
```

`setup` calls Bundler and Python venv/pip through Ruby, then builds both Swift packages. Install system Ruby, FFmpeg/ffprobe, ImageMagick and Swift/Xcode command line tools on macOS 14+ beforehand. `MV_PYTHON` overrides the local `.venv/bin/python3`; `MEDIA_FONT` overrides the detected font path. Configure the plugin's sensitive `FAL_AI_API_KEY` option, or set `FAL_AI_API_KEY` in the environment for direct developer CLI calls; never put the key in prompts/config/commits. `doctor` prints JSON booleans; `STRICT=1` makes missing dependencies fail. Tests require the full selected profile's tools and do not silently skip missing dependencies.

`fonts:list` scans installed macOS TTF/OTF files. Just before rendering, `fonts:copy[config/fonts.json]` copies a JSON mapping of project filenames to absolute source paths into the video's `tools/graphics/fonts/`. Run with `--project /absolute/video-workspace`; see [Project fonts](animation-audio-vfx.md#project-fonts). Setup does not fetch fonts.

## Native scenes, previews and finals (default workflow)

The step-by-step process is in [native-workflow.md](native-workflow.md); the recipes are in [scene-cookbook.md](scene-cookbook.md).

```sh
cd /absolute/project && ruby scenes/video.rb      # the scene generator: writes scenes/video.json + scenes/video.events.json
AUDIO=audio/excerpt.wav ruby scripts/mv.rb --project /absolute/project 'graphics:preview[scenes/video.json,output/preview.mp4,0,10]'
ONLY=600,601 ruby scripts/mv.rb --project /absolute/project 'graphics:render[scenes/video.json,output/stills,1800,1920,1080,60]'
JOBS=8 AUDIO=audio/excerpt.wav SUPERSAMPLE=2 BITRATE=15000000 ruby scripts/mv.rb --project /absolute/project 'graphics:render[scenes/video.json,output/video_clean.mp4,1800,1920,1080,60]'
FROM=1440 SUPERSAMPLE=2 ruby scripts/mv.rb --project /absolute/project 'graphics:benchmark[scenes/video.json,48,1920,1080,60]'
cd /absolute/project && ruby scenes/finish_cues.rb output/video_clean.mp4
```

- `graphics:preview[scene,out,from_s,to_s]` renders a draft at 1× and 30 fps, with the `AUDIO` cut to the range.
  `FPS`/`SUPERSAMPLE`/`WIDTH`/`HEIGHT`/`JOBS`/`GLOW` override the defaults.
- `graphics:render[scene,out,frames,width,height,fps]`:
  - takes `frames` as video seconds × fps;
  - writes a PNG directory when `out` has no movie extension (with `ONLY`, only the listed frames);
  - accepts `PLATE`, `AUDIO`, `CODEC=prores4444` (`.mov` with alpha), `SUPERSAMPLE`, `BITRATE`, `GLOW=gpu|cg` and `JOBS` (parallel chunks).
- `graphics:benchmark` reports fps without writing files.
- The scene generator and `finish_cues.rb` are plain Ruby scripts inside the project. They only write JSON/YAML; rendering still goes
  through `mv.rb`.

## New run configuration (optional Fal character path)

When regenerating a video with approved character sheets and their original Fal manifests, register those identities locally without uploading again:

```sh
ruby scripts/mv.rb --project /absolute/project 'ref:import[char-dev-v1,/absolute/dev.png,/absolute/original-run/manifest.json]'
```

The service verifies that the supplied image exactly matches the source manifest's local image, copies it into the new project's run and retains its existing HTTPS URL, model and request ID as provenance. Repeated identical imports are safe; a different identity must use a new versioned RUN. Both source files must exist for verification. If a hosted URL has expired, use the normal authorized upload flow and record the replacement; do not assume that an old URL still works. This imports an identity, not a finished scene. The new project can then use `import: { ref_base: "char-dev-v1" }` and generate fresh keyframes.

Invoke each import (and each differently parameterized call to the same Rake task) in a separate Ruby CLI process. Rake runs a task name once per process, even if it appears again with different bracket arguments.

`config/generations.rb` evaluates inside `Pipeline` and returns a Hash. It contains configuration, never rake bodies or shell commands:

```ruby
{
  "char-singer-v1" => { steps: [Steps::RefBase], image_model: Fal::Models::GptImage25 },
  "s01" => {
    steps: [Steps::RefBase, Steps::Music, Steps::Keyframes, Steps::Clips, Steps::Overlay],
    import: { ref_base: "char-singer-v1" },
    **section(0, 240), plate: "background"
  },
  "s02" => {
    steps: [Steps::RefBase, Steps::Music, Steps::Keyframes, Steps::Clips, Steps::Overlay],
    import: { ref_base: "char-singer-v1" },
    **section(240, 192), plate: "s01/background"
  }
}
```

For a new identity version edited from a prior character, add a run with `steps: [Steps::RefBase], edit_from: "char-singer-v1"` and write its edit instructions in `01_ref_base.txt`. `edit_from: "s01/approved-edit"` can instead promote an existing edited keyframe. The RefBase service selects the Sunburst edit endpoint, records a new identity and leaves the source untouched. Point dependent runs at the new ID after review.

`section(at, frames)` uses full `audio/song.wav`, offset `at/24.0`, integer frame length and an empty expected-lyrics list. Set `lyrics:` to selected recognizable words if desired. Sprite scenes are the default: `Clips, Overlay` with a still keyframe `plate:`, as in the example above. The full-frame paths are exceptions that the plan must justify (see "Self-contained characters" in [prompts.md](prompts.md)): a single H3 plate uses `Video` and a 5–15 second integer duration; multi-shot plates use `Keyframes, Shots, Overlay` with no `plate:`. `track:` optionally maps names to `[x,y,size,search,from_frame]` for tracked graphics. `reference:` is an optional local reference-video path.

Set `upload_music: false` when a section only needs its local soundtrack for compositing (for example a nonsinging H3 shot with `audio: false` plus existing timed captions). `gen:music` then cuts/fits the local WAV without constructing a Fal client. Use `anim:prepare` for existing cues. `review:music` runs local metrics and marks transcription skipped; expected lyrics cannot be verified without a transcript. A `Video`, an audio-driven `Shots` item or paid `gen:overlay` that reads `music.url` requires the default upload behavior. `Clips` with a separate vocal stem uploads just its actual needed stem interval.

Prompt files per run:

| File | Purpose |
|---|---|
| `01_ref_base.txt` (or `.json`) | Character prompt; JSON is sent as prompt text, not model options |
| `02_keyframes.yml` | Named image edit prompts, `base`, `refs` |
| `04_video.txt` | Single-shot H3 prompt (the Video step reads this stem) |
| `04_shots.yml` | Ordered shots, images, frames, optional audio/retime |
| `04_clips.yml` | H3/still/source sprite specifications and chroma/crop |
| `05_overlay.json` | Native scene, rendered through Ruby |

Read each step's `prompt` call if adding a new type. The imported `Music3` wrapper is optional for explicit song-generation requests; the normal skill uses the user's supplied song.

Example `02_keyframes.yml`:

```yaml
background:
  prompt: "Background plate matching the approved scene, visual style, lighting and colour treatment; no people or text."
singer:
  prompt: "SAME approved singer, full body, flat chroma green #00B140, limbs inside frame, no text."
reaction:
  base: singer
  prompt: "Same singer and framing; change only the expression to surprised."
duet:
  refs: [char-guest-v1]
  prompt: "Singer from image 1 and guest from image 2, separated silhouettes."
```

`base: false` omits the current ref_base; combine with `refs`. `base: other-run/keyframe` reuses an edited frame. An earlier same-run keyframe must appear before any dependent edit.

Example `04_clips.yml`:

```yaml
- name: sing
  image: singer
  seconds: 5
  audio: audio/stems/vocals.wav
  audio_at: 0
  gate: -36
  key: green
  prompt: "Same singer and approved visual style. Articulate the approved opening lyric; eyebrow raise on its joke. Locked camera, flat green, no text."
- name: surprise
  still: reaction
  key: green
```

`audio_at` is section-local, not the whole-song time. Omit `gate` if it damages consonants. `box: [x,y,w,h]`, `seed: [x,y]`, `frames`, `start`, `scale` are cutout options. Use the approved full prompt directive, style and performance details in real files; these abbreviated examples only show the schema.

## Production and review commands (optional Fal character path)

```sh
NOTE='User approved the linked plan and its generation allowance' ruby scripts/mv.rb --project /absolute/project plan:approve
ruby scripts/mv.rb --project /absolute/project work:next
LOG_DIR=/absolute/evaluation/logs LIMIT=3 ruby scripts/mv.rb work:watch
JOB=singer-v1 EVIDENCE=docs/reviews/singer-v1.md ruby scripts/mv.rb --project /absolute/project work:accept
RUN=char-singer-v1 ruby scripts/mv.rb --project /absolute/project gen:ref_base
RUN=char-singer-v1 ruby scripts/mv.rb --project /absolute/project review:ref_base
RUN=s01 ruby scripts/mv.rb --project /absolute/project pipeline:all
RUN=s01 ONLY=sing FORCE=1 ruby scripts/mv.rb --project /absolute/project gen:clips
RUN=s01 RECUT=1 ONLY=sing FORCE=1 ruby scripts/mv.rb --project /absolute/project gen:clips
RUN=s01 ruby scripts/mv.rb --project /absolute/project 'anim:prepare[audio/words.json]'
RUN=s01 ruby scripts/mv.rb --project /absolute/project 'anim:preview[0,24,96,239]'
RUN=s01 ruby scripts/mv.rb --project /absolute/project anim:overlay
ruby scripts/mv.rb --project /absolute/project 'media:preview[output/clean.mp4,s01,s02]'
```

`gen:ref_base`, `gen:keyframes`, `gen:video`, `gen:shots`, H3 `gen:clips`, generated music, `gen:overlay`, `review:music`, stems and SFX may call paid Fal endpoints. `gen:music` for an imported song is local processing plus CDN upload; `gen:overlay` uses paid Whisper unless re-rendering saved cues through `anim:overlay`. Reviews other than music are local. `pipeline:all` includes paid review calls; allocate them in the plan.

For existing reliable word timings, use `anim:prepare[full-song-words.json]` after the plate prerequisites exist, then `anim:preview`/`anim:overlay`. It accepts Whisper `chunks` or an array of `{w,s,e}` / `{word,start,end}`, selects this section and subtracts its song offset. With no argument it writes an empty cue list for sketches with explicitly authored timing. It also prepares configured tracks locally. `anim:overlay` records a complete manifest even on the first local render, so `review:overlay` works without a paid `gen:overlay` call.

`FORCE=1` changes cached work; `ONLY` confines ItemsStep work to named assets. A selected partial item set will not build the complete step's board until all items exist. `NEW_REQUEST=1` allows a new identical paid request; normal retries reuse saved receipts. `history[step]`, `adopt[step,request_id]`, `pick[step,index]`, `import[step,source_run]` support recovery and reuse. ItemsStep recovery uses per-item stored request IDs and reruns; adopt/pick are for single-output steps.

## Analysis, finishing and utility tasks

```sh
ruby scripts/mv.rb --project /absolute/project 'audio:analyze[audio/source.mp3,audio]'
ruby scripts/mv.rb --project /absolute/project 'audio:transcribe[audio/song.wav,audio/words.json]'
ruby scripts/mv.rb --project /absolute/project 'media:stems[audio/song.wav,audio/stems,vocals]'
ruby scripts/mv.rb --project /absolute/project 'media:frames[reference.mp4,output/reference_frames,12,480]'
ruby scripts/mv.rb --project /absolute/project 'media:cuts[reference.mp4,output/cuts.json]'
ruby scripts/mv.rb --project /absolute/project 'media:montage[output/review/strip.jpg,8,240,tmp/f/f_097.png,tmp/f/f_098.png]'
ruby scripts/mv.rb --project /absolute/project 'audio:transcribe_local[audio/source.mp3,audio/words_local.json,23,12]'
ruby scripts/mv.rb --project /absolute/project 'media:stems_local[audio/song.wav,audio/stems,0,0]'
ruby scripts/mv.rb --project /absolute/project 'audio:map[audio/song.wav,audio/map,audio/stems]'
ruby scripts/mv.rb --project /absolute/project 'audio:beatmap[audio/song.wav,audio/map/beatmap.json,audio/stems/drums.wav]'
ruby scripts/mv.rb --project /absolute/project 'audio:hits[audio/stems/drums.wav,audio/map/hits.json,audio/map/beatmap.json,audio/stems/bass.wav]'
ruby scripts/mv.rb --project /absolute/project 'audio:vocals[audio/stems/vocals.wav,audio/map/vocals.json,audio/map/beatmap.json]'
ruby scripts/mv.rb --project /absolute/project 'audio:sections[audio/song.wav,audio/map/sections.json,audio/map/beatmap.json,audio/map/hits.json,audio/map/vocals.json]'
ruby scripts/mv.rb --project /absolute/project 'audio:excerpt[audio/song.wav,audio/excerpt.wav,23,114.5,1.7]'
ruby scripts/mv.rb --project /absolute/project 'media:mouth[output/s01/04_clips/sing,audio/stems/vocals.wav,0,120,60,40,20]'
ruby scripts/mv.rb --project /absolute/project 'anim:render[tools/graphics/examples/futuristic.json,tmp/smoke,48,1920,1080]'
SFX=finish-sfx ruby scripts/mv.rb --project /absolute/project sfx:gen
SFX=finish-sfx ruby scripts/mv.rb --project /absolute/project sfx:mix
VFX=finish-vfx ruby scripts/mv.rb --project /absolute/project vfx:analyze
VFX=finish-vfx ruby scripts/mv.rb --project /absolute/project 'vfx:stills[0,24,120]'
VFX=finish-vfx ruby scripts/mv.rb --project /absolute/project 'vfx:clip[96,144]'
VFX=finish-vfx ruby scripts/mv.rb --project /absolute/project vfx:render
ruby scripts/mv.rb --project /absolute/project 'media:twitter[output/finished.mp4,output/delivery-1080.mp4]'
```

`media:montage` tiles frames into a labelled contact strip (columns, tile width) for frame-exact sync review. `audio:transcribe_local` (mlx-whisper; `MV_WHISPER_MODEL`, `MV_WHISPER_LANG`) and `media:stems_local` (Demucs `htdemucs` on MPS; `MV_DEMUCS_MODEL`; writes vocals, no_vocals, drums, bass and other in one pass) are free local alternatives run through `uv`; their timestamps refer to the whole song. Sung or heavily processed vocals can still hallucinate words; verify by listening.

`audio:excerpt[audio,out.wav,from,seconds,fade_seconds]` cuts the render soundtrack: `seconds` long from `from`, silence-padded if the song is shorter, with an optional fade-out over the last `fade_seconds`; 44.1 kHz stereo. Pass it as `AUDIO=` to `graphics:render` so the video and soundtrack share frame 0.

**Music map (sync timing).** `audio:map` runs `tools/python/music_map.py` (numpy + scipy through `uv`, free, ~2 s per song) and writes four JSON files; the single-purpose tasks write one each. Times are seconds of the input file; `f` is the 24fps frame.

- `beatmap.json`: `beats[{n,t,raw,bar,pos,f}]`, `bars[{bar,t,bpm}]`, `downbeat_phase`, `snare_feel` (backbeat/halftime), `tempo_mode`. Comb-locked tracking follows tempo drift — generated songs often shift a fraction of a BPM at section joins, which a single global grid turns into 100+ ms of error by the second chorus. `MV_TEMPO=constant` forces one straight grid.
- `hits.json`: `kick`/`snare`/`hat` (and `bass` 808 notes with pitch when a bass stem is given) as `{t,s,db,beat,bar,step}`. `t` is the attack's half-rise point, not the energy peak; cue flashes there. `bars[]` prints 16-step patterns (`x.......x.......`) for reading the groove. Prefer the drums stem; kicks fused with an 808 may read as `bass` notes instead.
- `vocals.json`: `lines` (lyric lines), `phrases` (words/notes) and `onsets` from a vocal stem, each with bar/step.
- `sections.json`: per-bar sub/low/mid/high/rms dB and hit counts, grouped into `drop`/`build`/`filtered`/`breakdown`/`groove` (+`vox`) sections with an `energy` 0–1. Labels are heuristics from band presence; confirm by listening.

`media:probe`, `media:sheet`, `media:frame`, `media:cut`, `media:cutout`, `media:sprite_box`, `media:style`, `media:concat`, `media:mux`, `media:upload` and `media:youtube` are listed by `-T` with their arguments. Export names denote encoding presets; they do not publish to platforms. For unlisted operations, add an OOP service under `lib/` and a thin registry delegate. Keep backend code under `tools/` and tests in `spec/`.

For detached lettering or debris in an RGBA sprite sequence, run `ruby scripts/mv.rb --project /absolute/project 'media:keep_component[output/raw-sprite,output/clean-sprite,320,400]'`. The seed is an integer pixel coordinate inside the intended subject in **every** input frame. The task preserves its four-connected nonzero-alpha component exactly and clears other alpha; it never expands or bridges components. Output must be a different, new or empty directory. Out-of-bounds or transparent seeds fail the whole sequence without publishing partial output. Touching text remains part of the subject and needs a separate mask; inspect the cleaned motion before use.

The packaging follows [Agent Skills script guidance](https://agentskills.io/skill-creation/using-scripts): relative entry paths, explicit prerequisites, noninteractive arguments, help, meaningful failure codes and compact results. Ruby OOP methods own execution and delegate backend work.
