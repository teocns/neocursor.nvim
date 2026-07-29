<h1 align="center">neocursor.nvim</h1>

<p align="center">
  <b>Cursor's Tab — the real next-edit model — inside Neovim.</b>
</p>

<p align="center">
  <a href="https://github.com/teocns/neocursor.nvim/actions/workflows/ci.yml">
    <img src="https://github.com/teocns/neocursor.nvim/actions/workflows/ci.yml/badge.svg" alt="CI"></a>
  <a href="https://github.com/teocns/neocursor.nvim/releases/latest">
    <img src="https://img.shields.io/github/v/release/teocns/neocursor.nvim?color=blue&label=release" alt="Latest release"></a>
  <img src="https://img.shields.io/badge/Neovim-0.10%2B-57A143?logo=neovim&logoColor=white" alt="Neovim 0.10+">
  <img src="https://img.shields.io/badge/platform-macOS%20%7C%20Linux%20%7C%20Windows-lightgrey" alt="macOS, Linux, Windows">
  <a href="./LICENSE">
    <img src="https://img.shields.io/badge/license-MIT-blue" alt="MIT"></a>
</p>

<p align="center">
  <img src="./assets/demo.png" alt="neocursor.nvim: Cursor's Tab predicting the rest of is_prime() as ghost text in Neovim" width="800">
</p>

<p align="center">
  <sub>Typed <code>def is_prime(n):</code> — Cursor predicted the whole body.
  <code>&lt;Tab&gt;</code> accepts · <code>&lt;Tab&gt;</code> again jumps to the next edit.</sub>
</p>

No API key. No model to choose. No account to create. If you're already signed
into Cursor, there is nothing else to set up — neocursor drives Cursor's own
`StreamCpp` backend with your existing login, so you get the *same* predictions,
at the *same* latency, as Cursor itself.

> [!WARNING]
> **Beta.** The goal is 1:1 parity with Cursor's Tab, and most of it is there.
> See [Cursor Tab parity](#cursor-tab-parity) for the honest scoreboard.

<p align="center">
  <a href="#requirements">Requirements</a> ·
  <a href="#installation">Installation</a> ·
  <a href="#usage">Usage</a> ·
  <a href="#configuration">Configuration</a> ·
  <a href="#cursor-tab-parity">Parity</a> ·
  <a href="#how-it-works">How it works</a> ·
  <a href="#troubleshooting">Troubleshooting</a>
</p>

---

## Requirements

- **Neovim ≥ 0.10**
- **Cursor, installed and signed in** (the desktop app) — neocursor reads your
  existing session. No token to paste, no API key, no separate subscription.
- **[`uv`](https://github.com/astral-sh/uv)** on your `PATH` — the Python sidecar
  runs through it and fetches its own deps. Nothing to `pip install`.

Works on **macOS, Linux and Windows**; the sidecar finds Cursor's session
wherever your platform puts it. Unusual install? See
[Troubleshooting](#cursor-cant-be-found).

---

## Installation

### lazy.nvim

```lua
{
  "teocns/neocursor.nvim",
  event = "InsertEnter",
  -- pre-warm the sidecar (double quotes so cmd.exe and sh both parse it)
  build = 'uv run --with "httpx[http2]" python -c "import httpx"',
  opts = {},
}
```

That's the entire setup. No tokens, no required `setup()` arguments — open a
file, start typing, pause → ghost text → `<Tab>`.

### vim.pack

Built into Neovim ≥ 0.12:

```lua
vim.pack.add { "https://github.com/teocns/neocursor.nvim" }
require("neocursor").setup {}
```

<details>
<summary><b>vim.pack: full parity with the lazy.nvim spec</b> (pre-warm + lazy start)</summary>

<br>

The lazy.nvim spec above pre-warms the sidecar's Python deps at install time
(`build`) and defers startup to insert mode (`event`). The vim.pack equivalent:

```lua
-- pre-warm the sidecar's deps on install/update (lazy.nvim's `build`).
-- Register this BEFORE vim.pack.add so it sees the initial install.
vim.api.nvim_create_autocmd("PackChanged", {
  callback = function(ev)
    if ev.data.spec.name ~= "neocursor.nvim" then return end
    if ev.data.kind == "install" or ev.data.kind == "update" then
      vim.system { "uv", "run", "--with", "httpx[http2]", "python", "-c", "import httpx" }
    end
  end,
})

vim.pack.add { "https://github.com/teocns/neocursor.nvim" }

-- start on first insert (lazy.nvim's `event = "InsertEnter"`)
vim.api.nvim_create_autocmd("InsertEnter", {
  once = true,
  callback = function() require("neocursor").setup {} end,
})
```

Skipping the pre-warm is fine — the sidecar fetches its own deps on first
launch; the first suggestion just arrives a few seconds later.

</details>

<details>
<summary><b>Letting nvim-cmp / blink.cmp own <code>&lt;Tab&gt;</code></b></summary>

<br>

If another plugin already maps `<Tab>`, set `map_tab = false` and fall through
to neocursor from your own handler:

```lua
{ "teocns/neocursor.nvim", event = "InsertEnter", opts = { map_tab = false } }

-- in your <Tab> mapping, try neocursor first:
if require("neocursor").accept() then return end
-- …otherwise let cmp/blink handle it
```

</details>

<details>
<summary><b>Pinning a version</b></summary>

<br>

```lua
{ "teocns/neocursor.nvim", version = "*" } -- latest tagged release instead of main
```

With vim.pack, `version` takes a tag, branch, commit hash, or
`vim.version.range()`:

```lua
vim.pack.add { { src = "https://github.com/teocns/neocursor.nvim", version = vim.version.range "*" } }
```

</details>

---

## Usage

Type, pause, and a suggestion appears. Then:

| Key / Command | Does |
|---|---|
| `<Tab>` | Accept · or **jump** to the predicted next edit · or chain to the next one |
| `<M-Right>` | Accept the suggestion word-by-word |
| `<C-]>` | Dismiss |
| `:NeocursorSuggest` | Force a request right now |
| `:NeocursorLog` | Toggle the live state dashboard |
| `:NeocursorDebug` | Print diagnostics |

**The tab-tab-tab flow:** accept a completion → if Cursor predicts an edit
elsewhere, the ghost turns into a `Tab →` hint → next `<Tab>` *jumps* your cursor
there → the one after *accepts*. Exactly Cursor's rhythm.

---

## Configuration

Every option is optional; these are the defaults.

```lua
require("neocursor").setup({
  debounce    = 250,          -- ms; overridden by Cursor's CppConfig at startup
  map_tab     = true,         -- false → another plugin owns <Tab>
  map_partial = "<M-Right>",  -- word-by-word accept; false disables
  filetypes   = nil,          -- allow-list, e.g. { "python", "lua" }; nil = all
  show_hints  = true,         -- false → no hint chrome
  -- how the sidecar is launched; override only for unusual Python setups
  sidecar_cmd = { "uv", "run", "--with", "httpx[http2]" },
})
```

### `show_hints`

Controls the two labels neocursor paints. Suggestions are never affected — ghost
text, diffs, and every `<Tab>` behavior are identical either way.

| Surface | Looks like | Hiding it costs |
|---|---|---|
| `edit` | `⟪neocursor · <Tab> accept⟫` | nothing; the diff beside it already shows the change |
| `prediction` | `⟪<Tab> → L42⟫` | the only on-screen sign a jump is queued |

```lua
show_hints = false                    -- hide both
show_hints = { edit = false }         -- hide the label, keep the jump pill
show_hints = { prediction = false }   -- hide the pill, keep the label
```

Turning the prediction pill off makes pending jumps invisible: `<Tab>` still
jumps, you just won't see where until it does. `:NeocursorDebug` prints the
resolved setting.

---

## Cursor Tab parity

The goal is a **1:1 port of Cursor's Tab** — here's what actually made it
across, and what's still in flight:

| Cursor Tab capability | neocursor |
|---|:---:|
| Inline multi-line completions (ghost text) | ✅ |
| Diff-style rewrites of existing lines | ✅ |
| **Next-edit prediction + cursor jump** (the tab-tab-tab flow) | ✅ |
| Multi-edit chains — one `<Tab>` per edit, no extra round-trips | ✅ |
| Recent-edit / diff-history context | ✅ |
| Nearby-file + linter-error context | ✅ |
| Request gating — stays quiet while you read/navigate | ✅ |
| Partial accept (word-by-word) | ✅ |
| Config pulled live from Cursor (`CppConfig`: debounce, heuristics) | ✅ |
| macOS / Linux / Windows auth paths | ✅ |
| Character-level diffs for single-character edits | 🚧 |
| Cross-file *apply* on jump targets | 🚧 partial — jump lands, chain is partial |

<sub>✅ ported · 🚧 in progress</sub>

The core loop — predict, ghost, `<Tab>`, jump, chain — is complete and running on
Cursor's actual backend. The 🚧 rows are edges, not the main path.

---

## How it works

neocursor doesn't reimplement or retrain a model — it *is* Cursor's Tab, reached
through a tiny stdio bridge:

```
  Neovim (Lua) ──JSON──▶ sidecar.py ──Connect/protobuf over h2──▶ Cursor StreamCpp
   render + <Tab>          reads your Cursor token,                (api2.cursor.sh)
   accept + jump           forges the checksum, streams edits
```

The sidecar reads your local Cursor session, speaks the exact `StreamCpp` call
Cursor's own client makes, and streams back the edit sequence plus the next
cursor-jump target. See [`NOTICE`](./NOTICE) for rendering-technique attribution.

---

## Troubleshooting

Start with `:NeocursorDebug` (resolved config, sidecar state, last error) and
`:NeocursorLog` (live event stream). Between them, most problems name themselves.

### Cursor can't be found

The sidecar looks for Cursor's signed-in session at your platform's data dir:

| | Cursor data dir |
|---|---|
| macOS | `~/Library/Application Support/Cursor` |
| Linux | `$XDG_CONFIG_HOME/Cursor` → `~/.config/Cursor` |
| Windows | `%APPDATA%\Cursor` |

Insiders builds and the lowercase `cursor` directory some Linux packages create
are detected too. If your install lives somewhere else — a portable copy, a
Flatpak/Snap sandbox, or Windows-side Cursor seen from WSL — point the sidecar
at it:

```sh
export CURSOR_CONFIG_DIR="/mnt/c/Users/me/AppData/Roaming/Cursor"   # WSL example
# or aim straight at the SQLite file:
export CURSOR_STATE_DB_PATH="/path/to/User/globalStorage/state.vscdb"
```

To see exactly what's being checked:

```sh
uv run cursor_paths.py   # in the plugin directory
```

That prints every candidate path and which one won — paste it into a bug report.

### No suggestions appear

- Confirm the sidecar came up: `:NeocursorDebug` → `sidecar job` should say `READY`.
- neocursor stays deliberately quiet while you read or navigate; type a little
  and pause. `:NeocursorSuggest` forces a request.
- Check `filetypes` isn't excluding the buffer, and that `buftype` is empty
  (special buffers are skipped by design).

### `<Tab>` does nothing

Another plugin almost certainly owns the mapping. Set `map_tab = false` and call
`require("neocursor").accept()` from your own handler — see
[Installation](#installation).

---

## Contributing

Issues and PRs welcome — see [CONTRIBUTING.md](./CONTRIBUTING.md) for the
project layout, how to run the specs, and what makes a bug report actionable.

Reporting something? Include `:NeocursorDebug` output, plus
`uv run cursor_paths.py` for anything path- or auth-related.

---

## Legal

Independent, **personal-use interoperability** project — not affiliated with
Anysphere / Cursor. It uses *your own* account; the token never leaves your
machine. It talks to Cursor's private API, which is undocumented and may change,
and using it may not fit Cursor's ToS — that's between you and Cursor. No Cursor
source is redistributed. Use at your own risk.

## License

[MIT](./LICENSE). Rendering-technique attribution lives in [`NOTICE`](./NOTICE).
