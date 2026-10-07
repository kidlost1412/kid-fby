#Requires -Version 5.1
param([string]$Root=(Split-Path $PSScriptRoot -Parent))
$ErrorActionPreference='Stop'
$tokens=$null; $errors=$null
$ast=[Management.Automation.Language.Parser]::ParseFile((Join-Path $Root 'core/kid-fby.ps1'),[ref]$tokens,[ref]$errors)
if ($errors.Count) { throw 'Engine parse failed.' }
foreach ($name in @('Quote-Arg','Invoke-Exe','Expand-KidLogo','Get-MovingLogoMuxArgs','Get-VideoSize','Test-ValidReelOutput')) {
    $fn=$ast.FindAll({param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq $name},$true) | Select-Object -First 1
    if (-not $fn) { throw "Missing function: $name" }
    Invoke-Expression $fn.Extent.Text
}
function Assert([bool]$Condition,[string]$Message) { if (-not $Condition) { throw $Message } }
$script:Here=$Root
$tempBase=[IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\')+'\'
$work=Join-Path $tempBase ('kidfby-watermark-test-'+[Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $work | Out-Null
try {
    $logo=Expand-KidLogo $work
    $zip=[IO.Compression.ZipFile]::OpenRead((Join-Path $Root 'core/kid-logo.zip'))
    try { Assert ($zip.Entries.Count -eq 1 -and $zip.Entries[0].FullName -eq 'kid-logo.png') 'Logo archive must contain only the selected original PNG.' } finally { $zip.Dispose() }
    # SHA256 of the original fifth logo approved by the user (not a redesigned variant).
    Assert ((Get-FileHash $logo).Hash -eq 'C236D2FAC8D7C7AECF743BF2094D91F9D86A36741C7832DA9203251DE1706A2C') 'Packaged logo differs from original selection.'
    $culture=[Threading.Thread]::CurrentThread.CurrentCulture
    try {
        [Threading.Thread]::CurrentThread.CurrentCulture=[cultureinfo]'de-DE'
        $args60=Get-MovingLogoMuxArgs 'video with spaces.mp4' 'audio.m4a' $logo 'output.mp4' 320 568 60
        Assert (($args60 -join ' ') -match 'aa=0\.40') 'Alpha must use an invariant decimal separator.'
    } finally { [Threading.Thread]::CurrentThread.CurrentCulture=$culture }
    foreach($fade in @(50,70)) {
        $a=Get-MovingLogoMuxArgs 'v.mp4' 'a.m4a' $logo 'o.mp4' 320 568 $fade
        $expected=if($fade -eq 50){'aa=0.50'}else{'aa=0.30'}
        Assert (($a -join ' ').Contains($expected)) 'Fade control does not map to correct opacity.'
    }
    $rejected=$false
    try { $null=Get-MovingLogoMuxArgs 'v' 'a' $logo 'o' 320 568 90 } catch { $rejected=$true }
    Assert $rejected 'Unsupported fade was accepted.'
    $ffmpeg=(Get-Command ffmpeg -ErrorAction Stop).Source
    $probe=(Get-Command ffprobe -ErrorAction Stop).Source
    $tools=@{ffprobe=$probe}
    $source=Join-Path $work 'source with spaces.mp4'
    $output=Join-Path $work 'moving logo.mp4'
    $r=Invoke-Exe $ffmpeg @('-v','error','-y','-f','lavfi','-i','color=c=blue:s=320x568:r=10:d=6','-f','lavfi','-i','sine=frequency=440:duration=6','-c:v','libx264','-pix_fmt','yuv420p','-c:a','aac','-shortest',$source)
    Assert ($r.Code -eq 0) "Cannot generate watermark fixture: $($r.Err)"
    $sourceHash=(Get-FileHash $source).Hash
    $audio=Join-Path $work 'selected dubbed audio.m4a'
    $r=Invoke-Exe $ffmpeg @('-v','error','-y','-f','lavfi','-i','sine=frequency=880:duration=6','-c:a','aac',$audio)
    Assert ($r.Code -eq 0) 'Cannot generate separate selected audio.'
    $r=Invoke-Exe $ffmpeg (Get-MovingLogoMuxArgs $source $audio $logo $output 320 568 60) -TimeoutMs 60000
    Assert ($r.Code -eq 0) "Overlay encode failed: $($r.Err)"
    Assert (Test-ValidReelOutput $tools $output) 'Watermark output lacks valid video/audio.'
    $size=Get-VideoSize $tools $output
    Assert ($size.W -eq 320 -and $size.H -eq 568) 'Overlay changed video dimensions.'
    Assert ((Get-FileHash $source).Hash -eq $sourceHash) 'Overlay modified source video.'
    $hashes=@()
    foreach($file in @($audio,$output,$source)) {
        $r=Invoke-Exe $ffmpeg @('-v','error','-i',$file,'-map','0:a:0','-c:a','copy','-f','hash','-hash','sha256','-')
        Assert ($r.Code -eq 0) 'Could not hash copied audio.'
        $hashes+=$r.Out.Trim()
    }
    Assert ($hashes[0] -eq $hashes[1]) 'Overlay changed audio packets.'
    Assert ($hashes[1] -ne $hashes[2]) 'Overlay mapped source audio instead of the selected dubbed track.'
    Add-Type -AssemblyName System.Drawing
    $centers=@()
    foreach($time in @('0','4')) {
        $frame=Join-Path $work ('frame-'+$time+'.png')
        $r=Invoke-Exe $ffmpeg @('-v','error','-y','-ss',$time,'-i',$output,'-frames:v','1',$frame)
        Assert ($r.Code -eq 0) "Cannot extract overlay frame: $($r.Err)"
        $bitmap=[Drawing.Bitmap]::FromFile($frame)
        try {
            $background=$bitmap.GetPixel(0,0); $count=0; $sumX=0.0; $sumY=0.0
            $minX=320; $minY=568; $maxX=0; $maxY=0
            for($y=0;$y -lt 568;$y+=2){for($x=0;$x -lt 320;$x+=2){
                $p=$bitmap.GetPixel($x,$y)
                $difference=[Math]::Abs([int]$p.R-$background.R)+[Math]::Abs([int]$p.G-$background.G)+[Math]::Abs([int]$p.B-$background.B)
                if($difference -gt 45){$count++;$sumX+=$x;$sumY+=$y;$minX=[Math]::Min($minX,$x);$maxX=[Math]::Max($maxX,$x);$minY=[Math]::Min($minY,$y);$maxY=[Math]::Max($maxY,$y)}
            }}
            Assert ($count -gt 30) 'Logo not visible in encoded frame.'
            Assert ($minX -gt 0 -and $maxX -lt 319 -and $minY -gt 0 -and $maxY -lt 567) 'Logo clipped at frame edge.'
            $centers+=[pscustomobject]@{X=$sumX/$count;Y=$sumY/$count}
        } finally { $bitmap.Dispose() }
    }
    $distance=[Math]::Sqrt([Math]::Pow($centers[1].X-$centers[0].X,2)+[Math]::Pow($centers[1].Y-$centers[0].Y,2))
    Assert ($distance -gt 10) 'Encoded logo did not move between frames.'
    Write-Host 'PASS watermark: exact original PNG; fade 50/60/70%; locale; real encode; dimensions; unchanged source/audio; visible movement inside frame.'
} finally {
    $resolved=[IO.Path]::GetFullPath($work)
    if(-not $resolved.StartsWith($tempBase,[StringComparison]::OrdinalIgnoreCase) -or [IO.Path]::GetFileName($resolved) -notmatch '^kidfby-watermark-test-[0-9a-f]{32}$'){throw 'Unsafe test cleanup path.'}
    Remove-Item -LiteralPath $resolved -Recurse -Force
}
