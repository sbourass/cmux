# Fork Release Pipeline (`sbourass/cmux`)

How the `sbourass/cmux` fork ships builds via Homebrew tap
`sbourass/homebrew-cmux`. For local build-environment setup, see
[build-env.md](./build-env.md).

---

## TL;DR

Personal fork of `manaflow-ai/cmux` distributed as an ad-hoc-signed DMG via a
Homebrew cask tap. Build chain on a `v*-sb.*` tag push:

```
tag push → Fork Release workflow → GitHub Release (cmux-macos.dmg)
                                 → Update Homebrew Tap workflow → cask updated
```

Sparkle auto-update is stripped at build time — Homebrew is the only update
channel. The DMG is attested with GitHub build provenance, and the release body
is generated per-tag to list the fork's commits on top of the upstream base.

---

## Versioning

`X.Y.Z-sb.N` where `X.Y.Z` is the upstream base version and `N` is the fork
iteration on top of it.

- `0.64.10-sb.1` — first fork build on top of upstream `v0.64.10`.
- `0.64.10-sb.2` — fork-only patch on the same base.
- `0.65.0-sb.1` — first fork build after rebasing onto upstream `v0.65.0`.

`scripts/bump-version.sh` handles the suffix:

```bash
./scripts/bump-version.sh patch          # bumps the -sb counter
./scripts/bump-version.sh 0.65.0-sb.1    # explicit set after upstream sync
```

`bump-version.sh` also bumps `CURRENT_PROJECT_VERSION` (Sparkle build number) so
the release-pretag guard passes.

---

## Preflight (run after any long break)

These were set up once and stay in place — but PATs expire and workflows can
get re-enabled by upstream syncs. Verify before shipping if it's been a while:

```bash
# Token still valid? (look for HOMEBREW_TAP_TOKEN; check Updated date)
gh secret list --repo sbourass/cmux

# Fork-specific workflows still active? (Fork Release + Update Homebrew Tap)
gh workflow list --repo sbourass/cmux

# Conflicting upstream workflows still disabled?
gh workflow list --repo sbourass/cmux --all | grep -E 'Release macOS app|Nightly|Update Homebrew Cask|Deploy docs channels'
# Each should show "disabled_manually"

# Any NEW upstream workflow that fires on our release tag? (added in the v0.64.22 sync,
# which is when "Deploy docs channels" showed up and would have failed on every fork tag)
# Anything listed here other than fork-release.yml must be disabled on the fork.
grep -lE 'tags:\s*(\["v\*"\]|$)' .github/workflows/*.yml | xargs grep -l 'v\*'

# Upstream CI workflows that require paid macOS runners still disabled?
# The fork has no Blacksmith/Warp runner, so their macOS jobs (runs-on:
# vars.MACOS_RUNNER_15 || warp-macos-...) queue forever on every PR; the ubuntu
# jobs run fine. Keep these disabled (the ubuntu-only workflow-guard-tests is the
# meaningful PR signal).
gh workflow list --repo sbourass/cmux --all | grep -E 'Activation performance|^CI[[:space:]]'
# Each should show "disabled_manually"

# Default branch still sb-main? (workflow_run depends on this)
gh repo view sbourass/cmux --json defaultBranchRef --jq .defaultBranchRef.name
# Expect: sb-main
```

If `HOMEBREW_TAP_TOKEN` is missing or expired, re-create the fine-grained PAT
(`sbourass/homebrew-cmux` Contents: read+write) and `gh secret set
HOMEBREW_TAP_TOKEN --repo sbourass/cmux`. Symptom of expiration is the tap
updater silently failing with HTTP 401 from the `peter-evans/repository-dispatch`
or `git push` step.

---

## Shipping a release

```bash
cd /Users/user/src/cmux/cmux-per-pane-shell-history

# 1. Verify build (see build-env.md for env requirements)
PATH="/opt/homebrew/opt/zig@0.15/bin:$PATH" ./scripts/reload.sh --tag sb-sync

# 2. Update docs/patches.md (see "Maintaining patches.md" below) — required step
#    reconcile the patch list, bump the "Last synced upstream base", re-run each
#    patch's Verify note against the current base.

# 3. Bump version
./scripts/bump-version.sh patch            # or explicit X.Y.Z-sb.N after a sync

# 4. Pretag guard (checks build number monotonic vs published)
./scripts/release-pretag-guard.sh

# 5. Commit, tag, push  (patches.md + version bump in the same release commit)
git commit -am "Bump to <new-version>"
git tag v<new-version>
git push origin sb-main v<new-version>

# 6. Watch
gh run watch --repo sbourass/cmux
```

Once `Fork Release` completes, `Update Homebrew Tap` chains off it via
`workflow_run` and rewrites `Casks/cmux-sb.rb` in the tap repo.

### Commit naming convention

Fork commit subjects use a scoped conventional-commit tag, two scopes only:

- **`fork(patch):`** — changes cmux's runtime behavior vs upstream (the commits with
  a **Verify** step in [`patches.md`](./patches.md)).
- **`fork(infra):`** — builds, ships, or documents the fork (CI workflows,
  `bump-version.sh`, the Homebrew-tap updater, these docs, the `patches.md` index,
  the `cmux-fork-release` skill). CI workflows are infra — no separate `workflow`
  scope.

Style `fork(<scope>): <lowercase imperative>`. The `Bump to <ver>-sb.N` tip is
release bookkeeping, left unprefixed. Subjects appear verbatim to users in the
generated GitHub Release body (`.github/workflows/fork-release.yml`). The reword is
applied during the upstream-sync rebase (it rewrites every SHA anyway, so there's no
extra force-push), and the `**Commit subject:**` keys in `patches.md` are updated in
lockstep at that point.

### Maintaining patches.md

[`docs/patches.md`](./patches.md) is the curated index of the behavioral patches the
fork carries. **Updating it is a required release step**, and Claude Code does it
automatically when asked to cut a fork release:

1. Reconcile the patch list against `git log --oneline --no-merges v<base>..sb-main`:
   add any new patch, remove any dropped one, fix file paths that moved.
2. Update the **"Last synced upstream base"** line to the version being shipped.
3. Re-run each behavioral patch's **Verify** steps against the current build and
   confirm they still pass — this is what catches a patch that rebased cleanly but was
   bypassed by an upstream refactor (the telemetry-default second-source-of-truth case).
   If a Verify step fails, fix the patch (and its **Rot watch** note) before shipping.

---

## Syncing with upstream

The fork tracks upstream release tags (not `main`/nightly).

```bash
cd /Users/user/src/cmux/cmux-per-pane-shell-history
git fetch upstream --tags
LATEST=$(gh release view --repo manaflow-ai/cmux --json tagName --jq .tagName)
git rebase "$LATEST"
# resolve conflicts (see "Recurring conflict files" below)
PATH="/opt/homebrew/opt/zig@0.15/bin:$PATH" ./scripts/reload.sh --tag sb-sync
git push --force-with-lease origin sb-main
```

After resolving conflicts, **re-verify every behavioral patch against the new base
using the Verify steps in [`docs/patches.md`](./patches.md)** before shipping. A clean
rebase does not guarantee a patch still works — upstream refactors can bypass a patch
that merged without conflict (e.g. the v0.64.11 settings extraction + telemetry
second-source-of-truth). Then ship a new release with `bump-version.sh <upstream>-sb.1`
(the "Update docs/patches.md" step in "Shipping a release" covers reconciling the index).

### Recurring conflict files

The per-pane-shell-history patch reliably conflicts on these files during upstream
rebase. Resolutions are mechanical — usually combining new parameter lists, i.e. keep
**both** sides rather than taking ours/theirs.

- `Packages/macOS/CmuxTerminal/Sources/CmuxTerminal/Surface/TerminalSurface.swift` — the
  `historyFileId` property + `init` parameter. **New location as of `v0.64.22`**; upstream
  moved `TerminalSurface` out of `Sources/GhosttyTerminalView.swift` into the `CmuxTerminal`
  package. In that sync it conflicted twice, both times because upstream added a field
  (`terminalLifecycleId`) adjacent to the fork's — resolution was to keep both.
- `Sources/Workspace.swift` — the restore call site; conflicts when upstream adds another
  argument (e.g. `terminalFontSizeCreationPolicy:`) next to `historyFileId:`.
- `Sources/SessionPersistence.swift`, `Sources/Panels/TerminalPanel.swift` — historically
  conflicted; auto-merged cleanly in `v0.64.22`.
- `Sources/GhosttyTerminalView.swift` — no longer a conflict site after the `CmuxTerminal`
  extraction, despite heavy upstream churn.
- `cmux.xcodeproj/project.pbxproj` — always conflicts, but only on the stale
  `Bump to <prev>-sb.N` commit, which is meant to be `git rebase --skip`ped (see the trap
  note in [patches.md](./patches.md) → "Release bookkeeping": the skip also reverts
  `patches.md`).

---

## Recovering from failures

### Fork Release fails with transient SPM 404

Sparkle/Sentry binary-target ZIPs occasionally 404 from GitHub's CDN during
package resolution. Just re-run:

```bash
gh run rerun <run-id> --repo sbourass/cmux --failed
```

`workflow_run` *does* fire on rerun success, so the tap-updater will chain
automatically.

### Update Homebrew Tap was skipped or failed

Trigger manually with the published version:

```bash
gh workflow run "Update Homebrew Tap" \
  --repo sbourass/cmux \
  --ref sb-main \
  -f version=v<X.Y.Z-sb.N>
```

(With or without leading `v` — the workflow normalizes.)

### Verifying the cask after a release

```bash
gh release view v<X.Y.Z-sb.N> --repo sbourass/cmux        # check DMG asset present
gh release download v<X.Y.Z-sb.N> --repo sbourass/cmux --pattern cmux-macos.dmg  # fetch it locally
gh attestation verify cmux-macos.dmg --repo sbourass/cmux  # verify build provenance (needs the local file)
gh api repos/sbourass/homebrew-cmux/contents/Casks/cmux-sb.rb --jq .content \
  | base64 -d | grep -E 'version|sha256'                   # check cask updated
brew update && brew upgrade --cask sbourass/cmux/cmux-sb   # end-to-end
```

---

## Locked-in decisions

1. **Versioning = `X.Y.Z-sb.N` suffix.** About cmux shows it directly; brew handles semver pre-release within the tap. `bump-version.sh` was patched to support it.
2. **Branch model:** `sb-main` is the personal trunk and the fork's default branch. `feat/*` branches merge into it. `main` tracks `upstream/main` (read-only-ish, for syncs only).
3. **Distribution = Homebrew cask tap.** No direct DMG downloads, no Mac App Store.
4. **Signing = ad-hoc (`codesign -s -`).** No Apple Developer Program. Users accept Gatekeeper once per install; the cask `caveats` block documents the `xattr -dr com.apple.quarantine` bypass.
5. **Sparkle = stripped at build time.** Critical: leaving upstream's `SUFeedURL` + `SUPublicEDKey` in place would let upstream-signed updates validate and silently replace the fork. The `Disable Sparkle` step in `fork-release.yml` removes both keys and sets `SUEnableAutomaticChecks=false`.
6. **Runner = GitHub-hosted `macos-latest`.** No self-hosted runners.
7. **Upstream sync = rebase, not merge.** Linear history; force-push to `origin/sb-main` is expected.

---

## Gotchas

1. **`workflow_run` triggers only fire from the default branch.** The fork's default branch must be `sb-main` (not `main`) for `Update Homebrew Tap` to listen for `Fork Release` completions. Don't change the default.

2. **Upstream's `v*` tag pattern collides.** Upstream workflows that trigger on `v*` (`Release macOS app`, etc.) would fire alongside `fork-release.yml` and fail noisily on missing Apple/Sparkle secrets. They are disabled on the fork via `gh workflow disable`. Re-disable any time an upstream sync re-enables them.

   A sync can also introduce a **brand-new** colliding workflow, which the preflight's
   fixed name list will not catch. The `v0.64.22` sync added `docs-channels.yml`
   ("Deploy docs channels", `tags: ["v*"]`), whose `release` job would fire on every
   `v*-sb.*` tag and fail on the fork's missing `VERCEL_*` secrets; it was disabled on
   2026-08-04. Use the tag-pattern grep in Preflight to enumerate them rather than
   trusting the name list. Note `mux-sdk-v*` / `cmux-sdk-v*` / `cmux-tui-v*` patterns do
   **not** match a `v…` tag, so those SDK/TUI publish workflows are safe to leave active.

3. **`bump-version.sh` chases upstream's Sparkle build number.** It curls `manaflow-ai/cmux`'s appcast and forces `CURRENT_PROJECT_VERSION` ≥ upstream's. Cosmetic, harmless — fork build numbers climb in lockstep with upstream's.

4. **`release-pretag-guard.sh` checks against upstream's appcast.** Works on the fork because fork builds track upstream numbering. If upstream skips a build number, the guard may complain spuriously.

5. **`workflow_run.head_branch` is the tag name for tag-triggered runs.** `update-homebrew-tap.yml` relies on this. Don't change the trigger source without updating the version-extraction logic.

6. **The cask token is `cmux-sb`, not `cmux` — deliberately.** The bare token `cmux`
   collides with upstream's **official homebrew/cask `cmux`**, which outranks
   third-party taps, so `brew upgrade cmux` silently resolves to upstream and drops the
   fork. The tap cask was renamed `cmux → cmux-sb` on 2026-06-29 to fix this; the
   tap-updater writes `Casks/cmux-sb.rb` and removes any stale `Casks/cmux.rb`. Install
   and upgrade with `brew install/upgrade --cask sbourass/cmux/cmux-sb`. Both casks still
   install `cmux.app` with bundle id `com.cmuxterm.app`, so the fork and upstream's cmux
   can't be installed at the same time (the `caveats` block documents this) — but the
   distinct token stops `brew upgrade` from silently swapping the fork for upstream.

---

## File pointers

| File | Purpose |
|---|---|
| `scripts/bump-version.sh` | Patched: accepts `-sb.N` suffix. |
| `.github/workflows/fork-release.yml` | Fork-only build/release workflow. |
| `.github/workflows/update-homebrew-tap.yml` | Tap auto-updater. |
| `Resources/Info.plist` | Contains Sparkle keys; `fork-release.yml` strips them at build time. |
| `cmux.xcodeproj/project.pbxproj` | Holds `MARKETING_VERSION` + `CURRENT_PROJECT_VERSION`. |
| `tests/test_ci_sparkle_build_monotonic.sh` | Sparkle build-monotonic guard. Hardcoded to upstream's appcast — ignore on the fork. |
| `docs/build-env.md` | Local build-environment requirements (zig, Metal Toolchain, submodules). |
| `docs/patches.md` | Curated index of the fork's behavioral patches (what + why + how to verify). Updated every release. |
| `docs/per-pane-shell-history.md` | The fork's per-pane shell-history feature spec. |
