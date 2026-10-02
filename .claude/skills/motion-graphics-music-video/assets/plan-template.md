# Music video production plan

## Brief and approval scope

- Song path and duration, and the excerpt (song from → to, seconds, fade).
- The supplied prompt, intended audience and aspect ratio.
- Preview and master frame rates (default: 30 fps drafts, 60 fps 1080p master).
- The requested mood and the chaotic/quiet balance.
- What approval authorizes. The native workflow makes no paid calls.
- If the optional character path is used: model call counts, generated seconds, pricing sources and the retry allowance.

## Creative direction

- The one-sentence premise, opening hook, main peak/drop, emotional arc, ending and the recurring motif with its payoff.
- Explain how the chosen look suits the song and brief.
- Require hyper quality, interesting detail and rhythmic precision, and aim for potential fun/virality without promising audience outcomes.

**Style bible.** Shared as constants in the scene generator:
- the palette (hex values);
- the background treatment;
- line weights and when they thin for the 60 fps master;
- glow/neon rules (which elements glow, halo sizes);
- textures and where they are allowed (grain, RGB, bands are section VFX cues, not global);
- the camera language (hits, shakes, pushes, whips, 3D planes);
- visual density and the moments of restraint.

**Typography:** the selected installed faces and weights, their PostScript names, the required glyphs, and the source paths and copied filenames (`config/fonts.json`).

## Music map and timing

- The map summary: BPM and drift, bar numbers of the sections, drop/build/break labels confirmed by listening, kick/snare availability, and vocal lines.
- Key moments with song time, bar and beat.
- Link `docs/TIMING.md`.

## Research

Link RESEARCH.md. For each selected detail: source URL and date, the accurate fact or inspiration, its visual treatment, and its section.

## Full storyboard (bar-keyed)

| Section | Bars | Video time | Song section/lyrics | Picture (nodes, motion, camera) | Text on screen | Motif/callback | Events (flash, word, big, neon) | SFX/VFX |
|---|---|---|---|---|---|---|---|---|

Repeat a block for every row:

- **Draws:** what the section draws and its layer order (background → distant graphics → focal element → type → HUD).
- **Sync:** which cues land on which beats or hits (`b(bar, beat)`, kicks, snares, vocal onsets).
- **Copy:** the exact on-screen text and its timing; the research detail and its payoff.
- **Finish:** the events it records for the finish, and any hand-placed SFX/VFX.
- **Acceptance:** hits on the beat, readable type, nothing unintended off-frame, a clean join to the next section.

## Build, preview and finish

- **Section order:** the order the sections are built in, with the opening and the main peak first.
- **Previews:** the preview ranges to show the user.
- **Final master:** settings (fps, `SUPERSAMPLE=2`, bitrate) and frame count.
- **Finish:** the SFX palette (Swift SoundSynth specs), the VFX palette and the shader cues.
- **Safety:** a photosensitivity warning if the video flashes, and a strobe rate under 3 Hz.

## Review and delivery

Check:
- opening/peak/ending playback with sound;
- contact sheets;
- type bounds;
- section joins;
- soundtrack continuity;
- a VFX on/off (plain vs shaders) comparison;
- SFX levels;
- the final frame count.

Deliver the finished, plain and clean versions, a contact sheet and the docs, and note any known uncertainty.

## Optional: characters (Fal path only)

For each cast member:
- a stable ID/version, role, silhouette, face, hair, clothing, palette and personality;
- an expression/pose sheet and no-change anchors;
- the character generation prompt, permitted edits and reference dependencies.

Characters are generated alone on chroma green and composited by the Swift renderer. List every full-frame H3 shot with its reason; none is the expected answer.

For each character shot:
- keyframe prompts;
- H3 prompt(s), 1080P, generated seconds, the exact stem interval and the placement interval;
- mouth targets.

Production waves: 2 pilot assets first, then 3–4, then 4–8, then 6–10 repeatedly ([production.md](../references/production.md)).
