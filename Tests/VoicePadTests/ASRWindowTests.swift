import Foundation
import Testing

@testable import VoicePad

/// The windows must tile the recording exactly. A gap or a silently dropped window is how a
/// long dictation used to lose everything after the first 30 s.
@Suite("ASR windowing")
struct ASRWindowTests {
    private func samples(seconds: Double, amplitude: Float = 0.1) -> [Float] {
        Array(repeating: amplitude, count: Int(seconds * 16000))
    }

    @Test func shortAudioIsOneWindow() {
        let audio = samples(seconds: 12)
        #expect(WhisperKitEngine.windows(of: audio) == [0..<audio.count])
    }

    @Test func emptyAudioYieldsNoWindows() {
        #expect(WhisperKitEngine.windows(of: []).isEmpty)
    }

    @Test func windowsTileTheAudioWithNoGaps() {
        let audio = samples(seconds: 48.8)
        let windows = WhisperKitEngine.windows(of: audio)
        #expect(windows.count == 2)
        #expect(windows.first?.lowerBound == 0)
        #expect(windows.last?.upperBound == audio.count)
        for (left, right) in zip(windows, windows.dropFirst()) {
            #expect(left.upperBound == right.lowerBound)
        }
    }

    @Test func noWindowExceedsOneWhisperWindow() {
        // A window longer than 30 s is truncated by the encoder and decodes to nothing.
        for seconds in [30.1, 31.0, 42.2, 48.8, 75.0, 130.0] {
            let audio = samples(seconds: seconds)
            for window in WhisperKitEngine.windows(of: audio) {
                #expect(!window.isEmpty)
                #expect(window.count <= WhisperKitEngine.windowSamples)
            }
        }
    }

    @Test func cutLandsOnTheQuietestPointBeforeTheBoundary() {
        var audio = samples(seconds: 40)
        let quiet = Int(28.0 * 16000)..<Int(28.2 * 16000)
        for index in quiet { audio[index] = 0 }

        let windows = WhisperKitEngine.windows(of: audio)
        let cut = windows[0].upperBound
        // Within the silent patch, give or take one 20 ms hop.
        #expect(cut >= quiet.lowerBound && cut <= quiet.upperBound + 320)
    }
}
