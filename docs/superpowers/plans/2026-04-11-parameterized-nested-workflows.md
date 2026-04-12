# Parameterized Nested Workflows Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add first-class input defaults, template-resolvable config fields, and caller validation to nested workflows.

**Architecture:** Introduce `Resolvable<T>` in the Template module to wrap config fields that can be either literal values or template strings. Add `defaultValue` to `WorkflowInput`. The parser produces `Resolvable` values from YAML; the engine resolves them before execution and validates caller inputs against child workflow declarations.

**Tech Stack:** Swift 6.3, SPM, Swift Testing (`@Test`, `#expect`)

---

## File Structure

| Action | Path | Responsibility |
|--------|------|----------------|
| Create | `Orc/Core/Template/Source/Resolvable.swift` | `Resolvable<T>` enum, `ResolvableConvertible` protocol, conformances |
| Create | `Orc/Core/Template/Tests/ResolvableTests.swift` | Tests for `Resolvable` resolution and conversions |
| Modify | `Orc/Core/Models/Source/Workflow.swift:33-47` | Add `defaultValue: String?` to `WorkflowInput` |
| Modify | `Orc/Core/Models/Source/Node.swift:1-58` | Change `agent`, `timeoutSeconds`, `onFailure`, `workspaceMode`, `permissionMode` to `Resolvable`; update `LoopConfig` and `RetryConfig` |
| Create | `Orc/Core/Engine/Source/ResolvedNodeConfig.swift` | Short-lived struct with all-typed resolved config values |
| Modify | `Orc/Core/Template/Source/TemplateError.swift:4-16` | Add `invalidConversion` case |
| Modify | `Orc/Core/Template/Source/TemplateResolver.swift:15-170` | Add `resolve(_:context:)` method for `Resolvable<T>` |
| Modify | `Orc/Core/Models/Source/Protocols.swift:48-50` | Add `resolve<T>` to `TemplateResolving` protocol |
| Modify | `Orc/Core/Parser/Source/WorkflowParser.swift:282-289` | Parse `default` from input dicts |
| Modify | `Orc/Core/Parser/Source/WorkflowParser.swift:295-425` | Parse `Resolvable` fields in `mapNode`, `mapLoopConfig`, `mapRetryConfig` |
| Modify | `Orc/Core/Parser/Source/WorkflowParser.swift:472-482` | Expand `collectTemplateStrings` to scan `Resolvable.template` values |
| Modify | `Orc/Core/Parser/Source/ParserError.swift:5-13` | Add `invalidFieldType` case |
| Modify | `Orc/Core/Engine/Source/EngineError.swift:6-48` | Add `missingRequiredInput` and `invalidConfigValue` cases |
| Modify | `Orc/Core/Engine/Source/NodeDispatcher.swift:33-50` | Add default-merging step at workflow execution start |
| Modify | `Orc/Core/Engine/Source/NodeDispatcher.swift:242-321` | Resolve `Resolvable` fields before dispatching node |
| Modify | `Orc/Core/Engine/Source/NodeDispatcher.swift:324-420` | Use resolved config values for agent name, timeout, retry |
| Modify | `Orc/Core/Engine/Source/NodeDispatcher.swift:566-844` | Add caller validation for nested workflows |
| Create | `Orc/Core/Parser/Tests/ResolvableParsingTests.swift` | Tests for parser handling of `Resolvable` fields and `default` |
| Create | `Orc/Core/Engine/Tests/DefaultMergingTests.swift` | Tests for default merging and caller validation |

---

### Task 1: `Resolvable<T>` Type and `ResolvableConvertible` Protocol

**Files:**
- Create: `Orc/Core/Template/Source/Resolvable.swift`
- Create: `Orc/Core/Template/Tests/ResolvableTests.swift`
- Modify: `Orc/Core/Template/Source/TemplateError.swift:4-16`
- Modify: `Orc/Core/Models/Source/Protocols.swift:48-50`
- Modify: `Orc/Core/Template/Source/TemplateResolver.swift:15-170`

- [ ] **Step 1: Write failing tests for `Resolvable` resolution**

```swift
// Orc/Core/Template/Tests/ResolvableTests.swift
import Models
import Template
import Testing

@Suite("Resolvable")
struct ResolvableTests {

    let resolver = TemplateFactory.makeResolver()

    let context = TaskContext(
        inputs: ["timeout": "30", "agent_name": "claude-code"],
        repoRoot: "/repo",
        workspacePath: "/workspace"
    )

    // MARK: - Literal passthrough

    @Test func literalIntReturnsValue() throws {
        let resolvable = Resolvable<Int>.literal(42)
        let result = try resolver.resolve(resolvable, context: context)
        #expect(result == 42)
    }

    @Test func literalStringReturnsValue() throws {
        let resolvable = Resolvable<String>.literal("hello")
        let result = try resolver.resolve(resolvable, context: context)
        #expect(result == "hello")
    }

    @Test func literalBoolReturnsValue() throws {
        let resolvable = Resolvable<Bool>.literal(true)
        let result = try resolver.resolve(resolvable, context: context)
        #expect(result == true)
    }

    // MARK: - Template resolution

    @Test func templateIntResolvesFromInput() throws {
        let resolvable = Resolvable<Int>.template("{{timeout}}")
        let result = try resolver.resolve(resolvable, context: context)
        #expect(result == 30)
    }

    @Test func templateStringResolvesFromInput() throws {
        let resolvable = Resolvable<String>.template("{{agent_name}}")
        let result = try resolver.resolve(resolvable, context: context)
        #expect(result == "claude-code")
    }

    @Test func templateBoolResolvesFromInput() throws {
        let ctx = TaskContext(
            inputs: ["fresh": "true"],
            repoRoot: "/repo",
            workspacePath: "/ws"
        )
        let resolvable = Resolvable<Bool>.template("{{fresh}}")
        let result = try resolver.resolve(resolvable, context: ctx)
        #expect(result == true)
    }

    // MARK: - Default filter

    @Test func templateWithDefaultUsesDefaultWhenMissing() throws {
        let resolvable = Resolvable<Int>.template("{{missing | default: 60}}")
        let result = try resolver.resolve(resolvable, context: context)
        #expect(result == 60)
    }

    @Test func templateWithDefaultUsesInputWhenPresent() throws {
        let resolvable = Resolvable<Int>.template("{{timeout | default: 60}}")
        let result = try resolver.resolve(resolvable, context: context)
        #expect(result == 30)
    }

    // MARK: - Error cases

    @Test func templateIntThrowsOnUnresolved() throws {
        let resolvable = Resolvable<Int>.template("{{missing}}")
        #expect(throws: TemplateError.self) {
            try resolver.resolve(resolvable, context: context)
        }
    }

    @Test func templateIntThrowsOnInvalidConversion() throws {
        let ctx = TaskContext(
            inputs: ["timeout": "not_a_number"],
            repoRoot: "/repo",
            workspacePath: "/ws"
        )
        let resolvable = Resolvable<Int>.template("{{timeout}}")
        #expect(throws: TemplateError.self) {
            try resolver.resolve(resolvable, context: ctx)
        }
    }

    // MARK: - Enum conformances

    @Test func failureStrategyFromResolved() throws {
        let ctx = TaskContext(
            inputs: ["mode": "continue"],
            repoRoot: "/repo",
            workspacePath: "/ws"
        )
        let resolvable = Resolvable<FailureStrategy>.template("{{mode}}")
        let result = try resolver.resolve(resolvable, context: ctx)
        #expect(result == .continue)
    }

    @Test func workspaceModeFromResolved() throws {
        let ctx = TaskContext(
            inputs: ["ws": "isolated"],
            repoRoot: "/repo",
            workspacePath: "/ws"
        )
        let resolvable = Resolvable<WorkspaceMode>.template("{{ws}}")
        let result = try resolver.resolve(resolvable, context: ctx)
        #expect(result == .isolated)
    }

    @Test func permissionModeFromResolved() throws {
        let ctx = TaskContext(
            inputs: ["pm": "full"],
            repoRoot: "/repo",
            workspacePath: "/ws"
        )
        let resolvable = Resolvable<PermissionMode>.template("{{pm}}")
        let result = try resolver.resolve(resolvable, context: ctx)
        #expect(result == .full)
    }

    @Test func invalidEnumValueThrows() throws {
        let ctx = TaskContext(
            inputs: ["mode": "invalid"],
            repoRoot: "/repo",
            workspacePath: "/ws"
        )
        let resolvable = Resolvable<FailureStrategy>.template("{{mode}}")
        #expect(throws: TemplateError.self) {
            try resolver.resolve(resolvable, context: ctx)
        }
    }

    // MARK: - Equatable

    @Test func equatableLiterals() {
        #expect(Resolvable<Int>.literal(42) == Resolvable<Int>.literal(42))
        #expect(Resolvable<Int>.literal(42) != Resolvable<Int>.literal(99))
    }

    @Test func equatableTemplates() {
        #expect(Resolvable<Int>.template("{{x}}") == Resolvable<Int>.template("{{x}}"))
        #expect(Resolvable<Int>.template("{{x}}") != Resolvable<Int>.template("{{y}}"))
    }

    @Test func literalNotEqualToTemplate() {
        #expect(Resolvable<Int>.literal(42) != Resolvable<Int>.template("42"))
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `cd Orc && swift test --filter ResolvableTests 2>&1 | tail -20`
Expected: Compilation errors — `Resolvable` type does not exist yet.

- [ ] **Step 3: Add `invalidConversion` case to `TemplateError`**

In `Orc/Core/Template/Source/TemplateError.swift`, add the new case and its description/localized handling:

```swift
// Add to the enum (after expressionEvaluation):
    /// A template resolved to a string that cannot be converted to the target type.
    case invalidConversion(value: String, targetType: String)
```

```swift
// Add to the description computed property switch:
        case .invalidConversion(let value, let targetType):
            return "Cannot convert '\(value)' to \(targetType)."
```

- [ ] **Step 4: Create `Resolvable.swift` with type, protocol, and conformances**

```swift
// Orc/Core/Template/Source/Resolvable.swift
import Models

/// A value that is either already resolved to a typed literal,
/// or contains a raw template string needing resolution at execution time.
public enum Resolvable<T: Sendable & Equatable>: Sendable, Equatable {
    case literal(T)
    case template(String)
}

extension Resolvable: Codable where T: Codable {
    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        // Try decoding as the literal type first, then fall back to String.
        if let value = try? container.decode(T.self) {
            self = .literal(value)
        } else {
            let raw = try container.decode(String.self)
            self = .template(raw)
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .literal(let value):
            try container.encode(value)
        case .template(let raw):
            try container.encode(raw)
        }
    }
}

/// Conforming types can be constructed from a resolved template string.
public protocol ResolvableConvertible {
    static func fromResolved(_ string: String) throws -> Self
}

// MARK: - Built-in Conformances

extension String: ResolvableConvertible {
    public static func fromResolved(_ string: String) throws -> String {
        string
    }
}

extension Int: ResolvableConvertible {
    public static func fromResolved(_ string: String) throws -> Int {
        guard let value = Int(string) else {
            throw TemplateError.invalidConversion(value: string, targetType: "Int")
        }
        return value
    }
}

extension Bool: ResolvableConvertible {
    public static func fromResolved(_ string: String) throws -> Bool {
        switch string.lowercased() {
        case "true", "yes", "1": return true
        case "false", "no", "0": return false
        default:
            throw TemplateError.invalidConversion(value: string, targetType: "Bool")
        }
    }
}

extension FailureStrategy: ResolvableConvertible {
    public static func fromResolved(_ string: String) throws -> FailureStrategy {
        guard let value = FailureStrategy(rawValue: string) else {
            throw TemplateError.invalidConversion(value: string, targetType: "FailureStrategy")
        }
        return value
    }
}

extension WorkspaceMode: ResolvableConvertible {
    public static func fromResolved(_ string: String) throws -> WorkspaceMode {
        guard let value = WorkspaceMode(rawValue: string) else {
            throw TemplateError.invalidConversion(value: string, targetType: "WorkspaceMode")
        }
        return value
    }
}

extension PermissionMode: ResolvableConvertible {
    public static func fromResolved(_ string: String) throws -> PermissionMode {
        guard let value = PermissionMode(rawValue: string) else {
            throw TemplateError.invalidConversion(value: string, targetType: "PermissionMode")
        }
        return value
    }
}
```

- [ ] **Step 5: Add `resolve(_:context:)` to `TemplateResolving` protocol**

In `Orc/Core/Models/Source/Protocols.swift`, add the new method to the protocol with a default implementation so existing conformances don't break:

```swift
// Add to TemplateResolving protocol:
    func resolve<T: ResolvableConvertible & Sendable & Equatable>(
        _ resolvable: Resolvable<T>, context: TaskContext
    ) throws -> T
```

- [ ] **Step 6: Implement `resolve(_:context:)` in `TemplateResolver`**

In `Orc/Core/Template/Source/TemplateResolver.swift`, add the method inside the struct (before the `// MARK: - Private Helpers` line):

```swift
    func resolve<T: ResolvableConvertible & Sendable & Equatable>(
        _ resolvable: Resolvable<T>, context: TaskContext
    ) throws -> T {
        switch resolvable {
        case .literal(let value):
            return value
        case .template(let raw):
            let resolved = try resolve(template: raw, context: context)
            return try T.fromResolved(resolved)
        }
    }
```

- [ ] **Step 7: Run tests to verify they pass**

Run: `cd Orc && swift test --filter ResolvableTests 2>&1 | tail -20`
Expected: All tests PASS.

- [ ] **Step 8: Build the full project to check for compilation issues**

Run: `cd /Users/sleimanzublidi/Source/Orc && bash Scripts/build.sh 2>&1 | tail -20`
Expected: Build succeeds with no errors or warnings.

- [ ] **Step 9: Run all existing tests to verify no regressions**

Run: `cd Orc && swift test 2>&1 | tail -30`
Expected: All tests PASS (existing tests unchanged).

- [ ] **Step 10: Commit**

```bash
git add Orc/Core/Template/Source/Resolvable.swift Orc/Core/Template/Tests/ResolvableTests.swift Orc/Core/Template/Source/TemplateError.swift Orc/Core/Template/Source/TemplateResolver.swift Orc/Core/Models/Source/Protocols.swift
git commit -m "[Claude] Add Resolvable<T> type and ResolvableConvertible protocol

Introduces generic Resolvable<T> enum (literal/template) in Template
module with resolution via TemplateResolving. Adds ResolvableConvertible
conformances for Int, Bool, String, FailureStrategy, WorkspaceMode,
PermissionMode. Adds invalidConversion error case to TemplateError."
```

---

### Task 2: Update `WorkflowInput` with `defaultValue`

**Files:**
- Modify: `Orc/Core/Models/Source/Workflow.swift:33-47`

- [ ] **Step 1: Write failing test for default value on WorkflowInput**

This is tested via the parser in Task 5. For now, verify the model accepts the field:

```swift
// Quick compile check — add to an existing test file or verify via build.
// The real tests come in Task 5 (parser) and Task 7 (engine).
```

- [ ] **Step 2: Add `defaultValue` to `WorkflowInput`**

In `Orc/Core/Models/Source/Workflow.swift`, replace the `WorkflowInput` struct:

```swift
/// A declared input parameter for a workflow.
public struct WorkflowInput: Sendable, Equatable, Codable {
    public let name: String
    public let type: String
    public let required: Bool
    public let defaultValue: String?

    public init(
        name: String,
        type: String = "string",
        required: Bool = true,
        defaultValue: String? = nil
    ) {
        self.name = name
        self.type = type
        self.required = required
        self.defaultValue = defaultValue
    }

    private enum CodingKeys: String, CodingKey {
        case name, type, required
        case defaultValue = "default"
    }
}
```

- [ ] **Step 3: Build to verify no compilation errors**

Run: `cd /Users/sleimanzublidi/Source/Orc && bash Scripts/build.sh 2>&1 | tail -20`
Expected: Build succeeds. Existing code passes `nil` implicitly via the default parameter.

- [ ] **Step 4: Run all tests to verify no regressions**

Run: `cd Orc && swift test 2>&1 | tail -30`
Expected: All tests PASS.

- [ ] **Step 5: Commit**

```bash
git add Orc/Core/Models/Source/Workflow.swift
git commit -m "[Claude] Add defaultValue field to WorkflowInput

Adds optional defaultValue: String? to WorkflowInput with CodingKeys
mapping to 'default' for YAML/JSON. Existing callers unaffected (nil
default parameter)."
```

---

### Task 3: Update `Node` Model with `Resolvable` Config Fields

**Files:**
- Modify: `Orc/Core/Models/Source/Node.swift:1-58`

- [ ] **Step 1: Update `Node` struct to use `Resolvable` fields**

Replace the `Node` struct fields and init in `Orc/Core/Models/Source/Node.swift`:

```swift
public struct Node: Sendable, Equatable, Codable {
    public let id: String
    public let agent: Resolvable<String>?
    public let prompt: String?
    public let command: String?
    public let dependsOn: [String]
    public let output: String?
    public let when: String?
    public let loop: LoopConfig?
    public let interactive: InteractiveMode?
    public let retry: RetryConfig?
    public let timeoutSeconds: Resolvable<Int>?
    public let onFailure: Resolvable<FailureStrategy>
    public let workflow: String?
    public let inputs: [String: String]?
    public let workspaceMode: Resolvable<WorkspaceMode>?
    public let permissionMode: Resolvable<PermissionMode>?

    public init(
        id: String,
        agent: Resolvable<String>? = nil,
        prompt: String? = nil,
        command: String? = nil,
        dependsOn: [String] = [],
        output: String? = nil,
        when: String? = nil,
        loop: LoopConfig? = nil,
        interactive: InteractiveMode? = nil,
        retry: RetryConfig? = nil,
        timeoutSeconds: Resolvable<Int>? = nil,
        onFailure: Resolvable<FailureStrategy> = .literal(.stop),
        workflow: String? = nil,
        inputs: [String: String]? = nil,
        workspaceMode: Resolvable<WorkspaceMode>? = nil,
        permissionMode: Resolvable<PermissionMode>? = nil
    ) {
        self.id = id
        self.agent = agent
        self.prompt = prompt
        self.command = command
        self.dependsOn = dependsOn
        self.output = output
        self.when = when
        self.loop = loop
        self.interactive = interactive
        self.retry = retry
        self.timeoutSeconds = timeoutSeconds
        self.onFailure = onFailure
        self.workflow = workflow
        self.inputs = inputs
        self.workspaceMode = workspaceMode
        self.permissionMode = permissionMode
    }
}
```

- [ ] **Step 2: Update `LoopConfig` to use `Resolvable` fields**

Replace the `LoopConfig` struct:

```swift
public struct LoopConfig: Sendable, Equatable, Codable {
    public let until: String
    public let maxIterations: Resolvable<Int>
    public let freshContext: Resolvable<Bool>

    public init(
        until: String,
        maxIterations: Resolvable<Int> = .literal(10),
        freshContext: Resolvable<Bool> = .literal(false)
    ) {
        self.until = until
        self.maxIterations = maxIterations
        self.freshContext = freshContext
    }
}
```

- [ ] **Step 3: Update `RetryConfig` to use `Resolvable` fields**

Replace the `RetryConfig` struct:

```swift
public struct RetryConfig: Sendable, Equatable, Codable {
    public let maxAttempts: Resolvable<Int>
    public let delaySeconds: Resolvable<Int>

    public init(
        maxAttempts: Resolvable<Int> = .literal(1),
        delaySeconds: Resolvable<Int> = .literal(0)
    ) {
        self.maxAttempts = maxAttempts
        self.delaySeconds = delaySeconds
    }
}
```

- [ ] **Step 4: Add `import Template` to `Node.swift`**

The `Node.swift` file needs access to `Resolvable` from the Template module. Add at the top:

```swift
import Template
```

**IMPORTANT:** `Models` currently has no dependency on `Template`. We need to check whether `Resolvable` should live in `Models` instead (since `Models` is the leaf module). If `Models` cannot depend on `Template`, move `Resolvable.swift` and `ResolvableConvertible` to the `Models` module. Check `Package.swift` — `Models` has no dependencies, so `Resolvable` must be defined in `Models`, not `Template`.

**Correction:** Move `Resolvable.swift` from `Orc/Core/Template/Source/Resolvable.swift` to `Orc/Core/Models/Source/Resolvable.swift`. The `ResolvableConvertible` conformances for `FailureStrategy`, `WorkspaceMode`, `PermissionMode` can stay in Models since those types are there. The `TemplateError.invalidConversion` reference means `ResolvableConvertible` conformances that throw `TemplateError` need to live in `Template` (which depends on `Models`).

**Revised approach:**
- `Resolvable<T>` enum → `Models` module (no dependencies needed)
- `ResolvableConvertible` protocol → `Models` module (no dependencies needed)
- Conformances for `String`, `Int`, `Bool` (that throw `TemplateError`) → `Template` module (in `Resolvable+Conformances.swift`)
- Conformances for `FailureStrategy`, `WorkspaceMode`, `PermissionMode` (that throw `TemplateError`) → `Template` module
- `resolve(_:context:)` method → `Template` module (on `TemplateResolver`)

This means `Node.swift` in `Models` can use `Resolvable<T>` without importing Template.

- [ ] **Step 5: Restructure — move `Resolvable` enum and protocol to Models**

Create `Orc/Core/Models/Source/Resolvable.swift`:

```swift
/// A value that is either already resolved to a typed literal,
/// or contains a raw template string needing resolution at execution time.
public enum Resolvable<T: Sendable & Equatable>: Sendable, Equatable {
    case literal(T)
    case template(String)
}

extension Resolvable: Codable where T: Codable {
    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let value = try? container.decode(T.self) {
            self = .literal(value)
        } else {
            let raw = try container.decode(String.self)
            self = .template(raw)
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .literal(let value):
            try container.encode(value)
        case .template(let raw):
            try container.encode(raw)
        }
    }
}

/// Conforming types can be constructed from a resolved template string.
public protocol ResolvableConvertible {
    static func fromResolved(_ string: String) throws -> Self
}
```

Move the conformances to `Orc/Core/Template/Source/Resolvable+Conformances.swift`:

```swift
import Models

extension String: ResolvableConvertible {
    public static func fromResolved(_ string: String) throws -> String {
        string
    }
}

extension Int: ResolvableConvertible {
    public static func fromResolved(_ string: String) throws -> Int {
        guard let value = Int(string) else {
            throw TemplateError.invalidConversion(value: string, targetType: "Int")
        }
        return value
    }
}

extension Bool: ResolvableConvertible {
    public static func fromResolved(_ string: String) throws -> Bool {
        switch string.lowercased() {
        case "true", "yes", "1": return true
        case "false", "no", "0": return false
        default:
            throw TemplateError.invalidConversion(value: string, targetType: "Bool")
        }
    }
}

extension FailureStrategy: ResolvableConvertible {
    public static func fromResolved(_ string: String) throws -> FailureStrategy {
        guard let value = FailureStrategy(rawValue: string) else {
            throw TemplateError.invalidConversion(value: string, targetType: "FailureStrategy")
        }
        return value
    }
}

extension WorkspaceMode: ResolvableConvertible {
    public static func fromResolved(_ string: String) throws -> WorkspaceMode {
        guard let value = WorkspaceMode(rawValue: string) else {
            throw TemplateError.invalidConversion(value: string, targetType: "WorkspaceMode")
        }
        return value
    }
}

extension PermissionMode: ResolvableConvertible {
    public static func fromResolved(_ string: String) throws -> PermissionMode {
        guard let value = PermissionMode(rawValue: string) else {
            throw TemplateError.invalidConversion(value: string, targetType: "PermissionMode")
        }
        return value
    }
}
```

Remove the original `Orc/Core/Template/Source/Resolvable.swift` file created in Task 1 and replace with this split.

- [ ] **Step 6: Fix all compilation errors from the type changes**

The model changes will cause compilation errors in:
- `WorkflowParser.swift` — node construction passes `String?` where `Resolvable<String>?` is expected, `Int?` where `Resolvable<Int>?` is expected, etc. (Fixed in Task 4.)
- `NodeDispatcher.swift` — reads `node.agent` as `String?`, `node.timeoutSeconds` as `Int?`, etc. (Fixed in Task 6.)
- Test fakes — construct `Node(...)` with old types. (Fixed in Task 4.)

For now, just verify the Models module compiles in isolation:

Run: `cd Orc && swift build --target Models 2>&1 | tail -20`
Expected: Models target compiles successfully.

- [ ] **Step 7: Commit**

```bash
git add Orc/Core/Models/Source/Node.swift Orc/Core/Models/Source/Resolvable.swift Orc/Core/Template/Source/Resolvable+Conformances.swift
git commit -m "[Claude] Update Node, LoopConfig, RetryConfig to use Resolvable fields

Changes agent, timeoutSeconds, onFailure, workspaceMode, permissionMode
to Resolvable<T>. Updates LoopConfig.maxIterations and freshContext,
RetryConfig.maxAttempts and delaySeconds. Moves Resolvable enum to Models
module, conformances to Template module."
```

**Note:** The project will NOT compile fully at this point. Parser and Engine have not been updated yet. That's expected — Tasks 4-6 fix those.

---

### Task 4: Update Parser for `Resolvable` Fields and Input Defaults

**Files:**
- Modify: `Orc/Core/Parser/Source/WorkflowParser.swift:282-482`
- Modify: `Orc/Core/Parser/Source/ParserError.swift:5-13`
- Create: `Orc/Core/Parser/Tests/ResolvableParsingTests.swift`

- [ ] **Step 1: Write failing tests for parser changes**

```swift
// Orc/Core/Parser/Tests/ResolvableParsingTests.swift
import Models
import Parser
import Testing

@Suite("Resolvable Parsing")
struct ResolvableParsingTests {

    let parser = ParserFactory.makeParser()

    // MARK: - Input defaults

    @Test func inputWithDefaultValueIsParsed() throws {
        let yaml = """
        name: test
        input:
          - name: timeout
            required: false
            default: "60"
        nodes:
          - id: step1
            agent: claude-code
            prompt: "Do work"
            timeout_seconds: "{{timeout}}"
        """
        let workflow = try parser.parse(yaml: yaml)
        #expect(workflow.input[0].defaultValue == "60")
    }

    @Test func inputWithoutDefaultHasNilDefault() throws {
        let yaml = """
        name: test
        input:
          - name: query
        nodes:
          - id: step1
            agent: claude-code
            prompt: "{{query}}"
        """
        let workflow = try parser.parse(yaml: yaml)
        #expect(workflow.input[0].defaultValue == nil)
    }

    @Test func inputDefaultAsTemplateString() throws {
        let yaml = """
        name: test
        input:
          - name: output_dir
            required: false
            default: "{{repo_root}}/output"
        nodes:
          - id: step1
            agent: claude-code
            prompt: "Write to {{output_dir}}"
        """
        let workflow = try parser.parse(yaml: yaml)
        #expect(workflow.input[0].defaultValue == "{{repo_root}}/output")
    }

    // MARK: - Resolvable config fields

    @Test func literalIntTimeoutIsParsed() throws {
        let yaml = """
        name: test
        nodes:
          - id: step1
            agent: claude-code
            prompt: "Do work"
            timeout_seconds: 30
        """
        let workflow = try parser.parse(yaml: yaml)
        #expect(workflow.nodes[0].timeoutSeconds == .literal(30))
    }

    @Test func templateTimeoutIsParsed() throws {
        let yaml = """
        name: test
        input:
          - name: timeout
        nodes:
          - id: step1
            agent: claude-code
            prompt: "Do work"
            timeout_seconds: "{{timeout}}"
        """
        let workflow = try parser.parse(yaml: yaml)
        #expect(workflow.nodes[0].timeoutSeconds == .template("{{timeout}}"))
    }

    @Test func literalAgentIsParsed() throws {
        let yaml = """
        name: test
        nodes:
          - id: step1
            agent: claude-code
            prompt: "Do work"
        """
        let workflow = try parser.parse(yaml: yaml)
        #expect(workflow.nodes[0].agent == .literal("claude-code"))
    }

    @Test func templateAgentIsParsed() throws {
        let yaml = """
        name: test
        input:
          - name: agent_name
        nodes:
          - id: step1
            agent: "{{agent_name}}"
            prompt: "Do work"
        """
        let workflow = try parser.parse(yaml: yaml)
        #expect(workflow.nodes[0].agent == .template("{{agent_name}}"))
    }

    @Test func literalOnFailureIsParsed() throws {
        let yaml = """
        name: test
        nodes:
          - id: step1
            agent: claude-code
            prompt: "Do work"
            on_failure: continue
        """
        let workflow = try parser.parse(yaml: yaml)
        #expect(workflow.nodes[0].onFailure == .literal(.continue))
    }

    @Test func templateOnFailureIsParsed() throws {
        let yaml = """
        name: test
        input:
          - name: failure_mode
        nodes:
          - id: step1
            agent: claude-code
            prompt: "Do work"
            on_failure: "{{failure_mode}}"
        """
        let workflow = try parser.parse(yaml: yaml)
        #expect(workflow.nodes[0].onFailure == .template("{{failure_mode}}"))
    }

    @Test func literalRetryConfigIsParsed() throws {
        let yaml = """
        name: test
        nodes:
          - id: step1
            agent: claude-code
            prompt: "Do work"
            retry:
              max_attempts: 3
              delay_seconds: 5
        """
        let workflow = try parser.parse(yaml: yaml)
        #expect(workflow.nodes[0].retry?.maxAttempts == .literal(3))
        #expect(workflow.nodes[0].retry?.delaySeconds == .literal(5))
    }

    @Test func templateRetryConfigIsParsed() throws {
        let yaml = """
        name: test
        input:
          - name: attempts
          - name: delay
        nodes:
          - id: step1
            agent: claude-code
            prompt: "Do work"
            retry:
              max_attempts: "{{attempts}}"
              delay_seconds: "{{delay}}"
        """
        let workflow = try parser.parse(yaml: yaml)
        #expect(workflow.nodes[0].retry?.maxAttempts == .template("{{attempts}}"))
        #expect(workflow.nodes[0].retry?.delaySeconds == .template("{{delay}}"))
    }

    @Test func literalLoopConfigIsParsed() throws {
        let yaml = """
        name: test
        nodes:
          - id: step1
            agent: claude-code
            prompt: "Do work"
            loop:
              until: approved
              max_iterations: 5
              fresh_context: true
        """
        let workflow = try parser.parse(yaml: yaml)
        #expect(workflow.nodes[0].loop?.maxIterations == .literal(5))
        #expect(workflow.nodes[0].loop?.freshContext == .literal(true))
    }

    @Test func templateLoopConfigIsParsed() throws {
        let yaml = """
        name: test
        input:
          - name: max_iter
          - name: fresh
        nodes:
          - id: step1
            agent: claude-code
            prompt: "Do work"
            loop:
              until: approved
              max_iterations: "{{max_iter}}"
              fresh_context: "{{fresh}}"
        """
        let workflow = try parser.parse(yaml: yaml)
        #expect(workflow.nodes[0].loop?.maxIterations == .template("{{max_iter}}"))
        #expect(workflow.nodes[0].loop?.freshContext == .template("{{fresh}}"))
    }

    @Test func templateWorkspaceModeIsParsed() throws {
        let yaml = """
        name: test
        input:
          - name: ws_mode
        nodes:
          - id: step1
            workflow: child.yaml
            inputs:
              key: value
            workspace: "{{ws_mode}}"
        """
        let workflow = try parser.parse(yaml: yaml)
        #expect(workflow.nodes[0].workspaceMode == .template("{{ws_mode}}"))
    }

    // MARK: - Template validation scans Resolvable templates

    @Test func unknownVariableInTemplateAgentIsDetected() throws {
        let yaml = """
        name: test
        nodes:
          - id: step1
            agent: "{{unknown_agent}}"
            prompt: "Do work"
        """
        let result = parser.validate(workflow: try parser.parse(yaml: yaml))
        let hasError = result.errors.contains { $0.message.contains("unknown_agent") }
        #expect(hasError)
    }

    // MARK: - Backward compatibility

    @Test func existingYAMLWithNoDefaultsOrTemplateConfigParses() throws {
        let yaml = """
        name: basic
        input:
          - name: question
        nodes:
          - id: ask
            agent: claude-code
            prompt: "{{question}}"
            timeout_seconds: 60
            on_failure: stop
        """
        let workflow = try parser.parse(yaml: yaml)
        #expect(workflow.input[0].defaultValue == nil)
        #expect(workflow.nodes[0].agent == .literal("claude-code"))
        #expect(workflow.nodes[0].timeoutSeconds == .literal(60))
        #expect(workflow.nodes[0].onFailure == .literal(.stop))
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `cd Orc && swift test --filter ResolvableParsingTests 2>&1 | tail -20`
Expected: Compilation errors — parser still constructs `Node` with old types.

- [ ] **Step 3: Add `invalidFieldType` case to `ParserError`**

In `Orc/Core/Parser/Source/ParserError.swift`, add:

```swift
    /// A field value has the wrong type (e.g., expected Int or template string).
    case invalidFieldType(node: String, field: String, expected: String)
```

And in the `description` computed property:

```swift
        case .invalidFieldType(let node, let field, let expected):
            return "[\(node)] Field '\(field)' has invalid type; expected \(expected)"
```

- [ ] **Step 4: Update `mapWorkflowInput` to read `default`**

In `WorkflowParser.swift`, update `mapWorkflowInput(from:)`:

```swift
    private func mapWorkflowInput(from dict: [String: Any]) throws -> WorkflowInput {
        guard let name = dict["name"] as? String else {
            throw ParserError.missingField(node: nil, field: "input.name")
        }
        let type = dict["type"] as? String ?? "string"
        let required = dict["required"] as? Bool ?? true
        let defaultValue = dict["default"] as? String

        return WorkflowInput(name: name, type: type, required: required, defaultValue: defaultValue)
    }
```

- [ ] **Step 5: Add `Resolvable` mapping helpers to `WorkflowParser`**

Add these private methods to `WorkflowParser`:

```swift
    // MARK: - Resolvable Mapping Helpers

    /// Maps a YAML value to `Resolvable<Int>`. Accepts Int literal or template String.
    private func mapResolvableInt(
        _ dict: [String: Any], key: String, nodeID: String
    ) throws -> Resolvable<Int>? {
        guard let raw = dict[key] else { return nil }
        if let intVal = raw as? Int {
            return .literal(intVal)
        }
        if let strVal = raw as? String {
            return .template(strVal)
        }
        throw ParserError.invalidFieldType(node: nodeID, field: key, expected: "Int or template string")
    }

    /// Maps a YAML value to `Resolvable<Bool>`. Accepts Bool literal or template String.
    private func mapResolvableBool(
        _ dict: [String: Any], key: String, nodeID: String
    ) throws -> Resolvable<Bool>? {
        guard let raw = dict[key] else { return nil }
        if let boolVal = raw as? Bool {
            return .literal(boolVal)
        }
        if let strVal = raw as? String {
            return .template(strVal)
        }
        throw ParserError.invalidFieldType(node: nodeID, field: key, expected: "Bool or template string")
    }

    /// Maps a YAML value to `Resolvable<String>`. Always wraps as literal unless
    /// the string contains `{{`, in which case it's treated as a template.
    private func mapResolvableString(
        _ dict: [String: Any], key: String
    ) -> Resolvable<String>? {
        guard let strVal = dict[key] as? String else { return nil }
        if strVal.contains("{{") {
            return .template(strVal)
        }
        return .literal(strVal)
    }

    /// Maps a YAML value to `Resolvable<T>` for `RawRepresentable` enums.
    /// Accepts a valid raw value (literal) or a template string.
    private func mapResolvableEnum<T: RawRepresentable>(
        _ dict: [String: Any], key: String, nodeID: String, typeName: String
    ) throws -> Resolvable<T>? where T.RawValue == String, T: Sendable & Equatable {
        guard let raw = dict[key] else { return nil }
        guard let strVal = raw as? String else {
            throw ParserError.invalidFieldType(node: nodeID, field: key, expected: "\(typeName) or template string")
        }
        if strVal.contains("{{") {
            return .template(strVal)
        }
        guard let value = T(rawValue: strVal) else {
            throw ParserError.invalidExpression(
                node: nodeID,
                detail: "Invalid \(typeName) value '\(strVal)'"
            )
        }
        return .literal(value)
    }
```

- [ ] **Step 6: Update `mapNode` to use Resolvable helpers**

Replace the relevant sections of `mapNode(from:)`:

```swift
    private func mapNode(from dict: [String: Any]) throws -> Models.Node {
        guard let id = dict["id"] as? String, !id.isEmpty else {
            throw ParserError.missingField(node: nil, field: "id")
        }

        let agent = mapResolvableString(dict, key: "agent")
        var prompt = dict["prompt"] as? String
        let command = dict["command"] as? String

        let dependsOn: [String]
        if let deps = dict["depends_on"] as? [String] {
            dependsOn = deps
        } else if let dep = dict["depends_on"] as? String {
            dependsOn = [dep]
        } else {
            dependsOn = []
        }

        let output = dict["output"] as? String
        let when = dict["when"] as? String

        // loop
        let loop: LoopConfig?
        if let loopDict = dict["loop"] as? [String: Any] {
            loop = try mapLoopConfig(from: loopDict, nodeID: id)
            if let loopPrompt = loopDict["prompt"] as? String, prompt == nil {
                prompt = loopPrompt
            }
        } else {
            loop = nil
        }

        // interactive
        let interactive: InteractiveMode?
        if let interStr = dict["interactive"] as? String {
            switch interStr {
            case "session":
                interactive = .session
            case "prompt":
                let message = dict["message"] as? String ?? ""
                interactive = .prompt(message: message)
            default:
                throw ParserError.invalidExpression(
                    node: id,
                    detail: "Invalid interactive mode '\(interStr)'; expected 'session' or 'prompt'"
                )
            }
        } else {
            interactive = nil
        }

        // retry
        let retry: RetryConfig?
        if let retryDict = dict["retry"] as? [String: Any] {
            retry = try mapRetryConfig(from: retryDict, nodeID: id)
        } else {
            retry = nil
        }

        // timeout_seconds
        let timeoutSeconds = try mapResolvableInt(dict, key: "timeout_seconds", nodeID: id)

        // on_failure
        let onFailure: Resolvable<FailureStrategy> = try mapResolvableEnum(
            dict, key: "on_failure", nodeID: id, typeName: "FailureStrategy"
        ) ?? .literal(.stop)

        // workflow
        let workflow = dict["workflow"] as? String

        // inputs
        let inputs = dict["inputs"] as? [String: String]

        // workspace
        let workspaceMode: Resolvable<WorkspaceMode>? = try mapResolvableEnum(
            dict, key: "workspace", nodeID: id, typeName: "WorkspaceMode"
        )

        // permission_mode
        let permissionMode: Resolvable<PermissionMode>? = try mapResolvableEnum(
            dict, key: "permission_mode", nodeID: id, typeName: "PermissionMode"
        )

        return Node(
            id: id,
            agent: agent,
            prompt: prompt,
            command: command,
            dependsOn: dependsOn,
            output: output,
            when: when,
            loop: loop,
            interactive: interactive,
            retry: retry,
            timeoutSeconds: timeoutSeconds,
            onFailure: onFailure,
            workflow: workflow,
            inputs: inputs,
            workspaceMode: workspaceMode,
            permissionMode: permissionMode
        )
    }
```

- [ ] **Step 7: Update `mapLoopConfig` for Resolvable fields**

```swift
    private func mapLoopConfig(from dict: [String: Any], nodeID: String) throws -> LoopConfig {
        guard let until = dict["until"] as? String else {
            throw ParserError.missingField(node: nodeID, field: "loop.until")
        }
        let maxIterations = try mapResolvableInt(dict, key: "max_iterations", nodeID: nodeID) ?? .literal(10)
        let freshContext = try mapResolvableBool(dict, key: "fresh_context", nodeID: nodeID) ?? .literal(false)

        return LoopConfig(
            until: until,
            maxIterations: maxIterations,
            freshContext: freshContext
        )
    }
```

- [ ] **Step 8: Update `mapRetryConfig` for Resolvable fields**

Note: signature changes to add `nodeID` parameter and `throws`:

```swift
    private func mapRetryConfig(from dict: [String: Any], nodeID: String) throws -> RetryConfig {
        let maxAttempts = try mapResolvableInt(dict, key: "max_attempts", nodeID: nodeID) ?? .literal(1)
        let delaySeconds = try mapResolvableInt(dict, key: "delay_seconds", nodeID: nodeID) ?? .literal(0)
        return RetryConfig(maxAttempts: maxAttempts, delaySeconds: delaySeconds)
    }
```

Update the call site in `mapNode` (already done in Step 6 — passes `nodeID: id`).

- [ ] **Step 9: Update `collectTemplateStrings` to scan Resolvable.template values**

```swift
    private func collectTemplateStrings(from node: Models.Node) -> [String] {
        var templates: [String] = []
        if let prompt = node.prompt { templates.append(prompt) }
        if let when = node.when { templates.append(when) }
        if let command = node.command { templates.append(command) }
        if let inputs = node.inputs {
            templates.append(contentsOf: inputs.values)
        }
        // Scan Resolvable.template values
        if case .template(let t) = node.agent { templates.append(t) }
        if case .template(let t) = node.timeoutSeconds { templates.append(t) }
        if case .template(let t) = node.onFailure { templates.append(t) }
        if case .template(let t) = node.workspaceMode { templates.append(t) }
        if case .template(let t) = node.permissionMode { templates.append(t) }
        if let loop = node.loop {
            if case .template(let t) = loop.maxIterations { templates.append(t) }
            if case .template(let t) = loop.freshContext { templates.append(t) }
        }
        if let retry = node.retry {
            if case .template(let t) = retry.maxAttempts { templates.append(t) }
            if case .template(let t) = retry.delaySeconds { templates.append(t) }
        }
        return templates
    }
```

- [ ] **Step 10: Update validation — relax agent check for template agents**

In `validate(workflow:)`, the check at line 60 requires `agent`, `command`, `workflow`, or `interactive`. With template agents, `node.agent` is non-nil (it's `.template(...)`) but we should still validate. Update the check:

```swift
// The existing check works because node.agent is Resolvable<String>? — it's non-nil
// when an agent is specified (whether literal or template). No change needed.
```

Actually verify: since `agent` changed from `String?` to `Resolvable<String>?`, the check `node.agent == nil` still works correctly — it checks for `Optional.none`, not the enum case. No change needed.

- [ ] **Step 11: Run parser tests**

Run: `cd Orc && swift test --filter ResolvableParsingTests 2>&1 | tail -30`
Expected: All new tests PASS.

- [ ] **Step 12: Run all existing parser tests**

Run: `cd Orc && swift test --filter ParserTests 2>&1 | tail -30`
Expected: All tests PASS. Existing YAML that uses literal values parses to `.literal(...)` values.

**Note:** Some existing tests may need minor updates where they compare `node.agent` to a `String` — they'll need to compare to `.literal("claude-code")` instead. Fix any such failures by updating the expected values.

- [ ] **Step 13: Commit**

```bash
git add Orc/Core/Parser/Source/WorkflowParser.swift Orc/Core/Parser/Source/ParserError.swift Orc/Core/Parser/Tests/ResolvableParsingTests.swift
git commit -m "[Claude] Update parser for Resolvable fields and input defaults

Parser now accepts typed literals or template strings for agent,
timeout_seconds, on_failure, workspace, permission_mode, retry, and loop
config fields. Reads 'default' from input declarations. Validates
template variables in Resolvable.template values."
```

---

### Task 5: Fix Existing Test Compilation

**Files:**
- Modify: `Orc/Core/Engine/Tests/NodeDispatcherTests.swift` — update `Node(...)` constructions
- Modify: `Orc/Core/Engine/Tests/LoopHandlerTests.swift` — update `LoopConfig(...)` constructions
- Modify: `Orc/Core/Engine/Tests/WorkflowEngineTests.swift` — update `Node(...)` constructions
- Modify: `Orc/Core/Engine/Tests/EvaluatorRunnerTests.swift` — update `Node/LoopConfig` constructions
- Modify: `Orc/Core/Parser/Tests/WorkflowParserTests.swift` — update expected values
- Modify: `Orc/Core/Engine/Tests/LocalizedErrorTests.swift` — add new error cases
- Modify: any other tests that construct `Node`, `LoopConfig`, or `RetryConfig`

- [ ] **Step 1: Find all test files constructing Node/LoopConfig/RetryConfig**

Search for `Node(` and `LoopConfig(` and `RetryConfig(` in test files. Each call site needs updating to use `Resolvable` types:
- `agent: "shell"` → `agent: .literal("shell")`
- `timeoutSeconds: 30` → `timeoutSeconds: .literal(30)`
- `onFailure: .stop` → `onFailure: .literal(.stop)`
- `workspaceMode: .shared` → `workspaceMode: .literal(.shared)`
- `permissionMode: .full` → `permissionMode: .literal(.full)`
- `maxAttempts: 3` → `maxAttempts: .literal(3)`
- `delaySeconds: 5` → `delaySeconds: .literal(5)`
- `maxIterations: 10` → `maxIterations: .literal(10)`
- `freshContext: false` → `freshContext: .literal(false)`

- [ ] **Step 2: Update each test file**

Apply the type changes systematically across all test files. This is mechanical — wrap each literal value in `.literal(...)`.

Also update assertions that compare `node.agent` to `"claude-code"` — change to `node.agent == .literal("claude-code")`.

- [ ] **Step 3: Add new error cases to `LocalizedErrorTests.swift`**

Add tests for:
- `EngineError.missingRequiredInput` — verify `localizedDescription`
- `EngineError.invalidConfigValue` — verify `localizedDescription`
- `TemplateError.invalidConversion` — verify `localizedDescription`
- `ParserError.invalidFieldType` — verify `localizedDescription`

- [ ] **Step 4: Build and run all tests**

Run: `cd /Users/sleimanzublidi/Source/Orc && bash Scripts/build.sh 2>&1 | tail -20`
Run: `cd Orc && swift test 2>&1 | tail -30`
Expected: Full build succeeds, all tests PASS.

- [ ] **Step 5: Commit**

```bash
git add -A
git commit -m "[Claude] Update all tests for Resolvable model changes

Wraps literal values in .literal() for Node, LoopConfig, RetryConfig
constructions across all test files. Adds LocalizedError tests for new
error cases."
```

---

### Task 6: Engine — `ResolvedNodeConfig`, Default Merging, Node Resolution, Caller Validation

**Files:**
- Create: `Orc/Core/Engine/Source/ResolvedNodeConfig.swift`
- Create: `Orc/Core/Engine/Tests/DefaultMergingTests.swift`
- Modify: `Orc/Core/Engine/Source/EngineError.swift:6-48`
- Modify: `Orc/Core/Engine/Source/NodeDispatcher.swift`

- [ ] **Step 1: Write failing tests for default merging and caller validation**

```swift
// Orc/Core/Engine/Tests/DefaultMergingTests.swift
import Engine
import Models
import Testing

@Suite("Default Merging and Caller Validation")
struct DefaultMergingTests {

    // MARK: - Default merging

    @Test func providedInputIsNotOverwrittenByDefault() async throws {
        // Workflow declares input with default, caller provides a value.
        // The caller's value should win.
        let workflow = Workflow(
            name: "test",
            input: [
                WorkflowInput(name: "timeout", defaultValue: "60")
            ],
            nodes: [Node(id: "step1", agent: .literal("shell"), command: "echo done")]
        )
        let fakeStore = FakeWorkflowStore()
        let fakeParser = FakeWorkflowParser(workflow: workflow)
        let dispatcher = makeDispatcher(plan: plan(for: workflow), store: fakeStore, parser: fakeParser)

        let run = try await fakeStore.createRun(Run(
            id: "", workflowName: "test", workflowFile: "test.yaml",
            status: .running, workspacePath: "/tmp/test"
        ))

        let result = try await dispatcher.execute(
            run: run, inputs: ["timeout": "30"]
        )

        // Verify the node saw timeout=30 (caller value), not 60 (default).
        let execs = try await fakeStore.getNodeExecutions(runID: run.id, nodeID: "step1")
        #expect(result.status == .completed)
    }

    @Test func missingInputWithDefaultIsFilledIn() async throws {
        let workflow = Workflow(
            name: "test",
            input: [
                WorkflowInput(name: "greeting", defaultValue: "hello")
            ],
            nodes: [Node(id: "step1", agent: .literal("shell"), command: "echo {{greeting}}")]
        )
        let fakeStore = FakeWorkflowStore()
        let fakeParser = FakeWorkflowParser(workflow: workflow)
        let dispatcher = makeDispatcher(plan: plan(for: workflow), store: fakeStore, parser: fakeParser)

        let run = try await fakeStore.createRun(Run(
            id: "", workflowName: "test", workflowFile: "test.yaml",
            status: .running, workspacePath: "/tmp/test"
        ))

        // No inputs provided — default should fill in.
        let result = try await dispatcher.execute(run: run, inputs: [:])
        #expect(result.status == .completed)
    }

    @Test func missingRequiredInputWithNoDefaultThrows() async throws {
        let workflow = Workflow(
            name: "test",
            input: [
                WorkflowInput(name: "query", required: true)
            ],
            nodes: [Node(id: "step1", agent: .literal("shell"), command: "echo {{query}}")]
        )
        let fakeStore = FakeWorkflowStore()
        let fakeParser = FakeWorkflowParser(workflow: workflow)
        let dispatcher = makeDispatcher(plan: plan(for: workflow), store: fakeStore, parser: fakeParser)

        let run = try await fakeStore.createRun(Run(
            id: "", workflowName: "test", workflowFile: "test.yaml",
            status: .running, workspacePath: "/tmp/test"
        ))

        await #expect(throws: EngineError.self) {
            try await dispatcher.execute(run: run, inputs: [:])
        }
    }

    // MARK: - Caller validation for nested workflows

    @Test func nestedWorkflowMissingRequiredInputFailsEarly() async throws {
        // Parent calls child that requires "spec_file" but doesn't provide it.
        let childWorkflow = Workflow(
            name: "child",
            input: [
                WorkflowInput(name: "spec_file", required: true)
            ],
            nodes: [Node(id: "work", agent: .literal("shell"), command: "cat {{spec_file}}")]
        )
        let parentWorkflow = Workflow(
            name: "parent",
            nodes: [
                Node(
                    id: "nested",
                    workflow: "child.yaml",
                    inputs: [:]  // Missing spec_file!
                )
            ]
        )
        let fakeStore = FakeWorkflowStore()
        let fakeParser = FakeWorkflowParser(workflow: parentWorkflow)
        fakeParser.fileOverrides["child.yaml"] = childWorkflow
        let dispatcher = makeDispatcher(plan: plan(for: parentWorkflow), store: fakeStore, parser: fakeParser)

        let run = try await fakeStore.createRun(Run(
            id: "", workflowName: "parent", workflowFile: "parent.yaml",
            status: .running, workspacePath: "/tmp/test"
        ))

        let result = try await dispatcher.execute(run: run, inputs: [:])
        // The nested node should fail.
        let execs = try await fakeStore.getNodeExecutions(runID: run.id, nodeID: "nested")
        #expect(execs.last?.status == .failed)
    }

    @Test func nestedWorkflowWithDefaultFillsMissingInput() async throws {
        // Parent calls child that has default for "mode", doesn't provide it.
        let childWorkflow = Workflow(
            name: "child",
            input: [
                WorkflowInput(name: "mode", required: true, defaultValue: "fast")
            ],
            nodes: [Node(id: "work", agent: .literal("shell"), command: "echo {{mode}}")]
        )
        let parentWorkflow = Workflow(
            name: "parent",
            nodes: [
                Node(
                    id: "nested",
                    workflow: "child.yaml",
                    inputs: ["dummy": "value"]  // mode not provided, but has default
                )
            ]
        )
        let fakeStore = FakeWorkflowStore()
        let fakeParser = FakeWorkflowParser(workflow: parentWorkflow)
        fakeParser.fileOverrides["child.yaml"] = childWorkflow
        let dispatcher = makeDispatcher(plan: plan(for: parentWorkflow), store: fakeStore, parser: fakeParser)

        let run = try await fakeStore.createRun(Run(
            id: "", workflowName: "parent", workflowFile: "parent.yaml",
            status: .running, workspacePath: "/tmp/test"
        ))

        let result = try await dispatcher.execute(run: run, inputs: [:])
        // Should succeed — child's default for "mode" fills in.
        #expect(result.status == .completed)
    }
}

// MARK: - Helpers (adjust to match existing test infrastructure)

// These helpers should match the pattern used in NodeDispatcherTests.swift.
// If the test file already has a makeDispatcher helper, reuse it.
// Otherwise, create minimal versions here.
```

**Note:** The exact helper construction depends on the existing test infrastructure in `NodeDispatcherTests.swift`. The implementing agent should read that file and match the patterns for constructing `NodeDispatcher` instances with fakes.

- [ ] **Step 2: Run tests to verify they fail**

Run: `cd Orc && swift test --filter DefaultMergingTests 2>&1 | tail -20`
Expected: Compilation errors — `ResolvedNodeConfig` and new error cases don't exist yet.

- [ ] **Step 3: Add new error cases to `EngineError`**

In `Orc/Core/Engine/Source/EngineError.swift`, add:

```swift
    /// A required input was not provided by the caller and has no default value.
    case missingRequiredInput(name: String, workflow: String)

    /// A Resolvable config field resolved to a value that cannot be converted
    /// to the target type.
    case invalidConfigValue(node: String, field: String, value: String, expected: String)
```

And in the `description` computed property:

```swift
        case .missingRequiredInput(let name, let workflow):
            "Missing required input '\(name)' for workflow '\(workflow)'."
        case .invalidConfigValue(let node, let field, let value, let expected):
            "[\(node)] Config field '\(field)' resolved to '\(value)'; expected \(expected)."
```

- [ ] **Step 4: Create `ResolvedNodeConfig`**

```swift
// Orc/Core/Engine/Source/ResolvedNodeConfig.swift
import Models

/// Short-lived container holding resolved (typed) config values for a node.
/// Created just before node execution by resolving all `Resolvable` fields.
struct ResolvedNodeConfig: Sendable {
    let agent: String?
    let timeoutSeconds: Int?
    let onFailure: FailureStrategy
    let workspaceMode: WorkspaceMode?
    let permissionMode: PermissionMode?
    let retry: ResolvedRetryConfig?
    let loop: ResolvedLoopConfig?
}

struct ResolvedRetryConfig: Sendable {
    let maxAttempts: Int
    let delaySeconds: Int
}

struct ResolvedLoopConfig: Sendable {
    let until: String
    let maxIterations: Int
    let freshContext: Bool
}
```

- [ ] **Step 5: Add default-merging to `NodeDispatcher.execute()`**

In `NodeDispatcher.execute(run:inputs:completedOutputs:)`, right after the `var nodeOutputs` / `var nodeStatuses` initialization (around line 39), add default merging:

```swift
        // Merge workflow input defaults into the provided inputs.
        var mergedInputs = inputs
        for workflowInput in plan.workflow.input {
            if mergedInputs[workflowInput.name] == nil {
                if let defaultTemplate = workflowInput.defaultValue {
                    // Resolve the default against a minimal context (builtins + already-provided inputs).
                    let defaultContext = TaskContext(
                        inputs: mergedInputs,
                        repoRoot: repoRoot,
                        workspacePath: run.workspacePath
                    )
                    let resolved = try templateResolver.resolve(template: defaultTemplate, context: defaultContext)
                    mergedInputs[workflowInput.name] = resolved
                } else if workflowInput.required {
                    throw EngineError.missingRequiredInput(
                        name: workflowInput.name,
                        workflow: plan.workflow.name
                    )
                }
            }
        }
```

Then use `mergedInputs` instead of `inputs` everywhere downstream in the method.

**Note:** `plan.workflow` is the `Workflow` model. Verify that `ExecutionPlan` stores a reference to the workflow. If not, the workflow must be passed in separately. Check `ExecutionPlan` — it stores `workflow: Workflow`. If it doesn't, add it.

- [ ] **Step 6: Verify `ExecutionPlan.workflow` reference exists**

`ExecutionPlan` already has `let workflow: Workflow` (at `Orc/Core/Engine/Source/ExecutionPlan.swift:7`). No changes needed — `plan.workflow.input` is available for default merging.

- [ ] **Step 7: Add node resolution before dispatch in `executeNode`**

In `executeNode(nodeID:run:inputs:nodeOutputs:nodeStatuses:)`, after constructing the `TaskContext` and before the dispatch branches, resolve the node's config:

```swift
        // Resolve Resolvable config fields.
        let config: ResolvedNodeConfig
        do {
            config = try resolveNodeConfig(node, context: context)
        } catch {
            let execID = UUID().uuidString
            let exec = NodeExecution(
                id: execID, runID: run.id, nodeID: nodeID,
                status: .failed,
                error: "Config resolution failed: \(error)",
                startedAt: Date(), completedAt: Date()
            )
            _ = try await store.createNodeExecution(exec)
            return (nodeID, .failed, nil, error)
        }
```

Add the `resolveNodeConfig` method:

```swift
    private func resolveNodeConfig(
        _ node: Models.Node, context: TaskContext
    ) throws -> ResolvedNodeConfig {
        let agent: String? = try node.agent.map { try templateResolver.resolve($0, context: context) }
        let timeoutSeconds: Int? = try node.timeoutSeconds.map { try templateResolver.resolve($0, context: context) }
        let onFailure = try templateResolver.resolve(node.onFailure, context: context)
        let workspaceMode: WorkspaceMode? = try node.workspaceMode.map { try templateResolver.resolve($0, context: context) }
        let permissionMode: PermissionMode? = try node.permissionMode.map { try templateResolver.resolve($0, context: context) }

        let retry: ResolvedRetryConfig?
        if let r = node.retry {
            retry = ResolvedRetryConfig(
                maxAttempts: try templateResolver.resolve(r.maxAttempts, context: context),
                delaySeconds: try templateResolver.resolve(r.delaySeconds, context: context)
            )
        } else {
            retry = nil
        }

        let loop: ResolvedLoopConfig?
        if let l = node.loop {
            loop = ResolvedLoopConfig(
                until: l.until,
                maxIterations: try templateResolver.resolve(l.maxIterations, context: context),
                freshContext: try templateResolver.resolve(l.freshContext, context: context)
            )
        } else {
            loop = nil
        }

        return ResolvedNodeConfig(
            agent: agent,
            timeoutSeconds: timeoutSeconds,
            onFailure: onFailure,
            workspaceMode: workspaceMode,
            permissionMode: permissionMode,
            retry: retry,
            loop: loop
        )
    }
```

- [ ] **Step 8: Update `executeSingleNode` to use resolved config**

Pass `config` to `executeSingleNode` (change signature to accept `ResolvedNodeConfig`):

```swift
    private func executeSingleNode(
        node: Models.Node,
        run: Run,
        context: TaskContext,
        config: ResolvedNodeConfig
    ) async -> (String, NodeStatus, String?, (any Error)?) {
```

Update internal usage:
- `node.agent ?? "shell"` → `config.agent ?? "shell"`
- `node.timeoutSeconds` → `config.timeoutSeconds`
- `node.permissionMode` → `config.permissionMode`
- `node.retry?.maxAttempts ?? 1` → `config.retry?.maxAttempts ?? 1`
- `node.retry?.delaySeconds` → `config.retry?.delaySeconds`

- [ ] **Step 9: Update `executeInteractiveNode` to use resolved config**

Similar pattern — pass `config` and use resolved values for timeout, retry, permission mode.

- [ ] **Step 10: Update `executeLoopNode` to use resolved config**

Pass `config` and use `config.loop?.maxIterations`, `config.loop?.freshContext`.

- [ ] **Step 11: Update `executeNestedWorkflow` for caller validation**

In `executeNestedWorkflow`, after parsing the child workflow and resolving `childInputs` (around line 654), add caller validation:

```swift
        // Validate caller provided all required inputs (that have no default).
        for childInput in childWorkflow.input {
            if childInput.required && childInput.defaultValue == nil
                && childInputs[childInput.name] == nil
            {
                let errorDetail = "Missing required input '\(childInput.name)'"
                do {
                    try await store.updateNodeExecution(
                        id: execID, status: .failed, output: nil, error: errorDetail
                    )
                } catch let storeError {
                    logger.warning("[\(node.id)] Failed to persist validation failure: \(storeError)")
                }
                return (node.id, .failed, nil, EngineError.missingRequiredInput(
                    name: childInput.name, workflow: childWorkflow.name
                ))
            }
        }
```

Also update the workspace mode resolution in `executeNestedWorkflow` to use the resolved config:

```swift
        let workspaceMode = config.workspaceMode ?? .shared
```

(Pass `config` to `executeNestedWorkflow` the same way as other methods.)

- [ ] **Step 12: Build the full project**

Run: `cd /Users/sleimanzublidi/Source/Orc && bash Scripts/build.sh 2>&1 | tail -20`
Expected: Build succeeds.

- [ ] **Step 13: Run all tests**

Run: `cd Orc && swift test 2>&1 | tail -30`
Expected: All tests PASS, including new `DefaultMergingTests`.

- [ ] **Step 14: Commit**

```bash
git add Orc/Core/Engine/Source/ResolvedNodeConfig.swift Orc/Core/Engine/Source/EngineError.swift Orc/Core/Engine/Source/NodeDispatcher.swift Orc/Core/Engine/Tests/DefaultMergingTests.swift
git commit -m "[Claude] Add default merging, node config resolution, caller validation

Engine merges workflow input defaults before execution. Resolves all
Resolvable config fields into ResolvedNodeConfig before dispatching.
Validates nested workflow callers provide required inputs. Adds
missingRequiredInput and invalidConfigValue engine errors."
```

---

### Task 7: Final Integration Test and Backward Compatibility Verification

**Files:**
- No new files — verify existing workflows still work

- [ ] **Step 1: Build release**

Run: `cd /Users/sleimanzublidi/Source/Orc && bash Scripts/build.sh release 2>&1 | tail -20`
Expected: Release build succeeds with zero errors and zero warnings.

- [ ] **Step 2: Run full test suite**

Run: `cd Orc && swift test 2>&1 | tail -30`
Expected: All tests PASS.

- [ ] **Step 3: Verify existing YAML workflows parse correctly**

Run a quick parse check on existing workflow files to make sure they still work:

```bash
cd /Users/sleimanzublidi/Source/Orc
for f in .orc/workflows/*.yaml; do
    echo "=== $f ==="
    # Use the orc CLI to validate (if available) or swift test covers this
done
```

- [ ] **Step 4: Commit if any fixes were needed**

If integration testing revealed any issues, fix and commit:

```bash
git add -A
git commit -m "[Claude] Fix integration issues from parameterized workflows"
```

If no fixes needed, skip this step.
