require "spec"
require "../src/sandboxer"

describe Sandboxer do
  describe Sandboxer::Policy do
    it "builds with defaults" do
      policy = Sandboxer::Policy.new
      policy.allow_network?.should be_false
      policy.new_session?.should be_true
      policy.read_only_paths.should be_empty
    end

    it "accepts paths via vararg helpers" do
      policy = Sandboxer::Policy.build do |p|
        p.read_only "/usr/lib", "/usr/share"
        p.read_write "/tmp/work"
        p.tmpfs "/tmp"
        p.allow_network = true
        p.working_dir = "/tmp/work"
        p.env["MY_VAR"] = "hello"
      end

      policy.read_only_paths.should eq(["/usr/lib", "/usr/share"])
      policy.read_write_paths.should eq(["/tmp/work"])
      policy.tmpfs_paths.should eq(["/tmp"])
      policy.allow_network?.should be_true
      policy.working_dir.should eq("/tmp/work")
      policy.env["MY_VAR"].should eq("hello")
    end

    it "supports method chaining" do
      policy = Sandboxer::Policy.new
        .read_only("/usr/lib")
        .read_write("/tmp")
        .tmpfs("/var/tmp")

      policy.read_only_paths.should eq(["/usr/lib"])
      policy.read_write_paths.should eq(["/tmp"])
      policy.tmpfs_paths.should eq(["/var/tmp"])
    end
  end

  describe "JSON round-trip" do
    it "serialises to JSON and back" do
      policy = Sandboxer::Policy.build do |p|
        p.read_only "/usr/share/myapp"
        p.read_write "/tmp/workspace"
        p.tmpfs "/tmp"
        p.allow_network = true
        p.working_dir = "/tmp/workspace"
        p.env["MY_VAR"] = "hello"
        p.unset_env << "SECRET"
        p.new_session = false
      end

      restored = Sandboxer::Policy.from_json(policy.to_json)

      restored.read_only_paths.should eq(policy.read_only_paths)
      restored.read_write_paths.should eq(policy.read_write_paths)
      restored.tmpfs_paths.should eq(policy.tmpfs_paths)
      restored.allow_network?.should eq(policy.allow_network?)
      restored.working_dir.should eq(policy.working_dir)
      restored.env.should eq(policy.env)
      restored.unset_env.should eq(policy.unset_env)
      restored.new_session?.should eq(policy.new_session?)
    end

    it "deserialises a minimal JSON object using field defaults" do
      policy = Sandboxer::Policy.from_json("{}")
      policy.allow_network?.should be_false
      policy.new_session?.should be_true
      policy.read_only_paths.should be_empty
      policy.env.should be_empty
    end

    it "deserialises a realistic policy file" do
      json = <<-JSON
        {
          "read_only_paths": ["/usr/share/myapp", "/etc/myapp"],
          "read_write_paths": ["/tmp/workspace"],
          "allow_network": false,
          "working_dir": "/tmp/workspace",
          "env": { "APP_ENV": "sandbox" }
        }
        JSON

      policy = Sandboxer::Policy.from_json(json)
      policy.read_only_paths.should eq(["/usr/share/myapp", "/etc/myapp"])
      policy.read_write_paths.should eq(["/tmp/workspace"])
      policy.allow_network?.should be_false
      policy.working_dir.should eq("/tmp/workspace")
      policy.env["APP_ENV"].should eq("sandbox")
      policy.tmpfs_paths.should be_empty # defaulted
      policy.new_session?.should be_true # defaulted
    end
  end

  describe Sandboxer::Bwrap do
    runner = Sandboxer::Bwrap.new
    base_policy = Sandboxer::Policy.build do |p|
      p.read_only "/usr/share/myapp"
      p.read_write "/tmp/workspace"
      p.working_dir = "/tmp/workspace"
    end

    it "starts argv with bwrap binary" do
      argv = runner.build_argv(["echo", "hi"], base_policy)
      argv.first.should eq("bwrap")
    end

    it "clears environment by default" do
      argv = runner.build_argv(["echo", "hi"], base_policy)
      argv.should contain("--clearenv")
    end

    it "mounts proc and dev" do
      argv = runner.build_argv(["echo", "hi"], base_policy)
      argv.should contain("--proc")
      argv.should contain("--dev")
    end

    it "binds read-only paths with --ro-bind" do
      argv = runner.build_argv(["echo", "hi"], base_policy)
      i = argv.index("--ro-bind")
      i.should_not be_nil
      argv[i.not_nil! + 1].should eq("/usr/share/myapp")
    end

    it "binds read-write paths with --bind" do
      argv = runner.build_argv(["echo", "hi"], base_policy)
      i = argv.index("--bind")
      i.should_not be_nil
      argv[i.not_nil! + 1].should eq("/tmp/workspace")
    end

    it "unshares network when allow_network is false" do
      argv = runner.build_argv(["echo", "hi"], base_policy)
      argv.should contain("--unshare-net")
    end

    it "does not unshare network when allow_network is true" do
      policy = Sandboxer::Policy.build { |p| p.allow_network = true }
      argv = runner.build_argv(["echo", "hi"], policy)
      argv.should_not contain("--unshare-net")
      argv.should contain("/etc/resolv.conf")
    end

    it "always unshares PID namespace" do
      argv = runner.build_argv(["echo", "hi"], base_policy)
      argv.should contain("--unshare-pid")
    end

    it "passes working dir with --chdir" do
      argv = runner.build_argv(["echo", "hi"], base_policy)
      i = argv.index("--chdir")
      i.should_not be_nil
      argv[i.not_nil! + 1].should eq("/tmp/workspace")
    end

    it "passes tmpfs mounts with --tmpfs" do
      policy = Sandboxer::Policy.build { |p| p.tmpfs "/tmp" }
      argv = runner.build_argv(["echo", "hi"], policy)
      i = argv.index("--tmpfs")
      i.should_not be_nil
      argv[i.not_nil! + 1].should eq("/tmp")
    end

    it "injects policy env vars after clearenv" do
      policy = Sandboxer::Policy.build { |p| p.env["FOO"] = "bar" }
      argv = runner.build_argv(["echo", "hi"], policy)
      i = argv.rindex("--setenv") # last --setenv (policy vars come after defaults)
      i.should_not be_nil
      argv[i.not_nil! + 1].should eq("FOO")
      argv[i.not_nil! + 2].should eq("bar")
    end

    it "ends argv with -- followed by the command" do
      argv = runner.build_argv(["echo", "hello world"], base_policy)
      sep = argv.rindex("--")
      sep.should_not be_nil
      argv[(sep.not_nil! + 1)..].should eq(["echo", "hello world"])
    end
  end

  describe Sandboxer::SandboxExec do
    runner = Sandboxer::SandboxExec.new
    base_policy = Sandboxer::Policy.build do |p|
      p.read_only "/usr/local/share/myapp"
      p.read_write "/tmp/workspace"
      p.working_dir = "/tmp/workspace"
    end

    it "opens with version and deny-default" do
      profile = runner.generate_profile(base_policy)
      profile.should contain("(version 1)")
      profile.should contain("(deny default)")
    end

    it "includes baseline process and mach permissions" do
      profile = runner.generate_profile(base_policy)
      profile.should contain("(allow process-fork)")
      profile.should contain("(allow mach-lookup)")
      profile.should contain("(allow sysctl-read)")
    end

    it "emits file-read* for read-only paths" do
      profile = runner.generate_profile(base_policy)
      profile.should contain("(allow file-read*")
      profile.should contain("/usr/local/share/myapp")
    end

    it "emits file-read* file-write* for read-write paths" do
      profile = runner.generate_profile(base_policy)
      profile.should contain("(allow file-read* file-write*")
      profile.should contain("/tmp/workspace")
    end

    it "does not emit network rules when allow_network is false" do
      profile = runner.generate_profile(base_policy)
      profile.should_not contain("network-outbound")
    end

    it "emits network rules when allow_network is true" do
      policy = Sandboxer::Policy.build { |p| p.allow_network = true }
      profile = runner.generate_profile(policy)
      profile.should contain("(allow network-outbound)")
      profile.should contain("(allow network-inbound)")
    end

    it "grants working_dir access when not covered by path lists" do
      policy = Sandboxer::Policy.build { |p| p.working_dir = "/opt/myapp/run" }
      profile = runner.generate_profile(policy)
      profile.should contain("/opt/myapp/run")
    end

    it "does not duplicate working_dir grant when already in read_write_paths" do
      policy = Sandboxer::Policy.build do |p|
        p.read_write "/tmp/workspace"
        p.working_dir = "/tmp/workspace"
      end
      profile = runner.generate_profile(policy)
      profile.scan("/tmp/workspace").size.should eq(1)
    end
  end
end
