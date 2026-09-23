<#
Drive a WebView2 page from an acceptance script over the DevTools protocol
(T1702).

THE GAP. The feedback composer's text box is a Chromium page (T934), and the
background test desktop has no input desktop: SendInput and CopyFromScreen are
dead there (T233), and a Chromium window takes no posted WM_CHAR. So until this
file, a script could prove the web composer OPENED, but could not type one
character into it or read one back - which is why six harnesses still pin
themselves to the RichEdit fallback (T937 -> T1703 re-points them, T1704 deletes
the fallback).

THE ROUTE. The WebView2 runtime honours WEBVIEW2_ADDITIONAL_BROWSER_ARGUMENTS
from the environment of the process that creates the environment - and it does
so inside EmbeddedBrowserWebView.dll, not only in WebView2Loader.dll, so our
loader-less entry point (webview2.zig) gets it too. Verified on this box on
2026-09-23 against runtime 153.0.4234.48: the browser process came up with
`--remote-debugging-port=<n>` on its command line and /json/list answered. That
means NO product code is involved: the app never reads this variable, it is the
runtime's own switch, and a release build is no different from a debug one -
which is also why it is set only in the environment of the app a test launches,
never globally.

Three consequences to keep in mind:

  * Arm BEFORE launch. The switch is read when the browser process starts, i.e.
    when the app's shared environment is created on the first viewer pane. An
    app that already has one ignores a later change.
  * The port is per browser process, and there is ONE per app (one shared
    environment, one user-data folder). Every page of that app - each viewer
    pane, each composer - is a separate target on the same port.
  * A browser process that ALREADY runs on the same user-data folder is reused
    and keeps its own switches. The debug build's folder is not the release
    build's (paths.userDataFolder), and the harness's shared kill clears repo
    instances,
    so in practice the switch sticks; Find-CdpComposer saying "no endpoint"
    is the symptom if it ever does not.

USE

    . (Join-Path $PSScriptRoot 'lib\FreePort.ps1')
    . (Join-Path $PSScriptRoot 'lib\WebViewCdp.ps1')
    $cdpPort = Enable-WebViewCdp            # before Start-OnTestDesktop
    ... launch the app, open a viewer pane, open the composer ...
    $c = Find-CdpComposer -Port $cdpPort    # throws when there is none
    Send-CdpComposerText $c 'hello'
    Send-CdpKey $c 'Enter'
    Send-CdpKey $c 'z' -Ctrl                 # the page's own undo
    (Get-CdpComposerText $c)                 # the document, read back
    Close-Cdp $c

WHAT A KEY EVENT HERE IS NOT. Input.dispatchKeyEvent is delivered into the
renderer. Whether it also raises the controller's AcceleratorKeyPressed (where
native claims Ctrl+Enter / Esc and the pane's keybinds) is the runtime's
business, and even when it does, native reads MODIFIERS from GetKeyState - the
OS keyboard state, which a synthetic event does not touch. So a chord NATIVE
owns is not proven by this driver; drive those through the band's own window
messages. Chords the PAGE owns (Ctrl+Z / Ctrl+Y undo, Backspace beside a chip)
are exactly what it is for.

Acceptance: section H of test\win32\viewer-composer.ps1.
#>

# No Set-StrictMode here: a dot-sourced file's strict mode becomes the CALLER's,
# and the harnesses this serves were not written under it.

$script:WebViewCdpEnvVar = 'WEBVIEW2_ADDITIONAL_BROWSER_ARGUMENTS'

# Draw a port, and arm every ghoztty this script launches afterwards to expose
# its WebView2 browser on it. Needs lib\FreePort.ps1 dot-sourced first.
function Enable-WebViewCdp {
    param([int]$Port = 0)
    $p = Resolve-TestPort -Name 'webview-cdp' -Port $Port
    Set-Item -Path "env:$script:WebViewCdpEnvVar" -Value "--remote-debugging-port=$p"
    return $p
}

# Stop arming later launches (an app already running keeps its port).
function Disable-WebViewCdp {
    Remove-Item -Path "env:$script:WebViewCdpEnvVar" -ErrorAction SilentlyContinue
}

# The debuggable targets on a port, or an empty list when nothing answers.
function Get-CdpTargets {
    param([Parameter(Mandatory = $true)][int]$Port)
    try {
        $r = Invoke-WebRequest -UseBasicParsing -TimeoutSec 5 `
            -Uri "http://127.0.0.1:$Port/json/list"
    } catch {
        return @()
    }
    $list = $r.Content | ConvertFrom-Json
    return @($list | Where-Object { $_.type -eq 'page' })
}

# Open a session on one target's websocket.
function Connect-Cdp {
    param(
        [Parameter(Mandatory = $true)][string]$WebSocketUrl,
        [int]$TimeoutMs = 5000
    )
    $ws = New-Object System.Net.WebSockets.ClientWebSocket
    $task = $ws.ConnectAsync([Uri]$WebSocketUrl, [System.Threading.CancellationToken]::None)
    if (-not $task.Wait($TimeoutMs) -or $ws.State -ne [System.Net.WebSockets.WebSocketState]::Open) {
        $ws.Dispose()
        throw "CDP: could not open $WebSocketUrl within $TimeoutMs ms"
    }
    return [pscustomobject]@{ Ws = $ws; NextId = 1; Url = $WebSocketUrl }
}

function Close-Cdp {
    param($Conn)
    if (-not $Conn) { return }
    try {
        if ($Conn.Ws.State -eq [System.Net.WebSockets.WebSocketState]::Open) {
            [void]$Conn.Ws.CloseAsync(
                [System.Net.WebSockets.WebSocketCloseStatus]::NormalClosure, 'done',
                [System.Threading.CancellationToken]::None).Wait(2000)
        }
    } catch {}
    $Conn.Ws.Dispose()
}

# One whole message off the socket, or $null when the deadline passes.
function Receive-CdpMessage {
    param($Conn, [datetime]$Deadline)
    $buf = New-Object byte[] 65536
    $ms = New-Object System.IO.MemoryStream
    try {
        while ($true) {
            $left = [int]($Deadline - (Get-Date)).TotalMilliseconds
            if ($left -le 0) { return $null }
            $seg = New-Object System.ArraySegment[byte] -ArgumentList @(, $buf)
            $task = $Conn.Ws.ReceiveAsync($seg, [System.Threading.CancellationToken]::None)
            if (-not $task.Wait($left)) { return $null }
            $res = $task.Result
            if ($res.MessageType -eq [System.Net.WebSockets.WebSocketMessageType]::Close) {
                throw 'CDP: the target closed the session'
            }
            $ms.Write($buf, 0, $res.Count)
            if ($res.EndOfMessage) { break }
        }
        return [System.Text.Encoding]::UTF8.GetString($ms.ToArray())
    } finally {
        $ms.Dispose()
    }
}

# Call one protocol method and return its `result`. Events that arrive in the
# meantime are skipped; a protocol error THROWS with the method named, so a
# caller's assertion never scores an error object as an answer.
function Invoke-Cdp {
    param(
        [Parameter(Mandatory = $true)]$Conn,
        [Parameter(Mandatory = $true)][string]$Method,
        [hashtable]$Params = @{},
        [int]$TimeoutMs = 5000
    )
    $id = $Conn.NextId
    $Conn.NextId = $id + 1
    $json = @{ id = $id; method = $Method; params = $Params } | ConvertTo-Json -Depth 10 -Compress
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($json)
    $seg = New-Object System.ArraySegment[byte] -ArgumentList @(, $bytes)
    $send = $Conn.Ws.SendAsync($seg, [System.Net.WebSockets.WebSocketMessageType]::Text, $true,
        [System.Threading.CancellationToken]::None)
    if (-not $send.Wait($TimeoutMs)) { throw "CDP: $Method could not be sent" }

    $deadline = (Get-Date).AddMilliseconds($TimeoutMs)
    while ($true) {
        $text = Receive-CdpMessage -Conn $Conn -Deadline $deadline
        if ($null -eq $text) { throw "CDP: $Method got no answer within $TimeoutMs ms" }
        $msg = $text | ConvertFrom-Json
        if (-not ($msg.PSObject.Properties.Name -contains 'id')) { continue }
        if ($msg.id -ne $id) { continue }
        if ($msg.PSObject.Properties.Name -contains 'error') {
            throw "CDP: $Method failed: $($msg.error.message)"
        }
        return $msg.result
    }
}

# Evaluate an expression in the page and return its value. A thrown exception
# in the page is a THROW here, not a value.
function Invoke-CdpEval {
    param([Parameter(Mandatory = $true)]$Conn, [Parameter(Mandatory = $true)][string]$Expression)
    $r = Invoke-Cdp $Conn 'Runtime.evaluate' @{ expression = $Expression; returnByValue = $true }
    if ($r.PSObject.Properties.Name -contains 'exceptionDetails') {
        throw "CDP: page threw evaluating '$Expression': $($r.exceptionDetails.text)"
    }
    if ($r.result.PSObject.Properties.Name -contains 'value') { return $r.result.value }
    return $null
}

# The composer page is the one whose `#c` is a plaintext-only editable box
# (viewer_feedback_page.zig documentAlloc). Keyed on that rather than on a URL,
# because NavigateToString pages have no URL of their own to key on.
$script:CdpComposerProbe = "(function(){var e=document.getElementById('c');" +
    "return !!e && e.getAttribute('contenteditable')==='plaintext-only';})()"

# Find the open composer's page and return a session on it. Waits for it to
# appear (the controller is created lazily when the composer opens) and THROWS
# when it never does, naming what the port did answer.
function Find-CdpComposer {
    param([Parameter(Mandatory = $true)][int]$Port, [int]$TimeoutMs = 15000)
    $deadline = (Get-Date).AddMilliseconds($TimeoutMs)
    $seen = 'no endpoint answered'
    while ((Get-Date) -lt $deadline) {
        $targets = @(Get-CdpTargets -Port $Port)
        if ($targets.Count -gt 0) { $seen = "$($targets.Count) page(s): " + (($targets | ForEach-Object { $_.url }) -join ', ') }
        foreach ($t in $targets) {
            $c = $null
            try {
                $c = Connect-Cdp -WebSocketUrl $t.webSocketDebuggerUrl
                if ((Invoke-CdpEval $c $script:CdpComposerProbe) -eq $true) {
                    # The page is on a window nobody focused (and on a desktop
                    # that has no input): emulate focus, or `focus()` and the
                    # selection it gives the typing below are refused.
                    [void](Invoke-Cdp $c 'Emulation.setFocusEmulationEnabled' @{ enabled = $true })
                    return $c
                }
            } catch {}
            Close-Cdp $c
        }
        Start-Sleep -Milliseconds 250
    }
    throw "CDP: no composer page on port $Port within $TimeoutMs ms ($seen)"
}

# Put the caret in the box, at the end of the document by default.
function Set-CdpComposerFocus {
    param([Parameter(Mandatory = $true)]$Conn, [switch]$KeepCaret)
    $collapse = if ($KeepCaret) { '' } else {
        'var r=document.createRange();r.selectNodeContents(e);r.collapse(false);' +
        'var s=getSelection();s.removeAllRanges();s.addRange(r);'
    }
    $ok = Invoke-CdpEval $Conn ("(function(){var e=document.getElementById('c');e.focus();" +
        $collapse + "return document.activeElement===e;})()")
    if ($ok -ne $true) { throw 'CDP: the composer box would not take focus' }
}

# Type text at the caret, the way an IME commit or a keyboard would: through
# the engine's own editing, so `input` fires and the page reports a snapshot.
function Send-CdpComposerText {
    param([Parameter(Mandatory = $true)]$Conn, [Parameter(Mandatory = $true)][string]$Text, [switch]$KeepCaret)
    Set-CdpComposerFocus -Conn $Conn -KeepCaret:$KeepCaret
    [void](Invoke-Cdp $Conn 'Input.insertText' @{ text = $Text })
}

# key -> (code, virtual-key, text a keyDown inserts). Letters and digits are
# derived; the named keys are the ones an editing test needs.
$script:CdpNamedKeys = @{
    'Enter'      = @('Enter', 13, "`r")
    'Backspace'  = @('Backspace', 8, $null)
    'Delete'     = @('Delete', 46, $null)
    'Escape'     = @('Escape', 27, $null)
    'Tab'        = @('Tab', 9, $null)
    'ArrowLeft'  = @('ArrowLeft', 37, $null)
    'ArrowUp'    = @('ArrowUp', 38, $null)
    'ArrowRight' = @('ArrowRight', 39, $null)
    'ArrowDown'  = @('ArrowDown', 40, $null)
    'Home'       = @('Home', 36, $null)
    'End'        = @('End', 35, $null)
}

# Press and release one key, with modifiers. `-Key` is a DOM key name
# ('Enter', 'Backspace', ...) or a single letter/digit.
function Send-CdpKey {
    param(
        [Parameter(Mandatory = $true)]$Conn,
        [Parameter(Mandatory = $true)][string]$Key,
        [switch]$Ctrl,
        [switch]$Shift,
        [switch]$Alt
    )
    $mods = 0
    if ($Alt) { $mods = $mods -bor 1 }
    if ($Ctrl) { $mods = $mods -bor 2 }
    if ($Shift) { $mods = $mods -bor 8 }

    if ($script:CdpNamedKeys.ContainsKey($Key)) {
        $spec = $script:CdpNamedKeys[$Key]
        $code = $spec[0]; $vk = $spec[1]; $text = $spec[2]
        $keyName = $Key
    } elseif ($Key.Length -eq 1 -and $Key -match '^[A-Za-z0-9]$') {
        $upper = $Key.ToUpperInvariant()
        $vk = [int][char]$upper
        $code = if ($upper -match '[A-Z]') { "Key$upper" } else { "Digit$upper" }
        $keyName = if ($Shift) { $upper } else { $Key.ToLowerInvariant() }
        # A chord inserts nothing; a bare letter does.
        $text = if ($Ctrl -or $Alt) { $null } else { $keyName }
    } else {
        throw "Send-CdpKey: no mapping for key '$Key'"
    }

    $down = @{
        type = if ($null -ne $text) { 'keyDown' } else { 'rawKeyDown' }
        modifiers = $mods; key = $keyName; code = $code
        windowsVirtualKeyCode = $vk; nativeVirtualKeyCode = $vk
    }
    if ($null -ne $text) { $down.text = $text; $down.unmodifiedText = $text }
    [void](Invoke-Cdp $Conn 'Input.dispatchKeyEvent' $down)
    [void](Invoke-Cdp $Conn 'Input.dispatchKeyEvent' @{
        type = 'keyUp'; modifiers = $mods; key = $keyName; code = $code
        windowsVirtualKeyCode = $vk; nativeVirtualKeyCode = $vk
    })
}

# The document as the page serializes it for the host: the same walk as
# composer.js `walk()`, which the page keeps private. NOT `innerText` - that
# counts the trailing placeholder <br> the engine leaves after an Enter as a
# second line break, and reads 'a\n\n' for a document the host holds as 'a\n'.
# Rules, in composer.js's order: text nodes are their data; a <br> is a break
# unless it is the box's last node after a break already (the placeholder); an
# image chip ([data-img]) is its own label and no break; any other element is a
# block that starts on a fresh line.
$script:CdpComposerRead = @'
(function(){var el=document.getElementById('c');var s='';
function num(n,a){if(!n.getAttribute)return 0;var v=parseInt(n.getAttribute(a)||'',10);return v>0?v:0;}
function walk(node){for(var n=node.firstChild;n;n=n.nextSibling){
if(n.nodeType===3){s+=n.data;}
else if(n.nodeName==='BR'){if(!n.nextSibling&&node===el&&s.charAt(s.length-1)==='\n')continue;s+='\n';}
else if(n.nodeType===1&&num(n,'data-img')>0){s+=n.textContent;}
else if(n.nodeType===1){if(s.length&&s.charAt(s.length-1)!=='\n')s+='\n';walk(n);}}}
walk(el);return s;})()
'@

function Get-CdpComposerText {
    param([Parameter(Mandatory = $true)]$Conn)
    return [string](Invoke-CdpEval $Conn $script:CdpComposerRead)
}

# Wait until the box holds exactly `$Expected`, and return what it last held.
function Wait-CdpComposerText {
    param([Parameter(Mandatory = $true)]$Conn, [string]$Expected, [int]$TimeoutMs = 3000)
    $deadline = (Get-Date).AddMilliseconds($TimeoutMs)
    $last = $null
    while ($true) {
        $last = Get-CdpComposerText $Conn
        if ($last -ceq $Expected -or (Get-Date) -ge $deadline) { return $last }
        Start-Sleep -Milliseconds 100
    }
}
