import Foundation
import SwiftUI

@MainActor
final class ScanModel: ObservableObject {
    @Published var groups: [ScanGroup] = []
    @Published var scanning = false
    @Published var status = "Ready."
    /// Sandbox build only: true when no folder has been granted yet, so the UI
    /// shows the "grant access" screen instead of an empty result.
    @Published var needsAccess = false
    @Published var selected: Set<String> = []      // keyed by absolute path
    @Published var lastReport: Scanner.DeleteReport?
    @Published var toolsMessage: String?

    /// Cleanups that a tool has to do for itself. Probed after each scan.
    @Published var pruneTools: [PruneTool] = []

    /// The boot volume, and whatever is still sitting in the Trash unemptied.
    @Published var disk: DiskSpace? = DiskSpace.current()
    @Published var trashBytes: Int64 = 0

    /// Folders the project walker is told to stay out of. Empty by default: the
    /// walk covers your whole home directory and takes about a second, so there is
    /// nothing to configure unless you actively want somewhere left alone.
    @Published var excluded: [URL] = []

    /// Which catalog the scan runs against: developer tooling, or the everyday
    /// caches (apps, logs, device backups) any Mac accumulates.
    @Published private(set) var audience: Audience = .developer

    private let excludedKey = "excludedFolders"
    private let audienceKey = "audience"

    init() {
        // Re-open any folders the user granted in a previous session. No-op outside
        // the sandbox, where the whole home directory is reachable already.
        SandboxAccess.loadGrants()
        needsAccess = !SandboxAccess.hasAccess

        let paths = UserDefaults.standard.stringArray(forKey: excludedKey) ?? []
        excluded = paths.map { URL(fileURLWithPath: $0) }
            .filter { FileManager.default.fileExists(atPath: $0.path) }

        if let raw = UserDefaults.standard.string(forKey: audienceKey),
           let saved = Audience(rawValue: raw) {
            audience = saved
            // A stored mode is a choice made in some session; never second-guess it.
            userPickedAudience = true
        }

        watchTrash()
    }

    /// True once the user has ever tapped the mode tabs themselves. Auto-mode
    /// only acts while this is false.
    private var userPickedAudience = false

    /// Switches between the Developer and System Data catalogs and rescans.
    /// Always available, even mid-scan: the scan in flight is cancelled (its
    /// results would land in the wrong list) and the new mode's scan starts as
    /// soon as it winds down — `rescan` queues itself behind a running scan.
    func setAudience(_ new: Audience) {
        guard new != audience else { return }
        audience = new
        userPickedAudience = true
        UserDefaults.standard.set(new.rawValue, forKey: audienceKey)
        selected.removeAll()
        // The old mode's rows must not linger while the new mode loads — clear
        // now, so the scan streams the new catalog into an empty list instead.
        groups = []
        if scanning {
            scanCancel?.cancel()
            status = "Loading \(new.label)…"
        }
        rescan()
    }

    // MARK: - Sandbox folder grants

    /// Folders the user has granted access to (sandbox build only).
    var grantedRoots: [URL] { SandboxAccess.roots }

    /// True in the App Store (sandboxed) build. Drives the folder-grant UI.
    var isSandboxed: Bool { SandboxAccess.isSandboxed }

    /// Whether the home folder itself is granted — the cache catalog needs it.
    /// When false, only project artifacts inside granted subfolders are found.
    var homeGranted: Bool { SandboxAccess.homeRoot != nil }

    #if canImport(AppKit)
    /// Asks the user to grant a folder, then rescans if they did. `preferHome`
    /// opens the picker so the whole home folder is easy to select in one click.
    func requestAccess(preferHome: Bool = false) {
        if SandboxAccess.requestAccess(preferHome: preferHome) != nil { rescan() }
    }
    #endif

    /// Revokes a granted folder and refreshes — or returns to the grant screen if
    /// that was the last one.
    func removeGrant(_ url: URL) {
        SandboxAccess.removeGrant(url)
        if SandboxAccess.hasAccess {
            rescan()
        } else {
            groups = []
            selected.removeAll()
            needsAccess = true
            status = "Grant DevSweep a folder to scan."
        }
    }

    // MARK: - Derived

    /// Every leaf row currently ticked, resolved back to real items.
    var selectedItems: [ScanItem] {
        allLeaves.filter { selected.contains($0.id) }
    }

    var selectedBytes: Int64 {
        selectedItems.reduce(0) { $0 + $1.bytes }
    }

    var reclaimableBytes: Int64 {
        groups.flatMap(\.items).filter { $0.tag != .never }.reduce(0) { $0 + $1.totalBytes }
    }

    var safeBytes: Int64 {
        groups.flatMap(\.items).filter { $0.tag == .safe }.reduce(0) { $0 + $1.totalBytes }
    }

    private var allLeaves: [ScanItem] {
        groups.flatMap(\.items).flatMap(\.deletableLeaves)
    }

    // MARK: - Selection

    func isSelected(_ item: ScanItem) -> Bool {
        if item.isContainer {
            let leaves = item.deletableLeaves
            return !leaves.isEmpty && leaves.allSatisfy { selected.contains($0.id) }
        }
        return selected.contains(item.id)
    }

    func isPartiallySelected(_ item: ScanItem) -> Bool {
        guard item.isContainer else { return false }
        let leaves = item.deletableLeaves
        let hit = leaves.filter { selected.contains($0.id) }.count
        return hit > 0 && hit < leaves.count
    }

    func toggle(_ item: ScanItem) {
        let leaves = item.deletableLeaves
        guard !leaves.isEmpty else { return }
        if isSelected(item) {
            leaves.forEach { selected.remove($0.id) }
        } else {
            leaves.forEach { selected.insert($0.id) }
        }
    }

    func selectAllSafe() {
        for group in groups {
            for item in group.items where item.tag == .safe {
                item.deletableLeaves.forEach { selected.insert($0.id) }
            }
        }
    }

    func clearSelection() { selected.removeAll() }

    // MARK: - Scanning

    /// A rescan asked for while one is already running (folder excluded, grant
    /// removed mid-scan) must not be silently dropped — it runs right after.
    private var rescanQueued = false

    /// Cancels the scan currently in flight. A fresh flag is made per scan.
    private var scanCancel: CancelFlag?

    func rescan() {
        guard !scanning else { rescanQueued = true; return }

        // Sandbox build: nothing is reachable until the user grants a folder.
        guard SandboxAccess.hasAccess else {
            needsAccess = true
            status = "Grant DevSweep a folder to scan."
            return
        }
        needsAccess = false

        scanning = true
        status = "Measuring caches…"
        lastReport = nil
        let skip = Set(excluded.map(\.standardizedFileURL.path))
        let audience = self.audience
        // Streaming partial results only helps when there is nothing on screen
        // yet; a rescan keeps the previous list visible until the new one is done.
        let streamPartials = groups.isEmpty
        // Outside the sandbox the whole home is walked; inside, the granted roots
        // normalised so an ancestor grant still starts at the home folder.
        let projectRoots = SandboxAccess.projectRoots
        // The cache catalog is home-relative, so it can only run when the home
        // folder itself was granted. A subfolder grant still gets a project scan.
        let runCatalog = !SandboxAccess.isSandboxed || SandboxAccess.homeRoot != nil

        let cancel = CancelFlag()
        scanCancel = cancel

        Task.detached(priority: .userInitiated) {
            var result = runCatalog
                ? Scanner.scanCatalog(audience: audience, cancel: cancel, onProgress: { partial, done, total in
                    Task { @MainActor in
                        guard self.scanning, !cancel.isCancelled else { return }
                        self.status = "Measuring caches… \(done) of \(total)"
                        if streamPartials { self.groups = partial }
                    }
                })
                : []

            // A cancelled scan publishes nothing and skips straight to winding
            // down — its numbers belong to a mode the user has already left.
            if !cancel.isCancelled {
                let space = DiskSpace.current()
                let trash = Scanner.trashSize()
                await MainActor.run {
                    self.disk = space
                    self.trashBytes = trash
                    self.lastTrashMtime = Self.trashMtime()
                    if audience == .developer { self.status = "Scanning your projects…" }
                }
            }

            // Project build output is developer clutter; the System Data catalog
            // stays out of people's repositories entirely.
            if audience == .developer, !cancel.isCancelled,
               let projects = Scanner.scanProjects(roots: projectRoots, excluding: skip, cancel: cancel) {
                result.append(projects)
            }

            let scanned = result
            await MainActor.run {
                if !cancel.isCancelled {
                    let stillValid = Set(scanned.flatMap(\.items).flatMap(\.deletableLeaves).map(\.id))
                    self.selected.formIntersection(stillValid)
                    self.groups = scanned
                    self.status = "Scanned \(scanned.count) categories."

                    // A Developer scan that found literally nothing, on a machine
                    // whose user never touched the tabs, means this isn't a
                    // developer's Mac — show them the mode made for them. Only
                    // when the catalog actually ran; a grant-less sandbox scan
                    // proves nothing.
                    if runCatalog, AutoMode.shouldSwitchToSystemData(
                        groups: scanned, audience: audience, userPicked: self.userPickedAudience) {
                        self.audience = .everyday
                        self.status = "No developer caches here — showing System Data."
                        self.rescanQueued = true
                    }
                }
                self.scanning = false
                if self.rescanQueued {
                    self.rescanQueued = false
                    self.rescan()
                }
            }

            // Probing Docker and Homebrew means running their CLIs, which is slow
            // and can hang — and is blocked entirely under the sandbox. Skip it there.
            guard !SandboxAccess.isSandboxed, audience == .developer, !cancel.isCancelled else { return }
            let tools = Scanner.availablePruneTools()
            await MainActor.run {
                if !cancel.isCancelled { self.pruneTools = tools }
            }
        }
    }

    // MARK: - Actions

    func trashSelected() {
        let items = selectedItems
        guard !items.isEmpty else { return }
        scanning = true
        status = "Moving \(items.count) item\(items.count == 1 ? "" : "s") to the Trash…"

        Task.detached(priority: .userInitiated) {
            let report = Scanner.trash(items)
            // Re-read the numbers the deletion changed. Everything else is known:
            // the rows that moved are simply removed, no full rescan needed.
            let space = DiskSpace.current()
            let trash = Scanner.trashSize()
            await MainActor.run {
                self.lastReport = report
                self.remove(paths: Set(report.movedURLs.map(\.path)))
                self.disk = space
                self.trashBytes = trash
                self.lastTrashMtime = Self.trashMtime()
                self.scanning = false
                self.status = "Moved \(report.moved) item\(report.moved == 1 ? "" : "s") to the Trash."
                if self.rescanQueued {
                    self.rescanQueued = false
                    self.rescan()
                }
            }
        }
    }

    /// Puts everything from the last "Move to Trash" back where it was — the one
    /// undo DevSweep offers. Rescans afterwards so the rows reappear.
    func undoLastClean() {
        guard let report = lastReport, !report.moves.isEmpty, !scanning else { return }
        lastReport = nil
        scanning = true
        status = "Putting \(report.moved) item\(report.moved == 1 ? "" : "s") back…"

        Task.detached(priority: .userInitiated) {
            let result = Scanner.restore(report)
            await MainActor.run {
                self.scanning = false
                self.status = result.skipped == 0
                    ? "Put back \(result.restored) item\(result.restored == 1 ? "" : "s")."
                    : "Put back \(result.restored) — \(result.skipped) could not go back."
                self.rescan()
            }
        }
    }

    /// Drops rows from the list and clears any selection that pointed at them.
    private func remove(paths: Set<String>) {
        guard !paths.isEmpty else { return }
        groups = groups.removing(paths: paths)
        let stillValid = Set(groups.flatMap(\.items).flatMap(\.deletableLeaves).map(\.id))
        selected.formIntersection(stillValid)
    }

    /// Cheap catch-up when the user comes back from Finder or a terminal: rows
    /// whose directories no longer exist disappear, and the disk and Trash
    /// numbers are re-read. A stat per row, not a rescan — safe to run on every
    /// app activation, which is exactly when external deletions become visible.
    /// Runs even with an empty list: the disk gauge and Trash footer still need
    /// fresh numbers after everything was cleaned.
    func refreshExternalChanges() {
        guard !scanning, !refreshing else { return }
        refreshing = true
        let candidates = groups.flatMap(\.items).flatMap { [$0] + $0.children }.map(\.url.path)
        // Re-walking a full Trash on every activation is thousands of stats.
        // Its directory's mtime changes whenever anything is added or removed,
        // so an unchanged mtime means the last measurement still holds.
        let knownMtime = lastTrashMtime
        let knownBytes = trashBytes

        Task.detached(priority: .utility) {
            let fm = FileManager.default
            let gone = Set(candidates.filter { !fm.fileExists(atPath: $0) })
            let space = DiskSpace.current()
            let mtime = Self.trashMtime()
            let trash = (mtime != nil && mtime == knownMtime) ? knownBytes : Scanner.trashSize()
            await MainActor.run {
                self.remove(paths: gone)
                self.disk = space
                self.trashBytes = trash
                self.lastTrashMtime = mtime
                self.refreshing = false
                self.scheduleDiskRecheck()
            }
        }
    }

    private var refreshing = false
    private var lastTrashMtime: Date?

    private nonisolated static func trashMtime() -> Date? {
        let path = SafetyGuard.home.appendingPathComponent(".Trash").path
        return (try? FileManager.default.attributesOfItem(atPath: path))?[.modificationDate] as? Date
    }

    // MARK: - Trash watching

    private var trashWatch: DispatchSourceFileSystemObject?
    private var trashDebounce: DispatchWorkItem?
    private var diskRecheckPending = false

    /// Watches ~/.Trash so emptying the bin updates the gauge and footer at once,
    /// even while DevSweep stays frontmost — app activation alone would miss it.
    /// Fails silently where the Trash is unreachable (sandbox without a grant).
    private func watchTrash() {
        let path = SafetyGuard.home.appendingPathComponent(".Trash").path
        let fd = open(path, O_EVTONLY)
        guard fd >= 0 else { return }
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd, eventMask: .write, queue: .main)
        source.setEventHandler { [weak self] in self?.trashChanged() }
        source.setCancelHandler { close(fd) }
        source.resume()
        trashWatch = source
    }

    /// Emptying the Trash fires one event per removed item; coalesce the burst.
    private func trashChanged() {
        trashDebounce?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.refreshExternalChanges() }
        trashDebounce = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8, execute: work)
    }

    /// Finder's free-space number (`forImportantUsage`) can trail a big deletion
    /// by a few seconds. One follow-up read catches the settled value.
    private func scheduleDiskRecheck() {
        guard !diskRecheckPending else { return }
        diskRecheckPending = true
        Task.detached(priority: .utility) {
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            let space = DiskSpace.current()
            await MainActor.run {
                if let space { self.disk = space }
                self.diskRecheckPending = false
            }
        }
    }

    func exclude(_ url: URL) {
        let std = url.standardizedFileURL
        guard !excluded.contains(where: { $0.standardizedFileURL == std }) else { return }
        excluded.append(std)
        persistExclusions()
        rescan()
    }

    func stopExcluding(_ url: URL) {
        excluded.removeAll { $0.standardizedFileURL == url.standardizedFileURL }
        persistExclusions()
        rescan()
    }

    private func persistExclusions() {
        UserDefaults.standard.set(excluded.map(\.path), forKey: excludedKey)
    }

    /// Runs a tool's own cleanup. Unlike everything else in DevSweep this frees the
    /// space immediately — `ContentView` confirms that with the user beforehand.
    func runPrune(_ tool: PruneTool) {
        guard !scanning else { return }
        scanning = true
        status = "Running \(tool.title)…"

        Task.detached(priority: .userInitiated) {
            let message = Scanner.runPrune(tool)
            await MainActor.run {
                self.toolsMessage = message
                self.scanning = false
                self.rescan()
            }
        }
    }
}
