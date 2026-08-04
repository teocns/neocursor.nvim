-- neocursor.nvim — Cursor Tab, in neovim.
-- Talks to the Python sidecar over stdio; renders the suggested edit as inline
-- ghost text (see preview.lua). <Tab> applies it.

local M = {}

local preview = require("neocursor.preview")
local heuristics = require("neocursor.heuristics")
local uv = vim.uv or vim.loop

local state = {
  job = nil,
  ready = false,
  seq = 0,        -- request counter; replies with a stale id are ignored
  partial = "",   -- stdout line-reassembly buffer
  timer = nil,
  suggestion = nil, -- { bufnr, start0, end0_excl, lines, mode, buf_lines }
  cfg = nil,
  seen = nil,     -- { buf, tick, row, col } last observed state; our own edits' echoes match it
  req = nil,      -- { bufnr, tick } buffer identity+version of the in-flight request
  req_ticks = {}, -- [id] = { bufnr, tick } per request, for rescuing late replies
  last_edit_at = nil, -- os.time() of the last real text edit (Cursor's lastEditTime)
  last_line = nil,    -- last cursor row seen, to detect line changes (Cursor's lastLine)
  queue = nil,     -- { list = {edit,...}, idx } multi-edit chain from one response
  prediction = nil, -- { path, line } next-jump target (cursorPredictionTarget)
  pred_rejects = {}, -- [path:line] = {count, ts} — Cursor: 30s TTL, max 5, mute at 2
  viewed = {},    -- [bufnr] = ms of last BufEnter (recency for additionalFiles)
  dbase = {},     -- [bufnr] = { path, text } baseline snapshot for diffing
  dtraj = {},     -- [path]  = { {diff, ts}, ... } committed edit trajectory
  rejects = {},   -- [key]   = times the user dismissed this exact suggestion
  dismissed = 0,  -- dismissals since the last accept (Cursor:
                  -- numberOfClearedSuggestionsSinceLastAccept — see the note
                  -- on rejected_too_many for why we count dismissals, not clears)
  log = {},       -- ring buffer of event strings for :NeocursorLog
  log_buf = nil,
  log_dirty = false,
  awaiting = false, -- a request is in flight (sent, no reply yet) — dashboard phase
  stderr_tail = {}, -- last stderr lines, replayed if the sidecar dies before ready
}

-- Hint chrome — the ⟪neocursor · <Tab> …⟫ label on an edit and the ⟪<Tab> → L42⟫
-- pill at a jump target — is display-only. Hiding it changes what you see, never
-- what <Tab> does, so every gate below still fires exactly as it did.
local HINTS_ALL = { edit = true, prediction = true }

--- show_hints: true/nil = all, false = none, table = per-surface.
local function normalize_hints(v)
  if v == false then return { edit = false, prediction = false } end
  if type(v) == "table" then
    return { edit = v.edit ~= false, prediction = v.prediction ~= false }
  end
  return { edit = true, prediction = true }
end

-- state.cfg is nil until setup() runs; default to showing everything.
local function hints()
  return (state.cfg and state.cfg.show_hints) or HINTS_ALL
end

local function plugin_root()
  local src = debug.getinfo(1, "S").source:sub(2)
  return vim.fn.fnamemodify(src, ":h:h:h") -- .../lua/neocursor/init.lua -> root
end

local function clear_suggestion()
  if state.suggestion then
    preview.clear(state.suggestion.bufnr)
    state.suggestion = nil
  end
  state.queue = nil -- abandon any pending multi-edit chain
end

local function buf_relpath(b)
  local n = vim.api.nvim_buf_get_name(b)
  if n == "" then return nil end
  return vim.fn.fnamemodify(n, ":.")
end

local function buf_text(b)
  return table.concat(vim.api.nvim_buf_get_lines(b, 0, -1, false), "\n")
end

-- Relative "N seconds/minutes ago" for the dashboard's clock fields.
local function ago(t)
  if not t then return "never" end
  local d = os.time() - t
  if d <= 0 then return "now" end
  if d < 60 then return d .. "s ago" end
  return math.floor(d / 60) .. "m ago"
end

-- Persistent debug surface rendered by :NeocursorLog. The top block is a LIVE
-- dashboard of the state machine — the phase we're in, what <Tab> would do at
-- this instant (Cursor's cursorAtInlineEdit rule), the self-echo guard, the
-- prediction ledger, the debounce timer — so the *current* dynamics are legible
-- without reading the history backwards. Below the separator: the event log,
-- newest first, so the freshest line sits right under the dashboard. Both the
-- dashboard and the latest events stay on screen at any window height (the view
-- is pinned to the top), which is why the log is reversed rather than tailed.
local function log_refresh()
  state.log_dirty = false
  local buf = state.log_buf
  if not (buf and vim.api.nvim_buf_is_valid(buf)) then return end
  local c = state.cfg or {}
  local s = state.suggestion

  -- what a <Tab> press would do RIGHT NOW (inlined cursorAtInlineEdit)
  local tab_now
  if s and vim.api.nvim_buf_is_valid(s.bufnr) then
    if vim.api.nvim_get_current_buf() ~= s.bufnr then
      tab_now = "— other buf"
    else
      local row0 = vim.api.nvim_win_get_cursor(0)[1] - 1
      local at = (s.end0_excl <= s.start0) and (row0 == s.start0)
        or (row0 >= s.start0 and row0 < s.end0_excl)
      tab_now = at and "ACCEPT edit" or ("JUMP → L" .. (s.start0 + 1))
    end
  elseif state.prediction then
    tab_now = "PREDICT jump"
  else
    tab_now = "literal ⇥"
  end

  -- which node of the pipeline we're sitting in
  local phase
  if s then phase = state.queue and "CHAINING" or "SHOWING"
  elseif state.timer then phase = "DEBOUNCING"
  elseif state.awaiting then phase = "IN-FLIGHT"
  else phase = "IDLE" end

  local pred = "none"
  if state.prediction then
    local p = state.prediction
    local r = state.pred_rejects[(p.path or "") .. ":" .. tostring(p.line)]
    pred = ("%s:%s%s"):format(p.path or "·", tostring(p.line),
      r and (r.count >= 2 and "  ⌀muted" or ("  rej×" .. r.count)) or "")
  end

  local sidecar = state.ready and "● ready" or (state.job and "◐ starting" or "○ down")
  local sugg = s and ("%s L%d · %d ln"):format(s.mode, s.start0 + 1, #s.lines) or "none"
  local chain = state.queue and (state.queue.idx .. "/" .. #state.queue.list) or "—"
  local seen = state.seen
    and ("L%d:%d ↻%s"):format(state.seen.row, state.seen.col, tostring(state.seen.tick))
    or "—"
  local fused = c.is_fused == nil and "?" or tostring(c.is_fused)

  local bar = string.rep("─", 58)
  local lines = {
    "┌" .. bar .. "┐",
    ("  phase   ▸ %-12s   sidecar   %s  (job %s)"):format(phase, sidecar, tostring(state.job or "-")),
    ("  TAB now ▸ %-12s   seq %d · last ok %s"):format(tab_now, state.seq, ago(state.last_ok_at)),
    ("  suggest   %-16s  debounce %sms · timer %s"):format(sugg, c.debounce or "?", state.timer and "ticking" or "idle"),
    ("  chain     %-16s  heur %d · excl %d · fused %s"):format(chain,
      c.heuristics and #c.heuristics or 0, c.exclude_patterns and #c.exclude_patterns or 0, fused),
    ("  predict   %-16s  guard(seen) %s"):format(pred, seen),
    ("  err %s · suppress %s · dismissed %d/%s%s"):format(
      tostring(state.last_error or "none"), tostring(state.last_suppressed or "none"),
      state.dismissed, tostring(c.max_cleared or 20),
      state.dismissed > (c.max_cleared or 20) and "  MUTED (accept one to resume)" or ""),
    "├─ log ─ newest first " .. string.rep("─", 37) .. "┤",
  }
  for i = #state.log, 1, -1 do lines[#lines + 1] = state.log[i] end

  vim.bo[buf].modifiable = true
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable = false
  for _, win in ipairs(vim.api.nvim_list_wins()) do
    if vim.api.nvim_win_get_buf(win) == buf then
      pcall(vim.api.nvim_win_set_cursor, win, { 1, 0 }) -- pin to top: dashboard always visible
    end
  end
end

local function log(line)
  state.log[#state.log + 1] = os.date("%H:%M:%S") .. "  " .. line
  if #state.log > 500 then table.remove(state.log, 1) end
  if not state.log_dirty then
    state.log_dirty = true
    vim.schedule(log_refresh)
  end
end

-- Tunables the sidecar fetched from Cursor's CppConfig (debounce, context
-- exclude-list, active heuristics, rejection threshold). Nil fields are left
-- at their defaults so a failed fetch degrades gracefully.
local function apply_config(cfg)
  if type(cfg.debounce) == "number" and cfg.debounce > 0 then state.cfg.debounce = cfg.debounce end
  if type(cfg.exclude_patterns) == "table" then state.cfg.exclude_patterns = cfg.exclude_patterns end
  if type(cfg.heuristics) == "table" then state.cfg.heuristics = cfg.heuristics end
  if type(cfg.reject_hard) == "number" then state.cfg.reject_hard = cfg.reject_hard end
  if type(cfg.max_cleared) == "number" then state.cfg.max_cleared = cfg.max_cleared end
  if type(cfg.is_fused) == "boolean" then state.cfg.is_fused = cfg.is_fused end
  log(("CONFIG  debounce=%sms heuristics=%d excludes=%d"):format(
    state.cfg.debounce, #state.cfg.heuristics, #state.cfg.exclude_patterns))
end

-- Is the cursor currently on the edit's target region? This is Cursor's
-- `cursorAtInlineEdit`: when false, <Tab> jumps here; when true, <Tab> accepts.
local function cursor_at(start0, end0_excl)
  local row0 = vim.api.nvim_win_get_cursor(0)[1] - 1
  if end0_excl <= start0 then return row0 == start0 end
  return row0 >= start0 and row0 < end0_excl
end

-- Record the buffer/cursor state our own edit or jump just produced. The
-- TextChangedI/CursorMovedI events it enqueues only fire after we return to the
-- main loop; they observe exactly this state and are swallowed by the autocmd's
-- duplicate check, so applying or jumping never clears the suggestion/chain it
-- just revealed. (A boolean guard can't do this — it's already reset by the
-- time those events fire.)
local function mark_seen(bufnr)
  local cur = vim.api.nvim_win_get_cursor(0)
  state.seen = {
    buf = bufnr,
    tick = vim.api.nvim_buf_get_changedtick(bufnr),
    row = cur[1],
    col = cur[2],
  }
end

-- Render one edit. If its text simply extends what the user has already typed
-- (prefix equals buffer content from the range start up to the cursor, nothing
-- meaningful after), show it as inline ghost text; otherwise a block diff.
-- Returns false if the edit is a no-op (identical to what's already there).
local function show_edit(edit)
  local bufnr = edit.bufnr
  local start0, end0_excl, lines = edit.start0, edit.end0_excl, edit.lines
  local cur = vim.api.nvim_win_get_cursor(0) -- { row1, col0 }
  local row1, col0 = cur[1], cur[2]
  local text = table.concat(lines, "\n")

  local cur_range = vim.api.nvim_buf_get_lines(bufnr, start0, end0_excl, false)
  if table.concat(cur_range, "\n") == text then return false end -- no-op

  local mode, ghost = "diff", nil
  -- inline only when the cursor sits inside the replaced range; a cursor past
  -- its end would make the "prefix" include lines the edit doesn't replace,
  -- and accepting would duplicate them
  if start0 <= row1 - 1 and row1 - 1 < end0_excl then
    local ok, prefix_lines = pcall(vim.api.nvim_buf_get_text, bufnr, start0, 0, row1 - 1, col0, {})
    local after = vim.api.nvim_get_current_line():sub(col0 + 1)
    if ok and after:match("^%s*$") then
      local prefix = table.concat(prefix_lines, "\n")
      if text:sub(1, #prefix) == prefix then
        local g = text:sub(#prefix + 1)
        if g ~= "" then mode, ghost = "inline", g end
      end
    end
  end

  state.suggestion = {
    bufnr = bufnr, start0 = start0, end0_excl = end0_excl, lines = lines, mode = mode,
    buf_lines = vim.api.nvim_buf_line_count(bufnr), -- re-anchors end0_excl as typing adds lines
  }
  if mode == "inline" then
    preview.inline(bufnr, row1 - 1, col0, ghost)
  else
    local at = cursor_at(start0, end0_excl)
    -- Advertise <Esc>, not <C-]>: leaving insert already dismisses (InsertLeave
    -- below files the rejection), so the label is true without mapping a key —
    -- and it names the one key every neovim user presses without thinking.
    local label = hints().edit
      and ((at and "<Tab> accept" or "<Tab> jump") .. " · <Esc> dismiss")
      or nil
    preview.diff(bufnr, start0, cur_range, lines, label)
  end
  log(("SHOW    %-6s L%d  (%d ln)"):format(mode, start0 + 1, #lines))
  return true
end

-- After applying the current edit, walk to the next one in the chain — locally,
-- no network. Adjust the line numbers of edits below by the applied line delta,
-- jump the cursor there, and render it. This is the "tab, tab, tab" loop.
local function advance_after_apply(applied)
  -- Every accept path lands here — Tab, word-at-a-time, and typing the ghost
  -- out in full — so this is the one place the churn budget refills.
  state.dismissed = 0
  local q = state.queue
  if not q then return end
  local delta = #applied.lines - (applied.end0_excl - applied.start0)
  q.idx = q.idx + 1
  if delta ~= 0 then
    for k = q.idx, #q.list do
      local e = q.list[k]
      if e.start0 >= applied.end0_excl then
        e.start0 = e.start0 + delta
        e.end0_excl = e.end0_excl + delta
      end
    end
  end
  -- Show the next edit in place; the cursor stays put, so the next <Tab> JUMPS
  -- to it (Cursor's cursorAtInlineEdit rule), and the <Tab> after that accepts.
  while q.idx <= #q.list do
    if show_edit(q.list[q.idx]) then return end
    q.idx = q.idx + 1 -- skip no-op edits
  end
  state.queue = nil -- chain exhausted
end

local function reject_key(path, edit)
  return path .. "@" .. edit.start0 .. ":" .. table.concat(edit.lines, "\n")
end

-- Lines the user just deleted (the newest diff's "-" lines), for the
-- reverting-user-change heuristic.
local function recently_removed(path)
  local traj = state.dtraj[path]
  if not traj or #traj == 0 then return nil end
  local set = {}
  for line in traj[#traj].diff:gmatch("[^\n]+") do
    if line:sub(1, 1) == "-" and line:sub(1, 3) ~= "---" then set[line:sub(2)] = true end
  end
  return set
end

-- Cursor-prediction rejection ledger, ported verbatim from their controller:
-- keyed path:line, 30s expiry, at most 5 entries (evict oldest), and a target
-- is only muted once it has been rejected twice (count >= 2).
local PRED_REJECT_TTL, PRED_REJECT_MAX = 30 * 1000, 5

local function pred_key(p) return (p.path or "") .. ":" .. tostring(p.line) end

local function record_pred_reject(p)
  local now = os.time() * 1000
  local r = state.pred_rejects[pred_key(p)]
  if r then
    r.count, r.ts = r.count + 1, now
  else
    state.pred_rejects[pred_key(p)] = { count = 1, ts = now }
  end
  local n, oldest, okey = 0, math.huge, nil
  for k, v in pairs(state.pred_rejects) do
    n = n + 1
    if v.ts < oldest then oldest, okey = v.ts, k end
  end
  if n > PRED_REJECT_MAX and okey then state.pred_rejects[okey] = nil end
end

local function pred_recently_rejected(p)
  local now = os.time() * 1000
  for k, v in pairs(state.pred_rejects) do
    if now - v.ts > PRED_REJECT_TTL then state.pred_rejects[k] = nil end
  end
  local r = state.pred_rejects[pred_key(p)]
  return r ~= nil and r.count >= 2
end

-- Cursor's hasRejectedTooManySuggestions. The per-suggestion ledger above only
-- catches the model REPEATING itself; this catches it being wrong in a new way
-- every time. Past the budget, stop volunteering — but only on the passive
-- triggers (entering insert, moving to another line). Typing still asks, which
-- is Cursor's split too: their content-change and linter-error paths never
-- consult this gate. Reset by accepting anything, or by leaving the buffer.
--
-- Cursor counts every clearSuggestions(); we count dismissals instead. Their
-- suggestion survives typing (isOnShortestEditPath), ours only survives it for
-- inline ghosts — a diff is dropped and refetched on each keystroke, so
-- counting clears here would mute after ~20 characters rather than ~20 ignored
-- suggestions. Same intent, adjusted for where the two renderers differ.
local function rejected_too_many()
  return state.dismissed > ((state.cfg and state.cfg.max_cleared) or 20)
end

-- Cursor's Escape is TIERED, and the tiers matter: their first press files the
-- suggestion as rejected and deliberately keeps the jump target alive (the
-- handler calls maybeShowHintLineWidget right after); only a second press, with
-- nothing showing, reaches clearCursorPrediction. Collapsing the two would mute
-- jump targets the user never actually said no to.
--
-- Tier 1 — file the visible edit as rejected and clear it. Returns false when
-- there was nothing to reject.
local function reject_suggestion()
  local s = state.suggestion
  if not s then return false end
  local key = reject_key(buf_relpath(s.bufnr) or "", s)
  state.rejects[key] = (state.rejects[key] or 0) + 1
  state.dismissed = state.dismissed + 1
  log(("DISMISS L%d  (rejected ×%d · %d/%s before mute)"):format(
    s.start0 + 1, state.rejects[key], state.dismissed,
    tostring((state.cfg and state.cfg.max_cleared) or 20)))
  clear_suggestion()
  return true
end

-- Tier 2 — reject the jump target itself (30s TTL, muted at 2).
local function reject_prediction(bufnr)
  if not state.prediction then return false end
  record_pred_reject(state.prediction)
  state.prediction = nil
  preview.clear_prediction(bufnr or 0)
  return true
end

-- Paint the "Tab →" hint at the prediction target (Cursor's hint widget).
-- Returns false when there is nothing worth jumping to (no prediction, or it
-- points at the line the cursor is already on).
local function show_prediction()
  local p = state.prediction
  if not (p and p.line) then return false end
  local bufnr = vim.api.nvim_get_current_buf()
  local rel = buf_relpath(bufnr)
  -- painting is optional (show_hints); the jump target itself is not, so the
  -- true/false this returns must stay the same either way
  local paint = hints().prediction
  if not paint then preview.clear_prediction(bufnr) end
  if (not p.path) or p.path == rel then
    local lc = vim.api.nvim_buf_line_count(bufnr)
    local row1 = math.min(math.max(p.line, 1), lc)
    if row1 == vim.api.nvim_win_get_cursor(0)[1] then return false end
    if paint then preview.prediction(bufnr, row1 - 1, "<Tab> → L" .. row1) end
  else
    -- cross-file target: anchor the hint at the cursor, name the destination
    local cur0 = vim.api.nvim_win_get_cursor(0)[1] - 1
    if paint then preview.prediction(bufnr, cur0, ("<Tab> → %s:%d"):format(p.path, p.line)) end
  end
  log(("PRED    → %s:%d"):format(p.path or "·", p.line))
  return true
end

-- Build the edit queue from a sidecar result and show the first showable edit.
local function render_result(res)
  local bufnr = vim.api.nvim_get_current_buf()
  -- the response was computed against the buffer as of send time; if the user
  -- switched buffers or typed since, its ranges no longer apply (a fresh
  -- request is already debounce-pending) — rendering it would misplace edits
  local rq = state.req
  if rq and (rq.bufnr ~= bufnr or vim.api.nvim_buf_get_changedtick(bufnr) ~= rq.tick) then
    log("DROP    stale response (buffer changed since request)")
    return
  end
  -- adopt this response's prediction target (or drop a stale/muted one)
  preview.clear_prediction(bufnr)
  local pred = res.prediction
  if pred and pred.line and not pred_recently_rejected(pred) then
    state.prediction = pred
  else
    state.prediction = nil
  end
  local edits_in = res.edits
  if not edits_in or #edits_in == 0 then
    if (res.text or "") == "" then
      -- an empty edit list can still carry a prediction: pure "Tab → there"
      if not show_prediction() then log("NOOP    empty response") end
      return
    end
    edits_in = { { text = res.text, range = res.range } } -- back-compat
  end
  local row1 = vim.api.nvim_win_get_cursor(0)[1]
  local list = {}
  for _, e in ipairs(edits_in) do
    local r = e.range
    local start1 = (r and r.start) or row1
    local end1 = (r and r.endInclusive) or row1
    list[#list + 1] = {
      bufnr = bufnr,
      start0 = math.max(0, start1 - 1),
      end0_excl = end1,
      lines = vim.split(e.text or "", "\n", { plain = true }),
    }
  end

  local path = vim.fn.expand("%:.")
  local first = list[1]
  local suppressed = heuristics.should_suppress(state.cfg.heuristics, {
    bufnr = bufnr, start0 = first.start0, end0_excl = first.end0_excl, lines = first.lines,
    recently_removed = recently_removed(path),
    rejections = state.rejects, key = reject_key(path, first), hard_reject = state.cfg.reject_hard,
  })
  if suppressed then
    state.last_suppressed = suppressed
    state.queue = nil
    log("SUPPRESS " .. suppressed)
    return
  end

  clear_suggestion() -- replace whatever was showing (e.g. a retained ghost)
  state.queue = { list = list, idx = 1 }
  while state.queue.idx <= #list do
    if show_edit(list[state.queue.idx]) then return end
    state.queue.idx = state.queue.idx + 1
  end
  state.queue = nil
  if show_prediction() then return end -- all edits stale, but a jump remains
  log("NOOP    suggestion matches buffer")
end

local function result_summary(res)
  local parts = {}
  for _, e in ipairs(res.edits or {}) do
    parts[#parts + 1] = e.range and ("L" .. e.range.start .. "-" .. e.range.endInclusive) or "L?"
  end
  local pred = res.prediction and ("  pred=" .. tostring(res.prediction.path) .. ":" .. tostring(res.prediction.line)) or ""
  return ("edits=%d  [%s]%s"):format(#(res.edits or {}), table.concat(parts, ", "), pred)
end

local function handle_result(res)
  if res.id == state.seq then state.awaiting = false end -- the current flight resolved
  if res.aborted then -- superseded upstream by a newer request; expected churn
    log("ABORT   #" .. tostring(res.id) .. "  (superseded)")
    return
  end
  if res.error then
    state.last_error = res.error
    log("ERR     #" .. tostring(res.id) .. "  " .. tostring(res.error))
    vim.schedule(function()
      vim.notify("neocursor: " .. tostring(res.error), vim.log.levels.WARN)
    end)
    return
  end
  state.last_ok_at = os.time()
  if res.id ~= state.seq then
    -- The reply outlived its request — but if the buffer is still byte-for-byte
    -- the one it was computed against (only movement-triggered refires bumped
    -- seq since), it is exact for this buffer. Binning it here is how good
    -- edits used to vanish while empty-handed newer replies showed "NOOP".
    local rt = state.req_ticks[res.id]
    local cb = vim.api.nvim_get_current_buf()
    if rt and res.edits and #res.edits > 0 and rt.bufnr == cb
      and vim.api.nvim_buf_get_changedtick(cb) == rt.tick then
      log(("RESCUE  #%s  (late, buffer unchanged)  %s"):format(tostring(res.id), result_summary(res)))
      vim.schedule(function()
        if vim.api.nvim_get_current_buf() == cb
          and vim.api.nvim_buf_get_changedtick(cb) == rt.tick then
          render_result(res)
        end
      end)
      return
    end
    log(("RES     #%s  (stale, seq=%d)  %s"):format(tostring(res.id), state.seq, result_summary(res)))
    return
  end
  log(("RES     #%s  %s"):format(tostring(res.id), result_summary(res)))
  vim.schedule(function()
    if vim.api.nvim_buf_is_valid(vim.api.nvim_get_current_buf()) then
      render_result(res)
    end
  end)
end

local function handle_line(line)
  -- luanil so JSON null decodes to nil, not vim.NIL (which is a truthy userdata
  -- and would crash `res.prediction`/`e.range` guards).
  local ok, res = pcall(vim.json.decode, line, { luanil = { object = true, array = true } })
  if not (ok and type(res) == "table") then return end
  if res.config then apply_config(res.config) else handle_result(res) end
end

local function on_stdout(_, data)
  if not data then return end
  data[1] = state.partial .. (data[1] or "")
  state.partial = table.remove(data) or ""
  for _, l in ipairs(data) do
    l = l:gsub("\r$", "") -- Windows: jobstart splits on \n and leaves the \r
    if l ~= "" then handle_line(l) end
  end
end

local function on_stderr(_, data)
  if not data then return end
  for _, l in ipairs(data) do
    l = l:gsub("\r$", "")
    if l ~= "" then
      if l:find("ready") then
        state.ready = true; log("SIDECAR ready")
      else
        state.last_stderr = l
        -- Keep a short tail: the sidecar's fatal errors (no Cursor install, not
        -- signed in) are multi-line, and they're all a user gets to debug with.
        table.insert(state.stderr_tail, l)
        if #state.stderr_tail > 20 then table.remove(state.stderr_tail, 1) end
        log("SIDECAR " .. l)
      end
    end
  end
end

function M.start()
  if state.job then return end
  local cmd = vim.deepcopy(state.cfg.sidecar_cmd)
  table.insert(cmd, plugin_root() .. "/sidecar.py")
  state.stderr_tail = {}
  local job = vim.fn.jobstart(cmd, {
    on_stdout = on_stdout,
    on_stderr = on_stderr,
    on_exit = function()
      local never_ready = not state.ready
      state.job = nil; state.ready = false; state.awaiting = false
      log("SIDECAR exited")
      -- Died during startup: say why instead of going quietly inert.
      if never_ready then
        local why = table.concat(state.stderr_tail, "\n")
        vim.notify(
          "neocursor: sidecar exited during startup" .. (why ~= "" and ("\n" .. why) or ""),
          vim.log.levels.ERROR
        )
      end
    end,
  })
  if job <= 0 then
    vim.notify("neocursor: failed to launch sidecar", vim.log.levels.ERROR)
    log("SIDECAR launch failed")
    return
  end
  state.job = job
  log("SIDECAR launching")
end

-- Gather the proximity context Cursor's native Tab sends as `additionalFiles`:
-- other visible splits (isOpen=true) plus the most-recently-visited buffers
-- (isOpen=false), each reduced to a bounded on-screen/near-cursor slice.
local function collect_additional_files(cur_buf)
  local MAX_FILES, MAX_LINES = 8, 200
  local files, seen = {}, {}

  local function relpath(b)
    local n = vim.api.nvim_buf_get_name(b)
    if n == "" then return nil end
    return vim.fn.fnamemodify(n, ":.")
  end
  local function usable(b)
    return vim.api.nvim_buf_is_loaded(b)
      and vim.bo[b].buftype == ""
      and vim.api.nvim_buf_get_name(b) ~= ""
  end
  local function excluded(path)
    for _, pat in ipairs(state.cfg.exclude_patterns or {}) do
      if path:find(pat, 1, true) then return true end
    end
    return false
  end
  local function push(b, is_open, top, bot, ts)
    local path = relpath(b)
    if not path or excluded(path) then return end
    local lines = vim.api.nvim_buf_get_lines(b, top - 1, bot, false)
    if #lines == 0 then return end
    seen[b] = true
    files[#files + 1] = {
      path = path, is_open = is_open, last_viewed_at = ts,
      ranges = { { start = top, stop = top + #lines - 1, content = table.concat(lines, "\n") } },
    }
  end

  -- 1) other visible splits → exactly what's on screen there
  for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
    local b = vim.api.nvim_win_get_buf(win)
    if b ~= cur_buf and not seen[b] and usable(b) then
      push(b, true, math.max(1, vim.fn.line("w0", win)), vim.fn.line("w$", win), state.viewed[b])
    end
  end

  -- 2) recently-visited buffers not on screen → a slice around their last cursor
  local mru = {}
  for b, t in pairs(state.viewed) do
    if b ~= cur_buf and not seen[b] and usable(b) then mru[#mru + 1] = { b = b, t = t } end
  end
  table.sort(mru, function(x, y) return x.t > y.t end)
  for _, e in ipairs(mru) do
    if #files >= MAX_FILES then break end
    local total = vim.api.nvim_buf_line_count(e.b)
    local mark = vim.api.nvim_buf_get_mark(e.b, '"')
    local center = (mark[1] > 0) and mark[1] or 1
    local top = math.max(1, center - math.floor(MAX_LINES / 2))
    push(e.b, false, top, math.min(total, top + MAX_LINES - 1), e.t)
  end

  return files
end

local function cap(s, n)
  if #s > n then return s:sub(1, n) .. "\n… (truncated)" end
  return s
end

-- linterErrors: current-buffer diagnostics → native LinterError shape (0-indexed).
-- vim.diagnostic.severity (ERROR/WARN/INFO/HINT = 1/2/3/4) matches Cursor's enum 1:1.
local SEV = {
  [vim.diagnostic.severity.ERROR] = 1,
  [vim.diagnostic.severity.WARN] = 2,
  [vim.diagnostic.severity.INFO] = 3,
  [vim.diagnostic.severity.HINT] = 4,
}
local function collect_linter_errors(buf, path)
  if not path then return nil end
  local diags = vim.diagnostic.get(buf)
  if #diags == 0 then return nil end
  local errors = {}
  for _, d in ipairs(diags) do
    if #errors >= 30 then break end
    errors[#errors + 1] = {
      message = d.message or "",
      source = d.source,
      severity = SEV[d.severity] or 1,
      range = {
        sl = d.lnum or 0, sc = d.col or 0,
        el = d.end_lnum or d.lnum or 0, ec = d.end_col or d.col or 0,
      },
    }
  end
  return { path = path, errors = errors }
end

-- diff trajectory: baseline snapshot per buffer; unified diff baseline→current is
-- the edit. commit_diff() coalesces at logical boundaries (InsertLeave/BufLeave).
local MAX_TRAJ, DIFF_CAP = 6, 4000

local function ensure_baseline(buf, path)
  if path and not state.dbase[buf] then
    state.dbase[buf] = { path = path, text = buf_text(buf) }
  end
end

-- returns (diff_string, current_text) or nil if unchanged
local function buf_diff(buf)
  local b = state.dbase[buf]
  if not b then return nil end
  local cur = buf_text(buf)
  if cur == b.text then return nil end
  -- ctxlen=0: emit ONLY the changed lines, no surrounding context. Cursor's
  -- backend uses diffHistory to locate the in-progress edit; 3 lines of context
  -- (the old default) bury the change and make it mis-locate — on a real file
  -- that silently flips the reply to edits=0. Verified against the live backend:
  -- same request, ctxlen=3 → 0 edits, ctxlen=0 → the correct completion.
  local d = vim.diff(b.text .. "\n", cur .. "\n", { result_type = "unified", ctxlen = 0 })
  if type(d) ~= "string" or d == "" then return nil end
  return cap(d, DIFF_CAP), cur
end

local function commit_diff(buf)
  local path = buf_relpath(buf)
  if not path then return end
  local d, cur = buf_diff(buf)
  if not d then return end
  local traj = state.dtraj[path]
  if not traj then traj = {}; state.dtraj[path] = traj end
  traj[#traj + 1] = { diff = d, ts = os.time() * 1000 }
  while #traj > MAX_TRAJ do table.remove(traj, 1) end
  state.dbase[buf] = { path = path, text = cur } -- advance baseline past this edit
end

local function collect_file_diff_histories(cur_buf, cur_path)
  local by_path = {}
  for path, traj in pairs(state.dtraj) do
    if #traj > 0 then
      local diffs, ts = {}, {}
      for _, e in ipairs(traj) do diffs[#diffs + 1] = e.diff; ts[#ts + 1] = e.ts end
      by_path[path] = { file_name = path, diff_history = diffs, diff_history_timestamps = ts }
    end
  end
  -- append the uncommitted in-progress edit of the current file as the newest step
  local d = buf_diff(cur_buf)
  if d and cur_path then
    local rec = by_path[cur_path]
    if not rec then
      rec = { file_name = cur_path, diff_history = {}, diff_history_timestamps = {} }
      by_path[cur_path] = rec
    end
    rec.diff_history[#rec.diff_history + 1] = d
    rec.diff_history_timestamps[#rec.diff_history_timestamps + 1] = os.time() * 1000
  end
  local arr = {}
  for _, rec in pairs(by_path) do arr[#arr + 1] = rec end
  if #arr == 0 then return nil end
  return arr
end

local function send_request()
  if not state.job then return end
  local bufnr = vim.api.nvim_get_current_buf()
  local cur = vim.api.nvim_win_get_cursor(0)
  state.seq = state.seq + 1
  local name = vim.fn.expand("%:.")
  local path = name ~= "" and name or "untitled"
  ensure_baseline(bufnr, buf_relpath(bufnr))
  local rp = buf_relpath(bufnr)
  local adds = collect_additional_files(bufnr)
  local lint = collect_linter_errors(bufnr, rp)
  local fdh = collect_file_diff_histories(bufnr, rp)
  state.req = { bufnr = bufnr, tick = vim.api.nvim_buf_get_changedtick(bufnr) }
  state.req_ticks[state.seq] = state.req
  state.req_ticks[state.seq - 16] = nil -- keep the ledger bounded
  local req = {
    id = state.seq,
    path = path,
    content = buf_text(bufnr),
    line = cur[1] - 1,
    col = cur[2],
    language = vim.bo[bufnr].filetype ~= "" and vim.bo[bufnr].filetype or "plaintext",
    additional_files = adds,
    linter_errors = lint,
    file_diff_histories = fdh,
  }
  vim.fn.chansend(state.job, vim.json.encode(req) .. "\n")
  state.awaiting = true
  log(("REQ     #%d  %s %d:%d  ctx=%d diffs=%d lint=%d"):format(
    state.seq, path, cur[1] - 1, cur[2], #adds, fdh and #fdh or 0, lint and #lint.errors or 0))
end

local function should_attach(bufnr)
  if vim.bo[bufnr].buftype ~= "" then return false end -- skip prompts/terminals/nofile
  local fts = state.cfg.filetypes
  if fts and #fts > 0 and not vim.tbl_contains(fts, vim.bo[bufnr].filetype) then
    return false
  end
  return true
end

local function cancel_timer()
  if state.timer then
    state.timer:stop(); state.timer:close(); state.timer = nil
  end
end

-- keep=true preserves the on-screen suggestion (a retained ghost the user is
-- typing through) while the refreshed request is in flight; the response then
-- replaces it atomically in render_result.
local function schedule_request(keep)
  if not should_attach(vim.api.nvim_get_current_buf()) then return end
  if not keep then clear_suggestion() end
  cancel_timer()
  state.timer = uv.new_timer()
  state.timer:start(state.cfg.debounce, 0, vim.schedule_wrap(function()
    cancel_timer()
    send_request()
  end))
end

-- Typing through the ghost: if the inline suggestion still extends what the
-- user has typed, shrink it in place instead of flickering it away; typing it
-- out in full counts as an accept and walks the chain. Returns true when the
-- suggestion survived (or was consumed) and must not be cleared.
local function try_retain()
  local s = state.suggestion
  if not (s and s.mode == "inline" and vim.api.nvim_get_current_buf() == s.bufnr) then
    return false
  end
  local lc = vim.api.nvim_buf_line_count(s.bufnr)
  local delta = lc - (s.buf_lines or lc)
  if delta ~= 0 then -- a newline typed inside the range: re-anchor the tail
    s.end0_excl = s.end0_excl + delta
    if state.queue then
      for k = state.queue.idx + 1, #state.queue.list do
        local e = state.queue.list[k]
        if e.start0 >= s.end0_excl - delta then
          e.start0, e.end0_excl = e.start0 + delta, e.end0_excl + delta
        end
      end
    end
  end
  if s.end0_excl > lc or s.end0_excl <= s.start0 then return false end
  if not show_edit(s) then -- region now equals the suggestion: typed out in full
    preview.clear(s.bufnr)
    state.suggestion = nil
    log("CONSUME L" .. (s.start0 + 1) .. "  typed through")
    advance_after_apply(s)
    return true
  end
  if state.suggestion.mode ~= "inline" then return false end -- deviated; drop it
  return true
end

-- Cursor moves made while an expr mapping evaluates are silently REVERTED when
-- the evaluation ends (:h expr-mapping "the cursor position is restored") —
-- blink/cmp integrations call M.accept() from exactly such mappings, and nvim
-- restores the cursor even though it now permits the buffer edit itself. So:
-- move synchronously (correct for our own callback mapping), then verify one
-- tick later — post-eval, where moving is legal — and re-apply if it was undone.
local function enforce_cursor(bufnr, pos)
  vim.schedule(function()
    if vim.api.nvim_get_current_buf() ~= bufnr then return end
    local cur = vim.api.nvim_win_get_cursor(0)
    if cur[1] ~= pos[1] or cur[2] ~= pos[2] then
      pcall(vim.api.nvim_win_set_cursor, 0, pos)
      mark_seen(bufnr) -- the enforced move fires its own echo; swallow it too
    end
  end)
end

-- Apply the edit under the cursor, then reveal the next one in the chain — all
-- synchronously, so a rapid tab-tab-tab can never slip a literal <Tab> into the
-- buffer between apply and re-render. The cursor stays at the applied edit; the
-- next <Tab> JUMPS to the revealed one (Cursor's cursorAtInlineEdit rule).
local function do_accept(s)
  if not vim.api.nvim_buf_is_valid(s.bufnr) then return end
  preview.clear(s.bufnr)
  state.suggestion = nil
  cancel_timer() -- a request scheduled before the accept would race the chain
  vim.cmd("let &undolevels=&undolevels") -- one undo reverts the whole accept
  local lc = vim.api.nvim_buf_line_count(s.bufnr)
  vim.api.nvim_buf_set_lines(s.bufnr, s.start0, math.min(s.end0_excl, lc), false, s.lines)
  local pos = { s.start0 + #s.lines, #(s.lines[#s.lines] or "") }
  pcall(vim.api.nvim_win_set_cursor, 0, pos)
  mark_seen(s.bufnr)
  advance_after_apply(s) -- local; no network
  enforce_cursor(s.bufnr, pos)
  if not state.suggestion then
    -- chain done: hand Tab over to the cursor prediction if the server sent
    -- one (Cursor's maybeShowHintLineWidget + retrigger-on-accept); otherwise
    -- just fetch a fresh suggestion here
    if not show_prediction() then
      state.prediction = nil
      schedule_request()
    end
  end
end

-- Move the cursor onto the edit (local, instant). This flips cursorAtInlineEdit
-- true, so the NEXT <Tab> accepts. Preview stays; its hint refreshes to "accept".
local function do_jump(s)
  if not vim.api.nvim_buf_is_valid(s.bufnr) then return end
  local lc = vim.api.nvim_buf_line_count(s.bufnr)
  local pos = { math.min(s.start0 + 1, lc), 0 }
  vim.api.nvim_win_set_cursor(0, pos)
  show_edit(s)
  mark_seen(s.bufnr)
  enforce_cursor(s.bufnr, pos)
end

-- Our own <Tab> mapping runs free of textlock, so fn runs synchronously. An
-- expr-map integrator (blink/cmp fallback chains) calls M.accept() under
-- textlock, where buffer/cursor changes throw — retry those once, deferred.
local function run_or_defer(fn, s)
  local ok, err = pcall(fn, s)
  if not ok then
    local msg = tostring(err)
    if msg:find("E565") or msg:find("E523") or msg:find("textlock") then
      vim.schedule(function()
        local ok2, err2 = pcall(fn, s)
        if not ok2 then log("ERR     apply failed: " .. tostring(err2)) end
      end)
    else
      log("ERR     apply failed: " .. msg)
    end
  end
end

-- Jump to the server's predicted next location (Cursor's tabToLineBefore-
-- AcceptingCpp): m' first so <C-o>/'' goes back, land at the line's first
-- non-blank column, then retrigger immediately — the next suggestion appears
-- at the landing point with no debounce. Cross-file targets open the file.
local function do_accept_prediction(p)
  preview.clear_prediction(0)
  state.prediction = nil
  cancel_timer()
  local bufnr = vim.api.nvim_get_current_buf()
  local rel = buf_relpath(bufnr)
  if p.path and rel and p.path ~= rel then
    vim.cmd("edit " .. vim.fn.fnameescape(p.path))
    bufnr = vim.api.nvim_get_current_buf()
  end
  local lc = vim.api.nvim_buf_line_count(bufnr)
  local row = math.min(math.max(p.line or 1, 1), lc)
  pcall(vim.cmd, "normal! m'") -- jumplist entry = the go-back affordance
  local line = vim.api.nvim_buf_get_lines(bufnr, row - 1, row, false)[1] or ""
  local col = (line:find("%S") or (#line + 1)) - 1
  local pos = { row, col }
  vim.api.nvim_win_set_cursor(0, pos)
  mark_seen(bufnr)
  enforce_cursor(bufnr, pos)
  log(("PREDGO  %s:%d"):format(p.path or "·", row))
  send_request() -- retriggerCppOnAccept
end

-- Cursor's shouldTabInsteadOfAccepting: on a blank line, Tab should indent,
-- not accept — but only for non-fused models (their check), and never for an
-- inline ghost sitting right at the cursor.
local function tab_should_indent(s)
  if state.cfg.is_fused ~= false then return false end
  if s.mode == "inline" then return false end
  return vim.api.nvim_get_current_line():match("^%s*$") ~= nil
end

-- <Tab> handler, Cursor's full priority order: pending edit (jump-first,
-- accept-second) → cursor prediction jump → nothing (caller falls back to a
-- literal tab). Returns true when Tab was consumed.
function M.accept()
  local s = state.suggestion
  if s then
    if vim.api.nvim_get_current_buf() ~= s.bufnr then
      clear_suggestion() -- suggestion belongs to another buffer; Tab stays a tab
      return false
    end
    if cursor_at(s.start0, s.end0_excl) then
      if tab_should_indent(s) then return false end
      log("ACCEPT  L" .. (s.start0 + 1))
      run_or_defer(do_accept, s)
    else
      log("JUMP    L" .. (s.start0 + 1))
      run_or_defer(do_jump, s)
    end
    return true
  end
  local p = state.prediction
  if p then
    run_or_defer(do_accept_prediction, p)
    return true
  end
  return false
end

-- Accept only the next word of an inline ghost (Cursor's acceptCppPartial):
-- insert the fragment, shrink the ghost in place, and when the last fragment
-- lands, walk the chain exactly like a full accept.
local function do_accept_partial(s)
  local bufnr = s.bufnr
  local cur = vim.api.nvim_win_get_cursor(0)
  local row1, col0 = cur[1], cur[2]
  local ok, prefix_lines = pcall(vim.api.nvim_buf_get_text, bufnr, s.start0, 0, row1 - 1, col0, {})
  if not ok then return end
  local text = table.concat(s.lines, "\n")
  local prefix = table.concat(prefix_lines, "\n")
  if text:sub(1, #prefix) ~= prefix then return end
  local ghost = text:sub(#prefix + 1)
  if ghost == "" then return end
  -- next word = leading blanks + one non-blank run; a leading newline is taken
  -- alone with its indentation (accepting the line break)
  local frag = ghost:match("^\n%s*") or ghost:match("^%s*[^%s]+") or ghost
  local flines = vim.split(frag, "\n", { plain = true })
  vim.api.nvim_buf_set_text(bufnr, row1 - 1, col0, row1 - 1, col0, flines)
  local nrow1 = row1 + #flines - 1
  local ncol = #flines > 1 and #flines[#flines] or (col0 + #frag)
  pcall(vim.api.nvim_win_set_cursor, 0, { nrow1, ncol })
  mark_seen(bufnr)
  local lc = vim.api.nvim_buf_line_count(bufnr)
  local delta = lc - (s.buf_lines or lc)
  if delta ~= 0 then
    s.end0_excl = s.end0_excl + delta
    if state.queue then
      for k = state.queue.idx + 1, #state.queue.list do
        local e = state.queue.list[k]
        if e.start0 >= s.end0_excl - delta then
          e.start0, e.end0_excl = e.start0 + delta, e.end0_excl + delta
        end
      end
    end
  end
  log(("PARTIAL L%d  +%d ch"):format(s.start0 + 1, #frag))
  if not show_edit(s) then -- ghost fully consumed: behaves like a full accept
    preview.clear(bufnr)
    state.suggestion = nil
    advance_after_apply(s)
    if not state.suggestion and not show_prediction() then
      state.prediction = nil
      schedule_request()
    end
  end
  enforce_cursor(bufnr, { nrow1, ncol })
end

function M.accept_partial()
  local s = state.suggestion
  if not (s and s.mode == "inline" and vim.api.nvim_get_current_buf() == s.bufnr) then
    return false
  end
  run_or_defer(do_accept_partial, s)
  return true
end
function M.has_prediction() return state.prediction ~= nil end

-- exposed for test/hints_spec.lua; pure, no state
M._normalize_hints = normalize_hints

-- Dismiss without leaving insert mode. <Esc> does the same thing and then exits
-- insert; this is the variant for when you want to keep typing. <C-]> is the
-- key copilot.vim, copilot.lua and avante.nvim all use for it.
function M.dismiss()
  local bufnr = vim.api.nvim_get_current_buf()
  -- tier 1 first, tier 2 only when there was no edit to dismiss — press it
  -- twice to clear an edit and then its jump target, exactly like Cursor.
  if not reject_suggestion() then reject_prediction(bufnr) end
  cancel_timer() -- a request already in the debounce would repaint what we just cleared
end

function M.log()
  if not (state.log_buf and vim.api.nvim_buf_is_valid(state.log_buf)) then
    state.log_buf = vim.api.nvim_create_buf(false, true)
    vim.bo[state.log_buf].bufhidden = "hide"
    vim.bo[state.log_buf].filetype = "neocursorlog"
    pcall(vim.api.nvim_buf_set_name, state.log_buf, "neocursor://log")
  end
  for _, win in ipairs(vim.api.nvim_list_wins()) do
    if vim.api.nvim_win_get_buf(win) == state.log_buf then
      vim.api.nvim_win_close(win, true) -- toggle off if already open
      return
    end
  end
  vim.cmd("botright 20split")
  local win = vim.api.nvim_get_current_win()
  vim.api.nvim_win_set_buf(win, state.log_buf)
  vim.wo[win].number, vim.wo[win].relativenumber, vim.wo[win].wrap = false, false, false
  log_refresh()
  vim.cmd("wincmd p") -- keep focus where the user was typing
end
function M.has_suggestion() return state.suggestion ~= nil end
function M.suggest() send_request() end -- manual trigger (:NeocursorSuggest)

-- Kill the sidecar and reset transient state. Lets setup() be re-run with a
-- different sidecar_cmd (specs swap in a canned sidecar mid-session).
function M.stop()
  if state.job then
    vim.fn.jobstop(state.job)
    state.job = nil
  end
  state.ready = false
  cancel_timer()
  clear_suggestion()
end

function M.setup(opts)
  opts = opts or {}
  state.cfg = {
    debounce = opts.debounce or 250,
    sidecar_cmd = opts.sidecar_cmd or { "uv", "run", "--with", "httpx[http2]" },
    map_tab = opts.map_tab ~= false, -- set false when another plugin (cmp) owns <Tab>
    filetypes = opts.filetypes,      -- optional allow-list; nil = all normal buffers
    show_hints = normalize_hints(opts.show_hints), -- display-only chrome; see normalize_hints
    exclude_patterns = {},           -- filled from CppConfig (skip .env/.pem/... as context)
    heuristics = {},                 -- filled from CppConfig (active suppression rules)
    reject_hard = 2,
    max_cleared = 20,                -- CppConfig maxNumberOfClearedSuggestionsSinceLastAccept
    is_fused = nil,                  -- CppConfig isFusedCursorPredictionModel (nil = unknown)
    map_partial = opts.map_partial ~= false
      and (type(opts.map_partial) == "string" and opts.map_partial or "<M-Right>")
      or nil,
  }
  M.start()

  local grp = vim.api.nvim_create_augroup("neocursor", { clear = true })
  vim.api.nvim_create_autocmd({ "TextChangedI", "CursorMovedI" }, {
    group = grp,
    callback = function(args)
      local buf = vim.api.nvim_get_current_buf()
      local cur = vim.api.nvim_win_get_cursor(0)
      local tick = vim.api.nvim_buf_get_changedtick(buf)
      local seen = state.seen
      state.seen = { buf = buf, tick = tick, row = cur[1], col = cur[2] }
      -- A real text edit is authoritatively the TextChangedI event (Cursor's
      -- onDidChangeContent → lastEditTime). The tick heuristic below can't tell
      -- a genuine edit from a buffer switch, so the reading-code clock keys off
      -- the event name instead.
      if args.event == "TextChangedI" then state.last_edit_at = os.time() end
      -- identical state = the echo of our own apply/jump, or the second of the
      -- two events one keystroke fires — nothing actually happened
      if seen and seen.buf == buf and seen.tick == tick
        and seen.row == cur[1] and seen.col == cur[2] then
        return
      end
      local prev_line = state.last_line
      state.last_line = cur[1]
      local typed = not seen or seen.buf ~= buf or seen.tick ~= tick
      if typed then
        if try_retain() then
          schedule_request(true) -- ghost survives; refresh in the background
        else
          schedule_request()     -- deviated from the suggestion: clear and refetch
        end
      else
        -- Pure cursor movement. Cursor's onDidChangeCursorPosition fires a
        -- request ONLY on a line change, and never while "reading code" (no
        -- edit in the last 60s) — a within-line move or idle navigation sends
        -- nothing. A visible suggestion is kept alive across moves (its hint is
        -- re-anchored), matching Cursor keeping the inline edit as a jump target.
        local s = state.suggestion
        if s and vim.api.nvim_get_current_buf() == s.bufnr then
          show_edit(s) -- re-anchor the jump⇄accept hint; no new request while shown
        else
          local line_changed = prev_line ~= cur[1]
          local reading = not state.last_edit_at or (os.time() - state.last_edit_at) >= 60
          if line_changed and not reading and not rejected_too_many() then
            schedule_request()
          end
        end
      end
    end,
  })
  vim.api.nvim_create_autocmd("InsertEnter", {
    group = grp,
    callback = function()
      state.last_line = vim.api.nvim_win_get_cursor(0)[1] -- baseline; first move isn't a "line change"
      if rejected_too_many() then return end -- Cursor gates its EditorChange trigger the same way
      schedule_request(true)                 -- request at the entry point
    end,
  })
  vim.api.nvim_create_autocmd({ "InsertLeave", "BufLeave" }, {
    group = grp,
    callback = function(args)
      commit_diff(args.buf) -- coalesce the just-finished edit into the trajectory
      cancel_timer()        -- don't fire a request for a buffer we just left
      -- <Esc> lands here, and this is the whole reason it counts as a dismiss:
      -- Cursor's Escape files a hard rejection before clearing, so ours must
      -- too, or the identical suggestion returns the moment you re-enter insert.
      reject_suggestion()
      -- The jump target is dropped but NOT filed as rejected: leaving insert is
      -- a mode change, not a "no" to where the model wanted to send you.
      state.prediction = nil
      preview.clear_prediction(args.buf)
      -- Leaving the buffer is our analogue of Cursor's onDidBlurEditorText:
      -- come back to a clean slate. Merely leaving insert is not — that happens
      -- constantly in neovim, and resetting there would defang the budget.
      if args.event == "BufLeave" then state.dismissed = 0 end
    end,
  })
  vim.api.nvim_create_autocmd("BufEnter", {
    group = grp,
    callback = function(args)
      if vim.bo[args.buf].buftype == "" and vim.api.nvim_buf_get_name(args.buf) ~= "" then
        state.viewed[args.buf] = os.time() * 1000
        ensure_baseline(args.buf, buf_relpath(args.buf))
      end
    end,
  })

  if state.cfg.map_tab then
    -- A callback mapping, not an expr map: expr evaluation runs under textlock,
    -- which forces the apply onto the next tick — and a fast tab-tab would slip
    -- a literal <Tab> into the buffer in between. Here the accept is
    -- synchronous; only a no-suggestion Tab falls through.
    vim.keymap.set("i", "<Tab>", function()
      if M.accept() then return end
      local tab = vim.api.nvim_replace_termcodes("<Tab>", true, false, true)
      vim.api.nvim_feedkeys(tab, "n", false)
    end, { desc = "neocursor: accept / jump / literal tab" })
  end

  if state.cfg.map_partial then
    local pkey = state.cfg.map_partial
    vim.keymap.set("i", pkey, function()
      if M.accept_partial() then return end
      local orig = vim.api.nvim_replace_termcodes(pkey, true, false, true)
      vim.api.nvim_feedkeys(orig, "n", false)
    end, { desc = "neocursor: accept next word of ghost" })
  end

  vim.keymap.set("i", "<C-]>", M.dismiss, { desc = "neocursor: dismiss" })
  vim.api.nvim_create_user_command("NeocursorSuggest", M.suggest, { desc = "request a suggestion now" })
  vim.api.nvim_create_user_command("NeocursorLog", M.log, { desc = "toggle the neocursor live log pane" })

  vim.api.nvim_create_user_command("NeocursorDebug", function()
    local s = state.suggestion
    local dbuf = vim.api.nvim_get_current_buf()
    local dlint = collect_linter_errors(dbuf, buf_relpath(dbuf))
    local dfdh = collect_file_diff_histories(dbuf, buf_relpath(dbuf))
    local lines = {
      "── neocursor debug ──",
      "sidecar job : " .. tostring(state.job) .. (state.ready and "  READY" or "  (no ready signal)"),
      "requests    : seq=" .. tostring(state.seq) .. "  last_ok=" .. tostring(state.last_ok_at or "never"),
      "suggestion  : " .. (s and (s.mode .. "  lines=" .. #s.lines) or "none"),
      "chain       : " .. (state.queue and (state.queue.idx .. "/" .. #state.queue.list) or "none"),
      "config      : debounce=" .. state.cfg.debounce .. "ms  heuristics=" .. #state.cfg.heuristics
        .. "  excludes=" .. #state.cfg.exclude_patterns,
      "hints       : edit=" .. tostring(hints().edit) .. "  prediction=" .. tostring(hints().prediction),
      "last suppress: " .. tostring(state.last_suppressed or "none"),
      "dismissed   : " .. state.dismissed .. "/" .. tostring(state.cfg.max_cleared or 20)
        .. (rejected_too_many() and "  (muted — passive triggers off until you accept)" or ""),
      "buffer      : buftype='" .. vim.bo.buftype .. "'  filetype='" .. vim.bo.filetype .. "'",
      "attach ok   : " .. tostring(should_attach(vim.api.nvim_get_current_buf())),
      "ctx files   : " .. tostring(#collect_additional_files(dbuf)),
      "linter errs : " .. tostring(dlint and #dlint.errors or 0),
      "diff files  : " .. tostring(dfdh and #dfdh or 0),
      "last error  : " .. tostring(state.last_error or "none"),
      "last stderr : " .. tostring(state.last_stderr or "none"),
    }
    vim.notify(table.concat(lines, "\n"), vim.log.levels.INFO)
  end, { desc = "neocursor diagnostics" })

  vim.notify("neocursor ready — type in insert mode; <Tab> accepts", vim.log.levels.INFO)
end

return M
