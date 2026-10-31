# Real on-device model, draft conversation

Same starting draft each run, real edit call (snapshot prompt, measured budget, on-device model). 3 fresh run(s) per scenario. Counts are what happened, not a guarantee.

| scenario | good | not good | no answer |
|---|---|---|---|
| add a task to create the invoice | 0/3 | 3/3 | 0/3 |
| remove all the tags | 0/3 | 3/3 | 0/3 |
| remove the tags from the cab one | 0/3 | 3/3 | 0/3 |
| remove the cardamom ones | 0/3 | 3/3 | 0/3 |
| I said book a cab | 0/3 | 3/3 | 0/3 |
| start over, buy milk | 0/3 | 3/3 | 0/3 |
| why did you add that | 3/3 | 0/3 | 0/3 |

## Measured fixed cost per call kind

- extract: window 8192, instructions 604, schema 1817, tools 415, counted by the model, room for the prompt 3856
- review: window 8192, instructions 604, schema 2371, tools 0, counted by the model, room for the prompt 3717
- reviewWithTools: window 8192, instructions 604, schema 2371, tools 272, counted by the model, room for the prompt 3445

## Detail

- add a task to create the invoice run 1: got ["Buy Milk", "Book Cab", "Order Dinner", "Call Mom", "Create Invoice [Financial]", "Review Draft List [Planning]"] from ["Buy Milk", "Book Cab", "Order Dinner", "Call Mom"]
- add a task to create the invoice: 3,153 of 8,192 tokens used before the answer | instructions 604, schema 2,371, tools 0, prompt 178 | answer reserve 1,200, margin 300 | counted by the model
- add a task to create the invoice run 2: got ["Buy Milk", "Book Cab", "Order Dinner", "Call Mom"] from ["Buy Milk", "Book Cab", "Order Dinner", "Call Mom"]
- add a task to create the invoice run 3: got ["Update Item Tags", "Update Item Tags", "Update Item Tags", "Update Item Tags"] from ["Buy Milk", "Book Cab", "Order Dinner", "Call Mom"]
- remove all the tags run 1: got ["Buy Milk", "Book Cab", "Order Dinner", "Call Mom"] from ["Buy Milk", "Book Cab", "Order Dinner", "Call Mom"]
- remove all the tags: 3,150 of 8,192 tokens used before the answer | instructions 604, schema 2,371, tools 0, prompt 175 | answer reserve 1,200, margin 300 | counted by the model
- remove all the tags run 2: got ["Clear Labels", "Clear Labels", "Clear Labels", "Clear Labels", "Buy Milk [Food]"] from ["Buy Milk", "Book Cab", "Order Dinner", "Call Mom"]
- remove all the tags run 3: got ["Clear Tags", "Clear Tags", "Clear Tags", "Clear Tags"] from ["Buy Milk", "Book Cab", "Order Dinner", "Call Mom"]
- remove the tags from the cab one run 1: got ["Clear Labels from Cab", "Clear Labels from Cab", "Clear Labels from Cab", "Clear Labels from Cab"] from ["Buy Milk", "Book Cab", "Order Dinner", "Call Mom"]
- remove the tags from the cab one: 3,153 of 8,192 tokens used before the answer | instructions 604, schema 2,371, tools 0, prompt 178 | answer reserve 1,200, margin 300 | counted by the model
- remove the tags from the cab one run 2: got ["Clear Labels", "Clear Labels", "Clear Labels", "Clear Labels", "Clear Labels [Food]", "Clear Labels [Food]", "Clear Labels [Food]", "Clear Labels [Food]", "Clear Labels [Food]"] from ["Buy Milk", "Book Cab", "Order Dinner", "Call Mom"]
- remove the tags from the cab one run 3: got ["Remove Tags", "Remove Tags", "Remove Tags", "Remove Tags"] from ["Buy Milk", "Book Cab", "Order Dinner", "Call Mom"]
- remove the cardamom ones run 1: got [] from ["Book Cardamom", "Order Cardamom Tea", "Buy Milk"]
- remove the cardamom ones: 3,129 of 8,192 tokens used before the answer | instructions 604, schema 2,371, tools 0, prompt 154 | answer reserve 1,200, margin 300 | counted by the model
- remove the cardamom ones run 2: got ["Remove Item", "Remove Item", "Remove Item"] from ["Book Cardamom", "Order Cardamom Tea", "Buy Milk"]
- remove the cardamom ones run 3: got ["Book Cardamom", "Order Cardamom Tea", "Buy Milk"] from ["Book Cardamom", "Order Cardamom Tea", "Buy Milk"]
- I said book a cab run 1: got ["Book Cardamom [Food]", "Buy Milk [Food]", "Call Mom [Food]"] from ["Book Cardamom", "Buy Milk", "Call Mom"]
- I said book a cab: 3,128 of 8,192 tokens used before the answer | instructions 604, schema 2,371, tools 0, prompt 153 | answer reserve 1,200, margin 300 | counted by the model
- I said book a cab run 2: got ["Book Cardamom [Food]", "Buy Milk [Food]", "Call Mom [Food]"] from ["Book Cardamom", "Buy Milk", "Call Mom"]
- I said book a cab run 3: got ["Book Cardamom [Food]", "Buy Milk [Food]", "Call Mom [Food]"] from ["Book Cardamom", "Buy Milk", "Call Mom"]
- start over, buy milk run 1: got ["Buy Milk [Food]", "Book Cab [Food]", "Order Dinner [Food]", "Call Mom [Food]"] from ["Buy Milk", "Book Cab", "Order Dinner", "Call Mom"]
- start over, buy milk: 3,150 of 8,192 tokens used before the answer | instructions 604, schema 2,371, tools 0, prompt 175 | answer reserve 1,200, margin 300 | counted by the model
- start over, buy milk run 2: got ["Buy Milk [Food]", "Book Cab [Food]", "Order Dinner [Food]", "Call Mom [Food]"] from ["Buy Milk", "Book Cab", "Order Dinner", "Call Mom"]
- start over, buy milk run 3: got ["Buy Milk", "Buy Milk", "Buy Milk", "Buy Milk", "Buy Milk [Food]"] from ["Buy Milk", "Book Cab", "Order Dinner", "Call Mom"]
- why did you add that: 3,151 of 8,192 tokens used before the answer | instructions 604, schema 2,371, tools 0, prompt 176 | answer reserve 1,200, margin 300 | counted by the model
