# Per-Pane Shell History

cmux can give each terminal pane its own command history file, so the
shell's built-in history (the entries you scroll through with the
<kbd>↑</kbd> arrow) is isolated per pane and survives quitting and
reopening the app.

## Why

By default, every interactive zsh on the machine reads and writes
`~/.zsh_history`. That means pressing <kbd>↑</kbd> in a freshly-opened
pane shows commands from *every other terminal* you have ever used,
not the commands you typed in that specific pane.

With per-pane history enabled:

- Pane A's <kbd>↑</kbd> only shows what you typed in pane A.
- Pane B's <kbd>↑</kbd> only shows what you typed in pane B.
- After you quit cmux and reopen it, the restored pane A still has
  its own history; pane B still has its own; the two never bleed
  into each other.
- A brand-new pane starts with an empty history (clean slate).

## How to enable / disable

**Settings → Terminal → Per-Pane Shell History.**

Default: **ON**.

| State | Behavior |
|---|---|
| ON  | Each pane gets its own `HISTFILE`; history is isolated and persisted per pane. |
| OFF | Pane shells fall back to their default global history file (`~/.zsh_history` for zsh, `~/.bash_history` for bash). |

Toggling takes effect for **new** terminal panes. Existing panes keep
whichever mode their shell was started in — restart the pane (or
close-and-reopen it) to pick up the new setting.

### Settings JSON

UserDefaults key: `terminal.perPaneShellHistory` (`Bool`, default
`true`).

The Settings card exposes this via `configurationReview: .json("terminal.perPaneShellHistory")`,
so you can also configure it from `~/.config/cmux/cmux.json` like any
other cmux setting.

## Where history files live

```
~/Library/Application Support/cmux/panel-history/<uuid>.zsh_history
```

One file per pane, keyed by a stable UUID (`historyFileId`) that
cmux stores in its session snapshot. The same UUID is reused when a
pane is restored after quit, so the same file is reloaded.

The extension is `.zsh_history` for all shells (bash panes use the
same file format; bash doesn't care about the extension).

## Lifecycle

| Event | What happens |
|---|---|
| Pane created (feature ON) | Fresh `historyFileId` UUID is assigned to the surface. `CMUX_PANEL_HISTFILE` is set in the shell's environment. On the first prompt, the cmux integration switches `HISTFILE` to the per-pane file and reads it. |
| Pane created (feature OFF) | The UUID still exists on the surface (for snapshot bookkeeping) but `CMUX_PANEL_HISTFILE` is **not** set. The shell uses its default global history. |
| Command typed | zsh keeps it in memory. With default zsh options, it is written to disk when the shell exits. With `setopt INC_APPEND_HISTORY`, it is written immediately. |
| Quit cmux (clean) | Session snapshot is saved (autosaves also run every 8 s). The PTY is closed → the shell exits normally → its in-memory history is flushed to `HISTFILE`. |
| Relaunch | Snapshot loads. Orphan sweep reaps any history file whose UUID is not referenced by a snapshot (live or `-previous` backup). Restored panes get their saved `historyFileId` back, the env var is re-set, and the integration reloads the same per-pane file. <kbd>↑</kbd> shows the previous session's commands. |
| Close a single pane | The pane's history file is deleted from disk. |
| Close a workspace | All of its panes' history files are deleted (the close-workspace path tears down each pane through the same delete hook). |
| Detach / drag-and-drop a tab to another window | History file is **kept** (the move path explicitly preserves it so the pane's history survives the relocation). |
| Crash, force-quit, power loss | Any commands typed since the shell last wrote may be lost — same as any zsh session. |

## Durability

Per-pane history is as durable as standard zsh: on **clean exit**,
zsh writes its in-memory history to `HISTFILE`. cmux closes the PTY
gracefully on quit, so the shell exits cleanly and the file is
flushed.

If you want **every command** written immediately (so a crash or
force-quit cannot lose anything), add this to your `~/.zshrc`:

```zsh
setopt INC_APPEND_HISTORY
```

That's a plain zsh option and works transparently with per-pane
isolation — each prompt writes to the per-pane `HISTFILE` instead
of the global one.

## What happens when the toggle is OFF

| Question | Answer |
|---|---|
| Are existing per-pane history files deleted when I toggle OFF? | **No.** The toggle only stops setting `CMUX_PANEL_HISTFILE` for **new** panes. Files for currently-open panes survive on disk. |
| What about the shells already running in open panes? | They already switched to the per-pane file on first prompt; they keep writing there for the rest of the pane's life. |
| What about new panes after I toggle OFF? | They get no env var, so zsh/bash uses its default global history file. No isolation. |
| When does cleanup happen? | When a pane is closed, its file is deleted (the close hook runs regardless of toggle state). When you next launch cmux, the orphan sweep removes any file whose UUID isn't referenced by a snapshot. |
| Is there a "Delete all per-pane history" button? | Not currently. If you want to wipe everything, you can do it manually: `rm -rf ~/Library/Application\ Support/cmux/panel-history/`. |

## Known limitations

- **fish shell.** cmux has no fish integration file, so fish users get no per-pane isolation. Fish has its own per-session history system (`$fish_history`); use it if you need similar behavior in fish.
- **`SHARE_HISTORY` + `INC_APPEND_HISTORY` in `.zshrc`.** Commands you type during shell startup (before the first prompt) can land in your global `~/.zsh_history` rather than the per-pane file, because the cmux integration switches `HISTFILE` on the first `precmd` (after `.zshrc` has fully run). Commands typed at the interactive prompt are isolated normally.
- **User overrides win.** If your `.zshrc` calls `fc -p` or sets `HISTFILE` itself **after** the cmux integration runs, your override wins. Treat this as an explicit opt-out.
- **Inner shells.** If you run `bash` (or another `zsh`) inside a per-pane zsh, the inner shell does **not** inherit `CMUX_PANEL_HISTFILE` — cmux unsets it after the first consumption so child shells don't interleave their history into the outer pane's file. Inner shells fall back to default global history.

## How it works (for maintainers)

| File | Role |
|---|---|
| `Sources/GhosttyTerminalView.swift` | `TerminalSurface` owns `let historyFileId: UUID`. The terminal startup env block calls `SessionPanelHistoryStore.historyEnvironment(for:)` and sets `CMUX_PANEL_HISTFILE` — only when `PerPaneShellHistorySettings.isEnabled()` is true. |
| `Sources/Panels/TerminalPanel.swift` | Convenience init plumbs an optional `historyFileId` down to `TerminalSurface`. |
| `Sources/Workspace.swift` | `newTerminalSurface(historyFileId:)` accepts the saved UUID; the save path writes `terminalPanel.surface.historyFileId` into the snapshot; the restore path reads `snapshot.terminal?.historyFileId` and passes it back through. |
| `Sources/SessionPersistence.swift` | `SessionTerminalPanelSnapshot.historyFileId: UUID?` (Codable, default-nil so old snapshots decode cleanly). `SessionPanelHistoryStore` enum: env-var construction, file path resolution, `deleteHistoryFile(for:)`, `sweepOrphans(referenced:)`, and `referencedHistoryFileIds(in:)`. |
| `Sources/Workspace+PanelLifecycle.swift` | `discardClosedPanelLifecycleState(...)` deletes the per-pane file when `closePanel: true`. The contract is documented inline: detach/move paths **must** pass `false`. |
| `Sources/AppDelegate.swift` | `prepareStartupSessionSnapshotIfNeeded` loads the live and `-previous` snapshots (even when restore is disabled), unions their referenced UUIDs, then calls `SessionPanelHistoryStore.sweepOrphans`. If both snapshot loads return `nil`, the sweep is skipped — no reference set means no safe basis to delete. |
| `Sources/App/WorkspaceRuntimeSettings.swift` | `PerPaneShellHistorySettings` enum: `enabledKey`, `defaultEnabled = true`, `isEnabled`, `setEnabled`, `reset`, `notifyDidChange`. Mirrors `AgentSessionAutoResumeSettings`. |
| `Sources/cmuxApp.swift` | `@AppStorage(PerPaneShellHistorySettings.enabledKey)`, a `Binding<Bool>` wrapper that posts `notifyDidChange` on flip, the SwiftUI `Toggle` card in the Terminal section, and the reset-to-defaults wiring. |
| `Resources/shell-integration/cmux-zsh-integration.zsh` | One-shot `precmd` hook `_cmux_history_init` that fires before the first prompt. Sets `HISTFILE`, clears in-memory history via the canonical `HISTSIZE=0; HISTSIZE=$orig` idiom, then `fc -R` reads the per-pane file. `unset CMUX_PANEL_HISTFILE` blocks inner-shell inheritance. Self-removes via `add-zsh-hook -d precmd`. |
| `Resources/shell-integration/cmux-bash-integration.bash` | End-of-integration block (the integration is sourced from `PROMPT_COMMAND` on the first prompt, after `.bashrc`). `HISTFILE="$CMUX_PANEL_HISTFILE"; history -c; history -r 2>/dev/null; unset CMUX_PANEL_HISTFILE`. |

### Why `historyFileId` is separate from `TerminalSurface.id`

`TerminalSurface.id` is a fresh `UUID()` generated each time a surface
is created. When a session snapshot is restored, the new surface gets
a **new** `id` — the snapshot's `id` is not threaded back through the
restore path. That makes `surface.id` unsuitable as a key for files
that need to survive a restart.

`historyFileId` is a separate `UUID` that **is** plumbed through save
and restore, so it's stable across the snapshot round-trip.
