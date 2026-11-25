import Foundation
import AppKit

/// The language DevSweep runs in. macOS normally takes this from System
/// Settings ▸ General ▸ Language & Region, where every app can be given its own
/// language; this is the same switch inside the app, for people who never find
/// that panel. It writes the standard `AppleLanguages` override and relaunches,
/// which is the only way a Foundation process changes language — strings are
/// resolved against the bundle's preferred localizations at launch.
///
/// Nothing is lost by the relaunch: the last scan is remembered on disk and the
/// window reopens on it; the app delegate finishes any move in flight first.
enum AppLanguage: String, CaseIterable, Identifiable {
    /// Follow the system (or the per-app choice in System Settings).
    case system = ""
    case english = "en"
    case german = "de"
    case japanese = "ja"
    case french = "fr"
    case spanish = "es"

    var id: String { rawValue }

    /// Shown in the menu. Each language is named in itself — "Deutsch", not
    /// "German" — the convention for language switchers, so it is never
    /// translated. Only the "follow the system" entry is.
    var menuTitle: String {
        switch self {
        case .system: return String(localized: "System Language", comment: "Language menu: follow the Mac's language setting instead of a fixed one.")
        case .english: return "English"
        case .german: return "Deutsch"
        case .japanese: return "日本語"
        case .french: return "Français"
        case .spanish: return "Español"
        }
    }

    private static let appleKey = "AppleLanguages"
    /// Our own record of the choice. `AppleLanguages` alone cannot tell "the
    /// user picked English here" from "the system is English".
    private static let ownKey = "devsweep.language"

    /// The choice made in this app, or `.system` when none was made.
    static var current: AppLanguage {
        AppLanguage(rawValue: UserDefaults.standard.string(forKey: ownKey) ?? "") ?? .system
    }

    /// Records the choice. Takes effect at the next launch; see `relaunch()`.
    static func apply(_ language: AppLanguage) {
        let defaults = UserDefaults.standard
        if language == .system {
            defaults.removeObject(forKey: ownKey)
            defaults.removeObject(forKey: appleKey)
        } else {
            defaults.set(language.rawValue, forKey: ownKey)
            defaults.set([language.rawValue], forKey: appleKey)
        }
        // The new process reads the defaults before this one has necessarily
        // flushed them; make sure they are on disk first.
        defaults.synchronize()
    }

    /// Starts a fresh copy of the app and quits this one once it is running.
    /// Works under the App Sandbox: the launch goes through LaunchServices, not
    /// a child process. The quit honours the delegate's wait for a move in flight.
    @MainActor
    static func relaunch() {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.createsNewApplicationInstance = true
        configuration.activates = true
        NSWorkspace.shared.openApplication(at: Bundle.main.bundleURL, configuration: configuration) { _, _ in
            DispatchQueue.main.async { NSApp.terminate(nil) }
        }
    }
}

// MARK: - UI

import SwiftUI

/// Shared between the menu bar and the Tools menu: the language the user just
/// picked, waiting for the relaunch confirmation in `ContentView`.
@MainActor
final class LanguageSwitch: ObservableObject {
    static let shared = LanguageSwitch()
    @Published var pending: AppLanguage?
}

/// The "Language" submenu. Selecting an entry asks before relaunching, so the
/// picker never shows a choice that has not taken effect yet.
struct LanguageMenu: View {
    /// `true` lists the languages directly inside the enclosing menu (the
    /// header's Language button); `false` nests them under a "Language" item
    /// (the View menu).
    var inline = false

    @ObservedObject private var languageSwitch = LanguageSwitch.shared

    var body: some View {
        if inline {
            picker.pickerStyle(.inline).labelsHidden()
        } else {
            picker.pickerStyle(.menu)
        }
    }

    private var picker: some View {
        Picker(selection: Binding(
            get: { AppLanguage.current },
            set: { chosen in if chosen != AppLanguage.current { languageSwitch.pending = chosen } }
        )) {
            ForEach(AppLanguage.allCases) { language in
                // Language names are endonyms — already in their own language.
                Text(verbatim: language.menuTitle).tag(language)
            }
        } label: {
            Text("Language", comment: "Submenu with the app's language choices; also the header button.")
        }
    }
}
