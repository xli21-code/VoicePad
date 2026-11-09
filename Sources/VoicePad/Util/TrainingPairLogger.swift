import Foundation

/// Appends one raw/polished transcription pair per utterance to ~/.voicepad/pairs.jsonl.
///
/// Purpose: accumulate (raw ASR, LLM-polished, target app, duration) tuples for a future
/// personal voice-correction model. This is local-only telemetry:
/// - append-only JSONL, no network calls
/// - creates ~/.voicepad/ if missing
/// - any failure is caught and logged, never thrown — must not affect the transcribe/paste flow
///
/// Known limitation (intentionally not solved here): whatever the user edits *after* the
/// text lands in the target app is invisible to us. Only raw_asr and polished are captured.
enum TrainingPairLogger {
    private static let path = ConfigDirectory.path + "/pairs.jsonl"

    private struct Pair: Encodable {
        let ts: String
        let raw_asr: String
        let polished: String?
        let target_app: String?
        let audio_duration_s: Double
        let audio_file: String?
        let asr_engine: String?
    }

    /// Best-effort append of one pair. Never throws, never blocks on network (there is none).
    static func log(rawASR: String, polished: String?, targetApp: String?, audioDurationS: Double, audioFile: String? = nil, asrEngine: String? = nil) {
        let pair = Pair(
            ts: ISO8601DateFormatter().string(from: Date()),
            raw_asr: rawASR,
            polished: polished,
            target_app: targetApp,
            audio_duration_s: audioDurationS,
            audio_file: audioFile,
            asr_engine: asrEngine
        )

        do {
            ConfigDirectory.ensureExists()
            var data = try JSONEncoder().encode(pair)
            data.append(0x0A) // newline — keep it JSON Lines

            if let handle = FileHandle(forWritingAtPath: path) {
                defer { handle.closeFile() }
                handle.seekToEndOfFile()
                handle.write(data)
            } else {
                guard FileManager.default.createFile(atPath: path, contents: data) else {
                    throw CocoaError(.fileWriteUnknown)
                }
            }
        } catch {
            // Silent to the caller by design — a training-data write must never
            // slow down or break live transcription/paste.
            vpLog("[TrainingPairLogger] failed to append pair: \(error)")
        }
    }
}
