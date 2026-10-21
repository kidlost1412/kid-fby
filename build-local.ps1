#Requires -Version 5.1
# Local compile only. This script does not publish, tag, commit or change version.
param([string]$Root='')
$ErrorActionPreference='Stop'
if(-not $Root){$Root=$PSScriptRoot}
$Root=[IO.Path]::GetFullPath($Root)
# The same version file drives the GUI, update payload and launcher metadata.
$buildVersion=[IO.File]::ReadAllText((Join-Path $Root 'core/version.txt')).Trim()
if ($buildVersion -cnotmatch '^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$') {
    throw 'core/version.txt must contain a version in x.y.z format.'
}
foreach ($component in $buildVersion.Split('.')) {
    $versionNumber=0
    if (-not [int]::TryParse($component,[ref]$versionNumber) -or $versionNumber -gt 65534) {
        throw 'Each launcher version component must be between 0 and 65534.'
    }
}
$gui=Join-Path $Root 'core/kid-fby-gui.ps1'
$source=Join-Path $Root 'core/wpf-gif-player.cs'
$tokens=$null;$errors=$null
$ast=[Management.Automation.Language.Parser]::ParseFile($gui,[ref]$tokens,[ref]$errors)
if($errors.Count){throw 'GUI parse failed; local build stopped.'}
$assignments=@($ast.FindAll({param($n)$n -is [Management.Automation.Language.AssignmentStatementAst] -and $n.Left.Extent.Text -eq '$wpfGifPlayerB64'},$true))
if($assignments.Count -ne 1){throw 'Expected exactly one embedded GIF source assignment.'}
$text=[IO.File]::ReadAllText($gui)
$extent=$assignments[0].Right.Extent
$replacement="'"+[Convert]::ToBase64String([IO.File]::ReadAllBytes($source))+"'"
$updated=$text.Substring(0,$extent.StartOffset)+$replacement+$text.Substring($extent.EndOffset)
if($updated -ne $text){[IO.File]::WriteAllText($gui,$updated,[Text.UTF8Encoding]::new($true))}
# The build remains usable without a tests directory.
foreach ($scriptName in @('kid-fby-gui.ps1','kid-fby.ps1','whisper-language.ps1','facebook-links.ps1','fix-ket-noi.ps1','updater.ps1')) {
    $scriptTokens=$null; $scriptErrors=$null
    [void][Management.Automation.Language.Parser]::ParseFile((Join-Path $Root ('core/'+$scriptName)),[ref]$scriptTokens,[ref]$scriptErrors)
    if ($scriptErrors.Count) { throw ('PowerShell parse failed: '+$scriptName) }
}
# Giao dien WPF: XAML phai la XML hop le, UTF-8 BOM + CRLF (giong file .ps1).
foreach ($xamlName in @('ui/Theme.xaml','ui/MainWindow.xaml')) {
    $xamlPath=Join-Path $Root ('core/'+$xamlName)
    $xamlBytes=[IO.File]::ReadAllBytes($xamlPath)
    if ($xamlBytes.Length -lt 3 -or $xamlBytes[0] -ne 0xEF -or $xamlBytes[1] -ne 0xBB -or $xamlBytes[2] -ne 0xBF) { throw ('XAML must be UTF-8 with BOM: '+$xamlName) }
    $xamlText=[Text.Encoding]::UTF8.GetString($xamlBytes)
    if ([regex]::IsMatch($xamlText,'(?<!\r)\n')) { throw ('XAML must use CRLF line endings: '+$xamlName) }
    try { [void]([xml]$xamlText.TrimStart([char]0xFEFF)) } catch { throw ('XAML is not well-formed: '+$xamlName+' '+$_.Exception.Message) }
}
# Phong Nunito (SIL OFL 1.1) nhung vao EXE; font la nhi phan -> chi kiem ton tai + chu ky TrueType, khong chuan hoa dong.
$fontResources=@('ui/fonts/Nunito-Regular.ttf','ui/fonts/Nunito-SemiBold.ttf','ui/fonts/Nunito-ExtraBold.ttf','ui/fonts/OFL.txt')
foreach ($fontName in $fontResources) {
    $fontPath=Join-Path $Root ('core/'+$fontName)
    if (-not (Test-Path -LiteralPath $fontPath -PathType Leaf)) { throw ('Missing UI font resource: '+$fontName) }
    if ($fontName -like '*.ttf') {
        $head=[IO.File]::ReadAllBytes($fontPath)[0..3]
        if (-not ($head[0] -eq 0 -and $head[1] -eq 1 -and $head[2] -eq 0 -and $head[3] -eq 0)) { throw ('Not a TrueType font: '+$fontName) }
    }
}
$compiler='C:\Windows\Microsoft.NET\Framework64\v4.0.30319\csc.exe'
if(-not (Test-Path -LiteralPath $compiler -PathType Leaf)){throw 'C# compiler is unavailable.'}
# Keep generated compiler input outside the checkout and retire only this owned directory.
$assemblyTempDir=Join-Path ([IO.Path]::GetTempPath()) ('kidfby-assembly-'+[guid]::NewGuid().ToString('N'))
$locationPushed=$false
try{
    [void][IO.Directory]::CreateDirectory($assemblyTempDir)
    $assemblyInfo=Join-Path $assemblyTempDir 'AssemblyInfo.cs'
    $assemblyText='using System.Reflection;' + "`r`n" +
        '[assembly: AssemblyVersion("' + $buildVersion + '.0")]' + "`r`n" +
        '[assembly: AssemblyFileVersion("' + $buildVersion + '.0")]' + "`r`n" +
        '[assembly: AssemblyInformationalVersion("' + $buildVersion + '")]' + "`r`n" +
        '[assembly: AssemblyCompany("Kid FB.Y")]' + "`r`n" +
        '[assembly: AssemblyProduct("Kid FB.Y")]' + "`r`n" +
        '[assembly: AssemblyTitle("Kid FB.Y")]' + "`r`n" +
        '[assembly: AssemblyCopyright("' + [char]0x00A9 + ' 2026 Kid FB.Y")]' + "`r`n"
    [IO.File]::WriteAllText($assemblyInfo,$assemblyText,[Text.UTF8Encoding]::new($true))
    Push-Location -LiteralPath $Root
    $locationPushed=$true
    & $compiler /nologo /target:winexe /out:Kid-FB.Y.exe /win32icon:core\Kid-FB.Y.ico /optimize+ /r:System.Windows.Forms.dll `
        /res:core\kid-fby-gui.ps1,kid-fby-gui.ps1 /res:core\kid-fby.ps1,kid-fby.ps1 `
        /res:core\whisper-language.ps1,whisper-language.ps1 /res:core\facebook-links.ps1,facebook-links.ps1 `
        /res:core\fix-ket-noi.ps1,fix-ket-noi.ps1 /res:core\kid-logo.zip,kid-logo.zip /res:core\Kid-FB.Y.ico,Kid-FB.Y.ico `
        /res:core\ui\Theme.xaml,ui.Theme.xaml /res:core\ui\MainWindow.xaml,ui.MainWindow.xaml `
        /res:core\ui\fonts\Nunito-Regular.ttf,ui.fonts.Nunito-Regular.ttf /res:core\ui\fonts\Nunito-SemiBold.ttf,ui.fonts.Nunito-SemiBold.ttf `
        /res:core\ui\fonts\Nunito-ExtraBold.ttf,ui.fonts.Nunito-ExtraBold.ttf /res:core\ui\fonts\OFL.txt,ui.fonts.OFL.txt Program.cs $assemblyInfo
    if($LASTEXITCODE -ne 0){throw 'Local EXE compile failed.'}
    $launcherMetadata=[Diagnostics.FileVersionInfo]::GetVersionInfo((Join-Path $Root 'Kid-FB.Y.exe'))
    if ($launcherMetadata.FileVersion -ne ($buildVersion+'.0') -or $launcherMetadata.ProductVersion -ne $buildVersion) {
        throw 'Launcher version metadata does not match core/version.txt.'
    }
    Write-Output ('Local EXE v'+$buildVersion+' compiled with synchronized GIF source and thirteen embedded resources (9 + 4 font files).')
}finally{
    if ($locationPushed) { Pop-Location }
    $resolvedAssembly=[IO.Path]::GetFullPath($assemblyTempDir)
    $assemblyBoundary=[IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\')+'\'
    if (-not $resolvedAssembly.StartsWith($assemblyBoundary,[StringComparison]::OrdinalIgnoreCase) -or
        [IO.Path]::GetDirectoryName($resolvedAssembly) -ne $assemblyBoundary.TrimEnd('\') -or
        [IO.Path]::GetFileName($resolvedAssembly) -notmatch '^kidfby-assembly-[0-9a-f]{32}$') { throw 'Unsafe assembly-input cleanup path.' }
    if (Test-Path -LiteralPath $resolvedAssembly) { Remove-Item -LiteralPath $resolvedAssembly -Recurse -Force }
}

# Check the actual launcher in a fresh, disposable directory.
$buildCheckDir=Join-Path ([IO.Path]::GetTempPath()) ('kidfby-build-check-'+[guid]::NewGuid().ToString('N'))
$buildProcess=$null
[void](New-Item -ItemType Directory -Path (Join-Path $buildCheckDir 'core'))
try {
    Copy-Item -LiteralPath (Join-Path $Root 'Kid-FB.Y.exe') -Destination $buildCheckDir
    foreach ($config in @('version.txt','updater.ps1','update.json')) {
        Copy-Item -LiteralPath (Join-Path $Root ('core/'+$config)) -Destination (Join-Path $buildCheckDir 'core')
    }
    $buildInfo=[Diagnostics.ProcessStartInfo]::new()
    $buildInfo.FileName=Join-Path $buildCheckDir 'Kid-FB.Y.exe'
    $buildInfo.Arguments='-SelfTest'
    $buildInfo.WorkingDirectory=$buildCheckDir
    $buildInfo.UseShellExecute=$false
    $buildInfo.CreateNoWindow=$true
    $buildInfo.WindowStyle=[Diagnostics.ProcessWindowStyle]::Hidden
    # Build check must not collide with a Kid FB.Y the developer already has open.
    $buildInfo.EnvironmentVariables['KID_FBY_ALLOW_MULTI']='1'
    $buildProcess=[Diagnostics.Process]::Start($buildInfo)
    if (-not $buildProcess.WaitForExit(30000)) {
        & taskkill.exe /F /T /PID $buildProcess.Id | Out-Null
        throw 'Fresh launcher SelfTest exceeded 30 seconds.'
    }
    if ($buildProcess.ExitCode -ne 0) { throw ('Fresh launcher SelfTest failed: '+$buildProcess.ExitCode) }
    foreach ($resource in (@('kid-fby-gui.ps1','kid-fby.ps1','whisper-language.ps1','facebook-links.ps1','fix-ket-noi.ps1','Kid-FB.Y.ico','kid-logo.zip','ui/Theme.xaml','ui/MainWindow.xaml') + $fontResources)) {
        $expected=(Get-FileHash -LiteralPath (Join-Path $Root ('core/'+$resource))).Hash
        $actual=(Get-FileHash -LiteralPath (Join-Path $buildCheckDir ('core/'+$resource))).Hash
        if ($actual -ne $expected) { throw ('Embedded resource mismatch: '+$resource) }
    }
    if (-not (Test-Path -LiteralPath (Join-Path $buildCheckDir 'core/_update/BOOT_OK'))) { throw 'Fresh GUI did not report BOOT_OK.' }
    Write-Output 'PASS: fresh launcher SelfTest and all thirteen embedded resource hashes (fonts byte-identical).'
} finally {
    if ($buildProcess) { $buildProcess.Dispose() }
    $resolvedCheck=[IO.Path]::GetFullPath($buildCheckDir)
    $tempBoundary=[IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\')+'\'
    if (-not $resolvedCheck.StartsWith($tempBoundary,[StringComparison]::OrdinalIgnoreCase) -or [IO.Path]::GetFileName($resolvedCheck) -notmatch '^kidfby-build-check-[0-9a-f]{32}$') { throw 'Unsafe build-check cleanup path.' }
    Remove-Item -LiteralPath $resolvedCheck -Recurse -Force
}
