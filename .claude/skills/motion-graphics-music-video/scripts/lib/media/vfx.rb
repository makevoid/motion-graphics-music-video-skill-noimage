require "json"
require "yaml"
require_relative "shell"
require_relative "anim"
require_relative "ffmpeg"
require_relative "python"

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

    # The whole video -> config `out` (the source's audio stream copied).
    def render
      cues
      mvfx("--out", out, *bitrate)
      out
    end

    def frames = @frames ||= FFmpeg.new.run("ffprobe", "-v", "error", "-select_streams", "v:0", "-count_packets", "-show_entries",
                                             "stream=nb_read_packets", "-of", "csv=p=0", source, quiet: true).to_i

    private

    # cues.yml `bitrate:` (bits/s, e.g. 15_000_000) for the encode; default scales with size and frame rate.
    def bitrate = config["bitrate"] ? ["--bitrate", Integer(config["bitrate"])] : []

    def mvfx(*args)
      dependencies = Dir[File.join(PACKAGE, "Sources", "**", "*.swift")] + Dir[File.join(Graphics::PACKAGE, "Sources", "**", "*.swift")] + [File.join(PACKAGE, "Package.swift"), File.join(Graphics::PACKAGE, "Package.swift")]
      build if !File.exist?(BIN) || dependencies.any? { |f| File.mtime(f) > File.mtime(BIN) }
      if config["lights"]
        raise ArgumentError, "lights must be a native .json scene" unless File.extname(config["lights"]) == ".json"
        args += ["--lights-scene", File.expand_path(config["lights"], ROOT)]
      end
      JSON.parse(run(BIN, "--in", source, "--cues", path("cues.json"), *args.map(&:to_s)).lines.last)
    end
  end
end
