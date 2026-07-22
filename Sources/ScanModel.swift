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

    private let excludedKey = "excludedFolders"

    init() {
        // Re-open any folders the user granted in a previous session. No-op outside
        // the sandbox, where the whole home directory is reachable already.
        SandboxAccess.loadGrants()
        needsAccess = !SandboxAccess.hasAccess

        let paths = UserDefaults.standard.stringArray(forKey: excludedKey) ?? []
        excluded = paths.map { URL(fileURLWithPath: $0) }
            .filter { FileManager.default.fileExists(atPath: $0.path) }
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

    func rescan() {
        guard !scanning else { return }

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
        // Outside the sandbox the whole home is walked; inside, the granted roots
        // normalised so an ancestor grant still starts at the home folder.
        let projectRoots = SandboxAccess.projectRoots
        // The cache catalog is home-relative, so it can only run when the home
        // folder itself was granted. A subfolder grant still gets a project scan.
        let runCatalog = !SandboxAccess.isSandboxed || SandboxAccess.homeRoot != nil

        Task.detached(priority: .userInitiated) {
            var result = runCatalog ? Scanner.scanCatalog() : []

            let space = DiskSpace.current()
            let trash = Scanner.trashSize()
            await MainActor.run {
                self.disk = space
                self.trashBytes = trash
                self.status = "Scanning your projects…"
            }

            if let projects = Scanner.scanProjects(roots: projectRoots, excluding: skip) {
                result.append(projects)
            }

            let scanned = result
            await MainActor.run {
                let stillValid = Set(scanned.flatMap(\.items).flatMap(\.deletableLeaves).map(\.id))
                self.selected.formIntersection(stillValid)
                self.groups = scanned
                self.scanning = false
                self.status = "Scanned \(scanned.count) categories."
            }

            // Probing Docker and Homebrew means running their CLIs, which is slow
            // and can hang — and is blocked entirely under the sandbox. Skip it there.
            guard !SandboxAccess.isSandboxed else { return }
            let tools = Scanner.availablePruneTools()
            await MainActor.run { self.pruneTools = tools }
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
                self.scanning = false
                self.status = "Moved \(report.moved) item\(report.moved == 1 ? "" : "s") to the Trash."
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
    func refreshExternalChanges() {
        guard !scanning, !refreshing, !groups.isEmpty else { return }
        refreshing = true
        let candidates = groups.flatMap(\.items).flatMap { [$0] + $0.children }.map(\.url.path)

        Task.detached(priority: .utility) {
            let fm = FileManager.default
            let gone = Set(candidates.filter { !fm.fileExists(atPath: $0) })
            let space = DiskSpace.current()
            let trash = Scanner.trashSize()
            await MainActor.run {
                self.remove(paths: gone)
                self.disk = space
                self.trashBytes = trash
                self.refreshing = false
            }
        }
    }

    private var refreshing = false

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
