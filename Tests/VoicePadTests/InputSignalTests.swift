import Foundation
import Testing

@testable import VoicePad

@Suite("InputSignal")
struct InputSignalTests {

    /// A dead microphone route (loopback device with nothing feeding it, unplugged
    /// device) delivers digital zeros, not noise.
    @Test("Digital silence is rejected")
    func digitalSilence() {
        let signal = InputSignal.analyze([Float](repeating: 0, count: 16_000))
        #expect(signal.peak == 0)
        #expect(signal.isSilent)
    }

    @Test("Empty take is rejected instead of crashing")
    func emptyTake() {
        let signal = InputSignal.analyze([])
        #expect(signal.voicedRatio == 0)
        #expect(signal.isSilent)
    }

    /// The noise floor of a real device sits far below the quietest archived dictation.
    @Test("Device noise floor stays below the gate")
    func noiseFloor() {
        var generator = SystemRandomNumberGenerator()
        let noise = (0..<16_000).map { _ in Float.random(in: -0.0002...0.0002, using: &generator) }
        #expect(InputSignal.analyze(noise).isSilent)
    }

    /// The quietest of 226 archived dictations peaked at 0.0179, so this is the floor
    /// the gate must keep passing (with margin).
    @Test("Quiet real speech passes")
    func quietSpeech() {
        let samples = (0..<16_000).map { index in
            Float(sin(Double(index) * 2 * .pi * 180 / 16_000)) * 0.019
        }
        let signal = InputSignal.analyze(samples)
        #expect(signal.peak > InputSignal.peakFloor)
        #expect(!signal.isSilent)
        #expect(signal.voicedRatio > 0.9)
    }

    @Test("Normal speech reports its level")
    func normalSpeech() {
        let samples = (0..<16_000).map { index in
            Float(sin(Double(index) * 2 * .pi * 220 / 16_000)) * 0.15
        }
        let signal = InputSignal.analyze(samples)
        #expect(signal.peak > 0.14)
        #expect(signal.voicedRatio > 0.9)
    }

    /// The gate is deliberately peak-only: the quietest archived dictation had no
    /// frame above the voice floor at all, so gating on `voicedRatio` would have
    /// thrown away real speech. A click therefore passes the gate and is caught by
    /// the existing "transcript has no letters" check instead.
    @Test("A single click is loud but barely voiced")
    func singleClick() {
        var samples = [Float](repeating: 0, count: 16_000)
        samples[8_000] = 0.9
        let signal = InputSignal.analyze(samples)
        #expect(signal.peak > InputSignal.peakFloor)
        #expect(!signal.isSilent)
        #expect(signal.voicedRatio < 0.05)
    }
}
