# Contributing

Issues and pull requests are welcome.

## Development setup

1. Install Node.js 20 or newer.
2. Run `npm ci`.
3. Run `npm run build` and `npm test` before submitting a change.
4. Run `npm run test:coverage` when changing tool behavior.
5. Run `npm run test:cli` after building to check direct and npm-style startup
   and shutdown with an active editor connection.
6. Install Godot and run `npm run test:godot` and `npm run test:bridge` for
   engine-dependent behavior. Set `GODOT_BIN` to override the executable.
   These commands require Godot; ordinary `npm test` skips engine tests when it
   is unavailable. All engine tests use disposable projects and isolated ports.

Keep file-based operations inside the configured Godot project root. When
changing the editor RPC contract, update both `src/tools/editor-tools.ts` and
the canonical plugin in `addons/godot_ai_bridge`, then extend the contract
tests.

Use `FileToolRegistry` for production registries and `utils/project-fs` for tool
reads/writes so operations participate in the shared queue, atomic writes, and
conflict checks. Initialization is an explicit exception to the configured root:
its own chosen project root is enforced and existing output files require the
`overwrite` option.

Regression tests should call registered tool handlers and assert preserved data,
not copied implementations. Use Godot-authored fixtures for text formats and
check engine errors and resource state, because failed loads may still exit zero.
CI checks Node 20/24 across Windows, macOS, and Linux, and Godot 4.3/4.7 on Linux.
Coverage gates require 50% statements/lines, 40% branches, and 50% functions.

Generated files in `dist` are published with the package. Rebuild them after
source changes, but do not add generated test files.
