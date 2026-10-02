# Optional Fal audio credentials

The native music-video workflow needs no Fal key. Keep the supplied song, local analysis and Swift sound synthesis unless the user explicitly requests Fal audio work. Supported audio tools are Music3, Stable Audio SFX, Whisper and Demucs; image/video model adapters are removed.

## Plugin sessions

Configure the plugin's optional **Fal API key** with `/plugin configure motion-graphics-music-video`. The sensitive `FAL_AI_API_KEY` option is passed only to the bundled `music-video` MCP server. Never ask the user to paste it into chat or read credential files. The server can start without a key; `credential_status` reports whether one is configured without revealing it.

Initialize the project, install dependencies, write the plan and record approval through the Ruby CLI. Use the server's `run_task` for requested audio tasks and poll `task_status` until complete. Its task allowlist contains audio processing/generation, audio uploads and the audio/composition pipeline; it exposes no image/video generation commands.

Include the actual requested audio calls and bounded retries in the plan. Existing approval within that scope remains valid; do not ask again per task. Missing configuration for requested audio work should be resolved through plugin configuration, not a key file. Cancellation stops the local process; an already submitted Fal request may still incur charges. Resume from saved receipts rather than resubmitting.

## Standalone developer use

The Ruby CLI reads only `FAL_AI_API_KEY` from its environment (or an explicitly supplied client argument). Do not put keys in source, prompts or config files. The MCP server prefers its plugin option and falls back to the exported environment key when the option is unset. Ordinary shell tasks cannot see the sensitive plugin option.

The shared client retains queue polling, saved request receipts, schema validation and cached uploads for audio work. Uploaded media URLs may be accessible to anyone with the link. Use `doctor` for local dependencies; a missing optional Fal key does not fail the native prerequisite check.
