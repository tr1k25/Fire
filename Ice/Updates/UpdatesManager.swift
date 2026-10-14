//
//  UpdatesManager.swift
//  Fire
//

import SwiftUI

/// Manager for app updates.
///
/// Fire does not ship an updater framework. Instead, it looks at the latest GitHub release
/// and offers to open its download page when a newer version exists.
@MainActor
final class UpdatesManager: NSObject, ObservableObject {
    private static let latestReleaseAPI = URL(string: "https://api.github.com/repos/tr1k25/Fire/releases/latest")!
    private static let releasesPage = URL(string: "https://github.com/tr1k25/Fire/releases/latest")!

    /// A Boolean value that indicates whether the user can check for updates.
    @Published var canCheckForUpdates = true

    /// The date of the last update check.
    @Published var lastUpdateCheckDate: Date?

    /// The shared app state.
    private(set) weak var appState: AppState?

    /// A Boolean value that indicates whether to automatically check for updates.
    var automaticallyChecksForUpdates: Bool {
        get {
            UserDefaults.standard.object(forKey: "FireAutomaticallyChecksForUpdates") as? Bool ?? false
        }
        set {
            objectWillChange.send()
            UserDefaults.standard.set(newValue, forKey: "FireAutomaticallyChecksForUpdates")
        }
    }

    /// Creates an updates manager with the given app state.
    init(appState: AppState) {
        self.appState = appState
        super.init()
    }

    /// Sets up the manager.
    func performSetup() {
        lastUpdateCheckDate = UserDefaults.standard.object(forKey: "FireLastUpdateCheckDate") as? Date
        if automaticallyChecksForUpdates {
            Task { await check(userInitiated: false) }
        }
    }

    /// Checks for app updates.
    @objc func checkForUpdates() {
        Task { await check(userInitiated: true) }
    }

    private func check(userInitiated: Bool) async {
        do {
            var request = URLRequest(url: Self.latestReleaseAPI)
            request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
            request.timeoutInterval = 15
            let (data, _) = try await URLSession.shared.data(for: request)
            guard
                let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                let tag = json["tag_name"] as? String
            else {
                throw URLError(.cannotParseResponse)
            }
            let now = Date.now
            lastUpdateCheckDate = now
            UserDefaults.standard.set(now, forKey: "FireLastUpdateCheckDate")

            let latest = tag.trimmingCharacters(in: CharacterSet(charactersIn: "vV"))
            let isNewer = latest.compare(Constants.versionString, options: .numeric) == .orderedDescending
            if isNewer {
                let alert = NSAlert()
                alert.messageText = "Fire \(latest) is available"
                alert.informativeText = "You are using version \(Constants.versionString)."
                alert.addButton(withTitle: "Open Download Page")
                alert.addButton(withTitle: "Later")
                appState?.activate(withPolicy: .regular)
                if alert.runModal() == .alertFirstButtonReturn {
                    NSWorkspace.shared.open(Self.releasesPage)
                }
            } else if userInitiated {
                let alert = NSAlert()
                alert.messageText = "Fire is up to date"
                alert.informativeText = "Version \(Constants.versionString) is the latest version."
                appState?.activate(withPolicy: .regular)
                alert.runModal()
            }
        } catch {
            if userInitiated {
                let alert = NSAlert()
                alert.messageText = "Could not check for updates"
                alert.informativeText = error.localizedDescription
                appState?.activate(withPolicy: .regular)
                alert.runModal()
            }
        }
    }
}

// MARK: UpdatesManager: BindingExposable
extension UpdatesManager: BindingExposable { }
