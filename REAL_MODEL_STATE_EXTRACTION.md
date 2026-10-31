# State-based extraction: what to measure (nothing here was measured)

No test was written or run for this change, and the real on-device model was not called. Everything below is a plan for the phone, not a result.
The change is build-verified only (`xcodebuild build-for-testing`).

## What is unmeasured, in three groups

1. **The prompt.** Whether the small model reads `STATE` (scope, draft by ref) beside the new words and returns only the new tasks, and does not repeat `DRAFT` items.
   The three variants to try by hand:
   - A: `FlatExperiments.scopeLine = true` (default): the STATE block and the scope instructions.
   - B: `scopeLine = false`: the STATE block is still sent, without the instruction lines.
   - C: the old behaviour: set `waiting` false in `flatAnswer` (no state at all).
2. **The scope fields.** Whether the model writes a person, day or time once at the top of the answer, leaves it off the tasks, and sets `leavesScope` only
   when it should. A model that fills these for a single task ("Buy milk for Rani") would store a scope that a later unrelated task then takes: watch for it.
3. **The second call.** Whether adding the previous accepted sentence covers a missed word, or only re-extracts the earlier tasks (those are filtered out).

## What to score on the phone

Per dictation: every spoken content word became a task, a field, or a skipped chip; no task got a person, day or time nobody said; tasks that name their own
person kept it; the scope was dropped (WARNING in the trace) when the value was invented; the second call fired only when words were uncovered; the
coverage check raised no alarm on a clean list (false alarms are the likeliest weakness: it has no word list, only what the answer returned).
Read the `TIME` lines for the cost of each call.

## Latency: what is known and what is not

The wait after the last word is the usual pause (4 s, a little more for a long turn), then the intent call (about 0.5 s was seen in an earlier run), then the
extraction (about 0.9 s per call). These are earlier observations, not measured for this change. The hold is unchanged.
- `VoiceTurnManager.speculativeExtraction` (off) starts the extraction beside the intent call and uses it only when the intent is create. It would save roughly
  the intent call's time, and waste one call otherwise. The two calls share one engine, so one failure message can be read as the other's.
- **Preview as you speak** (not built): run the extraction on partial speech and show the tasks as they form. It would remove most of the wait, but costs a
  model call per settled sentence while the recogniser is still running, makes the card change under the user while they talk (a task would appear, then be
  corrected by the next sentence), and would need the same state and scope rules applied to words that may still change. Recommendation: do not build it
  before measuring the speculative flag and a shorter hold on the phone. Not measured.

## Known limits

- A scope the model states for one task is stored and may be applied to the next task that names no person. The instructions say a person for one task goes on that task; this is unmeasured.
- When a long turn is read in several calls, the scope is read from the first answer that states it.
- The coverage check can miss a word that a task title repeats, and can flag a word the answer paraphrased.
- `SpellingHints` only knows words the household has used and brands in `IndianVocabulary`; the older `VocabularyMatcher` and `BrandFixer` (deleted in this working tree, not restored) did the same kind of match.
