<!-- Improved compatibility of back to top link: See: https://github.com/othneildrew/Best-README-Template/pull/73 -->
<a id="readme-top"></a>

<!-- PROJECT SHIELDS -->
<!--
*** I'm using markdown "reference style" links for readability.
*** Reference links are enclosed in brackets [ ] instead of parentheses ( ).
*** See the bottom of this document for the declaration of the reference variables
*** for contributors-url, forks-url, etc. This is an optional, concise syntax you may use.
*** https://www.markdownguide.org/basic-syntax/#reference-style-links

[![Contributors][contributors-shield]][contributors-url]
[![Forks][forks-shield]][forks-url]
[![Stargazers][stars-shield]][stars-url]
[![Issues][issues-shield]][issues-url]
[![MIT License][license-shield]][license-url]
-->

<!-- PROJECT LOGO -->
<br />
<div align="center">
  <a href="https://github.com/sleimanzublidi/orc">
    <img src="logo.svg" alt="Logo" height="80">
  </a>

<h3 align="center">Orc</h3>

  <p align="center">
    A Swift CLI for orchestrating AI agents running tasks. Define workflows in YAML, execute them as dependency graphs with automatic parallelization, and persist state in a local SQLite database.
    <br />
    <br />
    <a href="https://github.com/sleimanzublidi/orc/issues/new?labels=bug&template=bug-report---.md">Report Bug</a>
    &middot;
    <a href="https://github.com/sleimanzublidi/orc/issues/new?labels=enhancement&template=feature-request---.md">Request Feature</a>
  </p>
</div>

<!-- TABLE OF CONTENTS -->
<details>
  <summary>Table of Contents</summary>
  <ol>
    <li>
      <a href="#about-the-project">About The Project</a>
      <ul>
        <li><a href="#built-with">Built With</a></li>
      </ul>
    </li>
    <li>
      <a href="#getting-started">Getting Started</a>
      <ul>
        <li><a href="#prerequisites">Prerequisites</a></li>
        <li><a href="#installation">Installation</a></li>
      </ul>
    </li>
    <li><a href="#usage">Usage</a></li>
    <li><a href="#roadmap">Roadmap</a></li>
    <li><a href="#contributing">Contributing</a></li>
    <li><a href="#license">License</a></li>
    <li><a href="#contact">Contact</a></li>
    <li><a href="#acknowledgments">Acknowledgments</a></li>
  </ol>
</details>

<!-- ABOUT THE PROJECT -->
## About The Project

Orc is an open-source CLI that orchestrates AI agents through YAML-defined workflows. Each workflow follows a functional model (input → task → output) and is executed as a directed acyclic graph with automatic parallelization.

Key capabilities:

* **YAML-defined workflows** — declarative nodes with typed inputs, template variables (`{{variable}}`), and output mappings
* **Automatic parallelization** — nodes execute concurrently based on their dependency graph
* **Loop execution** — nodes can repeat with configurable evaluators (AI, script, or workflow-based) to determine completion
* **Conditional branching** — `when:` guards enable branching paths that converge downstream
* **Interactive nodes** — two modes: `session` (tmux-based terminal sessions) and `prompt` (pause for user input)
* **Nested workflows** — compose workflows by referencing child workflow files, with shared or isolated workspaces
* **Pluggable agents** — built-in `claude-code` and `shell` providers, plus custom CLI agents via configuration
* **SQLite persistence** — all run state, node executions, and stats stored locally with WAL mode for concurrent access
* **Resume from failure** — restart failed runs from the point of failure, skipping completed nodes
* **Workspace management** — per-run workspaces with configurable cleanup policies

The engine library (OrcEngine) is the single source of truth — the CLI is a thin client over it. This architecture ensures a future local web server can be built as another thin client over the same library.

<p align="right">(<a href="#readme-top">back to top</a>)</p>

### Built With

* [![Swift][Swift-badge]][Swift-url]
* [![SQLite][SQLite-badge]][SQLite-url]

<p align="right">(<a href="#readme-top">back to top</a>)</p>

<!-- GETTING STARTED -->
## Getting Started

### Prerequisites

* macOS (arm64 or x86_64) or Linux (x86_64 or arm64)
* Swift toolchain (5.9+)
* tmux (only required for interactive session nodes)

**Linux only:**

```sh
sudo apt-get install libsqlite3-dev libicu-dev
```

`libsqlite3-dev` is required by GRDB and `libicu-dev` is required by Foundation for date/string operations.

### Installation

#### Build from source

1. Clone the repo

   ```sh
   git clone https://github.com/sleimanzublidi/orc.git
   ```

2. Build the CLI

   ```sh
   cd Orc/CLI
   swift build -c release
   ```

#### Homebrew (planned)

```sh
brew tap <owner>/orc && brew install orc
```

#### Release archive

Download from [GitHub Releases](https://github.com/sleimanzublidi/orc/releases):

```
orc-v1.0.0-macos-arm64.zip
├── bin/orc
└── workflows/
    ├── code-review.yml
    ├── implement-feature.yml
    └── ...
```

### Initialize a project

```sh
orc init
```

Creates a `.orc/` directory with config, SQLite database (WAL mode), evaluator definitions, and built-in workflow templates.

<p align="right">(<a href="#readme-top">back to top</a>)</p>

<!-- USAGE EXAMPLES -->
## Usage

### Define a workflow

```yaml
name: "implement-feature"
description: "Plan and implement a feature"
input:
  - name: repo_path
    type: string
    required: true
  - name: feature_description
    type: string
    required: true

nodes:
  - id: plan
    agent: claude-code
    prompt: "Explore {{repo_path}} and create a plan for: {{feature_description}}"
    output: plan_file

  - id: implement
    agent: claude-code
    depends_on: [plan]
    loop:
      prompt: "Read {{plan_file}}. Implement the next incomplete task. Run validation."
      until: all_tasks_complete
      max_iterations: 20
      fresh_context: true

  - id: review
    agent: claude-code
    depends_on: [implement]
    interactive: session
    prompt: "Present the changes in {{repo_path}} for review."

output:
  summary: "{{review.output}}"
```

### Run a workflow

```sh
orc start workflow.yml --input repo_path=. --input feature_description="add auth"
```

### Monitor and interact

```sh
orc list                              # list all runs
orc status <run-id>                   # show run progress
orc attach <run-id> <node-id>         # attach to interactive session
orc respond <run-id> <node-id> <text> # respond to a prompt node
orc logs <run-id> --node <node-id>    # view logs
```

### Manage runs

```sh
orc resume <run-id>                   # resume a failed/cancelled run
orc cancel <run-id>                   # cancel a running workflow
orc cleanup <run-id>                  # remove workspace for a finished run
orc purge --older-than 30d            # delete old runs (preserves stats)
orc stats                             # view historical run statistics
```

### Custom agents

Any CLI tool can be used as a provider:

```yaml
# .orc/config.yml
providers:
  codex:
    type: cli-agent
    command: "codex -q '{{prompt}}'"
    interactive_command: "codex"
  aider:
    type: cli-agent
    command: "aider --message '{{prompt}}'"
    interactive_command: "aider"
```

Reference in workflows with `agent: codex` or `agent: aider`.

### Error handling

Per-node retry, timeout, and failure strategies:

```yaml
- id: deploy
  agent: shell
  command: "deploy.sh"
  retry:
    max_attempts: 3
    delay_seconds: 5
  timeout_seconds: 300
  on_failure: stop    # stop (default), skip, or continue
```

Configuration precedence: CLI flags > workflow YAML > `.orc/config.yml` > built-in defaults.

<p align="right">(<a href="#readme-top">back to top</a>)</p>

<!-- ROADMAP -->
## Roadmap

* [x] Core engine (DAG resolver, executor, loop handler)
* [x] YAML parser and validation
* [x] SQLite persistence and workspace management
* [x] Built-in providers (`claude-code`, `shell`)
* [x] Custom CLI agent support
* [x] Interactive nodes (session and prompt modes)
* [x] Nested workflow support
* [x] `{{repo_root}}` built-in variable (absolute path to the repository root, distinct from `{{workspace}}`)
* [x] Parameterized nested workflows (input defaults, template resolution in config fields, and caller overrides)
* [x] Agent-level output streaming, when running from terminal users don't know what's happening on agents
* [x] Local web server for browser-based monitoring
* [x] Linux support (Implemented but not validated)
* [ ] Git worktree isolation — `orc start --worktree` to run workflows in a temporary worktree, keeping the working tree clean

See the [open issues](https://github.com/sleimanzublidi/orc/issues) for a full list of proposed features (and known issues).

<p align="right">(<a href="#readme-top">back to top</a>)</p>

<!-- CONTRIBUTING -->
## Contributing

Contributions are what make the open source community such an amazing place to learn, inspire, and create. Any contributions you make are **greatly appreciated**.

If you have a suggestion that would make this better, please fork the repo and create a pull request. You can also simply open an issue with the tag "enhancement".
Don't forget to give the project a star! Thanks again!

1. Fork the Project
2. Create your Feature Branch (`git checkout -b feature/AmazingFeature`)
3. Commit your Changes (`git commit -m 'Add some AmazingFeature'`)
4. Push to the Branch (`git push origin feature/AmazingFeature`)
5. Open a Pull Request

<p align="right">(<a href="#readme-top">back to top</a>)</p>

### Top contributors

<a href="https://github.com/sleimanzublidi/orc/graphs/contributors">
  <img src="https://contrib.rocks/image?repo=sleimanzublidi/orc" alt="contrib.rocks image" />
</a>

<!-- LICENSE -->
## License

Distributed under the MIT License. See `LICENSE.txt` for more information.

<p align="right">(<a href="#readme-top">back to top</a>)</p>

<!-- ACKNOWLEDGMENTS -->
## Acknowledgments

* [Best-README-Template](https://github.com/othneildrew/Best-README-Template)

<p align="right">(<a href="#readme-top">back to top</a>)</p>

<!-- MARKDOWN LINKS & IMAGES -->
<!-- https://www.markdownguide.org/basic-syntax/#reference-style-links -->
[Swift-badge]: https://img.shields.io/badge/Swift-F05138?style=for-the-badge&logo=swift&logoColor=white
[Swift-url]: https://swift.org/
[SQLite-badge]: https://img.shields.io/badge/SQLite-003B57?style=for-the-badge&logo=sqlite&logoColor=white
[SQLite-url]: https://www.sqlite.org/
