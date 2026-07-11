# DevSweep

A macOS app that finds the build caches, package caches and toolchain junk that
development leaves behind, tags each one **Safe** / **Review** / **Never**, and
moves what you pick to the Trash.

It does not care what you write. Xcode, Gradle, npm, pnpm, Cargo, Go, pip, uv,
Poetry, conda, Bundler, NuGet, Composer, Maven, CocoaPods, SwiftPM, Homebrew,
Docker, JetBrains, VS Code, Unity, Unreal, Hugging Face — around ninety known
locations, and it only shows you the ones that actually exist on your machine.
A Rust developer sees Rust. A Python developer sees Python. Someone who does
both sees both.

```
open DevSweep.app
```

To rebuild after editing the source: `./build.sh`. No Xcode project, no
dependencies, no network access.

---

## Disk space

The header shows the boot volume: how much is free, how much it holds, and a bar
of used ▸ selected ▸ free. Ticking rows lights up a green segment — that is the
space you would get back.

*Would*, not *will*. Moving a file to the Trash frees nothing; the bytes are still
on the disk until the Trash is emptied. So DevSweep never claims otherwise: while
anything is sitting in the Trash the footer says how much, and reminds you that
the disk does not get it back until you empty it. Free space comes from
`volumeAvailableCapacityForImportantUsage`, the same figure Finder reports, which
includes purgeable space and is therefore a little higher than `df`.

## The safety model

This is the part that matters for a tool that deletes things.

**Nothing is ever deleted outright.** Every action goes through
`FileManager.trashItem`. Items land in `~/.Trash` and stay recoverable until you
empty it. There is no permanent-delete code path in the app. Because Trash on the
same volume is a rename, even a 30 GB `DerivedData` moves instantly.

The one exception is the prune tools, described below. They are separated out,
labelled, and confirmed individually, precisely because they break this rule.

**Every path passes an independent guard before it moves.** `SafetyGuard` in
[Sources/Models.swift](Sources/Models.swift) is checked twice — once when a row
is offered for selection, and again at the moment of deletion. It refuses
anything that is not strictly inside your home directory, anything containing
`..`, any symlink that resolves outside home, and anything on an explicit
protected list:

- **Credentials and keys** — `~/.ssh`, `~/.gnupg`, `~/.aws`, `~/.azure`,
  `~/.config/gcloud`, `~/Library/Keychains`, `~/Library/MobileDevice`, and
  `~/.gem/credentials`, which is your RubyGems API key sitting in the middle of
  a directory that is otherwise a cache.
- **Editor settings** — Xcode's `UserData`, VS Code's and Cursor's `User`
  folders, all of `~/Library/Application Support/JetBrains`. Losing these loses
  your setup, which is not a build you can re-run.
- **Container directories** — `~/Library/Caches`, `~/.cargo`, `~/go/pkg`,
  `~/.cache` and around forty others that must never be removed wholesale. Only
  their children may be.
- **Sandboxed app data** — `~/Library/Containers`, which is where Docker keeps
  its disk image.

The guard does not trust the catalog. If a rule were wrong, the guard still stops
it.

## What the tags mean

| Tag | Meaning |
| --- | --- |
| **Safe** | Leftover files your tools rebuild automatically. Deleting them costs nothing but one slower build. |
| **Review** | Comes back too, but slowly — a big download or a long rebuild. Each row says what it costs. Read before ticking. |
| **Protected** | Settings, credentials, the tools themselves. Shown greyed out with a lock, so you can see they were considered and skipped. Cannot be selected. |

If you don't want to think about any of this, press the big button twice: the
first press selects everything Safe, the second moves it to the Trash.

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
is nothing to restore. Each one confirms separately and says so before it runs.

## Project artifacts

Your repositories are found automatically. There is nothing to configure: the
scanner walks your home folder and reports the build output inside whatever it
finds — `build`, `target`, `node_modules`, `dist`, `.next`, `Pods`, `.gradle`,
`.venv`, `bin`/`obj`, `vendor`, `_build`, `.tox`, Unity's `Library`, Unreal's
`Intermediate`, and about twenty more.

The whole walk takes about a second, because it skips `~/Library`, `~/Pictures`,
`~/Movies` and `~/Music` outright and stops descending the moment it finds
something it is going to offer you. That is cheaper than asking you where your
code lives, so it doesn't ask.

A directory only counts if its **parent carries the matching project marker** —
`target` next to a `Cargo.toml` or `pom.xml`, `node_modules` next to a
`package.json`, `bin` next to a `.csproj`, Unity's `Library` next to *both*
`Assets` and `ProjectSettings`. A source folder that happens to be named `build`,
a `dist` of hand-written HTML, a `bin` full of shell scripts, a personal notes
folder called `Library` — all left alone. The name is never enough on its own.

If you want somewhere skipped, *Tools ▸ Exclude a folder from project scanning…*
It persists between launches. Most people will never need it.

## Measured on this machine

A real scan, verified against the filesystem:

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
versions are all correctly excluded as **Never**.

## Testing

```
./test.sh          the fast suite (~1 s)
./test.sh --live   adds checks that scan this machine's real caches
```

The suite is built around the one question that matters: **can the app ever
touch something important?** It attacks each layer that stands between a bug and
your files:

- The guard is fed every protected path, traversal tricks (`../../etc/passwd`),
  paths outside home, and a symlink that points out of your home directory. All
  must be refused.
- `Scanner.trash` is handed `~/.ssh`, `~/Documents`, `~/Library` and `/etc`
  directly — simulating a catalog, model and UI that have *all* failed. The
  guard inside the trash function is the last line, and the tests verify every
  attack is refused, reported, and the directories untouched.
- The project walker runs against a fixture tree of real projects (Rust, Node,
  .NET, Python, Unity, Flutter) and traps: a source folder named `build`, a
  `dist` of plain HTML, a notes folder named `Library`, a `bin` of shell
  scripts, a symlinked `node_modules`. The real ones must be found; the traps
  must never be.
- A real round-trip: a fixture directory is moved via the same code path the
  app uses, verified to land in the Trash and be recoverable, then cleaned up.
- `--live` scans the machine's actual caches and asserts every offered row
  passes the guard, none is a loose file, and no row contains or duplicates
  another.

96 checks, currently all green. Run it after any change to `Models.swift`,
`Catalog.swift` or `Scanner.swift`.

## Layout

```
Sources/
  Models.swift      SafetyTag, ScanItem, and SafetyGuard — the guard rail
  Catalog.swift     the rules: every known path, its tag, and why
  Scanner.swift     parallel `du` sizing, project walker, trashing, prune tools
  ScanModel.swift   observable state, selection, actions
  ContentView.swift the UI
Tests/main.swift      the test suite — run via test.sh
Tools/makeicon.swift  generates AppIcon.icns at build time
build.sh              swiftc → DevSweep.app, ad-hoc signed
test.sh               compiles and runs the tests
```

Adding a location means adding one `Rule` to `Catalog.swift`. Adding a project
artifact means one `ProjectArtifact` plus its name on the guard's allowlist — the
guard will not act on a name it has not been told about, even if the catalog asks.

## Caveats

- Ad-hoc signed, so on first launch macOS may ask you to confirm. Right-click ▸
  Open, or `xattr -d com.apple.quarantine DevSweep.app`.
- Sizes come from `du -sk -x`, i.e. blocks actually allocated on your boot volume.
  This is what you get back, and it can differ slightly from Finder's numbers.
- The Go module cache is offered as a whole and never expanded: its files are
  read-only, and an individual module cannot be moved out from under them.
- `__pycache__` is deliberately not listed. There are hundreds of them and they
  are tiny; they would bury the rows that are worth your attention.
- Emptying the Trash is left to you. That is deliberate.
