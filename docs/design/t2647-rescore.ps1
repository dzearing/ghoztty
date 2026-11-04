# T2647 probe: re-score a saved divider-flicker.ps1 -Live cell (its frames\ PNGs + pressed.png)
# offline through lib\DividerFlickerScore.ps1, so a scorer change can be checked against real
# captures without filming again. The live run does not log its banner lines: read them off
# pressed.png (a column scan of the pane across the divider) and pass -BannerLines "y1,y2".
#   powershell -NoProfile -File docs\design\t2647-rescore.ps1 -Dir temp\divider-flicker\<run>\1-vertical\frames -Line 615 -Lo 947 -Hi 1225 -BannerLines 113,128
param([string]$Dir, [int]$Line, [int]$Lo, [int]$Hi, [string]$BannerLines, [int]$Accent = 0xB95BD0)
$ErrorActionPreference = 'Stop'
$dfLibDir = 'D:\git\ghoztty\test\win32\lib'
. (Join-Path $dfLibDir 'FrameLabDriver.ps1'); Import-FrameLabDriver; Import-FrameCapture
. (Join-Path $dfLibDir 'DividerFlickerScore.ps1'); Import-DividerFlickerScore
Add-Type -AssemblyName System.Drawing
function Load([string]$p, [long]$ix) {
  $b = New-Object System.Drawing.Bitmap $p
  $r = New-Object System.Drawing.Rectangle 0, 0, $b.Width, $b.Height
  $d = $b.LockBits($r, 'ReadOnly', [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
  $f = New-Object GfcFrame; $f.Index = $ix; $f.W = $b.Width; $f.H = $b.Height; $f.Px = New-Object int[] ($b.Width * $b.Height)
  for ($y = 0; $y -lt $b.Height; $y++) { [Runtime.InteropServices.Marshal]::Copy([IntPtr]($d.Scan0.ToInt64() + $y * $d.Stride), $f.Px, $y * $b.Width, $b.Width) }
  $b.UnlockBits($d); $b.Dispose()
  for ($i = 0; $i -lt $f.Px.Length; $i++) { $f.Px[$i] = $f.Px[$i] -band 0xFFFFFF }
  return $f
}
$s = New-Object DfScorer
$s.Accent = $Accent; $s.Line = $Line; $s.Lo = $Lo; $s.Hi = $Hi; $s.BannerLines = [int[]]($BannerLines -split "," | ForEach-Object { [int]$_ })
$p0 = Load (Join-Path (Split-Path $Dir) 'pressed.png') 0
$s.BiteBase = ($s.Read($p0))[3]
foreach ($p in (Get-ChildItem $Dir -Filter 'f*.png' | Sort-Object Name)) {
  $ix = [long]($p.BaseName -replace '^f0*(\d+).*$', '$1')
  [void]$s.Score((Load $p.FullName $ix))
}
$c = Get-DividerFlickerCounts -Scorer $s
"base=$($s.BiteBase) frames=$($c.Frames) bitten=$($c.BittenFrames) [$($c.BittenWorst -join ' ')] torn=$($c.TornFrames) [$($c.TornWorst -join ' ')] ghost=$($c.GhostFrames) [$($c.GhostWorst -join ' ')] bar-gone=$($c.BarGoneFrames)"
