# zlap

`zlap` is a table-driven command-line parser for Zig 0.17.
Describe commands as structs and tagged unions, then parse argv into typed values.

## Features

- Flags, positionals, short aliases and short clusters
- Enums, repeated values, environment fallbacks and response files
- Nested commands, help, diagnostics and shell completion
- Compile-time JSON command specifications

## Add it to a project

From the consumer package:

```sh
zig fetch --save git+https://github.com/lumertzg/zlap.git
```

This records `zlap` in the consumer's `build.zig.zon`. Its `build.zig` then imports
the dependency:

```zig
const zlap_dep = b.dependency("zlap", .{ .target = target, .optimize = optimize });
exe.root_module.addImport("zlap", zlap_dep.module("zlap"));
```

This package exports its module with `b.addModule`. A consuming package obtains it
with `b.dependency`.

## Define and parse commands

Command structs hold flags and positionals. A default makes a field optional, while
a field without one is required. Field names become kebab-case long flags unless
metadata makes them positional. A tagged union field selects a nested command.

Use `parseFrom(T, allocator, argv, options)` for explicit argv and error handling.
Use `parse(T, init)` in `std.process.Init` programs to read process arguments and
render help or diagnostics. `defaults`, `fill`, and `updateFrom` support in-place
parsing and updates.

See [basic](examples/basic/main.zig) and [nested](examples/nested/main.zig) examples.
Build them with:

```sh
cd examples && zig build
```

The basic example reads `ZLAP_JOBS` when `--jobs` is absent:

```sh
cd examples
ZLAP_JOBS=4 zig build run-basic -- input.txt
ZLAP_JOBS=4 zig build run-basic -- --jobs 2 input.txt
```

Flags take precedence over environment values.

## Ownership

Scalar strings borrow argv or environment storage. `parseFrom` and `fill` allocate
lists with the supplied allocator, and callers free populated slices with it.
`updateFrom` uses that allocator for replacements.
`parse` allocates lists in `init.arena`, which owns their storage.

## Other API

`writeHelp`, `writeVersion`, and `renderDiagnostic` render output. `completionScript`
and `complete` support Bash, Zsh, Fish, PowerShell, and Nushell. `spec` returns a
compile-time JSON description of the command tree.

Unknown flags and commands can include a typo suggestion. Suggestions only consider
names accepted in the failing command's scope, including aliases and global flags.

### Shell completion

Set `.completion = true` in the root command's metadata when using `parse`. Emit
`completionScript(App, shell)` from your application's completion-install command,
then source that output in the corresponding shell. Initialize Zsh's completion
system with `compinit` first. Nushell scripts use command-wide completers and require
Nushell 0.116 or newer. PowerShell scripts target PowerShell 7.

Completion suggests flags, subcommands, and enum values for flags and positionals,
including positional values after `--`. Attached values retain their flag prefix,
so `complete` returns `--format=plain` for `--format=pl`. The shell adapters handle
insertion quoting and cursor units. The direct `complete` API takes a byte-offset
cursor and does not evaluate shell expansions or provide filesystem candidates.
Shells may supply their own filesystem fallback for unconstrained values.

### JSON command specification

`spec(App)` returns JSON at compile time. Each binding includes `required`, `env`,
`choices`, list `min`/`max`, `default_missing`, `require_equals`,
`allow_hyphen_values`, and `conflicts`/`requires`, alongside its names and help.
`required` means the field has no declaration default. Environment values can still
satisfy it. `choices` is null for non-enum fields. Relationships use the target's
`field` name in the same command, independently of CLI renames or display labels.
One-of switches retain their shared binding ID and fixed `value`.

## Test

```sh
zig build test
```

Real-shell integration tests run against installed Bash, Zsh, Fish, PowerShell, and
Nushell runtimes:

```sh
python3 tests/completion.py
```

Missing shells are skipped locally. CI uses `--require-all` to require all five.
