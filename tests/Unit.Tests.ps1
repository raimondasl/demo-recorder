<#
  Unit tests for the demo recorder's pure logic: module load, SendKeys encoding,
  settings resolution, scenario validation, and ffmpeg argument building.
  No display, audio, input, or network is required — safe to run headlessly / in CI.
#>

BeforeAll {
    $script:Root    = Split-Path $PSScriptRoot -Parent
    $script:Modules = Join-Path $script:Root 'modules'
    foreach ($m in 'Engine', 'Overlay', 'Recorder', 'Scenario') {
        Import-Module (Join-Path $script:Modules "$m.psm1") -Force -DisableNameChecking
    }
}

Describe 'Module load' {
    It 'exports the key functions' {
        Get-Command Test-DemoScenario   -ErrorAction SilentlyContinue | Should -Not -BeNullOrEmpty
        Get-Command ConvertTo-SendKeysChord -ErrorAction SilentlyContinue | Should -Not -BeNullOrEmpty
        Get-Command Set-NarrationEngine  -ErrorAction SilentlyContinue | Should -Not -BeNullOrEmpty
        Get-Command Start-DemoRecording  -ErrorAction SilentlyContinue | Should -Not -BeNullOrEmpty
    }
}

Describe 'SendKeys literal encoding' {
    It 'brace-escapes <label>' -ForEach @(
        @{ label = 'parentheses'; in = 'Get (1)';  out = 'Get {(}1{)}' }
        @{ label = 'percent';     in = '100%';     out = '100{%}' }
        @{ label = 'braces';      in = '@{a}';     out = '@{{}a{}}' }
        @{ label = 'plus/caret/tilde'; in = '+^~'; out = '{+}{^}{~}' }
        @{ label = 'plain text';  in = 'echo hi';  out = 'echo hi' }
    ) {
        ConvertTo-SendKeysLiteral $in | Should -BeExactly $out
    }
    It 'maps newline and tab to {ENTER}/{TAB}' {
        ConvertTo-SendKeysLiteral "a`nb`tc" | Should -BeExactly 'a{ENTER}b{TAB}c'
    }
}

Describe 'SendKeys chord conversion' {
    It 'converts <in> -> <out>' -ForEach @(
        @{ in = 'Ctrl+C';         out = '^c' }
        @{ in = 'Ctrl+Shift+Esc'; out = '^+{ESC}' }
        @{ in = 'Alt+F4';         out = '%{F4}' }
        @{ in = 'Enter';          out = '{ENTER}' }
        @{ in = 'Down';           out = '{DOWN}' }
        @{ in = 'a';              out = 'a' }
    ) {
        ConvertTo-SendKeysChord $in | Should -BeExactly $out
    }
    It 'rejects an unknown key token' {
        { ConvertTo-SendKeysChord 'Ctrl+Entr' } | Should -Throw
    }
    It 'rejects an unknown modifier' {
        { ConvertTo-SendKeysChord 'Hyper+a' } | Should -Throw
    }
}

Describe 'Get-Prop settings resolution' {
    BeforeAll { $script:obj = '{"submit":false,"count":0,"name":"x","empty":""}' | ConvertFrom-Json }
    It 'returns an explicit boolean false (not the default)' {
        Get-Prop $script:obj 'submit' $true | Should -BeFalse
    }
    It 'returns an explicit 0 (not the default)' {
        Get-Prop $script:obj 'count' 5 | Should -Be 0
    }
    It 'returns the default for a missing property' {
        Get-Prop $script:obj 'nope' 'def' | Should -BeExactly 'def'
    }
    It 'returns the default when the object is null' {
        Get-Prop $null 'x' 'def' | Should -BeExactly 'def'
    }
}

Describe 'Scenario validation' {
    It 'accepts the bundled example scenarios' -ForEach @(
        @{ file = 'scenarios/minimal.json' }
        @{ file = 'scenarios/example-powershell-demo.json' }
    ) {
        $scn = Read-DemoScenario -Path (Join-Path $script:Root $file)
        (Test-DemoScenario -Scenario $scn).Errors.Count | Should -Be 0
    }

    It 'flags unknown actions, missing fields, bad keys, and bad enums' {
        $bad = @'
{ "name":"bad","steps":[
  { "action":"runn", "command":"x" },
  { "action":"run" },
  { "action":"keys", "keys":["Ctrl+Entr"] },
  { "action":"focus" },
  { "action":"caption", "text":"hi", "position":"middle" }
]}
'@ | ConvertFrom-Json
        $r = Test-DemoScenario -Scenario $bad
        $r.Errors.Count | Should -BeGreaterOrEqual 5
        ($r.Errors -join "`n") | Should -Match 'unknown action'
        ($r.Errors -join "`n") | Should -Match "missing required field 'command'"
        ($r.Errors -join "`n") | Should -Match 'invalid key'
        ($r.Errors -join "`n") | Should -Match 'position'
    }

    It 'rejects a scenario with no steps' {
        $r = Test-DemoScenario -Scenario ('{"name":"empty"}' | ConvertFrom-Json)
        $r.Errors.Count | Should -BeGreaterThan 0
    }
}

Describe 'ffmpeg argument building' {
    It 'builds a full-desktop capture command' {
        InModuleScope Recorder {
            $a = New-FfmpegArgs -R @{ framerate = 30; crf = 23; preset = 'veryfast'; captureCursor = $true } -OutFile 'out.mp4'
            $s = $a -join ' '
            $s | Should -Match 'gdigrab'
            $s | Should -Match '-i desktop'
            $s | Should -Match 'libx264'
            $a[-1] | Should -Be 'out.mp4'
        }
    }
    It 'captures a window by title when region.window is set' {
        InModuleScope Recorder {
            $a = New-FfmpegArgs -R @{ region = ([pscustomobject]@{ window = 'Calculator' }) } -OutFile 'o.mp4'
            ($a -join ' ') | Should -Match 'title=Calculator'
        }
    }
    It 'adds a dshow audio input when audioDevice is set' {
        InModuleScope Recorder {
            $a = New-FfmpegArgs -R @{ audioDevice = 'Stereo Mix' } -OutFile 'o.mp4'
            ($a -join ' ') | Should -Match 'dshow'
            ($a -join ' ') | Should -Match 'aac'
        }
    }
}
