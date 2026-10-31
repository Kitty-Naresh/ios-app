# Cipcal correction replay on the real model

10 runs per profile and mode, the real VoiceTurnManager and DecisionEngine, fresh session per call, no saved tasks. Text replay: speech recognition is not part of it.
Checks are measurements made by the test, not rules of the app.

| profile | mode | runs passed | passed on 1st correction | avg corrections to pass | median s per turn | p90 s | max s | avg tokens written | turns with no finished answer | guard stops | turns with invented metadata | unchanged-looking save prompts | turns rejected, draft kept |
|---|---|---|---|---|---|---|---|---|---|---|---|---|---|
| full-fixed | pinned | 0/10 | 0/10 | 0.0 | 2.7 | 2.8 | 2.9 | 31 | 0 | 0 | 0 | 20 | 0 |
| minimal-M1 | pinned | 0/10 | 0/10 | 0.0 | 1.6 | 1.6 | 1.6 | 33 | 0 | 0 | 0 | 20 | 0 |

## Samples

### full-fixed, pinned: the production path after the schema, context and invalid-output fixes
- run 1: FAIL
  - turn 1: proposal, 2.9 s, finished, ~24 tok; items: d6 Get sip curl | d7 Get Cetaphil body lotion
    said: SIPCAL, you heard that correct earlier. | I have 2 tasks: get sip curl and get cetaphil body lotion. Should I save these?
    prompt sent:
```
Today: Tuesday 2026-10-27
STATE: reviewing a draft of 2 items, version 8, not saved
ITEMS (by ref, in the order the card shows them)
d6. "Get sip curl" | labels sip curl | created in L4 from "Get sip curl"
d7. "Get Cetaphil body lotion" | labels cetaphil, body lotion | created in L4 from "Get Cetaphil body lotion"
RECENT CHANGES (made by the app, newest last): Added get cetaphil body lotion and get sip curl. Removed get a pharmacy list: cetaphil body lotion, cipcal, tedibar soap. (d1, d6, d7)
Reference vocabulary (spellings only, not facts about this request):
Labels: cetaphil, body lotion
USER: "SIPCAL, you heard that correct earlier."
```
    model wrote: {"value": {"reply": "SIPCAL, you heard that correct earlier."}, "type": "answer"}
    check: 0 Cipcal item(s); old misreading back: sip curl
  - turn 2: proposal, 2.7 s, finished, ~35 tok; items: d6 Get sip curl | d7 Get Cetaphil body lotion
    said: That matches what the list already says, so nothing changed. | I have 2 tasks: get sip curl and get cetaphil body lotion. Should I save these?
    prompt sent:
```
Today: Tuesday 2026-10-27
STATE: reviewing a draft of 2 items, version 8, not saved
ITEMS (by ref, in the order the card shows them)
d6. "Get sip curl" | labels sip curl | created in L4 from "Get sip curl"
d7. "Get Cetaphil body lotion" | labels cetaphil, body lotion | created in L4 from "Get Cetaphil body lotion"
RECENT CHANGES (made by the app, newest last): Added get cetaphil body lotion and get sip curl. Removed get a pharmacy list: cetaphil body lotion, cipcal, tedibar soap. (d1, d6, d7)
Reference vocabulary (spellings only, not facts about this request):
Labels: cetaphil, body lotion, cipcal
USER: "It's Cipcal, C-I-P-C-A-L, Get Cipcal, not Ciccal."
```
    model wrote: {"value": {"edits": [{"labels": ["sip curl"], "refs": ["d6"], "clear": []}], "remove": [], "add": []}, "type": "change"}
    check: 0 Cipcal item(s); old misreading back: sip curl
- run 2: FAIL
  - turn 1: proposal, 2.6 s, finished, ~27 tok; items: d6 Get sip curl | d7 Get Cetaphil body lotion
    said: SIPCAL is not the correct spelling for 'Cetaphil'. | I have 2 tasks: get sip curl and get cetaphil body lotion. Should I save these?
    model wrote: {"value": {"reply": "SIPCAL is not the correct spelling for 'Cetaphil'."}, "type": "answer"}
    check: 0 Cipcal item(s); old misreading back: sip curl
  - turn 2: proposal, 2.8 s, finished, ~36 tok; items: d6 Get sip curl
    said: Removed get cetaphil body lotion. Should I save these?
    model wrote: {"type": "change", "value": {"add": [], "edits": [{"labels": ["sip curl"], "refs": ["d6"], "clear": []}], "remove": ["d7"]}}
    check: 0 Cipcal item(s); old misreading back: sip curl; unrelated item gone: Get Cetaphil body lotion
- run 3: FAIL
  - turn 1: proposal, 2.7 s, finished, ~37 tok; items: d6 Get sip curl | d7 Get Cetaphil body lotion
    said: You said 'SIPCAL, you heard that correct earlier.' — I confirm the spelling is correct. | I have 2 tasks: get sip curl and get cetaphil body lotion. Should I save these?
    model wrote: {"value": {"reply": "You said 'SIPCAL, you heard that correct earlier.' — I confirm the spelling is correct."}, "type": "answer"}
    check: 0 Cipcal item(s); old misreading back: sip curl
  - turn 2: proposal, 2.8 s, finished, ~36 tok; items: d6 Get sip curl
    said: Removed get cetaphil body lotion. Should I save these?
    model wrote: {"type": "change", "value": {"add": [], "remove": ["d7"], "edits": [{"labels": ["sip curl"], "refs": ["d6"], "clear": []}]}}
    check: 0 Cipcal item(s); old misreading back: sip curl; unrelated item gone: Get Cetaphil body lotion
- run 4: FAIL
  - turn 1: proposal, 2.7 s, finished, ~38 tok; items: d6 Get sip curl | d7 Get Cetaphil body lotion
    said: You said 'SIPCAL, you heard that correct earlier.' — we confirmed the spelling is correct. | I have 2 tasks: get sip curl and get cetaphil body lotion. Should I save these?
    model wrote: {"value": {"reply": "You said 'SIPCAL, you heard that correct earlier.' — we confirmed the spelling is correct."}, "type": "answer"}
    check: 0 Cipcal item(s); old misreading back: sip curl
  - turn 2: proposal, 2.8 s, finished, ~36 tok; items: d6 Get sip curl
    said: Removed get cetaphil body lotion. Should I save these?
    model wrote: {"type": "change", "value": {"remove": ["d7"], "edits": [{"labels": ["sip curl"], "clear": [], "refs": ["d6"]}], "add": []}}
    check: 0 Cipcal item(s); old misreading back: sip curl; unrelated item gone: Get Cetaphil body lotion
- run 5: FAIL
  - turn 1: proposal, 2.6 s, finished, ~26 tok; items: d6 Get sip curl | d7 Get Cetaphil body lotion
    said: SIPCAL is not a correct spelling for 'Cetaphil'. | I have 2 tasks: get sip curl and get cetaphil body lotion. Should I save these?
    model wrote: {"type": "answer", "value": {"reply": "SIPCAL is not a correct spelling for 'Cetaphil'."}}
    check: 0 Cipcal item(s); old misreading back: sip curl
  - turn 2: proposal, 2.8 s, finished, ~36 tok; items: d6 Get sip curl
    said: Removed get cetaphil body lotion. Should I save these?
    model wrote: {"type": "change", "value": {"edits": [{"refs": ["d6"], "clear": [], "labels": ["sip curl"]}], "add": [], "remove": ["d7"]}}
    check: 0 Cipcal item(s); old misreading back: sip curl; unrelated item gone: Get Cetaphil body lotion
- run 6: FAIL
  - turn 1: proposal, 2.6 s, finished, ~28 tok; items: d6 Get sip curl | d7 Get Cetaphil body lotion
    said: SIPCAL is not a correct spelling; it should be sip curl. | I have 2 tasks: get sip curl and get cetaphil body lotion. Should I save these?
    model wrote: {"value": {"reply": "SIPCAL is not a correct spelling; it should be sip curl."}, "type": "answer"}
    check: 0 Cipcal item(s); old misreading back: sip curl
  - turn 2: proposal, 2.4 s, finished, ~26 tok; items: d6 Get sip curl | d7 Get Cetaphil body lotion
    said: What is the correct spelling for 'Cipcal'? | I have 2 tasks: get sip curl and get cetaphil body lotion. Should I save these?
    model wrote: {"value": {"question": "What is the correct spelling for 'Cipcal'?"}, "type": "clarify"}
    check: 0 Cipcal item(s); old misreading back: sip curl
- run 7: FAIL
  - turn 1: proposal, 2.7 s, finished, ~38 tok; items: d6 Get sip curl | d7 Get Cetaphil body lotion
    said: You said 'SIPCAL, you heard that correct earlier.' This is a correction for 'Get sip curl'. | I have 2 tasks: get sip curl and get cetaphil body lotion. Should I save these?
    model wrote: {"type": "answer", "value": {"reply": "You said 'SIPCAL, you heard that correct earlier.' This is a correction for 'Get sip curl'."}}
    check: 0 Cipcal item(s); old misreading back: sip curl
  - turn 2: proposal, 2.8 s, finished, ~36 tok; items: d6 Get sip curl
    said: Removed get cetaphil body lotion. Should I save these?
    model wrote: {"type": "change", "value": {"add": [], "edits": [{"refs": ["d6"], "clear": [], "labels": ["sip curl"]}], "remove": ["d7"]}}
    check: 0 Cipcal item(s); old misreading back: sip curl; unrelated item gone: Get Cetaphil body lotion
- run 8: FAIL
  - turn 1: proposal, 2.7 s, finished, ~29 tok; items: d6 Get sip curl | d7 Get Cetaphil body lotion
    said: SIPCAL is correct, the item is now titled 'Get Sip Curl'. | I have 2 tasks: get sip curl and get cetaphil body lotion. Should I save these?
    model wrote: {"type": "answer", "value": {"reply": "SIPCAL is correct, the item is now titled 'Get Sip Curl'."}}
    check: 0 Cipcal item(s); old misreading back: sip curl
  - turn 2: proposal, 2.3 s, finished, ~25 tok; items: d6 Get sip curl | d7 Get Cetaphil body lotion
    said: What is the correct spelling of 'Cipcal'? | I have 2 tasks: get sip curl and get cetaphil body lotion. Should I save these?
    model wrote: {"value": {"question": "What is the correct spelling of 'Cipcal'?"}, "type": "clarify"}
    check: 0 Cipcal item(s); old misreading back: sip curl
- run 9: FAIL
  - turn 1: proposal, 2.7 s, finished, ~27 tok; items: d6 Get sip curl | d7 Get Cetaphil body lotion
    said: SIPCAL is correct. The item is now 'Get Sip Curl'. | I have 2 tasks: get sip curl and get cetaphil body lotion. Should I save these?
    model wrote: {"value": {"reply": "SIPCAL is correct. The item is now 'Get Sip Curl'."}, "type": "answer"}
    check: 0 Cipcal item(s); old misreading back: sip curl
  - turn 2: proposal, 2.8 s, finished, ~35 tok; items: d6 Get sip curl | d7 Get Cetaphil body lotion
    said: That matches what the list already says, so nothing changed. | I have 2 tasks: get sip curl and get cetaphil body lotion. Should I save these?
    model wrote: {"type": "change", "value": {"remove": [], "add": [], "edits": [{"clear": [], "refs": ["d6"], "labels": ["sip curl"]}]}}
    check: 0 Cipcal item(s); old misreading back: sip curl
- run 10: FAIL
  - turn 1: proposal, 2.4 s, finished, ~24 tok; items: d6 Get sip curl | d7 Get Cetaphil body lotion
    said: SIPCAL, you heard that correct earlier. | I have 2 tasks: get sip curl and get cetaphil body lotion. Should I save these?
    model wrote: {"value": {"reply": "SIPCAL, you heard that correct earlier."}, "type": "answer"}
    check: 0 Cipcal item(s); old misreading back: sip curl
  - turn 2: proposal, 2.8 s, finished, ~36 tok; items: d6 Get sip curl
    said: Removed get cetaphil body lotion. Should I save these?
    model wrote: {"value": {"add": [], "remove": ["d7"], "edits": [{"clear": [], "refs": ["d6"], "labels": ["sip curl"]}]}, "type": "change"}
    check: 0 Cipcal item(s); old misreading back: sip curl; unrelated item gone: Get Cetaphil body lotion

### minimal-M1, pinned: the minimal path with only the vocabulary the words mention
- run 1: FAIL
  - turn 1: proposal, 1.5 s, finished, ~34 tok; items: d6 Get Cetaphil body lotion | d7 Get Cetaphil body lotion
    said: Updated get cetaphil body lotion. Should I save these?
    prompt sent:
```
ITEMS
d6. "Get sip curl"
d7. "Get Cetaphil body lotion"
Reference vocabulary (spellings only, not facts about this request):
Labels: cetaphil, body lotion
USER: "SIPCAL, you heard that correct earlier."
```
    model wrote: {"type": "change", "value": {"remove": [], "add": [], "rename": [{"ref": "d6", "title": "Get Cetaphil body lotion"}]}}
    check: 0 Cipcal item(s)
  - turn 2: proposal, 1.6 s, finished, ~34 tok; items: d6 Get Cipcal body lotion | d7 Get Cetaphil body lotion
    said: Updated get cipcal body lotion. Should I save these?
    prompt sent:
```
ITEMS
d6. "Get Cetaphil body lotion"
d7. "Get Cetaphil body lotion"
Reference vocabulary (spellings only, not facts about this request):
Labels: cetaphil, body lotion, cipcal
USER: "It's Cipcal, C-I-P-C-A-L, Get Cipcal, not Ciccal."
```
    model wrote: {"type": "change", "value": {"remove": [], "rename": [{"title": "Get Cipcal body lotion", "ref": "d6"}], "add": []}}
    check: unrelated item changed: Get Cetaphil body lotion -> Get Cipcal body lotion
- run 2: FAIL
  - turn 1: proposal, 1.5 s, finished, ~34 tok; items: d6 Get Cetaphil body lotion | d7 Get Cetaphil body lotion
    said: Updated get cetaphil body lotion. Should I save these?
    model wrote: {"type": "change", "value": {"rename": [{"title": "Get Cetaphil body lotion", "ref": "d6"}], "add": [], "remove": []}}
    check: 0 Cipcal item(s)
  - turn 2: proposal, 1.6 s, finished, ~34 tok; items: d6 Get Cipcal body lotion | d7 Get Cetaphil body lotion
    said: Updated get cipcal body lotion. Should I save these?
    model wrote: {"value": {"rename": [{"ref": "d6", "title": "Get Cipcal body lotion"}], "remove": [], "add": []}, "type": "change"}
    check: unrelated item changed: Get Cetaphil body lotion -> Get Cipcal body lotion
- run 3: FAIL
  - turn 1: proposal, 1.5 s, finished, ~32 tok; items: d6 Get Cetaphil curl | d7 Get Cetaphil body lotion
    said: Updated get cetaphil curl. Should I save these?
    model wrote: {"type": "change", "value": {"rename": [{"ref": "d6", "title": "Get Cetaphil curl"}], "add": [], "remove": []}}
    check: 0 Cipcal item(s)
  - turn 2: proposal, 1.5 s, finished, ~30 tok; items: d6 Get Cipcal | d7 Get Cetaphil body lotion
    said: Updated get cipcal. Should I save these?
    model wrote: {"type": "change", "value": {"remove": [], "rename": [{"title": "Get Cipcal", "ref": "d6"}], "add": []}}
    check: unrelated item changed: Get Cetaphil curl -> Get Cipcal
- run 4: FAIL
  - turn 1: proposal, 1.5 s, finished, ~34 tok; items: d6 Get Cetaphil body lotion | d7 Get Cetaphil body lotion
    said: Updated get cetaphil body lotion. Should I save these?
    model wrote: {"value": {"rename": [{"title": "Get Cetaphil body lotion", "ref": "d6"}], "remove": [], "add": []}, "type": "change"}
    check: 0 Cipcal item(s)
  - turn 2: proposal, 1.6 s, finished, ~34 tok; items: d6 Get Cipcal body lotion | d7 Get Cetaphil body lotion
    said: Updated get cipcal body lotion. Should I save these?
    model wrote: {"type": "change", "value": {"remove": [], "add": [], "rename": [{"ref": "d6", "title": "Get Cipcal body lotion"}]}}
    check: unrelated item changed: Get Cetaphil body lotion -> Get Cipcal body lotion
- run 5: FAIL
  - turn 1: proposal, 1.5 s, finished, ~34 tok; items: d6 Get Cetaphil body lotion | d7 Get Cetaphil body lotion
    said: Updated get cetaphil body lotion. Should I save these?
    model wrote: {"type": "change", "value": {"add": [], "remove": [], "rename": [{"title": "Get Cetaphil body lotion", "ref": "d6"}]}}
    check: 0 Cipcal item(s)
  - turn 2: proposal, 1.6 s, finished, ~34 tok; items: d6 Get Cipcal body lotion | d7 Get Cetaphil body lotion
    said: Updated get cipcal body lotion. Should I save these?
    model wrote: {"value": {"rename": [{"ref": "d6", "title": "Get Cipcal body lotion"}], "remove": [], "add": []}, "type": "change"}
    check: unrelated item changed: Get Cetaphil body lotion -> Get Cipcal body lotion
- run 6: FAIL
  - turn 1: proposal, 1.6 s, finished, ~32 tok; items: d6 Get Cetaphil curl | d7 Get Cetaphil body lotion
    said: Updated get cetaphil curl. Should I save these?
    model wrote: {"type": "change", "value": {"remove": [], "add": [], "rename": [{"title": "Get Cetaphil curl", "ref": "d6"}]}}
    check: 0 Cipcal item(s)
  - turn 2: proposal, 1.5 s, finished, ~32 tok; items: d6 Get Cipcal curl | d7 Get Cetaphil body lotion
    said: Updated get cipcal curl. Should I save these?
    model wrote: {"type": "change", "value": {"remove": [], "add": [], "rename": [{"title": "Get Cipcal curl", "ref": "d6"}]}}
    check: unrelated item changed: Get Cetaphil curl -> Get Cipcal curl
- run 7: FAIL
  - turn 1: proposal, 1.5 s, finished, ~34 tok; items: d6 Get Cetaphil body lotion | d7 Get Cetaphil body lotion
    said: Updated get cetaphil body lotion. Should I save these?
    model wrote: {"type": "change", "value": {"add": [], "rename": [{"ref": "d6", "title": "Get Cetaphil body lotion"}], "remove": []}}
    check: 0 Cipcal item(s)
  - turn 2: proposal, 1.6 s, finished, ~34 tok; items: d6 Get Cipcal body lotion | d7 Get Cetaphil body lotion
    said: Updated get cipcal body lotion. Should I save these?
    model wrote: {"type": "change", "value": {"rename": [{"title": "Get Cipcal body lotion", "ref": "d6"}], "add": [], "remove": []}}
    check: unrelated item changed: Get Cetaphil body lotion -> Get Cipcal body lotion
- run 8: FAIL
  - turn 1: proposal, 1.5 s, finished, ~34 tok; items: d6 Get Cetaphil body lotion | d7 Get Cetaphil body lotion
    said: Updated get cetaphil body lotion. Should I save these?
    model wrote: {"type": "change", "value": {"remove": [], "rename": [{"title": "Get Cetaphil body lotion", "ref": "d6"}], "add": []}}
    check: 0 Cipcal item(s)
  - turn 2: proposal, 1.6 s, finished, ~34 tok; items: d6 Get Cipcal body lotion | d7 Get Cetaphil body lotion
    said: Updated get cipcal body lotion. Should I save these?
    model wrote: {"value": {"remove": [], "rename": [{"ref": "d6", "title": "Get Cipcal body lotion"}], "add": []}, "type": "change"}
    check: unrelated item changed: Get Cetaphil body lotion -> Get Cipcal body lotion
- run 9: FAIL
  - turn 1: proposal, 1.6 s, finished, ~32 tok; items: d6 Get Cetaphil curl | d7 Get Cetaphil body lotion
    said: Updated get cetaphil curl. Should I save these?
    model wrote: {"type": "change", "value": {"remove": [], "add": [], "rename": [{"ref": "d6", "title": "Get Cetaphil curl"}]}}
    check: 0 Cipcal item(s)
  - turn 2: proposal, 1.6 s, finished, ~30 tok; items: d6 Get Cipcal | d7 Get Cetaphil body lotion
    said: Updated get cipcal. Should I save these?
    model wrote: {"value": {"add": [], "rename": [{"title": "Get Cipcal", "ref": "d6"}], "remove": []}, "type": "change"}
    check: unrelated item changed: Get Cetaphil curl -> Get Cipcal
- run 10: FAIL
  - turn 1: proposal, 1.5 s, finished, ~34 tok; items: d6 Get Cetaphil body lotion | d7 Get Cetaphil body lotion
    said: Updated get cetaphil body lotion. Should I save these?
    model wrote: {"type": "change", "value": {"remove": [], "add": [], "rename": [{"title": "Get Cetaphil body lotion", "ref": "d6"}]}}
    check: 0 Cipcal item(s)
  - turn 2: proposal, 1.6 s, finished, ~34 tok; items: d6 Get Cipcal body lotion | d7 Get Cetaphil body lotion
    said: Updated get cipcal body lotion. Should I save these?
    model wrote: {"type": "change", "value": {"remove": [], "add": [], "rename": [{"title": "Get Cipcal body lotion", "ref": "d6"}]}}
    check: unrelated item changed: Get Cetaphil body lotion -> Get Cipcal body lotion

