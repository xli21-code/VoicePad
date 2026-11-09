import Foundation

/// Saves each dictation as a 16 kHz mono 16-bit WAV under ~/.voicepad/audio/.
///
/// Purpose: make past utterances replayable so ASR engines can be benchmarked on the
/// user's real speech (Chinese with embedded English terms) instead of guesswork.
/// Local-only, no network. Disable with:
///   defaults write com.voicepad.app archiveAudio -bool false
enum AudioArchive {
    static var isEnabled: Bool {
        UserDefaults.standard.object(forKey: "archiveAudio") == nil
            ? true
            : UserDefaults.standard.bool(forKey: "archiveAudio")
    }

    private static var directory: String { ConfigDirectory.path + "/audio" }

    /// Writes the samples and returns the file name (not the full path), or nil on failure.
    /// Best effort: never throws, never blocks the paste flow.
    static func save(samples: [Float], startedAt: Date = Date()) -> String? {
        guard isEnabled, !samples.isEmpty else { return nil }

        try? FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)

        let stamp = ISO8601DateFormatter().string(from: startedAt)
            .replacingOccurrences(of: ":", with: "")
            .replacingOccurrences(of: "-", with: "")
        let name = "\(stamp)-\(String(UUID().uuidString.prefix(6))).wav"
        let path = directory + "/" + name
        guard let data = wav(samples: samples, sampleRate: 16000) else { return nil }
        guard FileManager.default.createFile(atPath: path, contents: data) else {
            vpLog("[AudioArchive] write failed: \(path)")
            return nil
        }
        return name
    }

    private static func wav(samples: [Float], sampleRate: Int) -> Data? {
        var data = Data(capacity: 44 + samples.count * 2)
        let dataBytes = UInt32(samples.count * 2)

        func le32(_ v: UInt32) -> Data { withUnsafeBytes(of: v.littleEndian) { Data($0) } }
        func le16(_ v: UInt16) -> Data { withUnsafeBytes(of: v.littleEndian) { Data($0) } }

        data.append("RIFF".data(using: .ascii)!)
        data.append(le32(36 + dataBytes))
        data.append("WAVEfmt ".data(using: .ascii)!)
        data.append(le32(16))                                  // fmt chunk size
        data.append(le16(1))                                   // PCM
        data.append(le16(1))                                   // mono
        data.append(le32(UInt32(sampleRate)))
        data.append(le32(UInt32(sampleRate * 2)))              // byte rate
        data.append(le16(2))                                   // block align
        data.append(le16(16))                                  // bits per sample
        data.append("data".data(using: .ascii)!)
        data.append(le32(dataBytes))

        for s in samples {
            let clamped = max(-1.0, min(1.0, s))
            data.append(le16(UInt16(bitPattern: Int16(clamped * 32767))))
        }
        return data
    }
}
