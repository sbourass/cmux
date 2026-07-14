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

**Last synced upstream base:** `v0.64.18` (shipped as `v0.64.18-sb.1`)

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
  - `Packages/macOS/CmuxTerminal/Sources/CmuxTerminal/Surface/TerminalSurface.swift` —
    `historyFileId: UUID` stored property + init parameter on the (package-extracted)
    `TerminalSurface`.
  - `Sources/TerminalSurfaceRuntimeWiring.swift` — the app-module convenience
    `TerminalSurface.init` resolves `historyFileId` and, gated on
    `PerPaneShellHistorySettings.isEnabled()`, injects `CMUX_PANEL_HISTFILE` into the
    spawn env via `additionalEnvironment`. (Upstream moved `TerminalSurface` into the
    `CmuxTerminal` package, which cannot reach app-layer
    `SessionPanelHistoryStore`/`PerPaneShellHistorySettings`, so the env injection lives
    in this app-module seam instead of inside the surface's env builder.)
  - `Sources/SessionPersistence.swift` — `SessionPanelHistoryStore` (env key
    `CMUX_PANEL_HISTFILE`, `panel-history` dir, orphan sweep), `historyFileId` in the
    terminal snapshot.
  - `Sources/Workspace.swift`, `Sources/Workspace+PanelLifecycle.swift`,
    `Sources/Panels/TerminalPanel.swift`, `Sources/AppDelegate.swift` — plumb
    `historyFileId` through create/restore/close; orphan sweep at launch.
  - Shell integration: `Resources/shell-integration/cmux-zsh-integration.zsh`,
    `cmux-bash-integration.bash` — switch `HISTFILE` to `$CMUX_PANEL_HISTFILE` after rc.
  - **Settings UI** (ported into upstream's `CmuxSettingsUI` package):
    `Packages/macOS/CmuxSettings/.../Keys/TerminalCatalogSection.swift`
    (`perPaneShellHistory` catalog key),
    `Packages/macOS/CmuxSettingsUI/.../Sections/TerminalSection.swift` (row),
    `Packages/macOS/CmuxSettingsUI/.../Navigation/CuratedSettingEntry+Default.swift`
    (search entry),
    `Packages/macOS/CmuxSettingsUI/.../SettingsRowAnchorResolutionTests.swift` (test
    contract path), `Sources/SettingsNavigation.swift` (legacy in-app search entry).
  - Spec: `docs/per-pane-shell-history.md`.
- **Verify:**
  1. Settings → Terminal shows a **"Per-Pane Shell History"** toggle (after "Resume
     Agent Sessions on Reopen"), default ON.
  2. Two panes get **distinct** `$HISTFILE` paths under `panel-history/`. CLI check:
     `cmux send --surface surface:N 'echo $HISTFILE'` then `cmux read-screen …` for two
     surfaces — paths differ and end in `panel-history/<uuid>.zsh_history`.
  3. Each pane's history file contains only its own commands.
- **Rot watch:** the settings UI is the fragile part. Upstream's settings live in the
  `CmuxSettingsUI` catalog system (catalog key → `DefaultsValueModel` → `SettingsCardRow`
  + curated search entry + anchor test). If a future upstream moves/renames that, re-port
  the four settings pieces and keep `SettingsRowAnchorResolutionTests.rowConfigPaths` in
  sync (its contract test fails the build otherwise). The runtime mechanism
  (`CMUX_PANEL_HISTFILE`, shell integration) is stable. Second fragile spot:
  `TerminalSurface` is package-extracted (`CmuxTerminal`), so the env injection lives in
  `Sources/TerminalSurfaceRuntimeWiring.swift`'s convenience init, not in the surface
  itself. If upstream reshapes that convenience init or the `additionalEnvironment`
  plumbing, re-anchor the `CMUX_PANEL_HISTFILE` injection there and keep `historyFileId`
  flowing into the package init. Third spot, new in v0.64.17: upstream refactored the
  startup-snapshot loader in `Sources/AppDelegate.swift`
  (`prepareStartupSessionSnapshotIfNeeded`) to add crash-diagnostic-window pruning
  (`loadStartupSessionSnapshotPruningCrashDiagnostics`). The fork's orphan-sweep must
  coexist: adopt upstream's pruning load but assign it with an `if
  shouldAttemptRestore()` rather than upstream's early `guard … else return`, so the
  per-pane-history orphan sweep still runs when restore is disabled.

### 2. Default anonymous telemetry to off
- **Commit subject:** `fork(patch): default anonymous telemetry to off`
- **Purpose:** fresh installs are opt-in (telemetry off) rather than opt-out. Existing
  users keep their stored preference (the default is only consulted when the
  `sendAnonymousTelemetry` key is unset).
- **Key code (source of truth — ONE default since v0.64.16):**
  - `Packages/macOS/CmuxSettings/.../Keys/AppCatalogSection.swift` — catalog key
    `app.sendAnonymousTelemetry` `defaultValue: false`. This is the **single** source of
    truth: it drives both the Settings UI toggle and the send gate.
    `TelemetrySettings.enabledForCurrentLaunch` in `Sources/cmuxApp.swift` reads it
    directly via `AppCatalogSection().sendAnonymousTelemetry.value(in: .standard)`, so
    `Sources/cmuxApp.swift` no longer carries its own `defaultSendAnonymousTelemetry`
    field (upstream removed it in v0.64.16) and the fork no longer patches that file.
  - `cmuxTests/GhosttyConfigTests.swift` — `testTelemetryDefaultsToDisabledWhenUnset`
    asserts `AppCatalogSection().sendAnonymousTelemetry.value(in:)` is `false` when unset.
- **Verify:**
  1. With the key unset (`defaults read <bundle-id> sendAnonymousTelemetry` → "does not
     exist"), the Settings telemetry toggle shows **OFF**.
  2. Actual sending is gated off: `TelemetrySettings.enabledForCurrentLaunch` is `false`
     when unset (used by `SentryHelper`, `PostHogAnalytics`, `AppDelegate`).
- **Rot watch:** upstream split this into two defaults in v0.64.11 (a `TelemetrySettings`
  enum default *and* the catalog `DefaultsKey`) and then **re-merged** them into the
  single catalog `DefaultsKey` in v0.64.16. Only the catalog `defaultValue: false`
  matters now. If a future sync re-introduces a separate `TelemetrySettings` default or
  any other reader, default it off too.

---

## Fork infrastructure

Fork-only tooling for building/shipping the fork. Not behavioral patches to cmux; they
do not need per-sync behavior verification, but should still be checked to apply cleanly.

- `fork(infra): support -sb.N suffix in bump-version.sh` — version scheme `X.Y.Z-sb.N`
  (`scripts/bump-version.sh`).
- `fork(infra): add fork-release workflow` — `.github/workflows/fork-release.yml`:
  ad-hoc-signed, Sparkle-stripped DMG on `v*-sb.*` tag push.
- `fork(infra): add homebrew tap updater workflow` —
  `.github/workflows/update-homebrew-tap.yml`: chains off Fork Release via
  `workflow_run`, rewrites `Casks/cmux.rb` in `sbourass/homebrew-cmux`.
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
- `fork(infra): add fork commit naming convention` — defines the `fork(patch):` /
  `fork(infra):` scoped-subject convention across `docs/fork-release.md`,
  `docs/patches.md`, and the `cmux-fork-release` skill.
- `fork(infra): raise fork-release job timeout to 120m` — the universal WMO Release
  build outgrew the 60m job timeout at v0.64.17 (`.github/workflows/fork-release.yml`).
- `fork(infra): split zig CLI helper onto macos-15 for macOS 26 SDK` — after
  `macos-latest` migrated to macOS 26 (June 2026), zig 0.15.x can no longer link
  the Ghostty CLI helper against the macOS 26 SDK (undefined libSystem symbols).
  The release now builds that helper in a separate `macos-15` job, uploads it as
  an artifact, and the macos-26 app build consumes it with `CMUX_SKIP_ZIG_BUILD=1`
  + `install-prebuilt-ghostty-cli-helper.sh` — mirroring upstream's
  `build-ghostty-cli-helper` job split (`.github/workflows/fork-release.yml`).

---

## Release bookkeeping (recreated each release, not a tracked patch)

- `Bump to <version>` — version bump in `cmux.xcodeproj/project.pbxproj`
  (`MARKETING_VERSION` + `CURRENT_PROJECT_VERSION`). Left **unprefixed** (not a tracked
  patch). The previous base's `Bump to …` commit is intentionally dropped during each
  upstream rebase (superseded by the single `<new-base>-sb.1` bump). Always the tip of
  `sb-main`.
