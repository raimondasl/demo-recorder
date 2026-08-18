<#
.SYNOPSIS
  Load, validate, and pretty-print demo scenario files (JSON).

  Validation is intentionally strict: it is the safety net that catches the
  mistakes an LLM is most likely to make when generating a scenario (unknown
  actions, missing required fields, invented key names, bad enum values).
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:ValidActions = @(
    'wait','caption','narrate','launch','run','type','keys',
    'focus','window','click','screenshot','record','marker','prompt'
)
$script:Required = @{
    'wait'='';'caption'='text';'narrate'='text';'launch'='app';'run'='command';
    'type'='text';'keys'='keys';'focus'='';'window'='';'click'='x,y';
    'screenshot'='';'record'='op';'marker'='label';'prompt'='message'
}


# Apps that run a parent plus many child processes. Their content/renderer children
# have no MainWindowHandle, so targeting them by processName can select a handle-less
# process and the focus/window step then silently does nothing. Target by titleContains.
$script:MultiProcessApps = @(
    'chrome','msedge','msedgewebview2','firefox','brave','opera','vivaldi','iexplore',
    'code','slack','discord','teams','ms-teams','spotify','notion','obsidian','signal','postman','figma'
)

# Shared check for focus/window: flag processName values known to be multi-process.
function Test-MultiProcessTarget {
    param($Step, [string]$Loc, $Warnings)
    $pn = Get-Prop $Step 'processName'
    if (-not $pn) { return }
    $bare = ($pn -replace '\.exe$', '').ToLowerInvariant()
    if ($script:MultiProcessApps -contains $bare) {
        [void]$Warnings.Add("$Loc targets '$pn' by processName, but that app runs multiple processes whose child processes have no window handle - this step may silently do nothing. Use titleContains (a title belongs to a window), or launch it yourself and target it with 'as'.")
    }
}
function Get-Prop {
    # Returns the property value, or $Default when the property is absent or null.
    # NOTE: false/0/'' are valid values and are returned as-is (do NOT treat them
    # as "missing", or explicit booleans like submit:false would be overridden).
    param($Object, [string]$Name, $Default = $null)
    if ($null -eq $Object) { return $Default }
    $p = $Object.PSObject.Properties[$Name]
    if (-not $p) { return $Default }
    if ($null -eq $p.Value) { return $Default }
    return $p.Value
}

function Test-FieldMissing {
    # A required field counts as missing if absent, null, or an empty string.
    param($Object, [string]$Name)
    $v = Get-Prop $Object $Name
    return ($null -eq $v) -or ($v -is [string] -and $v -eq '')
}

function Read-DemoScenario {
    param([string]$Path)
    if (-not (Test-Path $Path)) { throw "Scenario file not found: $Path" }
    $raw = Get-Content -LiteralPath $Path -Raw -Encoding UTF8
    try { return ($raw | ConvertFrom-Json) }
    catch { throw "Scenario is not valid JSON ($Path): $($_.Exception.Message)" }
}

function Test-DemoScenario {
    param($Scenario)
    $errors   = New-Object System.Collections.ArrayList
    $warnings = New-Object System.Collections.ArrayList

    if (-not (Get-Prop $Scenario 'name'))  { [void]$warnings.Add("Top-level 'name' is missing (recommended).") }

    $steps = Get-Prop $Scenario 'steps'
    if (-not $steps) { [void]$errors.Add("Scenario has no 'steps' array."); return @{ Errors=$errors; Warnings=$warnings } }
    if ($steps -isnot [System.Array]) { $steps = @($steps) }

    # Recording mode (if present) must be known.
    $settings = Get-Prop $Scenario 'settings'
    $rec = Get-Prop $settings 'recording'
    $mode = Get-Prop $rec 'mode'
    if ($mode -and $mode -notin @('ffmpeg','manual','none','obs')) {
        [void]$errors.Add("settings.recording.mode '$mode' is invalid (ffmpeg|manual|none|obs).")
    }

    $i = 0
    foreach ($step in $steps) {
        $i++
        $action = Get-Prop $step 'action'
        $loc = "step #$i" + $(if (Get-Prop $step 'id') { " (id=$(Get-Prop $step 'id')) " } else { ' ' }) + "[$action]"
        if (-not $action) { [void]$errors.Add("$loc has no 'action'."); continue }
        if ($action -notin $script:ValidActions) {
            [void]$errors.Add("$loc unknown action. Valid: $($script:ValidActions -join ', ').")
            continue
        }
        # Required fields.
        $req = $script:Required[$action]
        if ($req) {
            foreach ($f in ($req -split ',')) {
                if (Test-FieldMissing $step $f) { [void]$errors.Add("$loc missing required field '$f'.") }
            }
        }
        # Per-action enum / shape checks.
        switch ($action) {
            'run' {
                $sh = Get-Prop $step 'shell'; if ($sh -and $sh -notin @('powershell','cmd')) { [void]$errors.Add("$loc shell '$sh' invalid (powershell|cmd).") }
                $ts = Get-Prop $step 'typeStyle'; if ($ts -and $ts -notin @('instant','human')) { [void]$errors.Add("$loc typeStyle '$ts' invalid (instant|human).") }
            }
            'type' {
                $ts = Get-Prop $step 'typeStyle'; if ($ts -and $ts -notin @('instant','human')) { [void]$errors.Add("$loc typeStyle '$ts' invalid (instant|human).") }
            }
            'keys' {
                $keys = Get-Prop $step 'keys'
                if ($keys) {
                    if ($keys -isnot [System.Array]) { $keys = @($keys) }
                    foreach ($k in $keys) {
                        try { [void](ConvertTo-SendKeysChord ([string]$k)) }
                        catch { [void]$errors.Add("$loc invalid key '$k': $($_.Exception.Message)") }
                    }
                }
            }
            'caption' {
                $pos = Get-Prop $step 'position'; if ($pos -and $pos -notin @('top','center','bottom')) { [void]$errors.Add("$loc position '$pos' invalid (top|center|bottom).") }
            }
            'click' {
                [void]$warnings.Add("$loc uses absolute screen coordinates, which are fragile across resolutions. Prefer keyboard-driven steps where possible.")
                $btn = Get-Prop $step 'button'; if ($btn -and $btn -notin @('left','right','double')) { [void]$errors.Add("$loc button '$btn' invalid (left|right|double).") }
            }
            'focus' {
                if (-not (Get-Prop $step 'as') -and -not (Get-Prop $step 'title') -and -not (Get-Prop $step 'titleContains') -and -not (Get-Prop $step 'processName')) {
                    [void]$errors.Add("$loc needs one of: as, title, titleContains, processName.")
                }
                Test-MultiProcessTarget -Step $step -Loc $loc -Warnings $warnings
            }
            'window' {
                if (-not (Get-Prop $step 'as') -and -not (Get-Prop $step 'title') -and -not (Get-Prop $step 'titleContains') -and -not (Get-Prop $step 'processName')) {
                    [void]$errors.Add("$loc needs a target: as, title, titleContains, or processName.")
                }
                $st = Get-Prop $step 'state'; if ($st -and $st -notin @('normal','maximized','minimized')) { [void]$errors.Add("$loc state '$st' invalid (normal|maximized|minimized).") }
                Test-MultiProcessTarget -Step $step -Loc $loc -Warnings $warnings
            }
            'record' {
                $op = Get-Prop $step 'op'; if ($op -and $op -notin @('start','stop')) { [void]$errors.Add("$loc op '$op' invalid (start|stop).") }
            }
            'wait' {
                if ($null -eq (Get-Prop $step 'seconds') -and $null -eq (Get-Prop $step 'ms')) { [void]$errors.Add("$loc needs 'seconds' or 'ms'.") }
            }
        }
    }
    return @{ Errors = $errors; Warnings = $warnings }
}

function Write-DemoScenarioPlan {
    param($Scenario)
    $name = Get-Prop $Scenario 'name' '(unnamed demo)'
    $desc = Get-Prop $Scenario 'description' ''
    $settings = Get-Prop $Scenario 'settings'
    $rec  = Get-Prop $settings 'recording'
    $mode = Get-Prop $rec 'mode' 'ffmpeg'

    Write-Host ''
    Write-Host "DEMO: $name" -ForegroundColor Cyan
    if ($desc) { Write-Host "      $desc" -ForegroundColor DarkGray }
    Write-Host "      recording mode: $mode" -ForegroundColor DarkGray
    Write-Host ''

    $steps = Get-Prop $Scenario 'steps'
    if ($steps -isnot [System.Array]) { $steps = @($steps) }
    $i = 0
    foreach ($step in $steps) {
        $i++
        $action = Get-Prop $step 'action'
        $summary = switch ($action) {
            'wait'      { $s = Get-Prop $step 'seconds'; $m = Get-Prop $step 'ms'; "pause $(if($s){"$s s"}else{"$m ms"})" }
            'caption'   { "caption: `"$(Get-Prop $step 'text')`"" }
            'narrate'   { "speak:   `"$(Get-Prop $step 'text')`"" }
            'launch'    { "launch $(Get-Prop $step 'app') $((Get-Prop $step 'args') -join ' ')" }
            'run'       { "run [$((Get-Prop $step 'shell' 'powershell'))]: $(Get-Prop $step 'command')" }
            'type'      { "type: `"$(Get-Prop $step 'text')`"" }
            'keys'      { "keys: $((Get-Prop $step 'keys') -join ', ')" }
            'focus'     { "focus window $(Get-Prop $step 'as')$(Get-Prop $step 'titleContains')$(Get-Prop $step 'title')" }
            'window'    { "window -> $(Get-Prop $step 'state' 'normal')" }
            'click'     { "click ($(Get-Prop $step 'x'),$(Get-Prop $step 'y')) $(Get-Prop $step 'button' 'left')" }
            'screenshot'{ "screenshot $(Get-Prop $step 'path')" }
            'record'    { "recording: $(Get-Prop $step 'op')" }
            'marker'    { "--- $(Get-Prop $step 'label') ---" }
            'prompt'    { "prompt operator: `"$(Get-Prop $step 'message')`"" }
            default     { '' }
        }
        $tag = '{0,3}.' -f $i
        Write-Host "$tag $summary"
        $cap = Get-Prop $step 'caption'; if ($cap) { Write-Host "      + caption: `"$cap`"" -ForegroundColor DarkGray }
        $say = Get-Prop $step 'say';     if ($say) { Write-Host "      + say: `"$say`"" -ForegroundColor DarkGray }
    }
    Write-Host ''
    Write-Host "$i steps total." -ForegroundColor Cyan
}

Export-ModuleMember -Function Get-Prop, Read-DemoScenario, Test-DemoScenario, Write-DemoScenarioPlan, Test-MultiProcessTarget
