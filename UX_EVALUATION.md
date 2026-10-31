# [AI-DRAFT] Kitty: heuristic evaluation and UX gaps

Draft for review. This is an expert review, not research with users.

**How it was done.** One reviewer walked the whole journey (first run, home, writing notes, preview and save, tasks, chats, voice, edit, reminders) using Nielsen's ten heuristics, a cognitive walkthrough of six tasks, and a check against iOS conventions. Evidence is the code, the simulator (a few screens, including the shopping-list flow end to end up to the preview), and the real-model scoreboards (voice 60 cases x3, notes 14 cases x3). **Not done:** no real users, no device run, no VoiceOver pass, no test with Apple Intelligence off. Treat severity as a judgement to confirm with users.

Severity: **High** = users fail or lose trust. **Medium** = users slow down or guess. **Low** = polish.

## The six tasks walked
1. Type a whole list on the home screen (heading + items), press send.
2. Type a heading, then items one message at a time.
3. Dictate a long brain dump by voice.
4. Find what I wrote last week, and the tasks it made.
5. Change a saved task ("make it two litres").
6. See what is due today from one chat.

## What works (keep)
- Chat-as-notes is a familiar model; every message is now kept and shown after a restart.
- Nothing is saved as a task without a tap; the preview is editable (tap a row, swipe to delete, "Add a task").
- Status on the note (working / tasks ready / N tasks created) tells you what happened without opening anything.
- Chats open silent, so the mic never surprises you; reminders ask permission only when a task has a day (in context, not at launch).
- Clear chat-list empty state; first launch goes straight into a chat.

## Findings, by journey stage

### A. First run and home
| # | Finding | Heuristic | Sev | Improvement |
|---|---|---|---|---|
| A1 | The empty state ("Chat with Kitty / Start a chat") is the biggest thing on a home that also has a text box, a mic, a compose icon and task chips. Four ways to start, no clear first action. | Recognition, simplicity | Med | One primary action. Make the box the hero; make the chat list the page, with the empty state only when there are truly no chats and no tasks. |
| A2 | Home mixes two products: a chat list (notes) and a task tray (chips: Overdue, Other, Rani, Today, New, Househelp). Chips mix smart views, people, categories and lists with no grouping. "Other 6" is a meaningless label. | Match with real world | Med | Group chips (When: Today, Overdue, New / Who / Lists). Rename "Other" ("No category") or hide it. |
| A3 | Opening the keyboard re-lays out the home screen: the box jumps from the bottom to the top, the content disappears, a floating "Done" pill appears; closing it jumps back. One tap on the box did not focus it in my run. | Consistency, control | Med-High | Keep the box where it is (pin it above the keyboard, use the standard keyboard dismiss). Remove the empty gap. |
| A4 | Return inserts a line break; sending needs the small arrow. Users say "press Enter" and expect it to send. | Match with real world | Med | Offer "Return sends" (default for the home box), with a way to add a line. At least make the arrow larger and labelled for VoiceOver. |
| A5 | Autocorrect and capitalisation change user words ("Diapers"; Hinglish and names get "corrected"). The note is "the user's own words". | User control | Low-Med | Turn off autocorrect in note boxes; keep suggestions. |
| A6 | No first-run explanation of the three ideas (notes, preview, tasks). The "Tasks ready" chip and the tray are not discoverable. | Help and docs, visibility | Med | One-time, skippable three-card tour, or an inline coach mark on the first chip. |

### B. Writing a note and the preview
| # | Finding | Heuristic | Sev | Improvement |
|---|---|---|---|---|
| B1 | **A bare list heading became a task** ("create shopping list for my kid"). Seen live. | Match with real world | High | Fixed in code (heading alone waits for items). Re-verify on device. |
| B2 | **Drip list** (heading then items): items were kept, but the preview kept the heading and reported "I heard 'diapers' but didn't make a task from it". Seen live. | Error prevention | High | Whole-group re-read and a Swift list reader were added; confirm on device. |
| B3 | The recovery text is jargon and points at a button ("Try again") that is not on the one-line bar. The bar's title says Save “shopping list for my kid”, in orange. | Error messages, consistency | Med-High | One sentence, one visible button, and the bar says what is wrong in plain words ("1 task needs a look"). |
| B4 | Two controls say the same thing: the chip on the bubble ("Tasks ready") and the preview row ("1 task ready to review"). | Consistency, minimalism | Low-Med | One place. Keep the row; drop the chip while the row is showing. |
| B5 | Wording: "Tasks ready" (ready to do? to save?), "Review tasks", "N tasks created". Three states, three phrasings. | Match with real world | Med | Verbs and objects: "Review 3 tasks", "Saved 3 tasks", "Reading…". |
| B6 | Collapsing the preview into a row adds a tap to the most common case (a clean list) and hides the content. | Efficiency | Med | If it is 1-3 tasks with no flags, show them in the row (inline, tappable), with "Review" only for more or flagged ones. |
| B7 | A stale hint under the chat says "Tap Save · tap a task to change it", but Save now lives in the tray. | Consistency | Med | Remove or reword now. Quick fix. |
| B8 | The grey mic with a slash looks disabled. "Off" and "broken" look the same. | Visibility of status | Med | Label it ("Tap to talk"), show it as available, not struck through. |
| B9 | Editing a note that already made tasks opens an "Update tasks" sheet you cannot talk to. | Flexibility | Med | Let the same tray handle it: "I changed the note; update these 3 tasks?". |
| B10 | Deleting a bubble keeps its tasks, and nothing shows which tasks to delete too. | User control | Low | On delete, offer "Also delete the 3 tasks?". |

### C. Tasks and the tray
| # | Finding | Heuristic | Sev | Improvement |
|---|---|---|---|---|
| C1 | The old in-chat task panel was dense with controls (filters, drop-downs, list cards). | Minimalism | High | Replaced by a lean list (done in code): tasks first, one header line, filter menu only when needed. Check on device. |
| C2 | The tray title is "Tasks" and does not say it shows only this chat's tasks. A user may think tasks went missing. | Visibility | Med | Subtitle "From this chat", with a small "All my tasks" link. |
| C3 | Tasks made from the tray (not from a note) were not linked to the chat, and the list was a snapshot. | Visibility of status | High | Fixed in code. Verify save then reopen on device. |
| C4 | A repeating task ("every day") often came back as a one-time task. Voice scoreboard: repeats failed intermittently; "every three months" is not supported and is only flagged. | Match with real world | High | Added a Swift fallback; extend the parser for monthly intervals; show a visible "Repeats: every day" tag in the preview. |
| C5 | Task edit form is large and shared with other screens. | Flexibility | Low-Med | A short "quick edit" (title, day, who) with "More" for the rest. |
| C6 | Overdue is shown in red with a late count; good. But 12 overdue tasks from old tests/tasks dominate home. | Recognition | Low | A "snooze all" or "tidy up" action for old overdue tasks. |

### D. Voice
| # | Finding | Heuristic | Sev | Improvement |
|---|---|---|---|---|
| D1 | The pause before Kitty acts is about 4 seconds, plus 1.5-4 s of model time. Dictation feels slow. | Efficiency | Med | Show a live "I'm listening" line immediately and a progress line during thinking. Consider shorter pause for short phrases. |
| D2 | Voice list dictation: every pause can start a model call; the same item can appear twice. | Error prevention | Med | Merge turns during one dictation; dedupe identical finals. |
| D3 | Transcription errors are shown only sometimes ("Did you say…?"). | Visibility | Low-Med | Let the user tap a word in the bubble to fix it before the tasks are read. |
| D4 | Wake word and Siri open the app listening, but typed or chat opens silent. | Consistency | Low | Say so on the mic ("Listening because you said Hey Kitty"). |

### E. Trust, accuracy and errors
| # | Finding | Heuristic | Sev | Improvement |
|---|---|---|---|---|
| E1 | First-try pass on our own voice cases is 58% (105/180) and 61-72% on notes (26/42). Failures: people across lines, long paragraphs, repeats, lists. A user will hit a wrong preview often. | Error prevention | High | Keep fixing the model path, but also make correcting cheap: tap a word, swipe a task, "Not a task" on a row. |
| E2 | When the model is unavailable (Apple Intelligence off, unsupported device, low battery) the experience is not checked here. The app depends on it. | Help users recover | High (unverified) | A first-run capability check with a plain message and a manual "Add task" path that never needs the model. |
| E3 | Silent failures: 6 of 180 voice turns show nothing when something was due. | Visibility of status | Med | Always say something ("I didn't catch a task in that; kept it as a note"). |
| E4 | Kitty's "wait" (still talking) produces no signal; the user does not know whether they were heard. | Visibility | Med | A subtle "listening for more" pulse. |

### F. Settings, jargon and accessibility
| # | Finding | Heuristic | Sev | Improvement |
|---|---|---|---|---|
| F1 | The chat's top-left menu shows developer options to every user: Speech engine (four engines), Live model view, Save task details, Delete saved task details. | Minimalism, match with real world | Med-High | Hide behind "Advanced"; default sensible values; plain-language names. |
| F2 | Jargon: preview, routine, profile, playbook, labels, "task details". | Match with real world | Med | "List", "Repeating task", "Check before saving". |
| F3 | Top-bar buttons are 36-40 pt (below the 44 pt guideline). Overdue is red; color is backed by "late" text only in the tray. Dynamic Type and VoiceOver were not tested. | Accessibility | Med | 44 pt targets, test at the largest text size, add VoiceOver labels to chips and rows. |
| F4 | Chat top bar has three icons (options, tasks, close) with only one labelled. | Recognition | Low | Labels or a "Tasks" text button. |

## Priorities
**Now (fix before the next test with users)**
1. Confirm on a device: heading-only waits; heading+items read as one list; tray shows saved tasks; "yes" only in the tray. (B1, B2, C3)
2. Plain recovery message with a visible button (B3) and remove the stale hint (B7).
3. Model-unavailable path and a manual add-task route (E2).
4. Hide developer options (F1).

**Next**
5. One-tap correction: inline words in the bubble, swipe to remove, "Not a task" (E1, D3).
6. Preview row shows 1-3 tasks inline (B6); consistent wording (B5, B4).
7. Tray scope label and "All my tasks" link (C2); home keyboard layout fix (A3); Return sends (A4).

**Later**
8. First-run tour (A6), chip grouping (A2), delete bubble with tasks (B10), 44 pt targets and an accessibility pass (F3).

## Proposed test with users (5 people, 30 minutes each, moderated)
- **Tasks:** the six above, plus "put your own real week into it".
- **Measure:** completed without help (yes/no), time to first saved task, number of corrections before saving, number of times they said "where did it go?", a SUS score at the end, and one question: "What do you think this app keeps, and what does it do with it?".
- **Instrument:** note count per chat, preview opened / saved / discarded, corrections per preview, silent turns, time from send to preview, mic on/off use, chat-chip taps.
- **Success bar:** 4 of 5 save a correct list on the first try; none lose a message; none ask where a task went.

## What this review cannot tell you
Real-world wording, how people actually speak lists, how often they correct previews, whether the one-line preview row is liked or resented, and whether a chat per typed note feels natural or cluttered. Those need the test above.
