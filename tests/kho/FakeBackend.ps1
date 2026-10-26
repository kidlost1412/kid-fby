# Fake TikTok backend on 127.0.0.1 (random port) for the worker tests: /health, /api/history/lookup, /api/desktop/jobs/<id>.
# Never talks to the real backend. Dot-source it after _load.ps1.
$khoFakeBackendCode = @'
using System;
using System.Collections.Concurrent;
using System.IO;
using System.Net;
using System.Text;
using System.Text.RegularExpressions;
using System.Threading;

public class KhoFakeBackend
{
    HttpListener listener;
    Thread thread;
    public ConcurrentDictionary<string, string> Rows = new ConcurrentDictionary<string, string>();   // reel_id -> JSON array of history entries
    public ConcurrentDictionary<string, string> Jobs = new ConcurrentDictionary<string, string>();   // request_id -> job JSON
    public int LookupCalls, JobCalls, HealthCalls;
    public string MoveOnLookupFrom, MoveOnLookupTo;   // test hook: this file is renamed while a lookup request is served (deterministic interleaving)
    public string Url;

    public KhoFakeBackend(int port)
    {
        Url = "http://127.0.0.1:" + port;
        listener = new HttpListener();
        listener.Prefixes.Add(Url + "/");
        listener.Start();
        thread = new Thread(Loop);
        thread.IsBackground = true;
        thread.Start();
    }

    void Loop()
    {
        while (listener.IsListening)
        {
            HttpListenerContext c;
            try { c = listener.GetContext(); } catch (Exception) { return; }
            try { Handle(c); }
            catch (Exception e) { try { Respond(c, 500, "{\"detail\":\"" + e.Message.Replace("\"", "'") + "\"}"); } catch (Exception) { } }
        }
    }

    void Handle(HttpListenerContext c)
    {
        string path = c.Request.Url.AbsolutePath;
        if (path == "/health") { Interlocked.Increment(ref HealthCalls); Respond(c, 200, "{\"status\":\"ok\",\"history_version\":2,\"native_schedule\":true}"); return; }
        if (path == "/api/history/lookup")
        {
            Interlocked.Increment(ref LookupCalls);
            if (MoveOnLookupFrom != null && File.Exists(MoveOnLookupFrom)) { File.Move(MoveOnLookupFrom, MoveOnLookupTo); }
            string body;
            using (var r = new StreamReader(c.Request.InputStream, Encoding.UTF8)) body = r.ReadToEnd();
            var sb = new StringBuilder("[");
            bool first = true;
            foreach (Match m in Regex.Matches(body, "\"reel_id\"\\s*:\\s*\"(\\d+)\""))
            {
                string id = m.Groups[1].Value, entries;
                if (!Rows.TryGetValue(id, out entries)) entries = "[]";
                if (!first) sb.Append(',');
                first = false;
                sb.Append("{\"reel_id\":\"").Append(id).Append("\",\"entries\":").Append(entries).Append('}');
            }
            sb.Append(']');
            Respond(c, 200, sb.ToString());
            return;
        }
        if (path.StartsWith("/api/desktop/jobs/"))
        {
            Interlocked.Increment(ref JobCalls);
            string job;
            if (Jobs.TryGetValue(path.Substring("/api/desktop/jobs/".Length), out job)) Respond(c, 200, job); else Respond(c, 404, "{}");
            return;
        }
        Respond(c, 404, "{}");
    }

    void Respond(HttpListenerContext c, int code, string text)
    {
        byte[] b = Encoding.UTF8.GetBytes(text);
        c.Response.StatusCode = code;
        c.Response.ContentType = "application/json";
        c.Response.ContentLength64 = b.Length;
        c.Response.OutputStream.Write(b, 0, b.Length);
        c.Response.Close();
    }

    public void Stop() { try { listener.Stop(); } catch (Exception) { } }
}
'@
if (-not ('KhoFakeBackend' -as [type])) { Add-Type -TypeDefinition $khoFakeBackendCode -Language CSharp }

function Start-FakeBackend {
    for ($try = 0; $try -lt 20; $try++) {
        try { return [KhoFakeBackend]::new((Get-Random -Minimum 20000 -Maximum 60000)) } catch { Start-Sleep -Milliseconds 50 }
    }
    throw 'could not open a local port for the fake backend'
}

function ConvertTo-EntriesJson { param($Entries) return (ConvertTo-Json -InputObject @($Entries) -Compress -Depth 6) }

function Invoke-Worker {
    # Runs the real worker script block the way the app does: a new runspace whose session state only has $script:tikTokWorkerFunctions.
    param([string]$Action, $Payload, [string]$BaseUrl)
    $state = [Management.Automation.Runspaces.InitialSessionState]::CreateDefault()
    foreach ($name in $script:tikTokWorkerFunctions) {
        $state.Commands.Add([Management.Automation.Runspaces.SessionStateFunctionEntry]::new($name, (Get-Item -LiteralPath "function:$name").ScriptBlock.ToString()))
    }
    $ps = [PowerShell]::Create($state)
    $cts = [Threading.CancellationTokenSource]::new()
    try {
        [void]$ps.AddScript($script:WorkerBlock.ToString()).AddArgument($Action).AddArgument($BaseUrl).AddArgument('').AddArgument($Payload).AddArgument('').AddArgument('').AddArgument($cts.Token)
        $clock = [Diagnostics.Stopwatch]::StartNew()
        $result = @($ps.Invoke())
        $clock.Stop()
        $errors = @($ps.Streams.Error | ForEach-Object { $_.ToString() })
        if ($ps.HadErrors -and -not $errors.Count) { $errors = @('pipeline reported errors') }
        return [pscustomobject]@{ Result = $(if ($result.Count) { $result[0] } else { $null }); Errors = $errors; Ms = $clock.Elapsed.TotalMilliseconds }
    } finally { $ps.Dispose(); $cts.Dispose() }
}
