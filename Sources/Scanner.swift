import Foundation
#if canImport(AppKit)
import AppKit
#endif

// MARK: - Shell

/// Runs short-lived helper commands (`du`, `go env`, `docker system df`). Everything
/// here is read-only or explicitly requested by the user; nothing shells out to
/// delete a file — that is `FileManager.trashItem`'s job alone.
enum Shell {
    struct Result {
        let status: Int32
        let output: String
        let timedOut: Bool
    }

    /// A login shell, because the tools we ask about (`go`, `docker`, `brew`) live
    /// wherever the user's PATH says they do. The timeout matters: a Docker CLI with
    /// no daemon behind it will sit there for a long time otherwise.
    @discardableResult
    static func run(_ command: String, timeout: TimeInterval = 20) -> Result {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-lc", command]

        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        p.standardInput = FileHandle.nullDevice

        do { try p.run() } catch { return Result(status: -1, output: "", timedOut: false) }

        // Drain the pipe on another thread. A command that writes more than the pipe
        // buffer would otherwise block forever while we sit in wait().
        let box = Box()
        let finished = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .userInitiated).async {
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            box.set(String(data: data, encoding: .utf8) ?? "")
            finished.signal()
        }

        var timedOut = false
        if finished.wait(timeout: .now() + timeout) == .timedOut {
            timedOut = true
            p.terminate()
            _ = finished.wait(timeout: .now() + 3)
        }
        p.waitUntilExit()

        return Result(status: p.terminationStatus, output: box.get(), timedOut: timedOut)
    }

    /// Is this command on the PATH at all?
    static func exists(_ tool: String) -> Bool {
        run("command -v \(tool)", timeout: 5).status == 0
    }

    private final class Box: @unchecked Sendable {
        private let lock = NSLock()
        private var value = ""
        func set(_ v: String) { lock.lock(); value = v; lock.unlock() }
        func get() -> String { lock.lock(); defer { lock.unlock() }; return value }
    }
}

// MARK: - Size parsing

enum SizeText {
    /// Pulls human-readable sizes ("1.2GB", "512 MiB", "0B") out of a tool's output.
    /// Used only to *show* what a prune would reclaim — never to decide anything, so
    /// a miss costs a missing number in a menu and nothing else.
    static func sizes(in text: String) -> [Int64] {
        let chars = Array(text)
        var out: [Int64] = []
        var i = 0

        while i < chars.count {
            guard chars[i].isNumber else { i += 1; continue }

            // The number has to start at a boundary, or "sha256" reads as 256.
            if i > 0 {
                let prev = chars[i - 1]
                if prev.isLetter || prev.isNumber || prev == "." { i += 1; continue }
            }

            var end = i
            while end < chars.count, chars[end].isNumber { end += 1 }
            if end + 1 < chars.count, chars[end] == ".", chars[end + 1].isNumber {
                end += 1
                while end < chars.count, chars[end].isNumber { end += 1 }
            }
            let number = Double(String(chars[i ..< end])) ?? 0

            var unitStart = end
            while unitStart < chars.count, chars[unitStart] == " " { unitStart += 1 }
            var unitEnd = unitStart
            while unitEnd < chars.count, chars[unitEnd].isLetter { unitEnd += 1 }

            if let scale = multiplier(String(chars[unitStart ..< unitEnd]).lowercased()) {
                out.append(Int64(number * scale))
            }
            i = max(end, unitEnd)
        }
        return out
    }

    private static func multiplier(_ unit: String) -> Double? {
        switch unit {
        case "b":          return 1
        case "k", "kb":    return 1_000
        case "kib":        return 1_024
        case "m", "mb":    return 1_000_000
        case "mib":        return 1_048_576
        case "g", "gb":    return 1_000_000_000
        case "gib":        return 1_073_741_824
        case "t", "tb":    return 1_000_000_000_000
        case "tib":        return 1_099_511_627_776
        default:           return nil
        }
    }
}

// MARK: - Prune tools

/// Space that cannot be reclaimed by moving a directory to the Trash, because the
/// tool that owns it keeps its data somewhere DevSweep will not touch (Docker's
/// disk image lives in ~/Library/Containers) or spread across places only the tool
/// knows. These run the tool's own cleanup command.
///
/// They free space immediately. Nothing goes to the Trash, and nothing comes back.
/// The UI says so, and asks before each one.
struct PruneTool: Identifiable, Hashable {
    let id: String
    let title: String
    /// What running it actually does, in the confirmation dialog.
    let detail: String
    /// Command that must succeed for this tool to be offered at all.
    let requires: String
    /// Command whose output we read a size out of. Nil means we can't preview.
    let probe: String?
    /// Add every size in the probe output rather than taking the largest.
    let sumsProbeSizes: Bool
    /// The command that reclaims the space.
    let command: String
    /// True when the operation genuinely cannot lose anything you'd want back.
    let harmless: Bool

    var reclaimable: Int64?

    static let all: [PruneTool] = [
        PruneTool(
            id: "simctl",
            title: "Delete unavailable simulators",
            detail: "Removes simulator devices whose runtime is no longer installed. Those devices cannot boot, so nothing usable is lost.",
            requires: "xcrun --find simctl",
            probe: nil,
            sumsProbeSizes: false,
            command: "xcrun simctl delete unavailable",
            harmless: true
        ),
        PruneTool(
            id: "docker",
            title: "Docker: prune unused data",
            detail: "Runs `docker system prune -f`: removes stopped containers, dangling images, unused networks and the build cache. Running containers, tagged images and named volumes are left alone. Docker keeps its disk image inside ~/Library/Containers, which DevSweep will not touch, so this is the only way to get that space back.",
            requires: "docker info",
            probe: "docker system df --format '{{.Reclaimable}}'",
            sumsProbeSizes: true,
            command: "docker system prune -f",
            harmless: false
        ),
        PruneTool(
            id: "brew",
            title: "Homebrew: full cleanup",
            detail: "Runs `brew cleanup`: removes outdated downloads and the old versions of formulae you have upgraded. Goes further than trashing the Homebrew cache directory, which only covers the downloads.",
            requires: "command -v brew",
            probe: "brew cleanup -n",
            sumsProbeSizes: false,
            command: "brew cleanup",
            harmless: false
        ),
        PruneTool(
            id: "nix",
            title: "Nix: collect garbage",
            detail: "Runs `nix-collect-garbage -d`: deletes store paths no longer reachable from a current generation, and drops old generations of your profiles. You cannot roll back to a deleted generation afterwards.",
            requires: "command -v nix-collect-garbage",
            probe: "nix-collect-garbage --dry-run 2>&1",
            sumsProbeSizes: false,
            command: "nix-collect-garbage -d",
            harmless: false
        ),
    ]
}

// MARK: - Cancellation

/// Set from the main thread to tell an in-flight scan to stop early — the user
/// switched modes and the results would land in the wrong list. The walkers
/// check it cooperatively; a cancelled scan returns fast and publishes nothing.
final class CancelFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var flag = false

    var isCancelled: Bool {
        lock.lock(); defer { lock.unlock() }
        return flag
    }

    func cancel() {
        lock.lock(); flag = true; lock.unlock()
    }
}

// MARK: - Scanner

enum Scanner {

    // MARK: - Sizing

    /// Sizes many directories at once, walking each tree in-process with `fts(3)`
    /// — the same machinery `du` itself is built on, so it is just as fast, works
    /// under the sandbox (no subprocess), and unlike the old FileManager walk it
    /// counts what is inside app bundles, which caches full of `.app`s (Electron,
    /// Playwright, simulator runtimes) are made of.
    static func sizes(of urls: [URL], cancel: CancelFlag? = nil) -> [String: Int64] {
        guard !urls.isEmpty else { return [:] }
        var result: [String: Int64] = [:]
        let lock = NSLock()
        DispatchQueue.concurrentPerform(iterations: urls.count) { i in
            guard cancel?.isCancelled != true else { return }
            let url = urls[i]
            let bytes = walkSize(url, cancel: cancel)
            lock.lock(); result[url.path] = bytes; lock.unlock()
        }
        return result
    }

    /// On-disk size of a file or directory, measured the way `du -x` does:
    /// allocated blocks, never following symlinks, never crossing volumes.
    private static func walkSize(_ url: URL, cancel: CancelFlag? = nil) -> Int64 {
        let path = strdup(url.path)
        defer { free(path) }
        var argv: [UnsafeMutablePointer<CChar>?] = [path, nil]

        // FTS_PHYSICAL: don't follow symlinks. FTS_XDEV: stay on one volume, or a
        // symlinked-in mount could balloon a cache's reported size.
        guard let fts = fts_open(&argv, FTS_PHYSICAL | FTS_XDEV | FTS_NOCHDIR, nil)
        else { return 0 }
        defer { fts_close(fts) }

        var total: Int64 = 0
        var seen = 0
        while let entry = fts_read(fts) {
            // A single huge tree (node_modules…) can take seconds; poll the flag
            // every so often, not per entry.
            seen += 1
            if seen & 0x3FF == 0, cancel?.isCancelled == true { break }

            switch Int32(entry.pointee.fts_info) {
            // Files, and each directory once (post-order); directories occupy
            // blocks too, which keeps the numbers matching what `du` reported.
            // Unreadable entries just contribute nothing.
            case FTS_F, FTS_DEFAULT, FTS_DP:
                if let st = entry.pointee.fts_statp {
                    total += Int64(st.pointee.st_blocks) * 512
                }
            default:
                break
            }
        }
        return total
    }

    /// How much is sitting in the Trash. Moving something there does not free a
    /// single byte, so the UI has to be able to say what is still waiting.
    static func trashSize() -> Int64 {
        let trash = SafetyGuard.home.appendingPathComponent(".Trash")
        guard FileManager.default.fileExists(atPath: trash.path) else { return 0 }
        return sizes(of: [trash])[trash.path] ?? 0
    }

    // MARK: - Catalog scan

    /// Scans the catalog for the given audience. `onProgress` (optional) is
    /// called from a background thread as directories finish measuring, with the
    /// groups assembled from everything measured so far plus done/total counts —
    /// the UI can show rows filling in instead of a blank wait.
    static func scanCatalog(audience: Audience = .developer,
                            cancel: CancelFlag? = nil,
                            onProgress: (([ScanGroup], Int, Int) -> Void)? = nil) -> [ScanGroup] {
        let fm = FileManager.default
        let rules = Catalog.activeRules(for: audience)

        // A rule that lives inside another rule's directory (~/.cache/pip inside
        // ~/.cache) must not also appear as one of that rule's children, or its
        // bytes would be counted twice and it would be offered from two places.
        let explicit = Set(rules.map { SafetyGuard.home.appendingPathComponent($0.relPath).standardizedFileURL.path })

        struct Pending {
            let rule: Rule
            let url: URL
            /// Immediate children to list as rows, display names resolved up
            /// front — one LaunchServices lookup per child, not per re-assembly.
            let children: [(url: URL, title: String, note: String)]
        }

        var pending: [Pending] = []
        var toMeasure: [URL] = []

        for rule in rules {
            let url = SafetyGuard.home.appendingPathComponent(rule.relPath)
            var children: [URL] = []

            if rule.expand {
                let contents = (try? fm.contentsOfDirectory(
                    at: url,
                    includingPropertiesForKeys: [.isDirectoryKey],
                    options: [.skipsHiddenFiles]
                )) ?? []
                children = contents
                    // Directories only. Loose files inside a cache root are not
                    // worth a row of their own, and some of them are not caches at
                    // all — ~/.gem/credentials is your RubyGems API key.
                    .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true }
                    // A rule that lives inside this one is offered under its own
                    // heading; listing it here too would double-count its bytes.
                    .filter { !explicit.contains($0.standardizedFileURL.path) }
                    .sorted { $0.lastPathComponent < $1.lastPathComponent }
            }

            if children.isEmpty {
                toMeasure.append(url)
            } else {
                toMeasure.append(contentsOf: children)
            }
            pending.append(Pending(rule: rule, url: url, children: children.map {
                let named = friendlyChild($0)
                return ($0, named.title, named.note)
            }))
        }

        func assemble(_ measured: [String: Int64]) -> [ScanGroup] {
            var byGroup: [String: [ScanItem]] = [:]
            for p in pending {
                let childItems: [ScanItem] = p.children.map { child in
                    ScanItem(
                        title: child.title,
                        note: child.note,
                        url: child.url,
                        tag: p.rule.tag,
                        bytes: measured[child.url.path] ?? 0
                    )
                }
                .filter { $0.bytes > 0 }
                .sorted { $0.bytes > $1.bytes }

                let item = ScanItem(
                    title: p.rule.title,
                    note: p.rule.note,
                    url: p.url,
                    tag: p.rule.tag,
                    bytes: childItems.isEmpty ? (measured[p.url.path] ?? 0) : 0,
                    children: childItems
                )

                // Empty non-protected entries are just noise.
                if item.totalBytes == 0 && item.tag != .never { continue }
                byGroup[p.rule.group, default: []].append(item)
            }

            return Catalog.groupOrder.compactMap { name in
                guard var items = byGroup[name], !items.isEmpty else { return nil }
                items.sort { lhs, rhs in
                    if lhs.tag != rhs.tag { return lhs.tag < rhs.tag }
                    return lhs.totalBytes > rhs.totalBytes
                }
                return ScanGroup(name: name, items: items)
            }
        }

        guard !toMeasure.isEmpty else { return assemble([:]) }

        // Measure concurrently, handing the caller a fresh assembly every so
        // often. Rows appear as their directories finish instead of after all.
        var measured: [String: Int64] = [:]
        var done = 0
        var lastEmit = DispatchTime.now()
        let lock = NSLock()
        let total = toMeasure.count

        DispatchQueue.concurrentPerform(iterations: total) { i in
            guard cancel?.isCancelled != true else { return }
            let bytes = walkSize(toMeasure[i], cancel: cancel)
            var snapshot: [String: Int64]?
            var count = 0
            lock.lock()
            measured[toMeasure[i].path] = bytes
            done += 1
            count = done
            if onProgress != nil, done < total {
                let now = DispatchTime.now()
                if now.uptimeNanoseconds - lastEmit.uptimeNanoseconds > 250_000_000 {
                    lastEmit = now
                    snapshot = measured
                }
            }
            lock.unlock()
            if let snapshot, cancel?.isCancelled != true {
                onProgress?(assemble(snapshot), count, total)
            }
        }
        return assemble(measured)
    }

    /// "com.spotify.client" means nothing to most people. When a cache folder is
    /// named by bundle identifier and that app is installed, show the app's name
    /// and keep the identifier as the row's note. Internal so the test suite can
    /// pin its behaviour — the confirm sheet leads with what this returns.
    static func friendlyChild(_ url: URL) -> (title: String, note: String) {
        let raw = url.lastPathComponent
        #if canImport(AppKit)
        if raw.contains("."), !raw.hasPrefix("."),
           let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: raw) {
            let name = app.deletingPathExtension().lastPathComponent
            if !name.isEmpty, name.lowercased() != raw.lowercased() {
                return (name, raw)
            }
        }
        #endif
        return (raw, "")
    }

    // MARK: - Project artifact scan

    /// Directories the walker will never descend into, whatever the depth budget
    /// says. Without this, pointing the scanner at your home folder would send it
    /// through all of ~/Library.
    private static let neverDescend: Set<String> = [
        "Library", "Applications", "Pictures", "Movies", "Music", ".Trash",
    ]

    /// Walks your repositories looking for regenerable build output. A directory
    /// only counts if its parent carries the matching project marker, so a source
    /// folder that happens to be called `build` — or a Unity project's `Library` —
    /// is judged on evidence, not on its name.
    ///
    /// Called with `$HOME` as the root: skipping `~/Library` and friends makes the
    /// whole walk take about a second, which is cheaper than asking the user where
    /// their code lives. `excluding` holds the paths they have asked it to skip.
    static func scanProjects(roots: [URL], excluding: Set<String> = [], maxDepth: Int = 7,
                             cancel: CancelFlag? = nil) -> ScanGroup? {
        let fm = FileManager.default
        let byName = Dictionary(grouping: Catalog.projectArtifacts, by: \.name)

        var hits: [(url: URL, artifact: ProjectArtifact)] = []

        func walk(_ dir: URL, depth: Int) {
            guard cancel?.isCancelled != true else { return }
            guard depth <= maxDepth, hits.count < 800 else { return }
            guard let entries = try? fm.contentsOfDirectory(
                at: dir,
                includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
                options: []
            ) else { return }

            for entry in entries {
                let values = try? entry.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
                guard values?.isDirectory == true, values?.isSymbolicLink != true else { continue }
                guard !excluding.contains(entry.standardizedFileURL.path) else { continue }

                let name = entry.lastPathComponent

                // The guard's allowlist is checked first and independently of the
                // catalog: a name the guard doesn't know is never even considered.
                if SafetyGuard.projectArtifactNames.contains(name),
                   let candidates = byName[name],
                   let artifact = candidates.first(where: { Catalog.markerPresent($0, in: dir) }) {
                    if SafetyGuard.isDeletable(entry) { hits.append((entry, artifact)) }
                    continue // never descend into what we're offering to delete
                }

                if neverDescend.contains(name) { continue }
                // Skip other dot-directories and anything obviously not a project.
                if name.hasPrefix(".") { continue }
                walk(entry, depth: depth + 1)
            }
        }

        for root in roots { walk(root, depth: 1) }
        guard !hits.isEmpty, cancel?.isCancelled != true else { return nil }

        let measured = sizes(of: hits.map(\.url), cancel: cancel)
        let items = hits.map { hit -> ScanItem in
            let parent = hit.url.deletingLastPathComponent()
            let where_ = parent.path.replacingOccurrences(of: SafetyGuard.home.path, with: "~")
            return ScanItem(
                title: "\(parent.lastPathComponent) › \(hit.url.lastPathComponent)",
                note: "\(hit.artifact.note)  ·  \(where_)",
                url: hit.url,
                tag: hit.artifact.tag,
                bytes: measured[hit.url.path] ?? 0
            )
        }
        .filter { $0.bytes > 0 }
        .sorted { lhs, rhs in
            if lhs.tag != rhs.tag { return lhs.tag < rhs.tag }
            return lhs.bytes > rhs.bytes
        }

        guard !items.isEmpty else { return nil }
        return ScanGroup(name: "Project artifacts", items: items)
    }

    // MARK: - Deletion

    struct DeleteReport {
        var freed: Int64 = 0
        var moved: Int = 0
        /// Where each item was, and where it landed in the Trash — enough to
        /// drop exactly those rows without a rescan, and to put them all back.
        var moves: [(original: URL, trashed: URL)] = []
        var failures: [(url: URL, reason: String)] = []

        /// The original locations of everything that went to the Trash.
        var movedURLs: [URL] { moves.map(\.original) }
    }

    /// Moves items to the Trash. Nothing here calls `removeItem`.
    static func trash(_ items: [ScanItem]) -> DeleteReport {
        var report = DeleteReport()
        let fm = FileManager.default

        for item in items {
            // Re-check at the moment of deletion, not just at selection time.
            guard SafetyGuard.isDeletable(item.url) else {
                report.failures.append((item.url, "blocked by safety guard"))
                continue
            }
            guard fm.fileExists(atPath: item.url.path) else { continue }

            do {
                var landed: NSURL?
                try fm.trashItem(at: item.url, resultingItemURL: &landed)
                report.freed += item.bytes
                report.moved += 1
                // If the system won't say where it landed (it always does), the
                // row is still removed; only Put Back skips that item.
                report.moves.append((item.url, (landed as URL?) ?? item.url))
            } catch {
                report.failures.append((item.url, error.localizedDescription))
            }
        }
        return report
    }

    /// Puts everything a report sent to the Trash back where it came from — the
    /// one undo DevSweep offers. Each destination is re-checked: it must be
    /// inside $HOME and must not exist again (a cache the tool already rebuilt
    /// is never overwritten). Anything that can't go back is skipped, not forced.
    static func restore(_ report: DeleteReport) -> (restored: Int, skipped: Int) {
        let fm = FileManager.default
        var restored = 0
        var skipped = 0

        for move in report.moves {
            let dest = move.original.standardizedFileURL
            guard dest.path.hasPrefix(SafetyGuard.home.path + "/"),
                  fm.fileExists(atPath: move.trashed.path),
                  !fm.fileExists(atPath: dest.path)
            else { skipped += 1; continue }

            do {
                try fm.moveItem(at: move.trashed, to: dest)
                restored += 1
            } catch {
                skipped += 1
            }
        }
        return (restored, skipped)
    }

    // MARK: - Prune tools

    /// Which prune tools are installed here, and how much each says it could free.
    /// Probes run in parallel and are all bounded: `docker info` with no daemon
    /// running must not hold up a scan.
    static func availablePruneTools() -> [PruneTool] {
        let tools = PruneTool.all
        var out = [PruneTool?](repeating: nil, count: tools.count)
        let lock = NSLock()

        DispatchQueue.concurrentPerform(iterations: tools.count) { i in
            var tool = tools[i]
            guard Shell.run(tool.requires, timeout: 10).status == 0 else { return }

            if let probe = tool.probe {
                let result = Shell.run(probe, timeout: 20)
                if result.status == 0, !result.timedOut {
                    let sizes = SizeText.sizes(in: result.output)
                    if !sizes.isEmpty {
                        tool.reclaimable = tool.sumsProbeSizes ? sizes.reduce(0, +) : (sizes.max() ?? 0)
                    }
                }
            }

            lock.lock()
            out[i] = tool
            lock.unlock()
        }

        return out.compactMap { $0 }
    }

    /// Runs a tool's own cleanup command. This does **not** go through the Trash —
    /// the UI confirms that with the user first.
    static func runPrune(_ tool: PruneTool) -> String {
        let result = Shell.run(tool.command, timeout: 300)
        let text = result.output.trimmingCharacters(in: .whitespacesAndNewlines)

        if result.timedOut {
            return text.isEmpty ? "\(tool.title) timed out." : "Timed out.\n\n\(text)"
        }
        if result.status != 0 {
            return text.isEmpty ? "\(tool.title) failed (exit \(result.status))." : text
        }
        return text.isEmpty ? "Nothing to clean up." : text
    }
}
