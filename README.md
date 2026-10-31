# Kitty: an attribute is kept only when the user's words say it

What changed (`build` and `build-for-testing` succeed; the `TaskExtractionTests` run has 8 failures, see "Not verified"; nothing was measured on the real model):
- **Rule:** a person, day, time, part of the day, timeframe, repeat, category, purpose or list is stored only when the user's own words for THAT
  task state it. No evidence, no value. Full table: `ATTRIBUTES.md`.
- **New `EvidenceGate.swift`**, one call in `TaskDraftMapper.item` after `WhenReader`. Words of a task = the whole answer for one task, otherwise
  the clause holding most of its title words; with several tasks and no clear clause only what the task's own fields carried counts. A value
  with no phrase there is cleared (trace: `SWIFT <attribute> "<value>" dropped: no evidence in the words`), and the phrase that backed each kept
  value is saved in `evidence`. A plausible person that was dropped leaves a card note ("I heard "School" as a person but it isn't someone I know").
- **Silent defaults removed:** no category guess (category filter shows untagged tasks under "Other"); no stored "due today" (undated tasks
  show "No date", are not in Today and not overdue); no assignee from the category (unassigned is blank, and "Mine" includes unassigned); the
  "(assumed)" preview tags and note are gone; routines, playbooks and list items are no longer given a guessed category or assignee.
- **WhenReader no longer guesses am/pm:** "at ten" with no period and no day-part reads no time, keeps the words and flags "Time needs a fix".
  "kal" is still tomorrow (past-marker rule, with a note).
- **Shown:** a "Your words" line on draft previews and a caption in the edit sheets; hand edits are marked "added by you"; tasks saved before
  this change show nothing (their `evidence` is empty).

Limits: the gate checks that a phrase is in the words, not that it is the right phrase; a recogniser error counts as evidence; the "No date"
marker is the pill on each card, there is no separate "No date" section header; the stage-5 defaults are a product change that can be reviewed separately.

Not verified: `TaskExtractionTests` has 8 failures. One (`testAListIsMadeOnce...`) asserted the removed default and has been updated, not re-run.
The others (`testCreateWithNoUsableTask...`, the 12-task and window tests whose titles are "Task N", `testAnEditWithAPartOfTheDay...`,
`testAnUnrelatedEdit...`) were not traced to a cause, so it is not known whether this change or earlier ones produced them. No new scripted
tests for the gate were written, and the scoreboard invented-attribute check and 60x3 run were not done (they need the on-device model).

# Kitty: days and times are read in Swift from the user's words

What changed (build-verified only: `build` and `build-for-testing` succeed; no test was written or run and nothing was measured on the real model):
- **New `WhenReader.swift`**, one call in `TaskDraftMapper.item`. It finds a day, a time, a part of the day or a timeframe that the model left
  in the title, the purpose or the repeat field, or gave as words Swift could not read ("six thirty", "kal", "four am on Friday",
  "before Diwali", "this month"). It fills only what the task has not got, cuts the phrase out of where it was, and never overwrites a value.
- **Reads:** today, tomorrow, weekdays, aaj, kal, parso; morning to night and subah, dopahar, shaam, raat (only with a cue); digit and spoken
  clock times (six thirty, half past six, quarter to five, at ten); timeframes kept as said (next week, month end, before Friday, before
  Diwali, before eleven).
- **Guesses, flagged on the card:** with no am/pm and no day-part, 7 to 11 is the morning and 1 to 6 the afternoon or evening ("at ten"
  10:00, "at five" 17:00); "kal" is tomorrow unless the words are in the past. Both add a note you can tap to fix.
- **Careful:** numbers with a unit or a count ("five apples", "two kg") are not times; a text that says how often (every, daily, alternate,
  weekdays) is never touched; with several tasks in one sentence a phrase is not copied from the sentence onto a task that did not carry it.
- **Not changed:** assignees such as "Kal", purposes that are really instructions, leftover frames in titles, task splitting, ordinal dates.

# Kitty: stop refusing valid tasks, and stop dropping tasks on "wait"

What changed (build-verified only: `build` and `build-for-testing` succeed; no test was written or run and nothing was measured on the real model):
- **The shell rule.** A title is refused as a spoken command only when it starts with a frame ("can you", "I want to"...), or starts with a
  command verb (add, create, make, remove, delete, start, set, remind) and names an app object or ends in "list". Length alone no longer counts,
  so a whole sentence as the title is accepted. Filler sounds (uh, um, hmm...) say nothing, so "uh the..." is still no task, and "remind me" is
  refused while "Remind me about parent teacher meeting" is kept. Only an edit's retitle that copies the whole spoken sentence is refused.
- **Wait with tasks.** On a final turn, if the model said wait (or clarify with no question) but its answer holds valid tasks, they are used
  (the trace says so). While the user may still be talking, wait still waits.
- Not changed: card content (purposes in the wrong place, unread times, invented people, leftover words such as "remind me of ...").

# Kitty: every detail on the row and the card, and one form to edit a task

What changed (build-verified only: `build` and `build-for-testing` succeed; no test was written or run, and the new rows, cards and sheets were
not looked at on screen, see the last bullet):
- **One helper for the lines under a title** (`TaskDetailLines.swift`, no SwiftUI): Why (purpose), How (instructions), Repeats (the repeat as
  said, else the parsed text), Around (a timeframe such as "next week", only when there is no day) and For (a person, only when no tag says
  it). Empty values and a value equal to the title are left out. A new field (a quantity, a place) is one more case and one more line there.
- **Preview rows** (`PreviewRow.details`, filled in `Proposal.bulk`, drawn by `proposalRow`) and **saved cards** (`TaskRowBody`) show those
  lines in small grey text, two lines each. The preview leaves out the timeframe and person (their tags show them) and the unreadable-repeat
  line (the orange tag shows it). The saved card never shows `notes` as the user's words; a "Repeat not understood: X" in the notes shows as an
  orange "Couldn't read the repeat" line.
- **One form** (`TaskFieldsForm.swift`): the draft sheet and the saved-task sheet use the same fields and the same `TaskFormState.commit()`:
  title, list, why, how, day, time, part of the day, timeframe (always shown, off when a day is set), repeat, priority and person. A day or
  time is rewritten only when you change it. The draft sheet keeps its Evidence section and buttons; the saved sheet keeps Done, Category
  and Delete, and shows notes read-only.
- **Editing a saved task:** tap the card (the checkbox keeps its own tap; swipe to delete and the long-press menu are unchanged), change
  fields, Save. If the change cannot be stored, the task is put back as it was, the sheet stays open and says "Couldn't save the change."
  (`TaskStore.update` now rolls back). A new list name is made when you Save, and taken back if the save fails.
- **The repeat on a saved task is kept as your words.** Editing it does not turn the task into a routine (the sheet says so). On a draft,
  a changed repeat is still read again by Swift, as before. A routine's copy for today cannot change its repeat.
- **Limits.** `quantity` and `place` do not exist yet. Saving a saved task that has both a day and a timeframe drops the timeframe, as the old
  sheet did. Not checked on screen: the simulator was booted with seeded tasks and the app launched, but no screen past the home screen was
  looked at (no tool here could tap), so the row and card layout, Dynamic Type, dark mode, a small iPhone, and tap against swipe and long-press
  are unverified.

# Kitty: garbled dictation, list names, restatement and duplicates in the draft

Trace: two turns of "Add House Add hostel task for tomorrow I said, add Househelp tasks for tomorrow ..." gave a list called "House Add hostel",
then a second turn re-sent two tasks with the day in the schedule field, flagged "Repeat not understood", and added them again.

What changed (build-verified only; no test was written or run, nothing was measured on the real model; no instruction text was changed):
- **List names.** A list the model names is used only if it exists, or the words say list, order or cart, or an existing list is found in the
  words. A name with a command word is refused. When one is refused the first item says so; the tasks keep their person and day.
- **Restatement.** Words before "I said," / "I meant," (with a comma or colon) are shown under Skipped and the extraction reads what follows.
- **Header only.** "I said, Househelp tasks" (or only a day, time or existing list) while a draft waits sets the person, day, time or list on the
  items that have none, with no new task and no model call. The card says what was set, or that the tasks already have it.
- **Day in the schedule field.** Read as the day, not a repeat; no "Repeat not understood". The model now sees draft days in words.
- **Duplicates.** The merge compares title, person, day, time (and the repeat of a routine); list, instructions, reason, category, priority and
  notes may differ only where one side is empty. The copy fills the empty fields and the item gets "Already on the list".
- **Every draft item** is sent to the model; the trace says how many, or that none fit. A title mostly of low-confidence words gets "I wasn't sure
  I heard this one right. Tap it to fix it." (only when the recogniser reports confidence).
- **Limits.** A garbled but plausible title cannot be recognised from the words. The merge cannot tell an accidental repeat from a meant one
  (only `distinct`, which the flat path cannot set); the card note is how you notice. The "I said," cut is a shape rule and may cut a real "I said,".
  A real list said without a cue ("list", "order", "cart") is now dropped, with a note on the card. Why the first item (d1) was missing in the
  second turn is not proven: the state sent held every item, and no merge was in place at that time. Hearing the speech merge repeat is only noted.
  Nothing was measured on the real model.

# Kitty: the same task is not added twice to a preview

Trace: dictating over several attempts and repeating yourself ("I said, add a task...") left two copies of the same items on the
draft ("Admin house" and "clean the baby mat", each twice). Drafts only compared items inside one answer, never across turns.

What changed (build-verified only; no test was written or run, nothing was measured on the real model):
- **Exact copy: merged, visibly.** A new item that is the same request as one already on the draft is not added as a row. The item
  already there keeps its place, ref and id and gets the note "Already on the list"; the card and the log say "Already had clean the
  baby mat." Same request means the same title, person, day, time, list and repeat, and the same category, priority and notes
  (`BulkDraftManager.existing(matching:in:)`). It applies to what you say (`join`), to what the model adds in an edit, and to an item
  you add by hand in the edit sheet.
- **Still two rows:** the same title for someone else or on another day, time or list ("Looks like another item" as before), and an
  item the model marked `distinctBecause` in the older answer format (`DraftItem.distinct`).
- **Limits.** Only exact copies. The flat answer cannot mark a deliberate repeat, so "two of those" said in a later turn, or the same
  task added by hand with nothing different, merges; change any field to get a second row. The note on the card is how you notice.
  The garbled name on the last item and the lost-request routing bug are separate and untouched. Saving was not run: one merged
  item is one row, so one task is what the card would save.

# Kitty: transcript text appeared twice (hybrid speech merge)

Symptom: after a pause the transcript sometimes said the same words twice ("add a task to buy milk to buy milk", or "... milk milk"). Whisper's text for a
phrase was in, and Apple's late words for the same phrase were still beside it.

Cause (from the code and hand-traced cases, not seen on a device): `HybridTranscript.merge` gave an Apple word to a settled phrase only by its time
(within 0.15 s of the phrase) or, untimed, by the word count Apple had when the pause was seen. Apple is behind the audio, so words said inside the phrase
can arrive after it, a little past its end or past that count, and then belonged to nobody and stayed beside Whisper's full text.

What changed (build-verified only: the new tests compile, none was run, per your choice; nothing was measured on a device):
- **Merge** (`HybridTranscript.swift`): untimed words inside a timed list are placed between their timed neighbours; a settled phrase also takes the Apple
  words right after its own that continue its text word by word (timed ones only within 0.5 s of its end and before the next phrase), so a word of the next
  phrase is never taken ("buy milk" then "milk chocolate" keeps both); a safety net removes a leftover run of two or more words that repeats the end of the
  settled text, unless the settled text itself repeats there. Details in `ALGORITHMS.md` 4.6.
- **What you see is what is sent.** The screen and the model read the same merged text, so there is one clean transcript and no separate show/send logic.
- **Replacement is not a restart.** Whisper's text can share no word with the garbled live words it replaces; `TurnAccumulator.absorb` now takes a hint
  (`HybridRecognizer.lastChangeWasSettle`) so that is not mistaken for the recogniser starting over (which would have put the same speech in `carry` twice).
  A repeated `phraseEnded` id is ignored.
- **Trace** (console trace or "save task details" only): whether Apple's partial words carry timestamps, and the phrases, words, origin and rule used whenever
  a late word was claimed, the safety net acted, or the result still repeats a run.
- **Tests** (`Tests/HybridTranscriptTests.swift`): the cases above, genuine repeats ("No no I said no.", "very very"), and recogniser-level cases.

Not known: whether Apple's partial words carry timestamps on a device (the trace will say), how long after a pause its last words arrive (0.5 s is a choice
from the 0.65 s minimum gap, not a measurement), and whether the words dropped by the safety net were ever really said twice.

# Kitty: state-based extraction for multi-sentence dictation (flat path)

Trace: "Add house help tasks for tomorrow. Clean baby mat. Refill, Detal, Hand wash. Soak, Washclots." lost "Washclots" and gave "Soak" no
person and no day. While a draft waits, the extraction only saw the new words (`Request: Soak, Washclots.`), a trace line said the draft
was sent when it was not, nothing checked that every word became something, and a misheard word went straight into a title.

What changed (build-verified only; no test was written or run, nothing was measured on the real model):
- **State, not history.** While a draft waits (flat path, no playbook), the prompt is `STATE` (the scope, then the draft by ref) plus
  `Request:` with only the new words (`FlatPrompt.state`). The earlier transcript is never sent. To fit the measured window the draft
  gives way in order: full item detail, title and category, titles, no draft items. The scope and the new words are never cut. The false
  trace line is gone; `flatAnswer` now traces exactly what was sent.
- **Scope.** The answer can carry a person, day and time said once for several tasks (`assignee`, `dueDate`, `dueTime`) and `leavesScope`.
  `ScopeReader` checks each one (a person is a known name, a role, or in the words; a day and a time must read through `DateResolver` and
  `TimeResolver`), drops what fails with a WARNING, merges it with the draft's `DraftScope`, and fills only the fields a new task left
  empty; a task's own value wins. The scope is kept on the draft (`BulkDraftManager.scope`, in the version, cleared with the draft) only
  when the tasks are committed. `leavesScope` is one addition to the brief: with a scope in force, "not given" cannot tell "not said" from
  "not for this scope", so the model says it. Behind `FlatExperiments.scopeLine`.
- **Coverage.** `Coverage.uncovered` lists the content words of the new words that no task, person, day, list or scope accounts for. When
  there are any and an accepted sentence came before, one more call asks with that sentence added (`FlatExperiments.coverageRetryCall`);
  the second answer is used only if it leaves fewer words uncovered, and tasks already on the draft are not added twice. What is still
  uncovered is recorded as a `HeardChunk`, shown on the card with "Try again" (`Proposal.recovery`) and kept as a skipped chip ("also add ...").
- **Spelling.** `SpellingHints` (in `VocabularyProvider.swift`): a word the system spell checker does not know, that sounds like a word this
  household uses (consonant skeleton plus edit distance) is offered as "Did you mean ...?" on the task's row; a word the recogniser scored
  under 0.5 gets "I wasn't sure I heard ...". Nothing is rewritten.
- **Latency.** Each model call writes `TIME: extraction call n of m: x s`. `VoiceTurnManager.speculativeExtraction` (off) starts the extraction
  beside the intent call. The hold is unchanged. See `REAL_MODEL_STATE_EXTRACTION.md`.

Phone script: (1) the four sentences above with 4 s pauses: the trace shows `sent beside the new words: scope person: Househelp; day: tomorrow;
draft d1 ...`, and "Soak" and "Washclots" come out with the person and day. (2) A garbled first chunk, then a good one: the `HeardChunk` and the
note appear. (3) After the list, "also buy milk for me": it is not given the house help scope. (4) "for Zorblax", "day blorp": a WARNING says the scope was
not accepted, and it is not stored. Nothing was committed or pushed.

# Kitty: no loops, one clean lifecycle per turn (flat path)

Trace A: "Create a task. Create a shopping list." The model proposed "Create a shopping list", the echo rule refused it (it ends in
"list"), the question call wrote a question that `registerModelQuestion` suppressed as a repeat, and `askForContent` returned `.wait`.
`.wait` meant both "still speaking" and "nothing to show", so the words stayed in the turn and the long-silence nudge ran them again
about every 3 s (two model calls each) until the screen closed. This is the cause found from the code and the trace; it was not reproduced
in a test (none was written or run this round).

What changed:
- **`TurnResult.handled`**: the words are consumed and there is nothing to show. `.wait` now only means "still speaking, keep the words".
  Returned by the three `askForContent` failure paths, an exhausted question and a repeated `notApplied`.
- **Consume on terminal**: `VoiceConversation.consumeTurnWords()` clears the turn text (carry, session, turn, committed, processed, last
  acted, nudged, final-tried) and restarts recognition, because the recogniser reports cumulative text and would bring the words back.
  Done for `.handled` and for `.question` (after the question is shown; the stage stays `.question`). A preview's words are not cleared.
- **`judge` order**: empty, finalizer, already-final (`finalTried`), nudge, already-looked, pause. The nudge's final pass still runs once
  per distinct words, then silence alone never sends them again.
- **Question verdicts**: `registerModelQuestion` returns `.ask`, `.again` (the same question once more) or `.exhausted` (a third
  showing, or three rounds). Exhausted resets the clarify state and returns `.handled`: idle, mic ready, typing visible. No question is
  written by Swift.
- **Safety nets**: a circuit breaker (`VoiceTurnManager.breakerWindow` 10 s): the same words, in the same state and final flag, a
  second time inside the window make no call and answer with a short typed-input message. A watchdog in `VoiceConversation`:
  thinking over `thinkingTimeout` 60 s is cancelled and the turn resets with a notice; already-looked words with no new sound for
  `staleWordsTimeout` 25 s are dropped and listening restarts. All three values are unmeasured guesses.
- **Feel**: while the words hold no task yet, the status line reads "Listening for the task…" (a label, not a question). Holds are
  unchanged (`noContentExtraHold` 0; the usual 4 s pause).
- **Trace**: the last line of every turn is `turn N ended: <wait|handled|question|proposal|reply>; the same words have come K time(s) in
  a row`. The watchdog writes `turn ended: idle`.

Not run: no tests were written or run, and nothing was measured on the real model. Phone script: (1) say "Create a task. Create a
shopping list." and stay silent 30 s: one question (or one re-show), then idle, no repeating `HEARD ... (final)`. (2) "add a task",
pause, "create a task", pause: no stacked words after a question. (3) After a question say "buy milk": one task. (4) Say "create a task"
and stay silent: a question, then nothing repeats. (5) Check each turn ends with `turn N ended: ...` and the counter stays at 1.
Nothing was committed or pushed.

# Kitty: a task must have content, and the model words the question (flat path)

"Can you create a new task? task?" produced a card "Save 'create'?". Nothing checked that a task is meaningful. Now one pure Swift
shape check, `TaskMeaning.hasContent` (`FlatEdit.swift`), removes app-talk (can, could, you, please, i, want, need, would, like, just,
said, a, an, the, new, another, one, to, for, me, task, tasks, reminder, reminders, todo, item, list, something), bare command verbs
(add, create, make, remove, delete, start, set) and repeated words, and asks whether anything is left. It does not interpret meaning.
It runs on the words before any model call (when no draft or card waits and the words do not answer an open question), and on every
title through `TaskDraftMapper.item` (model extraction, tasks added by an edit, a retitle) and in the hand-edit sheet (Add stays off,
with a hint). A title that is the spoken command itself ("Add a task to buy bread", "Add milk to the blanket list") is also refused
(`TaskMeaning.isCommandEcho`; this replaces `CommandTitle`, and is the one rule `hasContent` alone cannot cover).

When it fails there is no card and nothing is saved. The usual pause (about 4 s) is the hold: more words join the same turn first
(`VoiceTurnManager.noContentExtraHold`, 0 now, adds quiet for no-content words if the phone test says it asks too early). Then one small
model call (`DecisionProviding.contentQuestion`, own session, 15 s timeout) writes ONE question. Swift only checks it is one question and was
not asked already; it never writes the wording. No question (no model, timeout, not one question, a repeat) leaves the user listening
with no card and no fixed sentence. The next words are read through the existing clarify path, so "buy milk" becomes one task.

Not run: no test was run this round (build-for-testing only), and nothing was measured on the real model, so I don't know whether the
question is sensible, short or free of invented tasks. An opt-in check exists (`ContentQuestionRealModelTests`, set
`TEST_RUNNER_KITTY_REAL_MODEL=1`); no `REAL_MODEL_*.md` was written. A real task made only of app-talk and a bare verb ("Make a list")
is refused too. Nothing was committed or pushed.

# Kitty: intent routing and corrections (flat path)

A plain "I just said add a task to buy bread and milk" was read as an edit of a saved task. Now one tiny call (`FlatEdit.swift`:
`TaskIntent`: create, change, query, unrelated, plus a `correction` flag) says what the words are for, and Swift routes by that and by
the real state. The call sees the words and one line of state, never a task. It is skipped when nothing waits and the words do not point
at a saved task, and when the words answer an open question. A waiting draft always gets the call. create: new tasks, the saved-task
block is never sent. change: the draft edit when a draft waits, else the saved-task edit. query with no draft: Swift reads the question
itself (list, today/tomorrow/overdue, done, remaining words) and answers from the saved tasks, with no model call. A correction with a
draft is a change; with none it is a new request. No answer from the call: a waiting draft uses its edit call as before, otherwise the
words make tasks. `SavedEditGate` no longer matches "just", "one", "also", "make", "set", "actually" or a saved title.

Refusals, in Swift: an edit is rejected whole, with nothing shown or applied, when it clears `title` or an unknown field, names a ref
that is not listed, touches more than two tasks (a draft edit that says all, every, each or both is exempt), or touches a task the words
neither name nor point at. A draft shows the recovery card; saved tasks get "I couldn't apply that, nothing changed." A task whose title
is the spoken command ("Add a task to buy bread", or the whole sentence) is dropped. The edit schema's `add`, `update`, `remove` and
`clear` are now optional, because required arrays are a suspected cause of the padded answer (not verified).

Two instruction lines are behind `FlatExperiments` (`correctionLine`, `separateTargets`, both on) and were NOT measured on the real model.
Set either to `false` to take it out. Nothing else was measured either; the scripted tests were updated to compile and were not run.
Still unverified or failing: how the real model answers the intent call; the query reading is a keyword parse and can show too much or
too little; why a saved task was titled as a command (no trace of that turn exists); `unrelated` while a draft waits goes to extraction.
Nothing was committed or pushed.

# Kitty: conversational task creation and editing (flat path)

On the flat path, words said after a preview go to a small edit call (`FlatEdit.swift`) that returns only what changes: add, update
or remove tasks of the waiting draft by ref, in the user's words; Swift reads the day, time and repeat. An added task joins the draft's
only list, and a list named in the words ("to the Blinkit order") joins the one that exists. With no draft, words that could be about
the last five saved tasks (t1 to t5) get a card that needs a yes before anything changes. The edit sheet now has Repeat, part of the
day and a timeframe. Not measured on the real model, and the new scripted tests (`Tests/TaskExtractionTests.swift`) were not run to
completion. Nothing was committed or pushed.

# Kitty: list extraction on the production path

A user-named list now returns `listName` once (`BulkAgentDecision`, between `action` and `items`) with one item per independently
completable or purchasable thing; the old "a named list is one purchase task by default" wording is removed. `assignee`, `notes` and
`answer` guidance is stricter. Swift carries `listName` onto the drafts, shows it on the card, and makes or joins the list only when you
approve. This reduces a known failure mode; it was checked with scripted tests only (`Tests/ListExtractionTests.swift`) and has not been
measured on the real model. Nothing was committed, pushed or zipped.

# Kitty: flat task extraction (behind a flag, `.full` stays the default)

`PathProfile.flat` (`TaskExtraction.swift`, `TaskResolvers.swift`, `TokenBudgetService.swift`): the model returns only what the user
said (title, schedule, assignee, dueDate, dueTime, purpose, instructions, plus a list name and an optional question). Swift resolves
dates, times and repeats, makes the list when the draft is approved, validates, and saves nothing without approval. Labels are removed
app-wide. Lists show as sections on the review card and as list chips on Home. A question can sit beside the tasks (Save stays enabled).
Measured on the real model it splits more often (51/120 against 32/120 on the shared matrix, 1.5 s against 3.8 s a turn) but is worse on
some cases and invents purposes, so it was **not** made the default. Details, deviations and what was not measured:
`REAL_MODEL_FLAT_EXTRACTION.md`. Nothing was committed, pushed or zipped.

# Kitty: one task per requested action (measured, wording reverted)

The model interprets and splits a request; Swift keeps state, validates shape, handles duplicates, review and saving, and never splits
or merges a title by meaning. New wording for "one task per requested action or target, shared context on every task" was tried and
measured on the real model (12 utterances x 10 runs, `Tests/SplitMatrixTests.swift`). It helped a few cases (Cetaphil/Cipcal/Tedibar
0 to 6 of 10) and made single-request cases worse (plumber 3 to 0, dry cleaning 8 to 0, invented repeats), so it was **reverted**: the
instructions and schema guides are unchanged. Real-model splitting is still weak (milk and bread from Blinkit: 0 of 10). Details,
tables and causes: `REAL_MODEL_SPLIT_EXTRACTION.md`.

- Added `Tests/SplitExtractionTests.swift` (11 scripted tests of the Swift side) and the opt-in real-model matrix.
- Nothing here claims that the safeguards eliminate hallucinations.

# Kitty: quote checks are advisory, review is the save boundary

The model reads the meaning. Swift checks shape, references, parseable fields, versions and exactly-once saving. A generated draft
is not a saved task. None of this removes hallucinations: it makes them visible and keeps the user in charge of what is saved.

- **A quote that is not in the transcript is a flag, never a removal** (`BulkValidator.flagQuotes`). `DraftItem.quoteUnverified`
  puts an orange "Quote unverified" tag on the row; the task stays in the draft and in the save proposal. One, several or all
  failing: same policy. No quote at all makes no claim and is not flagged. A matching quote proves nothing about the task and
  earns no "verified" mark. A mismatch never retries the model. The old "Not in what you said" list is gone.
- **The model's quote is never shown as the user's speech.** The edit sheet shows "Model's quote" and "What you said" (the original
  transcript) separately. The review prompt says "quote unverified" instead of giving the quote back as "from …".
- **One question per undecided flagged task.** The card asks "Should I include ‘title’?" (`Proposal.flagQuestionItemID`). "Yes" marks
  it included, "no" removes it; neither saves. Include / Remove buttons do the same. When none is undecided the card asks "Should I
  save these?". Save always saves every task shown, flagged ones included.
- **Approval is for one version.** Include, remove and edit all move the draft version, so an earlier card cannot save the changed
  draft (`Proposal.approves`, also checked in the background apply). A completed answer is applied once per request id and draft
  version (`commit(ticket)`); streaming snapshots only update the display.
- **Success is reported only after storing.** `TaskStore.addMany` takes the tasks back out if encoding fails and returns nothing; the
  reply then says it could not save, keeps the draft, and the same approval can be given again.
- **Nothing is suppressed because a title matches.** A match with a saved task or routine is a note on the card ("You already have
  this saved"); an approved routine is saved even if a saved one has the same title and repeat (`allowDuplicate`).
- **Instructions**: one rule for one item per requested action; `heardAs` asks for the shortest unbroken run of the user's words.
- Tests: `Tests/ReviewBoundaryTests.swift` (scripted). Not covered: whether the model's interpretation is right.

# Kitty: stabilised creation and single-item correction

Result first: correction by spelling ("it's Cipcal, not sip curl") is **not reliable** on the on-device model (0 to 1 of 10 in the
replay), though latency, finished answers and invalid-output handling improved a lot. Production uses the full path. The minimal
path exists only for measurement. Numbers, samples, recommendation and the feature ladder: `REAL_MODEL_CORRECTION_REPLAY.md`.

- **One answer variant per turn** (`DraftReview` in `QuestionComposer.swift`): `answer` (a reply, no changes), `change` (edits by
  ref, remove, add), `clarify` (one question), `unrelated`. An `answer` carries no mutations by construction.
- **Invalid output is rejected whole** (`DraftReviewValidator`). Unknown ref, unknown action, empty change, the same item both
  edited and removed, a clarify that is not a question: nothing is applied, the draft stays as it was, and the card shows a
  recovery (what went wrong, the items by name, the words to retry) instead of the save prompt. Swift never repairs the model's output.
- **Review prompt** sends the current draft (ref, title, labels, provenance), the last changes, only the vocabulary the words
  mention, and the user's latest words. The old `ORIGINAL REQUEST` and `LINES SO FAR` repair history are gone. A recap is never
  stored as an open question (`ClarificationStateManager.isOneQuestion`).
- **Stable ids and provenance.** Each `DraftItem` keeps its ref and a `history` of (line, words, what changed).
- **Grouping.** The default shopping-list grouping in `ItemDraft.title` yields to an explicit grouping the user asks for.
- **Diagnostic path** (`MinimalPath.swift`, `VoiceTurnManager.profile = .minimal(vocabulary:)`): titles only, rename/remove/add by
  ref, no recurrence, playbooks, retrieval or metadata. It uses the same validator, apply and recovery code. Not used in production.
- **Replay harness**: `Tests/CorrectionReplayTests.swift` (opt in, `TEST_RUNNER_KITTY_REAL_MODEL=1`); scripted tests for invalid
  output in `Tests/InvalidOutputTests.swift`.

# Kitty: state snapshot, token budget and scoped edits

- **State, not conversation.** Swift keeps the whole conversation locally (`ConversationLog`) and sends the model only the state of
  this turn: `STATE`, the open `QUESTION`, `ITEMS` by ref, the last three `RECENT CHANGES` Swift made and the `USER` words (the
  `ORIGINAL REQUEST` and `LINES SO FAR` repair history are no longer sent). Empty sections are left out. Swift does not guess intent from the snapshot; the model reads it.
- **Measured budget** (`ContextAssembler.swift`). The window comes from `SystemLanguageModel.default.contextSize`; instructions,
  schema and tools are counted once per call kind with `tokenCount(for:)` (iOS 26.4 and later, an estimate before, labelled as one).
  Input room = window - fixed cost - 1,200 answer reserve - 300 margin. When the prompt does not fit, whole kinds of context drop in
  order: vocabulary (relevant, then none; "all" is no longer sent), skipped chatter, item detail (all fields, title and category, titles, count only; the
  last two hand the list to the draft tools). The user's words, the open question, the recent changes and the refs are never cut.
  The old `prefix(3200)` is gone. The line `... of 8,192 tokens ... counted by the model | estimated` is in the trace and the live view.
- **Scoped edits.** An edit names `ref`, `refs` or `all`; Swift applies it to each item and records one `Change`
  ("Cleared tags on 4 items."). `clear` takes `category` as well as `labels`; "tags" means both. `add` is its own action and leaves
  every existing item alone; `replace` is only for "start over".
- **Large lists.** `get_draft_items(ids)` and `search_draft(query, limit)` (`TaskTools.swift`, at most 12 items, the same 3-call
  limit). A turn too long for one call is read in batches ("part 2 of 3" in the live view) into one draft.
- Details of the real-model scenario run: `REAL_MODEL_RUNS.md`. `ALGORITHMS.md` still describes the older design.

# Kitty: model-first refactor and the live model view

- The model reads the words, extracts, corrects, clarifies and answers. Swift runs audio, timing, state, tools, storage and
  confirmations, and checks only shape, supported actions, required fields, references and exactly-once saving. It never merges,
  drops or rewrites what the model proposed; a mismatch with the transcript is a note on the card.
- `PersistentInstructions.text` in `Agent.swift` is the one instruction block (the OBJECTS / GROUNDING / EVIDENCE / CONVERSATION /
  OUTPUT text). Each call starts a fresh session.
- Tools the model fills in and Swift runs: `search_tasks`, `read_task`, `list_facets` (`TaskTools.swift`). At most 3 calls per turn,
  at most 12 records each. A model call is stopped after 45 s.
- Typed search is plain matching (title, tag, category, label, stored reason and words). The old concept expansion was removed.
- Settings menu, "Live model view": shows each step of a turn on screen while the model works. See `REAL_MODEL_RUNS.md` for the real
  model results, which are not good yet. `ALGORITHMS.md` still describes the older design.

# Kitty v36: LLM-first lean pipeline

The model reads what you said, as you said it, and decides everything. Swift only decodes the answer and keeps the safety net.

- **One schema, one call.** `DecisionProviding.extract(prompt:fresh:)` returns one `BulkDecisionValue` that carries create (tasks, routines,
  playbook) and view, update, complete, delete, clarify and wait. `decide` and `decideBulk` are kept only as shims for the test engines.
  The instructions are a short template: 8 rules and exactly 3 examples; formatting limits live in the `@Guide` descriptions; today's
  date, known people, categories and the pending draft go in the prompt as data.
- **Raw words in.** No speech cleaner, no brand fixer, no `TranscriptPolicy`. Brands (Blinkit, Swiggy, Zomato, Zepto, Grofers, UPI, Paytm)
  come first in `KeyTerms` for the Whisper prompt and in Apple Speech's `contextualStrings` (`VocabularyProvider.current`). One tiny
  `norm()` remains for comparing strings. `PromptBudget` stays only as a fallback: on a `context window full` error the turn is split by sentence.
- **Decode only.** `BulkValidator.decode` turns ISO dates, `HH:mm`, enums, empty strings and exact duplicates into values. It does not
  invent, drop, repair or ask. Removed: the pre-checker, `TaskValidator`, the vague-placeholder check, the long-turn analyser, the list
  detector, the read-back ("Did you say Rani?"), the sound-alike name matcher, `LabelFinder`, `ActionRecovery`, and the question-writing call.
  The preview, the edit sheet and "nothing saves until Save" are the safety net.
- **Edit before save stays.** The draft review call (its own short prompt), spoken quick edits (remove, replace, priority, fields,
  playbook step), `DraftEditSheet`. A new task is never built by a rule from "also add ..."; that goes to the model.
- **Endpointing.** After silence, if the last word is one of `the, and, a, my, to, for, with, um`, Kitty keeps the mic open and makes
  no model call (the trace says `NOT SENT TO THE MODEL`). A local 1.5 s timer then says "Anything else?" (a chime when read-aloud is off).
  `PauseProfile` timing and the "done" finalizer are unchanged.
- **Utterance.** One `Utterance { id, rawText, createdAt, source }` is written when Save is confirmed (the whole turn's words, including
  corrections made to the draft) and every task and routine from that turn carries its `utteranceID`. An abandoned draft stores
  nothing. It is stored as JSON in UserDefaults like the tasks, only while "Save task details" is on, and dropped when no task points to it.
  The old per-task `said` copy is no longer written; saved data that has it still loads and still shows.
- **Order.** `TaskSorting`: overdue first, then morning to night, then by time, applied to the lists and the preview. The prompt never mentions order.
- **Tests.** 399 run, 3 skipped (opt-in), 0 failures. The eval suite (`EVALS.md`) uses a scripted model, so it checks the wiring and
  the decode, not Apple's model. See `REAL_MODEL_RUNS.md` for what only a phone can show.

Not verified: real microphone and screen behaviour, the real model's output, prompt quality on real speech, and the "Anything else?" timing.

---

# Kitty v35: smaller app, Apple live text, turbo settles each phrase

The app was 3.8 GB on the phone. Most of it was dead weight, so v35 keeps **large-v3-turbo** and drops the rest.

- **Moonshine is gone** (code, tests, menu entry, the `moonshine-swift` package). A stored "moonshine" choice maps to Turbo; the old
  "Moonshine speech" switch set to off maps to Apple Speech.
- **The turbo CoreML encoder is no longer bundled** (it was about 1.2 GB). With no `-encoder.mlmodelc` beside the `.bin`, whisper.cpp runs the
  encoder on the GPU (Metal) on a device. `WhisperEngine.encoderURL(for:)` / `hasEncoder(for:)` decide; the log line says which path loaded.
  Optional: `sh Whisper/fetch-models.sh turbo-coreml` puts the encoder back (faster on the Neural Engine, 1.2 GB bigger).
- **small.en is no longer bundled** (parked in `WhisperSetup/parked/`, git-ignored). The "Whisper (quick)" engine only shows if it is installed.
- **Apple Speech shows the live words; turbo settles each phrase.** `HybridRecognizer` wraps `SpeechRecognizer`. The same microphone
  buffers go through `SpeechRecognizer.audioMirror` to `TurboSettler`, which runs the energy VAD and calls turbo once per pause (queue
  `kitty.whisper.final`). `HybridTranscript.merge` replaces the Apple words that fall in that phrase's time range with turbo's text. If Apple gives no word
  times it falls back to word-count boundaries. If turbo is not loaded or fails, Apple's words stand. A generation counter drops stale
  results after a restart or cancel.
- **Expected size: about 0.6 GB** (turbo 547 MB plus the framework). Not yet measured on a phone.

## Measure turbo on the phone (your step)

Set `KITTY_WHISPER_NO_COREML=1` in the scheme if you want to force the GPU path, speak a 10 s phrase, and read the breadcrumb
`whisper-turbo pass: X ms`. 3000 ms or less is fine. If it is much slower or the phone gets hot, tell me and I will build the quantized-encoder fallback.

## Simulator

Turbo is excluded on the simulator (CPU encoder, about 40 s per 11 s phrase) unless `KITTY_WHISPER_TURBO_SIM=1`; the menu shows
"(not installed)" and Apple Speech is used. Opt-in real run with no encoder (11 s recording: loaded in 45 s, one pass 42 s, text correct):

`TEST_RUNNER_KITTY_WHISPER_TURBO=1 TEST_RUNNER_KITTY_WHISPER_TURBO_SIM=1 TEST_RUNNER_KITTY_WHISPER_TURBO_MODEL=$PWD/Whisper/large-v3-turbo TEST_RUNNER_KITTY_WHISPER_WAV=/path/speech.wav xcodebuild test -project Kitty.xcodeproj -scheme Kitty -destination 'platform=iOS Simulator,name=iPhone 17' -only-testing:KittyTests/WhisperRealTests/testTheAccurateModelSettlesEachPhrase`

Tests: 395 run, 3 skipped (opt-in), 0 failures.

Not verified: how well Apple's partial word timestamps line up with the VAD phrases on a real device.

---

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

Seeing everything (debug builds): run the app from Xcode and type KITTY in the filter box of the debug console. Each turn prints, in
order: HEARD and CLEANED (what you said), SWIFT (what Swift stripped, found, kept or dropped, before the model and after it), TO MODEL
(the full prompt, with sizes and an estimated token count), FROM MODEL (the answer and the seconds it took) and RESULT (what you were
shown). That is the whole story of a turn. For the rest (GATES, STRIP, CHECKS, RULES, ROUTE, SAVED) set the UserDefaults flag
kitty.traceDetail = true. Switch the trace off with kitty.traceModel = false. It never prints in a release build or in unit tests
(Trace.swift). The live "Hearing N tasks" chip never traces.
Apple's own audio lines (`auou/vpio ... render err: -1`, `throwing -1`) are not Kitty's: typing KITTY in the console filter hides them.
(v36: the lean template replaced both instruction texts; there is no legacy switch any more.)

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

# Siri that carries your request

Siri phrases always end in the app name, and Siri cannot take free words inside a phrase, so the common requests are ready-made:
- "Hey Siri, add a task in Kitty" (also: add a task to / on / with / using Kitty, create a new task in Kitty, new task in Kitty,
  add a reminder in Kitty, I want to add a task in Kitty ...) opens Kitty listening.
- "Hey Siri, what are my tasks for today in Kitty" (also: what do I have today, show / read my tasks for today, today's tasks in
  Kitty), the same for tomorrow, and "what is overdue in Kitty" open Kitty, which runs the question itself, speaks the answer and
  keeps listening. If Kitty is already open, the question runs in that conversation.
- "Hey Siri, tell Kitty": Siri asks "What should I tell Kitty?", then Kitty opens and does whatever you said.
The words each phrase runs are in `KittySiriRequest` (Intents.swift). New phrases go in `QuickTasksShortcuts` (at most 10 shortcuts).

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
