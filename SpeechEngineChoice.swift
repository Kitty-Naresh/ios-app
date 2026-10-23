import Foundation

/// Which speech engine the conversation listens through. Chosen in the menu, so the three can be compared on the phone.
nonisolated enum SpeechEngineChoice: String, CaseIterable, Identifiable, Sendable {
    case whisperTurbo      // small.en shows live text, large-v3-turbo settles each phrase
    case whisper           // small.en alone
    case moonshine
    case apple

    var id: String { rawValue }

    static let key = "kitty.speechEngine"
    /// The older on/off switch for Moonshine, read once to carry the choice over.
    static let legacyMoonshineKey = "kitty.useMoonshine"

    var label: String {
        switch self {
        case .whisperTurbo: return "Whisper Turbo (accurate)"
        case .whisper: return "Whisper (quick, live model only)"
        case .moonshine: return "Moonshine"
        case .apple: return "Apple Speech"
        }
    }

    /// The model is in the app. Apple Speech always is.
    var isAvailable: Bool {
        switch self {
        case .whisperTurbo: return WhisperModel.isAvailable && WhisperModel.isAccurateAvailable
        case .whisper: return WhisperModel.isAvailable
        case .moonshine: return MoonshineModel.isAvailable
        case .apple: return true
        }
    }

    /// What was picked: the stored choice, else the old Moonshine switch, else Whisper Turbo (the default until you pick another).
    static func stored(in defaults: UserDefaults = .standard) -> SpeechEngineChoice {
        if let raw = defaults.string(forKey: key), let choice = SpeechEngineChoice(rawValue: raw) { return choice }
        if let legacy = defaults.object(forKey: legacyMoonshineKey) as? Bool { return legacy ? .moonshine : .apple }
        return .whisperTurbo
    }

    static func store(_ choice: SpeechEngineChoice, in defaults: UserDefaults = .standard) {
        defaults.set(choice.rawValue, forKey: key)
    }

    /// What will really be used: the pick, or the next best whose model is in the app. Turbo falls back to the quick Whisper (the
    /// live model alone), and then Apple Speech; Moonshine and Whisper fall back to Apple Speech.
    static func effective(in defaults: UserDefaults = .standard, available: (SpeechEngineChoice) -> Bool = { $0.isAvailable }) -> SpeechEngineChoice {
        let picked = stored(in: defaults)
        if available(picked) { return picked }
        if picked == .whisperTurbo && available(.whisper) { return .whisper }
        return .apple
    }
}
