# Kitty v34: Whisper large-v3-turbo, hybrid with small.en

The default speech engine is now **Whisper Turbo (accurate)**: `small.en` still shows the words live while you talk, and when you pause,
**large-v3-turbo** re-listens to the whole phrase and its text replaces the live line. That settled text is what Kitty acts on.
Pick the engine in the conversation menu (**Speech engine**): Whisper Turbo (accurate) / Whisper (quick, live model only) / Moonshine / Apple Speech.
It takes effect the next time the conversation opens. A choice you made before (for example plain Whisper) is kept; pick Turbo once to switch.

- **How the hybrid works.** `WhisperSession` (`WhisperEngine.swift`) has two models. The live one runs a pass about every 0.6 s of new audio.
  When you stop for 0.9 s, the phrase goes to a separate queue (`kitty.whisper.final`) where turbo transcribes it; the result replaces the
  live line by id. The next phrase is listened to at once, so a slow turbo pass never freezes the live text. If turbo is not loaded yet, fails, or
  runs past the 6 s the close is willing to wait, small.en's text settles the line instead. Restarts and cancels do not wait at all.
- **Loading.** `WhisperAccurate` loads turbo in the background when the app opens or a conversation starts (never blocking it), keeps it loaded
  for 10 minutes after the conversation closes, and lets go of it on a memory warning. While it loads for the first time the screen says so
  under the transcript, and the quick model listens meanwhile. On a phone the CoreML encoder is compiled on first use and cached: **expect the first
  load to take a minute or more**, later ones a few seconds.
- **Weights.** 5-bit `ggml-large-v3-turbo-q5_0.bin` (574 MB) plus its CoreML encoder (about 1.2 GB), in `Whisper/large-v3-turbo/`. **The app grows by
  about 1.8 GB** on top of small.en. The 16-bit file (1.6 GB) is available with `sh Whisper/fetch-models.sh turbo-f16`; the app uses the 5-bit one if both are there
  (delete it to compare).
- **Timings.** `VoiceTurnManager.longPause` is 4.0 s (was 3.5) and the quick nudge after a lone verb is 5.0 s. The caps follow the base (5.5 s and 6.5 s).
  `TranscriptPolicy.raw` already passes the words through uncleaned, and long turns already go whole to `decideBulk`.
- **Simulator.** There is no usable Neural Engine in the simulator and turbo on the CPU is very slow (about 40 s for an 11 s phrase), so the
  simulator uses small.en only and the menu says Turbo is not installed. To try it anyway: `KITTY_WHISPER_TURBO_SIM=1` with
  `KITTY_WHISPER_TURBO_MODEL=<folder with the .bin>`.

## Set-up

1. `sh Whisper/fetch-models.sh` (small.en and the framework, as before), then `sh Whisper/fetch-models.sh turbo` for turbo and its encoder.
   Both folders are git-ignored; the project bundles the whole `Whisper` folder.
2. Run on the iPhone 17 Pro with your signing team. Open the conversation once and wait for the first load (the notice disappears when it is ready).
3. Opt-in real-model checks on the Mac simulator (both take minutes):
   `TEST_RUNNER_KITTY_WHISPER_TURBO=1 TEST_RUNNER_KITTY_WHISPER_TURBO_SIM=1 TEST_RUNNER_KITTY_WHISPER_TURBO_MODEL=$PWD/Whisper/large-v3-turbo TEST_RUNNER_KITTY_WHISPER_WAV=/path/speech.wav xcodebuild test -only-testing:KittyTests/WhisperRealTests/testTheHybridSettlesWithTheAccurateModel …`
   The same 11 s brand recording that small.en got partly wrong came back from turbo (5-bit, CPU encoder) as: "Buy Maggi and Amul butter from Blinkit. Then ask Rani
   to sweep and mop the kitchen. Remind me to pay the base comb bill on Friday. And order Paralegi biscuits from Zepto." (Rani is right now;
   BESCOM and Parle-G are still spelled by sound.)

## Try on the phone

1. Same sentences as v33 on Turbo, then on Whisper (quick) and Apple Speech: brands, a long multi-task turn with a pause in the middle, "buy milk and bread".
2. How late does the settled text replace the live text after you stop (it should be about a second or two on the Neural Engine)? Does the line
   visibly change under Kitty's hands as it settles?
3. Heat and battery over 10 minutes, memory (does iOS ever kill the app while turbo is loaded?), and the first-load wait.
4. If it is too slow or warm: pick **Whisper (quick)** in the menu, or `KITTY_WHISPER_NO_COREML=1` to see what the CPU encoder costs.

## What was left out of the request, and why

- No whisper.cpp source package and no manual Xcode drag: the prebuilt `whisper.xcframework` is already linked and the `Whisper` folder is already bundled.
- No `import Speech` removal: Apple Speech stays for "Hey Kitty" and the hands-free "stop", and as the fallback engine. Audio capture was already
  engine-neutral and downsampled to 16 kHz off the main thread.
- The 5-bit turbo file is used rather than the 16-bit one (574 MB instead of 1.6 GB); `turbo-f16` is one command away.

# Kitty v33: Whisper as a third speech engine

Moonshine was worse than Apple Speech on the phone (wrong words and brands, no sentence breaks, worse tasks), so **Whisper** is now a third
engine in the same slot. Pick it in the conversation menu: **Speech engine: Whisper / Moonshine / Apple Speech**. It takes effect the next
time the conversation opens, so the three can be compared on the same sentences. The default is unchanged (Moonshine, or whatever the old
"Moonshine speech" switch was set to), so choose Whisper in the menu to try it.

- **Why Whisper.** It writes punctuation and capitals, can be shown the household's names and the Indian brands in a prompt, and is
  generally the most accurate of the three on accents (to be confirmed on your phone). Apple Speech is still used for "Hey Kitty" and for the hands-free "stop" while Kitty talks.
- **It is not a streaming model, so the live text is faked.** `WhisperSession` (`WhisperEngine.swift`) listens with a plain energy detector
  (`WhisperTurnBuffer`, `WhisperAudio.swift`). While you talk, the turn so far is transcribed again after about every 0.6 s of new audio;
  when you pause for 0.9 s one last pass settles the line. Silence never reaches the model, which is most of the battery saving. A stretch is
  capped at 60 s (it becomes its own line and the turn goes on). A slow phone is not run flat out: after a pass it rests for half as long
  as the pass took. Each stretch is one line, the same shape Moonshine's lines have, so `VoiceConversation` is unchanged.
- **Names and brands** go in as Whisper's `initial_prompt`: `KeyTerms.build` (household names first, then the bundled brands), cut at 450
  characters so the household is never cut off. `BrandFixer` still runs after Whisper, with the household's names protected.
- **Its habits on weak audio** are filtered (`WhisperText`): `[BLANK_AUDIO]` and `(music)`, "Thanks for watching" on a short sound, a word or
  phrase looped four or more times, and a segment Whisper itself says is not speech. A real "Thank you" or "Yes" is kept.
- **Per-word confidence** (`whisper_full_get_token_p`) goes into `SpokenWord`, so confidence-based read-back has words again.
- **Audio off the main thread.** The tap hands samples to `MoonshineSink` (reused: it only does the audio-thread-to-engine-queue hop), the
  engine queue converts to 16 kHz (`StreamResampler`), detects speech and runs the model. Only the published text is on the main actor.
- **Model and runtime.** `whisper.cpp` b5454 as a prebuilt `whisper.xcframework` (with CoreML), `ggml-small.en-q5_1.bin` (190 MB) and its CoreML
  encoder (163 MB) in `Whisper/small.en`. On a phone the encoder runs on the Neural Engine; **the first run after install compiles it and takes
  a few seconds** (the model is loaded, and warmed up, when the conversation opens). The simulator has no working Neural Engine path, so it
  uses the CPU encoder (`KITTY_WHISPER_NO_COREML=1` does the same on a phone, to compare speed and warmth). `no_context` is on, so a pass never
  feeds on the text of the pass before it.
- **If it is too slow or warm,** `sh Whisper/fetch-models.sh base` adds `base.en` (about 190 MB with its encoder). The app uses `small.en` if both
  are present, so delete `Whisper/small.en` (or the other way round) to compare.
- **App size** grows by about 350 MB with `small.en`.

## Set-up

1. `sh Whisper/fetch-models.sh` downloads the `whisper.xcframework` into `WhisperSetup/` and the small.en model and encoder into `Whisper/small.en/`
   (both git-ignored). The Xcode project links the framework and bundles the `Whisper` folder. Without the model the menu shows
   "Whisper (not installed)" and the app uses Apple Speech.
2. Open `Kitty.xcodeproj`, set your signing team, run on a phone, and pick **Whisper** in the menu.
3. Real-model check (opt in): `TEST_RUNNER_KITTY_WHISPER=1 TEST_RUNNER_KITTY_WHISPER_WAV=/path/speech.wav xcodebuild test -only-testing:KittyTests/WhisperRealTests …`
   It runs the recording through the same path as the microphone. On the Mac simulator (CPU encoder) an 11 s recording of
   "Buy Maggi and Amul butter from Blinkit. Then ask Rani to sweep and mop the kitchen. Remind me to pay the BESCOM bill on Friday, and order
   Parle-G biscuits from Zepto." came back as "Buy Maggi and Amul butter from Blinkit. Then ask Raani to sweep and mop the kitchen. Remind me
   to pay the base comb bill on Friday, and order Paraleji biscuits from Zepto." (Maggi, Amul, Blinkit and Zepto right; BESCOM, Parle-G and
   the name Rani still wrong).

## Try on the phone (same sentences on each engine)

1. Brands: "order from Blinkit and Zepto", "Aashirvaad atta", "Parle-G", "DMart", "pay the BESCOM bill".
2. A long turn with several tasks and a pause in the middle (the in-laws example), and "buy milk and bread".
3. Punctuation: does a long turn arrive as sentences, and do the tasks that come out match what you said?
4. A noisy room, fast speech, Hinglish words, hands-free "stop" while she talks, "Hey Kitty".
5. Speed and heat: how late does the live text appear after a word, how long until the first words after the mic opens (CoreML compile on the
   first run), and the phone's warmth and battery after 10 minutes. The breadcrumbs log the model load time and the pass count, average and
   worst milliseconds, and the thermal state.

## Known

- The live text moves about every 0.6 s, not word by word. If it feels laggy or the phone warm, try `base.en` or turn Neural Engine off to compare.
- Not tried on a real phone yet: the CoreML path, speed and heat. Only the Mac simulator (CPU encoder) was run.
- "Rani" can come out as "Raani" and BESCOM / Parle-G are not always spelled from the prompt; the next step if it matters is a post-pass for those.
- If Whisper is not good enough either, the next candidate is iOS 26's `SpeechAnalyzer` (native, streaming, punctuated, no app size) behind the same picker.
- Still open: "buy milk and bread" creates only "buy bread"; "Every day the maid sweeps and mops" yields only "Sweep".

# Kitty v32: live speech with Moonshine

Kitty now listens with **Moonshine Streaming** (medium, English) instead of Apple's recogniser for the conversation. Why: it is live
(partials while you speak), it adds punctuation and capitals, it runs on the phone, and it takes **key terms**, so Blinkit, Zepto,
Swiggy, Aashirvaad, Haldiram's, atta, paneer and the names in your household are expected words instead of "blink it" and "alter".
Apple Speech is still used for the "Hey Kitty" wake word, for the hands-free "stop" while Kitty talks, and as the fallback if the
Moonshine model cannot load.

- **One microphone, two consumers.** `AudioCapture` runs one engine and one tap and hands buffers to whichever `AudioSink` is current:
  `MoonshineSink` (downmix to mono Float, inference on its own queue, never on the audio thread) or `AppleAudioSink`. While Kitty
  talks with hands-free stop on, the running mic is handed to Apple Speech (`AppleStopListener`), then back to a fresh Moonshine stream.
- **`TurnRecognizer`** is the surface `VoiceConversation` uses. `MoonshineRecognizer` (`MoonshineRecognizer.swift`) and the Apple
  `SpeechRecognizer` (now in `AppleSpeech.swift`, the only file that imports `Speech`) both conform. The engine sits behind
  `StreamingEngine`/`EngineSession`, so tests use a fake one.
- **Key terms.** `KeyTerms.build` = the household's names (max 40) then `IndianVocabulary.terms` (brands, staples, festivals), at most 120.
  The list is set when the model loads and refreshed at every turn. Boost is 2.0 (`kitty.moonshineBoost`; 3.0 helps brands more and
  costs a little on other words).
- **`BrandFixer`** repairs what the key terms miss, conservatively: "blink it" to Blinkit, "Maggie" to Maggi, "parle g" to Parle-G, "zip tow"
  to Zepto. Only one clear match, never a short or everyday word, never a name the household uses, never "pay them" to Paytm. Anything
  doubtful is left to the "Did you say…?" read-back.
- **Slower to answer, on purpose.** `longPause` 1.6 to 3.5 s and `quickNudgeAfter` 3.5 to 5.0 s; the pause caps are now `longPause + 1.5`
  and `longPause + 2.5` (they were 3.2 and 4.2, which would have cut the new pause short). People think aloud, and Moonshine ends a line on a pause.
- **`TranscriptPolicy.raw`** (default on in the app, off in unit tests, menu: "Trust the transcript as spoken"). The cleaner passes words
  through, and a long turn skips `BulkDetector` and the clause digest: the whole punctuated turn goes to the model in one `decideBulk`
  prompt and it splits it (`raw-bulk` route). Validators, dates, assignees and read-back still run. Cost: "clean the… no wait, wash the
  car" is no longer repaired by rules. If it is worse on your phone, turn it off.
- **Menu**: "Moonshine speech (off: Apple)" switches recogniser on the next conversation, to compare the two.
- **Breadcrumbs** log the model load time, per-session pass count / average / worst milliseconds, end-of-phrase latency and the thermal state.

## Set-up

1. `sh Moonshine/fetch-models.sh` downloads the medium model (268 MB) into `Moonshine/medium-streaming-en/` (git-ignored). The folder is
   bundled in the app as a resource. Without it the app still works, on Apple Speech.
2. Open `Kitty.xcodeproj`; Xcode fetches `moonshine-swift` 0.1.5. Set your signing team and run on a phone.
3. Real-model check (opt in): `TEST_RUNNER_KITTY_MOONSHINE=1 TEST_RUNNER_KITTY_MOONSHINE_WAV=/path/speech.wav xcodebuild test -only-testing:KittyTests/MoonshineRealTests …`

## Try on the phone

Brands ("order from Blinkit and Zepto", "Aashirvaad atta", "Parle-G", "DMart"), the in-laws example with a pause in the middle, a noisy room
and fast speech, Hinglish words, hands-free "stop" while she talks, "Hey Kitty", and 30 minutes of use for battery and warmth. Note wrong
words, punctuation, lag, and anything worse than Apple. If Moonshine is not good enough, the Whisper plan is the fallback.

## Known

- Checked on the Mac and simulator with synthetic English (India) voices only: "Maggie", "Ashavad atta", "dhong" (DMart) and "peril g" can still
  be wrong; real Indian speakers on a phone are the real test.
- Moonshine gives no per-word confidence here, so confidence-based read-back and the learned pause profile see no words from it.
- Still open: "buy milk and bread" creates only "buy bread"; "Every day the maid sweeps and mops" yields only "Sweep".

# Kitty v31.1: non-answers, vague placeholders, bulk routines

- **Non-answers get an honest reply.** "I don't know", "no idea", "I really don't know", "nothing" are neither an answer nor a request:
  Kitty says she is unclear what to do and that nothing was done. She never lists your tasks for them (`UnclearAnswer`, with a gate,
  a route step in `VoiceTurnManager`, and a guard on the model's "view" and "ask" answers).
- **Vague placeholders are asked about.** "Add a task for the project" names no task, so Kitty asks "What would you like the task to be
  for the project?" instead of creating one titled "Project" (`VaguePlaceholder`). The answer becomes the real task, and a request that
  names something specific ("add a task to call the project manager") still just works.
- **Bulk routines, schedule first or by a named person.** "Every day: sweep, wash the dishes", "Every Sunday clean and mop" and "the maid
  should sweep every day and mop every Saturday" become separate routines, each with its own schedule and assignee; "weekly" or
  "monthly" alone is asked about ("Which day should I mop each week?") and the answer fills that routine.
  Known gap: a single third-person sentence like "Every day the maid sweeps and mops" still yields only "Sweep".
- **Tests no longer depend on the machine's model.** `TaskPlanner.onDeviceModelAllowed` keeps the on-device model off under XCTest
  (unless KITTY_REAL_MODEL=1), so scripted tests and evals give the same result whether Apple Intelligence is ready or not. Titles
  returned by the model are sentence-cased like the rule path's.

# Kitty v31: long, noisy speech

Someone who says "my in-laws are coming this Saturday and the house is a mess, so the maid should clean the bathrooms on Friday, oh and
I need to buy flowers, also remind me to call the caterer" gets four tasks, not a story. The model still only classifies and extracts;
Swift decides what is saved.

- **Long turns** (LongTurn.swift). `LongTurnAnalyzer` splits the speech into clauses and tells the asks from the chatter. It keeps one
  shared context (a day, an occasion) and one action clause per ask. A person (the maid, the driver) belongs to the clause that names
  them as the one doing it, not to "pay the maid". The occasion goes into the notes ("For in-laws"). Chatter ("so tired today") never
  becomes a task and its "today" is never a due date.
- **Fewer, smaller model calls.** A long turn sends a digest (the context first, then one line per action) instead of the ramble: at most
  4 actions per call and at most 3 calls. Whatever the model leaves out, or whenever it only says "wait", comes back from the clauses, so
  nothing the user asked for is lost. `BulkValidator` drops what was invented, and a day or person the model spread to every task stays
  only on the task that said it.
- **A day nobody said is asked, never written.** After the preview Kitty asks: "I picked these because of Saturday, for in-laws. Should I
  tag the ones without a date as due Saturday?" Yes tags only the undated tasks and shows the preview again. No leaves them dateless.
  Anything else drops the question. A task with its own day ("Friday", "next week") keeps it.
- **Preview** shows a "Used:" line (what was taken from the story) and a collapsed "Skipped (N)" list of what was heard but not made a
  task. Tap to add one back; saying "also add ..." works too.
- **Patience** (`PauseProfile`, in Agent.swift). Kitty measures the gaps between your words (median and 90th percentile, kept on the
  device only) and waits longer for someone who talks slowly. After a comma or a connector ("... the bathrooms, and") and deep in a long
  unfinished turn she waits longer still; a short "yes" after a long preview does not count as a long unfinished turn.
- **Live "Hearing N tasks" chip** while you talk (`HearingChip`, throttled, from the partial words alone, no model call).
- **Evals** (Tests/KittyEvals.swift, EVALS.md section K): 30 cases (108-137) with a scripted model. Four more metrics: K1 task recall,
  K2 task precision, K3 chatter-as-task rate, K4 context-carry accuracy. `testFullSuiteAndMetrics` asserts K1, K2 and K4 are at least 90%
  and K3 at most 5%. They measure the rules around the model, not Apple's model: `RealModelKTests` (set KITTY_REAL_MODEL=1) runs the
  cases against the real model, and REAL_MODEL_RUNS.md says honestly that this has not run yet (the model was "not ready" on this Mac).
  Note: the eval cases that use the local rules read the list names from UserDefaults, so the runner clears them first.

# Kitty v30: bulk creation, slot-filling clarification, one-shot confirmation, eval suite

Extends v29 (nothing replaced): the app still gates, the model still decides, Swift still validates.

- **Bulk creation** (BulkAgent.swift). BulkDetector spots lists ("add these tasks: ..."), verb-led lists, routine lists ("every day: ...")
  and playbooks before the model is called. "Buy milk and bread" is one task; "clean the bathroom and buy milk" is two. The model returns a
  BulkAgentDecision (@Generable TaskDraft / RoutineDraft / PlaybookDraft); BulkValidator drops invented items, resolves dates in Swift and
  checks every draft. Bulk drafts, playbooks, updates and deletes always wait for an explicit "yes". A single task or routine still saves
  after the 2-second countdown. 2-5 items are named ("Should I save these?"), more than 5 are summarised by category. After saving: one
  grouped line, "Saved 4 tasks: bathroom, groceries, plants, and trash."
- **Editing a draft before saving** (BulkDraftManager + DraftEditParser): "change milk to bread", "also add water plants", "no, remove
  the trash task", "make the bathroom task high priority", "change the first step to buy vegetables", "add a playbook step: buy groceries".
  Each touches only that item.
- **Clarification state machine** (ConversationStateManager.phase): idle, listening, pendingTask, pendingRoutine, pendingPlaybook,
  pendingBulkDraft, awaitingClarification, awaitingConfirmation. ClarificationStateManager asks exactly one missing required field
  (a task: an actionable title; a routine: title + schedule; a playbook: name + a step), never repeats a question, never asks for optional
  metadata (due date, priority, assignee, category, notes), and after three rounds proposes its best reading: "Should I save it this way,
  or would you like to change something?". The "Are you done?" loop is gone: a long silence on "Add a task to..." now asks what the task is.
- **Yes executes once** (ConfirmationManager): every proposal is armed once and consumed once, so a spoken yes, a tap and the countdown
  cannot save twice. A bare "no" asks what to change; only cancel/discard/never mind throws a preview away.
- **Evals** (Tests/KittyEvals.swift): 60 numbered cases (A-G), 15 regression cases (I), conversation-quality grading (H, a judge that checks
  brevity, one question, no robotic wording, no repeats), and the 13 metrics. EvalRunner replays recorded utterance sequences with a
  scripted model and an in-memory SaveSink, and writes every model input/output, validation result, spoken reply, state and saved object to
  /tmp/kitty-eval-report.json (or $KITTY_EVAL_REPORT). `testMinimalTwelve` is the starter set; `testFullSuiteAndMetrics` is everything.
  Run: xcodebuild test -scheme Kitty -destination 'platform=iOS Simulator,name=iPhone 17' -only-testing:KittyTests/KittyEvals

# Kitty v29: voice turns (hybrid: app gates, model decides)

The app buffers speech and decides WHEN a turn might be finished; the on-device model decides WHAT it means, at most once per
likely-complete turn. Short pause: keep listening. Longer pause (1.6 s): a local check (LocalSemanticPrechecker) rejects unfinished
speech ("Add a task to clean the...", "The bathroom", "Buy...", "...and") without calling the model. Otherwise one model call returns
an AgentDecision (wait / clarify / create_task / create_routine / create_playbook / update / complete / delete / view / unrelated).
TaskValidator checks it in Swift before anything is saved (actionable verb + object, dates resolved from your calendar, nothing
invented, categories checked, duplicates). "done", "save it", "go ahead", "that's all" end the turn or save what is pending.
New in the app: priority, notes and a specific category name (Bathroom, Groceries) on tasks.
Where things are (all in Agent.swift): PersistentInstructions, AgentDecision, PromptBuilder, LocalSemanticPrechecker, TaskValidator,
ConversationStateManager, VoiceTurnManager, DecisionExecutor. Unit tests: Tests/KittyVoiceTurnTests.swift (add to a TEST target only).

# Kitty v28: understanding the pause

In Talk to Kitty, a pause doesn't always mean "done". After a short pause (about 1.3 s) Kitty acts only if what you said is a
complete thought ("add milk to my Blinkit order", "yes"). A trailing fragment ("milk and", "make it") is held: Kitty waits.
After a long pause (about 4.5 s) with nothing she can act on, she asks "Are you done? Shall I go ahead and create something on
those lines?" with Yes, go ahead / No, I'm not done. When Kitty creates tasks, the tasks themselves appear as cards in the
conversation, not just a "added" message. Swipe a card left to delete it.

# Kitty v27: lists made by talking

Say "add milk and eggs to my Blinkit order". Kitty spots "Blinkit order" as a list, creates it if it is new (the preview
says "New list") and puts the items on it. Items on a list have no due date, so they never show as overdue or in Today.
Later: "what's in my Blinkit order", "I placed the Blinkit order" (marks everything done), "clear my Blinkit order",
"rename my Blinkit order to Zepto order", "move milk to my Zepto order", "start a new Goa trip list",
"delete my Goa trip list". Lists show as chips above the task list; long-press a chip for more, long-press a task to move it.
Kitty's replies now show the list first and the first two sentences of text, with More for the rest.
The Kitty guide has a new box, "How Kitty handles lists", that tells the model how to recognise a list.

# Kitty v26: the Kitty guide

Home > ... > Routines, playbooks & guide > Kitty guide: plain-text rules for how Kitty organises (order by time of day,
who gets what, when to ask instead of guess, never invent tasks) and how she replies (short, spoken, facts only, name the
first three of a long list). Editable, with a field for facts about your home. The guide is added to every on-device model
call. Answers to questions are worded by the model from facts Kitty works out herself, and are dropped if a number
isn't in the facts. Repeated chores show once with a count ("Clean dishes +2"): tick finishes one, long-press finishes all.

# Kitty v25: one way in

All of Kitty's separate Siri / Shortcuts actions are gone. There is one: Talk to Kitty, which opens the app and starts
listening. Everything else happens by talking inside the conversation.
Ways to open it: "Hey Siri, talk to Kitty" (also: speak to / chat with / hey / hi / hello / ask / start Kitty), Spotlight
(type "Talk to Kitty"), long-press the app icon > Talk to Kitty, Action Button or Back Tap set to the "Talk to Kitty"
shortcut, a Lock Screen or Control Center shortcut, and the optional "Hey Kitty" listener while the app is open.

# Kitty v24: open Kitty by voice

"Hey Siri, talk to Kitty" (also "hey Kitty", "hi Kitty", "start Kitty", "chat with Kitty") opens Kitty straight into the
conversation and starts listening, from the Home Screen or Lock Screen (Siri asks you to unlock). The same shortcut
("Talk to Kitty" in the Shortcuts app) can go on the Action Button or Back Tap.
iOS does not allow an app to listen for its own wake word in the background. Optional: Home menu > "Listen for Hey Kitty
while open" listens while the home screen is showing. Set Display Name to "Kitty" (Target > General) so Siri hears the name.

# Kitty v23: a conversation

Talk to Kitty is now a conversation. The mic stays open while you pause; Kitty works out what you mean only after a
real pause (longer if you trail off on "and", "then", "to the"...). If you keep talking, it is added to what you said
and the preview updates. She shows a preview of what she will do, with a button that fills in 2 seconds and then
applies; Discard, or saying "no", throws it away; saying "yes" applies it now. Deleting and clearing never apply by
themselves. If something is missing or unclear, Kitty asks instead of guessing (for example "Which day of the week?").
Straightforward things run right away: questions, and finishing one clearly matched task.
Home is just: Talk to Kitty, a box to type, and "Show all tasks". Filters live in a collapsible bar on the task list.

# Kitty v22

Smart order: tasks are ordered through the day. Apple Intelligence decides when each task is normally done
(morning walk first, evening walk later) or uses the exact time you say ("walk at 6 am"). The list shows
Morning / Afternoon / Evening / Night headers, a time tag on each card, and Kitty reads answers in that order.
Falls back to keywords (morning, lunch, dinner, bedtime...) without Apple Intelligence. Playbook steps keep your order.

# Kitty v21

Smart chips: Open / Overdue / Done / All with live counts (Overdue appears only when something is overdue), plus
"Show all tasks" / "Back to today". Kitty reads what you ask: "show open tasks" shows only open tasks, "what is overdue"
shows the backlog, "show completed" shows finished ones, "show all tasks" shows everything.

# Kitty v20 (redesign)

Home: greeting, filters (person chips, Today / Tomorrow / All, category menu), clean task cards, overdue in red,
playbooks as collapsible cards, completed tasks tucked away. Bottom: type to Ask/Add (works like talking) or tap the mic.
Menu (...): Routines & playbooks (and diagnostics), Clear completed.
Talk to Kitty: while you talk you see only your words and a pulsing mic. When you stop it sends itself in 2 seconds
(tap anywhere to edit), then shows Kitty's answer with the matching task list.

# Kitty v19

Talk to Kitty starts listening as soon as it opens (first time: allow Microphone and Speech Recognition). Tap the mic to stop.


Kitty no longer talks by default. Turn on "Read replies aloud" on the Talk to Kitty screen (remembered), or tap Listen on any reply.


Screens: Talk to Kitty now shows a task list under the transcript with assignee chips (All / Mine / Me / Family /
Househelp / ...), a Today / Tomorrow / All switch, tags on every task, a checkbox to mark done, long-press to reassign
or move, and playbooks as collapsible cards. Kitty picks the chip, day and category from your question.
"Show my tasks" = tasks tagged Me or Family. Overdue tasks are red with "N days overdue" and sit in their own section.

Repeating schedules: every day, chosen weekdays ("every Saturday and Sunday"), alternate days ("dust every other day",
"every 3 days"), every other week ("every other Saturday"), and monthly ("on the 5th of every month").
Backlog: a routine task nobody finishes stays open with its old due date and is listed again the next day under
"Backlog from earlier". Days missed while the app was closed are filled in too (up to two weeks).

Every task now has an assignee (Househelp / Me / Family / a name) and a due date. Kitty works them out from what you say; chores default to Househelp, everything else to Me, and no date means today.
  "What are the tasks for tomorrow for the house help?" -> routines + one-off tasks due that day, then anything still open from before.
  Change them by voice: "assign sweeping to the cook", "move mopping to tomorrow" (or to Saturday).

Routines, bigger jobs, and a real "what's today":

- Routines:  "every day the maid sweeps and mops", "wash restrooms every Saturday", "on weekdays water the plants"
             Saved once; a fresh copy appears each day it is due. Missed ones don't pile up.
             Ask "what are my routines?" or say "stop the weekly restroom routine".
- Playbooks: YOU teach Kitty how a job is done; Kitty never invents the steps.
             Say: "Here's how I make biryani. The cook marinates the chicken. The maid washes and soaks the rice.
             I fry the onions. The cook layers and dum cooks it. The maid cleans the kitchen."
             Kitty saves it with who does each task. Later, "I'm planning to cook biryani on Sunday" ->
             Kitty asks "Add them for Sunday? Say yes or no." -> yes creates the tasks (each with its person).
             "What playbooks do I have", "show my biryani playbook", "forget the biryani playbook".
             Teach again with the same name to replace it. "What does the maid have to do today?" works too.
- Today:     "what are my tasks for today" -> routines, then each playbook with numbered steps, then one-off tasks.


AI failures are now logged in the Diagnostics box on the main screen (lines starting "AI").

When Kitty falls back to simple rules, it now says why (device unsupported, Apple Intelligence off, model downloading, or iOS too old).

After you speak, the Send button fills left to right over 2 seconds and then sends by itself.
Tap anywhere (text box, empty space, mic) before it finishes to stop it and edit.
Typed text is never auto-sent.

Talk to Kitty (and the text box / Siri "Ask Kitty") now handle the full task lifecycle:

- Add:       "my househelp needs to dust and chop vegetables today"
- List:      "househelp tasks for today", "what's left at work?"
- Complete:  "mark dusting done", "I finished chopping vegetables", "mark all househelp tasks done"
- Reopen:    "reopen dusting", "mark dusting as not done"
- Rename:    "rename dusting to dust the shelves"
- Delete:    "delete the vegetables task", "delete all errands"
- Clear:     "clear completed tasks"

If a phrase matches more than one task, Kitty asks which one instead of guessing.
Bulk delete needs a category ("delete all errands").

Files (6, app target only): QuickTasksApp.swift, Intents.swift, TaskStore.swift, Agent.swift, SpeechRecognizer.swift, ConversationMode.swift
Info keys required: Microphone + Speech Recognition usage descriptions (missing keys crash the app on mic tap).
- Eval catalogue: see EVALS.md (regenerate with KITTY_EVAL_CATALOGUE=$PWD/EVALS.md and -only-testing:KittyTests/KittyEvals/testWriteEvalCatalogue).
