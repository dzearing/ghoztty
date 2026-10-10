# T1788 acceptance: `background-blur` blurs what is behind a translucent window.
#
# Mac blurs everything behind a translucent terminal window. On Windows 11 the
# documented counterpart is the acrylic system backdrop (DWMSBT_TRANSIENTWINDOW);
# Mica is not one (it samples the wallpaper only). Below 22H2 the accent
# blur-behind is the fallback.
#
# THE ORACLE - "is what shows through sharp or blurred?". A red/white 8px
# checker sits behind the window. `hf` is the mean |dG| between horizontal
# neighbours in the empty terminal background: a sharp checker seen through
# the window keeps big steps, a blur flattens them toward 0. It is only
# meaningful where the background is actually see-through - an OPAQUE
# background also scores ~0 - so every blur reading is paired with the
# checker-vs-blue see-through measure from translucent-window.ps1.
#
#   A  blur off: the background is see-through and the checker behind it is
#      SHARP (the control - without it a low hf would prove nothing).
#   B  live reload to blur on: still see-through, and the checker is BLURRED.
#   C  the blur is the acrylic backdrop - DWM reads the window's backdrop
#      attribute back as 3 (TRANSIENTWINDOW), not Mica (2).
#   D  the glyphs stay opaque under the blur (pure foreground green, the same
#      over both backdrops).
#   E  live reload to blur off: sharp again, and the backdrop back to DWM's
#      default (0).
#
# INPUT DESKTOP ONLY, declared in lib\TestDesktop.ps1: the subject is DWM's
# composite, and DWM composes only the input desktop. The windows appear
# briefly, topmost and without activation.
#
# -NegativeControl inverts assertion B, so a passing run proves B can fail.
#
# Only touches ghoztty processes running from this repo's zig-out.
param([string]$ExePath, [switch]$NegativeControl)

# T351: shared reset/kill helpers, ahead of isolation (drops an inherited
# $GHOZTTY_IPC_SOCKET).
. (Join-Path $PSScriptRoot 'lib\CleanSlate.ps1')
. (Join-Path $PSScriptRoot 'lib\DesktopCapability.ps1')
Assert-TestDesktopCapability -Name screen-pixels -Interactive
# T675: this harness tracks the pid it launches.
$env:GHOZTTY_NO_STARTUP_ESCAPE = '1'
$ErrorActionPreference = 'Stop'
$repo = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$exe = Join-Path $repo 'zig-out\bin\ghoztty.exe'
if ($ExePath) { $exe = $ExePath }
. (Join-Path $PSScriptRoot 'lib\Isolation.ps1')
[void](Set-GhozttyTestIsolation -Tag 'blur')
Assert-GhozttyIsolatedBuild -Exe $exe | Out-Null

$script:pass = 0
$script:fail = 0
function Assert([bool]$cond, [string]$label) {
    if ($cond) { $script:pass++; Write-Host "PASS  $label" }
    else { $script:fail++; Write-Host "FAIL  $label" -ForegroundColor Red }
}

Add-Type -ReferencedAssemblies System.Windows.Forms, System.Drawing -TypeDefinition @'
using System; using System.Drawing; using System.Text; using System.Windows.Forms;
using System.Runtime.InteropServices;
public class BlBackdrop : Form {
  public bool Blue;
  public BlBackdrop() { FormBorderStyle = FormBorderStyle.None; TopMost = true; StartPosition = FormStartPosition.Manual; ShowInTaskbar = false; }
  protected override bool ShowWithoutActivation { get { return true; } }
  protected override void OnPaint(PaintEventArgs e) {
    if (Blue) { e.Graphics.FillRectangle(Brushes.Blue, 0, 0, Width, Height); return; }
    for (int y = 0; y < Height; y += 8) for (int x = 0; x < Width; x += 8)
      e.Graphics.FillRectangle(((x / 8 + y / 8) % 2 == 0) ? Brushes.White : Brushes.Red, x, y, 8, 8);
  }
}
public static class Bl {
  [DllImport("user32")] public static extern bool SetProcessDpiAwarenessContext(IntPtr v);
  [DllImport("user32")] public static extern bool SetWindowPos(IntPtr h, IntPtr a, int x, int y, int cx, int cy, uint f);
  [DllImport("user32")] public static extern bool GetClientRect(IntPtr h, out RECT r);
  [DllImport("user32")] public static extern bool ClientToScreen(IntPtr h, ref POINT p);
  [DllImport("dwmapi")] static extern int DwmGetWindowAttribute(IntPtr h, int a, out int v, int s);
  [DllImport("user32")] static extern bool IsWindowVisible(IntPtr h);
  [DllImport("user32")] static extern bool EnumWindows(EnumProc cb, IntPtr p);
  [DllImport("user32")] static extern bool EnumChildWindows(IntPtr h, EnumProc cb, IntPtr p);
  [DllImport("user32")] static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
  [DllImport("user32", CharSet = CharSet.Unicode)] static extern int GetClassNameW(IntPtr h, StringBuilder s, int n);
  [StructLayout(LayoutKind.Sequential)] public struct RECT { public int Left, Top, Right, Bottom; }
  [StructLayout(LayoutKind.Sequential)] public struct POINT { public int X, Y; }
  delegate bool EnumProc(IntPtr h, IntPtr p);
  static string Cls(IntPtr h) { var sb = new StringBuilder(256); GetClassNameW(h, sb, 256); return sb.ToString(); }
  public static IntPtr FindTop(int pid, string cls) {
    IntPtr found = IntPtr.Zero;
    EnumWindows((h, p) => { uint wp; GetWindowThreadProcessId(h, out wp);
      if (wp == pid && IsWindowVisible(h) && Cls(h) == cls) { found = h; return false; } return true; }, IntPtr.Zero);
    return found;
  }
  public static IntPtr FindChild(IntPtr top, string cls) {
    IntPtr found = IntPtr.Zero;
    EnumChildWindows(top, (h, p) => { if (IsWindowVisible(h) && Cls(h) == cls) { found = h; return false; } return true; }, IntPtr.Zero);
    return found;
  }
  public static Rectangle ClientScreen(IntPtr h) {
    RECT r; GetClientRect(h, out r); POINT p = new POINT(); ClientToScreen(h, ref p);
    return new Rectangle(p.X, p.Y, r.Right - r.Left, r.Bottom - r.Top);
  }
  // DWMWA_SYSTEMBACKDROP_TYPE as DWM reports it; -1 when the query fails.
  public static int Backdrop(IntPtr h) { int v; return DwmGetWindowAttribute(h, 38, out v, 4) < 0 ? -1 : v; }
  public static int[] Grab(Rectangle r) {
    using (var bmp = new Bitmap(r.Width, r.Height)) {
      using (var g = Graphics.FromImage(bmp)) g.CopyFromScreen(r.X, r.Y, 0, 0, r.Size);
      var px = new int[r.Width * r.Height];
      for (int y = 0; y < r.Height; y++) for (int x = 0; x < r.Width; x++) px[y * r.Width + x] = bmp.GetPixel(x, y).ToArgb();
      return px;
    }
  }
  // Mean per-channel |a - b| over the two captures: 0 = opaque.
  public static double SeeThrough(int[] a, int[] b) {
    double s = 0; for (int i = 0; i < a.Length; i++) {
      s += Math.Abs(((a[i] >> 16) & 255) - ((b[i] >> 16) & 255)) + Math.Abs(((a[i] >> 8) & 255) - ((b[i] >> 8) & 255)) + Math.Abs((a[i] & 255) - (b[i] & 255));
    }
    return s / (3.0 * a.Length);
  }
  // Mean |dG| between horizontal neighbours: sharp checker = high, blur = ~0.
  public static double HighFreq(int[] a, int w) {
    double s = 0; int n = 0;
    for (int i = 0; i < a.Length; i++) {
      if (i % w == 0) continue;
      s += Math.Abs(((a[i] >> 8) & 255) - ((a[i - 1] >> 8) & 255)); n++;
    }
    return n == 0 ? 0 : s / n;
  }
  public static int[] GreenGlyphs(int[] a, int[] b) {
    int green = 0, same = 0;
    for (int i = 0; i < a.Length; i++) {
      int r = (a[i] >> 16) & 255, g = (a[i] >> 8) & 255, bl = a[i] & 255;
      if (g >= 250 && r <= 5 && bl <= 5) {
        green++;
        int r2 = (b[i] >> 16) & 255, g2 = (b[i] >> 8) & 255, b2 = b[i] & 255;
        if (Math.Abs(r - r2) <= 3 && Math.Abs(g - g2) <= 3 && Math.Abs(bl - b2) <= 3) same++;
      }
    }
    return new int[] { green, same };
  }
}
'@
[void][Bl]::SetProcessDpiAwarenessContext([IntPtr](-4))

$backdrop = New-Object BlBackdrop
$backdrop.Bounds = New-Object System.Drawing.Rectangle 150, 150, 1000, 760

function Set-Backdrop([bool]$blue) {
    $backdrop.Blue = $blue
    $backdrop.Invalidate(); $backdrop.Update()
    for ($i = 0; $i -lt 6; $i++) { [System.Windows.Forms.Application]::DoEvents(); Start-Sleep -Milliseconds 60 }
}

# One reading of a region: hf over the checker, and see-through against blue.
function Measure-Region([System.Drawing.Rectangle]$r) {
    Set-Backdrop $false
    Start-Sleep -Milliseconds 300   # the acrylic samples what is behind with a lag
    $a = [Bl]::Grab($r)
    Set-Backdrop $true
    Start-Sleep -Milliseconds 300
    $b = [Bl]::Grab($r)
    Set-Backdrop $false
    [pscustomobject]@{
        hf  = [Math]::Round([Bl]::HighFreq($a, $r.Width), 2)
        see = [Math]::Round([Bl]::SeeThrough($a, $b), 2)
        a   = $a
        b   = $b
    }
}

function Kill-RepoInstances { [void](Stop-RepoGhoztty -Exe $exe -SettleMs 500) }

$conf = Join-Path $env:TEMP ("ghoztty-t{0}-blur.conf" -f $PID)
function Write-Conf([bool]$blur) {
    [IO.File]::WriteAllText($conf, @"
background-opacity = 0.6
background-blur = $(if ($blur) { 'true' } else { 'false' })
background = #101010
foreground = #00ff00
cursor-color = #00ff00
cursor-style = block
cursor-style-blink = false
font-size = 16
"@)
}

function Invoke-Reload {
    $out = & $exe +reload --config 2>&1 | ForEach-Object { $_.ToString() } | Out-String
    Start-Sleep -Milliseconds 1500
    return $out.Trim()
}

# Thresholds. The bare checker scores ~31; seen through #101010 at 0.6 it keeps
# ~40% of that (~12). T1016 measured a blurred view at 0.00 (acrylic) and 1.13
# (accent). 6 and 3 leave room either side without meeting in the middle.
$SHARP_MIN = 6.0
$BLUR_MAX = 3.0
$SEE_MIN = 10.0

Write-Conf $false
Kill-RepoInstances
$proc = $null
try {
    $backdrop.Show(); [System.Windows.Forms.Application]::DoEvents()
    $errLog = Join-Path $env:TEMP ("ghoztty-t{0}-blur.err.txt" -f $PID)
    $argList = @('--config-default-files=false', '--session-persistence=false', "--config-file=$conf")
    $proc = Start-Process -FilePath $exe -ArgumentList $argList -PassThru -RedirectStandardError $errLog
    $top = [IntPtr]::Zero
    for ($i = 0; $i -lt 60 -and $top -eq [IntPtr]::Zero; $i++) {
        Start-Sleep -Milliseconds 200
        if ($proc.HasExited) { break }
        $top = [Bl]::FindTop($proc.Id, 'GhozttyWindow')
    }
    if ($top -eq [IntPtr]::Zero) { Write-Host 'SETUP FAIL: top window not found'; exit 1 }
    $pane = [Bl]::FindChild($top, 'GhozttyTerminal')
    if ($pane -eq [IntPtr]::Zero) { Write-Host 'SETUP FAIL: terminal pane not found'; exit 1 }
    # HWND_TOPMOST, SWP_NOACTIVATE | SWP_SHOWWINDOW: over the backdrop, never
    # the foreground.
    [void][Bl]::SetWindowPos($top, [IntPtr](-1), 250, 250, 800, 560, 0x0050)
    Start-Sleep -Seconds 3   # the shell prints its banner and prompt

    $paneRect = [Bl]::ClientScreen($pane)
    $textRect = New-Object System.Drawing.Rectangle $paneRect.X, $paneRect.Y, $paneRect.Width, ([int]($paneRect.Height * 0.4))
    $bgRect = New-Object System.Drawing.Rectangle ($paneRect.X + 20), ($paneRect.Y + [int]($paneRect.Height * 0.6)), ($paneRect.Width - 40), ([int]($paneRect.Height * 0.3))

    # --- A: blur off - the control -------------------------------------------
    $off = Measure-Region $bgRect
    Write-Host ("INFO  blur off: hf {0}, see-through {1}, backdrop {2}" -f $off.hf, $off.see, [Bl]::Backdrop($top))
    Assert ($off.see -ge $SEE_MIN) "A: blur off, the background is see-through ($($off.see) >= $SEE_MIN)"
    Assert ($off.hf -ge $SHARP_MIN) "A: blur off, the checker behind is sharp (hf $($off.hf) >= $SHARP_MIN)"

    # --- B/C/D: live reload to blur on ---------------------------------------
    Write-Conf $true
    $r = Invoke-Reload
    Write-Host "INFO  +reload --config: $r"
    $on = Measure-Region $bgRect
    $bd = [Bl]::Backdrop($top)
    Write-Host ("INFO  blur on: hf {0}, see-through {1}, backdrop {2}" -f $on.hf, $on.see, $bd)
    Assert ($on.see -ge $SEE_MIN) "B: blur on, the background is still see-through ($($on.see) >= $SEE_MIN)"
    if ($NegativeControl) {
        Write-Host 'NEGATIVE CONTROL: asserting the checker is still SHARP - this run MUST fail'
        Assert ($on.hf -ge $SHARP_MIN) "B (inverted): blur on, the checker is sharp (hf $($on.hf))"
    } else {
        Assert ($on.hf -le $BLUR_MAX) "B: blur on, the checker behind is blurred (hf $($on.hf) <= $BLUR_MAX)"
    }
    Assert ($bd -eq 3) "C: the blur is the acrylic backdrop, TRANSIENTWINDOW (backdrop attribute $bd == 3; Mica would be 2)"

    Set-Backdrop $false
    $ga = [Bl]::Grab($textRect); Set-Backdrop $true; $gb = [Bl]::Grab($textRect); Set-Backdrop $false
    $g = [Bl]::GreenGlyphs($ga, $gb)
    Write-Host "INFO  glyph pixels at pure #00ff00: $($g[0]), unchanged over both backdrops: $($g[1])"
    Assert ($g[0] -ge 20) "D: under the blur, at least 20 glyph pixels render at exactly the foreground colour ($($g[0]))"
    Assert ($g[1] -ge [int]($g[0] * 0.98)) "D: those glyph pixels read the same over both backdrops ($($g[1]) of $($g[0]))"

    # --- E: live reload back to blur off -------------------------------------
    Write-Conf $false
    [void](Invoke-Reload)
    $again = Measure-Region $bgRect
    $bd2 = [Bl]::Backdrop($top)
    Write-Host ("INFO  blur off again: hf {0}, see-through {1}, backdrop {2}" -f $again.hf, $again.see, $bd2)
    Assert ($again.hf -ge $SHARP_MIN) "E: reloaded to blur off, the checker is sharp again (hf $($again.hf) >= $SHARP_MIN)"
    Assert ($bd2 -eq 0) "E: the backdrop is back to DWM's default (attribute $bd2 == 0)"

    Assert (-not $proc.HasExited) 'no crash'
} finally {
    if ($proc -and -not $proc.HasExited) { Stop-Process -Id $proc.Id -Force -ErrorAction SilentlyContinue }
    $backdrop.Close()
    Kill-RepoInstances
    Remove-Item $conf -Force -ErrorAction SilentlyContinue
}

# --- stamp (T783) -------------------------------------------------------------
# What this proves is only visible in DWM's composite: no floor lane can see a
# blur, so a green run is the only evidence.
if ($script:fail -eq 0 -and -not $NegativeControl) {
    & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $repo 'scripts\guard-due.ps1') `
        update -Guard background-blur -Repo $repo 2>&1 | ForEach-Object { Write-Host "  $($_.ToString())" }
}

Write-Host ''
if ($script:fail -eq 0) { Write-Host "ALL PASS ($script:pass)" }
else { Write-Host "$script:fail FAILURE(S) ($script:pass passed)" -ForegroundColor Red; exit 1 }
