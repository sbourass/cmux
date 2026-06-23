---
name: cmux-fork-release
description: "Use whenever the target of a release, build, sync, tag, or pipeline-fix is the user's personal cmux fork rather than mainline cmux. Signals: 'the fork' / 'our fork', sbourass/cmux, branch sb-main, any -sb / X.Y.Z-sb.N version, or the fork's own Homebrew tap/cask. Covers the whole fork lifecycle — 'release the fork', 'update/sync the fork to the latest upstream', rebasing the fork's patches onto a new upstream tag, bumping the -sb counter to ship a fork-only patch on the same base, re-triggering the fork's release workflow after a tag push, and refreshing the fork's stale Homebrew cask/DMG. This is NOT the upstream cmux-release / /release flow (manaflow-ai, Apple-signed, Sparkle, changelog) — if anything identifies the fork, route it here instead."
---

# cmux fork sync & release (`sbourass/cmux`)

This skill orchestrates the personal fork's two-phase pipeline:

- **Phase A — Sync:** rebase the fork's patches onto the latest **upstream release tag** and re-verify them.
- **Phase B — Release:** bump to `X.Y.Z-sb.N`, tag, force-push, and let the tag-triggered CI publish the DMG + update the Homebrew cask.

"Release the fork" almost always means **A then B** (sync to the newest upstream, then ship). "Just sync" stops after Phase A; "ship a fork-only patch on the same base" is Phase B alone with `bump-version.sh patch`.

## Source of truth — read these first

The fork keeps its canonical, maintained procedure in-repo. Read them before acting; this skill orchestrates them and adds the Claude-Code operating lessons the docs don't carry.

- **`docs/fork-release.md`** — versioning, Preflight checklist, "Shipping a release", "Syncing with upstream", recurring conflict files, failure recovery, locked-in decisions.
- **`docs/patches.md`** — the curated index of behavioral patches with **Verify** + **Rot watch** notes. Updating it is a required release step; its Verify steps are what actually protect the fork across a rebase.

> The docs example paths reference a worktree (`…/cmux-per-pane-shell-history`) that may not exist. The live repo in this environment is at **`/Users/user/src/cmux/cmux`** — verify with `git remote -v` (origin = `sbourass/cmux`, upstream = `manaflow-ai/cmux`, branch `sb-main`).

## Branch / version model

- `sb-main` is the fork trunk and `origin`'s default branch. Each sync **rebases** the fork patches onto the new upstream tag, so `sb-main` history is rewritten and pushed with `--force-with-lease`.
- Version is `X.Y.Z-sb.N`: `X.Y.Z` = upstream base, `N` = fork iteration on that base. After a sync → `<upstream>-sb.1`; a fork-only patch on the same base → bump `N`.
- The fork tracks upstream **release tags**, not `main`/nightly.

## Fork commit naming convention

Every fork commit subject is a scoped conventional-commit tag — two scopes only:

- **`fork(patch):`** — changes cmux's runtime behavior versus upstream. These are
  exactly the commits that have a **Verify** step in `docs/patches.md` (today:
  per-pane shell history, telemetry-off).
- **`fork(infra):`** — everything that builds, ships, or documents the fork (CI
  workflows, `bump-version.sh`, the Homebrew-tap updater, the fork docs, the
  `patches.md` index, this skill). CI workflows are infra — there is **no** separate
  `workflow` scope.

Style: `fork(<scope>): <lowercase imperative>`. The `Bump to <ver>-sb.N` tip is
release bookkeeping (regenerated each release), not a tracked patch — leave it
**unprefixed**. Subjects are surfaced verbatim to users in the generated GitHub
Release body (`.github/workflows/fork-release.yml`), so keep them clean. The reword
is applied during the Phase A rebase (below), and `docs/patches.md`'s
`**Commit subject:**` keys are updated in lockstep in Phase B step 2.

---

## Phase A — Sync to the latest upstream release

Run git operations with the **sandbox disabled** — `git rebase`/`submodule update` need full worktree + `.git` write access, and the sandbox blocks creating new upstream dirs (e.g. `.claude/skills`) with "Operation not permitted", which aborts the rebase mid-checkout. See Gotchas.

```bash
cd /Users/user/src/cmux/cmux
git fetch upstream --tags
LATEST=$(gh release view --repo manaflow-ai/cmux --json tagName --jq .tagName)   # e.g. v0.64.15
git branch -f sb-main-presync-backup sb-main      # rollback point — keep until the release is verified
git rebase "$LATEST"
```

**Resolve conflicts.** `docs/patches.md` lists the reliably-conflicting files; resolutions are mechanical *combinations* — keep the fork's behavior while adopting upstream's new API shape, never a blind "take theirs/ours":

- Recurring: `Sources/GhosttyTerminalView.swift`, `Sources/SessionPersistence.swift`, `Sources/Workspace.swift`, `Sources/Panels/TerminalPanel.swift` (per-pane-shell-history plumbing — usually combining new parameter lists).
- Seen in the v0.64.15 sync: `Sources/AppDelegate.swift` — upstream refactored the startup-snapshot loader. The correct merge **adopts upstream's new entry point** (`SessionPersistenceStore.loadStartupSnapshot()`, which adds an unusable→backup fallback) **while preserving** the fork's "always load live+backup for orphan-sweep reference" logic. A clean apply that drops either side silently bypasses the patch.

**Skip the stale version-bump commit.** The fork's tip is a `Bump to <prev>-sb.N` commit; it conflicts on `cmux.xcodeproj/project.pbxproj` (version strings) and is obsolete. `git rebase --skip` it — re-versioning to `<LATEST>-sb.1` is a deliberate Phase-B step (the build number needs the pretag guard). Don't hand-resolve it into a half-bump.

**Sync submodules.** A rebase updates the *recorded* submodule pointers but not their worktrees, so `git submodule status` shows `+` drift (esp. `ghostty`):

```bash
git submodule update --init --recursive
git submodule status --recursive      # no leading '+' when aligned
```

**Reword fork commits** to the naming convention (above). The rebase already
rewrites every SHA, so this is the free moment to normalize subjects — no extra
force-push. Each replayed fork commit must carry its `fork(patch):` / `fork(infra):`
subject; the `Bump to …` tip stays unprefixed. Mechanism:

```bash
git rebase -i "$LATEST"     # mark each fork commit 'reword', fix its subject
```

If interactive `-i` is unavailable (some agent sandboxes block the editor), run it
in a normal shell or script the todo via `GIT_SEQUENCE_EDITOR`. Any already-correct
`fork(...)` subject needs no change. After rewording, `git log --oneline
"$LATEST"..sb-main` should read as a clean `fork(patch):` / `fork(infra):` list.

**Build-verify** (proves the conflict resolution compiles against the new base):

```bash
PATH="/opt/homebrew/opt/zig@0.15/bin:$PATH" ./scripts/reload.sh --tag sb-sync
```

If asked only to "update/sync the fork to upstream", **stop here** and offer the release as the follow-up.

---

## Phase B — Ship the fork release

### 1. Preflight (`docs/fork-release.md` → Preflight)

```bash
gh secret list   --repo sbourass/cmux | grep HOMEBREW_TAP_TOKEN          # present (PATs expire)
gh workflow list --repo sbourass/cmux | grep -E 'Fork Release|Homebrew'  # both active
gh workflow list --repo sbourass/cmux --all | grep -E 'Release macOS app|Nightly|Update Homebrew Cask'  # all disabled_manually
gh repo view sbourass/cmux --json defaultBranchRef --jq .defaultBranchRef.name  # sb-main
```

### 2. Update `docs/patches.md` (required)

- Set **"Last synced upstream base"** to `<LATEST>` (shipped as `<LATEST>-sb.1`).
- Reconcile the patch list against `git log --oneline --no-merges <LATEST>..sb-main` — add new patches, drop removed ones, fix moved paths.
- Update each `**Commit subject:**` key to the **reworded** subject (from the Phase A reword) — in lockstep, so the index keys keep matching live `git log`.
- **Re-run each behavioral patch's Verify** against the new base. The two that exist today:
  - *Default anonymous telemetry off* — **two** sources of truth, both must be `false`: `TelemetrySettings.defaultSendAnonymousTelemetry` (`Sources/cmuxApp.swift`) **and** the `app.sendAnonymousTelemetry` catalog `defaultValue` (`Packages/CmuxSettings/.../Keys/AppCatalogSection.swift`). A prior sync broke exactly this when upstream split the default.
  - *Per-pane shell history* — catalog default `true`, the three `CmuxSettingsUI` pieces (row + curated search entry + anchor test), runtime plumbing in `Sources/`, and both shell-integration scripts. Gold-standard runtime check (below): `$HISTFILE` resolves under `panel-history/<uuid>.zsh_history`.

### 3. Bump, guard, commit, tag

```bash
./scripts/bump-version.sh <LATEST>-sb.1     # sets MARKETING_VERSION + bumps CURRENT_PROJECT_VERSION (Sparkle build #)
./scripts/release-pretag-guard.sh           # asserts build # monotonic vs the published appcast
git commit -m "Bump to <LATEST>-sb.1" -- cmux.xcodeproj/project.pbxproj docs/patches.md
git tag v<LATEST>-sb.1
```

Commit **only** the version + patches.md changes — explicitly list paths so unrelated untracked files (WIP docs, etc.) stay out of the release commit.

### 4. Push (triggers CI)

`sb-main` history was rewritten by the sync, so it needs a lease-checked force-push; the tag pushes normally:

```bash
git push --force-with-lease origin sb-main
git push origin v<LATEST>-sb.1
```

The `v*-sb.*` tag fires **Fork Release** (ad-hoc-signed, Sparkle-stripped DMG, attested) → **Update Homebrew Tap** chains off it via `workflow_run` and rewrites `Casks/cmux.rb` in `sbourass/homebrew-cmux`.

### 5. Watch & verify

```bash
RUN=$(gh run list --repo sbourass/cmux --workflow "Fork Release" --limit 1 --json databaseId --jq '.[0].databaseId')
# Poll to a real terminal state — see Gotchas (gh run watch can exit 0 on a transient 502):
gh run view "$RUN" --repo sbourass/cmux --json status,conclusion --jq '.status+"|"+(.conclusion//"")'

gh release view v<LATEST>-sb.1 --repo sbourass/cmux --json assets --jq '[.assets[].name]'   # cmux-macos.dmg present
gh run list --repo sbourass/cmux --workflow "Update Homebrew Tap" --limit 1                  # success, chained
gh api repos/sbourass/homebrew-cmux/contents/Casks/cmux.rb --jq .content | base64 -d | grep -E 'version|sha256'  # cask bumped
```

Optionally end-to-end: `gh attestation verify <dmg> --repo sbourass/cmux` and `brew update && brew upgrade --cask sbourass/cmux/cmux`.

When the release is confirmed published, the `sb-main-presync-backup` ref can be deleted.

---

## Runtime verification of the built app (optional but recommended)

Drive the tagged build via the debug CLI (`CLAUDE.md` → Local dev). `send` types text without Enter — append `\n`:

```bash
./scripts/reload.sh --tag sb-sync --launch
CMUX_TAG=sb-sync scripts/cmux-debug-cli.sh workspace list
CMUX_TAG=sb-sync scripts/cmux-debug-cli.sh send --workspace workspace:1 --surface surface:1 'echo HISTFILE=$HISTFILE\n'
CMUX_TAG=sb-sync scripts/cmux-debug-cli.sh read-screen --workspace workspace:1 --surface surface:1
# expect: HISTFILE=…/cmux/panel-history/<uuid>.zsh_history  → per-pane-history patch live
```

A window screenshot may be uncapturable: the window can land on a background macOS Space, and forcing a Space switch needs an Accessibility permission `osascript`/`screencapture` won't have non-interactively. For a terminal app, `read-screen` returning live rendered content (not a blank grid) is the meaningful "it launched" evidence.

---

## Gotchas (Claude-Code operating lessons)

- **Sandbox blocks git rewrites.** `git rebase` / `git submodule update` fail with "Operation not permitted" creating new upstream dirs under the worktree (e.g. `.claude/skills`). Run them with the sandbox disabled. Symptom: rebase aborts at the initial checkout, leaving `.git/rebase-merge` half-applied.
- **Aborted rebase leaves stray untracked artifacts.** A partial checkout can drop an untracked symlink (e.g. `.agents/skills -> ../skills`) that then blocks the restart with "untracked working tree files would be overwritten". Remove the stray artifact and re-run; it's recreated correctly by the rebase.
- **`gh` over the sandbox** hits TLS cert failures (`x509: OSStatus -26276`); re-run gh commands with the sandbox disabled.
- **`gh run watch --exit-status` can exit 0 on a transient HTTP 502**, falsely signaling success while the run is still building. Confirm with `gh run view … --json status,conclusion`, or poll in a loop until `status=completed` before trusting the conclusion.
- **Capture noisy script output to a file.** `bump-version.sh` / `release-pretag-guard.sh` / build logs can get truncated inline; redirect to `"$TMPDIR/x.log"` and read it. Use `$TMPDIR`, not `/tmp/claude/...` (the latter may not exist → the command aborts before running).
- **Force-push is expected** on `sb-main` after a sync — always `--force-with-lease`, and confirm `origin/sb-main` still points at the pre-sync tip before pushing.

---

## Fork release history (for context)

| Tag | Date | Upstream base | Notes |
|-----|------|---------------|-------|
| `v0.64.10-sb.1` | 2026-05-26 | v0.64.10 | first fork build |
| `v0.64.10-sb.2` | 2026-05-29 | v0.64.10 | fork-only patch, same base |
| `v0.64.11-sb.1` | 2026-06-01 | v0.64.11 | sync; settings UI extracted upstream → telemetry second-default introduced |
| `v0.64.13-sb.1` | 2026-06-04 | v0.64.13 | sync (skipped 0.64.12) |
| `v0.64.14-sb.1` | 2026-06-06 | v0.64.14 | sync |
| `v0.64.15-sb.1` | 2026-06-12 | v0.64.15 | sync; AppDelegate startup-snapshot loader conflict |

`bump-version.sh` keeps `CURRENT_PROJECT_VERSION` (Sparkle build #) monotonic across all of these regardless of the `-sb.N` reset, which is what `release-pretag-guard.sh` enforces.

## Recovery

See `docs/fork-release.md` → "Recovering from failures": transient SPM 404 (`gh run rerun <id> --failed`), tap updater skipped/401 (`gh workflow run "Update Homebrew Tap" -f version=v<X.Y.Z-sb.N>` / re-create `HOMEBREW_TAP_TOKEN`), cask verification.
