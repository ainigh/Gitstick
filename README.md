# Gitstick 💾

Your GitHub repos as drives in the Mac menubar. Plug one in, drop files in the folder, walk away. Gitstick commits, pulls, merges, and pushes for you, with no messages to write and no dialogs to click.

- **PCs** are your GitHub account and organizations.
- **Drives** are repos. Plugging one in creates `~/Gitstick/<pc>/<drive>`, a normal folder that works in Finder, VS Code, and everything else.
- **Conflicts** never block you: both versions are kept, side by side.
- **Secrets, huge files, and folders that are repos of their own** are held back and flagged, never pushed.
- **You hear about what needs you.** A conflict copy, a held-back file, a protected branch: one notification each, and the item stays in the menu until it's resolved or dismissed. (Notifications and Launch at Login need the bundled `.app`.)
- **Ask before pulling** (optional, per drive). Outgoing stays automatic; incoming shows you what GitHub wants to change in your folder, and you click **Accept** or **Not Now**.
- **Three modes per drive.** *Auto*: drop and go. *Manual*: you commit (or click **Commit & Sync**), and Gitstick pulls when it's safe and pushes your commits. *Paused*: hands off.

See [ARCHITECTURE.md](ARCHITECTURE.md) for how the engine works and the rules it never breaks, and [ORIGIN.md](ORIGIN.md) for the note that started it.

## Run it

Requirements: macOS 13+, Xcode 15+ or the Swift 5.9+ toolchain, and `git`.

```bash
# Easiest sign-in: reuse the GitHub CLI (or paste a token in the app instead)
brew install gh && gh auth login

# Run the menubar app straight from source
swift run Gitstick

# …or build a proper Gitstick.app (no Dock icon, can live in /Applications)
./Scripts/make-app.sh && open dist/Gitstick.app
```

You can also open `Package.swift` in Xcode and run the `Gitstick` scheme.

## The engine without the UI

The same engine powers a small CLI, which is handy for trying it on an existing clone:

```bash
swift run gitstick pcs              # list your PCs and drives
swift run gitstick sync   ~/code/x            # one sync cycle (auto mode)
swift run gitstick watch  --manual ~/code/x   # keep synced; you commit, it pulls/pushes
swift run gitstick commit ~/code/x            # "Commit & Sync": staged files, or everything
swift run gitstick sync   --review ~/code/x   # push yours; show GitHub's changes instead of merging them
swift run gitstick accept ~/code/x            # …then bring them in (or `decline` to hold them off)
swift run gitstick status ~/code/x            # uncommitted / to push / to pull, no network
```

## Tests

```bash
swift test
```

The tests simulate two Macs sharing one "GitHub" (a bare repo on disk) and check the invariants: drop-and-go, keep-both conflicts (text, binary, file-vs-folder, executable bits), edit-beats-delete, independent changes merging, the Gatekeeper (secrets, nested repos), backing off during a manual merge, waiting out a transient `index.lock`, retrying when someone else pushes first, diverting from a protected branch, joining two first commits into an empty repo, request coalescing, and manual mode's promises (never commits on its own, never touches your index, waits instead of overwriting your uncommitted work, honors your staging on Commit & Sync). The engine and tests also build on Linux; CI runs them on every push (`.github/workflows/ci.yml`).

## Roadmap ideas

- Sign in with GitHub's OAuth device flow instead of pasting a token
- Auto-open a pull request when a protected branch diverts work
- Git LFS for large files
- "Format new drive" (create a repo) and branch picker
