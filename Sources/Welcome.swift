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
                Button("Skip") { onFinish() }
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
        .frame(width: 640, height: 560)
        .background(.background)
    }

    private var footer: some View {
        HStack {
            Button {
                withAnimation(.snappy(duration: 0.28)) { page -= 1 }
            } label: {
                Label("Back", systemImage: "chevron.left").labelStyle(.titleAndIcon)
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
                Text(isLast ? "Get Started" : "Next")
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

            if let story = page.story {
                Text(.init(story))
                    .font(.title3)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .lineSpacing(3)
                    .frame(maxWidth: 500)
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

private struct StepRow: View {
    let number: Int
    let title: String
    let detail: String

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            Text("\(number)")
                .font(.callout.weight(.bold))
                .foregroundStyle(.white)
                .frame(width: 26, height: 26)
                .background(Circle().fill(Color.accentColor))
            VStack(alignment: .leading, spacing: 2) {
                Text(.init(title)).font(.headline)
                Text(.init(detail)).font(.subheadline).foregroundStyle(.secondary)
            }
        }
    }
}

// MARK: - Content

private struct WelcomePage {
    let icon: String
    let title: String
    var story: String? = nil
    var steps: [(title: String, detail: String)] = []

    static func all(sandboxed: Bool) -> [WelcomePage] {
        let firstStep: (title: String, detail: String) = sandboxed
            ? ("Grant a folder",
               "DevSweep is sandboxed for the App Store, so it only looks where you allow. Choose your **Home folder** to cover every cache.")
            : ("Scan your Mac",
               "DevSweep walks your home folder and measures what each tool left behind — it takes about a second.")

        return [
            WelcomePage(
                icon: "sparkles",
                title: "Welcome to DevSweep",
                story: "Every project you build leaves a trail — caches, artifacts, downloaded dependencies. The sawdust of software. It is invisible, it is harmless, and over the months it quietly swallows *tens of gigabytes* of your disk.\n\nDevSweep is the broom."
            ),
            WelcomePage(
                icon: "internaldrive.fill",
                title: "It knows where to look",
                story: "Xcode's DerivedData. The npm and Gradle caches. Docker layers, Rust `target` folders, Python virtualenvs, simulator runtimes. DevSweep understands **dozens of developer tools** and finds the space they have tucked into corners of your home folder you never open."
            ),
            WelcomePage(
                icon: "checkmark.shield.fill",
                title: "Safe by design",
                story: "DevSweep never deletes. Everything it clears goes to the **Trash**, so you can always pull it back.\n\nEvery item is labelled — **Safe** to remove, **Review** first, or **Protected** and never touched. Your keys, credentials and settings are off-limits, and a separate guard double-checks every path before anything moves."
            ),
            WelcomePage(
                icon: "hand.point.up.left.fill",
                title: "Three steps to a lighter Mac",
                steps: [
                    firstStep,
                    ("Review and pick",
                     "Browse what it found — size and safety are shown for every row. Tick what you want gone."),
                    ("Move to Trash",
                     "Reclaim the space. Nothing is truly gone until you empty the Trash yourself."),
                ]
            ),
        ]
    }
}
