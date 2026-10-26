# Runs every tests\kho\NN-*.ps1 in its own powershell.exe (-STA) and fails when any of them fails.
$ps = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
$failed = @()
foreach ($t in Get-ChildItem -LiteralPath $PSScriptRoot -Filter '*.ps1' | Where-Object { $_.Name -match '^[0-9][0-9]-' } | Sort-Object Name) {
    Write-Output "=== $($t.Name)"
    & $ps -NoProfile -STA -File $t.FullName
    Write-Output "=== $($t.Name) exit=$LASTEXITCODE"
    if ($LASTEXITCODE -ne 0) { $failed += $t.Name }
}
if ($failed.Count) { Write-Output "FAILED: $($failed -join ', ')"; exit 1 }
Write-Output 'ALL TEST FILES PASSED'; exit 0
