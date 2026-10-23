import Foundation
import AVFoundation

/// Apple Speech shows the words live, and the accurate model (Whisper large-v3-turbo) settles each phrase when you pause: its text
/// replaces the words Apple heard for that phrase. Kitty acts on the settled text.
///
/// Apple Speech does all the audio work it always did (permissions, the audio session, restarts, the hands-free "stop"). The same
/// microphone buffers are also handed, through `audioMirror`, to a `TurboSettler`, which finds the pauses with a cheap energy
/// detector and runs the accurate model once per phrase on a queue of its own. If the accurate model is not loaded yet, or fails, Apple
/// Speech's words for that phrase stand, so nothing ever waits for it.
@MainActor
final class HybridRecognizer: TurnRecognizer {
    private(set) var transcript = ""
    private(set) var words: [SpokenWord] = []
    var onPartial: ((String) -> Void)?
    var onFinished: ((String) -> Void)?

    var isRecording: Bool { apple.isRecording }
    var errorMessage: String? {
        get { apple.errorMessage }
        set { apple.errorMessage = newValue }
    }
    var failureIsPermanent: Bool { apple.failureIsPermanent }
    var continuous: Bool {
        get { apple.continuous }
        set { apple.continuous = newValue }
    }
    var bargeIn: Bool {
        get { apple.bargeIn }
        set { apple.bargeIn = newValue }
    }
    var vocabulary: (@MainActor () -> [String])? {
        get { apple.vocabulary }
        set { apple.vocabulary = newValue }
    }

    let apple: SpeechRecognizer
    private let accurate: WhisperAccurate
    private let queue = DispatchQueue(label: "kitty.hybrid", qos: .userInitiated)
    private var sink: AudioHopSink?
    private var settler: TurboSettler?
    private var stats = PassStats(label: "whisper-turbo")
    private let generationBox = GenerationBox()
    private var phrases: [SettledPhrase] = []
    private var origin = 0.0                      // the audio clock when Apple's current recognition began
    private var delivered = false
    private var protectedNames: [String] = []     // the household's own names: never "repaired" into a brand

    /// What Apple Speech has heard in its current recognition. Replaced in tests.
    var appleWords: () -> [SpokenWord]
    var appleText: () -> String

    init(accurate: WhisperAccurate = .shared, apple: SpeechRecognizer? = nil) {
        let apple = apple ?? SpeechRecognizer()
        self.accurate = accurate
        self.apple = apple
        self.appleWords = { [unowned apple] in apple.words }
        self.appleText = { [unowned apple] in apple.transcript }
        apple.onPartial = { [weak self] _ in
            MainActor.assumeIsolated { self?.recompute() }
        }
        apple.onFinished = { [weak self] text in
            MainActor.assumeIsolated { self?.appleFinished(text) }
        }
    }

    var generation: Int { generationBox.value }

    // MARK: Listening

    func start() async {
        guard !isRecording else { return }
        generationBox.bump()
        delivered = false
        phrases = []
        transcript = ""
        words = []
        origin = 0
        protectedNames = vocabulary?() ?? []
        accurate.prepare(keyTerms: KeyTerms.build(household: protectedNames))     // in the background: never waited for
        openSettler()
        onPartial?("")
        await apple.start()
        if !apple.isRecording { closeSettler(discard: true) }                      // it did not start (permission, audio session)
    }

    func stop() {
        guard isRecording else { return }
        apple.stop()                    // Apple's last result arrives (or two seconds pass), then `appleFinished` runs
    }

    func cancel() {
        generationBox.bump()
        delivered = true
        apple.cancel()
        closeSettler(discard: true)
        phrases = []
    }

    /// A fresh recognition on the microphone that is already running. The pause detector starts over with it.
    @discardableResult
    func restartRecognition() -> Bool {
        guard isRecording else { return false }
        newRecognition()
        if let sink { apple.audioMirror.sink = sink }
        let ok = apple.restartRecognition()
        origin = sink?.secondsAppended ?? 0
        return ok
    }

    /// While Kitty talks the mic is only for a stop word: Apple Speech listens, and the accurate model is left alone, because it
    /// would be transcribing Kitty's own voice.
    @discardableResult
    func beginSpeakingListen() -> Bool {
        guard isRecording else { return false }
        newRecognition()
        apple.audioMirror.sink = nil
        return apple.beginSpeakingListen()
    }

    func resetAudioEngine() { apple.resetAudioEngine() }

    /// Lets go of the accurate model a while after the conversation closes.
    func unloadSoon() { accurate.unloadSoon() }

    private func newRecognition() {
        generationBox.bump()
        delivered = false
        phrases = []
        transcript = ""
        words = []
        protectedNames = vocabulary?() ?? []
        if let settler {
            settler.prompt = WhisperPrompt.build(from: KeyTerms.build(household: protectedNames))
            queue.async { settler.reset() }
        }
    }

    // MARK: The pause detector

    private func openSettler() {
        let box = generationBox
        let newSettler = TurboSettler(accurate: accurate.provider,
                                      prompt: WhisperPrompt.build(from: KeyTerms.build(household: protectedNames))) { [weak self] event in
            let g = box.value
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.received(event, generation: g) } }
        }
        stats = PassStats(label: "whisper-turbo")
        let newSink = AudioHopSink(session: newSettler, queue: queue, stats: stats)
        settler = newSettler
        sink = newSink
        apple.audioMirror.sink = newSink
    }

    private func closeSettler(discard: Bool, then completion: (@Sendable () -> Void)? = nil) {
        apple.audioMirror.sink = nil
        guard let old = sink else { completion?(); return }
        sink = nil
        settler = nil
        Breadcrumb.log(stats.summary)
        old.close(discard: discard, then: completion)
    }

    /// One event from the pause detector, on the main actor and in order. One from before a restart is dropped.
    func received(_ event: TurboSettler.Event, generation g: Int) {
        guard g == generationBox.value else { return }
        switch event {
        case .phraseEnded(let id, let start, let end):
            phrases.append(SettledPhrase(id: id, start: start, end: end, appleCountAtEnd: appleWords().count, text: nil))
        case .settled(let id, let text, let accurateWords, let ms):
            guard let i = phrases.firstIndex(where: { $0.id == id }) else { return }
            stats.recordLatency(ms)
            let repaired = BrandFixer.fix(text, protectedNames: protectedNames)
            if !repaired.changes.isEmpty {
                Breadcrumb.log("brand fix: " + repaired.changes.map { "\($0.from) -> \($0.to)" }.joined(separator: ", "))
            }
            phrases[i].text = repaired.text
            phrases[i].words = repaired.changes.isEmpty ? accurateWords : []
        }
        recompute()
    }

    // MARK: The transcript

    /// Apple's words with the settled phrases put in place of the ones they cover. With nothing settled yet it is exactly what Apple
    /// Speech reports, punctuation and all.
    private func merged() -> HybridTranscript.Merged {
        if !phrases.contains(where: { $0.text != nil }) { return .init(text: appleText(), words: appleWords()) }
        return HybridTranscript.merge(phrases: phrases, apple: appleWords(), origin: origin)
    }

    func recompute() {
        let m = merged()
        words = m.words
        guard m.text != transcript else { return }
        transcript = m.text
        onPartial?(m.text)
    }

    /// Apple Speech's recognition is over (you stopped it, or it ended by itself): settle what is being said, wait a few seconds at
    /// most for the accurate passes, and deliver.
    private func appleFinished(_ appleFinal: String) {
        guard !delivered else { return }
        delivered = true
        let gen = generationBox.value
        guard sink != nil else {
            deliver(appleFinal, generation: gen)
            return
        }
        closeSettler(discard: false) { [weak self] in
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.deliver(appleFinal, generation: gen) } }
        }
    }

    private func deliver(_ appleFinal: String, generation gen: Int) {
        guard gen == generationBox.value else { return }
        let m = merged()
        var text = m.text
        // Never lose what Apple heard if nothing was settled (or the merge came out empty for a reason other than noise).
        if text.isEmpty && !phrases.contains(where: { $0.text?.isEmpty == true }) { text = appleFinal }
        if !phrases.contains(where: { $0.text != nil }) { text = appleFinal }
        text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        words = m.words
        transcript = text
        onFinished?(text)
    }

    /// For tests: a listening session with no microphone, so settled phrases and Apple's words can be fed in by hand.
    func beginWithoutAudio() {
        generationBox.bump()
        delivered = false
        phrases = []
        transcript = ""
        words = []
        origin = 0
    }

    var phrasesForTests: [SettledPhrase] { phrases }
}

nonisolated final class GenerationBox: @unchecked Sendable {
    private let lock = NSLock()
    private var _value = 0
    var value: Int { lock.lock(); defer { lock.unlock() }; return _value }
    func bump() { lock.lock(); _value += 1; lock.unlock() }
}
