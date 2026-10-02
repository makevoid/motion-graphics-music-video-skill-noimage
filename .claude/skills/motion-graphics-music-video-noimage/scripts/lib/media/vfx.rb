require "json"
require "yaml"
require "etc"
require_relative "shell"
require_relative "anim"
require_relative "ffmpeg"
require_relative "python"
require_relative "graphics"

module Media
  # Native Swift VFX: decode, light layers, effects, audio and encode in memory.
  class Vfx < Shell
    ROOT = File.expand_path("../..", __dir__)
    PACKAGE = File.join(ROOT, "tools", "vfx")
    BIN = File.join(PACKAGE, ".build", "release", "mvfx")
    CORE_IMAGE = %w[punch zoom shake whip mblur edgeblur glow flash dark rgb glitch tv grain stretch echo bands shockwave lens heat streaks].freeze
    LIGHTS = %w[leak flare glints].freeze

    attr_reader :name, :dir

    def initialize(name = ENV.fetch("VFX", "run4-vfx"))
      @name = name
      @dir = File.join(ROOT, "output", name)
      FileUtils.mkdir_p(@dir)
    end

    def config = @config ||= YAML.safe_load_file(File.join(ROOT, "prompts", name, "cues.yml"))
    def source = File.expand_path(config.fetch("source"), ROOT)
    def out = File.expand_path(config.fetch("out"), ROOT)
    def path(file) = File.join(dir, file)

    # Song beat grid + onsets (scripts/beats.py) and picture cuts (scripts/cuts.py) of the source, for placing cues.
    def analyze
      wav = FFmpeg.new.extract_audio(source, path("song.wav"))
      File.write(path("beats.json"), run(Media::Python.new.executable, File.join(Python::SCRIPTS, "beats.py"), wav, "24", quiet: true))
      File.write(path("cuts.json"), run(Media::Python.new.executable, File.join(Python::SCRIPTS, "cuts.py"), source, quiet: true))
      { beats: JSON.parse(File.read(path("beats.json"))), cuts: JSON.parse(File.read(path("cuts.json"))) }
    end

    def build
      run("swift", "build", "-c", "release", "--package-path", PACKAGE)
      BIN
    end

    # cues.yml -> output/<name>/cues.json (checked: known fx, integer f/dur, sorted by frame).
    def cues
      list = config.fetch("cues").map do |c|
        fx = c.fetch("fx")
        raise ArgumentError, "unknown fx #{fx.inspect} in #{c} (#{(CORE_IMAGE + LIGHTS).join(" ")})" unless (CORE_IMAGE + LIGHTS).include?(fx)
        raise ArgumentError, "cue needs integer f and dur: #{c}" unless c["f"].is_a?(Integer) && c["dur"].is_a?(Integer) && c["dur"].positive?
        c
      end.sort_by { |c| [c["f"], c["fx"]] }
      File.write(path("cues.json"), JSON.pretty_generate({ "cues" => list }))
      path("cues.json")
    end

    # Stills of `list` frames with every effect -> output/<name>/stills/NNNN.png and a contact sheet stills.jpg (labelled by frame).
    def stills(list)
      cues
      FileUtils.rm_rf(path("stills"))
      mvfx("--stills", path("stills"), "--only", list.join(","))
      pngs = list.sort.map { |f| path(format("stills/%04d.png", f)) }
      run("magick", "montage", *(["-font", FONT] if FONT), "-pointsize", "20", "-fill", "white", "-label", "%t", *pngs,
          "-tile", "4x", "-geometry", "640x358+4+4", "-background", "black", path("stills.jpg"))
      path("stills.jpg")
    end

    # Frames [from, to) with the song, as its own video -> output/<name>/clip_<from>_<to>.mp4.
    def clip(from, to)
      cues
      mvfx("--out", path("clip_#{from}_#{to}.mp4"), "--from", from, "--to", to, *bitrate)
      path("clip_#{from}_#{to}.mp4")
    end

    # The whole video -> config `out` (the source's audio stream copied). jobs > 1 renders that many chunks in parallel mvfx
    # processes (each seeks to its start; echo ghosts are decoded from just before it), joins the pictures by stream copy and
    # copies the source's audio track whole, so chunk edges never touch the sound.
    def render(jobs: Integer(ENV["JOBS"] || [Etc.nprocessors - 2, 1].max.clamp(1, 8)))
      cues
      ensure_built # once, before any parallel chunk could start a build
      raise CommandError, "Output already exists: #{out}" if File.exist?(out)
      total = (FFmpeg.new.duration(source) * 24).round # cue-grid frames
      chunks = [jobs, total / 24].min
      return (mvfx("--out", out, *bitrate) && out) if chunks <= 1
      parts = "#{out}.parts"
      FileUtils.rm_rf(parts)
      FileUtils.mkdir_p(parts)
      bounds = (0..chunks).map { |i| total * i / chunks }
      threads = bounds.each_cons(2).with_index.map do |(from, to), i|
        file = File.join(parts, format("%03d.mp4", i))
        thread = Thread.new { mvfx("--out", file, "--from", from, "--to", to, "--no-audio", *bitrate, quiet: true) }
        thread.report_on_exception = false
        [file, thread]
      end
      errors = threads.filter_map do |_, thread|
        thread.value
        nil
      rescue CommandError => e
        e
      end
      raise errors.first if errors.any?
      list = File.join(parts, "list.txt")
      File.write(list, threads.map { |f, _| "file '#{f}'\n" }.join)
      run("ffmpeg", "-y", "-v", "error", "-f", "concat", "-safe", "0", "-i", list, "-i", source,
          "-map", "0:v:0", "-map", "1:a:0?", "-c", "copy", out)
      FileUtils.rm_rf(parts)
      out
    end

    def frames = @frames ||= FFmpeg.new.run("ffprobe", "-v", "error", "-select_streams", "v:0", "-count_packets", "-show_entries",
                                             "stream=nb_read_packets", "-of", "csv=p=0", source, quiet: true).to_i

    private

    # cues.yml `bitrate:` (bits/s, e.g. 15_000_000) for the encode; default scales with size and frame rate.
    def bitrate = config["bitrate"] ? ["--bitrate", Integer(config["bitrate"])] : []

    def ensure_built
      dependencies = Dir[File.join(PACKAGE, "Sources", "**", "*.swift")] + Dir[File.join(Graphics::PACKAGE, "Sources", "**", "*.swift")] + [File.join(PACKAGE, "Package.swift"), File.join(Graphics::PACKAGE, "Package.swift")]
      build if !File.exist?(BIN) || dependencies.any? { |f| File.mtime(f) > File.mtime(BIN) }
    end

    def mvfx(*args, quiet: false)
      ensure_built
      if config["lights"]
        raise ArgumentError, "lights must be a native .json scene" unless File.extname(config["lights"]) == ".json"
        args += ["--lights-scene", File.expand_path(config["lights"], ROOT)]
      end
      JSON.parse(run(BIN, "--in", source, "--cues", path("cues.json"), *args.map(&:to_s), quiet: quiet).lines.last)
    end
  end
end
