require_relative "spec_helper"
RSpec.describe "Fal audio HTTP and model contracts", :core do
  it "caches CDN upload URLs by bytes and downloads real response bytes" do
    with_workspace do
      File.write("audio.wav", "test audio bytes")
      Excon.defaults[:mock] = true
      calls = 0
      Excon.stub({method: :post, host: "rest.alpha.fal.ai"}) do
        calls += 1
        {status:200, body: JSON.generate(upload_url:"https://upload.test/file",file_url:"https://cdn.test/file")}
      end
      Excon.stub({method: :put, host:"upload.test"},{status:200,body:""})
      Excon.stub({method: :get, host:"cdn.test"},{status:200,body:"downloaded bytes"})
      client = Fal::Client.new(api_key:"fixture")
      expect(client.upload("audio.wav")).to eq("https://cdn.test/file")
      expect(client.upload("audio.wav")).to eq("https://cdn.test/file")
      expect(calls).to eq(1)
      client.download("https://cdn.test/file","download.wav")
      expect(File.read("download.wav")).to eq("downloaded bytes")
    end
  end
  it "keeps the receipt after a polling interruption and recovers without another POST" do
    with_workspace do
      approve
      client = Fal::Client.new(api_key:"fixture")
      expect(client).to receive(:submit).once.and_return({"request_id"=>"resume-1","status_url"=>"status","response_url"=>"result"})
      allow(client).to receive(:wait).and_raise(Fal::Error,"timeout")
      expect { client.run("test/endpoint",{prompt:"once"}) }.to raise_error(Fal::Error,/timeout/)
      allow(client).to receive(:wait).and_return(true)
      allow(client).to receive(:get_json).with("result").and_return({"ok"=>true})
      expect(client.run("test/endpoint",{prompt:"once"})).to eq(["resume-1",{"ok"=>true}])
    end
  end
  it "submits, polls, fetches and resumes identical paid requests without resubmitting" do
    with_workspace do
      approve
      Excon.defaults[:mock] = true
      submitted = []
      Excon.stub({method: :post, host: "queue.fal.run"}) do |req|
        submitted << JSON.parse(req[:body])
        {status: 200, body: JSON.generate(request_id: "job-1", status_url: "https://queue.fal.run/status", response_url: "https://queue.fal.run/result")}
      end
      Excon.stub({method: :get, path: "/status"}, {status: 200, body: '{"status":"COMPLETED"}'})
      Excon.stub({method: :get, path: "/result"}, {status: 200, body: '{"audio":{"url":"https://cdn.test/audio.wav"}}'})
      client = Fal::Client.new(api_key: "test-only", poll_interval: 0)
      2.times { expect(Fal::Models::StableAudioSfx.new(client: client).generate(prompt: "fixture").request_id).to eq("job-1") }
      expect(submitted.size).to eq(1)
      expect(submitted.first).to include("prompt" => "fixture")
      expect(Dir["output/requests/*.json"].size).to eq(1)
    end
  end
  it "validates endpoint inputs against a saved schema before submission" do
    with_workspace do
      path = Fal::OpenAPI.spec_path(Fal::Models::Music3.endpoint)
      json(path, components: {schemas: {Input: {required: ["prompt"], properties: {prompt: {type: "string"}, duration: {enum: [5]}}}}})
      client = double("no network")
      expect(client).not_to receive(:run)
      expect { Fal::Models::Music3.new(client: client).compose(prompt: "x", lyrics: "hello", duration: "bad") }.to raise_error(ArgumentError)
    end
  end
  it "surfaces terminal queue errors and never calls a paid endpoint before approval" do
    with_workspace do
      client = Fal::Client.new(api_key: "test-only", poll_interval: 0)
      expect(client).not_to receive(:submit)
      expect { client.run("test/model", {}) }.to raise_error(/approval missing/)
      allow(client).to receive(:get_json).and_return({"status" => "COMPLETED", "error" => "generation rejected"})
      expect { client.wait("https://test/status") }.to raise_error(Fal::Error, /generation rejected/)
    end
  end
end
