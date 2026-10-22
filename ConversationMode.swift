import SwiftUI
import Combine
import AVFoundation
#if os(iOS)
import UIKit
#endif

// MARK: - Talk to Kitty: a conversation, not a one-shot command
//
// Kitty keeps listening while you pause. After a real pause she works out what you mean and shows a preview.
// If you keep talking, what you say is added to what you already said and the preview updates.
// Nothing changes until the preview is confirmed (a 2-second button, or "yes"). If she needs more information she asks.

@MainActor
final class VoiceConversation: ObservableObject {
    enum Stage: Equatable { case idle, listening, thinking, preview, question }

    struct ChatLine: Identifiable {
        enum Role { case you, kitty }
        let id = UUID()
        var role: Role
        var text: String
        var struck: Set<Int> = []           // positions of words you took back ("um", "no wait"...): shown struck through
        var filter: PanelFilter? = nil      // show matching tasks under this reply
        var taskIDs: [UUID] = []            // tasks this reply created: shown as cards you can swipe to delete
    }

    static let autoAddDelay: Double = 2

    // What the screen shows
    @Published private(set) var stage: Stage = .idle
    @Published private(set) var turnText = ""          // everything you said in this turn, across pauses
    @Published private(set) var hearingTasks: Int?      // live "Hearing N tasks" chip: from the words so far, never from the model
    private var hearingThrottle = HearingThrottle()
    private var hearingTask: Task<Void, Never>?
    @Published private(set) var proposal: Proposal?
    @Published private(set) var question = ""
    @Published private(set) var lines: [ChatLine] = []
    /// How many of the words in `turnText` are already in the chat (said before a question). The live bubble shows the rest.
    @Published private(set) var committedWords = 0
    @Published private(set) var countdownActive = false
    @Published private(set) var isStale = false         // you kept talking: the preview is out of date
    /// Kitty is talking. The mic is off then, so tapping the mic button stops her and starts listening.
    @Published private(set) var isSpeaking = false
    private var spokenNow = ""          // what Kitty is saying right now, so her own voice is not mistaken for yours
    private var spokenBuffer = SpokenBuffer()   // and what she said just before, for the tail of her voice after she stops
    private var lastEchoLogged = ""
    private var sessionEchoLead = 0    // leading words of this session that were Kitty's tail, not yours
    private var bargeBase = ""          // what was already said in this turn when she began speaking
    private var userMuted = false       // you (or the idle timeout) turned the mic off: the watchdog leaves it off
    private var micBlocked = false      // a permission problem: only you can fix it, so do not keep retrying
    private var startingMic = false
    private var bargeRestarts: [Date] = []
    private var watchdogTicks = 0
    @Published private(set) var micOn = false { didSet { turns.state.setListening(micOn) } }
    @Published private(set) var errorMessage: String?

    /// Read Kitty's replies out loud. Off by default; remembered between launches.
    /// Tunes the recogniser for Indian English. Takes effect the next time listening starts.
    @Published var indianEnglish: Bool = SpeechLocalePreference.isIndianEnglish {
        didSet { SpeechLocalePreference.isIndianEnglish = indianEnglish }
    }
    @Published var speakReplies: Bool = UserDefaults.standard.bool(forKey: "kitty.speakReplies") {
        didSet {
            UserDefaults.standard.set(speakReplies, forKey: "kitty.speakReplies")
            if !speakReplies { Speaker.stopIfActive() }
        }
    }

    /// Fill the confirm button for 2 seconds and then apply. Turn off to always tap yourself.
    @Published var autoAdd: Bool = (UserDefaults.standard.object(forKey: "kitty.autoAdd") as? Bool) ?? true {
        didSet {
            UserDefaults.standard.set(autoAdd, forKey: "kitty.autoAdd")
            if !autoAdd { cancelCountdown() }
        }
    }

    private let speech: SpeechRecognizer = {
        let r = SpeechRecognizer()
        r.vocabulary = { VocabularyProvider.current() }
        return r
    }()
    /// Decides when speech might be a finished thought, and makes the one model call for it.
    private let turns = VoiceTurnManager()
    private var pauseProfile = PauseProfile.current()   // how long this person pauses mid-sentence, learned over time
    private var lastActedRaw = ""      // the speech Kitty last acted on, so the same words are not judged twice
    private var carry = ""             // text from earlier recognition sessions in this turn
    private var sessionText = ""       // the current recognition session (cumulative)
    private var processedText = ""     // the text the current preview or question was built from
    private var lastChange = Date()
    private var generation = 0
    private var active = false         // the screen is open
    private var processingTask: Task<Void, Never>?
    private var countdownTask: Task<Void, Never>?
    private var watcherTask: Task<Void, Never>?
    private var idleTask: Task<Void, Never>?
    private var restarts: [Date] = []
    private var micWanted = true       // false when you typed instead: don't open the mic behind your back

    init() {
        speech.continuous = true
        // Called on the main actor, in order, so a late partial of the old session can never slip in after a restart.
        speech.onPartial = { [weak self] text in
            MainActor.assumeIsolated { self?.heard(text) }
        }
        speech.onFinished = { [weak self] text in
            Task { @MainActor in self?.sessionEnded(text) }
        }
    }

    // MARK: Open and close

    /// Opens the conversation. With `seed` (typed on the home screen) it starts working right away; otherwise it listens.
    func open(seed: String?) {
        active = true
        errorMessage = nil
        userMuted = false
        micBlocked = false
        speech.bargeIn = BargeIn.enabled        // one duplex audio setup for the whole conversation
        lines = []
        turns.state.reset()
        resetTurn()
        stage = .idle
        startWatcher()
        let typed = (seed ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        micWanted = typed.isEmpty
        if typed.isEmpty {
            Task {
                try? await Task.sleep(nanoseconds: 400_000_000)   // let the screen finish appearing
                await startMic()
            }
        } else {
            carry = typed
            turnText = typed
            beginProcessing(typed: true)
        }
    }

    func close() {
        active = false
        processingTask?.cancel()
        countdownTask?.cancel()
        watcherTask?.cancel()
        idleTask?.cancel()
        countdownActive = false
        speech.bargeIn = false                  // let the audio session shut down with the screen
        speech.cancel()
        Speaker.stopIfActive()
        micOn = false
        generation += 1
    }

    // MARK: Listening

    private func startMic() async {
        guard active, !startingMic else { return }
        startingMic = true
        sessionEchoLead = 0
        defer { startingMic = false }
        speech.cancel()
        var attempt = 0
        while true {
            await speech.start()
            guard active else { speech.cancel(); return }
            guard let message = speech.errorMessage else { break }
            // A start-up hiccup (audio session or engine busy after a route change) is retried quietly. Only a permission
            // problem is shown, because only you can fix it.
            if let delay = MicPolicy.retryDelay(afterFailure: attempt, permanent: speech.failureIsPermanent) {
                Breadcrumb.log("mic start failed (try \(attempt + 1)): \(message)")
                speech.cancel()
                if attempt == MicPolicy.retryDelays.count - 1 { speech.resetAudioEngine() }
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                guard active, micWanted, !userMuted else { return }
                attempt += 1
                continue
            }
            errorMessage = message
            micOn = false
            micBlocked = speech.failureIsPermanent
            if proposal == nil { stage = .idle }
            return
        }
        micBlocked = false
        micMarkedOn()
    }

    private func micMarkedOn() {
        micOn = speech.isRecording
        if micOn {
            errorMessage = nil
            if stage == .idle { stage = .listening }
            armIdle()
        }
    }

    /// Back to listening after a turn: a fresh recognition on the microphone that is already running (no audio change),
    /// or a full start if it is not running.
    private func resumeListening() async {
        guard active, micWanted, !userMuted else { return }
        if speech.isRecording, speech.restartRecognition() { micMarkedOn(); return }
        await startMic()
    }

    func pauseListening() {
        userMuted = true                        // an explicit mute (or the idle timeout): the watchdog respects it
        speech.cancel()
        micOn = false
        if stage == .listening { stage = .idle }
    }

    /// Tap the mic: "I'm done" while you are talking, mute when there is nothing said, or start listening.
    func micTapped() {
        if isSpeaking {
            micWanted = true                    // tapping the mic is asking to talk
            userMuted = false
            stopSpeaking()
            return
        }
        if micOn {
            let text = turnText.trimmingCharacters(in: .whitespacesAndNewlines)
            if stage == .listening, !text.isEmpty, norm(SpeechCleaner.clean(text).text) != norm(processedText) {
                beginProcessing()          // don't wait for the pause
            } else if stage == .listening, text.isEmpty {
                pauseListening()
            }
        } else {
            micWanted = true
            userMuted = false
            micBlocked = false
            Task { await startMic() }
        }
    }

    private func heard(_ incoming: String) {
        guard active, !incoming.isEmpty else { return }
        if isSpeaking { bargeInHeard(incoming); return }
        // Just after Kitty stops, the start of what the microphone hears can be the tail of her own voice. Words before the
        // point where you begin are hers; the same number is dropped from every later partial of this session.
        let now = Date()
        let recent = spokenBuffer.recentText(now: now)
        if !recent.isEmpty {
            let lead = BargeIn.leadingEcho(heard: incoming, spoken: recent, strict: spokenBuffer.inQuietWindow(now: now))
            if lead > sessionEchoLead {
                sessionEchoLead = lead
                Breadcrumb.log("echo: dropping the first \(lead) words of “\(incoming.prefix(40))”")
            }
        }
        var text = incoming
        if sessionEchoLead > 0 {
            text = incoming.split(whereSeparator: { $0.isWhitespace }).dropFirst(sessionEchoLead).joined(separator: " ")
        }
        guard !text.isEmpty else { return }
        // A partial that starts over (it holds only the new sentence) is added to the turn, not put in place of it.
        let merged = TurnAccumulator.absorb(carry: carry, session: sessionText, partial: text)
        if merged.reset { Breadcrumb.log("partials restarted: kept “\(sessionText.prefix(40))”") }
        carry = merged.carry
        sessionText = merged.session
        let full = join(carry, sessionText)
        guard full != turnText else { return }
        turnText = full
        lastChange = Date()
        armIdle()
        updateHearingChip()
        // "done" at the end is not new content, and cleaning means "um" or "no wait" alone don't count as new words either.
        let spoken = SpeechCleaner.clean(VoiceTurnManager.splitFinalizer(full).text).text
        if stage == .thinking || stage == .preview || stage == .question, norm(spoken) != norm(processedText) {
            interrupt()                    // you kept talking
        }
    }

    /// At most every 0.5 s. A partial skipped by the throttle is looked at once the interval has passed, so the last words count.
    private func updateHearingChip() {
        guard stage == .listening else { return }
        if hearingThrottle.allow(at: Date()) {
            hearingTask?.cancel()
            hearingTask = nil
            hearingTasks = HearingChip.count(in: liveText, words: speech.words)
        } else if hearingTask == nil {
            hearingTask = Task { [weak self] in
                try? await Task.sleep(nanoseconds: 550_000_000)
                guard !Task.isCancelled, let self else { return }
                self.hearingTask = nil
                if self.stage == .listening { self.hearingTasks = HearingChip.count(in: self.liveText, words: self.speech.words) }
            }
        }
    }

    private func hideHearingChip() {
        hearingTask?.cancel()
        hearingTask = nil
        hearingThrottle.reset()
        hearingTasks = nil
    }

    /// The recognizer ended on its own (time limit). Keep what was heard and listen again.
    private func sessionEnded(_ text: String) {
        guard active else { return }
        if !isSpeaking { sessionEchoLead = 0 }
        if isSpeaking {
            // The recogniser ended while Kitty is still talking: open it again so "stop" keeps working. This has its own
            // budget, so it can never use up the one for normal listening.
            bargeRestarts.append(Date())
            bargeRestarts = bargeRestarts.filter { Date().timeIntervalSince($0) < 10 }
            if bargeRestarts.count <= 6 { Task { _ = await startBargeInListening() } }
            return
        }
        guard micOn else { return }
        if !text.isEmpty {
            carry = join(carry, text)
            sessionText = ""
            turnText = carry
        }
        restarts.append(Date())
        restarts = restarts.filter { Date().timeIntervalSince($0) < 10 }
        let delay = MicPolicy.restartDelay(restartsInWindow: restarts.count)
        Task {
            // Many endings in a row: wait a little longer each time instead of giving up and asking for a tap.
            if delay > 0 { try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000)) }
            guard self.active, self.micWanted, !self.userMuted else { return }
            await self.startMic()
        }
    }

    /// You spoke again: stop the current work, keep the words, and wait for the next pause.
    private func interrupt() {
        processingTask?.cancel()
        processingTask = nil
        generation += 1
        cancelCountdown()
        isStale = proposal != nil
        stage = .listening
    }

    // MARK: Knowing when you have finished

    private func startWatcher() {
        watcherTask?.cancel()
        watcherTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 120_000_000)
                guard let self else { return }
                self.watchdog()
                self.tick()
            }
        }
    }

    /// About once a second: if the mic is off and nobody turned it off, turn it back on.
    private func watchdog() {
        watchdogTicks += 1
        guard watchdogTicks % 8 == 0 else { return }
        guard MicPolicy.shouldRestart(active: active, micWanted: micWanted, userMuted: userMuted, blocked: micBlocked, micOn: micOn,
                                      isSpeaking: isSpeaking, starting: startingMic, thinking: stage == .thinking) else { return }
        Breadcrumb.log("watchdog: mic was off, restarting it")
        Task { await startMic() }
    }

    private func tick() {
        guard active, stage == .listening else { return }
        let raw = turnText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else { return }

        // Only "done" was said: nothing to act on.
        let parts = VoiceTurnManager.splitFinalizer(raw)
        if parts.isFinal, parts.text.isEmpty, proposal == nil {
            resetTurn()
            return
        }

        let silence = Date().timeIntervalSince(lastChange)
        switch VoiceTurnManager.gate(utterance: raw, silence: silence, lastActed: lastActedRaw, profile: pauseProfile) {
        case .keepListening, .hold:
            break                                   // a short pause, or unfinished speech: no model call
        case .evaluate(let text):
            beginProcessing(text: text)
        case .forceEvaluate(let text):
            // "done" / "save it" / "go ahead" after a preview saves it; otherwise it makes the speech final.
            if proposal != nil, norm(text) == norm(processedText) { confirm() } else { beginProcessing(text: text) }
        case .nudge:
            handleLongSilence(raw)
        }
    }

    /// A long silence on unfinished speech. Never "Are you done?": a pending preview comes back as it was, a dangling
    /// "add a task to…" gets a real question about the missing task, and anything else is dropped quietly.
    private func handleLongSilence(_ raw: String) {
        if proposal != nil {
            isStale = false
            stage = .preview
            return
        }
        if let q = turns.nudgeQuestion(for: raw) {
            lastActedRaw = turnText
            processedText = SpeechCleaner.clean(turnText).text
            turns.state.markProcessed(turnText)
            showQuestion(q)
            Breadcrumb.log("question: \(q.prefix(60))")
            speakQuestion(q)
        } else {
            // Nothing to ask. If there was real content before a trailing "and" or "the", act on that. Never just drop it.
            let trimmed = VoiceTurnManager.dropTrailingFiller(SpeechCleaner.clean(raw).text)
            if trimmed.split(separator: " ").count >= 2, VoiceTurnManager.norm(trimmed) != VoiceTurnManager.norm(processedText) {
                beginProcessing(text: trimmed, final: true)
            } else if trimmed.split(separator: " ").count >= 3 {
                beginProcessing(text: trimmed, final: true)          // the model already said "wait" and you stopped: answer anyway
            } else {
                resetTurn()
                if !micOn, micWanted { Task { await startMic() } }
            }
        }
    }

    // MARK: Working out what you meant

    private func beginProcessing(text override: String? = nil, typed: Bool = false, final: Bool = false) {
        // Everything downstream works on the cleaned words. The chat keeps the raw ones (see `liveAttributed`).
        let text = SpeechCleaner.clean((override ?? turnText).trimmingCharacters(in: .whitespacesAndNewlines)).text
        guard !text.isEmpty else { return }

        // "yes" after a preview saves it, "cancel" throws it away. A bare "no" is not a discard: Kitty asks what to change.
        if proposal != nil {
            switch ConfirmationManager.interpret(newPart(of: text, after: processedText)) {
            case .yes: confirm(); return
            case .cancel: discard(); return
            case .no, .other: break
            }
        }

        hideHearingChip()
        Breadcrumb.log("pause: working on “\(text.prefix(60))”")
        if !typed, !speech.words.isEmpty { pauseProfile = PauseProfile.record(words: speech.words) }
        lastActedRaw = turnText
        processedText = text
        stage = .thinking
        generation += 1
        let g = generation
        processingTask?.cancel()
        processingTask = Task { [weak self] in
            guard let self else { return }
            self.turns.heardWords = typed ? [] : self.speech.words      // per-word confidence, for the "Did you say…?" check
            let result = await self.turns.decide(utterance: text, final: final || typed)
            guard !Task.isCancelled, g == self.generation else { return }
            self.finishProcessing(result, typed: typed)
        }
    }

    private func finishProcessing(_ result: TurnResult, typed: Bool = false) {
        processingTask = nil
        switch result {
        case .wait:
            Breadcrumb.log("decision: wait")
            stage = .listening                      // the model thinks you are still speaking: say nothing, keep listening
            if typed { handleLongSilence(turnText.trimmingCharacters(in: .whitespacesAndNewlines)) }   // typing has no pause to wait for

        case .reply(let reply):
            let said = liveText
            Task { await finishTurn(you: said, reply: reply) }

        case .proposal(let p):
            question = ""
            proposal = p
            isStale = false
            if p.runImmediately { confirm(); return }
            stage = .preview
            Breadcrumb.log("preview: \(p.title)")
            if p.autoConfirm && autoAdd { startCountdown() }

        case .question(let q):
            proposal = nil
            isStale = false
            showQuestion(q)
            Breadcrumb.log("question: \(q.prefix(60))")
            speakQuestion(q)
        }
    }

    /// A question is spoken after a beat. If you carry on in that moment it is dropped, so Kitty never talks over the rest
    /// of a long thought.
    private func speakQuestion(_ q: String) {
        guard speakReplies else { return }
        let g = generation
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 900_000_000)
            guard let self, self.active, self.stage == .question, g == self.generation else { return }
            await self.speakAndResume(q)
        }
    }

    // MARK: Confirming

    private func startCountdown() {
        countdownTask?.cancel()
        countdownActive = true
        countdownTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(Self.autoAddDelay * 1_000_000_000))
            guard !Task.isCancelled, let self else { return }
            guard self.countdownActive, self.stage == .preview else { return }
            self.countdownTask = nil       // detach first: confirm() cancels the countdown, and that must not be us
            self.countdownActive = false
            self.confirm()
        }
    }

    func cancelCountdown() {
        countdownTask?.cancel()
        countdownTask = nil
        if countdownActive { countdownActive = false }
    }

    /// Apply the preview.
    func confirm() {
        guard let p = proposal else { return }
        guard turns.state.confirmation.consume(p.id) else { return }       // yes, a tap and the countdown: it runs exactly once
        cancelCountdown()
        processingTask?.cancel()
        generation += 1
        let said = liveText
        stage = .thinking
        Task {
            let reply = await p.apply()
            await finishTurn(you: said, reply: reply)
        }
    }

    /// Throw the preview away and start over.
    func discard() {
        cancelCountdown()
        processingTask?.cancel()
        generation += 1
        let said = liveText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !said.isEmpty { lines.append(ChatLine(role: .you, text: said, struck: liveRemoved)) }
        lines.append(ChatLine(role: .kitty, text: "Okay, I didn't change anything."))
        resetTurn()
        Task { await resumeListening() }
    }

    /// Type instead of speaking: counts as part of the same turn and starts working right away.
    func submitTyped(_ text: String) {
        let typed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !typed.isEmpty else { return }
        stopSpeaking()
        let wasListening = micOn
        interrupt()
        carry = join(turnText, typed)
        sessionText = ""
        turnText = carry
        if wasListening { Task { await startMic() } }
        beginProcessing(typed: true)
    }

    // MARK: Finishing a turn

    private func finishTurn(you: String, reply: AgentReply) async {
        let said = you.trimmingCharacters(in: .whitespacesAndNewlines)
        if !said.isEmpty { lines.append(ChatLine(role: .you, text: said, struck: liveRemoved)) }
        lines.append(ChatLine(role: .kitty, text: reply.message, filter: reply.spec.map { PanelFilter(spec: $0) },
                              taskIDs: reply.created))
        let made = reply.created.compactMap { id in TaskStore.shared.tasks.first { $0.id == id } }.map { (title: $0.title, id: $0.id) }
        turns.state.noteCreated(made)
        resetTurn()
        if speakReplies {
            await speakAndResume(Speaker.spokenForm(of: reply.message, isList: reply.spec != nil, hint: reply.hint))
        } else {
            await resumeListening()        // a fresh recognition for the next thing you say
        }
    }

    private func resetTurn() {
        hideHearingChip()
        turns.state.clearPending()
        sessionEchoLead = 0
        lastActedRaw = ""
        carry = ""
        sessionText = ""
        turnText = ""
        committedWords = 0
        processedText = ""
        proposal = nil
        question = ""
        isStale = false
        countdownTask?.cancel()
        countdownTask = nil
        countdownActive = false
        processingTask?.cancel()
        processingTask = nil
        generation += 1
        stage = micOn ? .listening : .idle
    }

    // MARK: Reading aloud

    /// The microphone is off while Kitty talks, so she never hears herself.
    func speakAndResume(_ text: String) async {
        micOn = false
        isSpeaking = true
        spokenNow = text
        bargeBase = turnText                    // anything you said before this (a question mid-thought) stays in the turn
        spokenBuffer.began(text)
        let duplex = await startBargeInListening()
        if !duplex { speech.cancel() }          // no hands-free stop: the mic stays off while she talks
        await Speaker.shared.speakAndWait(text, duplex: duplex)
        isSpeaking = false
        spokenNow = ""
        spokenBuffer.ended(at: Date())
        sessionEchoLead = 0
        guard active, micWanted, !userMuted else { speech.cancel(); return }
        // The audio session and microphone stay as they are (see `restartRecognition`); only the recognition starts afresh,
        // so nothing of Kitty's voice carries over and a stop never touches the audio setup.
        if duplex, speech.restartRecognition() { micMarkedOn(); return }
        await startMic()
    }

    /// Keeps the microphone open while Kitty talks so "stop", or anything else you say, can cut her off. False if it cannot.
    private func startBargeInListening() async -> Bool {
        guard BargeIn.enabled, active, micWanted, !userMuted else { return false }
        speech.bargeIn = true
        if speech.isRecording { return speech.restartRecognition() }
        await speech.start()
        guard speech.isRecording, speech.errorMessage == nil else {
            speech.cancel()
            return false
        }
        return true
    }

    /// What the microphone hears while Kitty is speaking. A stop word or real speech stops her and keeps your words.
    private func bargeInHeard(_ text: String) {
        guard case .interrupt(let rest) = BargeIn.decide(heard: text, spoken: spokenNow) else {
            let mine = BargeIn.userWords(heard: text, spoken: spokenNow).count
            let all = text.split(whereSeparator: { $0.isWhitespace }).count
            if mine < all, text != lastEchoLogged {                 // some of what the mic heard was Kitty's own voice
                lastEchoLogged = text
                Breadcrumb.log("echo while speaking: ignored “\(text.suffix(40))” (\(all - mine) of \(all) words hers)")
            }
            return
        }
        Breadcrumb.log("barge-in: “\(rest.prefix(40))”")
        // Added to what was said before she spoke, never in place of it: "…a list of tasks" then, over her question,
        // "the first task is…" is one thought.
        carry = join(bargeBase, rest)
        sessionText = ""
        turnText = carry
        lastChange = Date()
        stopSpeaking()
    }

    /// Cut Kitty off. The pending `speakAndResume` then carries on and opens the mic, so you can narrow the list or say the next thing.
    func stopSpeaking() {
        guard isSpeaking else { return }
        Speaker.stopIfActive()
    }

    func speak(_ text: String) { Task { await speakAndResume(text) } }

    // MARK: Housekeeping

    private func armIdle() {
        idleTask?.cancel()
        idleTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 90_000_000_000)
            guard !Task.isCancelled, let self else { return }
            if self.stage == .listening, self.turnText.isEmpty { self.pauseListening() }   // nobody is talking: stop listening
        }
    }

    /// What you have said since the last thing Kitty asked: the live bubble, and the line added to the chat.
    var liveText: String {
        let words = turnText.split(whereSeparator: { $0.isWhitespace })
        return words.dropFirst(min(committedWords, words.count)).joined(separator: " ")
    }

    /// Which words of `liveText` the cleaner removed (fillers, repeats, taken-back clauses). The bubble strikes them through.
    var liveRemoved: Set<Int> {
        let removed = SpeechCleaner.clean(turnText).removed
        let offset = committedWords
        return Set(removed.compactMap { $0 >= offset ? $0 - offset : nil })
    }

    /// Kitty asks a question: what you said so far and the question both go into the chat, so the whole exchange stays visible.
    private func showQuestion(_ q: String) {
        let said = liveText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !said.isEmpty { lines.append(ChatLine(role: .you, text: said, struck: liveRemoved)) }
        lines.append(ChatLine(role: .kitty, text: q))
        committedWords = turnText.split(whereSeparator: { $0.isWhitespace }).count
        question = q
        stage = .question
    }

    private func join(_ a: String, _ b: String) -> String {
        [a, b].map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }.joined(separator: " ")
    }

    /// Lower-case words only, so punctuation the recognizer adds later doesn't look like new speech.
    private func norm(_ s: String) -> String {
        s.lowercased().filter { $0.isLetter || $0.isNumber || $0 == " " }.split(separator: " ").joined(separator: " ")
    }

    private func newPart(of text: String, after processed: String) -> String {
        let t = norm(text), p = norm(processed)
        if !p.isEmpty, t.hasPrefix(p) { return String(t.dropFirst(p.count)).trimmingCharacters(in: .whitespaces) }
        return t
    }

    static func isConfirmation(_ s: String) -> Bool { ConfirmationManager.interpret(s) == .yes }

    /// Only an explicit cancel throws a preview away. A bare "no" asks what to change instead.
    static func isDiscard(_ s: String) -> Bool { ConfirmationManager.interpret(s) == .cancel }
}

// MARK: - Opening the conversation from outside the app (Siri, Action Button, Back Tap)

@MainActor
final class LaunchRouter: ObservableObject {
    static let shared = LaunchRouter()
    @Published var conversationRequested = false
    func requestConversation() { conversationRequested = true }
}

// MARK: - "Hey Kitty" while the app is open
//
// iOS does not let an app listen for its own wake word in the background (only the system does that for "Hey Siri").
// So this listens only while Kitty's home screen is on screen, and only if you turn it on.

@MainActor
final class WakeWordListener: ObservableObject {
    @Published private(set) var isListening = false
    @Published private(set) var errorMessage: String?
    @Published private(set) var heard = ""        // the last few words it heard, so you can see how "Hey Kitty" was understood
    var onWake: (() -> Void)?

    private let speech = SpeechRecognizer()
    private var wanted = false
    private var restarts: [Date] = []
    private var startedAt = Date()

    init() {
        speech.continuous = true
        speech.lightweight = true
        speech.onPartial = { [weak self] text in
            Task { @MainActor in self?.heard(text) }
        }
        speech.onFinished = { [weak self] _ in
            Task { @MainActor in self?.ended() }
        }
    }

    func start() {
        guard !wanted else { return }
        wanted = true
        errorMessage = nil
        heard = ""
        Task { await begin() }
    }

    func stop() {
        wanted = false
        speech.cancel()
        isListening = false
    }

    private func begin() async {
        guard wanted else { return }
        speech.cancel()
        startedAt = Date()
        await speech.start()
        guard wanted else { speech.cancel(); return }
        if let message = speech.errorMessage {
            Breadcrumb.log("wake: could not start: \(message.prefix(90))")
            errorMessage = message
            isListening = false
            wanted = false
            return
        }
        isListening = speech.isRecording
        Breadcrumb.log("wake: listening (on-device: \(speech.preferOnDevice))")
    }

    /// Apple ends a recognition session after about a minute; start another so listening never stops.
    private func ended() {
        guard wanted else { return }
        // Ending within seconds usually means on-device recognition isn't available: use the regular recognizer.
        if Date().timeIntervalSince(startedAt) < 4, speech.preferOnDevice {
            speech.preferOnDevice = false
            Breadcrumb.log("wake: ended quickly, trying without on-device")
        }
        restarts.append(Date())
        restarts = restarts.filter { Date().timeIntervalSince($0) < 12 }
        if restarts.count > 5 {
            Breadcrumb.log("wake: too many restarts, giving up")
            errorMessage = "“Hey Kitty” keeps stopping. Check Settings > Kitty for Microphone and Speech Recognition."
            isListening = false
            wanted = false
            return
        }
        Task { await begin() }
    }

    private func heard(_ text: String) {
        guard wanted, !text.isEmpty else { return }
        let words = text.lowercased().filter { $0.isLetter || $0 == " " }.split(separator: " ").map(String.init)
        let snippet = words.suffix(6).joined(separator: " ")
        if snippet != heard { heard = snippet }
        if Self.isWake(words) {
            Breadcrumb.log("wake: heard “\(snippet)”")
            stop()
            onWake?()
        }
    }

    /// A greeting followed by the name, allowing for how it is often misheard ("hey kitty", "hi kiti", "okay katie").
    static func isWake(_ words: [String]) -> Bool {
        let greetings: Set<String> = ["hey", "hi", "hay", "ok", "okay", "hello", "yo"]
        let names: Set<String> = ["kitty", "kitti", "kity", "kiti", "kitten", "katie", "kiki", "kitte", "kitties"]
        if words.contains("heykitty") || words.contains("hikitty") { return true }
        guard words.count > 1 else { return false }
        for i in 0..<(words.count - 1) where greetings.contains(words[i]) && names.contains(words[i + 1]) { return true }
        return false
    }
}

// MARK: - The conversation screen

struct FilterSheet: Identifiable {
    let id = UUID()
    var filter: PanelFilter
}

struct ConversationView: View {
    @ObservedObject var convo: VoiceConversation
    var seed: String? = nil
    @Environment(\.dismiss) private var dismiss
    @State private var sendFill: CGFloat = 0
    @State private var typed = ""
    @State private var sheet: FilterSheet?

    var body: some View {
        ZStack {
            Color.screenBackground.ignoresSafeArea()
            VStack(spacing: 0) {
                topBar
                thread
                bottomBar
            }
        }
        .onChange(of: convo.countdownActive) { _, active in
            if active {
                sendFill = 0
                withAnimation(.linear(duration: VoiceConversation.autoAddDelay)) { sendFill = 1 }
            } else {
                withAnimation(.easeOut(duration: 0.2)) { sendFill = 0 }
            }
        }
        .onAppear { convo.open(seed: seed) }
        .onDisappear { convo.close() }
        .sheet(item: $sheet) { item in TasksView(filter: item.filter) }
    }

    // MARK: Top bar

    private var topBar: some View {
        HStack {
            Menu {
                Toggle("Read replies aloud", isOn: $convo.speakReplies)
                Toggle("Add automatically after 2 seconds", isOn: $convo.autoAdd)
                Toggle("Listen for English (India)", isOn: $convo.indianEnglish)
            } label: {
                Image(systemName: "slider.horizontal.3")
                    .font(.title3)
                    .frame(width: 40, height: 40)
            }
            Spacer()
            Button {
                Breadcrumb.log("closed")
                dismiss()
            } label: {
                Image(systemName: "xmark")
                    .font(.subheadline.weight(.bold))
                    .foregroundStyle(Color.primary)
                    .frame(width: 36, height: 36)
                    .background(Color.primary.opacity(0.08), in: Circle())
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
    }

    // MARK: The conversation so far

    private var thread: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if convo.lines.isEmpty && convo.turnText.isEmpty && convo.stage != .thinking { welcome }
                    ForEach(convo.lines) { line in lineView(line) }
                    if !convo.liveText.isEmpty { youBubble }
                    responseArea
                    Color.clear.frame(height: 1).id("bottom")
                }
                .padding(.horizontal, 16)
                .padding(.top, 8)
                .padding(.bottom, 12)
            }
            .scrollIndicators(.hidden)
            .onChange(of: convo.turnText) { _, _ in scrollDown(proxy) }
            .onChange(of: convo.lines.count) { _, _ in scrollDown(proxy) }
            .onChange(of: convo.stage) { _, _ in scrollDown(proxy) }
        }
    }

    private func scrollDown(_ proxy: ScrollViewProxy) {
        withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo("bottom", anchor: .bottom) }
    }

    private var welcome: some View {
        VStack(spacing: 10) {
            Image(systemName: "waveform").font(.system(size: 38)).foregroundStyle(.secondary)
            Text("Hi, I'm Kitty").font(.system(.title2, design: .rounded).weight(.bold))
            Text("Tell me what to add, ask what's due, or say things like “mark dusting done”. I'll wait until you've finished, and show you what I'll do before I do it.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 60)
        .padding(.horizontal, 12)
    }

    /// Your words as you said them. Anything the cleaner took out stays visible, struck through and dimmed.
    private func spoken(_ text: String, struck: Set<Int>) -> AttributedString {
        var out = AttributedString()
        for (i, w) in SpeechCleaner.words(of: text).enumerated() {
            var part = AttributedString(i == 0 ? w : " " + w)
            if struck.contains(i) {
                part.strikethroughStyle = .single
                part.foregroundColor = .secondary
            }
            out += part
        }
        return out
    }

    private func youBubbleView(_ text: String, struck: Set<Int> = [], live: Bool) -> some View {
        HStack {
            Spacer(minLength: 48)
            (Text(spoken(text, struck: struck)) + Text(live ? " …" : "").foregroundStyle(.secondary))
                .font(.body)
                .padding(12)
                .background(Color.accentColor.opacity(0.14), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        }
    }

    private var youBubble: some View {
        VStack(alignment: .trailing, spacing: 6) {
            youBubbleView(convo.liveText, struck: convo.liveRemoved, live: convo.stage == .listening)
            if let n = convo.hearingTasks, convo.stage == .listening {
                Label(HearingChip.label(n), systemImage: "ear")
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Color.secondary.opacity(0.12), in: Capsule())
                    .transition(.opacity)
                    .accessibilityLabel(HearingChip.label(n))
            }
        }
    }

    @ViewBuilder
    private func lineView(_ line: VoiceConversation.ChatLine) -> some View {
        switch line.role {
        case .you:
            youBubbleView(line.text, struck: line.struck, live: false)
        case .kitty:
            VStack(alignment: .leading, spacing: 10) {
                // The list comes first. The words follow, and the rest of them opens on tap.
                if let f = line.filter {
                    ResultsBlock(filter: f) { sheet = FilterSheet(filter: f) }
                }
                if !line.taskIDs.isEmpty {
                    CreatedTasks(ids: line.taskIDs)
                }
                if !line.text.isEmpty {
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: "sparkles").foregroundStyle(Color.accentColor).padding(.top, 3)
                        ExpandableText(text: line.text)
                        Button { convo.speak(line.text) } label: {
                            Image(systemName: "speaker.wave.2.fill").font(.footnote).foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(14)
                    .background(Color.cardBackground, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                    .shadow(color: .black.opacity(0.05), radius: 6, y: 2)
                }
            }
        }
    }

    // MARK: Kitty's current response: thinking, a question, or a preview

    @ViewBuilder
    private var responseArea: some View {
        switch convo.stage {
        case .thinking:
            thinkingCard
        case .preview:
            if let p = convo.proposal { proposalCard(p, dimmed: false) }
        case .question:
            questionCard
        case .listening, .idle:
            if let p = convo.proposal, convo.isStale {
                proposalCard(p, dimmed: true)
            } else if !convo.question.isEmpty {
                questionCard
            } else if let error = convo.errorMessage {
                Text(error)
                    .font(.footnote)
                    .foregroundStyle(.red)
                    .padding(.horizontal, 4)
            }
        }
    }

    private var thinkingCard: some View {
        HStack(spacing: 10) {
            ProgressView()
            Text("Thinking…").font(.callout).foregroundStyle(.secondary)
            Spacer()
        }
        .padding(14)
        .background(Color.cardBackground, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    /// The question itself is in the chat above, so this is only a quiet hint.
    private var questionCard: some View {
        Text("Just answer. I'm listening.")
            .font(.footnote)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 4)
    }

    private func color(_ c: PreviewColor) -> Color {
        switch c {
        case .neutral: return Color.secondary
        case .purple: return Color.purple
        case .indigo: return Color.indigo
        case .red: return Color.red
        case .orange: return Color.orange
        case .person(let name): return Assignee.color(for: name)
        }
    }

    private func proposalCard(_ p: Proposal, dimmed: Bool) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: p.destructive ? "exclamationmark.triangle.fill" : "sparkles")
                    .foregroundStyle(p.destructive ? Color.red : Color.accentColor)
                Text(dimmed ? "Updating as you speak…" : p.title).font(.headline)
                Spacer()
            }

            ForEach(p.rows) { row in
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: row.icon)
                        .foregroundStyle(p.destructive ? Color.red : Color.accentColor)
                        .frame(width: 22)
                        .padding(.top, 2)
                    VStack(alignment: .leading, spacing: 6) {
                        Text(row.title).font(.system(.body, design: .rounded).weight(.semibold))
                        if !row.tags.isEmpty {
                            FlowLayout(spacing: 6) {
                                ForEach(row.tags) { tag in
                                    TagPill(text: tag.text, icon: tag.icon, color: color(tag.color))
                                }
                            }
                        }
                    }
                    Spacer(minLength: 0)
                }
            }

            ForEach(p.notes, id: \.self) { note in
                Text(note).font(.footnote).foregroundStyle(.secondary)
            }

            if let used = p.used, !dimmed {
                Text("Used: \(used)").font(.footnote).foregroundStyle(.secondary)
            }

            if !p.skipped.isEmpty, !dimmed {
                DisclosureGroup("Skipped (\(p.skipped.count))") {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(p.skipped, id: \.self) { text in
                            Button { convo.submitTyped("also add \(text)") } label: {
                                Label(text.prefix(1).uppercased() + text.dropFirst(), systemImage: "plus.circle")
                                    .font(.footnote)
                                    .multilineTextAlignment(.leading)
                            }
                            .buttonStyle(.plain)
                            .foregroundStyle(.secondary)
                        }
                        Text("Tap one to add it as a task.").font(.caption2).foregroundStyle(.tertiary)
                    }
                    .padding(.top, 4)
                }
                .font(.footnote)
                .foregroundStyle(.secondary)
            }

            if let prompt = p.prompt, !dimmed {
                Text(prompt).font(.callout.weight(.medium))
            }

            HStack(spacing: 10) {
                Button { convo.discard() } label: {
                    Label("Discard", systemImage: "xmark")
                        .frame(maxWidth: .infinity, minHeight: 44)
                }
                .buttonStyle(.bordered)
                .buttonBorderShape(.capsule)
                .tint(.secondary)

                Button { convo.confirm() } label: {
                    Label(convo.countdownActive ? "\(p.confirmLabel)…" : p.confirmLabel,
                          systemImage: p.destructive ? "trash" : "checkmark")
                        .frame(maxWidth: .infinity, minHeight: 44)
                }
                .buttonStyle(.borderedProminent)
                .buttonBorderShape(.capsule)
                .tint(p.destructive ? Color.red : Color.accentColor)
                .overlay(alignment: .leading) {
                    // Fills in 2 seconds; when it reaches the end, Kitty applies it.
                    GeometryReader { geo in
                        Capsule()
                            .fill(Color.white.opacity(0.3))
                            .frame(width: geo.size.width * sendFill)
                    }
                    .allowsHitTesting(false)
                    .clipShape(Capsule())
                }
            }
            .disabled(dimmed)

            Text(p.autoConfirm && convo.autoAdd
                 ? "Adding automatically. Keep talking to add more, or tap Discard."
                 : "Say “yes” or tap to confirm. Keep talking to change it.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(16)
        .background(Color.cardBackground, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .shadow(color: .black.opacity(0.08), radius: 10, y: 3)
        .opacity(dimmed ? 0.45 : 1)
    }

    // MARK: Bottom: status, type instead, and the mic

    private var statusText: String {
        switch convo.stage {
        case .listening where convo.isSpeaking: return "Kitty is speaking. Tap to stop and talk"
        case .listening: return convo.turnText.isEmpty ? "Listening…" : "Listening… tap the mic when you're done"
        case .thinking: return "Thinking…"
        case .preview: return convo.proposal?.autoConfirm == true && convo.autoAdd ? "Say “discard” to stop, or keep talking" : "Say “yes” to confirm, or keep talking"
        case .question: return "Go ahead, I'm listening"
        case .idle: return convo.isSpeaking ? "Kitty is speaking. Tap to stop and talk" : (convo.micOn ? "" : "Tap the mic to talk")
        }
    }

    private func sendTyped() {
        let text = typed
        typed = ""
        convo.submitTyped(text)
    }

    private var bottomBar: some View {
        VStack(spacing: 8) {
            Text(statusText)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .frame(height: 16)
            HStack(spacing: 12) {
                TextField("Or type here", text: $typed)
                    .submitLabel(.send)
                    .onSubmit { sendTyped() }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 12)
                    .background(Color.cardBackground, in: Capsule())
                MicButton(on: convo.micOn, busy: convo.stage == .thinking, speaking: convo.isSpeaking) { convo.micTapped() }
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 6)
        .padding(.bottom, 10)
    }
}

/// The microphone: pulses while Kitty is listening.
struct MicButton: View {
    let on: Bool
    var busy = false
    var speaking = false           // Kitty is talking: the button becomes "stop"
    var action: () -> Void
    @State private var pulse = false

    var body: some View {
        Button(action: action) {
            ZStack {
                if on {
                    Circle().fill(Color.accentColor.opacity(0.18)).frame(width: 82, height: 82)
                        .scaleEffect(pulse ? 1.15 : 0.9)
                }
                Circle().fill(speaking ? Color.orange : (on ? Color.accentColor : Color.gray.opacity(0.55))).frame(width: 58, height: 58)
                Image(systemName: speaking ? "stop.fill" : (on ? "mic.fill" : "mic.slash.fill"))
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(.white)
            }
            .frame(width: 82, height: 82)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(speaking ? "Stop Kitty speaking" : (on ? "Microphone on" : "Microphone off"))
        .onAppear {
            withAnimation(.easeInOut(duration: 1.1).repeatForever(autoreverses: true)) { pulse = true }
        }
    }
}

/// A short list of tasks shown under one of Kitty's answers.
struct ResultsBlock: View {
    @ObservedObject private var store = TaskStore.shared
    let filter: PanelFilter
    var onSeeAll: () -> Void

    var body: some View {
        let data = store.panel(filter)
        let all = data.overdue + data.due
        let stacks = TaskStacking.stacks(all)
        VStack(alignment: .leading, spacing: 8) {
            if all.isEmpty {
                Text("Nothing to show.").font(.footnote).foregroundStyle(.secondary)
            }
            ForEach(Array(stacks.prefix(5))) { stack in TaskCard(task: stack.lead, siblings: stack.items) }
            if stacks.count > 5 {
                Button("See all \(all.count)") { onSeeAll() }
                    .font(.subheadline.weight(.semibold))
            }
        }
    }
}

/// The full task list with filters (collapsed until you ask for them).
struct TasksView: View {
    @State var filter: PanelFilter
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            TaskPanel(filter: $filter)
                .padding(.horizontal, 16)
                .background(Color.screenBackground.ignoresSafeArea())
                .navigationTitle("Tasks")
                .inlineNavTitle()
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
                }
        }
    }
}

// MARK: - Design system

extension Color {
    static var screenBackground: Color {
        #if os(iOS)
        return Color(uiColor: .systemGroupedBackground)
        #else
        return Color.gray.opacity(0.1)
        #endif
    }

    static var cardBackground: Color {
        #if os(iOS)
        return Color(uiColor: .secondarySystemGroupedBackground)
        #else
        return Color.white
        #endif
    }
}

extension View {
    @ViewBuilder
    func inlineNavTitle() -> some View {
        #if os(iOS)
        self.navigationBarTitleDisplayMode(.inline)
        #else
        self
        #endif
    }
}

extension TaskCategory {
    var symbol: String {
        switch self {
        case .househelp: return "house.fill"
        case .work: return "briefcase.fill"
        case .personal: return "person.fill"
        case .family: return "figure.2.and.child.holdinghands"
        case .errands: return "cart.fill"
        case .health: return "heart.fill"
        case .finance: return "creditcard.fill"
        case .other: return "tag.fill"
        }
    }
}

extension PanelStatus {
    var symbol: String {
        switch self {
        case .open: return "circle"
        case .overdue: return "exclamationmark.triangle.fill"
        case .done: return "checkmark.circle.fill"
        case .all: return "square.stack.fill"
        }
    }
}

extension Assignee {
    /// A steady colour per person: Me indigo, Family green, Househelp orange, others from a palette.
    static func color(for name: String) -> Color {
        switch name.lowercased() {
        case "me": return .indigo
        case "family": return .green
        case "househelp": return .orange
        default:
            let palette: [Color] = [.pink, .teal, .purple, .mint, .brown, .cyan]
            let sum = name.lowercased().unicodeScalars.reduce(0) { $0 &+ Int($1.value) }
            return palette[sum % palette.count]
        }
    }
}

/// Lays pills out left to right and wraps to the next line.
struct FlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0, widest: CGFloat = 0
        for sub in subviews {
            let size = sub.sizeThatFits(.unspecified)
            if x > 0, x + size.width > maxWidth { x = 0; y += rowHeight + spacing; rowHeight = 0 }
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
            widest = max(widest, x - spacing)
        }
        return CGSize(width: widest, height: y + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, rowHeight: CGFloat = 0
        for sub in subviews {
            let size = sub.sizeThatFits(.unspecified)
            if x > bounds.minX, x + size.width > bounds.maxX { x = bounds.minX; y += rowHeight + spacing; rowHeight = 0 }
            sub.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}

struct TagPill: View {
    let text: String
    var icon: String? = nil
    var color: Color = .secondary
    var filled = false

    var body: some View {
        HStack(spacing: 4) {
            if let icon {
                Image(systemName: icon).font(.system(size: 10, weight: .bold))
            }
            Text(text).font(.caption2.weight(.semibold))
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .foregroundStyle(filled ? Color.white : color)
        .background(filled ? color : color.opacity(0.14), in: Capsule())
    }
}

/// The tags under a task: overdue, repeats, who, when, category, routine, playbook.
struct TaskTags: View {
    let task: TaskItem
    var showGroup = true
    var extra = 0                      // the same chore listed again: "+2 more"

    var body: some View {
        FlowLayout(spacing: 6) {
            if task.isOverdue {
                TagPill(text: "\(task.daysOverdue) \(task.daysOverdue == 1 ? "day" : "days") overdue",
                        icon: "exclamationmark.triangle.fill", color: .red, filled: true)
            }
            if extra > 0 {
                TagPill(text: "+\(extra) more", icon: "square.stack.fill", color: task.isOverdue ? .red : .secondary)
            }
            TagPill(text: task.effectiveAssignee, icon: "person.fill", color: Assignee.color(for: task.effectiveAssignee))
            TagPill(text: task.dueLabel, icon: "calendar", color: task.isOverdue ? .red : .secondary)
            if let time = task.timeLabel {
                TagPill(text: time, icon: task.sortSlot.symbol, color: .indigo)
            }
            if let p = task.priority {
                TagPill(text: p.capitalized, icon: "flag.fill", color: p == "high" ? .red : (p == "medium" ? .orange : .secondary))
            }
            TagPill(text: task.categoryLabel, icon: task.effectiveCategory.symbol, color: .secondary)
            if task.routineID != nil { TagPill(text: "Routine", icon: "repeat", color: .purple) }
            if showGroup, let g = task.group { TagPill(text: g, icon: "list.bullet.rectangle", color: .orange) }
        }
    }
}

/// Checkbox, title and tags. Tapping the circle marks it done (or not done).
struct TaskRowBody: View {
    let task: TaskItem
    var showGroup = true
    var extra = 0
    var onToggle: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Button(action: onToggle) {
                Image(systemName: task.isDone ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 26))
                    .foregroundStyle(task.isDone ? Color.green : (task.isOverdue ? Color.red : Color.secondary.opacity(0.7)))
            }
            .buttonStyle(.borderless)

            VStack(alignment: .leading, spacing: 8) {
                Text(task.title)
                    .font(.system(.body, design: .rounded).weight(.semibold))
                    .strikethrough(task.isDone)
                    .foregroundStyle(task.isDone ? Color.secondary : Color.primary)
                if let notes = task.notes, !notes.isEmpty {
                    Text(notes).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                }
                TaskTags(task: task, showGroup: showGroup, extra: extra)
            }
            Spacer(minLength: 0)
        }
        .opacity(task.isDone ? 0.6 : 1)
    }
}

/// Long-press menu: finish all repeats, reassign, change the day, delete.
struct TaskActions: View {
    let task: TaskItem
    var siblings: [TaskItem] = []      // the same chore listed again

    var body: some View {
        if siblings.count > 1 {
            Button("Mark all \(siblings.count) done") {
                for t in siblings where !t.isDone { TaskStore.shared.complete(t.id) }
            }
            Button("Keep one, remove the other \(siblings.count - 1)") {
                for t in siblings where t.id != task.id { TaskStore.shared.remove(t.id) }
            }
        }
        if !TaskStore.shared.profiles.isEmpty || task.profileID != nil {
            Menu("Move to list") {
                ForEach(TaskStore.shared.profiles) { p in
                    Button(p.name) { TaskStore.shared.moveTask(task.id, to: p) }
                }
                if task.profileID != nil {
                    Button("Take off its list") { TaskStore.shared.moveTask(task.id, to: nil) }
                }
            }
        }
        Menu("Assign to") {
            ForEach(TaskStore.shared.allAssigneeNames, id: \.self) { name in
                Button(name) { TaskStore.shared.setAssignee(task.id, to: name) }
            }
        }
        Button("Due today") { TaskStore.shared.setDue(task.id, to: .now) }
        Button("Due tomorrow") {
            TaskStore.shared.setDue(task.id, to: Calendar.current.date(byAdding: .day, value: 1, to: .now) ?? .now)
        }
        Button(role: .destructive) { TaskStore.shared.remove(task.id) } label: { Label("Delete", systemImage: "trash") }
    }
}

/// One task card. If the same chore appears more than once, `siblings` holds all of them: the card shows the
/// oldest with "+N more", ticking it finishes one, and the long-press menu can finish them all.
struct TaskCard: View {
    let task: TaskItem
    var showGroup = true
    var siblings: [TaskItem] = []

    var body: some View {
        TaskRowBody(task: task, showGroup: showGroup, extra: max(siblings.count - 1, 0)) {
            withAnimation { TaskStore.shared.toggle(task.id) }
        }
        .padding(14)
        .background {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(Color.cardBackground)
                .overlay {
                    if task.isOverdue {
                        RoundedRectangle(cornerRadius: 18, style: .continuous)
                            .fill(Color.red.opacity(0.07))
                    }
                }
        }
        .overlay {
            if task.isOverdue {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .strokeBorder(Color.red.opacity(0.4), lineWidth: 1)
            }
        }
        .shadow(color: .black.opacity(0.05), radius: 6, y: 2)
        .contextMenu { TaskActions(task: task, siblings: siblings) }
    }
}

/// Swipe a card left to delete it.
struct SwipeToDelete<Content: View>: View {
    let onDelete: () -> Void
    @ViewBuilder var content: Content
    @State private var offset: CGFloat = 0

    var body: some View {
        ZStack(alignment: .trailing) {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(Color.red)
                .overlay(alignment: .trailing) {
                    Image(systemName: "trash.fill")
                        .font(.title3)
                        .foregroundStyle(.white)
                        .padding(.trailing, 22)
                        .opacity(min(1, Double(-offset) / 60))
                }
            content
                .offset(x: offset)
                .simultaneousGesture(
                    DragGesture(minimumDistance: 14, coordinateSpace: .local)
                        .onChanged { v in
                            guard abs(v.translation.width) > abs(v.translation.height) else { return }
                            offset = min(0, max(v.translation.width, -160))
                        }
                        .onEnded { v in
                            if v.translation.width < -110 {
                                withAnimation(.easeOut(duration: 0.2)) { offset = -420 }
                                Task { try? await Task.sleep(nanoseconds: 180_000_000); onDelete() }
                            } else {
                                withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) { offset = 0 }
                            }
                        })
        }
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
    }
}

/// The tasks Kitty just created, shown as cards. Each one can be swiped away.
struct CreatedTasks: View {
    @ObservedObject private var store = TaskStore.shared
    let ids: [UUID]

    var body: some View {
        let tasks = ids.compactMap { id in store.tasks.first { $0.id == id } }
        VStack(alignment: .leading, spacing: 8) {
            ForEach(tasks) { task in
                SwipeToDelete(onDelete: { store.remove(task.id) }) {
                    TaskCard(task: task)
                }
            }
            if !tasks.isEmpty {
                Text("Swipe a task left to delete it.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

/// The first couple of sentences, with the rest behind "More".
struct ExpandableText: View {
    let text: String
    var sentenceLimit = 2
    @State private var expanded = false

    private var split: (head: String, hasMore: Bool) {
        var sentences: [String] = []
        text.enumerateSubstrings(in: text.startIndex..., options: .bySentences) { sub, _, _, _ in
            if let sub { sentences.append(sub) }
        }
        guard sentences.count > sentenceLimit else { return (text, false) }
        let head = sentences.prefix(sentenceLimit).joined().trimmingCharacters(in: .whitespacesAndNewlines)
        return (head, true)
    }

    var body: some View {
        let parts = split
        VStack(alignment: .leading, spacing: 6) {
            Text(expanded || !parts.hasMore ? text : parts.head + " …")
                .font(.callout)
                .frame(maxWidth: .infinity, alignment: .leading)
            if parts.hasMore {
                Button(expanded ? "Show less" : "More") {
                    withAnimation(.easeInOut(duration: 0.2)) { expanded.toggle() }
                }
                .font(.footnote.weight(.semibold))
                .buttonStyle(.plain)
                .foregroundStyle(Color.accentColor)
            }
        }
    }
}

/// Title row of a playbook: name, progress, and who is involved.
struct GroupHeader: View {
    let name: String
    let tasks: [TaskItem]

    var body: some View {
        let done = tasks.filter(\.isDone).count
        let people = Array(Set(tasks.map(\.effectiveAssignee))).sorted()
        let listID = tasks.first?.profileID
        let icon = listID.flatMap { id in TaskStore.shared.profiles.first(where: { $0.id == id })?.symbol } ?? "list.bullet.rectangle.fill"
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: icon).foregroundStyle(.orange)
                Text(name).font(.system(.headline, design: .rounded))
                Spacer()
                Text("\(done)/\(tasks.count)").font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
            }
            ProgressView(value: Double(done), total: Double(max(tasks.count, 1)))
                .tint(.orange)
            FlowLayout(spacing: 6) {
                if tasks.contains(where: \.isOverdue) {
                    TagPill(text: "Overdue steps", icon: "exclamationmark.triangle.fill", color: .red, filled: true)
                }
                ForEach(people, id: \.self) {
                    TagPill(text: $0, icon: "person.fill", color: Assignee.color(for: $0))
                }
            }
        }
    }
}

/// Filters (person, day, category) plus the task list. Used on the home screen and in Talk to Kitty.
struct TaskPanel: View {
    @ObservedObject private var store = TaskStore.shared
    @Binding var filter: PanelFilter
    @State private var expanded: Set<String> = []
    @State private var showCompleted = false

    private var choices: [AssigneeChoice] {
        var list: [AssigneeChoice] = [.all, .mine]
        for name in store.allAssigneeNames { list.append(.person(name)) }
        if case .person(let n) = filter.who, !list.contains(.person(n)) { list.append(.person(n)) }
        return list
    }

    @State private var showFilters = false

    private var activeCount: Int {
        (filter.who != .all ? 1 : 0) + (filter.category != nil ? 1 : 0) + (filter.day != .all ? 1 : 0) + (filter.status != .all ? 1 : 0)
            + (filter.profileID != nil ? 1 : 0)
    }

    private var summary: String {
        var parts: [String] = []
        if let pid = filter.profileID, let list = store.profiles.first(where: { $0.id == pid }) { parts.append(list.name) }
        if filter.who != .all { parts.append(filter.who.title) }
        if let c = filter.category { parts.append(c.label) }
        if filter.day != .all { parts.append(filter.day.rawValue) }
        if filter.status != .all { parts.append(filter.status.rawValue) }
        return parts.isEmpty ? "Everything" : parts.joined(separator: " · ")
    }

    /// One slim bar; the filters open and close from it.
    private var filterBar: some View {
        Button {
            withAnimation(.easeInOut(duration: 0.2)) { showFilters.toggle() }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "line.3.horizontal.decrease.circle" + (activeCount > 0 ? ".fill" : ""))
                Text(showFilters ? "Hide filters" : "Filters")
                if activeCount > 0 {
                    Text("\(activeCount)")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 2)
                        .background(Color.accentColor, in: Capsule())
                }
                Spacer()
                Text(summary).font(.footnote).foregroundStyle(.secondary).lineLimit(1)
                Image(systemName: showFilters ? "chevron.up" : "chevron.down")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.secondary)
            }
            .font(.subheadline.weight(.semibold))
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(Color.cardBackground, in: Capsule())
        }
        .buttonStyle(.plain)
    }

    private var filterControls: some View {
        VStack(alignment: .leading, spacing: 10) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(choices, id: \.self) { choice in chip(choice) }
                }
                .padding(.vertical, 2)
            }

            statusRow()

            HStack(spacing: 10) {
                Picker("Day", selection: $filter.day) {
                    ForEach(PanelDay.allCases) { day in Text(day.rawValue).tag(day) }
                }
                .pickerStyle(.segmented)
                categoryMenu
            }

            if let cat = filter.category {
                Button { filter.category = nil } label: {
                    TagPill(text: "\(cat.label)  ✕", icon: cat.symbol, color: .accentColor, filled: true)
                }
                .buttonStyle(.plain)
            }
        }
    }

    var body: some View {
        let data = store.panel(filter)
        VStack(alignment: .leading, spacing: 10) {
            listChips
            filterBar
            if showFilters { filterControls }

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) { content(data) }
                    .padding(.bottom, 12)
            }
            .scrollIndicators(.hidden)
        }
        .onAppear { store.refreshRoutines(includeTomorrow: filter.day == .tomorrow) }
        .onChange(of: filter.day) { _, day in store.refreshRoutines(includeTomorrow: day == .tomorrow) }
        .onChange(of: filter.who) { _, who in
            // Picking a person opens the playbooks so their steps are visible right away.
            if who != .all { expanded = Set(store.tasks.compactMap(\.group)) }
        }
        .onChange(of: filter.profileID) { _, id in
            // Picking a list opens it so its items are visible right away.
            if let id, let list = store.profiles.first(where: { $0.id == id }) { expanded.insert(list.name) }
        }
    }

    /// Your lists ("Blinkit order", "Goa trip"), always one tap away. Long-press one for more.
    @ViewBuilder
    private var listChips: some View {
        if !store.profiles.isEmpty {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(store.profiles) { list in listChip(list) }
                }
                .padding(.vertical, 2)
            }
        }
    }

    private func listChip(_ list: TaskProfile) -> some View {
        let selected = filter.profileID == list.id
        let open = store.items(in: list).filter { !$0.isDone }.count
        return Button {
            withAnimation { filter.profileID = selected ? nil : list.id }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: list.symbol).font(.caption.weight(.bold))
                Text(list.name)
                Text("\(open)").opacity(0.65)
            }
            .font(.subheadline.weight(.semibold))
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .foregroundStyle(selected ? Color.white : Color.primary)
            .background(selected ? Color.orange : Color.cardBackground, in: Capsule())
            .shadow(color: .black.opacity(selected ? 0 : 0.04), radius: 3, y: 1)
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button("Mark all done") { _ = store.completeAll(in: list) }
            Button("Remove all items", role: .destructive) { _ = store.clearItems(in: list) }
            Button("Delete list", role: .destructive) {
                if filter.profileID == list.id { filter.profileID = nil }
                store.removeProfile(list.id, deleteItems: true)
            }
        }
    }

    /// Smart chips: Open / Overdue / Done / All with live counts, and a shortcut to see everything.
    private func statusRow() -> some View {
        let counts = store.panelCounts(filter)
        return ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(PanelStatus.allCases) { status in
                    // Overdue only appears when there is something overdue (or you are looking at it).
                    if status != .overdue || (counts[.overdue] ?? 0) > 0 || filter.status == .overdue {
                        statusChip(status, count: counts[status] ?? 0)
                    }
                }
                smartChip
            }
            .padding(.vertical, 2)
        }
    }

    private func statusChip(_ status: PanelStatus, count: Int) -> some View {
        let selected = filter.status == status
        let tint: Color = status == .overdue ? .red : (status == .done ? .green : .accentColor)
        return Button {
            withAnimation { filter.status = status }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: status.symbol).font(.caption.weight(.bold))
                Text(status.rawValue)
                Text("\(count)").opacity(0.7)
            }
            .font(.footnote.weight(.semibold))
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .foregroundStyle(selected ? tint : Color.secondary)
            .background(selected ? tint.opacity(0.16) : Color.cardBackground, in: Capsule())
            .overlay(Capsule().strokeBorder(selected ? tint.opacity(0.5) : Color.clear, lineWidth: 1))
        }
        .buttonStyle(.plain)
    }

    private var smartChip: some View {
        let everything = PanelFilter(who: .all, category: nil, day: .all, status: .all)
        let showingAll = filter == everything
        return Button {
            withAnimation { filter = showingAll ? PanelFilter() : everything }
        } label: {
            Label(showingAll ? "Back to today" : "Show all tasks", systemImage: showingAll ? "arrow.uturn.backward" : "sparkles")
                .font(.footnote.weight(.semibold))
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .foregroundStyle(Color.accentColor)
                .background(Color.accentColor.opacity(0.12), in: Capsule())
        }
        .buttonStyle(.plain)
    }

    private var categoryMenu: some View {
        Menu {
            Button { filter.category = nil } label: {
                Label("All categories", systemImage: filter.category == nil ? "checkmark" : "square.grid.2x2")
            }
            ForEach(TaskCategory.allCases, id: \.self) { c in
                Button { filter.category = c } label: {
                    Label(c.label, systemImage: filter.category == c ? "checkmark" : c.symbol)
                }
            }
        } label: {
            Image(systemName: filter.category == nil ? "line.3.horizontal.decrease.circle" : "line.3.horizontal.decrease.circle.fill")
                .font(.title2)
        }
    }

    private func chip(_ choice: AssigneeChoice) -> some View {
        let selected = filter.who == choice
        return Button { filter.who = choice } label: {
            HStack(spacing: 6) {
                if case .person(let name) = choice {
                    Circle().fill(selected ? Color.white : Assignee.color(for: name)).frame(width: 8, height: 8)
                }
                Text(choice.title)
                Text("\(store.openCount(for: choice))").opacity(0.65)
            }
            .font(.subheadline.weight(.semibold))
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .foregroundStyle(selected ? Color.white : Color.primary)
            .background(selected ? Color.accentColor : Color.cardBackground, in: Capsule())
            .shadow(color: .black.opacity(selected ? 0 : 0.04), radius: 3, y: 1)
        }
        .buttonStyle(.plain)
    }

    private func sectionHeader(_ title: String, icon: String, count: Int, color: Color) -> some View {
        HStack(spacing: 6) {
            Image(systemName: icon).font(.caption.weight(.bold))
            Text(title).font(.footnote.weight(.bold)).textCase(.uppercase)
            Text("\(count)")
                .font(.caption2.weight(.bold))
                .padding(.horizontal, 7)
                .padding(.vertical, 2)
                .background(color.opacity(0.15), in: Capsule())
            Spacer()
        }
        .foregroundStyle(color)
        .padding(.top, 8)
    }

    private func slotHeader(_ slot: DaySlot) -> some View {
        HStack(spacing: 6) {
            Image(systemName: slot.symbol)
            Text(slot.label)
            Spacer()
        }
        .font(.caption.weight(.semibold))
        .foregroundStyle(.secondary)
        .padding(.top, 4)
        .padding(.leading, 4)
    }

    private var dueTitle: String {
        if filter.status == .done { return "Completed" }
        switch filter.day {
        case .today: return "Due today"
        case .tomorrow: return "Due tomorrow"
        case .all: return "Coming up"
        }
    }

    private var emptyTitle: String {
        switch filter.status {
        case .done: return "Nothing completed yet"
        case .overdue: return "Nothing overdue"
        case .open: return filter.who == .all ? "All clear" : "Nothing open for \(filter.who.title)"
        case .all: return filter.who == .all ? "No tasks" : "No tasks for \(filter.who.title)"
        }
    }

    private func groupNames(_ items: [TaskItem]) -> [String] {
        var out: [String] = []
        for g in items.compactMap(\.group) where !out.contains(g) { out.append(g) }
        return out
    }

    @ViewBuilder
    private func content(_ data: (overdue: [TaskItem], due: [TaskItem])) -> some View {
        // Finished tasks fold into a "Completed" row only when you are looking at everything.
        let foldDone = filter.status == .all
        let openLoose = data.due.filter { $0.group == nil && (!$0.isDone || !foldDone) }
        let doneLoose = foldDone ? data.due.filter { $0.group == nil && $0.isDone } : []
        let groups = groupNames(data.due)

        if data.overdue.isEmpty && data.due.isEmpty {
            VStack(spacing: 8) {
                Image(systemName: "checkmark.seal.fill").font(.system(size: 40)).foregroundStyle(.tertiary)
                Text(emptyTitle).font(.headline)
                Text(filter.status == .open || filter.status == .all
                     ? "Tap the mic and tell Kitty what to add."
                     : "Try another chip above, or tap “Show all tasks”.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity)
            .padding(.top, 36)
        }

        if !data.overdue.isEmpty {
            sectionHeader(filter.day == .tomorrow ? "Still open from earlier" : "Overdue",
                          icon: "exclamationmark.triangle.fill",
                          count: data.overdue.count,
                          color: filter.day == .tomorrow ? .orange : .red)
            ForEach(TaskStacking.stacks(data.overdue)) { stack in TaskCard(task: stack.lead, siblings: stack.items) }
        }

        if !openLoose.isEmpty || !groups.isEmpty {
            sectionHeader(dueTitle, icon: filter.status == .done ? "checkmark.circle.fill" : "calendar",
                          count: filter.status == .done ? data.due.count : data.due.filter { !$0.isDone }.count,
                          color: filter.status == .done ? .green : .secondary)
            ForEach(groups, id: \.self) { name in
                groupCard(name, data.due.filter { $0.group == name })
            }
            // Morning first, evening later: label each part of the day when the list spans more than one.
            let slotsPresent = DaySlot.allCases.filter { s in openLoose.contains { $0.sortSlot == s } }
            let showSlots = slotsPresent.count > 1 || (slotsPresent.first.map { $0 != .anytime } ?? false)
            if showSlots && filter.day != .all {
                ForEach(slotsPresent) { slot in
                    slotHeader(slot)
                    ForEach(TaskStacking.stacks(openLoose.filter { $0.sortSlot == slot })) { stack in
                        TaskCard(task: stack.lead, siblings: stack.items)
                    }
                }
            } else {
                ForEach(TaskStacking.stacks(openLoose)) { stack in TaskCard(task: stack.lead, siblings: stack.items) }
            }
        }

        if !doneLoose.isEmpty {
            Button {
                withAnimation { showCompleted.toggle() }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: showCompleted ? "chevron.down" : "chevron.right").font(.caption.weight(.bold))
                    Text("Completed").font(.footnote.weight(.bold)).textCase(.uppercase)
                    Text("\(doneLoose.count)").font(.caption.weight(.bold))
                    Spacer()
                }
                .foregroundStyle(.secondary)
                .padding(.top, 8)
            }
            .buttonStyle(.plain)
            if showCompleted {
                ForEach(doneLoose) { task in TaskCard(task: task) }
            }
        }
    }

    /// A playbook as one collapsible card; its steps appear when opened.
    private func groupCard(_ name: String, _ items: [TaskItem]) -> some View {
        let isOpen = Binding<Bool>(
            get: { expanded.contains(name) },
            set: { newValue in
                if newValue { _ = expanded.insert(name) } else { _ = expanded.remove(name) }
            })
        return DisclosureGroup(isExpanded: isOpen) {
            VStack(spacing: 8) {
                ForEach(items) { task in TaskCard(task: task, showGroup: false) }
            }
            .padding(.top, 10)
        } label: {
            GroupHeader(name: name, tasks: items)
        }
        .padding(14)
        .background(Color.cardBackground, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .shadow(color: .black.opacity(0.05), radius: 6, y: 2)
        .contextMenu {
            Button("Mark all done") {
                for t in items where !t.isDone { TaskStore.shared.complete(t.id) }
            }
        }
    }
}
