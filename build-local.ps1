#Requires -Version 5.1
# Local compile only. This script does not publish, tag, commit or change version.
param([string]$Root='')
$ErrorActionPreference='Stop'
if(-not $Root){$Root=$PSScriptRoot}
$Root=[IO.Path]::GetFullPath($Root)
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
$compiler='C:\Windows\Microsoft.NET\Framework64\v4.0.30319\csc.exe'
if(-not (Test-Path -LiteralPath $compiler -PathType Leaf)){throw 'C# compiler is unavailable.'}
Push-Location $Root
try{
    & $compiler /nologo /target:winexe /out:Kid-FB.Y.exe /win32icon:core\Kid-FB.Y.ico /optimize+ /r:System.Windows.Forms.dll `
        /res:core\kid-fby-gui.ps1,kid-fby-gui.ps1 /res:core\kid-fby.ps1,kid-fby.ps1 `
        /res:core\whisper-language.ps1,whisper-language.ps1 /res:core\facebook-links.ps1,facebook-links.ps1 `
        /res:core\fix-ket-noi.ps1,fix-ket-noi.ps1 /res:core\kid-logo.zip,kid-logo.zip /res:core\Kid-FB.Y.ico,Kid-FB.Y.ico Program.cs
    if($LASTEXITCODE -ne 0){throw 'Local EXE compile failed.'}
    Write-Output 'Local EXE compiled with synchronized GIF source and seven embedded resources.'
}finally{Pop-Location}

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
    $buildProcess=[Diagnostics.Process]::Start($buildInfo)
    if (-not $buildProcess.WaitForExit(30000)) {
        & taskkill.exe /F /T /PID $buildProcess.Id | Out-Null
        throw 'Fresh launcher SelfTest exceeded 30 seconds.'
    }
    if ($buildProcess.ExitCode -ne 0) { throw ('Fresh launcher SelfTest failed: '+$buildProcess.ExitCode) }
    foreach ($resource in @('kid-fby-gui.ps1','kid-fby.ps1','whisper-language.ps1','facebook-links.ps1','fix-ket-noi.ps1','Kid-FB.Y.ico','kid-logo.zip')) {
        $expected=(Get-FileHash -LiteralPath (Join-Path $Root ('core/'+$resource))).Hash
        $actual=(Get-FileHash -LiteralPath (Join-Path $buildCheckDir ('core/'+$resource))).Hash
        if ($actual -ne $expected) { throw ('Embedded resource mismatch: '+$resource) }
    }
    if (-not (Test-Path -LiteralPath (Join-Path $buildCheckDir 'core/_update/BOOT_OK'))) { throw 'Fresh GUI did not report BOOT_OK.' }
    Write-Output 'PASS: fresh launcher SelfTest and all seven embedded resource hashes.'
} finally {
    if ($buildProcess) { $buildProcess.Dispose() }
    $resolvedCheck=[IO.Path]::GetFullPath($buildCheckDir)
    $tempBoundary=[IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\')+'\'
    if (-not $resolvedCheck.StartsWith($tempBoundary,[StringComparison]::OrdinalIgnoreCase) -or [IO.Path]::GetFileName($resolvedCheck) -notmatch '^kidfby-build-check-[0-9a-f]{32}$') { throw 'Unsafe build-check cleanup path.' }
    Remove-Item -LiteralPath $resolvedCheck -Recurse -Force
}
