# Real on-device model: long and noisy cases (K)

**Not run on the real model yet.** On this Mac the simulator reports the on-device model as `unavailable(modelNotReady)`
(checked three times over several minutes, 22 Oct 2026), so there are no real-model numbers for the K cases. Everything in
`EVALS.md` for K was measured with a scripted model, which shows what Swift does with a given model answer, not what Apple's model
answers. Treat the K percentages as a test of the rules, not of the model.

An earlier attempt before the availability check came back as "0 of 460 tasks found, reply 5/5" for every case. That was the
unavailable model, not a result, and is not reported. The test now refuses to run (and says why) when the model is not available.

What is still unverified until it runs on a phone or a simulator with the model downloaded:

- whether the model answers the digest prompt (one line per action, the shared context first) with one task per line
- how often it says `wait` on a long finished turn (the rules answer when it does, so nothing is lost)
- whether it copies the day or the person into tasks that did not say it (Swift removes those, `BulkValidator`)
- how many of the 1 to 3 model calls a long turn really uses

To run it (writes `/tmp/kitty-real-model-k.md`; 5 runs per case, rule fallback off, `KITTY_REAL_RUNS` changes the count):

```
TEST_RUNNER_KITTY_REAL_MODEL=1 xcodebuild test -project Kitty.xcodeproj -scheme Kitty \
  -destination 'platform=iOS Simulator,name=iPhone 17' -only-testing:KittyTests/RealModelKTests
```

Then paste its summary table and raw output here.

---

# Real on-device model runs (messy-speech cases)

Run once on the iPhone 17 simulator, Apple's on-device model, 5 runs per case, rule fallback off. The cleaned sentence is what the model saw ("sees"). The "x N" lines are what came back. A temporary probe test produced this and was removed.

## Reading it

- Title wording varies run to run ("Clean bathroom" vs "Clean the bathroom"). That is the model, not the cleaner, and the action is right.
- The cleaner's output was right in every run (sees = the intended sentence).
- The main flakiness is the model answering **wait** on a finished sentence, mostly after a repair, where the cleaned text is short ("Buy bread", "wash the car", "Remind me to pay the electricity bill").
  - When the model picks `create_task` but sets wait=true with an empty title, Kitty now asks it once more, then falls back to the rule planner (new in this change, `model-single-retry` / `wait-overridden-create`).
  - When the model picks action `wait`, Kitty still honours it. After the long silence the existing `wait-overridden` path answers, so nothing is lost, only delayed.
- "Wait for the plumber" is a task, but the model says wait 5/5. The local gate does not hold it; the long-silence path answers.
- Lone "Clean", "Clean the" and "Add a task to…" are still held by the gate (no model call).

## Raw report

```

PROBE real-model messy cases, 5 runs each
#76 0/5 “Um, add a task to clean the bathroom”
      x3 Clean bathroom   [route=model-single
      x1 Clean bathroom   [route=model-single-retry
      x1 Clean bathroom   [route=model-single
#77 0/5 “Add a task uh to clean the bathroom”
      x1 Clean bathroom   [route=model-single
      x1 Clean bathroom   [route=model-single
      x1 Clean bathroom   [route=model-single
      x1 Clean bathroom   [route=model-single
      x1 Clean bathroom   [route=model-single
#79 0/5 “Er, so I need to, like, call the plumber”
      x4 WAIT   [route=model-single
      x1 REPLY: You have no open tasks.   [route=model-single
#81 1/5 “Basically, clean the garage”
      x1 Clean garage   [route=model-single
      x1 Clean garage   [route=model-single
      x1 Clean the garage   [route=model-single
      x1 Clean garage   [route=model-single
      x1 Clean garage   [route=model-single
#82 0/5 “Add a task to to clean the bathroom”
      x4 Clean bathroom   [route=model-single
      x1 Clean bathroom   [route=model-single
#83 0/5 “Clean the clean the bathroom”
      x3 Clean bathroom   [route=model-single
      x1 Clean bathroom   [route=model-single
      x1 Clean bathroom   [route=model-single
#84 0/5 “Buy buy milk and bread”
      x2 Buy milk | Buy bread   [route=model-single-retry
      x1 Buy milk | Buy bread   [route=model-single-retry
      x1 Buy milk   [route=model-single
      x1 Buy milk | Buy bread   [route=model-single-retry
#85 0/5 “Call the the plumber about the leaking tap”
      x4 Call the plumber   [route=model-single
      x1 Call the plumber   [route=model-single
#86 2/5 “Clean the... no wait, wash the car”
      x3 WAIT   [route=model-single
      x1 Wash the car   [route=model-single-retry
      x1 Wash the car   [route=model-single
#88 1/5 “Buy milk, I mean bread”
      x4 WAIT   [route=model-single
      x1 Buy bread   [route=model-single-retry
#89 2/5 “Call mom tomorrow, no wait, Friday”
      x2 WAIT   [route=model-single
      x1 Call mom   [route=model-single-retry
      x1 REPLY: You have no open tasks.   [route=model-single
      x1 Call mom   [route=model-single-retry
#90 0/5 “Buy milk, scratch that, call the plumber”
      x3 WAIT   [route=model-single
      x1 REPLY: You have no open tasks.   [route=model-single
      x1 ASK: Is this for a specific location—like the garage or backyard?   [route=model-single
#91 0/5 “Remind me to pay rent, sorry, pay the electricity bill”
      x5 WAIT   [route=model-single
#92 3/5 “Clean the bathroom or rather the kitchen”
      x1 Clean the kitchen   [route=model-single
      x1 Clean the kitchen   [route=model-single
      x1 Clean the kitchen   [route=model-single
      x1 Clean kitchen   [route=model-single
      x1 Clean kitchen   [route=model-single
#93 5/5 “Water the plants every Monday, no wait, every Tuesday”
#102 0/5 “Say sorry to mom”
      x3 WAIT   [route=model-single
      x2 ASK: What would you like the task to be?   [route=model-single
#103 0/5 “Wait for the plumber”
      x5 WAIT   [route=model-single
#104 0/5 “I would like to buy milk”
      x2 WAIT   [route=model-single
      x1 ASK: What type of milk are you looking for—whole milk, powdered, or organic?   [route=model-single
      x1 ASK: Is this for yourself or someone else?   [route=model-single
      x1 ASK: Is this for personal use or for the household?   [route=model-single
lone “Clean” → hold("action without an object")
lone “Clean the” → hold("ends with “the”")
lone “Add a task to…” → hold("trailing off")
SUMMARY: 1 stable-correct, 5 flaky, 12 never-correct of 18
```
