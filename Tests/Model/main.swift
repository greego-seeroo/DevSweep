import Foundation
// DevSweep's view-model test. Run by Scripts/test.sh --live after the core
// suite. It compiles ScanModel with the core and drives it the way the window
// does, against this machine's real caches: a fixture row is moved to the Trash
// while the scan is still measuring, must stay gone when the scan finishes, must
// survive a rescan as a Put Back, and must come back when put back. No row other
// than the fixture is ever moved.

var failures = 0
func check(_ ok: Bool, _ msg: String) { print((ok ? "  ok   " : "  FAIL ") + msg); if !ok { failures += 1 } }
let fm = FileManager.default
// ~/.cache is an expanded catalog rule, so a directory inside it becomes a
// child row of "Generic tool cache (~/.cache)" on the next scan.
let fixture = SafetyGuard.home.appendingPathComponent(".cache/devsweep-harness-\(ProcessInfo.processInfo.processIdentifier)")
for i in 0..<40 {
    let f = fixture.appendingPathComponent("d\(i % 4)/f\(i).bin")
    try? fm.createDirectory(at: f.deletingLastPathComponent(), withIntermediateDirectories: true)
    fm.createFile(atPath: f.path, contents: Data(repeating: 0x42, count: 8192))
}
@MainActor func rowPresent(_ m: ScanModel) -> ScanItem? {
    m.groups.flatMap(\.items).flatMap { [$0] + $0.children }.first { $0.url.path == fixture.path }
}
func waitUntil(_ what: String, timeout: Double, _ cond: @escaping @MainActor () -> Bool) async -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if await MainActor.run(body: cond) { return true }
        try? await Task.sleep(nanoseconds: 50_000_000)
    }
    print("  (timed out waiting for \(what))"); return false
}

Task { @MainActor in
    let t0 = Date()
    let model = ScanModel()
    model.rescan()
    check(model.scanning, "scan starts")

    _ = await waitUntil("fixture row to stream in", timeout: 60) { rowPresent(model) != nil }
    let row = rowPresent(model)
    print(String(format: "  info row streamed in at %.1fs, scanning=%@", Date().timeIntervalSince(t0), model.scanning ? "true" : "false"))
    check(row != nil, "fixture row appears while the scan is still running")
    check(model.scanning, "the scan is still running when the row appears")
    guard let row else { exit(1) }

    model.toggle(row)
    check(model.selected.contains(fixture.path), "the row can be ticked mid-scan")
    model.trashSelected()
    check(model.cleaning && model.scanning, "a move runs while the scan continues")
    check(model.cleaningStatus?.hasPrefix("Moving 1 item") == true, "the move has its own status line")
    _ = await waitUntil("move to finish", timeout: 120) { !model.cleaning }
    check(!fm.fileExists(atPath: fixture.path), "the directory went to the Trash mid-scan")
    check(rowPresent(model) == nil, "the row left the list at once")
    check(model.lastReport?.moved == 1, "Put Back is offered for it")
    let stillScanning = model.scanning
    print("  info scan still running after the move: \(stillScanning)")

    _ = await waitUntil("scan to finish", timeout: 180) { !model.scanning }
    print(String(format: "  info scan finished at %.1fs: %@", Date().timeIntervalSince(t0), model.status))
    check(rowPresent(model) == nil, "the trashed row does not come back when the scan finishes")
    check(model.lastReport?.moved == 1, "Put Back survives the scan finishing")
    check(!model.selected.contains(fixture.path), "nothing stale remains selected")

    model.rescan()
    _ = await waitUntil("rescan to finish", timeout: 180) { !model.scanning }
    check(model.lastReport?.moved == 1, "Put Back survives a rescan")

    model.undoLastClean()
    check(model.cleaning, "Put Back runs")
    _ = await waitUntil("put back to finish", timeout: 120) { !model.cleaning }
    check(fm.fileExists(atPath: fixture.appendingPathComponent("d0/f0.bin").path), "Put Back restored the directory with its contents")
    _ = await waitUntil("post-undo rescan to finish", timeout: 180) { !model.scanning }
    check(rowPresent(model) != nil, "the row is offered again after Put Back")

    try? fm.removeItem(at: fixture)
    print("\nview model: \(failures == 0 ? "all ok" : "\(failures) failed")")
    exit(failures == 0 ? 0 : 1)
}
// Nothing above may run past this: the fixture must not outlive the test.
Task {
    try? await Task.sleep(nanoseconds: 900_000_000_000)
    try? fm.removeItem(at: fixture)
    print("view model: timed out"); exit(1)
}
RunLoop.main.run()
