-- Headless behavioral spec for the tab-tab flow. Run from the repo root:
--   nvim --headless -u NONE -c "luafile test/flow_spec.lua"
--
-- Structure: the main thread blocks inside feedkeys(..., "x!") — a live insert
-- session whose vgetc wait runs the event loop, exactly like interactive use.
-- Timers drive the keystrokes and assertions, and end each round with <Esc>,
-- which unblocks the main thread. Asserted here are the parts that regressed:
-- suggestions surviving the echo events of our own apply/jump, two-phase
-- jump→accept, chain advance, and rapid tab-tab-tab never leaking a literal
-- <Tab> into the buffer.
-- an accept never copying a buffer-local 'undolevels' into the global option.
local root = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":h:h")
vim.opt.rtp:prepend(root)
vim.opt.swapfile = false -- a stale swap prompt would hang a headless run
io.stdout:setvbuf("no")

local failed = 0
local function check(desc, got, want)
  local ok = vim.deep_equal(got, want)
  if not ok then failed = failed + 1 end
  io.stdout:write(("%s %s%s\n"):format(ok and "ok  " or "FAIL", desc,
    ok and "" or ("  got=" .. vim.inspect(got) .. "  want=" .. vim.inspect(want))))
end

local nc = require("neocursor")
-- NEOCURSOR_SPEC_NO_HINTS=1 reruns this whole spec with the hint chrome off.
-- Hiding hints is display-only, so every behavioral assertion below — jump,
-- accept, chain advance — must hold identically in both modes.
local no_hints = os.getenv("NEOCURSOR_SPEC_NO_HINTS") == "1"
io.stdout:write(no_hints and "-- show_hints = false --\n" or "-- show_hints = default --\n")
nc.setup({
  debounce = 30,
  show_hints = not no_hints,
  -- "python3" doesn't exist on Windows; the canned sidecar is stdlib-only
  sidecar_cmd = { vim.fn.executable("python3") == 1 and "python3" or "python", root .. "/test/fake_sidecar.py" },
})

vim.cmd("edit " .. root .. "/test/spec_scratch.py") -- named file, normal buftype
local seed = { "line1 = 1", "line2 = 2", "line3 = 3", "line4 = 4", "line5 = 5" }
vim.api.nvim_buf_set_lines(0, 0, -1, false, seed)

local function feed(keys) -- blocking: runs the insert session until <Esc>
  vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes(keys, true, false, true), "x!", false)
end
local function input(keys) -- queued: consumed by the blocked insert loop
  vim.api.nvim_input(keys)
end
local function later(ms, fn) vim.defer_fn(fn, ms) end
local function poll(cond, timeout_ms, on_ok, on_fail)
  local waited = 0
  local function tick()
    if cond() then return on_ok() end
    waited = waited + 20
    if waited >= timeout_ms then return on_fail() end
    later(20, tick)
  end
  tick()
end
local function line(n) return vim.api.nvim_buf_get_lines(0, n - 1, n, false)[1] end
local function buf_text() return table.concat(vim.api.nvim_buf_get_lines(0, 0, -1, false), "\n") end

-- Round 1: type → suggestion → Tab (accept) → Tab (jump) → Tab (accept),
-- pausing between presses so each one's echo events fire before we assert.
local function round1()
  poll(nc.has_suggestion, 3000, function()
    check("suggestion arrives after typing", true, true)
    input("<Tab>")
    later(120, function()
      check("accept applies edit 1", line(1), "line1 = 100")
      check("chain edit 2 survives echo events", nc.has_suggestion(), true)
      input("<Tab>")
      later(120, function()
        check("jump moves cursor to edit 2", vim.api.nvim_win_get_cursor(0)[1], 4)
        check("suggestion survives jump echo", nc.has_suggestion(), true)
        input("<Tab>")
        later(120, function()
          check("accept applies edit 2", line(4), "line4 = 400")
          check("no literal <Tab> leaked into buffer", buf_text():find("\t") == nil, true)
          input("<Esc>")
        end)
      end)
    end)
  end, function()
    check("suggestion arrives after typing", false, true)
    input("<Esc>")
  end)
end

-- Round 2: the whole tab-tab-tab burst in one keystream. Under a deferred
-- accept this slipped literal tabs into the buffer mid-chain.
local function round2()
  poll(nc.has_suggestion, 3000, function()
    check("suggestion arrives (round 2)", true, true)
    input("<Tab><Tab><Tab>")
    later(200, function()
      check("rapid tab-tab-tab lands both edits", { line(1), line(4) },
        { "line1 = 100", "line4 = 400" })
      check("rapid gesture leaks no literal <Tab>", buf_text():find("\t") == nil, true)
      input("<Esc>")
    end)
  end, function()
    check("suggestion arrives (round 2)", false, true)
    input("<Esc>")
  end)
end

-- Round 3: pure cursor movement must NOT kill a shown suggestion — the backend
-- won't reliably re-offer an edit after a 1-column move, so clearing on
-- movement loses suggestions permanently (the CLAUDE.md field failure).
local function round3()
  poll(nc.has_suggestion, 5000, function()
    check("suggestion arrives (round 3)", true, true)
    input("<Left>")
    later(100, function() -- asserted inside the refetch window: retention, not resurrection
      check("suggestion survives cursor movement", nc.has_suggestion(), true)
      input("<Tab>")
      later(150, function()
        check("Tab still accepts after movement", line(1), "line1 = 100")
        input("<Esc>")
      end)
    end)
  end, function()
    check("suggestion arrives (round 3)", false, true)
    input("<Esc>")
  end)
end

-- Round 4: the continuous flow — chain exhausted → server's prediction target
-- becomes the "Tab →" hint → Tab jumps there and retriggers.
local function round4()
  poll(nc.has_suggestion, 5000, function()
    check("suggestion arrives (round 4)", true, true)
    input("<Tab><Tab><Tab>") -- accept L1, jump L4, accept L4 → chain exhausted
    later(200, function()
      check("prediction hint appears after chain", nc.has_prediction(), true)
      input("<Tab>")
      later(150, function()
        check("Tab jumps to predicted line", vim.api.nvim_win_get_cursor(0)[1], 2)
        check("prediction consumed by jump", nc.has_prediction(), false)
        input("<Esc>")
      end)
    end)
  end, function()
    check("suggestion arrives (round 4)", false, true)
    input("<Esc>")
  end)
end

-- Round 5: word-level partial accept of an inline ghost; consuming the last
-- fragment walks the chain like a full accept.
local function round5()
  poll(nc.has_suggestion, 5000, function()
    check("inline ghost arrives (round 5)", true, true)
    input("<M-Right>")
    later(150, function()
      check("partial accept completes the line", line(1), "line1 = 100")
      check("chain advances after ghost consumed", nc.has_suggestion(), true)
      input("<Esc>")
    end)
  end, function()
    check("inline ghost arrives (round 5)", false, true)
    input("<Esc>")
  end)
end

-- Round 6: panel buffers (diffview/mason/neogit-style) set buffer-local
-- 'undolevels' to -1/0. Accepting must close the undo block WITHOUT copying
-- that local value into the global option — a leak disables undo everywhere.
local function round6()
  poll(nc.has_suggestion, 3000, function()
    check("suggestion arrives (round 6)", true, true)
    local before = vim.api.nvim_get_option_value("undolevels", { scope = "global" })
    input("<Tab>")
    later(120, function()
      check("accept applies edit with local undolevels", line(1), "line1 = 100")
      local after = vim.api.nvim_get_option_value("undolevels", { scope = "global" })
      check("accept leaves global 'undolevels' unchanged", after, before)
      vim.cmd("setlocal undolevels<") -- drop the buffer-local override
      input("<Esc>")
    end)
  end, function()
    check("suggestion arrives (round 6)", false, true)
    input("<Esc>")
  end)
end

vim.api.nvim_win_set_cursor(0, { 1, 0 })
later(50, round1)
feed("Ax") -- blocks while round1 runs; returns on its <Esc>

vim.api.nvim_buf_set_lines(0, 0, -1, false, seed)
vim.api.nvim_win_set_cursor(0, { 1, 0 })
later(50, round2)
feed("Ay") -- blocks while round2 runs; returns on its <Esc>

vim.api.nvim_buf_set_lines(0, 0, -1, false, seed)
vim.api.nvim_win_set_cursor(0, { 1, 0 })
later(50, round3)
feed("Az") -- blocks while round3 runs; returns on its <Esc>

vim.api.nvim_buf_set_lines(0, 0, -1, false, seed)
vim.api.nvim_win_set_cursor(0, { 1, 0 })
later(50, round4)
feed("Aw") -- blocks while round4 runs; returns on its <Esc>

vim.api.nvim_buf_set_lines(0, 0, -1, false, seed)
vim.api.nvim_win_set_cursor(0, { 1, 0 })
later(50, round5)
feed("A0") -- "line1 = 10" is a prefix of the fake's edit → inline ghost "0"

vim.api.nvim_buf_set_lines(0, 0, -1, false, seed)
vim.api.nvim_win_set_cursor(0, { 1, 0 })
vim.api.nvim_set_option_value("undolevels", -1, { buf = 0 }) -- what panel buffers do
later(50, round6)
feed("A6") -- blocks while round6 runs; returns on its <Esc>

io.stdout:write(failed == 0 and "ALL PASS\n" or (failed .. " FAILURES\n"))
vim.cmd(failed == 0 and "qall!" or "cquit!")
