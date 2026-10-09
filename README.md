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

## Install

One line, on a Mac with macOS 13 or newer:

```bash
curl -fsSL https://raw.githubusercontent.com/ainigh/Gitstick/main/install.sh | bash
```

It downloads the latest release that GitHub built, puts `Gitstick.app` in `~/Applications`, and opens it. Look for the drive icon in the menu bar. If there's no release yet, it builds the app from source instead (that needs Apple's command line tools: `xcode-select --install`). The app is ad-hoc signed, not notarized, so macOS may ask about notifications again after an update.

Easiest sign-in: `brew install gh && gh auth login`, then hit refresh in the menu. Or paste a token in the app.

## Update

Every push to `main` is built by CI and published as a GitHub release (`v0.3.N`). The app checks for a newer release at launch, every 6 hours, and when you choose **Check for Updates…** in the gear menu. When one is ready:

- the **menubar icon turns solid** (the filled drive, with whatever badge the drives' state already shows),
- the menu opens with a **banner** at the top: the version, the commit's title, and an **Update** button.

**Update** downloads the release, swaps the app in place, and reopens it; the drives pick up where they left off, and a notification says which version you're now on. Running the install line again does the same thing. The gear menu always shows the version and commit you're on.

## Run it from source

Requirements: Xcode 15+ or the Swift 5.9+ toolchain, and `git`.

```bash
swift run Gitstick                              # the menubar app, straight from source (no updates, no notifications)
./Scripts/make-app.sh && open dist/Gitstick.app # a proper Gitstick.app, version 0.0.0: it will offer the latest release as an update
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

The tests simulate two Macs sharing one "GitHub" (a bare repo on disk) and check the invariants: drop-and-go, keep-both conflicts (text, binary, file-vs-folder, executable bits), edit-beats-delete, independent changes merging, the Gatekeeper (secrets, nested repos), backing off during a manual merge, waiting out a transient `index.lock`, retrying when someone else pushes first, diverting from a protected branch, joining two first commits into an empty repo, request coalescing, and manual mode's promises (never commits on its own, never touches your index, waits instead of overwriting your uncommitted work, honors your staging on Commit & Sync). The engine and tests also build on Linux; CI runs them on every push, builds the app on macOS, and on `main` publishes the release (`.github/workflows/ci.yml`).

## Roadmap ideas

- Sign in with GitHub's OAuth device flow instead of pasting a token
- Auto-open a pull request when a protected branch diverts work
- Git LFS for large files
- "Format new drive" (create a repo) and branch picker
