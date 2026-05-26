# Local Build Environment

Captured on macOS 26 / Xcode 26.5 (2026-05-26). cmux's main upstream build
instructions in `CLAUDE.md` work on most setups, but the fork release pipeline
requires a few extra pieces that aren't documented there.

If your build fails before the Swift compiler runs, you're probably missing
something from this list.

---

## Required (one-time setup)

### 1. Zig 0.15.2 (the ghostty submodule pins it)

Homebrew's stable `zig` is currently 0.16.x, which is **incompatible**. Install
the keg-only `zig@0.15`:

```bash
brew install zig@0.15
```

It lives at `/opt/homebrew/opt/zig@0.15/bin/zig` and is **not** symlinked into
PATH by default (keg-only). You'll prepend it when building (see [Building](#building)).

Verify:

```bash
/opt/homebrew/opt/zig@0.15/bin/zig version  # expect: 0.15.2
```

Symptoms of having the wrong zig:

- `error: Your Zig version v0.16.x does not meet the required build version of v0.15.2` — clear signal.
- `undefined symbol: _free` / `_fork` / `_malloc_size` etc. during `build_zcu.o` link — confusing signal but same root cause (mismatched zig).

### 2. Metal Toolchain (Xcode 26 ships without it)

```bash
xcodebuild -downloadComponent MetalToolchain
```

~690 MB download. Without it, ghostty's metal shader compile step fails with:

```
error: cannot execute tool 'metal' due to missing Metal Toolchain;
       use: xcodebuild -downloadComponent MetalToolchain
```

### 3. Submodules

If you're in a git worktree (not the main checkout), submodules don't
auto-initialize:

```bash
git submodule update --init --recursive
```

Cmux uses three submodules: `ghostty`, `homebrew-cmux`, `vendor/bonsplit`. All
are required for a full build. `setup.sh` runs this for you in the main
checkout but does not run automatically in worktrees you create later.

---

## Building

Prepend zig@0.15 to PATH, then run the normal reload script:

```bash
PATH="/opt/homebrew/opt/zig@0.15/bin:$PATH" ./scripts/reload.sh --tag sb-sync
```

Use a tag-bound build to avoid colliding with any untagged debug app
(`cmux DEV.app`). The script terminates any prior app with the same tag and
prints the new `.app` path. See `CLAUDE.md` for the full tag conventions.

To make this persistent, add to your shell profile:

```bash
# ~/.zshrc or ~/.bashrc
export PATH="/opt/homebrew/opt/zig@0.15/bin:$PATH"
```

This only matters when building. Don't add it to a shared profile if you also
work on other zig 0.16+ projects.

---

## Things that look broken but aren't

- **`reload.sh` says "dirty" ghostty state and rebuilds the xcframework.** The "dirty-<hash>" suffix is appended to the ghostty build key when the submodule's working tree has untracked files (e.g., a `.zig-cache/` or `zig-pkg/` directory). Clean it with `git -C ghostty clean -fdx` and rerun. The cached xcframework download will be reused.
- **Sparkle/Sentry 404 in CI.** Transient GitHub CDN issue during SPM package resolution. Re-run the failed job with `gh run rerun <id> --failed`. Doesn't happen locally.
