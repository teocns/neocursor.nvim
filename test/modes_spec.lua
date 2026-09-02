-- Insert-only spec: a suggestion never outlives insert mode, and HOW you leave
-- decides whether it counts. Run from the repo root:
--   nvim --headless -u NONE -c "luafile test/modes_spec.lua"
--
-- flow_spec.lua blocks the main thread inside feedkeys(..., "x!"), which runs
-- the insert loop and nothing else. Everything asserted here happens AFTER
-- insert ends — a reply landing in normal mode, the ModeChanged that Neovim
-- defers past a <C-c> interrupt until normal_check — and that only runs when
-- Neovim's own main loop is in charge. So this script installs a timer chain,
-- returns, and drives the editor with nvim_input exactly the way a terminal
-- does: <C-c> in particular arrives as the real interrupt (got_int), the path
-- that fires neither InsertLeave nor a synchronous ModeChanged.
local root = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":h:h")
vim.opt.rtp:prepend(root)
vim.opt.swapfile = false
vim.opt.showmode = false -- "-- INSERT --" would land in the spec's stdout
io.stdout:setvbuf("no")

local failed = 0
local function check(desc, got, want)
  local ok = vim.deep_equal(got, want)
  if not ok then failed = failed + 1 end
  io.stdout:write(("%s %s%s\n"):format(ok and "ok  " or "FAIL", desc,
    ok and "" or ("  got=" .. vim.inspect(got) .. "  want=" .. vim.inspect(want))))
end

local nc = require("neocursor")
local preview = require("neocursor.preview")
nc.setup({
  debounce = 30,
  sidecar_cmd = { vim.fn.executable("python3") == 1 and "python3" or "python", root .. "/test/fake_sidecar.py" },
})

vim.cmd("edit " .. root .. "/test/spec_scratch.py")
local seed = { "line1 = 1", "line2 = 2", "line3 = 3", "line4 = 4", "line5 = 5" }
local function reseed()
  vim.api.nvim_buf_set_lines(0, 0, -1, false, seed)
  vim.api.nvim_win_set_cursor(0, { 1, 0 })
end

local function input(keys) vim.api.nvim_input(keys) end
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
local function mode() return vim.api.nvim_get_mode().mode end
-- everything neocursor has painted: the suggestion namespace plus the jump pill
local function painted()
  return #vim.api.nvim_buf_get_extmarks(0, preview.namespace(), 0, -1, {})
    + #vim.api.nvim_buf_get_extmarks(0, preview.prediction_namespace(), 0, -1, {})
end
-- a log line matching `pat` appended after the `since` snapshot (#log_lines)
local function logged(pat, since)
  local lines = nc._log_lines()
  for i = since + 1, #lines do
    if lines[i]:find(pat, 1, true) then return true end
  end
  return false
end
local function log_mark() return #nc._log_lines() end

-- Round 1: the reply that lands AFTER <Esc>. The request leaves on the
-- debounce, the fake answers 300ms later, and <Esc> falls in between. That
-- reply used to be painted into normal mode — a diff labelled "<Tab> accept ·
-- <Esc> dismiss" that neither key could reach, both being insert mappings (#10).
-- It must be dropped, and dropped for the right reason: the buffer didn't
-- change, the mode did.
local function round1(done)
  reseed()
  local mark = log_mark()
  poll(function() return logged("REQ", mark) end, 5000, function()
    input("<Esc>") -- the reply is now in flight; 300ms RTT keeps it there
    poll(function() return logged("DROP", mark) or nc.has_suggestion() end, 5000, function()
      check("reply after <Esc> is not painted", nc.has_suggestion(), false)
      check("nothing on screen after the drop", painted(), 0)
      check("dropped for mode, not staleness", logged("outside insert", mark), true)
      check("editor is in normal mode", mode(), "n")
      done()
    end, function()
      check("reply after <Esc> reaches the renderer at all", false, true)
      done()
    end)
  end, function()
    check("request sent (round 1)", false, true)
    done()
  end)
  input("A1")
end

-- Round 2: <C-c>. Unmapped, it is an interrupt, not a keypress: InsertLeave
-- never fires (:h i_CTRL-C) and ModeChanged is skipped while got_int is set,
-- then fired from normal_check once the interrupt is cleared — before any
-- other key. A visible suggestion must be gone by then, and it must count:
-- <C-c> is how a lot of people say <Esc>.
local function round2(done)
  reseed()
  local mark = log_mark()
  poll(nc.has_suggestion, 5000, function()
    check("suggestion arrives (round 2)", true, true)
    poll(function() return not nc.has_suggestion() end, 2000, function()
      check("<C-c> clears the suggestion before any other key", painted(), 0)
      check("<C-c> lands in normal mode", mode(), "n")
      check("<C-c> counts as a dismiss, like <Esc>", logged("DISMISS", mark), true)
      done()
    end, function()
      check("<C-c> clears the suggestion before any other key", nc.has_suggestion(), false)
      done()
    end)
    input("<C-c>") -- last statement: this sets got_int for the rest of the tick
  end, function()
    check("suggestion arrives (round 2)", false, true)
    input("<Esc>")
    done()
  end)
  input("A2")
end

-- Round 3: <C-o> is a detour, not a no. One normal command, then straight back
-- into insert. The display clears while the command runs (it may edit the
-- buffer under the suggestion), but nothing is filed against the edit, so the
-- return trip's fresh request re-offers it. <Esc> afterwards still counts.
local function round3(done)
  reseed()
  poll(nc.has_suggestion, 5000, function()
    check("suggestion arrives (round 3)", true, true)
    local mark = log_mark()
    input("<C-o>zz")
    poll(function() return not nc.has_suggestion() end, 2000, function()
      check("<C-o> clears the display", painted(), 0)
      check("<C-o> is not filed as a dismiss", logged("DISMISS", mark), false)
      poll(nc.has_suggestion, 5000, function()
        check("suggestion returns after the detour", mode(), "i")
        check("still not filed as a dismiss", logged("DISMISS", mark), false)
        input("<Esc>")
        poll(function() return not nc.has_suggestion() end, 2000, function()
          check("<Esc> after the detour still counts", logged("DISMISS", mark), true)
          check("nothing on screen after <Esc>", painted(), 0)
          done()
        end, function()
          check("<Esc> after the detour clears", nc.has_suggestion(), false)
          done()
        end)
      end, function()
        check("suggestion returns after the detour", false, true)
        input("<Esc>")
        done()
      end)
    end, function()
      check("<C-o> clears the display", nc.has_suggestion(), false)
      input("<Esc>")
      done()
    end)
  end, function()
    check("suggestion arrives (round 3)", false, true)
    input("<Esc>")
    done()
  end)
  input("A3")
end

local function finish()
  io.stdout:write(failed == 0 and "ALL PASS\n" or (failed .. " FAILURES\n"))
  vim.cmd(failed == 0 and "qall!" or "cquit!")
end

-- hand control to the main loop; each round runs to completion before the next
later(50, function()
  round1(function()
    later(50, function()
      round2(function()
        later(50, function()
          round3(finish)
        end)
      end)
    end)
  end)
end)
