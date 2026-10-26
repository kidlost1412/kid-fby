# Two separate powershell.exe processes hammer Update-ReupMetadata on the same folder: no lost field, valid JSON.
. (Join-Path $PSScriptRoot '_load.ps1')
$out = New-TestDir
$iterations = 200
$ps = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
$hammer = Join-Path $PSScriptRoot 'hammer.ps1'

# the shared entry exists up front (history-shaped, so both processes edit it)
Write-TestMetadata $out @{ '9' = [ordered]@{ Posted = $false; Date = ''; Source = 'autotok-history'; History = @(); ManualPosted = $false; ManualDate = ''; Extra = 'keep me' } }

$procs = foreach ($mode in 'Posted', 'History') {
    $log = Join-Path $out "hammer-$mode.log"
    $args = @('-NoProfile', '-STA', '-File', $hammer, '-Mode', $mode, '-OutDir', $out, '-Iterations', $iterations)
    $proc = Start-Process -FilePath $ps -ArgumentList $args -PassThru -WindowStyle Hidden -RedirectStandardError $log
    [void]$proc.Handle   # keep the handle so ExitCode is readable after exit
    [pscustomobject]@{ Mode = $mode; Log = $log; Proc = $proc }
}
$sw = [Diagnostics.Stopwatch]::StartNew()
foreach ($p in $procs) { if (-not $p.Proc.WaitForExit(300000)) { $p.Proc.Kill(); throw "$($p.Mode) process timed out" } }
Write-Output "INFO  both processes finished in $([Math]::Round($sw.Elapsed.TotalSeconds, 1)) s"

Test-Case 'both processes exit 0 with no failed iteration' {
    foreach ($p in $procs) { Assert-Equal $p.Proc.ExitCode 0 "$($p.Mode) exit code ($([IO.File]::ReadAllText($p.Log)))" }
}
Test-Case 'final reup-status.json is valid for the app validator' {
    $meta = Get-ReupMetadata -OutDir $out
    Assert-Equal @($meta.PSObject.Properties).Count (2 * $iterations + 1) 'entry count'
}
Test-Case 'no lost field: every own entry of both processes is complete' {
    $meta = Get-ReupMetadata -OutDir $out
    for ($i = 1; $i -le $iterations; $i++) {
        $a = $meta.([string](1000000 + $i)); $b = $meta.([string](2000000 + $i))
        if ($null -eq $a -or $a.Posted -ne $true -or $a.Date -notmatch '^\d\d/\d\d \d\d:\d\d$') { throw "Posted entry $i incomplete: $(ConvertTo-Json $a -Compress)" }
        if ($null -eq $b -or @($b.History).Count -ne 1 -or $b.Posted -ne $true) { throw "History entry $i incomplete: $(ConvertTo-Json $b -Compress -Depth 5)" }
    }
}
Test-Case 'shared entry keeps both writers'' fields (manual mark from one, all history from the other, unknown field)' {
    $e = (Get-ReupMetadata -OutDir $out).'9'
    Assert-Equal $e.ManualPosted $true 'manual mark from the Posted process'
    Assert-Equal @($e.History).Count $iterations 'history keys'
    Assert-Equal @($e.History | ForEach-Object { $_.key } | Sort-Object -Unique).Count $iterations 'distinct keys'
    Assert-Equal $e.Extra 'keep me'
}
Test-Case 'no temp files left behind' {
    Assert-Equal @(Get-ChildItem -LiteralPath $out -Force -Filter '.reup-status-*.tmp').Count 0
}
Remove-Item -LiteralPath $out -Recurse -Force -ErrorAction SilentlyContinue
Complete-Tests
