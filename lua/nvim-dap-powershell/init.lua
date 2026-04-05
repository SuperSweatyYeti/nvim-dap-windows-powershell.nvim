-- lua/nvim-dap-powershell/init.lua
-- nvim-dap adapter for Windows PowerShell 5.1

local M = {}

-- Resolve the path to dap_server.ps1 relative to this plugin's directory.
-- Works whether the plugin is installed in any standard plugin manager path.
local function get_script_path()
  -- __FILE__ equivalent: find the source of this module
  local src = debug.getinfo(1, 'S').source
  if src:sub(1, 1) == '@' then
    src = src:sub(2)
  end
  -- src is .../lua/nvim-dap-powershell/init.lua
  -- adapter script is at .../adapter/dap_server.ps1
  local plugin_root = vim.fn.fnamemodify(src, ':p:h:h:h')
  return plugin_root .. '/adapter/dap_server.ps1'
end

--- Default configuration options.
---@class NvimDapPowershellOpts
---@field powershell_path string Path to powershell.exe (Windows PowerShell 5.1)
---@field configurations table[] Extra/override DAP configurations

local default_opts = {
  powershell_path = 'powershell.exe',
  configurations  = {},
}

--- Setup the nvim-dap adapter and configurations for PowerShell 5.1.
---
---@param opts NvimDapPowershellOpts|nil
function M.setup(opts)
  opts = vim.tbl_deep_extend('force', default_opts, opts or {})

  local ok, dap = pcall(require, 'dap')
  if not ok then
    vim.notify(
      '[nvim-dap-powershell] nvim-dap not found. Please install mfussenegger/nvim-dap.',
      vim.log.levels.ERROR
    )
    return
  end

  local server_script = get_script_path()

  -- Register the adapter
  dap.adapters.powershell = {
    type    = 'executable',
    command = opts.powershell_path,
    args    = {
      '-NoProfile',
      '-NonInteractive',
      '-ExecutionPolicy', 'Bypass',
      '-File', server_script,
    },
  }

  -- Build default configurations
  local default_configurations = {
    {
      type    = 'powershell',
      request = 'launch',
      name    = 'Launch PowerShell Script',
      program = function()
        local default = vim.fn.expand('%:p')
        local input = vim.fn.input('Script to debug: ', default, 'file')
        return input ~= '' and input or default
      end,
      args = function()
        local raw = vim.fn.input('Script arguments (space-separated, blank for none): ')
        if raw == '' then
          return {}
        end
        -- Split on whitespace
        local result = {}
        for word in raw:gmatch('%S+') do
          table.insert(result, word)
        end
        return result
      end,
      cwd = '${workspaceFolder}',
    },
  }

  -- Merge user configurations
  local configurations = vim.list_extend(
    vim.deepcopy(default_configurations),
    opts.configurations or {}
  )

  dap.configurations.ps1 = configurations
end

return M
