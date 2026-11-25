import SwiftUI
import AppKit
import Combine

// MARK: - App Delegate

/// Quits the app when the last window closes. DevSweep is a single-window
/// utility, so there is nothing useful to do in the background and no menu
/// item to bring the window back.
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    /// Finishes a move before quitting. A "Move to Trash" or a Put Back is a
    /// loop of filesystem moves on a background task; killing the process in
    /// the middle leaves half the items moved and loses the record that Put
    /// Back needs. So a quit asked for mid-move (Cmd-Q, or closing the window,
    /// which quits) waits for the move to end, then goes ahead by itself.
    private var quitWhenIdle: AnyCancellable?

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let model = ScanModel.current, model.cleaning else { return .terminateNow }
        quitWhenIdle = model.$cleaning
            .filter { !$0 }
            .first()
            .sink { _ in NSApp.reply(toApplicationShouldTerminate: true) }
        return .terminateLater
    }

    /// Sizes the window on the very first launch, and only then.
    ///
    /// SwiftUI ignores both `defaultSize` and the content's `idealWidth` once the
    /// content declares a minimum, so the window opened at that 900pt minimum —
    /// usable, but a cramped first impression for a list-driven app. Every launch
    /// after this one restores whatever frame the user left behind.
    private let sizedKey = "devsweep.didSizeFirstWindow.v1"

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard !UserDefaults.standard.bool(forKey: sizedKey) else { return }
        // The window does not exist yet when this fires.
        DispatchQueue.main.async { [self] in
            // Must not match the first-run welcome sheet, which is on screen by
            // now and is also titled — resizing that instead would be worse than
            // doing nothing.
            guard let window = NSApp.windows.first(where: {
                $0.isVisible && !$0.isSheet
                    && $0.styleMask.contains(.titled)
                    && $0.styleMask.contains(.resizable)
                    && $0.styleMask.contains(.closable)
            }) else { return }

            // Never larger than the display it opens on — an oversized window is
            // itself a way to push content off screen.
            let visible = (window.screen ?? NSScreen.main)?.visibleFrame.size
                ?? NSSize(width: 1180, height: 800)
            var frame = window.frame
            let size = NSSize(width: min(1180, visible.width),
                              height: min(800, visible.height))
            frame.size = size
            window.setFrame(frame, display: true)
            window.center()

            UserDefaults.standard.set(true, forKey: sizedKey)
        }
    }
}

// MARK: - App

@main
struct DevSweepApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var model = ScanModel()

    var body: some Scene {
        // The app name is not translated — verbatim keeps it out of the catalog.
        WindowGroup(Text(verbatim: "DevSweep")) {
            ContentView()
                .environmentObject(model)
        }
        .defaultSize(width: 1180, height: 800)
        .windowResizability(.contentMinSize)
        .commands {
            CommandGroup(replacing: .newItem) {}
            CommandGroup(after: .toolbar) {
                Button(action: model.rescan) { Text("Rescan", comment: "Menu item and header button: run the scan again.") }
                    .keyboardShortcut("r", modifiers: .command)
                Divider()
                LanguageMenu()
            }
        }
    }
}

