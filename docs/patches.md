# Fork patches (`sbourass/cmux`)

The set of changes this fork carries on top of upstream `manaflow-ai/cmux`, applied
on the `sb-main` branch. Each upstream sync rebases these onto the new `v<tag>` base
(see [fork-release.md](./fork-release.md) → "Syncing with upstream"), so the commit
SHAs change every sync **but this index does not**.

This file is the human-readable source of truth for *what* the fork changes and *why*.
The live, machine-readable list is always:

```bash
git log --oneline --no-merges v<upstream-base>..sb-main
```

**Last synced upstream base:** `v0.64.22` (shipped as `v0.64.22-sb.1`)

> Maintenance: this file is updated as part of every fork release — see
> [fork-release.md](./fork-release.md) → "Shipping a release", step "Update patches.md".
> When asked to cut a fork release, Claude Code reconciles this file against
> `git log v<base>..sb-main` and re-checks each patch's **Verify** note against the
> new upstream base.

> Commit naming: fork commits use scoped subjects — `fork(patch):` for behavioral
> patches (the ones with a **Verify** step below), `fork(infra):` for fork tooling/docs.
> See [fork-release.md](./fork-release.md) → "Commit naming convention". The reword is
> applied during the upstream-sync rebase, and the `**Commit subject:**` keys below are
> updated in lockstep at that point — so they always match live `git log`.

---

## Why "behavior + verify", not just a diff

Patches can apply cleanly during a rebase and still be **silently bypassed** when
upstream refactors the surrounding code. Real example from the `v0.64.10 → v0.64.11`
sync: upstream extracted the settings UI into a new `CmuxSettingsUI` Swift package and
introduced a **second source of truth** for the telemetry default (a catalog
`DefaultsKey`), so the telemetry patch merged without conflict but the UI no longer
reflected it. The git diff looked fine; the behavior was wrong.

Therefore every patch below records the **observable behavior it must produce** and
**how to verify it**, not just the files it touches. On each sync, re-run the Verify
step — that is what actually protects the fork.

---

## Behavioral patches

These change cmux's runtime behavior versus upstream.

### 1. Per-pane shell history isolation
- **Commit subject:** `fork(patch): per-pane shell history isolation`
- **Purpose:** each terminal pane gets its own command history file
  (`~/Library/Application Support/cmux/panel-history/<uuid>.zsh_history`), keyed by a
  stable UUID stored in the session snapshot. Pressing ↑ in a pane recalls only that
  pane's commands; history survives quit/reopen. Toggleable (default ON).
- **Key code (source of truth):**
  - `Sources/App/WorkspaceRuntimeSettings.swift` — `PerPaneShellHistorySettings`
    enum (UserDefaults key `terminal.perPaneShellHistory`, default `true`).
  - `Sources/TerminalSurfaceRuntimeWiring.swift` — sets `CMUX_PANEL_HISTFILE` env per
    surface (in the terminal-surface init that merges `additionalEnvironment`), gated on
    `PerPaneShellHistorySettings.isEnabled()`.
    (Upstream extracted this out of `Sources/GhosttyTerminalView.swift` around v0.64.1x —
    re-check this path after a sync.)
  - `Packages/macOS/CmuxTerminal/Sources/CmuxTerminal/Surface/TerminalSurface.swift` —
    the `historyFileId` stored property + its `init` parameter. **Moved here in the
    v0.64.22 sync**: upstream extracted `TerminalSurface` out of the app module into the
    new `CmuxTerminal` package, so this is now a cross-package public API rather than an
    app-module property. The env-var computation deliberately stays in
    `TerminalSurfaceRuntimeWiring` because `SessionPanelHistoryStore` /
    `PerPaneShellHistorySettings` are app-layer types `CmuxTerminal` cannot import.
  - `Sources/SessionPersistence.swift` — `SessionPanelHistoryStore` (env key
    `CMUX_PANEL_HISTFILE`, `panel-history` dir, orphan sweep), `historyFileId` in the
    terminal snapshot.
  - `Sources/Workspace.swift`, `Sources/Workspace+PanelLifecycle.swift`,
    `Sources/Panels/TerminalPanel.swift`, `Sources/AppDelegate.swift` — plumb
    `historyFileId` through create/restore/close; orphan sweep at launch.
  - Shell integration: `Resources/shell-integration/cmux-zsh-integration.zsh`,
    `cmux-bash-integration.bash` — switch `HISTFILE` to `$CMUX_PANEL_HISTFILE` after rc.
  - **Settings UI** (ported into upstream's `CmuxSettingsUI` package; note the
    `Packages/macOS/` group-folder prefix):
    `Packages/macOS/CmuxSettings/.../Keys/TerminalCatalogSection.swift`
    (`perPaneShellHistory` catalog key),
    `Packages/macOS/CmuxSettingsUI/.../Sections/TerminalSection.swift` (row),
    `Packages/macOS/CmuxSettingsUI/.../Navigation/CuratedSettingEntry+Default.swift`
    (search entry),
    `Packages/macOS/CmuxSettingsUI/.../SettingsRowAnchorResolutionTests.swift` (test
    contract path), `Sources/SettingsNavigation.swift` (legacy in-app search entry).
  - `Resources/Localizable.xcstrings` — `en` + `ja` for the three row strings
    (`settings.terminal.perPaneShellHistory`, `.subtitleOn`, `.subtitleOff`). The row is
    rendered from `CmuxSettingsUI`, which has no catalog of its own, so these live in the
    app-level catalog alongside the 60-odd upstream `settings.terminal.*` keys.
  - Spec: `docs/per-pane-shell-history.md`.
- **Verify:**
  1. Settings → Terminal shows a **"Per-Pane Shell History"** toggle (after "Resume
     Agent Sessions on Reopen"), default ON.
  2. Two panes get **distinct** `$HISTFILE` paths under `panel-history/`. CLI check:
     `cmux send --surface surface:N 'echo $HISTFILE'` then `cmux read-screen …` for two
     surfaces — paths differ and end in `panel-history/<uuid>.zsh_history`.
  3. Each pane's history file contains only its own commands.
  4. Localization: the three `settings.terminal.perPaneShellHistory*` keys exist in
     `Resources/Localizable.xcstrings` with **both** `en` and `ja`, and each `en` value is
     byte-identical to the `defaultValue` in `TerminalSection.swift`. A `defaultValue`
     English fallback alone does **not** count as localized (repo policy), and the row
     silently renders English on a Japanese system if the keys go missing — no build error.
- **Rot watch:** the settings UI is the fragile part. Upstream's settings live in the
  `CmuxSettingsUI` catalog system (catalog key → `DefaultsValueModel` → `SettingsCardRow`
  + curated search entry + anchor test). If a future upstream moves/renames that, re-port
  the four settings pieces and keep `SettingsRowAnchorResolutionTests.rowConfigPaths` in
  sync (its contract test fails the build otherwise). The runtime mechanism
  (`CMUX_PANEL_HISTFILE`, shell integration) is stable — it survived upstream's near-total
  rewrite of both shell-integration scripts in v0.64.22 as a clean auto-merge, because the
  patch appends a self-removing `precmd` hook (`_cmux_history_init`) rather than editing
  upstream's existing lines. If a future sync ever drops that hook registration
  (`add-zsh-hook precmd _cmux_history_init`), `HISTFILE` silently falls back to the shared
  global with no compile error — grep for it explicitly.

### 2. Default anonymous telemetry to off
- **Commit subject:** `fork(patch): default anonymous telemetry to off`
- **Purpose:** fresh installs are opt-in (telemetry off) rather than opt-out. Existing
  users keep their stored preference (the default is only consulted when the
  `sendAnonymousTelemetry` key is unset).
- **Key code (source of truth — a SINGLE catalog-backed default as of v0.64.20):**
  - `Packages/macOS/CmuxSettings/Sources/CmuxSettings/Keys/AppCatalogSection.swift` —
    catalog key `app.sendAnonymousTelemetry` `defaultValue: false` (UserDefaults key
    `sendAnonymousTelemetry`). This is the fork's only behavioral change (upstream ships
    `true`).
  - `Sources/cmuxApp.swift` — `TelemetrySettings.enabledForCurrentLaunch =
    AppCatalogSection().sendAnonymousTelemetry.value(in: .standard)`. **Reads the catalog
    key directly**, so it and the Settings UI toggle both flow from the single catalog
    default above. This drives the send gate used by `SentryHelper`, `PostHogAnalytics`,
    `AppDelegate`, `GhosttyTerminalView`.
  - `cmuxTests/GhosttyConfigTests.swift` — `testTelemetryDefaultsToDisabledWhenUnset`
    (asserts `false` when the key is unset).
- **Verify:**
  1. With the key unset (`defaults read <bundle-id> sendAnonymousTelemetry` → "does not
     exist"), the Settings telemetry toggle shows **OFF**.
  2. Actual sending is gated off: `TelemetrySettings.enabledForCurrentLaunch` is `false`
     when unset (used by `SentryHelper`, `PostHogAnalytics`, `AppDelegate`).
- **Rot watch:** upstream v0.64.11 split this into two defaults (a `TelemetrySettings` enum
  default *and* the catalog `DefaultsKey`); v0.64.20 re-consolidated to the **single**
  catalog `defaultValue` (`enabledForCurrentLaunch` now reads the catalog directly). Keep
  the catalog `defaultValue` at `false`. If a future sync re-introduces a separate enum/const
  default or a third reader that does **not** go through `AppCatalogSection().sendAnonymousTelemetry`,
  set that one to `false` too — this is the patch that has silently regressed on a refactor before.
  v0.64.22 added two **new** readers and both route correctly through the catalog key, so they
  inherit the fork's `false` with no extra patching:
  `Sources/CommandPalette/CommandPaletteSettingsToggle.swift` (a Command Palette telemetry
  toggle) and `Sources/KeyboardShortcutSettingsFileStore+Template.swift` (the generated
  `cmux.json` template, which therefore now documents `sendAnonymousTelemetry: false`). Both
  read `.defaultValue` off `AppCatalogSection()`; that is the pattern to require of any
  future reader.

---

## Fork infrastructure

Fork-only tooling for building/shipping the fork. Not behavioral patches to cmux; they
do not need per-sync behavior verification, but should still be checked to apply cleanly.

Listed in `git log` order (oldest first), with subjects matching the live reworded
`fork(infra):` commits.

- `fork(infra): support -sb.N suffix in bump-version.sh` — version scheme `X.Y.Z-sb.N`
  (`scripts/bump-version.sh`).
- `fork(infra): add fork-release workflow` — `.github/workflows/fork-release.yml`:
  ad-hoc-signed, Sparkle-stripped DMG on `v*-sb.*` tag push.
- `fork(infra): add homebrew tap updater workflow` —
  `.github/workflows/update-homebrew-tap.yml`: chains off Fork Release via `workflow_run`,
  rewrites `Casks/cmux-sb.rb` in `sbourass/homebrew-cmux`.
- `fork(infra): add fork-release and build-env docs` — `docs/fork-release.md`,
  `docs/build-env.md`.
- `fork(infra): add preflight checklist to fork-release docs` — preflight section in
  `docs/fork-release.md`.
- `fork(infra): add patches.md fork patch index + wire into release` — this index
  (`docs/patches.md`) and its release-step wiring in `docs/fork-release.md`.
- `fork(infra): harden fork release workflow` — robustness fixes to
  `.github/workflows/fork-release.yml`.
- `fork(infra): note attestation, generated release notes, disabled upstream CI`
  — DMG build provenance attestation, per-tag generated release notes, and the
  rationale for disabling conflicting upstream workflows (`docs/fork-release.md`).
- `fork(infra): add cmux-fork-release skill` — the agent skill that orchestrates this
  sync-and-release pipeline end to end (`skills/cmux-fork-release/SKILL.md`, symlinked
  from `.claude/skills/`). Wraps `docs/fork-release.md` + this index and adds the
  Claude-Code operating lessons (sandbox/git, `gh` 502 false-positives, force-with-lease).
- `fork(infra): add fork commit naming convention` — the `fork(patch):` / `fork(infra):`
  scoped-subject convention documented in `docs/fork-release.md`, this index, and the
  `cmux-fork-release` skill; applied during the sync rebase reword.
- `fork(infra): raise fork-release job timeout to 120m` — bumps the Fork Release job
  timeout in `.github/workflows/fork-release.yml` so full SPM resolution + build fits on
  the GitHub-hosted `macos-latest` runner.
- `fork(infra): split zig CLI helper onto macos-15 for macOS 26 SDK` — pins the zig
  CLI-helper build step to a `macos-15` runner in `.github/workflows/fork-release.yml` to
  avoid the macOS 26 SDK toolchain mismatch.
- `fork(infra): ship fork cask as cmux-sb token to avoid upstream homebrew/cask collision`
  — renames the tap cask `cmux` → `cmux-sb` so `brew upgrade` stops silently resolving the
  fork to upstream's official homebrew/cask entry (`.github/workflows/update-homebrew-tap.yml`,
  `docs/fork-release.md`). First shipped in `v0.64.22-sb.1`.

---

## Release bookkeeping (recreated each release, not a tracked patch)

- `Bump to <version>` — version bump in `cmux.xcodeproj/project.pbxproj`
  (`MARKETING_VERSION` + `CURRENT_PROJECT_VERSION`). The `0.64.10-sb.1`/`-sb.2` bump
  commits from the previous base were intentionally dropped during the `v0.64.11` rebase
  (superseded by the single `0.64.11-sb.1` bump). Always the tip of `sb-main`.

> **Trap — skipping the bump commit also reverts this file.** The release step commits
> `docs/patches.md` *and* the version bump as one `Bump to …` commit, and the next sync
> `git rebase --skip`s that commit as obsolete. The version bump is meant to be dropped,
> but the `patches.md` updates ride along and are silently lost, leaving this index reverted
> to whatever the last non-bump commit set (hit during the `v0.64.22` sync: the file reverted
> to v0.64.11-era content — stale "TWO defaults" telemetry note and pre-package file paths).
> Recover with `git checkout sb-main-presync-backup -- docs/patches.md` before re-editing,
> which is why the backup ref is kept until the release is verified. To avoid the trap
> entirely, commit `patches.md` as its own `fork(infra):` commit and keep the `Bump to …`
> commit limited to `project.pbxproj`.
