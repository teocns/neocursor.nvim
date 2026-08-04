# Configuration

[← back to README](../README.md)

Every option is optional. The [README](../README.md#configuration) has the
summary table; this page is the full reference.

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

`:NeocursorDebug` prints the resolved configuration, which is the fastest way to
confirm an option actually took effect.

---

## Contents

- [`debounce`](#debounce)
- [`map_tab`](#map_tab)
- [`map_partial`](#map_partial)
- [`filetypes`](#filetypes)
- [`show_hints`](#show_hints)
- [`sidecar_cmd`](#sidecar_cmd)

---

## `debounce`

`number` — default `250`

Milliseconds of idle time before a request goes out.

**This is usually overridden.** neocursor pulls Cursor's own `CppConfig` at
startup and adopts its debounce, so the value you set here is a fallback used
until that arrives (and if the fetch fails). Matching Cursor's timing is the
point — the plugin aims for parity, not for being faster than the real thing.

---

## `map_tab`

`boolean` — default `true`

Whether neocursor maps `<Tab>` in insert mode.

Set to `false` when nvim-cmp, blink.cmp, or a snippet engine already owns the
key, then call `require("neocursor").accept()` from your own handler. Full
pattern: [Installation](./installation.md#letting-nvim-cmp--blinkcmp-own-tab).

---

## `map_partial`

`string` or `false` — default `"<M-Right>"`

Key for accepting the current suggestion one word at a time, rather than all of
it. Useful when a completion is right for the first few words and wrong after.

Pass a different keystring to remap it, or `false` to leave the key unmapped.

---

## `filetypes`

`string[]` or `nil` — default `nil`

Allow-list of filetypes. `nil` means every normal buffer.

```lua
filetypes = { "python", "lua", "typescript" }
```

Special buffers — anything with a non-empty `buftype`, such as terminals, help
windows and file pickers — are always skipped regardless of this setting.
`:NeocursorDebug` reports `attach ok` for the current buffer.

---

## `show_hints`

`boolean` or `table` — default `true`

Controls the two labels neocursor paints. **Suggestions are never affected** —
ghost text, diffs, and every `<Tab>` behavior are identical either way. This is
purely what you see.

| Surface | Looks like | Marks | Hiding it costs |
|---|---|---|---|
| `edit` | `⟪neocursor · <Tab> accept · <Esc> dismiss⟫` | a pending edit | the diff still shows the change, but `<Esc>` stops advertising itself |
| `prediction` | `⟪<Tab> → L42⟫` | a jump target | the only on-screen sign a jump is queued |

```lua
show_hints = true                     -- default: both visible
show_hints = false                    -- hide both
show_hints = { edit = false }         -- hide the label, keep the jump pill
show_hints = { prediction = false }   -- hide the pill, keep the label
```

An omitted key in the table form defaults to visible, so `{ edit = false }` and
`{ edit = false, prediction = true }` are equivalent.

### Before you hide the prediction pill

The two surfaces are not symmetrical. The `edit` label is mostly decoration —
the diff underneath already tells you what will happen, though the label is also
where `<Esc> dismiss` is advertised. The `prediction` pill is the *only*
indication that a jump is queued; hide it and `<Tab>` will still jump, you just
won't know where until it lands.

If you want a quieter buffer without losing that, hide the label and keep the
pill:

```lua
show_hints = { edit = false }
```

---

## `sidecar_cmd`

`string[]` — default `{ "uv", "run", "--with", "httpx[http2]" }`

How the Python sidecar is launched. The plugin appends the script path, so this
is the prefix — interpreter and dependency handling only.

Override this only for unusual Python setups (a vendored interpreter, an
air-gapped machine with deps pre-installed). If suggestions stop working after
changing it, clear the override and confirm the default works before debugging
further — see [Troubleshooting](./troubleshooting.md#the-sidecar-wont-start).
