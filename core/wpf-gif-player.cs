using System;
using System.Collections.Generic;
using System.IO;
using System.Windows;
using System.Windows.Media;
using System.Windows.Media.Imaging;

public class RawGifFrame {
    public int Left, Top, Width, Height, DelayMs, Disposal;
    public int PixelWidth, PixelHeight;
    public int[] Pixels;
}

public class GifPlayerPreparedState {
    public string FilePath;
    public int CanvasWidth, CanvasHeight, FrameCount, PreviewWidth, PreviewHeight, CurrentFrameIndex;
    public int MaxPreviewSide, BackgroundArgb, BackgroundIndex;
    public bool HasBackground;
    public double TotalDurationSeconds, PreviewScale;
    public object[] Frames;
    public object[] CachedFrames;
    public object[] Checkpoints;
    public int[] Canvas, Restore;
}

/// <summary>Bounded-memory GIF preview renderer. Public canvas dimensions and frame metadata remain in logical GIF pixels.</summary>
public class WpfGifPlayer : IDisposable {
    public bool IsLoaded = false;
    public int CanvasWidth = 0, CanvasHeight = 0, FrameCount = 0;
    public double TotalDurationSeconds = 0.0;
    public WriteableBitmap BitmapSource = null;
    public int CurrentFrameIndex = 0;
    public int MaxPreviewSide = 720;
    public int PreviewWidth = 0, PreviewHeight = 0;
    public double PreviewScale = 1.0;
    public string LoadError = null;
    public long CachedFrameBytes { get { return _cachedBytes; } }
    public long CheckpointBytes { get { return _checkpointBytes; } }

    private sealed class FrameInfo {
        public int Left, Top, Width, Height, DelayMs, Disposal;
        public bool HasTransparency;
        public int TransparentColorIndex;
        public double Timestamp;
    }
    private sealed class Checkpoint {
        public int Index;
        public byte[] Canvas, Restore;
        public long Bytes { get { return (long)Canvas.Length + Restore.Length; } }
    }
    private readonly List<FrameInfo> _frames = new List<FrameInfo>();
    private readonly Dictionary<int, RawGifFrame> _frameCache = new Dictionary<int, RawGifFrame>();
    private readonly LinkedList<int> _frameLru = new LinkedList<int>();
    private readonly Dictionary<int, LinkedListNode<int>> _frameNodes = new Dictionary<int, LinkedListNode<int>>();
    private readonly SortedDictionary<int, Checkpoint> _checkpoints = new SortedDictionary<int, Checkpoint>();
    private FileStream _stream;
    private GifBitmapDecoder _decoder;
    private WriteableBitmap _logicalBitmap;
    private string _filePath;
    private int[] _canvasBuffer, _preFrameBuffer;
    private int _logicalBackgroundArgb, _logicalBackgroundIndex;
    private bool _hasLogicalBackground;
    private int _renderedIndex = -1;
    private int _decodedFramesInDecoder;
    private long _cachedBytes, _checkpointBytes;
    private double _nextTimeCheckpoint;
    private double _checkpointIntervalSeconds=1.0;
    private const long MaxCanvasBytes = 64L * 1024 * 1024;
    private const long MaxPersistentPlayerBytes = 128L * 1024 * 1024;
    private const long MaxCheckpointBytes = 32L * 1024 * 1024;
    private const long MaxCachedFrameBytes = 16L * 1024 * 1024;
    private const long MaxTotalDecodedPixels = 1200000000L;
    private const int MaxFrameCount = 10000;
    private const int MaxCanvasSide = 16384;
    private const int MaxDecoderBatchFrames = 8;
    private const int CheckpointStride = 24;

    public bool Load(string filePath) {
        Close();
        try {
            if (String.IsNullOrWhiteSpace(filePath) || !File.Exists(filePath)) throw new InvalidDataException("GIF file is missing.");
            _filePath = filePath;
            _stream = new FileStream(filePath, FileMode.Open, FileAccess.Read, FileShare.Read);
            byte[] header = new byte[10];
            if (_stream.Read(header, 0, header.Length) != header.Length || header[0] != (byte)'G' || header[1] != (byte)'I' || header[2] != (byte)'F')
                throw new InvalidDataException("File header is not a GIF.");
            int logicalWidth = header[6] | (header[7] << 8), logicalHeight = header[8] | (header[9] << 8);
            byte[] screen = new byte[13];
            _stream.Position = 0;
            if (_stream.Read(screen, 0, screen.Length) != screen.Length) throw new InvalidDataException("GIF logical screen descriptor is truncated.");
            int screenPacked = screen[10];
            _logicalBackgroundIndex = screen[11];
            _hasLogicalBackground = false;
            if ((screenPacked & 0x80) != 0) {
                int paletteEntries = 1 << ((screenPacked & 7) + 1);
                byte[] palette = new byte[paletteEntries * 3];
                if (_stream.Read(palette, 0, palette.Length) != palette.Length) throw new InvalidDataException("GIF global color table is truncated.");
                if (_logicalBackgroundIndex < paletteEntries) {
                    int p = _logicalBackgroundIndex * 3;
                    _logicalBackgroundArgb = unchecked((int)0xFF000000) | (palette[p] << 16) | (palette[p + 1] << 8) | palette[p + 2];
                    _hasLogicalBackground = true;
                }
            }
            _stream.Position = 0;
            _decoder = new GifBitmapDecoder(_stream, BitmapCreateOptions.PreservePixelFormat, BitmapCacheOption.OnDemand);
            if (_decoder.Frames.Count == 0 || _decoder.Frames.Count > MaxFrameCount) throw new InvalidDataException("GIF frame count is outside the supported budget.");
            FrameCount = _decoder.Frames.Count;

            var first = _decoder.Frames[0];
            var firstMeta = first.Metadata as BitmapMetadata;
            CanvasWidth = logicalWidth > 0 ? logicalWidth : ReadMeta(firstMeta, "/logscrdesc/Width", first.PixelWidth);
            CanvasHeight = logicalHeight > 0 ? logicalHeight : ReadMeta(firstMeta, "/logscrdesc/Height", first.PixelHeight);
            if (CanvasWidth < 1 || CanvasHeight < 1 || CanvasWidth > MaxCanvasSide || CanvasHeight > MaxCanvasSide ||
                (long)CanvasWidth * CanvasHeight * 4 > MaxCanvasBytes)
                throw new InvalidDataException("GIF logical canvas exceeds the supported memory budget (" + CanvasWidth + "x" + CanvasHeight + ").");

            PreviewScale = MaxPreviewSide > 0 ? Math.Min(1.0, (double)MaxPreviewSide / Math.Max(CanvasWidth, CanvasHeight)) : 1.0;
            PreviewWidth = Math.Max(1, (int)Math.Round(CanvasWidth * PreviewScale));
            PreviewHeight = Math.Max(1, (int)Math.Round(CanvasHeight * PreviewScale));
            long logicalCanvasBytes=(long)CanvasWidth*CanvasHeight*4, previewCanvasBytes=(long)PreviewWidth*PreviewHeight*4;
            if(logicalCanvasBytes*3+previewCanvasBytes+MaxCachedFrameBytes+MaxCheckpointBytes>MaxPersistentPlayerBytes)
                throw new InvalidDataException("GIF logical canvas plus preview exceeds the total player-memory budget; reduce MaxPreviewSide.");
            _canvasBuffer = new int[checked(CanvasWidth * CanvasHeight)];
            _preFrameBuffer = new int[_canvasBuffer.Length];
            _frames.Clear();
            double elapsed = 0;
            long declaredPixels = 0;
            for (int i = 0; i < FrameCount; i++) {
                var frame = _decoder.Frames[i];
                var meta = frame.Metadata as BitmapMetadata;
                int delayCs = ReadMeta(meta, "/grctlext/Delay", 10);
                if (delayCs <= 0) delayCs = 10;
                int fw = frame.PixelWidth, fh = frame.PixelHeight;
                if (fw < 1 || fh < 1 || fw > MaxCanvasSide || fh > MaxCanvasSide) throw new InvalidDataException("GIF frame dimensions are invalid.");
                declaredPixels += (long)fw * fh;
                if (declaredPixels > MaxTotalDecodedPixels) throw new InvalidDataException("GIF exceeds the cumulative decoded-pixel budget.");
                var info = new FrameInfo {
                    Left = ReadMeta(meta, "/imgdesc/Left", 0), Top = ReadMeta(meta, "/imgdesc/Top", 0),
                    Width = fw, Height = fh, DelayMs = delayCs * 10,
                    Disposal = Math.Max(0, Math.Min(3, ReadMeta(meta, "/grctlext/Disposal", 1))),
                    HasTransparency = ReadMeta(meta, "/grctlext/TransparencyFlag", 0) != 0,
                    TransparentColorIndex = ReadMeta(meta, "/grctlext/TransparentColorIndex", -1), Timestamp = elapsed
                };
                _frames.Add(info);
                elapsed += info.DelayMs / 1000.0;
            }
            TotalDurationSeconds = elapsed > 0 ? elapsed : 1.0;
            // Keep generic time anchors dense enough for short seeks while allowing
            // the compressed checkpoint budget to prune them uniformly on large canvases.
            _checkpointIntervalSeconds=Math.Max(0.5,TotalDurationSeconds/128.0);_nextTimeCheckpoint=0.0;
            BitmapSource = new WriteableBitmap(PreviewWidth, PreviewHeight, 96, 96, PixelFormats.Bgra32, null);
            _logicalBitmap = new WriteableBitmap(CanvasWidth, CanvasHeight, 96, 96, PixelFormats.Bgra32, null);
            IsLoaded = true;
            CurrentFrameIndex = 0;
            RenderToFrame(0);
            LoadError = null;
            return true;
        } catch (Exception ex) {
            LoadError = ex.Message;
            CloseResources();
            ResetState();
            return false;
        }
    }

    public void Close() { CloseResources(); ResetState(); LoadError = null; }
    public void Dispose() { Close(); }

    // Called on a worker STA. Decode/checkpoint work stays off the UI thread; only plain
    // metadata and array ownership cross threads. The returned state is a one-shot transfer object.
    public GifPlayerPreparedState PrepareForTransfer() {
        if (!IsLoaded) throw new InvalidOperationException("GIF player is not loaded.");
        RenderToFrame(FrameCount - 1);
        SeekToSeconds(0.0);
        ReleaseDecoder();
        var state = new GifPlayerPreparedState {
            FilePath = _filePath, CanvasWidth = CanvasWidth, CanvasHeight = CanvasHeight, FrameCount = FrameCount,
            PreviewWidth = PreviewWidth, PreviewHeight = PreviewHeight, CurrentFrameIndex = CurrentFrameIndex,
            MaxPreviewSide = MaxPreviewSide, BackgroundArgb = _logicalBackgroundArgb, BackgroundIndex = _logicalBackgroundIndex,
            HasBackground = _hasLogicalBackground, TotalDurationSeconds = TotalDurationSeconds, PreviewScale = PreviewScale,
            Frames = new object[_frames.Count], CachedFrames = new object[_frameCache.Count],
            Checkpoints = new object[_checkpoints.Count], Canvas = _canvasBuffer, Restore = _preFrameBuffer
        };
        for (int i = 0; i < _frames.Count; i++) {
            var f = _frames[i];
            state.Frames[i] = new object[] { f.Left, f.Top, f.Width, f.Height, f.DelayMs, f.Disposal, f.HasTransparency, f.TransparentColorIndex, f.Timestamp };
        }
        int c = 0;
        foreach (var pair in _frameCache) {
            var f = pair.Value;
            state.CachedFrames[c++] = new object[] { pair.Key, new RawGifFrame { Left=f.Left, Top=f.Top, Width=f.Width, Height=f.Height,
                DelayMs=f.DelayMs, Disposal=f.Disposal, PixelWidth=f.PixelWidth, PixelHeight=f.PixelHeight, Pixels=f.Pixels } };
        }
        c = 0;
        foreach (var pair in _checkpoints) state.Checkpoints[c++] = new object[] { pair.Key, pair.Value.Canvas, pair.Value.Restore };
        // Transfer array ownership to the plain state object; caller may now close this worker instance.
        _canvasBuffer=null; _preFrameBuffer=null; _frameCache.Clear(); _frameLru.Clear(); _frameNodes.Clear(); _checkpoints.Clear();
        _cachedBytes=0; _checkpointBytes=0;
        return state;
    }

    // Called only on the receiving UI thread; creates a new thread-affine WriteableBitmap.
    public bool AdoptOnCurrentThread(GifPlayerPreparedState state) {
        Close();
        if (state == null || state.Frames == null || state.Canvas == null || state.Restore == null) return false;
        try {
            _filePath=state.FilePath; CanvasWidth=state.CanvasWidth; CanvasHeight=state.CanvasHeight; FrameCount=state.FrameCount;
            PreviewWidth=state.PreviewWidth; PreviewHeight=state.PreviewHeight; CurrentFrameIndex=state.CurrentFrameIndex;
            MaxPreviewSide=state.MaxPreviewSide; _logicalBackgroundArgb=state.BackgroundArgb; _logicalBackgroundIndex=state.BackgroundIndex;
            _hasLogicalBackground=state.HasBackground; TotalDurationSeconds=state.TotalDurationSeconds; PreviewScale=state.PreviewScale;
            _frames.Clear();
            foreach (object[] a in state.Frames) _frames.Add(new FrameInfo { Left=(int)a[0], Top=(int)a[1], Width=(int)a[2], Height=(int)a[3],
                DelayMs=(int)a[4], Disposal=(int)a[5], HasTransparency=(bool)a[6], TransparentColorIndex=(int)a[7], Timestamp=(double)a[8] });
            _canvasBuffer=state.Canvas; _preFrameBuffer=state.Restore;
            _frameCache.Clear(); _frameLru.Clear(); _frameNodes.Clear(); _cachedBytes=0;
            foreach (object[] pair in state.CachedFrames) {
                int index=(int)pair[0]; var f=(RawGifFrame)pair[1];
                _frameCache[index]=f; _cachedBytes+=(long)f.Pixels.Length*4; _frameNodes[index]=_frameLru.AddFirst(index);
            }
            foreach (object[] a in state.Checkpoints) { var cp=new Checkpoint { Index=(int)a[0], Canvas=(byte[])a[1], Restore=(byte[])a[2] }; _checkpoints[cp.Index]=cp; _checkpointBytes+=cp.Bytes; }
            BitmapSource=new WriteableBitmap(PreviewWidth,PreviewHeight,96,96,PixelFormats.Bgra32,null);
            _logicalBitmap=new WriteableBitmap(CanvasWidth,CanvasHeight,96,96,PixelFormats.Bgra32,null);
            IsLoaded=true; _renderedIndex=CurrentFrameIndex; CommitToBitmap(); LoadError=null;
            state.Frames=null; state.CachedFrames=null; state.Checkpoints=null; state.Canvas=null; state.Restore=null;
            return true;
        } catch(Exception ex) { LoadError=ex.Message; CloseResources(); ResetState(); return false; }
    }

    public int NextFrame() {
        if (!IsLoaded || FrameCount <= 1) return 100;
        int next = (CurrentFrameIndex + 1) % FrameCount;
        StepToNext(next);
        CurrentFrameIndex = next;
        return _frames[next].DelayMs;
    }

    public void StepToNext(int targetIndex) {
        if (!IsLoaded || targetIndex < 0 || targetIndex >= FrameCount) return;
        if (targetIndex == 0 || targetIndex != _renderedIndex + 1) { RenderToFrame(targetIndex); return; }
        ApplyDisposal(_frames[_renderedIndex]);
        var next = GetFrame(targetIndex);
        if (_frames[targetIndex].Disposal == 3) Array.Copy(_canvasBuffer, _preFrameBuffer, _canvasBuffer.Length);
        DrawFrame(next);
        _renderedIndex = targetIndex;
        CurrentFrameIndex = targetIndex;
        MaybeSaveCheckpoint(targetIndex);
        CommitToBitmap();
    }

    public void SeekToSeconds(double seconds) {
        if (!IsLoaded || FrameCount == 0 || Double.IsNaN(seconds) || Double.IsInfinity(seconds)) return;
        int target=FrameIndexAtSeconds(seconds);
        if (target == CurrentFrameIndex && target == _renderedIndex) return;
        if (target == _renderedIndex + 1) StepToNext(target); else RenderToFrame(target);
    }

    public int FrameIndexAtSeconds(double seconds) {
        if(!IsLoaded||FrameCount==0||Double.IsNaN(seconds)||Double.IsInfinity(seconds))return 0;
        seconds%=TotalDurationSeconds;if(seconds<0)seconds+=TotalDurationSeconds;
        for(int i=FrameCount-1;i>=0;i--)if(seconds>=_frames[i].Timestamp)return i;
        return 0;
    }

    public void RenderToFrame(int targetIndex) {
        if (!IsLoaded || targetIndex < 0 || targetIndex >= FrameCount) return;
        Checkpoint cp = FindCheckpoint(targetIndex);
        int start;
        if (cp == null) {
            FillCanvas(InitialCanvasColor());
            Array.Clear(_preFrameBuffer, 0, _preFrameBuffer.Length);
            start = 0;
        } else {
            DecompressInts(cp.Canvas, _canvasBuffer);
            DecompressInts(cp.Restore, _preFrameBuffer);
            start = cp.Index + 1;
        }
        for (int i = start; i <= targetIndex; i++) {
            if (i > 0 && (i > start || cp != null)) ApplyDisposal(_frames[i - 1]);
            if (_frames[i].Disposal == 3) Array.Copy(_canvasBuffer, _preFrameBuffer, _canvasBuffer.Length);
            DrawFrame(GetFrame(i));
            MaybeSaveCheckpoint(i);
        }
        _renderedIndex = targetIndex;
        CurrentFrameIndex = targetIndex;
        CommitToBitmap();
    }

    public int GetPixelAlpha(int x, int y) { int px = GetLogicalPixel(x, y); return (px >> 24) & 255; }
    public int GetPixelRgb(int x, int y) { return GetLogicalPixel(x, y) & 0x00FFFFFF; }
    public int MapLogicalXToPreview(int x) { return PreviewWidth <= 0 ? 0 : Math.Max(0, Math.Min(PreviewWidth - 1, (int)Math.Floor(x * PreviewScale))); }
    public int MapLogicalYToPreview(int y) { return PreviewHeight <= 0 ? 0 : Math.Max(0, Math.Min(PreviewHeight - 1, (int)Math.Floor(y * PreviewScale))); }

    private int GetLogicalPixel(int x, int y) {
        if (_canvasBuffer == null || x < 0 || x >= CanvasWidth || y < 0 || y >= CanvasHeight) return 0;
        int px = Math.Min(PreviewWidth - 1, MapLogicalXToPreview(x));
        int py = Math.Min(PreviewHeight - 1, MapLogicalYToPreview(y));
        return _canvasBuffer[y * CanvasWidth + x];
    }

    private RawGifFrame GetFrame(int index) {
        RawGifFrame cached;
        if (_frameCache.TryGetValue(index, out cached)) { TouchFrame(index); return cached; }
        if (_decoder == null) {
            _stream = File.OpenRead(_filePath);
            _decoder = new GifBitmapDecoder(_stream, BitmapCreateOptions.PreservePixelFormat, BitmapCacheOption.OnDemand);
            _decodedFramesInDecoder = 0;
        }
        var frame = _decoder.Frames[index];
        int pw = frame.PixelWidth, ph = frame.PixelHeight;
        long decodedBytes = (long)pw * ph * 4;
        if (decodedBytes > MaxCachedFrameBytes) throw new InvalidDataException("GIF frame exceeds the decoded-frame memory budget.");
        var converted = new FormatConvertedBitmap(frame, PixelFormats.Bgra32, null, 0);
        int[] pixels = new int[checked(pw * ph)];
        converted.CopyPixels(new Int32Rect(0, 0, pw, ph), pixels, pw * 4, 0);
        var info = _frames[index];
        var raw = new RawGifFrame { Left = info.Left, Top = info.Top, Width = info.Width, Height = info.Height,
            PixelWidth = pw, PixelHeight = ph, DelayMs = info.DelayMs, Disposal = info.Disposal, Pixels = pixels };
        _decodedFramesInDecoder++;
        if (_decodedFramesInDecoder >= MaxDecoderBatchFrames) ReleaseDecoder();
        if (decodedBytes <= MaxCachedFrameBytes) {
            while (_cachedBytes + decodedBytes > MaxCachedFrameBytes && _frameLru.Last != null) EvictFrame(_frameLru.Last.Value);
            _frameCache[index] = raw;
            _cachedBytes += decodedBytes;
            _frameNodes[index] = _frameLru.AddFirst(index);
        }
        return raw;
    }

    private void DrawFrame(RawGifFrame f) {
        int left = f.Left, top = f.Top;
        for (int r = 0; r < f.PixelHeight; r++) {
            int dy = top + r; if (dy < 0 || dy >= CanvasHeight) continue;
            int row = r * f.PixelWidth, dstRow = dy * CanvasWidth;
            for (int c = 0; c < f.PixelWidth; c++) {
                int dx = left + c; if (dx < 0 || dx >= CanvasWidth) continue;
                int px = f.Pixels[row + c]; int alpha=(int)((uint)px>>24);
                if(alpha==0) continue;
                if(alpha==255){_canvasBuffer[dstRow+dx]=px;continue;}
                int dst=_canvasBuffer[dstRow+dx], da=(int)((uint)dst>>24), inv=255-alpha;
                long denominator=(long)alpha*255+(long)da*inv;
                if(denominator<=0)continue;
                int outA=(int)((denominator+127)/255);
                int b=(int)(((long)(px&255)*alpha*255+(long)(dst&255)*da*inv+denominator/2)/denominator);
                int g=(int)(((long)((px>>8)&255)*alpha*255+(long)((dst>>8)&255)*da*inv+denominator/2)/denominator);
                int red=(int)(((long)((px>>16)&255)*alpha*255+(long)((dst>>16)&255)*da*inv+denominator/2)/denominator);
                _canvasBuffer[dstRow+dx]=(outA<<24)|(red<<16)|(g<<8)|b;
            }
        }
    }

    private void ApplyDisposal(FrameInfo f) {
        if (f.Disposal == 2) {
            int left = f.Left, top = f.Top;
            int right = f.Left + f.Width, bottom = f.Top + f.Height;
            int fill = f.HasTransparency ? 0 : (_hasLogicalBackground ? _logicalBackgroundArgb : 0);
            for (int y = Math.Max(0, top); y < Math.Min(CanvasHeight, bottom); y++)
                for (int x = Math.Max(0, left); x < Math.Min(CanvasWidth, right); x++) _canvasBuffer[y * CanvasWidth + x] = fill;
        } else if (f.Disposal == 3) Array.Copy(_preFrameBuffer, _canvasBuffer, _canvasBuffer.Length);
    }

    private int InitialCanvasColor() {
        if (!_hasLogicalBackground) return 0;
        if (_frames.Count > 0 && _frames[0].HasTransparency) return 0;
        return _logicalBackgroundArgb;
    }
    private void FillCanvas(int color) { for (int i = 0; i < _canvasBuffer.Length; i++) _canvasBuffer[i] = color; }

    private void CommitToBitmap() {
        if (BitmapSource == null || _logicalBitmap == null) return;
        _logicalBitmap.WritePixels(new Int32Rect(0,0,CanvasWidth,CanvasHeight),_canvasBuffer,CanvasWidth*4,0);
        if(PreviewWidth==CanvasWidth&&PreviewHeight==CanvasHeight){BitmapSource.WritePixels(new Int32Rect(0,0,PreviewWidth,PreviewHeight),_canvasBuffer,CanvasWidth*4,0);return;}
        var scaled=new TransformedBitmap(_logicalBitmap,new ScaleTransform((double)PreviewWidth/CanvasWidth,(double)PreviewHeight/CanvasHeight));
        var pixels=new int[checked(PreviewWidth*PreviewHeight)];
        scaled.CopyPixels(new Int32Rect(0,0,PreviewWidth,PreviewHeight),pixels,PreviewWidth*4,0);
        BitmapSource.WritePixels(new Int32Rect(0,0,PreviewWidth,PreviewHeight),pixels,PreviewWidth*4,0);
    }

    private void MaybeSaveCheckpoint(int index) {
        if(_checkpoints.ContainsKey(index))return;
        bool stride=(index+1)%CheckpointStride==0;
        bool timed=_frames[index].Timestamp+1e-9>=_nextTimeCheckpoint;
        if(!stride&&!timed)return;
        if(timed)_nextTimeCheckpoint=_frames[index].Timestamp+_checkpointIntervalSeconds;
        SaveCheckpoint(index);
    }
    private void SaveCheckpoint(int index) {
        var canvas=CompressInts(_canvasBuffer); var restore=CompressInts(_preFrameBuffer);
        long bytes=(long)canvas.Length+restore.Length;
        if (bytes > MaxCheckpointBytes) return;
        while (_checkpointBytes + bytes > MaxCheckpointBytes && _checkpoints.Count > 0) {
            int[] keys=new int[_checkpoints.Count];_checkpoints.Keys.CopyTo(keys,0);int remove=keys[0];double best=Double.MaxValue;
            if(keys.Length>2){for(int i=1;i<keys.Length-1;i++){double span=_frames[keys[i+1]].Timestamp-_frames[keys[i-1]].Timestamp;if(span<best){best=span;remove=keys[i];}}}
            else if(keys.Length>1)remove=keys[0];
            _checkpointBytes -= _checkpoints[remove].Bytes; _checkpoints.Remove(remove);
        }
        var cp = new Checkpoint { Index = index, Canvas = canvas, Restore = restore };
        _checkpoints[index] = cp; _checkpointBytes += cp.Bytes;
    }

    private Checkpoint FindCheckpoint(int target) {
        Checkpoint result = null;
        foreach (var pair in _checkpoints) { if (pair.Key > target) break; result = pair.Value; }
        return result;
    }
    private static byte[] CompressInts(int[] pixels) {
        byte[] raw=new byte[pixels.Length*4]; Buffer.BlockCopy(pixels,0,raw,0,raw.Length);
        using(var output=new MemoryStream()) {
            using(var deflate=new System.IO.Compression.DeflateStream(output,System.IO.Compression.CompressionLevel.Fastest,true)) deflate.Write(raw,0,raw.Length);
            return output.ToArray();
        }
    }
    private static void DecompressInts(byte[] compressed,int[] destination) {
        byte[] chunk=new byte[64*1024]; int total=0, expected=checked(destination.Length*4);
        using(var input=new MemoryStream(compressed,false)) using(var deflate=new System.IO.Compression.DeflateStream(input,System.IO.Compression.CompressionMode.Decompress)) {
            while(total<expected){int n=deflate.Read(chunk,0,Math.Min(chunk.Length,expected-total));if(n<=0)throw new InvalidDataException("GIF checkpoint is truncated.");Buffer.BlockCopy(chunk,0,destination,total,n);total+=n;}
            if(deflate.ReadByte()!=-1)throw new InvalidDataException("GIF checkpoint exceeds the logical canvas size.");
        }
    }
    private void TouchFrame(int index) { LinkedListNode<int> n; if (_frameNodes.TryGetValue(index, out n)) { _frameLru.Remove(n); _frameLru.AddFirst(n); } }
    private void EvictFrame(int index) { RawGifFrame f; if (_frameCache.TryGetValue(index, out f)) { _cachedBytes -= (long)f.Pixels.Length * 4; _frameCache.Remove(index); } LinkedListNode<int> n; if (_frameNodes.TryGetValue(index, out n)) { _frameLru.Remove(n); _frameNodes.Remove(index); } }
    private static int ReadMeta(BitmapMetadata meta, string query, int fallback) { try { return meta == null ? fallback : Convert.ToInt32(meta.GetQuery(query)); } catch { return fallback; } }
    private void ReleaseDecoder() { _decoder = null; if (_stream != null) { try { _stream.Dispose(); } catch { } _stream = null; } _decodedFramesInDecoder = 0; }
    private void CloseResources() { ReleaseDecoder(); _filePath = null; }
    private void ResetState() {
        IsLoaded = false; _frames.Clear(); _frameCache.Clear(); _frameLru.Clear(); _frameNodes.Clear(); _cachedBytes = 0;
        _checkpoints.Clear(); _checkpointBytes = 0; _canvasBuffer = null; _preFrameBuffer = null; BitmapSource = null; _logicalBitmap=null;
        FrameCount = CanvasWidth = CanvasHeight = PreviewWidth = PreviewHeight = CurrentFrameIndex = 0;
        TotalDurationSeconds = 0; PreviewScale = 1; _renderedIndex = -1;
        _nextTimeCheckpoint=0;_checkpointIntervalSeconds=1.0;
        _logicalBackgroundArgb = _logicalBackgroundIndex = 0; _hasLogicalBackground = false;
    }
}
