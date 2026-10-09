# Gitstick 💾

Your GitHub repos as drives in the Mac menubar. Plug one in, drop files in the folder, walk away. Gitstick commits, pulls, merges, and pushes for you, with no messages to write and no dialogs to click.

- **PCs** are your GitHub account and organizations.
- **Drives** are repos. Plugging one in creates `~/Gitstick/<pc>/<drive>`, a normal folder that works in Finder, VS Code, and everything else.
- **Conflicts** never block you: both versions are kept, side by side.
- **Secrets and huge files** are held back and flagged, never pushed.

See [ARCHITECTURE.md](ARCHITECTURE.md) for how the engine works and the rules it never breaks.

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
swift run gitstick sync  ~/code/x   # one sync cycle
swift run gitstick watch ~/code/x   # keep a folder synced until Ctrl-C
```

## Tests

```bash
swift test
```

The tests simulate two Macs sharing one "GitHub" (a bare repo on disk) and check the invariants: drop-and-go, keep-both conflicts, edit-beats-delete, independent changes merging, the Gatekeeper, backing off during a manual merge, and retrying when someone else pushes first. The engine and tests also build on Linux, so they can run in CI.

## Roadmap ideas

- Sign in with GitHub's OAuth device flow instead of pasting a token
- Notifications for conflicts and held-back files (needs the bundled .app)
- Auto-open a pull request when a protected branch diverts work
- Per-drive "manual" mode that leaves staging to you
- Launch at login (`SMAppService`)
- Git LFS for large files
- "Format new drive" (create a repo) and branch picker
