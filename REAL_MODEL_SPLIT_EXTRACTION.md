# One task per requested action: what was measured, and what was kept

**Result: the new instruction wording was measured, did not meet the bar, and was reverted. The production instructions and schema guides are exactly what they were before this pass.** What stays is the measurement harness and a set of scripted tests of the Swift side.

## The principle

The model interprets and splits a request. Swift manages state, basic validation, duplicates, review and saving, and does no semantic splitting (no reading a title for "and"). That part of the code already held and is now covered by tests (`Tests/SplitExtractionTests.swift`, 11 scripted tests). Whether the model splits well is a different question, and it is the one measured here.

## How it was measured

`Tests/SplitMatrixTests.swift` (opt in: `TEST_RUNNER_KITTY_REAL_MODEL=1`). 12 utterances, 10 runs each, one fresh `VoiceTurnManager` per run with the real `DecisionEngine`, final speech, no saved tasks. Text, not audio. The checks are made by the test; the app applies none of them. "all" means every check of the case passed in that run.

Raw reports: `REAL_MODEL_SPLIT_RAW_BEFORE.md`, `REAL_MODEL_SPLIT_RAW_AFTER.md`, `REAL_MODEL_SPLIT_RAW_REVERTED_RERUN.md`.

## What was tried (AFTER)

- Replaced the extraction rule "one item per requested action ... keep related objects under one action" with: one task per requested action or target that can be completed independently, a complete product name kept together, shared context preserved on every task it applies to, routines for requested repetition, no invented steps, combine or split only when asked.
- Removed the "a named list is ONE purchase task" default from the `ItemDraft.title` guide; added "on every item it applies to" to the date, time, time-of-day, assignee and repeat guides.
- One short mention of splitting in the review instructions and in the `ReviewChange` schema text.
- No literal example in any instruction or schema text (examples in schemas come back as tasks).

## Results

Passes out of 10 runs. "split" is the right number of tasks, one per target. Context columns are the checks that a shared assignee, shop, day or time of day is on each task.

| case | said | BEFORE split | AFTER split | BEFORE all | AFTER all |
|---|---|---|---|---|---|
| milk-bread | Buy milk and bread from Blinkit | 0 | 0 | 0 | 0 |
| pharmacy | Get Cetaphil body lotion, Cipcal and Tedibar soap | 0 | **6** | 0 | **6** |
| rani | Ask Rani to clean the kitchen and the bathroom on Saturday | 0 | 0 | 0 | 0 |
| zepto | Order paneer and Amul butter from Zepto tomorrow evening | 0 | 0 | 0 | 0 |
| routines | Water the plants and feed the cat every morning | 4 | **8** | 0 | 0 |
| one-task | ... but make it one task | 1 | 1 | 1 | 1 |
| plumber | Call the plumber | 3 | **0** | 3 | 0 |
| dolo | Remind me to take Dolo 650 after lunch | 5 | **1** | 5 | 1 |
| friends | My friends are visiting ... (3 tasks) | 9 | 8 | 9 | 8 |
| playbook | ordered workflow | 0 | 0 | 0 | 0 |
| question | Remind me | 0 | 0 | 0 | 0 |
| leak | Pick up the dry cleaning | 8 | **0** | 8 | 0 |

| measured | BEFORE | AFTER |
|---|---|---|
| split | 30/100 | 24/100 |
| name kept whole | 29/30 | 26/30 |
| context | 36/100 | 30/100 |
| nothing invented | 71/100 | 70/100 |
| playbook handled | 50/60 | 50/60 |
| every check of the case | 26/120 | 16/120 |
| median / p90 seconds per turn | 7.4 / 50.5 | 13.7 / 91.9 |

## The bar, and the decision

The bar set before the run: keep the new wording only if AFTER is at least as good as BEFORE on every column and the split rate is higher. AFTER is lower on split, name, context and every-check, equal or lower on the rest, and slower. **Reverted.** The wording was not tuned further to chase the numbers.

What the samples show:

- It helped where the model was already close: Tedibar/Cipcal/Cetaphil went from 0 to 6 of 10, and the routine case split from 4 to 8 of 10.
- It hurt single-request cases. "Pick up the dry cleaning" went from one task (8/10) to several copies of the same task, some with invented schedules ("repeats every Sunday and Wednesday"); "Call the plumber" went from 3 to 0. The most likely cause is the "on every item" wording on the `repeating` guide and the "preserve schedule" rule: the model fills `repeating` on items that did not repeat. This is a reading of the samples, not something that was isolated by a separate run.
- Some of the change is noise. A rerun of five cases on the reverted wording (`REAL_MODEL_SPLIT_RAW_REVERTED_RERUN.md`) gave leak 9/10 and plumber 3/10 (close to BEFORE: 8 and 3), but dolo 1/10 where BEFORE had 5/10, and pharmacy 0/10, routines split 4/10 (as BEFORE). So one 10-run sample of a case can move by several runs on its own; the large drops on plumber and leak (3 to 0, 8 to 0) are outside that spread, the dolo drop is not. Latency was also much higher in the AFTER run (13.7 s median against 7.4 s); the reverted rerun was 10 to 14 s, so part of that is the machine, not the wording.
- The Cipcal creation replay was not rerun: with the wording reverted, the production path is the one already recorded in `REAL_MODEL_CORRECTION_REPLAY.md`.

## What the baseline shows that wording does not touch

These were present before this pass and are the larger problems:

- For "Buy milk and bread from Blinkit" the model usually writes the combined task and then also the split ones (or the combined task twice). Swift merges identical payloads, so the result is a combined task plus single ones, or one combined task. Split 0 of 10 before and after.
- The model fills the `repeating` object on every item (frequency "once", weekdays [1]) and rarely writes `dueDate`, `assignee` or `timeOfDay` for "on Saturday", "for Rani", "tomorrow evening": the context checks for those are 0 of 10 in both runs.
- Short or unusual inputs ("Remind me", "Call the plumber") sometimes produce items copied from the instructions ("Respond using the following JSON format", "Household to-do assistant"), or run past the 1,500-token guard. "Remind me" never produced a question (0 of 10 before and after).
- The playbook case produced three tasks, or a playbook beside tasks, never a playbook alone (0 of 10).

None of these is addressed by the safeguards in this app, and no claim is made that the safeguards remove hallucinations.

## What is in the tree

- `Tests/SplitMatrixTests.swift`: the real-model matrix (opt in).
- `Tests/SplitExtractionTests.swift`: 11 scripted tests: two targets stay two drafts with the shop on each; a combined title from the model is not split by Swift; shared assignee, day and time of day survive drafting and saving; two repeating actions are two routines; the same item twice is one draft unless the user asked for it twice; a split and a combine correction are applied in review without a new extraction; no instruction text contains an example that could come back as a task; the instructions stay short.
- Existing suites unchanged and passing: `ReviewBoundaryTests` 16, `InvalidOutputTests` 16.
- Not changed: `splitCompound` in `TaskStore.swift` (legacy, unused), `MinimalPath.swift`.
