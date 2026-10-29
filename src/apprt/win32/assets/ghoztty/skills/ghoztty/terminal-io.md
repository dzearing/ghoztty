# Reading, typing into and tracking panes

Read from the `ghoztty` skill for `+read`, the details of `+send-keys`, and `+set-state`.

## `ghoztty +read`

Read the last N lines of terminal output from a named pane and print to stdout. Useful for inspecting command output, logs, or checking if a process has finished.

```
ghoztty +read --name=<pane> [--lines=<N>]
```

| Flag | Description |
|------|-------------|
| `--name=<pane>` | Named pane to read from. Required. |
| `--lines=<N>` | Number of lines from the end of scrollback (default: 50). |

## `ghoztty +send-keys`

Send text and key sequences to a named pane's terminal PTY. Enables scripted interaction with running processes.

```
ghoztty +send-keys --target=<name> [flags] <text|key>...
```

> **To submit, end the text with `\n`** — `ghoztty +send-keys --target=t "prompt\n"`.
> (`--enter`, or a separate `Enter` argument, do the same thing. Use one, not
> two — they stack, and two of them submit twice.)

| Flag / Arg | Description |
|------------|-------------|
| `--target=<name>` | Named pane or window to send input to. Required. |
| `--enter` | Press Enter after the text, submitting it. Same as a trailing `\n` or a trailing `Enter` argument. On its own, with no text, it just presses Enter. |
| `--when-idle` | Poll the target's recent output every 500ms until it looks idle before sending: the tail unchanged across ~1s (a working TUI animates a spinner or a timer; an idle prompt is static, so this catches any program without naming its chrome) AND none of the caller's `--busy-marker` texts present. Sends anyway once the timeout elapses, or if the pane can't be read. |
| `--idle-timeout=<seconds>` | How long `--when-idle` waits before sending regardless. Default 30. |
| `--busy-marker=<text>` | Extra busy signal for `--when-idle`: while `<text>` is in the pane's last lines, the pane counts as busy even if its tail is static. Repeatable; any match counts. |
| `--keys-file=<path>` | Send the file's bytes **verbatim** — no key notation, no `\n` escape processing, and no trailing-newline peel. It keeps its position among the positional arguments, so `--keys-file=p.txt Enter` sends the file and then presses Enter. |
| `--` | Stop flag parsing. Everything after it is a positional, so this is how you send literal text starting with `--`. Key notation still applies. |
| Positional args | Text strings and key names, written to the PTY in order. |

**Key notation:**
- Control keys: `C-c` (Ctrl-C), `C-d` (Ctrl-D), `C-z` (Ctrl-Z), etc.
- Named keys: `Enter`, `Tab`, `Escape`, `Space`, `Backspace`
- Escape sequences in text: `\n`, `\t`, `\r`, `\\`, `\e`

```bash
ghoztty +send-keys --target=term "hello\tworld\n"   # types, then submits
ghoztty +send-keys --target=term "ls -la" Enter
ghoztty +send-keys --target=agent --when-idle --enter "next task"
ghoztty +send-keys --target=term C-c
ghoztty +send-keys --target=term -- "--not-a-flag" Enter
ghoztty +send-keys --target=agent --keys-file=prompt.txt Enter
```

**Text you did not author by hand goes through `--keys-file=`.** A generated
prompt, a path, anything carrying quotes or backslashes: put it in a file and
send the file. A positional argument is re-tokenized by whatever shell builds
the command line — PowerShell 5.1 does not escape an embedded `"` at all — so
such text arrives with its quotes stripped, its words concatenated, or broken
outright. Length is not the hazard; punctuation is.

**A trailing newline is a keypress; an interior one is content.** The trailing
run of `\n`/`\r` is peeled off the text and sent as that many Enter presses, so
`"a\nb\n"` pastes two lines and then submits. The peel happens after escape
processing, so `\n` written as the two-character escape and a real newline byte
behave the same. The accepted cost: text ending in a literal newline can't be
pasted without submitting — which is why `--keys-file=` is exempt from the
peel: a file the caller generated ends in a newline because files do, not
because it meant to submit. Pass a separate `Enter` (or `--enter`) to submit
one.

**Any unknown `--flag` is a hard error** (exit 1) naming the submit spellings —
`--press-enter` used to be typed into the pane at exit 0, silently. Single-dash
arguments (`-la`, `-p`) stay ordinary text.

**Why the boundary matters.** Argument boundaries survive to the write:
adjacent args of the same kind merge into a run, each **text** run is sent as a
bracketed paste, and each **key** run is sent bare outside the frame. That is
what makes a message actually submit. Flattened into one burst ending in `\r`,
a TUI reads that `\r` as a newline *inside* pasted text — correctly, since that
is what a real multi-line paste looks like — and the message sits unsent in the
composer. Framing only applies when the program has enabled bracketed paste
(every modern TUI and interactive shell does), so a plain `cat` or a script's
`read` still gets the bytes verbatim.

## `ghoztty +set-state`

Set the activity state of a named window or pane. State is aggregated across all panes in a window (priority: `needs_input` > `busy` > `idle`) and shown as a title suffix and custom `AXWindowActivityState` accessibility attribute. Transition to `needs_input` triggers `requestUserAttention`.

```
ghoztty +set-state --target=<name> --state=<idle|busy|needs_input>
```

| Flag | Description |
|------|-------------|
| `--target=<name>` | Named window or pane. Required. |
| `--state=<state>` | Activity state: `idle`, `busy`, or `needs_input`. Required. |

Processes can also set state via OSC escape sequence: `\033]7777;<state>\007`

```bash
ghoztty +set-state --target=dev --state=busy
ghoztty +set-state --target=dev --state=needs_input
ghoztty +set-state --target=dev --state=idle
```

**Don't set the state of your own pane.** Ghoztty's installed hooks already own
it, under the same `needs_input` > `busy` > `idle` ordering — including keeping
the pane `busy` while background subagents outlive the main loop. A manual call
either duplicates what the hooks just did or fights them. Use `+set-state` for
*other* panes: a build, a dev server, a long-running job you launched.

The hooks track each live subagent with a marker file under
`/tmp/ghoztty-<runtime>-agents-<session_id>/`, so the pane stays `busy` until
the last one finishes rather than going `idle` the moment the main loop goes
quiet. Markers are recovered two ways when a kill skips `SubagentStop`: the
owning agent's pid is baked into each filename (so a dead session's markers are
dropped exactly and instantly), and an agent that emits no tool call for longer
than `GHOZTTY_AGENT_STALE_MIN` minutes (default `30`) is presumed dead. That
window must exceed the longest single *tool call*, not the longest agent — a
40-minute build emits nothing between its start and its end.

This is wired for **Claude Code**. Copilot CLI gets the banner hooks but not yet
the full state machine (see the note in `CopilotHookSpec`), so a Copilot pane
still reports `idle` at the end of a turn even with background work in flight.

## Read output from a pane

```bash
# Check what a running process has printed
ghoztty +read --name=term --lines=10

# Capture output for processing
output=$(ghoztty +read --name=build --lines=100)
echo "$output" | grep "error"
```

## Send commands to a running pane

**To submit, end the text with `\n`.** (`--enter`, or a separate `Enter`
argument, do the same thing — use one, not two.)

```bash
# Run a command in an existing pane — the trailing \n is what submits it
ghoztty +send-keys --target=term "hello\tworld\n"
ghoztty +send-keys --target=term "npm test\n"

# The other two spellings of the same thing
ghoztty +send-keys --target=term "npm test" Enter
ghoztty +send-keys --target=term --enter "npm test"

# Interrupt a running process
ghoztty +send-keys --target=term C-c

# Send EOF to close a shell
ghoztty +send-keys --target=term C-d

# Send literal text that starts with `--`
ghoztty +send-keys --target=term -- "--not-a-flag" Enter
```

## Track activity state

```bash
# Mark a pane as busy while working
ghoztty +set-state --target=dev --state=busy
# Signal that user input is needed
ghoztty +set-state --target=dev --state=needs_input
# Mark idle when done
ghoztty +set-state --target=dev --state=idle
```

## Mistakes

- **Don't send `+send-keys` text with no way to submit it** — a bare `"message"` sits in a TUI composer unsent. End it with `\n` (`"message\n"`), or pass `--enter`, or a separate `Enter` argument. Pick one: they stack, and two of them submit twice.
- **Don't pass generated text as a positional argument** — a prompt you assembled, a path, anything with quotes or backslashes. Write it to a file and send `--keys-file=<path> Enter`; a positional goes through the calling shell's tokenizer and arrives mangled.
