# UserAlert.ps1 - tell the user something only they can fix, without taking
# their focus (T2097).
#
# The loop's supervisors are built to recover on their own, and for almost
# everything they can. An expired Claude login is the exception: nothing typed
# into the pane clears it, so on 2026-10-18..20 the watchdog nudged both lanes
# 171 times over 2.5 days and the user found out by looking. These are the two
# channels that reach them instead: a Windows toast notification, and a banner
# on the loop's own pane - because the toast can be switched off per app, and on
# this box it is.
#
# A toast is the right shape for go.md's NEVER PULL FOCUS rule. It does not
# activate a window or take the keyboard, and Windows itself holds it in the
# notification center while a fullscreen game or Focus Assist is on, so it can
# never pop over the thing the user is doing.
#
# Test seam: with $env:GHOZTTY_LOOP_ALERT_SINK set to a file path, the alert is
# appended there as one JSON line and nothing is shown. The acceptance harness
# runs under that, so it can count alerts without putting a toast on anyone's
# screen.

# The AppUserModelID toasts are posted under. Windows PowerShell's own is
# registered on every Windows install, so no shortcut or registration step has
# to exist first (an unregistered id makes Show() a silent no-op).
$script:LoopAlertAppId = '{1AC14E77-02E7-4E5D-B744-2EB1AE5198B7}\WindowsPowerShell\v1.0\powershell.exe'

function ConvertTo-LoopAlertXmlText([string]$Text) {
    return [System.Security.SecurityElement]::Escape($Text)
}

# Returns 'sink' / 'toast' / 'failed: <why>'. Never throws: a supervisor that
# dies because the notification platform is unavailable has turned one problem
# into two.
function Send-LoopUserAlert {
    param([string]$Title, [string]$Body)
    $sink = $env:GHOZTTY_LOOP_ALERT_SINK
    if ($sink) {
        try {
            $line = ([ordered]@{ at = (Get-Date).ToString('o'); title = $Title; body = $Body } |
                ConvertTo-Json -Compress)
            Add-Content -LiteralPath $sink -Value $line -Encoding UTF8
            return 'sink'
        } catch { return "failed: $($_.Exception.Message)" }
    }
    try {
        [void][Windows.UI.Notifications.ToastNotificationManager, Windows.UI.Notifications, ContentType = WindowsRuntime]
        [void][Windows.Data.Xml.Dom.XmlDocument, Windows.Data.Xml.Dom.XmlDocument, ContentType = WindowsRuntime]
        $xml = New-Object Windows.Data.Xml.Dom.XmlDocument
        # scenario="reminder" keeps it on screen until dismissed rather than
        # sliding away after five seconds - the toast is only worth sending if it
        # is still there when the user looks up.
        $xml.LoadXml(('<toast scenario="reminder"><visual><binding template="ToastGeneric">' +
            "<text>$(ConvertTo-LoopAlertXmlText $Title)</text>" +
            "<text>$(ConvertTo-LoopAlertXmlText $Body)</text>" +
            '</binding></visual><actions><action content="Dismiss" arguments="dismiss" activationType="system"/></actions></toast>'))
        $toast = New-Object Windows.UI.Notifications.ToastNotification $xml
        $notifier = [Windows.UI.Notifications.ToastNotificationManager]::CreateToastNotifier($script:LoopAlertAppId)
        # Show() on a notifier the user has switched off returns normally and
        # displays nothing - measured on this box on 2026-10-20, where Windows
        # PowerShell's notifications read DisabledForUser. So ask first, and say
        # so, rather than logging an alert nobody saw.
        $setting = [string]$notifier.Setting
        if ($setting -and $setting -ne 'Enabled') {
            return "failed: Windows notifications are off for Windows PowerShell (Setting=$setting)"
        }
        $notifier.Show($toast)
        return 'toast'
    } catch { return "failed: $($_.Exception.Message)" }
}

# The second channel, and the one that cannot be switched off: a banner on the
# loop's own pane (`+set-banner`, no focus change). A session stuck on a blocker
# cannot repaint its banner, so this one stays put until the user acts - and the
# first turn after they do sets its own banner over it, so nothing needs
# clearing. Same sink seam as the toast. Returns 'sink' / 'banner' / 'failed: ...'.
function Send-LoopPaneBanner {
    param([string]$GhozttyExe, [string]$PaneId, [string]$Text)
    if (-not $PaneId) { return 'failed: no pane to put it on' }
    # argv, not a keys file: +set-banner has no file form, and the text is ours.
    # PS 5.1 does not escape an embedded `"` on a native command line (T210),
    # so none may reach it.
    # A trailing backslash is the other half of that hazard: it escapes the
    # closing quote PowerShell adds around an argument with spaces.
    $Text = ($Text -replace '"', "'").TrimEnd('\')
    $sink = $env:GHOZTTY_LOOP_ALERT_SINK
    if ($sink) {
        try {
            $line = ([ordered]@{ at = (Get-Date).ToString('o'); banner = $PaneId; body = $Text } | ConvertTo-Json -Compress)
            Add-Content -LiteralPath $sink -Value $line -Encoding UTF8
            return 'sink'
        } catch { return "failed: $($_.Exception.Message)" }
    }
    try {
        # argv-audit: +set-banner has no file form; $Text had every '"' and any trailing '\' removed above.
        $out = & $GhozttyExe '+set-banner' "--target=$PaneId" $Text 2>&1 | Out-String
        if ($LASTEXITCODE -eq 0) { return 'banner' }
        return "failed: exit $LASTEXITCODE $($out.Trim())"
    } catch { return "failed: $($_.Exception.Message)" }
}
