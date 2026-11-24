#!/usr/bin/env python3
"""copy_reflow_fixture.py <dir>

A stand-in for a TUI that word-wraps its own output (Claude Code, anything on
Ink / wrap-ansi), for test/linux/copy-reflow.sh (T3565). Run as a pane's
program. It waits for <dir>/go (so the pane has its final size), then clears
the screen and writes, from the top-left:

  a prose paragraph behind a "⏺ " gutter, hard-wrapped at the pane's right edge
  with every continuation re-indented two columns - real newlines and real
  spaces, nothing the terminal's own soft wrap recorded;
  a blank row;
  a sentence ending in a URL longer than a whole row, broken mid-token at the
  edge, continuations re-indented two columns;
  a blank row;
  two rows of indented code, which must keep their line break and their
  relative indentation.

Each wrapped row is exactly what a word wrapper at the pane edge would leave,
so the shared copy cleanup (src/terminal/hard_wrap.zig) must rejoin it. Then it
writes <dir>/layout.json (cols, rows, each block's first viewport row and row
count, the prose and the URL as they should come back) and sleeps.
"""
import json
import os
import sys
import time
import textwrap

out = sys.argv[1]
deadline = time.time() + 60
while not os.path.exists(os.path.join(out, "go")):
    if time.time() > deadline:
        sys.exit(1)
    time.sleep(0.05)

cols, rows = os.get_terminal_size(sys.stdout.fileno())

PROSE = (
    "This is a deliberately long paragraph of ordinary prose that a terminal "
    "user interface hard-wrapped at the pane's right edge on its own, so that "
    "a copy out of it has a real example to rejoin, with words that land near "
    "the boundary and a few longer words like internationalization and "
    "responsibilities, and it keeps going for one more clause after that."
)
# Wrapped at the FULL width: a word wrapper moves a word down only when it
# would not have fit, which is exactly the test hard_wrap.boundary applies
# (a narrower wrap would read as a "near miss" and, correctly, never join).
prose_rows = textwrap.wrap(
    PROSE,
    width=cols,
    initial_indent="⏺ ",
    subsequent_indent="  ",
    break_long_words=False,
    break_on_hyphens=False,
)

URL = "https://example.com/ghoztty/copy-reflow/" + "-".join(
    "segment%02d" % i for i in range(max(4, (cols * 3 // 2) // 10))
) + "?q=1#end"
lead = "  A very long URL that must wrap: "
text = lead + URL
url_rows = [text[:cols]]
rest = text[cols:]
while rest:
    url_rows.append("  " + rest[: cols - 2])
    rest = rest[cols - 2 :]

CODE = ["  def answer():", "      return 42"]

# Rows go out with CR LF and never one cell past the edge, so the terminal
# records no soft wrap anywhere: every break below is a real newline.
# Bytes, not text: the pane's locale may not be UTF-8, and the gutter glyph is.
lines = prose_rows + [""] + url_rows + [""] + CODE
sys.stdout.buffer.write(("\x1b[H\x1b[2J" + "\r\n".join(lines)).encode("utf-8"))
sys.stdout.flush()

layout = {
    "cols": cols,
    "rows": rows,
    "prose": {"row": 0, "count": len(prose_rows), "text": PROSE, "last_len": len(prose_rows[-1])},
    "url": {
        "row": len(prose_rows) + 1,
        "count": len(url_rows),
        "url": URL,
        "lead": len(lead),
    },
    "code": {"row": len(prose_rows) + 1 + len(url_rows) + 1, "count": len(CODE)},
}
tmp = os.path.join(out, "layout.json.part")
with open(tmp, "w", encoding="utf-8") as f:
    json.dump(layout, f)
os.rename(tmp, os.path.join(out, "layout.json"))
time.sleep(600)
