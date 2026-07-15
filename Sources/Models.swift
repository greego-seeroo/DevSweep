import Foundation

// MARK: - Safety tags

enum SafetyTag: Int, Comparable, CaseIterable {
    case safe = 0
    case review = 1
    case never = 2

    var label: String {
        switch self {
        case .safe: return "Safe"
        case .review: return "Review"
        case .never: return "Protected"
        }
    }

    var headline: String {
        switch self {
        case .safe: return "Safe to delete"
        case .review: return "Read before deleting"
        case .never: return "Protected"
        }
    }

    var blurb: String {
        switch self {
        case .safe: return "Leftover files that your tools rebuild automatically. Deleting them costs you nothing but one slower build."
        case .review: return "These come back too, but slowly — a big download or a long rebuild. Each row says what it costs. Read it before you tick."
        case .never: return "Settings, credentials and the tools themselves. DevSweep will not touch these; they are shown so you can see they were considered."
        }
    }

    static func < (a: SafetyTag, b: SafetyTag) -> Bool { a.rawValue < b.rawValue }
}

// MARK: - Scan items

struct ScanItem: Identifiable, Hashable {
    var id: String { url.path }
    let title: String
    let note: String
    let url: URL
    let tag: SafetyTag
    var bytes: Int64 = 0
    var children: [ScanItem] = []

    var isContainer: Bool { !children.isEmpty }

    /// Total bytes this row represents.
    var totalBytes: Int64 {
        isContainer ? children.reduce(0) { $0 + $1.bytes } : bytes
    }

    /// Rows that a delete would actually act on.
    var deletableLeaves: [ScanItem] {
        guard tag != .never else { return [] }
        if isContainer { return children.filter { SafetyGuard.isDeletable($0.url) } }
        return SafetyGuard.isDeletable(url) ? [self] : []
    }
}

struct ScanGroup: Identifiable {
    var id: String { name }
    let name: String
    var items: [ScanItem]

    var totalBytes: Int64 { items.reduce(0) { $0 + $1.totalBytes } }
}

extension Array where Element == ScanGroup {
    /// The same groups with every row at one of `paths` removed. Used when rows
    /// stop existing — trashed by us, or deleted behind our back — so the list
    /// reflects reality immediately instead of after a full rescan.
    ///
    /// Mirrors `scanCatalog`'s rule for empties: a row that ends up at zero bytes
    /// disappears unless it is Protected, which is shown regardless of size.
    func removing(paths: Set<String>) -> [ScanGroup] {
        guard !paths.isEmpty else { return self }
        return compactMap { group in
            let items = group.items.compactMap { item -> ScanItem? in
                guard !paths.contains(item.id) else { return nil }
                var item = item
                item.children.removeAll { paths.contains($0.id) }
                if item.totalBytes == 0 && item.tag != .never { return nil }
                return item
            }
            return items.isEmpty ? nil : ScanGroup(name: group.name, items: items)
        }
    }
}

// MARK: - The guard rail

/// Every path that DevSweep is ever asked to delete passes through here first.
/// This is deliberately paranoid and independent of the catalog: even if a rule
/// or the project scanner produced a bad path, nothing outside these bounds moves.
enum SafetyGuard {
    /// The home directory every rule and the safety boundary are measured against.
    /// Outside the sandbox this is the real home. Inside it, `homeDirectoryForCurrentUser`
    /// points at the empty app container, so we use the folder the user granted
    /// (which resolves to their real home) — see `SandboxAccess`.
    static var home: URL {
        SandboxAccess.homeRoot ?? SandboxAccess.realHome
    }

    /// Directories that may never be deleted themselves. Their children still can be.
    /// Every container that holds a mix of cache and non-cache belongs here: the
    /// catalog may offer what is inside, never the box itself.
    private static let protectedExact: Set<String> = [
        "",
        // macOS
        "Library",
        "Library/Caches",
        "Library/Developer",
        "Library/Developer/Xcode",
        "Library/Developer/CoreSimulator",
        "Library/Application Support",
        "Library/Logs",
        "Library/Android",
        "Library/Android/sdk",
        "Applications",
        "Documents",
        "Desktop",
        "Downloads",
        "Pictures",
        "Movies",
        "Music",
        // Shared cache roots
        ".cache",
        ".local",
        ".local/share",
        ".config",
        // Toolchain and package-manager roots
        ".android",
        ".gradle",
        ".npm",
        ".m2",
        ".ivy2",
        ".sbt",
        ".coursier",
        ".yarn",
        ".cocoapods",
        ".cargo",
        ".rustup",
        ".pub-cache",
        ".composer",
        ".nuget",
        ".gem",
        ".bundle",
        ".conan2",
        ".bun",
        ".deno",
        "go",
        "go/pkg",
        // Version managers — the box stays, the download caches inside may go
        ".nvm",
        ".pyenv",
        ".rbenv",
        ".rvm",
        ".asdf",
        ".volta",
        ".sdkman",
        ".ghcup",
        ".stack",
        "fvm",
        ".fvm",
        // Conda prefixes
        "miniconda3",
        "anaconda3",
        "miniforge3",
        "mambaforge",
        "opt",
        "opt/miniconda3",
        "opt/anaconda3",
        // Editors
        "Library/Application Support/Code",
        "Library/Application Support/Cursor",
        "Library/Application Support/Windsurf",
        // Containers and infra
        ".docker",
        ".kube",
        ".minikube",
        ".terraform.d",
        ".vagrant.d",
        // Engines and ML
        "Library/Unity",
        ".ollama",
    ]

    /// Nothing at or beneath these ever moves. Credentials, signing material,
    /// editor settings, sandboxed app data — none of it is a cache.
    private static let protectedPrefixes: [String] = [
        // Credentials and keys
        ".ssh",
        ".gnupg",
        ".aws",
        ".azure",
        ".config/gcloud",
        ".password-store",
        ".netrc",
        ".gem/credentials",     // your RubyGems API key, sat in the middle of a cache
        "Library/Keychains",
        "Library/MobileDevice",
        // Editor and IDE settings — losing these loses your setup, not a build
        "Library/Developer/Xcode/UserData",
        "Library/Developer/Xcode/Templates",
        "Library/Application Support/Code/User",
        "Library/Application Support/Cursor/User",
        "Library/Application Support/Windsurf/User",
        "Library/Application Support/JetBrains",
        // Sandboxed app data. Docker's disk image lives here — see the prune tools.
        "Library/Containers",
        "Library/Group Containers",
    ]

    /// Directory names the project scanner is allowed to propose. The scanner will
    /// not offer a directory unless its name is on this list *and* its parent
    /// carries the matching project marker — but this list is the hard ceiling,
    /// checked independently of whatever the catalog thinks.
    static let projectArtifactNames: Set<String> = [
        // Mobile / Apple
        "build", ".dart_tool", "Pods", "DerivedData", ".build", "Carthage",
        // JVM
        ".gradle", "target", "out",
        // Node / web
        "node_modules", "dist", ".next", ".nuxt", ".svelte-kit", ".angular",
        ".turbo", ".parcel-cache", ".vite",
        // Python
        ".venv", "venv", ".tox", ".pytest_cache", ".mypy_cache", ".ruff_cache",
        // .NET
        "bin", "obj",
        // PHP / Go
        "vendor",
        // Rust is "target", shared with Maven above
        // Elixir / OCaml / Haskell / Elm
        "_build", "deps", ".stack-work", "elm-stuff",
        // Native
        "cmake-build-debug", "cmake-build-release",
        // Game engines
        "Library", "Intermediate", "Binaries", "DerivedDataCache",
        // Infra
        ".terraform",
    ]

    static func isDeletable(_ url: URL) -> Bool {
        let path = url.standardizedFileURL.path
        let homePath = home.path

        // Must live strictly inside the user's home directory.
        guard path.hasPrefix(homePath + "/") else { return false }

        let rel = String(path.dropFirst(homePath.count + 1))
        guard !rel.isEmpty else { return false }

        // No traversal tricks.
        guard !rel.contains("..") else { return false }

        if protectedExact.contains(rel) { return false }
        for prefix in protectedPrefixes {
            if rel == prefix || rel.hasPrefix(prefix + "/") { return false }
        }

        // Refuse to follow a symlink out of bounds.
        let resolved = url.resolvingSymlinksInPath().standardizedFileURL.path
        guard resolved.hasPrefix(homePath + "/") else { return false }

        return true
    }
}

// MARK: - The disk itself

/// What the boot volume looks like right now. `free` is the capacity macOS will
/// actually hand to an app that asks for it — which is not the same as
/// total-minus-used, because it counts purgeable space that the system will
/// evict under pressure. It is the number Finder shows you.
struct DiskSpace {
    let total: Int64
    let free: Int64

    var used: Int64 { max(0, total - free) }

    static func current() -> DiskSpace? {
        let keys: Set<URLResourceKey> = [
            .volumeTotalCapacityKey,
            .volumeAvailableCapacityForImportantUsageKey,
            .volumeAvailableCapacityKey,
        ]
        guard let values = try? SafetyGuard.home.resourceValues(forKeys: keys),
              let total = values.volumeTotalCapacity
        else { return nil }

        // `forImportantUsage` is the honest one; fall back if the volume won't say.
        let free: Int64
        if let important = values.volumeAvailableCapacityForImportantUsage {
            free = important
        } else {
            free = Int64(values.volumeAvailableCapacity ?? 0)
        }

        return DiskSpace(total: Int64(total), free: free)
    }
}

// MARK: - Formatting

enum Fmt {
    static let bytes: ByteCountFormatter = {
        let f = ByteCountFormatter()
        f.countStyle = .file
        f.allowsNonnumericFormatting = false
        return f
    }()

    static func size(_ n: Int64) -> String {
        n <= 0 ? "—" : bytes.string(fromByteCount: n)
    }
}
