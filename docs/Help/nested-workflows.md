# Nested Workflows

A node can execute an entire child workflow, enabling composition and reuse of workflow definitions.

## Syntax

```yaml
- id: deploy
  workflow: workflows/deploy.yaml
  depends_on: [build, test]
  inputs:
    environment: "staging"
    artifact_path: "{{build.output}}"
  output: deploy_result
```

| Field | Type | Required | Description |
|-------|------|----------|-------------|
| `workflow` | string | yes | Path to the child workflow YAML file |
| `inputs` | map | yes | Input mapping; values are template strings resolved against the parent context |
| `output` | string | no | Alias for the child workflow's output |
| `workspace` | string | no | `"shared"` (default) or `"isolated"` |

## Workspace Modes

**`shared`** -- The child workflow uses the same workspace directory as the parent. Useful when the child needs access to files created by earlier nodes.

**`isolated`** -- The child gets its own workspace at `<parent-workspace>/nested/<node-id>/`. Prevents file conflicts between parent and child.

```yaml
- id: child
  workflow: workflows/child.yaml
  workspace: isolated
  inputs:
    source: "{{workspace}}/src"
```

## How It Works

1. The engine parses the child workflow YAML.
2. The `inputs` map is resolved using the parent's current context (template variables, node outputs, etc.).
3. The child workflow's DAG is planned and executed as a self-contained run.
4. The child's final output becomes the parent node's output.
5. If the child workflow fails, the parent node fails.

## Failure and Retry

The parent node's `retry` and `on_failure` settings apply to the nested workflow as a whole:

```yaml
- id: deploy
  workflow: workflows/deploy.yaml
  inputs:
    env: "staging"
  retry:
    max_attempts: 2
    delay_seconds: 10
  on_failure: skip
```

A retry re-runs the entire child workflow from scratch.

## Example: Multi-Stage Pipeline

```yaml
name: pipeline
description: Build, test, and deploy with nested workflows

input:
  - name: target_env

nodes:
  - id: build
    workflow: workflows/build.yaml
    inputs:
      config: "release"
    output: build_artifact

  - id: test
    workflow: workflows/test.yaml
    depends_on: build
    workspace: isolated
    inputs:
      artifact: "{{build_artifact}}"

  - id: deploy
    workflow: workflows/deploy.yaml
    depends_on: test
    inputs:
      artifact: "{{build_artifact}}"
      environment: "{{target_env}}"
```

## Monitoring

Child runs are tracked in the database. Use `orc status <runID>` to see node states for both parent and child executions.
