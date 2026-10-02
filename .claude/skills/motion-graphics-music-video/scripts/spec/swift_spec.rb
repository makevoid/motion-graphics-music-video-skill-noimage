require_relative "spec_helper"
RSpec.describe "Swift VFX end to end", :swift do
  it "applies a cued effect to a character scene, preserves outside frames and audio" do
    raise "Swift VFX requires macOS 14+ (use PROFILE=media/core elsewhere)" unless RUBY_PLATFORM.include?("darwin")
    source = video
      sprite = character
      meta = py.cutout(sprite, file("sprites"), "green")
      meta["dir"] = file("sprites").delete_prefix("#{RT}/")
      json(file("clips.json"), hero: meta)
      native_scene(file("scene.json"), clip: "hero", background: "#244060", height: 180)
      Media::Anim.new.render(file("scene.json"),file("frames"),width:320,height:180,fps:24,frames:48,data:{clips:file("clips.json")})
      source = ff.overlay_frames(source,file("frames"),file("composed.mp4"),fps:24)
    name = "e2e-vfx-#{Process.pid}"
    dir = File.join(RT, "prompts", name); FileUtils.mkdir_p(dir)
    config = {"source" => source, "out" => file("effect.mp4"), "cues" => [{"fx" => "dark", "f" => 12, "dur" => 6, "hold" => 3, "amt" => 0.9}, {"fx" => "flare", "f" => 36, "dur" => 3, "amt" => 1, "x" => 0.5, "y" => 0.5}]}
    File.write(File.join(dir, "cues.yml"), YAML.dump(config))
    service = Media::Vfx.new(name)
    service.render
    info = ff.summary(file("effect.mp4"))
    expect(info.dig(:video, :frames)).to eq(48)
    expect(info.dig(:audio, :codec)).to eq("aac")
    [0,12,30,36].each do |frame|
      ff.frame_index(source, frame, file("before#{frame}.png"))
      ff.frame_index(file("effect.mp4"), frame, file("after#{frame}.png"))
    end
    expect(mean_luma(file("after12.png"))).to be < mean_luma(file("before12.png")) * 0.3
    [0,30].each { |frame| expect(mean_luma(file("after#{frame}.png"))).to be_within(0.02).of(mean_luma(file("before#{frame}.png"))) }
    before_light = magick.run("magick", file("before36.png"), "-crop", "60x40+130+70", "-colorspace", "gray", "-format", "%[fx:mean]", "info:", quiet: true).to_f
      after_light = magick.run("magick", file("after36.png"), "-crop", "60x40+130+70", "-colorspace", "gray", "-format", "%[fx:mean]", "info:", quiet: true).to_f
      expect(after_light).to be > before_light + 0.05
      expect(File.directory?(service.path("lights"))).to be(false)
      clip = service.clip(24,48)
      clip_info = ff.summary(clip)
      expect(clip_info.dig(:video,:frames)).to eq(24)
      expect(clip_info.dig(:audio,:codec)).to eq("aac")
      expect(clip_info[:duration]).to be_within(0.01).of(1)
      expect(File.file?(service.stills([0,12,36]))).to be(true)
      expect(Dir[service.path("stills/*.png")].size).to eq(3)
      config["cues"] = [{"fx" => "unknown", "f" => 1, "dur" => 1}]
    File.write(File.join(dir, "cues.yml"), YAML.dump(config))
    expect { Media::Vfx.new(name).render }.to raise_error(ArgumentError, /unknown fx/)
  end
  it "stretches a hit along its angle and leaves echo trails behind moving shapes" do
    source = file("moving.mp4")
    ff.run("ffmpeg", "-y", "-v", "error", "-f", "lavfi", "-i", "color=black:s=320x180:r=24:d=2", "-f", "lavfi", "-i", "color=white:s=30x30:r=24:d=2",
           "-f", "lavfi", "-i", "sine=frequency=440:duration=2", "-filter_complex", "[0][1]overlay=x='20+t*100':y=75[v]", "-map", "[v]", "-map", "2",
           "-c:v", "libx264", "-pix_fmt", "yuv420p", "-c:a", "aac", "-shortest", source)
    name = "e2e-vfx-motion-#{Process.pid}"
    dir = File.join(RT, "prompts", name); FileUtils.mkdir_p(dir)
    File.write(File.join(dir, "cues.yml"), YAML.dump({ "source" => source, "out" => file("motion.mp4"),
      "cues" => [{ "fx" => "stretch", "f" => 6, "dur" => 6, "amt" => 0.4, "x" => 0.5, "y" => 0.5 }, { "fx" => "echo", "f" => 24, "dur" => 12, "amt" => 0.9, "n" => 4, "hold" => 2, "fade" => 1 }] }))
    service = Media::Vfx.new(name)
    service.render
    box = ->(png) { magick.run("magick", png, "-colorspace", "gray", "-threshold", "40%", "-trim", "-format", "%w %h", "info:", quiet: true).split.map(&:to_i) }
    [6, 30].each do |frame|
      ff.frame_index(source, frame, file("m_before#{frame}.png"))
      ff.frame_index(file("motion.mp4"), frame, file("m_after#{frame}.png"))
    end
    w0, h0 = box.(file("m_before6.png")); w1, h1 = box.(file("m_after6.png"))
    expect([w0, h0]).to eq([30, 30])
    expect(w1).to be >= (w0 * 1.3).floor # stretched along 0 deg ...
    expect(h1).to be < h0                # ... and squashed across it
    trail, plain = box.(file("m_after30.png")).first, box.(file("m_before30.png")).first
    expect(trail).to be >= plain + 14    # the brighter ghosts (2 and 4 frames back, 4.2 px/frame) extend it leftward
    expect(File.file?(service.stills([30]))).to be(true) # a lone still decodes its own ghost frames
  end

  it "renders VFX on a 60 fps video with 24 fps cues: sideways RGB split, VHS bands, every output frame kept" do
    source = file("hfr.mp4")
    ff.run("ffmpeg", "-y", "-v", "error", "-f", "lavfi", "-i", "color=black:s=320x180:r=60:d=2,drawbox=x=140:y=0:w=40:h=180:color=white:t=fill",
           "-f", "lavfi", "-i", "sine=frequency=440:duration=2", "-c:v", "libx264", "-pix_fmt", "yuv420p", "-c:a", "aac", "-shortest", source)
    name = "e2e-vfx-hfr-#{Process.pid}"
    dir = File.join(RT, "prompts", name); FileUtils.mkdir_p(dir)
    File.write(File.join(dir, "cues.yml"), YAML.dump({ "source" => source, "out" => file("hfr_fx.mp4"), "bitrate" => 3_000_000,
      "cues" => [{ "fx" => "rgb", "f" => 0, "dur" => 12, "amt" => 0, "radius" => 8 },                        # cue frames 0-12 = 0.0-0.5 s
                 { "fx" => "bands", "f" => 24, "dur" => 12, "amt" => 1, "n" => 4, "size" => 0.2, "fade" => 1 }] })) # 1.0-1.5 s
    Media::Vfx.new(name).render
    probe = ff.run("ffprobe", "-v", "error", "-select_streams", "v", "-count_frames", "-show_entries", "stream=nb_read_frames,r_frame_rate",
                   "-of", "csv=p=0", file("hfr_fx.mp4"), quiet: true)
    expect(probe.strip.split(",")).to eq(["60/1", "120"])
    rgb = ->(png, x) { magick.run("magick", png, "-format", "%[fx:int(255*p{#{x},90}.r)] %[fx:int(255*p{#{x},90}.b)]", "info:", quiet: true).split.map(&:to_i) }
    ff.frame_index(file("hfr_fx.mp4"), 3, file("split.png"))
    fringes = [134, 186].map { |x| r, b = rgb.(file("split.png"), x); (r - b).abs }
    expect(fringes.max).to be > 80                 # one colour channel slid past the bar's edge, the other didn't
    diff = ->(frame) {
      ff.frame_index(source, frame, file("b#{frame}.png")); ff.frame_index(file("hfr_fx.mp4"), frame, file("a#{frame}.png"))
      magick.run("magick", file("b#{frame}.png"), file("a#{frame}.png"), "-compose", "difference", "-composite", "-format", "%[fx:mean]", "info:", quiet: true).to_f
    }
    expect(diff.(72)).to be > 0.01                 # 1.2 s: tracking bands roll through
    expect(diff.(110)).to be < 0.004               # 1.83 s: no cue, picture untouched
  end
end
