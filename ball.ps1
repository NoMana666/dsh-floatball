param(
  [int]$ParentPid = 0,
  [string]$SettingsDir = '',
  [string]$HeartbeatFile = '',
  [switch]$TestCapture,
  [string]$CapturePath = '',
  [switch]$TestAttention,
  [switch]$TestHover,
  [int]$CaptureDelayMs = 1200,
  [string]$MutexName = 'Global\DshFloatBall'
)

$ErrorActionPreference = 'Continue'
Add-Type -AssemblyName System.Windows.Forms, System.Drawing
if (-not ('BallForm' -as [type])) {
Add-Type -TypeDefinition @'
using System;
using System.Windows.Forms;
public class BallForm : Form {
  public BallForm() {
    this.DoubleBuffered = true;
    this.SetStyle(ControlStyles.UserPaint | ControlStyles.AllPaintingInWmPaint | ControlStyles.OptimizedDoubleBuffer | ControlStyles.Opaque, true);
  }
}
'@ -ReferencedAssemblies System.Windows.Forms, System.Drawing
}

if ([string]::IsNullOrWhiteSpace($SettingsDir)) {
  $SettingsDir = Join-Path $env:LOCALAPPDATA 'dsh-floatball'
}
New-Item -ItemType Directory -Force -Path $SettingsDir | Out-Null
$script:logFile = Join-Path $SettingsDir 'ball.log'
$script:settingsFile = Join-Path $SettingsDir 'settings.json'

function Write-Log([string]$msg) {
  try {
    $line = ('[{0}] {1}' -f (Get-Date -Format 'HH:mm:ss'), $msg)
    Add-Content -LiteralPath $script:logFile -Value $line -Encoding UTF8
  } catch {}
}

# ---------------- DPI ----------------
if (-not ('DshDpi' -as [type])) {
  Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public class DshDpi {
  [DllImport("user32.dll")] public static extern bool SetProcessDpiAwarenessContext(IntPtr v);
  [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h);
  [DllImport("user32.dll")] public static extern void SwitchToThisWindow(IntPtr h, bool altTab);
  [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr h, int c);
  [DllImport("user32.dll")] public static extern bool IsIconic(IntPtr h);
  [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
  [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr h, ref uint pid);
  [DllImport("kernel32.dll")] public static extern uint GetCurrentThreadId();
  [DllImport("user32.dll")] public static extern bool AttachThreadInput(uint a, uint b, bool attach);
  [DllImport("user32.dll")] public static extern void keybd_event(byte vk, byte scan, uint flags, IntPtr extra);
  [DllImport("user32.dll")] public static extern bool SetWindowPos(IntPtr h, IntPtr after, int x, int y, int cx, int cy, uint flags);
  [DllImport("user32.dll")] public static extern bool RedrawWindow(IntPtr h, IntPtr rect, IntPtr hrgn, uint flags);
  [DllImport("user32.dll", EntryPoint="GetWindowLongW")] public static extern int GetWindowLong(IntPtr h, int idx);
  [DllImport("user32.dll", EntryPoint="SetWindowLongW")] public static extern int SetWindowLong(IntPtr h, int idx, int val);
}
'@
}
# 关键：声明 DPI 感知，否则 Windows 会把窗口按 150% 缩放，导致模糊/锯齿/看着偏大
try { [void][DshDpi]::SetProcessDpiAwarenessContext([IntPtr](-4)) } catch {
  try { [void][DshDpi]::SetProcessDpiAwarenessContext([IntPtr](-3)) } catch {}
}

if (-not ('DshWake' -as [type])) {
  Add-Type -ReferencedAssemblies @('System.Drawing','System.Windows.Forms') -TypeDefinition @"
using System;
using System.Runtime.InteropServices;
using System.Text;
public class TrayClick {
  [DllImport("user32.dll")] static extern bool SetCursorPos(int x, int y);
  [DllImport("user32.dll")] static extern bool GetCursorPos(out POINT p);
  [DllImport("user32.dll")] static extern void mouse_event(uint flags, uint dx, uint dy, uint data, UIntPtr extra);
  [DllImport("user32.dll")] static extern int GetSystemMetrics(int index);
  [DllImport("user32.dll")] static extern bool IsIconic(IntPtr h);
  [DllImport("user32.dll")] static extern bool IsWindowVisible(IntPtr h);
  [DllImport("user32.dll")] static extern void keybd_event(byte vk, byte scan, uint flags, UIntPtr extra);
  [StructLayout(LayoutKind.Sequential)] public struct POINT { public int X; public int Y; }

  static void Log(string path, string msg) {
    try { System.IO.File.AppendAllText(path, "[" + DateTime.Now.ToString("HH:mm:ss") + "] tray: " + msg + "\r\n"); } catch {}
  }

  static bool[,] LoadTemplate(string path, out int tW, out int tH) {
    tW = 0; tH = 0;
    using (var src = new System.Drawing.Bitmap(path)) {
      int x0 = src.Width, y0 = src.Height, x1 = -1, y1 = -1;
      var ink = new bool[src.Width, src.Height];
      for (int y = 0; y < src.Height; y++)
        for (int x = 0; x < src.Width; x++) {
          var c = src.GetPixel(x, y);
          bool isInk = c.A > 30 && (c.R + c.G + c.B) / 3 < 120;
          ink[x, y] = isInk;
          if (isInk) { if (x < x0) x0 = x; if (y < y0) y0 = y; if (x > x1) x1 = x; if (y > y1) y1 = y; }
        }
      if (x1 < 0) return null;
      tW = x1 - x0 + 1; tH = y1 - y0 + 1;
      var t = new bool[tW, tH];
      for (int y = 0; y < tH; y++) for (int x = 0; x < tW; x++) t[x, y] = ink[x0 + x, y0 + y];
      return t;
    }
  }

  // 在指定屏幕区域内找鲸鱼图标，返回按可信度排序的候选点（x, y, iou）
  static System.Collections.Generic.List<double[]> MatchIn(bool[,] tmpl, int tW, int tH, int left, int top, int width, int height,
                                                           double minIou, int step, int timeoutMs, int excludeX, int excludeY, int excludeW, int excludeH) {
    var hits = new System.Collections.Generic.List<double[]>();
    if (width < 24 || height < 24) return hits;
    int stride = width * 4;
    var buf = new byte[stride * height];
    using (var shot = new System.Drawing.Bitmap(width, height, System.Drawing.Imaging.PixelFormat.Format32bppArgb))
    using (var g = System.Drawing.Graphics.FromImage(shot)) {
      g.CopyFromScreen(left, top, 0, 0, new System.Drawing.Size(width, height));
      var rect = new System.Drawing.Rectangle(0, 0, width, height);
      var data = shot.LockBits(rect, System.Drawing.Imaging.ImageLockMode.ReadOnly, System.Drawing.Imaging.PixelFormat.Format32bppArgb);
      System.Runtime.InteropServices.Marshal.Copy(data.Scan0, buf, 0, buf.Length);
      shot.UnlockBits(data);
    }
    var started = DateTime.Now;
    foreach (int size in new int[] { 16, 20, 24, 28 }) {
      if ((DateTime.Now - started).TotalMilliseconds > timeoutMs) break;
      int w = size, hh = (int)Math.Round((double)size * tH / tW);
      if (hh < 8) hh = 8;
      var t2 = new bool[w, hh];
      for (int y = 0; y < hh; y++)
        for (int x = 0; x < w; x++)
          t2[x, y] = tmpl[(int)((double)x * tW / w), (int)((double)y * tH / hh)];
      for (int y = 2; y <= height - hh - 2; y += step) {
        for (int x = 2; x <= width - w - 4; x += step) {
          int gx = left + x, gy = top + y;
          if (excludeW > 0 && gx + w > excludeX && gx < excludeX + excludeW && gy + hh > excludeY && gy < excludeY + excludeH) continue;
          int inter = 0, uni = 0;
          bool skip = false;
          for (int ty = 0; ty < hh && !skip; ty++) {
            int rowBase = (y + ty) * stride;
            for (int tx = 0; tx < w; tx++) {
              int o = rowBase + (x + tx) * 4;
              bool d = ((buf[o] + buf[o + 1] + buf[o + 2]) / 3) < 140;
              bool t = t2[tx, ty];
              if (d && t) inter++;
              if (d || t) uni++;
            }
            if (inter == 0 && ty > hh / 2) skip = true;
          }
          if (skip || uni == 0) continue;
          double iou = (double)inter / uni;
          if (iou > minIou) hits.Add(new double[] { iou, gx + w / 2, gy + hh / 2 });
        }
      }
    }
    hits.Sort((a, b) => b[0].CompareTo(a[0]));
    return hits;
  }

  static void Pick(System.Collections.Generic.List<double[]> hits, System.Collections.Generic.List<double[]> picked, int max, int gap) {
    foreach (var hit in hits) {
      bool dup = false;
      foreach (var pp in picked) if (Math.Abs(pp[1] - hit[1]) < gap && Math.Abs(pp[2] - hit[2]) < gap) { dup = true; break; }
      if (!dup) picked.Add(hit);
      if (picked.Count >= max) break;
    }
  }

  static bool ClickAndWait(System.Collections.Generic.List<double[]> picked, string log, IntPtr h, string tag) {
    POINT old; GetCursorPos(out old);
    for (int i = 0; i < picked.Count; i++) {
      int cx = (int)picked[i][1], cy = (int)picked[i][2];
      SetCursorPos(cx, cy);
      System.Threading.Thread.Sleep(70);
      mouse_event(0x0002, 0, 0, 0, UIntPtr.Zero);
      System.Threading.Thread.Sleep(40);
      mouse_event(0x0004, 0, 0, 0, UIntPtr.Zero);
      Log(log, tag + ": clicked #" + (i + 1) + " iou=" + picked[i][0].ToString("F3") + " at " + cx + "," + cy);
      for (int k = 0; k < 12; k++) {
        System.Threading.Thread.Sleep(100);
        if (IsWindowVisible(h) && !IsIconic(h)) { SetCursorPos(old.X, old.Y); Log(log, tag + ": restored after click #" + (i + 1)); return true; }
      }
    }
    SetCursorPos(old.X, old.Y);
    return false;
  }

  // 找鲸鱼图标并点击：先扫任务栏，再展开"隐藏图标"面板兜底（图标被收进 ▲ 里时走这条）
  public static bool TryRestore(string templatePath, string log, IntPtr h, int excludeX, int excludeY, int excludeW, int excludeH) {
    try {
      if (!System.IO.File.Exists(templatePath)) { Log(log, "template missing"); return false; }
      int sw = GetSystemMetrics(0), sh = GetSystemMetrics(1);
      int tW, tH;
      var tmpl = LoadTemplate(templatePath, out tW, out tH);
      if (tmpl == null) { Log(log, "template empty"); return false; }

      // ① 任务栏一条带
      var hits = MatchIn(tmpl, tW, tH, 0, sh - 130, sw, 130, 0.62, 2, 2500, excludeX, excludeY, excludeW, excludeH);
      var picked = new System.Collections.Generic.List<double[]>();
      Pick(hits, picked, 3, 30);
      if (picked.Count > 0) {
        Log(log, "taskbar candidates=" + picked.Count);
        if (ClickAndWait(picked, log, h, "taskbar")) return true;
      } else {
        Log(log, "no whale icon in taskbar");
      }

      if (IsWindowVisible(h) && !IsIconic(h)) return true;

      // 注意：不要用键盘模拟（Win+B 之类）去展开隐藏图标面板——会抢走用户焦点、把开始菜单/搜索框顶出来。
      // 图标被收进溢出面板时，交给调用方走"再启动 DSH"兜底。
      Log(log, "clicks did not restore");
      return false;
    } catch (Exception e) { Log(log, "error " + e.Message); return false; }
  }
}

public class DshWake {
  [DllImport("user32.dll")] static extern bool SetForegroundWindow(IntPtr h);
  [DllImport("user32.dll")] static extern IntPtr GetForegroundWindow();
  [DllImport("user32.dll")] static extern bool IsIconic(IntPtr h);
  [DllImport("user32.dll")] static extern bool IsWindowVisible(IntPtr h);
  [DllImport("user32.dll")] static extern bool ShowWindowAsync(IntPtr h, int c);
  [DllImport("user32.dll")] static extern bool SwitchToThisWindow(IntPtr h, bool alt);
  [DllImport("user32.dll")] static extern bool SetWindowPos(IntPtr h, IntPtr after, int x, int y, int cx, int cy, uint flags);
  [DllImport("user32.dll")] static extern IntPtr SendMessageTimeout(IntPtr h, uint msg, IntPtr w, IntPtr l, uint flags, uint timeout, out IntPtr result);
  [DllImport("user32.dll")] static extern bool GetWindowPlacement(IntPtr h, ref WINDOWPLACEMENT p);
  [DllImport("user32.dll")] static extern bool SetWindowPlacement(IntPtr h, ref WINDOWPLACEMENT p);

  [StructLayout(LayoutKind.Sequential)] struct POINT { public int X; public int Y; }
  [StructLayout(LayoutKind.Sequential)] struct RECT { public int Left; public int Top; public int Right; public int Bottom; }
  [StructLayout(LayoutKind.Sequential)] struct WINDOWPLACEMENT {
    public int length; public int flags; public int showCmd;
    public POINT ptMinPosition; public POINT ptMaxPosition; public RECT rcNormalPosition;
  }

  static int running = 0;

  static void Log(string path, string msg) {
    try { System.IO.File.AppendAllText(path, "[" + DateTime.Now.ToString("HH:mm:ss") + "] wake: " + msg + "\r\n"); } catch {}
  }

  public static bool Begin(long hwnd, string logPath, string exe, string trayTemplate, int[] exRect, bool useTray) {
    // 不再用"单飞锁"：线程可能卡在 GDI 里永远不返回，一旦锁住就全盘失效。
    // 改为允许并发（唤醒动作是幂等的），只在日志里标注并发数。
    int now = System.Threading.Interlocked.Increment(ref running);
    if (now > 1) Log(logPath, "concurrent wake x" + now);
    System.Threading.Thread t = new System.Threading.Thread(delegate () {
      try { Run(new IntPtr(hwnd), logPath, exe, trayTemplate, exRect, useTray); }
      catch (Exception e) { Log(logPath, "thread error " + e.Message); }
      finally { System.Threading.Interlocked.Decrement(ref running); }
    });
    t.IsBackground = true;
    t.Start();
    return true;
  }

  [DllImport("user32.dll")] static extern bool PostMessage(IntPtr h, uint msg, IntPtr w, IntPtr l);

  static bool TryUnminimize(IntPtr h, string log) {
    // 先让应用自己处理 SC_RESTORE（这是托盘点击走的同一条系统命令）
    PostMessage(h, 0x0112, new IntPtr(0xF120), IntPtr.Zero);
    System.Threading.Thread.Sleep(220);
    if (!IsIconic(h) && IsWindowVisible(h)) { Log(log, "SC_RESTORE ok"); return true; }
    ShowWindowAsync(h, 9);
    System.Threading.Thread.Sleep(160);
    if (!IsIconic(h) && IsWindowVisible(h)) { Log(log, "ShowWindowAsync(9) ok"); return true; }

    WINDOWPLACEMENT wp = new WINDOWPLACEMENT();
    wp.length = Marshal.SizeOf(typeof(WINDOWPLACEMENT));
    if (!GetWindowPlacement(h, ref wp)) { Log(log, "GetWindowPlacement failed"); return false; }
    Log(log, "placement showCmd=" + wp.showCmd);
    wp.showCmd = 1;
    bool ok = SetWindowPlacement(h, ref wp);
    Log(log, "SetWindowPlacement=" + ok);
    System.Threading.Thread.Sleep(200);
    return !IsIconic(h) && IsWindowVisible(h);
  }

  static void Front(IntPtr h, string log) {
    if (IsIconic(h)) { ShowWindowAsync(h, 9); System.Threading.Thread.Sleep(120); }
    ShowWindowAsync(h, 5);
    SetWindowPos(h, new IntPtr(-1), 0, 0, 0, 0, 0x0001 | 0x0002 | 0x0040);
    SetWindowPos(h, new IntPtr(-2), 0, 0, 0, 0, 0x0001 | 0x0002 | 0x0040);
    SwitchToThisWindow(h, true);
    SetForegroundWindow(h);
    System.Threading.Thread.Sleep(250);
    Log(log, "front fg=" + (GetForegroundWindow() == h));
  }

  static void Run(IntPtr h, string log, string exe, string trayTemplate, int[] exRect, bool useTray) {
    try {
      bool hidden = !IsWindowVisible(h);
      bool iconic = IsIconic(h);
      Log(log, "state hidden=" + hidden + " iconic=" + iconic);

      if (iconic && TryUnminimize(h, log)) { Front(h, log); return; }

      if ((!IsWindowVisible(h) || IsIconic(h)) && useTray) {
        if (!String.IsNullOrEmpty(trayTemplate)) {
          int ex, ey, ew, eh;
          if (exRect != null && exRect.Length == 4) { ex = exRect[0]; ey = exRect[1]; ew = exRect[2]; eh = exRect[3]; }
          else { ex = -1; ey = -1; ew = 0; eh = 0; }
          if (TrayClick.TryRestore(trayTemplate, log, h, ex, ey, ew, eh)) { Front(h, log); return; }
        }
      }

      if (!IsWindowVisible(h) || IsIconic(h)) {
        // 用户要求：不再走"二次启动"，它会把窗口恢复成一片空白、点不动的状态。
        // 只保留托盘点击这条（与用户手点托盘图标完全等价）。
        Log(log, "FAILED: tray click did not restore; please click the tray icon by hand");
        return;
      }

      Front(h, log);
      IntPtr res;
      bool pong = SendMessageTimeout(h, 0, IntPtr.Zero, IntPtr.Zero, 0x0002, 200, out res) != IntPtr.Zero;
      Log(log, "ping=" + (pong ? "pong" : "nopong"));
    } catch (Exception e) { Log(log, "error " + e.Message); }
  }
}

public class DshWin {
  [DllImport("user32.dll")] static extern bool EnumWindows(EnumProc lpEnumFunc, IntPtr lParam);
  delegate bool EnumProc(IntPtr hWnd, IntPtr lParam);
  [DllImport("user32.dll")] static extern uint GetWindowThreadProcessId(IntPtr hWnd, out uint pid);
  [DllImport("user32.dll")] static extern bool IsWindowVisible(IntPtr hWnd);
  [DllImport("user32.dll")] static extern bool IsIconic(IntPtr hWnd);
  [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern int GetWindowTextW(IntPtr hWnd, StringBuilder s, int n);
  [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern int GetClassNameW(IntPtr hWnd, StringBuilder s, int n);
  [StructLayout(LayoutKind.Sequential)] public struct RECT { public int Left, Top, Right, Bottom; }
  [DllImport("user32.dll")] static extern bool GetWindowRect(IntPtr hWnd, out RECT r);
  [DllImport("kernel32.dll")] static extern IntPtr OpenProcess(uint access, bool inherit, uint pid);
  [DllImport("kernel32.dll")] static extern bool GetExitCodeProcess(IntPtr h, out uint code);
  [DllImport("kernel32.dll")] static extern bool CloseHandle(IntPtr h);

  static bool IsPidAlive(uint pid) {
    IntPtr hp = OpenProcess(0x1000, false, pid);
    if (hp == IntPtr.Zero) return true;
    uint code;
    bool ok = GetExitCodeProcess(hp, out code);
    CloseHandle(hp);
    if (!ok) return true;
    return code == 259;
  }

  [DllImport("user32.dll")] static extern bool ShowWindow(IntPtr h, int c);
  [DllImport("user32.dll")] static extern bool SwitchToThisWindow(IntPtr h, bool alt);
  [DllImport("user32.dll")] static extern bool SetForegroundWindow(IntPtr h);
  [DllImport("user32.dll")] static extern bool PostMessage(IntPtr h, uint m, IntPtr w, IntPtr l);
  public static bool Vis(IntPtr h) { return IsWindowVisible(h); }
  public static bool Ico(IntPtr h) { return IsIconic(h); }
  public static void SC(IntPtr h) { PostMessage(h, 0x0112, new IntPtr(0xF120), IntPtr.Zero); }
  public static bool Minimize(IntPtr h) {
    if (h == IntPtr.Zero) return false;
    ShowWindow(h, 6);
    System.Threading.Thread.Sleep(80);
    if (IsIconic(h)) return true;
    ShowWindow(h, 7);
    return IsIconic(h);
  }
  public static void Front(IntPtr h) {
    if (IsIconic(h)) { ShowWindow(h, 9); System.Threading.Thread.Sleep(120); }
    ShowWindow(h, 5);
    SwitchToThisWindow(h, true);
    SetForegroundWindow(h);
  }

  public static IntPtr FindByTitle(string needle, bool visibleOnly) {
    IntPtr best = IntPtr.Zero;
    bool bestVisible = false;
    EnumWindows(delegate (IntPtr h, IntPtr l) {
      bool vis = IsWindowVisible(h);
      if (visibleOnly && !vis) return true;
      var c = new StringBuilder(128);
      GetClassNameW(h, c, 128);
      if (c.ToString() != "Chrome_WidgetWin_1") return true;
      var t = new StringBuilder(512);
      GetWindowTextW(h, t, 512);
      if (t.ToString().IndexOf(needle, StringComparison.OrdinalIgnoreCase) < 0) return true;
      uint pid; GetWindowThreadProcessId(h, out pid);
      if (!IsPidAlive(pid)) return true;
      bool ic = IsIconic(h);
      RECT r; GetWindowRect(h, out r);
      if (!ic && ((r.Right - r.Left) < 200 || (r.Bottom - r.Top) < 200)) return true;
      if (best == IntPtr.Zero || (!bestVisible && vis)) { best = h; bestVisible = vis; }
      return true;
    }, IntPtr.Zero);
    return best;
  }
}
"@
}

# ---------------- 单实例 ----------------
$script:mutex = New-Object System.Threading.Mutex($false, $MutexName)
$script:gotMutex = $false
try { $script:gotMutex = $script:mutex.WaitOne(0) } catch {}
if (-not $script:gotMutex) {
  Write-Log 'another ball is running, exit'
  exit 0
}
Write-Log 'mutex ok'

# ---------------- 设置 ----------------
$script:settings = [ordered]@{ x = -1; y = -1; size = 108; autoStart = $true; theme = 'classic'; bubble = $true }
if (Test-Path -LiteralPath $script:settingsFile) {
  try {
    $loaded = Get-Content -LiteralPath $script:settingsFile -Raw -Encoding UTF8 | ConvertFrom-Json
    foreach ($k in @('x', 'y', 'size', 'autoStart', 'theme', 'bubble')) {
      if ($null -ne $loaded.$k) { $script:settings[$k] = $loaded.$k }
    }
  } catch {}
} else {
  try {
    ($script:settings | ConvertTo-Json) | Set-Content -LiteralPath $script:settingsFile -Encoding UTF8
    Write-Log 'settings.json created'
  } catch {}
}

function Save-Settings {
  try {
    ($script:settings | ConvertTo-Json) | Set-Content -LiteralPath $script:settingsFile -Encoding UTF8
  } catch {}
}

$script:BASE = [int]$script:settings.size
if ($script:BASE -lt 60) { $script:BASE = 108 }
$script:PEAK_SCALE = 1.06
$script:PRESS_SCALE = 0.94

# 预生成缩放档位：只做整数像素，每档预渲染一次，运行时不再重采样
function Get-Steps([int]$targetPx) {
  $steps = New-Object System.Collections.Generic.List[int]
  $base = [int]$script:BASE
  for ($i = 0; $i -le 8; $i++) {
    $v = [int][math]::Round($base + ($targetPx - $base) * $i / 8.0)
    if ($steps.Count -eq 0 -or $steps[$steps.Count - 1] -ne $v) { $steps.Add($v) }
  }
  return , $steps
}

$script:stepsHover = Get-Steps ([int][math]::Round($script:BASE * $script:PEAK_SCALE))
$script:stepsPress = Get-Steps ([int][math]::Round($script:BASE * $script:PRESS_SCALE))

function Get-WinSize {
  $max = $script:BASE
  foreach ($s in $script:stepsHover) { if ($s -gt $max) { $max = $s } }
  $win = $max + 64
  if ($win -lt 160) { $win = 160 }
  return $win
}
$script:WIN = Get-WinSize

# ---------------- 贴图 ----------------
$script:here = Split-Path -Parent $MyInvocation.MyCommand.Path
$script:assets = Join-Path $script:here 'assets'
$script:theme = 'classic'
if ($script:settings.theme) { $script:theme = [string]$script:settings.theme }

$script:variants = @{}
function Load-ThemeSprites {
  $script:variants = @{}
  foreach ($state in @('valley', 'peak', 'off')) {
    foreach ($sfx in @('', '_hover', '_press')) {
      $name = "$state$sfx"
      $file = Join-Path $script:assets ("th_{0}_{1}.png" -f $script:theme, $name)
      if (-not (Test-Path -LiteralPath $file)) { $file = Join-Path $script:assets ("w2_{0}.png" -f $name) }
      if (Test-Path -LiteralPath $file) {
        try { $script:variants[$name] = [System.Drawing.Bitmap]::FromFile($file) } catch { Write-Log ('sprite load failed: ' + $name) }
      }
    }
  }
}
Load-ThemeSprites

$script:spriteCache = @{}
function Get-Sprite([int]$px, [string]$variant) {
  $key = "$variant|$px"
  if ($script:spriteCache.ContainsKey($key)) { return $script:spriteCache[$key] }
  $src = $script:variants[$variant]
  if ($null -eq $src) { $src = $script:variants['valley'] }
  $bmp = New-Object System.Drawing.Bitmap($px, $px, [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
  $g = [System.Drawing.Graphics]::FromImage($bmp)
  $g.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
  $g.PixelOffsetMode = [System.Drawing.Drawing2D.PixelOffsetMode]::HighQuality
  $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::HighQuality
  $g.DrawImage($src, 0, 0, $px, $px)
  $g.Dispose()
  $script:spriteCache[$key] = $bmp
  return $bmp
}

# ---------------- 形状 ----------------
$script:regionCache = @{}
function Get-Region([int]$px) {
  $key = "r|$px"
  if ($script:regionCache.ContainsKey($key)) { return $script:regionCache[$key] }
  $bmp = Get-Sprite $px 'valley'
  $w = $bmp.Width
  $h = $bmp.Height
  $solid = New-Object 'bool[]' ($w * $h)
  for ($y = 0; $y -lt $h; $y++) {
    for ($x = 0; $x -lt $w; $x++) {
      if ($bmp.GetPixel($x, $y).A -ge 96) { $solid[$y * $w + $x] = $true }
    }
  }
  # 从四周灌水，标记可达的外部空区
  $outside = New-Object 'bool[]' ($w * $h)
  $queue = New-Object System.Collections.Generic.Queue[int]
  for ($x = 0; $x -lt $w; $x++) {
    foreach ($y in @(0, ($h - 1))) {
      $i = $y * $w + $x
      if (-not $solid[$i] -and -not $outside[$i]) { $outside[$i] = $true; $queue.Enqueue($i) }
    }
  }
  for ($y = 0; $y -lt $h; $y++) {
    foreach ($x in @(0, ($w - 1))) {
      $i = $y * $w + $x
      if (-not $solid[$i] -and -not $outside[$i]) { $outside[$i] = $true; $queue.Enqueue($i) }
    }
  }
  while ($queue.Count -gt 0) {
    $i = $queue.Dequeue()
    $y = [int][math]::Floor($i / $w)
    $x = $i - $y * $w
    foreach ($d in @(@(1, 0), @(-1, 0), @(0, 1), @(0, -1))) {
      $nx = $x + $d[0]; $ny = $y + $d[1]
      if ($nx -lt 0 -or $ny -lt 0 -or $nx -ge $w -or $ny -ge $h) { continue }
      $ni = $ny * $w + $nx
      if (-not $solid[$ni] -and -not $outside[$ni]) { $outside[$ni] = $true; $queue.Enqueue($ni) }
    }
  }
  $whalePath = New-Object System.Drawing.Drawing2D.GraphicsPath
  $holePath = New-Object System.Drawing.Drawing2D.GraphicsPath
  for ($y = 0; $y -lt $h; $y++) {
    $runSolid = -1; $runHole = -1
    for ($x = 0; $x -le $w; $x++) {
      $isSolid = $false; $isHole = $false
      if ($x -lt $w) {
        $i = $y * $w + $x
        $isSolid = $solid[$i]
        $isHole = (-not $solid[$i]) -and (-not $outside[$i])
      }
      if ($isSolid -and $runSolid -lt 0) { $runSolid = $x }
      elseif (-not $isSolid -and $runSolid -ge 0) {
        $whalePath.AddRectangle((New-Object System.Drawing.Rectangle($runSolid, $y, ($x - $runSolid), 1)))
        $runSolid = -1
      }
      if ($isHole -and $runHole -lt 0) { $runHole = $x }
      elseif (-not $isHole -and $runHole -ge 0) {
        $holePath.AddRectangle((New-Object System.Drawing.Rectangle($runHole, $y, ($x - $runHole), 1)))
        $runHole = -1
      }
    }
  }
  $script:regionCache[$key] = @{ path = $whalePath; holes = $holePath; px = $px }
  return $script:regionCache[$key]
}

function Get-BadgeRect([int]$px, [int]$ox, [int]$oy) {
  $bd = [int][math]::Round($px * 0.34)
  $bx = $ox + $px - [int][math]::Round($bd * 0.30)
  $by = $oy + [int][math]::Round($bd * 0.02)
  return New-Object System.Drawing.Rectangle($bx, $by, $bd, $bd)
}

function Apply-Region([int]$px) {
  # 分层窗口（逐像素 alpha）不再使用 Region，避免把抗锯齿边缘裁成锯齿。
  return
  $entry = Get-Region $px
  $win = $form.ClientSize.Width
  $ox = [int][math]::Floor(($win - $px) / 2)
  $oy = [int][math]::Floor(($form.ClientSize.Height - $px) / 2)
  $m = New-Object System.Drawing.Drawing2D.Matrix
  $m.Translate([float]$ox, [float]$oy)
  $whole = New-Object System.Drawing.Drawing2D.GraphicsPath
  $p1 = $entry.path.Clone(); $p1.Transform($m); $whole.AddPath($p1, $false); $p1.Dispose()
  $p2 = $entry.holes.Clone(); $p2.Transform($m); $whole.AddPath($p2, $false); $p2.Dispose()
  $m.Dispose()
  if ($script:attention) {
    $r = Get-BadgeRect $px $ox $oy
    $whole.AddEllipse($r.X, $r.Y, $r.Width, $r.Height)
  }
  $form.Region = New-Object System.Drawing.Region($whole)
  $whole.Dispose()
}

# ---------------- 峰谷 ----------------
$script:PEAK_HOURS = @(@(9, 12), @(14, 18))
$script:HOLIDAYS = @(
  '2026-01-01', '2026-01-02', '2026-01-03',
  '2026-02-15', '2026-02-16', '2026-02-17', '2026-02-18', '2026-02-19', '2026-02-20', '2026-02-21',
  '2026-04-04', '2026-04-05', '2026-04-06',
  '2026-05-01', '2026-05-02', '2026-05-03', '2026-05-04', '2026-05-05',
  '2026-06-19', '2026-06-20', '2026-06-21',
  '2026-09-25', '2026-09-26', '2026-09-27',
  '2026-10-01', '2026-10-02', '2026-10-03', '2026-10-04', '2026-10-05', '2026-10-06', '2026-10-07'
)
function Get-PeakState {
  $now = Get-Date
  if ($now.DayOfWeek -eq 'Saturday' -or $now.DayOfWeek -eq 'Sunday') { return $false }
  if ($script:HOLIDAYS -contains $now.ToString('yyyy-MM-dd')) { return $false }
  foreach ($w in $script:PEAK_HOURS) {
    if ($now.Hour -ge $w[0] -and $now.Hour -lt $w[1]) { return $true }
  }
  return $false
}

# ---------------- DSH ----------------
$DSH_EXE = Join-Path $env:LOCALAPPDATA 'Programs\DeepSeek Harness\DeepSeek Harness.exe'
if (-not (Test-Path -LiteralPath $DSH_EXE)) {
  foreach ($cand in @(
      (Join-Path $env:ProgramFiles 'DeepSeek Harness\DeepSeek Harness.exe'),
      'C:\Users\77620\AppData\Local\Programs\DeepSeek Harness\DeepSeek Harness.exe')) {
    if ($cand -and (Test-Path -LiteralPath $cand)) { $DSH_EXE = $cand; break }
  }
}
Write-Log ("dsh exe: {0} exists={1}" -f $DSH_EXE, (Test-Path -LiteralPath $DSH_EXE))

function Get-DshProcs {
  @(Get-Process -ErrorAction SilentlyContinue | Where-Object { $_.ProcessName -like '*DeepSeek Harness*' })
}

function Set-Foreground([IntPtr]$hwnd) {
  try {
    if ([DshDpi]::IsIconic($hwnd)) { [void][DshDpi]::ShowWindow($hwnd, 9) }
    [void][DshDpi]::ShowWindow($hwnd, 5)
    # 顶层窗口瞬间置顶再还原：Windows 会顺带把前台权交给它（比 AttachThreadInput 干净）
    [void][DshDpi]::SetWindowPos($hwnd, [IntPtr](-1), 0, 0, 0, 0, (0x0001 -bor 0x0002 -bor 0x0040))
    [void][DshDpi]::SetWindowPos($hwnd, [IntPtr](-2), 0, 0, 0, 0, (0x0001 -bor 0x0002 -bor 0x0040))
    [DshDpi]::SwitchToThisWindow($hwnd, $true)
    [void][DshDpi]::SetForegroundWindow($hwnd)
    $fg = [DshDpi]::GetForegroundWindow()
    Write-Log ("foreground via topmost fg={0} ok={1}" -f $fg, ($fg -eq $hwnd))
  } catch { Write-Log ('foreground error: ' + $_.Exception.Message) }
}

$script:lastLaunch = [DateTime]::MinValue

function Force-Repaint([IntPtr]$hwnd, [switch]$Show) {
  # 一些 Electron 窗口被隐藏后再显示会白屏，发一次 FRAMECHANGED + SHOWWINDOW 强制重排重绘
  $flags = 0x0001 -bor 0x0002 -bor 0x0004 -bor 0x0020
  if ($Show) { $flags = $flags -bor 0x0040 }
  try {
    [void][DshDpi]::SetWindowPos($hwnd, [IntPtr]::Zero, 0, 0, 0, 0, $flags)
  } catch { Write-Log ('setwindowpos error: ' + $_.Exception.Message) }
  # RDW_INVALIDATE(1) | RDW_ALLCHILDREN(0x80) | RDW_UPDATENOW(0x100) | RDW_FRAME(0x400)
  try {
    [void][DshDpi]::RedrawWindow($hwnd, [IntPtr]::Zero, [IntPtr]::Zero, 0x0001 -bor 0x0080 -bor 0x0100 -bor 0x0400)
  } catch { Write-Log ('redrawwindow error: ' + $_.Exception.Message) }
}

function Wait-DshWindow([int]$tries) {
  for ($i = 0; $i -lt $tries; $i++) {
    $h = [DshWin]::FindByTitle('DeepSeek Harness', $true)
    if ($h -ne [IntPtr]::Zero) { return $h }
    Start-Sleep -Milliseconds 400
  }
  return [IntPtr]::Zero
}

function Show-DshWindow {
  $visible = [DshWin]::FindByTitle('DeepSeek Harness', $true)
  $any = [DshWin]::FindByTitle('DeepSeek Harness', $false)
  $target = $visible
  if ($target -eq [IntPtr]::Zero) { $target = $any }

  # 1) 窗口在、可见、未最小化：后台置前即可
  if ($target -ne [IntPtr]::Zero -and [DshWin]::Vis($target) -and -not [DshWin]::Ico($target)) {
    $b = $form.Bounds
    $ex = [int[]]@($b.X - 6, $b.Y - 6, $b.Width + 12, $b.Height + 12)
    $started = [DshWake]::Begin($target.ToInt64(), $script:logFile, $DSH_EXE, [string]::Empty, $ex, $false)
    if ($started) {
      $script:wakingUntil = [DateTime]::Now.AddSeconds(9)
      $script:maskColor = Get-MaskColor
      $form.Invalidate()
      Write-Log ("wake scheduled hwnd={0} visible=True" -f $target)
    } else { Write-Log 'wake already in flight' }
    return
  }

  # 2) 最小化：先让应用自己 SC_RESTORE，必要时第二实例
  if ($target -ne [IntPtr]::Zero -and [DshWin]::Ico($target)) {
    $b = $form.Bounds
    $ex = [int[]]@($b.X - 6, $b.Y - 6, $b.Width + 12, $b.Height + 12)
    $started = [DshWake]::Begin($target.ToInt64(), $script:logFile, $DSH_EXE, [string]::Empty, $ex, $false)
    if ($started) {
      $script:wakingUntil = [DateTime]::Now.AddSeconds(9)
      $script:maskColor = Get-MaskColor
      $form.Invalidate()
      Write-Log ("wake scheduled hwnd={0} iconic=True" -f $target)
    } else { Write-Log 'wake already in flight' }
    return
  }

  # 3) 窗口被隐藏（X 掉）：先模拟托盘点击（应用自己的 focusPrimaryWindow），失败再请求二次启动
  if ($target -ne [IntPtr]::Zero) {
    $b = $form.Bounds
    $ex = [int[]]@($b.X - 6, $b.Y - 6, $b.Width + 12, $b.Height + 12)
    $started = [DshWake]::Begin($target.ToInt64(), $script:logFile, $DSH_EXE, (Join-Path $PSScriptRoot 'assets\tray_whale.png'), $ex, $true)
    if ($started) {
      $script:wakingUntil = [DateTime]::Now.AddSeconds(9)
      $script:maskColor = Get-MaskColor
      $form.Invalidate()
      Write-Log ("wake scheduled hwnd={0} hidden=True (tray first)" -f $target)
    } else { Write-Log 'wake already in flight' }
    return
  }

  # 4) 完全找不到窗口：再启动一次
  if (([DateTime]::Now - $script:lastLaunch).TotalSeconds -lt 2) { Write-Log 'launch cooldown'; return }
  $script:lastLaunch = [DateTime]::Now
  Write-Log 'no window found, launch dsh'
  try { Start-Process -FilePath $DSH_EXE -ErrorAction Stop | Out-Null } catch { Write-Log ('launch failed: ' + $_.Exception.Message) }
}

# ---------------- 状态 ----------------
$script:running = [bool](Get-DshProcs)
$script:peak = Get-PeakState
$script:attention = $false
$script:attFromHost = $false
$script:attTestUntil = [DateTime]::MinValue
$script:attLingerUntil = [DateTime]::MinValue
$script:clickToggle = $false
$script:topMost = $true
$script:wakingUntil = [DateTime]::MinValue
$script:hovering = $false
$script:pressed = $false
$script:step = 0

function Get-MaskColor {
  # 唤醒期间不再改镂空区配色（用户要求：不出现橙色）
  if ($script:attention) { return [System.Drawing.Color]::FromArgb(255, 253, 224, 71) }
  if (-not $script:running) { return [System.Drawing.Color]::FromArgb(40, 148, 163, 184) }
  if ($script:peak) { return [System.Drawing.Color]::FromArgb(60, 236, 72, 153) }
  return [System.Drawing.Color]::FromArgb(60, 37, 99, 235)
}
$script:maskColor = [System.Drawing.Color]::FromArgb(60, 37, 99, 235)

function Get-StateName {
  if (-not $script:running) { return 'off' }
  if ($script:peak) { return 'peak' }
  return 'valley'
}

function Get-StepsList {
  if ($script:pressed -or ($script:pressed -eq $false -and $script:hovering)) {
    if ($script:pressed) { return , $script:stepsPress }
    return , $script:stepsHover
  }
  return , @([int]$script:BASE)
}

function Get-TargetSteps {
  if ($script:pressed) { return , $script:stepsPress }
  if ($script:hovering) { return , $script:stepsHover }
  return , @([int]$script:BASE)
}

# ---------------- 分层窗口（逐像素透明，边缘平滑） ----------------
$layeredSrc = Get-Content -Raw (Join-Path (Split-Path -Parent $MyInvocation.MyCommand.Path) 'layered.cs.txt')
Add-Type -TypeDefinition $layeredSrc -ReferencedAssemblies @('System.Drawing', 'System.Windows.Forms') -Language CSharp

if (-not ('DshWake' -as [type])) {
  try { Add-Content -LiteralPath (Join-Path $PSScriptRoot 'startup-error.log') -Value ("[{0}] FATAL: DshWake/DshWin 编译失败，唤醒功能不可用" -f (Get-Date).ToString('HH:mm:ss')) } catch {}
}
$script:animTimer = New-Object System.Windows.Forms.Timer
$script:animTimer.Interval = 15
$script:stateTimer = New-Object System.Windows.Forms.Timer
$script:stateTimer.Interval = 250

# ---------------- 窗体 ----------------
$form = New-Object LayeredBall
$form.FormBorderStyle = [System.Windows.Forms.FormBorderStyle]::None
$form.ShowInTaskbar = $false
$form.TopMost = $true
$form.AutoScaleMode = [System.Windows.Forms.AutoScaleMode]::None
$form.StartPosition = [System.Windows.Forms.FormStartPosition]::Manual
$form.Text = 'DSH 悬浮球'

$script:docked = $false
$script:dockOpen = $false
$script:dragging = $false
$script:dockEdge = ''
$script:dockX = 0
$script:dockY = 0
$script:revealX = 0
$script:revealY = 0
$script:slideX = $null
$script:slideY = $null
$script:lastSlideX = 0
$script:lastSlideY = 0

$script:slideTimer = New-Object System.Windows.Forms.Timer
$script:slideTimer.Interval = 12
$script:slideTimer.add_Tick({
  if ($null -eq $script:slideX) { $script:slideTimer.Stop(); return }
  $cx = $form.Left
  $cy = $form.Top
  $dx = $script:slideX - $cx
  $dy = $script:slideY - $cy
  if ([math]::Abs($dx) -lt 2 -and [math]::Abs($dy) -lt 2) {
    $form.Left = [int]$script:slideX
    $form.Top = [int]$script:slideY
    $script:slideX = $null
    $script:slideTimer.Stop()
    return
  }
  $form.Left = [int][math]::Round($cx + $dx * 0.4)
  $form.Top = [int][math]::Round($cy + $dy * 0.4)
})

function Clamp-ToNearestScreen([int]$x, [int]$y) {
  $pt = New-Object System.Drawing.Point(($x + [int]($form.Width / 2)), ($y + [int]($form.Height / 2)))
  $scr = [System.Windows.Forms.Screen]::FromPoint($pt).WorkingArea
  $nx = [math]::Min([math]::Max($x, $scr.Left), $scr.Right - $form.Width)
  $ny = [math]::Min([math]::Max($y, $scr.Top), $scr.Bottom - $form.Height)
  return @($nx, $ny)
}

function Slide-To([int]$x, [int]$y) {
  $script:slideX = $x
  $script:slideY = $y
  $script:lastSlideX = $x
  $script:lastSlideY = $y
  if (-not $script:slideTimer.Enabled) { $script:slideTimer.Start() }
}

$script:dockTimer = New-Object System.Windows.Forms.Timer
$script:dockTimer.Interval = 60
$script:dockTimer.add_Tick({
  if (-not $script:docked) { return }
  if ($script:dragging) { return }
  $cp = [System.Windows.Forms.Cursor]::Position
  $w = $form.Width
  $h = $form.Height
  # 已滑出时，窗口的真实矩形；吸附时，露在外面的那一小块矩形
  $shown = New-Object System.Drawing.Rectangle($script:lastSlideX, $script:lastSlideY, $w, $h)
  $hidden = New-Object System.Drawing.Rectangle($form.Left, $form.Top, $w, $h)
  $atDock = ([math]::Abs($form.Left - $script:dockX) -le 2) -and ([math]::Abs($form.Top - $script:dockY) -le 2)
  if (-not $script:dockOpen) {
    # 贴在边上：光标碰到露出的那一小块（外扩 10px）就滑出
    $strip = New-Object System.Drawing.Rectangle(($hidden.X - 10), ($hidden.Y - 10), ($hidden.Width + 20), ($hidden.Height + 20))
    if ($strip.Contains($cp)) {
      $script:dockOpen = $true
      # 注意：不要在这里做"整窗夹进屏幕"，那会把贴着边的球又推回来 ~50px，
      # 用户看到的就是"弹出好远"。reveal 位置本来就允许窗口有一部分在屏幕外。
      Slide-To ([int]$script:revealX) ([int]$script:revealY)
      Write-Log 'dock: reveal'
    }
  } else {
    # 已滑出：光标离开窗口 36px 以上才收回（迟滞，防抖）
    $stay = New-Object System.Drawing.Rectangle(($shown.X - 36), ($shown.Y - 36), ($shown.Width + 72), ($shown.Height + 72))
    if (-not $stay.Contains($cp)) {
      $script:dockOpen = $false
      Slide-To $script:dockX $script:dockY
      Write-Log 'dock: hide'
    }
  }
})

function Get-ScreenForForm {
  $pt = New-Object System.Drawing.Point(($form.Left + [int]($form.Width / 2)), ($form.Top + [int]($form.Height / 2)))
  return [System.Windows.Forms.Screen]::FromPoint($pt)
}

function Get-WhaleOx {
  return [int][math]::Floor(($form.Width - $script:BASE) / 2)
}

function Get-DockPoint([string]$edge, [int]$x, [int]$y, $scr) {
  $wa = $scr.WorkingArea
  $w = $form.Width
  $h = $form.Height
  $ox = Get-WhaleOx
  $wpx = $script:BASE
  # 只藏掉鲸鱼本体的 55%，窗口四周的透明留白不算：这样露出来的就是鱼的一大半
  switch ($edge) {
    'left' { return @(($wa.Left - $ox - [int][math]::Round($wpx * 0.55)), $y) }
    'right' { return @(($wa.Right - $ox - [int][math]::Round($wpx * 0.45)), $y) }
    'top' { return @($x, ($wa.Top - $ox - [int][math]::Round($wpx * 0.55))) }
    'bottom' { return @($x, ($wa.Bottom - $ox - [int][math]::Round($wpx * 0.45))) }
  }
  return @($x, $y)
}

function Update-Dock {
  $vs = [System.Windows.Forms.SystemInformation]::VirtualScreen
  $scr = Get-ScreenForForm
  $sb = $scr.Bounds
  $l = $form.Left
  $t = $form.Top
  $w = $form.Width
  $h = $form.Height
  $edge = ''
  # 只有"当前这块屏幕的边缘"本身就是虚拟桌面外边界时才吸附；
  # 两块屏幕之间的接缝（比如主屏右侧）不算边缘，避免鱼尾跑到隔壁屏幕。
  if ((($l - $sb.Left) -le 10) -and ($sb.Left -eq $vs.Left)) { $edge = 'left' }
  elseif ((($sb.Right - ($l + $w)) -le 10) -and ($sb.Right -eq $vs.Right)) { $edge = 'right' }
  elseif ((($t - $sb.Top) -le 10) -and ($sb.Top -eq $vs.Top)) { $edge = 'top' }
  elseif ((($sb.Bottom - ($t + $h)) -le 10) -and ($sb.Bottom -eq $vs.Bottom)) { $edge = 'bottom' }

  $script:revealX = $l
  $script:revealY = $t
  if ($edge -eq '') {
    $script:docked = $false
    $script:dockEdge = ''
    $script:dockTimer.Stop()
    return
  }
  $script:docked = $true
  $script:dockEdge = $edge
  $dp = Get-DockPoint $edge $l $t $scr
  $script:dockX = [int]$dp[0]
  $script:dockY = [int]$dp[1]

  # 弹出距离：只挪"藏起来的那部分"再多一点点，让整只鱼完整露出来
  $off = [int][math]::Round($script:BASE * 0.55) + 8
  switch ($edge) {
    'left' {
      $script:revealX = $script:dockX + $off
      $script:revealY = $script:dockY
    }
    'right' {
      $script:revealX = $script:dockX - $off
      $script:revealY = $script:dockY
    }
    'top' {
      $script:revealX = $script:dockX
      $script:revealY = $script:dockY + $off
    }
    'bottom' {
      $script:revealX = $script:dockX
      $script:revealY = $script:dockY - $off
    }
  }
  Write-Log ("dock offset {0} dock={1},{2} reveal={3},{4}" -f $off, $script:dockX, $script:dockY, $script:revealX, $script:revealY)
  Slide-To $script:dockX $script:dockY
  $script:dockTimer.Start()
  Write-Log ("dock {0} -> {1},{2}" -f $edge, $script:dockX, $script:dockY)
}

function Undock-IfNeeded {
  if (-not $script:docked) { return }
  $script:docked = $false
  $script:dockEdge = ''
}

function Sync-WindowSize {
  if ($form.ClientSize.Width -ne $script:WIN -or $form.ClientSize.Height -ne $script:WIN) {
    $form.ClientSize = New-Object System.Drawing.Size($script:WIN, $script:WIN)
  }
}

function Clamp-ToScreen {
  $scr = [System.Windows.Forms.Screen]::PrimaryScreen.WorkingArea
  if ($form.Left + $script:WIN -gt $scr.Right) { $form.Left = $scr.Right - $script:WIN }
  if ($form.Top + $script:WIN -gt $scr.Bottom) { $form.Top = $scr.Bottom - $script:WIN }
  if ($form.Left -lt $scr.Left) { $form.Left = $scr.Left }
  if ($form.Top -lt $scr.Top) { $form.Top = $scr.Top }
}

if ([int]$script:settings.x -gt -1 -and [int]$script:settings.y -gt -1) {
  $form.Left = [int]$script:settings.x
  $form.Top = [int]$script:settings.y
  Write-Log ("pos {0},{1} base={2}" -f $form.Left, $form.Top, $script:BASE)
} else {
  $scr = [System.Windows.Forms.Screen]::PrimaryScreen.WorkingArea
  $form.Left = $scr.Right - $script:WIN - 24
  $form.Top = $scr.Bottom - $script:WIN - 96
  Write-Log ("pos default {0},{1} base={2}" -f $form.Left, $form.Top, $script:BASE)
}

# 徽标几何
$script:badgeD = [int][math]::Round($script:BASE * 0.34)

$form.add_Paint({
  param($s, $e)
  $cw = [int]$form.ClientSize.Width
  $ch = [int]$form.ClientSize.Height
  if ($cw -le 0 -or $ch -le 0) { return }
  $bmpAll = New-Object System.Drawing.Bitmap($cw, $ch, [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
  $g = [System.Drawing.Graphics]::FromImage($bmpAll)
  try {
    $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
    $g.CompositingQuality = [System.Drawing.Drawing2D.CompositingQuality]::HighQuality
    $g.Clear([System.Drawing.Color]::Transparent)
    $script:maskColor = Get-MaskColor
    $px = $script:stepsNow[$script:step]
    $entry = Get-Region $px
    $win0 = $form.ClientSize.Width
    $ox0 = [int][math]::Floor(($win0 - $px) / 2)
    $oy0 = [int][math]::Floor(($form.ClientSize.Height - $px) / 2)
    if ($entry.holes.PointCount -gt 0) {
      $m0 = New-Object System.Drawing.Drawing2D.Matrix
      $m0.Translate([float]$ox0, [float]$oy0)
      $holePath = $entry.holes.Clone()
      $holePath.Transform($m0)
      $m0.Dispose()
      $tintBrush = New-Object System.Drawing.SolidBrush($script:maskColor)
      $g.FillPath($tintBrush, $holePath)
      $tintBrush.Dispose()
      $holePath.Dispose()
    }
    $variant = Get-StateName
    if ($script:pressed) { $variant = $variant + '_press' } elseif ($script:hovering) { $variant = $variant + '_hover' }
    $bmp = Get-Sprite $px $variant
    if ($script:dbgLogged -ne $true) { $script:dbgLogged = $true; Write-Log ("paint px={0} variant={1} sprite={2}x{3} alphaMid={4}" -f $px, $variant, $bmp.Width, $bmp.Height, $bmp.GetPixel([int]($bmp.Width/2), [int]($bmp.Height/2)).A) }
    $win = $form.ClientSize.Width
    $ox = [int][math]::Floor(($win - $px) / 2)
    $oy = [int][math]::Floor(($form.ClientSize.Height - $px) / 2)
    $g.DrawImage($bmp, $ox, $oy, $px, $px)
    if ($false -and $script:attention) {
      $r = Get-BadgeRect $px $ox $oy
      $bd = $r.Width
      $bx = $r.X
      $by = $r.Y
      $br = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::FromArgb(255, 249, 115, 22))
      $g.FillEllipse($br, $bx, $by, $bd, $bd)
      $br.Dispose()
      $penW = New-Object System.Drawing.Pen([System.Drawing.Color]::White, [float]([math]::Max(1.5, $bd * 0.09)))
      $g.DrawEllipse($penW, $bx, $by, $bd, $bd)
      $penW.Dispose()
      $font = New-Object System.Drawing.Font('Segoe UI', [float]($bd * 0.60), [System.Drawing.FontStyle]::Bold, [System.Drawing.GraphicsUnit]::Pixel)
      $fmt = New-Object System.Drawing.StringFormat
      $fmt.Alignment = [System.Drawing.StringAlignment]::Center
      $fmt.LineAlignment = [System.Drawing.StringAlignment]::Center
      $rectF = New-Object System.Drawing.RectangleF([float]$bx, [float]$by, [float]$bd, [float]$bd)
      $txt = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::White)
      [void]$g.DrawString('!', $font, $txt, $rectF, $fmt)
      $txt.Dispose(); $font.Dispose(); $fmt.Dispose()
    }
    $pushOk = $form.Push($bmpAll, $form.Left, $form.Top)
    if ($script:pushLogged -ne $true) { $script:pushLogged = $true; Write-Log ("push={0} at {1},{2} size={3}x{4}" -f $pushOk, $form.Left, $form.Top, $cw, $ch) }
  } catch {
    Write-Log ('paint error: ' + $_.Exception.Message)
  }
  $g.Dispose()
  $bmpAll.Dispose()
})

$script:stepsNow = @([int]$script:BASE)

$script:tip = New-Object System.Windows.Forms.ToolTip
$script:tip.InitialDelay = 300
$script:tip.ReshowDelay = 100
$script:tip.AutoPopDelay = 20000
$script:tip.ShowAlways = $true
$script:tipText = ''
function Update-Tip {
  $st = 'DSH 未运行'
  if ($script:running) { $st = 'DSH 运行中' }
  if ($script:running -and $script:peak) { $st = 'DSH 运行中 · 峰时计价' }
  if ($script:running -and -not $script:peak) { $st = 'DSH 运行中 · 谷时计价' }
  if ($script:attention) { $st = $st + ' · 有授权/提问待处理' }
  $txt = $st + [Environment]::NewLine + '左键：打开 DSH    右键：菜单'
  if ($script:running -and $script:hiddenWin) {
    $txt = $st + ' · 窗口已隐藏' + [Environment]::NewLine + '点任务栏鲸鱼图标，或右键 →「重启 DSH」'
  }
  # 只在文本真的变化时才重设，避免把正在显示的提示顶掉
  if ($txt -ne $script:tipText) {
    $script:tipText = $txt
    $script:tip.SetToolTip($form, $txt)
  }
}

$form.add_Move({
  if ($script:bubbleShown) { try { Place-Bubble } catch {} }
})

$form.add_MouseEnter({
  if (-not $script:hovering) { Write-Log 'hover enter' }
  $script:hovering = $true
  Update-Tip
  $script:animTimer.Start()
})
$form.add_MouseLeave({
  if ($script:hovering) { Write-Log 'hover leave' }
  $script:hovering = $false
  if (-not $script:pressed) { $script:animTimer.Start() }
})

$script:downPos = $null
$script:moved = $false
$form.add_MouseDown({
  param($s, $e)
  if ($e.Button -eq [System.Windows.Forms.MouseButtons]::Left) {
    $script:downPos = [System.Windows.Forms.Cursor]::Position
    $script:moved = $false
    $script:pressed = $true
    $script:animTimer.Start()
  }
})
$form.add_MouseMove({
  param($s, $e)
  if ($null -ne $script:downPos -and $e.Button -eq [System.Windows.Forms.MouseButtons]::Left) {
    $cur = [System.Windows.Forms.Cursor]::Position
    $dx = $cur.X - $script:downPos.X
    $dy = $cur.Y - $script:downPos.Y
    if (-not $script:moved -and ([math]::Abs($dx) + [math]::Abs($dy)) -gt 6) {
      $script:moved = $true
    }
    if ($script:moved) {
      $script:dragging = $true
      $form.Left = $form.Left + $dx
      $form.Top = $form.Top + $dy
      $script:downPos = $cur
      $form.Invalidate()
    }
  }
})
$script:lastActivate = [DateTime]::MinValue
$form.add_MouseUp({
  param($s, $e)
  if ($e.Button -ne [System.Windows.Forms.MouseButtons]::Left) { return }
  $moved = $script:moved
  $script:moved = $false
  $script:dragging = $false
  $script:downPos = $null
  $script:pressed = $false
  $script:animTimer.Start()
  if ($moved) {
    $script:settings.x = $form.Left
    $script:settings.y = $form.Top
    Save-Settings
    Write-Log ("drag end {0},{1}" -f $form.Left, $form.Top)
    Update-Dock
    return
  }
  if (([DateTime]::Now - $script:lastActivate).TotalMilliseconds -le 250) {
    Write-Log 'click debounced'
    return
  }
  $script:lastActivate = [DateTime]::Now
  Show-DshWindow
})

# ---------------- 右键菜单 ----------------
$menuSrc = Get-Content -Raw (Join-Path $script:here 'menu.cs.txt')
try { Add-Type -TypeDefinition $menuSrc -ReferencedAssemblies @('System.Drawing', 'System.Windows.Forms') -Language CSharp } catch { Write-Log ('menu type error: ' + $_.Exception.Message) }

$menu = New-Object System.Windows.Forms.ContextMenuStrip
$menu.Renderer = New-Object MenuRender
$menu.ShowImageMargin = $false
$menu.Padding = New-Object System.Windows.Forms.Padding(6, 8, 6, 8)
$menu.Font = New-Object System.Drawing.Font('Microsoft YaHei UI', 9)
$menu.DropShadowEnabled = $true
$menu.add_Opening({
  try { [MenuShape]::Round($menu, 12) } catch {}
  # 球窗口带 WS_EX_NOACTIVATE：不激活就收不到"失活"消息，菜单点别处不会关。
  # 打开菜单期间临时去掉这个样式并把球设为前台，关闭时再装回去。
  try {
    $hnd = $form.Handle
    $ex = [DshDpi]::GetWindowLong($hnd, -20)
    $script:exBeforeMenu = $ex
    [void][DshDpi]::SetWindowLong($hnd, -20, ($ex -band (-bnot 0x08000000)))
    [void][DshDpi]::SetForegroundWindow($hnd)
    Write-Log 'menu: activate temp'
  } catch {}
})
$menu.add_Closed({
  try {
    if ($null -ne $script:exBeforeMenu) {
      $hnd = $form.Handle
      $cur = [DshDpi]::GetWindowLong($hnd, -20)
      [void][DshDpi]::SetWindowLong($hnd, -20, ($cur -bor 0x08000000))
      $script:exBeforeMenu = $null
      Write-Log 'menu: noactivate restored'
    }
  } catch {}
})
$menu.add_SizeChanged({ try { [MenuShape]::Round($menu, 12) } catch {} })
$menu.BackColor = [System.Drawing.Color]::Transparent
$miOpen = $menu.Items.Add('🐋  打开 DSH 窗口')
$miOpen.add_Click({ Show-DshWindow })

$miBubble = $menu.Items.Add('💬  提醒气泡')
$miBubble.CheckOnClick = $true
$miBubble.Checked = [bool]$script:settings.bubble
$miBubble.add_Click({
  $script:settings.bubble = [bool]$miBubble.Checked
  Save-Settings
  if ($script:settings.bubble) {
    try { Show-Bubble '有操作等你确认，点我回去' } catch {}
  } else {
    try { Hide-Bubble } catch {}
  }
  Write-Log ('bubble ' + $script:settings.bubble)
})

$miSize = New-Object System.Windows.Forms.ToolStripMenuItem('📏  悬浮球大小')
$miSize.add_DropDownOpening({
  param($s, $e)
  foreach ($item in $s.DropDownItems) {
    if ($item -is [System.Windows.Forms.ToolStripMenuItem]) { $item.Checked = ([int]$item.Tag -eq [int]$script:BASE) }
  }
})
foreach ($sz in @(48, 60, 72, 84, 108, 132)) {
  $item = New-Object System.Windows.Forms.ToolStripMenuItem(("{0} px" -f $sz))
  $item.Tag = $sz
  $item.add_Click({ param($s, $e) & $setSize ([int]$s.Tag) }.GetNewClosure())
  [void]$miSize.DropDownItems.Add($item)
}
[void]$menu.Items.Add($miSize)

$miAuto = $menu.Items.Add('⚡  随 DSH 自动启动')
$miAuto.CheckOnClick = $true
$miAuto.Checked = [bool]$script:settings.autoStart
$miAuto.add_Click({
  $script:settings.autoStart = [bool]$miAuto.Checked
  Save-Settings
  Write-Log ('autoStart ' + $script:settings.autoStart)
})
$miTheme = New-Object System.Windows.Forms.ToolStripMenuItem('🎨  主题配色')
$themeNames = [ordered]@{ classic = '经典（蓝 / 粉）'; purple = '紫罗兰'; green = '薄荷绿'; orange = '琥珀橙' }
foreach ($t in $themeNames.Keys) {
  $ti = New-Object System.Windows.Forms.ToolStripMenuItem([string]$themeNames[$t])
  $ti.Tag = $t
  $ti.add_Click({
    param($s2, $e2)
    $script:theme = [string]$s2.Tag
    $script:settings.theme = $script:theme
    Save-Settings
    Load-ThemeSprites
    $script:spriteCache = @{}
    $script:regionCache = @{}
    $script:maskColor = Get-MaskColor
    $form.Invalidate()
    $form.Update()
    Write-Log ('theme ' + $script:theme)
  })
  [void]$miTheme.DropDownItems.Add($ti)
}
$miTheme.add_DropDownOpening({
  param($s2, $e2)
  foreach ($it in $s2.DropDownItems) { if ($it -is [System.Windows.Forms.ToolStripMenuItem]) { $it.Checked = ([string]$it.Tag -eq $script:theme) } }
})
[void]$menu.Items.Add($miTheme)

$miReset = $menu.Items.Add('📍  复位到右下角')
$miReset.add_Click({
  $scr = [System.Windows.Forms.Screen]::PrimaryScreen.WorkingArea
  $form.Left = $scr.Right - $script:WIN - 24
  $form.Top = $scr.Bottom - $script:WIN - 96
  $script:settings.x = $form.Left
  $script:settings.y = $form.Top
  Save-Settings
  $form.Invalidate()
  Write-Log ("reset pos {0},{1}" -f $form.Left, $form.Top)
})

$miTop = $menu.Items.Add('📌  始终置顶')
$miTop.CheckOnClick = $true
$miTop.Checked = $true
$miTop.add_Click({
  $script:topMost = [bool]$miTop.Checked
  $form.TopMost = $script:topMost
  Write-Log ('topmost ' + $script:topMost)
})

[void]$menu.Items.Add((New-Object System.Windows.Forms.ToolStripSeparator))
$miQuit = $menu.Items.Add('✖  退出悬浮球')
$miQuit.add_Click({ $form.Close() })
foreach ($it in $menu.Items) {
  if ($it -is [System.Windows.Forms.ToolStripMenuItem]) { $it.Padding = New-Object System.Windows.Forms.Padding(10, 7, 10, 7) }
}

function Update-ToggleText {
  foreach ($it in @($miAuto, $miTop, $miBubble)) {
    if ($null -eq $it) { continue }
    $base = [string]$it.Tag
    if ([string]::IsNullOrEmpty($base)) {
      $base = [string]$it.Text
      $it.Tag = $base
    }
    if ($it.Checked) { $it.Text = '☑  ' + $base } else { $it.Text = '☐  ' + $base }
  }
}
$menu.add_Opening({ Update-ToggleText })
Update-ToggleText
$form.ContextMenuStrip = $menu

$setSize = {
  param([int]$newSize)
  $script:BASE = $newSize
  $script:settings.size = $newSize
  Save-Settings
  $script:stepsHover = Get-Steps ([int][math]::Round($script:BASE * $script:PEAK_SCALE))
  $script:stepsPress = Get-Steps ([int][math]::Round($script:BASE * $script:PRESS_SCALE))
  $script:WIN = Get-WinSize
  $script:spriteCache.Clear()
  $script:regionCache.Clear()
  $cx = $form.Left + [int]($form.ClientSize.Width / 2)
  $cy = $form.Top + [int]($form.ClientSize.Height / 2)
  Sync-WindowSize
  $form.Left = $cx - [int]($script:WIN / 2)
  $form.Top = $cy - [int]($script:WIN / 2)
  Clamp-ToScreen
  $script:settings.x = $form.Left
  $script:settings.y = $form.Top
  Save-Settings
  $script:stepsNow = @([int]$script:BASE)
  $script:step = 0
  Apply-Region ([int]$script:BASE)
  Write-Log ("size set {0}" -f $newSize)
  $form.Invalidate()
}

# ---------------- 提醒气泡（逐像素透明，带投影/圆角/尖角） ----------------
$script:bubble = $null
$script:bubbleTimer = $null
$script:bubbleShown = $false
$script:bubbleText = ''
$script:bubbleTailLeft = $false
$script:bubbleW = 0
$script:bubbleH = 0

$script:bubbleFont = New-Object System.Drawing.Font('Microsoft YaHei UI', 9, [System.Drawing.FontStyle]::Bold)
$script:bubbleBadgeFont = New-Object System.Drawing.Font('Segoe UI', 9, [System.Drawing.FontStyle]::Bold)

function Get-RoundPath2([int]$w, [int]$h, [int]$r) {
  $gp = New-Object System.Drawing.Drawing2D.GraphicsPath
  if ($r -lt 1) { $r = 1 }
  $gp.AddArc(0, 0, ($r * 2), ($r * 2), 180, 90)
  $gp.AddArc(($w - $r * 2 - 1), 0, ($r * 2), ($r * 2), 270, 90)
  $gp.AddArc(($w - $r * 2 - 1), ($h - $r * 2 - 1), ($r * 2), ($r * 2), 0, 90)
  $gp.AddArc(0, ($h - $r * 2 - 1), ($r * 2), ($r * 2), 90, 90)
  $gp.CloseFigure()
  return $gp
}

function Get-BubbleLines([string]$text, [int]$maxW) {
  # 先按标点切成短句，再按宽度贪心拼行（CJK 逐字测量），最多 3 行
  $parts = New-Object System.Collections.ArrayList
  $buf = ''
  foreach ($ch in $text.ToCharArray()) {
    $buf += $ch
    if ('，。！？、；：,.!?;:'.Contains($ch)) { [void]$parts.Add($buf); $buf = '' }
  }
  if ($buf -ne '') { [void]$parts.Add($buf) }

  $lines = New-Object System.Collections.ArrayList
  $cur = ''
  foreach ($seg in $parts) {
    foreach ($ch in $seg.ToCharArray()) {
      $try = $cur + $ch
      $w = [System.Windows.Forms.TextRenderer]::MeasureText($try, $script:bubbleFont).Width
      if ($w -gt $maxW -and $cur -ne '') {
        [void]$lines.Add($cur)
        $cur = [string]$ch
      } else {
        $cur = $try
      }
    }
    if ($cur -ne '') { [void]$lines.Add($cur); $cur = '' }
    # 标点断句后不再继续拼接，避免两句粘在一行
    if ($lines.Count -ge 3) { break }
  }
  if ($lines.Count -eq 0) { [void]$lines.Add($text) }
  # 标点不能落在行首：把它挪回上一行末尾
  for ($i2 = 1; $i2 -lt $lines.Count; $i2++) {
    while ($lines[$i2].Length -gt 0 -and '，。！？、；：,.!?;:'.Contains([string]$lines[$i2][0])) {
      $lines[$i2 - 1] = [string]$lines[$i2 - 1] + [string]$lines[$i2][0]
      $lines[$i2] = $lines[$i2].Substring(1)
    }
  }
  if ($lines.Count -gt 3) {
    $lines = $lines[0..2]
  }
  return ,$lines
}

function Render-Bubble([string]$text, [bool]$tailLeft) {
  $padL = 44; $padR = 18; $tailW = 9; $shadow = 6
  $lineH = 23
  $lines = Get-BubbleLines $text 150
  $n = $lines.Count
  $maxLineW = 0
  foreach ($ln in $lines) {
    $lw = [System.Windows.Forms.TextRenderer]::MeasureText($ln, $script:bubbleFont).Width
    if ($lw -gt $maxLineW) { $maxLineW = $lw }
  }
  $cardH = [int]($n * $lineH + 20)
  $cardW = $padL + $maxLineW + $padR
  $W = $cardW + $tailW + $shadow * 2
  $H = $cardH + $shadow * 2
  $bmp = New-Object System.Drawing.Bitmap($W, $H)
  $g = [System.Drawing.Graphics]::FromImage($bmp)
  $g.SmoothingMode = 'AntiAlias'
  $g.TextRenderingHint = 'ClearTypeGridFit'
  $g.Clear([System.Drawing.Color]::Transparent)

  $cardX = $shadow
  $cardY = $shadow
  if ($tailLeft) { $cardX = $shadow + $tailW }

  # 柔和投影
  for ($i = 6; $i -ge 1; $i--) {
    $alpha = [int](4 + $i * 2)
    $brush = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::FromArgb($alpha, 15, 23, 42))
    $pth = Get-RoundPath2 $cardW ($cardH + $i) 14
    $mtx = New-Object System.Drawing.Drawing2D.Matrix
    $mtx.Translate(($cardX + ($i / 2)), ($cardY + 3))
    $pth.Transform($mtx)
    $g.FillPath($brush, $pth)
    $pth.Dispose(); $brush.Dispose(); $mtx.Dispose()
  }

  # 主体
  $cardPath = Get-RoundPath2 $cardW $cardH 14
  $mtx2 = New-Object System.Drawing.Drawing2D.Matrix
  $mtx2.Translate($cardX, $cardY)
  $cardPath.Transform($mtx2)
  $rectF = New-Object System.Drawing.Rectangle($cardX, $cardY, $cardW, $cardH)
  $lg = New-Object System.Drawing.Drawing2D.LinearGradientBrush($rectF, [System.Drawing.Color]::FromArgb(255, 255, 255, 255), [System.Drawing.Color]::FromArgb(255, 243, 247, 253), [System.Drawing.Drawing2D.LinearGradientMode]::Vertical)
  $g.FillPath($lg, $cardPath)
  $lg.Dispose()
  $pen = New-Object System.Drawing.Pen([System.Drawing.Color]::FromArgb(255, 214, 224, 238), 1)
  $g.DrawPath($pen, $cardPath)
  $pen.Dispose()

  # 尖角
  $tail = New-Object System.Drawing.Drawing2D.GraphicsPath
  $cy = $cardY + [int]($cardH / 2)
  if ($tailLeft) {
    $bx = $cardX
    $tail.AddPolygon(@(
      (New-Object System.Drawing.Point(($bx + 2), ($cy - 7))),
      (New-Object System.Drawing.Point(($bx - $tailW + 1), $cy)),
      (New-Object System.Drawing.Point(($bx + 2), ($cy + 7)))
    ))
  } else {
    $bx = $cardX + $cardW
    $tail.AddPolygon(@(
      (New-Object System.Drawing.Point(($bx - 2), ($cy - 7))),
      (New-Object System.Drawing.Point(($bx + $tailW - 1), $cy)),
      (New-Object System.Drawing.Point(($bx - 2), ($cy + 7)))
    ))
  }
  $tailBrush = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::FromArgb(255, 249, 250, 253))
  $g.FillPath($tailBrush, $tail)
  $tailBrush.Dispose(); $tail.Dispose()

  # 徽章（垂直居中）
  $d = 22
  $bx2 = $cardX + 12
  $by2 = $cardY + [int](($cardH - $d) / 2)
  $bg = New-Object System.Drawing.Drawing2D.LinearGradientBrush((New-Object System.Drawing.Rectangle($bx2, $by2, $d, $d)), [System.Drawing.Color]::FromArgb(255, 252, 200, 60), [System.Drawing.Color]::FromArgb(255, 245, 158, 11), [System.Drawing.Drawing2D.LinearGradientMode]::Vertical)
  $g.FillEllipse($bg, $bx2, $by2, $d, $d)
  $bg.Dispose()
  $sf = New-Object System.Drawing.StringFormat
  $sf.Alignment = 'Center'; $sf.LineAlignment = 'Center'
  $g.DrawString('!', $script:bubbleBadgeFont, [System.Drawing.Brushes]::White, (New-Object System.Drawing.RectangleF($bx2, $by2, $d, $d)), $sf)
  $sf.Dispose()

  # 多行文本
  $tf = New-Object System.Drawing.StringFormat
  $tf.Alignment = 'Near'; $tf.LineAlignment = 'Near'; $tf.FormatFlags = 'NoWrap'
  $txtBrush = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::FromArgb(255, 24, 34, 52))
  $top = $cardY + [int](($cardH - $n * $lineH) / 2) + 1
  for ($k = 0; $k -lt $n; $k++) {
    $tr = New-Object System.Drawing.RectangleF(($cardX + $padL), ($top + $k * $lineH), ($maxLineW + 10), ($lineH + 6))
    $g.DrawString($lines[$k], $script:bubbleFont, $txtBrush, $tr, $tf)
  }
  $txtBrush.Dispose(); $tf.Dispose()

  $g.Dispose()
  $script:bubbleW = $W
  $script:bubbleH = $H
  return $bmp
}

function Place-Bubble {
  if ($null -eq $script:bubble) { return }
  # 先按分行结果量出尺寸，再决定放左还是放右
  $lines0 = Get-BubbleLines $script:bubbleText 150
  $maxW0 = 0
  foreach ($ln0 in $lines0) {
    $lw0 = [System.Windows.Forms.TextRenderer]::MeasureText($ln0, $script:bubbleFont).Width
    if ($lw0 -gt $maxW0) { $maxW0 = $lw0 }
  }
  $script:bubbleW = 44 + $maxW0 + 18 + 9 + 12
  $script:bubbleH = [int]($lines0.Count * 23 + 20) + 12
  $ox = Get-WhaleOx
  $gap = 6
  $scr = [System.Windows.Forms.Screen]::FromPoint((New-Object System.Drawing.Point(($form.Left + 10), ($form.Top + 10)))).WorkingArea
  $whaleLeft = $form.Left + $ox
  $whaleTop = $form.Top + $ox
  $whaleMid = $whaleTop + [int]($script:BASE / 2)
  $x = $whaleLeft - $gap - $script:bubbleW
  $tailLeft = $false
  if ($x -lt ($scr.Left - 4)) {
    $x = $whaleLeft + $script:BASE + $gap
    $tailLeft = $true
  }
  if (($x + $script:bubbleW) -gt ($scr.Right + 4)) { $x = $scr.Right - $script:bubbleW + 4 }
  $y = $whaleMid - [int]($script:bubbleH / 2)
  if ($y -lt $scr.Top) { $y = $scr.Top }
  if (($y + $script:bubbleH) -gt $scr.Bottom) { $y = $scr.Bottom - $script:bubbleH }
  $script:bubbleTailLeft = $tailLeft
  $script:bubbleX = [int]$x
  $script:bubbleY = [int]$y
  $bm = Render-Bubble $script:bubbleText $tailLeft
  [void]$script:bubble.Push($bm, [int]$x, [int]$y)
  $bm.Dispose()
}

function Show-Bubble([string]$text) {
  try {
    if ($null -eq $script:bubble) {
      $script:bubble = New-Object LayeredBall
      $script:bubble.SetBounds(0, 0, 10, 10)
      $script:bubble.Show()
      $script:bubbleTimer = New-Object System.Windows.Forms.Timer
      $script:bubbleTimer.Interval = 3400
      $script:bubbleTimer.add_Tick({
        $script:bubbleTimer.Stop()
        if ($null -ne $script:bubble) { $script:bubble.Hide(); $script:bubbleShown = $false }
      })
    }
    $script:bubbleText = $text
    $script:bubbleShown = $true
    Place-Bubble
    $script:bubble.Show()
    $script:bubbleTimer.Stop()
    $script:bubbleTimer.Start()
    Write-Log ("bubble show: {0}" -f $text)
  } catch {
    Write-Log ("bubble error: {0}" -f $_.Exception.Message)
  }
}

function Hide-Bubble {
  try {
    if ($null -ne $script:bubbleTimer) { $script:bubbleTimer.Stop() }
    if ($null -ne $script:bubble) { $script:bubble.Hide(); $script:bubbleShown = $false }
  } catch {}
}

# ---------------- 心跳 ----------------
function Read-Heartbeat {
  if ([string]::IsNullOrWhiteSpace($HeartbeatFile)) { return }
  try {
    if (-not (Test-Path -LiteralPath $HeartbeatFile)) { return }
    $hb = Get-Content -LiteralPath $HeartbeatFile -Raw -Encoding UTF8 | ConvertFrom-Json
    $ts = 0L
    try { $ts = [long]$hb.ts } catch { $ts = 0L }
    if ($ts -le 0) {
      # 可能正读到写了一半的文件：等 250ms 再读一次
      Start-Sleep -Milliseconds 250
      try {
        $hb2 = Get-Content -LiteralPath $HeartbeatFile -Raw -Encoding UTF8 | ConvertFrom-Json
        if ($null -ne $hb2.ts) { $ts = [long]$hb2.ts; $hb = $hb2 }
      } catch {}
    }
    if ($ts -le 0) { $ts = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds() }
    $age = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds() - $ts
    if ($age -gt 20000) {
      Write-Log ("host heartbeat stale {0}ms, exit" -f $age)
      $form.Close()
      return
    }
    $script:attFromHost = [bool]$hb.attention
    $att = $script:attFromHost
    if ($script:attTestUntil -ne [DateTime]::MinValue) {
      if ([DateTime]::Now -lt $script:attTestUntil) { $att = $true }
      else { $script:attTestUntil = [DateTime]::MinValue }
    }
    if ($att) { $script:attLingerUntil = [DateTime]::MinValue }
    elseif ($script:attFromHost -eq $false -and $script:attention -and $script:attLingerUntil -eq [DateTime]::MinValue) {
      # 刚结束：再多亮 8 秒，方便用户注意到
      $script:attLingerUntil = [DateTime]::Now.AddSeconds(8)
    }
    $eff = $att -or ([DateTime]::Now -lt $script:attLingerUntil)
    if ($eff -ne $script:attention) {
      $script:attention = $eff
      if ($eff) {
        if ($script:settings.bubble) { try { Show-Bubble '有操作等你确认，点我回去' } catch {} }
      }
      $script:maskColor = Get-MaskColor
      Write-Log ("attention {0}" -f $eff)
      Apply-Region $script:stepsNow[$script:step]
      $form.Invalidate()
    }
  } catch {}
}

$script:slowTick = 0
$script:stateTimer.add_Tick({
  # 心跳文件很小，250ms 读一次，授权提醒最多 0.25 秒响应
  Read-Heartbeat
  $script:slowTick++
  if (($script:slowTick % 8) -ne 1) { return }
  Update-Tip
  $run = [bool](Get-DshProcs)
  $peak = Get-PeakState
  if ($run) {
    $visH = [DshWin]::FindByTitle('DeepSeek Harness', $true)
    $script:hiddenWin = ($visH -eq [IntPtr]::Zero)
  } else {
    $script:hiddenWin = $false
  }
  if ($run -ne $script:running -or $peak -ne $script:peak) {
    $script:running = $run
    $script:peak = $peak
    $script:spriteCache.Clear()
    $script:maskColor = Get-MaskColor
    $form.Invalidate()
    Write-Log ("state run={0} peak={1}" -f $run, $peak)
  }
})

# 动画：只切换预渲染档位，每档位图与 Region 都提前算好
$script:animTimer.add_Tick({
  $targets = Get-TargetSteps
  $fromIdx = $script:step
  $fromPx = $script:stepsNow[$script:step]
  # 目标列表与当前列表不同则重建当前列表
  if ($script:stepsNow.Count -ne $targets.Count -or $script:stepsNow[0] -ne $targets[0] -or $script:stepsNow[$script:stepsNow.Count - 1] -ne $targets[$targets.Count - 1]) {
    $script:stepsNow = $targets
    $script:step = 0
    for ($i = 0; $i -lt $targets.Count; $i++) {
      if ($targets[$i] -eq $fromPx) { $script:step = $i; break }
    }
  }
  $dir = 0
  if ($script:step -lt $targets.Count - 1) { $dir = 1 }
  if ($dir -eq 0 -and $script:step -eq 0) {
    $script:animTimer.Stop()
    Apply-Region $script:stepsNow[0]
    $form.Invalidate()
    return
  }
  $script:step = [math]::Min($script:step + 1, $targets.Count - 1)
  Apply-Region $script:stepsNow[$script:step]
  $form.Invalidate()
  if ($script:step -ge $targets.Count - 1) { $script:animTimer.Stop() }
})

$form.add_Shown({
  Sync-WindowSize
  Clamp-ToScreen
  Apply-Region ([int]$script:BASE)
  $form.Invalidate()
  $script:stateTimer.Start()
  Read-Heartbeat
  Update-Tip
  Write-Log ("shown at {0},{1} base={2} win={3}" -f $form.Left, $form.Top, $script:BASE, $form.ClientSize.Width)
  if ($TestCapture) {
    $script:capTimer = New-Object System.Windows.Forms.Timer
    $script:capTimer.Interval = $CaptureDelayMs
    $script:capTimer.add_Tick({
      $script:capTimer.Stop()
      try {
        New-Item -ItemType Directory -Force -Path (Split-Path -Parent $CapturePath) | Out-Null
        $bounds = [System.Windows.Forms.Screen]::PrimaryScreen.Bounds
        $bmp = New-Object System.Drawing.Bitmap($bounds.Width, $bounds.Height)
        $g = [System.Drawing.Graphics]::FromImage($bmp)
        $g.CopyFromScreen($bounds.Location, [System.Drawing.Point]::Empty, $bounds.Size)
        $bmp.Save($CapturePath, [System.Drawing.Imaging.ImageFormat]::Png)
        $g.Dispose(); $bmp.Dispose()
        Write-Log 'capture ok'
      } catch { Write-Log ('capture failed: ' + $_.Exception.Message) }
      $form.Close()
    })
    $script:capTimer.Start()
  }
})

if ($TestHover) { $script:hovering = $true; $script:animTimer.Start() }
if ($TestAttention) {
  $script:attTestUntil = [DateTime]::Now.AddMinutes(30)
  $script:attention = $true
}

Write-Log ("boot pid={0} parent={1} build=r14" -f $PID, $ParentPid)
[System.Windows.Forms.Application]::Run($form)
Write-Log 'exit'
try { $script:mutex.ReleaseMutex() } catch {}
