#!/usr/bin/env python3
"""Write a byte stream shaped like Claude Code's terminal output, for the reboot E2E.

    python3 tui-stream.py --mode=inline     --tag=A --out=/tmp/a.bin
    python3 tui-stream.py --mode=fullscreen --tag=B --out=/tmp/b.bin

A pane `cat`s the file (in raw mode, so `\\n` is not translated) and then idles.
Every pane the user restores after a reboot is running Claude Code, and a plain
`echo` loop does not exercise any of what made those restores break — so this
reproduces the parts that matter, measured from the user's own ring snapshots:

  - Synchronized-output frames (`?2026h` … `?2026l`) redrawn IN PLACE with
    relative cursor motion: thousands of them, so the raw stream is far bigger
    than what is on screen (2 MB of real Claude Code is ~700 frames).
  - Queries the terminal answers into the pty: DA1 (`CSI c`), DECRQM
    (`CSI ? 2026 $ p`), XTVERSION (`CSI > 0 q`), the kitty keyboard query
    (`CSI ? u`).
  - Keyboard-encoding state: kitty keyboard pushes/pops (`CSI > 1 u`) and
    modifyOtherKeys (`CSI > 4 ; 2 m`), focus reporting, bracketed paste.
  - 24-bit color on every character of the status line.

`inline` is Claude Code's default renderer: the conversation scrolls up on the
PRIMARY screen and only a bottom region (prompt box + status) is redrawn.
Conversation lines are `CONVO-<tag>-<n>`, printed once each, so the E2E can
assert the restored scrollback holds every one of them, once, in order — even
though the stream is several times larger than the agent's 2 MB ring.

`fullscreen` is the alternate-screen renderer: `BEFORE-TUI-<tag>` on the primary
screen, then `?1049h` + any-event mouse tracking, then absolute-positioned
frames. Enough of them that the `?1049h` falls out of a 2 MB ring window — the
case the raw-ring replay could never get right.

The last thing on screen is always `FINAL-<tag>` (inline: in the prompt box;
fullscreen: in the final frame), and the stream ends with the terminal in
exactly the state the real program leaves it: modes on, frame complete.
"""

import argparse

ESC = "\x1b"


def rgb(i, j):
    return f"{ESC}[38;2;{(i * 7 + j * 3) % 256};{(i * 13 + j) % 256};{(200 + j) % 256}m"


def status_line(i, width):
    text = f"ctx: {i % 997}k/1000k | files: clean | v2.1.999 (spinner {i})"
    colored = "".join(rgb(i, j) + ch for j, ch in enumerate(text))
    return colored + f"{ESC}[39m" + f"{ESC}[K"


def queries():
    # What the real program asks between frames; the terminal answers each one
    # by WRITING to the pty.
    return f"{ESC}[c{ESC}[?2026$p{ESC}[>0q{ESC}[?u"


def inline(tag, convo_lines, frames_per_line, width):
    out = []
    # The program starting up: keyboard + reporting modes, as Claude Code does.
    out.append(f"{ESC}[?2004h{ESC}[?1004h{ESC}[>1u{ESC}[>4;2m{ESC}[?25l")
    # The dynamic region: 3 rows (rule, prompt box, status) below the conversation.
    out.append("─" * min(width, 80) + "\r\n> \r\n" + status_line(0, width) + "\r\n")
    i = 0
    for n in range(convo_lines):
        for _ in range(frames_per_line):
            i += 1
            # Redraw the dynamic region in place: up 3, rewrite 3 rows.
            out.append(
                f"{ESC}[?2026h\r{ESC}[3A"
                + f"{ESC}[2K" + "─" * min(width, 80) + "\r\n"
                + f"{ESC}[2K> thinking{'.' * (i % 4)}\r\n"
                + f"{ESC}[2K" + status_line(i, width) + "\r\n"
                + f"{ESC}[?2026l"
            )
            if i % 7 == 0:
                out.append(queries())
            if i % 50 == 0:
                out.append(f"{ESC}[<u{ESC}[>1u")
        # A conversation line lands ABOVE the dynamic region: erase the region,
        # print the line, redraw the region below it.
        out.append(
            f"{ESC}[?2026h\r{ESC}[3A{ESC}[J"
            + f"{ESC}[1mCONVO-{tag}-{n:04d}{ESC}[0m the assistant said something useful here\r\n"
            + "─" * min(width, 80) + "\r\n> \r\n" + status_line(i, width) + "\r\n"
            + f"{ESC}[?2026l"
        )
    # Final frame: the prompt box holds the FINAL marker.
    out.append(
        f"{ESC}[?2026h\r{ESC}[3A"
        + f"{ESC}[2K" + "─" * min(width, 80) + "\r\n"
        + f"{ESC}[2K> FINAL-{tag}\r\n"
        + f"{ESC}[2K" + status_line(i + 1, width) + "\r\n"
        + f"{ESC}[?25h{ESC}[?2026l"
    )
    return "".join(out)


def fullscreen(tag, frames, rows, cols):
    out = [f"BEFORE-TUI-{tag} $ claude\r\n"]
    out.append(f"{ESC}[?1049h{ESC}[2J{ESC}[H")
    out.append(f"{ESC}[?1000h{ESC}[?1002h{ESC}[?1003h{ESC}[?1006h{ESC}[?2004h{ESC}[?1004h")
    out.append(f"{ESC}[>1u{ESC}[>4;2m")
    for i in range(frames):
        out.append(f"{ESC}[?2026h{ESC}[H")
        for r in range(1, rows - 1):
            out.append(f"{ESC}[{r};1H{ESC}[2Kframe {i} row {r} " + "·" * 20)
        out.append(f"{ESC}[{rows};1H{ESC}[2K" + status_line(i, cols))
        out.append(f"{ESC}[{rows - 1};3H{ESC}[?25h{ESC}[?2026l")
        if i % 5 == 0:
            out.append(queries())
    out.append(f"{ESC}[?2026h{ESC}[H{ESC}[2J")
    out.append(f"{ESC}[1;1HFINAL-{tag} last frame of the full-screen app")
    out.append(f"{ESC}[{rows};1H" + status_line(frames, cols))
    out.append(f"{ESC}[{rows - 1};3H{ESC}[?2026l")
    return "".join(out)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--mode", choices=("inline", "fullscreen"), required=True)
    ap.add_argument("--tag", required=True)
    ap.add_argument("--out", required=True)
    # Sized so the stream overruns the agent's 2 MB ring several times over.
    ap.add_argument("--convo", type=int, default=120)
    ap.add_argument("--frames-per-line", type=int, default=40)
    ap.add_argument("--frames", type=int, default=2500)
    ap.add_argument("--rows", type=int, default=24)
    ap.add_argument("--cols", type=int, default=80)
    a = ap.parse_args()
    data = (inline(a.tag, a.convo, a.frames_per_line, a.cols) if a.mode == "inline"
            else fullscreen(a.tag, a.frames, a.rows, a.cols))
    with open(a.out, "wb") as f:
        f.write(data.encode())


if __name__ == "__main__":
    main()
