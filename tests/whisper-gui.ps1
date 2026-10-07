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
Assert-True ($guiText -match '<CheckBox x:Name="ChkLanguage" Content="Nhận diện tiếng Việt bằng tiny" IsChecked="True"') 'Language checkbox must default on.'
Assert-True ($guiText -match 'ToolTip="Thử tối đa 2 đoạn audio ngắn; kết quả ước tính, vẫn nghe nghiệm thu\."') 'Language checkbox must explain the limited estimate and listening review.'
Assert-True ($guiText -match 'SkipLanguageCheck\s*=\s*\(\[bool\]\(-not \$ui\.ChkLanguage\.IsChecked\)\)') 'Start-Link must pass the inverse checkbox value to the engine.'
Assert-True ($guiText -match "Install-ToolGUI 'whisper'") 'Whisper install action must use the existing tool installer path.'

# Exercise the real Add-Line handler with isolated stage and log fixtures.
$script:ui = @{
    TxtRes = [pscustomobject]@{ Text = '' }
    BadgeRes = [pscustomobject]@{ Visibility = '' }
}
$script:runLog = ''
$script:testStages = @()
$script:testLog = ''
function Set-Stage { param($Stage,$Status,$Color,$Info); $script:testStages += [pscustomobject]@{ Stage=$Stage; Status=$Status; Color=$Color; Info=$Info } }
function Add-Log { param($Text,$Color); $script:testLog += [string]$Text }
. (Get-GuiFunction 'Add-Line')

$cases = @(
    @{ Line='AUDIO_LANG_VI: language=vi score=0.91 samples=1'; Status='Ước tính: tiếng Việt'; Color='#10B981'; Info='Whisper tiny · cần nghe nghiệm thu' },
    @{ Line='AUDIO_LANG_OTHER: language=en score=0.91 samples=1'; Status='Ước tính: ngôn ngữ khác'; Color='#F59E0B'; Info='Whisper tiny · cần nghe nghiệm thu · language=en' },
    @{ Line='AUDIO_LANG_UNKNOWN: samples=2'; Status='Chưa xác định ngôn ngữ'; Color='#F59E0B'; Info='Whisper tiny · cần nghe nghiệm thu' }
)
foreach ($case in $cases) {
    $script:testStages = @()
    $beforeLog = $script:runLog
    Add-Line $case.Line
    $stage = @($script:testStages | Where-Object { $_.Stage -eq 3 } | Select-Object -Last 1)[0]
    Assert-True ($stage -and $stage.Status -eq $case.Status) "$($case.Line) must set the expected Stage 3 status."
    Assert-True ($stage.Color -eq $case.Color) "$($case.Line) must use the expected Stage 3 color."
    Assert-True ($stage.Info -eq $case.Info) "$($case.Line) must use the expected Stage 3 review information."
    Assert-True ($stage.Info -notmatch '(?i)accuracy|độ chính xác|100\s*%|\b100\b') 'The stage must not describe a model score as accuracy.'
    Assert-True ($script:runLog.Length -gt $beforeLog.Length -and $script:runLog.EndsWith($case.Line + "`n")) 'Each language token must remain in the run log.'
}

$script:testStages = @()
Add-Line 'AUDIO_LANG_OTHER: score=0.50 samples=1'
$stageWithoutCode = @($script:testStages | Where-Object { $_.Stage -eq 3 } | Select-Object -Last 1)[0]
Assert-True ($stageWithoutCode.Info -eq 'Whisper tiny · cần nghe nghiệm thu') 'Other-language info may include a code only when the stable language=xx field exists.'

$script:testStages = @()
Add-Line 'DUB_SELECTED: fixture'
Add-Line 'AUDIO_LANG_VI: language=vi score=0.95 samples=1'
Assert-True (@($script:testStages | Where-Object { $_.Stage -eq 3 -and $_.Status -eq 'Ước tính: tiếng Việt' }).Count -eq 1) 'An audio estimate must be handled independently after a DUB-selected token.'

Write-Host 'PASS: Whisper GUI checkbox wiring and audio language stage/log tokens'
