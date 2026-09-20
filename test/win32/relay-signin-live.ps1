<#
.SYNOPSIS
  T915 - the SHIPPED Google sign-in configuration, measured against the real
  Google and the real relay.

.DESCRIPTION
  Every other check in this suite proves the sign-in flow works against a FAKE
  relay under a FAKE client id (`test\win32\relay-account.ps1` sets
  GHOSTTY_GOOGLE_CLIENT_ID=cid-e2e). T795 baked a real credential into
  delivered builds and made it observable from `+version`, and then said the
  one thing this seat could not prove:

      "this seat can prove everything except that the credential is the RIGHT
       credential"

  That was true of the account store and the token exchange, which need a
  person to consent in a browser. It was NOT true of the credential itself:
  Google will say whether a client id exists, is live, and accepts the loopback
  redirect this client uses - for free, over one unauthenticated GET, with
  nobody signed in and no token minted. That is section B, and it is the half
  T915 was blocked on.

  What runs with no human present (the default):

    A. the shipped credential - every delivered location reports the SAME baked
       client id from `+version`, and it is a real Google client id
    B. Google ACCEPTS it - the exact authorization URL `authorizationURL`
       builds (src\remote\google_oauth.zig) redirects to Google's sign-in
       page, not to an error
    C. teeth - a never-issued client id gets `invalid_client`, and the real one
       with a non-loopback redirect gets `redirect_uri_mismatch`. Without these
       B is a check that has never been observed saying anything but "fine"
       (go.md: a new gate ships with the demonstration that it can fail)
    D. the baked relay is a live BROKER - the brokered endpoints answer with
       the codes only a configured broker returns, and a nonsense path still
       404s, so C's codes are the endpoints answering rather than a catch-all

  What needs a person, and what this script does about it (section E). Consent
  is the user's Google account; a turn must not click it. So E does not drive a
  browser - it READS BACK the result:

      powershell -NoProfile -File test\win32\relay-signin-live.ps1 -Observe

  run after signing in from the machine chooser's account row, asserts that a
  real account landed (an email, minted at the baked relay base, unexpired) and
  then closes the loop the only way that cannot be faked: it calls the REAL
  relay with that token and requires 200 where an unauthenticated call gets
  401. A green -Observe writes the receipt beside this script, so the
  observation outlives the run that saw it - which is the whole of what T915
  asked for.

  Read-only throughout: nothing is written but that receipt, no token is
  minted, no account is touched, and no consent is ever given by this script.

  Needs the network. Offline, B/C/D SKIP and the run scores what it could
  reach.

  ASCII-only by design (PS 5.1 on this box mangles non-ASCII on rewrite).

  powershell -NoProfile -File test\win32\relay-signin-live.ps1
#>
[CmdletBinding()]
param(
    # Extra binaries to include in section A, beyond the delivered locations
    # this script already knows about.
    [string[]]$Exe = @(),
    # Assert the human half against the REAL account store (run this after
    # signing in from the machine chooser).
    [switch]$Observe,
    # Invert B: prove this script can score the real credential red.
    [switch]$NegativeControl
)

$ErrorActionPreference = 'Continue'

# Isolate the app endpoint even though every CLI call below is `+version`, a
# pure read that opens no pipe: a script that is started from one of the user's
# own panes inherits $GHOZTTY_IPC_SOCKET, and "this one is harmless" is exactly
# the reasoning that put fixture text into the go-loop's live Claude pane
# (lib\Isolation.ps1). Costs nothing, and keeps the static sweep honest.
. (Join-Path $PSScriptRoot 'lib\Isolation.ps1')
Set-GhozttyTestIsolation -Tag 'relaysignin' | Out-Null

. (Join-Path $PSScriptRoot 'lib\TestScore.ps1')

$script:passes = 0
$script:failures = 0
$script:skipped = 0
$script:negReached = $false

function Assert($name, $cond, $detail = '') {
    if ($cond) {
        Write-Host "  PASS $name"
        $script:passes++
    } else {
        Write-Host "  FAIL $name$(if ($detail) { " -- $detail" })"
        $script:failures++
    }
}

$repo = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$receipt = Join-Path $PSScriptRoot 'relay-signin-live.observed.json'

# The authorization endpoint and the redirect STYLE are the product's, read
# from the source that decides them so a change there cannot leave this script
# testing a URL the app no longer builds.
$authEndpoint = 'https://accounts.google.com/o/oauth2/v2/auth'
$oauthSrc = Join-Path $repo 'src\remote\google_oauth.zig'
$dirSrc = Join-Path $repo 'src\remote\relay_directory.zig'

# ---------------------------------------------------------------------------
# Probe helpers
# ---------------------------------------------------------------------------

# GET the authorization endpoint WITHOUT following the redirect, and report
# what Google decided. Invoke-WebRequest -MaximumRedirection 0 throws an
# unrelated "invalid due to the current state of the object" on PS 5.1, so this
# uses HttpWebRequest directly.
function Get-GoogleAuthVerdict {
    param(
        [Parameter(Mandatory = $true)][string]$ClientId,
        [Parameter(Mandatory = $true)][string]$RedirectUri
    )
    $u = $authEndpoint +
        '?client_id=' + [Uri]::EscapeDataString($ClientId) +
        '&redirect_uri=' + [Uri]::EscapeDataString($RedirectUri) +
        '&response_type=code' +
        '&scope=' + [Uri]::EscapeDataString('openid email profile') +
        # A fixed, well-formed S256 challenge (RFC 7636's own example): the
        # value is never redeemed, and a random one would make a failure
        # unreproducible.
        '&code_challenge=E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM' +
        '&code_challenge_method=S256' +
        '&state=t915probe&access_type=offline&prompt=consent'

    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    $req = [Net.HttpWebRequest]::Create($u)
    $req.AllowAutoRedirect = $false
    $req.Timeout = 20000
    $req.UserAgent = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64)'
    $resp = $null
    try { $resp = $req.GetResponse() }
    catch [Net.WebException] { $resp = $_.Exception.Response }
    catch { return [pscustomobject]@{ Reached = $false; Status = 0; Accepted = $false; Error = ''; Detail = $_.Exception.Message } }
    if ($null -eq $resp) { return [pscustomobject]@{ Reached = $false; Status = 0; Accepted = $false; Error = ''; Detail = 'no response' } }

    $loc = [string]$resp.Headers['Location']
    $status = [int]$resp.StatusCode
    try { $resp.Close() } catch { }

    # Google signals the two outcomes in the redirect it hands back:
    #   accepted -> /v3/signin/identifier?...  (the sign-in page)
    #   refused  -> ...?error=<base64url protobuf carrying the reason text>
    $err = ''
    if ($loc -match 'error=([^&]+)') { $err = Convert-GoogleError $Matches[1] }
    $accepted = ($loc -match '/v3/signin/identifier') -and ($err -eq '')

    [pscustomobject]@{
        Reached  = $true
        Status   = $status
        Accepted = $accepted
        Error    = $err
        Detail   = if ($loc.Length -gt 120) { $loc.Substring(0, 120) + '...' } else { $loc }
    }
}

# Google's `error=` parameter is base64url of a small protobuf; the reason text
# is plain ASCII inside it. Pull out the printable run rather than parsing it.
function Convert-GoogleError {
    param([Parameter(Mandatory = $true)][string]$Encoded)
    $t = $Encoded.Replace('-', '+').Replace('_', '/')
    switch ($t.Length % 4) { 2 { $t += '==' } 3 { $t += '=' } }
    try { $bytes = [Convert]::FromBase64String($t) } catch { return "<undecodable: $Encoded>" }
    $chars = foreach ($b in $bytes) { if ($b -ge 32 -and $b -lt 127) { [char]$b } else { ' ' } }
    (-join $chars) -replace '\s+', ' '
}

# One unauthenticated (or Bearer'd) call to the relay; returns the status code,
# or 0 when the host could not be reached at all.
function Get-RelayStatus {
    param(
        [Parameter(Mandatory = $true)][string]$Url,
        [string]$Method = 'GET',
        [string]$Body = '',
        [string]$Bearer = ''
    )
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    $req = [Net.HttpWebRequest]::Create($Url)
    $req.Method = $Method
    $req.Timeout = 20000
    $req.AllowAutoRedirect = $false
    if ($Bearer) { $req.Headers['Authorization'] = "Bearer $Bearer" }
    if ($Method -eq 'POST') {
        $req.ContentType = 'application/json'
        $bytes = [Text.Encoding]::UTF8.GetBytes($Body)
        $req.ContentLength = $bytes.Length
        try {
            $s = $req.GetRequestStream()
            $s.Write($bytes, 0, $bytes.Length)
            $s.Close()
        } catch { return 0 }
    }
    $resp = $null
    try { $resp = $req.GetResponse() }
    catch [Net.WebException] { $resp = $_.Exception.Response }
    catch { return 0 }
    if ($null -eq $resp) { return 0 }
    $code = [int]$resp.StatusCode
    try { $resp.Close() } catch { }
    $code
}

# The `relay sign-in :` line `+version` prints (T795). Returns '' when the
# binary is missing or says nothing, and '<none>' when it says "not configured".
function Get-BakedClientId {
    param([Parameter(Mandatory = $true)][string]$Path)
    if (-not (Test-Path $Path)) { return '' }
    $out = ''
    # Stringify per record BEFORE joining (T883): `2>&1` merges ErrorRecords
    # into the stream, and formatting those goes through the host's width - so
    # `| Out-String` would wrap the 72-character client id and the match below
    # would silently find nothing on a narrow host.
    try { $out = ((& $Path +version 2>&1 | ForEach-Object { "$_" }) -join "`n") } catch { return '' }
    if ($out -match 'relay sign-in\s*:\s*configured\s*\(([^)]+)\)') { return $Matches[1].Trim() }
    if ($out -match 'relay sign-in\s*:\s*not configured') { return '<none>' }
    ''
}

try {
    # --- A. the shipped credential -----------------------------------------
    ''
    '-- A. what the delivered builds actually carry'

    # The locations a user can be running, per go.md's delivery contract. The
    # installed release is the USER'S - read only, never written, never
    # launched.
    $locations = @(
        [pscustomobject]@{ Name = 'repo build (zig-out)'; Path = (Join-Path $repo 'zig-out\bin\ghoztty.exe') },
        [pscustomobject]@{ Name = 'Desktop portable'; Path = 'D:\Users\David\Desktop\Ghoztty-portable-x64\Ghoztty\ghoztty.exe' },
        [pscustomobject]@{ Name = 'installed release'; Path = (Join-Path $env:LOCALAPPDATA 'Programs\Ghoztty\ghoztty.exe') }
    )
    foreach ($extra in $Exe) {
        $locations += [pscustomobject]@{ Name = "extra: $extra"; Path = $extra }
    }

    $baked = @{}
    $present = 0
    foreach ($loc in $locations) {
        if (-not (Test-Path $loc.Path)) {
            Write-Host "  (absent) $($loc.Name): $($loc.Path)"
            continue
        }
        $present++
        $id = Get-BakedClientId -Path $loc.Path
        Write-Host "  $($loc.Name): $(if ($id) { $id } else { '<no relay sign-in line>' })"
        $baked[$loc.Name] = $id
    }

    Assert 'A1 at least one delivered build was found to measure' ($present -gt 0) `
        'no ghoztty.exe at any known location'

    $configured = @($baked.Values | Where-Object { $_ -and $_ -ne '<none>' } | Select-Object -Unique)
    # @(...) around every count: on PS 5.1 a pipeline that matches nothing can
    # answer $null for `.Count`, and `$null -eq 0` is false - which would score
    # the GOOD case as a failure here.
    $unconfigured = @($baked.GetEnumerator() |
        Where-Object { $_.Value -eq '<none>' -or $_.Value -eq '' } |
        ForEach-Object { $_.Key })
    Assert 'A2 every delivered build reports a baked client id' `
        ($unconfigured.Count -eq 0) "unconfigured or silent: $($unconfigured -join ', ')"
    Assert 'A3 they all carry the SAME id (one credential, not a drift per location)' `
        ($configured.Count -eq 1) "distinct ids: $($configured -join ' | ')"

    $liveId = if ($configured.Count -ge 1) { [string]$configured[0] } else { '' }
    Assert 'A4 it has the shape of a real Google client id' `
        ($liveId -match '^\d+-[a-z0-9]+\.apps\.googleusercontent\.com$') "got '$liveId'"

    # The source of the URL under test, so B cannot drift away from the product.
    Assert 'A5 the app still builds its URL against this authorization endpoint' `
        ((Test-Path $oauthSrc) -and ((Get-Content $oauthSrc -Raw) -match [regex]::Escape($authEndpoint))) `
        "not found in $oauthSrc"
    Assert 'A6 the app still uses a loopback redirect (what makes B''s redirect legal)' `
        ((Test-Path $oauthSrc) -and ((Get-Content $oauthSrc -Raw) -match 'http://127\.0\.0\.1')) `
        "no loopback redirect in $oauthSrc"

    # --- B. does Google accept it ------------------------------------------
    ''
    '-- B. the question T915 was blocked on: is it the RIGHT credential'

    $online = $false
    if ($liveId) {
        $v = Get-GoogleAuthVerdict -ClientId $liveId -RedirectUri 'http://127.0.0.1:49152'
        $online = $v.Reached
        if (-not $v.Reached) {
            Write-Host "  SKIP B: Google's authorization endpoint is unreachable ($($v.Detail))"
            $script:skipped++
        } elseif ($NegativeControl) {
            # Invert the real assertion: this MUST fail, which is the proof
            # that a green B means something.
            $script:negReached = $true
            Assert 'B1 NEGATIVE CONTROL: the real credential is refused by Google' `
                (-not $v.Accepted) "Google accepted it (status $($v.Status))"
        } else {
            Assert 'B1 Google redirects the shipped credential to its sign-in page' `
                $v.Accepted "status=$($v.Status) error='$($v.Error)' loc=$($v.Detail)"
            Assert 'B2 and names no error at all' ($v.Error -eq '') $v.Error
            Assert 'B3 the loopback redirect this client uses is accepted too' `
                ($v.Error -notmatch 'redirect_uri_mismatch') $v.Error
        }
    } else {
        Write-Host '  SKIP B: no baked client id to ask about'
        $script:skipped++
    }

    # --- C. teeth ----------------------------------------------------------
    ''
    '-- C. the same check, proved able to say no'

    if (-not $online) {
        Write-Host '  SKIP C: offline (B could not reach Google)'
        $script:skipped++
    } else {
        # A syntactically valid client id that Google has never issued.
        $bogus = '000000000000-zzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzz.apps.googleusercontent.com'
        $cv = Get-GoogleAuthVerdict -ClientId $bogus -RedirectUri 'http://127.0.0.1:49152'
        Assert 'C1 a never-issued client id is NOT accepted' (-not $cv.Accepted) `
            "Google accepted a made-up id: $($cv.Detail)"
        Assert 'C2 and Google says why: invalid_client' ($cv.Error -match 'invalid_client') `
            "reason was '$($cv.Error)'"

        # The real id, asked for a redirect this client is not allowed to use.
        # This is the check that a Web-application client id (wrong type) would
        # trip, which is the plausible way a WRONG credential gets baked in.
        $rv = Get-GoogleAuthVerdict -ClientId $liveId -RedirectUri 'https://not-a-loopback.example.com/cb'
        Assert 'C3 the real id is refused a redirect it does not own' (-not $rv.Accepted) `
            "accepted: $($rv.Detail)"
        Assert 'C4 and Google says why: redirect_uri_mismatch' `
            ($rv.Error -match 'redirect_uri_mismatch') "reason was '$($rv.Error)'"
    }

    # --- D. the baked relay ------------------------------------------------
    ''
    '-- D. the relay the shipped build dials is a live broker'

    $relayBase = ''
    if (Test-Path $dirSrc) {
        $dirText = Get-Content $dirSrc -Raw
        if ($dirText -match 'pub const default_base\s*=\s*"([^"]+)"') { $relayBase = $Matches[1] }
    }
    Assert 'D1 the build has a default relay base to dial' ($relayBase -ne '') `
        "no default_base in $dirSrc"
    Write-Host "  relay base: $relayBase"

    if ($relayBase -eq '') {
        Write-Host '  SKIP D: no relay base to probe'
        $script:skipped++
    } else {
        $reach = Get-RelayStatus -Url "$relayBase/"
        if ($reach -eq 0) {
            Write-Host "  SKIP D: $relayBase is unreachable"
            $script:skipped++
        } else {
            Assert 'D2 the relay answers at all' ($reach -ge 200 -and $reach -lt 500) "status $reach"

            # 400, not 404: the brokered exchange endpoint EXISTS and validated
            # the (empty) body. A relay without brokered sign-in configured has
            # no such route.
            $ex = Get-RelayStatus -Url "$relayBase/oauth/exchange" -Method POST -Body '{}'
            Assert 'D3 POST /oauth/exchange exists and validates its body (400, not 404)' `
                ($ex -eq 400) "status $ex"

            $rn = Get-RelayStatus -Url "$relayBase/oauth/renew" -Method POST -Body '{}'
            Assert 'D4 POST /oauth/renew demands a bearer (401, not 404)' ($rn -eq 401) "status $rn"

            $dv = Get-RelayStatus -Url "$relayBase/v1/client/devices"
            Assert 'D5 GET /v1/client/devices demands a bearer (401, not 404)' ($dv -eq 401) "status $dv"

            # Without this, D3-D5 would pass against a relay that answered
            # every path the same way.
            $none = Get-RelayStatus -Url "$relayBase/v1/client/no-such-route-t915"
            Assert 'D6 a nonsense path still 404s, so D3-D5 are the routes answering' `
                ($none -eq 404) "status $none"
        }
    }

    # --- E. the human half -------------------------------------------------
    ''
    '-- E. the one step a turn must not take: consent'

    Add-Type -AssemblyName System.Security
    # Resolve the store the way the product does (relay_account.accountPath):
    # GHOSTTY_ACCOUNT_STORE first, then %LOCALAPPDATA%\ghoztty\account.dat. The
    # override is what lets E's assertions be EXERCISED against a seeded store
    # without ever writing to the user's real one - otherwise E1-E6 would ship
    # having never run, and the first person to execute them would be the user,
    # after signing in, with no way to tell a harness bug from a product one.
    $storePath = if ($env:GHOSTTY_ACCOUNT_STORE) {
        $env:GHOSTTY_ACCOUNT_STORE
    } else {
        Join-Path $env:LOCALAPPDATA 'ghoztty\account.dat'
    }
    $acct = $null
    if (Test-Path $storePath) {
        try {
            $plain = [Security.Cryptography.ProtectedData]::Unprotect(
                [IO.File]::ReadAllBytes($storePath), $null, 'CurrentUser')
            $acct = [Text.Encoding]::UTF8.GetString($plain) | ConvertFrom-Json
        } catch {
            Write-Host "  account store present but unreadable: $($_.Exception.Message)"
        }
    }

    if (-not $Observe) {
        if ($null -eq $acct) {
            Write-Host '  not signed in on this box (no account.dat), which is the state T915 was filed over.'
        } else {
            Write-Host "  signed in as $($acct.email) at $($acct.relay_base)"
        }
        if (Test-Path $receipt) {
            $r = Get-Content $receipt -Raw | ConvertFrom-Json
            Write-Host "  RECORDED observation: $($r.observed_utc), $($r.relay_base), devices call $($r.devices_status)"
        } else {
            Write-Host '  no recorded observation yet. To make one, from the machine chooser'
            Write-Host '  (ctrl+shift+n) click the account row''s "Sign in with Google...", finish'
            Write-Host '  consent in the browser, then run:'
            Write-Host '      powershell -NoProfile -File test\win32\relay-signin-live.ps1 -Observe'
        }
    } else {
        Assert 'E1 an account store exists (sign in first, then re-run -Observe)' `
            ($null -ne $acct) "no readable store at $storePath"
        if ($null -ne $acct) {
            Assert 'E2 it is the brokered shape, not a pre-T93 legacy store' `
                (($null -ne $acct.session_token) -and ($null -eq $acct.refresh_token)) `
                'legacy store: sign in again to replace it'
            Assert 'E3 it carries the signed-in email' `
                (($null -ne $acct.email) -and ($acct.email -match '@')) "email='$($acct.email)'"
            Assert 'E4 it was minted at the relay the shipped build dials' `
                ($acct.relay_base -eq $relayBase) "stored '$($acct.relay_base)' vs baked '$relayBase'"
            $now = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
            Assert 'E5 the session has not expired' `
                (($null -ne $acct.expiry) -and ([int64]$acct.expiry -gt $now)) `
                "expiry=$($acct.expiry) now=$now"

            # The closing proof, and the only one that cannot be faked by
            # writing a file: the token the browser flow produced is honoured
            # by the REAL relay, on a route that answered 401 in D5.
            if ($acct.session_token -and $relayBase) {
                $auth = Get-RelayStatus -Url "$relayBase/v1/client/devices" -Bearer $acct.session_token
                Assert 'E6 the real relay HONOURS that token where an anonymous call got 401' `
                    ($auth -eq 200) "status $auth"
                # Only a run against the USER'S real store is an observation. A
                # seeded store under GHOSTTY_ACCOUNT_STORE exercises the
                # assertions above and must never mint the receipt that says
                # T915 was seen happening.
                if ($auth -eq 200 -and $script:failures -eq 0 -and -not $env:GHOSTTY_ACCOUNT_STORE) {
                    $rec = [ordered]@{
                        task           = 'T915'
                        observed_utc   = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
                        client_id      = $liveId
                        relay_base     = $relayBase
                        email_domain   = ([string]$acct.email -replace '^[^@]*@', '')
                        devices_status = $auth
                        builds         = ($baked.Keys -join ', ')
                    }
                    ($rec | ConvertTo-Json) | Set-Content -Path $receipt -Encoding ASCII
                    Write-Host "  receipt written: $receipt"
                }
            }
        }
    }

    # A -NegativeControl run that never reached its inverted assertion proves
    # nothing, so say so rather than exiting green.
    if ($NegativeControl -and -not $script:negReached) {
        Assert 'NEGATIVE CONTROL never reached its inverted assertion' $false ''
    }

    Complete-TestBody
}
finally {
}

# A clean green run records the covered files (T783). A run with SKIPPED
# sections left part of the subject unmeasured and does not stamp; neither does
# a -NegativeControl run, which inverted an assertion and is not evidence.
if ($script:failures -eq 0 -and $script:skipped -eq 0 -and -not $NegativeControl) {
    & powershell -NoProfile -ExecutionPolicy Bypass `
        -File (Join-Path $repo 'scripts\guard-due.ps1') `
        update -Guard relay-signin-live -Repo $repo 2>&1 | ForEach-Object { Write-Host "  $_" }
}

''
Write-TestVerdict -Label 'T915 RELAY SIGN-IN (LIVE)' -Pass $script:passes -Fail $script:failures `
    -Skipped $script:skipped
