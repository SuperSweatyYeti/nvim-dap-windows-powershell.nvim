# nvim-dap-windows-powershell.nvim

A lightweight, purpose-built [nvim-dap](https://github.com/mfussenegger/nvim-dap)
adapter for **Windows PowerShell 5.1** (`powershell.exe`).

Unlike the PowerShell Editor Services extension (which targets PowerShell 7+
and is heavy), this plugin ships a self-contained DAP server written in
PowerShell 5.1 itself. It uses the built-in
`System.Management.Automation.Debugger` API to set breakpoints, step through
code, and inspect variables — with no external dependencies.

Inspired by the terminal-buffer pattern from
[TheLeoP/powershell.nvim](https://github.com/TheLeoP/powershell.nvim).

---

## Features

- Full DAP support: breakpoints, step over/in/out, call stack, scopes, variables, evaluate
- Live **debug terminal buffer** — script output (`Write-Host`, `Write-Output`, errors) streams into a Neovim terminal window in real time
- **`toggle_debug_term()`** to show/hide the terminal during a session
- REPL-style evaluate via `Debugger.ProcessCommand` — expressions typed in the nvim-dap REPL have access to local variables of the paused frame
- DAP runs over a loopback TCP socket so stdout stays clean for the terminal
- PowerShell 5.1 only — no `pwsh.exe` / PS 7 required

---

## Requirements

| Requirement | Version |
|---|---|
| Neovim | ≥ 0.7 |
| [nvim-dap](https://github.com/mfussenegger/nvim-dap) | any recent |
| Windows PowerShell | 5.1 (`powershell.exe` on `PATH`) |
| OS | Windows |

---

## Installation

### [lazy.nvim](https://github.com/folke/lazy.nvim)

```lua
{
  'SuperSweatyYeti/nvim-dap-windows-powershell.nvim',
  dependencies = { 'mfussenegger/nvim-dap' },
  opts = {},
}
```

### [packer.nvim](https://github.com/wbthomason/packer.nvim)

```lua
use {
  'SuperSweatyYeti/nvim-dap-windows-powershell.nvim',
  requires = { 'mfussenegger/nvim-dap' },
  config = function()
    require('nvim-dap-powershell').setup()
  end,
}
```

### [vim-plug](https://github.com/junegunn/vim-plug)

```vim
Plug 'mfussenegger/nvim-dap'
Plug 'SuperSweatyYeti/nvim-dap-windows-powershell.nvim'
```

Then call `require('nvim-dap-powershell').setup()` in your Lua config.

---

## Configuration

```lua
require('nvim-dap-powershell').setup({
  -- Path to Windows PowerShell 5.1.  Default: 'powershell.exe' on PATH.
  powershell_path = 'powershell.exe',

  -- Vim split command used to open the debug terminal window.
  -- Examples: 'split', 'vsplit', 'tabnew', 'belowright split'
  terminal_split = 'split',

  -- Extra/override DAP launch configurations (merged after the built-in one).
  configurations = {},
})
```

---

## Usage

### Start debugging

Open a `.ps1` file, set a breakpoint, then run:

```vim
:lua require('dap').continue()
```

The plugin prompts you for the script path (defaults to the current file) and
optional arguments, then:

1. Spawns `dap_server.ps1` inside a hidden Neovim terminal buffer
2. Connects nvim-dap to it over a loopback TCP socket
3. Runs your script — output appears in the debug terminal

### Debug terminal

```lua
require('nvim-dap-powershell').toggle_debug_term()
```

Toggles the terminal window that runs the debug session.  All `Write-Host`,
`Write-Output`, `Write-Error`, and `Write-Warning` output from your script
appears here in real time.

Recommended keymap (add to your config or to `~/.config/nvim/ftplugin/ps1.lua`):

```lua
vim.keymap.set('n', '<leader>dt', function()
  require('nvim-dap-powershell').toggle_debug_term()
end)
```

You can also set a keymap *inside* the terminal buffer by listening to the
`User` autocmd that the plugin fires when the terminal is created:

```lua
local augroup = vim.api.nvim_create_augroup('my-ps-debug', { clear = true })
vim.api.nvim_create_autocmd('User', {
  group   = augroup,
  pattern = 'nvim-dap-powershell-debug_term',
  callback = function(ev)
    vim.keymap.set('n', '<leader>dt', function()
      require('nvim-dap-powershell').toggle_debug_term()
    end, { buffer = ev.data.buf })
  end,
})
```

### REPL (debug console)

While paused at a breakpoint, open nvim-dap's built-in REPL to evaluate
expressions in the current scope:

```vim
:lua require('dap').repl.open()
```

Type any PowerShell expression — it is evaluated via
`Debugger.ProcessCommand`, which has full access to local variables of the
paused frame.

---

## DAP features

| Feature | Supported |
|---|---|
| Launch script | ✅ |
| Line breakpoints | ✅ |
| Step over / in / out | ✅ |
| Continue | ✅ |
| Call stack | ✅ |
| Local / Script / Global scopes | ✅ |
| Variable inspection (nested) | ✅ |
| Evaluate (REPL, in-scope) | ✅ |
| Output events (stdout / stderr) | ✅ |
| Attach to process | ❌ |
| Conditional breakpoints | ❌ |
| Function breakpoints | ❌ |

---

## Troubleshooting

**Nothing happens when I call `dap.continue()`**
- Confirm that `powershell.exe` is on your `PATH` and is version 5.1:
  `powershell.exe -Command "$PSVersionTable.PSVersion"`
- Check the nvim-dap log: `:lua require('dap').set_log_level('DEBUG')`, then
  inspect `~/.cache/nvim/dap.log`.

**Breakpoints never hit**
- Make sure the path in `setBreakpoints` matches the actual script path
  (use absolute paths).
- The script must be run via the `program` field, not via `Invoke-Expression`.

**Debug terminal is empty / no output**
- Call `toggle_debug_term()` to open it.
- Verify that `$InformationPreference = 'Continue'` is not being overridden in
  your `$PROFILE`.

**"Server did not signal ready" error**
- PowerShell 5.1 startup is slow on some machines.  Increase the retry window:
  ```lua
  -- The ready-file poller retries up to 60 times at 300 ms intervals (18 s).
  -- If your machine is slower, this may need adjustment in the source.
  ```

---

## Architecture

```
nvim-dap-windows-powershell.nvim/
├── adapter/
│   └── dap_server.ps1        PowerShell 5.1 DAP server (TCP or stdin/stdout)
├── lua/
│   └── nvim-dap-powershell/
│       └── init.lua          Lua plugin — adapter function, terminal, setup()
├── doc/
│   └── nvim-dap-powershell.txt  Vim :help file
├── LICENSE
└── README.md
```

The adapter runs in two modes selected by Lua at startup:

| Mode | How selected | When to use |
|---|---|---|
| **TCP** | `-Port N -ReadyFile path` | Normal use — terminal buffer gets live output |
| **stdin/stdout** | (no flags) | Fallback / manual testing |

---

## License

MIT — see [LICENSE](LICENSE).
