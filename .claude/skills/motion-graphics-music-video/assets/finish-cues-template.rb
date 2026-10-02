# Finishing-pass cue sheets from the scene's own picture events (see references/native-workflow.md, "Finish").
#
# Copy to <project>/scenes/finish_cues.rb. After the clean master exists:
#   ruby scenes/finish_cues.rb output/<name>_clean.mp4 [scenes/<name>.events.json]
# writes (all generated: edit this file, not them)
#   prompts/finish-sfx/sfx.yml         procedural Swift SoundSynth SFX (free, offline) mixed under the music -> <name>_clean_sfx.mp4
#   prompts/finish-vfx/cues.yml        Swift VFX over that mix, Metal shader cues included               -> <name>_clean_finished.mp4
#   prompts/finish-vfx-plain/cues.yml  the same without the shader cues (an A/B and a safer fallback)    -> <name>_clean_finished_plain.mp4
# then run sfx:gen, sfx:mix, vfx:render (VFX=finish-vfx-plain and VFX=finish-vfx).
#
# Event kinds written by scene-template.rb: section {name, big, neon}, flash, word, typed {until, keys}, accent {amp}.
# Times are video seconds. SFX `at` is where a sound starts; VFX `f`/`dur` are frames on a 24 fps cue grid at any video rate.
require "json"
require "yaml"
require "fileutils"

class FinishCues
  ROOT = File.expand_path("..", __dir__)
  CUE_FPS = 24.0

  # Sound palette: name => SoundSynth spec (mgraphics --sfx). Several seeds per kind so repeats don't sound copy-pasted.
  SOUNDS = {
    "whoosh_a" => { "synth" => "whoosh", "duration" => 0.6, "peak" => 0.75, "from" => 300, "to" => 4200, "seed" => 1, "pan" => [-0.7, 0.7] },
    "whoosh_b" => { "synth" => "whoosh", "duration" => 0.5, "peak" => 0.8, "from" => 400, "to" => 5500, "seed" => 2, "pan" => [0.7, -0.7] },
    "riser" => { "synth" => "riser", "duration" => 1.6, "from" => 250, "to" => 6500, "seed" => 1 },
    "impact" => { "synth" => "impact", "duration" => 1.0, "freq" => 46, "seed" => 1 },
    "impact_soft" => { "synth" => "impact", "duration" => 0.6, "freq" => 72, "seed" => 2 },
    "subdrop" => { "synth" => "subdrop", "duration" => 1.6, "from" => 95, "to" => 28 },
    "type_a" => { "synth" => "type", "seed" => 1 },
    "type_b" => { "synth" => "type", "seed" => 2 },
    "type_c" => { "synth" => "type", "seed" => 3 },
    "shimmer" => { "synth" => "shimmer", "duration" => 1.4, "freq" => 1800, "seed" => 1 }
  }.freeze
  SHADERS = %w[shockwave streaks lens heat].freeze

  def initialize(clean, events_path)
    @clean = clean
    data = JSON.parse(File.read(File.expand_path(events_path, ROOT)))
    @duration = data["duration"]
    @events = data["events"]
    @sfx, @vfx = [], []
  end

  def of(kind) = @events.select { |e| e["kind"] == kind }
  def fr(t) = (t * CUE_FPS + 1e-6).floor
  def sections = of("section")
  def section_end(sec) = (sections.map { |s| s["t"] }.select { |t| t > sec["t"] }.min || @duration)

  # Seconds from a sound's start (leading silence trimmed) to its loudest moment: the sidecar sfx:gen writes, else an estimate.
  def peak(sound)
    meta = File.join(ROOT, "output", "finish-sfx", "sounds", "#{sound}.json")
    return JSON.parse(File.read(meta))["peak_at"] if File.exist?(meta)
    s = SOUNDS.fetch(sound)
    s["synth"] == "whoosh" ? s["duration"] * s["peak"] : 0.0
  end

  def sfx(sound, at, db, **kw) = (@sfx << { "at" => at.round(3), "sound" => sound, "rel_db" => db, **kw.transform_keys(&:to_s) } if at >= 0)
  def crest(sound, t, db, **kw) = sfx(sound, t - peak(sound), db, **kw)                     # loudest moment on t
  def land(sound, t, db, **kw) = sfx(sound, t - SOUNDS.fetch(sound)["duration"], db, **kw) # ends abruptly on t
  def vfx(fx, t, dur, **kw) = @vfx << { "fx" => fx, "f" => fr(t), "dur" => dur, **kw.transform_keys(&:to_s) }

  def sound_design
    # Section changes: a whoosh cresting on the downbeat; a "big" landing gets a riser into an impact and a sub drop.
    sections.each_with_index do |sec, i|
      next if sec["t"] < 0.1
      if sec["big"]
        land("riser", sec["t"], -11)
        sfx("impact", sec["t"], -12)
        sfx("subdrop", sec["t"], -16)
      else
        crest(i.even? ? "whoosh_a" : "whoosh_b", sec["t"], -13)
      end
    end
    of("flash").each { |e| sfx("impact_soft", e["t"], -11) unless sections.any? { |s| s["big"] && (s["t"] - e["t"]).abs < 0.05 } }
    # Typewriters: a key per character, at most one every 55 ms, rotating three keys. Keep them quiet.
    of("typed").each do |e|
      last = -1
      e["keys"].each_with_index do |k, j|
        next if k - last < 0.055
        sfx(%w[type_a type_b type_c][j % 3], k, -19)
        last = k
      end
    end
  end

  def picture
    # Flashes: a punch on the flash frame and bloom two frames after (never on it: a whiteout).
    of("flash").each do |e|
      vfx("punch", e["t"], 8, amt: 0.05, radius: 2)
      vfx("glow", e["t"] + 2 / CUE_FPS, 10, amt: 0.35, radius: 14)
    end
    # Big landings: zoom creeping in under the riser, then an RGB kick, a shockwave ring and a lens kick on the hit.
    sections.select { |s| s["big"] && s["t"] > 0.1 }.each do |s|
      t = s["t"]
      vfx("zoom", t - 1.0, 24, amt: 0.04)
      vfx("rgb", t, 6, amt: 0.008)
      vfx("shockwave", t, 14, amt: 0.9, x: 0.5, y: 0.5, radius: 0.55)
      vfx("lens", t, 10, amt: 0.12)
    end
    # Word slams: squash & stretch, alternating wide/tall.
    of("word").each_with_index { |e, i| vfx("stretch", e["t"], 5, amt: 0.09, angle: i.even? ? 0 : 90) }
    # Neon line-art sections: anamorphic streaks from the thin highlights for the whole section.
    sections.select { |s| s["neon"] }.each { |s| vfx("streaks", s["t"], fr(section_end(s)) - fr(s["t"]), amt: 0.8, fade: 8) }
    # Texture on one chosen section only (not everywhere; never on top of scene grain).
    if (sec = sections.find { |s| s["name"] == "nebula" })
      vfx("grain", sec["t"], fr(section_end(sec)) - fr(sec["t"]), amt: 0.15, fade: 8)
    end
    vfx("dark", @duration - 0.6, 14, amt: 0.9, hold: 14, pre: 6) # ease out to black
  end

  def write
    sound_design
    picture
    base = File.basename(@clean, ".mp4")
    sfx_out = "output/#{base}_sfx.mp4"
    put("finish-sfx", "sfx.yml", { "source" => @clean, "out" => sfx_out, "rel_db" => -13, "peak_db" => -11, "max_gain_db" => 14,
                                   "sounds" => SOUNDS, "cues" => @sfx.sort_by { |c| c["at"] } })
    cues = @vfx.select { |c| c["f"] >= 0 }.sort_by { |c| [c["f"], c["fx"]] }
    put("finish-vfx", "cues.yml", { "source" => sfx_out, "out" => "output/#{base}_finished.mp4", "bitrate" => 15_000_000, "cues" => cues })
    put("finish-vfx-plain", "cues.yml", { "source" => sfx_out, "out" => "output/#{base}_finished_plain.mp4", "bitrate" => 15_000_000,
                                          "cues" => cues.reject { |c| SHADERS.include?(c["fx"]) } })
    { sfx: @sfx.size, vfx: @vfx.size, sfx_out: sfx_out }
  end

  private

  def put(dir, file, doc)
    path = File.join(ROOT, "prompts", dir)
    FileUtils.mkdir_p(path)
    File.write(File.join(path, file), "# generated by scenes/finish_cues.rb — edit that, not this\n" + YAML.dump(doc))
  end
end

if $PROGRAM_NAME == __FILE__
  clean = ARGV[0] or abort "usage: ruby scenes/finish_cues.rb output/<name>_clean.mp4 [scenes/<name>.events.json]"
  events = ARGV[1] || Dir[File.join(__dir__, "*.events.json")].first or abort "no scenes/*.events.json: run the scene generator first"
  puts JSON.generate(FinishCues.new(clean, events).write)
end
