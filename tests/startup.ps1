#Requires -Version 5.1
param([string]$Root = (Split-Path $PSScriptRoot -Parent))
$ErrorActionPreference = 'Stop'
$Root = [IO.Path]::GetFullPath($Root)
$testRoot = Join-Path ([IO.Path]::GetTempPath()) ('kid-fby-startup-' + [Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $testRoot | Out-Null

function Assert-True([bool]$Condition, [string]$Message) {
    if (-not $Condition) { throw $Message }
}

function New-TestCase([string]$Name) {
    $dir = Join-Path $testRoot $Name
    $core = Join-Path $dir 'core'
    New-Item -ItemType Directory -Path $core -Force | Out-Null
    Copy-Item -LiteralPath (Join-Path $Root 'Kid-FB.Y.exe') -Destination $dir
    foreach ($name in @('version.txt', 'updater.ps1', 'update.json')) {
        Copy-Item -LiteralPath (Join-Path $Root "core\$name") -Destination $core
    }
    return $dir
}

function Invoke-LauncherTest([string]$Dir) {
    $psi = New-Object Diagnostics.ProcessStartInfo
    $psi.FileName = Join-Path $Dir 'Kid-FB.Y.exe'
    $psi.Arguments = '-SelfTest'
    $psi.WorkingDirectory = $Dir
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    $psi.WindowStyle = [Diagnostics.ProcessWindowStyle]::Hidden
    $p = [Diagnostics.Process]::Start($psi)
    try {
        if (-not $p.WaitForExit(30000)) {
            # Chi dung cay tien trinh cua ca kiem thu, khong dung tac vu khac.
            $kill = New-Object Diagnostics.ProcessStartInfo
            $kill.FileName = 'taskkill.exe'
            $kill.Arguments = '/F /T /PID ' + $p.Id
            $kill.UseShellExecute = $false
            $kill.CreateNoWindow = $true
            $kp = [Diagnostics.Process]::Start($kill)
            $kp.WaitForExit()
            $kp.Dispose()
            throw 'Launcher SelfTest vuot qua 30 giay.'
        }
        return $p.ExitCode
    } finally { $p.Dispose() }
}

try {
    $fresh = New-TestCase 'fresh'
    Assert-True ((Invoke-LauncherTest $fresh) -eq 0) 'Ban cai moi khong khoi tao duoc.'
    Assert-True (Test-Path -LiteralPath (Join-Path $fresh 'core\_update\BOOT_OK')) 'Thieu BOOT_OK.'
    Assert-True (-not (Test-Path -LiteralPath (Join-Path $fresh 'output'))) 'SelfTest khong duoc tao output gia.'
    foreach ($name in @('kid-fby-gui.ps1','kid-fby.ps1','whisper-language.ps1','facebook-links.ps1','fix-ket-noi.ps1','Kid-FB.Y.ico','kid-logo.zip')) {
        $expected = (Get-FileHash -LiteralPath (Join-Path $Root "core\$name")).Hash
        $actual = (Get-FileHash -LiteralPath (Join-Path $fresh "core\$name")).Hash
        Assert-True ($actual -eq $expected) "EXE nhung sai tai nguyen: $name"
    }
    Write-Host 'PASS: fresh install, all named UI controls, gallery/tool initialization, embedded resources'

    $stale = New-TestCase 'stale-update'
    $stage = Join-Path $stale 'core\_update\files\core'
    New-Item -ItemType Directory -Path $stage -Force | Out-Null
    [IO.File]::WriteAllText((Join-Path $stage 'version.txt'), '1.0.5')
    [IO.File]::WriteAllLines((Join-Path $stale 'core\_update\READY'), @('core\version.txt','core\version.txt'))
    Assert-True ((Invoke-LauncherTest $stale) -eq 0) 'Goi update cu lam khoi dong that bai.'
    $expectedVersion = [IO.File]::ReadAllText((Join-Path $Root 'core\version.txt'))
    Assert-True ([IO.File]::ReadAllText((Join-Path $stale 'core\version.txt')) -eq $expectedVersion) 'Launcher da ha phien ban.'
    Assert-True (-not (Test-Path -LiteralPath (Join-Path $stale 'core\_update\READY'))) 'READY cu chua bi vo hieu hoa.'
    Write-Host 'PASS: stale READY rejected without downgrade'

    $transaction = New-TestCase 'duplicate-files'
    $assembly = [Reflection.Assembly]::Load([IO.File]::ReadAllBytes((Join-Path $transaction 'Kid-FB.Y.exe')))
    $program = $assembly.GetType('KidFBY.Program')
    $flags = [Reflection.BindingFlags]'NonPublic,Static'
    $apply = $program.GetMethod('ApplyUpdate',$flags)
    $restore = $program.GetMethod('RestoreBackup',$flags)
    $updDir = Join-Path $transaction 'core\_update'
    $stageCore = Join-Path $updDir 'files\core'
    New-Item -ItemType Directory -Path $stageCore -Force | Out-Null
    [IO.File]::WriteAllText((Join-Path $transaction 'core\version.txt'), '1.0.7')
    [IO.File]::WriteAllText((Join-Path $stageCore 'version.txt'), '1.0.8')
    [IO.File]::WriteAllText((Join-Path $stageCore 'added.ps1'), '# new file')
    [IO.File]::WriteAllLines((Join-Path $updDir 'READY'), @('core\version.txt','core\version.txt','core\added.ps1'))
    $argsApply = [object[]]@([string]$transaction,[string]$updDir,$null)
    Assert-True ([bool]$apply.Invoke($null,$argsApply)) 'Update giao dich that bai.'
    $backup = [string]$argsApply[2]
    Assert-True ([IO.File]::ReadAllText((Join-Path $backup 'core\version.txt')) -eq '1.0.7') 'File trung lap lam hong backup.'
    [void]$restore.Invoke($null,[object[]]@([string]$transaction,[string]$backup))
    Assert-True ([IO.File]::ReadAllText((Join-Path $transaction 'core\version.txt')) -eq '1.0.7') 'Rollback khong khoi phuc version cu.'
    Assert-True (-not (Test-Path -LiteralPath (Join-Path $transaction 'core\added.ps1'))) 'Rollback khong xoa file moi.'
    Write-Host 'PASS: duplicate update entries preserve backup; rollback restores old files and removes additions'

    $broken = New-TestCase 'broken-startup'
    $gui = [IO.File]::ReadAllText((Join-Path $Root 'core\kid-fby-gui.ps1'))
    $good = '$ui.TxtOut.Text = Join-Path $root ''output''' + "`r`n" + 'if ($ui.TxtAppVersion)'
    $bad = '$ui.TxtOut.Text = Join-Path $root ''output''`r`nif ($ui.TxtAppVersion)'
    Assert-True ($gui.Contains($good)) 'Khong tim thay diem chen loi hoi quy.'
    [IO.File]::WriteAllText((Join-Path $broken 'core\kid-fby-gui.ps1'), $gui.Replace($good,$bad), (New-Object Text.UTF8Encoding($true)))
    Assert-True ((Invoke-LauncherTest $broken) -ne 0) 'SelfTest van bao thanh cong khi khoi tao loi.'
    Assert-True (-not (Test-Path -LiteralPath (Join-Path $broken 'core\_update\BOOT_OK'))) 'Khoi tao loi van ghi BOOT_OK.'
    Write-Host 'PASS: original startup regression fails SelfTest and propagates exit code'

    # Goi truc tiep GUI de kiem tra thu muc rong va mot kho video co du lieu.
    $gallery = New-TestCase 'gallery-paths'
    $outDir = Join-Path $gallery 'output'
    New-Item -ItemType Directory -Path $outDir | Out-Null
    [IO.File]::WriteAllBytes((Join-Path $outDir '123-3-hoan-chinh.mp4'), [byte[]]@(0))
    $marker = '    # Auto scan gallery va tools on launch'
    $extra = @'
    $ui.TxtOut.Text = ''
    Update-Gallery
    if ($ui.TxtGalleryCount.Text -ne '0 video') { throw 'Empty gallery count is stale.' }
    $ui.TxtOut.Text = Join-Path $root 'output'
'@
    Assert-True ($gui.Contains($marker)) 'Khong tim thay diem kiem tra gallery.'
    [IO.File]::WriteAllText((Join-Path $gallery 'core\kid-fby-gui.ps1'), $gui.Replace($marker,$extra + "`r`n" + $marker), (New-Object Text.UTF8Encoding($true)))
    Assert-True ((Invoke-LauncherTest $gallery) -eq 0) 'Gallery co du lieu hoac duong dan rong lam khoi tao loi.'
    Write-Host 'PASS: empty output path and gallery with one saved video'

    # Render WPF an; vo hieu hoa kiem tra ADB va mang de khong cham vao thiet bi.
    $render = New-TestCase 'render-window'
    $renderGui = $gui.Replace('param([switch]$SelfTest)', 'param([switch]$SelfTest)' + "`r`n" + '$SelfTest = $false')
    $renderGui = $renderGui.Replace('if ($ui.BtnCheck) {', 'if ($false) {')
    $renderGui = $renderGui.Replace("Start-UpdateJob 'check' " + '$true', "Write-Host 'Network check disabled in render test'")
    $renderCode = @'
    $win.ShowInTaskbar = $false
    $win.Opacity = 0
    $win.Add_ContentRendered({
        [IO.File]::WriteAllText((Join-Path $scriptDir '_update\RENDERED'), 'OK')
        $win.Close()
    })
    [void]$win.ShowDialog()
'@
    $renderGui = $renderGui.Replace('[void]$win.ShowDialog()', $renderCode)
    [IO.File]::WriteAllText((Join-Path $render 'core\kid-fby-gui.ps1'), $renderGui, (New-Object Text.UTF8Encoding($true)))
    Assert-True ((Invoke-LauncherTest $render) -eq 0) 'WPF render that bai.'
    Assert-True (Test-Path -LiteralPath (Join-Path $render 'core\_update\RENDERED')) 'WPF khong phat ContentRendered.'
    Assert-True (Test-Path -LiteralPath (Join-Path $render 'core\_update\BOOT_OK')) 'Render khong bao BOOT_OK.'
    Write-Host 'PASS: real WPF ContentRendered and BOOT_OK (hidden, no device/network actions)'
} finally {
    $resolved = [IO.Path]::GetFullPath($testRoot)
    $tempBase = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\') + '\'
    if ($resolved.StartsWith($tempBase,[StringComparison]::OrdinalIgnoreCase) -and (Split-Path $resolved -Leaf) -like 'kid-fby-startup-*') {
        Remove-Item -LiteralPath $resolved -Recurse -Force
    }
}
