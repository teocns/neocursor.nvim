# Contributing to neocursor.nvim

Issues and pull requests are welcome. This is a beta chasing 1:1 parity with
Cursor's Tab, so bug reports about behavior that differs from Cursor are
especially useful.

---

## Reporting a bug

Two commands make almost every report actionable — please include their output:

```vim
:NeocursorDebug
```

Resolved config, sidecar state, last error, and whether the current buffer is
eligible. **Redact nothing but paths you consider private** — it prints no token.

```sh
uv run cursor_paths.py   # in the plugin directory
```

Required for anything path- or auth-related. It prints every candidate location
checked and which one won, which usually identifies the problem outright.

Also helpful: your OS, how Cursor was installed (official build, Flatpak, Snap,
AUR, WSL-side), Neovim version (`nvim --version`), and `:NeocursorLog` output if
the failure is intermittent.

---

## Project layout

```
lua/neocursor/
  init.lua        state machine, <Tab> handling, sidecar protocol, context collection
  preview.lua     ghost text + diff rendering (extmarks, virt_text / virt_lines)
  heuristics.lua  suppression rules pulled live from Cursor's CppConfig

sidecar.py        stdio bridge: Neovim JSON ⇄ Cursor StreamCpp (Connect/protobuf over h2)
cursor_paths.py   platform path resolution — also runnable standalone as a diagnostic

docs/             installation variants, full config reference, troubleshooting
demo/             the recording harness that generates assets/demo.gif
test/             specs; all of these run in CI on macOS, Linux and Windows
poc/              protocol spikes kept for reference; never loaded at runtime
```

The README is the storefront — pitch, install, usage, and a summary of each
option. Anything longer than a screen belongs in `docs/`, linked from the
matching README section. `test/docs_links.py` enforces that those links keep
resolving.

The Lua side never talks to the network — it speaks line-delimited JSON to the
sidecar over stdio, and the sidecar owns everything about Cursor's protocol.
Keep that boundary intact.

---

## Running the tests

Requires `uv`, Python 3.12+, and Neovim on `PATH`. No test framework to install:
the specs are plain scripts that exit non-zero on failure.

```sh
# every relative link and anchor across README + docs/ resolves
python test/docs_links.py

# path resolution across all three platform layouts (synthesized, no Cursor needed)
python test/paths_spec.py

# sidecar startup contract against a synthesized Cursor install
python test/handshake_spec.py

# the tab-tab-tab flow: canned sidecar, real jobstart plumbing, live insert session
nvim --headless -u NONE -c "luafile test/flow_spec.lua"

# hint chrome: rendering + show_hints normalization
nvim --headless -u NONE -c "luafile test/hints_spec.lua"

# the same behavioral suite with hint chrome disabled — chrome must never
# change behavior, so these assertions must pass identically
NEOCURSOR_SPEC_NO_HINTS=1 nvim --headless -u NONE -c "luafile test/flow_spec.lua"

# the demo harness, headless: pilots a real Neovim through jump → accept →
# jump → accept and fails if any beat lands wrong (needs tmux)
DEMO_ATTACH=0 ./demo/drive.sh
```

None of them require you to be signed into Cursor; they synthesize an install
(`test/fake_cursor_home.py`) and use a canned sidecar (`test/fake_sidecar.py`).
The live backend is deliberately out of scope for CI — it's httpx over TLS, not
something a runner can meaningfully exercise.

### What CI runs

Every push and PR runs the full suite on `ubuntu-latest`, `windows-latest` and
`macos-latest`. Platform matters here more than in most plugins: neocursor reads
Cursor's session off disk, and that path moves per OS.

The demo harness also runs headlessly on Linux. It is there so that a change to
the tab flow breaks the build rather than quietly leaving a README GIF that
shows behavior the plugin no longer has.

---

## Regenerating the demo GIF

`assets/demo.gif` is a build artifact, not a hand-recorded file. Rebuild it with:

```sh
./demo/record.sh          # needs vhs, tmux, neovim, python3
```

The recording uses a canned backend, so it works without a Cursor subscription
and produces essentially the same output every run — which is what makes it
reviewable in a pull request instead of an opaque binary.

Change what happens on screen in `demo/drive.sh` (keystrokes and pacing) or
`demo/scenario.py` (the code being edited). Do not change the terminal geometry
casually: the tape's `906x520` is chosen to yield exactly the 84x20 pane
`drive.sh` pins tmux to, and anything else reflows the code. `demo/README.md`
explains the design and the traps in more detail.

---

## Pull requests

- **One concern per PR.** A rendering fix and a protocol change are two PRs.
- **Add a spec.** If a bug could regress silently, it needs an assertion. New
  options should cover both the default and the non-default path.
- **Keep the default path unchanged** unless that *is* the change, and say so
  loudly in the description if it is.
- **Match the surrounding style.** The codebase comments the *why* — especially
  where behavior mirrors a specific Cursor mechanism — and skips narrating the
  *what*. Follow the file you're editing.

### Commit messages

Conventional prefixes, lowercase subject, em-dash for elaboration:

```
feat: show_hints — opt out of the hint chrome
fix: stop the ghost surviving a buffer switch
docs: add vim.pack install instructions
test: set USERPROFILE alongside HOME in the path spec
chore: bump the CI matrix to Neovim stable
```

Reference the issue in the body (`Closes #4`) rather than the subject line.

---

## Scope

neocursor is an interoperability layer, not a model host. Changes that add a
second backend, bundle credentials, or redistribute Cursor source are out of
scope — see [Legal](./README.md#legal). Anything that brings the plugin closer
to Cursor's actual Tab behavior is in scope by default.
