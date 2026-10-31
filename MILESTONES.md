# [AI-DRAFT] Kitty milestones: from task app to notes thread

Draft for review. This is a plan, not a record of what is built. Update the status column as milestones land.

**Vision:** you write notes to Kitty like messaging yourself on WhatsApp. The notes stay, always readable and editable. Kitty finds tasks in them and shows a preview you confirm. Each note shows its status. You can ask Kitty questions, and saved tasks can remind you.

| ID | Milestone | What you can do after it | Size | Depends on | Status |
|---|---|---|---|---|---|
| **A1** | Notes persist | Write notes, close the app, reopen: your notes are there. Delete one. | S-M | none | built, build and unit tests pass; hand check on a device not done |
| **A2** | Status and menu on notes | See "Kitty is reading", "tasks ready" and "3 tasks created" on the note. Long-press for Copy, Delete, See details, View tasks. | M | A1 | built, compiles; not hand-checked on a device |
| **A3** | Copy and edit a note | Edit a note in a full-screen editor. Done runs the preview again. | M | A1, A2 | built, compiles; not hand-checked on a device |
| **A3b** | Multiple chats | Home is a chat list. Each row shows the chat's latest note and its time. A "+" starts a new chat, and tapping a row opens it. Titles come from the first line of the first note (no model call) and can be renamed. Deleting a chat asks first, and the tasks already created stay. | M | A3 | built, compiles; not hand-checked on a device |
| **A4** | Edits update earlier tasks | After an edit, an update preview changes or removes the tasks made from that note. It opens as its own session that disappears when you finish. | L | A3 | built, compiles; not hand-checked on a device |
| **A5** | Pending previews survive a restart | A preview you ignored is still there as "Review tasks" after you close the app. | M | A2 | built, compiles; not hand-checked on a device |
| **A6** | Ask Kitty in the thread | Ask "what do I need to buy today?" and get a plain answer, shown lighter than notes and never saved as a note. | M | A1 | built, compiles; not hand-checked on a device |
| **A7** | Reminders | Saved tasks that have a date or time in the note remind you. | M | A2 | built, compiles; not hand-checked on a device |
| **A8** | Polish | Date separators, search, speed on large notes, a notes quality scoreboard. | S-M | A1 | built, compiles; not hand-checked on a device |
| Later | Sync and backup, widgets, sharing, folders, rich text, ticking a note line to finish its task | | | | |

## Rules that apply to every milestone
- **Done means:** unit tests pass, nothing existing regresses, every acceptance item is checked by hand with screenshots, note text never goes to logs or anywhere new, and the report-back is filled in.
- **Nothing is saved as a task without the user's confirmation.** Reminders only fire for confirmed tasks.
- **Notes are the user's own words** and are never changed by extraction.
- **Voice stays as it is** throughout. Dictation into notes already works through the existing screen.
- **A note is what the user sends in a turn that starts while no preview is waiting.** Words said to change a preview, answers to Kitty's clarifying questions, questions about saved tasks, and anything Kitty says are not notes and are not saved.

## Each milestone, in short

**A1: Notes persist.** Done when a note survives force-quit, preview instructions and Kitty's replies are not saved, a corrupt file does not break the rest, and Delete works with confirmation. Foundation for everything else, and it has no AI.

**A2: Status and menu.** Done when the indicator shows Working, Tasks ready, N tasks created, or a problem; it survives a relaunch for created tasks; the old thinking card and "See details" link are gone from the main screen; the long-press menu works; Stop stays reachable. Note-level details are kept for the last 20 notes when "Save task details" is on; task-level details are unchanged. Risk: an indicator stuck on Working. It must clear on its own.

**A3: Copy and edit.** Done when Edit changes the same note in place (never a second bubble), Done runs the normal preview, rows matching tasks already made from this note are left out of it, and Edit is blocked while a preview is open or Kitty is working. Known limit: old tasks from the old wording stay until you delete them.

**A3b: Multiple chats.** Done when notes keep their chat across restarts and the home screen is the chat list. Tasks and reminders stay global; a chat is only a container for notes, and search and Ask Kitty (A6) cover all chats. Empty states: on the very first launch, with no chat yet, the app opens straight into a new empty chat with nothing to set up. If the user later has no chats (for example after deleting the last one), the chat list shows an empty state with one clear "Chat with Kitty" button. An empty chat also has its own empty state (a short line saying what is written here stays here). Data: A1 notes have no `chatID`. Add `chatID` to `Note` (bump `schemaVersion`), and give every existing note a single default chat on first load, so nothing saved is lost or reordered. Not included: moving a note between chats, pinning, archiving.

**A4: Edits update earlier tasks.** Done when an edit opens an update preview that matches tasks to lines, changes or removes them only after you confirm, and keeps everything in its own session. Before starting: fix the failing edit-path test (`testAnEditWithAPartOfTheDayAndASoftTimeframe`). Risk: matching lines to tasks is the hardest part of the whole plan. Measure it on a scoreboard first.

**A5: Pending previews survive.** Done when an ignored preview comes back after a restart, and a "Review tasks" marker shows on the note.

**A6: Ask Kitty.** Done when a question gets a text answer from your notes and tasks, and a note is never mistaken for a question without a way to switch it back. Before starting: the query path scored poorly on our tests, so measure it first.

**A7: Reminders.** Done when a task with a date or time said in its note reminds you at the right time, and nothing else does.

**A8: Polish.** Done when date separators and search work, a 1,000-note thread is fast, and a notes scoreboard (shopping lists, mixed notes, long notes, edited notes) runs on the real model with results recorded.

## Order
A1 -> A2 -> A3, then pause and use it for a while. Then A3b if one thread feels cluttered (the home screen then becomes the chat list), and A4, A5, A6, A7, A8. The pause lets real use tell us whether A3b and A4 are worth their size and where the preview annoys you.

## What was built, and where it differs from the plan (written after implementation)
- **A2:** the status chip and long-press menu are in. "See details" on a note shows the live steps for the latest note, or the details kept with a task made from it. Details are **not** stored separately for the last 20 notes. A "problem" status is not built.
- **A3:** Edit opens a full-screen editor; Done updates the same note and runs the preview again. Rows that match tasks already made from the note are **flagged** ("You already have this saved") by the existing check, not left out.
- **A3b:** the home screen is the chat list. The first launch goes straight into a new empty chat. The quick-note box and mic stay on the home screen and write to the last chat. Notes saved before chats existed are moved into one chat called "Notes".
- **A4:** an edit of a note that already made tasks opens an "Update tasks" sheet with what changed, what is new and what is gone. You tick items there; you cannot talk to it in this version. Tasks whose words are gone are deleted only if ticked.
- **A5:** an unsaved preview is not saved across a restart. Instead the note keeps a "Review tasks" marker, and tapping it reads the note again and brings the preview back.
- **A6:** questions about your notes ("what did I write about ...") are answered from the notes, on the phone, with no model call. Questions about tasks work as before.
- **A7:** local reminders. A task with a day reminds at its time, or at 9:00 on that day. Done tasks, past days and routine copies do not remind. The system asks for permission the first time.
- **A8:** day separators, search across all chats, a lazy thread, "Read more" on very long notes, and a notes scoreboard in `Tests/Scoreboard/notes_v1.json` (12 cases, not yet run).
