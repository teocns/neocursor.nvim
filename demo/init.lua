-- Pinned, hermetic Neovim config for the demo recording.
-- Deliberately loads NOTHING but neocursor: no colorscheme plugins, no
-- statusline, no user config. The recording must look identical on any
-- machine and in CI, so every visual knob is set explicitly here.
local root = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":h:h")

vim.opt.rtp:prepend(root)
vim.opt.swapfile = false
vim.opt.shada = ""
vim.opt.more = false
vim.opt.showcmd = false
vim.opt.showmode = false
vim.opt.ruler = false
vim.opt.laststatus = 0 -- no statusline: the code is the whole frame
vim.opt.cmdheight = 0 -- reclaim the last row (nvim 0.8+)
vim.opt.number = true
vim.opt.numberwidth = 4
vim.opt.signcolumn = "no"
vim.opt.fillchars = { eob = " " } -- hide the ~ tildes past end-of-buffer
vim.opt.scrolloff = 99 -- keep content vertically centred
vim.opt.shiftwidth = 4
vim.opt.expandtab = true
vim.opt.termguicolors = true

vim.cmd("syntax on")
vim.cmd("colorscheme habamax") -- ships with nvim; dark, high-contrast, stable

-- Readable on both GitHub light and dark backgrounds.
vim.api.nvim_set_hl(0, "Normal", { fg = "#c9d1d9", bg = "#0d1117" })
vim.api.nvim_set_hl(0, "LineNr", { fg = "#484f58", bg = "#0d1117" })
vim.api.nvim_set_hl(0, "CursorLineNr", { fg = "#c9d1d9", bg = "#0d1117" })
vim.api.nvim_set_hl(0, "EndOfBuffer", { fg = "#0d1117", bg = "#0d1117" })

-- The demo backend: a scripted stand-in for Cursor's servers so the recording
-- is byte-identical every run. Swap DEMO_SIDECAR=real to film the live backend.
local sidecar = os.getenv("NEOCURSOR_DEMO_SIDECAR") or (root .. "/demo/sidecar.py")
local py = vim.fn.executable("python3") == 1 and "python3" or "python"

-- setup() announces itself with an INFO vim.notify. With cmdheight=0 there is
-- no room to display it, so Neovim raises a hit-enter prompt -- which stops
-- answering RPC and hangs the driver before a single frame is filmed.
-- Drop INFO chatter, but deliberately let WARN/ERROR through: if the sidecar
-- fails to launch the recording SHOULD visibly break rather than quietly film
-- an editor that does nothing.
local real_notify = vim.notify
vim.notify = function(msg, level, opts)
  if (level or vim.log.levels.INFO) <= vim.log.levels.INFO then return end
  return real_notify(msg, level, opts)
end

require("neocursor").setup({
  debounce = 60,
  show_hints = true, -- the hint chrome IS the narration in a silent GIF
  sidecar_cmd = { py, sidecar },
})
