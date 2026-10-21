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
