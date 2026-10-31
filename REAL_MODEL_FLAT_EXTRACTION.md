# Flat task extraction: what was built and what was measured

Text, not audio. Real on-device model (iPhone 17 simulator), `Tests/SplitMatrixTests.swift`, 10 runs per utterance, one fresh
`VoiceTurnManager` per run, final speech, nothing saved. Every check is made by the test; the app applies none of them.
Raw reports: `REAL_MODEL_FLAT_RAW_FLAT.md` (flat) and `REAL_MODEL_FLAT_RAW_FULL.md` (full; stopped after 15 of 18 cases, the
12 shared cases and 3 of the brief's examples finished).

## Decision: `.full` stays the default

`PathProfile.flat` is behind the profile flag (set only by tests, like `.minimal`; no screen selects it). The bar was: at least as good
as `.full` on every column and splits more often. Splits more often: yes. At least as good on every column: **no**. So `.flat` was not
made the default and was not removed either.

## Same 12 utterances, `every check passed` out of 10 (stricter "invented" check: no purpose or instructions nobody said)

| case | full | flat |
|---|---|---|
| milk-bread | 0 | 0 |
| pharmacy | 0 | 3 |
| rani | 0 | 1 |
| zepto | 0 | 8 |
| routines | 0 | 0 |
| one-task | 9 | 2 |
| plumber | 7 | 10 |
| dolo | 5 | 2 |
| friends | 1 | 5 |
| playbook | 0 | 0 |
| question | 0 | 10 |
| leak | 10 | 10 |
| **total** | **32/120** | **51/120** |

Split checks on the same cases: flat 121/150 (including the brief's examples) against full 51/100 on the 12 cases before this change.
Median turn 1.5 s on flat against 3.8 s on full. The earlier `.full` baseline, before labels were removed, was 26/120; after, 36/120.

Where flat is worse: `one-task` ("but make it one task": 2 vs 9), `dolo` (2 vs 5), `milk-bread` invented (0, same).

## What the model gets wrong on the flat schema (measured)

- It fills `purpose` with words nobody said ("purchase", "shopping", "routine", "remind"), and `instructions` with a restatement of the
  title ("water plants"). Present in most runs of ordinary requests.
- It drops "every morning" and "tomorrow" often (routines 0/10, `b-recurring` 0/10, `b-tomorrow` 0/10). Swift cannot recover words the
  model did not return, and Swift does not read the transcript for dates or repeats.
- It sometimes files a one-time day under `schedule` ("tomorrow evening") or under `instructions` ("Saturday").
- Two lists in one request: one call per list, but the model often returns only the first task of each (`b-two-lists` 1/10).
- Drug names (Cipcal, Cetaphil) sometimes trip the on-device guardrail: "Response may contain sensitive or unsafe content". The turn
  then says it added nothing and why (`b-pharmacy-list`).

## Changes made after the measurement above, NOT measured on the real model

Scripted tests cover them (`Tests/TaskExtractionTests.swift`, 50 tests); the real model has not been run on this build.

1. A schedule that is a day or a part of the day with no repeat word ("tomorrow evening", "Saturday") is read as the due day, not a repeat.
2. `purpose` and `instructions` are kept only if each of their content words appears in what the user said and they do not merely
   repeat the title (`Provenance`). A paraphrase ("bone health" for "my bones") is therefore dropped. A deviation from the plan, which
   had no per-field check; it is in the trace, not on the card.
3. `@Guide` descriptions were added to the six optional task fields (the brief has none). A deviation from the brief's schema; the
   brief's session instructions are unchanged.
4. `RecurrenceParser`: "Monday to Friday except Wednesday" is read; a trailing "except" with nothing after it is unsupported.
5. Merged answers copy a response-level list name onto the tasks that have none.

## Not run

The flat Cipcal correction replay (a `flat` profile exists in `CorrectionReplayTests`), the flat matrix on the build with changes 1 to 3,
and the rest of the full-path matrix (last 3 brief examples). Skipped at the user's request.

## What the flat path does not support

Playbook creation by voice (the schema has no playbook; 0/10 on both paths), model-written category and priority (title fallback and
none), per-field quotes and the "Quote unverified" flag. Saved-task operations, search and look-ups still run through the existing
router before the extraction call. Edits to a waiting draft use the existing review call, extended with purpose and instructions.
Save-as-playbook exists as an action on an approved list.
