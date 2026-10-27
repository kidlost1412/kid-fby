#Requires -Version 5.1
<#
  Kid FB.Y - WPF interface hosted by Windows PowerShell.
  Runtime flow and source map: BAN-GIAO.md. Run Kid-FB.Y.exe for the interface.
#>
param([switch]$SelfTest, [string]$TikTokJobFile='')

if($TikTokJobFile){
    # A separate OS process owns file transfer, so closing the GUI cannot cancel a submitted job.
    $ErrorActionPreference='Stop'
    if([IO.Path]::GetFileName($TikTokJobFile) -notmatch '^[a-f0-9]{32}\.job$' -or [IO.Path]::GetFileName([IO.Path]::GetDirectoryName($TikTokJobFile)) -ne 'tiktok-posts'){throw 'Invalid TikTok job file.'}
    # The lock is held for the whole process life; the OS releases it if the process dies, so the GUI can tell
    # a live transfer from a dead one. A second worker for the same request gives up instead of sending twice.
    $lockPath=[IO.Path]::ChangeExtension($TikTokJobFile,'.lock');$lock=$null
    for($attempt=0;$attempt -lt 20 -and -not $lock;$attempt++){
        try{$lock=[IO.FileStream]::new($lockPath,[IO.FileMode]::OpenOrCreate,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None,1,[IO.FileOptions]::DeleteOnClose)}
        catch [IO.IOException]{Start-Sleep -Milliseconds 100}
    }
    if(-not $lock){exit 3}
    $exitCode=0
    try{
        if(-not [IO.File]::Exists($TikTokJobFile)){return}
        $job=[IO.File]::ReadAllText($TikTokJobFile,[Text.Encoding]::UTF8) | ConvertFrom-Json
        $expected=Join-Path (Join-Path ([IO.Path]::GetDirectoryName([string]$job.Record.SourcePath)) '.cache\tiktok-posts') ($job.Record.RequestId+'.job')
        if([IO.Path]::GetFullPath($expected) -ne [IO.Path]::GetFullPath($TikTokJobFile) -or $job.Record.OutDir -ne [IO.Path]::GetDirectoryName([string]$job.Record.SourcePath)){throw 'TikTok job path mismatch.'}
        $tokens=$null;$errors=$null
        $ast=[Management.Automation.Language.Parser]::ParseFile($PSCommandPath,[ref]$tokens,[ref]$errors)
        if($errors.Count){throw 'TikTok worker source parse failed.'}
        foreach($node in $ast.FindAll({param($n)$n -is [Management.Automation.Language.FunctionDefinitionAst]},$true)){
            if($node.Name -in @('Get-TikTokEndpoint','Save-TikTokReceipt','Find-TikTokTool','ConvertTo-TikTokArgument','Invoke-TikTokTool','Get-TikTokCleanArgs','Get-TikTokCleanPlan','Get-TikTokVideoStreamIndex','Get-TikTokMediaInfo','Get-TikTokVideoCounts','Test-TikTokCleanFile','New-TikTokCleanCopy')){. ([scriptblock]::Create($node.Extent.Text))}
        }
        $assignment=@($ast.FindAll({param($n)$n -is [Management.Automation.Language.AssignmentStatementAst] -and $n.Left.Extent.Text -eq '$script:tikTokWorker'},$true))[0]
        . ([scriptblock]::Create($assignment.Extent.Text))
        $env:KID_FBY_TIKTOK_URL=[string]$job.Endpoint
        $postsDir=[IO.Path]::GetDirectoryName($TikTokJobFile)
        $appDir=Split-Path $PSCommandPath -Parent
        $appRoot=if((Split-Path $appDir -Leaf) -in @('core','src','app')){Split-Path $appDir -Parent}else{$appDir}
        # Leftovers of an earlier worker for this request (it died; we hold the lock now).
        foreach($leftover in @('.clean.mp4','.clean-tmp.mp4')){$path=Join-Path $postsDir ($job.Record.RequestId+$leftover);if([IO.File]::Exists($path)){[IO.File]::Delete($path)}}
        $sha={param($Path) $h=[Security.Cryptography.SHA256]::Create();$s=[IO.File]::OpenRead($Path);try{[BitConverter]::ToString($h.ComputeHash($s)).Replace('-','').ToLowerInvariant()}finally{$s.Dispose();$h.Dispose()}}
        # Owner rule: only a metadata-clean copy is ever uploaded. If it cannot be made, nothing is sent and the .job stays for retry.
        $clean=''
        try{$clean=New-TikTokCleanCopy -SourcePath ([string]$job.Record.SourcePath) -PostsDir $postsDir -RequestId ([string]$job.Record.RequestId) -Root $appRoot}
        catch{
            $job.Record.Status='transfer_failed';$job.Record.Message='Không làm sạch được thông tin video (metadata). Chưa gửi lên TikTok. '+$_.Exception.Message
            Save-TikTokReceipt $job.Record
            exit 1
        }
        # History matching keeps using the ORIGINAL -3 identity; the backend hashes the uploaded (clean) bytes.
        $job.Record | Add-Member -NotePropertyName SourceSha256 -NotePropertyValue (& $sha ([string]$job.Record.SourcePath)) -Force
        $job.Record | Add-Member -NotePropertyName UploadSha256 -NotePropertyValue (& $sha $clean) -Force
        $job.Payload | Add-Member -NotePropertyName source_sha256 -NotePropertyValue $job.Record.SourceSha256 -Force
        # kid-install.ps1 is switching backend releases (upgrade lock held): wait up to 10 minutes before sending.
        $upgradeLock=Join-Path $appRoot 'integrations\autotok-upgrade.lock';$waitUntil=[DateTime]::UtcNow.AddMinutes(10)
        while([IO.File]::Exists($upgradeLock) -and [DateTime]::UtcNow -lt $waitUntil){
            try{[IO.File]::Open($upgradeLock,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::ReadWrite).Dispose();break}
            catch [IO.FileNotFoundException]{break}
            catch{Start-Sleep -Seconds 2}
        }
        try{
            $result=& $script:tikTokWorker 'create' (Get-TikTokEndpoint) $clean ($job.Payload | ConvertTo-Json -Depth 6 -Compress) ([string]$job.Record.RequestId) ''
            $response=$result | ConvertFrom-Json
            # The backend answers with the receipt state (also for a replayed request_id); record it as-is.
            $status=[string]$response.status
            if(-not $status){$status=$(if($response.schedule_id){'pending'}else{'unknown'})}
            $job.Record.Status=$status
            $job.Record.Message=$(if($status -eq 'preparation_failed'){'Bộ đăng nền báo chuẩn bị video thất bại.'}else{'Bộ đăng nền đã nhận tác vụ.'})
            Save-TikTokReceipt $job.Record
            if($response.schedule_id -or $status -in @('succeeded','failed','cancelled','preparation_failed','missing')){[IO.File]::Delete($TikTokJobFile)}
        }catch{
            $job.Record.Status='transfer_failed';$job.Record.Message='Chưa xác nhận được việc chuyển tệp. Kiểm tra lịch sử trước khi thử lại. '+$_.Exception.Message
            Save-TikTokReceipt $job.Record
            $exitCode=1
        }finally{
            try{if([IO.File]::Exists($clean)){[IO.File]::Delete($clean)}}catch{<# removed later by Remove-TikTokStaleCleanFiles #>}
        }
    }finally{$lock.Dispose()}
    exit $exitCode
}

# SelfTest phai that bai ngay khi co loi khoi tao, khong bao BOOT_OK gia.
if ($SelfTest) { $ErrorActionPreference = 'Stop' }

# Configure the actual GUI host before WPF creates a window; the launcher is a separate process.
try {
    [AppContext]::SetSwitch('Switch.System.Windows.DoNotScaleForDpiChanges', $false)
    [AppContext]::SetSwitch('Switch.System.Windows.DoNotUsePresentationDpiCapabilityTier2OrGreater', $false)
} catch { <# bo qua: AppContext switch khong co tren ban .NET nay #> }
if (-not ([System.Management.Automation.PSTypeName]'KidDisplaySupport').Type) {
    Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class KidDisplaySupport {
    [StructLayout(LayoutKind.Sequential)] struct Point { public int X, Y; }
    [StructLayout(LayoutKind.Sequential)] struct Rect { public int Left, Top, Right, Bottom; }
    [StructLayout(LayoutKind.Sequential)] struct MonitorInfo { public int Size; public Rect Monitor, Work; public uint Flags; }
    [DllImport("user32.dll")] static extern bool SetProcessDpiAwarenessContext(IntPtr context);
    [DllImport("user32.dll")] static extern IntPtr SetThreadDpiAwarenessContext(IntPtr context);
    [DllImport("user32.dll")] static extern IntPtr GetThreadDpiAwarenessContext();
    [DllImport("user32.dll")] static extern int GetAwarenessFromDpiAwarenessContext(IntPtr context);
    [DllImport("user32.dll")] static extern uint GetDpiForWindow(IntPtr hwnd);
    [DllImport("user32.dll")] static extern bool GetCursorPos(out Point point);
    [DllImport("user32.dll")] static extern IntPtr MonitorFromPoint(Point point, uint flags);
    [DllImport("user32.dll")] static extern IntPtr MonitorFromWindow(IntPtr hwnd, uint flags);
    [DllImport("user32.dll", CharSet=CharSet.Auto)] static extern bool GetMonitorInfo(IntPtr monitor, ref MonitorInfo info);
    [DllImport("user32.dll")] static extern bool GetWindowRect(IntPtr hwnd, out Rect rect);
    [DllImport("user32.dll")] static extern bool SetWindowPos(IntPtr hwnd, IntPtr after, int x, int y, int w, int h, uint flags);
    public static int EnableDpi() {
        try {
            if (!SetProcessDpiAwarenessContext(new IntPtr(-4))) SetThreadDpiAwarenessContext(new IntPtr(-4));
            return GetAwarenessFromDpiAwarenessContext(GetThreadDpiAwarenessContext());
        } catch (EntryPointNotFoundException) { return -1; }
    }
    public static double Dpi(IntPtr hwnd) {
        try { uint dpi=GetDpiForWindow(hwnd); return dpi > 0 ? dpi : 96.0; }
        catch (EntryPointNotFoundException) { return 96.0; }
    }
    public static int[] WorkArea(IntPtr hwnd, bool atCursor) {
        Point point; IntPtr monitor;
        if (atCursor && GetCursorPos(out point)) monitor=MonitorFromPoint(point,2);
        else monitor=MonitorFromWindow(hwnd,2);
        var info=new MonitorInfo(); info.Size=Marshal.SizeOf(typeof(MonitorInfo));
        if (!GetMonitorInfo(monitor,ref info)) throw new InvalidOperationException("Khong doc duoc vung lam viec man hinh.");
        return new int[]{info.Work.Left,info.Work.Top,info.Work.Right-info.Work.Left,info.Work.Bottom-info.Work.Top};
    }
    public static void Fit(IntPtr hwnd, bool initial) {
        Rect rect; if (!GetWindowRect(hwnd,out rect)) return;
        int[] work=WorkArea(hwnd,initial);
        int width=Math.Min(rect.Right-rect.Left,work[2]),height=Math.Min(rect.Bottom-rect.Top,work[3]);
        int x=initial ? work[0]+(work[2]-width)/2 : Math.Max(work[0],Math.Min(rect.Left,work[0]+work[2]-width));
        int y=initial ? work[1]+(work[3]-height)/2 : Math.Max(work[1],Math.Min(rect.Top,work[1]+work[3]-height));
        if(x!=rect.Left || y!=rect.Top || width!=rect.Right-rect.Left || height!=rect.Bottom-rect.Top)
            SetWindowPos(hwnd,IntPtr.Zero,x,y,width,height,0x0014);
    }
}
'@
}
$script:displayDpiAwareness = [KidDisplaySupport]::EnableDpi()
Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase, System.Windows.Forms, System.Drawing, System.Xaml

# Luoi the ao hoa cho trang Kho (o co dinh, so cot theo be rong, cuon theo pixel).
if (-not ([System.Management.Automation.PSTypeName]'KidWrapPanel').Type) {
    Add-Type -TypeDefinition @'
using System;
using System.Collections.Specialized;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Controls.Primitives;
using System.Windows.Media;

// Luoi the ao hoa cho Kho: o co dinh ItemWidth x ItemHeight, so cot theo be rong, chi tao the dang hien (cuon theo pixel).
public class KidWrapPanel : VirtualizingPanel, IScrollInfo
{
    public static readonly DependencyProperty ItemWidthProperty = DependencyProperty.Register("ItemWidth", typeof(double), typeof(KidWrapPanel),
        new FrameworkPropertyMetadata(200.0, FrameworkPropertyMetadataOptions.AffectsMeasure | FrameworkPropertyMetadataOptions.AffectsArrange));
    public static readonly DependencyProperty ItemHeightProperty = DependencyProperty.Register("ItemHeight", typeof(double), typeof(KidWrapPanel),
        new FrameworkPropertyMetadata(300.0, FrameworkPropertyMetadataOptions.AffectsMeasure | FrameworkPropertyMetadataOptions.AffectsArrange));
    public double ItemWidth { get { return (double)GetValue(ItemWidthProperty); } set { SetValue(ItemWidthProperty, value); } }
    public double ItemHeight { get { return (double)GetValue(ItemHeightProperty); } set { SetValue(ItemHeightProperty, value); } }

    private Size _extent = new Size(0, 0);
    private Size _viewport = new Size(0, 0);
    private Point _offset = new Point(0, 0);
    private int _perRow = 1;
    private double _leftPad = 0;
    private ScrollViewer _owner;
    private bool _canVScroll = true;
    private bool _canHScroll = false;

    private int ItemCount
    {
        get { ItemsControl ic = ItemsControl.GetItemsOwner(this); return ic == null ? 0 : ic.Items.Count; }
    }

    public int Columns { get { return _perRow; } }

    private void UpdateMetrics(Size avail)
    {
        double w = double.IsInfinity(avail.Width) ? ItemWidth : avail.Width;
        double iw = Math.Max(1.0, ItemWidth), ih = Math.Max(1.0, ItemHeight);
        _perRow = Math.Max(1, (int)Math.Floor(w / iw));
        int rows = (int)Math.Ceiling(ItemCount / (double)_perRow);
        _leftPad = Math.Max(0.0, (w - _perRow * iw) / 2.0);
        Size extent = new Size(w, rows * ih);
        double vh = double.IsInfinity(avail.Height) ? extent.Height : avail.Height;
        Size viewport = new Size(w, vh);
        bool changed = (extent != _extent) || (viewport != _viewport);
        _extent = extent; _viewport = viewport;
        double maxOff = Math.Max(0.0, _extent.Height - _viewport.Height);
        if (_offset.Y > maxOff) { _offset.Y = maxOff; changed = true; }
        if (_offset.Y < 0) { _offset.Y = 0; changed = true; }
        if (changed && _owner != null) _owner.InvalidateScrollInfo();
    }

    private void VisibleRange(out int first, out int last)
    {
        int count = ItemCount;
        double ih = Math.Max(1.0, ItemHeight);
        int firstRow = (int)Math.Floor(_offset.Y / ih);
        int lastRow = (int)Math.Ceiling((_offset.Y + _viewport.Height) / ih);
        first = Math.Max(0, firstRow * _perRow);
        last = Math.Min(count - 1, (lastRow + 1) * _perRow - 1);   // them 1 hang dem
    }

    protected override Size MeasureOverride(Size availableSize)
    {
        UIElementCollection ensureGenerator = InternalChildren;   // tao ItemContainerGenerator truoc khi dung
        if (ItemContainerGenerator == null) return new Size(0, 0);
        UpdateMetrics(availableSize);
        int count = ItemCount;
        if (count == 0) { RemoveAllChildren(); return new Size(_viewport.Width, double.IsInfinity(availableSize.Height) ? 0 : availableSize.Height); }
        int first, last; VisibleRange(out first, out last);
        IItemContainerGenerator gen = ItemContainerGenerator;
        GeneratorPosition start = gen.GeneratorPositionFromIndex(first);
        int childIndex = (start.Offset == 0) ? start.Index : start.Index + 1;
        using (gen.StartAt(start, GeneratorDirection.Forward, true))
        {
            for (int i = first; i <= last; i++, childIndex++)
            {
                bool isNew;
                UIElement child = gen.GenerateNext(out isNew) as UIElement;
                if (child == null) continue;
                if (isNew)
                {
                    if (childIndex >= InternalChildren.Count) AddInternalChild(child); else InsertInternalChild(childIndex, child);
                    gen.PrepareItemContainer(child);
                }
                child.Measure(new Size(ItemWidth, ItemHeight));
            }
        }
        CleanUp(first, last);
        double h = double.IsInfinity(availableSize.Height) ? _extent.Height : availableSize.Height;
        return new Size(_viewport.Width, h);
    }

    protected override Size ArrangeOverride(Size finalSize)
    {
        IItemContainerGenerator gen = ItemContainerGenerator;
        if (gen == null) return finalSize;
        for (int i = 0; i < InternalChildren.Count; i++)
        {
            int idx = gen.IndexFromGeneratorPosition(new GeneratorPosition(i, 0));
            if (idx < 0) continue;
            int row = idx / _perRow, col = idx % _perRow;
            InternalChildren[i].Arrange(new Rect(_leftPad + col * ItemWidth, row * ItemHeight - _offset.Y, ItemWidth, ItemHeight));
        }
        return finalSize;
    }

    private void CleanUp(int first, int last)
    {
        IItemContainerGenerator gen = ItemContainerGenerator;
        for (int i = InternalChildren.Count - 1; i >= 0; i--)
        {
            GeneratorPosition pos = new GeneratorPosition(i, 0);
            int idx = gen.IndexFromGeneratorPosition(pos);
            if (idx < first || idx > last) { gen.Remove(pos, 1); RemoveInternalChildRange(i, 1); }
        }
    }

    private void RemoveAllChildren()
    {
        if (InternalChildren.Count == 0) return;
        ItemContainerGenerator.RemoveAll();
        RemoveInternalChildRange(0, InternalChildren.Count);   // Clear() throws while the ItemsControl owns the panel
    }

    protected override void OnItemsChanged(object sender, ItemsChangedEventArgs args)
    {
        switch (args.Action)
        {
            case NotifyCollectionChangedAction.Remove:
            case NotifyCollectionChangedAction.Replace:
            case NotifyCollectionChangedAction.Move:
                // A move between khos removes, replaces and inserts several cards in one sync; patching InternalChildren by position then
                // leaves a stale child and CleanUp throws a NullReferenceException inside ItemContainerGenerator.Remove (crash log, Dispatcher).
                // Dropping every realized container is cheap (only the visible cards are generated again) and always consistent.
                RemoveAllChildren();
                break;
            case NotifyCollectionChangedAction.Reset:
                _offset.Y = 0;
                break;
        }
        InvalidateMeasure();
    }

    protected override void BringIndexIntoView(int index)
    {
        if (index < 0 || index >= ItemCount) return;
        double top = (index / _perRow) * ItemHeight;
        double bottom = top + ItemHeight;
        if (top < _offset.Y) SetVerticalOffset(top);
        else if (bottom > _offset.Y + _viewport.Height) SetVerticalOffset(bottom - _viewport.Height);
    }

    // ---- IScrollInfo (cuon theo pixel) ----
    public bool CanVerticallyScroll { get { return _canVScroll; } set { _canVScroll = value; } }
    public bool CanHorizontallyScroll { get { return _canHScroll; } set { _canHScroll = value; } }
    public double ExtentWidth { get { return _extent.Width; } }
    public double ExtentHeight { get { return _extent.Height; } }
    public double ViewportWidth { get { return _viewport.Width; } }
    public double ViewportHeight { get { return _viewport.Height; } }
    public double HorizontalOffset { get { return 0; } }
    public double VerticalOffset { get { return _offset.Y; } }
    public ScrollViewer ScrollOwner { get { return _owner; } set { _owner = value; } }
    public void LineUp() { SetVerticalOffset(_offset.Y - 48); }
    public void LineDown() { SetVerticalOffset(_offset.Y + 48); }
    public void LineLeft() { }
    public void LineRight() { }
    public void PageUp() { SetVerticalOffset(_offset.Y - _viewport.Height); }
    public void PageDown() { SetVerticalOffset(_offset.Y + _viewport.Height); }
    public void PageLeft() { }
    public void PageRight() { }
    public void MouseWheelUp() { SetVerticalOffset(_offset.Y - 96); }
    public void MouseWheelDown() { SetVerticalOffset(_offset.Y + 96); }
    public void MouseWheelLeft() { }
    public void MouseWheelRight() { }
    public void SetHorizontalOffset(double offset) { }
    public void SetVerticalOffset(double offset)
    {
        double maxOff = Math.Max(0.0, _extent.Height - _viewport.Height);
        if (offset < 0) offset = 0;
        if (offset > maxOff) offset = maxOff;
        if (Math.Abs(offset - _offset.Y) < 0.5) return;
        _offset.Y = offset;
        if (_owner != null) _owner.InvalidateScrollInfo();
        InvalidateMeasure();
    }
    public Rect MakeVisible(Visual visual, Rect rectangle)
    {
        for (int i = 0; i < InternalChildren.Count; i++)
        {
            DependencyObject child = InternalChildren[i];
            DependencyObject v = visual as DependencyObject;
            while (v != null && v != child) v = VisualTreeHelper.GetParent(v);
            if (v == child)
            {
                int idx = ItemContainerGenerator.IndexFromGeneratorPosition(new GeneratorPosition(i, 0));
                BringIndexIntoView(idx);
                break;
            }
        }
        return rectangle;
    }
}
'@ -ReferencedAssemblies @('PresentationFramework', 'PresentationCore', 'WindowsBase', 'System.Xaml')
}

if (-not ([System.Management.Automation.PSTypeName]'WpfGifPlayer').Type) {
    $wpfGifPlayerB64 = '77u/dXNpbmcgU3lzdGVtOw0KdXNpbmcgU3lzdGVtLkNvbGxlY3Rpb25zLkdlbmVyaWM7DQp1c2luZyBTeXN0ZW0uSU87DQp1c2luZyBTeXN0ZW0uV2luZG93czsNCnVzaW5nIFN5c3RlbS5XaW5kb3dzLk1lZGlhOw0KdXNpbmcgU3lzdGVtLldpbmRvd3MuTWVkaWEuSW1hZ2luZzsNCg0KcHVibGljIGNsYXNzIFJhd0dpZkZyYW1lIHsNCiAgICBwdWJsaWMgaW50IExlZnQsIFRvcCwgV2lkdGgsIEhlaWdodCwgRGVsYXlNcywgRGlzcG9zYWw7DQogICAgcHVibGljIGludCBQaXhlbFdpZHRoLCBQaXhlbEhlaWdodDsNCiAgICBwdWJsaWMgaW50W10gUGl4ZWxzOw0KfQ0KDQpwdWJsaWMgY2xhc3MgR2lmUGxheWVyUHJlcGFyZWRTdGF0ZSB7DQogICAgcHVibGljIHN0cmluZyBGaWxlUGF0aDsNCiAgICBwdWJsaWMgaW50IENhbnZhc1dpZHRoLCBDYW52YXNIZWlnaHQsIEZyYW1lQ291bnQsIFByZXZpZXdXaWR0aCwgUHJldmlld0hlaWdodCwgQ3VycmVudEZyYW1lSW5kZXg7DQogICAgcHVibGljIGludCBNYXhQcmV2aWV3U2lkZSwgQmFja2dyb3VuZEFyZ2IsIEJhY2tncm91bmRJbmRleDsNCiAgICBwdWJsaWMgYm9vbCBIYXNCYWNrZ3JvdW5kOw0KICAgIHB1YmxpYyBkb3VibGUgVG90YWxEdXJhdGlvblNlY29uZHMsIFByZXZpZXdTY2FsZTsNCiAgICBwdWJsaWMgb2JqZWN0W10gRnJhbWVzOw0KICAgIHB1YmxpYyBvYmplY3RbXSBDYWNoZWRGcmFtZXM7DQogICAgcHVibGljIG9iamVjdFtdIENoZWNrcG9pbnRzOw0KICAgIHB1YmxpYyBpbnRbXSBDYW52YXMsIFJlc3RvcmU7DQp9DQoNCi8vLyA8c3VtbWFyeT5Cb3VuZGVkLW1lbW9yeSBHSUYgcHJldmlldyByZW5kZXJlci4gUHVibGljIGNhbnZhcyBkaW1lbnNpb25zIGFuZCBmcmFtZSBtZXRhZGF0YSByZW1haW4gaW4gbG9naWNhbCBHSUYgcGl4ZWxzLjwvc3VtbWFyeT4NCnB1YmxpYyBjbGFzcyBXcGZHaWZQbGF5ZXIgOiBJRGlzcG9zYWJsZSB7DQogICAgcHVibGljIGJvb2wgSXNMb2FkZWQgPSBmYWxzZTsNCiAgICBwdWJsaWMgaW50IENhbnZhc1dpZHRoID0gMCwgQ2FudmFzSGVpZ2h0ID0gMCwgRnJhbWVDb3VudCA9IDA7DQogICAgcHVibGljIGRvdWJsZSBUb3RhbER1cmF0aW9uU2Vjb25kcyA9IDAuMDsNCiAgICBwdWJsaWMgV3JpdGVhYmxlQml0bWFwIEJpdG1hcFNvdXJjZSA9IG51bGw7DQogICAgcHVibGljIGludCBDdXJyZW50RnJhbWVJbmRleCA9IDA7DQogICAgcHVibGljIGludCBNYXhQcmV2aWV3U2lkZSA9IDcyMDsNCiAgICBwdWJsaWMgaW50IFByZXZpZXdXaWR0aCA9IDAsIFByZXZpZXdIZWlnaHQgPSAwOw0KICAgIHB1YmxpYyBkb3VibGUgUHJldmlld1NjYWxlID0gMS4wOw0KICAgIHB1YmxpYyBzdHJpbmcgTG9hZEVycm9yID0gbnVsbDsNCiAgICBwdWJsaWMgbG9uZyBDYWNoZWRGcmFtZUJ5dGVzIHsgZ2V0IHsgcmV0dXJuIF9jYWNoZWRCeXRlczsgfSB9DQogICAgcHVibGljIGxvbmcgQ2hlY2twb2ludEJ5dGVzIHsgZ2V0IHsgcmV0dXJuIF9jaGVja3BvaW50Qnl0ZXM7IH0gfQ0KDQogICAgcHJpdmF0ZSBzZWFsZWQgY2xhc3MgRnJhbWVJbmZvIHsNCiAgICAgICAgcHVibGljIGludCBMZWZ0LCBUb3AsIFdpZHRoLCBIZWlnaHQsIERlbGF5TXMsIERpc3Bvc2FsOw0KICAgICAgICBwdWJsaWMgYm9vbCBIYXNUcmFuc3BhcmVuY3k7DQogICAgICAgIHB1YmxpYyBpbnQgVHJhbnNwYXJlbnRDb2xvckluZGV4Ow0KICAgICAgICBwdWJsaWMgZG91YmxlIFRpbWVzdGFtcDsNCiAgICB9DQogICAgcHJpdmF0ZSBzZWFsZWQgY2xhc3MgQ2hlY2twb2ludCB7DQogICAgICAgIHB1YmxpYyBpbnQgSW5kZXg7DQogICAgICAgIHB1YmxpYyBieXRlW10gQ2FudmFzLCBSZXN0b3JlOw0KICAgICAgICBwdWJsaWMgbG9uZyBCeXRlcyB7IGdldCB7IHJldHVybiAobG9uZylDYW52YXMuTGVuZ3RoICsgUmVzdG9yZS5MZW5ndGg7IH0gfQ0KICAgIH0NCiAgICBwcml2YXRlIHJlYWRvbmx5IExpc3Q8RnJhbWVJbmZvPiBfZnJhbWVzID0gbmV3IExpc3Q8RnJhbWVJbmZvPigpOw0KICAgIHByaXZhdGUgcmVhZG9ubHkgRGljdGlvbmFyeTxpbnQsIFJhd0dpZkZyYW1lPiBfZnJhbWVDYWNoZSA9IG5ldyBEaWN0aW9uYXJ5PGludCwgUmF3R2lmRnJhbWU+KCk7DQogICAgcHJpdmF0ZSByZWFkb25seSBMaW5rZWRMaXN0PGludD4gX2ZyYW1lTHJ1ID0gbmV3IExpbmtlZExpc3Q8aW50PigpOw0KICAgIHByaXZhdGUgcmVhZG9ubHkgRGljdGlvbmFyeTxpbnQsIExpbmtlZExpc3ROb2RlPGludD4+IF9mcmFtZU5vZGVzID0gbmV3IERpY3Rpb25hcnk8aW50LCBMaW5rZWRMaXN0Tm9kZTxpbnQ+PigpOw0KICAgIHByaXZhdGUgcmVhZG9ubHkgU29ydGVkRGljdGlvbmFyeTxpbnQsIENoZWNrcG9pbnQ+IF9jaGVja3BvaW50cyA9IG5ldyBTb3J0ZWREaWN0aW9uYXJ5PGludCwgQ2hlY2twb2ludD4oKTsNCiAgICBwcml2YXRlIEZpbGVTdHJlYW0gX3N0cmVhbTsNCiAgICBwcml2YXRlIEdpZkJpdG1hcERlY29kZXIgX2RlY29kZXI7DQogICAgcHJpdmF0ZSBXcml0ZWFibGVCaXRtYXAgX2xvZ2ljYWxCaXRtYXA7DQogICAgcHJpdmF0ZSBzdHJpbmcgX2ZpbGVQYXRoOw0KICAgIHByaXZhdGUgaW50W10gX2NhbnZhc0J1ZmZlciwgX3ByZUZyYW1lQnVmZmVyOw0KICAgIHByaXZhdGUgaW50IF9sb2dpY2FsQmFja2dyb3VuZEFyZ2IsIF9sb2dpY2FsQmFja2dyb3VuZEluZGV4Ow0KICAgIHByaXZhdGUgYm9vbCBfaGFzTG9naWNhbEJhY2tncm91bmQ7DQogICAgcHJpdmF0ZSBpbnQgX3JlbmRlcmVkSW5kZXggPSAtMTsNCiAgICBwcml2YXRlIGludCBfZGVjb2RlZEZyYW1lc0luRGVjb2RlcjsNCiAgICBwcml2YXRlIGxvbmcgX2NhY2hlZEJ5dGVzLCBfY2hlY2twb2ludEJ5dGVzOw0KICAgIHByaXZhdGUgZG91YmxlIF9uZXh0VGltZUNoZWNrcG9pbnQ7DQogICAgcHJpdmF0ZSBkb3VibGUgX2NoZWNrcG9pbnRJbnRlcnZhbFNlY29uZHM9MS4wOw0KICAgIHByaXZhdGUgY29uc3QgbG9uZyBNYXhDYW52YXNCeXRlcyA9IDY0TCAqIDEwMjQgKiAxMDI0Ow0KICAgIHByaXZhdGUgY29uc3QgbG9uZyBNYXhQZXJzaXN0ZW50UGxheWVyQnl0ZXMgPSAxMjhMICogMTAyNCAqIDEwMjQ7DQogICAgcHJpdmF0ZSBjb25zdCBsb25nIE1heENoZWNrcG9pbnRCeXRlcyA9IDMyTCAqIDEwMjQgKiAxMDI0Ow0KICAgIHByaXZhdGUgY29uc3QgbG9uZyBNYXhDYWNoZWRGcmFtZUJ5dGVzID0gMTZMICogMTAyNCAqIDEwMjQ7DQogICAgcHJpdmF0ZSBjb25zdCBsb25nIE1heFRvdGFsRGVjb2RlZFBpeGVscyA9IDEyMDAwMDAwMDBMOw0KICAgIHByaXZhdGUgY29uc3QgaW50IE1heEZyYW1lQ291bnQgPSAxMDAwMDsNCiAgICBwcml2YXRlIGNvbnN0IGludCBNYXhDYW52YXNTaWRlID0gMTYzODQ7DQogICAgcHJpdmF0ZSBjb25zdCBpbnQgTWF4RGVjb2RlckJhdGNoRnJhbWVzID0gODsNCiAgICBwcml2YXRlIGNvbnN0IGludCBDaGVja3BvaW50U3RyaWRlID0gMjQ7DQoNCiAgICBwdWJsaWMgYm9vbCBMb2FkKHN0cmluZyBmaWxlUGF0aCkgew0KICAgICAgICBDbG9zZSgpOw0KICAgICAgICB0cnkgew0KICAgICAgICAgICAgaWYgKFN0cmluZy5Jc051bGxPcldoaXRlU3BhY2UoZmlsZVBhdGgpIHx8ICFGaWxlLkV4aXN0cyhmaWxlUGF0aCkpIHRocm93IG5ldyBJbnZhbGlkRGF0YUV4Y2VwdGlvbigiR0lGIGZpbGUgaXMgbWlzc2luZy4iKTsNCiAgICAgICAgICAgIF9maWxlUGF0aCA9IGZpbGVQYXRoOw0KICAgICAgICAgICAgX3N0cmVhbSA9IG5ldyBGaWxlU3RyZWFtKGZpbGVQYXRoLCBGaWxlTW9kZS5PcGVuLCBGaWxlQWNjZXNzLlJlYWQsIEZpbGVTaGFyZS5SZWFkKTsNCiAgICAgICAgICAgIGJ5dGVbXSBoZWFkZXIgPSBuZXcgYnl0ZVsxMF07DQogICAgICAgICAgICBpZiAoX3N0cmVhbS5SZWFkKGhlYWRlciwgMCwgaGVhZGVyLkxlbmd0aCkgIT0gaGVhZGVyLkxlbmd0aCB8fCBoZWFkZXJbMF0gIT0gKGJ5dGUpJ0cnIHx8IGhlYWRlclsxXSAhPSAoYnl0ZSknSScgfHwgaGVhZGVyWzJdICE9IChieXRlKSdGJykNCiAgICAgICAgICAgICAgICB0aHJvdyBuZXcgSW52YWxpZERhdGFFeGNlcHRpb24oIkZpbGUgaGVhZGVyIGlzIG5vdCBhIEdJRi4iKTsNCiAgICAgICAgICAgIGludCBsb2dpY2FsV2lkdGggPSBoZWFkZXJbNl0gfCAoaGVhZGVyWzddIDw8IDgpLCBsb2dpY2FsSGVpZ2h0ID0gaGVhZGVyWzhdIHwgKGhlYWRlcls5XSA8PCA4KTsNCiAgICAgICAgICAgIGJ5dGVbXSBzY3JlZW4gPSBuZXcgYnl0ZVsxM107DQogICAgICAgICAgICBfc3RyZWFtLlBvc2l0aW9uID0gMDsNCiAgICAgICAgICAgIGlmIChfc3RyZWFtLlJlYWQoc2NyZWVuLCAwLCBzY3JlZW4uTGVuZ3RoKSAhPSBzY3JlZW4uTGVuZ3RoKSB0aHJvdyBuZXcgSW52YWxpZERhdGFFeGNlcHRpb24oIkdJRiBsb2dpY2FsIHNjcmVlbiBkZXNjcmlwdG9yIGlzIHRydW5jYXRlZC4iKTsNCiAgICAgICAgICAgIGludCBzY3JlZW5QYWNrZWQgPSBzY3JlZW5bMTBdOw0KICAgICAgICAgICAgX2xvZ2ljYWxCYWNrZ3JvdW5kSW5kZXggPSBzY3JlZW5bMTFdOw0KICAgICAgICAgICAgX2hhc0xvZ2ljYWxCYWNrZ3JvdW5kID0gZmFsc2U7DQogICAgICAgICAgICBpZiAoKHNjcmVlblBhY2tlZCAmIDB4ODApICE9IDApIHsNCiAgICAgICAgICAgICAgICBpbnQgcGFsZXR0ZUVudHJpZXMgPSAxIDw8ICgoc2NyZWVuUGFja2VkICYgNykgKyAxKTsNCiAgICAgICAgICAgICAgICBieXRlW10gcGFsZXR0ZSA9IG5ldyBieXRlW3BhbGV0dGVFbnRyaWVzICogM107DQogICAgICAgICAgICAgICAgaWYgKF9zdHJlYW0uUmVhZChwYWxldHRlLCAwLCBwYWxldHRlLkxlbmd0aCkgIT0gcGFsZXR0ZS5MZW5ndGgpIHRocm93IG5ldyBJbnZhbGlkRGF0YUV4Y2VwdGlvbigiR0lGIGdsb2JhbCBjb2xvciB0YWJsZSBpcyB0cnVuY2F0ZWQuIik7DQogICAgICAgICAgICAgICAgaWYgKF9sb2dpY2FsQmFja2dyb3VuZEluZGV4IDwgcGFsZXR0ZUVudHJpZXMpIHsNCiAgICAgICAgICAgICAgICAgICAgaW50IHAgPSBfbG9naWNhbEJhY2tncm91bmRJbmRleCAqIDM7DQogICAgICAgICAgICAgICAgICAgIF9sb2dpY2FsQmFja2dyb3VuZEFyZ2IgPSB1bmNoZWNrZWQoKGludCkweEZGMDAwMDAwKSB8IChwYWxldHRlW3BdIDw8IDE2KSB8IChwYWxldHRlW3AgKyAxXSA8PCA4KSB8IHBhbGV0dGVbcCArIDJdOw0KICAgICAgICAgICAgICAgICAgICBfaGFzTG9naWNhbEJhY2tncm91bmQgPSB0cnVlOw0KICAgICAgICAgICAgICAgIH0NCiAgICAgICAgICAgIH0NCiAgICAgICAgICAgIF9zdHJlYW0uUG9zaXRpb24gPSAwOw0KICAgICAgICAgICAgX2RlY29kZXIgPSBuZXcgR2lmQml0bWFwRGVjb2Rlcihfc3RyZWFtLCBCaXRtYXBDcmVhdGVPcHRpb25zLlByZXNlcnZlUGl4ZWxGb3JtYXQsIEJpdG1hcENhY2hlT3B0aW9uLk9uRGVtYW5kKTsNCiAgICAgICAgICAgIGlmIChfZGVjb2Rlci5GcmFtZXMuQ291bnQgPT0gMCB8fCBfZGVjb2Rlci5GcmFtZXMuQ291bnQgPiBNYXhGcmFtZUNvdW50KSB0aHJvdyBuZXcgSW52YWxpZERhdGFFeGNlcHRpb24oIkdJRiBmcmFtZSBjb3VudCBpcyBvdXRzaWRlIHRoZSBzdXBwb3J0ZWQgYnVkZ2V0LiIpOw0KICAgICAgICAgICAgRnJhbWVDb3VudCA9IF9kZWNvZGVyLkZyYW1lcy5Db3VudDsNCg0KICAgICAgICAgICAgdmFyIGZpcnN0ID0gX2RlY29kZXIuRnJhbWVzWzBdOw0KICAgICAgICAgICAgdmFyIGZpcnN0TWV0YSA9IGZpcnN0Lk1ldGFkYXRhIGFzIEJpdG1hcE1ldGFkYXRhOw0KICAgICAgICAgICAgQ2FudmFzV2lkdGggPSBsb2dpY2FsV2lkdGggPiAwID8gbG9naWNhbFdpZHRoIDogUmVhZE1ldGEoZmlyc3RNZXRhLCAiL2xvZ3NjcmRlc2MvV2lkdGgiLCBmaXJzdC5QaXhlbFdpZHRoKTsNCiAgICAgICAgICAgIENhbnZhc0hlaWdodCA9IGxvZ2ljYWxIZWlnaHQgPiAwID8gbG9naWNhbEhlaWdodCA6IFJlYWRNZXRhKGZpcnN0TWV0YSwgIi9sb2dzY3JkZXNjL0hlaWdodCIsIGZpcnN0LlBpeGVsSGVpZ2h0KTsNCiAgICAgICAgICAgIGlmIChDYW52YXNXaWR0aCA8IDEgfHwgQ2FudmFzSGVpZ2h0IDwgMSB8fCBDYW52YXNXaWR0aCA+IE1heENhbnZhc1NpZGUgfHwgQ2FudmFzSGVpZ2h0ID4gTWF4Q2FudmFzU2lkZSB8fA0KICAgICAgICAgICAgICAgIChsb25nKUNhbnZhc1dpZHRoICogQ2FudmFzSGVpZ2h0ICogNCA+IE1heENhbnZhc0J5dGVzKQ0KICAgICAgICAgICAgICAgIHRocm93IG5ldyBJbnZhbGlkRGF0YUV4Y2VwdGlvbigiR0lGIGxvZ2ljYWwgY2FudmFzIGV4Y2VlZHMgdGhlIHN1cHBvcnRlZCBtZW1vcnkgYnVkZ2V0ICgiICsgQ2FudmFzV2lkdGggKyAieCIgKyBDYW52YXNIZWlnaHQgKyAiKS4iKTsNCg0KICAgICAgICAgICAgUHJldmlld1NjYWxlID0gTWF4UHJldmlld1NpZGUgPiAwID8gTWF0aC5NaW4oMS4wLCAoZG91YmxlKU1heFByZXZpZXdTaWRlIC8gTWF0aC5NYXgoQ2FudmFzV2lkdGgsIENhbnZhc0hlaWdodCkpIDogMS4wOw0KICAgICAgICAgICAgUHJldmlld1dpZHRoID0gTWF0aC5NYXgoMSwgKGludClNYXRoLlJvdW5kKENhbnZhc1dpZHRoICogUHJldmlld1NjYWxlKSk7DQogICAgICAgICAgICBQcmV2aWV3SGVpZ2h0ID0gTWF0aC5NYXgoMSwgKGludClNYXRoLlJvdW5kKENhbnZhc0hlaWdodCAqIFByZXZpZXdTY2FsZSkpOw0KICAgICAgICAgICAgbG9uZyBsb2dpY2FsQ2FudmFzQnl0ZXM9KGxvbmcpQ2FudmFzV2lkdGgqQ2FudmFzSGVpZ2h0KjQsIHByZXZpZXdDYW52YXNCeXRlcz0obG9uZylQcmV2aWV3V2lkdGgqUHJldmlld0hlaWdodCo0Ow0KICAgICAgICAgICAgaWYobG9naWNhbENhbnZhc0J5dGVzKjMrcHJldmlld0NhbnZhc0J5dGVzK01heENhY2hlZEZyYW1lQnl0ZXMrTWF4Q2hlY2twb2ludEJ5dGVzPk1heFBlcnNpc3RlbnRQbGF5ZXJCeXRlcykNCiAgICAgICAgICAgICAgICB0aHJvdyBuZXcgSW52YWxpZERhdGFFeGNlcHRpb24oIkdJRiBsb2dpY2FsIGNhbnZhcyBwbHVzIHByZXZpZXcgZXhjZWVkcyB0aGUgdG90YWwgcGxheWVyLW1lbW9yeSBidWRnZXQ7IHJlZHVjZSBNYXhQcmV2aWV3U2lkZS4iKTsNCiAgICAgICAgICAgIF9jYW52YXNCdWZmZXIgPSBuZXcgaW50W2NoZWNrZWQoQ2FudmFzV2lkdGggKiBDYW52YXNIZWlnaHQpXTsNCiAgICAgICAgICAgIF9wcmVGcmFtZUJ1ZmZlciA9IG5ldyBpbnRbX2NhbnZhc0J1ZmZlci5MZW5ndGhdOw0KICAgICAgICAgICAgX2ZyYW1lcy5DbGVhcigpOw0KICAgICAgICAgICAgZG91YmxlIGVsYXBzZWQgPSAwOw0KICAgICAgICAgICAgbG9uZyBkZWNsYXJlZFBpeGVscyA9IDA7DQogICAgICAgICAgICBmb3IgKGludCBpID0gMDsgaSA8IEZyYW1lQ291bnQ7IGkrKykgew0KICAgICAgICAgICAgICAgIHZhciBmcmFtZSA9IF9kZWNvZGVyLkZyYW1lc1tpXTsNCiAgICAgICAgICAgICAgICB2YXIgbWV0YSA9IGZyYW1lLk1ldGFkYXRhIGFzIEJpdG1hcE1ldGFkYXRhOw0KICAgICAgICAgICAgICAgIGludCBkZWxheUNzID0gUmVhZE1ldGEobWV0YSwgIi9ncmN0bGV4dC9EZWxheSIsIDEwKTsNCiAgICAgICAgICAgICAgICBpZiAoZGVsYXlDcyA8PSAwKSBkZWxheUNzID0gMTA7DQogICAgICAgICAgICAgICAgaW50IGZ3ID0gZnJhbWUuUGl4ZWxXaWR0aCwgZmggPSBmcmFtZS5QaXhlbEhlaWdodDsNCiAgICAgICAgICAgICAgICBpZiAoZncgPCAxIHx8IGZoIDwgMSB8fCBmdyA+IE1heENhbnZhc1NpZGUgfHwgZmggPiBNYXhDYW52YXNTaWRlKSB0aHJvdyBuZXcgSW52YWxpZERhdGFFeGNlcHRpb24oIkdJRiBmcmFtZSBkaW1lbnNpb25zIGFyZSBpbnZhbGlkLiIpOw0KICAgICAgICAgICAgICAgIGRlY2xhcmVkUGl4ZWxzICs9IChsb25nKWZ3ICogZmg7DQogICAgICAgICAgICAgICAgaWYgKGRlY2xhcmVkUGl4ZWxzID4gTWF4VG90YWxEZWNvZGVkUGl4ZWxzKSB0aHJvdyBuZXcgSW52YWxpZERhdGFFeGNlcHRpb24oIkdJRiBleGNlZWRzIHRoZSBjdW11bGF0aXZlIGRlY29kZWQtcGl4ZWwgYnVkZ2V0LiIpOw0KICAgICAgICAgICAgICAgIHZhciBpbmZvID0gbmV3IEZyYW1lSW5mbyB7DQogICAgICAgICAgICAgICAgICAgIExlZnQgPSBSZWFkTWV0YShtZXRhLCAiL2ltZ2Rlc2MvTGVmdCIsIDApLCBUb3AgPSBSZWFkTWV0YShtZXRhLCAiL2ltZ2Rlc2MvVG9wIiwgMCksDQogICAgICAgICAgICAgICAgICAgIFdpZHRoID0gZncsIEhlaWdodCA9IGZoLCBEZWxheU1zID0gZGVsYXlDcyAqIDEwLA0KICAgICAgICAgICAgICAgICAgICBEaXNwb3NhbCA9IE1hdGguTWF4KDAsIE1hdGguTWluKDMsIFJlYWRNZXRhKG1ldGEsICIvZ3JjdGxleHQvRGlzcG9zYWwiLCAxKSkpLA0KICAgICAgICAgICAgICAgICAgICBIYXNUcmFuc3BhcmVuY3kgPSBSZWFkTWV0YShtZXRhLCAiL2dyY3RsZXh0L1RyYW5zcGFyZW5jeUZsYWciLCAwKSAhPSAwLA0KICAgICAgICAgICAgICAgICAgICBUcmFuc3BhcmVudENvbG9ySW5kZXggPSBSZWFkTWV0YShtZXRhLCAiL2dyY3RsZXh0L1RyYW5zcGFyZW50Q29sb3JJbmRleCIsIC0xKSwgVGltZXN0YW1wID0gZWxhcHNlZA0KICAgICAgICAgICAgICAgIH07DQogICAgICAgICAgICAgICAgX2ZyYW1lcy5BZGQoaW5mbyk7DQogICAgICAgICAgICAgICAgZWxhcHNlZCArPSBpbmZvLkRlbGF5TXMgLyAxMDAwLjA7DQogICAgICAgICAgICB9DQogICAgICAgICAgICBUb3RhbER1cmF0aW9uU2Vjb25kcyA9IGVsYXBzZWQgPiAwID8gZWxhcHNlZCA6IDEuMDsNCiAgICAgICAgICAgIC8vIEtlZXAgZ2VuZXJpYyB0aW1lIGFuY2hvcnMgZGVuc2UgZW5vdWdoIGZvciBzaG9ydCBzZWVrcyB3aGlsZSBhbGxvd2luZw0KICAgICAgICAgICAgLy8gdGhlIGNvbXByZXNzZWQgY2hlY2twb2ludCBidWRnZXQgdG8gcHJ1bmUgdGhlbSB1bmlmb3JtbHkgb24gbGFyZ2UgY2FudmFzZXMuDQogICAgICAgICAgICBfY2hlY2twb2ludEludGVydmFsU2Vjb25kcz1NYXRoLk1heCgwLjUsVG90YWxEdXJhdGlvblNlY29uZHMvMTI4LjApO19uZXh0VGltZUNoZWNrcG9pbnQ9MC4wOw0KICAgICAgICAgICAgQml0bWFwU291cmNlID0gbmV3IFdyaXRlYWJsZUJpdG1hcChQcmV2aWV3V2lkdGgsIFByZXZpZXdIZWlnaHQsIDk2LCA5NiwgUGl4ZWxGb3JtYXRzLkJncmEzMiwgbnVsbCk7DQogICAgICAgICAgICBfbG9naWNhbEJpdG1hcCA9IG5ldyBXcml0ZWFibGVCaXRtYXAoQ2FudmFzV2lkdGgsIENhbnZhc0hlaWdodCwgOTYsIDk2LCBQaXhlbEZvcm1hdHMuQmdyYTMyLCBudWxsKTsNCiAgICAgICAgICAgIElzTG9hZGVkID0gdHJ1ZTsNCiAgICAgICAgICAgIEN1cnJlbnRGcmFtZUluZGV4ID0gMDsNCiAgICAgICAgICAgIFJlbmRlclRvRnJhbWUoMCk7DQogICAgICAgICAgICBMb2FkRXJyb3IgPSBudWxsOw0KICAgICAgICAgICAgcmV0dXJuIHRydWU7DQogICAgICAgIH0gY2F0Y2ggKEV4Y2VwdGlvbiBleCkgew0KICAgICAgICAgICAgTG9hZEVycm9yID0gZXguTWVzc2FnZTsNCiAgICAgICAgICAgIENsb3NlUmVzb3VyY2VzKCk7DQogICAgICAgICAgICBSZXNldFN0YXRlKCk7DQogICAgICAgICAgICByZXR1cm4gZmFsc2U7DQogICAgICAgIH0NCiAgICB9DQoNCiAgICBwdWJsaWMgdm9pZCBDbG9zZSgpIHsgQ2xvc2VSZXNvdXJjZXMoKTsgUmVzZXRTdGF0ZSgpOyBMb2FkRXJyb3IgPSBudWxsOyB9DQogICAgcHVibGljIHZvaWQgRGlzcG9zZSgpIHsgQ2xvc2UoKTsgfQ0KDQogICAgLy8gQ2FsbGVkIG9uIGEgd29ya2VyIFNUQS4gRGVjb2RlL2NoZWNrcG9pbnQgd29yayBzdGF5cyBvZmYgdGhlIFVJIHRocmVhZDsgb25seSBwbGFpbg0KICAgIC8vIG1ldGFkYXRhIGFuZCBhcnJheSBvd25lcnNoaXAgY3Jvc3MgdGhyZWFkcy4gVGhlIHJldHVybmVkIHN0YXRlIGlzIGEgb25lLXNob3QgdHJhbnNmZXIgb2JqZWN0Lg0KICAgIHB1YmxpYyBHaWZQbGF5ZXJQcmVwYXJlZFN0YXRlIFByZXBhcmVGb3JUcmFuc2ZlcigpIHsNCiAgICAgICAgaWYgKCFJc0xvYWRlZCkgdGhyb3cgbmV3IEludmFsaWRPcGVyYXRpb25FeGNlcHRpb24oIkdJRiBwbGF5ZXIgaXMgbm90IGxvYWRlZC4iKTsNCiAgICAgICAgUmVuZGVyVG9GcmFtZShGcmFtZUNvdW50IC0gMSk7DQogICAgICAgIFNlZWtUb1NlY29uZHMoMC4wKTsNCiAgICAgICAgUmVsZWFzZURlY29kZXIoKTsNCiAgICAgICAgdmFyIHN0YXRlID0gbmV3IEdpZlBsYXllclByZXBhcmVkU3RhdGUgew0KICAgICAgICAgICAgRmlsZVBhdGggPSBfZmlsZVBhdGgsIENhbnZhc1dpZHRoID0gQ2FudmFzV2lkdGgsIENhbnZhc0hlaWdodCA9IENhbnZhc0hlaWdodCwgRnJhbWVDb3VudCA9IEZyYW1lQ291bnQsDQogICAgICAgICAgICBQcmV2aWV3V2lkdGggPSBQcmV2aWV3V2lkdGgsIFByZXZpZXdIZWlnaHQgPSBQcmV2aWV3SGVpZ2h0LCBDdXJyZW50RnJhbWVJbmRleCA9IEN1cnJlbnRGcmFtZUluZGV4LA0KICAgICAgICAgICAgTWF4UHJldmlld1NpZGUgPSBNYXhQcmV2aWV3U2lkZSwgQmFja2dyb3VuZEFyZ2IgPSBfbG9naWNhbEJhY2tncm91bmRBcmdiLCBCYWNrZ3JvdW5kSW5kZXggPSBfbG9naWNhbEJhY2tncm91bmRJbmRleCwNCiAgICAgICAgICAgIEhhc0JhY2tncm91bmQgPSBfaGFzTG9naWNhbEJhY2tncm91bmQsIFRvdGFsRHVyYXRpb25TZWNvbmRzID0gVG90YWxEdXJhdGlvblNlY29uZHMsIFByZXZpZXdTY2FsZSA9IFByZXZpZXdTY2FsZSwNCiAgICAgICAgICAgIEZyYW1lcyA9IG5ldyBvYmplY3RbX2ZyYW1lcy5Db3VudF0sIENhY2hlZEZyYW1lcyA9IG5ldyBvYmplY3RbX2ZyYW1lQ2FjaGUuQ291bnRdLA0KICAgICAgICAgICAgQ2hlY2twb2ludHMgPSBuZXcgb2JqZWN0W19jaGVja3BvaW50cy5Db3VudF0sIENhbnZhcyA9IF9jYW52YXNCdWZmZXIsIFJlc3RvcmUgPSBfcHJlRnJhbWVCdWZmZXINCiAgICAgICAgfTsNCiAgICAgICAgZm9yIChpbnQgaSA9IDA7IGkgPCBfZnJhbWVzLkNvdW50OyBpKyspIHsNCiAgICAgICAgICAgIHZhciBmID0gX2ZyYW1lc1tpXTsNCiAgICAgICAgICAgIHN0YXRlLkZyYW1lc1tpXSA9IG5ldyBvYmplY3RbXSB7IGYuTGVmdCwgZi5Ub3AsIGYuV2lkdGgsIGYuSGVpZ2h0LCBmLkRlbGF5TXMsIGYuRGlzcG9zYWwsIGYuSGFzVHJhbnNwYXJlbmN5LCBmLlRyYW5zcGFyZW50Q29sb3JJbmRleCwgZi5UaW1lc3RhbXAgfTsNCiAgICAgICAgfQ0KICAgICAgICBpbnQgYyA9IDA7DQogICAgICAgIGZvcmVhY2ggKHZhciBwYWlyIGluIF9mcmFtZUNhY2hlKSB7DQogICAgICAgICAgICB2YXIgZiA9IHBhaXIuVmFsdWU7DQogICAgICAgICAgICBzdGF0ZS5DYWNoZWRGcmFtZXNbYysrXSA9IG5ldyBvYmplY3RbXSB7IHBhaXIuS2V5LCBuZXcgUmF3R2lmRnJhbWUgeyBMZWZ0PWYuTGVmdCwgVG9wPWYuVG9wLCBXaWR0aD1mLldpZHRoLCBIZWlnaHQ9Zi5IZWlnaHQsDQogICAgICAgICAgICAgICAgRGVsYXlNcz1mLkRlbGF5TXMsIERpc3Bvc2FsPWYuRGlzcG9zYWwsIFBpeGVsV2lkdGg9Zi5QaXhlbFdpZHRoLCBQaXhlbEhlaWdodD1mLlBpeGVsSGVpZ2h0LCBQaXhlbHM9Zi5QaXhlbHMgfSB9Ow0KICAgICAgICB9DQogICAgICAgIGMgPSAwOw0KICAgICAgICBmb3JlYWNoICh2YXIgcGFpciBpbiBfY2hlY2twb2ludHMpIHN0YXRlLkNoZWNrcG9pbnRzW2MrK10gPSBuZXcgb2JqZWN0W10geyBwYWlyLktleSwgcGFpci5WYWx1ZS5DYW52YXMsIHBhaXIuVmFsdWUuUmVzdG9yZSB9Ow0KICAgICAgICAvLyBUcmFuc2ZlciBhcnJheSBvd25lcnNoaXAgdG8gdGhlIHBsYWluIHN0YXRlIG9iamVjdDsgY2FsbGVyIG1heSBub3cgY2xvc2UgdGhpcyB3b3JrZXIgaW5zdGFuY2UuDQogICAgICAgIF9jYW52YXNCdWZmZXI9bnVsbDsgX3ByZUZyYW1lQnVmZmVyPW51bGw7IF9mcmFtZUNhY2hlLkNsZWFyKCk7IF9mcmFtZUxydS5DbGVhcigpOyBfZnJhbWVOb2Rlcy5DbGVhcigpOyBfY2hlY2twb2ludHMuQ2xlYXIoKTsNCiAgICAgICAgX2NhY2hlZEJ5dGVzPTA7IF9jaGVja3BvaW50Qnl0ZXM9MDsNCiAgICAgICAgcmV0dXJuIHN0YXRlOw0KICAgIH0NCg0KICAgIC8vIENhbGxlZCBvbmx5IG9uIHRoZSByZWNlaXZpbmcgVUkgdGhyZWFkOyBjcmVhdGVzIGEgbmV3IHRocmVhZC1hZmZpbmUgV3JpdGVhYmxlQml0bWFwLg0KICAgIHB1YmxpYyBib29sIEFkb3B0T25DdXJyZW50VGhyZWFkKEdpZlBsYXllclByZXBhcmVkU3RhdGUgc3RhdGUpIHsNCiAgICAgICAgQ2xvc2UoKTsNCiAgICAgICAgaWYgKHN0YXRlID09IG51bGwgfHwgc3RhdGUuRnJhbWVzID09IG51bGwgfHwgc3RhdGUuQ2FudmFzID09IG51bGwgfHwgc3RhdGUuUmVzdG9yZSA9PSBudWxsKSByZXR1cm4gZmFsc2U7DQogICAgICAgIHRyeSB7DQogICAgICAgICAgICBfZmlsZVBhdGg9c3RhdGUuRmlsZVBhdGg7IENhbnZhc1dpZHRoPXN0YXRlLkNhbnZhc1dpZHRoOyBDYW52YXNIZWlnaHQ9c3RhdGUuQ2FudmFzSGVpZ2h0OyBGcmFtZUNvdW50PXN0YXRlLkZyYW1lQ291bnQ7DQogICAgICAgICAgICBQcmV2aWV3V2lkdGg9c3RhdGUuUHJldmlld1dpZHRoOyBQcmV2aWV3SGVpZ2h0PXN0YXRlLlByZXZpZXdIZWlnaHQ7IEN1cnJlbnRGcmFtZUluZGV4PXN0YXRlLkN1cnJlbnRGcmFtZUluZGV4Ow0KICAgICAgICAgICAgTWF4UHJldmlld1NpZGU9c3RhdGUuTWF4UHJldmlld1NpZGU7IF9sb2dpY2FsQmFja2dyb3VuZEFyZ2I9c3RhdGUuQmFja2dyb3VuZEFyZ2I7IF9sb2dpY2FsQmFja2dyb3VuZEluZGV4PXN0YXRlLkJhY2tncm91bmRJbmRleDsNCiAgICAgICAgICAgIF9oYXNMb2dpY2FsQmFja2dyb3VuZD1zdGF0ZS5IYXNCYWNrZ3JvdW5kOyBUb3RhbER1cmF0aW9uU2Vjb25kcz1zdGF0ZS5Ub3RhbER1cmF0aW9uU2Vjb25kczsgUHJldmlld1NjYWxlPXN0YXRlLlByZXZpZXdTY2FsZTsNCiAgICAgICAgICAgIF9mcmFtZXMuQ2xlYXIoKTsNCiAgICAgICAgICAgIGZvcmVhY2ggKG9iamVjdFtdIGEgaW4gc3RhdGUuRnJhbWVzKSBfZnJhbWVzLkFkZChuZXcgRnJhbWVJbmZvIHsgTGVmdD0oaW50KWFbMF0sIFRvcD0oaW50KWFbMV0sIFdpZHRoPShpbnQpYVsyXSwgSGVpZ2h0PShpbnQpYVszXSwNCiAgICAgICAgICAgICAgICBEZWxheU1zPShpbnQpYVs0XSwgRGlzcG9zYWw9KGludClhWzVdLCBIYXNUcmFuc3BhcmVuY3k9KGJvb2wpYVs2XSwgVHJhbnNwYXJlbnRDb2xvckluZGV4PShpbnQpYVs3XSwgVGltZXN0YW1wPShkb3VibGUpYVs4XSB9KTsNCiAgICAgICAgICAgIF9jYW52YXNCdWZmZXI9c3RhdGUuQ2FudmFzOyBfcHJlRnJhbWVCdWZmZXI9c3RhdGUuUmVzdG9yZTsNCiAgICAgICAgICAgIF9mcmFtZUNhY2hlLkNsZWFyKCk7IF9mcmFtZUxydS5DbGVhcigpOyBfZnJhbWVOb2Rlcy5DbGVhcigpOyBfY2FjaGVkQnl0ZXM9MDsNCiAgICAgICAgICAgIGZvcmVhY2ggKG9iamVjdFtdIHBhaXIgaW4gc3RhdGUuQ2FjaGVkRnJhbWVzKSB7DQogICAgICAgICAgICAgICAgaW50IGluZGV4PShpbnQpcGFpclswXTsgdmFyIGY9KFJhd0dpZkZyYW1lKXBhaXJbMV07DQogICAgICAgICAgICAgICAgX2ZyYW1lQ2FjaGVbaW5kZXhdPWY7IF9jYWNoZWRCeXRlcys9KGxvbmcpZi5QaXhlbHMuTGVuZ3RoKjQ7IF9mcmFtZU5vZGVzW2luZGV4XT1fZnJhbWVMcnUuQWRkRmlyc3QoaW5kZXgpOw0KICAgICAgICAgICAgfQ0KICAgICAgICAgICAgZm9yZWFjaCAob2JqZWN0W10gYSBpbiBzdGF0ZS5DaGVja3BvaW50cykgeyB2YXIgY3A9bmV3IENoZWNrcG9pbnQgeyBJbmRleD0oaW50KWFbMF0sIENhbnZhcz0oYnl0ZVtdKWFbMV0sIFJlc3RvcmU9KGJ5dGVbXSlhWzJdIH07IF9jaGVja3BvaW50c1tjcC5JbmRleF09Y3A7IF9jaGVja3BvaW50Qnl0ZXMrPWNwLkJ5dGVzOyB9DQogICAgICAgICAgICBCaXRtYXBTb3VyY2U9bmV3IFdyaXRlYWJsZUJpdG1hcChQcmV2aWV3V2lkdGgsUHJldmlld0hlaWdodCw5Niw5NixQaXhlbEZvcm1hdHMuQmdyYTMyLG51bGwpOw0KICAgICAgICAgICAgX2xvZ2ljYWxCaXRtYXA9bmV3IFdyaXRlYWJsZUJpdG1hcChDYW52YXNXaWR0aCxDYW52YXNIZWlnaHQsOTYsOTYsUGl4ZWxGb3JtYXRzLkJncmEzMixudWxsKTsNCiAgICAgICAgICAgIElzTG9hZGVkPXRydWU7IF9yZW5kZXJlZEluZGV4PUN1cnJlbnRGcmFtZUluZGV4OyBDb21taXRUb0JpdG1hcCgpOyBMb2FkRXJyb3I9bnVsbDsNCiAgICAgICAgICAgIHN0YXRlLkZyYW1lcz1udWxsOyBzdGF0ZS5DYWNoZWRGcmFtZXM9bnVsbDsgc3RhdGUuQ2hlY2twb2ludHM9bnVsbDsgc3RhdGUuQ2FudmFzPW51bGw7IHN0YXRlLlJlc3RvcmU9bnVsbDsNCiAgICAgICAgICAgIHJldHVybiB0cnVlOw0KICAgICAgICB9IGNhdGNoKEV4Y2VwdGlvbiBleCkgeyBMb2FkRXJyb3I9ZXguTWVzc2FnZTsgQ2xvc2VSZXNvdXJjZXMoKTsgUmVzZXRTdGF0ZSgpOyByZXR1cm4gZmFsc2U7IH0NCiAgICB9DQoNCiAgICBwdWJsaWMgaW50IE5leHRGcmFtZSgpIHsNCiAgICAgICAgaWYgKCFJc0xvYWRlZCB8fCBGcmFtZUNvdW50IDw9IDEpIHJldHVybiAxMDA7DQogICAgICAgIGludCBuZXh0ID0gKEN1cnJlbnRGcmFtZUluZGV4ICsgMSkgJSBGcmFtZUNvdW50Ow0KICAgICAgICBTdGVwVG9OZXh0KG5leHQpOw0KICAgICAgICBDdXJyZW50RnJhbWVJbmRleCA9IG5leHQ7DQogICAgICAgIHJldHVybiBfZnJhbWVzW25leHRdLkRlbGF5TXM7DQogICAgfQ0KDQogICAgcHVibGljIHZvaWQgU3RlcFRvTmV4dChpbnQgdGFyZ2V0SW5kZXgpIHsNCiAgICAgICAgaWYgKCFJc0xvYWRlZCB8fCB0YXJnZXRJbmRleCA8IDAgfHwgdGFyZ2V0SW5kZXggPj0gRnJhbWVDb3VudCkgcmV0dXJuOw0KICAgICAgICBpZiAodGFyZ2V0SW5kZXggPT0gMCB8fCB0YXJnZXRJbmRleCAhPSBfcmVuZGVyZWRJbmRleCArIDEpIHsgUmVuZGVyVG9GcmFtZSh0YXJnZXRJbmRleCk7IHJldHVybjsgfQ0KICAgICAgICBBcHBseURpc3Bvc2FsKF9mcmFtZXNbX3JlbmRlcmVkSW5kZXhdKTsNCiAgICAgICAgdmFyIG5leHQgPSBHZXRGcmFtZSh0YXJnZXRJbmRleCk7DQogICAgICAgIGlmIChfZnJhbWVzW3RhcmdldEluZGV4XS5EaXNwb3NhbCA9PSAzKSBBcnJheS5Db3B5KF9jYW52YXNCdWZmZXIsIF9wcmVGcmFtZUJ1ZmZlciwgX2NhbnZhc0J1ZmZlci5MZW5ndGgpOw0KICAgICAgICBEcmF3RnJhbWUobmV4dCk7DQogICAgICAgIF9yZW5kZXJlZEluZGV4ID0gdGFyZ2V0SW5kZXg7DQogICAgICAgIEN1cnJlbnRGcmFtZUluZGV4ID0gdGFyZ2V0SW5kZXg7DQogICAgICAgIE1heWJlU2F2ZUNoZWNrcG9pbnQodGFyZ2V0SW5kZXgpOw0KICAgICAgICBDb21taXRUb0JpdG1hcCgpOw0KICAgIH0NCg0KICAgIHB1YmxpYyB2b2lkIFNlZWtUb1NlY29uZHMoZG91YmxlIHNlY29uZHMpIHsNCiAgICAgICAgaWYgKCFJc0xvYWRlZCB8fCBGcmFtZUNvdW50ID09IDAgfHwgRG91YmxlLklzTmFOKHNlY29uZHMpIHx8IERvdWJsZS5Jc0luZmluaXR5KHNlY29uZHMpKSByZXR1cm47DQogICAgICAgIGludCB0YXJnZXQ9RnJhbWVJbmRleEF0U2Vjb25kcyhzZWNvbmRzKTsNCiAgICAgICAgaWYgKHRhcmdldCA9PSBDdXJyZW50RnJhbWVJbmRleCAmJiB0YXJnZXQgPT0gX3JlbmRlcmVkSW5kZXgpIHJldHVybjsNCiAgICAgICAgaWYgKHRhcmdldCA9PSBfcmVuZGVyZWRJbmRleCArIDEpIFN0ZXBUb05leHQodGFyZ2V0KTsgZWxzZSBSZW5kZXJUb0ZyYW1lKHRhcmdldCk7DQogICAgfQ0KDQogICAgcHVibGljIGludCBGcmFtZUluZGV4QXRTZWNvbmRzKGRvdWJsZSBzZWNvbmRzKSB7DQogICAgICAgIGlmKCFJc0xvYWRlZHx8RnJhbWVDb3VudD09MHx8RG91YmxlLklzTmFOKHNlY29uZHMpfHxEb3VibGUuSXNJbmZpbml0eShzZWNvbmRzKSlyZXR1cm4gMDsNCiAgICAgICAgc2Vjb25kcyU9VG90YWxEdXJhdGlvblNlY29uZHM7aWYoc2Vjb25kczwwKXNlY29uZHMrPVRvdGFsRHVyYXRpb25TZWNvbmRzOw0KICAgICAgICBmb3IoaW50IGk9RnJhbWVDb3VudC0xO2k+PTA7aS0tKWlmKHNlY29uZHM+PV9mcmFtZXNbaV0uVGltZXN0YW1wKXJldHVybiBpOw0KICAgICAgICByZXR1cm4gMDsNCiAgICB9DQoNCiAgICBwdWJsaWMgdm9pZCBSZW5kZXJUb0ZyYW1lKGludCB0YXJnZXRJbmRleCkgew0KICAgICAgICBpZiAoIUlzTG9hZGVkIHx8IHRhcmdldEluZGV4IDwgMCB8fCB0YXJnZXRJbmRleCA+PSBGcmFtZUNvdW50KSByZXR1cm47DQogICAgICAgIENoZWNrcG9pbnQgY3AgPSBGaW5kQ2hlY2twb2ludCh0YXJnZXRJbmRleCk7DQogICAgICAgIGludCBzdGFydDsNCiAgICAgICAgaWYgKGNwID09IG51bGwpIHsNCiAgICAgICAgICAgIEZpbGxDYW52YXMoSW5pdGlhbENhbnZhc0NvbG9yKCkpOw0KICAgICAgICAgICAgQXJyYXkuQ2xlYXIoX3ByZUZyYW1lQnVmZmVyLCAwLCBfcHJlRnJhbWVCdWZmZXIuTGVuZ3RoKTsNCiAgICAgICAgICAgIHN0YXJ0ID0gMDsNCiAgICAgICAgfSBlbHNlIHsNCiAgICAgICAgICAgIERlY29tcHJlc3NJbnRzKGNwLkNhbnZhcywgX2NhbnZhc0J1ZmZlcik7DQogICAgICAgICAgICBEZWNvbXByZXNzSW50cyhjcC5SZXN0b3JlLCBfcHJlRnJhbWVCdWZmZXIpOw0KICAgICAgICAgICAgc3RhcnQgPSBjcC5JbmRleCArIDE7DQogICAgICAgIH0NCiAgICAgICAgZm9yIChpbnQgaSA9IHN0YXJ0OyBpIDw9IHRhcmdldEluZGV4OyBpKyspIHsNCiAgICAgICAgICAgIGlmIChpID4gMCAmJiAoaSA+IHN0YXJ0IHx8IGNwICE9IG51bGwpKSBBcHBseURpc3Bvc2FsKF9mcmFtZXNbaSAtIDFdKTsNCiAgICAgICAgICAgIGlmIChfZnJhbWVzW2ldLkRpc3Bvc2FsID09IDMpIEFycmF5LkNvcHkoX2NhbnZhc0J1ZmZlciwgX3ByZUZyYW1lQnVmZmVyLCBfY2FudmFzQnVmZmVyLkxlbmd0aCk7DQogICAgICAgICAgICBEcmF3RnJhbWUoR2V0RnJhbWUoaSkpOw0KICAgICAgICAgICAgTWF5YmVTYXZlQ2hlY2twb2ludChpKTsNCiAgICAgICAgfQ0KICAgICAgICBfcmVuZGVyZWRJbmRleCA9IHRhcmdldEluZGV4Ow0KICAgICAgICBDdXJyZW50RnJhbWVJbmRleCA9IHRhcmdldEluZGV4Ow0KICAgICAgICBDb21taXRUb0JpdG1hcCgpOw0KICAgIH0NCg0KICAgIHB1YmxpYyBpbnQgR2V0UGl4ZWxBbHBoYShpbnQgeCwgaW50IHkpIHsgaW50IHB4ID0gR2V0TG9naWNhbFBpeGVsKHgsIHkpOyByZXR1cm4gKHB4ID4+IDI0KSAmIDI1NTsgfQ0KICAgIHB1YmxpYyBpbnQgR2V0UGl4ZWxSZ2IoaW50IHgsIGludCB5KSB7IHJldHVybiBHZXRMb2dpY2FsUGl4ZWwoeCwgeSkgJiAweDAwRkZGRkZGOyB9DQogICAgcHVibGljIGludCBNYXBMb2dpY2FsWFRvUHJldmlldyhpbnQgeCkgeyByZXR1cm4gUHJldmlld1dpZHRoIDw9IDAgPyAwIDogTWF0aC5NYXgoMCwgTWF0aC5NaW4oUHJldmlld1dpZHRoIC0gMSwgKGludClNYXRoLkZsb29yKHggKiBQcmV2aWV3U2NhbGUpKSk7IH0NCiAgICBwdWJsaWMgaW50IE1hcExvZ2ljYWxZVG9QcmV2aWV3KGludCB5KSB7IHJldHVybiBQcmV2aWV3SGVpZ2h0IDw9IDAgPyAwIDogTWF0aC5NYXgoMCwgTWF0aC5NaW4oUHJldmlld0hlaWdodCAtIDEsIChpbnQpTWF0aC5GbG9vcih5ICogUHJldmlld1NjYWxlKSkpOyB9DQoNCiAgICBwcml2YXRlIGludCBHZXRMb2dpY2FsUGl4ZWwoaW50IHgsIGludCB5KSB7DQogICAgICAgIGlmIChfY2FudmFzQnVmZmVyID09IG51bGwgfHwgeCA8IDAgfHwgeCA+PSBDYW52YXNXaWR0aCB8fCB5IDwgMCB8fCB5ID49IENhbnZhc0hlaWdodCkgcmV0dXJuIDA7DQogICAgICAgIGludCBweCA9IE1hdGguTWluKFByZXZpZXdXaWR0aCAtIDEsIE1hcExvZ2ljYWxYVG9QcmV2aWV3KHgpKTsNCiAgICAgICAgaW50IHB5ID0gTWF0aC5NaW4oUHJldmlld0hlaWdodCAtIDEsIE1hcExvZ2ljYWxZVG9QcmV2aWV3KHkpKTsNCiAgICAgICAgcmV0dXJuIF9jYW52YXNCdWZmZXJbeSAqIENhbnZhc1dpZHRoICsgeF07DQogICAgfQ0KDQogICAgcHJpdmF0ZSBSYXdHaWZGcmFtZSBHZXRGcmFtZShpbnQgaW5kZXgpIHsNCiAgICAgICAgUmF3R2lmRnJhbWUgY2FjaGVkOw0KICAgICAgICBpZiAoX2ZyYW1lQ2FjaGUuVHJ5R2V0VmFsdWUoaW5kZXgsIG91dCBjYWNoZWQpKSB7IFRvdWNoRnJhbWUoaW5kZXgpOyByZXR1cm4gY2FjaGVkOyB9DQogICAgICAgIGlmIChfZGVjb2RlciA9PSBudWxsKSB7DQogICAgICAgICAgICBfc3RyZWFtID0gRmlsZS5PcGVuUmVhZChfZmlsZVBhdGgpOw0KICAgICAgICAgICAgX2RlY29kZXIgPSBuZXcgR2lmQml0bWFwRGVjb2Rlcihfc3RyZWFtLCBCaXRtYXBDcmVhdGVPcHRpb25zLlByZXNlcnZlUGl4ZWxGb3JtYXQsIEJpdG1hcENhY2hlT3B0aW9uLk9uRGVtYW5kKTsNCiAgICAgICAgICAgIF9kZWNvZGVkRnJhbWVzSW5EZWNvZGVyID0gMDsNCiAgICAgICAgfQ0KICAgICAgICB2YXIgZnJhbWUgPSBfZGVjb2Rlci5GcmFtZXNbaW5kZXhdOw0KICAgICAgICBpbnQgcHcgPSBmcmFtZS5QaXhlbFdpZHRoLCBwaCA9IGZyYW1lLlBpeGVsSGVpZ2h0Ow0KICAgICAgICBsb25nIGRlY29kZWRCeXRlcyA9IChsb25nKXB3ICogcGggKiA0Ow0KICAgICAgICBpZiAoZGVjb2RlZEJ5dGVzID4gTWF4Q2FjaGVkRnJhbWVCeXRlcykgdGhyb3cgbmV3IEludmFsaWREYXRhRXhjZXB0aW9uKCJHSUYgZnJhbWUgZXhjZWVkcyB0aGUgZGVjb2RlZC1mcmFtZSBtZW1vcnkgYnVkZ2V0LiIpOw0KICAgICAgICB2YXIgY29udmVydGVkID0gbmV3IEZvcm1hdENvbnZlcnRlZEJpdG1hcChmcmFtZSwgUGl4ZWxGb3JtYXRzLkJncmEzMiwgbnVsbCwgMCk7DQogICAgICAgIGludFtdIHBpeGVscyA9IG5ldyBpbnRbY2hlY2tlZChwdyAqIHBoKV07DQogICAgICAgIGNvbnZlcnRlZC5Db3B5UGl4ZWxzKG5ldyBJbnQzMlJlY3QoMCwgMCwgcHcsIHBoKSwgcGl4ZWxzLCBwdyAqIDQsIDApOw0KICAgICAgICB2YXIgaW5mbyA9IF9mcmFtZXNbaW5kZXhdOw0KICAgICAgICB2YXIgcmF3ID0gbmV3IFJhd0dpZkZyYW1lIHsgTGVmdCA9IGluZm8uTGVmdCwgVG9wID0gaW5mby5Ub3AsIFdpZHRoID0gaW5mby5XaWR0aCwgSGVpZ2h0ID0gaW5mby5IZWlnaHQsDQogICAgICAgICAgICBQaXhlbFdpZHRoID0gcHcsIFBpeGVsSGVpZ2h0ID0gcGgsIERlbGF5TXMgPSBpbmZvLkRlbGF5TXMsIERpc3Bvc2FsID0gaW5mby5EaXNwb3NhbCwgUGl4ZWxzID0gcGl4ZWxzIH07DQogICAgICAgIF9kZWNvZGVkRnJhbWVzSW5EZWNvZGVyKys7DQogICAgICAgIGlmIChfZGVjb2RlZEZyYW1lc0luRGVjb2RlciA+PSBNYXhEZWNvZGVyQmF0Y2hGcmFtZXMpIFJlbGVhc2VEZWNvZGVyKCk7DQogICAgICAgIGlmIChkZWNvZGVkQnl0ZXMgPD0gTWF4Q2FjaGVkRnJhbWVCeXRlcykgew0KICAgICAgICAgICAgd2hpbGUgKF9jYWNoZWRCeXRlcyArIGRlY29kZWRCeXRlcyA+IE1heENhY2hlZEZyYW1lQnl0ZXMgJiYgX2ZyYW1lTHJ1Lkxhc3QgIT0gbnVsbCkgRXZpY3RGcmFtZShfZnJhbWVMcnUuTGFzdC5WYWx1ZSk7DQogICAgICAgICAgICBfZnJhbWVDYWNoZVtpbmRleF0gPSByYXc7DQogICAgICAgICAgICBfY2FjaGVkQnl0ZXMgKz0gZGVjb2RlZEJ5dGVzOw0KICAgICAgICAgICAgX2ZyYW1lTm9kZXNbaW5kZXhdID0gX2ZyYW1lTHJ1LkFkZEZpcnN0KGluZGV4KTsNCiAgICAgICAgfQ0KICAgICAgICByZXR1cm4gcmF3Ow0KICAgIH0NCg0KICAgIHByaXZhdGUgdm9pZCBEcmF3RnJhbWUoUmF3R2lmRnJhbWUgZikgew0KICAgICAgICBpbnQgbGVmdCA9IGYuTGVmdCwgdG9wID0gZi5Ub3A7DQogICAgICAgIGZvciAoaW50IHIgPSAwOyByIDwgZi5QaXhlbEhlaWdodDsgcisrKSB7DQogICAgICAgICAgICBpbnQgZHkgPSB0b3AgKyByOyBpZiAoZHkgPCAwIHx8IGR5ID49IENhbnZhc0hlaWdodCkgY29udGludWU7DQogICAgICAgICAgICBpbnQgcm93ID0gciAqIGYuUGl4ZWxXaWR0aCwgZHN0Um93ID0gZHkgKiBDYW52YXNXaWR0aDsNCiAgICAgICAgICAgIGZvciAoaW50IGMgPSAwOyBjIDwgZi5QaXhlbFdpZHRoOyBjKyspIHsNCiAgICAgICAgICAgICAgICBpbnQgZHggPSBsZWZ0ICsgYzsgaWYgKGR4IDwgMCB8fCBkeCA+PSBDYW52YXNXaWR0aCkgY29udGludWU7DQogICAgICAgICAgICAgICAgaW50IHB4ID0gZi5QaXhlbHNbcm93ICsgY107IGludCBhbHBoYT0oaW50KSgodWludClweD4+MjQpOw0KICAgICAgICAgICAgICAgIGlmKGFscGhhPT0wKSBjb250aW51ZTsNCiAgICAgICAgICAgICAgICBpZihhbHBoYT09MjU1KXtfY2FudmFzQnVmZmVyW2RzdFJvdytkeF09cHg7Y29udGludWU7fQ0KICAgICAgICAgICAgICAgIGludCBkc3Q9X2NhbnZhc0J1ZmZlcltkc3RSb3crZHhdLCBkYT0oaW50KSgodWludClkc3Q+PjI0KSwgaW52PTI1NS1hbHBoYTsNCiAgICAgICAgICAgICAgICBsb25nIGRlbm9taW5hdG9yPShsb25nKWFscGhhKjI1NSsobG9uZylkYSppbnY7DQogICAgICAgICAgICAgICAgaWYoZGVub21pbmF0b3I8PTApY29udGludWU7DQogICAgICAgICAgICAgICAgaW50IG91dEE9KGludCkoKGRlbm9taW5hdG9yKzEyNykvMjU1KTsNCiAgICAgICAgICAgICAgICBpbnQgYj0oaW50KSgoKGxvbmcpKHB4JjI1NSkqYWxwaGEqMjU1Kyhsb25nKShkc3QmMjU1KSpkYSppbnYrZGVub21pbmF0b3IvMikvZGVub21pbmF0b3IpOw0KICAgICAgICAgICAgICAgIGludCBnPShpbnQpKCgobG9uZykoKHB4Pj44KSYyNTUpKmFscGhhKjI1NSsobG9uZykoKGRzdD4+OCkmMjU1KSpkYSppbnYrZGVub21pbmF0b3IvMikvZGVub21pbmF0b3IpOw0KICAgICAgICAgICAgICAgIGludCByZWQ9KGludCkoKChsb25nKSgocHg+PjE2KSYyNTUpKmFscGhhKjI1NSsobG9uZykoKGRzdD4+MTYpJjI1NSkqZGEqaW52K2Rlbm9taW5hdG9yLzIpL2Rlbm9taW5hdG9yKTsNCiAgICAgICAgICAgICAgICBfY2FudmFzQnVmZmVyW2RzdFJvdytkeF09KG91dEE8PDI0KXwocmVkPDwxNil8KGc8PDgpfGI7DQogICAgICAgICAgICB9DQogICAgICAgIH0NCiAgICB9DQoNCiAgICBwcml2YXRlIHZvaWQgQXBwbHlEaXNwb3NhbChGcmFtZUluZm8gZikgew0KICAgICAgICBpZiAoZi5EaXNwb3NhbCA9PSAyKSB7DQogICAgICAgICAgICBpbnQgbGVmdCA9IGYuTGVmdCwgdG9wID0gZi5Ub3A7DQogICAgICAgICAgICBpbnQgcmlnaHQgPSBmLkxlZnQgKyBmLldpZHRoLCBib3R0b20gPSBmLlRvcCArIGYuSGVpZ2h0Ow0KICAgICAgICAgICAgaW50IGZpbGwgPSBmLkhhc1RyYW5zcGFyZW5jeSA/IDAgOiAoX2hhc0xvZ2ljYWxCYWNrZ3JvdW5kID8gX2xvZ2ljYWxCYWNrZ3JvdW5kQXJnYiA6IDApOw0KICAgICAgICAgICAgZm9yIChpbnQgeSA9IE1hdGguTWF4KDAsIHRvcCk7IHkgPCBNYXRoLk1pbihDYW52YXNIZWlnaHQsIGJvdHRvbSk7IHkrKykNCiAgICAgICAgICAgICAgICBmb3IgKGludCB4ID0gTWF0aC5NYXgoMCwgbGVmdCk7IHggPCBNYXRoLk1pbihDYW52YXNXaWR0aCwgcmlnaHQpOyB4KyspIF9jYW52YXNCdWZmZXJbeSAqIENhbnZhc1dpZHRoICsgeF0gPSBmaWxsOw0KICAgICAgICB9IGVsc2UgaWYgKGYuRGlzcG9zYWwgPT0gMykgQXJyYXkuQ29weShfcHJlRnJhbWVCdWZmZXIsIF9jYW52YXNCdWZmZXIsIF9jYW52YXNCdWZmZXIuTGVuZ3RoKTsNCiAgICB9DQoNCiAgICBwcml2YXRlIGludCBJbml0aWFsQ2FudmFzQ29sb3IoKSB7DQogICAgICAgIGlmICghX2hhc0xvZ2ljYWxCYWNrZ3JvdW5kKSByZXR1cm4gMDsNCiAgICAgICAgaWYgKF9mcmFtZXMuQ291bnQgPiAwICYmIF9mcmFtZXNbMF0uSGFzVHJhbnNwYXJlbmN5KSByZXR1cm4gMDsNCiAgICAgICAgcmV0dXJuIF9sb2dpY2FsQmFja2dyb3VuZEFyZ2I7DQogICAgfQ0KICAgIHByaXZhdGUgdm9pZCBGaWxsQ2FudmFzKGludCBjb2xvcikgeyBmb3IgKGludCBpID0gMDsgaSA8IF9jYW52YXNCdWZmZXIuTGVuZ3RoOyBpKyspIF9jYW52YXNCdWZmZXJbaV0gPSBjb2xvcjsgfQ0KDQogICAgcHJpdmF0ZSB2b2lkIENvbW1pdFRvQml0bWFwKCkgew0KICAgICAgICBpZiAoQml0bWFwU291cmNlID09IG51bGwgfHwgX2xvZ2ljYWxCaXRtYXAgPT0gbnVsbCkgcmV0dXJuOw0KICAgICAgICBfbG9naWNhbEJpdG1hcC5Xcml0ZVBpeGVscyhuZXcgSW50MzJSZWN0KDAsMCxDYW52YXNXaWR0aCxDYW52YXNIZWlnaHQpLF9jYW52YXNCdWZmZXIsQ2FudmFzV2lkdGgqNCwwKTsNCiAgICAgICAgaWYoUHJldmlld1dpZHRoPT1DYW52YXNXaWR0aCYmUHJldmlld0hlaWdodD09Q2FudmFzSGVpZ2h0KXtCaXRtYXBTb3VyY2UuV3JpdGVQaXhlbHMobmV3IEludDMyUmVjdCgwLDAsUHJldmlld1dpZHRoLFByZXZpZXdIZWlnaHQpLF9jYW52YXNCdWZmZXIsQ2FudmFzV2lkdGgqNCwwKTtyZXR1cm47fQ0KICAgICAgICB2YXIgc2NhbGVkPW5ldyBUcmFuc2Zvcm1lZEJpdG1hcChfbG9naWNhbEJpdG1hcCxuZXcgU2NhbGVUcmFuc2Zvcm0oKGRvdWJsZSlQcmV2aWV3V2lkdGgvQ2FudmFzV2lkdGgsKGRvdWJsZSlQcmV2aWV3SGVpZ2h0L0NhbnZhc0hlaWdodCkpOw0KICAgICAgICB2YXIgcGl4ZWxzPW5ldyBpbnRbY2hlY2tlZChQcmV2aWV3V2lkdGgqUHJldmlld0hlaWdodCldOw0KICAgICAgICBzY2FsZWQuQ29weVBpeGVscyhuZXcgSW50MzJSZWN0KDAsMCxQcmV2aWV3V2lkdGgsUHJldmlld0hlaWdodCkscGl4ZWxzLFByZXZpZXdXaWR0aCo0LDApOw0KICAgICAgICBCaXRtYXBTb3VyY2UuV3JpdGVQaXhlbHMobmV3IEludDMyUmVjdCgwLDAsUHJldmlld1dpZHRoLFByZXZpZXdIZWlnaHQpLHBpeGVscyxQcmV2aWV3V2lkdGgqNCwwKTsNCiAgICB9DQoNCiAgICBwcml2YXRlIHZvaWQgTWF5YmVTYXZlQ2hlY2twb2ludChpbnQgaW5kZXgpIHsNCiAgICAgICAgaWYoX2NoZWNrcG9pbnRzLkNvbnRhaW5zS2V5KGluZGV4KSlyZXR1cm47DQogICAgICAgIGJvb2wgc3RyaWRlPShpbmRleCsxKSVDaGVja3BvaW50U3RyaWRlPT0wOw0KICAgICAgICBib29sIHRpbWVkPV9mcmFtZXNbaW5kZXhdLlRpbWVzdGFtcCsxZS05Pj1fbmV4dFRpbWVDaGVja3BvaW50Ow0KICAgICAgICBpZighc3RyaWRlJiYhdGltZWQpcmV0dXJuOw0KICAgICAgICBpZih0aW1lZClfbmV4dFRpbWVDaGVja3BvaW50PV9mcmFtZXNbaW5kZXhdLlRpbWVzdGFtcCtfY2hlY2twb2ludEludGVydmFsU2Vjb25kczsNCiAgICAgICAgU2F2ZUNoZWNrcG9pbnQoaW5kZXgpOw0KICAgIH0NCiAgICBwcml2YXRlIHZvaWQgU2F2ZUNoZWNrcG9pbnQoaW50IGluZGV4KSB7DQogICAgICAgIHZhciBjYW52YXM9Q29tcHJlc3NJbnRzKF9jYW52YXNCdWZmZXIpOyB2YXIgcmVzdG9yZT1Db21wcmVzc0ludHMoX3ByZUZyYW1lQnVmZmVyKTsNCiAgICAgICAgbG9uZyBieXRlcz0obG9uZyljYW52YXMuTGVuZ3RoK3Jlc3RvcmUuTGVuZ3RoOw0KICAgICAgICBpZiAoYnl0ZXMgPiBNYXhDaGVja3BvaW50Qnl0ZXMpIHJldHVybjsNCiAgICAgICAgd2hpbGUgKF9jaGVja3BvaW50Qnl0ZXMgKyBieXRlcyA+IE1heENoZWNrcG9pbnRCeXRlcyAmJiBfY2hlY2twb2ludHMuQ291bnQgPiAwKSB7DQogICAgICAgICAgICBpbnRbXSBrZXlzPW5ldyBpbnRbX2NoZWNrcG9pbnRzLkNvdW50XTtfY2hlY2twb2ludHMuS2V5cy5Db3B5VG8oa2V5cywwKTtpbnQgcmVtb3ZlPWtleXNbMF07ZG91YmxlIGJlc3Q9RG91YmxlLk1heFZhbHVlOw0KICAgICAgICAgICAgaWYoa2V5cy5MZW5ndGg+Mil7Zm9yKGludCBpPTE7aTxrZXlzLkxlbmd0aC0xO2krKyl7ZG91YmxlIHNwYW49X2ZyYW1lc1trZXlzW2krMV1dLlRpbWVzdGFtcC1fZnJhbWVzW2tleXNbaS0xXV0uVGltZXN0YW1wO2lmKHNwYW48YmVzdCl7YmVzdD1zcGFuO3JlbW92ZT1rZXlzW2ldO319fQ0KICAgICAgICAgICAgZWxzZSBpZihrZXlzLkxlbmd0aD4xKXJlbW92ZT1rZXlzWzBdOw0KICAgICAgICAgICAgX2NoZWNrcG9pbnRCeXRlcyAtPSBfY2hlY2twb2ludHNbcmVtb3ZlXS5CeXRlczsgX2NoZWNrcG9pbnRzLlJlbW92ZShyZW1vdmUpOw0KICAgICAgICB9DQogICAgICAgIHZhciBjcCA9IG5ldyBDaGVja3BvaW50IHsgSW5kZXggPSBpbmRleCwgQ2FudmFzID0gY2FudmFzLCBSZXN0b3JlID0gcmVzdG9yZSB9Ow0KICAgICAgICBfY2hlY2twb2ludHNbaW5kZXhdID0gY3A7IF9jaGVja3BvaW50Qnl0ZXMgKz0gY3AuQnl0ZXM7DQogICAgfQ0KDQogICAgcHJpdmF0ZSBDaGVja3BvaW50IEZpbmRDaGVja3BvaW50KGludCB0YXJnZXQpIHsNCiAgICAgICAgQ2hlY2twb2ludCByZXN1bHQgPSBudWxsOw0KICAgICAgICBmb3JlYWNoICh2YXIgcGFpciBpbiBfY2hlY2twb2ludHMpIHsgaWYgKHBhaXIuS2V5ID4gdGFyZ2V0KSBicmVhazsgcmVzdWx0ID0gcGFpci5WYWx1ZTsgfQ0KICAgICAgICByZXR1cm4gcmVzdWx0Ow0KICAgIH0NCiAgICBwcml2YXRlIHN0YXRpYyBieXRlW10gQ29tcHJlc3NJbnRzKGludFtdIHBpeGVscykgew0KICAgICAgICBieXRlW10gcmF3PW5ldyBieXRlW3BpeGVscy5MZW5ndGgqNF07IEJ1ZmZlci5CbG9ja0NvcHkocGl4ZWxzLDAscmF3LDAscmF3Lkxlbmd0aCk7DQogICAgICAgIHVzaW5nKHZhciBvdXRwdXQ9bmV3IE1lbW9yeVN0cmVhbSgpKSB7DQogICAgICAgICAgICB1c2luZyh2YXIgZGVmbGF0ZT1uZXcgU3lzdGVtLklPLkNvbXByZXNzaW9uLkRlZmxhdGVTdHJlYW0ob3V0cHV0LFN5c3RlbS5JTy5Db21wcmVzc2lvbi5Db21wcmVzc2lvbkxldmVsLkZhc3Rlc3QsdHJ1ZSkpIGRlZmxhdGUuV3JpdGUocmF3LDAscmF3Lkxlbmd0aCk7DQogICAgICAgICAgICByZXR1cm4gb3V0cHV0LlRvQXJyYXkoKTsNCiAgICAgICAgfQ0KICAgIH0NCiAgICBwcml2YXRlIHN0YXRpYyB2b2lkIERlY29tcHJlc3NJbnRzKGJ5dGVbXSBjb21wcmVzc2VkLGludFtdIGRlc3RpbmF0aW9uKSB7DQogICAgICAgIGJ5dGVbXSBjaHVuaz1uZXcgYnl0ZVs2NCoxMDI0XTsgaW50IHRvdGFsPTAsIGV4cGVjdGVkPWNoZWNrZWQoZGVzdGluYXRpb24uTGVuZ3RoKjQpOw0KICAgICAgICB1c2luZyh2YXIgaW5wdXQ9bmV3IE1lbW9yeVN0cmVhbShjb21wcmVzc2VkLGZhbHNlKSkgdXNpbmcodmFyIGRlZmxhdGU9bmV3IFN5c3RlbS5JTy5Db21wcmVzc2lvbi5EZWZsYXRlU3RyZWFtKGlucHV0LFN5c3RlbS5JTy5Db21wcmVzc2lvbi5Db21wcmVzc2lvbk1vZGUuRGVjb21wcmVzcykpIHsNCiAgICAgICAgICAgIHdoaWxlKHRvdGFsPGV4cGVjdGVkKXtpbnQgbj1kZWZsYXRlLlJlYWQoY2h1bmssMCxNYXRoLk1pbihjaHVuay5MZW5ndGgsZXhwZWN0ZWQtdG90YWwpKTtpZihuPD0wKXRocm93IG5ldyBJbnZhbGlkRGF0YUV4Y2VwdGlvbigiR0lGIGNoZWNrcG9pbnQgaXMgdHJ1bmNhdGVkLiIpO0J1ZmZlci5CbG9ja0NvcHkoY2h1bmssMCxkZXN0aW5hdGlvbix0b3RhbCxuKTt0b3RhbCs9bjt9DQogICAgICAgICAgICBpZihkZWZsYXRlLlJlYWRCeXRlKCkhPS0xKXRocm93IG5ldyBJbnZhbGlkRGF0YUV4Y2VwdGlvbigiR0lGIGNoZWNrcG9pbnQgZXhjZWVkcyB0aGUgbG9naWNhbCBjYW52YXMgc2l6ZS4iKTsNCiAgICAgICAgfQ0KICAgIH0NCiAgICBwcml2YXRlIHZvaWQgVG91Y2hGcmFtZShpbnQgaW5kZXgpIHsgTGlua2VkTGlzdE5vZGU8aW50PiBuOyBpZiAoX2ZyYW1lTm9kZXMuVHJ5R2V0VmFsdWUoaW5kZXgsIG91dCBuKSkgeyBfZnJhbWVMcnUuUmVtb3ZlKG4pOyBfZnJhbWVMcnUuQWRkRmlyc3Qobik7IH0gfQ0KICAgIHByaXZhdGUgdm9pZCBFdmljdEZyYW1lKGludCBpbmRleCkgeyBSYXdHaWZGcmFtZSBmOyBpZiAoX2ZyYW1lQ2FjaGUuVHJ5R2V0VmFsdWUoaW5kZXgsIG91dCBmKSkgeyBfY2FjaGVkQnl0ZXMgLT0gKGxvbmcpZi5QaXhlbHMuTGVuZ3RoICogNDsgX2ZyYW1lQ2FjaGUuUmVtb3ZlKGluZGV4KTsgfSBMaW5rZWRMaXN0Tm9kZTxpbnQ+IG47IGlmIChfZnJhbWVOb2Rlcy5UcnlHZXRWYWx1ZShpbmRleCwgb3V0IG4pKSB7IF9mcmFtZUxydS5SZW1vdmUobik7IF9mcmFtZU5vZGVzLlJlbW92ZShpbmRleCk7IH0gfQ0KICAgIHByaXZhdGUgc3RhdGljIGludCBSZWFkTWV0YShCaXRtYXBNZXRhZGF0YSBtZXRhLCBzdHJpbmcgcXVlcnksIGludCBmYWxsYmFjaykgeyB0cnkgeyByZXR1cm4gbWV0YSA9PSBudWxsID8gZmFsbGJhY2sgOiBDb252ZXJ0LlRvSW50MzIobWV0YS5HZXRRdWVyeShxdWVyeSkpOyB9IGNhdGNoIHsgcmV0dXJuIGZhbGxiYWNrOyB9IH0NCiAgICBwcml2YXRlIHZvaWQgUmVsZWFzZURlY29kZXIoKSB7IF9kZWNvZGVyID0gbnVsbDsgaWYgKF9zdHJlYW0gIT0gbnVsbCkgeyB0cnkgeyBfc3RyZWFtLkRpc3Bvc2UoKTsgfSBjYXRjaCB7IH0gX3N0cmVhbSA9IG51bGw7IH0gX2RlY29kZWRGcmFtZXNJbkRlY29kZXIgPSAwOyB9DQogICAgcHJpdmF0ZSB2b2lkIENsb3NlUmVzb3VyY2VzKCkgeyBSZWxlYXNlRGVjb2RlcigpOyBfZmlsZVBhdGggPSBudWxsOyB9DQogICAgcHJpdmF0ZSB2b2lkIFJlc2V0U3RhdGUoKSB7DQogICAgICAgIElzTG9hZGVkID0gZmFsc2U7IF9mcmFtZXMuQ2xlYXIoKTsgX2ZyYW1lQ2FjaGUuQ2xlYXIoKTsgX2ZyYW1lTHJ1LkNsZWFyKCk7IF9mcmFtZU5vZGVzLkNsZWFyKCk7IF9jYWNoZWRCeXRlcyA9IDA7DQogICAgICAgIF9jaGVja3BvaW50cy5DbGVhcigpOyBfY2hlY2twb2ludEJ5dGVzID0gMDsgX2NhbnZhc0J1ZmZlciA9IG51bGw7IF9wcmVGcmFtZUJ1ZmZlciA9IG51bGw7IEJpdG1hcFNvdXJjZSA9IG51bGw7IF9sb2dpY2FsQml0bWFwPW51bGw7DQogICAgICAgIEZyYW1lQ291bnQgPSBDYW52YXNXaWR0aCA9IENhbnZhc0hlaWdodCA9IFByZXZpZXdXaWR0aCA9IFByZXZpZXdIZWlnaHQgPSBDdXJyZW50RnJhbWVJbmRleCA9IDA7DQogICAgICAgIFRvdGFsRHVyYXRpb25TZWNvbmRzID0gMDsgUHJldmlld1NjYWxlID0gMTsgX3JlbmRlcmVkSW5kZXggPSAtMTsNCiAgICAgICAgX25leHRUaW1lQ2hlY2twb2ludD0wO19jaGVja3BvaW50SW50ZXJ2YWxTZWNvbmRzPTEuMDsNCiAgICAgICAgX2xvZ2ljYWxCYWNrZ3JvdW5kQXJnYiA9IF9sb2dpY2FsQmFja2dyb3VuZEluZGV4ID0gMDsgX2hhc0xvZ2ljYWxCYWNrZ3JvdW5kID0gZmFsc2U7DQogICAgfQ0KfQ0KDQovLy8gPHN1bW1hcnk+T25lIGRlZGljYXRlZCBTVEEgcmVuZGVyZXIsIG9uZSBwZW5kaW5nIHRpbWVzdGFtcCBhbmQgb25lIGNvbXBsZXRlZCBmcm96ZW4gcHJldmlldy4NCi8vLyBEZWNvZGUvc2VlayB3b3JrIHJ1bnMgb2ZmIHRoZSBVSSB0aHJlYWQ7IENsb3NlIG1heSBKb2luIHRoZSByZW5kZXJlciBmb3IgdXAgdG8gMTAwIG1zLjwvc3VtbWFyeT4NCnB1YmxpYyBzZWFsZWQgY2xhc3MgV3BmR2lmUGxheWJhY2tXb3JrZXIgOiBJRGlzcG9zYWJsZSB7DQogICAgcHJpdmF0ZSByZWFkb25seSBvYmplY3QgX2dhdGUgPSBuZXcgb2JqZWN0KCk7DQogICAgcHJpdmF0ZSByZWFkb25seSBTeXN0ZW0uVGhyZWFkaW5nLkF1dG9SZXNldEV2ZW50IF93YWtlID0gbmV3IFN5c3RlbS5UaHJlYWRpbmcuQXV0b1Jlc2V0RXZlbnQoZmFsc2UpOw0KICAgIHByaXZhdGUgU3lzdGVtLlRocmVhZGluZy5UaHJlYWQgX3RocmVhZDsNCiAgICBwcml2YXRlIGJvb2wgX2Nsb3NlZCwgX3BlbmRpbmc7DQogICAgcHJpdmF0ZSBkb3VibGUgX3NlY29uZHM7DQogICAgcHJpdmF0ZSBsb25nIF92ZXJzaW9uOw0KICAgIHByaXZhdGUgQml0bWFwU291cmNlIF9jb21wbGV0ZWQ7DQogICAgcHJpdmF0ZSBpbnQgX2NvbXBsZXRlZEluZGV4Ow0KICAgIHByaXZhdGUgbG9uZyBfY29tcGxldGVkVmVyc2lvbjsNCiAgICBwcml2YXRlIGRvdWJsZVtdIF90aW1lc3RhbXBzOw0KICAgIHByaXZhdGUgaW50IF9yZXF1ZXN0ZWRJbmRleCA9IC0xOw0KICAgIHB1YmxpYyBib29sIElzTG9hZGVkIHsgZ2V0OyBwcml2YXRlIHNldDsgfQ0KICAgIHB1YmxpYyBCaXRtYXBTb3VyY2UgQml0bWFwU291cmNlIHsgZ2V0OyBwcml2YXRlIHNldDsgfQ0KICAgIHB1YmxpYyBpbnQgQ3VycmVudEZyYW1lSW5kZXggeyBnZXQ7IHByaXZhdGUgc2V0OyB9DQogICAgcHVibGljIHN0cmluZyBMb2FkRXJyb3IgeyBnZXQ7IHByaXZhdGUgc2V0OyB9DQogICAgcHVibGljIGludCBDYW52YXNXaWR0aCB7IGdldDsgcHJpdmF0ZSBzZXQ7IH0NCiAgICBwdWJsaWMgaW50IENhbnZhc0hlaWdodCB7IGdldDsgcHJpdmF0ZSBzZXQ7IH0NCiAgICBwdWJsaWMgaW50IEZyYW1lQ291bnQgeyBnZXQ7IHByaXZhdGUgc2V0OyB9DQogICAgcHVibGljIGRvdWJsZSBUb3RhbER1cmF0aW9uU2Vjb25kcyB7IGdldDsgcHJpdmF0ZSBzZXQ7IH0NCiAgICBwdWJsaWMgYm9vbCBJc1dvcmtlckFsaXZlIHsgZ2V0IHsgcmV0dXJuIF90aHJlYWQgIT0gbnVsbCAmJiBfdGhyZWFkLklzQWxpdmU7IH0gfQ0KDQogICAgcHVibGljIGJvb2wgQWRvcHRPbkN1cnJlbnRUaHJlYWQoR2lmUGxheWVyUHJlcGFyZWRTdGF0ZSBzdGF0ZSkgew0KICAgICAgICBpZiAoc3RhdGUgPT0gbnVsbCB8fCBzdGF0ZS5GcmFtZXMgPT0gbnVsbCB8fCBzdGF0ZS5DYW52YXMgPT0gbnVsbCkgcmV0dXJuIGZhbHNlOw0KICAgICAgICBsb2NrIChfZ2F0ZSkgew0KICAgICAgICAgICAgaWYgKF90aHJlYWQgIT0gbnVsbCB8fCBfY2xvc2VkKSByZXR1cm4gZmFsc2U7DQogICAgICAgICAgICBDYW52YXNXaWR0aD1zdGF0ZS5DYW52YXNXaWR0aDsgQ2FudmFzSGVpZ2h0PXN0YXRlLkNhbnZhc0hlaWdodDsgRnJhbWVDb3VudD1zdGF0ZS5GcmFtZUNvdW50OyBUb3RhbER1cmF0aW9uU2Vjb25kcz1zdGF0ZS5Ub3RhbER1cmF0aW9uU2Vjb25kczsNCiAgICAgICAgICAgIF90aW1lc3RhbXBzID0gbmV3IGRvdWJsZVtzdGF0ZS5GcmFtZXMuTGVuZ3RoXTsNCiAgICAgICAgICAgIGZvciAoaW50IGk9MDtpPF90aW1lc3RhbXBzLkxlbmd0aDtpKyspIF90aW1lc3RhbXBzW2ldPShkb3VibGUpKChvYmplY3RbXSlzdGF0ZS5GcmFtZXNbaV0pWzhdOw0KICAgICAgICAgICAgSXNMb2FkZWQgPSB0cnVlOw0KICAgICAgICAgICAgX3RocmVhZCA9IG5ldyBTeXN0ZW0uVGhyZWFkaW5nLlRocmVhZChkZWxlZ2F0ZSgpIHsgUnVuKHN0YXRlKTsgfSk7DQogICAgICAgICAgICBfdGhyZWFkLklzQmFja2dyb3VuZCA9IHRydWU7DQogICAgICAgICAgICBfdGhyZWFkLk5hbWUgPSAiR0lGIHByZXZpZXcgcmVuZGVyZXIiOw0KICAgICAgICAgICAgX3RocmVhZC5TZXRBcGFydG1lbnRTdGF0ZShTeXN0ZW0uVGhyZWFkaW5nLkFwYXJ0bWVudFN0YXRlLlNUQSk7DQogICAgICAgICAgICBfdGhyZWFkLlN0YXJ0KCk7DQogICAgICAgIH0NCiAgICAgICAgcmV0dXJuIHRydWU7DQogICAgfQ0KICAgIHB1YmxpYyB2b2lkIFNlZWtUb1NlY29uZHMoZG91YmxlIHNlY29uZHMpIHsNCiAgICAgICAgaWYgKERvdWJsZS5Jc05hTihzZWNvbmRzKSB8fCBEb3VibGUuSXNJbmZpbml0eShzZWNvbmRzKSkgcmV0dXJuOw0KICAgICAgICBsb2NrIChfZ2F0ZSkgew0KICAgICAgICAgICAgaWYgKF9jbG9zZWQgfHwgIUlzTG9hZGVkKSByZXR1cm47DQogICAgICAgICAgICBkb3VibGUgbm9ybWFsaXplZD1zZWNvbmRzJVRvdGFsRHVyYXRpb25TZWNvbmRzOw0KICAgICAgICAgICAgaWYobm9ybWFsaXplZDwwKW5vcm1hbGl6ZWQrPVRvdGFsRHVyYXRpb25TZWNvbmRzOw0KICAgICAgICAgICAgaW50IGxvPTAsaGk9X3RpbWVzdGFtcHMuTGVuZ3RoLTE7DQogICAgICAgICAgICB3aGlsZShsbzxoaSl7aW50IG1pZD0obG8raGkrMSkvMjtpZihfdGltZXN0YW1wc1ttaWRdPD1ub3JtYWxpemVkKWxvPW1pZDtlbHNlIGhpPW1pZC0xO30NCiAgICAgICAgICAgIGlmKGxvPT1fcmVxdWVzdGVkSW5kZXgpcmV0dXJuOw0KICAgICAgICAgICAgX3JlcXVlc3RlZEluZGV4PWxvOw0KICAgICAgICAgICAgX3NlY29uZHMgPSBzZWNvbmRzOyBfcGVuZGluZyA9IHRydWU7IF92ZXJzaW9uKys7IF9jb21wbGV0ZWQgPSBudWxsOw0KICAgICAgICAgICAgX3dha2UuU2V0KCk7DQogICAgICAgIH0NCiAgICB9DQogICAgLy8gQ2FsbCBvbiB0aGUgVUkgZGlzcGF0Y2hlci4gT25seSBpbW11dGFibGUgZnJvemVuIGltYWdlcyBjcm9zcyB0aHJlYWRzLg0KICAgIHB1YmxpYyBib29sIFBvbGxGcmFtZSgpIHsNCiAgICAgICAgbG9jayAoX2dhdGUpIHsNCiAgICAgICAgICAgIGlmIChfY2xvc2VkIHx8IF9jb21wbGV0ZWQgPT0gbnVsbCB8fCBfY29tcGxldGVkVmVyc2lvbiAhPSBfdmVyc2lvbikgcmV0dXJuIGZhbHNlOw0KICAgICAgICAgICAgQml0bWFwU291cmNlID0gX2NvbXBsZXRlZDsgQ3VycmVudEZyYW1lSW5kZXggPSBfY29tcGxldGVkSW5kZXg7IF9jb21wbGV0ZWQgPSBudWxsOw0KICAgICAgICAgICAgcmV0dXJuIHRydWU7DQogICAgICAgIH0NCiAgICB9DQogICAgcHJpdmF0ZSB2b2lkIFJ1bihHaWZQbGF5ZXJQcmVwYXJlZFN0YXRlIHN0YXRlKSB7DQogICAgICAgIHRyeSB7DQogICAgICAgICAgICB1c2luZyAodmFyIHBsYXllciA9IG5ldyBXcGZHaWZQbGF5ZXIoKSkgew0KICAgICAgICAgICAgICAgIGlmICghcGxheWVyLkFkb3B0T25DdXJyZW50VGhyZWFkKHN0YXRlKSkgdGhyb3cgbmV3IEludmFsaWRPcGVyYXRpb25FeGNlcHRpb24ocGxheWVyLkxvYWRFcnJvcik7DQogICAgICAgICAgICAgICAgYm9vbCBmaXJzdCA9IHRydWU7DQogICAgICAgICAgICAgICAgd2hpbGUgKHRydWUpIHsNCiAgICAgICAgICAgICAgICAgICAgZG91YmxlIHNlY29uZHM7IGxvbmcgdmVyc2lvbjsgYm9vbCBoYXZlUmVxdWVzdDsNCiAgICAgICAgICAgICAgICAgICAgbG9jayAoX2dhdGUpIHsNCiAgICAgICAgICAgICAgICAgICAgICAgIGlmIChfY2xvc2VkKSByZXR1cm47DQogICAgICAgICAgICAgICAgICAgICAgICBoYXZlUmVxdWVzdCA9IGZpcnN0IHx8IF9wZW5kaW5nOyBzZWNvbmRzID0gX3NlY29uZHM7IHZlcnNpb24gPSBfdmVyc2lvbjsgX3BlbmRpbmcgPSBmYWxzZTsgZmlyc3QgPSBmYWxzZTsNCiAgICAgICAgICAgICAgICAgICAgfQ0KICAgICAgICAgICAgICAgICAgICBpZiAoIWhhdmVSZXF1ZXN0KSB7IF93YWtlLldhaXRPbmUoKTsgY29udGludWU7IH0NCiAgICAgICAgICAgICAgICAgICAgcGxheWVyLlNlZWtUb1NlY29uZHMoc2Vjb25kcyk7DQogICAgICAgICAgICAgICAgICAgIHsNCiAgICAgICAgICAgICAgICAgICAgICAgIHZhciBzbmFwc2hvdCA9IHBsYXllci5CaXRtYXBTb3VyY2UuQ2xvbmUoKTsgc25hcHNob3QuRnJlZXplKCk7DQogICAgICAgICAgICAgICAgICAgICAgICBsb2NrIChfZ2F0ZSkgew0KICAgICAgICAgICAgICAgICAgICAgICAgICAgIGlmIChfY2xvc2VkKSByZXR1cm47DQogICAgICAgICAgICAgICAgICAgICAgICAgICAgLy8gQSByZXBsYWNlZCBzZWVrIG11c3QgbmV2ZXIgcHVibGlzaCBpdHMgb2Jzb2xldGUgaW1hZ2UuDQogICAgICAgICAgICAgICAgICAgICAgICAgICAgaWYgKHZlcnNpb24gPT0gX3ZlcnNpb24pIHsgX2NvbXBsZXRlZCA9IHNuYXBzaG90OyBfY29tcGxldGVkSW5kZXggPSBwbGF5ZXIuQ3VycmVudEZyYW1lSW5kZXg7IF9jb21wbGV0ZWRWZXJzaW9uID0gdmVyc2lvbjsgfQ0KICAgICAgICAgICAgICAgICAgICAgICAgfQ0KICAgICAgICAgICAgICAgICAgICB9DQogICAgICAgICAgICAgICAgICAgIGxvY2sgKF9nYXRlKSB7IGlmIChfY2xvc2VkKSByZXR1cm47IGlmIChfcGVuZGluZykgY29udGludWU7IH0NCiAgICAgICAgICAgICAgICAgICAgX3dha2UuV2FpdE9uZSgpOw0KICAgICAgICAgICAgICAgIH0NCiAgICAgICAgICAgIH0NCiAgICAgICAgfSBjYXRjaCAoRXhjZXB0aW9uIGV4KSB7DQogICAgICAgICAgICBsb2NrIChfZ2F0ZSkgeyBpZiAoIV9jbG9zZWQpIHsgTG9hZEVycm9yID0gZXguTWVzc2FnZTsgSXNMb2FkZWQgPSBmYWxzZTsgfSB9DQogICAgICAgIH0gZmluYWxseSB7IF93YWtlLkRpc3Bvc2UoKTsgfQ0KICAgIH0NCiAgICBwdWJsaWMgdm9pZCBDbG9zZSgpIHsNCiAgICAgICAgbG9jayAoX2dhdGUpIHsNCiAgICAgICAgICAgIGlmIChfY2xvc2VkKSByZXR1cm47DQogICAgICAgICAgICBfY2xvc2VkID0gdHJ1ZTsgSXNMb2FkZWQgPSBmYWxzZTsgX3BlbmRpbmcgPSBmYWxzZTsgX2NvbXBsZXRlZCA9IG51bGw7IEJpdG1hcFNvdXJjZSA9IG51bGw7DQogICAgICAgICAgICAvLyBUaGUgd29ya2VyIG93bnMgZXZlbnQgZGlzcG9zYWwgYWZ0ZXIgaXQgaGFzIHJlbGVhc2VkIGRlY29kZXIgcmVzb3VyY2VzLg0KICAgICAgICAgICAgaWYgKF90aHJlYWQgIT0gbnVsbCAmJiBfdGhyZWFkLklzQWxpdmUpIHsgdHJ5IHsgX3dha2UuU2V0KCk7IH0gY2F0Y2ggKE9iamVjdERpc3Bvc2VkRXhjZXB0aW9uKSB7IH0gfQ0KICAgICAgICAgICAgZWxzZSBpZiAoX3RocmVhZCA9PSBudWxsKSBfd2FrZS5EaXNwb3NlKCk7DQogICAgICAgIH0NCiAgICAgICAgLy8gTmV2ZXIgd2FpdCB3aGlsZSBob2xkaW5nIHRoZSBwdWJsaWNhdGlvbiBsb2NrLiBBIHNsb3cgaW4tZmxpZ2h0IHNlZWsgbWF5DQogICAgICAgIC8vIGZpbmlzaCBhZnRlciB0aGlzIGJvdW5kOyB0aGUgYmFja2dyb3VuZCB3b3JrZXIgc3RpbGwgb3ducyBpdHMgY2xlYW51cC4NCiAgICAgICAgaWYgKF90aHJlYWQgIT0gbnVsbCAmJiBfdGhyZWFkICE9IFN5c3RlbS5UaHJlYWRpbmcuVGhyZWFkLkN1cnJlbnRUaHJlYWQgJiYgX3RocmVhZC5Jc0FsaXZlKSBfdGhyZWFkLkpvaW4oMTAwKTsNCiAgICB9DQogICAgcHVibGljIHZvaWQgRGlzcG9zZSgpIHsgQ2xvc2UoKTsgfQ0KfQ0K'
    $wpfGifPlayerCode = [System.Text.Encoding]::UTF8.GetString([System.Convert]::FromBase64String($wpfGifPlayerB64))
    try {
        Add-Type -TypeDefinition $wpfGifPlayerCode -ReferencedAssemblies PresentationCore, PresentationFramework, WindowsBase, System.Xaml
    } catch {
        # Bao lai sau khi log/toast san sang (Report-StartupGifError).
        $script:gifAddTypeError = $_.Exception.Message
        $script:gifAddTypeErrorDetail = [string]$_
    }
}
$script:gifPlayer = $null
$script:gifSelectionGeneration = 0
$script:gifSelectionWorker = $null
$script:gifCancelledWorkers = New-Object System.Collections.ArrayList
if (([System.Management.Automation.PSTypeName]'WpfGifPlayer').Type) {
    try { $script:gifPlayer = New-Object WpfGifPlayer } catch {
        if (-not $script:gifAddTypeError) { $script:gifAddTypeError = $_.Exception.Message; $script:gifAddTypeErrorDetail = [string]$_ }
    }
}
try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch { <# bo qua: khong co console khi chay an #> }

$scriptPath = if ($MyInvocation.MyCommand.Path) { $MyInvocation.MyCommand.Path } elseif ($PSScriptRoot) { Join-Path $PSScriptRoot 'kid-fby-gui.ps1' } else { (Get-Location).Path }
$scriptDir = Split-Path $scriptPath -Parent
if (-not (Test-Path -LiteralPath (Join-Path $scriptDir 'kid-fby.ps1'))) {
    if (Test-Path -LiteralPath (Join-Path $scriptDir 'core\kid-fby.ps1')) {
        $scriptDir = Join-Path $scriptDir 'core'
    }
}
$engine = Join-Path $scriptDir 'kid-fby.ps1'
$linkHelper = Join-Path $scriptDir 'facebook-links.ps1'
if (Test-Path -LiteralPath $linkHelper) { . $linkHelper }
if (-not (Test-Path -LiteralPath $engine)) {
    $cand = Join-Path (Split-Path $scriptDir -Parent) 'core\kid-fby.ps1'
    if (Test-Path -LiteralPath $cand) { $engine = $cand }
}
$root = if ((Split-Path $scriptDir -Leaf) -in @('core','src','app')) {
    Split-Path $scriptDir -Parent
} else {
    $scriptDir
}
$script:whisperLanguageHelperAvailable = $false
$whisperLanguageHelper = Join-Path $scriptDir 'whisper-language.ps1'
if (Test-Path -LiteralPath $whisperLanguageHelper) {
    try {
        . $whisperLanguageHelper
        $script:whisperLanguageHelperAvailable = [bool](Get-Command 'Get-WhisperPaths' -ErrorAction SilentlyContinue)
    } catch { $script:whisperLanguageHelperAvailable = $false }
}
$script:verLocal = '1.0.0'
try {
    $vf = Join-Path $scriptDir 'version.txt'
    if (Test-Path -LiteralPath $vf) { $script:verLocal = (Get-Content -LiteralPath $vf -Raw).Trim() }
} catch { <# bo qua: khong doc duoc version.txt thi dung 1.0.0 #> }

# ------------------------------------------------------------- log ben tren dia ----
# Goc app = thu muc cha cua core. Loi ghi log khong bao gio duoc lam hong UI.
$script:logDir = Join-Path $root 'logs'
$script:fileLogPending = [System.Text.StringBuilder]::new()
$script:fileLogError = $null
$script:fileLogErrorReported = $false
$script:fileLogMaxBytes = 5MB

function Get-GuiLogPath {
    return (Join-Path $script:logDir ('gui-' + (Get-Date).ToString('yyyyMMdd') + '.log'))
}

function Write-FileLog {
    param([string]$Text, [switch]$Immediate)
    try {
        [void]$script:fileLogPending.Append((Get-Date).ToString('yyyy-MM-dd HH:mm:ss.fff')).Append('  ').Append($Text).Append("`r`n")
        if ($Immediate -or $script:fileLogPending.Length -gt 65536) { Flush-FileLog }
    } catch {
        $script:fileLogError = $_.Exception.Message
    }
}

function Write-FileLogLimited {
    # Ghi log co gioi han tan suat cho duong nong (timer 30 lan/giay, keo logo...): moi Key toi da 1 dong / MinSeconds, kem so lan bi nen.
    param([string]$Key, [string]$Text, [double]$MinSeconds = 30)
    if (-not $script:logLimitState) { $script:logLimitState = @{} }
    $now = [Diagnostics.Stopwatch]::GetTimestamp()
    $st = $script:logLimitState[$Key]
    if ($st -and (($now - $st.Last) / [double][Diagnostics.Stopwatch]::Frequency) -lt $MinSeconds) { $st.Skipped++; return }
    $extra = $(if ($st -and $st.Skipped -gt 0) { " (lap lai $($st.Skipped) lan)" } else { '' })
    $script:logLimitState[$Key] = @{ Last = $now; Skipped = 0 }
    Write-FileLog ($Text + $extra)
}

function Flush-FileLog {
    if ($script:fileLogPending.Length -eq 0) { return }
    $chunk = $script:fileLogPending.ToString()
    [void]$script:fileLogPending.Clear()
    try {
        [void][System.IO.Directory]::CreateDirectory($script:logDir)
        $path = Get-GuiLogPath
        $info = [System.IO.FileInfo]::new($path)
        if ($info.Exists -and $info.Length -gt $script:fileLogMaxBytes) {
            $rotated = Join-Path $script:logDir ('gui-' + (Get-Date).ToString('yyyyMMdd-HHmmss') + '-' + [Guid]::NewGuid().ToString('N').Substring(0, 6) + '.log')
            [System.IO.File]::Move($path, $rotated)
        }
        [System.IO.File]::AppendAllText($path, $chunk, [System.Text.UTF8Encoding]::new($false))
        $script:fileLogError = $null
    } catch {
        # Khong nem lai: chi ghi nho de bao mot lan tren log hien thi.
        $script:fileLogError = $_.Exception.Message
    }
}

function Write-CrashLog {
    param([string]$Source, $Exception, [string]$ScriptStack = '')
    try {
        [void][System.IO.Directory]::CreateDirectory($script:logDir)
        $path = Join-Path $script:logDir ('crash-' + (Get-Date).ToString('yyyyMMdd-HHmmss') + '.log')
        $sb = [System.Text.StringBuilder]::new()
        [void]$sb.AppendLine("Kid FB.Y v$($script:verLocal) - crash $((Get-Date).ToString('o'))")
        [void]$sb.AppendLine("Nguon: $Source")
        [void]$sb.AppendLine("PowerShell: $($PSVersionTable.PSVersion) · OS: $([Environment]::OSVersion.VersionString)")
        if ($ScriptStack) { [void]$sb.AppendLine('--- ScriptStackTrace ---'); [void]$sb.AppendLine($ScriptStack) }
        if ($Exception -and $Exception.PSObject.Properties.Name -contains 'ErrorRecord' -and $Exception.ErrorRecord -and $Exception.ErrorRecord.ScriptStackTrace) {
            [void]$sb.AppendLine('--- ErrorRecord.ScriptStackTrace ---'); [void]$sb.AppendLine([string]$Exception.ErrorRecord.ScriptStackTrace)
        }
        [void]$sb.AppendLine('--- Exception ---'); [void]$sb.AppendLine([string]$Exception)
        [System.IO.File]::WriteAllText($path, $sb.ToString(), [System.Text.UTF8Encoding]::new($false))
        Write-FileLog "CRASH ($Source): $(if ($Exception) { $Exception.Message }) -> $path" -Immediate
        return $path
    } catch {
        $script:fileLogError = $_.Exception.Message
        return $null
    }
}

function Show-KidMessageBox {
    # MessageBox he thong (chi dung khi giao dien chua san sang hoac hop thoai theo theme loi).
    # KID_FBY_NO_MSGBOX=1 (kiem thu/build): khong bat hop thoai len man hinh, chi ghi log va tra ve nut mac dinh.
    param([string]$Message, [string]$Title = 'Kid FB.Y', [string]$Buttons = 'OK', [string]$Icon = 'Error', [string]$Default = '')
    if ($env:KID_FBY_NO_MSGBOX -eq '1') {
        Write-FileLog "MSGBOX (an) $Title :: $Message" -Immediate
        return $(if ($Default) { $Default } elseif ($Buttons -eq 'YesNo') { 'No' } else { 'OK' })
    }
    if ($Default) { return [System.Windows.MessageBox]::Show($Message, $Title, $Buttons, $Icon, $Default) }
    return [System.Windows.MessageBox]::Show($Message, $Title, $Buttons, $Icon)
}

function Remove-OldGuiLogs {
    # G-R12: log GUI/crash cu hon 14 ngay bi xoa khi khoi dong (chi trong thu muc logs cua app).
    param([int]$Days = 14)
    $removed = 0
    try {
        if (-not [System.IO.Directory]::Exists($script:logDir)) { return 0 }
        $limit = (Get-Date).AddDays(-$Days)
        foreach ($f in [System.IO.DirectoryInfo]::new($script:logDir).GetFiles('*.log')) {
            if ($f.Name -notmatch '^(gui|crash)-\d{8}') { continue }
            if ($f.LastWriteTime -ge $limit) { continue }
            try { $f.Delete(); $removed++ }
            catch { Write-FileLog "WARN Không xóa được log cũ '$($f.FullName)': $($_.Exception.Message)" }
        }
        if ($removed) { Write-FileLog "INFO Đã xóa $removed file log cũ hơn $Days ngày." }
    } catch { Write-FileLog "WARN Dọn log cũ: $($_.Exception.Message)" }
    return $removed
}

# ------------------------------------------------------------- phong chu Nunito (core\ui\fonts, giay phep OFL) ----
$script:fontDir = $null
function Set-KidFontResources {
    # Thay FontUi/FontUiSemibold/FontUiBold trong theme bang Nunito neu co file font; thieu -> giu Segoe UI.
    param([System.Windows.ResourceDictionary]$Dictionary)
    if (-not $Dictionary -or -not $script:fontDir) { return $false }
    $regular = Join-Path $script:fontDir 'Nunito-Regular.ttf'
    if (-not [System.IO.File]::Exists($regular)) { return $false }
    try {
        $base = [Uri]::new(([System.IO.Path]::GetFullPath($script:fontDir).TrimEnd('\') + '\'))
        $Dictionary['FontUi'] = [System.Windows.Media.FontFamily]::new($base, './#Nunito, Segoe UI')
        $Dictionary['FontUiSemibold'] = [System.Windows.Media.FontFamily]::new($base, './#Nunito SemiBold, Segoe UI Semibold')
        $Dictionary['FontUiBold'] = [System.Windows.Media.FontFamily]::new($base, './#Nunito ExtraBold, Segoe UI Black')
        return $true
    } catch {
        Write-FileLog "WARN Không nạp được phông Nunito: $($_.Exception.Message)"
        return $false
    }
}

# ------------------------------------------------------------- giao dien (core\ui\*.xaml) ----
# Cay cua so nam o core\ui\MainWindow.xaml, token/style o core\ui\Theme.xaml (nhung trong launcher).
# Theme duoc merge vao Window.Resources trong code nen MainWindow chi dung DynamicResource.
$script:uiDir = Join-Path $scriptDir 'ui'
$script:fontDir = Join-Path $script:uiDir 'fonts'
function Read-KidXamlFile {
    param([string]$Name)
    $path = Join-Path $script:uiDir $Name
    if (-not [System.IO.File]::Exists($path)) {
        throw [System.IO.FileNotFoundException]::new("Thiếu file giao diện: $path. Hãy mở lại bằng Kid-FB.Y.exe để khôi phục hoặc cài lại bản đầy đủ.", $path)
    }
    $text = [System.IO.File]::ReadAllText($path, [System.Text.Encoding]::UTF8)
    try { return [Windows.Markup.XamlReader]::Parse($text) }
    catch { throw [System.InvalidOperationException]::new("File giao diện lỗi ($Name): $($_.Exception.Message)", $_.Exception) }
}
try {
    $script:themeDictionary = Read-KidXamlFile 'Theme.xaml'
    if ($script:themeDictionary -isnot [System.Windows.ResourceDictionary]) { throw 'Theme.xaml không phải ResourceDictionary.' }
    $script:fontsLoaded = Set-KidFontResources $script:themeDictionary
    $win = Read-KidXamlFile 'MainWindow.xaml'
    if ($win -isnot [System.Windows.Window]) { throw 'MainWindow.xaml không phải Window.' }
    [void]$win.Resources.MergedDictionaries.Add($script:themeDictionary)
} catch {
    $uiLoadError = $_.Exception
    $crash = Write-CrashLog -Source 'XamlLoad' -Exception $uiLoadError -ScriptStack ([string]$_.ScriptStackTrace)
    if ($SelfTest) { Write-Error ("Không nạp được giao diện: " + $uiLoadError.Message) -ErrorAction Continue; exit 1 }
    Show-KidMessageBox -Message ("Không nạp được giao diện Kid FB.Y.`r`n`r`n$($uiLoadError.Message)" +
        $(if ($crash) { "`r`n`r`nChi tiết: $crash" } else { '' })) | Out-Null
    exit 1
}

function Get-Brush {
    # Mau giao dien lay tu token Theme.xaml (khong dung ma hex trong code).
    param([Parameter(Mandatory)][string]$Token)
    $brush = $null
    try { $brush = $win.TryFindResource($Token) } catch { $brush = $null }
    if ($brush -is [System.Windows.Media.Brush]) { return $brush }
    if (-not $script:missingBrushTokens) { $script:missingBrushTokens = @{} }
    if (-not $script:missingBrushTokens.ContainsKey($Token)) {
        $script:missingBrushTokens[$Token] = $true
        Write-FileLog "WARN Thiếu token màu '$Token' trong Theme.xaml; dùng TextPrimary."
    }
    $fallback = $win.TryFindResource('TextPrimary')
    if ($fallback -is [System.Windows.Media.Brush]) { return $fallback }
    return [System.Windows.SystemColors]::ControlTextBrush
}
# Moi ten control code dung qua $ui[...] (SelfTest kiem tung ten + quet tham chieu $ui.X trong script).
$script:uiNames = @(
    'RootGrid','TxtAppVersion','HeaderBadges','ChipDevice','ChipDeviceDot','ChipDeviceText','ChipTools','ChipToolsDot','ChipToolsText',
    'BtnWinMin','BtnWinMax','BtnWinClose','BodyGrid','ColSidebar','ColPage','ColPreview','SidebarBorder','SidebarScroll','SidebarDeco','WashiLeft','WashiRight',
    'PolicyStrip','BtnPolicyHelp','PopPolicy','TxtOutShort','RowPreviewDeco','RowPreviewBar','PreviewDeco','BtnPreviewExpand','PlayBarHost',
    'TxtCopyLabel','TxtCopyIcon','BtnMore','MenuMore','PillUnverified','TxtCountUnverified',
    'NavSource','NavBrand','NavQueue','NavLibrary','NavSettings','PageHost',
    'ViewSource','BtnPasteLinks','BtnImportLinks','BtnClearLinks','TxtLinks','TxtLinksPlaceholder','TxtLinkSummary','TxtDuplicateWarning',
    'TxtSumLinks','TxtSumDup','TxtSumRejected','TxtSumRun',
    'PanelDupChoice','RbDupSkip','RbDupRedownload','TxtOut','BtnOpenOut','TxtLanguagePolicy',
    'ViewBrand','TxtWatermarkSummary','ChkWatermark','ImgLogoPreview','TxtLogoName','TxtLogoPath','TxtLogoDefaultHint','BtnPickLogo','BtnDefaultLogo',
    'SldLogoSize','TxtLogoSize','SldLogoFade','TxtLogoFade','CmbLogoMode','PanelLogoPosition','CmbLogoPosition',
    'ChkGif','ImgGifPreview','TxtGifName','TxtGifPath','BtnPickGif','SldGifSize','TxtGifSize','CmbGifPosition','BtnGifFullFrame',
    'BtnSelectLogo','BtnSelectGif','BtnReedit',
    'ViewQueue','TxtQueueHeader','QueueList','QueueEmpty','TxtStepTitle','StepList',
    'ViewLibrary','TxtGalleryCount','TabLibVideos','TabLibRejected','TxtRejectedTabLabel','PanelLibFilters','TxtGallerySearch','TxtGallerySearchHint',
    'CmbDateFilter','CmbFilterSpecificDate','CmbKho','BtnKhoManage','PanelStatusTabs','TabStAll','TabStPending','TabStHeld','TabStPosted','BtnMoveSelected','TxtMoveSelected','BtnSpreadSelected','PanelDownloadKho','CmbDownloadKho','BtnRefreshGallery','PanelLibVideos','GalleryList',
    'GalleryState','TxtGalleryStateGlyph','TxtGalleryStateTitle','TxtGalleryStateText','PanelLibRejected','TxtRejectedDashboard','RejectedList',
    'ImgGalleryMascot','BadgeGalleryGlyph','BtnGalleryRetry','PanelSelBar','TxtSelCount','BtnClearSelection','PanelKhoEmptyActions','BtnKhoEmptyImport','BtnKhoEmptyManage',
    'ViewSettings','SetTabTools','SetTabGeneral','SetTabLogs','SetTabUpdate','SetTabAbout','ViewTools','BtnCheck','BtnInstallAllTools',
    'ViewGeneral','ChkAllowOnsetSync','TxtCacheInfo','BtnCleanLegacy','BtnClearCache','TxtCleanupDays','BtnCleanupOld',
    'BadgeStatusScrcpy','TxtStatusScrcpy','BtnInstallScrcpy','BadgeStatusAdb','TxtStatusAdb','BtnInstallAdb',
    'BadgeStatusYtdlp','TxtStatusYtdlp','BtnInstallYtdlp','BadgeStatusFfmpeg','TxtStatusFfmpeg','BtnInstallFfmpeg',
    'BadgeStatusWhisper','TxtStatusWhisper','BtnInstallWhisper','BtnCheckTools','BtnOpenUninstall',
    'CardChrome','BtnChromeGuide','BtnChromeFolder','BtnChromePair','TxtChromeInfo','PanelChromeCode','TxtChromeCode','TxtChromeCountdown','TxtChromeStatus','ListChromeClients','ListChromeAccounts',
    'BadgeAutotok','TxtAutotokBadge','BtnAutotokInstall','TxtAutotokInfo','TxtAutotokProgress','BarAutotok','BtnAutotokChrome',
    'ViewLogs','TxtLogPath','BtnCopyLog','BtnOpenLogFolder','BtnClearLog','TxtLog',
    'ViewUpdate','BtnUpdate','TxtUpdateButton','TxtUpdateInfo','ViewAbout','TxtAboutVersion',
    'PreviewPane','BadgeRes','TxtRes','BtnTrackB','BtnTrackA','PanelRev','BtnCopyReup','BtnRedo','BtnFolder','BtnDeleteCurrent',
    'PanelPlay','Seek','BtnPlay','TxtTime','BtnOpenExt','ViewportGrid','PhoneFrame','PlayerContainer','Player','CanvasWatermark',
    'BoxLogoOverlay','BorderLogoOverlay','ImgVideoWatermark','GripLogoResize','GripLogoResizeNW','GripLogoResizeNE','GripLogoResizeSW',
    'GripLogoResizeN','GripLogoResizeS','GripLogoResizeW','GripLogoResizeE',
    'BoxGifOverlay','BorderGifOverlay','ImgVideoGif','GripGifResize','GripGifResizeNW','GripGifResizeNE','GripGifResizeSW',
    'GripGifResizeN','GripGifResizeS','GripGifResizeW','GripGifResizeE',
    'BadgePreviewMode','TxtPreviewMode','TxtNoVid','PreviewSample','TxtLogoMotionHint','PhoneShell','ImgNoVid','TxtNoVidTitle','TxtNoVidText',
    'BandLayer','BandRect','SpreadBar','TxtSpreadStatus','SpreadProgress','BtnSpreadStop','ActionBar','BtnStart','TxtStartGlyph','TxtStartLabel','TxtProgress','TxtStat','TxtCurrentItem','Bar',
    'TxtCountSaved','TxtCountRejected','TxtCountSkipped','TxtCountFailed','PillSaved','PillRejected','PillSkipped','PillFailed','NotificationHost')
$ui = @{}
foreach ($n in $script:uiNames) {
    $ui[$n] = $win.FindName($n)
}
$ui.TxtOut.Text = Join-Path $root 'output'
if ($ui.TxtAppVersion) { $ui.TxtAppVersion.Text = "v$($script:verLocal)" }

# ------------------------------------------------------------- trang thai ----
$script:ps            = $null
$script:handle        = $null
$script:seen          = 0
$script:mode          = ''
$script:queue         = @()
$script:idx           = 0
$script:lastOut       = ''
$script:runLog        = [System.Text.StringBuilder]::new()   # nhat ky engine cua lan chay hien tai (StringBuilder: khong cong chuoi O(n^2))
$script:giu           = 0
$script:bo            = 0
$script:loi           = 0
$script:chuaXN        = 0      # "Chua xac nhan" (unverified): dem rieng, KHONG tinh vao "loi"
$script:narrowBar     = $false
$script:failedLinks   = @()
$script:lastCompletedOut = ''
$script:keoSeek       = $false
$script:wasPlaying    = $false
$script:stopping      = $false
$script:stopHandle    = $null
$script:childProcesses = [hashtable]::Synchronized(@{})
$script:seenErrors    = 0
$script:logoCustomX   = -1.0
$script:logoCustomY   = -1.0
$script:logoCustomWidth = -1.0
$script:logoCustomHeight = -1.0
$script:gifCustomX    = -1.0
$script:gifCustomY    = -1.0
$script:gifCustomWidth = -1.0
$script:gifCustomHeight = -1.0
$script:gifFullFrame = $false
$script:gifApplyingFullFrame = $false
$script:uiBusy = $false
$script:dragTarget    = $null
$script:dragStartPt   = $null
$script:dragStartPos  = $null
$script:dragStartSize = $null
$script:loggedErrors  = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
$script:cancelRequested = $false
$script:closeAfterStop = $false
$script:activeTrack   = 'B'
$script:filterDate    = 'all'
$script:filterKho     = 'all'  # 'all' hoac ma kho
$script:filterStatus  = 'all'  # all | pending | held | posted
$script:boTruoc       = 0      # link bo qua vi da loai truoc (loc luc bam Bat dau hoac engine bao already-rejected)
$script:currentResult = $null  # @@KIDFBY_RESULT cua muc dang chay
$script:queueFinalizedIdx = -1 # chi so muc da duoc tinh ket qua (chong dem trung khi tick loi)
$script:forceRetryRejected = $false
$script:logoLastPresetIdx = 3
$script:gifLastPresetIdx  = 1
$script:tickErrorKey  = ''
$script:tickErrorRepeat = 0
$script:settingsLoading = $false
$script:settingsPath  = Join-Path $root 'data\settings.json'
$script:settingsReadLocked = $false  # doc settings.json bi loi IO (khong phai file hong) -> khong ghi trong phien
$script:settingsReady = $false   # chi luu sau khi da nap xong, tranh ghi de file cua nguoi dung bang mac dinh

$script:tSettings     = $null
# Mo hinh du lieu giao dien (ObservableCollection cua PSCustomObject; chi cap nhat tren UI thread/Dispatcher).
$script:queueRows     = New-Object 'System.Collections.ObjectModel.ObservableCollection[object]'
$script:queueRowByIdx = @{}    # chi so trong $script:queue -> vi tri dong trong $script:queueRows
$script:queueTotal    = 0
$script:skipExisting  = 0      # video da co trong kho, nguoi dung chon bo qua
$script:stepRows      = New-Object 'System.Collections.ObjectModel.ObservableCollection[object]'
$script:galleryAll    = @()    # moi video da quet (truoc bo loc)
$script:galleryRows   = New-Object 'System.Collections.ObjectModel.ObservableCollection[object]'
$script:rejectedRows  = New-Object 'System.Collections.ObjectModel.ObservableCollection[object]'
$script:galleryIndexByPath = @{}    # duong dan -> vi tri trong $script:galleryAll (G-R7: khong quet O(N^2))
$script:galleryRowIndexByPath = @{} # duong dan -> vi tri trong $script:galleryRows (danh sach dang hien)
$script:gallerySyncing = $false     # dang dong bo ObservableCollection: bo qua SelectionChanged
$script:galleryScanReady = $false   # chi quet Kho (tao anh thu nho) sau khi da nap settings.json
$script:mediaWorkersStopping = New-Object System.Collections.ArrayList  # worker dang dung, cho Dispose (G-R9)
$script:choiceDialogAutoAnswer = $null  # kiem thu tu dong: chi so lua chon (-1 = Huy); $null = hien hop thoai that
$script:galleryGen    = 0
$script:galleryState  = 'idle'  # idle | loading | ready | error
$script:galleryLastBuildMs = 0.0
$script:probeCache    = @{}     # duong dan -> ket qua ffprobe/thumbnail tu media worker
$script:thumbCache    = @{}     # duong dan anh thu nho -> BitmapImage da Freeze
$script:filterSearch  = ''
$script:currentPage   = 'source'
$script:switchingPage = $false
$script:confirmDialogAutoAnswer = $null  # chi dung cho kiem thu tu dong (harness); $null = hien hop thoai that
$script:lastConfirmDialog = $null
$script:linkSummary   = $null
$script:lastQueueEnd  = $null    # @{ Stopped; Time } cua hang doi gan nhat (thanh day: "Hoan tat/Da dung luc HH:mm")
# ------------------------------------------------------------- cai dat nguoi dung (data\settings.json) ----
function Read-KidSettings {
    # Tra ve doi tuong cai dat hoac $null (khong co file / file hong -> doi ten .corrupt-<ts>).
    # V13: loi DOC (file bi khoa tam: IOException/UnauthorizedAccess...) KHAC file hong: thu lai 3 lan cach 300 ms;
    # van loi -> $null + settingsReadLocked (phien nay dung mac dinh va KHONG ghi settings.json), tuyet doi khong doi ten .corrupt.
    param([string]$Path)
    $script:settingsReadLocked = $false
    if (-not [System.IO.File]::Exists($Path)) { return $null }
    $json = $null; $readErr = ''
    for ($attempt = 1; $attempt -le 3; $attempt++) {
        try { $json = [System.IO.File]::ReadAllText($Path, [System.Text.Encoding]::UTF8); $readErr = ''; break }
        catch {
            $readErr = $_.Exception.Message
            Write-FileLog "WARN doc cai dat lan $attempt/3 that bai: $readErr"
            if ($attempt -lt 3) { Start-Sleep -Milliseconds 300 }
        }
    }
    if ($null -eq $json) {
        $script:settingsReadLocked = $true
        Add-Log "Không đọc được file cài đặt (đang bị khóa?): $readErr. Phiên này dùng cài đặt mặc định và không ghi đè settings.json." 'Warning'
        # Khong tra $null (se bi nham voi "khong co file/file hong"): tra dau hieu rieng; Import-UserSettings doc dau hieu nay.
        return [pscustomobject]@{ __readLocked = $true; __readError = [string]$readErr }
    }
    try {
        if ([string]::IsNullOrWhiteSpace($json) -or -not $json.TrimStart().StartsWith('{')) { throw 'Không phải đối tượng JSON.' }
        $obj = ConvertFrom-Json -InputObject $json -ErrorAction Stop
        if ($null -eq $obj -or $obj -isnot [pscustomobject]) { throw 'Định dạng cài đặt không hợp lệ.' }
        return $obj
    } catch {
        $err = $_.Exception.Message
        $bad = $Path + '.corrupt-' + (Get-Date).ToString('yyyyMMdd-HHmmss')
        if ([System.IO.File]::Exists($bad)) { $bad += '-' + [Guid]::NewGuid().ToString('N').Substring(0, 6) }
        try {
            [System.IO.File]::Move($Path, $bad)
            Add-Log "File cài đặt bị hỏng ($err); đã đổi tên thành '$bad' và dùng cài đặt mặc định." 'Warning'
        } catch {
            Add-Log "File cài đặt bị hỏng ($err) và không đổi tên được: $($_.Exception.Message). Dùng cài đặt mặc định." 'Warning'
        }
        return $null
    }
}

function Write-KidSettings {
    # Ghi nguyen tu: file tam cung thu muc -> Flush(true) -> File.Replace (hoac Move neu chua co).
    param([string]$Path, $Data)
    $dir = [System.IO.Path]::GetDirectoryName([System.IO.Path]::GetFullPath($Path))
    [void][System.IO.Directory]::CreateDirectory($dir)
    $json = ConvertTo-Json -InputObject $Data -Depth 6 -ErrorAction Stop
    $temp = Join-Path $dir ('.settings-' + [Guid]::NewGuid().ToString('N') + '.tmp')
    try {
        $stream = [System.IO.File]::Open($temp, [System.IO.FileMode]::CreateNew, [System.IO.FileAccess]::Write, [System.IO.FileShare]::None)
        try {
            $bytes = [System.Text.UTF8Encoding]::new($false).GetBytes($json)
            $stream.Write($bytes, 0, $bytes.Length)
            $stream.Flush($true)
        } finally { $stream.Dispose() }
        if ([System.IO.File]::Exists($Path)) { [System.IO.File]::Replace($temp, $Path, [System.Management.Automation.Language.NullString]::Value) }
        else { [System.IO.File]::Move($temp, $Path) }
        $temp = $null
    } finally {
        if ($temp -and [System.IO.File]::Exists($temp)) {
            try { [System.IO.File]::Delete($temp) } catch { Write-FileLog "WARN Không xóa được file tạm cài đặt '$temp': $($_.Exception.Message)" }
        }
    }
}

function Get-SettingsOutDir {
    # outDir trong settings.json la gia tri TUONG THICH = thu muc cua kho tai ve (TxtOut an, dong bo bang Sync-OutDirFromKho).
    # Ban cu cua app doc lai duoc file; ban nay chi dung no de tao kho "Output cũ" o lan mo dau tien.
    return [string]$ui.TxtOut.Text
}

function Get-CurrentSettings {
    $winW = $win.Width; $winH = $win.Height; $state = 'Normal'
    if ($win.WindowState -eq [System.Windows.WindowState]::Maximized) {
        $state = 'Maximized'
        if (-not $win.RestoreBounds.IsEmpty) { $winW = $win.RestoreBounds.Width; $winH = $win.RestoreBounds.Height }
    } elseif ($win.ActualWidth -gt 0) { $winW = $win.ActualWidth; $winH = $win.ActualHeight }
    $gifPath = if ($ui.TxtGifPath -and $ui.TxtGifPath.Text) { $ui.TxtGifPath.Text } elseif ($script:gifSelectionWorker) { [string]$script:gifSelectionWorker.Path } else { '' }
    return [ordered]@{
        version = 1
        outDir  = [string](Get-SettingsOutDir)
        logo = [ordered]@{
            enabled  = [bool]$ui.ChkWatermark.IsChecked
            path     = [string]$ui.TxtLogoPath.Text
            size     = [int]$ui.SldLogoSize.Value
            fade     = [int]$ui.SldLogoFade.Value
            motion   = $(if ($ui.CmbLogoMode.SelectedIndex -eq 1) { 'Fixed' } else { 'Free' })
            position = [int]$ui.CmbLogoPosition.SelectedIndex
            lastPreset = [int]$script:logoLastPresetIdx
            customX = [double]$script:logoCustomX; customY = [double]$script:logoCustomY
            customW = [double]$script:logoCustomWidth; customH = [double]$script:logoCustomHeight
        }
        gif = [ordered]@{
            enabled   = [bool]$ui.ChkGif.IsChecked
            path      = $gifPath
            size      = [int]$ui.SldGifSize.Value
            position  = [int]$ui.CmbGifPosition.SelectedIndex
            lastPreset = [int]$script:gifLastPresetIdx
            fullFrame = [bool]$script:gifFullFrame
            customX = [double]$script:gifCustomX; customY = [double]$script:gifCustomY
            customW = [double]$script:gifCustomWidth; customH = [double]$script:gifCustomHeight
        }
        sync = [ordered]@{ allowOnset = [bool]($ui.ChkAllowOnsetSync -and $ui.ChkAllowOnsetSync.IsChecked) }
        chrome = [ordered]@{ cookieAccounts = @($script:chromeCookieChoice) }
        window = [ordered]@{ width = [double]$winW; height = [double]$winH; state = $state }
    }
}

function ConvertTo-SettingDouble {
    param($Value, [double]$Default = -1.0)
    $d = 0.0
    if ($null -ne $Value -and [double]::TryParse([string]$Value, [System.Globalization.NumberStyles]::Float, [System.Globalization.CultureInfo]::InvariantCulture, [ref]$d) -and
        -not [double]::IsNaN($d) -and -not [double]::IsInfinity($d)) { return $d }
    return $Default
}

function Import-UserSettings {
    param([string]$Path = $script:settingsPath)
    $s = Read-KidSettings -Path $Path
    if (-not $s) { return $false }
    if ($s.PSObject.Properties['__readLocked']) { $script:settingsReadLocked = $true; return $false }   # doc loi IO tam thoi: dung mac dinh, khong ghi trong phien
    $script:settingsLoading = $true
    try {
        # outDir da luu = thu muc cua kho "Output cũ" khi chua co data\kho.json (dung ca khi o rut: kho giu nguyen duong dan, khong doi sang mac dinh).
        if ($s.outDir) { $script:khoLegacyOutDir = [string]$s.outDir }
        $l = $s.logo
        if ($l) {
            if ($null -ne $l.enabled) { $ui.ChkWatermark.IsChecked = [bool]$l.enabled }
            if ($l.path -and [System.IO.File]::Exists([string]$l.path)) {
                try { Set-LogoSelection -Path ([string]$l.path) } catch { Add-Log "Không nạp lại được logo đã lưu: $($_.Exception.Message)" 'Warning' }
            }
            if ($null -ne $l.size) { $ui.SldLogoSize.Value = [Math]::Max($ui.SldLogoSize.Minimum, [Math]::Min($ui.SldLogoSize.Maximum, (ConvertTo-SettingDouble $l.size 30))) }
            if ($null -ne $l.fade) { $ui.SldLogoFade.Value = [Math]::Max($ui.SldLogoFade.Minimum, [Math]::Min($ui.SldLogoFade.Maximum, (ConvertTo-SettingDouble $l.fade 60))) }
            $ui.CmbLogoMode.SelectedIndex = $(if ([string]$l.motion -eq 'Fixed') { 1 } else { 0 })
            $last = [int](ConvertTo-SettingDouble $l.lastPreset 3); if ($last -lt 0 -or $last -gt 4) { $last = 3 }
            $pos = [int](ConvertTo-SettingDouble $l.position 3)
            $ui.CmbLogoPosition.SelectedIndex = $(if ($pos -ge 0 -and $pos -le 4) { $pos } else { $last })
            $script:logoLastPresetIdx = $(if ($pos -ge 0 -and $pos -le 4) { $pos } else { $last })
            # Sau slider (ValueChanged xoa W/H) va preset (SelectionChanged xoa X/Y).
            $script:logoCustomX = ConvertTo-SettingDouble $l.customX; $script:logoCustomY = ConvertTo-SettingDouble $l.customY
            $script:logoCustomWidth = ConvertTo-SettingDouble $l.customW; $script:logoCustomHeight = ConvertTo-SettingDouble $l.customH
            if (Test-LogoHasCustomGeometry) { $ui.CmbLogoPosition.SelectedIndex = $script:positionCustomIndex }
        }
        $g = $s.gif
        if ($g) {
            if ($null -ne $g.size) { $ui.SldGifSize.Value = [Math]::Max($ui.SldGifSize.Minimum, [Math]::Min($ui.SldGifSize.Maximum, (ConvertTo-SettingDouble $g.size 20))) }
            $last = [int](ConvertTo-SettingDouble $g.lastPreset 1); if ($last -lt 0 -or $last -gt 4) { $last = 1 }
            $pos = [int](ConvertTo-SettingDouble $g.position 1)
            $ui.CmbGifPosition.SelectedIndex = $(if ($pos -ge 0 -and $pos -le 4) { $pos } else { $last })
            $script:gifLastPresetIdx = $(if ($pos -ge 0 -and $pos -le 4) { $pos } else { $last })
            if ([bool]$g.fullFrame) {
                $script:gifApplyingFullFrame = $true
                try {
                    $ui.SldGifSize.Value = $ui.SldGifSize.Maximum
                    $script:gifFullFrame = $true
                    $script:gifCustomX = 0.0; $script:gifCustomY = 0.0; $script:gifCustomWidth = -1.0; $script:gifCustomHeight = -1.0
                    if ($ui.BtnGifFullFrame) { $ui.BtnGifFullFrame.Style = $win.FindResource('BtnPrimary') }
                } finally { $script:gifApplyingFullFrame = $false }
            } else {
                $script:gifCustomX = ConvertTo-SettingDouble $g.customX; $script:gifCustomY = ConvertTo-SettingDouble $g.customY
                $script:gifCustomWidth = ConvertTo-SettingDouble $g.customW; $script:gifCustomHeight = ConvertTo-SettingDouble $g.customH
            }
            if (Test-GifHasCustomGeometry) { $ui.CmbGifPosition.SelectedIndex = $script:positionCustomIndex }
            if ($g.path -and [System.IO.File]::Exists([string]$g.path)) {
                try { Set-GifSelection -Path ([string]$g.path) } catch { Add-Log "Không nạp lại được GIF đã lưu: $($_.Exception.Message)" 'Warning' }
            }
            if ($null -ne $g.enabled) { $ui.ChkGif.IsChecked = [bool]$g.enabled }
        }
        # G-C3: dong bo theo am thanh khi khong thu duoc hinh - mac dinh TAT; chi bat khi file luu dung $true.
        if ($ui.ChkAllowOnsetSync) { $ui.ChkAllowOnsetSync.IsChecked = [bool]($s.sync -and $s.sync.allowOnset -eq $true) }
        if ($s.chrome -and $s.chrome.cookieAccounts) { $script:chromeCookieChoice = @(@($s.chrome.cookieAccounts) | ForEach-Object { [string]$_ } | Where-Object { $_ -match '^[0-9]+$' }) }
        $w = $s.window
        if ($w) {
            $ww = ConvertTo-SettingDouble $w.width 0; $wh = ConvertTo-SettingDouble $w.height 0
            if ($ww -ge 600 -and $wh -ge 400) { $win.Width = $ww; $win.Height = $wh }
            if ([string]$w.state -eq 'Maximized') { $win.WindowState = [System.Windows.WindowState]::Maximized }
        }
    } finally { $script:settingsLoading = $false }
    if (Get-Command 'Update-WatermarkOverlay' -ErrorAction SilentlyContinue) { Update-WatermarkOverlay }
    if (Get-Command 'Update-WatermarkSummary' -ErrorAction SilentlyContinue) { Update-WatermarkSummary }
    Add-Log "Đã nạp cài đặt đã lưu: $Path" 'Muted'
    return $true
}

function Initialize-UserSettings {
    # Chi cho phep luu khi nap thanh cong hoac chua co file (file hong da duoc doi ten .corrupt).
    # Import nem loi giua chung -> khong luu trong phien nay de khong ghi de settings.json bang trang thai do.
    $script:settingsReady = $false
    try {
        [void](Import-UserSettings)
        # File bi khoa tam khi doc: dung mac dinh va KHONG ghi settings.json trong phien nay (V13).
        $script:settingsReady = -not $script:settingsReadLocked
        if ($script:settingsReadLocked) { Show-Toast 'Không đọc được cài đặt đã lưu (file đang bị khóa). Phiên này dùng mặc định và không lưu cài đặt.' -Kind warning }
    } catch {
        $script:settingsLoading = $false
        Write-FileLog "ERR  Import-UserSettings: $($_.Exception.Message)`r`n$($_.ScriptStackTrace)" -Immediate
        Add-Log "Không nạp được cài đặt đã lưu: $($_.Exception.Message). Phiên này sẽ không ghi đè settings.json." 'Warning'
    }
    return $script:settingsReady
}

function Save-UserSettings {
    if ($SelfTest -or -not $script:settingsReady) { return }
    if ($script:tSettings) { $script:tSettings.Stop() }
    try { Write-KidSettings -Path $script:settingsPath -Data (Get-CurrentSettings) }
    catch { Add-Log "Không lưu được cài đặt '$($script:settingsPath)': $($_.Exception.Message)" 'Warning' }
}

function Request-SaveSettings {
    # Debounce 1 s: gom nhieu thay doi (keo slider, keo logo) thanh mot lan ghi.
    if ($SelfTest -or $script:settingsLoading -or -not $script:settingsReady) { return }
    if (-not $script:tSettings) {
        $script:tSettings = New-Object Windows.Threading.DispatcherTimer
        $script:tSettings.Interval = [TimeSpan]::FromSeconds(1)
        $script:tSettings.Add_Tick({ Save-UserSettings })
    }
    $script:tSettings.Stop(); $script:tSettings.Start()
}

# ------------------------------------------------------------- ham luu trang thai TikTok ----
function Get-ReupMetadata {
    param([Parameter(Mandatory)][string]$OutDir)
    $p = Join-Path $OutDir 'reup-status.json'
    try {
        # FileShare ReadWrite|Delete: never block the writer's atomic File.Replace.
        $readStream = $null
        for ($readTry = 1; $null -eq $readStream; $readTry++) {
            try { $readStream = [System.IO.FileStream]::new($p, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, ([System.IO.FileShare]::ReadWrite -bor [System.IO.FileShare]::Delete)) }
            catch [System.IO.FileNotFoundException] { throw }
            catch [System.IO.DirectoryNotFoundException] { throw }
            catch [System.IO.IOException] { if ($readTry -ge 5) { throw }; Start-Sleep -Milliseconds 50 }
        }
        try {
            $reader = [System.IO.StreamReader]::new($readStream, [System.Text.Encoding]::UTF8, $true)
            $json = $reader.ReadToEnd()
        } finally { $readStream.Dispose() }
    } catch [System.IO.FileNotFoundException] {
        return [pscustomobject]@{}
    } catch [System.IO.DirectoryNotFoundException] {
        return [pscustomobject]@{}
    } catch {
        throw "Không đọc được lịch sử TikTok '$p': $($_.Exception.Message)"
    }
    try {
        if ([string]::IsNullOrWhiteSpace($json) -or -not $json.TrimStart().StartsWith('{')) { throw 'Lịch sử phải là một đối tượng JSON.' }
        $meta = ConvertFrom-Json -InputObject $json -ErrorAction Stop
        if ($null -eq $meta -or $meta -isnot [pscustomobject]) { throw 'Định dạng lịch sử không hợp lệ.' }
        foreach ($entry in $meta.PSObject.Properties) {
            if ($null -eq $entry.Value -or $entry.Value -isnot [pscustomobject] -or
                $entry.Value.Posted -isnot [bool] -or $entry.Value.Date -isnot [string]) {
                throw "Trạng thái video '$($entry.Name)' không hợp lệ."
            }
        }
        return $meta
    } catch {
        throw "Lịch sử TikTok bị lỗi; dữ liệu được giữ nguyên. File '$p': $($_.Exception.Message)"
    }
}

function Get-CanonicalPath {
    # One identity for a folder (R6): full path without trailing separators, except roots such as C:\.
    # Compare results with OrdinalIgnoreCase (Test-SamePath).
    param([string]$Path)
    $full = [System.IO.Path]::GetFullPath($Path)
    $pathRoot = [System.IO.Path]::GetPathRoot($full)
    if ($full.Length -gt $pathRoot.Length) {
        $full = $full.TrimEnd('\', '/')
        if ($full.Length -lt $pathRoot.Length) { $full = $pathRoot }
    }
    return $full
}

function Test-SamePath {
    param([string]$A, [string]$B)
    if ([string]::IsNullOrWhiteSpace($A) -or [string]::IsNullOrWhiteSpace($B)) { return $false }
    try { return [string]::Equals((Get-CanonicalPath $A), (Get-CanonicalPath $B), [StringComparison]::OrdinalIgnoreCase) }
    catch { return $false }
}

function Get-FileStamp {
    param([string]$Path)
    $info = [System.IO.FileInfo]::new($Path)
    if (-not $info.Exists) { return 'none' }
    return ($info.Length.ToString() + '|' + $info.LastWriteTimeUtc.Ticks)
}

function Get-ReupMutexName {
    # Same name as earlier versions for the same folder, so old and new app copies exclude each other.
    param([string]$StatusPath)
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try { $key = [BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($StatusPath.ToUpperInvariant()))).Replace('-', '') }
    finally { $sha.Dispose() }
    return ('Local\KidFby-ReupMetadata-' + $key)
}

function Update-ReupMetadata {
    # The only writer of reup-status.json: lock, read once, change in memory, atomic replace only when changed.
    # $Change receives the metadata object and returns $true when it modified it. Unknown fields are kept.
    # A corrupt file makes Get-ReupMetadata throw, so it is never overwritten.
    param([string]$OutDir, [scriptblock]$Change, [int]$TimeoutMs = 10000)
    $statusDir = Get-CanonicalPath $OutDir
    $statusFile = Join-Path $statusDir 'reup-status.json'
    $statusMutex = $null
    $statusLocked = $false
    $statusTemp = $null
    try {
        $statusMutex = [System.Threading.Mutex]::new($false, (Get-ReupMutexName $statusFile))
        try { $statusLocked = $statusMutex.WaitOne($TimeoutMs) }
        catch [System.Threading.AbandonedMutexException] { $statusLocked = $true }
        if (-not $statusLocked) { throw 'Lịch sử đang được ứng dụng khác cập nhật. Vui lòng thử lại.' }
        $statusMeta = Get-ReupMetadata -OutDir $statusDir
        $statusChanged = [bool](@(& $Change $statusMeta) | Select-Object -Last 1)
        if ($statusChanged) {
            [System.IO.Directory]::CreateDirectory($statusDir) | Out-Null
            $statusJson = ConvertTo-Json -InputObject $statusMeta -Depth 12 -ErrorAction Stop
            $statusTemp = Join-Path $statusDir ('.reup-status-' + [Guid]::NewGuid().ToString('N') + '.tmp')
            $statusStream = [System.IO.File]::Open($statusTemp, [System.IO.FileMode]::CreateNew, [System.IO.FileAccess]::Write, [System.IO.FileShare]::None)
            try {
                $statusBytes = [System.Text.UTF8Encoding]::new($false).GetBytes($statusJson)
                $statusStream.Write($statusBytes, 0, $statusBytes.Length)
                $statusStream.Flush($true)
            } finally { $statusStream.Dispose() }
            for ($statusTry = 1; ; $statusTry++) {
                try {
                    if ([System.IO.File]::Exists($statusFile)) { [System.IO.File]::Replace($statusTemp, $statusFile, [System.Management.Automation.Language.NullString]::Value) }
                    else { [System.IO.File]::Move($statusTemp, $statusFile) }
                    break
                } catch [System.IO.IOException] {
                    if ($statusTry -ge 5) { throw }
                    Start-Sleep -Milliseconds (50 + 25 * $statusTry)
                }
            }
            $statusTemp = $null
        }
        return [pscustomobject]@{ Changed = $statusChanged; Stamp = (Get-FileStamp $statusFile); Metadata = $statusMeta }
    } catch {
        throw "Không lưu được lịch sử TikTok. Dữ liệu cũ được giữ nguyên. $($_.Exception.Message)"
    } finally {
        if ($statusTemp -and [System.IO.File]::Exists($statusTemp)) { try { [System.IO.File]::Delete($statusTemp) } catch { <# bo qua: file tam, loi xoa khong anh huong ket qua #> } }
        if ($statusLocked) { $statusMutex.ReleaseMutex() }
        if ($statusMutex) { $statusMutex.Dispose() }
    }
}

function Set-ReupField {
    param($Item, [string]$Name, $Value)
    if ($Item.PSObject.Properties[$Name]) { $Item.$Name = $Value }
    else { $Item | Add-Member -MemberType NoteProperty -Name $Name -Value $Value -Force }
}

function Get-ReupManualState {
    # Manual "posted" mark (D3). Items written before the TikTok bridge only have Posted/Date: that is the manual mark.
    param($Item)
    if (-not $Item) { return @{ Posted = $false; Date = '' } }
    if ($Item.PSObject.Properties['ManualPosted']) { return @{ Posted = [bool]$Item.ManualPosted; Date = [string]$Item.ManualDate } }
    if ($Item.Source -ne 'autotok-history') { return @{ Posted = [bool]$Item.Posted; Date = [string]$Item.Date } }
    return @{ Posted = $false; Date = '' }
}

function Update-ReupAggregate {
    # Posted/Date stay readable by older app versions: posted = manual mark OR a succeeded TikTok post.
    param($Item)
    $manual = Get-ReupManualState $Item
    $success = @(@($Item.History) | Where-Object { $_ -and [string]$_.status -eq 'succeeded' } | Sort-Object { Get-TikTokSortKey ([string]$_.accepted_at) } -Descending)
    Set-ReupField $Item 'Posted' ([bool]($manual.Posted -or $success.Count))
    Set-ReupField $Item 'Date' $(if ($success.Count) { Format-TikTokTime $(if ([string]$success[0].tiktok_schedule_time) { [string]$success[0].tiktok_schedule_time } else { [string]$success[0].accepted_at }) -Short } elseif ($manual.Posted) { [string]$manual.Date } else { '' })
}

function Set-ReupMetadata {
    # Manual posted mark (D3). Only the manual flag flips; synced TikTok history is kept as-is.
    param([string]$VideoId, [bool]$Posted, [Parameter(Mandatory)][string]$OutDir)
    if ([string]::IsNullOrWhiteSpace($VideoId)) { throw 'Thiếu ID video để lưu lịch sử TikTok.' }
    if (Test-KhoIdReserved $OutDir $VideoId) { throw "$(Get-ReelLabel $VideoId) đang có lần chuyển kho chưa hoàn tất; xử lý trong Quản lý kho rồi thử lại." }
    $markDate = (Get-Date).ToString('dd/MM HH:mm')
    [void](Update-ReupMetadata -OutDir $OutDir -Change {
        param($meta)
        $property = $meta.PSObject.Properties[$VideoId]
        $item = if ($property) { $property.Value } else { $null }
        if (-not $item) {
            # S6: never create an entry for a video whose -3 is no longer in this folder (moved or deleted).
            if (-not [System.IO.File]::Exists((Get-KhoVideoPath $OutDir $VideoId))) { throw "$(Get-ReelLabel $VideoId) không còn trong thư mục kho này (đã chuyển hoặc xóa)." }
            $meta | Add-Member -MemberType NoteProperty -Name $VideoId -Force -Value ([pscustomobject]@{ Posted = $Posted; Date = $markDate })
        } elseif ($item.Source -ne 'autotok-history') {
            # Pre-integration shape: Posted/Date are the manual mark.
            Set-ReupField $item 'Posted' $Posted
            Set-ReupField $item 'Date' $markDate
        } else {
            Set-ReupField $item 'ManualPosted' $Posted
            Set-ReupField $item 'ManualDate' $(if ($Posted) { $markDate } else { '' })
            Update-ReupAggregate $item
        }
        return $true
    })
}

# ------------------------------------------------------------- kho = thu muc that (moi kho la mot thu muc xuat day du) ----
# A kho is a REAL folder and a complete output folder like the old single one: <id>-3-hoan-chinh.mp4 at its root, .cache\ (-1/-2,
# thumbs, tiktok-posts receipts, tiktok-identities.json) and its own reup-status.json. data\kho.json (registry v2) is read and written
# on the UI thread only; background code works with plain folder paths and never touches the registry.
$script:khoRegistry = $null
$script:khoRegistryReady = $true     # $false: kho.json was unreadable this session -> it is never overwritten
$script:khoLegacyOutDir = ''         # outDir saved in settings.json = the folder that becomes "Output cũ" on first start ('' -> <root>\output)
$script:khoSettingsLoaded = $false   # $false until startup has read settings.json: before that the registry is never created, cached or saved (outDir unknown)
$script:queueOutDir = ''             # folder the running download queue saves into (captured at queue start; record again = that video's folder)
$script:importBusy = $false          # a background folder import is running
$script:khoExclusive = 0             # > 0 while a dialog / cleanup holds the kho folders (no move or delete may run)
$script:khoMoveRunning = $false      # a move batch is running (every other actor refuses)
$script:khoAutoMoveWanted = $false   # a sync pass changed history: look for videos to move into their account kho
$script:khoAutoMoveDeferred = $false # wanted but the app was busy: re-armed on the next busy -> quiet transition (not every 1 s tick)
$script:khoWasBusy = $false          # Test-KhoQuiet was non-empty at the previous sync tick
$script:khoAutoMoveFailed = @{}      # account -> time of the last failed attempt to create its kho (not retried for 10 minutes)

# D12: video trong kho = MỌI file video của thư mục kho (.mp4 .mov .m4v .mkv .webm .avi, không phân biệt hoa/thường; bỏ file ẩn bắt đầu bằng '.', *.part, *.tmp).
# Khóa nhận diện (key): video do app tạo (<số>-3-hoan-chinh.mp4) giữ khóa là số ID; video ngoài có khóa 'f:' + tên file đúng nguyên văn.
# Khóa dùng làm tên mục reup-status.json, VideoId của biên nhận, id nhật ký chuyển kho. Ảnh thu nhỏ: khóa số dùng nguyên, video ngoài dùng 'f_' + SHA1(tên file) (chữ thường).
function Test-KhoVideoFileName {
    param([string]$Name)
    if ([string]::IsNullOrWhiteSpace($Name) -or $Name.StartsWith('.')) { return $false }
    $ext = [System.IO.Path]::GetExtension($Name).ToLowerInvariant()
    return ($ext -in @('.mp4', '.mov', '.m4v', '.mkv', '.webm', '.avi'))
}

function Get-KhoVideoKey {
    # '' khi $FileName không phải file video của kho.
    param([string]$FileName)
    if (-not (Test-KhoVideoFileName $FileName)) { return '' }
    $m = [regex]::Match($FileName, '^(\d+)-3-hoan-chinh\.mp4$', [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
    if ($m.Success) { return $m.Groups[1].Value }
    return ('f:' + $FileName)
}

function Test-KhoExternalKey { param([string]$Key) return ([string]$Key).StartsWith('f:') }

function Test-KhoVideoKey {
    param([string]$Key)
    if ($Key -match '^\d+$') { return $true }
    return ($Key.StartsWith('f:') -and (Test-KhoVideoFileName $Key.Substring(2)))
}

function Get-KhoVideoFileName {
    # Tên file trong thư mục kho của một khóa; '' nếu khóa không hợp lệ.
    param([string]$Key)
    if ($Key -match '^\d+$') { return ($Key + '-3-hoan-chinh.mp4') }
    if (Test-KhoVideoKey $Key) { return $Key.Substring(2) }
    return ''
}

function Get-KhoVideoPath {
    param([Alias('Root')][string]$KhoRoot, [string]$Key)
    $name = Get-KhoVideoFileName $Key
    if (-not $name) { return '' }
    return (Join-Path $KhoRoot $name)
}

function Get-KhoThumbKey {
    param([string]$Key)
    if (-not $Key.StartsWith('f:')) { return $Key }
    $sha = [System.Security.Cryptography.SHA1]::Create()
    try { return ('f_' + [BitConverter]::ToString($sha.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($Key.Substring(2)))).Replace('-', '').ToLowerInvariant()) }
    finally { $sha.Dispose() }
}

function Get-KhoPath { return (Join-Path $script:root 'data\kho.json') }

function Test-KhoId {
    param([string]$Id)
    return [bool]($Id -cmatch '^k-[0-9a-f]{32}$')
}

function ConvertTo-KhoUsername {
    # '@Anna ' -> 'Anna'; '' when there is no usable TikTok username.
    param([string]$Username)
    $u = ([string]$Username).Trim().TrimStart('@')
    if (-not $u -or $u -match '\s') { return '' }
    return $u
}

function Get-KhoSlotsWith {
    # D10: thêm một giờ người dùng gõ ("7:30" -> "07:30") vào danh sách khung giờ; sai định dạng thì ném lỗi tiếng Việt. Trùng thì giữ nguyên. Trả về danh sách đã sắp xếp.
    param([string[]]$Slots = @(), [string]$Text)
    $m = [regex]::Match(([string]$Text).Trim(), '^(\d{1,2})[:h](\d{2})$')
    if (-not $m.Success -or [int]$m.Groups[1].Value -gt 23 -or [int]$m.Groups[2].Value -gt 59) { throw "Giờ không hợp lệ: '$Text'. Dùng dạng HH:mm, ví dụ 19:00." }
    $slot = ('{0:00}:{1:00}' -f [int]$m.Groups[1].Value, [int]$m.Groups[2].Value)
    return @(ConvertTo-KhoSlots (@($Slots) + $slot))
}

function Get-KhoSlotsWithout {
    param([string[]]$Slots = @(), [string]$Slot)
    return @(ConvertTo-KhoSlots @(@($Slots) | Where-Object { [string]$_ -cne $Slot }))
}

function ConvertTo-KhoSlots {
    # Valid 'HH:mm' times, sorted, no duplicates.
    param($Raw)
    return @(@($Raw) | Where-Object { $null -ne $_ -and ([string]$_) -match '^([01]\d|2[0-3]):[0-5]\d$' } | ForEach-Object { [string]$_ } | Sort-Object -Unique)
}

function New-KhoId { return ('k-' + [Guid]::NewGuid().ToString('N')) }

function New-KhoLibrary {
    param([string]$Id, [string]$Name, [string]$Path, [string]$Account = '', [bool]$CreatedByApp = $false)
    return [pscustomobject]@{ id = $Id; name = $Name; path = $Path; account = $Account; caption = ''; hashtags = @(); lowStock = 3; slots = @(); createdByApp = $CreatedByApp }
}

function ConvertTo-KhoLibrary {
    # Validated copy of one stored library; $null when the id or the path is not valid.
    param($Raw)
    if ($null -eq $Raw) { return $null }
    $id = [string]$Raw.id
    if (-not (Test-KhoId $id)) { return $null }
    $text = ([string]$Raw.path).Trim()
    if (-not ($text -match '^[A-Za-z]:[\\/]' -or $text.StartsWith('\\'))) { return $null }
    try { $path = Get-CanonicalPath $text } catch { return $null }
    $account = ConvertTo-KhoUsername ([string]$Raw.account)
    $name = ([string]$Raw.name).Trim()
    if (-not $name) { $name = $(if ($account) { '@' + $account } else { [IO.Path]::GetFileName($path) }) }
    $lib = New-KhoLibrary -Id $id -Name $name -Path $path -Account $account -CreatedByApp ($Raw.createdByApp -eq $true)
    $lib.caption = [string]$Raw.caption
    $lib.hashtags = @(@($Raw.hashtags) | Where-Object { $null -ne $_ -and ([string]$_).Trim() } | ForEach-Object { ([string]$_).Trim() })
    $low = 0
    if ([int]::TryParse([string]$Raw.lowStock, [ref]$low) -and $low -ge 0 -and $low -le 999) { $lib.lowStock = $low }
    $lib.slots = @(ConvertTo-KhoSlots $Raw.slots)
    return $lib
}

function ConvertTo-KhoRegistry {
    # Validated copy of a parsed registry: bad libraries dropped; duplicate ids / folders dropped (first wins); a second kho
    # claiming an account loses the account. downloadTarget falls back to the first kho. The list may be empty (caller decides).
    param($Raw)
    $list = New-Object System.Collections.Generic.List[object]
    $ids = @{}; $paths = @{}; $accounts = @{}
    foreach ($item in @($Raw.libraries)) {
        $lib = ConvertTo-KhoLibrary $item
        if ($null -eq $lib -or $ids.ContainsKey($lib.id) -or $paths.ContainsKey($lib.path.ToUpperInvariant())) { continue }
        $ids[$lib.id] = $true; $paths[$lib.path.ToUpperInvariant()] = $true
        if ($lib.account) {
            if ($accounts.ContainsKey($lib.account.ToLowerInvariant())) { $lib.account = '' } else { $accounts[$lib.account.ToLowerInvariant()] = $true }
        }
        $list.Add($lib)
    }
    $target = [string]$Raw.downloadTarget
    if (-not $ids.ContainsKey($target)) { $target = $(if ($list.Count) { [string]$list[0].id } else { '' }) }
    $since = [string]$Raw.autoMoveSince
    $parsed = [DateTimeOffset]::MinValue
    if (-not [DateTimeOffset]::TryParse($since, [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::AssumeUniversal, [ref]$parsed)) { $since = '' }
    return [pscustomobject]@{ version = 2; libraries = $list.ToArray(); downloadTarget = $target; autoMoveSince = $since }
}

function Get-KhoLegacyOutDir {
    $saved = ([string]$script:khoLegacyOutDir).Trim()
    if ($saved -match '^[A-Za-z]:[\\/]' -or $saved.StartsWith('\\')) { return $saved }
    if ($saved) { Write-FileLog "WARN outDir đã lưu '$saved' không phải đường dẫn đầy đủ; dùng thư mục output mặc định cho kho 'Output cũ'." }
    return (Join-Path $script:root 'output')
}

function New-KhoDefaultRegistry {
    # First start (or nothing usable on disk): one kho "Output cũ" = the folder the app used so far. Nothing is moved.
    # autoMoveSince = now: only posts confirmed from now on may move a video into an account kho.
    $lib = New-KhoLibrary -Id (New-KhoId) -Name 'Output cũ' -Path (Get-CanonicalPath (Get-KhoLegacyOutDir))
    return [pscustomobject]@{ version = 2; libraries = @($lib); downloadTarget = $lib.id; autoMoveSince = [DateTime]::UtcNow.ToString('o') }
}

function Move-KhoFileAside {
    # Renames a bad / old registry file so it is never lost; $false when it could not be renamed.
    param([string]$Path, [string]$Kind)
    $bad = $Path + '.' + $Kind + '-' + (Get-Date).ToString('yyyyMMdd-HHmmss')
    if ([System.IO.File]::Exists($bad)) { $bad += '-' + [Guid]::NewGuid().ToString('N').Substring(0, 6) }
    try { [System.IO.File]::Move($Path, $bad); Write-FileLog "INFO kho.json: file cũ đã được đổi tên thành '$bad'."; return $true }
    catch { Write-FileLog "WARN kho.json: không đổi tên được '$Path' ($Kind): $($_.Exception.Message)"; return $false }
}

function Read-KhoRegistry {
    # Missing / v1 (logical kho) / corrupt -> a fresh registry with "Output cũ" (saved at once; the old file is renamed aside, never
    # deleted). Unreadable (locked) -> in-memory default and $script:khoRegistryReady = $false: this session never overwrites the file.
    # Never throws.
    param([string]$Path = (Get-KhoPath))
    $script:khoRegistryReady = $true
    $fresh = {
        param([string]$Why)
        $reg = New-KhoDefaultRegistry
        if ($script:settingsReadLocked) {
            # settings.json was locked: the real outDir is unknown, so "Output cũ" may point at the wrong folder -> keep it in memory only.
            $script:khoRegistryReady = $false
            Write-FileLog "WARN kho.json: cài đặt đang bị khóa nên chưa biết thư mục xuất cũ; kho tạm chỉ dùng trong phiên này ($Why)."
            return $reg
        }
        try { [void](Save-KhoRegistry -Registry $reg -Path $Path) } catch { Write-FileLog "WARN Không ghi được kho.json mới ($Why): $($_.Exception.Message)" }
        Write-FileLog "INFO kho.json: tạo mới với kho 'Output cũ' = '$($reg.libraries[0].path)' ($Why)."
        return $reg
    }
    try {
        if (-not [System.IO.File]::Exists($Path)) { return (& $fresh 'chưa có file') }
        $json = $null; $readErr = $null
        for ($try = 1; $try -le 3; $try++) {
            try { $json = [System.IO.File]::ReadAllText($Path, [System.Text.Encoding]::UTF8); $readErr = $null; break }
            catch { $readErr = $_.Exception.Message; if ($try -lt 3) { Start-Sleep -Milliseconds 100 } }
        }
        if ($null -ne $readErr) {
            Write-FileLog "WARN Không đọc được kho.json (đang bị khóa?), giữ nguyên file và không ghi đè trong phiên này: $readErr"
            $script:khoRegistryReady = $false
            return (New-KhoDefaultRegistry)
        }
        $obj = $null; $parseError = ''
        try {
            if ([string]::IsNullOrWhiteSpace($json) -or -not $json.TrimStart().StartsWith('{')) { throw 'Không phải đối tượng JSON.' }
            $obj = ConvertFrom-Json -InputObject $json -ErrorAction Stop
            if ($null -eq $obj -or $obj -isnot [pscustomobject] -or $null -eq $obj.PSObject.Properties['libraries']) { throw 'Thiếu danh sách kho.' }
        } catch { $parseError = $_.Exception.Message }
        if ($parseError) {
            Write-FileLog "WARN kho.json bị hỏng ($parseError)."
            if (-not (Move-KhoFileAside $Path 'corrupt')) { $script:khoRegistryReady = $false; return (New-KhoDefaultRegistry) }
            return (& $fresh 'file hỏng')
        }
        $version = 0; [void][int]::TryParse([string]$obj.version, [ref]$version)
        $reg = ConvertTo-KhoRegistry $obj
        if ($version -lt 2 -or -not @($reg.libraries).Count) {
            if (-not (Move-KhoFileAside $Path $(if ($version -lt 2) { 'v1' } else { 'invalid' }))) { $script:khoRegistryReady = $false; return (New-KhoDefaultRegistry) }
            return (& $fresh $(if ($version -lt 2) { 'chuyển từ kho nhãn (v1)' } else { 'không có kho hợp lệ' }))
        }
        return $reg
    } catch {
        $script:khoRegistryReady = $false
        Write-FileLog "WARN Đọc kho.json lỗi: $($_.Exception.Message)"
        return (New-KhoDefaultRegistry)
    }
}

function Get-KhoRegistry {
    # Before settings.json is loaded the saved outDir (= folder of "Output cũ") is unknown: hand out a transient default that is never
    # cached or written, so an early caller cannot create / save a registry that points at <app>\output.
    if ($script:khoSettingsLoaded -eq $false) {
        Write-FileLog 'WARN Get-KhoRegistry được gọi trước khi nạp cài đặt; trả về kho tạm, không lưu.'
        return (New-KhoDefaultRegistry)
    }
    if ($null -eq $script:khoRegistry) { $script:khoRegistry = Read-KhoRegistry }
    return $script:khoRegistry
}

function Save-KhoRegistry {
    # Atomic write (Write-KidSettings). Returns $false without writing when kho.json was unreadable this session.
    param($Registry = (Get-KhoRegistry), [string]$Path = (Get-KhoPath))
    if ($script:khoSettingsLoaded -eq $false) { Write-FileLog 'WARN Chưa nạp cài đặt; không ghi kho.json.'; return $false }
    if (-not $script:khoRegistryReady) { Write-FileLog 'WARN kho.json không đọc được trong phiên này; không ghi đè.'; return $false }
    $data = [ordered]@{
        version = 2
        libraries = @($Registry.libraries | ForEach-Object {
            [ordered]@{ id = [string]$_.id; name = [string]$_.name; path = [string]$_.path; account = [string]$_.account; caption = [string]$_.caption
                        hashtags = @($_.hashtags | ForEach-Object { [string]$_ }); lowStock = [int]$_.lowStock
                        slots = @($_.slots | ForEach-Object { [string]$_ }); createdByApp = [bool]$_.createdByApp }
        })
        downloadTarget = [string]$Registry.downloadTarget
        autoMoveSince = [string]$Registry.autoMoveSince
    }
    Write-KidSettings -Path $Path -Data $data
    return $true
}

function Invoke-KhoRegistryChange {
    # Applies $Change to a copy and saves it; the in-memory registry is replaced only after the save succeeded.
    param([scriptblock]$Change)
    $current = Get-KhoRegistry
    if ($script:khoSettingsLoaded -eq $false) { throw 'Chưa nạp xong cài đặt nên chưa lưu được thay đổi kho.' }
    if (-not $script:khoRegistryReady) { throw 'Không đọc được data\kho.json nên phiên này không lưu thay đổi kho. Đóng ứng dụng, kiểm tra file rồi mở lại.' }
    $copy = ConvertTo-KhoRegistry $current
    $output = @(& $Change $copy) | Select-Object -Last 1
    [void](Save-KhoRegistry -Registry $copy)
    $script:khoRegistry = $copy
    return $output
}

function Assert-KhoName {
    # Trimmed name, or a Vietnamese error when it is empty, too long or already used by another kho.
    param($Registry, [string]$Name, [string]$ExceptId = '')
    $n = $Name.Trim()
    if (-not $n) { throw 'Tên kho không được để trống.' }
    if ($n.Length -gt 60) { throw 'Tên kho tối đa 60 ký tự.' }
    foreach ($lib in @($Registry.libraries)) {
        if ($lib.id -ne $ExceptId -and [string]::Equals([string]$lib.name, $n, [StringComparison]::OrdinalIgnoreCase)) { throw "Đã có kho tên '$n'." }
    }
    return $n
}

function Get-KhoList { return @((Get-KhoRegistry).libraries) }

function Get-KhoById {
    param([string]$Id, $Registry = (Get-KhoRegistry))
    foreach ($lib in @($Registry.libraries)) { if ([string]$lib.id -ceq $Id) { return $lib } }
    return $null
}

function Get-KhoByPath {
    param([string]$Path, $Registry = (Get-KhoRegistry))
    if ([string]::IsNullOrWhiteSpace($Path)) { return $null }
    try { $full = Get-CanonicalPath $Path } catch { return $null }
    foreach ($lib in @($Registry.libraries)) { if ([string]::Equals([string]$lib.path, $full, [StringComparison]::OrdinalIgnoreCase)) { return $lib } }
    return $null
}

function Get-KhoForAccount {
    # The kho assigned to a TikTok username (case-insensitive), or $null.
    param([string]$Username, $Registry = (Get-KhoRegistry))
    $u = ConvertTo-KhoUsername $Username
    if (-not $u) { return $null }
    foreach ($lib in @($Registry.libraries)) { if ([string]$lib.account -and [string]::Equals([string]$lib.account, $u, [StringComparison]::OrdinalIgnoreCase)) { return $lib } }
    return $null
}

function Get-KhoRoots {
    # Canonical folder of every registered kho, registry order.
    param($Registry = (Get-KhoRegistry))
    return @($Registry.libraries | ForEach-Object { [string]$_.path })
}

function Test-KhoPathAllowed {
    # '' when $Path may become (or stay) the folder of a kho; otherwise the Vietnamese reason: full path, not a drive root, same
    # volume as the first kho (so every move is one instant rename), not equal to / inside / containing another kho folder.
    param($Registry, [string]$Path, [string]$ExceptId = '')
    $text = ([string]$Path).Trim()
    if (-not ($text -match '^[A-Za-z]:[\\/]' -or $text.StartsWith('\\'))) { return 'Chọn thư mục đầy đủ, ví dụ D:\Kho video.' }
    try { $full = Get-CanonicalPath $text } catch { return 'Đường dẫn thư mục không hợp lệ.' }
    $pathRoot = [IO.Path]::GetPathRoot($full)
    if ($full.Length -le $pathRoot.Length) { return 'Không dùng gốc ổ đĩa làm kho; hãy chọn một thư mục con.' }
    $libs = @($Registry.libraries)
    if ($libs.Count) {
        $firstRoot = [IO.Path]::GetPathRoot([string]$libs[0].path)
        if (-not [string]::Equals($firstRoot, $pathRoot, [StringComparison]::OrdinalIgnoreCase)) {
            return "Mọi kho phải nằm trên cùng một ổ đĩa ($firstRoot) để chuyển video tức thì và không mất file."
        }
    }
    foreach ($o in $libs) {
        if ([string]$o.id -ceq $ExceptId) { continue }
        $p = [string]$o.path
        if ([string]::Equals($p, $full, [StringComparison]::OrdinalIgnoreCase)) { return "Thư mục này đã là kho '$($o.name)'." }
        if ($full.StartsWith($p.TrimEnd('\') + '\', [StringComparison]::OrdinalIgnoreCase)) { return "Thư mục này nằm trong kho '$($o.name)'. Chọn thư mục khác." }
        if ($p.StartsWith($full.TrimEnd('\') + '\', [StringComparison]::OrdinalIgnoreCase)) { return "Thư mục này chứa kho '$($o.name)'. Chọn thư mục khác." }
    }
    return ''
}

function Get-KhoDownloadTarget {
    # Id of the kho the next download queue saves into (the first kho when the stored one is gone).
    $reg = Get-KhoRegistry
    $lib = Get-KhoById ([string]$reg.downloadTarget) $reg
    if ($lib) { return [string]$lib.id }
    $first = @($reg.libraries)[0]
    return $(if ($first) { [string]$first.id } else { '' })
}

function Get-KhoDownloadPath {
    $lib = Get-KhoById (Get-KhoDownloadTarget)
    return $(if ($lib) { [string]$lib.path } else { (Get-CanonicalPath (Get-KhoLegacyOutDir)) })
}

function Set-KhoDownloadTarget {
    param([string]$Id)
    $reg = Get-KhoRegistry
    if (-not (Get-KhoById $Id $reg)) { throw 'Không tìm thấy kho.' }
    # Locked kho.json: the choice only lasts for this session.
    if (-not $script:khoRegistryReady) { $reg.downloadTarget = $Id; return }
    Invoke-KhoRegistryChange { param($r) $r.downloadTarget = $Id }
}

function Sync-OutDirFromKho {
    # TxtOut (an) = thu muc cua kho tai ve. Chi la gia tri tuong thich cho ma cu va settings.json; hang doi dang chay da chup duong dan rieng.
    if (-not $ui -or -not $ui.TxtOut) { return }
    $path = Get-KhoDownloadPath
    if ([string]$ui.TxtOut.Text -ceq $path) { return }
    $ui.TxtOut.Text = $path
}

function Get-KhoDefaultFolder {
    # <parent of the download-target kho>\Kho <name>: always on the same volume as the other khos.
    param([string]$Name)
    $parent = [IO.Path]::GetDirectoryName((Get-KhoDownloadPath))
    if (-not $parent) { throw 'Không xác định được thư mục cha của kho tải về.' }
    $safe = (([string]$Name) -replace '[\\/:*?"<>|\x00-\x1f]', '_').Trim().TrimEnd('.')
    if (-not $safe) { $safe = 'moi' }
    return (Join-Path $parent ('Kho ' + $safe))
}

function New-Kho {
    # Creates the folder (default <parent of the download kho>\Kho <name>) and registers it. Nothing is registered when the
    # folder cannot be created or the registry cannot be saved (a folder this call made is removed again).
    param([string]$Name, [string]$Path = '', [string]$Account = '')
    $made = @{ Dir = ''; Existed = $true }
    try {
        return (Invoke-KhoRegistryChange {
            param($reg)
            $n = Assert-KhoName $reg $Name
            $user = ConvertTo-KhoUsername $Account
            if ($Account -and -not $user) { throw 'Tên tài khoản TikTok không hợp lệ.' }
            if ($user) { $dupe = Get-KhoForAccount $user $reg; if ($dupe) { throw "Tài khoản @$user đã có kho '$($dupe.name)'." } }
            $target = $(if ($Path) { $Path } else { Get-KhoDefaultFolder $n })
            $why = Test-KhoPathAllowed $reg $target
            if ($why) { throw $why }
            $full = Get-CanonicalPath $target
            $made.Existed = [IO.Directory]::Exists($full)
            [void][IO.Directory]::CreateDirectory($full)
            $made.Dir = $full
            $lib = New-KhoLibrary -Id (New-KhoId) -Name $n -Path $full -Account $user -CreatedByApp (-not $made.Existed)
            $reg.libraries = @($reg.libraries) + $lib
            return $lib
        })
    } catch {
        if ($made.Dir -and -not $made.Existed) {
            try { [IO.Directory]::Delete($made.Dir) } catch { Write-FileLog "WARN Không xóa lại được thư mục kho vừa tạo '$($made.Dir)': $($_.Exception.Message)" }
        }
        throw
    }
}

function New-KhoForAccount {
    # Returns the account's kho, creating "Kho @user" (named @user) when missing.
    param([string]$Username)
    $u = ConvertTo-KhoUsername $Username
    if (-not $u) { throw 'Tên tài khoản TikTok không hợp lệ.' }
    $existing = Get-KhoForAccount $u
    if ($existing) { return $existing }
    $name = '@' + $u
    if (@((Get-KhoRegistry).libraries | Where-Object { [string]::Equals([string]$_.name, $name, [StringComparison]::OrdinalIgnoreCase) }).Count) { $name += ' (TikTok)' }
    return (New-Kho -Name $name -Account $u)
}

function Rename-Kho {
    param([string]$Id, [string]$Name)
    Invoke-KhoRegistryChange {
        param($reg)
        $lib = Get-KhoById $Id $reg
        if (-not $lib) { throw 'Không tìm thấy kho.' }
        $lib.name = Assert-KhoName $reg $Name $Id
    }
}

function Set-KhoAccount {
    # Assigns a TikTok account to a kho ('' removes it). One kho per account.
    param([string]$Id, [string]$Account)
    Invoke-KhoRegistryChange {
        param($reg)
        $lib = Get-KhoById $Id $reg
        if (-not $lib) { throw 'Không tìm thấy kho.' }
        $user = ConvertTo-KhoUsername $Account
        if ($Account.Trim() -and -not $user) { throw 'Tên tài khoản TikTok không hợp lệ.' }
        if ($user) {
            $dupe = Get-KhoForAccount $user $reg
            if ($dupe -and [string]$dupe.id -cne $Id) { throw "Tài khoản @$user đã có kho '$($dupe.name)'." }
        }
        $lib.account = $user
    }
}

function Set-KhoOptions {
    # Caption template, default hashtags, low-stock threshold and posting slots of one kho; only the parameters given are changed.
    param([string]$Id, [string]$Caption, [string[]]$Hashtags, [int]$LowStock, [string[]]$Slots)
    $bound = $PSBoundParameters
    Invoke-KhoRegistryChange {
        param($reg)
        $lib = Get-KhoById $Id $reg
        if (-not $lib) { throw 'Không tìm thấy kho.' }
        if ($bound.ContainsKey('Caption')) { $lib.caption = [string]$Caption }
        if ($bound.ContainsKey('Hashtags')) { $lib.hashtags = @(@($Hashtags) | Where-Object { $_ -and $_.Trim() } | ForEach-Object { $_.Trim() }) }
        if ($bound.ContainsKey('LowStock')) {
            if ($LowStock -lt 0 -or $LowStock -gt 999) { throw 'Ngưỡng sắp hết phải từ 0 đến 999.' }
            $lib.lowStock = $LowStock
        }
        if ($bound.ContainsKey('Slots')) {
            $bad = @(@($Slots) | Where-Object { $_ -and ([string]$_) -notmatch '^([01]\d|2[0-3]):[0-5]\d$' })
            if ($bad.Count) { throw "Giờ đăng không hợp lệ: $($bad[0]). Dùng dạng HH:mm, ví dụ 19:00." }
            $lib.slots = @(ConvertTo-KhoSlots $Slots)
        }
    }
}

function Test-KhoImportBlocked {
    # '' when a folder import may start now; otherwise the message for the owner.
    if ($script:importBusy) { return 'Đang thêm video từ một thư mục khác.' }
    if ($script:khoMoveRunning -or $script:khoExclusive -gt 0) { return 'Đang chuyển kho hoặc mở hộp thoại đăng/dọn dẹp. Thử lại sau.' }
    if ($script:ps -or $script:stopping -or ($script:queue -and @($script:queue).Count -gt 0)) { return 'Hãy dừng hoặc đợi hàng đợi / sửa video hoàn tất trước khi thêm video từ thư mục.' }
    return ''
}

function Copy-KhoExternalFiles {
    # D12: chép các file video người dùng thả vào trang Kho vào thư mục kho $ToRoot. KHÔNG ghi đè (trùng tên thì bỏ qua); chép sang <tên>.part rồi đổi tên
    # (File.Move không ghi đè) nên không bao giờ có file video dở. Trả về @{ Copied = tên; Skipped = @(@{Name; Why}); Failed = @(@{Name; Why}) }.
    param([string[]]$Files, [string]$ToRoot)
    $copied = New-Object System.Collections.Generic.List[string]
    $skipped = New-Object System.Collections.Generic.List[object]
    $failed = New-Object System.Collections.Generic.List[object]
    foreach ($src in @($Files)) {
        $name = [System.IO.Path]::GetFileName([string]$src)
        if ([System.IO.Directory]::Exists([string]$src)) { $skipped.Add(@{ Name = $name; Why = 'là thư mục' }); continue }
        if (-not (Test-KhoVideoFileName $name)) { $skipped.Add(@{ Name = $name; Why = 'không phải file video (.mp4 .mov .m4v .mkv .webm .avi)' }); continue }
        if (-not [System.IO.File]::Exists([string]$src)) { $skipped.Add(@{ Name = $name; Why = 'không thấy file' }); continue }
        $dest = Join-Path $ToRoot $name
        if ([System.IO.File]::Exists($dest)) { $skipped.Add(@{ Name = $name; Why = 'kho đã có file cùng tên (không ghi đè)' }); continue }
        $partial = $dest + '.part'
        try {
            [void][System.IO.Directory]::CreateDirectory($ToRoot)
            [System.IO.File]::Copy([string]$src, $partial, $true)
            if ([System.IO.FileInfo]::new($partial).Length -ne [System.IO.FileInfo]::new([string]$src).Length) { throw 'file chép ra không đủ dung lượng' }
            [System.IO.File]::Move($partial, $dest)
            $copied.Add($name)
        } catch {
            $failed.Add(@{ Name = $name; Why = $_.Exception.Message })
            Write-FileLog "WARN Thả video vào kho: không chép được '$src' -> '$dest': $($_.Exception.Message)"
            try { if ([System.IO.File]::Exists($partial)) { [System.IO.File]::Delete($partial) } } catch { Write-FileLog "WARN Không xóa được file dở '$partial': $($_.Exception.Message)" }
        }
    }
    return @{ Copied = $copied.ToArray(); Skipped = $skipped.ToArray(); Failed = $failed.ToArray() }
}

function Invoke-KhoDrop {
    # Thả file từ Explorer lên trang Kho: chép vào kho đang chọn. Từ chối khi ứng dụng không yên hoặc đang xem "Tất cả kho".
    param([string[]]$Files)
    $files = @($Files | Where-Object { $_ })
    if (-not $files.Count) { return }
    $busy = Test-KhoQuiet
    if ($busy) { Show-Toast "Đang bận ($busy)… thử lại sau." -Kind warning; return }
    $lib = $null
    if ($script:filterKho -and [string]$script:filterKho -ne 'all') { $lib = Get-KhoById ([string]$script:filterKho) }
    if (-not $lib) { Show-Toast 'Chọn một kho cụ thể (không phải "Tất cả kho") rồi thả video vào lại.' -Kind warning; return }
    $script:khoMoveRunning = $true
    $r = $null
    try { $r = Copy-KhoExternalFiles -Files $files -ToRoot ([string]$lib.path) }
    finally { $script:khoMoveRunning = $false }
    if (@($r.Copied).Count) { Update-Gallery }
    $parts = @()
    if (@($r.Copied).Count) { $parts += "Đã thêm $(@($r.Copied).Count) video vào $($lib.name)." }
    if (@($r.Skipped).Count) { $parts += "Bỏ qua $(@($r.Skipped).Count): $($r.Skipped[0].Name) $($r.Skipped[0].Why)." }
    if (@($r.Failed).Count) { $parts += "Lỗi $(@($r.Failed).Count): $($r.Failed[0].Name) — $($r.Failed[0].Why)." }
    Show-Toast ($parts -join ' ') -Kind $(if (@($r.Failed).Count) { 'error' } elseif (@($r.Copied).Count) { 'success' } else { 'warning' })
}

function Get-KhoFileSha256 {
    param([string]$Path)
    $sha = [System.Security.Cryptography.SHA256]::Create()
    $stream = [System.IO.File]::Open($Path, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::Read)
    try { return [BitConverter]::ToString($sha.ComputeHash($stream)).Replace('-', '') }
    finally { $stream.Dispose(); $sha.Dispose() }
}

function Copy-KhoFileNoOverwrite {
    # Copies to <dest>.part, flushes, then File.Move (which throws when dest exists). Returns 'copied' or 'exists'.
    param([string]$Source, [string]$Dest, [Threading.CancellationToken]$CancelToken = [Threading.CancellationToken]::None)
    if ([System.IO.File]::Exists($Dest)) { return 'exists' }
    $part = $Dest + '.part'
    $moved = $false
    try {
        $in = [System.IO.File]::Open($Source, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::Read)
        try {
            $out = [System.IO.File]::Open($part, [System.IO.FileMode]::Create, [System.IO.FileAccess]::Write, [System.IO.FileShare]::None)
            try {
                $buffer = New-Object byte[] (4MB)
                while (($read = $in.Read($buffer, 0, $buffer.Length)) -gt 0) {
                    $CancelToken.ThrowIfCancellationRequested()
                    $out.Write($buffer, 0, $read)
                }
                $out.Flush($true)
            } finally { $out.Dispose() }
        } finally { $in.Dispose() }
        try { [System.IO.File]::Move($part, $Dest); $moved = $true }
        catch [System.IO.IOException] { if (-not [System.IO.File]::Exists($Dest)) { throw }; return 'exists' }
        return 'copied'
    } finally {
        if (-not $moved -and [System.IO.File]::Exists($part)) { try { [System.IO.File]::Delete($part) } catch { <# bo qua: file .part, loi xoa khong anh huong ket qua #> } }
    }
}

function Import-KhoFolder {
    # Copies <id>-3-hoan-chinh.mp4 (+ -1/-2 companions) of a folder into the kho folder $OutDir without overwriting anything, then
    # records the source's history in one Update-ReupMetadata call. Safe to run in a background runspace: no UI access; progress
    # goes to the optional $Progress callback ({Done; Total; Id}). The source folder is only read.
    # An id already present with identical content (retry after a failed metadata step) only gets the metadata step.
    param([string]$SourceDir, [string]$OutDir, [scriptblock]$Progress = $null, [Threading.CancellationToken]$CancelToken = [Threading.CancellationToken]::None)
    if (-not [System.IO.Directory]::Exists($SourceDir)) { throw "Không thấy thư mục nguồn: $SourceDir" }
    $srcFull = Get-CanonicalPath $SourceDir; $outFull = Get-CanonicalPath $OutDir
    if ([string]::Equals($srcFull, $outFull, [StringComparison]::OrdinalIgnoreCase)) { throw 'Thư mục nguồn trùng thư mục kho.' }
    [void][System.IO.Directory]::CreateDirectory($outFull)
    $result = [pscustomobject]@{ Added = 0; Skipped = 0; Failed = 0; Cancelled = $false; AddedIds = @(); SkippedIds = @(); Errors = @(); Warnings = @() }
    $errors = New-Object System.Collections.Generic.List[string]; $warnings = New-Object System.Collections.Generic.List[string]
    $pending = New-Object System.Collections.Generic.List[string]; $skippedIds = New-Object System.Collections.Generic.List[string]
    $identical = New-Object System.Collections.Generic.List[string]   # already present with the same bytes: metadata step only
    $files = @([System.IO.DirectoryInfo]::new($srcFull).GetFiles('*-3-hoan-chinh.mp4') | Where-Object { $_.Name -match '^\d+-3-hoan-chinh\.mp4$' } | Sort-Object Name)
    $srcCache = Join-Path $srcFull '.cache'; $dstCache = Join-Path $outFull '.cache'
    $progressFailed = $false
    $done = 0
    foreach ($file in $files) {
        if ($CancelToken.IsCancellationRequested) { $result.Cancelled = $true; break }
        $id = ([string]$file.Name) -replace '-3-hoan-chinh\.mp4$', ''
        $done++
        if ($Progress) {
            try { & $Progress ([pscustomobject]@{ Done = $done; Total = $files.Count; Id = $id }) }
            catch { if (-not $progressFailed) { $progressFailed = $true; $warnings.Add("Hàm báo tiến độ lỗi: $($_.Exception.Message)") } }
        }
        try {
            $dest = Join-Path $outFull $file.Name
            $copy = Copy-KhoFileNoOverwrite -Source $file.FullName -Dest $dest -CancelToken $CancelToken
            if ($copy -eq 'exists') {
                $same = ([System.IO.FileInfo]::new($dest).Length -eq $file.Length) -and ((Get-KhoFileSha256 $dest) -eq (Get-KhoFileSha256 $file.FullName))
                if (-not $same) { $skippedIds.Add($id); continue }
                $identical.Add($id)
            }
            foreach ($leaf in @("$id-1-video-goc.mp4", "$id-2-am-thanh-tho.m4a")) {
                if ([System.IO.File]::Exists((Join-Path $dstCache $leaf)) -or [System.IO.File]::Exists((Join-Path $outFull $leaf))) { continue }
                $from = @((Join-Path $srcCache $leaf), (Join-Path $srcFull $leaf)) | Where-Object { [System.IO.File]::Exists($_) } | Select-Object -First 1
                if (-not $from) { continue }
                try {
                    if (-not [System.IO.Directory]::Exists($dstCache)) {
                        [void][System.IO.Directory]::CreateDirectory($dstCache)
                        try { [System.IO.File]::SetAttributes($dstCache, [System.IO.FileAttributes]::Directory -bor [System.IO.FileAttributes]::Hidden) }
                        catch { $warnings.Add("Không đặt được thuộc tính ẩn cho .cache: $($_.Exception.Message)") }
                    }
                    [void](Copy-KhoFileNoOverwrite -Source $from -Dest (Join-Path $dstCache $leaf) -CancelToken $CancelToken)
                } catch {
                    if ($CancelToken.IsCancellationRequested) { throw }
                    $warnings.Add("Reel #$id`: không chép được $leaf ($($_.Exception.Message)); vẫn thêm video nhưng không sửa lại logo/GIF được.")
                }
            }
            $pending.Add($id)
        } catch {
            if ($CancelToken.IsCancellationRequested) { $result.Cancelled = $true; break }
            $result.Failed++; $errors.Add("Reel #$id`: $($_.Exception.Message)")
        }
    }
    if ($pending.Count) {
        $source = $null
        try { $source = Get-ReupMetadata -OutDir $srcFull }
        catch { $warnings.Add("Không đọc được reup-status.json của thư mục nguồn; không chép lịch sử đăng. $($_.Exception.Message)") }
        $ids = $pending.ToArray()
        try {
            [void](Update-ReupMetadata -OutDir $outFull -Change {
                param($meta)
                $any = $false
                foreach ($id in $ids) {
                    $theirs = if ($source) { $source.PSObject.Properties[$id] } else { $null }
                    $theirs = if ($theirs) { $theirs.Value } else { $null }
                    $mine = $meta.PSObject.Properties[$id]
                    $mine = if ($mine) { $mine.Value } else { $null }
                    if ($null -eq $mine -and $theirs) {
                        $clone = ConvertFrom-Json -InputObject (ConvertTo-Json -InputObject $theirs -Depth 12 -Compress)
                        foreach ($name in @('Kho', 'KhoManual', 'KhoPinned')) { if ($clone.PSObject.Properties[$name]) { [void]$clone.PSObject.Properties.Remove($name) } }
                        $meta | Add-Member -MemberType NoteProperty -Name $id -Force -Value $clone
                        $any = $true
                    } elseif ($mine -and $theirs -and $theirs.Source -eq 'autotok-history') {
                        # Union of history by key; our own entry wins on the same key.
                        $have = @{}
                        foreach ($h in @($mine.History)) { if ($h) { $have[[string]$h.key] = $true } }
                        $extra = @(@($theirs.History) | Where-Object { $_ -and [string]$_.key -and -not $have.ContainsKey([string]$_.key) } | ForEach-Object { ConvertTo-TikTokHistoryEntry $_ })
                        if ($extra.Count) {
                            $union = @(@($mine.History | Where-Object { $_ }) + $extra | Sort-Object { Get-TikTokSortKey ([string]$_.created_at) } -Descending)
                            if (Set-TikTokItemHistory $meta $id $union '') { $any = $true }
                        }
                    }
                }
                return $any
            })
            $fresh = @($ids | Where-Object { -not $identical.Contains($_) })
            $result.Added = $fresh.Count
            $result.AddedIds = $fresh
            foreach ($i in $identical) { if (-not $skippedIds.Contains($i)) { $skippedIds.Add($i) } }
        } catch {
            # Files stay; running the import again finishes the metadata step (identical files are recognised).
            $result.Failed += $ids.Count
            $errors.Add("Đã chép $($ids.Count) video nhưng chưa ghi được lịch sử: $($_.Exception.Message) Chạy lại để hoàn tất.")
        }
    }
    $result.Skipped = $skippedIds.Count; $result.SkippedIds = $skippedIds.ToArray()
    $result.Errors = $errors.ToArray(); $result.Warnings = $warnings.ToArray()
    return $result
}

# Functions a background runspace needs to run Import-KhoFolder (build an InitialSessionState from these, like the TikTok worker).
$script:khoImportFunctions = @('Get-CanonicalPath', 'Get-FileStamp', 'Get-ReupMutexName', 'Get-ReupMetadata', 'Update-ReupMetadata', 'Set-ReupField',
    'Get-ReupManualState', 'Update-ReupAggregate', 'Format-TikTokTime', 'Get-TikTokSortKey', 'ConvertTo-TikTokHistoryEntry', 'Get-TikTokHistorySignature',
    'Set-TikTokItemHistory', 'Get-KhoFileSha256', 'Copy-KhoFileNoOverwrite', 'Import-KhoFolder')

# ------------------------------------------------------------- chuyen kho that: nhat ky giao dich (data\kho-moves) ----
# A move is a batch of same-volume renames driven by a journal written BEFORE the first rename (temp file + Flush(true) + rename).
# The journal lives outside every kho folder, so no cache cleanup can ever delete it. Recovery (startup, before each batch) rolls
# forward from the recorded phase: renaming -> meta-target-done -> meta-source-done. Every step is idempotent.
function Get-KhoMovesDir { return (Join-Path $script:root 'data\kho-moves') }

function Add-KhoMoveLog {
    param([string]$Text)
    try {
        $dir = Join-Path $script:root 'logs'
        [void][System.IO.Directory]::CreateDirectory($dir)
        [System.IO.File]::AppendAllText((Join-Path $dir 'kho-moves.log'), ((Get-Date).ToString('yyyy-MM-dd HH:mm:ss') + '  ' + $Text + "`r`n"), [System.Text.UTF8Encoding]::new($false))
    } catch { Write-FileLog "WARN kho-moves.log: $($_.Exception.Message)" }
}

function Write-KhoJournal {
    # Atomic: temp file in the same folder, Flush(true), then rename / replace.
    param($Journal)
    $dir = Get-KhoMovesDir
    [void][System.IO.Directory]::CreateDirectory($dir)
    $path = Join-Path $dir ([string]$Journal.txid + '.json')
    $temp = $path + '.' + [Guid]::NewGuid().ToString('N') + '.tmp'
    try {
        $bytes = [System.Text.UTF8Encoding]::new($false).GetBytes((ConvertTo-Json -InputObject $Journal -Depth 14 -ErrorAction Stop))
        $stream = [System.IO.File]::Open($temp, [System.IO.FileMode]::CreateNew, [System.IO.FileAccess]::Write, [System.IO.FileShare]::None)
        try { $stream.Write($bytes, 0, $bytes.Length); $stream.Flush($true) } finally { $stream.Dispose() }
        if ([System.IO.File]::Exists($path)) { [System.IO.File]::Replace($temp, $path, [System.Management.Automation.Language.NullString]::Value) }
        else { [System.IO.File]::Move($temp, $path) }
        $temp = $null
    } finally { if ($temp -and [System.IO.File]::Exists($temp)) { try { [System.IO.File]::Delete($temp) } catch { Write-FileLog "WARN journal temp: $($_.Exception.Message)" } } }
    return $path
}

function Read-KhoJournals {
    # Every journal file as @{ Path; Journal; Error }. An unreadable file is reported (it keeps blocking), never deleted.
    $dir = Get-KhoMovesDir
    $list = New-Object System.Collections.Generic.List[object]
    if (-not [System.IO.Directory]::Exists($dir)) { return @() }
    foreach ($f in [System.IO.DirectoryInfo]::new($dir).GetFiles('*.json')) {
        if (-not $f.Name.EndsWith('.json', [StringComparison]::OrdinalIgnoreCase)) { continue }
        try {
            $j = [System.IO.File]::ReadAllText($f.FullName, [System.Text.Encoding]::UTF8) | ConvertFrom-Json -ErrorAction Stop
            if ($null -eq $j -or -not [string]$j.txid -or -not [string]$j.from -or -not [string]$j.to) { throw 'Thiếu trường bắt buộc.' }
            $list.Add(@{ Path = $f.FullName; Journal = $j; Error = '' })
        } catch { $list.Add(@{ Path = $f.FullName; Journal = $null; Error = $_.Exception.Message }) }
    }
    return $list.ToArray()
}

function Get-KhoJournalBlock {
    # Message when an unresolved journal reserves one of the folders (or any, when unreadable), otherwise ''.
    param([string[]]$Roots)
    $set = @{}
    foreach ($r in @($Roots)) { if ($r) { $set[(Get-CanonicalPath $r).ToUpperInvariant()] = $true } }
    foreach ($e in @(Read-KhoJournals)) {
        if (-not $e.Journal) { return "Có file nhật ký chuyển kho không đọc được ($([IO.Path]::GetFileName($e.Path))). Kiểm tra thư mục data\kho-moves rồi mở lại ứng dụng." }
        foreach ($p in @($e.Journal.from, $e.Journal.to)) {
            if ($p -and $set.ContainsKey((Get-CanonicalPath ([string]$p)).ToUpperInvariant())) {
                return "Có lần chuyển video #$($e.Journal.id) chưa hoàn tất giữa '$($e.Journal.from)' và '$($e.Journal.to)'. Kho này bị khóa chuyển/xóa cho tới khi xử lý (Quản lý kho › 'Có lần chuyển kho dở dang' › Thử hoàn tất, hoặc Bỏ qua để giữ file tại chỗ)."
            }
        }
    }
    return ''
}

function Get-KhoBlockedRoots {
    # Canonical folders reserved by unresolved move journals (HashSet, case-insensitive); $null when a journal cannot be read
    # (then no folder can be trusted). Reads the small journal folder only, never a reup-status.json.
    $set = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    foreach ($e in @(Read-KhoJournals)) {
        if (-not $e.Journal) { return $null }
        foreach ($p in @($e.Journal.from, $e.Journal.to)) { if ($p) { [void]$set.Add((Get-CanonicalPath ([string]$p))) } }
    }
    return , $set
}

function Get-KhoReservedIds {
    # Video ids that an unresolved move journal reserves in this kho folder (it is the journal's source or target): metadata writes for them
    # wait until recovery completes, otherwise recovery would overwrite them. Hashtable id -> $true; key '*' = a journal is unreadable, so
    # nothing can be trusted. Reads the small journal folder only.
    param([string]$Root)
    $set = @{}
    if (-not $Root) { return $set }
    $canon = (Get-CanonicalPath $Root).ToUpperInvariant()
    foreach ($e in @(Read-KhoJournals)) {
        if (-not $e.Journal) { $set['*'] = $true; continue }
        foreach ($p in @($e.Journal.from, $e.Journal.to)) {
            if ($p -and (Get-CanonicalPath ([string]$p)).ToUpperInvariant() -eq $canon) { $set[[string]$e.Journal.id] = $true }
        }
    }
    return $set
}

function Test-KhoIdReserved {
    param([string]$Root, [string]$VideoId)
    $set = Get-KhoReservedIds $Root
    return ($set.ContainsKey('*') -or $set.ContainsKey([string]$VideoId))
}

function Initialize-KhoCacheDir {
    param([string]$Dir)
    if ([System.IO.Directory]::Exists($Dir)) { return }
    [void][System.IO.Directory]::CreateDirectory($Dir)
    try { [System.IO.File]::SetAttributes($Dir, [System.IO.FileAttributes]::Directory -bor [System.IO.FileAttributes]::Hidden) }
    catch { Write-FileLog "WARN Không đặt được thuộc tính ẩn cho '$Dir': $($_.Exception.Message)" }
}

function Get-KhoReceiptGroups {
    # Files of <root>\.cache\tiktok-posts grouped by request id: @{ VideoId; Files; Live } (VideoId read from the receipt, else the
    # .job; '' when unknown). Live = a .job or .lock (running OR kept for retry) exists.
    param([Alias('Root')][string]$KhoRoot)
    $dir = Join-Path (Join-Path $KhoRoot '.cache') 'tiktok-posts'
    $groups = @{}
    if (-not [System.IO.Directory]::Exists($dir)) { return $groups }
    foreach ($f in [System.IO.DirectoryInfo]::new($dir).GetFiles()) {
        $m = [regex]::Match($f.Name, '^([a-f0-9]{32})\.(.+)$')
        if (-not $m.Success) { continue }
        $req = $m.Groups[1].Value; $rest = $m.Groups[2].Value
        if (-not $groups.ContainsKey($req)) { $groups[$req] = @{ VideoId = ''; Files = (New-Object System.Collections.Generic.List[object]); Live = $false } }
        $g = $groups[$req]
        $g.Files.Add(@{ Path = $f.FullName; Name = $f.Name; Rest = $rest })
        if ($rest -ceq 'job' -or $rest -ceq 'lock') { $g.Live = $true }
    }
    foreach ($req in @($groups.Keys)) {
        $g = $groups[$req]
        $source = @($g.Files | Where-Object { $_.Rest -cmatch '^json(\.archived-.+)?$' } | Sort-Object { $_.Rest.Length }) + @($g.Files | Where-Object { $_.Rest -cmatch '^job(\.archived-.+)?$' })
        foreach ($f in $source) {
            try {
                $doc = [System.IO.File]::ReadAllText($f.Path, [System.Text.Encoding]::UTF8) | ConvertFrom-Json -ErrorAction Stop
                $vid = $(if ($f.Rest -cmatch '^json') { [string]$doc.VideoId } else { [string]$doc.Record.VideoId })
                if (Test-KhoVideoKey $vid) { $g.VideoId = $vid; break }
            } catch { Write-FileLog "WARN Không đọc được biên nhận '$($f.Name)': $($_.Exception.Message)" }
        }
    }
    return $groups
}

function Get-KhoVideoBlock {
    # S2: '' when nothing about this video's TikTok jobs blocks a move / delete; otherwise the Vietnamese reason. Any .job / .lock of
    # the video in its folder blocks it (running or kept for retry). A job whose video cannot be read blocks the whole folder.
    param([Alias('Root')][string]$KhoRoot, [string]$Id, $Groups = $null)
    if ($null -eq $Groups) { $Groups = Get-KhoReceiptGroups $KhoRoot }
    foreach ($req in $Groups.Keys) {
        $g = $Groups[$req]
        if (-not $g.Live) { continue }
        if ($g.VideoId -ceq $Id) { return 'Video có lệnh đăng chưa xong hoặc lỗi chưa xử lý — Thử lại hoặc Lưu trữ trước.' }
        if (-not $g.VideoId) { return 'Thư mục có lệnh đăng không rõ thuộc video nào (xem Lịch sử đăng) — xử lý trước.' }
    }
    if (Test-TikTokTransferActive (Get-KhoVideoPath $KhoRoot $Id)) { return 'Video đang được chuyển sang bộ đăng nền.' }
    return ''
}

function New-KhoMovePlan {
    # Ordered renames of one video: -1/-2 (.cache and legacy root), thumbnail + probe cache (optional), TikTok receipts (finished /
    # archived, by VideoId), and LAST the -3. Only files that exist are listed.
    param([string]$Id, [string]$FromRoot, [string]$ToRoot, $Groups = $null)
    $items = New-Object System.Collections.Generic.List[object]
    $add = { param($src, $dst, $optional, $kind) if ([System.IO.File]::Exists($src)) { $items.Add([ordered]@{ src = $src; dst = $dst; optional = [bool]$optional; kind = $kind; status = 'pending' }) } }
    $fc = Join-Path $FromRoot '.cache'; $tc = Join-Path $ToRoot '.cache'
    # Video ngoài không có -1/-2: chỉ ảnh thu nhỏ, biên nhận đã xong và chính file.
    foreach ($leaf in $(if (Test-KhoExternalKey $Id) { @() } else { @("$Id-1-video-goc.mp4", "$Id-2-am-thanh-tho.m4a") })) {
        & $add (Join-Path $fc $leaf) (Join-Path $tc $leaf) $false 'companion'
        & $add (Join-Path $FromRoot $leaf) (Join-Path $ToRoot $leaf) $false 'legacy-companion'
    }
    $tk = Get-KhoThumbKey $Id
    foreach ($ext in @('jpg', 'json')) { & $add (Join-Path (Join-Path $fc 'thumbs') "$tk.$ext") (Join-Path (Join-Path $tc 'thumbs') "$tk.$ext") $true 'thumb' }
    if ($null -eq $Groups) { $Groups = Get-KhoReceiptGroups $FromRoot }
    foreach ($req in @($Groups.Keys | Sort-Object)) {
        $g = $Groups[$req]
        if ($g.VideoId -cne $Id) { continue }
        foreach ($f in @($g.Files | Sort-Object { $_.Name })) {
            & $add $f.Path (Join-Path (Join-Path $tc 'tiktok-posts') $f.Name) $false $(if ($f.Rest -ceq 'json') { 'receipt' } else { 'receipt-archive' })
        }
    }
    & $add (Get-KhoVideoPath $FromRoot $Id) (Get-KhoVideoPath $ToRoot $Id) $false 'final'
    return $items.ToArray()
}

function Invoke-KhoMoveRename {
    # One rename of a journal; idempotent: src only -> move; dst only -> already done; both -> conflict (mandatory) / skipped (optional).
    # Returns 'moved' | 'done' | 'skipped' | 'conflict' | 'failed'.
    param($Rename)
    $src = [string]$Rename.src; $dst = [string]$Rename.dst; $optional = [bool]$Rename.optional
    $se = [System.IO.File]::Exists($src); $de = [System.IO.File]::Exists($dst)
    if (-not $se -and $de) { return 'done' }
    if ($se -and $de) { return $(if ($optional) { 'skipped' } else { 'conflict' }) }
    if (-not $se) { return $(if ($optional) { 'skipped' } else { 'failed' }) }
    $lastError = ''
    for ($try = 1; $try -le 4; $try++) {
        try {
            $parent = [IO.Path]::GetDirectoryName($dst)
            if ([IO.Path]::GetFileName($parent) -ceq 'thumbs' -or [IO.Path]::GetFileName($parent) -ceq 'tiktok-posts') { Initialize-KhoCacheDir ([IO.Path]::GetDirectoryName($parent)) }
            elseif ([IO.Path]::GetFileName($parent) -ceq '.cache') { Initialize-KhoCacheDir $parent }
            [void][System.IO.Directory]::CreateDirectory($parent)
            [System.IO.File]::Move($src, $dst)
            return 'moved'
        } catch {
            $lastError = $_.Exception.Message
            if ([System.IO.File]::Exists($dst) -and -not [System.IO.File]::Exists($src)) { return 'moved' }
            if ($try -lt 4) { Start-Sleep -Milliseconds 150 }
        }
    }
    Write-FileLog "WARN Chuyển kho: không đổi tên được '$src' -> '$dst': $lastError"
    $Rename.error = $lastError
    return $(if ($optional) { 'skipped' } else { 'failed' })
}

function Update-KhoReceiptPaths {
    # A moved finished receipt must name its new folder, or the receipt reader rejects it. Idempotent.
    param([string]$ReceiptPath, [string]$NewRoot, [string]$Id)
    if (-not [System.IO.File]::Exists($ReceiptPath)) { return }
    try { $rec = [System.IO.File]::ReadAllText($ReceiptPath, [System.Text.Encoding]::UTF8) | ConvertFrom-Json -ErrorAction Stop }
    catch { Write-FileLog "WARN Chuyển kho: không đọc được biên nhận '$ReceiptPath': $($_.Exception.Message)"; return }
    $newSource = Get-KhoVideoPath $NewRoot $Id
    if ((Test-SamePath ([string]$rec.OutDir) $NewRoot) -and (Test-SamePath ([string]$rec.SourcePath) $newSource)) { return }
    Set-ReupField $rec 'OutDir' $NewRoot
    Set-ReupField $rec 'SourcePath' $newSource
    Save-TikTokReceipt $rec
}

function Copy-ReupEntry {
    # Deep copy of one metadata entry without the labels of the old logical kho.
    param($Entry)
    $clone = ConvertFrom-Json -InputObject (ConvertTo-Json -InputObject $Entry -Depth 12 -Compress)
    foreach ($n in @('Kho', 'KhoManual')) { if ($clone.PSObject.Properties[$n]) { [void]$clone.PSObject.Properties.Remove($n) } }
    return $clone
}

function Test-ReupConfirmed {
    # The entry has a confirmed post (succeeded, not publish_uncertain).
    param($Entry)
    if ($null -eq $Entry) { return $false }
    return (@(@($Entry.History) | Where-Object { $_ -and [string]$_.status -eq 'succeeded' -and $_.publish_uncertain -ne $true }).Count -gt 0)
}

function Merge-KhoMoveEntry {
    # S4: puts the source entry (snapshot) into the target metadata. No target entry -> a copy. Otherwise history is united by key
    # (target wins), the manual state is normalised through Get-ReupManualState (kept when either side marked it), fields only the
    # source has are kept, KhoPinned is kept when either side has it. Idempotent. Returns $true when the target changed.
    param($Meta, [string]$Id, $Snapshot)
    if ($null -eq $Snapshot) { return $false }
    $prop = $Meta.PSObject.Properties[$Id]
    if (-not $prop -or $null -eq $prop.Value) {
        $Meta | Add-Member -MemberType NoteProperty -Name $Id -Force -Value (Copy-ReupEntry $Snapshot)
        return $true
    }
    $mine = $prop.Value
    $before = ConvertTo-Json -InputObject $mine -Depth 12 -Compress
    $ms = Get-ReupManualState $Snapshot; $mm = Get-ReupManualState $mine
    $posted = [bool]($ms.Posted -or $mm.Posted)
    $date = $(if ($mm.Posted) { [string]$mm.Date } elseif ($ms.Posted) { [string]$ms.Date } else { '' })
    if ($mine.Source -eq 'autotok-history' -or $Snapshot.Source -eq 'autotok-history') {
        $have = @{}
        foreach ($h in @($mine.History)) { if ($h -and [string]$h.key) { $have[[string]$h.key] = $true } }
        $extra = @(@($Snapshot.History) | Where-Object { $_ -and [string]$_.key -and -not $have.ContainsKey([string]$_.key) } | ForEach-Object { ConvertTo-TikTokHistoryEntry $_ })
        $union = @(@($mine.History | Where-Object { $_ }) + $extra | Sort-Object { Get-TikTokSortKey ([string]$_.created_at) } -Descending)
        Set-ReupField $mine 'Source' 'autotok-history'
        Set-ReupField $mine 'History' $union
        Set-ReupField $mine 'ManualPosted' $posted
        Set-ReupField $mine 'ManualDate' $date
        if (-not [string]$mine.FileSha256 -and [string]$Snapshot.FileSha256) { Set-ReupField $mine 'FileSha256' ([string]$Snapshot.FileSha256) }
        Update-ReupAggregate $mine
    } else {
        Set-ReupField $mine 'Posted' $posted
        Set-ReupField $mine 'Date' $date
    }
    foreach ($p in $Snapshot.PSObject.Properties) {
        if ($p.Name -in @('Kho', 'KhoManual', 'KhoPinned')) { continue }
        if (-not $mine.PSObject.Properties[$p.Name]) { $mine | Add-Member -MemberType NoteProperty -Name $p.Name -Value $p.Value -Force }
    }
    if ($Snapshot.KhoPinned -eq $true -and $mine.KhoPinned -ne $true) { Set-ReupField $mine 'KhoPinned' $true }
    return ($before -cne (ConvertTo-Json -InputObject $mine -Depth 12 -Compress))
}

function Resume-KhoMove {
    # Finishes one journalled move from its recorded phase; every step is idempotent, so it also repairs a crash at any point.
    # Returns @{ Done; Conflict; Error }. Not done = the journal stays and blocks both folders.
    param($Journal, [string]$JournalPath)
    $id = [string]$Journal.id; $to = [string]$Journal.to; $from = [string]$Journal.from
    $phase = [string]$Journal.phase
    if ($phase -eq 'renaming') {
        foreach ($r in @($Journal.renames)) {
            if ($r.PSObject.Properties['error'] -eq $null) { $r | Add-Member -NotePropertyName error -NotePropertyValue '' -Force }
            $state = Invoke-KhoMoveRename $r
            $r.status = $state
            if ($state -eq 'conflict' -or $state -eq 'failed') {
                $why = $(if ($state -eq 'conflict') { "đã có file cùng tên ở đích: $([IO.Path]::GetFileName([string]$r.dst))" } else { "không đổi tên được $([IO.Path]::GetFileName([string]$r.src))$(if ($r.error) { ' (' + $r.error + ')' })" })
                try { [void](Write-KhoJournal $Journal) } catch { Write-FileLog "WARN Không ghi được nhật ký chuyển kho: $($_.Exception.Message)" }
                Add-KhoMoveLog "STOP #$id $from -> $to : $why"
                return @{ Done = $false; Conflict = ($state -eq 'conflict'); Error = $why }
            }
        }
        foreach ($r in @($Journal.renames)) { if ([string]$r.kind -eq 'receipt' -and [string]$r.status -in @('moved', 'done')) { Update-KhoReceiptPaths ([string]$r.dst) $to $id } }
        $snapshot = $Journal.sourceEntrySnapshot
        # A journal without a snapshot (nothing was known at planning time): the source entry that still exists is the truth.
        if ($null -eq $snapshot) {
            $currentSource = (Get-ReupMetadata -OutDir $from).PSObject.Properties[$id]
            if ($currentSource -and $null -ne $currentSource.Value) { $snapshot = Copy-ReupEntry $currentSource.Value }
        }
        if ($null -ne $snapshot) {
            [void](Update-ReupMetadata -OutDir $to -Change { param($meta) return (Merge-KhoMoveEntry $meta $id $snapshot) })
        }
        $Journal.phase = 'meta-target-done'
        [void](Write-KhoJournal $Journal)
        $phase = 'meta-target-done'
    }
    if ($phase -eq 'meta-target-done') {
        [void](Update-ReupMetadata -OutDir $from -Change {
            param($meta)
            if (-not $meta.PSObject.Properties[$id]) { return $false }
            [void]$meta.PSObject.Properties.Remove($id)
            return $true
        })
        $Journal.phase = 'meta-source-done'
        [void](Write-KhoJournal $Journal)
    }
    try { [System.IO.File]::Delete($JournalPath) } catch { Write-FileLog "WARN Không xóa được nhật ký chuyển kho '$JournalPath': $($_.Exception.Message)"; return @{ Done = $false; Conflict = $false; Error = 'Không xóa được nhật ký.' } }
    Add-KhoMoveLog "OK   #$id $from -> $to ($([string]$Journal.reason))"
    return @{ Done = $true; Conflict = $false; Error = '' }
}

function Resume-KhoMoves {
    # Recovery: roll every pending journal forward. Returns @{ Done; Pending (messages) }. Runs at startup before the gallery / sync
    # start and before each move batch.
    $done = 0; $pending = New-Object System.Collections.Generic.List[string]
    foreach ($e in @(Read-KhoJournals)) {
        if (-not $e.Journal) { $pending.Add("Nhật ký chuyển kho hỏng: $([IO.Path]::GetFileName($e.Path)) ($($e.Error))"); continue }
        try {
            $r = Resume-KhoMove $e.Journal $e.Path
            if ($r.Done) { $done++ } else { $pending.Add("Video #$($e.Journal.id): $($r.Error)") }
        } catch {
            Write-FileLog "ERR  Hoàn tất chuyển kho #$($e.Journal.id): $($_.Exception.Message)`r`n$($_.ScriptStackTrace)"
            $pending.Add("Video #$($e.Journal.id): $($_.Exception.Message)")
        }
    }
    return @{ Done = $done; Pending = $pending.ToArray() }
}

function Get-KhoStuckMoves {
    # Journals still on disk = moves that startup / the last batch could not finish. @{ Path; Text } per journal (unreadable ones too).
    $list = New-Object System.Collections.Generic.List[object]
    foreach ($e in @(Read-KhoJournals)) {
        $name = [IO.Path]::GetFileName([string]$e.Path)
        if (-not $e.Journal) { $list.Add(@{ Path = [string]$e.Path; Text = "Nhật ký hỏng $name ($($e.Error))" }); continue }
        $list.Add(@{ Path = [string]$e.Path; Text = "Video $(Get-ReelLabel ([string]$e.Journal.id)): '$($e.Journal.from)' → '$($e.Journal.to)' (bước: $([string]$e.Journal.phase))" })
    }
    return $list.ToArray()
}

function Move-KhoJournalAside {
    # "Bỏ qua": the journal moves to data\kho-moves\abandoned\ (never deleted); files stay exactly where they are. Returns the new path.
    param([string]$JournalPath)
    $dir = Get-KhoMovesDir
    $full = [IO.Path]::GetFullPath($JournalPath)
    if (-not (Test-SamePath ([IO.Path]::GetDirectoryName($full)) $dir)) { throw 'Chỉ bỏ qua được nhật ký nằm trong data\kho-moves.' }
    if (-not [System.IO.File]::Exists($full)) { throw 'Không thấy file nhật ký (có thể đã được xử lý).' }
    $abandoned = Join-Path $dir 'abandoned'
    [void][System.IO.Directory]::CreateDirectory($abandoned)
    $dest = Join-Path $abandoned ([IO.Path]::GetFileNameWithoutExtension($full) + '.' + (Get-Date).ToString('yyyyMMdd-HHmmss') + '-' + [Guid]::NewGuid().ToString('N').Substring(0, 6) + '.json')
    [System.IO.File]::Move($full, $dest)
    Add-KhoMoveLog "SKIP nhật ký $([IO.Path]::GetFileName($full)) được bỏ qua theo yêu cầu (file giữ nguyên tại chỗ) -> $dest"
    return $dest
}

function Initialize-KhoStartup {
    # Luc khoi dong, TRUOC khi quet kho va truoc khi dong bo TikTok chay: nap (hoac tao/chuyen doi) data\kho.json, hoan tat cac lan chuyen kho
    # dang do tu nhat ky, roi dong bo duong dan tuong thich. Khong nem loi.
    $script:khoRegistry = $null
    try { [void](Get-KhoRegistry) } catch { Write-FileLog "ERR  Nạp kho.json: $($_.Exception.Message)" -Immediate; $script:khoRegistryReady = $false }
    try {
        $r = Resume-KhoMoves
        if ($r.Done) { Add-Log "Đã hoàn tất $($r.Done) lần chuyển video dở dang từ lần chạy trước." 'Info' }
        if ($r.Pending.Count) {
            foreach ($m in $r.Pending) { Add-Log "Chuyển kho dở dang chưa xử lý được: $m" 'Warning' }
            Show-Toast 'Có lần chuyển video giữa các kho chưa hoàn tất. Hai kho liên quan bị khóa chuyển/xóa; xem Cài đặt › Nhật ký.' -Kind warning
        }
    } catch { Write-FileLog "ERR  Khôi phục chuyển kho: $($_.Exception.Message)`r`n$($_.ScriptStackTrace)" -Immediate; Add-Log "Không khôi phục được chuyển kho dở dang: $($_.Exception.Message)" 'Warning' }
    Sync-OutDirFromKho
}

function Move-KhoVideos {
    # PRE: the caller checked Test-KhoQuiet and paused the sync. Moves each video (serially, one journal each) into $ToRoot.
    # $Videos: @{ Id; From }. -Manual: a video that already has a confirmed post gets KhoPinned (auto-move leaves it).
    # Returns @{ Moved = @(ids); Failed = @(@{ Id; Why }) }.
    param([object[]]$Videos, [string]$ToRoot, [switch]$Manual)
    $moved = New-Object System.Collections.Generic.List[string]
    $failed = New-Object System.Collections.Generic.List[object]
    $to = Get-CanonicalPath $ToRoot
    $groupCache = @{}
    foreach ($v in @($Videos)) {
        $id = [string]$v.Id; $from = Get-CanonicalPath ([string]$v.From)
        $why = ''
        try {
            if (-not (Test-KhoVideoKey $id)) { throw 'ID video không hợp lệ.' }
            if (Test-SamePath $from $to) { throw 'Video đã ở kho này.' }
            $block = Get-KhoJournalBlock @($from, $to)
            if ($block) { throw $block }
            if (-not $groupCache.ContainsKey($from.ToUpperInvariant())) { $groupCache[$from.ToUpperInvariant()] = Get-KhoReceiptGroups $from }
            $groups = $groupCache[$from.ToUpperInvariant()]
            $block = Get-KhoVideoBlock $from $id $groups
            if ($block) { throw $block }
            $plan = @(New-KhoMovePlan $id $from $to $groups)
            if (-not @($plan | Where-Object { $_.kind -eq 'final' }).Count) { throw 'Không thấy file video hoàn chỉnh (-3) ở kho nguồn.' }
            foreach ($r in $plan) {
                if (-not [System.IO.File]::Exists([string]$r.src)) { throw "Thiếu file nguồn $([IO.Path]::GetFileName([string]$r.src))." }
                if (-not $r.optional -and [System.IO.File]::Exists([string]$r.dst)) { throw "Kho đích đã có $([IO.Path]::GetFileName([string]$r.dst)); không ghi đè." }
            }
            $finalSrc = [string]@($plan | Where-Object { $_.kind -eq 'final' })[0].src
            try { [System.IO.File]::Open($finalSrc, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::None).Dispose() }
            catch { throw 'Video đang được mở ở ứng dụng khác (xem trước hoặc trình phát). Đóng rồi thử lại.' }
            $snapshot = $null
            $meta = Get-ReupMetadata -OutDir $from
            $prop = $meta.PSObject.Properties[$id]
            if ($prop -and $null -ne $prop.Value) {
                $snapshot = Copy-ReupEntry $prop.Value
                if ($Manual -and (Test-ReupConfirmed $snapshot)) { Set-ReupField $snapshot 'KhoPinned' $true }
            }
            $journal = [ordered]@{
                version = 1; txid = [Guid]::NewGuid().ToString('N'); id = $id; from = $from; to = $to; phase = 'renaming'
                reason = $(if ($Manual) { 'manual' } else { 'auto' }); createdAt = [DateTime]::UtcNow.ToString('o')
                renames = @($plan); sourceEntrySnapshot = $snapshot
            }
            $path = Write-KhoJournal $journal
            $saved = [System.IO.File]::ReadAllText($path, [System.Text.Encoding]::UTF8) | ConvertFrom-Json
            $r = Resume-KhoMove $saved $path
            if (-not $r.Done) { throw $r.Error }
            $moved.Add($id)
        } catch {
            $why = $_.Exception.Message
            Write-FileLog "WARN Chuyển kho #$id : $why"
            $failed.Add(@{ Id = $id; Why = $why })
        }
    }
    return @{ Moved = $moved.ToArray(); Failed = $failed.ToArray() }
}

function Release-KhoPlayer {
    # The preview player must not hold a -3 that is about to move or go to the Recycle Bin.
    param([string[]]$Paths)
    if (-not $ui -or -not $ui.Player) { return }
    try {
        $open = @()
        if ($script:lastOut) { $open += [IO.Path]::GetFullPath([string]$script:lastOut) }
        if ($ui.Player.Source -and $ui.Player.Source.IsFile) { $open += [IO.Path]::GetFullPath($ui.Player.Source.LocalPath) }
        foreach ($p in @($Paths)) {
            foreach ($o in $open) { if ([string]::Equals([IO.Path]::GetFullPath($p), $o, [StringComparison]::OrdinalIgnoreCase)) { Clear-Player; return } }
        }
    } catch { Write-FileLog "WARN Release-KhoPlayer: $($_.Exception.Message)" }
}

function Test-KhoQuiet {
    # '' when nothing else can touch the kho folders (S1): no download / record-again / re-edit / import / move / dialog / cleanup /
    # backend install. Otherwise the reason (Vietnamese, lower case). The TikTok sync is handled by Suspend-TikTokSync.
    if ($script:khoMoveRunning) { return 'đang chuyển kho' }
    if ($script:ps -or $script:stopping -or ($script:queue -and @($script:queue).Count -gt 0)) { return 'đang tải, ghi âm hoặc sửa video' }
    if ($script:importBusy) { return 'đang thêm video từ thư mục' }
    if (Test-SpreadRunActive) { return 'đang rải lịch đăng TikTok' }
    if ($script:khoExclusive -gt 0) { return 'đang mở hộp thoại đăng, rải lịch hoặc dọn dẹp' }
    # A closed dialog's preparation worker (writes metadata) may still be stopping: an unfinished retiring task keeps the folders busy.
    if ($script:tikTokReaper -and @($script:tikTokReaper.Tasks | Where-Object { -not $_.Async.IsCompleted -or ($_.StopAsync -and -not $_.StopAsync.IsCompleted) }).Count) { return 'đang dừng tác vụ chuẩn bị đăng TikTok' }
    if ($script:autotokInstall -or (Test-AutotokUpgradeActive)) { return 'đang cài hoặc cập nhật bộ đăng' }
    return ''
}

function Suspend-TikTokSync {
    # Pauses new sync passes and lets a running one finish (never cancelled mid-write). Returns $true when no pass is running.
    param([int]$TimeoutMs = 8000)
    $sync = $script:tikTokSync
    if (-not $sync) { return $true }
    $sync.Paused = $true
    $sw = [Diagnostics.Stopwatch]::StartNew()
    while (($sync.Task -or $sync.Fast) -and $sw.ElapsedMilliseconds -lt $TimeoutMs) {
        try { Invoke-TikTokSyncTick } catch { Write-FileLog "WARN Chờ đồng bộ xong: $($_.Exception.Message)" }
        if ($sync.Task -or $sync.Fast) { Start-Sleep -Milliseconds 50 }
    }
    return -not ($sync.Task -or $sync.Fast)
}

function Resume-TikTokSync {
    if ($script:tikTokSync) { $script:tikTokSync.Paused = $false }
}

function Invoke-KhoMove {
    # The one entry for moving videos between khos (manual menu and auto-move). Items need Id and Path (the -3 file). Runs only when the
    # app is quiet. Returns @{ Moved; Failed; Busy; Target }; Busy is the reason when nothing was attempted.
    param([object[]]$Items, [string]$TargetId, [ValidateSet('manual', 'auto')][string]$Reason = 'manual')
    $result = @{ Moved = @(); Failed = @(); Busy = ''; Target = $null }
    $target = Get-KhoById $TargetId
    if (-not $target) { throw 'Không tìm thấy kho đích.' }
    $result.Target = $target
    $busy = Test-KhoQuiet
    if ($busy) { $result.Busy = $busy; return $result }
    $script:khoMoveRunning = $true
    try {
        if (-not (Suspend-TikTokSync)) { $result.Busy = 'đang đồng bộ TikTok'; return $result }
        # Finish what can be finished; a journal that stays stuck blocks only ITS two folders (Move-KhoVideos checks per folder).
        $recovered = Resume-KhoMoves
        foreach ($m in @($recovered.Pending)) { Write-FileLog "WARN Chuyển kho dở dang chưa xử lý được (chỉ khóa kho liên quan): $m" }
        $videos = @(@($Items) | Where-Object { $_ -and [string]$_.Id -and [string]$_.Path } | ForEach-Object { @{ Id = [string]$_.Id; From = [IO.Path]::GetDirectoryName([IO.Path]::GetFullPath([string]$_.Path)) } } | Where-Object { -not (Test-SamePath $_.From ([string]$target.path)) })
        Release-KhoPlayer @($videos | ForEach-Object { Get-KhoVideoPath $_.From $_.Id })
        $batch = Move-KhoVideos -Videos $videos -ToRoot ([string]$target.path) -Manual:($Reason -eq 'manual')
        $result.Moved = @($batch.Moved); $result.Failed = @($batch.Failed)
        return $result
    } finally {
        $script:khoMoveRunning = $false
        Resume-TikTokSync
    }
}

function Get-KhoAutoMoveCandidates {
    # Pure. Videos in a kho WITHOUT an account whose earliest confirmed post (succeeded, not uncertain, accepted_at >= autoMoveSince,
    # a username) is on an account; not pinned (S5); the -3 file exists. Videos already in an account kho never move by themselves.
    # $MetaByRoot: canonical kho folder -> metadata object. Returns @{ Id; From; Username; When }.
    param($Registry, $MetaByRoot)
    $since = [long]0
    if ([string]$Registry.autoMoveSince) { $since = Get-TikTokSortKey ([string]$Registry.autoMoveSince) }
    $out = New-Object System.Collections.Generic.List[object]
    foreach ($lib in @($Registry.libraries)) {
        if ([string]$lib.account) { continue }
        $meta = $MetaByRoot[[string]$lib.path]
        if ($null -eq $meta) { continue }
        foreach ($p in $meta.PSObject.Properties) {
            $entry = $p.Value
            if ($null -eq $entry -or $entry.Source -ne 'autotok-history' -or $entry.KhoPinned -eq $true) { continue }
            $best = $null; $bestKey = [long]::MaxValue
            foreach ($h in @($entry.History)) {
                if ($null -eq $h -or [string]$h.status -ne 'succeeded' -or $h.publish_uncertain -eq $true -or -not (ConvertTo-KhoUsername ([string]$h.username))) { continue }
                $key = Get-TikTokSortKey ([string]$h.accepted_at)
                if ($key -le 0 -or $key -lt $since) { continue }
                if ($key -lt $bestKey) { $bestKey = $key; $best = $h }
            }
            if ($null -eq $best) { continue }
            if (-not [System.IO.File]::Exists((Get-KhoVideoPath ([string]$lib.path) ([string]$p.Name)))) { continue }
            $out.Add(@{ Id = [string]$p.Name; From = [string]$lib.path; Username = (ConvertTo-KhoUsername ([string]$best.username)); When = $bestKey })
        }
    }
    return $out.ToArray()
}

function Invoke-KhoAutoMove {
    # After a sync pass: moves newly confirmed videos into their account kho (created when missing, next to the download kho).
    # Not quiet -> deferred (NOT retried every tick): the tick re-arms it when the app turns quiet; a sync pass that changes history re-arms it too.
    # Returns the number of videos moved.
    param($MetaByRoot)
    if (-not $script:khoRegistryReady) { return 0 }
    if (Test-KhoQuiet) { $script:khoAutoMoveWanted = $false; $script:khoAutoMoveDeferred = $true; return 0 }
    $reg = Get-KhoRegistry
    $cands = @(Get-KhoAutoMoveCandidates $reg $MetaByRoot)
    $script:khoAutoMoveWanted = $false
    if (-not $cands.Count) { return 0 }
    $movedTotal = 0
    foreach ($group in @($cands | Group-Object { $_.Username.ToLowerInvariant() })) {
        $user = $group.Group[0].Username
        $lib = Get-KhoForAccount $user
        if (-not $lib) {
            $last = $script:khoAutoMoveFailed[$user.ToLowerInvariant()]
            if ($last -and ([DateTime]::UtcNow - $last).TotalMinutes -lt 10) { continue }
            try { $lib = New-KhoForAccount $user; Write-FileLog "INFO Tự tạo kho '$($lib.name)' tại '$($lib.path)' cho @$user." }
            catch { $script:khoAutoMoveFailed[$user.ToLowerInvariant()] = [DateTime]::UtcNow; Write-FileLog "WARN Không tự tạo được kho cho @${user}: $($_.Exception.Message)"; continue }
        }
        $items = @($group.Group | ForEach-Object { [pscustomobject]@{ Id = $_.Id; Path = (Get-KhoVideoPath $_.From $_.Id) } })
        $r = Invoke-KhoMove -Items $items -TargetId ([string]$lib.id) -Reason auto
        if ($r.Busy) { $script:khoAutoMoveWanted = $true; return $movedTotal }
        $movedTotal += @($r.Moved).Count
        foreach ($f in @($r.Failed)) { Write-FileLog "WARN Tự chuyển #$($f.Id) sang '$($lib.name)': $($f.Why)" }
    }
    return $movedTotal
}

# ------------------------------------------------------------- xoa video / xoa kho: Thung rac ----
$script:khoRecycleOverride = $null   # test seam: scriptblock { param($Path, $IsFolder) } replacing the shell call


function Test-KhoRecycleBin {
    # Does the Windows Recycle Bin work for $Path? Not for network (UNC / mapped) drives, removable / optical / RAM drives, or subst / virtual drives
    # (QueryDosDevice target starts with \??\). Returns @{ Ok; Reason } with the Vietnamese reason when not.
    param([string]$Path)
    if (-not ([System.Management.Automation.PSTypeName]'KidDosDevice').Type) {
        Add-Type -TypeDefinition @"
using System.Runtime.InteropServices;
using System.Text;
public static class KidDosDevice {
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    static extern uint QueryDosDevice(string name, StringBuilder buffer, int max);
    public static string Query(string name) { var sb = new StringBuilder(2048); return QueryDosDevice(name, sb, sb.Capacity) == 0 ? "" : sb.ToString(); }
}
"@
    }
    $full = [System.IO.Path]::GetFullPath($Path)
    if ($full.StartsWith('\\')) { return @{ Ok = $false; Reason = 'thư mục mạng (UNC)' } }
    $drive = [System.IO.Path]::GetPathRoot($full)
    if ($drive -notmatch '^[A-Za-z]:\\$') { return @{ Ok = $false; Reason = 'không xác định được ổ đĩa' } }
    try {
        $type = [System.IO.DriveInfo]::new($drive).DriveType
        if ($type -ne [System.IO.DriveType]::Fixed) { return @{ Ok = $false; Reason = "ổ $($drive.Substring(0, 2)) là ổ $type (không phải ổ cứng cố định)" } }
    } catch { return @{ Ok = $false; Reason = "không đọc được loại ổ $($drive.Substring(0, 2)): $($_.Exception.Message)" } }
    $target = [KidDosDevice]::Query($drive.Substring(0, 2))
    if ($target.StartsWith('\??\')) { return @{ Ok = $false; Reason = "ổ $($drive.Substring(0, 2)) là ổ ảo (subst) trỏ tới $($target.Substring(4))" } }
    return @{ Ok = $true; Reason = '' }
}

function Get-KhoNoRecycleReason {
    # '' when the Windows Recycle Bin works for $Path, otherwise the reason (used to ask for an explicit "xóa vĩnh viễn").
    param([string]$Path)
    if ($script:khoRecycleOverride) { return '' }
    $bin = Test-KhoRecycleBin $Path
    return $(if ($bin.Ok) { '' } else { [string]$bin.Reason })
}

function Invoke-KhoRecycle {
    # Sends one file (or a whole folder) to the Windows Recycle Bin; throws when it cannot. On a volume WITHOUT a Recycle Bin it refuses unless the caller
    # passes -AllowPermanent after the owner explicitly confirmed a permanent delete: nothing is ever deleted permanently by surprise.
    param([string]$Path, [switch]$Folder, [switch]$AllowPermanent)
    if ($script:khoRecycleOverride) { & $script:khoRecycleOverride $Path ([bool]$Folder); return }
    $bin = Test-KhoRecycleBin $Path
    if (-not $bin.Ok) {
        if (-not $AllowPermanent) { throw "Ổ này không có Thùng rác ($($bin.Reason)); cần xác nhận xóa vĩnh viễn." }
        if ($Folder) { [System.IO.Directory]::Delete($Path, $true) } else { [System.IO.File]::Delete($Path) }
        return
    }
    Add-Type -AssemblyName Microsoft.VisualBasic
    $dialogs = [Microsoft.VisualBasic.FileIO.UIOption]::OnlyErrorDialogs
    $bin = [Microsoft.VisualBasic.FileIO.RecycleOption]::SendToRecycleBin
    if ($Folder) { [Microsoft.VisualBasic.FileIO.FileSystem]::DeleteDirectory($Path, $dialogs, $bin) }
    else { [Microsoft.VisualBasic.FileIO.FileSystem]::DeleteFile($Path, $dialogs, $bin) }
}

function Remove-ReelToRecycleBin {
    # S8: one video of a kho folder -> Recycle Bin: the -3 first, then -1/-2, then its finished / archived receipts (thumbnails are
    # regenerable and are deleted outright). When any recycle fails the metadata entry is KEPT and the rest is reported, so a retry
    # deletes what is left (a missing -3 with leftovers is still deletable). Returns @{ Success; Recycled; Remaining; Errors; MetaError }.
    param([Alias('Root')][string]$KhoRoot, [string]$Id, $Groups = $null, [switch]$AllowPermanent)
    $result = @{ Success = $false; Recycled = @(); Remaining = @(); Errors = @(); MetaError = '' }
    $recycled = New-Object System.Collections.Generic.List[string]; $errors = New-Object System.Collections.Generic.List[string]
    $remaining = New-Object System.Collections.Generic.List[string]
    $r = Get-CanonicalPath $KhoRoot
    if (-not (Test-KhoVideoKey $Id)) { $result.Errors = @('ID video không hợp lệ.'); return $result }
    $files = New-Object System.Collections.Generic.List[string]
    $files.Add((Get-KhoVideoPath $r $Id))
    foreach ($leaf in $(if (Test-KhoExternalKey $Id) { @() } else { @("$Id-1-video-goc.mp4", "$Id-2-am-thanh-tho.m4a") })) { $files.Add((Join-Path (Join-Path $r '.cache') $leaf)); $files.Add((Join-Path $r $leaf)) }
    if ($null -eq $Groups) { $Groups = Get-KhoReceiptGroups $r }
    $block = Get-KhoVideoBlock $r $Id $Groups
    if ($block) { $result.Errors = @($block); return $result }
    foreach ($req in @($Groups.Keys | Sort-Object)) {
        $g = $Groups[$req]
        if ($g.VideoId -cne $Id) { continue }
        foreach ($f in @($g.Files | Sort-Object { $_.Name })) { $files.Add([string]$f.Path) }
    }
    $finalPath = [string]$files[0]
    $stopped = $false
    foreach ($path in $files) {
        if (-not [System.IO.File]::Exists($path)) { continue }
        # The video itself could not be recycled (open in another program, ...): STOP. Its re-edit inputs and receipts stay exactly where they are.
        if ($stopped) { $remaining.Add($path); continue }
        try { Invoke-KhoRecycle $path -AllowPermanent:$AllowPermanent; $recycled.Add($path) }
        catch { $errors.Add("$([IO.Path]::GetFileName($path)): $($_.Exception.Message)"); $remaining.Add($path); Write-FileLog "WARN Thùng rác: không chuyển được '$path': $($_.Exception.Message)"; if ($path -ceq $finalPath) { $stopped = $true } }
    }
    $result.Recycled = $recycled.ToArray(); $result.Errors = $errors.ToArray(); $result.Remaining = $remaining.ToArray()
    if ($errors.Count) { return $result }
    foreach ($ext in @('jpg', 'json')) {
        $t = Join-Path (Join-Path (Join-Path $r '.cache') 'thumbs') ((Get-KhoThumbKey $Id) + ".$ext")
        try { if ([System.IO.File]::Exists($t)) { [System.IO.File]::Delete($t) } } catch { Write-FileLog "WARN Không xóa được ảnh thu nhỏ '$t': $($_.Exception.Message)" }
    }
    try {
        [void](Update-ReupMetadata -OutDir $r -Change {
            param($meta)
            if (-not $meta.PSObject.Properties[$Id]) { return $false }
            [void]$meta.PSObject.Properties.Remove($Id)
            return $true
        })
    } catch { $result.MetaError = $_.Exception.Message; Write-FileLog "WARN Đã xóa file Reel #$Id nhưng chưa xóa được lịch sử: $($_.Exception.Message)" }
    $result.Success = $true
    return $result
}

function Get-KhoPendingDeletesPath { return (Join-Path $script:root 'data\kho-pending-deletes.json') }

function Get-KhoPendingDeleteIds {
    # Ids whose deletion in this kho folder did not finish (their -3 may already be in the Recycle Bin). Throws when the file is unreadable.
    param([Alias('Root')][string]$KhoRoot)
    $path = Get-KhoPendingDeletesPath
    if (-not [System.IO.File]::Exists($path)) { return @() }
    $data = [System.IO.File]::ReadAllText($path, [System.Text.Encoding]::UTF8) | ConvertFrom-Json -ErrorAction Stop
    $key = (Get-CanonicalPath $KhoRoot).ToUpperInvariant()
    foreach ($p in $data.PSObject.Properties) { if ($p.Name.ToUpperInvariant() -ceq $key) { return @(@($p.Value) | ForEach-Object { [string]$_ } | Where-Object { $_ }) } }
    return @()
}

function Set-KhoPendingDeleteIds {
    # Replaces the pending ids of one kho folder (empty = none); other folders' entries are kept. Atomic (Write-KidSettings).
    param([Alias('Root')][string]$KhoRoot, [string[]]$Ids)
    $path = Get-KhoPendingDeletesPath
    $key = (Get-CanonicalPath $KhoRoot).ToUpperInvariant()
    $map = [ordered]@{}
    if ([System.IO.File]::Exists($path)) {
        $data = [System.IO.File]::ReadAllText($path, [System.Text.Encoding]::UTF8) | ConvertFrom-Json -ErrorAction Stop
        foreach ($p in $data.PSObject.Properties) { if ($p.Name.ToUpperInvariant() -cne $key) { $map[$p.Name] = @(@($p.Value) | ForEach-Object { [string]$_ }) } }
    }
    $ids = @(@($Ids) | Where-Object { $_ } | Select-Object -Unique)
    if ($ids.Count) { $map[$key] = $ids }
    elseif (-not $map.Count -and -not [System.IO.File]::Exists($path)) { return }
    Write-KidSettings -Path $path -Data $map
}

function Test-KhoFolderOnlyAppFiles {
    # True when the folder holds nothing but files the app made itself (status file, thumbnails, identity cache, empty receipt folder).
    param([Alias('Root')][string]$KhoRoot)
    foreach ($e in [System.IO.DirectoryInfo]::new($KhoRoot).GetFileSystemInfos()) {
        if ($e -is [System.IO.DirectoryInfo]) {
            if ($e.Name -cne '.cache') { return $false }
            foreach ($c in $e.GetFileSystemInfos()) {
                if ($c -is [System.IO.DirectoryInfo]) {
                    if ($c.Name -ceq 'thumbs') { continue }
                    if ($c.Name -ceq 'tiktok-posts' -and -not $c.GetFileSystemInfos().Count) { continue }
                    return $false
                }
                if ($c.Name -notmatch '^tiktok-identities\.json') { return $false }
            }
        } elseif ($e.Name -cne 'reup-status.json' -and $e.Name -notmatch '^\.reup-status-.*\.tmp$') { return $false }
    }
    return $true
}

function Get-KhoVideoFiles {
    param([Alias('Root')][string]$KhoRoot)
    if (-not [System.IO.Directory]::Exists($KhoRoot)) { return @() }
    return @([System.IO.DirectoryInfo]::new($KhoRoot).GetFiles() | Where-Object { Test-KhoVideoFileName $_.Name })
}

function Remove-KhoWithVideos {
    # S8: all videos of the kho -> Recycle Bin, then the kho leaves the registry (and the folder goes to the bin when this app made it
    # and only app files remain). Refused when the app is not quiet, a journal references the folder, any video has a TikTok job
    # (running or kept for retry), or it is the last kho. Nothing is unregistered unless every video was recycled.
    # Returns @{ Success; Deleted; Failed = @(@{Id; Errors}); FolderRecycled; Why }.
    param([string]$Id, [switch]$AllowPermanent)
    $result = @{ Success = $false; Deleted = 0; Failed = @(); FolderRecycled = $false; Why = '' }
    $reg = Get-KhoRegistry
    $lib = Get-KhoById $Id $reg
    if (-not $lib) { throw 'Không tìm thấy kho.' }
    if (@($reg.libraries).Count -le 1) { throw 'Không xóa được kho cuối cùng. Luôn phải có ít nhất một kho.' }
    if (-not $script:khoRegistryReady) { throw 'Không đọc được data\kho.json nên phiên này không lưu thay đổi kho. Đóng ứng dụng, kiểm tra file rồi mở lại.' }
    $busy = Test-KhoQuiet
    if ($busy) { $result.Why = "Đang bận ($busy). Thử lại sau."; return $result }
    $script:khoMoveRunning = $true
    try {
        if (-not (Suspend-TikTokSync)) { $result.Why = 'Đang đồng bộ TikTok. Thử lại sau.'; return $result }
        $recovered = Resume-KhoMoves
        $block = Get-KhoJournalBlock @([string]$lib.path)
        if ($block) { $result.Why = $block; return $result }
        $khoRoot = [string]$lib.path
        $videos = @(Get-KhoVideoFiles $khoRoot)
        $groups = Get-KhoReceiptGroups $khoRoot
        # Ids of an earlier, incomplete deletion are retried even when their -3 is already gone (companions/metadata may remain).
        try { $leftover = @(Get-KhoPendingDeleteIds $khoRoot) } catch { Write-FileLog "WARN kho-pending-deletes.json: $($_.Exception.Message)"; $result.Why = 'Không đọc được data\kho-pending-deletes.json (danh sách video xóa dở). Kiểm tra file rồi thử lại.'; return $result }
        $ids = @(@(@($videos | ForEach-Object { Get-KhoVideoKey $_.Name }) + $leftover) | Where-Object { $_ } | Select-Object -Unique)
        foreach ($vid in $ids) {
            $why = Get-KhoVideoBlock $khoRoot $vid $groups
            if ($why) { $result.Why = "$(if ($vid -match '^\d+$') { "Video #$vid" } else { Get-ReelLabel $vid }): $why"; return $result }
        }
        # A job without a readable video blocks the folder even when it has no video of its own.
        foreach ($req in $groups.Keys) { if ($groups[$req].Live -and -not $groups[$req].VideoId) { $result.Why = 'Thư mục có lệnh đăng không rõ thuộc video nào — xử lý trước.'; return $result } }
        Release-KhoPlayer @($videos | ForEach-Object { $_.FullName })
        $failed = New-Object System.Collections.Generic.List[object]; $deleted = 0
        try { Set-KhoPendingDeleteIds $khoRoot $ids } catch { Write-FileLog "WARN Không ghi được kho-pending-deletes.json: $($_.Exception.Message)"; $result.Why = 'Không ghi được data\kho-pending-deletes.json nên chưa xóa gì. Thử lại sau.'; return $result }
        foreach ($vid in $ids) {
            $r = Remove-ReelToRecycleBin -Root $khoRoot -Id $vid -Groups $groups -AllowPermanent:$AllowPermanent
            if ($r.Success) { $deleted++ } else { $failed.Add(@{ Id = $vid; Errors = @($r.Errors) }) }
        }
        $result.Deleted = $deleted; $result.Failed = $failed.ToArray()
        try { Set-KhoPendingDeleteIds $khoRoot @($failed | ForEach-Object { [string]$_.Id }) } catch { Write-FileLog "WARN Không cập nhật kho-pending-deletes.json: $($_.Exception.Message)"; if (-not $failed.Count) { $result.Why = 'Không cập nhật được data\kho-pending-deletes.json nên giữ kho lại. Thử lại sau.'; return $result } }
        if ($failed.Count) { $result.Why = "Chưa xóa hết: $($failed.Count) video còn lỗi. Kho được giữ lại; thử lại sau."; return $result }
        Invoke-KhoRegistryChange {
            param($r)
            $r.libraries = @($r.libraries | Where-Object { [string]$_.id -cne $Id })
            if ([string]$r.downloadTarget -ceq $Id) { $r.downloadTarget = [string]@($r.libraries)[0].id }
        }
        if ($lib.createdByApp -and [System.IO.Directory]::Exists($khoRoot)) {
            try {
                if (Test-KhoFolderOnlyAppFiles $khoRoot) { Invoke-KhoRecycle $khoRoot -Folder -AllowPermanent:$AllowPermanent; $result.FolderRecycled = $true }
            } catch { Write-FileLog "WARN Không chuyển được thư mục kho '$khoRoot' vào Thùng rác: $($_.Exception.Message)" }
        }
        $result.Success = $true
        return $result
    } finally {
        $script:khoMoveRunning = $false
        Resume-TikTokSync
    }
}

# ------------------------------------------------------------- hang doi: dong bang + 7 buoc ----
$script:stepNames = @('Kiểm tra công cụ', 'Kiểm tra thiết bị', 'Đọc ID và thời lượng', 'Chọn lồng tiếng Việt', 'Thu âm từ Android', 'Cắt và chuẩn hóa âm', 'Ghép và xuất MP4')
$script:queueStatusText = @{
    pending = 'Chờ'; running = 'Đang chạy'; ok = 'Đã lưu'; rejected = 'Bị loại'; skipped = 'Bỏ qua'
    failed = 'Lỗi'; unverified = 'Chưa xác nhận'; cancelled = 'Đã dừng'
}

function New-QueueRow {
    param([int]$Index, [string]$Url, [string]$Status = 'pending', [string]$Message = '', [int]$Step = 0, [string]$Video = '',
          [string]$SyncText = '', [bool]$SyncWarn = $false, [int]$QueueIdx = -1, $Id = $null, [string]$ActionOverride = '',
          [string]$Origin = '', [string]$RedoFile = '', [string]$Detail = '')
    if ($null -eq $Id) {
        $Id = ''
        try { if (Get-Command Get-FacebookVideoId -ErrorAction SilentlyContinue) { $Id = [string](Get-FacebookVideoId -Url $Url) } }
        catch { Write-FileLog "WARN Get-FacebookVideoId '$Url': $($_.Exception.Message)" }
    }
    $action = switch ($Status) { 'ok' { 'open' } 'failed' { 'retry' } 'unverified' { 'retry' } 'cancelled' { 'retry' } 'rejected' { 'unreject' } default { '' } }
    if ($ActionOverride) { $action = $ActionOverride }
    if ($action -eq 'unreject' -and -not $Id) { $action = '' }
    if ($action -eq 'open' -and -not $Video) { $action = '' }
    $actionText = switch ($action) { 'open' { 'Mở file' } 'retry' { 'Thử lại' } 'unreject' { 'Bỏ loại' } default { '' } }
    $statusText = $script:queueStatusText[$Status]
    if (-not $statusText) { $statusText = $Status }
    return [pscustomobject]@{
        Index = $Index; QueueIdx = $QueueIdx; Url = $Url; Id = [string]$Id
        IdText = $(if ($Id) { "Reel #$Id" } else { $Url })
        Status = $Status; StatusText = $statusText; Step = $Step
        StepText = $(if ($Step -gt 0) { "$Step/7" } else { '–' })
        Beads = (Get-QueueBeadStates -Step $Step -Status $Status)
        Message = $Message; Video = $Video; SyncText = $SyncText; SyncWarn = [bool]$SyncWarn
        ActionKind = $action; ActionText = $actionText; ActionOverride = $ActionOverride
        Origin = $Origin; RedoFile = $RedoFile; Detail = $Detail; HasDetail = [bool]$Detail
    }
}

# TikTok bridge: autotok owns accounts, uploads and durable scheduled jobs.
function Get-TikTokIntegration {
    # Same resolution as integrations\tiktok\start.ps1 (D1). Not configured: the app keeps its behaviour from before
    # the bridge (copy button, manual posted badge, no sync timer, no hashing).
    $launcher = Join-Path $script:root 'integrations\tiktok\start.ps1'
    $starter = [string]$env:KID_FBY_AUTOTOK_STARTER
    $config = Join-Path $script:root 'integrations\tiktok\local.json'
    if (-not $starter -and [IO.File]::Exists($config)) {
        try { $starter = [string]([IO.File]::ReadAllText($config) | ConvertFrom-Json -ErrorAction Stop).Starter }
        catch { Write-FileLog "WARN TikTok integration config '$config': $($_.Exception.Message)"; $starter = '' }
    }
    $enabled = [bool]($starter -and [IO.File]::Exists($starter) -and [IO.File]::Exists($launcher))
    return @{ Enabled = $enabled; Launcher = $launcher; Starter = $starter }
}

function Test-TikTokEnabled { return [bool]($script:tikTok -and $script:tikTok.Enabled) }

function Get-TikTokEndpoint {
    $value = if ($env:KID_FBY_TIKTOK_URL) { $env:KID_FBY_TIKTOK_URL.TrimEnd('/') } else { 'http://127.0.0.1:8765' }
    $uri = [Uri]$value
    if ($uri.Scheme -ne 'http' -or $uri.Host -ne '127.0.0.1' -or $uri.AbsolutePath -ne '/' -or $uri.Query -or $uri.UserInfo) { throw 'Bộ đăng TikTok phải chạy tại http://127.0.0.1 trên máy này.' }
    return $value
}

# ------------------------------------------------------------- bo dang TikTok: cai mot cham ----
# core\autotok-bundle.zip (delivered by the signed app update) carries integrations\autotok\kid-install.ps1.
# The installer runs in its own hidden process; the GUI only polls its progress file (no UI blocking).
function Get-AutotokPaths {
    $integrations = Join-Path $script:root 'integrations'
    return @{
        Integrations = $integrations; Bundle = (Join-Path $script:root 'core\autotok-bundle.zip')
        Current = (Join-Path $integrations 'autotok-current.json'); Launcher = (Join-Path $integrations 'autotok-start.ps1')
        UpgradeLock = (Join-Path $integrations 'autotok-upgrade.lock'); InstallLock = (Join-Path $integrations 'autotok-install.lock')
        LocalJson = (Join-Path $integrations 'tiktok\local.json')
    }
}

function Test-AutotokLockHeld {
    # kid-install.ps1 holds its lock files with FileShare.None + DeleteOnClose; a file nobody holds is a leftover.
    param([string]$Path)
    if (-not [IO.File]::Exists($Path)) { return $false }
    try { [IO.File]::Open($Path, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::ReadWrite).Dispose(); return $false }
    catch [IO.FileNotFoundException] { return $false }
    catch { return $true }
}

function Test-AutotokUpgradeActive {
    # True for the whole installer run (install lock) and while it switches releases (upgrade lock).
    $paths = Get-AutotokPaths
    return ([bool]$script:autotokInstall -or (Test-AutotokLockHeld $paths.InstallLock) -or (Test-AutotokLockHeld $paths.UpgradeLock))
}

function Find-AutotokChrome {
    # Same places as run_autotok_web.py find_chrome().
    foreach ($base in @($env:ProgramFiles, ${env:ProgramFiles(x86)}, $env:LOCALAPPDATA)) {
        if (-not $base) { continue }
        $exe = Join-Path $base 'Google\Chrome\Application\chrome.exe'
        if ([IO.File]::Exists($exe)) { return $exe }
    }
    return ''
}

function Get-AutotokInstallState {
    $paths = Get-AutotokPaths
    $state = @{ BundleSha = ''; Chrome = (Find-AutotokChrome); Installed = $false; Version = ''; Sha = ''; Foreign = ''
        EnvStarter = [string]$env:KID_FBY_AUTOTOK_STARTER; Installing = ([bool]$script:autotokInstall -or (Test-AutotokLockHeld $paths.InstallLock)) }
    if ([IO.File]::Exists($paths.Bundle)) {
        # Hash cached by size + time: the zip only changes with an app update.
        $fi = [IO.FileInfo]::new($paths.Bundle); $stamp = '{0}|{1}' -f $fi.Length, $fi.LastWriteTimeUtc.Ticks
        if (-not $script:autotokBundleCache -or $script:autotokBundleCache.Stamp -ne $stamp) {
            $script:autotokBundleCache = @{ Stamp = $stamp; Sha = (Get-FileHash -LiteralPath $paths.Bundle -Algorithm SHA256).Hash.ToLowerInvariant() }
        }
        $state.BundleSha = $script:autotokBundleCache.Sha
    }
    if ([IO.File]::Exists($paths.Current)) {
        try {
            $current = [IO.File]::ReadAllText($paths.Current, [Text.Encoding]::UTF8) | ConvertFrom-Json -ErrorAction Stop
            $release = [string]$current.release
            if ($release -match '^[0-9a-f]{12}-[0-9]{8}-[0-9]{6}$' -and [IO.File]::Exists((Join-Path $paths.Integrations "autotok-releases\$release\.kid-release-ok"))) {
                $state.Installed = $true; $state.Version = [string]$current.version; $state.Sha = [string]$current.sha
                $state.Verified = ($null -eq $current.PSObject.Properties['verified']) -or [bool]$current.verified
            }
        } catch { Write-FileLog "WARN autotok-current.json: $($_.Exception.Message)" }
    }
    if ([IO.File]::Exists($paths.LocalJson)) {
        try {
            $starter = [string]([IO.File]::ReadAllText($paths.LocalJson) | ConvertFrom-Json -ErrorAction Stop).Starter
            if ($starter -and [IO.Path]::GetFullPath($starter) -ine $paths.Launcher) { $state.Foreign = $starter }
        } catch { $state.Foreign = $paths.LocalJson }
    }
    return $state
}

function Update-AutotokSection {
    if (-not $ui.BtnAutotokInstall) { return }
    $s = Get-AutotokInstallState
    $short = $(if ($s.Sha) { ' (' + $s.Sha.Substring(0, [Math]::Min(8, $s.Sha.Length)) + ')' } else { '' })
    $color = 'Coral'; $label = 'Cài bộ đăng TikTok'; $enabled = $true
    $info = 'Đăng và hẹn giờ video lên TikTok ngay trong app. Cần Google Chrome và mạng; cài một lần, khoảng 5 phút.'
    if ($s.Installing) { $badge = 'Đang cài…'; $color = 'Butter'; $label = 'Đang cài…'; $enabled = $false }
    elseif ($s.EnvStarter) { $badge = 'Tự cấu hình'; $color = 'Sky'; $enabled = $false; $info = 'Đang dùng bộ đăng theo biến môi trường KID_FBY_AUTOTOK_STARTER. Bỏ biến này nếu muốn dùng bản cài một chạm.' }
    elseif (-not $s.BundleSha -and -not $s.Installed) { $badge = 'Chưa có gói cài'; $enabled = $false; $info = 'Bản Kid FB.Y này chưa kèm bộ đăng TikTok. Vào thẻ Cập nhật để nhận bản mới rồi quay lại đây.' }
    elseif ($s.Foreign) { $badge = 'Bản tự cài'; $color = 'Sky'; $label = 'Chuyển sang bản một chạm'; $enabled = [bool]$s.BundleSha; $info = "Đang dùng bộ đăng tự cài: $($s.Foreign). Có thể chuyển sang bản cài một chạm; tài khoản và dữ liệu giữ nguyên." }
    elseif (-not $s.Installed) { $badge = 'Chưa cài' }
    elseif (-not $s.Verified) { $badge = 'Cần kiểm tra'; $color = 'Butter'; $label = 'Kiểm tra / sửa'; $enabled = [bool]$s.BundleSha; $info = 'Lần cài trước bị ngắt giữa chừng. Bấm Kiểm tra / sửa: app chạy thử bản mới, lỗi thì quay lại bản cũ.' }
    elseif ($s.BundleSha -and $s.BundleSha -ne $s.Sha) { $badge = 'Có bản mới'; $color = 'Butter'; $label = 'Cập nhật bộ đăng'; $info = "Đang dùng bản $($s.Version)$short. Bản cập nhật của app có bộ đăng mới hơn; video đang gửi sẽ được đợi xong trước khi chuyển." }
    else { $badge = "Đã cài · $($s.Version)"; $color = 'Mint'; $label = 'Kiểm tra / sửa'; $enabled = [bool]$s.BundleSha; $info = "Bộ đăng TikTok đã sẵn sàng$short. Bấm Kiểm tra / sửa nếu đăng bài bị lỗi." }
    if (-not $s.Chrome -and -not $s.Installing) { $enabled = $false; $info += ' Cần cài Google Chrome trước.' }
    $ui.TxtAutotokBadge.Text = $badge
    $ui.BadgeAutotok.Background = Get-Brush ($color + 'Soft'); $ui.BadgeAutotok.BorderBrush = Get-Brush ($color + 'Line')
    $ui.BtnAutotokInstall.Content = $label; $ui.BtnAutotokInstall.IsEnabled = $enabled
    $ui.TxtAutotokInfo.Text = $info
    $ui.BtnAutotokChrome.Visibility = $(if ($s.Chrome) { 'Collapsed' } else { 'Visible' })
}

function Test-AutotokTransfersActive {
    # A background TikTok transfer still running would lose its backend mid-upload.
    try {
        foreach ($out in @(Get-KhoRoots)) {
            $dir = Join-Path $out '.cache\tiktok-posts'
            if (-not [IO.Directory]::Exists($dir)) { continue }
            foreach ($lock in [IO.DirectoryInfo]::new($dir).GetFiles('*.lock')) {
                if ($lock.Name -match '^([a-f0-9]{32})\.lock$' -and (Test-TikTokWorkerAlive $out $Matches[1])) { return $true }
            }
        }
    } catch { Write-FileLog "WARN autotok transfer check: $($_.Exception.Message)" }
    return $false
}

function Enable-TikTokIntegrationLive {
    # After a successful install: TikTok features on without restarting the app.
    $was = Test-TikTokEnabled
    $script:tikTok = Get-TikTokIntegration
    if (-not (Test-TikTokEnabled)) { return $false }
    if (-not $was) { Set-TikTokPostingUi }
    if (-not $script:tikTokSyncTimer) { Start-TikTokStatusSync }
    try { Update-Gallery } catch { Write-FileLog "WARN Update-Gallery after TikTok install: $($_.Exception.Message)" }
    return $true
}

function Start-AutotokInstall {
    if ($script:autotokInstall) { return }
    $s = Get-AutotokInstallState
    if ($s.Installing) { Show-Toast 'Đang có một lần cài bộ đăng TikTok chạy.' -Kind warning; return }
    if ($script:khoMoveRunning) { Show-Toast 'Đang chuyển kho. Thử lại sau.' -Kind warning; return }
    if ($s.EnvStarter) { Show-Toast 'Đang dùng KID_FBY_AUTOTOK_STARTER; bản cài một chạm không thay được cấu hình này.' -Kind warning; return }
    if (-not $s.BundleSha) { Show-Toast 'Bản này chưa kèm gói bộ đăng TikTok. Vào Cập nhật để nhận bản mới.' -Kind warning; return }
    if (-not $s.Chrome) { Show-Toast 'Cần cài Google Chrome trước (https://www.google.com/chrome/).' -Kind warning; Update-AutotokSection; return }
    if ((Test-TikTokEnabled) -and (Test-AutotokTransfersActive)) { Show-Toast 'Đang có video chuyển lên TikTok. Đợi xong rồi cài.' -Kind warning; return }
    $takeOver = $false
    if ($s.Foreign) {
        $takeOver = Show-ConfirmDialog -Title 'Chuyển sang bộ đăng cài một chạm?' -ConfirmText 'Chuyển' -Message (
            "Kid FB.Y đang dùng bộ đăng tự cài:`r`n$($s.Foreign)`r`n`r`n" +
            "Bản cài một chạm dùng chung thư mục dữ liệu, nên tài khoản TikTok và lịch sử giữ nguyên. " +
            "Bản tự cài sẽ được dừng sau khi các video đang gửi xong; nếu bản mới lỗi, app tự quay lại bản cũ.")
        if (-not $takeOver) { return }
    }
    $paths = Get-AutotokPaths
    $work = Join-Path ([IO.Path]::GetTempPath()) ('KidFBY-autotok-' + [Guid]::NewGuid().ToString('N'))
    try {
        # Run the installer from the bundle only when it matches the bundle's own file list.
        New-Item -ItemType Directory -Path $work -Force | Out-Null
        $script = Join-Path $work 'kid-install.ps1'
        Add-Type -AssemblyName System.IO.Compression.FileSystem
        $zip = [IO.Compression.ZipFile]::OpenRead($paths.Bundle)
        try {
            $manifestEntry = $zip.GetEntry('bundle.json'); $entry = $zip.GetEntry('autotok/kid-install.ps1')
            if (-not $manifestEntry -or -not $entry) { throw 'Gói cài thiếu bundle.json hoặc kid-install.ps1.' }
            $reader = New-Object IO.StreamReader($manifestEntry.Open(), [Text.Encoding]::UTF8)
            try { $manifest = $reader.ReadToEnd() | ConvertFrom-Json } finally { $reader.Dispose() }
            $expected = [string](@($manifest.files | Where-Object { [string]$_.path -ceq 'autotok/kid-install.ps1' }) | Select-Object -First 1).sha256
            [IO.Compression.ZipFileExtensions]::ExtractToFile($entry, $script, $false)
        } finally { $zip.Dispose() }
        if (-not $expected -or (Get-FileHash -LiteralPath $script -Algorithm SHA256).Hash -ne $expected.ToUpperInvariant()) { throw 'kid-install.ps1 không khớp gói cài.' }
        $progress = Join-Path $work 'progress.txt'
        $argList = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', ('"' + $script + '"'), '-Root', ('"' + $script:root.TrimEnd('\') + '"'),
            '-Bundle', ('"' + $paths.Bundle + '"'), '-ProgressFile', ('"' + $progress + '"'))
        if ($takeOver) { $argList += '-TakeOverStarter' }
        $process = Start-Process -FilePath 'powershell.exe' -ArgumentList $argList -WindowStyle Hidden -PassThru
        $null = $process.Handle
    } catch {
        try { Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction Stop } catch { Write-FileLog "WARN autotok temp cleanup: $($_.Exception.Message)" }
        Show-Toast ('Không bắt đầu cài được bộ đăng TikTok: ' + $_.Exception.Message) -Kind error
        return
    }
    Write-FileLog "AUTOTOK install started pid=$($process.Id) takeover=$takeOver"
    $script:autotokInstall = @{ Process = $process; Progress = $progress; Work = $work; Timer = (New-Object Windows.Threading.DispatcherTimer) }
    $ui.TxtAutotokProgress.Text = 'Đang bắt đầu…'; $ui.TxtAutotokProgress.Visibility = 'Visible'
    $ui.BarAutotok.Value = 0; $ui.BarAutotok.Visibility = 'Visible'
    Update-AutotokSection
    $script:autotokInstall.Timer.Interval = [TimeSpan]::FromMilliseconds(500)
    $script:autotokInstall.Timer.Add_Tick({
        try { Invoke-AutotokInstallTick } catch { Write-FileLog "WARN autotok install tick: $($_.Exception.Message)" }
    })
    $script:autotokInstall.Timer.Start()
}

function Read-AutotokProgress {
    # Last step and the result line from the installer's progress file (@@AUTOTOK_STEP / @@AUTOTOK_RESULT).
    param([string]$Path)
    $out = @{ Pct = -1; Message = ''; Result = '' }
    if (-not [IO.File]::Exists($Path)) { return $out }
    $fs = [IO.File]::Open($Path, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::ReadWrite -bor [IO.FileShare]::Delete)
    try { $text = (New-Object IO.StreamReader($fs, [Text.Encoding]::UTF8)).ReadToEnd() } finally { $fs.Dispose() }
    foreach ($line in ($text -split "`n")) {
        if ($line -match '^@@AUTOTOK_STEP (\S+) (\d+) (.*)$') { $out.Pct = [int]$Matches[2]; $out.Message = $Matches[3].Trim() }
        elseif ($line -match '^@@AUTOTOK_RESULT (ok|failed) (\S+) ?(.*)$') { $out.Result = $Matches[1]; $out.Reason = $Matches[2]; $out.Message = $Matches[3].Trim() }
    }
    return $out
}

function Invoke-AutotokInstallTick {
    $job = $script:autotokInstall
    if (-not $job) { return }
    $p = Read-AutotokProgress $job.Progress
    if ($p.Pct -ge 0) { $ui.BarAutotok.Value = $p.Pct }
    if ($p.Message) { $ui.TxtAutotokProgress.Text = $p.Message }
    if (-not $job.Process.HasExited) { return }
    $p = Read-AutotokProgress $job.Progress
    $job.Timer.Stop(); $script:autotokInstall = $null
    try { Remove-Item -LiteralPath $job.Work -Recurse -Force -ErrorAction Stop } catch { Write-FileLog "WARN autotok temp cleanup: $($_.Exception.Message)" }
    Write-FileLog "AUTOTOK install finished exit=$($job.Process.ExitCode) result=$($p.Result) reason=$($p.Reason)"
    $ui.BarAutotok.Visibility = 'Collapsed'
    if ($p.Result -eq 'ok') {
        $ui.TxtAutotokProgress.Text = $p.Message
        Start-ChromeConnect
        if (Enable-TikTokIntegrationLive) { Show-Toast ($p.Message + ' Nút Đăng video đã sẵn sàng.') -Kind success }
        else { Show-Toast ($p.Message + ' Nhưng app chưa nhận cấu hình TikTok; mở lại app.') -Kind warning }
    } else {
        $message = $(if ($p.Result -and $p.Message) { $p.Message }
            elseif ($p.Message) { "Trình cài dừng bất thường ở bước: $($p.Message) (mã $($job.Process.ExitCode)). Xem integrations\autotok-install.log." }
            else { "Trình cài dừng bất thường (mã $($job.Process.ExitCode)). Xem integrations\autotok-install.log." })
        $ui.TxtAutotokProgress.Text = $message
        Show-Toast ('Chưa cài được bộ đăng TikTok: ' + $message) -Kind error
    }
    Update-AutotokSection
}

# ------------------------------------------------------------- Ket noi Chrome (Cai dat): ghep ma, danh sach Chrome, dang qua Cookie/Chrome ----
# Every backend call goes through the 'ext' background action (never on the UI thread); one operation at a time, in order.
$script:chromeCookieChoice = @()   # ids of accounts the owner put back on Cookie: never switched to Chrome automatically (settings.json)
$script:chromeUi = @{ Task = $null; Op = $null; Ops = (New-Object System.Collections.ArrayList); Timer = $null; LastPoll = [DateTime]::MinValue
    Clients = @(); Accounts = @(); ChromeOk = $false; Tried = @{}; ReloadToasted = $false; PairExpires = ''; PairClients = 0; Building = $false }

function Select-ChromeClientForAccount {
    # Which Chrome an account is bound to when the owner picks "Chrome": the one reporting the same TikTok username;
    # with no such name and exactly one healthy Chrome, that one but flagged Mismatch (the owner must confirm).
    param($Account, $Clients)
    $ok = @(@($Clients) | Where-Object { $_ -and [string]$_.status -eq 'ok' -and [bool]$_.has_identity })
    if (-not $ok.Count) { return @{ Error = 'Chưa có Chrome nào đang kết nối và đã đăng nhập TikTok. Mở Chrome có tiện ích trước.' } }
    $name = ([string]$Account.username).Trim().TrimStart('@')
    $same = @($ok | Where-Object { ([string]$_.tiktok_username).Trim().TrimStart('@') -ieq $name })
    if ($same.Count -eq 1) { return @{ Client = $same[0]; Mismatch = $false } }
    if ($same.Count -gt 1) { return @{ Error = 'Có nhiều Chrome cùng tài khoản này — gỡ bớt một ở danh sách trên.' } }
    if ($ok.Count -eq 1) { return @{ Client = $ok[0]; Mismatch = $true } }
    return @{ Error = 'Không có Chrome nào đăng nhập TikTok tên @' + $name + '. Mở đúng Chrome rồi thử lại.' }
}

function Get-ChromeGuidePath { return (Join-Path $script:root 'integrations\autotok-extension\HUONG-DAN-CAI-TIEN-ICH.md') }
function Get-ChromeExtensionDir { return (Join-Path $script:root 'integrations\autotok-extension') }

function Test-ChromeSectionVisible {
    return [bool]($ui.ViewSettings -and $ui.ViewTools -and $ui.ViewSettings.IsVisible -and $ui.ViewTools.IsVisible)
}

function Set-ChromeStatusText {
    param([string]$Text)
    if (-not $ui.TxtChromeStatus) { return }
    $ui.TxtChromeStatus.Text = $Text
    $ui.TxtChromeStatus.Visibility = $(if ($Text) { 'Visible' } else { 'Collapsed' })
}

function Add-ChromeOp {
    param([string]$Kind, [hashtable]$Payload, $Ctx = $null)
    if ($Kind -eq 'refresh') {
        # One refresh is enough: a queued or running one will see the newest state.
        if (($script:chromeUi.Op -and $script:chromeUi.Op.Kind -eq 'refresh') -or @($script:chromeUi.Ops | Where-Object { $_.Kind -eq 'refresh' }).Count) { return }
    }
    [void]$script:chromeUi.Ops.Add(@{ Kind = $Kind; Payload = $Payload; Ctx = $Ctx })
    Start-ChromeTimer
}

function Start-ChromeTimer {
    if ($script:chromeUi.Timer) { return }
    $t = New-Object Windows.Threading.DispatcherTimer
    $t.Interval = [TimeSpan]::FromSeconds(1)
    $t.Add_Tick({ try { Invoke-ChromeTick } catch { Write-FileLog "WARN Chrome tick: $($_.Exception.Message)" } })
    $script:chromeUi.Timer = $t
    $t.Start()
}

function Start-ChromeConnect {
    # App start / after an install: one quiet look at the connected Chromes (reload reminder, automatic switch to Chrome).
    Add-ChromeOp 'refresh' @{ op = 'refresh' } @{ Silent = $true }
}

function Update-ChromeCountdown {
    $s = $script:chromeUi
    if (-not $s.PairExpires -or -not $ui.PanelChromeCode) { return }
    $left = Get-ChromePairCodeRemaining $s.PairExpires
    if ($left -le 0) {
        $s.PairExpires = ''
        $ui.PanelChromeCode.Visibility = 'Collapsed'
        Set-ChromeStatusText 'Mã đã hết hạn. Bấm Tạo mã ghép nối để lấy mã mới.'
        return
    }
    $ui.TxtChromeCountdown.Text = 'Còn {0}:{1:00}' -f [int][Math]::Floor($left / 60), ($left % 60)
}

function Invoke-ChromeTick {
    $s = $script:chromeUi
    Update-ChromeCountdown
    if ($s.Task) {
        if (-not $s.Task.Async.IsCompleted) { return }
        Complete-ChromeOp
    }
    if ($s.Task) { return }
    if (-not $s.Ops.Count) {
        # Poll only while the section is on screen; faster while a pairing code is waiting to be used.
        $every = $(if ($s.PairExpires) { 2 } else { 5 })
        if ((Test-ChromeSectionVisible) -and ([DateTime]::UtcNow - $s.LastPoll).TotalSeconds -ge $every) { Add-ChromeOp 'refresh' @{ op = 'refresh' } @{ Silent = $false } }
    }
    if (-not $s.Ops.Count) { return }
    $op = $s.Ops[0]; $s.Ops.RemoveAt(0)
    $s.Op = $op
    if ($op.Kind -eq 'refresh') { $s.LastPoll = [DateTime]::UtcNow }
    try { $s.Task = Start-TikTokTask -Action 'ext' -Payload $op.Payload }
    catch { $s.Op = $null; Write-FileLog "WARN Chrome start $($op.Kind): $($_.Exception.Message)"; Set-ChromeStatusText ('Không gọi được bộ đăng: ' + (Get-FriendlyError $_.Exception.Message)) }
}

function Complete-ChromeOp {
    $s = $script:chromeUi
    $task = $s.Task; $op = $s.Op; $s.Task = $null; $s.Op = $null
    if ($ui.BtnChromePair) { $ui.BtnChromePair.IsEnabled = $true }
    $silent = [bool]($op.Ctx -and $op.Ctx.Silent)
    try { $r = Complete-TikTokTask $task }
    catch {
        $text = Get-FriendlyError $_.Exception.Message
        Write-FileLog "WARN Chrome $($op.Kind): $($_.Exception.Message)"
        if (-not $silent) { Set-ChromeStatusText $text }
        return
    }
    if (-not $r.ok) {
        $text = Get-ChromeApiErrorText ([int]$r.status) ([string]$r.text)
        Write-FileLog "WARN Chrome $($op.Kind) HTTP $($r.status): $($r.text)"
        if ($op.Ctx -and $op.Ctx.Auto) { return }   # automatic switch refused by the backend rules: stay on cookies, say nothing
        if (-not $silent) { Set-ChromeStatusText $text }
        if ($op.Kind -in @('set-publisher', 'from-chrome', 'remove-client')) { Show-Toast $text -Kind warning; Add-ChromeOp 'refresh' @{ op = 'refresh' } @{ Silent = $false } }
        return
    }
    switch ($op.Kind) {
        'refresh' {
            $clientsRaw = $r.clients | ConvertFrom-Json; $accountsRaw = $r.accounts | ConvertFrom-Json
            $s.Clients = @($clientsRaw | Where-Object { $_ }); $s.Accounts = @($accountsRaw | Where-Object { $_ }); $s.ChromeOk = [bool]$r.chrome
            if (-not $silent) { Set-ChromeStatusText '' }
            if ($s.PairExpires -and $s.Clients.Count -gt $s.PairClients) {
                $s.PairExpires = ''; $ui.PanelChromeCode.Visibility = 'Collapsed'
                Set-ChromeStatusText 'Đã ghép nối xong. Chrome sẽ hiện ở danh sách dưới đây.'
            }
            Update-ChromeLists
            Invoke-ChromeReloadReminder
            Invoke-ChromeAutoSwitch
        }
        'pair-code' {
            $j = $r.text | ConvertFrom-Json
            $s.PairExpires = [string]$j.expires_at; $s.PairClients = $s.Clients.Count
            $digits = [string]$j.code
            $ui.TxtChromeCode.Text = $(if ($digits.Length -eq 6) { $digits.Substring(0, 3) + ' ' + $digits.Substring(3) } else { $digits })
            $ui.PanelChromeCode.Visibility = 'Visible'
            Set-ChromeStatusText 'Nhập 6 số này vào tiện ích (bấm biểu tượng tiện ích trên Chrome). Mã dùng một lần.'
            Update-ChromeCountdown
        }
        'remove-client' { Show-Toast 'Đã gỡ Chrome này.' -Kind success; Add-ChromeOp 'refresh' @{ op = 'refresh' } @{ Silent = $false } }
        'from-chrome' {
            $a = $r.text | ConvertFrom-Json
            Show-Toast ('Đã thêm tài khoản @' + [string]$a.username + ' (đăng qua Chrome).') -Kind success
            Add-ChromeOp 'refresh' @{ op = 'refresh' } @{ Silent = $false }
        }
        'set-publisher' {
            $id = [string]$op.Ctx.AccountId
            if ($op.Ctx.Publisher -eq 'cookies') { if ($script:chromeCookieChoice -notcontains $id) { $script:chromeCookieChoice = @($script:chromeCookieChoice) + $id } }
            else { $script:chromeCookieChoice = @($script:chromeCookieChoice | Where-Object { $_ -ne $id }) }
            Request-SaveSettings
            if ($op.Ctx.Auto) { Show-Toast ('Tài khoản ' + [string]$op.Ctx.Username + ' sẽ đăng qua Chrome') -Kind success }
            else { Show-Toast ('Tài khoản ' + [string]$op.Ctx.Username + $(if ($op.Ctx.Publisher -eq 'chrome') { ' đăng qua Chrome.' } else { ' đăng qua Cookie.' })) -Kind success }
            Add-ChromeOp 'refresh' @{ op = 'refresh' } @{ Silent = $false }
        }
    }
}

function Invoke-ChromeReloadReminder {
    $s = $script:chromeUi
    if ($s.ReloadToasted -or -not (Test-ChromeNeedReload $s.Clients)) { return }
    $s.ReloadToasted = $true
    Show-Toast 'Có bản tiện ích mới — vào chrome://extensions bấm ⟳' -Kind warning
}

function Invoke-ChromeAutoSwitch {
    # Chrome is the default publisher: switch matching cookie accounts once. Needs the saved choices to be known.
    $s = $script:chromeUi
    if (-not $script:settingsReady -or -not $s.ChromeOk) { return }
    foreach ($item in @(Get-ChromeAutoSwitchPlan -Accounts $s.Accounts -Clients $s.Clients -CookieChoice $script:chromeCookieChoice -Tried $s.Tried)) {
        $id = [string]$item.Account.id
        $s.Tried[$id] = $true
        Add-ChromeOp 'set-publisher' @{ op = 'set-publisher'; account_id = [int]$item.Account.id; publisher = 'chrome'; client_id = [int]$item.Client.id; confirm = $false } `
            @{ Auto = $true; AccountId = $id; Username = '@' + [string]$item.Account.username; Publisher = 'chrome' }
    }
}

function New-ChromeText {
    param([string]$Text, [bool]$Muted = $false, [bool]$Bold = $false)
    $t = New-Object Windows.Controls.TextBlock
    $t.Text = $Text; $t.TextWrapping = 'Wrap'
    if ($Muted) { $t.Style = $win.FindResource('TextMutedStyle') }
    if ($Bold) { $t.FontWeight = [Windows.FontWeights]::ExtraBold }
    return $t
}

function New-ChromeButton {
    param([string]$Text, [string]$StyleName = 'BtnGhost')
    $b = New-Object Windows.Controls.Button
    $b.Content = $Text; $b.Style = $win.FindResource($StyleName); $b.MinHeight = 44; $b.Margin = [Windows.Thickness]::new(8, 4, 0, 4)
    [Windows.Automation.AutomationProperties]::SetName($b, $Text)
    return $b
}

function Update-ChromeLists {
    if (-not $ui.ListChromeClients) { return }
    $s = $script:chromeUi
    $s.Building = $true
    try {
        $ui.ListChromeClients.Children.Clear(); $ui.ListChromeAccounts.Children.Clear()
        if (-not $s.ChromeOk) {
            [void]$ui.ListChromeClients.Children.Add((New-ChromeText 'Bộ đăng TikTok hiện tại chưa hỗ trợ Chrome. Bấm Cập nhật / Kiểm tra bộ đăng ở thẻ trên.' $true))
            return
        }
        if (-not $s.Clients.Count) { [void]$ui.ListChromeClients.Children.Add((New-ChromeText 'Chưa có Chrome nào. Cài tiện ích rồi bấm Tạo mã ghép nối.' $true)) }
        foreach ($cl in $s.Clients) {
            $row = New-Object Windows.Controls.DockPanel; $row.Margin = [Windows.Thickness]::new(0, 4, 0, 4)
            $buttons = New-Object Windows.Controls.WrapPanel; [Windows.Controls.DockPanel]::SetDock($buttons, 'Right'); $buttons.VerticalAlignment = 'Center'
            $name = $(if ([string]$cl.tiktok_username) { '@' + [string]$cl.tiktok_username } else { '(chưa đăng nhập TikTok)' })
            $hasAccount = [bool](@($s.Accounts | Where-Object { [string]$cl.tiktok_username -and ([string]$_.username).TrimStart('@') -ieq ([string]$cl.tiktok_username).TrimStart('@') }).Count)
            if ([bool]$cl.has_identity -and [string]$cl.status -eq 'ok' -and -not $hasAccount) {
                $add = New-ChromeButton 'Thêm tài khoản từ Chrome' 'BtnPrimary'
                $add.Tag = [int]$cl.id
                $add.Add_Click({ param($sender, $e) $sender.IsEnabled = $false; Add-ChromeOp 'from-chrome' @{ op = 'from-chrome'; client_id = [int]$sender.Tag } })
                [void]$buttons.Children.Add($add)
            }
            $del = New-ChromeButton 'Gỡ'
            $del.Tag = @{ Id = [int]$cl.id; Name = $name }
            $del.Add_Click({ param($sender, $e)
                if (Show-ConfirmDialog -Title 'Gỡ Chrome này?' -ConfirmText 'Gỡ' -Danger -Message ("Gỡ $($sender.Tag.Name) khỏi danh sách? Chrome đó sẽ không đăng được nữa cho tới khi ghép nối lại.")) {
                    Add-ChromeOp 'remove-client' @{ op = 'remove-client'; client_id = [int]$sender.Tag.Id }
                }
            })
            [void]$buttons.Children.Add($del)
            [void]$row.Children.Add($buttons)
            $info = New-Object Windows.Controls.StackPanel
            [void]$info.Children.Add((New-ChromeText ($name + $(if ([string]$cl.label) { ' · ' + [string]$cl.label } else { '' })) $false $true))
            [void]$info.Children.Add((New-ChromeText ((Get-ChromeClientStatusText $cl) + ' · thấy ' + (Format-ChromeLastSeen ([string]$cl.last_seen_at)) + $(if ([string]$cl.ext_version) { ' · tiện ích ' + [string]$cl.ext_version } else { '' })) $true))
            if ([bool]$cl.need_reload) { [void]$info.Children.Add((New-ChromeText 'Có bản tiện ích mới — vào chrome://extensions bấm ⟳' $false $true)) }
            [void]$row.Children.Add($info)
            [void]$ui.ListChromeClients.Children.Add($row)
        }
        $withPublisher = @($s.Accounts | Where-Object { $_.PSObject.Properties['publisher'] })
        if (-not $withPublisher.Count) { [void]$ui.ListChromeAccounts.Children.Add((New-ChromeText 'Chưa có tài khoản TikTok. Thêm từ Chrome ở trên, hoặc đăng nhập cookie ở Tài khoản / Lịch đăng.' $true)) }
        foreach ($a in $withPublisher) {
            $row = New-Object Windows.Controls.DockPanel; $row.Margin = [Windows.Thickness]::new(0, 4, 0, 4)
            $combo = New-Object Windows.Controls.ComboBox
            [void]$combo.Items.Add('Chrome'); [void]$combo.Items.Add('Cookie')   # Chrome first: the default publisher
            $combo.SelectedIndex = $(if ([string]$a.publisher -eq 'cookies') { 1 } else { 0 })
            $combo.MinWidth = 120; $combo.MinHeight = 44; $combo.VerticalAlignment = 'Center'; $combo.Tag = $a
            [Windows.Automation.AutomationProperties]::SetName($combo, 'Đăng qua cho @' + [string]$a.username)
            [Windows.Controls.DockPanel]::SetDock($combo, 'Right')
            $combo.Add_SelectionChanged({ param($sender, $e) Invoke-ChromePublisherChoice $sender })
            [void]$row.Children.Add($combo)
            $info = New-Object Windows.Controls.StackPanel
            [void]$info.Children.Add((New-ChromeText ('@' + [string]$a.username) $false $true))
            $note = Get-TikTokAccountNote $a
            $hint = ''
            if ([string]$a.publisher -eq 'cookies' -and -not (Select-ChromeClientForAccount $a $s.Clients).Client) { $hint = 'Mở Chrome có tiện ích để đăng qua Chrome' }
            [void]$info.Children.Add((New-ChromeText $(if ($note) { 'Chưa đăng được: ' + $note } else { 'Sẵn sàng' }) $true))
            if ($hint) { [void]$info.Children.Add((New-ChromeText $hint $true)) }
            [void]$row.Children.Add($info)
            [void]$ui.ListChromeAccounts.Children.Add($row)
        }
    } finally { $s.Building = $false }
}

function Invoke-ChromePublisherChoice {
    param($Combo)
    $s = $script:chromeUi
    if ($s.Building -or $Combo.SelectedIndex -lt 0) { return }
    $a = $Combo.Tag
    $want = $(if ($Combo.SelectedIndex -eq 0) { 'chrome' } else { 'cookies' })
    if ($want -eq [string]$a.publisher) { return }
    if ($want -eq 'cookies') {
        Add-ChromeOp 'set-publisher' @{ op = 'set-publisher'; account_id = [int]$a.id; publisher = 'cookies' } @{ AccountId = [string]$a.id; Username = '@' + [string]$a.username; Publisher = 'cookies' }
        return
    }
    $pick = Select-ChromeClientForAccount $a $s.Clients
    if (-not $pick.Client) { Show-Toast $pick.Error -Kind warning; Update-ChromeLists; return }
    if ($pick.Mismatch -and -not (Show-ConfirmDialog -Title 'Chrome khác tên tài khoản?' -ConfirmText 'Đúng, cùng tài khoản' -Message (
            "Chrome đang đăng nhập TikTok @$($pick.Client.tiktok_username), khác tên tài khoản @$($a.username).`r`nChỉ đồng ý nếu đúng là cùng một tài khoản."))) { Update-ChromeLists; return }
    Add-ChromeOp 'set-publisher' @{ op = 'set-publisher'; account_id = [int]$a.id; publisher = 'chrome'; client_id = [int]$pick.Client.id; confirm = [bool]$pick.Mismatch } `
        @{ AccountId = [string]$a.id; Username = '@' + [string]$a.username; Publisher = 'chrome' }
}

function Open-ChromeGuide {
    $guide = Get-ChromeGuidePath
    if ([IO.File]::Exists($guide)) { Start-Process -FilePath $guide; return }
    Show-Toast 'Chưa có file hướng dẫn. Cài hoặc cập nhật bộ đăng TikTok trước (Cài đặt → Bộ đăng TikTok).' -Kind warning
}

function Open-ChromeExtensionFolder {
    $dir = Get-ChromeExtensionDir
    if ([IO.Directory]::Exists($dir)) { Start-Process -FilePath 'explorer.exe' -ArgumentList ('"' + $dir + '"'); return }
    Show-Toast 'Chưa có thư mục tiện ích. Cài hoặc cập nhật bộ đăng TikTok trước (Cài đặt → Bộ đăng TikTok).' -Kind warning
}

$script:tikTokWorker = {
    param($Action, $BaseUrl, $FilePath, $PayloadJson, $RequestId, $Starter, [Threading.CancellationToken]$CancelToken = [Threading.CancellationToken]::None)
    $ErrorActionPreference='Stop'
    Add-Type -AssemblyName System.Net.Http
    $handler=[Net.Http.HttpClientHandler]::new();$handler.AllowAutoRedirect=$false;$handler.UseProxy=$false
    $client=[Net.Http.HttpClient]::new($handler)
    $client.Timeout=$(if($Action -eq 'create'){[TimeSpan]::FromMinutes(10)}else{[TimeSpan]::FromSeconds(60)})
    [void]$client.DefaultRequestHeaders.Add('X-Requested-With','autotok')
    # One connection per request: hashing can keep the client idle longer than the server keep-alive timeout, and a
    # reused connection the server already closed fails the next request.
    $client.DefaultRequestHeaders.ConnectionClose=$true
    $finalStates=@('succeeded','failed','cancelled','preparation_failed','missing')
    function Read-Response($Response){
        try{
            $text=$Response.Content.ReadAsStringAsync().GetAwaiter().GetResult()
            if(-not $Response.IsSuccessStatusCode){throw ('Bộ đăng trả về HTTP '+[int]$Response.StatusCode+'. Xem Lịch sử / Lịch đăng để kiểm tra.')}
            return $text
        }finally{$Response.Dispose()}
    }
    function Get-Json([string]$Url,[int]$TimeoutSeconds=0){
        $linked=[Threading.CancellationTokenSource]::CreateLinkedTokenSource($CancelToken)
        try{
            if($TimeoutSeconds -gt 0){$linked.CancelAfter([TimeSpan]::FromSeconds($TimeoutSeconds))}
            return ((Read-Response ($client.GetAsync($Url,$linked.Token).GetAwaiter().GetResult())) | ConvertFrom-Json)
        }finally{$linked.Dispose()}
    }
    function Test-Health{
        try{return (Get-Json ($BaseUrl+'/health') 5)}catch{if($CancelToken.IsCancellationRequested){throw};return $null}
    }
    function Get-FileSha256([string]$Path){
        # Chunked so that closing the dialog/app can stop hashing a large file between chunks (G8).
        $hash=[Security.Cryptography.SHA256]::Create();$stream=[IO.File]::Open($Path,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::Read)
        try{
            $buffer=New-Object byte[] (4MB)
            while(($read=$stream.Read($buffer,0,$buffer.Length)) -gt 0){
                $CancelToken.ThrowIfCancellationRequested()
                [void]$hash.TransformBlock($buffer,0,$read,$null,0)
            }
            [void]$hash.TransformFinalBlock($buffer,0,0)
            return [BitConverter]::ToString($hash.Hash).Replace('-','').ToLowerInvariant()
        }finally{$stream.Dispose();$hash.Dispose()}
    }
    function Read-IdentityCache([string]$File){
        $cache=@{}
        try{
            if([IO.File]::Exists($File)){
                $old=[IO.File]::ReadAllText($File) | ConvertFrom-Json
                foreach($p in $old.PSObject.Properties){$cache[$p.Name]=@{Stamp=[string]$p.Value.Stamp;Hash=[string]$p.Value.Hash}}
            }
        }catch{ <# unreadable cache: files are hashed again, nothing is lost #> }
        return $cache
    }
    function Save-IdentityCache([string]$File,[hashtable]$Cache){
        $temp=$File+'.'+[Guid]::NewGuid().ToString('N')+'.tmp'
        try{
            [void][IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($File))
            [IO.File]::WriteAllText($temp,(ConvertTo-Json -InputObject $Cache -Depth 4 -Compress),[Text.UTF8Encoding]::new($false))
            if([IO.File]::Exists($File)){[IO.File]::Replace($temp,$File,[Management.Automation.Language.NullString]::Value)}else{[IO.File]::Move($temp,$File)}
            return ''
        }catch{return $_.Exception.Message}finally{if([IO.File]::Exists($temp)){[IO.File]::Delete($temp)}}
    }
    function Resolve-Identities($Files,[hashtable]$Cache,[bool]$Prune){
        $changed=$false;$items=New-Object Collections.Generic.List[object];$seen=@{}
        foreach($file in @($Files)){
            $CancelToken.ThrowIfCancellationRequested()
            $path=[string]$file.path;$sha='';$seen[$path]=$true
            try{
                $info=[IO.FileInfo]::new($path)
                if($info.Exists){
                    $stamp=$info.Length.ToString()+'|'+$info.LastWriteTimeUtc.Ticks
                    $hit=$Cache[$path]
                    if($hit -and $hit.Stamp -eq $stamp){$sha=[string]$hit.Hash}
                    else{
                        $sha=Get-FileSha256 $path
                        $after=[IO.FileInfo]::new($path)
                        if($stamp -ne ($after.Length.ToString()+'|'+$after.LastWriteTimeUtc.Ticks)){$sha=''}else{$Cache[$path]=@{Stamp=$stamp;Hash=$sha};$changed=$true}
                    }
                }
            }catch{if($CancelToken.IsCancellationRequested){throw};$sha=''}
            $items.Add(@{reel_id=[string]$file.id;sha256=$sha})
        }
        if($Prune){foreach($key in @($Cache.Keys)){if(-not $seen.ContainsKey($key)){$Cache.Remove($key);$changed=$true}}}
        return @{Items=$items.ToArray();Changed=$changed}
    }
    function Invoke-Lookup($Identities,$Receipts){
        # At most 500 videos per request (R8). A failed chunk leaves its videos out, so their stored state is kept.
        $byVideo=@{}
        foreach($r in @($Receipts)){$vid=[string]$r.VideoId;if(-not $byVideo.ContainsKey($vid)){$byVideo[$vid]=New-Object Collections.Generic.List[string]};$byVideo[$vid].Add([string]$r.RequestId)}
        $rows=@{};$failed=0;$message='';$wireToKey=@{}   # D12: video ngoài gửi lên backend bằng mã ngắn f_<sha1> (reel_id tối đa 128 ký tự); trả lời đổi ngược về khóa
        $list=@($Identities)
        for($i=0;$i -lt $list.Count;$i+=500){
            $CancelToken.ThrowIfCancellationRequested()
            $chunk=New-Object Collections.Generic.List[object]
            for($j=$i;$j -lt [Math]::Min($i+500,$list.Count);$j++){
                $v=$list[$j];$ids=if($byVideo.ContainsKey([string]$v.reel_id)){$byVideo[[string]$v.reel_id].ToArray()}else{@()}
                $wire=Get-KhoThumbKey ([string]$v.reel_id);$wireToKey[$wire]=[string]$v.reel_id;$chunk.Add(@{reel_id=$wire;sha256=[string]$v.sha256;request_ids=@($ids)})
            }
            $content=[Net.Http.StringContent]::new((ConvertTo-Json -InputObject @{videos=$chunk.ToArray()} -Depth 6 -Compress),[Text.Encoding]::UTF8,'application/json')
            try{
                $parsed=(Read-Response ($client.PostAsync($BaseUrl+'/api/history/lookup',$content,$CancelToken).GetAwaiter().GetResult())) | ConvertFrom-Json
                foreach($row in $parsed){if($row){$rk=[string]$row.reel_id;if($wireToKey.ContainsKey($rk)){$rk=$wireToKey[$rk]};$rows[$rk]=@($row.entries | Where-Object {$null -ne $_})}}
            }catch{if($CancelToken.IsCancellationRequested){throw};$failed++;$message=$_.Exception.Message}
            finally{$content.Dispose()}
        }
        return @{Rows=$rows;Failed=$failed;Message=$message}
    }
    function Invoke-Probes([object[]]$Receipts,[string]$Cursor){
        # Receipts the lookup did not report: ask for the exact request_id. 404 = the backend never got it (R2).
        # At most 20 GETs per tick, round-robin by RequestId from $Cursor so receipt #21+ is reached on later ticks.
        $found=@{};$missing=@{};$next=$Cursor
        $sorted=@($Receipts | Sort-Object {[string]$_.RequestId} -CaseSensitive)
        $after=@($sorted | Where-Object {[string]::CompareOrdinal([string]$_.RequestId,$Cursor) -gt 0})
        $before=@($sorted | Where-Object {[string]::CompareOrdinal([string]$_.RequestId,$Cursor) -le 0})
        foreach($r in @(@($after)+@($before) | Select-Object -First 20)){
            $next=[string]$r.RequestId
            $CancelToken.ThrowIfCancellationRequested()
            $id=[string]$r.RequestId
            try{
                $response=$client.GetAsync($BaseUrl+'/api/desktop/jobs/'+$id,$CancelToken).GetAwaiter().GetResult()
                if([int]$response.StatusCode -eq 404){$response.Dispose();$missing[$id]=$true}
                else{
                    $job=(Read-Response $response) | ConvertFrom-Json
                    $found[$id]=[pscustomobject]@{key=('request:'+$id);request_id=$id;username=$(if($job.username){[string]$job.username}else{[string]$r.Username});status=[string]$job.status;publish_uncertain=[bool]$job.publish_uncertain;prior_uncertain=[bool]$job.prior_uncertain;planned_for=[string]$job.planned_for;accepted_at=[string]$job.accepted_at;created_at=[string]$r.CreatedAt;time_source=[string]$job.time_source;sha256='';post_url=[string]$job.post_url;post_id=[string]$job.post_id;link_state=[string]$job.link_state;tiktok_schedule_time=[string]$job.tiktok_schedule_time;schedule_mode=[string]$job.schedule_mode}
                }
            }catch{if($CancelToken.IsCancellationRequested){throw}<# unknown outcome: the receipt stays blocking #>}
        }
        return @{Found=$found;Missing=$missing;Cursor=$next}
    }
    function Invoke-HistorySync($Data,[bool]$Single){
        $outDir=Get-CanonicalPath ([string]$Data.out_dir)
        $result=@{Changed=$false;Stale='';InputSig=[string]$Data.last_input_sig;FileStamp=[string]$Data.last_file_stamp;ProbeCursor=[string]$Data.probe_cursor;IdentityCache=$null;Failures=@();Videos=@{};Hashes=@{};Skipped=$false}
        $files=@()
        if($Data.file){$files=@($Data.file)}
        elseif([IO.Directory]::Exists($outDir)){
            foreach($file in [IO.DirectoryInfo]::new($outDir).GetFiles()){$key=Get-KhoVideoKey $file.Name;if($key){$files+=@{id=$key;path=$file.FullName}}}
        }
        if(-not $files.Count){return $result}
        if(-not $Single -and -not (Test-Health)){$result.Stale='Chưa kết nối được bộ đăng nền; trạng thái TikTok trong Kho có thể chưa mới.';return $result}
        $cacheFile=Join-Path $outDir '.cache\tiktok-identities.json'
        $cache=if($Data.identity_cache -is [hashtable]){$Data.identity_cache}else{Read-IdentityCache $cacheFile}
        $identities=Resolve-Identities $files $cache (-not $Single)
        $result.IdentityCache=$cache
        if($identities.Changed){$saveError=Save-IdentityCache $cacheFile $cache;if($saveError){$result.Stale='Không ghi được bộ nhớ mã tệp: '+$saveError}}
        foreach($v in $identities.Items){$result.Hashes[[string]$v.reel_id]=[string]$v.sha256}
        $receipts=@($Data.receipts | Where-Object {$_})
        $lookup=Invoke-Lookup $identities.Items $receipts
        if($lookup.Failed){
            if($Single){throw ('Chưa đọc được lịch sử đăng của video này: '+$lookup.Message)}
            $result.Stale='Chưa cập nhật được lịch sử TikTok cho một số video: '+$lookup.Message
        }
        $now=[DateTime]::UtcNow
        $known=@{}
        foreach($rowEntries in $lookup.Rows.Values){foreach($e in @($rowEntries)){if($e.request_id){$known[[string]$e.request_id]=$true}}}
        $candidates=@($receipts | Where-Object {
            $lookup.Rows.ContainsKey([string]$_.VideoId) -and -not $known.ContainsKey([string]$_.RequestId) -and -not $_.WorkerAlive -and
            [string]$_.Status -notin @('posted','archived')+$finalStates -and ([string]$_.Status -eq 'transfer_failed' -or (Get-TikTokReceiptAge $_ $now) -gt 120)
        })
        $probe=Invoke-Probes $candidates ([string]$Data.probe_cursor)
        $result.ProbeCursor=[string]$probe.Cursor
        $perVideo=@{}
        $busy=New-Object Collections.Generic.List[string]  # videos that can get a history: backend entries or local receipts
        $receiptIndex=New-TikTokReceiptIndex $receipts  # once per pass: receipts by video, not a scan per video
        $signature=New-Object Text.StringBuilder
        foreach($v in $identities.Items){
            $vid=[string]$v.reel_id
            $rows=$lookup.Rows[$vid]
            if($null -eq $rows){[void]$signature.Append($vid).Append("|stale`n");continue}
            $mine=$receiptIndex.ByVideo[$vid]
            [void]$signature.Append($vid).Append('|').Append([string]$v.sha256).Append("`n")
            # Nothing at all for this video: empty history, empty signature (the common case in a large Kho).
            if(-not $rows.Length -and $null -eq $mine){$perVideo[$vid]=@();continue}
            $entries=[Collections.Generic.List[object]]::new()
            foreach($e in $rows){$entries.Add($e)}
            foreach($r in $mine){if($probe.Found.ContainsKey([string]$r.RequestId)){$entries.Add($probe.Found[[string]$r.RequestId])}}
            $perVideo[$vid]=$entries.ToArray();$busy.Add($vid)
            if($entries.Count){[void]$signature.Append((Get-TikTokHistorySignature @($entries.ToArray() | ForEach-Object {ConvertTo-TikTokHistoryEntry $_})))}
        }
        foreach($r in $receipts){
            $id=[string]$r.RequestId
            [void]$signature.Append($id).Append('|').Append([string]$r.VideoId).Append('|').Append((Get-TikTokReceiptState $r ($probe.Missing.ContainsKey($id)) $now)).Append("`n")
        }
        $digest=[Security.Cryptography.SHA256]::Create()
        try{$inputSig=[BitConverter]::ToString($digest.ComputeHash([Text.Encoding]::UTF8.GetBytes($signature.ToString()))).Replace('-','')}finally{$digest.Dispose()}
        $statusFile=Join-Path $outDir 'reup-status.json'
        # Steady state: same backend answer, same receipts, file untouched since the last pass -> no read, no write (G1).
        if(-not $Single -and $inputSig -eq [string]$Data.last_input_sig -and (Get-FileStamp $statusFile) -eq [string]$Data.last_file_stamp){$result.Skipped=$true;return $result}
        $merged=@{}
        $update=Update-ReupMetadata -OutDir $outDir -Change {
            param($meta)
            $any=$false
            # Only these can change: videos with entries or receipts, and stored successes (kept when the backend lists nothing).
            # Every other video would merge to an empty history, which stores nothing.
            $todo=@{};foreach($vid in $busy){$todo[$vid]=$true}
            foreach($p in $meta.PSObject.Properties){if($perVideo.ContainsKey($p.Name) -and $p.Value.Source -eq 'autotok-history' -and @($p.Value.History | Where-Object {$_ -and [string]$_.status -eq 'succeeded'}).Count){$todo[$p.Name]=$true}}
            foreach($vid in @($todo.Keys)){
                $old=$meta.PSObject.Properties[$vid]
                # D6/S6: a video whose -3 left this folder (moved or deleted) never gets a NEW entry from a pass that captured it earlier.
                if(-not $old -and -not [IO.File]::Exists((Get-KhoVideoPath $outDir $vid))){continue}
                if($Data.reserved_ids -and ($Data.reserved_ids.ContainsKey('*') -or $Data.reserved_ids.ContainsKey($vid))){continue}  # pending move journal: recovery owns this entry
                $history=@(Merge-TikTokVideoHistory $vid $perVideo[$vid] $receipts $(if($old){$old.Value}else{$null}) $probe.Missing $now $receiptIndex)
                $merged[$vid]=$history
                if(Set-TikTokItemHistory $meta $vid $history ([string]$result.Hashes[$vid])){$any=$true}
            }
            foreach($vid in $perVideo.Keys){if(-not $merged.ContainsKey($vid)){$merged[$vid]=@()}}
            return $any
        }
        $result.Changed=[bool]$update.Changed;$result.FileStamp=[string]$update.Stamp;$result.InputSig=$inputSig;$result.Videos=$merged
        $failures=New-Object Collections.Generic.List[object]
        foreach($r in $receipts){
            $history=$merged[[string]$r.VideoId]
            if(-not $history -or (Get-TikTokReceiptAge $r $now) -gt 86400){continue}
            foreach($h in @($history)){if([string]$h.request_id -eq [string]$r.RequestId -and [string]$h.status -in @('transfer_failed','preparation_failed')){$failures.Add(@{RequestId=[string]$r.RequestId;VideoId=[string]$r.VideoId;Username=[string]$r.Username;Status=[string]$h.status});break}}
        }
        $result.Failures=$failures.ToArray()
        return $result
    }
    function Get-ActiveRequests($Meta){
        # Entries Kho shows as waiting or posting: the only ones the fast pass asks about.
        $list=New-Object Collections.Generic.List[object]
        foreach($p in $Meta.PSObject.Properties){
            if($null -eq $p.Value -or $p.Value.Source -ne 'autotok-history'){continue}
            foreach($h in @($p.Value.History)){
                if($h -and [string]$h.request_id -cmatch '^[a-f0-9]{32}$' -and [string]$h.status -in (Get-TikTokActiveStatuses)){$list.Add(@{VideoId=[string]$p.Name;RequestId=[string]$h.request_id})}
            }
        }
        return $list.ToArray()
    }
    function Invoke-FastStatus($Data){
        # Fast path: at most 10 GET /api/desktop/jobs/{id} per pass for active entries only. Never hashes files and
        # never waits for the full lookup, so a first-run hash of the whole Kho does not delay it.
        $outDir=Get-CanonicalPath ([string]$Data.out_dir)
        $stamp=Get-FileStamp (Join-Path $outDir 'reup-status.json')
        $active=if($stamp -eq [string]$Data.last_stamp -and $null -ne $Data.active){@($Data.active)}else{@(Get-ActiveRequests (Get-ReupMetadata -OutDir $outDir))}
        $result=@{Changed=$false;Stamp=$stamp;Active=$active;Cursor=[string]$Data.cursor;Polled=0}
        if(-not $active.Count){return $result}
        $sorted=@($active | Sort-Object {[string]$_.RequestId} -CaseSensitive)
        $after=@($sorted | Where-Object {[string]::CompareOrdinal([string]$_.RequestId,$result.Cursor) -gt 0})
        $before=@($sorted | Where-Object {[string]::CompareOrdinal([string]$_.RequestId,$result.Cursor) -le 0})
        $jobs=@{}
        foreach($a in @(@($after)+@($before) | Select-Object -First 10)){
            $CancelToken.ThrowIfCancellationRequested()
            $id=[string]$a.RequestId;$result.Cursor=$id
            $linked=[Threading.CancellationTokenSource]::CreateLinkedTokenSource($CancelToken);$linked.CancelAfter([TimeSpan]::FromSeconds(10))
            try{
                $response=$client.GetAsync($BaseUrl+'/api/desktop/jobs/'+$id,$linked.Token).GetAwaiter().GetResult()
                if([int]$response.StatusCode -eq 404){$response.Dispose();continue}  # not on the backend yet: the full sync decides
                $job=(Read-Response $response) | ConvertFrom-Json
                if([string]$job.status){$jobs[$id]=@{VideoId=[string]$a.VideoId;Job=$job};$result.Polled++}
            }catch{if($CancelToken.IsCancellationRequested){throw};break}  # backend unreachable: the full sync reports it
            finally{$linked.Dispose()}
        }
        if(-not $jobs.Count){return $result}
        $update=Update-ReupMetadata -OutDir $outDir -Change {
            param($meta)
            $any=$false
            foreach($vid in @($jobs.Values | ForEach-Object {$_.VideoId} | Select-Object -Unique)){
                $prop=$meta.PSObject.Properties[$vid]
                if(-not $prop -or $prop.Value.Source -ne 'autotok-history'){continue}
                if($Data.reserved_ids -and ($Data.reserved_ids.ContainsKey('*') -or $Data.reserved_ids.ContainsKey($vid))){continue}  # pending move journal
                $history=@(foreach($h in @($prop.Value.History)){
                    if($null -eq $h){continue}
                    $hit=$jobs[[string]$h.request_id]
                    if(-not $hit -or $hit.VideoId -ne $vid){$h;continue}
                    Update-TikTokEntryFromJob $h $hit.Job
                })
                if(Set-TikTokItemHistory $meta $vid $history ''){$any=$true}
            }
            return $any
        }
        $result.Changed=[bool]$update.Changed;$result.Stamp=[string]$update.Stamp;$result.Active=@(Get-ActiveRequests $update.Metadata)
        return $result
    }
    try{
        $payload=if($PayloadJson -is [string]){$PayloadJson | ConvertFrom-Json}else{$PayloadJson}
        if($Action -in @('accounts','prepare')){
            $health=Test-Health
            if(-not $health){
                if(-not $Starter -or -not (Test-Path -LiteralPath $Starter -PathType Leaf)){throw 'Chưa kết nối được bộ đăng nền. Mở autotok rồi bấm Làm mới.'}
                $process=Start-Process powershell.exe -ArgumentList @('-NoProfile','-ExecutionPolicy','Bypass','-File',('"'+$Starter+'"')) -WindowStyle Hidden -PassThru
                if(-not $process.WaitForExit(45000)){throw 'Bộ đăng nền khởi động quá lâu.'}
                # The starter can return before the web server listens: wait for /health up to 30 s (G10).
                $deadline=[DateTime]::UtcNow.AddSeconds(30)
                while(-not $health -and [DateTime]::UtcNow -lt $deadline){
                    if($CancelToken.WaitHandle.WaitOne(1000)){$CancelToken.ThrowIfCancellationRequested()}
                    $health=Test-Health
                }
                if(-not $health){throw 'Đã mở bộ đăng nền nhưng sau 30 giây vẫn chưa kết nối được. Bấm Làm mới để thử lại.'}
            }
            if($health.history_version -ne 2){throw 'Bộ đăng nền cần cập nhật lên bản lịch sử mới rồi khởi động lại.'}
            $accounts=@(Get-Json ($BaseUrl+'/api/accounts'))
            if($Action -eq 'accounts'){return (ConvertTo-Json -InputObject $accounts -Depth 5 -Compress)}
            $sync=Invoke-HistorySync $payload $true
            $videoId=[string]$payload.file.id
            return @{accounts=$accounts;history=@($sync.Videos[$videoId]);file_sha=[string]$sync.Hashes[$videoId];changed=[bool]$sync.Changed;native_schedule=[bool]$health.native_schedule}
        }
        if($Action -eq 'sync'){return (Invoke-HistorySync $payload $false)}
        if($Action -eq 'fast'){return (Invoke-FastStatus $payload)}
        if($Action -eq 'create'){
            $form=[Net.Http.MultipartFormDataContent]::new()
            try{
                foreach($key in @('username','title','scheduled_for','options_json','reel_id')){$form.Add([Net.Http.StringContent]::new([string]$payload.$key,[Text.Encoding]::UTF8),$key)}
                if($payload.source_sha256){$form.Add([Net.Http.StringContent]::new([string]$payload.source_sha256),'source_sha256')}
                $form.Add([Net.Http.StringContent]::new($RequestId),'request_id')
                $stream=[IO.File]::Open($FilePath,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::Read)
                $part=[Net.Http.StreamContent]::new($stream);$part.Headers.ContentType=[Net.Http.Headers.MediaTypeHeaderValue]::new('video/mp4')
                $form.Add($part,'video','video.mp4')
                $response=$client.PostAsync($BaseUrl+'/api/desktop/jobs',$form,$CancelToken).GetAwaiter().GetResult()
                try{
                    $text=$response.Content.ReadAsStringAsync().GetAwaiter().GetResult()
                    if($response.IsSuccessStatusCode){return $text}
                    # A handled preparation failure (HTTP 500) still carries the receipt state: report it, not a generic error.
                    $body=$null;try{$body=$text | ConvertFrom-Json}catch{$body=$null}
                    if($body -and [string]$body.status){return $text}
                    $detail=if($body -and $body.detail){' ('+[string]$body.detail+')'}else{''}
                    throw ('Bộ đăng trả về HTTP '+[int]$response.StatusCode+$detail+'. Xem Lịch sử / Lịch đăng để kiểm tra.')
                }finally{$response.Dispose()}
            }finally{$form.Dispose()}
        }
        if($Action -eq 'ext'){
            # Chrome publisher, GUI-only endpoints. HttpClient sends no Origin header (the backend refuses requests that have one).
            # HTTP refusals are returned (status + body), not thrown: the UI turns them into Vietnamese text.
            function Send-Ext([string]$Method,[string]$Path,$Body){
                $req=[Net.Http.HttpRequestMessage]::new([Net.Http.HttpMethod]::new($Method),$BaseUrl+$Path)
                try{
                    if($null -ne $Body){$req.Content=[Net.Http.StringContent]::new((ConvertTo-Json -InputObject $Body -Compress),[Text.Encoding]::UTF8,'application/json')}
                    $resp=$client.SendAsync($req,$CancelToken).GetAwaiter().GetResult()
                    try{return @{ok=[bool]$resp.IsSuccessStatusCode;status=[int]$resp.StatusCode;text=$resp.Content.ReadAsStringAsync().GetAwaiter().GetResult()}}
                    finally{$resp.Dispose()}
                }finally{$req.Dispose()}
            }
            $op=[string]$payload.op
            if($op -eq 'refresh'){
                $health=Test-Health
                if(-not $health){throw 'Chưa kết nối được bộ đăng nền. Mở app lại hoặc cài bộ đăng TikTok.'}
                $chrome=[bool]($health.PSObject.Properties['chrome_ext'] -and [int]$health.chrome_ext -ge 1)
                $clientsText='[]'
                if($chrome){
                    $c=Send-Ext 'GET' '/api/ext/clients' $null
                    if(-not $c.ok){return @{ok=$false;status=$c.status;text=$c.text}}
                    $clientsText=$c.text
                }
                return @{ok=$true;status=200;chrome=$chrome;clients=$clientsText;accounts=(ConvertTo-Json -InputObject @(Get-Json ($BaseUrl+'/api/accounts')) -Depth 5 -Compress)}
            }
            if($op -eq 'pair-code'){return (Send-Ext 'POST' '/api/ext/pair-code' @{})}
            if($op -eq 'remove-client'){return (Send-Ext 'DELETE' ('/api/ext/clients/'+[int]$payload.client_id) $null)}
            if($op -eq 'from-chrome'){return (Send-Ext 'POST' '/api/accounts/from-chrome' @{client_id=[int]$payload.client_id})}
            if($op -eq 'set-publisher'){
                $body=@{publisher=[string]$payload.publisher}
                if([string]$payload.publisher -eq 'chrome'){$body.client_id=[int]$payload.client_id;$body.confirm_username_mismatch=[bool]$payload.confirm}
                return (Send-Ext 'PATCH' ('/api/accounts/'+[int]$payload.account_id) $body)
            }
            throw 'Tác vụ Chrome không hợp lệ.'
        }
        if($Action -eq 'refresh-link'){
            $content=[Net.Http.StringContent]::new('',[Text.Encoding]::UTF8,'application/json')
            try{return (Read-Response ($client.PostAsync($BaseUrl+'/api/history/'+[Uri]::EscapeDataString([string]$payload.key)+'/refresh-link',$content,$CancelToken).GetAwaiter().GetResult()))}
            finally{$content.Dispose()}
        }
        if($Action -eq 'status'){
            $list=@()
            foreach($key in @($payload.ids)){
                $response=$client.GetAsync($BaseUrl+'/api/desktop/jobs/'+$key,$CancelToken).GetAwaiter().GetResult()
                if([int]$response.StatusCode -eq 404){$response.Dispose();$list+=[pscustomobject]@{request_id=$key;status='unknown'}}else{$list+=((Read-Response $response)|ConvertFrom-Json)}
            }
            return (ConvertTo-Json -InputObject $list -Depth 7 -Compress)
        }
        throw 'Tác vụ TikTok không hợp lệ.'
    }finally{$client.Dispose();$handler.Dispose()}
}

# Functions the background runspace needs besides the worker itself (metadata merge/write runs off the UI thread).
$script:tikTokWorkerFunctions = @('Get-CanonicalPath', 'Get-FileStamp', 'Get-ReupMutexName', 'Get-ReupMetadata', 'Update-ReupMetadata',
    'Set-ReupField', 'Get-ReupManualState', 'Update-ReupAggregate', 'Format-TikTokTime', 'Get-TikTokSortKey', 'ConvertTo-TikTokHistoryEntry',
    'Get-TikTokHistorySignature', 'Get-TikTokReceiptAge', 'Get-TikTokReceiptState', 'Merge-TikTokVideoHistory', 'Set-TikTokItemHistory',
    'Test-TikTokStaleDowngrade', 'Get-TikTokActiveStatuses', 'Update-TikTokEntryFromJob', 'New-TikTokReceiptIndex',
    'Test-KhoVideoFileName', 'Get-KhoVideoKey', 'Test-KhoVideoKey', 'Get-KhoVideoFileName', 'Get-KhoVideoPath', 'Get-KhoThumbKey')

function Get-TikTokWorkerSessionState {
    # Functions are defined through the session state (not a prepended statement): a multi-statement batch runs on a
    # thread-pool work item that crashes the process if the app exits while a task is still running.
    if (-not $script:tikTokWorkerState) {
        $state = [Management.Automation.Runspaces.InitialSessionState]::CreateDefault()
        foreach ($name in $script:tikTokWorkerFunctions) {
            $state.Commands.Add([Management.Automation.Runspaces.SessionStateFunctionEntry]::new($name, (Get-Item -LiteralPath "function:$name").ScriptBlock.ToString()))
        }
        $script:tikTokWorkerState = $state
    }
    return $script:tikTokWorkerState
}

function Start-TikTokTask {
    param([string]$Action, $Payload = @{}, [string]$FilePath = '', [string]$RequestId = '')
    if ($Payload -is [hashtable] -and $Payload.ContainsKey('out_dir')) {
        # Ids reserved by an unresolved move journal: the worker's Change blocks skip them (recovery would overwrite their writes).
        $reserved = Get-KhoReservedIds ([string]$Payload.out_dir)
        if ($reserved.Count) { Write-FileLogLimited -Key 'kho-reserved' -Text ('WARN TikTok sync bỏ qua video đang chờ hoàn tất chuyển kho: ' + (@($reserved.Keys) -join ', ')) -MinSeconds 300 }
        $Payload.reserved_ids = $reserved
    }
    $ps = [PowerShell]::Create((Get-TikTokWorkerSessionState))
    $cancel=[Threading.CancellationTokenSource]::new()
    try {
        # The payload object is handed over as-is (no JSON round trip on the UI thread); the caller does not touch it afterwards.
        [void]$ps.AddScript($script:tikTokWorker.ToString()).AddArgument($Action).AddArgument((Get-TikTokEndpoint)).AddArgument($FilePath).AddArgument($Payload).AddArgument($RequestId).AddArgument([string]$script:tikTok.Launcher).AddArgument($cancel.Token)
        return @{ PS=$ps; Async=$ps.BeginInvoke(); Action=$Action; Cancel=$cancel; Clock=[Diagnostics.Stopwatch]::StartNew() }
    } catch { $ps.Dispose(); $cancel.Dispose(); throw }
}

function Complete-TikTokTask {
    param($Task)
    try {
        $result = @($Task.PS.EndInvoke($Task.Async))
        if ($Task.PS.HadErrors -and $Task.PS.Streams.Error.Count) { throw ([string]$Task.PS.Streams.Error[0]) }
        if ($result.Count -eq 1 -and $result[0] -isnot [string]) { return $result[0] }
        return (($result -join '') | ConvertFrom-Json -ErrorAction Stop)
    } finally { $Task.PS.Dispose(); if($Task.Cancel){$Task.Cancel.Dispose()} }
}

function Stop-TikTokTask {
    # Never blocks the UI thread (G8): cancel cooperatively, ask the pipeline to stop, and dispose only after both
    # the invocation and the stop request have completed, from a timer.
    param($Task)
    if (-not $Task) { return }
    try { $Task.Cancel.Cancel() } catch { Write-FileLog "WARN TikTok cancel: $($_.Exception.Message)" }
    try { $Task.StopAsync = $Task.PS.BeginStop($null, $null) } catch { Write-FileLog "WARN TikTok stop: $($_.Exception.Message)" }
    if (-not $script:tikTokReaper) {
        $script:tikTokReaper = @{ Tasks = New-Object System.Collections.ArrayList; Timer = New-Object Windows.Threading.DispatcherTimer }
        $script:tikTokReaper.Timer.Interval = [TimeSpan]::FromMilliseconds(500)
        $script:tikTokReaper.Timer.Add_Tick({ Invoke-TikTokReaper })
    }
    [void]$script:tikTokReaper.Tasks.Add($Task)
    $script:tikTokReaper.Timer.Start()
}

function Invoke-TikTokReaper {
    foreach ($task in @($script:tikTokReaper.Tasks)) {
        if (-not $task.Async.IsCompleted -or ($task.StopAsync -and -not $task.StopAsync.IsCompleted)) { continue }
        try { [void]$task.PS.EndInvoke($task.Async) } catch { <# cancelled on purpose: the outcome is discarded #> }
        try { if ($task.StopAsync) { $task.PS.EndStop($task.StopAsync) } } catch { <# stop of an already finished pipeline #> }
        try { $task.PS.Dispose(); $task.Cancel.Dispose() } catch { Write-FileLog "WARN TikTok dispose: $($_.Exception.Message)" }
        $script:tikTokReaper.Tasks.Remove($task)
    }
    if (-not $script:tikTokReaper.Tasks.Count) { $script:tikTokReaper.Timer.Stop() }
}

function Save-TikTokReceipt {
    param($Record)
    $dir = Join-Path $Record.OutDir '.cache\tiktok-posts'
    [void][IO.Directory]::CreateDirectory($dir)
    $target = Join-Path $dir ($Record.RequestId + '.json')
    $temp = $target + '.' + [Guid]::NewGuid().ToString('N') + '.tmp'
    try {
        $stream = [IO.File]::Open($temp, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
        try {
            $bytes = [Text.UTF8Encoding]::new($false).GetBytes(($Record | ConvertTo-Json -Depth 5))
            $stream.Write($bytes,0,$bytes.Length); $stream.Flush($true)
        } finally { $stream.Dispose() }
        if ([IO.File]::Exists($target)) { [IO.File]::Replace($temp,$target,[Management.Automation.Language.NullString]::Value) }
        else { [IO.File]::Move($temp,$target) }
    } finally { if ([IO.File]::Exists($temp)) { [IO.File]::Delete($temp) } }
}

function Get-TikTokReceipts {
    # Parsed receipts are cached by file stamp: a steady sync pass does not re-read them, and an invalid receipt is
    # logged once per version instead of every pass (G7).
    param([string]$OutDir)
    $out = Get-CanonicalPath $OutDir
    $dir = Join-Path $out '.cache\tiktok-posts'
    if (-not [IO.Directory]::Exists($dir)) { return }
    if (-not $script:tikTokReceiptCache) { $script:tikTokReceiptCache = @{} }
    foreach ($file in [IO.DirectoryInfo]::new($dir).GetFiles('*.json')) {
        if (-not $file.Name.EndsWith('.json', [StringComparison]::OrdinalIgnoreCase)) { continue }
        $stamp = $file.Length.ToString() + '|' + $file.LastWriteTimeUtc.Ticks
        $hit = $script:tikTokReceiptCache[$file.FullName]
        if ($hit -and $hit.Stamp -eq $stamp) { if ($hit.Record) { $hit.Record }; continue }
        $record = $null
        try {
            $parsed = [IO.File]::ReadAllText($file.FullName) | ConvertFrom-Json -ErrorAction Stop
            if ($parsed.RequestId -notmatch '^[a-f0-9]{32}$' -or $file.BaseName -ne $parsed.RequestId -or
                -not (Test-SamePath ([string]$parsed.OutDir) $out) -or
                -not (Test-SamePath ([IO.Path]::GetDirectoryName([string]$parsed.SourcePath)) $out) -or
                -not (Test-KhoVideoKey ([string]$parsed.VideoId)) -or [string]$parsed.VideoId -ne (Get-ReelId $parsed.SourcePath)) { throw 'Biên nhận không hợp lệ.' }
            $record = $parsed
        } catch { Write-FileLog ('WARN TikTok receipt ignored: ' + $file.Name + ' · ' + $_.Exception.Message) }
        $script:tikTokReceiptCache[$file.FullName] = @{ Stamp = $stamp; Record = $record }
        if ($record) { $record }
    }
}

function Test-TikTokWorkerAlive {
    # R2: the background process holds <id>.lock with FileShare.None for its whole life.
    param([string]$OutDir, [string]$RequestId)
    $lock = Join-Path (Join-Path $OutDir '.cache\tiktok-posts') ($RequestId + '.lock')
    if (-not [IO.File]::Exists($lock)) { return $false }
    try { $probe = [IO.File]::Open($lock, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::ReadWrite -bor [IO.FileShare]::Delete); $probe.Dispose(); return $false }
    catch [IO.FileNotFoundException] { return $false }
    catch [IO.IOException] { return $true }
    catch { return $false }
}

function Get-TikTokReceiptViews {
    # Fresh copies for the background runspace (cached receipt objects are never shared across threads).
    param([string]$OutDir)
    foreach ($r in @(Get-TikTokReceipts $OutDir)) {
        $final = [string]$r.Status -in @('posted', 'succeeded', 'failed', 'cancelled', 'preparation_failed', 'missing')
        [pscustomobject]@{
            RequestId = [string]$r.RequestId; VideoId = [string]$r.VideoId; Username = [string]$r.Username; ScheduledFor = [string]$r.ScheduledFor
            Status = [string]$r.Status; CreatedAt = [string]$r.CreatedAt; LaunchedAt = [string]$r.LaunchedAt
            SourceSha256 = [string]$r.SourceSha256; UploadSha256 = [string]$r.UploadSha256
            WorkerAlive = $(if ($final) { $false } else { Test-TikTokWorkerAlive $OutDir ([string]$r.RequestId) })
        }
    }
}

function Test-TikTokTransferActive {
    # A live background transfer is still reading this file (R2): deleting it now would break the upload.
    param([string]$FilePath)
    try {
        $source = Get-CanonicalPath $FilePath
        $out = [IO.Path]::GetDirectoryName($source)
        $dir = Join-Path $out '.cache\tiktok-posts'
        if (-not [IO.Directory]::Exists($dir)) { return $false }
        foreach ($lock in [IO.DirectoryInfo]::new($dir).GetFiles('*.lock')) {
            if ($lock.Name -notmatch '^([a-f0-9]{32})\.lock$') { continue }
            $id = $Matches[1]
            if (-not (Test-TikTokWorkerAlive $out $id)) { continue }
            try {
                $record = [IO.File]::ReadAllText((Join-Path $dir ($id + '.json'))) | ConvertFrom-Json -ErrorAction Stop
                if (Test-SamePath ([string]$record.SourcePath) $source) { return $true }
            } catch { return $true }
        }
    } catch { Write-FileLog "WARN TikTok transfer check '$FilePath': $($_.Exception.Message)" }
    return $false
}

function Get-TikTokActiveStatuses {
    # Backend job states that are still going (a new post on the account waits for them). pending_ext / waiting_ext are
    # the Chrome publisher's states (waiting for the extension / the extension is posting).
    return @('preparing', 'pending', 'queued', 'running', 'pending_ext', 'waiting_ext')
}

# ------------------------------------------------------------- Chrome publisher: accounts, clients, pairing ----
function Test-TikTokAccountReady {
    # AccountRead.ready (cookies: session, Chrome: bound client online). A backend without Chrome support has no
    # `ready`: fall back to has_valid_session.
    param($Account)
    if ($null -eq $Account) { return $false }
    if ($Account.PSObject.Properties['ready']) { return [bool]$Account.ready }
    return [bool]$Account.has_valid_session
}

function Select-TikTokReadyAccounts {
    param($Accounts)
    return @(@($Accounts) | Where-Object { $_ -and (Test-TikTokAccountReady $_) })
}

function Get-TikTokReadyReasonText {
    param([string]$Reason)
    switch ($Reason) {
        'chrome_offline' { return 'Chrome chưa mở/chưa bật tiện ích' }
        'chrome_conflict' { return 'Có hai hồ sơ Chrome cùng tài khoản này — gỡ bớt một ở Cài đặt → Kết nối Chrome' }
        'chrome_need_reload' { return 'Cần tải lại tiện ích (chrome://extensions → ⟳)' }
        'chrome_unbound' { return 'Chưa gắn với Chrome nào — kết nối Chrome ở Cài đặt' }
        'no_session' { return 'chưa đăng nhập' }
    }
    return ''
}

function Get-TikTokAccountNote {
    # Why a not-ready account cannot be picked ('' when it is ready).
    param($Account)
    if (Test-TikTokAccountReady $Account) { return '' }
    if ($Account.PSObject.Properties['ready_reason']) {
        $text = Get-TikTokReadyReasonText ([string]$Account.ready_reason)
        if ($text) { return $text }
    }
    if ($Account.PSObject.Properties['publisher'] -and [string]$Account.publisher -eq 'chrome') { return 'Chrome chưa sẵn sàng' }
    return 'chưa đăng nhập'
}

function Get-TikTokNoReadyAccountsText {
    # Text for "no account can post now": names the reason of each account that exists.
    param($Accounts)
    $list = @(@($Accounts) | Where-Object { $_ })
    if (-not $list.Count) { return 'Chưa có tài khoản. Mở Tài khoản / Lịch đăng để thêm, hoặc Cài đặt → Kết nối Chrome.' }
    $parts = @($list | ForEach-Object { '@' + [string]$_.username + ': ' + (Get-TikTokAccountNote $_) })
    return 'Chưa có tài khoản sẵn sàng. ' + ($parts -join '; ')
}

function Get-ChromeClientStatusText {
    param($Client)
    switch ([string]$Client.status) {
        'ok' { return 'Đang kết nối' }
        'need_reload' { return 'Cần tải lại tiện ích' }
        'offline' { return 'Chrome chưa mở' }
        'no_identity' { return 'Chưa đăng nhập TikTok trong Chrome' }
        'conflict' { return 'Trùng tài khoản với Chrome khác' }
    }
    return 'Chưa rõ'
}

function Format-ChromeLastSeen {
    param([string]$Value, [DateTime]$NowUtc = [DateTime]::UtcNow)
    if (-not $Value) { return 'chưa thấy' }
    try { $when = [DateTimeOffset]::Parse($Value, [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::AssumeUniversal) } catch { return 'chưa rõ' }
    $age = ($NowUtc - $when.UtcDateTime).TotalSeconds
    if ($age -lt 0) { $age = 0 }
    if ($age -lt 60) { return 'vừa xong' }
    if ($age -lt 3600) { return ([int][Math]::Floor($age / 60)).ToString() + ' phút trước' }
    return $when.ToLocalTime().ToString('HH:mm dd/MM')
}

function Test-ChromeNeedReload {
    param($Clients)
    return [bool](@(@($Clients) | Where-Object { $_ -and [bool]$_.need_reload }).Count)
}

function Get-ChromePairCodeRemaining {
    # Whole seconds left of a pairing code (0 = expired).
    param([string]$ExpiresAt, [DateTime]$NowUtc = [DateTime]::UtcNow)
    try { $end = [DateTimeOffset]::Parse($ExpiresAt, [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::AssumeUniversal).UtcDateTime } catch { return 0 }
    return [int][Math]::Max(0, [Math]::Ceiling(($end - $NowUtc).TotalSeconds))
}

function Get-ChromeApiErrorText {
    # Backend refusals of the Chrome calls -> Vietnamese. Body is the raw response text ({"detail": ...} or {"message": ...}).
    param([int]$Status, [string]$Body)
    $detail = ''
    try {
        $o = $Body | ConvertFrom-Json -ErrorAction Stop
        if ($o.PSObject.Properties['message'] -and $o.message) { $detail = [string]$o.message }
        elseif ($o.PSObject.Properties['detail'] -and $o.detail -is [string]) { $detail = [string]$o.detail }
    } catch { $detail = '' }
    if ($detail -match '[^\u0000-\u007F]') { return $detail }   # the backend already speaks Vietnamese
    switch -Regex ($detail) {
        'username already exists' { return 'Đã có tài khoản trùng tên này.' }
        'client_id is required' { return 'Chưa chọn Chrome để gắn.' }
        'pending or running' { return 'Tài khoản còn video đang chờ hoặc đang đăng — đợi xong hoặc hủy trước.' }
        'not found' { return 'Không tìm thấy tài khoản này (có thể đã bị xóa).' }
    }
    switch ($Status) {
        403 { return 'Bộ đăng từ chối yêu cầu này.' }
        404 { return 'Không tìm thấy (có thể đã bị gỡ).' }
        409 { return 'Bộ đăng không cho thực hiện lúc này.' }
        422 { return 'Thông tin gửi lên chưa đúng.' }
    }
    return "Bộ đăng trả về lỗi $Status."
}

function Get-ChromeAutoSwitchPlan {
    # Owner decision: Chrome is the default publisher. A cookie account whose TikTok username is reported by exactly one
    # healthy connected Chrome is switched to Chrome once. Never switched: accounts the owner put back on Cookie,
    # accounts already tried this session, a conflict (two profiles with the same user), a client that is not 'ok'
    # (offline / needs reload / no identity), several matching clients, and a different username (mismatch needs a
    # human confirmation, so it is not automatic). The backend's own rules still apply (confirm_username_mismatch=false).
    param($Accounts, $Clients, $CookieChoice = @(), [hashtable]$Tried = @{})
    $plan = New-Object System.Collections.Generic.List[object]
    $choice = @(@($CookieChoice) | ForEach-Object { [string]$_ })
    $list = @(@($Clients) | Where-Object { $_ })
    foreach ($a in @($Accounts)) {
        if (-not $a -or -not $a.PSObject.Properties['publisher'] -or [string]$a.publisher -ne 'cookies') { continue }
        $id = [string]$a.id
        if ($choice -contains $id -or $Tried.ContainsKey($id)) { continue }
        $name = ([string]$a.username).Trim().TrimStart('@')
        if (-not $name) { continue }
        $same = @($list | Where-Object { $_.tiktok_username -and ([string]$_.tiktok_username).Trim().TrimStart('@') -ieq $name })
        if (-not $same.Count) { continue }
        if (@($same | Where-Object { [string]$_.status -eq 'conflict' -or [bool]$_.conflict }).Count) { continue }
        $good = @($same | Where-Object { [string]$_.status -eq 'ok' -and [bool]$_.has_identity })
        if ($good.Count -ne 1 -or $same.Count -ne 1) { continue }
        $plan.Add(@{ Account = $a; Client = $good[0] })
    }
    return $plan.ToArray()
}

function Get-TikTokStatusText {
    param($Result)
    if ($Result.publish_uncertain) { return 'Chưa rõ kết quả: video có thể đã lên TikTok. Kiểm tra tài khoản trước khi đăng lại.' }
    switch ([string]$Result.status) {
        'pending' { 'Đã nhận tác vụ, sắp gửi lên TikTok.' }
        'running' { 'Đang gửi video lên TikTok…' }
        'pending_ext' { 'Chờ Chrome: mở Chrome có tiện ích để đăng.' }
        'waiting_ext' { 'Chrome đang đăng video lên TikTok…' }
        'succeeded' { 'TikTok đã nhận yêu cầu đăng thành công. Video có thể cần thời gian xử lý.' }
        'failed' { 'Đăng thất bại. Xem chi tiết trong Lịch đăng ở bảng điều khiển.' }
        'cancelled' { 'Tác vụ đã được hủy.' }
        'preparing' { 'Đang chuẩn bị hoặc chuẩn bị bị gián đoạn. Kiểm tra bảng điều khiển trước khi gửi lại.' }
        'missing' { 'Tác vụ đã bị xóa khỏi bảng điều khiển. Kiểm tra tài khoản trước khi đăng lại.' }
        default { 'Chưa xác nhận được tác vụ. Bấm Kiểm tra kết quả; không gửi lại khi chưa kiểm tra.' }
    }
}

function Apply-TikTokResult {
    param($Record, $Result)
    if ($Result.status -eq 'succeeded' -and $Record.Status -ne 'posted') {
        Set-ReupMetadata -VideoId $Record.VideoId -Posted $true -OutDir $Record.OutDir
        $Record.Status = 'posted'
        Save-TikTokReceipt $Record
        if (Get-KhoByPath ([string]$Record.OutDir)) { Update-Gallery }
    }
}

function Format-TikTokTime {
    param([string]$Value,[switch]$Short)
    if(-not $Value){return 'chưa rõ giờ'}
    try{ $when=[DateTimeOffset]::Parse($Value,[Globalization.CultureInfo]::InvariantCulture,[Globalization.DateTimeStyles]::AssumeUniversal).ToLocalTime(); return $when.ToString($(if($Short){'dd/MM HH:mm'}else{'dd/MM/yyyy HH:mm:ss'})) }catch{return 'chưa rõ giờ'}
}

function Format-TikTokClock {
    # "HH:mm dd/MM" in local time (Đã hẹn trên TikTok · 19:00 25/10).
    param([string]$Value)
    try { return [DateTimeOffset]::Parse($Value, [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::AssumeUniversal).ToLocalTime().ToString('HH:mm dd/MM') } catch { return 'chưa rõ giờ' }
}

function Test-TikTokPostUrl {
    # The only URLs the app opens or copies: a public TikTok post link built by the backend.
    param([string]$Url)
    return [bool]($Url -cmatch '^https://www\.tiktok\.com/@[A-Za-z0-9._]+/video/[0-9]+\z')
}

function Test-TikTokPostId {
    # TikTok post ids are 17-20 ASCII digits; anything else is never copied.
    param([string]$Id)
    return [bool]($Id -cmatch '^[0-9]{17,20}\z')
}

function Test-TikTokHeldByTikTok {
    # TikTok accepted the post and publishes it at tiktok_schedule_time (still in the future).
    param($Entry, [DateTime]$NowUtc = [DateTime]::UtcNow)
    if ([string]$Entry.status -ne 'succeeded' -or -not [string]$Entry.tiktok_schedule_time) { return $false }
    try { return ([DateTimeOffset]::Parse([string]$Entry.tiktok_schedule_time, [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::AssumeUniversal).UtcDateTime -gt $NowUtc) } catch { return $false }
}

function Get-TikTokLinkText {
    # Link part of a succeeded entry: the URL, or why there is none yet.
    param($Entry)
    if (Test-TikTokPostUrl ([string]$Entry.post_url)) { return [string]$Entry.post_url }
    if ([string]$Entry.link_state -eq 'found' -and (Test-TikTokPostId ([string]$Entry.post_id))) { return 'Mã bài: ' + [string]$Entry.post_id }
    switch ([string]$Entry.link_state) {
        'pending' { return 'Đang lấy link…' }
        'gave_up' { return 'Chưa lấy được link' }
        'scheduled_on_tiktok' { return 'Có link sau giờ đăng' }
    }
    return ''
}

function Get-TikTokScheduleBounds {
    # Hẹn giờ trên TikTok: TikTok holds the post; allowed from 20 minutes to 10 days ahead (local time).
    param([DateTime]$Now = [DateTime]::Now)
    # Min is rounded UP to the next whole minute so the minute shown in the hint is accepted.
    $min = $Now.AddMinutes(20)
    $floor = $min.AddTicks(-($min.Ticks % [TimeSpan]::TicksPerMinute))
    if ($floor -lt $min) { $floor = $floor.AddMinutes(1) }
    return @{ Min = $floor; Max = $Now.AddDays(10) }
}

function Test-TikTokScheduleDay {
    param([DateTime]$Day, [DateTime]$Now = [DateTime]::Now)
    $b = Get-TikTokScheduleBounds $Now
    return ($Day.Date -ge $b.Min.Date -and $Day.Date -le $b.Max.Date)
}

function Get-TikTokScheduleError {
    # '' when TikTok can schedule $When (local time); otherwise the message shown to the user.
    param([DateTime]$When, [DateTime]$Now = [DateTime]::Now)
    $b = Get-TikTokScheduleBounds $Now
    if ($When -lt $b.Min -or $When -gt $b.Max) {
        return ('Chọn giờ từ ' + $b.Min.ToString('HH:mm dd/MM') + ' đến ' + $b.Max.ToString('HH:mm dd/MM') + ' (20 phút đến 10 ngày tới).')
    }
    return ''
}

function Get-TikTokSortKey {
    param([string]$Value)
    if (-not $Value) { return [long]0 }
    try { return [DateTimeOffset]::Parse($Value, [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::AssumeUniversal).UtcTicks }
    catch { return [long]0 }
}

function ConvertTo-TikTokHistoryEntry {
    # Compact history entry stored in reup-status.json (R5): exactly the fields the UI needs.
    param($Entry)
    return [pscustomobject]@{
        key = [string]$Entry.key; request_id = [string]$Entry.request_id; username = [string]$Entry.username; status = [string]$Entry.status
        publish_uncertain = [bool]$Entry.publish_uncertain; prior_uncertain = [bool]$Entry.prior_uncertain
        planned_for = [string]$Entry.planned_for; accepted_at = [string]$Entry.accepted_at; created_at = [string]$Entry.created_at
        time_source = [string]$Entry.time_source; sha256 = [string]$Entry.sha256
        post_url = [string]$Entry.post_url; post_id = [string]$Entry.post_id; link_state = [string]$Entry.link_state; tiktok_schedule_time = [string]$Entry.tiktok_schedule_time
        schedule_mode = [string]$Entry.schedule_mode
    }
}

function Get-TikTokHistorySignature {
    param([object[]]$History)
    $text = New-Object System.Text.StringBuilder
    foreach ($h in @($History)) {
        if ($null -eq $h) { continue }
        [void]$text.Append([string]$h.key).Append('|').Append([string]$h.request_id).Append('|').Append([string]$h.username).Append('|').Append([string]$h.status).Append('|').Append([bool]$h.publish_uncertain).Append('|').Append([bool]$h.prior_uncertain).Append('|').Append([string]$h.planned_for).Append('|').Append([string]$h.accepted_at).Append('|').Append([string]$h.created_at).Append('|').Append([string]$h.time_source).Append('|').Append([string]$h.sha256).Append('|').Append([string]$h.post_url).Append('|').Append([string]$h.post_id).Append('|').Append([string]$h.link_state).Append('|').Append([string]$h.tiktok_schedule_time).Append('|').Append([string]$h.schedule_mode).Append("`n")
    }
    return $text.ToString()
}

function Get-TikTokReceiptAge {
    param($Receipt, [DateTime]$NowUtc)
    $since = if ($Receipt.LaunchedAt) { [string]$Receipt.LaunchedAt } else { [string]$Receipt.CreatedAt }
    try { return ($NowUtc - [DateTimeOffset]::Parse($since, [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::AssumeUniversal).UtcDateTime).TotalSeconds }
    catch { return [double]::MaxValue }
}

function Get-TikTokReceiptState {
    # Local state of a receipt the backend history does not list (R2). 'preparing' blocks the account;
    # 'transfer_failed' ("Chưa chuyển được") does not and offers retry/archive in the dialog.
    param($Receipt, [bool]$NotFound, [DateTime]$NowUtc)
    if ($Receipt.WorkerAlive) { return 'preparing' }
    $recorded = [string]$Receipt.Status
    if ($recorded -in @('succeeded', 'failed', 'cancelled', 'preparation_failed', 'missing')) { return $recorded }
    if ($NotFound -and ($recorded -eq 'transfer_failed' -or (Get-TikTokReceiptAge $Receipt $NowUtc) -gt 120)) { return 'transfer_failed' }
    return 'preparing'
}

function Test-TikTokStaleDowngrade {
    # A stored success is never replaced by non-terminal data for the same request (A2). Entries carry no attempt id and a
    # retry is a new request_id, so there is no "newer attempt" to tell apart.
    param($Stored, [string]$IncomingStatus)
    return [bool]($Stored -and [string]$Stored.status -eq 'succeeded' -and $IncomingStatus -in (Get-TikTokActiveStatuses))
}

function Update-TikTokEntryFromJob {
    # Fast path: the stored entry (key, created_at, sha256 kept) with everything the backend reports for the same request.
    # Stale non-terminal data does not undo a stored success.
    param($Stored, $Job)
    $e = ConvertTo-TikTokHistoryEntry $Stored
    if (Test-TikTokStaleDowngrade $Stored ([string]$Job.status)) { return $e }
    $e.status = [string]$Job.status; $e.publish_uncertain = [bool]$Job.publish_uncertain; $e.prior_uncertain = [bool]$Job.prior_uncertain
    if ($Job.username) { $e.username = [string]$Job.username }
    if ($Job.planned_for) { $e.planned_for = [string]$Job.planned_for }
    $e.accepted_at = [string]$Job.accepted_at; $e.post_url = [string]$Job.post_url; $e.post_id = [string]$Job.post_id; $e.link_state = [string]$Job.link_state
    $e.tiktok_schedule_time = [string]$Job.tiktok_schedule_time; $e.schedule_mode = [string]$Job.schedule_mode
    if ($Job.time_source) { $e.time_source = [string]$Job.time_source }
    return $e
}

function New-TikTokReceiptIndex {
    # Built once per sync pass: receipts by VideoId and the upload-hash map, so no pass scans all receipts per video (A7).
    param([object[]]$Receipts)
    $byVideo = @{}; $uploads = @{}
    foreach ($r in @($Receipts)) {
        if (-not $r) { continue }
        if ($r.UploadSha256 -and $r.SourceSha256) { $uploads[[string]$r.RequestId] = $r }
        $vid = [string]$r.VideoId
        if (-not $byVideo.ContainsKey($vid)) { $byVideo[$vid] = New-Object System.Collections.Generic.List[object] }
        $byVideo[$vid].Add($r)
    }
    return @{ ByVideo = $byVideo; Uploads = $uploads }
}

function Merge-TikTokVideoHistory {
    # Backend entries + confirmed successes kept from the stored item + local receipts not yet known to the backend.
    # $Index (New-TikTokReceiptIndex) is optional: a sync pass builds it once; a single call builds its own.
    param([string]$VideoId, [object[]]$Entries, [object[]]$Receipts, $OldItem, [hashtable]$NotFound = @{}, [DateTime]$NowUtc = [DateTime]::UtcNow, [hashtable]$Index = $null)
    if (-not $Index) { $Index = New-TikTokReceiptIndex $Receipts }
    $all = New-Object System.Collections.Generic.List[object]
    $keys = @{}; $requests = @{}   # value = position in $all
    # The backend hashes the uploaded metadata-clean copy; map that hash back to the original -3 file (D5 comparison).
    $uploads = $Index.Uploads
    foreach ($e in @($Entries)) {
        if ($null -eq $e) { continue }
        $h = ConvertTo-TikTokHistoryEntry $e
        $upload = if ($h.request_id) { $uploads[$h.request_id] } else { $null }
        if ($upload -and [string]::Equals($h.sha256, [string]$upload.UploadSha256, [StringComparison]::OrdinalIgnoreCase)) { $h.sha256 = [string]$upload.SourceSha256 }
        if (-not $h.key -and $h.request_id) { $h.key = 'request:' + $h.request_id }
        if (-not $h.key -or $keys.ContainsKey($h.key)) { continue }
        $keys[$h.key] = $all.Count
        if ($h.request_id) { $requests[$h.request_id] = $all.Count }
        $all.Add($h)
    }
    if ($OldItem -and $OldItem.Source -eq 'autotok-history') {
        # A success the backend no longer reports (deleted history row) must not make the video look unposted.
        foreach ($old in @($OldItem.History)) {
            if (-not $old -or [string]$old.status -ne 'succeeded' -or -not [string]$old.key) { continue }
            $slot = $null
            if ($keys.ContainsKey([string]$old.key)) { $slot = $keys[[string]$old.key] }
            elseif ($old.request_id -and $requests.ContainsKey([string]$old.request_id)) { $slot = $requests[[string]$old.request_id] }
            if ($null -ne $slot) {
                # Same request already in the incoming data: a stale non-terminal copy must not undo the stored success (A2).
                if (Test-TikTokStaleDowngrade $old ([string]$all[$slot].status)) { $all[$slot] = ConvertTo-TikTokHistoryEntry $old }
                continue
            }
            $h = ConvertTo-TikTokHistoryEntry $old
            $keys[$h.key] = $all.Count
            # Also claim the request: a local receipt of an already confirmed request is not listed again.
            if ($h.request_id) { $requests[$h.request_id] = $all.Count }
            $all.Add($h)
        }
    }
    foreach ($r in $Index.ByVideo[$VideoId]) {   # not @(...): that fails on a List[object] in Windows PowerShell 5.1
        if (-not $r) { continue }
        $id = [string]$r.RequestId
        if ($requests.ContainsKey($id) -or [string]$r.Status -eq 'posted') { continue }
        $requests[$id] = $all.Count
        $all.Add([pscustomobject]@{
            key = 'local:' + $id; request_id = $id; username = [string]$r.Username; status = (Get-TikTokReceiptState $r ([bool]$NotFound[$id]) $NowUtc)
            publish_uncertain = $false; prior_uncertain = $false; planned_for = [string]$r.ScheduledFor; accepted_at = ''
            created_at = [string]$r.CreatedAt; time_source = 'local'; sha256 = ''
            post_url = ''; post_id = ''; link_state = ''; tiktok_schedule_time = ''; schedule_mode = $(if ([string]$r.ScheduledFor) { 'native' } else { 'now' })
        })
    }
    return @($all | Sort-Object { Get-TikTokSortKey ([string]$_.created_at) } -Descending)
}

function Set-TikTokItemHistory {
    # Store the merged history of one video; returns $true only when the stored item changed. Never touches the manual mark.
    param($Metadata, [string]$VideoId, [object[]]$History, [string]$FileSha256 = '')
    if (-not @($History).Count) { return $false }
    $property = $Metadata.PSObject.Properties[$VideoId]
    $item = if ($property) { $property.Value } else { $null }
    if ($item -and $item.Source -eq 'autotok-history' -and $item.PSObject.Properties['ManualPosted'] -and
        (-not $FileSha256 -or [string]$item.FileSha256 -eq $FileSha256) -and
        (Get-TikTokHistorySignature @($item.History)) -eq (Get-TikTokHistorySignature $History)) { return $false }
    if (-not $item) {
        $item = [pscustomobject]@{ Posted = $false; Date = '' }
        $Metadata | Add-Member -MemberType NoteProperty -Name $VideoId -Force -Value $item
    }
    $manual = Get-ReupManualState $item
    Set-ReupField $item 'ManualPosted' ([bool]$manual.Posted)
    Set-ReupField $item 'ManualDate' ([string]$manual.Date)
    Set-ReupField $item 'Source' 'autotok-history'
    Set-ReupField $item 'History' @($History)
    if ($FileSha256) { Set-ReupField $item 'FileSha256' $FileSha256 }
    Update-ReupAggregate $item
    return $true
}

function Test-TikTokPriorVersion {
    # D5/R9: an entry recorded for a different file content than the current -3 file.
    param($Entry, [string]$FileSha256)
    return [bool]([string]$Entry.sha256 -and $FileSha256 -and -not [string]::Equals([string]$Entry.sha256, $FileSha256, [StringComparison]::OrdinalIgnoreCase))
}

function Get-TikTokEntryMode {
    # 'native' (TikTok holds the post until its time), 'now' or 'local' (legacy job that waited on this PC).
    # planned_for alone cannot tell: the backend sets it to the creation time of a "now" job too.
    param($Entry)
    $mode = [string]$Entry.schedule_mode
    if ($mode) { return $mode }
    if ([string]$Entry.tiktok_schedule_time) { return 'native' }
    if (-not [string]$Entry.planned_for) { return 'now' }
    # Backend without schedule_mode: TikTok schedules start 20 minutes ahead, so a plan within 15 minutes
    # of creation is a "now" job's creation time.
    $planned = Get-TikTokSortKey ([string]$Entry.planned_for); $created = Get-TikTokSortKey ([string]$Entry.created_at)
    if ($planned -and $created -and ($planned - $created) -lt [TimeSpan]::FromMinutes(15).Ticks) { return 'now' }
    return 'native'
}

function Get-TikTokEntryWhen {
    # The time TikTok publishes a scheduled entry: what TikTok accepted, else what was asked.
    param($Entry)
    if ([string]$Entry.tiktok_schedule_time) { return [string]$Entry.tiktok_schedule_time }
    return [string]$Entry.planned_for
}

function Get-TikTokEntryLabel {
    param($Entry, [string]$FileSha256 = '')
    $mode = Get-TikTokEntryMode $Entry
    $label = switch ([string]$Entry.status) {
        'succeeded' {
            if (Test-TikTokHeldByTikTok $Entry) { 'Đã hẹn trên TikTok · ' + (Format-TikTokClock ([string]$Entry.tiktok_schedule_time)) + ' (có thể tắt máy)' }
            else { $link = Get-TikTokLinkText $Entry; 'Đã đăng · ' + (Format-TikTokClock $(if ([string]$Entry.tiktok_schedule_time) { [string]$Entry.tiktok_schedule_time } else { [string]$Entry.accepted_at })) + $(if ($link) { ' · ' + $link } else { '' }) }
        }
        { $_ -in @('pending', 'queued') } {
            if ($mode -eq 'native') { 'Chờ gửi lên TikTok · hẹn ' + (Format-TikTokClock (Get-TikTokEntryWhen $Entry)) }
            elseif ($mode -eq 'local') { 'Chờ đăng lúc ' + (Format-TikTokClock ([string]$Entry.planned_for)) }
            else { 'Đang chờ đăng' }
        }
        'running' { if ($mode -eq 'native') { 'Đang gửi lên TikTok · hẹn ' + (Format-TikTokClock (Get-TikTokEntryWhen $Entry)) } else { 'Đang đăng…' } }
        'pending_ext' { 'Chờ Chrome' + $(if ($mode -eq 'native') { ' · hẹn ' + (Format-TikTokClock (Get-TikTokEntryWhen $Entry)) } else { '' }) }
        'waiting_ext' { 'Chrome đang đăng' + $(if ($mode -eq 'native') { ' · hẹn ' + (Format-TikTokClock (Get-TikTokEntryWhen $Entry)) } else { '…' }) }
        'preparing' { 'Đang chuyển video' }
        'preparation_failed' { 'Chuẩn bị video thất bại' }
        'transfer_failed' { 'Chưa chuyển được sang bộ đăng nền' }
        'cancelled' { 'Đã hủy' }
        'missing' { 'Tác vụ đã bị xóa khỏi bảng điều khiển' }
        default { 'Đăng thất bại' }
    }
    if ($Entry.publish_uncertain) { $label = 'Chưa rõ kết quả · kiểm tra TikTok trước khi gửi lại' }
    elseif ($Entry.prior_uncertain) { $label += ' · Từng có lần chưa rõ kết quả' }
    if (Test-TikTokPriorVersion $Entry $FileSha256) { $label += ' (bản trước)' }
    if ($Entry.time_source -eq 'legacy_result_time') { $label += ' (mốc xử lý từ lịch sử cũ)' }
    return $label
}

function Get-TikTokEntryShort {
    param($Entry)
    if ($Entry.publish_uncertain) { return 'Chưa rõ kết quả' }
    $mode = Get-TikTokEntryMode $Entry
    $short = switch ([string]$Entry.status) {
        { $_ -in @('pending', 'queued') } {
            if ($mode -eq 'native') { "Chờ gửi hẹn`n" + (Format-TikTokClock (Get-TikTokEntryWhen $Entry)) }
            elseif ($mode -eq 'local') { "Chờ đăng lúc`n" + (Format-TikTokClock ([string]$Entry.planned_for)) }
            else { 'Đang chờ đăng' }
        }
        'running' { if ($mode -eq 'native') { "Đang gửi hẹn`n" + (Format-TikTokClock (Get-TikTokEntryWhen $Entry)) } else { 'Đang đăng…' } }
        'pending_ext' { 'Chờ Chrome' }
        'waiting_ext' { 'Chrome đang đăng' }
        'preparing' { 'Đang chuyển…' }
        'cancelled' { 'Đã hủy lịch' }
        'transfer_failed' { 'Chưa chuyển được' }
        'preparation_failed' { 'Chuẩn bị lỗi' }
        'missing' { 'Tác vụ đã xóa' }
        default { 'Đăng thất bại' }
    }
    return $short
}

function Get-TikTokHistoryPayload {
    param([string]$OutDir,[string]$FilePath='')
    $dir = Get-CanonicalPath $OutDir
    $payload = @{ out_dir = $dir; receipts = @(Get-TikTokReceiptViews $dir) }
    if ($FilePath) { $payload.file = @{ id = (Get-ReelId $FilePath); path = [IO.Path]::GetFullPath($FilePath) } }
    return $payload
}

function Add-TikTokLocalReceiptHistory {
    # Right after submit: show the new receipt in Kho immediately (it is replaced by the backend entry on the next sync).
    param([string]$OutDir, [string]$VideoId, [object[]]$Entries, $Record)
    $view = [pscustomobject]@{ RequestId = [string]$Record.RequestId; VideoId = [string]$Record.VideoId; Username = [string]$Record.Username; ScheduledFor = [string]$Record.ScheduledFor; Status = [string]$Record.Status; CreatedAt = [string]$Record.CreatedAt; LaunchedAt = [string]$Record.LaunchedAt; WorkerAlive = $true }
    if (Test-KhoIdReserved $OutDir $VideoId) { Write-FileLog "WARN Bỏ qua ghi lịch sử cục bộ cho #${VideoId}: đang có lần chuyển kho chưa hoàn tất."; return $false }
    # Short wait: this runs on the UI thread right after submit; the next sync pass writes it anyway.
    $localUpdate = Update-ReupMetadata -OutDir $OutDir -TimeoutMs 1500 -Change {
        param($meta)
        $old = $meta.PSObject.Properties[$VideoId]
        # S6: no NEW entry for a video whose -3 left this folder.
        if (-not $old -and -not [IO.File]::Exists((Get-KhoVideoPath $OutDir $VideoId))) { return $false }
        $history = @(Merge-TikTokVideoHistory $VideoId $Entries @($view) $(if ($old) { $old.Value } else { $null }))
        return [bool](Set-TikTokItemHistory $meta $VideoId $history '')
    }
    return [bool]$localUpdate.Changed
}

function Set-TikTokSyncStale {
    # R8: a failed sync keeps the stored state, shows a visible note in Kho and logs at most every 5 minutes.
    # -Root: the kho folder the message is about (one note per folder; the first non-empty one is shown).
    param([string]$Message, [Alias('Root')][string]$KhoRoot = '')
    if ($Message) { Write-FileLogLimited -Key 'tiktok-sync' -Text ('WARN TikTok sync: ' + $Message) -MinSeconds 300 }
    $sync = $script:tikTokSync
    if ($Message) { $sync.StaleRoots[$KhoRoot] = [string]$Message } else { $sync.StaleRoots.Remove($KhoRoot) }
    $combined = [string](@($sync.StaleRoots.Values | Where-Object { $_ }) | Select-Object -First 1)
    if ([string]$sync.Stale -eq $combined) { return }
    if ($sync.Stale -and -not $combined) { Write-FileLog 'TikTok sync: kết nối lại bình thường.' }
    $sync.Stale = $combined
    Update-GalleryCountText
}

function Update-GalleryCountText {
    if (-not $ui.TxtGalleryCount -or $null -eq $script:galleryCountBase) { return }
    if (-not $script:tikTokSync) { $ui.TxtGalleryCount.Text = [string]$script:galleryCountBase; return }
    $stale = [string]$script:tikTokSync.Stale
    $ui.TxtGalleryCount.Text = [string]$script:galleryCountBase + $(if ($stale) { ' · TikTok chưa cập nhật' } else { '' })
    $ui.TxtGalleryCount.ToolTip = $(if ($stale) { $stale } else { $null })
}

function Show-TikTokFailureToasts {
    # G9: one toast per failed request in this session.
    param([object[]]$Failures)
    $new = @($Failures | Where-Object { $_ -and -not $script:tikTokSync.Notified.ContainsKey([string]$_.RequestId) })
    foreach ($f in $new) { $script:tikTokSync.Notified[[string]$f.RequestId] = $true }
    if ($new.Count -eq 1) {
        $who = if ($new[0].Username) { ' (@' + $new[0].Username + ')' } else { '' }
        Show-Toast ("Reel #$($new[0].VideoId)$who chưa chuyển được sang bộ đăng nền. Mở Lịch sử đăng video để kiểm tra.") -Kind warning
    } elseif ($new.Count -gt 1) {
        Show-Toast "$($new.Count) video chưa chuyển được sang bộ đăng nền. Mở Lịch sử đăng video của từng video để kiểm tra." -Kind warning
    }
}

function Get-TikTokSyncDelay {
    # Pause after a full pass: 3x its duration, at least 4 s and at most 30 s (a first-run hash of the whole Kho
    # must not push the next pass minutes away).
    param([double]$ElapsedSeconds)
    return [Math]::Min(30.0, [Math]::Max(4.0, 3.0 * $ElapsedSeconds))
}

function Get-TikTokRootState {
    # Per kho folder: identity cache, input signature, file stamp, probe cursor and the fast pass bookkeeping (every folder has its own).
    param([Alias('Root')][string]$KhoRoot)
    $sync = $script:tikTokSync
    $state = $sync.Roots[$KhoRoot]
    if (-not $state) {
        $state = @{ IdentityCache = $null; InputSig = ''; FileStamp = ''; ProbeCursor = ''; NextAt = [DateTime]::MinValue
                    FastStamp = ''; FastActive = @(); FastCursor = ''; FastNextAt = [DateTime]::MinValue; FastWroteAt = [DateTime]::MinValue }
        $sync.Roots[$KhoRoot] = $state
    }
    return $state
}

function Invoke-TikTokFastTick {
    # Fast path (a pass starts every ~5 s): status of entries that are waiting/posting, independent of the full pass. One kho folder per
    # pass, round-robin. Returns $true when it started a pass in this tick.
    param([string[]]$Roots)
    $sync = $script:tikTokSync
    if ($sync.Fast) {
        if (-not $sync.Fast.Async.IsCompleted) { return $false }
        $task = $sync.Fast; $sync.Fast = $null
        $state = $sync.Roots[[string]$task.OutDir]
        # Start to start: a slow pass (large Kho) does not add a full 5 s wait on top of its own duration.
        if ($state) { $state.FastNextAt = [DateTime]::UtcNow.AddSeconds([Math]::Max(1.0, 5.0 - $task.Clock.Elapsed.TotalSeconds)) }
        try { $result = Complete-TikTokTask $task }
        catch { Write-FileLogLimited -Key 'tiktok-fast' -Text ('WARN TikTok fast status: ' + $_.Exception.Message) -MinSeconds 300; return $false }
        if (-not $state) { return $false }   # the folder is no longer a kho
        $state.FastStamp = [string]$result.Stamp; $state.FastActive = @($result.Active); $state.FastCursor = [string]$result.Cursor
        if ($result.Changed) { $state.FastWroteAt = [DateTime]::UtcNow; $script:khoAutoMoveWanted = $true; Update-Gallery }
        return $false
    }
    if ($sync.Paused -or -not @($Roots).Count) { return $false }
    $n = @($Roots).Count
    for ($k = 0; $k -lt $n; $k++) {
        $khoRoot = [string]@($Roots)[([int]$sync.FastRoot + $k) % $n]
        $state = Get-TikTokRootState $khoRoot
        if ([DateTime]::UtcNow -lt $state.FastNextAt) { continue }
        # Idle (nothing active, file unchanged): no task at all.
        $stamp = Get-FileStamp (Join-Path $khoRoot 'reup-status.json')
        if ($stamp -eq $state.FastStamp -and -not @($state.FastActive).Count) { $state.FastNextAt = [DateTime]::UtcNow.AddSeconds(5); continue }
        $sync.FastRoot = ([int]$sync.FastRoot + $k + 1) % $n
        $sync.Fast = Start-TikTokTask 'fast' @{ out_dir = $khoRoot; last_stamp = $state.FastStamp; active = @($state.FastActive); cursor = $state.FastCursor }
        $sync.Fast.OutDir = $khoRoot
        return $true
    }
    return $false
}

function Invoke-TikTokSyncStep {
    $sync = $script:tikTokSync
    $roots = @(Get-KhoRoots | Where-Object { [IO.Directory]::Exists($_) })
    $known = @{}; foreach ($r in @(Get-KhoRoots)) { $known[$r] = $true }
    foreach ($k in @($sync.Roots.Keys)) { if (-not $known.ContainsKey($k)) { $sync.Roots.Remove($k); $sync.StaleRoots.Remove($k) } }
    # At most one pass starts per tick: opening a runspace costs the UI thread, so two in one tick add up.
    $startedFast = Invoke-TikTokFastTick $roots
    if ($sync.Task) {
        if (-not $sync.Task.Async.IsCompleted) { return }
        $task = $sync.Task; $sync.Task = $null
        $elapsed = $task.Clock.Elapsed.TotalSeconds
        $state = $sync.Roots[[string]$task.OutDir]
        if ($state) { $state.NextAt = [DateTime]::UtcNow.AddSeconds((Get-TikTokSyncDelay $elapsed)) }
        try { $result = Complete-TikTokTask $task }
        catch { Set-TikTokSyncStale ('Lỗi đồng bộ: ' + $_.Exception.Message) ([string]$task.OutDir); return }
        if (-not $state) { return }
        if ($result.IdentityCache -is [hashtable]) { $state.IdentityCache = $result.IdentityCache }
        $state.InputSig = [string]$result.InputSig; $state.FileStamp = [string]$result.FileStamp; $state.ProbeCursor = [string]$result.ProbeCursor
        Set-TikTokSyncStale ([string]$result.Stale) ([string]$task.OutDir)
        Show-TikTokFailureToasts @($result.Failures)
        if ($result.Changed) {
            # The full pass read the backend before a fast write landed: it may have written an older status.
            # Ask the fast path again right away instead of showing it until the next full pass.
            if ($state.FastWroteAt -gt $task.StartedAt) { $state.FastStamp = ''; $state.FastNextAt = [DateTime]::MinValue }
            $script:khoAutoMoveWanted = $true
            Update-Gallery
        }
        return
    }
    if ($sync.Paused -or $startedFast -or -not $roots.Count) { return }
    $due = @($roots | ForEach-Object { @{ Root = $_; At = (Get-TikTokRootState $_).NextAt } } | Where-Object { [DateTime]::UtcNow -ge $_.At } | Sort-Object { $_.At })
    if (-not $due.Count) { return }
    $khoRoot = [string]$due[0].Root
    $state = Get-TikTokRootState $khoRoot
    Remove-TikTokStaleCleanFiles $khoRoot
    $payload = Get-TikTokHistoryPayload $khoRoot
    $payload.identity_cache = $state.IdentityCache; $payload.last_input_sig = $state.InputSig; $payload.last_file_stamp = $state.FileStamp; $payload.probe_cursor = [string]$state.ProbeCursor
    $sync.Task = Start-TikTokTask 'sync' $payload
    $sync.Task.OutDir = $khoRoot; $sync.Task.StartedAt = [DateTime]::UtcNow
}

function Invoke-TikTokSyncTick {
    # One 1 s tick: the sync step, then (when no pass is running or paused) the auto-move of newly confirmed videos.
    $sync = $script:tikTokSync
    Invoke-TikTokSyncStep
    $busyNow = [bool](Test-KhoQuiet)
    if ($script:khoAutoMoveDeferred -and $script:khoWasBusy -and -not $busyNow) { $script:khoAutoMoveDeferred = $false; $script:khoAutoMoveWanted = $true }
    $script:khoWasBusy = $busyNow
    if ($script:khoAutoMoveWanted -and -not $sync.Paused -and -not $sync.Task -and -not $sync.Fast -and -not $script:khoMoveRunning) {
        try { [void](Invoke-KhoAutoMoveNow) } catch { Write-FileLogLimited -Key 'kho-automove' -Text ('WARN Tự chuyển kho: ' + $_.Exception.Message) -MinSeconds 300 }
    }
}

function Get-GalleryMetaByRoot {
    # Fresh read of reup-status.json of every kho folder (canonical folder -> metadata). A folder that cannot be read is left out
    # and logged: callers treat it as "nothing known", never as empty history. -Skip: folders that are not read at all.
    # -Unreadable: optional List[string] that receives every folder whose history could not be read (completeness info for scheduling).
    param($Skip = $null, $Unreadable = $null)
    $map = @{}
    foreach ($r in @(Get-KhoRoots)) {
        if ($Skip -and $Skip.Contains([string]$r)) { continue }
        if (-not [IO.Directory]::Exists($r)) { continue }
        try { $map[$r] = Get-ReupMetadata -OutDir $r }
        catch { Write-FileLog "WARN Không đọc được lịch sử của kho '$r': $($_.Exception.Message)"; if ($null -ne $Unreadable) { $Unreadable.Add([string]$r) } }
    }
    return $map
}

function Get-KhoHistoryGapText {
    # '' when every folder was read, otherwise the visible message that blocks automatic slot choice (a hidden booking may exist there).
    param([string[]]$Unreadable)
    $roots = @($Unreadable | Where-Object { $_ })
    if (-not $roots.Count) { return '' }
    $names = @($roots | ForEach-Object { $root = $_; $lib = @(Get-KhoList | Where-Object { Test-SamePath ([string]$_.path) $root }) | Select-Object -First 1; $(if ($lib) { [string]$lib.name } else { $root }) })
    return "Chưa đọc được lịch sử kho '$($names -join "', '")'; thử lại."
}

function Get-GalleryMetaChecked {
    # @{ Map; Gap }: the per-folder history map plus the gap message ('' = complete).
    $unreadable = New-Object 'System.Collections.Generic.List[string]'
    try { $map = Get-GalleryMetaByRoot -Unreadable $unreadable }
    catch { Write-FileLog ('WARN Đọc lịch sử các kho: ' + $_.Exception.Message); return @{ Map = @{}; Gap = 'Chưa đọc được lịch sử các kho; thử lại.' } }
    return @{ Map = $map; Gap = (Get-KhoHistoryGapText $unreadable.ToArray()) }
}

function Invoke-KhoAutoMoveNow {
    # Reads every kho's history and moves newly confirmed videos into their account kho; refreshes the gallery and tells the owner.
    # Cheap checks first (no reup-status.json read): not quiet -> deferred; folders reserved by a stuck journal are left out.
    if (-not $script:khoRegistryReady) { $script:khoAutoMoveWanted = $false; return 0 }
    if (Test-KhoQuiet) { $script:khoAutoMoveWanted = $false; $script:khoAutoMoveDeferred = $true; return 0 }
    $blocked = Get-KhoBlockedRoots
    if ($null -eq $blocked) { $script:khoAutoMoveWanted = $false; Write-FileLogLimited -Key 'kho-automove-journal' -Text 'WARN Tự chuyển kho tạm dừng: có nhật ký chuyển kho không đọc được (Quản lý kho › Bỏ qua).' -MinSeconds 300; return 0 }
    $meta = Get-GalleryMetaByRoot -Skip $blocked
    $moved = Invoke-KhoAutoMove $meta
    if ($moved -gt 0) {
        Show-Toast ("Đã chuyển $moved video vào kho theo tài khoản đã đăng.") -Kind success
        Update-Gallery
    }
    return $moved
}

function Start-TikTokStatusSync {
    if (-not (Test-TikTokEnabled)) { return }
    $script:tikTokSync = @{ Task = $null; Fast = $null; Roots = @{}; Notified = @{}; Stale = ''; StaleRoots = @{}; FastRoot = 0; Paused = $false }
    $script:khoAutoMoveWanted = $true
    # 1 s ticks: an idle tick only compares times and one file stamp per kho; the passes themselves run off the UI thread.
    $script:tikTokSyncTimer = New-Object Windows.Threading.DispatcherTimer
    $script:tikTokSyncTimer.Interval = [TimeSpan]::FromSeconds(1)
    $script:tikTokSyncTimer.Add_Tick({
        try { Invoke-TikTokSyncTick }
        catch { Set-TikTokSyncStale ('Lỗi đồng bộ: ' + $_.Exception.Message) }
    })
    $script:tikTokSyncTimer.Start()
}

function Find-TikTokTool {
    # Same places the app looks for FFmpeg (tools\ffmpeg, tools\ffmpeg\bin, tools, then PATH).
    param([string]$Name, [Alias('Root')][string]$AppRoot)
    foreach ($sub in @("tools\ffmpeg\$Name.exe", "tools\ffmpeg\bin\$Name.exe", "tools\$Name.exe")) {
        $candidate = Join-Path $AppRoot $sub
        if ([IO.File]::Exists($candidate)) { return $candidate }
    }
    $command = Get-Command $Name -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($command) { return [string]$command.Source }
    return ''
}

function ConvertTo-TikTokArgument {
    # Windows command-line quoting for one argument (paths may contain spaces, [] and Vietnamese).
    param([string]$Value)
    if ($Value -ne '' -and $Value -notmatch '[\s"]') { return $Value }
    $text = New-Object System.Text.StringBuilder
    [void]$text.Append('"'); $slashes = 0
    foreach ($ch in $Value.ToCharArray()) {
        if ($ch -eq '\') { $slashes++; continue }
        if ($ch -eq '"') { [void]$text.Append('\' * ($slashes * 2 + 1)).Append('"') } else { [void]$text.Append('\' * $slashes).Append($ch) }
        $slashes = 0
    }
    [void]$text.Append('\' * ($slashes * 2)).Append('"')
    return $text.ToString()
}

function Invoke-TikTokTool {
    param([string]$Exe, [string[]]$Arguments, [int]$TimeoutMs = 600000)
    $info = [Diagnostics.ProcessStartInfo]::new($Exe)
    $info.Arguments = (@($Arguments | ForEach-Object { ConvertTo-TikTokArgument $_ }) -join ' ')
    $info.UseShellExecute = $false; $info.CreateNoWindow = $true
    $info.RedirectStandardOutput = $true; $info.RedirectStandardError = $true
    $info.StandardOutputEncoding = [Text.Encoding]::UTF8; $info.StandardErrorEncoding = [Text.Encoding]::UTF8
    $process = [Diagnostics.Process]::Start($info)
    try {
        $out = $process.StandardOutput.ReadToEndAsync(); $err = $process.StandardError.ReadToEndAsync()
        if (-not $process.WaitForExit($TimeoutMs)) { try { $process.Kill() } catch { <# already exited #> }; throw ([IO.Path]::GetFileName($Exe) + ' quá thời gian.') }
        $process.WaitForExit()
        return @{ Code = $process.ExitCode; Out = $out.Result; Err = $err.Result }
    } finally { $process.Dispose() }
}

function Get-TikTokWireReelId {
    # reel_id gửi cho bộ đăng nền: ID số của video do app tạo; video ngoài KHÔNG gửi reel_id (lịch sử khớp theo sha256 của file).
    param([string]$Key)
    if ($Key -match '^\d+$') { return $Key }
    return ''
}

function Get-TikTokVideoStreamIndex {
    # ffprobe stream index of the video the clean copy works on: the first video stream that is not an attached cover picture. -1 = none.
    # Planning, ffmpeg mapping and frame/keyframe verification all use this one choice.
    param($Info)
    $streams = @($Info.streams | Where-Object { $_ })
    for ($i = 0; $i -lt $streams.Count; $i++) {
        $s = $streams[$i]
        if ($s.codec_type -ne 'video' -or [string]$s.disposition.attached_pic -eq '1') { continue }
        $n = 0
        if ($s.PSObject.Properties['index'] -and [int]::TryParse([string]$s.index, [ref]$n)) { return $n }
        return $i
    }
    return -1
}

function Get-TikTokCleanPlan {
    # Chọn cách tạo bản sạch từ kết quả ffprobe (đã ConvertFrom-Json): 'copy' (đóng gói lại, không mã hóa lại) khi hình H.264/HEVC và âm AAC hoặc không có âm;
    # 'audio' (giữ hình, mã hóa lại âm sang AAC) khi hình H.264/HEVC nhưng âm khác AAC; 'video' (H.264 + AAC) khi hình là codec khác; 'none' khi không có luồng hình.
    param($Info)
    $streams = @($Info.streams | Where-Object { $_ })
    $videoIndex = Get-TikTokVideoStreamIndex $Info
    if ($videoIndex -lt 0) { return 'none' }
    $video = @($streams | Where-Object { $_.codec_type -eq 'video' -and [string]$_.disposition.attached_pic -ne '1' })
    $vcodec = ([string]$video[0].codec_name).ToLowerInvariant()
    if ($vcodec -notin @('h264', 'avc', 'avc1', 'hevc', 'h265')) { return 'video' }
    $audio = @($streams | Where-Object { $_.codec_type -eq 'audio' })
    if (-not $audio.Count) { return 'copy' }
    if (([string]$audio[0].codec_name).ToLowerInvariant() -eq 'aac') { return 'copy' }
    return 'audio'
}

function Get-TikTokCleanArgs {
    # Keep in sync with Get-CleanOutputArgs in core\kid-fby.ps1 (the engine is not loaded in this process).
    param([string]$Codec)
    $list = @('-map_metadata','-1','-map_chapters','-1','-fflags','+bitexact','-flags:v','+bitexact','-flags:a','+bitexact',
              '-metadata:s:v','handler_name=','-metadata:s:a','handler_name=','-metadata:s:v','encoder=')
    if ($Codec -match '^(h264|avc)') { $list += @('-bsf:v','filter_units=remove_types=6') }
    elseif ($Codec -match '^(hevc|h265)') { $list += @('-bsf:v','filter_units=remove_types=39|40') }
    return $list
}

function Get-TikTokMediaInfo {
    param([string]$Ffprobe, [string]$Path)
    $probe = Invoke-TikTokTool $Ffprobe @('-v','error','-show_format','-show_streams','-show_chapters','-of','json',$Path) 120000
    if ($probe.Code -ne 0) { throw ('ffprobe lỗi: ' + $probe.Err.Trim()) }
    return ($probe.Out | ConvertFrom-Json)
}

function Get-TikTokVideoCounts {
    # Keyframe packets and decoded frames of one video stream (-Stream: ffprobe stream specifier; the clean copy holds only the chosen video, so
    # 'v:0' there, while the source passes the planned stream index). Stripping SEI from an open-GOP stream can drop
    # keyframe flags (recovery-point SEI) or leading frames (stream starting with a non-IDR I frame).
    param([string]$Ffprobe, [string]$Path, [string]$Stream = 'v:0')
    $packets = Invoke-TikTokTool $Ffprobe @('-v','error','-select_streams',$Stream,'-show_entries','packet=flags','-of','csv=p=0',$Path) 600000
    $frames = Invoke-TikTokTool $Ffprobe @('-v','error','-select_streams',$Stream,'-count_frames','-show_entries','stream=nb_read_frames','-of','csv=p=0',$Path) 1800000
    if ($packets.Code -ne 0 -or $frames.Code -ne 0) { throw ('ffprobe lỗi: ' + ($packets.Err + ' ' + $frames.Err).Trim()) }
    $count = 0
    # The line can carry side data too (e.g. rotation gives '180,'): take the first number.
    $number = [regex]::Match([string]$frames.Out, '\d+')
    if (-not $number.Success -or -not [int]::TryParse($number.Value, [ref]$count)) { throw ('ffprobe không đếm được khung hình: ' + ([string]$frames.Out).Trim()) }
    return @{ Keys = @(([string]$packets.Out -split "`r?`n") | Where-Object { $_ -cmatch '^K' }).Count; Frames = $count }
}

function Test-TikTokCleanFile {
    # Gate before upload: no identifying tags, no chapters, no encoder/source strings in the bytes, decodes cleanly,
    # same duration as the source and (with -SourceCounts) the same decoded frames and, for a stream copy, keyframes.
    # Returns @{ Ok; Reason; EncoderBytesOnly; VideoFixable } (VideoFixable: re-encoding the video can fix every problem).
    param([string]$Ffmpeg, [string]$Ffprobe, [string]$Path, [double]$SourceDuration, $SourceCounts = $null, [switch]$VideoReencoded)
    $info = Get-TikTokMediaInfo $Ffprobe $Path
    $problems = New-Object System.Collections.Generic.List[string]
    $fixable = $true
    foreach ($p in @($info.format.tags.PSObject.Properties)) {
        if ($p -and $p.Name -notin @('major_brand','minor_version','compatible_brands')) { $problems.Add('format tag ' + $p.Name); $fixable = $false }
    }
    $streams = @($info.streams | Where-Object { $_ })
    foreach ($s in $streams) {
        if ($s.codec_type -notin @('video','audio')) { $problems.Add('extra stream ' + $s.codec_type); $fixable = $false }
        foreach ($p in @($s.tags.PSObject.Properties)) {
            if (-not $p) { continue }
            if ($p.Name -eq 'language') { continue }
            if ($p.Name -eq 'handler_name' -and [string]$p.Value -in @('VideoHandler','SoundHandler')) { continue }
            if ($p.Name -eq 'vendor_id' -and [string]$p.Value -eq '[0][0][0][0]') { continue }
            $problems.Add('stream tag ' + $p.Name + '=' + [string]$p.Value); $fixable = $false
        }
    }
    if (@($info.chapters | Where-Object { $_ }).Count) { $problems.Add('chapters'); $fixable = $false }
    # Signature-shaped patterns: bare 4-letter strings occur by chance in compressed data of large files.
    $pattern = [regex]::new('(?i)(lav[fc]\d{1,3}\.\d{1,3}\.\d{1,3})|(x26[45] - core|x265 \(build|x264 core|x265 core)|(facebook)')
    $hits = New-Object System.Collections.Generic.List[string]
    $latin = [Text.Encoding]::GetEncoding(28591)
    $stream = [IO.File]::Open($Path, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read)
    try {
        $buffer = New-Object byte[] (4MB); $tail = ''
        while (($read = $stream.Read($buffer, 0, $buffer.Length)) -gt 0) {
            $text = $tail + $latin.GetString($buffer, 0, $read)
            foreach ($m in $pattern.Matches($text)) { if (-not $hits.Contains($m.Value.ToLowerInvariant())) { $hits.Add($m.Value.ToLowerInvariant()) } }
            $tail = if ($text.Length -gt 64) { $text.Substring($text.Length - 64) } else { $text }
        }
    } finally { $stream.Dispose() }
    $encoderOnly = ($hits.Count -gt 0 -and -not @($hits | Where-Object { $_ -notmatch '^lav[fc]' }).Count)
    foreach ($h in $hits) { $problems.Add('bytes ' + $h) }
    if (-not $problems.Count) {
        $decode = Invoke-TikTokTool $Ffmpeg @('-hide_banner','-nostdin','-v','error','-i',$Path,'-f','null','-') 1800000
        if ($decode.Code -ne 0 -or $decode.Err.Trim()) { $problems.Add('decode: ' + $decode.Err.Trim()); $fixable = $false }
        $duration = 0.0; [void][double]::TryParse([string]$info.format.duration, [Globalization.NumberStyles]::Float, [Globalization.CultureInfo]::InvariantCulture, [ref]$duration)
        if ([Math]::Abs($duration - $SourceDuration) -gt 0.05) { $problems.Add(('duration {0:0.000} vs {1:0.000}' -f $duration, $SourceDuration)) }
        if ($SourceCounts) {
            $counts = Get-TikTokVideoCounts $Ffprobe $Path
            if ($counts.Frames -ne $SourceCounts.Frames) { $problems.Add(('decoded frames {0} vs source {1}' -f $counts.Frames, $SourceCounts.Frames)) }
            if (-not $VideoReencoded -and $counts.Keys -ne $SourceCounts.Keys) { $problems.Add(('keyframes {0} vs source {1}' -f $counts.Keys, $SourceCounts.Keys)) }
            if ($VideoReencoded -and $counts.Keys -lt 1) { $problems.Add('no keyframe'); $fixable = $false }
        }
    }
    return @{ Ok = (-not $problems.Count); Reason = ($problems -join '; '); EncoderBytesOnly = $encoderOnly; VideoFixable = ($fixable -and $problems.Count -gt 0) }
}

function New-TikTokCleanCopy {
    # Every TikTok upload is a metadata-clean copy of the -3 file (also for files made before the engine cleaned them).
    # Tries a stream copy first; an encoder string only in the audio -> re-encode audio; broken keyframes/frames after
    # SEI stripping or encoder strings in the video (e.g. x265 info in hvcC) -> re-encode the video to H.264 with the
    # engine's libx264 settings (Get-VideoEncoderArgs in core\kid-fby.ps1). Throws when no attempt passes the gate.
    param([string]$SourcePath, [string]$PostsDir, [string]$RequestId, [Alias('Root')][string]$AppRoot)
    $ffmpeg = Find-TikTokTool 'ffmpeg' $AppRoot; $ffprobe = Find-TikTokTool 'ffprobe' $AppRoot
    if (-not $ffmpeg -or -not $ffprobe) { throw 'Không tìm thấy FFmpeg/FFprobe.' }
    $size = [IO.FileInfo]::new($SourcePath).Length
    try {
        $free = [IO.DriveInfo]::new([IO.Path]::GetPathRoot([IO.Path]::GetFullPath($PostsDir))).AvailableFreeSpace
        if ($free -lt $size + 64MB) { throw ('Không đủ dung lượng trống để làm sạch video (cần khoảng ' + [Math]::Ceiling(($size + 64MB) / 1MB) + ' MB).') }
    } catch [ArgumentException] { <# UNC or unknown drive: copy anyway, ffmpeg reports a full disk #> }
    try { $source = Get-TikTokMediaInfo $ffprobe $SourcePath }
    catch { throw ('Không đọc được thông tin video bằng ffprobe (file hỏng hoặc không phải video?). ' + $_.Exception.Message) }
    $plan = Get-TikTokCleanPlan $source
    if ($plan -eq 'none') { throw 'File này không có hình ảnh nên không đăng được lên TikTok.' }
    $videoIndex = Get-TikTokVideoStreamIndex $source
    $codec = [string](@($source.streams | Where-Object { $_.codec_type -eq 'video' -and [string]$_.disposition.attached_pic -ne '1' })[0].codec_name)
    $sourceDuration = 0.0; [void][double]::TryParse([string]$source.format.duration, [Globalization.NumberStyles]::Float, [Globalization.CultureInfo]::InvariantCulture, [ref]$sourceDuration)
    $sourceCounts = Get-TikTokVideoCounts $ffprobe $SourcePath ([string]$videoIndex)
    $clean = Join-Path $PostsDir ($RequestId + '.clean.mp4')
    $temp = Join-Path $PostsDir ($RequestId + '.clean-tmp.mp4')
    $last = ''
    $mode = $plan   # copy | audio | video
    while ($mode) {
        foreach ($p in @($temp, $clean)) { if ([IO.File]::Exists($p)) { [IO.File]::Delete($p) } }
        $codecArgs = switch ($mode) {
            'copy' { @('-c','copy') + (Get-TikTokCleanArgs $codec) }
            'audio' { @('-c:v','copy','-c:a','aac','-b:a','192k') + (Get-TikTokCleanArgs $codec) }
            # Same as Get-VideoEncoderArgs 'libx264' in core\kid-fby.ps1; passthrough keeps every source frame (no dup/drop).
            default { @('-c:v','libx264','-crf','19','-preset','medium','-profile:v','high','-pix_fmt','yuv420p','-fps_mode','passthrough','-c:a','aac','-b:a','192k') + (Get-TikTokCleanArgs 'h264') }
        }
        $arguments = @('-hide_banner','-nostdin','-v','error','-y','-i',$SourcePath,'-map',('0:' + $videoIndex),'-map','0:a:0?') + $codecArgs + @('-movflags','+faststart',$temp)
        $run = Invoke-TikTokTool $ffmpeg $arguments 3600000
        if ($run.Code -ne 0 -or -not [IO.File]::Exists($temp)) { $last = 'ffmpeg: ' + $run.Err.Trim(); break }
        [IO.File]::Move($temp, $clean)
        $gate = Test-TikTokCleanFile $ffmpeg $ffprobe $clean $sourceDuration -SourceCounts $sourceCounts -VideoReencoded:($mode -eq 'video')
        if ($gate.Ok) { return $clean }
        $last = $gate.Reason
        $next = ''
        if ($mode -eq 'copy' -and $gate.EncoderBytesOnly) { $next = 'audio' }
        elseif ($mode -ne 'video' -and $gate.VideoFixable) { $next = 'video' }
        $mode = $next
    }
    foreach ($p in @($temp, $clean)) { if ([IO.File]::Exists($p)) { [IO.File]::Delete($p) } }
    throw ('Làm sạch metadata không đạt: ' + $last)
}

function Remove-TikTokStaleCleanFiles {
    # Clean copies/temp files left by a worker that died (its lock is gone). Live workers are never touched.
    param([string]$OutDir)
    $dir = Join-Path $OutDir '.cache\tiktok-posts'
    if (-not [IO.Directory]::Exists($dir)) { return }
    foreach ($file in [IO.DirectoryInfo]::new($dir).GetFiles('*.clean*.mp4')) {
        if ($file.Name -notmatch '^([a-f0-9]{32})\.clean(-tmp)?\.mp4$') { continue }
        if (Test-TikTokWorkerAlive $OutDir $Matches[1]) { continue }
        try { $file.Delete() } catch { Write-FileLog "WARN TikTok stale clean file '$($file.Name)': $($_.Exception.Message)" }
    }
}

function Start-TikTokJobProcess {
    param([string]$JobFile, [switch]$PassThru)
    $process = (Start-Process powershell.exe -ArgumentList @('-NoProfile','-STA','-ExecutionPolicy','Bypass','-File',('"'+$scriptPath+'"'),'-TikTokJobFile',('"'+$JobFile+'"')) -WindowStyle Hidden -PassThru)
    if ($PassThru) { return $process }
}

function Set-TikTokReceiptFailed {
    param($Record, [string]$Message)
    $Record.Status = 'transfer_failed'; $Record.Message = $Message
    try { Save-TikTokReceipt $Record } catch { Write-FileLog "WARN TikTok receipt $($Record.RequestId): $($_.Exception.Message)" }
}

function Start-TikTokBackgroundJob {
    # Throws only when no background process was started, so the caller may let the user submit again.
    # -PassThru: returns the child process (the serial "Rải lịch" runner starts the next job only after it exits).
    param($Record,$Payload,[switch]$PassThru)
    $jobFile=Join-Path (Join-Path $Record.OutDir '.cache\tiktok-posts') ($Record.RequestId+'.job')
    Save-TikTokReceipt $Record
    try{
        $bytes=[Text.UTF8Encoding]::new($false).GetBytes((@{Record=$Record;Payload=$Payload;Endpoint=(Get-TikTokEndpoint)} | ConvertTo-Json -Depth 8))
        $stream=[IO.File]::Open($jobFile,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::None)
        try{$stream.Write($bytes,0,$bytes.Length);$stream.Flush($true)}finally{$stream.Dispose()}
    }catch{
        try{if([IO.File]::Exists($jobFile)){[IO.File]::Delete($jobFile)}}catch{Write-FileLog "WARN TikTok job file cleanup: $($_.Exception.Message)"}
        Set-TikTokReceiptFailed $Record 'Không tạo được tệp tác vụ nền.'
        throw
    }
    try{ $process=Start-TikTokJobProcess $jobFile -PassThru }
    catch{
        try{[IO.File]::Delete($jobFile)}catch{Write-FileLog "WARN TikTok job file cleanup: $($_.Exception.Message)"}
        Set-TikTokReceiptFailed $Record 'Không khởi chạy được tác vụ nền.'
        throw
    }
    if($PassThru){return $process}
}

function Restart-TikTokTransfer {
    # "Thử chuyển lại" (G3/R2): re-runs the SAME .job, so the backend sees the same request_id and replays, never duplicates.
    param([string]$OutDir, [string]$RequestId)
    if ($script:khoMoveRunning) { throw 'Đang chuyển kho. Thử lại sau.' }
    if ($RequestId -notmatch '^[a-f0-9]{32}$') { throw 'Mã yêu cầu không hợp lệ.' }
    $dir = Join-Path (Get-CanonicalPath $OutDir) '.cache\tiktok-posts'
    $jobFile = Join-Path $dir ($RequestId + '.job')
    if (-not [IO.File]::Exists($jobFile)) { throw 'Không còn tệp tác vụ để thử lại. Nếu cần, hãy đăng lại thành bài mới.' }
    if (Test-TikTokWorkerAlive $OutDir $RequestId) { throw 'Video này đang được chuyển. Đợi một chút rồi bấm Làm mới.' }
    $record = [IO.File]::ReadAllText((Join-Path $dir ($RequestId + '.json'))) | ConvertFrom-Json -ErrorAction Stop
    Remove-TikTokStaleCleanFiles $OutDir
    Set-ReupField $record 'Status' 'submitted'
    Set-ReupField $record 'Message' ''
    Set-ReupField $record 'LaunchedAt' ([DateTime]::UtcNow.ToString('o'))
    Save-TikTokReceipt $record
    Start-TikTokJobProcess $jobFile
}

function Move-TikTokReceiptToArchive {
    # "Bỏ biên nhận" (G3): rename, never delete, so the receipt stays inspectable/recoverable.
    param([string]$OutDir, [string]$RequestId)
    if ($script:khoMoveRunning) { throw 'Đang chuyển kho. Thử lại sau.' }
    if ($RequestId -notmatch '^[a-f0-9]{32}$') { throw 'Mã yêu cầu không hợp lệ.' }
    if (Test-TikTokWorkerAlive $OutDir $RequestId) { throw 'Video này đang được chuyển. Đợi một chút rồi bấm Làm mới.' }
    $dir = Join-Path (Get-CanonicalPath $OutDir) '.cache\tiktok-posts'
    $suffix = '.archived-' + (Get-Date).ToString('yyyyMMdd-HHmmss')
    Remove-TikTokStaleCleanFiles $OutDir
    # The .job goes first: once it is gone the request cannot be re-sent by mistake.
    foreach ($name in @(($RequestId + '.job'), ($RequestId + '.json'))) {
        $path = Join-Path $dir $name
        if ([IO.File]::Exists($path)) { [IO.File]::Move($path, $path + $suffix) }
    }
}

# ------------------------------------------------------------- hashtag hay dung cho TikTok (data\tiktok-hashtags.json) ----
function Get-TikTokHashtagPath { return (Join-Path $script:root 'data\tiktok-hashtags.json') }

function Get-TikTokHashtagsFromText {
    # Cac hashtag trong caption (Unicode: chu cai, dau to hop, so, gach duoi). Khong phan biet hoa thuong; giu cach viet dau tien.
    param([string]$Text)
    $seen = @{}; $list = New-Object 'System.Collections.Generic.List[string]'
    if ([string]::IsNullOrEmpty($Text)) { return $list.ToArray() }
    foreach ($m in [regex]::Matches($Text, '#([\p{L}\p{M}\p{N}_]{1,100})')) {
        $tag = $m.Value; $key = $tag.ToLowerInvariant()
        if (-not $seen.ContainsKey($key)) { $seen[$key] = 1; $list.Add($tag) }
    }
    return $list.ToArray()
}

function Read-TikTokHashtags {
    # Tra ve mang muc @{tag;count;lastUsed}. Thieu file -> rong. File hong -> doi ten .corrupt-<ts> roi coi nhu rong. Khong bao gio nem loi.
    # $Unreadable (tuy chon): dat $true khi file ton tai nhung khong doc duoc (khoa/IO) -> nguoi goi KHONG duoc ghi de.
    param([string]$Path = (Get-TikTokHashtagPath), [ref]$Unreadable)
    $result = New-Object 'System.Collections.Generic.List[object]'
    if ($null -ne $Unreadable) { $Unreadable.Value = $false }
    try {
        if (-not [System.IO.File]::Exists($Path)) { return $result.ToArray() }
        $json = $null; $readErr = $null
        for ($try = 1; $try -le 3; $try++) {
            try { $json = [System.IO.File]::ReadAllText($Path, [System.Text.Encoding]::UTF8); $readErr = $null; break }
            catch { $readErr = $_.Exception.Message; if ($try -lt 3) { Start-Sleep -Milliseconds 100 } }
        }
        if ($null -ne $readErr) {
            Write-FileLog "WARN Không đọc được hashtag đã lưu (đang bị khóa?), giữ nguyên file: $readErr"
            if ($null -ne $Unreadable) { $Unreadable.Value = $true }
            return $result.ToArray()
        }
        try {
            if ([string]::IsNullOrWhiteSpace($json) -or -not $json.TrimStart().StartsWith('{')) { throw 'Không phải đối tượng JSON.' }
            $obj = ConvertFrom-Json -InputObject $json -ErrorAction Stop
            if ($null -eq $obj -or $obj -isnot [pscustomobject] -or $null -eq $obj.PSObject.Properties['tags']) { throw 'Thiếu danh sách tags.' }
            $seen = @{}
            foreach ($t in @($obj.tags)) {
                $tag = if ($null -ne $t) { [string]$t.tag } else { '' }
                if ($tag -notmatch '^#[\p{L}\p{M}\p{N}_]{1,100}$') { continue }
                $key = $tag.ToLowerInvariant(); if ($seen.ContainsKey($key)) { continue }
                $seen[$key] = 1
                $count = 0; if (-not [int]::TryParse([string]$t.count, [ref]$count) -or $count -lt 1) { $count = 1 }
                # accounts (tuy chon, ban cu khong co): username viet thuong -> so lan dung.
                $acc = [ordered]@{}
                if ($null -ne $t.PSObject.Properties['accounts'] -and $t.accounts -is [pscustomobject]) {
                    foreach ($ap in $t.accounts.PSObject.Properties) { $n = 0; if ([int]::TryParse([string]$ap.Value, [ref]$n) -and $n -ge 1) { $acc[([string]$ap.Name).ToLowerInvariant()] = $n } }
                }
                $result.Add([pscustomobject]@{ tag = $tag; count = $count; lastUsed = [string]$t.lastUsed; accounts = $acc })
            }
        } catch {
            $err = $_.Exception.Message
            $bad = $Path + '.corrupt-' + (Get-Date).ToString('yyyyMMdd-HHmmss')
            if ([System.IO.File]::Exists($bad)) { $bad += '-' + [Guid]::NewGuid().ToString('N').Substring(0, 6) }
            try { [System.IO.File]::Move($Path, $bad); Write-FileLog "WARN File hashtag bị hỏng ($err); đã đổi tên thành '$bad'." }
            catch { Write-FileLog "WARN File hashtag bị hỏng ($err) và không đổi tên được: $($_.Exception.Message)" }
            $result.Clear()
        }
    } catch { Write-FileLog "WARN Đọc hashtag đã lưu lỗi: $($_.Exception.Message)"; $result.Clear() }
    return $result.ToArray()
}

function Save-TikTokHashtags {
    # Ghi nguyen tu (dung Write-KidSettings), toi da 300 muc: bo muc dung lau nhat.
    param([object[]]$Tags, [string]$Path = (Get-TikTokHashtagPath))
    $keep = @($Tags | Sort-Object -Property @{ Expression = { [string]$_.lastUsed }; Descending = $true }, @{ Expression = { [int]$_.count }; Descending = $true } | Select-Object -First 300)
    Write-KidSettings -Path $Path -Data ([ordered]@{ version = 1; tags = @($keep | ForEach-Object {
        $o = [ordered]@{ tag = [string]$_.tag; count = [int]$_.count; lastUsed = [string]$_.lastUsed }
        if ($null -ne $_.PSObject.Properties['accounts'] -and $_.accounts -and @($_.accounts.Keys).Count) { $o.accounts = $_.accounts }
        $o }) })
}

function Add-TikTokHashtagsFromCaption {
    # Hoc hashtag tu caption da dang: count++ va lastUsed = bay gio. Nguoi goi phai bat loi (khong duoc lam hong viec dang).
    param([string]$Caption, [string]$Path = (Get-TikTokHashtagPath), [string]$Account = '')
    $acct = ([string]$Account).Trim().TrimStart('@').ToLowerInvariant()
    $found = @(Get-TikTokHashtagsFromText $Caption)
    if (-not $found.Count) { return }
    $now = [DateTime]::UtcNow.ToString('o')
    $items = New-Object 'System.Collections.Generic.List[object]'; $index = @{}
    $unreadable = $false
    foreach ($e in @(Read-TikTokHashtags -Path $Path -Unreadable ([ref]$unreadable))) { $index[([string]$e.tag).ToLowerInvariant()] = $e; $items.Add($e) }
    foreach ($tag in $found) {
        $key = $tag.ToLowerInvariant()
        if ($index.ContainsKey($key)) { $e = $index[$key]; $e.count = [int]$e.count + 1; $e.lastUsed = $now }
        else { $e = [pscustomobject]@{ tag = $tag; count = 1; lastUsed = $now; accounts = [ordered]@{} }; $index[$key] = $e; $items.Add($e) }
        if ($acct) {
            if ($null -eq $e.PSObject.Properties['accounts'] -or $null -eq $e.accounts) { $e | Add-Member -NotePropertyName accounts -NotePropertyValue ([ordered]@{}) -Force }
            $e.accounts[$acct] = [int]$(if ($e.accounts.Contains($acct)) { $e.accounts[$acct] } else { 0 }) + 1
        }
    }
    if ($unreadable) { return }
    Save-TikTokHashtags -Tags $items.ToArray() -Path $Path
}

function Remove-TikTokHashtag {
    param([string]$Tag, [string]$Path = (Get-TikTokHashtagPath))
    $unreadable = $false
    $left = @(Read-TikTokHashtags -Path $Path -Unreadable ([ref]$unreadable) | Where-Object { ([string]$_.tag) -ine $Tag })
    if ($unreadable) { return }
    Save-TikTokHashtags -Tags $left -Path $Path
}

function Get-TikTokHashtagToken {
    # Hashtag dang go do tai con tro (vd "#xu|"): @{Start;End;Prefix} hoac $null. End mo rong qua cac ky tu hashtag sau con tro.
    param([string]$Text, [int]$Caret)
    if ($null -eq $Text) { $Text = '' }
    $Caret = [Math]::Max(0, [Math]::Min($Caret, $Text.Length))
    $m = [regex]::Match($Text.Substring(0, $Caret), '#([\p{L}\p{M}\p{N}_]*)$')
    if (-not $m.Success) { return $null }
    $end = $Caret
    while ($end -lt $Text.Length -and ([string]$Text[$end]) -match '^[\p{L}\p{M}\p{N}_]$') { $end++ }
    return @{ Start = $m.Index; End = $end; Prefix = $m.Groups[1].Value }
}

function Get-TikTokHashtagSuggestions {
    # Tag goi y (chuoi): bo tag da co trong caption, loc theo phan dang go, xep theo count giam roi lastUsed giam.
    param([object[]]$Tags, [string]$Text, [int]$Caret, [int]$Max = 20, [string]$Account = '')
    if ($null -eq $Text) { $Text = '' }
    $acct = ([string]$Account).Trim().TrimStart('@').ToLowerInvariant()
    # So lan tai khoan nay da dung tag; tag cua tai khoan xep truoc (theo so lan roi lastUsed), con lai xep theo count chung roi lastUsed.
    $accCount = { $n = 0; if ($acct -and $null -ne $_.PSObject.Properties['accounts'] -and $_.accounts -and $_.accounts.Contains($acct)) { $n = [int]$_.accounts[$acct] }; $n }
    $tok = Get-TikTokHashtagToken -Text $Text -Caret $Caret
    $rest = $Text; $prefix = ''
    if ($tok) { $rest = $Text.Remove($tok.Start, $tok.End - $tok.Start); $prefix = '#' + $tok.Prefix }
    $have = @{}; foreach ($t in @(Get-TikTokHashtagsFromText $rest)) { $have[$t.ToLowerInvariant()] = 1 }
    $pick = @($Tags | Where-Object { $null -ne $_ -and -not $have.ContainsKey(([string]$_.tag).ToLowerInvariant()) -and ($prefix.Length -le 1 -or ([string]$_.tag).StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase)) } |
        Sort-Object -Property @{ Expression = $accCount; Descending = $true }, @{ Expression = { if ((& $accCount) -gt 0) { 0 } else { [int]$_.count } }; Descending = $true }, @{ Expression = { [string]$_.lastUsed }; Descending = $true } | Select-Object -First $Max)
    return @($pick | ForEach-Object { [string]$_.tag })
}

function Add-TikTokHashtagToCaption {
    # Them tag vao caption: thay phan dang go tai con tro, neu khong thi them o cuoi (co dau cach dau). Reason: exists | toolong.
    param([string]$Text, [int]$Caret, [string]$Tag, [int]$MaxLength = 2200)
    if ($null -eq $Text) { $Text = '' }
    $tok = Get-TikTokHashtagToken -Text $Text -Caret $Caret
    $rest = $Text; if ($tok) { $rest = $Text.Remove($tok.Start, $tok.End - $tok.Start) }
    foreach ($t in @(Get-TikTokHashtagsFromText $rest)) {
        if ($t -ieq $Tag) { return [pscustomobject]@{ Ok = $false; Text = $Text; Caret = $Caret; Reason = 'exists' } }
    }
    if ($tok) { $new = $Text.Substring(0, $tok.Start) + $Tag + $Text.Substring($tok.End); $pos = $tok.Start + $Tag.Length }
    else {
        $sep = if ($Text.Length -eq 0 -or [char]::IsWhiteSpace($Text[$Text.Length - 1])) { '' } else { ' ' }
        $new = $Text + $sep + $Tag; $pos = $new.Length
    }
    if ($MaxLength -gt 0 -and $new.Length -gt $MaxLength) { return [pscustomobject]@{ Ok = $false; Text = $Text; Caret = $Caret; Reason = 'toolong' } }
    # Chen o cuoi caption: them dau cach de con tro khong dinh vao tag vua chen (neu khong se bi coi la dang go do tag do).
    if ($pos -eq $new.Length -and ($MaxLength -le 0 -or $new.Length -lt $MaxLength)) { $new += ' '; $pos++ }
    return [pscustomobject]@{ Ok = $true; Text = $new; Caret = $pos; Reason = '' }
}

function Get-TikTokPrefsPath { return (Join-Path $script:root 'data\tiktok-prefs.json') }

function Read-TikTokPrefs {
    # @{ lastAccount; times = @{ <user lower> = @{ 'HH:mm' = count } } }. Thieu file -> rong. Hong -> doi ten .corrupt-<ts> roi coi nhu rong.
    # $Unreadable: $true khi file ton tai nhung khong doc duoc (khoa) -> nguoi goi KHONG duoc ghi de. Khong bao gio nem loi.
    param([string]$Path = (Get-TikTokPrefsPath), [ref]$Unreadable)
    $prefs = @{ lastAccount = ''; times = @{} }
    if ($null -ne $Unreadable) { $Unreadable.Value = $false }
    try {
        if (-not [System.IO.File]::Exists($Path)) { return $prefs }
        $json = $null; $readErr = $null
        for ($try = 1; $try -le 3; $try++) {
            try { $json = [System.IO.File]::ReadAllText($Path, [System.Text.Encoding]::UTF8); $readErr = $null; break }
            catch { $readErr = $_.Exception.Message; if ($try -lt 3) { Start-Sleep -Milliseconds 100 } }
        }
        if ($null -ne $readErr) {
            Write-FileLog "WARN Không đọc được tiktok-prefs.json (đang bị khóa?), giữ nguyên file: $readErr"
            if ($null -ne $Unreadable) { $Unreadable.Value = $true }
            return $prefs
        }
        try {
            if ([string]::IsNullOrWhiteSpace($json) -or -not $json.TrimStart().StartsWith('{')) { throw 'Không phải đối tượng JSON.' }
            $obj = ConvertFrom-Json -InputObject $json -ErrorAction Stop
            if ($null -eq $obj -or $obj -isnot [pscustomobject]) { throw 'Không phải đối tượng JSON.' }
            $p = @{ lastAccount = ''; times = @{} }
            if ($null -ne $obj.PSObject.Properties['lastAccount']) { $p.lastAccount = ([string]$obj.lastAccount).Trim().TrimStart('@').ToLowerInvariant() }
            if ($null -ne $obj.PSObject.Properties['times'] -and $obj.times -is [pscustomobject]) {
                foreach ($u in $obj.times.PSObject.Properties) {
                    if ($u.Value -isnot [pscustomobject]) { continue }
                    $m = @{}
                    foreach ($tp in $u.Value.PSObject.Properties) {
                        $n = 0
                        if ($tp.Name -match '^([01]\d|2[0-3]):[0-5]\d$' -and [int]::TryParse([string]$tp.Value, [ref]$n) -and $n -ge 1) { $m[$tp.Name] = $n }
                    }
                    if ($m.Count) { $p.times[([string]$u.Name).ToLowerInvariant()] = $m }
                }
            }
            $prefs = $p
        } catch {
            $err = $_.Exception.Message
            $bad = $Path + '.corrupt-' + (Get-Date).ToString('yyyyMMdd-HHmmss')
            if ([System.IO.File]::Exists($bad)) { $bad += '-' + [Guid]::NewGuid().ToString('N').Substring(0, 6) }
            try { [System.IO.File]::Move($Path, $bad); Write-FileLog "WARN tiktok-prefs.json bị hỏng ($err); đã đổi tên thành '$bad'." }
            catch { Write-FileLog "WARN tiktok-prefs.json bị hỏng ($err) và không đổi tên được: $($_.Exception.Message)" }
            $prefs = @{ lastAccount = ''; times = @{} }
        }
    } catch { Write-FileLog "WARN Đọc tiktok-prefs.json lỗi: $($_.Exception.Message)" }
    return $prefs
}

function Save-TikTokPrefs {
    param($Prefs, [string]$Path = (Get-TikTokPrefsPath))
    $times = [ordered]@{}
    foreach ($u in @($Prefs.times.Keys | Sort-Object)) {
        $m = [ordered]@{}; foreach ($t in @($Prefs.times[$u].Keys | Sort-Object)) { $m[$t] = [int]$Prefs.times[$u][$t] }
        $times[$u] = $m
    }
    Write-KidSettings -Path $Path -Data ([ordered]@{ version = 1; lastAccount = [string]$Prefs.lastAccount; times = $times })
}

function Register-TikTokPrefsSubmit {
    # Sau khi giao viec dang thanh cong: nho tai khoan cuoi; neu hen gio thi them 1 vao times[user]['HH:mm']. Nguoi goi phai bat loi.
    param([string]$Username, [string]$Time = '', [string]$Path = (Get-TikTokPrefsPath))
    $u = ([string]$Username).Trim().TrimStart('@').ToLowerInvariant()
    if (-not $u) { return }
    $unreadable = $false
    $prefs = Read-TikTokPrefs -Path $Path -Unreadable ([ref]$unreadable)
    if ($unreadable) { return }
    $prefs.lastAccount = $u
    if ($Time -match '^([01]\d|2[0-3]):[0-5]\d$') {
        if (-not $prefs.times.ContainsKey($u)) { $prefs.times[$u] = @{} }
        $prefs.times[$u][$Time] = [int]$(if ($prefs.times[$u].ContainsKey($Time)) { $prefs.times[$u][$Time] } else { 0 }) + 1
    }
    Save-TikTokPrefs -Prefs $prefs -Path $Path
}

function Get-TikTokTimeChips {
    # Toi da 4 gio: hay dung nhat cua tai khoan (count giam, bang nhau thi gio som truoc), thieu thi bo sung 08:00/12:00/19:00/21:00; tra ve theo thu tu gio.
    param($Times, [int]$Count = 4)
    $fallback = @('08:00', '12:00', '19:00', '21:00')
    $pick = New-Object 'System.Collections.Generic.List[string]'
    if ($Times) {
        foreach ($k in @($Times.Keys | Sort-Object -Property @{ Expression = { [int]$Times[$_] }; Descending = $true }, @{ Expression = { [string]$_ }; Descending = $false })) {
            if ($pick.Count -lt $Count) { $pick.Add([string]$k) }
        }
    }
    foreach ($f in $fallback) { if ($pick.Count -lt $Count -and -not $pick.Contains($f)) { $pick.Add($f) } }
    return @($pick | Sort-Object)
}

function Get-TikTokCaptionTemplate {
    # Caption + hashtag mau cua kho dich (S10): kho gan voi tai khoan (truong account cua kho) neu co; neu khong thi kho khong-tai-khoan ma video
    # dang nam trong do (VideoKhoId = ma kho). '' neu khong co mau.
    param([string]$Account, [string]$VideoKhoId, [object[]]$Libraries)
    $u = ConvertTo-KhoUsername $Account
    $target = $null
    if ($u) { $target = @($Libraries | Where-Object { $_ -and [string]$_.account -and [string]::Equals([string]$_.account, $u, [StringComparison]::OrdinalIgnoreCase) }) | Select-Object -First 1 }
    if (-not $target -and $VideoKhoId) {
        $target = @($Libraries | Where-Object { $_ -and [string]$_.id -ceq $VideoKhoId -and -not [string]$_.account }) | Select-Object -First 1
    }
    if (-not $target) { return '' }
    $parts = New-Object 'System.Collections.Generic.List[string]'
    if (([string]$target.caption).Trim()) { $parts.Add(([string]$target.caption).Trim()) }
    foreach ($h in @($target.hashtags)) { $t = ([string]$h).Trim().TrimStart('#'); if ($t) { $parts.Add('#' + $t) } }
    return ($parts -join ' ')
}

function ConvertTo-TikTokLocalTime {
    # Chuoi ISO/UTC -> gio may; $null neu rong hoac khong doc duoc.
    param([string]$Value)
    if (-not $Value) { return $null }
    $o = [DateTimeOffset]::MinValue
    if ([DateTimeOffset]::TryParse($Value, [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::AssumeUniversal, [ref]$o)) { return $o.LocalDateTime }
    return $null
}

function Get-TikTokRepostWarning {
    # Bai da dang xac nhan (succeeded, khong publish_uncertain) tren tai khoan KHAC tai khoan dang chon: @{ Username; When(gio may) } hoac $null. Lay bai moi nhat.
    param([object[]]$Entries, [string]$Account)
    $u = ([string]$Account).Trim().TrimStart('@')
    $hit = @(@($Entries) | Where-Object { $_ -and [string]$_.status -eq 'succeeded' -and $_.publish_uncertain -ne $true -and [string]$_.username -and [string]$_.username -ine $u } |
        Sort-Object { Get-TikTokSortKey ([string]$_.accepted_at) } -Descending)
    if (-not $hit.Count) { return $null }
    return @{ Username = [string]$hit[0].username; When = (ConvertTo-TikTokLocalTime ([string]$hit[0].accepted_at)) }
}

function Get-TikTokBusyTimes {
    # Gio (gio may) cua cac muc DA HEN/DANG CHO cua tai khoan nay tren moi video trong $Metadata (MOT hoac NHIEU reup-status.json: moi thu muc kho mot cai)
    # va $ExtraEntries. Muc lich su co cung key (cung mot lan dang) chi tinh MOT lan: luc dang chuyen kho, lich su co the nam o hai thu muc.
    param($Metadata, [string]$Account, [DateTime]$Now = [DateTime]::Now, [object[]]$ExtraEntries = @())
    $u = ([string]$Account).Trim().TrimStart('@')
    $active = Get-TikTokActiveStatuses
    $all = New-Object 'System.Collections.Generic.List[object]'
    foreach ($m in @($Metadata)) { if ($m) { foreach ($p in $m.PSObject.Properties) { foreach ($h in @($p.Value.History)) { if ($h) { $all.Add($h) } } } } }
    foreach ($h in @($ExtraEntries)) { if ($h) { $all.Add($h) } }
    $seen = @{}
    $busy = New-Object 'System.Collections.Generic.List[DateTime]'
    foreach ($h in $all) {
        if (-not [string]$h.username -or [string]$h.username -ine $u) { continue }
        $key = [string]$h.key
        if ($key) { if ($seen.ContainsKey($key)) { continue }; $seen[$key] = $true }
        $t = ConvertTo-TikTokLocalTime ([string]$h.tiktok_schedule_time)
        if ($null -eq $t) { $t = ConvertTo-TikTokLocalTime ([string]$h.planned_for) }
        # Bai khong hen gio (dang ngay): tinh tai luc backend nhan (accepted_at), chua co thi luc tao.
        $immediate = $false
        if ($null -eq $t) { $t = ConvertTo-TikTokLocalTime ([string]$h.accepted_at); $immediate = $true }
        if ($null -eq $t) { $t = ConvertTo-TikTokLocalTime ([string]$h.created_at) }
        if ($null -eq $t) { continue }
        $st = [string]$h.status
        # Bai da/dang di trong HOM NAY (da qua gio) van tinh vao tran moi ngay va khoang cach; ngay cu thi bo.
        $today = ($t.Date -eq $Now.Date)
        if ($immediate) { if (($st -in $active -or $st -eq 'succeeded') -and $today) { $busy.Add($t) } }
        elseif ($st -in $active -or ($st -eq 'succeeded' -and ($t -gt $Now -or $today))) { $busy.Add($t) }
    }
    return $busy.ToArray()
}

function Get-TikTokAccountBusyTimes {
    # S7: gio ban cua mot tai khoan tren MOI kho (doc moi reup-status.json cua tung thu muc kho, hoac $MetaByRoot da co), loai trung theo key.
    param([string]$Account, [DateTime]$Now = [DateTime]::Now, [object[]]$ExtraEntries = @(), $MetaByRoot = $null)
    if ($null -eq $MetaByRoot) { $MetaByRoot = Get-GalleryMetaByRoot }
    return @(Get-TikTokBusyTimes -Metadata @($MetaByRoot.Values) -Account $Account -Now $Now -ExtraEntries $ExtraEntries)
}

function Get-NextFreeTikTokSlot {
    # Gio som nhat (gio may) trong cac gio yeu thich ('HH:mm') nam trong [Bounds.Min, Bounds.Max] va cach moi gio ban it nhat 60 phut; $null neu khong co.
    param([string[]]$Favorites, [DateTime[]]$Busy = @(), [DateTime]$Now = [DateTime]::Now, $Bounds = $null)
    if ($null -eq $Bounds) { $Bounds = Get-TikTokScheduleBounds $Now }
    $times = @(@($Favorites) | Where-Object { $_ -match '^([01]\d|2[0-3]):[0-5]\d$' } | Sort-Object -Unique)
    foreach ($d in 0..10) {
        $day = $Bounds.Min.Date.AddDays($d)
        foreach ($t in $times) {
            $slot = $day.AddHours([int]$t.Substring(0, 2)).AddMinutes([int]$t.Substring(3, 2))
            if ($slot -lt $Bounds.Min -or $slot -gt $Bounds.Max) { continue }
            $clash = $false
            foreach ($b in @($Busy)) { if ([Math]::Abs(($slot - $b).TotalMinutes) -lt 60) { $clash = $true; break } }
            if (-not $clash) { return $slot }
        }
    }
    return $null
}

# ------------------------------------------------------------- Rải lịch: nhiều video -> nhiều giờ hẹn (T4) ----
function Get-TikTokSpreadPlan {
    # Giờ hẹn (giờ máy) cho $Count video của MỘT tài khoản, tăng dần, MỖI KHUNG GIỜ MỘT VIDEO: đi từng ngày từ hôm nay qua các khung giờ ('HH:mm'; thiếu/không hợp lệ thì 08:00/12:00/19:00/21:00).
    # Bỏ giờ < +20 phút hoặc > +10 ngày (Bounds) và giờ cách một giờ bận (bài đã hẹn/đang chờ của tài khoản trên mọi kho) dưới 60 phút. Hết chỗ (quá 10 ngày) thì trả ít hơn $Count.
    param([int]$Count, [string[]]$Favorites = @(), [DateTime[]]$Busy = @(), [DateTime]$Now = [DateTime]::Now, $Bounds = $null)
    $plan = New-Object 'System.Collections.Generic.List[DateTime]'
    if ($Count -le 0) { return $plan.ToArray() }
    if ($null -eq $Bounds) { $Bounds = Get-TikTokScheduleBounds $Now }
    $times = @(@($Favorites) | Where-Object { $_ -match '^([01]\d|2[0-3]):[0-5]\d$' } | Sort-Object -Unique)
    if (-not $times.Count) { $times = @(Get-TikTokTimeChips $null) }
    for ($d = 0; $d -le 10 -and $plan.Count -lt $Count; $d++) {
        $day = $Now.Date.AddDays($d)
        foreach ($t in $times) {
            if ($plan.Count -ge $Count) { break }
            $slot = $day.AddHours([int]$t.Substring(0, 2)).AddMinutes([int]$t.Substring(3, 2))
            if ($slot -lt $Bounds.Min -or $slot -gt $Bounds.Max) { continue }
            $clash = $false
            foreach ($b in @($Busy)) { if ([Math]::Abs(($slot - $b).TotalMinutes) -lt 60) { $clash = $true; break } }
            if (-not $clash) { $plan.Add($slot) }
        }
    }
    return $plan.ToArray()
}

function Get-TikTokSpreadWarn {
    # Lịch sử đã lưu của 1 video (mọi tài khoản): 'active' (có lệnh đang chờ/chạy - luôn bỏ qua), 'posted' (đã đăng xác nhận hoặc đã hẹn thành công - mặc định bỏ qua), '' (trống).
    param([object[]]$History, [bool]$Posted = $false)
    $h = @(@($History) | Where-Object { $_ })
    if (@($h | Where-Object { [string]$_.status -in (Get-TikTokActiveStatuses) }).Count) { return 'active' }
    if (@($h | Where-Object { [string]$_.status -eq 'succeeded' -and $_.publish_uncertain -ne $true }).Count) { return 'posted' }
    if ($Posted) { return 'posted' }
    return ''
}

function Set-TikTokSpreadTimes {
    # Gán giờ cho các dòng đang tick (không phải 'active'), theo thứ tự dòng; dòng còn lại When=$null. Trả về số dòng tick nhưng không còn chỗ.
    param([object[]]$Rows, [string[]]$Favorites = @(), [DateTime[]]$Busy = @(), [DateTime]$Now = [DateTime]::Now)
    foreach ($r in @($Rows)) { $r.When = $null }
    $eligible = @(@($Rows) | Where-Object { $_.Include -and $_.Warn -ne 'active' })
    $plan = @(Get-TikTokSpreadPlan -Count $eligible.Count -Favorites $Favorites -Busy $Busy -Now $Now)
    for ($i = 0; $i -lt $plan.Count; $i++) { $eligible[$i].When = $plan[$i] }
    return ($eligible.Count - $plan.Count)
}

function Get-TikTokAutoScheduleItems {
    # "Tự hẹn lịch" của kho tài khoản: video Chờ đăng của kho, KHÔNG có mục lịch sử nào, cũ nhất trước.
    # $MetaByRoot: thu muc kho -> reup-status.json (moi video doc lich su o thu muc cua chinh no).
    param([object[]]$Items, [string]$KhoId, $MetaByRoot)
    $out = New-Object 'System.Collections.Generic.List[object]'
    foreach ($it in @($Items)) {
        if (-not $it -or [string]$it.Kho -cne $KhoId -or (Get-GalleryBucket $it) -ne 'pending') { continue }
        $metadata = $(if ($MetaByRoot) { $MetaByRoot[[string]$it.Root] } else { $null })
        $p = if ($metadata) { $metadata.PSObject.Properties[[string]$it.Id] } else { $null }
        if ($p -and @(@($p.Value.History) | Where-Object { $_ }).Count) { continue }
        $out.Add($it)
    }
    return @($out | Sort-Object { [IO.File]::GetLastWriteTimeUtc([string]$_.Path) }, { [string]$_.Id })
}

function New-TikTokSpreadJob {
    # Cùng hình dạng record/payload với hộp thoại đăng 1 video (để biên lai, đồng bộ, lịch sử, tự gán kho chạy như cũ).
    param([string]$Path, [string]$Account, [string]$Caption, [DateTime]$When)
    $source = [IO.Path]::GetFullPath($Path); $outDir = [IO.Path]::GetDirectoryName($source); $videoId = Get-ReelId $source
    $scheduled = $When.ToUniversalTime().ToString('o')
    $options = @{ allow_comment = 1; allow_duet = 0; allow_stitch = 0; visibility_type = 0; ai_label = 0 }
    $payload = @{ username = $Account; title = $Caption; scheduled_for = $scheduled; options_json = ($options | ConvertTo-Json -Compress); reel_id = (Get-TikTokWireReelId $videoId) }
    $now = [DateTime]::UtcNow.ToString('o')
    $record = [pscustomobject]@{ RequestId = [Guid]::NewGuid().ToString('N'); SourcePath = $source; OutDir = $outDir; VideoId = $videoId; Username = $Account; ScheduledFor = $scheduled; Status = 'submitted'; CreatedAt = $now; LaunchedAt = $now; Message = ''; Caption = $Caption }
    return @{ Record = $record; Payload = $payload }
}

function Get-SpreadEffectiveCaption {
    # Caption THỰC SỰ được gửi cho một dòng: caption riêng của dòng nếu có chữ, không thì caption chung (đã cắt khoảng trắng).
    param($Row, [string]$Common = '')
    $own = $(if ($Row.PSObject.Properties['Caption']) { ([string]$Row.Caption).Trim() } else { '' })
    if ($own) { return $own }
    return ([string]$Common).Trim()
}

function Get-SpreadCaptionProblem {
    # '' khi MỌI dòng sẽ gửi (có giờ hẹn) đều có caption thực sự; ngược lại thông báo nói rõ video nào còn thiếu.
    param([object[]]$Rows, [string]$Common = '')
    $missing = @(@($Rows) | Where-Object { $_ -and $_.When -and -not (Get-SpreadEffectiveCaption -Row $_ -Common $Common) })
    if (-not $missing.Count) { return '' }
    $names = @($missing | Select-Object -First 3 | ForEach-Object { Get-ReelLabel $_.Id })
    return 'Video ' + ($names -join ', ') + $(if ($missing.Count -gt 3) { ' và ' + ($missing.Count - 3) + ' video nữa' } else { '' }) + ' chưa có caption: nhập vào ô "Caption chung" hoặc vào ô caption dưới giờ hẹn của video đó.'
}

function ConvertFrom-SpreadTimeText {
    # D10: ô giờ của một dòng ("dd/MM HH:mm", giờ máy). Năm = năm hiện tại, sang năm sau nếu ngày đã qua. Hợp lệ khi TikTok cho hẹn được (20 phút đến 10 ngày).
    # Trả về @{ Ok; When; Error }.
    param([string]$Text, [DateTime]$Now = [DateTime]::Now)
    $m = [regex]::Match(([string]$Text).Trim(), '^(\d{1,2})/(\d{1,2})\s+(\d{1,2}):(\d{2})$')
    $format = 'Nhập giờ dạng dd/MM HH:mm, ví dụ 28/10 19:00.'
    if (-not $m.Success) { return @{ Ok = $false; When = $null; Error = $format } }
    $d = [int]$m.Groups[1].Value; $mo = [int]$m.Groups[2].Value; $h = [int]$m.Groups[3].Value; $mi = [int]$m.Groups[4].Value
    $when = $null
    foreach ($year in @($Now.Year, ($Now.Year + 1))) {
        try { $cand = [DateTime]::new($year, $mo, $d, $h, $mi, 0, [DateTimeKind]::Local) } catch { return @{ Ok = $false; When = $null; Error = 'Ngày giờ không có thật. ' + $format } }
        if ($cand -ge $Now.Date) { $when = $cand; break }
    }
    if ($null -eq $when) { return @{ Ok = $false; When = $null; Error = $format } }
    $err = Get-TikTokScheduleError $when $Now
    if ($err) { return @{ Ok = $false; When = $null; Error = $err } }
    return @{ Ok = $true; When = $when; Error = '' }
}

function Get-SpreadRowWarning {
    # D10: cảnh báo (không chặn) cho MỘT dòng sau khi sửa giờ: cách một bài khác (các dòng khác + giờ bận của tài khoản) dưới 60 phút. '' nếu ổn.
    param([DateTime]$When, [DateTime[]]$Others = @(), [DateTime[]]$Busy = @())
    $nearest = $null
    foreach ($b in @(@($Others) + @($Busy))) { $gap = [Math]::Abs(($When - $b).TotalMinutes); if ($gap -lt 60 -and ($null -eq $nearest -or $gap -lt $nearest)) { $nearest = $gap } }
    if ($null -eq $nearest) { return '' }
    return 'Cách một bài khác chỉ ' + [int][Math]::Round($nearest) + ' phút (nên từ 60 phút).'
}

function Get-TikTokSpreadSendResult {
    # Kết quả THẬT của một tiến trình con sau khi thoát: đọc biên nhận .cache\tiktok-posts\<RequestId>.json.
    # Đã gửi = bộ đăng nền trả trạng thái nhận việc (pending/queued/running/succeeded...). Lỗi = transfer_failed, preparation_failed, failed, cancelled, missing, unknown,
    # hoặc biên nhận vẫn 'submitted' / không có (tiến trình chết trước khi chuyển xong). Trả về @{ Sent; Message }.
    param([string]$OutDir, [string]$RequestId, $ExitCode = $null)
    $code = $(if ($null -ne $ExitCode -and [string]$ExitCode -ne '') { ' (mã thoát ' + $ExitCode + ')' } else { '' })
    $path = Join-Path (Join-Path $OutDir '.cache\tiktok-posts') ($RequestId + '.json')
    if (-not [IO.File]::Exists($path)) { return @{ Sent = $false; Message = 'Không thấy biên nhận gửi video' + $code + '.' } }
    try { $receipt = [IO.File]::ReadAllText($path) | ConvertFrom-Json -ErrorAction Stop }
    catch { Write-FileLog ('WARN Rải lịch: không đọc được biên nhận ' + $RequestId + ': ' + $_.Exception.Message); return @{ Sent = $false; Message = 'Không đọc được biên nhận gửi video' + $code + '.' } }
    $status = ([string]$receipt.Status).Trim().ToLowerInvariant()
    $text = ([string]$receipt.Message).Trim()
    if ($status -in @('transfer_failed', 'preparation_failed', 'failed', 'cancelled', 'missing', 'unknown')) {
        return @{ Sent = $false; Message = $(if ($text) { $text } else { 'Gửi lỗi: ' + $status }) + $code }
    }
    if (-not $status -or $status -eq 'submitted') { return @{ Sent = $false; Message = 'Tiến trình gửi đã kết thúc nhưng chưa nhận được xác nhận từ bộ đăng nền' + $code + '.' } }
    return @{ Sent = $true; Message = $text }
}

function New-TikTokSpreadRun {
    # Rows: các dòng đã tick và có When (Id, Path, When, ...). Busy: giờ bận của tài khoản trước khi gửi.
    # Verifier ({row, job, process} -> @{Sent; Message}) kiểm kết quả thật khi tiến trình con thoát; HistoryReader ({row} -> @{History; Posted; TransferActive}) đọc lịch sử mới nhất ngay trước khi gửi. Không có thì bỏ qua bước đó.
    param([object[]]$Rows, [string]$Account, [string]$Caption, [string[]]$Favorites = @(), [DateTime[]]$Busy = @(), [scriptblock]$Verifier = $null, [scriptblock]$HistoryReader = $null)
    foreach ($r in @($Rows)) { $r | Add-Member -NotePropertyName State -NotePropertyValue 'planned' -Force; $r | Add-Member -NotePropertyName Message -NotePropertyValue '' -Force; $r | Add-Member -NotePropertyName Shifted -NotePropertyValue $false -Force }
    return @{ Rows = @($Rows); Account = $Account; Caption = $Caption; Favorites = @($Favorites); Busy = @($Busy)
             Verifier = $Verifier; HistoryReader = $HistoryReader; CurrentRow = $null; CurrentJob = $null; CurrentStarted = $null; LongWait = $false; InFlight = 0
             Index = 0; Current = $null; Stopped = $false; Finished = $false; Sent = 0; Failed = 0; Skipped = 0; Shifted = 0 }
}

function Complete-TikTokSpreadCurrent {
    # Tiến trình con vừa thoát: hàng đã đếm 'sent' lúc giao; nếu biên nhận cho thấy gửi lỗi thì chuyển sang 'failed' (không tính là đã gửi).
    param($Run)
    $row = $Run.CurrentRow; $job = $Run.CurrentJob; $proc = $Run.Current
    $Run.Current = $null; $Run.CurrentRow = $null; $Run.CurrentJob = $null; $Run.LongWait = $false
    if (-not $Run.Verifier -or -not $row) { return }
    try { $v = & $Run.Verifier $row $job $proc }
    catch { $v = @{ Sent = $false; Message = 'Không kiểm tra được kết quả gửi: ' + $_.Exception.Message }; Write-FileLog ('WARN Rải lịch: kiểm kết quả ' + (Get-ReelLabel $row.Id) + ': ' + $_.Exception.Message) }
    if ($v.Sent) { return }
    $row.State = 'failed'; $row.Message = [string]$v.Message; $Run.Sent--; $Run.Failed++
    Write-FileLog ('WARN Rải lịch: ' + (Get-ReelLabel $row.Id) + ' gửi lỗi: ' + $row.Message)
}

function Stop-TikTokSpreadRun {
    # Dừng NGAY: không giao thêm video nào, kết thúc lượt chạy. Tiến trình con đang chạy (nếu có) vẫn chạy tiếp; kết quả cuối do đồng bộ thường lệ cập nhật. Không bao giờ gửi lại.
    param($Run)
    if ($Run.Finished) { return }
    $Run.Stopped = $true
    if ($Run.Current) {
        if ($Run.Current.HasExited) { Complete-TikTokSpreadCurrent $Run }
        else {
            if ($Run.CurrentRow) { $Run.CurrentRow.Message = 'Đang gửi — kết quả sẽ cập nhật ở lịch sử đăng.' }
            $Run.InFlight++; $Run.Current = $null; $Run.CurrentRow = $null; $Run.CurrentJob = $null; $Run.LongWait = $false
        }
    }
    $Run.Finished = $true
}

function Update-TikTokSpreadRowFromMeta {
    # Sau bước chuẩn bị (lịch sử vừa được làm mới): tính lại cảnh báo của MỌI dòng. Dòng vừa thành 'active'/'posted' thì bị bỏ tick (chủ phải tick lại mới hẹn). 'active' không bị hạ cấp.
    param($Row, $Meta)
    $p = $(if ($Meta) { $Meta.PSObject.Properties[[string]$Row.Id] } else { $null })
    if (-not $p) { return }
    $Row.History = @(@($p.Value.History) | Where-Object { $_ })
    $w = Get-TikTokSpreadWarn -History $Row.History -Posted ([bool]$p.Value.Posted)
    if ($w -and $w -ne $Row.Warn -and $Row.Warn -ne 'active') {
        $Row.Warn = $w; $Row.Include = $false
        if ($w -eq 'posted') {
            $ok = @($Row.History | Where-Object { [string]$_.status -eq 'succeeded' -and $_.publish_uncertain -ne $true -and [string]$_.username } | Select-Object -First 1)
            if ($ok.Count) { $Row | Add-Member -NotePropertyName Other -NotePropertyValue ('@' + [string]$ok[0].username) -Force }
        }
    }
}

function Get-TikTokSpreadSummary {
    param($Run)
    $left = @($Run.Rows | Where-Object { $_.State -eq 'planned' }).Count
    return 'Đã gửi ' + $Run.Sent + ', lỗi ' + $Run.Failed + ', chưa gửi ' + $left + $(if ($Run.Skipped) { ' · ' + $Run.Skipped + ' bỏ qua' } else { '' }) + $(if ($Run.Shifted) { ' · ' + $Run.Shifted + ' dời giờ' } else { '' }) + $(if ($Run.InFlight) { ' · ' + $Run.InFlight + ' đang gửi (kết quả cập nhật sau)' } else { '' }) + '.'
}

function Step-TikTokSpreadRun {
    # Một bước của bộ gửi TUẦN TỰ (gọi từ timer): chỉ bắt đầu việc kế tiếp khi tiến trình con trước đã thoát.
    # Mỗi giờ được kiểm lại ngay trước khi chạy; nếu đã quá gần (< +20 phút) thì đổi sang giờ trống kế tiếp, không bao giờ đăng ngay.
    # Trả về 'waiting' | 'launched' | 'skipped' | 'failed' | 'finished'.
    param($Run, [scriptblock]$Launcher, [scriptblock]$AfterLaunch = $null, [DateTime]$Now = [DateTime]::Now)
    if ($Run.Finished) { return 'finished' }
    if ($Run.Current) {
        if (-not $Run.Current.HasExited) {
            if ($Run.CurrentStarted -and ($Now - $Run.CurrentStarted).TotalMinutes -gt 15) { $Run.LongWait = $true }   # chỉ báo; không bao giờ gửi lại
            return 'waiting'
        }
        Complete-TikTokSpreadCurrent $Run
    }
    if ($Run.Stopped -or $Run.Index -ge $Run.Rows.Count) { $Run.Finished = $true; return 'finished' }
    $row = $Run.Rows[$Run.Index]; $Run.Index++
    # Kiểm lại lịch sử MỚI NHẤT của video ngay trước khi gửi (có thể vừa có lệnh đang chạy / vừa được đăng từ lúc xem trước).
    if ($Run.HistoryReader) {
        $cur = $null
        try { $cur = & $Run.HistoryReader $row } catch { Write-FileLog ('WARN Rải lịch: không đọc lại lịch sử ' + (Get-ReelLabel $row.Id) + ': ' + $_.Exception.Message) }
        if ($cur) {
            $w = Get-TikTokSpreadWarn -History @($cur.History) -Posted ([bool]$cur.Posted)
            if (-not $w -and $cur.TransferActive) { $w = 'active' }
            $why = $null
            if ($w -eq 'active') { $why = 'Video vừa có lệnh đăng chờ/chạy — bỏ qua, không gửi thêm.' }
            elseif ($w -eq 'posted' -and -not ($row.Warn -eq 'posted' -and $row.Include)) { $why = 'Video vừa được đăng xong — bỏ qua (tick lại để vẫn hẹn).' }
            if ($why) {
                $row.State = 'skipped'; $row.Message = $why; $Run.Skipped++
                Write-FileLog ('WARN Rải lịch: bỏ qua ' + (Get-ReelLabel $row.Id) + ' vì ' + $why)
                return 'skipped'
            }
        }
    }
    if (Get-TikTokScheduleError $row.When $Now) {
        $busy = @($Run.Busy) + @($Run.Rows | Where-Object { $_ -ne $row -and $_.State -in @('planned', 'sent') -and $_.When } | ForEach-Object { $_.When })
        $next = @(Get-TikTokSpreadPlan -Count 1 -Favorites $Run.Favorites -Busy $busy -Now $Now)
        if (-not $next.Count) {
            $row.State = 'skipped'; $row.Message = 'Giờ hẹn đã quá gần và không còn giờ trống.'; $Run.Skipped++
            Write-FileLog ('WARN Rải lịch: bỏ qua ' + (Get-ReelLabel $row.Id) + ' vì ' + $row.Message)
            return 'skipped'
        }
        $row.When = $next[0]; $row.Shifted = $true; $Run.Shifted++
    }
    $rowCaption = $(if ($row.PSObject.Properties['Caption'] -and ([string]$row.Caption).Trim()) { [string]$row.Caption } else { [string]$Run.Caption })   # D10: caption riêng của dòng
    $job = New-TikTokSpreadJob -Path $row.Path -Account $Run.Account -Caption $rowCaption -When $row.When
    try { $proc = & $Launcher $job.Record $job.Payload }
    catch {
        $row.State = 'failed'; $row.Message = [string]$_.Exception.Message; $Run.Failed++
        Write-FileLog ('WARN Rải lịch: không giao được ' + (Get-ReelLabel $row.Id) + ': ' + $row.Message)
        return 'failed'
    }
    $row.State = 'sent'; $Run.Sent++; $Run.Current = $proc; $Run.CurrentRow = $row; $Run.CurrentJob = $job; $Run.CurrentStarted = $Now; $Run.LongWait = $false
    if ($AfterLaunch) { try { & $AfterLaunch $row $job } catch { Write-FileLog ('WARN Rải lịch sau khi giao ' + (Get-ReelLabel $row.Id) + ': ' + $_.Exception.Message) } }
    return 'launched'
}

function Get-TikTokRescheduleSeed {
    # D13: when the NEWEST TikTok entry of a video is a native schedule that TikTok rejected (status failed, schedule_mode native) returns
    # @{ Account; Caption; RequestId } (Caption from the receipt of that request when it kept one, else ''), otherwise $null.
    param([object[]]$History, [string]$OutDir)
    $latest = $null; $latestKey = [long]-1
    foreach ($h in @($History)) {
        if ($null -eq $h) { continue }
        $k = Get-TikTokSortKey ([string]$h.created_at)
        if ($k -le 0) { $k = Get-TikTokSortKey ([string]$h.accepted_at) }
        if ($null -eq $latest -or $k -ge $latestKey) { $latest = $h; $latestKey = $k }
    }
    if ($null -eq $latest -or [string]$latest.status -ne 'failed' -or [string]$latest.schedule_mode -ne 'native' -or -not (ConvertTo-KhoUsername ([string]$latest.username))) { return $null }
    $caption = ''
    $req = [string]$latest.request_id
    if ($req -match '^[a-f0-9]{32}$' -and $OutDir) {
        foreach ($dir in @((Join-Path (Join-Path $OutDir '.cache') 'tiktok-posts'), $OutDir)) {
            $f = Join-Path $dir ($req + '.json')
            if (-not [System.IO.File]::Exists($f)) { continue }
            try { $caption = [string]([System.IO.File]::ReadAllText($f, [System.Text.Encoding]::UTF8) | ConvertFrom-Json -ErrorAction Stop).Caption; break }
            catch { Write-FileLog "WARN Hẹn lại: không đọc được biên nhận '$f': $($_.Exception.Message)" }
        }
    }
    return @{ Account = (ConvertTo-KhoUsername ([string]$latest.username)); Caption = $caption; RequestId = $req }
}

function Show-TikTokPublishDialog {
    param([string]$FilePath, $Reschedule = $null)
    if([string]::IsNullOrWhiteSpace($FilePath) -or -not (Test-Path -LiteralPath $FilePath -PathType Leaf) -or -not (Test-KhoVideoFileName ([IO.Path]::GetFileName($FilePath)))){Show-Toast 'Chọn video hoàn chỉnh trong Kho trước khi đăng.' -Kind warning;return}
    # D4: posting only reads a finished -3 file, so a running download queue does not block it.
    if($script:stopping){Show-Toast 'Đợi tác vụ hiện tại dừng hẳn trước khi đăng video.' -Kind warning;return}
    $source=[IO.Path]::GetFullPath($FilePath);$outDir=[IO.Path]::GetDirectoryName($source);$videoId=Get-ReelId $source
    $markup=@'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation" xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml" Title="Đăng video lên TikTok" Width="780" Height="850" MinWidth="600" MinHeight="460" WindowStartupLocation="CenterOwner" ShowInTaskbar="False" Background="{DynamicResource Surface0}" Foreground="{DynamicResource TextPrimary}" FontFamily="{DynamicResource FontUi}" FontSize="15" Language="vi-VN">
 <Grid Margin="24"><Grid.RowDefinitions><RowDefinition Height="Auto"/><RowDefinition Height="*"/><RowDefinition Height="Auto"/></Grid.RowDefinitions>
 <StackPanel><TextBlock Text="Đăng video lên TikTok" Style="{DynamicResource TextHeading}" FontSize="25"/><TextBlock x:Name="FileLabel" Margin="0,5,0,16" TextTrimming="CharacterEllipsis" Foreground="{DynamicResource TextMuted}"/></StackPanel>
 <ScrollViewer Grid.Row="1" VerticalScrollBarVisibility="Auto"><StackPanel Margin="0,0,10,0">
  <DockPanel><Button x:Name="Refresh" Content="Làm mới" DockPanel.Dock="Right" HorizontalAlignment="Right"/><TextBlock Text="Chọn tài khoản đăng" FontWeight="ExtraBold" VerticalAlignment="Center"/></DockPanel>
  <WrapPanel x:Name="Accounts" Margin="0,8,0,12"/>
  <Border Background="{DynamicResource Surface1}" BorderBrush="{DynamicResource InkFaint}" BorderThickness="1" CornerRadius="16" Padding="14" Margin="0,0,0,16"><StackPanel><TextBlock Text="Lịch sử của video này" FontWeight="ExtraBold"/><StackPanel x:Name="History" Margin="0,6,0,0"/><TextBlock x:Name="Status" Text="Đang kiểm tra tài khoản và lịch sử…" TextWrapping="Wrap" Margin="0,6,0,0" Foreground="{DynamicResource TextMuted}"/></StackPanel></Border>
  <TextBlock Text="Mô tả video / caption" FontWeight="SemiBold"/><TextBox x:Name="Caption" AcceptsReturn="True" TextWrapping="Wrap" MaxLength="2200" Height="92" VerticalScrollBarVisibility="Auto" Margin="0,6,0,8"/>
  <StackPanel Margin="0,0,0,12"><TextBlock x:Name="HashtagHeader" Text="Hashtag hay dùng" FontWeight="SemiBold" Visibility="Collapsed" Margin="0,0,0,6"/><WrapPanel x:Name="HashtagChips"/><TextBlock x:Name="HashtagHint" Text="Hashtag bạn dùng khi đăng sẽ được lưu để gợi ý lần sau." TextWrapping="Wrap" FontSize="12" Foreground="{DynamicResource TextMuted}"/></StackPanel>
  <CheckBox x:Name="Schedule" Content="Hẹn giờ trên TikTok" MinHeight="44" Margin="0,0,0,8" ToolTip="Video được gửi lên TikTok ngay; TikTok giữ bài và tự đăng đúng giờ. Khi thẻ hiện 'Đã hẹn trên TikTok', anh có thể tắt máy."/>
  <Border x:Name="WhenPanel" Visibility="Collapsed" Background="{DynamicResource Surface1}" CornerRadius="18" BorderBrush="{DynamicResource InkFaint}" BorderThickness="1" Padding="14" Margin="0,0,0,14">
   <WrapPanel>
    <StackPanel Width="356" Margin="0,0,14,0">
     <DockPanel Margin="0,0,0,8"><Button x:Name="NextMonth" Content="›" Width="44" Height="44" Padding="0" FontSize="26" DockPanel.Dock="Right" AutomationProperties.Name="Tháng sau"/><Button x:Name="PrevMonth" Content="‹" Width="44" Height="44" Padding="0" FontSize="26" DockPanel.Dock="Left" AutomationProperties.Name="Tháng trước"/><TextBlock x:Name="MonthLabel" FontWeight="ExtraBold" VerticalAlignment="Center" HorizontalAlignment="Center"/></DockPanel>
     <UniformGrid Columns="7" Margin="0,0,0,4"><TextBlock Text="Th 2" TextAlignment="Center"/><TextBlock Text="Th 3" TextAlignment="Center"/><TextBlock Text="Th 4" TextAlignment="Center"/><TextBlock Text="Th 5" TextAlignment="Center"/><TextBlock Text="Th 6" TextAlignment="Center"/><TextBlock Text="Th 7" TextAlignment="Center"/><TextBlock Text="CN" TextAlignment="Center"/></UniformGrid>
     <UniformGrid x:Name="Days" Columns="7" Rows="6"/>
    </StackPanel>
    <StackPanel Width="230" Margin="0,8,0,0"><TextBlock Text="Giờ đăng · 24 tiếng" FontWeight="ExtraBold"/><StackPanel Orientation="Horizontal" Margin="0,8,0,10"><TextBox x:Name="Hour" Text="19" Width="68" Height="44" MinHeight="44" Padding="4,0" MaxLength="2" TextAlignment="Center" VerticalContentAlignment="Center" AutomationProperties.Name="Giờ đăng"/><TextBlock Text=" : " FontSize="20" VerticalAlignment="Center"/><TextBox x:Name="Minute" Text="00" Width="68" Height="44" MinHeight="44" Padding="4,0" MaxLength="2" TextAlignment="Center" VerticalContentAlignment="Center" AutomationProperties.Name="Phút đăng"/></StackPanel><TextBlock x:Name="ChosenDate" TextWrapping="Wrap" Margin="0,0,0,12"/><WrapPanel x:Name="TimePresets"/><Button x:Name="NextFree" Content="Giờ trống kế tiếp" Margin="0,6,0,0" HorizontalAlignment="Left" ToolTip="Chọn giờ yêu thích gần nhất (từ 20 phút nữa) mà tài khoản này chưa có bài hẹn trong vòng 1 tiếng."/><WrapPanel Margin="0,12,0,8"><Button x:Name="Today" Content="Hôm nay" Margin="0,0,6,6"/><Button x:Name="Tomorrow" Content="Ngày mai" Margin="0,0,0,6"/></WrapPanel><TextBlock x:Name="ScheduleHint" FontSize="12" Foreground="{DynamicResource TextMuted}" TextWrapping="Wrap"/></StackPanel>
   </WrapPanel>
  </Border>
  <Expander Header="Tùy chọn nâng cao" Margin="0,0,0,10"><WrapPanel><CheckBox x:Name="Comments" Content="Bình luận" IsChecked="True" MinHeight="44" Margin="0,0,18,0"/><CheckBox x:Name="Duet" Content="Song ca" MinHeight="44" Margin="0,0,18,0"/><CheckBox x:Name="Stitch" Content="Ghép nối" MinHeight="44" Margin="0,0,18,0"/><CheckBox x:Name="Private" Content="Chỉ mình tôi" MinHeight="44" Margin="0,0,18,0"/><CheckBox x:Name="AI" Content="Nhãn AI" MinHeight="44"/></WrapPanel></Expander>
  <CheckBox x:Name="ConfirmRepost" Content="Tôi đã kiểm tra và muốn đăng lại thành bài mới" Visibility="Collapsed" MinHeight="44" Margin="0,4,0,8"/>
  <Border x:Name="RepostWarnBox" Visibility="Collapsed" Background="{DynamicResource WarningSubtle}" BorderBrush="{DynamicResource Warning}" BorderThickness="1" CornerRadius="14" Padding="12" Margin="0,4,0,8"><StackPanel><TextBlock x:Name="RepostWarn" TextWrapping="Wrap" FontWeight="SemiBold" Foreground="{DynamicResource WarningText}"/><CheckBox x:Name="ConfirmOther" Content="Tôi vẫn muốn đăng" MinHeight="44" Margin="0,6,0,0"/></StackPanel></Border>
 </StackPanel></ScrollViewer>
 <WrapPanel Grid.Row="2" HorizontalAlignment="Right" Margin="0,16,0,0"><Button x:Name="Dashboard" Content="Tài khoản / Lịch đăng" Margin="0,0,8,8"/><Button x:Name="Close" Content="Đóng" Margin="0,0,8,8" IsCancel="True"/><Button x:Name="Submit" Content="Đăng và chạy nền" Style="{DynamicResource BtnPrimary}" IsEnabled="False" Margin="0,0,0,8"/></WrapPanel>
 </Grid>
</Window>
'@
    $dlg=[Windows.Markup.XamlReader]::Parse($markup);[void]$dlg.Resources.MergedDictionaries.Add((Get-DialogTheme));$dlg.Owner=$win
    $dlg.MaxHeight=[Math]::Max(460,[Windows.SystemParameters]::WorkArea.Height-40)
    $c=@{};foreach($name in @('FileLabel','Refresh','Accounts','History','Status','Caption','HashtagHeader','HashtagChips','HashtagHint','Schedule','WhenPanel','NextMonth','PrevMonth','MonthLabel','Days','Hour','Minute','ChosenDate','TimePresets','Today','Tomorrow','ScheduleHint','Comments','Duet','Stitch','Private','AI','ConfirmRepost','NextFree','RepostWarnBox','RepostWarn','ConfirmOther','Dashboard','Close','Submit')){$c[$name]=$dlg.FindName($name)}
    $c.FileLabel.Text=[IO.Path]::GetFileName($source)
    $state=@{Task=$null;SelectedAccount='';Entries=@();Tags=@(Read-TikTokHashtags);Ready=$false;Native=$false;SelectedDay=[DateTime]::Today;Month=[DateTime]::Today.AddDays(1-[DateTime]::Today.Day);Submitted=$false;FileSha='';Prefs=(Read-TikTokPrefs);Dirty=$false;Programmatic=$false;Libraries=@();VideoKho='';Chips=@()}
    # Kho data for the caption template / account preselect; failures are logged and the dialog works without them.
    # The video's folder IS its kho: history is read from / written to this folder; busy times for "next free slot" come from every kho (S7).
    $state.VideoKhoAccount=''
    try{
        $state.Libraries=@((Get-KhoRegistry).libraries)
        $videoLib=Get-KhoByPath $outDir
        if($videoLib){$state.VideoKho=[string]$videoLib.id;$state.VideoKhoAccount=[string]$videoLib.account}
    }catch{Write-FileLog ('WARN TikTok dialog kho info: '+$_.Exception.Message)}
    $updateSelection={
        $blocking=Get-TikTokActiveStatuses
        $own=@($state.Entries | Where-Object {$_.username -eq $state.SelectedAccount -or (-not $_.username -and $_.status -in $blocking)})
        $active=@($own | Where-Object {$_.status -in $blocking})
        $repeat=@($own | Where-Object {$_.status -eq 'succeeded' -or $_.publish_uncertain -or $_.prior_uncertain})
        $c.ConfirmRepost.Visibility=$(if($repeat.Count){'Visible'}else{'Collapsed'})
        $other=$(if($state.SelectedAccount){Get-TikTokRepostWarning @($state.Entries) $state.SelectedAccount}else{$null})
        if($other){
            $c.RepostWarn.Text='Video này đã đăng ở @'+$other.Username+$(if($other.When){' ('+$other.When.ToString('dd/MM HH:mm')+')'}else{''})+'. Đăng thêm tài khoản khác dễ bị TikTok coi là trùng.'
            $c.RepostWarnBox.Visibility='Visible'
        }else{$c.RepostWarnBox.Visibility='Collapsed'}
        $needOther=[bool]$other -and -not $c.ConfirmOther.IsChecked
        $state.Upgrading=Test-AutotokUpgradeActive
        $c.Submit.IsEnabled=(-not $state.Submitted -and -not $state.Upgrading -and $state.Ready -and $state.SelectedAccount -and -not $active.Count -and (-not $repeat.Count -or $c.ConfirmRepost.IsChecked) -and -not $needOther)
        if($state.Submitted){return}
        if($state.Upgrading){$c.Status.Text='Đang cài hoặc cập nhật bộ đăng TikTok. Đợi xong rồi đăng.';return}
        if($active.Count){$c.Status.Text='Tài khoản này đã có tác vụ cho video này. Xem Lịch đăng để theo dõi; không cần gửi thêm.'}
        elseif($repeat.Count -and -not $c.ConfirmRepost.IsChecked){$c.Status.Text='Video đã được gửi trên tài khoản này hoặc kết quả chưa rõ. Chọn tài khoản khác, hoặc xác nhận đăng lại sau khi kiểm tra.'}
        elseif($needOther){$c.Status.Text='Video này đã đăng ở tài khoản khác. Chọn "Tôi vẫn muốn đăng" nếu anh chắc chắn.'}
        elseif($state.Ready){$c.Status.Text='Nhập caption rồi bấm Đăng và chạy nền. Anh có thể tiếp tục dùng app ngay.'}
    }.GetNewClosure()
    # Hashtag hay dung: chip goi y duoi o caption (loc theo hashtag dang go tai con tro).
    $hashtagUi=@{Render=$null;Remove=$null}
    $chipClicked={
        param($sender,$eventArgs)
        $ctx=$sender.Tag;$cap=$ctx.Controls.Caption
        $r=Add-TikTokHashtagToCaption -Text $cap.Text -Caret $cap.CaretIndex -Tag $ctx.Tag -MaxLength $cap.MaxLength
        if($r.Ok){$cap.Text=$r.Text;$cap.CaretIndex=$r.Caret}
        elseif($r.Reason -eq 'toolong'){$ctx.Controls.Status.Text='Caption đã đạt giới hạn '+$cap.MaxLength+' ký tự, không thêm được hashtag này.'}
        [void]$cap.Focus();$cap.CaretIndex=$cap.Text.Length
        & $ctx.Holder.Render
    }
    $chipRemove={
        param($sender,$eventArgs)
        $ctx=$sender.Tag
        try{Remove-TikTokHashtag $ctx.Tag;$ctx.State.Tags=@(Read-TikTokHashtags)}catch{Write-FileLog ('WARN TikTok hashtag remove: '+$_.Exception.Message);$ctx.Controls.Status.Text='Không xóa được hashtag khỏi gợi ý.'}
        & $ctx.Holder.Render
    }
    $chipKey={
        param($sender,$eventArgs)
        if($eventArgs.Key -eq [Windows.Input.Key]::Delete){$eventArgs.Handled=$true;& $sender.Tag.Holder.Remove $sender $eventArgs}
    }
    $hashtagUi.Remove=$chipRemove
    $hashtagUi.Render={
        $c.HashtagChips.Children.Clear()
        $list=@(Get-TikTokHashtagSuggestions -Tags $state.Tags -Text $c.Caption.Text -Caret $c.Caption.CaretIndex -Max 20 -Account $state.SelectedAccount)
        $none=(@($state.Tags).Count -eq 0)
        $c.HashtagHint.Visibility=$(if($none){'Visible'}else{'Collapsed'})
        $c.HashtagHeader.Visibility=$(if($none){'Collapsed'}else{'Visible'})
        foreach($tag in $list){
            $b=New-Object Windows.Controls.Button;$b.Style=$dlg.FindResource('BtnSecondary')
            $label=New-Object Windows.Controls.TextBlock;$label.Text=$tag;$b.Content=$label
            $b.MinHeight=34;$b.Padding=[Windows.Thickness]::new(12,0,12,0);$b.Margin=[Windows.Thickness]::new(0,0,6,6)
            $ctx=@{Tag=$tag;Controls=$c;State=$state;Holder=$hashtagUi}
            $b.Tag=$ctx;$b.ToolTip='Bấm để thêm vào caption. Chuột phải hoặc phím Delete để xóa khỏi gợi ý.'
            [Windows.Automation.AutomationProperties]::SetName($b,'Thêm hashtag '+$tag)
            $menu=New-Object Windows.Controls.ContextMenu;$item=New-Object Windows.Controls.MenuItem;$item.Header='Xóa khỏi gợi ý';$item.Tag=$ctx;$item.Add_Click($chipRemove);[void]$menu.Items.Add($item);$b.ContextMenu=$menu
            $b.Add_Click($chipClicked);$b.Add_PreviewKeyDown($chipKey)
            [void]$c.HashtagChips.Children.Add($b)
        }
    }.GetNewClosure()
    $c.Caption.Add_TextChanged({if(-not $state.Programmatic){$state.Dirty=$true};& $hashtagUi.Render}.GetNewClosure())
    $c.Caption.Add_SelectionChanged({& $hashtagUi.Render}.GetNewClosure())
    & $hashtagUi.Render
    $calendar=@{Render=$null}
    $dayClicked={
        param($sender,$eventArgs)
        $context=$sender.CommandParameter
        $context.State.SelectedDay=[DateTime]$sender.Tag
        $context.State.Month=$context.State.SelectedDay.AddDays(1-$context.State.SelectedDay.Day)
        & $context.Calendar.Render
    }
    $accountChecked={
        param($sender,$eventArgs)
        $context=$sender.Tag
        $context.State.SelectedAccount=[string]$context.Username
        $context.Controls.ConfirmRepost.IsChecked=$false
        $context.Controls.ConfirmOther.IsChecked=$false
        & $context.OnAccount
        & $context.Update
    }
    $receiptAction={
        param($sender,$eventArgs)
        $context=$sender.Tag
        try{
            if($context.Action -eq 'retry'){
                Restart-TikTokTransfer -OutDir $context.OutDir -RequestId $context.RequestId
                Show-Toast 'Đã giao lại video cho bộ đăng nền với cùng mã yêu cầu, nên không tạo bài trùng.' -Kind info
            }else{
                Move-TikTokReceiptToArchive -OutDir $context.OutDir -RequestId $context.RequestId
                Show-Toast 'Đã bỏ biên nhận. Tệp được giữ lại trong .cache\tiktok-posts (đuôi .archived-…).' -Kind info
            }
            & $context.Refresh
        }catch{$context.Controls.Status.Text=$_.Exception.Message}
    }
    $renderCalendar={
        $c.Days.Children.Clear();$vi=[Globalization.CultureInfo]::GetCultureInfo('vi-VN')
        $c.MonthLabel.Text=$state.Month.ToString("'Tháng' MM · yyyy",$vi)
        $offset=(([int]$state.Month.DayOfWeek+6)%7);$first=$state.Month.AddDays(-$offset)
        for($i=0;$i -lt 42;$i++){
            $day=$first.AddDays($i);$button=New-Object Windows.Controls.Button
            $button.Content=[string]$day.Day;$button.Tag=$day;$button.MinWidth=44;$button.MinHeight=44;$button.Height=46;$button.Margin=[Windows.Thickness]::new(2)
            $button.Padding=[Windows.Thickness]::new(0);$button.FontSize=14
            $button.Style=$dlg.FindResource($(if($day.Date -eq $state.SelectedDay.Date){'BtnPrimary'}else{'BtnSecondary'}))
            $button.IsEnabled=(Test-TikTokScheduleDay $day)
            if($day.Month -ne $state.Month.Month){$button.Opacity=0.55}
            [Windows.Automation.AutomationProperties]::SetName($button,$day.ToString('dddd, dd/MM/yyyy',$vi))
            $button.CommandParameter=@{State=$state;Calendar=$calendar}
            $button.Add_Click($dayClicked)
            [void]$c.Days.Children.Add($button)
        }
        $c.ChosenDate.Text='Đã chọn: '+$state.SelectedDay.ToString('dddd, dd/MM/yyyy',$vi)
        $bounds=Get-TikTokScheduleBounds
        $c.ScheduleHint.Text='Giờ trên máy. Chọn từ '+$bounds.Min.ToString('HH:mm dd/MM')+' đến '+$bounds.Max.ToString('HH:mm dd/MM')+'. Video được gửi lên TikTok ngay; TikTok giữ bài và tự đăng đúng giờ. Khi thẻ hiện "Đã hẹn trên TikTok", anh có thể tắt máy.'
    }.GetNewClosure()
    # The callback captures a shared object so rebuilding the calendar does not lose its renderer.
    $calendar.Render=$renderCalendar
    $c.NextMonth.Add_Click({$state.Month=$state.Month.AddMonths(1);& $calendar.Render}.GetNewClosure())
    $c.PrevMonth.Add_Click({$state.Month=$state.Month.AddMonths(-1);& $calendar.Render}.GetNewClosure())
    $c.Today.Add_Click({$state.SelectedDay=[DateTime]::Today;$state.Month=$state.SelectedDay.AddDays(1-$state.SelectedDay.Day);& $calendar.Render}.GetNewClosure())
    $c.Tomorrow.Add_Click({$state.SelectedDay=[DateTime]::Today.AddDays(1);$state.Month=$state.SelectedDay.AddDays(1-$state.SelectedDay.Day);& $calendar.Render}.GetNewClosure())
    # Time chips: the selected account's most used times (data\tiktok-prefs.json), topped up with 08:00/12:00/19:00/21:00.
    $renderPresets={
        $c.TimePresets.Children.Clear()
        $key=([string]$state.SelectedAccount).ToLowerInvariant();$times=$null
        if($key -and $state.Prefs.times.ContainsKey($key)){$times=$state.Prefs.times[$key]}
        $state.Chips=@(Get-TikTokTimeChips $times)
        # Khung gio da dat cho kho cua tai khoan (Quan ly kho) thay cho gio hay dung.
        $slotLib=Get-KhoForAccount $state.SelectedAccount
        if($slotLib -and @($slotLib.slots).Count){$state.Chips=@($slotLib.slots)}
        foreach($time in $state.Chips){$b=New-Object Windows.Controls.Button;$b.Content=$time;$b.Tag=$time;$b.Margin=[Windows.Thickness]::new(0,0,6,6);$b.Add_Click({param($sender,$eventArgs) $parts=([string]$sender.Tag).Split(':');$c.Hour.Text=$parts[0];$c.Minute.Text=$parts[1]}.GetNewClosure());[void]$c.TimePresets.Children.Add($b)}
    }.GetNewClosure()
    & $renderPresets
    # Account changed: refresh chips, prefill the caption while the user has not typed, re-rank hashtag suggestions.
    $onAccount={
        & $renderPresets
        if(-not $state.Dirty){
            $template=Get-TikTokCaptionTemplate -Account $state.SelectedAccount -VideoKhoId $state.VideoKho -Libraries $state.Libraries
            if($template -ne $c.Caption.Text){$state.Programmatic=$true;try{$c.Caption.Text=$template;$c.Caption.CaretIndex=$template.Length}finally{$state.Programmatic=$false}}
        }
        & $hashtagUi.Render
    }.GetNewClosure()
    $c.NextFree.Add_Click({
        if(-not $state.SelectedAccount){$c.ScheduleHint.Text='Chọn tài khoản trước.';return}
        try{
            $metaRead=Get-GalleryMetaChecked
            if($metaRead.Gap){$c.ScheduleHint.Text=$metaRead.Gap+' Chưa chọn giờ tự động; bạn vẫn có thể nhập giờ bằng tay (chưa kiểm tra trùng lịch).';return}
            $busy=@(Get-TikTokAccountBusyTimes -Account $state.SelectedAccount -ExtraEntries @($state.Entries) -MetaByRoot $metaRead.Map)
            $slot=Get-NextFreeTikTokSlot -Favorites @($state.Chips) -Busy $busy
        }catch{Write-FileLog ('WARN TikTok next free slot: '+$_.Exception.Message);$c.Status.Text='Không đọc được lịch để tìm giờ trống: '+$_.Exception.Message;return}
        if($null -eq $slot){$c.ScheduleHint.Text='Các giờ yêu thích trong 10 ngày tới đều đã có bài hẹn. Chọn giờ khác bằng tay.';return}
        $c.Schedule.IsChecked=$true
        $state.SelectedDay=$slot.Date;$state.Month=$state.SelectedDay.AddDays(1-$state.SelectedDay.Day)
        $c.Hour.Text=$slot.ToString('HH');$c.Minute.Text=$slot.ToString('mm')
        & $calendar.Render
        $c.ScheduleHint.Text='Giờ trống kế tiếp: '+$slot.ToString('HH:mm dd/MM')+'. '+$c.ScheduleHint.Text
    }.GetNewClosure())
    $c.Schedule.Add_Checked({if(-not (Test-TikTokScheduleDay $state.SelectedDay)){$state.SelectedDay=(Get-TikTokScheduleBounds).Min.Date;$state.Month=$state.SelectedDay.AddDays(1-$state.SelectedDay.Day)};& $calendar.Render;$c.WhenPanel.Visibility='Visible';$c.Private.IsChecked=$false;$c.Private.IsEnabled=$false;$c.Submit.Content='Hẹn giờ trên TikTok';$dlg.UpdateLayout();$c.WhenPanel.BringIntoView()}.GetNewClosure())
    $c.Schedule.Add_Unchecked({$c.WhenPanel.Visibility='Collapsed';$c.Private.IsEnabled=$true;$c.Submit.Content='Đăng và chạy nền'}.GetNewClosure())
    $c.ConfirmRepost.Add_Checked($updateSelection);$c.ConfirmRepost.Add_Unchecked($updateSelection);$c.ConfirmOther.Add_Checked($updateSelection);$c.ConfirmOther.Add_Unchecked($updateSelection)
    $c.Dashboard.Add_Click({Start-Process ((Get-TikTokEndpoint)+'/accounts')}.GetNewClosure())
    $c.Close.Add_Click({$dlg.Close()}.GetNewClosure())
    $refresh={if($state.Task -or $state.Submitted){return};try{$state.Ready=$false;$c.Submit.IsEnabled=$false;$c.Refresh.IsEnabled=$false;$c.Status.Text='Đang kiểm tra lịch sử và tài khoản…';$state.Task=Start-TikTokTask 'prepare' (Get-TikTokHistoryPayload $outDir $source)}catch{$c.Status.Text=$_.Exception.Message;$c.Refresh.IsEnabled=$true}}.GetNewClosure()
    $c.Refresh.Add_Click($refresh)
    $c.Submit.Add_Click({
        if($state.Submitted){return}
        try{
            & $updateSelection
            if(-not $c.Submit.IsEnabled){return}
            $caption=$c.Caption.Text.Trim();if(-not $caption){throw 'Vui lòng nhập caption.'}
            $scheduled=''
            if($c.Schedule.IsChecked){
                if($c.Hour.Text -notmatch '^\d{1,2}$' -or [int]$c.Hour.Text -gt 23 -or $c.Minute.Text -notmatch '^\d{1,2}$' -or [int]$c.Minute.Text -gt 59){throw 'Giờ cần trong khoảng 00–23, phút trong khoảng 00–59.'}
                if(-not $state.Native){throw 'Bộ đăng nền chưa hỗ trợ hẹn giờ trên TikTok. Cập nhật bộ đăng nền rồi khởi động lại.'}
                $when=$state.SelectedDay.Date.AddHours([int]$c.Hour.Text).AddMinutes([int]$c.Minute.Text)
                $whenError=Get-TikTokScheduleError $when
                if($whenError){throw $whenError}
                $scheduled=$when.ToUniversalTime().ToString('o')
            }
            $options=@{allow_comment=[int][bool]$c.Comments.IsChecked;allow_duet=[int][bool]$c.Duet.IsChecked;allow_stitch=[int][bool]$c.Stitch.IsChecked;visibility_type=[int][bool]$c.Private.IsChecked;ai_label=[int][bool]$c.AI.IsChecked}
            $payload=@{username=$state.SelectedAccount;title=$caption;scheduled_for=$scheduled;options_json=($options|ConvertTo-Json -Compress);reel_id=(Get-TikTokWireReelId $videoId)}
            $now=[DateTime]::UtcNow.ToString('o')
            $record=[pscustomobject]@{RequestId=[Guid]::NewGuid().ToString('N');SourcePath=$source;OutDir=$outDir;VideoId=$videoId;Username=$state.SelectedAccount;ScheduledFor=$scheduled;Status='submitted';CreatedAt=$now;LaunchedAt=$now;Message='';Caption=$caption}
            # G2: marked before launching; reset only when Start-TikTokBackgroundJob reports that nothing was started.
            $state.Submitted=$true;$c.Submit.IsEnabled=$false
            try{Start-TikTokBackgroundJob $record $payload}catch{$state.Submitted=$false;throw}
        }catch{
            $message=$_.Exception.Message
            & $updateSelection
            $c.Status.Text=$message
            return
        }
        # The job now runs in its own process. Nothing below may re-enable Submit; failures here are logged, not fatal.
        try{Add-TikTokHashtagsFromCaption $caption -Account $state.SelectedAccount}catch{Write-FileLog ('WARN TikTok hashtag save after submit: '+$_.Exception.Message)}
        try{Register-TikTokPrefsSubmit -Username $state.SelectedAccount -Time $(if($scheduled){$when.ToString('HH:mm')}else{''})}catch{Write-FileLog ('WARN TikTok prefs save after submit: '+$_.Exception.Message)}
        $warning=''
        try{[void](Add-TikTokLocalReceiptHistory $outDir $videoId @($state.Entries) $record)}catch{$warning=$_.Exception.Message;Write-FileLog ('WARN TikTok local history after submit: '+$warning)}
        try{Update-Gallery}catch{if(-not $warning){$warning=$_.Exception.Message};Write-FileLog ('WARN TikTok gallery refresh after submit: '+$_.Exception.Message)}
        try{$dlg.Close()}catch{Write-FileLog ('WARN TikTok dialog close after submit: '+$_.Exception.Message)}
        if($warning){Show-Toast 'Đã giao video cho bộ đăng nền, nhưng Kho chưa ghi được trạng thái mới. Kho sẽ tự cập nhật khi bộ đăng nền báo kết quả.' -Kind warning}
        elseif($scheduled){Show-Toast 'Đang gửi video lên TikTok để hẹn giờ. Chỉ tắt máy khi thẻ hiện "Đã hẹn trên TikTok".' -Kind info}
        else{Show-Toast 'Đã giao video cho bộ đăng nền. Kết quả đăng sẽ tự cập nhật trong Kho.' -Kind info}
    }.GetNewClosure())
    $timer=New-Object Windows.Threading.DispatcherTimer;$timer.Interval=[TimeSpan]::FromMilliseconds(250)
    $timer.Add_Tick({
        # Upgrade lock appeared/disappeared while the dialog is open: re-evaluate Submit.
        if($state.Ready -and -not $state.Submitted -and [bool]$state.Upgrading -ne (Test-AutotokUpgradeActive)){& $updateSelection}
        if(-not $state.Task -or -not $state.Task.Async.IsCompleted){return}
        $task=$state.Task;$state.Task=$null
        try{
            $result=Complete-TikTokTask $task
            $state.Entries=@($result.history | Where-Object {$null -ne $_})
            $state.FileSha=[string]$result.file_sha
            $state.Native=[bool]$result.native_schedule
            if(-not $state.Native){$c.Schedule.IsChecked=$false;$c.Schedule.IsEnabled=$false;$c.NextFree.IsEnabled=$false;$c.Schedule.ToolTip='Bộ đăng nền chưa hỗ trợ hẹn giờ trên TikTok. Cập nhật bộ đăng nền rồi khởi động lại.'}
            if($result.changed){Update-Gallery}
            $c.History.Children.Clear()
            if(-not $state.Entries.Count){$text=New-Object Windows.Controls.TextBlock;$text.Text='Chưa có lịch sử đăng trong hệ thống.';[void]$c.History.Children.Add($text)}
            $postsDir=Join-Path $outDir '.cache\tiktok-posts'
            foreach($entry in @($state.Entries | Select-Object -First 8)){
                $text=New-Object Windows.Controls.TextBlock;$text.TextWrapping='Wrap';$text.Margin=[Windows.Thickness]::new(0,4,0,2)
                $text.Text=$(if($entry.username){'@'+$entry.username}else{'Chưa rõ tài khoản'})+' · '+(Get-TikTokEntryLabel $entry $state.FileSha)
                if($entry.status -eq 'succeeded' -and $entry.key -and ((Test-TikTokPostUrl ([string]$entry.post_url)) -or (Test-TikTokPostId ([string]$entry.post_id)) -or [string]$entry.link_state -eq 'gave_up')){
                    $row=New-Object Windows.Controls.WrapPanel;[void]$row.Children.Add($text)
                    $button=New-Object Windows.Controls.Button;$button.Margin=[Windows.Thickness]::new(0,4,8,4)
                    if(Test-TikTokPostUrl ([string]$entry.post_url)){$button.Content='Mở bài đăng';$button.Tag=[string]$entry.post_url;$button.Add_Click({param($sender,$eventArgs) [void](Open-TikTokPostUrl ([string]$sender.Tag))})}
                    elseif(Test-TikTokPostId ([string]$entry.post_id)){$button.Content='Sao chép mã';$button.Tag=[string]$entry.post_id;$button.Add_Click({param($sender,$eventArgs) [void](Copy-TikTokPostId ([string]$sender.Tag))})}
                    else{$button.Content='Thử lấy lại link';$button.Tag=[string]$entry.key;$button.Add_Click({param($sender,$eventArgs) Start-TikTokLinkRefresh ([string]$sender.Tag);$sender.IsEnabled=$false})}
                    [void]$row.Children.Add($button);[void]$c.History.Children.Add($row);continue
                }
                if($entry.status -eq 'failed'){
                    # TikTok's answer to the failed attempt is kept by the background poster: its Lịch đăng page shows it.
                    $row=New-Object Windows.Controls.WrapPanel;[void]$row.Children.Add($text)
                    $button=New-Object Windows.Controls.Button;$button.Content='Xem chi tiết lỗi';$button.Margin=[Windows.Thickness]::new(0,4,8,4)
                    $button.Add_Click({Start-Process ((Get-TikTokEndpoint)+'/schedules')}.GetNewClosure())
                    [void]$row.Children.Add($button);[void]$c.History.Children.Add($row);continue
                }
                if($entry.status -ne 'transfer_failed' -or $entry.time_source -ne 'local'){[void]$c.History.Children.Add($text);continue}
                # "Chưa chuyển được": the backend has no record of this request and its worker is gone (R2).
                $row=New-Object Windows.Controls.WrapPanel;[void]$row.Children.Add($text)
                $actions=@()
                if([IO.File]::Exists((Join-Path $postsDir ($entry.request_id+'.job')))){$actions+=,@('Thử chuyển lại','retry')}
                $actions+=,@('Bỏ biên nhận','archive')
                foreach($spec in $actions){
                    $button=New-Object Windows.Controls.Button;$button.Content=$spec[0];$button.Margin=[Windows.Thickness]::new(0,4,8,4)
                    $button.Tag=@{Action=$spec[1];RequestId=[string]$entry.request_id;OutDir=$outDir;Refresh=$refresh;Controls=$c}
                    $button.Add_Click($receiptAction)
                    [void]$row.Children.Add($button)
                }
                [void]$c.History.Children.Add($row)
            }
            $c.Accounts.Children.Clear();$group='TikTokAccount'+[Guid]::NewGuid().ToString('N')
            $accounts=Select-TikTokReadyAccounts $result.accounts
            foreach($account in $accounts){
                $button=New-Object Windows.Controls.RadioButton;$button.Style=$dlg.FindResource('SegButton');$button.GroupName=$group;$button.Content='@'+$account.username;$button.Tag=@{State=$state;Controls=$c;Username=[string]$account.username;Update=$updateSelection;OnAccount=$onAccount};$button.MinHeight=48;$button.Padding=[Windows.Thickness]::new(16,0,16,0);$button.Margin=[Windows.Thickness]::new(0,0,8,8)
                $button.Add_Checked($accountChecked)
                [void]$c.Accounts.Children.Add($button)
            }
            $state.Ready=$true
            if($Reschedule -and -not $state.Seeded){
                # D13 Hẹn lại: same account and caption as the failed schedule; the time is the next free slot (after the selection below).
                $state.Seeded=$true;$state.SelectedAccount=[string]$Reschedule.Account
                if([string]$Reschedule.Caption){$state.Dirty=$true;$state.Programmatic=$true;try{$c.Caption.Text=[string]$Reschedule.Caption;$c.Caption.CaretIndex=$c.Caption.Text.Length}finally{$state.Programmatic=$false}}
                $state.SeedSlot=$true
            }
            if($c.Accounts.Children.Count){
                # Order of preference: the account already chosen (refresh), the video's account kho, the last used account, then the first.
                $want=@();if($state.SelectedAccount){$want+=$state.SelectedAccount};if($state.VideoKhoAccount){$want+=$state.VideoKhoAccount};if($state.Prefs.lastAccount){$want+=$state.Prefs.lastAccount}
                $pre=$null
                foreach($w in $want){$pre=@($c.Accounts.Children | Where-Object {$_.Tag.Username -ieq $w})[0];if($pre){break}}
                if(-not $pre){$pre=$c.Accounts.Children[0]}
                $pre.IsChecked=$true
            }else{$c.Status.Text=(Get-TikTokNoReadyAccountsText $result.accounts)}
            & $updateSelection
            if($state.SeedSlot){$state.SeedSlot=$false;$c.NextFree.RaiseEvent((New-Object Windows.RoutedEventArgs ([Windows.Controls.Primitives.ButtonBase]::ClickEvent)))}
        }catch{$c.Status.Text=$_.Exception.Message;$state.Ready=$false}
        $c.Refresh.IsEnabled=$true
    }.GetNewClosure())
    $dlg.Add_Closed({$timer.Stop();if($state.Task){Stop-TikTokTask $state.Task;$state.Task=$null}}.GetNewClosure())
    & $calendar.Render
    & $refresh
    $timer.Start()
    # Hop thoai dang giu video/thu muc: khong cho chuyen kho / xoa kho / don dep chay xen vao (Test-KhoQuiet).
    $script:khoExclusive++
    try { [void]$dlg.ShowDialog() } finally { $script:khoExclusive-- }
}

# ------------------------------------------------------------- Rải lịch chạy nền (D9) ----
# Bấm xác nhận ở hộp thoại Rải lịch chỉ tạo lượt chạy rồi đóng hộp thoại. Lượt chạy sống ở $script:spreadRun và do một DispatcherTimer điều khiển
# (mỗi nhịp = một Step-TikTokSpreadRun). Tiến trình hiện ở dải dưới cùng ("Đang gửi lịch k/N…" + Dừng). Chỉ một lượt tại một thời điểm.
# Lượt chạy tính là "bận" trong Test-KhoQuiet: chuyển kho / xóa kho bị hoãn tới khi xong. Đóng app giữa chừng không lưu lại gì (tiến trình con
# đã giao vẫn chạy tiếp, nhờ vậy lịch đã gửi không mất).
$script:spreadRun = $null
$script:tSpread = $null

function Test-SpreadRunActive { return [bool]($script:spreadRun -and -not $script:spreadRun.Run.Finished) }

function Update-SpreadButtons {
    # Nút Rải lịch tắt trong lúc đang chạy (một lượt tại một thời điểm); tooltip nói lý do.
    $active = Test-SpreadRunActive
    if ($ui -and $ui.BtnSpreadSelected) {
        $ui.BtnSpreadSelected.IsEnabled = (-not $active)
        $ui.BtnSpreadSelected.ToolTip = $(if ($active) { 'Đang rải lịch — đợi xong hoặc bấm Dừng ở dải dưới cùng.' } else { 'Xếp các video đang chọn vào nhiều giờ hẹn trên TikTok' })
        [Windows.Controls.ToolTipService]::SetShowOnDisabled($ui.BtnSpreadSelected, $true)
    }
}

function Update-SpreadStatusUi {
    param([switch]$Hide, [string]$Text = '', [double]$Fraction = 0)
    if ($ui -and $ui.SpreadBar) {
        $was = [string]$ui.SpreadBar.Visibility
        if ($Hide) { $ui.SpreadBar.Visibility = 'Collapsed' }
        else {
            $ui.TxtSpreadStatus.Text = $Text
            $ui.SpreadProgress.Value = [Math]::Max(0.0, [Math]::Min(1.0, $Fraction))
            $ui.SpreadBar.Visibility = 'Visible'
        }
        # Dải xuất hiện/biến mất làm thân trang cao/thấp đi: tính lại bố cục khung xem trước.
        if ($was -ne [string]$ui.SpreadBar.Visibility -and (Get-Command Update-ResponsiveLayout -ErrorAction SilentlyContinue)) {
            try { Update-ResponsiveLayout } catch { Write-FileLog "WARN Bố cục sau khi đổi dải rải lịch: $($_.Exception.Message)" }
        }
    }
    Update-SpreadButtons
}

function Complete-SpreadLaunch {
    # Sau khi một video được giao cho tiến trình nền: nhớ hashtag/giờ/tài khoản và ghi lịch sử cục bộ ở thư mục kho CỦA CHÍNH video.
    param($Row, $Job)
    $acct = [string]$script:spreadRun.Run.Account
    try { Add-TikTokHashtagsFromCaption ([string]$Job.Payload.title) -Account $acct } catch { Write-FileLog ('WARN Rải lịch hashtag: ' + $_.Exception.Message) }
    try { Register-TikTokPrefsSubmit -Username $acct -Time ([DateTime]$Row.When).ToString('HH:mm') } catch { Write-FileLog ('WARN Rải lịch prefs: ' + $_.Exception.Message) }
    try { [void](Add-TikTokLocalReceiptHistory ([string]$Job.Record.OutDir) ([string]$Row.Id) @($Row.History) $Job.Record) } catch { Write-FileLog ('WARN Rải lịch lịch sử cục bộ: ' + $_.Exception.Message) }
    try { Update-GalleryItemsFromMeta -Ids @([string]$Row.Id) } catch { Write-FileLog ('WARN Rải lịch làm mới kho: ' + $_.Exception.Message) }
}

function Complete-SpreadRun {
    # Kết thúc lượt chạy (xong hoặc bị Dừng): tắt timer, giấu dải, báo kết quả một lần.
    param([switch]$Stopped)
    $sr = $script:spreadRun
    if (-not $sr) { return }
    $run = $sr.Run
    if ($script:tSpread) { $script:tSpread.Stop() }
    $script:spreadRun = $null
    Update-SpreadStatusUi -Hide
    $left = @($run.Rows | Where-Object { $_.State -eq 'planned' }).Count
    $text = Get-TikTokSpreadSummary $run
    Write-FileLog ('INFO Rải lịch ' + $(if ($Stopped) { 'đã dừng: ' } else { 'xong: ' }) + $text)
    Show-Toast (($(if ($Stopped) { 'Đã dừng rải lịch. ' } else { '' })) + $text) -Kind $(if ($Stopped -or $run.Failed -or $run.Skipped -or $left -or $run.InFlight) { 'warning' } else { 'success' })
}

function Stop-SpreadBackground {
    # Dừng có hiệu lực NGAY: không giao thêm; tiến trình con đang chạy (nếu có) chạy tiếp, kết quả cuối do đồng bộ thường lệ cập nhật.
    $sr = $script:spreadRun
    if (-not $sr -or $sr.Run.Finished) { return }
    Stop-TikTokSpreadRun -Run $sr.Run
    Complete-SpreadRun -Stopped
}

function Invoke-SpreadRunTick {
    # Một nhịp của timer: một bước của bộ gửi tuần tự, toast cho mỗi video lỗi MỚI, cập nhật dải tiến trình, kết thúc khi hết việc.
    param([DateTime]$Now = [DateTime]::Now)
    $sr = $script:spreadRun
    if (-not $sr) { if ($script:tSpread) { $script:tSpread.Stop() }; return }
    $run = $sr.Run
    $result = ''
    if (-not $run.Finished) {
        if (Test-AutotokUpgradeActive) { Update-SpreadStatusUi -Text 'Đang chờ bộ đăng nền cập nhật xong…' -Fraction ($(if ($sr.Total) { ($run.Sent + $run.Failed + $run.Skipped) / [double]$sr.Total } else { 0 })); return }
        try { $result = Step-TikTokSpreadRun -Run $run -Launcher $sr.Launcher -AfterLaunch $sr.AfterLaunch -Now $Now }
        catch {
            Write-FileLog "ERR  Rải lịch (bước gửi): $($_.Exception.Message)`r`n$($_.ScriptStackTrace)"
            Show-Toast ('Rải lịch gặp lỗi và đã dừng: ' + (Get-FriendlyError $_.Exception.Message)) -Kind error
            Stop-TikTokSpreadRun -Run $run
            $result = 'finished'
        }
    }
    foreach ($row in @($run.Rows)) {
        if ($row.State -eq 'failed' -and -not $sr.Notified.ContainsKey([string]$row.Path)) {
            $sr.Notified[[string]$row.Path] = $true
            Show-Toast ((Get-ReelLabel ([string]$row.Id)) + ': gửi lịch lỗi — ' + [string]$row.Message) -Kind error
        }
    }
    if ($run.Finished -or $result -eq 'finished') { Complete-SpreadRun; return }
    $done = $run.Sent + $run.Failed + $run.Skipped
    $text = $(if ($run.LongWait) { 'Đang chờ video ' + $run.Index + ' gửi xong (đã lâu)… bấm Dừng để kết thúc; video đó vẫn chạy nền.' } else { 'Đang gửi lịch ' + $done + '/' + $sr.Total + '…' })
    Update-SpreadStatusUi -Text $text -Fraction $(if ($sr.Total) { $done / [double]$sr.Total } else { 0 })
}

function Start-TikTokSpreadBackground {
    # Tạo và chạy một lượt rải lịch NỀN. Rows: các dòng đã tick và có When (mỗi dòng có thể có Caption riêng). Throws khi đã có lượt khác.
    # -Launcher/-Verifier/-HistoryReader/-NoTimer: chỗ cắm cho test; mặc định là tiến trình nền thật, biên nhận thật và DispatcherTimer.
    param([object[]]$Rows, [string]$Account, [string]$Caption, [string[]]$Favorites = @(), [DateTime[]]$Busy = @(),
          [scriptblock]$Launcher = $null, [scriptblock]$Verifier = $null, [scriptblock]$HistoryReader = $null, [switch]$NoTimer)
    if (Test-SpreadRunActive) { throw 'Đang có một lượt rải lịch chạy. Đợi xong hoặc bấm Dừng ở dải dưới cùng.' }
    if (-not $Launcher) { $Launcher = { param($record, $payload) Start-TikTokBackgroundJob $record $payload -PassThru } }
    if (-not $Verifier) { $Verifier = { param($row, $job, $proc) Get-TikTokSpreadSendResult -OutDir ([string]$job.Record.OutDir) -RequestId ([string]$job.Record.RequestId) -ExitCode $proc.ExitCode } }
    if (-not $HistoryReader) {
        $HistoryReader = {
            param($row)
            $m = Get-ReupMetadata -OutDir ([string]$row.Root)
            $p = $(if ($m) { $m.PSObject.Properties[[string]$row.Id] } else { $null })
            [pscustomobject]@{ History = @($(if ($p) { @($p.Value.History) | Where-Object { $_ } })); Posted = [bool]($p -and $p.Value.Posted); TransferActive = (Test-TikTokTransferActive ([string]$row.Path)) }
        }
    }
    $run = New-TikTokSpreadRun -Rows $Rows -Account $Account -Caption $Caption -Favorites $Favorites -Busy $Busy -Verifier $Verifier -HistoryReader $HistoryReader
    $script:spreadRun = @{ Run = $run; Launcher = $Launcher; AfterLaunch = { param($row, $job) Complete-SpreadLaunch $row $job }; Notified = @{}; Total = @($Rows).Count }
    Update-SpreadStatusUi -Text ('Đang gửi lịch 0/' + @($Rows).Count + '…') -Fraction 0
    if (-not $NoTimer) {
        if (-not $script:tSpread) {
            $script:tSpread = New-Object Windows.Threading.DispatcherTimer
            $script:tSpread.Interval = [TimeSpan]::FromMilliseconds(300)
            $script:tSpread.Add_Tick({
                try { Invoke-SpreadRunTick }
                catch { Write-FileLog "ERR  Invoke-SpreadRunTick: $($_.Exception.Message)`r`n$($_.ScriptStackTrace)" }
            })
        }
        $script:tSpread.Start()
    }
    return $run
}

function Show-TikTokSpreadDialog {
    # Rải lịch: nhiều video -> một tài khoản -> xem trước giờ hẹn -> "Hẹn N video" gửi TUẦN TỰ (mỗi lần một tiến trình con).
    # Đóng hộp thoại giữa chừng = dừng; video chưa gửi thì không gửi (không lưu hàng đợi qua lần mở sau).
    param([object[]]$Items, [string]$Account = '', $Owner = $null)
    $items = @($Items | Where-Object { $_ -and $_.Path })
    if (-not (Test-TikTokEnabled)) { Show-Toast 'Chưa kết nối bộ đăng TikTok.' -Kind warning; return }
    if ($script:stopping) { Show-Toast 'Đợi tác vụ hiện tại dừng hẳn trước khi đăng video.' -Kind warning; return }
    if (Test-SpreadRunActive) { Show-Toast 'Đang rải lịch — đợi xong hoặc bấm Dừng ở dải dưới cùng.' -Kind warning; return }
    if (-not $items.Count) { Show-Toast 'Chọn video trong Kho trước khi rải lịch.' -Kind warning; return }
    # Moi dong co thu muc kho rieng (lich su doc/ghi o do); gio ban, tran moi ngay va khoang cach tinh tren MOI kho cua tai khoan (S7).
    $roots = @($items | ForEach-Object { [IO.Path]::GetDirectoryName([IO.Path]::GetFullPath([string]$_.Path)) } | Select-Object -Unique)
    $markup = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation" xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml" Title="Rải lịch đăng TikTok" Width="760" Height="820" MinWidth="600" MinHeight="460" WindowStartupLocation="CenterOwner" ShowInTaskbar="False" Background="{DynamicResource Surface0}" Foreground="{DynamicResource TextPrimary}" FontFamily="{DynamicResource FontUi}" FontSize="15" Language="vi-VN">
 <Grid Margin="24"><Grid.RowDefinitions><RowDefinition Height="Auto"/><RowDefinition Height="*"/><RowDefinition Height="Auto"/></Grid.RowDefinitions>
 <StackPanel><TextBlock Text="Rải lịch đăng TikTok" Style="{DynamicResource TextHeading}" FontSize="25"/><TextBlock x:Name="Sub" Margin="0,5,0,14" TextWrapping="Wrap" Foreground="{DynamicResource TextMuted}"/></StackPanel>
 <ScrollViewer Grid.Row="1" VerticalScrollBarVisibility="Auto"><StackPanel Margin="0,0,10,0">
  <TextBlock Text="Chọn tài khoản đăng" FontWeight="ExtraBold"/>
  <WrapPanel x:Name="Accounts" Margin="0,8,0,12"/>
  <TextBlock x:Name="Hours" TextWrapping="Wrap" FontSize="12" Foreground="{DynamicResource TextMuted}" Margin="0,0,0,12"/>
  <TextBlock Text="Caption chung (tự điền cho mọi video chưa sửa caption riêng)" FontWeight="SemiBold"/>
  <TextBox x:Name="Caption" AcceptsReturn="True" TextWrapping="Wrap" MaxLength="2200" Height="92" VerticalScrollBarVisibility="Auto" Margin="0,6,0,14"/>
  <TextBlock Text="Xem trước giờ hẹn (mỗi video một khung giờ; sửa giờ hoặc caption riêng ngay trên từng dòng)" FontWeight="ExtraBold" TextWrapping="Wrap"/>
  <Border Background="{DynamicResource Surface1}" BorderBrush="{DynamicResource InkFaint}" BorderThickness="1" CornerRadius="16" Padding="10" Margin="0,8,0,8"><StackPanel x:Name="Rows"/></Border>
  <TextBlock x:Name="Summary" TextWrapping="Wrap" FontWeight="SemiBold"/>
 </StackPanel></ScrollViewer>
 <DockPanel Grid.Row="2" Margin="0,14,0,0">
  <WrapPanel DockPanel.Dock="Right" HorizontalAlignment="Right"><Button x:Name="Close" Content="Đóng" Margin="12,0,0,0" IsCancel="True"/><Button x:Name="Confirm" Content="Hẹn video" Style="{DynamicResource BtnPrimary}" IsEnabled="False" Margin="12,0,0,0"/></WrapPanel>
  <TextBlock x:Name="Status" Text="Đang kiểm tra tài khoản…" TextWrapping="Wrap" VerticalAlignment="Center" FontWeight="SemiBold"/>
 </DockPanel>
 </Grid>
</Window>
'@
    $dlg = [Windows.Markup.XamlReader]::Parse($markup); [void]$dlg.Resources.MergedDictionaries.Add((Get-DialogTheme))
    $ownerWin = if ($Owner) { $Owner } else { $win }
    if ($ownerWin -and $ownerWin.IsVisible) { $dlg.Owner = $ownerWin }
    $dlg.MaxHeight = [Math]::Max(460, [Windows.SystemParameters]::WorkArea.Height - 40)
    $c = @{}; foreach ($name in @('Sub', 'Accounts', 'Hours', 'Caption', 'Rows', 'Summary', 'Close', 'Confirm', 'Status')) { $c[$name] = $dlg.FindName($name) }
    $state = @{ Task = $null; Ready = $false; Native = $false; Account = ''; Prefs = (Read-TikTokPrefs); Libraries = @(); MetaByRoot = $null; PrepQueue = (New-Object System.Collections.Generic.Queue[string]); AccountsLoaded = $false; Rows = @(); Unplaced = 0; Chips = @(); Busy = @()
                Dirty = $false; Programmatic = $false; Rendering = $false; Replan = $null; Done = $false }
    try { $state.Libraries = @((Get-KhoRegistry).libraries) } catch { Write-FileLog ('WARN Rải lịch kho: ' + $_.Exception.Message) }
    $c.Sub.Text = $items.Count.ToString() + ' video đã chọn. Mỗi video được gửi lên TikTok lần lượt và hẹn đúng giờ trong bảng dưới; TikTok giữ bài và tự đăng.'

    $metaRead = Get-GalleryMetaChecked; $state.MetaByRoot = $metaRead.Map; $state.HistoryGap = $metaRead.Gap
    $rows = New-Object 'System.Collections.Generic.List[object]'
    foreach ($it in $items) {
        $hist = @(); $itemRoot = Get-CanonicalPath ([IO.Path]::GetDirectoryName([IO.Path]::GetFullPath([string]$it.Path)))
        $meta = $state.MetaByRoot[$itemRoot]
        if ($meta) { $p = $meta.PSObject.Properties[[string]$it.Id]; if ($p) { $hist = @(@($p.Value.History) | Where-Object { $_ }) } }
        $warn = Get-TikTokSpreadWarn -History $hist -Posted ([bool]$it.Posted)
        if (-not $warn -and (Test-TikTokTransferActive ([string]$it.Path))) { $warn = 'active' }
        $other = $null
        if ($warn -eq 'posted') {
            $ok = @($hist | Where-Object { [string]$_.status -eq 'succeeded' -and $_.publish_uncertain -ne $true -and [string]$_.username } | Select-Object -First 1)
            if ($ok.Count) { $other = '@' + [string]$ok[0].username }
        }
        $rows.Add([pscustomobject]@{ Id = [string]$it.Id; Path = [string]$it.Path; Root = $itemRoot; Kho = [string]$it.Kho; Warn = $warn; Include = ($warn -eq ''); When = $null; Other = $other; History = $hist; Caption = ''; CaptionEdited = $false; TimeEdited = $false; TimeBad = $false; TimeText = ''; TimeBox = $null; NoteBox = $null; CaptionBox = $null })
    }
    $state.Rows = $rows.ToArray()
    # Chiều rộng ô giờ: đo chữ "88/88 88:88" (ExtraBold, cỡ chữ hộp thoại) + đệm + viền + dư, để "dd/MM HH:mm" luôn hiện đủ ở mọi DPI (đơn vị WPF độc lập thiết bị).
    $ft = New-Object Windows.Media.FormattedText('88/88 88:88', [Globalization.CultureInfo]::GetCultureInfo('vi-VN'), [Windows.FlowDirection]::LeftToRight,
        (New-Object Windows.Media.Typeface($dlg.FontFamily, [Windows.FontStyles]::Normal, [Windows.FontWeights]::ExtraBold, [Windows.FontStretches]::Normal)), 15.0, [Windows.Media.Brushes]::Black, 1.0)
    $state.TimeBoxWidth = [Math]::Ceiling($ft.WidthIncludingTrailingWhitespace) + 20 + 4 + 14

    $updateConfirm = {
        $n = @($state.Rows | Where-Object { $_.When }).Count
        $c.Confirm.Content = 'Hẹn ' + $n + ' video'
        $c.Confirm.IsEnabled = ($state.Ready -and $state.Native -and $state.Account -and $n -gt 0 -and -not @($state.Rows | Where-Object { $_.Include -and $_.TimeBad }).Count -and -not $state.Done -and -not (Test-AutotokUpgradeActive))
    }.GetNewClosure()
    # D10: giờ và caption sửa được ở từng dòng. Sửa giờ chỉ kiểm tra lại CHÍNH dòng đó (giờ hợp lệ trong khoảng TikTok cho phép; cách bài khác / số bài mỗi ngày
    # chỉ là cảnh báo), không xếp lại các dòng khác. Giờ sai: viền đỏ, dòng không có giờ và nút Hẹn tắt.
    $state.RowWarning = {
        param($r)
        $others = @($state.Rows | Where-Object { $_ -ne $r -and $_.Include -and $_.When } | ForEach-Object { [DateTime]$_.When })
        return (Get-SpreadRowWarning -When ([DateTime]$r.When) -Others $others -Busy @($state.Busy))
    }.GetNewClosure()
    $state.TimeEdited = {
        param($s, $e)
        if ($state.Rendering) { return }
        $r = $s.Tag
        $p = ConvertFrom-SpreadTimeText -Text $s.Text
        $r.TimeEdited = $true; $r.TimeText = [string]$s.Text
        if ($p.Ok) {
            $r.When = $p.When; $r.TimeBad = $false; $s.ClearValue([Windows.Controls.Control]::BorderBrushProperty)
            $s.ToolTip = $null
            $r.NoteBox.Text = [string](& $state.RowWarning $r)
        } else {
            $r.When = $null; $r.TimeBad = $true; $s.BorderBrush = $dlg.FindResource('Danger'); $s.ToolTip = $p.Error
            $r.NoteBox.Text = $p.Error
        }
        & $updateConfirm
    }.GetNewClosure()
    $state.CaptionEdited = {
        param($s, $e)
        if ($state.Rendering -or $state.Programmatic) { return }
        $s.Tag.Caption = [string]$s.Text; $s.Tag.CaptionEdited = $true
        & $updateConfirm
    }.GetNewClosure()
    $render = {
        $state.Rendering = $true
        try {
            $c.Rows.Children.Clear()
            foreach ($r in $state.Rows) {
                $g = New-Object Windows.Controls.Grid
                foreach ($w in @(44, 190, 0, -1)) { $col = New-Object Windows.Controls.ColumnDefinition; $col.Width = $(if ($w -gt 0) { [Windows.GridLength]::new($w) } elseif ($w -eq 0) { [Windows.GridLength]::Auto } else { [Windows.GridLength]::new(1, [Windows.GridUnitType]::Star) }); [void]$g.ColumnDefinitions.Add($col) }
                $g.Margin = [Windows.Thickness]::new(0, 2, 0, 8)
                foreach ($hh in 1..2) { $rd = New-Object Windows.Controls.RowDefinition; $rd.Height = [Windows.GridLength]::Auto; [void]$g.RowDefinitions.Add($rd) }
                $cb = New-Object Windows.Controls.CheckBox; $cb.IsChecked = [bool]$r.Include; $cb.IsEnabled = ($r.Warn -ne 'active'); $cb.MinHeight = 32; $cb.VerticalAlignment = 'Center'; $cb.Tag = $r
                [Windows.Automation.AutomationProperties]::SetName($cb, 'Hẹn ' + (Get-ReelLabel $r.Id))
                $cb.Add_Click({
                    param($s, $e)
                    if ($state.Rendering) { return }
                    $s.Tag.Include = [bool]$s.IsChecked
                    & $state.Replan
                }.GetNewClosure())
                [Windows.Controls.Grid]::SetColumn($cb, 0); [void]$g.Children.Add($cb)
                $t1 = New-Object Windows.Controls.TextBlock; $t1.Text = (Get-ReelLabel $r.Id); $t1.VerticalAlignment = 'Center'; $t1.FontWeight = 'SemiBold'
                [Windows.Controls.Grid]::SetColumn($t1, 1); [void]$g.Children.Add($t1)
                $t2 = New-Object Windows.Controls.TextBox; $t2.MinHeight = 36; $t2.VerticalContentAlignment = 'Center'; $t2.FontWeight = 'ExtraBold'; $t2.Margin = [Windows.Thickness]::new(0, 0, 8, 0)
                $t2.Padding = [Windows.Thickness]::new(10, 6, 10, 6); $t2.MinWidth = $state.TimeBoxWidth   # đủ chỗ cho "dd/MM HH:mm" đầy đủ, không cuộn ngang
                $t2.Text = $(if ($r.When) { ([DateTime]$r.When).ToString('dd/MM HH:mm') } elseif ($r.TimeBad) { [string]$r.TimeText } else { '' }); $t2.Tag = $r; $t2.IsEnabled = ($r.Warn -ne 'active'); $t2.MaxLength = 12
                [Windows.Automation.AutomationProperties]::SetName($t2, 'Giờ hẹn ' + (Get-ReelLabel $r.Id) + ' (dd/MM HH:mm)')
                if ($r.TimeBad) { $t2.BorderBrush = $dlg.FindResource('Danger') }
                $t2.Add_TextChanged($state.TimeEdited)
                $r.TimeBox = $t2
                [Windows.Controls.Grid]::SetColumn($t2, 2); [void]$g.Children.Add($t2)
                $t3 = New-Object Windows.Controls.TextBlock; $t3.VerticalAlignment = 'Center'; $t3.TextWrapping = 'Wrap'; $t3.FontSize = 13; $t3.Foreground = $dlg.FindResource('TextMuted')
                $note = ''
                if ($r.Warn -eq 'active') { $note = 'Đang có lệnh đăng chờ/chạy — bỏ qua.' }
                elseif ($r.Warn -eq 'posted') { $note = 'Đã đăng' + $(if ($r.Other) { ' ở ' + $r.Other } else { '' }) + $(if ($r.Include) { ' — vẫn hẹn lại.' } else { ' — tick để vẫn hẹn.' }) }
                elseif ($r.Include -and -not $r.When) { $note = 'Quá 10 ngày — chưa có giờ (nhập giờ tay hoặc bỏ tick).' }
                $t3.Text = $note
                $r.NoteBox = $t3
                if ($r.Include -and $r.When -and -not $r.TimeBad -and $r.Warn -ne 'active') { $w0 = & $state.RowWarning $r; if ($w0) { $t3.Text = $w0 } }
                [Windows.Controls.Grid]::SetColumn($t3, 3); [void]$g.Children.Add($t3)
                $cap = New-Object Windows.Controls.TextBox; $cap.AcceptsReturn = $true; $cap.TextWrapping = 'Wrap'; $cap.MaxLength = 2200; $cap.MinHeight = 44; $cap.MaxHeight = 92; $cap.VerticalScrollBarVisibility = 'Auto'
                $cap.Margin = [Windows.Thickness]::new(0, 4, 0, 0); $cap.Text = [string]$r.Caption; $cap.Tag = $r; $cap.IsEnabled = ($r.Warn -ne 'active')
                [Windows.Automation.AutomationProperties]::SetName($cap, 'Caption ' + (Get-ReelLabel $r.Id))
                $cap.Add_TextChanged($state.CaptionEdited)
                $r.CaptionBox = $cap
                [Windows.Controls.Grid]::SetRow($cap, 1); [Windows.Controls.Grid]::SetColumn($cap, 1); [Windows.Controls.Grid]::SetColumnSpan($cap, 3); [void]$g.Children.Add($cap)
                [void]$c.Rows.Children.Add($g)
            }
        } finally { $state.Rendering = $false }
        $placed = @($state.Rows | Where-Object { $_.When }).Count
        $c.Summary.Text = $(if (-not $state.Account) { '' } else { $placed.ToString() + '/' + $items.Count + ' video có giờ hẹn' + $(if ($state.Unplaced -gt 0) { ' · Còn ' + $state.Unplaced + ' video chưa có giờ (quá 10 ngày)' } else { '' }) + '.' })
        & $updateConfirm
    }.GetNewClosure()
    $state.Replan = {
        if ($state.HistoryGap) { $metaRead = Get-GalleryMetaChecked; $state.MetaByRoot = $metaRead.Map; $state.HistoryGap = $metaRead.Gap }   # retry on every re-plan
        if ($state.HistoryGap) {
            # An unreadable kho history may hide a booking of this account: no automatic slots. Rows with a hand-typed time keep it.
            foreach ($r in $state.Rows) { if (-not $r.TimeEdited) { $r.When = $null } }
            $c.Status.Text = $state.HistoryGap + ' Chưa xếp giờ tự động; bạn vẫn có thể nhập giờ bằng tay (chưa kiểm tra trùng lịch).'
            & $render; return
        }
        if (-not $state.Account) { & $render; return }
        try {
            $key = $state.Account.ToLowerInvariant()
            $times = $(if ($state.Prefs.times.ContainsKey($key)) { $state.Prefs.times[$key] } else { $null })
            $state.Chips = @(Get-TikTokTimeChips $times)
            $slotLib = Get-KhoForAccount $state.Account
            if ($slotLib -and @($slotLib.slots).Count) { $state.Chips = @($slotLib.slots) }
            $state.Busy = @(Get-TikTokAccountBusyTimes -Account $state.Account -MetaByRoot $state.MetaByRoot)
            # Dòng đã sửa giờ bằng tay giữ nguyên giờ; chỉ các dòng còn lại được xếp quanh chúng.
            $kept = @($state.Rows | Where-Object { $_.TimeEdited -and $_.Include -and $_.Warn -ne 'active' })
            $free = @($state.Rows | Where-Object { $kept -notcontains $_ })
            $keptBusy = @($kept | Where-Object { $_.When } | ForEach-Object { [DateTime]$_.When })
            $state.Unplaced = Set-TikTokSpreadTimes -Rows $free -Favorites $state.Chips -Busy (@($state.Busy) + $keptBusy)
            $c.Hours.Text = 'Mỗi video một khung giờ, theo thứ tự, trong 10 ngày tới: ' + ($state.Chips -join ', ') + $(if ($slotLib -and @($slotLib.slots).Count) { ' (khung giờ đã đặt cho kho @' + $state.Account + ').' } else { ' (kho chưa đặt khung giờ: dùng giờ bạn hay đăng hoặc 08:00, 12:00, 19:00, 21:00).' })
            $c.Status.Text = ''
        } catch { Write-FileLog ('WARN Rải lịch xếp giờ: ' + $_.Exception.Message); $c.Status.Text = 'Không xếp được giờ: ' + $_.Exception.Message }
        & $render
    }.GetNewClosure()
    $c.Caption.Add_TextChanged({
        if (-not $state.Programmatic) { $state.Dirty = $true }
        # Caption chung = mẫu của mọi dòng chưa được sửa riêng.
        $text = [string]$c.Caption.Text
        $was = $state.Programmatic; $state.Programmatic = $true
        try { foreach ($r in $state.Rows) { if (-not $r.CaptionEdited) { $r.Caption = $text; if ($r.CaptionBox) { $r.CaptionBox.Text = $text } } } } finally { $state.Programmatic = $was }
        & $updateConfirm
    }.GetNewClosure())

    $setCaption = {
        if ($state.Dirty) { return }
        $template = Get-TikTokCaptionTemplate -Account $state.Account -VideoKhoId '' -Libraries $state.Libraries
        if (-not $template) { foreach ($r in $state.Rows) { $template = Get-TikTokCaptionTemplate -Account '' -VideoKhoId $r.Kho -Libraries $state.Libraries; if ($template) { break } } }
        if ($template -ne $c.Caption.Text) { $state.Programmatic = $true; try { $c.Caption.Text = $template } finally { $state.Programmatic = $false } }
    }.GetNewClosure()
    $accountChecked = {
        param($s, $e)
        $state.Account = [string]$s.Tag
        & $setCaption
        & $state.Replan
    }.GetNewClosure()

    $c.Close.Add_Click({ $dlg.Close() }.GetNewClosure())
    $tick = {
        if ($state.Task -and $state.Task.Async.IsCompleted) {
            $task = $state.Task; $state.Task = $null
            try {
                $result = Complete-TikTokTask $task
                $state.Native = [bool]$result.native_schedule
                if ($result.changed) { try { Update-Gallery } catch { Write-FileLog ('WARN Rải lịch làm mới kho: ' + $_.Exception.Message) } }
                $metaRead = Get-GalleryMetaChecked; $state.MetaByRoot = $metaRead.Map; $state.HistoryGap = $metaRead.Gap
                foreach ($r in $state.Rows) { Update-TikTokSpreadRowFromMeta -Row $r -Meta $state.MetaByRoot[[string]$r.Root] }
                if (-not $state.AccountsLoaded) {
                    $state.AccountsLoaded = $true
                    $c.Accounts.Children.Clear(); $group = 'SpreadAccount' + [Guid]::NewGuid().ToString('N')
                    $accounts = Select-TikTokReadyAccounts $result.accounts
                    foreach ($a in $accounts) {
                        $b = New-Object Windows.Controls.RadioButton; $b.Style = $dlg.FindResource('SegButton'); $b.GroupName = $group; $b.Content = '@' + $a.username; $b.Tag = [string]$a.username
                        $b.MinHeight = 48; $b.Padding = [Windows.Thickness]::new(16, 0, 16, 0); $b.Margin = [Windows.Thickness]::new(0, 0, 8, 8)
                        $b.Add_Checked($accountChecked); [void]$c.Accounts.Children.Add($b)
                    }
                    $state.Native = [bool]$result.native_schedule
                    $state.Ready = $true
                    if ($c.Accounts.Children.Count) {
                        $want = @(); if ($Account) { $want += $Account }
                        # Tai khoan cua kho: neu moi video nam trong cung mot kho co tai khoan thi chon san tai khoan do (S10).
                        $khoAccounts = @($state.Rows | ForEach-Object { $k = $_.Kho; @($state.Libraries | Where-Object { [string]$_.id -ceq $k } | ForEach-Object { [string]$_.account }) } | Select-Object -Unique)
                        if ($khoAccounts.Count -eq 1 -and $khoAccounts[0]) { $want += $khoAccounts[0] }
                        if ($state.Prefs.lastAccount) { $want += $state.Prefs.lastAccount }
                        $pre = $null
                        foreach ($w in $want) { $pre = @($c.Accounts.Children | Where-Object { $_.Tag -ieq $w })[0]; if ($pre) { break } }
                        if (-not $pre) { $pre = $c.Accounts.Children[0] }
                        $pre.IsChecked = $true
                        $c.Status.Text = $(if ($state.Native) { '' } else { 'Bộ đăng nền chưa hỗ trợ hẹn giờ trên TikTok. Cập nhật bộ đăng nền rồi khởi động lại.' })
                    } else { $c.Status.Text = (Get-TikTokNoReadyAccountsText $result.accounts) }
                }
                & $state.Replan
                # Con thu muc kho khac (video chon tu nhieu kho): lam moi lich su tung kho mot, roi xep lai.
                if ($state.PrepQueue.Count) {
                    try { $state.Task = Start-TikTokTask 'prepare' (Get-TikTokHistoryPayload ($state.PrepQueue.Dequeue())) }
                    catch { Write-FileLog ('WARN Rải lịch làm mới kho khác: ' + $_.Exception.Message) }
                }
            } catch { $c.Status.Text = $_.Exception.Message; Write-FileLog ('WARN Rải lịch chuẩn bị: ' + $_.Exception.Message); $state.Ready = $false }
        }
    }.GetNewClosure()
    $c.Confirm.Add_Click({
        try {
            if (-not $c.Confirm.IsEnabled) { return }
            if (Test-SpreadRunActive) { throw 'Đang có một lượt rải lịch chạy. Đợi xong hoặc bấm Dừng ở dải dưới cùng.' }
            if (Test-AutotokUpgradeActive) { throw 'Bộ đăng nền đang cập nhật. Đợi xong rồi thử lại.' }
            $cap = ([string]$c.Caption.Text).Trim()
            if (-not $state.Native) { throw 'Bộ đăng nền chưa hỗ trợ hẹn giờ trên TikTok. Cập nhật bộ đăng nền rồi khởi động lại.' }
            $planned = @($state.Rows | Where-Object { $_.When })
            if (-not $planned.Count) { throw 'Không có video nào có giờ hẹn.' }
            # Caption thực sự của mỗi dòng = caption riêng nếu có, không thì caption chung; dòng nào trống cả hai thì báo đúng dòng đó.
            $problem = Get-SpreadCaptionProblem -Rows $planned -Common $cap
            if ($problem) { throw $problem }
            foreach ($p in $planned) { $p.Caption = Get-SpreadEffectiveCaption -Row $p -Common $cap }
            # D9: hộp thoại đóng ngay; lượt gửi chạy nền (dải tiến trình ở dưới cùng, nút Dừng, toast khi có lỗi và khi xong).
            [void](Start-TikTokSpreadBackground -Rows $planned -Account $state.Account -Caption $cap -Favorites $state.Chips -Busy $state.Busy)
            $state.Done = $true
            $dlg.Close()
        } catch { $c.Status.Text = $_.Exception.Message; & $updateConfirm }
    }.GetNewClosure())
    $timer = New-Object Windows.Threading.DispatcherTimer; $timer.Interval = [TimeSpan]::FromMilliseconds(300)
    $timer.Add_Tick($tick)
    $dlg.Add_Closed({
        $timer.Stop()
        if ($state.Task) { Stop-TikTokTask $state.Task; $state.Task = $null }
    }.GetNewClosure())
    $c.Status.Text = 'Đang kiểm tra tài khoản…'
    & $render
    try {
        foreach ($r in @($roots | Select-Object -Skip 1)) { $state.PrepQueue.Enqueue([string]$r) }
        $state.Task = Start-TikTokTask 'prepare' (Get-TikTokHistoryPayload ([string]$roots[0]))
    } catch { $c.Status.Text = $_.Exception.Message; Write-FileLog ('WARN Rải lịch: ' + $_.Exception.Message) }
    $timer.Start()
    $script:khoExclusive++
    try { [void]$dlg.ShowDialog() } finally { $script:khoExclusive-- }
}

function Set-TikTokPostingUi {
    # D2: configured -> the preview button posts; copying stays in the More menu and on Ctrl+C.
    if (-not (Test-TikTokEnabled)) { return }
    $ui.TxtCopyLabel.Text = 'Đăng video'
    $ui.TxtCopyIcon.Text = [string][char]0xE898
    $ui.BtnCopyReup.ToolTip = 'Chọn tài khoản, nhập caption và đăng hoặc hẹn giờ lên TikTok'
    [Windows.Automation.AutomationProperties]::SetName($ui.BtnCopyReup, 'Đăng video lên TikTok')
    if ($ui.MenuMore) {
        $copy = New-Object Windows.Controls.MenuItem
        $copy.Header = 'Sao chép để đăng'; $copy.Tag = [string][char]0xE8C8; $copy.InputGestureText = 'Ctrl+C'
        $copy.ToolTip = 'Sao chép file vào clipboard để dán (Ctrl+V) khi đăng (Ctrl+C)'
        [Windows.Automation.AutomationProperties]::SetName($copy, 'Sao chép để đăng')
        $copy.Add_Click({ if ($script:lastOut) { Copy-ToClipboard $script:lastOut } })
        $ui.MenuMore.Items.Insert(0, $copy)
    }
}

$script:tikTok = Get-TikTokIntegration
Set-TikTokPostingUi

$win.Add_Closed({
    if ($script:tikTokSyncTimer) { $script:tikTokSyncTimer.Stop() }
    if ($script:autotokInstall) { $script:autotokInstall.Timer.Stop() }
    if ($script:tikTokSync -and $script:tikTokSync.Task) { Stop-TikTokTask $script:tikTokSync.Task; $script:tikTokSync.Task = $null }
    if ($script:tikTokSync -and $script:tikTokSync.Fast) { Stop-TikTokTask $script:tikTokSync.Fast; $script:tikTokSync.Fast = $null }
})

function Get-QueueStepState {
    # Trang thai buoc $N (1-7) cua mot dong: done | running | failed | pending (dung chung cho chuoi hat va the chi tiet).
    param([int]$N, [int]$Step, [string]$Status)
    if ($Status -eq 'ok') { return 'done' }
    if ($Step -gt 0 -and $N -lt $Step) { return 'done' }
    if ($Step -gt 0 -and $N -eq $Step) { if ($Status -in @('running', 'pending')) { return 'running' } else { return 'failed' } }
    return 'pending'
}

function Get-QueueBeadStates {
    param([int]$Step, [string]$Status)
    $list = New-Object 'System.Collections.Generic.List[string]'
    for ($n = 1; $n -le 7; $n++) { $list.Add((Get-QueueStepState -N $n -Step $Step -Status $Status)) }
    return ,$list.ToArray()
}

function Get-QueueRow {
    param([int]$QueueIdx)
    if (-not $script:queueRowByIdx.ContainsKey($QueueIdx)) { return $null }
    $pos = [int]$script:queueRowByIdx[$QueueIdx]
    if ($pos -lt 0 -or $pos -ge $script:queueRows.Count) { return $null }
    return $script:queueRows[$pos]
}

function Update-QueueRow {
    # PSCustomObject khong bao thay doi thuoc tinh: thay ca dong de ObservableCollection phat Replace.
    param([int]$QueueIdx, [hashtable]$Changes)
    $old = Get-QueueRow $QueueIdx
    if (-not $old) { return $null }
    $pos = [int]$script:queueRowByIdx[$QueueIdx]
    $p = @{ Index = $old.Index; QueueIdx = $old.QueueIdx; Url = $old.Url; Id = $old.Id; Status = $old.Status; Message = $old.Message; Step = $old.Step
            Video = $old.Video; SyncText = $old.SyncText; SyncWarn = $old.SyncWarn; ActionOverride = $old.ActionOverride
            Origin = $old.Origin; RedoFile = $old.RedoFile; Detail = $old.Detail }
    foreach ($k in $Changes.Keys) { $p[$k] = $Changes[$k] }
    $new = New-QueueRow @p
    $wasSelected = ($ui.QueueList -and [object]::ReferenceEquals($ui.QueueList.SelectedItem, $old))
    $script:queueRows[$pos] = $new
    if ($wasSelected) { $ui.QueueList.SelectedItem = $new }
    Update-StepPanel
    return $new
}

function Initialize-QueueRows {
    # Mot dong cho moi link se chay + dong "Bo qua" cho link da loai truoc / da co trong kho (Skipped: @{ Url; Message }).
    param([string[]]$Links, [object[]]$Skipped = @(), [string]$Origin = '', [string]$RedoFile = '')
    $script:queueRows.Clear()
    $script:queueRowByIdx = @{}
    $i = 0
    for ($q = 0; $q -lt @($Links).Count; $q++) {
        $i++
        $script:queueRowByIdx[$q] = $script:queueRows.Count
        $script:queueRows.Add((New-QueueRow -Index $i -Url ([string]$Links[$q]) -QueueIdx $q -Origin $Origin -RedoFile $RedoFile))
    }
    foreach ($s in @($Skipped)) {
        if (-not $s) { continue }
        $i++
        $script:queueRows.Add((New-QueueRow -Index $i -Url ([string]$s.Url) -Status 'skipped' -Message ([string]$s.Message)))
    }
    $script:queueTotal = @($Links).Count
    Update-QueueEmptyState
    Update-StepPanel
    Update-ActionBar
}

function Update-QueueEmptyState {
    if ($ui.QueueEmpty) { $ui.QueueEmpty.Visibility = $(if ($script:queueRows.Count) { 'Collapsed' } else { 'Visible' }) }
}

function Get-StepPanelRow {
    $row = if ($ui.QueueList) { $ui.QueueList.SelectedItem } else { $null }
    if ($row) { return $row }
    if ($script:mode -eq 'run' -and $script:queue -and @($script:queue).Count) { $row = Get-QueueRow $script:idx }
    if ($row) { return $row }
    for ($i = $script:queueRows.Count - 1; $i -ge 0; $i--) {
        if ($script:queueRows[$i].Status -ne 'pending' -and $script:queueRows[$i].QueueIdx -ge 0) { return $script:queueRows[$i] }
    }
    return $null
}

function Update-StepPanel {
    if (-not $ui.StepList) { return }
    $row = Get-StepPanelRow
    $step = if ($row) { [int]$row.Step } else { 0 }
    $status = if ($row) { [string]$row.Status } else { '' }
    $script:stepRows.Clear()
    for ($n = 1; $n -le 7; $n++) {
        $state = Get-QueueStepState -N $n -Step $step -Status $status
        $glyph = switch ($state) { 'done' { [string][char]0xE73E } 'running' { [string][char]0xE768 } 'failed' { [string][char]0xE711 } default { '' } }
        $detail = switch ($state) { 'done' { 'Xong' } 'running' { 'Đang chạy' } 'failed' { 'Dừng ở bước này' } default { 'Chưa tới' } }
        $edge = if ($n -eq 1) { 'first' } elseif ($n -eq 7) { 'last' } else { '' }
        $script:stepRows.Add([pscustomobject]@{ No = $n; NoText = "Bước $n"; Name = $script:stepNames[$n - 1]; State = $state; Glyph = $glyph; Detail = $detail; Edge = $edge })
    }
    if ($ui.TxtStepTitle) {
        $ui.TxtStepTitle.Text = if ($row) {
            $label = if ($row.Id) { "Reel #$($row.Id)" } else { [string]$row.Url }
            "$label · $($row.StatusText)" + $(if ($step -gt 0 -and $status -eq 'running') { " · bước $step/7" } else { '' })
        } else { 'Chi tiết các bước' }
    }
}

function Set-QueueStep {
    # Buoc engine 1-7 (@@KIDFBY_STAGE hoac dong "[n] ..." cua log) -> dong dang chay.
    param([int]$Step, [string]$Message = '')
    if ($Step -lt 1 -or $Step -gt 7) { return }
    $script:currentStep = $Step
    if ($script:mode -ne 'run') { return }
    $row = Get-QueueRow $script:idx
    if (-not $row -or $row.Status -ne 'running') { Update-ActionBar; return }
    $changes = @{ Step = [Math]::Max([int]$row.Step, $Step) }
    $changes.Message = $(if ($Message) { $Message } else { $script:stepNames[$Step - 1] + '…' })
    [void](Update-QueueRow -QueueIdx $script:idx -Changes $changes)
    Update-ActionBar
}

function Test-QueueRunning {
    # Nut chinh hien "Dung" khi co hang doi/sua lai/cai dat; kiem tra may nen luc khoi dong khong tinh.
    return [bool](($script:ps -and $script:mode -ne 'check') -or $script:stopping -or ($script:queue -and @($script:queue).Count -gt 0))
}

function Update-PrimaryButton {
    if (-not $ui.BtnStart) { return }
    $running = Test-QueueRunning
    try {
        if ($running) {
            $ui.BtnStart.Style = $win.FindResource('BtnDangerSolid')
            $ui.TxtStartLabel.Text = $(if ($script:stopping) { 'Đang dừng…' } else { '_Dừng' })
            $ui.TxtStartGlyph.Text = [string][char]0xE71A
            $ui.BtnStart.ToolTip = 'Dừng hàng đợi (Esc)'
        } else {
            $ui.BtnStart.Style = $win.FindResource('BtnPrimary')
            $ui.TxtStartLabel.Text = '_Bắt đầu'
            $ui.TxtStartGlyph.Text = [string][char]0xE768
            $ui.BtnStart.ToolTip = 'Bắt đầu xử lý danh sách link (Ctrl+Enter)'
        }
    } catch { Write-FileLog "WARN Update-PrimaryButton: $($_.Exception.Message)" }
    $ui.BtnStart.IsEnabled = -not $script:stopping
}

function Get-QueuePendingCount {
    # So muc chua chay (sau muc dang chay) trong hang doi hien tai.
    if ($script:mode -ne 'run' -or -not $script:queue) { return 0 }
    return [Math]::Max(0, @($script:queue).Count - [int]$script:idx - 1)
}

function Update-ActionBar {
    if (-not $ui.TxtProgress) { return }
    $total = [int]$script:queueTotal
    $done = if ($total -gt 0) { [Math]::Min($total, [Math]::Max(0, [int]$script:queueFinalizedIdx + 1)) } else { 0 }
    $ui.TxtProgress.Text = "$done/$total"
    $indeterminate = [bool]($script:ps -and $script:mode -in @('check', 'setup', 'reedit'))
    $ui.Bar.IsIndeterminate = $indeterminate
    $ui.Bar.Maximum = [double][Math]::Max(1, $total)
    $ui.Bar.Value = [double]$done

    $current = 'Sẵn sàng'
    $currentToken = 'TextMuted'
    if ($script:mode -eq 'run' -and $script:queue -and @($script:queue).Count) {
        $currentToken = 'TextPrimary'
        $row = Get-QueueRow $script:idx
        $label = if ($row -and $row.Id) { "Reel #$($row.Id)" } elseif ($row) { [string]$row.Url } else { "Video $($script:idx + 1)" }
        $stepNo = if ($row) { [int]$row.Step } else { 0 }
        $current = $label + $(if ($stepNo -gt 0) { " · bước $stepNo/7 · " + $script:stepNames[$stepNo - 1] } else { ' · đang khởi động' })
    } elseif ($script:ps -and $script:mode -eq 'check') { $current = 'Đang kiểm tra máy…' }
    elseif ($script:ps -and $script:mode -eq 'setup') { $current = 'Đang cài công cụ…' }
    elseif ($script:ps -and $script:mode -eq 'reedit') { $current = 'Đang sửa lại logo/GIF…' }
    elseif ($script:lastQueueEnd) {
        $current = $(if ($script:lastQueueEnd.Stopped) { 'Đã dừng lúc ' } else { 'Hoàn tất lúc ' }) + $script:lastQueueEnd.Time.ToString('HH:mm')
        $currentToken = $(if ($script:lastQueueEnd.Stopped) { 'WarningText' } else { 'SuccessText' })
    }
    $ui.TxtCurrentItem.Text = $current
    $ui.TxtCurrentItem.Foreground = Get-Brush $currentToken
    # Pill dem: Da luu (Mint) · Bi loai (Butter) · Chua xac nhan (Sky) · Bo qua (Lavender) · Loi (san ho).
    # Bang 0: KHONG lam mo pill; chu TextMuted + vien nhat. Cua so hep: chi hien so (nhan nam trong tooltip).
    if (-not $script:pillBorderOrig) { $script:pillBorderOrig = @{} }
    foreach ($pill in @(@($ui.PillSaved, $ui.TxtCountSaved, [int]$script:giu, 'đã lưu', 'Đã lưu'),
                        @($ui.PillRejected, $ui.TxtCountRejected, [int]$script:bo, 'bị loại', 'Bị loại (không có bản lồng tiếng Việt)'),
                        @($ui.PillUnverified, $ui.TxtCountUnverified, [int]$script:chuaXN, 'chưa xác nhận', 'Chưa xác nhận (chưa kiểm chứng được bản lồng tiếng; thử lại sau)'),
                        @($ui.PillSkipped, $ui.TxtCountSkipped, ([int]$script:boTruoc + [int]$script:skipExisting), 'bỏ qua', 'Bỏ qua (đã loại trước hoặc đã có trong kho)'),
                        @($ui.PillFailed, $ui.TxtCountFailed, [int]$script:loi, 'lỗi', 'Lỗi'))) {
        $active = ($pill[2] -gt 0)
        $n = [int]$pill[2]
        if ($pill[1]) {
            $pill[1].Text = $(if ($script:narrowBar) { "$n" } else { "$n $($pill[3])" })
            $pill[1].Foreground = Get-Brush $(if ($active) { 'TextPrimary' } else { 'TextMuted' })
            $pill[1].FontWeight = $(if ($active) { [Windows.FontWeights]::ExtraBold } else { [Windows.FontWeights]::Bold })
        }
        if ($pill[0]) {
            if (-not $script:pillBorderOrig.ContainsKey($pill[0].Name)) { $script:pillBorderOrig[$pill[0].Name] = $pill[0].BorderBrush }
            $pill[0].BorderBrush = $(if ($active) { $script:pillBorderOrig[$pill[0].Name] } else { Get-Brush 'InkFaint' })
            $pill[0].ToolTip = "$n $($pill[3]) — $($pill[4])"
            [Windows.Automation.AutomationProperties]::SetName($pill[0], "$n $($pill[3])")
        }
    }
    Update-PrimaryButton
}

# ------------------------------------------------------------- dieu huong trang ----
$script:pageViews = [ordered]@{ source = 'ViewSource'; brand = 'ViewBrand'; queue = 'ViewQueue'; library = 'ViewLibrary'; settings = 'ViewSettings' }
$script:pageNavs  = @{ source = 'NavSource'; brand = 'NavBrand'; queue = 'NavQueue'; library = 'NavLibrary'; settings = 'NavSettings' }

$script:compactLayout = $false   # chieu cao logic < 640 px (man hinh thap / zoom 125-150%)
$script:previewBig = $false      # che do "Xem lon": an trang ben trai, video chiem ca than
$script:previewColWidth = 0.0
$script:pauseOnOpenPos = [TimeSpan]::Zero   # vi tri dat lai khi mo xong nguon moi o trang thai tam dung (hien khung hinh dau, khong den)

function Get-BodyHeight {
    # Chieu cao "than" = khach - thanh tieu de (48) - dai day (card + le).
    $rootH = if ($ui.RootGrid -and $ui.RootGrid.ActualHeight -gt 0) { [double]$ui.RootGrid.ActualHeight } elseif ($win.ActualHeight -gt 0) { [double]$win.ActualHeight } else { 720.0 }
    $barH = if ($ui.ActionBar -and $ui.ActionBar.ActualHeight -gt 0) { [double]$ui.ActionBar.ActualHeight + 8.0 } else { 72.0 }
    # Dải rải lịch nền (chỉ hiện khi đang gửi) nằm ngay trên dải hành động và lấy bớt chiều cao thân trang.
    if ($ui.SpreadBar -and $ui.SpreadBar.Visibility -eq 'Visible' -and $ui.SpreadBar.ActualHeight -gt 0) { $barH += [double]$ui.SpreadBar.ActualHeight + 8.0 }
    return [Math]::Max(0.0, $rootH - 48.0 - $barH)
}

function Set-CompactLayout {
    # V3: o man hinh thap sidebar thu nho (nut 64, cham 44), an trang tri, an dai chinh sach; Hang doi thu buoc thanh 1 dong cham.
    param([bool]$On)
    $script:compactLayout = $On
    $win.Resources['NavDot'] = $(if ($On) { 40.0 } else { 59.0 })
    $win.Resources['NavBtnW'] = $(if ($On) { 88.0 } else { 92.0 })
    $win.Resources['NavBtnH'] = $(if ($On) { 64.0 } else { 90.0 })
    $win.Resources['NavGlyph'] = $(if ($On) { 17.0 } else { 22.0 })
    $win.Resources['NavFont'] = $(if ($On) { 13.0 } else { 14.0 })
    $win.Resources['NavLabelGap'] = $(if ($On) { 1.0 } else { 5.0 })
    $win.Resources['NavMargin'] = [Windows.Thickness]::new(0)
    if ($ui.ColSidebar) { $ui.ColSidebar.Width = [Windows.GridLength]::new($(if ($On) { 92.0 } else { 96.0 })) }
    $vis = $(if ($On) { 'Collapsed' } else { 'Visible' })
    foreach ($n in @('SidebarDeco', 'PolicyStrip', 'TxtGalleryCount', 'WashiLeft', 'WashiRight')) { if ($ui[$n]) { $ui[$n].Visibility = $vis } }
    try { Update-StepListTemplate } catch { Write-FileLog "WARN Update-StepListTemplate: $($_.Exception.Message)" }
}

function Update-PreviewColumn {
    $show = $script:currentPage -in @('brand', 'library')
    if ($script:previewBig -and -not $show) { $script:previewBig = $false; if ($ui.PageHost) { $ui.PageHost.Visibility = 'Visible' } }
    $big = ($show -and $script:previewBig)
    $bodyH = Get-BodyHeight
    $deco = $(if ($script:compactLayout) { 0.0 } else { 24.0 })
    # Hv = than - 14 (le) - deco - 56 (hang nut) - 8 (vien + bong)
    $hv = [Math]::Max(0.0, $bodyH - 14.0 - $deco - 56.0 - 8.0)
    $sidebarW = $(if ($script:compactLayout) { 92.0 } else { 96.0 })
    $winW = $(if ($ui.RootGrid -and $ui.RootGrid.ActualWidth -gt 0) { [double]$ui.RootGrid.ActualWidth } elseif ($win.ActualWidth -gt 0) { [double]$win.ActualWidth } else { 1440.0 })
    $cap = [Math]::Max(300.0, 0.42 * ($winW - $sidebarW))
    $width = [Math]::Min([Math]::Max([Math]::Round($hv * 9.0 / 16.0) + 28.0 + 16.0, 300.0), $cap)
    $tooSmall = ($hv -lt 60.0 -and -not $big)
    $script:previewColWidth = $width
    # Trang tri 24 px tren khung video: an o man hinh thap va o che do Xem lon (nhuong cho video).
    $showDeco = (-not $script:compactLayout -and -not $big)
    if ($ui.RowPreviewDeco) { $ui.RowPreviewDeco.Height = [Windows.GridLength]::new($(if ($showDeco) { 24.0 } else { 0.0 })) }
    if ($ui.PreviewDeco) { $ui.PreviewDeco.Visibility = $(if ($showDeco) { 'Visible' } else { 'Collapsed' }) }
    if ($ui.ColPage) { $ui.ColPage.Width = [Windows.GridLength]::new($(if ($big) { 0.0 } else { 1.0 }), $(if ($big) { [Windows.GridUnitType]::Pixel } else { [Windows.GridUnitType]::Star })) }
    if ($ui.ColPreview) {
        $ui.ColPreview.Width = $(if (-not $show -or $tooSmall) { [Windows.GridLength]::new(0.0) } elseif ($big) { [Windows.GridLength]::new(1.0, [Windows.GridUnitType]::Star) } else { [Windows.GridLength]::new($width) })
    }
    if ($ui.PageHost) { $ui.PageHost.Visibility = $(if ($big) { 'Collapsed' } else { 'Visible' }) }
    # Xem lon: hang nut duoi video khong gian het be ngang (gioi han + can giua).
    if ($ui.PanelRev) {
        $ui.PanelRev.MaxWidth = $(if ($big) { 520.0 } else { [double]::PositiveInfinity })
        $ui.PanelRev.HorizontalAlignment = $(if ($big) { [Windows.HorizontalAlignment]::Center } else { [Windows.HorizontalAlignment]::Stretch })
    }
    if ($ui.PreviewPane) { $ui.PreviewPane.Visibility = $(if ($show -and -not $tooSmall) { 'Visible' } else { 'Collapsed' }) }
    if ($ui.BtnPreviewExpand) {
        $ui.BtnPreviewExpand.Content = [string][char]$(if ($big) { 0xE73F } else { 0xE740 })
        $ui.BtnPreviewExpand.ToolTip = $(if ($big) { 'Thu nhỏ (Esc hoặc F)' } else { 'Xem lớn (F)' })
        [Windows.Automation.AutomationProperties]::SetName($ui.BtnPreviewExpand, $(if ($big) { 'Thu nhỏ khung xem trước' } else { 'Xem lớn' }))
    }
    # Toast o goc DUOI phai, ngay tren dai day; co cot xem truoc thi dich sang trai cot do (khong che nut duoi video).
    if ($ui.NotificationHost) { $ui.NotificationHost.Margin = [Windows.Thickness]::new(0, 0, $(if ($show -and -not $big -and -not $tooSmall) { $width + 16.0 } else { 24.0 }), 88.0) }
    if ($show) { [void]$win.Dispatcher.BeginInvoke([Action]{ Update-PhoneFrameSize; Update-WatermarkOverlay }, [Windows.Threading.DispatcherPriority]::Loaded) }
}

function Set-PreviewBig {
    # Che do "Xem lon" (nut ⤢, phim F, nhap dup the Kho; Esc thoat): chi co nghia o trang Thuong hieu / Kho.
    param([bool]$On)
    if ($On -and -not (Test-PreviewPageVisible)) { return }
    if ($On -eq $script:previewBig) { return }
    $script:previewBig = $On
    Update-PreviewColumn
    [void]$win.Dispatcher.BeginInvoke([Action]{ Update-PhoneFrameSize; Update-WatermarkOverlay }, [Windows.Threading.DispatcherPriority]::Loaded)
}

function Show-SettingsSection {
    param([ValidateSet('tools', 'general', 'logs', 'update', 'about')][string]$Name)
    $map = @{ tools = @('ViewTools', 'SetTabTools'); general = @('ViewGeneral', 'SetTabGeneral'); logs = @('ViewLogs', 'SetTabLogs'); update = @('ViewUpdate', 'SetTabUpdate'); about = @('ViewAbout', 'SetTabAbout') }
    $script:switchingPage = $true
    try {
        foreach ($k in $map.Keys) {
            $ui[$map[$k][0]].Visibility = $(if ($k -eq $Name) { 'Visible' } else { 'Collapsed' })
            $ui[$map[$k][1]].IsChecked = ($k -eq $Name)
        }
    } finally { $script:switchingPage = $false }
    if ($Name -eq 'logs') { Flush-LogBatch; if ($ui.TxtLogPath) { $ui.TxtLogPath.Text = Get-GuiLogPath } }
    if ($Name -eq 'general') { Update-CacheInfo }
    Invoke-PageEnterAnimation $ui[$map[$Name][0]]
}

function Invoke-PageEnterAnimation {
    # Chuyen trang: hien dan + truot len 8 px trong 160 ms (khong lam doi bo cuc).
    param($Element)
    if (-not $Element -or $SelfTest) { return }
    try {
        $tt = $Element.RenderTransform -as [Windows.Media.TranslateTransform]
        if (-not $tt -or $tt.IsFrozen) { $tt = New-Object Windows.Media.TranslateTransform; $Element.RenderTransform = $tt }
        $dur = [Windows.Duration]::new([TimeSpan]::FromMilliseconds(160))
        $ease = New-Object Windows.Media.Animation.CubicEase
        $ease.EasingMode = 'EaseOut'
        $fade = New-Object Windows.Media.Animation.DoubleAnimation(0.0, 1.0, $dur)
        $fade.EasingFunction = $ease
        $slide = New-Object Windows.Media.Animation.DoubleAnimation(8.0, 0.0, $dur)
        $slide.EasingFunction = $ease
        $Element.BeginAnimation([Windows.UIElement]::OpacityProperty, $fade)
        $tt.BeginAnimation([Windows.Media.TranslateTransform]::YProperty, $slide)
    } catch { Write-FileLog "WARN Invoke-PageEnterAnimation: $($_.Exception.Message)" }
}

function Suspend-PreviewPlayback {
    # G-R2: roi trang co khung xem truoc (Thuong hieu/Kho) -> tam dung, khong phat tieng khi khung bi an.
    try {
        if ($ui.Player -and $ui.Player.Source -and $ui.BtnPlay -and [string]$ui.BtnPlay.Content -eq 'Tạm dừng') {
            $ui.Player.Pause()
            $ui.BtnPlay.Content = 'Phát'
        }
    } catch { Write-FileLog "WARN Suspend-PreviewPlayback: $($_.Exception.Message)" }
}

function Test-PreviewPageVisible {
    return ($script:currentPage -in @('brand', 'library'))
}

function Enter-OverlayEditMode {
    # Video hoan chinh (-3) da nung logo/GIF nen khong keo duoc: dung video goc sach (-1) neu con; khong con thi bao ro ly do.
    if ($script:ps -or $script:previewingClean) { return }
    if (-not $script:lastOut -or -not (Test-Path -LiteralPath $script:lastOut)) { return }
    if ($script:lastOut -notmatch '-3-hoan-chinh\.mp4$') { return }
    $clean = $null
    try { $clean = Get-ReelCompanionPath -VideoPath $script:lastOut -Kind source } catch { Write-FileLog "WARN Enter-OverlayEditMode: $($_.Exception.Message)" }
    if ($clean) {
        Enter-CleanPreviewMode
        if ($script:previewingClean) { $script:autoCleanFromBrand = $true }
    } elseif ($ui.BadgePreviewMode) {
        $ui.TxtPreviewMode.Text = 'Video này đã gắn logo; không còn bản gốc để chỉnh vị trí'
        $ui.BadgePreviewMode.Visibility = 'Visible'
    }
}

function Show-Page {
    param([ValidateSet('source', 'brand', 'queue', 'library', 'settings')][string]$Name, [string]$Sub = '')
    $previous = $script:currentPage
    if ($script:previewBig) { $script:previewBig = $false }   # doi trang -> thoat "Xem lon"
    $script:switchingPage = $true
    try {
        foreach ($k in $script:pageViews.Keys) {
            $ui[$script:pageViews[$k]].Visibility = $(if ($k -eq $Name) { 'Visible' } else { 'Collapsed' })
            $ui[$script:pageNavs[$k]].IsChecked = ($k -eq $Name)
        }
    } finally { $script:switchingPage = $false }
    $script:currentPage = $Name
    if ($previous -in @('brand', 'library') -and $Name -notin @('brand', 'library')) { Suspend-PreviewPlayback }
    if ($previous -ne $Name) { Invoke-PageEnterAnimation $ui[$script:pageViews[$Name]] }
    Update-PreviewColumn
    # Video truoc do da bi xoa khoi dia -> xoa trang khung xem truoc.
    if ($script:lastOut -and -not (Test-Path -LiteralPath $script:lastOut)) { Clear-Player }
    # V12: o trang Thuong hieu luon hien khung keo logo/GIF tren video dang xem (chuyen sang video goc sach de keo duoc);
    # roi trang Thuong hieu sang Kho thi tra lai video hoan chinh.
    if ($Name -eq 'brand') { Enter-OverlayEditMode }
    elseif ($previous -eq 'brand' -and $script:autoCleanFromBrand) { $script:autoCleanFromBrand = $false; Exit-CleanPreviewMode }
    if ($Name -ne 'brand' -and -not $script:previewingClean -and $ui.BadgePreviewMode) { $ui.BadgePreviewMode.Visibility = 'Collapsed' }
    switch ($Name) {
        'library'  { Update-Gallery }
        'settings' { Update-ToolsStatus; if ($Sub) { Show-SettingsSection $Sub } }
        'queue'    { Update-QueueEmptyState; Update-StepPanel }
    }
}

# ------------------------------------------------------------- thong bao + hop thoai theo theme ----
function Get-FriendlyError {
    # Loi .NET/IO (tieng Anh) -> cau tieng Viet de hieu. Chi tiet goc luon nam trong log / nut "Chi tiet".
    param([string]$Message)
    $m = ([string]$Message).Trim()
    if (-not $m) { return 'Lỗi không rõ' }
    $inner = [regex]::Replace($m, '^Exception calling "[^"]*" with "?\d*"? argument\(s\):\s*"?', '').TrimEnd('"')
    if ($inner) { $m = $inner }
    switch -Regex ($m) {
        'being used by another process|sharing violation' { return 'File đang được ứng dụng khác mở — đóng nó rồi thử lại' }
        'Access to the path|UnauthorizedAccess|Access is denied|is denied' { return 'Không có quyền truy cập file hoặc thư mục này' }
        'Could not find (a part of the path|file|a part)|Cannot find (path|file)|does not exist|DirectoryNotFound|FileNotFound' { return 'Không tìm thấy file hoặc thư mục' }
        'not enough space|disk is full|There is not enough space' { return 'Ổ đĩa không còn đủ chỗ trống' }
        'path, file name, or both are too long|PathTooLong' { return 'Đường dẫn quá dài' }
        'network path|network name|network is' { return 'Không truy cập được đường dẫn mạng' }
        'Illegal characters|invalid characters|not a legal|Invalid path' { return 'Đường dẫn chứa ký tự không hợp lệ' }
        'timed out|timeout' { return 'Quá thời gian chờ' }
    }
    return $m
}

$script:toastOverflow = 0
function Update-ToastMoreChip {
    # Chip "+N" khi co thong bao cu bi gop (toi da 2 the hien cung luc); het the thi xoa chip.
    $hostPanel = $ui.NotificationHost
    if (-not $hostPanel) { return }
    $more = $hostPanel.Children | Where-Object { $_.Name -eq 'ToastMore' } | Select-Object -First 1
    $toastCount = @($hostPanel.Children | Where-Object { $_.Name -ne 'ToastMore' }).Count
    if ($toastCount -eq 0) { $script:toastOverflow = 0 }
    if ($script:toastOverflow -le 0) { if ($more) { $hostPanel.Children.Remove($more) }; return }
    if (-not $more) {
        $txt = New-Object Windows.Controls.TextBlock
        $txt.FontSize = 13; $txt.FontWeight = [Windows.FontWeights]::Bold; $txt.Foreground = Get-Brush 'TextPrimary'
        $more = New-Object Windows.Controls.Border
        $more.Name = 'ToastMore'; $more.Child = $txt
        $more.CornerRadius = [Windows.CornerRadius]::new(15); $more.Height = 30; $more.BorderThickness = [Windows.Thickness]::new(2)
        $more.BorderBrush = Get-Brush 'Ink'; $more.Background = Get-Brush 'ButterSoft'
        $more.Padding = [Windows.Thickness]::new(12, 0, 12, 0); $txt.VerticalAlignment = 'Center'; $more.Margin = [Windows.Thickness]::new(0, 8, 8, 0)
        $more.HorizontalAlignment = 'Right'
        $hostPanel.Children.Insert(0, $more)
    }
    $more.Child.Text = "+$($script:toastOverflow) thông báo trước"
}
function Remove-Toast {
    param($Toast)
    if ($ui.NotificationHost) { $ui.NotificationHost.Children.Remove($Toast) }
    Update-ToastMoreChip
}

function Show-Toast {
    # Kind: info | success | warning | error. Loi giu den khi nguoi dung dong; con lai tu tat sau 4 s.
    # The sticker trang vien nau; chip tron mau theo loai (Sky/Mint/Butter/san ho); thanh cong co ngoi sao lap lanh.
    param([string]$Message, [ValidateSet('info', 'success', 'warning', 'error')][string]$Kind = 'info')
    try {
        Write-FileLog "TOAST $Kind $Message"
        $hostPanel = $ui.NotificationHost
        if (-not $hostPanel) { return }
        $token = switch ($Kind) { 'success' { 'Success' } 'warning' { 'Warning' } 'error' { 'Danger' } default { 'Info' } }
        $glyph = switch ($Kind) { 'success' { 0xE73E } 'warning' { 0xE7BA } 'error' { 0xEA39 } default { 0xE946 } }
        $toastXaml = @'
<Grid xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation" xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml" Margin="0,12,0,0">
  <Border Margin="4,4,0,0" CornerRadius="18" Background="{DynamicResource StickerShadow}"/>
  <Border x:Name="Card" Margin="0,0,4,4" CornerRadius="18" Background="{DynamicResource Surface1}" BorderBrush="{DynamicResource Ink}" BorderThickness="2" Padding="12,10,8,10">
    <Grid>
      <Grid.ColumnDefinitions><ColumnDefinition Width="Auto"/><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
      <Border x:Name="Chip" Width="38" Height="38" CornerRadius="19" BorderBrush="{DynamicResource Ink}" BorderThickness="2" VerticalAlignment="Top" Margin="0,0,12,0">
        <TextBlock x:Name="Glyph" FontFamily="{DynamicResource FontIcon}" FontSize="15" HorizontalAlignment="Center" VerticalAlignment="Center" Foreground="{DynamicResource TextPrimary}"/>
      </Border>
      <TextBlock x:Name="Msg" Grid.Column="1" TextWrapping="Wrap" TextTrimming="CharacterEllipsis" MaxHeight="42" FontSize="14" FontWeight="SemiBold" LineHeight="20" VerticalAlignment="Center" Foreground="{DynamicResource TextPrimary}"/>
      <Button x:Name="Close" Grid.Column="2" Style="{DynamicResource BtnIcon}" Width="44" Height="44" FontSize="11" VerticalAlignment="Top" Margin="4,-8,-6,-8"
              ToolTip="Đóng thông báo"/>
    </Grid>
  </Border>
  <Image x:Name="Deco" Source="{DynamicResource DecoSparkles}" Width="32" Height="26" HorizontalAlignment="Right" VerticalAlignment="Top" Margin="0,-14,46,0" Visibility="Collapsed" IsHitTestVisible="False"/>
</Grid>
'@
        $toast = [Windows.Markup.XamlReader]::Parse($toastXaml)
        $card = $toast.FindName('Card')
        $chip = $toast.FindName('Chip')
        $chip.Background = Get-Brush $token
        $toast.FindName('Glyph').Text = [string][char]$glyph
        $toast.FindName('Msg').Text = $Message
        $toast.FindName('Msg').ToolTip = $Message   # day du trong tooltip khi bi cat o 2 dong
        if ($Kind -eq 'success') { $toast.FindName('Deco').Visibility = 'Visible' }
        $close = $toast.FindName('Close')
        $close.Content = [string][char]0xE8BB
        [Windows.Automation.AutomationProperties]::SetName($close, 'Đóng thông báo')
        $toast.Tag = $Kind
        $card.Tag = $Kind
        [Windows.Automation.AutomationProperties]::SetName($toast, $Message)
        $close.Add_Click({ Remove-Toast $toast }.GetNewClosure())
        [void]$hostPanel.Children.Add($toast)
        # Toi da 2 the; the cu hon gop vao chip "+N".
        $shown = @($hostPanel.Children | Where-Object { $_.Name -ne 'ToastMore' })
        while ($shown.Count -gt 2) {
            $hostPanel.Children.Remove($shown[0]); $script:toastOverflow++
            $shown = @($hostPanel.Children | Where-Object { $_.Name -ne 'ToastMore' })
        }
        Update-ToastMoreChip
        if (-not $SelfTest) {
            try {
                $tt = New-Object Windows.Media.TranslateTransform
                $toast.RenderTransform = $tt
                $dur = [Windows.Duration]::new([TimeSpan]::FromMilliseconds(180))
                $toast.BeginAnimation([Windows.UIElement]::OpacityProperty, (New-Object Windows.Media.Animation.DoubleAnimation(0.0, 1.0, $dur)))
                $tt.BeginAnimation([Windows.Media.TranslateTransform]::XProperty, (New-Object Windows.Media.Animation.DoubleAnimation(18.0, 0.0, $dur)))
            } catch { Write-FileLog "WARN toast animation: $($_.Exception.Message)" }
        }
        if ($Kind -ne 'error') {
            $toastTimer = New-Object Windows.Threading.DispatcherTimer
            $toastTimer.Interval = [TimeSpan]::FromSeconds(4)
            $toastTimer.Add_Tick({ $toastTimer.Stop(); Remove-Toast $toast }.GetNewClosure())
            $toastTimer.Start()
        }
        $script:lastToast = $toast
    } catch {
        Write-FileLog "WARN Show-Toast: $($_.Exception.Message)"
    }
}

function Get-DialogTheme {
    # Hop thoai la cua so rieng: can mot ban theme rieng (khong dung chung instance voi cua so chinh).
    if (-not $script:dialogTheme) {
        $script:dialogTheme = Read-KidXamlFile 'Theme.xaml'
        [void](Set-KidFontResources $script:dialogTheme)
    }
    return $script:dialogTheme
}

function New-ConfirmDialog {
    # Hop thoai sticker: linh vat dam may, tieu de ExtraBold, nut tron; nut mac dinh = Huy (Enter/Esc).
    # -Choices: them danh sach lua chon dang nut tron radio (lua chon dau tien duoc chon san).
    param([string]$Title, [string]$Message, [string]$ConfirmText = 'Đồng ý', [string]$CancelText = 'Hủy',
          [switch]$Danger, [switch]$OkOnly, [ValidateSet('warning', 'info', 'error')][string]$Kind = 'warning',
          [string[]]$Choices = @(), [int]$ChoiceDefault = 0)
    $dialogXaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation" xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        WindowStyle="None" AllowsTransparency="True" Background="Transparent" ResizeMode="NoResize" SizeToContent="WidthAndHeight"
        ShowInTaskbar="False" WindowStartupLocation="CenterOwner" FontFamily="{DynamicResource FontUi}" FontSize="15"
        Foreground="{DynamicResource TextPrimary}" TextOptions.TextFormattingMode="Display">
  <Grid Margin="18">
    <Border Margin="6,6,0,0" CornerRadius="24" Background="{DynamicResource StickerShadow}"/>
    <Border x:Name="DlgCard" Margin="0,0,6,6" Background="{DynamicResource Surface1}" BorderBrush="{DynamicResource InkStrong}" BorderThickness="2.5" CornerRadius="24"
            Padding="26,22,26,22" Width="520">
      <StackPanel>
        <DockPanel>
          <Grid DockPanel.Dock="Left" Width="76" Height="64" Margin="0,0,14,0" VerticalAlignment="Top">
            <Image Source="{DynamicResource MascotCloud}" Width="72" Height="57" VerticalAlignment="Bottom" HorizontalAlignment="Left"/>
            <Border x:Name="DlgChip" Width="30" Height="30" CornerRadius="15" BorderBrush="{DynamicResource Ink}" BorderThickness="2" HorizontalAlignment="Right" VerticalAlignment="Top">
              <TextBlock x:Name="DlgGlyph" Style="{DynamicResource Icon}" FontSize="13" Foreground="{DynamicResource TextPrimary}"/>
            </Border>
          </Grid>
          <TextBlock x:Name="DlgTitle" Style="{DynamicResource TextHeading}" FontSize="22" VerticalAlignment="Center" TextWrapping="Wrap"/>
        </DockPanel>
        <ScrollViewer MaxHeight="340" VerticalScrollBarVisibility="Auto" Margin="0,14,0,0">
          <TextBlock x:Name="DlgMessage" Style="{DynamicResource TextBody}" FontSize="15" LineHeight="23" Foreground="{DynamicResource TextPrimary}"/>
        </ScrollViewer>
        <StackPanel x:Name="DlgChoices" Margin="0,14,0,0" Visibility="Collapsed"/>
        <StackPanel Orientation="Horizontal" HorizontalAlignment="Right" Margin="0,22,0,0">
          <Button x:Name="DlgCancel" MinWidth="120" Margin="0,0,10,0" IsCancel="True" IsDefault="True"/>
          <Button x:Name="DlgOk" MinWidth="120"/>
        </StackPanel>
      </StackPanel>
    </Border>
  </Grid>
</Window>
'@
    $dlg = [Windows.Markup.XamlReader]::Parse($dialogXaml)
    [void]$dlg.Resources.MergedDictionaries.Add((Get-DialogTheme))
    $glyphText = $dlg.FindName('DlgGlyph')
    $glyphText.Text = [string][char]$(switch ($Kind) { 'info' { 0xE946 } 'error' { 0xEA39 } default { 0xE7BA } })
    $dlg.FindName('DlgChip').Background = $dlg.FindResource($(switch ($Kind) { 'info' { 'Info' } 'error' { 'Danger' } default { 'Warning' } }))
    $dlg.FindName('DlgTitle').Text = $Title
    $dlg.FindName('DlgMessage').Text = $Message
    $dlg.Title = $Title
    $ok = $dlg.FindName('DlgOk'); $cancel = $dlg.FindName('DlgCancel')
    $ok.Content = $ConfirmText
    $cancel.Content = $CancelText
    $ok.Style = $dlg.FindResource($(if ($Danger) { 'BtnDangerSolid' } else { 'BtnPrimary' }))
    [Windows.Automation.AutomationProperties]::SetName($ok, $ConfirmText)
    [Windows.Automation.AutomationProperties]::SetName($cancel, $CancelText)
    $choicePanel = $dlg.FindName('DlgChoices')
    $choiceButtons = New-Object System.Collections.ArrayList
    if (@($Choices).Count) {
        $choicePanel.Visibility = 'Visible'
        $group = 'DlgChoice' + [Guid]::NewGuid().ToString('N').Substring(0, 6)
        for ($ci = 0; $ci -lt @($Choices).Count; $ci++) {
            $rb = New-Object Windows.Controls.RadioButton
            $rb.GroupName = $group
            $rb.Content = [string]$Choices[$ci]
            $rb.Margin = [Windows.Thickness]::new(0, 0, 0, 10)
            $rb.Tag = $ci
            $rb.IsChecked = ($ci -eq $ChoiceDefault)
            [Windows.Automation.AutomationProperties]::SetName($rb, [string]$Choices[$ci])
            [void]$choicePanel.Children.Add($rb)
            [void]$choiceButtons.Add($rb)
        }
    }
    $dlg.Tag = $choiceButtons
    if ($OkOnly) {
        # Chi mot nut: van an toan vi khong co hanh dong pha huy.
        $cancel.Visibility = 'Collapsed'
        $ok.IsDefault = $true; $ok.IsCancel = $true
        $dlg.Add_Loaded({ [void]$ok.Focus() }.GetNewClosure())
    } else {
        # Nut mac dinh an toan: Enter/Esc = Huy, focus ban dau o Huy.
        $dlg.Add_Loaded({ [void]$cancel.Focus() }.GetNewClosure())
    }
    $ok.Add_Click({ $dlg.DialogResult = $true }.GetNewClosure())
    $dlg.Add_MouseLeftButtonDown({ param($s, $e) try { $dlg.DragMove() } catch { Write-FileLog "WARN dialog DragMove: $($_.Exception.Message)" } }.GetNewClosure())
    return $dlg
}

function Get-DialogChoice {
    # Chi so lua chon dang chon trong hop thoai co -Choices (-1 neu khong co).
    param($Dialog)
    foreach ($rb in @($Dialog.Tag)) { if ($rb -is [Windows.Controls.RadioButton] -and $rb.IsChecked) { return [int]$rb.Tag } }
    return -1
}

function Show-ConfirmDialog {
    # Tra ve $true chi khi nguoi dung bam nut xac nhan. Ham cu dung MessageBox trang -> thay bang hop thoai theo theme.
    param([string]$Title, [string]$Message, [string]$ConfirmText = 'Đồng ý', [string]$CancelText = 'Hủy',
          [switch]$Danger, [switch]$OkOnly, [string]$Kind = 'warning', [switch]$Exclusive)
    # -Exclusive: a destructive confirmation holds khoExclusive while it is shown, so no auto-move / move / cleanup can change the
    # files it is about (callers also revalidate the target after the answer).
    Write-FileLog "DIALOG $Title"
    if ($null -ne $script:confirmDialogAutoAnswer) { return [bool]$script:confirmDialogAutoAnswer }
    if ($Exclusive) { $script:khoExclusive++ }
    try {
        $dlg = New-ConfirmDialog -Title $Title -Message $Message -ConfirmText $ConfirmText -CancelText $CancelText -Danger:$Danger -OkOnly:$OkOnly -Kind $Kind
        if ($win -and $win.IsVisible) { $dlg.Owner = $win }
        $script:lastConfirmDialog = $dlg
        $result = $dlg.ShowDialog()
        return ($result -eq $true)
    } catch {
        Write-FileLog "ERR  Show-ConfirmDialog: $($_.Exception.Message)"
        $mb = Show-KidMessageBox -Message $Message -Title $Title -Buttons $(if ($OkOnly) { 'OK' } else { 'YesNo' }) -Icon 'Warning' -Default $(if ($OkOnly) { 'OK' } else { 'No' })
        return ($mb -eq 'Yes' -or ($OkOnly -and $mb -eq 'OK'))
    } finally { $script:lastConfirmDialog = $null; if ($Exclusive) { $script:khoExclusive-- } }
}

function Show-ChoiceDialog {
    # Hop thoai co lua chon (nut tron). Tra ve chi so lua chon khi bam xac nhan; -1 khi Huy/Enter/Esc.
    param([string]$Title, [string]$Message, [string[]]$Choices, [int]$Default = 0, [string]$ConfirmText = 'Tiếp tục',
          [string]$CancelText = 'Hủy', [switch]$Danger, [string]$Kind = 'warning')
    Write-FileLog "DIALOG $Title (lựa chọn)"
    if ($null -ne $script:choiceDialogAutoAnswer) { return [int]$script:choiceDialogAutoAnswer }
    try {
        $dlg = New-ConfirmDialog -Title $Title -Message $Message -ConfirmText $ConfirmText -CancelText $CancelText -Danger:$Danger -Kind $Kind -Choices $Choices -ChoiceDefault $Default
        if ($win -and $win.IsVisible) { $dlg.Owner = $win }
        $script:lastConfirmDialog = $dlg
        if ($dlg.ShowDialog() -ne $true) { return -1 }
        return (Get-DialogChoice $dlg)
    } catch {
        Write-FileLog "ERR  Show-ChoiceDialog: $($_.Exception.Message)"
        Show-Toast "Không mở được hộp thoại: $(Get-FriendlyError $_.Exception.Message)" -Kind error
        return -1
    } finally { $script:lastConfirmDialog = $null }
}

function Clear-LogBatch {
    if ($script:logPendingText) { [void]$script:logPendingText.Clear() }
    if ($script:logFlushTimer) { try { $script:logFlushTimer.Stop() } catch { <# bo qua: don dep khi huy/dong, loi o day khong anh huong ket qua #> } }
}

function Flush-LogBatch {
    Flush-FileLog
    if ($script:fileLogError -and -not $script:fileLogErrorReported -and $script:logPendingText) {
        # Bao mot lan; khong goi Add-Log de tranh vong lap ghi file.
        $script:fileLogErrorReported = $true
        [void]$script:logPendingText.Append("Không ghi được file log trong '$($script:logDir)': $($script:fileLogError)`r`n")
    }
    if (-not $ui.TxtLog) { Clear-LogBatch; return }
    if (-not $script:logPendingText -or $script:logPendingText.Length -eq 0) {
        if ($script:logFlushTimer) { try { $script:logFlushTimer.Stop() } catch { <# bo qua: don dep khi huy/dong, loi o day khong anh huong ket qua #> } }
        return
    }
    $batch = $script:logPendingText.ToString()
    [void]$script:logPendingText.Clear()
    if ($script:logFlushTimer) { try { $script:logFlushTimer.Stop() } catch { <# bo qua: don dep khi huy/dong, loi o day khong anh huong ket qua #> } }
    $ui.TxtLog.AppendText($batch)
    if ($ui.TxtLog.Text.Length -gt 60000) {
        $ui.TxtLog.Text = $ui.TxtLog.Text.Substring($ui.TxtLog.Text.Length - 40000)
    }
    $ui.TxtLog.ScrollToEnd()
}

function Add-Log {
    param([string]$Text, [string]$Mau = 'Muted')
    $level = switch ($Mau) { 'Danger' { 'ERR ' } 'Warning' { 'WARN' } default { 'INFO' } }
    Write-FileLog "$level $Text"
    if (-not $ui.TxtLog) { return }
    if (-not $script:logPendingText) { $script:logPendingText = [System.Text.StringBuilder]::new() }
    $entry = $Text + "`r`n"
    $combinedLength = $script:logPendingText.Length + $entry.Length
    if ($combinedLength -gt 60000) {
        $removeCount = $combinedLength - 40000
        if ($removeCount -lt $script:logPendingText.Length) {
            [void]$script:logPendingText.Remove(0, $removeCount)
            [void]$script:logPendingText.Append($entry)
        } else {
            [void]$script:logPendingText.Clear()
            $entryStart = [Math]::Max(0, $entry.Length - 40000)
            [void]$script:logPendingText.Append($entry.Substring($entryStart))
        }
    } else {
        [void]$script:logPendingText.Append($entry)
    }
    if (-not $script:logFlushTimer) {
        $script:logFlushTimer = [System.Windows.Threading.DispatcherTimer]::new()
        $script:logFlushTimer.Interval = [TimeSpan]::FromMilliseconds(30)
        $script:logFlushTimer.Add_Tick({ Flush-LogBatch })
    }
    if (-not $script:logFlushTimer.IsEnabled) { $script:logFlushTimer.Start() }
}

function ConvertFrom-EngineEventLine {
    # '@@KIDFBY_<TYPE> {json}' -> @{ Type='STAGE'|'RESULT'|...; Data=<object>; Error=<string> } ; khong phai su kien -> $null
    param([string]$Line)
    if ($null -eq $Line) { return $null }
    $t = $Line.TrimStart()
    if (-not $t.StartsWith('@@KIDFBY_')) { return $null }
    $m = [regex]::Match($t, '^@@KIDFBY_([A-Z_]+)\s*(.*)$')
    if (-not $m.Success) { return @{ Type = ''; Data = $null; Error = 'Dòng sự kiện không đúng định dạng.' } }
    $evt = @{ Type = $m.Groups[1].Value; Data = $null; Error = $null }
    $json = $m.Groups[2].Value.Trim()
    if ($json) {
        try { $evt.Data = ConvertFrom-Json -InputObject $json -ErrorAction Stop }
        catch { $evt.Error = "JSON sự kiện lỗi: $($_.Exception.Message)" }
    }
    return $evt
}

function Invoke-EngineEvent {
    param([string]$Line)
    Write-FileLog "EVT  $Line"
    $evt = ConvertFrom-EngineEventLine $Line
    if (-not $evt) { return }
    if ($evt.Error) { Write-FileLog "WARN $($evt.Error)"; return }
    if ($evt.Type -eq 'STAGE' -and $evt.Data) {
        $step = 0
        if ([int]::TryParse([string]$evt.Data.step, [ref]$step)) { Set-QueueStep $step }
    } elseif ($evt.Type -eq 'RESULT' -and $evt.Data) {
        $script:currentResult = $evt.Data
    }
}

function Add-Line {
    param([string]$L)
    # Dong su kien may doc: an khoi log hien thi, van ghi file log.
    if ($null -ne $L -and $L.TrimStart().StartsWith('@@KIDFBY_')) { Invoke-EngineEvent $L; return }
    [void]$script:runLog.Append($L).Append("`r`n")

    # Thong diep cua dong dang chay (bang Hang doi); buoc lay tu @@KIDFBY_STAGE, dong "[n] ..." la du phong.
    if ($script:mode -eq 'run') {
        $stepMatch = [regex]::Match([string]$L, '^\s*\[([1-7])\]\s')
        if ($stepMatch.Success) { Set-QueueStep ([int]$stepMatch.Groups[1].Value) }
        $note = $null
        if ($L -match '\bDUB_UNVERIFIED\b') { $note = 'Chưa xác nhận được tiếng Việt trên giao diện Facebook' }
        elseif ($L -match '\bDUB_SELECTED\b') { $note = 'Đã chọn tiếng Việt trên Meta' }
        elseif ($L -match '\bDUB_UNAVAILABLE\b') { $note = 'Meta không có bản lồng tiếng Việt' }
        elseif ($L -match 'Da chap nhan lua chon Tieng Viet tu UI Meta; bat dau tai phan hinh HD') { $note = 'Đang tải phần hình chất lượng cao…' }
        elseif ($L -match 'Am thanh da cat va chuan hoa xong\s*\(([\d.]+)s,\s*muc am\s*([-\d.]+)\s*dB\)') { $note = "Âm thanh $($Matches[1]) s · mức $($Matches[2]) dB" }
        elseif ($L -match '(\d+x\d+)\s+([a-zA-Z0-9]+)\s+\|\s+([\d.]+)\s+giay\s+\|\s+([\d.]+)\s+MB') { $note = "Hình $($Matches[1] -replace 'x', '×') $($Matches[2]) · $($Matches[3]) s · $(Format-Bytes ([double]::Parse($Matches[4], [Globalization.CultureInfo]::InvariantCulture) * 1MB))" }
        if ($note) {
            $row = Get-QueueRow $script:idx
            if ($row -and $row.Status -eq 'running') { [void](Update-QueueRow -QueueIdx $script:idx -Changes @{ Message = $note }) }
        }
    }
    # Format log
    if ($L -match 'KHONG XONG|^\s*x\s|LỖI')              { Add-Log $L 'Danger'; return }
    if ($L -match '^\s*v\s|XONG|SAN SANG')              { Add-Log $L 'Success'; return }
    if ($L -match '^\s*!\s|Cach sua:')                  { Add-Log $L 'Warning'; return }
    if ($L -match '^\s*-\s')                            { Add-Log $L 'Muted'; return }
    if ($L -match '^\[\d+\]')                           { Add-Log $L 'Info'; return }
    if ($L -match '=====\s*video')                      { Add-Log $L 'Info'; return }
    Add-Log $L
}

function Set-Busy {
    param([bool]$On)
    $script:uiBusy = $On
    $gifSourceAvailable = [bool]($ui.ImgVideoGif -and $ui.ImgVideoGif.Source)
    # Nut chinh khong bi khoa: dang chay thi no la nut Dung (Update-PrimaryButton).
    foreach ($ctl in @($ui.BtnCheck, $ui.BtnInstallAllTools, $ui.BtnInstallScrcpy, $ui.BtnInstallAdb, $ui.BtnInstallYtdlp,
                       $ui.BtnInstallFfmpeg, $ui.BtnInstallWhisper, $ui.BtnOpenUninstall,
                       $ui.TxtLinks, $ui.BtnPasteLinks, $ui.BtnImportLinks, $ui.BtnClearLinks, $ui.RbDupSkip, $ui.RbDupRedownload, $ui.CmbDownloadKho)) {
        if ($ctl) { $ctl.IsEnabled = -not $On }
    }
    if ($ui.ChkWatermark) { $ui.ChkWatermark.IsEnabled = -not $On }
    foreach ($logoControl in @($ui.TxtLogoPath,$ui.BtnPickLogo,$ui.BtnDefaultLogo,$ui.SldLogoSize,$ui.SldLogoFade,$ui.CmbLogoMode,$ui.CmbLogoPosition)) {
        if ($logoControl) { $logoControl.IsEnabled = -not $On }
    }
    if ($ui.CmbLogoPosition) { $ui.CmbLogoPosition.IsEnabled = (-not $On -and $ui.CmbLogoMode.SelectedIndex -eq 1) }
    if ($ui.ChkGif) { $ui.ChkGif.IsEnabled = -not $On }
    foreach ($gifControl in @($ui.TxtGifPath,$ui.BtnPickGif,$ui.SldGifSize,$ui.BtnGifFullFrame,$ui.CmbGifPosition)) {
        if ($gifControl) { $gifControl.IsEnabled = -not $On }
    }
    if ($ui.BtnReedit) { $ui.BtnReedit.IsEnabled = (-not $On -and (Test-ReeditInputs $script:lastOut)) }
    if ($ui.BtnGifFullFrame) { $ui.BtnGifFullFrame.IsEnabled = (-not $On -and $gifSourceAvailable) }
    Update-ActionBar
}

function Copy-ToClipboard {
    param([string]$FilePath)
    if (-not $FilePath -or -not (Test-Path -LiteralPath $FilePath)) {
        Show-Toast 'Không tìm thấy file để copy.' -Kind warning
        return
    }
    try {
        $col = New-Object System.Collections.Specialized.StringCollection
        $full = [System.IO.Path]::GetFullPath($FilePath)
        [void]$col.Add($full)
        [System.Windows.Forms.Clipboard]::SetFileDropList($col)
        Show-Toast 'Đã sao chép file. Bấm Ctrl+V ở trang đăng để tải lên.' -Kind success
        Add-Log "Đã chép file vào Clipboard: $(Split-Path $FilePath -Leaf) (sẵn sàng Ctrl+V)" 'Info'
    } catch {
        Add-Log "Lỗi sao chép vào clipboard: $($_.Exception.Message)" 'Danger'
        Show-Toast "Không sao chép được file: $(Get-FriendlyError $_.Exception.Message)" -Kind error
    }
}

function Set-TrackButtons {
    # 'B' = video hoan chinh (ban long tieng); 'A' = am thanh tach.
    param([string]$Track)
    $script:switchingPage = $true
    try {
        if ($ui.BtnTrackB) { $ui.BtnTrackB.IsChecked = ($Track -ne 'A') }
        if ($ui.BtnTrackA) { $ui.BtnTrackA.IsChecked = ($Track -eq 'A') }
    } finally { $script:switchingPage = $false }
}

function Clear-Player {
    if ($script:deleteRestoreGenerationState) { $script:deleteRestoreGenerationState.Token = [Guid]::NewGuid().ToString('N') }
    if (Get-Command 'Stop-GifSelectionWorker' -ErrorAction SilentlyContinue) { Stop-GifSelectionWorker }
    try { $ui.Player.Stop() }  catch { Write-FileLog "WARN Player.Stop: $($_.Exception.Message)" }
    try { $ui.Player.Close() } catch { Write-FileLog "WARN Player.Close: $($_.Exception.Message)" }
    $ui.Player.Source = $null
    $script:pauseOnOpen = $false
    $ui.Player.IsMuted = $false
    $ui.PanelPlay.Visibility = 'Collapsed'
    $ui.TxtNoVid.Visibility  = 'Visible'
    $ui.BadgeRes.Visibility  = 'Collapsed'
    $ui.PhoneFrame.ToolTip   = $null
    $ui.BtnPlay.Content      = 'Phát'
    $ui.TxtTime.Text         = '0:00 / 0:00'
    $ui.PanelRev.Visibility  = 'Collapsed'
    $script:lastOut          = $null
    $script:previewingClean  = $false
    if ($ui.BadgePreviewMode) { $ui.BadgePreviewMode.Visibility = 'Collapsed' }
    if ($ui.BtnReedit) { $ui.BtnReedit.IsEnabled = $false }
    $script:activeTrack      = 'B'
    Set-TrackButtons 'B'
    if (Get-Command 'Update-WatermarkOverlay' -ErrorAction SilentlyContinue) { Update-WatermarkOverlay }
}

function Load-Player {
    # G-R2: khung xem truoc chi hien o Thuong hieu/Kho -> o trang khac luon nap o khung dau, khong phat tieng.
    param([string]$Path, [switch]$NoAutoPlay)
    if (-not (Test-PreviewPageVisible)) { $NoAutoPlay = $true }
    if ($script:deleteRestoreGenerationState) { $script:deleteRestoreGenerationState.Token = [Guid]::NewGuid().ToString('N') }
    $script:pauseOnOpen = $false
    try { $ui.Player.IsMuted = $false } catch { Write-FileLog "WARN Player.IsMuted: $($_.Exception.Message)" }
    if (-not $Path -or -not (Test-Path -LiteralPath $Path)) {
        Clear-Player
        return
    }
    try {
        $script:lastOut = $Path
        $script:previewingClean = $false
        if ($ui.BadgePreviewMode) { $ui.BadgePreviewMode.Visibility = 'Collapsed' }
        if ($ui.BtnReedit) { $ui.BtnReedit.IsEnabled = (-not $script:ps -and (Test-ReeditInputs $Path)) }
        Update-RedoAvailability $Path
        try { $ui.Player.Stop() }  catch { Write-FileLog "WARN Player.Stop: $($_.Exception.Message)" }
        try { $ui.Player.Close() } catch { Write-FileLog "WARN Player.Close: $($_.Exception.Message)" }
        $full = [System.IO.Path]::GetFullPath($Path)
        $ui.Player.Source = New-Object Uri($full)
        $ui.PhoneFrame.ToolTip = [System.IO.Path]::GetFileName($full)   # ten file nam trong tooltip (khong con dong "Dang xem")
        $ui.PanelPlay.Visibility = 'Visible'
        if ($NoAutoPlay) {
            # Manual LoadedBehavior can need Play() to open media; mute and pause on MediaOpened at frame 0.
            $script:pauseOnOpen = $true
            $ui.Player.IsMuted = $true
            $ui.Player.Play()
            $ui.BtnPlay.Content = 'Phát'
        } else {
            $ui.Player.Play()
            $ui.BtnPlay.Content = 'Tạm dừng'
        }
        # Mac dinh nghe ban long tieng (video hoan chinh).
        Set-TrackButtons 'B'
        $script:activeTrack = 'B'
        if (Get-Command 'Update-WatermarkOverlay' -ErrorAction SilentlyContinue) { Update-WatermarkOverlay }
    } catch {
        Write-FileLog "WARN Load-Player '$Path': $($_.Exception.Message)"
        Clear-Player
    }
}
function Get-ResolutionLabel {
    # Phan hang theo canh NGAN de video doc (1080x1920) khong bi goi la 2K.
    param([int]$Width, [int]$Height)
    $s = [Math]::Min($Width, $Height)
    if ($s -ge 2160) { return '4K UHD' }
    if ($s -ge 1440) { return '2K QHD' }
    if ($s -ge 1080) { return 'Full HD' }
    if ($s -ge 720)  { return 'HD' }
    return 'SD'
}

$ui.Player.Add_MediaOpened({
    $ui.TxtNoVid.Visibility = 'Collapsed'
    if ($script:pauseOnOpen) {
        $script:pauseOnOpen = $false
        $openPos = $script:pauseOnOpenPos
        $script:pauseOnOpenPos = [TimeSpan]::Zero
        try { $ui.Player.Pause(); $ui.Player.Position = $(if ($openPos) { $openPos } else { [TimeSpan]::Zero }) } catch { Write-FileLog "WARN Pause on open: $($_.Exception.Message)" }
        $ui.Player.IsMuted = $false
        $ui.BtnPlay.Content = 'Phát'
    }
    if ($ui.Player.NaturalDuration.HasTimeSpan) {
        $tot = $ui.Player.NaturalDuration.TimeSpan.TotalSeconds
        $ui.Seek.Maximum = $tot
    }
    if ($ui.Player.NaturalVideoWidth -gt 0) {
        $w = $ui.Player.NaturalVideoWidth
        $h = $ui.Player.NaturalVideoHeight
        $tag = Get-ResolutionLabel -Width $w -Height $h
        $script:resFullText = "$tag · $($w)×$($h)"
        $ui.TxtRes.Text = $script:resFullText
        $ui.BadgeRes.Visibility = 'Visible'
    }
    if (Get-Command 'Update-PhoneFrameSize' -ErrorAction SilentlyContinue) { Update-PhoneFrameSize }
    if (Get-Command 'Update-WatermarkOverlay' -ErrorAction SilentlyContinue) { Update-WatermarkOverlay }
})

$ui.Player.Add_MediaFailed({
    param($s, $e)
    $script:pauseOnOpen = $false
    try { $ui.Player.IsMuted = $false } catch { Write-FileLog "WARN Player.IsMuted: $($_.Exception.Message)" }
    Clear-Player
    $err = if ($e.ErrorException) { $e.ErrorException.Message } else { 'Lỗi giải mã Windows Media Foundation' }
    Add-Log "Cảnh báo Video Player: $err" 'Warning'
})

function Format-VideoTime {
    param([double]$TotalSeconds)
    if ([double]::IsNaN($TotalSeconds) -or [double]::IsInfinity($TotalSeconds) -or $TotalSeconds -lt 0) {
        $TotalSeconds = 0.0
    }
    $totalTenths = [long][Math]::Round($TotalSeconds * 10.0)
    $tenth = $totalTenths % 10
    $totalSec = [long][Math]::Floor($totalTenths / 10.0)
    $sec = $totalSec % 60
    $min = [long][Math]::Floor($totalSec / 60.0)
    return ('{0}:{1:00}.{2}' -f $min, $sec, $tenth)
}

function Switch-AudioTrack {
    param([string]$Track) # 'A' (am thanh tach) | 'B' (video hoan chinh)
    if (-not $script:lastOut -or -not (Test-Path -LiteralPath $script:lastOut)) {
        Clear-Player
        return
    }
    $targetFile = $null
    if ($Track -eq 'A') {
        # Am thanh tach (-2) nam trong <thu muc xuat>\.cache; file cu o goc van dung duoc.
        $fAm = Get-ReelCompanionPath -VideoPath $script:lastOut -Kind audio
        if ($fAm) { $targetFile = $fAm }
    } else {
        $targetFile = $script:lastOut
    }

    if (-not $targetFile -or -not (Test-Path -LiteralPath $targetFile)) {
        Set-TrackButtons $script:activeTrack
        Show-Toast 'Không tìm thấy âm thanh tách của video này (.cache hoặc thư mục xuất).' -Kind warning
        return
    }

    try {
        $curPos = $ui.Player.Position
        $isPlaying = ($ui.BtnPlay.Content -match 'Tạm dừng')
        $full = [System.IO.Path]::GetFullPath($targetFile)
        $ui.Player.Source = New-Object Uri($full)
        $script:activeTrack = $Track
        Set-TrackButtons $Track
        $script:previewingClean = $false
        if ($ui.BadgePreviewMode) { $ui.BadgePreviewMode.Visibility = 'Collapsed' }
        if (Get-Command 'Update-WatermarkOverlay' -ErrorAction SilentlyContinue) { Update-WatermarkOverlay }
        Show-Toast $(if ($Track -eq 'A') { 'Đang nghe: âm thanh tách.' } else { 'Đang nghe: bản lồng tiếng (video hoàn chỉnh).' })
        if ($curPos.TotalSeconds -gt 0) { $ui.Player.Position = $curPos }
        if ($isPlaying) { $ui.Player.Play() }
    } catch {
        Set-TrackButtons $script:activeTrack
        Add-Log "Không đổi được âm thanh xem trước: $($_.Exception.Message)" 'Warning'
        Show-Toast 'Không đổi được âm thanh xem trước.' -Kind error
    }
}
# ------------------------------------------------------------- file cua mot Reel: -3 o goc, -1/-2 trong .cache (dot 4) ----
# Thu muc xuat chi hien <ID>-3-hoan-chinh.mp4. Video goc (-1) va am thanh (-2) nam trong <thu muc xuat>\.cache (an);
# file cu cua ban truoc co the con o goc -> moi cho doc/xoa deu xet .cache truoc, roi toi goc.
$script:reelCacheName = '.cache'
function Get-ReelId {
    param([string]$VideoPath)
    $key = Get-KhoVideoKey ([IO.Path]::GetFileName([string]$VideoPath))
    if ($key) { return $key }
    return ([IO.Path]::GetFileName([string]$VideoPath) -replace '-3-hoan-chinh\.mp4$', '')
}

function Get-ReelLabel {
    # Tên người đọc được của một video theo khóa: "Reel #<id>" cho video của app, tên file (không đuôi) cho video ngoài ('f:<tên file>').
    param([string]$Id)
    if ($Id.StartsWith('f:')) { return [IO.Path]::GetFileNameWithoutExtension($Id.Substring(2)) }
    return "Reel #$Id"
}

function Get-ReelCacheDir {
    param([string]$OutDir)
    if ([string]::IsNullOrWhiteSpace($OutDir)) { return '' }
    return (Join-Path $OutDir $script:reelCacheName)
}

function Get-ReelCompanionPath {
    # Duong dan -1 (source) hoac -2 (audio) dang ton tai cua video -3; '' neu khong co o .cache lan goc.
    param([string]$VideoPath, [ValidateSet('source', 'audio')][string]$Kind)
    if ([string]::IsNullOrWhiteSpace($VideoPath) -or $VideoPath -notmatch '-3-hoan-chinh\.mp4$') { return '' }
    $dir = Split-Path $VideoPath -Parent
    $id = Get-ReelId $VideoPath
    $leaf = if ($Kind -eq 'source') { "$id-1-video-goc.mp4" } else { "$id-2-am-thanh-tho.m4a" }
    foreach ($p in @((Join-Path (Get-ReelCacheDir $dir) $leaf), (Join-Path $dir $leaf))) {
        if ([System.IO.File]::Exists($p)) { return $p }
    }
    return ''
}

function Test-KhoExternalVideoPath {
    # Video ngoài (không phải -3 của app) nằm trong một thư mục kho đã đăng ký: đã là video hoàn chỉnh, không phủ logo/GIF xem trước lên nó.
    param([string]$Path)
    if ([string]::IsNullOrWhiteSpace($Path) -or -not (Test-KhoExternalKey (Get-ReelId $Path))) { return $false }
    return [bool](Get-KhoByPath ([IO.Path]::GetDirectoryName([IO.Path]::GetFullPath($Path))))
}

function Update-RedoAvailability {
    # Ghi âm lại / sửa logo-GIF chỉ cho video do app tạo (cần file -1/-2); video ngoài: tắt kèm giải thích.
    param([string]$Path)
    $external = [bool]($Path -and (Test-KhoExternalKey (Get-ReelId $Path)))
    if ($ui.BtnRedo) {
        $ui.BtnRedo.IsEnabled = (-not $external)
        $ui.BtnRedo.ToolTip = $(if ($external) { 'Chỉ dùng cho video do app tạo' } else { 'Ghi âm lại video này (Ctrl+R)' })
    }
    if ($ui.BtnReedit -and $external) { $ui.BtnReedit.ToolTip = 'Chỉ dùng cho video do app tạo' }
}

function Test-ReeditInputs {
    # Nut "Ap dung len video dang xem" chi bat khi co du -3 + -1 + -2 (.cache hoac goc cu).
    param([string]$VideoPath)
    if ([string]::IsNullOrWhiteSpace($VideoPath) -or $VideoPath -notmatch '-3-hoan-chinh\.mp4$' -or -not [System.IO.File]::Exists($VideoPath)) { return $false }
    return [bool]((Get-ReelCompanionPath -VideoPath $VideoPath -Kind source) -and (Get-ReelCompanionPath -VideoPath $VideoPath -Kind audio))
}

function Get-ReelMediaFiles {
    # Cac file media cua mot Reel (theo thu tu xoa): -3 o goc, -1/-2 trong .cache, -1/-2 cu o goc.
    # Moi muc: @{ Path; Leaf; Location = 'root' | 'cache' | 'legacy'; Kind }. -Existing: chi file dang co.
    param([string]$VideoPath, [switch]$Existing)
    $dir = Split-Path $VideoPath -Parent
    $id = Get-ReelId $VideoPath
    $cache = Get-ReelCacheDir $dir
    # Video ngoài chỉ có file chính (không có -1/-2).
    if (Test-KhoExternalKey $id) {
        $one = @([pscustomobject]@{ Path = (Join-Path $dir (Get-KhoVideoFileName $id)); Leaf = (Get-KhoVideoFileName $id); Location = 'root'; Kind = 'final' })
        if ($Existing) { return @($one | Where-Object { [System.IO.File]::Exists($_.Path) }) }
        return $one
    }
    $list = @(
        [pscustomobject]@{ Path = (Join-Path $dir "$id-3-hoan-chinh.mp4"); Leaf = "$id-3-hoan-chinh.mp4"; Location = 'root'; Kind = 'final' }
        [pscustomobject]@{ Path = (Join-Path $cache "$id-1-video-goc.mp4"); Leaf = "$id-1-video-goc.mp4"; Location = 'cache'; Kind = 'source' }
        [pscustomobject]@{ Path = (Join-Path $cache "$id-2-am-thanh-tho.m4a"); Leaf = "$id-2-am-thanh-tho.m4a"; Location = 'cache'; Kind = 'audio' }
        [pscustomobject]@{ Path = (Join-Path $dir "$id-1-video-goc.mp4"); Leaf = "$id-1-video-goc.mp4"; Location = 'legacy'; Kind = 'source' }
        [pscustomobject]@{ Path = (Join-Path $dir "$id-2-am-thanh-tho.m4a"); Leaf = "$id-2-am-thanh-tho.m4a"; Location = 'legacy'; Kind = 'audio' }
    )
    if ($Existing) { return @($list | Where-Object { [System.IO.File]::Exists($_.Path) }) }
    return $list
}

function Get-ReelThumbFiles {
    # Anh thu nho + cache ffprobe cua Reel: <thu muc xuat>\.cache\thumbs\<id>.* (va .thumbs\<id>.* cua ban cu).
    param([string]$VideoPath)
    $dir = Split-Path $VideoPath -Parent
    $id = Get-ReelId $VideoPath
    $tk = Get-KhoThumbKey $id
    $found = New-Object System.Collections.ArrayList
    foreach ($td in @((Join-Path (Get-ReelCacheDir $dir) 'thumbs'), (Join-Path $dir '.thumbs'))) {
        if (-not [System.IO.Directory]::Exists($td)) { continue }
        foreach ($f in [System.IO.DirectoryInfo]::new($td).GetFiles()) {
            if ($f.Name -eq "$tk.jpg" -or $f.Name -eq "$tk.json" -or $f.Name.StartsWith("$tk.jpg.tmp")) { [void]$found.Add($f.FullName) }
        }
    }
    return @($found)
}

function Remove-ReelFiles {
    # S8: the video's files go to the Windows Recycle Bin (-3 first, then -1/-2 and its finished receipts; thumbnails are deleted).
    # A failure keeps the metadata entry and reports what is left in RecoveryPaths; a retry deletes the rest.
    # Returns Success, Errors, CleanupStatus ('Complete'), RecoveryPaths (files still there), DeletedFiles.
    param([string]$FilePath, [switch]$AllowPermanent)
    if (-not $FilePath) { return @{ Success = $false; Errors = @('Thieu duong dan file can xoa.'); CleanupStatus = 'NotStarted'; RecoveryPaths = @() } }
    $dir = Split-Path $FilePath -Parent
    # A stuck / pending move journal reserves both of its folders: nothing in them may be deleted until it is resolved.
    $journalBlock = Get-KhoJournalBlock @($dir)
    if ($journalBlock) { return @{ Success = $false; Errors = @($journalBlock); CleanupStatus = 'NotStarted'; RecoveryPaths = @(); DeletedFiles = @() } }
    $mediaFiles = @(Get-ReelMediaFiles -VideoPath $FilePath)
    $targetPaths = @($mediaFiles | ForEach-Object { [IO.Path]::GetFullPath($_.Path) })

    # Giai phong player tam thoi de bo lock tren file video neu dang phat
    $playerWasLocked = $false
    $activePaths = [System.Collections.Generic.List[string]]::new()
    if ($script:lastOut) {
        try { $activePaths.Add([IO.Path]::GetFullPath($script:lastOut)) } catch { Write-FileLog "WARN Remove-ReelFiles lastOut: $($_.Exception.Message)" }
    }
    if ($ui.Player -and $ui.Player.Source -and $ui.Player.Source.IsFile) {
        try { $activePaths.Add([IO.Path]::GetFullPath($ui.Player.Source.LocalPath)) } catch { Write-FileLog "WARN Remove-ReelFiles source: $($_.Exception.Message)" }
    }
    foreach ($targetPath in $targetPaths) {
        foreach ($activePath in $activePaths) {
            if ([string]::Equals($targetPath, $activePath, [StringComparison]::OrdinalIgnoreCase)) { $playerWasLocked = $true; break }
        }
        if ($playerWasLocked) { break }
    }
    if ($playerWasLocked -and $ui.Player) {
        try { $ui.Player.Stop() } catch { Write-FileLog "WARN Remove-ReelFiles Player.Stop: $($_.Exception.Message)" }
        try { $ui.Player.Close() } catch { Write-FileLog "WARN Remove-ReelFiles Player.Close: $($_.Exception.Message)" }
        $ui.Player.Source = $null
    }
    Start-Sleep -Milliseconds 100

    $removal = Remove-ReelToRecycleBin -Root $dir -Id (Get-ReelId $FilePath) -AllowPermanent:$AllowPermanent
    foreach ($k in @($script:probeCache.Keys)) { if ([string]::Equals($k, $FilePath, [StringComparison]::OrdinalIgnoreCase)) { $script:probeCache.Remove($k) } }
    return @{
        Success = [bool]$removal.Success
        Errors  = @($removal.Errors)
        CleanupStatus = 'Complete'
        RecoveryPaths = @($removal.Remaining)
        DeletedFiles = @($removal.Recycled)
        ThumbWarnings = @()
    }
}

# ------------------------------------------------------------- cap nhat kho video & loc ----
function Test-GalleryActionsBusy {
    return [bool]($script:ps -or $script:importBusy -or $script:khoMoveRunning -or ($script:queue -and $script:queue.Count -gt 0))
}

function Get-DeleteConfirmText {
    # G-C1: liet ke dung cac file se xoa va noi chung nam (-3 o thu muc xuat, -1/-2 trong .cache an, file cu o goc).
    param([string]$FilePath, [string]$NoRecycle = '')
    $id = Get-ReelId $FilePath
    $dir = Split-Path $FilePath -Parent
    $files = @(Get-ReelMediaFiles -VideoPath $FilePath -Existing)
    $desc = @{ final = 'video hoàn chỉnh'; source = 'video gốc sạch (để sửa lại logo/GIF)'; audio = 'âm thanh đã thu (để sửa lại)' }
    $where = @{ root = 'thư mục kho'; cache = '.cache (ẩn)'; legacy = 'thư mục kho, file cũ' }
    $lines = @($files | ForEach-Object { "• $($_.Leaf) — $($desc[$_.Kind]) · $($where[$_.Location])" })
    if (-not $lines.Count) { $lines = @("• $(Get-KhoVideoFileName $id) — video hoàn chỉnh") }
    $thumbs = @(Get-ReelThumbFiles -VideoPath $FilePath)
    if ($NoRecycle) {
        return ("Ổ này không có Thùng rác ($NoRecycle) — xóa vĩnh viễn?`r`nXóa $(Get-ReelLabel $id) khỏi kho, KHÔNG khôi phục được:`r`n$dir`r`n`r`n" + ($lines -join "`r`n") +
            $(if ($thumbs.Count) { "`r`n• ảnh thu nhỏ trong .cache	humbs" } else { '' }) + "`r`n`r`nLịch sử đăng của video này cũng bị xóa khỏi kho.")
    }
    return ("Chuyển $(Get-ReelLabel $id) trong kho vào Thùng rác:`r`n$dir`r`n`r`n" + ($lines -join "`r`n") +
        $(if ($thumbs.Count) { "`r`n• ảnh thu nhỏ trong .cache\thumbs (tự tạo lại được, xóa luôn)" } else { '' }) +
        "`r`n`r`nCác file nằm trong Thùng rác của Windows nên khôi phục được từ đó; lịch sử đăng của video này sẽ được xóa khỏi kho.")
}

function Confirm-GalleryDelete {
    param([string]$FilePath)
    # Hop thoai theo theme; nut mac dinh la Huy: Enter/Esc khong xoa nham.
    $n = [Math]::Max(1, @(Get-ReelMediaFiles -VideoPath $FilePath -Existing).Count)
    $noBin = Get-KhoNoRecycleReason (Split-Path $FilePath -Parent)
    if ($noBin) { return (Show-ConfirmDialog -Title 'Ổ này không có Thùng rác — xóa vĩnh viễn?' -Message (Get-DeleteConfirmText -FilePath $FilePath -NoRecycle $noBin) -ConfirmText "Xóa vĩnh viễn $n file" -Danger -Exclusive) }
    return (Show-ConfirmDialog -Title 'Xóa video này?' -Message (Get-DeleteConfirmText -FilePath $FilePath) -ConfirmText "Chuyển $n file vào Thùng rác" -Danger -Exclusive)
}

function Open-GalleryFile {
    param([string]$FilePath)
    try {
        $psi = New-Object System.Diagnostics.ProcessStartInfo
        $psi.FileName = 'explorer.exe'; $psi.Arguments = "/select,`"$FilePath`""; $psi.UseShellExecute = $true
        [System.Diagnostics.Process]::Start($psi) | Out-Null
    } catch {
        Write-FileLog "WARN explorer /select '$FilePath': $($_.Exception.Message)"
        Open-FolderSafe (Split-Path $FilePath -Parent)
    }
}

function Invoke-GalleryView {
    # -NoAutoPlay: chon the trong Kho chi nap video o 0:00, khong phat (G-E2E); nut Xem thi phat.
    param([string]$FilePath, [hashtable]$Controls, [switch]$NoAutoPlay)
    if (Test-GalleryActionsBusy) {
        Show-Toast 'Hãy dừng hoặc đợi hàng đợi hoàn tất trước khi xem video khác.' -Kind warning
        return $false
    }
    if (-not (Test-Path -LiteralPath $FilePath)) { Show-Toast 'Không tìm thấy video trong kho.' -Kind warning; return $false }
    $script:lastOut = $FilePath
    Load-Player $FilePath -NoAutoPlay:$NoAutoPlay
    # Ten file chi nam trong tooltip cua khung video (khong con dong "Dang xem: ..." chiem cho).
    $Controls.PhoneFrame.ToolTip = (Split-Path $FilePath -Leaf)
    $Controls.PanelRev.Visibility = 'Visible'
    return $true
}
function Invoke-GalleryDelete {
    param([string]$FilePath, [hashtable]$Controls)
    if (Test-GalleryActionsBusy) {
        Show-Toast 'Hãy hoàn tất tác vụ và hàng đợi trước khi xóa video trong kho.' -Kind warning
        return $false
    }
    if (-not (Test-Path -LiteralPath $FilePath)) { Show-Toast 'Không tìm thấy video trong kho.' -Kind warning; return $false }
    $journalBlock = Get-KhoJournalBlock @((Split-Path $FilePath -Parent))
    if ($journalBlock) { Show-Toast $journalBlock -Kind warning; return $false }
    if (Test-TikTokTransferActive $FilePath) { Show-Toast 'Video đang được chuyển sang bộ đăng nền. Đợi chuyển xong rồi hãy xóa.' -Kind warning; return $false }
    if (-not (Confirm-GalleryDelete $FilePath)) { return $false }
    if (-not (Test-Path -LiteralPath $FilePath)) { Show-Toast 'Video đã được chuyển hoặc không còn ở vị trí này; chưa xóa gì.' -Kind warning; return $false }

    $savedSource = $Controls.Player.Source
    $savedSourceText = if ($savedSource) { $savedSource.ToString() } else { '' }
    $savedPosition = [TimeSpan]::Zero
    try { $savedPosition = $Controls.Player.Position } catch { <# bo qua: player chua mo nguon: vi tri mac dinh 0 #> }
    $savedWasPlaying = ($Controls.BtnPlay -and $Controls.BtnPlay.Content -match 'Tạm dừng')
    $savedLastOut = $script:lastOut
    $savedActiveTrack = $script:activeTrack
    $savedPreviewingClean = $script:previewingClean
    $savedBadge = if ($Controls.BadgePreviewMode) { $Controls.BadgePreviewMode.Visibility } else { $null }
    $savedReview = if ($Controls.PanelRev) { $Controls.PanelRev.Visibility } else { $null }
    $savedPanelPlay = if ($Controls.PanelPlay) { $Controls.PanelPlay.Visibility } else { $null }
    $savedNoVid = if ($Controls.TxtNoVid) { $Controls.TxtNoVid.Visibility } else { $null }
    $rowId = Get-ReelId $FilePath
    $reelPaths = @(Get-ReelMediaFiles -VideoPath $FilePath | ForEach-Object { [IO.Path]::GetFullPath($_.Path) })
    $activePaths = [System.Collections.Generic.List[string]]::new()
    if ($savedLastOut) { try { $activePaths.Add([IO.Path]::GetFullPath($savedLastOut)) } catch { <# bo qua: duong dan khong hop le thi khong tinh la dang xem #> } }
    if ($savedSource -and $savedSource.IsFile) { try { $activePaths.Add([IO.Path]::GetFullPath($savedSource.LocalPath)) } catch { <# bo qua: duong dan khong hop le thi khong tinh la dang xem #> } }
    $affectsPlayer = $false
    foreach ($reelPath in $reelPaths) {
        foreach ($activePath in $activePaths) {
            if ([string]::Equals($reelPath, $activePath, [StringComparison]::OrdinalIgnoreCase)) { $affectsPlayer = $true; break }
        }
        if ($affectsPlayer) { break }
    }

    $result = $null
    try { $result = Remove-ReelFiles $FilePath -AllowPermanent:([bool](Get-KhoNoRecycleReason (Split-Path $FilePath -Parent))) }
    catch { $result = @{ Success=$false; Errors=@($_.Exception.Message); CleanupStatus='RecoveryRequired'; RecoveryPaths=@() } }
    $recoveryPaths = @($result.RecoveryPaths | Where-Object { $_ })
    Add-Log "Gallery delete: success=$($result.Success); cleanup=$($result.CleanupStatus); recovery=$($recoveryPaths -join ', '); errors=$(@($result.Errors) -join '; ')" 'Danger'

    if (-not $result.Success) {
        $script:lastOut = $savedLastOut
        $script:activeTrack = $savedActiveTrack
        $script:previewingClean = $savedPreviewingClean
        if ($Controls.PanelRev -and $null -ne $savedReview) { $Controls.PanelRev.Visibility = $savedReview }
        if ($Controls.PanelPlay -and $null -ne $savedPanelPlay) { $Controls.PanelPlay.Visibility = $savedPanelPlay }
        if ($Controls.TxtNoVid -and $null -ne $savedNoVid) { $Controls.TxtNoVid.Visibility = $savedNoVid }
        if ($Controls.BadgePreviewMode -and $null -ne $savedBadge) { $Controls.BadgePreviewMode.Visibility = $savedBadge }
        if ($Controls.BtnReedit) { $Controls.BtnReedit.IsEnabled = ($savedLastOut -and (Test-Path -LiteralPath $savedLastOut)) }
        if ($savedSource -and $affectsPlayer) {
            $sourceAvailable = (-not $savedSource.IsFile) -or (Test-Path -LiteralPath $savedSource.LocalPath)
            if ($sourceAvailable) {
                if (-not $script:deleteRestoreGenerationState) { $script:deleteRestoreGenerationState = [pscustomobject]@{ Token = '' } }
                $generationState = $script:deleteRestoreGenerationState
                $restore = [pscustomobject]@{ Token=[Guid]::NewGuid().ToString('N'); Opened=$false; Failed=$false; Done=$false; SourceText=$savedSourceText; Timer=$null; OpenHandler=$null; FailHandler=$null; TickHandler=$null; Expires=[DateTime]::UtcNow.AddSeconds(15) }
                $generationState.Token = $restore.Token
                $opened = { param($sender,$eventArgs) if ($generationState.Token -eq $restore.Token -and $Controls.Player.Source -and $Controls.Player.Source.ToString() -eq $restore.SourceText) { $restore.Opened=$true } }.GetNewClosure()
                $failed = { param($sender,$eventArgs) if ($generationState.Token -eq $restore.Token -and $Controls.Player.Source -and $Controls.Player.Source.ToString() -eq $restore.SourceText) { $restore.Failed=$true } }.GetNewClosure()
                $restore.OpenHandler=[System.Windows.RoutedEventHandler]$opened
                $restore.FailHandler=[System.EventHandler[System.Windows.ExceptionRoutedEventArgs]]$failed
                $timer = [Windows.Threading.DispatcherTimer]::new(); $timer.Interval=[TimeSpan]::FromMilliseconds(50); $restore.Timer=$timer
                $restoreFileLog = ${function:Write-FileLog}
                $tick = {
                    $current = if ($Controls.Player.Source) { $Controls.Player.Source.ToString() } else { '' }
                    if ($restore.Done -or $generationState.Token -ne $restore.Token -or $current -ne $restore.SourceText -or $restore.Failed -or [DateTime]::UtcNow -gt $restore.Expires) {
                        $restore.Done=$true; $restore.Timer.Stop()
                        try { $Controls.Player.Remove_MediaOpened($restore.OpenHandler) } catch { <# bo qua: don dep khi huy/dong, loi o day khong anh huong ket qua #> }
                        try { $Controls.Player.Remove_MediaFailed($restore.FailHandler) } catch { <# bo qua: don dep khi huy/dong, loi o day khong anh huong ket qua #> }
                        try { $restore.Timer.Remove_Tick($restore.TickHandler) } catch { <# bo qua: don dep khi huy/dong, loi o day khong anh huong ket qua #> }
                        return
                    }
                    if (-not $restore.Opened) { return }
                    $restore.Done=$true; $restore.Timer.Stop()
                    try { $Controls.Player.Position=$savedPosition } catch { & $restoreFileLog "WARN khôi phục vị trí phát sau xóa lỗi: $($_.Exception.Message)" }
                    if ($savedWasPlaying) { try { $Controls.Player.Play(); $Controls.BtnPlay.Content='Tạm dừng' } catch { & $restoreFileLog "WARN khôi phục phát sau xóa lỗi: $($_.Exception.Message)" } }
                    else { try { $Controls.Player.Pause(); $Controls.BtnPlay.Content='Phát' } catch { & $restoreFileLog "WARN khôi phục tạm dừng sau xóa lỗi: $($_.Exception.Message)" } }
                    try { $Controls.Player.Remove_MediaOpened($restore.OpenHandler) } catch { <# bo qua: don dep khi huy/dong, loi o day khong anh huong ket qua #> }
                    try { $Controls.Player.Remove_MediaFailed($restore.FailHandler) } catch { <# bo qua: don dep khi huy/dong, loi o day khong anh huong ket qua #> }
                    try { $restore.Timer.Remove_Tick($restore.TickHandler) } catch { <# bo qua: don dep khi huy/dong, loi o day khong anh huong ket qua #> }
                }.GetNewClosure()
                $restore.TickHandler=[System.EventHandler]$tick
                $Controls.Player.Add_MediaOpened($restore.OpenHandler); $Controls.Player.Add_MediaFailed($restore.FailHandler); $timer.Add_Tick($restore.TickHandler)
                try {
                    if ($Controls.Player.Source) { $Controls.Player.Stop(); $Controls.Player.Close() }
                    $Controls.Player.Source=$savedSource
                    $Controls.Player.Play(); $Controls.BtnPlay.Content='Tạm dừng'
                    $Controls.PanelPlay.Visibility='Visible'; $Controls.TxtNoVid.Visibility='Collapsed'; $timer.Start()
                }
                catch { $timer.Stop(); try { $Controls.Player.Remove_MediaOpened($opened) } catch { <# bo qua: don dep khi huy/dong, loi o day khong anh huong ket qua #> }; try { $Controls.Player.Remove_MediaFailed($failed) } catch { <# bo qua: don dep khi huy/dong, loi o day khong anh huong ket qua #> } }
            } else {
                try { $Controls.Player.Stop(); $Controls.Player.Close(); $Controls.Player.Source=$null } catch { <# bo qua: don dep khi huy/dong, loi o day khong anh huong ket qua #> }
                if ($Controls.PanelPlay) { $Controls.PanelPlay.Visibility='Collapsed' }
                if ($Controls.TxtNoVid) { $Controls.TxtNoVid.Visibility='Visible' }
                if ($Controls.BtnReedit) { $Controls.BtnReedit.IsEnabled=$false }
            }
        }
        $detail = if ($recoveryPaths.Count) { " Có file cần khôi phục: $($recoveryPaths -join ', ')" } else { ' Các file vẫn được giữ nguyên hoặc đã khôi phục.' }
        Show-Toast ("Không xóa được video." + $detail) -Kind error
        return $false
    }

    if ($affectsPlayer) { Clear-Player }
    if ($recoveryPaths.Count -or $result.CleanupStatus -ne 'Complete') {
        $retained = if ($recoveryPaths.Count) { $recoveryPaths -join ', ' } else { 'đường dẫn không xác định' }
        Show-Toast "Đã xóa video; còn bản sao tạm cần dọn: $retained" -Kind warning
    } else { Show-Toast "Đã xóa video $(Get-ReelLabel $rowId)." -Kind success }
    Update-Gallery
    return $true
}

function Get-RejectedReasonText {
    param($Entry)
    switch ([string]$Entry.Reason) {
        'vietnamese-unavailable' { return 'Meta không có bản lồng tiếng Việt' }
        'audio-not-vietnamese'   { return 'Âm thanh không phải tiếng Việt' + $(if ($Entry.Language) { ': ' + $Entry.Language } else { '' }) }
        ''                       { return 'Không rõ lý do' }
        default                  { return (Get-ReasonText ([string]$Entry.Reason)) }
    }
}

function Update-RejectedDashboard {
    if (-not $ui.TxtRejectedDashboard) { return }
    try {
        $entries = @(Get-RejectedReels -Root $script:root | Sort-Object RejectedAt -Descending)
        if ($ui.TxtRejectedTabLabel) { $ui.TxtRejectedTabLabel.Text = "Lịch sử đã loại ($($entries.Count))" }
        $canUnreject = [bool](Get-Command Remove-RejectedReel -ErrorAction SilentlyContinue)
        $rows = New-Object 'System.Collections.ObjectModel.ObservableCollection[object]'
        foreach ($entry in $entries) {
            $date = try { ([DateTime]::Parse([string]$entry.RejectedAt, [Globalization.CultureInfo]::InvariantCulture)).ToLocalTime().ToString('dd/MM/yyyy HH:mm') } catch { [string]$entry.RejectedAt }
            $rows.Add([pscustomobject]@{
                VideoId = [string]$entry.VideoId
                Title = 'Reel #' + $entry.VideoId
                Detail = $date + ' · ' + (Get-RejectedReasonText $entry)
                UnrejectTip = $(if ($canUnreject) { "Gỡ Reel #$($entry.VideoId) khỏi lịch sử loại để có thể tải lại." } else { 'Cần bản engine mới để bỏ loại.' })
            })
        }
        $script:rejectedRows = $rows
        if ($ui.RejectedList) { $ui.RejectedList.ItemsSource = $rows }
        $ui.TxtRejectedDashboard.Text = if (-not $entries.Count) { 'Chưa có video bị loại. Video không có bản lồng tiếng Việt sẽ được ghi vào đây và tự bỏ qua ở lần sau.' }
                                        else { "$($entries.Count) video bị loại sẽ tự bỏ qua khi tải. Bấm Bỏ loại để cho phép tải lại." }
    } catch {
        $ui.TxtRejectedDashboard.Text = 'Không đọc được lịch sử loại. Hãy dừng tải để tránh tải lại video đã loại.'
        Add-Log "Không đọc được lịch sử loại: $($_.Exception.Message)" 'Danger'
    }
}

function Invoke-UnrejectReel {
    param([string]$VideoId)
    if ([string]::IsNullOrWhiteSpace($VideoId)) { return }
    # Engine dang chay co the giu mutex lich su loai: khong cho UI thread cho toi 10 s.
    if ($script:ps -or $script:stopping -or ($script:queue -and $script:queue.Count -gt 0)) {
        Show-Toast 'Đang xử lý — thử lại sau khi dừng.' -Kind warning
        return
    }
    if (-not (Get-Command Remove-RejectedReel -ErrorAction SilentlyContinue)) {
        Show-Toast 'Cần bản engine mới để bỏ loại video.' -Kind warning
        Add-Log "Không bỏ loại được Reel #${VideoId}: thiếu hàm Remove-RejectedReel (cần bản engine mới)." 'Warning'
        return
    }
    try {
        $removed = [bool](Remove-RejectedReel -Root $script:root -VideoId $VideoId)
        if ($removed) {
            Add-Log "Đã bỏ loại Reel #$VideoId; lần tải sau sẽ xử lý lại video này." 'Success'
            Show-Toast "Đã bỏ loại Reel #$VideoId." -Kind success
            # Dong bang hang doi cua video nay: cho phep Thu lai.
            foreach ($q in @($script:queueRowByIdx.Keys)) {
                $r = Get-QueueRow $q
                if ($r -and $r.Id -eq $VideoId -and $r.Status -eq 'rejected') {
                    [void](Update-QueueRow -QueueIdx $q -Changes @{ Message = 'Đã bỏ loại — bấm Thử lại để tải lại.'; ActionOverride = 'retry' })
                }
            }
        } else {
            Show-Toast "Reel #$VideoId không còn trong lịch sử loại."
        }
    } catch {
        Add-Log "Không bỏ loại được Reel #${VideoId}: $($_.Exception.Message)" 'Danger'
        Show-Toast "Không bỏ loại được Reel #${VideoId}: $(Get-FriendlyError $_.Exception.Message)" -Kind error
    }
    Update-RejectedDashboard
    Update-LinkDuplicateWarning
}

# ------------------------------------------------------------- media worker nen (quet kho, ffprobe, anh thu nho) ----
# Mot runspace nen nhan viec qua BlockingCollection, tra ket qua qua ConcurrentQueue; UI doc bang DispatcherTimer.
function Get-MediaToolPath {
    param([ValidateSet('ffmpeg', 'ffprobe')][string]$Name)
    foreach ($rel in @("tools\ffmpeg\$Name.exe", "tools\ffmpeg\bin\$Name.exe", "tools\$Name.exe")) {
        $p = Join-Path $script:root $rel
        if ([System.IO.File]::Exists($p)) { return $p }
    }
    $cmd = Get-Command $Name -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($cmd) { return [string]$cmd.Source }
    return ''
}

$script:mediaWorkerScript = @'
param($Jobs, $Results, $Ffmpeg, $Ffprobe, $State)
$ErrorActionPreference = 'Stop'
function Invoke-Tool([string]$Exe, [string]$Arguments, [int]$TimeoutMs) {
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $Exe; $psi.Arguments = $Arguments; $psi.UseShellExecute = $false
    $psi.RedirectStandardOutput = $true; $psi.RedirectStandardError = $true; $psi.CreateNoWindow = $true
    $p = [System.Diagnostics.Process]::Start($psi)
    $State['Proc'] = $p
    try {
        $o = $p.StandardOutput.ReadToEndAsync(); $e = $p.StandardError.ReadToEndAsync()
        if (-not $p.WaitForExit($TimeoutMs)) { $p.Kill(); [void]$p.WaitForExit(3000); return @{ Code = -1; Out = ''; Err = "timeout $TimeoutMs ms" } }
        [void]$o.Wait(3000); [void]$e.Wait(3000)
        return @{ Code = $p.ExitCode; Out = [string]$o.Result; Err = [string]$e.Result }
    } finally { $State['Proc'] = $null; $p.Dispose() }
}
while (-not $Jobs.IsCompleted) {
    $job = $null
    if (-not $Jobs.TryTake([ref]$job, 300)) { continue }
    if ($null -eq $job) { continue }
    try {
        if ($job.Kind -eq 'scan') {
            # One job over every kho folder (each non-recursive); a folder that cannot be read reports its own error.
            $scanned = New-Object System.Collections.Generic.List[object]
            foreach ($dir in @($job.Dirs)) {
                $entry = [pscustomobject]@{ Dir = [string]$dir; Files = @(); Error = ''; Missing = $false }
                try {
                    if (-not [System.IO.Directory]::Exists([string]$dir)) { $entry.Missing = $true }
                    else {
                        $entry.Files = @(Get-ChildItem -LiteralPath $dir -File -ErrorAction Stop | Where-Object { $_.Name[0] -ne '.' -and $_.Extension.ToLowerInvariant() -in @('.mp4', '.mov', '.m4v', '.mkv', '.webm', '.avi') } |
                            Sort-Object LastWriteTime -Descending |
                            ForEach-Object { [pscustomobject]@{ FullName = $_.FullName; Name = $_.Name; Length = $_.Length; LastWriteTime = $_.LastWriteTime; Stamp = "$($_.Length)-$($_.LastWriteTimeUtc.Ticks)"; Root = [string]$dir } })
                    }
                } catch { $entry.Error = $_.Exception.Message }
                $scanned.Add($entry)
            }
            $Results.Enqueue([pscustomobject]@{ Kind = 'scan'; Gen = $job.Gen; Roots = $scanned.ToArray(); Error = '' })
            continue
        }
        if ($job.Kind -ne 'probe') { continue }
        $video = [string]$job.Path
        $fi = [System.IO.FileInfo]::new($video)
        if (-not $fi.Exists) { $Results.Enqueue([pscustomobject]@{ Kind = 'probe'; Gen = $job.Gen; Path = $video; Stamp = ''; Duration = 0.0; Width = 0; Height = 0; Thumb = ''; Error = 'missing' }); continue }
        $stamp = "$($fi.Length)-$($fi.LastWriteTimeUtc.Ticks)"
        # Dot 4: anh thu nho nam trong <thu muc xuat>\.cache\thumbs (.cache an, dung chung voi -1/-2 cua engine).
        $cacheDir = Join-Path $fi.DirectoryName '.cache'
        $thumbDir = Join-Path $cacheDir 'thumbs'
        $cacheCreated = -not [System.IO.Directory]::Exists($cacheDir)
        [void][System.IO.Directory]::CreateDirectory($thumbDir)
        if ($cacheCreated) {
            try { [System.IO.File]::SetAttributes($cacheDir, [System.IO.FileAttributes]::Directory -bor [System.IO.FileAttributes]::Hidden) }
            catch { $State['Warn'] = 'hidden .cache: ' + $_.Exception.Message }
        }
        $infoPath = Join-Path $thumbDir ($job.Id + '.json')
        $thumbPath = Join-Path $thumbDir ($job.Id + '.jpg')
        $info = $null; $err = ''
        if ([System.IO.File]::Exists($infoPath)) {
            try { $cached = [System.IO.File]::ReadAllText($infoPath) | ConvertFrom-Json; if ($cached.stamp -eq $stamp) { $info = $cached } }
            catch { $err = 'cache: ' + $_.Exception.Message }
        }
        if (-not $info) {
            $err = ''
            if (-not $Ffprobe) { $err = 'ffprobe-missing' }
            else {
                $r = Invoke-Tool $Ffprobe ('-v error -select_streams v:0 -show_entries stream=width,height:format=duration -of json "' + $video + '"') 15000
                if ($r.Code -eq 0) {
                    $j = $r.Out | ConvertFrom-Json
                    $dur = 0.0; [void][double]::TryParse([string]$j.format.duration, [Globalization.NumberStyles]::Float, [Globalization.CultureInfo]::InvariantCulture, [ref]$dur)
                    $st = @($j.streams)[0]
                    $info = [pscustomobject]@{ stamp = $stamp; duration = $dur; width = [int]$st.width; height = [int]$st.height }
                    [System.IO.File]::WriteAllText($infoPath, ($info | ConvertTo-Json -Compress), [System.Text.UTF8Encoding]::new($false))
                } else { $err = "ffprobe exit $($r.Code): " + ([string]$r.Err).Trim() }
            }
        }
        $thumbOk = [System.IO.File]::Exists($thumbPath) -and ([System.IO.File]::GetLastWriteTimeUtc($thumbPath) -ge $fi.LastWriteTimeUtc)
        # Anh thu nho doi 180 -> 360 px (the Kho lon hon): file cu (info chua co tv=2) duoc tao lai mot lan.
        $thumbStale = ($thumbOk -and $info -and [int]$(if ($info.PSObject.Properties.Name -contains 'tv') { $info.tv } else { 0 }) -lt 2)
        if ($thumbStale) { $thumbOk = $false }
        if (-not $thumbOk -and $info -and $Ffmpeg) {
            $seek = if ([double]$info.duration -gt 2.0) { '1' } else { '0' }
            $tmp = $thumbPath + '.tmp.jpg'
            $r = Invoke-Tool $Ffmpeg ('-hide_banner -loglevel error -ss ' + $seek + ' -i "' + $video + '" -frames:v 1 -vf scale=360:-2 -q:v 3 -y "' + $tmp + '"') 20000
            if ($r.Code -eq 0 -and [System.IO.File]::Exists($tmp)) {
                if ([System.IO.File]::Exists($thumbPath)) { [System.IO.File]::Delete($thumbPath) }
                [System.IO.File]::Move($tmp, $thumbPath)
                $thumbOk = $true
                try {
                    $info | Add-Member -Name tv -Value 2 -MemberType NoteProperty -Force
                    [System.IO.File]::WriteAllText($infoPath, ($info | ConvertTo-Json -Compress), [System.Text.UTF8Encoding]::new($false))
                } catch { $err = 'cache: ' + $_.Exception.Message }
            } else {
                if ([System.IO.File]::Exists($tmp)) { [System.IO.File]::Delete($tmp) }
                $err = "ffmpeg thumbnail exit $($r.Code): " + ([string]$r.Err).Trim()
            }
        }
        $Results.Enqueue([pscustomobject]@{
            Kind = 'probe'; Gen = $job.Gen; Path = $video; Stamp = $stamp
            Duration = $(if ($info) { [double]$info.duration } else { 0.0 })
            Width = $(if ($info) { [int]$info.width } else { 0 }); Height = $(if ($info) { [int]$info.height } else { 0 })
            Thumb = $(if ($thumbOk) { $thumbPath } else { '' }); Error = $err })
    } catch {
        $Results.Enqueue([pscustomobject]@{ Kind = [string]$job.Kind; Gen = $job.Gen; Path = [string]$job.Path; Roots = @(); Stamp = ''
                                            Files = @(); Duration = 0.0; Width = 0; Height = 0; Thumb = ''; Error = $_.Exception.Message })
    }
}
'@

function Start-MediaWorker {
    $w = $script:mediaWorker
    if ($w -and -not $w.Async.IsCompleted) { return $w }
    if ($w) { Stop-MediaWorker }
    $jobs = New-Object 'System.Collections.Concurrent.BlockingCollection[object]'
    $results = New-Object 'System.Collections.Concurrent.ConcurrentQueue[object]'
    $state = [hashtable]::Synchronized(@{ Proc = $null; Warn = '' })
    $ffmpegPath = Get-MediaToolPath 'ffmpeg'; $ffprobePath = Get-MediaToolPath 'ffprobe'
    $ps = [PowerShell]::Create()
    [void]$ps.AddScript($script:mediaWorkerScript).AddArgument($jobs).AddArgument($results).AddArgument($ffmpegPath).AddArgument($ffprobePath).AddArgument($state)
    $async = $ps.BeginInvoke()
    $script:mediaWorker = [pscustomobject]@{ PS = $ps; Async = $async; Jobs = $jobs; Results = $results; State = $state; Reported = $false
                                             Ffmpeg = [string]$ffmpegPath; Ffprobe = [string]$ffprobePath }
    if (-not $script:tMedia) {
        $script:tMedia = New-Object Windows.Threading.DispatcherTimer
        $script:tMedia.Interval = [TimeSpan]::FromMilliseconds(120)
        $script:tMedia.Add_Tick({
            try { Receive-MediaResults }
            catch { Write-FileLog "ERR  Receive-MediaResults: $($_.Exception.Message)`r`n$($_.ScriptStackTrace)" }
            try { Complete-StoppedMediaWorkers }
            catch { Write-FileLog "ERR  Complete-StoppedMediaWorkers: $($_.Exception.Message)" }
        })
    }
    $script:tMedia.Start()
    return $script:mediaWorker
}

function Close-MediaWorkerInstance {
    # Giai phong PowerShell + runspace cua worker (sau khi pipeline da dung). Khong nem loi.
    param($Entry)
    if (-not $Entry -or -not $Entry.PS) { return }
    $rs = $null
    try { $rs = $Entry.PS.Runspace } catch { Write-FileLog "WARN media worker runspace: $($_.Exception.Message)" }
    if ($Entry.StopHandle) { try { $Entry.PS.EndStop($Entry.StopHandle) } catch { Write-FileLog "WARN media worker EndStop: $($_.Exception.Message)" } }
    try { $Entry.PS.Dispose() } catch { Write-FileLog "WARN media worker Dispose: $($_.Exception.Message)" }
    if ($rs) {
        try { if ($rs.RunspaceStateInfo.State -ne 'Closed') { $rs.Dispose() } } catch { Write-FileLog "WARN media worker runspace Dispose: $($_.Exception.Message)" }
    }
    $Entry.PS = $null
}

function Complete-StoppedMediaWorkers {
    # G-R9: worker da BeginStop -> khi pipeline dung xong (hoac qua 5 s) thi Dispose PowerShell/runspace.
    param([switch]$Force)
    for ($i = $script:mediaWorkersStopping.Count - 1; $i -ge 0; $i--) {
        $e = $script:mediaWorkersStopping[$i]
        $done = (-not $e.StopHandle -or $e.StopHandle.IsCompleted) -and (-not $e.Async -or $e.Async.IsCompleted)
        if ($done -or $Force -or ([DateTime]::UtcNow - $e.Since).TotalSeconds -gt 5) {
            Close-MediaWorkerInstance $e
            $script:mediaWorkersStopping.RemoveAt($i)
        }
    }
    if ($script:tMedia -and -not $script:mediaWorker -and $script:mediaWorkersStopping.Count -eq 0) { $script:tMedia.Stop() }
}

function Stop-MediaWorker {
    param([switch]$Wait)
    $w = $script:mediaWorker
    if ($w) {
        $script:mediaWorker = $null
        try { $w.Jobs.CompleteAdding() } catch { Write-FileLog "WARN media worker CompleteAdding: $($_.Exception.Message)" }
        $proc = $w.State['Proc']
        if ($proc) { try { if (-not $proc.HasExited) { $proc.Kill() } } catch { Write-FileLog "WARN media worker kill: $($_.Exception.Message)" } }
        $stopHandle = $null
        if (-not $w.Async.IsCompleted) {
            try { $stopHandle = $w.PS.BeginStop($null, $null) } catch { Write-FileLog "WARN media worker stop: $($_.Exception.Message)" }
        }
        [void]$script:mediaWorkersStopping.Add([pscustomobject]@{ PS = $w.PS; Async = $w.Async; StopHandle = $stopHandle; Since = [DateTime]::UtcNow })
        if ($script:tMedia -and -not $Wait) { $script:tMedia.Start() }
    }
    if ($Wait) {
        # Dong app: cho toi da ~1.5 s roi giai phong ep buoc.
        $sw = [Diagnostics.Stopwatch]::StartNew()
        while ($script:mediaWorkersStopping.Count -and $sw.ElapsedMilliseconds -lt 1500) {
            Complete-StoppedMediaWorkers
            if ($script:mediaWorkersStopping.Count) { Start-Sleep -Milliseconds 50 }
        }
        Complete-StoppedMediaWorkers -Force
    } else {
        Complete-StoppedMediaWorkers
    }
}

function Test-MediaToolsChanged {
    # G-R3: worker dang dung duong dan ffmpeg/ffprobe cu (vd vua cai cong cu) -> can tao lai.
    $w = $script:mediaWorker
    if (-not $w) { return $false }
    return ([string](Get-MediaToolPath 'ffmpeg') -ne [string]$w.Ffmpeg -or [string](Get-MediaToolPath 'ffprobe') -ne [string]$w.Ffprobe)
}

function Reset-MediaWorkerForTools {
    # Sau khi cai/thay cong cu: dung worker cu, xoa ket qua probe loi de quet lai bang cong cu moi.
    param([string]$Reason = 'công cụ thay đổi')
    Write-FileLog "INFO Tạo lại media worker ($Reason)."
    Stop-MediaWorker
    foreach ($k in @($script:probeCache.Keys)) { if ($script:probeCache[$k].Error) { $script:probeCache.Remove($k) } }
    if ($script:galleryScanReady -and $script:currentPage -eq 'library') { Update-Gallery }
}

function Request-MediaJob {
    param([hashtable]$Job)
    if ($SelfTest) { return }
    $w = Start-MediaWorker
    try { $w.Jobs.Add([pscustomobject]$Job) }
    catch { Write-FileLog "WARN Request-MediaJob: $($_.Exception.Message)" }
}

function Receive-MediaResults {
    $w = $script:mediaWorker
    if (-not $w) { return }   # timer dung o Complete-StoppedMediaWorkers khi khong con worker nao
    $item = $null; $n = 0
    while ($n -lt 25 -and $w.Results.TryDequeue([ref]$item)) {
        $n++
        try {
            if ($item.Kind -eq 'scan') { Complete-GalleryScan $item } else { Apply-GalleryProbe $item }
        } catch { Write-FileLog "ERR  media result ($($item.Kind)): $($_.Exception.Message)`r`n$($_.ScriptStackTrace)" }
    }
    if ($w.State -and $w.State['Warn']) { Write-FileLog "WARN media worker: $($w.State['Warn'])"; $w.State['Warn'] = '' }
    if ($w.Async.IsCompleted -and -not $w.Reported) {
        # G-R9: worker chet ngoai y muon -> Kho bao loi + nut Thu lai; giai phong runspace.
        $w.Reported = $true
        $why = try { if ($w.PS.Streams.Error.Count) { [string]$w.PS.Streams.Error[0] } else { 'kết thúc' } } catch { $_.Exception.Message }
        Write-FileLog "WARN media worker dừng: $why"
        $script:mediaWorker = $null
        [void]$script:mediaWorkersStopping.Add([pscustomobject]@{ PS = $w.PS; Async = $w.Async; StopHandle = $null; Since = [DateTime]::UtcNow })
        $script:galleryState = 'error'
        Set-GalleryState error "Trình đọc kho dừng bất ngờ ($why). Bấm Thử lại để quét lại."
        Add-Log "Trình quét kho dừng bất ngờ: $why" 'Warning'
    }
}

# ------------------------------------------------------------- kho video (ListView ao hoa) ----
function Format-Duration {
    param([double]$Seconds)
    if ($Seconds -le 0 -or [double]::IsNaN($Seconds)) { return '' }
    $t = [TimeSpan]::FromSeconds([Math]::Round($Seconds))
    if ($t.TotalHours -ge 1) { return ('{0}:{1:00}:{2:00}' -f [int]$t.TotalHours, $t.Minutes, $t.Seconds) }
    return ('{0}:{1:00}' -f [int]$t.TotalMinutes, $t.Seconds)
}

function Get-ThumbImage {
    param([string]$Path)
    if (-not $Path -or -not [System.IO.File]::Exists($Path)) { return $null }
    $key = $Path + '|' + [System.IO.File]::GetLastWriteTimeUtc($Path).Ticks
    if ($script:thumbCache.ContainsKey($key)) { return $script:thumbCache[$key] }
    try {
        $bmp = New-Object Windows.Media.Imaging.BitmapImage
        $bmp.BeginInit()
        $bmp.CacheOption = [Windows.Media.Imaging.BitmapCacheOption]::OnLoad      # doc xong dong file, khong khoa
        $bmp.CreateOptions = [Windows.Media.Imaging.BitmapCreateOptions]::IgnoreImageCache
        $bmp.DecodePixelWidth = 216
        $bmp.UriSource = New-Object Uri($Path)
        $bmp.EndInit()
        $bmp.Freeze()
        $script:thumbCache[$key] = $bmp
        return $bmp
    } catch {
        Write-FileLog "WARN thumbnail '$Path': $($_.Exception.Message)"
        return $null
    }
}

function Get-TikTokHeldUntilUtc {
    # Latest tiktok_schedule_time (UTC) of the entries TikTok is holding; $null when none can be read.
    param([object[]]$Entries)
    $latest = $null
    foreach ($e in @($Entries)) {
        try {
            $when = [DateTimeOffset]::Parse([string]$e.tiktok_schedule_time, [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::AssumeUniversal).UtcDateTime
            if ($null -eq $latest -or $when -gt $latest) { $latest = $when }
        } catch { Write-FileLog "WARN Không đọc được giờ hẹn '$($e.tiktok_schedule_time)': $($_.Exception.Message)" }
    }
    return $latest
}

function New-GalleryItem {
    param($File, $Metadata, $Probe)
    $id = Get-KhoVideoKey ([string]$File.Name)
    $external = Test-KhoExternalKey $id
    $isPosted = ($null -ne $Metadata -and $Metadata.PSObject.Properties.Name -contains $id -and $Metadata.$id.Posted -eq $true)
    $postedDate = if ($isPosted -and $Metadata.$id.Date) { [string]$Metadata.$id.Date } else { '' }
    # D13: newest TikTok entry is a rejected native schedule -> "Hẹn lại" on the card menu (receipt read only for those rare cards).
    $reschedule = $null
    if ($null -ne $Metadata -and $Metadata.PSObject.Properties.Name -contains $id -and $Metadata.$id.History) {
        try { $reschedule = Get-TikTokRescheduleSeed -History @($Metadata.$id.History) -OutDir ([string]$File.Root) } catch { Write-FileLog "WARN Hẹn lại: $($_.Exception.Message)" }
    }
    $date = [DateTime]$File.LastWriteTime
    $sizeText = Format-Bytes ([double]$File.Length)
    $detail = 'Đang đọc thông tin…'
    $thumb = $null
    $thumbPath = ''
    if ($Probe -and $Probe.Stamp -eq $File.Stamp) {
        if ($Probe.Width -gt 0 -and $Probe.Height -gt 0) {
            $detail = (@((Format-Duration $Probe.Duration), ("$($Probe.Width)×$($Probe.Height) " + (Get-ResolutionLabel -Width $Probe.Width -Height $Probe.Height))) | Where-Object { $_ }) -join ' · '
        } elseif ($Probe.Error -eq 'ffprobe-missing') { $detail = 'Chưa có ffprobe để đọc thời lượng/độ phân giải' }
        else { $detail = 'Không đọc được thông tin video' }
        # Ep kieu: gia tri tra ve tu ham bi boc PSObject -> binding WPF khong nhan la ImageSource.
        $thumb = [Windows.Media.ImageSource](Get-ThumbImage $Probe.Thumb)
        if ($thumb) { $thumbPath = [string]$Probe.Thumb }
    }
    $metaText = $date.ToString('dd/MM/yy · HH:mm') + ' · ' + $sizeText
    $postedText = $(if ($isPosted) { 'Đã đăng TikTok' + $(if ($postedDate) { " · $postedDate" } else { '' }) } else { 'Chưa đăng TikTok' })
    # Nhan tren anh thu nho: ngan (dd/MM) de khong bi cat; ban day du (kem gio) o tooltip.
    $postedShort = $(if ($isPosted) { 'Đã đăng' + $(if ($postedDate) { ' · ' + $(if ($postedDate -match '^\s*(\d{1,2}/\d{1,2})') { $Matches[1] } else { ($postedDate.Trim() -split '\s+')[0] }) } else { '' }) } else { 'Chưa đăng' })
    $entry = if ($Metadata -and $Metadata.PSObject.Properties[$id]) { $Metadata.$id } else { $null }
    $postUrl = ''; $postId = ''; $linkKey = ''; $linkState = ''; $heldUntil = $null
    $manual = Get-ReupManualState $entry
    # The kho is the folder the file is in (a kho IS a folder); a folder nobody registered gives ''.
    $khoLib = $script:khoByPath[[string]$File.Root]
    $khoId = $(if ($khoLib) { [string]$khoLib.id } else { '' })
    if ($entry -and $entry.Source -eq 'autotok-history') {
        # Synced TikTok history (D3/D5): the badge is posted when marked manually OR a post succeeded.
        $history = @($entry.History | Where-Object { $null -ne $_ })
        $fileSha = [string]$entry.FileSha256
        $lines = @(foreach ($h in $history) { $(if ($h.username) { '@' + $h.username } else { 'Chưa rõ tài khoản' }) + ' · ' + (Get-TikTokEntryLabel $h $fileSha) })
        if ($manual.Posted) { $lines = @('Đã đánh dấu đăng thủ công' + $(if ($manual.Date) { ' · ' + $manual.Date } else { '' })) + $lines }
        if ($lines.Count) { $postedText = $lines -join "`n" }
        if ($isPosted) {
            $success = @($history | Where-Object { $_.status -eq 'succeeded' })
            $current = @($success | Where-Object { -not (Test-TikTokPriorVersion $_ $fileSha) })
            $postedShort = $(if (-not $manual.Posted -and $success.Count -and -not $current.Count) { 'Đã đăng (bản trước)' } else { 'Đã đăng' }) + $(if ($postedDate) { "`n$postedDate" } else { '' })
            $held = @($success | Where-Object { Test-TikTokHeldByTikTok $_ })
            if ($held.Count -and -not $manual.Posted) {
                $heldUntil = Get-TikTokHeldUntilUtc $held
                $postedShort = "Đã hẹn trên TikTok`n· " + (Format-TikTokClock ([string]$held[0].tiktok_schedule_time))
                $postedText = 'Đã hẹn trên TikTok · ' + (Format-TikTokClock ([string]$held[0].tiktok_schedule_time)) + "`nTikTok giữ bài và tự đăng đúng giờ; có thể tắt máy.`n" + $postedText
            }
        } elseif ($history.Count) { $postedShort = Get-TikTokEntryShort $history[0] }
        $linkEntry = @($history | Where-Object { $_.status -eq 'succeeded' -and $_.key } | Sort-Object { Get-TikTokSortKey ([string]$_.accepted_at) } -Descending | Select-Object -First 1)
        if ($linkEntry.Count) { $postId = $(if (Test-TikTokPostId ([string]$linkEntry[0].post_id)) { [string]$linkEntry[0].post_id } else { '' }); $postUrl = $(if (Test-TikTokPostUrl ([string]$linkEntry[0].post_url)) { [string]$linkEntry[0].post_url } else { '' }); $linkKey = [string]$linkEntry[0].key; $linkState = [string]$linkEntry[0].link_state }
    } elseif ($isPosted -and (Test-TikTokEnabled)) {
        $postedShort = 'Đã đăng' + $(if ($postedDate) { "`n$postedDate" } else { '' })
        $postedText += ' (đánh dấu thủ công)'
    }
    $khoName = $(if ($khoLib) { [string]$khoLib.name } else { '' })
    $statusName = $(if ($heldUntil -and $heldUntil -gt [DateTime]::UtcNow) { 'Đã hẹn' } elseif ($isPosted) { 'Đã đăng' } else { 'Chờ đăng' })
    return [pscustomobject]@{
        Path = [string]$File.FullName; Id = $id; Title = (Get-ReelLabel $id); External = $external; Reschedule = $reschedule; ThumbKey = (Get-KhoThumbKey $id); FileName = [string]$File.Name; Date = $date; Stamp = [string]$File.Stamp
        MetaText = $metaText; DetailText = $detail; Posted = [bool]$isPosted; ManualPosted = [bool]$manual.Posted; PostedText = $postedText; PostedShort = $postedShort
        PostedMultiline = $postedShort.Contains("`n")
        Thumb = $thumb; ThumbPath = $thumbPath; File = $File
        PostUrl = $postUrl; PostId = $postId; LinkKey = $linkKey; LinkState = $linkState
        Kho = $khoId; Root = [string]$File.Root; HeldUntil = $heldUntil; KhoName = $khoName; AutomationText = "$(Get-ReelLabel $id) · $statusName · $khoName"
        # Chu ky hien thi: giong nhau -> giu nguyen doi tuong cu (khong tao lai the, giu cuon/chon).
        Signature = ([string]$File.Stamp + '|' + $metaText + '|' + $detail + '|' + $postedText + '|' + $postedShort + '|' + [bool]$manual.Posted + '|' + $thumbPath + '|' + $postUrl + '|' + $postId + '|' + $linkState + '|' + $khoId + '|' + $khoName + '|' + $(if ($reschedule) { 'R' + $reschedule.RequestId } else { '' }))
    }
}

function Set-GalleryAll {
    # Dat danh sach Kho day du + chi muc duong dan -> vi tri (G-R7).
    param([object[]]$Items)
    $script:galleryAll = @($Items)
    $map = @{}
    for ($i = 0; $i -lt $script:galleryAll.Count; $i++) { $map[[string]$script:galleryAll[$i].Path] = $i }
    $script:galleryIndexByPath = $map
}

function Set-GalleryState {
    param([ValidateSet('hidden', 'loading', 'empty', 'nomatch', 'khoempty', 'missing', 'error')][string]$State, [string]$Text = '')
    if (-not $ui.GalleryState) { return }
    if ($State -eq 'hidden') { $ui.GalleryState.Visibility = 'Collapsed'; return }
    $spec = switch ($State) {
        'loading' { @(0xE895, 'Đang quét kho…', 'Đang đọc các thư mục kho ở nền; cứ dùng giao diện bình thường nhé.') }
        'empty'   { @(0xE8F1, 'Kho trống', 'Chưa có video nào — dán link ở trang Nguồn nhé!') }
        'khoempty' { @(0xE8F1, 'Kho này chưa có video.', 'Thêm video từ một thư mục, chuyển video từ kho khác sang, hoặc chọn kho này ở trang Nguồn rồi tải video về.') }
        'nomatch' { @(0xE71C, 'Không có video phù hợp', 'Thử đổi bộ lọc ngày, kho, trạng thái hoặc từ khóa tìm kiếm.') }
        'missing' { @(0xE8B7, 'Chưa thấy thư mục kho', 'Kiểm tra ổ đĩa, hoặc đổi thư mục kho trong Quản lý kho nhé.') }
        default   { @(0xEA39, 'Không đọc được kho', 'Dữ liệu được giữ nguyên; kiểm tra quyền truy cập rồi bấm Thử lại.') }
    }
    $isError = ($State -eq 'error')
    $ui.TxtGalleryStateGlyph.Text = [string][char]$spec[0]
    $ui.TxtGalleryStateGlyph.Foreground = Get-Brush 'TextPrimary'
    if ($ui.BadgeGalleryGlyph) {
        $ui.BadgeGalleryGlyph.Visibility = $(if ($isError -or $State -eq 'missing') { 'Visible' } else { 'Collapsed' })
        $ui.BadgeGalleryGlyph.Background = Get-Brush $(if ($isError) { 'DangerSubtle' } else { 'WarningSubtle' })
    }
    if ($ui.ImgGalleryMascot) { $ui.ImgGalleryMascot.Visibility = $(if ($isError -or $State -eq 'missing') { 'Collapsed' } else { 'Visible' }) }
    if ($ui.PanelKhoEmptyActions) { $ui.PanelKhoEmptyActions.Visibility = $(if ($State -eq 'khoempty') { 'Visible' } else { 'Collapsed' }) }
    if ($ui.BtnGalleryRetry) { $ui.BtnGalleryRetry.Visibility = $(if ($isError) { 'Visible' } else { 'Collapsed' }) }
    $ui.TxtGalleryStateTitle.Text = $spec[1]
    $ui.TxtGalleryStateText.Text = $(if ($Text) { $Text } else { $spec[2] })
    $ui.GalleryState.Visibility = 'Visible'
}

function Update-Gallery {
    # Quet kho chay nen (media worker); ket qua ve qua Complete-GalleryScan tren UI thread.
    # Chi quet sau khi da nap settings.json: khong tao anh thu nho trong thu muc xuat mac dinh luc khoi dong (G-E2E).
    Update-RejectedDashboard
    if (Get-Command Update-LinkDuplicateWarning -ErrorAction SilentlyContinue) { Update-LinkDuplicateWarning }
    if (-not $script:galleryScanReady) { return }
    $script:galleryGen++
    Update-KhoKnown
    $roots = @(Get-KhoRoots | Where-Object { [System.IO.Directory]::Exists($_) })
    if (-not $roots.Count) {
        Set-GalleryAll @(); $script:galleryState = 'ready'
        Apply-GalleryFilter
        Set-GalleryState missing
        return
    }
    try {
        $metas = @{}
        foreach ($r in $roots) { $metas[$r] = Get-ReupMetadata -OutDir $r }
        $script:galleryMetaByRoot = $metas
    }
    catch {
        $script:galleryState = 'error'
        $script:galleryCountBase = 'Không đọc được lịch sử đã đăng'
        $ui.TxtGalleryCount.Text = $script:galleryCountBase
        Set-GalleryState error 'Không đọc được lịch sử đã đăng. Dữ liệu được giữ nguyên; kiểm tra file reup-status.json của các kho rồi bấm Thử lại.'
        Add-Log $_.Exception.Message 'Danger'
        # A transient sharing collision (IO read error, kept after retries) is only logged; corrupt data still toasts.
        if ($_.Exception.Message -like 'Không đọc được lịch sử TikTok*') { Write-FileLog "WARN Get-ReupMetadata (va cham doc/ghi): $($_.Exception.Message)" }
        else { Show-Toast 'Không đọc được lịch sử đã đăng. Xem Cài đặt › Nhật ký.' -Kind error }
        return
    }
    $script:galleryState = 'loading'
    if (-not @($script:galleryAll).Count) { Set-GalleryState loading }
    if ($SelfTest) { return }
    Request-MediaJob @{ Kind = 'scan'; Gen = $script:galleryGen; Dirs = $roots }
}

function Complete-GalleryScan {
    param($Result)
    if ($Result.Gen -ne $script:galleryGen) { return }
    $bad = @($Result.Roots | Where-Object { $_.Error })
    if ($Result.Error -or $bad.Count) {
        $script:galleryState = 'error'
        $why = $(if ($bad.Count) { ($bad | ForEach-Object { "$($_.Dir): $($_.Error)" }) -join '; ' } else { [string]$Result.Error })
        Set-GalleryState error ("Không đọc được thư mục kho: " + $why)
        Add-Log "Không quét được kho: $why" 'Danger'
        return
    }
    $sw = [Diagnostics.Stopwatch]::StartNew()
    Update-KhoKnown
    $items = New-Object System.Collections.ArrayList
    $files = New-Object System.Collections.Generic.List[object]
    foreach ($r in @($Result.Roots)) { foreach ($f in @($r.Files)) { $files.Add($f) } }
    $ordered = $(if (@($Result.Roots).Count -gt 1) { @($files | Sort-Object -Property @{ Expression = { $_.LastWriteTime }; Descending = $true }) } else { $files.ToArray() })
    foreach ($f in $ordered) {
        $new = New-GalleryItem -File $f -Metadata (Get-GalleryMetaFor ([string]$f.Root)) -Probe $script:probeCache[[string]$f.FullName]
        # G-R6: giu doi tuong cu neu noi dung hien thi khong doi -> ListView khong tao lai the, giu cuon/chon.
        $oldIdx = $script:galleryIndexByPath[[string]$f.FullName]
        if ($null -ne $oldIdx -and $oldIdx -lt @($script:galleryAll).Count) {
            $old = $script:galleryAll[$oldIdx]
            if ($old -and $old.Path -eq $new.Path -and $old.Signature -eq $new.Signature) { $new = $old }
        }
        [void]$items.Add($new)
    }
    Set-GalleryAll @($items)
    Update-GalleryDateChoices
    $script:galleryState = 'ready'
    Apply-GalleryFilter
    Test-KhoLowStock
    if ($ui.GalleryList -and $ui.GalleryList.IsVisible) { $ui.GalleryList.UpdateLayout() }
    $sw.Stop()
    $script:galleryLastBuildMs = $sw.Elapsed.TotalMilliseconds
    # Lay thong tin/anh thu nho cho muc chua co (thu tu dang hien thi truoc).
    foreach ($it in $script:galleryAll) {
        $cached = $script:probeCache[$it.Path]
        if (-not $cached -or $cached.Stamp -ne $it.Stamp) { Request-MediaJob @{ Kind = 'probe'; Gen = $script:galleryGen; Path = $it.Path; Id = $it.ThumbKey } }
    }
}

function Apply-GalleryProbe {
    # G-R7: tra muc bang hashtable duong dan -> vi tri (O(1) moi ket qua), khong quet hai vong.
    param($Result)
    if (-not $Result.Path) { return }
    $path = [string]$Result.Path
    $script:probeCache[$path] = $Result
    if ($Result.Error -and $Result.Error -ne 'ffprobe-missing') { Write-FileLog "WARN probe '$path': $($Result.Error)" }
    $i = $script:galleryIndexByPath[$path]
    if ($null -eq $i -or $i -ge @($script:galleryAll).Count) { return }
    $old = $script:galleryAll[$i]
    if (-not $old -or $old.Path -ne $path) { return }
    $new = New-GalleryItem -File $old.File -Metadata (Get-GalleryMetaFor ([string]$old.Root)) -Probe $Result
    if ($new.Signature -eq $old.Signature) { return }
    $script:galleryAll[$i] = $new
    $pos = $script:galleryRowIndexByPath[$path]
    if ($null -ne $pos -and $pos -lt $script:galleryRows.Count -and [object]::ReferenceEquals($script:galleryRows[$pos], $old)) {
        $wasSelected = $ui.GalleryList.SelectedItems.Contains($old)
        $script:gallerySyncing = $true
        try {
            $script:galleryRows[$pos] = $new
            if ($wasSelected -and -not $ui.GalleryList.SelectedItems.Contains($new)) { [void]$ui.GalleryList.SelectedItems.Add($new) }
        } finally { $script:gallerySyncing = $false }
    }
}

function Update-GalleryDateChoices {
    if (-not $ui.CmbFilterSpecificDate) { return }
    $script:updatingCombo = $true
    try {
        $current = if ($ui.CmbFilterSpecificDate.SelectedItem) { [string]$ui.CmbFilterSpecificDate.SelectedItem.Tag } else { '' }
        $ui.CmbFilterSpecificDate.Items.Clear()
        $groups = @($script:galleryAll | Group-Object { $_.Date.ToString('yyyy-MM-dd') } | Sort-Object Name -Descending)
        foreach ($g in $groups) {
            $item = New-Object Windows.Controls.ComboBoxItem
            $d = [DateTime]::ParseExact($g.Name, 'yyyy-MM-dd', [Globalization.CultureInfo]::InvariantCulture)
            $item.Content = ('{0:dd/MM/yyyy} ({1} video)' -f $d, $g.Count)
            $item.Tag = $g.Name
            [void]$ui.CmbFilterSpecificDate.Items.Add($item)
            if ($g.Name -eq $current) { $ui.CmbFilterSpecificDate.SelectedItem = $item }
        }
    } finally { $script:updatingCombo = $false }
}

# ------------------------------------------------------------- kho: dem, bo loc, chuyen kho (UI) ----
$script:khoKnown = @{}                    # ma kho dang co trong registry
$script:khoNames = @{}                    # ma kho -> ten hien tren the (chip kho)
$script:khoByPath = @{}                   # thu muc kho (chuan hoa) -> kho
$script:galleryMetaByRoot = @{}           # thu muc kho -> reup-status.json da doc (cho khung Kho va lich)
$script:khoCounts = @{}                   # ma kho -> [int[]] chờ đăng / đã hẹn / đã đăng
$script:khoComboSig = ''
$script:galleryTabCounts = [int[]]@(0, 0, 0)   # chờ đăng / đã hẹn / đã đăng theo bộ lọc ngày + kho + tìm kiếm hiện tại
# Chữ kho: một dòng, cắt bằng dấu … khi quá dài (ô đóng và danh sách thả xuống không tràn sang khung xem trước).
$script:khoItemTemplate = [Windows.Markup.XamlReader]::Parse('<DataTemplate xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"><TextBlock Text="{Binding}" TextTrimming="CharacterEllipsis" MaxWidth="300"/></DataTemplate>')
$script:khoDownloadSig = ''
$script:khoLowWarned = @{}                # kho tai khoan da bao sap het trong phien nay
$script:galleryNowUtc = [DateTime]::UtcNow

function Get-GalleryBucket {
    # pending (chờ đăng) | held (đã hẹn trên TikTok, giờ hẹn chưa tới) | posted (đã đăng). Bộ nhớ, không đọc file.
    param($Item, [DateTime]$NowUtc = [DateTime]::UtcNow)
    if ($Item.HeldUntil -and $Item.HeldUntil -gt $NowUtc) { return 'held' }
    if ($Item.Posted) { return 'posted' }
    return 'pending'
}

function Update-KhoKnown {
    # Registry ids / folders as sets; computed once per gallery build, not per item.
    $known = @{}; $names = @{}; $byPath = @{}
    foreach ($lib in @((Get-KhoRegistry).libraries)) { $known[[string]$lib.id] = $true; $names[[string]$lib.id] = [string]$lib.name; $byPath[[string]$lib.path] = $lib }
    $script:khoKnown = $known; $script:khoNames = $names; $script:khoByPath = $byPath
}

function Get-GalleryMetaFor {
    # reup-status.json (already read) of one kho folder; $null when unknown.
    param([Alias('Root')][string]$KhoRoot)
    if (-not $KhoRoot -or -not $script:galleryMetaByRoot) { return $null }
    return $script:galleryMetaByRoot[$KhoRoot]
}

function Select-GalleryItems {
    # One pass over $script:galleryAll (memory only): the items that pass the date / kho / status / search filters, and (with
    # -UpdateCounts) the per-kho counts of pending/held/posted of ALL items. No per-item function call: 2,500 items stay fast.
    param([DateTime]$Today, [switch]$UpdateCounts)
    $known = @{}; $counts = @{}
    foreach ($lib in @((Get-KhoRegistry).libraries)) { $known[[string]$lib.id] = $true; $counts[[string]$lib.id] = [int[]]@(0, 0, 0) }
    if ($script:filterKho -ne 'all' -and -not $known.ContainsKey($script:filterKho)) { $script:filterKho = 'all' }
    $now = $script:galleryNowUtc
    $fd = [string]$script:filterDate
    $dateMode = 0; $d1 = $Today; $d2 = $Today
    if ($fd -eq 'today') { $dateMode = 1 }
    elseif ($fd -eq 'yesterday') { $dateMode = 1; $d1 = $Today.AddDays(-1) }
    elseif ($fd -eq '7days') { $dateMode = 2; $d1 = $Today.AddDays(-6) }
    elseif ($fd -match '^\d{4}-\d{2}-\d{2}$') { $dateMode = 3 }
    $khoFilter = [string]$script:filterKho; $search = [string]$script:filterSearch
    $statusIdx = switch ([string]$script:filterStatus) { 'pending' { 0 } 'held' { 1 } 'posted' { 2 } default { -1 } }
    $out = New-Object System.Collections.ArrayList
    $tab = [int[]]@(0, 0, 0)   # status tab counts: current date + kho + search filters, any status
    foreach ($it in $script:galleryAll) {
        $k = [string]$it.Kho
        $b = if ($it.HeldUntil -and $it.HeldUntil -gt $now) { 1 } elseif ($it.Posted) { 2 } else { 0 }
        if ($UpdateCounts -and $counts.ContainsKey($k)) { $counts[$k][$b]++ }
        if ($dateMode) {
            $d = $it.Date.Date
            if ($dateMode -eq 1) { if ($d -ne $d1) { continue } }
            elseif ($dateMode -eq 2) { if ($d -lt $d1 -or $d -gt $d2) { continue } }
            elseif ($it.Date.ToString('yyyy-MM-dd') -ne $fd) { continue }
        }
        if ($khoFilter -ne 'all' -and $k -cne $khoFilter) { continue }
        if ($search -and $it.Id.IndexOf($search, [StringComparison]::OrdinalIgnoreCase) -lt 0) { continue }
        $tab[$b]++
        if ($statusIdx -ge 0 -and $b -ne $statusIdx) { continue }
        [void]$out.Add($it)
    }
    if ($UpdateCounts) { $script:khoKnown = $known; $script:khoCounts = $counts; $script:galleryTabCounts = $tab }
    return , $out
}

function Format-KhoCounts {
    # "7 chờ đăng · 3 đã đăng": phần bằng 0 bị bỏ; kho trống -> "chưa có video".
    param([int[]]$Counts)
    $parts = @()
    if ($Counts[0]) { $parts += ('{0} chờ đăng' -f $Counts[0]) }
    if ($Counts[1]) { $parts += ('{0} đã hẹn' -f $Counts[1]) }
    if ($Counts[2]) { $parts += ('{0} đã đăng' -f $Counts[2]) }
    if (-not $parts.Count) { return 'chưa có video' }
    return ($parts -join ' · ')
}

function Update-GalleryKhoSelector {
    # Rebuilds the kho selector / status tab labels / download combo only when their text changed.
    if (-not $ui.CmbKho) { return }
    $libs = @((Get-KhoRegistry).libraries)
    if ($script:filterKho -ne 'all' -and -not $script:khoKnown.ContainsKey($script:filterKho)) { $script:filterKho = 'all' }
    $total = [int[]]@(0, 0, 0)
    foreach ($v in $script:khoCounts.Values) { for ($n = 0; $n -lt 3; $n++) { $total[$n] += $v[$n] } }
    $entries = New-Object System.Collections.Generic.List[object]
    $entries.Add(@{ Id = 'all'; Text = 'Tất cả kho — ' + (Format-KhoCounts $total) })
    foreach ($lib in $libs) {
        $c = $script:khoCounts[[string]$lib.id]; if (-not $c) { $c = [int[]]@(0, 0, 0) }
        $entries.Add(@{ Id = [string]$lib.id; Text = [string]$lib.name + ' — ' + (Format-KhoCounts $c) })
    }
    $sig = (@($entries | ForEach-Object { $_.Id + '=' + $_.Text }) -join "`n")
    $script:updatingCombo = $true
    try {
        if ($sig -ne $script:khoComboSig) {
            $ui.CmbKho.Items.Clear()
            foreach ($e in $entries) { $ci = New-Object Windows.Controls.ComboBoxItem; $ci.Content = $e.Text; $ci.Tag = $e.Id; $ci.ToolTip = $e.Text; $ci.ContentTemplate = $script:khoItemTemplate; [void]$ui.CmbKho.Items.Add($ci) }
            $script:khoComboSig = $sig
        }
        $sel = $ui.CmbKho.SelectedItem
        if (-not $sel -or [string]$sel.Tag -cne $script:filterKho) {
            foreach ($ci in $ui.CmbKho.Items) { if ([string]$ci.Tag -ceq $script:filterKho) { $ui.CmbKho.SelectedItem = $ci; break } }
        }
        $dsig = (@($libs | ForEach-Object { $_.id + '=' + $_.name }) -join "`n") + '|' + (Get-KhoDownloadTarget)
        if ($ui.CmbDownloadKho -and $dsig -ne $script:khoDownloadSig) {
            $ui.CmbDownloadKho.Items.Clear()
            $target = Get-KhoDownloadTarget
            foreach ($lib in $libs) {
                $ci = New-Object Windows.Controls.ComboBoxItem; $ci.Content = [string]$lib.name; $ci.Tag = [string]$lib.id
                [void]$ui.CmbDownloadKho.Items.Add($ci)
                if ([string]$lib.id -ceq $target) { $ui.CmbDownloadKho.SelectedItem = $ci }
            }
            $script:khoDownloadSig = $dsig
        }
    } finally { $script:updatingCombo = $false }
    $sc = $script:galleryTabCounts
    $ui.TabStAll.Content = 'Tất cả ({0})' -f ($sc[0] + $sc[1] + $sc[2])
    $ui.TabStPending.Content = 'Chờ đăng ({0})' -f $sc[0]
    $ui.TabStHeld.Content = 'Đã hẹn ({0})' -f $sc[1]
    $ui.TabStPosted.Content = 'Đã đăng ({0})' -f $sc[2]
}

function Test-KhoLowStock {
    # Once per session per account kho: toast when its pending (chờ đăng) count falls below the kho's threshold.
    if ($script:galleryState -ne 'ready' -or -not @($script:galleryAll).Count) { return }
    $low = New-Object System.Collections.Generic.List[string]
    foreach ($lib in @((Get-KhoRegistry).libraries)) {
        $id = [string]$lib.id
        if (-not [string]$lib.account -or [int]$lib.lowStock -le 0 -or $script:khoLowWarned.ContainsKey($id)) { continue }
        $c = $script:khoCounts[$id]; if (-not $c) { continue }
        if ($c[0] -lt [int]$lib.lowStock) { $script:khoLowWarned[$id] = $true; $low.Add(('{0} (còn {1})' -f $lib.name, $c[0])) }
    }
    if ($low.Count) { Show-Toast ('Sắp hết video chờ đăng: ' + ($low -join ', ') + '. Thêm video vào kho nhé.') -Kind warning }
}

function Update-MoveSelectedButton {
    if (-not $ui.BtnMoveSelected -or -not $ui.GalleryList) { return }
    $n = $ui.GalleryList.SelectedItems.Count
    # Thanh chọn nhiều là lớp phủ ở đáy lưới: hiện/ẩn không làm lưới nhảy.
    $ui.PanelSelBar.Visibility = $(if ($n -ge 2) { 'Visible' } else { 'Collapsed' })
    if ($n -ge 2) { $ui.TxtSelCount.Text = "Đã chọn $n video"; $ui.TxtMoveSelected.Text = "Chuyển $n video sang kho…" }
    if ($ui.BtnSpreadSelected) { $ui.BtnSpreadSelected.Visibility = $(if (Test-TikTokEnabled) { 'Visible' } else { 'Collapsed' }) }
    Update-SpreadButtons
}

function Clear-GallerySelection {
    if ($ui.GalleryList -and $ui.GalleryList.SelectedItems.Count) { $ui.GalleryList.UnselectAll() }
}

function Reset-GalleryScroll {
    # Đổi kho/tab: lưới về đầu để không nhìn nhầm chỗ trống giữa danh sách.
    $queue = New-Object System.Collections.Generic.Queue[object]
    $queue.Enqueue($ui.GalleryList)
    while ($queue.Count) {
        $node = $queue.Dequeue()
        if ($node -is [Windows.Controls.ScrollViewer]) { $node.ScrollToTop(); return }
        for ($i = 0; $i -lt [Windows.Media.VisualTreeHelper]::GetChildrenCount($node); $i++) { $queue.Enqueue([Windows.Media.VisualTreeHelper]::GetChild($node, $i)) }
    }
}

function Update-GalleryItemsFromMeta {
    # Re-reads reup-status.json only (no media scan) and rebuilds the cards of the given video ids (or every card when no id).
    param([string[]]$Ids = @(), [switch]$Force)   # -Force: thay luôn thẻ dù chữ ký không đổi (đổi tên kho -> chip kho)
    try {
        $metas = @{}
        foreach ($r in @(Get-KhoRoots | Where-Object { [System.IO.Directory]::Exists($_) })) { $metas[$r] = Get-ReupMetadata -OutDir $r }
        $script:galleryMetaByRoot = $metas
    }
    catch {
        Add-Log $_.Exception.Message 'Danger'
        Show-Toast 'Không đọc được lịch sử đã đăng để cập nhật kho. Bấm Làm mới để thử lại.' -Kind error
        return
    }
    Update-KhoKnown
    $idSet = @{}; foreach ($id in @($Ids)) { $idSet[[string]$id] = $true }
    for ($i = 0; $i -lt @($script:galleryAll).Count; $i++) {
        $old = $script:galleryAll[$i]
        if ($idSet.Count -and -not $idSet.ContainsKey([string]$old.Id)) { continue }
        $new = New-GalleryItem -File $old.File -Metadata (Get-GalleryMetaFor ([string]$old.Root)) -Probe $script:probeCache[[string]$old.Path]
        if ($Force -or $new.Signature -ne $old.Signature) { $script:galleryAll[$i] = $new }
    }
    Apply-GalleryFilter
}

function Update-GalleryHeldExpired {
    # Every 60 s while the Library page is visible: a video whose TikTok schedule time has passed moves from "Đã hẹn" to "Đã đăng".
    # Memory only: no network, no media scan, no file read.
    if ($script:currentPage -ne 'library' -or $script:galleryState -ne 'ready') { return }
    if (-not $ui.PanelLibVideos -or $ui.PanelLibVideos.Visibility -ne 'Visible') { return }
    $now = [DateTime]::UtcNow; $changed = $false
    for ($i = 0; $i -lt @($script:galleryAll).Count; $i++) {
        $old = $script:galleryAll[$i]
        if (-not $old.HeldUntil -or $old.HeldUntil -gt $now) { continue }
        $new = New-GalleryItem -File $old.File -Metadata (Get-GalleryMetaFor ([string]$old.Root)) -Probe $script:probeCache[[string]$old.Path]
        $script:galleryAll[$i] = $new; $changed = $true
    }
    if ($changed) { Apply-GalleryFilter }
}

# ------------------------------------------------------------- chọn bằng khung kéo (D11) ----
function Get-RubberBandHits {
    # Hàm thuần: chỉ số các ô của KidWrapPanel giao với khung kéo. Hình học giống panel: ô ItemWidth x ItemHeight, $Columns ô mỗi hàng, lề trái (ViewportWidth - Columns*ItemWidth)/2,
    # hàng r nằm ở y = r*ItemHeight trong "không gian nội dung" (đã cộng độ cuộn). Điểm neo (AnchorX/AnchorY) ở không gian nội dung; con trỏ (PointX/PointY) ở tọa độ khung nhìn nên cộng ScrollOffset hiện tại.
    # Chạm cạnh không tính. Không tạo container nào: chỉ tính số học, nên cuộn ảo hóa không ảnh hưởng.
    param([double]$AnchorX, [double]$AnchorY, [double]$PointX, [double]$PointY, [double]$ScrollOffset, [double]$ItemWidth, [double]$ItemHeight, [int]$Columns, [double]$ViewportWidth, [int]$Count)
    if ($Count -le 0 -or $Columns -le 0 -or $ItemWidth -le 0 -or $ItemHeight -le 0) { return @() }
    $x1 = [Math]::Min($AnchorX, $PointX); $x2 = [Math]::Max($AnchorX, $PointX)
    $py = $PointY + $ScrollOffset
    $y1 = [Math]::Min($AnchorY, $py); $y2 = [Math]::Max($AnchorY, $py)
    if ($x2 -le $x1 -or $y2 -le $y1) { return @() }
    $left = [Math]::Max(0.0, ($ViewportWidth - $Columns * $ItemWidth) / 2.0)
    $rowFirst = [Math]::Max(0, [int][Math]::Floor($y1 / $ItemHeight))
    $rowLast = [int][Math]::Ceiling($y2 / $ItemHeight) - 1
    $hits = New-Object 'System.Collections.Generic.List[int]'
    for ($r = $rowFirst; $r -le $rowLast; $r++) {
        for ($col = 0; $col -lt $Columns; $col++) {
            $cl = $left + $col * $ItemWidth
            if ($x2 -le $cl -or $x1 -ge $cl + $ItemWidth) { continue }
            $idx = $r * $Columns + $col
            if ($idx -lt $Count) { $hits.Add($idx) }
        }
    }
    return $hits.ToArray()
}

function Find-GalleryVisualChild {
    param($VisualRoot, [Type]$Type)
    $q = New-Object System.Collections.Generic.Queue[object]; $q.Enqueue($VisualRoot)
    while ($q.Count) {
        $n = $q.Dequeue()
        if ($Type.IsInstanceOfType($n)) { return $n }
        if ($n -is [Windows.Media.Visual]) { for ($i = 0; $i -lt [Windows.Media.VisualTreeHelper]::GetChildrenCount($n); $i++) { $q.Enqueue([Windows.Media.VisualTreeHelper]::GetChild($n, $i)) } }
    }
    return $null
}

$script:band = $null
$script:tBand = $null

function Get-BandPointer {
    # Pointer in panel coordinates. $global:KhoBandPointerOverride is a test seam (the WPF smoke injects the pointer; real use leaves it $null).
    param($Panel)
    if ($null -ne $global:KhoBandPointerOverride) { return $global:KhoBandPointerOverride }
    return [Windows.Input.Mouse]::GetPosition($Panel)
}

function Update-GalleryBand {
    # Vẽ khung và áp dụng lựa chọn theo vị trí con trỏ hiện tại (gọi khi chuột di chuyển và mỗi nhịp tự cuộn).
    $b = $script:band
    if (-not $b -or -not $b.Active) { return }
    $panel = $b.Panel
    $pos = Get-BandPointer $panel
    $vw = [double]$panel.ViewportWidth; $vh = [double]$panel.ViewportHeight
    $px = [Math]::Max(0.0, [Math]::Min($vw, $pos.X)); $py = [Math]::Max(0.0, [Math]::Min($vh, $pos.Y))
    $scroll = [double]$panel.VerticalOffset
    $hits = @(Get-RubberBandHits -AnchorX $b.AX -AnchorY $b.AY -PointX $px -PointY $py -ScrollOffset $scroll -ItemWidth $panel.ItemWidth -ItemHeight $panel.ItemHeight -Columns $panel.Columns -ViewportWidth $vw -Count $ui.GalleryList.Items.Count)
    # Khung vẽ trên lớp phủ (tọa độ khung nhìn); neo trôi theo độ cuộn.
    $ay = $b.AY - $scroll
    $tl = $panel.TranslatePoint([Windows.Point]::new([Math]::Min($b.AX, $px), [Math]::Min($ay, $py)), $ui.BandLayer)
    [Windows.Controls.Canvas]::SetLeft($ui.BandRect, $tl.X); [Windows.Controls.Canvas]::SetTop($ui.BandRect, $tl.Y)
    $ui.BandRect.Width = [Math]::Abs($px - $b.AX); $ui.BandRect.Height = [Math]::Abs($py - $ay)
    $ui.BandRect.Visibility = 'Visible'
    $sig = ($hits -join ',')
    if ($sig -ceq $b.Sig) { return }
    $b.Sig = $sig
    $want = New-Object 'System.Collections.Generic.List[object]'
    if ($b.Ctrl) { foreach ($s in $b.Base) { $want.Add($s) } }
    foreach ($i in $hits) { $item = $ui.GalleryList.Items[$i]; if ($want -notcontains $item) { $want.Add($item) } }
    $script:gallerySyncing = $true
    try {
        $ui.GalleryList.SelectedItems.Clear()
        foreach ($item in $want) { [void]$ui.GalleryList.SelectedItems.Add($item) }
    } finally { $script:gallerySyncing = $false }
    Update-MoveSelectedButton
}

function Start-GalleryBand {
    # Nhấn chuột trái ở chỗ TRỐNG của lưới (không phải thẻ, nút, thanh cuộn): ghi neo; khung chỉ bật khi kéo quá vài pixel, nên nhấp thường không đổi gì.
    param($Source, $EventArgs)
    $n = $Source
    while ($n -and $n -ne $ui.GalleryList) {
        if ($n -is [Windows.Controls.ListViewItem] -or $n -is [Windows.Controls.Primitives.ScrollBar] -or $n -is [Windows.Controls.Primitives.ButtonBase]) { return }
        $n = $(if ($n -is [Windows.Media.Visual]) { [Windows.Media.VisualTreeHelper]::GetParent($n) } else { $null })
    }
    $panel = Find-GalleryVisualChild $ui.GalleryList ([KidWrapPanel])
    if (-not $panel -or $ui.GalleryList.Items.Count -eq 0) { return }
    $pos = $EventArgs.GetPosition($panel)
    $ctrl = [bool]([Windows.Input.Keyboard]::Modifiers -band [Windows.Input.ModifierKeys]::Control)
    $script:band = @{ Panel = $panel; AX = $pos.X; AY = $pos.Y + [double]$panel.VerticalOffset; StartX = $pos.X; StartY = $pos.Y; Ctrl = $ctrl; Base = @($ui.GalleryList.SelectedItems); Active = $false; Sig = $null }
}

function Move-GalleryBand {
    param($EventArgs)
    $b = $script:band
    if (-not $b) { return }
    if ($EventArgs.LeftButton -ne [Windows.Input.MouseButtonState]::Pressed) { Stop-GalleryBand; return }
    if (-not $b.Active) {
        $pos = $EventArgs.GetPosition($b.Panel)
        if ([Math]::Abs($pos.X - $b.StartX) -lt 5 -and [Math]::Abs($pos.Y - $b.StartY) -lt 5) { return }
        $b.Active = $true
        $b.Captured = $(if ($null -ne $global:KhoBandPointerOverride) { $false } else { [bool]$ui.GalleryList.CaptureMouse() })   # test seam: an injected pointer has no real button down, so no capture (its synthetic mouse events would end the band)
        if (-not $script:tBand) {
            $script:tBand = New-Object Windows.Threading.DispatcherTimer
            $script:tBand.Interval = [TimeSpan]::FromMilliseconds(50)
            $script:tBand.Add_Tick({ try { Step-GalleryBandScroll } catch { Write-FileLog "WARN Khung kéo: $($_.Exception.Message)" } })
        }
        $script:tBand.Start()
    }
    Update-GalleryBand
}

function Step-GalleryBandScroll {
    # Tự cuộn khi con trỏ gần mép trên/dưới (hoặc ra ngoài) trong lúc kéo.
    $b = $script:band
    if (-not $b -or -not $b.Active) { if ($script:tBand) { $script:tBand.Stop() }; return }
    $pos = Get-BandPointer $b.Panel
    $vh = [double]$b.Panel.ViewportHeight
    $edge = 32.0
    $step = 0.0
    if ($pos.Y -lt $edge) { $step = -[Math]::Min(48.0, 8.0 + ($edge - $pos.Y) / 2.0) }
    elseif ($pos.Y -gt $vh - $edge) { $step = [Math]::Min(48.0, 8.0 + ($pos.Y - ($vh - $edge)) / 2.0) }
    if ($step -ne 0.0) { $b.Panel.SetVerticalOffset([double]$b.Panel.VerticalOffset + $step) }
    Update-GalleryBand
}

function Stop-GalleryBand {
    $b = $script:band
    $script:band = $null
    if ($script:tBand) { $script:tBand.Stop() }
    if ($b -and $b.Active) { try { $ui.GalleryList.ReleaseMouseCapture() } catch { Write-FileLog "WARN Khung kéo thả chuột: $($_.Exception.Message)" } }
    if ($ui.BandRect) { $ui.BandRect.Visibility = 'Collapsed' }
}

function Get-GalleryMoveTargets {
    # The whole multi-selection when the card is part of it, otherwise just the card.
    param($Item)
    $sel = @($ui.GalleryList.SelectedItems)
    if ($sel.Count -gt 1 -and @($sel | Where-Object { [string]$_.Path -eq [string]$Item.Path }).Count) { return $sel }
    return @($Item)
}

function Move-GalleryItemsToKho {
    # S1: the physical move runs only when the app is quiet; otherwise the owner is told to retry.
    param([object[]]$Items, [string]$KhoId)
    $picked = @($Items | Where-Object { $_ -and [string]$_.Id -and [string]$_.Path })
    if (-not $picked.Count) { return }
    $result = $null
    try { $result = Invoke-KhoMove -Items $picked -TargetId $KhoId -Reason manual }
    catch {
        Add-Log "Không chuyển kho được: $($_.Exception.Message)" 'Danger'
        Show-Toast ('Không chuyển kho được: ' + (Get-FriendlyError $_.Exception.Message)) -Kind error
        return
    }
    if ($result.Busy) { Show-Toast ("Đang bận ($($result.Busy))… thử lại sau.") -Kind warning; return }
    $name = [string]$result.Target.name
    $movedCount = @($result.Moved).Count; $failedCount = @($result.Failed).Count
    if ($movedCount) { Update-Gallery }
    if ($movedCount) { Show-Toast ("Đã chuyển $movedCount video sang $name.") -Kind success }
    if ($failedCount) {
        foreach ($x in @($result.Failed)) { Add-Log "Không chuyển được $(Get-ReelLabel ([string]$x.Id)): $($x.Why)" 'Warning' }
        $first = @($result.Failed)[0]
        Show-Toast ("Không chuyển được $failedCount video. $(Get-ReelLabel ([string]$first.Id)): $($first.Why)") -Kind warning
    }
    Test-KhoLowStock
}

function Add-KhoMoveEntries {
    # Danh sách kho phẳng (không menu con: giao diện menu không có popup con). Kho mà mọi video đã chọn đang ở đó thì tắt.
    param($Menu, [object[]]$Items)
    $count = @($Items).Count
    $head = New-Object Windows.Controls.MenuItem
    $head.Header = $(if ($count -gt 1) { "Chuyển $count video sang kho:" } else { 'Chuyển sang kho:' })
    $head.Tag = [string][char]0xE8B7
    $head.IsEnabled = $false
    [Windows.Automation.AutomationProperties]::SetName($head, [string]$head.Header)
    [void]$Menu.Items.Add($head)
    foreach ($lib in @((Get-KhoRegistry).libraries)) {
        $id = [string]$lib.id
        $here = 0
        foreach ($it in @($Items)) { if ([string]$it.Kho -ceq $id) { $here++ } }
        $all = ($here -ge $count)
        $sub = New-Object Windows.Controls.MenuItem
        $sub.Header = ([string]$lib.name).Replace('_', '__') + $(if ($all) { ' (đang ở đây)' } else { '' })
        if ($all) { $sub.Tag = [string][char]0xE73E }
        $sub.IsEnabled = (-not $all)
        $sub.CommandParameter = @{ Items = @($Items); KhoId = $id }
        [Windows.Automation.AutomationProperties]::SetName($sub, [string]$lib.name)
        $sub.Add_Click({
            param($sender, $eventArgs)
            $eventArgs.Handled = $true
            Move-GalleryItemsToKho -Items @($sender.CommandParameter.Items) -KhoId ([string]$sender.CommandParameter.KhoId)
        })
        [void]$Menu.Items.Add($sub)
    }
}

function Show-KhoMoveMenu {
    param($Target, [object[]]$Items, $Placement = [Windows.Controls.Primitives.PlacementMode]::Bottom)
    $menu = New-Object Windows.Controls.ContextMenu
    Add-KhoMoveEntries -Menu $menu -Items $Items
    $Target.ContextMenu = $menu; $menu.PlacementTarget = $Target; $menu.Placement = $Placement; $menu.IsOpen = $true
}

function Sync-GalleryRows {
    # G-R6: mot ObservableCollection duy nhat (gan ItemsSource mot lan); dong bo theo Path de giu vi tri cuon va muc dang chon.
    param([object[]]$Wanted)
    $rows = $script:galleryRows
    $selPaths = @{}
    if ($ui.GalleryList) { foreach ($s in @($ui.GalleryList.SelectedItems)) { $selPaths[[string]$s.Path] = $true } }
    $wantedList = @($Wanted)
    # Doi kho/tab co the doi hang nghin the: tinh so thay doi; nhieu thi dung lai ObservableCollection moi (khong bao tung thay doi cho ListView).
    $added = 0
    $indexNow = $script:galleryRowIndexByPath
    foreach ($w in $wantedList) { if (-not $indexNow.ContainsKey([string]$w.Path)) { $added++ } }
    $removed = $rows.Count - ($wantedList.Count - $added)
    $script:gallerySyncing = $true
    try {
        if ($added + $removed -gt 150) {
            $rows = New-Object 'System.Collections.ObjectModel.ObservableCollection[object]' -ArgumentList (, [object[]]$wantedList)
            $script:galleryRows = $rows
            if ($ui.GalleryList) { $ui.GalleryList.ItemsSource = $rows }
        } else {
            $wantedSet = @{}
            foreach ($w in $wantedList) { $wantedSet[[string]$w.Path] = $true }
            # 1) bo muc khong con trong danh sach can hien
            for ($i = $rows.Count - 1; $i -ge 0; $i--) { if (-not $wantedSet.ContainsKey([string]$rows[$i].Path)) { $rows.RemoveAt($i) } }
            # 2) dat dung thu tu: giu doi tuong cu neu giong; di chuyen neu lech; chen muc moi
            $current = @{}
            for ($i = 0; $i -lt $rows.Count; $i++) { $current[[string]$rows[$i].Path] = $rows[$i] }
            for ($i = 0; $i -lt $wantedList.Count; $i++) {
                $w = $wantedList[$i]
                $p = [string]$w.Path
                if ($i -lt $rows.Count -and [string]$rows[$i].Path -eq $p) {
                    if (-not [object]::ReferenceEquals($rows[$i], $w)) { $rows[$i] = $w }
                    continue
                }
                if ($current.ContainsKey($p)) {
                    $j = $rows.IndexOf($current[$p])
                    if ($j -gt $i) { $rows.Move($j, $i) }
                    if (-not [object]::ReferenceEquals($rows[$i], $w)) { $rows[$i] = $w }
                } else {
                    $rows.Insert($i, $w)
                }
            }
            while ($rows.Count -gt $wantedList.Count) { $rows.RemoveAt($rows.Count - 1) }
        }
        $map = @{}
        for ($i = 0; $i -lt $rows.Count; $i++) { $map[[string]$rows[$i].Path] = $i }
        $script:galleryRowIndexByPath = $map
        if ($ui.GalleryList) {
            if (-not [object]::ReferenceEquals($ui.GalleryList.ItemsSource, $rows)) { $ui.GalleryList.ItemsSource = $rows }
            # Giu lai tat ca muc dang chon (theo Path) sau khi doi tuong the bi thay; muc khong con hien thi thi bo chon.
            if ($selPaths.Count) {
                $chosen = @{}
                foreach ($s in @($ui.GalleryList.SelectedItems)) { $chosen[[string]$s.Path] = $s }
                foreach ($sp in @($selPaths.Keys)) {
                    if (-not $map.ContainsKey($sp)) { continue }
                    $row = $rows[$map[$sp]]
                    if (-not ($chosen.ContainsKey($sp) -and [object]::ReferenceEquals($chosen[$sp], $row))) { [void]$ui.GalleryList.SelectedItems.Add($row) }
                }
                foreach ($s in @($ui.GalleryList.SelectedItems)) { if (-not $map.ContainsKey([string]$s.Path)) { [void]$ui.GalleryList.SelectedItems.Remove($s) } }
            }
        }
    } finally { $script:gallerySyncing = $false }
}

function Apply-GalleryFilter {
    # Everything below runs in memory on $script:galleryAll: no file scan, no hashing, no network.
    $today = (Get-Date).Date
    $script:galleryNowUtc = [DateTime]::UtcNow
    $wanted = Select-GalleryItems -Today $today -UpdateCounts
    Update-GalleryKhoSelector
    $all = @($script:galleryAll).Count
    # Bo loc ngay lam rong Kho (ngay khong con video) -> ve "Tat ca ngay" + thong bao.
    if ($wanted.Count -eq 0 -and $all -gt 0 -and [string]$script:filterDate -ne 'all' -and -not $script:resettingDateFilter -and $script:galleryState -ne 'loading') {
        $saveSearch = $script:filterSearch; $saveKho = $script:filterKho; $saveStatus = $script:filterStatus
        try {
            $script:filterSearch = ''; $script:filterKho = 'all'; $script:filterStatus = 'all'
            $dateHits = $(Select-GalleryItems -Today $today).Count
        } finally { $script:filterSearch = $saveSearch; $script:filterKho = $saveKho; $script:filterStatus = $saveStatus }
        if ($dateHits -eq 0) {
            $script:resettingDateFilter = $true
            try {
                $script:filterDate = 'all'
                if ($ui.CmbDateFilter) { $ui.CmbDateFilter.SelectedIndex = 0 }
                if ($ui.CmbFilterSpecificDate) { $ui.CmbFilterSpecificDate.Visibility = 'Collapsed' }
            } finally { $script:resettingDateFilter = $false }
            Show-Toast 'Không còn video nào trong ngày đã chọn — đã chuyển về Tất cả ngày.' -Kind info
            $wanted = Select-GalleryItems -Today $today -UpdateCounts
            Update-GalleryKhoSelector
        }
    }
    $ui.GalleryList.Tag = $(if ($script:filterKho -eq 'all') { 'all' } else { 'one' })   # chip kho trên thẻ chỉ hiện khi xem Tất cả kho
    Sync-GalleryRows -Wanted @($wanted)
    $viewCount = $script:galleryRows.Count
    $script:galleryCountBase = if ($all -eq 0) { '0 video' } elseif ($viewCount -eq $all) { "$all video" } else { "Hiển thị $viewCount / $all video" }
    Update-GalleryCountText
    Update-MoveSelectedButton
    if ($script:galleryState -eq 'loading' -and $all -eq 0) { Set-GalleryState loading }
    elseif ($all -eq 0) { Set-GalleryState empty }
    elseif ($viewCount -eq 0) {
        # Danh sách rỗng: bỏ khung xem trước video cũ (trừ khi đang ghi/xử lý).
        if ($script:lastOut -and $script:galleryIndexByPath.ContainsKey([string]$script:lastOut) -and -not (Test-GalleryActionsBusy)) { Clear-Player }
        if ($script:filterKho -ne 'all' -and (Get-KhoTotalCount $script:filterKho) -eq 0) { Set-GalleryState khoempty } else { Set-GalleryState nomatch }
    }
    else { Set-GalleryState hidden }
}

function Set-GalleryPosted {
    # Manual posted mark (D3): flips only the manual flag; a synced TikTok success keeps the badge on.
    param($Item)
    $manualNow = if ($Item.PSObject.Properties['ManualPosted']) { [bool]$Item.ManualPosted } else { [bool]$Item.Posted }
    $newState = -not $manualNow
    if ($script:khoMoveRunning) { Show-Toast 'Đang chuyển kho. Thử lại sau.' -Kind warning; return }
    try { Set-ReupMetadata -VideoId $Item.Id -Posted $newState -OutDir ([string]$Item.Root) }
    catch {
        Add-Log $_.Exception.Message 'Danger'
        Show-Toast 'Không lưu được trạng thái đã đăng; dữ liệu cũ được giữ nguyên. Chi tiết trong Nhật ký.' -Kind error
        return
    }
    try { $script:galleryMetaByRoot[[string]$Item.Root] = Get-ReupMetadata -OutDir ([string]$Item.Root) } catch { Write-FileLog "WARN Get-ReupMetadata sau khi đánh dấu: $($_.Exception.Message)" }
    $i = $script:galleryIndexByPath[[string]$Item.Path]
    $updated = $null
    if ($null -ne $i -and $i -lt @($script:galleryAll).Count -and $script:galleryAll[$i].Path -eq $Item.Path) {
        $updated = New-GalleryItem -File $Item.File -Metadata (Get-GalleryMetaFor ([string]$Item.Root)) -Probe $script:probeCache[$Item.Path]
        $script:galleryAll[$i] = $updated
    }
    Apply-GalleryFilter
    if (-not $newState -and $updated -and $updated.Posted) { Show-Toast "Đã bỏ đánh dấu thủ công. $(Get-ReelLabel ([string]$Item.Id)) vẫn có lượt đăng TikTok thành công từ bộ đăng nền." -Kind success; return }
    Show-Toast $(if ($newState) { "Đã đánh dấu $(Get-ReelLabel ([string]$Item.Id)) là đã đăng TikTok." } else { "Đã bỏ đánh dấu đăng TikTok cho $(Get-ReelLabel ([string]$Item.Id))." }) -Kind success
}

function Invoke-GalleryRowAction {
    param($EventArgs)
    $btn = $EventArgs.OriginalSource
    if ($btn -isnot [Windows.Controls.Button]) { return }
    $item = $btn.DataContext
    if (-not $item -or -not $item.Path) { return }
    $EventArgs.Handled = $true
    switch ([string]$btn.Tag) {
        'view'   { [void](Invoke-GalleryView -FilePath $item.Path -Controls $ui) }
        'copy'   { Copy-ToClipboard $item.Path }
        'folder' { Open-GalleryFile $item.Path }
        'redo'   {
            if ((Test-GalleryActionsBusy) -or $script:stopping) { Show-Toast 'Hãy dừng hoặc đợi hàng đợi hoàn tất trước khi ghi âm lại.' -Kind warning; return }
            $script:lastOut = $item.Path
            Start-RecordingAgain
        }
        'delete' { [void](Invoke-GalleryDelete -FilePath $item.Path -Controls $ui) }
        'tiktok' { if (Test-TikTokEnabled) { Show-TikTokPublishDialog -FilePath $item.Path } else { Set-GalleryPosted $item } }
        'more'   { Show-GalleryCardMenu -Button $btn -Item $item }
    }
}

function Open-TikTokPostUrl {
    param([string]$Url)
    if (-not (Test-TikTokPostUrl $Url)) { Show-Toast 'Link bài đăng không hợp lệ, không mở.' -Kind warning; return $false }
    Start-Process $Url
    return $true
}

function Copy-TikTokPostUrl {
    param([string]$Url)
    if (-not (Test-TikTokPostUrl $Url)) { Show-Toast 'Link bài đăng không hợp lệ, không sao chép.' -Kind warning; return $false }
    [Windows.Clipboard]::SetText($Url)
    Show-Toast 'Đã sao chép link bài đăng.' -Kind info
    return $true
}

function Copy-TikTokPostId {
    param([string]$Id)
    if (-not (Test-TikTokPostId $Id)) { Show-Toast 'Mã bài không hợp lệ, không sao chép.' -Kind warning; return $false }
    [Windows.Clipboard]::SetText($Id)
    Show-Toast 'Đã sao chép mã bài đăng.' -Kind info
    return $true
}

function Start-TikTokLinkRefresh {
    # "Thử lấy lại link": the backend looks the link up again (read-only, never reposts).
    param([string]$Key)
    if (-not $Key -or -not (Test-TikTokEnabled)) { return }
    $task = Start-TikTokTask 'refresh-link' @{ key = $Key }
    $timer = New-Object Windows.Threading.DispatcherTimer
    $timer.Interval = [TimeSpan]::FromMilliseconds(300)
    $timer.Tag = $task
    $timer.Add_Tick({
        param($sender, $eventArgs)
        $t = $sender.Tag
        if (-not $t.Async.IsCompleted) { return }
        $sender.Stop()
        try { [void](Complete-TikTokTask $t); Show-Toast 'Đang lấy lại link bài đăng. Kho sẽ tự cập nhật.' -Kind info }
        catch { Show-Toast ('Chưa yêu cầu lấy lại link được: ' + $_.Exception.Message) -Kind warning }
    })
    $timer.Start()
}

function Show-GalleryCardMenu {
    # Menu "..." tren the Kho. TikTok items only when the integration is configured (D1).
    param($Button,$Item)
    if(-not $Item -or [string]::IsNullOrWhiteSpace([string]$Item.Path)){Show-Toast 'Không xác định được video. Chọn lại thẻ trong Kho.' -Kind warning;return}
    $menu=New-Object Windows.Controls.ContextMenu
    $specs=@()
    if(Test-TikTokEnabled){
        $specs+=,@('Đăng video lên TikTok',0xE898,'post')
        $specs+=,@('Lịch sử đăng video',0xE81C,'history')
        if($Item.Reschedule){$specs+=,@('Hẹn lại',0xE787,'reschedule')}
        $specs+=,@($(if($Item.ManualPosted){'Bỏ đánh dấu đã đăng'}else{'Đánh dấu đã đăng'}),0xE73E,'mark')
        if(Test-TikTokPostUrl ([string]$Item.PostUrl)){
            $specs+=,@('Mở bài đăng',0xE8A7,'openpost')
            $specs+=,@('Sao chép link',0xE71B,'copylink')
        }elseif(Test-TikTokPostId ([string]$Item.PostId)){
            $specs+=,@('Sao chép mã bài',0xE71B,'copyid')
        }elseif([string]$Item.LinkKey -and [string]$Item.LinkState -eq 'gave_up'){
            $specs+=,@('Thử lấy lại link',0xE72C,'refreshlink')
        }
    }
    if(-not (Test-TikTokEnabled)){$specs+=,@('Cài bộ đăng TikTok…',0xE896,'installtiktok')}
    $specs+=,@('Sao chép để đăng',0xE8C8,'copy')
    $specs+=,@('Mở thư mục',0xE838,'folder')
    $specs+=,@('Xem lớn',0xE740,'view')
    $specs+=,@('Ghi âm lại',0xE720,'redo')   # video ngoài: mục bị tắt bên dưới
    $moveItems=@(Get-GalleryMoveTargets $Item)
    $specs+=,@($(if($moveItems.Count -gt 1){"Chuyển $($moveItems.Count) video sang kho…"}else{'Chuyển sang kho…'}),0xE8B7,'moveto')
    $specs+=,@('Xóa video',0xE74D,'delete')
    foreach($spec in $specs){
        if($spec[2] -eq 'delete'){ [void]$menu.Items.Add((New-Object Windows.Controls.Separator)) }
        $entry=New-Object Windows.Controls.MenuItem
        $entry.Header=[string]$spec[0];$entry.Tag=[string][char][int]$spec[1]
        if($spec[2] -eq 'redo' -and $Item.External){$entry.IsEnabled=$false;$entry.ToolTip='Chỉ dùng cho video do app tạo';[Windows.Controls.ToolTipService]::SetShowOnDisabled($entry,$true)}
        $entry.CommandParameter=@{Path=[string]$Item.Path;Action=[string]$spec[2];Item=$Item;PostUrl=[string]$Item.PostUrl;PostId=[string]$Item.PostId;LinkKey=[string]$Item.LinkKey;Button=$Button;MoveItems=$moveItems}
        [Windows.Automation.AutomationProperties]::SetName($entry,[string]$spec[0])
        # Read all per-video context from the sender. No nested dynamic-module closures.
        $entry.Add_Click({
            param($sender,$eventArgs)
            $context=$sender.CommandParameter
            $filePath=[string]$context.Path
            switch([string]$context.Action){
                'post' {Show-TikTokPublishDialog -FilePath $filePath}
                'history' {Show-TikTokPublishDialog -FilePath $filePath}
                'reschedule' {Show-TikTokPublishDialog -FilePath $filePath -Reschedule $context.Item.Reschedule}
                'mark' {Set-GalleryPosted $context.Item}
                'openpost' {Open-TikTokPostUrl ([string]$context.PostUrl)}
                'copylink' {Copy-TikTokPostUrl ([string]$context.PostUrl)}
                'copyid' {Copy-TikTokPostId ([string]$context.PostId)}
                'refreshlink' {Start-TikTokLinkRefresh ([string]$context.LinkKey)}
                'copy' {Copy-ToClipboard $filePath}
                'installtiktok' {Show-Page 'settings' -Sub 'tools'}
                'folder' {Open-GalleryFile $filePath}
                'view' {if(Invoke-GalleryView -FilePath $filePath -Controls $ui -NoAutoPlay){Set-PreviewBig $true}}
                'redo' {
                    if((Test-GalleryActionsBusy) -or $script:stopping){Show-Toast 'Hãy dừng hoặc đợi hàng đợi hoàn tất trước khi ghi âm lại.' -Kind warning;return}
                    $script:lastOut=$filePath
                    Start-RecordingAgain
                }
                'moveto' {Show-KhoMoveMenu -Target $context.Button -Items @($context.MoveItems)}
                'delete' {[void](Invoke-GalleryDelete -FilePath $filePath -Controls $ui)}
            }
            $eventArgs.Handled=$true
        })
        [void]$menu.Items.Add($entry)
    }
    $Button.ContextMenu=$menu;$menu.PlacementTarget=$Button;$menu.Placement=[Windows.Controls.Primitives.PlacementMode]::Bottom;$menu.IsOpen=$true
}


# ------------------------------------------------------------- hop thoai "Quan ly kho" ----
function ConvertTo-KhoHashtagList {
    param([string]$Text)
    return @(($Text -split '[\s,]+') | Where-Object { $_ -and $_ -ne '#' } | ForEach-Object { if ($_.StartsWith('#')) { $_ } else { '#' + $_ } } | Select-Object -Unique)
}

function Get-KhoTotalCount {
    param([string]$Id)
    $c = $script:khoCounts[$Id]
    if (-not $c) { return 0 }
    return [int]($c[0] + $c[1] + $c[2])
}

function Test-KhoRegistryWritable { return [bool]$script:khoRegistryReady }

function Confirm-KhoDelete {
    # "Xóa kho '<tên>' và N video vào Thùng rác?" - the default button is Cancel.
    param($Owner, [string]$Name, [int]$Count = 0, [string]$NoRecycle = '')
    if ($null -ne $script:confirmDialogAutoAnswer) { return [bool]$script:confirmDialogAutoAnswer }
    Write-FileLog "DIALOG Xóa kho '$Name' ($Count video)"
    $script:khoExclusive++
    try {
        if ($NoRecycle) {
            $dlg = New-ConfirmDialog -Title 'Ổ này không có Thùng rác — xóa vĩnh viễn?' -Message "Ổ này không có Thùng rác ($NoRecycle) — xóa vĩnh viễn?`r`nXóa kho '$Name' và $Count video KHÔNG khôi phục được." -ConfirmText 'Xóa vĩnh viễn' -Danger
        } else {
        $dlg = New-ConfirmDialog -Title "Xóa kho '$Name' và $Count video vào Thùng rác?" -Message "Xóa kho '$Name' và $Count video vào Thùng rác?`r`nCác file nằm trong Thùng rác của Windows nên khôi phục được từ đó. Thư mục kho do ứng dụng tạo cũng vào Thùng rác khi không còn gì khác trong đó." -ConfirmText 'Xóa kho' -Danger
        }
        if ($Owner) { $dlg.Owner = $Owner } elseif ($win -and $win.IsVisible) { $dlg.Owner = $win }
        return ($dlg.ShowDialog() -eq $true)
    } catch {
        Write-FileLog "ERR  Confirm-KhoDelete: $($_.Exception.Message)"
        return $false
    } finally { $script:khoExclusive-- }
}

function Update-KhoCardsAfterRename {
    # Chip kho trên thẻ đổi theo tên mới: chỉ dựng lại thẻ của kho này (Ids rỗng nghĩa là TẤT CẢ nên phải chặn).
    param([string]$KhoId)
    $ids = New-Object System.Collections.Generic.List[string]
    foreach ($it in @($script:galleryAll)) { if ([string]$it.Kho -ceq $KhoId) { $ids.Add([string]$it.Id) } }
    if ($ids.Count) { Update-GalleryItemsFromMeta -Ids $ids.ToArray() -Force } else { Apply-GalleryFilter }
}

function Remove-KhoAndRefresh {
    # Remove-KhoWithVideos (videos -> Recycle Bin, kho unregistered) then a gallery rebuild. Returns the result of Remove-KhoWithVideos.
    param([string]$Id, [switch]$AllowPermanent)
    $result = Remove-KhoWithVideos -Id $Id -AllowPermanent:$AllowPermanent
    if ($result.Success -and $script:filterKho -ceq $Id) { $script:filterKho = 'all' }
    Sync-OutDirFromKho
    Update-Gallery
    return $result
}

function Start-KhoImportJob {
    # Runs Import-KhoFolder in a background runspace. The caller polls $job.Sync (Done/Total/Id/Finished/Result/Error).
    param([string]$SourceDir, [string]$OutDir)
    $blocked = Test-KhoImportBlocked
    if ($blocked) { throw $blocked }
    if (-not (Get-KhoByPath $OutDir)) { throw 'Kho này không còn trong danh sách. Chọn lại kho.' }
    # Mot lan chuyen kho dang do dang giu thu muc nay: khong chep vao luc do.
    $journalBlock = Get-KhoJournalBlock @($OutDir)
    if ($journalBlock) { throw $journalBlock }
    $iss = [Management.Automation.Runspaces.InitialSessionState]::CreateDefault()
    foreach ($name in $script:khoImportFunctions) {
        $iss.Commands.Add([Management.Automation.Runspaces.SessionStateFunctionEntry]::new($name, (Get-Item -LiteralPath "function:$name").ScriptBlock.ToString()))
    }
    $sync = [hashtable]::Synchronized(@{ Done = 0; Total = 0; Id = ''; Finished = $false; Result = $null; Error = '' })
    $cts = New-Object Threading.CancellationTokenSource
    $rs = [Management.Automation.Runspaces.RunspaceFactory]::CreateRunspace($iss)
    $ps = $null
    $script:importBusy = $true
    try {
        $rs.Open()
        $ps = [PowerShell]::Create(); $ps.Runspace = $rs
        $script = @'
param($src, $out, $sync, $token)
$ErrorActionPreference = 'Stop'
try {
    $cb = { param($p) $sync.Done = $p.Done; $sync.Total = $p.Total; $sync.Id = $p.Id }.GetNewClosure()
    $sync.Result = Import-KhoFolder -SourceDir $src -OutDir $out -Progress $cb -CancelToken $token
} catch { $sync.Error = $_.Exception.Message }
finally { $sync.Finished = $true }
'@
        [void]$ps.AddScript($script).AddArgument($SourceDir).AddArgument($OutDir).AddArgument($sync).AddArgument($cts.Token)
        $async = $ps.BeginInvoke()
    } catch {
        $script:importBusy = $false
        if ($ps) { $ps.Dispose() }; $rs.Dispose(); $cts.Dispose()
        throw
    }
    return @{ PS = $ps; Runspace = $rs; Async = $async; Sync = $sync; Cts = $cts }
}

function Complete-KhoImportJob {
    # Disposes the runspace and clears importBusy. Returns @{ Result; Error }.
    param($Job)
    $err = [string]$Job.Sync.Error
    try { [void]$Job.PS.EndInvoke($Job.Async) }
    catch { if (-not $err) { $err = $_.Exception.Message } }
    if ($Job.PS.Streams.Error.Count -and -not $err) { $err = [string]$Job.PS.Streams.Error[0] }
    try { $Job.PS.Dispose(); $Job.Runspace.Dispose(); $Job.Cts.Dispose() } catch { Write-FileLog "WARN Dọn runspace nhập kho: $($_.Exception.Message)" }
    $script:importBusy = $false
    return @{ Result = $Job.Sync.Result; Error = $err }
}

function Format-KhoImportSummary {
    param($Result)
    $r = $Result
    $text = "Đã thêm $($r.Added) video · bỏ qua $($r.Skipped) vì đã có · lỗi $($r.Failed)"
    if ($r.Cancelled) { $text += ' (đã dừng giữa chừng)' }
    foreach ($e in @($r.Errors | Select-Object -First 3)) { $text += "`n! $e" }
    foreach ($w in @($r.Warnings | Select-Object -First 2)) { $text += "`n- $w" }
    return $text
}

function Show-KhoManagerDialog {
    # Quan ly kho (kho = thu muc that): chon kho, xem/mo thu muc, doi ten, gan tai khoan TikTok, mau caption/hashtag, khung gio dang,
    # kho tai ve, them kho (thu muc), xoa kho (video vao Thung rac), them video tu thu muc khac.
    param([string]$Kho = '', [switch]$StartImport)
    $markup = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation" xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml" Title="Quản lý kho" Width="780" Height="860" MinWidth="560" MinHeight="420" WindowStartupLocation="CenterOwner" ShowInTaskbar="False" Background="{DynamicResource Surface0}" Foreground="{DynamicResource TextPrimary}" FontFamily="{DynamicResource FontUi}" FontSize="15" Language="vi-VN">
 <Grid Margin="24">
  <Grid.RowDefinitions><RowDefinition Height="Auto"/><RowDefinition Height="*"/><RowDefinition Height="Auto"/></Grid.RowDefinitions>
  <StackPanel>
   <TextBlock Text="Quản lý kho" Style="{DynamicResource TextHeading}" FontSize="25"/>
   <TextBlock Text="Mỗi kho là một thư mục thật chứa video của nó. Chuyển video sang kho khác là chuyển file; xóa video hoặc xóa kho đưa file vào Thùng rác của Windows." Style="{DynamicResource TextMutedStyle}" TextWrapping="Wrap" Margin="0,4,0,0"/>
   <Border x:Name="WarnBox" Visibility="Collapsed" Background="{DynamicResource DangerSubtle}" BorderBrush="{DynamicResource Ink}" BorderThickness="2" CornerRadius="14" Padding="12,8" Margin="0,10,0,0"><TextBlock x:Name="Warn" TextWrapping="Wrap" FontWeight="SemiBold"/></Border>
   <Border x:Name="StuckBox" Visibility="Collapsed" Background="{DynamicResource DangerSubtle}" BorderBrush="{DynamicResource Ink}" BorderThickness="2" CornerRadius="14" Padding="12,8" Margin="0,10,0,0"><StackPanel>
    <TextBlock Text="Có lần chuyển kho dở dang" FontWeight="ExtraBold"/>
    <TextBlock x:Name="StuckText" TextWrapping="Wrap" Margin="0,4,0,8"/>
    <WrapPanel><Button x:Name="BtnStuckRetry" Content="Thử hoàn tất" Margin="0,0,8,0" AutomationProperties.Name="Thử hoàn tất lần chuyển kho dở dang"/><Button x:Name="BtnStuckAbandon" Content="Bỏ qua (giữ file tại chỗ)" AutomationProperties.Name="Bỏ qua lần chuyển kho dở dang"/></WrapPanel>
   </StackPanel></Border>
  </StackPanel>
  <ScrollViewer Grid.Row="1" VerticalScrollBarVisibility="Auto"><StackPanel Margin="0,14,10,0">
   <TextBlock Text="Chọn kho" FontWeight="ExtraBold"/>
   <WrapPanel x:Name="KhoChips" Margin="0,8,0,12"/>
   <Border Background="{DynamicResource Surface1}" BorderBrush="{DynamicResource InkFaint}" BorderThickness="1" CornerRadius="16" Padding="14" Margin="0,0,0,16"><StackPanel>
    <TextBlock x:Name="DetailTitle" FontWeight="ExtraBold" FontSize="17" TextWrapping="Wrap"/>
    <DockPanel Margin="0,6,0,0">
     <Button x:Name="BtnOpenFolder" Content="Mở thư mục" DockPanel.Dock="Right" Margin="8,0,0,0" AutomationProperties.Name="Mở thư mục kho"/>
     <TextBlock x:Name="PathText" Style="{DynamicResource TextMutedStyle}" TextWrapping="Wrap" VerticalAlignment="Center"/>
    </DockPanel>
    <DockPanel Margin="0,8,0,12">
     <Button x:Name="BtnDelete" Content="Xóa kho…" DockPanel.Dock="Right" Margin="8,0,0,0" ToolTipService.ShowOnDisabled="True" AutomationProperties.Name="Xóa kho đang chọn"/>
     <Button x:Name="BtnRename" Content="Đổi tên" DockPanel.Dock="Right" Margin="8,0,0,0" ToolTipService.ShowOnDisabled="True" AutomationProperties.Name="Đổi tên kho"/>
     <TextBox x:Name="NameBox" MaxLength="60" MinHeight="44" VerticalContentAlignment="Center" ToolTipService.ShowOnDisabled="True" AutomationProperties.Name="Tên kho"/>
    </DockPanel>
    <TextBlock Text="Tài khoản TikTok của kho (để trống nếu kho không gắn tài khoản)" FontWeight="SemiBold"/>
    <DockPanel Margin="0,6,0,10">
     <Button x:Name="BtnSetAccount" Content="Lưu tài khoản" DockPanel.Dock="Right" Margin="8,0,0,0"/>
     <TextBox x:Name="AccountBox" MaxLength="60" MinHeight="44" VerticalContentAlignment="Center" AutomationProperties.Name="Tài khoản TikTok của kho"/>
    </DockPanel>
    <TextBlock Text="Mẫu caption" FontWeight="SemiBold"/>
    <TextBox x:Name="CaptionBox" AcceptsReturn="True" TextWrapping="Wrap" MaxLength="2200" Height="92" VerticalScrollBarVisibility="Auto" Margin="0,6,0,10" AutomationProperties.Name="Mẫu caption"/>
    <TextBlock Text="Hashtag mặc định (cách nhau bằng dấu cách)" FontWeight="SemiBold"/>
    <TextBox x:Name="TagsBox" MinHeight="44" VerticalContentAlignment="Center" Margin="0,6,0,10" AutomationProperties.Name="Hashtag mặc định"/>
    <TextBlock Text="Khung giờ đăng của kho (bấm giờ để xóa; dùng cho Rải lịch và hộp Đăng)" FontWeight="SemiBold"/>
    <WrapPanel x:Name="SlotChips" Margin="0,6,0,4"/>
    <DockPanel Margin="0,0,0,10"><Button x:Name="BtnSlotAdd" Content="Thêm giờ" DockPanel.Dock="Right" Margin="8,0,0,0" AutomationProperties.Name="Thêm khung giờ"/><TextBox x:Name="SlotAddBox" MinHeight="44" MaxLength="5" VerticalContentAlignment="Center" ToolTip="Nhập giờ dạng HH:mm, ví dụ 19:00, rồi bấm Thêm giờ" AutomationProperties.Name="Giờ mới (HH:mm)"/></DockPanel>
    <StackPanel Orientation="Horizontal">
     <TextBlock Text="Báo sắp hết khi còn dưới" VerticalAlignment="Center"/>
     <TextBox x:Name="LowBox" Width="68" MinHeight="44" Padding="4,8" VerticalContentAlignment="Center" MaxLength="3" TextAlignment="Center" Margin="10,0,10,0" AutomationProperties.Name="Ngưỡng sắp hết"/>
     <TextBlock Text="video chờ đăng" VerticalAlignment="Center"/>
    </StackPanel>
    <WrapPanel Margin="0,12,0,0">
     <Button x:Name="BtnSaveOpts" Content="Lưu mẫu và ngưỡng" Style="{DynamicResource BtnMint}" Margin="0,0,8,8"/>
     <Button x:Name="BtnSetTarget" Content="Dùng làm kho tải về" Margin="0,0,8,8" ToolTip="Video tải về từ trang Nguồn sẽ lưu vào kho này" AutomationProperties.Name="Đặt làm kho tải về"/>
     <Button x:Name="BtnAutoSchedule" Content="Tự hẹn lịch…" Visibility="Collapsed" Margin="0,0,8,8" ToolTip="Xếp các video Chờ đăng chưa từng đăng của kho này vào giờ yêu thích trong vài ngày tới (xem trước, bấm xác nhận mới gửi)" AutomationProperties.Name="Tự hẹn lịch cho kho tài khoản"/>
    </WrapPanel>
   </StackPanel></Border>
   <TextBlock Text="Thêm kho mới" FontWeight="ExtraBold"/>
   <TextBlock Text="Mỗi kho là một thư mục trên cùng ổ đĩa với các kho khác. Để trống ô thư mục: app tạo thư mục 'Kho &lt;tên&gt;' cạnh kho tải về." Style="{DynamicResource TextMutedStyle}" TextWrapping="Wrap" Margin="0,4,0,8"/>
   <TextBox x:Name="AddBox" MaxLength="60" MinHeight="44" VerticalContentAlignment="Center" Margin="0,0,0,8" AutomationProperties.Name="Tên kho mới"/>
   <DockPanel Margin="0,0,0,8">
    <Button x:Name="BtnBrowse" Content="Chọn thư mục…" DockPanel.Dock="Right" Margin="8,0,0,0" AutomationProperties.Name="Chọn thư mục cho kho mới"/>
    <TextBox x:Name="AddPathBox" MinHeight="44" VerticalContentAlignment="Center" AutomationProperties.Name="Thư mục kho mới"/>
   </DockPanel>
   <Button x:Name="BtnAdd" Content="Thêm kho" HorizontalAlignment="Left" Margin="0,0,0,16"/>
   <StackPanel x:Name="AcctPanel" Visibility="Collapsed" Margin="0,0,0,16">
    <TextBlock Text="Thêm kho cho tài khoản TikTok" FontWeight="ExtraBold"/>
    <DockPanel Margin="0,8,0,4">
     <Button x:Name="BtnAddAcct" Content="Thêm kho cho tài khoản" DockPanel.Dock="Right" Margin="8,0,0,0"/>
     <Button x:Name="BtnLoadAcct" Content="Tải lại" DockPanel.Dock="Right" Margin="8,0,0,0" AutomationProperties.Name="Tải lại danh sách tài khoản"/>
     <ComboBox x:Name="CmbAcct" AutomationProperties.Name="Tài khoản TikTok"/>
    </DockPanel>
    <TextBlock x:Name="AcctStatus" Style="{DynamicResource TextMutedStyle}" TextWrapping="Wrap"/>
   </StackPanel>
   <TextBlock Text="Thêm video từ thư mục" FontWeight="ExtraBold"/>
   <TextBlock Text="Chép các file &lt;ID&gt;-3-hoan-chinh.mp4 từ một thư mục vào kho đang chọn. Video đã có thì bỏ qua; thư mục nguồn không bị đổi." Style="{DynamicResource TextMutedStyle}" TextWrapping="Wrap" Margin="0,4,0,8"/>
   <WrapPanel>
    <Button x:Name="BtnImport" Content="Thêm video từ thư mục…" Margin="0,0,8,8"/>
    <Button x:Name="BtnImportStop" Content="Dừng" Visibility="Collapsed" Margin="0,0,8,8"/>
   </WrapPanel>
   <ProgressBar x:Name="ImportBar" Height="12" Minimum="0" Maximum="1" Visibility="Collapsed" Margin="0,0,0,6"/>
   <TextBlock x:Name="ImportText" TextWrapping="Wrap" FontWeight="SemiBold"/>
  </StackPanel></ScrollViewer>
  <DockPanel Grid.Row="2" Margin="0,14,0,0">
   <Button x:Name="Close" Content="Đóng" DockPanel.Dock="Right" IsCancel="True" Margin="12,0,0,0"/>
   <TextBlock x:Name="Status" TextWrapping="Wrap" VerticalAlignment="Center" FontWeight="SemiBold"/>
  </DockPanel>
 </Grid>
</Window>
'@
    $dlg = [Windows.Markup.XamlReader]::Parse($markup)
    [void]$dlg.Resources.MergedDictionaries.Add((Get-DialogTheme))
    if ($win -and $win.IsVisible) { $dlg.Owner = $win }
    $dlg.MaxHeight = [Math]::Max(460, [Windows.SystemParameters]::WorkArea.Height - 40)
    $c = @{}
    foreach ($name in @('WarnBox', 'Warn', 'StuckBox', 'StuckText', 'BtnStuckRetry', 'BtnStuckAbandon', 'KhoChips', 'DetailTitle', 'PathText', 'BtnOpenFolder', 'BtnDelete', 'BtnRename', 'NameBox', 'AccountBox', 'BtnSetAccount', 'CaptionBox', 'TagsBox', 'SlotChips', 'SlotAddBox', 'BtnSlotAdd', 'LowBox',
                        'BtnSaveOpts', 'BtnSetTarget', 'BtnAutoSchedule', 'AddBox', 'AddPathBox', 'BtnBrowse', 'BtnAdd',
                        'AcctPanel', 'BtnAddAcct', 'BtnLoadAcct', 'CmbAcct', 'AcctStatus', 'BtnImport', 'BtnImportStop', 'ImportBar', 'ImportText', 'Close', 'Status')) { $c[$name] = $dlg.FindName($name) }
    $firstKho = @(Get-KhoList)[0]
    $state = @{ Selected = $(if ($Kho -and (Get-KhoById $Kho)) { $Kho } else { [string]$firstKho.id }); Rendering = $false; Job = $null; AcctTask = $null; Fill = $null; Render = $null; Writable = (Test-KhoRegistryWritable); TikTok = (Test-TikTokEnabled) }

    # Handler defined at the dialog's top level: a closure made INSIDE another closure loses $c / $state.
    $slotRemove = {
                param($sender, $eventArgs)
                try {
                    $cur = Get-KhoById $state.Selected
                    Set-KhoOptions -Id $state.Selected -Slots (Get-KhoSlotsWithout -Slots @($cur.slots) -Slot ([string]$sender.Tag))
                    & $state.RenderSlots
                    $c.Status.Text = 'Đã xóa khung giờ ' + [string]$sender.Tag + '.'
                } catch { $c.Status.Text = (Get-FriendlyError $_.Exception.Message); Write-FileLog "WARN Quản lý kho (xóa giờ): $($_.Exception.Message)" }
    }.GetNewClosure()
    # D10: khung giờ đăng của kho = các chip (bấm để xóa) + ô thêm HH:mm; lưu ngay vào kho.slots.
    $state.RenderSlots = {
        $lib = Get-KhoById $state.Selected
        $c.SlotChips.Children.Clear()
        if (-not $lib) { return }
        if (-not @($lib.slots).Count) { $none = New-Object Windows.Controls.TextBlock; $none.Text = 'Chưa đặt khung giờ: Rải lịch dùng giờ bạn hay đăng hoặc 08:00, 12:00, 19:00, 21:00.'; $none.TextWrapping = 'Wrap'; $none.Foreground = $dlg.FindResource('TextMuted'); [void]$c.SlotChips.Children.Add($none) }
        foreach ($s in @($lib.slots)) {
            $b = New-Object Windows.Controls.Button; $b.Content = ([string]$s + '  ×'); $b.Tag = [string]$s; $b.Margin = [Windows.Thickness]::new(0, 0, 6, 6); $b.MinHeight = 36; $b.IsEnabled = $state.Writable
            $b.ToolTip = 'Bấm để xóa khung giờ này'
            [Windows.Automation.AutomationProperties]::SetName($b, 'Xóa khung giờ ' + [string]$s)
            $b.Add_Click($slotRemove)
            [void]$c.SlotChips.Children.Add($b)
        }
    }.GetNewClosure()

    # Fill the detail panel for the selected kho and enable/disable the controls.
    $state.Fill = {
        $lib = Get-KhoById $state.Selected
        if (-not $lib) { $lib = @(Get-KhoList)[0]; $state.Selected = [string]$lib.id }
        $importing = [bool]$state.Job
        $isTarget = ([string]$lib.id -ceq (Get-KhoDownloadTarget))
        $only = (@(Get-KhoList).Count -le 1)
        $c.DetailTitle.Text = [string]$lib.name + ' · ' + (Get-KhoTotalCount ([string]$lib.id)) + ' video' + $(if ($lib.account) { ' · tài khoản @' + $lib.account } else { '' }) + $(if ($isTarget) { ' · kho tải về' } else { '' })
        $c.PathText.Text = [string]$lib.path
        $c.NameBox.Text = [string]$lib.name
        $c.AccountBox.Text = $(if ($lib.account) { '@' + $lib.account } else { '' })
        $c.CaptionBox.Text = [string]$lib.caption
        $c.TagsBox.Text = (@($lib.hashtags) -join ' ')
        & $state.RenderSlots
        & $state.RenderStuck
        $c.LowBox.Text = [string]$lib.lowStock
        $w = $state.Writable
        $c.BtnRename.IsEnabled = $w
        $c.BtnDelete.IsEnabled = ($w -and -not $only -and -not $importing)
        $c.BtnDelete.ToolTip = $(if ($only) { 'Luôn phải có ít nhất một kho; không xóa được kho cuối cùng.' } else { 'Xóa kho và mọi video trong kho vào Thùng rác (khôi phục được từ Thùng rác)' })
        foreach ($ctl in @($c.NameBox, $c.AccountBox, $c.BtnSetAccount, $c.CaptionBox, $c.TagsBox, $c.SlotAddBox, $c.BtnSlotAdd, $c.LowBox, $c.BtnSaveOpts, $c.AddBox, $c.AddPathBox, $c.BtnBrowse, $c.BtnAdd)) { $ctl.IsEnabled = $w }
        $c.BtnSetTarget.IsEnabled = ($w -and -not $isTarget)
        $c.BtnAddAcct.IsEnabled = ($w -and $c.CmbAcct.Items.Count -gt 0)
        $c.BtnImport.IsEnabled = (-not $importing)
        $c.BtnAutoSchedule.Visibility = $(if ($state.TikTok -and $lib.account) { 'Visible' } else { 'Collapsed' })
        $c.BtnAutoSchedule.IsEnabled = (-not $importing)
    }.GetNewClosure()

    $chipChecked = {
        param($sender, $eventArgs)
        if ($state.Rendering) { return }
        $state.Selected = [string]$sender.Tag
        & $state.Fill
    }.GetNewClosure()

    $state.Render = {
        $state.Rendering = $true
        try {
            $c.KhoChips.Children.Clear()
            $group = 'KhoMgr' + [Guid]::NewGuid().ToString('N')
            foreach ($lib in @(Get-KhoList)) {
                $rb = New-Object Windows.Controls.RadioButton
                $rb.Style = $dlg.FindResource('SegButton'); $rb.GroupName = $group
                $rb.Content = [string]$lib.name + ' (' + (Get-KhoTotalCount ([string]$lib.id)) + ')'
                $rb.Tag = [string]$lib.id; $rb.Margin = [Windows.Thickness]::new(0, 0, 8, 8)
                [Windows.Automation.AutomationProperties]::SetName($rb, [string]$lib.name)
                $rb.IsChecked = ([string]$lib.id -ceq $state.Selected)
                $rb.Add_Checked($chipChecked)
                [void]$c.KhoChips.Children.Add($rb)
            }
        } finally { $state.Rendering = $false }
        & $state.Fill
    }.GetNewClosure()

    # Lần chuyển kho dở dang (nhật ký còn lại): thử hoàn tất lại hoặc bỏ qua (nhật ký sang data\kho-moves\abandoned, file giữ nguyên).
    $state.RenderStuck = {
        $stuck = @(Get-KhoStuckMoves)
        $c.StuckBox.Visibility = $(if ($stuck.Count) { 'Visible' } else { 'Collapsed' })
        $c.StuckText.Text = (@($stuck | ForEach-Object { $_.Text }) -join "`r`n")
    }.GetNewClosure()
    $c.BtnStuckRetry.Add_Click({
        try {
            if (Test-KhoQuiet) { $c.Status.Text = "Đang bận ($(Test-KhoQuiet)); thử lại sau."; return }
            if (-not (Suspend-TikTokSync)) { $c.Status.Text = 'Đang đồng bộ TikTok; thử lại sau ít giây.'; return }
            try { $r = Resume-KhoMoves } finally { Resume-TikTokSync }
            & $state.RenderStuck
            $c.Status.Text = $(if ($r.Pending.Count) { 'Chưa hoàn tất được: ' + ($r.Pending -join '; ') } else { "Đã hoàn tất $($r.Done) lần chuyển kho dở dang." })
            Update-Gallery
        } catch { $c.Status.Text = (Get-FriendlyError $_.Exception.Message); Write-FileLog "WARN Quản lý kho (thử hoàn tất chuyển kho): $($_.Exception.Message)" }
    }.GetNewClosure())
    $c.BtnStuckAbandon.Add_Click({
        try {
            $stuck = @(Get-KhoStuckMoves)
            if (-not $stuck.Count) { & $state.RenderStuck; return }
            $ok = Show-ConfirmDialog -Title 'Bỏ qua chuyển kho dở dang?' -ConfirmText 'Bỏ qua' -Danger -Message ("Các file KHÔNG bị đổi hay xóa — chúng nằm nguyên ở chỗ hiện tại (có thể một phần ở kho cũ, một phần ở kho mới). Chỉ nhật ký chuyển kho được cất sang data\kho-moves\abandoned, kho liên quan được mở khóa.`r`n`r`n" + (@($stuck | ForEach-Object { $_.Text }) -join "`r`n"))
            if (-not $ok) { return }
            foreach ($s in $stuck) { [void](Move-KhoJournalAside $s.Path) }
            & $state.RenderStuck
            $c.Status.Text = 'Đã bỏ qua; file giữ nguyên tại chỗ.'
            Update-Gallery
        } catch { $c.Status.Text = (Get-FriendlyError $_.Exception.Message); Write-FileLog "WARN Quản lý kho (bỏ qua chuyển kho): $($_.Exception.Message)" }
    }.GetNewClosure())

    $afterChange = { Apply-GalleryFilter; & $state.Render }.GetNewClosure()
    $fail = { param($ex) $c.Status.Text = (Get-FriendlyError $ex.Exception.Message); Write-FileLog "WARN Quản lý kho: $($ex.Exception.Message)" }.GetNewClosure()

    $c.BtnAdd.Add_Click({
        try {
            $lib = New-Kho -Name $c.AddBox.Text -Path ([string]$c.AddPathBox.Text).Trim()
            $c.AddBox.Text = ''; $c.AddPathBox.Text = ''; $state.Selected = [string]$lib.id
            Update-Gallery
            & $afterChange
            $c.Status.Text = "Đã thêm kho '$($lib.name)' tại $($lib.path)."
        } catch { & $fail $_ }
    }.GetNewClosure())
    $c.BtnBrowse.Add_Click({
        try {
            $picker = New-Object System.Windows.Forms.FolderBrowserDialog
            $picker.Description = 'Chọn (hoặc tạo) thư mục cho kho mới'
            if ($picker.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) { $c.AddPathBox.Text = $picker.SelectedPath }
        } catch { & $fail $_ }
    }.GetNewClosure())
    $c.BtnOpenFolder.Add_Click({
        $lib = Get-KhoById $state.Selected
        if ($lib) { Open-FolderSafe ([string]$lib.path) }
    }.GetNewClosure())
    $c.BtnRename.Add_Click({
        try {
            Rename-Kho -Id $state.Selected -Name $c.NameBox.Text
            Update-KhoCardsAfterRename -KhoId ([string]$state.Selected)
            & $afterChange
            $c.Status.Text = 'Đã đổi tên kho (tên thư mục không đổi).'
        } catch { & $fail $_ }
    }.GetNewClosure())
    $c.BtnSetAccount.Add_Click({
        try {
            Set-KhoAccount -Id $state.Selected -Account ([string]$c.AccountBox.Text)
            & $afterChange
            $c.Status.Text = $(if (([string]$c.AccountBox.Text).Trim()) { 'Đã gán tài khoản cho kho.' } else { 'Đã bỏ tài khoản khỏi kho.' })
        } catch { & $fail $_ }
    }.GetNewClosure())
    $c.BtnSetTarget.Add_Click({
        try {
            Set-KhoDownloadTarget $state.Selected
            Sync-OutDirFromKho
            & $afterChange
            $c.Status.Text = 'Video tải về từ trang Nguồn sẽ lưu vào kho này.'
        } catch { & $fail $_ }
    }.GetNewClosure())
    # Enter: tên = đổi tên, tài khoản = lưu tài khoản, ô thêm = thêm kho, hashtag/giờ/ngưỡng = lưu. Esc: đóng hộp thoại.
    $enterClicks = @{ NameBox = 'BtnRename'; AccountBox = 'BtnSetAccount'; AddBox = 'BtnAdd'; AddPathBox = 'BtnAdd'; TagsBox = 'BtnSaveOpts'; SlotAddBox = 'BtnSlotAdd'; LowBox = 'BtnSaveOpts' }
    foreach ($boxName in $enterClicks.Keys) {
        $target = $c[$enterClicks[$boxName]]
        $c[$boxName].Add_KeyDown({
            param($sender, $eventArgs)
            if ($eventArgs.Key -eq [System.Windows.Input.Key]::Return -and $target.IsEnabled) {
                $eventArgs.Handled = $true
                $target.RaiseEvent((New-Object Windows.RoutedEventArgs ([Windows.Controls.Primitives.ButtonBase]::ClickEvent)))
            }
        }.GetNewClosure())
    }
    $dlg.Add_PreviewKeyDown({
        param($sender, $eventArgs)
        if ($eventArgs.Key -eq [System.Windows.Input.Key]::Escape -and -not $c.CmbAcct.IsDropDownOpen) { $eventArgs.Handled = $true; $sender.Close() }
    }.GetNewClosure())
    $c.BtnDelete.Add_Click({
        try {
            $lib = Get-KhoById $state.Selected
            if (-not $lib) { return }
            $name = [string]$lib.name; $count = Get-KhoTotalCount ([string]$lib.id)
            $noBin = Get-KhoNoRecycleReason ([string]$lib.path)
            if (-not (Confirm-KhoDelete -Owner $dlg -Name $name -Count $count -NoRecycle $noBin)) { return }
            $again = Get-KhoById ([string]$lib.id)
            if (-not $again -or [string]$again.path -cne [string]$lib.path) { $c.Status.Text = "Kho '$name' đã thay đổi trong lúc xác nhận; chưa xóa gì."; return }
            $r = Remove-KhoAndRefresh -Id ([string]$lib.id) -AllowPermanent:([bool]$noBin)
            if ($r.Success) {
                $state.Selected = [string]@(Get-KhoList)[0].id
                & $afterChange
                $c.Status.Text = "Đã xóa kho '$name' và $($r.Deleted) video vào Thùng rác." + $(if ($r.FolderRecycled) { ' Thư mục kho cũng vào Thùng rác.' } else { ' Thư mục kho được giữ lại trên ổ đĩa.' })
            } else {
                & $afterChange
                $why = [string]$r.Why
                if (@($r.Failed).Count) { $why += ' ' + (@($r.Failed | Select-Object -First 2 | ForEach-Object { "$(Get-ReelLabel ([string]$_.Id)): $($_.Errors -join '; ')" }) -join ' | ') }
                $c.Status.Text = $why
                Write-FileLog "WARN Xóa kho '$name' chưa hoàn tất: $why"
            }
        } catch { & $fail $_ }
    }.GetNewClosure())
    $c.BtnSlotAdd.Add_Click({
        try {
            $cur = Get-KhoById $state.Selected
            $new = Get-KhoSlotsWith -Slots @($cur.slots) -Text ([string]$c.SlotAddBox.Text)
            Set-KhoOptions -Id $state.Selected -Slots $new
            $c.SlotAddBox.Text = ''
            & $state.RenderSlots
            $c.Status.Text = 'Đã thêm khung giờ.'
        } catch { & $fail $_ }
    }.GetNewClosure())
    $c.BtnSaveOpts.Add_Click({
        try {
            $low = 0
            if (-not [int]::TryParse(([string]$c.LowBox.Text).Trim(), [ref]$low) -or $low -lt 0 -or $low -gt 999) { throw 'Ngưỡng sắp hết phải là số từ 0 đến 999.' }
            Set-KhoOptions -Id $state.Selected -Caption ([string]$c.CaptionBox.Text) -Hashtags @(ConvertTo-KhoHashtagList $c.TagsBox.Text) -LowStock $low
            & $state.Fill
            $c.Status.Text = 'Đã lưu mẫu caption, hashtag và ngưỡng.'
        } catch { & $fail $_ }
    }.GetNewClosure())

    $c.BtnAutoSchedule.Add_Click({
        try {
            $lib = Get-KhoById $state.Selected
            if (-not $lib -or -not [string]$lib.account) { return }
            $metaRead = Get-GalleryMetaChecked
            if ($metaRead.Gap) { $c.Status.Text = $metaRead.Gap; return }
            $cand = @(Get-TikTokAutoScheduleItems -Items @($script:galleryAll) -KhoId ([string]$lib.id) -MetaByRoot $metaRead.Map)
            if (-not $cand.Count) { $c.Status.Text = 'Kho này không có video Chờ đăng nào chưa từng đăng.'; return }
            Show-TikTokSpreadDialog -Items $cand -Account ([string]$lib.account) -Owner $dlg
            & $state.Render
        } catch { & $fail $_ }
    }.GetNewClosure())

    # TikTok accounts (only when the TikTok backend is configured).
    $loadAccounts = {
        if (-not $state.TikTok -or $state.AcctTask) { return }
        $c.AcctStatus.Text = 'Đang tải danh sách tài khoản…'; $c.BtnLoadAcct.IsEnabled = $false
        try { $state.AcctTask = Start-TikTokTask 'accounts' }
        catch { $c.AcctStatus.Text = 'Không tải được tài khoản: ' + (Get-FriendlyError $_.Exception.Message); $c.BtnLoadAcct.IsEnabled = $true }
    }.GetNewClosure()
    if ($state.TikTok) {
        $c.AcctPanel.Visibility = 'Visible'
        $c.BtnLoadAcct.Add_Click($loadAccounts)
        $c.BtnAddAcct.Add_Click({
            try {
                $sel = $c.CmbAcct.SelectedItem
                if (-not $sel) { throw 'Chọn một tài khoản trước.' }
                $lib = New-KhoForAccount ([string]$sel.Tag)
                $state.Selected = [string]$lib.id
                $c.CmbAcct.Items.Remove($sel)
                if ($c.CmbAcct.Items.Count) { $c.CmbAcct.SelectedIndex = 0 }
                Update-Gallery
                & $afterChange
                $c.Status.Text = "Đã thêm kho '$($lib.name)' tại $($lib.path)."
            } catch { & $fail $_ }
        }.GetNewClosure())
    }

    # Folder import (background runspace; progress polled by the timer below). The kho being imported into is reserved (importBusy).
    $c.BtnImport.Add_Click({
        $blocked = Test-KhoImportBlocked
        if ($blocked) { $c.Status.Text = $blocked; return }
        try {
            $lib = Get-KhoById $state.Selected
            if (-not $lib) { throw 'Chọn một kho trước.' }
            $picker = New-Object System.Windows.Forms.FolderBrowserDialog
            $picker.Description = 'Chọn thư mục chứa video đã làm xong (<ID>-3-hoan-chinh.mp4)'
            if ($picker.ShowDialog() -ne [System.Windows.Forms.DialogResult]::OK) { return }
            $state.Job = Start-KhoImportJob -SourceDir $picker.SelectedPath -OutDir ([string]$lib.path)
            $c.ImportBar.Visibility = 'Visible'; $c.ImportBar.Value = 0
            $c.BtnImportStop.Visibility = 'Visible'
            $c.ImportText.Text = 'Đang chuẩn bị…'; $c.Status.Text = ''
            & $state.Fill
        } catch { & $fail $_ }
    }.GetNewClosure())
    $c.BtnImportStop.Add_Click({ if ($state.Job) { try { $state.Job.Cts.Cancel() } catch { Write-FileLog "WARN Dừng nhập kho: $($_.Exception.Message)" }; $c.ImportText.Text = 'Đang dừng…' } }.GetNewClosure())

    $timer = New-Object Windows.Threading.DispatcherTimer
    $timer.Interval = [TimeSpan]::FromMilliseconds(300)
    $timer.Add_Tick({
        if ($state.AcctTask -and $state.AcctTask.Async.IsCompleted) {
            $task = $state.AcctTask; $state.AcctTask = $null
            try {
                $accounts = @(Complete-TikTokTask $task | Where-Object { $_ -and [string]$_.username })
                $have = @{}; foreach ($lib in @(Get-KhoList)) { if ([string]$lib.account) { $have[([string]$lib.account).ToLowerInvariant()] = $true } }
                $c.CmbAcct.Items.Clear()
                foreach ($a in $accounts) {
                    if ($have.ContainsKey((ConvertTo-KhoUsername ([string]$a.username)).ToLowerInvariant())) { continue }
                    $ci = New-Object Windows.Controls.ComboBoxItem
                    $ci.Content = '@' + $a.username + $($note = Get-TikTokAccountNote $a; if ($note) { ' (' + $note + ')' } else { '' })
                    $ci.Tag = [string]$a.username
                    [void]$c.CmbAcct.Items.Add($ci)
                }
                if ($c.CmbAcct.Items.Count) { $c.CmbAcct.SelectedIndex = 0; $c.AcctStatus.Text = 'Chọn tài khoản rồi bấm Thêm kho cho tài khoản.' }
                else { $c.AcctStatus.Text = $(if ($accounts.Count) { 'Mọi tài khoản đều đã có kho.' } else { 'Chưa có tài khoản TikTok nào. Mở Tài khoản / Lịch đăng để thêm.' }) }
            } catch { $c.AcctStatus.Text = 'Không tải được tài khoản: ' + (Get-FriendlyError $_.Exception.Message) }
            $c.BtnLoadAcct.IsEnabled = $true
            & $state.Fill
        }
        if ($state.Job) {
            $job = $state.Job
            $total = [int]$job.Sync.Total; $done = [int]$job.Sync.Done
            if (-not $job.Sync.Finished) {
                if ($total -gt 0) { $c.ImportBar.Value = $done / $total; $c.ImportText.Text = "Đang chép $done/$total · Reel #$($job.Sync.Id)" }
            } else {
                $state.Job = $null
                $outcome = Complete-KhoImportJob $job
                $c.ImportBar.Visibility = 'Collapsed'; $c.BtnImportStop.Visibility = 'Collapsed'
                if ($outcome.Error) { $c.ImportText.Text = 'Không thêm được: ' + (Get-FriendlyError $outcome.Error); Write-FileLog "WARN Nhập kho: $($outcome.Error)" }
                elseif ($outcome.Result) {
                    $c.ImportText.Text = Format-KhoImportSummary $outcome.Result
                    Write-FileLog ('INFO Nhập kho: ' + ($c.ImportText.Text -replace "`n", ' | '))
                    Update-Gallery
                }
                & $state.Render
            }
        }
    }.GetNewClosure())
    $dlg.Add_Closing({
        param($sender, $eventArgs)
        if ($state.Job) { $eventArgs.Cancel = $true; $c.Status.Text = 'Đang thêm video từ thư mục. Bấm Dừng hoặc đợi xong rồi hãy đóng.' }
    }.GetNewClosure())
    $dlg.Add_Closed({ $timer.Stop(); if ($state.AcctTask) { Stop-TikTokTask $state.AcctTask; $state.AcctTask = $null } }.GetNewClosure())

    if (-not $state.Writable) {
        $c.WarnBox.Visibility = 'Visible'
        $c.Warn.Text = 'Không đọc được data\kho.json nên phiên này không lưu thay đổi kho. Đóng ứng dụng, kiểm tra file rồi mở lại. Các nút sửa kho đang tắt.'
    }
    & $state.Render
    $timer.Start()
    if ($StartImport) { $dlg.Add_ContentRendered({ if (-not $state.Started) { $state.Started = $true; $c.BtnImport.RaiseEvent((New-Object Windows.RoutedEventArgs ([Windows.Controls.Primitives.ButtonBase]::ClickEvent))) } }.GetNewClosure()) }
    if ($state.TikTok) { & $loadAccounts }
    [void]$dlg.ShowDialog()
}

function Invoke-QueueRowAction {
    param($EventArgs)
    $btn = $EventArgs.OriginalSource
    if ($btn -isnot [Windows.Controls.Button]) { return }
    $row = $btn.DataContext
    if (-not $row) { return }
    $EventArgs.Handled = $true
    if ([string]$btn.Tag -eq 'detail') {
        [void](Show-ConfirmDialog -Title 'Chi tiết' -Kind info -OkOnly -ConfirmText 'Đóng' -Message ([string]$row.Detail))
        return
    }
    switch ([string]$row.ActionKind) {
        'open' {
            if (-not $row.Video -or -not (Test-Path -LiteralPath $row.Video)) { Show-Toast 'Không còn file video này trong thư mục xuất.' -Kind warning; return }
            if (Test-GalleryActionsBusy) { Open-GalleryFile $row.Video; return }
            if (Invoke-GalleryView -FilePath $row.Video -Controls $ui -NoAutoPlay) { Show-Page 'library' }
        }
        'retry' {
            if (Test-QueueRunning) { Show-Toast 'Hàng đợi đang chạy; thử lại sau khi xong hoặc bấm Dừng.' -Kind warning; return }
            # G-R4: dong tu "Ghi am lai" -> chay lai dung luong ghi am lai (thu muc cua video, bo qua lich su loai).
            if ([string]$row.Origin -eq 'redo' -and $row.RedoFile -and (Test-Path -LiteralPath ([string]$row.RedoFile) -PathType Leaf)) {
                $script:lastOut = [string]$row.RedoFile
                Start-RecordingAgain
                return
            }
            # Thu lai la yeu cau ro rang: khong bo qua video da co trong kho.
            Start-QueueFromLinks -Links @([string]$row.Url) -SkipExisting $false
        }
        'unreject' { Invoke-UnrejectReel -VideoId ([string]$row.Id) }
    }
}

# ------------------------------------------------------------- quan ly cong cu & thu vien ----
function Update-ToolsStatus {
    $inToolsScrcpy = (Test-Path -LiteralPath (Join-Path $script:root 'tools\scrcpy\scrcpy.exe')) -or
                     (Test-Path -LiteralPath (Join-Path $script:root 'tools\scrcpy\scrcpy-win64-v5.0\scrcpy.exe')) -or
                     (Test-Path -LiteralPath (Join-Path $script:root 'tools\scrcpy\scrcpy-win64-v4.1\scrcpy.exe')) -or
                     (Test-Path -LiteralPath (Join-Path $script:root 'tools\scrcpy\scrcpy-win64-v3.1\scrcpy.exe')) -or
                     (Test-Path -LiteralPath (Join-Path $script:root 'tools\scrcpy\scrcpy-win64-v2.7\scrcpy.exe')) -or
                     (Test-Path -LiteralPath (Join-Path $script:root 'tools\scrcpy.exe'))
    $hasScrcpy = $inToolsScrcpy -or (Get-Command 'scrcpy' -ErrorAction SilentlyContinue)

    $inToolsAdb    = (Test-Path -LiteralPath (Join-Path $script:root 'tools\scrcpy\adb.exe')) -or
                     (Test-Path -LiteralPath (Join-Path $script:root 'tools\scrcpy\scrcpy-win64-v5.0\adb.exe')) -or
                     (Test-Path -LiteralPath (Join-Path $script:root 'tools\scrcpy\scrcpy-win64-v4.1\adb.exe')) -or
                     (Test-Path -LiteralPath (Join-Path $script:root 'tools\scrcpy\scrcpy-win64-v3.1\adb.exe')) -or
                     (Test-Path -LiteralPath (Join-Path $script:root 'tools\scrcpy\scrcpy-win64-v2.7\adb.exe')) -or
                     (Test-Path -LiteralPath (Join-Path $script:root 'tools\adb.exe'))
    $hasAdb = $inToolsAdb -or (Get-Command 'adb' -ErrorAction SilentlyContinue) -or
              (Test-Path -LiteralPath 'D:\LDPlayer\LDPlayer14\adb.exe' -ErrorAction SilentlyContinue) -or
              (Test-Path -LiteralPath 'D:\LDPlayer\LDPlayer9\adb.exe' -ErrorAction SilentlyContinue) -or
              (Test-Path -LiteralPath 'C:\LDPlayer\LDPlayer14\adb.exe' -ErrorAction SilentlyContinue)

    $inToolsYtdlp  = (Test-Path -LiteralPath (Join-Path $script:root 'tools\yt-dlp.exe')) -or
                     (Test-Path -LiteralPath (Join-Path $script:root 'tools\yt-dlp\yt-dlp.exe'))
    $hasYtdlp = $inToolsYtdlp -or (Get-Command 'yt-dlp' -ErrorAction SilentlyContinue)

    $inToolsFfmpeg = (Test-Path -LiteralPath (Join-Path $script:root 'tools\ffmpeg\ffmpeg.exe')) -or
                     (Test-Path -LiteralPath (Join-Path $script:root 'tools\ffmpeg\bin\ffmpeg.exe')) -or
                     (Test-Path -LiteralPath (Join-Path $script:root 'tools\ffmpeg.exe'))
    $hasFfmpeg = $inToolsFfmpeg -or (Get-Command 'ffmpeg' -ErrorAction SilentlyContinue)
    $inToolsFfprobe = (Test-Path -LiteralPath (Join-Path $script:root 'tools\ffmpeg\ffprobe.exe')) -or
                      (Test-Path -LiteralPath (Join-Path $script:root 'tools\ffmpeg\bin\ffprobe.exe')) -or
                      (Test-Path -LiteralPath (Join-Path $script:root 'tools\ffprobe.exe'))
    $hasFfprobe = $inToolsFfprobe -or (Get-Command 'ffprobe' -ErrorAction SilentlyContinue)

    function Set-ToolCard($txtElem, $badgeElem, $btnElem, [bool]$installed, [bool]$inTools = $false) {
        # Badge pill: nen Soft + vien dam + chu nau (Mint = portable, Sky = co tren may, san ho = chua co).
        if (-not $txtElem -or -not $badgeElem) { return }
        $txtElem.Foreground = Get-Brush 'TextPrimary'
        if ($inTools) {
            $txtElem.Text = 'Có sẵn trong app'
            $badgeElem.Background = Get-Brush 'MintSoft'; $badgeElem.BorderBrush = Get-Brush 'MintLine'
            if ($btnElem) { $btnElem.Content = 'Tải lại' }
        } elseif ($installed) {
            $txtElem.Text = 'Có trên máy'
            $badgeElem.Background = Get-Brush 'SkySoft'; $badgeElem.BorderBrush = Get-Brush 'SkyLine'
            if ($btnElem) { $btnElem.Content = 'Gom vào tools' }
        } else {
            $txtElem.Text = 'Chưa có'
            $badgeElem.Background = Get-Brush 'CoralSoft'; $badgeElem.BorderBrush = Get-Brush 'CoralLine'
            if ($btnElem) { $btnElem.Content = 'Cài đặt' }
        }
    }

    Set-ToolCard $ui.TxtStatusScrcpy $ui.BadgeStatusScrcpy $ui.BtnInstallScrcpy $hasScrcpy $inToolsScrcpy
    Set-ToolCard $ui.TxtStatusAdb    $ui.BadgeStatusAdb    $ui.BtnInstallAdb    $hasAdb    $inToolsAdb
    Set-ToolCard $ui.TxtStatusYtdlp  $ui.BadgeStatusYtdlp  $ui.BtnInstallYtdlp  $hasYtdlp  $inToolsYtdlp
    Set-ToolCard $ui.TxtStatusFfmpeg $ui.BadgeStatusFfmpeg $ui.BtnInstallFfmpeg $hasFfmpeg $inToolsFfmpeg
    $hasWhisper = $false
    if ($script:whisperLanguageHelperAvailable) {
        try {
            $whisperPaths = Get-WhisperPaths $script:root
            $hasWhisper = [bool]$whisperPaths.Ready
        } catch {
            $hasWhisper = $false
            Write-FileLog "WARN Get-WhisperPaths: $($_.Exception.Message)"
        }
    }
    Set-ToolCard $ui.TxtStatusWhisper $ui.BadgeStatusWhisper $ui.BtnInstallWhisper $hasWhisper $hasWhisper
    if ($hasWhisper -and $ui.BtnInstallWhisper) { $ui.BtnInstallWhisper.Content = 'Kiểm tra' }
    if (-not $hasWhisper -and $ui.TxtStatusWhisper) {
        # Whisper chi de chan doan: chua cai khong phai loi (badge trung tinh, khong do).
        $ui.TxtStatusWhisper.Text = 'Không bắt buộc'
        $ui.BadgeStatusWhisper.Background = Get-Brush 'NeutralSubtle'; $ui.BadgeStatusWhisper.BorderBrush = Get-Brush 'Neutral'
        if ($ui.BtnInstallWhisper) { $ui.BtnInstallWhisper.Content = 'Cài (tùy chọn)' }
    }
    if ($hasFfmpeg -and -not $hasFfprobe) {
        $ui.TxtStatusFfmpeg.Text = 'Thiếu ffprobe'
        $ui.TxtStatusFfmpeg.Foreground = Get-Brush 'TextPrimary'
        $ui.BadgeStatusFfmpeg.Background = Get-Brush 'CoralSoft'; $ui.BadgeStatusFfmpeg.BorderBrush = Get-Brush 'CoralLine'
    }
    # G-R3: worker quet Kho dang dung ffmpeg/ffprobe cu (vua cai/doi cong cu) -> tao lai.
    if (Test-MediaToolsChanged) { Reset-MediaWorkerForTools 'đường dẫn ffmpeg/ffprobe thay đổi' }
    # Chip "Cong cu": chi dua tren file/lenh co san (nhe, khong goi adb). Chip thiet bi do ket qua -Check quyet dinh.
    $script:toolPresence = @{ scrcpy = [bool]$hasScrcpy; adb = [bool]$hasAdb; ffmpeg = [bool]$hasFfmpeg; ffprobe = [bool]$hasFfprobe; ytdlp = [bool]$hasYtdlp }
    $missing = @(); foreach ($k in @('adb', 'scrcpy', 'ffmpeg', 'ffprobe', 'ytdlp')) { if (-not $script:toolPresence[$k]) { $missing += $(if ($k -eq 'ytdlp') { 'yt-dlp' } else { $k }) } }
    Set-HeaderChip -Chip 'Tools' -State $(if ($missing.Count) { 'bad' } else { 'ok' }) -Text $(if ($missing.Count) { 'Thiếu công cụ' } else { 'Công cụ' }) `
        -Tip $(if ($missing.Count) { 'Thiếu: ' + ($missing -join ', ') + '. Bấm để mở Cài đặt › Công cụ.' } else { 'Đã có ADB, scrcpy, FFmpeg, ffprobe, yt-dlp.' })
    try { Update-AutotokSection } catch { Write-FileLog "WARN Update-AutotokSection: $($_.Exception.Message)" }
}

function Set-HeaderChip {
    # State: ok (Success) | bad (Danger) | unknown (TextMuted, chua kiem). 'Scrcpy' gop vao chip Cong cu.
    param([ValidateSet('Device','Scrcpy','Tools')][string]$Chip, [ValidateSet('ok','bad','unknown')][string]$State, [string]$Text, [string]$Tip)
    $script:headerChipState = if ($script:headerChipState) { $script:headerChipState } else { @{} }
    $script:headerChipState[$Chip] = $State
    if ($Chip -eq 'Scrcpy') { return }
    $dot = $ui["Chip${Chip}Dot"]; $txt = $ui["Chip${Chip}Text"]; $border = $ui["Chip$Chip"]
    # Cham tron 10 px (Ellipse): xanh = san sang, san ho = co van de, be = chua kiem tra. Tooltip ghi ro trang thai.
    $color = switch ($State) { 'ok' { 'MintLine' } 'bad' { 'Coral' } default { 'Neutral' } }
    $label = switch ($State) { 'ok' { 'Sẵn sàng' } 'bad' { 'Có vấn đề' } default { 'Chưa kiểm tra' } }
    if ($dot -is [Windows.Shapes.Shape]) { $dot.Fill = Get-Brush $color } elseif ($dot) { $dot.Foreground = Get-Brush $color }
    if ($txt -and $Text) { $txt.Text = $Text }
    if ($border) {
        $border.ToolTip = $(if ($Tip) { "Trạng thái: $label — $Tip" } else { "Trạng thái: $label" })
        [Windows.Automation.AutomationProperties]::SetHelpText($border, [string]$border.ToolTip)
    }
}

function Get-CheckChipState {
    # Doc output cua 'kid-fby.ps1 -Check' (dong v/x cua Test-Ready). Tra ve trang thai thiet bi / scrcpy / cong cu.
    param([string]$Text)
    $r = @{
        Device = @{ State = 'unknown'; Text = 'Thiết bị'; Tip = 'Chưa kiểm tra thiết bị Android. Bấm để kiểm tra.' }
        Scrcpy = $null
        Tools  = $null
    }
    if ([string]::IsNullOrEmpty($Text)) { return $r }
    $toolState = @{}
    foreach ($k in @('adb','scrcpy','ytdlp','ffmpeg','ffprobe')) {
        if ($Text -match "(?m)^\s*v\s+$k\s*$") { $toolState[$k] = 'ok' }
        elseif ($Text -match "(?m)^\s*x\s+$k\b") { $toolState[$k] = 'bad' }
    }
    if ($toolState.ContainsKey('scrcpy')) {
        $r.Scrcpy = @{ State = $toolState['scrcpy']; Text = 'scrcpy'; Tip = $(if ($toolState['scrcpy'] -eq 'ok') { 'Kiểm tra máy: scrcpy sẵn sàng.' } else { 'Kiểm tra máy: thiếu scrcpy.' }) }
    }
    $checked = @('adb','scrcpy','ffmpeg','ffprobe','ytdlp' | Where-Object { $toolState.ContainsKey($_) })
    if ($checked.Count) {
        $bad = @($checked | Where-Object { $toolState[$_] -eq 'bad' })
        $r.Tools = @{ State = $(if ($bad.Count) { 'bad' } else { 'ok' }); Text = $(if ($bad.Count) { 'Thiếu công cụ' } else { 'Công cụ' })
                      Tip = $(if ($bad.Count) { 'Kiểm tra máy: thiếu ' + (($bad | ForEach-Object { if ($_ -eq 'ytdlp') { 'yt-dlp' } else { $_ } }) -join ', ') } else { 'Kiểm tra máy: ADB, scrcpy, FFmpeg, ffprobe, yt-dlp sẵn sàng.' }) }
    }
    $dev = [regex]::Match($Text, '(?m)^\s*v\s+(.*?)\s+\(Android\s+([^)]*)\)\s+\[([^\]]+)\]')
    $ready = ($Text -match 'MAY DA SAN SANG')
    if ($dev.Success -and $ready) {
        $r.Device = @{ State = 'ok'; Text = 'Thiết bị'; Tip = "Sẵn sàng: $($dev.Groups[1].Value.Trim()) (Android $($dev.Groups[2].Value)) [$($dev.Groups[3].Value)]" }
    } elseif ($Text -match '(?m)^\[2\]\s') {
        $msg = [regex]::Match($Text, 'KHONG XONG\s+(\S[^\r\n]*)')
        $tip = if ($msg.Success) { 'Chưa sẵn sàng: ' + $msg.Groups[1].Value.Trim() } else { 'Chưa sẵn sàng — xem Cài đặt › Nhật ký.' }
        $r.Device = @{ State = 'bad'; Text = 'Thiết bị'; Tip = $tip }
    } elseif ($toolState.Values -contains 'bad') {
        $r.Device = @{ State = 'unknown'; Text = 'Thiết bị'; Tip = 'Chưa kiểm tra thiết bị vì thiếu công cụ.' }
    }
    return $r
}

function Update-HeaderChipsFromCheck {
    param([string]$Text)
    $st = Get-CheckChipState -Text $Text
    Set-HeaderChip -Chip 'Device' -State $st.Device.State -Text $st.Device.Text -Tip $st.Device.Tip
    if ($st.Scrcpy) { Set-HeaderChip -Chip 'Scrcpy' -State $st.Scrcpy.State -Text $st.Scrcpy.Text -Tip $st.Scrcpy.Tip }
    if ($st.Tools)  { Set-HeaderChip -Chip 'Tools'  -State $st.Tools.State  -Text $st.Tools.Text  -Tip $st.Tools.Tip }
}

function Install-ToolGUI {
    param([string]$ToolName)
    if ($script:ps -or ($script:queue -and $script:queue.Count -gt 0)) {
        Show-Toast 'Hãy hoàn tất tác vụ và hàng đợi trước khi cài công cụ.' -Kind warning
        return
    }
    $tDir = Join-Path $script:root 'tools'
    foreach ($sub in @('', '_download', 'scrcpy', 'ffmpeg')) {
        $p = if ($sub) { Join-Path $tDir $sub } else { $tDir }
        if (-not (Test-Path -LiteralPath $p)) {
            try { [void][System.IO.Directory]::CreateDirectory($p) }
            catch { Add-Log "Không tạo được thư mục '$p': $($_.Exception.Message)" 'Warning' }
        }
    }
    Show-Page 'settings' -Sub 'logs'
    Add-Log ""
    Add-Log "===== Đang tải và cài công cụ: $ToolName =====" 'Info'
    Start-Engine -Links @() -Named @{ SetupTool = $ToolName } -Mode 'setup' -XoaLog $false
}
function Start-Engine {
    param([string[]]$Links, [hashtable]$Named, [string]$Mode, [bool]$XoaLog = $true)
    if ($script:ps) { return }
    if ($Mode -notin @('run','reedit') -and $script:queue -and $script:queue.Count -gt 0) {
        Show-Toast 'Hãy dừng hoặc đợi hàng đợi hoàn tất trước khi kiểm tra hoặc cài công cụ.' -Kind warning
        return
    }
    # The engine registers only subprocesses it owns; a fresh registry is safe after Finish-Engine disposed the prior pipeline.
    $script:childProcesses = [hashtable]::Synchronized(@{})
    $script:stopHandle = $null
    $script:seenErrors = 0
    $script:loggedErrors = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    $script:cancelRequested = $false
    if ($XoaLog) { Clear-LogBatch; if ($ui.TxtLog) { $ui.TxtLog.Clear() }; [void]$script:runLog.Clear() }
    $script:seen = 0; $script:mode = $Mode; [void]$script:runLog.Clear(); $script:stopping = $false
    $script:currentResult = $null
    $ui.PanelRev.Visibility = 'Collapsed'
    $candidate = $null
    try {
        Set-Busy $true
        try { [System.Environment]::CurrentDirectory = $script:root } catch { <# bo qua: khong doi duoc thu muc hien tai; engine dung duong dan tuyet doi #> }
        # Do not publish a partially configured runspace as the active task.
        $candidate = [PowerShell]::Create()
        [void]$candidate.AddCommand('Set-Location').AddParameter('LiteralPath', $script:root)
        [void]$candidate.AddStatement()
        [void]$candidate.AddCommand($engine)
        if ($Links) { foreach ($l in $Links) { [void]$candidate.AddArgument($l) } }
        if ($Named) { foreach ($k in $Named.Keys) { [void]$candidate.AddParameter($k, $Named[$k]) } }
        [void]$candidate.AddParameter('ProcessRegistry', $script:childProcesses)
        $invokeHandle = $candidate.BeginInvoke()
        $script:ps = $candidate
        $script:handle = $invokeHandle
        $timer.Start()
        Update-ActionBar
    } catch {
        $startError = $_.Exception.Message
        # If launch got as far as starting a pipeline, cancel only its children.
        if ($script:ps) { try { Stop-Engine } catch { <# bo qua: don dep khi huy/dong, loi o day khong anh huong ket qua #> } }
        if ($candidate) { try { $candidate.Dispose() } catch { <# bo qua: don dep khi huy/dong, loi o day khong anh huong ket qua #> } }
        $script:ps = $null; $script:handle = $null; $script:stopHandle = $null
        $script:stopping = $false; $script:cancelRequested = $false
        $timer.Stop()
        if ($Mode -eq 'run') {
            foreach ($pendingUrl in @($script:queue | Select-Object -Skip $script:idx)) {
                Add-Log ("Chưa khởi động: $pendingUrl") 'Warning'
            }
            $script:queue = @()
            $script:forceRetryRejected = $false
            $script:queueOutDir = ''
        }
        Set-Busy $false
        Add-Line ("LỖI KHỞI ĐỘNG: $startError")
        $ui.TxtStat.Text = 'Không khởi động được tác vụ · xem Cài đặt › Nhật ký'
        $ui.TxtStat.Foreground = (Get-Brush 'DangerText')
        if ($Mode -eq 'reedit') {
            Complete-Reedit
        } elseif ($Mode -eq 'run' -and $script:lastCompletedOut -and
            (Test-Path -LiteralPath $script:lastCompletedOut -PathType Leaf)) {
            Load-Player $script:lastCompletedOut
        }
        Show-Toast 'Không khởi động được tác vụ. Đã giải phóng hàng đợi; xem Cài đặt › Nhật ký rồi thử lại.' -Kind error
    }
}

function Stop-Engine {
    if (-not $script:ps) { return }
    $script:stopping = $true
    $script:cancelRequested = $true
    Update-PrimaryButton
    $owned = @()
    $registry = $script:childProcesses
    if ($registry) {
        [System.Threading.Monitor]::Enter($registry.SyncRoot)
        try { $owned = @($registry.Values) }
        finally { [System.Threading.Monitor]::Exit($registry.SyncRoot) }
    }
    foreach ($proc in $owned) {
        try { if ($proc -and -not $proc.HasExited) { $proc.Kill() } } catch { <# bo qua: don dep khi huy/dong, loi o day khong anh huong ket qua #> }
    }
    if (-not $script:stopHandle) {
        try { $script:stopHandle = $script:ps.BeginStop($null, $null) }
        catch { $script:stopHandle = $null }
    }
    # Keep the dispatcher timer and busy state active until both async operations finish.
}

function Pump-Output {
    if (-not $script:ps) { return }
    $inf = $script:ps.Streams.Information
    while ($script:seen -lt $inf.Count) {
        $rec = $inf[$script:seen]; $script:seen++
        $md = $rec.MessageData; $msg = ''
        if ($null -ne $md) {
            if ($md.PSObject.Properties.Name -contains 'Message') { $msg = [string]$md.Message }
            else { $msg = [string]$md }
        }
        foreach ($ln in ($msg -split "`r?
")) { Add-Line $ln }
    }
    $errs = $script:ps.Streams.Error
    while ($script:seenErrors -lt $errs.Count) {
        $rec = $errs[$script:seenErrors]
        $script:seenErrors++
        if (-not (($script:cancelRequested -or $script:stopping) -and (Test-PipelineStoppedException $rec))) {
            $errText = [string]$rec.Exception.Message
            if (-not $script:loggedErrors.Contains($errText)) {
                [void]$script:loggedErrors.Add($errText)
                Add-Line "LỖI: $errText"
            }
        }
    }
}

function Test-PipelineStoppedException {
    # Nhan ca Exception lan ErrorRecord. Khi PowerShell co nhieu statement (Set-Location; engine) bi BeginStop,
    # EndInvoke KHONG nem loi ma Streams.Error nhan mot ErrorRecord FQID 'PipelineStopped' voi
    # Exception = ParentContainsErrorRecordException (khong co InnerException) -> phai nhan theo FQID / ErrorRecord long.
    param($ErrorOrException)
    if ($null -eq $ErrorOrException) { return $false }
    $records = New-Object System.Collections.ArrayList
    $exceptions = New-Object System.Collections.ArrayList
    if ($ErrorOrException -is [System.Management.Automation.ErrorRecord]) { [void]$records.Add($ErrorOrException) }
    elseif ($ErrorOrException -is [System.Exception]) { [void]$exceptions.Add($ErrorOrException) }
    else { return $false }
    $guard = 0
    while (($records.Count -or $exceptions.Count) -and $guard -lt 32) {
        $guard++
        if ($records.Count) {
            $rec = $records[0]; $records.RemoveAt(0)
            if ([string]$rec.FullyQualifiedErrorId -match '^PipelineStopped(,|$)') { return $true }
            if ($rec.Exception) { [void]$exceptions.Add($rec.Exception) }
            continue
        }
        $current = $exceptions[0]; $exceptions.RemoveAt(0)
        while ($current) {
            if ($current -is [System.Management.Automation.PipelineStoppedException]) { return $true }
            if ($current -is [System.Management.Automation.IContainsErrorRecord] -and $current.ErrorRecord -and
                -not [object]::ReferenceEquals($current.ErrorRecord.Exception, $current)) { [void]$records.Add($current.ErrorRecord) }
            elseif ($current -is [System.Management.Automation.IContainsErrorRecord] -and $current.ErrorRecord -and
                [string]$current.ErrorRecord.FullyQualifiedErrorId -match '^PipelineStopped(,|$)') { return $true }
            $current = $current.InnerException
        }
    }
    return $false
}

function Finish-Engine {
    param([bool]$Cancelled = $false)
    $psInstance = $script:ps
    $invokeHandle = $script:handle
    if (-not $psInstance) { return }
    try {
        if ($invokeHandle) {
            try { [void]$psInstance.EndInvoke($invokeHandle) }
            catch {
                if (-not (($Cancelled -or $script:cancelRequested) -and (Test-PipelineStoppedException $_.Exception))) {
                    $errText = [string]$_.Exception.Message
                    if (-not $script:loggedErrors.Contains($errText)) {
                        [void]$script:loggedErrors.Add($errText)
                        Add-Line "LỖI: $errText"
                    }
                }
            }
        }
        Pump-Output
    } finally {
        try { $psInstance.Dispose() } catch { <# bo qua: don dep khi huy/dong, loi o day khong anh huong ket qua #> }
        if ([object]::ReferenceEquals($script:ps, $psInstance)) {
            $script:ps = $null
            $script:handle = $null
            $script:stopHandle = $null
            $script:stopping = $false
            $script:cancelRequested = $false
            $timer.Stop()
            Set-Busy $false
            if (Get-Command Update-LinkDuplicateWarning -ErrorAction SilentlyContinue) { Update-LinkDuplicateWarning }
        }
    }
}

function Start-Link {
    if ($script:ps -or $script:stopping -or $script:cancelRequested) { return }
    if (-not $script:queue -or $script:queue.Count -eq 0 -or $script:idx -lt 0 -or $script:idx -ge $script:queue.Count) {
        Show-Toast 'Không có video đang chờ xử lý trong hàng đợi.' -Kind warning
        return
    }
    if ([string]::IsNullOrWhiteSpace($script:queueOutDir) -or -not [IO.Path]::IsPathRooted($script:queueOutDir)) {
        # Khong bao gio doan thu muc: hang doi nao cung phai co thu muc dich da chup luc bat dau.
        Write-FileLog "ERR  Start-Link: queueOutDir trống ('$($script:queueOutDir)')" -Immediate
        Show-Toast 'Không xác định được kho để lưu video. Đã dừng hàng đợi; chọn kho ở trang Nguồn rồi bấm Bắt đầu lại.' -Kind error
        $script:queue = @(); Set-Busy $false; Update-ActionBar
        return
    }
    Clear-Player
    $script:currentStep = 0
    [void](Update-QueueRow -QueueIdx $script:idx -Changes @{ Status = 'running'; Step = 0; Message = 'Đang khởi động…'; SyncText = ''; SyncWarn = $false; ActionOverride = '' })
    $n = $script:idx + 1
    Add-Log '' ; Add-Log "===== Video $n/$($script:queue.Count) =====" 'Info'
    Add-Log $script:queue[$script:idx] 'Muted'
    # Muc dang chay + buoc hien o TxtCurrentItem (Update-ActionBar); TxtStat chi cho thong diep phu.
    $ui.TxtStat.Text = ''

    $posIdx = if ($ui.CmbLogoPosition -and $ui.CmbLogoPosition.SelectedIndex -ge 0 -and $ui.CmbLogoPosition.SelectedIndex -le 4) { $ui.CmbLogoPosition.SelectedIndex } else { [int]$script:logoLastPresetIdx }
    $gifPosIdx = if ($ui.CmbGifPosition -and $ui.CmbGifPosition.SelectedIndex -ge 0 -and $ui.CmbGifPosition.SelectedIndex -le 4) { $ui.CmbGifPosition.SelectedIndex } else { [int]$script:gifLastPresetIdx }
    $isFixedMode = ($ui.CmbLogoMode -and $ui.CmbLogoMode.SelectedIndex -eq 1)
    $logoCustX = if ($isFixedMode -and $null -ne $script:logoCustomX -and ([string]$script:logoCustomX).Trim().Length -gt 0 -and [double]$script:logoCustomX -ge 0.0) { [double]$script:logoCustomX } else { -1.0 }
    $logoCustY = if ($isFixedMode -and $null -ne $script:logoCustomY -and ([string]$script:logoCustomY).Trim().Length -gt 0 -and [double]$script:logoCustomY -ge 0.0) { [double]$script:logoCustomY } else { -1.0 }
    $gifCustX  = if ($null -ne $script:gifCustomX -and ([string]$script:gifCustomX).Trim().Length -gt 0 -and [double]$script:gifCustomX -ge 0.0) { [double]$script:gifCustomX } else { -1.0 }
    $gifCustY  = if ($null -ne $script:gifCustomY -and ([string]$script:gifCustomY).Trim().Length -gt 0 -and [double]$script:gifCustomY -ge 0.0) { [double]$script:gifCustomY } else { -1.0 }

    $namedArgs = @{
        OutDir             = [string]$script:queueOutDir;   # chup luc bat dau hang doi (kho tai ve) hoac thu muc cua video khi ghi am lai; khong doc lai TxtOut
        Watermark          = [bool]$ui.ChkWatermark.IsChecked;
        LogoFile           = $ui.TxtLogoPath.Text;
        LogoSize           = [int]$ui.SldLogoSize.Value;
        LogoFade           = [int]$ui.SldLogoFade.Value;
        LogoMotion         = $(if ($ui.CmbLogoMode.SelectedIndex -eq 0) { 'Free' } else { 'Fixed' });
        LogoPosition       = @('TopLeft','TopRight','BottomLeft','BottomRight','Center')[$posIdx];
        GifWatermark       = [bool]($ui.ChkGif -and $ui.ChkGif.IsChecked -and $ui.TxtGifPath -and -not [string]::IsNullOrWhiteSpace($ui.TxtGifPath.Text));
        GifFile            = $(if ($ui.TxtGifPath) { $ui.TxtGifPath.Text } else { '' });
        GifSize            = $(if ($ui.SldGifSize) { [int]$ui.SldGifSize.Value } else { 20 });
        GifFullFrame       = [bool]$script:gifFullFrame;
        GifPosition        = @('TopLeft','TopRight','BottomLeft','BottomRight','Center')[$gifPosIdx];
        LogoCustomX        = [double]$logoCustX;
        LogoCustomY        = [double]$logoCustY;
        LogoCustomWidth    = [double]$script:logoCustomWidth;
        LogoCustomHeight   = [double]$script:logoCustomHeight;
        GifCustomX         = [double]$gifCustX;
        GifCustomY         = [double]$gifCustY;
        GifCustomWidth     = [double]$script:gifCustomWidth;
        GifCustomHeight    = [double]$script:gifCustomHeight
    }
    if ($script:forceRetryRejected) {
        if (Test-EngineParameter 'ForceRetryRejected') { $namedArgs['ForceRetryRejected'] = $true }
        else { Add-Log 'Engine hiện tại chưa hỗ trợ -ForceRetryRejected (cần bản engine mới); video đã loại sẽ vẫn bị bỏ qua.' 'Warning' }
    }
    # G-C3: nguoi dung bat "dong bo theo am thanh khi khong thu duoc hinh" o Cai dat > Tuy chon (mac dinh tat).
    if ($ui.ChkAllowOnsetSync -and $ui.ChkAllowOnsetSync.IsChecked) {
        if (Test-EngineParameter 'AllowOnsetSync') { $namedArgs['AllowOnsetSync'] = $true }
        else { Add-Log 'Engine hiện tại chưa hỗ trợ -AllowOnsetSync; bỏ qua lựa chọn đồng bộ theo âm thanh.' 'Warning' }
    }
    Start-Engine -Links @($script:queue[$script:idx]) -Named $namedArgs -Mode 'run' -XoaLog $false
}

function Test-EngineParameter {
    # Kiem tham so engine bang metadata script (khong chay engine). Ket qua duoc cache.
    param([string]$Name)
    # Parser::ParseFile nhan duong dan nguyen van (khong dien giai wildcard [] nhu Get-Command -Name).
    $stamp = $null
    try { $stamp = [System.IO.File]::GetLastWriteTimeUtc($engine) } catch { Write-FileLog "WARN Không đọc được thời gian sửa engine: $($_.Exception.Message)" }
    if (-not $script:engineParamCache -or $script:engineParamCacheStamp -ne $stamp -or $script:engineParamCachePath -ne $engine) {
        $cache = @{}
        try {
            $tokens = $null; $parseErrors = $null
            $ast = [System.Management.Automation.Language.Parser]::ParseFile($engine, [ref]$tokens, [ref]$parseErrors)
            if ($parseErrors -and $parseErrors.Count) { throw "Engine có lỗi cú pháp: $($parseErrors[0].Message)" }
            if ($ast.ParamBlock) {
                foreach ($p in $ast.ParamBlock.Parameters) { $cache[$p.Name.VariablePath.UserPath] = $true }
            }
        } catch {
            Add-Log "Không đọc được tham số engine: $($_.Exception.Message)" 'Warning'
        }
        $script:engineParamCache = $cache
        $script:engineParamCacheStamp = $stamp
        $script:engineParamCachePath = $engine
    }
    return $script:engineParamCache.ContainsKey($Name)
}

function Start-RecordingAgain {
    if ($script:ps -or $script:stopping -or ($script:queue -and $script:queue.Count)) {
        Show-Toast 'Hãy dừng hoặc đợi hàng đợi hoàn tất trước khi ghi âm lại.' -Kind warning
        return
    }
    if ($script:importBusy) {
        Show-Toast 'Đang thêm video từ thư mục — hãy đợi xong rồi ghi âm lại.' -Kind warning
        return
    }
    $redoFile = $script:lastOut
    if (-not $redoFile -or -not (Test-Path -LiteralPath $redoFile -PathType Leaf)) {
        Show-Toast 'Chọn video đã xuất trong Kho trước khi ghi âm lại.' -Kind warning
        return
    }
    if (Test-KhoExternalKey (Get-ReelId $redoFile)) { Show-Toast 'Chỉ dùng cho video do app tạo.' -Kind warning; return }
    $match = [regex]::Match([IO.Path]::GetFileName($redoFile), '^(\d+)-3-hoan-chinh\.mp4$', [Text.RegularExpressions.RegexOptions]::IgnoreCase)
    if (-not $match.Success) {
        Show-Toast 'Không xác định được ID Facebook từ tên video để ghi âm lại.' -Kind warning
        return
    }
    # The explicit retry is a one-item queue targeting the selected video's folder.
    # Existing files remain intact until the engine successfully publishes replacements.
    # Thu muc dich = chinh thu muc cua video (truyen thang cho engine); TxtOut / kho tai ve khong bi dong den.
    $redoDir = [IO.Path]::GetDirectoryName([IO.Path]::GetFullPath($redoFile))
    if ($script:khoMoveRunning -or $script:khoExclusive -gt 0) { Show-Toast 'Đang chuyển kho hoặc mở hộp thoại đăng/dọn dẹp. Thử lại sau.' -Kind warning; return }
    $jBlock = Get-KhoJournalBlock @($redoDir)
    if ($jBlock) { Show-Toast $jBlock -Kind warning; return }
    $script:queueOutDir = $redoDir
    $script:queue = @('https://www.facebook.com/reel/' + $match.Groups[1].Value + '/')
    $script:idx = 0; $script:giu = 0; $script:bo = 0; $script:loi = 0; $script:chuaXN = 0; $script:boTruoc = 0; $script:skipExisting = 0; $script:queueFinalizedIdx = -1
    $script:failedLinks = @(); $script:lastCompletedOut = $redoFile
    # Ghi am lai la yeu cau ro rang cua nguoi dung: bo qua lich su loai cho link nay (CONTRACT §2).
    $script:forceRetryRejected = $true
    # Dong danh dau Origin=redo: nut "Thu lai" se chay lai dung luong Ghi am lai (G-R4).
    Initialize-QueueRows -Links $script:queue -Origin 'redo' -RedoFile $redoFile
    Show-Page 'queue'
    Add-Log ('Ghi âm lại Reel #' + $match.Groups[1].Value + ' · giữ bản cũ nếu xử lý lỗi hoặc bị dừng.') 'Info'
    Start-Link
}

function Start-Reedit {
    if ($script:ps) { return }
    if ($script:importBusy) { Show-Toast 'Đang thêm video từ thư mục — hãy đợi xong rồi sửa video.' -Kind warning; return }
    if ($script:khoMoveRunning -or $script:khoExclusive -gt 0) { Show-Toast 'Đang chuyển kho hoặc mở hộp thoại đăng/dọn dẹp. Thử lại sau.' -Kind warning; return }
    if (-not $script:lastOut -or -not (Test-Path -LiteralPath $script:lastOut)) {
        Show-Toast 'Chọn video đã xuất trong Kho trước khi sửa lại.' -Kind warning
        return
    }
    $jBlock = Get-KhoJournalBlock @([IO.Path]::GetDirectoryName([IO.Path]::GetFullPath([string]$script:lastOut)))
    if ($jBlock) { Show-Toast $jBlock -Kind warning; return }

    $posIdx = if ($ui.CmbLogoPosition -and $ui.CmbLogoPosition.SelectedIndex -ge 0 -and $ui.CmbLogoPosition.SelectedIndex -le 4) { $ui.CmbLogoPosition.SelectedIndex } else { [int]$script:logoLastPresetIdx }
    $gifPosIdx = if ($ui.CmbGifPosition -and $ui.CmbGifPosition.SelectedIndex -ge 0 -and $ui.CmbGifPosition.SelectedIndex -le 4) { $ui.CmbGifPosition.SelectedIndex } else { [int]$script:gifLastPresetIdx }
    $isFixedMode = ($ui.CmbLogoMode -and $ui.CmbLogoMode.SelectedIndex -eq 1)
    $logoCustX = if ($isFixedMode -and $null -ne $script:logoCustomX -and ([string]$script:logoCustomX).Trim().Length -gt 0 -and [double]$script:logoCustomX -ge 0.0) { [double]$script:logoCustomX } else { -1.0 }
    $logoCustY = if ($isFixedMode -and $null -ne $script:logoCustomY -and ([string]$script:logoCustomY).Trim().Length -gt 0 -and [double]$script:logoCustomY -ge 0.0) { [double]$script:logoCustomY } else { -1.0 }
    $gifCustX  = if ($null -ne $script:gifCustomX -and ([string]$script:gifCustomX).Trim().Length -gt 0 -and [double]$script:gifCustomX -ge 0.0) { [double]$script:gifCustomX } else { -1.0 }
    $gifCustY  = if ($null -ne $script:gifCustomY -and ([string]$script:gifCustomY).Trim().Length -gt 0 -and [double]$script:gifCustomY -ge 0.0) { [double]$script:gifCustomY } else { -1.0 }

    $script:reeditTarget = $script:lastOut
    $script:reeditReviewVisible = ($ui.PanelRev.Visibility -eq 'Visible')
    $named = @{ ReeditVideo=$script:reeditTarget; Watermark=[bool]$ui.ChkWatermark.IsChecked; LogoFile=$ui.TxtLogoPath.Text;
                LogoSize=[int]$ui.SldLogoSize.Value; LogoFade=[int]$ui.SldLogoFade.Value;
                LogoMotion=$(if ($ui.CmbLogoMode.SelectedIndex -eq 0) {'Free'} else {'Fixed'});
                LogoPosition=@('TopLeft','TopRight','BottomLeft','BottomRight','Center')[$posIdx];
                GifWatermark=[bool]($ui.ChkGif -and $ui.ChkGif.IsChecked -and $ui.TxtGifPath -and -not [string]::IsNullOrWhiteSpace($ui.TxtGifPath.Text));
                GifFile=$(if ($ui.TxtGifPath) { $ui.TxtGifPath.Text } else { '' });
                GifSize=$(if ($ui.SldGifSize) { [int]$ui.SldGifSize.Value } else { 20 });
                GifFullFrame=[bool]$script:gifFullFrame;
                GifPosition=@('TopLeft','TopRight','BottomLeft','BottomRight','Center')[$gifPosIdx];
                LogoCustomX=[double]$logoCustX; LogoCustomY=[double]$logoCustY;
                LogoCustomWidth=[double]$script:logoCustomWidth; LogoCustomHeight=[double]$script:logoCustomHeight;
                GifCustomX=[double]$gifCustX; GifCustomY=[double]$gifCustY;
                GifCustomWidth=[double]$script:gifCustomWidth; GifCustomHeight=[double]$script:gifCustomHeight }
    Clear-Player
    Add-Log 'Sửa logo và GIF từ video gốc và audio đã lưu…' 'Info'
    $ui.TxtStat.Text='Đang áp dụng thay đổi logo và GIF…'
    Start-Engine -Links @() -Named $named -Mode 'reedit' -XoaLog $false
}

function Complete-Reedit {
    param([bool]$Cancelled = $false)
    $ok = (-not $Cancelled -and $script:runLog.ToString() -match '(?m)^REEDIT_OK:')
    $script:previewingClean = $false
    if ($ui.BadgePreviewMode) { $ui.BadgePreviewMode.Visibility = 'Collapsed' }
    if ($script:reeditTarget -and (Test-Path -LiteralPath $script:reeditTarget)) { Load-Player $script:reeditTarget }
    $ui.PanelRev.Visibility = $(if ($script:reeditReviewVisible) {'Visible'} else {'Collapsed'})
    $ui.TxtStat.Text = $(if ($ok) {'Đã sửa logo và GIF · sẵn sàng xem lại'} elseif ($Cancelled) {'Đã dừng sửa · giữ video cũ'} else {'Chưa sửa được · giữ video cũ, xem Nhật ký'})
    Update-Gallery
    Update-ActionBar
    if ($ok) { Show-Toast 'Đã áp dụng logo và GIF mới vào video.' -Kind success }
    elseif (-not $Cancelled) { Show-Toast 'Chưa sửa được video; bản cũ được giữ nguyên. Xem Cài đặt › Nhật ký.' -Kind error }
}

$script:reasonText = @{
    'vietnamese-unavailable' = 'Meta không có bản lồng tiếng Việt cho video này'
    'already-rejected'       = 'Đã bị loại trước đây'
    'dub-unverified'         = 'Chưa xác nhận được tiếng Việt trên Reel — thử lại sau nhé'
    'no-onset'               = 'Không tìm được điểm bắt đầu tiếng trong bản thu'
    'short-capture'          = 'Bản thu ngắn hơn video'
    'silent-capture'         = 'Bản thu không có tiếng — kiểm tra âm lượng thiết bị'
    'start-missing'          = 'Reel không phát từ giây 0 trong bản thu (đã thử 2 lần)'
    'low-confidence'         = 'Khớp hình chưa đủ chắc chắn (đã thử 2 lần)'
    'no-video-sync'          = 'Không thu được hình màn hình để đồng bộ (có thể bật đồng bộ theo âm thanh ở Cài đặt › Tùy chọn)'
    'download-failed'        = 'Tải video thất bại (đã thử 3 lần)'
    'metadata-failed'        = 'Không đọc được video từ link Facebook'
    'invalid-link'           = 'Link Facebook không hợp lệ'
    'invalid-duration'       = 'Độ dài video tải về bất thường'
    'duration-mismatch'      = 'Độ dài video đổi sau khi thu âm'
    'capture-failed'         = 'Thu âm từ Android thất bại'
    'audio-failed'           = 'Xử lý âm thanh thất bại'
    'mux-failed'             = 'Ghép video thất bại'
    'invalid-output'         = 'File hoàn chỉnh không đạt kiểm tra'
    'publish-failed'         = 'Lưu file xuất thất bại'
    'output-locked'          = 'File video đang được mở ở ứng dụng khác — đóng trình xem rồi thử lại'
    'history-save-failed'    = 'Không lưu được lịch sử loại'
    'stopped'                = 'Đã dừng giữa chừng'
    'exception'              = 'Có lỗi xảy ra trong lúc xử lý (xem Nhật ký)'
    'missing-output'         = 'Đã xử lý xong nhưng không thấy file video'
    'gui-exception'          = 'Lỗi nội bộ giao diện (xem Nhật ký)'
    'unknown'                = 'Có lỗi xảy ra (xem Nhật ký)'
}

function Get-ReasonText {
    # Ma reason cua engine (khong dau) -> cau tieng Viet co dau than thien. Ma la -> "Co loi xay ra · ma <reason>".
    param([string]$Reason)
    $k = ([string]$Reason).Trim().ToLowerInvariant()
    if ($k -and $script:reasonText.ContainsKey($k)) { return $script:reasonText[$k] }
    if (-not $k) { return $script:reasonText['unknown'] }
    return "Có lỗi xảy ra · mã $k"
}

function Get-QueueItemOutcome {
    # Phan loai ket qua mot muc. Uu tien @@KIDFBY_RESULT (CONTRACT §1); khong co RESULT -> regex log cu.
    # Kind: saved | rejected | skipped (da loai truoc) | failed | cancelled
    # Message = cau tieng Viet co dau cho nguoi dung (Get-ReasonText); thong diep goc khong dau cua engine chi ghi log (RawMessage).
    param($Result, [string]$Log)
    if ($null -ne $Result) {
        $status = ([string]$Result.status).ToLowerInvariant()
        $reason = [string]$Result.reason
        $message = [string]$Result.message
        if ($message) { Write-FileLog "INFO engine result status=$status reason=$reason message=$message" }
        switch ($status) {
            'ok' {
                $video = [string]$Result.video
                if ($video -and (Test-Path -LiteralPath $video -PathType Leaf)) {
                    $note = if ($message -match 'sync-drift[^0-9]*?(\d+)\s*ms') { "cảnh báo: hình màn hình trễ $($Matches[1]) ms giữa các đoạn" } else { '' }
                    return @{ Kind = 'saved'; Video = $video; Reason = $reason; Message = $note; RawMessage = $message; Source = 'result' }
                }
                Write-FileLog "WARN engine báo ok nhưng không thấy file: $video"
                return @{ Kind = 'failed'; Video = $video; Reason = 'missing-output'; Message = (Get-ReasonText 'missing-output'); RawMessage = $message; Source = 'result' }
            }
            'rejected' {
                $kind = if ($reason -eq 'already-rejected') { 'skipped' } else { 'rejected' }
                return @{ Kind = $kind; Video = ''; Reason = $reason; Message = (Get-ReasonText $reason); RawMessage = $message; Source = 'result' }
            }
            'cancelled' { return @{ Kind = 'cancelled'; Video = ''; Reason = $reason; Message = (Get-ReasonText $(if ($reason) { $reason } else { 'stopped' })); RawMessage = $message; Source = 'result' } }
            default {
                # unverified | failed | trang thai la -> cau than thien theo reason
                $r = if ($reason) { $reason } else { 'unknown' }
                return @{ Kind = 'failed'; Video = ''; Reason = $reason; Message = (Get-ReasonText $r); RawMessage = $message; Source = 'result'; Status = $status }
            }
        }
    }
    if ($Log -match '(?m)REEL_REJECTED:') {
        $reasonMatch = [regex]::Match($Log, '(?m)REEL_REJECTED:.*\breason=(\S+)')
        $reason = if ($reasonMatch.Success) { $reasonMatch.Groups[1].Value } else { '' }
        $kind = if ($reason -eq 'already-rejected') { 'skipped' } else { 'rejected' }
        return @{ Kind = $kind; Video = ''; Reason = $reason; Message = ''; Source = 'log' }
    }
    $match = [regex]::Match([string]$Log, '(?m)^\s*Video\s*:\s*(.+\.mp4)\s*$')
    $output = if ($match.Success) { $match.Groups[1].Value.Trim() } else { '' }
    if ($output -and (Test-Path -LiteralPath $output -PathType Leaf)) {
        return @{ Kind = 'saved'; Video = $output; Reason = ''; Message = ''; Source = 'log' }
    }
    return @{ Kind = 'failed'; Video = ''; Reason = ''; Message = ''; Source = 'log' }
}

function Format-QueueSummary {
    # Dung hang doi -> "Da dung · ...", khong ghi "Hoan tat" (G-E2E).
    param([switch]$Stopped)
    $head = if ($Stopped) { 'Đã dừng' } else { 'Hoàn tất' }
    $unv = $(if ([int]$script:chuaXN -gt 0) { " · $($script:chuaXN) chưa xác nhận" } else { '' })
    return "$head · $($script:giu) đã lưu · $($script:bo) bị loại · $($script:boTruoc) bỏ qua (đã loại trước)$unv · $($script:loi) lỗi"
}

function Get-SyncInfo {
    # Truong dong bo (engine dot 2, tuy chon): syncMethod "video"|"onset", syncConfidence, t0Onset, syncDriftMs.
    # Khong co truong -> chuoi rong (GUI cu/engine cu van chay binh thuong).
    param($Result)
    $info = @{ Text = ''; Warn = $false }
    if ($null -eq $Result) { return $info }
    $names = @($Result.PSObject.Properties.Name)
    if (-not ($names -contains 'syncMethod') -or [string]::IsNullOrWhiteSpace([string]$Result.syncMethod)) { return $info }
    $inv = [Globalization.CultureInfo]::InvariantCulture
    $method = switch ([string]$Result.syncMethod) { 'video' { 'hình' } 'onset' { 'âm' } default { [string]$Result.syncMethod } }
    $parts = @("Đồng bộ: $method")
    $conf = 0.0
    if ($names -contains 'syncConfidence' -and $null -ne $Result.syncConfidence -and
        [double]::TryParse([string]$Result.syncConfidence, [Globalization.NumberStyles]::Float, $inv, [ref]$conf)) {
        $parts += ('độ tin cậy ' + $conf.ToString('0.00', $inv))
    }
    $drift = 0.0
    if ($names -contains 'syncDriftMs' -and $null -ne $Result.syncDriftMs -and
        [double]::TryParse([string]$Result.syncDriftMs, [Globalization.NumberStyles]::Float, $inv, [ref]$drift)) {
        if ($drift -gt 80.0) { $parts += ('cảnh báo trôi ' + $drift.ToString('0', $inv) + ' ms'); $info.Warn = $true }
        else { $parts += ('lệch ' + $drift.ToString('0', $inv) + ' ms') }
    }
    $info.Text = $parts -join ' · '
    return $info
}

function Get-OutcomeDetailText {
    # Chi tiet ky thuat cho nut "Chi tiet" (khong hien tren the): ma reason + thong diep goc cua engine (khong dau, de gui/tra cuu).
    param([hashtable]$Outcome)
    $lines = New-Object System.Collections.Generic.List[string]
    if ($Outcome.Message) { $lines.Add([string]$Outcome.Message) }
    if ($Outcome.Reason) { $lines.Add("Mã lý do: $($Outcome.Reason)") }
    if ($Outcome.RawMessage) { $lines.Add("Thông điệp kỹ thuật: $($Outcome.RawMessage)") }
    if ($lines.Count -eq 0) { return '' }
    return ($lines -join "`n")
}

function Register-QueueOutcome {
    # Cap nhat bo dem + log + dong bang cho muc hien tai; dung chung cho ket thuc binh thuong va nhanh Dung.
    param([hashtable]$Outcome)
    $n = $script:idx + 1; $total = $script:queue.Count
    $url = $script:queue[$script:idx]
    $script:queueFinalizedIdx = $script:idx
    $sync = Get-SyncInfo $script:currentResult
    $rowChanges = @{ SyncText = $sync.Text; SyncWarn = $sync.Warn }
    switch ($Outcome.Kind) {
        'saved' {
            $script:lastCompletedOut = $Outcome.Video
            $script:giu++
            Add-Log ("Đã lưu ($n/$total): $($Outcome.Video)") 'Success'
            if ($sync.Text) { Add-Log ("  " + $sync.Text) $(if ($sync.Warn) { 'Warning' } else { 'Muted' }) }
            $rowChanges.Status = 'ok'; $rowChanges.Step = 7; $rowChanges.Video = [string]$Outcome.Video
            $rowChanges.Message = 'Đã lưu ' + [IO.Path]::GetFileName([string]$Outcome.Video) + $(if ($Outcome.Message) { ' · ' + $Outcome.Message } else { '' })
        }
        'rejected' {
            $script:lastOut = ''; $script:activeTrack = $null
            $script:bo++
            $why = if ($Outcome.Message) { $Outcome.Message } elseif ($Outcome.Reason) { Get-ReasonText $Outcome.Reason } else { 'không có bản lồng tiếng Việt phù hợp' }
            Add-Log "Video $n/$total bị loại ($why); tự chuyển video tiếp theo." 'Warning'
            # Lich su loai vua doi: cap nhat tong ngay, khong doi Update-Gallery.
            Update-RejectedDashboard
            $rowChanges.Status = 'rejected'; $rowChanges.Message = $why
            $rowChanges.Detail = Get-OutcomeDetailText $Outcome
        }
        'skipped' {
            $script:lastOut = ''; $script:activeTrack = $null
            $script:boTruoc++
            Add-Log "Video $n/$total đã bị loại trước đây — bỏ qua." 'Warning'
            $rowChanges.Status = 'skipped'; $rowChanges.Message = 'Đã bị loại trước đây'
        }
        'cancelled' {
            Add-Log "Video $n/$total đã dừng giữa chừng." 'Warning'
            $rowChanges.Status = 'cancelled'; $rowChanges.Message = 'Đã dừng giữa chừng'
        }
        default {
            # "Chua xac nhan" (unverified) co the thu lai: dem rieng, khong tinh vao "loi".
            if ([string]$Outcome.Status -eq 'unverified') { $script:chuaXN++ } else { $script:loi++ }
            $script:failedLinks += $url
            $detail = if ($Outcome.Message) { " — $($Outcome.Message)" } else { '' }
            Add-Log ("Video $n/$total chưa hoàn tất$detail; đã ghi lỗi và tự chuyển tiếp: $url") 'Danger'
            $rowChanges.Status = $(if ([string]$Outcome.Status -eq 'unverified') { 'unverified' } else { 'failed' })
            $rowChanges.Message = $(if ($Outcome.Message) { [string]$Outcome.Message } else { 'Chưa hoàn tất; xem Nhật ký' })
            $rowChanges.Detail = Get-OutcomeDetailText $Outcome
        }
    }
    [void](Update-QueueRow -QueueIdx $script:idx -Changes $rowChanges)
    Update-ActionBar
}

function Complete-QueueItem {
    param([string]$Log)
    if ($script:ps -or $script:stopping -or $script:cancelRequested -or $script:mode -ne 'run' -or
        -not $script:queue -or $script:idx -lt 0 -or $script:idx -ge $script:queue.Count) { return }

    $ui.PanelRev.Visibility = 'Collapsed'
    $outcome = Get-QueueItemOutcome -Result $script:currentResult -Log $Log
    if ($script:queueFinalizedIdx -ne $script:idx) { Register-QueueOutcome $outcome }
    if ($Log -match 'REEL_CLEANUP_PENDING:') { Show-Toast 'Có file tạm đang bị khóa, chưa dọn được. Xem Cài đặt › Nhật ký.' -Kind warning }
    if ($outcome.Kind -eq 'cancelled') {
        # Engine tu bao huy: dung ca hang doi, khong chay muc sau.
        Stop-QueueSummary -Stopped
        Update-Gallery
        return
    }
    # No preview playback between items: the next item captures Android audio.
    Next-Link
}

function Stop-QueueSummary {
    param([switch]$Stopped)
    $script:queueOutDir = ''
    Add-Log ''
    Add-Log (Format-QueueSummary -Stopped:$Stopped) $(if ($Stopped) { 'Warning' } else { 'Success' })
    foreach ($failedUrl in $script:failedLinks) { Add-Log ("Link chưa hoàn tất: $failedUrl") 'Warning' }
    if ($Stopped) {
        # Dong dang chay / chua chay -> "Da dung" de bang khong con "Dang chay" sau khi dung.
        foreach ($q in @($script:queueRowByIdx.Keys | Sort-Object)) {
            $r = Get-QueueRow $q
            if ($r -and $r.Status -eq 'running') { [void](Update-QueueRow -QueueIdx $q -Changes @{ Status = 'cancelled'; Message = 'Đã dừng giữa chừng' }) }
            elseif ($r -and $r.Status -eq 'pending') { [void](Update-QueueRow -QueueIdx $q -Changes @{ Status = 'cancelled'; Message = 'Chưa chạy (đã dừng hàng đợi)' }) }
        }
    }
    $script:queue = @()
    $script:forceRetryRejected = $false
    $ui.PanelRev.Visibility = 'Collapsed'
    # Thanh day khong lap lai tong ket bang chu (so lieu nam o 4 pill): chi "Hoan tat/Da dung luc HH:mm".
    $script:lastQueueEnd = [pscustomobject]@{ Stopped = [bool]$Stopped; Time = Get-Date }
    $ui.TxtStat.Text = ''
    Set-Busy $false
    Show-Toast (Format-QueueSummary -Stopped:$Stopped) -Kind $(if ($Stopped -or $script:loi -or $script:chuaXN) { 'warning' } else { 'success' })
}

function Next-Link {
    if ($script:ps -or $script:stopping -or $script:cancelRequested -or
        -not $script:queue -or $script:idx -lt 0 -or $script:idx -ge $script:queue.Count) { return }
    $script:idx++
    if ($script:idx -lt $script:queue.Count) { Start-Link }
    else {
        Stop-QueueSummary
        Update-Gallery
        if ($script:lastCompletedOut -and (Test-Path -LiteralPath $script:lastCompletedOut -PathType Leaf)) {
            Load-Player $script:lastCompletedOut
        }
    }
}

# ------------------------------------------------------------------ nhip ----
$timer = New-Object Windows.Threading.DispatcherTimer
$timer.Interval = [TimeSpan]::FromMilliseconds(200)
function Invoke-EngineTickError {
    # Thay cho catch rong cu: ghi log (UI + file kem stack), giai phong hang doi neu chuoi chuyen muc bi gay,
    # va bao dam timer khong dung vinh vien khi engine con chay.
    param($ErrorRecord, [bool]$WasStopping = $false)
    $msg = if ($ErrorRecord -and $ErrorRecord.Exception) { $ErrorRecord.Exception.Message } else { [string]$ErrorRecord }
    $stack = if ($ErrorRecord -and $ErrorRecord.ScriptStackTrace) { [string]$ErrorRecord.ScriptStackTrace } else { '' }
    try {
        $key = $msg + '|' + $stack
        if ($key -eq $script:tickErrorKey) { $script:tickErrorRepeat++ } else { $script:tickErrorKey = $key; $script:tickErrorRepeat = 1 }
        # Loi lap lai moi 200 ms: chi hien 3 lan dau va moi lan thu 50.
        if ($script:tickErrorRepeat -le 3 -or ($script:tickErrorRepeat % 50) -eq 0) {
            $suffix = if ($script:tickErrorRepeat -gt 1) { " (lần $($script:tickErrorRepeat))" } else { '' }
            Add-Log "Lỗi nội bộ trong vòng xử lý hàng đợi: $msg$suffix" 'Danger'
            Write-FileLog "ERR  tick stack:`r`n$stack" -Immediate
        }
    } catch { $script:fileLogError = $_.Exception.Message }

    if ($script:ps) {
        # Engine van chay (loi o Pump-Output/ve UI): giu timer chay de con nhan ket thuc.
        if (-not $timer.IsEnabled) { $timer.Start() }
        return
    }
    if ($script:mode -ne 'run' -or -not $script:queue -or $script:queue.Count -eq 0) { return }
    if ($WasStopping -or $script:cancelRequested) {
        try { Stop-QueueSummary -Stopped } catch { $script:queue = @(); $script:queueOutDir = ''; Set-Busy $false }
        return
    }
    $reason = $msg
    $guard = 0
    while (-not $script:ps -and -not $script:stopping -and $script:queue -and
           $script:idx -ge 0 -and $script:idx -lt $script:queue.Count -and $guard -le $script:queue.Count) {
        $guard++
        if ($script:queueFinalizedIdx -ne $script:idx) {
            Register-QueueOutcome @{ Kind = 'failed'; Video = ''; Reason = 'gui-exception'; Message = "lỗi nội bộ GUI: $reason" }
        }
        try { Next-Link; return }
        catch {
            $reason = $_.Exception.Message
            Add-Log "Không chuyển được sang video tiếp theo: $reason" 'Danger'
            Write-FileLog "ERR  Next-Link stack:`r`n$($_.ScriptStackTrace)" -Immediate
        }
    }
    if (-not $script:ps -and $script:queue -and $script:queue.Count -gt 0) {
        foreach ($pendingUrl in @($script:queue | Select-Object -Skip ($script:idx + 1))) { Add-Log ("Chưa khởi động: $pendingUrl") 'Warning' }
        try { Stop-QueueSummary -Stopped } catch { $script:queue = @(); $script:queueOutDir = ''; Set-Busy $false }
    }
}

function Invoke-EngineTick {
    Pump-Output
    if ($script:stopping) {
            $stopDone = (-not $script:stopHandle -or $script:stopHandle.IsCompleted)
            $invokeDone = (-not $script:handle -or $script:handle.IsCompleted)
            if ($stopDone -and $invokeDone) {
                if ($script:stopHandle) { try { $script:ps.EndStop($script:stopHandle) } catch { Write-FileLog "WARN EndStop: $($_.Exception.Message)" } }
                Finish-Engine -Cancelled $true
                if ($script:mode -eq 'reedit') {
                    Complete-Reedit -Cancelled $true
                    if ($script:closeAfterStop) { $script:closeAfterStop = $false; $win.Close() }
                    return
                }
                if ($script:mode -eq 'run' -and $script:queue -and $script:idx -ge 0 -and $script:idx -lt $script:queue.Count -and
                    $script:queueFinalizedIdx -ne $script:idx) {
                    # Dung dung luc muc vua xong: ket qua da xac dinh van duoc tinh (G15).
                    $outcome = Get-QueueItemOutcome -Result $script:currentResult -Log $script:runLog.ToString()
                    if ($outcome.Kind -in @('saved','rejected','skipped')) { Register-QueueOutcome $outcome }
                }
                if ($script:mode -eq 'run' -and $script:queue -and $script:queue.Count -gt 0) { Stop-QueueSummary -Stopped }
                $script:queue = @()
                $script:forceRetryRejected = $false
                $script:queueOutDir = ''
                try { Update-Gallery } catch { Add-Log 'Không cập nhật được kho sau khi dừng; các file đã lưu vẫn được giữ nguyên.' 'Warning' }
                $ui.PanelRev.Visibility = 'Collapsed'
                if ($ui.TxtStat -and $script:mode -ne 'run') { $ui.TxtStat.Text = 'Đã dừng theo yêu cầu'; $ui.TxtStat.Foreground = (Get-Brush 'WarningText') }
                Update-ActionBar
                if ($script:closeAfterStop) { $script:closeAfterStop = $false; $win.Close() }
            }
            return
        }
        if ($script:handle -and $script:handle.IsCompleted) {
            $laCheck = ($script:mode -eq 'check')
            $laSetup = ($script:mode -eq 'setup')
            Finish-Engine -Cancelled $false
            $txt = $script:runLog.ToString()
            if ($script:mode -eq 'reedit') { Complete-Reedit; return }
            if ($laSetup) {
                # G-R3: vua cai cong cu -> worker quet Kho phai dung ffmpeg/ffprobe moi.
                Reset-MediaWorkerForTools 'vừa cài công cụ'
                Update-ToolsStatus
                $hasScrcpy = (Test-Path -LiteralPath (Join-Path $script:root 'tools\scrcpy\scrcpy.exe')) -or
                             (Test-Path -LiteralPath (Join-Path $script:root 'tools\scrcpy\scrcpy-win64-v5.0\scrcpy.exe')) -or
                             (Test-Path -LiteralPath (Join-Path $script:root 'tools\scrcpy\scrcpy-win64-v4.1\scrcpy.exe')) -or
                             (Test-Path -LiteralPath (Join-Path $script:root 'tools\scrcpy\scrcpy-win64-v3.1\scrcpy.exe')) -or
                             (Test-Path -LiteralPath (Join-Path $script:root 'tools\scrcpy\scrcpy-win64-v2.7\scrcpy.exe')) -or
                             (Test-Path -LiteralPath (Join-Path $script:root 'tools\scrcpy.exe')) -or
                             (Get-Command 'scrcpy' -ErrorAction SilentlyContinue)
                $hasAdb    = (Test-Path -LiteralPath (Join-Path $script:root 'tools\scrcpy\adb.exe')) -or
                             (Test-Path -LiteralPath (Join-Path $script:root 'tools\scrcpy\scrcpy-win64-v5.0\adb.exe')) -or
                             (Test-Path -LiteralPath (Join-Path $script:root 'tools\scrcpy\scrcpy-win64-v4.1\adb.exe')) -or
                             (Test-Path -LiteralPath (Join-Path $script:root 'tools\scrcpy\scrcpy-win64-v3.1\adb.exe')) -or
                             (Test-Path -LiteralPath (Join-Path $script:root 'tools\scrcpy\scrcpy-win64-v2.7\adb.exe')) -or
                             (Test-Path -LiteralPath (Join-Path $script:root 'tools\adb.exe')) -or
                             (Get-Command 'adb' -ErrorAction SilentlyContinue) -or
                             (Test-Path -LiteralPath 'D:\LDPlayer\LDPlayer14\adb.exe' -ErrorAction SilentlyContinue) -or
                             (Test-Path -LiteralPath 'D:\LDPlayer\LDPlayer9\adb.exe' -ErrorAction SilentlyContinue) -or
                             (Test-Path -LiteralPath 'C:\LDPlayer\LDPlayer14\adb.exe' -ErrorAction SilentlyContinue)
                $hasYtdlp  = (Test-Path -LiteralPath (Join-Path $script:root 'tools\yt-dlp.exe')) -or
                             (Test-Path -LiteralPath (Join-Path $script:root 'tools\yt-dlp\yt-dlp.exe')) -or
                             (Get-Command 'yt-dlp' -ErrorAction SilentlyContinue)
                $hasFfmpeg = (Test-Path -LiteralPath (Join-Path $script:root 'tools\ffmpeg\ffmpeg.exe')) -or
                             (Test-Path -LiteralPath (Join-Path $script:root 'tools\ffmpeg\bin\ffmpeg.exe')) -or
                             (Test-Path -LiteralPath (Join-Path $script:root 'tools\ffmpeg.exe')) -or
                             (Get-Command 'ffmpeg' -ErrorAction SilentlyContinue)
                $hasFfprobe = (Test-Path -LiteralPath (Join-Path $script:root 'tools\ffmpeg\ffprobe.exe')) -or
                              (Test-Path -LiteralPath (Join-Path $script:root 'tools\ffmpeg\bin\ffprobe.exe')) -or
                              (Test-Path -LiteralPath (Join-Path $script:root 'tools\ffprobe.exe')) -or
                              (Get-Command 'ffprobe' -ErrorAction SilentlyContinue)
                $allReady = $hasScrcpy -and $hasAdb -and $hasYtdlp -and $hasFfmpeg -and $hasFfprobe
                if ($allReady) {
                    Show-Toast 'Công cụ xử lý video đã sẵn sàng.' -Kind success
                    Add-Log "Các công cụ xử lý video đã sẵn sàng; trạng thái Whisper tiny xem ở Cài đặt › Công cụ." 'Success'
                } else {
                    Show-Toast 'Đã cập nhật trạng thái công cụ; vẫn còn công cụ chưa có.' -Kind warning
                    Add-Log "Kiểm tra hoàn tất: xem trạng thái từng công cụ ở Cài đặt › Công cụ." 'Info'
                }
                Update-ActionBar
                return
            }
            if ($laCheck) {
                Update-ToolsStatus
                Update-HeaderChipsFromCheck -Text $txt
                if ($txt -match 'SAN SANG') {
                    if ($ui.TxtStat) {
                        $ui.TxtStat.Text = 'Máy đã sẵn sàng'
                        $ui.TxtStat.Foreground = (Get-Brush 'SuccessText')
                    }
                } else {
                    if ($ui.TxtStat) {
                        $ui.TxtStat.Text = 'Máy chưa sẵn sàng · xem chip Thiết bị/Công cụ'
                        $ui.TxtStat.Foreground = (Get-Brush 'DangerText')
                    }
                }
                Update-ActionBar
                return
            }
            if ($script:queue.Count -eq 0) { return }
            Complete-QueueItem -Log $txt
        }
}

$timer.Add_Tick({
    $wasStopping = [bool]$script:stopping
    try { Invoke-EngineTick }
    catch {
        $tickError = $_
        try { Invoke-EngineTickError -ErrorRecord $tickError -WasStopping $wasStopping }
        catch { Write-FileLog "ERR  Invoke-EngineTickError: $($_.Exception.Message)`r`n$($_.ScriptStackTrace)" -Immediate }
    }
})

# Dong bo thanh tua va lop phu theo vi tri phat video.
$tPlay = New-Object Windows.Threading.DispatcherTimer
$tPlay.Interval = [TimeSpan]::FromMilliseconds(33)
$tPlay.Add_Tick({
    try {
        if (Get-Command 'Poll-GifSelectionWorker' -ErrorAction SilentlyContinue) { Poll-GifSelectionWorker }
        # Nap "khong tu phat" nhung MediaOpened chua toi (khung xem truoc dang an): khong de video chay ngam toi cuoi.
        if ($script:pauseOnOpen -and $ui.Player.Source -and $ui.Player.Position.TotalSeconds -gt 0.3) {
            $script:pauseOnOpen = $false
            try { $ui.Player.Pause(); $ui.Player.Position = [TimeSpan]::Zero } catch { Write-FileLog "WARN pause-on-open guard: $($_.Exception.Message)" }
            $ui.Player.IsMuted = $false
            $ui.BtnPlay.Content = 'Phát'
        }
        if ($ui.Player.Source -and $ui.Player.NaturalDuration.HasTimeSpan) {
            $tot = $ui.Player.NaturalDuration.TimeSpan.TotalSeconds
            $cur = $ui.Player.Position.TotalSeconds
            if ($tot -gt 0) {
                if ($ui.Seek.Maximum -ne $tot) { $ui.Seek.Maximum = $tot }
                $nowTicks = [System.Diagnostics.Stopwatch]::GetTimestamp()
                $isSeeking = ($script:keoSeek -or $ui.Seek.IsMouseCaptureWithin -or ($nowTicks -lt $script:suppressSeekSyncUntil))
                if (-not $isSeeking) {
                    $ui.Seek.Value = $cur
                    $ui.TxtTime.Text = (Format-VideoTime $cur) + " / " + (Format-VideoTime $tot)
                }
                if ($ui.CmbLogoMode -and $ui.CmbLogoMode.SelectedIndex -eq 0 -and ($ui.BtnPlay.Content -match 'Tạm dừng')) {
                    Update-WatermarkOverlay
                }
                # Final exports already contain the GIF. Do not decode an invisible second copy.
                if ($script:gifPlayer -and $script:gifPlayer.IsLoaded -and $ui.ChkGif -and $ui.ChkGif.IsChecked -and
                    $ui.ImgVideoGif -and $ui.ImgVideoGif.IsVisible -and $win.WindowState -ne 'Minimized') {
                    $script:gifPlayer.SeekToSeconds($cur)
                }
            }
        }
        if ($script:gifPlayer -is [WpfGifPlaybackWorker]) {
            if ($script:gifPlayer.PollFrame()) {
                $firstFrame = -not $ui.ImgVideoGif.Source
                if ($ui.ImgGifPreview) { $ui.ImgGifPreview.Source = $script:gifPlayer.BitmapSource }
                if ($ui.ImgVideoGif) { $ui.ImgVideoGif.Source = $script:gifPlayer.BitmapSource }
                if ($firstFrame) { Update-WatermarkOverlay }
            } elseif ($script:gifPlayer.LoadError -and -not $script:gifPlaybackErrorReported) {
                $script:gifPlaybackErrorReported = $true
                Add-Log ('Lỗi phát GIF: ' + $script:gifPlayer.LoadError) 'Danger'
                Show-Toast 'Không phát được GIF. Chọn lại file; chi tiết trong Cài đặt › Nhật ký.' -Kind error
            }
        }
    } catch { Write-FileLogLimited 'timer-gif' "WARN timer phat GIF: $($_.Exception.Message)" }
})
$tPlay.Start()

# ------------------------------------------------------------------- nut & tabs ----
# Custom Window Chrome Buttons
$ui.BtnWinMin.Add_Click({ $win.WindowState = [System.Windows.WindowState]::Minimized })
$ui.BtnWinMax.Add_Click({
    if ($win.WindowState -eq [System.Windows.WindowState]::Maximized) {
        $win.WindowState = [System.Windows.WindowState]::Normal
    } else {
        $win.WindowState = [System.Windows.WindowState]::Maximized
    }
})
function Update-MaxButtonGlyph {
    # Dong bo ca khi phong to bang double-click thanh tieu de hoac Win+mui ten / snap. Glyph Segoe Fluent/MDL2.
    if (-not $ui.BtnWinMax) { return }
    $max = ($win.WindowState -eq [System.Windows.WindowState]::Maximized)
    $ui.BtnWinMax.Content = [string][char]$(if ($max) { 0xE923 } else { 0xE922 })
    $ui.BtnWinMax.ToolTip = if ($max) { 'Khôi phục' } else { 'Phóng to' }
    [Windows.Automation.AutomationProperties]::SetName($ui.BtnWinMax, [string]$ui.BtnWinMax.ToolTip)
}
$win.Add_StateChanged({ Update-MaxButtonGlyph })
$ui.BtnWinClose.Add_Click({ $win.Close() })

# ------------------------------------------------------------- dieu huong sidebar + tab phu ----
$navCheckedHandler = [System.Windows.RoutedEventHandler]{
    param($sender, $e)
    if ($script:switchingPage) { return }
    foreach ($k in $script:pageNavs.Keys) {
        if ([object]::ReferenceEquals($ui[$script:pageNavs[$k]], $sender)) { Show-Page $k; return }
    }
}
foreach ($navName in $script:pageNavs.Values) { $ui[$navName].Add_Checked($navCheckedHandler) }

$settingsTabHandler = [System.Windows.RoutedEventHandler]{
    param($sender, $e)
    if ($script:switchingPage) { return }
    $name = switch ($sender.Name) { 'SetTabGeneral' { 'general' } 'SetTabLogs' { 'logs' } 'SetTabUpdate' { 'update' } 'SetTabAbout' { 'about' } default { 'tools' } }
    Show-SettingsSection $name
    if ($name -eq 'tools') { Update-ToolsStatus }
}
foreach ($tabName in @('SetTabTools', 'SetTabGeneral', 'SetTabLogs', 'SetTabUpdate', 'SetTabAbout')) { $ui[$tabName].Add_Checked($settingsTabHandler) }

function Show-LibrarySection {
    param([ValidateSet('videos', 'rejected')][string]$Name)
    $videos = ($Name -eq 'videos')
    $ui.PanelLibVideos.Visibility = $(if ($videos) { 'Visible' } else { 'Collapsed' })
    $ui.PanelLibFilters.Visibility = $(if ($videos) { 'Visible' } else { 'Collapsed' })
    $ui.PanelLibRejected.Visibility = $(if ($videos) { 'Collapsed' } else { 'Visible' })
    if (-not $videos) { Update-RejectedDashboard }
}
$ui.TabLibVideos.Add_Checked({ Show-LibrarySection 'videos' })
$ui.TabLibRejected.Add_Checked({ Show-LibrarySection 'rejected' })

# Chip tieu de: thiet bi -> kiem tra may; cong cu -> Cai dat > Cong cu.
$ui.ChipDevice.Add_Click({
    if ($script:ps -or (Test-QueueRunning)) { Show-Toast 'Đang chạy tác vụ; kiểm tra máy sau khi xong.' -Kind warning; return }
    Show-Toast 'Đang kiểm tra máy…'
    Invoke-DeviceCheck
})
$ui.ChipTools.Add_Click({ Show-Page 'settings' -Sub 'tools' })

# ------------------------------------------------------------- bo loc kho ----
$ui.CmbDateFilter.Add_SelectionChanged({
    if ($script:updatingCombo) { return }
    $idx = $ui.CmbDateFilter.SelectedIndex
    $ui.CmbFilterSpecificDate.Visibility = $(if ($idx -eq 4) { 'Visible' } else { 'Collapsed' })
    $script:filterDate = switch ($idx) {
        1 { 'today' } 2 { 'yesterday' } 3 { '7days' }
        4 { if ($ui.CmbFilterSpecificDate.SelectedItem) { [string]$ui.CmbFilterSpecificDate.SelectedItem.Tag } else { 'all' } }
        default { 'all' }
    }
    if ($idx -eq 4 -and -not $ui.CmbFilterSpecificDate.SelectedItem -and $ui.CmbFilterSpecificDate.Items.Count) { $ui.CmbFilterSpecificDate.IsDropDownOpen = $true }
    Apply-GalleryFilter
})
$ui.CmbFilterSpecificDate.Add_SelectionChanged({
    if ($script:updatingCombo) { return }
    $sel = $ui.CmbFilterSpecificDate.SelectedItem
    if ($sel -and $ui.CmbDateFilter.SelectedIndex -eq 4) { $script:filterDate = [string]$sel.Tag; Apply-GalleryFilter }
})
$ui.CmbKho.Add_SelectionChanged({
    if ($script:updatingCombo) { return }
    $sel = $ui.CmbKho.SelectedItem
    if (-not $sel) { return }
    $script:filterKho = [string]$sel.Tag
    Apply-GalleryFilter
    Reset-GalleryScroll
})
$ui.TabStAll.Add_Checked({ $script:filterStatus = 'all'; Apply-GalleryFilter; Reset-GalleryScroll })
$ui.TabStPending.Add_Checked({ $script:filterStatus = 'pending'; Apply-GalleryFilter; Reset-GalleryScroll })
$ui.TabStHeld.Add_Checked({ $script:filterStatus = 'held'; Apply-GalleryFilter; Reset-GalleryScroll })
$ui.TabStPosted.Add_Checked({ $script:filterStatus = 'posted'; Apply-GalleryFilter; Reset-GalleryScroll })
# Mũi tên trái/phải đổi tab trạng thái.
$ui.PanelStatusTabs.Add_PreviewKeyDown({
    param($sender, $e)
    $dir = switch ($e.Key) { 'Left' { -1 } 'Right' { 1 } default { 0 } }
    if (-not $dir) { return }
    $tabs = @($ui.TabStAll, $ui.TabStPending, $ui.TabStHeld, $ui.TabStPosted)
    $cur = 0; for ($i = 0; $i -lt $tabs.Count; $i++) { if ($tabs[$i].IsChecked) { $cur = $i } }
    $next = ($cur + $dir + $tabs.Count) % $tabs.Count
    $tabs[$next].IsChecked = $true; [void]$tabs[$next].Focus()
    $e.Handled = $true
})
$ui.BtnKhoManage.Add_Click({ Show-KhoManagerDialog -Kho $script:filterKho })
$ui.BtnKhoEmptyImport.Add_Click({ Show-KhoManagerDialog -Kho $script:filterKho -StartImport })
$ui.BtnKhoEmptyManage.Add_Click({ Show-KhoManagerDialog -Kho $script:filterKho })
$ui.BtnClearSelection.Add_Click({ Clear-GallerySelection })
$ui.BtnMoveSelected.Add_Click({
    $picked = @($ui.GalleryList.SelectedItems)
    if ($picked.Count) { Show-KhoMoveMenu -Target $ui.BtnMoveSelected -Items $picked -Placement ([Windows.Controls.Primitives.PlacementMode]::Top) }
})
$ui.BtnSpreadStop.Add_Click({ Stop-SpreadBackground })
$ui.BtnSpreadSelected.Add_Click({
    $picked = @($ui.GalleryList.SelectedItems)
    if ($picked.Count) { Show-TikTokSpreadDialog -Items $picked }
})
$ui.CmbDownloadKho.Add_SelectionChanged({
    if ($script:updatingCombo) { return }
    $sel = $ui.CmbDownloadKho.SelectedItem
    if (-not $sel) { return }
    try { Set-KhoDownloadTarget ([string]$sel.Tag); Sync-OutDirFromKho }
    catch {
        Add-Log "Không lưu được kho tải về: $($_.Exception.Message)" 'Danger'
        Show-Toast ('Không lưu được kho tải về: ' + (Get-FriendlyError $_.Exception.Message)) -Kind error
    }
})
# Moi 60 giay (chi khi dang o trang Kho): video "Da hen" da qua gio hen chuyen sang "Da dang". Chi doc bo nho.
$tGalleryHeld = New-Object Windows.Threading.DispatcherTimer
$tGalleryHeld.Interval = [TimeSpan]::FromSeconds(60)
$tGalleryHeld.Add_Tick({ try { Update-GalleryHeldExpired } catch { Write-FileLog "WARN Update-GalleryHeldExpired: $($_.Exception.Message)" } })
$tGalleryHeld.Start()
$tGallerySearch = New-Object Windows.Threading.DispatcherTimer
$tGallerySearch.Interval = [TimeSpan]::FromMilliseconds(250)
$tGallerySearch.Add_Tick({
    $tGallerySearch.Stop()
    $script:filterSearch = ([string]$ui.TxtGallerySearch.Text).Trim()
    Apply-GalleryFilter
})
$ui.TxtGallerySearch.Add_TextChanged({
    $ui.TxtGallerySearchHint.Visibility = $(if ([string]::IsNullOrEmpty($ui.TxtGallerySearch.Text)) { 'Visible' } else { 'Collapsed' })
    $tGallerySearch.Stop(); $tGallerySearch.Start()
})
$ui.BtnRefreshGallery.Add_Click({ $script:probeCache = @{}; Update-Gallery })

# Nut tren dong bang: mot handler cho moi danh sach (ao hoa), doc Tag + DataContext cua nut.
$ui.GalleryList.AddHandler([Windows.Controls.Primitives.ButtonBase]::ClickEvent, [System.Windows.RoutedEventHandler]{ param($sender, $e) Invoke-GalleryRowAction $e })
$ui.GalleryList.Add_MouseDoubleClick({
    param($sender, $e)
    $item = $ui.GalleryList.SelectedItem
    # Nhap dup the Kho: xem + che do "Xem lon".
    if ($item -and $item.Path -and -not ($e.OriginalSource -is [Windows.Controls.Button])) {
        if (Invoke-GalleryView -FilePath $item.Path -Controls $ui) { Set-PreviewBig $true }
    }
})
# Nguoi dung chon mot the: nap vao khung xem truoc o 0:00, khong tu phat. Khong bao gio tu chon khi vao Kho.
# D12: thả file video từ Explorer lên trang Kho = chép vào kho đang chọn.
foreach ($dropTarget in @($ui.PanelLibVideos, $ui.GalleryList)) { if ($dropTarget) { $dropTarget.AllowDrop = $true } }
$ui.PanelLibVideos.Add_DragOver({ param($s, $e) $e.Effects = $(if ($e.Data.GetDataPresent([Windows.DataFormats]::FileDrop)) { [Windows.DragDropEffects]::Copy } else { [Windows.DragDropEffects]::None }); $e.Handled = $true })
$ui.PanelLibVideos.Add_Drop({
    param($s, $e)
    $e.Handled = $true
    try { if ($e.Data.GetDataPresent([Windows.DataFormats]::FileDrop)) { Invoke-KhoDrop -Files @($e.Data.GetData([Windows.DataFormats]::FileDrop)) } }
    catch { Write-FileLog "ERR  Thả video vào kho: $($_.Exception.Message)`r`n$($_.ScriptStackTrace)"; Show-Toast ('Không thêm được video: ' + (Get-FriendlyError $_.Exception.Message)) -Kind error }
})
# D11: kéo một khung trên vùng trống để chọn nhiều thẻ (Ctrl giữ lựa chọn cũ).
$ui.GalleryList.Add_PreviewMouseLeftButtonDown({ param($s, $e) try { Start-GalleryBand $e.OriginalSource $e } catch { Write-FileLog "WARN Khung kéo (nhấn): $($_.Exception.Message)" } })
$ui.GalleryList.Add_PreviewMouseMove({ param($s, $e) try { Move-GalleryBand $e } catch { Write-FileLog "WARN Khung kéo (di chuyển): $($_.Exception.Message)"; Stop-GalleryBand } })
$ui.GalleryList.Add_PreviewMouseLeftButtonUp({ param($s, $e) try { $wasActive = [bool]($script:band -and $script:band.Active); Stop-GalleryBand; if ($wasActive) { $e.Handled = $true } } catch { Write-FileLog "WARN Khung kéo (nhả): $($_.Exception.Message)" } })
$ui.GalleryList.Add_LostMouseCapture({ param($s, $e) if ($script:band -and $script:band.Active -and $script:band.Captured -and -not $ui.GalleryList.IsMouseCaptured) { Stop-GalleryBand } })
$ui.GalleryList.Add_SelectionChanged({
    Update-MoveSelectedButton
    if ($script:gallerySyncing) { return }
    if ($ui.GalleryList.SelectedItems.Count -ne 1) { return }   # chon nhieu the: khong tai khung xem truoc
    $item = $ui.GalleryList.SelectedItem
    if (-not $item -or -not $item.Path -or $item.Path -eq $script:lastOut) { return }
    if (Test-GalleryActionsBusy) { return }
    [void](Invoke-GalleryView -FilePath $item.Path -Controls $ui -NoAutoPlay)
})
$ui.BtnGalleryRetry.Add_Click({
    # G-R9: worker chet / loi doc kho -> tao lai worker va quet lai.
    Stop-MediaWorker
    $script:probeCache = @{}
    Update-Gallery
})
$ui.RejectedList.AddHandler([Windows.Controls.Primitives.ButtonBase]::ClickEvent, [System.Windows.RoutedEventHandler]{
    param($sender, $e)
    $btn = $e.OriginalSource
    if ($btn -is [Windows.Controls.Button] -and $btn.Tag) { $e.Handled = $true; Invoke-UnrejectReel -VideoId ([string]$btn.Tag) }
})
$ui.QueueList.AddHandler([Windows.Controls.Primitives.ButtonBase]::ClickEvent, [System.Windows.RoutedEventHandler]{ param($sender, $e) Invoke-QueueRowAction $e })
$ui.QueueList.Add_SelectionChanged({ Update-StepPanel })
$ui.QueueList.ItemsSource = $script:queueRows
$ui.StepList.ItemsSource = $script:stepRows
# Luoi 3-4 cot: KidWrapPanel (ao hoa) thay StackPanel mac dinh cua ListView; so cot tu dong theo be rong.
$wrapFactory = New-Object Windows.FrameworkElementFactory([KidWrapPanel])
$wrapFactory.SetValue([KidWrapPanel]::ItemWidthProperty, 208.0)
$wrapFactory.SetValue([KidWrapPanel]::ItemHeightProperty, 396.0)
$ui.GalleryList.ItemsPanel = New-Object Windows.Controls.ItemsPanelTemplate($wrapFactory)
$ui.GalleryList.ItemsSource = $script:galleryRows
$ui.RejectedList.ItemsSource = $script:rejectedRows
# ------------------------------------------------------------- cac nut cai dat thu vien ----
$ui.BtnInstallAllTools.Add_Click({ Install-ToolGUI 'all' })
$ui.BtnInstallScrcpy.Add_Click({   Install-ToolGUI 'scrcpy' })
$ui.BtnInstallAdb.Add_Click({      Install-ToolGUI 'adb' })
$ui.BtnInstallYtdlp.Add_Click({    Install-ToolGUI 'ytdlp' })
$ui.BtnInstallFfmpeg.Add_Click({   Install-ToolGUI 'ffmpeg' })
$ui.BtnInstallWhisper.Add_Click({  Install-ToolGUI 'whisper' })
$ui.BtnCheckTools.Add_Click({      Update-ToolsStatus })
$ui.BtnAutotokInstall.Add_Click({  Start-AutotokInstall })
$ui.BtnAutotokChrome.Add_Click({   Start-Process 'https://www.google.com/chrome/' })
$ui.BtnChromeGuide.Add_Click({ Open-ChromeGuide })
$ui.BtnChromeFolder.Add_Click({ Open-ChromeExtensionFolder })
$ui.BtnChromePair.Add_Click({ $ui.BtnChromePair.IsEnabled = $false; Add-ChromeOp 'pair-code' @{ op = 'pair-code' } })
$ui.BtnOpenUninstall.Add_Click({
    if (Test-AppBusy) { Show-Toast 'Đang chạy tác vụ hoặc hàng đợi — không thể gỡ thư viện lúc này.' -Kind warning; return }
    $confirmed = Show-ConfirmDialog -Title 'Gỡ thư viện công cụ?' -ConfirmText 'Gỡ thư viện' -Danger -Message (
        "Xóa vĩnh viễn toàn bộ thư mục:`r`n$(Join-Path $root 'tools')`r`n`r`n" +
        "Bao gồm ADB, scrcpy, FFmpeg/ffprobe, yt-dlp và model Whisper đã tải.`r`n" +
        "Sau khi gỡ, ứng dụng không tải hoặc xử lý video được cho tới khi cài lại (cần mạng).`r`n" +
        "Video đã xuất và lịch sử trong output/data không bị xóa.")
    if (-not $confirmed) { return }
    try {
        $rootFull = [System.IO.Path]::GetFullPath($root).TrimEnd([System.IO.Path]::DirectorySeparatorChar, [System.IO.Path]::AltDirectorySeparatorChar)
        $tDir = [System.IO.Path]::GetFullPath((Join-Path $rootFull 'tools'))
        if (-not [string]::Equals([System.IO.Path]::GetDirectoryName($tDir).TrimEnd([System.IO.Path]::DirectorySeparatorChar, [System.IO.Path]::AltDirectorySeparatorChar), $rootFull, [System.StringComparison]::OrdinalIgnoreCase) -or
            -not [string]::Equals([System.IO.Path]::GetFileName($tDir), 'tools', [System.StringComparison]::OrdinalIgnoreCase)) {
            throw 'Đường dẫn thư mục tools không nằm trực tiếp trong thư mục dự án.'
        }
        if (Test-Path -LiteralPath $tDir) { Remove-Item -LiteralPath $tDir -Recurse -Force -ErrorAction Stop }
        if (Test-Path -LiteralPath $tDir) { throw 'Một số tệp vẫn còn hoặc đang bị khóa.' }
        Update-ToolsStatus
        Show-Toast 'Đã gỡ thư viện công cụ.' -Kind success
        Add-Log 'Đã gỡ bỏ thư viện trong thư mục tools.' 'Success'
    } catch {
        Show-Toast "Gỡ thư viện thất bại: $(Get-FriendlyError $_.Exception.Message)" -Kind error
        Add-Log "Gỡ thư viện thất bại: $($_.Exception.Message)" 'Danger'
    }
})

$ui.BtnCopyLog.Add_Click({
    try {
        Flush-LogBatch
        $txt = if ($ui.TxtLog -and $ui.TxtLog.Text) { $ui.TxtLog.Text } else { $script:runLog.ToString() }
        if (-not $txt -or -not $txt.Trim()) {
            Show-Toast 'Chưa có nhật ký nào để sao chép.' -Kind warning
            return
        }
        [System.Windows.Clipboard]::SetText($txt)
        Show-Toast 'Đã sao chép toàn bộ nhật ký vào clipboard.' -Kind success
    } catch {
        Show-Toast "Không sao chép được nhật ký: $(Get-FriendlyError $_.Exception.Message)" -Kind error
    }
})
$ui.BtnClearLog.Add_Click({
    Clear-LogBatch
    if ($ui.TxtLog) { $ui.TxtLog.Clear() }
    [void]$script:runLog.Clear()
    Show-Toast 'Đã xóa nhật ký đang hiển thị; file log vẫn được giữ.'
})
$ui.BtnOpenLogFolder.Add_Click({ Flush-FileLog; Open-FolderSafe $script:logDir })

# ------------------------------------------------------------- Cai dat > Tuy chon: luu tru .cache (G-C2) ----
function Format-Bytes {
    # So kieu vi-VN: "0,5 MB"; duoi 0,1 MB -> KB nguyen ("25 KB"); duoi 1 KB -> "N B".
    param([double]$Bytes)
    $vi = [Globalization.CultureInfo]::GetCultureInfo('vi-VN')
    if ($Bytes -ge 1GB) { return ($Bytes / 1GB).ToString('0.0', $vi) + ' GB' }
    if ($Bytes -ge 0.1 * 1MB) { return ($Bytes / 1MB).ToString('0.0', $vi) + ' MB' }
    if ($Bytes -ge 1KB) { return ($Bytes / 1KB).ToString('0', $vi) + ' KB' }
    return ([double]$Bytes).ToString('0', $vi) + ' B'
}

function Get-LegacyIntermediateFiles {
    # File -1/-2 cua ban cu con nam o GOC mot thu muc kho (khong tu xoa/di chuyen; chi liet ke).
    param([string]$OutDir)
    if ([string]::IsNullOrWhiteSpace($OutDir) -or -not [System.IO.Directory]::Exists($OutDir)) { return @() }
    $di = [System.IO.DirectoryInfo]::new($OutDir)
    return @($di.GetFiles() | Where-Object { $_.Name -match '-1-video-goc\.mp4$' -or $_.Name -match '-2-am-thanh-tho\.m4a$' })
}

function Get-CacheScope {
    # Pham vi don cache / file cu / Don o: kho dang chon o trang Kho (mot kho) hoac tat ca kho. Luon noi ro pham vi trong chu hien cho nguoi dung.
    # Tra ve @{ Roots = @(thu muc kho); Label; Single }.
    $libs = @((Get-KhoRegistry).libraries)
    if ($script:filterKho -and [string]$script:filterKho -ne 'all') {
        $one = @($libs | Where-Object { [string]$_.id -ceq [string]$script:filterKho })
        if ($one.Count) { return @{ Roots = @([string]$one[0].path); Label = "kho '$($one[0].name)'"; Single = $true } }
    }
    $label = $(if ($libs.Count -eq 1) { "kho '$($libs[0].name)'" } else { "tất cả $($libs.Count) kho" })
    return @{ Roots = @($libs | ForEach-Object { [string]$_.path }); Label = $label; Single = $false }
}

function Get-KhoJournalPaths {
    # Duong dan day du cua MOI file ma mot nhat ky chuyen kho dang ton tai nhac toi (nguon va dich). Don dep khong bao gio dung toi chung.
    # Tra ve $null khi co nhat ky khong doc duoc: khi do moi thao tac don dep phai tu choi.
    $set = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    foreach ($e in @(Read-KhoJournals)) {
        if (-not $e.Journal) { return $null }
        foreach ($r in @($e.Journal.renames)) {
            foreach ($p in @($r.src, $r.dst)) { if ($p) { [void]$set.Add([IO.Path]::GetFullPath([string]$p)) } }
        }
    }
    return , $set
}

function Get-CacheSummary {
    # Tong hop .cache (tru tiktok-posts va file ma nhat ky chuyen kho nhac toi), file -1/-2 cu o goc va .thumbs cu cua cac thu muc kho trong $Roots.
    param([string[]]$Roots)
    $r = [pscustomobject]@{ CacheDirs = @(); CacheExists = $false; CacheFiles = 0; CacheBytes = [double]0; ReeditCount = 0
                            LegacyFiles = @(); LegacyBytes = [double]0; LegacyThumbs = @() }
    $roots = @(@($Roots) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    if (-not $roots.Count) { return $r }
    $protected = Get-KhoJournalPaths
    $dirs = New-Object System.Collections.Generic.List[string]; $legacy = New-Object System.Collections.Generic.List[object]; $thumbs = New-Object System.Collections.Generic.List[string]
    foreach ($khoRoot in $roots) {
        $cacheDir = Get-ReelCacheDir $khoRoot
        if ([System.IO.Directory]::Exists($cacheDir)) {
            $r.CacheExists = $true; $dirs.Add($cacheDir)
            $posts = (Join-Path $cacheDir 'tiktok-posts') + '\'
            foreach ($f in [System.IO.DirectoryInfo]::new($cacheDir).GetFiles('*', [System.IO.SearchOption]::AllDirectories)) {
                if ($f.FullName.StartsWith($posts, [StringComparison]::OrdinalIgnoreCase)) { continue }
                if ($protected -and $protected.Contains($f.FullName)) { continue }
                $r.CacheFiles++; $r.CacheBytes += $f.Length
                if ($f.Name -match '-1-video-goc\.mp4$' -and $f.DirectoryName -eq $cacheDir) { $r.ReeditCount++ }
            }
        }
        foreach ($f in @(Get-LegacyIntermediateFiles $khoRoot)) { $legacy.Add($f); $r.LegacyBytes += $f.Length }
        $oldThumbs = Join-Path $khoRoot '.thumbs'
        if ([System.IO.Directory]::Exists($oldThumbs)) { $thumbs.Add($oldThumbs) }
    }
    $r.CacheDirs = $dirs.ToArray(); $r.LegacyFiles = $legacy.ToArray(); $r.LegacyThumbs = $thumbs.ToArray()
    return $r
}

function Update-CacheInfo {
    if (-not $ui.TxtCacheInfo) { return }
    try {
        $scope = Get-CacheScope
        $s = Get-CacheSummary $scope.Roots
        $head = "Phạm vi: $($scope.Label) (đổi bằng ô chọn kho ở trang Kho)"
        $cacheText = if ($s.CacheExists) { ".cache: $($s.CacheFiles) file · $(Format-Bytes $s.CacheBytes) · sửa lại được $($s.ReeditCount) video" } else { '.cache: chưa có (video mới sẽ cất file gốc vào đây)' }
        $legacyText = if ($s.LegacyFiles.Count) { "File trung gian cũ ở thư mục kho: $($s.LegacyFiles.Count) file · $(Format-Bytes $s.LegacyBytes)" } else { 'Không có file trung gian cũ ở thư mục kho.' }
        $ui.TxtCacheInfo.Text = $head + "`n" + $cacheText + "`n" + $legacyText
        if ($ui.BtnCleanLegacy) { $ui.BtnCleanLegacy.IsEnabled = [bool]($s.LegacyFiles.Count -or $s.LegacyThumbs.Count) }
        if ($ui.BtnClearCache) { $ui.BtnClearCache.IsEnabled = ($s.CacheFiles -gt 0) }
    } catch {
        $ui.TxtCacheInfo.Text = 'Không đọc được dung lượng .cache: ' + $_.Exception.Message
        Write-FileLog "WARN Update-CacheInfo: $($_.Exception.Message)"
    }
}

function Test-CacheActionBlocked {
    # Don dep (cache, file cu, Don o) tu choi khi ung dung dang ban, dang chuyen kho, hoac mot nhat ky chuyen kho dang do con giu cac thu muc nay.
    param([string[]]$Roots = @())
    if (Test-AppBusy) { Show-Toast 'Đang xử lý — hãy đợi hàng đợi hoặc tác vụ hoàn tất rồi dọn.' -Kind warning; return $true }
    if ($script:khoMoveRunning -or $script:khoExclusive -gt 0) { Show-Toast 'Đang chuyển kho hoặc mở hộp thoại đăng/dọn dẹp — thử lại sau.' -Kind warning; return $true }
    $block = Get-KhoJournalBlock @($Roots)
    if ($block) { Show-Toast $block -Kind warning; return $true }
    return $false
}

function Release-PlayerFromCache {
    # Player dang mo file trong .cache (am thanh tach / video goc sach) -> dong truoc khi di chuyen/xoa.
    param([string]$CacheDir)
    try {
        if ($ui.Player -and $ui.Player.Source -and $ui.Player.Source.IsFile) {
            $src = [IO.Path]::GetFullPath($ui.Player.Source.LocalPath)
            $cacheRoot = [IO.Path]::GetFullPath($CacheDir).TrimEnd('\') + '\'
            if ($src.StartsWith($cacheRoot, [StringComparison]::OrdinalIgnoreCase)) { Clear-Player }
        }
    } catch { Write-FileLog "WARN Release-PlayerFromCache: $($_.Exception.Message)" }
}

function Invoke-CleanLegacyFiles {
    # Quyet dinh 2: dem file -1/-2 cu o goc cac kho trong pham vi; hop thoai 2 lua chon (mac dinh: chuyen vao .cache cua CHINH kho do), Huy la nut mac dinh.
    $scope = Get-CacheScope
    if (Test-CacheActionBlocked $scope.Roots) { return }
    $s = Get-CacheSummary $scope.Roots
    if (-not $s.LegacyFiles.Count -and -not $s.LegacyThumbs.Count) { Show-Toast "Không có file trung gian cũ nào ở $($scope.Label)." -Kind info; Update-CacheInfo; return }
    $msg = "Phạm vi: $($scope.Label)`r`nCó $($s.LegacyFiles.Count) file trung gian cũ (-1 video gốc, -2 âm thanh) · $(Format-Bytes $s.LegacyBytes) ở gốc thư mục kho." +
        $(if ($s.LegacyThumbs.Count) { "`r`n`r`nThư mục .thumbs cũ (ảnh thu nhỏ, tự tạo lại) cũng sẽ được dọn." } else { '' }) +
        "`r`n`r`nChọn cách dọn:"
    $choice = Show-ChoiceDialog -Title 'Dọn file trung gian cũ?' -Message $msg -ConfirmText 'Dọn' -Kind info `
        -Choices @('Chuyển vào .cache (vẫn sửa lại được)', 'Xóa vĩnh viễn (không sửa lại logo/GIF được nữa)') -Default 0
    if ($choice -lt 0) { return }
    # Tu luc xac nhan toi luc ket thuc khong co chuyen kho / hop thoai khac chen vao.
    if (Test-CacheActionBlocked $scope.Roots) { return }
    $script:khoExclusive++
    try {
        foreach ($cd in @($s.LegacyFiles | ForEach-Object { Get-ReelCacheDir ([string]$_.DirectoryName) } | Select-Object -Unique)) { Release-PlayerFromCache $cd }
        $moved = 0; $deleted = 0; $skipped = 0; $failed = 0; $freed = [double]0
        foreach ($f in $s.LegacyFiles) {
            try {
                if ($choice -eq 0) {
                    $cacheDir = Get-ReelCacheDir ([string]$f.DirectoryName)
                    Initialize-KhoCacheDir $cacheDir
                    $dest = Join-Path $cacheDir $f.Name
                    # Khong ghi de ban trong .cache (co the la ban moi hon do engine tao).
                    if ([System.IO.File]::Exists($dest)) { $skipped++; Add-Log "Giữ nguyên $($f.Name): .cache đã có file cùng tên." 'Warning'; continue }
                    [System.IO.File]::Move($f.FullName, $dest)
                    $moved++
                } else {
                    $len = $f.Length
                    [System.IO.File]::Delete($f.FullName)
                    $deleted++; $freed += $len
                }
            } catch {
                $failed++
                Add-Log "Không dọn được $($f.Name): $($_.Exception.Message)" 'Danger'
            }
        }
        foreach ($t in @($s.LegacyThumbs)) {
            try { Remove-Item -LiteralPath $t -Recurse -Force -ErrorAction Stop }
            catch { $failed++; Add-Log "Không xóa được thư mục .thumbs cũ '$t': $($_.Exception.Message)" 'Warning' }
        }
        $summary = if ($choice -eq 0) { "Đã chuyển $moved file vào .cache" } else { "Đã xóa $deleted file · giải phóng $(Format-Bytes $freed)" }
        if ($skipped) { $summary += " · giữ nguyên $skipped file trùng tên" }
        if ($failed) { $summary += " · $failed mục lỗi (xem Nhật ký)" }
        Add-Log $summary $(if ($failed) { 'Warning' } else { 'Success' })
        Show-Toast ($summary + '.') -Kind $(if ($failed) { 'warning' } else { 'success' })
    } finally { $script:khoExclusive-- }
    Update-CacheInfo
    Update-Gallery
}

function Clear-KhoCacheDir {
    # Xoa moi file trong <kho>\.cache TRU tiktok-posts (bien nhan = lich su ben vung) va file ma nhat ky chuyen kho dang do nhac toi,
    # roi thu muc rong. Tiep tuc khi mot file loi. Tra ve @{ Deleted; Kept; Errors }.
    param([string]$CacheDir, $Protected)
    $r = @{ Deleted = 0; Kept = 0; Errors = New-Object System.Collections.Generic.List[string] }
    if (-not [System.IO.Directory]::Exists($CacheDir)) { return $r }
    $posts = (Join-Path $CacheDir 'tiktok-posts') + '\'
    foreach ($f in [System.IO.DirectoryInfo]::new($CacheDir).GetFiles('*', [System.IO.SearchOption]::AllDirectories)) {
        if ($f.FullName.StartsWith($posts, [StringComparison]::OrdinalIgnoreCase)) { continue }
        if ($Protected -and $Protected.Contains($f.FullName)) { $r.Kept++; continue }
        try { [System.IO.File]::Delete($f.FullName); $r.Deleted++ }
        catch { $r.Errors.Add("$($f.Name): $($_.Exception.Message)"); Write-FileLog "WARN Dọn cache không xóa được '$($f.FullName)': $($_.Exception.Message)" }
    }
    foreach ($d in @([System.IO.DirectoryInfo]::new($CacheDir).GetDirectories('*', [System.IO.SearchOption]::AllDirectories) | Sort-Object { $_.FullName.Length } -Descending)) {
        if (($d.FullName + '\').StartsWith($posts, [StringComparison]::OrdinalIgnoreCase)) { continue }
        try { if (-not $d.GetFileSystemInfos().Count) { [System.IO.Directory]::Delete($d.FullName) } }
        catch { Write-FileLog "WARN Dọn cache không xóa được thư mục '$($d.FullName)': $($_.Exception.Message)" }
    }
    try { if (-not [System.IO.DirectoryInfo]::new($CacheDir).GetFileSystemInfos().Count) { [System.IO.Directory]::Delete($CacheDir) } }
    catch { Write-FileLog "WARN Dọn cache không xóa được '$CacheDir': $($_.Exception.Message)" }
    return $r
}

function Invoke-ClearReeditCache {
    # Xoa .cache cua cac kho trong pham vi sau xac nhan; noi ro se mat kha nang sua lai logo/GIF cho video cu.
    $scope = Get-CacheScope
    if (Test-CacheActionBlocked $scope.Roots) { return }
    $s = Get-CacheSummary $scope.Roots
    if (-not $s.CacheExists) { Show-Toast "Chưa có thư mục .cache nào ở $($scope.Label)." -Kind info; Update-CacheInfo; return }
    foreach ($cd in $s.CacheDirs) {
        $full = [IO.Path]::GetFullPath($cd).TrimEnd('\')
        $okShape = ([IO.Path]::GetFileName($full) -ceq $script:reelCacheName) -and (@($scope.Roots | Where-Object { Test-SamePath ([IO.Path]::GetDirectoryName($full)) $_ }).Count -eq 1)
        if (-not $okShape) { Show-Toast 'Đường dẫn .cache không hợp lệ; không xóa.' -Kind error; return }
    }
    $ok = Show-ConfirmDialog -Title 'Dọn cache sửa lại?' -Danger -Exclusive -ConfirmText 'Dọn cache' -Message (
        "Xóa vĩnh viễn cache sửa lại của $($scope.Label):`r`n$(($s.CacheDirs) -join "`r`n")`r`n`r`n$($s.CacheFiles) file · $(Format-Bytes $s.CacheBytes)" +
        " (video gốc -1, âm thanh -2 và ảnh thu nhỏ).`r`n`r`nSau khi xóa, $($s.ReeditCount) video cũ sẽ KHÔNG sửa lại logo/GIF được nữa; " +
        "muốn sửa phải tải và ghi âm lại. Video hoàn chỉnh (-3) và biên nhận đăng TikTok được giữ nguyên.")
    if (-not $ok) { return }
    if (Test-CacheActionBlocked $scope.Roots) { return }
    foreach ($cd in $s.CacheDirs) { if (-not [System.IO.Directory]::Exists($cd)) { Show-Toast 'Thư mục .cache đã thay đổi trong lúc xác nhận; chưa dọn gì. Thử lại.' -Kind warning; Update-CacheInfo; return } }
    $protected = Get-KhoJournalPaths
    if ($null -eq $protected) { Show-Toast 'Có nhật ký chuyển kho không đọc được; chưa dọn gì.' -Kind warning; return }
    $script:khoExclusive++
    try {
        $deleted = 0; $errors = New-Object System.Collections.Generic.List[string]
        foreach ($cd in $s.CacheDirs) {
            Release-PlayerFromCache $cd
            $one = Clear-KhoCacheDir -CacheDir $cd -Protected $protected
            $deleted += $one.Deleted
            foreach ($e in $one.Errors) { $errors.Add($e) }
        }
        $script:probeCache = @{}; $script:thumbCache = @{}
        if ($errors.Count) {
            Add-Log "Không xóa hết .cache ($($errors.Count) lỗi): $($errors[0])" 'Danger'
            Show-Toast "Đã xóa $deleted file nhưng $($errors.Count) file chưa xóa được: $(Get-FriendlyError $errors[0])" -Kind error
        } else {
            Add-Log "Đã dọn cache sửa lại của $($scope.Label) ($deleted file · $(Format-Bytes $s.CacheBytes))." 'Success'
            Show-Toast "Đã dọn .cache · giải phóng $(Format-Bytes $s.CacheBytes)." -Kind success
        }
    } finally { $script:khoExclusive-- }
    if ($script:lastOut -and $ui.BtnReedit) { $ui.BtnReedit.IsEnabled = (-not $script:uiBusy -and (Test-ReeditInputs $script:lastOut)) }
    Update-CacheInfo
    Update-Gallery
}

function ConvertFrom-ManualPostedDate {
    # Ngay danh dau thu cong co dang "dd/MM HH:mm" (khong co nam): lay nam hien tai, neu ra tuong lai thi lui 1 nam. $null neu khong doc duoc.
    param([string]$Text, [DateTime]$Now)
    if ([string]::IsNullOrWhiteSpace($Text)) { return $null }
    $m = [regex]::Match($Text.Trim(), '^(\d{1,2})/(\d{1,2})(?:\s+(\d{1,2}):(\d{2}))?')
    if (-not $m.Success) { return $null }
    $hh = if ($m.Groups[3].Success) { [int]$m.Groups[3].Value } else { 0 }
    $mm = if ($m.Groups[4].Success) { [int]$m.Groups[4].Value } else { 0 }
    foreach ($year in @($Now.Year, ($Now.Year - 1))) {
        try {
            $d = [DateTime]::new($year, [int]$m.Groups[2].Value, [int]$m.Groups[1].Value, $hh, $mm, 0, [DateTimeKind]::Local)
            if ($d -le $Now) { return $d }
        } catch { continue }
    }
    return $null
}

function Get-KhoCleanupCandidates {
    # Don o: video co bai dang xac nhan MOI NHAT (hoac ngay danh dau thu cong) cu hon $Days ngay VA con file trung gian -1/-2
    # (.cache hoac file cu o goc cua CHINH kho chua video). Chi doc dia de xem file nao con. Khong bao gio tra -3.
    # $MetaByRoot: thu muc kho -> reup-status.json. Gio dang = tiktok_schedule_time neu co, khong thi accepted_at; muc succeeded khong ro gio => bo video.
    param($Items, $MetaByRoot, [int]$Days, [DateTime]$Now, [string]$KhoId = 'all')
    $cutoff = $Now.AddDays(-$Days)
    $result = New-Object System.Collections.Generic.List[object]
    foreach ($it in @($Items)) {
        if ($null -eq $it -or -not [string]$it.Id) { continue }
        if ($KhoId -and $KhoId -ne 'all' -and [string]$it.Kho -cne $KhoId) { continue }
        $id = [string]$it.Id
        $metadata = $(if ($MetaByRoot) { $MetaByRoot[[string]$it.Root] } else { $null })
        $entry = if ($metadata -and $metadata.PSObject.Properties[$id]) { $metadata.$id } else { $null }
        if ($null -eq $entry) { continue }
        $times = New-Object System.Collections.Generic.List[DateTime]
        $unknown = $false
        foreach ($h in @($entry.History)) {
            if ($null -eq $h -or [string]$h.status -ne 'succeeded' -or $h.publish_uncertain -eq $true) { continue }
            $raw = if ([string]$h.tiktok_schedule_time) { [string]$h.tiktok_schedule_time } else { [string]$h.accepted_at }
            $t = ConvertTo-TikTokLocalTime $raw
            if ($null -eq $t) { $unknown = $true } else { $times.Add($t) }
        }
        $manual = Get-ReupManualState $entry
        if ($manual.Posted) {
            $t = ConvertFrom-ManualPostedDate -Text ([string]$manual.Date) -Now $Now
            if ($null -eq $t) { $unknown = $true } else { $times.Add($t) }
        }
        if ($unknown -or $times.Count -eq 0) { continue }
        $newest = ($times | Sort-Object -Descending | Select-Object -First 1)
        if ($newest -gt $cutoff) { continue }
        $files = @(Get-ReelMediaFiles -VideoPath ([string]$it.Path) -Existing | Where-Object { $_.Kind -ne 'final' } |
            ForEach-Object { [pscustomobject]@{ Path = $_.Path; Leaf = $_.Leaf; Length = [double][IO.FileInfo]::new($_.Path).Length } })
        if (-not $files.Count) { continue }
        $bytes = [double]0; foreach ($f in $files) { $bytes += $f.Length }
        $result.Add([pscustomobject]@{ Id = $id; Path = [string]$it.Path; Kho = [string]$it.Kho; Root = [string]$it.Root; PostedAt = $newest; Files = $files; Bytes = $bytes })
    }
    return $result.ToArray()
}

function Remove-KhoCleanupFiles {
    # Xoa -1/-2 cua cac ung vien. Bo qua video dang co luot chuyen TikTok chay va file ma nhat ky chuyen kho dang do nhac toi. Tiep tuc khi mot file loi.
    # Chi xoa dung file ten -1-video-goc.mp4 / -2-am-thanh-tho.m4a; -3, anh thu nho, .kidfby-publish-* khong bao gio bi cham.
    param($Candidates, $Protected = $null)
    $r = @{ Deleted = 0; Failed = 0; Skipped = 0; Freed = [double]0; Errors = New-Object System.Collections.Generic.List[string] }
    foreach ($c in @($Candidates)) {
        if (Test-TikTokTransferActive -FilePath ([string]$c.Path)) { $r.Skipped++; Write-FileLog "Dọn ổ: bỏ qua $($c.Id) vì đang chuyển TikTok."; continue }
        foreach ($f in @($c.Files)) {
            if ($f.Leaf -notmatch '^.+-(1-video-goc\.mp4|2-am-thanh-tho\.m4a)$') { $r.Failed++; $r.Errors.Add("$($f.Leaf): không phải file trung gian"); continue }
            if ($Protected -and $Protected.Contains([IO.Path]::GetFullPath([string]$f.Path))) { $r.Skipped++; Write-FileLog "Dọn ổ: giữ '$($f.Path)' vì một nhật ký chuyển kho đang nhắc tới."; continue }
            try {
                Remove-Item -LiteralPath $f.Path -Force -ErrorAction Stop
                $r.Deleted++; $r.Freed += $f.Length
            } catch {
                $r.Failed++; $r.Errors.Add("$($f.Leaf): $($_.Exception.Message)")
                Write-FileLog "WARN Dọn ổ không xóa được '$($f.Path)': $($_.Exception.Message)"
            }
        }
    }
    return $r
}

function Invoke-KhoCleanup {
    $days = 0
    if (-not [int]::TryParse(([string]$ui.TxtCleanupDays.Text).Trim(), [ref]$days) -or $days -lt 7 -or $days -gt 365) {
        Show-Toast 'Số ngày phải từ 7 đến 365.' -Kind warning; return
    }
    $scopeId = 'all'; $scopeText = 'tất cả kho'
    if ($script:filterKho -and $script:filterKho -ne 'all') {
        $khoName = if ($script:khoNames -and $script:khoNames.ContainsKey($script:filterKho)) { [string]$script:khoNames[$script:filterKho] } else { [string]$script:filterKho }
        $pick = Show-ChoiceDialog -Title 'Dọn ổ: phạm vi' -Kind info -ConfirmText 'Tiếp tục' -Choices @("Chỉ kho đang chọn ($khoName)", 'Tất cả kho') -Default 0 `
            -Message "Chọn phạm vi tìm video đã đăng hơn $days ngày."
        if ($pick -lt 0) { return }
        if ($pick -eq 0) { $scopeId = [string]$script:filterKho; $scopeText = "kho '$khoName'" }
    }
    $scopeRoots = @($(if ($scopeId -eq 'all') { Get-KhoRoots } else { (Get-KhoById $scopeId).path }))
    if (Test-CacheActionBlocked $scopeRoots) { return }
    $metaByRoot = Get-GalleryMetaByRoot
    $cands = @(Get-KhoCleanupCandidates -Items @($script:galleryAll) -MetaByRoot $metaByRoot -Days $days -Now (Get-Date) -KhoId $scopeId)
    $cands = @($cands | Where-Object { -not (Test-TikTokTransferActive -FilePath ([string]$_.Path)) })
    if (-not $cands.Count) { Show-Toast "Không có video nào đã đăng hơn $days ngày còn file trung gian ($scopeText)." -Kind info; return }
    $total = [double]0; foreach ($c in $cands) { $total += $c.Bytes }
    $ok = Show-ConfirmDialog -Title 'Dọn ổ?' -Danger -Exclusive -ConfirmText 'Xóa file trung gian' -Message (
        "Xóa file trung gian (để ghi âm lại) của $($cands.Count) video đã đăng hơn $days ngày ($scopeText), giải phóng $(Format-Bytes $total). " +
        "Video hoàn chỉnh (-3) được giữ nguyên. Sau khi xóa sẽ không ghi âm lại/sửa lại được các video này.")
    if (-not $ok) { return }
    if (Test-CacheActionBlocked $scopeRoots) { return }
    if (@($cands | Where-Object { -not [System.IO.File]::Exists([string]$_.Path) }).Count) { Show-Toast 'Có video đã được chuyển hoặc xóa trong lúc xác nhận; chưa dọn gì. Thử lại.' -Kind warning; return }
    $protected = Get-KhoJournalPaths
    if ($null -eq $protected) { Show-Toast 'Có nhật ký chuyển kho không đọc được; chưa dọn gì.' -Kind warning; return }
    $script:khoExclusive++
    try {
        foreach ($khoRoot in @($cands | ForEach-Object { $_.Root } | Select-Object -Unique)) { Release-PlayerFromCache (Get-ReelCacheDir $khoRoot) }
        $r = Remove-KhoCleanupFiles -Candidates $cands -Protected $protected
        $summary = "Dọn ổ: đã xóa $($r.Deleted) file · giải phóng $(Format-Bytes $r.Freed) · lỗi $($r.Failed)"
        if ($r.Skipped) { $summary += " · bỏ qua $($r.Skipped) mục đang chuyển TikTok hoặc chuyển kho dở dang" }
        Add-Log $summary $(if ($r.Failed) { 'Warning' } else { 'Success' })
        foreach ($e in $r.Errors) { Add-Log "Dọn ổ lỗi: $e" 'Warning' }
        Show-Toast ($summary + '.') -Kind $(if ($r.Failed) { 'warning' } else { 'success' })
    } finally { $script:khoExclusive-- }
    Update-CacheInfo
    Update-Gallery
}

$ui.BtnCleanLegacy.Add_Click({ Invoke-CleanLegacyFiles })
$ui.BtnCleanupOld.Add_Click({ Invoke-KhoCleanup })
$ui.BtnClearCache.Add_Click({ Invoke-ClearReeditCache })

function Get-RejectedLinkMatches {
    # Link trong danh sach trung lich su loai (theo ID hoac URL da ghi). Dung chung cho canh bao va nut Bat dau.
    param([string[]]$Links, $Rejected)
    # URL so sanh sau chuan hoa (ConvertTo-FacebookNormalizedUrl) neu ham co; ID luon uu tien.
    $canNormalize = [bool](Get-Command ConvertTo-FacebookNormalizedUrl -ErrorAction SilentlyContinue)
    $norm = { param($u) if ($canNormalize) { try { [string](ConvertTo-FacebookNormalizedUrl $u) } catch { [string]$u } } else { [string]$u } }
    $ids = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
    $urls = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
    foreach ($r in @($Rejected)) {
        if ($r.VideoId) { [void]$ids.Add([string]$r.VideoId) }
        foreach ($u in @($r.Urls)) { if ($u) { [void]$urls.Add([string]$u); [void]$urls.Add((& $norm $u)) } }
    }
    return @($Links | Where-Object {
        $id = Get-FacebookVideoId -Url $_
        ($id -and $ids.Contains([string]$id)) -or $urls.Contains([string]$_) -or $urls.Contains((& $norm $_))
    })
}

function Get-LinkSummary {
    # Mot nguon duy nhat cho the Tom tat (trang Nguon) va nut Bat dau.
    param([string]$Text, [string[]]$OutDir, [bool]$SkipExisting = $true)
    $raw = @()
    if (Get-Command Get-FacebookInputLinks -CommandType Function -ErrorAction SilentlyContinue) { $raw = @(Get-FacebookInputLinks -Text $Text -KeepDuplicates) }
    else { $raw = @($Text -split "`r?`n" | ForEach-Object { $_.Trim() } | Where-Object { $_ }) }
    $report = $null
    if (Get-Command Get-FacebookLinkDuplicateReport -ErrorAction SilentlyContinue) { $report = Get-FacebookLinkDuplicateReport -Text $Text -OutDir $OutDir }
    $unique = if ($report) { @($report.Links) } else { @($raw | Select-Object -Unique) }
    $rejected = @(Get-RejectedReels -Root $script:root)
    $blocked = @(Get-RejectedLinkMatches -Links $unique -Rejected $rejected)
    $blockedIds = @($blocked | ForEach-Object { Get-FacebookVideoId -Url $_ } | Where-Object { $_ })
    $downloaded = @(if ($report) { @($report.DownloadedIds) | Where-Object { $blockedIds -notcontains $_ } })
    $runnable = @($unique | Where-Object { $blocked -cnotcontains $_ })
    if ($SkipExisting -and $downloaded.Count) { $runnable = @($runnable | Where-Object { $downloaded -notcontains (Get-FacebookVideoId -Url $_) }) }
    return [pscustomobject]@{
        Raw = $raw.Count; Unique = $unique.Count; Duplicates = [Math]::Max(0, $raw.Count - $unique.Count)
        DuplicateIds = @(if ($report) { @($report.DuplicateIds) }); Blocked = @($blocked); Downloaded = @($downloaded)
        Links = @($unique); Runnable = @($runnable)
    }
}

function Update-LinkDuplicateWarning {
    if (-not $ui.TxtLinkSummary) { return }
    $text = [string]$ui.TxtLinks.Text
    if ($ui.TxtLinksPlaceholder) { $ui.TxtLinksPlaceholder.Visibility = $(if ([string]::IsNullOrEmpty($text)) { 'Visible' } else { 'Collapsed' }) }
    try {
        $s = Get-LinkSummary -Text $text -OutDir @(Get-KhoRoots) -SkipExisting ([bool]$ui.RbDupSkip.IsChecked)
        $script:linkSummary = $s
        # 4 sticker so to: Link · Trung · Da loai truoc · Se chay
        if ($ui.TxtSumLinks) { $ui.TxtSumLinks.Text = [string]$s.Raw }
        if ($ui.TxtSumDup) { $ui.TxtSumDup.Text = [string]$s.Duplicates }
        if ($ui.TxtSumRejected) { $ui.TxtSumRejected.Text = [string]$s.Blocked.Count }
        if ($ui.TxtSumRun) { $ui.TxtSumRun.Text = [string]$s.Runnable.Count }
        if ($s.Raw -eq 0) {
            $ui.TxtLinkSummary.Text = 'Chưa có link nào'
            $ui.TxtLinkSummary.Foreground = Get-Brush 'TextMuted'
        } else {
            $ui.TxtLinkSummary.Text = "$($s.Raw) link · $($s.Duplicates) trùng · $($s.Blocked.Count) đã loại trước · $($s.Downloaded.Count) đã có trong kho · $($s.Runnable.Count) sẽ chạy"
            $ui.TxtLinkSummary.Foreground = Get-Brush 'TextPrimary'
        }
        $details = @()
        if ($s.Duplicates) { $details += ('Lặp trong danh sách (chỉ chạy một lần): ' + ((@($s.DuplicateIds | Select-Object -First 3) | ForEach-Object { "#$_" }) -join ', ') + $(if (@($s.DuplicateIds).Count -gt 3) { '…' } else { '' })) }
        if ($s.Blocked.Count) { $details += "$($s.Blocked.Count) link đã bị loại trước đây sẽ tự bỏ qua (bỏ loại ở Kho › Lịch sử đã loại)." }
        if ($s.Downloaded.Count) { $details += ('Đã có trong kho: ' + ((@($s.Downloaded | Select-Object -First 3) | ForEach-Object { "#$_" }) -join ', ') + $(if ($s.Downloaded.Count -gt 3) { '…' } else { '' })) }
        # Mot dong gon (so lieu da co o 4 sticker); chi tiet day du o tooltip.
        $ui.TxtDuplicateWarning.Text = $(if ($details.Count -gt 1) { "$($details[-1]) (+$($details.Count - 1) ghi chú)" } elseif ($details.Count) { [string]$details[0] } else { '' })
        $ui.TxtDuplicateWarning.ToolTip = $(if ($details.Count) { $details -join "`n" } else { $null })
        $ui.TxtDuplicateWarning.Visibility = $(if ($details.Count) { 'Visible' } else { 'Collapsed' })
        $ui.PanelDupChoice.Visibility = $(if ($s.Downloaded.Count) { 'Visible' } else { 'Collapsed' })
    } catch {
        $ui.TxtLinkSummary.Text = 'Không kiểm tra được danh sách link. Kiểm tra lại các thư mục kho và lịch sử loại.'
        $ui.TxtLinkSummary.Foreground = Get-Brush 'WarningText'
        Write-FileLog "WARN Update-LinkDuplicateWarning: $($_.Exception.Message)"
    }
}

# Debounce 400 ms: dem link, trung lap va lich su loai chi tinh khi nguoi dung ngung go; Bat dau tinh lai dong bo.
$tLinkWarning = New-Object Windows.Threading.DispatcherTimer
$tLinkWarning.Interval = [TimeSpan]::FromMilliseconds(400)
$tLinkWarning.Add_Tick({
    $tLinkWarning.Stop()
    try { Update-LinkDuplicateWarning } catch { Add-Log "Không kiểm tra được danh sách link: $($_.Exception.Message)" 'Warning' }
})
$ui.TxtLinks.Add_TextChanged({
    if ($ui.TxtLinksPlaceholder) { $ui.TxtLinksPlaceholder.Visibility = $(if ([string]::IsNullOrEmpty($ui.TxtLinks.Text)) { 'Visible' } else { 'Collapsed' }) }
    $tLinkWarning.Stop(); $tLinkWarning.Start()
})
$ui.RbDupSkip.Add_Checked({ Update-LinkDuplicateWarning })
$ui.RbDupRedownload.Add_Checked({ Update-LinkDuplicateWarning })

function Add-LinksText {
    # Them link vao cuoi o (giu hoan tac Ctrl+Z cua TextBox).
    param([string]$Text)
    if ([string]::IsNullOrWhiteSpace($Text)) { return 0 }
    $current = [string]$ui.TxtLinks.Text
    $prefix = if ($current.Length -and -not $current.EndsWith("`n")) { "`r`n" } else { '' }
    $ui.TxtLinks.CaretIndex = $current.Length
    $ui.TxtLinks.SelectedText = $prefix + $Text.Trim()
    $ui.TxtLinks.CaretIndex = $ui.TxtLinks.Text.Length
    return @($Text -split "`r?`n" | Where-Object { $_.Trim() }).Count
}
$ui.BtnPasteLinks.Add_Click({
    $clip = ''
    try { $clip = [System.Windows.Clipboard]::GetText() } catch { Write-FileLog "WARN Clipboard.GetText: $($_.Exception.Message)" }
    if ([string]::IsNullOrWhiteSpace($clip)) { Show-Toast 'Clipboard không có văn bản để dán.' -Kind warning; return }
    $n = Add-LinksText $clip
    Show-Toast "Đã dán $n dòng." -Kind success
})
$ui.BtnImportLinks.Add_Click({
    $dialog = New-Object Microsoft.Win32.OpenFileDialog
    $dialog.Filter = 'Văn bản (*.txt)|*.txt|Tất cả file (*.*)|*.*'
    $dialog.CheckFileExists = $true
    if ($dialog.ShowDialog($win) -ne $true) { return }
    try {
        $content = [System.IO.File]::ReadAllText($dialog.FileName, [System.Text.Encoding]::UTF8)
        $n = Add-LinksText $content
        Show-Toast "Đã nhập $n dòng từ $([IO.Path]::GetFileName($dialog.FileName))." -Kind success
    } catch {
        Show-Toast "Không đọc được file: $(Get-FriendlyError $_.Exception.Message)" -Kind error
    }
})
$ui.BtnClearLinks.Add_Click({
    if ([string]::IsNullOrEmpty($ui.TxtLinks.Text)) { return }
    [void]$ui.TxtLinks.Focus()
    $ui.TxtLinks.SelectAll()
    $ui.TxtLinks.SelectedText = ''
    Show-Toast 'Đã xóa danh sách link (Ctrl+Z để hoàn tác).'
})

function Update-ResponsiveLayout {
    # Cot xem truoc theo chieu cao than (xem Update-PreviewColumn); chieu cao logic < 640 -> bo cuc gon (Set-CompactLayout).
    # Chip trang thai an khi qua hep.
    if ($ui.HeaderBadges) { $ui.HeaderBadges.Visibility = if ($win.ActualWidth -gt 0 -and $win.ActualWidth -lt 900) { 'Collapsed' } else { 'Visible' } }
    $rootH = $(if ($ui.RootGrid -and $ui.RootGrid.ActualHeight -gt 0) { [double]$ui.RootGrid.ActualHeight } else { 0.0 })
    $compact = ($rootH -gt 0.0 -and $rootH -lt 640.0)
    if ($compact -ne $script:compactLayout) { Set-CompactLayout $compact }
    Update-PreviewColumn
    Update-BarDensity
}

function Update-BarDensity {
    # Dai day hep (cua so < 1100 logic): nhan pill dem gon (chi so, tooltip da co nhan).
    $narrow = [bool]($ui.RootGrid -and $ui.RootGrid.ActualWidth -gt 0 -and $ui.RootGrid.ActualWidth -lt 1100)
    if ($narrow -ne $script:narrowBar) { $script:narrowBar = $narrow; Update-ActionBar }
}
function Update-DisplayBounds {
    param([switch]$Initial)
    if ($script:adjustingDisplayBounds -or $win.WindowState -ne 'Normal') { return }
    $handle = ([Windows.Interop.WindowInteropHelper]::new($win)).Handle
    if ($handle -eq [IntPtr]::Zero) { return }
    $script:adjustingDisplayBounds = $true
    try {
        [KidDisplaySupport]::Fit($handle, [bool]$Initial)
        $work = [KidDisplaySupport]::WorkArea($handle, $false)
        $scale = [KidDisplaySupport]::Dpi($handle) / 96.0
        # Toi thieu 1200x720 logic; man hinh nho hon (vd 1366x768 o 150%) thi theo vung lam viec.
        $win.MinWidth = [Math]::Min(1200.0, $work[2] / $scale)
        $win.MinHeight = [Math]::Min(720.0, $work[3] / $scale)
        Update-ResponsiveLayout
    } catch {
        if (Get-Command Add-Log -ErrorAction SilentlyContinue) { Add-Log ('Không điều chỉnh được màn hình: ' + $_.Exception.Message) 'Warning' }
    } finally { $script:adjustingDisplayBounds = $false }
}
$win.Add_SourceInitialized({ Update-DisplayBounds -Initial })
$win.Add_LocationChanged({ Update-DisplayBounds })
$win.Add_StateChanged({ Update-DisplayBounds })
$win.Add_SizeChanged({ Update-ResponsiveLayout })
if ($win.PSObject.Methods.Name -contains 'Add_DpiChanged') {
    $win.Add_DpiChanged({
        # Let WPF apply the new DPI before constraining logical dimensions.
        [void]$win.Dispatcher.BeginInvoke([action]{ Update-DisplayBounds; Update-PhoneFrameSize }, [Windows.Threading.DispatcherPriority]::Loaded)
    })
}

function Update-PhoneFrameSize {
    # Khung video = vung ViewportGrid tru 8 px (vien 2+2, bong 4); ty le that cua video (mac dinh 9:16).
    # Khung giu cung kich thuoc khi rong va khi co video 9:16 (khong "nhay").
    if (-not $ui.ViewportGrid -or -not $ui.PhoneFrame) { return }
    $availH = $ui.ViewportGrid.ActualHeight
    $availW = $ui.ViewportGrid.ActualWidth
    if ($availH -lt 40 -or $availW -lt 40) { return }

    $aspectRatio = 9.0 / 16.0
    if ($ui.Player -and $ui.Player.NaturalVideoWidth -gt 0 -and $ui.Player.NaturalVideoHeight -gt 0) {
        $aspectRatio = [double]$ui.Player.NaturalVideoWidth / [double]$ui.Player.NaturalVideoHeight
    }

    $chrome = 8.0
    $targetH = [Math]::Max(40.0, $availH - $chrome)
    $targetW = [Math]::Round($targetH * $aspectRatio)
    if ($targetW -gt ($availW - $chrome)) {
        $targetW = [Math]::Max(40.0, $availW - $chrome)
        $targetH = [Math]::Round($targetW / $aspectRatio)
    }

    if ($ui.TxtNoVid) {
        $compactPlaceholder = $targetW -lt 180 -or $targetH -lt 300
        if ($ui.ImgNoVid) { $ui.ImgNoVid.Width = $(if ($compactPlaceholder) { 48.0 } else { 64.0 }); $ui.ImgNoVid.Height = $(if ($compactPlaceholder) { 38.0 } else { 50.0 }) }
        if ($ui.TxtNoVidTitle) { $ui.TxtNoVidTitle.FontSize = $(if ($compactPlaceholder) { 14.0 } else { 15.0 }) }
        if ($ui.TxtNoVidText) { $ui.TxtNoVidText.Visibility = $(if ($compactPlaceholder) { 'Collapsed' } else { 'Visible' }) }
    }
    # Chip do phan giai: day du khi video du rong, gon ("Full HD") khi hep (kich thuoc o tooltip) de khong dung nut Xem lon.
    if ($ui.TxtRes -and $script:resFullText) {
        $short = ([string]$script:resFullText -split ' · ')[0]
        $ui.TxtRes.Text = $(if ($targetW -lt 240) { $short } else { $script:resFullText })
        $ui.BadgeRes.ToolTip = $script:resFullText
    }
    # Thanh dieu khien phu: thoi gian chi hien khi video du rong.
    if ($ui.TxtTime) { $ui.TxtTime.Visibility = $(if ($targetW -lt 250) { 'Collapsed' } else { 'Visible' }) }
    # Hang nut duoi video theo be rong cot: hep -> nut Sao chep chi con bieu tuong, nhan an gon.
    $paneW = $(if ($ui.PreviewPane -and $ui.PreviewPane.ActualWidth -gt 0) { $ui.PreviewPane.ActualWidth } else { $availW })
    # >= 470: bieu tuong + "Sao chep de dang"; 400-470: chi chu; < 400: chi bieu tuong (tooltip co ten day du).
    if ($ui.TxtCopyLabel) { $ui.TxtCopyLabel.Visibility = $(if ($paneW -lt 400) { 'Collapsed' } else { 'Visible' }) }
    if ($ui.BtnCopyReup) {
        $iconOnly = ($paneW -lt 400)
        $ui.BtnCopyReup.HorizontalAlignment = $(if ($iconOnly) { [Windows.HorizontalAlignment]::Left } else { [Windows.HorizontalAlignment]::Stretch })
        $ui.BtnCopyReup.MinWidth = $(if ($iconOnly) { 52.0 } else { 0.0 })
    }
    if ($ui.TxtCopyIcon) {
        $ui.TxtCopyIcon.Visibility = $(if ($paneW -ge 470 -or $paneW -lt 400) { 'Visible' } else { 'Collapsed' })
        $ui.TxtCopyIcon.Margin = [Windows.Thickness]::new(0, 0, $(if ($paneW -lt 400) { 0.0 } else { 8.0 }), 0)
    }
    if ($ui.BtnTrackA) {
        $ui.BtnTrackA.Content = $(if ($paneW -lt 470) { 'Âm thanh' } else { 'Âm thanh tách' })
        $ui.BtnTrackA.FontSize = $(if ($paneW -lt 340) { 13.0 } else { 14.0 })
        $ui.BtnTrackB.FontSize = $(if ($paneW -lt 340) { 13.0 } else { 14.0 })
        $pad = $(if ($paneW -lt 340) { 9.0 } else { 12.0 })
        $ui.BtnTrackA.Padding = [Windows.Thickness]::new($pad, 0, $pad, 0)
        $ui.BtnTrackB.Padding = [Windows.Thickness]::new($pad, 0, $pad, 0)
    }
    if ([Math]::Abs($ui.PhoneFrame.Height - $targetH) -gt 1.5 -or [Math]::Abs($ui.PhoneFrame.Width - $targetW) -gt 1.5) {
        $ui.PhoneFrame.Height = $targetH
        $ui.PhoneFrame.Width  = $targetW
        if ($ui.CanvasWatermark) {
            $ui.CanvasWatermark.Width  = $targetW
            $ui.CanvasWatermark.Height = $targetH
        }
        # Bo goc 18 px (khung 20 - vien 2) cho video; ClipToBounds chi cat hinh chu nhat.
        if ($ui.PlayerContainer) { $ui.PlayerContainer.Clip = [Windows.Media.RectangleGeometry]::new([Windows.Rect]::new(0, 0, $targetW, $targetH), 18.0, 18.0) }
        if (Get-Command 'Update-WatermarkOverlay' -ErrorAction SilentlyContinue) { Update-WatermarkOverlay }
    }
}
function Enter-CleanPreviewMode {
    if ($script:previewingClean) { return }
    if (-not $script:lastOut -or -not (Test-Path -LiteralPath $script:lastOut)) { return }
    if ($script:lastOut -notmatch '-3-hoan-chinh\.mp4$') { return }
    # Video goc sach (-1) nam trong .cache (dot 4); file cu o goc van dung duoc.
    $cleanPath = Get-ReelCompanionPath -VideoPath $script:lastOut -Kind source
    if (-not $cleanPath) { return }

    try {
        $curPos = if ($ui.Player -and $ui.Player.Source) { $ui.Player.Position } else { [TimeSpan]::Zero }
        $wasPlaying = ($ui.BtnPlay -and $ui.BtnPlay.Content -match 'Tạm dừng')
        $script:previewingClean = $true
        try { $ui.Player.Stop() } catch { <# bo qua: don dep khi huy/dong, loi o day khong anh huong ket qua #> }
        try { $ui.Player.Close() } catch { <# bo qua: don dep khi huy/dong, loi o day khong anh huong ket qua #> }
        $ui.Player.Source = New-Object Uri([System.IO.Path]::GetFullPath($cleanPath))
        if ($wasPlaying) {
            if ($curPos.TotalSeconds -gt 0) { $ui.Player.Position = $curPos }
            $ui.Player.Play()
            $ui.BtnPlay.Content = 'Tạm dừng'
        } else {
            # Tam dung: mo + dung o dung vi tri cu de van thay khung hinh (Manual khong ve hinh neu chua Play).
            $script:pauseOnOpen = $true; $script:pauseOnOpenPos = $curPos; $ui.Player.IsMuted = $true
            $ui.Player.Play()
        }

if ($ui.BadgePreviewMode) { $ui.TxtPreviewMode.Text = 'Đang chỉnh vị trí · video gốc sạch (bấm để quay lại)'; $ui.BadgePreviewMode.Visibility = 'Visible' }
        if (Get-Command 'Update-WatermarkOverlay' -ErrorAction SilentlyContinue) { Update-WatermarkOverlay }
    } catch { Write-FileLog "WARN Enter-CleanPreviewMode: $($_.Exception.Message)" }
}

function Exit-CleanPreviewMode {
    if (-not $script:previewingClean) { return }
    if (-not $script:lastOut -or -not (Test-Path -LiteralPath $script:lastOut)) { return }
    try {
        $curPos = if ($ui.Player -and $ui.Player.Source) { $ui.Player.Position } else { [TimeSpan]::Zero }
        $wasPlaying = ($ui.BtnPlay -and $ui.BtnPlay.Content -match 'Tạm dừng')
        $script:previewingClean = $false
        try { $ui.Player.Stop() } catch { <# bo qua: don dep khi huy/dong, loi o day khong anh huong ket qua #> }
        try { $ui.Player.Close() } catch { <# bo qua: don dep khi huy/dong, loi o day khong anh huong ket qua #> }
        $ui.Player.Source = New-Object Uri([System.IO.Path]::GetFullPath($script:lastOut))
        if ($wasPlaying) {
            if ($curPos.TotalSeconds -gt 0) { $ui.Player.Position = $curPos }
            $ui.Player.Play()
            $ui.BtnPlay.Content = 'Tạm dừng'
        } else {
            $script:pauseOnOpen = $true; $script:pauseOnOpenPos = $curPos; $ui.Player.IsMuted = $true
            $ui.Player.Play()
        }

if ($ui.BadgePreviewMode) { $ui.BadgePreviewMode.Visibility = 'Collapsed' }
        if (Get-Command 'Update-WatermarkOverlay' -ErrorAction SilentlyContinue) { Update-WatermarkOverlay }
    } catch { Write-FileLog "WARN Exit-CleanPreviewMode: $($_.Exception.Message)" }
}

function Update-WatermarkSummary {
    $logoOn = ($ui.ChkWatermark -and $ui.ChkWatermark.IsChecked)
    $gifHasFile = ($ui.TxtGifPath -and -not [string]::IsNullOrWhiteSpace($ui.TxtGifPath.Text))
    $gifChecked = ($ui.ChkGif -and $ui.ChkGif.IsChecked)
    $gifOn = ($gifChecked -and $gifHasFile)
    $logoSize = if ($ui.SldLogoSize) { [int][Math]::Round($ui.SldLogoSize.Value) } else { 30 }
    $gifSize  = if ($ui.SldGifSize)  { [int][Math]::Round($ui.SldGifSize.Value) }  else { 20 }
    $logoHasCustomSize = ($script:logoCustomWidth -gt 0.0 -and $script:logoCustomHeight -gt 0.0)
    if ($ui.TxtLogoSize) { $ui.TxtLogoSize.Text = if ($logoHasCustomSize) { 'Rộng {0}% · Cao {1}%' -f [int][Math]::Round($script:logoCustomWidth * 100.0), [int][Math]::Round($script:logoCustomHeight * 100.0) } else { '{0}%' -f $logoSize } }
    $logoTxt = if ($logoOn -and $logoHasCustomSize) { 'Logo: rộng {0}% · cao {1}%' -f [int][Math]::Round($script:logoCustomWidth * 100.0), [int][Math]::Round($script:logoCustomHeight * 100.0) } elseif ($logoOn) { "Logo: $logoSize%" } else { "Logo: T" + [char]0x1EAF + "t" }
    $gifHasCustomSize = ($script:gifCustomWidth -gt 0.0 -and $script:gifCustomHeight -gt 0.0)
    if ($ui.TxtGifSize) {
        $ui.TxtGifSize.Text = if ($script:gifFullFrame) { 'Phủ khung' } elseif ($gifHasCustomSize) { 'Rộng {0}% · Cao {1}%' -f [int][Math]::Round($script:gifCustomWidth * 100.0), [int][Math]::Round($script:gifCustomHeight * 100.0) } else { '{0}%' -f $gifSize }
    }
    $gifTxt = if ($gifOn -and $script:gifFullFrame) { 'GIF: Phủ khung' } elseif ($gifOn -and $gifHasCustomSize) { 'GIF: rộng {0}% · cao {1}%' -f [int][Math]::Round($script:gifCustomWidth * 100.0), [int][Math]::Round($script:gifCustomHeight * 100.0) } elseif ($gifOn) { "GIF: $gifSize%" } elseif ($gifChecked) { "GIF: Ch" + [char]0x01B0 + "a ch" + [char]0x1ECD + "n" } else { "GIF: T" + [char]0x1EAF + "t" }
    if ($ui.TxtWatermarkSummary) {
        $ui.TxtWatermarkSummary.Text = "$logoTxt " + [char]0x00B7 + " $gifTxt"
    }
}

# Trang Thuong hieu hien day du (khong con accordion Toggle-WatermarkOptions).
function Update-OverlaySelectorState {
    $logoAvailable = ($ui.ChkWatermark -and $ui.ChkWatermark.IsChecked -and $ui.ImgVideoWatermark -and $ui.ImgVideoWatermark.Source)
    $gifAvailable = ($ui.ChkGif -and $ui.ChkGif.IsChecked -and $ui.ImgVideoGif -and $ui.ImgVideoGif.Source)
    $gifSourceAvailable = [bool]($ui.ImgVideoGif -and $ui.ImgVideoGif.Source)
    if ($ui.BtnSelectLogo) { $ui.BtnSelectLogo.IsEnabled = [bool]$logoAvailable }
    if ($ui.BtnSelectGif) { $ui.BtnSelectGif.IsEnabled = [bool]$gifAvailable }
    if ($ui.BtnGifFullFrame) { $ui.BtnGifFullFrame.IsEnabled = (-not $script:uiBusy -and $gifSourceAvailable) }
}

function Update-WatermarkOverlay {
    if (-not $ui.CanvasWatermark) { return }
    if (Get-Command 'Update-OverlaySelectorState' -ErrorAction SilentlyContinue) { Update-OverlaySelectorState }

    # Neu dang phat video hoan chinh *-3-hoan-chinh.mp4 ma KHONG trong che do xem truoc sach (Clean Preview Mode),
    # thi video da co logo/GIF duoc nung vao tu truoc -> an overlay de khong bi chong 2 logo/GIF!
    # Chua co nguon video: an overlay + grip. Rieng trang Thuong hieu hien khung mau 9:16 de van keo tha duoc.
    $hasSource = [bool]($ui.Player -and $ui.Player.Source)
    $useSample = (-not $hasSource -and $script:currentPage -eq 'brand')
    if ($ui.PreviewSample) { $ui.PreviewSample.Visibility = $(if ($useSample) { 'Visible' } else { 'Collapsed' }) }
    if (-not $hasSource -and $ui.TxtNoVid) { $ui.TxtNoVid.Visibility = $(if ($useSample) { 'Collapsed' } else { 'Visible' }) }
    if (-not $hasSource -and -not $useSample) {
        foreach ($o in @($ui.BoxLogoOverlay, $ui.BoxGifOverlay, $ui.ImgVideoWatermark, $ui.ImgVideoGif)) { if ($o) { $o.Visibility = 'Collapsed' } }
        return
    }
    $isFinalizedVideo = ($ui.Player -and $ui.Player.Source -and $script:lastOut -and (($script:lastOut -match '-3-hoan-chinh\.mp4$') -or (Test-KhoExternalVideoPath $script:lastOut)) -and (-not $script:previewingClean))
    if ($isFinalizedVideo) {
        if ($ui.BoxLogoOverlay)    { $ui.BoxLogoOverlay.Visibility    = 'Collapsed' }
        if ($ui.BoxGifOverlay)     { $ui.BoxGifOverlay.Visibility     = 'Collapsed' }
        if ($ui.ImgVideoWatermark) { $ui.ImgVideoWatermark.Visibility = 'Collapsed' }

        if ($ui.ImgVideoGif)       { $ui.ImgVideoGif.Visibility       = 'Collapsed' }
        return
    }

    $frameW = $ui.CanvasWatermark.ActualWidth
    $frameH = $ui.CanvasWatermark.ActualHeight
    if ($frameW -le 10 -or $frameH -le 10) {
        $frameW = if ($ui.PhoneFrame -and $ui.PhoneFrame.Width -gt 10) { $ui.PhoneFrame.Width } else { 340.0 }
        $frameH = if ($ui.PhoneFrame -and $ui.PhoneFrame.Height -gt 10) { $ui.PhoneFrame.Height } else { 604.0 }
    }

    # 1. Kich thuoc logo (% theo chieu rong video)
    $logoEnabled = ($ui.ChkWatermark -and $ui.ChkWatermark.IsChecked)
    if ($logoEnabled -and $ui.ImgVideoWatermark -and $ui.ImgVideoWatermark.Source) {
                $logoAspect = 1.0
        try {
            $srcW = $ui.ImgVideoWatermark.Source.PixelWidth
            $srcH = $ui.ImgVideoWatermark.Source.PixelHeight
            if ($srcW -gt 0 -and $srcH -gt 0) { $logoAspect = [double]$srcH / [double]$srcW }
        } catch { Write-FileLogLimited 'overlay-aspect' "WARN doc ty le logo: $($_.Exception.Message)" }
        $hasCustomLogoSize = ($script:logoCustomWidth -gt 0.0 -and $script:logoCustomHeight -gt 0.0)
        if ($hasCustomLogoSize) {
            $logoW = [Math]::Max(6.0, [Math]::Round($frameW * $script:logoCustomWidth))
            $logoH = [Math]::Max(6.0, [Math]::Round($frameH * $script:logoCustomHeight))
            $logoStretch = 'Fill'
        } else {
            $sizePercent = if ($ui.SldLogoSize) { [double]$ui.SldLogoSize.Value } else { 30.0 }
            $logoW = [Math]::Max(1.0, [Math]::Round($frameW * ($sizePercent / 100.0)))
            $logoH = [Math]::Max(1.0, [Math]::Round($logoW * $logoAspect))
            # Gioi han chieu cao logo toi da 60% chieu cao khung hinh de tranh logo qua dai tran khung
            $maxLogoH = [Math]::Round($frameH * 0.60)
            if ($logoH -gt $maxLogoH) {
                $logoH = $maxLogoH
                $logoW = [Math]::Max(1.0, [Math]::Round($logoH / $logoAspect))
            }
            $logoStretch = 'Uniform'
        }
        # 2. Do mo logo (0% - 95%)
        $fadeVal = if ($ui.SldLogoFade) { [double]$ui.SldLogoFade.Value } else { 60.0 }
        $alpha = [Math]::Max(0.05, [Math]::Min(1.0, (100.0 - $fadeVal) / 100.0))

        $ui.ImgVideoWatermark.Stretch = $logoStretch
        $ui.ImgVideoWatermark.Width   = $logoW
        $ui.ImgVideoWatermark.Height  = $logoH
        $ui.ImgVideoWatermark.Opacity = $alpha

        if ($ui.BoxLogoOverlay) {
            $ui.BoxLogoOverlay.Width  = $logoW
            $ui.BoxLogoOverlay.Height = $logoH
        }

        # 3. Vi tri & Chuyen dong Logo
        $availX = [Math]::Max(0.0, $frameW - $logoW)
        $availY = [Math]::Max(0.0, $frameH - $logoH)

        $isFixed = ($ui.CmbLogoMode -and $ui.CmbLogoMode.SelectedIndex -eq 1)
        if ($isFixed) {
            if ($null -ne $script:logoCustomX -and $script:logoCustomX -ge 0.0 -and
                $null -ne $script:logoCustomY -and $script:logoCustomY -ge 0.0) {
                $x = $availX * [double]$script:logoCustomX
                $y = $availY * [double]$script:logoCustomY
            } else {
                $posIdx = if ($ui.CmbLogoPosition) { [int]$ui.CmbLogoPosition.SelectedIndex } else { 3 }
                switch ($posIdx) {
                    0 { $x = $availX * 0.04; $y = $availY * 0.04 } # Tren trai
                    1 { $x = $availX * 0.96; $y = $availY * 0.04 } # Tren phai
                    2 { $x = $availX * 0.04; $y = $availY * 0.96 } # Duoi trai
                    3 { $x = $availX * 0.96; $y = $availY * 0.96 } # Duoi phai
                    4 { $x = $availX * 0.50; $y = $availY * 0.50 } # Giua
                    default { $x = $availX * 0.96; $y = $availY * 0.96 }
                }
            }
        } else {
            # Tu do - di chuyen (khop cong thuc FFmpeg)
            $t = 0.0
            if ($ui.Player -and $ui.Player.Source) {
                try { $t = $ui.Player.Position.TotalSeconds } catch { Write-FileLogLimited 'overlay-pos' "WARN doc vi tri phat: $($_.Exception.Message)" }
            }
            $x = $availX * (0.5 + 0.46 * [Math]::Sin(0.23 * $t + 0.6))
            $y = $availY * (0.5 + 0.46 * [Math]::Sin(0.17 * $t - 1.1))
        }

        $roundX = [Math]::Round($x)
        $roundY = [Math]::Round($y)
        if ($ui.BoxLogoOverlay) {
            [Windows.Controls.Canvas]::SetLeft($ui.BoxLogoOverlay, $roundX)
            [Windows.Controls.Canvas]::SetTop($ui.BoxLogoOverlay, $roundY)
            $ui.BoxLogoOverlay.Visibility = 'Visible'
        }
        [Windows.Controls.Canvas]::SetLeft($ui.ImgVideoWatermark, $roundX)
        [Windows.Controls.Canvas]::SetTop($ui.ImgVideoWatermark, $roundY)
        $ui.ImgVideoWatermark.Visibility = 'Visible'
    } else {
        if ($ui.BoxLogoOverlay)    { $ui.BoxLogoOverlay.Visibility    = 'Collapsed' }
        if ($ui.ImgVideoWatermark) { $ui.ImgVideoWatermark.Visibility = 'Collapsed' }
    }

    # 4. Xu ly Overlay GIF
    $gifEnabled = ($ui.ChkGif -and $ui.ChkGif.IsChecked -and $ui.TxtGifPath -and -not [string]::IsNullOrWhiteSpace($ui.TxtGifPath.Text))
    if ($gifEnabled -and $ui.ImgVideoGif) {
        if ($script:gifFullFrame) {
            $gifW = $frameW
            $gifH = $frameH
        } elseif ($script:gifCustomWidth -gt 0.0 -and $script:gifCustomHeight -gt 0.0) {
            $gifW = [Math]::Max(6.0, [Math]::Round($frameW * $script:gifCustomWidth))
            $gifH = [Math]::Max(6.0, [Math]::Round($frameH * $script:gifCustomHeight))
        } else {
            $gifPercent = if ($ui.SldGifSize) { [double]$ui.SldGifSize.Value } else { 20.0 }
            $gifW = [Math]::Max(1.0, [Math]::Round($frameW * ($gifPercent / 100.0)))
            $gifAspect = 1.0
            try {
                if ($ui.ImgVideoGif -and $ui.ImgVideoGif.Source -and $ui.ImgVideoGif.Source.PixelWidth -gt 0 -and $ui.ImgVideoGif.Source.PixelHeight -gt 0) {
                    $gifAspect = [double]$ui.ImgVideoGif.Source.PixelHeight / [double]$ui.ImgVideoGif.Source.PixelWidth
                }
            } catch { Write-FileLogLimited 'overlay-aspect' "WARN doc ty le GIF: $($_.Exception.Message)" }
            $gifH = [Math]::Max(1.0, [Math]::Round($gifW * $gifAspect))

            # Gioi han chieu cao GIF toi da 100% chieu cao khung hinh
            $maxGifH = [Math]::Round($frameH * 1.00)
            if ($gifH -gt $maxGifH) {
                $gifH = $maxGifH
                $gifW = [Math]::Max(1.0, [Math]::Round($gifH / $gifAspect))
            }
        }
        $availGX = [Math]::Max(0.0, $frameW - $gifW)
        $availGY = [Math]::Max(0.0, $frameH - $gifH)

        if ($script:gifFullFrame) {
            $gx = 0.0
            $gy = 0.0
        } elseif ($null -ne $script:gifCustomX -and $script:gifCustomX -ge 0.0 -and
            $null -ne $script:gifCustomY -and $script:gifCustomY -ge 0.0) {
            $gx = $availGX * [double]$script:gifCustomX
            $gy = $availGY * [double]$script:gifCustomY
        } else {
            $gifPosIdx = if ($ui.CmbGifPosition) { [int]$ui.CmbGifPosition.SelectedIndex } else { 1 }
            switch ($gifPosIdx) {
                0 { $gx = $availGX * 0.04; $gy = $availGY * 0.04 } # Tren trai
                1 { $gx = $availGX * 0.96; $gy = $availGY * 0.04 } # Tren phai
                2 { $gx = $availGX * 0.04; $gy = $availGY * 0.96 } # Duoi trai
                3 { $gx = $availGX * 0.96; $gy = $availGY * 0.96 } # Duoi phai
                4 { $gx = $availGX * 0.50; $gy = $availGY * 0.50 } # Giua
                default { $gx = $availGX * 0.96; $gy = $availGY * 0.04 }
            }
        }

        $hasCustomGifSize = ($script:gifCustomWidth -gt 0.0 -and $script:gifCustomHeight -gt 0.0)
        $gifStretch = if ($script:gifFullFrame -or $hasCustomGifSize) { 'Fill' } else { 'Uniform' }
        if ($ui.ImgVideoGif) { $ui.ImgVideoGif.Stretch = $gifStretch }

        $roundGX = [Math]::Round($gx)
        $roundGY = [Math]::Round($gy)
        if ($ui.BoxGifOverlay) {
            $ui.BoxGifOverlay.Width  = $gifW
            $ui.BoxGifOverlay.Height = $gifH
            [Windows.Controls.Canvas]::SetLeft($ui.BoxGifOverlay, $roundGX)
            [Windows.Controls.Canvas]::SetTop($ui.BoxGifOverlay, $roundGY)
            $ui.BoxGifOverlay.Visibility = 'Visible'
        }

        if ($script:gifPlayer -and $script:gifPlayer.IsLoaded -and $ui.ImgVideoGif) {
            $ui.ImgVideoGif.Source = $script:gifPlayer.BitmapSource
            $ui.ImgVideoGif.Width = $gifW
            $ui.ImgVideoGif.Height = $gifH
            [Windows.Controls.Canvas]::SetLeft($ui.ImgVideoGif, $roundGX)
            [Windows.Controls.Canvas]::SetTop($ui.ImgVideoGif, $roundGY)
            $ui.ImgVideoGif.Visibility = 'Visible'

        } elseif ($ui.ImgVideoGif -and $ui.ImgVideoGif.Source) {
            $ui.ImgVideoGif.Width = $gifW
            $ui.ImgVideoGif.Height = $gifH
            [Windows.Controls.Canvas]::SetLeft($ui.ImgVideoGif, $roundGX)
            [Windows.Controls.Canvas]::SetTop($ui.ImgVideoGif, $roundGY)
            $ui.ImgVideoGif.Visibility = 'Visible'

        }
    } else {
        if ($ui.BoxGifOverlay) { $ui.BoxGifOverlay.Visibility = 'Collapsed' }

        if ($ui.ImgVideoGif) { $ui.ImgVideoGif.Visibility = 'Collapsed' }
    }
}
$ui.SldLogoSize.Add_ValueChanged({
    $script:logoCustomWidth = -1.0
    $script:logoCustomHeight = -1.0
    $ui.TxtLogoSize.Text = ('{0}%' -f [int][Math]::Round($ui.SldLogoSize.Value))
    if (Get-Command 'Enter-CleanPreviewMode' -ErrorAction SilentlyContinue) { Enter-CleanPreviewMode }
    if (Get-Command 'Update-WatermarkOverlay' -ErrorAction SilentlyContinue) { Update-WatermarkOverlay }
    if (Get-Command 'Update-WatermarkSummary' -ErrorAction SilentlyContinue) { Update-WatermarkSummary }
})
$ui.CmbLogoMode.Add_SelectionChanged({
    $fixed = ($ui.CmbLogoMode.SelectedIndex -eq 1)
    $ui.PanelLogoPosition.Visibility = $(if ($fixed) { 'Visible' } else { 'Collapsed' })
    if ($ui.TxtLogoMotionHint) { $ui.TxtLogoMotionHint.Visibility = $(if ($fixed) { 'Collapsed' } else { 'Visible' }) }
    $ui.CmbLogoPosition.IsEnabled = ($ui.CmbLogoMode.IsEnabled -and $fixed)
    if (Get-Command 'Enter-CleanPreviewMode' -ErrorAction SilentlyContinue) { Enter-CleanPreviewMode }
    if (Get-Command 'Update-WatermarkOverlay' -ErrorAction SilentlyContinue) { Update-WatermarkOverlay }
})
$ui.SldLogoFade.Add_ValueChanged({
    $ui.TxtLogoFade.Text = ('{0}%' -f [int][Math]::Round($ui.SldLogoFade.Value))
    if (Get-Command 'Enter-CleanPreviewMode' -ErrorAction SilentlyContinue) { Enter-CleanPreviewMode }
    if (Get-Command 'Update-WatermarkOverlay' -ErrorAction SilentlyContinue) { Update-WatermarkOverlay }
})
$script:positionCustomIndex = 5   # muc "Tuy chinh (keo tha)" trong CmbLogoPosition/CmbGifPosition

function Set-PositionComboCustom {
    # Goi khi keo/resize: hien "Tuy chinh" thay vi de combo trong (SelectedIndex=-1).
    param([ValidateSet('logo','gif')][string]$Target)
    $cmb = if ($Target -eq 'logo') { $ui.CmbLogoPosition } else { $ui.CmbGifPosition }
    if ($cmb -and $cmb.SelectedIndex -ne $script:positionCustomIndex) { $cmb.SelectedIndex = $script:positionCustomIndex }
}

function Test-LogoHasCustomGeometry {
    return [bool](($script:logoCustomX -ge 0.0 -and $script:logoCustomY -ge 0.0) -or ($script:logoCustomWidth -gt 0.0 -and $script:logoCustomHeight -gt 0.0))
}
function Test-GifHasCustomGeometry {
    return [bool]($script:gifFullFrame -or ($script:gifCustomX -ge 0.0 -and $script:gifCustomY -ge 0.0) -or ($script:gifCustomWidth -gt 0.0 -and $script:gifCustomHeight -gt 0.0))
}

if ($ui.CmbLogoPosition) {
    $ui.CmbLogoPosition.Add_SelectionChanged({
        $idx = $ui.CmbLogoPosition.SelectedIndex
        if ($idx -eq $script:positionCustomIndex) {
            # Chon lai "Tuy chinh" khi chua co hinh hoc tuy chinh -> giu preset truoc do.
            if (-not (Test-LogoHasCustomGeometry)) { $ui.CmbLogoPosition.SelectedIndex = [int]$script:logoLastPresetIdx }
            return
        }
        if ($idx -ge 0) {
            $script:logoLastPresetIdx = $idx
            $script:logoCustomX = -1.0
            $script:logoCustomY = -1.0
            if (Get-Command 'Enter-CleanPreviewMode' -ErrorAction SilentlyContinue) { Enter-CleanPreviewMode }
            if (Get-Command 'Update-WatermarkOverlay' -ErrorAction SilentlyContinue) { Update-WatermarkOverlay }
        }
        Request-SaveSettings
    })
}
if ($ui.ChkWatermark) {
    $ui.ChkWatermark.Add_Checked({
        if (Get-Command 'Enter-CleanPreviewMode' -ErrorAction SilentlyContinue) { Enter-CleanPreviewMode }
        if (Get-Command 'Update-WatermarkOverlay' -ErrorAction SilentlyContinue) { Update-WatermarkOverlay }
        if (Get-Command 'Update-WatermarkSummary' -ErrorAction SilentlyContinue) { Update-WatermarkSummary }
    })
    $ui.ChkWatermark.Add_Unchecked({
        if (Get-Command 'Enter-CleanPreviewMode' -ErrorAction SilentlyContinue) { Enter-CleanPreviewMode }
        if (Get-Command 'Update-WatermarkOverlay' -ErrorAction SilentlyContinue) { Update-WatermarkOverlay }
        if (Get-Command 'Update-WatermarkSummary' -ErrorAction SilentlyContinue) { Update-WatermarkSummary }
    })
}
if ($ui.ViewportGrid) {
    $ui.ViewportGrid.Add_SizeChanged({
        if (Get-Command 'Update-PhoneFrameSize' -ErrorAction SilentlyContinue) { Update-PhoneFrameSize }
    })
}
function Set-LogoSelection {
    param([string]$Path)
    $stream = $null; $zip = $null
    try {
        if ([string]::IsNullOrWhiteSpace($Path)) {
            Add-Type -AssemblyName System.IO.Compression.FileSystem
            $zip = [IO.Compression.ZipFile]::OpenRead((Join-Path $scriptDir 'kid-logo.zip'))
            $entry = $zip.GetEntry('kid-logo.png')
            if (-not $entry) { throw 'Không tìm thấy logo Kid.' }
            $stream = New-Object IO.MemoryStream
            $entryStream = $entry.Open()
            try { $entryStream.CopyTo($stream) } finally { $entryStream.Dispose() }
            $stream.Position = 0
        } else {
            $stream = [IO.File]::OpenRead($Path)
        }
        $bitmap = New-Object Windows.Media.Imaging.BitmapImage
        $bitmap.BeginInit()
        $bitmap.DecodePixelWidth = 96
        $bitmap.CacheOption = [Windows.Media.Imaging.BitmapCacheOption]::OnLoad
        $bitmap.StreamSource = $stream
        $bitmap.EndInit()
        $bitmap.Freeze()
    } finally {
        if ($stream) { $stream.Dispose() }
        if ($zip) { $zip.Dispose() }
    }
    $custom = -not [string]::IsNullOrWhiteSpace($Path)
    $ui.ImgLogoPreview.Source = $bitmap
    if ($ui.ImgVideoWatermark) { $ui.ImgVideoWatermark.Source = $bitmap }
    $ui.TxtLogoPath.Text = $(if ($custom) { $Path } else { '' })
    $ui.TxtLogoPath.ToolTip = $(if ($custom) { $Path } else { 'Đang dùng logo Kid có sẵn trong ứng dụng.' })
    $ui.TxtLogoPath.CaretIndex = 0
    $ui.TxtLogoPath.ScrollToHome()
    $ui.TxtLogoName.Text = $(if ($custom) { 'Đang dùng: ' + [IO.Path]::GetFileName($Path) } else { 'Đang dùng: Logo Kid' })
    $ui.TxtLogoName.ToolTip = $ui.TxtLogoPath.ToolTip
    $ui.TxtLogoDefaultHint.Visibility = $(if ($custom) { 'Collapsed' } else { 'Visible' })
    $ui.BtnDefaultLogo.Content = $(if ($custom) { 'Dùng logo Kid' } else { 'Logo Kid (đang dùng)' })
    $ui.BtnDefaultLogo.IsEnabled = ($custom -and -not $script:uiBusy)
    if (Get-Command 'Enter-CleanPreviewMode' -ErrorAction SilentlyContinue) { Enter-CleanPreviewMode }
    if (Get-Command 'Update-WatermarkOverlay' -ErrorAction SilentlyContinue) { Update-WatermarkOverlay }
}
$ui.BtnDefaultLogo.Add_Click({
    try { Set-LogoSelection -Path '' } catch { Show-Toast 'Không đọc được logo Kid. Hãy mở lại bằng Kid-FB.Y.exe để khôi phục.' -Kind error }
})
$ui.BtnPickLogo.Add_Click({
    $dialog = New-Object Microsoft.Win32.OpenFileDialog
    $dialog.Filter = 'PNG (*.png)|*.png'
    $dialog.CheckFileExists = $true
    if ($dialog.ShowDialog($win) -ne $true) { return }
    $image = $null
    $validPath = $null
    try {
        $image = [System.Drawing.Image]::FromFile($dialog.FileName)
        if ($image.RawFormat.Guid -ne [System.Drawing.Imaging.ImageFormat]::Png.Guid) {
            throw 'Không phải PNG.'
        }
        $validPath = $dialog.FileName
    } catch {
        Show-Toast 'PNG không hợp lệ hoặc không đọc được.' -Kind error
        return
    } finally {
        if ($image) { $image.Dispose() }
    }
    try { Set-LogoSelection -Path $validPath } catch { Show-Toast 'Không đọc được ảnh PNG đã chọn.' -Kind error }
})

function Get-GifWorkerEngineFunctions {
    if($script:gifWorkerEngineFunctionTexts){return ,$script:gifWorkerEngineFunctionTexts}
    $tokens=$null; $parseErrors=$null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($engine, [ref]$tokens, [ref]$parseErrors)
    if($parseErrors.Count){throw "Engine parse failed for worker GIF validation: $($parseErrors[0].Message)"}
    $wanted = @('Quote-Arg','Invoke-Exe','Find-Tool','Test-GifFile')
    $defs = @($ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $wanted -contains $n.Name }, $true) | ForEach-Object { $_.Extent.Text })
    foreach ($name in $wanted) { if (-not ($defs -match "(?im)^function\s+$([regex]::Escape($name))\b")) { throw "Engine GIF validation helper is missing: $name" } }
    $script:gifWorkerEngineFunctionTexts=$defs
    return ,$defs
}
try { Get-GifWorkerEngineFunctions | Out-Null } catch { Write-FileLog "WARN kiem tra ham engine cho worker GIF: $($_.Exception.Message)" }

function Stop-GifSelectionWorker {
    $job = $script:gifSelectionWorker
    if (-not $job) { return }
    $job.Cancelled = $true
    if($job.Runspace -and -not $job.Async -and $job.Runspace.RunspaceStateInfo.State -eq [System.Management.Automation.Runspaces.RunspaceState]::Opening){
        if(-not $script:gifCancelledWorkers.Contains($job)){[void]$script:gifCancelledWorkers.Add($job)}
        if([object]::ReferenceEquals($script:gifSelectionWorker,$job)){$script:gifSelectionWorker=$null}
        return
    }
    if ($job.PowerShell -and $job.Async -and -not $job.Async.IsCompleted) {
        [void]$script:gifCancelledWorkers.Add($job)
        try { $job.StopAsync = $job.PowerShell.BeginStop($null, $null) } catch { <# bo qua: don dep khi huy/dong, loi o day khong anh huong ket qua #> }
    }
    if (-not $job.Async -or $job.Async.IsCompleted) {
        try { if ($job.PowerShell) { $job.PowerShell.Dispose() } } catch { <# bo qua: don dep khi huy/dong, loi o day khong anh huong ket qua #> }
        try { if ($job.Runspace) { $job.Runspace.Dispose() } } catch { <# bo qua: don dep khi huy/dong, loi o day khong anh huong ket qua #> }
        $script:gifSelectionWorker = $null
    }
    if ($job.Async -and -not $job.Async.IsCompleted) { $script:gifSelectionWorker = $null }
}

function Start-GifSelectionWorker {
    param([string]$FullPath, [int]$Generation)
    Stop-GifSelectionWorker
    $engineFunctions = Get-GifWorkerEngineFunctions
    $runspace=$null;$ps=$null
    try {
    $runspace = [RunspaceFactory]::CreateRunspace()
    $runspace.ApartmentState = [Threading.ApartmentState]::STA
    $runspace.ThreadOptions = [System.Management.Automation.Runspaces.PSThreadOptions]::ReuseThread
    $ps = [PowerShell]::Create(); $ps.Runspace = $runspace
    $worker = {
        param($path,$rootPath,$functionTexts)
        $script:Here = $rootPath
        foreach($definition in $functionTexts) { Invoke-Expression $definition }
        $process=[Diagnostics.Process]::GetCurrentProcess();$process.Refresh();$privateBefore=$process.PrivateMemorySize64
        Test-GifFile -File $path
        $player = New-Object WpfGifPlayer
        $player.MaxPreviewSide = 720
        if(-not $player.Load($path)) { throw "GIF decode failed: $($player.LoadError)" }
        $process.Refresh();$privateAfterLoad=$process.PrivateMemorySize64
        $prepared = $player.PrepareForTransfer()
        $process.Refresh();$privateAfterPrepare=$process.PrivateMemorySize64
        $player.Close()
        [pscustomobject]@{ Path=$path; Prepared=$prepared; FrameCount=$prepared.FrameCount; Width=$prepared.CanvasWidth; Height=$prepared.CanvasHeight; PrivateBefore=$privateBefore; PrivateAfterLoad=$privateAfterLoad; PrivateAfterPrepare=$privateAfterPrepare }
    }
    [void]$ps.AddScript($worker.ToString()).AddArgument($FullPath).AddArgument($script:root).AddArgument($engineFunctions)
    $runspace.OpenAsync()
    $script:gifSelectionWorker = [pscustomobject]@{ Generation=$Generation; Path=$FullPath; PowerShell=$ps; Runspace=$runspace; Async=$null; Cancelled=$false; StopAsync=$null }
    } catch {
        try{if($ps){$ps.Dispose()}}catch{};try{if($runspace){$runspace.Dispose()}}catch{}
        throw
    }
}

function Poll-GifSelectionWorker {
    foreach($stale in @($script:gifCancelledWorkers)) {
        if($stale.CleanupComplete) { [void]$script:gifCancelledWorkers.Remove($stale); continue }
        $openingFinished=($stale.Runspace -and -not $stale.Async -and $stale.Runspace.RunspaceStateInfo.State -in @([System.Management.Automation.Runspaces.RunspaceState]::Opened,[System.Management.Automation.Runspaces.RunspaceState]::Broken,[System.Management.Automation.Runspaces.RunspaceState]::Closed))
        if(($stale.StopAsync -and $stale.StopAsync.IsCompleted) -or (-not $stale.StopAsync -and $stale.Async -and $stale.Async.IsCompleted) -or $openingFinished) {
            if($stale.StopAsync -and $stale.StopAsync.IsCompleted){try{$null=$stale.PowerShell.EndStop($stale.StopAsync)}catch{}}
            elseif($stale.Async -and $stale.Async.IsCompleted){try{$null=$stale.PowerShell.EndInvoke($stale.Async)}catch{}}
            try{$stale.PowerShell.Dispose()}catch{};try{$stale.Runspace.Dispose()}catch{}
            [void]$script:gifCancelledWorkers.Remove($stale)
        }
    }
    if($script:closeAfterGifStop -and -not $script:ps -and -not $script:gifSelectionWorker -and $script:gifCancelledWorkers.Count-eq 0){
        $script:closeAfterGifStop=$false
        try{$action=[Action]{if($win){$win.Close()}};$null=$win.Dispatcher.BeginInvoke($action)}catch{}
    }
    $job = $script:gifSelectionWorker
    if (-not $job) { return }
    if(-not $job.Async){
        $state=$job.Runspace.RunspaceStateInfo.State
        if($state -eq [System.Management.Automation.Runspaces.RunspaceState]::Opening){return}
        if($state -ne [System.Management.Automation.Runspaces.RunspaceState]::Opened){
            $script:lastGifWorkerError="GIF worker runspace failed to open ($state)."
            try{$job.PowerShell.Dispose()}catch{};try{$job.Runspace.Dispose()}catch{}
            if([object]::ReferenceEquals($script:gifSelectionWorker,$job)){$script:gifSelectionWorker=$null}
            if(Get-Command 'Show-Toast' -ErrorAction SilentlyContinue){Show-Toast 'Không thể khởi chạy bộ giải mã GIF.' -Kind error}
            return
        }
        try{$job.Async=$job.PowerShell.BeginInvoke()}catch{
            $script:lastGifWorkerError=$_.Exception.Message
            try{$job.PowerShell.Dispose()}catch{};try{$job.Runspace.Dispose()}catch{}
            if([object]::ReferenceEquals($script:gifSelectionWorker,$job)){$script:gifSelectionWorker=$null}
            if(Get-Command 'Show-Toast' -ErrorAction SilentlyContinue){Show-Toast 'Không thể khởi chạy bộ giải mã GIF.' -Kind error}
            return
        }
    }
    if ($job.Cancelled -and $job.StopAsync -and $job.StopAsync.IsCompleted) {
        try { $null=$job.PowerShell.EndStop($job.StopAsync) } catch { <# bo qua: don dep khi huy/dong, loi o day khong anh huong ket qua #> }
        try { $job.PowerShell.Dispose() } catch { <# bo qua: don dep khi huy/dong, loi o day khong anh huong ket qua #> }
        try { $job.Runspace.Dispose() } catch { <# bo qua: don dep khi huy/dong, loi o day khong anh huong ket qua #> }
        if ([object]::ReferenceEquals($script:gifSelectionWorker,$job)) { $script:gifSelectionWorker=$null }
        return
    }
    if (-not $job.Async.IsCompleted) { return }
    $result=$null; $failure=$null
    try {
        $output=$job.PowerShell.EndInvoke($job.Async)
        if($output.Count -gt 0){$result=$output[$output.Count-1]}
        if($job.PowerShell.Streams.Error.Count -gt 0){$failure=[string]$job.PowerShell.Streams.Error[0]}
    } catch { $failure=$_.Exception.Message }
    try { $job.PowerShell.Dispose() } catch { <# bo qua: don dep khi huy/dong, loi o day khong anh huong ket qua #> }; try { $job.Runspace.Dispose() } catch { <# bo qua: don dep khi huy/dong, loi o day khong anh huong ket qua #> }
    if ([object]::ReferenceEquals($script:gifSelectionWorker,$job)) { $script:gifSelectionWorker=$null }
    if ($job.Cancelled -or $job.Generation -ne $script:gifSelectionGeneration) { return }
    if ($failure -or -not $result -or -not $result.Prepared) {
        $script:lastGifWorkerError=if($failure){$failure}else{'GIF worker returned no prepared frame data.'}
        if(Get-Command 'Add-Log' -ErrorAction SilentlyContinue){Add-Log "Lỗi tải GIF: $($script:lastGifWorkerError)" 'Danger'}
        if(Get-Command 'Show-Toast' -ErrorAction SilentlyContinue){Show-Toast 'GIF không hợp lệ hoặc không thể giải mã.' -Kind error}
        return
    }
    $script:lastGifWorkerResult=$result
    try {
        $next=New-Object WpfGifPlaybackWorker
        if(-not $next.AdoptOnCurrentThread($result.Prepared)){throw "Prepared GIF adoption failed: $($next.LoadError)"}
        if($script:gifPlayer){try{$script:gifPlayer.Close()}catch{}}
        $script:gifPlayer=$next
        $script:gifPlaybackErrorReported=$false
        if($ui.ImgGifPreview){$ui.ImgGifPreview.Source=$next.BitmapSource}
        if($ui.ImgVideoGif){$ui.ImgVideoGif.Source=$next.BitmapSource}
        $fileName=[IO.Path]::GetFileName($job.Path)
        if($ui.TxtGifPath){$ui.TxtGifPath.Text=$job.Path;$ui.TxtGifPath.ToolTip=$job.Path;$ui.TxtGifPath.CaretIndex=0;$ui.TxtGifPath.ScrollToHome()}
        if($ui.TxtGifName){$ui.TxtGifName.Text=[string]::Format("{0}ang d{1}ng: {2}",[char]0x0110,[char]0x00F9,$fileName);$ui.TxtGifName.ToolTip=$job.Path}
        if(Get-Command 'Enter-CleanPreviewMode' -ErrorAction SilentlyContinue){Enter-CleanPreviewMode}
        if(Get-Command 'Update-WatermarkOverlay' -ErrorAction SilentlyContinue){Update-WatermarkOverlay}
        if(Get-Command 'Update-WatermarkSummary' -ErrorAction SilentlyContinue){Update-WatermarkSummary}
    } catch { $script:lastGifWorkerError=$_.Exception.Message; if($next){try{$next.Close()}catch{}} }
}

function Reset-GifFullFrame {
    param([switch]$PreserveCustomSize)
    if (-not $script:gifFullFrame) { return }
    $script:gifFullFrame = $false
    if (-not $PreserveCustomSize) {
        $script:gifCustomWidth = -1.0
        $script:gifCustomHeight = -1.0
    }
    $stretch = if ($PreserveCustomSize) { 'Fill' } else { 'Uniform' }
    if ($ui.ImgVideoGif) { $ui.ImgVideoGif.Stretch = $stretch }

    if ($ui.BtnGifFullFrame) { $ui.BtnGifFullFrame.Style = $win.FindResource('BtnSecondary') }
}

function Set-GifFullFrame {
    if ($script:uiBusy) { return }
    $gifSourceAvailable = [bool]($ui.ImgVideoGif -and $ui.ImgVideoGif.Source)
    if (-not ($gifSourceAvailable -and $ui.TxtGifPath -and -not [string]::IsNullOrWhiteSpace($ui.TxtGifPath.Text))) {
        if (Get-Command 'Show-Toast' -ErrorAction SilentlyContinue) { Show-Toast 'Chọn file GIF trước khi phủ đầy khung video.' -Kind warning }
        return
    }
    $script:gifFullFrame = $true
    $script:gifApplyingFullFrame = $true
    try {
        if ($ui.BtnGifFullFrame) { $ui.BtnGifFullFrame.Style = $win.FindResource('BtnPrimary') }
        if ($ui.ChkGif) { $ui.ChkGif.IsChecked = $true }
        if ($ui.SldGifSize) { $ui.SldGifSize.Value = $ui.SldGifSize.Maximum }
        $script:gifCustomWidth = -1.0
        $script:gifCustomHeight = -1.0
        $script:gifCustomX = 0.0
        $script:gifCustomY = 0.0
        Set-PositionComboCustom -Target gif
        if (Get-Command 'Enter-CleanPreviewMode' -ErrorAction SilentlyContinue) { Enter-CleanPreviewMode }
        if (Get-Command 'Update-WatermarkOverlay' -ErrorAction SilentlyContinue) { Update-WatermarkOverlay }
        if (Get-Command 'Update-WatermarkSummary' -ErrorAction SilentlyContinue) { Update-WatermarkSummary }
    } finally {
        $script:gifApplyingFullFrame = $false
    }
}
function Set-GifSelection {
    param([string]$Path)
    if ([string]::IsNullOrWhiteSpace($Path)) {
        Reset-GifFullFrame
        $script:gifCustomX = -1.0
        $script:gifCustomY = -1.0
        $script:gifCustomWidth = -1.0
        $script:gifCustomHeight = -1.0
        $script:gifSelectionGeneration++
        Stop-GifSelectionWorker
        if ($ui.TxtGifPath) { $ui.TxtGifPath.Text = ''; $ui.TxtGifPath.ToolTip = 'File GIF (.gif)' }
        if ($ui.TxtGifName) { $ui.TxtGifName.Text = "Ch" + [char]0x01B0 + "a ch" + [char]0x1ECD + "n file GIF"; $ui.TxtGifName.ToolTip = $null }
        if ($ui.ImgGifPreview) { $ui.ImgGifPreview.Source = $null }
        if ($script:gifPlayer) { try { $script:gifPlayer.Close() } catch { <# bo qua: don dep khi huy/dong, loi o day khong anh huong ket qua #> } }
        $script:gifPlayer=$null

        if ($ui.ImgVideoGif) { $ui.ImgVideoGif.Source=$null; $ui.ImgVideoGif.Visibility='Collapsed' }
        if ($ui.BoxGifOverlay) { $ui.BoxGifOverlay.Visibility='Collapsed' }
        if(Get-Command 'Update-WatermarkOverlay' -ErrorAction SilentlyContinue){Update-WatermarkOverlay}
        if(Get-Command 'Update-WatermarkSummary' -ErrorAction SilentlyContinue){Update-WatermarkSummary}
        return
    }
    if(-not (Test-Path -LiteralPath $Path -PathType Leaf)){if(Get-Command 'Show-Toast' -ErrorAction SilentlyContinue){Show-Toast 'Không tìm thấy file GIF đã chọn.'};return}
    try { $full=[IO.Path]::GetFullPath($Path); $generation=([int]$script:gifSelectionGeneration)+1; $script:gifSelectionGeneration=$generation; Start-GifSelectionWorker -FullPath $full -Generation $generation;if(Get-Command 'Show-Toast' -ErrorAction SilentlyContinue){Show-Toast 'Đang tải GIF, vui lòng đợi.'} }
    catch { $script:lastGifWorkerError=$_.Exception.Message;if(Get-Command 'Add-Log' -ErrorAction SilentlyContinue){Add-Log "Không thể khởi tạo GIF worker: $($script:lastGifWorkerError)" 'Danger'};if(Get-Command 'Show-Toast' -ErrorAction SilentlyContinue){Show-Toast 'Không thể tải GIF lúc này.'} }
}

if ($ui.SldGifSize) {
    $ui.SldGifSize.Add_ValueChanged({
        if ($script:gifFullFrame -and -not $script:gifApplyingFullFrame) { Reset-GifFullFrame }
        $script:gifCustomWidth = -1.0
        $script:gifCustomHeight = -1.0
        if ($ui.TxtGifSize) { $ui.TxtGifSize.Text = ('{0}%' -f [int][Math]::Round($ui.SldGifSize.Value)) }
        if (Get-Command 'Enter-CleanPreviewMode' -ErrorAction SilentlyContinue) { Enter-CleanPreviewMode }
        if (Get-Command 'Update-WatermarkOverlay' -ErrorAction SilentlyContinue) { Update-WatermarkOverlay }
        if (Get-Command 'Update-WatermarkSummary' -ErrorAction SilentlyContinue) { Update-WatermarkSummary }
    })
}
if ($ui.CmbGifPosition) {
    $ui.CmbGifPosition.Add_SelectionChanged({
        $idx = $ui.CmbGifPosition.SelectedIndex
        if ($idx -eq $script:positionCustomIndex) {
            if (-not (Test-GifHasCustomGeometry)) { $ui.CmbGifPosition.SelectedIndex = [int]$script:gifLastPresetIdx }
            return
        }
        if ($idx -ge 0) {
            $script:gifLastPresetIdx = $idx
            if ($script:gifFullFrame) { Reset-GifFullFrame }
            $script:gifCustomX = -1.0
            $script:gifCustomY = -1.0
            if (Get-Command 'Enter-CleanPreviewMode' -ErrorAction SilentlyContinue) { Enter-CleanPreviewMode }
            if (Get-Command 'Update-WatermarkOverlay' -ErrorAction SilentlyContinue) { Update-WatermarkOverlay }
        }
        Request-SaveSettings
    })
}
if ($ui.ChkGif) {
    $ui.ChkGif.Add_Checked({
        if (Get-Command 'Enter-CleanPreviewMode' -ErrorAction SilentlyContinue) { Enter-CleanPreviewMode }
        if (Get-Command 'Update-WatermarkOverlay' -ErrorAction SilentlyContinue) { Update-WatermarkOverlay }
        if (Get-Command 'Update-WatermarkSummary' -ErrorAction SilentlyContinue) { Update-WatermarkSummary }
    })
    $ui.ChkGif.Add_Unchecked({
        if (Get-Command 'Enter-CleanPreviewMode' -ErrorAction SilentlyContinue) { Enter-CleanPreviewMode }
        if (Get-Command 'Update-WatermarkOverlay' -ErrorAction SilentlyContinue) { Update-WatermarkOverlay }
        if (Get-Command 'Update-WatermarkSummary' -ErrorAction SilentlyContinue) { Update-WatermarkSummary }
    })
}
if ($ui.BtnGifFullFrame) { $ui.BtnGifFullFrame.Add_Click({ Set-GifFullFrame }) }
if ($ui.BtnPickGif) {
    $ui.BtnPickGif.Add_Click({
        $dialog = New-Object Microsoft.Win32.OpenFileDialog
        $dialog.Filter = 'GIF (*.gif)|*.gif'
        $dialog.CheckFileExists = $true
        if ($dialog.ShowDialog($win) -ne $true) { return }
        $path = $dialog.FileName
        Set-GifSelection -Path $path
        if ($ui.ChkGif) { $ui.ChkGif.IsChecked = $true }
    })
}

# ==============================================================================
# HE THONG TUONG TAC CHUOT KEO THA & RESIZE WATERMARK/GIF TRUC TIEP TREN CANVAS
# ==============================================================================

if ($ui.CanvasWatermark) {
    $ui.CanvasWatermark.Add_MouseDown({
        try { $ui.CanvasWatermark.Focus() } catch { <# bo qua: khong focus duoc canvas thi bo qua #> }
    })
}

function Select-ActiveOverlay {
    param([string]$Target)
    if ($Target -eq 'logo' -and $ui.BoxLogoOverlay) {
        if (-not ($ui.ChkWatermark -and $ui.ChkWatermark.IsChecked -and $ui.ImgVideoWatermark -and $ui.ImgVideoWatermark.Source)) { return }
        $script:activeOverlay = 'logo'
        [Windows.Controls.Panel]::SetZIndex($ui.BoxLogoOverlay, 20)
        if ($ui.BoxGifOverlay) { [Windows.Controls.Panel]::SetZIndex($ui.BoxGifOverlay, 10) }
        try {
            $ui.BorderLogoOverlay.BorderBrush = (Get-Brush 'OverlayLogo')
            $ui.BorderGifOverlay.BorderBrush  = (Get-Brush 'OverlayGifDim')
        } catch { Write-FileLogLimited 'overlay-brush' "WARN doi mau vien overlay: $($_.Exception.Message)" }
    } elseif ($Target -eq 'gif' -and $ui.BoxGifOverlay) {
        if (-not ($ui.ChkGif -and $ui.ChkGif.IsChecked -and $ui.ImgVideoGif -and $ui.ImgVideoGif.Source)) { return }
        $script:activeOverlay = 'gif'
        [Windows.Controls.Panel]::SetZIndex($ui.BoxGifOverlay, 20)
        if ($ui.BoxLogoOverlay) { [Windows.Controls.Panel]::SetZIndex($ui.BoxLogoOverlay, 10) }
        try {
            $ui.BorderGifOverlay.BorderBrush  = (Get-Brush 'OverlayGif')
            $ui.BorderLogoOverlay.BorderBrush = (Get-Brush 'OverlayLogoDim')
        } catch { Write-FileLogLimited 'overlay-brush' "WARN doi mau vien overlay: $($_.Exception.Message)" }
    }
    # Lop dang chinh = nut Primary (khong dung ky tu dau tich).
    if ($ui.BtnSelectLogo) { $ui.BtnSelectLogo.Style = $win.FindResource($(if ($script:activeOverlay -eq 'logo') { 'BtnPrimary' } else { 'BtnSecondary' })) }
    if ($ui.BtnSelectGif) { $ui.BtnSelectGif.Style = $win.FindResource($(if ($script:activeOverlay -eq 'gif') { 'BtnPrimary' } else { 'BtnSecondary' })) }
}

if ($ui.BtnSelectLogo) {
    $ui.BtnSelectLogo.Add_Click({
        if (-not ($ui.ChkWatermark -and $ui.ChkWatermark.IsChecked -and $ui.ImgVideoWatermark -and $ui.ImgVideoWatermark.Source)) { return }
        if (-not $script:previewingClean -and (Get-Command 'Enter-CleanPreviewMode' -ErrorAction SilentlyContinue)) { Enter-CleanPreviewMode }
        Select-ActiveOverlay -Target 'logo'
    })
}
if ($ui.BtnSelectGif) {
    $ui.BtnSelectGif.Add_Click({
        if (-not ($ui.ChkGif -and $ui.ChkGif.IsChecked -and $ui.ImgVideoGif -and $ui.ImgVideoGif.Source)) { return }
        if (-not $script:previewingClean -and (Get-Command 'Enter-CleanPreviewMode' -ErrorAction SilentlyContinue)) { Enter-CleanPreviewMode }
        Select-ActiveOverlay -Target 'gif'
    })
}

function Get-OverlayFreeResizeGeometry {
    param(
        [double]$FrameWidth, [double]$FrameHeight,
        [double]$StartLeft, [double]$StartTop,
        [double]$StartWidth, [double]$StartHeight,
        [double]$DeltaX, [double]$DeltaY,
        [string]$Handle
    )
    $frameW = [Math]::Max(6.0, $FrameWidth)
    $frameH = [Math]::Max(6.0, $FrameHeight)
    $minW = [Math]::Min(6.0, $frameW)
    $minH = [Math]::Min(6.0, $frameH)
    $handleName = $Handle.ToUpperInvariant()
    $moveWest = $handleName.Contains('W')
    $moveEast = $handleName.Contains('E')
    $moveNorth = $handleName.Contains('N')
    $moveSouth = $handleName.Contains('S')

    if ($moveEast) {
        $candidateRight = $StartLeft + $StartWidth + $DeltaX
        $width = [Math]::Max($minW, [Math]::Min($frameW, ($candidateRight - $StartLeft)))
        $left = [Math]::Max(0.0, [Math]::Min(($frameW - $width), $StartLeft))
    } elseif ($moveWest) {
        $fixedRight = $StartLeft + $StartWidth
        $candidateLeft = $StartLeft + $DeltaX
        $width = [Math]::Max($minW, [Math]::Min($frameW, ($fixedRight - $candidateLeft)))
        $left = [Math]::Max(0.0, [Math]::Min(($frameW - $width), ($fixedRight - $width)))
    } else {
        $width = [Math]::Max($minW, [Math]::Min($frameW, $StartWidth))
        $left = [Math]::Max(0.0, [Math]::Min(($frameW - $width), $StartLeft))
    }

    if ($moveSouth) {
        $candidateBottom = $StartTop + $StartHeight + $DeltaY
        $height = [Math]::Max($minH, [Math]::Min($frameH, ($candidateBottom - $StartTop)))
        $top = [Math]::Max(0.0, [Math]::Min(($frameH - $height), $StartTop))
    } elseif ($moveNorth) {
        $fixedBottom = $StartTop + $StartHeight
        $candidateTop = $StartTop + $DeltaY
        $height = [Math]::Max($minH, [Math]::Min($frameH, ($fixedBottom - $candidateTop)))
        $top = [Math]::Max(0.0, [Math]::Min(($frameH - $height), ($fixedBottom - $height)))
    } else {
        $height = [Math]::Max($minH, [Math]::Min($frameH, $StartHeight))
        $top = [Math]::Max(0.0, [Math]::Min(($frameH - $height), $StartTop))
    }

    $availableX = [Math]::Max(0.0, $frameW - $width)
    $availableY = [Math]::Max(0.0, $frameH - $height)
    return [pscustomobject]@{
        Left = [Math]::Round($left)
        Top = [Math]::Round($top)
        Width = [Math]::Round($width)
        Height = [Math]::Round($height)
        CustomX = if ($availableX -gt 0.0) { [Math]::Round($left / $availableX, 6) } else { 0.0 }
        CustomY = if ($availableY -gt 0.0) { [Math]::Round($top / $availableY, 6) } else { 0.0 }
        CustomWidth = [Math]::Round($width / $frameW, 6)
        CustomHeight = [Math]::Round($height / $frameH, 6)
    }
}



# 1. MouseDown tren BoxLogoOverlay (Di chuyen Logo)
if ($ui.BoxLogoOverlay) {
    $ui.BoxLogoOverlay.Add_MouseLeftButtonDown({
        param($sender, $e)
        if (-not $ui.CanvasWatermark) { return }
        if (-not $script:previewingClean) {
            if (Get-Command 'Enter-CleanPreviewMode' -ErrorAction SilentlyContinue) { Enter-CleanPreviewMode }
        }
        if (Get-Command 'Select-ActiveOverlay' -ErrorAction SilentlyContinue) { Select-ActiveOverlay -Target 'logo' }
        $script:dragTarget = 'logo'
        $script:dragMode   = 'move'
        $script:dragStartPt = $e.GetPosition($ui.CanvasWatermark)
        $curL = [Windows.Controls.Canvas]::GetLeft($ui.BoxLogoOverlay)
        $curT = [Windows.Controls.Canvas]::GetTop($ui.BoxLogoOverlay)
        if ([double]::IsNaN($curL)) { $curL = 0.0 }
        if ([double]::IsNaN($curT)) { $curT = 0.0 }
        $script:dragStartPos = [System.Windows.Point]::new($curL, $curT)
        $frameW = [Math]::Max(10.0, $ui.CanvasWatermark.ActualWidth)
        $frameH = [Math]::Max(10.0, $ui.CanvasWatermark.ActualHeight)
        $boxW = $ui.BoxLogoOverlay.ActualWidth
        $boxH = $ui.BoxLogoOverlay.ActualHeight
        $maxLeft = [Math]::Max(0.0, $frameW - $boxW)
        $maxTop  = [Math]::Max(0.0, $frameH - $boxH)
        $script:logoCustomX = if ($maxLeft -gt 0) { [Math]::Round([Math]::Max(0.0, [Math]::Min($maxLeft, $curL)) / $maxLeft, 4) } else { 0.0 }
        $script:logoCustomY = if ($maxTop  -gt 0) { [Math]::Round([Math]::Max(0.0, [Math]::Min($maxTop,  $curT)) / $maxTop,  4) } else { 0.0 }
        if ($ui.CmbLogoMode -and $ui.CmbLogoMode.SelectedIndex -ne 1) {
            $ui.CmbLogoMode.SelectedIndex = 1
        }
        Set-PositionComboCustom -Target logo
        $ui.BoxLogoOverlay.CaptureMouse() | Out-Null
        $e.Handled = $true
    })
}

# 3. MouseDown tren BoxGifOverlay (Di chuyen GIF)
if ($ui.BoxGifOverlay) {
    $ui.BoxGifOverlay.Add_MouseLeftButtonDown({
        param($sender, $e)
        if (-not $ui.CanvasWatermark) { return }
        if (-not $script:previewingClean) {
            if (Get-Command 'Enter-CleanPreviewMode' -ErrorAction SilentlyContinue) { Enter-CleanPreviewMode }
        }
        if (Get-Command 'Select-ActiveOverlay' -ErrorAction SilentlyContinue) { Select-ActiveOverlay -Target 'gif' }
        $script:dragTarget = 'gif'
        $script:dragMode   = 'move'
        $script:dragStartPt = $e.GetPosition($ui.CanvasWatermark)
        $curL = [Windows.Controls.Canvas]::GetLeft($ui.BoxGifOverlay)
        $curT = [Windows.Controls.Canvas]::GetTop($ui.BoxGifOverlay)
        if ([double]::IsNaN($curL)) { $curL = 0.0 }
        if ([double]::IsNaN($curT)) { $curT = 0.0 }
        $script:dragStartPos = [System.Windows.Point]::new($curL, $curT)
        $frameW = [Math]::Max(10.0, $ui.CanvasWatermark.ActualWidth)
        $frameH = [Math]::Max(10.0, $ui.CanvasWatermark.ActualHeight)
        $boxW = $ui.BoxGifOverlay.ActualWidth
        $boxH = $ui.BoxGifOverlay.ActualHeight
        $maxLeft = [Math]::Max(0.0, $frameW - $boxW)
        $maxTop  = [Math]::Max(0.0, $frameH - $boxH)
        $script:gifCustomX = if ($maxLeft -gt 0) { [Math]::Round([Math]::Max(0.0, [Math]::Min($maxLeft, $curL)) / $maxLeft, 4) } else { 0.0 }
        $script:gifCustomY = if ($maxTop  -gt 0) { [Math]::Round([Math]::Max(0.0, [Math]::Min($maxTop,  $curT)) / $maxTop,  4) } else { 0.0 }
        Set-PositionComboCustom -Target gif
        $ui.BoxGifOverlay.CaptureMouse() | Out-Null
        $e.Handled = $true
    })
}

$resizeGrips = @(
    @{ Control=$ui.GripLogoResize;   Target='logo'; Corner='SE' },
    @{ Control=$ui.GripLogoResizeNW; Target='logo'; Corner='NW' },
    @{ Control=$ui.GripLogoResizeNE; Target='logo'; Corner='NE' },
    @{ Control=$ui.GripLogoResizeSW; Target='logo'; Corner='SW' },
    @{ Control=$ui.GripLogoResizeN; Target='logo'; Corner='N'  },
    @{ Control=$ui.GripLogoResizeS; Target='logo'; Corner='S'  },
    @{ Control=$ui.GripLogoResizeW; Target='logo'; Corner='W'  },
    @{ Control=$ui.GripLogoResizeE; Target='logo'; Corner='E'  },
    @{ Control=$ui.GripGifResize;    Target='gif';  Corner='SE' },
    @{ Control=$ui.GripGifResizeNW;  Target='gif';  Corner='NW' },
    @{ Control=$ui.GripGifResizeNE;  Target='gif';  Corner='NE' },
    @{ Control=$ui.GripGifResizeSW;  Target='gif';  Corner='SW' },
    @{ Control=$ui.GripGifResizeN;   Target='gif';  Corner='N'  },
    @{ Control=$ui.GripGifResizeS;   Target='gif';  Corner='S'  },
    @{ Control=$ui.GripGifResizeW;   Target='gif';  Corner='W'  },
    @{ Control=$ui.GripGifResizeE;   Target='gif';  Corner='E'  }
)
$resizeGripMouseDownAction = {
    param($sender, $e)
    if (-not $ui.CanvasWatermark) { return }
    $parts = ([string]$sender.Tag).Split(':')
    $target = $parts[0]
    $handle = $parts[1]
    $box = if ($target -eq 'logo') { $ui.BoxLogoOverlay } else { $ui.BoxGifOverlay }
    if (-not $box) { return }
    if (-not $script:previewingClean -and (Get-Command 'Enter-CleanPreviewMode' -ErrorAction SilentlyContinue)) { Enter-CleanPreviewMode }
    if (Get-Command 'Select-ActiveOverlay' -ErrorAction SilentlyContinue) { Select-ActiveOverlay -Target $target }

    $frameW = [Math]::Max(6.0, $ui.CanvasWatermark.ActualWidth)
    $frameH = [Math]::Max(6.0, $ui.CanvasWatermark.ActualHeight)
    $left = [Windows.Controls.Canvas]::GetLeft($box)
    $top = [Windows.Controls.Canvas]::GetTop($box)
    if ([double]::IsNaN($left)) { $left = 0.0 }
    if ([double]::IsNaN($top)) { $top = 0.0 }
    $width = if ($box.Width -gt 0.0) { [double]$box.Width } else { [double]$box.ActualWidth }
    $height = if ($box.Height -gt 0.0) { [double]$box.Height } else { [double]$box.ActualHeight }
    $script:dragResizeState = [pscustomobject]@{
        Handle=$handle; Left=$left; Top=$top; Width=$width; Height=$height
    }
    $script:dragTarget = $target
    $script:dragMode = 'resize'
    $script:dragStartPt = $e.GetPosition($ui.CanvasWatermark)

    if ($target -eq 'logo') {
        $maxLeft = [Math]::Max(0.0, $frameW - $width)
        $maxTop = [Math]::Max(0.0, $frameH - $height)
        $script:logoCustomX = if ($maxLeft -gt 0.0) { [Math]::Round($left / $maxLeft, 6) } else { 0.0 }
        $script:logoCustomY = if ($maxTop -gt 0.0) { [Math]::Round($top / $maxTop, 6) } else { 0.0 }
        if ($ui.CmbLogoMode -and $ui.CmbLogoMode.SelectedIndex -ne 1) { $ui.CmbLogoMode.SelectedIndex = 1 }
        Set-PositionComboCustom -Target logo
    } else {
        $maxLeft = [Math]::Max(0.0, $frameW - $width)
        $maxTop = [Math]::Max(0.0, $frameH - $height)
        $script:gifCustomX = if ($maxLeft -gt 0.0) { [Math]::Round($left / $maxLeft, 6) } else { 0.0 }
        $script:gifCustomY = if ($maxTop -gt 0.0) { [Math]::Round($top / $maxTop, 6) } else { 0.0 }
        if ($script:gifFullFrame) {
            $script:gifCustomWidth = [Math]::Round($width / $frameW, 6)
            $script:gifCustomHeight = [Math]::Round($height / $frameH, 6)
            Reset-GifFullFrame -PreserveCustomSize
        }
        Set-PositionComboCustom -Target gif
    }
    $sender.CaptureMouse() | Out-Null
    $e.Handled = $true
}
$ui.GripLogoResize.Tag = 'logo:SE'
$ui.GripLogoResize.Add_MouseLeftButtonDown($resizeGripMouseDownAction)
$ui.GripGifResize.Tag = 'gif:SE'
$ui.GripGifResize.Add_MouseLeftButtonDown($resizeGripMouseDownAction)
foreach ($gripSpec in $resizeGrips | Where-Object { $_.Corner -ne 'SE' }) {
    if (-not $gripSpec.Control) { continue }
    $gripSpec.Control.Tag = "$($gripSpec.Target):$($gripSpec.Corner)"
    $gripSpec.Control.Add_MouseLeftButtonDown($resizeGripMouseDownAction)
}

# 5. MouseMove tren CanvasWatermark & Controls (Dieu khien toa do & kich thuoc lien tuc, muot ma toi 4 goc)
if ($ui.CanvasWatermark) {
    $ui.CanvasWatermark.Add_MouseMove({
        param($sender, $e)
        if (-not $script:dragTarget -or -not $script:dragMode) { return }
        $frameW = [Math]::Max(6.0, $ui.CanvasWatermark.ActualWidth)
        $frameH = [Math]::Max(6.0, $ui.CanvasWatermark.ActualHeight)
        $curPt = $e.GetPosition($ui.CanvasWatermark)

        if ($script:dragTarget -eq 'logo' -and $ui.BoxLogoOverlay) {
            if ($script:dragMode -eq 'move') {
                $deltaX = $curPt.X - $script:dragStartPt.X
                $deltaY = $curPt.Y - $script:dragStartPt.Y
                $boxW = $ui.BoxLogoOverlay.ActualWidth
                $boxH = $ui.BoxLogoOverlay.ActualHeight
                $maxLeft = [Math]::Max(0.0, $frameW - $boxW)
                $maxTop = [Math]::Max(0.0, $frameH - $boxH)
                $left = [Math]::Max(0.0, [Math]::Min($maxLeft, $script:dragStartPos.X + $deltaX))
                $top = [Math]::Max(0.0, [Math]::Min($maxTop, $script:dragStartPos.Y + $deltaY))
                [Windows.Controls.Canvas]::SetLeft($ui.BoxLogoOverlay, [Math]::Round($left))
                [Windows.Controls.Canvas]::SetTop($ui.BoxLogoOverlay, [Math]::Round($top))
                $script:logoCustomX = if ($maxLeft -gt 0.0) { [Math]::Round($left / $maxLeft, 6) } else { 0.0 }
                $script:logoCustomY = if ($maxTop -gt 0.0) { [Math]::Round($top / $maxTop, 6) } else { 0.0 }
                Set-PositionComboCustom -Target logo
                if ($ui.CmbLogoMode -and $ui.CmbLogoMode.SelectedIndex -ne 1) { $ui.CmbLogoMode.SelectedIndex = 1 }
            } elseif ($script:dragMode -eq 'resize') {
                $resize = $script:dragResizeState
                if (-not $resize) { return }
                $layout = Get-OverlayFreeResizeGeometry -FrameWidth $frameW -FrameHeight $frameH `
                    -StartLeft $resize.Left -StartTop $resize.Top -StartWidth $resize.Width -StartHeight $resize.Height `
                    -DeltaX ($curPt.X - $script:dragStartPt.X) -DeltaY ($curPt.Y - $script:dragStartPt.Y) -Handle $resize.Handle
                $script:logoCustomX = $layout.CustomX; $script:logoCustomY = $layout.CustomY
                $script:logoCustomWidth = $layout.CustomWidth; $script:logoCustomHeight = $layout.CustomHeight
                if ($ui.CmbLogoMode -and $ui.CmbLogoMode.SelectedIndex -ne 1) { $ui.CmbLogoMode.SelectedIndex = 1 }
                Set-PositionComboCustom -Target logo
                [Windows.Controls.Canvas]::SetLeft($ui.BoxLogoOverlay, $layout.Left)
                [Windows.Controls.Canvas]::SetTop($ui.BoxLogoOverlay, $layout.Top)
                if ($ui.TxtLogoSize) { $ui.TxtLogoSize.Text = 'Rộng {0}% · Cao {1}%' -f [int][Math]::Round($layout.CustomWidth * 100.0), [int][Math]::Round($layout.CustomHeight * 100.0) }
                if (Get-Command 'Update-WatermarkOverlay' -ErrorAction SilentlyContinue) { Update-WatermarkOverlay }
                if (Get-Command 'Update-WatermarkSummary' -ErrorAction SilentlyContinue) { Update-WatermarkSummary }
            }
        } elseif ($script:dragTarget -eq 'gif' -and $ui.BoxGifOverlay) {
            if ($script:dragMode -eq 'move') {
                $deltaX = $curPt.X - $script:dragStartPt.X
                $deltaY = $curPt.Y - $script:dragStartPt.Y
                $boxW = $ui.BoxGifOverlay.ActualWidth
                $boxH = $ui.BoxGifOverlay.ActualHeight
                $maxLeft = [Math]::Max(0.0, $frameW - $boxW)
                $maxTop = [Math]::Max(0.0, $frameH - $boxH)
                $left = [Math]::Max(0.0, [Math]::Min($maxLeft, $script:dragStartPos.X + $deltaX))
                $top = [Math]::Max(0.0, [Math]::Min($maxTop, $script:dragStartPos.Y + $deltaY))
                [Windows.Controls.Canvas]::SetLeft($ui.BoxGifOverlay, [Math]::Round($left))
                [Windows.Controls.Canvas]::SetTop($ui.BoxGifOverlay, [Math]::Round($top))
                $script:gifCustomX = if ($maxLeft -gt 0.0) { [Math]::Round($left / $maxLeft, 6) } else { 0.0 }
                $script:gifCustomY = if ($maxTop -gt 0.0) { [Math]::Round($top / $maxTop, 6) } else { 0.0 }
                Set-PositionComboCustom -Target gif
            } elseif ($script:dragMode -eq 'resize') {
                $resize = $script:dragResizeState
                if (-not $resize) { return }
                $layout = Get-OverlayFreeResizeGeometry -FrameWidth $frameW -FrameHeight $frameH `
                    -StartLeft $resize.Left -StartTop $resize.Top -StartWidth $resize.Width -StartHeight $resize.Height `
                    -DeltaX ($curPt.X - $script:dragStartPt.X) -DeltaY ($curPt.Y - $script:dragStartPt.Y) -Handle $resize.Handle
                $script:gifCustomX = $layout.CustomX; $script:gifCustomY = $layout.CustomY
                $script:gifCustomWidth = $layout.CustomWidth; $script:gifCustomHeight = $layout.CustomHeight
                if ($script:gifFullFrame) { Reset-GifFullFrame -PreserveCustomSize }
                Set-PositionComboCustom -Target gif
                [Windows.Controls.Canvas]::SetLeft($ui.BoxGifOverlay, $layout.Left)
                [Windows.Controls.Canvas]::SetTop($ui.BoxGifOverlay, $layout.Top)
                if ($ui.TxtGifSize) { $ui.TxtGifSize.Text = 'Rộng {0}% · Cao {1}%' -f [int][Math]::Round($layout.CustomWidth * 100.0), [int][Math]::Round($layout.CustomHeight * 100.0) }
                if (Get-Command 'Update-WatermarkOverlay' -ErrorAction SilentlyContinue) { Update-WatermarkOverlay }
                if (Get-Command 'Update-WatermarkSummary' -ErrorAction SilentlyContinue) { Update-WatermarkSummary }
            }
        }
        $e.Handled = $true
    })
}

# 6. Giai phong chuot an toan (MouseUp & LostMouseCapture) - khong huy ngang khi chuot ra ngoai Canvas
$cleanupDragAction = {
    param($sender, $e)
    if ($script:dragTarget -or $script:dragMode) {
        $captureOwners = @($ui.BoxLogoOverlay,$ui.GripLogoResize,$ui.GripLogoResizeNW,$ui.GripLogoResizeNE,$ui.GripLogoResizeSW,$ui.GripLogoResizeN,$ui.GripLogoResizeS,$ui.GripLogoResizeW,$ui.GripLogoResizeE,
            $ui.BoxGifOverlay,$ui.GripGifResize,$ui.GripGifResizeNW,$ui.GripGifResizeNE,$ui.GripGifResizeSW,$ui.GripGifResizeN,$ui.GripGifResizeS,$ui.GripGifResizeW,$ui.GripGifResizeE) |
            Where-Object { $_ -and $_.IsMouseCaptured }
        $script:dragTarget       = $null
        $script:dragMode         = $null
        $script:dragStartPt      = $null
        $script:dragStartPos     = $null
        $script:dragStartPercent = $null
        $script:dragResizeState  = $null
        foreach ($captureOwner in $captureOwners) {
            if ($captureOwner.IsMouseCaptured) { $captureOwner.ReleaseMouseCapture() | Out-Null }
        }
        if ($e) { $e.Handled = $true }
    }
}

if ($ui.BoxLogoOverlay)    {
    $ui.BoxLogoOverlay.Add_MouseLeftButtonUp($cleanupDragAction)
    $ui.BoxLogoOverlay.Add_LostMouseCapture($cleanupDragAction)
}
if ($ui.BoxGifOverlay)     {
    $ui.BoxGifOverlay.Add_MouseLeftButtonUp($cleanupDragAction)
    $ui.BoxGifOverlay.Add_LostMouseCapture($cleanupDragAction)
}
$ui.GripLogoResize.Add_MouseLeftButtonUp($cleanupDragAction)
$ui.GripLogoResize.Add_LostMouseCapture($cleanupDragAction)
$ui.GripGifResize.Add_MouseLeftButtonUp($cleanupDragAction)
$ui.GripGifResize.Add_LostMouseCapture($cleanupDragAction)
$allOverlayResizeGrips = @($ui.GripLogoResizeNW,$ui.GripLogoResizeNE,$ui.GripLogoResizeSW,$ui.GripLogoResizeN,$ui.GripLogoResizeS,$ui.GripLogoResizeW,$ui.GripLogoResizeE,
    $ui.GripGifResizeNW,$ui.GripGifResizeNE,$ui.GripGifResizeSW,$ui.GripGifResizeN,$ui.GripGifResizeS,$ui.GripGifResizeW,$ui.GripGifResizeE)
foreach ($grip in $allOverlayResizeGrips) {
    if ($grip) {
        $grip.Add_MouseLeftButtonUp($cleanupDragAction)
        $grip.Add_LostMouseCapture($cleanupDragAction)
    }
}
if ($ui.CanvasWatermark)   {
    $ui.CanvasWatermark.Add_MouseLeftButtonUp($cleanupDragAction)
}

# 7. MouseWheel (Lan chuot truc tiep tren Overlay de doi co)
if ($ui.BoxLogoOverlay) {
    $ui.BoxLogoOverlay.Add_MouseWheel({
        param($sender, $e)
        if (-not $ui.SldLogoSize) { return }
        $step = [Math]::Sign($e.Delta) * 2.0
        $newVal = [Math]::Max($ui.SldLogoSize.Minimum, [Math]::Min($ui.SldLogoSize.Maximum, $ui.SldLogoSize.Value + $step))
        $ui.SldLogoSize.Value = $newVal
        if (Get-Command 'Enter-CleanPreviewMode' -ErrorAction SilentlyContinue) { Enter-CleanPreviewMode }
        $e.Handled = $true
    })
}
if ($ui.BoxGifOverlay) {
    $ui.BoxGifOverlay.Add_MouseWheel({
        param($sender, $e)
        if (-not $ui.SldGifSize) { return }
        if ($script:gifFullFrame) { Reset-GifFullFrame }
        $step = [Math]::Sign($e.Delta) * 2.0
        $newVal = [Math]::Max($ui.SldGifSize.Minimum, [Math]::Min($ui.SldGifSize.Maximum, $ui.SldGifSize.Value + $step))
        $ui.SldGifSize.Value = $newVal
        if (Get-Command 'Enter-CleanPreviewMode' -ErrorAction SilentlyContinue) { Enter-CleanPreviewMode }
        if (Get-Command 'Update-WatermarkOverlay' -ErrorAction SilentlyContinue) { Update-WatermarkOverlay }
        if (Get-Command 'Update-WatermarkSummary' -ErrorAction SilentlyContinue) { Update-WatermarkSummary }
        $e.Handled = $true
    })
}
# --- HE THONG PHIM TAT CHUYEN NGHIEP (CapCut / Premiere Style) ---
$win.Add_PreviewKeyDown({
    param($sender, $e)
    # Phim tat toan cuc (ca khi dang go trong o link): Ctrl+Enter = Bat dau, Esc = Dung (xac nhan), Ctrl+1..5 = chuyen trang.
    $mods = [System.Windows.Input.Keyboard]::Modifiers
    $ctrlOnly = ($mods -eq [System.Windows.Input.ModifierKeys]::Control)
    if ($ctrlOnly -and $e.Key -eq [System.Windows.Input.Key]::Return) {
        if (-not (Test-QueueRunning)) { Start-QueueFromInput } else { Show-Toast 'Hàng đợi đang chạy.' }
        $e.Handled = $true; return
    }
    if ($e.Key -eq [System.Windows.Input.Key]::Escape -and $mods -eq [System.Windows.Input.ModifierKeys]::None) {
        $focusedCombo = [System.Windows.Input.Keyboard]::FocusedElement
        if ($focusedCombo -is [System.Windows.Controls.ComboBox] -and $focusedCombo.IsDropDownOpen) { return }
        # "Xem lon" thoat truoc; chi khi khong o che do do moi tinh toi viec dung hang doi.
        if ($script:previewBig) { Set-PreviewBig $false; $e.Handled = $true; return }
        if ($script:currentPage -eq 'library' -and $ui.GalleryList.SelectedItems.Count -gt 1) { Clear-GallerySelection; $e.Handled = $true; return }
        if (Test-QueueRunning) { Request-Stop -Confirm; $e.Handled = $true; return }
    }
    if ($ctrlOnly) {
        $pageKey = switch ($e.Key) { 'D1' { 'source' } 'NumPad1' { 'source' } 'D2' { 'brand' } 'NumPad2' { 'brand' } 'D3' { 'queue' } 'NumPad3' { 'queue' }
                                     'D4' { 'library' } 'NumPad4' { 'library' } 'D5' { 'settings' } 'NumPad5' { 'settings' } default { $null } }
        if ($pageKey) { Show-Page $pageKey; $e.Handled = $true; return }
    }
    # Khong kich hoat phim tat neu dang nhap lieu hoac dang focus control can phim do
    $kbd = [System.Windows.Input.Keyboard]::FocusedElement
    if ($kbd) {
        if ($kbd -is [System.Windows.Controls.Primitives.TextBoxBase] -or
            $kbd -is [System.Windows.Controls.PasswordBox] -or
            ($kbd -is [System.Windows.Controls.ComboBox] -and $kbd.IsEditable)) {
            return
        }
        if ($e.Key -eq [System.Windows.Input.Key]::Space -and
            ($kbd -is [System.Windows.Controls.Primitives.ButtonBase] -or
             $kbd -is [System.Windows.Controls.Primitives.ToggleButton] -or
             $kbd -is [System.Windows.Controls.CheckBox])) {
            return
        }
        if (($e.Key -eq [System.Windows.Input.Key]::Left -or $e.Key -eq [System.Windows.Input.Key]::Right) -and
            (($kbd -is [System.Windows.Controls.Slider] -and $kbd -ne $ui.Seek) -or
             $kbd -is [System.Windows.Controls.ComboBox] -or
             $kbd -is [System.Windows.Controls.Primitives.ScrollBar])) {
            return
        }
    }

    # Space: Phat / Tam dung video an toan (chi kich hoat khi video da load va player dang hien thi)
    if ($e.Key -eq [System.Windows.Input.Key]::Space) {
        if ($ui.BtnPlay -and $ui.BtnPlay.IsEnabled -and $ui.Player.Source -and $ui.PanelPlay.Visibility -eq 'Visible') {
            $ui.BtnPlay.RaiseEvent((New-Object Windows.RoutedEventArgs ([System.Windows.Controls.Button]::ClickEvent)))
            $e.Handled = $true
        }
    }
    # F: Xem lon (bat/tat) khi dang o trang co khung xem truoc
    elseif ($e.Key -eq [System.Windows.Input.Key]::F -and -not [System.Windows.Input.Keyboard]::Modifiers) {
        if (Test-PreviewPageVisible) { Set-PreviewBig (-not $script:previewBig); $e.Handled = $true }
    }
    # Mui ten Trai: Tua lui 3 giay
    elseif ($e.Key -eq [System.Windows.Input.Key]::Left) {
        if ($ui.Player -and $ui.Player.Source -and $ui.Player.NaturalDuration.HasTimeSpan -and -not $script:keoSeek -and $ui.PanelPlay.Visibility -eq 'Visible') {
            $curSec = $ui.Player.Position.TotalSeconds
            $totSec = $ui.Player.NaturalDuration.TimeSpan.TotalSeconds
            $targetSec = [Math]::Max(0.0, $curSec - 3.0)
            $script:suppressSeekSyncUntil = [System.Diagnostics.Stopwatch]::GetTimestamp() + [long]([System.Diagnostics.Stopwatch]::Frequency * 0.40)
            $ui.Player.Position = [TimeSpan]::FromSeconds($targetSec)
            if ($ui.Seek) { $ui.Seek.Value = $targetSec }
            $ui.TxtTime.Text = (Format-VideoTime $targetSec) + ' / ' + (Format-VideoTime $totSec)
            if ($ui.BtnPlay -and $ui.BtnPlay.Content -match 'Phát') {
                try {
                    $ui.Player.Play()
                    $ui.Player.Pause()
                } catch { Write-FileLogLimited 'player-seek' "WARN Play/Pause sau khi tua: $($_.Exception.Message)" }
            }
            if ($ui.CmbLogoMode -and $ui.CmbLogoMode.SelectedIndex -eq 0) {
                if (Get-Command 'Update-WatermarkOverlay' -ErrorAction SilentlyContinue) { Update-WatermarkOverlay }
            }
            $e.Handled = $true
        }
    }
    # Mui ten Phai: Tua toi 3 giay
    elseif ($e.Key -eq [System.Windows.Input.Key]::Right) {
        if ($ui.Player -and $ui.Player.Source -and $ui.Player.NaturalDuration.HasTimeSpan -and -not $script:keoSeek -and $ui.PanelPlay.Visibility -eq 'Visible') {
            $curSec = $ui.Player.Position.TotalSeconds
            $totSec = $ui.Player.NaturalDuration.TimeSpan.TotalSeconds
            $targetSec = [Math]::Min($totSec, $curSec + 3.0)
            $script:suppressSeekSyncUntil = [System.Diagnostics.Stopwatch]::GetTimestamp() + [long]([System.Diagnostics.Stopwatch]::Frequency * 0.40)
            $ui.Player.Position = [TimeSpan]::FromSeconds($targetSec)
            if ($ui.Seek) { $ui.Seek.Value = $targetSec }
            $ui.TxtTime.Text = (Format-VideoTime $targetSec) + ' / ' + (Format-VideoTime $totSec)
            if ($ui.BtnPlay -and $ui.BtnPlay.Content -match 'Phát') {
                try {
                    $ui.Player.Play()
                    $ui.Player.Pause()
                } catch { Write-FileLogLimited 'player-seek' "WARN Play/Pause sau khi tua: $($_.Exception.Message)" }
            }
            if ($ui.CmbLogoMode -and $ui.CmbLogoMode.SelectedIndex -eq 0) {
                if (Get-Command 'Update-WatermarkOverlay' -ErrorAction SilentlyContinue) { Update-WatermarkOverlay }
            }
            $e.Handled = $true
        }
    }
    # T hoac Ctrl+Tab: Chuyen doi Track A va Track B (Tra phim Tab don thuan cho he thong de chuyen focus)
    elseif (($e.Key -eq [System.Windows.Input.Key]::T -and -not [System.Windows.Input.Keyboard]::Modifiers) -or
            ($e.Key -eq [System.Windows.Input.Key]::Tab -and ([System.Windows.Input.Keyboard]::Modifiers -band [System.Windows.Input.ModifierKeys]::Control))) {
        if ($ui.PanelRev -and $ui.PanelRev.Visibility -eq 'Visible') {
            $nextTrack = if ($script:activeTrack -eq 'A') { 'B' } else { 'A' }
            Switch-AudioTrack $nextTrack
            $e.Handled = $true
        }
    }
    # Ctrl + C: Copy file video de re-up
    elseif ($e.Key -eq [System.Windows.Input.Key]::C -and ([System.Windows.Input.Keyboard]::Modifiers -band [System.Windows.Input.ModifierKeys]::Control)) {
        if ($ui.BtnCopyReup -and $ui.BtnCopyReup.IsEnabled -and $ui.PanelRev -and $ui.PanelRev.Visibility -eq 'Visible') {
            if ($script:lastOut) { Copy-ToClipboard $script:lastOut }
            $e.Handled = $true
        }
    }
    # Shift + Delete: Xoa video hien tai an toan
    elseif ($e.Key -eq [System.Windows.Input.Key]::Delete -and ([System.Windows.Input.Keyboard]::Modifiers -band [System.Windows.Input.ModifierKeys]::Shift)) {
        if ($ui.BtnDeleteCurrent -and $ui.BtnDeleteCurrent.IsEnabled -and $ui.PanelRev -and $ui.PanelRev.Visibility -eq 'Visible') {
            $ui.BtnDeleteCurrent.RaiseEvent((New-Object Windows.RoutedEventArgs ([System.Windows.Controls.MenuItem]::ClickEvent)))
            $e.Handled = $true
        }
    }
    # Ctrl + R: Ghi am lai (Redo) an toan
    elseif ($e.Key -eq [System.Windows.Input.Key]::R -and ([System.Windows.Input.Keyboard]::Modifiers -band [System.Windows.Input.ModifierKeys]::Control)) {
        if ($ui.BtnRedo -and $ui.BtnRedo.IsEnabled -and $ui.PanelRev -and $ui.PanelRev.Visibility -eq 'Visible') {
            $ui.BtnRedo.RaiseEvent((New-Object Windows.RoutedEventArgs ([System.Windows.Controls.MenuItem]::ClickEvent)))
            $e.Handled = $true
        }
    }
})

if ($ui.BadgePreviewMode) {
    $ui.BadgePreviewMode.Add_MouseDown({
        Exit-CleanPreviewMode
    })
}

try { Set-LogoSelection -Path '' } catch { Add-Log 'Không đọc được ảnh xem trước logo Kid.' 'Warning' }
try { Set-GifSelection -Path '' } catch { Write-FileLog "WARN nap GIF mac dinh: $($_.Exception.Message)" }
try {
    if (Get-Command 'Update-PhoneFrameSize' -ErrorAction SilentlyContinue) { Update-PhoneFrameSize }
    if (Get-Command 'Update-WatermarkOverlay' -ErrorAction SilentlyContinue) { Update-WatermarkOverlay }
} catch { Write-FileLog "WARN khoi tao khung xem truoc: $($_.Exception.Message)" }
function Open-FolderSafe([string]$targetPath) {
    try {
        if (-not $targetPath -or $targetPath.Trim() -eq '') {
            $targetPath = Get-KhoDownloadPath
        }
        $p = [System.IO.Path]::GetFullPath($targetPath)
        if (-not (Test-Path -LiteralPath $p)) {
            # CreateDirectory khong dien giai wildcard [] nhu New-Item -Path.
            [void][System.IO.Directory]::CreateDirectory($p)
        }
        [System.Diagnostics.Process]::Start("explorer.exe", "`"$p`"") | Out-Null
    } catch {
        try {
            Start-Process explorer.exe -ArgumentList "`"$targetPath`""
        } catch { Write-FileLog "WARN mo Explorer du phong: $($_.Exception.Message)" }
    }
}

$ui.BtnOpenOut.Add_Click({ Open-FolderSafe (Get-KhoDownloadPath) })
# "Mo thu muc" duoi video: thu muc kho chua video dang xem; chua xem video nao thi mo kho tai ve.
$ui.BtnFolder.Add_Click({
    $dir = $(if ($script:lastOut) { [IO.Path]::GetDirectoryName([IO.Path]::GetFullPath([string]$script:lastOut)) } else { Get-KhoDownloadPath })
    Open-FolderSafe $dir
})
function Invoke-DeviceCheck {
    # ShowLogs: chi chuyen sang tab Logs khi nguoi dung bam nut; kiem tra nen luc khoi dong giu tab hien tai.
    param([switch]$ShowLogs)
    try {
        if ($ShowLogs) { Show-Page 'settings' -Sub 'logs' }
        Start-Engine -Links @() -Named @{ Check = $true } -Mode 'check'
    } catch {
        Add-Log "Không chạy được kiểm tra máy: $($_.Exception.Message)" 'Danger'
    }
}
$ui.BtnCheck.Add_Click({ Invoke-DeviceCheck -ShowLogs })

function Request-Stop {
    # Nut chinh (khi dang chay) va Esc dung CUNG mot quy tac (G-E2E):
    # con >= 1 muc chua chay -> hoi xac nhan (nut mac dinh = tiep tuc chay); chi con muc dang chay -> dung ngay.
    param([switch]$Confirm)   # giu tham so cu cho tuong thich; quy tac khong phu thuoc no
    if (-not $script:ps -or $script:stopping) { return }
    $left = Get-QueuePendingCount
    if ($left -ge 1) {
        $msg = "Còn $left video chưa chạy sẽ bị hủy; video đang xử lý dừng giữa chừng. Các video đã lưu được giữ nguyên."
        if (-not (Show-ConfirmDialog -Title 'Dừng hàng đợi?' -Message $msg -ConfirmText 'Dừng' -CancelText 'Tiếp tục chạy' -Danger)) { return }
    }
    Stop-Engine
    Add-Log ''; Add-Log 'Đã dừng theo yêu cầu của người dùng.' 'Warning'
    Update-ActionBar
}
$ui.BtnReedit.Add_Click({ Start-Reedit })
$ui.BtnPlay.Add_Click({
    if (-not $ui.Player.Source) { return }
    if ($ui.BtnPlay.Content -match 'Phát') {
        $ui.Player.Play()
        $ui.BtnPlay.Content = 'Tạm dừng'
    } else {
        $ui.Player.Pause()
        $ui.BtnPlay.Content = 'Phát'
    }
})

# XU LY TUA VIDEO SIEU MUOT - KHONG BI LAG / DUOI CODEC
$finishSeekAction = {
    if (-not $script:keoSeek) { return }
    $script:keoSeek = $false
    if ($ui.Seek.IsMouseCaptured) { $ui.Seek.ReleaseMouseCapture() }
    $script:suppressSeekSyncUntil = [System.Diagnostics.Stopwatch]::GetTimestamp() + [long]([System.Diagnostics.Stopwatch]::Frequency * 0.40)
    if ($ui.Player.Source) {
        $targetSec = $ui.Seek.Value
        $ui.Player.Position = [TimeSpan]::FromSeconds($targetSec)
        $tot = if ($ui.Player.NaturalDuration.HasTimeSpan) { $ui.Player.NaturalDuration.TimeSpan.TotalSeconds } else { 0.0 }
        $ui.TxtTime.Text = (Format-VideoTime $targetSec) + ' / ' + (Format-VideoTime $tot)
        if ($script:wasPlaying) {
            try { $ui.Player.Play() } catch { Write-FileLogLimited 'player-seek' "WARN Play sau khi tua: $($_.Exception.Message)" }
            if ($ui.BtnPlay) { $ui.BtnPlay.Content = 'Tạm dừng' }
        } else {
            try {
                $ui.Player.Play()
                $ui.Player.Pause()
            } catch { Write-FileLogLimited 'player-seek' "WARN Play/Pause sau khi tua: $($_.Exception.Message)" }
        }
        if ($ui.CmbLogoMode -and $ui.CmbLogoMode.SelectedIndex -eq 0) {
            if (Get-Command 'Update-WatermarkOverlay' -ErrorAction SilentlyContinue) { Update-WatermarkOverlay }
        }
    }
}

function Update-SeekFromPointer {
    param($EventArgs)
    if (-not $EventArgs -or -not $ui.Seek -or -not $ui.Player.Source) { return }
    $ui.Seek.ApplyTemplate() | Out-Null
    $track = $ui.Seek.Template.FindName('PART_Track', $ui.Seek)
    if (-not $track -or $track.ActualWidth -le 0.0) { return }
    # Map absolute track geometry: ValueFromPoint depends on a thumb layout that may lag rapid input.
    $point = $EventArgs.GetPosition($track)
    $thumbWidth = if ($track.Thumb) { $track.Thumb.ActualWidth } else { 0.0 }
    $travel = [Math]::Max(1.0, $track.ActualWidth - $thumbWidth)
    $fraction = [Math]::Max(0.0, [Math]::Min(1.0, ($point.X - $thumbWidth / 2.0) / $travel))
    if ($ui.Seek.IsDirectionReversed) { $fraction = 1.0 - $fraction }
    $value = $ui.Seek.Minimum + $fraction * ($ui.Seek.Maximum - $ui.Seek.Minimum)
    if ([double]::IsNaN($value) -or [double]::IsInfinity($value)) { return }
    $ui.Seek.Value = [Math]::Max($ui.Seek.Minimum, [Math]::Min($ui.Seek.Maximum, $value))
}

$ui.Seek.Add_PreviewMouseLeftButtonDown({
    param($sender, $e)
    if (-not $ui.Player.Source) { return }
    $script:keoSeek = $true
    $script:wasPlaying = ($ui.BtnPlay.Content -match 'Tạm dừng')
    if ($script:wasPlaying) { $ui.Player.Pause() }
    if ($e) {
        # Own the gesture so Thumb/default move-to-point capture cannot end it early.
        $e.Handled = $true
        $ui.Seek.CaptureMouse() | Out-Null
        Update-SeekFromPointer $e
    }
})
$ui.Seek.Add_PreviewMouseMove({
    param($sender, $e)
    if ($script:keoSeek -and $ui.Seek.IsMouseCaptured -and $e.LeftButton -eq [Windows.Input.MouseButtonState]::Pressed) {
        Update-SeekFromPointer $e
        $e.Handled = $true
    }
})
$ui.Seek.Add_PreviewMouseLeftButtonUp({
    param($sender, $e)
    if ($script:keoSeek) { Update-SeekFromPointer $e; & $finishSeekAction; $e.Handled = $true }
})
$ui.Seek.Add_LostMouseCapture({ & $finishSeekAction })
$win.Add_PreviewMouseLeftButtonUp({
    param($sender, $e)
    if ($script:keoSeek) { Update-SeekFromPointer $e; & $finishSeekAction }
})

$script:lastSeekTicks = 0
$ui.Seek.Add_ValueChanged({
    if ($script:keoSeek -and $ui.Player.Source) {
        $targetSec = $ui.Seek.Value
        $tot = if ($ui.Player.NaturalDuration.HasTimeSpan) { $ui.Player.NaturalDuration.TimeSpan.TotalSeconds } else { 0.0 }
        $ui.TxtTime.Text = (Format-VideoTime $targetSec) + ' / ' + (Format-VideoTime $tot)

        # Throttle live seek to ~80ms to avoid media decoder exhaustion
        $now = [System.Diagnostics.Stopwatch]::GetTimestamp()
        $freq = [System.Diagnostics.Stopwatch]::Frequency
        if (($now - $script:lastSeekTicks) / $freq -ge 0.080) {
            $script:lastSeekTicks = $now
            $ui.Player.Position = [TimeSpan]::FromSeconds($targetSec)
            if ($ui.CmbLogoMode -and $ui.CmbLogoMode.SelectedIndex -eq 0) {
                if (Get-Command 'Update-WatermarkOverlay' -ErrorAction SilentlyContinue) { Update-WatermarkOverlay }
            }
        }
    }
})

$ui.Player.Add_MediaEnded({
    $ui.Player.Pause()
    $ui.BtnPlay.Content = 'Phát'
})

$ui.BtnTrackA.Add_Click({ Switch-AudioTrack 'A' })
$ui.BtnTrackB.Add_Click({ Switch-AudioTrack 'B' })

$ui.BtnCopyReup.Add_Click({
    if (-not $script:lastOut) { return }
    if (Test-TikTokEnabled) { Show-TikTokPublishDialog -FilePath $script:lastOut } else { Copy-ToClipboard $script:lastOut }
})

$ui.BtnOpenExt.Add_Click({
    if ($script:lastOut -and (Test-Path -LiteralPath $script:lastOut)) {
        Start-Process $script:lastOut
    }
})

$ui.BtnRedo.Add_Click({ Start-RecordingAgain })

# Nut "..." duoi video: mo menu (Ghi am lai / Mo thu muc / Mo bang trinh phat ngoai / Xoa).
$ui.BtnMore.Add_Click({
    $ui.MenuMore.PlacementTarget = $ui.BtnMore
    $ui.MenuMore.Placement = [Windows.Controls.Primitives.PlacementMode]::Top
    $ui.MenuMore.IsOpen = $true
})
$ui.BtnPreviewExpand.Add_Click({ Set-PreviewBig (-not $script:previewBig) })
$ui.BtnPolicyHelp.Add_Click({ $ui.PopPolicy.IsOpen = (-not $ui.PopPolicy.IsOpen) })

# Thanh dieu khien + nut Xem lon phu tren video: hien khi re chuot, tu an sau 2 s khong re chuot.
$script:overlayLastMove = [Diagnostics.Stopwatch]::GetTimestamp()
function Set-PlayOverlayVisible {
    param([bool]$On)
    $op = $(if ($On) { 1.0 } else { 0.0 })
    foreach ($el in @($ui.PlayBarHost, $ui.BtnPreviewExpand)) {
        if ($el -and $el.Opacity -ne $op) { $el.Opacity = $op }
        if ($el) { $el.IsHitTestVisible = $On }
    }
}
function Show-PlayOverlay {
    $script:overlayLastMove = [Diagnostics.Stopwatch]::GetTimestamp()
    Set-PlayOverlayVisible $true
}
$ui.PlayerContainer.Add_MouseMove({ Show-PlayOverlay })
$ui.PlayerContainer.Add_MouseEnter({ Show-PlayOverlay })
$script:overlayTimer = New-Object Windows.Threading.DispatcherTimer
$script:overlayTimer.Interval = [TimeSpan]::FromMilliseconds(250)
$script:overlayTimer.Add_Tick({
    if ($script:dragTarget) { Set-PlayOverlayVisible $false; return }   # dang keo logo/GIF: khong de thanh phu che
    $idle = ([Diagnostics.Stopwatch]::GetTimestamp() - $script:overlayLastMove) / [double][Diagnostics.Stopwatch]::Frequency
    if ($idle -lt 2.0 -or $script:keoSeek) { return }
    if ($ui.PlayBarHost.IsMouseOver -or $ui.BtnPreviewExpand.IsMouseOver -or $ui.Seek.IsKeyboardFocusWithin -or $ui.BtnPlay.IsKeyboardFocusWithin -or $ui.BtnPreviewExpand.IsKeyboardFocusWithin) { return }
    Set-PlayOverlayVisible $false
})
$script:overlayTimer.Start()
Set-PlayOverlayVisible $true

function Update-StepListTemplate {
    # Man hinh thap: the 7 buoc thu thanh 1 dong cham (cao 36); binh thuong dung mau day du trong XAML.
    if (-not $ui.StepList) { return }
    if (-not $script:stepTemplateFull) { $script:stepTemplateFull = $ui.StepList.ItemTemplate }
    $ui.StepList.ItemTemplate = $(if ($script:compactLayout) { $win.FindResource('StepTemplateCompact') } else { $script:stepTemplateFull })
    if ($ui.TxtStepTitle) { $ui.TxtStepTitle.Visibility = $(if ($script:compactLayout) { 'Collapsed' } else { 'Visible' }) }
}

# Thu muc xuat: hien dang rut gon GIUA ("C:\...\output") khi khong sua; day du trong tooltip va khi dang go.
function Get-MiddleTrimmedPath {
    param([string]$Path, [double]$MaxWidth, $Block)
    if ([string]::IsNullOrEmpty($Path) -or $MaxWidth -le 20) { return $Path }
    $tf = New-Object Windows.Media.Typeface($Block.FontFamily, $Block.FontStyle, $Block.FontWeight, $Block.FontStretch)
    $dpi = 1.0; try { $dpi = [Windows.Media.VisualTreeHelper]::GetDpi($Block).PixelsPerDip } catch { $dpi = 1.0 }
    $measure = { param($t) (New-Object Windows.Media.FormattedText($t, [Globalization.CultureInfo]::CurrentUICulture, [Windows.FlowDirection]::LeftToRight, $tf, $Block.FontSize, [Windows.Media.Brushes]::Black, $dpi)).Width }
    if ((& $measure $Path) -le $MaxWidth) { return $Path }
    $parts = @($Path -split '[\\/]' | Where-Object { $_ -ne '' })
    $ellipsis = [string][char]0x2026
    if ($parts.Count -ge 3) {
        $first = $parts[0] + '\'
        for ($k = $parts.Count - 2; $k -ge 1; $k--) {
            $cand = $first + $ellipsis + '\' + (($parts[($parts.Count - $k)..($parts.Count - 1)]) -join '\')
            if ((& $measure $cand) -le $MaxWidth) { return $cand }
        }
    }
    $tail = $parts[$parts.Count - 1]
    $cand = $(if ($parts.Count -ge 2) { $parts[0] + '\' + $ellipsis + '\' + $tail } else { $tail })
    while ($cand.Length -gt 4 -and (& $measure $cand) -gt $MaxWidth) { $cand = $cand.Substring(0, $cand.Length - 2) + $ellipsis }
    return $cand
}
function Update-OutPathDisplay {
    # Duong dan kho tai ve (TxtOut an) hien rut gon GIUA trong the "Kho tai ve"; day du trong tooltip.
    if (-not $ui.TxtOutShort -or -not $ui.TxtOut) { return }
    $pane = $ui.TxtOutShort.Parent
    $w = $(if ($pane) { $pane.ActualWidth - 30.0 } else { 0.0 })
    $ui.TxtOutShort.Text = Get-MiddleTrimmedPath -Path ([string]$ui.TxtOut.Text) -MaxWidth $w -Block $ui.TxtOutShort
}
$ui.TxtOut.Add_TextChanged({ Update-OutPathDisplay })
if ($ui.TxtOutShort.Parent) { $ui.TxtOutShort.Parent.Add_SizeChanged({ Update-OutPathDisplay }) }
Update-OutPathDisplay

$ui.BtnDeleteCurrent.Add_Click({
    if (Test-GalleryActionsBusy) { Show-Toast 'Hãy dừng hoặc đợi hàng đợi hoàn tất trước khi xóa video.' -Kind warning; return }
    if (-not $script:lastOut) { return }
    $delPath = $script:lastOut
    if (Test-TikTokTransferActive $delPath) { Show-Toast 'Video đang được chuyển sang bộ đăng nền. Đợi chuyển xong rồi hãy xóa.' -Kind warning; return }
    if (Confirm-GalleryDelete -FilePath $delPath) {
        $savedSource = $ui.Player.Source
        $savedPosition = [TimeSpan]::Zero
        try { $savedPosition = $ui.Player.Position } catch { <# bo qua: player chua mo nguon: vi tri mac dinh 0 #> }
        # Match the established play-button state used by track switching and seeking.
        $savedWasPlaying = ($ui.BtnPlay -and $ui.BtnPlay.Content -match 'Tạm dừng')
        $savedLastOut = $script:lastOut
        $savedActiveTrack = $script:activeTrack
        $savedPreviewingClean = $script:previewingClean
        $savedPreviewBadge = if ($ui.BadgePreviewMode) { $ui.BadgePreviewMode.Visibility } else { $null }
        $savedReviewVisibility = if ($ui.PanelRev) { $ui.PanelRev.Visibility } else { $null }
        $savedPanelPlayVisibility = if ($ui.PanelPlay) { $ui.PanelPlay.Visibility } else { $null }
        $savedNoVidVisibility = if ($ui.TxtNoVid) { $ui.TxtNoVid.Visibility } else { $null }

        $delResult = $null
        try { $delResult = Remove-ReelFiles $delPath -AllowPermanent:([bool](Get-KhoNoRecycleReason (Split-Path $delPath -Parent))) }
        catch {
            $delResult = @{ Success = $false; Errors = @($_.Exception.Message); CleanupStatus = 'RecoveryRequired'; RecoveryPaths = @() }
        }
        if (-not $delResult -or -not $delResult.Success) {
            # Restore review state and the exact media source that was active before deletion.
            $script:lastOut = $savedLastOut
            $script:activeTrack = $savedActiveTrack
            $script:previewingClean = $savedPreviewingClean
            if ($ui.PanelRev -and $null -ne $savedReviewVisibility) { $ui.PanelRev.Visibility = $savedReviewVisibility }
            if ($ui.PanelPlay -and $null -ne $savedPanelPlayVisibility) { $ui.PanelPlay.Visibility = $savedPanelPlayVisibility }
            if ($ui.TxtNoVid -and $null -ne $savedNoVidVisibility) { $ui.TxtNoVid.Visibility = $savedNoVidVisibility }
            if ($ui.BadgePreviewMode -and $null -ne $savedPreviewBadge) { $ui.BadgePreviewMode.Visibility = $savedPreviewBadge }
            if ($ui.BtnReedit) { $ui.BtnReedit.IsEnabled = ($savedLastOut -and (Test-Path -LiteralPath $savedLastOut)) }

            if ($savedSource) {
                $sourceAvailable = $true
                if ($savedSource.IsFile) { $sourceAvailable = Test-Path -LiteralPath $savedSource.LocalPath }
                if (-not $sourceAvailable) {
                    try { $ui.Player.Stop(); $ui.Player.Close(); $ui.Player.Source = $null } catch { <# bo qua: don dep khi huy/dong, loi o day khong anh huong ket qua #> }
                    if ($ui.PanelPlay) { $ui.PanelPlay.Visibility = 'Collapsed' }
                    if ($ui.TxtNoVid) { $ui.TxtNoVid.Visibility = 'Visible' }
                    if ($ui.BtnPlay) { $ui.BtnPlay.Content = 'Phát' }
                    if ($ui.BtnReedit) { $ui.BtnReedit.IsEnabled = $false }
                    $recoveryPaths = @($delResult.RecoveryPaths | Where-Object { $_ })
                    $missingSourceMessage = if ($recoveryPaths.Count) { "Không thể mở nguồn xem trước đã bị chuyển đi. File cần khôi phục: $($recoveryPaths -join ', ')" } else { "Không thể mở nguồn xem trước đã bị chuyển đi: $($savedSource.LocalPath)" }
                    Show-Toast $missingSourceMessage -Kind error
                    Add-Log "Không khôi phục được nguồn xem trước $($savedSource.LocalPath); cleanup=$($delResult.CleanupStatus); recovery=$($recoveryPaths -join ', ')" 'Danger'
                    try { Update-Gallery } catch { Write-FileLog "WARN Update-Gallery sau loi khoi phuc: $($_.Exception.Message)" }
                    return
                }
                if (-not $script:deleteRestoreGenerationState) { $script:deleteRestoreGenerationState = [pscustomobject]@{ Token = '' } }
                $generationState = $script:deleteRestoreGenerationState
                $restoreState = @{
                    SourceText = $savedSource.ToString()
                    Source = $savedSource
                    Position = $savedPosition
                    WasPlaying = [bool]$savedWasPlaying
                    Completed = $false
                    Opened = $false
                    Failed = $false
                    OpenHandler = $null
                    FailedHandler = $null
                    TimerHandler = $null
                    Timer = [System.Windows.Threading.DispatcherTimer]::new()
                    Expires = [DateTime]::UtcNow.AddSeconds(15)
                    Token = [Guid]::NewGuid().ToString('N')
                }
                $generationState.Token = $restoreState.Token
                $restoreAddLog = ${function:Add-Log}
                $openedAction = {
                    param($sender, $eventArgs)
                    $currentSource = if ($ui.Player.Source) { $ui.Player.Source.ToString() } else { '' }
                    if ($generationState.Token -ne $restoreState.Token -or $currentSource -ne $restoreState.SourceText) {
                        return
                    }
                    $restoreState.Opened = $true
                }.GetNewClosure()
                $failedAction = {
                    param($sender, $eventArgs)
                    $currentSource = if ($ui.Player.Source) { $ui.Player.Source.ToString() } else { '' }
                    if ($generationState.Token -eq $restoreState.Token -and $currentSource -eq $restoreState.SourceText) { $restoreState.Failed = $true }
                }.GetNewClosure()
                $restoreAction = {
                    param($sender, $eventArgs)
                    if ($restoreState.Completed) { return }
                    $currentSource = if ($ui.Player.Source) { $ui.Player.Source.ToString() } else { '' }
                    if ($generationState.Token -ne $restoreState.Token -or $currentSource -ne $restoreState.SourceText) {
                        $restoreState.Completed = $true
                        $restoreState.Timer.Stop()
                        try { $restoreState.Timer.Remove_Tick($restoreState.TimerHandler) } catch { <# bo qua: don dep khi huy/dong, loi o day khong anh huong ket qua #> }
                        try { $ui.Player.Remove_MediaOpened($restoreState.OpenHandler) } catch { <# bo qua: don dep khi huy/dong, loi o day khong anh huong ket qua #> }
                        try { $ui.Player.Remove_MediaFailed($restoreState.FailedHandler) } catch { <# bo qua: don dep khi huy/dong, loi o day khong anh huong ket qua #> }
                        return
                    }
                    if ($restoreState.Failed) {
                        $restoreState.Completed = $true
                        $restoreState.Timer.Stop()
                        try { $restoreState.Timer.Remove_Tick($restoreState.TimerHandler) } catch { <# bo qua: don dep khi huy/dong, loi o day khong anh huong ket qua #> }
                        try { $ui.Player.Remove_MediaOpened($restoreState.OpenHandler) } catch { <# bo qua: don dep khi huy/dong, loi o day khong anh huong ket qua #> }
                        try { $ui.Player.Remove_MediaFailed($restoreState.FailedHandler) } catch { <# bo qua: don dep khi huy/dong, loi o day khong anh huong ket qua #> }
                        & $restoreAddLog "Không mở được media source cần khôi phục: $($restoreState.SourceText)" 'Danger'
                        return
                    }
                    if (-not $restoreState.Opened) {
                        if ([DateTime]::UtcNow -ge $restoreState.Expires) {
                            $restoreState.Completed = $true
                            $restoreState.Timer.Stop()
                            try { $restoreState.Timer.Remove_Tick($restoreState.TimerHandler) } catch { <# bo qua: don dep khi huy/dong, loi o day khong anh huong ket qua #> }
                            try { $ui.Player.Remove_MediaOpened($restoreState.OpenHandler) } catch { <# bo qua: don dep khi huy/dong, loi o day khong anh huong ket qua #> }
                            try { $ui.Player.Remove_MediaFailed($restoreState.FailedHandler) } catch { <# bo qua: don dep khi huy/dong, loi o day khong anh huong ket qua #> }
                            & $restoreAddLog "Hết thời gian chờ MediaOpened để khôi phục nguồn: $($restoreState.SourceText)" 'Danger'
                        }
                        return
                    }
                    $restoreState.Completed = $true
                    $restoreState.Timer.Stop()
                    try { $restoreState.Timer.Remove_Tick($restoreState.TimerHandler) } catch { <# bo qua: don dep khi huy/dong, loi o day khong anh huong ket qua #> }
                    try { $ui.Player.Remove_MediaOpened($restoreState.OpenHandler) } catch { <# bo qua: don dep khi huy/dong, loi o day khong anh huong ket qua #> }
                    try { $ui.Player.Remove_MediaFailed($restoreState.FailedHandler) } catch { <# bo qua: don dep khi huy/dong, loi o day khong anh huong ket qua #> }
                    try { $ui.Player.Position = $restoreState.Position } catch { Write-FileLog "WARN khoi phuc vi tri phat: $($_.Exception.Message)" }
                    if ($restoreState.WasPlaying) {
                        try { $ui.Player.Play() } catch { Write-FileLog "WARN khoi phuc phat: $($_.Exception.Message)" }
                        if ($ui.BtnPlay) { $ui.BtnPlay.Content = 'Tạm dừng' }
                    } else {
                        try { $ui.Player.Pause() } catch { Write-FileLog "WARN khoi phuc tam dung: $($_.Exception.Message)" }
                        if ($ui.BtnPlay) { $ui.BtnPlay.Content = 'Phát' }
                    }
                }.GetNewClosure()
                $restoreState.OpenHandler = [System.Windows.RoutedEventHandler]$openedAction
                $restoreState.FailedHandler = [System.EventHandler[System.Windows.ExceptionRoutedEventArgs]]$failedAction
                $restoreState.TimerHandler = [System.EventHandler]$restoreAction
                try {
                    $restoreState.Timer.Interval = [TimeSpan]::FromMilliseconds(50)
                    $restoreState.Timer.Add_Tick($restoreState.TimerHandler)
                    $ui.Player.Add_MediaOpened($restoreState.OpenHandler)
                    $ui.Player.Add_MediaFailed($restoreState.FailedHandler)
                    $ui.Player.Source = $restoreState.Source
                    # Manual LoadedBehavior does not guarantee an open starts
                    # on Source assignment alone; Play initiates MediaOpened.
                    $ui.Player.Play()
                    if ($ui.BtnPlay) { $ui.BtnPlay.Content = 'Tạm dừng' }
                    $restoreState.Timer.Start()
                } catch {
                    $restoreState.Completed = $true
                    try { $restoreState.Timer.Stop(); $restoreState.Timer.Remove_Tick($restoreState.TimerHandler) } catch { <# bo qua: don dep khi huy/dong, loi o day khong anh huong ket qua #> }
                    try { $ui.Player.Remove_MediaOpened($restoreState.OpenHandler) } catch { <# bo qua: don dep khi huy/dong, loi o day khong anh huong ket qua #> }
                    try { $ui.Player.Remove_MediaFailed($restoreState.FailedHandler) } catch { <# bo qua: don dep khi huy/dong, loi o day khong anh huong ket qua #> }
                    Add-Log "Lỗi khôi phục nguồn xem trước: $($_.Exception.Message)" 'Danger'
                }
            } elseif ($ui.BtnPlay) {
                $ui.BtnPlay.Content = if ($savedWasPlaying) { 'Tạm dừng' } else { 'Phát' }
            }
            $cleanupStatus = if ($delResult.CleanupStatus) { $delResult.CleanupStatus } else { 'Unknown' }
            $recoveryPaths = @($delResult.RecoveryPaths | Where-Object { $_ })
            $toastText = 'Không thể xóa đủ file. Các file đã được giữ nguyên hoặc khôi phục.'
            if ($recoveryPaths.Count) { $toastText = "Không thể xóa đủ file. Có file cần khôi phục: $($recoveryPaths -join ', ')" }
            Show-Toast $toastText -Kind error
            Add-Log "Lỗi khi xóa file; cleanup=$cleanupStatus; recovery=$($recoveryPaths -join ', '); chi tiết=$($delResult.Errors -join ' | ')" 'Danger'
            try { Update-Gallery } catch { Write-FileLog "WARN Update-Gallery sau loi xoa: $($_.Exception.Message)" }
            return
        }
        Clear-Player
        $successCleanupStatus = if ($delResult.CleanupStatus) { $delResult.CleanupStatus } else { 'Unknown' }
        $successRecoveryPaths = @($delResult.RecoveryPaths | Where-Object { $_ })
        if ($successCleanupStatus -eq 'Complete' -and -not $successRecoveryPaths.Count) {
            Show-Toast 'Đã xóa video.' -Kind success
            Add-Log "Đã xóa video: $delPath" 'Danger'
        } else {
            Show-Toast "Đã xóa video; còn bản sao tạm cần dọn: $($successRecoveryPaths -join ', ')" -Kind warning
            Add-Log "Đã xóa video: $delPath; cleanup=$successCleanupStatus; recovery=$($successRecoveryPaths -join ', '); chi tiết=$($delResult.Errors -join ' | ')" 'Warning'
        }
        try { Update-Gallery } catch {
            Add-Log "Lỗi khi làm mới Kho Video: $($_.Exception.Message)" 'Warning'
        }
    }
})

function Start-QueueFromLinks {
    # Loc link da loai truoc + (tuy lua chon o the Tom tat) video da co trong kho, dung bang hang doi va chay.
    param([string[]]$Links, [bool]$SkipExisting = $true)
    if ($script:ps) { Show-Toast 'Đang chạy tác vụ — hãy đợi hoàn tất.' -Kind warning; return }
    if ($script:importBusy) { Show-Toast 'Đang thêm video từ thư mục — hãy đợi xong rồi bắt đầu.' -Kind warning; return }
    if ($script:queue -and $script:queue.Count -gt 0) { Show-Toast 'Hãy dừng hoặc đợi hàng đợi hiện tại hoàn tất trước khi bắt đầu.' -Kind warning; return }
    if ($script:khoMoveRunning -or $script:khoExclusive -gt 0) { Show-Toast 'Đang chuyển kho hoặc mở hộp thoại đăng/dọn dẹp — thử lại sau.' -Kind warning; return }
    # Kho dich chup MOT lan luc bat dau: doi kho tai ve giua chung khong doi noi luu cua hang doi nay; kho nay bi giu (khong chuyen/xoa) toi khi xong.
    $targetLib = Get-KhoById (Get-KhoDownloadTarget)
    if (-not $targetLib) { Show-Toast 'Chưa có kho để lưu video. Mở Quản lý kho để tạo hoặc chọn kho.' -Kind error; return }
    $targetDir = [string]$targetLib.path
    $jBlock = Get-KhoJournalBlock @($targetDir)
    if ($jBlock) { Show-Toast $jBlock -Kind warning; return }
    $links = @($Links | Where-Object { $_ })
    if ($links.Count -eq 0) {
        Show-Page 'source'
        Show-Toast 'Chưa có link Facebook hợp lệ. Dán link video, Reel hoặc share/r vào ô Danh sách link.' -Kind warning
        return
    }
    $xau = @($links | Where-Object { $_ -notmatch 'facebook\.com|fb\.watch' })
    if ($xau.Count -gt 0) {
        if (-not (Show-ConfirmDialog -Title 'Kiểm tra lại link?' -Kind info -ConfirmText 'Vẫn chạy' -CancelText 'Sửa lại' `
                -Message "Có $($xau.Count) dòng không giống link Facebook (vd: $($xau[0])). Vẫn tiếp tục?")) { return }
    }
    $skipped = New-Object System.Collections.ArrayList
    $preRejectedCount = 0
    try {
        $rejectedHistory = @(Get-RejectedReels -Root $script:root)
        $blockedLinks = @(Get-RejectedLinkMatches -Links $links -Rejected $rejectedHistory)
        # Dem theo video (ID hoac URL) de link lap khong bi tinh hai lan.
        $preRejectedCount = @($blockedLinks | ForEach-Object { $bid = Get-FacebookVideoId -Url $_; if ($bid) { "id:$bid" } else { "url:$_" } } | Select-Object -Unique).Count
        foreach ($b in @($blockedLinks | Select-Object -Unique)) { [void]$skipped.Add(@{ Url = $b; Message = 'Đã bị loại trước đây (không có bản lồng tiếng Việt)' }) }
        $links = @($links | Where-Object { $blockedLinks -cnotcontains $_ })
        if (-not $links.Count) {
            Update-RejectedDashboard
            $ui.TxtStat.Text = "Không có video mới: $preRejectedCount bỏ qua (đã loại trước)"
            Show-Toast 'Tất cả link đã bị loại trước đây; không tải lại. Bỏ loại ở Kho › Lịch sử đã loại nếu muốn thử lại.' -Kind warning
            return
        }
    } catch {
        Add-Log "Không đọc được lịch sử loại: $($_.Exception.Message)" 'Danger'
        Show-Toast 'Không đọc được lịch sử loại. Hãy kiểm tra file data/rejected-videos.json trước khi tải.' -Kind error
        return
    }
    $duplicateReport = $null
    $skipExistingCount = 0
    if (Get-Command Get-FacebookLinkDuplicateReport -ErrorAction SilentlyContinue) {
        try { $duplicateReport = Get-FacebookLinkDuplicateReport -Text ($links -join "`n") -OutDir @(Get-KhoRoots) }
        catch { Show-Toast 'Không kiểm tra được ID đã tải. Kiểm tra lại các thư mục kho.' -Kind error; return }
        $links = @($duplicateReport.Links)
        if ($duplicateReport.DownloadedIds.Count -gt 0 -and $SkipExisting) {
            # Lua chon "Bo qua / Tai lai" nam o the Tom tat (trang Nguon), khong hien hop thoai.
            $existing = @($links | Where-Object { (Get-FacebookVideoId -Url $_) -in $duplicateReport.DownloadedIds })
            foreach ($e in $existing) { [void]$skipped.Add(@{ Url = $e; Message = 'Đã có trong kho (chọn "Tải và ghi âm lại" ở trang Nguồn để chạy lại)' }) }
            $skipExistingCount = $existing.Count
            $links = @($links | Where-Object { $existing -cnotcontains $_ })
            if ($links.Count -eq 0) { Show-Toast 'Tất cả video trong danh sách đã có trong kho — không có video mới.' -Kind info; return }
        }
    }
    if (-not [System.IO.Directory]::Exists($targetDir)) {
        try { [void][System.IO.Directory]::CreateDirectory($targetDir) }
        catch { Show-Toast "Không tạo được thư mục kho: $($_.Exception.Message)" -Kind error; Add-Log "Không tạo được thư mục kho '$targetDir': $($_.Exception.Message)" 'Danger'; return }
    }
    Clear-LogBatch
    if ($ui.TxtLog) { $ui.TxtLog.Clear() }; [void]$script:runLog.Clear()
    if ($duplicateReport -and $duplicateReport.DuplicateIds.Count -gt 0) {
        Add-Log ('ID lặp, chỉ xử lý một lần: ' + ($duplicateReport.DuplicateIds -join ', ')) 'Warning'
    }
    $script:queue = $links; $script:idx = 0; $script:giu = 0; $script:bo = 0
    $script:loi = 0; $script:chuaXN = 0; $script:failedLinks = @(); $script:lastCompletedOut = ''
    $script:boTruoc = $preRejectedCount; $script:skipExisting = $skipExistingCount; $script:queueFinalizedIdx = -1; $script:forceRetryRejected = $false
    $script:queueOutDir = $targetDir
    if ($preRejectedCount) { Add-Log "$preRejectedCount video đã bị loại trước đây — bỏ qua." 'Warning' }
    if ($skipExistingCount) { Add-Log "$skipExistingCount video đã có trong kho — bỏ qua theo lựa chọn ở trang Nguồn." 'Warning' }
    Add-Log 'Chế độ tự động: lưu từng video rồi chạy tiếp đến hết danh sách; bấm Dừng để kết thúc sớm.' 'Info'
    Initialize-QueueRows -Links $links -Skipped @($skipped)
    Show-Page 'queue'
    Start-Link
}

function Start-QueueFromInput {
    if ($script:ps -and $script:mode -eq 'check') { Show-Toast 'Đang kiểm tra máy, vui lòng đợi vài giây rồi bấm Bắt đầu.'; return }
    $links = @()
    if (Get-Command Get-FacebookInputLinks -CommandType Function -ErrorAction SilentlyContinue) {
        $links = @(Get-FacebookInputLinks -Text $ui.TxtLinks.Text)
    } else {
        foreach ($l in ($ui.TxtLinks.Text -split "`r?`n")) {
            $t = $l.Trim().Trim('"').Trim("'").Trim()
            if ($t -match '\S') { $links += $t }
        }
    }
    Start-QueueFromLinks -Links $links -SkipExisting (-not [bool]$ui.RbDupRedownload.IsChecked)
}

# Mot nut chinh o thanh hanh dong: Bat dau <-> Dung (cung vi tri).
$ui.BtnStart.Add_Click({
    if (Test-QueueRunning) { Request-Stop; return }
    Start-QueueFromInput
})
# ------------------------------------------------------------- cap nhat qua GitHub ----
$script:updProc = $null; $script:updMode = ''; $script:updSilent = $false
if ($ui.TxtUpdateInfo) { $ui.TxtUpdateInfo.Text = "Phiên bản hiện tại v$($script:verLocal). Ứng dụng tự kiểm tra bản mới khi mở; bản tải về được kiểm chữ ký trước khi cài." }
if ($ui.TxtAboutVersion) { $ui.TxtAboutVersion.Text = "Phiên bản v$($script:verLocal) · Windows PowerShell $($PSVersionTable.PSVersion) · WPF" }
$tUpd = New-Object Windows.Threading.DispatcherTimer
$tUpd.Interval = [TimeSpan]::FromMilliseconds(400)

function Test-AppBusy {
    # Dang chay engine (hang doi, sua video, kiem tra, cai dat) hoac con muc trong hang doi.
    return [bool]($script:ps -or $script:stopping -or $script:importBusy -or ($script:queue -and $script:queue.Count -gt 0))
}

function Set-UpdateButtonText {
    param([string]$Text, [bool]$Enabled = $true)
    if ($ui.TxtUpdateButton) { $ui.TxtUpdateButton.Text = $Text }
    if ($ui.BtnUpdate) { $ui.BtnUpdate.IsEnabled = $Enabled }
}

function Start-UpdateJob([string]$Mode, [bool]$Silent = $false) {
    if ($script:updProc) { return }
    $upd = Join-Path $scriptDir 'updater.ps1'
    if (-not (Test-Path -LiteralPath $upd)) { if (-not $Silent) { Show-Toast 'Thiếu file updater.ps1.' -Kind error }; return }
    $script:updMode = $Mode; $script:updSilent = $Silent
    Set-UpdateButtonText $(if ($Mode -eq 'check') { 'Đang kiểm tra…' } else { 'Đang tải bản mới…' }) $false
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $psi.Arguments = "-NoProfile -ExecutionPolicy Bypass -File `"$upd`" -Mode $Mode"
    $psi.CreateNoWindow = $true; $psi.UseShellExecute = $false
    $script:updProc = [System.Diagnostics.Process]::Start($psi)
    $tUpd.Start()
}

$tUpd.Add_Tick({
    if (-not $script:updProc -or -not $script:updProc.HasExited) { return }
    $tUpd.Stop(); $script:updProc = $null
    Set-UpdateButtonText 'Kiểm tra bản mới' $true
    $st = $null
    try { $st = Get-Content -LiteralPath (Join-Path $scriptDir '_update\status.json') -Raw -Encoding UTF8 | ConvertFrom-Json }
    catch { Write-FileLog "WARN Đọc _update\status.json: $($_.Exception.Message)" }
    if (-not $st -or -not $st.ok) {
        $err = if ($st) { $st.error } else { 'Không đọc được kết quả' }
        Write-FileLog "WARN Cập nhật: $err"
        if (-not $script:updSilent) { Show-Toast "Không kiểm tra hoặc tải được bản cập nhật: $err" -Kind error }
        return
    }
    if ($script:updMode -eq 'check') {
        if (-not $st.hasUpdate) {
            if (-not $script:updSilent) { Show-Toast "Đang dùng bản mới nhất (v$($script:verLocal))." -Kind success }
            return
        }
        Set-UpdateButtonText "Cập nhật lên v$($st.remote)" $true
        if ($ui.TxtUpdateInfo) { $ui.TxtUpdateInfo.Text = "Có bản mới v$($st.remote) (đang dùng v$($script:verLocal))." }
        if ($script:updSilent -and -not $st.mandatory) {
            Add-Log "Có bản cập nhật mới v$($st.remote) — vào Cài đặt › Cập nhật để cài." 'Success'
            Show-Toast "Có bản mới v$($st.remote). Vào Cài đặt › Cập nhật để cài."
            return
        }
        if (Test-AppBusy) { Show-Toast 'Đang xử lý — bấm Dừng trước khi cập nhật.' -Kind warning; return }
        $log = (@($st.changelog) | ForEach-Object { "• $_" }) -join "`r`n"
        $kb = [math]::Round(([double]$st.size) / 1KB, 0)
        $ok = Show-ConfirmDialog -Title "Cập nhật lên v$($st.remote)?" -Kind info -ConfirmText 'Cập nhật' -CancelText 'Để sau' `
            -Message ("Đang dùng v$($st.local).`r`n`r`nThay đổi:`r`n$log`r`n`r`nDung lượng khoảng $kb KB. Ứng dụng sẽ khởi động lại sau khi tải xong.")
        if ($ok) { Start-UpdateJob 'download' $false }
        return
    }
    if ($script:updMode -eq 'download' -and $st.ready) {
        if (Test-AppBusy) {
            # Khong khoi dong lai giua luc dang xu ly; ban moi da tai, ap dung o lan mo sau.
            Add-Log "Đã tải xong bản v$($st.remote) nhưng đang xử lý video; mở lại Kid-FB.Y.exe sau khi xong để áp dụng." 'Warning'
            Show-Toast 'Đã tải bản mới — đang xử lý nên chưa khởi động lại.' -Kind warning
            return
        }
        [void](Show-ConfirmDialog -Title "Đã tải xong v$($st.remote)" -Kind info -OkOnly -ConfirmText 'Khởi động lại' `
            -Message 'Ứng dụng sẽ khởi động lại để áp dụng bản mới.')
        $exe = Join-Path $root 'Kid-FB.Y.exe'
        if (Test-Path -LiteralPath $exe) {
            # -AfterUpdate: launcher moi cho launcher cu nha khoa single-instance.
            Start-Process -FilePath $exe -WorkingDirectory $root -ArgumentList '-AfterUpdate'
            $win.Close()
        } else {
            Show-Toast 'Không tìm thấy Kid-FB.Y.exe. Hãy mở lại ứng dụng bằng Kid-FB.Y.exe để áp dụng bản mới.' -Kind error
        }
    }
})

$ui.BtnUpdate.Add_Click({
    if (Test-AppBusy) { Show-Toast 'Đang xử lý — bấm Dừng trước khi cập nhật.' -Kind warning; return }
    Start-UpdateJob 'check' $false
})
$win.Add_Closing({ param($sender,$eventArgs)
    $gifPending=($script:gifSelectionWorker -or ($script:gifCancelledWorkers -and $script:gifCancelledWorkers.Count -gt 0))
    if($gifPending){
        $script:closeAfterGifStop = $true
        $script:gifSelectionGeneration++
        try { Stop-GifSelectionWorker } catch { <# bo qua: don dep khi huy/dong, loi o day khong anh huong ket qua #> }
    }
    if ($script:ps) {
        $eventArgs.Cancel = $true
        $script:closeAfterStop = $true
        Stop-Engine
        return
    }
    if ($gifPending -or ($script:gifCancelledWorkers -and $script:gifCancelledWorkers.Count -gt 0)) { $eventArgs.Cancel=$true; return }
    try { if ($tUpd) { $tUpd.Stop() } } catch { <# bo qua: don dep khi huy/dong, loi o day khong anh huong ket qua #> }
    try { if ($script:updProc -and -not $script:updProc.HasExited) { $script:updProc.Kill() } } catch { <# bo qua: don dep khi huy/dong, loi o day khong anh huong ket qua #> }
    $script:gifSelectionGeneration++
    try { Stop-GifSelectionWorker } catch { <# bo qua: don dep khi huy/dong, loi o day khong anh huong ket qua #> }
    if ($script:gifPlayer) { try { $script:gifPlayer.Close() } catch { <# bo qua: don dep khi huy/dong, loi o day khong anh huong ket qua #> }; $script:gifPlayer=$null }

    try { Stop-Engine } catch { <# bo qua: don dep khi huy/dong, loi o day khong anh huong ket qua #> }
    try { if ($tLinkWarning) { $tLinkWarning.Stop() } } catch { <# bo qua: don dep khi huy/dong, loi o day khong anh huong ket qua #> }
    try { if ($tPlay) { $tPlay.Stop() } } catch { <# bo qua: don dep khi huy/dong, loi o day khong anh huong ket qua #> }
    try { if ($timer) { $timer.Stop() } } catch { <# bo qua: don dep khi huy/dong, loi o day khong anh huong ket qua #> }
    try { if ($tGallerySearch) { $tGallerySearch.Stop() } } catch { Write-FileLog "WARN tGallerySearch.Stop: $($_.Exception.Message)" }
    try { Stop-MediaWorker -Wait } catch { Write-FileLog "WARN Stop-MediaWorker khi đóng: $($_.Exception.Message)" }
    try { Save-UserSettings } catch { Write-FileLog "WARN Save-UserSettings khi đóng: $($_.Exception.Message)" }
    try { Flush-LogBatch } catch { Write-FileLog "WARN Flush-LogBatch khi đóng: $($_.Exception.Message)" }
    try { [System.IO.File]::Delete((Join-Path (Join-Path $scriptDir '_update') 'gui.hwnd')) } catch { Write-FileLog "WARN xóa gui.hwnd: $($_.Exception.Message)" }
    Flush-FileLog
    try { if ($script:logFlushTimer) { $script:logFlushTimer.Stop() } } catch { Write-FileLog "WARN dừng logFlushTimer: $($_.Exception.Message)" }
})

try {
    # ------------------------------------------------------------------ chay ----
    if (-not (Test-Path -LiteralPath $engine)) {
        if ($SelfTest) { throw "Khong tim thay engine: $engine" }
        Show-KidMessageBox -Message "Không tìm thấy kid-fby.ps1 cạnh file này.

$engine" -Title 'Thiếu file' | Out-Null
        return
    }
    # Loi khong bat duoc trong handler WPF -> crash log + thong bao, khong dong app giua chung.
    $win.Dispatcher.add_UnhandledException({
        param($sender, $e)
        $crashPath = Write-CrashLog -Source 'Dispatcher' -Exception $e.Exception
        try { Add-Log "Lỗi giao diện không mong muốn: $($e.Exception.Message)" 'Danger' } catch { $script:fileLogError = $_.Exception.Message }
        $e.Handled = $true
        if (-not $script:crashDialogOpen) {
            $script:crashDialogOpen = $true
            try {
                Show-KidMessageBox -Message ("Đã xảy ra lỗi giao diện; app vẫn tiếp tục chạy.`r`n`r`n$($e.Exception.Message)" +
                    $(if ($crashPath) { "`r`n`r`nChi tiết: $crashPath" } else { '' })) | Out-Null
            } finally { $script:crashDialogOpen = $false }
        }
    })
    [AppDomain]::CurrentDomain.add_UnhandledException([UnhandledExceptionEventHandler]{
        param($sender, $e)
        [void](Write-CrashLog -Source ('AppDomain' + $(if ($e.IsTerminating) { ' (terminating)' } else { '' })) -Exception $e.ExceptionObject)
    })
    if ($script:gifAddTypeError) {
        Add-Log "GIF tắt: không nạp được bộ phát GIF ($($script:gifAddTypeError))." 'Danger'
        Write-FileLog "ERR  GIF Add-Type detail: $($script:gifAddTypeErrorDetail)"
        Show-Toast "GIF tắt: $($script:gifAddTypeError)" -Kind error
    }
    if (-not $SelfTest) {
        [void](Remove-OldGuiLogs -Days 14)
        [void](Initialize-UserSettings)
        if ($ui.ChkAllowOnsetSync) { $ui.ChkAllowOnsetSync.Add_Checked({ Request-SaveSettings }); $ui.ChkAllowOnsetSync.Add_Unchecked({ Request-SaveSettings }) }
        # Luu (debounce 1 s) khi nguoi dung doi cai dat.
        foreach ($c in @($ui.ChkWatermark, $ui.ChkGif)) { if ($c) { $c.Add_Checked({ Request-SaveSettings }); $c.Add_Unchecked({ Request-SaveSettings }) } }
        foreach ($s in @($ui.SldLogoSize, $ui.SldLogoFade, $ui.SldGifSize)) { if ($s) { $s.Add_ValueChanged({ Request-SaveSettings }) } }
        $ui.CmbLogoMode.Add_SelectionChanged({ Request-SaveSettings })
        foreach ($tb in @($ui.TxtOut, $ui.TxtLogoPath, $ui.TxtGifPath)) { if ($tb) { $tb.Add_TextChanged({ Request-SaveSettings }) } }
        if ($ui.CanvasWatermark) { $ui.CanvasWatermark.Add_PreviewMouseLeftButtonUp({ Request-SaveSettings }) }
        if ($ui.BtnGifFullFrame) { $ui.BtnGifFullFrame.Add_Click({ Request-SaveSettings }) }
        $win.Add_SizeChanged({ Request-SaveSettings })
        $win.Add_StateChanged({ Request-SaveSettings })
    }
    # Kho la thu muc that: nap registry (chuyen "Output cũ" lan dau) va hoan tat chuyen kho dang do TRUOC khi quet kho / chay dong bo.
    $script:khoSettingsLoaded = $true    # settings.json da duoc nap (hoac khong co / bi khoa): tu day registry kho moi duoc tao va luu
    Initialize-KhoStartup
    # Bo chon kho + o "Luu vao kho" co noi dung ngay tu luc mo app (khong doi toi lan quet Kho dau tien); chi sau khi registry da nap.
    try { Update-GalleryKhoSelector } catch { Write-FileLog "WARN Khoi tao bo chon kho: $($_.Exception.Message)" }
    # Khoi dong: trang Nguon, quet kho nen (chi sau khi settings da nap -> dung thu muc kho cua nguoi dung), trang thai cong cu.
    Show-Page 'source'
    $script:galleryScanReady = $true
    Update-Gallery
    Update-ToolsStatus
    Update-MaxButtonGlyph
    Update-LinkDuplicateWarning
    Update-QueueEmptyState
    Update-StepPanel
    Update-ActionBar

    if ($SelfTest) {
        foreach ($k in $script:uiNames) {
            if ($null -eq $ui[$k]) { throw "Thieu thanh phan giao dien: $k" }
        }
        # Moi tham chieu $ui.X trong script phai co trong danh sach (bat loi doi ten control trong MainWindow.xaml).
        $selfText = [System.IO.File]::ReadAllText($scriptPath, [System.Text.Encoding]::UTF8)
        $refs = [regex]::Matches($selfText, '\$ui\.([A-Za-z][A-Za-z0-9]+)') | ForEach-Object { $_.Groups[1].Value } | Sort-Object -Unique
        $missingRefs = @($refs | Where-Object { $_ -notin @('Keys', 'Values', 'Count', 'ContainsKey') -and -not $ui.ContainsKey($_) })
        if ($missingRefs.Count) { throw ('Code tham chieu control khong co trong MainWindow.xaml: ' + ($missingRefs -join ', ')) }
        $brushLiterals = @([regex]::Matches($selfText, "Get-Brush\s+(?:\$\(if[^)]*\)\s*\{\s*)?'([A-Za-z]+)'") | ForEach-Object { $_.Groups[1].Value })
        $brushLiterals += @([regex]::Matches($selfText, "\{\s*'([A-Z][A-Za-z]+(?:Subtle|Soft|Line|Text))'\s*\}") | ForEach-Object { $_.Groups[1].Value })
        $tokenList = @('Surface0','Surface1','Surface2','SurfaceAlt','Ink','InkStrong','StickerShadow','TextPrimary','TextMuted','TextSubtle','Accent','AccentHover',
                       'Success','Warning','Danger','Info','Neutral','Pink','Mint','MintLine','Coral','OverlayLogo','OverlayLogoDim','OverlayGif','OverlayGifDim') + $brushLiterals
        foreach ($token in @($tokenList | Sort-Object -Unique)) {
            if (-not ($win.TryFindResource($token) -is [System.Windows.Media.SolidColorBrush])) { throw "Thieu token mau: $token" }
        }
        foreach ($styleKey in @('BtnPrimary','BtnSecondary','BtnGhost','BtnDanger','BtnDangerSolid','BtnIcon','NavButton','SegButton','Icon','StatusBadge','StickerCard','ToggleSwitch','NotePaper')) {
            if (-not ($win.TryFindResource($styleKey) -is [System.Windows.Style])) { throw "Thieu style: $styleKey" }
        }
        if (-not $ui.TxtOut.Text -or $ui.TxtOut.Text -cne (Get-KhoDownloadPath)) { throw 'Thu muc tai ve (TxtOut) khong khop kho tai ve.' }
        if ($ui.TxtAppVersion.Text -ne "v$($script:verLocal)") { throw 'Nhan phien ban khoi tao khong dung.' }
        $ud = Join-Path $scriptDir '_update'
        if (-not (Test-Path -LiteralPath $ud)) { New-Item -ItemType Directory -Path $ud -Force | Out-Null }
        [System.IO.File]::WriteAllText((Join-Path $ud 'BOOT_OK'), $(if ($env:KID_FBY_UPDATE_TOKEN) { $env:KID_FBY_UPDATE_TOKEN } else { (Get-Date).ToString('o') }))
        Write-Host "SelfTest: Kid FB.Y khoi tao thanh cong, $($ui.Keys.Count) thanh phan giao dien"
        return
    }

    # G-E2E: khong tu chon/nap video nao luc mo app (truoc day video moi nhat bi nap ngam va chay toi cuoi).
    # Nguoi dung chon the trong Kho -> nap o 0:00, khong phat.
    Clear-Player
    Start-TikTokStatusSync
    if (Test-TikTokEnabled) { Start-ChromeConnect }

    $icoFile = Join-Path $root 'Kid-FB.Y.ico'
    if (-not (Test-Path -LiteralPath $icoFile)) { $icoFile = Join-Path $scriptDir 'Kid-FB.Y.ico' }
    if (Test-Path -LiteralPath $icoFile) {
        try {
            $win.Icon = [System.Windows.Media.Imaging.BitmapFrame]::Create((New-Object System.Uri([System.IO.Path]::GetFullPath($icoFile))))
        } catch { Write-FileLog "WARN dat icon cua so: $($_.Exception.Message)" }
    }

    $win.Add_ContentRendered({
        # Bao cho launcher biet ban hien tai khoi dong OK (de khong rollback)
        try {
            $ud = Join-Path $scriptDir '_update'
            if (-not (Test-Path -LiteralPath $ud)) { New-Item -ItemType Directory -Path $ud -Force | Out-Null }
            [System.IO.File]::WriteAllText((Join-Path $ud 'BOOT_OK'), $(if ($env:KID_FBY_UPDATE_TOKEN) { $env:KID_FBY_UPDATE_TOKEN } else { (Get-Date).ToString('o') }))
        } catch { Write-FileLog "WARN ghi BOOT_OK: $($_.Exception.Message)" }
        # U-INST: de lan mo thu 2 dua cua so nay len truoc (Program.cs doc file nay: pid|hwnd|gio khoi dong UTC ticks).
        try {
            $hwnd = ([Windows.Interop.WindowInteropHelper]::new($win)).Handle.ToInt64()
            $startTicks = [Diagnostics.Process]::GetCurrentProcess().StartTime.ToUniversalTime().Ticks
            $ud2 = Join-Path $scriptDir '_update'
            if (-not (Test-Path -LiteralPath $ud2)) { New-Item -ItemType Directory -Path $ud2 -Force | Out-Null }
            [System.IO.File]::WriteAllText((Join-Path $ud2 'gui.hwnd'), "$PID|$hwnd|$startTicks")
        } catch { Write-FileLog "WARN ghi gui.hwnd: $($_.Exception.Message)" }
        # Kiem tra may nen nhu cu nhung giu nguyen tab dang mo (khong nhay sang Logs).
        Invoke-DeviceCheck
        try { Start-UpdateJob 'check' $true } catch { Add-Log "Không kiểm tra được bản cập nhật: $($_.Exception.Message)" 'Warning' }
    })
    # SourceInitialized fits to the monitor under the pointer, using physical coordinates.
    [void]$win.ShowDialog()
} catch {
    if ($SelfTest) { Write-Error $_ -ErrorAction Continue; exit 1 }
    Show-KidMessageBox -Message "Đã xảy ra sự cố giao diện:

$($_.Exception.Message)" | Out-Null
}
