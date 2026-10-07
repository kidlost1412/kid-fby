#Requires -Version 5.1
param([string]$Root=(Split-Path $PSScriptRoot -Parent))
$ErrorActionPreference = 'Stop'
$Root = [IO.Path]::GetFullPath($Root)
$guiPath = Join-Path $Root 'core\kid-fby-gui.ps1'
$guiText = [IO.File]::ReadAllText($guiPath)
$tokens = $null
$parseErrors = $null
$guiAst = [System.Management.Automation.Language.Parser]::ParseFile($guiPath,[ref]$tokens,[ref]$parseErrors)

function Assert-True([bool]$Condition,[string]$Message) {
    if (-not $Condition) { throw $Message }
}

function Get-GuiFunction([string]$Name) {
    $fn = $guiAst.Find({ param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $Name },$true) | Select-Object -First 1
    if (-not $fn) { throw "Missing GUI function: $Name" }
    return [scriptblock]::Create($fn.Extent.Text)
}

Assert-True ($parseErrors.Count -eq 0) "GUI parse errors: $($parseErrors -join '; ')"
Assert-True ($guiText -notmatch '(?i)taskkill(?:\.exe)?\s+/F\s+/IM|Stop-Process\s+-Name') 'GUI must not kill processes by image name.'
Assert-True ($guiText -notmatch '\.AddScript\(') 'GUI engine launch must not interpolate root into AddScript.'
Assert-True ($guiText -match 'AddParameter\(''ProcessRegistry'',\s*\$script:childProcesses\)') 'GUI must pass the owned-process registry to the engine.'
Assert-True ($guiText -match '\$script:ps\.BeginStop\(\$null,\s*\$null\)') 'GUI cancellation must use asynchronous BeginStop.'
Assert-True ($guiText -match 'Finish-Engine\s+-Cancelled\s+\$true') 'Timer must finish cancellation after async completion.'
Assert-True ($guiText -match '(?s)\$win\.Add_Closing\(\{\s*param\(\$sender,\$eventArgs\).*?\$eventArgs\.Cancel\s*=\s*\$true.*?Stop-Engine') 'Window close must defer exit until asynchronous engine cancellation completes.'
Assert-True ($guiText -match '\$script:closeAfterStop\s*=\s*\$false;\s*\$win\.Close\(\)') 'Window must close after the cancellation timer finishes cleanup.'
Assert-True ($guiText -match 'Chỉ ghi âm lại video đang nghiệm thu trong hàng đợi\.') 'Redo must reject missing or invalid review queue state.'
Assert-True ($guiText -notmatch 'Remove-ReelFiles\s+\$redoFile') 'Redo must preserve current final files until replacement succeeds.'
Assert-True ($guiText -match "'Thiếu ffprobe ✖'") 'Tool status must identify missing ffprobe.'
Assert-True ($guiText -match '\$today\.AddDays\(-6\).*\$today') 'Seven day filter must include today and the six preceding dates.'
Assert-True ($guiText -match 'Content="🎧 Audio Tách"') 'Track A must be labeled Audio Tách.'

# Exercise the real log-token handler with isolated stage and log fixtures.
$script:ui = @{
    TxtRes = [pscustomobject]@{ Text = '' }
    BadgeRes = [pscustomobject]@{ Visibility = '' }
}
$script:runLog = ''
$script:testStages = @()
function Set-Stage { param($Stage,$Status,$Color,$Info); $script:testStages += [pscustomobject]@{ Stage=$Stage; Status=$Status; Color=$Color; Info=$Info } }
function Add-Log { param($Text,$Color); $script:testLog += [string]$Text }
. (Get-GuiFunction 'Add-Line')
$script:testLog = ''
Add-Line 'DUB_UNVERIFIED: fixture'
Assert-True ($script:testStages[-1].Status -eq 'Cần nghe kiểm tra' -and $script:testStages[-1].Info -eq 'Chưa xác nhận được tiếng Việt từ giao diện') 'DUB_UNVERIFIED must remain an orange review status.'
$script:testStages = @()
Add-Line 'DUB_SELECTED: fixture'
Assert-True ($script:testStages[-1].Status -eq 'Đã gửi lựa chọn' -and $script:testStages[-1].Info -eq 'Đã chọn trên giao diện; cần nghe nghiệm thu') 'DUB_SELECTED must remain an orange review status.'
$script:testStages = @()
Add-Line 'Da chon Tieng Viet thanh cong'
Assert-True (-not ($script:testStages | Where-Object { $_.Stage -eq 3 -and $_.Status -eq 'Đã kích hoạt ✔' })) 'Legacy tap-success text must not mark language verification.'

# Load the actual cleanup functions and run them against only local PowerShell pipelines.
. (Get-GuiFunction 'Pump-Output')
. (Get-GuiFunction 'Test-PipelineStoppedException')
. (Get-GuiFunction 'Finish-Engine')
. (Get-GuiFunction 'Stop-Engine')
. (Get-GuiFunction 'Start-Engine')
. (Get-GuiFunction 'Install-ToolGUI')
function Set-Busy { param([bool]$On); $script:testBusy = $On }
function Show-Toast { param([string]$Message); $script:testToast = $Message }
$script:ui.PanelRev = [pscustomobject]@{ Visibility = 'Visible' }
$script:queue = @('https://fixture.invalid/reel')
$script:ps = $null
$script:testToast = ''
Start-Engine -Links @() -Named @{ Check = $true } -Mode 'check'
Assert-True (-not $script:ps -and $script:ui.PanelRev.Visibility -eq 'Visible') 'Check must not hide pending review or start a pipeline.'
Assert-True ($script:testToast -eq 'Hãy hoàn tất hàng đợi đang nghiệm thu trước khi kiểm tra hoặc cài công cụ.') 'Check must explain the pending-review guard.'
$script:testToast = ''
Start-Engine -Links @() -Named @{ SetupTool = 'ffmpeg' } -Mode 'setup'
Assert-True (-not $script:ps -and $script:ui.PanelRev.Visibility -eq 'Visible') 'Setup must not hide pending review or start a pipeline.'
$script:testToast = ''
Install-ToolGUI 'ffmpeg'
Assert-True (-not $script:ps -and $script:ui.PanelRev.Visibility -eq 'Visible') 'Tool installation must not hide pending review or start a pipeline.'
Assert-True ($script:testToast -eq 'Hãy hoàn tất tác vụ và hàng đợi trước khi cài công cụ.') 'Tool installation must explain the pending-review guard.'
$script:queue = @()

$script:timer = [pscustomobject]@{ Stopped = $false }
$script:timer | Add-Member ScriptMethod Stop { $this.Stopped = $true }
$script:childProcesses = [hashtable]::Synchronized(@{})
$script:testBusy = $false
$script:runLog = ''
$script:loggedErrors = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)

function New-TestPipeline([string]$Code) {
    $script:ps = [System.Management.Automation.PowerShell]::Create()
    [void]$script:ps.AddScript($Code)
    $script:seen = 0
    $script:seenErrors = 0
    $script:stopping = $false
    $script:cancelRequested = $false
    $script:stopHandle = $null
    $script:loggedErrors = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    $script:handle = $script:ps.BeginInvoke()
}

New-TestPipeline "Write-Error 'gui-runtime-fixture-error'"
for ($i=0; $i -lt 500 -and -not $script:handle.IsCompleted; $i++) { Start-Sleep -Milliseconds 10 }
Assert-True $script:handle.IsCompleted 'Local error fixture pipeline did not finish.'
Finish-Engine
Assert-True (-not $script:ps -and -not $script:handle -and $script:timer.Stopped -and -not $script:testBusy) 'Natural finish must dispose pipeline and restore idle UI state.'
$errorLines = @($script:runLog -split "`n" | Where-Object { $_ -match 'gui-runtime-fixture-error' })
Assert-True ($errorLines.Count -eq 1) 'A stream error and EndInvoke exception must be logged once.'

$script:timer.Stopped = $false
$script:runLog = ''
New-TestPipeline "throw 'gui-runtime-terminating-error'"
for ($i=0; $i -lt 500 -and -not $script:handle.IsCompleted; $i++) { Start-Sleep -Milliseconds 10 }
Assert-True $script:handle.IsCompleted 'Local terminating-error fixture pipeline did not finish.'
Finish-Engine
$errorLines = @($script:runLog -split "`n" | Where-Object { $_ -match 'gui-runtime-terminating-error' })
Assert-True ($errorLines.Count -eq 1) 'A terminating EndInvoke exception and its stream error must be logged once.'

$ownedProcess = $null
$unrelatedProcess = $null
try {
    $psi = New-Object Diagnostics.ProcessStartInfo
    $psi.FileName = [Diagnostics.Process]::GetCurrentProcess().MainModule.FileName
    $psi.Arguments = '-NoProfile -NonInteractive -Command "Start-Sleep -Seconds 30"'
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    $psi.WindowStyle = [Diagnostics.ProcessWindowStyle]::Hidden
    $ownedProcess = [Diagnostics.Process]::Start($psi)
    $unrelatedProcess = [Diagnostics.Process]::Start($psi)
    Start-Sleep -Milliseconds 150

    $script:timer.Stopped = $false
    $script:runLog = ''
    New-TestPipeline 'Start-Sleep -Seconds 30'
    [System.Threading.Monitor]::Enter($script:childProcesses.SyncRoot)
    try { $script:childProcesses['owned-fixture'] = $ownedProcess }
    finally { [System.Threading.Monitor]::Exit($script:childProcesses.SyncRoot) }
    $stopClock = [Diagnostics.Stopwatch]::StartNew()
    Stop-Engine
    $stopClock.Stop()
    Assert-True ($stopClock.Elapsed.TotalSeconds -lt 2) 'Stop-Engine must request cancellation without waiting on the UI thread.'
    Assert-True ($script:ps -and $script:handle -and $script:stopHandle) 'Stop-Engine must retain pipeline state until async cleanup completes.'
    Assert-True ($ownedProcess.WaitForExit(5000)) 'Stop-Engine did not terminate the registered owned process.'
    Assert-True (-not $unrelatedProcess.HasExited) 'Stop-Engine terminated a same-name process absent from the owned registry.'
    for ($i=0; $i -lt 500 -and (-not $script:stopHandle.IsCompleted -or -not $script:handle.IsCompleted); $i++) { Start-Sleep -Milliseconds 10 }
    Assert-True ($script:stopHandle.IsCompleted -and $script:handle.IsCompleted) 'Cancelled local fixture pipeline did not complete asynchronously.'
    try { $script:ps.EndStop($script:stopHandle) } catch { }
    Finish-Engine -Cancelled $true
    Assert-True (-not $script:ps -and -not $script:handle -and $script:timer.Stopped -and -not $script:testBusy) 'Cancelled finish must dispose pipeline and restore idle UI state.'
    Assert-True ($script:runLog -notmatch 'PipelineStoppedException') 'Expected pipeline cancellation must not be logged as an error.'
} finally {
    foreach ($testProcess in @($ownedProcess,$unrelatedProcess)) {
        if ($testProcess) {
            try { if (-not $testProcess.HasExited) { $testProcess.Kill(); [void]$testProcess.WaitForExit(5000) } } catch { }
            $testProcess.Dispose()
        }
    }
}
Write-Host 'PASS: GUI runtime contracts, language review tokens, natural errors, and asynchronous cancellation'
