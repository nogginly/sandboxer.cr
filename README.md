# Sandboxer

> **Very much in development.**

A Crystal shard for running shell commands inside a platform-native sandbox, with a configurable access policy.

|Platform|Mechanism                                |Status    |
|--------|-----------------------------------------|----------|
|macOS   |`sandbox-exec` + SBPL profiles (Seatbelt)|✔️ Runs    |
|Linux   |`bwrap` (Bubblewrap) user namespaces     |❗️ Untested|

## Usage as a shard

Add to your `shard.yml`:

```yaml
dependencies:
  sandboxer:
    github: nogginly/sandboxer.cr
```

Then `shards install`.

### Defining a policy

```crystal
require "sandboxer"

policy = Sandboxer::Policy.build do |p|
  p.read_only "/usr/share/myapp"   # paths the process may read
  p.read_write "/tmp/workspace"    # paths the process may read and write
  p.tmpfs "/tmp"                   # in-memory scratch space (Linux); RW grant (macOS)
  p.allow_network = false          # deny all network access
  p.working_dir = "/tmp/workspace"
  p.env["APP_ENV"] = "sandbox"     # explicit env vars inside the sandbox
end
```

All fields are optional. Omitted fields default to the safest option: no network, no paths, no extra env vars.

Policies can also be loaded from a JSON file:

```crystal
policy = Sandboxer::Policy.from_json(File.read("policy.json"))
```

```json
{
  "read_only_paths":  ["/usr/share/myapp"],
  "read_write_paths": ["/tmp/workspace"],
  "tmpfs_paths":      ["/tmp"],
  "allow_network":    false,
  "working_dir":      "/tmp/workspace",
  "env":              { "APP_ENV": "sandbox" }
}
```

### Running a command

```crystal
result = Sandboxer.run(["python3", "script.py"], policy)

if result.success?
  puts result.stdout
else
  STDERR.puts result.stderr
  exit result.exit_code
end
```

`Sandboxer.run` selects the appropriate runner for the current platform automatically. Exit codes follow Unix conventions; signal exits are mapped to `128 + signal_number`.

### Inspecting the generated invocation

Both runners expose their native policy representation without executing, which is useful for logging, auditing, or iterating on a policy:

```crystal
# Linux: print the bwrap flag list
runner = Sandboxer::Bwrap.new
puts runner.build_argv(["python3", "script.py"], policy).join(" ")

# macOS: print the SBPL profile
runner = Sandboxer::SandboxExec.new
puts runner.generate_profile(policy)
```

### Checking runner availability

```crystal
Sandboxer.platform_runners.each do |runner|
  puts "#{runner.class}: #{runner.available? ? "available" : "not found"}"
end
```

### Merging policies

Policies can be merged to layer reusable building blocks on top of a base policy:

```crystal
merged = my_policy.merge(other_policy)
```

Merge rules:
- **Path arrays** (`read_only_paths`, `read_write_paths`, `tmpfs_paths`, `unset_env`): union, duplicates removed.
- **`allow_network`**: `true` if either policy allows it.
- **`new_session`**: `true` if either policy requires it.
- **`working_dir`**: `other` wins if set, otherwise `self` is kept.
- **`env`**: merged; `other` wins on key collision.

`merge` returns a new `Policy`; neither original is modified.

### Presets

Sandboxer ships pre-defined policies for common toolchains under `Sandboxer::Preset`. Merge one into your policy rather than enumerating paths manually:

```crystal
# Homebrew on Apple Silicon
policy = my_policy.merge(Sandboxer::Preset::Brew::MACOS_ARM)

# Homebrew on Intel macOS
policy = my_policy.merge(Sandboxer::Preset::Brew::MACOS_INTEL)

# Homebrew on Linux
policy = my_policy.merge(Sandboxer::Preset::Brew::LINUX)
```

Presets only add permissions — they never enable network access or override your `working_dir` unless you merge them in that order intentionally.

## CLI

> **Note:** The CLI is not yet distributed as a release binary. If you need it today, build from source — see [DEVELOPMENT.md](./DEVELOPMENT.md). A release workflow is planned.

The CLI will supports the following subcommands:

```sh
# Run a command inside a sandbox
sandboxer run --policy policy.json -- command [args...]

# Run a brew-installed command
sandboxer run --policy policy.json --add brew -- brew list

# Print the native invocation without executing
sandboxer inspect --policy policy.json [--platform linux|macos]

# Preview the effect of a preset without executing
sandboxer inspect --policy policy.json --add brew [--platform linux|macos]

# Check which sandbox runners are available on this host
sandboxer check
```

## Development

See [DEVELOPMENT.md](./DEVELOPMENT.md) for how to build, run the specs, and understand the internals.

## Contributions, by invitation!

*With apologies*, at this time contributions are *by invitation only* and limited to people I know and see often.

These are early days for _Sandboxer_ and I am busy with family and work.

At this time I want to work on this at a manageable pace.
