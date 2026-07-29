# Troubleshooting

[← back to README](../README.md)

Two commands answer most questions before you read any further:

| Command | Shows |
|---|---|
| `:NeocursorDebug` | resolved config, sidecar state, last error, whether this buffer is eligible |
| `:NeocursorLog` | live event stream — requests, responses, suppressions, jumps |

`:NeocursorDebug` prints no token and no buffer contents, so its output is safe
to paste into an issue.

---

## Contents

- [Cursor can't be found](#cursor-cant-be-found)
- [The sidecar won't start](#the-sidecar-wont-start)
- [No suggestions appear](#no-suggestions-appear)
- [`<Tab>` does nothing](#tab-does-nothing)
- [Suggestions appear but in the wrong place](#suggestions-appear-but-in-the-wrong-place)
- [Filing a bug](#filing-a-bug)

---

## Cursor can't be found

**Symptom:** the sidecar dies at startup, or `:NeocursorDebug` shows an error
mentioning `state.vscdb` or a missing config directory.

neocursor reads Cursor's signed-in session off disk. It looks where your
platform puts it:

| Platform | Cursor data dir |
|---|---|
| macOS | `~/Library/Application Support/Cursor` |
| Linux | `$XDG_CONFIG_HOME/Cursor` → `~/.config/Cursor` |
| Windows | `%APPDATA%\Cursor` |

Insiders builds and the lowercase `cursor` directory some Linux packages create
are detected automatically. The first candidate that actually contains a
`state.vscdb` wins.

### See exactly what's being checked

```sh
uv run cursor_paths.py   # in the plugin directory
```

This prints every candidate path and which one was selected. It's the single
most useful output for any path or auth problem — run it before anything else.

### Point it somewhere else

Portable installs, Flatpak/Snap sandboxes, or Windows-side Cursor seen from WSL
need an explicit path:

```sh
# the Cursor config directory
export CURSOR_CONFIG_DIR="/mnt/c/Users/me/AppData/Roaming/Cursor"   # WSL example

# or aim straight at the SQLite file
export CURSOR_STATE_DB_PATH="/path/to/User/globalStorage/state.vscdb"
```

Set these where Neovim will inherit them — your shell profile, or
`vim.env.CURSOR_CONFIG_DIR = "…"` in your config before `setup()`.

### Signed in?

neocursor uses an existing session; it cannot create one. Open Cursor, confirm
you're logged in, and let it sync once before trying again.

---

## The sidecar won't start

**Symptom:** `:NeocursorDebug` shows `sidecar job : nil` or `(no ready signal)`.

Check `last stderr` in the same output — the sidecar's own error is replayed
there when it dies before signalling ready.

Common causes:

- **`uv` isn't on Neovim's `PATH`.** A GUI-launched Neovim often has a narrower
  `PATH` than your terminal. Verify from inside Neovim: `:echo exepath('uv')`.
  Empty means Neovim can't see it, even if your shell can.
- **First run is still fetching deps.** The sidecar pulls `httpx[http2]` on
  first launch. Give it a few seconds, or pre-warm it:
  ```sh
  uv run --with "httpx[http2]" python -c "import httpx"
  ```
- **A custom `sidecar_cmd` that doesn't work.** Clear the override and retry
  with the default before debugging anything else.

---

## No suggestions appear

Work down this list in order:

1. **Is the sidecar up?** `:NeocursorDebug` → `sidecar job` should say `READY`.
   If not, see [above](#the-sidecar-wont-start).

2. **Is this buffer eligible?** Same output, `attach ok`. If it's `false`, check
   the `buffer` line — special buffers (non-empty `buftype`) are skipped by
   design, and a `filetypes` allow-list that doesn't include this filetype will
   exclude it.

3. **Is it being suppressed on purpose?** Check `last suppress`. neocursor
   inherits Cursor's heuristics and deliberately stays quiet while you read or
   navigate rather than firing on every cursor move. Type a little, then pause.

4. **Force one.** `:NeocursorSuggest` bypasses the debounce and requests
   immediately. If that produces a suggestion, the plumbing is fine and you were
   hitting gating, not a bug.

5. **Watch it live.** `:NeocursorLog` shows requests going out and what comes
   back, including responses dropped as stale.

---

## `<Tab>` does nothing

Almost always another plugin owns the mapping. nvim-cmp, blink.cmp, LuaSnip and
most snippet engines map `<Tab>` in insert mode.

Check who has it:

```vim
:verbose imap <Tab>
```

The output names the file that set it last. If it isn't neocursor, hand the key
over explicitly:

```lua
require("neocursor").setup({ map_tab = false })

-- then, in your own <Tab> mapping, try neocursor first:
if require("neocursor").accept() then return end
-- …otherwise fall through to cmp / blink / snippets
```

`accept()` returns `true` when it consumed the key and `false` when there was
nothing to accept, which makes it safe as the first branch of a chain.

See [Installation](./installation.md#letting-nvim-cmp--blinkcmp-own-tab) for the
full pattern.

---

## Suggestions appear but in the wrong place

If a suggestion lands at the wrong line, or an accept duplicates text, that's a
bug worth reporting — but first confirm it isn't a stale response: `:NeocursorLog`
marks responses dropped because the buffer changed since the request was sent.

Include the log excerpt and, if you can, the sequence of keystrokes that
produced it. This class of bug is almost always about ordering, so the log is
far more useful than a screenshot.

---

## Filing a bug

Include:

- `:NeocursorDebug` output
- `uv run cursor_paths.py` output — required for anything path- or auth-related
- OS, and how Cursor was installed (official build, Flatpak, Snap, AUR, WSL-side)
- `nvim --version`
- `:NeocursorLog` excerpt if the failure is intermittent

→ [open an issue](https://github.com/teocns/neocursor.nvim/issues) ·
[contributing guide](../CONTRIBUTING.md)
