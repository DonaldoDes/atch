# atch

`atch` is a small C utility that lets you attach and detach terminal sessions,
similar to the detach feature of `screen/tmux` — but without the terminal emulation,
multiple windows, or other overhead.

**The key property of `atch` is transparency.** It does not interpose a
terminal emulator between you and your program. The raw byte stream flows
directly from the pty to your terminal, exactly as if you had run the program
in a plain shell. This means:

- **Mouse works.** Mouse reporting, click events, and drag sequences pass
  through unmodified. No escape-sequence re-encoding, no `set -g mouse on`,
  no fighting with terminfo databases.
- **Scroll works.** Programs that use the alternate screen buffer, or that
  emit their own scroll sequences, behave identically inside and outside an
  `atch` session. There is nothing to configure.
- **Colors and graphics work.** True-color, sixel, kitty graphics, OSC
  sequences — all pass through untouched.
- **`$TERM` is unchanged.** `atch` does not set or override your terminal
  type. The program sees exactly the same `$TERM` your shell uses.

In contrast, `tmux` and `screen` implement their own terminal emulators.
They re-encode the output stream, which frequently breaks mouse support,
scroll behavior, and newer terminal features unless you find and apply the
right obscure configuration knob — and then remember it on every new machine.
With `atch` there is nothing to remember, because there is nothing in the way.

When a program runs inside an `atch` session it is protected from the
controlling terminal. You can detach from it, disconnect, and re-attach later
from the same or a different terminal, and the program keeps running
undisturbed.

**Session history survives everything.** Every byte written to the terminal
is appended to a persistent log file on disk. When you re-attach — whether
the session is still running, crashed, or you have rebooted the machine — the
full output history is replayed to your terminal first, so you can see exactly
what happened and pick up right where you left off. No plugins, no
configuration, no manual `script` wrappers. Other session managers keep
history only in memory: when the process dies or the machine reboots, the
output is gone. With `atch` it is on disk until you clear it.

## Features

- Attach and detach from running programs
- Multiple clients can attach to the same session simultaneously
- **No terminal emulation** — raw output stream is passed through unchanged
- Sessions persist across disconnects, crashes, and reboots
- **Full session history on disk** — every line ever written is saved and replayed on re-attach
- **History survives process exit** — re-opening a session shows the complete prior output before starting fresh
- Push stdin directly to a running session
- List all sessions with liveness status
- Prevents accidental recursive self-attach
- Tiny and auditable

## Building

```sh
make
```

## Usage

```
atch [<session> [command...]]   Attach to session or create it (default)
atch <command> [options] ...
```

Sessions are identified by name. A bare name (no `/`) is stored as a socket
under `~/.cache/atch/`. A name containing `/` is used as-is as a filesystem path.

If no command is given, `$SHELL` is used.

## Commands

| Command | Description |
|---------|-------------|
| `atch [<session> [cmd...]]` | Attach to a session, or create it if it doesn't exist (default behavior). |
| `attach <session>` | Strict attach — fail if the session does not exist. |
| `new <session> [cmd...]` | Create a new session and attach to it. |
| `start <session> [cmd...]` | Create a new session, detached (atch exits immediately). |
| `run <session> [cmd...]` | Like `start`, but atch stays in the foreground instead of daemonizing. |
| `push <session>` | Copy stdin verbatim to the session. |
| `kill <session>` | Gracefully stop a session (SIGTERM, then SIGKILL after 5 s if needed). |
| `list` | List all sessions in the session directory, with liveness status. |
| `current` | Print the current session name and exit 0 if inside a session; exit 1 silently if not. |

Short aliases: `a` → `attach`, `n` → `new`, `s` → `start`, `p` → `push`,
`k` → `kill`, `l` / `ls` → `list`.

## Options

Options can appear before or after the session name.

| Flag | Description |
|------|-------------|
| `-e <char>` | Set the detach character. Accepts `^X` notation. Default: `^\`. |
| `-E` | Disable the detach character entirely. |
| `-r <method>` | Redraw method on attach: `none`, `ctrl_l`, or `winch` (default). |
| `-R <method>` | Clear method on attach: `none` or `move`. |
| `-z` | Disable suspend-key (`^Z`) processing (pass it to the program instead). |
| `-q` | Suppress informational messages. |
| `-t` | Disable VT100 assumptions. |

Use `--` to separate atch options from command arguments that start with `-`:

```sh
atch new mysession -- grep -r foo /var/log
```

## Examples

**Start a shell session named `work` and attach to it:**
```sh
atch work
```

**Start a specific command in a named session:**
```sh
atch new build -- make -j4
```

**Attach to an existing session, creating it if needed:**
```sh
atch work
```

**Strict attach — fail if the session is not running:**
```sh
atch attach work
```

**Detach** from a running session: press `^\` (Ctrl-\\). The session and its
program keep running.

**Re-attach** later:
```sh
atch work
```

**Run a command fully detached (no terminal needed):**
```sh
atch start daemon myserver
```

**Send keystrokes to a running session:**
```sh
printf 'ls -la\n' | atch push work
```

**Use a custom detach character:**
```sh
atch attach work -e '^A'
```

**List all sessions:**
```sh
atch list
```

**Kill a session:**
```sh
atch kill work
```

## Session storage

By default, session sockets are stored in `~/.cache/atch/`. The directory is
created automatically, including `~/.cache` if it does not yet exist. If
`$HOME` is unset, sockets are stored in `/tmp/.atch-<uid>/`.

To use a custom path, include a `/` in the session name:

```sh
atch new /tmp/mysession
```

`atch` sets the `ATCH_SESSION` environment variable inside each session to the
socket path. This prevents recursive self-attach and can be used by shell
prompts or scripts to detect whether they are running inside an `atch` session.

Use `atch current` to check from a script or prompt:

```sh
# exit code: 0 inside a session, 1 outside
atch current && echo "inside session: $(atch current)"

# shell prompt example (bash/zsh PS1)
PS1='$(atch current 2>/dev/null && echo "[$(atch current)] ")$ '
```

Sessions can be nested: running `atch new inner` from within a session is
allowed. `ATCH_SESSION` is set only in the child process of each master, so
the outer session's shell always retains its own value — the self-attach
protection works correctly at all nesting levels.

## Session history

`atch` keeps two complementary history stores, both replayed automatically
whenever you attach — no configuration required.

### On-disk log (persistent)

Every byte written to the pty is appended to a log file on disk
(`~/.cache/atch/<session>.log`). The log persists across everything:

- **Detach / re-attach** — re-attaching to a running session replays the
  complete history before the live stream begins.
- **Session exit** — once the program exits, the full output remains on disk.
  Running `atch mysession` again starts a fresh session but first shows
  everything from the previous one, so you know exactly what it did.
- **Machine reboot** — the log file survives a reboot. The next time you
  open the session you see the complete prior output before the new shell
  starts.
- **Crash recovery** — if the session process is killed unexpectedly, the
  log is intact. Nothing is lost.

This is fundamentally different from `tmux`, `screen`, and `dtach`: they hold
history only in memory. When the process exits or the machine restarts, the
output is gone. With `atch` the raw byte stream is on disk until you
explicitly clear it with `atch clear <session>`.

The log is capped at 1 MB by default; once it exceeds that, only the most
recent 1 MB is kept. To change the cap, build with:

```sh
make CFLAGS="-DLOG_MAX_SIZE=$((4*1024*1024))"
```

### In-memory ring buffer (fast replay)

While the session is running, `atch` also maintains a 128 KB ring buffer in
the master process. When a new client attaches to a running session that has
no on-disk log to replay, the ring is used to deliver the most recent output
instantly, without a disk read. The ring is lost when the master exits, but
the on-disk log covers that case.

To adjust the ring size, build with:

```sh
make CFLAGS="-DSCROLLBACK_SIZE=$((256*1024))"
```

The value must be a power of two.

### Clearing history

To wipe the on-disk log and start clean on the next attach:

```sh
atch clear mysession
```

## Backward compatibility

The original flag-based syntax is still supported:

```
atch -a <session>              # same as: atch attach <session>
atch -A <session> [cmd...]     # same as: atch [<session> [cmd...]]
atch -c <session> [cmd...]     # same as: atch new <session> [cmd...]
atch -n <session> [cmd...]     # same as: atch start <session> [cmd...]
atch -N <session> [cmd...]     # same as: atch run <session> [cmd...]
atch -p <session>              # same as: atch push <session>
atch -k <session>              # same as: atch kill <session>
atch -l                        # same as: atch list
atch -i                        # same as: atch current
```

Existing scripts do not need to be updated.

## License

GPL. Based on dtach by Ned T. Crigler.
