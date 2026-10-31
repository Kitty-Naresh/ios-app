import SwiftUI
import UniformTypeIdentifiers
import Combine
import AVFoundation
import AudioToolbox
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
        var noteID: UUID? = nil             // set on your line that is a saved note: it can be deleted, and it is kept across restarts
        var edited = false                  // the note was changed by hand: the bubble says "Edited"
        var date = Date()                   // when it was written: the thread starts a new day with a date
    }

    // What the screen shows
    @Published private(set) var stage: Stage = .idle { didSet { stageSince = Date(); refreshScreenAwake() } }
    /// When the stage last changed: the watchdog uses it to find a turn that is stuck.
    private var stageSince = Date()
    /// Working on the words longer than this (seconds) is stuck: the work is cancelled and the turn starts again. Not measured.
    static let thinkingTimeout: TimeInterval = 60
    /// Words that were already judged, with nothing new and no sound for this long (seconds), are dropped. Not measured.
    static let staleWordsTimeout: TimeInterval = 25
    @Published private(set) var turnText = ""          // everything you said in this turn, across pauses
    @Published private(set) var proposal: Proposal?
    @Published private(set) var question = ""
    @Published private(set) var lines: [ChatLine] = []
    var notesStore: NotesStore = .shared
    var kittyStore: KittyMessagesStore = .shared
    var chatsStore: ChatsStore = .shared
    /// The chat this conversation is in: its notes load when the screen opens, and new notes belong to it.
    var chatID: UUID?
    /// The note this turn became (see `NoteCapture`): saved when Kitty starts working on it, final once a preview or question opens.
    private var note = NoteCapture()
    /// The note of the most recent turn, kept after the turn ends: "See details" on it shows the steps of that turn.
    private(set) var lastNoteID: UUID?
    /// The note whose edited text Kitty is reading now: its own bubble shows "working", and no second bubble is made.
    private var editingNoteID: UUID?
    /// What an edit of a note would change in the tasks made from it, shown in its own sheet until it is applied or cancelled.
    @Published private(set) var updateSession: NoteUpdateSession?
    private var micWasOnForUpdate = false
    /// How many of the words in `turnText` are already in the chat (said before a question). The live bubble shows the rest.
    @Published private(set) var committedWords = 0
    @Published private(set) var isStale = false         // you kept talking: the preview is out of date
    /// Kitty is talking. The mic is off then, so tapping the mic button stops her and starts listening.
    @Published private(set) var isSpeaking = false { didSet { refreshScreenAwake() } }
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
    /// Turns whose model call was still running when the screen was closed: they finish on their own (see `finishInBackground`).
    private var backgroundGenerations = Set<Int>()
    /// The turns of the request being worked on ("clean", then "the bathroom"), kept to be saved with the tasks it makes.
    private var requestRecords: [TaskTurnRecord] = []
    /// Where "See details" is kept (replaceable in tests).
    var detailsStore: TaskDetailsStore = .shared
    /// Why the mic turned itself off, so the quiet stop is never a mystery.
    @Published private(set) var micNotice: String?
    @Published private(set) var micOn = false {
        didSet { turns.state.setListening(micOn); refreshScreenAwake() }
    }
    @Published private(set) var errorMessage: String?

    /// Read Kitty's replies out loud. Off by default; remembered between launches.
    /// Tunes the recogniser for Indian English. Takes effect the next time listening starts.
    @Published var indianEnglish: Bool = SpeechLocalePreference.isIndianEnglish {
        didSet { SpeechLocalePreference.isIndianEnglish = indianEnglish }
    }
    /// Keep how each task was made (what was said, sent, answered and checked) so a long press can show it. Off by default.
    @Published var saveDetails: Bool = Trace.recording {
        didSet { UserDefaults.standard.set(saveDetails, forKey: Trace.recordingKey) }
    }
    /// Show what Kitty is doing while the model works: the steps, the text sent, the answer as it is written. On by default in a
    /// debug build.
    @Published var liveView: Bool = LiveFeed.enabled {
        didSet { UserDefaults.standard.set(liveView, forKey: LiveFeed.key) }
    }
    /// Whisper Turbo or Apple Speech for the conversation, to compare. Takes effect the next time the conversation opens.
    @Published var speechEngine: SpeechEngineChoice = SpeechEngineChoice.stored() {
        didSet { SpeechEngineChoice.store(speechEngine) }
    }
    @Published var speakReplies: Bool = UserDefaults.standard.bool(forKey: "kitty.speakReplies") {
        didSet {
            UserDefaults.standard.set(speakReplies, forKey: "kitty.speakReplies")
            if !speakReplies { Speaker.stopIfActive() }
        }
    }

    /// The engine picked in the menu when its model is on the phone; Apple Speech otherwise, or if that engine fails to load.
    private var speech: any TurnRecognizer = VoiceConversation.makeRecognizer()
    /// Decides when speech might be a finished thought, and makes the one model call for it.
    private var turns: VoiceTurnManager      // replaced when the words written so far are read again as one whole
    private var pauseProfile = PauseProfile.current()   // how long this person pauses mid-sentence, learned over time
    private var lastActedRaw = ""      // the speech Kitty last acted on, so the same words are not judged twice
    private var finalTried = ""        // the words already judged as final: silence alone never sends them to the model again
    private var carry = ""             // text from earlier recognition sessions in this turn
    private var sessionText = ""       // the current recognition session (cumulative)
    private var processedText = ""     // the text the current preview or question was built from
    private var lastChange = Date()
    private var generation = 0
    private var active = false { didSet { refreshScreenAwake() } }        // the screen is open

    // The screen stays awake only while Kitty is listening, speaking or working on the Talk screen (see `ScreenAwake`).
    /// Asks the system to keep the screen on or lets it sleep again. Replaced in tests so UIKit is never touched.
    var keepScreenAwake: @MainActor (Bool) -> Void = { ScreenAwake.apply($0) }
    private var appInForeground = true { didSet { refreshScreenAwake() } }
    private var screenKeptAwake = false

    /// The app moved to or from the foreground. Going to the background always releases the hold; coming back reapplies it.
    func appForegroundChanged(_ foreground: Bool) { appInForeground = foreground }

    private func refreshScreenAwake() {
        let want = ScreenAwake.wanted(screenOpen: active, appInForeground: appInForeground, micOn: micOn,
                                      isSpeaking: isSpeaking, working: stage == .thinking)
        guard want != screenKeptAwake else { return }
        screenKeptAwake = want
        keepScreenAwake(want)
    }
    private var processingTask: Task<Void, Never>?
    private var watcherTask: Task<Void, Never>?
    private var idleTask: Task<Void, Never>?
    private var restarts: [Date] = []
    /// The preview tray is open: what is said or typed now is an instruction for the preview, never a note.
    @Published private(set) var trayOpen = false
    func setTray(_ open: Bool) { trayOpen = open }
    /// The preview was changed by hand or by an instruction. From then on new words are added to it; until then they are read together
    /// with everything written before (a heading, then its items), so the whole is read as one.
    private var draftTouched = false
    private var instructionLog: [String] = []     // what was said to the preview, in order: the summary after a save repeats it
    private var resumeGroup: UUID?                 // Kitty's last question was about this group and was never answered
    private var instruction = false     // the words being worked on are an instruction for the preview, not a note
    private var micWanted = true       // false when you typed instead: don't open the mic behind your back
    private var nudgedText = ""        // the words "Anything else?" was already said for, so it is said once per stretch of speech
    /// Quiet after a dangling last word before the nudge. Tests set it short.
    var nudgeDelay: TimeInterval = Endpointing.nudgeDelay
    /// Called whenever the fixed nudge fires (tests).
    var onNudge: (() -> Void)?
    private var lastWaitKind = ""      // the last "not sent yet" reason printed in the trace, so it is not repeated every tick

    /// A quiet line while the accurate speech model is getting ready (first run only), so a slower start is explained.
    @Published private(set) var speechNotice: String?
    private var accurateObserver: AnyCancellable?

    init(turns: VoiceTurnManager? = nil) {
        self.turns = turns ?? VoiceTurnManager()
        configureSpeech()
        accurateObserver = WhisperAccurate.shared.$status
            .receive(on: DispatchQueue.main)
            .sink { [weak self] status in
                guard let self else { return }
                let turbo = Self.engine(of: self.speech) == .whisperTurbo
                switch status {
                case .loading where turbo:
                    self.speechNotice = "Getting the accurate speech model ready. Apple Speech listens meanwhile."
                case .failed where turbo:
                    self.speechNotice = "The accurate speech model could not load. Apple Speech is listening."
                default:
                    self.speechNotice = nil
                }
            }
    }

    /// Which engine a recogniser is.
    static func engine(of recognizer: any TurnRecognizer) -> SpeechEngineChoice {
        if recognizer is HybridRecognizer { return .whisperTurbo }
        if recognizer is WhisperRecognizer { return .whisper }
        return .apple
    }

    static func makeRecognizer(for choice: SpeechEngineChoice = SpeechEngineChoice.effective()) -> any TurnRecognizer {
        switch choice {
        case .whisperTurbo: return HybridRecognizer(accurate: WhisperAccurate.shared)
        case .whisper: return WhisperRecognizer()
        case .apple:
            Breadcrumb.log("speech: using Apple Speech (picked, or the other model is missing)")
            return SpeechRecognizer()
        }
    }

    /// Frees the model of whichever local engine is in use, a little after the conversation closes.
    private func unloadModelSoon() {
        (speech as? HybridRecognizer)?.unloadSoon()
        (speech as? WhisperRecognizer)?.unloadSoon()
    }

    /// Whether the speech model failed to load (the quick Whisper; the hybrid carries on with Apple Speech by itself).
    private var modelLoadFailed: Bool {
        (speech as? WhisperRecognizer)?.modelLoadFailed == true
    }

    private func configureSpeech() {
        speech.continuous = true
        speech.vocabulary = { VocabularyProvider.current() }
        // Called on the main actor, in order, so a late partial of the old session can never slip in after a restart.
        speech.onPartial = { [weak self] text in
            MainActor.assumeIsolated { self?.heard(text) }
        }
        speech.onFinished = { [weak self] text in
            Task { @MainActor in self?.sessionEnded(text) }
        }
    }

    /// The speech model would not load: carry on with Apple Speech so the conversation still works.
    private func fallBackToApple() {
        Breadcrumb.log("speech: \(Self.engine(of: speech).label) failed, falling back to Apple Speech")
        speech.cancel()
        speech = SpeechRecognizer()
        speech.bargeIn = BargeIn.enabled
        configureSpeech()
    }

    // MARK: Open and close

    /// Opens the conversation. With `seed` (typed on the home screen) it starts working right away; it listens only when `voice` says so.
    /// With `voice` (a request from Siri) the seed runs the same way, but the mic stays wanted: the answer is spoken and Kitty listens on.
    func open(seed: String?, voice: Bool = false) {
        active = true
        errorMessage = nil
        micNotice = nil
        userMuted = false
        micBlocked = false
        if Self.engine(of: speech) != SpeechEngineChoice.effective() {     // the menu choice changed since the last conversation
            speech.cancel()
            speech = Self.makeRecognizer()
            configureSpeech()
        }
        speech.bargeIn = BargeIn.enabled        // one duplex audio setup for the whole conversation
        // Your notes, and what Kitty kept in the thread (her questions and her summaries), in the order they happened.
        let saved = notesStore.load(chat: chatID)
        let kept = kittyStore.load(chat: chatID)
        lines = (saved.map { (at: $0.createdAt, line: ChatLine(role: .you, text: $0.text, noteID: $0.id, edited: $0.editedAt != nil, date: $0.createdAt)) }
                 + kept.map { (at: $0.createdAt, line: ChatLine(role: .kitty, text: $0.text, date: $0.createdAt)) })
            .sorted { $0.at < $1.at }.map(\.line)
        // A question Kitty asked before the app closed, with nothing written since: the next answer is read with what it was about.
        resumeGroup = kept.last.flatMap { q in q.kind == .question && (saved.last?.createdAt ?? .distantPast) < q.createdAt ? q.groupID : nil }
        requestRecords = []
        turns.state.reset()
        resetTurn()
        stage = .idle
        startWatcher()
        let typed = (seed ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        micWanted = voice                  // a chat opens silent; the mic button, Siri and "Hey Kitty" ask it to listen
        if typed.isEmpty {
            guard voice else { return }
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
        // Closing the screen never saves anything by itself: a model call still running finishes in the background and, like a
        // preview waiting for a tap, says it was not saved.
        if stage == .thinking, processingTask != nil {
            backgroundGenerations.insert(generation)
            processingTask = nil                // detached on purpose: nothing below may cancel it
        } else if stage == .preview, let p = proposal {
            LaunchRouter.shared.post("“\(p.title)” wasn't saved, so nothing changed.")
        }
        active = false
        processingTask?.cancel()
        watcherTask?.cancel()
        idleTask?.cancel()
        speech.bargeIn = false                  // let the audio session shut down with the screen
        speech.cancel()
        unloadModelSoon()
        Speaker.stopIfActive()
        micOn = false
        proposal = nil
        stage = .idle
        generation += 1
    }

    /// A model call that was still running when the screen closed has come back. Nothing is saved by itself: a preview or a
    /// question is left alone, and the home screen says so. Only finishing or reopening one clear task runs at once.
    private func finishInBackground(_ result: TurnResult) async {
        switch result {
        case .proposal(let p):
            if p.runImmediately {
                await applyInBackground(p)
            } else {
                LaunchRouter.shared.post("“\(p.title)” wasn't saved, so nothing changed. Open Talk to Kitty to try again.")
            }
        case .question:
            LaunchRouter.shared.post("Kitty needed an answer, so nothing was added. Open Talk to Kitty to try again.")
        case .reply(let reply):
            if reply.didAdd { LaunchRouter.shared.post(reply.message) }
        case .wait, .handled:
            break
        }
    }

    private func applyInBackground(_ p: Proposal) async {
        // An approval belongs to the draft version it was shown with: a changed draft is not saved from here.
        guard p.approves(currentDraftVersion: turns.state.drafts.version) else {
            LaunchRouter.shared.post("The list changed, so I didn't save “\(p.title)”. Open Talk to Kitty to check it.")
            return
        }
        guard turns.state.confirmation.consume(p.id) else { return }       // still exactly once
        let reply = await p.apply()
        if reply.report?.persistenceFailed == true { turns.state.confirmation.rearm(p.id) }     // nothing stored: the approval stays valid
        keepDetails(for: reply)
        LaunchRouter.shared.post(reply.message)
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
            if modelLoadFailed {
                fallBackToApple()
                continue
            }
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
            micNotice = nil
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
        if stage == .listening {
            // A preview that was dimmed because you were talking comes back whole; switching the mic off never hides it.
            if proposal != nil { stage = .preview; isStale = false } else { stage = .idle }
        }
    }

    /// Tap the mic. It is a listening switch (see `MicTap`): "I'm done" when there are new words, otherwise it stops or
    /// starts listening, in every state, and never cancels work that is under way.
    func micTapped() {
        let text = turnText.trimmingCharacters(in: .whitespacesAndNewlines)
        let hasNewWords = !text.isEmpty && norm(text) != norm(processedText)
        switch MicTap.decide(micOn: micOn, isSpeaking: isSpeaking, stage: stage, hasNewWords: hasNewWords) {
        case .stopSpeaking:
            micWanted = true                    // tapping the mic is asking to talk
            userMuted = false
            stopSpeaking()
        case .processNow:
            beginProcessing()                   // don't wait for the pause
        case .stopListening:
            pauseListening()
        case .startListening:
            micWanted = true
            userMuted = false
            micBlocked = false
            Task { await startMic() }
        }
    }

    /// Whether the thinking card can offer Cancel: the model is working on your words (saving a confirmed task cannot be stopped).
    var canCancelWork: Bool { stage == .thinking && processingTask != nil }

    /// Stop the work that is under way and drop the words. The mic is left as it is.
    func cancelWork() {
        guard canCancelWork else { return }
        processingTask?.cancel()
        processingTask = nil
        let said = liveText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !said.isEmpty { appendYou(said) }
        lines.append(ChatLine(role: .kitty, text: "Okay, I didn't change anything."))
        if proposal != nil {
            // A preview waiting to be saved prevails: cancelling the work on a change to it leaves the preview as it was.
            committedWords = turnText.split(whereSeparator: { $0.isWhitespace }).count
            processedText = turnText
            isStale = false
            stage = .preview
            Task { await resumeListening() }
            return
        }
        resetTurn()
        Task { await resumeListening() }        // stays off if you turned the mic off
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
        let merged = TurnAccumulator.absorb(carry: carry, session: sessionText, partial: text, replacedBySettle: speech.lastChangeWasSettle)
        if merged.reset { Breadcrumb.log("partials restarted: kept “\(sessionText.prefix(40))”") }
        carry = merged.carry
        sessionText = merged.session
        let full = join(carry, sessionText)
        guard full != turnText else { return }
        turnText = full
        lastChange = Date()
        armIdle()
        // "done" at the end is not new content.
        let spoken = VoiceTurnManager.splitFinalizer(full).text
        if stage == .thinking || stage == .preview || stage == .question, norm(spoken) != norm(processedText) {
            interrupt()                    // you kept talking
        }
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
                self.stuckCheck()
                self.tick()
            }
        }
    }

    /// A turn that cannot end by itself is ended here, so no state lasts forever: a model call that never comes back, or words that were
    /// already looked at and sit there with nothing happening.
    private func stuckCheck() {
        guard active else { return }
        let now = Date()
        if stage == .thinking, processingTask != nil, now.timeIntervalSince(stageSince) > Self.thinkingTimeout {
            Breadcrumb.log("watchdog: thinking for over \(Int(Self.thinkingTimeout)) s, the work is cancelled and the turn starts again")
            Trace.note("WARNING", "turn ended: idle (stuck while thinking for over \(Int(Self.thinkingTimeout)) s)")
            processingTask?.cancel()
            processingTask = nil
            resetTurn()
            restartAfterWatchdog(notice: "That took too long, so I stopped. Say it again, or type it.")
            return
        }
        let said = turnText.trimmingCharacters(in: .whitespacesAndNewlines)
        if stage == .listening, !isSpeaking, micOn, proposal == nil, !said.isEmpty, norm(said) == norm(lastActedRaw),
           now.timeIntervalSince(lastChange) > Self.staleWordsTimeout {
            Breadcrumb.log("watchdog: words that were already looked at stayed for over \(Int(Self.staleWordsTimeout)) s, dropped")
            Trace.note("WARNING", "turn ended: idle (the same words sat unchanged for over \(Int(Self.staleWordsTimeout)) s)")
            resetTurn()
            restartAfterWatchdog(notice: nil)
        }
    }

    private func restartAfterWatchdog(notice: String?) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            await self.resumeListening()
            if let notice { self.micNotice = notice }       // after the restart: starting the mic clears notices
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
        guard active, stage == .listening, !isSpeaking else { return }
        let raw = turnText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else { return }

        // Only "done" was said: nothing to act on.
        let parts = VoiceTurnManager.splitFinalizer(raw)
        if parts.isFinal, parts.text.isEmpty, proposal == nil {
            resetTurn()
            return
        }

        let silence = Date().timeIntervalSince(lastChange)
        let judged = VoiceTurnManager.judge(utterance: raw, silence: silence, lastActed: lastActedRaw, profile: pauseProfile,
                                            finalTried: finalTried)
        switch judged.gate {
        case .keepListening:
            // A short pause: no model call. The trace says why, once per reason.
            if judged.kind != lastWaitKind {
                lastWaitKind = judged.kind
                Trace.note("SWIFT", "NOT SENT TO THE MODEL YET: \(judged.why)")
            }
        case .holdDangling:
            // The last word cannot end a thought ("…and the"): the mic stays open, the model is not called. After a short quiet
            // Kitty says "Anything else?" once, from the device.
            if judged.kind != lastWaitKind {
                lastWaitKind = judged.kind
                Trace.note("SWIFT", "NOT SENT TO THE MODEL: \(judged.why)")
            }
            if Endpointing.shouldNudge(silence: silence, text: raw, alreadyNudgedFor: nudgedText, delay: nudgeDelay) {
                nudgedText = raw
                nudge()
            }
        case .evaluate(let text):
            beginProcessing(text: text)
        case .forceEvaluate(let text):
            // "done" / "save it" / "go ahead" after a preview saves it; otherwise it makes the speech final.
            if proposal != nil, norm(text) == norm(processedText) { confirm() } else { beginProcessing(text: text) }
        case .nudge:
            handleLongSilence(raw)
        }
    }

    /// The fixed on-device nudge: no model call. Spoken when read-aloud is on, a system chime otherwise. What was said stays in the turn.
    private func nudge() {
        Trace.note("SWIFT", "NOT SENT TO THE MODEL: \"\(Endpointing.nudgePhrase)\" is a fixed phrase after a dangling word")
        onNudge?()
        guard speakReplies else {
            Chime.play()
            lastChange = Date()
            return
        }
        carry = turnText                     // what was said stays; the recognition that restarts after the nudge continues it
        sessionText = ""
        Task { @MainActor [weak self] in
            guard let self else { return }
            await self.speakAndResume(Endpointing.nudgePhrase)
            self.lastChange = Date()
        }
    }

    /// A long silence: the words are processed as final (a model "wait" is no longer an answer). A pending preview that was
    /// showing comes back as it was.
    private func handleLongSilence(_ raw: String) {
        if proposal != nil {
            isStale = false
            stage = .preview
            Trace.note("SWIFT", "NOT SENT TO THE MODEL: a long silence after unfinished words; the preview that was showing stays as it was")
            return
        }
        beginProcessing(text: raw, final: true)
    }

    // MARK: Working out what you meant

    private func beginProcessing(text override: String? = nil, typed: Bool = false, final: Bool = false) {
        // The raw transcript goes on as heard: the model reads it whole.
        let text = (override ?? turnText).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }

        // "yes" after a preview saves it, "cancel" throws it away. A bare "no" is not a discard: Kitty asks what to change.
        if proposal != nil {
            var fresh = newPart(of: text, after: processedText)
            if fresh.isEmpty { fresh = newPart(of: turnText, after: lastActedRaw) }
            switch ConfirmationManager.interpret(fresh) {
            case .yes where trayOpen: confirm(); return
            case .cancel where trayOpen: discard(); return
            case .yes, .cancel: askToOpenTray(); return
            case .no, .other: break
            }
        }
        if trayOpen || instruction { draftTouched = true }
        let reread = proposal != nil && !draftTouched

        if proposal == nil, answerFromNotes(text) { return }
        saveWordsAsNote(text, typed: typed)
        lastWaitKind = ""
        Breadcrumb.log("pause: working on “\(text.prefix(60))”")
        if !typed, !speech.words.isEmpty { pauseProfile = PauseProfile.record(words: speech.words) }
        lastActedRaw = turnText
        processedText = text
        if final { finalTried = text }
        stage = .thinking
        generation += 1
        let g = generation
        processingTask?.cancel()
        processingTask = Task { [weak self] in
            guard let self else { return }
            // New words written beside a preview nobody has changed are read together with the ones before them, from a clean start: a
            // heading and its items become one list, not a task for the heading and one more for each item.
            let reader = reread ? VoiceTurnManager() : self.turns
            reader.heardWords = typed ? [] : self.speech.words      // per-word confidence, for the "Did you say…?" check
            var result = await reader.decide(utterance: text, final: final || typed)
            if reread { result = self.adoptReading(result, from: reader) }
            guard !Task.isCancelled else { self.adoptLatestPreview(); return }     // the draft may have changed all the same
            if let record = reader.lastRecord { self.requestRecords = Array((self.requestRecords + [record]).suffix(6)) }
            if self.backgroundGenerations.remove(g) != nil { await self.finishInBackground(result); return }   // the screen was closed
            guard g == self.generation else { self.adoptLatestPreview(); return }     // you spoke on: the preview still shows the latest draft
            self.finishProcessing(result, typed: typed)
        }
    }

    /// A fresh reading of everything written replaces the preview only if it found tasks; anything else leaves the preview as it was.
    private func adoptReading(_ result: TurnResult, from reader: VoiceTurnManager) -> TurnResult {
        switch result {
        case .proposal: turns = reader; return result
        case .wait: return result
        default: return .handled
        }
    }

    /// "yes" or "cancel" said in the chat while the preview is closed: nothing is saved or thrown away unseen.
    private func askToOpenTray() {
        committedWords = SpokenText.pieces(turnText).count
        lines.append(ChatLine(role: .kitty, text: "Open the tasks that are ready to review and save them."))
        stage = .preview
    }

    /// What you sent is always kept. The words Kitty starts on become a note and a bubble at once, preview or not; the words of an
    /// instruction (from the preview tray) are not shown or kept. Typed messages are each a note; spoken words that the model has
    /// not judged finished stay one note that grows (see `NoteCapture`).
    private func saveWordsAsNote(_ text: String, typed: Bool) {
        defer { instruction = false }
        guard !note.adopted else { return }
        if typed { note.settle() }
        let all = SpokenText.pieces(text)
        let base = note.growingBase ?? committedWords
        guard all.count > base else { return }
        let piece = SpokenText.text(of: all[base...]).trimmingCharacters(in: .whitespacesAndNewlines)
        committedWords = all.count
        if instruction || trayOpen { if !piece.isEmpty { instructionLog.append(piece) }; return }       // said to the preview: kept for the summary only
        guard !piece.isEmpty, let saved = note.save(piece, from: base, in: notesStore, chatID: chatID) else { return }
        lastNoteID = saved.id
        if let chat = chatID { chatsStore.touch(chat, firstLine: piece) }
        lines.removeAll { $0.noteID == saved.id }                   // a growing note keeps one bubble
        var line = ChatLine(role: .you, text: piece, struck: liveRemoved)
        line.noteID = saved.id
        line.date = saved.createdAt
        lines.append(line)
    }

    /// The model said "wait": the words are not a finished message. They go back into the live bubble, still saved, and the next words
    /// join them in the same note.
    private func takeBackGrowingBubble() {
        guard let base = note.growingBase, let id = note.id else { return }
        lines.removeAll { $0.noteID == id }
        committedWords = base
    }

    private func finishProcessing(_ result: TurnResult, typed: Bool = false) {
        processingTask = nil
        if case .wait = result {} else { note.settle() }
        switch result {
        case .wait:
            Breadcrumb.log("decision: wait")
            takeBackGrowingBubble()
            stage = micOn ? .listening : .idle                      // the model thinks you are still speaking: say nothing, keep listening

        case .handled:
            // The words were used up and there is nothing to show (a question that was shown twice, no question came back, a repeat):
            // the words go into the chat as yours and the turn starts clean, so nothing can run them again.
            Breadcrumb.log("decision: handled")
            let said = liveText.trimmingCharacters(in: .whitespacesAndNewlines)
            if !said.isEmpty { appendYou(said) }
            isStale = false
            if proposal != nil {
                stage = .preview                    // the preview is still built from those words: they stay
            } else {
                consumeTurnWords()
                stage = .listening
            }

        case .reply(let reply):
            let said = liveText
            Task { await finishTurn(you: said, reply: reply) }

        case .proposal(let p):
            // An edited note that already made tasks does not get a second preview card: it gets what would change, in its own sheet.
            if let id = editingNoteID, !createdTaskIDs(for: id).isEmpty {
                let existing = createdTaskIDs(for: id).compactMap { tid in TaskStore.shared.tasks.first { $0.id == tid } }
                let plan = NoteUpdate.plan(tasks: existing, drafts: turns.state.drafts.ordered)
                turns.state.reset()
                resetTurn()
                if !plan.isEmpty { presentUpdate(noteID: id, plan: plan) }
                return
            }
            if let id = note.id { notesStore.setReviewPending(groupOf: id, true) }      // until it is saved or discarded, the notes say "Review tasks"
            question = ""
            proposal = p
            isStale = false
            if p.runImmediately { confirm(); return }
            stage = .preview
            Breadcrumb.log("preview: \(p.title)")
            commitWordsToChat()         // what you said is a line of its own: the next thing you say starts a new one
            if let answer = p.reply { showReviewAnswer(answer) }

        case .question(let q):
            proposal = nil
            isStale = false
            showQuestion(q)
            Breadcrumb.log("question: \(q.prefix(60))")
            consumeTurnWords()                      // the stage stays .question: the next words are the answer, not the old ones again
            speakQuestion(q)
        }
    }

    /// The words of this turn are used up (answered with a question, or handled with nothing to show). They are removed everywhere, and
    /// the recogniser is restarted, because it reports cumulative text: without the restart its next partial would bring them back.
    /// A preview's words are not cleared: the preview is still built from them.
    private func consumeTurnWords() {
        note.reset()
        editingNoteID = nil
        lastActedRaw = ""
        finalTried = ""
        nudgedText = ""
        carry = ""
        sessionText = ""
        turnText = ""
        committedWords = 0
        processedText = ""
        lastWaitKind = ""
        sessionEchoLead = 0
        Breadcrumb.log("turn words consumed; recognition restarted")
        guard active, micWanted, !userMuted, !isSpeaking else { return }
        if speech.isRecording, speech.restartRecognition() { return }
        Task { await startMic() }
    }

    /// The draft behind the card is the one the turn manager holds. A result dropped because you spoke on has still changed
    /// that draft, so the card is brought up to date. This only refreshes the card: it never saves the newer version unseen.
    @discardableResult
    private func adoptLatestPreview() -> Bool {
        guard active, turns.state.drafts.hasContent, let latest = turns.state.pendingProposal, proposal?.id != latest.id else { return false }
        proposal = latest
        Breadcrumb.log("preview brought up to date: \(latest.title)")
        return true
    }

    /// The words Kitty has just worked on go into the chat as your line, and the live bubble starts again after them. Words spoken
    /// while Kitty was thinking are not counted: they stay in the bubble as the next line.
    private func commitWordsToChat() {
        let all = SpokenText.pieces(turnText)
        let handled = min(all.count, processedText.split(whereSeparator: { $0.isWhitespace }).count)
        guard handled > committedWords else { return }
        let said = SpokenText.text(of: all[committedWords..<handled])       // line breaks you typed stay
        if !said.isEmpty { appendYou(said) }
        committedWords = handled
    }

    /// Kitty answers something said about the draft (why a task was missed, what changed): your words and her answer go into the
    /// chat, the draft stays on the card, and nothing is saved.
    private func showReviewAnswer(_ answer: String) {
        commitWordsToChat()
        lines.append(ChatLine(role: .kitty, text: answer))
        Breadcrumb.log("draft review: \(answer.prefix(60))")
        guard speakReplies else { return }
        let g = generation
        Task { @MainActor [weak self] in
            guard let self, self.active, self.stage == .preview, g == self.generation else { return }
            await self.speakAndResume(Speaker.spokenForm(of: answer, isList: false, hint: nil))
        }
    }

    // MARK: Changing the draft by hand

    /// True while the edit sheet is open: the microphone is off, so nothing said to someone else changes the draft.
    @Published private(set) var editingDraft = false
    private var micWasOnForEdit = false

    func beginManualEdit() {
        guard proposal != nil, !editingDraft else { return }
        editingDraft = true
        stopSpeaking()
        micWasOnForEdit = micOn
        pauseListening()
    }

    func endManualEdit() {
        guard editingDraft else { return }
        editingDraft = false
        guard micWasOnForEdit, active else { return }
        micWanted = true
        userMuted = false
        Task { await startMic() }
    }

    func draftItem(_ id: UUID) -> DraftItem? { turns.state.drafts.item(id: id) }
    var knownPeople: [String] { turns.knownPeople() }

    func saveDraftEdit(_ item: DraftItem) { draftTouched = true; adopt(turns.editDraft(item)) }
    func deleteDraftItem(_ id: UUID) { draftTouched = true; adopt(turns.removeDraftItem(id: id)) }
    /// The user said to include a flagged task: it stays, is marked, and the card is rebuilt for the new draft version.
    func includeDraftItem(_ id: UUID) { draftTouched = true; adopt(turns.includeFlaggedItem(id: id)) }
    /// What was said for the draft that waits, as heard. Shown beside the model's quote.
    var draftSpokenText: String { turns.state.drafts.spokenText }
    func addDraftItem(_ item: DraftItem) { draftTouched = true; adopt(turns.addDraftItem(item)) }

    /// The preview after a change by hand; with nothing left in it, the draft is thrown away.
    private func adopt(_ p: Proposal?) {
        guard let p else { discard(); return }
        proposal = p
        isStale = false
        question = ""
        stage = .preview
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

    /// Apply the preview.
    func confirm() {
        // Approval belongs to the exact draft you saw. If the draft changed since, the card is refreshed and nothing is saved.
        let changed = (proposal.map { !$0.approves(currentDraftVersion: turns.state.drafts.version) } ?? false) && turns.state.drafts.hasContent
        if !changed { adoptLatestPreview() }
        if changed {
            adoptLatestPreview()
            stage = .preview
            isStale = false
            showReviewAnswer("The list changed while you were deciding, so I haven't saved anything. Check the latest and say yes again.")
            return
        }
        guard let p = proposal else { return }
        guard turns.state.confirmation.consume(p.id) else { return }       // a "yes" and a tap together: it runs exactly once
        processingTask?.cancel()
        processingTask = nil
        generation += 1
        let said = liveText
        stage = .thinking
        Task {
            let reply = await p.apply()
            if reply.report?.persistenceFailed == true {
                // Nothing was stored. The draft stays on screen exactly as approved, the same approval can be given again, and the
                // reply says so instead of reporting a save.
                turns.state.confirmation.rearm(p.id)
                stage = .preview
                showReviewAnswer(reply.message)
                return
            }
            await finishTurn(you: said, reply: reply)
        }
    }

    /// Throw the preview away and start over.
    func discard() {
        if let id = note.id { notesStore.setReviewPending(groupOf: id, false) }       // the words stay; only the proposed tasks go
        requestRecords = []
        processingTask?.cancel()
        generation += 1
        let said = liveText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !said.isEmpty { appendYou(said) }
        lines.append(ChatLine(role: .kitty, text: "Okay, I didn't change anything."))
        resetTurn()
        Task { await resumeListening() }
    }

    /// Type instead of speaking: counts as part of the same turn and starts working right away.
    /// `asNote` false is an instruction about the preview ("remove the milk", from the tray): it is worked on but never kept as a note.
    func submitTyped(_ text: String, asNote: Bool = true) {
        let typed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !typed.isEmpty else { return }
        if proposal != nil, !trayOpen, asNote, [.yes, .cancel].contains(ConfirmationManager.interpret(typed)) { askToOpenTray(); return }
        instruction = !asNote
        if asNote, proposal == nil, turnText.isEmpty, let gid = resumeGroup {
            let before = notesStore.text(ofGroup: gid)
            if !before.isEmpty {
                turnText = before
                committedWords = SpokenText.pieces(before).count
                note.continueGroup(gid)
            }
        }
        resumeGroup = nil
        stopSpeaking()
        let wasListening = micOn
        interrupt()
        carry = [turnText, typed].map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }.joined(separator: "\n")      // each message on its own line
        sessionText = ""
        turnText = carry
        if wasListening { Task { await startMic() } }
        beginProcessing(typed: true)
    }

    // MARK: Finishing a turn

    /// The turns behind a reply that made tasks go with those tasks. A finished reply ends the request either way.
    private func keepDetails(for reply: AgentReply) {
        // Model calls made while saving (the time of day of each task) come after the turns, as one more record.
        let records = TaskDetailsFormat.withSavingCalls(requestRecords, calls: ModelTape.drain())
        if !reply.created.isEmpty { detailsStore.attach(records, to: reply.created) }
        requestRecords = []
    }

    private func finishTurn(you: String, reply: AgentReply) async {
        keepDetails(for: reply)
        // The screen was closed while this saved: say what happened on the home screen. Never speak or listen from nowhere.
        guard active else { LaunchRouter.shared.post(reply.message); return }
        // A question about saved tasks is not a note: nothing was written down.
        note.dropIfQuestion(created: !reply.created.isEmpty || reply.didAdd, answeredFromTasks: reply.spec != nil, in: notesStore)
        // The tasks made now belong to the note that opened this preview: it shows "N tasks created" and can open them.
        // Tasks made from this chat belong to it, even when nothing was written in this turn (a task asked for in the tray): with no note of
        // its own they are remembered on the chat's newest note, so the chat's task views and chips include them.
        if !reply.created.isEmpty, let id = note.id ?? chatID.flatMap({ notesStore.latest(in: $0)?.id }) {
            notesStore.attach(groupOf: id, taskIDs: reply.created)
            notesStore.setReviewPending(groupOf: id, false)
        }
        let said = you.trimmingCharacters(in: .whitespacesAndNewlines)
        if !said.isEmpty { appendYou(said) }
        if let summary = savedSummary(for: reply) {
            // A save is told once, in a few plain words, and kept: it shows what was written, what was asked, and what came of it.
            lines.append(ChatLine(role: .kitty, text: summary))
            kittyStore.add(summary, kind: .summary, chatID: chatID, groupID: note.groupID)
        } else {
            lines.append(ChatLine(role: .kitty, text: reply.message, filter: reply.spec.map { PanelFilter(spec: $0) },
                                  taskIDs: reply.created + reply.shown.filter { !reply.created.contains($0) }))
        }
        let made = reply.created.compactMap { id in TaskStore.shared.tasks.first { $0.id == id } }.map { (title: $0.title, id: $0.id) }
        turns.state.noteCreated(made)
        resetTurn()
        if speakReplies {
            await speakAndResume(Speaker.spokenForm(of: reply.message, isList: reply.spec != nil || !reply.shown.isEmpty, hint: reply.hint))
        } else {
            await resumeListening()        // a fresh recognition for the next thing you say
        }
    }

    /// "From what you wrote, I made 4 tasks on your Shopping list: diapers, wipes, lotion and 1 more. You also said: “remove the milk”."
    /// Written here from what was really saved and what the user really said, never by the model. Nil when nothing was made or changed.
    private func savedSummary(for reply: AgentReply) -> String? {
        let tasks = reply.created.compactMap { id in TaskStore.shared.tasks.first { $0.id == id } }
        let said = instructionLog.prefix(3).map { "“" + ($0.count > 40 ? String($0.prefix(40)) + "…" : $0) + "”" }.joined(separator: ", ")
        if tasks.isEmpty {
            guard reply.didChange, !said.isEmpty else { return nil }
            return "From what you said (\(said)), I updated your tasks."
        }
        let n = tasks.count
        var text = "From what you wrote, I made \(n) \(n == 1 ? "task" : "tasks")"
        let listIDs = Set(tasks.compactMap(\.profileID))
        if listIDs.count == 1, tasks.allSatisfy({ $0.profileID != nil }),
           let list = TaskStore.shared.profiles.first(where: { $0.id == listIDs.first })?.name { text += " on your \(list) list" }
        text += ": " + tasks.prefix(4).map(\.title).joined(separator: ", ")
        if n > 4 { text += " and \(n - 4) more" }
        text += "."
        if !said.isEmpty { text += " You also said: \(said)." }
        return text
    }

    private func resetTurn() {
        note.reset()
        draftTouched = false
        instructionLog = []
        editingNoteID = nil
        lastWaitKind = ""
        finalTried = ""
        turns.state.clearPending()
        sessionEchoLead = 0
        lastActedRaw = ""
        nudgedText = ""
        carry = ""
        sessionText = ""
        turnText = ""
        committedWords = 0
        processedText = ""
        proposal = nil
        question = ""
        isStale = false
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
        if !speech.isRecording {
            await speech.start()
            guard speech.isRecording, speech.errorMessage == nil else {
                speech.cancel()
                return false
            }
        }
        return speech.beginSpeakingListen()      // the hybrid and Whisper hand the running mic to Apple Speech for the short "stop"
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
            if self.stage == .listening, self.turnText.isEmpty {                             // nobody is talking: stop listening
                self.pauseListening()
                self.micNotice = "Mic turned off after a quiet minute. Tap it to talk."
            }
        }
    }

    /// What you have said since the last thing Kitty asked: the live bubble, and the line added to the chat.
    var liveText: String {
        SpokenText.tail(of: turnText, droppingWords: committedWords)
    }

    /// Nothing is struck through: Kitty shows the words exactly as they were heard.
    var liveRemoved: Set<Int> { [] }

    /// Kitty asks a question: what you said so far and the question both go into the chat, so the whole exchange stays visible.
    private func showQuestion(_ q: String) {
        let said = liveText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !said.isEmpty { appendYou(said) }
        lines.append(ChatLine(role: .kitty, text: q))
        kittyStore.add(q, kind: .question, chatID: chatID, groupID: note.groupID)
        committedWords = turnText.split(whereSeparator: { $0.isWhitespace }).count
        question = q
        stage = .question
    }

    /// Your words go into the chat. The first line of a turn that became a note carries the note's id, so it can be deleted.
    private func appendYou(_ text: String) {
        lines.append(ChatLine(role: .you, text: text, struck: liveRemoved))
    }

    /// Whether this line is a saved note that may be deleted now (not the note Kitty is still working on).
    func canDelete(_ line: ChatLine) -> Bool {
        guard let id = line.noteID else { return false }
        return !isBeingWorkedOn(id)
    }

    /// Whether this note is part of what Kitty is working on or showing a preview for.
    private func isBeingWorkedOn(_ id: UUID) -> Bool {
        guard stage == .thinking || proposal != nil else { return false }
        if id == note.id { return true }
        guard let gid = note.groupID else { return false }
        return notesStore.note(id)?.groupID == gid
    }

    func deleteNote(_ id: UUID) {
        guard !isBeingWorkedOn(id) else { return }
        notesStore.delete(id: id)
        lines.removeAll { $0.noteID == id }
    }

    // MARK: What a note shows

    /// The note being worked on right now, if any.
    var currentNoteID: UUID? { note.id }

    /// The tasks made from this note that still exist.
    func createdTaskIDs(for noteID: UUID) -> [UUID] {
        let ids = notesStore.group(of: noteID).flatMap(\.taskIDs)
        guard !ids.isEmpty else { return [] }                                                       // most notes made no tasks: nothing to look up
        let alive = Set(TaskStore.shared.tasks.map(\.id))
        var seen = Set<UUID>()
        return ids.filter { alive.contains($0) && seen.insert($0).inserted }
    }

    func createdCount(for noteID: UUID) -> Int { createdTaskIDs(for: noteID).count }

    /// Every task still saved that was made from the notes of this chat.
    var chatTaskIDs: Set<UUID> {
        let ids = notesStore.load(chat: chatID).flatMap(\.taskIDs)
        guard !ids.isEmpty else { return [] }
        let alive = Set(TaskStore.shared.tasks.map(\.id))
        return Set(ids.filter { alive.contains($0) })
    }

    /// A task made from this note that has details kept (the "Save task details" switch was on), for "See details".
    func taskWithDetails(for noteID: UUID) -> TaskItem? {
        createdTaskIDs(for: noteID).lazy.compactMap { id in TaskStore.shared.tasks.first { $0.id == id } }
            .first { TaskDetailsStore.shared.has($0.id) }
    }

    /// The status of a note that is already in the chat.
    func status(of line: ChatLine) -> NoteStatus? {
        guard let id = line.noteID else { return nil }
        let group = notesStore.group(of: id)
        guard group.last?.id == id else { return nil }                         // one status for what was written together: on its last bubble
        let inTurn = isInCurrentTurn(id)
        return NoteStatus.of(working: stage == .thinking && (inTurn || id == editingNoteID), previewForThisNote: proposal != nil && inTurn,
                             reviewPending: group.contains(where: \.reviewPending), createdCount: createdCount(for: id))
    }

    private func isInCurrentTurn(_ id: UUID) -> Bool {
        if id == note.id { return true }
        guard let gid = note.groupID else { return false }
        return notesStore.note(id)?.groupID == gid
    }

    /// Whether a note can be edited now: not while Kitty works or a preview or question is open, so two things never compete.
    var canEditNotes: Bool { proposal == nil && stage != .thinking && stage != .preview && stage != .question }

    /// The user edited a note. The same note and bubble change in place (never a second one), and the new words go through Kitty
    /// like a fresh note: a preview comes again if there are tasks in them.
    func editNote(_ id: UUID, to text: String) {
        let new = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard canEditNotes, !new.isEmpty, notesStore.updateText(id: id, text: new) else { return }
        if let i = lines.firstIndex(where: { $0.noteID == id }) { lines[i].text = new; lines[i].edited = true }
        readNote(id, text: notesStore.groupText(of: id))
    }

    /// A question about your notes ("what did I write about the baby?") is answered here from your notes, on the phone. The question is
    /// in the chat for now, but it is not a note and is not kept; neither is the answer. Returns whether it was one.
    private func answerFromNotes(_ text: String) -> Bool {
        guard NoteSearch.looksLikeNotesQuestion(text) else { return false }
        let found = NoteSearch.matches(query: text, in: notesStore.load())
        let said = text.trimmingCharacters(in: .whitespacesAndNewlines)
        lines.append(ChatLine(role: .you, text: said, struck: liveRemoved))
        lines.append(ChatLine(role: .kitty, text: NoteSearch.answer(for: found)))
        consumeTurnWords()
        stage = micOn ? .listening : .idle
        return true
    }

    /// "Review tasks": Kitty reads a note again, as it is, and the preview comes back.
    func reviewNote(_ id: UUID) {
        guard canEditNotes, notesStore.note(id) != nil else { return }
        readNote(id, text: notesStore.groupText(of: id))              // everything written together is read again
    }

    /// The words of a note go through Kitty like a fresh note that is that same note: it keeps its bubble, and its own bubble shows the work.
    private func readNote(_ id: UUID, text: String) {
        stopSpeaking()
        interrupt()
        resetTurn()
        turns.state.reset()
        if let saved = notesStore.note(id) { note.adopt(saved) }
        lastNoteID = id
        editingNoteID = id
        carry = text
        sessionText = ""
        turnText = text
        committedWords = text.split(whereSeparator: { $0.isWhitespace }).count      // the words are already in the chat: no live bubble
        beginProcessing(text: text, typed: true)
    }

    private func presentUpdate(noteID: UUID, plan: NoteUpdatePlan) {
        stopSpeaking()
        micWasOnForUpdate = micOn
        pauseListening()                    // nothing said while the sheet is open changes anything
        updateSession = NoteUpdateSession(noteID: noteID, plan: plan)
    }

    /// Does what was ticked, and remembers the new tasks on the note.
    func applyUpdate(_ choice: NoteUpdateChoice) {
        guard let session = updateSession else { return }
        let result = NoteUpdate.apply(session.plan, choice: choice, store: TaskStore.shared)
        notesStore.attach(id: session.noteID, taskIDs: result.added)
        closeUpdate()
    }

    func dismissUpdate() { closeUpdate() }

    private func closeUpdate() {
        updateSession = nil
        guard micWasOnForUpdate, active else { return }
        micWasOnForUpdate = false
        micWanted = true
        userMuted = false
        Task { await startMic() }
    }

    /// The status of the words still being worked on (the bubble at the bottom): only "working", while Kitty is thinking.
    var liveStatus: NoteStatus? { stage == .thinking ? .working : nil }

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
    /// A short note for the home screen ("Added 2 tasks") when something finished after the Talk screen was closed.
    @Published private(set) var notice: String?
    private var noticeTask: Task<Void, Never>?

    func post(_ text: String) {
        notice = text
        noticeTask?.cancel()
        noticeTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 4_000_000_000)
            guard !Task.isCancelled else { return }
            self?.notice = nil
        }
    }

    func clearNotice() {
        noticeTask?.cancel()
        notice = nil
    }
    /// What Siri asked Kitty to do, when it was more than "start listening" ("what are my tasks for today").
    private(set) var pendingRequest: String?

    /// Opens the conversation. With `request`, Kitty runs those words as if you had said them, speaks the answer and goes on listening.
    func requestConversation(request: String? = nil) {
        let text = request?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        pendingRequest = text.isEmpty ? nil : text
        conversationRequested = true
    }

    /// Hands the waiting request over, once.
    func takeRequest() -> String? {
        defer { pendingRequest = nil }
        return pendingRequest
    }
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

/// "What Kitty is doing": the steps of the turn as they happen. What was heard, what Swift did, the exact text sent to the model, the
/// model's answer as it is written, each search of your tasks, what Swift checked, and the result (or why it failed). It stays until
/// the next turn starts, so a slow or failed turn can be read afterwards.
struct LiveModelPanel: View {
    @ObservedObject var feed: LiveFeed
    let working: Bool
    /// Closed at first: while Kitty thinks, and beside the preview, the panel is one button, "See details". Tapping it opens the
    /// steps, and the way to close them is at the bottom, after the last step, where the reading ends.
    @State private var expanded: Bool

    init(feed: LiveFeed, working: Bool, startsOpen: Bool = false) {
        _feed = ObservedObject(wrappedValue: feed)
        self.working = working
        _expanded = State(initialValue: startsOpen)
    }

    /// The newest step in a few words, so the closed button says what Kitty is doing right now.
    private var latest: String {
        guard let step = feed.steps.last else { return "" }
        let first = step.text.split(separator: "\n", omittingEmptySubsequences: true).first.map(String.init) ?? ""
        return LiveStepRow.label(step.stage, text: first) + (first.isEmpty ? "" : ": " + first)
    }

    var body: some View {
        Group { panel }
            // A new turn starts closed again: what the last turn left open is not shown over the next one.
            .onChange(of: feed.started) { _, _ in expanded = false }
    }

    @ViewBuilder private var panel: some View {
        if !feed.steps.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                if expanded {
                    title
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(feed.steps) { step in LiveStepRow(step: step) }
                    }
                    collapse
                } else {
                    seeDetails
                }
            }
            .padding(12)
            .background(Color.cardBackground, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(Color.secondary.opacity(0.15)))
        }
    }

    /// The closed state: one button, with the live status line under it while the model works, and Share beside it.
    private var seeDetails: some View {
        HStack(spacing: 8) {
            Button { withAnimation { expanded = true } } label: {
                HStack(spacing: 8) {
                    Image(systemName: working ? "waveform.path.ecg" : "doc.text.magnifyingglass").foregroundStyle(working ? Color.accentColor : .secondary)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("See details").font(.subheadline.weight(.semibold))
                        Text(latest).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                    Spacer()
                    elapsed
                    Image(systemName: "chevron.down").font(.caption).foregroundStyle(.secondary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityHint("Shows what Kitty is doing, step by step")
            TraceShareButton()
        }
    }

    /// The open state's heading. It is not a button: closing is at the bottom.
    private var title: some View {
        HStack(spacing: 8) {
            Image(systemName: working ? "waveform.path.ecg" : "checkmark.circle").foregroundStyle(working ? Color.accentColor : .secondary)
            Text("What Kitty is doing").font(.subheadline.weight(.semibold))
            Spacer()
            elapsed
            TraceShareButton()
        }
    }

    /// After the last step, so it is reached at the end of the reading and the thread stays where it was.
    private var collapse: some View {
        Button { withAnimation { expanded = false } } label: {
            HStack(spacing: 6) {
                Spacer()
                Image(systemName: "chevron.up").font(.caption.weight(.bold))
                Text("Hide details").font(.footnote.weight(.semibold))
                Spacer()
            }
            .foregroundStyle(.secondary)
            .padding(.vertical, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// Running seconds while the turn works; the total once it has finished.
    @ViewBuilder private var elapsed: some View {
        if working, let start = feed.started {
            TimelineView(.periodic(from: .now, by: 0.5)) { ctx in
                Text(String(format: "%.0f s", max(0, ctx.date.timeIntervalSince(start)))).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }
        } else if let last = feed.steps.last {
            Text(String(format: "%.1f s", last.at)).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
        }
    }
}

/// The trace of the turn on screen (and the last one), as a plain text file. The text is built when the share sheet is used, so
/// it holds everything up to that moment, even while a model call is still running.
nonisolated struct TraceExport: Transferable {
    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(exportedContentType: .plainText) { _ in
            let stamp = String(Int(Date().timeIntervalSince1970))
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("Kitty-trace-\(stamp).txt")
            try TurnTraceFormat.text().write(to: url, atomically: true, encoding: .utf8)
            return SentTransferredFile(url)
        }
    }
}

struct TraceShareButton: View {
    var titled = false

    var body: some View {
        ShareLink(item: TraceExport(), preview: SharePreview("Kitty trace")) {
            if titled {
                Label("Share trace", systemImage: "square.and.arrow.up").font(.caption.weight(.semibold))
            } else {
                Image(systemName: "square.and.arrow.up").font(.subheadline)
            }
        }
        .buttonStyle(.plain)
        .foregroundStyle(Color.accentColor)
        .accessibilityLabel("Share trace")
        .accessibilityHint("Shares everything sent to the model and written back in this turn")
    }
}

fileprivate struct LiveStepRow: View {
    let step: LiveStep
    @State private var open = false

    private var lines: [String] { step.text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init) }
    private var first: String { lines.first ?? "" }
    private var rest: String { lines.dropFirst().joined(separator: "\n") }
    /// A step opens only when tapped. The model's answer while it is written shows a short readable tail instead, and a long text
    /// shows its first lines with "Show all".
    private var isOpen: Bool { open }
    @State private var showAll = false
    private static let openLines = 14
    private static let tailCharacters = 320

    /// The last few lines of the answer as written so far, at a normal size.
    private var tail: String {
        let text = rest.replacingOccurrences(of: "\n", with: " ")
        return text.count > Self.tailCharacters ? "…" + text.suffix(Self.tailCharacters) : text
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(String(format: "%.1f", step.at)).font(.caption2.monospacedDigit()).foregroundStyle(.tertiary).frame(width: 34, alignment: .trailing)
                Text(Self.label(step.stage, text: first)).font(.caption.weight(.semibold)).foregroundStyle(Self.color(step.stage, text: first))
                Text(first).font(.caption).foregroundStyle(.secondary).lineLimit(isOpen ? nil : 2)
                if !rest.isEmpty {
                    Spacer(minLength: 0)
                    Image(systemName: open ? "chevron.up" : "chevron.down").font(.caption2).foregroundStyle(.tertiary)
                }
            }
            if isOpen, !rest.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text(Self.sectioned(rest, stage: step.stage))
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(showAll ? nil : Self.openLines)
                        .textSelection(.enabled)
                    if !showAll, rest.split(separator: "\n", omittingEmptySubsequences: false).count > Self.openLines {
                        Button("Show all") { showAll = true }.font(.caption.weight(.semibold)).buttonStyle(.plain)
                    }
                }
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            } else if step.writing, !rest.isEmpty {
                Text(tail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(6)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { if !rest.isEmpty { withAnimation { open.toggle() } } }
    }

    /// The labels of the prompt's sections, in bold, so what was sent reads as STATE, ITEMS, RECENT CHANGES, USER and so on.
    static let promptSections = ["STATE:", "QUESTION:", "ITEMS", "RECENT CHANGES", "LINES SO FAR", "THIS LINE:", "LIKELY ITEMS:", "ORIGINAL REQUEST:", "HEARD BUT NOT MADE INTO TASKS:", "USER:",
                                 "Today:", "Transcript:", "Pending draft", "Clarification so far:", "Reference vocabulary", "left out to fit:"]

    static func sectioned(_ text: String, stage: String) -> AttributedString {
        guard stage == "TO MODEL" || stage == "BUDGET" else { return AttributedString(text) }
        var out = AttributedString()
        for (n, line) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
            var row = AttributedString((n == 0 ? "" : "\n") + line)
            if let label = promptSections.first(where: { line.hasPrefix($0) }), let r = row.range(of: label) {
                row[r].font = .system(.caption2, design: .monospaced).bold()
                row[r].foregroundColor = .primary
            }
            out += row
        }
        return out
    }

    /// The step where the app, not the model, searched the saved tasks (`searched: day today -> 3 results`).
    static func isSearch(_ stage: String, _ text: String) -> Bool { stage == "SWIFT" && text.hasPrefix("searched:") }

    static func label(_ stage: String, text: String = "") -> String {
        if isSearch(stage, text) { return "Swift searched" }
        switch stage {
        case "HEARD": return "Heard"
        case "CLEANED": return "Cleaned"
        case "SWIFT": return "Swift"
        case "TO MODEL": return "Sent to model"
        case "INSTRUCTIONS": return "Instructions sent"
        case "SCHEMA": return "Schema sent"
        case "MODEL WRITING": return "Model writing"
        case "FROM MODEL": return "Model answered"
        case "BUDGET": return "Budget"
        case "LINE": return "New line"
        case "RESULT": return "Result"
        case "WARNING": return "Warning"
        case "CLARIFY": return "Question"
        default: return stage.capitalized
        }
    }

    static func color(_ stage: String, text: String = "") -> Color {
        if isSearch(stage, text) { return .blue }
        switch stage {
        case "WARNING": return .orange
        case "RESULT": return .green
        case "TO MODEL", "MODEL WRITING", "FROM MODEL", "INSTRUCTIONS", "SCHEMA": return .purple
        case "BUDGET": return .teal
        case "LINE": return .orange
        default: return .secondary
        }
    }
}

/// When the thread may move by itself. A user who is scrolling, or who has scrolled up to read, is never pulled to the bottom.
enum AutoScroll {
    enum Cause {
        case line       // a new line of the chat, or the stage changed: the answer to what was just said
        case words      // the user's words as they speak
        case step       // a new step of the live panel
    }

    static func shouldFollow(_ cause: Cause, userTouching: Bool, nearBottom: Bool) -> Bool {
        guard !userTouching else { return false }
        switch cause {
        case .line: return true                 // a new answer appears: show it, even if the user had scrolled up
        case .words, .step: return nearBottom   // background updates only follow a reader who is already at the bottom
        }
    }
}

struct ConversationView: View {
    @ObservedObject var convo: VoiceConversation
    var seed: String? = nil
    var seedIsVoice = false
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @State private var typed = ""
    @State private var typedFocused = false
    @State private var sheet: FilterSheet?
    @State private var editTarget: DraftEditTarget?
    /// Lists on a review card that were opened past the first few tasks (by list name; a card is short-lived).
    @State private var openedLists: Set<String> = []
    /// The thread follows new content only while the user is not scrolling it and is at (or near) the bottom.
    @State private var touching = false
    @State private var nearBottom = true
    @State private var noteToDelete: VoiceConversation.ChatLine?     // asks "Delete this note?" before anything is removed
    @State private var noteSheet: NoteSheet?                          // details or tasks of a note
    @State private var stopAsk = false                                // asks "Stop?" when the working indicator is tapped
    @State private var previewJump = 0                                // a tap on "Tasks ready" scrolls to the preview
    @State private var noteEditTarget: NoteEditTarget?                // the note open in the editor
    @State private var previewOpen = false                            // the full preview, opened from the one-line bar
    @State private var savedTrayID: UUID?                             // the tray shows the tasks saved from this note, with the same box to change them
    @ObservedObject private var taskStore = TaskStore.shared
    @State private var tasksTray = false                              // the tray shows this chat's tasks, narrowed by the chip that was tapped
    @State private var trayFilter = ChatTaskFilter.open
    @State private var trayDetent = PresentationDetent.medium
    @State private var trayTyped = ""
    @State private var trayFocused = false

    var body: some View {
        ZStack {
            Color.screenBackground.ignoresSafeArea()
                .onTapGesture { typedFocused = false }
            VStack(spacing: 0) {
                topBar
                thread
                bottomBar
            }
        }
        .onAppear {
            convo.appForegroundChanged(scenePhase == .active)
            convo.open(seed: seed, voice: seedIsVoice)
        }
        .onDisappear { convo.close() }
        .onChange(of: scenePhase) { _, phase in convo.appForegroundChanged(phase == .active) }
        .sheet(item: $sheet) { item in TasksView(filter: item.filter) }
        .sheet(isPresented: $previewOpen) { previewSheet }
        .onChange(of: previewOpen) { _, open in convo.setTray(open); if !open { savedTrayID = nil; tasksTray = false } }
        .sheet(item: $editTarget, onDismiss: { convo.endManualEdit(); if convo.proposal != nil { previewOpen = true } }) { target in
            DraftEditSheet(convo: convo, target: target)
        }
    }

    private func openEditor(_ target: DraftEditTarget) {
        convo.beginManualEdit()
        previewOpen = false                      // one sheet at a time: the preview comes back when the editor closes
        Task { try? await Task.sleep(nanoseconds: 450_000_000); editTarget = target }
    }

    // MARK: Top bar

    private var topBar: some View {
        HStack {
            Menu {
                Toggle("Read replies aloud", isOn: $convo.speakReplies)
                Toggle("Listen for English (India)", isOn: $convo.indianEnglish)
                Picker("Speech engine", selection: $convo.speechEngine) {
                    ForEach(SpeechEngineChoice.menuChoices) { choice in
                        Text(choice.isAvailable ? choice.label : choice.label + " (not installed)").tag(choice)
                    }
                }
                Toggle("Live model view", isOn: $convo.liveView)
                Toggle("Save task details", isOn: $convo.saveDetails)
                Button("Delete saved task details", role: .destructive) { convo.detailsStore.clear(); UtteranceStore.shared.clear() }
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
                LazyVStack(alignment: .leading, spacing: 14) {
                    if convo.lines.isEmpty && convo.turnText.isEmpty && convo.stage != .thinking { welcome }
                    ForEach(Array(convo.lines.enumerated()), id: \.element.id) { index, line in
                        if index == 0 || !Calendar.current.isDate(line.date, inSameDayAs: convo.lines[index - 1].date) { DaySeparator(date: line.date) }
                        lineView(line)
                    }
                    if !convo.liveText.isEmpty { youBubble }
                    responseArea
                    Color.clear.frame(height: 1).id("bottom")
                }
                .padding(.horizontal, 16)
                .padding(.top, 8)
                .padding(.bottom, 12)
            }
            .scrollIndicators(.hidden)
            .scrollDismissesKeyboard(.interactively)
            .simultaneousGesture(TapGesture().onEnded { typedFocused = false })
            .onScrollPhaseChange { _, phase in touching = phase == .interacting || phase == .decelerating }
            .onScrollGeometryChange(for: Bool.self) { g in
                g.contentOffset.y + g.containerSize.height >= g.contentSize.height - 80
            } action: { _, near in nearBottom = near }
            .task {
                // Saved notes load as the screen opens: start at the newest, without animating through them.
                try? await Task.sleep(nanoseconds: 120_000_000)
                scrollDown(proxy, animated: false)
            }
            .confirmationDialog("Delete this note?", isPresented: Binding(get: { noteToDelete != nil },
                                                                           set: { if !$0 { noteToDelete = nil } }),
                                titleVisibility: .visible) {
                Button("Delete note", role: .destructive) {
                    if let id = noteToDelete?.noteID { convo.deleteNote(id) }
                    noteToDelete = nil
                }
                Button("Cancel", role: .cancel) { noteToDelete = nil }
            } message: {
                Text("Tasks already made from it stay.")
            }
            .confirmationDialog("Stop working on this?", isPresented: $stopAsk, titleVisibility: .visible) {
                Button("Stop", role: .destructive) { convo.cancelWork() }
                Button("Keep going", role: .cancel) {}
            }
            .sheet(item: $noteSheet) { noteSheetView($0) }
            .sheet(item: Binding(get: { convo.updateSession }, set: { if $0 == nil { convo.dismissUpdate() } })) { session in
                NoteUpdateSheet(plan: session.plan, onApply: { convo.applyUpdate($0) }, onCancel: { convo.dismissUpdate() })
            }
            .fullScreenCover(item: $noteEditTarget) { target in
                NoteEditorView(original: target.text) { convo.editNote(target.id, to: $0) }
            }
            .onChange(of: previewJump) { _, _ in withAnimation { proxy.scrollTo("preview", anchor: .top) } }
            .onChange(of: convo.turnText) { _, _ in follow(.words, proxy) }
            .onChange(of: convo.lines.count) { _, _ in follow(.line, proxy) }
            .onChange(of: convo.stage) { _, _ in follow(.line, proxy) }
            // Only a step that is ADDED moves the thread. The model's streamed answer grows a step many times a second and must not.
            .onReceive(LiveFeed.shared.$steps.map(\.count).removeDuplicates()) { count in
                if convo.liveView, count > 0 { follow(.step, proxy) }
            }
        }
    }

    /// Follows new content to the bottom unless the user is scrolling or has scrolled away (`AutoScroll`).
    private func follow(_ cause: AutoScroll.Cause, _ proxy: ScrollViewProxy) {
        guard AutoScroll.shouldFollow(cause, userTouching: touching, nearBottom: nearBottom) else { return }
        scrollDown(proxy, animated: cause != .step)
    }

    private func scrollDown(_ proxy: ScrollViewProxy, animated: Bool = true) {
        if animated { withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo("bottom", anchor: .bottom) } }
        else { proxy.scrollTo("bottom", anchor: .bottom) }
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

    /// Your words as you said them: line breaks you typed stay line breaks, runs of spaces collapse to one.
    private func spoken(_ text: String, struck: Set<Int>) -> AttributedString {
        var out = AttributedString()
        for (i, piece) in SpokenText.pieces(text).enumerated() {
            var part = AttributedString(piece.separator + piece.word)
            if struck.contains(i) {
                part.strikethroughStyle = .single
                part.foregroundColor = .secondary
            }
            out += part
        }
        return out
    }

    /// Your words as a bubble. What Kitty is doing with them is one small thing in the bottom-right corner, like the ticks in a chat.
    private func youBubbleView(_ text: String, struck: Set<Int> = [], live: Bool, edited: Bool = false,
                               status: NoteStatus? = nil, onStatus: (() -> Void)? = nil, lineLimit: Int? = nil, onMore: (() -> Void)? = nil) -> some View {
        HStack {
            Spacer(minLength: 48)
            VStack(alignment: .trailing, spacing: 4) {
                (Text(spoken(text, struck: struck)) + Text(live ? " …" : "").foregroundStyle(.secondary))
                    .font(.body)
                    .multilineTextAlignment(.leading)
                    .lineLimit(lineLimit)
                if lineLimit != nil, let onMore {
                    Button("Read more", action: onMore).font(.footnote.weight(.semibold)).buttonStyle(.plain).foregroundStyle(Color.accentColor)
                }
                if edited || status != nil {
                    HStack(spacing: 8) {
                        if edited { Text("Edited").font(.caption2).foregroundStyle(.secondary) }
                        if let status { NoteStatusChip(status: status, onTap: onStatus) }
                    }
                }
            }
            .padding(12)
            .background(Color.accentColor.opacity(0.14), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        }
    }

    private var youBubble: some View {
        VStack(alignment: .trailing, spacing: 6) {
            youBubbleView(convo.liveText, struck: convo.liveRemoved, live: convo.stage == .listening,
                          status: convo.liveStatus, onStatus: convo.canCancelWork ? { stopAsk = true } : nil)
                .contextMenu {
                    Button("See details", systemImage: "doc.text.magnifyingglass") { noteSheet = .details(nil) }
                    if convo.canCancelWork { Button("Stop", systemImage: "stop.circle", role: .destructive) { convo.cancelWork() } }
                }
        }
    }

    /// What a tap on a note's status does: "Tasks ready" goes to the preview, "N tasks created" opens them.
    private func noteChipAction(_ line: VoiceConversation.ChatLine) -> (() -> Void)? {
        guard let status = convo.status(of: line) else { return nil }
        switch status {
        case .ready: return { previewOpen = true }
        case .created: return { if let id = line.noteID { savedTrayID = id; trayDetent = .large; previewOpen = true } }
        case .review: return convo.canEditNotes ? { if let id = line.noteID { convo.reviewNote(id) } } : nil
        case .working: return convo.canCancelWork ? { stopAsk = true } : nil
        }
    }

    @ViewBuilder
    private func noteMenu(_ line: VoiceConversation.ChatLine) -> some View {
        Button("Copy", systemImage: "doc.on.doc") { UIPasteboard.general.string = line.text }
        if let id = line.noteID {
            Button("Edit", systemImage: "pencil") { noteEditTarget = NoteEditTarget(id: id, text: line.text) }
                .disabled(!convo.canEditNotes)
            Button("See details", systemImage: "doc.text.magnifyingglass") { noteSheet = .details(id) }
            if convo.createdCount(for: id) > 0 { Button("View tasks", systemImage: "checklist") { savedTrayID = id; trayDetent = .large; previewOpen = true } }
        }
        if convo.canDelete(line) {
            Button("Delete", systemImage: "trash", role: .destructive) { noteToDelete = line }
        }
    }

    @ViewBuilder
    private func noteSheetView(_ sheet: NoteSheet) -> some View {
        switch sheet {
        case .details(let id):
            NoteDetailsSheet(task: id.flatMap { convo.taskWithDetails(for: $0) },
                             showLive: (id == nil || id == convo.lastNoteID) && !LiveFeed.shared.steps.isEmpty,
                             working: convo.stage == .thinking)
        case .tasks(let id):
            NoteTasksSheet(ids: convo.createdTaskIDs(for: id))
        case .read(let id):
            NoteReadSheet(text: NotesStore.shared.note(id)?.text ?? "")
        }
    }

    @ViewBuilder
    private func lineView(_ line: VoiceConversation.ChatLine) -> some View {
        switch line.role {
        case .you:
            youBubbleView(line.text, struck: line.struck, live: false, edited: line.edited, status: convo.status(of: line), onStatus: noteChipAction(line),
                          lineLimit: line.noteID != nil && line.text.count > 600 ? 10 : nil,
                          onMore: line.noteID.map { id in { noteSheet = .read(id) } })
                .contextMenu { noteMenu(line) }
                .accessibilityActions {
                    if let id = line.noteID {
                        if convo.canEditNotes { Button("Edit note") { noteEditTarget = NoteEditTarget(id: id, text: line.text) } }
                        Button("See details") { noteSheet = .details(id) }
                        if convo.createdCount(for: id) > 0 { Button("View tasks") { noteSheet = .tasks(id) } }
                    }
                    if convo.canDelete(line) { Button("Delete note") { noteToDelete = line } }
                }
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
            // The preview stays on screen (dimmed) while the model works: it is never swapped for a spinner.
            if let p = convo.proposal { previewBar(p, dimmed: true).id("preview") }
        case .preview:
            if let p = convo.proposal { previewBar(p, dimmed: false).id("preview") }
        case .question:
            questionCard
        case .listening, .idle:
            if let p = convo.proposal {
                previewBar(p, dimmed: convo.isStale).id("preview")
            } else if !convo.question.isEmpty {
                questionCard
            } else if let error = convo.errorMessage {
                Text(error)
                    .font(.footnote)
                    .foregroundStyle(.red)
                    .padding(.horizontal, 4)
            } else if let note = convo.micNotice {
                Text(note)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 4)
            } else if let notice = convo.speechNotice {
                Text(notice)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 4)
            }
        }
    }

    /// The question itself is in the chat above, so this is only a quiet hint.
    private var questionCard: some View {
        Text(convo.micOn ? "Just answer. I'm listening." : "Just answer. Type it below, or tap the mic.")
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

    /// One task of a review card: a tile with its title and what Kitty understood about it.
    @ViewBuilder
    private func proposalRow(_ row: PreviewRow, p: Proposal, dimmed: Bool) -> some View {
                let editable = row.draftID != nil && !dimmed && !p.destructive
                SwipeToDeleteRow(enabled: editable, label: "Delete \(row.title)") {
                    if let id = row.draftID { withAnimation { convo.deleteDraftItem(id) } }
                } content: {
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: row.icon)
                        .foregroundStyle(p.destructive ? Color.red : Color.accentColor)
                        .frame(width: 22)
                        .padding(.top, 2)
                    VStack(alignment: .leading, spacing: 6) {
                        Text(row.title).font(.system(.body, design: .rounded).weight(.semibold))
                        DetailLinesView(lines: row.details)
                        let status = row.tags.filter { !$0.isLabel }
                        if !status.isEmpty {
                            FlowLayout(spacing: 6) {
                                ForEach(status) { tag in
                                    TagPill(text: tag.text, icon: tag.icon, color: color(tag.color))
                                }
                            }
                        }
                        LabelRow(labels: row.tags.filter(\.isLabel).map(\.text), scrolls: false)
                    }
                    Spacer(minLength: 0)
                    if editable {
                        Image(systemName: "pencil")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .padding(.top, 4)
                    }
                }
                // Each task is its own tile: padded inside, a gap between tiles, rounded to match the card.
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: SwipeToDeleteRow<EmptyView>.tileRadius, style: .continuous))
                .contentShape(Rectangle())
                .onTapGesture {
                    if editable, let id = row.draftID { openEditor(DraftEditTarget(itemID: id)) }
                }
                .accessibilityElement(children: .combine)
                .accessibilityHint(editable ? "Double tap to change this task" : "")
                .accessibilityAddTraits(editable ? .isButton : [])
                }
    }

    /// The most tasks of one list shown before "Show all".
    private static let sectionPreview = 6

    /// One list on a review card: its name and a line saying whether it is new, then its tasks. A list is a group of tasks, never a
    /// task of its own, and its name is shown as the user said it.
    @ViewBuilder
    private func proposalSection(_ section: PreviewSection, p: Proposal, dimmed: Bool) -> some View {
        let key = section.listName ?? ""
        let open = openedLists.contains(key) || section.rows.count <= Self.sectionPreview + 1
        let shown = open ? section.rows : Array(section.rows.prefix(Self.sectionPreview))
        VStack(alignment: .leading, spacing: 8) {
            if section.listName != nil {
                HStack(spacing: 8) {
                    Image(systemName: section.icon).foregroundStyle(Color.accentColor).frame(width: 22)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(section.listName ?? "").font(.system(.subheadline, design: .rounded).weight(.bold))
                        Text(section.subtitle).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                }
                .accessibilityElement(children: .combine)
                .accessibilityAddTraits(.isHeader)
            } else if p.sections.count > 1 {
                Text(section.subtitle).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            }
            ForEach(shown) { row in proposalRow(row, p: p, dimmed: dimmed) }
            if !open {
                Button { withAnimation { _ = openedLists.insert(key) } } label: {
                    Text("Show all \(section.rows.count)").font(.footnote.weight(.medium))
                }
                .buttonStyle(.plain)
                .foregroundStyle(Color.accentColor)
            }
        }
    }

    /// What the thread shows of a preview: one quiet line. The full card opens in a sheet when you tap it.
    private func previewBar(_ p: Proposal, dimmed: Bool) -> some View {
        let rows = p.sections.isEmpty ? p.rows : p.sections.flatMap(\.rows)
        let drafts = rows.filter { $0.draftID != nil }.count
        let needsYou = p.destructive || p.recovery != nil || p.flagQuestionItemID != nil
        let headline = dimmed ? "Updating…"
            : drafts > 0 && !needsYou ? "\(drafts) \(drafts == 1 ? "task" : "tasks") ready to review"
            : p.title
        let tint: Color = p.destructive ? .red : (p.recovery != nil || p.flagQuestionItemID != nil ? .orange : .accentColor)
        return Button { trayDetent = .medium; previewOpen = true } label: {
            HStack(spacing: 10) {
                if dimmed { ProgressView().controlSize(.small) }
                else { Image(systemName: needsYou ? "exclamationmark.circle.fill" : "checklist").foregroundStyle(tint) }
                VStack(alignment: .leading, spacing: 2) {
                    Text(headline).font(.subheadline.weight(.semibold)).foregroundStyle(Color.primary).lineLimit(1)
                    if !dimmed {
                        Text(rows.prefix(3).map(\.title).joined(separator: " · "))
                            .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
                Spacer(minLength: 8)
                Text("Review").font(.footnote.weight(.semibold)).foregroundStyle(tint)
                Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(Color.cardBackground, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .shadow(color: .black.opacity(0.05), radius: 5, y: 1)
            .opacity(dimmed ? 0.7 : 1)
        }
        .buttonStyle(.plain)
        .accessibilityHint("Opens the tasks Kitty found so you can save them")
    }

    /// The full preview, in a tray. Everything about these tasks happens here: look, change by hand, say or type a change, save. What is
    /// said or typed in the tray is an instruction for the preview and never appears in the chat. It closes by itself on save or discard.
    private var previewSheet: some View {
        NavigationStack {
            Group {
                if let p = convo.proposal {
                    ScrollView { proposalCard(p, dimmed: convo.isStale || convo.stage == .thinking).padding(16) }
                } else if tasksTray || savedTrayID != nil {
                    trayTaskList
                }
            }
            .background(Color.screenBackground)
            .navigationTitle(convo.proposal != nil ? "Your tasks" : "Tasks")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { previewOpen = false } } }
            .safeAreaInset(edge: .bottom) { trayInput }
        }
        .presentationDetents([.medium, .large], selection: $trayDetent)
        .presentationDragIndicator(.visible)
        .onChange(of: convo.proposal == nil) { _, gone in if gone && savedTrayID == nil && !tasksTray { previewOpen = false } }     // a task view stays after a change
    }

    /// The tray's own box and mic: a change to the tasks, in words.
    private var trayInput: some View {
        if convo.proposal == nil { return AnyView(compactTrayInput) }
        return AnyView(previewTrayInput)
    }

    /// With only tasks on screen the box is one slim line and the mic a small button, so the tasks keep the room.
    private var compactTrayInput: some View {
        HStack(spacing: 10) {
            TypedInputBox(placeholder: "Change these tasks…", text: $trayTyped, isFocused: $trayFocused, maxLines: 3) { sendTrayInstruction() }
            Button { convo.micTapped() } label: {
                Image(systemName: convo.micOn ? "mic.fill" : "mic.slash.fill")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(.white)
                    .frame(width: 40, height: 40)
                    .background(convo.micOn ? Color.accentColor : Color.gray.opacity(0.55), in: Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(convo.micOn ? "Microphone on. Tap to stop listening" : "Microphone off. Tap to listen")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 6)
        .background(.bar)
    }

    private var previewTrayInput: some View {
        HStack(alignment: .bottom, spacing: 12) {
            TypedInputBox(placeholder: convo.proposal == nil ? "Change these tasks, e.g. make it two litres" : "Change something, e.g. remove the milk", text: $trayTyped, isFocused: $trayFocused) { sendTrayInstruction() }
            MicButton(on: convo.micOn, busy: convo.stage == .thinking, speaking: convo.isSpeaking) { convo.micTapped() }
                .alignmentGuide(.bottom) { $0.height / 2 + oneLineBoxHeight / 2 }
        }
        .padding(.horizontal, 16)
        .padding(.top, 6)
        .background(.bar)
    }

    /// This chat's tasks, saved and still there.
    private var chatTasks: [TaskItem] {
        let ids = convo.chatTaskIDs
        return ids.isEmpty ? [] : taskStore.tasks.filter { ids.contains($0.id) }
    }

    /// The chips above the chat's box: only this chat's tasks, and only the views that have tasks in them. Nothing when it has none.
    private var peekChips: [PeekChip] {
        let kinds = ChatTaskFilter.available(in: chatTasks)
        return kinds.filter { $0.filter != .all }.map { kind in
            PeekChip(id: kind.filter.id, title: kind.filter.title, icon: Self.peekIcon(kind.filter), count: kind.count, late: kind.filter == .overdue)
        }
    }

    private static func peekIcon(_ filter: ChatTaskFilter) -> String? {
        switch filter {
        case .today: return "sun.max.fill"
        case .overdue: return "exclamationmark.triangle.fill"
        case .done: return "checkmark.circle.fill"
        case .open: return "circle"
        case .all: return nil
        }
    }

    /// A tap on a chip opens the tray on that view; the grip (or a swipe up) opens it on the open tasks.
    private func openPeek(_ chipID: String?) {
        let open = chatTasks
        guard !open.isEmpty else { return }
        savedTrayID = nil
        trayFilter = chipID.flatMap { ChatTaskFilter(rawValue: $0) } ?? (ChatTaskFilter.open.matchesAny(in: open) ? .open : .all)
        tasksTray = true
        trayDetent = .large
        previewOpen = true
    }

    /// The tray's tasks and nothing else, the same list the home screen uses, narrowed to this chat.
    private var trayTaskList: some View {
        let saved = savedTrayID.map { Set(convo.createdTaskIDs(for: $0)) } ?? []
        let tasks = tasksTray ? chatTasks : taskStore.tasks.filter { saved.contains($0.id) }
        return TaskTrayList(tasks: tasks, lists: taskStore.profiles, filter: tasksTray ? $trayFilter : .constant(.all))
    }

    private func sendTrayInstruction() {
        let text = trayTyped.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        trayTyped = ""
        convo.submitTyped(text, asNote: false)
    }

    private func proposalCard(_ p: Proposal, dimmed: Bool) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: p.destructive || p.recovery != nil ? "exclamationmark.triangle.fill" : "sparkles")
                    .foregroundStyle(p.destructive ? Color.red : (p.recovery != nil ? Color.orange : Color.accentColor))
                Text(dimmed ? "Updating as you speak…" : p.title).font(.headline)
                Spacer()
            }

            if p.sections.isEmpty {
                VStack(spacing: 8) {
                    ForEach(p.rows) { row in proposalRow(row, p: p, dimmed: dimmed) }
                }
            } else {
                VStack(alignment: .leading, spacing: 14) {
                    ForEach(p.sections) { section in proposalSection(section, p: p, dimmed: dimmed) }
                }
            }

            if !dimmed, !p.destructive, p.rows.contains(where: { $0.draftID != nil }) {
                Button { openEditor(DraftEditTarget(itemID: nil)) } label: {
                    Label("Add a task", systemImage: "plus.circle")
                        .font(.footnote.weight(.medium))
                }
                .buttonStyle(.plain)
                .foregroundStyle(Color.accentColor)
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
                            Button { convo.submitTyped("also add \(text)", asNote: false) } label: {
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
                    .foregroundStyle(p.recovery == nil ? Color.primary : Color.orange)
            }

            // A flagged task nobody has decided on: include it or remove it. Save below still saves everything shown.
            if let flagged = p.flagQuestionItemID, !dimmed {
                FlowLayout(spacing: 8) {
                    Button { convo.includeDraftItem(flagged) } label: {
                        Label("Include", systemImage: "checkmark.circle").font(.footnote.weight(.semibold)).lineLimit(1)
                    }
                    .buttonStyle(.bordered)
                    .buttonBorderShape(.capsule)
                    Button { convo.deleteDraftItem(flagged) } label: {
                        Label("Remove", systemImage: "minus.circle").font(.footnote.weight(.semibold)).lineLimit(1)
                    }
                    .buttonStyle(.bordered)
                    .buttonBorderShape(.capsule)
                    .tint(.secondary)
                    Button { openEditor(DraftEditTarget(itemID: flagged)) } label: {
                        Label("See what you said", systemImage: "text.quote").font(.footnote.weight(.semibold)).lineLimit(1)
                    }
                    .buttonStyle(.bordered)
                    .buttonBorderShape(.capsule)
                    .tint(.secondary)
                }
            }

            // The last words could not be applied: the list above is as it was. Try the same words again, or fix an item by hand.
            if let r = p.recovery, !dimmed {
                FlowLayout(spacing: 8) {
                    Button { convo.submitTyped(r.retryWords, asNote: false) } label: {
                        Label("Try again", systemImage: "arrow.clockwise").font(.footnote.weight(.semibold)).lineLimit(1)
                    }
                    .buttonStyle(.bordered)
                    .buttonBorderShape(.capsule)
                    ForEach(r.items, id: \.id) { item in
                        Button { openEditor(DraftEditTarget(itemID: item.id)) } label: {
                            Label("Edit “\(item.title)”", systemImage: "pencil").font(.footnote.weight(.semibold)).lineLimit(1).truncationMode(.tail)
                        }
                        .buttonStyle(.bordered)
                        .buttonBorderShape(.capsule)
                    }
                }
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
                    Label(p.confirmLabel, systemImage: p.destructive ? "trash" : "checkmark")
                        .frame(maxWidth: .infinity, minHeight: 44)
                }
                .buttonStyle(.borderedProminent)
                .buttonBorderShape(.capsule)
                .tint(p.destructive ? Color.red : Color.accentColor)
            }
            .disabled(dimmed)

            Text(p.destructive ? "Say “yes” or tap to confirm."
                 : p.flagQuestionItemID != nil ? "Say “yes” to include it or “no” to remove it. Nothing is saved until you tap Save, and Save saves every task shown here."
                 : "Nothing is saved until you tap Save or say “yes”. Keep talking, tap a task to change it, or swipe it left to remove it.")
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
        ConversationStatus.text(stage: convo.stage, micOn: convo.micOn, isSpeaking: convo.isSpeaking,
                                hasWords: !convo.turnText.isEmpty,
                                needsTask: convo.stage == .listening && !convo.turnText.isEmpty
                                    && !TaskMeaning.hasContent(VoiceTurnManager.splitFinalizer(convo.turnText).text))
    }

    private func sendTyped() {
        let text = typed.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        typed = ""
        convo.submitTyped(text)
    }

    /// Height of the typing box with one line in it (its padding plus one line of body text).
    @ScaledMetric(relativeTo: .body) private var oneLineBoxHeight: CGFloat = 44

    private var bottomBar: some View {
        VStack(spacing: 8) {
            Text(statusText)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .multilineTextAlignment(.center)
                .frame(minHeight: 16)
            if !peekChips.isEmpty {
                TaskPeekBar(chips: peekChips) { openPeek($0) }
                    .padding(.horizontal, -16)          // the bar runs edge to edge; its first chip lines up with the box
            }
            HStack(alignment: .bottom, spacing: 12) {
                // The same box as the home screen (`TypedInputBox`).
                TypedInputBox(placeholder: "Type a message", text: $typed, isFocused: $typedFocused) { sendTyped() }
                // The mic's centre sits level with the middle of a one-line box (the mic is taller than the box, so bottoms alone
                // would put it too high); when the box grows, the mic stays level with its last line.
                MicButton(on: convo.micOn, busy: convo.stage == .thinking, speaking: convo.isSpeaking) { convo.micTapped() }
                    .alignmentGuide(.bottom) { $0.height / 2 + oneLineBoxHeight / 2 }
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 6)
        .padding(.bottom, 0)        // the mic's frame already reaches below the box
    }
}

/// The microphone: pulses while Kitty is listening.
struct MicButton: View {
    let on: Bool
    var busy = false               // Kitty is working on what you said: a ring turns around the button, the mic is still a switch
    var speaking = false           // Kitty is talking: the button becomes "stop"
    var action: () -> Void
    @State private var pulse = false

    private var label: String {
        if speaking { return "Stop Kitty speaking" }
        if on { return busy ? "Microphone on, working. Tap to stop listening" : "Microphone on. Tap to stop listening" }
        return busy ? "Microphone off, still working. Tap to listen" : "Microphone off. Tap to listen"
    }

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
                if busy && !speaking {
                    ProgressView()
                        .progressViewStyle(.circular)
                        .tint(on ? Color.accentColor : Color.secondary)
                        .scaleEffect(1.6)
                        .frame(width: 82, height: 82)
                }
            }
            .frame(width: 82, height: 82)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
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
        let order = PanelOrder(data, filter: filter)
        let inline = order.inline(limit: 5)
        let total = order.flat.count
        let moreStacks = TaskStacking.stacks(order.flat).count > inline.shown
        VStack(alignment: .leading, spacing: 8) {
            if total == 0 {
                Text("Nothing to show.").font(.footnote).foregroundStyle(.secondary)
            }
            // What was asked for first, in the order the spoken answer gives it. Overdue comes after.
            ForEach(inline.cards) { stack in TaskCard(task: stack.lead, siblings: stack.items) }
            if !inline.overdueCards.isEmpty {
                overdueLabel(count: order.overdue.count)
                ForEach(inline.overdueCards) { stack in TaskCard(task: stack.lead, siblings: stack.items) }
            }
            if inline.overdueHidden > 0 {
                Button { onSeeAll() } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "exclamationmark.triangle.fill").font(.caption.weight(.bold))
                        Text(order.spot == .noteBelow ? filter.noteText(count: inline.overdueHidden) : "\(inline.overdueHidden) more overdue")
                            .font(.footnote.weight(.bold))
                        Spacer()
                        Image(systemName: "chevron.right").font(.caption.weight(.bold))
                    }
                    .foregroundStyle(.red)
                    .padding(.top, 4)
                }
                .buttonStyle(.plain)
            }
            if moreStacks && inline.overdueHidden == 0 {
                Button("See all \(total)") { onSeeAll() }
                    .font(.subheadline.weight(.semibold))
            }
        }
    }

    private func overdueLabel(count: Int) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "exclamationmark.triangle.fill").font(.caption.weight(.bold))
            Text("Overdue \(count)").font(.footnote.weight(.bold))
        }
        .foregroundStyle(.red)
        .padding(.top, 4)
    }
}

/// The full task list with filters (collapsed until you ask for them).
struct TasksView: View {
    let filter: PanelFilter
    @ObservedObject private var store = TaskStore.shared
    @Environment(\.dismiss) private var dismiss
    @State private var view = ChatTaskFilter.all

    init(filter: PanelFilter) { self.filter = filter }

    var body: some View {
        // The tasks a question or a view asked for, in the same slim list as everywhere else.
        let data = store.panel(filter)
        NavigationStack {
            TaskTrayList(tasks: data.overdue + data.due, lists: store.profiles, filter: $view)
                .background(Color.screenBackground.ignoresSafeArea())
                .navigationTitle("Tasks")
                .inlineNavTitle()
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
                }
        }
    }
}

// MARK: - One tap to a label's tasks

/// Where the home screen's sheet goes: the whole list, one of the smart views, or one label's tasks.
enum TasksRoute: Identifiable, Equatable {
    case all
    case overdue
    case today
    case new
    case label(String)

    var id: String {
        switch self {
        case .all: return "all"
        case .overdue: return "overdue"
        case .today: return "today"
        case .new: return "new"
        case .label(let name): return "label:" + TaskLabels.stemKey(name)
        }
    }

    /// The route a home chip opens.
    init(_ chip: HomeChip) {
        switch chip.kind {
        case .all: self = .all
        case .overdue: self = .overdue
        case .today: self = .today
        case .new: self = .new
        case .label: self = .label(chip.name)
        }
    }
}

/// What "New" lists: open tasks created in the last week, newest first, in one plain list.
struct NewTasksView: View {
    @ObservedObject private var store = TaskStore.shared
    @Environment(\.dismiss) private var dismiss
    @State private var since = HomeLabels.newSince()

    var body: some View {
        let data = store.panel(PanelFilter(who: .all, category: nil, day: .all, status: .open, addedSince: since))
        let tasks = (data.overdue + data.due).sorted { ($0.createdAt ?? .distantPast) > ($1.createdAt ?? .distantPast) }
        NavigationStack {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    if tasks.isEmpty {
                        Text("Nothing new this week.").font(.headline).frame(maxWidth: .infinity).padding(.top, 40)
                    } else {
                        Text("\(tasks.count) added in the last \(HomeLabels.newDays) days")
                            .font(.subheadline).foregroundStyle(.secondary).padding(.top, 2)
                        ForEach(TaskStacking.stacks(tasks)) { stack in TaskCard(task: stack.lead, siblings: stack.items) }
                    }
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 24)
            }
            .scrollIndicators(.hidden)
            .background(Color.screenBackground.ignoresSafeArea())
            .navigationTitle("New")
            .largeNavTitle()
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
    }
}

/// One chip: a smart view (a symbol and a count), or a label (its name, how many tasks are open, a dot for a person, an icon for a
/// list or a category, a small red dot when something is late).
struct LabelChip: View {
    let chip: HomeChip
    var selected = false
    let action: () -> Void

    private var tint: Color {
        if selected { return .white }
        switch chip.kind {
        case .overdue: return .red
        case .today: return .accentColor
        default: return .secondary
        }
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                leading
                Text(chip.name).lineLimit(1)
                if chip.kind != .all { Text("\(chip.open)").opacity(0.65) }
                if chip.hasOverdue {
                    Circle().fill(selected ? Color.white : Color.red).frame(width: 6, height: 6)
                }
                if chip.kind == .all { Image(systemName: "chevron.right").font(.caption.weight(.bold)).opacity(0.65) }
            }
            .font(.subheadline.weight(.semibold))
            .padding(.horizontal, 14)
            .frame(minHeight: 44)
            .foregroundStyle(selected ? Color.white : (chip.kind == .overdue ? Color.red : Color.primary))
            .background(selected ? Color.accentColor : Color.cardBackground, in: Capsule())
            .shadow(color: .black.opacity(selected ? 0 : 0.05), radius: 3, y: 1)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(chip.spoken)
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
    }

    @ViewBuilder
    private var leading: some View {
        switch chip.kind {
        case .overdue: Image(systemName: "exclamationmark.triangle.fill").font(.caption).foregroundStyle(tint)
        case .today: Image(systemName: "sun.max.fill").font(.caption).foregroundStyle(tint)
        case .new: Image(systemName: "sparkles").font(.caption).foregroundStyle(tint)
        case .all: EmptyView()
        case .label:
            if chip.isPerson {
                Circle().fill(selected ? Color.white : Assignee.color(for: chip.name)).frame(width: 8, height: 8)
            } else if chip.isList {
                Image(systemName: "tray.full.fill").font(.caption).foregroundStyle(tint)
            } else if chip.isCategory {
                Image(systemName: "folder.fill").font(.caption).foregroundStyle(tint)
            }
        }
    }
}

/// The tasks of one label, and nothing else: overdue first, then today, then what is coming up. A row of chips switches to
/// another label without closing. The full filters are one step away. Everything is read from the tasks in memory.
struct LabelTasksView: View {
    @ObservedObject private var store = TaskStore.shared
    @Environment(\.dismiss) private var dismiss
    @State private var label: String
    @State private var names: [String]              // the switcher's order, fixed when this opens so it never jumps
    @State private var kinds: [String: TaskTag.Kind]  // which of them are people, lists or categories (the chip icon), also fixed when this opens
    @State private var showCompleted = false
    @State private var showFilters = false

    init(label: String) {
        _label = State(initialValue: label)
        let index = TaskStore.shared.tagIndex
        let shown = HomeLabels.chips(index: index, tasks: TaskStore.shared.tasks, recentTaps: RecentLabels.list(),
                                     limit: 8, profiles: TaskStore.shared.profiles, tapDates: RecentLabels.dates()).map(\.name)
        let all = shown.contains { TaskLabels.same($0, label) } ? shown : [label] + shown
        _names = State(initialValue: all)
        var kinds: [String: TaskTag.Kind] = [:]
        for e in index {
            let key = TaskLabels.stemKey(e.name)
            if e.kinds.contains(.person) { kinds[key] = .person }
            else if e.kinds.contains(.list) { kinds[key] = .list }
            else if e.kinds.contains(.category) { kinds[key] = .category }
        }
        _kinds = State(initialValue: kinds)
    }

    /// Narrowed to a label, so what is current comes first and the overdue ones follow (see `PanelFilter.overdueSpot`).
    var filter: PanelFilter { PanelFilter(who: .all, category: nil, day: .all, status: .open, label: label, requestedFirst: true) }

    private func chip(_ name: String) -> HomeChip {
        let s = HomeLabels.stats(for: name, in: store.tasks)
        let kind = kinds[TaskLabels.stemKey(name)]
        var chip = HomeChip(name: name, open: s.open, overdue: s.overdue, isPerson: kind == .person)
        chip.isList = kind == .list
        chip.isCategory = kind == .category
        return chip
    }

    var body: some View {
        let data = store.panel(filter)
        let groups = LabelSections.make(overdue: data.overdue, due: data.due)
        let open = data.overdue.count + data.due.count
        let done = store.panel(PanelFilter(who: .all, category: nil, day: .all, status: .done, label: label)).due

        NavigationStack {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    if names.count > 1 { switcher }
                    if open > 0 {
                        Text("\(open) open" + (data.overdue.isEmpty ? "" : " · \(data.overdue.count) overdue"))
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .padding(.top, 2)
                    }
                    if open == 0 {
                        Text("Nothing open for \(label).")
                            .font(.headline)
                            .frame(maxWidth: .infinity)
                            .padding(.top, 40)
                    }
                    ForEach(groups, id: \.kind) { group in
                        switch group.kind {
                        case .today:
                            section(groups.count > 1 ? "Today" : nil, icon: "sun.max.fill", color: .accentColor, tasks: group.tasks)
                        case .comingUp:
                            section("Coming up", icon: "calendar", color: .secondary, tasks: group.tasks)
                        case .overdue:
                            section("Overdue", icon: "exclamationmark.triangle.fill", color: .red, tasks: group.tasks)
                        }
                    }
                    if !done.isEmpty {
                        Button {
                            withAnimation { showCompleted.toggle() }
                        } label: {
                            HStack(spacing: 6) {
                                Image(systemName: showCompleted ? "chevron.down" : "chevron.right").font(.caption.weight(.bold))
                                Text(showCompleted ? "Hide completed" : "Show completed (\(done.count))").font(.footnote.weight(.semibold))
                                Spacer()
                            }
                            .foregroundStyle(.secondary)
                            .padding(.top, 8)
                        }
                        .buttonStyle(.plain)
                        if showCompleted { ForEach(done) { TaskCard(task: $0) } }
                    }
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 24)
            }
            .scrollIndicators(.hidden)
            .background(Color.screenBackground.ignoresSafeArea())
            .navigationTitle(label)
            .largeNavTitle()
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
                ToolbarItem(placement: .topBarLeading) {
                    Menu {
                        Button { showFilters = true } label: { Label("More filters", systemImage: "line.3.horizontal.decrease.circle") }
                    } label: { Image(systemName: "ellipsis.circle") }
                }
            }
            .navigationDestination(isPresented: $showFilters) {
                TaskPanelPage(filter: PanelFilter(who: .all, category: nil, day: .all, status: .open, label: label, requestedFirst: true))
            }
            .onAppear { store.refreshRoutines() }
        }
    }

    private var switcher: some View {
        CenteredFlowLayout(spacing: 8) {
            ForEach(names, id: \.self) { name in
                LabelChip(chip: chip(name), selected: TaskLabels.same(name, label)) {
                    guard !TaskLabels.same(name, label) else { return }
                    RecentLabels.note(name)
                    withAnimation(.easeInOut(duration: 0.15)) { label = name; showCompleted = false }
                }
            }
        }
        .frame(maxWidth: .infinity)
    }

    @ViewBuilder
    private func section(_ title: String?, icon: String, color: Color, tasks: [TaskItem]) -> some View {
        if !tasks.isEmpty {
            if let title {
                HStack(spacing: 6) {
                    Image(systemName: icon).font(.caption.weight(.bold))
                    Text(title).font(.footnote.weight(.bold)).textCase(.uppercase)
                    Text("\(tasks.count)").font(.footnote).opacity(0.7)
                    Spacer()
                }
                .foregroundStyle(color)
                .padding(.top, 8)
            }
            ForEach(TaskStacking.stacks(tasks)) { stack in TaskCard(task: stack.lead, siblings: stack.items) }
        }
    }
}

/// The full panel with its filters, pushed from a label's list for the rare time they are needed.
struct TaskPanelPage: View {
    @State var filter: PanelFilter

    var body: some View {
        TaskPanel(filter: $filter)
            .padding(.horizontal, 16)
            .background(Color.screenBackground.ignoresSafeArea())
            .navigationTitle("Filters")
            .inlineNavTitle()
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

    @ViewBuilder
    func largeNavTitle() -> some View {
        #if os(iOS)
        self.navigationBarTitleDisplayMode(.large)
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
            // A pill wider than the line (a long quote) is given the line's width, never its own: otherwise it makes the card,
            // and the whole thread with it, wider than the screen.
            let size = sub.sizeThatFits(ProposedViewSize(width: maxWidth.isFinite ? maxWidth : nil, height: nil))
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
            let size = sub.sizeThatFits(ProposedViewSize(width: bounds.width, height: nil))
            if x > bounds.minX, x + size.width > bounds.maxX { x = bounds.minX; y += rowHeight + spacing; rowHeight = 0 }
            sub.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}

/// Like `FlowLayout`, but every row is centred in the width it is given (the home screen's label chips).
struct CenteredFlowLayout: Layout {
    var spacing: CGFloat = 8

    private func rows(_ subviews: Subviews, maxWidth: CGFloat) -> [[Int]] {
        var out: [[Int]] = [[]]
        var x: CGFloat = 0
        for (i, sub) in subviews.enumerated() {
            let w = sub.sizeThatFits(ProposedViewSize(width: maxWidth.isFinite ? maxWidth : nil, height: nil)).width
            if x > 0, x + w > maxWidth { out.append([]); x = 0 }
            out[out.count - 1].append(i)
            x += w + spacing
        }
        return out
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var height: CGFloat = 0, widest: CGFloat = 0
        for (r, row) in rows(subviews, maxWidth: maxWidth).enumerated() {
            let sizes = row.map { subviews[$0].sizeThatFits(ProposedViewSize(width: maxWidth.isFinite ? maxWidth : nil, height: nil)) }
            height += (r > 0 ? spacing : 0) + (sizes.map(\.height).max() ?? 0)
            widest = max(widest, sizes.map(\.width).reduce(0, +) + spacing * CGFloat(max(row.count - 1, 0)))
        }
        return CGSize(width: proposal.width ?? widest, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for row in rows(subviews, maxWidth: bounds.width) {
            let sizes = row.map { subviews[$0].sizeThatFits(ProposedViewSize(width: bounds.width, height: nil)) }
            let width = sizes.map(\.width).reduce(0, +) + spacing * CGFloat(max(row.count - 1, 0))
            var x = bounds.minX + max(0, (bounds.width - width) / 2)
            for (k, i) in row.enumerated() {
                subviews[i].place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(sizes[k]))
                x += sizes[k].width + spacing
            }
            y += (sizes.map(\.height).max() ?? 0) + spacing
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
            Text(text).font(.caption2.weight(.semibold)).lineLimit(1).truncationMode(.tail)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .foregroundStyle(filled ? Color.white : color)
        .background(filled ? color : color.opacity(0.14), in: Capsule())
    }
}

/// How the label row should lay out: a single scrolling line, with an expand control only when it overflows.
enum LabelRowLayout {
    static func needsExpand(content: CGFloat, available: CGFloat) -> Bool { available > 0 && content > available + 1 }
}

/// What a tap on a label pill does. The task panel sets it to "show only this label"; elsewhere pills are plain.
private struct LabelTapKey: EnvironmentKey {
    static let defaultValue: ((String) -> Void)? = nil
}

extension EnvironmentValues {
    var labelTap: ((String) -> Void)? {
        get { self[LabelTapKey.self] }
        set { self[LabelTapKey.self] = newValue }
    }
}

/// A task's labels in one line. Scroll sideways, or tap the chevron to wrap them all into view.
struct LabelRow: View {
    let labels: [String]
    @Environment(\.labelTap) private var labelTap
    var icon: String = "tag.fill"
    var icons: [String: String] = [:]          // a pill's own icon, by its text: person, folder, tag, list, flag
    /// False inside a row that has its own sideways swipe (the preview): the labels wrap instead of scrolling.
    var scrolls = true
    @State private var expanded = false
    @State private var content: CGFloat = 0
    @State private var available: CGFloat = 0

    private struct WidthKey: PreferenceKey {
        static var defaultValue: CGFloat = 0
        static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
    }

    private var overflows: Bool { LabelRowLayout.needsExpand(content: content, available: available) }

    private func pills() -> some View {
        ForEach(labels, id: \.self) { label in
            if let labelTap {
                Button { labelTap(label) } label: { TagPill(text: label, icon: icons[label] ?? icon, color: .secondary) }
                    .buttonStyle(.plain)
                    .accessibilityHint("Shows only tasks with this tag")
            } else {
                TagPill(text: label, icon: icons[label] ?? icon, color: .secondary)
            }
        }
    }

    var body: some View {
        if labels.isEmpty {
            EmptyView()
        } else if expanded || !scrolls {
            HStack(alignment: .top, spacing: 6) {
                FlowLayout(spacing: 6) { pills() }
                if expanded { chevron }
            }
        } else {
            HStack(spacing: 4) {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) { pills() }
                        .background(GeometryReader { Color.clear.preference(key: WidthKey.self, value: $0.size.width) })
                }
                .onPreferenceChange(WidthKey.self) { content = $0 }
                .background(GeometryReader { g in Color.clear.onAppear { available = g.size.width }.onChange(of: g.size.width) { _, w in available = w } })
                .mask(
                    HStack(spacing: 0) {
                        Rectangle()
                        if overflows {
                            LinearGradient(colors: [.black, .clear], startPoint: .leading, endPoint: .trailing).frame(width: 16)
                        }
                    }
                )
                if overflows { chevron }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var chevron: some View {
        Button { withAnimation(.snappy) { expanded.toggle() } } label: {
            Image(systemName: expanded ? "chevron.up" : "chevron.down")
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(.secondary)
                .frame(width: 22, height: 22)
                .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .accessibilityLabel(expanded ? "Show fewer labels" : "Show all labels")
    }
}

/// The tags under a task. One pill style, with an icon for the type: person, folder (category), tag (label), list, flag (priority).
/// Every tag pill opens the tag filter. Overdue, the day, the time and "+N more" are status, not tags, and stay as chips.
struct TaskTags: View {
    let task: TaskItem
    var showGroup = true
    var extra = 0                      // the same chore listed again: "+2 more"
    @Environment(\.labelTap) private var labelTap

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            statusTags
            let shown = task.tagNames
            LabelRow(labels: shown, icons: Dictionary(shown.map { ($0, icon(of: $0)) }, uniquingKeysWith: { a, _ in a }))
        }
    }

    /// The type icon of a tag on this task: its list or its category.
    private func icon(of name: String) -> String {
        if let list = task.listName, TaskLabels.same(list, name) || TaskLabels.same(TaskLabels.listShort(list), name) { return TaskTag.Kind.list.icon }
        if TaskLabels.same(task.categoryLabel, name) { return TaskTag.Kind.category.icon }
        return TaskTag.Kind.category.icon
    }

    /// A tag pill that opens the tag filter when the panel allows it.
    @ViewBuilder
    private func tag(_ name: String, icon: String, color: Color) -> some View {
        if let labelTap {
            Button { labelTap(name) } label: { TagPill(text: name, icon: icon, color: color) }
                .buttonStyle(.plain)
                .accessibilityHint("Shows only tasks with this tag")
        } else {
            TagPill(text: name, icon: icon, color: color)
        }
    }

    private var statusTags: some View {
        FlowLayout(spacing: 6) {
            if task.isOverdue {
                TagPill(text: "\(task.daysOverdue) \(task.daysOverdue == 1 ? "day" : "days") overdue",
                        icon: "exclamationmark.triangle.fill", color: .red, filled: true)
            }
            if extra > 0 {
                TagPill(text: "+\(extra) more", icon: "square.stack.fill", color: task.isOverdue ? .red : .secondary)
            }
            if !task.effectiveAssignee.isEmpty {
                tag(task.effectiveAssignee, icon: TaskTag.Kind.person.icon, color: Assignee.color(for: task.effectiveAssignee))
            }
            if let soft = task.softDue, task.dueDate == nil {
                TagPill(text: soft, icon: "calendar.badge.clock", color: .secondary)      // as said ("next week"): never turned into a date
            } else {
                TagPill(text: task.dueLabel, icon: "calendar", color: task.isOverdue ? .red : .secondary)
            }
            if let time = task.timeLabel {
                TagPill(text: time, icon: task.sortSlot.symbol, color: .indigo)
            }
            if let p = task.priority {
                tag(p.capitalized, icon: TaskTag.Kind.priority.icon, color: p == "high" ? .red : (p == "medium" ? .orange : .secondary))
            }
            if task.routineID != nil { TagPill(text: "Routine", icon: "repeat", color: .purple) }
            // A playbook step shows its playbook. A list item shows its list as a tag below, like any other.
            if showGroup, task.profileID == nil, let g = task.group { tag(g, icon: TaskTag.Kind.playbook.icon, color: .orange) }
        }
    }
}

/// The lines under a task's title: why, how, repeat and timeframe, as the user said them. A line Kitty could not read is orange.
struct DetailLinesView: View {
    let lines: [TaskDetailLine]

    var body: some View {
        ForEach(lines) { line in
            Group {
                if line.label.isEmpty {
                    Text(line.value)
                } else {
                    Text(line.label + ": ").fontWeight(.semibold) + Text(line.value)
                }
            }
            .font(.caption)
            .foregroundStyle(line.isFlag ? Color.orange : Color.secondary)
            .lineLimit(2)
            .fixedSize(horizontal: false, vertical: true)
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
                DetailLinesView(lines: TaskDetailLines.lines(for: task, shownAsTag: [.forWhom]))
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
    /// Set when the details of how this task was made were kept: adds "See details".
    var onDetails: (() -> Void)? = nil
    /// Opens the edit form for this task.
    var onEdit: (() -> Void)? = nil

    var body: some View {
        if let onEdit {
            Button(action: onEdit) { Label("Edit", systemImage: "pencil") }
        }
        if let onDetails {
            Button(action: onDetails) { Label("See details", systemImage: "doc.text.magnifyingglass") }
        }
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
    /// Swipe the card left to delete it, in every list. A stack of the same chore loses one at a time, like ticking does.
    var swipeToDelete = true

    var body: some View {
        if swipeToDelete {
            SwipeToDelete(onDelete: { withAnimation { TaskStore.shared.remove(task.id) } }) { card }
                .accessibilityAction(named: "Delete") { withAnimation { TaskStore.shared.remove(task.id) } }
        } else {
            card
        }
    }

    @State private var showDetails = false
    @State private var editing = false

    private var card: some View {
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
        // One tap opens the form with every field, to change and save. The checkbox keeps its own tap.
        .contentShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .onTapGesture { editing = true }
        .accessibilityAction(named: "Edit") { editing = true }
        .contextMenu {
            TaskActions(task: task, siblings: siblings, onDetails: TaskDetailsStore.shared.has(task.id) ? { showDetails = true } : nil,
                        onEdit: { editing = true })
        }
        .sheet(isPresented: $showDetails) { TaskDetailsView(task: task) }
        .sheet(isPresented: $editing) { TaskEditSheet(task: task) }
    }
}

/// The form for a saved task: the same fields as the draft sheet (`TaskFieldsForm`), plus what only a saved task has. Nothing is written
/// until Save; Cancel throws the changes away. It edits this one task: for a repeating chore's copy for today, or a playbook step, the
/// routine or playbook behind it is left as it is. If the change cannot be stored, the sheet stays open and says so.
struct TaskEditSheet: View {
    let taskID: UUID
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var store = TaskStore.shared

    @State private var form: TaskFormState
    @State private var isDone: Bool
    @State private var category: TaskCategory
    @State private var saveFailed = false
    private let originalCategory: TaskCategory
    private let originalList: String?

    init(task: TaskItem) {
        taskID = task.id
        // The task as it is saved now, not as the card was drawn.
        let base = TaskStore.shared.tasks.first { $0.id == task.id } ?? task
        let bigger = base.routineID != nil || (base.profileID == nil && base.group != nil)
        _form = State(initialValue: TaskFormState(draft: TaskFormBridge.draft(from: base), mode: .saved(routineCopy: base.routineID != nil, partOfBigger: bigger)))
        _isDone = State(initialValue: base.isDone)
        _category = State(initialValue: base.effectiveCategory)
        originalCategory = base.effectiveCategory
        originalList = base.listName
    }

    private var people: [String] {
        var names = store.allAssigneeNames
        if let a = form.item.assignee.map(Assignee.normalize), !a.isEmpty, !names.contains(where: { $0.lowercased() == a.lowercased() }) { names.append(a) }
        return names
    }

    var body: some View {
        NavigationStack {
            Form {
                TaskFieldsForm(form: $form, people: people, noPersonLabel: "Not set")
                Section("Status") {
                    Toggle("Done", isOn: $isDone)
                }
                Section("Category") {
                    Picker("Category", selection: $category) {
                        ForEach(TaskCategory.allCases, id: \.self) { Text("\($0.emoji) \($0.label)").tag($0) }
                    }
                }
                Section {
                    Button("Delete this task", role: .destructive) {
                        withAnimation { store.remove(taskID) }
                        dismiss()
                    }
                } footer: {
                    if saveFailed { Text("Couldn't save the change.").foregroundStyle(.red) }
                }
            }
            .navigationTitle("Edit task")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("Save", action: commit).disabled(!form.canSave) }
            }
        }
        .presentationDetents([.large])
    }

    private func commit() {
        guard let current = store.tasks.first(where: { $0.id == taskID }) else { saveFailed = true; return }
        let draft = form.commit()
        var out = TaskFormBridge.apply(draft, to: current)
        out.isDone = isDone
        if category != originalCategory { out.category = category; out.categoryName = nil }
        // The list: left alone when the name is as it was; otherwise an existing list, a new one made now (the user's own Save), or none.
        var madeList: TaskProfile?
        let named = TaskDraftMapper.clean(draft.listName)
        if !(named == nil && originalList == nil), !(named != nil && originalList != nil && TaskLabels.same(named ?? "", originalList ?? "")) {
            if let named {
                if let known = store.profile(named: named) { out.profileID = known.id }
                else {
                    let made = store.ensureProfile(named)
                    out.profileID = made.profile.id
                    if made.created { madeList = made.profile }
                }
            } else {
                out.profileID = nil
            }
        }
        guard store.update(out) else {
            // Not stored: the task is as it was (the store put it back), a list made for it is taken back, and the sheet stays.
            if let madeList { store.removeProfile(madeList.id, deleteItems: false) }
            saveFailed = true
            return
        }
        dismiss()
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
                .opacity(offset < 0 ? 1 : 0)            // hidden at rest, so it never peeks out from behind the card
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
        // Clip to the card while it slides, but leave room for its shadow at rest.
        .mask { RoundedRectangle(cornerRadius: 18, style: .continuous).padding(offset == 0 ? -24 : 0) }
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
                TaskCard(task: task)             // swipes away by itself
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
        let people = Array(Set(tasks.map(\.effectiveAssignee).filter { !$0.isEmpty })).sorted()
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
                .accessibilityHidden(true)
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
    @State private var showEarlier = false          // tomorrow's view: the overdue note expanded
    // The list card: which lists show every open task, which show their finished ones, a name being typed, an item being added.
    @State private var showAllOpen: Set<String> = []
    @State private var showDone: Set<String> = []
    @State private var renaming: TaskProfile?
    @State private var renameText = ""
    @State private var newItem: [String: String] = [:]
    @State private var notice: String?

    private var choices: [AssigneeChoice] {
        var list: [AssigneeChoice] = [.all, .mine]
        for name in store.allAssigneeNames { list.append(.person(name)) }
        if case .person(let n) = filter.who, !list.contains(.person(n)) { list.append(.person(n)) }
        return list
    }

    @State private var showFilters = false

    private var activeCount: Int {
        (filter.who != .all ? 1 : 0) + (filter.category != nil ? 1 : 0) + (filter.day != .all ? 1 : 0) + (filter.status != .all ? 1 : 0)
            + (filter.profileID != nil ? 1 : 0) + (filter.label != nil ? 1 : 0)
    }

    private var summary: String {
        var parts: [String] = []
        if let pid = filter.profileID, let list = store.profiles.first(where: { $0.id == pid }) { parts.append(list.name) }
        if filter.who != .all { parts.append(filter.who.title) }
        if let c = filter.category { parts.append(c.label) }
        if let l = filter.label { parts.append("#" + l) }
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
                labelMenu
            }

            if let cat = filter.category {
                Button { filter.category = nil } label: {
                    TagPill(text: "\(cat.label)  ✕", icon: cat.symbol, color: .accentColor, filled: true)
                }
                .buttonStyle(.plain)
            }
            if let label = filter.label {
                Button { filter.label = nil } label: {
                    TagPill(text: "\(label)  ✕", icon: "tag.fill", color: .accentColor, filled: true)
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
        .environment(\.labelTap, { name in
            filter.label = name
            withAnimation(.easeInOut(duration: 0.2)) { showFilters = true }
        })
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

    /// Every tag on open tasks, whatever its type (person, category, list or label), with how many tasks carry it and an icon for
    /// the type: tap one to see only those tasks.
    private var labelMenu: some View {
        let counts = Array(store.tagIndex.prefix(40))
        func icon(_ e: TagEntry) -> String { e.kinds.count == 1 ? (e.kinds.first?.icon ?? "tag.fill") : "tag.fill" }
        return Menu {
            Button { filter.label = nil } label: {
                Label("All tags", systemImage: filter.label == nil ? "checkmark" : "tag")
            }
            ForEach(counts, id: \.name) { item in
                Button { filter.label = item.name } label: {
                    Label("\(item.name) (\(item.count))", systemImage: filter.label.map { TaskLabels.same($0, item.name) } == true ? "checkmark" : icon(item))
                }
            }
        } label: {
            Image(systemName: filter.label == nil ? "tag" : "tag.fill").font(.title2)
        }
        .disabled(counts.isEmpty)
        .accessibilityLabel("Filter by tag")
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
        case .all:
            // After a question, the section is named for what was asked: "Zomato", "Househelp", "Bathroom".
            if filter.requestedFirst {
                if let l = filter.label { return l }
                if filter.who != .all { return filter.who.title }
                if let c = filter.category { return c.label }
                return "Open now"
            }
            return "Coming up"
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

        let spot = filter.overdueSpot
        let overdueBelow = spot == .noteBelow

        if !data.overdue.isEmpty && spot == .top {
            sectionHeader("Overdue", icon: "exclamationmark.triangle.fill", count: data.overdue.count, color: .red)
            ForEach(TaskStacking.stacks(data.overdue)) { stack in TaskCard(task: stack.lead, siblings: stack.items) }
        }

        if overdueBelow && openLoose.isEmpty && groups.isEmpty && !data.overdue.isEmpty {
            Text(filter.day == .today ? "Nothing due today" : "Nothing due tomorrow").font(.headline).padding(.top, 8)
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

        if spot == .sectionBelow && !data.overdue.isEmpty {
            // The overdue tasks match the question too, so they are listed, open, after the ones that are current.
            sectionHeader("Overdue", icon: "exclamationmark.triangle.fill", count: data.overdue.count, color: .red)
            ForEach(TaskStacking.stacks(data.overdue)) { stack in TaskCard(task: stack.lead, siblings: stack.items) }
        }

        if overdueBelow && !data.overdue.isEmpty {
            Button {
                withAnimation { showEarlier.toggle() }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill").font(.caption.weight(.bold))
                    Text(filter.noteText(count: data.overdue.count)).font(.footnote.weight(.bold))
                    Spacer()
                    Image(systemName: showEarlier ? "chevron.down" : "chevron.right").font(.caption.weight(.bold))
                }
                .foregroundStyle(.red)
                .padding(.top, 8)
            }
            .buttonStyle(.plain)
            if showEarlier {
                ForEach(TaskStacking.stacks(data.overdue)) { stack in TaskCard(task: stack.lead, siblings: stack.items) }
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

    /// The most open tasks of a list shown before "Show N more".
    private static let listPreview = 6

    /// A list (or a playbook) as one collapsible card. A list shows its name and progress, its open tasks first as a checklist, the
    /// finished ones under "Done (N)", and a menu for what can be done to the whole list. Playbooks and lists the user marked
    /// "Steps in order" are numbered; a list never is unless the user said so.
    private func groupCard(_ name: String, _ items: [TaskItem]) -> some View {
        let isOpen = Binding<Bool>(
            get: { expanded.contains(name) },
            set: { newValue in
                if newValue { _ = expanded.insert(name) } else { _ = expanded.remove(name) }
            })
        let list = items.first?.profileID.flatMap { id in store.profiles.first(where: { $0.id == id }) }
        let open = items.filter { !$0.isDone }
        let done = items.filter(\.isDone)
        let numbered = list.map { $0.isOrdered } ?? (items.first?.profileID == nil)
        let visible = showAllOpen.contains(name) || open.count <= Self.listPreview + 1 ? open : Array(open.prefix(Self.listPreview))
        return DisclosureGroup(isExpanded: isOpen) {
            VStack(spacing: 8) {
                if let list {
                    HStack {
                        Spacer()
                        listMenu(list, items: items)
                    }
                }
                ForEach(Array(visible.enumerated()), id: \.element.id) { n, task in
                    HStack(alignment: .top, spacing: 6) {
                        if numbered { Text("\(n + 1)").font(.caption.weight(.bold)).foregroundStyle(.secondary).frame(width: 18).padding(.top, 18) }
                        TaskCard(task: task, showGroup: false)
                    }
                }
                if visible.count < open.count {
                    Button { withAnimation { _ = showAllOpen.insert(name) } } label: {
                        Text("Show \(open.count - visible.count) more").font(.footnote.weight(.medium))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(Color.accentColor)
                }
                if !done.isEmpty {
                    Button {
                        withAnimation { if showDone.contains(name) { _ = showDone.remove(name) } else { _ = showDone.insert(name) } }
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: showDone.contains(name) ? "chevron.down" : "chevron.right").font(.caption.weight(.bold))
                            Text("Done (\(done.count))").font(.footnote.weight(.semibold))
                            Spacer()
                        }
                        .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    if showDone.contains(name) { ForEach(done) { task in TaskCard(task: task, showGroup: false) } }
                }
                if let list {
                    HStack(spacing: 8) {
                        Image(systemName: "plus.circle").foregroundStyle(.secondary)
                        TextField("Add item", text: Binding(get: { newItem[name] ?? "" }, set: { newItem[name] = $0 }))
                            .submitLabel(.done)
                            .onSubmit {
                                let text = (newItem[name] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                                guard !text.isEmpty else { return }
                                store.addItems([text], to: list)
                                newItem[name] = ""
                            }
                    }
                    .font(.subheadline)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
                    .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                }
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

    /// What can be done to a whole list.
    private func listMenu(_ list: TaskProfile, items: [TaskItem]) -> some View {
        Menu {
            Button { for t in items where !t.isDone { store.complete(t.id) } } label: { Label("Mark all done", systemImage: "checkmark.circle") }
            Button { renameText = list.name; renaming = list } label: { Label("Rename", systemImage: "pencil") }
            Button {
                store.setOrdered(!list.isOrdered, for: list.id)
            } label: { Label(list.isOrdered ? "Steps in order (on)" : "Steps in order", systemImage: "list.number") }
            Button {
                notice = store.savePlaybook(fromList: list) ? "Saved “\(list.name)” as a playbook." : "There is nothing on this list to save."
            } label: { Label("Save as playbook", systemImage: "square.and.arrow.down") }
            Button(role: .destructive) {
                if filter.profileID == list.id { filter.profileID = nil }
                store.removeProfile(list.id, deleteItems: true)
            } label: { Label("Delete list", systemImage: "trash") }
        } label: {
            Image(systemName: "ellipsis.circle").font(.title3).foregroundStyle(.secondary)
        }
        .accessibilityLabel("List actions for \(list.name)")
        .alert("Rename list", isPresented: Binding(get: { renaming?.id == list.id }, set: { if !$0 { renaming = nil } })) {
            TextField("Name", text: $renameText)
            Button("Rename") { store.renameProfile(list.id, to: renameText); renaming = nil }
            Button("Cancel", role: .cancel) { renaming = nil }
        }
        .alert(notice ?? "", isPresented: Binding(get: { notice != nil }, set: { if !$0 { notice = nil } })) {
            Button("OK", role: .cancel) { notice = nil }
        }
    }
}


// MARK: - How a task was made

/// What was said, what the model was sent and answered, what Swift checked, and what was saved: one card per step, one block
/// per turn (a task made after a question has two).
struct TaskDetailsView: View {
    let task: TaskItem
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        let records = TaskDetailsStore.shared.records(for: task.id)
        NavigationStack {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 14) {
                    if records.isEmpty {
                        Text("No details were kept for this task.").font(.headline).padding(.top, 40).frame(maxWidth: .infinity)
                    }
                    if !records.isEmpty {
                        NavigationLink {
                            FullTraceView(task: task, records: records)
                        } label: {
                            Label("Full trace: every model call, word for word", systemImage: "list.bullet.rectangle")
                                .font(.subheadline.weight(.semibold))
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(14)
                                .background(Color.cardBackground, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                        }
                        .buttonStyle(.plain)
                    }
                    ForEach(Array(records.enumerated()), id: \.element.id) { n, record in
                        if record.route == "saving" {
                            card(nil, title: "Model calls while saving", symbol: "tray.and.arrow.down.fill") {
                                ForEach(record.calls) { call in ModelCallBlock(call: call, part: .both) }
                            }
                        } else {
                        if records.count > 1 { turnHeader(n + 1, of: records.count, record) }
                        ForEach(TaskDetailsFormat.sections(for: record).filter { $0.section != .savedAs }, id: \.section) { part in
                            card(part.section) { sectionContent(part.section, part.stages, record) }
                        }
                        if !record.result.isEmpty {
                            card(nil, title: "Kitty said", symbol: "bubble.left.fill") { Text(record.result).font(.callout) }
                        }
                        }
                    }
                    card(.savedAs) {
                        VStack(alignment: .leading, spacing: 6) {
                            ForEach(Array(TaskDetailsFormat.savedRows(task).enumerated()), id: \.offset) { _, row in fieldRow(row.key, row.value) }
                        }
                    }
                }
                .padding(16)
            }
            .background(Color.screenBackground.ignoresSafeArea())
            .navigationTitle("How this was made")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
                ToolbarItem(placement: .topBarLeading) {
                    ShareLink(item: TaskDetailsFormat.fullTrace(task: task, records: records)) { Image(systemName: "square.and.arrow.up") }
                        .disabled(records.isEmpty)
                }
            }
        }
    }

    private func turnHeader(_ n: Int, of total: Int, _ record: TaskTurnRecord) -> some View {
        HStack {
            Text("Turn \(n) of \(total)").font(.headline)
            Spacer()
            Text(record.date.formatted(date: .omitted, time: .shortened)).font(.footnote).foregroundStyle(.secondary)
        }
        .padding(.top, 8)
    }

    private func card<Content: View>(_ section: DetailSection?, title: String? = nil, symbol: String? = nil,
                                     @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(title ?? section?.title ?? "", systemImage: symbol ?? section?.symbol ?? "circle")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(Color.cardBackground, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    private func fieldRow(_ key: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            if !key.isEmpty { Text(key.capitalized).font(.footnote).foregroundStyle(.secondary).frame(width: 84, alignment: .leading) }
            Text(value).font(.callout).frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled)
        }
    }

    /// A turn with recorded model calls shows them exactly (instructions, history, prompt, reply); otherwise the shorter lines.
    @ViewBuilder
    private func sectionContent(_ section: DetailSection, _ stages: [TraceStage], _ record: TaskTurnRecord) -> some View {
        if !record.calls.isEmpty && (section == .sentToModel || section == .modelReplied) {
            ForEach(record.calls) { call in ModelCallBlock(call: call, part: section == .sentToModel ? .sent : .received) }
        } else {
            stagesView(section, stages)
        }
    }

    @ViewBuilder
    private func stagesView(_ section: DetailSection, _ stages: [TraceStage]) -> some View {
        if stages.isEmpty {
            Text(section.empty).font(.callout).foregroundStyle(.secondary)
        }
        ForEach(Array(stages.enumerated()), id: \.offset) { _, s in
            switch s.stage {
            case "TO MODEL":
                let parts = TaskDetailsFormat.split(s.text)
                Text(parts.summary).font(.callout)
                if !parts.body.isEmpty { raw("Show full prompt", parts.body) }
            case "FROM MODEL":
                let parts = TaskDetailsFormat.split(s.text)
                Text(parts.summary).font(.footnote).foregroundStyle(.secondary)
                ForEach(Array(parts.body.split(separator: "\n").enumerated()), id: \.offset) { _, line in
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(Array(TaskDetailsFormat.fields(of: String(line)).enumerated()), id: \.offset) { _, f in fieldRow(f.key, f.value) }
                    }
                }
                if !parts.body.isEmpty { raw("Show raw reply", parts.body) }
            case "HEARD", "CLEANED":
                VStack(alignment: .leading, spacing: 2) {
                    Text(s.stage == "HEARD" ? "Heard" : "Cleaned").font(.footnote).foregroundStyle(.secondary)
                    Text(s.text).font(.callout).textSelection(.enabled)
                }
            default:
                check(s.text)
            }
        }
    }

    private func check(_ text: String) -> some View {
        let kind = TaskDetailsFormat.checkKind(text)
        let icon: (String, Color) = {
            switch kind {
            case .dropped: return ("minus.circle.fill", .orange)
            case .added: return ("plus.circle.fill", .blue)
            case .kept: return ("checkmark.circle.fill", .green)
            case .info: return ("info.circle.fill", .secondary)
            }
        }()
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        return HStack(alignment: .top, spacing: 8) {
            Image(systemName: icon.0).foregroundStyle(icon.1)
            VStack(alignment: .leading, spacing: 2) {
                Text(lines.first ?? "").font(.callout)
                if lines.count > 1 {
                    Text(lines.dropFirst().joined(separator: "\n")).font(.system(.caption, design: .monospaced)).foregroundStyle(.secondary)
                }
            }
            .textSelection(.enabled)
        }
    }

    private func raw(_ title: String, _ text: String) -> some View {
        DisclosureGroup(title) {
            ScrollView(.horizontal) {
                Text(text).font(.system(.caption, design: .monospaced)).textSelection(.enabled).padding(.top, 6)
            }
        }
        .font(.footnote.weight(.semibold))
        .tint(.secondary)
    }
}


/// One model call, exactly: what the session already held, what was sent, what came back, how long it took and any error.
struct ModelCallBlock: View {
    enum Part { case sent, received, both }
    let call: ModelCallRecord
    var part: Part = .both
    var number: Int? = nil

    private var history: String {
        call.history.map { "[\($0.role)]\n\($0.text)" }.joined(separator: "\n\n")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text((number.map { "Model call \($0): " } ?? "") + call.kind)
                .font(.callout.weight(.semibold))
            Text(call.mode + (call.seconds > 0 ? String(format: " · %.1f s", call.seconds) : ""))
                .font(.footnote)
                .foregroundStyle(.secondary)
            if part != .received {
                Text("Instructions \(Trace.size(call.instructions)) · history \(call.history.count) \(call.history.count == 1 ? "entry" : "entries") · prompt \(Trace.size(call.prompt))")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                disclosure("Show instructions", call.instructions.isEmpty ? "(none recorded)" : call.instructions)
                if !call.history.isEmpty { disclosure("Show session history (\(call.history.count))", history) }
                disclosure("Show exact prompt", call.prompt)
            }
            if part != .sent {
                if let error = call.error {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .font(.footnote)
                        .foregroundStyle(.orange)
                        .textSelection(.enabled)
                }
                if !call.rawReply.isEmpty {
                    Text("Exact reply").font(.footnote).foregroundStyle(.secondary)
                    Text(call.rawReply)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                } else if call.error == nil {
                    Text("The model gave no reply.").font(.callout).foregroundStyle(.secondary)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func disclosure(_ title: String, _ text: String) -> some View {
        DisclosureGroup(title) {
            ScrollView(.horizontal) {
                Text(text).font(.system(.caption, design: .monospaced)).textSelection(.enabled).padding(.top, 6)
            }
        }
        .font(.footnote.weight(.semibold))
        .tint(.secondary)
    }
}

/// Everything that happened while a task was made, in the order it happened: what was heard, each Swift step and each model
/// call, word for word.
struct FullTraceView: View {
    let task: TaskItem
    let records: [TaskTurnRecord]

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 12) {
                ForEach(TaskDetailsFormat.timeline(for: records)) { item in
                    switch item.kind {
                    case .header(let title):
                        Text(title).font(.headline).padding(.top, 10)
                    case .step(let step):
                        VStack(alignment: .leading, spacing: 2) {
                            Text(step.stage).font(.caption2.weight(.bold)).foregroundStyle(.secondary)
                            Text(step.text).font(.callout).textSelection(.enabled)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    case .call(let call, let number):
                        ModelCallBlock(call: call, part: .both, number: number)
                            .padding(14)
                            .background(Color.cardBackground, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                    }
                }
            }
            .padding(16)
        }
        .background(Color.screenBackground.ignoresSafeArea())
        .navigationTitle("Full trace")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                ShareLink(item: TaskDetailsFormat.fullTrace(task: task, records: records)) { Image(systemName: "square.and.arrow.up") }
            }
        }
    }
}


// MARK: - Changing a task of the draft by hand

/// Which task the edit sheet is for; `itemID` is nil for a new one.
struct DraftEditTarget: Identifiable {
    let id = UUID()
    var itemID: UUID?
}

/// One task in the draft, or a new task: the same fields as the saved-task sheet (`TaskFieldsForm`). Nothing here saves to the list:
/// it changes the draft, which still waits for Save.
struct DraftEditSheet: View {
    @ObservedObject var convo: VoiceConversation
    let target: DraftEditTarget
    @Environment(\.dismiss) private var dismiss

    @State private var form: TaskFormState
    private let isNew: Bool

    init(convo: VoiceConversation, target: DraftEditTarget) {
        self.convo = convo
        self.target = target
        let existing = target.itemID.flatMap { convo.draftItem($0) }
        isNew = existing == nil
        _form = State(initialValue: TaskFormState(draft: existing ?? DraftItem(title: "")))
    }

    private var item: DraftItem { form.item }

    private var people: [String] {
        var names = convo.knownPeople
        if let a = item.assignee, !a.isEmpty, !names.contains(a) { names.append(a) }
        return names
    }

    var body: some View {
        NavigationStack {
            Form {
                TaskFieldsForm(form: $form, people: people) {
                    if !isNew, item.heardAs != nil || item.quoteUnverified {
                        // The model's quote is the model's, not the user's speech. The original transcript is shown beside it so the
                        // user can judge for themselves; a quote that matches is not proof that the task is right either.
                        Section("Evidence") {
                            if let quote = item.heardAs {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(item.quoteUnverified ? "Model's quote (not found word for word in what you said)" : "Model's quote")
                                        .font(.caption).foregroundStyle(.secondary)
                                    Text("“\(quote)”").font(.callout)
                                }
                            }
                            VStack(alignment: .leading, spacing: 4) {
                                Text("What you said").font(.caption).foregroundStyle(.secondary)
                                Text(convo.draftSpokenText.isEmpty ? "Not available" : convo.draftSpokenText).font(.callout)
                            }
                            if item.quoteUnverified {
                                Button(item.reviewed ? "Included" : "Include this task") {
                                    if let id = target.itemID { convo.includeDraftItem(id) }
                                    dismiss()
                                }
                                .disabled(item.reviewed)
                                Button("Remove this task", role: .destructive) {
                                    if let id = target.itemID { convo.deleteDraftItem(id) }
                                    dismiss()
                                }
                            }
                        }
                    }
                }
                if !isNew {
                    Section {
                        Button("Delete this task", role: .destructive) {
                            if let id = target.itemID { convo.deleteDraftItem(id) }
                            dismiss()
                        }
                    }
                }
            }
            .navigationTitle(isNew ? "Add a task" : "Change task")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button(isNew ? "Add" : "Done", action: commit).disabled(!form.canSave) }
            }
        }
        .presentationDetents([.large])
    }

    private func commit() {
        let out = form.commit()
        if isNew { convo.addDraftItem(out) } else { convo.saveDraftEdit(out) }
        dismiss()
    }
}


/// The system chime that stands in for "Anything else?" when read-aloud is off.
enum Chime {
    static func play() { AudioServicesPlaySystemSound(1057) }
}


// MARK: - Swipe left to delete, for rows that are not in a List

/// A row that slides left to show a red trash button, and deletes with a long swipe or a tap on the button. The preview card is not
/// a `List`, so it has no built-in swipe actions. It reacts only to a mostly sideways drag, so scrolling the thread still works.
/// VoiceOver gets a "Delete" action instead.
struct SwipeToDeleteRow<Content: View>: View {
    let enabled: Bool
    var label = "Delete"
    let onDelete: () -> Void
    @ViewBuilder let content: () -> Content

    @State private var offset: CGFloat = 0
    @State private var open = false
    private let reveal: CGFloat = 84
    private let fullSwipe: CGFloat = 200
    /// The corner radius of a task tile, shared with the action behind it so the two read as one shape.
    static var tileRadius: CGFloat { 14 }
    private let gap: CGFloat = 8

    var body: some View {
        if !enabled {
            content()
        } else {
            ZStack(alignment: .trailing) {
                Button(role: .destructive, action: onDelete) {
                    VStack(spacing: 3) {
                        Image(systemName: "trash.fill").font(.body.weight(.semibold))
                        Text("Remove").font(.caption2.weight(.semibold))
                    }
                    .foregroundStyle(.white)
                    .frame(width: reveal - gap)
                    .frame(maxHeight: .infinity)
                    .background(Color.red, in: RoundedRectangle(cornerRadius: Self.tileRadius, style: .continuous))
                }
                .buttonStyle(.plain)
                .opacity(offset < 0 ? 1 : 0)
                .accessibilityHidden(true)

                content()
                    .offset(x: offset)
                    .allowsHitTesting(!open)
                    .overlay {
                        // Open: a tap anywhere on the row closes it instead of opening the editor.
                        if open { Color.clear.contentShape(Rectangle()).offset(x: offset).onTapGesture { close() } }
                    }
            }
            .simultaneousGesture(
                DragGesture(minimumDistance: 16)
                    .onChanged { v in
                        guard abs(v.translation.width) > abs(v.translation.height) else { return }
                        offset = min(0, max(-fullSwipe - 40, (open ? -reveal : 0) + v.translation.width))
                    }
                    .onEnded { v in
                        guard abs(v.translation.width) > abs(v.translation.height) else { return }
                        let end = (open ? -reveal : 0) + v.translation.width
                        if end < -fullSwipe {
                            onDelete()
                            close()
                        } else if end < -reveal / 2 {
                            withAnimation(.snappy) { open = true; offset = -reveal }
                        } else {
                            close()
                        }
                    }
            )
            .accessibilityAction(named: Text(label), onDelete)
        }
    }

    private func close() {
        withAnimation(.snappy) { open = false; offset = 0 }
    }
}


/// How your words are laid out in the chat. Words are what the app counts (`committedWords`, struck indices), but the spaces between
/// them are kept as written: a line break you typed stays a line break, any other run of spaces becomes one space.
enum SpokenText {
    struct Piece: Equatable { var separator: String; var word: String }

    static func pieces(_ text: String) -> [Piece] {
        var out: [Piece] = []
        var gap = ""
        var word = ""
        func flush() {
            guard !word.isEmpty else { return }
            let sep: String
            if out.isEmpty { sep = "" }
            else {
                let breaks = gap.filter { $0.isNewline }.count
                sep = breaks > 0 ? String(repeating: "\n", count: breaks) : " "
            }
            out.append(Piece(separator: sep, word: word))
            word = ""; gap = ""
        }
        for ch in text {
            if ch.isWhitespace {
                if !word.isEmpty { flush() }
                gap.append(ch)
            } else {
                word.append(ch)
            }
        }
        flush()
        return out
    }

    /// The words of a run of pieces as written; the gap in front of the first one is dropped.
    static func text(of run: ArraySlice<Piece>) -> String {
        run.enumerated().map { $0.offset == 0 ? $0.element.word : $0.element.separator + $0.element.word }.joined()
    }

    /// Everything after the first `n` words, as written (line breaks kept), without the gap in front of the first word kept.
    static func tail(of text: String, droppingWords n: Int) -> String {
        let all = pieces(text)
        let rest = all.dropFirst(min(max(n, 0), all.count))
        return rest.enumerated().map { $0.offset == 0 ? $0.element.word : $0.element.separator + $0.element.word }.joined()
    }
}
