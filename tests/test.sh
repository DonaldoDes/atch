#!/bin/sh
# Integration tests for atch.
# Usage: sh tests/test.sh <path-to-atch-binary>
# Runs entirely in /tmp so it never touches real session state.

ATCH="${1:-./atch}"

# ── test framework ──────────────────────────────────────────────────────────

PASS=0
FAIL=0
T=0

ok() {
    T=$((T + 1)); PASS=$((PASS + 1))
    printf "ok %d - %s\n" "$T" "$1"
}

fail() {
    T=$((T + 1)); FAIL=$((FAIL + 1))
    printf "not ok %d - %s\n" "$T" "$1"
    [ -n "$2" ] && printf "  # expected : %s\n  # got      : %s\n" "$2" "$3"
}

assert_eq() {
    if [ "$2" = "$3" ]; then ok "$1"; else fail "$1" "$2" "$3"; fi
}

assert_contains() {
    case "$3" in *"$2"*) ok "$1" ;; *) fail "$1" "(contains '$2')" "$3" ;; esac
}

assert_not_contains() {
    case "$3" in *"$2"*) fail "$1" "(not contain '$2')" "$3" ;; *) ok "$1" ;; esac
}

assert_exit() {
    if [ "$2" = "$3" ]; then ok "$1"; else fail "$1" "exit $2" "exit $3"; fi
}

run() { out=$("$@" 2>&1); rc=$?; }

# ── isolation ────────────────────────────────────────────────────────────────

TESTDIR=$(mktemp -d)
export HOME="$TESTDIR"
trap 'rm -rf "$TESTDIR"' EXIT

printf "TAP version 13\n"

# ── helpers ──────────────────────────────────────────────────────────────────

# Wait until the session socket appears (up to 1 s).
wait_socket() {
    local i=0
    while [ $i -lt 20 ]; do
        [ -S "$HOME/.cache/atch/$1" ] && return 0
        sleep 0.05
        i=$((i + 1))
    done
    return 1
}

# Kill a named session and wait for its socket to vanish.
tidy() { "$ATCH" kill "$1" >/dev/null 2>&1; sleep 0.05; }

# ── 1. help / version ────────────────────────────────────────────────────────

run "$ATCH" --help
assert_exit   "help: --help exits 0"      0 "$rc"
assert_contains "help: --help shows usage"  "Usage:" "$out"

run "$ATCH" -h
assert_exit   "help: -h exits 0"          0 "$rc"
assert_contains "help: -h shows usage"    "Usage:" "$out"

run "$ATCH" "?"
assert_exit   "help: ? exits 0"           0 "$rc"
assert_contains "help: ? shows usage"     "Usage:" "$out"

run "$ATCH" --version
assert_exit     "version: exits 0"        0 "$rc"
assert_contains "version: shows version"  "version" "$out"

# ── 2. start command ─────────────────────────────────────────────────────────

run "$ATCH" start
assert_exit     "start: no session → exit 1"        1 "$rc"
assert_contains "start: no session → message"       "No session was specified" "$out"

run "$ATCH" start s-basic sleep 999
assert_exit     "start: exits 0"                    0 "$rc"
assert_contains "start: prints confirmation"        "session 's-basic' started" "$out"
tidy s-basic

# quiet flag after session name
run "$ATCH" start s-quiet -q sleep 999
assert_exit     "start -q: exits 0"                 0 "$rc"
assert_eq       "start -q: no output"               "" "$out"
tidy s-quiet

# quiet flag before session name (new-style option position)
run "$ATCH" start -q s-qpre sleep 999
assert_exit     "start -q (pre-session): exits 0"   0 "$rc"
assert_eq       "start -q (pre-session): no output" "" "$out"
tidy s-qpre

# already running
run "$ATCH" start s-dup sleep 999
run "$ATCH" start s-dup sleep 999
assert_exit     "start: already running → exit 1"   1 "$rc"
assert_contains "start: already running message"    "already running" "$out"
tidy s-dup

# bad command
run "$ATCH" start s-badcmd __atch_no_such_cmd__
assert_exit     "start: bad command → exit 1"       1 "$rc"
assert_contains "start: bad command message"        "could not execute" "$out"

# short alias 's'
run "$ATCH" s s-alias sleep 999
assert_exit     "start alias 's': exits 0"          0 "$rc"
assert_contains "start alias 's': confirmation"     "session 's-alias' started" "$out"
tidy s-alias

# legacy -n
run "$ATCH" -n s-legacy sleep 999
assert_exit     "legacy -n: exits 0"                0 "$rc"
tidy s-legacy

# ── 3. list command ───────────────────────────────────────────────────────────

run "$ATCH" list
assert_exit  "list: empty → exits 0"                0 "$rc"
assert_eq    "list: empty → (no sessions)"          "(no sessions)" "$out"

# quiet suppresses the empty message
run "$ATCH" -q list
assert_exit  "list -q: empty → exits 0"             0 "$rc"
assert_eq    "list -q: empty → no output"           "" "$out"

# with a running session
"$ATCH" start s-list sleep 999
run "$ATCH" list
assert_exit     "list: shows running session → exits 0"    0 "$rc"
assert_contains "list: shows session name"                 "s-list" "$out"
assert_not_contains "list: no [dead] for live session"    "[dead]" "$out"

# quiet still shows session data (only suppresses meta-messages)
run "$ATCH" -q list
assert_contains "list -q: still shows session data"        "s-list" "$out"

# short aliases
run "$ATCH" l
assert_contains "list alias 'l': works"   "s-list" "$out"
run "$ATCH" ls
assert_contains "list alias 'ls': works"  "s-list" "$out"

# legacy -l
run "$ATCH" -l
assert_contains "legacy -l: works"        "s-list" "$out"

tidy s-list

run "$ATCH" list
assert_eq "list: back to empty after kill" "(no sessions)" "$out"

# ── 3b. interactive picker: non-TTY fallback (US-007) ────────────────────────
#
# When stdout is NOT a TTY (pipe / script), `atch list` MUST fall back to the
# plain-text listing.  We verify this by running through a pipe (the `run`
# helper) and checking:
#   1. Exit code is 0
#   2. Session names appear in the output
#   3. No ANSI cursor-movement escapes are written
#   4. --no-picker flag also forces plain-text mode

"$ATCH" start picker-live sleep 999

run "$ATCH" list
assert_exit     "picker fallback: non-tty list exits 0"          0 "$rc"
assert_contains "picker fallback: live session shown"            "picker-live" "$out"

# No cursor-movement escapes should appear in non-TTY output
case "$out" in
    *"["*"A"*|*"["*"B"*|*"["*"H"*|*"["*"J"*)
        fail "picker fallback: no cursor-movement escapes in non-tty output" \
             "no ESC[A/B/H/J" "found in output" ;;
    *)
        ok "picker fallback: no cursor-movement escapes in non-tty output" ;;
esac

# --no-picker flag forces plain-text mode
run "$ATCH" list --no-picker
assert_exit     "picker --no-picker: exits 0"                    0 "$rc"
assert_contains "picker --no-picker: live session shown"         "picker-live" "$out"

tidy picker-live

# Stale session listed in non-TTY mode with [stale]
"$ATCH" run picker-stale sleep 99999 &
PICKER_STALE_PID=$!
wait_socket picker-stale
kill -9 "$PICKER_STALE_PID" 2>/dev/null
sleep 0.1

run "$ATCH" list
assert_contains "picker fallback: dead session shows [dead]"   "[dead]" "$out"

rm -f "$HOME/.cache/atch/picker-stale"

# ── 4. stale session ─────────────────────────────────────────────────────────
# Use 'run' (dontfork master stays in foreground) so we get the master PID
# directly via $!.  kill -9 leaves the socket file on disk but removes the
# listener → ECONNREFUSED → list shows [stale].

"$ATCH" run s-stale sleep 99999 &
STALE_MASTER_PID=$!
wait_socket s-stale
kill -9 "$STALE_MASTER_PID" 2>/dev/null
sleep 0.1

run "$ATCH" list
assert_contains "list: dead session shows [dead]" "[dead]" "$out"

# clean up orphaned child and leftover socket
for p in $(ls /proc | grep -E '^[0-9]+$'); do
    [ -f "/proc/$p/cmdline" ] || continue
    cmd=$(tr '\0' ' ' < "/proc/$p/cmdline" 2>/dev/null)
    case "$cmd" in *"sleep 99999"*) kill "$p" 2>/dev/null ;; esac
done
rm -f "$HOME/.cache/atch/s-stale"

# ── 5. kill command ───────────────────────────────────────────────────────────

run "$ATCH" kill
assert_exit     "kill: no session → exit 1"          1 "$rc"
assert_contains "kill: no session → message"         "No session was specified" "$out"

run "$ATCH" kill s-noexist
assert_exit     "kill: nonexistent → exit 1"         1 "$rc"
assert_contains "kill: nonexistent → message"        "does not exist" "$out"

"$ATCH" start s-kill sleep 999
run "$ATCH" kill s-kill
assert_exit     "kill: running → exit 0"             0 "$rc"
assert_contains "kill: prints stopped"               "stopped" "$out"

run "$ATCH" kill s-kill
assert_exit     "kill: already gone → exit 1"        1 "$rc"
assert_contains "kill: already gone → message"       "does not exist" "$out"

# legacy -k
"$ATCH" start s-legkill sleep 999
run "$ATCH" -k s-legkill
assert_exit     "legacy -k: exits 0"                 0 "$rc"
assert_contains "legacy -k: prints stopped"          "stopped" "$out"

# short alias 'k'
"$ATCH" start s-kalias sleep 999
run "$ATCH" k s-kalias
assert_exit     "kill alias 'k': exits 0"            0 "$rc"
assert_contains "kill alias 'k': prints stopped"     "stopped" "$out"

# extra args rejected
"$ATCH" start s-killextra sleep 999
run "$ATCH" kill s-killextra extra
assert_exit     "kill: extra arg → exit 1"           1 "$rc"
assert_contains "kill: extra arg → message"          "Invalid number of arguments" "$out"
tidy s-killextra

# kill -f / --force (skip SIGTERM grace period, send SIGKILL directly)
"$ATCH" start s-killf sleep 999
run "$ATCH" kill -f s-killf
assert_exit     "kill -f: exits 0"                   0 "$rc"
assert_contains "kill -f: prints killed"             "killed" "$out"

"$ATCH" start s-killf2 sleep 999
run "$ATCH" kill --force s-killf2
assert_exit     "kill --force: exits 0"              0 "$rc"
assert_contains "kill --force: prints killed"        "killed" "$out"

# -f after session name
"$ATCH" start s-killf3 sleep 999
run "$ATCH" kill s-killf3 -f
assert_exit     "kill -f (after session): exits 0"   0 "$rc"
assert_contains "kill -f (after session): killed"    "killed" "$out"

# -f on nonexistent session still reports the error
run "$ATCH" kill -f s-noexist-force
assert_exit     "kill -f: nonexistent → exit 1"      1 "$rc"
assert_contains "kill -f: nonexistent → message"     "does not exist" "$out"

# kill attached session: simulate a client attached to the session
# The attached client keeps a socket connection with MSG_ATTACH sent.
# kill must terminate the session despite the attached client.
"$ATCH" start s-kill-att sleep 999
wait_socket s-kill-att

# Simulate an attached client: connect + send MSG_ATTACH packet.
# struct packet = type(1) + len(1) + union(sizeof(struct winsize)).
# MSG_ATTACH=1, len=0 → normal ring replay.
python3 -c "
import socket, struct, time, sys, os
ws = 8
sockpath = os.environ['HOME'] + '/.cache/atch/s-kill-att'
s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
s.connect(sockpath)
pkt = struct.pack('BB', 1, 0) + b'\x00' * ws
s.sendall(pkt)
# keep alive until killed or master closes
s.setblocking(False)
for _ in range(200):
    time.sleep(0.1)
    try:
        d = s.recv(4096)
        if not d: break
    except BlockingIOError: pass
s.close()
" &
KILL_ATT_CLIENT=$!
sleep 0.5

# Verify the session shows as attached (S_IXUSR set)
run "$ATCH" list --no-picker
assert_contains "kill-att: shows [attached]"         "[attached]" "$out"

# Kill the attached session (non-force)
run "$ATCH" kill s-kill-att
assert_exit     "kill-att: exits 0"                  0 "$rc"

# Session must be gone
run "$ATCH" list --no-picker
assert_not_contains "kill-att: session gone"         "s-kill-att" "$out"

kill $KILL_ATT_CLIENT 2>/dev/null
wait $KILL_ATT_CLIENT 2>/dev/null

# kill -f on attached session: must terminate quickly (< 3s)
"$ATCH" start s-kill-att-f sleep 999
wait_socket s-kill-att-f

python3 -c "
import socket, struct, time, sys, os
ws = 8
sockpath = os.environ['HOME'] + '/.cache/atch/s-kill-att-f'
s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
s.connect(sockpath)
pkt = struct.pack('BB', 1, 0) + b'\x00' * ws
s.sendall(pkt)
s.setblocking(False)
for _ in range(200):
    time.sleep(0.1)
    try:
        d = s.recv(4096)
        if not d: break
    except BlockingIOError: pass
s.close()
" &
KILL_ATT_F_CLIENT=$!
sleep 0.5

run "$ATCH" list --no-picker
assert_contains "kill-att-f: shows [attached]"       "[attached]" "$out"

run "$ATCH" kill -f s-kill-att-f
assert_exit     "kill-att-f: exits 0"                0 "$rc"
assert_contains "kill-att-f: prints killed"          "killed" "$out"

run "$ATCH" list --no-picker
assert_not_contains "kill-att-f: session gone"       "s-kill-att-f" "$out"

kill $KILL_ATT_F_CLIENT 2>/dev/null
wait $KILL_ATT_F_CLIENT 2>/dev/null

# kill attached session running a SIGTERM-ignoring child.
# The child traps SIGTERM, so only SIGKILL (escalation) can stop it.
# kill -f must succeed because it sends SIGKILL directly.
"$ATCH" start s-kill-trap sh -c 'trap "" TERM; sleep 999'
wait_socket s-kill-trap

# Attach a client
python3 -c "
import socket, struct, time, os
ws = 8
sockpath = os.environ['HOME'] + '/.cache/atch/s-kill-trap'
s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
s.connect(sockpath)
pkt = struct.pack('BB', 1, 0) + b'\x00' * ws
s.sendall(pkt)
s.setblocking(False)
for _ in range(200):
    time.sleep(0.1)
    try:
        d = s.recv(4096)
        if not d: break
    except BlockingIOError: pass
s.close()
" &
KILL_TRAP_CLIENT=$!
sleep 0.5

run "$ATCH" list --no-picker
assert_contains "kill-trap: shows [attached]"        "[attached]" "$out"

# Force kill must work even though child ignores SIGTERM
run "$ATCH" kill -f s-kill-trap
assert_exit     "kill-trap: force exits 0"           0 "$rc"
assert_contains "kill-trap: prints killed"           "killed" "$out"

run "$ATCH" list --no-picker
assert_not_contains "kill-trap: session gone"        "s-kill-trap" "$out"

kill $KILL_TRAP_CLIENT 2>/dev/null
wait $KILL_TRAP_CLIENT 2>/dev/null

# ── 6. clear command ─────────────────────────────────────────────────────────

run "$ATCH" clear
assert_exit     "clear: no session, no env → exit 1"         1 "$rc"
assert_contains "clear: no session, no env → message"        "No session was specified" "$out"

# clear a nonexistent log is silent success
run "$ATCH" clear s-noexist-clear
assert_exit "clear: no log → exits 0"                0 "$rc"
assert_eq   "clear: no log → no output"              "" "$out"

# start a session (creates the log)
"$ATCH" start s-clear sleep 999

run "$ATCH" clear s-clear
assert_exit     "clear: exits 0"                     0 "$rc"
assert_contains "clear: confirmation message"        "log cleared" "$out"

# quiet suppresses confirmation
"$ATCH" start s-clearq sleep 999
run "$ATCH" -q clear s-clearq
assert_exit "clear -q: exits 0"                      0 "$rc"
assert_eq   "clear -q: no output"                    "" "$out"

tidy s-clear
tidy s-clearq

# extra args rejected
run "$ATCH" clear s-noexist-clear extra
assert_exit     "clear: extra arg → exit 1"          1 "$rc"
assert_contains "clear: extra arg → message"         "Invalid number of arguments" "$out"

# atch clear with ATCH_SESSION set uses current session
"$ATCH" start s-clear-cur sleep 999
wait_socket s-clear-cur
run env ATCH_SESSION="$HOME/.cache/atch/s-clear-cur" "$ATCH" clear
assert_exit     "clear: current session → exit 0"    0 "$rc"
assert_contains "clear: current session → message"   "log cleared" "$out"

# atch clear with no arg uses innermost session from nested chain
"$ATCH" start s-clear-inner sleep 999
wait_socket s-clear-inner
run env ATCH_SESSION="$HOME/.cache/atch/s-clear-cur:$HOME/.cache/atch/s-clear-inner" \
        "$ATCH" clear
assert_exit     "clear: nested env no arg → exit 0"  0 "$rc"
assert_contains "clear: nested env no arg → message" "s-clear-inner" "$out"

tidy s-clear-cur
tidy s-clear-inner

# ── 7. current command ───────────────────────────────────────────────────────

run "$ATCH" current
assert_exit "current: outside session → exit 1"      1 "$rc"
assert_eq   "current: outside session → no output"   "" "$out"

# ATCH_SESSION holds the chain; a single session has no colon
run env ATCH_SESSION="$HOME/.cache/atch/mywork" "$ATCH" current
assert_exit     "current: single session → exit 0"         0 "$rc"
assert_eq       "current: single session → basename"       "mywork" "$out"

# deep path
run env ATCH_SESSION="/tmp/deep/path/proj" "$ATCH" current
assert_exit     "current: deep path → exit 0"        0 "$rc"
assert_eq       "current: deep path basename"        "proj" "$out"

# two levels of nesting: ATCH_SESSION = outer:inner
run env ATCH_SESSION="$HOME/.cache/atch/outer:$HOME/.cache/atch/inner" \
        "$ATCH" current
assert_exit     "current: nested 2 levels → exit 0"  0 "$rc"
assert_eq       "current: nested 2 levels → chain"   "outer > inner" "$out"

# three levels of nesting
run env ATCH_SESSION="/s/a:/s/b:/s/c" "$ATCH" current
assert_exit     "current: nested 3 levels → exit 0"  0 "$rc"
assert_eq       "current: nested 3 levels → chain"   "a > b > c" "$out"

# legacy -i
run "$ATCH" -i
assert_exit "legacy -i: outside session → exit 1"    1 "$rc"

# verify that ATCH_SESSION is set in the child and contains the socket path
"$ATCH" start envname-test sh -c \
    'printf "%s\n" "$ATCH_SESSION" > /tmp/atch-envname.txt'
sleep 0.1
run grep -q "envname-test" /tmp/atch-envname.txt
assert_exit "current: ATCH_SESSION set in child and contains socket path" 0 "$rc"
rm -f /tmp/atch-envname.txt

# verify that dashes (and other non-alphanumeric chars) in the binary name
# are replaced with underscores in the env var name:
# binary 'ssh2incus-atch' → env var 'SSH2INCUS_ATCH_SESSION'
DASH_ATCH="$TESTDIR/bin/ssh2incus-atch"
mkdir -p "$TESTDIR/bin"
ln -s "$ATCH" "$DASH_ATCH" 2>/dev/null || cp "$ATCH" "$DASH_ATCH"
"$DASH_ATCH" start envdash-test sh -c \
    'printf "%s\n" "$SSH2INCUS_ATCH_SESSION" > /tmp/atch-envdash.txt'
sleep 0.1
run grep -q "envdash-test" /tmp/atch-envdash.txt
assert_exit "current: dash in binary name → underscore in env var name" 0 "$rc"
"$DASH_ATCH" kill envdash-test >/dev/null 2>&1
rm -f /tmp/atch-envdash.txt

# ── 8. push command ───────────────────────────────────────────────────────────

run "$ATCH" push
assert_exit     "push: no session → exit 1"          1 "$rc"
assert_contains "push: no session → message"         "No session was specified" "$out"

run "$ATCH" push s-noexist-push
assert_exit     "push: nonexistent session → exit 1" 1 "$rc"

# push to a running session (cat echoes input back to pty → appears in log)
"$ATCH" start s-push cat
sleep 0.05
printf 'atch-push-marker\n' | "$ATCH" push s-push
sleep 0.1
run grep -q "atch-push-marker" "$HOME/.cache/atch/s-push.log"
assert_exit "push: data appears in session log"       0 "$rc"
tidy s-push

# extra args rejected
run "$ATCH" push s-noexist extra
assert_exit     "push: extra arg → exit 1"           1 "$rc"
assert_contains "push: extra arg → message"          "Invalid number of arguments" "$out"

# legacy -p (nonexistent session)
run "$ATCH" -p s-noexist-push
assert_exit "legacy -p: nonexistent → exit 1"        1 "$rc"

# ── 9. attach / new / open — TTY requirement ─────────────────────────────────
# All three require a TTY. Running in a non-TTY environment they must fail
# with a clear message (not a crash or silent hang).

run "$ATCH" attach s-notty
assert_exit     "attach: no tty → exit 1"            1 "$rc"
assert_contains "attach: no tty → message"           "requires a terminal" "$out"

run "$ATCH" a s-notty
assert_exit     "attach alias 'a': no tty → exit 1"  1 "$rc"
assert_contains "attach alias 'a': message"          "requires a terminal" "$out"

run "$ATCH" new s-notty
assert_exit     "new: no tty → exit 1"               1 "$rc"
assert_contains "new: no tty → message"              "requires a terminal" "$out"

run "$ATCH" n s-notty
assert_exit     "new alias 'n': no tty → exit 1"     1 "$rc"
assert_contains "new alias 'n': message"             "requires a terminal" "$out"

# default open (atch <session>) with no tty
run "$ATCH" s-notty-open
assert_exit     "open: no tty → exit 1"              1 "$rc"
assert_contains "open: no tty → message"             "requires a terminal" "$out"

# strict attach to nonexistent session still reports tty requirement first
run "$ATCH" attach s-noexist-notty
assert_exit     "attach: nonexistent + no tty → exit 1"     1 "$rc"
assert_contains "attach: nonexistent + no tty → message"    "requires a terminal" "$out"

# legacy -a
run "$ATCH" -a s-notty
assert_exit     "legacy -a: no tty → exit 1"         1 "$rc"
assert_contains "legacy -a: no tty → message"        "requires a terminal" "$out"

# legacy -A
run "$ATCH" -A s-notty
assert_exit     "legacy -A: no tty → exit 1"         1 "$rc"
assert_contains "legacy -A: message"                 "requires a terminal" "$out"

# legacy -c
run "$ATCH" -c s-notty
assert_exit     "legacy -c: no tty → exit 1"         1 "$rc"
assert_contains "legacy -c: message"                 "requires a terminal" "$out"

# ── 10. -q global option (before subcommand) ────────────────────────────────

"$ATCH" start gq-s sleep 999

run "$ATCH" -q list
assert_exit     "-q before list: exits 0"            0 "$rc"
assert_contains "-q before list: still shows data"   "gq-s" "$out"

"$ATCH" kill gq-s > /dev/null
run "$ATCH" -q list
assert_exit     "-q before list: empty → exits 0"    0 "$rc"
assert_eq       "-q before list: empty → no output"  "" "$out"

run "$ATCH" -q start gq-s2 sleep 999
assert_exit     "-q before start: exits 0"           0 "$rc"
assert_eq       "-q before start: no output"         "" "$out"
tidy gq-s2

run "$ATCH" -q clear gq-noexist
assert_exit     "-q before clear: exits 0"           0 "$rc"
assert_eq       "-q before clear: no output"         "" "$out"

# ── 11. -e / -E flag ─────────────────────────────────────────────────────────

# -e with ^X notation
run "$ATCH" start -e "^A" e-test sleep 999
assert_exit     "-e ^A: exits 0"                     0 "$rc"
assert_contains "-e ^A: confirmation"                "started" "$out"
tidy e-test

# -e with literal char
run "$ATCH" start -e "~" e-test2 sleep 999
assert_exit     "-e ~: exits 0"                      0 "$rc"
tidy e-test2

# -e with ^? (DEL)
run "$ATCH" start -e "^?" e-test3 sleep 999
assert_exit     "-e ^?: exits 0"                     0 "$rc"
tidy e-test3

# -e missing argument
run "$ATCH" start -e
assert_exit     "-e missing arg: exit 1"             1 "$rc"
assert_contains "-e missing arg: message"            "No escape character" "$out"

# -E disables detach char
run "$ATCH" start -E e-nodetach sleep 999
assert_exit     "-E: exits 0"                        0 "$rc"
assert_contains "-E: confirmation"                   "started" "$out"
tidy e-nodetach

# ── 12. -r / -R flag ─────────────────────────────────────────────────────────

for method in none ctrl_l winch; do
    run "$ATCH" start -r "$method" r-test sleep 999
    assert_exit     "-r $method: exits 0"            0 "$rc"
    tidy r-test
done

run "$ATCH" start -r badmethod r-test sleep 999
assert_exit     "-r badmethod: exit 1"               1 "$rc"
assert_contains "-r badmethod: message"              "Invalid redraw method" "$out"

run "$ATCH" start -r
assert_exit     "-r missing arg: exit 1"             1 "$rc"
assert_contains "-r missing arg: message"            "No redraw method" "$out"

for method in none move; do
    run "$ATCH" start -R "$method" R-test sleep 999
    assert_exit     "-R $method: exits 0"            0 "$rc"
    tidy R-test
done

run "$ATCH" start -R badmethod R-test sleep 999
assert_exit     "-R badmethod: exit 1"               1 "$rc"
assert_contains "-R badmethod: message"              "Invalid clear method" "$out"

run "$ATCH" start -R
assert_exit     "-R missing arg: exit 1"             1 "$rc"
assert_contains "-R missing arg: message"            "No clear method" "$out"

# ── 13. -z / -t flags ────────────────────────────────────────────────────────

run "$ATCH" start -z z-test sleep 999
assert_exit     "-z: exits 0"                        0 "$rc"
assert_contains "-z: confirmation"                   "started" "$out"
tidy z-test

run "$ATCH" start -t t-test sleep 999
assert_exit     "-t: exits 0"                        0 "$rc"
assert_contains "-t: confirmation"                   "started" "$out"
tidy t-test

# ── 14. combined / stacked flags ─────────────────────────────────────────────

# -qEzt combined in one flag
run "$ATCH" start -qEzt combo-test sleep 999
assert_exit     "combined -qEzt: exits 0"            0 "$rc"
assert_eq       "combined -qEzt: no output"          "" "$out"
tidy combo-test

# multiple separate flags before session
run "$ATCH" start -q -E -z -t combo2 sleep 999
assert_exit     "separate -q -E -z -t: exits 0"     0 "$rc"
assert_eq       "separate -q -E -z -t: no output"   "" "$out"
tidy combo2

# -e and -r together (e before r)
run "$ATCH" start -e "^B" -r none combo3 sleep 999
assert_exit     "-e + -r together: exits 0"          0 "$rc"
tidy combo3

# ── 15. -- separator ─────────────────────────────────────────────────────────

# A command that starts with - must be separated with --
run "$ATCH" start sep-test -- sleep 999
assert_exit     "-- separator: exits 0"              0 "$rc"
assert_contains "-- separator: confirmation"         "started" "$out"
tidy sep-test

# ── 16. invalid option ───────────────────────────────────────────────────────

run "$ATCH" start -x s-badopt sleep 999
assert_exit     "invalid option -x: exit 1"          1 "$rc"
assert_contains "invalid option -x: message"         "Invalid option" "$out"

# ── 17. custom socket path (name with /) ─────────────────────────────────────

CUSTOM_SOCK="$TESTDIR/custom-session"
run "$ATCH" start "$CUSTOM_SOCK" sleep 999
assert_exit     "custom path: exits 0"               0 "$rc"
assert_contains "custom path: confirmation"          "started" "$out"
[ -S "$CUSTOM_SOCK" ] && ok "custom path: socket created at given path" \
                        || fail "custom path: socket created at given path" "socket file" "not found"

run "$ATCH" list
assert_not_contains "custom path: not in default list" "custom-session" "$out"

run "$ATCH" kill "$CUSTOM_SOCK"
assert_exit     "custom path kill: exits 0"          0 "$rc"
assert_contains "custom path kill: stopped"          "stopped" "$out"

# ── 18. ATCH_SESSION env in child process ────────────────────────────────────

"$ATCH" start env-test sh -c 'echo "SESSION=$ATCH_SESSION" > /tmp/atch-env-test.txt'
sleep 0.1
run grep -q "SESSION=" /tmp/atch-env-test.txt
assert_exit "ATCH_SESSION set in child process"      0 "$rc"
rm -f /tmp/atch-env-test.txt

# ── 19. session log written on start ─────────────────────────────────────────

"$ATCH" start log-test sh -c 'printf "hello-log-test\n"; sleep 999'
sleep 0.1
run grep -q "hello-log-test" "$HOME/.cache/atch/log-test.log"
assert_exit "session output written to log"          0 "$rc"
tidy log-test

# ── 20. -C log cap flag ──────────────────────────────────────────────────────

# valid sizes: 0 (disable), k/K suffix, m/M suffix, bare bytes
run "$ATCH" start -C 0 C-test0 sleep 999
assert_exit     "-C 0: exits 0"                      0 "$rc"
assert_contains "-C 0: confirmation"                 "started" "$out"
# log file must NOT exist when logging is disabled
if [ -e "$HOME/.cache/atch/C-test0.log" ]; then
    fail "-C 0: no log file created" "no file" "file exists"
else
    ok "-C 0: no log file created"
fi
tidy C-test0

# -C before the subcommand (global pre-pass position)
run "$ATCH" -C 0 start C-global sleep 999
assert_exit     "-C 0 (global position): exits 0"    0 "$rc"
if [ -e "$HOME/.cache/atch/C-global.log" ]; then
    fail "-C 0 (global position): no log file" "no file" "file exists"
else
    ok "-C 0 (global position): no log file"
fi
tidy C-global

run "$ATCH" start -C 128k C-128k sleep 999
assert_exit     "-C 128k: exits 0"                   0 "$rc"
assert_contains "-C 128k: confirmation"              "started" "$out"
tidy C-128k

run "$ATCH" start -C 4m C-4m sleep 999
assert_exit     "-C 4m: exits 0"                     0 "$rc"
assert_contains "-C 4m: confirmation"                "started" "$out"
tidy C-4m

run "$ATCH" start -C 65536 C-bytes sleep 999
assert_exit     "-C <bytes>: exits 0"                0 "$rc"
tidy C-bytes

# missing argument
run "$ATCH" start -C
assert_exit     "-C missing arg: exit 1"             1 "$rc"
assert_contains "-C missing arg: message"            "No log size" "$out"

# invalid value
run "$ATCH" start -C foo C-bad sleep 999
assert_exit     "-C invalid: exit 1"                 1 "$rc"
assert_contains "-C invalid: message"                "Invalid log size" "$out"

# ── 21. ATCH_SESSION ancestry protection ─────────────────────────────────────
#
# Regression test for the ATCH_SESSION stale-ancestry bug.
#
# The anti-recursion guard in attach_main must only fire when the current
# process is genuinely a descendant of the target session.  It must NOT fire
# when ATCH_SESSION merely contains the session path but the process is not
# actually running inside that session (stale env var).
#
# Because attach_main is only reached after require_tty() in the normal
# command path, we probe the guard by simulating the session's .ppid file:
#
#   • No .ppid file (or PID 0) → guard is bypassed → "does not exist" / "requires a terminal"
#   • .ppid file with a PID that IS an ancestor of the current shell → guard fires
#   • .ppid file with a PID that is NOT an ancestor (e.g. already-dead PID) → guard bypassed
#
# A session's .ppid file is written by the master and contains the PID of the
# shell process running inside the pty (the_pty.pid).

mkdir -p "$HOME/.cache/atch"

# Case A: ATCH_SESSION holds a session path, NO .ppid file exists → no block
GHOST_SOCK="$HOME/.cache/atch/ghost-session"
# No socket, no .ppid — completely absent session
run env ATCH_SESSION="$GHOST_SOCK" "$ATCH" attach ghost-session 2>&1
assert_exit "ppid-guard: no ppid file → exit 1 (not self-attach)"  1 "$rc"
assert_not_contains "ppid-guard: no ppid file → no self-attach msg" \
    "from within itself" "$out"

# Case B: .ppid file contains a dead / non-ancestor PID → guard must NOT fire
"$ATCH" start ppid-live sleep 9999
wait_socket ppid-live
PPID_SOCK="$HOME/.cache/atch/ppid-live"
# Write a PID that is definitely not an ancestor (PID 1 is init/launchd,
# which is NOT a direct ancestor of our test shell in a normal session).
# Using a large unlikely-to-exist PID is fragile; using PID 1 is safe because
# PID 1 is the root, not our direct ancestor in the process hierarchy
# (our shell's ppid is the test runner, not init).
# Actually we need a PID that is NOT in our ancestry. PID of a sleep process works.
DEAD_PID_PROC=$(sh -c 'sleep 60 & echo $!')
sleep 0.05
kill "$DEAD_PID_PROC" 2>/dev/null
wait "$DEAD_PID_PROC" 2>/dev/null
# DEAD_PID_PROC is now dead — write it as ppid
printf "%d\n" "$DEAD_PID_PROC" > "${PPID_SOCK}.ppid"
run env ATCH_SESSION="$PPID_SOCK" "$ATCH" attach ppid-live 2>&1
assert_exit "ppid-guard: dead ppid → exit 1 (not self-attach)" 1 "$rc"
assert_not_contains "ppid-guard: dead ppid → no self-attach msg" \
    "from within itself" "$out"
tidy ppid-live

# Case C: .ppid file contains the PID of our current shell → guard MUST fire
"$ATCH" start self-session sleep 9999
wait_socket self-session
SELF_SOCK="$HOME/.cache/atch/self-session"
# Write the PID of the current shell ($$) as if this process IS the shell
# running inside the session.  From atch's perspective, our process IS a
# descendant of "$$" (itself) — so the guard should trigger.
printf "%d\n" "$$" > "${SELF_SOCK}.ppid"
run env ATCH_SESSION="$SELF_SOCK" "$ATCH" attach self-session 2>&1
assert_exit "ppid-guard: self as ppid → blocked exit 1" 1 "$rc"
assert_contains "ppid-guard: self as ppid → self-attach msg" \
    "from within itself" "$out"
tidy self-session

# ── 22. replay_session_log: bounded replay (last SCROLLBACK_SIZE bytes only) ──
#
# Regression test for: replay_session_log must replay at most SCROLLBACK_SIZE
# (128 KB) of the session log.  Without this cap, attaching a session with a
# large log (e.g. a long-running build) causes an overwhelming scroll that
# appears to loop indefinitely.
#
# Strategy: create a synthetic .log file larger than SCROLLBACK_SIZE (128 KB),
# attach to the dead session using expect(1) to supply a PTY (required by
# attach_main), and verify the output byte count and content.
#
# expect(1) is available on macOS by default and on most Linux distros.
# If absent, the test is skipped.

if command -v expect >/dev/null 2>&1 && command -v python3 >/dev/null 2>&1; then
    mkdir -p "$HOME/.cache/atch"

    REPLAY_SOCK="$HOME/.cache/atch/replay-cap-sess"
    REPLAY_LOG="${REPLAY_SOCK}.log"

    # Build a log of ~290 KB: OLD_DATA fills the first 160 KB,
    # NEW_DATA fills the last 128 KB.  Only NEW_DATA should appear in replay.
    python3 -c "
import sys
old = b'OLD_DATA_LINE_PADDED_TO_EXACTLY_32B\n'
new = b'NEW_DATA_LINE_PADDED_TO_EXACTLY_32B\n'
old_count = (160 * 1024) // len(old) + 1
new_count = (128 * 1024) // len(new) + 1
sys.stdout.buffer.write(old * old_count)
sys.stdout.buffer.write(new * new_count)
" > "$REPLAY_LOG"

    # Use expect to run atch attach with a real PTY, capturing all output.
    # atch exits immediately after replaying the log for a dead session.
    REPLAY_OUT=$(mktemp)
    expect - << EXPECT_EOF > "$REPLAY_OUT" 2>/dev/null
set timeout 10
spawn $ATCH attach replay-cap-sess
expect eof
EXPECT_EOF

    OUT_BYTES=$(wc -c < "$REPLAY_OUT")

    # Output must stay within SCROLLBACK_SIZE + some terminal-overhead margin
    # (expect may inject a few extra bytes; 256 KB is a safe upper bound).
    MAX_BYTES=262144
    if [ "$OUT_BYTES" -le "$MAX_BYTES" ]; then
        ok "replay-log: output bounded ($OUT_BYTES <= $MAX_BYTES bytes)"
    else
        fail "replay-log: output bounded" \
             "<= $MAX_BYTES bytes" "$OUT_BYTES bytes"
    fi

    # Replayed content must come from the tail (NEW_DATA present).
    if grep -q "NEW_DATA" "$REPLAY_OUT" 2>/dev/null; then
        ok "replay-log: tail of log replayed (NEW_DATA present)"
    else
        fail "replay-log: tail of log replayed (NEW_DATA present)" \
             "NEW_DATA in output" "not found"
    fi

    # HEAD of log must NOT appear (OLD_DATA absent).
    if grep -q "OLD_DATA" "$REPLAY_OUT" 2>/dev/null; then
        fail "replay-log: head of log skipped (OLD_DATA absent)" \
             "no OLD_DATA" "OLD_DATA found"
    else
        ok "replay-log: head of log skipped (OLD_DATA absent)"
    fi

    rm -f "$REPLAY_OUT" "$REPLAY_LOG"
else
    ok "replay-log: skip (expect or python3 not available)"
    ok "replay-log: skip (expect or python3 not available)"
    ok "replay-log: skip (expect or python3 not available)"
fi

# ── 21. no-args → usage ──────────────────────────────────────────────────────

# Invoking with zero arguments calls usage() (exits 0, prints help).
# We already consumed the binary name in main, so argc < 1 → usage().
run "$ATCH"
assert_exit     "no args: exits 0 (usage)"           0 "$rc"
assert_contains "no args: shows Usage:"              "Usage:" "$out"

# ── 23. detach-status: S_IXUSR cleared immediately after MSG_DETACH ──────────
#
# Regression test for: when the client detaches (Ctrl+\), it must send
# MSG_DETACH to the master BEFORE calling exit(0).  This ensures the master
# clears the S_IXUSR bit on the socket synchronously (within one select cycle)
# so that `atch list` never races with a stale "[attached]" status.
#
# Without the fix, the client exits without MSG_DETACH; the master only learns
# about the detach when it receives EOF on the closed fd, which can arrive after
# a `list` reads the stale S_IXUSR bit — especially on loaded systems.
#
# Strategy: use Python to simulate the two scenarios:
#   A. MSG_DETACH sent before close  → socket must lose S_IXUSR immediately
#   B. Close without MSG_DETACH      → socket loses S_IXUSR after one master
#                                       select cycle (tolerated, but slower)
#
# The critical invariant tested here is scenario A: after MSG_DETACH is sent
# and acknowledged, `list` must NOT show "[attached]".  This is the exact
# behaviour enforced by the fix in process_kbd.

if command -v python3 >/dev/null 2>&1; then

    # Helper: send MSG_ATTACH, optionally MSG_DETACH, then close.
    # Usage: attach_and_detach <sock_path> <send_detach: 0|1>
    attach_and_detach() {
        python3 - "$1" "$2" << 'PYEOF'
import socket, struct, sys, time

sock_path = sys.argv[1]
send_detach = sys.argv[2] == '1'

MSG_ATTACH = 1
MSG_DETACH = 2

def pkt(msg_type):
    return struct.pack('BB8s', msg_type, 0, b'\x00' * 8)

s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
s.connect(sock_path)
s.sendall(pkt(MSG_ATTACH))
time.sleep(0.05)   # let master process MSG_ATTACH and set S_IXUSR
if send_detach:
    s.sendall(pkt(MSG_DETACH))
    time.sleep(0.05)  # let master process MSG_DETACH and clear S_IXUSR
s.close()
PYEOF
    }

    # --- single session: proper MSG_DETACH flow (scenario A) ---
    "$ATCH" start det-s1 sleep 999
    wait_socket det-s1
    SOCK1="$HOME/.cache/atch/det-s1"

    attach_and_detach "$SOCK1" 1   # send MSG_DETACH before close
    sleep 0.05                     # minimal delay after close

    run "$ATCH" list
    assert_not_contains \
        "detach-status: session not shown as attached after MSG_DETACH" \
        "[attached]" "$out"

    tidy det-s1

    # --- two sessions: reproduce the multi-session attach/detach cycle ---
    # Steps mirror the exact reproduction sequence from the bug report:
    #   create s1, detach, create s2, detach,
    #   attach s1, detach, attach s2, detach → none should show [attached]
    "$ATCH" start det-a sleep 999
    "$ATCH" start det-b sleep 999
    wait_socket det-a
    wait_socket det-b
    SOCKA="$HOME/.cache/atch/det-a"
    SOCKB="$HOME/.cache/atch/det-b"

    attach_and_detach "$SOCKA" 1
    sleep 0.05
    attach_and_detach "$SOCKB" 1
    sleep 0.05
    attach_and_detach "$SOCKA" 1
    sleep 0.05

    run "$ATCH" list
    assert_not_contains \
        "detach-status: det-a not [attached] after second detach cycle" \
        "[attached]" "$out"

    attach_and_detach "$SOCKB" 1
    sleep 0.05

    run "$ATCH" list
    assert_not_contains \
        "detach-status: det-b not [attached] after detach cycle" \
        "[attached]" "$out"

    tidy det-a
    tidy det-b

else
    ok "detach-status: skip (python3 not available)"
    ok "detach-status: skip (python3 not available)"
    ok "detach-status: skip (python3 not available)"
fi

# ── 24. start-inside-session: no [attached] when started from inside a session ──
#
# Regression test for: a session created with `atch start` from within an
# attached session must never appear as [attached] in `atch list`.
#
# Root cause: create_socket restored the original umask BEFORE calling bind(2).
# With a typical shell umask of 022, bind created the socket file with mode
# 0755 (S_IXUSR set).  chmod(0600) was called immediately after, but the
# tiny window between bind and chmod was enough for a concurrent `atch list`
# (or an immediate stat after start) to see the stale execute bit and report
# the session as [attached].
#
# Fix: use umask(0177) before bind so the socket is created directly as 0600
# (no execute bit ever present during creation).
#
# Test strategy:
#   A. Start outer-session so there is an [attached] session in the directory.
#   B. Simulate being inside outer-session by setting ATCH_SESSION.
#   C. Run `atch start inner-session` — no client must ever attach.
#   D. Check socket mode immediately: S_IXUSR must NOT be set.
#   E. Check `atch list`: inner-session must NOT show [attached].

"$ATCH" start sis-outer sleep 999
wait_socket sis-outer
SIS_OUTER_SOCK="$HOME/.cache/atch/sis-outer"

# Attach to outer via python so it shows [attached] — this mirrors the real
# scenario where the user is inside the outer session.
if command -v python3 >/dev/null 2>&1; then
    python3 - "$SIS_OUTER_SOCK" << 'PYEOF' &
import socket, struct, sys, time
s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
s.connect(sys.argv[1])
s.sendall(struct.pack('BB8s', 1, 0, b'\x00' * 8))  # MSG_ATTACH
time.sleep(15)
s.close()
PYEOF
    SIS_ATTACH_PID=$!
    sleep 0.1

    # Start inner-session as if we are inside outer-session (ATCH_SESSION set)
    ATCH_SESSION="$SIS_OUTER_SOCK" "$ATCH" start sis-inner sleep 999
    wait_socket sis-inner
    SIS_INNER_SOCK="$HOME/.cache/atch/sis-inner"

    # Check socket mode immediately after start: no S_IXUSR allowed.
    # The owner execute bit (S_IXUSR) is the bit 0 of the hundreds digit
    # in the 3-digit octal representation (i.e., digit is 1, 3, 5, or 7).
    # We extract the hundreds digit and test whether it is odd.
    SOCK_MODE=$(stat -c "%a" "$SIS_INNER_SOCK" 2>/dev/null || \
                stat -f "%Lp" "$SIS_INNER_SOCK" 2>/dev/null || echo "unknown")
    # Hundreds digit: remove last two chars → first char of 3-digit mode
    OWNER_DIGIT="${SOCK_MODE%??}"
    case "$OWNER_DIGIT" in
        1|3|5|7)
            fail "start-inside: socket mode must not have S_IXUSR" \
                 "owner digit 0,2,4 or 6 (no execute)" "$OWNER_DIGIT (mode $SOCK_MODE)" ;;
        *)
            ok "start-inside: socket created without S_IXUSR (mode $SOCK_MODE)" ;;
    esac

    # Check list: inner-session must NOT appear as [attached]
    run "$ATCH" list
    assert_not_contains \
        "start-inside: inner session not shown as [attached] in list" \
        "[attached]" \
        "$(echo "$out" | grep sis-inner)"

    kill $SIS_ATTACH_PID 2>/dev/null
    wait $SIS_ATTACH_PID 2>/dev/null

    tidy sis-outer
    tidy sis-inner
else
    ok "start-inside: skip (python3 not available)"
    ok "start-inside: skip (python3 not available)"
fi

# ── 25. auto-cleanup: atch list removes orphan sockets ───────────────────────
#
# US-005: When list_main encounters a socket that returns ECONNREFUSED
# (dead master), it must automatically unlink the socket and its associated
# .log and .ppid files.
#
# Strategy: use 'atch run' so the master runs in the foreground and we have
# its PID. Kill -9 to leave the socket on disk. Verify list shows [stale],
# then run list again and verify the socket has been removed.

"$ATCH" run ac-orphan sleep 99999 &
AC_ORPHAN_PID=$!
wait_socket ac-orphan
AC_SOCK="$HOME/.cache/atch/ac-orphan"

# Create a .ppid file so we can verify it gets cleaned too
printf "99999\n" > "${AC_SOCK}.ppid"

kill -9 "$AC_ORPHAN_PID" 2>/dev/null
# Also kill the sleep child so it doesn't linger
sleep 0.2

# First list call: socket is stale, must be listed and then removed
run "$ATCH" list
assert_contains "auto-cleanup: list detects orphan before cleanup" \
    "ac-orphan" "$out"

# After list, the socket file must be gone
if [ ! -e "$AC_SOCK" ]; then
    ok "auto-cleanup: list removes orphan socket"
else
    fail "auto-cleanup: list removes orphan socket" "socket removed" "socket still present"
fi

# .log file must be gone too (if it existed)
if [ ! -e "${AC_SOCK}.log" ]; then
    ok "auto-cleanup: list removes orphan .log"
else
    fail "auto-cleanup: list removes orphan .log" ".log removed" ".log still present"
fi

# .ppid file must be gone too
if [ ! -e "${AC_SOCK}.ppid" ]; then
    ok "auto-cleanup: list removes orphan .ppid"
else
    fail "auto-cleanup: list removes orphan .ppid" ".ppid removed" ".ppid still present"
fi

# Second list call: orphan gone, should no longer appear
run "$ATCH" list
assert_not_contains "auto-cleanup: orphan absent from list after cleanup" \
    "ac-orphan" "$out"

# ── 26. atch clean: explicit cleanup command ──────────────────────────────────
#
# 'atch clean' must:
#   a) remove all orphan sockets (ECONNREFUSED) and their .log/.ppid files
#   b) NOT remove live sessions
#   c) exit 0 and print a summary

# Create two orphan sockets by killing masters with -9
"$ATCH" run clean-orphan1 sleep 99999 &
CO1_PID=$!
wait_socket clean-orphan1
CO1_SOCK="$HOME/.cache/atch/clean-orphan1"

"$ATCH" run clean-orphan2 sleep 99999 &
CO2_PID=$!
wait_socket clean-orphan2
CO2_SOCK="$HOME/.cache/atch/clean-orphan2"

# Start a live session that must survive
"$ATCH" start clean-live sleep 999

kill -9 "$CO1_PID" 2>/dev/null
kill -9 "$CO2_PID" 2>/dev/null
sleep 0.2

# atch clean must exit 0
run "$ATCH" clean
assert_exit "clean: exits 0" 0 "$rc"

# Orphan sockets must be gone
if [ ! -e "$CO1_SOCK" ]; then
    ok "clean: removes orphan1 socket"
else
    fail "clean: removes orphan1 socket" "removed" "still present"
fi

if [ ! -e "$CO2_SOCK" ]; then
    ok "clean: removes orphan2 socket"
else
    fail "clean: removes orphan2 socket" "removed" "still present"
fi

# Live session must still be present
run "$ATCH" list
assert_contains "clean: live session survives cleanup" "clean-live" "$out"
assert_not_contains "clean: live session not marked dead" "[dead]" "$out"

tidy clean-live

# atch clean with -q must be silent
"$ATCH" run clean-quiet-orphan sleep 99999 &
CQ_PID=$!
wait_socket clean-quiet-orphan
kill -9 "$CQ_PID" 2>/dev/null
sleep 0.2

run "$ATCH" -q clean
assert_exit "clean -q: exits 0" 0 "$rc"
assert_eq   "clean -q: no output" "" "$out"

# ── 27. atch clean: no orphans prints message ─────────────────────────────────

run "$ATCH" clean
assert_exit "clean: no orphans → exits 0" 0 "$rc"
assert_contains "clean: no orphans → message" "no orphan" "$out"

# ── 28. rename command ───────────────────────────────────────────────────────
#
# US-008: `atch rename <old> <new>` must atomically rename socket + .log + .ppid
#
# Criteria:
#   a) Renames a live session: socket, .log, .ppid all renamed
#   b) After rename, old session name is gone from list, new name appears
#   c) Session remains functional after rename (can be killed by new name)
#   d) Dead sessions cannot be renamed
#   e) Missing session → error
#   f) Target name already exists → error

# 28a. rename a live session
"$ATCH" start rn-old sleep 999
wait_socket rn-old
RN_OLD_SOCK="$HOME/.cache/atch/rn-old"

# Verify .log and .ppid exist before rename
[ -f "${RN_OLD_SOCK}.log" ] && ok "rename: .log exists before rename" \
    || fail "rename: .log exists before rename" "file exists" "not found"
[ -f "${RN_OLD_SOCK}.ppid" ] && ok "rename: .ppid exists before rename" \
    || fail "rename: .ppid exists before rename" "file exists" "not found"

run "$ATCH" rename rn-old rn-new
assert_exit     "rename: live session → exit 0"         0 "$rc"
assert_contains "rename: confirmation message"          "renamed" "$out"

# Old files must be gone
[ ! -e "$RN_OLD_SOCK" ] && ok "rename: old socket removed" \
    || fail "rename: old socket removed" "removed" "still present"
[ ! -e "${RN_OLD_SOCK}.log" ] && ok "rename: old .log removed" \
    || fail "rename: old .log removed" "removed" "still present"
[ ! -e "${RN_OLD_SOCK}.ppid" ] && ok "rename: old .ppid removed" \
    || fail "rename: old .ppid removed" "removed" "still present"

# New files must exist
RN_NEW_SOCK="$HOME/.cache/atch/rn-new"
[ -S "$RN_NEW_SOCK" ] && ok "rename: new socket exists" \
    || fail "rename: new socket exists" "socket file" "not found"
[ -f "${RN_NEW_SOCK}.log" ] && ok "rename: new .log exists" \
    || fail "rename: new .log exists" "file exists" "not found"
[ -f "${RN_NEW_SOCK}.ppid" ] && ok "rename: new .ppid exists" \
    || fail "rename: new .ppid exists" "file exists" "not found"

# 28b. new name appears in list, old name does not
run "$ATCH" list
assert_contains     "rename: new name in list"          "rn-new" "$out"
assert_not_contains "rename: old name not in list"      "rn-old" "$out"

# 28c. session is still functional (killable by new name)
run "$ATCH" kill rn-new
assert_exit     "rename: kill by new name → exit 0"     0 "$rc"
assert_contains "rename: kill by new name → stopped"    "stopped" "$out"

# 28d. dead session cannot be renamed
"$ATCH" run rn-dead sleep 99999 &
RN_DEAD_PID=$!
wait_socket rn-dead
kill -9 "$RN_DEAD_PID" 2>/dev/null
sleep 0.2

run "$ATCH" rename rn-dead rn-dead2
assert_exit     "rename: dead session → exit 1"         1 "$rc"
assert_contains "rename: dead session → message"        "not running" "$out"
rm -f "$HOME/.cache/atch/rn-dead" "$HOME/.cache/atch/rn-dead.log" "$HOME/.cache/atch/rn-dead.ppid"

# 28e. missing session → error
run "$ATCH" rename rn-noexist rn-noexist2
assert_exit     "rename: missing session → exit 1"      1 "$rc"
assert_contains "rename: missing session → message"     "does not exist" "$out"

# 28f. target name already exists → error
"$ATCH" start rn-src sleep 999
"$ATCH" start rn-dst sleep 999
run "$ATCH" rename rn-src rn-dst
assert_exit     "rename: target exists → exit 1"        1 "$rc"
assert_contains "rename: target exists → message"       "already exists" "$out"
tidy rn-src
tidy rn-dst

# 28g. no args → error
run "$ATCH" rename
assert_exit     "rename: no args → exit 1"              1 "$rc"
assert_contains "rename: no args → message"             "No session was specified" "$out"

# 28h. one arg → error
run "$ATCH" rename rn-onearg
assert_exit     "rename: one arg → exit 1"              1 "$rc"

# ── 29. picker n=new: create session from interactive picker ──────────────────
#
# US-009: pressing 'n' in the interactive picker must:
#   a) show an inline prompt "New session name: "
#   b) create the session via start, then refresh the picker
#   c) empty name → ignored, return to picker
#   d) Escape → cancel, return to picker
#   e) help banner includes n=new
#
# Strategy: use expect(1) to drive the picker with a real PTY.
# Test requires at least one existing session so the picker is shown.

if command -v expect >/dev/null 2>&1; then

    # 29a. help banner includes n=new
    "$ATCH" start pn-banner sleep 999
    wait_socket pn-banner

    BANNER_OUT=$(mktemp)
    expect - << 'EXPECT_EOF' > "$BANNER_OUT" 2>&1
set timeout 3
spawn sh -c "exec $env(ATCH) list 2>&1"
sleep 1
send "\x1b"
expect eof
EXPECT_EOF

    if grep -q "n=new" "$BANNER_OUT"; then
        ok "picker-new: help banner contains n=new"
    else
        fail "picker-new: help banner contains n=new" "n=new in banner" "not found"
    fi
    rm -f "$BANNER_OUT"
    tidy pn-banner

    # 29b. n + session name → session created and appears in list
    "$ATCH" start pn-exist sleep 999
    wait_socket pn-exist

    PICKER_OUT=$(mktemp)
    expect - << 'EXPECT_EOF' > "$PICKER_OUT" 2>&1
set timeout 5
spawn sh -c "exec $env(ATCH) list 2>&1"
sleep 0.5
send "n"
sleep 0.5
send "pn-created\r"
sleep 1
send "\x1b"
expect eof
EXPECT_EOF

    # Verify the session was actually created
    run "$ATCH" list
    if echo "$out" | grep -q "pn-created"; then
        ok "picker-new: n + name creates session"
    else
        fail "picker-new: n + name creates session" "pn-created in list" "$out"
    fi
    rm -f "$PICKER_OUT"
    tidy pn-exist
    tidy pn-created

    # 29c. n + empty name (just Enter) → no session created
    "$ATCH" start pn-empty sleep 999
    wait_socket pn-empty

    # Count sessions before
    BEFORE_COUNT=$("$ATCH" list --no-picker 2>/dev/null | wc -l | tr -d ' ')

    PICKER_OUT=$(mktemp)
    expect - << 'EXPECT_EOF' > "$PICKER_OUT" 2>&1
set timeout 5
spawn sh -c "exec $env(ATCH) list 2>&1"
sleep 0.5
send "n"
sleep 0.5
send "\r"
sleep 0.5
send "\x1b"
expect eof
EXPECT_EOF

    # Count sessions after — must be same
    AFTER_COUNT=$("$ATCH" list --no-picker 2>/dev/null | wc -l | tr -d ' ')
    if [ "$BEFORE_COUNT" = "$AFTER_COUNT" ]; then
        ok "picker-new: n + empty name → no session created"
    else
        fail "picker-new: n + empty name → no session created" \
             "$BEFORE_COUNT sessions" "$AFTER_COUNT sessions"
    fi
    rm -f "$PICKER_OUT"
    tidy pn-empty

    # 29d. n + Escape → cancel, no session created
    "$ATCH" start pn-esc sleep 999
    wait_socket pn-esc

    BEFORE_COUNT=$("$ATCH" list --no-picker 2>/dev/null | wc -l | tr -d ' ')

    PICKER_OUT=$(mktemp)
    expect - << 'EXPECT_EOF' > "$PICKER_OUT" 2>&1
set timeout 5
spawn sh -c "exec $env(ATCH) list 2>&1"
sleep 0.5
send "n"
sleep 0.5
send "\x1b"
sleep 0.5
send "\x1b"
expect eof
EXPECT_EOF

    AFTER_COUNT=$("$ATCH" list --no-picker 2>/dev/null | wc -l | tr -d ' ')
    if [ "$BEFORE_COUNT" = "$AFTER_COUNT" ]; then
        ok "picker-new: n + Escape → no session created"
    else
        fail "picker-new: n + Escape → no session created" \
             "$BEFORE_COUNT sessions" "$AFTER_COUNT sessions"
    fi
    rm -f "$PICKER_OUT"
    tidy pn-esc

else
    ok "picker-new: skip (expect not available)"
    ok "picker-new: skip (expect not available)"
    ok "picker-new: skip (expect not available)"
    ok "picker-new: skip (expect not available)"
fi

# ── summary ──────────────────────────────────────────────────────────────────

printf "\n1..%d\n" "$T"
printf "# %d passed, %d failed\n" "$PASS" "$FAIL"

[ "$FAIL" -eq 0 ]
