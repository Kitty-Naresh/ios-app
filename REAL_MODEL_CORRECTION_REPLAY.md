# Correction replay on the real on-device model

Date of runs: 27 Oct 2026. Device model: Apple Foundation Models on the iPhone 17 simulator.
Harness: `Tests/CorrectionReplayTests.swift`. It drives the real `VoiceTurnManager` and `DecisionEngine`, with a fresh model session per call and no saved tasks. It is a text replay, so speech recognition is not part of it.
Raw reports with every prompt sent and every raw model answer:

- `REAL_MODEL_CORRECTION_REPLAY_RAW_BEFORE.md`: the code as it was before this change.
- `REAL_MODEL_CORRECTION_REPLAY_RAW_AFTER.md`: the final run of all three profiles.
- `REAL_MODEL_CORRECTION_REPLAY_RAW_SWAP.md`: the item-order probe.

## 1. What was replayed

The trace in `Downloads/Untitled (8).txt`, as six chunks of speech (R1 to R6):

1. The user lists a pharmacy list: Cetaphil body lotion, Cipcal, Tedibar soap.
2. They say the list title is not needed, and that Cetaphil and body lotion are one item.
3. They ask for individual tasks.
4. They add a mishearing ("sip curl").
5. They say "SIPCAL, you heard that correct earlier."
6. They correct it: "It's Cipcal, C-I-P-C-A-L, Get Cipcal, not Ciccal."

Two modes, 10 runs each:

- **pinned**: the draft the trace had at turn 7 (`d6 Get Cetaphil body lotion`, `d7 Get sip curl`) is seeded, then R5 and R6 are sent. This isolates single-item correction.
- **free**: R1 to R6 are sent in order from nothing, so creation and every later turn depend on the model's own earlier output.

A run passes when the draft ends with a Cipcal item, no "sip curl" item, no change to the unrelated items, and no invented schedule or label.
All checks are measurements made by the test, not rules in the app.

Profiles:

- **current** (BEFORE only): the production schema and prompts as they were.
- **full-fixed**: the production path after the schema, context and invalid-output fixes in this change.
- **minimal-M0**: the diagnostic path. Titles only, rename/remove/add by item ref, no vocabulary.
- **minimal-M1**: the same path, plus only the vocabulary the user's words mention.

## 2. Results

### BEFORE (the code as it was)

| profile | mode | runs passed | median s per turn | p90 s | max s | avg tokens written | turns with no finished answer | guard stops | invented metadata | save prompts that looked unchanged |
|---|---|---|---|---|---|---|---|---|---|---|
| current | pinned | 0/10 | 12.3 | 44.7 | 50.6 | 532 | 2 | 0 | 0 | 20 |
| current | free | 0/10 | 13.4 | 56.1 | 60.3 | 619 | 10 | 6 | 0 | 51 |

On creation (R1) the old path produced the three items in 1 of 10 free runs. It returned no finished answer in 6 of those 10 first turns.

### AFTER (final run, 10 runs each)

| profile | mode | runs passed | passed on 1st correction | avg corrections to pass | median s per turn | p90 s | max s | avg tokens written | turns with no finished answer | guard stops | invented metadata | save prompts that looked unchanged | turns rejected, draft kept |
|---|---|---|---|---|---|---|---|---|---|---|---|---|---|
| full-fixed | pinned | 0/10 | 0/10 | n/a | 2.8 | 3.2 | 3.3 | 36 | 0 | 0 | 0 | 16 | 4 |
| full-fixed | free | 1/10 | 0/10 | 2.0 | 3.3 | 9.7 | 13.8 | 107 | 0 | 0 | 0 | 53 | 7 |
| minimal-M0 | pinned | 0/10 | 0/10 | n/a | 1.5 | 1.6 | 1.6 | 34 | 0 | 0 | 0 | 20 | 0 |
| minimal-M0 | free | 0/10 | 0/10 | n/a | 1.6 | 2.3 | 2.8 | 45 | 0 | 0 | 0 | 60 | 0 |
| minimal-M1 | pinned | 0/10 | 0/10 | n/a | 1.5 | 1.6 | 1.6 | 34 | 0 | 0 | 0 | 20 | 0 |
| minimal-M1 | free | 0/10 | 0/10 | n/a | 1.7 | 2.4 | 3.5 | 48 | 0 | 0 | 0 | 56 | 4 |

Creation in the free runs (R1 gave three separate items), counted from the raw report:

| profile | three items after R1 |
|---|---|
| current (before) | 1/10 |
| full-fixed | 7/10 |
| minimal-M0 | 10/10 |
| minimal-M1 | 1/10 |

### Item-order probe

The two draft items were swapped (`d6 Get sip curl`, `d7 Get Cetaphil body lotion`), 10 runs each.
full-fixed pinned: 0/10. minimal-M1 pinned: 0/10.
So the failure is not a position bias toward `d6`.

## 3. What the numbers say

**Correction accuracy did not reach the bar.**
The bar was 9 of 10 correct single-item corrections. The best result across all profiles is 1 of 10, and that was full-fixed in the free mode. In the pinned mode it is 0 of 10 for every profile. The change did not make the model able to do the correction.

**Why it fails.**
The raw outputs show three repeating patterns in the pinned mode:

- It answers instead of changing. Turn R5 ("SIPCAL, you heard that correct earlier") is a statement. The model returns an `answer` that repeats the user's words.
- On R6 it either asks a question ("What is the correct spelling of 'Cipcal'?") or returns a `change` that edits the wrong item, for example only the Cetaphil labels.
- When it does rename, it picks the wrong item (the other item) or merges the two titles ("Cipcal Body Lotion").

The model has to decide that "Cipcal" is a respelling of "sip curl", and the two share very little text. That is a hard semantic match for the small model. Swapping the item order did not change the result.
Giving the model clearer variants, a one-item rule and a smaller schema did not fix it.

**What did improve.**

- Latency fell. The median per turn went from 12.3 s to 2.8 s (full-fixed) and 1.5 s (minimal). The p90 went from 44.7 s to 3.2 s and 1.6 s in the pinned mode.
- Tokens written fell from about 530 to about 35 per turn in the pinned mode.
- Turns with no finished answer went from 2 and 10 (pinned and free) to 0.
- Guard stops went from 6 to 0.
- No run invented a schedule, a label or a priority. Invented-metadata turns: 0 in every row.
- Invalid output is now rejected whole. In the full-fixed profile, 4 pinned turns and 7 free turns were rejected with the draft kept. Typical case: the same item both edited and removed. No contradictory operation was applied.
- Creation improved on the full path (1/10 to 7/10 for three separate items). It is perfect on minimal-M0 (10/10) and poor on minimal-M1 (1/10). In M1 the vocabulary line contains "Pharmacy list" from the user's words, and the model then made one combined task.

**What did not improve.**

- "Save prompts that looked unchanged" is still high (16 to 60). This counts turns where the correction failed and the card still asks to save a list that is not corrected. Where the output is invalid, the card now says so and the save prompt is replaced by a recovery. Where the output is valid but wrong (a wrong item renamed, or an answer that only echoes), the app cannot know. Detecting that in Swift would be a silent reinterpretation, which the plan rules out.
- User turns needed: full-fixed free passed once, after 2 correction turns. In every other run the correction was never accomplished within the replay, so the honest figure for "turns needed" is "more than the 2 correction turns offered".

## 4. Recommendation

The user decides. Production is **not** switched.

1. **Do not switch production to the minimal path on this evidence.** It is 2 times faster than full-fixed per turn and creates cleanly in M0, but it corrects no better (0/10) and M1 creation regresses to 1/10.
2. **Keep the full-fixed path for creation.** It is better than the old path on every measurement: latency, finished answers, creation (1/10 to 7/10), and no invented metadata.
3. **Treat correction by spelling as unsolved on this model.** More prompt text did not fix it. Options to decide between, none tried yet because each departs from the plan:
   - Let the user point at the item: an item-level edit (tap the card, say or type the new title). This is the "specific item-level edit path" from the plan. The recovery card already names the items.
   - Let the model name the item by its old wording (for example `"item": "sip curl"`) instead of choosing a ref, and have the app match the string exactly. This changes the schema.
   - Show the original spoken wording of each item ("heard as") in the prompt, so that "Cipcal" can be compared with what was actually said.
   - Have the model rewrite the whole list of titles, then match unchanged titles by exact text. This loses stable IDs.
4. If correction accuracy matters more than speed, run the same replay once on a larger model, to separate "prompt problem" from "model size problem".

## 5. Feature ladder (documentation only, nothing below is built or enabled)

The baseline is not reliable yet, so no rung may be added. The ladder is the order in which features come back once the baseline passes. Each rung is measured with this same replay plus the creation checks. A rung is kept only if it meets its bar. The ladder stops at the first rung that does not.

Baseline bar (must hold before rung 1):

- Single-item correction: at least 9 of 10 pinned runs correct.
- Creation: at least 9 of 10 free runs give the right items.
- Zero changes to unrelated items and zero invented metadata in all runs.
- p90 latency under 5 s per turn on device.
- Invalid output is always rejected with the draft kept.

| rung | feature | what is added | bar to keep it |
|---|---|---|---|
| 1 | Relevant vocabulary | Only labels/spellings that the user's words mention (already built as M1) | Baseline bar still holds. Creation must not drop (M1 shows it can). |
| 2 | Optional day, time, priority, person | One field at a time, only when said | Baseline bar holds. Invented-field turns stay at 0 in every run. |
| 3 | Labels | The labels the user names | Baseline bar holds. No label appears that was not said. |
| 4 | Simplified recurrence | A short fixed set of repeat patterns, not the full schema | Baseline bar holds. Every repeat found must match the words. |
| 5 | Playbooks | Reusable lists | Baseline bar holds. Playbook turns must not change plain creation accuracy. |
| 6 | Retrieval and operations | Questions about saved tasks, complete/reopen/rename/delete | Baseline bar holds. Wrong-task changes: 0 in the replay. |

Rules for the ladder:

- One rung per change. Run the replay (10 runs, pinned and free) before and after.
- Record the result in this file and in `REAL_MODEL_RUNS.md`.
- If a rung falls below its bar, remove it, do not tune around it, and report it.
- No rung is enabled in production without the user's explicit decision.

## 6. How to repeat

```
TEST_RUNNER_KITTY_REAL_MODEL=1 TEST_RUNNER_KITTY_REAL_RUNS=10 \
TEST_RUNNER_KITTY_REPLAY_OUT=/tmp/replay/after.md \
xcodebuild test-without-building -project Kitty.xcodeproj -scheme Kitty \
  -destination 'platform=iOS Simulator,name=iPhone 17' \
  -only-testing:KittyTests/CorrectionReplayTests
```

Optional: `TEST_RUNNER_KITTY_REPLAY_PROFILES` (full-fixed, minimal-M0, minimal-M1), `TEST_RUNNER_KITTY_REPLAY_MODES` (pinned, free), `TEST_RUNNER_KITTY_REPLAY_SWAP=1`.
A full run of all profiles takes about 10 minutes. Do not build while it runs.
