# sprite-testdata acceptance (T820): the sprite-face reference test resolves
# its reference images from the SOURCE ROOT, not from the cwd, and a failing
# run writes its artifacts under zig-out instead of scattering PNGs through
# the source tree.
#
#   powershell -NoProfile -File test\win32\sprite-testdata.ps1
#   powershell -NoProfile -File test\win32\sprite-testdata.ps1 -NegativeControl
#
# Non-interactive and launches no GUI: the subject is `zig build test`. The
# defect this guards is invisible to the floor lane, because the lane always
# runs from the repo root - the one cwd the old relative path happened to work
# from. Run from anywhere else, every reference page failed to open, the test
# failed for a reason that had nothing to do with the code under test, and it
# dropped 36 PNGs into whatever directory the caller was standing in
# (src\apprt\win32\, in the run that filed the task).
#
# Builds are cached, so section A pays for the test binary once and B reuses it.
param(
    [string]$Repo = 'D:\git\ghoztty',

    # Invert one assertion, to prove a green run here is evidence and not a
    # script that asserts nothing (T221's shape).
    [switch]$NegativeControl
)

$ErrorActionPreference = 'Continue'

# T1511: the shared scorer, and the dot-source is also what ARMS the run.
. (Join-Path $PSScriptRoot 'lib\TestScore.ps1')

$script:failures = 0
$script:passes = 0
$script:skipped = 0
$script:negReached = $false
$Repo = (Resolve-Path $Repo).Path
$tmp = Join-Path $env:TEMP "ghoztty-sprite-testdata-$PID"
New-Item -ItemType Directory -Force $tmp | Out-Null

function Assert($name, $cond) {
    if ($cond) { "  PASS $name"; $script:passes++ } else { "  FAIL $name"; $script:failures++ }
}

# One `zig build test` invocation of the sprite tests, run from -From with an
# optional source-root override. Returns the exit code and the combined log;
# every assertion reads the log as well as the code, because a lying exit code
# is exactly the shape these suites exist to catch.
function Invoke-SpriteTest {
    param([string]$Tag, [string]$From, [string]$RootOverride)

    $log = Join-Path $tmp "$Tag.log"
    # The cache MUST be on the repo's drive (T243), and TMP follows it (T1431).
    $cacheDir = (Split-Path $Repo -Qualifier) + '\zig-global-cache'
    $override = if ($RootOverride) {
        'set "GHOSTTY_SPRITE_TESTDATA_ROOT=' + $RootOverride + '" && '
    } else { '' }
    $buildFile = Join-Path $Repo 'build.zig'
    $cmd = "set `"ZIG_GLOBAL_CACHE_DIR=$cacheDir`" && ${override}cd /d `"$From`" && " +
        "zig build --build-file `"$buildFile`" test -Dapp-runtime=win32 -Doptimize=Debug " +
        "-Dtest-filter=sprite > `"$log`" 2>&1"
    & cmd.exe /c $cmd | Out-Null
    $code = $LASTEXITCODE
    $text = if (Test-Path -LiteralPath $log) { (Get-Content -LiteralPath $log -Raw) } else { '' }
    if ($null -eq $text) { $text = '' }
    return [pscustomobject]@{ Exit = $code; Log = $text; Path = $log }
}

# Every PNG the test could have scattered, anywhere in the tracked tree. The
# count is what matters, so `@()` keeps a single match from unrolling to a
# scalar with a null .Count (PS 5.1).
function Get-StrayPngs {
    @(Get-ChildItem -LiteralPath $Repo -Recurse -File -Filter 'sprite_face_*.png' `
        -ErrorAction SilentlyContinue |
        Where-Object { $_.FullName -notlike "$Repo\zig-out*" -and
                       $_.FullName -notlike "$Repo\.zig-cache*" })
}

$strayBefore = @(Get-StrayPngs)
if ($strayBefore.Count -gt 0) {
    "  NOTE $($strayBefore.Count) sprite_face_*.png already in the tree before this run:"
    $strayBefore | Select-Object -First 3 | ForEach-Object { "    $($_.FullName)" }
}

# ============================================================================
"== A: the test passes when run from a directory that is NOT the repo root"
# ============================================================================
# src\apprt\win32 is the cwd the defect was found in, so it is the one used.
$from = Join-Path $Repo 'src\apprt\win32'
$a = Invoke-SpriteTest -Tag 'a-subdir' -From $from

Assert "A1 the run exits 0 from $from" ($a.Exit -eq 0)
Assert "A2 no reference file failed to open" `
    (-not ($a.Log -match "Can't open reference file"))

$strayAfter = @(Get-StrayPngs)
$newStray = @($strayAfter | Where-Object { $strayBefore.FullName -notcontains $_.FullName })
if ($NegativeControl) {
    $script:negReached = $true
    Assert "A3 (INVERTED) the run DID litter the source tree" ($newStray.Count -gt 0)
} else {
    Assert "A3 it wrote no PNGs into the source tree" ($newStray.Count -eq 0)
    if ($newStray.Count -gt 0) {
        $newStray | Select-Object -First 5 | ForEach-Object { "    stray: $($_.FullName)" }
    }
}

# ============================================================================
"== B: a FAILING run puts its artifacts under the root's zig-out, never the cwd"
# ============================================================================
# An override root with no testdata in it makes every page fail to open, which
# is the path that used to copy 36 PNGs into the cwd.
$fakeRoot = Join-Path $tmp 'root'
New-Item -ItemType Directory -Force $fakeRoot | Out-Null
$b = Invoke-SpriteTest -Tag 'b-artifacts' -From $from -RootOverride $fakeRoot

Assert "B1 the run fails, and says which reference file it could not open" `
    (($b.Exit -ne 0) -and ($b.Log -match "Can't open reference file"))
Assert "B2 the missing reference is named by its ABSOLUTE path under the override root" `
    ($b.Log -match [regex]::Escape($fakeRoot))

$artifacts = @(Get-ChildItem -LiteralPath (Join-Path $fakeRoot 'zig-out\sprite-face-test') `
    -File -Filter '*.png' -ErrorAction SilentlyContinue)
Assert "B3 the actual-image PNGs land in <root>\zig-out\sprite-face-test (found $($artifacts.Count))" `
    ($artifacts.Count -gt 0)

$strayAfterB = @(Get-StrayPngs)
$newStrayB = @($strayAfterB | Where-Object { $strayBefore.FullName -notcontains $_.FullName })
Assert "B4 and a failing run still wrote nothing into the source tree" `
    ($newStrayB.Count -eq 0)
if ($newStrayB.Count -gt 0) {
    $newStrayB | Select-Object -First 5 | ForEach-Object { "    stray: $($_.FullName)" }
}

# ============================================================================
"== C: the unit test that holds the resolver is really in the binary"
# ============================================================================
# T733: a filter proves nothing unless the named test was compiled in, and the
# dump is the only place those names exist.
$logC = Join-Path $tmp 'c-names.log'
$cacheDir = (Split-Path $Repo -Qualifier) + '\zig-global-cache'
$cmdC = "set `"ZIG_GLOBAL_CACHE_DIR=$cacheDir`" && set `"GHOZTTY_TEST_FILTER_DUMP=1`" && " +
    "cd /d `"$Repo`" && zig build test -Dapp-runtime=win32 -Doptimize=Debug " +
    "-Dtest-filter=sprite > `"$logC`" 2>&1"
& cmd.exe /c $cmdC | Out-Null
$textC = if (Test-Path -LiteralPath $logC) { (Get-Content -LiteralPath $logC -Raw) } else { '' }
if ($null -eq $textC) { $textC = '' }
Assert "C1 the resolver test is compiled in under this filter" `
    ($textC -match 'test-filter: font\.sprite\.Face\.test\.T820')
Assert "C2 so is the reference test it protects" `
    ($textC -match 'test-filter: font\.sprite\.Face\.test\.sprite face render all sprites')

""
if ($NegativeControl -and -not $script:negReached) {
    Assert "NEGATIVE CONTROL never reached its inverted assertion" $false
}

# --- stamp (T783) -----------------------------------------------------------
Complete-TestBody  # T1039: before the stamp, a child process reads this run's state
if ($script:failures -eq 0 -and $script:skipped -eq 0 -and -not $NegativeControl) {
    & powershell -NoProfile -ExecutionPolicy Bypass `
        -File (Join-Path $PSScriptRoot '..\..\scripts\guard-due.ps1') `
        update -Guard sprite-testdata 2>&1 | ForEach-Object { Write-Host "  $_" }
}

Remove-Item -Recurse -Force $tmp -ErrorAction SilentlyContinue
Write-TestVerdict -Pass $script:passes -Fail $script:failures -Skipped $script:skipped
