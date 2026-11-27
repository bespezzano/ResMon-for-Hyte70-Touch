// npwatch: a small background watcher for the music auto-switch. Every second it asks Windows' media controls
// what's playing and writes one line to the output file when that changes:
//   <status>\t<album>\t<title>\t<artist>\t<music 1|0>      (status: Playing, Paused, Stopped, None, ...)
// Every 2 seconds it also writes which game from known-games.txt is running (or an empty line), for game.lua,
// so a known game is detected even when it isn't the focused app, and whenever the focused app changes it writes
// that app's exe, whether its window is fullscreen and its install path (game.lua's "is it a game?" check), and it keeps the music page's
// "Recently played" list (history.txt and cover thumbnails in the history folder).
// One instance at a time; exits by itself when Rainmeter isn't running. The builder compiles it with the C#
// compiler that ships with Windows (.NET Framework 4), so nothing has to be installed.
using System;
using System.Diagnostics;
using System.IO;
using System.Linq;
using System.Text;
using System.Threading;
using Windows.Foundation;
using Windows.Media.Control;

static class NpWatch
{
    static GlobalSystemMediaTransportControlsSessionManager manager;

    static string Read()
    {
        if (manager == null) manager = Wait(GlobalSystemMediaTransportControlsSessionManager.RequestAsync());
        var sessions = manager.GetSessions().ToList();
        var current = manager.GetCurrentSession();
        var playing = sessions.Where(s => s.GetPlaybackInfo().PlaybackStatus ==
            GlobalSystemMediaTransportControlsSessionPlaybackStatus.Playing).ToList();
        GlobalSystemMediaTransportControlsSession pick = null;
        if (playing.Count > 0)
            pick = (current != null && playing.Any(s => s.SourceAppUserModelId == current.SourceAppUserModelId)) ? current : playing[0];
        else
            pick = current;
        curProps = null;
        if (pick == null) { curPlaying = curMusic = false; return "None\t\t\t\t0"; }
        var p = Wait(pick.TryGetMediaPropertiesAsync());
        curProps = p;
        curPlaying = pick.GetPlaybackInfo().PlaybackStatus == GlobalSystemMediaTransportControlsSessionPlaybackStatus.Playing;
        curMusic = IsMusic(pick.SourceAppUserModelId, p.AlbumTitle);
        return string.Join("\t", pick.GetPlaybackInfo().PlaybackStatus.ToString(),
            Clean(p.AlbumTitle), Clean(p.Title), Clean(p.Artist), curMusic ? "1" : "0");
    }

    static GlobalSystemMediaTransportControlsSessionMediaProperties curProps;
    static bool curPlaying, curMusic;

    // ---- recently played: a music track that has played for 5 s is added to <dir>\history.txt (newest first,
    // "<unix time>\t<title>\t<artist>\t<thumbnail file>") with a small rounded cover thumbnail next to it
    static string histKey;
    static int histSecs;
    static bool histDone;
    const int HistoryMax = 30;

    static void TrackHistory(string dir)
    {
        var p = curProps;
        if (p == null || !curPlaying || !curMusic || string.IsNullOrEmpty(p.Title)) return;
        string key = Clean(p.Title) + "\t" + Clean(p.Artist);
        if (key != histKey) { histKey = key; histSecs = 0; histDone = false; }
        if (histDone || ++histSecs < 5) return;
        histDone = true;
        Directory.CreateDirectory(dir);
        string file = Path.Combine(dir, "history.txt");
        var lines = File.Exists(file) ? File.ReadAllLines(file, Encoding.UTF8).Where(l => l.Trim() != "").ToList()
                                      : new System.Collections.Generic.List<string>();
        if (lines.Count > 0)
        {
            var top = lines[0].Split('\t');
            if (top.Length >= 3 && top[1] + "\t" + top[2] == key) return;   // resumed the same track
        }
        string thumb = "";
        try { thumb = SaveThumb(p, dir, key); } catch (Exception) { }
        long now = (long)(DateTime.UtcNow - new DateTime(1970, 1, 1)).TotalSeconds;
        lines.Insert(0, now + "\t" + key + "\t" + thumb);
        if (lines.Count > HistoryMax) lines = lines.Take(HistoryMax).ToList();
        Write(file, string.Join("\n", lines));
        // remove thumbnails nobody refers to any more
        var keep = new System.Collections.Generic.HashSet<string>(lines.Select(l => l.Split('\t')).Where(a => a.Length >= 4).Select(a => a[3]));
        foreach (var f in Directory.GetFiles(dir, "t*.png"))
            if (!keep.Contains(Path.GetFileName(f))) try { File.Delete(f); } catch (Exception) { }
    }

    static string SaveThumb(GlobalSystemMediaTransportControlsSessionMediaProperties p, string dir, string key)
    {
        if (p.Thumbnail == null) return "";
        var stream = Wait(p.Thumbnail.OpenReadAsync());
        var reader = new Windows.Storage.Streams.DataReader(stream.GetInputStreamAt(0));
        uint size = Wait(reader.LoadAsync((uint)stream.Size));
        var bytes = new byte[size];
        reader.ReadBytes(bytes);
        string name = "t" + ((uint)key.GetHashCode()).ToString("x8") + ".png";
        using (var src = System.Drawing.Image.FromStream(new MemoryStream(bytes)))
        using (var bmp = new System.Drawing.Bitmap(120, 120))
        using (var g = System.Drawing.Graphics.FromImage(bmp))
        {
            g.SmoothingMode = System.Drawing.Drawing2D.SmoothingMode.AntiAlias;
            g.InterpolationMode = System.Drawing.Drawing2D.InterpolationMode.HighQualityBicubic;
            int s = Math.Min(src.Width, src.Height);   // centre square (video thumbnails are 16:9)
            using (var path = new System.Drawing.Drawing2D.GraphicsPath())
            {
                int r = 14;
                path.AddArc(0, 0, r * 2, r * 2, 180, 90); path.AddArc(120 - r * 2, 0, r * 2, r * 2, 270, 90);
                path.AddArc(120 - r * 2, 120 - r * 2, r * 2, r * 2, 0, 90); path.AddArc(0, 120 - r * 2, r * 2, r * 2, 90, 90);
                path.CloseFigure();
                g.SetClip(path);
                g.DrawImage(src, new System.Drawing.Rectangle(0, 0, 120, 120),
                    new System.Drawing.Rectangle((src.Width - s) / 2, (src.Height - s) / 2, s, s), System.Drawing.GraphicsUnit.Pixel);
            }
            bmp.Save(Path.Combine(dir, name), System.Drawing.Imaging.ImageFormat.Png);
        }
        return name;
    }

    // Music rather than a video: the player reports an album, it's a music app, or (browsers report everything
    // as music) a browser window shows YouTube Music. Chrome's window title is its visible tab's, so a YouTube
    // Music tab behind another tab only counts when the track has an album.
    static bool IsMusic(string app, string album)
    {
        if (!string.IsNullOrEmpty(album)) return true;
        app = (app ?? "").ToLowerInvariant();
        if (app.Contains("spotify") || app.Contains("cinhimbnkkaeohfgghhklpknlkffjgod") || app.Contains("zunemusic")
            || app.Contains("itunes") || app.Contains("applemusic") || app.Contains("tidal") || app.Contains("deezer")
            || app.Contains("amazon music") || app.Contains("foobar") || app.Contains("musicbee") || app.Contains("aimp"))
            return true;
        bool found = false;
        EnumWindows((h, l) =>
        {
            if (!IsWindowVisible(h)) return true;
            var sb = new StringBuilder(512);
            GetWindowText(h, sb, sb.Capacity);
            string t = sb.ToString();
            if (t.Contains("YouTube Music") || t.Contains("Spotify") || t.Contains("SoundCloud")) { found = true; return false; }
            return true;
        }, IntPtr.Zero);
        return found;
    }

    delegate bool EnumProc(IntPtr hwnd, IntPtr lParam);
    [System.Runtime.InteropServices.DllImport("user32.dll")] static extern bool EnumWindows(EnumProc cb, IntPtr lParam);
    [System.Runtime.InteropServices.DllImport("user32.dll")] static extern bool IsWindowVisible(IntPtr hwnd);
    [System.Runtime.InteropServices.DllImport("user32.dll", CharSet = System.Runtime.InteropServices.CharSet.Unicode)]
    static extern int GetWindowText(IntPtr hwnd, StringBuilder sb, int max);

    // wait for a WinRT async call without the AsTask helper (that needs the Windows SDK's metadata to compile)
    static T Wait<T>(IAsyncOperation<T> op)
    {
        for (int i = 0; op.Status == AsyncStatus.Started; i++)
        {
            if (i > 500) { op.Cancel(); throw new TimeoutException(); }
            Thread.Sleep(10);
        }
        if (op.Status != AsyncStatus.Completed) throw new InvalidOperationException(op.Status.ToString());
        return op.GetResults();
    }

    static string Clean(string s) { return (s ?? "").Replace('\t', ' ').Replace('\r', ' ').Replace('\n', ' '); }

    static void Write(string path, string line)
    {
        File.WriteAllText(path + ".tmp", line + "\n", new UTF8Encoding(false));
        if (File.Exists(path)) File.Delete(path);
        File.Move(path + ".tmp", path);
    }

    // known games (known-games.txt: one exe per line, # comments), reloaded when the file changes
    static string[] known = new string[0];
    static DateTime knownTime;

    static string RunningGame(string knownFile)
    {
        var t = File.GetLastWriteTimeUtc(knownFile);
        if (t != knownTime)
        {
            knownTime = t;
            known = File.ReadAllLines(knownFile).Select(l => l.Trim().ToLowerInvariant())
                .Where(l => l != "" && !l.StartsWith("#")).ToArray();
        }
        if (known.Length == 0) return "";
        var running = new System.Collections.Generic.HashSet<string>(
            Process.GetProcesses().Select(p => p.ProcessName.ToLowerInvariant() + ".exe"));
        return known.FirstOrDefault(running.Contains) ?? "";
    }

    // the focused app, for game.lua's "is this a game?" check: <exe>\t<fullscreen 1|0>\t<full exe path>
    // (fullscreen: the window covers its whole monitor, as exclusive and borderless-fullscreen games do)
    struct RECT { public int L, T, R, B; }
    struct MONITORINFO { public int cbSize; public RECT rcMonitor, rcWork; public uint dwFlags; }
    [System.Runtime.InteropServices.DllImport("user32.dll")] static extern IntPtr GetForegroundWindow();
    [System.Runtime.InteropServices.DllImport("user32.dll")] static extern bool IsZoomed(IntPtr hwnd);
    [System.Runtime.InteropServices.DllImport("user32.dll")] static extern uint GetWindowThreadProcessId(IntPtr hwnd, out uint pid);
    [System.Runtime.InteropServices.DllImport("user32.dll")] static extern bool GetWindowRect(IntPtr hwnd, out RECT r);
    [System.Runtime.InteropServices.DllImport("user32.dll")] static extern IntPtr MonitorFromWindow(IntPtr hwnd, uint flags);
    [System.Runtime.InteropServices.DllImport("user32.dll")] static extern bool GetMonitorInfo(IntPtr mon, ref MONITORINFO mi);
    [System.Runtime.InteropServices.DllImport("kernel32.dll")] static extern IntPtr OpenProcess(uint access, bool inherit, uint pid);
    [System.Runtime.InteropServices.DllImport("kernel32.dll")] static extern bool CloseHandle(IntPtr h);
    [System.Runtime.InteropServices.DllImport("kernel32.dll", CharSet = System.Runtime.InteropServices.CharSet.Unicode)]
    static extern bool QueryFullProcessImageName(IntPtr h, int flags, StringBuilder name, ref int size);

    static string Focused()
    {
        IntPtr w = GetForegroundWindow();
        if (w == IntPtr.Zero) return "";
        uint pid; GetWindowThreadProcessId(w, out pid);
        string path = "";
        IntPtr h = OpenProcess(0x1000, false, pid);   // PROCESS_QUERY_LIMITED_INFORMATION (works for elevated games too)
        if (h != IntPtr.Zero)
        {
            var sb = new StringBuilder(1024); int n = sb.Capacity;
            if (QueryFullProcessImageName(h, 0, sb, ref n)) path = sb.ToString();
            CloseHandle(h);
        }
        if (path == "") return "";
        RECT r; var mi = new MONITORINFO { cbSize = System.Runtime.InteropServices.Marshal.SizeOf(typeof(MONITORINFO)) };
        // a maximised window also overhangs the screen edges a little, but isn't fullscreen
        bool full = !IsZoomed(w) && GetWindowRect(w, out r) && GetMonitorInfo(MonitorFromWindow(w, 2), ref mi)
            && r.L <= mi.rcMonitor.L && r.T <= mi.rcMonitor.T && r.R >= mi.rcMonitor.R && r.B >= mi.rcMonitor.B;
        return Path.GetFileName(path).ToLowerInvariant() + "\t" + (full ? "1" : "0") + "\t" + path.ToLowerInvariant();
    }

    // args: <media status file> [<known-games.txt> <running known game file> [<history folder> [<focus file>]]]
    static int Main(string[] args)
    {
        if (args.Length < 1) return 2;
        string outFile = args[0];
        string knownFile = args.Length >= 3 ? args[1] : null, gameFile = args.Length >= 3 ? args[2] : null;
        string histDir = args.Length >= 4 && args[3] != "" ? args[3] : null;
        string focusFile = args.Length >= 5 && args[4] != "" ? args[4] : null;
        bool created;
        using (var mutex = new Mutex(true, "Local\\ResMonNpWatch", out created))
        {
            if (!created) return 0;
            PointerKeeper.Start();
            string last = null, lastGame = null, lastFocus = null;
            int tick = 0;
            while (true)
            {
                if (tick % 10 == 0 && Process.GetProcessesByName("Rainmeter").Length == 0) return 0;
                try
                {
                    string line = Read();
                    if (line != last) { Write(outFile, line); last = line; }
                }
                catch (Exception) { manager = null; curProps = null; }   // Windows' media service restarted: ask again next time
                if (histDir != null) try { TrackHistory(histDir); } catch (Exception) { }
                if (focusFile != null) try
                {
                    string f = Focused();
                    if (f != lastFocus) { Write(focusFile, f); lastFocus = f; }
                }
                catch (Exception) { }
                if (knownFile != null && tick % 2 == 0)
                {
                    try
                    {
                        string game = File.Exists(knownFile) ? RunningGame(knownFile) : "";
                        if (game != lastGame) { Write(gameFile, game); lastGame = game; }
                    }
                    catch (Exception) { }
                }
                tick++;
                Thread.Sleep(1000);
            }
        }
    }
}

// Touching a screen moves the mouse pointer to the touch point, so after a swipe on the HYTE screen the pointer
// is left there. This watches mouse input (a low-level hook, which only sees events, it doesn't change them):
// when a touch starts it notes where the pointer is, and once touch input has stopped for 400 ms it puts the
// pointer back there. Touch and pen input is recognised by the signature Windows puts on the mouse events it makes
// from them (0xFF5157xx in dwExtraInfo).
static class PointerKeeper
{
    struct POINT { public int X, Y; }
    struct MSLLHOOKSTRUCT { public POINT pt; public uint mouseData, flags, time; public IntPtr extra; }
    struct MSG { public IntPtr hwnd; public uint message; public IntPtr wParam, lParam; public uint time; public POINT pt; }
    delegate IntPtr HookProc(int code, IntPtr wParam, IntPtr lParam);

    [System.Runtime.InteropServices.DllImport("user32.dll")] static extern IntPtr SetWindowsHookEx(int id, HookProc proc, IntPtr mod, uint thread);
    [System.Runtime.InteropServices.DllImport("user32.dll")] static extern IntPtr CallNextHookEx(IntPtr h, int code, IntPtr wParam, IntPtr lParam);
    [System.Runtime.InteropServices.DllImport("user32.dll")] static extern int GetMessage(out MSG msg, IntPtr hwnd, uint min, uint max);
    [System.Runtime.InteropServices.DllImport("user32.dll")] static extern bool SetCursorPos(int x, int y);
    [System.Runtime.InteropServices.DllImport("user32.dll")] static extern bool GetCursorPos(out POINT p);
    [System.Runtime.InteropServices.DllImport("user32.dll")] static extern bool SetProcessDpiAwarenessContext(IntPtr ctx);
    [System.Runtime.InteropServices.DllImport("kernel32.dll")] static extern IntPtr GetModuleHandle(string name);

    const int WH_MOUSE_LL = 14, WM_LBUTTONDOWN = 0x201, WM_LBUTTONUP = 0x202;
    static volatile bool down;
    static HookProc proc;   // kept referenced so the garbage collector doesn't free them
    static Timer timer;
    static volatile bool haveReal, pending;
    static int realX, realY, lastTouch;

    public static void Start()
    {
        // per-monitor DPI aware, so hook and SetCursorPos use real pixels on every monitor
        try { SetProcessDpiAwarenessContext(new IntPtr(-4)); } catch (Exception) { }
        var t = new Thread(() =>
        {
            proc = Hook;
            SetWindowsHookEx(WH_MOUSE_LL, proc, GetModuleHandle(null), 0);
            MSG m;
            while (GetMessage(out m, IntPtr.Zero, 0, 0) > 0) { }
        });
        t.IsBackground = true;
        t.Start();
        timer = new Timer(_ =>
        {
            // after the finger lifts (400 ms), or 2.5 s without touch input (a swipe doesn't always report the lift)
            int idle = unchecked(Environment.TickCount - lastTouch);
            if (pending && haveReal && ((!down && idle > 400) || idle > 2500))
            {
                pending = false; down = false;
                SetCursorPos(realX, realY);
            }
        }, null, 100, 100);
    }

    static IntPtr Hook(int code, IntPtr wParam, IntPtr lParam)
    {
        if (code >= 0)
        {
            var e = (MSLLHOOKSTRUCT)System.Runtime.InteropServices.Marshal.PtrToStructure(lParam, typeof(MSLLHOOKSTRUCT));
            bool touch = ((long)e.extra & 0xFFFFFF00) == 0xFF515700;
            if (touch)
            {
                // the hook runs before Windows moves the pointer, so at the first touch event of a gesture the
                // pointer is still where the mouse left it: that's where it goes back to
                POINT p;
                if (!pending && GetCursorPos(out p)) { realX = p.X; realY = p.Y; haveReal = true; }
                lastTouch = Environment.TickCount;
                pending = true;
                if ((int)wParam == WM_LBUTTONDOWN) down = true;
                else if ((int)wParam == WM_LBUTTONUP) down = false;
            }
        }
        return CallNextHookEx(IntPtr.Zero, code, wParam, lParam);
    }
}
