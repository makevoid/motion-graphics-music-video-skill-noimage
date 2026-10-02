require "rbconfig"
module Toolkit
  class TestRunner
    def run
      profile = ENV.fetch("PROFILE", "all")
      raise "PROFILE must be all, core, media or swift" unless %w[all core media swift].include?(profile)
      args = [RbConfig.ruby, "-S", "rspec", "spec", "--format", "documentation"]
      args += ["--tag", profile] unless profile == "all"
      ok = system(*args)
      raise "RSpec failed for PROFILE=#{profile}; see failures above" unless ok
    end
  end
end
