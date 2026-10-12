# AGENTS.md

## Zig Development

Use `zigdoc` to discover current APIs for the Zig standard library and any third-party dependencies before coding.
Run `mise run lint` before finishing changes.

Examples:
```bash
zigdoc std.fs
zigdoc std.posix.getuid
zigdoc vaxis.Window
```

## Zig Style

- preferred file order: `//!` module doc comment, `const Self = @This()`, imports, `const log = std.log.scoped(...)`
- pass allocators explicitly and use `errdefer` for cleanup on error
- keep tests inline with the code they cover and include them from the module test entry point

## Safety

- Add assertions at API boundaries and state transitions and avoid trivial assertions.
- Keep functions small and push pure computation into helpers.
- Comments should explain why, not what.
