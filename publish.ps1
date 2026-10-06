#Requires -Version 5.1
<#
  Phat hanh ban moi Kid FB.Y len GitHub.
    .\publish.ps1 -Version 1.1.0 -Note "Sua loi bam Dung bi dung tool","Them nut cap nhat"
    .\publish.ps1 -Version 1.1.1 -Note "Fix gap" -Mandatory     (bat buoc khach cap nhat)
    .\publish.ps1 -Version 1.1.0 -Note "..." -NoPush            (chi tao version.json, khong git push)
#>
param(
    [Parameter(Mandatory = $true)][string]$Version,
    [string[]]$Note = @(),
    [switch]$Mandatory,
    [switch]$NoPush
)
$ErrorActionPreference = 'Stop'
$root = $PSScriptRoot
Set-Location $root

try { [void][version]$Version } catch { throw "Phien ban khong dung dinh dang x.y.z (vi du: 1.1.0)" }

$verFile = Join-Path $root 'core\version.txt'
$old = if (Test-Path $verFile) { (Get-Content $verFile -Raw).Trim() } else { '0.0.0' }
if ([version]$Version -le [version]$old) {
    throw "Version moi ($Version) phai lon hon version hien tai ($old)"
}

Write-Host "=== PHAT HANH PHIEN BAN MOI: v$Version (hien tai: v$old) ===" -ForegroundColor Cyan

# 1. Tu dong khoi tao git neu chua co
if (-not (Test-Path (Join-Path $root '.git'))) {
    Write-Host "[1/6] Khoi tao Git repository..." -ForegroundColor Yellow
    & git init -b main | Out-Null
} else {
    Write-Host "[1/6] Git repository da san sang." -ForegroundColor Green
}

# 2. Phat hien remote origin va tu dong cap nhat core\update.json neu can
$remoteUrl = ''
try { $remoteUrl = (& git remote get-url origin 2>$null) } catch { }
$cfgFile = Join-Path $root 'core\update.json'
if ($remoteUrl -and ($remoteUrl -match 'github\.com[:/]([^/]+)/([^/\.]+?)(\.git)?$')) {
    $detectedRepo = "$($matches[1])/$($matches[2])"
    $curCfg = @{}
    if (Test-Path $cfgFile) {
        try { $curCfg = Get-Content $cfgFile -Raw -Encoding UTF8 | ConvertFrom-Json } catch { }
    }
    if ($curCfg.repo -ne $detectedRepo) {
        $newCfg = [ordered]@{ repo = $detectedRepo; branch = if ($curCfg.branch) { $curCfg.branch } else { 'main' } }
        [System.IO.File]::WriteAllText($cfgFile, ($newCfg | ConvertTo-Json), (New-Object System.Text.UTF8Encoding($false)))
        Write-Host "[2/6] Da tu dong cap nhat core\update.json -> $detectedRepo" -ForegroundColor Green
    } else {
        Write-Host "[2/6] Cau hinh update.json hop le ($detectedRepo)." -ForegroundColor Green
    }
} else {
    Write-Host "[2/6] Chua ket noi remote GitHub. Dang dung file update.json hien tai." -ForegroundColor Yellow
}

# 3. Ghi version.txt
[System.IO.File]::WriteAllText($verFile, $Version)
Write-Host "[3/6] Da ghi version $Version vao core\version.txt" -ForegroundColor Green

# 4. Build lai Kid-FB.Y.exe de nhung code moi nhat
Write-Host "[4/6] Dang bien dich Kid-FB.Y.exe moi..." -ForegroundColor Yellow
$csc = 'C:\Windows\Microsoft.NET\Framework64\v4.0.30319\csc.exe'
if (Test-Path $csc) {
    & $csc /nologo /target:winexe /out:Kid-FB.Y.exe /win32icon:core\Kid-FB.Y.ico `
        /r:System.Windows.Forms.dll `
        /res:core\kid-fby-gui.ps1,kid-fby-gui.ps1 `
        /res:core\kid-fby.ps1,kid-fby.ps1 `
        /res:core\fix-ket-noi.ps1,fix-ket-noi.ps1 `
        /res:core\Kid-FB.Y.ico,Kid-FB.Y.ico Program.cs
    if ($LASTEXITCODE -eq 0) {
        Write-Host "    -> Bien dich Kid-FB.Y.exe thanh cong." -ForegroundColor Green
    } else {
        Write-Host "    ! Khong bien dich duoc Kid-FB.Y.exe (ma $LASTEXITCODE). Giu nguyen file cu." -ForegroundColor Yellow
    }
}

# 5. Tao manifest version.json hoan chinh
Write-Host "[5/6] Dang tao manifest version.json..." -ForegroundColor Yellow
$coreFiles = Get-ChildItem 'core' -File | Where-Object {
    $_.Extension -in '.ps1','.ico','.txt' -and $_.Name -notin @('run.log')
} | ForEach-Object {
    [ordered]@{
        path   = "core/$($_.Name)"
        sha256 = (Get-FileHash $_.FullName -Algorithm SHA256).Hash
        size   = $_.Length
    }
}

$man = [ordered]@{
    version     = $Version
    releasedAt  = (Get-Date).ToString('yyyy-MM-dd HH:mm')
    minLauncher = '1.0.0'
    mandatory   = [bool]$Mandatory
    changelog   = @($Note)
    files       = @($coreFiles)
    tools       = [ordered]@{
        'yt-dlp' = [ordered]@{ version = 'latest'; exe = 'yt-dlp.exe' }
        'scrcpy' = [ordered]@{ version = '3.1';    exe = 'scrcpy.exe' }
        'ffmpeg' = [ordered]@{ version = 'release'; exe = 'ffmpeg.exe' }
    }
}
[System.IO.File]::WriteAllText((Join-Path $root 'version.json'), ($man | ConvertTo-Json -Depth 5), (New-Object System.Text.UTF8Encoding($false)))
Write-Host "    -> Da tao version.json ($(@($coreFiles).Count) file)" -ForegroundColor Green

if ($NoPush) {
    Write-Host "`n[HOAN TAT] Che do -NoPush: Da tao san ban v$Version tren may. Khong push len Git." -ForegroundColor Cyan
    return
}

# 6. Commit & Push len GitHub
Write-Host "[6/6] Dang commit va day len GitHub..." -ForegroundColor Yellow
if (-not $remoteUrl) {
    Write-Host "`n! Luu y quan trong:" -ForegroundColor Yellow
    Write-Host "  Chua co remote GitHub origin de push. Hay tao repo tren GitHub roi chay lenh sau tren may:" -ForegroundColor White
    Write-Host "    git remote add origin https://github.com/<tai-khoan>/<ten-repo>.git" -ForegroundColor Cyan
    Write-Host "    git add -A" -ForegroundColor Cyan
    Write-Host "    git commit -m `"Phat hanh ban v$Version`"" -ForegroundColor Cyan
    Write-Host "    git push -u origin main`n" -ForegroundColor Cyan
    return
}

& git add -A
$commitMsg = if ($Note -and $Note.Count -gt 0) { "v$Version - $($Note -join '; ')" } else { "Release v$Version" }
& git commit -m $commitMsg
& git tag -f "v$Version"
& git push -u origin main
& git push origin "v$Version"

Write-Host "`n[THANH CONG] Da phat hanh ban v$Version len GitHub!" -ForegroundColor Green
Write-Host "May khach chi can mo tool hoac bam nut 'Cap nhat' la se tu dong nhan ban moi!" -ForegroundColor Green
