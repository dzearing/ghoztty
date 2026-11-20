# T1555 acceptance: activating an About box link reaches the URL it claims.
#
# T714 gave the About box a row of hyperlinks and ipc-version.ps1 proves they
# are there, labelled, visible and sized. Nothing proved that ACTIVATING one
# goes anywhere, because both the click and the Enter paths end in
# `App.openUrl` -> `ShellExecuteW`, and a script that clicked would launch a
# browser on every run.
#
# THE SEAM (src\apprt\win32\open_url_seam.zig, Debug builds only):
#   GHOZTTY_TEST_OPEN_URL_LOG=<file>   openUrl appends the URL to <file> as one
#                                      line instead of asking the shell
#   GHOZTTY_TEST_ABOUT_VERSION=X.Y.Z   About builds its links as a published
#                                      X.Y.Z release would - a dev build's own
#                                      version earns no release link at all
#
# THE ORACLE: the recorder's lines, read back after each activation and
# compared to the exact URL `about_links.zig` says that build earns.
#
#   A   the row a release-shaped build earns: Release notes, Commit, Docs,
#       GitHub - in that order
#   B   CLICK each link: one new line per click, the exact URL, and the
#       dialog is still open after each (the link follows; it never dismisses)
#   B1  the release link is the `win-v<version>` TAG page, not Mac's `v` tag
#   C   ENTER on a focused link follows it (one new line, its URL) and leaves
#       the dialog open - `handleKey` declines Enter for a focused link; if it
#       ever consumed it, Enter would dismiss the box and record nothing
#   D   control: Enter on the OK button DISMISSES the box and records nothing,
#       so C's "still open" is a claim the dialog could have failed
#
# -NegativeControl expects the wrong URL for Docs: B and C MUST go red.
#
# Runs on a BACKGROUND desktop (lib\TestDesktop.ps1); nothing takes the
# user's foreground - asserted by the foreground watcher, not assumed.
#
#   powershell -NoProfile -File test\win32\about-links.ps1

param([string]$ExePath, [switch]$NegativeControl, [switch]$Interactive)

. (Join-Path $PSScriptRoot 'lib\CleanSlate.ps1')
$ErrorActionPreference = 'Continue'
$repo = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$exe = Join-Path $repo 'zig-out\bin\ghoztty.exe'
if ($ExePath) { $exe = $ExePath }
$cli = [System.IO.Path]::ChangeExtension($exe, '.com')
if (-not (Test-Path $cli)) { $cli = $exe }

$tmp = Join-Path $env:TEMP "ghoztty-t1555-$PID"
New-Item -ItemType Directory -Force $tmp | Out-Null
$urlLog = Join-Path $tmp 'opened-urls.txt'
$releaseVersion = '1.37.2'

# Inherited by the app through CreateProcessW.
$env:GHOZTTY_PIPE_SUFFIX = "-aboutlinks$PID"
$env:GHOZTTY_TEST_OPEN_URL_LOG = $urlLog
$env:GHOZTTY_TEST_ABOUT_VERSION = $releaseVersion

. (Join-Path $PSScriptRoot 'lib\TestDesktop.ps1')
. (Join-Path $PSScriptRoot 'lib\TestScore.ps1')

$script:pass = 0
$script:fail = 0
$script:skipped = 0
function Assert([bool]$cond, [string]$label) {
    if ($cond) { $script:pass++; Write-Host "PASS  $label" }
    else { $script:fail++; Write-Host "FAIL  $label" -ForegroundColor Red }
}

# The fork's URLs, written out here rather than read from about_links.zig: the
# point is to compare the app against an independent statement of them.
$repoUrl = 'https://github.com/dzearing/ghoztty'
$docsUrl = 'https://dzearing.github.io/ghoztty/'
if ($NegativeControl) {
    Write-Host 'NEGATIVE CONTROL: expecting the wrong Docs URL - B and C MUST fail'
    $docsUrl = 'https://example.invalid/not-the-docs/'
}

function Get-UrlLines {
    if (-not (Test-Path $urlLog)) { return @() }
    return @(Get-Content -LiteralPath $urlLog | Where-Object { $_ -ne '' })
}

# Wait for the recorder to grow past $Before lines; the new lines, or @().
function Wait-NewUrls([int]$Before, [int]$TimeoutMs = 4000) {
    $sw = [Diagnostics.Stopwatch]::StartNew()
    while ($sw.ElapsedMilliseconds -lt $TimeoutMs) {
        $lines = @(Get-UrlLines)
        if ($lines.Count -gt $Before) {
            Start-Sleep -Milliseconds 200   # a second line would be a defect too
            $lines = @(Get-UrlLines)
            return @($lines[$Before..($lines.Count - 1)])
        }
        Start-Sleep -Milliseconds 100
    }
    return @()
}

function Get-LinkByLabel($Dlg, [string]$Label) {
    foreach ($l in @(Get-TestChildWindows -Window $Dlg -Class 'SysLink')) {
        if ((Get-TestControlText -Control ([IntPtr]$l.Hwnd)) -eq "<a>$Label</a>") { return $l }
    }
    return $null
}

# Posted, never sent: the dialog is modal and its nested pump is what
# dispatches the click (activity-monitor.ps1's Click-TestPosted, same reason).
function Click-Link($Dlg, $Link) {
    $h = [IntPtr]$Link.Hwnd
    $r = Get-TestWindowRect -Window $h
    return Send-TestMouse -Window $Dlg -Target $h `
        -X ([int](($r.Left + $r.Right) / 2)) -Y ([int](($r.Top + $r.Bottom) / 2)) `
        -Button left -Action click
}

function Open-AboutBox($AppPid, [IntPtr]$Top, [IntPtr]$Surface) {
    foreach ($try in 1..3) {
        if (-not (Send-TestKeys -Window $Top -Target $Surface -Modifiers ctrl, shift -Key P)) { continue }
        $popup = Wait-TestWindow -ProcessId $AppPid -Class 'GhozttyCommandPalette' -TimeoutMs 5000
        if ($popup -eq [IntPtr]::Zero) { continue }
        $edit = Find-TestWindowEx -Parent $popup -Class 'EDIT'
        if ($edit -eq [IntPtr]::Zero) { continue }
        Send-TestControlText -Control $edit -Text 'about' | Out-Null
        Send-TestControlKey -Control $edit -Key Enter | Out-Null
        $dlg = Wait-TestWindow -ProcessId $AppPid -Class 'GhozttyConfirmDialog' -TimeoutMs 5000
        if ($dlg -ne [IntPtr]::Zero) { return $dlg }
    }
    return [IntPtr]::Zero
}

Reset-GhozttyTestState -Exe $exe -SettleMs 1000 | Out-Null
Start-TestForegroundWatch
$td = New-TestDesktop -Interactive:$Interactive
$launched = @()

try {
    "== setup: one debug window on the test desktop, links recorded"
    $app = Start-OnTestDesktop -Exe $exe -Arguments @('--session-persistence=false')
    $launched += $app.Pid
    $top = Wait-TestWindow -ProcessId $app.Pid -Class 'GhozttyWindow' -TimeoutMs 15000
    if ($top -eq [IntPtr]::Zero) { throw 'SETUP: top window not found' }
    Start-Sleep -Seconds 2
    $surface = Get-TestChildWindow -Window $top -Class 'GhozttyTerminal'
    if ($surface -eq [IntPtr]::Zero) { throw 'SETUP: terminal surface not found' }

    # The commit the About box links: the one this build stamped.
    cmd /c "`"$cli`" +list --json > `"$tmp\list.json`" 2>&1" | Out-Null
    $commit = ''
    try { $commit = [string](Get-Content "$tmp\list.json" -Raw | ConvertFrom-Json).data.build.commit } catch {}
    Assert ($commit -match '^[0-9a-f]{7,40}$') "setup: the build stamped a commit ('$commit')"

    $expected = [ordered]@{
        'Release notes' = "$repoUrl/releases/tag/win-v$releaseVersion"
        'Commit'        = "$repoUrl/commits/$commit"
        'Docs'          = $docsUrl
        'GitHub'        = $repoUrl
    }

    $dlg = Open-AboutBox $app.Pid $top $surface
    if ($dlg -eq [IntPtr]::Zero) { throw 'SETUP: the About box never opened' }
    Assert (-not (Test-Path $urlLog)) 'setup: opening About followed no link'

    "== A: the row a release-shaped build earns"
    $labels = @(Get-TestChildWindows -Window $dlg -Class 'SysLink' |
        Sort-Object { $_.Left } |
        ForEach-Object { Get-TestControlText -Control ([IntPtr]$_.Hwnd) })
    "  link row: $($labels -join ' | ')"
    Assert (($labels -join '|') -eq '<a>Release notes</a>|<a>Commit</a>|<a>Docs</a>|<a>GitHub</a>') `
        'A  Release notes, Commit, Docs, GitHub - in that order'

    "== B: clicking each link records exactly its URL, and the box stays open"
    foreach ($label in $expected.Keys) {
        $link = Get-LinkByLabel $dlg $label
        if (-not $link) { Assert $false "B  '$label' link exists"; continue }
        $before = @(Get-UrlLines).Count
        Click-Link $dlg $link | Out-Null
        $new = @(Wait-NewUrls $before)
        "  clicked '$label' -> $($new -join ' ; ')"
        Assert ($new.Count -eq 1) "B  '$label': one click, one URL (got $($new.Count))"
        Assert ($new.Count -ge 1 -and $new[0] -eq $expected[$label]) "B  '$label' goes to $($expected[$label])"
        Assert (Test-TestWindowExists -Window $dlg) "B  '$label': the About box is still open"
    }
    $rel = @(@(Get-UrlLines) | Where-Object { $_ -like '*/releases/*' })
    Assert ($rel.Count -eq 1 -and $rel[0] -match "/releases/tag/win-v$([regex]::Escape($releaseVersion))$") `
        "B1 the release link is the win-v$releaseVersion TAG page"

    "== C: Enter on a focused link follows it and leaves the box open"
    $docs = Get-LinkByLabel $dlg 'Docs'
    if (-not $docs) {
        Assert $false 'C  Docs link exists'
    } else {
        $focused = Focus-TestWindow -Window $dlg -Child ([IntPtr]$docs.Hwnd)
        Assert ([bool]$focused) 'C  the Docs link took the keyboard'
        $before = @(Get-UrlLines).Count
        Send-TestControlKey -Control ([IntPtr]$docs.Hwnd) -Key Enter | Out-Null
        $new = @(Wait-NewUrls $before)
        "  Enter on Docs -> $($new -join ' ; ')"
        Assert ($new.Count -eq 1 -and $new[0] -eq $expected['Docs']) "C  Enter follows the Docs link to $($expected['Docs'])"
        Start-Sleep -Milliseconds 300
        Assert (Test-TestWindowExists -Window $dlg) 'C  ...and the About box is still open'
    }

    "== D: control - Enter on OK dismisses the box and follows nothing"
    $ok = [IntPtr]::Zero
    foreach ($b in @(Get-TestChildWindows -Window $dlg -Class 'Button')) {
        if ((Get-TestControlText -Control ([IntPtr]$b.Hwnd)) -match '^&?OK$') { $ok = [IntPtr]$b.Hwnd }
    }
    Assert ($ok -ne [IntPtr]::Zero) 'D  the OK button exists'
    if ($ok -ne [IntPtr]::Zero) {
        Focus-TestWindow -Window $dlg -Child $ok | Out-Null
        $before = @(Get-UrlLines).Count
        Send-TestControlKey -Control $ok -Key Enter | Out-Null
        $sw = [Diagnostics.Stopwatch]::StartNew()
        while ((Test-TestWindowExists -Window $dlg) -and $sw.ElapsedMilliseconds -lt 4000) { Start-Sleep -Milliseconds 100 }
        Assert (-not (Test-TestWindowExists -Window $dlg)) 'D  Enter on OK closes the About box'
        Assert (@(Get-UrlLines).Count -eq $before) 'D  ...and follows no link'
    }
    if (Test-TestWindowExists -Window $dlg) { Send-TestWindowClose -Window $dlg | Out-Null }

    Assert (-not ($app.Process -and $app.Process.HasExited)) 'no crash across the About round-trip'
    Complete-TestBody
} catch {
    Write-Host "FAIL  aborted: $($_.Exception.Message)" -ForegroundColor Red
    $script:fail++
} finally {
    Remove-TestDesktop
    Reset-GhozttyTestState -Exe $exe -SettleMs 500 | Out-Null
    Remove-Item -Recurse -Force $tmp -ErrorAction SilentlyContinue
    Remove-Item Env:\GHOZTTY_TEST_OPEN_URL_LOG -ErrorAction SilentlyContinue
    Remove-Item Env:\GHOZTTY_TEST_ABOUT_VERSION -ErrorAction SilentlyContinue
}

$fgSeen = @(Stop-TestForegroundWatch)
if (-not $Interactive -and $env:GHOZTTY_TEST_INTERACTIVE -ne '1') {
    $launched = @($launched | Select-Object -Unique)
    Assert ($fgSeen.Count -gt 0) 'the foreground watcher actually sampled (negative control)'
    $leaked = @($launched | Where-Object { $fgSeen -contains $_ })
    Assert ($leaked.Count -eq 0) 'no test-desktop app ever became foreground on the interactive desktop'
}
Assert (Test-TestBodyComplete) 'the script ran to the end (no section was skipped by an error)'

if ($script:fail -eq 0 -and $script:skipped -eq 0 -and -not $NegativeControl) {
    & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $repo 'scripts\guard-due.ps1') `
        update -Guard about-links -Repo $repo 2>&1 | ForEach-Object { "  $_" }
}

""
Write-TestVerdict -Pass $script:pass -Fail $script:fail -Skipped ([int]$script:skipped) -Label 'T1555 ACCEPTANCE'
