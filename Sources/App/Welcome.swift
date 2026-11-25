import SwiftUI

// MARK: - First-run welcome

/// A short, story-driven introduction shown the first time DevSweep launches.
/// It explains why the app exists, what it finds, why it is safe, and how to
/// start — then hands off to granting a folder. Persisted via `@AppStorage`, so
/// it appears exactly once.
struct WelcomeView: View {
    /// Sandbox build tailors the first step (grant a folder vs. just scan).
    let sandboxed: Bool
    /// Called when the user finishes or skips. The caller records that the
    /// welcome was seen and kicks off the grant/scan flow.
    let onFinish: () -> Void

    @State private var page = 0

    private var pages: [WelcomePage] { WelcomePage.all(sandboxed: sandboxed) }
    private var isLast: Bool { page == pages.count - 1 }

    var body: some View {
        VStack(spacing: 0) {
            // Skip, top-right.
            HStack {
                Spacer()
                Button(action: onFinish) { Text("Skip", comment: "Welcome sheet: dismisses the introduction.") }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .font(.callout)
            }
            .padding([.top, .trailing], 16)

            Spacer(minLength: 0)

            PageContent(page: pages[page])
                .id(page)
                .transition(.asymmetric(
                    insertion: .move(edge: .trailing).combined(with: .opacity),
                    removal: .move(edge: .leading).combined(with: .opacity)))
                .padding(.horizontal, 44)

            Spacer(minLength: 0)

            footer
        }
        // A hard height would crop the longest page if the system text size grows.
        // The tallest page measures 419pt today, so 560 is the comfortable resting
        // size and the sheet grows rather than clips if it ever needs more.
        .frame(width: 640)
        .frame(minHeight: 560)
        .background(.background)
    }

    private var footer: some View {
        HStack {
            Button {
                withAnimation(.snappy(duration: 0.28)) { page -= 1 }
            } label: {
                Label {
                    Text("Back", comment: "Welcome sheet: goes to the previous page.")
                } icon: {
                    Image(systemName: "chevron.left")
                }
                .labelStyle(.titleAndIcon)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .opacity(page == 0 ? 0 : 1)
            .disabled(page == 0)

            Spacer()

            HStack(spacing: 7) {
                ForEach(0 ..< pages.count, id: \.self) { i in
                    Circle()
                        .fill(i == page ? Color.accentColor : Color.secondary.opacity(0.3))
                        .frame(width: 7, height: 7)
                        .animation(.snappy, value: page)
                }
            }

            Spacer()

            Button {
                if isLast {
                    onFinish()
                } else {
                    withAnimation(.snappy(duration: 0.28)) { page += 1 }
                }
            } label: {
                Group {
                    if isLast {
                        Text("Get Started", comment: "Welcome sheet: last page's main button.")
                    } else {
                        Text("Next", comment: "Welcome sheet: advances to the next page.")
                    }
                }
                .frame(minWidth: 84)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .keyboardShortcut(.defaultAction)
        }
        .padding(20)
    }
}

// MARK: - One page

private struct PageContent: View {
    let page: WelcomePage

    var body: some View {
        VStack(spacing: 18) {
            ZStack {
                Circle()
                    .fill(LinearGradient(
                        colors: [Color(red: 0.20, green: 0.55, blue: 0.95),
                                 Color(red: 0.10, green: 0.72, blue: 0.55)],
                        startPoint: .topLeading, endPoint: .bottomTrailing))
                    .frame(width: 92, height: 92)
                    .shadow(color: .black.opacity(0.18), radius: 10, y: 4)
                Image(systemName: page.icon)
                    .font(.system(size: 42, weight: .medium))
                    .foregroundStyle(.white)
            }

            Text(page.title)
                .font(.system(size: 26, weight: .bold))
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)

            if let story = page.story {
                Text(story)
                    .font(.title3)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .lineSpacing(3)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: 500)
            }

            if page.choosesLanguage {
                LanguageChoice()
                    .padding(.top, 4)
            }

            if !page.steps.isEmpty {
                VStack(alignment: .leading, spacing: 14) {
                    ForEach(Array(page.steps.enumerated()), id: \.offset) { i, step in
                        StepRow(number: i + 1, title: step.title, detail: step.detail)
                    }
                }
                .frame(maxWidth: 460)
                .padding(.top, 4)
            }
        }
    }
}

/// The first-run language choice. Picking a language other than the current
/// one applies it and relaunches at once — no confirmation, because the
/// welcome has not been marked seen yet, so the app comes straight back to
/// this very page, now in the chosen language, and the user carries on.
private struct LanguageChoice: View {
    @State private var selection = AppLanguage.current

    var body: some View {
        Picker(selection: $selection) {
            ForEach(AppLanguage.allCases) { language in
                // Endonyms: each language named in itself, never translated.
                Text(verbatim: language.menuTitle).tag(language)
            }
        } label: {
            EmptyView()
        }
        .pickerStyle(.radioGroup)
        .labelsHidden()
        .onChange(of: selection) { _, chosen in
            guard chosen != AppLanguage.current else { return }
            AppLanguage.apply(chosen)
            AppLanguage.relaunch()
        }
        .accessibilityLabel(Text("Language", comment: "Submenu with the app's language choices; also the header button."))
    }
}

private struct StepRow: View {
    let number: Int
    let title: LocalizedStringResource
    let detail: LocalizedStringResource

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            Text(number, format: .number)
                .font(.callout.weight(.bold))
                .foregroundStyle(.white)
                .frame(width: 26, height: 26)
                .background(Circle().fill(Color.accentColor))
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.headline)
                    .fixedSize(horizontal: false, vertical: true)
                Text(detail).font(.subheadline).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

// MARK: - Content

/// All copy is `LocalizedStringResource`: a literal is extracted as-is, and
/// `Text(resource)` keeps the Markdown (bold, paragraphs) after translation.
private struct WelcomePage {
    let icon: String
    let title: LocalizedStringResource
    var story: LocalizedStringResource? = nil
    var steps: [(title: LocalizedStringResource, detail: LocalizedStringResource)] = []
    /// Shows the language radio group under the story.
    var choosesLanguage = false

    static func all(sandboxed: Bool) -> [WelcomePage] {
        let firstStep: (title: LocalizedStringResource, detail: LocalizedStringResource) = sandboxed
            ? (LocalizedStringResource("Grant your Home folder", comment: "Welcome sheet, step 1 title (App Store build)."),
               LocalizedStringResource("DevSweep is sandboxed for the App Store, so it only looks where you allow. In the picker, select the folder with the **house icon and your username** — that one grant covers every cache. Granting a smaller folder works too, but the results stay partial.",
                                       comment: "Welcome sheet, step 1 detail (App Store build). Markdown bold."))
            : (LocalizedStringResource("Scan your Mac", comment: "Welcome sheet, step 1 title (unsandboxed build)."),
               LocalizedStringResource("DevSweep walks your home folder and measures what each tool left behind — it takes about a second.",
                                       comment: "Welcome sheet, step 1 detail (unsandboxed build)."))

        return [
            WelcomePage(
                icon: "globe",
                title: LocalizedStringResource("Choose your language", comment: "Welcome sheet, first page title: the language choice."),
                story: LocalizedStringResource("DevSweep restarts in the language you pick and brings you right back here. You can change it any time with the Language button at the top of the window.",
                                               comment: "Welcome sheet, first page text under the language choice."),
                choosesLanguage: true
            ),
            WelcomePage(
                icon: "sparkles",
                title: LocalizedStringResource("Welcome to DevSweep", comment: "Welcome sheet, page 1 title. 'DevSweep' is the app name."),
                story: LocalizedStringResource("Every project you build leaves a trail — caches, artifacts, downloaded dependencies. The sawdust of software. It is invisible, it is harmless, and over the months it quietly swallows *tens of gigabytes* of your disk.\n\nDevSweep is the broom.",
                                               comment: "Welcome sheet, page 1 story. Markdown italics; keep the blank line between paragraphs. The sawdust/broom image may be adapted.")
            ),
            WelcomePage(
                icon: "internaldrive.fill",
                title: LocalizedStringResource("It knows where to look", comment: "Welcome sheet, page 2 title."),
                story: LocalizedStringResource("Xcode's DerivedData. The npm and Gradle caches. Docker layers, Rust `target` folders, Python virtualenvs, simulator runtimes. DevSweep understands **dozens of developer tools** and finds the space they have tucked into corners of your home folder you never open.",
                                               comment: "Welcome sheet, page 2 story. Tool names (Xcode, npm, Gradle, Docker, Rust, Python) and folder names (DerivedData, `target`) stay as they are. Markdown bold.")
            ),
            WelcomePage(
                icon: "switch.2",
                title: LocalizedStringResource("Two sweeps in one", comment: "Welcome sheet, page 3 title: the app has two scan modes."),
                story: LocalizedStringResource("**Developer** digs through toolchains and build output — the sawdust above.\n\n**System Data** is for everyone: app caches, old logs and forgotten iPhone backups — the mystery bulk that Settings lumps under “System Data”.\n\nSwitch between them any time with the tabs at the top.",
                                               comment: "Welcome sheet, page 3 story. The bold words are the two mode tab names and must match their translations; 'System Data' is the term macOS System Settings uses. Markdown; keep blank lines between paragraphs.")
            ),
            WelcomePage(
                icon: "checkmark.shield.fill",
                title: LocalizedStringResource("Safe by design", comment: "Welcome sheet, page 4 title."),
                story: LocalizedStringResource("DevSweep never deletes. Everything it clears goes to the **Trash**, so you can always pull it back.\n\nEvery item is labelled — **Safe** to remove, **Review** first, or **Protected** and never touched. Your keys, credentials and settings are off-limits, and a separate guard double-checks every path before anything moves.",
                                               comment: "Welcome sheet, page 4 story. The bold Safe / Review / Protected must match the badge translations; 'Trash' is the macOS Trash. Markdown; keep the blank line.")
            ),
            WelcomePage(
                icon: "hand.point.up.left.fill",
                title: LocalizedStringResource("Three steps to a lighter Mac", comment: "Welcome sheet, page 5 title."),
                steps: [
                    firstStep,
                    (LocalizedStringResource("Review and pick", comment: "Welcome sheet, step 2 title."),
                     LocalizedStringResource("Browse what it found — size and safety are shown for every row. Tick what you want gone.", comment: "Welcome sheet, step 2 detail. 'Tick' means select the checkbox.")),
                    (LocalizedStringResource("Move to Trash", comment: "Welcome sheet, step 3 title. Same wording as the main button."),
                     LocalizedStringResource("Reclaim the space. Nothing is truly gone until you empty the Trash yourself.", comment: "Welcome sheet, step 3 detail.")),
                ]
            ),
        ]
    }
}
