# Kitty scoreboard report

Time zone: Asia/Kolkata. Profile: app default (flat). Runs per case: 3. Reference time: 2026-10-28 12:00 IST.

**First-try pass rate: 0/15** (0%). Silent turns (nothing shown when something was due): 0. Model time per turn: median 2.1 s, 90th percentile 2.8 s, worst 3.5 s.

## By group

| group | passed | of |
|---|---|---|
| Dates and times | 0 | 6 |
| Quantity, place, purpose | 0 | 6 |
| Simple task | 0 | 3 |

## By case

| case | group | input | passes |
|---|---|---|---|
| A02 | Simple task | call the plumber about the leaking tap in the kitchen | 0/3 |
| B03 | Dates and times | pick up Aarav from tuition at six thirty today evening | 0/3 |
| B04 | Dates and times | parent teacher meeting is on Saturday at ten uh remind me | 0/3 |
| D04 | Quantity, place, purpose | buy a birthday gift for Anaya's friend's party on Sunday something under five hundred rupe | 0/3 |
| D05 | Quantity, place, purpose | book a cab to the airport at four am on Friday for the Delhi trip | 0/3 |

## Samples

### A02 (Simple task): "call the plumber about the leaking tap in the kitchen"
- run 1: FAIL: outcome question (wanted a card with tasks); missing task: Call plumber about leaking kitchen tap (question, 3.5 s)
      (question) What task do you want to add today?
      trace:
        SWIFT: no intent call: nothing waits and the words do not point at a saved task, so they make tasks
        ROUTE: model
        WARNING: the title "call the plumber about the leaking tap in the kitchen" says nothing about a task (app-talk, a bare command, or the spoken command itself): refused
        WARNING: 1 draft(s) had no usable title (blank, or only app-talk) and were dropped
        WARNING: every task the model named said nothing about a task: no card is made, the user is asked what to add
        CHECKS: outcome: noContent
        ROUTE: no-content
        FROM MODEL: flat content question: What task do you want to add today?
        RESULT: question: What task do you want to add today?
      model wrote: {"question": "What task do you want to add today?"}
- run 2: FAIL: outcome question (wanted a card with tasks); missing task: Call plumber about leaking kitchen tap (question, 2.3 s)
      (question) What task do you want to add today?
      trace:
        SWIFT: no intent call: nothing waits and the words do not point at a saved task, so they make tasks
        ROUTE: model
        WARNING: the title "call the plumber about the leaking tap in the kitchen" says nothing about a task (app-talk, a bare command, or the spoken command itself): refused
        WARNING: 1 draft(s) had no usable title (blank, or only app-talk) and were dropped
        WARNING: every task the model named said nothing about a task: no card is made, the user is asked what to add
        CHECKS: outcome: noContent
        ROUTE: no-content
        FROM MODEL: flat content question: What task do you want to add today?
        RESULT: question: What task do you want to add today?
      model wrote: {"question": "What task do you want to add today?"}
- run 3: FAIL: outcome question (wanted a card with tasks); missing task: Call plumber about leaking kitchen tap (question, 2.3 s)
      (question) What task do you want to add today?
      trace:
        SWIFT: no intent call: nothing waits and the words do not point at a saved task, so they make tasks
        ROUTE: model
        WARNING: the title "call the plumber about the leaking tap in the kitchen" says nothing about a task (app-talk, a bare command, or the spoken command itself): refused
        WARNING: 1 draft(s) had no usable title (blank, or only app-talk) and were dropped
        WARNING: every task the model named said nothing about a task: no card is made, the user is asked what to add
        CHECKS: outcome: noContent
        ROUTE: no-content
        FROM MODEL: flat content question: What task do you want to add today?
        RESULT: question: What task do you want to add today?
      model wrote: {"question": "What task do you want to add today?"}

### B03 (Dates and times): "pick up Aarav from tuition at six thirty today evening"
- run 1: FAIL: Pick up Aarav from tuition: due none (wanted 2026-10-28); Pick up Aarav from tuition: time none (wanted 18:30) (proposal, 1.9 s)
      pick up Aarav from tuition [for Aarav]
      trace:
        SWIFT: no intent call: nothing waits and the words do not point at a saved task, so they make tasks
        SWIFT: scope (person: Aarav) filled what 1 new task(s) left empty; a value a task said itself was kept
        SWIFT: coverage: nothing in the answer accounts for “six”, “thirty”
        SWIFT: no second call: there is no earlier accepted sentence to add
        ROUTE: model
        SWIFT: purpose "tuition" is not in what the user said, or only repeats the title: not kept
        CHECKS: outcome: items([Kitty.DraftItem(id: F5090FC8-501B-4186-91A0-90E39260E8E0, ref: "", kind: Kitty.DraftItem.Kind.task, title: "pick up Aarav from tuition", categoryName: nil, due: nil, timeMinutes: nil, priority: nil, assignee: Optional("Aarav"), notes: nil, reason: nil, utteranceID: nil, recurrence: nil, listName: nil, instructions: nil, schedule: nil, softDue: nil, slot: nil, heardAs: nil, quoteUnv
        SWIFT: the draft keeps this scope for the next words: person: Aarav
        WARNING: heard but not made into a task: “six”, “thirty”. The card says so and offers to add it
        RESULT: proposal: Save “pick up Aarav from tuition” | I heard “six”, “thirty” but didn't make a task from it. Tap Try again to add it, or say "yes" to save the list as it is.
      model wrote: {"outcome": "create", "tasks": [{"purpose": "tuition", "title": "pick up Aarav from tuition"}], "assignee": "Aarav"}
- run 2: FAIL: Pick up Aarav from tuition: time evening (wanted 18:30) (proposal, 2.1 s)
      pick up Aarav from tuition [for Aarav] [due Wed, 28 Oct] [evening]
      trace:
        SWIFT: no intent call: nothing waits and the words do not point at a saved task, so they make tasks
        SWIFT: scope (person: Aarav; day: today evening) filled what 1 new task(s) left empty; a value a task said itself was kept
        SWIFT: coverage: nothing in the answer accounts for “six”, “thirty”
        SWIFT: no second call: there is no earlier accepted sentence to add
        ROUTE: model
        SWIFT: purpose "tuition" is not in what the user said, or only repeats the title: not kept
        CHECKS: outcome: items([Kitty.DraftItem(id: 436C7F56-F850-423C-BB2F-AF1041DB533C, ref: "", kind: Kitty.DraftItem.Kind.task, title: "pick up Aarav from tuition", categoryName: nil, due: Optional(2026-10-27 18:30:00 +0000), timeMinutes: nil, priority: nil, assignee: Optional("Aarav"), notes: nil, reason: nil, utteranceID: nil, recurrence: nil, listName: nil, instructions: nil, schedule: nil, softDue: nil, s
        SWIFT: the draft keeps this scope for the next words: person: Aarav; day: today evening
        WARNING: heard but not made into a task: “six”, “thirty”. The card says so and offers to add it
        RESULT: proposal: Save “pick up Aarav from tuition” | I heard “six”, “thirty” but didn't make a task from it. Tap Try again to add it, or say "yes" to save the list as it is.
      model wrote: {"outcome": "create", "assignee": "Aarav", "tasks": [{"title": "pick up Aarav from tuition", "purpose": "tuition"}], "dueDate": "today evening"}
- run 3: FAIL: Pick up Aarav from tuition: time evening (wanted 18:30) (proposal, 1.8 s)
      pick up Aarav from tuition [for Aarav] [due Wed, 28 Oct] [evening]
      trace:
        SWIFT: no intent call: nothing waits and the words do not point at a saved task, so they make tasks
        SWIFT: coverage: nothing in the answer accounts for “six”, “thirty”
        SWIFT: no second call: there is no earlier accepted sentence to add
        ROUTE: model
        CHECKS: outcome: items([Kitty.DraftItem(id: FC7341AE-2CDB-4EBA-BBBC-A5B0FE8A25F2, ref: "", kind: Kitty.DraftItem.Kind.task, title: "pick up Aarav from tuition", categoryName: nil, due: Optional(2026-10-27 18:30:00 +0000), timeMinutes: nil, priority: nil, assignee: Optional("Aarav"), notes: nil, reason: nil, utteranceID: nil, recurrence: nil, listName: nil, instructions: nil, schedule: nil, softDue: nil, s
        WARNING: heard but not made into a task: “six”, “thirty”. The card says so and offers to add it
        RESULT: proposal: Save “pick up Aarav from tuition” | I heard “six”, “thirty” but didn't make a task from it. Tap Try again to add it, or say "yes" to save the list as it is.
      model wrote: {"tasks": [{"assignee": "Aarav", "dueDate": "today evening", "title": "pick up Aarav from tuition"}], "outcome": "create"}

### B04 (Dates and times): "parent teacher meeting is on Saturday at ten uh remind me"
- run 1: FAIL: outcome question (wanted a card with tasks); missing task: Attend parent-teacher meeting (question, 2.0 s)
      (question) What would you like the task to be?
      trace:
        SWIFT: no intent call: nothing waits and the words do not point at a saved task, so they make tasks
        SWIFT: scope (person: Parent; day: Saturday) filled what 1 new task(s) left empty; a value a task said itself was kept
        SWIFT: coverage: nothing in the answer accounts for “ten”
        SWIFT: no second call: there is no earlier accepted sentence to add
        ROUTE: model
        CHECKS: outcome: wait
        ROUTE: model-waited-asked
        RESULT: question: What would you like the task to be?
      model wrote: {"assignee": "parent", "dueDate": "Saturday", "outcome": "wait", "tasks": [{"title": "remind me of parent teacher meeting", "purpose": "remind"}]}
- run 2: FAIL: outcome question (wanted a card with tasks); missing task: Attend parent-teacher meeting (question, 1.7 s)
      (question) What would you like the task to be?
      trace:
        SWIFT: no intent call: nothing waits and the words do not point at a saved task, so they make tasks
        SWIFT: coverage: nothing in the answer accounts for “ten”
        SWIFT: no second call: there is no earlier accepted sentence to add
        ROUTE: model
        CHECKS: outcome: wait
        ROUTE: model-waited-asked
        RESULT: question: What would you like the task to be?
      model wrote: {"tasks": [{"dueDate": "Saturday", "title": "remind me of parent teacher meeting"}], "outcome": "wait"}
- run 3: FAIL: outcome question (wanted a card with tasks); missing task: Attend parent-teacher meeting (question, 1.7 s)
      (question) What would you like the task to be?
      trace:
        SWIFT: no intent call: nothing waits and the words do not point at a saved task, so they make tasks
        SWIFT: coverage: nothing in the answer accounts for “ten”
        SWIFT: no second call: there is no earlier accepted sentence to add
        ROUTE: model
        CHECKS: outcome: wait
        ROUTE: model-waited-asked
        RESULT: question: What would you like the task to be?
      model wrote: {"tasks": [{"title": "remind me about parent teacher meeting", "dueDate": "Saturday"}], "outcome": "wait"}

### D04 (Quantity, place, purpose): "buy a birthday gift for Anaya's friend's party on Sunday something under five hundred rupees"
- run 1: FAIL: Buy birthday gift: purpose something under five hundred rupees (wanted Anaya's friend's party) (proposal, 2.1 s)
      buy a birthday gift for Anaya's friend's party [for Anaya] [due Sun, 1 Nov] [purpose: something under five hundred rupees]
      trace:
        SWIFT: no intent call: nothing waits and the words do not point at a saved task, so they make tasks
        SWIFT: scope (person: Anaya; day: Sunday) filled what 1 new task(s) left empty; a value a task said itself was kept
        ROUTE: model
        CHECKS: outcome: items([Kitty.DraftItem(id: DDAD6B19-F9DA-49E4-9E5B-182A014CBC1E, ref: "", kind: Kitty.DraftItem.Kind.task, title: "buy a birthday gift for Anaya\'s friend\'s party", categoryName: nil, due: Optional(2026-10-31 18:30:00 +0000), timeMinutes: nil, priority: nil, assignee: Optional("Anaya"), notes: nil, reason: Optional("something under five hundred rupees"), utteranceID: nil, recurrence: nil
        SWIFT: the draft keeps this scope for the next words: person: Anaya; day: Sunday
        RESULT: proposal: Save “buy a birthday gift for Anaya's friend's party” | I have 1 task: buy a birthday gift for anaya's friend's party. Should I save these?
      model wrote: {"assignee": "Anaya", "dueDate": "Sunday", "outcome": "create", "tasks": [{"title": "buy a birthday gift for Anaya's friend's party", "purpose": "something under five hundred rupees"}]}
- run 2: FAIL: outcome question (wanted a card with tasks); missing task: Buy birthday gift (question, 2.6 s)
      (question) What task do you want to add today?
      trace:
        SWIFT: no intent call: nothing waits and the words do not point at a saved task, so they make tasks
        ROUTE: model
        WARNING: the title "buy a birthday gift for Anaya's friend's party on Sunday something under five hundred rupees" says nothing about a task (app-talk, a bare command, or the spoken command itself): refused
        WARNING: 1 draft(s) had no usable title (blank, or only app-talk) and were dropped
        WARNING: every task the model named said nothing about a task: no card is made, the user is asked what to add
        CHECKS: outcome: noContent
        ROUTE: no-content
        FROM MODEL: flat content question: What task do you want to add today?
        RESULT: question: What task do you want to add today?
      model wrote: {"question": "What task do you want to add today?"}
- run 3: FAIL: outcome question (wanted a card with tasks); missing task: Buy birthday gift (question, 2.8 s)
      (question) What task do you want to add today?
      trace:
        SWIFT: no intent call: nothing waits and the words do not point at a saved task, so they make tasks
        ROUTE: model
        WARNING: the title "buy a birthday gift for Anaya's friend's party on Sunday something under five hundred rupees" says nothing about a task (app-talk, a bare command, or the spoken command itself): refused
        WARNING: 1 draft(s) had no usable title (blank, or only app-talk) and were dropped
        WARNING: every task the model named said nothing about a task: no card is made, the user is asked what to add
        CHECKS: outcome: noContent
        ROUTE: no-content
        FROM MODEL: flat content question: What task do you want to add today?
        RESULT: question: What task do you want to add today?
      model wrote: {"question": "What task do you want to add today?"}

### D05 (Quantity, place, purpose): "book a cab to the airport at four am on Friday for the Delhi trip"
- run 1: FAIL: outcome question (wanted a card with tasks); missing task: Book cab to airport (question, 2.6 s)
      (question) What task do you want to add today?
      trace:
        SWIFT: no intent call: nothing waits and the words do not point at a saved task, so they make tasks
        ROUTE: model
        WARNING: the title "book a cab to the airport at four am on Friday for the Delhi trip" says nothing about a task (app-talk, a bare command, or the spoken command itself): refused
        WARNING: 1 draft(s) had no usable title (blank, or only app-talk) and were dropped
        WARNING: every task the model named said nothing about a task: no card is made, the user is asked what to add
        CHECKS: outcome: noContent
        ROUTE: no-content
        FROM MODEL: flat content question: What task do you want to add today?
        RESULT: question: What task do you want to add today?
      model wrote: {"question": "What task do you want to add today?"}
- run 2: FAIL: Book cab to airport: time none (wanted 04:00); Book cab to airport: purpose none (wanted Delhi trip) (proposal, 1.9 s)
      book a cab to the airport [for Delhi Trip] [due Fri, 30 Oct] [schedule: four am] [needs a fix: repeat=four am]
      trace:
        SWIFT: no intent call: nothing waits and the words do not point at a saved task, so they make tasks
        SWIFT: scope (person: Delhi Trip; day: Friday) filled what 1 new task(s) left empty; a value a task said itself was kept
        ROUTE: model
        CHECKS: outcome: items([Kitty.DraftItem(id: 0D64BF9C-EB99-4FB1-BB49-8D72EFBFD452, ref: "", kind: Kitty.DraftItem.Kind.task, title: "book a cab to the airport", categoryName: nil, due: Optional(2026-10-29 18:30:00 +0000), timeMinutes: nil, priority: nil, assignee: Optional("Delhi Trip"), notes: nil, reason: nil, utteranceID: nil, recurrence: nil, listName: nil, instructions: nil, schedule: Optional("four a
        SWIFT: the draft keeps this scope for the next words: person: Delhi Trip; day: Friday
        RESULT: proposal: Save “book a cab to the airport” | I have 1 task: book a cab to the airport. Should I save these?
      model wrote: {"outcome": "create", "assignee": "Delhi trip", "dueDate": "Friday", "tasks": [{"title": "book a cab to the airport", "schedule": "four am"}]}
- run 3: FAIL: Book cab to airport: due none (wanted 2026-10-30); Book cab to airport: time none (wanted 04:00) (proposal, 1.8 s)
      book a cab to the airport [schedule: four am on Friday] [purpose: for the Delhi trip] [needs a fix: repeat=four am on Friday]
      trace:
        SWIFT: no intent call: nothing waits and the words do not point at a saved task, so they make tasks
        ROUTE: model
        CHECKS: outcome: items([Kitty.DraftItem(id: 1C644A16-6F8C-43A4-8E3A-B1E4E05B86AE, ref: "", kind: Kitty.DraftItem.Kind.task, title: "book a cab to the airport", categoryName: nil, due: nil, timeMinutes: nil, priority: nil, assignee: nil, notes: nil, reason: Optional("for the Delhi trip"), utteranceID: nil, recurrence: nil, listName: nil, instructions: nil, schedule: Optional("four am on Friday"), softDue: 
        RESULT: proposal: Save “book a cab to the airport” | I have 1 task: book a cab to the airport. Should I save these?
      model wrote: {"outcome": "create", "tasks": [{"schedule": "four am on Friday", "purpose": "for the Delhi trip", "title": "book a cab to the airport"}]}

