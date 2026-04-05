#Requires -Version 5.1
# dap_server.ps1 — PowerShell 5.1 DAP adapter for nvim-dap
# Communicates over stdin/stdout using the DAP wire format.

Set-StrictMode -Off
$ErrorActionPreference = 'Continue'

# ---------------------------------------------------------------------------
# I/O helpers — DAP wire format: "Content-Length: N\r\n\r\n<json>"
# ---------------------------------------------------------------------------

function Read-DapMessage {
    $headerBuf = [System.Text.StringBuilder]::new()
    $prevChar  = $null
    $contentLength = $null

    # Read header lines until we hit the blank line (\r\n\r\n)
    while ($true) {
        $ch = [char][Console]::Read()
        if ($ch -eq "`n" -and $prevChar -eq "`r") {
            $line = $headerBuf.ToString().TrimEnd("`r")
            $headerBuf.Clear() | Out-Null
            if ($line -eq '') {
                break   # blank line => end of headers
            }
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
        $read   = [Console]::In.Read($buf, $total, $contentLength - $total)
        if ($read -le 0) { break }
        $total += $read
    }
    $json = New-Object string (, $buf)
    try {
        return ConvertFrom-Json $json
    } catch {
        return $null
    }
}

function Write-DapMessage {
    param([hashtable]$Message)
    $json  = ConvertTo-Json $Message -Depth 20 -Compress
    $bytes = [System.Text.Encoding]::UTF8.GetByteCount($json)
    $wire  = "Content-Length: $bytes`r`n`r`n$json"
    [Console]::Out.Write($wire)
    [Console]::Out.Flush()
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
$script:runspace        = $null
$script:ps              = $null
$script:debuggerStop    = $null   # InvocationInfo / CallStackFrame at stop
$script:stopEvent       = $null   # ManualResetEventSlim to block script thread
$script:resumeAction    = 'Continue'
$script:breakpoints     = @{}     # file -> list of PSBreakpoint ids
$script:launched        = $false
$script:configDone      = $false
$script:localVarsAtStop = @{}
$script:scriptVars      = @{}
$script:globalVars      = @{}
$script:callStack       = @()

# ---------------------------------------------------------------------------
# Launch the script in a separate runspace
# ---------------------------------------------------------------------------
function Start-DebugTarget {
    param([string]$Program, [string[]]$Args, [string]$Cwd)

    $script:stopEvent = New-Object System.Threading.ManualResetEventSlim($false)

    $iss = [System.Management.Automation.Runspaces.InitialSessionState]::CreateDefault()
    $script:runspace = [System.Management.Automation.Runspaces.RunspaceFactory]::CreateRunspace($iss)
    $script:runspace.Open()

    # Hook debugger events on the runspace's debugger
    $debugger = $script:runspace.Debugger

    # DebuggerStop — fired at breakpoints / steps
    Register-ObjectEvent -InputObject $debugger -EventName 'DebuggerStop' -Action {
        $eventArgs = $Event.SourceEventArgs  # DebuggerStopEventArgs
        $script:callStack       = @($eventArgs.InvocationInfo)
        $script:debuggerStop    = $eventArgs

        # Capture variables from the stop context
        $cmd = [System.Management.Automation.PowerShell]::Create()
        $cmd.Runspace = $script:runspace
        try {
            $cmd.AddScript('Get-Variable -Scope 0 -ErrorAction SilentlyContinue') | Out-Null
            $vars = $cmd.Invoke()
            $script:localVarsAtStop = @{}
            foreach ($v in $vars) { $script:localVarsAtStop[$v.Name] = $v.Value }
        } catch {}
        try {
            $cmd.Commands.Clear()
            $cmd.AddScript('Get-Variable -Scope Script -ErrorAction SilentlyContinue') | Out-Null
            $svars = $cmd.Invoke()
            $script:scriptVars = @{}
            foreach ($v in $svars) { $script:scriptVars[$v.Name] = $v.Value }
        } catch {}
        try {
            $cmd.Commands.Clear()
            $cmd.AddScript('Get-Variable -Scope Global -ErrorAction SilentlyContinue') | Out-Null
            $gvars = $cmd.Invoke()
            $script:globalVars = @{}
            foreach ($v in $gvars) { $script:globalVars[$v.Name] = $v.Value }
        } catch {}
        $cmd.Dispose()

        Reset-VarStore

        # Determine stop reason
        $reason = 'breakpoint'
        if ($eventArgs.Breakpoints.Count -eq 0) { $reason = 'step' }

        Send-Event (New-Event 'stopped' @{
            reason            = $reason
            threadId          = 1
            allThreadsStopped = $true
        })

        # Block until DAP client sends continue/next/etc.
        $script:stopEvent.Reset()
        $script:stopEvent.Wait()

        # Set the resume action on the event args
        $eventArgs.ResumeAction = [System.Management.Automation.DebuggerResumeAction]($script:resumeAction)
    } | Out-Null

    # BreakpointUpdated event (informational)
    Register-ObjectEvent -InputObject $debugger -EventName 'BreakpointUpdated' -Action {} | Out-Null

    # Run the target script asynchronously
    $script:ps = [System.Management.Automation.PowerShell]::Create()
    $script:ps.Runspace = $script:runspace

    if ($Cwd) {
        $escapedCwd = $Cwd -replace "'", "''"
        $script:ps.AddScript("Set-Location '$escapedCwd'") | Out-Null
        $script:ps.Invoke() | Out-Null
        $script:ps.Commands.Clear()
    }

    # Build the script invocation — pass args if any
    $escapedProgram = $Program -replace "'", "''"
    if ($Args -and $Args.Count -gt 0) {
        $argStr = ($Args | ForEach-Object { "'$($_ -replace "'","''")'" }) -join ' '
        $script:ps.AddScript("& '$escapedProgram' $argStr") | Out-Null
    } else {
        $script:ps.AddScript("& '$escapedProgram'") | Out-Null
    }

    # Capture output streams
    $script:ps.Streams.Information.add_DataAdded({
        param($sender, $e)
        $record = $sender[$e.Index]
        Send-Output "$($record.MessageData)`n" 'stdout'
    })
    $script:ps.Streams.Warning.add_DataAdded({
        param($sender, $e)
        $record = $sender[$e.Index]
        Send-Output "WARNING: $($record.Message)`n" 'stderr'
    })
    $script:ps.Streams.Error.add_DataAdded({
        param($sender, $e)
        $record = $sender[$e.Index]
        Send-Output "ERROR: $($record.ToString())`n" 'stderr'
    })
    $script:ps.Streams.Verbose.add_DataAdded({
        param($sender, $e)
        $record = $sender[$e.Index]
        Send-Output "VERBOSE: $($record.Message)`n" 'stdout'
    })

    # Redirect Write-Host / standard output via InformationStream merge
    $psInvokeSettings = New-Object System.Management.Automation.PSInvocationSettings
    $psInvokeSettings.AddToHistory = $false

    $callback = [System.AsyncCallback] {
        param($asyncResult)
        try {
            $script:ps.EndInvoke($asyncResult)
        } catch {}
        Send-Event (New-Event 'terminated' @{})
        Send-Event (New-Event 'exited' @{ exitCode = 0 })
    }

    $script:ps.BeginInvoke([System.Management.Automation.PSDataCollection[System.Management.Automation.PSObject]]$null,
                           $psInvokeSettings, $callback, $null) | Out-Null
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
                    Start-DebugTarget -Program $program -Args $launchArgs -Cwd $cwd
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
                if (-not $script:runspace) {
                    # Runspace not ready yet — queue breakpoints to set after launch
                    Send-Response (New-Response $seq 'setBreakpoints' $true @{ breakpoints = @() })
                    break
                }
                $source = if ($args -and $args.PSObject.Properties['source'] -and
                              $args.source.PSObject.Properties['path']) { $args.source.path } else { $null }
                $bpLines = if ($args -and $args.PSObject.Properties['breakpoints']) { @($args.breakpoints) } else { @() }

                if (-not $source) {
                    Send-ErrorResponse $seq 'setBreakpoints' "No source path provided"
                    break
                }

                $verified = Set-DapBreakpoints -Source $source -BreakpointLines $bpLines
                Send-Response (New-Response $seq 'setBreakpoints' $true @{ breakpoints = $verified })
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
                    stackFrames = $frames
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

                Send-Response (New-Response $seq 'variables' $true @{ variables = $results })
            }

            'evaluate' {
                $expression = if ($args -and $args.PSObject.Properties['expression']) { $args.expression } else { '' }
                if (-not $script:runspace) {
                    Send-ErrorResponse $seq 'evaluate' 'No active debug session'
                    break
                }
                try {
                    $cmd = [System.Management.Automation.PowerShell]::Create()
                    $cmd.Runspace = $script:runspace
                    $cmd.AddScript($expression) | Out-Null
                    $evalResult = $cmd.Invoke()
                    $cmd.Dispose()

                    $resultStr = if ($evalResult -and $evalResult.Count -gt 0) {
                        ($evalResult | Out-String).Trim()
                    } else {
                        ''
                    }
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
