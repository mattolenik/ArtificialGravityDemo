# Audit fixes — 2026-09-29

All 26 confirmed findings from the audit of revision `cb41a6a` have been addressed
in the working tree. The historical report is retained under
`audit/2026-09-29/REPORT.md`; its findings describe the original revision.
No release or remote publication is implied by this completion record.

## Resolution map

| ID | Resolution | Regression coverage |
|---|---|---|
| 01 | Balanced multiline parsing and retained source literals preserve scene data. | Scene parser and Godot-authored scene tests |
| 02 | Unknown Variants retain their original syntax; explicit property replacements still accept typed shorthand. | Scene parser, public read/write round trip, engine polygon test |
| 03 | Animation changes retain existing keys and unknown fields, and edit only the root resource. Unsupported track edits fail before writing. | Animation tests, nested resource test, engine keyframe test |
| 04 | Subtree removal matches complete path components. | `Player`/`Player2` and root deletion tests |
| 05 | Enemy costs must be positive and generation work is bounded. | Wave input rejection tests |
| 06 | Paths resolve existing ancestors and enforce canonical root containment. | Escaping, dangling and internal symlink tests |
| 07 | Rename updates descendants, owners, relative node references and signal endpoints; ambiguous references fail before mutation. | Rename, empty NodePath, collision and ambiguity tests |
| 08 | Resource values serialize recursively with escaped strings and retained dictionary keys. | Resource handler and engine load tests |
| 09 | Scene hierarchy attaches descendants beneath the actual root. | Hierarchy regression |
| 10 | Audio edits retain effect resources, slots, unknown fields and surviving bus settings. | Audio preservation and StringName listing tests |
| 11 | InputMap edits preserve original event literals and unknown action fields. | Modifier, typed event and unknown-field tests |
| 12 | Generated UI uses project-relative `res://` script references. | Nested output and engine load tests |
| 13 | Movement generation selects a compatible default base and rejects unsupported explicit bases. | Default, 2D/3D and engine compilation tests |
| 14 | Empty generated functions include `pass`. | Empty menu/dialog engine tests |
| 15 | Explicit zero alpha and margins survive generation. | Theme handler and engine tests |
| 16 | Navigation readiness checks dimensions, enabled regions and non-null meshes. | Navigation validation tests |
| 17 | The bridge requires a fresh private project token before dispatching RPCs. | Node connection tests and real-engine rejection of missing/wrong pairing |
| 18 | Undo restores subtree ownership and sibling ordering before save. | Real-editor remove/undo/save test |
| 19 | Runtime output uses the configured Godot log file, with explicit source and availability status. | Runtime print/error and disabled-capture tests |
| 20 | Client and plugin timeouts account for requested wait duration. | Six-second runtime wait and client fake-clock test beyond 30 seconds |
| 21 | Log cursors advance only through completed lines and handle truncation. | Incremental log integration test |
| 22 | Connection generations and socket-specific callbacks isolate reconnect attempts. | Connection unit and real bridge reconnect tests |
| 23 | Server shutdown closes the editor connection and pending requests. | HTTP SIGTERM smoke test with a connected bridge |
| 24 | Main-module detection resolves executable symlinks. | Direct and symlinked CLI MCP handshake/EOF tests |
| 25 | A shared file-tool queue serializes operations; atomic writes reject observed external conflicts. | Twenty concurrent edits, external-edit interleavings, queue recovery and exclusive creation tests |
| 26 | Project initialization preflights every target, defaults to exclusive creation, and requires explicit overwrite for conflicts. | Existing project/template protection, overwrite and symlink tests |

Independent review of the fixes also found and corrected literal metadata reuse,
empty NodePath normalization, nested animation key replacement, post-publication
snapshot adoption, and audio StringName display issues. Each has a regression test.

## Validation

- Build passes and tracked `dist` output is regenerated.
- Full local suite: **196 tests pass across 25 files** with Godot 4.7 available.
- Coverage: **53.60% statements, 47.86% branches, 59.19% functions, 53.34% lines**.
  Coverage gates were raised to 50/40/50/50 percent respectively.
- CLI smoke checks pass, including npm-style executable symlinks, stdin EOF,
  and POSIX HTTP shutdown while connected to the editor bridge.
- Real Godot 4.3 and 4.7 checks pass for generated resources/scripts and scene,
  animation and input preservation. Bridge integration passes on both versions.
- `npm audit --audit-level=moderate`: **zero vulnerabilities**.
- Package dry run includes the executable, new runtime helpers and canonical addon.

Local validation uses macOS and Node 20/24. The new CI workflow schedules Node
20/24 on Windows, macOS and Linux, plus Godot 4.3/4.7 on Linux; those remote runs
have not yet been observed. Windows skips the POSIX signal assertion because
Node forcibly terminates Windows children when sent SIGTERM; EOF checks still run.
Ordinary tests skip the two engine-dependent cases when Godot is unavailable;
the dedicated engine commands require it.

## Upgrade and remaining boundaries

Update the MCP server and the copied `addons/godot_ai_bridge` folder together,
then restart or re-enable the Godot plugin. Start the server with `--project`
pointing to that project so `godot_connect` can read its private pairing file.
Legacy unpaired clients are intentionally incompatible. See README pairing
instructions for file permissions and explicit-token connections.

Runtime capture requires Godot file logging and reports when it is unavailable.
It returns log entries, not structured engine stack traces.

Unsupported scene sections, animation edits and ambiguous rename references
fail safely; the parser does not promise to edit every possible Godot format.
Filesystem serialization is within one MCP process. Conflict checks detect
observed external edits but do not lock other processes, and multiple output
files are not committed as a single transaction. Canonical path validation is
not an operating-system sandbox.
