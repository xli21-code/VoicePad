import Foundation

/// Ensures ~/.voicepad/ directory exists at app launch.
/// All config files (dictionary.txt, corrections.txt, app-branches.json, config.json) live here.
enum ConfigDirectory {
    static let path = NSHomeDirectory() + "/.voicepad"

    /// Create ~/.voicepad/ if it doesn't exist. Call once at app launch.
    static func ensureExists() {
        let fm = FileManager.default
        if !fm.fileExists(atPath: path) {
            try? fm.createDirectory(atPath: path, withIntermediateDirectories: true)
            vpLog("[ConfigDirectory] Created \(path)")
        }
    }
}
