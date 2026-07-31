#!/usr/bin/env python3
"""Scripted stand-in for Cursor's backend, used only to record the demo GIF.

Speaks the exact same JSON-lines protocol as the real sidecar (see
test/fake_sidecar.py), so init.lua's job plumbing is exercised unmodified.
Using a canned backend makes the recording byte-identical on every run and in
CI — the real backend's latency and phrasing vary, which would make the GIF
irreproducible and the demo un-reviewable.

Scenario (demo/scenario.py): the developer renames `self.retries` to
`self.max_retries` on line 3. The two call sites that now break live 5 and 10
lines away — exactly the case where next-edit prediction beats a plain LSP
rename, because each site needs a different surrounding rewrite.

    L8   for attempt in range(cfg.retries):   ->  cfg.max_retries
    L13  print(f"retries={cfg.retries}")      ->  cfg.max_retries

Yielding the Tab rhythm:  jump -> accept -> jump -> accept.
"""
import json
import os
import sys
import time

# Set NEOCURSOR_DEMO_LOG to capture the real request shape while iterating.
LOG = os.getenv("NEOCURSOR_DEMO_LOG")

# A deliberate, constant think-time. Instant replies look fake and give the
# viewer no beat to register the ghost text; the real backend sits near this.
LATENCY_S = 0.25

CHAIN = [
    {
        "text": "    for attempt in range(cfg.max_retries):",
        "range": {"start": 8, "endInclusive": 8},
    },
    {
        "text": '    print(f"retries={cfg.max_retries}")',
        "range": {"start": 13, "endInclusive": 13},
    },
]

print("ready", file=sys.stderr, flush=True)

for line in sys.stdin:
    line = line.strip()
    if not line:
        continue
    try:
        req = json.loads(line)
    except json.JSONDecodeError:
        continue

    if LOG:
        with open(LOG, "a") as fh:
            fh.write(line + "\n")

    time.sleep(LATENCY_S)

    res = {
        "id": req.get("id"),
        "text": CHAIN[0]["text"],
        "range": CHAIN[0]["range"],
        "edits": CHAIN,
        # Once the chain is spent, point back at the field the developer just
        # renamed. The pill lands near the top of the frame, so the last beat
        # visually rhymes with the first and the GIF loops without a jolt.
        "prediction": {"path": req.get("path"), "line": 3},
    }
    print(json.dumps(res), flush=True)
