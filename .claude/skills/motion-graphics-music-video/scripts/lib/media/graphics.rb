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
               supersample: nil, bitrate: nil, jobs: nil, from: 0, glow: nil)
      ensure_built
      argv = lambda do |movie, sound|
        args = [scene, "--out", movie, "--width", width, "--height", height, "--fps", fps, "--frames", frames]
        args += ["--only", only.join(",")] if only
        args += ["--from", from] if from.positive? && !only
        args += ["--plate", plate] if plate
        args += ["--audio", sound] if sound
        args += ["--codec", codec] if codec
        args += ["--supersample", supersample] if supersample
        args += ["--bitrate", bitrate] if bitrate
        args += ["--glow", glow] if glow
        args << "--benchmark" if benchmark
        args << "--measure-coverage" if coverage
        data.each { |name, path| args += ["--data", "#{name}=#{path}"] }
        args
      end
      chunks = jobs.to_i > 1 && out.match?(/\.(mp4|mov)\z/i) && !benchmark && !plate ? [jobs.to_i, (frames - from) / 24].min : 1
      return parallel(argv, out, frames: frames, fps: fps, audio: audio, chunks: chunks, from: from) if chunks > 1
      JSON.parse(run(BIN, *argv.call(out, audio)).lines.last)
    end

    # Fast draft of a time range for iterating: 1x (no supersampling), 30 fps, seconds from...to of the scene's clock (times stay
    # absolute; the soundtrack is cut to match). Finals use #render with SUPERSAMPLE=2 at the delivery frame rate.
    def preview(scene, out, from:, to:, fps: 30, width: 1920, height: 1080, supersample: 1, audio: nil, jobs: nil, data: {}, glow: nil)
      first, last = (from * fps).round, (to * fps).round
      raise ArgumentError, "preview needs 0 <= from < to" unless first >= 0 && last > first
      render(scene, out, width: width, height: height, fps: fps, frames: last, from: first, supersample: (supersample if supersample > 1),
                         audio: audio, jobs: jobs, data: data, glow: glow)
    end

    # Procedural sound effect (SoundSynth in Synth.swift) -> {"wav", "duration", "peak_at"}. spec: {"synth" => "whoosh", ...}.
    def synth(out, spec)
      ensure_built
      JSON.parse(run(BIN, "--sfx", out, "--spec", JSON.generate(spec), quiet: true).lines.last)
    end

    private

    def parallel(argv, out, frames:, fps:, audio:, chunks:, from: 0)
      raise CommandError, "Output already exists: #{out}" if File.exist?(out)
      parts = "#{out}.parts"
      FileUtils.rm_rf(parts)
      FileUtils.mkdir_p(parts)
      bounds = (0..chunks).map { |i| from + (frames - from) * i / chunks }
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
      if audio && from.positive? # a range: the soundtrack starts at the range's first frame
        audio = FFmpeg.new.excerpt(audio, File.join(parts, "range.wav"), from: (from / fps.to_f).round(6), seconds: ((frames - from) / fps.to_f).round(6))
      end
      FFmpeg.new.mux(joined, audio, out) if audio
      FileUtils.rm_rf(parts)
      ms = (Process.clock_gettime(Process::CLOCK_MONOTONIC) - started) * 1000
      { "out" => out, "frames" => frames - from, "fps" => fps, "jobs" => chunks, "ms" => ms, "render_fps" => (frames - from) / (ms / 1000) }
    end

    def ensure_built
      sources = Dir[File.join(PACKAGE, "Sources", "**", "*.swift")] + [File.join(PACKAGE, "Package.swift")]
      build if !File.file?(BIN) || sources.any? { |path| File.mtime(path) > File.mtime(BIN) }
    end
  end
end
