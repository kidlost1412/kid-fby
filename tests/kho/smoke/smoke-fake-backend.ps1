# Local FAKE TikTok backend for the WPF smoke (never the real one). State file JSON: { "rows": { "<wire reel id>": [history entries] } }.
# Logs every accepted job creation to "<state>.creates" as: request_id|reel_id|scheduled_for|title (one line per job).
# A job whose caption contains FAILME is answered with HTTP 500 (a failed transfer). Quit with GET /quit.
param([int]$Port, [string]$State)
$l = [Net.HttpListener]::new()
$l.Prefixes.Add("http://127.0.0.1:$Port/")
$l.Start()
[IO.File]::WriteAllText($State + '.ready', 'ok')
$latin = [Text.Encoding]::GetEncoding(28591)
function Get-Field {
    param([string]$Raw, [string]$Name)
    $m = [regex]::Match($Raw, ('name="' + $Name + '"(?:\r\n[^\r\n]+)*\r\n\r\n(.*?)\r\n--'), [Text.RegularExpressions.RegexOptions]::Singleline)
    if (-not $m.Success) { return '' }
    return [Text.Encoding]::UTF8.GetString($latin.GetBytes($m.Groups[1].Value))
}
while ($l.IsListening) {
    $ctx = $l.GetContext()
    $req = $ctx.Request; $res = $ctx.Response
    $path = $req.Url.AbsolutePath
    $body = ''; $code = 200
    try {
        if ($path -eq '/quit') { $res.StatusCode = 200; $res.Close(); break }
        elseif ($path -eq '/health') { $body = '{"ok":true,"history_version":2,"native_schedule":true}' }
        elseif ($path -eq '/api/accounts') { $body = '[{"username":"anna","has_valid_session":true},{"username":"bob","has_valid_session":true}]' }
        elseif ($path -eq '/api/history/lookup') {
            $st = [IO.File]::ReadAllText($State) | ConvertFrom-Json
            $in = (New-Object IO.StreamReader($req.InputStream, [Text.Encoding]::UTF8)).ReadToEnd() | ConvertFrom-Json
            $rows = New-Object Collections.Generic.List[object]
            foreach ($v in @($in.videos)) {
                $e = $st.rows.PSObject.Properties[[string]$v.reel_id]
                $rows.Add([pscustomobject]@{ reel_id = [string]$v.reel_id; entries = @($(if ($e) { @($e.Value) } else { @() })) })
            }
            $body = $(if ($rows.Count) { '[' + ((@($rows | ForEach-Object { ConvertTo-Json -InputObject $_ -Depth 8 -Compress })) -join ',') + ']' } else { '[]' })
        } elseif ($path -eq '/api/desktop/jobs' -and $req.HttpMethod -eq 'POST') {
            $raw = (New-Object IO.StreamReader($req.InputStream, $latin)).ReadToEnd()
            $rid = Get-Field $raw 'request_id'; $title = Get-Field $raw 'title'
            if ($title -like '*FAILME*') { $code = 500; $body = '{"detail":"rejected by the fake backend"}' }
            else {
                Add-Content -LiteralPath ($State + '.creates') -Value ($rid + '|' + (Get-Field $raw 'reel_id') + '|' + (Get-Field $raw 'scheduled_for') + '|' + $title) -Encoding UTF8
                Start-Sleep -Milliseconds 400
                $body = '{"status":"pending","schedule_id":1,"request_id":"' + $rid + '"}'
            }
        } else { $code = 404; $body = '{}' }
    } catch { $code = 500; $body = '{"detail":"' + $_.Exception.Message.Replace('"', "'") + '"}' }
    $res.StatusCode = $code; $res.ContentType = 'application/json'
    $b = [Text.Encoding]::UTF8.GetBytes($body); $res.ContentLength64 = $b.Length
    $res.OutputStream.Write($b, 0, $b.Length); $res.Close()
}
$l.Stop()
