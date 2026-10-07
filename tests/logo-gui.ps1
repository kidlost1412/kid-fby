#Requires -Version 5.1
param([string]$Root=(Split-Path $PSScriptRoot -Parent))
$ErrorActionPreference='Stop'
Add-Type -AssemblyName PresentationFramework,PresentationCore,WindowsBase,System.Drawing
$tokens=$null; $errors=$null
$ast=[Management.Automation.Language.Parser]::ParseFile((Join-Path $Root 'core/kid-fby-gui.ps1'),[ref]$tokens,[ref]$errors)
if($errors.Count){throw 'GUI parse failed.'}
function Assert([bool]$Condition,[string]$Message){if(-not $Condition){throw $Message}}
function Show-Toast {param([string]$Message);$script:lastToast=$Message}
$assignment=$ast.Find({param($n) $n -is [Management.Automation.Language.AssignmentStatementAst] -and $n.Left.Extent.Text -eq '[xml]$xaml'},$true)
if(-not $assignment){throw 'Cannot find XAML.'}
Invoke-Expression $assignment.Extent.Text
$window=[Windows.Markup.XamlReader]::Load((New-Object Xml.XmlNodeReader $xaml))
$win=$window
$scriptDir=Join-Path $Root 'core'
try {
    $ui=@{}
    foreach($element in $xaml.SelectNodes('//*[@*[local-name()="Name"]]')) {
        $name=$element.GetAttribute('Name','http://schemas.microsoft.com/winfx/2006/xaml')
        if($name){$ui[$name]=$window.FindName($name)}
    }
    foreach($name in @('ChkWatermark','TxtLogoPath','BtnPickLogo','BtnDefaultLogo','SldLogoSize','TxtLogoSize','SldLogoFade','TxtLogoFade','CmbLogoMode','CmbLogoPosition')){Assert ($null -ne $ui[$name]) "Missing logo control: $name"}
    foreach($name in @('Start-Link','Set-Busy','Set-LogoSelection')) {
        $fn=$ast.Find({param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq $name},$true)
        Invoke-Expression $fn.Extent.Text
    }
    foreach($prefix in @('$ui.SldLogoSize.Add_ValueChanged','$ui.SldLogoFade.Add_ValueChanged','$ui.CmbLogoMode.Add_SelectionChanged','$ui.BtnDefaultLogo.Add_Click')){
        $call=$ast.Find({param($n) $n -is [Management.Automation.Language.InvokeMemberExpressionAst] -and $n.Extent.Text.StartsWith($prefix)},$true)
        Assert ($null -ne $call) "Missing event: $prefix"
        Invoke-Expression $call.Extent.Text
    }
    $ui.SldLogoSize.Value=17; $ui.SldLogoFade.Value=42
    Assert ($ui.TxtLogoSize.Text -eq '17%' -and $ui.TxtLogoFade.Text -eq '42%') 'Slider labels did not update.'
    $ui.CmbLogoMode.SelectedIndex=1
    Assert ($ui.CmbLogoPosition.IsEnabled -and $ui.PanelLogoPosition.Visibility -eq 'Visible') 'Fixed mode did not show position controls.'
    Set-Busy $true
    Assert (-not $ui.BtnPickLogo.IsEnabled -and -not $ui.SldLogoSize.IsEnabled -and -not $ui.CmbLogoPosition.IsEnabled) 'Logo controls remain editable during run.'
    Set-Busy $false
    Assert ($ui.BtnPickLogo.IsEnabled -and $ui.CmbLogoPosition.IsEnabled) 'Logo controls did not restore after run.'
    function Clear-Player {}
    function Reset-Stages {}
    function Add-Log {param($Text,$Color)}
    function Start-Engine {param($Links,$Named,$Mode,$XoaLog);$script:captured=$Named}
    $script:queue=@('https://www.facebook.com/reel/1234/');$script:idx=0
    $ui.TxtLogoPath.Text='C:\Logo của anh\ảnh trong suốt.png'
    foreach($index in 0..4){
        $ui.CmbLogoPosition.SelectedIndex=$index
        Start-Link
        Assert ($script:captured.LogoFile -eq $ui.TxtLogoPath.Text -and $script:captured.LogoSize -eq 17 -and $script:captured.LogoFade -eq 42) 'GUI changed selected path or slider values.'
        Assert ($script:captured.LogoMotion -eq 'Fixed' -and $script:captured.LogoPosition -eq @('TopLeft','TopRight','BottomLeft','BottomRight','Center')[$index]) 'GUI passed wrong fixed position.'
    }
    $ui.CmbLogoMode.SelectedIndex=0; Start-Link
    Assert ($script:captured.LogoMotion -eq 'Free' -and $ui.PanelLogoPosition.Visibility -eq 'Collapsed') 'Free mode did not hide position label and control.'
    $ui.BtnDefaultLogo.RaiseEvent((New-Object Windows.RoutedEventArgs ([Windows.Controls.Button]::ClickEvent)))
    Assert ([string]::IsNullOrEmpty($ui.TxtLogoPath.Text)) 'Default logo button did not clear custom path.'
    Assert ($ui.TxtLogoName.Text -eq 'Đang dùng: Logo Kid' -and $ui.BtnDefaultLogo.Content -eq '✓ Logo Kid' -and $ui.TxtLogoDefaultHint.Visibility -eq 'Visible' -and $null -ne $ui.ImgLogoPreview.Source) 'Default logo selection is not visibly confirmed.'
    $testDir=Join-Path ([IO.Path]::GetTempPath()) ('kidfby-picker-'+[Guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $testDir | Out-Null
    try {
        Add-Type -AssemblyName System.IO.Compression.FileSystem
        $zip=[IO.Compression.ZipFile]::OpenRead((Join-Path $scriptDir 'kid-logo.zip'))
        $pickedPath=Join-Path $testDir 'logo của anh.png'
        try { [IO.Compression.ZipFileExtensions]::ExtractToFile($zip.GetEntry('kid-logo.png'),$pickedPath) } finally { $zip.Dispose() }
        $script:mockDialog=[pscustomobject]@{FileName=$pickedPath;Filter='';CheckFileExists=$false}
        $script:mockDialog | Add-Member ScriptMethod ShowDialog { param($Owner) return $true }
        $picker=$ast.Find({param($n) $n -is [Management.Automation.Language.InvokeMemberExpressionAst] -and $n.Extent.Text.StartsWith('$ui.BtnPickLogo.Add_Click')},$true)
        # Mock only the modal dialog; run the actual selection/validation/event code.
        Invoke-Expression ($picker.Extent.Text.Replace('$dialog = New-Object Microsoft.Win32.OpenFileDialog','$dialog = $script:mockDialog'))
        $ui.BtnPickLogo.RaiseEvent((New-Object Windows.RoutedEventArgs ([Windows.Controls.Button]::ClickEvent)))
        Assert ($ui.TxtLogoPath.Text -eq $pickedPath -and $ui.TxtLogoPath.ToolTip -eq $pickedPath) 'Picker did not display full selected PNG path.'
        Assert ($ui.TxtLogoName.Text -eq 'Đang dùng: logo của anh.png' -and $ui.TxtLogoDefaultHint.Visibility -eq 'Collapsed' -and $ui.BtnDefaultLogo.Content -eq 'Dùng Logo Kid') 'Custom logo selection state incorrect.'
        Assert ($null -ne $ui.ImgLogoPreview.Source -and $ui.ImgLogoPreview.Source.IsFrozen) 'Custom logo thumbnail not loaded.'
        $script:mockDialog | Add-Member ScriptMethod ShowDialog {param($Owner) return $false} -Force
        $ui.BtnPickLogo.RaiseEvent((New-Object Windows.RoutedEventArgs ([Windows.Controls.Button]::ClickEvent)))
        Assert ($ui.TxtLogoPath.Text -eq $pickedPath) 'Cancelling picker cleared the selected logo.'
        $badPath=Join-Path $testDir 'bad.png';[IO.File]::WriteAllText($badPath,'not a PNG')
        $script:mockDialog.FileName=$badPath
        $script:mockDialog | Add-Member ScriptMethod ShowDialog {param($Owner) return $true} -Force
        $ui.BtnPickLogo.RaiseEvent((New-Object Windows.RoutedEventArgs ([Windows.Controls.Button]::ClickEvent)))
        Assert ($ui.TxtLogoPath.Text -eq $pickedPath -and $script:lastToast -match 'PNG') 'Invalid PNG replaced a valid selection or failed to show an error.'
        # The preview must not lock the source file after selecting it.
        $exclusive=[IO.File]::Open($pickedPath,[IO.FileMode]::Open,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None)
        $exclusive.Dispose()
    } finally {
        $resolved=[IO.Path]::GetFullPath($testDir)
        $prefix=[IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\')+'\'
        if(-not $resolved.StartsWith($prefix,[StringComparison]::OrdinalIgnoreCase) -or [IO.Path]::GetFileName($resolved) -notmatch '^kidfby-picker-[0-9a-f]{32}$'){throw 'Unsafe picker cleanup path.'}
        Remove-Item -LiteralPath $resolved -Recurse -Force
    }
    $window.Content.Measure((New-Object Windows.Size 1120,760))
    $window.Content.Arrange((New-Object Windows.Rect 0,0,1120,760))
    $window.Content.UpdateLayout()
    foreach($name in @('BtnPickLogo','SldLogoSize','SldLogoFade','CmbLogoMode','TxtLogoPath')){Assert ($ui[$name].ActualWidth -gt 0 -and $ui[$name].ActualHeight -gt 0) "Logo control not laid out: $name"}
    $pathContentHost=$ui.TxtLogoPath.Template.FindName('PART_ContentHost',$ui.TxtLogoPath)
    Assert ($pathContentHost.ActualHeight -ge 18) 'Logo path text is clipped by insufficient content height.'
    Assert ($ui.PanelLogoPosition.ActualWidth -eq 0) 'Hidden position controls still take layout space.'
    $ui.CmbLogoMode.SelectedIndex=1; $window.Content.UpdateLayout()
    Assert ($ui.CmbLogoPosition.ActualWidth -gt 0) 'Fixed position selector not visible in layout.'
    Write-Host 'PASS logo GUI: picker path/name/thumbnail, default selection confirmation, no image lock, non-clipped text, free hides position, fixed shows it, and engine bindings.'
} finally { $window.Close() }
