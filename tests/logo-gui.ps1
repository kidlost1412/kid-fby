#Requires -Version 5.1
param([string]$Root=(Split-Path $PSScriptRoot -Parent))
$ErrorActionPreference='Stop'
Add-Type -AssemblyName PresentationFramework,PresentationCore,WindowsBase,System.Drawing
$tokens=$null; $errors=$null
$ast=[Management.Automation.Language.Parser]::ParseFile((Join-Path $Root 'core/kid-fby-gui.ps1'),[ref]$tokens,[ref]$errors)
if($errors.Count){throw 'GUI parse failed.'}
function Assert([bool]$Condition,[string]$Message){if(-not $Condition){throw $Message}}
$assignment=$ast.Find({param($n) $n -is [Management.Automation.Language.AssignmentStatementAst] -and $n.Left.Extent.Text -eq '[xml]$xaml'},$true)
if(-not $assignment){throw 'Cannot find XAML.'}
Invoke-Expression $assignment.Extent.Text
$window=[Windows.Markup.XamlReader]::Load((New-Object Xml.XmlNodeReader $xaml))
try {
    $ui=@{}
    foreach($element in $xaml.SelectNodes('//*[@*[local-name()="Name"]]')) {
        $name=$element.GetAttribute('Name','http://schemas.microsoft.com/winfx/2006/xaml')
        if($name){$ui[$name]=$window.FindName($name)}
    }
    foreach($name in @('ChkWatermark','TxtLogoPath','BtnPickLogo','BtnDefaultLogo','SldLogoSize','TxtLogoSize','SldLogoFade','TxtLogoFade','CmbLogoMode','CmbLogoPosition')){Assert ($null -ne $ui[$name]) "Missing logo control: $name"}
    foreach($name in @('Start-Link','Set-Busy')) {
        $fn=$ast.Find({param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq $name},$true)
        Invoke-Expression $fn.Extent.Text
    }
    foreach($prefix in @('$ui.SldLogoSize.Add_ValueChanged','$ui.SldLogoFade.Add_ValueChanged','$ui.CmbLogoMode.Add_SelectionChanged','$ui.BtnDefaultLogo.Add_Click')){
        $call=$ast.Find({param($n) $n -is [Management.Automation.Language.InvokeMemberExpressionAst] -and $n.Extent.Text.StartsWith($prefix)},$true)
        Assert ($null -ne $call) "Missing event: $prefix"
        Invoke-Expression $call.Extent.Text
    }
    $ui.SldLogoSize.Value=17; $ui.SldLogoFade.Value=42
    Assert ($ui.TxtLogoSize.Text -eq '17% chiều rộng' -and $ui.TxtLogoFade.Text -eq '42%') 'Slider labels did not update.'
    $ui.CmbLogoMode.SelectedIndex=1
    Assert $ui.CmbLogoPosition.IsEnabled 'Fixed mode did not enable position control.'
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
    Assert ($script:captured.LogoMotion -eq 'Free' -and -not $ui.CmbLogoPosition.IsEnabled) 'Free mode binding/position state incorrect.'
    $ui.BtnDefaultLogo.RaiseEvent((New-Object Windows.RoutedEventArgs ([Windows.Controls.Button]::ClickEvent)))
    Assert ([string]::IsNullOrEmpty($ui.TxtLogoPath.Text)) 'Default logo button did not clear custom path.'
    $window.Content.Measure((New-Object Windows.Size 1120,760))
    $window.Content.Arrange((New-Object Windows.Rect 0,0,1120,760))
    $window.Content.UpdateLayout()
    foreach($name in @('BtnPickLogo','SldLogoSize','SldLogoFade','CmbLogoMode','CmbLogoPosition')){Assert ($ui[$name].ActualWidth -gt 0 -and $ui[$name].ActualHeight -gt 0) "Logo control not laid out: $name"}
    Write-Host 'PASS logo GUI: WPF controls/layout, live labels, busy states, all positions, exact engine arguments, and default-logo reset.'
} finally { $window.Close() }
