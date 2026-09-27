# T1787 acceptance: `background-opacity` makes only the BACKGROUND translucent.
#
# Mac's background-opacity lets the desktop show through the terminal's
# background while glyphs, the cursor and the window chrome stay fully opaque.
# Windows used whole-window WS_EX_LAYERED + LWA_ALPHA, which faded everything
# uniformly - text included - and (measured in T1016) defeated every DWM blur.
# The fix composes the window by per-pixel alpha, with the GDI chrome painted
# alpha-correct and the viewer host composed as an opaque layer.
#
# THE ORACLE - "does this pixel see through?". A backdrop window sits behind
# the ghoztty window and every region is captured twice: once over a red/white
# checker, once over solid blue. An opaque pixel reads the same both times; a
# translucent one changes with what is behind it. One measure covers glyphs,
# chrome, background and the viewer bar alike, and needs no knowledge of what
# the pixels ought to be.
#
#   A  glyphs: the green prompt text and block cursor, at exactly #00ff00, read
#      the same over both backdrops. Under LWA_ALPHA not one pixel is pure green.
#   B  background: the empty terminal area DOES change with the backdrop.
#   C  caption band: does not change (GDI writes alpha 0 - the chrome must be
#      made opaque on purpose or it paints invisible).
#   D  after a split: the caption still does not change. The post-layout divider
#      pass once blitted its whole clip box and erased the caption with it.
#   E  viewer nav bar: does not change (a GDI child of a per-pixel-alpha window).
#   F  toggle_background_opacity: opaque, then translucent again.
#   G  the top-level is no longer WS_EX_LAYERED - the old mechanism is gone.
#   (The inline tab-rename box takes the same `composeOpaqueLayer` call E
#   proves; it cancels on focus loss, and this harness never takes focus.)
#
# INPUT DESKTOP ONLY, declared in lib\TestDesktop.ps1: the subject is DWM's
# composite, and DWM composes only the input desktop. The windows appear
# briefly, topmost and without activation; keys are POSTED to the pane, so the
# user's foreground is never taken.
#
# -NegativeControl inverts assertion A, so a passing run proves A can fail.
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
[void](Set-GhozttyTestIsolation -Tag 'translucent')
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
public class TlBackdrop : Form {
  public bool Blue;
  public TlBackdrop() { FormBorderStyle = FormBorderStyle.None; TopMost = true; StartPosition = FormStartPosition.Manual; ShowInTaskbar = false; }
  protected override bool ShowWithoutActivation { get { return true; } }
  protected override void OnPaint(PaintEventArgs e) {
    if (Blue) { e.Graphics.FillRectangle(Brushes.Blue, 0, 0, Width, Height); return; }
    for (int y = 0; y < Height; y += 8) for (int x = 0; x < Width; x += 8)
      e.Graphics.FillRectangle(((x / 8 + y / 8) % 2 == 0) ? Brushes.White : Brushes.Red, x, y, 8, 8);
  }
}
public static class Tl {
  [DllImport("user32")] public static extern bool SetProcessDpiAwarenessContext(IntPtr v);
  [DllImport("user32")] public static extern bool SetWindowPos(IntPtr h, IntPtr a, int x, int y, int cx, int cy, uint f);
  [DllImport("user32")] public static extern int GetWindowLong(IntPtr h, int i);
  [DllImport("user32")] public static extern uint GetDpiForWindow(IntPtr h);
  [DllImport("user32")] public static extern bool PostMessageW(IntPtr h, uint m, IntPtr w, IntPtr l);
  [DllImport("user32")] public static extern bool GetWindowRect(IntPtr h, out RECT r);
  [DllImport("user32")] public static extern bool GetClientRect(IntPtr h, out RECT r);
  [DllImport("user32")] public static extern bool ClientToScreen(IntPtr h, ref POINT p);
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
  // Screen rect of a window's client area.
  public static Rectangle ClientScreen(IntPtr h) {
    RECT r; GetClientRect(h, out r); POINT p = new POINT(); ClientToScreen(h, ref p);
    return new Rectangle(p.X, p.Y, r.Right - r.Left, r.Bottom - r.Top);
  }
  public static Rectangle WindowScreen(IntPtr h) {
    RECT r; GetWindowRect(h, out r); return new Rectangle(r.Left, r.Top, r.Right - r.Left, r.Bottom - r.Top);
  }
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
  // Pixels that are pure foreground green in `a`, and how many of those read
  // identically (within 3 per channel) in `b`.
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
[void][Tl]::SetProcessDpiAwarenessContext([IntPtr](-4))

$backdrop = New-Object TlBackdrop
$backdrop.Bounds = New-Object System.Drawing.Rectangle 150, 150, 1000, 760

function Set-Backdrop([bool]$blue) {
    $backdrop.Blue = $blue
    $backdrop.Invalidate(); $backdrop.Update()
    for ($i = 0; $i -lt 6; $i++) { [System.Windows.Forms.Application]::DoEvents(); Start-Sleep -Milliseconds 60 }
}

# Both captures of a screen rect, checker first. Returns @(checker, blue).
function Get-BothCaptures([System.Drawing.Rectangle]$r) {
    Set-Backdrop $false
    $a = [Tl]::Grab($r)
    Set-Backdrop $true
    $b = [Tl]::Grab($r)
    Set-Backdrop $false
    return , @($a, $b)
}

function Get-SeeThrough([System.Drawing.Rectangle]$r) {
    $c = Get-BothCaptures $r
    return [Math]::Round([Tl]::SeeThrough($c[0], $c[1]), 2)
}

function Kill-RepoInstances { [void](Stop-RepoGhoztty -Exe $exe -SettleMs 500) }

$conf = Join-Path $env:TEMP ("ghoztty-t{0}-translucent.conf" -f $PID)
[IO.File]::WriteAllText($conf, @"
background-opacity = 0.6
background = #101010
foreground = #00ff00
cursor-color = #00ff00
cursor-style = block
cursor-style-blink = false
font-size = 16
keybind = f9=toggle_background_opacity
"@)

Kill-RepoInstances
$proc = $null
try {
    $backdrop.Show(); [System.Windows.Forms.Application]::DoEvents()
    $errLog = Join-Path $env:TEMP ("ghoztty-t{0}-translucent.err.txt" -f $PID)
    $argList = @('--config-default-files=false', '--session-persistence=false', "--config-file=$conf")
    $proc = Start-Process -FilePath $exe -ArgumentList $argList -PassThru -RedirectStandardError $errLog
    $top = [IntPtr]::Zero
    for ($i = 0; $i -lt 60 -and $top -eq [IntPtr]::Zero; $i++) {
        Start-Sleep -Milliseconds 200
        if ($proc.HasExited) { break }
        $top = [Tl]::FindTop($proc.Id, 'GhozttyWindow')
    }
    if ($top -eq [IntPtr]::Zero) { Write-Host 'SETUP FAIL: top window not found'; exit 1 }
    $pane = [Tl]::FindChild($top, 'GhozttyTerminal')
    if ($pane -eq [IntPtr]::Zero) { Write-Host 'SETUP FAIL: terminal pane not found'; exit 1 }
    # HWND_TOPMOST, SWP_NOACTIVATE | SWP_SHOWWINDOW: over the backdrop, never
    # the foreground.
    [void][Tl]::SetWindowPos($top, [IntPtr](-1), 250, 250, 800, 560, 0x0050)
    Start-Sleep -Seconds 3   # the shell prints its banner and prompt

    $scale = [Tl]::GetDpiForWindow($top) / 96.0
    $client = [Tl]::ClientScreen($top)
    Write-Host ("INFO  client {0} scale {1}" -f $client, $scale)

    # --- G: not whole-window alpha -------------------------------------------
    $ex = [Tl]::GetWindowLong($top, -20)
    Assert (($ex -band 0x80000) -eq 0) ("G: top-level is not WS_EX_LAYERED (exstyle=0x{0:x})" -f $ex)

    # Regions. The caption band is the top 32 DIPs; sample its middle rows
    # across the span between the title and the caption buttons. The terminal
    # region is the pane's client; its lower half is empty background.
    $capRect = New-Object System.Drawing.Rectangle ($client.X + [int]($client.Width * 0.45)), ($client.Y + [int](6 * $scale)), ([int]($client.Width * 0.2)), ([int](18 * $scale))
    $paneRect = [Tl]::ClientScreen($pane)
    $textRect = New-Object System.Drawing.Rectangle $paneRect.X, $paneRect.Y, $paneRect.Width, ([int]($paneRect.Height * 0.4))
    $bgRect = New-Object System.Drawing.Rectangle ($paneRect.X + 20), ($paneRect.Y + [int]($paneRect.Height * 0.6)), ($paneRect.Width - 40), ([int]($paneRect.Height * 0.3))

    # --- A: glyphs opaque ----------------------------------------------------
    $c = Get-BothCaptures $textRect
    $g = [Tl]::GreenGlyphs($c[0], $c[1])
    Write-Host "INFO  glyph pixels at pure #00ff00: $($g[0]), unchanged over both backdrops: $($g[1])"
    if ($NegativeControl) {
        Write-Host 'NEGATIVE CONTROL: asserting the glyphs are NOT opaque - this run MUST fail'
        Assert ($g[0] -lt 20) "A (inverted): fewer than 20 pure-green glyph pixels"
    } else {
        Assert ($g[0] -ge 20) "A: at least 20 glyph pixels render at exactly the foreground colour ($($g[0]))"
        Assert ($g[1] -ge [int]($g[0] * 0.98)) "A: those glyph pixels read the same over both backdrops ($($g[1]) of $($g[0]))"
    }

    # --- B: background translucent -------------------------------------------
    $bgSee = Get-SeeThrough $bgRect
    Assert ($bgSee -ge 30) "B: the terminal background shows the backdrop through (see-through $bgSee >= 30)"

    # --- C: caption opaque -----------------------------------------------------
    $capSee = Get-SeeThrough $capRect
    Assert ($capSee -le 2) "C: the caption band is opaque (see-through $capSee <= 2)"

    # --- F: toggle_background_opacity -------------------------------------------
    # Posted F9 (WM_KEYDOWN/UP, VK 0x78): the pane reads the VK from wparam.
    [void][Tl]::PostMessageW($pane, 0x100, [IntPtr]0x78, [IntPtr]0x00430001)
    [void][Tl]::PostMessageW($pane, 0x101, [IntPtr]0x78, [IntPtr]([int64]0xC0430001))
    Start-Sleep -Milliseconds 1200
    $opaqueSee = Get-SeeThrough $bgRect
    Assert ($opaqueSee -le 2) "F: toggled opaque, the background no longer shows through (see-through $opaqueSee)"
    [void][Tl]::PostMessageW($pane, 0x100, [IntPtr]0x78, [IntPtr]0x00430001)
    [void][Tl]::PostMessageW($pane, 0x101, [IntPtr]0x78, [IntPtr]([int64]0xC0430001))
    Start-Sleep -Milliseconds 1200
    $backSee = Get-SeeThrough $bgRect
    Assert ($backSee -ge 30) "F: toggled back, the background is translucent again (see-through $backSee)"

    # --- D: caption survives the post-layout divider pass -------------------------
    $out = & $exe +split --direction=right 2>&1 | ForEach-Object { $_.ToString() } | Out-String
    Start-Sleep -Milliseconds 1500
    Assert ($out -notmatch '(?i)error') "D: +split answered ($($out.Trim()))"
    $capSee2 = Get-SeeThrough $capRect
    Assert ($capSee2 -le 2) "D: after a split the caption band is still opaque (see-through $capSee2)"

    # --- E: viewer nav bar opaque ------------------------------------------------
    $readme = Join-Path $repo 'README.md'
    $out = & $exe +split --direction=down "--view=$readme" 2>&1 | ForEach-Object { $_.ToString() } | Out-String
    $nav = [IntPtr]::Zero
    for ($i = 0; $i -lt 40 -and $nav -eq [IntPtr]::Zero; $i++) {
        Start-Sleep -Milliseconds 250
        $nav = [Tl]::FindChild($top, 'GhozttyViewerNav')
    }
    if ($nav -eq [IntPtr]::Zero) {
        Assert $false "E: viewer nav bar appeared ($($out.Trim()))"
    } else {
        Start-Sleep -Milliseconds 1500
        $navRect = [Tl]::WindowScreen($nav)
        $navSee = Get-SeeThrough $navRect
        Assert ($navSee -le 2) "E: the viewer nav bar is opaque (see-through $navSee over $navRect)"
    }

    Assert (-not $proc.HasExited) 'no crash'
} finally {
    if ($proc -and -not $proc.HasExited) { Stop-Process -Id $proc.Id -Force -ErrorAction SilentlyContinue }
    $backdrop.Close()
    Kill-RepoInstances
    Remove-Item $conf -Force -ErrorAction SilentlyContinue
}

# --- stamp (T783) -------------------------------------------------------------
# What this proves is only visible in DWM's composite: no floor lane can see a
# chrome band that went transparent, so a green run is the only evidence.
if ($script:fail -eq 0 -and -not $NegativeControl) {
    & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $repo 'scripts\guard-due.ps1') `
        update -Guard translucent-window -Repo $repo 2>&1 | ForEach-Object { Write-Host "  $($_.ToString())" }
}

Write-Host ''
if ($script:fail -eq 0) { Write-Host "ALL PASS ($script:pass)" }
else { Write-Host "$script:fail FAILURE(S) ($script:pass passed)" -ForegroundColor Red; exit 1 }
