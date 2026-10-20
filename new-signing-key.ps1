#Requires -Version 5.1
<#
  Tao cap khoa RSA 3072-bit de ky manifest cap nhat (version.json -> version.json.sig).
    .\new-signing-key.ps1             (tao khoa; tu choi neu khoa rieng da ton tai)
    .\new-signing-key.ps1 -Force      (GHI DE khoa cu: moi ban da phat hanh se khong cap nhat duoc nua)
  Khoa rieng:    $env:USERPROFILE\.kidfby\update-signing-private.xml   (KHONG BAO GIO dua vao repo)
  Khoa cong khai: $env:USERPROFILE\.kidfby\update-signing-public.xml   (dan vao $UpdatePublicKeyXml trong core\updater.ps1)
#>
param(
    [string]$Dir = '',
    [switch]$Force
)
$ErrorActionPreference = 'Stop'
if (-not $Dir) { $Dir = Join-Path $env:USERPROFILE '.kidfby' }
$dirFull = [IO.Path]::GetFullPath($Dir)
$repoFull = [IO.Path]::GetFullPath($PSScriptRoot).TrimEnd('\') + '\'
if (($dirFull.TrimEnd('\') + '\').StartsWith($repoFull, [StringComparison]::OrdinalIgnoreCase)) {
    throw "Khong duoc luu khoa rieng trong repo ($dirFull). Chon thu muc ngoai repo."
}
$privPath = Join-Path $dirFull 'update-signing-private.xml'
$pubPath  = Join-Path $dirFull 'update-signing-public.xml'
if ((Test-Path -LiteralPath $privPath) -and -not $Force) {
    throw "Khoa rieng da ton tai: $privPath. Tu choi ghi de (dung -Force neu chac chan; ban da phat hanh se khong nhan cap nhat nua)."
}
[void][IO.Directory]::CreateDirectory($dirFull)

$rsa = New-Object System.Security.Cryptography.RSACryptoServiceProvider(3072)
try {
    $rsa.PersistKeyInCsp = $false
    $privXml = $rsa.ToXmlString($true)
    $pubXml  = $rsa.ToXmlString($false)
} finally { $rsa.Dispose() }

$utf8 = New-Object System.Text.UTF8Encoding($false)
[IO.File]::WriteAllText($privPath, $privXml, $utf8)
[IO.File]::WriteAllText($pubPath, $pubXml, $utf8)

# Han che quyen doc khoa rieng cho tai khoan hien tai (best effort, canh bao neu that bai).
try {
    $me = [Security.Principal.WindowsIdentity]::GetCurrent().Name
    & icacls.exe $privPath /inheritance:r /grant:r ($me + ':(F)') | Out-Null
    if ($LASTEXITCODE -ne 0) { Write-Warning "icacls tra ma $LASTEXITCODE; hay tu han che quyen file $privPath." }
} catch { Write-Warning "Khong han che duoc quyen file khoa rieng: $($_.Exception.Message)" }

Write-Host "Da tao khoa rieng : $privPath  (GIU BI MAT, SAO LUU NGOAI MAY, KHONG DUA VAO GIT)" -ForegroundColor Yellow
Write-Host "Da tao khoa cong khai: $pubPath" -ForegroundColor Green
Write-Host 'Dan chuoi XML duoi day vao $UpdatePublicKeyXml (dau nhay don) trong core\updater.ps1:' -ForegroundColor Cyan
Write-Output $pubXml
