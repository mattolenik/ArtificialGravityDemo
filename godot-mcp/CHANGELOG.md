# Changelog

All notable changes to this project will be documented here.

The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project uses [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Fixed

- Preserve scene Variants, multiline data, animation keys, audio effects, and
  unrelated input bindings during file edits; reject unsupported mutations safely.
- Correct subtree deletion, rename references, returned hierarchy, and editor undo
  ownership/order; retain parser metadata in structured scene read/write round trips.
- Enforce real-path containment, bound wave-generation work, serialize file
  operations, detect observed edit conflicts, and protect project initialization.
- Repair generated UI references/empty functions/zero values, movement templates,
  and navigation readiness checks.
- Repair executable-symlink startup, reconnect lifecycle, graceful shutdown,
  runtime wait deadlines, standard output/error ingestion, and incremental logs.
- Update Vitest and transitive Hono to patched versions.

### Changed

- The live bridge now requires private per-project pairing credentials. Update
  both the server and copied addon, then restart the plugin; unpaired legacy
  clients are intentionally rejected.
- Runtime console capture uses the configured log file and reports its availability.
- Project initialization requires `overwrite: true` to replace conflicting files.

### Added

- Production-handler regressions, real Godot preservation/runtime tests, CLI
  lifecycle smoke tests, and a cross-platform CI matrix.

## [0.2.0] - 2026-08-14

### Fixed

- Project initialization now copies the canonical bundled AI Bridge, including
  runtime automation support.
- Package metadata, Node.js requirements, cross-platform tests, and published
  package contents are aligned with the repository.
- Runtime dependencies are updated to patched releases.

### Added

- License and contribution documentation.
- Stateless localhost HTTP transport at `/mcp`, with 2025-era compatibility.

### Changed

- Migrated the server to the stable MCP TypeScript SDK v2 and Zod 4.
- Stdio now negotiates both 2025-era MCP and the 2026-07-28 protocol.
- Tool schemas are registered natively through Standard Schema instead of a
  hand-written JSON Schema converter.

## [0.1.0]

- Initial Godot MCP server release.
