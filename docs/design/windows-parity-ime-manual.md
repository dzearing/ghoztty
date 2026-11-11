# The IME checks that need a real input method (T642)

The viewer feedback composer, the terminal surface and every other text field
in the Windows build get IME composition from the OS rather than from code we
wrote. Most of that claim is now proved automatically. This file records the
part that is **not**, why it cannot be, and what to do about it before a
release.

## What the automated suite already proves

The composer is a WebView2 page since T934/T1704 (the RichEdit fallback is
gone), so its IME is Chromium's. `test\win32\viewer-feedback.ps1` section K
drives a real composition through the engine over the DevTools protocol —
`Input.imeSetComposition` with the intermediate reading, then with the
converted string, then `Input.insertText` as the commit — and asserts:

- the composed string lands in the composer,
- ordinary typing continues **at the caret the commit left** (the composition
  ended cleanly and did not leave the caret at its start),
- the pane's mirrored buffer is **byte-exact** for the composed text once the
  composition has ended, compared against the UTF-8 encoding of what the page
  holds. The page reports during a composition too, so the buffer sees
  intermediate text on the way through; what has to be true, and is asserted,
  is that it is right at the end.

The commit arrives by an insertion path, not a keystroke, which is the shape a
keystroke-only test cannot see (T1450). It needs no IME installed. Until T1706
this section posted `WM_IME_*` messages at the RichEdit fallback instead; those
mean nothing to a Chromium window.

## What it cannot prove, and why

Everything an IME renders or reads through the **input context** rather than
through the message:

| Check | Why it needs a real IME |
|---|---|
| The candidate window appears, and over the caret | Drawn by the IME, positioned from the caret rectangle Chromium reports to it; nothing to observe without one |
| The intermediate composition is shown underlined | The engine holds the intermediate string (section K drives it), but its rendering is the IME/Chromium's and is only judged by eye |
| Reconversion, and cancelling a composition with Escape | Driven by the IME through the input context, which the DevTools protocol does not reach |
| The composition following the caret as the pill grows | Needs the IME's own window to observe |

The box this loop runs on has exactly one input method installed
(`en-US`, `0409:00000409`). Adding a Japanese one is a Windows language
feature-on-demand: it needs elevation and a download, and it permanently
changes the user's language bar and their Win+Space toggle on the machine they
work in every day. An acceptance run does not get to make that change, so the
table above is a **manual pre-release check**, not an automated one.

## The manual check

Run once per release, on any Windows box with a Microsoft IME installed
(Settings → Time & language → Language & region → Add a language → Japanese,
with "Basic typing" selected):

1. Open a viewer pane (`ghoztty +new-window --view=<some file>`), open the
   feedback composer, and switch to the Japanese IME (Win+Space).
2. Type `nihongo` and confirm: the candidate window appears **over the caret**,
   the intermediate string is shown underlined **inside the pill**, and the
   pill grows if the composition wraps.
3. Press Space to cycle candidates, Enter to commit. The committed word is in
   the composer, once, with no leftover underline.
4. Start a second composition and press Escape: the composition is cancelled
   and the composer stays **open** — Escape must not be stolen from the IME to
   close the composer.
5. Send with Ctrl+Enter and confirm the report on disk carries the composed
   text unmangled.
6. Repeat steps 2–3 in a terminal pane, which takes a different path
   (`Surface.zig` handles `WM_IME_COMPOSITION` itself rather than letting a
   control do it).

## Recording it, and what asks for it (T1451)

Record every run, pass or fail, against the release line it was run on:

```
powershell -NoProfile -File scripts\manual-check.ps1 record -Check ime -Result pass -Note "<what you saw>"
powershell -NoProfile -File scripts\manual-check.ps1 record -Check ime -Result fail -Note "T<id>: <what broke>"
```

and commit `docs\design\windows-parity-manual-checks.json`. A failure is also a
task, filed the ordinary way; `record` refuses a fail whose note does not name
one.

Until a pass is recorded for the current line (Major.Minor, e.g. `1.37`), the
check is **owed**, and it says so in two places a person reads: the publish log
(`%TEMP%\ghoztty-daily-publish.log`) every time `scripts\daily-publish.ps1` cuts
a release, and `daily-publish.ps1 -Status`, which the morning digest reads. The
line is `MANUAL CHECK OWED: ime ...`. It never holds a release back: this box
cannot run the check, so it is a reminder, not a gate. A new line (the Mac
version moving to the next minor) owes it again. Ask directly with
`scripts\manual-check.ps1 status`.
