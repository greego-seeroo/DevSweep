import Foundation
#if canImport(AppKit)
import AppKit
#endif

// MARK: - Sandbox folder access

/// The Mac App Store build runs inside the App Sandbox, which walls the app off
/// from everything outside its own container. To scan the real caches the user
/// has to hand over a folder through a system open panel; macOS then lets us
/// keep that access across launches via a *security-scoped bookmark*.
///
/// Everything here is a no-op in the Developer ID / test build (not sandboxed):
/// `isSandboxed` is false, `homeRoot` falls back to the real home directory, and
/// the scanner never asks for a grant. That keeps `main`'s behaviour and the test
/// suite unchanged — the sandbox path only lights up when actually sandboxed.
enum SandboxAccess {
    private static let defaultsKey = "grantedFolderBookmarks"

    /// True when running under the App Sandbox. macOS sets this environment
    /// variable for every sandboxed process; nothing else does.
    static let isSandboxed = ProcessInfo.processInfo.environment["APP_SANDBOX_CONTAINER_ID"] != nil

    /// The user's *real* home directory (`/Users/name`), even inside the sandbox.
    /// `NSHomeDirectory()` / `homeDirectoryForCurrentUser` return the container
    /// there — but the account's passwd entry still points at the real home, and
    /// reading it is allowed. Outside the sandbox the two agree.
    static let realHome: URL = {
        if let pw = getpwuid(getuid()), let dir = pw.pointee.pw_dir {
            let path = String(cString: dir)
            if !path.isEmpty { return URL(fileURLWithPath: path).standardizedFileURL }
        }
        return FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL
    }()

    /// Folders the user has granted, resolved from stored bookmarks. Each has had
    /// `startAccessingSecurityScopedResource()` called; we hold that for the whole
    /// process lifetime, so there is no matching stop.
    private(set) static var roots: [URL] = []

    /// The granted folder that is, or contains, the real home directory. The
    /// catalog scan is entirely home-relative, so this is what it runs against.
    /// nil until the user grants their home (or an ancestor of it).
    static var homeRoot: URL? {
        if !isSandboxed { return realHome }
        let home = realHome.path
        return roots.first { $0.standardizedFileURL.path == home }
            ?? roots.first { home.hasPrefix($0.standardizedFileURL.path + "/") }
    }

    /// Whether there is anything to scan at all. Any granted folder counts — the
    /// project walker runs over whatever roots exist. The cache catalog needs the
    /// home folder specifically (see `homeRoot`), but a subfolder grant still gives
    /// a useful project-artifact scan.
    static var hasAccess: Bool { !isSandboxed || !roots.isEmpty }

    // MARK: Persistence

    /// Re-opens every previously granted folder. Call once at launch, before the
    /// first scan.
    static func loadGrants() {
        guard isSandboxed else { return }
        let datas = UserDefaults.standard.array(forKey: defaultsKey) as? [Data] ?? []
        var resolved: [URL] = []
        var fresh: [Data] = []

        for data in datas {
            var stale = false
            guard let url = try? URL(resolvingBookmarkData: data,
                                     options: [.withSecurityScope],
                                     relativeTo: nil,
                                     bookmarkDataIsStale: &stale) else { continue }
            _ = url.startAccessingSecurityScopedResource()
            resolved.append(url)
            // A stale bookmark still resolves but should be rewritten so it keeps
            // working; if we can't, keep the old data rather than dropping access.
            if stale, let renewed = try? url.bookmarkData(options: [.withSecurityScope],
                                                          includingResourceValuesForKeys: nil,
                                                          relativeTo: nil) {
                fresh.append(renewed)
            } else {
                fresh.append(data)
            }
        }

        roots = dedupe(resolved)
        UserDefaults.standard.set(fresh, forKey: defaultsKey)
    }

    /// Stores a freshly granted folder and adds it to `roots`.
    static func store(_ url: URL) {
        guard let data = try? url.bookmarkData(options: [.withSecurityScope],
                                               includingResourceValuesForKeys: nil,
                                               relativeTo: nil) else { return }
        _ = url.startAccessingSecurityScopedResource()

        var datas = UserDefaults.standard.array(forKey: defaultsKey) as? [Data] ?? []
        datas.removeAll { bookmarkPath($0) == url.standardizedFileURL.path }
        datas.append(data)
        UserDefaults.standard.set(datas, forKey: defaultsKey)

        roots = dedupe(roots + [url])
    }

    /// Drops a grant. The bookmark is forgotten; access ends at the next launch.
    static func removeGrant(_ url: URL) {
        var datas = UserDefaults.standard.array(forKey: defaultsKey) as? [Data] ?? []
        datas.removeAll { bookmarkPath($0) == url.standardizedFileURL.path }
        UserDefaults.standard.set(datas, forKey: defaultsKey)
        url.stopAccessingSecurityScopedResource()
        roots.removeAll { $0.standardizedFileURL.path == url.standardizedFileURL.path }
    }

    // MARK: Requesting access

    #if canImport(AppKit)
    /// Shows a folder-open panel and stores whatever the user grants. Returns the
    /// granted URL, or nil if they cancelled.
    @MainActor
    static func requestAccess(preferHome: Bool = false) -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = false
        panel.prompt = "Grant Access"

        if preferHome {
            // Open in /Users so the home folder itself is a single click away —
            // selecting the *current* folder is easy to miss otherwise.
            panel.title = "Add Your Home Folder"
            panel.message = "Select the folder named “\(realHome.lastPathComponent)”, then click Grant Access. This lets DevSweep find every developer cache in one step."
            panel.directoryURL = realHome.deletingLastPathComponent()
        } else {
            panel.title = "Choose a Folder to Scan"
            panel.message = "Pick a folder for DevSweep to scan. Your Home folder covers every cache; you can also pick a single project or cache directory."
            panel.directoryURL = realHome
        }

        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        store(url)
        return url
    }
    #endif

    // MARK: Helpers

    private static func dedupe(_ urls: [URL]) -> [URL] {
        var seen = Set<String>()
        return urls.filter { seen.insert($0.standardizedFileURL.path).inserted }
    }

    private static func bookmarkPath(_ data: Data) -> String? {
        var stale = false
        return try? URL(resolvingBookmarkData: data,
                        options: [.withSecurityScope],
                        relativeTo: nil,
                        bookmarkDataIsStale: &stale).standardizedFileURL.path
    }
}
