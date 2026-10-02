require_relative "spec_helper"
# Synthetic drum track with known hit times: tempo ramps 120 -> 123 BPM, kick on beat 1 and the "and" of 2, snare on
# 2 and 4, closed hats on 8ths, sub bass except in a 4-bar breakdown (bars 8-11), and a sung line every other bar.
RSpec.describe "Music map (scipy beat/hit/vocal/section analysis)", :media do
  RATE = 44_100
  BARS = 20

  def beat_times
    t, out = 0.25, []
    (BARS * 4).times { |n| out << t; t += 60.0 / (120 + 3.0 * n / (BARS * 4)) }
    out
  end

  def write_wav(path, samples)
    pcm = samples.map { |v| (v.clamp(-1.0, 1.0) * 32_000).round }.pack("s<*")
    File.open(path, "wb") do |f|
      f << ["RIFF", 36 + pcm.bytesize, "WAVE", "fmt ", 16, 1, 1, RATE, RATE * 2, 2, 16, "data", pcm.bytesize].pack("a4Va4a4VvvVVvva4V") << pcm
    end
    path
  end

  def add(buf, at, len)
    a = (at * RATE).round
    (0...(len * RATE).round).each { |i| buf[a + i] += yield(i.to_f / RATE) if a + i < buf.size }
  end

  def truth
    @truth ||= begin
      beats = beat_times
      period = ->(n) { (beats[n + 1] || beats[n] + (beats[n] - beats[n - 1])) - beats[n] }
      kicks, snares, hats = [], [], []
      beats.each_with_index do |t, n|
        bar, pos = n.divmod(4)
        breakdown = (8..11).cover?(bar)
        kicks << t if pos.zero? && !breakdown
        kicks << t + 0.5 * period.(n) if pos == 1 && !breakdown
        snares << t if pos.odd?
        hats << t; hats << t + period.(n) / 2
      end
      { beats: beats, kicks: kicks, snares: snares, hats: hats - snares }
    end
  end

  def drums_wav
    @drums_wav ||= begin
      rng = Random.new(7)
      buf = Array.new(((truth[:beats].last + 1.5) * RATE).round, 0.0)
      truth[:kicks].each { |t| add(buf, t, 0.25) { |x| 0.9 * Math.exp(-x / 0.06) * Math.sin(2 * Math::PI * (50 * x + 60 * 0.03 * (1 - Math.exp(-x / 0.03)))) } }
      truth[:snares].each { |t| add(buf, t, 0.18) { |x| 0.5 * Math.exp(-x / 0.045) * (rng.rand * 2 - 1) } }
      truth[:hats].each { |t| add(buf, t, 0.05) { |x| 0.18 * Math.exp(-x / 0.012) * [8_100, 9_340, 10_870, 12_210].sum { |f| Math.sin(2 * Math::PI * f * x) } / 4 } }
      truth[:beats].each_slice(4).with_index do |bar, b|
        next if (8..11).cover?(b)
        len = bar.last - bar.first + 0.45
        add(buf, bar.first, len) { |x| 0.25 * [x / 0.02, 1, (len - x) / 0.02].min * Math.sin(2 * Math::PI * 41 * x) } # declicked
      end
      write_wav(file("drums.wav"), buf)
    end
  end

  def vocal_lines = truth[:beats].each_slice(8).map { |b| [b[0] + 0.1, b[4]] }

  def vocals_wav
    buf = Array.new(((truth[:beats].last + 1.5) * RATE).round, 0.0)
    vocal_lines.each do |s, e|
      add(buf, s, e - s) { |x| env = [x / 0.03, 1, (e - s - x) / 0.05].min.clamp(0, 1); 0.3 * env * (1..6).sum { |h| Math.sin(2 * Math::PI * 260 * h * x) / h } }
    end
    write_wav(file("vocals.wav"), buf)
  end

  def nearest(list, t) = list.min_by { |x| (x - t).abs }

  it "tracks a drifting tempo, downbeats, drum attacks, vocal lines and the breakdown through the Ruby tasks" do
    drums, vocals = drums_wav, vocals_wav
    beatmap, hits, vox, secs = %w[beatmap hits vocals sections].map { |n| file("#{n}.json") }
    [["audio:beatmap", drums, beatmap], ["audio:hits", drums, hits, beatmap], ["audio:vocals", vocals, vox, beatmap],
     ["audio:sections", drums, secs, beatmap, hits, vox]].each do |task, *args|
      _, err, status = cli("#{task}[#{args.join(",")}]")
      expect(status.exitstatus).to eq(0), err
    end

    b = JSON.parse(File.read(beatmap))
    expect(b["tempo_mode"]).to eq("local")
    expect(b["bpm"]).to be_within(2).of(121.5)
    tracked = b["beats"].map { |x| x["t"] }
    truth[:beats][2..-3].each { |t| expect((nearest(tracked, t) - t).abs).to be < 0.015 }
    downbeats = b["beats"].select { |x| x["pos"].zero? }.map { |x| x["t"] }
    truth[:beats].each_slice(4).map(&:first)[1..-2].each { |t| expect((nearest(downbeats, t) - t).abs).to be < 0.015 }
    expect(b["snare_feel"]).to eq("backbeat")

    h = JSON.parse(File.read(hits))
    { "kick" => [truth[:kicks], [0, 6]], "snare" => [truth[:snares], [4, 12]] }.each do |name, (times, steps)|
      found = h[name]
      expect(found.size).to be_within((times.size * 0.1).ceil).of(times.size), name
      expect(found.map { |x| x["step"] }.uniq.sort).to eq(steps), name
      times.each { |t| expect((nearest(found.map { |x| x["t"] }, t) - t).abs).to be < 0.012 } # attack, not energy peak
    end
    expect(h["hat"].map { |x| x["step"] }.uniq).to all(be_even)
    expect(h["hat"].size).to be >= (truth[:hats].size * 0.8)
    expect(h["bars"].find { |r| r["bar"] == 2 }["snare"]).to eq("....x.......x...")

    v = JSON.parse(File.read(vox))
    expect(v["lines"].size).to eq(vocal_lines.size)
    v["lines"].zip(vocal_lines).each { |row, (s, e)| expect(row["s"]).to be_within(0.03).of(s); expect(row["e"]).to be_within(0.06).of(e) }

    starts = JSON.parse(File.read(secs))["sections"].map { |s| s["start_bar"] }
    expect(starts).to include(8, 12)
  end

  it "rejects sections without a beat map" do
    _, err, status = cli("audio:sections[#{drums_wav},#{file("s.json")}]")
    expect(status.exitstatus).not_to eq(0)
    expect(err).to match(/Need 3 arguments/)
  end
end
