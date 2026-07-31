# Demo recording harness

Everything that produces `assets/demo.gif` (the README hero) and
`assets/demo-still.png` (a poster frame for contexts that cannot animate —
GitHub's social card, link unfurls, slides). Regenerate both with:

```bash
./demo/record.sh
```

## Why it is built this way

A demo GIF is documentation, and documentation that nobody can rebuild rots.
The usual approach — screen-record yourself once and drag the file in — leaves a
binary in the repo that cannot be reviewed, corrected, or re-shot when the UI
changes. Everything here is aimed at making the recording a build artifact
instead: pinned inputs, scripted keystrokes, one command.

Two decisions carry most of that weight.

**The backend is canned.** `sidecar.py` speaks the same JSON-lines protocol as
the real sidecar but always returns the same two edits. The live Cursor backend
varies in latency and wording, which would make every take different and the
result impossible to review in a pull request. It also means recording works
without a Cursor subscription.

**The keystrokes are event-synchronised, not timed.** `drive.sh` pilots a real
Neovim over its RPC socket and polls the plugin's own predicates —
`has_suggestion()`, the cursor line, the buffer text — so each beat starts the
instant the previous one lands. A recording built on `sleep` looks fine on the
machine it was made on and silently breaks everywhere slower, pressing `<Tab>`
before the ghost text exists.

## The pieces

| File | Role |
| --- | --- |
| `scenario.py` | The code on screen. Copied to a scratch dir; never edited in place. |
| `init.lua` | Hermetic Neovim config — no user plugins, fixed colours and geometry. |
| `sidecar.py` | Scripted stand-in for Cursor's backend. |
| `drive.sh` | Pilots Neovim; owns the keystrokes and the pacing. |
| `demo.tape` | VHS tape. Only films — it never types into the editor. |
| `record.sh` | Entry point: preflight, record, optimise, report size. |

## The scenario

`self.retries` is renamed to `self.max_retries` on line 3. Two call sites, 5 and
10 lines away, are now stale. The developer types one word and then presses
`<Tab>` four times: jump, accept, jump, accept.

This case is chosen deliberately over a plain completion demo. Completion looks
like every other AI plugin; the cursor jump is the part that does not exist
elsewhere, so the scenario is built to need it twice.

## Tuning

| Variable | Default | Effect |
| --- | --- | --- |
| `DEMO_SPEED` | `1.0` | Scales every dramatic pause. `1.5` for a slower read. |
| `DEMO_COLS` / `DEMO_ROWS` | `84` / `20` | tmux pane size. Must match the tape geometry. |
| `DEMO_ATTACH` | `1` | `0` runs the beats headlessly — the CI smoke test. |
| `DEMO_BUDGET_KB` | `3500` | Warn above this output size. |
| `DEMO_POSTER_AT` | `7.2` | Timestamp the poster frame is taken from. |

Playback speed is set in the tape (`Set PlaybackSpeed`), not here — it scales
typing and pauses together, whereas `DEMO_SPEED` stretches only the pauses and
is meant for watching the pilot live.

Geometry is the one thing that cannot be changed casually. `906x520` at
`FontSize 16` with `Padding 20` and a window bar yields exactly an 84x20
terminal, which is what `drive.sh` pins tmux to. Change any of them and the code
reflows. Re-probe before touching it:

```bash
# inside a tape: Type "tput cols > /tmp/probe.txt; tput lines >> /tmp/probe.txt"
```

## Checking it without recording

```bash
DEMO_ATTACH=0 ./demo/drive.sh   # drives the flow, prints one line per beat
```

This is a genuine behavioural test — it fails loudly if a suggestion never
arrives or a jump lands on the wrong line — and it is much faster than a full
render.

## Gotchas that cost real time

- **`nvim --remote-expr` needs `--headless` and `</dev/null`.** Given a TTY on
  stdin it starts a full UI, and the value comes back wrapped in escape codes.
  It only behaves when run from a pipe, which is exactly how you test it by hand
  and exactly not how a recorder runs it.
- **VHS types nothing for a single-quoted string.** Every `Type` in the tape is
  double-quoted, and all shell logic lives in scripts rather than in the tape.
- **A bash `EXIT` trap also fires inside `$(...)`.** This script is mostly RPC
  polls in command substitution; without a `BASHPID` guard the first poll tears
  down the session it is polling.
- **tmux `-x/-y` is advisory.** Default `window-size latest` resizes to whatever
  client attaches, so the window is pinned with `window-size manual`.
