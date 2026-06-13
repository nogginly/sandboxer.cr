module Sandboxer
  # macOS sandbox runner using sandbox-exec and SBPL profiles.
  #
  # sandbox-exec wraps a process in Apple's Seatbelt framework (a MACF kernel
  # module). It evaluates a declarative SBPL (Sandbox Profile Language) policy
  # against every syscall the process makes; violations return EPERM.
  #
  # SBPL is a Scheme-like DSL. This runner generates a deny-default profile
  # and adds explicit allow rules derived from the policy.
  #
  # Deprecation note: sandbox-exec has been marked deprecated in macOS headers
  # since 10.8 but remains functional through current releases. No public
  # replacement exists for the ad-hoc CLI use case (App Sandbox requires code
  # signing and an app bundle). Used in production by Chromium and Firefox.
  #
  # The BASELINE constant contains the minimum permissions any process needs
  # to start under deny-default. Omitting any of these typically causes an
  # immediate crash or silent hang (dyld, Mach IPC, and sysctl are all gated).
  class SandboxExec < Runner
    BINARY = "sandbox-exec"

    BASELINE = <<-SBPL
      ; --- process lifecycle ---
      (allow process-fork)
      (allow process-exec)
      (allow process-exec-interpreter)

      ; --- mach IPC: required by dyld and most system frameworks ---
      (allow mach-lookup)
      (allow mach-register)

      ; --- sysctl: read by libc on startup ---
      (allow sysctl-read)

      ; --- dyld, system frameworks, and basic device nodes ---
      ; /private/var/db/dyld             = Intel dyld shared cache
      ; /System/Volumes/Preboot/Cryptexes = Apple Silicon dyld shared cache (arm64)
      (allow file-read*
        (subpath "/usr/lib")
        (subpath "/usr/share")
        (subpath "/System/Library")
        (subpath "/System/Volumes/Preboot/Cryptexes")
        (subpath "/private/var/db/dyld")
        (literal "/dev/null")
        (literal "/dev/random")
        (literal "/dev/urandom"))

      ; --- stat/readdir: needed broadly ---
      (allow file-read-metadata)

      ; --- root filesystem: required for path resolution ---
      ; ! Note that file-read-data (literal "/") grants read on the
      ;   root directory node only — not its contents. That's distinct
      ;   from (subpath "/") which would be a blanket allow on the
      ;   entire filesystem.
      (allow file-read-data (literal "/"))

      SBPL

    def available? : Bool
      !Process.find_executable(BINARY).nil?
    end

    def run(command : Array(String), policy : Policy) : Result
      raise RunnerUnavailableError.new(
        "#{BINARY} not found. It should be present at /usr/bin/sandbox-exec on macOS."
      ) unless available?

      # File.tempfile with a block returns File, not the block value, so
      # Crystal cannot infer Result as the return type. Manage the tempfile
      # explicitly with begin/ensure instead.
      profile_file = File.tempfile("sbx_", ".sb")
      begin
        profile_file.print(generate_profile(policy))
        profile_file.flush
        execute([BINARY, "-f", profile_file.path, "--"] + command)
      ensure
        profile_file.close
        File.delete(profile_file.path) rescue nil
      end
    end

    # Returns the SBPL profile string for *policy*.
    # Useful for inspection, logging, or writing to disk without executing.
    #
    # All paths are expanded to absolute before being written to the profile.
    # SBPL evaluates paths against the real filesystem and does not resolve
    # relative paths — passing "./" would silently match nothing.
    def generate_profile(policy : Policy) : String
      String.build do |s|
        s << "(version 1)\n"
        s << "(deny default)\n\n"
        s << BASELINE
        s << "\n"

        # ── Read-only paths ───────────────────────────────────────────────
        unless policy.read_only_paths.empty?
          s << "(allow file-read*\n"
          policy.read_only_paths.each do |path|
            s << "  (subpath #{File.expand_path(path).inspect})\n"
          end
          s << ")\n\n"
        end

        # ── Read-write paths ──────────────────────────────────────────────
        unless policy.read_write_paths.empty?
          s << "(allow file-read* file-write*\n"
          policy.read_write_paths.each do |path|
            s << "  (subpath #{File.expand_path(path).inspect})\n"
          end
          s << ")\n\n"
        end

        # ── tmpfs paths ───────────────────────────────────────────────────
        # macOS has no tmpfs. We grant RW access to the existing path.
        # For true scratch isolation, pass a pre-created Dir.tempdir here.
        unless policy.tmpfs_paths.empty?
          s << "; tmpfs: no tmpfs on macOS — granting rw to existing paths\n"
          s << "(allow file-read* file-write*\n"
          policy.tmpfs_paths.each do |path|
            s << "  (subpath #{File.expand_path(path).inspect})\n"
          end
          s << ")\n\n"
        end

        # ── Working directory ─────────────────────────────────────────────
        # Ensure it's accessible even if not covered by the path lists above.
        if wd = policy.working_dir
          abs_wd = File.expand_path(wd)
          all_paths = (policy.read_write_paths +
                       policy.read_only_paths +
                       policy.tmpfs_paths).map { |p| File.expand_path(p) }
          unless all_paths.any? { |p| abs_wd.starts_with?(p) }
            s << "; working_dir not covered by path lists — granting rw\n"
            s << "(allow file-read* file-write* (subpath #{abs_wd.inspect}))\n\n"
          end
        end

        # ── Network ───────────────────────────────────────────────────────
        if policy.allow_network
          s << "(allow network-outbound)\n"
          s << "(allow network-inbound)\n"
          s << "(allow network-bind)\n"
        end
      end
    end
  end
end
