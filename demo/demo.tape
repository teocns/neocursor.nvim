# VHS tape for the neocursor.nvim hero GIF.  Render with: ./demo/record.sh
#
# This tape only *films*. All the editing is driven by demo/drive.sh, which
# pilots a real Neovim over its RPC socket and waits on the plugin's own state
# between beats. VHS therefore never types into the editor and never needs to
# guess how long the backend will take.
#
# Geometry note: 906x520 at FontSize 16 with Padding 20 and a window bar yields
# exactly an 84x20 terminal, which is the size drive.sh pins the tmux window
# to. Changing any of these WILL reflow the code -- re-probe with `tput cols`
# before touching them.

Output "assets/demo.gif"

Set Shell "bash"
Set FontSize 16
Set Width 906
Set Height 520
Set Padding 20
Set WindowBar Colorful
Set BorderRadius 10
Set Framerate 24
Set CursorBlink false

# 1.2x. Applied at playback rather than by shortening the beats, so the pacing
# stays uniform -- typing, pauses and the Tab gestures all scale together. The
# beats themselves stay readable when drive.sh is run live in a terminal.
Set PlaybackSpeed 1.2

# GitHub-dark palette, so the GIF sits naturally in the README on either theme.
Set Theme { "name": "github-dark", "background": "#0d1117", "foreground": "#c9d1d9", "cursor": "#58a6ff", "selection": "#264f78", "black": "#484f58", "red": "#ff7b72", "green": "#3fb950", "yellow": "#d29922", "blue": "#58a6ff", "magenta": "#bc8cff", "cyan": "#39c5cf", "white": "#b1bac4", "brightBlack": "#6e7681", "brightRed": "#ffa198", "brightGreen": "#56d364", "brightYellow": "#e3b341", "brightBlue": "#79c0ff", "brightMagenta": "#d2a8ff", "brightCyan": "#56d4dd", "brightWhite": "#f0f6fc" }

# --- boot, unfilmed ---------------------------------------------------------
# Neovim's startup is not part of the story. Bring the session fully up while
# frames are hidden, so the first thing a viewer ever sees is the finished code.
#
# Every Type line below is a bare command in double quotes. VHS silently types
# NOTHING for a single-quoted string, and shell metacharacters in a tape are a
# reliable way to lose an evening -- so all the real logic lives in drive.sh and
# the tape only ever names it. record.sh guarantees the working directory.
Hide
Type "./demo/drive.sh --boot"
Enter

# Wait on the pilot's own readiness line rather than a fixed sleep. A sleep that
# is too short types the next command into a still-running boot; one that is
# long enough to be safe wastes ten seconds on every render. This also fails the
# tape loudly if boot never comes up, instead of filming an empty terminal.
Wait+Screen@30s /rpc socket up/

Type "clear"
Enter
Sleep 500ms

# Attach to the warm session. ~900ms is enough for tmux to paint the pane; the
# pilot's opening beat is sized to leave ~2.2s of readable rest after this.
Type "./demo/drive.sh --film"
Enter
Sleep 900ms
Show

# --- the take ---------------------------------------------------------------
# drive.sh holds its opening beat until this attach completes, so filming and
# the performance start together. ~15s of event-synced beats follow; the extra
# margin here is absorbed by the closing rest, not by a shell prompt.
# The beats are event-synced, so the performance is ~12-13s depending on how
# fast the machine answers RPC -- it is not a fixed length. This window has to
# clear the SLOW end of that range, or the recording stops mid-gesture with the
# final accept never shown. Overshoot is cheap: the extra frames are the same
# resting state the closing beat already holds, which is what the loop wants.
# Undershoot silently truncates the payoff.
Sleep 15s
