# Intake, research and a complete storyboard

Three starting points are supported:

1. **A song and a prompt, researched.** The default. *deadstar* was made this way: astronomy facts as on-screen lines over neon line art.
2. **A song and a reference video.** Its timing, camera and graphic language are studied, then reinterpreted. *deadstar*'s line-art
   speed came from a reference.
3. **A revision of an existing video.** Begin from its established storyboard, scene generator and latest delivered version. Preserve
   its meaningful sections and motif unless the user asked for a remix.
   - On the optional character path, also start from its latest approved identity versions.
   - Use `ref:import` to verify provenance and resolve version mismatches before prompting.

## Song-first planning

1. **Map the song.** Preserve the original in `audio/source.<extension>`.
   - `audio:analyze` decodes it once to `audio/song.wav` and writes beats and energy.
   - For frame-exact sync, run `media:stems_local`, then `audio:map`. It produces a drift-following tempo map, downbeats, kick/snare/hat
     attack times, vocal lines and bar-aligned sections (see [tasks.md](tasks.md)).
   - Key cues to those times, never to a computed `bpm` grid.
   - Listen to confirm section labels.
2. **Choose the excerpt** at musical boundaries: start on a downbeat or pickup, and end after a phrase with a fade (`audio:excerpt`).
   - The excerpt start is the scene's `SONG_START`.
   - Plan the video in **bars** (the map's own numbering) and convert to video seconds only in the generator.
   - Cover the whole excerpt; never leave dead air at the end.
3. **Mark the timing events:** lyric lines and the words worth showing, drops, builds, breaks, the last hit and silences.
   - Choose the moments that get the biggest gestures: the opening hook, the first drop, the core peak and the ending.
   - Choose the bars that stay calm.
4. **Keep refinements in `docs/TIMING.md`:** map corrections, words from `audio:transcribe_local` checked by ear, and BPM drift notes.
   Do not rewrite an approved creative plan merely to log implementation progress.

## Research for interesting details

- Search the song's subject and concrete phrases, then adjacent visual, scientific and cultural topics.
- Collect several useful candidates, not a giant link dump. Each entry has:
  - the source title, URL and access date;
  - the verified fact or inspiration;
  - the proposed visual/line of text and its section;
  - whether it is fictionalized.
- Use current primary sources for real numbers and claims.
- Avoid forcing irrelevant memes into every section.

Motion graphics turn facts into pictures:
- diagrams that draw themselves;
- counters and odometers racing to a real number;
- fake instrument HUDs;
- distance ladders;
- maps;
- stamps;
- typewritten captions.

Build escalating callbacks: introduce a motif in the hook, transform it at the drop, misuse it in a verse, and pay it off at the ending.
Design readable focal areas and a few calm beats. Chaos comes from choreography, not from constant random flicker.

## With a reference video

Use `media:probe`, `media:cuts`, `media:cut`, `media:frames[...,12,480]` and `media:frame` through Ruby. Review dense frame strips between
cuts; a sparse contact sheet hides how a line draws on, how type moves, or how a camera reveals a scene. Record:

| Frame range | lyric/cue | camera | drawing/type action | timing per beat | foreground/background | reuse/invention |
|---|---|---|---|---|---|---|

Cut detection is a candidate list: flat graphics and hard flashes need visual confirmation. Study staging and motion, then write an
original plan in the user's chosen direction.

## Approval package

- Use [the plan template](../assets/plan-template.md). The plan must:
  - cover the whole excerpt;
  - key every section to bars;
  - give the exact on-screen copy;
  - identify which details came from research.
- The native workflow makes no paid calls.
  - Approval covers the creative direction.
  - A rendered preview of the opening section makes the decision concrete.
- When the optional character path is included:
  - estimate calls by model and generated seconds;
  - allow a bounded number of retries;
  - quote current pricing sources. If a price cannot be established, say so and obtain a call-count budget. Do not invent a dollar total.
- The chat summary should let the user understand the video without reading the whole plan.

Approval covers execution within those creative (and, for characters, cost) bounds. Ask again for a changed creative direction, a model
substitution, or spending beyond the allowance. Routine renders, fixes and iterations within the plan can proceed.
