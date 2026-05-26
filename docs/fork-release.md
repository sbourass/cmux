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
channel.

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
gh workflow list --repo sbourass/cmux --all | grep -E 'Release macOS app|Nightly|Update Homebrew Cask'
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

# 2. Bump version
./scripts/bump-version.sh patch            # or explicit X.Y.Z-sb.N after a sync

# 3. Pretag guard (checks build number monotonic vs published)
./scripts/release-pretag-guard.sh

# 4. Commit, tag, push
git commit -am "Bump to <new-version>"
git tag v<new-version>
git push origin sb-main v<new-version>

# 5. Watch
gh run watch --repo sbourass/cmux
```

Once `Fork Release` completes, `Update Homebrew Tap` chains off it via
`workflow_run` and rewrites `Casks/cmux.rb` in the tap repo.

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

Then ship a new release with `bump-version.sh <upstream>-sb.1`.

### Recurring conflict files

The `feat/per-pane-shell-history` patch reliably conflicts on these files
during upstream rebase. Resolutions are mechanical — usually combining new
parameter lists.

- `Sources/GhosttyTerminalView.swift`
- `Sources/SessionPersistence.swift`
- `Sources/Workspace.swift`
- `Sources/Panels/TerminalPanel.swift`

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
gh api repos/sbourass/homebrew-cmux/contents/Casks/cmux.rb --jq .content \
  | base64 -d | grep -E 'version|sha256'                   # check cask updated
brew update && brew upgrade --cask sbourass/cmux/cmux      # end-to-end
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

3. **`bump-version.sh` chases upstream's Sparkle build number.** It curls `manaflow-ai/cmux`'s appcast and forces `CURRENT_PROJECT_VERSION` ≥ upstream's. Cosmetic, harmless — fork build numbers climb in lockstep with upstream's.

4. **`release-pretag-guard.sh` checks against upstream's appcast.** Works on the fork because fork builds track upstream numbering. If upstream skips a build number, the guard may complain spuriously.

5. **`workflow_run.head_branch` is the tag name for tag-triggered runs.** `update-homebrew-tap.yml` relies on this. Don't change the trigger source without updating the version-extraction logic.

6. **The `cmux` cask token collides with upstream's tap.** Users must `brew uninstall --cask cmux` from upstream before installing from the fork tap. The cask `caveats` block documents this.

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
| `docs/per-pane-shell-history.md` | The fork's per-pane shell-history feature spec. |
