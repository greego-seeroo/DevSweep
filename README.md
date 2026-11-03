# DevSweep

A macOS app that finds the build caches, package caches and toolchain junk that
development leaves behind, tags each one **Safe** / **Review** / **Protected**,
and moves what you pick to the Trash.

It does not care what you write. Xcode, Gradle, npm, pnpm, Cargo, Go, pip, uv,
Poetry, conda, Bundler, NuGet, Composer, Maven, CocoaPods, SwiftPM, Homebrew,
Docker, JetBrains, VS Code, Unity, Unreal, Hugging Face — about 120 known
locations, and it only shows you the ones that actually exist on your machine.
A Rust developer sees Rust. A Python developer sees Python. Someone who does
both sees both.

Since 1.1 there is a second sweep for everyone else: **System Data** mode looks
at the places macOS files under "System Data" in Settings ▸ Storage — app caches,
logs and diagnostics, iPhone and iPad backups — and names each app cache after
the app it belongs to ("Spotify", not `com.spotify.client`). If the Developer
scan finds nothing on a Mac, the app switches to System Data by itself.

DevSweep ships on the Mac App Store and runs inside the App Sandbox. The first
thing it asks for is your Home folder; see *Folder access* below.

---

## Folder access

The App Store build is sandboxed, so it can read nothing until you grant it a
folder. The welcome screen ends in a standard Open panel pointed one level above
your Home folder, so granting Home is one click. The grant is stored as a
security-scoped bookmark and survives relaunches; *Folders* in the header lists
every granted folder and lets you reveal or remove one.

Granting only a subfolder (say `~/Projects`) still works, but only for project
artifacts inside it: the catalog of cache locations is home-relative and needs
the Home grant. A banner says so and offers to add Home.

Nothing is sent anywhere. There is no network code in the app.

## Disk space

The header shows the boot volume: how much is free, how much it holds, and a bar
of used ▸ selected ▸ free. Ticking rows lights up a green segment — that is the
space you would get back.

*Would*, not *will*. Moving a file to the Trash frees nothing; the bytes are still
on the disk until the Trash is emptied. So DevSweep never claims otherwise: while
anything is sitting in the Trash the footer says how much, and reminds you that
the disk does not get it back until you empty it. The app watches `~/.Trash`, so
emptying it in Finder updates the numbers within a second or two even while
DevSweep is frontmost. (In the App Store build the watcher starts at launch, so
on the very first run, before the Home grant exists, the numbers refresh when
you return to DevSweep instead; from the next launch on it is live.) Free space is the larger of Finder's figure
(`volumeAvailableCapacityForImportantUsage`, which counts purgeable space) and
the plain filesystem figure, so a fresh deletion shows immediately.

## The safety model

This is the part that matters for a tool that deletes things.

**Nothing is ever deleted outright.** Every action goes through
`FileManager.trashItem`. Items land in `~/.Trash` and stay recoverable until you
empty it. There is no permanent-delete code path in the app. Because Trash on the
same volume is a rename, even a 30 GB `DerivedData` moves instantly.

The one exception is the prune tools, described below. They are separated out,
labelled, and confirmed individually, precisely because they break this rule.

**Every path passes an independent guard before it moves.** `SafetyGuard` in
[Sources/Core/Models.swift](Sources/Core/Models.swift) is checked twice — once when a row
is offered for selection, and again at the moment of deletion. It refuses
anything that is not strictly inside your home directory, anything containing
`..`, any symlink that resolves outside home, and anything on an explicit
protected list:

- **Credentials and keys** — `~/.ssh`, `~/.gnupg`, `~/.aws`, `~/.azure`,
  `~/.config/gcloud`, `~/.password-store`, `~/.netrc`, `~/Library/Keychains`,
  `~/Library/MobileDevice`, and `~/.gem/credentials`, which is your RubyGems API
  key sitting in the middle of a directory that is otherwise a cache.
- **Editor settings** — Xcode's `UserData` and `Templates`, VS Code's, Cursor's
  and Windsurf's `User` folders, all of `~/Library/Application Support/JetBrains`.
  Losing these loses your setup, which is not a build you can re-run.
- **Container directories** — `~/Library/Caches`, `~/.cargo`, `~/go/pkg`,
  `~/.cache` and about seventy others that must never be removed wholesale. Only
  their children may be.
- **Sandboxed app data** — `~/Library/Containers` and `~/Library/Group
  Containers`, which is where Docker keeps its disk image and where Safari and
  Mail keep theirs.

The guard does not trust the catalog: if a rule pointed at one of these, the guard
would still stop it. Be clear about what that means, though. The guard is a
denylist inside your home folder. A path that is inside home and on neither list
passes, so for everything else — `~/Library/Mail`, your dotfiles, your documents —
the protection is the catalog being right, plus the Trash.

Home itself is always the real `/Users/you`, read from the passwd entry. Under
the sandbox `NSHomeDirectory()` returns the app's container, and the guard never
uses it.

## What the tags mean

| Tag | Meaning |
| --- | --- |
| **Safe** | Leftover files your tools rebuild automatically. Deleting them costs nothing but one slower build. |
| **Review** | Comes back too, but slowly — a big download or a long rebuild. Each row says what it costs. Read before ticking. |
| **Protected** | Settings, credentials, the tools themselves. Shown greyed out with a lock, so you can see they were considered and skipped. Cannot be selected. |

If you don't want to think about any of this, press the big button twice: the
first press selects everything Safe, the second shows you the list it is about
to move. Confirm, and it all goes to the Trash.

The results of the last scan are remembered, so the window opens with rows on
it straight away — the status line says how old they are — and the scan that
starts at once refreshes them in place. A remembered row whose folder has since
gone is dropped before it is shown. The record lives in the app's own
Application Support folder, inside its sandbox container; nothing is written to
your home folder. The same applies when you switch between Developer and
System Data: whatever that mode found last time appears instantly.

You never have to wait for a scan to finish. Rows appear as their folders are
measured, and any row on screen can be ticked and moved to the Trash while the
rest of the scan is still running: the guard re-checks every path at the moment
it moves, and a folder that goes to the Trash mid-measurement is simply dropped
from the results. Once only a few folders are left, the status line names them
— "still measuring CocoaPods spec repos" — so a long wait is never a mystery.

Notable **Review** calls, and why they aren't Safe:

- **Xcode Archives** hold the dSYMs for builds you shipped. Delete them and you
  can no longer symbolicate crash reports from those versions.
- **iOS DeviceSupport** comes back on its own, but Xcode re-extracts symbols
  slowly the next time you plug in a device on that iOS build.
- **Simulator devices** contain every app you installed and its data. Prefer
  *Tools ▸ Delete unavailable simulators*, which removes only devices whose
  runtime is already gone — those cannot boot, so nothing is lost.
- **Virtualenvs** (Poetry, Pipenv, a project's own `.venv`) rebuild from a lock
  file, but every dependency downloads again.
- **Conda environments** rebuild only if you kept an `environment.yml`.
  Otherwise the exact package set is gone.
- **Hugging Face and Ollama models** re-download on demand — at several
  gigabytes each.
- **Unity's `Library`** is an import cache, but reimporting a large project takes
  a very long time.
- **Flutter SDK cache** restores via `flutter precache`, but `flutter` will not
  run until that download finishes.
- **iPhone and iPad backups** (System Data mode) cannot be rebuilt from the Mac
  at all. They are Review rather than Protected only so that you *can* remove a
  backup of a device you no longer own.

## Put Back

After a cleanup the banner offers **Put Back**. It moves every item from that
cleanup out of the Trash and back to exactly where it came from, skipping any
item whose original location has since been recreated (a tool rebuilt the
directory) so nothing is ever overwritten. Items it skips stay in the Trash.

Put Back covers the most recent cleanup only, and the record of it lives in
memory: it survives rescans and mode switches, but quitting the app forgets it.
Finder's own *Put Back* still works on every item regardless.

## Prune tools

Some space cannot be reclaimed by moving a directory to the Trash. Docker keeps
everything inside a disk image in `~/Library/Containers`, which the guard refuses
to touch — and trashing that image would destroy every image, container and
volume you have in one move. Homebrew's old versions are scattered through the
Cellar. The only sane way to reclaim these is to ask the tool to clean up after
itself.

*Tools ▸ Run a tool's own cleanup* lists whichever of these are installed, with
the size each one reports it could reclaim:

| Tool | Runs | Removes |
| --- | --- | --- |
| Simulators | `xcrun simctl delete unavailable` | Devices whose runtime is gone. They cannot boot, so nothing usable is lost. |
| Docker | `docker system prune -f` | Stopped containers, dangling images, unused networks, build cache. Running containers, tagged images and named volumes are left alone. |
| Homebrew | `brew cleanup` | Outdated downloads and the old versions of formulae you have upgraded. |
| Nix | `nix-collect-garbage -d` | Unreachable store paths and old profile generations. |

**These do not go through the Trash.** The space comes back immediately and there
is nothing to restore. Each one confirms separately; the ones that could remove
something you might want back (everything but the simulator cleanup, which only
removes devices that can no longer boot) say so before they run.

**The App Store build cannot offer them.** The sandbox does not allow launching
other programs, so the sandboxed app never probes for these tools and the menu
only ever shows the placeholder. They are available in an unsandboxed build from
source. The app looks for them after a Developer scan; the menu keeps whatever
it last found until the next Developer scan. The same limit applies to the runtime discovery
of the Flutter SDK and Go caches: sandboxed, the app checks the usual locations
instead of asking `flutter` and `go` where they are.

## Project artifacts

Your repositories are found automatically. There is nothing to configure: the
scanner walks the folders you granted (Home, normally) and reports the build
output inside whatever it finds — `build`, `target`, `node_modules`, `dist`,
`.next`, `Pods`, `.gradle`, `.venv`, `bin`/`obj`, `vendor`, `_build`, `.tox`,
Unity's `Library`, Unreal's `Intermediate`, and about twenty more.

The walk is fast because it skips `~/Library`, `~/Applications`, `~/Pictures`,
`~/Movies`, `~/Music`, `~/.Trash` and every dot-folder outright, goes at most
seven levels deep, and stops descending the moment it finds something it is
going to offer you. It also stops after 800 hits. That is cheaper than asking
you where your code lives, so it doesn't ask.

A directory only counts if its **parent carries the matching project marker** —
`target` next to a `Cargo.toml` or `pom.xml`, `node_modules` next to a
`package.json`, `bin` next to a `.csproj`, Unity's `Library` next to *both*
`Assets` and `ProjectSettings`. A source folder that happens to be named `build`,
a `dist` of hand-written HTML, a `bin` full of shell scripts, a personal notes
folder called `Library` — all left alone. The name is never enough on its own.
The walker also refuses any name that is not on the guard's own allowlist of
build-output names, so the catalog cannot teach it a new one by itself.

If you want somewhere skipped, *Tools ▸ Exclude a folder from project scanning…*
It persists between launches. Most people will never need it.

## Measured on a development machine

A real scan from 1.0, verified against the filesystem:

```
reclaimable:  89.12 GB
tagged safe:  52.31 GB
scan time:    13.4 s

JVM & Gradle       24.67 GB   (Gradle caches 18.58 GB, distributions 5.98 GB)
Android            17.84 GB   (AVDs 3.15 GB, system images 2.31 GB)
Flutter & Dart     16.99 GB   (FVM SDKs 7.32 GB, pub cache 4.37 GB)
Xcode              16.00 GB   (DerivedData 9.5 GB, iOS DeviceSupport 5.94 GB)
Simulators         14.56 GB
Project artifacts   7.93 GB   (104 build dirs across ~/StudioProjects)
Node & web          1.97 GB
Package managers    1.01 GB
Ruby              423.1 MB
Other caches      202.9 MB
```

`~/Library/Android/sdk` (11.67 GB), the rbenv interpreters and the nvm Node
versions are all correctly excluded as **Protected**. Sizing has since moved
in-process (see *Caveats*) and the same scan now takes a few seconds.

## Building

```
Scripts/build.sh         swiftc → DevSweep.app, signed and sandboxed
Scripts/test.sh          the fast suite
Scripts/test.sh --live   adds checks that scan this machine's real caches
Scripts/make-dmg.sh      wraps DevSweep.app in a DMG (same-machine use only, see Caveats)
```

There are two ways to build and they produce the same app:

- **`Scripts/build.sh`** compiles everything under `Sources/` with `swiftc`, generates the icon,
  and code-signs. It reads the version and build number out of the Xcode
  project, so the values typed into Xcode are the single source of truth.
- **`DevSweep.xcodeproj`** is what the App Store archive comes from. It compiles
  the same files and runs the same icon script.

`Scripts/build.sh` signs with the Apple Development certificate that belongs to the
project's team (`DEVELOPMENT_TEAM` in the project file), not merely the first one
in the keychain, so the script build and the Xcode build share a signature and
macOS keeps your folder grants across rebuilds. Set `SIGN_ID` to override. With
no matching certificate it falls back to ad-hoc signing, and macOS will re-ask
for folder access after every rebuild.

## Testing

The suite is built around the one question that matters: **can the app ever
touch something important?** It attacks each layer that stands between a bug and
your files:

- The guard is fed a sample of protected paths from every category, traversal
  tricks (`../../etc/passwd`), paths outside home, and a symlink that points out
  of your home directory. All must be refused.
- `Scanner.trash` is handed `~/.ssh`, `~/Documents`, `~/Library` and `/etc`
  directly — simulating a catalog, model and UI that have *all* failed. The
  guard inside the trash function is the last line, and the tests verify every
  attack is refused, reported, and the directories untouched.
- The project walker runs against a fixture tree of real projects (Rust, Node,
  .NET, Python, Unity, Flutter) and traps: a source folder named `build`, a
  `dist` of plain HTML, a notes folder named `Library`, a `bin` of shell
  scripts, a symlinked `node_modules`. The real ones must be found; the traps
  must never be.
- Both catalogs are checked for integrity: every rule's group is known, no path
  is absolute or traverses upward, every rule passes the guard, and in System
  Data mode only Logs may be tagged Safe.
- The sizer, cancellation, disk-space reads, size parsing, in-place row removal,
  the auto-switch rule and friendly app names each have their own section. The
  sharded sizer is checked against the single walk and against `du`, its
  progress callbacks for consistency, a walk whose folder is trashed half-way
  for surviving it, and streamed rows for merging into the list correctly.
- A real round-trip: a fixture directory is moved via the same code path the
  app uses, verified to land in the Trash, put back with its contents intact,
  then cleaned up. An end-to-end "user journey" does scan → clean → Put Back →
  rescan on a fixture project.
- `--live` scans the machine's actual caches in both modes and asserts every
  offered row passes the guard, none is a loose file, no row contains or
  duplicates another, and streamed progress never overshoots.

168 checks without `--live`, currently all green. The suite is a plain Swift
script with no XCTest; it compiles `Sources/Core` only. `--live` adds the
real-machine scans and a second program, `Tests/Model`, that compiles the view
model with the core and drives it headlessly: it moves a fixture row to the
Trash while a real scan is still measuring and checks the row stays gone, the
undo survives a rescan, and Put Back restores it. The UI, the welcome sheet and
real sandbox behaviour are covered by the manual checklist in
[TESTING.md](TESTING.md). Run the suite after any change to `Sources/Core` or
`ScanModel.swift`.

## Layout

```
Sources/
  Core/                 no UI; this is what the tests compile
    Models.swift        SafetyTag, ScanItem, SafetyGuard — the guard rail; DiskSpace
    Catalog.swift       the rules: every known path, its tag, and why; both modes
    Scanner.swift       fts sizing, catalog scan, project walker, trash + Put Back, prune tools
    Sandbox.swift       App Sandbox bridge: folder grants, the real home directory
  App/
    DevSweepApp.swift   entry point, window sizing, quit-on-close
    ScanModel.swift     observable state: scans, modes, selection, actions, Trash watcher
    ContentView.swift   the main window
    Welcome.swift       the first-run intro
Tests/main.swift        the test suite — run via Scripts/test.sh
Resources/
  Info.plist            shared by both builds; version placeholders filled from the project
  DevSweep.entitlements App Sandbox, user-selected read/write, app-scoped bookmarks
Scripts/
  build.sh              swiftc → DevSweep.app
  test.sh               compiles Sources/Core + Tests and runs them
  make-dmg.sh           DMG packaging
  makeicon.swift        generates AppIcon.icns at build time (both builds call it)
DevSweep.xcodeproj      App Store archive; owns the version, build number and team
```

Adding a location means adding one `Rule` to `Catalog.swift`. Adding a project
artifact means one `ProjectArtifact` plus its name on the guard's allowlist — the
guard will not act on a name it has not been told about, even if the catalog asks.

## Caveats

- Sizes are allocated blocks on your boot volume, measured in-process with
  `fts(3)` (no `du` subprocess, which the sandbox would not allow). This is what
  you get back, and it can differ slightly from Finder's numbers. Hard-linked
  files are counted once per link. Each folder is split into a few dozen
  parallel walks, so a single tree of millions of small files (a CocoaPods spec
  repo, simulator devices) uses every core instead of holding the whole scan
  up; the totals are identical to a single walk, and to `du`.
- The Go module cache is offered as a whole and never expanded: its files are
  read-only, and an individual module cannot be moved out from under them.
- `__pycache__` is deliberately not listed. There are hundreds of them and they
  are tiny; they would bury the rows that are worth your attention.
- `Scripts/make-dmg.sh` packages whatever `Scripts/build.sh` produced: a single-architecture,
  development-signed, sandboxed app. It is for moving a build between your own
  Macs, not for distribution — that needs Developer ID signing and notarization,
  which this repository does not do.
- Emptying the Trash is left to you. That is deliberate.
