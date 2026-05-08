# Packaging Workflows

Workflows often span multiple files: a YAML definition, the prompts it references, and any sub-workflows it composes. The `orc pack` and `orc install` commands bundle a workflow plus its dependencies into a single, sharable archive.

## Format

A workflow package is a zip archive with the `.orc-workflow` extension:

```
<workflow>.orc-workflow
├── manifest.yaml          # metadata + file index
└── files/                 # mirrors the project's .orc/ subtree
    ├── workflows/...
    └── prompts/...
```

`manifest.yaml` records the package name, version, optional description and author, the entrypoint workflow, and every file shipped:

```yaml
name: self-improve
version: 1.0.0
description: ...
author: Sleiman
entrypoint: workflows/self-improve.yaml
files:
  - workflows/self-improve.yaml
  - prompts/codebase-summary.md
  - workflows/implement-task.yaml
  - ...
```

## Packing

```sh
orc pack <workflow> [--output PATH] [--package-version V] [--author NAME] [--include PATH ...]
```

`<workflow>` accepts the same forms as `orc start` and `orc validate` — a bare workflow name (resolved under `.orc/workflows/`) or a path to a YAML file.

The packer:

1. Validates the entrypoint workflow.
2. Walks the workflow's nodes and follows two kinds of references:
   - `prompt_file:` values starting with `{{orc_root}}/` or `.orc/`
   - `workflow:` values starting with `{{orc_root}}/` or `.orc/` (recursively, so sub-workflows pull in their own prompts and sub-workflows too)
3. Writes `manifest.yaml` with the discovered file list, then zips everything.

If a referenced file is missing or the entrypoint fails validation, the pack errors out instead of producing a broken package.

## Auto-discovery limits

The packer only follows references in **typed YAML fields** (`prompt_file:`, `workflow:`). It cannot read shell command bodies, so files referenced indirectly — for example, a `command:` block that does `cat {{orc_root}}/data/seed.json` — are *not* discovered.

For those files, list them explicitly with `--include` (paths are relative to `.orc/`):

```sh
orc pack self-improve --include self-improve/ideas-backlog.md
```

`--include` can be repeated.

## Installing

```sh
orc install <archive>.orc-workflow [--force]
```

The installer:

1. Extracts the archive to a temporary directory.
2. Decodes and validates `manifest.yaml`. Paths that try to escape the package (`..`, absolute paths) are rejected.
3. Verifies every file listed in the manifest is present in the archive.
4. **Pre-flight collision check**: if any target file already exists in the project's `.orc/`, install aborts with a list of the conflicts. The project is left untouched.
5. With `--force`: existing files are replaced.

Each installed file is reported as `added:` or `replaced:`.

## Workflow

Typical iteration loop while authoring a shareable package:

```sh
# Edit your workflow + prompts
$EDITOR .orc/workflows/my-workflow.yaml

# Repack — overwrites dist/<name>.orc-workflow
bash Scripts/pack.sh my-workflow --version 0.2.0

# Install into another project to test
cd ../other-project
orc install ../Orc/dist/my-workflow.orc-workflow --force
```

## See also

- `orc help workflows` — workflow YAML schema
- `orc help nested-workflows` — how `workflow:` references resolve
- `orc help templates` — `{{orc_root}}` and other built-in variables
