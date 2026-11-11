# What a screen reader sees in one of our windows (T1468).
#
# Asks a window for its MSAA client object (AccessibleObjectFromWindow, i.e. a
# real WM_GETOBJECT answered by the app and marshalled across processes) and
# reads it the way Narrator's MSAA proxy does: through the IAccessible vtable,
# never by IDispatch name lookup. That makes it the honest oracle for owner-drawn
# chrome on the background test desktop, where nothing can be heard or seen: a
# part the app forgot to describe is simply absent from the dump.
#
# Every call runs on a FRESH STA thread bound to the test desktop by name, so
# the window and the caller agree about which desktop they are on, and no COM
# object outlives the call that made it.
#
#   . (Join-Path $PSScriptRoot 'lib\AccProbe.ps1')
#   $dump = Get-AccDump -Window $hwnd -Desktop $td      # parsed object
#   Invoke-AccAction -Window $hwnd -Desktop $td -Op doDefault -Child 3
#
# Dump shape (one object):
#   Self     : @{ Name; Role; State; Count }
#   Children : @( @{ Id; Obj; Name; Role; State; Desc; Key; Action; X; Y; W; H } )
#   Focus    : child id (int), 'obj' (a child window's object), or 'none'
#   Selection: same encoding as Focus
#   Error    : $null, or why the probe could not read the window

Set-StrictMode -Version Latest

if (-not ('GhozttyAccProbe' -as [type])) {
    Add-Type -Language CSharp -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
using System.Text;
using System.Threading;

// IAccessible, declared in vtable order. Dual, so the CLR calls the slots after
// IDispatch's four directly - the route every MSAA client takes.
[ComImport, Guid("618736E0-3C3D-11CF-810C-00AA00389B71"),
 InterfaceType(ComInterfaceType.InterfaceIsDual)]
public interface IGhozttyAcc {
    [return: MarshalAs(UnmanagedType.IDispatch)] object get_accParent();
    int get_accChildCount();
    [return: MarshalAs(UnmanagedType.IDispatch)] object get_accChild(object varChild);
    string get_accName(object varChild);
    string get_accValue(object varChild);
    string get_accDescription(object varChild);
    object get_accRole(object varChild);
    object get_accState(object varChild);
    string get_accHelp(object varChild);
    int get_accHelpTopic(out string pszHelpFile, object varChild);
    string get_accKeyboardShortcut(object varChild);
    object get_accFocus();
    object get_accSelection();
    string get_accDefaultAction(object varChild);
    void accSelect(int flagsSelect, object varChild);
    void accLocation(out int pxLeft, out int pyTop, out int pcxWidth, out int pcyHeight, object varChild);
    object accNavigate(int navDir, object varStart);
    object accHitTest(int xLeft, int yTop);
    void accDoDefaultAction(object varChild);
    void put_accName(object varChild, string szName);
    void put_accValue(object varChild, string szValue);
}

public static class GhozttyAccProbe {
    [DllImport("oleacc.dll")]
    static extern int AccessibleObjectFromWindow(IntPtr hwnd, uint id, ref Guid iid,
        [MarshalAs(UnmanagedType.IUnknown)] out object ppv);
    [DllImport("user32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
    static extern IntPtr OpenDesktopW(string name, uint flags, bool inherit, uint access);
    [DllImport("user32.dll", SetLastError = true)]
    static extern bool SetThreadDesktop(IntPtr h);
    [DllImport("user32.dll")]
    static extern bool CloseDesktop(IntPtr h);

    const uint OBJID_CLIENT = 0xFFFFFFFC;
    static Guid IID_IAccessible = new Guid("618736E0-3C3D-11CF-810C-00AA00389B71");

    static string Clean(string s) {
        if (s == null) return "";
        return s.Replace("\r", " ").Replace("\n", " ").Replace("|", "/");
    }

    static string Encode(object v) {
        if (v == null) return "none";
        if (v is int) return ((int)v).ToString();
        return "obj";
    }

    static string OnDesktop(string desktop, Func<string> fn) {
        string result = null;
        var t = new Thread(delegate() {
            IntPtr h = IntPtr.Zero;
            try {
                if (!String.IsNullOrEmpty(desktop)) {
                    h = OpenDesktopW(desktop, 0, false, 0x10000000);
                    if (h == IntPtr.Zero) { result = "ERROR OpenDesktop " + Marshal.GetLastWin32Error(); return; }
                    if (!SetThreadDesktop(h)) { result = "ERROR SetThreadDesktop " + Marshal.GetLastWin32Error(); return; }
                }
                result = fn();
            } catch (Exception e) {
                result = "ERROR " + e.GetType().Name + ": " + Clean(e.Message);
            } finally {
                if (h != IntPtr.Zero) CloseDesktop(h);
            }
        });
        t.SetApartmentState(ApartmentState.STA);
        t.IsBackground = true;
        t.Start();
        if (!t.Join(20000)) return "ERROR timeout";
        return result;
    }

    static IGhozttyAcc Open(long hwnd) {
        object o;
        int hr = AccessibleObjectFromWindow(new IntPtr(hwnd), OBJID_CLIENT, ref IID_IAccessible, out o);
        if (hr != 0) throw new COMException("AccessibleObjectFromWindow", hr);
        return (IGhozttyAcc)o;
    }

    static string Try(Func<string> f) {
        try { return Clean(f()); } catch (Exception e) { return "!" + e.HResult.ToString("X8"); }
    }

    // The whole tree one level down, one line per element.
    public static string Dump(string desktop, long hwnd) {
        return OnDesktop(desktop, delegate() {
            var acc = Open(hwnd);
            var sb = new StringBuilder();
            int n = acc.get_accChildCount();
            sb.AppendFormat("self|{0}|{1}|{2}|{3}\n",
                Try(() => acc.get_accName(0)),
                Try(() => Convert.ToString(acc.get_accRole(0))),
                Try(() => Convert.ToString(acc.get_accState(0))),
                n);
            for (int id = 1; id <= n; id++) {
                object child = null;
                try { child = acc.get_accChild(id); } catch (COMException) { }
                if (child != null) {
                    sb.AppendFormat("child|{0}|1|||||||||\n", id);
                    Marshal.ReleaseComObject(child);
                    continue;
                }
                int x = 0, y = 0, w = 0, h = 0;
                string loc = "ok";
                try { acc.accLocation(out x, out y, out w, out h, id); }
                catch (COMException e) { loc = "!" + e.ErrorCode.ToString("X8"); }
                int cid = id;
                sb.AppendFormat("child|{0}|0|{1}|{2}|{3}|{4}|{5}|{6}|{7},{8},{9},{10}|{11}\n",
                    id,
                    Try(() => acc.get_accName(cid)),
                    Try(() => Convert.ToString(acc.get_accRole(cid))),
                    Try(() => Convert.ToString(acc.get_accState(cid))),
                    Try(() => acc.get_accDescription(cid)),
                    Try(() => acc.get_accKeyboardShortcut(cid)),
                    Try(() => acc.get_accDefaultAction(cid)),
                    x, y, w, h, loc);
            }
            sb.AppendFormat("focus|{0}\n", Try(() => Encode(acc.get_accFocus())));
            sb.AppendFormat("selection|{0}\n", Try(() => Encode(acc.get_accSelection())));
            Marshal.ReleaseComObject(acc);
            return sb.ToString();
        });
    }

    // One call: doDefault <id> | select <flags> <id> | hitTest <x> <y> |
    // name <id> | focus.
    public static string Do(string desktop, long hwnd, string op, int a, int b) {
        return OnDesktop(desktop, delegate() {
            var acc = Open(hwnd);
            try {
                switch (op) {
                    case "doDefault": acc.accDoDefaultAction(a); return "ok";
                    case "select": acc.accSelect(a, b); return "ok";
                    case "hitTest": return Encode(acc.accHitTest(a, b));
                    case "name": return Try(() => acc.get_accName(a));
                    case "focus": return Encode(acc.get_accFocus());
                    case "navigate": return Encode(acc.accNavigate(a, b));
                    default: return "ERROR unknown op " + op;
                }
            } catch (Exception e) {
                return "!" + e.HResult.ToString("X8");
            } finally {
                Marshal.ReleaseComObject(acc);
            }
        });
    }
}
'@
}

function Get-AccDesktopName($Desktop) {
    if ($null -eq $Desktop) { return '' }
    if ($Desktop.Interactive) { return '' }
    return [string]$Desktop.Name
}

function Get-AccDump {
    param(
        [Parameter(Mandatory = $true)][IntPtr]$Window,
        $Desktop
    )
    $raw = [GhozttyAccProbe]::Dump((Get-AccDesktopName $Desktop), [long]$Window)
    $out = [pscustomobject]@{
        Self      = $null
        Children  = @()
        Focus     = $null
        Selection = $null
        Error     = $null
        Raw       = $raw
    }
    if ($null -eq $raw -or $raw.StartsWith('ERROR')) {
        $out.Error = if ($null -eq $raw) { 'no answer' } else { $raw }
        return $out
    }
    $kids = New-Object System.Collections.ArrayList
    foreach ($line in ($raw -split "`n")) {
        if (-not $line) { continue }
        $f = $line -split '\|'
        switch ($f[0]) {
            'self' {
                $out.Self = [pscustomobject]@{
                    Name = $f[1]; Role = $f[2]; State = $f[3]; Count = [int]$f[4]
                }
            }
            'child' {
                $x = 0; $y = 0; $w = 0; $h = 0
                if ($f.Count -gt 9 -and $f[9] -match '^(-?\d+),(-?\d+),(-?\d+),(-?\d+)$') {
                    $x = [int]$Matches[1]; $y = [int]$Matches[2]; $w = [int]$Matches[3]; $h = [int]$Matches[4]
                }
                [void]$kids.Add([pscustomobject]@{
                    Id     = [int]$f[1]
                    Obj    = ($f[2] -eq '1')
                    Name   = $f[3]
                    Role   = $f[4]
                    State  = $f[5]
                    Desc   = $f[6]
                    Key    = $f[7]
                    Action = $f[8]
                    X = $x; Y = $y; W = $w; H = $h
                })
            }
            'focus' { $out.Focus = $f[1] }
            'selection' { $out.Selection = $f[1] }
        }
    }
    $out.Children = @($kids.ToArray())
    return $out
}

function Invoke-AccAction {
    param(
        [Parameter(Mandatory = $true)][IntPtr]$Window,
        $Desktop,
        [Parameter(Mandatory = $true)][string]$Op,
        [int]$A = 0,
        [int]$B = 0
    )
    return [GhozttyAccProbe]::Do((Get-AccDesktopName $Desktop), [long]$Window, $Op, $A, $B)
}

# The child with id $Id from a dump, or $null.
function Get-AccChild($Dump, [int]$Id) {
    if ($null -eq $Dump) { return $null }
    foreach ($c in @($Dump.Children)) { if ($c.Id -eq $Id) { return $c } }
    return $null
}

# Whether MSAA state bit $Bit is set in a state string from a dump.
function Test-AccState([string]$State, [int]$Bit) {
    $n = 0
    if (-not [int]::TryParse($State, [ref]$n)) { return $false }
    return (($n -band $Bit) -ne 0)
}
