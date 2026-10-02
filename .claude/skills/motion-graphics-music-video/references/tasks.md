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
      runtime.rb                 load media services and audio/composition steps
      pipeline/                  audio runs, local composition and manifests
      fal/                       audio adapters, queue/storage client and schemas
      media/                     Ruby wrappers that shell out
    tools/
      python/                    analysis, cutouts, tracking and audio mixing
      graphics/                  Swift library/renderer, JSON examples; project fonts copied before rendering
      vfx/                       Swift package and Core Image effects
    spec/                        high-level RSpec contracts and E2E tests
```

`init` copies the executable toolkit to a new project with the same `Rakefile → lib → tools` layers and adds `config/`, `audio/`, `prompts/`, `docs/`, `output/`. It excludes installed dependencies, build caches, generated outputs and test scratch data. Each project is self-contained; install dependencies there with `setup`. Ruby 3.2+ is required by the OOP code. Run the CLI using the same Ruby used for Bundler.

All examples below are executed from the skill directory. Replace `/absolute/project` with the real initialized project path. `ruby scripts/mv.rb --project /absolute/project 'TASK[...]'` and, inside the project, `bundle exec rake 'TASK[...]'` are equivalent. CLI flags precede/follow the task; task arguments use Rake brackets. Quote bracket expressions in zsh. For file names containing commas, rename/copy the input in Ruby before using Rake's comma-separated arguments.


## Setup and inspection

```sh
ruby scripts/mv.rb --help
ruby scripts/mv.rb -T
ruby scripts/mv.rb --project /absolute/project setup
ruby scripts/mv.rb --project /absolute/project doctor
```

`setup` calls Bundler and Python venv/pip through Ruby, then builds both Swift packages. Install system Ruby, FFmpeg/ffprobe, ImageMagick and Swift/Xcode command line tools on macOS 14+ beforehand. `MV_PYTHON` overrides the local `.venv/bin/python3`; `MEDIA_FONT` overrides the detected font path. `doctor` prints JSON booleans; `STRICT=1` makes missing dependencies fail. Tests require the full selected profile's tools and do not silently skip missing dependencies.

`fonts:list` scans installed macOS TTF/OTF files. Just before rendering, `fonts:copy[config/fonts.json]` copies a JSON mapping of project filenames to absolute source paths into the video's `tools/graphics/fonts/`. Run with `--project /absolute/video-workspace`; see [Project fonts](animation-audio-vfx.md#project-fonts). Setup does not fetch fonts.

## Native scenes, previews and finals

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

## Creative approval and progress

```sh
NOTE='User approved the linked creative plan' ruby scripts/mv.rb --project /absolute/project plan:approve
AGENT=main EVENT=preview MESSAGE='Opening rendered for review' ruby scripts/mv.rb --project /absolute/project work:log
ruby scripts/mv.rb --project /absolute/project work:watch
```

`work:next` and `work:accept` can track dependency-ready local jobs when the project uses `config/production.json`; they do not submit media to a service. Use `graphics:preview` and `graphics:render` directly for scenes. The default rendering and finishing workflow runs locally.

## Optional Fal audio

Use these only for audio work the user explicitly requests. Read [credentials.md](credentials.md) first. Keep the normal supplied-song, local-analysis and Swift-SFX path otherwise.

```sh
ruby scripts/mv.rb --project /absolute/project openapi:fetch
ruby scripts/mv.rb --project /absolute/project openapi:summary
ruby scripts/mv.rb --project /absolute/project 'audio:transcribe[audio/song.wav,audio/words.json]'
ruby scripts/mv.rb --project /absolute/project 'media:stems[audio/song.wav,audio/stems,vocals]'
```

In plugin sessions, run the paid tasks via the `music-video` MCP server. Schema inspection stays in the Ruby CLI. The schemas cover only Music3, Stable Audio SFX, Whisper and Demucs.

For Music3, `config/generations.rb` returns a Hash evaluated inside `Pipeline`:

```ruby
{
  "audio-demo" => { steps: [Steps::Music], duration: 10, upload_music: false, lyrics: [] }
}
```

Write `prompts/audio-demo/03_music_prompt.txt` and `03_music_lyrics.txt`, include the requested call and retry allowance in `docs/PLAN.md`, and record the user's approval with `plan:approve`. Then run `RUN=audio-demo gen:music`. Output and request receipts are retained under `output/`. `review:music` checks local metrics; when `upload_music: true`, it also uses paid Whisper. `music_from:` and `music_offset:` reuse a supplied local soundtrack instead of generating one.

`sfx:gen` also retains Stable Audio SFX support when a sound has `prompt:` rather than `synth:` or `tone:`. Use prompt-based SFX only when requested and approved; native synthesis needs no Fal key.

The optional run pipeline supports only `Steps::Music` and `Steps::Overlay`. For an existing local scene, set `plate:` to a supplied image/video path or omit it for a scene that draws its own background. Optional `clips:` points to local clip metadata JSON. Write `prompts/<run>/05_overlay.json`, run `anim:prepare[full-song-words.json]`, then `anim:preview[0,24]` / `anim:overlay` for local composition. `gen:overlay` instead uses paid Whisper to prepare captions. `pipeline:all` processes the configured audio/composition steps and may call paid audio services; it is not the default video command.

`media:preview[out.mp4,s01,s02]` joins contiguous run sections with one continuous song. `history`, `adopt`, `pick` and `import` retain audio request recovery/reuse. Retrying an identical Fal request resumes its saved receipt; use `NEW_REQUEST=1` only for an authorized fresh request. The pipeline has no image/video generation steps.

## Analysis, finishing and utility tasks

```sh
ruby scripts/mv.rb --project /absolute/project 'audio:analyze[audio/source.mp3,audio]'
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
ruby scripts/mv.rb --project /absolute/project 'media:mouth[assets/singer-frames,audio/stems/vocals.wav,0,120,60,40,20]'
ruby scripts/mv.rb --project /absolute/project 'anim:render[tools/graphics/examples/futuristic.json,tmp/smoke,48,1920,1080]'
SFX=finish-sfx ruby scripts/mv.rb --project /absolute/project sfx:gen
SFX=finish-sfx ruby scripts/mv.rb --project /absolute/project sfx:mix
VFX=finish-vfx ruby scripts/mv.rb --project /absolute/project vfx:analyze
VFX=finish-vfx ruby scripts/mv.rb --project /absolute/project 'vfx:stills[0,24,120]'
VFX=finish-vfx ruby scripts/mv.rb --project /absolute/project 'vfx:clip[96,144]'
VFX=finish-vfx ruby scripts/mv.rb --project /absolute/project vfx:render
ruby scripts/mv.rb --project /absolute/project 'media:twitter[output/finished.mp4,output/finished_x.mp4]'
ruby scripts/mv.rb --project /absolute/project 'media:faststart[output/finished.mp4,output/finished_fs.mp4]'
```

**X/Twitter delivery.** `media:twitter[video,out.mp4]` encodes any source to X's upload spec:
- MP4, H.264 High@4.2, yuv420p, progressive, square pixels, tagged BT.709 limited range (untagged/BT.601 sources are converted);
- fits the 16:9 1920x1080, 9:16 1080x1920 or 1:1 1080x1080 box without upscaling; a source within 1% of the ratio (1928x1076 model clips) is fill-cropped to it; rotated phone video and anamorphic pixels are handled;
- keeps the frame rate up to 60 (higher is capped), closed 1 s GOPs, faststart;
- CRF 16 with a 24 Mb/s VBV cap (X's maximum is 25). Override with `CRF=`, `MAX_MBPS=` (≤ 25), `TUNE=animation|film|grain`;
- AAC-LC stereo/mono at 44.1/48 kHz is copied, anything else becomes AAC-LC 48 kHz stereo 256 kb/s; metadata is stripped.

It refuses to overwrite `out`, and prints the result with `mbps`, `fits_free` (≤ 140 s, ≤ 512 MB) and `fits_premium` (≤ 4 h, ≤ 16 GB on web/iOS; Android uploads stop at 10 min). A 1080p60 native render re-encodes transparently (deadstar: PSNR 50 dB, SSIM 0.997, ~3 min for 2 min on 8 cores). `media:faststart` is the lossless alternative when the master is already in spec and only needs its index moved to the front.

`media:montage` tiles frames into a labelled contact strip (columns, tile width) for frame-exact sync review. `audio:transcribe_local` (mlx-whisper; `MV_WHISPER_MODEL`, `MV_WHISPER_LANG`) and `media:stems_local` (Demucs `htdemucs` on MPS; `MV_DEMUCS_MODEL`; writes vocals, no_vocals, drums, bass and other in one pass) run locally through `uv`; their timestamps refer to the whole song. Sung or heavily processed vocals can still hallucinate words; verify by listening.

`audio:excerpt[audio,out.wav,from,seconds,fade_seconds]` cuts the render soundtrack: `seconds` long from `from`, silence-padded if the song is shorter, with an optional fade-out over the last `fade_seconds`; 44.1 kHz stereo. Pass it as `AUDIO=` to `graphics:render` so the video and soundtrack share frame 0.

**Music map (sync timing).** `audio:map` runs `tools/python/music_map.py` (numpy + scipy through `uv`, free, ~2 s per song) and writes four JSON files; the single-purpose tasks write one each. Times are seconds of the input file; `f` is the 24fps frame.

- `beatmap.json`: `beats[{n,t,raw,bar,pos,f}]`, `bars[{bar,t,bpm}]`, `downbeat_phase`, `snare_feel` (backbeat/halftime), `tempo_mode`. Comb-locked tracking follows tempo drift — generated songs often shift a fraction of a BPM at section joins, which a single global grid turns into 100+ ms of error by the second chorus. `MV_TEMPO=constant` forces one straight grid.
- `hits.json`: `kick`/`snare`/`hat` (and `bass` 808 notes with pitch when a bass stem is given) as `{t,s,db,beat,bar,step}`. `t` is the attack's half-rise point, not the energy peak; cue flashes there. `bars[]` prints 16-step patterns (`x.......x.......`) for reading the groove. Prefer the drums stem; kicks fused with an 808 may read as `bass` notes instead.
- `vocals.json`: `lines` (lyric lines), `phrases` (words/notes) and `onsets` from a vocal stem, each with bar/step.
- `sections.json`: per-bar sub/low/mid/high/rms dB and hit counts, grouped into `drop`/`build`/`filtered`/`breakdown`/`groove` (+`vox`) sections with an `energy` 0–1. Labels are heuristics from band presence; confirm by listening.

`media:probe`, `media:sheet`, `media:frame`, `media:cut`, `media:cutout`, `media:sprite_box`, `media:style`, `media:concat`, `media:mux` and `media:youtube` are listed by `-T` with their arguments. Export names denote encoding presets; they do not publish to platforms. For unlisted operations, add an OOP service under `lib/` and a thin registry delegate. Keep backend code under `tools/` and tests in `spec/`.

For detached lettering or debris in an RGBA sprite sequence, run `ruby scripts/mv.rb --project /absolute/project 'media:keep_component[output/raw-sprite,output/clean-sprite,320,400]'`. The seed is an integer pixel coordinate inside the intended subject in **every** input frame. The task preserves its four-connected nonzero-alpha component exactly and clears other alpha; it never expands or bridges components. Output must be a different, new or empty directory. Out-of-bounds or transparent seeds fail the whole sequence without publishing partial output. Touching text remains part of the subject and needs a separate mask; inspect the cleaned motion before use.

The packaging follows [Agent Skills script guidance](https://agentskills.io/skill-creation/using-scripts): relative entry paths, explicit prerequisites, noninteractive arguments, help, meaningful failure codes and compact results. Ruby OOP methods own execution and delegate backend work.
