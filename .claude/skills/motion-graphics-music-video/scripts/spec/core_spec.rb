require_relative "spec_helper"
RSpec.describe "Skill contracts and Ruby entry", :core do
  it "loads valid metadata and resolves every bundled Markdown reference" do
    skill = File.read(File.join(SKILL, "SKILL.md"))
    front = YAML.safe_load(skill.split("---", 3)[1])
    expect(front.fetch("name")).to eq("motion-graphics-music-video")
    expect(front.fetch("description").length).to be > 30
    Dir[File.join(SKILL, "**", "*.md")].reject { |p| p.include?("node_modules") || p.include?("/tmp/") }.each do |path|
      File.read(path).scan(/\[[^\]]*\]\(([^)]+)\)/).flatten.each do |target|
        next if target.start_with?("https:", "http:", "#")
        expect(File.exist?(File.expand_path(target.split("#").first, File.dirname(path)))).to be(true), "Broken reference #{target} in #{path}"
      end
    end
  end
  it "shows help and lists local executable tasks" do
    out, err, status = cli("--help")
    expect(status.exitstatus).to eq(0), err
    expect(out).to include("--project", "Exit:")
    out, err, status = cli("-T")
    expect(status.exitstatus).to eq(0), err
    expect(out).to include("graphics:preview", "graphics:render", "media:mouth", "vfx:render", "test")
  end
  it "rejects incomplete intake without prompting or overwriting an existing project" do
    _, _, status = cli("init")
    expect(status.exitstatus).to eq(2)
    File.write(file("song.wav"), "fixture"); File.write(file("brief.md"), "Dancing robot")
    dir = file("project")
    out, err, status = cli("init", "--project", dir, "--song", file("song.wav"), "--prompt-file", file("brief.md"))
    expect(status.exitstatus).to eq(0), err
    expect(JSON.parse(out)["project"]).to eq(dir)
    expect(File.read(File.join(dir, "docs/BRIEF.md"))).to eq("Dancing robot")
    out, err, status = cli("--project", dir, "-T")
    expect(status.exitstatus).to eq(0), err
    expect(out).to include("graphics:preview", "audio:map", "sfx:gen")
    _, err, status = cli("--project", dir, "gen:ref_base")
    expect(status.success?).to be(false)
    expect(err).to include("Don't know how to build task")
    _, _, status = cli("init", "--project", dir, "--song", file("song.wav"), "--prompt-file", file("brief.md"))
    expect(status.exitstatus).to eq(2)
  end
  it "executes shell arguments literally, including spaces and shell metacharacters" do
    dangerous = "a path; $(touch SHOULD_NOT_EXIST) `x`"
    out = Media::Shell.new.run(RbConfig.ruby, "-e", "print ARGV.fetch(0)", dangerous, quiet: true)
    expect(out).to eq(dangerous)
    expect(File.exist?("SHOULD_NOT_EXIST")).to be(false)
  end
  it "surfaces a backend failure" do
    expect { Media::Shell.new.run(RbConfig.ruby, "-e", "STDERR.puts 'fixture failure'; exit 9", quiet: true) }.to raise_error(Media::CommandError, /fixture failure/)
  end
  it "invalidates approval when the creative plan changes" do
    with_workspace do
      expect { Workflow::Approval.new.check! }.to raise_error(/approval missing/)
      approve
      expect(Workflow::Approval.new.check!).to be(true)
      File.write("docs/PLAN.md", "Different cast and story")
      expect { Workflow::Approval.new.check! }.to raise_error(/Plan changed/)
    end
  end
  it "reads and records UTF-8 approval files independently of the locale" do
    with_workspace do
      approve
      File.write("docs/PLAN.md", "Bloom — 音楽", encoding: "UTF-8")
      note = "Approve wave 2 — café / 音楽"
      Workflow::Approval.new.record!(note)
      script = <<~RUBY
        # encoding: UTF-8
        require #{File.join(RT, "lib/workflow/approval").inspect}
        abort "Expected US-ASCII" unless Encoding.default_external == Encoding::US_ASCII
        approval = Workflow::Approval.new
        approval.check!
        approval.record!(#{note.inspect})
        approval.check!
      RUBY
      _, err, status = Open3.capture3({"LC_ALL" => "C", "LANG" => "C"}, RbConfig.ruby, "-EUS-ASCII", "-e", script)
      expect(status.success?).to be(true), err
      expect(JSON.parse(File.read("config/approval.json", encoding: "UTF-8"))["user_approval"]).to eq(note)
    end
  end
  it "allocates reviewed dependency waves 2,4,8,10,10 and resumes an active wave" do
    with_workspace do
      FileUtils.mkdir_p("config")
      jobs = 34.times.map { |i| {id: "j#{i}", run: "r#{i}", state: "pending", depends: []} }
      json("config/production.json", wave: 0, jobs: jobs)
      waves = Workflow::Waves.new
      File.write("review.md", "Reviewed fixture output")
      [2, 4, 8, 10, 10].each do |count|
        result = waves.next!
        expect(result[:jobs].size).to eq(count)
        expect(waves.next![:jobs]).to eq(result[:jobs])
        result[:jobs].each { |j| waves.accept!(j["id"], "review.md") }
      end
      expect(waves.next![:complete]).to be(true)
    end
  end
  it "waits for dependencies, prevents shared run ownership and detects cycles" do
    with_workspace do
      FileUtils.mkdir_p("config")
      json("config/production.json", jobs: [{id: "a", run: "shared"}, {id: "b", run: "shared"}, {id: "c", depends: ["a"]}])
      result = Workflow::Waves.new.next!
      expect(result[:jobs].map { |j| j["id"] }).to eq(["a"])
      json("config/production.json", jobs: [{id: "a", depends: ["b"]}, {id: "b", depends: ["a"]}])
      expect { Workflow::Waves.new.next! }.to raise_error(/No jobs ready/)
    end
  end
  it "refuses noncontiguous section assembly before touching media" do
    stub_const("Pipeline::GENERATIONS", {
      "test-a" => {steps: [], **Pipeline.section(0, 24)},
      "test-b" => {steps: [], **Pipeline.section(25, 24)}
    })
    expect { Toolkit::Operations.new.preview(file("out.mp4"), %w[test-a test-b]) }.to raise_error(/Noncontiguous/)
  end
end

RSpec.describe "Native default and removed visual generation", :core do
  it "rejects removed image and video generation commands" do
    %w[gen:ref_base gen:ref_torn gen:keyframes gen:video gen:shots gen:clips ref:import].each do |task|
      _, err, status = cli(task)
      expect(status.success?).to be(false), "#{task} unexpectedly ran"
      expect(err).to include("Don't know how to build task")
    end
  end

  it "checks local prerequisites without requiring a generation credential" do
    service = Toolkit::Operations.new
    allow(Media::Shell).to receive(:available?).and_return(true)
    allow(service).to receive(:system).and_return(true)
    ENV["STRICT"] = "1"
    expect { service.doctor }.to output(/"python_packages": true/).to_stdout
  end
end
