# Contributing

Use Zig 0.16.0, installed directly or through [mise](https://mise.jdx.dev/).

From the repository root, run:

```sh
zig build test
zig build
```

The test step also checks formatting. To check the examples, run:

```sh
cd examples
zig build fmt
zig build
```

## Commit messages

Use Conventional Commits for every commit and pull request title:
`type: subject` or `type(scope): subject`. Common types are `feat`, `fix`,
`docs`, and `chore`.

Examples:

```text
feat(parser): support optional values
fix(completion): preserve escaped spaces
```

Keep changes small and focused. Add regression coverage for behavior changes. Tests
live beside the code they cover under `src`. Ensure the module is imported by
`src/root.zig`, which registers the library's test modules.

Update public API documentation and examples when a user-visible API changes.
Use the repository's Zig conventions: `camelCase` functions, `snake_case` values,
and `PascalCase` types. Pass allocators explicitly, document ownership, and keep
comments limited to intent, contracts, invariants, or hidden constraints.
