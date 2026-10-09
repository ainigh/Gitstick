# Gitstick — Architecture

> Plug a repo in like a USB stick. Drop files. Walk away.

GitHub accounts and organizations are **PCs**. Their repositories are **drives**. Plugging in a drive puts a real folder on your Mac at `~/Gitstick/<pc>/<drive>`; from then on, anything that changes in that folder ends up on GitHub, and anything that changes on GitHub ends up in that folder, without a single question being asked.

This document covers only the parts that are hard and must stay true. UI, settings, and plumbing are left out on purpose.

## The one rule

**Git never talks to the human. Gitstick decides.** Every place where Git would normally stop and ask (commit message, merge message, conflict, credentials, protected branch) has a default decision, written down below. If a new feature introduces a prompt, it is a bug.

## Modes

Each drive has a mode, switchable at any time from its menu:

| | **Auto** | **Manual** | **Paused** |
|---|---|---|---|
| Who commits | Gitstick, everything | You (VS Code, terminal, or one-click **Commit & Sync**) | — |
| Your index (staging) | Owned by Gitstick | Never touched | Never touched |
| A file edit triggers | a full sync (after 3 s quiet) | a local count refresh only — no network, no writes | a local count refresh |
| A commit (HEAD moves) triggers | a sync | a sync within ~1 s: pull-if-safe, then push | nothing |
| Every 60 s | sync | sync | nothing |
| Default for | repos you can write to | read-only and archived repos | — |

Manual is the mode for repos where history is communication: you write the commit messages and choose what goes into each commit, and Gitstick only does the pulling and pushing.

**Commit & Sync** is the bridge between the two. In manual mode it commits *what you staged*, or everything if you staged nothing, with a generated message, and then syncs. Your staging is a decision, so it's honored. The Gatekeeper still applies, because Gitstick is the one making that commit.

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
2. **Snapshot** (auto mode, or Commit & Sync). Stage, let the Gatekeeper unstage anything risky, then commit with a generated message. This happens *before* anything remote is touched. In manual mode without Commit & Sync, this step is skipped entirely.
3. **Fetch.**
4. **Integrate.** Fast-forward if possible, otherwise make a real merge commit. Conflicts go to the ConflictResolver. Unrelated histories (two Macs both making the first commit into an empty repo) are joined, not refused. If git refuses because the merge would overwrite uncommitted or untracked files, or if the index has staged changes, the cycle stops in **waiting** and names the files in the way. Nothing has been changed at that point.
5. **Push** to the same branch. If someone pushed in between, go back to step 3 (up to 3 times). If the branch is protected or read-only, *divert*.

## Invariants

These are what the tests check. Each one exists because breaking it either loses data or brings back a prompt.

**I1 — Commit before integrate.** Whatever Gitstick commits is committed before a merge can touch the working tree. A commit is the only state Git guarantees it can always get back to, so once your file is in a commit, nothing downstream can destroy it. *Consequence:* no stash, no `pull --autostash`, no rebase of local work.

**I2 — No byte is lost in a conflict.** When both sides changed a file, the remote version keeps the original name and the local version is saved next to it as `name (conflict from <Mac> <date>).ext`. Both are committed. When one side edited and the other deleted, the edit wins (a delete is cheap to redo, and it's still in history). When one side made `name` a file and the other a folder, the folder stays and the file becomes a conflict copy (`(conflict from <Mac> …)` if it was ours, `(conflict from GitHub …)` if it came from the remote). Gitstick never picks a loser, so it never needs to ask.

> Why the remote keeps the name: collaborators who didn't touch anything see no surprise; the person whose Mac had the conflict is the one who gets the visible copy, and they're the one with context to reconcile it.

**I3 — Never rewrite published history.** No force-push, no rebase, no amend of anything that has left the Mac. Merge commits make the history a little noisier; force-push would make it wrong.

**I4 — Never prompt.** Every git call runs with terminal prompts, editors, and askpass disabled. Commit messages are generated (`Add index.html`, `Add 2 files, update style.css`, with the full path list in the body). Merge messages are generated. Credentials come from the Keychain, `$GITHUB_TOKEN`, or the GitHub CLI, and are passed as a per-command header through the environment (`GIT_CONFIG_COUNT`), so nothing is written to `.git/config` and the token never appears in the process list.

**I5 — Back off from humans.** See step 1 of the cycle. If you start a rebase in the terminal, Gitstick waits for you to finish rather than committing into the middle of it. A bare `index.lock` is given two seconds to disappear first: VS Code's background `git status` and a quick `git add` hold it for a moment, and that is not someone at work.

**I6 — When in doubt, hold back.** A wrong auto-commit is permanent and possibly public; a held-back file is a yellow line in the menu. The Gatekeeper refuses:
- secret-looking files by name (`.env`, `id_rsa`, `*.pem`, `*.p12` …)
- secret-looking content (private keys, GitHub/AWS/Slack/Stripe/Anthropic tokens)
- files over 50 MB (GitHub's warning threshold; the hard rejection is at 100 MB)
- folders that are a git repository of their own (a dragged-in project with its `.git`): git would commit them as an empty pointer, and every other Mac would see an empty folder

Held-back files stay on disk, untouched, and are reported on every cycle. Junk (`.DS_Store`, editor swap files, Office lock files, `node_modules/`) is excluded via `.git/info/exclude`, which is local-only, so Gitstick never edits the repo's own `.gitignore` behind your back.

**I7 — One cycle at a time per drive; requests coalesce.** Each drive has a serial queue. Any number of requests during a running cycle collapse into exactly one follow-up cycle, so a 500-file drag-and-drop produces one or two commits, not 500. A Commit & Sync request is sticky: it survives coalescing until a cycle actually performs it.

**I8 — A failed cycle leaves the tree as it found it.** If integration fails partway through, the merge is aborted. The next cycle starts clean; your files are still in the commit from I1.

**I9 — Protected means divert, not fail.** If a push is refused by branch protection, the work is pushed to `gitstick/<mac-name>` instead and the drive shows *diverted*. Your files are on GitHub and nobody's rules were broken. (A later version can open the pull request automatically.)

**I10 — Manual means hands off your work.** In manual mode Gitstick never creates a commit on its own, never changes your index, and only merges when git can do so without touching a single uncommitted file. When that isn't possible, the drive shows *waiting* ("2 changes on GitHub touch notes.md — commit to pull") until you commit, and then the ordinary keep-both rules apply. Two mechanisms enforce this. First, git's own refusal to overwrite local changes is treated as a clean "not yet," never as an error or a reason to stash. Second, Gitstick never merges over a non-empty index, because conflict resolution commits the index and would otherwise swallow what you staged.

**I11 — Waiting is not an error.** A pull that would collide with local work leaves the repo exactly as it was and is retried on the next cycle. Your unpushed commits simply wait with it, since GitHub would reject them until the pull lands. This applies in auto mode too, when a held-back file sits where GitHub wants to put a file.

## Components

| File | Responsibility |
|---|---|
| `Git.swift` | Non-interactive `git` runner. Binary-safe output, auth header, no prompts (I4). |
| `RepoSyncer.swift` | Modes, the cycle, and the state machine (I1, I3, I5, I7–I11). |
| `ConflictResolver.swift` | Keep-both policy over index stages 2 (ours) and 3 (theirs) (I2). |
| `Gatekeeper.swift` | Local excludes, secret and size checks (I6). |
| `CommitMessage.swift` | Deterministic messages from `--name-status`. |
| `Watcher.swift` | FSEvents watcher (macOS) and polling watcher (elsewhere), both reporting *file edited* vs *HEAD moved*; debouncer. |
| `DriveManager.swift` | Plug in (partial clone, `--filter=blob:none`), eject (final sync), per-drive mode, persistence. |
| `GitHub.swift` | Token sources, and listing PCs and drives from the API. |

## Known gaps

- **One branch per drive** (the one checked out). Switching branches by hand works; Gitstick follows whatever `HEAD` is.
- **Manual mode doesn't watch the network for you.** "N to pull" reflects the last fetch, which happens every 60 s and after each of your commits.
- **Large files** are held back rather than sent through Git LFS.
- **Rename/rename conflicts** fall back to keeping whichever side Git staged.
- **Nested repositories** are held back, not synced. Delete the inner `.git` (or make it a submodule yourself) to sync its files.
- **No virtual filesystem.** Drives are real folders (full working tree, with history fetched lazily). That keeps every app compatible. A File Provider extension for lazy file contents is a possible later layer on top of this engine, not a replacement.

Closed in 0.2: *staging is owned by Gitstick* (now only in auto mode) and *held-back files block a pull with an error* (now a harmless *waiting*).
