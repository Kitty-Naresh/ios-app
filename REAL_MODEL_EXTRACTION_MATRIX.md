# Extraction experiment, real on-device model

Recorded 2026-10-27 on the iPhone 17 simulator. 5 runs per cell and input. Harness: Tests/ExtractionExperimentTests.swift (gated by TEST_RUNNER_KITTY_REAL_MODEL=1).

## Matrix before any production change (cells C0a to C5, P = production schema with the full vocabulary, Pnow = production schema with selective vocabulary)

Checks are measurements made by the test, not rules of the app. Counts are what happened, not a guarantee.

| cell | input | finished | stopped by guard | other | one task | products in title | products only in labels | has repeating | duplicate titles | >3 items | vocabulary words as items | avg items | avg tokens | avg s |
|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|
| C0a | dictated | 5/5 | 0 | 0 | 1 | 4 | 0 | 0 | 0 | 1 | 0 | 2.8 | 86 | 2.2 |
| C0a | colon | 5/5 | 0 | 0 | 0 | 5 | 0 | 0 | 0 | 0 | 0 | 3.0 | 62 | 1.6 |
| C0b | dictated | 5/5 | 0 | 0 | 5 | 0 | 0 | 0 | 0 | 0 | 0 | 1.0 | 39 | 1.4 |
| C0b | colon | 5/5 | 0 | 0 | 4 | 1 | 0 | 0 | 0 | 0 | 0 | 1.4 | 41 | 1.5 |
| C1 | dictated | 5/5 | 0 | 0 | 5 | 1 | 0 | 0 | 0 | 0 | 0 | 1.0 | 53 | 1.9 |
| C1 | colon | 5/5 | 0 | 0 | 3 | 0 | 0 | 0 | 0 | 0 | 0 | 1.4 | 66 | 2.1 |
| C2 | dictated | 5/5 | 0 | 0 | 5 | 0 | 5 | 0 | 0 | 0 | 0 | 1.0 | 61 | 2.1 |
| C2 | colon | 5/5 | 0 | 0 | 5 | 0 | 5 | 0 | 0 | 0 | 0 | 1.0 | 63 | 2.2 |
| C3old | dictated | 5/5 | 0 | 0 | 2 | 3 | 2 | 5 | 0 | 3 | 0 | 2.8 | 237 | 6.0 |
| C3old | colon | 5/5 | 0 | 0 | 1 | 3 | 2 | 5 | 1 | 3 | 0 | 3.0 | 258 | 6.6 |
| C3 | dictated | 5/5 | 0 | 0 | 2 | 1 | 4 | 4 | 2 | 2 | 0 | 2.6 | 191 | 5.4 |
| C3 | colon | 5/5 | 0 | 0 | 1 | 0 | 5 | 4 | 4 | 0 | 0 | 2.4 | 174 | 11.5 |
| C4 | dictated | 5/5 | 0 | 0 | 2 | 3 | 2 | 4 | 0 | 2 | 0 | 2.6 | 161 | 4.6 |
| C4 | colon | 5/5 | 0 | 0 | 4 | 1 | 4 | 1 | 0 | 1 | 0 | 1.6 | 78 | 2.8 |
| C5 | dictated | 5/5 | 0 | 0 | 0 | 5 | 0 | 5 | 0 | 5 | 0 | 4.4 | 248 | 7.4 |
| C5 | colon | 5/5 | 0 | 0 | 0 | 1 | 1 | 5 | 2 | 2 | 3 | 7.8 | 419 | 16.1 |
| P | dictated | 5/5 | 0 | 0 | 1 | 1 | 3 | 2 | 1 | 2 | 3 | 3.8 | 288 | 8.8 |
| P | colon | 3/5 | 2 | 0 | 0 | 1 | 2 | 3 | 2 | 2 | 4 | 11.6 | 765 | 32.2 |
| Pnow | dictated | 5/5 | 0 | 0 | 0 | 4 | 1 | 1 | 1 | 4 | 0 | 4.0 | 226 | 11.8 |
| Pnow | colon | 5/5 | 0 | 0 | 1 | 3 | 2 | 0 | 1 | 3 | 0 | 3.6 | 200 | 11.0 |

First cell (in order) showing leakage, duplicates, more than 3 items or a guard stop: C0a (dictated): 0 run(s) with vocabulary words as items, 0 with duplicate titles, 0 stopped by the guard, 1 with more than 3 items

## Samples

### C0a, dictated: short instructions, no vocabulary, tiny schema (heardAs, title)
- run 1: finished, 1 item(s), ~41 tokens, 2.6 s: Create Pharmacy list
- run 2: finished, 3 item(s), ~101 tokens, 2.1 s: Buy Cetaphil body lotion | Buy Cipcal | Buy Tedibar soap
- run 3: finished, 4 item(s), ~90 tokens, 2.1 s: Pharmacy List | Buy Cetaphil Body Lotion | Buy Cipcal | Buy Tedibar Soap
- run 4: finished, 3 item(s), ~101 tokens, 2.1 s: Get Cetaphil body lotion | Get Cipcal | Get Tedibar soap
- run 5: finished, 3 item(s), ~101 tokens, 2.1 s: Get Cetaphil body lotion | Get Cipcal | Get Tedibar soap

### C0a, colon: short instructions, no vocabulary, tiny schema (heardAs, title)
- run 1: finished, 3 item(s), ~64 tokens, 1.6 s: Purchase Cetaphil body lotion | Purchase Cipcal | Purchase Tedibar soap
- run 2: finished, 3 item(s), ~64 tokens, 1.6 s: Purchase Cetaphil body lotion | Purchase Cipcal | Purchase Tedibar soap
- run 3: finished, 3 item(s), ~64 tokens, 1.6 s: Purchase Cetaphil Body Lotion | Purchase Cipcal | Purchase Tedibar Soap
- run 4: finished, 3 item(s), ~60 tokens, 1.6 s: Buy Cetaphil Body Lotion | Buy Cipcal | Buy Tedibar Soap
- run 5: finished, 3 item(s), ~60 tokens, 1.6 s: Buy Cetaphil body lotion | Buy Cipcal | Buy Tedibar soap

### C0b, dictated: production instructions, tiny schema
- run 1: finished, 1 item(s), ~39 tokens, 1.4 s: Pharmacy List
- run 2: finished, 1 item(s), ~39 tokens, 1.3 s: Pharmacy list
- run 3: finished, 1 item(s), ~39 tokens, 1.3 s: Pharmacy list
- run 4: finished, 1 item(s), ~39 tokens, 1.3 s: Pharmacy List
- run 5: finished, 1 item(s), ~39 tokens, 1.4 s: Pharmacy List

### C0b, colon: production instructions, tiny schema
- run 1: finished, 1 item(s), ~38 tokens, 1.4 s: Pharmacy list
- run 2: finished, 3 item(s), ~57 tokens, 1.8 s: cetaphil body lotion | cipcal | tedibar soap
- run 3: finished, 1 item(s), ~38 tokens, 1.4 s: Pharmacy List
- run 4: finished, 1 item(s), ~38 tokens, 1.4 s: Pharmacy List
- run 5: finished, 1 item(s), ~38 tokens, 1.3 s: Pharmacy list

### C1, dictated: + optional metadata (no labels, no repeating)
- run 1: finished, 1 item(s), ~53 tokens, 1.9 s: Pharmacy List
- run 2: finished, 1 item(s), ~52 tokens, 1.9 s: Pharmacy list
- run 3: finished, 1 item(s), ~52 tokens, 1.9 s: Pharmacy List
- run 4: finished, 1 item(s), ~53 tokens, 1.9 s: Pharmacy list
- run 5: finished, 1 item(s), ~59 tokens, 1.8 s: Pharmacy list - cetaphil body lotion - cipcal - tedibar soap

### C1, colon: + optional metadata (no labels, no repeating)
- run 1: finished, 1 item(s), ~60 tokens, 2.0 s: Pharmacy List
- run 2: finished, 1 item(s), ~60 tokens, 2.0 s: Pharmacy List
- run 3: finished, 1 item(s), ~52 tokens, 1.9 s: Pharmacy list
- run 4: finished, 2 item(s), ~81 tokens, 2.4 s: Pharmacy List | cetaphil body lotion
- run 5: finished, 2 item(s), ~81 tokens, 2.4 s: Pharmacy List | cetaphil body lotion

### C2, dictated: + labels and project (optional)
- run 1: finished, 1 item(s), ~58 tokens, 2.1 s: Pharmacy List [labels of the first: cetaphil, body lotion, cipcal, tedibar, soap]
- run 2: finished, 1 item(s), ~64 tokens, 2.1 s: Pharmacy list [labels of the first: cetaphil, body lotion, cipcal, tedibar soap]
- run 3: finished, 1 item(s), ~65 tokens, 2.1 s: Pharmacy List [labels of the first: cetaphil, body lotion, cipcal, tedibar, soap]
- run 4: finished, 1 item(s), ~64 tokens, 2.1 s: Pharmacy List [labels of the first: cetaphil, body lotion, cipcal, tedibar soap]
- run 5: finished, 1 item(s), ~57 tokens, 2.0 s: Pharmacy list [labels of the first: cetaphil, body lotion, cipcal, tedibar soap]

### C2, colon: + labels and project (optional)
- run 1: finished, 1 item(s), ~63 tokens, 2.1 s: Pharmacy List [labels of the first: cetaphil, body lotion, cipcal, tedibar soap]
- run 2: finished, 1 item(s), ~64 tokens, 2.2 s: Pharmacy list [labels of the first: cetaphil, body lotion, cipcal, tedibar, soap]
- run 3: finished, 1 item(s), ~64 tokens, 2.2 s: Pharmacy List [labels of the first: cetaphil, body lotion, cipcal, tedibar, soap]
- run 4: finished, 1 item(s), ~63 tokens, 2.1 s: Pharmacy List [labels of the first: cetaphil, body lotion, cipcal, tedibar soap]
- run 5: finished, 1 item(s), ~63 tokens, 2.1 s: Pharmacy List [labels of the first: cetaphil, body lotion, cipcal, tedibar soap]

### C3old, dictated: + repeating as it is today (frequency free text, once allowed, six required fields)
- run 1: finished, 4 item(s), ~328 tokens, 8.1 s: Pharmacy List | Cetaphil Body Lotion | Cipcal | Tedibar Soap [labels of the first: cetaphil, cipcal, tedibar]
- run 2: finished, 4 item(s), ~339 tokens, 8.1 s: Pharmacy list | cetaphil body lotion | cipcal | tedibar soap [labels of the first: cetaphil, cipcal, tedibar]
- run 3: finished, 4 item(s), ~323 tokens, 7.7 s: Pharmacy List | Cetaphil Body Lotion | Cipcal | Tedibar Soap [labels of the first: cetaphil, cipcal, tedibar]
- run 4: finished, 1 item(s), ~99 tokens, 3.1 s: Pharmacy list [labels of the first: cetaphil, body lotion, cipcal, tedibar, soap]
- run 5: finished, 1 item(s), ~99 tokens, 3.0 s: Pharmacy List [labels of the first: cetaphil, body lotion, cipcal, tedibar, soap]

### C3old, colon: + repeating as it is today (frequency free text, once allowed, six required fields)
- run 1: finished, 1 item(s), ~97 tokens, 3.0 s: Pharmacy List [labels of the first: cetaphil, body lotion, cipcal, tedibar soap]
- run 2: finished, 4 item(s), ~330 tokens, 8.0 s: Pharmacy List | Cetaphil Body Lotion | Cipcal | Tedibar Soap [labels of the first: cetaphil, body lotion, cipcal, tedibar, soap]
- run 3: finished, 4 item(s), ~332 tokens, 8.2 s: Pharmacy List | Cetaphil Body Lotion | Cipcal | Tedibar Soap [labels of the first: cetaphil, body lotion, cipcal, tedibar, soap]
- run 4: finished, 2 item(s), ~200 tokens, 5.7 s: Pharmacy List | Pharmacy List [labels of the first: cetaphil, body lotion, cipcal, tedibar, soap]
- run 5: finished, 4 item(s), ~332 tokens, 8.0 s: Pharmacy list | cetaphil body lotion | cipcal | tedibar soap [labels of the first: cetaphil, body lotion, cipcal, tedibar, soap]

### C3, dictated: + simplified repeating (no once, frequency enum, optional numbers)
- run 1: finished, 4 item(s), ~311 tokens, 8.3 s: Pharmacy list | Pharmacy list | Pharmacy list | Pharmacy list [labels of the first: cetaphil, body lotion, cipcal, tedibar soap]
- run 2: finished, 4 item(s), ~282 tokens, 7.8 s: Pharmacy list | cetaphil body lotion | cipcal | tedibar soap [labels of the first: cetaphil, body lotion, cipcal, tedibar, soap]
- run 3: finished, 1 item(s), ~85 tokens, 2.9 s: Pharmacy list [labels of the first: cetaphil, body lotion, cipcal, tedibar soap]
- run 4: finished, 3 item(s), ~214 tokens, 5.7 s: Pharmacy List | Pharmacy List | Pharmacy List [labels of the first: cetaphil, cipcal, tedibar]
- run 5: finished, 1 item(s), ~64 tokens, 2.2 s: Pharmacy list [labels of the first: cetaphil, body lotion, cipcal, tedibar soap]

### C3, colon: + simplified repeating (no once, frequency enum, optional numbers)
- run 1: finished, 1 item(s), ~63 tokens, 2.2 s: Pharmacy List [labels of the first: cetaphil, body lotion, cipcal, tedibar soap]
- run 2: finished, 3 item(s), ~231 tokens, 40.1 s: Pharmacy List | Pharmacy List | Pharmacy List [labels of the first: cetaphil, body lotion, cipcal, tedibar soap]
- run 3: finished, 3 item(s), ~221 tokens, 5.5 s: Pharmacy list | Pharmacy list | Pharmacy list [labels of the first: cetaphil, body lotion, cipcal, tedibar, soap]
- run 4: finished, 3 item(s), ~201 tokens, 5.2 s: Pharmacy List | Pharmacy List | Pharmacy List [labels of the first: cetaphil, cipcal, tedibar]
- run 5: finished, 2 item(s), ~158 tokens, 4.7 s: Pharmacy List | Pharmacy List [labels of the first: cetaphil, body lotion, cipcal, tedibar soap]

### C4, dictated: C3 + selective vocabulary (only what the words mention)
- run 1: finished, 1 item(s), ~68 tokens, 2.3 s: Pharmacy list [labels of the first: cetaphil, body lotion, cipcal, tedibar soap]
- run 2: finished, 4 item(s), ~253 tokens, 7.3 s: Pharmacy list | cetaphil body lotion | cipcal | tedibar soap [labels of the first: cetaphil, body lotion, cipcal, tedibar soap]
- run 3: finished, 1 item(s), ~57 tokens, 2.1 s: Pharmacy list [labels of the first: cetaphil, body lotion, cipcal, tedibar soap]
- run 4: finished, 4 item(s), ~222 tokens, 5.5 s: Pharmacy list | cetaphil body lotion | cipcal | tedibar soap [labels of the first: cetaphil, body lotion, cipcal, tedibar soap]
- run 5: finished, 3 item(s), ~208 tokens, 5.9 s: Buy cetaphil body lotion | Buy cipcal | Buy tedibar soap [labels of the first: cetaphil, body lotion]

### C4, colon: C3 + selective vocabulary (only what the words mention)
- run 1: finished, 1 item(s), ~52 tokens, 2.0 s: Pharmacy list [labels of the first: cetaphil, body lotion, cipcal, tedibar soap]
- run 2: finished, 1 item(s), ~52 tokens, 2.0 s: Pharmacy list [labels of the first: cetaphil, body lotion, cipcal, tedibar soap]
- run 3: finished, 4 item(s), ~186 tokens, 5.8 s: Pharmacy list | Cetaphil body lotion | Cipcal | Tedibar soap [labels of the first: cetaphil, body lotion, cipcal, tedibar soap]
- run 4: finished, 1 item(s), ~52 tokens, 2.1 s: Pharmacy list [labels of the first: cetaphil, body lotion, cipcal, tedibar soap]
- run 5: finished, 1 item(s), ~52 tokens, 2.1 s: Pharmacy list [labels of the first: cetaphil, body lotion, cipcal, tedibar soap]

### C5, dictated: C3 + the full vocabulary of the trace
- run 1: finished, 4 item(s), ~234 tokens, 6.9 s: Pharmacy list | cetaphil body lotion | cipcal | tedibar soap [labels of the first: Pharmacy list]
- run 2: finished, 5 item(s), ~266 tokens, 8.1 s: Pharmacy list | cetaphil | body lotion | cipcal | tedibar soap [labels of the first: Pharmacy list]
- run 3: finished, 5 item(s), ~287 tokens, 8.3 s: Pharmacy list | cetaphil | body lotion | cipcal | tedibar soap [labels of the first: Pharmacy list]
- run 4: finished, 4 item(s), ~223 tokens, 6.9 s: Pharmacy List | cetaphil Body Lotion | cipcal | tedibar Soap [labels of the first: Pharmacy list]
- run 5: finished, 4 item(s), ~234 tokens, 6.9 s: Pharmacy list | cetaphil body lotion | cipcal | tedibar soap [labels of the first: Pharmacy list]

### C5, colon: C3 + the full vocabulary of the trace
- run 1: finished, 2 item(s), ~130 tokens, 4.1 s: Pharmacy list | Baby winter wear [labels of the first: Pharmacy list]
- run 2: finished, 2 item(s), ~134 tokens, 4.0 s: Pharmacy list | Clothing [labels of the first: Pharmacy list]
- run 3: finished, 5 item(s), ~358 tokens, 10.3 s: Pharmacy list | Cetaphil, cipcal, tedibar soap | Body lotion, cipcal, tedibar soap | Cetaphil, cipcal, tedibar soap | Body lotion, cipcal, tedibar soap [labels of the first: Pharmacy list]
- run 4: finished, 28 item(s), ~1348 tokens, 58.0 s: Pharmacy list | Grocery order | Grocery order | Grocery order | Grocery order | Grocery order [labels of the first: Pharmacy list]
- run 5: finished, 2 item(s), ~126 tokens, 4.2 s: Pharmacy list | baby winter wear [labels of the first: Pharmacy list]

### P, dictated: the production schema (BulkAgentDecision) with the full vocabulary: the control that reproduced the trace before the changes
- run 1: finished, 4 item(s), ~540 tokens, 16.3 s: Pharmacy list | cetaphil body lotion | cipcal | tedibar soap [labels of the first: Pharmacy list]
- run 2: finished, 10 item(s), ~351 tokens, 10.1 s: Pharmacy list | baby winter wear | loungewear | Adho hostel | Bokeh Camp | Party [labels of the first: cetaphil, body lotion, cipcal, tedibar soap]
- run 3: finished, 2 item(s), ~196 tokens, 6.0 s: Pharmacy list | baby winter wear [labels of the first: cetaphil, body lotion, cipcal, tedibar soap]
- run 4: finished, 2 item(s), ~196 tokens, 6.1 s: Pharmacy list | baby winter wear [labels of the first: cetaphil, body lotion, cipcal, tedibar soap]
- run 5: finished, 1 item(s), ~160 tokens, 5.7 s: Pharmacy list [labels of the first: Pharmacy list]

### P, colon: the production schema (BulkAgentDecision) with the full vocabulary: the control that reproduced the trace before the changes
- run 1: finished, 2 item(s), ~521 tokens, 15.5 s: Buy Cetaphil Body Lotion, Cipcal, Tedibar Soap | Use Blinkit, Swiggy, Zomato, Zepto, Grofers, UPI, Paytm, Household, Roger Kitty, Bucke Cab, Accommodation, IKEA, baby winter wear, loungewear, Adho hostel, Bokeh Camp, Party, Friends, Pharmacy list, cetaphil, body lotion, cipcal, tedibar soap [labels of the first: Pharmacy list]
- run 2: finished, 3 item(s), ~147 tokens, 5.0 s: Pharmacy list | Household | Accommodation [labels of the first: cetaphil, body lotion, cipcal, tedibar soap]
- run 3: finished, 2 item(s), ~153 tokens, 5.2 s: Pharmacy list | Roger Kitty [labels of the first: cetaphil, body lotion, cipcal, tedibar soap]
- run 4: stopped by the output guard, 27 item(s), ~1502 tokens, 58.9 s: Pharmacy list | Baby winter wear | Adho hostel | Bokeh Camp | Party | Friends [labels of the first: Pharmacy list]
- run 5: stopped by the output guard, 24 item(s), ~1502 tokens, 76.4 s: Pharmacy list | Clothing | Shopping | Accommodation | Househelp | Househelp [labels of the first: Pharmacy list]

### Pnow, dictated: the production schema with the selective vocabulary the app now sends
- run 1: finished, 5 item(s), ~336 tokens, 16.7 s: Pharmacy list | Pharmacy list | Pharmacy list | Pharmacy list | Pharmacy list [labels of the first: cetaphil, body lotion, cipcal, tedibar soap]
- run 2: finished, 3 item(s), ~253 tokens, 13.1 s: Buy cetaphil body lotion | Buy cipcal | Buy tedibar soap [labels of the first: cetaphil, body lotion]
- run 3: finished, 4 item(s), ~151 tokens, 8.7 s: Pharmacy list | cetaphil body lotion | cipcal | tedibar soap [labels of the first: cetaphil, body lotion, cipcal, tedibar soap]
- run 4: finished, 4 item(s), ~202 tokens, 10.4 s: Pharmacy list | cetaphil body lotion | cipcal | tedibar soap [labels of the first: cetaphil, body lotion, cipcal, tedibar soap]
- run 5: finished, 4 item(s), ~192 tokens, 10.3 s: Pharmacy list | cetaphil body lotion | cipcal | tedibar soap [labels of the first: cetaphil, body lotion, cipcal, tedibar soap]

### Pnow, colon: the production schema with the selective vocabulary the app now sends
- run 1: finished, 4 item(s), ~194 tokens, 10.6 s: Pharmacy list | cetaphil body lotion | cipcal | tedibar soap [labels of the first: cetaphil, body lotion, cipcal, tedibar soap]
- run 2: finished, 2 item(s), ~112 tokens, 7.2 s: Pharmacy list | cetaphil body lotion [labels of the first: cetaphil, body lotion, cipcal, tedibar soap]
- run 3: finished, 1 item(s), ~292 tokens, 15.0 s: Pharmacy list [labels of the first: cetaphil, body lotion, cipcal, tedibar soap]
- run 4: finished, 4 item(s), ~171 tokens, 9.6 s: Pharmacy list | cetaphil body lotion | cipcal | tedibar soap [labels of the first: cetaphil, body lotion, cipcal, tedibar soap]
- run 5: finished, 7 item(s), ~232 tokens, 12.5 s: Pharmacy list | cetaphil body lotion | body lotion | body lotion | cetaphil | cipcal [labels of the first: cetaphil, body lotion, cipcal, tedibar soap]


## Production schema after the kept changes (selective vocabulary + one-purchase-task rule; recurrence unchanged)


| cell | input | finished | stopped by guard | other | one task | products in title | products only in labels | has repeating | duplicate titles | >3 items | vocabulary words as items | avg items | avg tokens | avg s |
|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|
| Pnow | dictated | 4/5 | 1 | 0 | 1 | 4 | 0 | 5 | 1 | 2 | 0 | 6.6 | 478 | 17.4 |
| Pnow | colon | 5/5 | 0 | 0 | 2 | 5 | 0 | 5 | 1 | 3 | 0 | 3.0 | 235 | 7.7 |

First cell (in order) showing leakage, duplicates, more than 3 items or a guard stop: Pnow (dictated): 0 run(s) with vocabulary words as items, 1 with duplicate titles, 1 stopped by the guard, 2 with more than 3 items

## Samples

### Pnow, dictated: the production schema with the selective vocabulary the app now sends
- run 1: finished, 3 item(s), ~212 tokens, 7.8 s: get cetaphil body lotion | get cipcal | get tedibar soap [labels of the first: cetaphil, body lotion] [first repeating: once: once]
- run 2: finished, 1 item(s), ~108 tokens, 4.2 s: get cetaphil body lotion, cipcal, tedibar soap [labels of the first: Pharmacy list] [first repeating: once: once]
- run 3: finished, 3 item(s), ~212 tokens, 7.1 s: get cetaphil body lotion | get cipcal | get tedibar soap [labels of the first: cetaphil, body lotion] [first repeating: once: once]
- run 4: stopped by the output guard, 21 item(s), ~1502 tokens, 56.7 s: get cetaphil body lotion cipcal tedibar soap | get cetaphil body lotion | get cipcal | get tedibar soap | get cetaphil body lotion cipcal tedibar soap | get cetaphil body lotion [labels of the first: Pharmacy list] [first repeating: once: once] [ended: runaway("it wrote more than about 1,500 tokens")]
- run 5: finished, 5 item(s), ~357 tokens, 11.4 s: get cetaphil body lotion, cipcal, tedibar soap | get cetaphil body lotion | get cipcal | get tedibar soap | create Pharmacy list [labels of the first: Pharmacy list] [first repeating: once: once]

### Pnow, colon: the production schema with the selective vocabulary the app now sends
- run 1: finished, 4 item(s), ~290 tokens, 9.2 s: get cetaphil body lotion, cipcal, tedibar soap | get cetaphil body lotion | get cipcal | get tedibar soap [labels of the first: Pharmacy list] [first repeating: once: once]
- run 2: finished, 1 item(s), ~108 tokens, 4.3 s: get cetaphil body lotion, cipcal, tedibar soap [labels of the first: Pharmacy list] [first repeating: once: today]
- run 3: finished, 5 item(s), ~361 tokens, 11.2 s: buy cetaphil body lotion, cipcal, tedibar soap | buy cetaphil body lotion | buy cetaphil body lotion | buy cipcal | buy tedibar soap [labels of the first: Pharmacy list] [first repeating: once: once]
- run 4: finished, 4 item(s), ~313 tokens, 9.5 s: buy cetaphil body lotion, buy cipcal, buy tedibar soap | buy body lotion | buy cipcal | buy tedibar soap [labels of the first: Pharmacy list] [first repeating: once: once]
- run 5: finished, 1 item(s), ~107 tokens, 4.2 s: buy cetaphil body lotion, cipcal, tedibar soap [labels of the first: Pharmacy list] [first repeating: once: once]


## Tried and not kept: simplified recurrence (no once, enum frequency, optional numbers)

Production schema, selective vocabulary, simplified recurrence only:

| cell | input | finished | stopped by guard | other | one task | products in title | products only in labels | has repeating | duplicate titles | >3 items | vocabulary words as items | avg items | avg tokens | avg s |
|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|
| Pnow | dictated | 4/5 | 0 | 1 | 0 | 3 | 1 | 3 | 3 | 3 | 0 | 7.0 | 452 | 29.0 |
| Pnow | colon | 5/5 | 0 | 0 | 1 | 3 | 2 | 3 | 1 | 1 | 0 | 3.0 | 185 | 11.4 |

Same plus the purchase-task rule:

| cell | input | finished | stopped by guard | other | one task | products in title | products only in labels | has repeating | duplicate titles | >3 items | vocabulary words as items | avg items | avg tokens | avg s |
|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|
| Pnow | dictated | 4/5 | 0 | 1 | 0 | 4 | 0 | 5 | 2 | 3 | 0 | 9.4 | 616 | 23.7 |
| Pnow | colon | 3/5 | 2 | 0 | 0 | 3 | 0 | 5 | 2 | 4 | 0 | 11.0 | 740 | 27.0 |
