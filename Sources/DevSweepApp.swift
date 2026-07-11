import SwiftUI

@main
struct DevSweepApp: App {
    @StateObject private var model = ScanModel()

    var body: some Scene {
        WindowGroup("DevSweep") {
            ContentView()
                .environmentObject(model)
        }
        .windowResizability(.contentMinSize)
        .commands {
            CommandGroup(replacing: .newItem) {}
            CommandGroup(after: .toolbar) {
                Button("Rescan") { model.rescan() }
                    .keyboardShortcut("r", modifiers: .command)
            }
        }
    }
}
