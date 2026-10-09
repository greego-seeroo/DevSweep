import Foundation

/// Who a scan is for. Developer mode covers toolchains and build output;
/// Everyday mode covers the caches any Mac accumulates — apps, logs, device
/// backups — in language that doesn't assume you know what a toolchain is.
enum Audience: String, CaseIterable {
    case developer
    case everyday

    /// "System Data" is the name Settings ▸ Storage gives the bucket people are
    /// trying to shrink, so that is the word the switch uses.
    var label: String {
        switch self {
        case .developer: return "Developer"
        case .everyday: return "System Data"
        }
    }

    /// SF Symbol shown next to the label in the mode switch.
    var icon: String {
        switch self {
        case .developer: return "hammer.fill"
        case .everyday: return "internaldrive.fill"
        }
    }
}

/// A known location on a developer machine, with a hand-written verdict on
/// whether losing it costs you anything.
struct Rule {
    let group: String
    let title: String
    /// Path relative to the user's home directory.
    let relPath: String
    let tag: SafetyTag
    let note: String
    /// List the directory's immediate children as individually selectable rows.
    var expand: Bool = false
}

/// A build artifact found inside a checked-out repository. `name` alone is never
/// enough — `dist` and `bin` and `target` are all perfectly ordinary source
/// directory names — so a hit only counts when the parent carries one of the
/// markers that proves what kind of project it is.
struct ProjectArtifact {
    enum Marker {
        case file(String)
        case dir(String)
        /// Any file with this extension, e.g. `.csproj`.
        case ext(String)
    }

    let name: String
    let markers: [Marker]
    /// Require every marker rather than any one of them.
    var requiresAll: Bool = false
    let tag: SafetyTag
    let note: String
}

enum Catalog {
    static let groupOrder = [
        "Xcode",
        "Simulators",
        "Flutter & Dart",
        "Android",
        "JVM & Gradle",
        "Node & web",
        "Python",
        "Rust",
        "Go",
        "Ruby",
        ".NET",
        "PHP",
        "C, C++ & native",
        "Containers & infrastructure",
        "Editors & IDEs",
        "Game engines",
        "AI & ML models",
        "Package managers",
        "Version managers",
        "Other caches",
        "Project artifacts",
        // Everyday mode's groups. The two catalogs never run together, so the
        // relative order between the two halves of this list never shows.
        "App caches",
        "Logs & diagnostics",
        "iPhone & iPad backups",
    ]

    // MARK: - Everyday catalog

    /// What Everyday mode scans. Deliberately short: a handful of places that are
    /// genuinely safe to offer, each explained without developer vocabulary.
    /// Browser caches surface as children of ~/Library/Caches (Chrome, Firefox);
    /// Safari and Mail live in Library/Containers, which the guard protects.
    static let everydayRules: [Rule] = [
        Rule(group: "App caches", title: "App caches",
             relPath: "Library/Caches", tag: .review,
             note: "Files your apps saved so they load faster — one folder per app. Apps rebuild these, but some may sign you out or re-download data afterwards. Tick the big ones you recognise rather than everything.",
             expand: true),

        Rule(group: "Logs & diagnostics", title: "App logs",
             relPath: "Library/Logs", tag: .safe,
             note: "Diagnostic text files your apps wrote. Only useful when troubleshooting a problem; apps start new ones automatically.",
             expand: true),

        Rule(group: "iPhone & iPad backups", title: "Device backups",
             relPath: "Library/Application Support/MobileSync/Backup", tag: .review,
             note: "Complete backups of iPhones and iPads synced to this Mac — often tens of gigabytes. Only delete a backup if the device is gone or backed up to iCloud; it cannot be rebuilt from the Mac.",
             expand: true),
    ]

    // MARK: - Catalog

    static let rules: [Rule] = [

        // MARK: Xcode
        Rule(group: "Xcode", title: "Derived data",
             relPath: "Library/Developer/Xcode/DerivedData", tag: .safe,
             note: "Build intermediates, indexes and module caches, one folder per project. Xcode rebuilds whatever it needs. This is almost always the biggest win.",
             expand: true),

        Rule(group: "Xcode", title: "Build products",
             relPath: "Library/Developer/Xcode/Products", tag: .safe,
             note: "Copies of built products. Regenerated on the next build."),

        Rule(group: "Xcode", title: "Xcode's own cache",
             relPath: "Library/Caches/com.apple.dt.Xcode", tag: .safe,
             note: "Xcode's internal scratch space. Recreated on launch."),

        Rule(group: "Xcode", title: "Documentation cache",
             relPath: "Library/Developer/Xcode/DocumentationCache", tag: .safe,
             note: "Downloaded developer documentation. Re-downloaded on demand."),

        Rule(group: "Xcode", title: "Device logs",
             relPath: "Library/Developer/Xcode/iOS Device Logs", tag: .safe,
             note: "Crash logs pulled off attached devices. Diagnostic only."),

        Rule(group: "Xcode", title: "Archives",
             relPath: "Library/Developer/Xcode/Archives", tag: .review,
             note: "Contains the dSYMs for builds you shipped. Without them you cannot symbolicate crash reports from the App Store. Delete archives for versions you no longer support; keep the rest.",
             expand: true),

        Rule(group: "Xcode", title: "iOS device support",
             relPath: "Library/Developer/Xcode/iOS DeviceSupport", tag: .review,
             note: "Debug symbols copied off each physical device, one folder per iOS build. Safe to delete, but Xcode re-extracts them (slowly, several minutes) the next time you plug in a device running that version.",
             expand: true),

        Rule(group: "Xcode", title: "watchOS device support",
             relPath: "Library/Developer/Xcode/watchOS DeviceSupport", tag: .review,
             note: "As above, for paired watches.",
             expand: true),

        Rule(group: "Xcode", title: "tvOS device support",
             relPath: "Library/Developer/Xcode/tvOS DeviceSupport", tag: .review,
             note: "As above, for Apple TV devices.",
             expand: true),

        Rule(group: "Xcode", title: "User data",
             relPath: "Library/Developer/Xcode/UserData", tag: .never,
             note: "Your code snippets, key bindings, themes, breakpoints and behaviours. None of this comes back."),

        Rule(group: "Xcode", title: "Provisioning profiles",
             relPath: "Library/MobileDevice/Provisioning Profiles", tag: .never,
             note: "Signing profiles for device builds and distribution. Losing these breaks builds until you re-download them from the portal."),

        // MARK: Simulators
        Rule(group: "Simulators", title: "Simulator devices",
             relPath: "Library/Developer/CoreSimulator/Devices", tag: .review,
             note: "One disk image per simulator, including every app you ever installed and its data. Deleting loses that state. Prefer Tools ▸ Delete unavailable simulators, which removes only devices whose runtime is already gone."),

        Rule(group: "Simulators", title: "Simulator caches",
             relPath: "Library/Developer/CoreSimulator/Caches", tag: .safe,
             note: "Cached runtime images and dyld caches. Rebuilt on next simulator boot."),

        Rule(group: "Simulators", title: "Simulator temp files",
             relPath: "Library/Developer/CoreSimulator/Temp", tag: .safe,
             note: "Scratch space for the simulator host."),

        Rule(group: "Simulators", title: "Simulator logs",
             relPath: "Library/Logs/CoreSimulator", tag: .safe,
             note: "Simulator log archives. Purely diagnostic."),

        Rule(group: "Simulators", title: "Playground devices",
             relPath: "Library/Developer/XCPGDevices", tag: .safe,
             note: "Throwaway simulator devices created for Swift Playgrounds and previews."),

        Rule(group: "Simulators", title: "Test devices",
             relPath: "Library/Developer/XCTestDevices", tag: .safe,
             note: "Throwaway simulator devices created by test runs."),

        // MARK: Flutter & Dart
        Rule(group: "Flutter & Dart", title: "Pub package cache",
             relPath: ".pub-cache", tag: .safe,
             note: "Every Dart package you have ever depended on. `flutter pub get` re-downloads what your projects actually need — expect one slow fetch afterwards.",
             expand: true),

        Rule(group: "Flutter & Dart", title: "Dart analysis server cache",
             relPath: ".dartServer", tag: .safe,
             note: "Analyzer index. Rebuilt when you next open a project."),

        Rule(group: "Flutter & Dart", title: "Dart tool cache",
             relPath: "Library/Caches/dart", tag: .safe,
             note: "Dart SDK download cache."),

        Rule(group: "Flutter & Dart", title: "FVM Flutter versions",
             relPath: "fvm/versions", tag: .review,
             note: "Whole Flutter SDKs, one per version FVM manages. Re-downloadable with `fvm install`, but each is a gigabyte-scale clone.",
             expand: true),

        // MARK: Android
        Rule(group: "Android", title: "Android build cache",
             relPath: ".android/cache", tag: .safe,
             note: "Android build system scratch space."),

        Rule(group: "Android", title: "Android Studio caches",
             relPath: "Library/Caches/Google", tag: .safe,
             note: "IDE indexes and caches, one folder per Android Studio version. Rebuilt on next launch (first open will be slow).",
             expand: true),

        Rule(group: "Android", title: "Emulator system images",
             relPath: "Library/Android/sdk/system-images", tag: .review,
             note: "Bootable Android images, roughly 2–8 GB each. Re-downloadable through the SDK Manager, but that is a large download.",
             expand: true),

        Rule(group: "Android", title: "Virtual devices (AVDs)",
             relPath: ".android/avd", tag: .review,
             note: "Each emulator's disk and snapshots. Deleting loses installed apps and saved state; the device definition must be recreated in Device Manager.",
             expand: true),

        Rule(group: "Android", title: "Android SDK",
             relPath: "Library/Android/sdk", tag: .never,
             note: "Platform tools, build tools and platforms. Your toolchain — not a cache."),

        // MARK: JVM & Gradle
        Rule(group: "JVM & Gradle", title: "Gradle caches",
             relPath: ".gradle/caches", tag: .safe,
             note: "Downloaded dependencies and the build cache. Gradle re-fetches on the next build. Frequently tens of gigabytes.",
             expand: true),

        Rule(group: "JVM & Gradle", title: "Gradle daemon logs",
             relPath: ".gradle/daemon", tag: .safe,
             note: "Logs and registry for background Gradle daemons."),

        Rule(group: "JVM & Gradle", title: "Gradle distributions",
             relPath: ".gradle/wrapper/dists", tag: .safe,
             note: "Gradle itself, one copy per version your projects' wrappers pin. Re-downloaded on the next build.",
             expand: true),

        Rule(group: "JVM & Gradle", title: "Gradle-managed JDKs",
             relPath: ".gradle/jdks", tag: .review,
             note: "JDKs Gradle downloaded via toolchain auto-provisioning. Re-downloaded on the next build that needs them."),

        Rule(group: "JVM & Gradle", title: "Maven repository",
             relPath: ".m2/repository", tag: .safe,
             note: "Cached Maven artifacts. Re-fetched on demand."),

        Rule(group: "JVM & Gradle", title: "Ivy cache",
             relPath: ".ivy2/cache", tag: .safe,
             note: "Cached Ivy/sbt artifacts. Re-resolved on the next build."),

        Rule(group: "JVM & Gradle", title: "Coursier cache",
             relPath: "Library/Caches/Coursier", tag: .safe,
             note: "Scala's artifact cache. Re-fetched by sbt or Mill on demand."),

        Rule(group: "JVM & Gradle", title: "sbt boot",
             relPath: ".sbt/boot", tag: .safe,
             note: "sbt's downloaded launchers and Scala compilers. Re-downloaded on the next build."),

        Rule(group: "JVM & Gradle", title: "Kotlin/Native dependencies",
             relPath: ".konan", tag: .review,
             note: "The Kotlin/Native compiler and platform libraries. Re-downloaded on the next multiplatform build — a large fetch.",
             expand: true),

        // MARK: Node & web
        Rule(group: "Node & web", title: "npm cache",
             relPath: ".npm/_cacache", tag: .safe,
             note: "npm's content-addressable download cache. Equivalent to `npm cache clean --force`."),

        Rule(group: "Node & web", title: "Yarn cache",
             relPath: "Library/Caches/Yarn", tag: .safe,
             note: "Yarn's global package cache."),

        Rule(group: "Node & web", title: "Yarn Berry cache",
             relPath: ".yarn/berry/cache", tag: .safe,
             note: "Yarn 2+ zipped package cache."),

        Rule(group: "Node & web", title: "pnpm store",
             relPath: "Library/pnpm/store", tag: .safe,
             note: "pnpm's global content-addressable store. Re-populated on install."),

        Rule(group: "Node & web", title: "Bun install cache",
             relPath: ".bun/install/cache", tag: .safe,
             note: "Bun's global package cache. Re-populated by `bun install`."),

        Rule(group: "Node & web", title: "Deno cache",
             relPath: "Library/Caches/deno", tag: .safe,
             note: "Deno's dependency and compilation cache. Re-fetched on the next run."),

        Rule(group: "Node & web", title: "node-gyp headers",
             relPath: "Library/Caches/node-gyp", tag: .safe,
             note: "Node headers kept for building native addons, one set per Node version. Re-downloaded when a native module is next compiled."),

        Rule(group: "Node & web", title: "TypeScript cache",
             relPath: "Library/Caches/typescript", tag: .safe,
             note: "Auto-fetched type definitions for editors. Re-downloaded on demand."),

        Rule(group: "Node & web", title: "Playwright browsers",
             relPath: "Library/Caches/ms-playwright", tag: .safe,
             note: "Downloaded browser binaries for Playwright tests. Re-downloaded by `playwright install`."),

        Rule(group: "Node & web", title: "Playwright browsers (Go)",
             relPath: "Library/Caches/ms-playwright-go", tag: .safe,
             note: "Browser binaries for the Go Playwright bindings. Re-downloaded on demand."),

        Rule(group: "Node & web", title: "Cypress binaries",
             relPath: "Library/Caches/Cypress", tag: .review,
             note: "The Cypress test runner itself, one copy per version. Re-downloaded by `cypress install` — a few hundred megabytes each time.",
             expand: true),

        Rule(group: "Node & web", title: "Electron binaries",
             relPath: "Library/Caches/electron", tag: .safe,
             note: "Downloaded Electron runtimes. Re-fetched on the next install."),

        Rule(group: "Node & web", title: "electron-builder cache",
             relPath: "Library/Caches/electron-builder", tag: .safe,
             note: "Packaging tools and downloaded runtimes for electron-builder."),

        Rule(group: "Node & web", title: "Puppeteer browsers",
             relPath: ".cache/puppeteer", tag: .safe,
             note: "Chromium builds downloaded by Puppeteer. Re-downloaded on the next install."),

        // MARK: Python
        Rule(group: "Python", title: "pip cache",
             relPath: "Library/Caches/pip", tag: .safe,
             note: "Cached Python wheels. Equivalent to `pip cache purge`."),

        Rule(group: "Python", title: "pip cache (XDG)",
             relPath: ".cache/pip", tag: .safe,
             note: "The same wheel cache, when pip is configured to follow XDG paths."),

        Rule(group: "Python", title: "uv cache",
             relPath: "Library/Caches/uv", tag: .safe,
             note: "uv's wheel and source cache. Re-populated on the next sync — uv is fast enough that this costs little."),

        Rule(group: "Python", title: "Poetry artifacts",
             relPath: "Library/Caches/pypoetry/artifacts", tag: .safe,
             note: "Downloaded distributions kept by Poetry. Re-fetched on demand."),

        Rule(group: "Python", title: "Poetry cache",
             relPath: "Library/Caches/pypoetry/cache", tag: .safe,
             note: "Poetry's resolver cache."),

        Rule(group: "Python", title: "Poetry virtualenvs",
             relPath: "Library/Caches/pypoetry/virtualenvs", tag: .review,
             note: "One full virtualenv per project Poetry manages. Deleting means `poetry install` again for each project you return to.",
             expand: true),

        Rule(group: "Python", title: "Pipenv virtualenvs",
             relPath: ".local/share/virtualenvs", tag: .review,
             note: "One full virtualenv per Pipenv project. Rebuilt by `pipenv install`.",
             expand: true),

        Rule(group: "Python", title: "pre-commit hooks",
             relPath: ".cache/pre-commit", tag: .safe,
             note: "Cloned and built hook environments. Rebuilt on the next `pre-commit run` — slow, but automatic."),

        Rule(group: "Python", title: "pyenv build cache",
             relPath: ".pyenv/cache", tag: .safe,
             note: "Source tarballs pyenv downloaded to build interpreters. Not needed once the interpreter is built."),

        Rule(group: "Python", title: "pyenv interpreters",
             relPath: ".pyenv/versions", tag: .never,
             note: "The Python interpreters themselves, and the packages installed into them. Your toolchain — not a cache."),

        // MARK: Rust
        Rule(group: "Rust", title: "Cargo registry",
             relPath: ".cargo/registry", tag: .safe,
             note: "Downloaded and unpacked crate sources plus the index. Cargo re-fetches what your builds need.",
             expand: true),

        Rule(group: "Rust", title: "Cargo git checkouts",
             relPath: ".cargo/git", tag: .safe,
             note: "Clones of git dependencies. Re-cloned on the next build."),

        Rule(group: "Rust", title: "rustup downloads",
             relPath: ".rustup/downloads", tag: .safe,
             note: "Partially downloaded toolchain archives. Scratch space."),

        Rule(group: "Rust", title: "sccache",
             relPath: "Library/Caches/Mozilla.sccache", tag: .safe,
             note: "Shared compilation cache. Rebuilt as you compile."),

        Rule(group: "Rust", title: "rustup toolchains",
             relPath: ".rustup/toolchains", tag: .never,
             note: "The Rust compilers themselves. Re-installable with rustup, but this is your toolchain, not a cache."),

        // MARK: Go
        Rule(group: "Go", title: "Go build cache",
             relPath: "Library/Caches/go-build", tag: .safe,
             note: "Compiled package objects. Equivalent to `go clean -cache`. Rebuilt on the next build."),

        Rule(group: "Go", title: "Go build cache (XDG)",
             relPath: ".cache/go-build", tag: .safe,
             note: "The same build cache, when XDG paths are in use."),

        // The module cache is added dynamically (see goRules) because its files are
        // read-only and its location depends on GOMODCACHE.

        // MARK: Ruby
        Rule(group: "Ruby", title: "Bundler cache",
             relPath: ".bundle/cache", tag: .safe,
             note: "Gems Bundler cached for offline installs. Re-fetched by `bundle install`."),

        Rule(group: "Ruby", title: "Installed gems",
             relPath: ".gem", tag: .review,
             note: "Gems installed outside a version manager, including their native extensions. `bundle install` rebuilds what a project needs, but native gems recompile slowly.",
             expand: true),

        Rule(group: "Ruby", title: "rbenv build cache",
             relPath: ".rbenv/cache", tag: .safe,
             note: "Ruby source tarballs downloaded to build interpreters. Not needed once built."),

        Rule(group: "Ruby", title: "RVM archives",
             relPath: ".rvm/archives", tag: .safe,
             note: "Downloaded Ruby source archives. Scratch space."),

        Rule(group: "Ruby", title: "rbenv interpreters",
             relPath: ".rbenv/versions", tag: .never,
             note: "The Ruby interpreters themselves, and every gem installed into them. Your toolchain."),

        // MARK: .NET
        Rule(group: ".NET", title: "NuGet packages",
             relPath: ".nuget/packages", tag: .safe,
             note: "The global NuGet package folder. `dotnet restore` re-downloads what your projects reference.",
             expand: true),

        Rule(group: ".NET", title: "NuGet HTTP cache",
             relPath: "Library/Caches/NuGet", tag: .safe,
             note: "NuGet's HTTP response cache. Equivalent to `dotnet nuget locals all --clear`."),

        Rule(group: ".NET", title: ".NET SDK",
             relPath: ".dotnet", tag: .never,
             note: "The .NET SDK and its tools when installed to your home directory. Your toolchain."),

        // MARK: PHP
        Rule(group: "PHP", title: "Composer cache",
             relPath: ".composer/cache", tag: .safe,
             note: "Downloaded packages and metadata. `composer install` re-fetches them."),

        Rule(group: "PHP", title: "Composer cache (XDG)",
             relPath: ".cache/composer", tag: .safe,
             note: "The same Composer cache under XDG paths."),

        // MARK: C, C++ & native
        Rule(group: "C, C++ & native", title: "ccache",
             relPath: ".ccache", tag: .safe,
             note: "Cached object files. Deleting costs one slow rebuild, nothing more."),

        Rule(group: "C, C++ & native", title: "ccache (XDG)",
             relPath: ".cache/ccache", tag: .safe,
             note: "The same ccache under XDG paths."),

        Rule(group: "C, C++ & native", title: "Conan packages",
             relPath: ".conan2/p", tag: .review,
             note: "Downloaded and locally built Conan packages. Re-fetched on the next install, but anything built from source compiles again.",
             expand: true),

        Rule(group: "C, C++ & native", title: "vcpkg build trees",
             relPath: "vcpkg/buildtrees", tag: .safe,
             note: "Intermediate build output for vcpkg ports. Not needed once a port is installed."),

        Rule(group: "C, C++ & native", title: "vcpkg downloads",
             relPath: "vcpkg/downloads", tag: .safe,
             note: "Source archives vcpkg downloaded. Re-fetched when a port is rebuilt."),

        // MARK: Containers & infrastructure
        Rule(group: "Containers & infrastructure", title: "Colima VM disk",
             relPath: ".colima", tag: .review,
             note: "The Colima virtual machine, including every image and container inside it. Recreated by `colima start`, but you lose the VM's contents.",
             expand: true),

        Rule(group: "Containers & infrastructure", title: "Lima VMs",
             relPath: ".lima", tag: .review,
             note: "Lima virtual machine disks. Deleting loses whatever lives inside them.",
             expand: true),

        Rule(group: "Containers & infrastructure", title: "minikube cache",
             relPath: ".minikube/cache", tag: .safe,
             note: "Downloaded ISOs and container images for minikube. Re-downloaded on the next `minikube start`."),

        Rule(group: "Containers & infrastructure", title: "Kubernetes HTTP cache",
             relPath: ".kube/cache", tag: .safe,
             note: "kubectl's discovery and response cache. Rebuilt on the next command."),

        Rule(group: "Containers & infrastructure", title: "Vagrant boxes",
             relPath: ".vagrant.d/boxes", tag: .review,
             note: "Downloaded base boxes, often gigabytes each. Re-downloaded by `vagrant up`.",
             expand: true),

        Rule(group: "Containers & infrastructure", title: "Terraform plugin cache",
             relPath: ".terraform.d/plugin-cache", tag: .safe,
             note: "Cached provider binaries. Re-downloaded by `terraform init`."),

        // MARK: Editors & IDEs
        Rule(group: "Editors & IDEs", title: "JetBrains caches",
             relPath: "Library/Caches/JetBrains", tag: .safe,
             note: "Indexes and local history caches, one folder per IDE version. Rebuilt on next launch — the first project open will be slow.",
             expand: true),

        Rule(group: "Editors & IDEs", title: "JetBrains logs",
             relPath: "Library/Logs/JetBrains", tag: .safe,
             note: "IDE logs. Diagnostic only.",
             expand: true),

        Rule(group: "Editors & IDEs", title: "VS Code cache",
             relPath: "Library/Application Support/Code/Cache", tag: .safe,
             note: "Electron's HTTP cache for VS Code."),

        Rule(group: "Editors & IDEs", title: "VS Code cached data",
             relPath: "Library/Application Support/Code/CachedData", tag: .safe,
             note: "Compiled JavaScript kept per VS Code version. Regenerated on launch; old versions' copies are dead weight."),

        Rule(group: "Editors & IDEs", title: "VS Code extension downloads",
             relPath: "Library/Application Support/Code/CachedExtensionVSIXs", tag: .safe,
             note: "Downloaded extension packages, already installed. Pure leftovers."),

        Rule(group: "Editors & IDEs", title: "VS Code logs",
             relPath: "Library/Application Support/Code/logs", tag: .safe,
             note: "Editor and extension host logs. Diagnostic only."),

        Rule(group: "Editors & IDEs", title: "Cursor cached data",
             relPath: "Library/Application Support/Cursor/CachedData", tag: .safe,
             note: "As VS Code above — compiled JavaScript per version."),

        Rule(group: "Editors & IDEs", title: "Cursor cache",
             relPath: "Library/Application Support/Cursor/Cache", tag: .safe,
             note: "Cursor's HTTP cache."),

        Rule(group: "Editors & IDEs", title: "Neovim cache",
             relPath: ".cache/nvim", tag: .safe,
             note: "Compiled Lua and shada scratch space. Rebuilt on next launch."),

        Rule(group: "Editors & IDEs", title: "JetBrains settings & plugins",
             relPath: "Library/Application Support/JetBrains", tag: .never,
             note: "Your IDE configuration, keymaps and installed plugins. Not a cache."),

        // MARK: Game engines
        Rule(group: "Game engines", title: "Unity caches",
             relPath: "Library/Unity/cache", tag: .safe,
             note: "Unity's shared package and shader cache. Re-downloaded and rebuilt on the next project open.",
             expand: true),

        Rule(group: "Game engines", title: "Unity Asset Store downloads",
             relPath: "Library/Unity/Asset Store-5.x", tag: .review,
             note: "Every asset package you have downloaded. Re-downloadable from the Asset Store, but that is a slow, manual re-fetch.",
             expand: true),

        Rule(group: "Game engines", title: "Unreal derived data cache",
             relPath: "Library/Application Support/Epic/UnrealEngine/Common/DerivedDataCache", tag: .safe,
             note: "Cooked shaders and derived assets. Rebuilt on the next cook — slow, but nothing is lost."),

        Rule(group: "Game engines", title: "Unreal logs",
             relPath: "Library/Logs/Unreal Engine", tag: .safe,
             note: "Editor and build logs. Diagnostic only.",
             expand: true),

        Rule(group: "Game engines", title: "Godot cache",
             relPath: "Library/Caches/Godot", tag: .safe,
             note: "Shader and import caches. Reimported on next project open."),

        // MARK: AI & ML models
        Rule(group: "AI & ML models", title: "Hugging Face cache",
             relPath: ".cache/huggingface", tag: .review,
             note: "Downloaded models and datasets, routinely tens of gigabytes. Everything re-downloads on demand, but these are very large fetches.",
             expand: true),

        Rule(group: "AI & ML models", title: "Ollama models",
             relPath: ".ollama/models", tag: .review,
             note: "Local LLM weights. Re-pullable with `ollama pull`, at several gigabytes per model."),

        Rule(group: "AI & ML models", title: "PyTorch hub cache",
             relPath: ".cache/torch", tag: .review,
             note: "Downloaded model weights and compiled kernels. Re-downloaded on demand."),

        Rule(group: "AI & ML models", title: "Keras models",
             relPath: ".keras", tag: .review,
             note: "Downloaded Keras model weights and datasets."),

        // MARK: Package managers
        Rule(group: "Package managers", title: "Homebrew downloads",
             relPath: "Library/Caches/Homebrew", tag: .safe,
             note: "Downloaded bottles and source tarballs. Equivalent to `brew cleanup` — see Tools for the full cleanup, which also removes old installed versions."),

        Rule(group: "Package managers", title: "CocoaPods cache",
             relPath: "Library/Caches/CocoaPods", tag: .safe,
             note: "Downloaded pod sources. `pod install` re-fetches them."),

        Rule(group: "Package managers", title: "CocoaPods spec repos",
             relPath: ".cocoapods/repos", tag: .review,
             note: "Clones of the podspec repositories. Deleting works, but re-cloning the CocoaPods trunk repo is slow and bandwidth-heavy.",
             expand: true),

        Rule(group: "Package managers", title: "Swift Package Manager cache",
             relPath: "Library/Caches/org.swift.swiftpm", tag: .safe,
             note: "Cloned and cached Swift packages. Re-resolved on next build."),

        // MARK: Version managers
        Rule(group: "Version managers", title: "nvm download cache",
             relPath: ".nvm/.cache", tag: .safe,
             note: "Node tarballs nvm downloaded. Not needed once a version is installed."),

        Rule(group: "Version managers", title: "asdf downloads",
             relPath: ".asdf/downloads", tag: .safe,
             note: "Source archives asdf downloaded to build tools. Scratch space."),

        Rule(group: "Version managers", title: "SDKMAN archives",
             relPath: ".sdkman/archives", tag: .safe,
             note: "Downloaded JDK and tool archives, already installed. Leftovers."),

        Rule(group: "Version managers", title: "SDKMAN temp",
             relPath: ".sdkman/tmp", tag: .safe,
             note: "SDKMAN scratch space."),

        Rule(group: "Version managers", title: "ghcup cache",
             relPath: ".ghcup/cache", tag: .safe,
             note: "Downloaded GHC and cabal archives. Re-downloadable."),

        Rule(group: "Version managers", title: "Node versions (nvm)",
             relPath: ".nvm/versions", tag: .never,
             note: "The Node runtimes themselves and their global packages. Your toolchain."),

        Rule(group: "Version managers", title: "asdf installs",
             relPath: ".asdf/installs", tag: .never,
             note: "Every tool version asdf manages. Your toolchain."),

        Rule(group: "Version managers", title: "SDKMAN candidates",
             relPath: ".sdkman/candidates", tag: .never,
             note: "Your installed JDKs, Gradle and Maven versions. Toolchain."),

        // MARK: Other
        Rule(group: "Other caches", title: "Generic tool cache (~/.cache)",
             relPath: ".cache", tag: .review,
             note: "A shared dumping ground for many tools. Mostly disposable, but read the child rows — some tools keep state here. Anything DevSweep already knows about is listed under its own heading instead.",
             expand: true),

        Rule(group: "Other caches", title: "Chromium Embedded Framework",
             relPath: "Library/Caches/CEF", tag: .safe,
             note: "Shared browser runtime cache used by Electron-style apps."),
    ]

    // MARK: - Project artifacts

    /// What the project scanner looks for inside your repositories. `SafetyGuard`
    /// holds the independent allowlist of names; anything here that is not also
    /// there is silently ignored.
    static let projectArtifacts: [ProjectArtifact] = [
        // Flutter / Dart
        ProjectArtifact(name: ".dart_tool", markers: [.file("pubspec.yaml")], tag: .safe,
                        note: "Dart build metadata. Regenerated by `pub get`."),

        // Generic build output — the marker decides what kind of project this is.
        ProjectArtifact(name: "build",
                        markers: [.file("pubspec.yaml"), .file("build.gradle"), .file("build.gradle.kts"),
                                  .file("package.json"), .file("CMakeLists.txt"), .file("Makefile")],
                        tag: .safe,
                        note: "Build output. Regenerated by the next build."),

        // Apple
        ProjectArtifact(name: "Pods", markers: [.file("Podfile")], tag: .safe,
                        note: "Installed pods. Restored by `pod install`."),
        ProjectArtifact(name: ".build", markers: [.file("Package.swift")], tag: .safe,
                        note: "SwiftPM build output."),
        ProjectArtifact(name: "DerivedData", markers: [.ext("xcodeproj"), .ext("xcworkspace"), .file("Package.swift")],
                        tag: .safe,
                        note: "Project-local derived data."),
        ProjectArtifact(name: "Carthage", markers: [.file("Cartfile"), .file("Cartfile.resolved")], tag: .review,
                        note: "Carthage checkouts and built frameworks. `carthage bootstrap` rebuilds them — slowly."),

        // JVM
        ProjectArtifact(name: ".gradle",
                        markers: [.file("settings.gradle"), .file("settings.gradle.kts"),
                                  .file("build.gradle"), .file("build.gradle.kts")],
                        tag: .safe,
                        note: "Project-local Gradle state."),
        ProjectArtifact(name: "target", markers: [.file("pom.xml"), .file("Cargo.toml"), .file("build.sbt")], tag: .safe,
                        note: "Maven, Cargo or sbt build output. Rebuilt by the next build."),
        ProjectArtifact(name: "out", markers: [.file("build.gradle"), .file("build.gradle.kts")], tag: .safe,
                        note: "Build output."),

        // Node / web
        ProjectArtifact(name: "node_modules", markers: [.file("package.json")], tag: .safe,
                        note: "Installed dependencies. Restored by `npm install`."),
        ProjectArtifact(name: "dist", markers: [.file("package.json"), .file("pyproject.toml"), .file("setup.py")],
                        tag: .review,
                        note: "Bundled output. Regenerated by the next build — but some projects commit or serve dist/, so check first."),
        ProjectArtifact(name: ".next", markers: [.file("package.json")], tag: .safe,
                        note: "Next.js build cache and output."),
        ProjectArtifact(name: ".nuxt", markers: [.file("package.json")], tag: .safe,
                        note: "Nuxt build output."),
        ProjectArtifact(name: ".svelte-kit", markers: [.file("package.json")], tag: .safe,
                        note: "SvelteKit build output."),
        ProjectArtifact(name: ".angular", markers: [.file("package.json")], tag: .safe,
                        note: "Angular's build cache."),
        ProjectArtifact(name: ".turbo", markers: [.file("package.json")], tag: .safe,
                        note: "Turborepo task cache."),
        ProjectArtifact(name: ".parcel-cache", markers: [.file("package.json")], tag: .safe,
                        note: "Parcel's build cache."),
        ProjectArtifact(name: ".vite", markers: [.file("package.json")], tag: .safe,
                        note: "Vite's dependency pre-bundle cache."),

        // Python
        ProjectArtifact(name: ".venv",
                        markers: [.file("pyproject.toml"), .file("requirements.txt"), .file("setup.py"), .file("Pipfile")],
                        tag: .review,
                        note: "The project's virtualenv. Rebuilt by `pip install -r` or `uv sync`, but every dependency downloads again."),
        ProjectArtifact(name: "venv",
                        markers: [.file("pyproject.toml"), .file("requirements.txt"), .file("setup.py")],
                        tag: .review,
                        note: "The project's virtualenv. Rebuilt by re-installing its dependencies."),
        ProjectArtifact(name: ".tox", markers: [.file("tox.ini"), .file("pyproject.toml")], tag: .safe,
                        note: "tox's per-environment virtualenvs. Rebuilt on the next run."),
        ProjectArtifact(name: ".pytest_cache", markers: [.file("pyproject.toml"), .file("setup.py"), .file("pytest.ini"), .file("tox.ini")],
                        tag: .safe, note: "pytest's last-run cache."),
        ProjectArtifact(name: ".mypy_cache", markers: [.file("pyproject.toml"), .file("setup.py"), .file("mypy.ini")],
                        tag: .safe, note: "mypy's incremental type cache."),
        ProjectArtifact(name: ".ruff_cache", markers: [.file("pyproject.toml"), .file("ruff.toml")], tag: .safe,
                        note: "Ruff's lint cache."),

        // .NET
        ProjectArtifact(name: "bin", markers: [.ext("csproj"), .ext("fsproj"), .ext("vbproj"), .ext("sln")], tag: .safe,
                        note: ".NET build output. Rebuilt by `dotnet build`."),
        ProjectArtifact(name: "obj", markers: [.ext("csproj"), .ext("fsproj"), .ext("vbproj"), .ext("sln")], tag: .safe,
                        note: ".NET build intermediates."),

        // PHP / Go
        ProjectArtifact(name: "vendor", markers: [.file("composer.json"), .file("go.mod")], tag: .safe,
                        note: "Vendored dependencies. Restored by `composer install` or `go mod vendor`."),

        // Elixir / OCaml / Haskell / Elm
        ProjectArtifact(name: "_build", markers: [.file("mix.exs"), .file("dune-project")], tag: .safe,
                        note: "Build output. Rebuilt by the next compile."),
        ProjectArtifact(name: "deps", markers: [.file("mix.exs")], tag: .safe,
                        note: "Fetched Elixir dependencies. Restored by `mix deps.get`."),
        ProjectArtifact(name: ".stack-work", markers: [.file("stack.yaml")], tag: .safe,
                        note: "Stack's per-project build output."),
        ProjectArtifact(name: "elm-stuff", markers: [.file("elm.json")], tag: .safe,
                        note: "Elm's build artifacts."),

        // Native
        ProjectArtifact(name: "cmake-build-debug", markers: [.file("CMakeLists.txt")], tag: .safe,
                        note: "CLion's debug build directory."),
        ProjectArtifact(name: "cmake-build-release", markers: [.file("CMakeLists.txt")], tag: .safe,
                        note: "CLion's release build directory."),

        // Infra
        ProjectArtifact(name: ".terraform", markers: [.file("main.tf"), .file("terraform.tf")], tag: .safe,
                        note: "Downloaded providers and modules. Restored by `terraform init`."),

        // Game engines — Unity's is literally called Library, hence the strict AND.
        ProjectArtifact(name: "Library", markers: [.dir("Assets"), .dir("ProjectSettings")], requiresAll: true,
                        tag: .review,
                        note: "Unity's import cache. Rebuilt automatically on the next project open — but reimporting a large project takes a long time."),
        ProjectArtifact(name: "Intermediate", markers: [.ext("uproject")], tag: .safe,
                        note: "Unreal build intermediates."),
        ProjectArtifact(name: "Binaries", markers: [.ext("uproject")], tag: .safe,
                        note: "Compiled Unreal binaries. Rebuilt by the next build."),
        ProjectArtifact(name: "DerivedDataCache", markers: [.ext("uproject")], tag: .safe,
                        note: "Unreal's project-local derived data."),
    ]

    /// True when `parent` proves this artifact belongs to a real project of that kind.
    static func markerPresent(_ artifact: ProjectArtifact, in parent: URL) -> Bool {
        let fm = FileManager.default

        func hit(_ marker: ProjectArtifact.Marker) -> Bool {
            switch marker {
            case .file(let name):
                var isDir: ObjCBool = false
                let ok = fm.fileExists(atPath: parent.appendingPathComponent(name).path, isDirectory: &isDir)
                return ok && !isDir.boolValue
            case .dir(let name):
                var isDir: ObjCBool = false
                let ok = fm.fileExists(atPath: parent.appendingPathComponent(name).path, isDirectory: &isDir)
                return ok && isDir.boolValue
            case .ext(let ext):
                guard let names = try? fm.contentsOfDirectory(atPath: parent.path) else { return false }
                return names.contains { $0.hasSuffix("." + ext) }
            }
        }

        return artifact.requiresAll ? artifact.markers.allSatisfy(hit) : artifact.markers.contains(where: hit)
    }

    // MARK: - Active rules

    /// Rules whose path exists, plus the ones that can only be found at runtime.
    static func activeRules(for audience: Audience = .developer) -> [Rule] {
        let base = audience == .developer ? rules : everydayRules
        var found = base.filter { exists(SafetyGuard.home.appendingPathComponent($0.relPath)) }
        if audience == .developer { found.append(contentsOf: dynamicRules()) }

        // A rule that sits inside another rule would be counted twice. Keep the
        // more specific one and let the outer rule's expansion skip it (Scanner
        // does the skipping); this only drops exact duplicates.
        var seen = Set<String>()
        return found.filter { seen.insert($0.relPath).inserted }
    }

    /// Locations that depend on where a toolchain was installed, so they cannot be
    /// hard-coded. Each is verified to exist and to sit inside $HOME.
    private static func dynamicRules() -> [Rule] {
        var out: [Rule] = []
        if let flutter = flutterCacheRule() { out.append(flutter) }
        out.append(contentsOf: goRules())
        out.append(contentsOf: condaRules())
        return out
    }

    private static func exists(_ url: URL) -> Bool {
        var isDir: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) && isDir.boolValue
    }

    /// Turns an absolute path into a home-relative one, or nil if it is not in $HOME.
    private static func relativeToHome(_ path: String) -> String? {
        let home = SafetyGuard.home.path
        let std = URL(fileURLWithPath: path).standardizedFileURL.path
        guard std.hasPrefix(home + "/") else { return nil }
        let rel = String(std.dropFirst(home.count + 1))
        return rel.isEmpty ? nil : rel
    }

    // MARK: Flutter

    /// The Flutter SDK's own cache lives inside wherever the SDK was cloned, so it
    /// has to be located rather than hard-coded. Only reported if it sits in $HOME.
    private static func flutterCacheRule() -> Rule? {
        guard let sdk = locateFlutterSDK() else { return nil }
        let cache = sdk.appendingPathComponent("bin/cache")
        guard exists(cache), let rel = relativeToHome(cache.path) else { return nil }
        return Rule(
            group: "Flutter & Dart",
            title: "Flutter SDK cache (\(sdk.lastPathComponent))",
            relPath: rel,
            tag: .review,
            note: "Downloaded engine artifacts, the bundled Dart SDK and toolchain binaries for every platform you have built for. Restored by `flutter precache` / the next build, but it is a large download and `flutter` will not run until it finishes."
        )
    }

    private static func locateFlutterSDK() -> URL? {
        if !SandboxAccess.isSandboxed {
            let result = Shell.run("command -v flutter", timeout: 5)
            guard result.status == 0 else { return nil }
            let line = result.output.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty else { return nil }
            // .../flutter/bin/flutter  ->  .../flutter
            let bin = URL(fileURLWithPath: line).resolvingSymlinksInPath()
            return bin.deletingLastPathComponent().deletingLastPathComponent()
        }
        // Sandbox: no subprocess. Check where the SDK is usually cloned under $HOME.
        for guess in ["flutter", "development/flutter", "dev/flutter", "src/flutter",
                      "fvm/default", "sdk/flutter"] {
            let sdk = SafetyGuard.home.appendingPathComponent(guess)
            if exists(sdk.appendingPathComponent("bin/cache")) { return sdk }
        }
        return nil
    }

    // MARK: Go

    /// GOMODCACHE and GOCACHE move with GOPATH, so ask the toolchain rather than
    /// guessing. The module cache is deliberately *not* expanded: its files are
    /// read-only, and the individual module directories cannot be moved out from
    /// under their read-only parents. The whole cache moves fine.
    private static func goRules() -> [Rule] {
        let modCache: String
        let buildCache: String

        if !SandboxAccess.isSandboxed {
            let result = Shell.run("go env GOMODCACHE GOCACHE", timeout: 8)
            guard result.status == 0 else { return [] }
            let lines = result.output
                .split(separator: "\n")
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
            guard lines.count >= 1 else { return [] }
            modCache = lines[0]
            buildCache = lines.count >= 2 ? lines[1] : ""
        } else {
            // Sandbox: no subprocess. Fall back to Go's documented defaults, which
            // hold unless the user overrode GOPATH/GOCACHE. Each is checked to exist.
            modCache = SafetyGuard.home.appendingPathComponent("go/pkg/mod").path
            buildCache = SafetyGuard.home.appendingPathComponent("Library/Caches/go-build").path
        }

        var out: [Rule] = []

        if let rel = relativeToHome(modCache), exists(SafetyGuard.home.appendingPathComponent(rel)) {
            out.append(Rule(
                group: "Go",
                title: "Go module cache",
                relPath: rel,
                tag: .safe,
                note: "Every Go module you have ever downloaded. `go mod download` re-fetches what your builds need. Equivalent to `go clean -modcache`."
            ))
        }

        if !buildCache.isEmpty, let rel = relativeToHome(buildCache),
           exists(SafetyGuard.home.appendingPathComponent(rel)),
           !rules.contains(where: { $0.relPath == rel }) {
            out.append(Rule(
                group: "Go",
                title: "Go build cache",
                relPath: rel,
                tag: .safe,
                note: "Compiled package objects. Equivalent to `go clean -cache`."
            ))
        }

        return out
    }

    // MARK: Conda

    /// Conda installs itself wherever you pointed the installer. The package cache
    /// inside it is disposable (`conda clean --packages`); the environments are not.
    private static func condaRules() -> [Rule] {
        let candidates = ["miniconda3", "anaconda3", "miniforge3", "mambaforge",
                          "opt/miniconda3", "opt/anaconda3"]
        var out: [Rule] = []

        for base in candidates {
            let root = SafetyGuard.home.appendingPathComponent(base)
            guard exists(root) else { continue }

            let pkgs = root.appendingPathComponent("pkgs")
            if exists(pkgs), let rel = relativeToHome(pkgs.path) {
                out.append(Rule(
                    group: "Python",
                    title: "Conda package cache (\(root.lastPathComponent))",
                    relPath: rel,
                    tag: .safe,
                    note: "Downloaded and unpacked conda packages. Equivalent to `conda clean --packages`. Environments keep working; the packages re-download only if you build a new environment."
                ))
            }

            let envs = root.appendingPathComponent("envs")
            if exists(envs), let rel = relativeToHome(envs.path) {
                out.append(Rule(
                    group: "Python",
                    title: "Conda environments (\(root.lastPathComponent))",
                    relPath: rel,
                    tag: .review,
                    note: "One full environment per project. Rebuildable from an environment.yml if you have one — otherwise the exact package set is gone.",
                    expand: true
                ))
            }
        }

        return out
    }
}
