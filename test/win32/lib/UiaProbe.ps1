# What a UI Automation client (Narrator, NVDA, Inspect) sees in one of our
# windows (T2122).
#
# The UIA twin of AccProbe.ps1: asks a window for its UIA element (a real
# WM_GETOBJECT(UiaRootObjectId) answered by the app's provider, merged by
# UIAutomationCore with the HWND host provider, and marshalled across
# processes) and walks it through the RAW view, which is every element the
# providers report - so a part the app forgot to describe is simply absent.
#
# Every call runs on a FRESH STA thread bound to the test desktop by name, the
# same arrangement as AccProbe, so the window and the caller agree about which
# desktop they are on.
#
#   . (Join-Path $PSScriptRoot 'lib\UiaProbe.ps1')
#   $dump = Get-UiaDump -Window $hwnd -Desktop $td
#   Invoke-UiaButton -Window $hwnd -Desktop $td -AutomationId TuckedPaneStrip -Name 'Tucked pane: s2'
#
# Dump shape (one object):
#   Children : @( @{ Name; Help; Type; AutomationId; Class; Invoke; X; Y; W; H } )
#              - the window element's direct children, in raw-view order
#   Error    : $null, or why the probe could not read the window

Set-StrictMode -Version Latest

if (-not ('GhozttyUiaProbe' -as [type])) {
    Add-Type -ReferencedAssemblies UIAutomationClient, UIAutomationTypes, WindowsBase -Language CSharp -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
using System.Text;
using System.Threading;
using System.Windows.Automation;

public static class GhozttyUiaProbe {
    [DllImport("user32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
    static extern IntPtr OpenDesktopW(string name, uint flags, bool inherit, uint access);
    [DllImport("user32.dll", SetLastError = true)]
    static extern bool SetThreadDesktop(IntPtr h);
    [DllImport("user32.dll")]
    static extern bool CloseDesktop(IntPtr h);

    static string Clean(string s) {
        if (s == null) return "";
        return s.Replace("\r", " ").Replace("\n", " ").Replace("|", "/");
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
        if (!t.Join(30000)) return "ERROR timeout";
        return result;
    }

    static string Line(AutomationElement e) {
        var c = e.Current;
        object inv = e.GetCurrentPropertyValue(AutomationElement.IsInvokePatternAvailableProperty);
        var r = c.BoundingRectangle;
        string rect = r.IsEmpty ? "0,0,0,0" :
            String.Format("{0},{1},{2},{3}", (int)r.X, (int)r.Y, (int)r.Width, (int)r.Height);
        return String.Join("|", new string[] {
            "CHILD", Clean(c.Name), Clean(c.HelpText),
            c.ControlType == null ? "" : c.ControlType.ProgrammaticName,
            Clean(c.AutomationId), Clean(c.ClassName),
            (inv is bool && (bool)inv) ? "1" : "0", rect });
    }

    public static string Dump(string desktop, long hwnd) {
        return OnDesktop(desktop, delegate() {
            var root = AutomationElement.FromHandle(new IntPtr(hwnd));
            var sb = new StringBuilder();
            var walker = TreeWalker.RawViewWalker;
            var child = walker.GetFirstChild(root);
            int guard = 0;
            while (child != null && guard++ < 200) {
                sb.AppendLine(Line(child));
                child = walker.GetNextSibling(child);
            }
            return sb.ToString();
        });
    }

    public static string InvokeByName(string desktop, long hwnd, string automationId, string name) {
        return OnDesktop(desktop, delegate() {
            var root = AutomationElement.FromHandle(new IntPtr(hwnd));
            var walker = TreeWalker.RawViewWalker;
            var child = walker.GetFirstChild(root);
            int guard = 0;
            while (child != null && guard++ < 200) {
                var c = child.Current;
                if (c.AutomationId == automationId && c.Name == name) {
                    object p;
                    if (!child.TryGetCurrentPattern(InvokePattern.Pattern, out p)) return "ERROR no Invoke pattern";
                    ((InvokePattern)p).Invoke();
                    return "OK";
                }
                child = walker.GetNextSibling(child);
            }
            return "ERROR not found";
        });
    }
}
'@
}

function Get-UiaDesktopName($Desktop) {
    if ($null -eq $Desktop) { return '' }
    if ($Desktop.Interactive) { return '' }
    return [string]$Desktop.Name
}

function Get-UiaDump {
    param(
        [Parameter(Mandatory = $true)][IntPtr]$Window,
        $Desktop
    )
    $raw = [GhozttyUiaProbe]::Dump((Get-UiaDesktopName $Desktop), [long]$Window)
    if ($null -eq $raw) { $raw = '' }
    if ($raw.StartsWith('ERROR')) {
        return [pscustomobject]@{ Children = @(); Error = $raw }
    }
    $kids = @()
    foreach ($line in ($raw -split "`r?`n")) {
        if (-not $line.StartsWith('CHILD|')) { continue }
        $f = $line -split '\|'
        $r = @($f[7] -split ',' | ForEach-Object { [int]$_ })
        $kids += [pscustomobject]@{
            Name         = $f[1]
            Help         = $f[2]
            Type         = $f[3]
            AutomationId = $f[4]
            Class        = $f[5]
            Invoke       = ($f[6] -eq '1')
            X            = $r[0]
            Y            = $r[1]
            W            = $r[2]
            H            = $r[3]
        }
    }
    return [pscustomobject]@{ Children = $kids; Error = $null }
}

function Invoke-UiaButton {
    param(
        [Parameter(Mandatory = $true)][IntPtr]$Window,
        $Desktop,
        [Parameter(Mandatory = $true)][string]$AutomationId,
        [Parameter(Mandatory = $true)][string]$Name
    )
    return [GhozttyUiaProbe]::InvokeByName((Get-UiaDesktopName $Desktop), [long]$Window, $AutomationId, $Name)
}
