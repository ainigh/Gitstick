# Gitstick — Architecture

> Plug a repo in like a USB stick. Drop files. Walk away.

GitHub accounts and organizations are **PCs**. Their repositories are **drives**. Plugging in a drive puts a real folder on your Mac at `~/Gitstick/<pc>/<drive>`; from then on, anything that changes in that folder ends up on GitHub, and anything that changes on GitHub ends up in that folder, without a single question being asked.

This document covers only the parts that are hard and must stay true. UI, settings, and plumbing are left out on purpose.

## The one rule

**Git never talks to the human. Gitstick decides.** Every place where Git would normally stop and ask (commit message, merge message, conflict, credentials, protected branch) has a default decision, written down below. If a new feature introduces a prompt, it is a bug.

## The engine

```
 Finder / VS Code / any app
            │  file events
            ▼
   ┌─────────────────┐   burst of events   ┌───────────┐   one request   ┌──────────────┐
   │  FolderWatcher  │ ──────────────────▶ │ Debouncer │ ──────────────▶ │  RepoSyncer  │ ◀── 60s poll
   │ (FSEvents, .git │                     │ quiet 3s, │                 │ (serial per  │
   │   ignored)      │                     │ max 30s   │                 │   drive)     │
   └─────────────────┘                     └───────────┘                 └──────┬───────┘
                                                                                │
                              guard → snapshot → fetch → integrate → push ◀─────┘
                                │        │                   │          │
                         human active?  Gatekeeper    ConflictResolver  divert if
                         → pause        holds back    (keep both)       protected
```

### The sync cycle

Every cycle runs the same five steps in the same order. The order is the design.

1. **Guard.** If a human is mid-operation in this repo (a merge, rebase, cherry-pick, or bisect in progress, or `index.lock` held by another git process), stop and report *paused*. Gitstick is a guest in your repo; it never fights the terminal or VS Code.
2. **Snapshot.** `add -A`, let the Gatekeeper unstage anything risky, then commit with a generated message. This happens *before* anything remote is touched.
3. **Fetch.**
4. **Integrate.** Fast-forward if possible, otherwise make a real merge commit. Conflicts go to the ConflictResolver. Unrelated histories (two Macs both making the first commit into an empty repo) are joined, not refused.
5. **Push** to the same branch. If someone pushed in between, go back to step 3 (up to 3 times). If the branch is protected or read-only, *divert*.

## Invariants

These are what the tests check. Each one exists because breaking it either loses data or brings back a prompt.

**I1 — Commit before integrate.** Local work is always committed before a merge can touch the working tree. A commit is the only state Git guarantees it can always get back to, so once your file is in a commit, nothing downstream can destroy it. *Consequence:* no stash, no `pull --autostash`, no rebase of local work.

**I2 — No byte is lost in a conflict.** When both sides changed a file, the remote version keeps the original name and the local version is saved next to it as `name (conflict from <Mac> <date>).ext`. Both are committed. When one side edited and the other deleted, the edit wins (a delete is cheap to redo, and it's still in history). Gitstick never picks a loser, so it never needs to ask.

> Why the remote keeps the name: collaborators who didn't touch anything see no surprise; the person whose Mac had the conflict is the one who gets the visible copy, and they're the one with context to reconcile it.

**I3 — Never rewrite published history.** No force-push, no rebase, no amend of anything that has left the Mac. Merge commits make the history a little noisier; force-push would make it wrong.

**I4 — Never prompt.** Every git call runs with terminal prompts, editors, and askpass disabled. Commit messages are generated (`Add index.html`, `Add 2 files, update style.css`, with the full path list in the body). Merge messages are generated. Credentials come from the Keychain, `$GITHUB_TOKEN`, or the GitHub CLI, and are passed as a per-command header, so nothing is written to `.git/config`.

**I5 — Back off from humans.** See step 1 of the cycle. If you start a rebase in the terminal, Gitstick waits for you to finish rather than committing into the middle of it.

**I6 — When in doubt, hold back.** A wrong auto-commit is permanent and possibly public; a held-back file is a yellow line in the menu. The Gatekeeper refuses:
- secret-looking files by name (`.env`, `id_rsa`, `*.pem`, `*.p12` …)
- secret-looking content (private keys, GitHub/AWS/Slack/Stripe/Anthropic tokens)
- files over 50 MB (GitHub's warning threshold; the hard rejection is at 100 MB)

Held-back files stay on disk, untouched, and are reported on every cycle. Junk (`.DS_Store`, editor swap files, Office lock files, `node_modules/`) is excluded via `.git/info/exclude`, which is local-only, so Gitstick never edits the repo's own `.gitignore` behind your back.

**I7 — One cycle at a time per drive; requests coalesce.** Each drive has a serial queue. Any number of requests during a running cycle collapse into exactly one follow-up cycle, so a 500-file drag-and-drop produces one or two commits, not 500.

**I8 — A failed cycle leaves the tree as it found it.** If integration fails partway through, the merge is aborted. The next cycle starts clean; your files are still in the commit from I1.

**I9 — Protected means divert, not fail.** If a push is refused by branch protection, the work is pushed to `gitstick/<mac-name>` instead and the drive shows *diverted*. Your files are on GitHub and nobody's rules were broken. (A later version can open the pull request automatically.)

## Components

| File | Responsibility |
|---|---|
| `Git.swift` | Non-interactive `git` runner. Binary-safe output, auth header, no prompts (I4). |
| `RepoSyncer.swift` | The cycle and the state machine (I1, I3, I5, I7, I8, I9). |
| `ConflictResolver.swift` | Keep-both policy over index stages 2 (ours) and 3 (theirs) (I2). |
| `Gatekeeper.swift` | Local excludes, secret and size checks (I6). |
| `CommitMessage.swift` | Deterministic messages from `--name-status`. |
| `Watcher.swift` | FSEvents watcher (macOS), polling watcher (elsewhere), debouncer. |
| `DriveManager.swift` | Plug in (partial clone, `--filter=blob:none`), eject (final sync), persistence. |
| `GitHub.swift` | Token sources, and listing PCs and drives from the API. |

## Known gaps (deliberate for v0.1)

- **Staging is owned by Gitstick.** If you carefully stage half a change in VS Code, the next cycle commits all of it. A future "manual" mode per drive will leave the index alone.
- **One branch per drive** (the one checked out). Switching branches by hand works; Gitstick follows whatever `HEAD` is.
- **Held-back untracked files vs. remote.** If GitHub gains a file at the same path as a held-back local file, the merge refuses (it would overwrite) and the drive shows an error until you rename or delete the local file.
- **Large files** are held back rather than sent through Git LFS.
- **Rename/rename conflicts** fall back to keeping whichever side Git staged.
- **No virtual filesystem.** Drives are real folders (full working tree, with history fetched lazily). That keeps every app compatible. A File Provider extension for lazy file contents is a possible later layer on top of this engine, not a replacement.
