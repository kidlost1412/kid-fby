#Requires -Version 5.1
param([string]$Root=(Split-Path $PSScriptRoot -Parent))
$ErrorActionPreference = 'Stop'
. (Join-Path $Root 'core\facebook-links.ps1')

function Assert-Links {
    param([string]$Name, [string]$InputText, [string[]]$Expected)
    $actual = @(Get-FacebookInputLinks -Text $InputText)
    if ($actual.Count -ne $Expected.Count) { throw "$Name expected $($Expected.Count) links, got $($actual.Count): $($actual -join ' | ')" }
    for ($i = 0; $i -lt $Expected.Count; $i++) {
        if ($actual[$i] -cne $Expected[$i]) { throw "$Name mismatch at $i. Expected '$($Expected[$i])', got '$($actual[$i])'." }
    }
    Write-Host "PASS $Name"
}

function Assert-Canonical {
    param([string]$Name, [string]$Url, [string]$VideoId, [string]$Expected)
    $actual = Get-FacebookCanonicalVideoUrl -Url $Url -VideoId $VideoId
    if ($actual -cne $Expected) { throw "$Name expected '$Expected', got '$actual'." }
    Write-Host "PASS $Name"
}

Assert-Links 'plain URL' 'Watch https://www.facebook.com/watch/?v=123.' @('https://www.facebook.com/watch/?v=123')
Assert-Links 'Unicode NBSP splitting' ('first' + [char]0x00A0 + 'https://facebook.com/reel/123 second') @('https://facebook.com/reel/123')
Assert-Links 'Markdown link' '[clip](https://www.facebook.com/reel/123)' @('https://www.facebook.com/reel/123')
Assert-Links 'quoted angle URL' '"<https://m.facebook.com/watch/?v=1&amp;x=2>"' @('https://m.facebook.com/watch/?v=1&x=2')
Assert-Links 'bare Facebook URL' 'www.facebook.com/reel/77 and facebook.com/watch/?v=8' @('https://www.facebook.com/reel/77','https://facebook.com/watch/?v=8')
Assert-Links 'query preservation and punctuation' 'https://www.facebook.com/watch/?v=123&foo=Bar%2Fb, https://facebook.com/watch/?v=4?x=1!' @('https://www.facebook.com/watch/?v=123&foo=Bar%2Fb','https://facebook.com/watch/?v=4?x=1')
Assert-Links 'duplicates and mixed links' "https://facebook.com/reel/1`n[again](https://facebook.com/reel/1) <https://fb.watch/abc/>" @('https://facebook.com/reel/1','https://fb.watch/abc/')
Assert-Links 'reject unrelated and unsafe URLs' 'https://evilfacebook.com/x https://facebook.com.evil.com/y https://evil.com/?next=facebook.com/reel/2 javascript://facebook.com/reel/3' @()
Assert-Links 'trusted Facebook subdomains' 'https://m.facebook.com/x https://business.facebook.com/a' @('https://m.facebook.com/x','https://business.facebook.com/a')
Assert-Links 'fb.watch' 'https://fb.watch/abc' @('https://fb.watch/abc')

Assert-Canonical 'share/r metadata ID' 'https://www.facebook.com/share/r/19bVLUNWK5/' '949206081560084' 'https://www.facebook.com/reel/949206081560084/'
Assert-Canonical 'share/v metadata ID' 'https://www.facebook.com/share/v/opaque/?mibextid=xx' '12345' 'https://www.facebook.com/watch/?v=12345'
Assert-Canonical 'reel metadata ID' 'https://m.facebook.com/reels/opaque?tracking=1' '67890' 'https://www.facebook.com/reel/67890/'
Assert-Canonical 'fb.watch metadata ID' 'https://fb.watch/opaque-token/' '987' 'https://www.facebook.com/watch/?v=987'
Assert-Canonical 'invalid ID leaves URL unchanged' 'https://www.facebook.com/share/r/token/' 'token' 'https://www.facebook.com/share/r/token/'
Assert-Canonical 'direct URL remains unchanged' 'https://www.facebook.com/watch/?v=123' '123' 'https://www.facebook.com/watch/?v=123'
Assert-Canonical 'untrusted host remains unchanged' 'https://facebook.com.evil.com/share/r/token' '123' 'https://facebook.com.evil.com/share/r/token'

$script:MockEffectiveUrl = ''
$script:MockCurlExitCode = 0
$script:MockCurlCalls = 0
function Get-Command {
    param([string]$Name, [System.Management.Automation.ActionPreference]$ErrorAction)
    if ($Name -eq 'curl.exe') { return [pscustomobject]@{ Source = 'mock-curl.exe' } }
}
function Invoke-Exe {
    param([string]$Exe, [string[]]$ExeArgs, [int]$TimeoutMs)
    $script:MockCurlCalls++
    if ($Exe -ne 'mock-curl.exe' -or $TimeoutMs -ne 20000 -or $ExeArgs -notcontains '--max-redirs' -or $ExeArgs -notcontains '5') { throw 'Resolver did not use the bounded curl invocation.' }
    return [pscustomobject]@{ Code = $script:MockCurlExitCode; Out = $script:MockEffectiveUrl; Err = '' }
}
function Assert-Resolved {
    param([string]$Name, [string]$Url, [string]$Expected, [int]$ExpectedCalls)
    $before = $script:MockCurlCalls
    $actual = Resolve-FacebookShareUrl -Url $Url
    if ($actual -cne $Expected) { throw "$Name expected '$Expected', got '$actual'." }
    if (($script:MockCurlCalls - $before) -ne $ExpectedCalls) { throw "$Name made an unexpected number of curl calls." }
    Write-Host "PASS $Name"
}
$script:MockEffectiveUrl = 'https://www.facebook.com/reel/949206081560084/'
Assert-Resolved 'share URL resolves to reported video ID' 'https://www.facebook.com/share/r/19bVLUNWK5/' 'https://www.facebook.com/reel/949206081560084/' 1
$script:MockEffectiveUrl = 'https://www.facebook.com/owner/videos/949206081560084/'
Assert-Resolved 'owner videos path resolves' 'https://www.facebook.com/share/v/token/' 'https://www.facebook.com/watch/?v=949206081560084' 1
$script:MockEffectiveUrl = 'https://www.facebook.com/login/?next=%2Freel%2F949206081560084%2F'
Assert-Resolved 'login redirect with nested ID stays unchanged' 'https://www.facebook.com/share/r/token/' 'https://www.facebook.com/share/r/token/' 1
$script:MockEffectiveUrl = 'https://www.facebook.com/checkpoint/?next=%2Fvideos%2F949206081560084%2F'
Assert-Resolved 'checkpoint redirect with nested ID stays unchanged' 'https://www.facebook.com/share/r/token/' 'https://www.facebook.com/share/r/token/' 1
$script:MockCurlExitCode = 22
Assert-Resolved 'private or failed share stays unchanged' 'https://www.facebook.com/share/r/private/' 'https://www.facebook.com/share/r/private/' 1
$script:MockCurlExitCode = 0
$script:MockEffectiveUrl = 'https://facebook.com.evil.com/reel/123/'
Assert-Resolved 'malicious redirect stays unchanged' 'https://www.facebook.com/share/r/token/' 'https://www.facebook.com/share/r/token/' 1
Assert-Resolved 'direct reel skips curl' 'https://www.facebook.com/reel/123/' 'https://www.facebook.com/reel/123/' 0
Write-Host 'PASS all Facebook link tests'
