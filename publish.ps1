#Requires -Version 5.1
<#
  Phat hanh ban moi Kid FB.Y len GitHub.
    .\publish.ps1 -Version 1.1.0 -Note "Sua loi bam Dung bi dung tool","Them nut cap nhat"
    .\publish.ps1 -Version 1.1.1 -Note "Fix gap" -Mandatory     (bat buoc khach cap nhat)
    .\publish.ps1 -Version 1.1.0 -Note "..." -NoPush            (doi version, build va tao manifest; khong commit/tag/push)
#>
param(
    [Parameter(Mandatory = $true)][string]$Version,
    [string[]]$Note = @(),
    [switch]$Mandatory,
    [switch]$NoPush,
    [string]$SigningKeyPath = ''
)
$ErrorActionPreference = 'Stop'
$root = $PSScriptRoot
Set-Location -LiteralPath $root

if ($Version -cnotmatch '^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$') { throw 'Version phai co dinh dang x.y.z.' }
foreach ($component in $Version.Split('.')) {
    $versionNumber=0
    if (-not [int]::TryParse($component,[ref]$versionNumber) -or $versionNumber -gt 65534) { throw 'Moi thanh phan version phai tu 0 den 65534.' }
}

$verFile = Join-Path $root 'core\version.txt'
$old = if (Test-Path -LiteralPath $verFile) { (Get-Content -LiteralPath $verFile -Raw).Trim() } else { '0.0.0' }
if ([version]$Version -le [version]$old) {
    throw "Version moi ($Version) phai lon hon version hien tai ($old)"
}

# Khoa ky manifest (RSA-SHA256). Khoa rieng nam NGOAI repo; thieu khoa -> dung truoc khi doi bat cu thu gi.
if (-not $SigningKeyPath) { $SigningKeyPath = Join-Path $env:USERPROFILE '.kidfby\update-signing-private.xml' }
if (-not (Test-Path -LiteralPath $SigningKeyPath -PathType Leaf)) {
    throw "Thieu khoa ky manifest: $SigningKeyPath. Chay .\new-signing-key.ps1 de tao (va dan khoa cong khai vao core\updater.ps1). Dung phat hanh."
}
$signingFull = [IO.Path]::GetFullPath($SigningKeyPath)
if ($signingFull.StartsWith(([IO.Path]::GetFullPath($root).TrimEnd('\') + '\'), [StringComparison]::OrdinalIgnoreCase)) {
    throw "Khoa rieng nam trong repo ($signingFull). Chuyen ra ngoai repo roi chay lai."
}

if ([System.IO.File]::ReadAllText((Join-Path $root 'core\updater.ps1')) -match 'PUBLIC_KEY_PLACEHOLDER') {
    throw 'core\updater.ps1 van la placeholder khoa ky: ban phat hanh se lam khach mat tu cap nhat. Chay .\new-signing-key.ps1, dan chuoi khoa cong khai vao $UpdatePublicKeyXml trong core\updater.ps1, roi phat hanh lai (ke ca -NoPush).'
}

Write-Host "=== PHAT HANH PHIEN BAN MOI: v$Version (hien tai: v$old) ===" -ForegroundColor Cyan

# 1. Tu dong khoi tao git neu chua co
if (-not (Test-Path -LiteralPath (Join-Path $root '.git'))) {
    Write-Host "[1/6] Khoi tao Git repository..." -ForegroundColor Yellow
    & git init -b main | Out-Null
    if ($LASTEXITCODE -ne 0) { throw 'git init that bai. Dung phat hanh.' }
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
    if (Test-Path -LiteralPath $cfgFile) {
        try { $curCfg = Get-Content -LiteralPath $cfgFile -Raw -Encoding UTF8 | ConvertFrom-Json } catch { }
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
& powershell.exe -NoProfile -STA -ExecutionPolicy Bypass -File (Join-Path $root 'build-local.ps1') -Root $root
if ($LASTEXITCODE -ne 0) { throw 'Local build or launcher verification failed. Publishing stopped.' }

# 5. Tao manifest version.json hoan chinh
Write-Host "[5/6] Dang tao manifest version.json..." -ForegroundColor Yellow
function Get-NormalizedFileHash([System.IO.FileInfo]$fi) {
    if ($fi.Extension -in '.ico','.exe','.dll','.zip') {
        return (Get-FileHash -LiteralPath $fi.FullName -Algorithm SHA256).Hash
    }
    $txt = [System.IO.File]::ReadAllText($fi.FullName, [System.Text.Encoding]::UTF8).TrimStart([char]0xFEFF)
    $cleanTxt = $txt -replace "`r`n", "`n"
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($cleanTxt)
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try { ([BitConverter]::ToString($sha.ComputeHash($bytes))).Replace('-','') } finally { $sha.Dispose() }
}

$coreFiles = Get-ChildItem -LiteralPath (Join-Path $root 'core') -File | Where-Object {
    $_.Extension -in '.ps1','.ico','.txt','.json','.zip' -and $_.Name -notin @('run.log')
} | ForEach-Object {
    [ordered]@{
        path   = "core/$($_.Name)"
        sha256 = (Get-NormalizedFileHash $_)
        size   = $_.Length
    }
}
$coreFiles = @($coreFiles) + @([ordered]@{
    path = 'Kid-FB.Y.exe'
    sha256 = (Get-FileHash -LiteralPath (Join-Path $root 'Kid-FB.Y.exe') -Algorithm SHA256).Hash
    size = (Get-Item -LiteralPath (Join-Path $root 'Kid-FB.Y.exe')).Length
})

$man = [ordered]@{
    version     = $Version
    releasedAt  = (Get-Date).ToString('yyyy-MM-dd HH:mm')
    # updater.ps1 tu choi cap nhat tu dong neu Kid-FB.Y.exe hien tai thap hon minLauncher.
    minLauncher = '1.0.0'
    mandatory   = [bool]$Mandatory
    changelog   = @($Note)
    files       = @($coreFiles)
}
# LF-only, khong BOM: git (text=auto) khong doi byte, nen chu ky van dung tren ban raw.githubusercontent.
$manJson = (($man | ConvertTo-Json -Depth 5) -replace "`r`n", "`n")
$manPath = Join-Path $root 'version.json'
[System.IO.File]::WriteAllText($manPath, $manJson, (New-Object System.Text.UTF8Encoding($false)))
Write-Host "    -> Da tao version.json ($(@($coreFiles).Count) file)" -ForegroundColor Green

# Ky DUNG byte cua version.json -> version.json.sig (Base64, RSA-SHA256, PKCS#1 v1.5)
Write-Host "[5b/6] Dang ky manifest..." -ForegroundColor Yellow
$rsa = New-Object System.Security.Cryptography.RSACryptoServiceProvider
try {
    $rsa.PersistKeyInCsp = $false
    $rsa.FromXmlString([System.IO.File]::ReadAllText($signingFull))
    if ($rsa.PublicOnly) { throw 'File khoa khong chua khoa rieng.' }
    $manBytes = [System.IO.File]::ReadAllBytes($manPath)
    $sigBytes = $rsa.SignData($manBytes, 'SHA256')
    $pubXml = $rsa.ToXmlString($false)
    if (-not $rsa.VerifyData($manBytes, 'SHA256', $sigBytes)) { throw 'Tu kiem chu ky that bai.' }
} finally { $rsa.Dispose() }
$sigPath = Join-Path $root 'version.json.sig'
[System.IO.File]::WriteAllText($sigPath, [Convert]::ToBase64String($sigBytes), (New-Object System.Text.ASCIIEncoding))
Write-Host "    -> Da tao version.json.sig" -ForegroundColor Green

# Khoa cong khai nhung trong updater.ps1 phai khop khoa ky, neu khong khach se tu choi moi ban cap nhat.
$updaterText = [System.IO.File]::ReadAllText((Join-Path $root 'core\updater.ps1'))
if ($updaterText -match 'PUBLIC_KEY_PLACEHOLDER') {
    throw 'core\updater.ps1 van la placeholder khoa ky: ban phat hanh se lam khach mat tu cap nhat. Chay .\new-signing-key.ps1, dan chuoi khoa cong khai vao $UpdatePublicKeyXml trong core\updater.ps1, roi phat hanh lai (ke ca -NoPush).'
} else {
    $modulusOf = { param($t) if ($t -match '<Modulus>([^<]+)</Modulus>') { $matches[1] } else { '' } }
    if ((& $modulusOf $updaterText) -ne (& $modulusOf $pubXml)) {
        throw 'Khoa cong khai trong core\updater.ps1 KHONG khop khoa ky dang dung. Dung phat hanh.'
    }
}

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
    Write-Host "    git add -A   (gom ca version.json va version.json.sig)" -ForegroundColor Cyan
    Write-Host "    git commit -m `"Phat hanh ban v$Version`"" -ForegroundColor Cyan
    Write-Host "    git push -u origin main`n" -ForegroundColor Cyan
    return
}

& git add -- version.json version.json.sig
if ($LASTEXITCODE -ne 0) { throw 'git add version.json/version.json.sig that bai. Chua phat hanh.' }
& git add -A
if ($LASTEXITCODE -ne 0) { throw 'git add that bai. Chua phat hanh.' }
$commitMsg = if ($Note -and $Note.Count -gt 0) { "v$Version - $($Note -join '; ')" } else { "Release v$Version" }
& git commit -m $commitMsg
if ($LASTEXITCODE -ne 0) { throw 'git commit that bai. Chua push.' }
& git tag "v$Version"
if ($LASTEXITCODE -ne 0) { throw 'Khong tao duoc tag (co the da ton tai). Chua push.' }
& git push -u origin main
if ($LASTEXITCODE -ne 0) { throw 'Push branch that bai. Kiem tra Git truoc khi phat hanh lai.' }
& git push origin "v$Version"
if ($LASTEXITCODE -ne 0) { throw 'Push tag that bai. Branch da push; can kiem tra va push tag lai.' }

Write-Host "`n[THANH CONG] Da phat hanh ban v$Version len GitHub!" -ForegroundColor Green
Write-Host "May khach chi can mo tool hoac bam nut 'Cap nhat' la se tu dong nhan ban moi!" -ForegroundColor Green
