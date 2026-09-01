# DevSweep 1.1.0 — Test Plan

Two layers: the **automated suite** (`./test.sh`, add `--live` for real-machine
scans) and a **manual checklist** for everything only a human at the screen can
judge. Run the automated suite before every build; walk the manual list before
every release.

## Automated suite — `./test.sh --live`

Status: **135 / 135 passing** (2026-09-01, this machine).

| # | Area | What it proves |
|---|------|----------------|
| 1 | Safety guard | Protected folders, credentials, paths outside $HOME, `..` traversal and symlink escapes are all refused; legitimate caches are allowed |
| 2 | Scan items | Rows on protected paths offer nothing for deletion, containers filter children through the guard |
| 3 | Project walker | Real build output is detected by marker evidence; same-named source folders (`bin` of shell scripts, `dist` of plain HTML…) are left alone; exclusions honoured; symlinked artifacts skipped |
| 4 | Catalog integrity | Every rule's group is ordered, no duplicate/absolute/traversing paths, every rule passes the guard |
| 5 | Everyday catalog integrity | Same checks for the System Data rules; only Logs is tagged Safe (app caches and device backups can never be mass-selected); the two catalogs never bleed into each other |
| 6 | Sizing (fts walker) | All files counted; **files inside `.app` bundles counted** (regression: the old walker skipped them); symlinks not followed; totals in the right ballpark |
| 7 | Cancellation | A cancelled sizing run measures nothing; a cancelled project scan returns nothing; an uncancelled flag changes nothing |
| 8 | Disk space | Reads succeed repeatedly (regression: the cached-URL bug returned the first reading forever); free ≤ total |
| 9 | Size parsing | docker/brew/nix output parsed; hex digests, version numbers and bare counts are not sizes |
| 10 | Row removal | Deleting rows updates containers, empties disappear, Protected rows stay |
| 11 | Trash flow | Items land in the Trash recoverably; direct attacks with protected paths are refused by the last-line guard; the report records where each item landed |
| 11b | Put Back (undo) | A restore round-trips contents back to the original path; a rebuilt directory is never overwritten; destinations outside $HOME are refused even from a corrupted report |
| 11c | Friendly names | Bundle ids of installed apps become app names with the id kept as the note; ordinary and dot-folder names pass through; uninstalled bundle ids stay as-is |
| 11d | User journey | End-to-end: scan a fixture project → every row has a size → clean all → rows disappear without rescan and folders are gone → Put Back restores everything with contents intact → a rescan offers them again |
| 11c | Auto mode | An empty Developer scan on an untouched machine switches to System Data; a dev machine stays; an explicit user choice is never overridden; System Data never switches away |
| 12 | Live Developer scan | Real scan of this machine: every offered row passes the guard, no nesting, no duplicates, no loose files |
| 13 | Live System Data scan | Same guarantees for Everyday mode; only everyday groups appear |
| 14 | Live streaming | Partial results are emitted during measuring; progress counter never overshoots; final result complete |

## Manual checklist — walk before release

### A. First run & intro
- [ ] Delete the app's defaults (`defaults delete com.zackyoosuf.DevSweep` or fresh account) and launch: the intro shows once, with **5 pages** — the new "Two sweeps in one" page explains Developer vs System Data.
- [ ] Existing users (welcomeSeen v1) see the updated intro **once** after updating, then never again.
- [ ] Skip works from any page; Get Started on the sandbox build flows straight into the folder-grant panel.

### B. Mode switch (the tabs)
- [ ] Tabs show as a capsule with icons; the accent pill slides when switching.
- [ ] Switch to System Data: the developer rows clear **immediately** (never showing the old mode's data), rows stream in as they're measured.
- [ ] Click the other tab **while measuring**: the scan stops within ~1 second and the new mode starts loading. No half-results from the old mode ever appear.
- [ ] The chosen mode is remembered across quit/relaunch.
- [ ] System Data rows use plain language; app cache rows show real app names ("Spotify", not `com.spotify.client`), with the bundle id as the small note.
- [ ] In System Data mode: no project artifacts, no Docker/Homebrew prune tools offered.

### C. Free space (the original bug)
- [ ] Move items to Trash in DevSweep, then empty the Trash in Finder: the free-space number rises **by itself within a few seconds** — no Rescan click needed, even with DevSweep frontmost.
- [ ] The footer's "Trash holds X" line drops to the empty-Trash message at the same time.
- [ ] Rescan after any external deletion (e.g. `rm -rf` a cache in Terminal) shows updated free space.

### D. Scanning & progress
- [ ] First scan: rows appear progressively with "Measuring caches… N of M" — no long blank wait.
- [ ] Rescan keeps the previous list visible until the new one is ready (no flicker to empty).
- [ ] While scanning: Rescan, the Folders menu, the Tools menu, and the main clean button are disabled; the tabs stay clickable.
- [ ] Excluding a folder or removing a grant mid-scan is not lost — a follow-up rescan runs automatically when the current one ends.

### E. Cleaning flow
- [ ] "Select everything safe" then the confirm sheet: counts, sizes and Review warnings correct.
- [ ] Confirm sheet rows lead with the friendly name ("Spotify", "web-app › node_modules") with the raw path as small print beneath.
- [ ] After moving to Trash: the moved rows disappear without a rescan, the banner reports the count, disk gauge updates.
- [ ] **Put Back** on the banner restores every item of the last cleanup to its original place, the rows reappear after the automatic rescan, and the Trash no longer holds them.
- [ ] Put Back when a tool already rebuilt one of the directories: that item is skipped (stays in the Trash), the rest restore, and the status says how many could not go back.
- [ ] Restore something from the Trash by hand in Finder, click Rescan: it reappears.
- [ ] Protected rows always show a lock and can never be ticked, in both modes.

### E2. Auto mode (needs a non-developer environment)
- [ ] On a Mac (or fresh account) with no developer tooling: first scan runs in Developer, finds nothing, switches itself to System Data with the status "No developer caches here — showing System Data", then scans.
- [ ] After the user has ever tapped a tab (or a mode was saved from a past session), the app never switches modes by itself.
- [ ] On this dev machine: no auto-switch ever happens (Developer scan is never empty).

### F. Sandbox / App Store build specifics
- [ ] No grant → grant screen; subfolder-only grant → partial results + Home-folder banner.
- [ ] Grants survive relaunch; removing the last grant returns to the grant screen.
- [ ] System Data mode with only a subfolder granted behaves sensibly (catalog needs the Home grant).

### G. Accessibility & window
- [ ] VoiceOver reads each row's checkbox as "Select ‹name›, selected/not selected", the disk gauge as "Disk space, X free of Y", and both tabs with their selected state.
- [ ] Window at minimum size (900×620) and at larger text sizes: nothing clipped, including the new tabs.

### H. Performance sanity
- [ ] Full developer scan on a loaded dev machine finishes in seconds, not minutes (App Store build included — the fts walker replaced the slow FileManager walk).
- [ ] Caches full of app bundles (Playwright/Electron) report realistic sizes, matching `du -sh` within a few percent.
- [ ] Re-activating the app repeatedly with a very full Trash does not re-walk the Trash each time (mtime debounce).
