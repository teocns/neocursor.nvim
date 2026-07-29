# Installation

[← back to README](../README.md)

The [README](../README.md#installation) covers the two canonical setups. This
page collects the variants: full vim.pack parity, coexisting with a completion
plugin, and pinning a version.

---

## Contents

- [What the lazy.nvim spec actually does](#what-the-lazynvim-spec-actually-does)
- [vim.pack: full parity with the lazy.nvim spec](#vimpack-full-parity-with-the-lazynvim-spec)
- [Letting nvim-cmp / blink.cmp own `<Tab>`](#letting-nvim-cmp--blinkcmp-own-tab)
- [Pinning a version](#pinning-a-version)

---

## What the lazy.nvim spec actually does

```lua
{
  "teocns/neocursor.nvim",
  event = "InsertEnter",
  build = 'uv run --with "httpx[http2]" python -c "import httpx"',
  opts = {},
}
```

Three things worth knowing, because the vim.pack equivalent has to reproduce
them by hand:

- **`event = "InsertEnter"`** defers startup until you first enter insert mode.
  Nothing is spawned while you're just reading files.
- **`build`** pre-warms the sidecar's Python dependencies at install time, so
  the first suggestion isn't waiting on a download. The double quotes matter —
  they let both `cmd.exe` and `sh` parse the argument.
- **`opts = {}`** calls `setup()` with defaults. There is nothing you're
  required to configure.

---

## vim.pack: full parity with the lazy.nvim spec

The minimal form is in the README. This reproduces the pre-warm and the lazy
start:

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

> `vim.pack` is built into Neovim ≥ 0.12. On 0.10–0.11, use a plugin manager.

---

## Letting nvim-cmp / blink.cmp own `<Tab>`

By default neocursor maps `<Tab>` in insert mode. If another plugin already
owns it, set `map_tab = false` and call into neocursor from your own handler:

```lua
{ "teocns/neocursor.nvim", event = "InsertEnter", opts = { map_tab = false } }
```

```lua
-- in your <Tab> mapping, try neocursor first:
if require("neocursor").accept() then return end
-- …otherwise let cmp / blink / your snippet engine handle it
```

`accept()` returns `true` if it consumed the key — there was a suggestion to
accept, an edit to jump to, or a chain to advance — and `false` if there was
nothing pending. That makes it safe as the first branch: when neocursor has
nothing to offer, your existing behavior is untouched.

Not sure who currently owns the key? `:verbose imap <Tab>` names the file that
mapped it last.

---

## Pinning a version

Track tagged releases instead of `main`:

```lua
{ "teocns/neocursor.nvim", version = "*" }
```

With vim.pack, `version` takes a tag, branch, commit hash, or a
`vim.version.range()`:

```lua
vim.pack.add {
  { src = "https://github.com/teocns/neocursor.nvim", version = vim.version.range "*" },
}
```

This is a beta and `main` moves; pinning is reasonable if you'd rather adopt
changes deliberately. See [releases](https://github.com/teocns/neocursor.nvim/releases).
