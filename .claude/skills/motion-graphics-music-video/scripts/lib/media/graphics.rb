require "json"
require_relative "shell"

module Media
  # Native Swift scene renderer. Used by the Anim entry point and direct movie exports.
  class Graphics < Shell
    PACKAGE = File.expand_path("../../tools/graphics", __dir__)
    BIN = File.join(PACKAGE, ".build", "release", "mgraphics")

    def build
      run("swift", "build", "-c", "release", "--package-path", PACKAGE)
      { path: BIN }
    end

    def render(scene, out, width:, height:, fps:, frames:, data: {}, only: nil, plate: nil, audio: nil, codec: nil, benchmark: false, coverage: false)
      sources = Dir[File.join(PACKAGE, "Sources", "**", "*.swift")] + [File.join(PACKAGE, "Package.swift")]
      build if !File.file?(BIN) || sources.any? { |path| File.mtime(path) > File.mtime(BIN) }
      args = [scene, "--out", out, "--width", width, "--height", height, "--fps", fps, "--frames", frames]
      args += ["--only", only.join(",")] if only
      args += ["--plate", plate] if plate
      args += ["--audio", audio] if audio
      args += ["--codec", codec] if codec
      args << "--benchmark" if benchmark
      args << "--measure-coverage" if coverage
      data.each { |name, path| args += ["--data", "#{name}=#{path}"] }
      JSON.parse(run(BIN, *args).lines.last)
    end
  end
end
