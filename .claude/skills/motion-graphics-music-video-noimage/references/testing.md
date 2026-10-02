# RSpec verification

Routine tests make no paid calls; Fal audio contracts use mocked responses. All test execution enters through Ruby. From the skill directory:

```sh
ruby scripts/mv.rb setup
ruby scripts/mv.rb test
PROFILE=core ruby scripts/mv.rb test
PROFILE=media ruby scripts/mv.rb test
PROFILE=swift ruby scripts/mv.rb test
```

The repository root also has `rake test`. `PROFILE=all` (default) runs all examples locally. Tests fail if a required backend cannot run, including unavailable native GPU/codec services or Swift on a non-macOS machine. Use a narrower profile when that backend is unavailable and report what was not exercised. Tests leave diagnostic fixtures in `scripts/tmp/` and derived review outputs under `scripts/output/`, both ignored by git.

There is no paid/live test profile. No generation API key is required. Music-map tests may use `uv` to obtain their local Python dependencies on first use.

## What is tested

| Profile | Observable behavior |
|---|---|
| core | skill metadata/reference links, CLI help/task discovery, project initialization and overwrite rejection, literal shell arguments, subprocess errors, plan approval, dependency waves, worker journals, local fonts, rejection of removed image/video commands, Fal audio adapter contracts, credential isolation, request caching and recovery |
| media | real FFmpeg/ffprobe + ImageMagick + Python audio duration/silence/energy, music mapping on a synthetic drifting-tempo track, cut detection, green alpha edges, sprite cleanup and placement, actual moving pixels, deterministic repeats, frame counts and soundtrack continuity, supplied-asset overlay rendering, procedural SFX caching/timing/levels, mouth-alignment diagnostics |
| swift | native graphics geometry/alpha/seek tests, Metal particles/compute/3D, H.264 timing, ProRes alpha, audio analysis, sparse JSON overlays, real Swift VFX renders, cue-on/cue-off pixel checks, audio/frame preservation and invalid-effect rejection |

Synthetic fixtures keep placement, alpha and timing measurable. Initialized projects retain a `.skill/` copy of the instructions and references so their copied test suite can validate documentation too. The media profile checks that component cleanup preserves the subject's exact RGBA and soft alpha, leaves the source unchanged, and rejects invalid seeds without publishing partial output.

Run `swift test` in `scripts/tools/graphics` after renderer changes. Executable checks do not establish creative quality; inspect and listen to the output as well.

## Behavioral review

Use a disposable project to check the relevant workflow:

1. Song and creative prompt: initialize, map the music, research a bar-keyed plan, create a scene from `assets/scene-template.rb`, and render range previews before the master.
2. Edit one section: preview that range and keep previously delivered masters intact.
3. Missing kick detections: use snares or bass-note timing, then verify with sound.
4. Finish: `finish_cues.rb` places local SFX/VFX on scene events; whooshes crest on downbeats using cached `peak_at` values.
5. Character brief: draw characters procedurally or use supplied art and clips. Do not offer remote image/video generation or ask for credentials for the native build.

Review the plan against the user's taste and watch the opening, peak and ending with sound. Record findings in the review document; a Markdown link check is not a creative evaluation.
