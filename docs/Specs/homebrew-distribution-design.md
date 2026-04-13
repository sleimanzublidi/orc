# Homebrew Distribution for Orc

## Goal

Enable `brew tap sleimanzublidi/orc && brew install orc` by adding a Homebrew formula to this repo and a tag-triggered GitHub Actions workflow that builds, tests, and publishes releases.

## Deliverables

1. **GitHub Actions release workflow** (`.github/workflows/release.yml`) — triggered by `v*` tags, builds all platforms, runs tests, creates a GitHub Release, and updates the formula.
2. **Homebrew formula** (`Formula/orc.rb`) — installs the pre-built universal macOS binary by default, with a `head` fallback that builds from source.
3. **Updated README** — replace the placeholder install instructions with the real commands.

## Release Workflow

### Trigger

Push a tag matching `v*` (e.g., `v1.0.0`).

The workflow extracts the semver from the tag and validates it matches the version in `OrcInfo.swift`. A mismatch fails the workflow.

### Jobs

| Job | Runner | Depends On | Steps |
|-----|--------|------------|-------|
| `test` | `macos-15` | — | Checkout, `swift test` (in `Orc/`), `build.sh`, `validate.sh` |
| `build-macos` | `macos-15` | `test` | `build.sh release`, upload universal zip as artifact |
| `build-linux-x86_64` | `ubuntu-latest` | `test` | `build-linux.sh release` for x86_64, upload zip as artifact |
| `build-linux-arm64` | `ubuntu-24.04-arm` | `test` | `build-linux.sh release` for arm64, upload zip as artifact |
| `release` | `ubuntu-latest` | all build jobs | Download artifacts, create GitHub Release, attach all zips |
| `update-formula` | `ubuntu-latest` | `release` | Download macOS zip, compute SHA-256, update `Formula/orc.rb` with new version + hash, commit and push to `main` |

### Artifact naming

Existing scripts already produce these names:
- macOS: `release-orc-cli-universal-<VERSION>.zip`
- Linux: `orc-cli-<VERSION>-linux-<ARCH>.zip`

These are attached to the GitHub Release as-is.

### Permissions

- The `release` job uses the default `GITHUB_TOKEN` with `contents: write` to create the GitHub Release.
- The `update-formula` job uses the default `GITHUB_TOKEN` with `contents: write` to push the formula update commit to `main`.

No additional secrets or personal access tokens are required since the formula lives in the same repo.

### Version validation

The workflow parses the tag (e.g., `v1.0.0` → `1.0.0`) and greps `OrcInfo.swift` for the version string. If they don't match, the workflow fails immediately before any builds run. This prevents releasing a binary whose embedded version doesn't match the tag.

## Homebrew Formula

Located at `Formula/orc.rb` in the repo root.

### Install path (pre-built binary)

For tagged releases, the formula downloads the universal macOS zip from the GitHub Release and installs the binary to `bin/orc`.

```ruby
class Orc < Formula
  desc "CLI for orchestrating AI agents via YAML-defined workflows"
  homepage "https://github.com/sleimanzublidi/orc"
  license "MIT"
  version "1.0.0"

  url "https://github.com/sleimanzublidi/orc/releases/download/v#{version}/release-orc-cli-universal-#{version}.zip"
  sha256 "<computed-by-workflow>"

  depends_on :macos

  def install
    bin.install "orc-cli-#{version}/bin/orc"
  end

  test do
    assert_match version.to_s, shell_output("#{bin}/orc version")
    assert_match "USAGE:", shell_output("#{bin}/orc help")
  end
end
```

### Head install (build from source)

Users can install the latest `main` with `brew install --HEAD orc`. This requires Xcode (Swift toolchain) on the user's machine.

The formula's `head` block clones the repo and builds a universal release binary using `swift build` inside the `Orc/` subdirectory.

### Formula update automation

The `update-formula` job in the release workflow:

1. Checks out `main`
2. Downloads the macOS release zip and computes its SHA-256
3. Uses `sed` to update `version`, `url`, and `sha256` in `Formula/orc.rb`
4. Commits with message `Formula: orc <version>` and pushes to `main`

## User Experience

```sh
# First-time install
brew tap sleimanzublidi/orc
brew install orc

# Upgrade after a new release
brew update && brew upgrade orc

# Install latest main (build from source)
brew install --HEAD sleimanzublidi/orc/orc
```

## Release Process (developer side)

1. Update version in `OrcInfo.swift` if needed
2. Commit the version bump
3. Tag and push: `git tag v1.0.0 && git push origin v1.0.0`
4. The workflow handles everything else: test, build, release, formula update

## Changes to This Repo

| What | Where | Type |
|------|-------|------|
| Release workflow | `.github/workflows/release.yml` | New file |
| Homebrew formula | `Formula/orc.rb` | New file |
| README install instructions | `README.md` | Edit |

## Out of Scope

- Submitting to homebrew-core (the official Homebrew repo). This can be done later once the project has more users/visibility. For now, a personal tap is appropriate.
- Cask distribution (Orc is a CLI, not a GUI app).
- Windows builds.
