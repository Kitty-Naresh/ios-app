import Foundation

/// Which speech engine the conversation listens through. Chosen in the menu, so the engines can be compared on the phone.
nonisolated enum SpeechEngineChoice: String, CaseIterable, Identifiable, Sendable {
    case whisperTurbo      // Apple Speech shows live text, large-v3-turbo settles each phrase
    case whisper           // small.en alone (a development option: the model is not bundled)
    case apple

    var id: String { rawValue }

    static let key = "kitty.speechEngine"
    /// The older on/off switch for Moonshine (now removed), read once so nobody who turned it off is moved onto Whisper.
    static let legacyMoonshineKey = "kitty.useMoonshine"
    /// The stored value Moonshine had before it was removed.
    private static let removedMoonshine = "moonshine"

    var label: String {
        switch self {
        case .whisperTurbo: return "Whisper Turbo (accurate)"
        case .whisper: return "Whisper (quick, live model only)"
        case .apple: return "Apple Speech"
        }
    }

    /// The model is in the app. Apple Speech always is.
    var isAvailable: Bool {
        switch self {
        case .whisperTurbo: return WhisperModel.isAccurateAvailable
        case .whisper: return WhisperModel.isAvailable
        case .apple: return true
        }
    }

    /// What the menu offers: turbo and Apple Speech always, the quick Whisper only if its model was put in the app.
    static var menuChoices: [SpeechEngineChoice] {
        allCases.filter { $0 != .whisper || $0.isAvailable }
    }

    /// What was picked: the stored choice, else the old Moonshine switch (off means Apple Speech), else Whisper Turbo.
    static func stored(in defaults: UserDefaults = .standard) -> SpeechEngineChoice {
        if let raw = defaults.string(forKey: key) {
            if let choice = SpeechEngineChoice(rawValue: raw) { return choice }
            if raw == removedMoonshine { return .whisperTurbo }
        }
        if let legacy = defaults.object(forKey: legacyMoonshineKey) as? Bool, !legacy { return .apple }
        return .whisperTurbo
    }

    static func store(_ choice: SpeechEngineChoice, in defaults: UserDefaults = .standard) {
        defaults.set(choice.rawValue, forKey: key)
    }

    /// What will really be used: the pick, or the next best whose model is in the app. Turbo falls back to the quick Whisper
    /// if its model happens to be there, and then to Apple Speech; the quick Whisper falls back to Apple Speech.
    static func effective(in defaults: UserDefaults = .standard, available: (SpeechEngineChoice) -> Bool = { $0.isAvailable }) -> SpeechEngineChoice {
        let picked = stored(in: defaults)
        if available(picked) { return picked }
        if picked == .whisperTurbo && available(.whisper) { return .whisper }
        return .apple
    }
}
