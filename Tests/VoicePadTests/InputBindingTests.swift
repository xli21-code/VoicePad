import Foundation
import Testing

@testable import VoicePad

@Suite("InputBinding")
struct InputBindingTests {

    @Test("Automatic accepts whatever the system bound")
    func automaticAcceptsAnything() {
        #expect(InputBinding.matches(intended: nil, actual: "BlackHole2ch_UID"))
        #expect(!InputBinding.matches(intended: nil, actual: nil))
    }

    @Test("A requested device must be the one in use")
    func requestedDeviceMustMatch() {
        #expect(InputBinding.matches(intended: "BlackHole2ch_UID", actual: "BlackHole2ch_UID"))
        #expect(!InputBinding.matches(intended: "BlackHole2ch_UID", actual: "WXMH mini"))
        #expect(!InputBinding.matches(intended: "BlackHole2ch_UID", actual: nil))
    }

    @Test("Menu label names the device in use")
    func labelShowsActual() {
        #expect(
            InputBinding.menuLabel(
                intended: nil,
                intendedName: nil,
                actual: "BlackHole2ch_UID",
                actualName: "BlackHole 2ch"
            ) == "BlackHole 2ch"
        )
        #expect(
            InputBinding.menuLabel(
                intended: "BlackHole2ch_UID",
                intendedName: "BlackHole 2ch",
                actual: "BlackHole2ch_UID",
                actualName: "BlackHole 2ch"
            ) == "BlackHole 2ch"
        )
    }

    /// The whole point: a silent fallback must be visible in the menu.
    @Test("Menu label exposes a fallback")
    func labelShowsMismatch() {
        #expect(
            InputBinding.menuLabel(
                intended: "BlackHole2ch_UID",
                intendedName: "BlackHole 2ch",
                actual: "WXMH mini UID",
                actualName: "WXMH mini"
            ) == "WXMH mini (requested BlackHole 2ch)"
        )
    }

    @Test("Nothing bound yields no label")
    func unbonded() {
        #expect(InputBinding.menuLabel(intended: "x", intendedName: "X", actual: nil, actualName: nil) == nil)
    }
}
