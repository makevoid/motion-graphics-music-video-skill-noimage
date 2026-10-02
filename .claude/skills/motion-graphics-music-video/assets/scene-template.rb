# Scene generator template for a native Swift motion-graphics music video (see references/native-workflow.md).
#
# Copy to <project>/scenes/<name>.rb, edit the constants and the section methods, then:
#   ruby scenes/<name>.rb      -> scenes/<name>.json         the scene for graphics:preview / graphics:render
#                                 scenes/<name>.events.json  picture events + section bounds for scenes/finish_cues.rb
#
# Clock: every time is video seconds (0 = SONG_START in the song = the first frame). The music map is in song seconds and is
# shifted here once, so cues read b(bar, beat) in the song's own bar numbers. Times are fps-independent: the same JSON renders
# 30 fps previews and the 60 fps master.
require "json"

module Video
  NAME = File.basename(__FILE__, ".rb")
  ROOT = File.expand_path("..", __dir__)                  # the project (this file lives in <project>/scenes)
  W, H = 1920, 1080
  CX, CY = W / 2.0, H / 2.0
  SONG_START = 0.0      # song second of the first frame: the `from` of audio:excerpt
  DURATION = 30.0       # video seconds: the excerpt length (frames = DURATION * fps)
  GRID = 60.0           # delivery fps; f(t) snaps cue starts to its frames so hits land on the frame that contains the beat
  BPM = 120.0           # only used when audio/map/ is missing (constant grid fallback); run audio:map for real songs

  # Palette and type: take them from docs/PLAN.md. Fonts are PostScript names of faces copied by fonts:copy (an unknown name
  # fails the render); FONT_FILES are their files in tools/graphics/fonts/.
  INK, PAPER, HOT, GOLD, COOL, VIOLET = "#0B0A09", "#EDE6D8", "#FF5A1F", "#FFC531", "#2EE6FF", "#7A3CFF"
  DISPLAY, MONO = "Impact", "AndaleMono"
  FONT_FILES = %w[impact.ttf andale-mono.ttf].freeze

  # The running order: [section method, length in bars]; nil = until the end. Sections start on downbeats, counted from the
  # first bar that starts inside the video. Rename, reorder and add methods freely; each draws only inside its own bounds.
  PLAN = [[:intro, 4], [:hook, 4], [:nebula, 4], [:outro, nil]].freeze

  # Beat grid, drum hits, vocal onsets and sections from audio:map (audio/map/*.json), shifted to video seconds.
  class MusicMap
    attr_reader :sections

    def initialize(dir)
      path = File.join(dir, "beatmap.json")
      if File.exist?(path)
        beats = JSON.parse(File.read(path))["beats"]
        @t = beats.map { |x| x["t"] - SONG_START }
        @bar0 = {}
        beats.each_with_index { |x, i| @bar0[x["bar"]] ||= i if x["pos"].zero? }
      else # constant fallback: bar 0 at video 0
        n = ((DURATION + 30) * BPM / 60).ceil
        @t = (0..n).map { |i| i * 60.0 / BPM }
        @bar0 = (0..n / 4).to_h { |bar| [bar, bar * 4] }
      end
      @hits = load(dir, "hits.json") { |h| %w[kick snare hat].to_h { |k| [k, (h[k] || []).map { |x| [x["t"] - SONG_START, x["s"]] }] } } || Hash.new([])
      @vox = load(dir, "vocals.json") { |v| v["onsets"].map { |o| [o["t"] - SONG_START, o["strength"] || 1] } } || []
      @sections = load(dir, "sections.json") { |s| s["sections"].map { |x| x.merge("t" => x["t"] - SONG_START, "end" => x["end"] - SONG_START) } } || []
    end

    # Video time of fractional beat `pos` (0 = downbeat) of song bar `bar`, interpolated on the drift-following grid.
    def beat(bar, pos = 0)
      i = @bar0.fetch(bar.floor) { raise ArgumentError, "bar #{bar} is not in the beat map" } + (bar - bar.floor) * 4 + pos
      i0 = [i.floor, @t.size - 2].min
      (@t[i0] + (i - i0) * (@t[i0 + 1] - @t[i0])).round(4)
    end

    def first_bar_after(t) = @bar0.keys.sort.find { |bar| beat(bar) >= t - 1e-3 }
    def hits(kind, from, to, min: 0.0) = @hits[kind].select { |t, s| t >= from && t < to && s >= min }.map(&:first)
    def vox(from, to, min: 0.5) = @vox.select { |t, s| t >= from && t < to && s >= min }.map(&:first)

    private

    def load(dir, name)
      path = File.join(dir, name)
      yield JSON.parse(File.read(path)) if File.exist?(path)
    end
  end

  class Builder
    TAU = 2 * Math::PI

    def initialize
      @nodes = []
      @events = []  # {kind:, t:, ...}: what finish_cues.rb puts sound and VFX on
      @accents = [] # [t, amplitude]: camera hits
      @map = MusicMap.new(File.join(ROOT, "audio", "map"))
      @rng = Random.new(7) # seeded: the same JSON on every run
    end

    # ------------------------------------------------------------------ timing
    def b(bar, pos = 0) = @map.beat(bar, pos)
    def f(t) = (t * GRID + 1e-6).floor / GRID
    def hits(kind, from, to, min: 0.5) = @map.hits(kind, from, to, min: min)
    def rand(a = 1.0, b = nil) = b ? a + @rng.rand * (b - a) : @rng.rand * a
    def event(kind, t, **kw) = @events << { kind: kind, t: t.round(4), **kw }
    def accent(t, amp = 16) = (@accents << [t, amp]; event(:accent, t, amp: amp))

    # A track sampled from a Ruby function of time (orbits, physics, anything not expressible as a few eased keys).
    def sample_track(s, e, step = 1 / 30.0)
      (0..((e - s) / step).ceil).map { |j| t = [s + j * step, e].min; [t.round(4), yield(t)] }.uniq(&:first)
    end

    # A starfield/"beat" phase track: 0 on each beat time, rising to 1 just before the next.
    def beat_phase(times) = times.each_cons(2).flat_map { |t0, t1| [[t0, 0], [t1 - 0.001, 1]] }

    # ------------------------------------------------------------------ node constructors (plain hashes = scene JSON)
    def group(children, **kw) = { type: "group", children: children }.merge(kw)

    def text(str, font: DISPLAY, size: 120, x: CX, y: CY, fill: PAPER, align: "center", **kw)
      { type: "text", text: str, font: font, size: size, x: x, y: y, fill: fill, align: align }.merge(kw)
    end

    # Oversized so the camera shake never reveals an edge.
    def rect(fill, start, stop, **kw) = { type: "rect", x: -120, y: -120, width: W + 240, height: H + 240, fill: fill, start: start, end: stop }.merge(kw)
    def bg(color, from, to, **kw) = @nodes << rect(color, f(from), f(to), **kw)

    def flash(t, color = PAPER, frames = 1)
      event(:flash, t)
      bg(color, t, f(t) + frames / GRID)
    end

    def star_points(r, inner, rays = 5, rot = -Math::PI / 2)
      (0...rays * 2).map { |i| a = rot + i * Math::PI / rays; rr = i.even? ? r : inner; [Math.cos(a) * rr, Math.sin(a) * rr] }
    end

    def ngon(r, n, rot = 0) = (0...n).map { |i| a = rot + i * TAU / n; [Math.cos(a) * r, Math.sin(a) * r] }

    # ------------------------------------------------------------------ reusable moves
    # Giant word that slams in on `start` with outline echoes trailing toward (dx, dy) and a slow push-in until `stop`.
    def echo_word(str, start:, stop:, font: DISPLAY, size: 380, fill: PAPER, echo: HOT, copies: 4, dx: 0, dy: 0.09, x: CX, y: CY, cap: 0.8)
      base = y + size * cap / 2
      kids = copies.downto(1).map do |i|
        text(str, font: font, size: size, x: x + dx * size * i, y: base + dy * size * i, fill: nil, outline: echo,
                  outlineWidth: [size / 90.0, 2].max, opacity: (1 - i / (copies + 1.0)) * 0.9, start: f(start + i / GRID * 2), end: stop)
      end
      hit = group(kids + [text(str, font: font, size: size, x: x, y: base, fill: fill)], start: f(start), end: stop, x: x, y: CY, anchor: [x, CY], entrance: "slam")
      push = [[f(start), 1.0], [stop, 1.05]]
      group([hit], start: f(start), end: stop, x: x, y: CY, anchor: [x, CY], tracks: { scaleX: push, scaleY: push })
    end

    # One echo word per cue, each holding until the next: [[word, time, {overrides}], ...]. Sized to fit the frame.
    def words(list, stop, **kw)
      list.each_with_index do |(w, t, o), i|
        t_end = i + 1 < list.size ? list[i + 1][1] : stop
        event(:word, t, word: w)
        size = [(o || {})[:size] || 380, 1700.0 / (w.size * 0.52)].min.round
        @nodes << echo_word(w, start: t, stop: f(t_end), size: size, **kw, **(o || {}).except(:size))
      end
    end

    # Radial streaks that shoot outward: trimEnd leads, trimStart chases.
    def rays(t, count:, inner:, outer:, colors:, width: 3, dur: 0.45, x: CX, y: CY)
      count.times.map do |i|
        a = i * TAU / count + rand(-0.25, 0.25) * Math::PI / count
        r0, r1, d = inner * rand(0.8, 1.2), outer * rand(0.6, 1.15), dur * rand(0.7, 1.2)
        { type: "line", points: [[Math.cos(a) * r0, Math.sin(a) * r0], [Math.cos(a) * r1, Math.sin(a) * r1]], x: x, y: y,
          stroke: colors[i % colors.size], strokeWidth: width * rand(0.6, 1.4), start: f(t), end: t + d + 0.05,
          tracks: { trimEnd: [[t, 0], [t + d * 0.55, 1, "outCubic"]], trimStart: [[t + d * 0.15, 0], [t + d, 1, "outCubic"]] } }
      end
    end

    # Polygon shards flung from a point, spinning and fading.
    def shards(t, count:, colors:, x: CX, y: CY, speed: 900, size: 40, dur: 0.9)
      count.times.map do |i|
        a, dist, s = rand(TAU), speed * rand(0.35, 1.0), size * rand(0.4, 1.3)
        pts = 3.times.map { |k| ang = k * 2.1 + rand(-0.4, 0.4); [Math.cos(ang) * s, Math.sin(ang) * s] }
        c = colors[i % colors.size]
        outlined = rand < 0.35
        { type: "polygon", points: pts, fill: outlined ? nil : c, stroke: outlined ? c : nil, strokeWidth: 3, start: f(t), end: t + dur,
          tracks: { x: [[t, x], [t + dur, x + Math.cos(a) * dist, "outExpo"]], y: [[t, y], [t + dur, y + Math.sin(a) * dist, "outExpo"]],
                    rotation: [[t, rand(6.28)], [t + dur, rand(-9, 9), "outCubic"]], opacity: [[t + dur * 0.6, 1], [t + dur, 0]] } }
      end
    end

    def ring_burst(t, r: 60, to: 6, color: PAPER, width: 3, dur: 0.4, x: CX, y: CY)
      { type: "circle", radius: r, fill: nil, stroke: color, strokeWidth: width, x: x, y: y, start: f(t), end: t + dur,
        tracks: { scaleX: [[t, 0.6], [t + dur, to, "outCubic"]], scaleY: [[t, 0.6], [t + dur, to, "outCubic"]], opacity: [[t, 1], [t + dur, 0]] } }
    end

    # Typewriter line (monospace advance 0.6 em) with a block cursor; records key times for typing SFX.
    def typed(str, t0, t1, stop:, x: 96, y: H - 150, size: 34, fill: PAPER, align: "left", cursor: true, **kw)
      n = [str.length, 1].max
      adv = size * 0.6
      x0 = { "center" => x - n * adv / 2, "right" => x - n * adv }.fetch(align, x)
      at = ->(i) { t0 + (t1 - t0) * i / n }
      event(:typed, t0, until: t1, keys: (1..n).reject { |i| str[i - 1] == " " }.map { |i| at.(i).round(4) })
      out = [text(str, font: MONO, size: size, x: x0, y: y, fill: fill, align: "left", start: f(t0), end: stop,
                  reveal: [[t0, 0]] + (1..n).map { |i| [at.(i), i.to_f / n, "hold"] }, **kw)]
      return out unless cursor
      blink = [[t0, 1]] + (0..((stop - t1) / 0.25).floor).map { |k| [t1 + 0.25 * (k + 1), k.even? ? 0 : 1, "hold"] }
      out << { type: "rect", x: 0, y: y - size * 0.78, width: adv * 0.9, height: size * 0.92, fill: HOT, start: f(t0), end: stop,
               tracks: { x: [[t0, x0]] + (1..n).map { |i| [at.(i), x0 + i * adv, "hold"] }, opacity: blink } }
    end

    # Neon line art: thin strokes + glow halos + whitened cores on a section's nodes (render finals with SUPERSAMPLE=2).
    def neon(nodes, glow: 9, core: 0.55) = nodes.each { |n| n[:glow] ||= glow; n[:glowCore] ||= core }

    # ------------------------------------------------------------------ sections (examples: replace with the plan's)
    # intro: a star outline draws on bar by bar over a pulsing starfield; a typed caption; neon line art.
    def intro(s, e, bars)
      bg(INK, s, e)
      beats = bars.flat_map { |bar| (0..3).map { |p| b(bar, p) } } + [e]
      @nodes << { type: "shader", shader: "starfield", x: -120, y: -120, width: W + 240, height: H + 240, center: [CX + 120, CY + 120], seed: 11,
                  colors: [PAPER, HOT, COOL], stars: 0.85, twinkle: 0.6, pulse: 0.7, drift: 0.4, start: f(s), end: f(e),
                  tracks: { beat: beat_phase(beats), brightness: [[s, 0], [s + 1.0, 0.9, "smooth"]] } }
      first = @nodes.size
      trim = [[s, 0]] + bars.each_with_index.map { |bar, i| [b(bar), ((i + 1.0) / bars.size).round(3), "inOutCubic"] }
      @nodes << { type: "polygon", points: star_points(300, 120), fill: nil, stroke: PAPER, strokeWidth: 2, boil: 2, seed: 3, x: CX, y: CY,
                  start: f(s), end: f(e), tracks: { trimEnd: trim, rotation: [[s, -0.6], [e, 0.1, "outCubic"]] } }
      bars.each_with_index do |bar, i| # a ring breathes out on every downbeat
        t = b(bar)
        @nodes << ring_burst(t, r: 320, to: 1.4, color: i.odd? ? HOT : PAPER, width: 1.5, dur: 0.8)
      end
      neon(@nodes[first..])
      @nodes.concat typed("SIGNAL ACQUIRED", b(bars[1]), b(bars[1], 2), stop: f(e), size: 30)
      event(:section, s, name: "intro", neon: true)
    end

    # hook: one giant word per half bar (put the real lyric words on vocal onsets: @map.vox), rays and a camera hit on kicks.
    def hook(s, e, bars)
      bg(INK, s, e)
      lyric = %w[MAKE SOME NOISE NOW] # placeholder copy: use the song's words from audio/map/vocals.json or a transcript
      times = bars.flat_map { |bar| [b(bar), b(bar, 2)] }
      cues = times.each_with_index.map { |t, i| [lyric[i % lyric.size], t, i.odd? ? { fill: HOT, echo: PAPER } : {}] }
      words(cues, f(e))
      # Kicks fused with an 808 can be missing from hits.json: fall back to the strong snares (read the map's bar patterns).
      drums = hits("kick", s, e)
      drums = hits("snare", s, e, min: 0.6) if drums.empty?
      drums.each_with_index do |t, i|
        accent(t, i.zero? ? 30 : 14)
        @nodes.concat rays(t, count: 18, inner: 200, outer: 1100, colors: [HOT, GOLD, PAPER], width: 4)
      end
      @nodes.concat shards(s, count: 40, colors: [HOT, PAPER, GOLD, COOL], speed: 1200)
      flash(s, PAPER)
      event(:section, s, name: "hook", big: true)
    end

    # nebula: a procedural Metal gas cloud reveals from the centre; a ring of type orbits it; snares ping rings.
    def nebula(s, e, _bars)
      bg(INK, s, e)
      @nodes << { type: "shader", shader: "nebula", x: 0, y: 0, width: W, height: H, center: [CX, CY], radius: 620, seed: 1811, detail: 2.2, swirl: 3.0,
                  colors: ["#3A1060", HOT, GOLD], filaments: 1.2, core: 0.8, stars: 0.6, drift: 0.25, start: f(s), end: f(e),
                  tracks: { reveal: [[s, 0], [s + 1.2, 1, "outCubic"]], brightness: [[s, 0.6], [s + 0.6, 1.1], [e, 0.9]] } }
      first = @nodes.size
      @nodes << { type: "textpath", text: "EVERY STAR YOU SEE IS A MESSAGE FROM THE PAST · " * 2, font: MONO, size: 26, radius: 420, fill: PAPER,
                  x: CX, y: CY, start: f(s), end: f(e), tracks: { offset: [[s, 0], [e, -900]] } }
      @nodes << { type: "rings", count: 10, radius: 80, spacing: 70, stroke: COOL, strokeWidth: 1.5, fade: 0.1, x: CX, y: CY, start: f(s), end: f(e),
                  tracks: { phase: [[s, 0], [e, 3]] } }
      hits("snare", s, e).each { |t| @nodes << ring_burst(t, r: 90, to: 6, color: GOLD, width: 2) }
      neon(@nodes[first..], glow: 8)
      event(:section, s, name: "nebula", neon: true)
    end

    # outro: the star returns with a ring on each strong snare, undraws, and an end card types out; fade to black on the last second.
    def outro(s, e, _bars)
      bg(INK, s, e)
      first = @nodes.size
      @nodes << { type: "polygon", points: star_points(300, 120), fill: nil, stroke: HOT, strokeWidth: 3, boil: 2, seed: 3, x: CX, y: CY, start: f(s), end: e,
                  tracks: { trimEnd: [[s, 0], [s + 0.8, 1, "outCubic"]], trimStart: [[e - 2.0, 0], [e - 0.3, 1, "inCubic"]], rotation: [[s, -0.25], [e, 0.4]] } }
      hits("snare", s, e - 2.0, min: 0.6).each_with_index { |t, i| @nodes << ring_burst(t, r: 330, to: 1.5, color: i.even? ? HOT : PAPER, width: 1.5, dur: 0.7) }
      neon(@nodes[first..])
      @nodes.concat typed("END OF SIGNAL", s + 0.6, s + 1.4, stop: e, x: CX, y: CY + 400, size: 30, align: "center")
      @nodes << rect(INK, e - 1.0, e, tracks: { opacity: [[e - 1.0, 0], [e - 0.1, 1, "smooth"]] })
      event(:section, s, name: "outro")
    end

    # ------------------------------------------------------------------ whole-frame layers
    # Camera: a decaying hold-frame shake and a scale punch on every accent (8 frames each at 24 fps cadence).
    def camera(children)
      xs, ys, ss = [[-1, CX]], [[-1, CY]], [[-1, 1.0]]
      kept = @accents.sort_by(&:first).each_with_object([]) { |h, out| out << h if out.empty? || h[0] >= out.last[0] + 8 / 24.0 }
      kept.each do |t, amp|
        t0 = f(t)
        8.times do |j|
          a = amp * (1 - j / 8.0)**2
          xs << [t0 + j / 24.0, CX + (j == 7 ? 0 : rand(-a, a)), "hold"]
          ys << [t0 + j / 24.0, CY + (j == 7 ? 0 : rand(-a, a)), "hold"]
        end
        ss << [t0, 1.0, "hold"] if t0 > ss.last[0]
        ss << [t0 + 0.01, 1.0 + amp / 600.0, "hold"]
        ss << [t0 + 6 / 24.0, 1.0, "outCubic"]
      end
      group(children, x: CX, y: CY, anchor: [CX, CY], tracks: { x: xs, y: ys, scaleX: ss, scaleY: ss })
    end

    # Photosensitivity notice for videos with flashes/strobes: blinks at ~2 Hz (under the 3 Hz threshold), outside the camera.
    def epilepsy_warning(s, e, red: "#FF2B2B")
      blink, t, on = [], s, true
      (blink << [t, on ? 1 : 0.15, "hold"]; t += on ? 0.32 : 0.18; on = !on) while t < e
      [group([text("EPILEPSY WARNING · FLASHING LIGHTS", font: MONO, size: 18, x: W - 104, y: H - 74, fill: red, align: "right"),
              { type: "polygon", points: [[0, -14], [14, 11], [-14, 11]], fill: nil, stroke: red, strokeWidth: 2.2, x: W - 104 - 34 * 18 * 0.6 - 30, y: H - 80 }],
             start: f(s), end: f(e), glow: 6, glowCore: 0.6, tracks: { opacity: blink })]
    end

    def build
      bar = @map.first_bar_after(0)
      PLAN.each do |name, n|
        bars = n ? (bar...bar + n).to_a : (bar..).take_while { |x| (b(x) rescue DURATION) < DURATION - 0.5 }
        break if bars.empty? || b(bars.first) >= DURATION - 0.5 # the song ran out: drop the remaining sections
        s = b(bars.first)
        e = n ? b(bar + n) : DURATION
        s = 0.0 if name == PLAN.first[0] # the first section also covers any pickup before its downbeat
        send(name, s, [e, DURATION].min, bars)
        bar += n if n
      end
      @nodes = [camera(@nodes)] + epilepsy_warning(0.5, 2.5)
      {
        version: 1, background: INK,
        fonts: FONT_FILES.map { |n| "../tools/graphics/fonts/#{n}" },
        nodes: @nodes,
        effects: [{ name: "CIBloom", parameters: { inputRadius: 10, inputIntensity: 0.35 } }]
      }
    end

    def events = { song_start: SONG_START, duration: DURATION, events: @events.sort_by { |e| e[:t] } }
  end
end

if $PROGRAM_NAME == __FILE__
  builder = Video::Builder.new
  doc = builder.build
  out = File.join(__dir__, "#{Video::NAME}.json")
  File.write(out, JSON.generate(doc))
  File.write(File.join(__dir__, "#{Video::NAME}.events.json"), JSON.pretty_generate(builder.events))
  puts JSON.generate(path: out, nodes: doc[:nodes].size, seconds: Video::DURATION, frames_60fps: (Video::DURATION * 60).round)
end
