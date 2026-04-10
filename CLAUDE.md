# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project

Orc is a Swift CLI for orchestrating AI agents via YAML-defined workflows. Workflows execute as directed acyclic graphs with automatic parallelization, and state is persisted in a local SQLite database.

**Status:** Active development.

## Build & Test

```sh
swift build                         # Debug build
swift build -c release              # Release build
swift test                          # Run all tests
swift test --filter <TestName>      # Run a single test
```

Formatting (once `.swift-format` exists at package root):
```sh
swift-format format --in-place --recursive .
swift-format lint --recursive .
```

## Architecture

Monorepo with 6 SPM library targets + 1 executable. The CLI library holds all command logic; the `orc` executable is a thin `@main` entry point. Dependency flow is strictly top-down:

```
orc (executable, @main entry point)
 └─ CLI (library, command definitions over Engine)
 └─ Engine (DAG resolver, executor, loop/interactive/resume/cancel)
     ├─ Providers (Claude Code, Shell, CLI Agent implementations)
     │   └─ Models
     ├─ Store (SQLite via GRDB, WAL mode, migrations)
     │   └─ Models
     ├─ Template ({{variable}} resolution, when: expressions)
     │   └─ Models
     └─ Parser (YAML parsing/validation via Yams)
         └─ Models
```

**Key constraint:** `OrcEngine` is the single source of truth. The CLI is a thin argument-parsing layer with zero business logic -- this allows future clients (e.g., web server) to reuse the same engine.

Each module is laid out as `<Module>/Source/` and `<Module>/Tests/`.

## Specs

Authoritative design and engineering specs live in `Docs/Specs/`:
- `orc-cli-design-spec.md` -- YAML schema, execution flow, evaluators, workspace management, error handling, SQLite schema, CLI commands
- `orc-cli-engineering-spec.md` -- Module definitions, type inventories, protocol boundaries, error types, test strategies

Always consult these specs before implementing or modifying features.

## Build Policy

- **[ALWAYS]** Fix all errors and warnings found when building — never dismiss them as "pre-existing".

## Code Conventions

- **Swift 6.3**, strict concurrency checking, macOS 14+ (arm64/x86_64)
- All `public` types must be `Sendable` -- zero warnings
- Actors for mutable shared state; structured concurrency (`TaskGroup`, `async let`) for parallelism
- Protocol-first boundaries at every layer crossing; concrete types stay `internal`
- Protocol naming: protocols end in `-ing` (e.g., `AgentProviding`); implementations are nouns
- `internal` by default; explicit `public` only on Engine API surface
- Per-module typed errors (e.g., `ParserError`, `StoreError`) -- no generic `Error` throws
- No force unwraps outside tests
- Test framework: Swift Testing (`@Test`, `#expect`)

## Dependencies

| Package | Version | Purpose |
|---------|---------|---------|
| swift-argument-parser | 1.x | CLI argument parsing |
| Yams | 5.x | YAML deserialization |
| GRDB.swift | 7.x | SQLite persistence |
| swift-log | 1.x | Structured logging |
