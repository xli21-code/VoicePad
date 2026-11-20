import Foundation

/// Compares the microphone the app asked for with the one the audio unit ended up bound
/// to, because `kAudioOutputUnitProperty_CurrentDevice` can fail or be overridden while the
/// engine starts. The app used to trust its own configuration, so the menu said
/// "BlackHole 2ch" while the take came from whatever device the unit kept.
enum InputBinding {
    /// `intended` is nil for "automatic", which accepts whatever the system picks.
    static func matches(intended: String?, actual: String?) -> Bool {
        guard let intended else { return actual != nil }
        return intended == actual
    }

    /// Menu label for the binding, or nil when nothing is bound yet.
    ///
    /// When the requested device is not the one in use, both names are shown — silently
    /// recording from another device is what this type exists to make impossible.
    static func menuLabel(
        intended: String?,
        intendedName: String?,
        actual: String?,
        actualName: String?
    ) -> String? {
        guard let actual else { return nil }
        let actualLabel = actualName ?? actual
        guard let intended, intended != actual else { return actualLabel }
        return "\(actualLabel) (requested \(intendedName ?? intended))"
    }
}
