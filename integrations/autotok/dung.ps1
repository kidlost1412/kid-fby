#Requires -Version 5.1
<#
Dung cac dich vu autotok do start.ps1 da bat. Chi dung dung tien trinh da ghi trong runtime\processes.json
(PID + gio khoi dong + ten tien trinh phai khop). Tu choi neu co lich dang chay hoac video dang cho gui len TikTok, tru khi co -Force.
#>
param([switch]$Force)

$ErrorActionPreference = 'Stop'
$taskStatePath = Join-Path $PSScriptRoot 'runtime\processes.json'
if (-not (Test-Path -LiteralPath $taskStatePath -PathType Leaf)) { Write-Output 'Khong co dich vu nao dang duoc ghi nhan.'; return }

$taskExisting = Get-Content -Raw -LiteralPath $taskStatePath | ConvertFrom-Json
$taskAlive = @()
foreach ($taskRecord in @($taskExisting)) {
    if (-not $taskRecord) { continue }
    $taskProcess = Get-Process -Id $taskRecord.pid -ErrorAction SilentlyContinue
    if (-not $taskProcess) { continue }
    try { $taskTicks = $taskProcess.StartTime.ToUniversalTime().Ticks.ToString() } catch { $taskTicks = $null }
    if ($taskProcess.ProcessName -ne 'python' -or -not $taskTicks -or $taskTicks -ne [string]$taskRecord.startTimeUtcTicks) { continue }
    $taskAlive += $taskRecord
}
if ($taskAlive.Count -eq 0) { Write-Output 'Cac dich vu da ghi nhan khong con chay.'; return }

if (-not $Force -and ($taskAlive | Where-Object { $_.service -eq 'api' })) {
    try {
        $taskRunningJobs = @(Invoke-RestMethod -Uri 'http://127.0.0.1:8765/api/schedules?status=running' -TimeoutSec 5)
        $taskPendingJobs = @(Invoke-RestMethod -Uri 'http://127.0.0.1:8765/api/schedules?status=pending' -TimeoutSec 5)
    } catch {
        throw "Khong kiem tra duoc lich dang chay ($($_.Exception.Message)). Dung -Force neu chac chan muon dung."
    }
    if ($taskRunningJobs.Count -gt 0) { throw "Dang co $($taskRunningJobs.Count) lich dang dang bai. Doi xong hoac dung -Force." }
    if ($taskPendingJobs.Count -gt 0) { throw "Con video dang cho gui len TikTok ($($taskPendingJobs.Count) lich). Doi gui xong hoac dung -Force." }
}

# The venv python.exe may be a launcher whose child holds the port: stop the recorded process and its descendants.
function Get-Descendants([int]$ParentId) {
    foreach ($taskChild in @(Get-CimInstance Win32_Process -Filter "ParentProcessId=$ParentId")) {
        Get-Descendants $taskChild.ProcessId
        $taskChild.ProcessId
    }
}
foreach ($taskRecord in $taskAlive) {
    foreach ($taskId in @(Get-Descendants ([int]$taskRecord.pid)) + @([int]$taskRecord.pid)) {
        Stop-Process -Id $taskId -Force -ErrorAction SilentlyContinue
    }
    Write-Output "Da dung $($taskRecord.service) (PID $($taskRecord.pid))"
}
ConvertTo-Json -InputObject @() | Set-Content -Encoding utf8 -LiteralPath $taskStatePath
