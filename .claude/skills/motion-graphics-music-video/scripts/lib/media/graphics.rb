require "json"
require_relative "shell"
require_relative "ffmpeg"

module Media
  # Native Swift scene renderer. Used by the Anim entry point and direct movie exports.
  class Graphics < Shell
    PACKAGE = File.expand_path("../../tools/graphics", __dir__)
    BIN = File.join(PACKAGE, ".build", "release", "mgraphics")

    def build
      run("swift", "build", "-c", "release", "--package-path", PACKAGE)
      { path: BIN }
    end

    # jobs > 1 renders a movie as that many frame chunks in parallel mgraphics processes (each frame is a pure function of its
    # time, so chunks match a sequential render), joins them with a stream copy and muxes the audio once.
    def render(scene, out, width:, height:, fps:, frames:, data: {}, only: nil, plate: nil, audio: nil, codec: nil, benchmark: false, coverage: false,
               supersample: nil, bitrate: nil, jobs: nil)
      ensure_built
      argv = lambda do |movie, sound|
        args = [scene, "--out", movie, "--width", width, "--height", height, "--fps", fps, "--frames", frames]
        args += ["--only", only.join(",")] if only
        args += ["--plate", plate] if plate
        args += ["--audio", sound] if sound
        args += ["--codec", codec] if codec
        args += ["--supersample", supersample] if supersample
        args += ["--bitrate", bitrate] if bitrate
        args << "--benchmark" if benchmark
        args << "--measure-coverage" if coverage
        data.each { |name, path| args += ["--data", "#{name}=#{path}"] }
        args
      end
      chunks = jobs.to_i > 1 && out.match?(/\.(mp4|mov)\z/i) && !benchmark && !plate ? [jobs.to_i, frames / 24].min : 1
      return parallel(argv, out, frames: frames, fps: fps, audio: audio, chunks: chunks) if chunks > 1
      JSON.parse(run(BIN, *argv.call(out, audio)).lines.last)
    end

    # Procedural sound effect (SoundSynth in Synth.swift) -> {"wav", "duration", "peak_at"}. spec: {"synth" => "whoosh", ...}.
    def synth(out, spec)
      ensure_built
      JSON.parse(run(BIN, "--sfx", out, "--spec", JSON.generate(spec), quiet: true).lines.last)
    end

    private

    def parallel(argv, out, frames:, fps:, audio:, chunks:)
      raise CommandError, "Output already exists: #{out}" if File.exist?(out)
      parts = "#{out}.parts"
      FileUtils.rm_rf(parts)
      FileUtils.mkdir_p(parts)
      bounds = (0..chunks).map { |i| frames * i / chunks }
      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      warn "  rendering #{frames} frames as #{chunks} parallel chunks"
      files = bounds.each_cons(2).with_index.map do |(from, to), i|
        file = File.join(parts, format("%03d.mp4", i))
        thread = Thread.new { run(BIN, *argv.call(file, nil), "--from", from, "--to", to, quiet: true) }
        thread.report_on_exception = false
        [file, thread]
      end
      errors = files.filter_map do |_, thread|
        thread.value
        nil
      rescue CommandError => e
        e
      end
      raise errors.first if errors.any?
      list = File.join(parts, "list.txt")
      File.write(list, files.map { |f, _| "file '#{File.expand_path(f)}'\n" }.join)
      joined = audio ? File.join(parts, "joined#{File.extname(out)}") : out
      run("ffmpeg", "-y", "-v", "error", "-f", "concat", "-safe", "0", "-i", list, "-c", "copy", joined)
      FFmpeg.new.mux(joined, audio, out) if audio
      FileUtils.rm_rf(parts)
      ms = (Process.clock_gettime(Process::CLOCK_MONOTONIC) - started) * 1000
      { "out" => out, "frames" => frames, "fps" => fps, "jobs" => chunks, "ms" => ms, "render_fps" => frames / (ms / 1000) }
    end

    def ensure_built
      sources = Dir[File.join(PACKAGE, "Sources", "**", "*.swift")] + [File.join(PACKAGE, "Package.swift")]
      build if !File.file?(BIN) || sources.any? { |path| File.mtime(path) > File.mtime(BIN) }
    end
  end
end
