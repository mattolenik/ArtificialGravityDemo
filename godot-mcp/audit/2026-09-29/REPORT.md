# Godot MCP deep audit — 2026-09-29

> Historical baseline report. All 26 confirmed findings have since been addressed
> locally; see [fixes and validation](../../docs/AUDIT_FIXES.md) for the resolution
> map, upgrade requirements, and remaining boundaries.

Audited [alexmeckes/godot-mcp at cb41a6a](https://github.com/alexmeckes/godot-mcp/tree/cb41a6a478417bf56ad73e55f3a3a2b7e0cb0262), the current main revision fetched for this audit. Three specialist subagents reviewed the Godot bridge, scene/resource/animation code, and generated-content tools; the primary reviewer checked transports, packaging, project initialization, concurrency, and combined evidence.

**Assessment: routine edits can silently destroy existing project data. Fix the preservation and bridge-access issues before relying on this release for autonomous editing of valuable projects.** The build and 150 tests pass, but targeted probes reproduce problems that those tests do not exercise.

There are **26 confirmed findings: 9 P1 and 17 P2**. P1 means fix urgently because of data loss, a security-boundary failure, or whole-server unavailability. P2 means a material functional/reliability defect to schedule next. These are engineering priorities, not CVSS scores. Dependency advisories and unverified observations are separate and are not included in the count.

## Findings index

Detailed reproductions, affected call paths, and fix directions are in the linked component reports. Findings are grouped by area rather than discovery time.

| ID | Priority | Confirmed behavior | Primary source |
|---|---|---|---|
| 01 | P1 | Scene rewrites erase Godot-authored multiline dictionaries and arrays | [tscn-parser.ts:249](/Users/alexmeckes/Documents/ChatGPT/godotmcp/src/parsers/tscn-parser.ts:249) |
| 02 | P1 | Unsupported Godot literals become quoted strings; Polygon2D geometry disappears | [tscn-parser.ts:536](/Users/alexmeckes/Documents/ChatGPT/godotmcp/src/parsers/tscn-parser.ts:536) |
| 03 | P1 | Adding one animation key deletes existing Godot-authored keys | [animation-tools.ts:901](/Users/alexmeckes/Documents/ChatGPT/godotmcp/src/tools/animation-tools.ts:901) |
| 04 | P1 | Removing Player also removes descendants of Player2 | [tscn-parser.ts:657](/Users/alexmeckes/Documents/ChatGPT/godotmcp/src/parsers/tscn-parser.ts:657) |
| 05 | P1 | A zero-cost enemy causes an infinite synchronous generation loop | [resource-tools.ts:820](/Users/alexmeckes/Documents/ChatGPT/godotmcp/src/tools/resource-tools.ts:820) |
| 06 | P1 | Symlinks bypass the advertised project filesystem boundary | [path-utils.ts:28](/Users/alexmeckes/Documents/ChatGPT/godotmcp/src/utils/path-utils.ts:28) |
| 07 | P2 | Renaming a node leaves children and references at their old paths | [tscn-parser.ts:693](/Users/alexmeckes/Documents/ChatGPT/godotmcp/src/parsers/tscn-parser.ts:693) |
| 08 | P2 | Resource dictionaries serialize as `[object Object]`; quotes corrupt strings | [resource-tools.ts:422](/Users/alexmeckes/Documents/ChatGPT/godotmcp/src/tools/resource-tools.ts:422) |
| 09 | P2 | Returned scene hierarchy splits root and descendants into unrelated trees | [tscn-parser.ts:709](/Users/alexmeckes/Documents/ChatGPT/godotmcp/src/parsers/tscn-parser.ts:709) |
| 10 | P1 | Changing audio bus volume deletes persisted effect chains | [audio-tools.ts:609](/Users/alexmeckes/Documents/ChatGPT/godotmcp/src/tools/audio-tools.ts:609) |
| 11 | P2 | Editing InputMap removes modifiers from unrelated existing bindings | [input-tools.ts:672](/Users/alexmeckes/Documents/ChatGPT/godotmcp/src/tools/input-tools.ts:672) |
| 12 | P2 | Nested relative UI output paths produce broken script references | [ui-component-tools.ts:375](/Users/alexmeckes/Documents/ChatGPT/godotmcp/src/tools/ui-component-tools.ts:375) |
| 13 | P2 | Default movement generation emits GDScript that cannot compile | [script-tools.ts:585](/Users/alexmeckes/Documents/ChatGPT/godotmcp/src/tools/script-tools.ts:585) |
| 14 | P2 | Empty menu/dialog button arrays produce invalid function bodies | [ui-component-tools.ts:458](/Users/alexmeckes/Documents/ChatGPT/godotmcp/src/tools/ui-component-tools.ts:458) |
| 15 | P2 | Explicit zero alpha becomes opaque; zero margins are omitted | [ui-theme-tools.ts:408](/Users/alexmeckes/Documents/ChatGPT/godotmcp/src/tools/ui-theme-tools.ts:408) |
| 16 | P2 | Navigation validation approves incompatible dimensions/null mesh readiness | [navigation-tools.ts:706](/Users/alexmeckes/Documents/ChatGPT/godotmcp/src/tools/navigation-tools.ts:706) |
| 17 | P1 | Unauthenticated bridge accepts arbitrary Origin and executes GDScript | [ws_server.gd:57](/Users/alexmeckes/Documents/ChatGPT/godotmcp/addons/godot_ai_bridge/ws_server.gd:57) |
| 18 | P1 | Remove → undo → save loses subtree descendants | [message_handler.gd:218](/Users/alexmeckes/Documents/ChatGPT/godotmcp/addons/godot_ai_bridge/message_handler.gd:218) |
| 19 | P2 | Standard runtime output/errors never reach the selected plugin capture hook | [godot_ai_bridge.gd:124](/Users/alexmeckes/Documents/ChatGPT/godotmcp/addons/godot_ai_bridge/godot_ai_bridge.gd:124) |
| 20 | P2 | Runtime waits longer than five seconds time out before completion | [godot_ai_bridge.gd:98](/Users/alexmeckes/Documents/ChatGPT/godotmcp/addons/godot_ai_bridge/godot_ai_bridge.gd:98) |
| 21 | P2 | Incremental log polling skips the first newly appended line | [message_handler.gd:985](/Users/alexmeckes/Documents/ChatGPT/godotmcp/addons/godot_ai_bridge/message_handler.gd:985) |
| 22 | P2 | Immediate reconnect is cleared by the old socket's close callback | [editor-tools.ts:776](/Users/alexmeckes/Documents/ChatGPT/godotmcp/src/tools/editor-tools.ts:776) |
| 23 | P2 | HTTP SIGTERM shutdown leaves the connected bridge process alive | [index.ts:259](/Users/alexmeckes/Documents/ChatGPT/godotmcp/src/index.ts:259) |
| 24 | P2 | npm-style symlinked CLI silently exits without starting the server | [index.ts:274](/Users/alexmeckes/Documents/ChatGPT/godotmcp/src/index.ts:274) |
| 25 | P2 | Concurrent scene edits report success while overwriting each other | [scene-tools.ts:270](/Users/alexmeckes/Documents/ChatGPT/godotmcp/src/tools/scene-tools.ts:270) |
| 26 | P2 | Project initialization overwrites existing config, ignore rules, and templates | [docs-tools.ts:1669](/Users/alexmeckes/Documents/ChatGPT/godotmcp/src/tools/docs-tools.ts:1669) |

**Findings 01–09:** [Scene, animation, resource, and path report](/Users/alexmeckes/Documents/ChatGPT/godotmcp/audit/2026-09-29/scene-findings.md).

**Findings 10–16:** [Audio, input, script, shader, UI, and navigation report](/Users/alexmeckes/Documents/ChatGPT/godotmcp/audit/2026-09-29/generation-findings.md).

**Findings 17–23:** [Editor bridge and runtime report](/Users/alexmeckes/Documents/ChatGPT/godotmcp/audit/2026-09-29/bridge-findings.md).

The symlink issue assumes a symlink already exists or can be planted in the project; it is a failure of the promised root restriction, not evidence that this local tool is a complete sandbox. For the bridge issue, a raw WebSocket client with an untrusted Origin successfully invoked `execute.gdscript` without initialization or credentials. A browser exploit was not run. Browser loopback access, Local Network Access, and mixed-content restrictions affect reachability; this is not a claim that every website can exploit every browser. The HTTP transport's Origin guard does not protect the separate Godot WebSocket server.

## Additional server and packaging findings

### 24 — P2: Resolve the executable symlink before deciding whether to start

The main-module guard compares the real module filename with the unresolved `process.argv[1]`. npm's executable on Unix is normally a symlink, so the comparison fails and `main()` is never called. A temporary symlink to the same built `dist/index.js` exited successfully with no startup output; invoking the target directly started the stdio server normally. Both executions used the same Node binary and arguments. This breaks `godot-mcp`/npm-bin style launch while the README's explicit `node /path/dist/index.js` workaround works.

Normalize both paths through realpath or separate the always-executed CLI entry from the importable server module. Add a packaging smoke test that installs or symlinks the declared binary and completes an MCP handshake.

### 25 — P2: Serialize each file's read-modify-write transaction

`godot_modify_node` reads at line 270, mutates an in-memory copy, and overwrites the file at line 280 without locking or version checks. Multiple calls can read the same original file and each report success, with only the last write surviving. Ten simultaneous requests setting ten distinct root metadata properties returned ten successful responses but persisted only one property, in all three reproduction runs. This is independent of the parser's lossy serialization.

Queue mutations per canonical file path, or use optimistic version checks and return conflicts. Use temporary-file plus rename writes to avoid partial-file exposure, but note that atomic rename alone does not prevent lost updates. Apply the same transaction policy to other read-modify-write handlers. Coordinate with externally edited files through content/version checks rather than assuming an in-process lock covers Godot itself.

### 26 — P2: Refuse initialization over an existing project by default

`godot_init_project` creates directories recursively and then unconditionally overwrites `project.godot`, `.gitignore`, template files, and optionally plugin files. Calling it on a directory with an existing project succeeds while erasing existing settings/autoloads and ignore rules. The reproduction used an empty template and demonstrated loss of the existing `Save` autoload and `private-data/` ignore rule. Nonempty templates additionally overwrite matching main scenes/player scripts.

Preflight all conflicting files before writing and reject an existing project unless a clearly documented overwrite mode is explicitly requested. A retry should not silently reset a project. The initializer also deliberately accepts an arbitrary absolute `projectPath`; this contradicts the blanket tool-description statement that all file operations are restricted to the configured root. Either enforce the boundary or document initialization as an explicit exception. The latter discrepancy is not counted as a separate finding.

## Verification and test quality

Environment: macOS, Node **24.15.0**, npm **11.12.1**, Godot **4.7.stable.official.5b4e0cb0f**. Dependencies installed from the lockfile. Implementation files were unchanged; rebuilding reproduced the tracked JavaScript content. Build-induced executable permission change was restored.

| Check | Result |
|---|---|
| `npm ci --ignore-scripts` | Passed |
| `npm run build` | Passed |
| `npm test` | 150 tests across 17 files passed |
| `npm run test:coverage` | Passed configured thresholds; statements 29.14%, branches 24.5%, functions 35.04%, lines 29.4% |
| Modern + legacy MCP HTTP tests | Passed |
| Real HTTP Host/Origin rejection probes | Hostile Host, hostile Origin, and null Origin rejected with 403 |
| Invalid MCP tool input | Returned `isError: true` |
| Package dry run after completed build | 83 entries; server entry and addon files present |
| Scene/resource probe | 11 of 11 targeted defects reproduced; Godot confirmed semantic loss/load errors |
| Generated content probe | Godot confirmed audio/input/UI/script defects |
| Shader parser checks | All 11 effects and five custom shader-type templates passed syntax checks |
| Live bridge tests | Isolated headless editor plus attached runtime exercised; temporary processes stopped |

The green suite is weak evidence of production correctness in several areas. Scene-tool tests call mocked filesystem functions without registering the tool. Script/shader/procedural tests largely exercise copied regexes or toy algorithms. The registry integration test establishes discovery, not correctness of most tools. Parser round-trip tests assert counts rather than equivalence; animation fixtures use single-line dictionaries unlike Godot's saver. Audio fixtures omit effects. Bridge tests inspect method strings and a schema rather than execute socket lifecycle or Godot undo.

Production statement coverage is **6.55% for scene tools, 1.84% for resource tools, 2.32% for script tools, 3.63% for shader tools, and 1.24% for UI components**. The repository has no checked-in GitHub Actions workflow. Coverage percentage alone is not the target: the missing tests are round-trip preservation, registered-handler behavior, actual engine acceptance, and transport lifecycle.

Godot may log script/resource errors and still exit zero when a probe catches a failed load. Future engine tests must inspect returned resources/script validity and expected state, not just process exit status. Shader checks here establish syntax; they do not establish visual correctness.

## Dependencies

`npm audit` reported **four moderate affected-package entries, zero high and zero critical**, recorded in [npm-audit.json](/Users/alexmeckes/Documents/ChatGPT/godotmcp/audit/2026-09-29/npm-audit.json). The entries cover the Vitest development dependency family and transitive Hono. This is not four demonstrated exploitable vulnerabilities in the running MCP server.

Update the pinned Vitest/coverage pair together to a patched compatible version (the audit reports 4.1.11) and refresh the Hono resolution to a patched release (the audit reports a fix at 4.13.5 for the listed ranges). The [Vitest advisory](https://github.com/advisories/GHSA-82fw-gwwq-j7x9) concerns exposed mocker/dev-server paths; the checked-in test configuration uses the Node environment. The [Hono toSSG advisory](https://github.com/advisories/GHSA-gqvv-2mrq-wpjv) covers functionality not directly invoked in this project's server code. Other Hono advisories are listed in the saved audit result; exploitability through this adapter was not established. No dependency upgrades were applied during this audit.

## Recommended repair sequence

1. **Prevent damage:** add regression fixtures for findings 01–06, 10, and 18; reject unsupported document constructs before overwriting; correct deletion boundaries/undo ownership; bound procedural work. Add bridge pairing/authentication and enforce the intended filesystem boundary.
2. **Make edits preserve data:** share a lossless Godot Variant/document representation across scenes, animation, audio, InputMap, and resources, or delegate mutations to Godot where practical. Preserve unknown fields/sections. Add per-file transactions and explicit initialization overwrite policy.
3. **Restore reliable operation:** fix CLI symlink handling, reconnect lifecycle, shutdown disposal, duration-aware timeouts, and output/log ingestion.
4. **Validate generated artifacts:** canonicalize resource paths, make templates compatible with their base classes, handle empty/zero values, and test outputs by loading them in Godot. Add dimension-aware navigation checks.
5. **Gate releases on behavior:** run build/unit tests, real Godot fixture round trips, registered-tool integration, installed-binary handshake, and dependency checks in CI. Include supported Godot and Node versions rather than relying on the single environment used here.

## Reproduction artifacts

Run from the repository root after installing dependencies and building:

```sh
node audit/2026-09-29/main-repro.mjs
node audit/2026-09-29/scene-repro.mjs "$PWD"
node audit/2026-09-29/generation-repro.mjs
```

These scripts create disposable projects in the system temp directory; the wave-loop probe has a two-second subprocess timeout. `GODOT_BIN` can override the Godot executable for scene/generation checks. The scene probe falls back to textual fixtures if Godot is unavailable; that fallback does not provide engine validation. Reports of a reproduced defect are intentionally expected on this revision; these are audit probes, not a passing regression suite.

Saved outputs: [main-results.txt](/Users/alexmeckes/Documents/ChatGPT/godotmcp/audit/2026-09-29/main-results.txt), [scene-results.txt](/Users/alexmeckes/Documents/ChatGPT/godotmcp/audit/2026-09-29/scene-results.txt), [generation-results.txt](/Users/alexmeckes/Documents/ChatGPT/godotmcp/audit/2026-09-29/generation-results.txt), and [validation.txt](/Users/alexmeckes/Documents/ChatGPT/godotmcp/audit/2026-09-29/validation.txt). The bridge report contains separate manual reproduction steps and the original temporary fixture location.

## Limits and unchanged state

This audit combines static review and targeted execution; it is not exhaustive execution of all 99 tools or a formal security proof. Windows/Linux, the minimum declared Node version, older supported Godot 4.x versions, browser exploitation, GUI visual layout, shader appearance, and screenshot/input behavior were not fully exercised. Secondary static concerns in component reports are explicitly separated from confirmed findings.

No implementation fixes, dependency changes, commits, PRs, or remote writes were made. The only new repository files are these audit reports, probes, and captured results.
