#!/usr/bin/env bash
# Deterministically pilots a live Neovim through the tab-tab flow for the demo
# recording.
#
# The important property: this script never sleeps waiting for the plugin. It
# drives nvim over its RPC socket and *polls the plugin's own predicates* --
# has_suggestion() / line('.') / the buffer text itself -- so each beat begins
# the instant the previous one actually landed. Blind sleeps would desync the
# moment the backend or a CI runner got slower, silently producing a GIF where
# Tab is pressed before the ghost text exists.
#
# Sleeps that DO remain are purely dramatic: time for a human to read the
# frame. They are tagged `beat` and are the only pacing knob.
#
# Modes exist so a recorder never films Neovim's startup. `--boot` blocks until
# the editor is up and painted; `--film` then attaches to an already-warm
# session, so the very first recorded frame is the finished code.
#
#   ./demo/drive.sh                 # boot + drive + watch, in your terminal
#   ./demo/drive.sh --boot          # bring the session up, leave it running
#   ./demo/drive.sh --film          # drive an already-booted session, attached
#   DEMO_ATTACH=0 ./demo/drive.sh   # headless smoke test (CI)
#   DEMO_SPEED=1.5 ./demo/drive.sh  # stretch every dramatic beat
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SESSION="${DEMO_SESSION:-neocursor-demo}"
SOCK="${DEMO_SOCK:-/tmp/neocursor-demo.sock}"
WORK="${DEMO_WORK:-/tmp/neocursor-demo}"
LOG="${DEMO_LOG:-/tmp/neocursor-demo.log}"
COLS="${DEMO_COLS:-84}"
ROWS="${DEMO_ROWS:-20}"
SPEED="${DEMO_SPEED:-1.0}"
ATTACH="${DEMO_ATTACH:-1}"
MODE="${1:-all}"

beat() { sleep "$(awk -v a="$1" -v s="$SPEED" 'BEGIN{print a*s}')"; }

# A Neovim sitting on a hit-enter prompt never answers RPC, and --remote-expr
# waits forever. Cap every call so a wedged editor surfaces as a failed
# `await` instead of a hung recording. `timeout` is absent on stock macOS;
# degrade gracefully rather than hard-requiring coreutils.
if command -v timeout >/dev/null 2>&1; then TMO=(timeout 3)
elif command -v gtimeout >/dev/null 2>&1; then TMO=(gtimeout 3)
else TMO=(); fi

# --headless and </dev/null are both load-bearing, not belt-and-braces noise.
# When the remote client finds a TTY on stdin it spins up a full-screen UI,
# tears it down, and the value we asked for comes back buried in a hundred
# bytes of escape sequences -- so every comparison silently fails. It only
# looks fine when run from a pipe, which is exactly how you test it by hand and
# exactly not how a recorder runs it.
rpc()  { "${TMO[@]}" nvim --headless --server "$SOCK" --remote-expr "$1" 2>/dev/null </dev/null || true; }
send() { "${TMO[@]}" nvim --headless --server "$SOCK" --remote-send "$1" 2>/dev/null </dev/null || true; }
pred()     { rpc "luaeval('require\"neocursor\".$1() and 1 or 0')"; }
cur_line() { rpc 'line(".")'; }
has_word() { rpc "getline($1) =~ 'max_retries' ? 1 : 0"; }

# Poll until a probe prints the expected value. Fails loudly rather than
# silently filming an editor where nothing happens.
await() {
  local what="$1" want="$2" probe="$3" timeout="${4:-8000}" waited=0
  while [ "$waited" -lt "$timeout" ]; do
    [ "$(eval "$probe")" = "$want" ] && { printf '  ok    %s\n' "$what"; return 0; }
    sleep 0.05; waited=$((waited + 50))
  done
  printf '  FAIL  %s (timeout %sms)\n' "$what" "$timeout"
  tmux capture-pane -t "$SESSION" -p
  return 1
}

# Type like a person, one character at a time -- an instant paste reads as fake
# and gives the debounce nothing to react to.
type_human() {
  local text="$1" delay="${2:-0.08}"
  for ((i = 0; i < ${#text}; i++)); do
    send "${text:i:1}"; sleep "$delay"
  done
}

beats() {
  # Beat 0 -- hold on the untouched file. The viewer must read the code before
  # anything moves, or the payoff lands on nothing. --film adds a further hold
  # ahead of this one to absorb recorder start-up drift.
  beat 2.0

  # Beat 1 -- the developer renames one field on line 3. `fr` lands on
  # `retries`, `cw` changes that word. This is the ONLY edit a human makes.
  send ':3<CR>'; send '0'; send 'fr'; beat 0.5
  send 'cw'; beat 0.25
  type_human 'max_retries'

  # Beat 2 -- the plugin now knows both call sites are stale.
  await 'suggestion arrives' 1 "pred has_suggestion" 8000
  beat 1.4

  # Beat 3 -- Tab #1 teleports to the first broken call site, 5 lines down.
  send '<Tab>'
  await 'jumped to call site L8' 8 'cur_line' 4000
  beat 1.2

  # Beat 4 -- Tab #2 accepts the rewrite there.
  send '<Tab>'
  await 'call site L8 rewritten' 1 'has_word 8' 4000
  beat 1.2

  # Beat 5 -- Tab #3 teleports to the second call site, 5 lines further.
  send '<Tab>'
  await 'jumped to call site L13' 13 'cur_line' 4000
  beat 1.2

  # Beat 6 -- Tab #4 accepts the final rewrite. The refactor is complete; the
  # developer typed one word to get here.
  send '<Tab>'
  await 'call site L13 rewritten' 1 'has_word 13' 4000

  send '<Esc>'
  # Beat 7 -- rest on the finished state so all three lines can be seen to
  # agree, and so the loop has a clean resting frame to return to.
  beat 2.0
  printf 'demo drive complete\n'
}

boot() {
  rm -rf "$WORK" && mkdir -p "$WORK"
  cp "$ROOT/demo/scenario.py" "$WORK/config.py"   # never mutate the repo copy
  rm -f "$SOCK" "$LOG"
  tmux kill-session -t "$SESSION" 2>/dev/null || true
  tmux new-session -d -s "$SESSION" -x "$COLS" -y "$ROWS" \
    "nvim --listen $SOCK -u $ROOT/demo/init.lua $WORK/config.py"

  # `-x/-y` alone is advisory: tmux's default `window-size latest` resizes the
  # window to whatever client attaches, so the recorder's own terminal would
  # silently change the frame and reflow the code. Pin it.
  tmux set-option -t "$SESSION" window-size manual 2>/dev/null || true
  tmux resize-window -t "$SESSION" -x "$COLS" -y "$ROWS" 2>/dev/null || true

  # tmux's status bar would otherwise brand every frame of the GIF with a
  # hostname and a clock -- which also makes the recording non-reproducible.
  tmux set-option -t "$SESSION" status off 2>/dev/null || true

  # Block until the editor actually answers, so a recorder that starts filming
  # right after this call never catches a blank or half-painted frame.
  await 'nvim rpc socket up' 2 "rpc '1+1'" 15000
}

# bash runs an EXIT trap inside command-substitution subshells too, and this
# script is almost entirely $(...) RPC polls. Without the BASHPID guard the
# very first poll would tear down the session it is polling.
MAIN_PID=$$
cleanup() {
  [ "${BASHPID:-$$}" = "$MAIN_PID" ] || return 0
  tmux kill-session -t "$SESSION" 2>/dev/null || true
  rm -f "$SOCK"
}

case "$MODE" in
  --boot)
    # Leave the session running for a subsequent --film; no cleanup trap.
    boot
    ;;
  --film)
    # Session is already warm. Hold the pilot until a client is actually
    # attached: starting on a timer instead means any delay in attaching eats
    # the opening beat, and the recording opens midway through the typing with
    # the "before" state never shown.
    #
    # Deliberately does NOT tear the session down at the end -- if attach
    # exits, the recorder films the shell prompt underneath. The last frame
    # must stay on the finished code. record.sh cleans up afterwards.
    (
      until [ "$(tmux display -t "$SESSION" -p '#{session_attached}' 2>/dev/null)" = "1" ]; do
        sleep 0.05
      done
      # Attach only tells us tmux has a client -- it says nothing about whether
      # the recorder has resumed capturing frames, and that resumption has
      # drifted by up to ~3s between runs. Hold the pristine frame through that
      # window: if the performance starts first, the recording opens midway
      # through the typing and the viewer never sees the original line, which is
      # the entire setup for the rename.
      beat 2.0
      beats
    ) >"$LOG" 2>&1 &
    exec tmux attach -t "$SESSION"
    ;;
  all)
    trap cleanup EXIT
    boot
    if [ "$ATTACH" = "0" ]; then
      beats 2>&1 | tee "$LOG"
      exit "${PIPESTATUS[0]}"
    fi
    ( beats >"$LOG" 2>&1; tmux kill-session -t "$SESSION" 2>/dev/null ) &
    exec tmux attach -t "$SESSION"
    ;;
  *)
    printf 'usage: %s [--boot|--film]\n' "$0" >&2
    exit 2
    ;;
esac
