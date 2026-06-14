require "./sandboxer"

require "option_parser"

# sandbox_cli.cr — command-line interface for the sandboxer shard.
#
# Build:   shards build
# Binary:  ./bin/sandboxer
#
# Usage:
#   sandboxer run     --policy policy.json -- command [args...]
#   sandboxer inspect --policy policy.json [--platform linux|macos]
#   sandboxer check
#   sandboxer help

module Sandboxer
  module CLI
    VERSION_BANNER = "sandboxer #{Sandboxer::VERSION} — platform-agnostic sandbox runner"

    def self.run(argv : Array(String)) : Int32
      return help(status: 0) if argv.empty?

      subcommand = argv.shift

      case subcommand
      when "run"                  then cmd_run(argv)
      when "inspect"              then cmd_inspect(argv)
      when "check"                then cmd_check(argv)
      when "help", "--help", "-h" then help(status: 0)
      when "version", "--version" then puts VERSION_BANNER; 0
      else
        STDERR.puts "Unknown subcommand: #{subcommand.inspect}"
        STDERR.puts "Run 'sandboxer help' for usage."
        1
      end
    end

    # ── sandboxer run ──────────────────────────────────────────────────────────
    # Loads a policy file and executes a command inside the sandboxer.
    #
    #   sandboxer run --policy policy.json -- python3 script.py
    #   sandboxer run --policy policy.json --allow-network -- curl https://example.com
    #   sandboxer run --policy policy.json --add brew -- brew list

    private def self.cmd_run(argv : Array(String)) : Int32
      policy_path = nil
      allow_network_override = nil
      preset_names = [] of String

      # Split argv on "--" to separate sandboxer flags from the command.
      sep = argv.index("--")
      unless sep
        STDERR.puts "sandboxer run: missing '--' separator before command."
        STDERR.puts "Usage: sandboxer run --policy policy.json -- command [args...]"
        return 1
      end

      sandbox_args = argv[0, sep]
      command = argv[(sep + 1)..]

      if command.empty?
        STDERR.puts "sandboxer run: no command given after '--'."
        return 1
      end

      OptionParser.parse(sandbox_args) do |opts|
        opts.banner = "Usage: sandboxer run [options] -- command [args...]"

        opts.on("-p FILE", "--policy FILE", "Path to JSON policy file") do |file|
          policy_path = file
        end

        opts.on("--allow-network", "Override policy: permit network access") do
          allow_network_override = true
        end

        opts.on("--no-network", "Override policy: deny network access") do
          allow_network_override = false
        end

        opts.on("--add PRESET", "Merge a named preset into the policy (e.g. brew)") do |name|
          preset_names << name
        end

        opts.on("-h", "--help", "Show this help") do
          puts opts
          exit 0
        end

        opts.invalid_option do |flag|
          STDERR.puts "sandboxer run: unknown option #{flag.inspect}"
          STDERR.puts opts
          exit 1
        end
      end

      policy = load_policy(policy_path)
      return 1 if policy.nil?

      # Apply presets.
      preset_names.each do |name|
        preset = resolve_preset(name)
        if preset.nil?
          STDERR.puts "sandboxer run: unknown preset #{name.inspect}. Known presets: brew."
          return 1
        end
        policy = policy.merge(preset)
      end

      # Apply CLI overrides on top of the policy file.
      if override = allow_network_override
        policy.allow_network = override
      end

      begin
        runner = Sandboxer.runner
        result = runner.run(command, policy)
        STDOUT.puts
        STDOUT.print result.stdout
        STDERR.print result.stderr
        result.exit_code
      rescue ex : RunnerUnavailableError
        STDERR.puts "sandboxer: #{ex.message}"
        1
      end
    end

    # ── sandboxer inspect ───────────────────────────────────────────────────────
    # Prints the native invocation (bwrap argv or SBPL profile) that would be
    # used for a given policy, without executing anything.
    #
    #   sandboxer inspect --policy policy.json
    #   sandboxer inspect --policy policy.json --platform macos
    #   sandboxer inspect --policy policy.json --add brew --platform macos

    private def self.cmd_inspect(argv : Array(String)) : Int32
      policy_path = nil
      platform = detect_platform
      preset_names = [] of String

      OptionParser.parse(argv) do |opts|
        opts.banner = "Usage: sandboxer inspect [options]"

        opts.on("-p FILE", "--policy FILE", "Path to JSON policy file") do |file|
          policy_path = file
        end

        opts.on("--platform PLATFORM", "Platform to inspect for: linux, macos") do |name|
          platform = name
        end

        opts.on("--add PRESET", "Merge a named preset into the policy (e.g. brew)") do |name|
          preset_names << name
        end

        opts.on("-h", "--help", "Show this help") do
          puts opts
          exit 0
        end

        opts.invalid_option do |flag|
          STDERR.puts "sandboxer inspect: unknown option #{flag.inspect}"
          exit 1
        end
      end

      policy = load_policy(policy_path)
      return 1 if policy.nil?

      # Apply presets.
      preset_names.each do |name|
        preset = resolve_preset(name)
        if preset.nil?
          STDERR.puts "sandboxer inspect: unknown preset #{name.inspect}. Known presets: brew."
          return 1
        end
        policy = policy.merge(preset)
      end

      # Dummy command for display; inspect shows structure, not a real execution.
      placeholder = ["<command>", "<args...>"]

      case platform
      when "linux"
        runner = Bwrap.new
        STDERR.puts "Note: bwrap is not available on this host — output is for reference only." unless runner.available?
        puts "# bwrap invocation:"
        puts runner.build_argv(placeholder, policy).join(" \\\n  ")
      when "macos"
        runner = SandboxExec.new
        STDERR.puts "Note: sandbox-exec is not available on this host — output is for reference only." unless runner.available?
        puts "# SBPL profile (sandbox-exec -f <profile> -- #{placeholder.join(" ")}):"
        puts runner.generate_profile(policy)
      else
        STDERR.puts "sandboxer inspect: unknown platform #{platform.inspect}. Use 'linux' or 'macos'."
        return 1
      end

      0
    end

    # ── sandboxer check ─────────────────────────────────────────────────────────
    # Probes the current environment and reports which runners are available.
    #
    #   sandboxer check

    private def self.cmd_check(argv : Array(String)) : Int32
      OptionParser.parse(argv) do |opts|
        opts.banner = "Usage: sandboxer check"
        opts.on("-h", "--help", "Show this help") { puts opts; exit 0 }
      end

      puts VERSION_BANNER
      puts "Platform: #{detect_platform}"
      puts

      runners = [
        {Bwrap.new, "bwrap", "Linux (bubblewrap user namespaces)"},
        {SandboxExec.new, "sandbox-exec", "macOS (Seatbelt / SBPL)"},
      ]

      ok = false
      runners.each do |(runner, name, description)|
        if runner.available?
          puts "  ✓ #{name.ljust(16)} #{description}"
          ok = true
        else
          puts "  ✗ #{name.ljust(16)} #{description} — not found"
        end
      end

      puts
      if ok
        puts "At least one runner is available. 'sandboxer run' will work on this host."
        0
      else
        STDERR.puts "No runners available. Install bwrap (Linux) or use macOS with sandbox-exec."
        1
      end
    end

    # ── Helpers ───────────────────────────────────────────────────────────────

    # Maps a preset name to the appropriate Policy for the current platform.
    # Returns nil for unknown names.
    private def self.resolve_preset(name : String) : Policy?
      case name
      when "brew"
        {% if flag?(:darwin) && flag?(:aarch64) %}
          Preset::Brew::MACOS_ARM
        {% elsif flag?(:darwin) %}
          Preset::Brew::MACOS_INTEL
        {% elsif flag?(:linux) %}
          Preset::Brew::LINUX
        {% else %}
          nil
        {% end %}
      else
        nil
      end
    end

    private def self.load_policy(path : String?) : Policy?
      if path
        unless File.exists?(path)
          STDERR.puts "sandboxer: policy file not found: #{path.inspect}"
          return nil
        end
        begin
          Policy.from_json(File.read(path))
        rescue ex : JSON::ParseException
          STDERR.puts "sandboxer: invalid policy JSON in #{path.inspect}: #{ex.message}"
          nil
        end
      else
        # No policy file: use a safe default (deny-all, no network).
        STDERR.puts "sandboxer: no --policy file given; using empty (deny-all) policy."
        Policy.new
      end
    end

    private def self.detect_platform : String
      {% if flag?(:linux) %}
        "linux"
      {% elsif flag?(:darwin) %}
        "macos"
      {% else %}
        "unknown"
      {% end %}
    end

    private def self.help(status : Int32) : Int32
      puts <<-HELP
        #{VERSION_BANNER}

        Subcommands:
          run      Execute a command inside a sandboxer
          inspect  Print the native invocation without executing
          check    Report which sandboxer runners are available
          help     Show this help
          version  Print version

        Examples:
          sandboxer run --policy policy.json -- python3 script.py
          sandboxer run --policy policy.json --allow-network -- curl https://example.com
          sandboxer run --policy policy.json --add brew -- brew list
          sandboxer inspect --policy policy.json
          sandboxer inspect --policy policy.json --platform macos
          sandboxer inspect --policy policy.json --add brew --platform macos
          sandboxer check

        Policy file (JSON):
          {
            "read_only_paths":  ["/usr/share/myapp"],
            "read_write_paths": ["/tmp/workspace"],
            "tmpfs_paths":      ["/tmp"],
            "allow_network":    false,
            "working_dir":      "/tmp/workspace",
            "env":              { "APP_ENV": "sandboxer" }
          }

        All policy keys are optional; omitted keys use safe defaults.
        HELP
      status
    end
  end
end

exit Sandboxer::CLI.run(ARGV)
