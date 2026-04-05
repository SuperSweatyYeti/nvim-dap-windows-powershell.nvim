-- lua/nvim-dap-powershell/init.lua
-- nvim-dap adapter for Windows PowerShell 5.1
--
-- Inspired by https://github.com/TheLeoP/powershell.nvim
-- The adapter spawns dap_server.ps1 in a Neovim terminal buffer so that
-- script output is visible as a live debug console.  DAP protocol runs over a
-- loopback TCP connection so stdout is free for the terminal.

local api = vim.api
local M   = {}

-- ---------------------------------------------------------------------------
-- Module-level debug-terminal state (one session at a time)
-- ---------------------------------------------------------------------------
local dap_term_buf     = nil ---@type integer?
local dap_term_channel = nil ---@type integer?
local _opts            = {} ---@type NvimDapPowershellOpts populated by setup()

local function find_term_win()
  if not dap_term_buf then return nil end
  for _, win in ipairs(api.nvim_tabpage_list_wins(0)) do
    if api.nvim_win_get_buf(win) == dap_term_buf then
      return win
    end
  end
end

local function is_term_open()
  local win = find_term_win()
  if not win then return false end
  local wt = vim.fn.win_gettype(win)
  return wt == '' or wt == 'popup'
end

local function open_term()
  if not dap_term_buf then
    vim.notify('[nvim-dap-powershell] No debug terminal buffer', vim.log.levels.WARN)
    return
  end
  vim.cmd(_opts.terminal_split or 'split')
  api.nvim_set_current_buf(dap_term_buf)
end

local function close_term()
  local win = find_term_win()
  if not win then
    vim.notify('[nvim-dap-powershell] No debug terminal window open', vim.log.levels.WARN)
    return
  end
  api.nvim_win_close(win, true)
end

--- Toggle the PowerShell debug terminal window.
---
--- Bind this to a key in your config, e.g.:
---   vim.keymap.set('n', '<leader>dt',
---     require('nvim-dap-powershell').toggle_debug_term)
---
--- Or inside a ps1 FileType autocmd:
---   vim.keymap.set('n', '<leader>dt',
---     function() require('nvim-dap-powershell').toggle_debug_term() end)
function M.toggle_debug_term()
  if is_term_open() then
    close_term()
  else
    open_term()
  end
end

-- ---------------------------------------------------------------------------
-- Utilities
-- ---------------------------------------------------------------------------

local function get_script_path()
  local src = debug.getinfo(1, 'S').source
  if src:sub(1, 1) == '@' then src = src:sub(2) end
  -- this file lives at .../lua/nvim-dap-powershell/init.lua
  -- dap_server.ps1 lives at   .../adapter/dap_server.ps1
  local plugin_root = vim.fn.fnamemodify(src, ':p:h:h:h')
  return plugin_root .. '/adapter/dap_server.ps1'
end

--- Poll until dap_server.ps1 writes its ready-file (same pattern used by
--- TheLeoP/powershell.nvim for the PSES session file).
---@param ready_path string
---@param callback   fun()
---@param max_tries  integer
---@param delay_ms   integer
local function wait_for_ready_file(ready_path, callback, max_tries, delay_ms)
  max_tries = max_tries or 60
  delay_ms  = delay_ms  or 300
  local function try(remaining)
    if remaining == 0 then
      vim.notify(
        ('[nvim-dap-powershell] Server did not signal ready (%s)'):format(ready_path),
        vim.log.levels.ERROR
      )
      return
    end
    if vim.fn.filereadable(ready_path) == 1 then
      vim.fn.delete(ready_path)
      callback()
    else
      vim.defer_fn(function() try(remaining - 1) end, delay_ms)
    end
  end
  try(max_tries)
end

-- ---------------------------------------------------------------------------
-- Default options
-- ---------------------------------------------------------------------------

---@class NvimDapPowershellOpts
---@field powershell_path  string   Path to powershell.exe (Windows PowerShell 5.1)
---@field configurations   table[]  Extra/override DAP launch configurations
---@field terminal_split   string   Vim split command used to open the terminal (default: 'split')

local default_opts = {
  powershell_path = 'powershell.exe',
  configurations  = {},
  terminal_split  = 'split',
}

-- ---------------------------------------------------------------------------
-- Setup
-- ---------------------------------------------------------------------------

--- Register the nvim-dap adapter and configurations for PowerShell 5.1.
---
---@param opts NvimDapPowershellOpts|nil
function M.setup(opts)
  _opts = vim.tbl_deep_extend('force', default_opts, opts or {})

  local ok, dap = pcall(require, 'dap')
  if not ok then
    vim.notify(
      '[nvim-dap-powershell] nvim-dap not found. Please install mfussenegger/nvim-dap.',
      vim.log.levels.ERROR
    )
    return
  end

  local server_script = get_script_path()

  -- Register the adapter as a function so we can spin up a fresh terminal
  -- buffer for every debug session (mirrors TheLeoP/powershell.nvim).
  dap.adapters.powershell = function(on_config)
    local port       = math.random(10000, 59999)
    -- Unique ready-file: dap_server.ps1 writes it once the TCP listener is up
    local ready_file = vim.fn.tempname() .. '.nvim-dap-ps-ready'

    dap_term_buf = api.nvim_create_buf(false, false)
    api.nvim_buf_call(dap_term_buf, function()
      dap_term_channel = vim.fn.jobstart(
        {
          _opts.powershell_path,
          '-NoProfile', '-NonInteractive',
          '-ExecutionPolicy', 'Bypass',
          '-File', server_script,
          '-Port', tostring(port),
          '-ReadyFile', ready_file,
        },
        { term = true }
      )
      -- Fire the same User autocmd pattern as TheLeoP/powershell.nvim so
      -- users can attach keymaps to the terminal buffer.
      api.nvim_exec_autocmds('User', {
        pattern = 'nvim-dap-powershell-debug_term',
        data    = { channel = dap_term_channel, buf = dap_term_buf },
      })
    end)

    wait_for_ready_file(ready_file, function()
      on_config { type = 'server', host = '127.0.0.1', port = port }
    end)
  end

  -- Clean up terminal buffer when the debug session ends
  local key = 'nvim-dap-powershell'
  dap.listeners.after.initialize[key] = function(session)
    session.on_close[key] = function()
      if is_term_open() then close_term() end
      if dap_term_buf then
        pcall(api.nvim_buf_delete, dap_term_buf, { force = true })
      end
      dap_term_channel = nil
      dap_term_buf     = nil
    end
  end

  -- Build default launch configurations
  local default_configurations = {
    {
      type    = 'powershell',
      request = 'launch',
      name    = 'Launch PowerShell Script',
      program = function()
        local default = vim.fn.expand('%:p')
        local input   = vim.fn.input('Script to debug: ', default, 'file')
        return input ~= '' and input or default
      end,
      args = function()
        local raw = vim.fn.input('Script arguments (space-separated, blank for none): ')
        if raw == '' then return {} end
        local result = {}
        for word in raw:gmatch('%S+') do table.insert(result, word) end
        return result
      end,
      cwd = '${workspaceFolder}',
    },
  }

  dap.configurations.ps1 = vim.list_extend(
    vim.deepcopy(default_configurations),
    _opts.configurations or {}
  )
end

return M
