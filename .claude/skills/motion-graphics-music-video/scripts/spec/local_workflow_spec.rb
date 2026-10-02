require_relative "spec_helper"

RSpec.describe "Local soundtrack and prepared overlay", :media do
  it "renders a first overlay from existing global word timings without any Fal client" do
    song = tone(duration: 3)
    run = "e2e-local-#{Process.pid}-#{object_id}"
    project = Pipeline::Project.new(run)
    stub_const("Pipeline::GENERATIONS", { run => { steps: [Pipeline::Steps::Music, Pipeline::Steps::Overlay],
                                                  **Pipeline.section(24, 4), music_from: song, upload_music: false, plate: character, track: {pin: [100,200,16,16,1]} } })
    expect(Fal::Client).not_to receive(:new)
    Pipeline::Steps::Music.new(project: project).run!
    expect(project[:music]["url"]).to be_nil
    expect(ff.duration(project[:music]["path"])).to be_within(0.002).of(4 / 24.0)
    dir = File.join(RT, "prompts", run)
    FileUtils.mkdir_p(dir)
    json(File.join(dir, "05_overlay.json"), background: "#202060", nodes: [{type: "rect", x: 20, y: 20, width: 120, height: 120}])
    json(file("words.json"), chunks: [{text: "before", timestamp: [0.0,0.5]}, {text: "here", timestamp: [1.05,1.12]}, {text: "after", timestamp: [2,2.5]}])
    overlay = Pipeline::Steps::Overlay.new(project: project)
    expect(overlay.prepare!(file("words.json"))[:count]).to eq(1)
    words = JSON.parse(File.read(project.path("05_overlay", "words.json")))
    expect(words.first["s"]).to be_within(1e-6).of(0.05)
    tracking = JSON.parse(File.read(project.path("05_overlay", "pin.json")))
    expect(tracking["points"]).to eq([[100,200,0.0], [100,200,1.0], [100,200,1.0], [100,200,1.0]])
    result = overlay.render!
    expect(project[:overlay]["rendered_frames"]).to eq(4)
    expect(project[:overlay]["coverage_pct_by_frame"]).not_to be_empty
    expect(File.directory?(project.path("05_overlay", "frames"))).to be(false)
    expect(File.exist?(project.path("04_plate_still.mp4"))).to be(false)
    expect(ff.summary(result[:path]).dig(:audio, :codec)).to eq("aac")
    expect(ff.summary(result[:path]).dig(:video,:frames)).to eq(4)
    sheet = file("new-review-directory/contact.jpg")
    ff.contact_sheet(result[:path], sheet, cols: 2, rows: 1, width: 160)
    expect(ff.summary(sheet).dig(:video, :w)).to be > 300
  end
end
