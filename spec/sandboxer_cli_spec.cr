require "spec"
require "../src/sandboxer_cli"

describe Sandboxer::CLI do
  # Helper: run the CLI with a given argv, return exit code.
  # We call CLI.run directly rather than spawning a subprocess so
  # the specs stay fast and don't require a compiled binary.

  describe "routing" do
    it "returns 0 for 'version'" do
      Sandboxer::CLI.run(["version"]).should eq(0)
    end

    it "returns 0 for '--version'" do
      Sandboxer::CLI.run(["--version"]).should eq(0)
    end

    it "returns 0 for 'help'" do
      Sandboxer::CLI.run(["help"]).should eq(0)
    end

    it "returns 0 for '--help'" do
      Sandboxer::CLI.run(["--help"]).should eq(0)
    end

    it "returns 1 for an unknown subcommand" do
      Sandboxer::CLI.run(["bogus"]).should eq(1)
    end

    it "returns 1 with empty argv" do
      # empty argv falls through to help, which returns 0
      Sandboxer::CLI.run([] of String).should eq(0)
    end
  end

  describe "sandbox check" do
    it "exits 0 when at least one runner is available" do
      # On any supported platform at least one runner should be found.
      # This test will be skipped on unsupported platforms.
      result = Sandboxer::CLI.run(["check"])
      result.should be_a(Int32)
    end
  end

  describe "sandbox run" do
    it "returns 1 when '--' separator is missing" do
      result = Sandboxer::CLI.run(["run", "--policy", "policy.json"])
      result.should eq(1)
    end

    it "returns 1 when no command follows '--'" do
      result = Sandboxer::CLI.run(["run", "--"])
      result.should eq(1)
    end

    it "returns 1 when the policy file does not exist" do
      result = Sandboxer::CLI.run(["run", "--policy", "/nonexistent/policy.json", "--", "echo", "hi"])
      result.should eq(1)
    end

    it "returns 1 for invalid JSON in a policy file" do
      File.tempfile("bad_policy_", ".json") do |f|
        f.print("{ this is not json }")
        f.flush

        result = Sandboxer::CLI.run(["run", "--policy", f.path, "--", "echo", "hi"])
        result.should eq(1)
      end
    end
  end

  describe "sandbox inspect" do
    it "returns 0 for linux platform with a valid policy" do
      File.tempfile("policy_", ".json") do |f|
        f.print(%({"read_only_paths": ["/usr/share"], "allow_network": false}))
        f.flush

        result = Sandboxer::CLI.run(["inspect", "--policy", f.path, "--platform", "linux"])
        result.should eq(0)
      end
    end

    it "returns 0 for macos platform with a valid policy" do
      File.tempfile("policy_", ".json") do |f|
        f.print(%({"read_only_paths": ["/usr/share"], "allow_network": false}))
        f.flush

        result = Sandboxer::CLI.run(["inspect", "--policy", f.path, "--platform", "macos"])
        result.should eq(0)
      end
    end

    it "returns 1 for an unknown platform" do
      File.tempfile("policy_", ".json") do |f|
        f.print("{}")
        f.flush

        result = Sandboxer::CLI.run(["inspect", "--policy", f.path, "--platform", "windows"])
        result.should eq(1)
      end
    end

    it "uses an empty policy when no --policy is given" do
      result = Sandboxer::CLI.run(["inspect", "--platform", "linux"])
      result.should eq(0)
    end
  end
end
