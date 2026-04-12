# Parameterized Nested Workflows

Input defaults, template resolution in config fields, and caller overrides.

## Overview

Three changes to make nested workflows fully parameterized:

1. **`WorkflowInput.defaultValue`** — declare defaults once on inputs instead of repeating `| default:` in every template reference
2. **`Resolvable<T>`** — config fields like `timeout_seconds`, `agent`, `on_failure`, `workspace` accept template strings alongside literal values
3. **Caller validation** — engine validates that parent provides all required inputs before launching a child workflow

## 1. `Resolvable<T>` Type (Template Module)

A value that is either already resolved to a typed literal, or contains a raw template string needing resolution.

```swift
enum Resolvable<T: Sendable>: Sendable, Equatable where T: Equatable {
    case literal(T)
    case template(String)
}
```

Resolution uses a protocol for type conversion from the resolved string:

```swift
protocol ResolvableConvertible {
    static func fromResolved(_ string: String) throws -> Self
}
```

Built-in conformances: `Int`, `Bool`, `String`, `WorkspaceMode`, `FailureStrategy`. Each throws `TemplateError.invalidConversion` on failure.

`TemplateResolver` gains:

```swift
func resolve<T: ResolvableConvertible>(
    _ resolvable: Resolvable<T>,
    context: TaskContext
) throws -> T
```

- `.literal(let value)` — returns value directly
- `.template(let raw)` — resolves the template string, then calls `T.fromResolved()`

## 2. `WorkflowInput` Default Field

```swift
struct WorkflowInput: Sendable, Equatable, Codable {
    let name: String
    let type: String        // "string" or "file"
    let required: Bool      // default true
    let defaultValue: String?  // new — raw template string, CodingKeys maps to "default"
}
```

YAML:

```yaml
input:
  - name: timeout
    type: string
    required: false
    default: "60"
  - name: output_dir
    required: false
    default: "{{repo_root}}/output"
```

Defaults are template strings — resolved against the context available at workflow start (builtins + caller-provided inputs).

## 3. Updated Node Model

Fields that become `Resolvable`:

```swift
struct Node: Sendable, Equatable, Codable {
    // Unchanged — already strings resolved at execution time
    let id: String
    let prompt: String?
    let command: String?
    let dependsOn: [String]           // structural, needed for DAG
    let output: String?               // alias, needed for DAG planning
    let when: String?                 // already template-resolved
    let workflow: String?             // file path needed at parse time
    let inputs: [String: String]?     // already template-resolved at dispatch

    // Now Resolvable
    let agent: Resolvable<String>?
    let timeoutSeconds: Resolvable<Int>?
    let onFailure: Resolvable<FailureStrategy>
    let workspaceMode: Resolvable<WorkspaceMode>?

    let loop: LoopConfig?
    let interactive: InteractiveMode?
    let retry: RetryConfig?
}

struct LoopConfig: Sendable, Equatable, Codable {
    let until: String                    // evaluator name — stays literal
    let maxIterations: Resolvable<Int>
    let freshContext: Resolvable<Bool>
}

struct RetryConfig: Sendable, Equatable, Codable {
    let maxAttempts: Resolvable<Int>
    let delaySeconds: Resolvable<Int>
}
```

Fields that stay literal: `id`, `dependsOn`, `output` (alias), `workflow` path, `until` — these are structural and needed at parse/planning time before any context exists.

## 4. Parser Changes

For each `Resolvable` field, the parser accepts either the typed literal or a string:

```swift
func mapResolvableInt(_ dict: [String: Any], key: String) throws -> Resolvable<Int>? {
    guard let raw = dict[key] else { return nil }
    if let intVal = raw as? Int {
        return .literal(intVal)
    } else if let strVal = raw as? String {
        return .template(strVal)
    } else {
        throw ParserError.invalidFieldType(node: nodeId, field: key, expected: "Int or template string")
    }
}
```

Similar helpers for `mapResolvableBool`, `mapResolvableString`, `mapResolvableEnum<T: RawRepresentable>`.

Static template validation scans `Resolvable.template` values in addition to existing prompt/command/when fields.

`WorkflowParser.mapWorkflow()` reads `default` from input dicts as optional string.

## 5. Engine Resolution + Execution

### Node resolution

Before executing any node, the engine resolves all `Resolvable` fields:

```swift
func resolveNode(_ node: Node, context: TaskContext) throws -> ResolvedNodeConfig {
    ResolvedNodeConfig(
        agent: try node.agent.map { try templateResolver.resolve($0, context: context) },
        timeoutSeconds: try node.timeoutSeconds.map { try templateResolver.resolve($0, context: context) },
        onFailure: try templateResolver.resolve(node.onFailure, context: context),
        workspaceMode: try node.workspaceMode.map { try templateResolver.resolve($0, context: context) },
        loop: try node.loop.map { try resolveLoopConfig($0, context: context) },
        retry: try node.retry.map { try resolveRetryConfig($0, context: context) }
    )
}
```

`ResolvedNodeConfig` is a short-lived internal struct used within `NodeDispatcher` during execution.

### Default merging

At workflow execution start, before any node runs:

1. Start with caller-provided inputs
2. For each `workflow.input` with a `defaultValue`: if input not already provided, resolve the default template string and insert into `context.inputs`
3. For each `workflow.input` where `required && no default && not provided`: throw `EngineError.missingRequiredInput`

### Caller validation for nested workflows

In `executeNestedWorkflow()`, after parsing child and resolving parent's `inputs:` map:

1. For each child `workflow.input` where `required && no defaultValue && key not in childInputs`: throw `EngineError.missingRequiredInput(name:, workflow:)`
2. Proceed — child's own default merging fills in the rest

### New error cases

- `EngineError.missingRequiredInput(name: String, workflow: String)`
- `EngineError.invalidConfigValue(node: String, field: String, value: String, expected: String)`

## 6. YAML Example

```yaml
name: parameterized-build
description: Build with configurable agent and timeout
input:
  - name: agent_name
    required: false
    default: claude-code
  - name: timeout
    required: false
    default: "60"
  - name: spec_file
    type: file
    required: true

nodes:
  - id: build
    agent: "{{agent_name}}"
    prompt: "Build the project per {{spec_file}}"
    timeout_seconds: "{{timeout}}"
    on_failure: "{{failure_mode | default: stop}}"
    retry:
      max_attempts: 3
      delay_seconds: "{{delay | default: 5}}"
```

## 7. Testing Strategy

### Template module (`Orc/Core/Template/Tests/`)

- `ResolvableTests`: `.literal` passthrough, `.template` resolution with inputs, default filter fallback, missing variable error, invalid conversion error
- `ResolvableConvertible` conformances: `Int`, `Bool`, `String`, `WorkspaceMode`, `FailureStrategy`

### Parser module (`Orc/Core/Parser/Tests/`)

- `WorkflowInput` parsing with `default` field present, absent, and as template string
- `Resolvable` field parsing: literal int, template string, wrong type → error
- Mixed literal and template fields in same node
- Static validation catches unknown variables inside `Resolvable.template` values
- Backward compatibility: existing YAML parses identically

### Engine module (`Orc/Core/Engine/Tests/`)

- Default merging: provided → not overwritten; missing + default → filled; missing + required + no default → error
- Caller validation: parent provides required → ok; parent omits required → early error with workflow name
- Node resolution: all `Resolvable` fields resolve from context
- `invalidConfigValue` error on unconvertible value
- End-to-end nested workflow with overrides and defaults

### Backward compatibility

All existing YAML files parse and execute identically. No defaults = all `.literal` values. Existing tests pass without modification.
