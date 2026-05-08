# Ideas Backlog

Last updated: 20260508

Ideas are ranked by the self-improve reviewer. Selected or completed ideas are removed; unresolved high-value ideas stay eligible for future runs.

## Scoring Guide

Each idea is scored from 1 to 5 on:
- **Value:** user-facing product impact or ability to unblock high-value user-facing work.
- **Feasibility:** confidence that the self-improve workflow can implement and validate the idea autonomously in one run.
- **Safety:** likelihood the change can be made without regressions.

The composite score is `Value x Feasibility x Safety`, with a maximum of 125.

Backlog retention rule: keep an idea only if `Value >= 3`, `Safety >= 3`, and either `Feasibility >= 3` or the idea is explicitly marked as strategic/unblocking in its notes. Remove low-value, unsafe, speculative, obsolete, duplicate, or already-implemented ideas.

## 1. Dry-Run / Execution Preview for Workflows
**Source:** product
**Value:** 5
**Feasibility:** 3
**Safety:** 5
**Status:** candidate
**Description:** Add `orc start --dry-run` or `orc plan` to parse a workflow, build the DAG, show topological execution groups, provider usage, conditional branches, loops, and template values that can be resolved before execution. Runtime-only values such as upstream node outputs should be shown as pending/unresolved placeholders rather than failing the preview.
**Rationale:** This repeatedly scored as one of the strongest remaining product ideas because it shortens the workflow authoring loop without dispatching costly AI agents.
**Notes:** Reuses the existing parser and execution planner, but needs a public engine API and CLI formatter.

## 2. Structured Output Access with `orc output`
**Source:** product
**Value:** 4
**Feasibility:** 3
**Safety:** 5
**Status:** candidate
**Description:** Add `orc output <run-id>` to display completed run outputs by node, with `--node <node-id>`, `--json`, and `--raw` modes for scripting.
**Rationale:** Workflows exist to produce reusable results, but users currently have to inspect logs and manually extract outputs.
**Notes:** The required data already exists in persisted node execution output fields; the main work is CLI parsing and formatting.

## 3. Interactive Input Prompting and Input Files
**Source:** product
**Value:** 5
**Feasibility:** 2
**Safety:** 3
**Status:** candidate
**Description:** When required workflow inputs are missing, prompt interactively for values in TTY contexts, showing input name, type, and defaults. Add `--input-file <params.yml>` as a non-interactive companion for repeated or CI runs.
**Rationale:** Missing inputs currently create a poor first-run experience. This improves onboarding and makes parameter-heavy workflows easier to run.
**Notes:** Strategic/unblocking candidate despite lower feasibility. Consider splitting into two smaller tasks: `--input-file` first, then TTY prompting.

## 4. Live Execution Visibility in the Terminal
**Source:** product
**Value:** 4
**Feasibility:** 2
**Safety:** 3
**Status:** candidate
**Description:** Improve terminal visibility for long-running workflows with some combination of DAG-level lifecycle lines during `orc start`, `orc status --watch`, and `orc logs --follow`.
**Rationale:** Long agent workflows can run for minutes with little feedback. Users need to know whether a run is progressing, blocked, or failed.
**Notes:** Strategic candidate despite lower feasibility. A narrow `status --watch` implementation may be safer than full DAG rendering or output streaming.

## 5. Guided Workflow Scaffolding with `orc new`
**Source:** product
**Value:** 4
**Feasibility:** 2
**Safety:** 5
**Status:** candidate
**Description:** Add an interactive `orc new` command that guides users through workflow name, inputs, nodes, agents, prompts or commands, dependencies, and outputs, then writes a commented YAML workflow.
**Rationale:** Orc's YAML schema is powerful but hard to learn from scratch. Scaffolding would make workflow creation approachable for new users.
**Notes:** Strategic onboarding candidate despite lower feasibility. Can start with a non-interactive `--from-template` path before a full wizard.

## 6. Actionable Error Recovery Guidance
**Source:** product
**Value:** 4
**Feasibility:** 3
**Safety:** 4
**Status:** candidate
**Description:** Add recovery hints for common failures, such as missing inputs, provider not found, failed runs, missing `.orc`, and project already initialized. Include next commands like `orc logs <id> --node <node-id>`, `orc resume <id>`, or `orc init --update`.
**Rationale:** Structured error persistence has been improved, but users still benefit from clear "what to do next" guidance at failure points.
**Notes:** Keep this focused on high-friction errors rather than broad message rewrites.

## 7. Multi-Node Workflow Template Demonstrating Core Features
**Source:** product
**Value:** 3
**Feasibility:** 5
**Safety:** 5
**Status:** candidate
**Description:** Add a bundled template that demonstrates dependencies, parallel nodes, conditionals, loops, and optional interactive nodes.
**Rationale:** Templates are the practical tutorial for new users, and current starter workflows underrepresent Orc's DAG model.
**Notes:** Keep the template small and executable; avoid adding commented examples that cannot be validated.
