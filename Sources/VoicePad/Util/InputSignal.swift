import Foundation

/// Measures a take before it is sent to the speech model.
///
/// A silent take is not a rare accident: when the microphone route dies (a virtual
/// loopback device with nothing feeding it, a device that was unplugged) the recorder
/// still produces a full buffer of digital zeros. Whisper turns that into a short
/// hallucination — `'그.'` with `lang=<|ko|>` was the observed one — the polisher then
/// answers "（无有效内容）", and that answer was pasted into the user's document.
///
/// The floor below comes from 241 archived takes: 226 with real transcripts have a peak
/// of at least 0.0179, while every take that produced no speech has a peak of exactly 0.
/// 0.005 sits between them with a 3.5× margin on the quietest real dictation, so a soft
/// speaker still passes and a dead route cannot.
struct InputSignal: Equatable {
    /// Largest absolute sample, 0...1.
    let peak: Float
    /// Root mean square of the whole window.
    let rms: Float
    /// Share of 20 ms frames loud enough to be voice rather than the noise floor.
    let voicedRatio: Float

    static let peakFloor: Float = 0.005
    private static let frameLength = 320 // 20 ms at 16 kHz
    private static let voiceFloor: Float = 0.01

    /// True when the take carries no signal worth transcribing.
    var isSilent: Bool {
        peak < Self.peakFloor
    }

    static func analyze(_ samples: [Float]) -> InputSignal {
        guard !samples.isEmpty else {
            return InputSignal(peak: 0, rms: 0, voicedRatio: 0)
        }

        var peak: Float = 0
        var sumOfSquares: Float = 0
        for sample in samples {
            let magnitude = abs(sample)
            if magnitude > peak { peak = magnitude }
            sumOfSquares += sample * sample
        }

        var frames = 0
        var voiced = 0
        var index = 0
        while index + frameLength <= samples.count {
            var frameEnergy: Float = 0
            for offset in index..<(index + frameLength) {
                frameEnergy += samples[offset] * samples[offset]
            }
            if (frameEnergy / Float(frameLength)).squareRoot() >= voiceFloor {
                voiced += 1
            }
            frames += 1
            index += frameLength
        }

        return InputSignal(
            peak: peak,
            rms: (sumOfSquares / Float(samples.count)).squareRoot(),
            voicedRatio: frames == 0 ? 0 : Float(voiced) / Float(frames)
        )
    }
}
