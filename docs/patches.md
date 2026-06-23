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

**Last synced upstream base:** `v0.64.11` (shipped as `v0.64.11-sb.1`)

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
- **Commit subject:** `Add per-pane shell history isolation`
- **Purpose:** each terminal pane gets its own command history file
  (`~/Library/Application Support/cmux/panel-history/<uuid>.zsh_history`), keyed by a
  stable UUID stored in the session snapshot. Pressing ↑ in a pane recalls only that
  pane's commands; history survives quit/reopen. Toggleable (default ON).
- **Key code (source of truth):**
  - `Sources/App/WorkspaceRuntimeSettings.swift` — `PerPaneShellHistorySettings`
    enum (UserDefaults key `terminal.perPaneShellHistory`, default `true`).
  - `Sources/GhosttyTerminalView.swift` — sets `CMUX_PANEL_HISTFILE` env per surface
    (in/after `applyManagedCmuxContextEnvironment`), gated on
    `PerPaneShellHistorySettings.isEnabled()`; `historyFileId` on `TerminalSurface`.
  - `Sources/SessionPersistence.swift` — `SessionPanelHistoryStore` (env key
    `CMUX_PANEL_HISTFILE`, `panel-history` dir, orphan sweep), `historyFileId` in the
    terminal snapshot.
  - `Sources/Workspace.swift`, `Sources/Workspace+PanelLifecycle.swift`,
    `Sources/Panels/TerminalPanel.swift`, `Sources/AppDelegate.swift` — plumb
    `historyFileId` through create/restore/close; orphan sweep at launch.
  - Shell integration: `Resources/shell-integration/cmux-zsh-integration.zsh`,
    `cmux-bash-integration.bash` — switch `HISTFILE` to `$CMUX_PANEL_HISTFILE` after rc.
  - **Settings UI** (ported into upstream's `CmuxSettingsUI` package):
    `Packages/CmuxSettings/.../Keys/TerminalCatalogSection.swift` (`perPaneShellHistory`
    catalog key), `Packages/CmuxSettingsUI/.../Sections/TerminalSection.swift` (row),
    `Packages/CmuxSettingsUI/.../Navigation/CuratedSettingEntry+Default.swift` (search
    entry), `Packages/CmuxSettingsUI/.../SettingsRowAnchorResolutionTests.swift` (test
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
  (`CMUX_PANEL_HISTFILE`, shell integration) is stable.

### 2. Default anonymous telemetry to off
- **Commit subject:** `Default anonymous telemetry to off`
- **Purpose:** fresh installs are opt-in (telemetry off) rather than opt-out. Existing
  users keep their stored preference (the default is only consulted when the
  `sendAnonymousTelemetry` key is unset).
- **Key code (source of truth — there are TWO defaults, both must be `false`):**
  - `Sources/cmuxApp.swift` — `TelemetrySettings.defaultSendAnonymousTelemetry = false`
    (drives the actual send gate `TelemetrySettings.enabledForCurrentLaunch`).
  - `Packages/CmuxSettings/.../Keys/AppCatalogSection.swift` — catalog key
    `app.sendAnonymousTelemetry` `defaultValue: false` (drives the **Settings UI toggle**;
    same UserDefaults key `sendAnonymousTelemetry`).
  - `cmuxTests/GhosttyConfigTests.swift` — `testTelemetryDefaultsToDisabledWhenUnset`.
- **Verify:**
  1. With the key unset (`defaults read <bundle-id> sendAnonymousTelemetry` → "does not
     exist"), the Settings telemetry toggle shows **OFF**.
  2. Actual sending is gated off: `TelemetrySettings.enabledForCurrentLaunch` is `false`
     when unset (used by `SentryHelper`, `PostHogAnalytics`, `AppDelegate`).
- **Rot watch:** **two sources of truth** for one UserDefaults key — the
  `TelemetrySettings` enum default *and* the `CmuxSettings` catalog `DefaultsKey` default.
  They were split by upstream in v0.64.11. If a sync touches either, set **both** to
  `false`. If upstream adds a third reader, default it off too.

---

## Fork infrastructure

Fork-only tooling for building/shipping the fork. Not behavioral patches to cmux; they
do not need per-sync behavior verification, but should still be checked to apply cleanly.

- `Support -sb.N suffix in bump-version.sh` — version scheme `X.Y.Z-sb.N`
  (`scripts/bump-version.sh`).
- `Add fork-release workflow` — `.github/workflows/fork-release.yml`: ad-hoc-signed,
  Sparkle-stripped DMG on `v*-sb.*` tag push.
- `Add homebrew tap updater workflow` — `.github/workflows/update-homebrew-tap.yml`:
  chains off Fork Release via `workflow_run`, rewrites `Casks/cmux.rb` in
  `sbourass/homebrew-cmux`.
- `Add fork-release and build-env docs` — `docs/fork-release.md`, `docs/build-env.md`.
- `Add preflight checklist to fork-release docs` — preflight section in
  `docs/fork-release.md`.
- `Add docs/patches.md fork patch index + wire into release process` — this index
  (`docs/patches.md`) and its release-step wiring in `docs/fork-release.md`.
- `Harden fork release workflow` — robustness fixes to
  `.github/workflows/fork-release.yml`.
- `docs(fork-release): note attestation, generated release notes, and disabled fork CI workflows`
  — DMG build provenance attestation, per-tag generated release notes, and the
  rationale for disabling conflicting upstream workflows (`docs/fork-release.md`).
- `Add cmux-fork-release skill` — the agent skill that orchestrates this
  sync-and-release pipeline end to end (`skills/cmux-fork-release/SKILL.md`, symlinked
  from `.claude/skills/`). Wraps `docs/fork-release.md` + this index and adds the
  Claude-Code operating lessons (sandbox/git, `gh` 502 false-positives, force-with-lease).

---

## Release bookkeeping (recreated each release, not a tracked patch)

- `Bump to <version>` — version bump in `cmux.xcodeproj/project.pbxproj`
  (`MARKETING_VERSION` + `CURRENT_PROJECT_VERSION`). The `0.64.10-sb.1`/`-sb.2` bump
  commits from the previous base were intentionally dropped during the `v0.64.11` rebase
  (superseded by the single `0.64.11-sb.1` bump). Always the tip of `sb-main`.
