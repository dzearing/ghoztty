<#
.SYNOPSIS
    T1034 analyzer - a hook whose doc comment names its caller must HAVE a
    caller, and a window message with a handler must have a sender.

.DESCRIPTION
    T1031 found `Surface.signalFrameDrawn` documented as "called by the
    renderer thread after SwapBuffers" with no call site anywhere in the tree:
    the synchronous-present wait it fed sat on an event nobody set, expiring
    on its 16 ms timeout, from the day it was written. Nothing was red - it
    compiled, the tests passed, and the feature did not exist. This analyzer
    looks for that CLASS rather than that bug.

    Two shapes:

      no-caller    - a `fn`, field or `const`/`var` under the scanned
                     directories whose `///` doc comment names who calls,
                     sets, signals or posts it ("called by", "invoked from",
                     "set by", "posted by", ...), and whose name appears on
                     no CODE line anywhere under `src\` (or `build.zig`)
                     other than its own declaration. Comments do not count
                     (the doc comment itself is one) and neither do lines in
                     a `test` block: a hook that only a test calls has not
                     got the caller its comment promises either.
      no-handler / - a `WM_APP_*` window message defined under the scanned
      no-sender      directories with no `=>` / `==` handler site, or with a
                     handler and nothing that ever sends it. A sender is any
                     other code reference (a Post/SendMessage, an
                     `attach(hwnd, MSG)`, a `uCallbackMessage = MSG`), or a
                     test script under `test\win32\` that posts it by name.

    Both shapes are one kind of evidence - a NAME with nothing on the other
    end - so the analysis is an identifier census, built once over the whole
    of `src\`, not a search per hit. A name only ever reached through a string
    (`@field(x, "name")`) still counts, because string contents are part of
    the code line.

    Pure text analysis; launches nothing.
#>

$script:UnwiredCallerPhrase = '(?i)\b(called (by|from|on|when|after|before|once|each|every|at)|invoked (by|from|on|when)|calls this|is called|gets called|set by|signall?ed by|written by|fired by|filled (in )?by|posted by|the \w+ thread calls)\b'
$script:UnwiredDeclPattern = '^\s*(?:pub\s+)?(?:export\s+)?(?:inline\s+)?(?:fn\s+([A-Za-z_]\w*)\s*\(|(?:var|const)\s+([A-Za-z_]\w*)\s*[:=]|([A-Za-z_]\w*)\s*:[^=]*[=,])'
$script:UnwiredMsgDefPattern = '^\s*(?:pub\s+)?const\s+(WM_APP_[A-Z0-9_]+)\s*(?::[^=]*)?='

function Get-UnwiredZigFiles([string]$Root) {
    @(Get-ChildItem -LiteralPath $Root -Recurse -File -Filter '*.zig' -ErrorAction SilentlyContinue |
        Where-Object { $_.FullName -notmatch '[\\/]\.zig-cache[\\/]' })
}

# The line scan is C#: it reads every line of ~940 files (560k lines), and a
# PowerShell object per line cost 80+ seconds where this costs a few.
if (-not ('GhozttyUnwiredHookScan' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.IO;
using System.Text.RegularExpressions;

public sealed class GhozttyUnwiredFile {
    public string Rel;
    public string[] Raw;
    public string[] Code;
    public bool[] InTest;
}

public sealed class GhozttyUnwiredDecl {
    public string Kind;    // "hook" or "msg"
    public string Name;
    public string File;
    public int Line;
    public string Phrase;
}

public static class GhozttyUnwiredHookScan {
    static readonly Regex Ident = new Regex(@"[A-Za-z_]\w*", RegexOptions.Compiled);
    static readonly Regex TestStart = new Regex(@"^test\b", RegexOptions.Compiled);

    // The code part of a line: everything before a `//` that is not inside a
    // string literal. Data that names a hook is a reference, so string
    // contents stay.
    public static string CodeOf(string line) {
        int slash = line.IndexOf("//", StringComparison.Ordinal);
        if (slash < 0) return line;
        int quote = line.IndexOf('"');
        if (quote < 0 || quote > slash) return line.Substring(0, slash);
        bool inStr = false;
        for (int i = 0; i < line.Length; i++) {
            char ch = line[i];
            if (inStr) {
                if (ch == '\\') { i++; continue; }
                if (ch == '"') inStr = false;
                continue;
            }
            if (ch == '"') { inStr = true; continue; }
            if (ch == '/' && i + 1 < line.Length && line[i + 1] == '/') return line.Substring(0, i);
        }
        return line;
    }

    // Braces outside string literals, for a `test` block's extent.
    public static int BraceDelta(string code) {
        int d = 0; bool inStr = false;
        for (int i = 0; i < code.Length; i++) {
            char ch = code[i];
            if (inStr) {
                if (ch == '\\') { i++; continue; }
                if (ch == '"') inStr = false;
                continue;
            }
            if (ch == '"') inStr = true;
            else if (ch == '{') d++;
            else if (ch == '}') d--;
        }
        return d;
    }

    public static GhozttyUnwiredFile Read(string path, string rel) {
        string[] raw = File.ReadAllLines(path);
        var f = new GhozttyUnwiredFile { Rel = rel, Raw = raw, Code = new string[raw.Length], InTest = new bool[raw.Length] };
        bool inTest = false; int depth = 0;
        for (int k = 0; k < raw.Length; k++) {
            string code = CodeOf(raw[k]);
            f.Code[k] = code;
            if (!inTest && TestStart.IsMatch(code)) { inTest = true; depth = 0; }
            f.InTest[k] = inTest;
            if (inTest) {
                depth += BraceDelta(code);
                if (depth <= 0 && code.IndexOf('}') >= 0) inTest = false;
            }
        }
        return f;
    }

    // identifier -> every "rel:line" CODE line (outside a test block) naming it.
    public static Dictionary<string, List<string>> Census(IList<GhozttyUnwiredFile> files) {
        var census = new Dictionary<string, List<string>>(StringComparer.Ordinal);
        var seen = new HashSet<string>(StringComparer.Ordinal);
        foreach (var f in files) {
            for (int k = 0; k < f.Code.Length; k++) {
                if (f.InTest[k]) continue;
                string c = f.Code[k];
                if (c.Length == 0) continue;
                seen.Clear();
                foreach (Match m in Ident.Matches(c)) {
                    if (!seen.Add(m.Value)) continue;
                    List<string> l;
                    if (!census.TryGetValue(m.Value, out l)) { l = new List<string>(); census[m.Value] = l; }
                    l.Add(f.Rel + ":" + (k + 1));
                }
            }
        }
        return census;
    }

    // Every declaration in one file that the audit holds to its word: a
    // `///`-documented fn/field/const/var whose comment names who calls, sets
    // or posts it, and every WM_APP_* message definition.
    public static List<GhozttyUnwiredDecl> Declarations(GhozttyUnwiredFile f, string phrasePattern, string declPattern, string msgPattern) {
        var phrase = new Regex(phrasePattern);
        var decl = new Regex(declPattern);
        var msg = new Regex(msgPattern);
        var outList = new List<GhozttyUnwiredDecl>();
        for (int i = 0; i < f.Raw.Length; i++) {
            if (!f.InTest[i]) {
                var mm = msg.Match(f.Code[i]);
                if (mm.Success) outList.Add(new GhozttyUnwiredDecl { Kind = "msg", Name = mm.Groups[1].Value, File = f.Rel, Line = i + 1 });
            }
            if (!f.Raw[i].TrimStart().StartsWith("///", StringComparison.Ordinal)) continue;
            int j = i; var doc = new List<string>();
            while (j < f.Raw.Length && f.Raw[j].TrimStart().StartsWith("///", StringComparison.Ordinal)) {
                doc.Add(f.Raw[j].TrimStart().Substring(3).Trim()); j++;
            }
            i = j - 1;
            if (j >= f.Raw.Length || f.InTest[j]) continue;
            var pm = phrase.Match(string.Join(" ", doc));
            if (!pm.Success) continue;
            var dm = decl.Match(f.Code[j]);
            if (!dm.Success) continue;
            string name = dm.Groups[1].Success ? dm.Groups[1].Value : dm.Groups[2].Success ? dm.Groups[2].Value : dm.Groups[3].Value;
            outList.Add(new GhozttyUnwiredDecl { Kind = "hook", Name = name, File = f.Rel, Line = j + 1, Phrase = pm.Value });
        }
        return outList;
    }
}
'@
}

function Get-UnwiredHookFindings {
    param(
        [Parameter(Mandatory)][string]$Repo,
        [string[]]$ScanRel = @('src\apprt\win32', 'src\remote'),
        [string]$SrcRel = 'src',
        [string]$TestScriptRel = 'test\win32',
        # The audit's own harness names messages as fixtures and as its teeth
        # plant; it is no message's sender.
        [string[]]$ExcludeScripts = @('unwired-hook-audit.ps1')
    )
    $parsed = New-Object 'System.Collections.Generic.List[GhozttyUnwiredFile]'
    foreach ($f in (Get-UnwiredZigFiles (Join-Path $Repo $SrcRel))) {
        $rel = $f.FullName.Substring($Repo.TrimEnd('\').Length + 1)
        $parsed.Add([GhozttyUnwiredHookScan]::Read($f.FullName, $rel))
    }
    $buildZig = Join-Path $Repo 'build.zig'
    if (Test-Path -LiteralPath $buildZig) { $parsed.Add([GhozttyUnwiredHookScan]::Read($buildZig, 'build.zig')) }
    $census = [GhozttyUnwiredHookScan]::Census($parsed)
    $byRel = @{}
    foreach ($p in $parsed) { $byRel[$p.Rel] = $p }

    $scanPrefixes = @($ScanRel | ForEach-Object { $_.TrimEnd('\') + '\' })
    $hooks = New-Object System.Collections.Generic.List[object]
    $msgs = New-Object System.Collections.Generic.List[object]
    $findings = New-Object System.Collections.Generic.List[object]

    foreach ($p in $parsed) {
        $inScan = $false
        foreach ($sp in $scanPrefixes) { if ($p.Rel.StartsWith($sp, [StringComparison]::OrdinalIgnoreCase)) { $inScan = $true; break } }
        if (-not $inScan) { continue }
        foreach ($d in [GhozttyUnwiredHookScan]::Declarations($p, $script:UnwiredCallerPhrase, $script:UnwiredDeclPattern, $script:UnwiredMsgDefPattern)) {
            if ($d.Kind -eq 'msg') { $msgs.Add($d); continue }
            $decl = "$($d.File):$($d.Line)"
            $refs = @()
            if ($census.ContainsKey($d.Name)) { $refs = @($census[$d.Name] | Where-Object { $_ -ne $decl }) }
            $hooks.Add([pscustomobject]@{ Name = $d.Name; File = $d.File; Line = $d.Line; Phrase = $d.Phrase; Refs = $refs.Count })
            if ($refs.Count -eq 0) {
                $findings.Add([pscustomobject]@{
                    Kind = 'no-caller'; File = $d.File; Line = $d.Line; Name = $d.Name
                    Detail = "its doc comment says '$($d.Phrase)' but nothing outside a test references it - wire the caller, or delete it and its comment"
                })
            }
        }
    }

    # Test scripts that post a message are its sender. They post the number
    # (`0x8000 + 38`) with the name beside it, often in a comment, so any
    # mention counts.
    $scriptText = ''
    $tsRoot = Join-Path $Repo $TestScriptRel
    if (Test-Path -LiteralPath $tsRoot) {
        $scriptText = (Get-ChildItem -LiteralPath $tsRoot -Recurse -File -Filter '*.ps1' -ErrorAction SilentlyContinue |
            Where-Object { $ExcludeScripts -notcontains $_.Name } |
            ForEach-Object { [IO.File]::ReadAllText($_.FullName) }) -join "`n"
    }
    foreach ($m in $msgs) {
        $decl = "$($m.File):$($m.Line)"
        $refs = @()
        if ($census.ContainsKey($m.Name)) { $refs = @($census[$m.Name] | Where-Object { $_ -ne $decl }) }
        $handlers = 0; $senders = 0
        foreach ($ref in $refs) {
            $idx = $ref.LastIndexOf(':')
            $rel = $ref.Substring(0, $idx); $ln = [int]$ref.Substring($idx + 1)
            $code = $byRel[$rel].Code[$ln - 1]
            $at = [regex]::Match($code, '(?<![\w])' + $m.Name + '(?![\w])').Index
            $arrow = $code.IndexOf('=>')
            if (($arrow -gt $at) -or $code -match ('==\s*(\w+\.)?' + $m.Name + '(?![\w])')) { $handlers++ }
            else { $senders++ }
        }
        if ($scriptText -match ('(?<![\w])' + $m.Name + '(?![\w])')) { $senders++ }
        if ($handlers -eq 0) {
            $findings.Add([pscustomobject]@{ Kind = 'no-handler'; File = $m.File; Line = $m.Line; Name = $m.Name
                Detail = 'no window procedure handles it - whatever posts it is talking to nobody' })
        } elseif ($senders -eq 0) {
            $findings.Add([pscustomobject]@{ Kind = 'no-sender'; File = $m.File; Line = $m.Line; Name = $m.Name
                Detail = 'it has a handler and nothing sends it - the handler is dead, the way signalFrameDrawn''s event was' })
        }
    }

    return [pscustomobject]@{ Hooks = $hooks; Messages = $msgs; Findings = $findings }
}
