# One task per requested action: real-model matrix (flat path)

10 runs per utterance. One fresh turn manager per run, the real FlatExtractionEngine, final speech, no saved tasks. Text, not audio.
Every check is a measurement made by the test; the app applies none of them.

| case | said | measured | all | median s | p90 s |
|---|---|---|---|---|---|
| milk-bread | Buy milk and bread from Blinkit | split: one task for milk, one for bread 10/10; context: Blinkit on each 10/10; invented: nothing added, no metadata 0/10; playbook: no playbook 10/10; **all 0/10** | 1.6 | 2.0 |
| pharmacy | Get Cetaphil body lotion, Cipcal and Tedibar soap | split: one task each for Cetaphil, Cipcal, Tedibar 5/10; name: "Cetaphil body lotion" kept together 10/10; invented: nothing added, no metadata 8/10; playbook: no playbook 10/10; **all 3/10** | 1.5 | 1.8 |
| rani | Ask Rani to clean the kitchen and the bathroom on Saturday | split: one task for the kitchen, one for the bathroom 6/10; context: Rani on each 9/10; context: Saturday on each 1/10; invented: nothing added 1/10; **all 1/10** | 1.9 | 1.9 |
| zepto | Order paneer and Amul butter from Zepto tomorrow evening | split: one task for paneer, one for Amul butter 10/10; name: "Amul butter" kept together 10/10; context: Zepto on each 10/10; context: tomorrow on each 10/10; context: evening on each 10/10; invented: nothing added 8/10; **all 8/10** | 1.6 | 1.8 |
| routines | Water the plants and feed the cat every morning | split: one routine for the plants, one for the cat 10/10; context: each repeats 0/10; context: morning on each 0/10; invented: nothing added 0/10; **all 0/10** | 1.5 | 1.8 |
| one-task | Buy milk and bread from Blinkit, but make it one task | split: one task holding both 9/10; context: Blinkit kept 10/10; invented: no metadata 2/10; **all 2/10** | 1.4 | 1.4 |
| plumber | Call the plumber | split: exactly one task 10/10; invented: no steps added, no metadata 10/10; playbook: no playbook 10/10; **all 10/10** | 1.1 | 1.1 |
| dolo | Remind me to take Dolo 650 after lunch | split: exactly one task 10/10; name: "Dolo 650" kept together 10/10; invented: no steps added, not a routine 2/10; playbook: no playbook 10/10; **all 2/10** | 1.5 | 1.5 |
| friends | My friends are visiting, I need to prepare the room, order food from Blinkit, book a cab | split: one task each for the room, the food, the cab 9/10; context: Blinkit on the food task 9/10; invented: nothing added, no metadata 5/10; playbook: no playbook 10/10; **all 5/10** | 1.8 | 2.5 |
| playbook | Teach me a playbook for hosting guests: first clean the room, then order food, then book a cab | playbook: a playbook with three ordered steps 0/10; **all 0/10** | 1.9 | 2.0 |
| question | Remind me | question: one question, nothing made 10/10; **all 10/10** | 1.1 | 1.1 |
| leak | Pick up the dry cleaning | split: exactly one task 10/10; invented: nothing from other requests (milk, bread, Blinkit, Zepto) 10/10; **all 10/10** | 1.1 | 1.1 |
| b-pharmacy-list | Pharmacy list: buy Cetaphil body lotion, Teddybar soap, and Cipcal tablets. | split: one task each for Cetaphil, Teddybar, Cipcal 1/10; list: the list is Pharmacy, not a task, on each item 1/10; invented: no day, time, person, repeat 9/10; **all 0/10** | 3.3 | 3.3 |
| b-recurring | Every morning, have the househelp water the balcony plants. | split: one task, not copies for each day 10/10; context: a morning routine Swift can run 0/10; context: the househelp is the assignee 9/10; invented: nothing added 6/10; **all 0/10** | 1.4 | 1.5 |
| b-purpose | Buy Cipcal for calcium deficiency. Get 500 mg, one strip. | split: exactly one task 10/10; fields: the purpose is the reason 7/10; fields: the dosage is the instructions 6/10; invented: no system notes, not a routine, no metadata 10/10; **all 3/10** | 1.7 | 1.7 |
| b-clarify | Buy Cipcal. | question: the task is shown beside one question 10/10; invented: nothing added, no metadata 10/10; **all 10/10** | 1.2 | 1.2 |
| b-tomorrow | Buy milk tomorrow. | split: exactly one task 10/10; context: tomorrow, worked out by Swift 0/10; question: no question asked, only the save prompt 10/10; invented: nothing added 10/10; **all 0/10** | 1.2 | 1.2 |
| b-two-lists | Pharmacy list: Cetaphil, Teddybar, Cipcal. Grocery list: milk, bread, eggs. | split: six tasks, one each 1/10; list: three on Pharmacy, three on Grocery 1/10; invented: no day, time, person, repeat 10/10; **all 1/10** | 2.8 | 2.8 |

## By what was measured

| measured | passed | of |
|---|---|---|
| split | 121 | 150 |
| name | 30 | 30 |
| context | 78 | 130 |
| list | 2 | 20 |
| fields | 13 | 20 |
| invented | 101 | 160 |
| playbook | 50 | 60 |
| question | 30 | 30 |
| every check of the case | 65 | 180 |

Median 1.5 s, p90 2.5 s per turn.

## Samples

### milk-bread: "Buy milk and bread from Blinkit"
- run 1: FAIL: nothing added, no metadata (proposal, 2.5 s) Buy milk [purpose: purchase] [instructions: from Blinkit] | Buy bread [purpose: purchase] [instructions: from Blinkit]
    model wrote: {"tasks": [{"title": "Buy milk", "purpose": "purchase", "instructions": "from Blinkit"}, {"instructions": "from Blinkit", "title": "Buy bread", "purpose": "purchase"}], "outcome": "create"}
- run 2: FAIL: nothing added, no metadata (proposal, 1.6 s) Buy milk from Blinkit [purpose: shopping] | Buy bread from Blinkit [purpose: shopping]
    model wrote: {"tasks": [{"purpose": "shopping", "title": "Buy milk from Blinkit"}, {"purpose": "shopping", "title": "Buy bread from Blinkit"}], "outcome": "create"}
- run 3: FAIL: nothing added, no metadata (proposal, 1.7 s) Buy milk from Blinkit [instructions: Purchase milk from Blinkit.] | Buy bread from Blinkit [instructions: Purchase bread from Blinkit.]
    model wrote: {"tasks": [{"instructions": "Purchase milk from Blinkit.", "title": "Buy milk from Blinkit"}, {"title": "Buy bread from Blinkit", "instructions": "Purchase bread from Blinkit."}], "outcome": "create"}
- run 4: FAIL: nothing added, no metadata (proposal, 1.6 s) Buy milk from Blinkit [purpose: purchase] | Buy bread from Blinkit [purpose: purchase]
    model wrote: {"tasks": [{"title": "Buy milk from Blinkit", "purpose": "purchase"}, {"purpose": "purchase", "title": "Buy bread from Blinkit"}], "outcome": "create"}
- run 5: FAIL: nothing added, no metadata (proposal, 1.6 s) Buy milk from Blinkit [purpose: purchase] | Buy bread from Blinkit [purpose: purchase]
    model wrote: {"tasks": [{"purpose": "purchase", "title": "Buy milk from Blinkit"}, {"purpose": "purchase", "title": "Buy bread from Blinkit"}], "outcome": "create"}
- run 6: FAIL: nothing added, no metadata (proposal, 2.0 s) Buy milk from Blinkit [purpose: Purchase] [instructions: Purchase milk from Blinkit] | Buy bread from Blinkit [purpose: Purchase] [instructions: Purchase bread from Blinkit]
    model wrote: {"outcome": "create", "tasks": [{"instructions": "Purchase milk from Blinkit", "title": "Buy milk from Blinkit", "purpose": "Purchase"}, {"purpose": "Purchase", "title": "Buy bread from Blinkit", "instructions": "Purchase bread from Blinkit"}]}
- run 7: FAIL: nothing added, no metadata (proposal, 1.9 s) Buy milk from Blinkit [purpose: purchase] [instructions: from Blinkit] | Buy bread from Blinkit [purpose: purchase] [instructions: from Blinkit]
    model wrote: {"outcome": "create", "tasks": [{"title": "Buy milk from Blinkit", "purpose": "purchase", "instructions": "from Blinkit"}, {"instructions": "from Blinkit", "purpose": "purchase", "title": "Buy bread from Blinkit"}]}
- run 8: FAIL: nothing added, no metadata (proposal, 1.6 s) Buy milk from Blinkit [purpose: purchase] | Buy bread from Blinkit [purpose: purchase]
    model wrote: {"outcome": "create", "tasks": [{"purpose": "purchase", "title": "Buy milk from Blinkit"}, {"title": "Buy bread from Blinkit", "purpose": "purchase"}]}
- run 9: FAIL: nothing added, no metadata (proposal, 1.6 s) Buy milk from Blinkit [purpose: purchase] | Buy bread from Blinkit [purpose: purchase]
    model wrote: {"tasks": [{"purpose": "purchase", "title": "Buy milk from Blinkit"}, {"purpose": "purchase", "title": "Buy bread from Blinkit"}], "outcome": "create"}
- run 10: FAIL: nothing added, no metadata (proposal, 1.6 s) Buy milk from Blinkit [purpose: shopping] | Buy bread from Blinkit [purpose: shopping]
    model wrote: {"outcome": "create", "tasks": [{"title": "Buy milk from Blinkit", "purpose": "shopping"}, {"purpose": "shopping", "title": "Buy bread from Blinkit"}]}

### pharmacy: "Get Cetaphil body lotion, Cipcal and Tedibar soap"
- run 1: FAIL: nothing added, no metadata (proposal, 1.8 s) Get Cetaphil body lotion [instructions: request] | Get Cipcal [instructions: request] | Get Tedibar soap [instructions: request]
    model wrote: {"tasks": [{"instructions": "request", "title": "Get Cetaphil body lotion"}, {"title": "Get Cipcal", "instructions": "request"}, {"title": "Get Tedibar soap", "instructions": "request"}], "outcome": "create"}
- run 2: ok (proposal, 1.5 s) Get Cetaphil body lotion | Get Cipcal | Get Tedibar soap
- run 3: FAIL: one task each for Cetaphil, Cipcal, Tedibar (proposal, 1.2 s) Get Cetaphil body lotion
    model wrote: {"tasks": [{"title": "Get Cetaphil body lotion"}], "outcome": "create"}
- run 4: ok (proposal, 1.5 s) Get Cetaphil body lotion | Get Cipcal | Get Tedibar soap
- run 5: FAIL: one task each for Cetaphil, Cipcal, Tedibar (proposal, 1.3 s) Get Cetaphil body lotion [list: shopping]
    model wrote: {"tasks": [{"title": "Get Cetaphil body lotion"}], "listName": "shopping", "outcome": "create"}
- run 6: FAIL: one task each for Cetaphil, Cipcal, Tedibar (proposal, 1.2 s) Get Cetaphil body lotion
    model wrote: {"tasks": [{"title": "Get Cetaphil body lotion"}], "outcome": "create"}
- run 7: FAIL: one task each for Cetaphil, Cipcal, Tedibar (proposal, 1.2 s) Get Cetaphil body lotion
    model wrote: {"outcome": "create", "tasks": [{"title": "Get Cetaphil body lotion"}]}
- run 8: FAIL: nothing added, no metadata (proposal, 1.9 s) Get Cetaphil body lotion [purpose: obtain product] | Get Cipcal [purpose: obtain product] | Get Tedibar soap [purpose: obtain product]
    model wrote: {"tasks": [{"purpose": "obtain product", "title": "Get Cetaphil body lotion"}, {"purpose": "obtain product", "title": "Get Cipcal"}, {"purpose": "obtain product", "title": "Get Tedibar soap"}], "outcome": "create"}
- run 9: FAIL: one task each for Cetaphil, Cipcal, Tedibar (proposal, 1.2 s) Get Cetaphil body lotion
    model wrote: {"outcome": "create", "tasks": [{"title": "Get Cetaphil body lotion"}]}
- run 10: ok (proposal, 1.5 s) Get Cetaphil body lotion | Get Cipcal | Get Tedibar soap

### rani: "Ask Rani to clean the kitchen and the bathroom on Saturday"
- run 1: FAIL: one task for the kitchen, one for the bathroom; Saturday on each; nothing added (proposal, 1.4 s) clean the kitchen [for Rani] [purpose: clean]
    model wrote: {"tasks": [{"assignee": "Rani", "purpose": "clean", "title": "clean the kitchen"}], "outcome": "create"}
- run 2: FAIL: Saturday on each; nothing added (proposal, 1.9 s) Clean the kitchen [for Rani] [purpose: clean] [instructions: Clean the kitchen] | Clean the bathroom [for Rani] [purpose: clean] [instructions: Clean the bathroom]
    model wrote: {"tasks": [{"assignee": "Rani", "title": "Clean the kitchen", "instructions": "Clean the kitchen", "purpose": "clean"}, {"purpose": "clean", "assignee": "Rani", "title": "Clean the bathroom", "instructions": "Clean the bathroom"}], "outcome": "create"}
- run 3: FAIL: one task for the kitchen, one for the bathroom; Saturday on each; nothing added (proposal, 1.4 s) clean the kitchen [for Rani] [purpose: clean]
    model wrote: {"outcome": "create", "tasks": [{"assignee": "Rani", "purpose": "clean", "title": "clean the kitchen"}]}
- run 4: ok (proposal, 1.8 s) Clean the kitchen [for Rani] [due Sat, 31 Oct] | Clean the bathroom [for Rani] [due Sat, 31 Oct]
- run 5: FAIL: Saturday on each; nothing added (proposal, 1.9 s) clean the kitchen [for Rani] [purpose: clean] | clean the bathroom [for Rani] [purpose: clean] [instructions: on Saturday]
    model wrote: {"outcome": "create", "tasks": [{"assignee": "Rani", "title": "clean the kitchen", "purpose": "clean"}, {"assignee": "Rani", "title": "clean the bathroom", "instructions": "on Saturday", "purpose": "clean"}]}
- run 6: FAIL: one task for the kitchen, one for the bathroom; Rani on each; Saturday on each; nothing added (proposal, 2.2 s) clean the kitchen [for Rani] [purpose: clean] | clean the bathroom [for Rani] [purpose: clean] | schedule task on Saturday [due Sat, 31 Oct]
    model wrote: {"tasks": [{"instructions": "", "purpose": "clean", "title": "clean the kitchen", "assignee": "Rani"}, {"purpose": "clean", "assignee": "Rani", "instructions": "", "title": "clean the bathroom"}, {"title": "schedule task on Saturday", "schedule": "Saturday"}], "outcome": "create"}
- run 7: FAIL: Saturday on each; nothing added (proposal, 1.9 s) Clean the kitchen [for Rani] [purpose: clean] | Clean the bathroom [for Rani] [purpose: clean] [instructions: on Saturday]
    model wrote: {"outcome": "create", "tasks": [{"assignee": "Rani", "title": "Clean the kitchen", "purpose": "clean"}, {"assignee": "Rani", "instructions": "on Saturday", "title": "Clean the bathroom", "purpose": "clean"}]}
- run 8: FAIL: Saturday on each; nothing added (proposal, 1.9 s) clean the kitchen [for Rani] [purpose: clean] | clean the bathroom [for Rani] [purpose: clean] [instructions: on Saturday]
    model wrote: {"outcome": "create", "tasks": [{"title": "clean the kitchen", "assignee": "Rani", "purpose": "clean"}, {"instructions": "on Saturday", "purpose": "clean", "title": "clean the bathroom", "assignee": "Rani"}]}
- run 9: FAIL: one task for the kitchen, one for the bathroom; Saturday on each; nothing added (proposal, 1.4 s) Clean the kitchen [for Rani] [purpose: cleaning] [instructions: Clean the kitchen]
    model wrote: {"tasks": [{"purpose": "cleaning", "instructions": "Clean the kitchen", "title": "Clean the kitchen", "assignee": "Rani"}], "outcome": "create"}
- run 10: FAIL: Saturday on each; nothing added (proposal, 1.8 s) Clean the kitchen [for Rani] [purpose: clean] | Clean the bathroom [for Rani] [purpose: clean] [instructions: Saturday]
    model wrote: {"outcome": "create", "tasks": [{"purpose": "clean", "assignee": "Rani", "title": "Clean the kitchen"}, {"assignee": "Rani", "purpose": "clean", "instructions": "Saturday", "title": "Clean the bathroom"}]}

### zepto: "Order paneer and Amul butter from Zepto tomorrow evening"
- run 1: ok (proposal, 1.6 s) Order paneer from Zepto [due Wed, 28 Oct] [evening] | Order Amul butter from Zepto [due Wed, 28 Oct] [evening]
    model wrote: {"outcome": "create", "tasks": [{"schedule": "tomorrow evening", "title": "Order paneer from Zepto"}, {"schedule": "tomorrow evening", "title": "Order Amul butter from Zepto"}]}
- run 2: FAIL: nothing added (proposal, 2.4 s) Order paneer [due Wed, 28 Oct] [evening] [list: Orders] [purpose: purchase] [instructions: from Zepto] | Order Amul butter [due Wed, 28 Oct] [evening] [list: Orders] [purpose: purchase] [instructions: from Zepto]
    model wrote: {"outcome": "create", "listName": "Orders", "tasks": [{"instructions": "from Zepto", "title": "Order paneer", "purpose": "purchase", "schedule": "tomorrow evening"}, {"purpose": "purchase", "title": "Order Amul butter", "instructions": "from Zepto", "schedule": "tomorrow evening"}], "question": "Is Zepto available for ordering tomorrow evening?"}
- run 3: FAIL: nothing added (proposal, 1.8 s) Order paneer from Zepto [due Wed, 28 Oct] [evening] [purpose: purchase] | Order Amul butter from Zepto [due Wed, 28 Oct] [evening] [purpose: purchase]
    model wrote: {"outcome": "create", "tasks": [{"title": "Order paneer from Zepto", "purpose": "purchase", "schedule": "tomorrow evening"}, {"purpose": "purchase", "title": "Order Amul butter from Zepto", "schedule": "tomorrow evening"}]}
- run 4: ok (proposal, 1.6 s) Order paneer from Zepto [due Wed, 28 Oct] [evening] | Order Amul butter from Zepto [due Wed, 28 Oct] [evening]
- run 5: ok (proposal, 1.6 s) Order paneer from Zepto [due Wed, 28 Oct] [evening] | Order Amul butter from Zepto [due Wed, 28 Oct] [evening]
- run 6: ok (proposal, 1.6 s) Order paneer from Zepto [due Wed, 28 Oct] [evening] | Order Amul butter from Zepto [due Wed, 28 Oct] [evening]
- run 7: ok (proposal, 1.6 s) Order paneer from Zepto [due Wed, 28 Oct] [evening] | Order Amul butter from Zepto [due Wed, 28 Oct] [evening]
- run 8: ok (proposal, 1.6 s) Order paneer from Zepto [due Wed, 28 Oct] [evening] | Order Amul butter from Zepto [due Wed, 28 Oct] [evening]
- run 9: ok (proposal, 1.6 s) Order paneer from Zepto [due Wed, 28 Oct] [evening] | Order Amul butter from Zepto [due Wed, 28 Oct] [evening]
- run 10: ok (proposal, 1.6 s) Order paneer from Zepto [due Wed, 28 Oct] [evening] | Order Amul butter from Zepto [due Wed, 28 Oct] [evening]

### routines: "Water the plants and feed the cat every morning"
- run 1: FAIL: each repeats; morning on each; nothing added (proposal, 1.8 s) Water the plants [purpose: maintain plants] [instructions: water plants] | Feed the cat [purpose: feed cat] [instructions: feed cat]
    model wrote: {"tasks": [{"title": "Water the plants", "instructions": "water plants", "purpose": "maintain plants"}, {"instructions": "feed cat", "purpose": "feed cat", "title": "Feed the cat"}], "outcome": "create"}
- run 2: FAIL: each repeats; morning on each; nothing added (proposal, 1.5 s) Water the plants [purpose: maintain growth] | Feed the cat [purpose: provide nutrition]
    model wrote: {"tasks": [{"purpose": "maintain growth", "title": "Water the plants"}, {"purpose": "provide nutrition", "title": "Feed the cat"}], "outcome": "create"}
- run 3: FAIL: each repeats; morning on each; nothing added (proposal, 1.5 s) Water the plants [purpose: maintain greenery] | Feed the cat [purpose: provide nourishment]
    model wrote: {"outcome": "create", "tasks": [{"purpose": "maintain greenery", "title": "Water the plants"}, {"purpose": "provide nourishment", "title": "Feed the cat"}]}
- run 4: FAIL: each repeats; morning on each; nothing added (proposal, 1.5 s) Water the plants [purpose: maintain growth] | Feed the cat [purpose: provide nutrition]
    model wrote: {"outcome": "create", "tasks": [{"title": "Water the plants", "purpose": "maintain growth"}, {"purpose": "provide nutrition", "title": "Feed the cat"}]}
- run 5: FAIL: each repeats; morning on each; nothing added (proposal, 1.7 s) Water the plants [purpose: keep them healthy] | Feed the cat [purpose: keep it well-fed]
    model wrote: {"outcome": "create", "tasks": [{"purpose": "keep them healthy", "title": "Water the plants"}, {"purpose": "keep it well-fed", "title": "Feed the cat"}]}
- run 6: FAIL: each repeats; morning on each; nothing added (proposal, 1.6 s) Water the plants [purpose: routine] | Feed the cat [purpose: routine]
    model wrote: {"outcome": "create", "tasks": [{"purpose": "routine", "title": "Water the plants"}, {"title": "Feed the cat", "purpose": "routine"}]}
- run 7: FAIL: each repeats; morning on each; nothing added (proposal, 1.5 s) Water the plants [purpose: maintain growth] | Feed the cat [purpose: provide nourishment]
    model wrote: {"tasks": [{"title": "Water the plants", "purpose": "maintain growth"}, {"purpose": "provide nourishment", "title": "Feed the cat"}], "outcome": "create"}
- run 8: FAIL: each repeats; morning on each; nothing added (proposal, 1.5 s) Water the plants [purpose: maintain growth] | Feed the cat [purpose: provide nutrition]
    model wrote: {"tasks": [{"purpose": "maintain growth", "title": "Water the plants"}, {"title": "Feed the cat", "purpose": "provide nutrition"}], "outcome": "create"}
- run 9: FAIL: each repeats; morning on each; nothing added (proposal, 1.5 s) Water the plants [purpose: maintain greenery] | Feed the cat [purpose: provide nourishment]
    model wrote: {"outcome": "create", "tasks": [{"title": "Water the plants", "purpose": "maintain greenery"}, {"purpose": "provide nourishment", "title": "Feed the cat"}]}
- run 10: FAIL: each repeats; morning on each; nothing added (proposal, 1.8 s) Water the plants [purpose: maintain greenery] [instructions: water plants] | Feed the cat [purpose: care for pet] [instructions: feed cat]
    model wrote: {"tasks": [{"purpose": "maintain greenery", "instructions": "water plants", "title": "Water the plants"}, {"instructions": "feed cat", "title": "Feed the cat", "purpose": "care for pet"}], "outcome": "create"}

### one-task: "Buy milk and bread from Blinkit, but make it one task"
- run 1: FAIL: no metadata (proposal, 1.4 s) Buy milk and bread from Blinkit [purpose: purchase]
    model wrote: {"outcome": "create", "tasks": [{"purpose": "purchase", "title": "Buy milk and bread from Blinkit"}]}
- run 2: FAIL: no metadata (proposal, 1.4 s) Buy milk and bread from Blinkit [purpose: shopping]
    model wrote: {"tasks": [{"title": "Buy milk and bread from Blinkit", "purpose": "shopping"}], "outcome": "create"}
- run 3: ok (proposal, 1.3 s) Buy milk and bread from Blinkit
- run 4: FAIL: no metadata (proposal, 1.4 s) Buy milk and bread from Blinkit [purpose: Purchase essentials]
    model wrote: {"outcome": "create", "tasks": [{"title": "Buy milk and bread from Blinkit", "purpose": "Purchase essentials"}]}
- run 5: FAIL: one task holding both; no metadata (proposal, 2.0 s) Buy milk from Blinkit [purpose: Purchase] [instructions: Go to Blinkit and purchase milk] | Buy bread from Blinkit [purpose: Purchase] [instructions: Go to Blinkit and purchase bread]
    model wrote: {"outcome": "create", "tasks": [{"instructions": "Go to Blinkit and purchase milk", "title": "Buy milk from Blinkit", "purpose": "Purchase"}, {"instructions": "Go to Blinkit and purchase bread", "title": "Buy bread from Blinkit", "purpose": "Purchase"}]}
- run 6: ok (proposal, 1.2 s) Buy milk and bread from Blinkit
- run 7: FAIL: no metadata (proposal, 1.4 s) Buy milk and bread from Blinkit [purpose: purchase]
    model wrote: {"outcome": "create", "tasks": [{"purpose": "purchase", "title": "Buy milk and bread from Blinkit"}]}
- run 8: FAIL: no metadata (proposal, 1.4 s) Buy milk and bread from Blinkit [purpose: Purchase essentials]
    model wrote: {"outcome": "create", "tasks": [{"purpose": "Purchase essentials", "title": "Buy milk and bread from Blinkit"}]}
- run 9: FAIL: no metadata (proposal, 1.3 s) Buy milk and bread from Blinkit [purpose: shopping]
    model wrote: {"outcome": "create", "tasks": [{"title": "Buy milk and bread from Blinkit", "purpose": "shopping"}]}
- run 10: FAIL: no metadata (proposal, 1.4 s) Buy milk and bread from Blinkit [purpose: Purchase items]
    model wrote: {"tasks": [{"title": "Buy milk and bread from Blinkit", "purpose": "Purchase items"}], "outcome": "create"}

### plumber: "Call the plumber"
- run 1: ok (proposal, 1.1 s) Call the plumber
    model wrote: {"outcome": "create", "tasks": [{"title": "Call the plumber"}]}
- run 2: ok (proposal, 1.1 s) Call the plumber
- run 3: ok (proposal, 1.1 s) Call the plumber
- run 4: ok (proposal, 1.1 s) Call the plumber
- run 5: ok (proposal, 1.1 s) Call the plumber
- run 6: ok (proposal, 1.1 s) Call the plumber
- run 7: ok (proposal, 1.1 s) Call the plumber
- run 8: ok (proposal, 1.1 s) Call the plumber
- run 9: ok (proposal, 1.1 s) Call the plumber
- run 10: ok (proposal, 1.1 s) Call the plumber

### dolo: "Remind me to take Dolo 650 after lunch"
- run 1: FAIL: no steps added, not a routine (proposal, 1.5 s) Take Dolo 650 after lunch [purpose: remind]
    model wrote: {"outcome": "create", "tasks": [{"purpose": "remind", "title": "Take Dolo 650 after lunch"}]}
- run 2: FAIL: no steps added, not a routine (proposal, 1.5 s) Take Dolo 650 after lunch [purpose: take medication]
    model wrote: {"outcome": "create", "tasks": [{"purpose": "take medication", "title": "Take Dolo 650 after lunch"}]}
- run 3: FAIL: no steps added, not a routine (proposal, 1.4 s) Take Dolo 650 [purpose: after lunch]
    model wrote: {"tasks": [{"title": "Take Dolo 650", "purpose": "after lunch"}], "outcome": "create"}
- run 4: ok (proposal, 1.4 s) Take Dolo 650 [instructions: after lunch]
- run 5: ok (proposal, 1.5 s) Take Dolo 650 after lunch [instructions: Take Dolo 650 after lunch]
- run 6: FAIL: no steps added, not a routine (proposal, 1.3 s) Take Dolo 650 after lunch [purpose: reminder]
    model wrote: {"tasks": [{"purpose": "reminder", "title": "Take Dolo 650 after lunch"}], "outcome": "create"}
- run 7: FAIL: no steps added, not a routine (proposal, 1.5 s) Take Dolo 650 after lunch [purpose: take medication]
    model wrote: {"outcome": "create", "tasks": [{"title": "Take Dolo 650 after lunch", "purpose": "take medication"}]}
- run 8: FAIL: no steps added, not a routine (proposal, 1.4 s) Take Dolo 650 after lunch [purpose: medication]
    model wrote: {"outcome": "create", "tasks": [{"title": "Take Dolo 650 after lunch", "purpose": "medication"}]}
- run 9: FAIL: no steps added, not a routine (proposal, 1.4 s) Take Dolo 650 after lunch [purpose: after lunch]
    model wrote: {"outcome": "create", "tasks": [{"title": "Take Dolo 650 after lunch", "purpose": "after lunch"}]}
- run 10: FAIL: no steps added, not a routine (proposal, 1.5 s) Take Dolo 650 after lunch [purpose: take medication]
    model wrote: {"outcome": "create", "tasks": [{"purpose": "take medication", "title": "Take Dolo 650 after lunch"}]}

### friends: "My friends are visiting, I need to prepare the room, order food from Blinkit, book a cab"
- run 1: ok (proposal, 1.4 s) Prepare the room | Order food from Blinkit | Book a cab
    model wrote: {"outcome": "create", "tasks": [{"title": "Prepare the room"}, {"title": "Order food from Blinkit"}, {"title": "Book a cab"}]}
- run 2: ok (proposal, 1.5 s) Prepare the room | Order food from Blinkit | Book a cab
- run 3: ok (proposal, 1.5 s) Prepare the room | Order food from Blinkit | Book a cab
- run 4: FAIL: nothing added, no metadata (proposal, 2.5 s) Prepare the room [list: Tasks] [purpose: Prepare the room] | Order food from Blinkit [list: Tasks] [purpose: Order food] | Book a cab [list: Tasks] [purpose: Book a cab]
    model wrote: {"listName": "Tasks", "question": "What specific actions do I need to take for preparing the room?", "outcome": "create", "tasks": [{"purpose": "Prepare the room", "title": "Prepare the room"}, {"title": "Order food from Blinkit", "purpose": "Order food"}, {"title": "Book a cab", "purpose": "Book a cab"}]}
- run 5: FAIL: one task each for the room, the food, the cab; Blinkit on the food task; nothing added, no metadata (proposal, 1.7 s) Prepare the room [list: Tasks] [purpose: prepare for visitors]
    model wrote: {"listName": "Tasks", "question": "What specific room tasks need to be completed?", "outcome": "create", "tasks": [{"title": "Prepare the room", "purpose": "prepare for visitors"}]}
- run 6: ok (proposal, 1.9 s) Prepare the room [list: Tasks] | Order food from Blinkit [list: Tasks] | Book a cab [list: Tasks]
- run 7: FAIL: nothing added, no metadata (proposal, 2.7 s) Prepare the room [list: Tasks] [purpose: Get ready for friends' visit] | Order food from Blinkit [list: Tasks] [purpose: Get food for the visitors] | Book a cab [list: Tasks] [purpose: Get transportation for the visitors]
    model wrote: {"outcome": "create", "question": "What specific actions do I need to take for preparing the room?", "listName": "Tasks", "tasks": [{"purpose": "Get ready for friends' visit", "title": "Prepare the room"}, {"purpose": "Get food for the visitors", "title": "Order food from Blinkit"}, {"title": "Book a cab", "purpose": "Get transportation for the visitors"}]}
- run 8: ok (proposal, 1.4 s) Prepare the room | Order food from Blinkit | Book a cab
- run 9: FAIL: nothing added, no metadata (proposal, 1.8 s) prepare the room [purpose: friends are visiting] | order food from Blinkit [purpose: friends are visiting] | book a cab [purpose: friends are visiting]
    model wrote: {"tasks": [{"purpose": "friends are visiting", "title": "prepare the room"}, {"purpose": "friends are visiting", "title": "order food from Blinkit"}, {"purpose": "friends are visiting", "title": "book a cab"}], "outcome": "create"}
- run 10: FAIL: nothing added, no metadata (proposal, 1.8 s) Prepare the room [purpose: for friends] | Order food from Blinkit [purpose: for friends] | Book a cab [purpose: for friends]
    model wrote: {"tasks": [{"title": "Prepare the room", "purpose": "for friends"}, {"purpose": "for friends", "title": "Order food from Blinkit"}, {"purpose": "for friends", "title": "Book a cab"}], "outcome": "create"}

### playbook: "Teach me a playbook for hosting guests: first clean the room, then order food, then book a cab"
- run 1: FAIL: a playbook with three ordered steps (proposal, 1.8 s) clean the room [purpose: prepare the space] | order food [purpose: feed guests] | book a cab [purpose: transport guests]
    model wrote: {"tasks": [{"title": "clean the room", "purpose": "prepare the space"}, {"purpose": "feed guests", "title": "order food"}, {"purpose": "transport guests", "title": "book a cab"}], "outcome": "create"}
- run 2: FAIL: a playbook with three ordered steps (proposal, 1.9 s) clean the room [purpose: prepare guest area] | order food [purpose: provide guest meal] | book a cab [purpose: transport guests]
    model wrote: {"tasks": [{"purpose": "prepare guest area", "title": "clean the room"}, {"purpose": "provide guest meal", "title": "order food"}, {"purpose": "transport guests", "title": "book a cab"}], "outcome": "create"}
- run 3: FAIL: a playbook with three ordered steps (proposal, 1.8 s) clean the room [purpose: preparation] | order food [purpose: guest satisfaction] | book a cab [purpose: transportation]
    model wrote: {"tasks": [{"purpose": "preparation", "title": "clean the room"}, {"purpose": "guest satisfaction", "title": "order food"}, {"purpose": "transportation", "title": "book a cab"}], "outcome": "create"}
- run 4: FAIL: a playbook with three ordered steps (proposal, 1.9 s) clean the room [purpose: prepare the room] | order food [purpose: provide guests with meals] | book a cab [purpose: transport guests]
    model wrote: {"tasks": [{"purpose": "prepare the room", "title": "clean the room"}, {"title": "order food", "purpose": "provide guests with meals"}, {"purpose": "transport guests", "title": "book a cab"}], "outcome": "create"}
- run 5: FAIL: a playbook with three ordered steps (proposal, 2.0 s) clean the room [purpose: prepare the space] | order food [purpose: provide guests with meals] | book a cab [purpose: transport guests]
    model wrote: {"outcome": "create", "tasks": [{"title": "clean the room", "purpose": "prepare the space"}, {"title": "order food", "purpose": "provide guests with meals"}, {"title": "book a cab", "purpose": "transport guests"}]}
- run 6: FAIL: a playbook with three ordered steps (proposal, 1.9 s) clean the room [purpose: preparation] | order food [purpose: guest satisfaction] | book a cab [purpose: transportation]
    model wrote: {"tasks": [{"purpose": "preparation", "title": "clean the room"}, {"title": "order food", "purpose": "guest satisfaction"}, {"title": "book a cab", "purpose": "transportation"}], "outcome": "create"}
- run 7: FAIL: a playbook with three ordered steps (proposal, 1.9 s) clean the room [purpose: prepare space] | order food [purpose: provide meals] | book a cab [purpose: transport guests]
    model wrote: {"outcome": "create", "tasks": [{"purpose": "prepare space", "title": "clean the room"}, {"purpose": "provide meals", "title": "order food"}, {"title": "book a cab", "purpose": "transport guests"}]}
- run 8: FAIL: a playbook with three ordered steps (proposal, 1.8 s) clean the room [purpose: prepare for guests] | order food [purpose: feed guests] | book a cab [purpose: transport guests]
    model wrote: {"outcome": "create", "tasks": [{"title": "clean the room", "purpose": "prepare for guests"}, {"title": "order food", "purpose": "feed guests"}, {"title": "book a cab", "purpose": "transport guests"}]}
- run 9: FAIL: a playbook with three ordered steps (proposal, 1.9 s) Clean the room [purpose: Prepare the space] | Order food [purpose: Provide meals] | Book a cab [purpose: Transport guests]
    model wrote: {"outcome": "create", "tasks": [{"title": "Clean the room", "purpose": "Prepare the space"}, {"purpose": "Provide meals", "title": "Order food"}, {"purpose": "Transport guests", "title": "Book a cab"}]}
- run 10: FAIL: a playbook with three ordered steps (proposal, 2.0 s) clean the room [list: Playbook] [purpose: preparation] | order food [list: Playbook] [purpose: guest satisfaction] | book a cab [list: Playbook] [purpose: transportation]
    model wrote: {"tasks": [{"purpose": "preparation", "title": "clean the room"}, {"purpose": "guest satisfaction", "title": "order food"}, {"title": "book a cab", "purpose": "transportation"}], "listName": "Playbook", "outcome": "create"}

### question: "Remind me"
- run 1: ok (question, 1.0 s) What would you like the task to be?
    model wrote: {"outcome": "wait", "tasks": []}
- run 2: ok (question, 1.0 s) What would you like the task to be?
- run 3: ok (question, 1.0 s) What would you like the task to be?
- run 4: ok (question, 1.0 s) What would you like the task to be?
- run 5: ok (question, 1.3 s) What would you like the task to be?
- run 6: ok (question, 1.1 s) What would you like the task to be?
- run 7: ok (question, 1.1 s) What would you like the task to be?
- run 8: ok (question, 1.1 s) What would you like the task to be?
- run 9: ok (question, 1.1 s) What would you like the task to be?
- run 10: ok (question, 1.1 s) What would you like the task to be?

### leak: "Pick up the dry cleaning"
- run 1: ok (proposal, 1.1 s) Pick up the dry cleaning
    model wrote: {"outcome": "create", "tasks": [{"title": "Pick up the dry cleaning"}]}
- run 2: ok (proposal, 1.1 s) Pick up the dry cleaning
- run 3: ok (proposal, 1.1 s) Pick up the dry cleaning
- run 4: ok (proposal, 1.0 s) Pick up the dry cleaning
- run 5: ok (proposal, 1.1 s) Pick up the dry cleaning
- run 6: ok (proposal, 1.1 s) Pick up the dry cleaning
- run 7: ok (proposal, 1.1 s) Pick up the dry cleaning
- run 8: ok (proposal, 1.1 s) Pick up the dry cleaning
- run 9: ok (proposal, 1.1 s) Pick up the dry cleaning
- run 10: ok (proposal, 1.1 s) Pick up the dry cleaning

### b-pharmacy-list: "Pharmacy list: buy Cetaphil body lotion, Teddybar soap, and Cipcal tablets."
- run 1: FAIL: no day, time, person, repeat (proposal, 2.1 s) buy Cetaphil body lotion [list: Pharmacy list] [purpose: pharmacy purchase] | buy Teddybar soap [list: Pharmacy list] [purpose: pharmacy purchase] | buy Cipcal tablets [list: Pharmacy list] [purpose: pharmacy purchase]
    model wrote: {"listName": "Pharmacy list", "outcome": "create", "tasks": [{"purpose": "pharmacy purchase", "title": "buy Cetaphil body lotion"}, {"purpose": "pharmacy purchase", "title": "buy Teddybar soap"}, {"title": "buy Cipcal tablets", "purpose": "pharmacy purchase"}]}
- run 2: FAIL: one task each for Cetaphil, Teddybar, Cipcal; the list is Pharmacy, not a task, on each item (reply, 3.3 s) I didn't add anything: The model failed: Response may contain sensitive or unsafe content. Please try again.
    model wrote: {"outcome": "create", "tasks": [{"title": "buy Cetaphil body lotion", "purpose": "purchase"}, {"purpose": "purchase", "title": "buy Teddybar soap"}, {}], "listName": "Pharmacy list"}
- run 3: FAIL: one task each for Cetaphil, Teddybar, Cipcal; the list is Pharmacy, not a task, on each item (reply, 3.3 s) I didn't add anything: The model failed: Response may contain sensitive or unsafe content. Please try again.
    model wrote: {"listName": "Pharmacy list", "tasks": [{"title": "buy Cetaphil body lotion", "purpose": "purchase"}, {"title": "buy Teddybar soap", "purpose": "purchase"}, {}], "outcome": "create"}
- run 4: FAIL: one task each for Cetaphil, Teddybar, Cipcal; the list is Pharmacy, not a task, on each item (reply, 3.4 s) I didn't add anything: The model failed: Response may contain sensitive or unsafe content. Please try again.
    model wrote: {"outcome": "create", "listName": "Pharmacy list", "tasks": [{"purpose": "buy", "title": "buy Cetaphil body lotion"}, {"title": "buy Teddybar soap", "purpose": "buy"}, {}]}
- run 5: FAIL: one task each for Cetaphil, Teddybar, Cipcal; the list is Pharmacy, not a task, on each item (reply, 3.3 s) I didn't add anything: The model failed: Response may contain sensitive or unsafe content. Please try again.
    model wrote: {"tasks": [{"purpose": "buy", "title": "buy Cetaphil body lotion"}, {"purpose": "buy", "title": "buy Teddybar soap"}, {}], "outcome": "create", "listName": "Pharmacy list"}
- run 6: FAIL: one task each for Cetaphil, Teddybar, Cipcal; the list is Pharmacy, not a task, on each item (reply, 3.3 s) I didn't add anything: The model failed: Response may contain sensitive or unsafe content. Please try again.
    model wrote: {"listName": "Pharmacy list", "tasks": [{"purpose": "purchase", "title": "buy Cetaphil body lotion"}, {"purpose": "purchase", "title": "buy Teddybar soap"}, {}], "outcome": "create"}
- run 7: FAIL: one task each for Cetaphil, Teddybar, Cipcal; the list is Pharmacy, not a task, on each item (reply, 3.3 s) I didn't add anything: The model failed: Response may contain sensitive or unsafe content. Please try again.
    model wrote: {"tasks": [{"title": "buy Cetaphil body lotion", "purpose": "buy"}, {"purpose": "buy", "title": "buy Teddybar soap"}, {}], "outcome": "create", "listName": "Pharmacy list"}
- run 8: FAIL: one task each for Cetaphil, Teddybar, Cipcal; the list is Pharmacy, not a task, on each item (reply, 3.3 s) I didn't add anything: The model failed: Response may contain sensitive or unsafe content. Please try again.
    model wrote: {"tasks": [{"title": "buy Cetaphil body lotion", "purpose": "purchase"}, {"purpose": "purchase", "title": "buy Teddybar soap"}, {}], "listName": "Pharmacy list", "outcome": "create"}
- run 9: FAIL: one task each for Cetaphil, Teddybar, Cipcal; the list is Pharmacy, not a task, on each item (reply, 3.2 s) I didn't add anything: The model failed: Response may contain sensitive or unsafe content. Please try again.
    model wrote: {"listName": "Pharmacy list", "outcome": "create", "tasks": [{"purpose": "purchase", "title": "buy Cetaphil body lotion"}, {"purpose": "purchase", "title": "buy Teddybar soap"}, {}]}
- run 10: FAIL: one task each for Cetaphil, Teddybar, Cipcal; the list is Pharmacy, not a task, on each item (reply, 1.8 s) I didn't add anything: The model failed: Response may contain sensitive or unsafe content. Please try again.
    model wrote: {"outcome": "create", "listName": "Pharmacy list", "tasks": [{"title": "buy Cetaphil body lotion"}, {"title": "buy Teddybar soap"}, {}]}

### b-recurring: "Every morning, have the househelp water the balcony plants."
- run 1: FAIL: a morning routine Swift can run; nothing added (proposal, 1.5 s) water the balcony plants [for Househelp] [purpose: every morning]
    model wrote: {"outcome": "create", "tasks": [{"title": "water the balcony plants", "assignee": "househelp", "purpose": "every morning"}]}
- run 2: FAIL: a morning routine Swift can run (proposal, 1.3 s) water the balcony plants [for Househelp]
    model wrote: {"outcome": "create", "tasks": [{"assignee": "househelp", "title": "water the balcony plants"}]}
- run 3: FAIL: a morning routine Swift can run (proposal, 1.3 s) water the balcony plants [for Househelp]
    model wrote: {"tasks": [{"title": "water the balcony plants", "assignee": "househelp"}], "outcome": "create"}
- run 4: FAIL: a morning routine Swift can run; the househelp is the assignee; nothing added (proposal, 1.5 s) househelp water balcony plants [purpose: water the balcony plants] [instructions: water the balcony plants]
    model wrote: {"outcome": "create", "tasks": [{"title": "househelp water balcony plants", "purpose": "water the balcony plants", "instructions": "water the balcony plants"}]}
- run 5: FAIL: a morning routine Swift can run (proposal, 1.3 s) water the balcony plants [for Househelp]
    model wrote: {"tasks": [{"assignee": "househelp", "title": "water the balcony plants"}], "outcome": "create"}
- run 6: FAIL: a morning routine Swift can run (proposal, 1.3 s) water the balcony plants [for Househelp]
    model wrote: {"tasks": [{"assignee": "househelp", "title": "water the balcony plants"}], "outcome": "create"}
- run 7: FAIL: a morning routine Swift can run (proposal, 1.4 s) water the balcony plants [for Househelp]
    model wrote: {"outcome": "create", "tasks": [{"title": "water the balcony plants", "assignee": "househelp"}]}
- run 8: FAIL: a morning routine Swift can run; nothing added (proposal, 1.5 s) water the balcony plants [for Househelp] [purpose: have the balcony plants watered]
    model wrote: {"tasks": [{"assignee": "househelp", "title": "water the balcony plants", "purpose": "have the balcony plants watered"}], "outcome": "create"}
- run 9: FAIL: a morning routine Swift can run; nothing added (proposal, 1.4 s) househelp water the balcony plants [for Househelp] [purpose: water balcony plants]
    model wrote: {"tasks": [{"purpose": "water balcony plants", "title": "househelp water the balcony plants", "assignee": "househelp"}], "outcome": "create"}
- run 10: FAIL: a morning routine Swift can run (proposal, 1.3 s) househelp water the balcony plants [for Househelp]
    model wrote: {"outcome": "create", "tasks": [{"assignee": "househelp", "title": "househelp water the balcony plants"}]}

### b-purpose: "Buy Cipcal for calcium deficiency. Get 500 mg, one strip."
- run 1: FAIL: the purpose is the reason (proposal, 1.6 s) Buy Cipcal for calcium deficiency [instructions: 500 mg, one strip]
    model wrote: {"tasks": [{"title": "Buy Cipcal for calcium deficiency", "instructions": "500 mg, one strip"}], "outcome": "create"}
- run 2: FAIL: the dosage is the instructions (proposal, 1.6 s) Buy Cipcal for calcium deficiency, 500 mg, one strip [purpose: calcium deficiency]
    model wrote: {"outcome": "create", "tasks": [{"title": "Buy Cipcal for calcium deficiency, 500 mg, one strip", "purpose": "calcium deficiency"}]}
- run 3: FAIL: the dosage is the instructions (proposal, 1.7 s) Buy Cipcal for calcium deficiency, 500 mg, one strip [purpose: calcium deficiency]
    model wrote: {"tasks": [{"title": "Buy Cipcal for calcium deficiency, 500 mg, one strip", "purpose": "calcium deficiency"}], "outcome": "create"}
- run 4: ok (proposal, 1.8 s) Buy Cipcal for calcium deficiency [purpose: calcium deficiency] [instructions: 500 mg, one strip]
- run 5: ok (proposal, 1.7 s) Buy Cipcal for calcium deficiency [purpose: calcium deficiency] [instructions: 500 mg, one strip]
- run 6: FAIL: the purpose is the reason (proposal, 1.5 s) Buy Cipcal for calcium deficiency [instructions: 500 mg, one strip]
    model wrote: {"outcome": "create", "tasks": [{"instructions": "500 mg, one strip", "title": "Buy Cipcal for calcium deficiency"}]}
- run 7: FAIL: the dosage is the instructions (proposal, 1.6 s) Buy Cipcal for calcium deficiency, 500 mg, one strip [purpose: calcium deficiency]
    model wrote: {"outcome": "create", "tasks": [{"purpose": "calcium deficiency", "title": "Buy Cipcal for calcium deficiency, 500 mg, one strip"}]}
- run 8: ok (proposal, 1.7 s) Buy Cipcal for calcium deficiency [purpose: calcium deficiency] [instructions: 500 mg, one strip]
- run 9: FAIL: the dosage is the instructions (proposal, 1.7 s) Buy Cipcal for calcium deficiency, 500 mg, one strip [purpose: calcium deficiency] [instructions: one strip]
    model wrote: {"tasks": [{"title": "Buy Cipcal for calcium deficiency, 500 mg, one strip", "instructions": "one strip", "purpose": "calcium deficiency"}], "outcome": "create"}
- run 10: FAIL: the purpose is the reason (proposal, 1.5 s) Buy Cipcal for calcium deficiency [instructions: Get 500 mg, one strip]
    model wrote: {"outcome": "create", "tasks": [{"instructions": "Get 500 mg, one strip", "title": "Buy Cipcal for calcium deficiency"}]}

### b-clarify: "Buy Cipcal."
- run 1: ok (proposal, 1.1 s) Buy Cipcal
    model wrote: {"tasks": [{"title": "Buy Cipcal"}], "outcome": "create"}
- run 2: ok (proposal, 1.1 s) Buy Cipcal
- run 3: ok (proposal, 1.1 s) Buy Cipcal
- run 4: ok (proposal, 1.2 s) Buy Cipcal
- run 5: ok (proposal, 1.1 s) Buy Cipcal
- run 6: ok (proposal, 1.2 s) Buy Cipcal
- run 7: ok (proposal, 1.3 s) Buy Cipcal
- run 8: ok (proposal, 1.2 s) Buy Cipcal
- run 9: ok (proposal, 1.2 s) Buy Cipcal
- run 10: ok (proposal, 1.2 s) Buy Cipcal

### b-tomorrow: "Buy milk tomorrow."
- run 1: FAIL: tomorrow, worked out by Swift (proposal, 1.2 s) Buy milk
    model wrote: {"tasks": [{"title": "Buy milk"}], "outcome": "create"}
- run 2: FAIL: tomorrow, worked out by Swift (proposal, 1.2 s) Buy milk
    model wrote: {"tasks": [{"title": "Buy milk"}], "outcome": "create"}
- run 3: FAIL: tomorrow, worked out by Swift (proposal, 1.3 s) Buy milk
    model wrote: {"outcome": "create", "tasks": [{"title": "Buy milk"}]}
- run 4: FAIL: tomorrow, worked out by Swift (proposal, 1.1 s) Buy milk
    model wrote: {"outcome": "create", "tasks": [{"title": "Buy milk"}]}
- run 5: FAIL: tomorrow, worked out by Swift (proposal, 1.2 s) Buy milk
    model wrote: {"tasks": [{"title": "Buy milk"}], "outcome": "create"}
- run 6: FAIL: tomorrow, worked out by Swift (proposal, 1.1 s) Buy milk
    model wrote: {"outcome": "create", "tasks": [{"title": "Buy milk"}]}
- run 7: FAIL: tomorrow, worked out by Swift (proposal, 1.1 s) Buy milk
    model wrote: {"outcome": "create", "tasks": [{"title": "Buy milk"}]}
- run 8: FAIL: tomorrow, worked out by Swift (proposal, 1.2 s) Buy milk
    model wrote: {"tasks": [{"title": "Buy milk"}], "outcome": "create"}
- run 9: FAIL: tomorrow, worked out by Swift (proposal, 1.2 s) Buy milk
    model wrote: {"outcome": "create", "tasks": [{"title": "Buy milk"}]}
- run 10: FAIL: tomorrow, worked out by Swift (proposal, 1.2 s) Buy milk
    model wrote: {"tasks": [{"title": "Buy milk"}], "outcome": "create"}

### b-two-lists: "Pharmacy list: Cetaphil, Teddybar, Cipcal. Grocery list: milk, bread, eggs."
- run 1: ok (proposal, 3.1 s) Cetaphil [list: Pharmacy list] | Teddybar [list: Pharmacy list] | Cipcal [list: Pharmacy list] | get milk [list: Grocery list] | get bread [list: Grocery list] | get eggs [list: Grocery list]
    model wrote: {"outcome": "create", "tasks": [{"title": "get milk"}, {"title": "get bread"}, {"title": "get eggs"}], "listName": "Grocery list"}
- run 2: FAIL: six tasks, one each; three on Pharmacy, three on Grocery (proposal, 2.5 s) Add Cetaphil to Pharmacy list [list: Pharmacy list] | get milk [list: Grocery list]
    model wrote: {"listName": "Grocery list", "tasks": [{"title": "get milk"}], "outcome": "create"}
- run 3: FAIL: six tasks, one each; three on Pharmacy, three on Grocery (proposal, 2.8 s) List Cetaphil [list: Pharmacy list] | get milk [list: Grocery list] | get bread [list: Grocery list] | get eggs [list: Grocery list]
    model wrote: {"outcome": "create", "tasks": [{"title": "get milk"}, {"title": "get bread"}, {"title": "get eggs"}], "listName": "Grocery list"}
- run 4: FAIL: six tasks, one each; three on Pharmacy, three on Grocery (proposal, 2.6 s) List Cetaphil [list: Pharmacy list] | obtain milk [list: Grocery list]
    model wrote: {"outcome": "create", "listName": "Grocery list", "tasks": [{"title": "obtain milk"}]}
- run 5: FAIL: six tasks, one each; three on Pharmacy, three on Grocery (proposal, 2.8 s) Cetaphil [list: Pharmacy list] | buy milk [list: Grocery list] | buy bread [list: Grocery list] | buy eggs [list: Grocery list]
    model wrote: {"tasks": [{"title": "buy milk"}, {"title": "buy bread"}, {"title": "buy eggs"}], "listName": "Grocery list", "outcome": "create"}
- run 6: FAIL: six tasks, one each; three on Pharmacy, three on Grocery (proposal, 2.6 s) Cetaphil [list: Pharmacy list] | get milk [list: Grocery list]
    model wrote: {"outcome": "create", "listName": "Grocery list", "tasks": [{"title": "get milk"}]}
- run 7: FAIL: six tasks, one each; three on Pharmacy, three on Grocery (proposal, 2.6 s) List Cetaphil [list: Pharmacy list] | buy milk [list: Grocery list]
    model wrote: {"outcome": "create", "listName": "Grocery list", "tasks": [{"title": "buy milk"}]}
- run 8: FAIL: six tasks, one each; three on Pharmacy, three on Grocery (proposal, 2.8 s) Cetaphil [list: Pharmacy list] | get milk [list: Grocery list] | get bread [list: Grocery list] | get eggs [list: Grocery list]
    model wrote: {"outcome": "create", "tasks": [{"title": "get milk"}, {"title": "get bread"}, {"title": "get eggs"}], "listName": "Grocery list"}
- run 9: FAIL: six tasks, one each; three on Pharmacy, three on Grocery (proposal, 2.5 s) List Cetaphil [list: Pharmacy list] | buy milk [list: Grocery list]
    model wrote: {"tasks": [{"title": "buy milk"}], "listName": "Grocery list", "outcome": "create"}
- run 10: FAIL: six tasks, one each; three on Pharmacy, three on Grocery (proposal, 2.8 s) Request Cetaphil [list: Pharmacy list] | get milk [list: Grocery list] | get bread [list: Grocery list] | get eggs [list: Grocery list]
    model wrote: {"outcome": "create", "listName": "Grocery list", "tasks": [{"title": "get milk"}, {"title": "get bread"}, {"title": "get eggs"}]}

