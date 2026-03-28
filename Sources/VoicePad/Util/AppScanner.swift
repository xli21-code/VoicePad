import AppKit
import Foundation

/// Information about an installed macOS application.
struct AppInfo: Identifiable, Hashable {
    let bundleID: String
    let name: String
    let icon: NSImage
    let path: String

    var id: String { bundleID }

    func hash(into hasher: inout Hasher) {
        hasher.combine(bundleID)
    }

    static func == (lhs: AppInfo, rhs: AppInfo) -> Bool {
        lhs.bundleID == rhs.bundleID
    }
}

/// Scans /Applications and ~/Applications for installed apps.
struct AppScanner {
    /// Scan for installed applications. Returns apps sorted by name.
    /// Deduplicates by bundle ID.
    func scanInstalledApps() -> [AppInfo] {
        var seen = Set<String>()
        var results: [AppInfo] = []

        let dirs = [
            "/Applications",
            NSHomeDirectory() + "/Applications",
        ]

        for dir in dirs {
            guard let contents = try? FileManager.default.contentsOfDirectory(atPath: dir) else {
                continue
            }
            for item in contents where item.hasSuffix(".app") {
                let appPath = dir + "/" + item
                guard let bundle = Bundle(path: appPath),
                      let bundleID = bundle.bundleIdentifier else { continue }

                guard !seen.contains(bundleID) else { continue }
                seen.insert(bundleID)

                let name = bundle.infoDictionary?["CFBundleName"] as? String
                    ?? bundle.infoDictionary?["CFBundleDisplayName"] as? String
                    ?? (item as NSString).deletingPathExtension

                let icon = NSWorkspace.shared.icon(forFile: appPath)
                results.append(AppInfo(bundleID: bundleID, name: name, icon: icon, path: appPath))
            }
        }

        // Also include currently running apps not found in /Applications
        for app in NSWorkspace.shared.runningApplications {
            guard let bundleID = app.bundleIdentifier,
                  !seen.contains(bundleID),
                  let url = app.bundleURL else { continue }
            seen.insert(bundleID)

            let name = app.localizedName ?? bundleID
            let icon = app.icon ?? NSImage(systemSymbolName: "app", accessibilityDescription: nil) ?? NSImage()
            results.append(AppInfo(bundleID: bundleID, name: name, icon: icon, path: url.path))
        }

        return results.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }
}
