<p align="center"><img src="Resources/AppIcon.png" width="128" alt="DevSweep icon"></p>

# DevSweep

A native macOS (SwiftUI, macOS 14+, Apple Silicon & Intel) cleaner for developers, modelled on CleanMyMac's layout.

## Install

```bash
brew trust --cask moovendhan-v/tap/devsweep   # Homebrew 7+: trust this one cask from the tap
brew install --cask moovendhan-v/tap/devsweep
```

Update with `brew upgrade --cask devsweep`; remove with `brew uninstall --cask devsweep` (add `--zap` to also delete its settings).

| Module | What it does |
| --- | --- |
| **Smart Care** | One-click checkup across every module, then a checklist with a single **Run** for the safe items. |
| **Dashboard** | Disk usage bar, reclaimable total, breakdown chart, biggest space users. |
| **System Junk** | App caches, browser & Electron caches, logs, unfinished downloads, old installers, Trash. |
| **Developer Caches** | Xcode, npm/yarn/pnpm/bun/deno, pip/uv/conda, Homebrew, Cargo, Go, Gradle/Maven, Docker, editors and AI tools. |
| **Project Folders** | `node_modules`, `.build`, `Pods`, `target`, `.terraform`, `.venv`, … in a folder tree with an age filter. |
| **Large & Old Files** | Files over 50 MB in your home folder (including hidden VM disks), filtered by type, size and last use. |
| **Duplicates** | Identical files matched by SHA-256 of their contents; keeps the newest copy by default. |
| **Uninstaller** | Apps with size and last use, plus their leftovers in ~/Library; also finds leftovers of apps already deleted. |
| **Performance** | Memory pressure, heavy apps (Quit), launch agents, admin maintenance tasks (purge RAM, flush DNS, reindex Spotlight). |
| **Space Lens** | Treemap or list of any folder, sorted by size, with breadcrumbs. |
| **Menu bar** | Free space at a glance, Smart Scan and shortcuts. |

## Dynamic cache discovery

Cache locations aren't only hard-coded ([Discovery.swift](Sources/DevSweep/Discovery.swift)):

1. **Ask the tools.** `npm config get cache`, `yarn cache dir`, `pnpm store path`, `deno info --json`, `pip3 cache dir`,
   `uv cache dir`, `brew --cache`, `composer config --global cache-dir`, `conda info --base`, `go env GOCACHE/GOMODCACHE`,
   `$CARGO_HOME`, `$GRADLE_USER_HOME`. Probes run from `$HOME` with a 12 s timeout and corepack downloads disabled.
2. **Ask Docker** how much it can reclaim (`docker system df`) and clean it with `docker … prune`.
3. **Scan the disk.** Every folder in `~/Library/Caches` (named after its app, with its icon), Chromium/Electron cache
   folders inside `~/Library/Application Support/*`, `~/.cache/*`, and `cache`/`logs`/`tmp` folders inside `~/.<tool>`.
4. **Classify** each one into a developer or junk group by name. Big downloads (Playwright browsers, ML models) are
   marked "Review first" and aren't pre-selected.

Anything already covered by another entry is skipped, so nothing is counted twice. Expand any row to clean individual
sub-folders (e.g. one DerivedData project).

## Safety

- Cleaning moves items to the Trash by default. Turn off "Move to Trash" to delete permanently.
- Only items marked safe are pre-selected. "Review first" items need an explicit tick.
- Give DevSweep **Full Disk Access** (System Settings › Privacy & Security) for a complete scan, including the Trash.

## Build

    ./build_app.sh                 # universal build/DevSweep.app
    ARCHS=arm64 ./build_app.sh     # faster, Apple Silicon only
    open build/DevSweep.app

The script calls `swiftc` directly (no Xcode needed), uses the newest SDK that matches the installed compiler, and
regenerates the icon from `scripts/make_icon.swift` if `Resources/AppIcon.icns` is missing.

## Release to Homebrew

One-time setup: a public repo `moovendhan-v/devsweep` (this code) and a public repo `moovendhan-v/homebrew-tap` (the cask).

    echo 1.0.1 > VERSION
    GITHUB_OWNER=moovendhan-v scripts/release.sh            # build, zip, write homebrew-tap/Casks/devsweep.rb
    GITHUB_OWNER=moovendhan-v scripts/release.sh --publish  # + GitHub release upload + push the tap

The cask template lives in `packaging/devsweep.rb.template`. Releases are ad-hoc signed, so the cask clears the
quarantine flag after install. For a smoother first launch (and to qualify for the official homebrew-cask repo),
sign with a Developer ID: `SIGN_IDENTITY="Developer ID Application: …" ./build_app.sh`, then notarize the zip with
`xcrun notarytool submit … --wait` and drop the `postflight_steps` block.
