# State snapshot + token budget: real on-device model results (2026-10-26)

Draft-edit conversation on the real on-device model (Version 27.0, simulator on this Mac), the snapshot prompt, the measured budget,
3 fresh runs per scenario, run twice (the second run after the `@Guide` text for edit/add/replace was made stricter).
`TEST_RUNNER_KITTY_REAL_MODEL=1 TEST_RUNNER_KITTY_REAL_RUNS=3`. Counts are what happened, not a guarantee. **The edit scenarios did NOT work on the real model; this is not a pass.**

| scenario (3 runs each) | run 1 good | run 2 good |
|---|---|---|
| add a task to create the invoice | 0/3 | 0/3 |
| remove all the tags | 0/3 | 0/3 |
| remove the tags from the cab one | 0/3 | 0/3 |
| remove the cardamom ones | 1/3 | 0/3 |
| I said book a cab | 0/3 | 0/3 |
| start over, buy milk | 0/3 | 0/3 |
| why did you add that (a question) | 2/3 | 3/3 |

What went wrong: for edit requests the model usually returned the list itself in the wrong field (items titled "Clear Labels",
"Update Item Tags", four copies each), invented extra items ("Review Draft List"), or changed nothing. Only plain questions work.
The Swift side (scoped ops, recent changes, budget) is proven with scripted model answers (447 tests, 5 skipped, 0 failures), which
proves the plumbing, NOT that the model picks the right op. I did not add a phrase list to force it, because the app is model-first.
No A/B of the old short instructions against the new long block was run.

Measured fixed cost on the real model (counted by the model, not estimated):

- extract: window 8,192, instructions 604, schema 1,817, tools 415, room for the prompt 3,856
- review: window 8,192, instructions 604, schema 2,371, tools 0, room for the prompt 3,717
- review with tools: window 8,192, instructions 604, schema 2,371, tools 272, room for the prompt 3,445
- a typical edit turn used about 3,150 of 8,192 before the answer (reserve 1,200 and margin 300 kept apart)

Full raw detail of run 2: `REAL_MODEL_DRAFT_RUN2.md`.

---

# Model-first refactor: real on-device model results (2026-10-26)

Run on the simulator on this Mac with `TEST_RUNNER_KITTY_REAL_MODEL=1 TEST_RUNNER_KITTY_REAL_RUNS=2`, the persistent instructions as
supplied on 2026-10-26 (the long OBJECTS / GROUNDING / EVIDENCE / CONVERSATION / OUTPUT block), the real tools and the real validator.
Two fresh runs per scenario is a measurement, not a guarantee. **These results are poor, and this is not a pass.**

Run on Version 27.0 (Build 24A434), Apple's on-device model, 2 fresh runs per scenario, the real tools and the real validator. A count of runs is a measurement, not a guarantee.

| scenario | runs | as wanted |
|---|---|---|
| Party: exactly accommodation, Swiggy food, a cab (no cooking, cleaning, dates, playbook) | 2 | 0/2 |
| No unsupported additions: 'buy milk and call the plumber' gives exactly those two | 2 | 0/2 |
| No omitted tasks: five separate requests give five tasks | 2 | 2/2 |
| No invented metadata: 'pay the rent' has no date, person, schedule or label | 2 | 0/2 |
| A requested repeat is read: 'water the plants every Sunday' | 2 | 0/2 |
| Correction kept: 'buy milk and call the bank, no wait, call the dentist instead of the bank' | 2 | 1/2 |
| Useful clarification: 'get the cleaning done' asks or waits and makes no task | 2 | 0/2 |
| Retrieval accuracy: 'what Zzswiggy tasks do I have' cites only the two Zzswiggy tasks | 2 | 1/2 |
| No match: 'what Zzquantum tasks do I have' shows no task and invents none | 2 | 2/2 |

Token window with the tools attached: not measured by this run (the framework gives no per-call token count here).

What the raw output shows (full text in `/tmp/kitty-real-model-mf.md` after a run):

- The model often returns the same task twice, once as a task and once as a routine, or the whole list twice. Swift shows both and
  flags them; it does not merge or drop them (by design), so the preview has duplicates.
- It adds metadata nobody said: a due date, the assignee "Househelp", labels such as "Rent" and "Blinkit" on "pay the rent".
- It adds tasks nobody asked for ("Plan Party", "Respond").
- "Water the plants every Sunday" came back as a one-time task plus a "monthly on the 1st" routine, so the weekday was not read.
- "Get the cleaning done" made two "Clean Bathroom" tasks instead of asking a question.
- Retrieval gave a correct answer with the right two records once and an empty answer once.
- Before the tool limit: one real session ran about a hundred `search_tasks` calls (every assignee, `today` and `tomorrow`) on
  "clean mattress and chop veggies" until the 8,192-token window filled. Now: at most 3 tool calls per turn, the fourth is told to stop,
  the fifth ends the answer, and the words are asked again in a fresh session without tools. A model call is also stopped after 45 s.
  The failure reason is now shown in the reply and in the live view.

Not done: I did not compare this against the previous short instructions on the real model (a run was started and rejected), so I
cannot say whether the longer block is worse than the short one. The simulator's model is not the phone's model either. Token use
with the tools attached was not measured.

The live model view (Settings menu, "Live model view"; on by default in Debug) shows each step, the text sent, the model's answer as
it is written, each search, the elapsed time and the failure reason, on screen.

# LLM-first lean pipeline (v36): what only a phone can show

**None of this has been run on a real device or against the real on-device model.** The simulator on this Mac does not give a usable
model (see the K section below), and nothing here can test the microphone, the screen, or how good the prompt is. The unit tests
and the eval suite use a scripted model: they prove the wiring (one unified call, the raw words in the prompt, decode-only validation,
the endpointing hold and nudge, one `Utterance` per Save, client-side sorting), not the quality of Apple's model.

The sections below this one were written for the earlier pipeline (speech cleaner, rule fallbacks, meaning check, read-back). Where
they mention those, they describe history; the code is gone.

Check on the phone, in Debug, with the console filter `KITTY`:

- [ ] **One call per turn.** `TO MODEL` appears once for a finished request, and the same schema returns create, view, update,
      complete, delete, clarify and wait. Note how often it answers `wait` on a finished sentence (Swift no longer overrides it; the
      long silence and "done" still act).
- [ ] **Raw words in, nothing repaired.** The prompt carries the transcript as heard ("blink it" stays "blink it" unless Whisper's prompt
      or Apple's `contextualStrings` fixed it). Try "order from Blinkit, Swiggy and Zepto", "pay on Paytm by UPI". If brands come out wrong,
      that is the recogniser: the brand list is the first thing in the Whisper prompt and in `contextualStrings`.
- [ ] **Prompt quality.** The eight rules and three examples are untested on the real model. Read ten real turns' `FROM MODEL`
      output: is the date right (ISO, worked out from today), is the time `HH:mm`, are people and projects placed on the right task,
      is a missing day left empty? Swift will not fix a wrong value; it shows in the preview and the edit sheet.
- [ ] **Endpointing.** Say "buy milk and the" then stop: the mic must stay open, the trace says `NOT SENT TO THE MODEL`, and after
      1.5 s Kitty says "Anything else?" (or plays the chime when read-aloud is off). Say "buy milk and bread" then stop: it goes to the model.
- [ ] **Edit before save.** Nothing saves until Save. "Remove the milk", "make the bread high priority", "also add eggs" (the last goes to
      the model, never a rule).
- [ ] **Draft updated by edits, not re-extraction.** Make a draft of three tasks, then say (while the preview shows) "make the second one
      high priority and tomorrow", "call it Water the balcony plants instead", "no day for the plants", "drop the third one", "also add
      pay rent". The trace shows route `draft-edit`, a prompt with the numbered draft and only the new words, and an `edits` answer with
      the right `item` number and fields; the other items stay exactly as they were. Unplug the model or speak while it is busy: the preview
      stays with "I couldn't update that, so nothing changed" and no `extract` call appears. Whether the on-device model reliably picks the
      right item number and field is NOT verified anywhere else: note how often it misses.
- [ ] **Questions say what Kitty understood.** Say something noisy and ambiguous ("um call Rani about the trip, Friday, no Sunday,
      whatever"), and something with no action ("add a task to update"). The question starts with one short "I understood …" sentence
      that only uses words you said, then asks about the single unclear detail with a reason in a few words (never "is that right?"). The
      next `TO MODEL` prompt holds "You had understood: …" (the latest recap only) and your answer. Note how often the recap adds
      something you did not say, is longer than one sentence, or is missing.
- [ ] **Weekly routine on named days.** Say "Add weekly tasks to buy vegetables on every Sunday and Monday". Expect ONE routine (Buy
      Vegetables, every Sunday and Monday), or one question if the model is unsure; never a one-time task, never two items that
      lose a day. Save the `HEARD / TO MODEL / FROM MODEL / RESULT` lines of every run: the `schedule` text the model gave is what
      Swift reads. Note how often the model gives "weekly" with no days, or a one-time task.
- [ ] **A correction replaces the wrong preview.** Make a wrong preview (for example two one-time tasks), then say "that's not it, I
      want vegetables every Sunday and Monday". The trace shows route `draft-edit`, an answer with action `replace` and the complete new
      list, and the preview then holds only that list (the old items gone, even ones you edited by hand). Note how often the model picks
      `edit` or `unrelated` instead of `replace`, and whether the prompt's "words said so far" line holds your whole request.
- [ ] **Unsure means ask, not preview.** Say something whose core task or repeat is unclear ("do the thing on weekends, I think").
      Expect one question that starts "I understood …" and keeps the preview (if any) as it is; your next words are read as the answer
      (the prompt shows "You asked, and are waiting for the answer: …"), and after three questions the list stays as it is. Note how
      often the model shows a preview when it should have asked, or asks about priority, date or assignee, which it must not.
- [ ] **Utterance.** With "Save task details" on, a turn that makes three tasks keeps its words once; the task's details sheet shows
      "What you said". With the switch off nothing is kept and `utteranceID` is empty.
- [ ] **Order.** The preview and the lists show overdue first, then morning to night, then by time.
- [ ] **Window.** One 3,000-character turn: does it overflow (`context window full`)? `PromptBudget` only splits on overflow; the
      numbers in it are estimates (see the next section).

---

# Task anatomy and stored words: check on a device

A task is who (assignee) does what (action, required) by when (day, time) for what reason (optional). Swift stores the cleaned words with the task (`said`) and the model's optional `reason`. Both are searchable. The simulator's model is a stand-in, so these need a real device run.

1. Say: "I need to go to my in-laws house and pick my wife and my kid." Expect one task whose title holds the purpose ("Pick up wife and kid from in-laws' house"). If the model first answers "Go to in-laws", the trace should show `MeaningCheck` leaving out "pick my wife and my kid" and a second call.
2. Say: "Remind me to buy candles for the party on Saturday." Expect the title "Buy candles", reason "for the party", due Saturday. The reason must be a few of the user's own words. An invented one should show `reason "..." dropped` in the trace.
3. Say a list: "Clean the bathroom and buy milk for the party." Each task should keep only its own part of the words.
4. Later ask "show me the party things". The task should be found through its reason or stored words.
5. Count the model's tokens for the instructions (about 3,500 characters) and check that nothing in a long turn overflows the window.

# Measure the prompt ceiling, and check model-first on a device

**Not run yet: it needs a phone with Apple Intelligence.** The numbers in `PromptBudget` (`PromptBudget.swift`) are conservative
estimates, not measurements: the window is about 4,096 tokens shared by the instructions (~900 tokens), the output schema, the
prompt and the answer, so a fresh-session utterance can probably carry 2,000 to 3,500 characters.

1. Run the app in Debug on the device (the trace is printed to the Xcode console, filter `KITTY`).
2. Speak or type one long turn at a time, with several actions and a project, at about 1,000, 1,500, 2,000, 2,500, 3,000 and
   3,500 characters (a paragraph of sentences, each asking for something).
3. For each turn read, from the `TO MODEL` line, the prompt size, and from the `FROM MODEL` line, the seconds and whether it says
   `context window full`. Note the largest size that answered every time and how many tasks came back against the actions said.
4. Set `PromptBudget.utteranceTokens` to about 80% of that size (in estimated tokens, 3.5 characters each) and
   `PromptBudget.chunkCharacters` to about 60% of the budget in characters. A longer turn then goes in whole-sentence pieces, and a
   `context window full` error splits by sentence and asks again.

Check list for model-first (what a simulator cannot show):

- [ ] "I am working on this project called Project Kitty. I want to add a task to improve its labeling." gives one task, `project` is
      "Kitty", no assignee, no question.
- [ ] "Add a task to improve the labeling for project Kitty." never returns Kitty as the assignee; if it does, the trace shows one
      `WARNING meaning check` and the second answer is accepted.
- [ ] A turn with three asks and a story around them: every ask comes back (the `WARNING` line about fewer items than sentences
      does not appear), and a forgotten one is named in the one re-prompt.
- [ ] A 3,000-character turn: `TO MODEL` shows several pieces, each with `Context so far: project …`, and the merged draft has
      every ask once.
- [ ] A later "this project" turn is labelled with the project and Kitty does not ask for its name.
- [ ] The `SWIFT` block after the model shows "Swift saw … the model did not tag it" for a brand the model missed, and the task
      is not tagged with it silently.
- [ ] Time to answer for a single short turn is no slower than before (one call).

---

# Real on-device model: long and noisy cases (K)

**Not run on the real model yet.** On this Mac the simulator reports the on-device model as `unavailable(modelNotReady)`
(checked three times over several minutes, 22 Oct 2026), so there are no real-model numbers for the K cases. Everything in
`EVALS.md` for K was measured with a scripted model, which shows what Swift does with a given model answer, not what Apple's model
answers. Treat the K percentages as a test of the rules, not of the model.

An earlier attempt before the availability check came back as "0 of 460 tasks found, reply 5/5" for every case. That was the
unavailable model, not a result, and is not reported. The test now refuses to run (and says why) when the model is not available.

What is still unverified until it runs on a phone or a simulator with the model downloaded:

- whether the model answers the digest prompt (one line per action, the shared context first) with one task per line
- how often it says `wait` on a long finished turn (the rules answer when it does, so nothing is lost)
- whether it copies the day or the person into tasks that did not say it (Swift removes those, `BulkValidator`)
- how many of the 1 to 3 model calls a long turn really uses

To run it (writes `/tmp/kitty-real-model-k.md`; 5 runs per case, rule fallback off, `KITTY_REAL_RUNS` changes the count):

```
TEST_RUNNER_KITTY_REAL_MODEL=1 xcodebuild test -project Kitty.xcodeproj -scheme Kitty \
  -destination 'platform=iOS Simulator,name=iPhone 17' -only-testing:KittyTests/RealModelKTests
```

Then paste its summary table and raw output here.

---

# Real on-device model runs (messy-speech cases)

Run once on the iPhone 17 simulator, Apple's on-device model, 5 runs per case, rule fallback off. The cleaned sentence is what the model saw ("sees"). The "x N" lines are what came back. A temporary probe test produced this and was removed.

## Reading it

- Title wording varies run to run ("Clean bathroom" vs "Clean the bathroom"). That is the model, not the cleaner, and the action is right.
- The cleaner's output was right in every run (sees = the intended sentence).
- The main flakiness is the model answering **wait** on a finished sentence, mostly after a repair, where the cleaned text is short ("Buy bread", "wash the car", "Remind me to pay the electricity bill").
  - When the model picks `create_task` but sets wait=true with an empty title, Kitty now asks it once more, then falls back to the rule planner (new in this change, `model-single-retry` / `wait-overridden-create`).
  - When the model picks action `wait`, Kitty still honours it. After the long silence the existing `wait-overridden` path answers, so nothing is lost, only delayed.
- "Wait for the plumber" is a task, but the model says wait 5/5. The local gate does not hold it; the long-silence path answers.
- Lone "Clean", "Clean the" and "Add a task to…" are still held by the gate (no model call).

## Raw report

```

PROBE real-model messy cases, 5 runs each
#76 0/5 “Um, add a task to clean the bathroom”
      x3 Clean bathroom   [route=model-single
      x1 Clean bathroom   [route=model-single-retry
      x1 Clean bathroom   [route=model-single
#77 0/5 “Add a task uh to clean the bathroom”
      x1 Clean bathroom   [route=model-single
      x1 Clean bathroom   [route=model-single
      x1 Clean bathroom   [route=model-single
      x1 Clean bathroom   [route=model-single
      x1 Clean bathroom   [route=model-single
#79 0/5 “Er, so I need to, like, call the plumber”
      x4 WAIT   [route=model-single
      x1 REPLY: You have no open tasks.   [route=model-single
#81 1/5 “Basically, clean the garage”
      x1 Clean garage   [route=model-single
      x1 Clean garage   [route=model-single
      x1 Clean the garage   [route=model-single
      x1 Clean garage   [route=model-single
      x1 Clean garage   [route=model-single
#82 0/5 “Add a task to to clean the bathroom”
      x4 Clean bathroom   [route=model-single
      x1 Clean bathroom   [route=model-single
#83 0/5 “Clean the clean the bathroom”
      x3 Clean bathroom   [route=model-single
      x1 Clean bathroom   [route=model-single
      x1 Clean bathroom   [route=model-single
#84 0/5 “Buy buy milk and bread”
      x2 Buy milk | Buy bread   [route=model-single-retry
      x1 Buy milk | Buy bread   [route=model-single-retry
      x1 Buy milk   [route=model-single
      x1 Buy milk | Buy bread   [route=model-single-retry
#85 0/5 “Call the the plumber about the leaking tap”
      x4 Call the plumber   [route=model-single
      x1 Call the plumber   [route=model-single
#86 2/5 “Clean the... no wait, wash the car”
      x3 WAIT   [route=model-single
      x1 Wash the car   [route=model-single-retry
      x1 Wash the car   [route=model-single
#88 1/5 “Buy milk, I mean bread”
      x4 WAIT   [route=model-single
      x1 Buy bread   [route=model-single-retry
#89 2/5 “Call mom tomorrow, no wait, Friday”
      x2 WAIT   [route=model-single
      x1 Call mom   [route=model-single-retry
      x1 REPLY: You have no open tasks.   [route=model-single
      x1 Call mom   [route=model-single-retry
#90 0/5 “Buy milk, scratch that, call the plumber”
      x3 WAIT   [route=model-single
      x1 REPLY: You have no open tasks.   [route=model-single
      x1 ASK: Is this for a specific location—like the garage or backyard?   [route=model-single
#91 0/5 “Remind me to pay rent, sorry, pay the electricity bill”
      x5 WAIT   [route=model-single
#92 3/5 “Clean the bathroom or rather the kitchen”
      x1 Clean the kitchen   [route=model-single
      x1 Clean the kitchen   [route=model-single
      x1 Clean the kitchen   [route=model-single
      x1 Clean kitchen   [route=model-single
      x1 Clean kitchen   [route=model-single
#93 5/5 “Water the plants every Monday, no wait, every Tuesday”
#102 0/5 “Say sorry to mom”
      x3 WAIT   [route=model-single
      x2 ASK: What would you like the task to be?   [route=model-single
#103 0/5 “Wait for the plumber”
      x5 WAIT   [route=model-single
#104 0/5 “I would like to buy milk”
      x2 WAIT   [route=model-single
      x1 ASK: What type of milk are you looking for—whole milk, powdered, or organic?   [route=model-single
      x1 ASK: Is this for yourself or someone else?   [route=model-single
      x1 ASK: Is this for personal use or for the household?   [route=model-single
lone “Clean” → hold("action without an object")
lone “Clean the” → hold("ends with “the”")
lone “Add a task to…” → hold("trailing off")
SUMMARY: 1 stable-correct, 5 flaky, 12 never-correct of 18
```
