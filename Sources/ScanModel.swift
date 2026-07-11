import Foundation
import SwiftUI

@MainActor
final class ScanModel: ObservableObject {
    @Published var groups: [ScanGroup] = []
    @Published var scanning = false
    @Published var status = "Ready."
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
        let paths = UserDefaults.standard.stringArray(forKey: excludedKey) ?? []
        excluded = paths.map { URL(fileURLWithPath: $0) }
            .filter { FileManager.default.fileExists(atPath: $0.path) }
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
        scanning = true
        status = "Measuring caches…"
        lastReport = nil
        let skip = Set(excluded.map(\.standardizedFileURL.path))

        Task.detached(priority: .userInitiated) {
            var result = Scanner.scanCatalog()

            let space = DiskSpace.current()
            let trash = Scanner.trashSize()
            await MainActor.run {
                self.disk = space
                self.trashBytes = trash
                self.status = "Scanning your projects…"
            }

            if let projects = Scanner.scanProjects(roots: [SafetyGuard.home], excluding: skip) {
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
            // and can hang. Do it after the list is already on screen.
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
            await MainActor.run {
                self.lastReport = report
                self.selected.removeAll()
                self.scanning = false
                self.status = "Moved \(report.moved) item\(report.moved == 1 ? "" : "s") to the Trash."
                self.rescan()
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
