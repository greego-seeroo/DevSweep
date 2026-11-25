import Foundation

// DevSweep's test suite. Run with Scripts/test.sh, or Scripts/test.sh --live to add the
// slower checks that scan this machine's real caches.
//
// The suite is organised around the one question that matters for a tool that
// deletes things: can it ever touch something important? Every layer that stands
// between a bug and your files is exercised here — the guard, the walker's
// marker rule, the catalog's integrity, and the trash flow itself.

var failures = 0
var passes = 0

func check(_ ok: Bool, _ what: String) {
    if ok { passes += 1; print("  ok   \(what)") }
    else { failures += 1; print("  FAIL \(what)") }
}

func section(_ name: String) { print("\n— \(name) —") }

let fm = FileManager.default
let home = SafetyGuard.home
func h(_ p: String) -> URL { home.appendingPathComponent(p) }

// Every fixture lives under one uniquely-named directory in $HOME (the guard
// refuses anything outside $HOME, so fixtures elsewhere would pass vacuously).
// It is removed by removeFixtures() at the end — not by a `defer`, which never runs when the
// script ends in exit(). Leftovers from runs that crashed are swept as well.
let fixtureRoot = h(".devsweep-tests-\(ProcessInfo.processInfo.processIdentifier)")

func fixture(_ p: String, bytes: Int = 4096) {
    let u = fixtureRoot.appendingPathComponent(p)
    try? fm.createDirectory(at: u.deletingLastPathComponent(), withIntermediateDirectories: true)
    fm.createFile(atPath: u.path, contents: Data(repeating: 0x41, count: bytes))
}

func fixtureDir(_ p: String) {
    try? fm.createDirectory(at: fixtureRoot.appendingPathComponent(p), withIntermediateDirectories: true)
}

func removeFixtures() {
    try? fm.removeItem(at: fixtureRoot)
    // Sweep fixture roots left behind by earlier runs (the prefix is unique to
    // this suite and the pid suffix means they are never anything else).
    let names = (try? fm.contentsOfDirectory(atPath: home.path)) ?? []
    for name in names where name.hasPrefix(".devsweep-tests-") {
        try? fm.removeItem(at: home.appendingPathComponent(name))
    }
}

// MARK: - 1. The guard: what may never move

section("Guard refuses the forbidden")

// The home directory and the big containers.
for path in ["", "Library", "Library/Caches", "Library/Developer",
             "Library/Application Support", "Documents", "Desktop", "Downloads",
             ".cache", ".cargo", ".gradle", ".npm", "go/pkg", ".nvm", ".docker"] {
    check(!SafetyGuard.isDeletable(h(path)), "container refused: ~/\(path.isEmpty ? "" : path)")
}

// Credentials and settings — nothing at or beneath them, ever.
for path in [".ssh", ".ssh/id_rsa", ".gnupg", ".aws/credentials", ".azure/token",
             ".config/gcloud/credentials.db", ".gem/credentials",
             "Library/Keychains/login.keychain-db",
             "Library/MobileDevice/Provisioning Profiles",
             "Library/Developer/Xcode/UserData/CodeSnippets",
             "Library/Application Support/Code/User/settings.json",
             "Library/Application Support/JetBrains/IntelliJIdea2024.1/keymaps",
             "Library/Containers/com.docker.docker/Data",
             "Library/Group Containers/group.com.apple.notes"] {
    check(!SafetyGuard.isDeletable(h(path)), "protected refused: ~/\(path)")
}

// Anything outside the home directory.
for path in ["/", "/etc", "/etc/passwd", "/usr/local/lib", "/Applications/Safari.app",
             "/System/Library", "/Volumes/External/repos/node_modules"] {
    check(!SafetyGuard.isDeletable(URL(fileURLWithPath: path)), "outside home refused: \(path)")
}

// Traversal tricks.
check(!SafetyGuard.isDeletable(h("../../etc/passwd")), "dot-dot traversal refused")
check(!SafetyGuard.isDeletable(h("Library/Caches/../../.ssh")), "dot-dot through a cache refused")

// Case tricks. The boot volume is case-insensitive, so these name the same
// folders as the protected list does, just spelled differently.
for path in ["library", "LIBRARY/Caches", "Library/keychains/login.keychain-db",
             ".SSH/id_rsa", "library/containers/com.docker.docker", "documents"] {
    check(!SafetyGuard.isDeletable(h(path)), "case variant refused: ~/\(path)")
}

section("Guard allows the legitimate")

for path in ["Library/Caches/pip", "Library/Caches/Homebrew", ".cache/pip",
             ".cargo/registry", "go/pkg/mod", ".npm/_cacache",
             "Library/Developer/Xcode/DerivedData",
             "Library/Application Support/Code/CachedData"] {
    check(SafetyGuard.isDeletable(h(path)), "cache allowed: ~/\(path)")
}

section("Guard refuses symlink escapes")

// A symlink inside $HOME that points outside it must be refused, even though
// its own path looks fine.
fixtureDir("links")
let escape = fixtureRoot.appendingPathComponent("links/escape")
try? fm.createSymbolicLink(at: escape, withDestinationURL: URL(fileURLWithPath: "/private/tmp"))
check(fm.fileExists(atPath: escape.path), "fixture symlink created")
check(!SafetyGuard.isDeletable(escape), "symlink to /private/tmp refused")

// A symlink that stays inside $HOME is fine.
let internalLink = fixtureRoot.appendingPathComponent("links/internal")
fixtureDir("links/real")
try? fm.createSymbolicLink(at: internalLink,
                           withDestinationURL: fixtureRoot.appendingPathComponent("links/real"))
check(SafetyGuard.isDeletable(internalLink), "symlink within home allowed")

// A symlink that stays inside $HOME but lands on something protected is not —
// trashing through it would move the target. Both the link itself and a path
// that merely passes through it.
let toLibrary = fixtureRoot.appendingPathComponent("links/lib")
try? fm.createSymbolicLink(at: toLibrary, withDestinationURL: h("Library"))
check(!SafetyGuard.isDeletable(toLibrary), "symlink to ~/Library refused")
check(!SafetyGuard.isDeletable(toLibrary.appendingPathComponent("Keychains")),
      "path through a symlink into ~/Library/Keychains refused")
check(!SafetyGuard.isDeletable(toLibrary.appendingPathComponent("Caches")),
      "path through a symlink onto a protected container refused")
check(SafetyGuard.isDeletable(toLibrary.appendingPathComponent("Caches/pip")),
      "path through a symlink onto a legitimate cache allowed")

// MARK: - 2. The model: what a row offers for deletion

section("ScanItem offers nothing it shouldn't")

let protectedItem = ScanItem(title: "ssh", note: "", url: h(".ssh"), tag: .safe, bytes: 1)
check(protectedItem.deletableLeaves.isEmpty, "a Safe-tagged row on a protected path offers nothing")

let neverItem = ScanItem(title: "sdk", note: "", url: h("Library/Android/sdk"), tag: .never, bytes: 1)
check(neverItem.deletableLeaves.isEmpty, "a Protected row offers nothing")

let mixed = ScanItem(title: "box", note: "", url: h("Library/Caches"), tag: .safe, bytes: 0,
                     children: [
                        ScanItem(title: "good", note: "", url: h("Library/Caches/pip"), tag: .safe, bytes: 1),
                        ScanItem(title: "bad", note: "", url: h(".ssh"), tag: .safe, bytes: 1),
                     ])
check(mixed.deletableLeaves.map(\.title) == ["good"],
      "a container filters its children through the guard")

// MARK: - 3. The walker: evidence, not names

section("Walker detects real build output")

// Real projects with real markers.
fixture("repos/rust-app/Cargo.toml", bytes: 100)
fixture("repos/rust-app/target/debug/app", bytes: 200_000)
fixture("repos/web-app/package.json", bytes: 100)
fixture("repos/web-app/node_modules/left-pad/index.js", bytes: 150_000)
fixture("repos/web-app/dist/bundle.js", bytes: 90_000)
fixture("repos/dotnet-app/App.csproj", bytes: 100)
fixture("repos/dotnet-app/bin/Debug/app.dll", bytes: 70_000)
fixture("repos/dotnet-app/obj/project.assets.json", bytes: 60_000)
fixture("repos/py-app/pyproject.toml", bytes: 100)
fixture("repos/py-app/.venv/lib/x.py", bytes: 120_000)
fixture("repos/unity-game/Assets/Main.cs", bytes: 100)
fixture("repos/unity-game/ProjectSettings/P.asset", bytes: 100)
fixture("repos/unity-game/Library/Artifacts/blob", bytes: 300_000)
fixture("repos/nested/a/b/flutter-app/pubspec.yaml", bytes: 100)
fixture("repos/nested/a/b/flutter-app/build/apk", bytes: 80_000)

// Traps: right names, no evidence. None of these may ever be offered.
fixture("repos/plain-repo/src/main.c", bytes: 100)
fixture("repos/plain-repo/build/handwritten.c", bytes: 500_000)     // no marker at all
fixture("repos/docs-site/dist/index.html", bytes: 400_000)          // dist of plain HTML
fixture("repos/notes/Assets/x.txt", bytes: 100)
fixture("repos/notes/Library/important.txt", bytes: 600_000)        // not Unity: no ProjectSettings
fixture("repos/scripts/bin/deploy.sh", bytes: 300_000)              // bin of shell scripts
fixture("repos/writing/target/audience.md", bytes: 250_000)         // target of prose
fixture("repos/js-app/package.json", bytes: 100)
fixture("repos/js-app/deps/vendored.js", bytes: 200_000)            // deps is Elixir-only evidence
fixture("repos/notes-tf/.terraform/x", bytes: 150_000)              // .terraform with no *.tf beside it

// A symlinked artifact must be skipped — trashing a symlink's destination
// through the link would reach whatever it points at.
fixture("repos/linked-app/package.json", bytes: 100)
try? fm.createSymbolicLink(
    at: fixtureRoot.appendingPathComponent("repos/linked-app/node_modules"),
    withDestinationURL: fixtureRoot.appendingPathComponent("repos/web-app/node_modules"))

let walkRoot = fixtureRoot.appendingPathComponent("repos")
let found = Set((Scanner.scanProjects(roots: [walkRoot])?.items ?? []).map {
    $0.url.path.replacingOccurrences(of: walkRoot.path + "/", with: "")
})

for expected in ["rust-app/target", "web-app/node_modules", "web-app/dist",
                 "dotnet-app/bin", "dotnet-app/obj", "py-app/.venv",
                 "unity-game/Library", "nested/a/b/flutter-app/build"] {
    check(found.contains(expected), "detected \(expected)")
}
for trap in ["plain-repo/build", "docs-site/dist", "notes/Library",
             "scripts/bin", "writing/target", "linked-app/node_modules",
             "js-app/deps", "notes-tf/.terraform"] {
    check(!found.contains(trap), "left alone: \(trap)")
}
check(!found.contains("web-app/node_modules/left-pad"), "never descends into what it offers")

section("Walker honours exclusions")

let skip: Set<String> = [walkRoot.appendingPathComponent("web-app").standardizedFileURL.path]
let afterSkip = Set((Scanner.scanProjects(roots: [walkRoot], excluding: skip)?.items ?? []).map {
    $0.url.path.replacingOccurrences(of: walkRoot.path + "/", with: "")
})
check(!afterSkip.contains("web-app/node_modules"), "excluded folder is skipped")
check(afterSkip.contains("rust-app/target"), "everything else still found")

// MARK: - 4. The catalog: internally consistent

section("Catalog integrity")

let orphans = Catalog.projectArtifacts.map(\.name).filter { !SafetyGuard.projectArtifactNames.contains($0) }
check(orphans.isEmpty, "every artifact name is on the guard's allowlist \(orphans)")

let unknownGroups = Set(Catalog.rules.map(\.group)).subtracting(Catalog.groupOrder)
check(unknownGroups.isEmpty, "every rule's group is in groupOrder \(unknownGroups)")

var seenPaths = Set<String>()
let dupes = Catalog.rules.map(\.relPath).filter { !seenPaths.insert($0).inserted }
check(dupes.isEmpty, "no duplicate rule paths \(dupes)")

let deadRules = Catalog.rules
    .filter { $0.tag != .never && !$0.expand }
    .filter { !SafetyGuard.isDeletable(home.appendingPathComponent($0.relPath)) }
check(deadRules.isEmpty, "every whole-directory rule passes the guard \(deadRules.map(\.relPath))")

let deadContainers = Catalog.rules
    .filter { $0.tag != .never && $0.expand }
    .filter { !SafetyGuard.isDeletable(home.appendingPathComponent($0.relPath).appendingPathComponent("x")) }
check(deadContainers.isEmpty, "every expanded rule can offer children \(deadContainers.map(\.relPath))")

let relative = Catalog.rules.filter { $0.relPath.hasPrefix("/") || $0.relPath.contains("..") }
check(relative.isEmpty, "every rule path is clean and home-relative \(relative.map(\.relPath))")

section("Everyday catalog integrity")

let edUnknown = Set(Catalog.everydayRules.map(\.group)).subtracting(Catalog.groupOrder)
check(edUnknown.isEmpty, "every everyday group is in groupOrder \(edUnknown)")

let edRelative = Catalog.everydayRules.filter { $0.relPath.hasPrefix("/") || $0.relPath.contains("..") }
check(edRelative.isEmpty, "every everyday rule path is clean and home-relative \(edRelative.map(\.relPath))")

let edDeadRules = Catalog.everydayRules
    .filter { $0.tag != .never && !$0.expand }
    .filter { !SafetyGuard.isDeletable(home.appendingPathComponent($0.relPath)) }
check(edDeadRules.isEmpty, "every everyday whole-directory rule passes the guard \(edDeadRules.map(\.relPath))")

let edDeadContainers = Catalog.everydayRules
    .filter { $0.tag != .never && $0.expand }
    .filter { !SafetyGuard.isDeletable(home.appendingPathComponent($0.relPath).appendingPathComponent("x")) }
check(edDeadContainers.isEmpty, "every everyday expanded rule can offer children \(edDeadContainers.map(\.relPath))")

// A user who taps "Select everything safe" must never mass-select app caches or
// device backups — losing those costs sign-ins and irreplaceable backups.
check(!Catalog.everydayRules.contains { $0.tag == .safe && $0.relPath != "Library/Logs" },
      "only logs are tagged Safe in the everyday catalog")

// The two catalogs must never bleed into each other: a System Data scan shows
// no toolchains, a Developer scan shows no app caches.
let everydayGroups = Set(Catalog.everydayRules.map(\.group))
check(Catalog.activeRules(for: .everyday).allSatisfy { everydayGroups.contains($0.group) },
      "a System Data scan includes only everyday rules")
check(Catalog.activeRules(for: .developer).allSatisfy { !everydayGroups.contains($0.group) },
      "a Developer scan includes no everyday rules")

// MARK: - 4b. Sizing: the fts walker

section("Sizing")

fixture("sizes/plain/a.bin", bytes: 1_000_000)
fixture("sizes/plain/b.bin", bytes: 500_000)
// Regression: the old FileManager walk skipped package descendants, so caches
// full of .app bundles (Electron, Playwright browsers) reported near zero.
fixture("sizes/bundle/Fake.app/Contents/MacOS/fake", bytes: 750_000)
fixtureDir("sizes/withlink")
let sizeRoot = fixtureRoot.appendingPathComponent("sizes")
try? fm.createSymbolicLink(
    at: sizeRoot.appendingPathComponent("withlink/escape"),
    withDestinationURL: sizeRoot.appendingPathComponent("plain"))

let measuredSizes = Scanner.sizes(of: [
    sizeRoot.appendingPathComponent("plain"),
    sizeRoot.appendingPathComponent("bundle"),
    sizeRoot.appendingPathComponent("withlink"),
])
let plainBytes = measuredSizes[sizeRoot.appendingPathComponent("plain").path] ?? 0
check(plainBytes >= 1_500_000, "all files in a directory are counted (got \(plainBytes))")
check(plainBytes <= 4_000_000, "allocated size stays in the right ballpark (got \(plainBytes))")
let bundleBytes = measuredSizes[sizeRoot.appendingPathComponent("bundle").path] ?? 0
check(bundleBytes >= 750_000, "files inside .app bundles are counted (got \(bundleBytes))")
let linkBytes = measuredSizes[sizeRoot.appendingPathComponent("withlink").path] ?? 0
check(linkBytes < 100_000, "symlinks are not followed when sizing (got \(linkBytes))")

// MARK: - 4b2. Sharded sizing: many walks, one answer

section("Sharded sizing")

// A tree shaped like the CocoaPods spec repo — a few levels of many small
// directories — plus loose files at every level, a symlink, and an empty
// directory. The sharded walk must agree with the single walk exactly, and
// both must agree with du.
for a in 0..<10 {
    fixture("shard/top.\(a).txt", bytes: 1234)
    for b in 0..<4 {
        fixture("shard/\(a)/mid.\(b).txt", bytes: 777)
        for c in 0..<3 {
            fixture("shard/\(a)/\(b)/leaf.\(c).bin", bytes: 4096 * (c + 1))
        }
    }
}
fixtureDir("shard/empty")
let shardRoot = fixtureRoot.appendingPathComponent("shard")
try? fm.createSymbolicLink(at: shardRoot.appendingPathComponent("link"),
                           withDestinationURL: shardRoot.appendingPathComponent("0"))

let shardedBytes = Scanner.sizes(of: [shardRoot])[shardRoot.path] ?? -1
let singleBytes = Scanner.sizeUnsharded(shardRoot)
check(shardedBytes == singleBytes, "sharded walk equals the single walk (\(shardedBytes) vs \(singleBytes))")

let du = Process()
du.executableURL = URL(fileURLWithPath: "/usr/bin/du")
du.arguments = ["-sk", "-x", shardRoot.path]
let duPipe = Pipe(); du.standardOutput = duPipe
try? du.run(); du.waitUntilExit()
let duText = String(data: duPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
let duBytes = Int64(duText.split(separator: "\t").first.flatMap { Int($0) } ?? -1) * 1024
check(duBytes > 0 && shardedBytes == duBytes, "sharded walk matches du -sk (\(shardedBytes) vs \(duBytes))")

// Several directories at once: every one is reported, progress reaches the
// total, and the pending list names only directories still being measured.
let shardDirs = (0..<10).map { shardRoot.appendingPathComponent("\($0)") }
var progressDone: [Int] = []
var pendingSane = true
let progressLock = NSLock()
let many = Scanner.sizes(of: shardDirs, onProgress: { known, done, total, pending in
    progressLock.lock()
    progressDone.append(done)
    if total != shardDirs.count || done > total || known.count != done
        || pending.count != total - done || pending.contains(where: { known[shardDirs[$0].path] != nil }) {
        pendingSane = false
    }
    progressLock.unlock()
})
check(many.count == shardDirs.count, "every directory is measured")
check(many.values.allSatisfy { $0 == many.values.first }, "identical directories measure identically")
check(pendingSane, "progress reports consistent done/known/pending")
check(progressDone == progressDone.sorted(), "progress never goes backwards within the callback order")
check(!progressDone.contains(shardDirs.count), "the final result is returned, not emitted as progress")

// A directory trashed while it is being walked ends the walk; it must not
// hang or crash, and the walk of the other directory is unaffected.
fixtureDir("shard/victim")
for i in 0..<200 { fixture("shard/victim/\(i / 20)/f\(i).bin", bytes: 512) }
let victimDir = shardRoot.appendingPathComponent("victim")
let bystander = shardRoot.appendingPathComponent("1")
let bystanderAlone = Scanner.sizes(of: [bystander])[bystander.path] ?? -1
let raceGroup = DispatchGroup()
var raced: [String: Int64] = [:]
raceGroup.enter()
DispatchQueue.global().async {
    raced = Scanner.sizes(of: [victimDir, bystander])
    raceGroup.leave()
}
var trashedVictim: NSURL?
try? fm.trashItem(at: victimDir, resultingItemURL: &trashedVictim)
check(raceGroup.wait(timeout: .now() + 30) == .success, "a walk survives its directory being trashed mid-way")
check(raced[bystander.path] == bystanderAlone, "the other directory is still measured correctly")
if let t = trashedVictim as URL? { try? fm.removeItem(at: t) }

// MARK: - 4b3. Streaming into an existing list

section("Merging streamed rows")

func row(_ name: String, _ bytes: Int64, tag: SafetyTag = .safe) -> ScanItem {
    ScanItem(title: name, note: "", url: fixtureRoot.appendingPathComponent("merge/\(name)"), tag: tag, bytes: bytes)
}
let oldList = [
    ScanGroup(name: "A", items: [row("a1", 100), row("a2", 200)]),
    ScanGroup(name: "B", items: [row("b1", 300)]),
]
let freshRows = [
    ScanGroup(name: "A", items: [row("a2", 250), row("a3", 50)]),
    ScanGroup(name: "C", items: [row("c1", 10)]),
]
let mergedList = oldList.merging(freshRows)
check(mergedList.map(\.name) == ["A", "B", "C"], "old group order kept, new group appended")
check(mergedList[0].items.map(\.title) == ["a1", "a2", "a3"], "remeasured row replaced in place, new row appended")
check(mergedList[0].items[1].bytes == 250, "the remeasured row carries the new size")
check(mergedList[0].items[0].bytes == 100 && mergedList[1].items[0].bytes == 300,
      "rows the new scan has not reached keep their old size")
check([ScanGroup]().merging(freshRows).map(\.name) == ["A", "C"], "merging into an empty list is the fresh list")

// What a scan measured before a row was trashed must not come back: a partial
// with the trashed row, filtered the way ScanModel filters it, drops it.
let trashedMidScan: Set<String> = [row("a1", 0).id]
check(freshRows.merging(oldList).removing(paths: trashedMidScan).flatMap(\.items).map(\.title).contains("a1") == false,
      "a row trashed mid-scan is removed from the streamed result")

// MARK: - 4b3b. The remembered scan

section("Remembered scan")

let cacheDir = fixtureRoot.appendingPathComponent("cache")
fixtureDir("cache/rows/keep")
fixtureDir("cache/rows/container")
fixtureDir("cache/rows/child-keep")
fixtureDir("cache/rows/child-gone")
fixtureDir("cache/rows/gone")
fixtureDir("cache/rows/locked")
let rows = fixtureRoot.appendingPathComponent("cache/rows")
func cacheRow(_ name: String, _ bytes: Int64, tag: SafetyTag = .safe, children: [ScanItem] = []) -> ScanItem {
    ScanItem(title: name, note: "note \(name)", url: rows.appendingPathComponent(name), tag: tag, bytes: bytes, children: children)
}
let remembered = [
    ScanGroup(name: "Xcode", items: [
        cacheRow("keep", 1000),
        cacheRow("gone", 2000),
        cacheRow("container", 0, tag: .review, children: [cacheRow("child-keep", 300), cacheRow("child-gone", 400)]),
    ]),
    ScanGroup(name: "Android", items: [cacheRow("locked", 0, tag: .never)]),
]
ScanCache.save(remembered, audience: .developer, in: cacheDir)
check(fm.fileExists(atPath: ScanCache.file(for: .developer, in: cacheDir).path), "the scan is written to disk")

let loaded = ScanCache.load(audience: .developer, in: cacheDir)
check(loaded != nil, "the scan loads back")
check(loaded.map { abs($0.date.timeIntervalSinceNow) < 5 } == true, "with the time it was taken")
check(loaded?.groups.map(\.name) == ["Xcode", "Android"], "groups and their order survive")
let xcode = loaded?.groups.first?.items ?? []
check(xcode.map(\.title) == ["keep", "gone", "container"], "rows survive with titles")
check(xcode.first?.bytes == 1000 && xcode.first?.note == "note keep" && xcode.first?.tag == .safe, "bytes, notes and tags survive")
check(xcode.last?.children.map(\.title) == ["child-keep", "child-gone"], "children survive")
check(loaded?.groups.last?.items.first?.tag == .never, "Protected rows survive")
check(ScanCache.load(audience: .everyday, in: cacheDir) == nil, "the other mode has nothing remembered")

try? fm.removeItem(at: rows.appendingPathComponent("gone"))
try? fm.removeItem(at: rows.appendingPathComponent("child-gone"))
let pruned = ScanCache.load(audience: .developer, in: cacheDir)
check(pruned?.groups.first?.items.map(\.title) == ["keep", "container"], "a row whose directory vanished is dropped")
check(pruned?.groups.first?.items.last?.children.map(\.title) == ["child-keep"], "so is a vanished child")

try? fm.removeItem(at: rows.appendingPathComponent("keep"))
try? fm.removeItem(at: rows.appendingPathComponent("child-keep"))
try? fm.removeItem(at: rows.appendingPathComponent("locked"))
check(ScanCache.load(audience: .developer, in: cacheDir) == nil, "nothing left means nothing remembered")

try? "not json".write(to: ScanCache.file(for: .developer, in: cacheDir), atomically: true, encoding: .utf8)
check(ScanCache.load(audience: .developer, in: cacheDir) == nil, "a corrupt file is ignored")
ScanCache.save(remembered, audience: .developer, in: cacheDir)
var raw = (try? JSONSerialization.jsonObject(with: Data(contentsOf: ScanCache.file(for: .developer, in: cacheDir)))) as? [String: Any] ?? [:]
raw["schema"] = ScanCache.schema + 1
try? JSONSerialization.data(withJSONObject: raw).write(to: ScanCache.file(for: .developer, in: cacheDir))
check(ScanCache.load(audience: .developer, in: cacheDir) == nil, "a file from a newer schema is ignored")
ScanCache.clear(audience: .developer, in: cacheDir)
check(!fm.fileExists(atPath: ScanCache.file(for: .developer, in: cacheDir).path), "clear removes the file")

check(ScanCache.directory.path.contains("Application Support/DevSweep"), "the real cache lives in Application Support")

// MARK: - 4b4. The status line names the stragglers

section("Measuring status")

check(ScanStatus.measuring(done: 10, total: 153, waiting: ["x", "y"]) == "Measuring caches… 10 of 153",
      "early on, the status is just a count")
check(ScanStatus.measuring(done: 152, total: 153, waiting: ["CocoaPods spec repos"])
      == "Measuring caches… 152 of 153 · still measuring CocoaPods spec repos",
      "the last few are named")

// MARK: - 4c. Cancellation: a scan told to stop, stops

section("Cancellation")

let fresh = CancelFlag()
check(!fresh.isCancelled, "a fresh flag is not cancelled")
fresh.cancel()
check(fresh.isCancelled, "cancel() sticks")

let stopped = CancelFlag()
stopped.cancel()
check(Scanner.sizes(of: [sizeRoot], cancel: stopped).isEmpty,
      "a cancelled sizing run measures nothing")
check(Scanner.scanProjects(roots: [walkRoot], cancel: stopped) == nil,
      "a cancelled project scan returns nothing")
check(Scanner.scanProjects(roots: [walkRoot], cancel: CancelFlag()) != nil,
      "an uncancelled flag changes nothing")

// MARK: - 4d. Disk space: fresh on every read

section("Disk space")

if let first = DiskSpace.current(), let second = DiskSpace.current() {
    check(first.total > 0 && first.free > 0, "disk space reads")
    check(first.free <= first.total, "free never exceeds total")
    check(first.used >= 0, "used is never negative")
    check(second.free > 0 && second.total == first.total, "a second read also succeeds")
} else {
    check(false, "DiskSpace.current() returned nil")
}

// MARK: - 5. Size parsing (display-only, but shouldn't lie)

section("Size parsing")

check(SizeText.sizes(in: "0B\n1.2GB (100%)\n0B\n345.6MB (57%)\n").reduce(0, +) == 1_545_600_000,
      "docker df output sums correctly")
check(SizeText.sizes(in: "This operation would free approximately 1.1GB of disk space.").max() == 1_100_000_000,
      "brew cleanup -n reads correctly")
check(SizeText.sizes(in: "2345.67 MiB would be freed").max() == Int64(2345.67 * 1_048_576),
      "binary units read correctly")
check(SizeText.sizes(in: "sha256:abc123def").isEmpty, "hex digests are not sizes")
check(SizeText.sizes(in: "1.5 games installed").isEmpty, "'games' is not gigabytes")
check(SizeText.sizes(in: "Deleted 12 images").isEmpty, "bare counts are not sizes")
check(SizeText.sizes(in: "freeing 500 kb").max() == 500_000, "lowercase unit with a space reads correctly")
check(SizeText.sizes(in: "cache: 10TiB total").max() == 10 * 1_099_511_627_776, "terabyte-scale binary units read correctly")
check(SizeText.sizes(in: "v1.2.3 released").isEmpty, "version numbers are not sizes")

// MARK: - 5b. In-place removal: what the list does when rows stop existing

section("Row removal without a rescan")

let sampleGroups: [ScanGroup] = [
    ScanGroup(name: "Xcode", items: [
        ScanItem(title: "box", note: "", url: h("Library/Developer/Xcode/DerivedData"), tag: .safe, bytes: 0,
                 children: [
                    ScanItem(title: "a", note: "", url: h("Library/Developer/Xcode/DerivedData/a"), tag: .safe, bytes: 10),
                    ScanItem(title: "b", note: "", url: h("Library/Developer/Xcode/DerivedData/b"), tag: .safe, bytes: 20),
                 ]),
        ScanItem(title: "sdk", note: "", url: h("Library/Android/sdk"), tag: .never, bytes: 0),
    ]),
    ScanGroup(name: "Go", items: [
        ScanItem(title: "mod", note: "", url: h("go/pkg/mod"), tag: .safe, bytes: 5),
    ]),
]

let afterLeaf = sampleGroups.removing(paths: [h("Library/Developer/Xcode/DerivedData/a").path])
check(afterLeaf[0].items[0].children.map(\.title) == ["b"], "removing one child keeps its siblings")
check(afterLeaf[0].items[0].totalBytes == 20, "the container's total shrinks with the child")

let afterAll = sampleGroups.removing(paths: [h("Library/Developer/Xcode/DerivedData/a").path,
                                             h("Library/Developer/Xcode/DerivedData/b").path])
check(!afterAll[0].items.contains { $0.title == "box" }, "a container emptied of children disappears")
check(afterAll[0].items.contains { $0.title == "sdk" }, "a Protected row stays even at zero bytes")

let afterGroup = sampleGroups.removing(paths: [h("go/pkg/mod").path])
check(!afterGroup.contains { $0.name == "Go" }, "a group emptied of items disappears")
check(afterGroup.contains { $0.name == "Xcode" }, "other groups are untouched")

check(sampleGroups.removing(paths: []).count == sampleGroups.count, "removing nothing changes nothing")

// MARK: - 6. The trash flow itself, end to end

section("Trash flow")

// A real directory goes in, lands in ~/.Trash, and disappears from its origin.
let victimName = "devsweep-trash-roundtrip-\(ProcessInfo.processInfo.processIdentifier)"
let victim = fixtureRoot.appendingPathComponent(victimName)
try? fm.createDirectory(at: victim, withIntermediateDirectories: true)
fm.createFile(atPath: victim.appendingPathComponent("junk.bin").path,
              contents: Data(repeating: 0x41, count: 32_768))

let okReport = Scanner.trash([ScanItem(title: "victim", note: "", url: victim, tag: .safe, bytes: 32_768)])
check(okReport.moved == 1 && okReport.failures.isEmpty, "deletable item moves to the Trash")
check(!fm.fileExists(atPath: victim.path), "item is gone from its origin")
check(okReport.movedURLs == [victim], "the report records what moved, at its original path")
check(okReport.moves.count == 1 && okReport.moves.first?.trashed != victim,
      "the report records where in the Trash it landed")

section("Put Back (undo)")

// Round trip: what was trashed comes back exactly where it was.
let undone = Scanner.restore(okReport)
check(undone.restored == 1 && undone.skipped == 0, "restore puts the item back")
check(fm.fileExists(atPath: victim.appendingPathComponent("junk.bin").path),
      "restored directory has its contents")
if let trashed = okReport.moves.first?.trashed {
    check(!fm.fileExists(atPath: trashed.path), "the item left the Trash")
}
check(Scanner.restore(okReport).restored == 0, "a second restore has nothing to do")

// Never overwrite: if the tool already rebuilt the directory, the restore skips.
let reReport = Scanner.trash([ScanItem(title: "victim", note: "", url: victim, tag: .safe, bytes: 1)])
try? fm.createDirectory(at: victim, withIntermediateDirectories: true)
let blocked = Scanner.restore(reReport)
check(blocked.restored == 0 && blocked.skipped == 1, "restore never overwrites a rebuilt directory")
if let trashed = reReport.moves.first?.trashed {
    check(fm.fileExists(atPath: trashed.path), "the skipped item stays safely in the Trash")
    try? fm.removeItem(at: trashed)   // tidy up exactly our own fixture
}

// Never write outside $HOME, even from a corrupted report.
fixture("restore/src.bin")
var evil = Scanner.DeleteReport()
evil.moves = [(original: URL(fileURLWithPath: "/private/tmp/devsweep-evil-\(ProcessInfo.processInfo.processIdentifier)"),
               trashed: fixtureRoot.appendingPathComponent("restore/src.bin"))]
let evilResult = Scanner.restore(evil)
check(evilResult.restored == 0 && evilResult.skipped == 1, "restore refuses destinations outside home")
check(fm.fileExists(atPath: fixtureRoot.appendingPathComponent("restore/src.bin").path),
      "the refused item is left untouched")

section("Auto mode")

let devGroups = [ScanGroup(name: "Xcode", items: [
    ScanItem(title: "x", note: "", url: h("Library/Developer/Xcode/DerivedData"), tag: .safe, bytes: 1),
])]
check(AutoMode.shouldSwitchToSystemData(groups: [], audience: .developer, userPicked: false),
      "an empty Developer scan on an untouched machine switches to System Data")
check(!AutoMode.shouldSwitchToSystemData(groups: devGroups, audience: .developer, userPicked: false),
      "a machine with developer caches stays in Developer")
check(!AutoMode.shouldSwitchToSystemData(groups: [], audience: .developer, userPicked: true),
      "the user's explicit choice is never overridden")
check(!AutoMode.shouldSwitchToSystemData(groups: [], audience: .everyday, userPicked: false),
      "System Data never auto-switches away")

// MARK: - 6c. Friendly names: what the list and the confirm sheet lead with

section("Friendly names")

let safari = Scanner.friendlyChild(h("Library/Caches/com.apple.Safari"))
check(safari.title == "Safari" && safari.note == "com.apple.Safari",
      "bundle ids become app names (got “\(safari.title)”)")
let plainName = Scanner.friendlyChild(h("Library/Caches/Homebrew"))
check(plainName.title == "Homebrew" && plainName.note.isEmpty,
      "ordinary folder names pass through untouched")
let dotName = Scanner.friendlyChild(h(".cache"))
check(dotName.title == ".cache" && dotName.note.isEmpty, "dot-folders pass through untouched")
let ghostApp = Scanner.friendlyChild(h("Library/Caches/com.nonexistent.devsweep-zzz"))
check(ghostApp.title == "com.nonexistent.devsweep-zzz",
      "bundle ids of apps not installed stay as they are")

// MARK: - 6d. A user's journey, end to end

section("A user's journey (scan → tick → clean → regret → put back)")

// A small web project, as a user's disk would have it.
fixture("journey/web-app/package.json", bytes: 100)
fixture("journey/web-app/node_modules/lib/index.js", bytes: 250_000)
fixture("journey/web-app/dist/bundle.js", bytes: 90_000)
let journeyRoot = fixtureRoot.appendingPathComponent("journey")

if let foundGroup = Scanner.scanProjects(roots: [journeyRoot]) {
    // The user scans and sees rows with sizes.
    let leaves = foundGroup.items.flatMap(\.deletableLeaves)
    check(leaves.count == 2, "the scan finds the build output (\(leaves.map(\.title)))")
    check(leaves.allSatisfy { $0.bytes > 0 }, "every row shows a real size")

    // They tick everything and clean.
    let cleanReport = Scanner.trash(leaves)
    check(cleanReport.moved == leaves.count && cleanReport.failures.isEmpty,
          "one click moves the lot to the Trash")

    // The list updates itself without a rescan.
    let afterClean = [foundGroup].removing(paths: Set(cleanReport.movedURLs.map(\.path)))
    check(afterClean.isEmpty, "the cleaned rows disappear without a rescan")
    check(!fm.fileExists(atPath: journeyRoot.appendingPathComponent("web-app/node_modules").path),
          "the folders are really gone from the project")

    // They regret it and press Put Back.
    let putBack = Scanner.restore(cleanReport)
    check(putBack.restored == cleanReport.moved && putBack.skipped == 0,
          "Put Back restores the whole cleanup")
    check(fm.fileExists(atPath: journeyRoot.appendingPathComponent("web-app/node_modules/lib/index.js").path),
          "node_modules is back, contents intact")
    check(fm.fileExists(atPath: journeyRoot.appendingPathComponent("web-app/dist/bundle.js").path),
          "dist is back, contents intact")

    // And a rescan finds everything offered again.
    let rescanned = Scanner.scanProjects(roots: [journeyRoot])
    check(rescanned?.items.flatMap(\.deletableLeaves).count == 2, "a rescan offers the restored rows again")
} else {
    check(false, "journey scan found nothing")
}

section("Trash flow, continued")

// Verify the landing spot with the same API the app uses. Enumerating ~/.Trash
// is TCC-protected for command-line processes, but trashItem hands back the
// resulting URL — which also lets the test remove exactly its own fixture.
let victim2 = fixtureRoot.appendingPathComponent(victimName + "-b")
try? fm.createDirectory(at: victim2, withIntermediateDirectories: true)
var landed: NSURL?
try? fm.trashItem(at: victim2, resultingItemURL: &landed)
if let landed = landed as URL? {
    check(landed.path.contains("/.Trash"), "item lands inside a Trash directory")
    check(fm.fileExists(atPath: landed.path), "item is recoverable from the Trash")
    try? fm.removeItem(at: landed)   // clean up exactly our own fixture
} else {
    check(false, "trashItem reported no resulting URL")
}

// The attack test: hand the trash function protected paths directly, as if the
// catalog, the model and the UI had all failed. The guard is the last line.
let attacks = [h(".ssh"), h("Documents"), h("Library"), h(".gem/credentials"),
               URL(fileURLWithPath: "/etc")]
let attackReport = Scanner.trash(attacks.map {
    ScanItem(title: $0.lastPathComponent, note: "", url: $0, tag: .safe, bytes: 1)
})
check(attackReport.moved == 0, "no protected path moved (\(attackReport.moved) did)")
check(attackReport.failures.count == attacks.count, "every attack was refused and reported")
check(attackReport.failures.allSatisfy { $0.reason == "blocked by safety guard" },
      "each refusal names the guard")
check(fm.fileExists(atPath: h(".ssh").path), "~/.ssh is untouched")
check(fm.fileExists(atPath: h("Documents").path), "~/Documents is untouched")

// A path that no longer exists is skipped silently, not reported as an error.
let ghost = fixtureRoot.appendingPathComponent("never-existed")
let ghostReport = Scanner.trash([ScanItem(title: "ghost", note: "", url: ghost, tag: .safe, bytes: 1)])
check(ghostReport.moved == 0 && ghostReport.failures.isEmpty, "missing path is skipped silently")

// MARK: - 6d. Localization: every string the UI can show has every language

section("Localization catalog")

// The catalogs are read from the repository (Scripts/test.sh runs from its
// root). Each translatable key must carry all four languages, every
// translation must keep the English placeholders, and keys whose number
// varies must have plural forms. English falls back to the key itself.
struct Catalog_ {
    let name: String
    let strings: [String: [String: Any]]
}
func loadCatalog(_ name: String) -> Catalog_? {
    let url = URL(fileURLWithPath: "Resources/\(name).xcstrings")
    guard let data = try? Data(contentsOf: url),
          let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let strings = root["strings"] as? [String: [String: Any]]
    else { return nil }
    return Catalog_(name: name, strings: strings)
}
/// The format placeholders of a string, positions stripped, sorted.
func placeholders(_ text: String) -> [String] {
    let pattern = try! NSRegularExpression(pattern: "%(\\d+\\$)?(@|lld|ld|d|lu|llu|f|s)")
    let range = NSRange(text.startIndex..., in: text)
    return pattern.matches(in: text, range: range)
        .map { String(text[Range($0.range(at: 2), in: text)!]) }
        .sorted()
}
/// Every value a localization can resolve to (one for a plain string, several for variations).
func values(of localization: [String: Any]) -> [String] {
    if let unit = localization["stringUnit"] as? [String: Any], let value = unit["value"] as? String {
        return [value]
    }
    if let variations = localization["variations"] as? [String: Any],
       let plural = variations["plural"] as? [String: [String: Any]] {
        return plural.values.flatMap { values(of: $0) }
    }
    return []
}
let languages = ["de", "ja", "fr", "es"]
for name in ["Localizable", "InfoPlist"] {
    guard let catalog = loadCatalog(name) else {
        check(false, "\(name).xcstrings is readable from the repository root")
        continue
    }
    var missing: [String: Int] = [:]
    var badPlaceholders: [String] = []
    var badPlurals: [String] = []
    var stale = 0
    var translatable = 0
    for (key, entry) in catalog.strings {
        if entry["extractionState"] as? String == "stale" { stale += 1; continue }
        if entry["shouldTranslate"] as? Bool == false { continue }
        translatable += 1
        let localizations = entry["localizations"] as? [String: [String: Any]] ?? [:]
        let english = localizations["en"].map(values(of:)) ?? [key]
        let source = placeholders(english.first ?? key)
        let isPlural = (localizations["en"]?["variations"] as? [String: Any])?["plural"] != nil
        for language in languages {
            guard let localization = localizations[language] else {
                missing[language, default: 0] += 1
                continue
            }
            for value in values(of: localization) where placeholders(value) != source {
                badPlaceholders.append("\(language): \(key)")
            }
            if isPlural {
                let plural = (localization["variations"] as? [String: Any])?["plural"] as? [String: Any]
                let wanted = language == "ja" ? ["other"] : ["one", "other"]
                if plural == nil || !wanted.allSatisfy({ plural?[$0] != nil }) { badPlurals.append("\(language): \(key)") }
            }
        }
    }
    check(translatable > 0, "\(name): \(translatable) translatable keys")
    check(stale == 0, "\(name): no stale keys (\(stale))")
    for language in languages {
        check(missing[language] == nil, "\(name): every key has \(language) (\(missing[language] ?? 0) missing)")
    }
    check(badPlaceholders.isEmpty, "\(name): placeholders survive translation \(badPlaceholders.prefix(3))")
    check(badPlurals.isEmpty, "\(name): count-based strings have plural forms \(badPlurals.prefix(3))")
}

// The safety vocabulary resolves to real words in the development language.
check(SafetyTag.allCases.allSatisfy { !$0.label.isEmpty && !$0.headline.isEmpty && !$0.blurb.isEmpty },
      "Safe / Review / Protected labels, headlines and blurbs resolve")
check(Catalog.groupOrder.allSatisfy { !Catalog.groupDisplayName($0).isEmpty }, "every group has a display name")
check(Catalog.groupDisplayName("Project artifacts") == "Project artifacts", "group display names fall back to the key")

// MARK: - 7. Live checks (--live): this machine's real scan

if CommandLine.arguments.contains("--live") {
    section("Live scan (slow)")

    let groups = Scanner.scanCatalog()
    check(!groups.isEmpty, "catalog scan finds something on a dev machine")

    let leaves = groups.flatMap(\.items).flatMap(\.deletableLeaves)
    let blocked = leaves.filter { !SafetyGuard.isDeletable($0.url) }
    check(blocked.isEmpty, "every offered row passes the guard (\(blocked.count) blocked)")

    // Expansion must offer only directories — a file row here means another
    // ~/.gem/credentials could slip through.
    let fileLeaves = leaves.filter {
        var isDir: ObjCBool = false
        return fm.fileExists(atPath: $0.url.path, isDirectory: &isDir) && !isDir.boolValue
    }
    check(fileLeaves.isEmpty, "no loose files offered \(fileLeaves.map(\.url.lastPathComponent))")

    // No offered path may contain another — that would double-count and
    // double-delete.
    let paths = leaves.map(\.url.standardizedFileURL.path).sorted()
    var nested: [String] = []
    for (i, p) in paths.enumerated() {
        if i + 1 < paths.count, paths[i + 1].hasPrefix(p + "/") { nested.append(paths[i + 1]) }
    }
    check(nested.isEmpty, "no offered row contains another \(nested.prefix(3))")

    var seen = Set<String>()
    let dupRows = paths.filter { !seen.insert($0).inserted }
    check(dupRows.isEmpty, "no row appears twice \(dupRows.prefix(3))")

    section("Live System Data scan (slow)")

    let edScanned = Scanner.scanCatalog(audience: .everyday)
    check(!edScanned.isEmpty, "System Data scan finds something on a real machine")
    check(edScanned.allSatisfy { everydayGroups.contains($0.name) },
          "System Data results carry only everyday groups \(edScanned.map(\.name))")

    let edLeaves = edScanned.flatMap(\.items).flatMap(\.deletableLeaves)
    let edBlocked = edLeaves.filter { !SafetyGuard.isDeletable($0.url) }
    check(edBlocked.isEmpty, "every System Data row passes the guard (\(edBlocked.count) blocked)")

    let edPaths = edLeaves.map(\.url.standardizedFileURL.path).sorted()
    var edNested: [String] = []
    for (i, p) in edPaths.enumerated() {
        if i + 1 < edPaths.count, edPaths[i + 1].hasPrefix(p + "/") { edNested.append(edPaths[i + 1]) }
    }
    check(edNested.isEmpty, "no System Data row contains another \(edNested.prefix(3))")

    let edFileLeaves = edLeaves.filter {
        var isDir: ObjCBool = false
        return fm.fileExists(atPath: $0.url.path, isDirectory: &isDir) && !isDir.boolValue
    }
    check(edFileLeaves.isEmpty, "no loose files offered in System Data \(edFileLeaves.map(\.url.lastPathComponent))")

    var edSeen = Set<String>()
    let edDupRows = edPaths.filter { !edSeen.insert($0).inserted }
    check(edDupRows.isEmpty, "no System Data row appears twice \(edDupRows.prefix(3))")

    // Streaming: partial assemblies arrive, and the final result is complete.
    // The callback fires from worker threads, so collect under a lock and
    // check afterwards.
    var emissions = 0
    var overshoot = false
    let emitLock = NSLock()
    let streamed = Scanner.scanCatalog(audience: .developer, onProgress: { _, done, total, _ in
        emitLock.lock()
        emissions += 1
        if done > total { overshoot = true }
        emitLock.unlock()
    })
    check(!streamed.isEmpty, "streaming scan returns the full result")
    check(emissions > 0, "partial results are emitted during measuring")
    check(!overshoot, "progress counter never overshoots")
    print("  info streaming emitted \(emissions) partial update\(emissions == 1 ? "" : "s")")
}

// MARK: - Summary

section("Cleanup")
removeFixtures()
check(!fm.fileExists(atPath: fixtureRoot.path), "fixture directory removed from $HOME")

print("\n\(passes) passed, \(failures) failed\n")
exit(failures == 0 ? 0 : 1)
