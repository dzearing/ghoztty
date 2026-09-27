# T1016 probe: which blur mechanism actually blurs what is behind a
# translucent ghoztty window?
#
# A debug ghoztty (background-opacity 0.6, background-blur on) is parked over a
# sharp red/white checker, and each mechanism is applied to it FROM OUTSIDE the
# app (so no experiment code ships): the undocumented accent blur, and the
# documented DWMWA_SYSTEMBACKDROP_TYPE acrylic (3) and Mica (2). The score is
# `hf`, the mean |dG| between horizontal neighbours in a patch of the client -
# a sharp checker keeps big steps, a blur flattens them toward 0. The same
# modes are then applied to a POSITIVE CONTROL window built the way DWM
# materials expect (no WS_EX_LAYERED, frame extended, client alpha 0), which
# proves the capture can see a blur at all. PNGs land in -Out.
#
# Runs on the INPUT desktop on purpose - DWM composes only that desktop, so the
# background test desktop cannot answer a composition question (T306). Windows
# appear briefly, topmost and without activation. Not an acceptance harness:
# a measuring tool for T1787/T1788, re-run after either lands.
param(
    [string]$Exe = (Join-Path $PSScriptRoot '..\zig-out\bin\ghoztty.exe'),
    [string]$Out = (Join-Path $env:TEMP 't1016-probe')
)
$ErrorActionPreference = 'Stop'
New-Item -ItemType Directory -Force $Out | Out-Null
. (Join-Path $PSScriptRoot '..\test\win32\lib\Isolation.ps1')
[void](Set-GhozttyTestIsolation -Tag t1016 -Quiet)

Add-Type -ReferencedAssemblies System.Windows.Forms, System.Drawing -TypeDefinition @'
using System; using System.Drawing; using System.Windows.Forms; using System.Runtime.InteropServices;
public class Checker : Form {
  public Checker() { FormBorderStyle = FormBorderStyle.None; TopMost = true; StartPosition = FormStartPosition.Manual; ShowInTaskbar = false; }
  protected override bool ShowWithoutActivation { get { return true; } }
  protected override void OnPaint(PaintEventArgs e) {
    for (int y = 0; y < Height; y += 8) for (int x = 0; x < Width; x += 8)
      e.Graphics.FillRectangle(((x / 8 + y / 8) % 2 == 0) ? Brushes.White : Brushes.Red, x, y, 8, 8);
  }
}
public class Glass : Form {
  // Non-layered, frame extended over the whole client, painted black: GDI black
  // is alpha 0, so whatever material DWM puts behind the window shows through.
  [StructLayout(LayoutKind.Sequential)] public struct MARGINS { public int l, r, t, b; }
  [DllImport("dwmapi")] static extern int DwmExtendFrameIntoClientArea(IntPtr h, ref MARGINS m);
  public Glass() { FormBorderStyle = FormBorderStyle.None; TopMost = true; StartPosition = FormStartPosition.Manual; ShowInTaskbar = false; BackColor = Color.Black; }
  protected override bool ShowWithoutActivation { get { return true; } }
  protected override void OnHandleCreated(EventArgs e) { base.OnHandleCreated(e); var m = new MARGINS { l = -1, r = -1, t = -1, b = -1 }; DwmExtendFrameIntoClientArea(Handle, ref m); }
}
public static class P {
  [DllImport("user32")] public static extern bool SetProcessDpiAwarenessContext(IntPtr v);
  [StructLayout(LayoutKind.Sequential)] public struct AP { public int State; public uint Flags; public uint Grad; public uint Anim; }
  [StructLayout(LayoutKind.Sequential)] public struct WCAD { public uint Attrib; public IntPtr pv; public IntPtr cb; }
  [DllImport("user32")] static extern int SetWindowCompositionAttribute(IntPtr h, ref WCAD d);
  [DllImport("dwmapi")] public static extern int DwmSetWindowAttribute(IntPtr h, int a, ref int v, int s);
  [DllImport("dwmapi")] public static extern int DwmGetWindowAttribute(IntPtr h, int a, out int v, int s);
  [DllImport("user32")] public static extern int GetWindowLong(IntPtr h, int i);
  [DllImport("user32")] public static extern bool SetWindowPos(IntPtr h, IntPtr a, int x, int y, int cx, int cy, uint f);
  [DllImport("user32")] public static extern bool GetLayeredWindowAttributes(IntPtr h, out uint k, out byte a, out uint f);
  public static int Accent(IntPtr h, int state) {
    var p = new AP { State = state }; var ptr = Marshal.AllocHGlobal(Marshal.SizeOf(p));
    Marshal.StructureToPtr(p, ptr, false);
    var d = new WCAD { Attrib = 19, pv = ptr, cb = (IntPtr)Marshal.SizeOf(p) };
    int r = SetWindowCompositionAttribute(h, ref d); Marshal.FreeHGlobal(ptr); return r;
  }
  public static int Backdrop(IntPtr h, int v) { return DwmSetWindowAttribute(h, 38, ref v, 4); }
  public static int ReadBackdrop(IntPtr h) { int v; DwmGetWindowAttribute(h, 38, out v, 4); return v; }
}
'@
[void][P]::SetProcessDpiAwarenessContext([IntPtr](-4))

function Measure-Patch([int]$X, [int]$Y, [int]$W, [int]$H, [string]$Name) {
    $bmp = New-Object System.Drawing.Bitmap $W, $H
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    $g.CopyFromScreen($X, $Y, 0, 0, (New-Object System.Drawing.Size $W, $H))
    $g.Dispose()
    $bmp.Save((Join-Path $Out "$Name.png"))
    # High-frequency energy: mean |dG| between horizontal neighbours. The
    # checker alternates white/red, so G swings 255<->0 at every 8px edge; a
    # sharp view keeps big steps, a blur flattens them.
    $sum = 0.0; $n = 0; $gsum = 0.0; $rsum = 0.0
    for ($yy = 0; $yy -lt $H; $yy += 2) {
        $prev = $null
        for ($xx = 0; $xx -lt $W; $xx++) {
            $c = $bmp.GetPixel($xx, $yy)
            $gsum += $c.G; $rsum += $c.R
            if ($null -ne $prev) { $sum += [Math]::Abs($c.G - $prev); $n++ }
            $prev = $c.G
        }
    }
    $px = ($H / 2) * $W
    $bmp.Dispose()
    [pscustomobject]@{ mode = $Name; hf = [Math]::Round($sum / $n, 2); meanR = [Math]::Round($rsum / $px, 1); meanG = [Math]::Round($gsum / $px, 1) }
}

$checker = New-Object Checker
$checker.Bounds = New-Object System.Drawing.Rectangle 200, 200, 900, 700
$checker.Show(); [System.Windows.Forms.Application]::DoEvents()

$proc = Start-Process -FilePath $Exe -ArgumentList '--config-default-files=false', '--background-opacity=0.6', '--background-blur=true', '--background=#101010', '--foreground=#101010' -PassThru
try {
    $hwnd = [IntPtr]::Zero
    for ($i = 0; $i -lt 100 -and $hwnd -eq [IntPtr]::Zero; $i++) {
        Start-Sleep -Milliseconds 200; $proc.Refresh(); $hwnd = $proc.MainWindowHandle
    }
    if ($hwnd -eq [IntPtr]::Zero) { throw 'no ghoztty window' }
    Start-Sleep -Milliseconds 1500
    # HWND_TOPMOST, SWP_NOACTIVATE|SWP_SHOWWINDOW
    [void][P]::SetWindowPos($hwnd, [IntPtr](-1), 300, 300, 700, 500, 0x0050)
    $ex = [P]::GetWindowLong($hwnd, -20)
    $k = 0; $a = 0; $f = 0; [void][P]::GetLayeredWindowAttributes($hwnd, [ref]$k, [ref]$a, [ref]$f)
    "exstyle=0x{0:x} layered={1} alpha={2} flags={3}" -f $ex, (($ex -band 0x80000) -ne 0), $a, $f
    $px = 600; $py = 600; $pw = 300; $ph = 120   # inside the client, clear of the prompt text
    $results = @()
    $results += Measure-Patch 220 220 300 60 'checker-bare-control'
    Start-Sleep -Milliseconds 800
    $results += Measure-Patch $px $py $pw $ph 'as-launched-accent-blur'
    $modes = @(
        @{ n = 'no-blur';            accent = 0; bd = 1 },
        @{ n = 'accent-blur';        accent = 3; bd = 1 },
        @{ n = 'backdrop-acrylic';   accent = 0; bd = 3 },
        @{ n = 'backdrop-mica';      accent = 0; bd = 2 },
        @{ n = 'accent+acrylic';     accent = 3; bd = 3 },
        @{ n = 'accent-acrylic-4';   accent = 4; bd = 1 }
    )
    foreach ($m in $modes) {
        $ra = [P]::Accent($hwnd, $m.accent); $rb = [P]::Backdrop($hwnd, $m.bd)
        Start-Sleep -Milliseconds 1200
        $r = Measure-Patch $px $py $pw $ph $m.n
        $r | Add-Member accentRet $ra; $r | Add-Member backdropHr ('0x{0:x}' -f $rb); $r | Add-Member readBack ([P]::ReadBackdrop($hwnd))
        $results += $r
    }
    # Positive controls: the same modes on a window built the way DWM
    # materials expect (no WS_EX_LAYERED, per-pixel alpha 0 in the client).
    Stop-Process -Id $proc.Id -Force
    $glass = New-Object Glass
    $glass.Bounds = New-Object System.Drawing.Rectangle 300, 300, 700, 500
    $glass.Show(); [System.Windows.Forms.Application]::DoEvents()
    $gh = $glass.Handle
    foreach ($m in $modes) {
        $ra = [P]::Accent($gh, $m.accent); $rb = [P]::Backdrop($gh, $m.bd)
        for ($t = 0; $t -lt 12; $t++) { [System.Windows.Forms.Application]::DoEvents(); Start-Sleep -Milliseconds 100 }
        $r = Measure-Patch $px $py $pw $ph ('glass-' + $m.n)
        $r | Add-Member accentRet $ra; $r | Add-Member backdropHr ('0x{0:x}' -f $rb); $r | Add-Member readBack ([P]::ReadBackdrop($gh))
        $results += $r
    }
    $glass.Close()
    $results | Format-Table -AutoSize | Out-String -Width 200
} finally {
    if ($proc -and -not $proc.HasExited) { Stop-Process -Id $proc.Id -Force }
    $checker.Close()
}
