<#
.SYNOPSIS
  Low-level input + window automation for the demo recorder (PowerShell 5.1, no external deps).

  Everything here uses built-in Windows facilities only:
    - WScript.Shell COM for SendKeys / AppActivate
    - user32.dll P/Invoke for mouse + window placement
    - System.Drawing for screenshots

  Exported verbs are consumed by Invoke-Demo.ps1's step dispatcher.
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# --- Native interop (compiled once into the AppDomain) ---------------------
if (-not ([System.Management.Automation.PSTypeName]'DemoNative.Win32').Type) {
    Add-Type -Namespace 'DemoNative' -Name 'Win32' -MemberDefinition @'
    [System.Runtime.InteropServices.DllImport("user32.dll")] public static extern bool SetCursorPos(int X, int Y);
    [System.Runtime.InteropServices.DllImport("user32.dll")] public static extern void mouse_event(uint dwFlags, uint dx, uint dy, uint dwData, System.IntPtr dwExtraInfo);
    [System.Runtime.InteropServices.DllImport("user32.dll")] public static extern bool SetForegroundWindow(System.IntPtr hWnd);
    [System.Runtime.InteropServices.DllImport("user32.dll")] public static extern bool ShowWindow(System.IntPtr hWnd, int nCmdShow);
    [System.Runtime.InteropServices.DllImport("user32.dll")] public static extern bool MoveWindow(System.IntPtr hWnd, int X, int Y, int nWidth, int nHeight, bool bRepaint);
    [System.Runtime.InteropServices.DllImport("kernel32.dll")] public static extern System.IntPtr GetConsoleWindow();
    public const uint MOUSEEVENTF_LEFTDOWN  = 0x0002, MOUSEEVENTF_LEFTUP  = 0x0004;
    public const uint MOUSEEVENTF_RIGHTDOWN = 0x0008, MOUSEEVENTF_RIGHTUP = 0x0010;
    public const int SW_HIDE = 0, SW_SHOWNORMAL = 1, SW_MINIMIZE = 6, SW_MAXIMIZE = 3, SW_RESTORE = 9;
'@
}

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

# --- Module state ----------------------------------------------------------
$script:WShell       = $null
$script:DemoWindows  = @{}     # 'as'-name -> System.Diagnostics.Process
$script:CurrentShell = $null   # last-launched terminal, reused by 'run' steps
$script:TermForceConhost = $false   # route terminals through conhost.exe (classic host)
$script:TermSavedFont    = $null    # saved HKCU\Console font, restored after the demo

function Get-WShell {
    if (-not $script:WShell) { $script:WShell = New-Object -ComObject WScript.Shell }
    return $script:WShell
}

# --- SendKeys text encoding -------------------------------------------------
# Characters that are syntactically special to SendKeys must be wrapped in
# braces to be sent literally. Newlines/tabs map to {ENTER}/{TAB}.
function ConvertTo-SendKeysLiteral {
    param([string]$Text)
    $special = '+^%~(){}[]'
    $sb = New-Object System.Text.StringBuilder
    foreach ($c in $Text.ToCharArray()) {
        $code = [int]$c
        if ($code -eq 10)      { [void]$sb.Append('{ENTER}') }
        elseif ($code -eq 13)  { }                                  # swallow CR (handled by LF)
        elseif ($code -eq 9)   { [void]$sb.Append('{TAB}') }
        elseif ($special.IndexOf($c) -ge 0) { [void]$sb.Append('{'); [void]$sb.Append($c); [void]$sb.Append('}') }
        else { [void]$sb.Append($c) }
    }
    return $sb.ToString()
}

# Named keys and modifier symbols for the 'keys' action vocabulary.
$script:NamedKeys = @{
    'enter'='{ENTER}'; 'return'='{ENTER}'; 'tab'='{TAB}'; 'esc'='{ESC}'; 'escape'='{ESC}';
    'backspace'='{BACKSPACE}'; 'bksp'='{BACKSPACE}'; 'delete'='{DELETE}'; 'del'='{DELETE}';
    'up'='{UP}'; 'down'='{DOWN}'; 'left'='{LEFT}'; 'right'='{RIGHT}';
    'home'='{HOME}'; 'end'='{END}'; 'pageup'='{PGUP}'; 'pgup'='{PGUP}'; 'pagedown'='{PGDN}'; 'pgdn'='{PGDN}';
    'space'='{ }'; 'insert'='{INSERT}'; 'ins'='{INSERT}'; 'printscreen'='{PRTSC}'; 'prtsc'='{PRTSC}';
    'capslock'='{CAPSLOCK}'; 'numlock'='{NUMLOCK}'; 'break'='{BREAK}'; 'help'='{HELP}';
    'f1'='{F1}';'f2'='{F2}';'f3'='{F3}';'f4'='{F4}';'f5'='{F5}';'f6'='{F6}';
    'f7'='{F7}';'f8'='{F8}';'f9'='{F9}';'f10'='{F10}';'f11'='{F11}';'f12'='{F12}'
}
$script:Modifiers = @{ 'ctrl'='^'; 'control'='^'; 'shift'='+'; 'alt'='%' }

# Returns the list of valid named-key tokens (used by the validator).
function Get-DemoKeyVocabulary {
    return @{ Keys = ($script:NamedKeys.Keys | Sort-Object); Modifiers = ($script:Modifiers.Keys | Sort-Object) }
}

# Convert a single chord token like "Ctrl+Shift+P" / "Enter" / "F5" / "a"
# into a SendKeys expression. Throws on an unknown key token.
function ConvertTo-SendKeysChord {
    param([string]$Chord)
    $parts = $Chord -split '\+'
    # A trailing empty part means the literal '+' was the key (e.g. "Ctrl++").
    if ($parts[-1] -eq '') { $parts = $parts[0..($parts.Count-2)]; $parts += '+' }
    $mods = ''
    for ($i = 0; $i -lt $parts.Count - 1; $i++) {
        $m = $parts[$i].Trim().ToLowerInvariant()
        if (-not $script:Modifiers.ContainsKey($m)) { throw "Unknown modifier '$($parts[$i])' in key chord '$Chord'. Valid: $($script:Modifiers.Keys -join ', ')." }
        $mods += $script:Modifiers[$m]
    }
    $keyToken = $parts[-1].Trim()
    $lower = $keyToken.ToLowerInvariant()
    if ($script:NamedKeys.ContainsKey($lower)) { $keyExpr = $script:NamedKeys[$lower] }
    elseif ($keyToken.Length -eq 1)            { $keyExpr = ConvertTo-SendKeysLiteral $keyToken.ToLowerInvariant() }  # Shift is expressed via the +modifier, never letter case
    else { throw "Unknown key '$keyToken' in chord '$Chord'. Use a single character or a named key (see Get-DemoKeyVocabulary)." }
    return $mods + $keyExpr
}

# --- Foreground / focus -----------------------------------------------------
function Get-DemoWindowHandle {
    # Return the process main-window handle, or [IntPtr]::Zero when there is none.
    # MainWindowHandle can be $null (not just 0) - e.g. a stored process that has
    # exited, or a handle-less content process of a multi-process app like a browser.
    # $null -ne [IntPtr]::Zero is TRUE, so a naive guard passes null straight into
    # user32 and the P/Invoke throws "Cannot convert null to type System.IntPtr",
    # which used to abort the whole run. Everything funnels through here instead.
    param([System.Diagnostics.Process]$Process)
    if (-not $Process) { return [IntPtr]::Zero }
    try {
        $h = $Process.MainWindowHandle
        if ($null -eq $h -or "$h" -eq "") { return [IntPtr]::Zero }
        return [IntPtr]$h
    } catch { return [IntPtr]::Zero }
}

function Set-DemoForeground {
    param([System.Diagnostics.Process]$Process, [int]$SettleMs = 250)
    if (-not $Process) { return $false }
    try { $Process.Refresh() } catch {}
    $ok = $false
    try { $ok = [bool](Get-WShell).AppActivate($Process.Id) } catch {}
    $h = Get-DemoWindowHandle -Process $Process
    if ($h -ne [IntPtr]::Zero) {
        [void][DemoNative.Win32]::SetForegroundWindow($h)
    } elseif (-not $ok) {
        Write-Warning ("No window handle for process '{0}' (pid {1}) - focus step did nothing. Multi-process apps (browsers, Electron) have handle-less child processes: target them with titleContains instead of processName." -f $Process.ProcessName, $Process.Id)
    }
    Start-Sleep -Milliseconds $SettleMs
    return $ok
}

# --- Terminal appearance (font + classic conhost) ---------------------------
# Windows Terminal ignores console font settings, and under it the shell process
# doesn't own its window (breaking focus/typing). So for readable, reliable demos
# we set the console font in HKCU\Console and launch terminals via conhost.exe
# (the classic host), then restore the font afterwards.
function Set-DemoTerminalStyle {
    param([int]$FontSize = 0, [string]$FontFace = 'Consolas', [bool]$ForceConhost = $false)
    $script:TermForceConhost = ($ForceConhost -or $FontSize -gt 0)
    if ($FontSize -gt 0) {
        $k = 'HKCU:\Console'
        $ck = Get-ItemProperty $k -ErrorAction SilentlyContinue
        $script:TermSavedFont = @{ FontSize = $ck.FontSize; FaceName = $ck.FaceName; FontFamily = $ck.FontFamily; FontWeight = $ck.FontWeight }
        Set-ItemProperty $k -Name FontSize   -Value ($FontSize -shl 16) -Type DWord    # high word = pixel height
        Set-ItemProperty $k -Name FaceName   -Value $FontFace           -Type String
        Set-ItemProperty $k -Name FontFamily -Value 54                  -Type DWord    # TrueType
        Set-ItemProperty $k -Name FontWeight -Value 400                 -Type DWord
    }
}

function Restore-DemoTerminalStyle {
    if ($script:TermSavedFont) {
        $k = 'HKCU:\Console'; $s = $script:TermSavedFont
        foreach ($n in 'FontSize','FaceName','FontFamily','FontWeight') {
            if ($null -ne $s[$n]) { Set-ItemProperty $k -Name $n -Value $s[$n] }
        }
        $script:TermSavedFont = $null
    }
    $script:TermForceConhost = $false
}

# --- Apps / terminals -------------------------------------------------------
function Start-DemoApp {
    param(
        [string]$App,
        [string[]]$Arguments,
        [string]$As,
        [int]$WaitForWindowMs = 5000
    )
    if ($Arguments -and $Arguments.Count -gt 0) {
        $proc = Start-Process -FilePath $App -ArgumentList $Arguments -PassThru
    } else {
        $proc = Start-Process -FilePath $App -PassThru
    }
    # Wait for a top-level window to exist so we can focus/automate it.
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    while ($sw.ElapsedMilliseconds -lt $WaitForWindowMs) {
        try { $proc.Refresh() } catch {}
        # Use the safe accessor: a null handle is "no window yet", not "ready" -
        # the raw check would break out immediately and store a handle-less process.
        if (-not $proc.HasExited -and (Get-DemoWindowHandle -Process $proc) -ne [IntPtr]::Zero) { break }
        Start-Sleep -Milliseconds 120
    }
    if ($As) { $script:DemoWindows[$As] = $proc }
    return $proc
}

function Get-DemoWindowProcess {
    param([string]$As, [string]$Title, [string]$TitleContains, [string]$ProcessName)
    if ($As -and $script:DemoWindows.ContainsKey($As)) { return $script:DemoWindows[$As] }
    # Filter through Get-DemoWindowHandle so handle-less processes (null MainWindowHandle,
    # e.g. browser content processes) can never be selected as a target.
    $candidates = Get-Process | Where-Object { (Get-DemoWindowHandle -Process $_) -ne [IntPtr]::Zero -and $_.MainWindowTitle }
    if ($Title)          { $candidates = $candidates | Where-Object { $_.MainWindowTitle -eq $Title } }
    elseif ($TitleContains) { $candidates = $candidates | Where-Object { $_.MainWindowTitle -like "*$TitleContains*" } }
    elseif ($ProcessName){ $candidates = $candidates | Where-Object { $_.ProcessName -eq ($ProcessName -replace '\.exe$','') } }
    return ($candidates | Select-Object -First 1)
}

function Focus-DemoWindow {
    param([string]$As, [string]$Title, [string]$TitleContains, [string]$ProcessName)
    $proc = Get-DemoWindowProcess -As $As -Title $Title -TitleContains $TitleContains -ProcessName $ProcessName
    if (-not $proc) { throw "Could not find a window to focus (as='$As' title='$Title' contains='$TitleContains' process='$ProcessName')." }
    return Set-DemoForeground -Process $proc
}

function Set-DemoWindowState {
    param(
        [System.Diagnostics.Process]$Process,
        [string]$State,                       # normal|maximized|minimized
        [Nullable[int]]$X, [Nullable[int]]$Y, [Nullable[int]]$Width, [Nullable[int]]$Height
    )
    $h = Get-DemoWindowHandle -Process $Process
    if ($h -eq [IntPtr]::Zero) {
        if ($Process) { Write-Warning ("No window handle for process '{0}' (pid {1}) - window step did nothing." -f $Process.ProcessName, $Process.Id) }
        else           { Write-Warning "Window step target could not be resolved to a running window - step did nothing." }
        return
    }
    switch ($State) {
        'maximized' { [void][DemoNative.Win32]::ShowWindow($h, [DemoNative.Win32]::SW_MAXIMIZE) }
        'minimized' { [void][DemoNative.Win32]::ShowWindow($h, [DemoNative.Win32]::SW_MINIMIZE) }
        default     { [void][DemoNative.Win32]::ShowWindow($h, [DemoNative.Win32]::SW_RESTORE) }
    }
    if ($null -ne $X -and $null -ne $Y -and $null -ne $Width -and $null -ne $Height) {
        [void][DemoNative.Win32]::MoveWindow($h, $X, $Y, $Width, $Height, $true)
    }
}

# --- Typing -----------------------------------------------------------------
function Send-DemoText {
    param(
        [string]$Text,
        [ValidateSet('instant','human')] [string]$Style = 'instant',
        [int]$DelayMs = 35,
        [switch]$Submit
    )
    $wshell = Get-WShell
    if ($Style -eq 'human') {
        foreach ($ch in $Text.ToCharArray()) {
            $wshell.SendKeys((ConvertTo-SendKeysLiteral ([string]$ch)))
            Start-Sleep -Milliseconds $DelayMs
        }
    } else {
        $wshell.SendKeys((ConvertTo-SendKeysLiteral $Text))
    }
    if ($Submit) { Start-Sleep -Milliseconds 80; $wshell.SendKeys('{ENTER}') }
}

function Send-DemoKeys {
    param([string[]]$Keys, [int]$Count = 1, [int]$IntervalMs = 60)
    $wshell = Get-WShell
    for ($i = 0; $i -lt $Count; $i++) {
        foreach ($k in $Keys) {
            $wshell.SendKeys((ConvertTo-SendKeysChord $k))
            Start-Sleep -Milliseconds $IntervalMs
        }
    }
}

# --- The headline action: type a command into a VISIBLE terminal ------------
function Invoke-DemoRun {
    param(
        [string]$Command,
        [ValidateSet('powershell','cmd')] [string]$Shell = 'powershell',
        [bool]$NewWindow = $false,
        [string]$As,
        [ValidateSet('instant','human')] [string]$Style = 'human',
        [int]$DelayMs = 30,
        [bool]$Submit = $true,
        [int]$WaitMs = 800
    )
    $shellProc = $null
    if ($As -and $script:DemoWindows.ContainsKey($As) -and -not $script:DemoWindows[$As].HasExited) {
        $shellProc = $script:DemoWindows[$As]
    }
    $needNew = $NewWindow -or (-not $shellProc -and (-not $script:CurrentShell -or $script:CurrentShell.HasExited))
    if (-not $shellProc -and -not $needNew) { $shellProc = $script:CurrentShell }

    if ($needNew -or -not $shellProc) {
        if ($Shell -eq 'cmd') { $exe = 'cmd.exe';        $a = @('/K') }
        else                  { $exe = 'powershell.exe'; $a = @('-NoExit','-NoProfile') }
        if ($script:TermForceConhost) {
            # conhost.exe <shell> <args...> forces the classic host (honors the font).
            $shellProc = Start-DemoApp -App 'conhost.exe' -Arguments (@($exe) + $a) -As $As
        } else {
            $shellProc = Start-DemoApp -App $exe -Arguments $a -As $As
        }
        Start-Sleep -Milliseconds 700   # let the prompt finish drawing
    }
    $script:CurrentShell = $shellProc

    [void](Set-DemoForeground -Process $shellProc)
    Send-DemoText -Text $Command -Style $Style -DelayMs $DelayMs -Submit:$Submit
    Start-Sleep -Milliseconds $WaitMs
    return $shellProc
}

# --- Mouse ------------------------------------------------------------------
function Invoke-DemoClick {
    param([int]$X, [int]$Y, [ValidateSet('left','right','double')] [string]$Button = 'left')
    [void][DemoNative.Win32]::SetCursorPos($X, $Y)
    Start-Sleep -Milliseconds 120
    switch ($Button) {
        'right' {
            [DemoNative.Win32]::mouse_event([DemoNative.Win32]::MOUSEEVENTF_RIGHTDOWN, 0,0,0,[IntPtr]::Zero)
            [DemoNative.Win32]::mouse_event([DemoNative.Win32]::MOUSEEVENTF_RIGHTUP,   0,0,0,[IntPtr]::Zero)
        }
        'double' {
            for ($i=0; $i -lt 2; $i++) {
                [DemoNative.Win32]::mouse_event([DemoNative.Win32]::MOUSEEVENTF_LEFTDOWN,0,0,0,[IntPtr]::Zero)
                [DemoNative.Win32]::mouse_event([DemoNative.Win32]::MOUSEEVENTF_LEFTUP,  0,0,0,[IntPtr]::Zero)
                Start-Sleep -Milliseconds 80
            }
        }
        default {
            [DemoNative.Win32]::mouse_event([DemoNative.Win32]::MOUSEEVENTF_LEFTDOWN,0,0,0,[IntPtr]::Zero)
            [DemoNative.Win32]::mouse_event([DemoNative.Win32]::MOUSEEVENTF_LEFTUP,  0,0,0,[IntPtr]::Zero)
        }
    }
}

# --- Screenshots ------------------------------------------------------------
function Save-DemoScreenshot {
    param([string]$Path, [hashtable]$Region)
    if ($Region) {
        $rect = New-Object System.Drawing.Rectangle($Region.x, $Region.y, $Region.width, $Region.height)
    } else {
        $rect = [System.Windows.Forms.SystemInformation]::VirtualScreen
    }
    $bmp = New-Object System.Drawing.Bitmap($rect.Width, $rect.Height)
    $g   = [System.Drawing.Graphics]::FromImage($bmp)
    try {
        $g.CopyFromScreen($rect.X, $rect.Y, 0, 0, $bmp.Size)
        $dir = Split-Path -Parent $Path
        if ($dir -and -not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
        $bmp.Save($Path, [System.Drawing.Imaging.ImageFormat]::Png)
    } finally {
        $g.Dispose(); $bmp.Dispose()
    }
    return $Path
}

# --- Controller-window helpers (hide our own console during capture) --------
function Set-ControllerWindowState {
    param([ValidateSet('minimized','normal')] [string]$State = 'minimized')
    $h = [DemoNative.Win32]::GetConsoleWindow()
    if ($h -eq [IntPtr]::Zero) { return }
    if ($State -eq 'minimized') { [void][DemoNative.Win32]::ShowWindow($h, [DemoNative.Win32]::SW_MINIMIZE) }
    else { [void][DemoNative.Win32]::ShowWindow($h, [DemoNative.Win32]::SW_RESTORE) }
}

function Reset-DemoEngineState {
    $script:DemoWindows  = @{}
    $script:CurrentShell = $null
}

Export-ModuleMember -Function `
    Get-WShell, ConvertTo-SendKeysLiteral, ConvertTo-SendKeysChord, Get-DemoKeyVocabulary, `
    Set-DemoForeground, Get-DemoWindowHandle, Start-DemoApp, Get-DemoWindowProcess, Focus-DemoWindow, Set-DemoWindowState, `
    Send-DemoText, Send-DemoKeys, Invoke-DemoRun, Invoke-DemoClick, Save-DemoScreenshot, `
    Set-DemoTerminalStyle, Restore-DemoTerminalStyle, Set-ControllerWindowState, Reset-DemoEngineState
