#Requires -Version 5.1
# dap_server.ps1 — PowerShell 5.1 DAP adapter for nvim-dap
#
# Communication modes:
#   Default (-Port 0)  : stdin/stdout DAP wire format
#   TCP     (-Port N)  : listen on loopback TCP port N for DAP;
#                        stdout/stderr are then free for the terminal buffer
#
# -ReadyFile <path>    : write this file once the TCP listener is active so
#                        the Lua side knows it is safe to connect.

param(
    [int]$Port      = 0,
    [string]$ReadyFile = ''
)

Set-StrictMode -Off
$ErrorActionPreference = 'Continue'

# Force BOM-less UTF-8 on all output streams to prevent DAP header corruption.
# In .NET Framework (PowerShell 5.1) [System.Text.Encoding]::UTF8 includes a
# BOM preamble; we must create the encoding explicitly with $false to suppress it.
$utf8NoBom = New-Object System.Text.UTF8Encoding($false)
[Console]::OutputEncoding = $utf8NoBom
[Console]::InputEncoding  = $utf8NoBom
$OutputEncoding           = $utf8NoBom

# ---------------------------------------------------------------------------
# I/O abstraction — DAP reader/writer backed by stdin/stdout or TCP stream
# ---------------------------------------------------------------------------

$script:useTcp    = $Port -gt 0
$script:dapReader = $null
$script:dapWriter = $null
$script:dapLock   = [System.Object]::new()  # guards dapWriter
$script:termLock  = [System.Object]::new()  # guards Console::Out in TCP mode

if ($script:useTcp) {
    $listener = New-Object System.Net.Sockets.TcpListener(
        [System.Net.IPAddress]::Loopback, $Port)
    $listener.Start()

    # Signal readiness AFTER the listener is bound so the Lua side can connect
    if ($ReadyFile -ne '') {
        [System.IO.File]::WriteAllText($ReadyFile, 'ready')
    }

    $tcpClient = $listener.AcceptTcpClient()
    $listener.Stop()

    $netStream            = $tcpClient.GetStream()
    $script:dapReader     = New-Object System.IO.StreamReader(
        $netStream, $utf8NoBom)
    $script:dapWriter     = New-Object System.IO.StreamWriter(
        $netStream, $utf8NoBom)
    $script:dapWriter.AutoFlush = $true
} else {
    $script:dapReader = [Console]::In
    $script:dapWriter = New-Object System.IO.StreamWriter(
        [Console]::OpenStandardOutput(), $utf8NoBom)
    $script:dapWriter.AutoFlush = $true
}

# ---------------------------------------------------------------------------
# I/O helpers — DAP wire format: "Content-Length: N\r\n\r\n<json>"
# ---------------------------------------------------------------------------

function Read-DapMessage {
    $headerBuf     = [System.Text.StringBuilder]::new()
    $prevChar      = $null
    $contentLength = $null

    while ($true) {
        $ch = [char]$script:dapReader.Read()
        if ($ch -eq "`n" -and $prevChar -eq "`r") {
            $line = $headerBuf.ToString().TrimEnd("`r")
            $headerBuf.Clear() | Out-Null
            if ($line -eq '') { break }
            if ($line -match '^Content-Length:\s*(\d+)') {
                $contentLength = [int]$Matches[1]
            }
        } else {
            $headerBuf.Append($ch) | Out-Null
        }
        $prevChar = $ch
    }

    if ($null -eq $contentLength) { return $null }

    $buf   = New-Object char[] $contentLength
    $total = 0
    while ($total -lt $contentLength) {
        $read = $script:dapReader.Read($buf, $total, $contentLength - $total)
        if ($read -le 0) { break }
        $total += $read
    }
    $json = New-Object string (, $buf)
    try { return ConvertFrom-Json $json } catch { return $null }
}

function Write-DapMessage {
    param([hashtable]$Message)
    $json  = ConvertTo-Json $Message -Depth 20 -Compress
    $bytes = [System.Text.Encoding]::UTF8.GetByteCount($json)
    $wire  = "Content-Length: $bytes`r`n`r`n$json"
    [System.Threading.Monitor]::Enter($script:dapLock)
    try {
        $script:dapWriter.Write($wire)
        $script:dapWriter.Flush()
    } finally {
        [System.Threading.Monitor]::Exit($script:dapLock)
    }
}

# Write text directly to the terminal window.
# In TCP mode Console::Out is the terminal buffer, not the DAP socket.
# In stdin/stdout mode this is a no-op (stdout is the DAP socket).
function Write-TerminalOutput {
    param([string]$Text)
    if (-not $script:useTcp) { return }
    [System.Threading.Monitor]::Enter($script:termLock)
    try {
        [Console]::Out.Write($Text)
        [Console]::Out.Flush()
    } finally {
        [System.Threading.Monitor]::Exit($script:termLock)
    }
}

# ---------------------------------------------------------------------------
# Sequence counter
# ---------------------------------------------------------------------------
$script:seq = 0
function Next-Seq { $script:seq++; $script:seq }

# ---------------------------------------------------------------------------
# Response / event builders
# ---------------------------------------------------------------------------
function New-Response {
    param($RequestSeq, $Command, [bool]$Success = $true, $Body = $null, $Message = '')
    $r = @{
        seq        = Next-Seq
        type       = 'response'
        request_seq = $RequestSeq
        success    = $Success
        command    = $Command
    }
    if ($Body)    { $r.body    = $Body    }
    if ($Message) { $r.message = $Message }
    $r
}

function New-Event {
    param($EventName, $Body = $null)
    $e = @{
        seq   = Next-Seq
        type  = 'event'
        event = $EventName
    }
    if ($Body) { $e.body = $Body }
    $e
}

function Send-Response { param($R) Write-DapMessage $R }
function Send-Event    { param($E) Write-DapMessage $E }

function Send-Output {
    param([string]$Text, [string]$Category = 'stdout')
    Send-Event (New-Event 'output' @{ category = $Category; output = $Text })
}

function Send-ErrorResponse {
    param($RequestSeq, $Command, [string]$Msg)
    Send-Response (New-Response $RequestSeq $Command $false $null $Msg)
    Send-Output "[dap_server error] $Msg`n" 'stderr'
}

# ---------------------------------------------------------------------------
# Variable reference store — used to drill into nested objects
# ---------------------------------------------------------------------------
$script:varStore   = @{}
$script:varStoreId = 0

function New-VarRef {
    param($Value)
    $script:varStoreId++
    $script:varStore[$script:varStoreId] = $Value
    $script:varStoreId
}

function Reset-VarStore {
    $script:varStore   = @{}
    $script:varStoreId = 0
}

function ConvertTo-DapVariable {
    param([string]$Name, $Value, [int]$Depth = 0)

    $typeName = if ($null -eq $Value) { 'null' } else { $Value.GetType().Name }
    $varRef   = 0

    if ($null -eq $Value) {
        $display = 'null'
    } elseif ($Value -is [System.Collections.IDictionary]) {
        $display = "[hashtable/$typeName] ($($Value.Count) keys)"
        if ($Depth -lt 4) { $varRef = New-VarRef $Value }
    } elseif ($Value -is [System.Collections.IEnumerable] -and $Value -isnot [string]) {
        $arr     = @($Value)
        $display = "[$typeName] ($($arr.Count) items)"
        if ($Depth -lt 4) { $varRef = New-VarRef $Value }
    } elseif ($Value -is [System.Management.Automation.PSCustomObject] -or
              $Value -is [System.Management.Automation.PSObject]) {
        $props   = $Value.PSObject.Properties
        $display = "[$typeName] ($($props.Count) props)"
        if ($Depth -lt 4) { $varRef = New-VarRef $Value }
    } elseif ($typeName -in @('Boolean','Int32','Int64','Double','Single','Decimal')) {
        $display = "$Value"
    } else {
        $str = try { "$Value" } catch { '<error>' }
        $display = if ($str.Length -gt 200) { $str.Substring(0, 200) + '...' } else { $str }
    }

    @{
        name               = "$Name"
        value              = "$display"
        type               = $typeName
        variablesReference = $varRef
    }
}

function Get-ChildVariables {
    param($Container, [int]$Depth = 1)
    $results = @()
    if ($null -eq $Container) { return $results }

    if ($Container -is [System.Collections.IDictionary]) {
        foreach ($key in $Container.Keys) {
            $results += ConvertTo-DapVariable "$key" $Container[$key] $Depth
        }
    } elseif ($Container -is [System.Collections.IEnumerable] -and $Container -isnot [string]) {
        $i = 0
        foreach ($item in $Container) {
            $results += ConvertTo-DapVariable "[$i]" $item $Depth
            $i++
        }
    } else {
        foreach ($prop in $Container.PSObject.Properties) {
            $val = try { $prop.Value } catch { '<error>' }
            $results += ConvertTo-DapVariable $prop.Name $val $Depth
        }
    }
    $results
}

# ---------------------------------------------------------------------------
# Scope variable-reference constants
# ---------------------------------------------------------------------------
$SCOPE_LOCAL  = 1000
$SCOPE_SCRIPT = 1001
$SCOPE_GLOBAL = 1002

# ---------------------------------------------------------------------------
# Debugger state
# ---------------------------------------------------------------------------
$script:runspace            = $null
$script:ps                  = $null
$script:debuggerStop        = $null   # DebuggerStopEventArgs when paused at bp/step
$script:stopEvent           = $null   # ManualResetEventSlim — blocks the script thread
$script:resumeAction        = 'Continue'
$script:breakpoints         = @{}     # file path -> list of PSBreakpoint ids
$script:pendingBreakpoints  = @()     # breakpoint requests queued before runspace exists
$script:launched            = $false
$script:configDone          = $false
$script:localVarsAtStop     = @{}
$script:scriptVars          = @{}
$script:globalVars          = @{}

# ---------------------------------------------------------------------------
# Launch the target script in a separate runspace
# ---------------------------------------------------------------------------
function Start-DebugTarget {
    param([string]$Program, [string[]]$Args, [string]$Cwd, $PendingBreakpoints = @())

    $script:stopEvent = [System.Threading.ManualResetEventSlim]::new($false)

    $iss             = [System.Management.Automation.Runspaces.InitialSessionState]::CreateDefault()
    $script:runspace = [System.Management.Automation.Runspaces.RunspaceFactory]::CreateRunspace($iss)
    $script:runspace.Open()
    $script:runspace.Debugger.SetDebugMode([System.Management.Automation.DebugModes]::LocalScript)

    $debugger = $script:runspace.Debugger

    # DebuggerStop — fired at every breakpoint and step.
    # Use add_DebuggerStop() (direct .NET event subscription) so the handler runs
    # synchronously on the debuggee's thread. Register-ObjectEvent would queue the
    # event to a different runspace/thread, meaning the script thread never actually
    # blocks and $eventArgs.ResumeAction is never read by the debugger.
    $script:debuggerStopHandler = {
        param($sender, $eventArgs)

        # Snapshot variables from the paused frame
        $capturePs = [System.Management.Automation.PowerShell]::Create()
        $capturePs.Runspace = $script:runspace
        try {
            $capturePs.AddScript('Get-Variable -Scope 0 -ErrorAction SilentlyContinue') | Out-Null
            $script:localVarsAtStop = @{}
            foreach ($v in $capturePs.Invoke()) { $script:localVarsAtStop[$v.Name] = $v.Value }
        } catch {}
        try {
            $capturePs.Commands.Clear()
            $capturePs.AddScript('Get-Variable -Scope Script -ErrorAction SilentlyContinue') | Out-Null
            $script:scriptVars = @{}
            foreach ($v in $capturePs.Invoke()) { $script:scriptVars[$v.Name] = $v.Value }
        } catch {}
        try {
            $capturePs.Commands.Clear()
            $capturePs.AddScript('Get-Variable -Scope Global -ErrorAction SilentlyContinue') | Out-Null
            $script:globalVars = @{}
            foreach ($v in $capturePs.Invoke()) { $script:globalVars[$v.Name] = $v.Value }
        } catch {}
        $capturePs.Dispose()

        $script:debuggerStop = $eventArgs
        Reset-VarStore

        $reason = if ($eventArgs.Breakpoints.Count -eq 0) { 'step' } else { 'breakpoint' }
        Send-Event (New-Event 'stopped' @{
            reason            = $reason
            threadId          = 1
            allThreadsStopped = $true
        })

        # Block the debuggee's thread until the DAP client sends continue / next / stepIn / stepOut
        $script:stopEvent.Reset()
        $script:stopEvent.Wait()

        # Use ProcessCommand() to properly resume the debugger in PowerShell 5.1.
        # Directly setting $eventArgs.ResumeAction is not sufficient when using
        # BeginInvoke() — the debugger drops into an interactive prompt and the
        # runspace becomes corrupted. ProcessCommand() is the correct mechanism,
        # as used by PowerShell Editor Services (PSES).
        $debuggerCommandMap = @{
            'Continue' = 'c'
            'StepOver' = 'v'
            'StepInto' = 's'
            'StepOut'  = 'o'
        }
        $dbgCmd = $debuggerCommandMap[$script:resumeAction]
        if (-not $dbgCmd) { $dbgCmd = 'c' }  # fallback to continue

        $psCmd = [System.Management.Automation.PSCommand]::new()
        $psCmd.AddScript($dbgCmd) | Out-Null
        $dbgOutput = New-Object 'System.Management.Automation.PSDataCollection[psobject]'
        $dbgResult = $sender.ProcessCommand($psCmd, $dbgOutput)
        $eventArgs.ResumeAction  = $dbgResult.ResumeAction
        $script:debuggerStop     = $null
    }
    $debugger.add_DebuggerStop($script:debuggerStopHandler)

    # Register an empty BreakpointUpdated handler so the event is acknowledged.
    # Stored in a script variable so it can be unregistered on disconnect.
    $script:breakpointUpdatedHandler = {}
    $debugger.add_BreakpointUpdated($script:breakpointUpdatedHandler)

    # ---- Build the PowerShell invocation ----
    $script:ps          = [System.Management.Automation.PowerShell]::Create()
    $script:ps.Runspace = $script:runspace

    # Ensure Write-Host flows through the Information stream (PS 5+)
    $script:ps.AddScript('$global:InformationPreference = "Continue"') | Out-Null
    $script:ps.Invoke() | Out-Null
    $script:ps.Commands.Clear()

    if ($Cwd) {
        $escapedCwd = $Cwd -replace "'", "''"
        $script:ps.AddScript("Set-Location '$escapedCwd'") | Out-Null
        $script:ps.Invoke() | Out-Null
        $script:ps.Commands.Clear()
    }

    $escapedProgram = $Program -replace "'", "''"
    if ($Args -and $Args.Count -gt 0) {
        $argStr = ($Args | ForEach-Object { "'$($_ -replace "'","''")'" }) -join ' '
        $script:ps.AddScript("& '$escapedProgram' $argStr") | Out-Null
    } else {
        $script:ps.AddScript("& '$escapedProgram'") | Out-Null
    }

    # Information stream — Write-Host in PS 5+ arrives here
    $script:ps.Streams.Information.add_DataAdded({
        param($sender, $e)
        $record = $sender[$e.Index]
        $msg = if ($record.MessageData -is [System.Management.Automation.HostInformationMessage]) {
            $record.MessageData.Message
        } else {
            "$($record.MessageData)"
        }
        Write-TerminalOutput "$msg`n"
        Send-Output "$msg`n" 'stdout'
    })

    $script:ps.Streams.Warning.add_DataAdded({
        param($sender, $e)
        $record = $sender[$e.Index]
        Write-TerminalOutput "WARNING: $($record.Message)`n"
        Send-Output "WARNING: $($record.Message)`n" 'stderr'
    })

    $script:ps.Streams.Error.add_DataAdded({
        param($sender, $e)
        $record = $sender[$e.Index]
        Write-TerminalOutput "ERROR: $($record.ToString())`n"
        Send-Output "ERROR: $($record.ToString())`n" 'stderr'
    })

    $script:ps.Streams.Verbose.add_DataAdded({
        param($sender, $e)
        $record = $sender[$e.Index]
        Write-TerminalOutput "VERBOSE: $($record.Message)`n"
        Send-Output "VERBOSE: $($record.Message)`n" 'stdout'
    })

    # Output collection captures Write-Output and plain pipeline results
    $inputCol  = New-Object 'System.Management.Automation.PSDataCollection[psobject]'
    $inputCol.Complete()
    $outputCol = New-Object 'System.Management.Automation.PSDataCollection[psobject]'
    $outputCol.add_DataAdded({
        param($sender, $e)
        $record = $sender[$e.Index]
        $str = try {
            if ($record -is [string]) { $record }
            else { ($record | Out-String).TrimEnd("`r`n") }
        } catch { '<output>' }
        if ($str -ne '') {
            Write-TerminalOutput "$str`n"
            Send-Output "$str`n" 'stdout'
        }
    })

    $psSettings             = New-Object System.Management.Automation.PSInvocationSettings
    $psSettings.AddToHistory = $false

    $callback = [System.AsyncCallback]{
        param($asyncResult)
        try { $script:ps.EndInvoke($asyncResult) } catch {}
        Send-Event (New-Event 'terminated' @{})
        Send-Event (New-Event 'exited' @{ exitCode = 0 })
    }

    # Apply any breakpoints that arrived before the runspace was created,
    # so they are set BEFORE the target script begins executing.
    foreach ($pending in $PendingBreakpoints) {
        Set-DapBreakpoints -Source $pending.source -BreakpointLines $pending.lines | Out-Null
    }

    $script:ps.BeginInvoke($inputCol, $outputCol, $psSettings, $callback, $null) | Out-Null
}

# ---------------------------------------------------------------------------
# Set breakpoints helper
# ---------------------------------------------------------------------------
function Set-DapBreakpoints {
    param([string]$Source, $BreakpointLines)

    # Clear existing breakpoints for this file
    if ($script:breakpoints.ContainsKey($Source)) {
        foreach ($bpId in $script:breakpoints[$Source]) {
            $cmd = [System.Management.Automation.PowerShell]::Create()
            $cmd.Runspace = $script:runspace
            $cmd.AddCommand('Remove-PSBreakpoint').AddParameter('Id', $bpId) | Out-Null
            try { $cmd.Invoke() | Out-Null } catch {}
            $cmd.Dispose()
        }
    }
    $script:breakpoints[$Source] = @()

    $verified = @()
    foreach ($bp in $BreakpointLines) {
        $line   = $bp.line
        $cmd    = [System.Management.Automation.PowerShell]::Create()
        $cmd.Runspace = $script:runspace
        $cmd.AddCommand('Set-PSBreakpoint').AddParameter('Script', $Source).AddParameter('Line', $line) | Out-Null
        try {
            $result = $cmd.Invoke()
            if ($result -and $result.Count -gt 0) {
                $script:breakpoints[$Source] += $result[0].Id
            }
            $verified += @{ verified = $true; line = $line }
        } catch {
            $verified += @{ verified = $false; line = $line; message = $_.Exception.Message }
        }
        $cmd.Dispose()
    }
    $verified
}

# ---------------------------------------------------------------------------
# Main message loop
# ---------------------------------------------------------------------------
function Invoke-DapServer {
    while ($true) {
        $msg = Read-DapMessage
        if ($null -eq $msg) { continue }

        $seq     = $msg.seq
        $command = $msg.command
        $args    = if ($msg.PSObject.Properties['arguments']) { $msg.arguments } else { $null }

        switch ($command) {

            'initialize' {
                Send-Response (New-Response $seq 'initialize' $true @{
                    supportsConfigurationDoneRequest      = $true
                    supportsFunctionBreakpoints           = $false
                    supportsConditionalBreakpoints        = $false
                    supportsEvaluateForHovers             = $true
                    supportsStepBack                      = $false
                    supportsSetVariable                   = $false
                    supportsRestartRequest                = $false
                    supportsTerminateRequest              = $false
                    supportsExceptionOptions              = $false
                    supportsValueFormattingOptions        = $false
                    supportsExceptionInfoRequest          = $false
                    supportTerminateDebuggee              = $true
                    supportsDelayedStackTraceLoading      = $false
                    supportsLoadedSourcesRequest          = $false
                    supportsLogPoints                     = $false
                    supportsTerminateThreadsRequest       = $false
                    supportsSetExpression                 = $false
                    supportsGotoTargetsRequest            = $false
                    supportsCompletionsRequest            = $false
                    supportsModulesRequest                = $false
                    supportsRestartFrame                  = $false
                    supportsStepInTargetsRequest          = $false
                    supportsDataBreakpoints               = $false
                    supportsReadMemoryRequest             = $false
                    supportsDisassembleRequest            = $false
                    supportsCancelRequest                 = $false
                    supportsBreakpointLocationsRequest    = $false
                    supportsClipboardContext              = $false
                    supportsSteppingGranularity           = $false
                    supportsInstructionBreakpoints        = $false
                    supportsExceptionFilterOptions        = $false
                })
                Send-Event (New-Event 'initialized')
            }

            'launch' {
                $program = if ($args -and $args.PSObject.Properties['program']) { $args.program } else { $null }
                if (-not $program) {
                    Send-ErrorResponse $seq 'launch' "Missing 'program' in launch arguments"
                    break
                }
                $launchArgs = if ($args -and $args.PSObject.Properties['args'])    { @($args.args) }    else { @() }
                $cwd        = if ($args -and $args.PSObject.Properties['cwd'])     { $args.cwd }        else { $null }

                try {
                    Start-DebugTarget -Program $program -Args $launchArgs -Cwd $cwd -PendingBreakpoints $script:pendingBreakpoints
                    $script:pendingBreakpoints = @()
                    $script:launched = $true
                    Send-Response (New-Response $seq 'launch' $true)
                } catch {
                    Send-ErrorResponse $seq 'launch' "Failed to launch: $($_.Exception.Message)"
                }
            }

            'configurationDone' {
                $script:configDone = $true
                Send-Response (New-Response $seq 'configurationDone' $true)
            }

            'setBreakpoints' {
                $source  = if ($args -and $args.PSObject.Properties['source'] -and
                               $args.source.PSObject.Properties['path']) { $args.source.path } else { $null }
                $bpLines = if ($args -and $args.PSObject.Properties['breakpoints']) { @($args.breakpoints) } else { @() }

                if (-not $source) {
                    Send-ErrorResponse $seq 'setBreakpoints' "No source path provided"
                    break
                }

                if (-not $script:runspace) {
                    # Runspace not ready yet — queue for after launch and respond with unverified
                    $script:pendingBreakpoints += @{ source = $source; lines = $bpLines }
                    $unverified = @($bpLines | ForEach-Object { @{ verified = $false; line = $_.line } })
                    Send-Response (New-Response $seq 'setBreakpoints' $true @{ breakpoints = $unverified })
                    break
                }

                $verified = Set-DapBreakpoints -Source $source -BreakpointLines $bpLines
                Send-Response (New-Response $seq 'setBreakpoints' $true @{ breakpoints = @($verified) })
            }

            'threads' {
                Send-Response (New-Response $seq 'threads' $true @{
                    threads = @(@{ id = 1; name = 'Main Thread' })
                })
            }

            'stackTrace' {
                if ($null -eq $script:debuggerStop) {
                    Send-Response (New-Response $seq 'stackTrace' $true @{
                        stackFrames = @()
                        totalFrames = 0
                    })
                    break
                }

                $frames = @()
                try {
                    $cmd = [System.Management.Automation.PowerShell]::Create()
                    $cmd.Runspace = $script:runspace
                    $cmd.AddScript('Get-PSCallStack') | Out-Null
                    $stack = $cmd.Invoke()
                    $cmd.Dispose()

                    $frameId = 0
                    foreach ($frame in $stack) {
                        $scriptPath = if ($frame.ScriptName) { $frame.ScriptName } else { '<unknown>' }
                        $lineNo     = if ($frame.ScriptLineNumber) { [int]$frame.ScriptLineNumber } else { 0 }
                        $funcName   = if ($frame.FunctionName) { $frame.FunctionName } else { '<script>' }
                        $frames += @{
                            id     = $frameId
                            name   = $funcName
                            source = @{ path = $scriptPath; name = [System.IO.Path]::GetFileName($scriptPath) }
                            line   = $lineNo
                            column = 0
                        }
                        $frameId++
                    }
                } catch {
                    # Fallback: use InvocationInfo from DebuggerStop
                    $inv = $script:debuggerStop.InvocationInfo
                    if ($inv) {
                        $frames = @(@{
                            id     = 0
                            name   = if ($inv.MyCommand) { $inv.MyCommand.Name } else { '<script>' }
                            source = @{
                                path = if ($inv.ScriptName) { $inv.ScriptName } else { '' }
                                name = if ($inv.ScriptName) { [System.IO.Path]::GetFileName($inv.ScriptName) } else { '' }
                            }
                            line   = if ($inv.ScriptLineNumber) { [int]$inv.ScriptLineNumber } else { 0 }
                            column = if ($inv.OffsetInLine)     { [int]$inv.OffsetInLine }     else { 0 }
                        })
                    }
                }

                Send-Response (New-Response $seq 'stackTrace' $true @{
                    stackFrames = @($frames)
                    totalFrames = $frames.Count
                })
            }

            'scopes' {
                $frameId = if ($args -and $args.PSObject.Properties['frameId']) { $args.frameId } else { 0 }
                Send-Response (New-Response $seq 'scopes' $true @{
                    scopes = @(
                        @{ name = 'Local';  variablesReference = $SCOPE_LOCAL;  expensive = $false }
                        @{ name = 'Script'; variablesReference = $SCOPE_SCRIPT; expensive = $false }
                        @{ name = 'Global'; variablesReference = $SCOPE_GLOBAL; expensive = $true  }
                    )
                })
            }

            'variables' {
                $varRef  = if ($args -and $args.PSObject.Properties['variablesReference']) { [int]$args.variablesReference } else { 0 }
                $results = @()

                if ($varRef -eq $SCOPE_LOCAL) {
                    foreach ($kv in $script:localVarsAtStop.GetEnumerator()) {
                        $results += ConvertTo-DapVariable $kv.Key $kv.Value
                    }
                } elseif ($varRef -eq $SCOPE_SCRIPT) {
                    foreach ($kv in $script:scriptVars.GetEnumerator()) {
                        $results += ConvertTo-DapVariable $kv.Key $kv.Value
                    }
                } elseif ($varRef -eq $SCOPE_GLOBAL) {
                    foreach ($kv in $script:globalVars.GetEnumerator()) {
                        $results += ConvertTo-DapVariable $kv.Key $kv.Value
                    }
                } elseif ($script:varStore.ContainsKey($varRef)) {
                    $container = $script:varStore[$varRef]
                    $results   = Get-ChildVariables $container
                } else {
                    $results = @()
                }

                Send-Response (New-Response $seq 'variables' $true @{ variables = @($results) })
            }

            'evaluate' {
                $expression = if ($args -and $args.PSObject.Properties['expression']) { $args.expression } else { '' }
                if (-not $script:runspace) {
                    Send-ErrorResponse $seq 'evaluate' 'No active debug session'
                    break
                }
                try {
                    $psOutput = New-Object 'System.Management.Automation.PSDataCollection[psobject]'

                    if ($null -ne $script:debuggerStop) {
                        # Debugger is paused — use ProcessCommand to evaluate inside
                        # the current stack frame.  This gives access to local vars.
                        $psCmd = [System.Management.Automation.PSCommand]::new()
                        $psCmd.AddScript($expression) | Out-Null
                        $script:runspace.Debugger.ProcessCommand($psCmd, $psOutput) | Out-Null
                    } else {
                        # Script is running — use a fresh PS instance on same runspace
                        $ps2 = [System.Management.Automation.PowerShell]::Create()
                        $ps2.Runspace = $script:runspace
                        $ps2.AddScript($expression) | Out-Null
                        foreach ($item in $ps2.Invoke()) { [void]$psOutput.Add($item) }
                        $ps2.Dispose()
                    }

                    $resultStr = if ($psOutput.Count -gt 0) {
                        ($psOutput | ForEach-Object { "$_" }) -join "`n"
                    } else { '' }

                    # Mirror the result in the terminal window as well
                    if ($resultStr -ne '') { Write-TerminalOutput "$resultStr`n" }

                    Send-Response (New-Response $seq 'evaluate' $true @{
                        result             = $resultStr
                        variablesReference = 0
                    })
                } catch {
                    Send-ErrorResponse $seq 'evaluate' $_.Exception.Message
                }
            }

            'continue' {
                $script:resumeAction = 'Continue'
                Send-Response (New-Response $seq 'continue' $true @{ allThreadsContinued = $true })
                if ($script:stopEvent) { $script:stopEvent.Set() }
            }

            'next' {
                $script:resumeAction = 'StepOver'
                Send-Response (New-Response $seq 'next' $true)
                if ($script:stopEvent) { $script:stopEvent.Set() }
            }

            'stepIn' {
                $script:resumeAction = 'StepInto'
                Send-Response (New-Response $seq 'stepIn' $true)
                if ($script:stopEvent) { $script:stopEvent.Set() }
            }

            'stepOut' {
                $script:resumeAction = 'StepOut'
                Send-Response (New-Response $seq 'stepOut' $true)
                if ($script:stopEvent) { $script:stopEvent.Set() }
            }

            'disconnect' {
                Send-Response (New-Response $seq 'disconnect' $true)
                # Unblock any waiting debugger stop
                $script:resumeAction = 'Continue'
                if ($script:stopEvent) { $script:stopEvent.Set() }
                # Give runspace a moment to finish, then clean up
                Start-Sleep -Milliseconds 300
                if ($script:ps -and $script:ps.InvocationStateInfo.State -eq 'Running') {
                    try { $script:ps.Stop() } catch {}
                }
                if ($script:runspace) {
                    # Remove direct event handlers before closing the runspace
                    try { $script:runspace.Debugger.remove_DebuggerStop($script:debuggerStopHandler) } catch {}
                    try { $script:runspace.Debugger.remove_BreakpointUpdated($script:breakpointUpdatedHandler) } catch {}
                    try { $script:runspace.Close() } catch {}
                    try { $script:runspace.Dispose() } catch {}
                }
                Send-Event (New-Event 'terminated' @{})
                Send-Event (New-Event 'exited' @{ exitCode = 0 })
                exit 0
            }

            default {
                # Unknown command — send empty success response to keep client happy
                Send-Response (New-Response $seq $command $true)
            }
        }
    }
}

# ---------------------------------------------------------------------------
# Entry point
# ---------------------------------------------------------------------------
try {
    Invoke-DapServer
} catch {
    Send-Output "[dap_server] Fatal error: $($_.Exception.Message)`n" 'stderr'
    exit 1
}
