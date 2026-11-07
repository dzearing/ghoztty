# T2733: what the box looked like when the comp-spike live oracle ran.
#
# On 2026-11-05 the live oracle read comp=0 (1 captured frame per run, the
# edge never moved) while gdi still scored; on 2026-11-07 the same build on the
# same box read 0.944 with nothing changed in the code. The failure was a BOX
# state, and nothing recorded which one (the cause T2465 guessed, a fully
# covered ghost, is disproved: the 11-07 green run was fully covered too). So
# every -Live run now prints one BOXSTATE line, and a blind comp verdict names
# it, so the next occurrence carries its own evidence.
#
# Get-UncoveredFraction is pure (rects in, fraction out) so it is unit-tested
# by test\win32\comp-box-state.ps1; Get-CompBoxState reads the live desktop
# (never opens, moves or focuses a window).

# Fraction of $Target not inside any of $Covers, sampled on a $Grid x $Grid
# lattice of cell centres. Rects are @{L;T;R;B} (R/B exclusive).
function Get-UncoveredFraction {
    param(
        [Parameter(Mandatory)][hashtable]$Target,
        [object[]]$Covers = @(),
        [int]$Grid = 24
    )
    $w = $Target.R - $Target.L
    $h = $Target.B - $Target.T
    if ($w -le 0 -or $h -le 0) { return 0.0 }
    $free = 0
    for ($i = 0; $i -lt $Grid; $i++) {
        $x = $Target.L + ($i + 0.5) * $w / $Grid
        for ($j = 0; $j -lt $Grid; $j++) {
            $y = $Target.T + ($j + 0.5) * $h / $Grid
            $hit = $false
            foreach ($c in $Covers) {
                if ($x -ge $c.L -and $x -lt $c.R -and $y -ge $c.T -and $y -lt $c.B) { $hit = $true; break }
            }
            if (-not $hit) { $free++ }
        }
    }
    return [double]$free / ($Grid * $Grid)
}

if (-not ('CompBoxState.Native' -as [type])) {
    Add-Type -Namespace CompBoxState -Name Native -MemberDefinition @'
[StructLayout(LayoutKind.Sequential)] public struct RECT { public int L, T, R, B; }
[StructLayout(LayoutKind.Sequential)] public struct POWER { public byte AC, Battery, Percent, SaverFlag; public int Life, Full; }
[StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)] public struct MONINFO { public int cb; public RECT Mon, Work; public int Flags; }
public delegate bool EnumProc(IntPtr h, IntPtr l);
[DllImport("user32.dll")] public static extern bool EnumWindows(EnumProc cb, IntPtr l);
[DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr h);
[DllImport("user32.dll")] public static extern bool IsIconic(IntPtr h);
[DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out RECT r);
[DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
[DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern int GetClassNameW(IntPtr h, System.Text.StringBuilder s, int n);
[DllImport("user32.dll")] public static extern IntPtr MonitorFromWindow(IntPtr h, int flags);
[DllImport("user32.dll")] public static extern IntPtr MonitorFromRect(ref RECT r, int flags);
[DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern bool GetMonitorInfoW(IntPtr m, ref MONINFO i);
[DllImport("user32.dll")] public static extern int GetSystemMetrics(int i);
[DllImport("user32.dll")] public static extern bool SystemParametersInfoW(int a, int b, out int v, int c);
[DllImport("kernel32.dll")] public static extern bool GetSystemPowerStatus(out POWER p);
[DllImport("dwmapi.dll")] public static extern int DwmGetWindowAttribute(IntPtr h, int a, out int v, int n);
[DllImport("user32.dll")] public static extern int GetWindowLongW(IntPtr h, int i);
'@
}

function Get-CompWindowClass([IntPtr]$h) {
    $sb = New-Object System.Text.StringBuilder 128
    [void][CompBoxState.Native]::GetClassNameW($h, $sb, 128)
    return $sb.ToString()
}

# One line describing the desktop the ghost at ($X,$Y) sized $W x $H lands on.
# Every field is a cause that could stop DWM ticking its animations.
function Get-CompBoxState {
    param([int]$X, [int]$Y, [int]$W = 1016, [int]$H = 679)
    $N = [CompBoxState.Native]
    $target = @{ L = $X; T = $Y; R = $X + $W; B = $Y + $H }
    $skip = @('Progman', 'WorkerW', 'Shell_TrayWnd', 'Shell_SecondaryTrayWnd', 'GhozttyCompSpike')
    $covers = New-Object System.Collections.ArrayList
    $script:compOverlays = 0
    $cb = [CompBoxState.Native+EnumProc] {
        param($h, $l)
        if (-not $N::IsWindowVisible($h) -or $N::IsIconic($h)) { return $true }
        $cloak = 0
        if ($N::DwmGetWindowAttribute($h, 14, [ref]$cloak, 4) -eq 0 -and $cloak -ne 0) { return $true }
        # A click-through window (our own ghosts) does not occlude, and a layered
        # one is an overlay (the NVIDIA overlay spans a whole monitor, see-through):
        # counted separately, never as a cover, or every ghost reads covered.
        $exs = $N::GetWindowLongW($h, -20)
        if (($exs -band 0x20) -ne 0) { return $true }
        if (($exs -band 0x80000) -ne 0) { $script:compOverlays++; return $true }
        if ($skip -contains (Get-CompWindowClass $h)) { return $true }
        $r = New-Object CompBoxState.Native+RECT
        if ($N::GetWindowRect($h, [ref]$r) -and $r.R -gt $r.L -and $r.B -gt $r.T) {
            [void]$covers.Add(@{ L = $r.L; T = $r.T; R = $r.R; B = $r.B })
        }
        return $true
    }
    [void]$N::EnumWindows($cb, [IntPtr]::Zero)
    $uncovered = Get-UncoveredFraction -Target $target -Covers @($covers)

    $fg = $N::GetForegroundWindow()
    $fgClass = if ($fg -ne [IntPtr]::Zero) { Get-CompWindowClass $fg } else { 'none' }
    $fgFull = $false
    if ($fg -ne [IntPtr]::Zero) {
        $fr = New-Object CompBoxState.Native+RECT
        $mi = New-Object CompBoxState.Native+MONINFO
        $mi.cb = [System.Runtime.InteropServices.Marshal]::SizeOf($mi)
        if ($N::GetWindowRect($fg, [ref]$fr) -and $N::GetMonitorInfoW($N::MonitorFromWindow($fg, 2), [ref]$mi)) {
            $fgFull = ($fr.L -le $mi.Mon.L -and $fr.T -le $mi.Mon.T -and $fr.R -ge $mi.Mon.R -and $fr.B -ge $mi.Mon.B)
        }
    }
    $gr = New-Object CompBoxState.Native+RECT
    $gr.L = $target.L; $gr.T = $target.T; $gr.R = $target.R; $gr.B = $target.B
    $gm = New-Object CompBoxState.Native+MONINFO
    $gm.cb = [System.Runtime.InteropServices.Marshal]::SizeOf($gm)
    $onMon = 'none'
    $hm = $N::MonitorFromRect([ref]$gr, 0)
    if ($hm -ne [IntPtr]::Zero -and $N::GetMonitorInfoW($hm, [ref]$gm)) {
        $onMon = '{0},{1},{2}x{3}{4}' -f $gm.Mon.L, $gm.Mon.T, ($gm.Mon.R - $gm.Mon.L), ($gm.Mon.B - $gm.Mon.T), $(if (($gm.Flags -band 1) -ne 0) { ',primary' } else { '' })
    }
    $anim = 0
    [void]$N::SystemParametersInfoW(0x1042, 0, [ref]$anim, 0)  # SPI_GETCLIENTAREAANIMATION
    $p = New-Object CompBoxState.Native+POWER
    $power = 'unknown'
    $saver = 'unknown'
    if ($N::GetSystemPowerStatus([ref]$p)) {
        $power = switch ($p.AC) { 0 { 'battery' } 1 { 'ac' } default { 'unknown' } }
        $saver = if (($p.SaverFlag -band 1) -ne 0) { 'on' } else { 'off' }
    }
    $transp = 'unknown'
    try {
        $v = Get-ItemPropertyValue -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize' -Name EnableTransparency -ErrorAction Stop
        $transp = if ($v -ne 0) { 'on' } else { 'off' }
    } catch { }
    # The 2026-11-05 blind runs followed an update installed 2026-11-03, so the
    # exact build (with its update revision) rides on every line.
    $os = 'unknown'
    try {
        $cv = Get-ItemProperty -Path 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion' -ErrorAction Stop
        $os = '{0}.{1}' -f $cv.CurrentBuild, $cv.UBR
    } catch { }
    return ('BOXSTATE ghost={0},{1},{2}x{3} uncovered={4:N2} covers={5} overlays={6} monitor={7} monitors={8} fg_class={9} fg_fullscreen={10} client_anim={11} power={12} battery_saver={13} transparency={14} os={15}' -f
        $X, $Y, $W, $H, $uncovered, $covers.Count, $script:compOverlays, $onMon, $N::GetSystemMetrics(80), ($fgClass -replace ' ', '_'), $fgFull.ToString().ToLower(), $anim, $power, $saver, $transp, $os)
}

# Why a blind comp score is not (yet) a code defect: names the box state so
# the next occurrence carries its own evidence. Coverage is deliberately NOT
# named as a cause: T2465 blamed a covering maximized window, but on 2026-11-07
# a ghost with uncovered=0.00 under a maximized window scored 0.944 (T2733), so
# covering alone does not stop DWM's animations. Compare the line with a green
# run's instead.
function Get-CompBlindHint([string]$BoxState) {
    if (-not $BoxState) { return '' }
    $hint = " [box: $($BoxState -replace '^BOXSTATE ', '')]"
    if ($BoxState -match ' fg_fullscreen=true') {
        $hint += ' - a fullscreen foreground window is up; DWM may stop composing other windows on its monitor'
    } elseif ($BoxState -match ' battery_saver=on') {
        $hint += ' - battery saver is on'
    }
    $hint += ' - a desktop state, not yet a code defect: diff this line against a green run (T2733)'
    return $hint
}
