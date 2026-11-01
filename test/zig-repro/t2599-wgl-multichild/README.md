# T2599: a second plain WGL child leaks top-level-sized GPU memory

A standalone Win32 + WGL program with no Ghoztty code in it. It shows that the
GPU memory plain terminal panes strand (T2499, T2599) comes from the OpenGL
driver, not from Ghoztty. It also checks the fix before anyone builds it:
**one GL child window per top-level, with any number of contexts presenting
into it, does not leak.**

```
powershell -NoProfile -File test\zig-repro\t2599-wgl-multichild\run.ps1 [-Scenarios two-live,shared] [-Reps 3]
```

`run.ps1` builds `repro.exe` into `temp\t2599-wgl-multichild\`, runs every
scenario on the test desktop (never the user's), and drives each step with a
synchronous `SendMessage(WM_APP, cmd, arg)` to the top-level. After every step
it reads the process's `GPU Process Memory\Dedicated Usage`. The command table
is at the top of `repro.zig`. The top-level is 1000x700 and the children are
250 px columns that never overlap.

## Result (2026-11-01, RTX 4090, WGL, 1000x700 top-level)

| Scenario | What it is | Setup MB | per hide/show | per min/restore |
|---|---|---|---|---|
| `one` | one GL child | 12.57 | 0 | 0 |
| `shared` | one GL child, two contexts presenting into it | 12.57 | 0 | 0 |
| `two-live` | two GL children, both alive | 17.94 | **+3.0** | **+3.0** |
| `live-0swap` | same, nothing presents after the show | 17.94 | **+3.0** | **+3.0** |
| `live-1swap` | same, only child 0 presents after the show | 17.94 | **+3.0** | **+3.0** |
| `two` | second child destroyed before the cycles | 15.57 | 0 | 0 |
| `churn` | add and destroy a second child 3x | 21.57 | 0 | 0 |
| `park` | second child hidden, not destroyed | 17.94 | +1.0 (+3 on the first show only) | 0 |
| `noswap2` | second child has a context but never swaps | 12.57 | 0 | 0 |
| `gdi2` | second child is GDI, not GL | 12.57 | 0 | 0 |

What it shows:

- **Each top-level redirection surface leaks while two GL children have
  presented.** Each show or restore costs +3.0 MB (about 1000x700x4), and that
  memory is never freed. The children do not have to present again for it to
  happen.
- **Destroying a second child that has presented strands 3 MB once.**
  `churn` climbs 15.57, then 18.57, then 21.57, one step per destroyed child.
  This is T2499's per-pane leak, and it is what T2597's pane pool works around.
- **A child only counts once it has swapped.** A context that never swaps
  (`noswap2`) costs nothing, and neither does a GDI child (`gdi2`).
- **The fix holds at the driver level.** One child window with two contexts
  scissoring into it and swapping once (`shared`) is flat across every cycle.

The app behaves the same way. Ghoztty's per-step probe (split, close, then
hide/show, with `GHOZTTY_PANE_LAYER=0`) gives:

- **Pane pool off** (`GHOZTTY_PANE_REUSE=0`): show is flat, and each
  split+close strands 3 MB (54.4, 57.4, 60.4, 63.4). This matches `churn`.
- **Pane pool on** (the T2597 default): closing is flat, but every show costs
  +3 MB. The parked pane window is still a second presenter, which matches
  `two-live`.

Either way, one of the two leaks is left. Only a single presenter per
top-level (T2610) avoids both.
