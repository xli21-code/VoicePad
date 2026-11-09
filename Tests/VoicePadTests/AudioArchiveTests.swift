import Foundation
import Testing

@testable import VoicePad

@Suite("AudioArchive")
struct AudioArchiveTests {
    @Test("Writes a 16 kHz mono 16-bit WAV and returns its file name")
    func writesWav() throws {
        // 0.1s of a 440 Hz tone
        let samples = (0..<1600).map { sin(2 * .pi * 440 * Float($0) / 16000) * 0.5 }
        let name = try #require(AudioArchive.save(samples: samples))
        let path = ConfigDirectory.path + "/audio/" + name
        defer { try? FileManager.default.removeItem(atPath: path) }

        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        #expect(data.count == 44 + samples.count * 2)

        func str(_ range: Range<Int>) -> String {
            String(data: data.subdata(in: range), encoding: .ascii) ?? ""
        }
        func u32(_ offset: Int) -> UInt32 {
            data.subdata(in: offset..<offset + 4).withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }
        }
        func u16(_ offset: Int) -> UInt16 {
            data.subdata(in: offset..<offset + 2).withUnsafeBytes { $0.loadUnaligned(as: UInt16.self) }
        }

        #expect(str(0..<4) == "RIFF")
        #expect(str(8..<12) == "WAVE")
        #expect(str(12..<16) == "fmt ")
        #expect(u32(16) == 16)                       // PCM chunk size
        #expect(u16(20) == 1)                       // format = PCM
        #expect(u16(22) == 1)                       // mono
        #expect(u32(24) == 16000)                   // sample rate
        #expect(u32(28) == 32000)                   // byte rate
        #expect(u16(32) == 2)                       // block align
        #expect(u16(34) == 16)                      // bits per sample
        #expect(str(36..<40) == "data")
        #expect(u32(40) == UInt32(samples.count * 2))
    }
}
