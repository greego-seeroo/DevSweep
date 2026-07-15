import Foundation

// DevSweep's test suite. Run with ./test.sh, or ./test.sh --live to add the
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
// It is removed at the end, and the name is impossible to collide with.
let fixtureRoot = h(".devsweep-tests-\(ProcessInfo.processInfo.processIdentifier)")

func fixture(_ p: String, bytes: Int = 4096) {
    let u = fixtureRoot.appendingPathComponent(p)
    try? fm.createDirectory(at: u.deletingLastPathComponent(), withIntermediateDirectories: true)
    fm.createFile(atPath: u.path, contents: Data(repeating: 0x41, count: bytes))
}

func fixtureDir(_ p: String) {
    try? fm.createDirectory(at: fixtureRoot.appendingPathComponent(p), withIntermediateDirectories: true)
}

defer { try? fm.removeItem(at: fixtureRoot) }

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
// Best-effort tidy-up of our fixture from the Trash; the name is unique to this run.
try? fm.removeItem(at: h(".Trash/\(victimName)"))

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
}

// MARK: - Summary

print("\n\(passes) passed, \(failures) failed\n")
exit(failures == 0 ? 0 : 1)
