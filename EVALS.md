# Kitty eval cases

Generated from `Tests/KittyEvals.swift` (`testWriteEvalCatalogue`). 75 cases. Each case is a recorded utterance sequence replayed against a scripted model. “Today” is Wednesday 21 October 2026; “+1d” means tomorrow.

The 12 to start with: #1, #2, #4, #41, #42, #17, #45, #24, #48, #31, #39, #75.

## A. Turn completeness

| # | Case | Input (each turn) | Expected behaviour (each turn) | Expected saved objects |
|---|---|---|---|---|
| 1 | “Add a task to…” waits | “Add a task to…” | no model call → wait: held locally, no model call; state `listening`; model not called | nothing saved |
| 2 | “Add a task to clean the…” waits | “Add a task to clean the…” | no model call → wait: held locally, no model call; state `listening`; model not called | nothing saved |
| 3 | “Um, I need to…” waits | “Um, I need to…” | no model call → wait: held locally, no model call; state `listening`; model not called | nothing saved |
| 4 | A complete task is evaluated and saved | “Add a task to clean the bathroom” | model: `create_task` “Clean the bathroom” → saved; state `listening`; model called | 1 task: “Clean the bathroom” (Bathroom) |
| 5 | A trailing “and…” waits | “Clean bathroom, buy milk, and…” | no model call → wait: held locally, no model call; state `listening`; model not called | nothing saved |
| 6 | Three finished items are evaluated as a bulk draft | “Clean bathroom, buy milk, and water plants” | model: bulk `create_tasks` (3 items) → preview: Clean bathroom / Buy milk / Water plants; says “3 tasks … should i save these?”; state `awaitingConfirmation` | nothing saved; still pending: Clean bathroom / Buy milk / Water plants |
| 7 | “Actually, make it high priority” updates the pending task | 1. “Add a task to clean the bathroom”<br>2. “Actually, make it high priority” | 1. model: `create_task` “Clean the bathroom” → preview: Clean the bathroom; state `pendingTask`<br>2. model: `update_task` → saved; state `listening`; model called | 1 task: “Clean the bathroom” (high priority) |
| 8 | “Done” saves the pending task | 1. “Add a task to clean the bathroom”<br>2. “done” | 1. model: `create_task` “Clean the bathroom” → preview: Clean the bathroom; state `pendingTask`<br>2. no model call → saved; state `listening`; model not called | 1 task: “Clean the bathroom” |

## B. Task validation

| # | Case | Input (each turn) | Expected behaviour (each turn) | Expected saved objects |
|---|---|---|---|---|
| 9 | “Add a task for the project” asks what should be done | “Add a task for the project” | model: `clarify` “What should be done for the project?” → asks one question: “what should be done”; state `awaitingClarification`; model called | nothing saved |
| 10 | “Add a task to clean” asks what to clean after a long silence | “Add a task to clean” *(then a long silence)* | no model call → asks one question: “what should i clean?”; state `awaitingClarification`; model not called | nothing saved |
| 11 | A lone “Buy” asks what to buy after a long silence | “Buy” *(then a long silence)* | no model call → asks one question: “what should i buy?”; state `awaitingClarification`; model not called | nothing saved |
| 12 | “The bathroom” creates nothing | “The bathroom” | no model call → wait: held locally, no model call; state `listening`; model not called | nothing saved |
| 13 | “Add a task to clean the bathroom” creates a task | “Add a task to clean the bathroom” | model: `create_task` “Clean the bathroom” → saved; state `listening`; model called | 1 task: “Clean the bathroom” |
| 14 | “Buy milk tomorrow” creates a task due tomorrow | “Buy milk tomorrow” | model: `create_task` “Buy milk” → saved; state `listening` | 1 task: “Buy milk” (due +1d) |
| 15 | “Call the plumber about the leaking tap” creates a task | “Call the plumber about the leaking tap” | model: `create_task` “Call the plumber about the leaking tap” → saved; state `listening` | 1 task: “Call the plumber about the leaking tap” |
| 16 | “Add a task called bathroom” has no action, so it asks | “Add a task called bathroom” | model: `create_task` “Bathroom” → asks one question: “bathroom”; state `awaitingClarification`; model called | nothing saved |

## C. Routines

| # | Case | Input (each turn) | Expected behaviour (each turn) | Expected saved objects |
|---|---|---|---|---|
| 17 | Every morning is a daily routine | “Water the plants every morning” | model: `create_routine` “Water the plants” → saved; state `listening` | 1 routine: “Water the plants” (Plants, every day) |
| 18 | Every Monday is a weekly routine | “Clean the bathroom every Monday” | model: `create_routine` “Clean the bathroom” → saved; state `listening` | 1 routine: “Clean the bathroom” (every Monday) |
| 19 | Every day is a daily routine | “Take out trash every day” | model: `create_routine` “Take out trash” → saved; state `listening` | 1 routine: “Take out trash” (every day) |
| 20 | “Buy milk tomorrow” is a one-time task, not a routine | “Buy milk tomorrow” | model: `create_task` “Buy milk” → saved; state `listening` | 1 task: “Buy milk” (due +1d) |
| 21 | “Add watering plants” asks one-time or routine | “Add watering plants” | model: `clarify` “Should this be a one-time task or a repeating routine?” → asks one question: “one-time … routine”; state `awaitingClarification` | nothing saved |
| 22 | A routine with an assignee | “Clean bathroom every Monday for househelp” | model: `create_routine` “Clean bathroom” → saved; state `listening` | 1 routine: “Clean bathroom” (for Househelp, every Monday) |
| 23 | A daily list becomes three routines after one confirmation | 1. “Every day: make beds, wash dishes, wipe counters”<br>2. “Yes” | 1. model: bulk `create_routines` (3 items) → preview: Make beds / Wash dishes / Wipe counters; says “3 daily routines”; state `awaitingConfirmation`<br>2. no model call → saved, says “saved 3 routines”; state `listening`; model not called | 3 routines: “Make beds” (every day), “Wash dishes” (every day), “Wipe counters” (every day) |

## D. Playbooks

| # | Case | Input (each turn) | Expected behaviour (each turn) | Expected saved objects |
|---|---|---|---|---|
| 24 | A playbook proposes steps and confirms once | 1. “Create a playbook to cook biryani”<br>2. “Yes” | 1. model: bulk `create_playbook` (4 steps) → preview: Chop onions / Marinate the chicken / Cook the rice / Layer and steam; says “should i include these steps”; state `awaitingConfirmation`<br>2. no model call → saved, says “cook biryani playbook … four steps”; state `listening`; model not called | playbook “Cook biryani”, 4 steps |
| 25 | A playbook with a due date | 1. “Prepare the home for guests this Saturday”<br>2. “Yes” | 1. model: `create_playbook` “Prepare home for guests” → preview: Clean the living room / Make the beds / Stock the fridge; state `awaitingConfirmation`<br>2. no model call → saved; state `listening`; model not called | playbook “Prepare home for guests”, 3 steps, due +3d |
| 26 | “Weekly deep clean” proposes steps | 1. “Weekly deep clean”<br>2. “Yes” | 1. model: `create_playbook` “Weekly deep clean” → preview: Dust the shelves / Mop the floors / Scrub the bathrooms; state `awaitingConfirmation`<br>2. no model call → saved; state `listening`; model not called | playbook “Weekly deep clean”, 3 steps |
| 27 | “Move-in cleaning” proposes steps | 1. “Move-in cleaning”<br>2. “Yes” | 1. model: `create_playbook` “Move-in cleaning” → preview: Wipe the cabinets / Clean the windows / Mop the floors; state `awaitingConfirmation`<br>2. no model call → saved; state `listening`; model not called | playbook “Move-in cleaning”, 3 steps |
| 28 | “Cook pasta” is ambiguous between a task and a playbook | “Cook pasta” | model: `clarify` “Is this a one-time task, or steps you want me to remember as a playbook?” → asks one question: “playbook”; state `awaitingClarification` | nothing saved |
| 29 | A playbook step is added to the pending playbook | 1. “Create a playbook to cook biryani”<br>2. “Add a playbook step: buy groceries”<br>3. “Yes” | 1. model: bulk `create_playbook` (4 steps) → preview: Chop onions / Marinate the chicken / Cook the rice / Layer and steam; state `awaitingConfirmation`<br>2. no model call → preview: Chop onions / Marinate the chicken / Cook the rice / Layer and steam / Buy groceries; says “added step 5”; state `awaitingConfirmation`<br>3. no model call → saved; state `listening`; model not called | playbook “Cook biryani”, 5 steps |
| 30 | Changing a step edits it in place, with no duplicate | 1. “Create a playbook to cook biryani”<br>2. “Change the first step to buy vegetables”<br>3. “Yes” | 1. model: bulk `create_playbook` (4 steps) → preview: Chop onions / Marinate the chicken / Cook the rice / Layer and steam; state `awaitingConfirmation`<br>2. no model call → preview: Buy vegetables / Marinate the chicken / Cook the rice / Layer and steam; says “changed step 1”; state `awaitingConfirmation`<br>3. no model call → saved; state `listening`; model not called | playbook “Cook biryani”, 4 steps, first “Buy vegetables” |

## E. Bulk creation

| # | Case | Input (each turn) | Expected behaviour (each turn) | Expected saved objects |
|---|---|---|---|---|
| 31 | Three actions make three task drafts | “Clean the bathroom, buy milk, and water the plants” | model: bulk `create_tasks` (3 items) → preview: Clean the bathroom / Buy milk / Water the plants; says “3 tasks … clean the bathroom, buy milk, and water the plants … should i save these?”; state `awaitingConfirmation` | nothing saved; still pending: Clean the bathroom / Buy milk / Water the plants |
| 32 | “Add these tasks: …” makes three drafts | “Add these tasks: dishes, laundry, trash” | model: bulk `create_tasks` (3 items) → preview: Wash dishes / Do laundry / Take out trash; state `awaitingConfirmation` | nothing saved; still pending: Wash dishes / Do laundry / Take out trash |
| 33 | A daily list makes three routine drafts | 1. “Daily househelp tasks: make beds, wash dishes, wipe counters”<br>2. “Yes” | 1. model: bulk `create_routines` (3 items) → preview: Make beds / Wash dishes / Wipe counters; says “3 daily routines”; state `awaitingConfirmation`<br>2. no model call → saved; state `listening`; model not called | 3 routines: “Make beds” (every day), “Wash dishes” (every day), “Wipe counters” (every day) |
| 34 | “Buy milk and bread” is one grocery task | “Buy milk and bread” | model: `create_task` “Buy milk and bread” → saved; state `listening` | 1 task: “Buy milk and bread” (Groceries) |
| 35 | “Clean the bathroom and buy milk” is two tasks | 1. “Clean the bathroom and buy milk”<br>2. “Yes” | 1. model: bulk `create_tasks` (2 items) → preview: Clean the bathroom / Buy milk; says “2 tasks”; state `awaitingConfirmation`<br>2. no model call → saved; state `listening`; model not called | 2 tasks: “Clean the bathroom”, “Buy milk” |
| 36 | Five tasks wait for one confirmation | 1. “Add five tasks: dishes, laundry, trash, beds, floors”<br>2. “Yes” | 1. model: bulk `create_tasks` (5 items) → preview: Wash dishes / Do laundry / Take out trash / Make beds / Mop floors; says “5 tasks”; state `awaitingConfirmation`<br>2. no model call → saved; state `listening`; model not called | 5 tasks: “Wash dishes”, “Do laundry”, “Take out trash”, “Make beds”, “Mop floors” |
| 37 | “Actually change milk to bread” changes only the milk item | 1. “Clean the bathroom, buy milk, and water the plants”<br>2. “Actually change milk to bread”<br>3. “Yes” | 1. model: bulk `create_tasks` (3 items) → preview: Clean the bathroom / Buy milk / Water the plants; state `awaitingConfirmation`<br>2. no model call → preview: Clean the bathroom / Buy bread / Water the plants; says “changed it to buy bread”; state `awaitingConfirmation`; model not called<br>3. no model call → saved; state `listening`; model not called | 3 tasks: “Clean the bathroom”, “Buy bread”, “Water the plants” |
| 38 | “Also add water plants” extends the pending draft | 1. “Clean the bathroom and buy milk”<br>2. “Also add water plants”<br>3. “Yes” | 1. model: bulk `create_tasks` (2 items) → preview: Clean the bathroom / Buy milk; state `awaitingConfirmation`<br>2. no model call → preview: Clean the bathroom / Buy milk / Water plants; says “added water plants … should i save these?”; state `awaitingConfirmation`; model not called<br>3. no model call → saved; state `listening`; model not called | 3 tasks: “Clean the bathroom”, “Buy milk”, “Water plants” |
| 39 | “Yes, save them” saves all, once | 1. “Clean the bathroom, buy milk, and water the plants”<br>2. “Yes, save them” | 1. model: bulk `create_tasks` (3 items) → preview: Clean the bathroom / Buy milk / Water the plants; state `awaitingConfirmation`<br>2. no model call → saved, says “saved 3 tasks”; state `listening`; model not called | 3 tasks: “Clean the bathroom”, “Buy milk”, “Water the plants” |
| 40 | “No, remove the trash task” removes only that item | 1. “Add these tasks: dishes, laundry, trash”<br>2. “No, remove the trash task”<br>3. “Yes” | 1. model: bulk `create_tasks` (3 items) → preview: Wash dishes / Do laundry / Take out trash; state `awaitingConfirmation`<br>2. no model call → preview: Wash dishes / Do laundry; says “removed take out trash”; state `awaitingConfirmation`; model not called<br>3. no model call → saved; state `listening`; model not called | 2 tasks: “Wash dishes”, “Do laundry” |

## F. Clarification loops

| # | Case | Input (each turn) | Expected behaviour (each turn) | Expected saved objects |
|---|---|---|---|---|
| 41 | “Add a task for laundry” asks one question | “Add a task for laundry” | model: `clarify` “Do you want to wash it, fold it, or put it away?” → asks one question: “wash”; state `awaitingClarification` | nothing saved |
| 42 | “Wash and fold it” answers it: saved, no second confirmation | 1. “Add a task for laundry”<br>2. “Wash and fold it” | 1. model: `clarify` “Do you want to wash it, fold it, or put it away?” → asks one question: “wash”; state `awaitingClarification`<br>2. model: `create_task` “Wash and fold laundry” → saved; state `listening`; model called | 1 task: “Wash and fold laundry” |
| 43 | “Add a task for the project” asks what action | “Add a task for the project” | model: `clarify` “What do you want to do for the project?” → asks one question: “what do you want to do”; state `awaitingClarification` | nothing saved |
| 44 | “Clean the garage” answers it | 1. “Add a task for the project”<br>2. “Clean the garage” | 1. model: `clarify` “What do you want to do for the project?” → asks one question; state `awaitingClarification`<br>2. model: `create_task` “Clean the garage” → saved; state `listening` | 1 task: “Clean the garage” |
| 45 | “Add watering plants” asks one-time or routine | “Add watering plants” | model: `clarify` “Should this be a one-time task or a repeating routine?” → asks one question: “one-time … routine”; state `awaitingClarification` | nothing saved |
| 46 | “Every morning” makes the routine with no further question | 1. “Add watering plants”<br>2. “Every morning” | 1. model: `clarify` “Should this be a one-time task or a repeating routine?” → asks one question; state `awaitingClarification`<br>2. model: `create_routine` “Water plants” → saved; state `listening`; model called | 1 routine: “Water plants” (every day) |
| 47 | A playbook for guests: steps and one confirmation question | “Create a playbook for guests” | model: bulk `create_playbook` (3 steps) → preview: Clean the guest room / Make the bed / Stock the fridge; says “should i include these steps”; state `awaitingConfirmation` | nothing saved |
| 48 | “Yes” saves the playbook and nothing more is asked | 1. “Create a playbook for guests”<br>2. “Yes” | 1. model: bulk `create_playbook` (3 steps) → preview: Clean the guest room / Make the bed / Stock the fridge; state `awaitingConfirmation`<br>2. no model call → saved, says “guest prep playbook”; state `listening`; model not called | playbook “Guest prep”, 3 steps |
| 49 | “Add a task” asks what task, after a long silence | “Add a task” *(then a long silence)* | no model call → asks one question: “what would you like the task to be?”; state `awaitingClarification`; model not called | nothing saved |
| 50 | “Buy milk” answers it: saved, no confirmation | 1. “Add a task” *(then a long silence)*<br>2. “Buy milk” | 1. no model call → asks one question; state `awaitingClarification`<br>2. model: `create_task` “Buy milk” → saved; state `listening`; model called | 1 task: “Buy milk” |

## G. Metadata extraction

| # | Case | Input (each turn) | Expected behaviour (each turn) | Expected saved objects |
|---|---|---|---|---|
| 51 | Due date, time and priority | “Buy milk tomorrow at 9am, high priority” | model: `create_task` “Buy milk” → saved; state `listening` | 1 task: “Buy milk” (Groceries, due +1d, 9:00, high priority) |
| 52 | Assignee and due date | “Ask Priya to clean the bathroom on Friday” | model: `create_task` “Clean the bathroom” → saved; state `listening` | 1 task: “Clean the bathroom” (due +2d, for Priya) |
| 53 | Frequency and schedule | “Clean the bathroom every Monday” | model: `create_routine` “Clean the bathroom” → saved; state `listening` | 1 routine: “Clean the bathroom” (every Monday) |
| 54 | Category Admin and no invented due date | “Add a task to pay the electricity bill” | model: `create_task` “Pay the electricity bill” → saved; state `listening` | 1 task: “Pay the electricity bill” (Admin) |
| 55 | Category Plants and a daily routine | “Water the balcony plants every morning” | model: `create_routine` “Water the balcony plants” → saved; state `listening` | 1 routine: “Water the balcony plants” (Plants, every day) |
| 56 | Category Home Maintenance, one-time | “Fix the leaking kitchen tap” | model: `create_task` “Fix the leaking kitchen tap” → saved; state `listening` | 1 task: “Fix the leaking kitchen tap” (Home Maintenance) |
| 57 | Groceries and cleaning supplies stay one errand | “Buy groceries and cleaning supplies” | model: `create_task` “Buy groceries and cleaning supplies” → saved; state `listening` | 1 task: “Buy groceries and cleaning supplies” (Groceries) |
| 58 | “Remind me to call mom tomorrow” | “Remind me to call mom tomorrow” | model: `create_task` “Call mom” → saved; state `listening` | 1 task: “Call mom” (due +1d) |
| 59 | A task with no details asks | “Add a task with no details” | model: `clarify` “What would you like the task to be?” → asks one question: “what would you like the task to be?”; state `awaitingClarification` | nothing saved |
| 60 | Email John about the invoice tomorrow morning | “Add a task to email John about the invoice tomorrow morning” | model: `create_task` “Email John about the invoice” → saved; state `listening` | 1 task: “Email John about the invoice” (due +1d) |

## I. Regression cases (from production failures) and extras

| # | Case | Input (each turn) | Expected behaviour (each turn) | Expected saved objects |
|---|---|---|---|---|
| 61 | No task is created after “um”; the rest is merged | 1. “Um, I need to…”<br>2. “buy milk” | 1. no model call → wait: held locally, no model call; state `listening`; model not called<br>2. model: `create_task` “Buy milk” → saved; state `listening`; model called | 1 task: “Buy milk” |
| 62 | A long silence never asks “Are you done?” | “Add a task to” *(then a long silence)* | no model call → asks one question: “what would you like the task to be?”; state `awaitingClarification`; model not called | nothing saved |
| 63 | A second “yes” after saving saves nothing more | 1. “Clean the bathroom, buy milk, and water the plants”<br>2. “Yes”<br>3. “Yes” | 1. model: bulk `create_tasks` (3 items) → preview: Clean the bathroom / Buy milk / Water the plants; state `awaitingConfirmation`<br>2. no model call → saved; state `listening`; model not called<br>3. no model call → replies “all set”; state `listening`; model not called | 3 tasks: “Clean the bathroom”, “Buy milk”, “Water the plants” |
| 64 | The same task is not saved twice after a clarification | 1. “Add a task for laundry”<br>2. “Wash and fold it”<br>3. “Wash and fold laundry” | 1. model: `clarify` “Do you want to wash it, fold it, or put it away?” → asks one question; state `awaitingClarification`<br>2. model: `create_task` “Wash and fold laundry” → saved; state `listening`<br>3. model: `create_task` “Wash and fold laundry” → replies “already on your list”; state `listening` | 1 task: “Wash and fold laundry” |
| 65 | The pending draft survives “No” and a question | 1. “Add these tasks: dishes, laundry, trash”<br>2. “No”<br>3. “Remove the trash task”<br>4. “Yes” | 1. model: bulk `create_tasks` (3 items) → preview: Wash dishes / Do laundry / Take out trash; state `awaitingConfirmation`<br>2. no model call → asks one question: “what would you like to change?”; state `awaitingClarification`; model not called<br>3. no model call → preview: Wash dishes / Do laundry; state `awaitingConfirmation`; model not called<br>4. no model call → saved; state `listening`; model not called | 2 tasks: “Wash dishes”, “Do laundry” |
| 66 | A playbook with stated steps is one playbook, not separate tasks | 1. “Create a playbook to cook biryani, first chop onions, then marinate chicken, then cook rice”<br>2. “Yes” | 1. model: bulk `create_playbook` (3 steps) → preview: Chop onions / Marinate chicken / Cook rice; says “should i save the cook biryani playbook”; state `awaitingConfirmation`<br>2. no model call → saved; state `listening`; model not called | playbook “Cook biryani”, 3 steps |
| 67 | A routine is never saved as a one-time task | “Water the plants every morning” | model: `create_routine` “Water the plants” → saved; state `listening` | 1 routine: “Water the plants” (every day) |
| 68 | An invented due date and assignee are dropped | “Clean the bathroom” | model: `create_task` “Clean the bathroom” → saved; state `listening` | 1 task: “Clean the bathroom” |
| 69 | A question about optional metadata is never asked | “Add a task to clean the bathroom” | model: `clarify` “When should this be due?” → saved; state `listening` | 1 task: “clean the bathroom” |
| 70 | Two questions in one are cut to the first | “Add a task for the garage” | model: `clarify` “What should I do in the garage? And when?” → asks one question: “what should i do in the garage?”; state `awaitingClarification` | nothing saved |
| 71 | Invalid categories are refused | “Fix the leaking tap” | model: `create_task` “Fix the leaking tap” → saved; state `listening` | 1 task: “Fix the leaking tap” (no category) |
| 72 | The model's date is ignored: Swift resolves “tomorrow” | “Buy milk tomorrow” | model: `create_task` “Buy milk” → saved; state `listening` | 1 task: “Buy milk” (due +1d) |
| 73 | More than five items are summarised by category | 1. “Add these tasks: dishes, laundry, trash, beds, floors, windows, plants”<br>2. “Yes” | 1. model: bulk `create_tasks` (7 items) → preview: Wash dishes / Do laundry / Take out trash / Make beds / Mop floors / Clean windows / Water plants; says “7 tasks … should i save these?”; state `awaitingConfirmation`<br>2. no model call → saved, says “saved 7 tasks”; state `listening`; model not called | 7 tasks: “Wash dishes”, “Do laundry”, “Take out trash”, “Make beds”, “Mop floors”, “Clean windows”, “Water plants” |
| 74 | After three questions Kitty proposes its best reading | 1. “Add a task for laundry”<br>2. “the usual”<br>3. “you know”<br>4. “just do it”<br>5. “Yes” | 1. model: `clarify` “Do you want to wash it, fold it, or put it away?” → asks one question; state `awaitingClarification`<br>2. model: `clarify` “What do you mean by the usual?” → asks one question; state `awaitingClarification`<br>3. model: `clarify` “Could you say that another way?” → asks one question; state `awaitingClarification`<br>4. model: `clarify` “Is it for today?” → preview; says “should i save it this way, or would you like to change something?”; state `awaitingConfirmation`<br>5. no model call → saved; state `listening`; model not called | 1 task: “laundry the usual you know just do it” |
| 75 | “Actually make the bathroom task high priority” changes only that item | 1. “Clean the bathroom, buy milk, and water the plants”<br>2. “Actually make the bathroom task high priority”<br>3. “Yes” | 1. model: bulk `create_tasks` (3 items) → preview: Clean the bathroom / Buy milk / Water the plants; state `awaitingConfirmation`<br>2. no model call → preview: Clean the bathroom / Buy milk / Water the plants; says “made clean the bathroom high priority”; state `awaitingConfirmation`; model not called<br>3. no model call → saved; state `listening`; model not called | 3 tasks: “Clean the bathroom” (high priority), “Buy milk”, “Water the plants” |

## H. Conversation quality (graded on every case)

Every response Kitty speaks in every case above is graded by `Judge`, and the case fails on any issue:

- one short sentence or two: no more than 32 words
- at most one question per response
- no robotic wording ("Are you done?", "Shall I go ahead and create…", "Please provide…", "required field")
- no repeated question, and no more than three questions in a conversation
- a finished sentence
- plus, from the case checks: wait versus clarify is correct, interruption keeps the pending state,
  bulk saves get one grouped confirmation, no invented metadata, no duplicate objects

## Metrics reported after every run

1. Wait accuracy  2. Clarify precision  3. Clarify recall  4. Task extraction accuracy  5. Task-type accuracy
6. Bulk-split accuracy  7. Duplicate rate  8. Invented-field rate  9. Confirmation-loop rate
10. Clarification-loop rate  11. Save success rate  12. Completion rate  13. Response quality (judge)
