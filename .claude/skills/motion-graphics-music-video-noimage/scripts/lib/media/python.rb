require "json"
require_relative "shell"

module Media
  # Runs analysis scripts in ./scripts with the local python3 (PIL + numpy)
  # and parses their JSON stdout.
  class Python < Shell
    SCRIPTS = File.expand_path("../../tools/python", __dir__)

    def executable = ENV["MV_PYTHON"] || (File.file?(File.expand_path(".venv/bin/python3")) ? File.expand_path(".venv/bin/python3") : "python3")

    def call(script, *args)
      JSON.parse(run(executable, File.join(SCRIPTS, script), *args, quiet: true))
    end

    # Share of low-saturation (hand-drawn / monochrome) vs colored pixels per image.
    def style_split(*images)
      call("style_split.py", *images)
    end

    # Per-frame position of a feature (box `size` centred at x, y in frame `from`) by template matching.
    def track_template(video, x, y, size, search = size, from = 0)
      call("track_template.py", video, x.to_s, y.to_s, size.to_s, search.to_s, from.to_s)
    end

    # Character cut out of a video/still into transparent PNGs in `out` (scripts/cutout.py): key "paper" or "green",
    # box [x, y, w, h], seed [x, y], frames, start, scale. Returns { "frames", "w", "h", "box", "scale" }.
    def cutout(source, out, key, box: nil, seed: nil, frames: nil, start: nil, scale: nil)
      args = [source, out, key]
      args += ["--box", *box] if box
      args += ["--seed", *seed] if seed
      { "--frames" => frames, "--start" => start, "--scale" => scale }.each { |flag, v| args += [flag, v] if v }
      call("cutout.py", *args.map(&:to_s))
    end

    # Local word timestamps through mlx-whisper in an ephemeral uv environment (Apple Silicon; local processing).
    # Returns Whisper-style { "text", "chunks" => [{ "text", "timestamp" => [s, e] }] } in whole-song seconds.
    def transcribe_local(audio, from: 0.0, seconds: 0.0, model: ENV["MV_WHISPER_MODEL"] || "mlx-community/whisper-large-v3-turbo", language: ENV["MV_WHISPER_LANG"].to_s)
      raise CommandError, "uv is required for local transcription (https://docs.astral.sh/uv/)" unless Shell.available?("uv")
      JSON.parse(run("uv", "run", "--quiet", "--no-project", "--python", "3.12", "--with", "mlx-whisper",
                     "python", File.join(SCRIPTS, "transcribe_local.py"), audio, from.to_s, seconds.to_s, model, language, quiet: true).lines.last)
    end

    # Music map (tools/python/music_map.py, numpy + scipy in an ephemeral uv environment; local processing).
    # cmd: "all" (input song, out dir; stems: dir with drums/bass/vocals/no_vocals.wav), "beats", "hits", "vocals",
    # "sections" (out .json). opts: drums:, bass:, beats:, hits:, vocals:, stems: paths; fps:, tempo: auto|constant|local.
    def music_map(cmd, input, out, **opts)
      raise CommandError, "uv is required for the music map (https://docs.astral.sh/uv/)" unless Shell.available?("uv")
      flags = opts.compact.flat_map { |k, v| ["--#{k.to_s.tr("_", "-")}", v.to_s] }
      JSON.parse(run("uv", "run", "--quiet", "--no-project", "--python", "3.12", "--with", "numpy", "--with", "scipy", "--with", "soundfile",
                     "python", File.join(SCRIPTS, "music_map.py"), cmd, input, out, *flags, quiet: true).lines.last)
    end

    # Local Demucs stem WAVs (vocals, no_vocals, drums, bass, other) (full-song aligned) through an ephemeral uv environment; local processing.
    def stems_local(audio, out, from: 0.0, seconds: 0.0, model: ENV["MV_DEMUCS_MODEL"] || "htdemucs")
      raise CommandError, "uv is required for local stems (https://docs.astral.sh/uv/)" unless Shell.available?("uv")
      JSON.parse(run("uv", "run", "--quiet", "--no-project", "--python", "3.12", "--with", "demucs", "--with", "soundfile",
                     "python", File.join(SCRIPTS, "stems_local.py"), audio, out, from.to_s, seconds.to_s, model, quiet: true).lines.last)
    end

    # RMS loudness + vocal-band energy per window, for a mono wav.
    def audio_energy(wav, window: 0.5)
      call("audio_energy.py", wav, window.to_s)
    end
  end
end
