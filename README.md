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
  <img src="./assets/demo.gif" alt="neocursor.nvim in Neovim: renaming self.retries to self.max_retries, then pressing Tab to jump to each stale call site and accept the rewritten line" width="800">
</p>

<p align="center">
  <sub>Renamed one field on line 3. The two call sites below are now stale.
  <code>&lt;Tab&gt;</code> jumps to each one · <code>&lt;Tab&gt;</code> again accepts the rewrite.</sub>
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
wherever your platform puts it. Portable install, Flatpak/Snap, or WSL? See
[Cursor can't be found](./docs/troubleshooting.md#cursor-cant-be-found).

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

**More setups** → [docs/installation.md](./docs/installation.md): full vim.pack
parity with the lazy.nvim spec, coexisting with nvim-cmp / blink.cmp, and
pinning a version.

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

### The tab-tab-tab flow

One key does three jobs, in Cursor's exact rhythm — accept, then jump, then
accept again:

```mermaid
flowchart LR
    T["you type, then pause"] --> G["ghost text / diff appears"]
    G -->|Tab| A["edit applied"]
    A --> Q{"Cursor predicts an<br/>edit elsewhere?"}
    Q -->|"yes"| P["jump pill appears<br/>⟪Tab → L42⟫"]
    P -->|Tab| J["cursor jumps there"]
    J -->|Tab| A
    Q -->|"no"| T
```

The loop back through *jump → accept* is what makes it feel like Cursor rather
than a completion engine: you keep pressing the same key and the edits come to
you.

---

## Configuration

Every option is optional. This is the complete set, at its defaults:

```lua
require("neocursor").setup({
  debounce    = 250,
  map_tab     = true,
  map_partial = "<M-Right>",
  filetypes   = nil,
  show_hints  = true,
  sidecar_cmd = { "uv", "run", "--with", "httpx[http2]" },
})
```

| Option | Type | Description |
|---|---|---|
| `debounce` | `number` | Idle milliseconds before a request. Overridden by Cursor's `CppConfig` at startup. |
| `map_tab` | `boolean` | `false` leaves `<Tab>` unmapped so nvim-cmp / blink.cmp can own it. |
| `map_partial` | `string` \| `false` | Key for word-by-word accept. `false` disables it. |
| `filetypes` | `string[]` \| `nil` | Allow-list, e.g. `{ "python", "lua" }`. `nil` means every normal buffer. |
| `show_hints` | `boolean` \| `table` | Hint chrome. `false` hides it; a table hides one surface. |
| `sidecar_cmd` | `string[]` | How the Python sidecar launches. Override only for unusual setups. |

**Full reference** → [docs/configuration.md](./docs/configuration.md): what each
option does, why `debounce` is usually overridden, and which hint surface you
actually want to keep.

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

```mermaid
flowchart LR
    NV["<b>Neovim</b><br/><code>lua/neocursor</code><br/>ghost text · diffs · owns Tab"]
    SC["<b>sidecar.py</b><br/>reads your Cursor session<br/>forges the checksum"]
    CU["<b>Cursor StreamCpp</b><br/><code>api2.cursor.sh</code>"]

    NV -->|"buffer, cursor, edit history<br/>(JSON over stdio)"| SC
    SC -->|"Connect / protobuf over h2"| CU
    CU -.->|"streamed edits<br/>+ next-jump target"| SC
    SC -.->|"JSON"| NV
```

The sidecar reads your local Cursor session, speaks the exact `StreamCpp` call
Cursor's own client makes, and streams back the edit sequence plus the next
cursor-jump target. Your token never leaves the machine, and the Lua side never
touches the network — that boundary is deliberate.

See [`NOTICE`](./NOTICE) for rendering-technique attribution.

---

## Troubleshooting

Start with `:NeocursorDebug` (resolved config, sidecar state, last error) and
`:NeocursorLog` (live event stream). Between them, most problems name themselves.

**Full guide** → [docs/troubleshooting.md](./docs/troubleshooting.md): Cursor
can't be found, the sidecar won't start, no suggestions appear, `<Tab>` does
nothing, and what to include in a bug report.

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
