#!/usr/bin/env bash
# Render the hero GIF. One command, reproducible on any machine:
#
#   ./demo/record.sh
#
# Everything that determines what ends up on screen is pinned in version
# control -- the Neovim config (demo/init.lua), the backend responses
# (demo/sidecar.py), the keystrokes and their synchronisation (demo/drive.sh),
# and the terminal geometry (demo/demo.tape). Re-running this should produce
# essentially the same GIF, which is what makes the demo reviewable in a PR
# rather than a mystery binary someone once dragged in.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
export NEOCURSOR_ROOT="$ROOT"

OUT="assets/demo.gif"
BUDGET_KB="${DEMO_BUDGET_KB:-3500}"   # GitHub renders fine well past this;
                                      # beyond it the README feels sluggish.

missing=()
for tool in vhs tmux nvim python3; do
  command -v "$tool" >/dev/null 2>&1 || missing+=("$tool")
done
if [ ${#missing[@]} -gt 0 ]; then
  printf 'missing required tool(s): %s\n' "${missing[*]}" >&2
  printf 'install with: brew install vhs tmux neovim\n' >&2
  exit 1
fi

# A leftover session from an aborted run would be attached to instead of a
# fresh one, silently filming a half-finished buffer.
tmux kill-session -t "${DEMO_SESSION:-neocursor-demo}" 2>/dev/null || true

mkdir -p assets
rm -f "$OUT"

printf '==> recording (about 40s)\n'
vhs demo/demo.tape

# drive.sh --film deliberately leaves the session alive so the recording ends
# on the finished code rather than on a shell prompt. Reap it here.
tmux kill-session -t "${DEMO_SESSION:-neocursor-demo}" 2>/dev/null || true
rm -f "${DEMO_SOCK:-/tmp/neocursor-demo.sock}"

if [ ! -f "$OUT" ]; then
  printf 'vhs produced no output; see the errors above\n' >&2
  exit 1
fi

size_kb() { echo $(( ( $(wc -c < "$1") + 1023 ) / 1024 )); }
raw_kb=$(size_kb "$OUT")
printf '==> raw: %s KB\n' "$raw_kb"

# Lossless-only optimisation. `--lossy` shaves a lot more off, but it stipples
# antialiased glyph edges, and this GIF is almost entirely small text -- the
# thing a viewer is being asked to read.
if command -v gifsicle >/dev/null 2>&1; then
  gifsicle -O3 --careful "$OUT" -o "$OUT.opt" 2>/dev/null && mv "$OUT.opt" "$OUT"
  printf '==> optimised: %s KB (was %s KB)\n' "$(size_kb "$OUT")" "$raw_kb"
else
  printf '==> gifsicle not found; skipping optimisation\n'
fi

# A still for the places that cannot animate: GitHub's social preview card, link
# unfurls, slides. Generated here rather than by hand so it can never drift out
# of sync with the GIF it is supposed to represent.
POSTER="assets/demo-still.png"
POSTER_AT="${DEMO_POSTER_AT:-7.2}"   # mid-refactor: one call site fixed, one
                                     # still stale with the jump hint showing
if command -v ffmpeg >/dev/null 2>&1; then
  if ffmpeg -y -ss "$POSTER_AT" -i "$OUT" -frames:v 1 "$POSTER" 2>/dev/null; then
    printf '==> poster: %s (t=%ss)\n' "$POSTER" "$POSTER_AT"
  else
    printf '!!  poster frame failed; %s may be stale\n' "$POSTER" >&2
  fi
else
  printf '==> ffmpeg not found; skipping poster frame\n'
fi

final_kb=$(size_kb "$OUT")
if [ "$final_kb" -gt "$BUDGET_KB" ]; then
  printf '!!  %s KB exceeds the %s KB budget -- consider trimming a beat\n' \
    "$final_kb" "$BUDGET_KB" >&2
fi

printf '==> wrote %s (%s KB)\n' "$OUT" "$final_kb"
