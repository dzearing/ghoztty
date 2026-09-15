# T601 acceptance: a .html file renders as a live page, and live-reloads on save.
#
# What is asserted, in the shape the task's validation criteria ask for:
#
#   - `--view=<file>.html` renders the PAGE: its own stylesheet, script and
#     image are fetched, which a source view never does.
#   - relative assets resolve, including one in a subdirectory.
#   - saving the file re-loads it in place.
#   - `+reload` re-runs it too.
#   - `+list --json` reports the pane exactly as it reports any other viewer
#     mode: type `viewer`, `url` the file's own path (NOT the synthetic origin
#     the engine loaded it from).
#   - a missing .html file gets the pane's own error card, naming the file,
#     rather than the engine's can't-be-reached page.
#   - a page's own assets arrive as what they ARE (T750): a font, a wasm
#     module, a source map, a csv and a webmanifest each get their real type,
#     with the wasm arm proved by the engine actually compiling the module -
#     and a negative control serving the same bytes under an untabled
#     extension, which must be refused.
#   - the read grant is the file's own directory and nothing above it: a page
#     in `docs/` asking for `../app.css` is refused. That is the documented
#     cost of narrow-by-default, and it is asserted so it cannot widen by
#     accident.
#
# ORACLE, and why it is the log. This runs on the background test desktop,
# where CopyFromScreen and SendInput are dead (T233), so nothing out here can
# see a rendered page. The pane states what it did instead:
#
#     viewer html pane=<id> page=<url> root=<dir> fallback=<bool>
#     viewer page pane=<id> served=<rel> bytes=<n>
#
# The first is emitted by `syncHtmlGrant`, the only place the grant is decided.
# The second is emitted by `servePageResource` for every request the PAGE made
# - and a subresource request is proof the bytes were parsed as HTML, because a
# document rendered as source never asks for its own stylesheet. Neither line
# can be produced by any other path.
#
# POSITIVE CONTROL: the same markup opened as `.txt` renders through the
# template in the same run and against the same app, and must produce NEITHER
# line. A green-and-empty run (the T216 lesson) is therefore impossible: the
# control can only pass while the html assertions also pass.
#
# NOT asserted here: that the reload PRESERVES scroll. Nothing outside the
# browser can read a scroll offset on this desktop. What decides it is the
# reload PLAN - `reload_in_place` (a plain reload, which the engine restores
# scroll across) for a save, against `refetch` for an explicit `+reload` - and
# that is asserted in the none lane, in viewer_content's "reloadPlan: the
# branch is the verb's whole contract".
#
# Only touches ghoztty processes running from this repo's zig-out*.
#
#   powershell -NoProfile -File test\win32\viewer-html.ps1
param(
    [string]$ExePath,
    [switch]$Interactive
)

# T351: the shared reset/kill helpers (Stop-RepoGhoztty). Dot-sourced HERE, ahead
# of any isolation setup, because it drops an inherited $GHOZTTY_IPC_SOCKET - a
# test never wants the caller pane's endpoint.
. (Join-Path $PSScriptRoot 'lib\CleanSlate.ps1')
$ErrorActionPreference = 'Continue'
$repo = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$exe = Join-Path $repo 'zig-out\bin\ghoztty.exe'
if (-not (Test-Path $exe)) { $exe = 'D:\git\ghoztty\zig-out\bin\ghoztty.exe' }
if ($ExePath) { $exe = $ExePath }

# Isolate the IPC endpoint (inherited through CreateProcessW).
$env:GHOZTTY_PIPE_SUFFIX = "-htmltest$PID"

. (Join-Path $PSScriptRoot 'lib\TestDesktop.ps1')

$script:pass = 0
$script:fail = 0
$script:skipped = 0

function Assert([bool]$cond, [string]$label) {
    if ($cond) { $script:pass++; Write-Host "PASS  $label" }
    else { $script:fail++; Write-Host "FAIL  $label" -ForegroundColor Red }
}

function Stop-RepoInstances {
    # T351: one shared, path-exact kill (lib\CleanSlate.ps1) instead of a private
    # copy - the filter this replaced also matched a detached instance running from
    # zig-out-release (T53b), and every copy answered "does the agent go too" alone.
    [void](Stop-RepoGhoztty -Exe $exe -AppOnly -SettleMs 500)
}

function Invoke-Verb([string[]]$VerbArgs) {
    $out = (& $exe @VerbArgs 2>&1 | ForEach-Object { $_.ToString() } | Out-String)
    return [pscustomobject]@{ Code = $LASTEXITCODE; Out = $out }
}

function Get-Data {
    $json = (& $exe +list --json 2>$null | Out-String).Trim()
    if (-not $json) { return $null }
    return ($json | ConvertFrom-Json).data
}

function Get-Leaves($node) {
    if ($node.type -eq 'leaf') { return @($node.terminal) }
    return @(Get-Leaves $node.left) + @(Get-Leaves $node.right)
}

function Get-Win($target) {
    $data = Get-Data
    if (-not $data) { return $null }
    foreach ($w in $data.windows) { if ($w.target -eq $target) { return $w } }
    return $null
}

function Wait-Win($target) {
    for ($t = 0; $t -lt 25; $t++) {
        $w = Get-Win $target
        if ($w) { return $w }
        Start-Sleep -Milliseconds 200
    }
    return $null
}

function Get-OnlyPane($target) {
    $w = Get-Win $target
    if (-not $w) { return $null }
    $leaves = @(Get-Leaves $w.tabs[0].splits)
    if ($leaves.Count -ne 1) { return $null }
    return $leaves[0]
}

# Every `served=` line this pane has produced, oldest first. Read from the file
# each time rather than cached: the whole point of the reload arms is that the
# COUNT grows.
function Get-Served($errlog, $paneId) {
    if (-not (Test-Path $errlog) -or -not $paneId) { return @() }
    $out = @()
    foreach ($line in (Get-Content $errlog -ErrorAction SilentlyContinue)) {
        if ($line -match "viewer page pane=$([regex]::Escape($paneId)) served=(\S+) bytes=(\d+)(?: mime=(\S+))?") {
            $out += [pscustomobject]@{ Rel = $Matches[1]; Bytes = [int]$Matches[2]; Mime = $Matches[3] }
        }
    }
    return $out
}

function Wait-Served($errlog, $paneId, [string]$Rel, [int]$AtLeast = 1) {
    for ($t = 0; $t -lt 60; $t++) {
        $n = @(Get-Served $errlog $paneId | Where-Object { $_.Rel -eq $Rel }).Count
        if ($n -ge $AtLeast) { return $n }
        Start-Sleep -Milliseconds 250
    }
    return @(Get-Served $errlog $paneId | Where-Object { $_.Rel -eq $Rel }).Count
}

# The pane's LAST reported html grant. Last, not first: a pane re-derives the
# grant on every navigation it issues.
function Get-HtmlState($errlog, $paneId) {
    if (-not (Test-Path $errlog) -or -not $paneId) { return $null }
    $hit = $null
    foreach ($line in (Get-Content $errlog -ErrorAction SilentlyContinue)) {
        if ($line -match "viewer html pane=$([regex]::Escape($paneId)) page=(\S*) root=(.+) fallback=(true|false)$") {
            $hit = [pscustomobject]@{
                Page     = $Matches[1]
                Root     = $Matches[2].Trim()
                Fallback = ($Matches[3] -eq 'true')
            }
        }
    }
    return $hit
}

function Wait-HtmlState($errlog, $paneId) {
    for ($t = 0; $t -lt 40; $t++) {
        $s = Get-HtmlState $errlog $paneId
        if ($s) { return $s }
        Start-Sleep -Milliseconds 250
    }
    return $null
}

# --- the site under test ---------------------------------------------------
$site = Join-Path $env:TEMP ('ghoztty-t601-site-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
New-Item -ItemType Directory -Path $site | Out-Null
New-Item -ItemType Directory -Path (Join-Path $site 'pics') | Out-Null
New-Item -ItemType Directory -Path (Join-Path $site 'docs') | Out-Null

$indexPath = Join-Path $site 'index.html'
$indexHtml = @'
<!doctype html>
<html><head>
<meta charset="utf-8">
<title>T601 page</title>
<link rel="stylesheet" href="app.css">
</head><body>
<h1 id="hello">T601 marker one</h1>
<img src="pics/dot.png" alt="dot">
<a href="docs/two.html">two</a>
<script src="app.js"></script>
</body></html>
'@
Set-Content -LiteralPath $indexPath -Value $indexHtml -Encoding UTF8
Set-Content -LiteralPath (Join-Path $site 'app.css') -Value 'h1 { color: #b30000; }' -Encoding UTF8
Set-Content -LiteralPath (Join-Path $site 'app.js') -Value 'document.body.dataset.t601 = "ran";' -Encoding UTF8
# A real 1x1 PNG: an <img> whose bytes are not an image is a request the engine
# may abandon, and the request is what is being measured.
[IO.File]::WriteAllBytes(
    (Join-Path $site 'pics\dot.png'),
    [Convert]::FromBase64String('iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg=='))

# A page one directory DOWN, whose stylesheet reference reaches UP out of its
# own folder. Opened directly, its grant is `docs\` and the reach is refused.
$twoPath = Join-Path $site 'docs\two.html'
Set-Content -LiteralPath $twoPath -Value @'
<!doctype html>
<html><head><link rel="stylesheet" href="../app.css"></head>
<body><h1>T601 page two</h1></body></html>
'@ -Encoding UTF8

# The control: the SAME markup, opened as a name the viewer renders through its
# template. It must produce none of the html-mode evidence.
$txtPath = Join-Path $site 'source.txt'
Set-Content -LiteralPath $txtPath -Value $indexHtml -Encoding UTF8

# A `.htm` sibling, because the extension table carries both spellings.
$htmPath = Join-Path $site 'short.htm'
Set-Content -LiteralPath $htmPath -Value '<!doctype html><html><body><h1>T601 htm</h1></body></html>' -Encoding UTF8

$missingPath = Join-Path $site 'gone.html'

# --- T750: the assets a REAL page brings with it ---------------------------
# Its own folder, so section C's re-saves of index.html cannot perturb it.
$mimeDir = Join-Path $site 'mime'
New-Item -ItemType Directory -Path $mimeDir | Out-Null
$mimePath = Join-Path $mimeDir 'page.html'
Set-Content -LiteralPath $mimePath -Encoding UTF8 -Value @'
<!doctype html>
<html><head><meta charset="utf-8"><title>T750</title>
<style>
@font-face { font-family: T750Face; src: url(t750.ttf) format("truetype"); }
h1 { font-family: T750Face, serif; }
</style>
</head><body>
<h1>T750 wants its font</h1>
<script>
// The oracle is a FETCH: this desktop cannot read a rendered page, but every
// page-host request lands in the log. A module that compiled asks for ok.txt;
// one that did not asks for bad.txt, so silence is never mistaken for success.
WebAssembly.instantiateStreaming(fetch("tiny.wasm"))
  .then(function () { fetch("wasm-ok.txt"); },
        function () { fetch("wasm-bad.txt"); });
// NEGATIVE CONTROL: byte-identical module under an extension the table does
// not carry, so it is served application/octet-stream. Chromium refuses to
// compile that, which is precisely what the wasm row above buys.
WebAssembly.instantiateStreaming(fetch("tiny.wasmx"))
  .then(function () { fetch("ctrl-ok.txt"); },
        function () { fetch("ctrl-bad.txt"); });
fetch("data.csv");
fetch("bundle.js.map");
fetch("site.webmanifest");
</script>
</body></html>
'@
# A valid empty WebAssembly module: the 4-byte magic and version 1. Small, and
# `instantiateStreaming` accepts it - so the only thing that can fail the arm
# is the MIME type.
$wasmBytes = [byte[]](0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00)
[IO.File]::WriteAllBytes((Join-Path $mimeDir 'tiny.wasm'), $wasmBytes)
[IO.File]::WriteAllBytes((Join-Path $mimeDir 'tiny.wasmx'), $wasmBytes)
# The font's BYTES are not asserted on - browsers sniff fonts and ignore the
# declared type - so a placeholder is honest here. What is asserted is the type
# the table answers with, which is the part this task moved.
[IO.File]::WriteAllBytes((Join-Path $mimeDir 't750.ttf'), [byte[]](0x00, 0x01, 0x00, 0x00))
Set-Content -LiteralPath (Join-Path $mimeDir 'data.csv') -Value "a,b`n1,2" -Encoding UTF8
Set-Content -LiteralPath (Join-Path $mimeDir 'bundle.js.map') -Value '{"version":3}' -Encoding UTF8
Set-Content -LiteralPath (Join-Path $mimeDir 'site.webmanifest') -Value '{"name":"T750"}' -Encoding UTF8
Set-Content -LiteralPath (Join-Path $mimeDir 'wasm-ok.txt') -Value 'ok' -Encoding UTF8
Set-Content -LiteralPath (Join-Path $mimeDir 'wasm-bad.txt') -Value 'bad' -Encoding UTF8
Set-Content -LiteralPath (Join-Path $mimeDir 'ctrl-ok.txt') -Value 'ok' -Encoding UTF8
Set-Content -LiteralPath (Join-Path $mimeDir 'ctrl-bad.txt') -Value 'bad' -Encoding UTF8

Stop-RepoInstances
Start-TestForegroundWatch
$td = New-TestDesktop -Interactive:$Interactive

try {
    $errlog = Join-Path $env:TEMP 'ghoztty-viewer-html-stderr.log'
    Remove-Item $errlog -ErrorAction SilentlyContinue
    $app = Start-OnTestDesktop -Exe $exe -StdErr $errlog -Arguments @('--session-persistence=false')
    Start-Sleep -Seconds 3
    if ($app.Process -and $app.Process.HasExited) { Write-Host 'SETUP FAIL: GUI died at launch'; exit 1 }
    $appPid = $app.Pid
    if ((Wait-TestWindow -ProcessId $appPid -Class 'GhozttyWindow') -eq [IntPtr]::Zero) {
        Write-Host 'SETUP FAIL: no GhozttyWindow'; exit 1
    }

    # --- A. the page renders, and its own assets resolve ---------------------
    $r = Invoke-Verb @('+new-window', '--target=t601', "--view=$indexPath")
    Assert ($r.Code -eq 0) "+new-window --view=<file>.html exits 0 (got $($r.Code))"
    Assert ($null -ne (Wait-Win 't601')) 'the html viewer window exists'
    $leaf = Get-OnlyPane 't601'
    Assert ($null -ne $leaf) 'the html viewer window has exactly one pane'
    $pane = if ($leaf) { $leaf.id } else { $null }

    $s = Wait-HtmlState $errlog $pane
    Assert ($null -ne $s) 'the pane reported an html grant'
    Assert ($s -and -not $s.Fallback) "the file was readable, so the PAGE is what loaded (fallback=$($s.Fallback))"
    Assert ($s -and $s.Page -eq 'https://ghoztty-page/index.html') `
        "the page loads from the page host (got '$($s.Page)')"
    Assert ($s -and $s.Root -eq $site) `
        "the read grant is the file's own directory (got '$($s.Root)', want '$site')"

    Assert ((Wait-Served $errlog $pane 'index.html') -ge 1) 'the page document itself was served'
    Assert ((Wait-Served $errlog $pane 'app.css') -ge 1) `
        'the page fetched its own stylesheet, so it was parsed as HTML and not shown as source'
    Assert ((Wait-Served $errlog $pane 'app.js') -ge 1) '...and its own script'
    Assert ((Wait-Served $errlog $pane 'pics/dot.png') -ge 1) `
        '...and an image in a subdirectory of the grant'

    # --- B. +list --json reports it like any other viewer --------------------
    Assert ($leaf -and $leaf.type -eq 'viewer') "+list --json calls the pane a viewer (got '$($leaf.type)')"
    Assert ($leaf -and $leaf.url -eq $indexPath) `
        "...and its url is the FILE's path, not the synthetic origin (got '$($leaf.url)')"

    # --- C. saving the file reloads it ---------------------------------------
    $before = @(Get-Served $errlog $pane | Where-Object { $_.Rel -eq 'index.html' }).Count
    $grown = $indexHtml + "<!-- T601 saved again, and this comment makes it longer -->`n"
    Set-Content -LiteralPath $indexPath -Value $grown -Encoding UTF8
    $after = Wait-Served $errlog $pane 'index.html' ($before + 1)
    Assert ($after -gt $before) `
        "saving the file re-loaded the page (served index.html $before time(s), then $after)"
    # The re-load is a real re-read of DISK, not a cache hit dressed up as one:
    # the file grew, so the served length has to grow with it. Without the
    # `Cache-Control: no-store` on page-host responses this is the assertion
    # that goes red.
    $lens = @(Get-Served $errlog $pane | Where-Object { $_.Rel -eq 'index.html' } | ForEach-Object { $_.Bytes })
    Assert ($lens.Count -ge 2 -and $lens[-1] -gt $lens[0]) `
        "...and served the bytes now on disk, not the ones it had (lengths $($lens -join ','))"

    # --- D. +reload re-runs it too -------------------------------------------
    $before = @(Get-Served $errlog $pane | Where-Object { $_.Rel -eq 'index.html' }).Count
    $r = Invoke-Verb @('+reload', '--target=t601')
    Assert ($r.Code -eq 0) "+reload against an html pane exits 0 (got $($r.Code))"
    $after = Wait-Served $errlog $pane 'index.html' ($before + 1)
    Assert ($after -gt $before) "+reload re-fetched the page (served $before time(s), then $after)"

    # --- E. the control: the same markup, rendered through the template ------
    $r = Invoke-Verb @('+new-window', '--target=t601txt', "--view=$txtPath")
    Assert ($r.Code -eq 0) "+new-window --view=<same markup>.txt exits 0 (got $($r.Code))"
    Assert ($null -ne (Wait-Win 't601txt')) 'the control viewer window exists'
    $txtLeaf = Get-OnlyPane 't601txt'
    $txtPane = if ($txtLeaf) { $txtLeaf.id } else { $null }
    Assert ($null -ne $txtPane) 'the control window has exactly one pane'
    # Give it as long as the html pane took to produce its evidence, so this is
    # a measured absence rather than a race won by reading too early.
    Start-Sleep -Seconds 3
    Assert ($null -eq (Get-HtmlState $errlog $txtPane)) `
        'the control pane reported NO html grant (it renders through the template)'
    Assert (@(Get-Served $errlog $txtPane).Count -eq 0) `
        '...and made no page-host request: identical bytes, shown as source'

    # --- F. `.htm` renders too ------------------------------------------------
    $r = Invoke-Verb @('+new-window', '--target=t601htm', "--view=$htmPath")
    Assert ($r.Code -eq 0) "+new-window --view=<file>.htm exits 0 (got $($r.Code))"
    Assert ($null -ne (Wait-Win 't601htm')) 'the .htm viewer window exists'
    $htmLeaf = Get-OnlyPane 't601htm'
    $htmPane = if ($htmLeaf) { $htmLeaf.id } else { $null }
    $s = Wait-HtmlState $errlog $htmPane
    Assert ($s -and $s.Page -eq 'https://ghoztty-page/short.htm') `
        "a .htm file renders as a page too (got '$($s.Page)')"
    Assert ((Wait-Served $errlog $htmPane 'short.htm') -ge 1) '...and its document was served'

    # --- G. the grant is narrow, on purpose ----------------------------------
    # `docs\two.html` opened directly is granted `docs\`, so its `../app.css`
    # resolves to `https://ghoztty-page/app.css` and lands OUTSIDE the grant.
    # Refusing it is the documented cost of narrow-by-default; widening a grant
    # later is easy, taking one back is not.
    $r = Invoke-Verb @('+new-window', '--target=t601sub', "--view=$twoPath")
    Assert ($r.Code -eq 0) "+new-window --view=docs\two.html exits 0 (got $($r.Code))"
    Assert ($null -ne (Wait-Win 't601sub')) 'the subdirectory page window exists'
    $subLeaf = Get-OnlyPane 't601sub'
    $subPane = if ($subLeaf) { $subLeaf.id } else { $null }
    $s = Wait-HtmlState $errlog $subPane
    Assert ($s -and $s.Root -eq (Join-Path $site 'docs')) `
        "the grant is that page's OWN directory (got '$($s.Root)')"
    Assert ((Wait-Served $errlog $subPane 'two.html') -ge 1) 'the subdirectory page itself was served'
    $refused = $false
    for ($t = 0; $t -lt 40; $t++) {
        $txt = (Get-Content $errlog -ErrorAction SilentlyContinue | Out-String)
        if ($txt -match 'viewer page resource not found or outside its grant: app\.css') { $refused = $true; break }
        Start-Sleep -Milliseconds 250
    }
    Assert $refused 'a page reaching UP out of its own folder is refused, not served'
    Assert (@(Get-Served $errlog $subPane | Where-Object { $_.Rel -eq 'app.css' }).Count -eq 0) `
        '...and nothing above the grant was ever handed to it'

    # --- H. a missing file gets the pane's own error card --------------------
    $r = Invoke-Verb @('+new-window', '--target=t601gone', "--view=$missingPath")
    Assert ($r.Code -eq 0) "+new-window --view=<missing>.html exits 0 (got $($r.Code))"
    Assert ($null -ne (Wait-Win 't601gone')) 'the missing-file window exists'
    $goneLeaf = Get-OnlyPane 't601gone'
    $gonePane = if ($goneLeaf) { $goneLeaf.id } else { $null }
    $s = Wait-HtmlState $errlog $gonePane
    Assert ($s -and $s.Fallback) `
        "a missing .html falls back to the template so the pane can explain itself (fallback=$($s.Fallback))"
    $carded = $false
    for ($t = 0; $t -lt 40; $t++) {
        $txt = (Get-Content $errlog -ErrorAction SilentlyContinue | Out-String)
        if ($txt -match ('viewer file error: Cannot read file \(' + [regex]::Escape($missingPath) + '\)')) {
            $carded = $true; break
        }
        Start-Sleep -Milliseconds 250
    }
    Assert $carded 'the error card names the file that could not be read'
    Assert (@(Get-Served $errlog $gonePane).Count -eq 0) `
        '...and no page was served for it'

    # --- J. a real page's assets arrive as what they ARE (T750) --------------
    $r = Invoke-Verb @('+new-window', '--target=t601mime', "--view=$mimePath")
    Assert ($r.Code -eq 0) "+new-window --view=<page with fonts, wasm, a map>.html exits 0 (got $($r.Code))"
    Assert ($null -ne (Wait-Win 't601mime')) 'the mime-table page window exists'
    $mimeLeaf = Get-OnlyPane 't601mime'
    $mimePane = if ($mimeLeaf) { $mimeLeaf.id } else { $null }
    Assert ($null -ne $mimePane) 'the mime-table page window has exactly one pane'

    function Get-ServedMime([string]$Rel) {
        $hit = @(Get-Served $errlog $mimePane | Where-Object { $_.Rel -eq $Rel })
        if ($hit.Count -eq 0) { return $null }
        return $hit[-1].Mime
    }

    [void](Wait-Served $errlog $mimePane 't750.ttf')
    Assert ((Get-ServedMime 't750.ttf') -eq 'font/ttf') `
        "a @font-face .ttf is served font/ttf (got '$(Get-ServedMime 't750.ttf')')"

    [void](Wait-Served $errlog $mimePane 'tiny.wasm')
    Assert ((Get-ServedMime 'tiny.wasm') -eq 'application/wasm') `
        "a .wasm module is served application/wasm (got '$(Get-ServedMime 'tiny.wasm')')"

    [void](Wait-Served $errlog $mimePane 'data.csv')
    Assert ((Get-ServedMime 'data.csv') -eq 'text/csv') `
        "a .csv is served text/csv (got '$(Get-ServedMime 'data.csv')')"
    [void](Wait-Served $errlog $mimePane 'bundle.js.map')
    Assert ((Get-ServedMime 'bundle.js.map') -eq 'application/json') `
        "a source map is served application/json (got '$(Get-ServedMime 'bundle.js.map')')"
    [void](Wait-Served $errlog $mimePane 'site.webmanifest')
    Assert ((Get-ServedMime 'site.webmanifest') -eq 'application/manifest+json') `
        "a .webmanifest is served application/manifest+json (got '$(Get-ServedMime 'site.webmanifest')')"

    # The type is not decoration on the wasm row: the engine's streaming
    # compile REFUSES anything else, so the module either instantiated or it
    # did not, and the page says which by asking for a file.
    [void](Wait-Served $errlog $mimePane 'wasm-ok.txt')
    Assert ((Get-ServedMime 'wasm-ok.txt') -ne $null) `
        'the streaming WebAssembly compile succeeded, which only application/wasm allows'
    Assert (@(Get-Served $errlog $mimePane | Where-Object { $_.Rel -eq 'wasm-bad.txt' }).Count -eq 0) `
        '...and the failure path was never taken'

    # NEGATIVE CONTROL: the same bytes under an extension the table does not
    # carry are served application/octet-stream and MUST fail to compile. A run
    # where both arms pass would mean the type is not being honoured at all,
    # and the arm above would prove nothing.
    [void](Wait-Served $errlog $mimePane 'ctrl-bad.txt')
    Assert (@(Get-Served $errlog $mimePane | Where-Object { $_.Rel -eq 'ctrl-bad.txt' }).Count -ge 1) `
        'the same module under an untabled extension was REFUSED (negative control)'
    Assert ((Get-ServedMime 'tiny.wasmx') -eq 'application/octet-stream') `
        "...because it was served the fallback type (got '$(Get-ServedMime 'tiny.wasmx')')"
    Assert (@(Get-Served $errlog $mimePane | Where-Object { $_.Rel -eq 'ctrl-ok.txt' }).Count -eq 0) `
        '...and the control never reported success'

    # --- I. the app survived all of it ---------------------------------------
    Assert (-not ($app.Process -and $app.Process.HasExited)) 'GUI process alive after all scenarios'
    Assert (-not (Test-TestDesktopLeak -ProcessId $appPid)) 'GUI never became visible on the interactive desktop'
} finally {
    Remove-TestDesktop
    Stop-RepoInstances
    Remove-Item $site -Recurse -Force -ErrorAction SilentlyContinue
}

$fgSeen = @(Stop-TestForegroundWatch)
$leaked = @(Get-TestLaunchedPids | Where-Object { $fgSeen -contains $_ })
Assert ($leaked.Count -eq 0) "no test-desktop app ever became foreground on the interactive desktop (saw $($leaked -join ','))"

Write-Host ''
if ($script:fail -eq 0) {
    Write-Host "ALL PASS ($script:pass assertions$(if ($script:skipped) { ", $script:skipped SKIPPED" }))"
} else {
    Write-Host "$script:fail FAILURE(S) ($script:pass passed$(if ($script:skipped) { ", $script:skipped SKIPPED" }))"
    exit 1
}
