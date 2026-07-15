import SwiftUI
import AppKit

struct ContentView: View {
    @EnvironmentObject var model: ScanModel

    @State private var filter: SafetyTag? = nil
    @State private var expanded: Set<String> = []
    @State private var collapsed: Set<String> = []
    @State private var search = ""
    @State private var confirming = false
    @State private var pendingPrune: PruneTool?
    @FocusState private var searchFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
            Divider()
            footer
        }
        .frame(minWidth: 1060, minHeight: 620)
        .onAppear { if model.groups.isEmpty { model.rescan() } }
        // Coming back from Finder or a terminal is the moment external deletions
        // become visible — catch up without making the user rescan.
        .onReceive(NotificationCenter.default.publisher(
            for: NSApplication.didBecomeActiveNotification)) { _ in
            model.refreshExternalChanges()
        }
        .onChange(of: model.groups.map(\.name)) { _, names in autoCollapse(names) }
        .sheet(isPresented: $confirming) { ConfirmSheet(isPresented: $confirming) }
        .alert("Cleanup finished",
               isPresented: Binding(
                   get: { model.toolsMessage != nil },
                   set: { if !$0 { model.toolsMessage = nil } })) {
            Button("OK") { model.toolsMessage = nil }
        } message: {
            Text(model.toolsMessage ?? "")
        }
        .alert(
            pendingPrune?.title ?? "",
            isPresented: Binding(
                get: { pendingPrune != nil },
                set: { if !$0 { pendingPrune = nil } }),
            presenting: pendingPrune
        ) { tool in
            Button("Cancel", role: .cancel) { pendingPrune = nil }
            Button(tool.harmless ? "Run" : "Free space now",
                   role: tool.harmless ? nil : .destructive) {
                model.runPrune(tool)
                pendingPrune = nil
            }
        } message: { tool in
            Text(pruneWarning(for: tool))
        }
    }

    private func pruneWarning(for tool: PruneTool) -> String {
        var text = tool.detail
        if let bytes = tool.reclaimable, bytes > 0 {
            text += "\n\nIt reports about \(Fmt.size(bytes)) to reclaim."
        }
        if !tool.harmless {
            text += "\n\nThis one does not go through the Trash. The space comes back immediately and there is nothing to restore afterwards."
        }
        return text
    }

    /// A polyglot machine can produce twenty groups. Open the three biggest and
    /// leave the rest folded, so the first screen is readable rather than complete.
    private func autoCollapse(_ names: [String]) {
        guard names.count > 8 else { collapsed = []; return }
        let biggest = model.groups
            .sorted { $0.totalBytes > $1.totalBytes }
            .prefix(3)
            .map(\.name)
        collapsed = Set(names).subtracting(biggest)
    }

    // MARK: - Header

    private var header: some View {
        HStack(alignment: .center, spacing: 18) {
            VStack(alignment: .leading, spacing: 2) {
                Text(Fmt.size(model.reclaimableBytes))
                    .font(.system(size: 30, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .contentTransition(.numericText())
                Text("could be freed · \(Fmt.size(model.safeBytes)) of it is safe")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Divider().frame(height: 36)

            DiskGauge(disk: model.disk,
                      selected: model.selectedBytes,
                      trash: model.trashBytes)

            Spacer()

            if model.scanning {
                ProgressView().controlSize(.small)
                Text(model.status).font(.caption).foregroundStyle(.secondary)
            }

            // Sandbox build: let the user see and manage the folders they granted.
            if model.isSandboxed {
                Menu {
                    if model.grantedRoots.isEmpty {
                        Text("No folders granted yet")
                    } else {
                        Section("Folders DevSweep can scan") {
                            ForEach(model.grantedRoots, id: \.path) { folder in
                                Menu(short(folder)) {
                                    Button("Reveal in Finder") {
                                        NSWorkspace.shared.activateFileViewerSelecting([folder])
                                    }
                                    Button("Remove", role: .destructive) {
                                        model.removeGrant(folder)
                                    }
                                }
                            }
                        }
                    }
                    Divider()
                    if !model.homeGranted {
                        Button("Add Home Folder (finds all caches)…") {
                            model.requestAccess(preferHome: true)
                        }
                    }
                    Button("Add Another Folder…") { model.requestAccess() }
                } label: {
                    Label("Folders", systemImage: "folder")
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
            }

            SearchField(text: $search, focused: $searchFocused)
                .frame(width: 170)
                // An invisible button is the standard way to route a shortcut to
                // a focus change; TextField cannot carry one itself.
                .background(
                    Button("") { searchFocused = true }
                        .keyboardShortcut("f", modifiers: .command)
                        .opacity(0)
                )

            Picker("", selection: $filter) {
                Text("All").tag(SafetyTag?.none)
                ForEach(SafetyTag.allCases, id: \.self) { tag in
                    Text(tag.label).tag(SafetyTag?.some(tag))
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 240)

            Menu {
                Button("Select all safe items") { model.selectAllSafe() }
                Button("Clear selection") { model.clearSelection() }
                Divider()
                Button("Expand all groups") { collapsed.removeAll() }
                Button("Collapse all groups") { collapsed = Set(model.groups.map(\.name)) }
                Divider()

                // Cleanups only the owning tool can perform. Everything above this
                // line goes to the Trash; nothing below it does.
                if model.pruneTools.isEmpty {
                    Text("Looking for Docker, Homebrew…")
                } else {
                    Section("Run a tool's own cleanup") {
                        ForEach(model.pruneTools) { tool in
                            Button(pruneLabel(tool)) { pendingPrune = tool }
                        }
                    }
                }

                Divider()
                Button("Exclude a folder from project scanning…") { pickExclusion() }
                if !model.excluded.isEmpty {
                    Menu("Stop excluding") {
                        ForEach(model.excluded, id: \.path) { folder in
                            Button(folder.lastPathComponent) { model.stopExcluding(folder) }
                        }
                    }
                }
                Divider()
                Button("Open Trash") {
                    NSWorkspace.shared.open(
                        FileManager.default.homeDirectoryForCurrentUser
                            .appendingPathComponent(".Trash"))
                }
            } label: {
                Label("Tools", systemImage: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()

            Button {
                model.rescan()
            } label: {
                Label("Rescan", systemImage: "arrow.clockwise")
            }
            .disabled(model.scanning)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }

    // MARK: - List

    private var query: String {
        search.trimmingCharacters(in: .whitespaces).lowercased()
    }

    /// A row matches if its own title, note or path matches — or if one of its
    /// children does, since children are what you actually tick.
    private func matches(_ item: ScanItem) -> Bool {
        guard !query.isEmpty else { return true }
        func hit(_ i: ScanItem) -> Bool {
            i.title.lowercased().contains(query)
                || i.note.lowercased().contains(query)
                || i.url.path.lowercased().contains(query)
        }
        return hit(item) || item.children.contains(where: hit)
    }

    private var visibleGroups: [ScanGroup] {
        model.groups.compactMap { group in
            var items = group.items
            if let filter { items = items.filter { $0.tag == filter } }
            if !query.isEmpty {
                let groupMatches = group.name.lowercased().contains(query)
                if !groupMatches { items = items.filter(matches) }
            }
            return items.isEmpty ? nil : ScanGroup(name: group.name, items: items)
        }
    }

    /// While searching, everything on screen is already a match — folding it away
    /// would just hide the answer.
    private func isCollapsed(_ group: ScanGroup) -> Bool {
        query.isEmpty && collapsed.contains(group.name)
    }

    @ViewBuilder
    private var content: some View {
        if let report = model.lastReport, report.moved > 0 || !report.failures.isEmpty {
            ReportBanner(report: report) { model.lastReport = nil }
        }

        // The first scan has nothing to show yet. Without this the empty `groups`
        // would fall through to NoMatches and claim nothing matches an empty search.
        if model.needsAccess && model.groups.isEmpty && !model.scanning {
            GrantAccess(followup: false) { model.requestAccess(preferHome: true) }
        } else if model.groups.isEmpty && model.scanning {
            Scanning(status: model.status)
        } else if model.groups.isEmpty && model.isSandboxed && !model.homeGranted {
            // Something was granted, but no caches were found because the home
            // folder — where the caches live — is not among the granted folders.
            GrantAccess(followup: true) { model.requestAccess(preferHome: true) }
        } else if model.groups.isEmpty {
            ContentUnavailableViewCompat()
        } else if visibleGroups.isEmpty {
            NoMatches(query: search, filter: filter)
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
                    if let filter, query.isEmpty {
                        TagExplainer(tag: filter)
                    }
                    ForEach(visibleGroups) { group in
                        Section {
                            if !isCollapsed(group) {
                                ForEach(group.items) { item in
                                    ItemRow(item: item, expanded: $expanded, maxBytes: maxBytes)
                                    Divider().padding(.leading, 20)
                                }
                            }
                        } header: {
                            GroupHeader(group: group, collapsed: isCollapsed(group)) {
                                if collapsed.contains(group.name) {
                                    collapsed.remove(group.name)
                                } else {
                                    collapsed.insert(group.name)
                                }
                            }
                        }
                    }
                }
                .padding(.bottom, 12)
            }
        }
    }

    private func pruneLabel(_ tool: PruneTool) -> String {
        guard let bytes = tool.reclaimable, bytes > 0 else { return tool.title + "…" }
        return "\(tool.title)… — \(Fmt.size(bytes))"
    }

    private var maxBytes: Int64 {
        max(1, model.groups.flatMap(\.items).map(\.totalBytes).max() ?? 1)
    }

    // MARK: - Footer

    private var footer: some View {
        HStack(spacing: 14) {
            Image(systemName: model.trashBytes > 0 ? "trash" : "arrow.uturn.backward.circle")
                .foregroundStyle(.secondary)

            if model.trashBytes > 0 {
                Text("The Trash holds \(Fmt.size(model.trashBytes)). Your disk does not get that space back until you empty it.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button("Open Trash") {
                    NSWorkspace.shared.open(
                        FileManager.default.homeDirectoryForCurrentUser
                            .appendingPathComponent(".Trash"))
                }
                .buttonStyle(.link)
                .font(.caption)
            } else {
                Text("Everything is moved to the Trash, never deleted outright. Nothing is gone until you empty it.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            if !model.selected.isEmpty {
                Button("Clear") { model.clearSelection() }
                    .buttonStyle(.link)
            }

            // One button carries the whole flow: first click selects everything
            // safe, second click moves it to the Trash. Someone who has never seen
            // the tag system just presses it twice.
            Button {
                if model.selected.isEmpty {
                    model.selectAllSafe()
                } else {
                    confirming = true
                }
            } label: {
                Text(mainButtonTitle)
                    .frame(minWidth: 240)
            }
            .keyboardShortcut(.defaultAction)
            .disabled(model.scanning || (model.selected.isEmpty && model.safeBytes == 0))
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .background(.bar)
    }

    private var mainButtonTitle: String {
        if !model.selected.isEmpty {
            let n = model.selectedItems.count
            return "Move \(n) item\(n == 1 ? "" : "s") to Trash — \(Fmt.size(model.selectedBytes))"
        }
        if model.safeBytes > 0 {
            return "Select everything safe — \(Fmt.size(model.safeBytes))"
        }
        return "Nothing to clean"
    }

    private func pickExclusion() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = SafetyGuard.home
        panel.prompt = "Exclude"
        panel.message = "DevSweep already scans your whole home folder for build output. Pick a folder you would rather it left alone."
        if panel.runModal() == .OK, let url = panel.url {
            model.exclude(url)
        }
    }

    /// A granted folder's path, shortened with ~ for display in menus.
    private func short(_ url: URL) -> String {
        let home = SandboxAccess.realHome.path
        let path = url.standardizedFileURL.path
        if path == home { return "Home folder (~)" }
        return path.replacingOccurrences(of: home + "/", with: "~/")
    }
}

// MARK: - Rows

/// The state of the boot volume. The green segment is what the current selection
/// would give back — *after* you empty the Trash, which is why the caption keeps
/// saying so. Moving a file to the Trash frees nothing on its own.
private struct DiskGauge: View {
    let disk: DiskSpace?
    let selected: Int64
    let trash: Int64

    private let width: CGFloat = 190

    var body: some View {
        if let disk, disk.total > 0 {
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 4) {
                    Text(Fmt.size(disk.free))
                        .font(.callout.weight(.semibold))
                        .monospacedDigit()
                        .contentTransition(.numericText())
                        .foregroundStyle(runningLow(disk) ? Color.orange : Color.primary)
                    Text("free of \(Fmt.size(disk.total))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                bar(disk)

                Text(caption)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .frame(width: width, alignment: .leading)
            .help("\(Fmt.size(disk.used)) used, \(Fmt.size(disk.free)) free.")
        }
    }

    private func runningLow(_ disk: DiskSpace) -> Bool {
        Double(disk.free) / Double(disk.total) < 0.10
    }

    /// used ▸ [what you have ticked] ▸ free
    private func bar(_ disk: DiskSpace) -> some View {
        let total = Double(disk.total)
        let ticked = min(Double(selected), Double(disk.used))
        let plainUsed = max(0, Double(disk.used) - ticked)

        return HStack(spacing: 0) {
            Rectangle()
                .fill(Color.secondary.opacity(0.55))
                .frame(width: width * plainUsed / total)
            Rectangle()
                .fill(Color.green)
                .frame(width: width * ticked / total)
            Rectangle()
                .fill(Color.secondary.opacity(0.15))
        }
        .frame(width: width, height: 6)
        .clipShape(Capsule())
    }

    private var caption: String {
        if selected > 0 {
            return "\(Fmt.size(selected)) selected — freed once emptied"
        }
        if trash > 0 {
            return "\(Fmt.size(trash)) already in the Trash"
        }
        return "\(Fmt.size(disk?.used ?? 0)) used"
    }
}

private struct SearchField: View {
    @Binding var text: String
    var focused: FocusState<Bool>.Binding

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: "magnifyingglass")
                .font(.caption)
                .foregroundStyle(.secondary)
            TextField("Search", text: $text)
                .textFieldStyle(.plain)
                .font(.callout)
                .focused(focused)
                .onExitCommand {          // Escape: clear, then step out
                    text = ""
                    focused.wrappedValue = false
                }
            if !text.isEmpty {
                Button {
                    text = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 4)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(Color.secondary.opacity(0.10))
        )
    }
}

private struct GroupHeader: View {
    let group: ScanGroup
    let collapsed: Bool
    let toggle: () -> Void

    var body: some View {
        Button(action: toggle) {
            HStack(spacing: 6) {
                Image(systemName: "chevron.right")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.tertiary)
                    .rotationEffect(.degrees(collapsed ? 0 : 90))
                    .frame(width: 10)
                Text(group.name.uppercased())
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .tracking(0.6)
                Text("\(group.items.count)")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.tertiary)
                Spacer()
                Text(Fmt.size(group.totalBytes))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 7)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(.regularMaterial)
    }
}

/// Empty state for the two ways of narrowing the list. With no search text the
/// culprit is the tag filter, and “Nothing matches ‘’” would just look broken.
private struct NoMatches: View {
    let query: String
    let filter: SafetyTag?

    private var searching: Bool {
        !query.trimmingCharacters(in: .whitespaces).isEmpty
    }

    var body: some View {
        VStack(spacing: 8) {
            Spacer()
            Image(systemName: searching ? "magnifyingglass" : "line.3.horizontal.decrease.circle")
                .font(.system(size: 30))
                .foregroundStyle(.tertiary)
            if searching {
                Text("Nothing matches “\(query)”.").font(.headline)
                Text("Try a tool name, a path, or clear the tag filter.")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                Text("Nothing here is tagged \(filter?.label ?? "that").").font(.headline)
                Text("Pick another tag, or All to see everything found.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }
}

private struct ItemRow: View {
    @EnvironmentObject var model: ScanModel
    let item: ScanItem
    @Binding var expanded: Set<String>
    let maxBytes: Int64

    @State private var hovered: String?

    private var isExpanded: Bool { expanded.contains(item.id) }

    var body: some View {
        VStack(spacing: 0) {
            row(for: item, indent: 0, isParent: item.isContainer)

            if item.isContainer && isExpanded {
                ForEach(item.children) { child in
                    row(for: child, indent: 30, isParent: false)
                }
            }
        }
    }

    @ViewBuilder
    private func row(for entry: ScanItem, indent: CGFloat, isParent: Bool) -> some View {
        let locked = entry.tag == .never || entry.deletableLeaves.isEmpty

        HStack(spacing: 10) {
            Color.clear.frame(width: indent, height: 1)

            if locked {
                Image(systemName: "lock.fill")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .frame(width: 16)
            } else {
                CheckBox(
                    on: model.isSelected(entry),
                    partial: model.isPartiallySelected(entry)
                ) { model.toggle(entry) }
            }

            if isParent {
                Button {
                    if isExpanded { expanded.remove(entry.id) } else { expanded.insert(entry.id) }
                } label: {
                    Image(systemName: "chevron.right")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(.secondary)
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                        .frame(width: 12)
                }
                .buttonStyle(.plain)
            } else if indent == 0 {
                Color.clear.frame(width: 12, height: 1)
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(entry.title)
                    .font(indent > 0 ? .caption : .body)
                    .foregroundStyle(locked ? .secondary : .primary)
                if !entry.note.isEmpty {
                    Text(entry.note)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if isParent && !isExpanded {
                    Text("\(entry.children.count) item\(entry.children.count == 1 ? "" : "s")")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            SizeBar(bytes: entry.totalBytes, maxBytes: maxBytes, tag: entry.tag)

            Text(Fmt.size(entry.totalBytes))
                .font(.callout.monospacedDigit())
                .foregroundStyle(locked ? .secondary : .primary)
                .frame(width: 84, alignment: .trailing)

            TagBadge(tag: entry.tag)
                .opacity(indent > 0 ? 0 : 1)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, indent > 0 ? 5 : 9)
        .background(hovered == entry.id ? Color.secondary.opacity(0.08) : .clear)
        .contentShape(Rectangle())
        .onHover { inside in hovered = inside ? entry.id : (hovered == entry.id ? nil : hovered) }
        // Clicking anywhere on the row toggles it. The checkbox and chevron are
        // buttons, so they consume their own clicks before this fires.
        .onTapGesture { if !locked { model.toggle(entry) } }
        .contextMenu {
            Button("Reveal in Finder") {
                NSWorkspace.shared.activateFileViewerSelecting([entry.url])
            }
            Button("Copy path") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(entry.url.path, forType: .string)
            }
        }
        .help(entry.url.path.replacingOccurrences(of: SafetyGuard.home.path, with: "~"))
    }
}

private struct CheckBox: View {
    let on: Bool
    let partial: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            ZStack {
                // An unchecked box is drawn with a transparent fill. A shape filled
                // with a clear colour rasterises to zero alpha and is not hit-tested,
                // which would leave only the 1pt border clickable — hence the
                // contentShape below, which gives the whole square a hit area.
                RoundedRectangle(cornerRadius: 4)
                    .fill(on || partial ? Color.accentColor : Color.clear)
                RoundedRectangle(cornerRadius: 4)
                    .strokeBorder(on || partial ? Color.accentColor : Color.secondary.opacity(0.55),
                                  lineWidth: 1)
                if on {
                    Image(systemName: "checkmark")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(.white)
                } else if partial {
                    RoundedRectangle(cornerRadius: 1)
                        .fill(.white)
                        .frame(width: 8, height: 2)
                }
            }
            .frame(width: 16, height: 16)
            .contentShape(Rectangle())
            .padding(4)             // a forgiving target without changing the drawn size
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(-4)
    }
}

private struct SizeBar: View {
    let bytes: Int64
    let maxBytes: Int64
    let tag: SafetyTag

    var body: some View {
        let ratio = min(1, max(0, Double(bytes) / Double(maxBytes)))
        ZStack(alignment: .leading) {
            Capsule().fill(Color.secondary.opacity(0.12))
            Capsule().fill(color).frame(width: max(2, 90 * ratio))
        }
        .frame(width: 90, height: 5)
    }

    private var color: Color {
        switch tag {
        case .safe: return .green
        case .review: return .orange
        case .never: return .secondary.opacity(0.5)
        }
    }
}

struct TagBadge: View {
    let tag: SafetyTag

    var body: some View {
        Text(tag.label.uppercased())
            .font(.system(size: 9, weight: .bold))
            .tracking(0.5)
            .foregroundStyle(fg)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(Capsule().fill(bg))
            .frame(width: 80)
    }

    private var fg: Color {
        switch tag {
        case .safe: return .green
        case .review: return .orange
        case .never: return .secondary
        }
    }

    private var bg: Color {
        switch tag {
        case .safe: return .green.opacity(0.14)
        case .review: return .orange.opacity(0.14)
        case .never: return .secondary.opacity(0.12)
        }
    }
}

private struct TagExplainer: View {
    let tag: SafetyTag

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            TagBadge(tag: tag)
            VStack(alignment: .leading, spacing: 2) {
                Text(tag.headline).font(.callout.weight(.medium))
                Text(tag.blurb).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
    }
}

private struct ReportBanner: View {
    let report: Scanner.DeleteReport
    let dismiss: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: report.failures.isEmpty ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                .foregroundStyle(report.failures.isEmpty ? .green : .orange)
            VStack(alignment: .leading, spacing: 1) {
                Text("Moved \(report.moved) item\(report.moved == 1 ? "" : "s") to the Trash — \(Fmt.size(report.freed)) recoverable until you empty it.")
                    .font(.callout)
                if !report.failures.isEmpty {
                    Text("\(report.failures.count) could not be moved: \(report.failures.prefix(2).map { $0.url.lastPathComponent }.joined(separator: ", "))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            Button("Open Trash") {
                NSWorkspace.shared.open(
                    FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".Trash"))
            }
            .buttonStyle(.link)
            Button(action: dismiss) {
                Image(systemName: "xmark")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("Dismiss")
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 10)
        .background(Color.green.opacity(0.07))
    }
}

/// Shown while the very first scan is running, when there is not yet a single row
/// to put on screen. Later scans keep the previous list visible and rely on the
/// small spinner in the header instead.
private struct Scanning: View {
    let status: String

    var body: some View {
        VStack(spacing: 10) {
            Spacer()
            ProgressView()
                .progressViewStyle(.circular)
                .controlSize(.large)
            Text(status)
                .font(.headline)
                .contentTransition(.opacity)
            Text("Measuring your caches and walking your projects. This usually takes a few seconds.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .animation(.default, value: status)
    }
}

/// Shown in the App Store (sandboxed) build before any folder has been granted.
/// A sandboxed app can only read what the user explicitly hands over, so the very
/// first thing DevSweep needs is permission to look at a folder.
private struct GrantAccess: View {
    /// false: the first-run screen, nothing granted yet.
    /// true: folders were granted but held no caches — nudge toward the home folder.
    let followup: Bool
    let grant: () -> Void

    var body: some View {
        VStack(spacing: 14) {
            Spacer()
            Image(systemName: followup ? "folder.badge.plus" : "folder.badge.questionmark")
                .font(.system(size: 44))
                .foregroundStyle(.tint)
            Text(followup ? "No caches in the folders you added" : "Grant a folder to scan")
                .font(.title3.weight(.semibold))
            Text(followup
                 ? "Developer caches live under your **Home folder** (Xcode, npm, Gradle, and the rest). Add it to let DevSweep find them — you can still remove it later."
                 : "DevSweep only looks where you let it. Choose your **Home folder** to cover every cache, or a single project or cache directory to keep it narrow. You can add or remove folders any time.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 440)
            Button(action: grant) {
                Label(followup ? "Add Home Folder…" : "Choose Folder…", systemImage: "folder")
                    .padding(.horizontal, 6)
            }
            .controlSize(.large)
            .buttonStyle(.borderedProminent)
            .padding(.top, 2)
            Text("Nothing is read or deleted until you pick a folder.")
                .font(.caption)
                .foregroundStyle(.tertiary)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct ContentUnavailableViewCompat: View {
    var body: some View {
        VStack(spacing: 8) {
            Spacer()
            Image(systemName: "internaldrive")
                .font(.system(size: 34))
                .foregroundStyle(.tertiary)
            Text("Nothing found to clean.").font(.headline)
            Text("Either your caches are already empty, or DevSweep could not read them.")
                .font(.caption).foregroundStyle(.secondary)
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }
}

// MARK: - Confirmation

private struct ConfirmSheet: View {
    @EnvironmentObject var model: ScanModel
    @Binding var isPresented: Bool

    var body: some View {
        let items = model.selectedItems
        let review = items.filter { $0.tag == .review }

        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Move \(items.count) item\(items.count == 1 ? "" : "s") to the Trash?")
                    .font(.title3.weight(.semibold))
                Text("\(Fmt.size(model.selectedBytes)) will be freed once you empty the Trash. Until then everything below is recoverable.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            .padding(20)

            if !review.isEmpty {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    Text("\(review.count) of these are tagged **Review** — they take real time or bandwidth to rebuild.")
                        .font(.callout)
                    Spacer()
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 12)
            }

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(items) { item in
                        HStack(spacing: 8) {
                            TagBadge(tag: item.tag)
                            Text(item.url.path.replacingOccurrences(of: SafetyGuard.home.path, with: "~"))
                                .font(.caption.monospaced())
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Spacer()
                            Text(Fmt.size(item.bytes))
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                        .padding(.horizontal, 20)
                        .padding(.vertical, 4)
                    }
                }
                .padding(.vertical, 8)
            }
            .frame(height: 240)

            Divider()

            HStack {
                Spacer()
                Button("Cancel") { isPresented = false }
                    .keyboardShortcut(.cancelAction)
                Button("Move to Trash") {
                    isPresented = false
                    model.trashSelected()
                }
                .keyboardShortcut(.defaultAction)
            }
            .padding(16)
        }
        .frame(width: 620)
    }
}
