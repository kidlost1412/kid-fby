#Requires -Version 5.1
$ErrorActionPreference = 'Stop'
$taskRoot = $PSScriptRoot
$taskPython = Join-Path $taskRoot '.venv\Scripts\python.exe'
$taskHost = Join-Path $taskRoot 'run_autotok_web.py'
$taskRuntime = Join-Path $taskRoot 'runtime'
if (-not (Test-Path -LiteralPath $taskPython -PathType Leaf)) { throw 'Chua cai dat autotok. Chay integrations\autotok\cai-dat.ps1 truoc.' }
New-Item -ItemType Directory -Path $taskRuntime -Force | Out-Null

# Check step: resolve paths/Chrome via the host itself (single source of truth) and verify the CLI.
$taskCheckLines = @(& $taskPython $taskHost --check)
if ($LASTEXITCODE -ne 0) { throw 'Host check failed.' }
$taskCheck = @{}
foreach ($taskLine in $taskCheckLines) { if ("$taskLine" -match '^(SRC|DATA|DIST|CHROME)=(.*)$') { $taskCheck[$Matches[1]] = $Matches[2] } }
if (-not $taskCheck.DATA -or -not $taskCheck.SRC) { throw 'Host check returned no paths.' }
if ($taskCheck.CHROME -like 'NOT FOUND*') { throw 'Chrome was not found.' }
if ($taskCheck.DIST -notlike '*index.html=True') { throw 'Frontend build (web\frontend\dist) is missing.' }
$taskData = $taskCheck.DATA

# Apply a Windows DACL (user + SYSTEM only) on the private data directory; Python chmod(0600) does not create this protection.
New-Item -ItemType Directory -Path $taskData -Force | Out-Null
$taskDirectoryInfo = [System.IO.DirectoryInfo]::new($taskData)
if ($PSVersionTable.PSEdition -eq 'Desktop') { $taskAcl = $taskDirectoryInfo.GetAccessControl([System.Security.AccessControl.AccessControlSections]::Access) } else { $taskAcl = [System.IO.FileSystemAclExtensions]::GetAccessControl($taskDirectoryInfo, [System.Security.AccessControl.AccessControlSections]::Access) }
$taskAcl.SetAccessRuleProtection($true, $false)
foreach ($taskOldRule in @($taskAcl.GetAccessRules($true, $false, [System.Security.Principal.SecurityIdentifier]))) {
    $taskAcl.RemoveAccessRuleSpecific($taskOldRule)
}
$taskUserSid = [System.Security.Principal.WindowsIdentity]::GetCurrent().User
$taskSystemSid = [System.Security.Principal.SecurityIdentifier]::new('S-1-5-18')
foreach ($taskSid in @($taskUserSid, $taskSystemSid)) {
    $taskRule = [System.Security.AccessControl.FileSystemAccessRule]::new(
        $taskSid,
        [System.Security.AccessControl.FileSystemRights]::FullControl,
        [System.Security.AccessControl.InheritanceFlags]'ContainerInherit,ObjectInherit',
        [System.Security.AccessControl.PropagationFlags]::None,
        [System.Security.AccessControl.AccessControlType]::Allow
    )
    $taskAcl.AddAccessRule($taskRule)
}
if ($PSVersionTable.PSEdition -eq 'Desktop') { $taskDirectoryInfo.SetAccessControl($taskAcl) } else { [System.IO.FileSystemAclExtensions]::SetAccessControl($taskDirectoryInfo, $taskAcl) }

$taskStatePath = Join-Path $taskRuntime 'processes.json'
$taskServicePorts = [ordered]@{ api = 8765; control = 17900; scheduler = $null }

# Windows PowerShell 5.1 has no ConvertTo-Json -AsArray; -InputObject @(...) writes a JSON array in 5.1 and 7.
function Save-TaskState($records) {
    ConvertTo-Json -InputObject @($records) | Set-Content -Encoding utf8 -LiteralPath $taskStatePath
}

# A recorded service counts as running only while that exact process (PID + start time) is alive.
$taskStarted = @()
if (Test-Path -LiteralPath $taskStatePath) {
    # Assign first: in 5.1 ConvertFrom-Json emits a JSON array as ONE pipeline object, so @(... | ConvertFrom-Json) would nest it.
    $taskExisting = Get-Content -Raw -LiteralPath $taskStatePath | ConvertFrom-Json
    foreach ($taskRecord in @($taskExisting)) {
        if (-not $taskRecord -or -not $taskServicePorts.Contains([string]$taskRecord.service)) { continue }
        $taskProcess = Get-Process -Id $taskRecord.pid -ErrorAction SilentlyContinue
        if (-not $taskProcess) { continue }
        try { $taskTicks = $taskProcess.StartTime.ToUniversalTime().Ticks.ToString() } catch { $taskTicks = $null }
        # PID reused (or start time unreadable, e.g. a system process): do not trust it.
        if ($taskProcess.ProcessName -ne 'python' -or -not $taskTicks -or $taskTicks -ne [string]$taskRecord.startTimeUtcTicks) { continue }
        $taskStarted += [PSCustomObject]@{service=[string]$taskRecord.service; pid=[int]$taskRecord.pid; startTimeUtcTicks=[string]$taskRecord.startTimeUtcTicks}
    }
}
$taskRunning = @($taskStarted | ForEach-Object { $_.service })
$taskMissing = @($taskServicePorts.Keys | Where-Object { $taskRunning -notcontains $_ })
if ($taskMissing.Count -eq 0) {
    Write-Output 'Dashboard already running: http://127.0.0.1:8765'
    return
}
if ($taskRunning.Count -gt 0) {
    Write-Output ('Dashboard partly running (' + ($taskRunning -join ', ') + '); starting only: ' + ($taskMissing -join ', '))
}

foreach ($taskService in $taskMissing) {
    $taskPort = $taskServicePorts[$taskService]
    if ($taskPort -and (Get-NetTCPConnection -State Listen -LocalPort $taskPort -ErrorAction SilentlyContinue)) {
        throw "Local port $taskPort is already in use by another process."
    }
}

# Uploader probes video size/duration with ffprobe; point it at Kid FB.Y's bundled copy when present.
$taskFfprobe = Join-Path (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)) 'tools' | Join-Path -ChildPath 'ffmpeg' | Join-Path -ChildPath 'ffprobe.exe'
if (-not $env:KID_FBY_FFPROBE -and (Test-Path -LiteralPath $taskFfprobe -PathType Leaf)) { $env:KID_FBY_FFPROBE = $taskFfprobe }

foreach ($taskService in $taskMissing) {
    $taskProcess = Start-Process -FilePath $taskPython -ArgumentList @('"' + $taskHost + '"', $taskService) `
        -WorkingDirectory $taskRoot -WindowStyle Hidden -PassThru `
        -RedirectStandardOutput (Join-Path $taskRuntime "$taskService.stdout.log") `
        -RedirectStandardError (Join-Path $taskRuntime "$taskService.stderr.log")
    $taskStarted += [PSCustomObject]@{service=$taskService; pid=$taskProcess.Id; startTimeUtcTicks=$taskProcess.StartTime.ToUniversalTime().Ticks.ToString()}
    Save-TaskState $taskStarted
}
Write-Output 'Dashboard starting: http://127.0.0.1:8765'
$taskStarted | Format-Table service,pid
