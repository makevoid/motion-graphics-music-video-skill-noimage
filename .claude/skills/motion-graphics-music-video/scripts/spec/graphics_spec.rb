require_relative "spec_helper"

RSpec.describe Media::Graphics, :core do
  it "routes JSON scenes through Swift with cue files and sparse frames" do
    service = Media::Anim.new
    allow(service).to receive(:build)
    expect(service).to receive(:run).with(Media::Graphics::BIN, "scene.json", "--out", "frames", "--width", 320, "--height", 180, "--fps", 24, "--frames", 48, "--only", "0,24", "--data", "words=words.json").and_return('{"frames":2}')
    expect(service.render("scene.json", "frames", width: 320, height: 180, fps: 24, frames: 48, data: { words: "words.json" }, only: [0,24])["frames"]).to eq(2)
  end

  it "rejects removed JavaScript scenes without launching a process" do
    service = Media::Anim.new
    expect(service).not_to receive(:run)
    expect { service.render("scene.js", "frames", width: 320, height: 180, fps: 24, frames: 48) }.to raise_error(ArgumentError, /JavaScript rendering has been removed/)
  end

  it "passes video options as separate argv values and propagates renderer failures" do
    service = described_class.new
    allow(service).to receive(:build)
    expect(service).to receive(:run).with(described_class::BIN, "scene with spaces.json", "--out", "out.mov", "--width", 320, "--height", 180, "--fps", 29.97, "--frames", 60,
      "--plate", "plate with spaces.mp4", "--audio", "song.m4a", "--codec", "prores4444", "--data", "words=word cues.json").and_raise(Media::CommandError, "fixture")
    expect { service.render("scene with spaces.json", "out.mov", width: 320, height: 180, fps: 29.97, frames: 60, plate: "plate with spaces.mp4", audio: "song.m4a", codec: "prores4444", data: { words: "word cues.json" }) }.to raise_error(Media::CommandError, "fixture")
  end
end

RSpec.describe "Native graphics package", :swift do
  it "passes geometry, animation, alpha, GPU, and native video round-trip tests" do
    package = Media::Graphics::PACKAGE
    expect(Media::Shell.new.run("swift", "test", "--package-path", package)).to include("0 failures")
  end

  it "renders sparse JSON overlay frames through the existing Anim interface" do
    scene = File.join(Media::Graphics::PACKAGE, "examples", "overlay.json")
    result = Media::Anim.new.render(scene, file("native"), width: 320, height: 180, fps: 24, frames: 48, only: [0, 24, 47])
    expect(result["frames"]).to eq(3)
    expect(Dir[File.join(file("native"), "*.png")].map { |f| File.basename(f) }).to contain_exactly("0000.png", "0024.png", "0047.png")
    coverage = magick.alpha_coverage(file("native/0024.png"))
    expect(coverage).to be_between(0.01, 0.5)
  end
end
