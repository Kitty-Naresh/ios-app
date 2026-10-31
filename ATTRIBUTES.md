# Attributes of a task: who can set them, and what counts as evidence

The rule (30 Oct 2026): **an attribute is stored only when the user's own words for this task state it.** No evidence, no value.
A guess, a likely default, a pattern the model recognises or a value copied from elsewhere is not evidence. Each kept value carries the
words that justified it (`DraftItem.evidence`, copied to `TaskItem.evidence`); a value set by hand carries "added by you".

"Today" is the rule before this change. "Now" is the rule after it. A silent source is any place that set a value with no evidence.

| Attribute | Who can set it | Today's evidence rule | Silent sources found | Now |
|---|---|---|---|---|
| title | model (`title`), hand | `TaskMeaning.isMeaningful` (not app-talk or a spoken command) | none | unchanged: the user's words naming the task |
| day (`due`) | model `dueDate`, `WhenReader`, scope (`DraftScope.day`), hand | `DateResolver` reads it; unreadable is flagged | scope carry-over onto items whose words say otherwise; save stored `p.due ?? today` (`TaskStore.addMany`); `effectiveDue` counted an undated task as today | a day phrase in the task's own words (clause), or an applicable header; no stored default |
| time (`timeMinutes`) | model `dueTime`, `WhenReader`, scope time, hand | `TimeResolver` / `WhenReader` | `WhenReader` guessed AM/PM ("at ten" 10:00, "at five" 17:00) | only with a said am/pm, a day-part, a 24-hour form, noon or midnight; otherwise the phrase stays as said and is flagged |
| day-part (`slot`) | model `dueTime`, `WhenReader`, hand | `TimeResolver.slotWords` | `TaskItem.sortSlot` uses `DaySlot.guess(from: title)`, for ordering only (never stored, never shown): kept | an explicit day-part word with a cue |
| timeframe (`softDue`) | model, `WhenReader`, hand | `DateResolver` soft words | model put it in `purpose` | an explicit loose-deadline phrase |
| repeat (`schedule`, `recurrence`) | model `schedule`, hand | `RecurrenceParser`; unreadable flagged | model wrote a day or time into `schedule` (moved by the mapper and `WhenReader`) | an explicit repeat cue (every, each, daily, weekly, monthly, alternate, a plural weekday) |
| assignee | model `assignee`, scope, hand | `Assignee.normalize`; scope checked by `ScopeReader` | model: "School", "Kal", "Parent", "the Delhi trip", "user"; scope leaked "Househelp" onto "buy milk, that is for me"; `effectiveAssignee` defaulted by category (Househelp, else Me); the preview showed "Me (assumed)" | a known person or role with a doer cue ("ask Rani to", "for Rani", "tell Rani"), or an applicable header; empty means unassigned and is shown as no person |
| purpose (`reason`) | model `purpose`, hand | `Provenance.said` (in the words, not a repeat of the title) | timeframes and places as purposes ("before Diwali", "tuition") | a reason cue (because, so that, since, as, "for the ...") plus the reason, in the words |
| instructions | model `instructions`, hand | `Provenance.said` | `"One"`, whole clauses | a quantity, dose, variant, preference or method phrase in the words |
| list (`listName`) | model `listName`, `ListNameGate`, hand | `ListNameGate` (not a person, a command, or a timeframe) | "House Add hostel" | a list cue ("to the X order", "X list") or an existing list |
| category | hand only now | none for the flat path | `PlannedTask`/`ValidatedTask.planned()` and every save site set `TaskCategory.guess(from: title)`; `effectiveCategory` guessed again at read time; "Category: Househelp" on cards nobody said | only `TaskCategory.mentioned` in the user's own words; otherwise empty ("Other" in category filters, no chip) |
| priority | hand, older bulk path | none (the flat path never sets it) | none found | an explicit word: urgent, important, asap, high or low priority |
| notes | Swift only ("Repeat not understood: X") | system text, never the user's words | none | unchanged: never evidence for anything |
| quantity / place | do not exist yet | - | - | - |

Silent sources beyond the first list:
- `TaskStore.add(_:)` (typed in by hand) still sets today as the due day. It is the user's own action on the Today screen, so it is kept
  and recorded as "added by you".
- `TaskStore.addMany(titles)`, routines (`addRoutine`) and playbook steps stored `TaskCategory.guess`; they now store nothing.
- `Routine.effectiveAssignee` defaulted like a task's; it follows the same new rule.
- The single-task preview added "(assumed)" tags for person and day and a note explaining them; removed.
- `DaySlot.guess(from:)` stays for ordering a list only. It is not stored or shown.
