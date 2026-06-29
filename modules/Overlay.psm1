<#
.SYNOPSIS
  On-screen captions and spoken narration for the demo recorder.

  Captions render in a borderless, top-most, click-through window that never
  steals focus from the demo app (WS_EX_NOACTIVATE | WS_EX_TOOLWINDOW |
  WS_EX_TRANSPARENT), so SendKeys keeps flowing to the real target while text
  is on screen. Each caption runs in its own STA runspace with a self-closing
  timer, so the main engine thread is never blocked.

  Narration uses the built-in System.Speech (SAPI5) synthesizer. NOTE: spoken
  audio is heard live but is only captured in the video if you also record an
  audio loopback device (see README). On-screen captions are always captured.
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
Add-Type -AssemblyName System.Speech

# A Form that shows without activating and lets clicks pass through.
if (-not ([System.Management.Automation.PSTypeName]'DemoNoActivateForm').Type) {
    Add-Type -ReferencedAssemblies System.Windows.Forms, System.Drawing -TypeDefinition @'
    using System;
    using System.Windows.Forms;
    public class DemoNoActivateForm : Form {
        public bool IsDemoOverlay { get { return true; } }   // a public member to quiet Add-Type's "no public members" warning
        protected override bool ShowWithoutActivation { get { return true; } }
        const int WS_EX_NOACTIVATE = 0x08000000;
        const int WS_EX_TOOLWINDOW = 0x00000080;
        const int WS_EX_TOPMOST    = 0x00000008;
        const int WS_EX_TRANSPARENT= 0x00000020;
        protected override CreateParams CreateParams {
            get {
                CreateParams cp = base.CreateParams;
                cp.ExStyle |= WS_EX_NOACTIVATE | WS_EX_TOOLWINDOW | WS_EX_TOPMOST | WS_EX_TRANSPARENT;
                return cp;
            }
        }
    }
'@
}

$script:CaptionJobs = New-Object System.Collections.ArrayList   # @{ ps; handle }
$script:Synths      = New-Object System.Collections.ArrayList

# The work each caption runspace performs. Kept as a scriptblock so it can be
# pushed into an STA runspace.
$script:CaptionWorker = {
    param($Text, $DurationMs, $Position, $FontSize, $BgOpacity)
    Add-Type -AssemblyName System.Windows.Forms
    Add-Type -AssemblyName System.Drawing
    $form = New-Object DemoNoActivateForm
    $form.FormBorderStyle = 'None'
    $form.StartPosition   = 'Manual'
    $form.ShowInTaskbar   = $false
    $form.TopMost         = $true
    $form.BackColor       = [System.Drawing.Color]::FromArgb(18, 18, 18)
    $form.Opacity         = $BgOpacity

    $label = New-Object System.Windows.Forms.Label
    $label.Text      = $Text
    $label.ForeColor = [System.Drawing.Color]::White
    $label.Dock      = 'Fill'
    $label.TextAlign = 'MiddleCenter'
    $label.Font      = New-Object System.Drawing.Font('Segoe UI', [single]$FontSize, [System.Drawing.FontStyle]::Bold)
    $form.Controls.Add($label)

    $area = [System.Windows.Forms.Screen]::PrimaryScreen.WorkingArea
    $w = [int]($area.Width * 0.82)
    $h = [int]($FontSize * 2.6) + 24
    $x = $area.X + [int](($area.Width - $w) / 2)
    switch ($Position) {
        'top'    { $y = $area.Y + 48 }
        'center' { $y = $area.Y + [int](($area.Height - $h) / 2) }
        default  { $y = $area.Y + $area.Height - $h - 72 }
    }
    $form.Bounds = New-Object System.Drawing.Rectangle($x, $y, $w, $h)

    $timer = New-Object System.Windows.Forms.Timer
    $timer.Interval = [int]$DurationMs
    $timer.Add_Tick({ $timer.Stop(); $form.Close() })
    $timer.Start()

    [System.Windows.Forms.Application]::Run($form)
    $form.Dispose()
}

function Show-DemoCaption {
    param(
        [string]$Text,
        [int]$DurationMs = 3500,
        [ValidateSet('top','center','bottom')] [string]$Position = 'bottom',
        [int]$FontSize = 28,
        [double]$BgOpacity = 0.85,
        [switch]$Wait
    )
    $rs = [runspacefactory]::CreateRunspace()
    $rs.ApartmentState = 'STA'
    $rs.ThreadOptions  = 'ReuseThread'
    $rs.Open()
    $ps = [powershell]::Create()
    $ps.Runspace = $rs
    [void]$ps.AddScript($script:CaptionWorker).AddArgument($Text).AddArgument($DurationMs).AddArgument($Position).AddArgument($FontSize).AddArgument($BgOpacity)
    $handle = $ps.BeginInvoke()
    if ($Wait) {
        $ps.EndInvoke($handle)
        $ps.Dispose(); $rs.Dispose()
    } else {
        [void]$script:CaptionJobs.Add(@{ ps = $ps; rs = $rs; handle = $handle })
    }
}

function Invoke-DemoNarration {
    param(
        [string]$Text,
        [string]$Voice,
        [int]$Rate = 0,        # -10 .. 10
        [int]$Volume = 100,    # 0 .. 100
        [switch]$Wait
    )
    $synth = New-Object System.Speech.Synthesis.SpeechSynthesizer
    if ($Voice) { try { $synth.SelectVoice($Voice) } catch { Write-Warning "Voice '$Voice' not found; using default." } }
    $synth.Rate   = [Math]::Max(-10, [Math]::Min(10, $Rate))
    $synth.Volume = [Math]::Max(0, [Math]::Min(100, $Volume))
    if ($Wait) {
        try { $synth.Speak($Text) } finally { $synth.Dispose() }
    } else {
        [void]$script:Synths.Add($synth)
        [void]$synth.SpeakAsync($Text)
    }
}

function Get-DemoVoices {
    $synth = New-Object System.Speech.Synthesis.SpeechSynthesizer
    try { return ($synth.GetInstalledVoices() | ForEach-Object { $_.VoiceInfo.Name }) }
    finally { $synth.Dispose() }
}

# Tear down any lingering captions / async narration at end of run.
function Stop-DemoOverlays {
    foreach ($job in $script:CaptionJobs) {
        try { if (-not $job.handle.IsCompleted) { $job.ps.Stop() } } catch {}
        try { $job.ps.Dispose() } catch {}
        try { $job.rs.Dispose() } catch {}
    }
    $script:CaptionJobs.Clear()
    foreach ($s in $script:Synths) {
        try { $s.SpeakAsyncCancelAll() } catch {}
        try { $s.Dispose() } catch {}
    }
    $script:Synths.Clear()
}

Export-ModuleMember -Function Show-DemoCaption, Invoke-DemoNarration, Get-DemoVoices, Stop-DemoOverlays
