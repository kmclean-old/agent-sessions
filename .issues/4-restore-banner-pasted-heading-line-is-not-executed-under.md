# Restore banner: pasted heading line is not executed under bracketed paste

## Context

Raised by the codex review of the libghostty 1.5 upgrade (2026-09-04); it
predates that range and is not a migration regression, since the old
`sendText` and the new `paste(text:)` both call `ghostty_surface_text`,
which Ghostty's `Surface.textCallback` routes to
`completeClipboardPaste(text, true)` — a paste, bracketed whenever the
program at the prompt has enabled mode 2004 (zsh does by default).

`SessionResume.restoreInput` builds `printf '%s\n' '<heading>'\n<resume
command>` and `TerminalCenter` pastes it in one go, documented as "the
heading prints, the resume command is left typed". Under bracketed paste
the embedded newline is pasted text: both lines land in the line editor
as a two-line buffer, the heading is not printed until the user presses
Enter, and Enter then runs both lines. The banner tests inject
`textDelivery`, so they cannot see this.

## Options

- Send the heading as its own paste followed by a real Enter via
  `sendKey(.enter)` (libghostty-spm 1.5 exposes `sendKey`), then paste the
  resume command alone.
- Or drop the printed heading and keep only the pre-typed command, with
  the context shown in the app UI instead.

## Acceptance criteria

- At a zsh prompt with bracketed paste on, the heading is printed and only
  the resume command remains in the buffer, unexecuted.

## Resolution (2026-09-05)

Kira hit exactly this on the first successful resume: the pane showed
`❯ printf '%s\n' 'Last Claude Code session: …'` with the resume command on
a second line beneath it.

Neither option above was taken as written. Pasting the heading and then
sending a real Enter would leave the `printf` line echoed in scrollback (and
in history) — the thing Kira asked to be rid of. Dropping the heading loses
the one place the remembered title survives after restore (the fresh
shell's first title overwrites the sidebar name). Instead the heading is
now the pane's own OUTPUT: a restored session's initial pane is spawned with
`TerminalSurfaceOptions.command` set to
`zsh -f -c 'printf … <heading>; exec -l zsh'`
(`SessionResumeMetadata.restoreShellCommand`), and only the resume command
is typed once the shell is at its prompt. Nothing is ever pasted to print.

Why that exact shape, verified against Ghostty c4e16970a803 (the commit
libghostty-spm 1.5.20260903 embeds) and reproduced in a pty:

- embedded.zig runs a surface command as `login -flp <user> /bin/bash
  --noprofile --norc -c "exec -l <string>"`, so the string must be one
  simple command → an intermediary `-c` shell.
- shell_integration.zig picks the integration from the first word's
  basename. Zsh's is env-only (`ZDOTDIR` → Ghostty's `.zshenv`), and
  `zsh -f` reads no startup files, so the inner `exec -l zsh` gets the
  integration, oh-my-zsh and a login shell exactly as a plain spawn does
  (`LOGIN=on OMZ=~/.oh-my-zsh ZDOTDIR=[] INTEG=1` in the pty run). Other
  login shells get the plain spawn and no heading rather than a pane that
  silently lost its integration.
- A surface command forces `wait-after-command`: `exit` in a restored pane
  now shows Ghostty's "Process exited" line and closes on the next
  keypress, where a fresh pane closes at once. Accepted as the price;
  documented in the README and `restoreShellCommand`.

Checks: `bb test` (557 tests, 0 failures) including a test that runs the
composed command through real `/bin/bash … -c "exec -l …"` + `zsh -f -c`
with a hostile title. Not yet seen in the running app — needs a relaunch of
a build carrying this change.

