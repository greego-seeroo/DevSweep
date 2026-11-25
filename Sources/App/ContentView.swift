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

    /// Shown once, ever. Bumping the suffix re-shows it after a redesign —
    /// v2: the intro gained the Developer / System Data modes page.
    @AppStorage("devsweep.welcomeSeen.v2") private var welcomeSeen = false
    @State private var launched = false
    @State private var showWelcome = false

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
            Divider()
            footer
        }
        // The minimum is the width the header genuinely needs at its narrowest
        // (see `header`), not an aspiration — below it, controls would be clipped
        // rather than merely cramped. The size it *opens* at is `defaultSize` on
        // the WindowGroup.
        .frame(minWidth: 900, minHeight: 620)
        .onAppear {
            if !welcomeSeen { showWelcome = true }
            // Always scan on opening, even when last time's rows are already on
            // screen: they are shown so the wait is not blank, not as truth.
            if !launched { launched = true; model.rescan() }
        }
        .sheet(isPresented: $showWelcome) {
            WelcomeView(sandboxed: model.isSandboxed) {
                welcomeSeen = true
                showWelcome = false
                // Hand off straight into granting a folder on the sandbox build,
                // so the story flows into the first useful action.
                if model.isSandboxed && model.needsAccess {
                    model.requestAccess(preferHome: true)
                }
            }
            .interactiveDismissDisabled()
        }
        // Coming back from Finder or a terminal is the moment external deletions
        // become visible — catch up without making the user rescan.
        .onReceive(NotificationCenter.default.publisher(
            for: NSApplication.didBecomeActiveNotification)) { _ in
            model.refreshExternalChanges()
        }
        .onChange(of: model.groups.map(\.name)) { _, names in autoCollapse(names) }
        .sheet(isPresented: $confirming) { ConfirmSheet(isPresented: $confirming) }
        .alert(Text("Cleanup finished", comment: "Alert title after a prune tool (Docker, Homebrew…) has run."),
               isPresented: Binding(
                   get: { model.toolsMessage != nil },
                   set: { if !$0 { model.toolsMessage = nil } })) {
            Button("OK") { model.toolsMessage = nil }
        } message: {
            // The tool's own output, or an already localized summary.
            Text(verbatim: model.toolsMessage ?? "")
        }
        .alert(
            Text(verbatim: pendingPrune?.title ?? ""),
            isPresented: Binding(
                get: { pendingPrune != nil },
                set: { if !$0 { pendingPrune = nil } }),
            presenting: pendingPrune
        ) { tool in
            Button("Cancel", role: .cancel) { pendingPrune = nil }
            if tool.harmless {
                Button(action: { model.runPrune(tool); pendingPrune = nil }) {
                    Text("Run", comment: "Confirms a prune tool that cannot lose anything (unavailable simulators).")
                }
            } else {
                Button(role: .destructive, action: { model.runPrune(tool); pendingPrune = nil }) {
                    Text("Free space now", comment: "Confirms a prune tool that deletes outright, bypassing the Trash.")
                }
            }
        } message: { tool in
            Text(verbatim: pruneWarning(for: tool))
        }
        .alert(
            languageAlertTitle,
            isPresented: Binding(
                get: { languageSwitch.pending != nil },
                set: { if !$0 { languageSwitch.pending = nil } }),
            presenting: languageSwitch.pending
        ) { language in
            Button("Cancel", role: .cancel) { languageSwitch.pending = nil }
            Button(action: {
                AppLanguage.apply(language)
                AppLanguage.relaunch()
            }) {
                Text("Relaunch", comment: "Confirms a language change; the app quits and reopens.")
            }
        } message: { _ in
            Text("DevSweep quits and reopens in the new language. Nothing is moved or deleted, and your last scan is kept.",
                 comment: "Explains what happens when the language is changed.")
        }
    }

    @ObservedObject private var languageSwitch = LanguageSwitch.shared

    private var languageAlertTitle: Text {
        switch languageSwitch.pending {
        case .system?, nil:
            return Text("Follow the system language?", comment: "Alert title when the user picks 'System Language'.")
        case let language?:
            return Text("Switch language to \(language.menuTitle)?",
                        comment: "Alert title when the user picks a language. %@ is the language's own name (Deutsch, 日本語…).")
        }
    }

    /// Separate localized paragraphs, joined — never one sentence built from parts.
    private func pruneWarning(for tool: PruneTool) -> String {
        var paragraphs = [tool.detail]
        if let bytes = tool.reclaimable, bytes > 0 {
            paragraphs.append(String(localized: "It reports about \(Fmt.size(bytes)) to reclaim.",
                                     comment: "Prune confirmation, extra paragraph. %@ is a size the tool itself estimated."))
        }
        if !tool.harmless {
            paragraphs.append(String(localized: "This one does not go through the Trash. The space comes back immediately and there is nothing to restore afterwards.",
                                     comment: "Prune confirmation, warning paragraph for tools that delete outright."))
        }
        return paragraphs.joined(separator: "\n\n")
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

    /// Two rows, deliberately — and each row folds into two of its own when
    /// its language or text size needs more than the window gives it.
    ///
    /// Every control is `fixedSize` — a truncated control label reads as a bug,
    /// so nothing is allowed to compress. That makes a row's width a hard
    /// requirement, and one row carrying the summary, the gauge, four menus, the
    /// search field *and* a four-segment picker needs ~1450pt before anything is
    /// clipped. Splitting it in two, and letting each half wrap (`ViewThatFits`),
    /// keeps the 900pt minimum honest in every shipped language.
    private var header: some View {
        VStack(spacing: 10) {
            summaryRow
            findRow
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
    }

    /// What is on the disk, and the actions that change it.
    ///
    /// Same rule as `findRow`: one row when it fits, two when it does not —
    /// the numbers on the first line, the buttons on the second. German,
    /// French and Spanish labels are long enough that the sandbox build's
    /// four buttons no longer share a row with the gauge at 900pt.
    private var summaryRow: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .center, spacing: 18) {
                summaryBlock
                Divider().frame(height: 36)
                gauge
                Spacer(minLength: 12)
                actionButtons
            }
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .center, spacing: 18) {
                    summaryBlock
                    Divider().frame(height: 36)
                    gauge
                    Spacer(minLength: 0)
                }
                HStack(alignment: .center, spacing: 18) {
                    Spacer(minLength: 0)
                    actionButtons
                }
            }
        }
    }

    private var summaryBlock: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(Fmt.size(model.reclaimableBytes))
                .font(.system(size: 30, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .contentTransition(.numericText())
                .fixedSize()
            // May wrap to a second line in longer languages; the number
            // above never compresses.
            Text("could be freed · \(Fmt.size(model.safeBytes)) of it is safe",
                 comment: "Caption under the large reclaimable size, read together with it: '<size> could be freed · <size> of it is safe'. %@ is the size of the Safe items.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 230, alignment: .leading)
        }
    }

    private var gauge: some View {
        DiskGauge(disk: model.disk,
                  selected: model.selectedBytes,
                  trash: model.trashBytes)
    }

    /// Folders (sandbox only), Tools, Language, Rescan. Every one is
    /// `fixedSize` — a truncated control label reads as a bug.
    @ViewBuilder
    private var actionButtons: some View {
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
            // Granting or revoking a folder mid-scan would invalidate the
            // scan in flight; wait it out.
            .disabled(model.scanning)
        }

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
                Text("Looking for Docker, Homebrew…", comment: "Tools menu placeholder while installed tools are probed. Product names.")
            } else {
                Section("Run a tool's own cleanup") {
                    ForEach(model.pruneTools) { tool in
                        Button(action: { pendingPrune = tool }) { Text(verbatim: pruneLabel(tool)) }
                    }
                }
                // A prune tool deletes outright; not while anything else moves.
                .disabled(model.scanning || model.cleaning)
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
                NSWorkspace.shared.open(SafetyGuard.trash)
            }
        } label: {
            Label("Tools", systemImage: "ellipsis.circle")
        }
        .menuStyle(.borderlessButton)
        .fixedSize()

        // The language switch, as its own button so nobody has to know it is
        // inside Tools. The same list sits in the View menu.
        Menu {
            LanguageMenu(inline: true)
        } label: {
            Label("Language", systemImage: "globe")
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help(Text("Switch the language DevSweep runs in. The app relaunches; nothing is moved or deleted.",
                   comment: "Tooltip on the Language button in the header."))

        Button {
            model.rescan()
        } label: {
            Label("Rescan", systemImage: "arrow.clockwise")
        }
        .fixedSize()
        .disabled(model.scanning)
    }

    /// Narrowing the list: audience mode, search, live scan status, and the
    /// safety-tag filter.
    ///
    /// One row when it fits, two when it does not. The controls never compress
    /// (a truncated label reads as a bug), so in a longer language — or at a
    /// larger text size — the filter drops to a second line instead of pushing
    /// the tabs off the left edge. The live status is the one flexible piece:
    /// it takes whatever is left and truncates, and counts for nothing when
    /// the row's width is measured (`idealWidth: 0`), so a long status never
    /// flips the layout mid-scan.
    private var findRow: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .center, spacing: 12) {
                modeAndSearch
                Spacer(minLength: 12)
                tagFilter
            }
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .center, spacing: 12) {
                    modeAndSearch
                    Spacer(minLength: 0)
                }
                tagFilter
            }
        }
    }

    @ViewBuilder
    private var modeAndSearch: some View {
        // Who the scan is for. Always clickable: switching mid-scan cancels
        // the scan in flight and starts the new mode's straight after.
        AudienceTabs(selection: model.audience) {
            model.setAudience($0)
        }
        .help(Text("Developer: toolchains, caches and build output. System Data: app caches, logs and device backups.",
                   comment: "Tooltip on the mode tabs. 'Developer' and 'System Data' must match the tab names."))

        SearchField(text: $search, focused: $searchFocused)
            .frame(minWidth: 150, idealWidth: 220, maxWidth: 260)
            // An invisible button is the standard way to route a shortcut to
            // a focus change; TextField cannot carry one itself.
            .background(
                Button(action: { searchFocused = true }) { EmptyView() }
                    .keyboardShortcut("f", modifiers: .command)
                    .opacity(0)
            )

        if model.scanning || model.cleaning {
            ProgressView().controlSize(.small)
            // A move in progress is the more urgent thing to show; the scan
            // status comes back the moment it finishes.
            Text(verbatim: model.cleaningStatus ?? model.status)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(idealWidth: 0, maxWidth: 420, alignment: .leading)
        }
    }

    private var tagFilter: some View {
        Picker(selection: $filter) {
            Text("All", comment: "Safety filter segment: show every row.").tag(SafetyTag?.none)
            ForEach(SafetyTag.allCases, id: \.self) { tag in
                Text(tag.label).tag(SafetyTag?.some(tag))
            }
        } label: {
            EmptyView()
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        // Sized by its longest label ("Protected"), never cropped to a
        // guessed width.
        .fixedSize()
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
            ReportBanner(report: report,
                         busy: model.scanning || model.cleaning,
                         putBack: { model.undoLastClean() },
                         dismiss: { model.lastReport = nil })
        }

        // Only subfolders granted: results are partial. Nudge toward the home
        // folder, which is the one grant that surfaces every developer cache.
        if model.isSandboxed && !model.homeGranted && !model.groups.isEmpty {
            HomeGrantBanner { model.requestAccess(preferHome: true) }
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
        guard let bytes = tool.reclaimable, bytes > 0 else {
            return String(localized: "\(tool.title)…", comment: "Tools menu item. %@ is a prune tool name; the ellipsis means a confirmation follows.")
        }
        return String(localized: "\(tool.title)… — \(Fmt.size(bytes))",
                      comment: "Tools menu item. %1$@ is a prune tool name, %2$@ the size it says it can free.")
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
                    .fixedSize(horizontal: false, vertical: true)
                Button("Open Trash") {
                    NSWorkspace.shared.open(SafetyGuard.trash)
                }
                .buttonStyle(.link)
                .font(.caption)
            } else {
                Text("Everything is moved to the Trash, never deleted outright. Nothing is gone until you empty it.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer()

            if !model.selected.isEmpty {
                Button(action: model.clearSelection) { Text("Clear", comment: "Footer link: clears the selection.") }
                    .buttonStyle(.link)
            }

            // One button carries the whole flow: first click selects everything
            // safe, second click confirms and moves it to the Trash. Someone who
            // has never seen the tag system just presses it twice.
            Button {
                if model.selected.isEmpty {
                    model.selectAllSafe()
                } else {
                    confirming = true
                }
            } label: {
                Text(verbatim: mainButtonTitle)
                    .frame(minWidth: 240)
            }
            .fixedSize()
            .keyboardShortcut(.defaultAction)
            // Cleaning while a scan runs is fine — rows are real the moment they
            // appear. Only one move at a time, though.
            .disabled(model.cleaning || (model.selected.isEmpty && model.safeBytes == 0))
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .background(.bar)
    }

    private var mainButtonTitle: String {
        if !model.selected.isEmpty {
            let n = model.selectedItems.count
            return String(localized: "Move \(n) items to Trash — \(Fmt.size(model.selectedBytes))",
                          comment: "Main button. %1$lld is the number of selected items, %2$@ their total size.")
        }
        if model.safeBytes > 0 {
            return String(localized: "Select everything safe — \(Fmt.size(model.safeBytes))",
                          comment: "Main button when nothing is selected yet. %@ is the total size of the Safe items.")
        }
        return String(localized: "Nothing to clean", comment: "Main button when the scan found nothing removable; disabled.")
    }

    private func pickExclusion() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = SafetyGuard.home
        panel.prompt = String(localized: "Exclude", comment: "Folder picker button: exclude the chosen folder from project scanning.")
        panel.message = String(localized: "DevSweep already scans your whole home folder for build output. Pick a folder you would rather it left alone.",
                               comment: "Folder picker message for excluding a folder.")
        if panel.runModal() == .OK, let url = panel.url {
            model.exclude(url)
        }
    }

    /// A granted folder's path, shortened with ~ for display in menus.
    private func short(_ url: URL) -> String {
        let home = SandboxAccess.realHome.path
        let path = url.standardizedFileURL.path
        if path == home { return String(localized: "Home folder (~)", comment: "Name of the home folder in the Folders menu. Keep the (~).") }
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

    /// The width of the bar itself. The block around it is free to be wider when
    /// the caption needs it — "123.4 GB selected — freed once emptied" is 203pt,
    /// so pinning the block to the bar's width used to clip it.
    private let width: CGFloat = 200

    var body: some View {
        if let disk, disk.total > 0 {
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 4) {
                    Text(Fmt.size(disk.free))
                        .font(.callout.weight(.semibold))
                        .monospacedDigit()
                        .contentTransition(.numericText())
                        .foregroundStyle(runningLow(disk) ? Color.orange : Color.primary)
                    Text("free of \(Fmt.size(disk.total))",
                         comment: "Follows the free-space figure in the disk gauge, read as '<free size> free of <total size>'. %@ is the disk's total size.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .fixedSize()

                bar(disk)

                Text(verbatim: caption)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(minWidth: width, alignment: .leading)
            .help(Text("\(Fmt.size(disk.used)) used, \(Fmt.size(disk.free)) free.",
                       comment: "Tooltip on the disk gauge. %1$@ used size, %2$@ free size."))
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text("Disk space", comment: "Accessibility label of the disk gauge."))
            .accessibilityValue(Text("\(Fmt.size(disk.free)) free of \(Fmt.size(disk.total)). \(caption)",
                                     comment: "Accessibility value of the disk gauge. %1$@ free size, %2$@ total size, %3$@ the gauge caption."))
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
            return String(localized: "\(Fmt.size(selected)) selected — freed once emptied",
                          comment: "Disk gauge caption. %@ is the size of the selection; it is freed only when the Trash is emptied.")
        }
        if trash > 0 {
            return String(localized: "\(Fmt.size(trash)) already in the Trash", comment: "Disk gauge caption. %@ is the size of the Trash's contents.")
        }
        return String(localized: "\(Fmt.size(disk?.used ?? 0)) used", comment: "Disk gauge caption. %@ is the used size of the disk.")
    }
}

/// The Developer / System Data switch: a capsule with a sliding accent pill,
/// icon + label per side. Styled as the header's one bold control — this is the
/// choice that decides what the whole window shows.
private struct AudienceTabs: View {
    let selection: Audience
    let choose: (Audience) -> Void

    @Namespace private var pill

    var body: some View {
        HStack(spacing: 2) {
            ForEach(Audience.allCases, id: \.self) { audience in
                let on = selection == audience
                Button { choose(audience) } label: {
                    HStack(spacing: 5) {
                        Image(systemName: audience.icon)
                            .font(.caption)
                        Text(audience.label)
                            .font(.callout.weight(on ? .semibold : .regular))
                    }
                    .foregroundStyle(on ? Color.white : Color.primary)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 5)
                    .background {
                        if on {
                            Capsule()
                                .fill(Color.accentColor)
                                .matchedGeometryEffect(id: "selected", in: pill)
                        }
                    }
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text(audience.label))
                .accessibilityAddTraits(on ? [.isSelected] : [])
            }
        }
        .padding(3)
        .background(Capsule().fill(Color.secondary.opacity(0.12)))
        .animation(.spring(response: 0.25, dampingFraction: 0.85), value: selection)
        .fixedSize()
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
                Text(verbatim: Catalog.groupDisplayName(group.name))
                    .textCase(.uppercase)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .tracking(0.6)
                Text(group.items.count, format: .number)
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
                    .fixedSize(horizontal: false, vertical: true)
                Text("Try a tool name, a path, or clear the tag filter.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Group {
                    switch filter {
                    case .safe?:
                        Text("Nothing here is tagged Safe.", comment: "Empty state for the Safe filter. 'Safe' must match the badge.")
                    case .review?:
                        Text("Nothing here is tagged Review.", comment: "Empty state for the Review filter. 'Review' must match the badge.")
                    case .never?:
                        Text("Nothing here is tagged Protected.", comment: "Empty state for the Protected filter. 'Protected' must match the badge.")
                    case nil:
                        Text("Nothing matches the current filter.", comment: "Empty state fallback.")
                    }
                }
                .font(.headline)
                .fixedSize(horizontal: false, vertical: true)
                Text("Pick another tag, or All to see everything found.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
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
                    .accessibilityLabel(Text("Select \(entry.title)", comment: "Accessibility label of a row's checkbox. %@ is the row title."))
                    .accessibilityValue(checkboxState(for: entry))
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
                        // A 12pt chevron is a fiddly target. Pad the hit area out
                        // to ~28pt and pull the layout back in, same trick as the
                        // checkbox — the row looks identical, the click doesn't miss.
                        .padding(8)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .padding(-8)
                .accessibilityLabel(isExpanded
                    ? Text("Collapse \(entry.title)", comment: "Accessibility label of a row's disclosure chevron. %@ is the row title.")
                    : Text("Expand \(entry.title)", comment: "Accessibility label of a row's disclosure chevron. %@ is the row title."))
            } else if indent == 0 {
                Color.clear.frame(width: 12, height: 1)
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(entry.title)
                    .font(indent > 0 ? .caption : .body)
                    .foregroundStyle(locked ? .secondary : .primary)
                    .fixedSize(horizontal: false, vertical: true)
                if !entry.note.isEmpty {
                    Text(entry.note)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if isParent && !isExpanded {
                    Text("\(entry.children.count) items", comment: "Under a collapsed container row: how many child rows it holds.")
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

    private func checkboxState(for entry: ScanItem) -> Text {
        if model.isSelected(entry) {
            return Text("selected", comment: "Accessibility value of a ticked checkbox.")
        }
        if model.isPartiallySelected(entry) {
            return Text("partially selected", comment: "Accessibility value of a container whose children are partly ticked.")
        }
        return Text("not selected", comment: "Accessibility value of an unticked checkbox.")
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
        // Decorative: the size it visualises sits right beside it as text.
        .accessibilityHidden(true)
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
        Text(verbatim: tag.label)
            .textCase(.uppercase)
            .font(.system(size: 9, weight: .bold))
            .tracking(0.5)
            .foregroundStyle(fg)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(Capsule().fill(bg))
            // A floor, not a cap: "PROTECTED" is 76pt today, and a hard 80pt
            // frame would let it spill over its neighbour at larger text sizes.
            .fixedSize()
            .frame(minWidth: 80)
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
                    .fixedSize(horizontal: false, vertical: true)
                Text(tag.blurb).font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
    }
}

private struct ReportBanner: View {
    let report: Scanner.DeleteReport
    /// True while a scan or another move is running; Put Back waits for it.
    let busy: Bool
    let putBack: () -> Void
    let dismiss: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: report.failures.isEmpty ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                .foregroundStyle(report.failures.isEmpty ? .green : .orange)
            VStack(alignment: .leading, spacing: 1) {
                Text("Moved \(report.moved) items to the Trash — \(Fmt.size(report.freed)) recoverable until you empty it.",
                     comment: "Banner after a move. %1$lld is the number of items, %2$@ their size.")
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
                if !report.failures.isEmpty {
                    Text("\(report.failures.count) could not be moved: \(report.failures.prefix(2).map { $0.url.lastPathComponent }.formatted(.list(type: .and, width: .narrow)))",
                         comment: "Banner line for failed moves. %1$lld is the number of failures, %2$@ up to two folder names.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer()
            // The one undo: everything the report moved goes back where it was.
            if report.moved > 0 {
                Button(action: putBack) { Text("Put Back", comment: "Banner link: the one undo — restores everything the last cleanup moved.") }
                    .buttonStyle(.link)
                    .disabled(busy)
                    .help(Text("Restores every item from this cleanup to where it came from.", comment: "Tooltip on Put Back."))
            }
            Button("Open Trash") {
                NSWorkspace.shared.open(SafetyGuard.trash)
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

/// A standing recommendation shown when only specific folders were granted. The
/// results on screen are real but partial — most developer caches live under the
/// home folder, so adding it is the single step that surfaces everything.
private struct HomeGrantBanner: View {
    let addHome: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "lightbulb.fill")
                .foregroundStyle(.yellow)
            VStack(alignment: .leading, spacing: 1) {
                Text("Add your Home folder for a complete scan")
                    .font(.callout.weight(.semibold))
                    .fixedSize(horizontal: false, vertical: true)
                Text("You've granted specific folders, so this list is partial. Most caches — Xcode, npm, Gradle, and the rest — live under your Home folder.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            Button(action: addHome) {
                Label("Add Home Folder", systemImage: "folder.badge.plus")
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
            .fixedSize()
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 10)
        .background(Color.accentColor.opacity(0.08))
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
                .fixedSize(horizontal: false, vertical: true)
            Text("Measuring your caches and walking your projects. This usually takes a few seconds.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
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
            Group {
                if followup {
                    Text("No caches in the folders you added", comment: "Empty state title when granted folders held no caches.")
                } else {
                    Text("Grant a folder to scan", comment: "First-run title in the App Store build: no folder granted yet.")
                }
            }
                .font(.title3.weight(.semibold))
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            Group {
                if followup {
                    Text("Developer caches live under your **Home folder** (Xcode, npm, Gradle, and the rest). Add it to let DevSweep find them — you can still remove it later.",
                         comment: "Empty state text when granted folders held no caches. Markdown bold; tool names stay.")
                } else {
                    Text("DevSweep only looks where you let it. Choose your **Home folder** to cover every cache, or a single project or cache directory to keep it narrow. You can add or remove folders any time.",
                         comment: "First-run text in the App Store build. Markdown bold.")
                }
            }
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 440)
            Button(action: grant) {
                Label {
                    if followup {
                        Text("Add Home Folder…", comment: "Button that opens the folder picker on the home folder.")
                    } else {
                        Text("Choose Folder…", comment: "Button that opens the folder picker.")
                    }
                } icon: {
                    Image(systemName: "folder")
                }
                .padding(.horizontal, 6)
            }
            .controlSize(.large)
            .buttonStyle(.borderedProminent)
            .padding(.top, 2)
            Text("Nothing is read or deleted until you pick a folder.")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
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
                .fixedSize(horizontal: false, vertical: true)
            Text("Either your caches are already empty, or DevSweep could not read them.")
                .font(.caption).foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
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
                Text("Move \(items.count) items to the Trash?", comment: "Confirmation sheet title. %lld is the number of selected items.")
                    .font(.title3.weight(.semibold))
                    .fixedSize(horizontal: false, vertical: true)
                Text("\(Fmt.size(model.selectedBytes)) will be freed once you empty the Trash. Until then everything below is recoverable.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(20)

            if !review.isEmpty {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    Text("\(review.count) of these are tagged **Review** — they take real time or bandwidth to rebuild.",
                         comment: "Confirmation sheet warning. %lld is the number of Review items; the bold word must match the Review badge.")
                        .font(.callout)
                        .fixedSize(horizontal: false, vertical: true)
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
                            // Lead with the name the list showed ("Spotify",
                            // "web-app › node_modules") — the raw path is the
                            // small print, not the headline, at the one moment
                            // the user is deciding whether to trust the app.
                            VStack(alignment: .leading, spacing: 1) {
                                Text(item.title)
                                    .font(.callout)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                Text(item.url.path.replacingOccurrences(of: SafetyGuard.home.path, with: "~"))
                                    .font(.caption.monospaced())
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                            }
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
                Button(action: {
                    isPresented = false
                    model.trashSelected()
                }) {
                    Text("Move to Trash", comment: "Confirmation sheet's confirm button. Same wording as the welcome sheet's step 3.")
                }
                .keyboardShortcut(.defaultAction)
            }
            .padding(16)
        }
        .frame(width: 680)
    }
}
