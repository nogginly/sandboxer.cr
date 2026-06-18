require "spec"
require "../src/sandboxer"

# ── Policy ────────────────────────────────────────────────────────────────────

describe Sandboxer::Policy do
  describe ".new" do
    it "defaults to empty path lists" do
      policy = Sandboxer::Policy.new
      policy.read_only_paths.should be_empty
      policy.read_write_paths.should be_empty
      policy.tmpfs_paths.should be_empty
      policy.unset_env.should be_empty
      policy.env.should be_empty
    end

    it "defaults allow_network to false" do
      Sandboxer::Policy.new.allow_network?.should be_false
    end

    it "defaults new_session to true" do
      Sandboxer::Policy.new.new_session?.should be_true
    end

    it "defaults working_dir to nil" do
      Sandboxer::Policy.new.working_dir.should be_nil
    end
  end

  describe ".build" do
    it "yields a policy and returns it configured" do
      policy = Sandboxer::Policy.build do |p|
        p.read_only "/usr/share"
        p.read_write "/tmp/work"
        p.tmpfs "/tmp/scratch"
        p.allow_network = true
        p.working_dir = "/tmp/work"
        p.env["FOO"] = "bar"
      end
      policy.read_only_paths.should eq(["/usr/share"])
      policy.read_write_paths.should eq(["/tmp/work"])
      policy.tmpfs_paths.should eq(["/tmp/scratch"])
      policy.allow_network?.should be_true
      policy.working_dir.should eq("/tmp/work")
      policy.env["FOO"].should eq("bar")
    end
  end

  describe "#read_only / #read_write / #tmpfs" do
    it "accepts multiple paths in one call" do
      policy = Sandboxer::Policy.build do |p|
        p.read_only "/a", "/b"
        p.read_write "/c", "/d"
        p.tmpfs "/e", "/f"
      end
      policy.read_only_paths.should eq(["/a", "/b"])
      policy.read_write_paths.should eq(["/c", "/d"])
      policy.tmpfs_paths.should eq(["/e", "/f"])
    end
  end

  describe ".from_json / #to_json" do
    it "round-trips a policy through JSON" do
      json = %({"read_only_paths":["/usr/share"],"read_write_paths":["/tmp"],"tmpfs_paths":[],"allow_network":false,"working_dir":null,"env":{},"unset_env":[],"new_session":true})
      policy = Sandboxer::Policy.from_json(json)
      policy.read_only_paths.should eq(["/usr/share"])
      policy.read_write_paths.should eq(["/tmp"])
      policy.allow_network?.should be_false
    end

    it "deserialises allow_network from JSON" do
      policy = Sandboxer::Policy.from_json(%({"allow_network":true}))
      policy.allow_network?.should be_true
    end
  end

  describe "#merge" do
    it "unions path arrays without duplicates" do
      a = Sandboxer::Policy.build { |p| p.read_only "/usr/share", "/etc/myapp" }
      b = Sandboxer::Policy.build { |p| p.read_only "/etc/myapp", "/opt/data" }
      a.merge(b).read_only_paths.should eq(["/usr/share", "/etc/myapp", "/opt/data"])
    end

    it "unions all path list types" do
      a = Sandboxer::Policy.build { |p| p.read_write "/tmp/a"; p.tmpfs "/run/a" }
      b = Sandboxer::Policy.build { |p| p.read_write "/tmp/b"; p.tmpfs "/run/b" }
      merged = a.merge(b)
      merged.read_write_paths.should eq(["/tmp/a", "/tmp/b"])
      merged.tmpfs_paths.should eq(["/run/a", "/run/b"])
    end

    it "allow_network is true if either is true" do
      a = Sandboxer::Policy.build { |p| p.allow_network = false }
      b = Sandboxer::Policy.build { |p| p.allow_network = true }
      a.merge(b).allow_network?.should be_true
      b.merge(a).allow_network?.should be_true
      a.merge(a).allow_network?.should be_false
    end

    it "new_session is true if either is true" do
      a = Sandboxer::Policy.new # default true
      b = Sandboxer::Policy.build { |p| p.new_session = false }
      a.merge(b).new_session?.should be_true
      b.merge(a).new_session?.should be_true
      b.merge(b).new_session?.should be_false
    end

    it "other working_dir wins when set; falls back to self" do
      a = Sandboxer::Policy.build { |p| p.working_dir = "/tmp/a" }
      b = Sandboxer::Policy.build { |p| p.working_dir = "/tmp/b" }
      c = Sandboxer::Policy.new
      a.merge(b).working_dir.should eq("/tmp/b")
      a.merge(c).working_dir.should eq("/tmp/a")
      c.merge(c).working_dir.should be_nil
    end

    it "merges env hashes with other winning on collision" do
      a = Sandboxer::Policy.build { |p| p.env["FOO"] = "a"; p.env["BAR"] = "shared" }
      b = Sandboxer::Policy.build { |p| p.env["BAR"] = "b"; p.env["BAZ"] = "b" }
      merged = a.merge(b)
      merged.env["FOO"].should eq("a")
      merged.env["BAR"].should eq("b")
      merged.env["BAZ"].should eq("b")
    end

    it "unions unset_env without duplicates" do
      a = Sandboxer::Policy.build { |p| p.unset_env.concat(["SECRET", "TOKEN"]) }
      b = Sandboxer::Policy.build { |p| p.unset_env.concat(["TOKEN", "DEBUG"]) }
      a.merge(b).unset_env.should eq(["SECRET", "TOKEN", "DEBUG"])
    end

    it "returns a new Policy leaving originals unchanged" do
      a = Sandboxer::Policy.build { |p| p.read_only "/usr/share" }
      b = Sandboxer::Policy.build { |p| p.read_only "/opt/data" }
      a.merge(b)
      a.read_only_paths.should eq(["/usr/share"])
      b.read_only_paths.should eq(["/opt/data"])
    end
  end
end

# ── Bwrap ─────────────────────────────────────────────────────────────────────

describe Sandboxer::Bwrap do
  runner = Sandboxer::Bwrap.new
  base_policy = Sandboxer::Policy.new

  describe "#build_argv" do
    it "starts with the bwrap binary" do
      runner.build_argv(["echo", "hi"], base_policy).first.should eq("bwrap")
    end

    it "clears environment and passes through defaults" do
      argv = runner.build_argv(["echo"], base_policy)
      argv.should contain("--clearenv")
    end

    it "mounts proc and dev" do
      argv = runner.build_argv(["echo"], base_policy)
      argv.should contain("--proc")
      argv.should contain("--dev")
    end

    it "always unshares PID namespace" do
      runner.build_argv(["echo"], base_policy).should contain("--unshare-pid")
    end

    it "denies network by default" do
      runner.build_argv(["echo"], base_policy).should contain("--unshare-net")
    end

    it "allows network when policy says so" do
      policy = Sandboxer::Policy.build { |p| p.allow_network = true }
      argv = runner.build_argv(["echo"], policy)
      argv.should_not contain("--unshare-net")
      argv.should contain("--ro-bind-try")
    end

    it "binds read-only paths with --ro-bind" do
      policy = Sandboxer::Policy.build { |p| p.read_only "/usr/share" }
      argv = runner.build_argv(["echo"], policy)
      i = argv.index("--ro-bind")
      i.should_not be_nil
      argv[(i.not_nil! + 1)..(i.not_nil! + 2)].should eq(["/usr/share", "/usr/share"])
    end

    it "binds read-write paths with --bind" do
      policy = Sandboxer::Policy.build { |p| p.read_write "/tmp/work" }
      argv = runner.build_argv(["echo"], policy)
      i = argv.index("--bind")
      i.should_not be_nil
      argv[(i.not_nil! + 1)..(i.not_nil! + 2)].should eq(["/tmp/work", "/tmp/work"])
    end

    it "mounts tmpfs paths with --tmpfs" do
      policy = Sandboxer::Policy.build { |p| p.tmpfs "/tmp/scratch" }
      argv = runner.build_argv(["echo"], policy)
      i = argv.index("--tmpfs")
      i.should_not be_nil
      argv[i.not_nil! + 1].should eq("/tmp/scratch")
    end

    it "sets working directory with --chdir" do
      policy = Sandboxer::Policy.build { |p| p.working_dir = "/tmp/work" }
      argv = runner.build_argv(["echo"], policy)
      i = argv.index("--chdir")
      i.should_not be_nil
      argv[i.not_nil! + 1].should eq("/tmp/work")
    end

    it "adds --new-session when new_session is true" do
      runner.build_argv(["echo"], base_policy).should contain("--new-session")
    end

    it "omits --new-session when new_session is false" do
      policy = Sandboxer::Policy.build { |p| p.new_session = false }
      runner.build_argv(["echo"], policy).should_not contain("--new-session")
    end

    it "appends -- and the command at the end" do
      argv = runner.build_argv(["ls", "-la"], base_policy)
      sep = argv.index("--").not_nil!
      argv[(sep + 1)..].should eq(["ls", "-la"])
    end

    it "passes through policy env vars" do
      policy = Sandboxer::Policy.build { |p| p.env["MY_VAR"] = "hello" }
      argv = runner.build_argv(["echo"], policy)
      i = argv.index("MY_VAR")
      i.should_not be_nil
      argv[i.not_nil! + 1].should eq("hello")
    end

    it "adds --unsetenv for unset_env entries" do
      policy = Sandboxer::Policy.build { |p| p.unset_env << "SECRET" }
      argv = runner.build_argv(["echo"], policy)
      i = argv.index("--unsetenv")
      i.should_not be_nil
      argv[i.not_nil! + 1].should eq("SECRET")
    end
  end
end

# ── SandboxExec ───────────────────────────────────────────────────────────────

describe Sandboxer::SandboxExec do
  runner = Sandboxer::SandboxExec.new
  base_policy = Sandboxer::Policy.new

  describe "#generate_profile" do
    it "starts with version and deny default" do
      profile = runner.generate_profile(base_policy)
      profile.should contain("(version 1)")
      profile.should contain("(deny default)")
    end

    it "includes the BASELINE" do
      profile = runner.generate_profile(base_policy)
      profile.should contain("(allow process-fork)")
      profile.should contain("(allow mach-lookup)")
      profile.should contain("(allow sysctl-read)")
      profile.should contain("/private/var/run/syslog")
    end

    it "grants read-only access to read_only_paths" do
      policy = Sandboxer::Policy.build { |p| p.read_only "/usr/share/myapp" }
      profile = runner.generate_profile(policy)
      profile.should contain("(allow file-read*")
      profile.should contain("/usr/share/myapp")
    end

    it "grants read-write access to read_write_paths" do
      policy = Sandboxer::Policy.build { |p| p.read_write "/tmp/work" }
      profile = runner.generate_profile(policy)
      profile.should contain("(allow file-read* file-write*")
      profile.should contain("/tmp/work")
    end

    it "grants read-write access to tmpfs_paths (no tmpfs on macOS)" do
      policy = Sandboxer::Policy.build { |p| p.tmpfs "/tmp/scratch" }
      profile = runner.generate_profile(policy)
      profile.should contain("(allow file-read* file-write*")
      profile.should contain("/tmp/scratch")
    end

    it "expands relative paths to absolute" do
      policy = Sandboxer::Policy.build { |p| p.read_only "." }
      profile = runner.generate_profile(policy)
      profile.should_not contain("\".\"/")
      profile.should contain(File.expand_path("."))
    end

    it "resolves symlinked paths to their real target, not the symlink" do
      # Built generically with a throwaway symlink rather than asserting
      # the macOS-specific /tmp -> /private/tmp mapping, since this spec
      # also runs under the Linux CI job where that symlink doesn't exist.
      real_dir = File.join(Dir.tempdir, "sbx_real_#{Random::Secure.hex(4)}")
      link_path = File.join(Dir.tempdir, "sbx_link_#{Random::Secure.hex(4)}")
      Dir.mkdir(real_dir)
      File.symlink(real_dir, link_path)

      begin
        policy = Sandboxer::Policy.build { |p| p.read_only link_path }
        profile = runner.generate_profile(policy)
        profile.should contain(File.realpath(real_dir))
        profile.should_not contain(link_path)
      ensure
        File.delete(link_path)
        Dir.delete(real_dir)
      end
    end

    it "falls back to expand_path for paths that don't exist yet" do
      policy = Sandboxer::Policy.build { |p| p.read_write "/tmp/sbx_does_not_exist_yet" }
      profile = runner.generate_profile(policy)
      profile.should contain("/tmp/sbx_does_not_exist_yet")
    end

    it "grants network access when allow_network is true" do
      policy = Sandboxer::Policy.build { |p| p.allow_network = true }
      profile = runner.generate_profile(policy)
      profile.should contain("(allow network-outbound)")
    end

    it "does not grant blanket network access by default" do
      # BASELINE always allows the syslog socket specifically (local
      # logging, not network access) — assert the absence of the bare,
      # unrestricted grant rather than the operation name itself.
      runner.generate_profile(base_policy).should_not contain("(allow network-outbound)")
    end

    it "adds extra rw grant for working_dir not covered by path lists" do
      policy = Sandboxer::Policy.build { |p| p.working_dir = "/tmp/myapp" }
      profile = runner.generate_profile(policy)
      profile.should contain("/tmp/myapp")
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
