#include "atch.h"

#ifndef VDISABLE
#ifdef _POSIX_VDISABLE
#define VDISABLE _POSIX_VDISABLE
#else
#define VDISABLE 0377
#endif
#endif

/* ── ancestry helpers ────────────────────────────────────────────────────── */

/*
** Return the parent PID of 'pid'.
** Returns 0 on failure (pid not found or permission denied).
** Portable across Linux (/proc) and macOS (libproc / sysctl).
*/
#ifdef __APPLE__
#include <libproc.h>
static pid_t get_parent_pid(pid_t pid)
{
	struct proc_bsdinfo info;

	if (proc_pidinfo(pid, PROC_PIDTBSDINFO, 0,
			 &info, sizeof(info)) <= 0)
		return 0;
	return (pid_t)info.pbi_ppid;
}
#else
static pid_t get_parent_pid(pid_t pid)
{
	char path[64];
	FILE *f;
	pid_t ppid = 0;
	char line[256];

	snprintf(path, sizeof(path), "/proc/%d/status", (int)pid);
	f = fopen(path, "r");
	if (!f)
		return 0;
	while (fgets(line, sizeof(line), f)) {
		if (sscanf(line, "PPid: %d", &ppid) == 1)
			break;
	}
	fclose(f);
	return ppid;
}
#endif

/*
** Return 1 if 'ancestor_pid' is equal to, or an ancestor of, 'child_pid'.
** Walks the process tree upward; gives up after 1024 steps to avoid loops.
*/
static int is_ancestor(pid_t ancestor_pid, pid_t child_pid)
{
	pid_t p = child_pid;
	int steps = 0;

	while (p > 1 && steps < 1024) {
		if (p == ancestor_pid)
			return 1;
		p = get_parent_pid(p);
		steps++;
	}
	/* Also check the final value (handles the p == ancestor_pid == 1 edge) */
	return (p == ancestor_pid);
}

/*
** Read the session shell PID from '<sockpath>.ppid'.
** Returns 0 if the file does not exist or cannot be read.
*/
static pid_t read_session_ppid(const char *sockpath)
{
	char ppid_path[600];
	FILE *f;
	long pid = 0;

	snprintf(ppid_path, sizeof(ppid_path), "%s.ppid", sockpath);
	f = fopen(ppid_path, "r");
	if (!f)
		return 0;
	if (fscanf(f, "%ld", &pid) != 1)
		pid = 0;
	fclose(f);
	return (pid > 0) ? (pid_t)pid : 0;
}

/*
** Return 1 if the current process is genuinely running inside the session
** whose socket path is 'sockpath'.
**
** The check reads '<sockpath>.ppid' (written by the master when it forks
** the pty child) and tests whether that PID is an ancestor of the calling
** process.  If the file is absent or the PID is no longer an ancestor,
** the ATCH_SESSION variable is considered stale and the guard is skipped.
*/
static int session_is_ancestor(const char *sockpath)
{
	pid_t shell_pid = read_session_ppid(sockpath);

	if (shell_pid <= 0)
		return 0;	/* no .ppid file → assume stale */
	return is_ancestor(shell_pid, getpid());
}

/* ─────────────────────────────────────────────────────────────────────────── */

/*
** The current terminal settings. After coming back from a suspend, we
** restore this.
*/
static struct termios cur_term;
/* 1 if the window size changed */
static int win_changed;
/* Socket creation time, used to compute session age in messages. */
time_t session_start;

char const *clear_csi_data(void)
{
	if (no_ansiterm || clear_method == CLEAR_NONE ||
	    (clear_method == CLEAR_UNSPEC && dont_have_tty))
		return "\r\n";
	/* CLEAR_MOVE, or CLEAR_UNSPEC with a real tty: move to bottom */
	return "\033[999H\r\n";
}

/* Write buf to fd handling partial writes. Exit on failure. */
void write_buf_or_fail(int fd, const void *buf, size_t count)
{
	while (count != 0) {
		ssize_t ret = write(fd, buf, count);

		if (ret >= 0) {
			buf = (const char *)buf + ret;
			count -= ret;
		} else if (ret < 0 && errno == EINTR)
			continue;
		else {
			if (session_start) {
				char age[32];
				session_age(age, sizeof(age));
				printf
				    ("%s[%s: session '%s' write failed after %s]\r\n",
				     clear_csi_data(), progname,
				     session_shortname(), age);
			} else {
				printf("%s[%s: write failed]\r\n",
				       clear_csi_data(), progname);
			}
			exit(1);
		}
	}
}

/* Write pkt to fd. Exit on failure. */
void write_packet_or_fail(int fd, const struct packet *pkt)
{
	while (1) {
		ssize_t ret = write(fd, pkt, sizeof(struct packet));

		if (ret == sizeof(struct packet))
			return;
		else if (ret < 0 && errno == EINTR)
			continue;
		else {
			if (session_start) {
				char age[32];
				session_age(age, sizeof(age));
				printf
				    ("%s[%s: session '%s' write failed after %s]\r\n",
				     clear_csi_data(), progname,
				     session_shortname(), age);
			} else {
				printf("%s[%s: write failed]\r\n",
				       clear_csi_data(), progname);
			}
			exit(1);
		}
	}
}

/* Restores the original terminal settings. */
static void restore_term(void)
{
	tcsetattr(0, TCSADRAIN, &orig_term);
	if (!no_ansiterm) {
		printf("\033[0m\033[?25h");
	}
	fflush(stdout);
	if (no_ansiterm)
		(void)system("tput init 2>/dev/null");
}

/* Connects to a unix domain socket */
static int connect_socket(char *name)
{
	int s;
	struct sockaddr_un sockun;

	if (strlen(name) > sizeof(sockun.sun_path) - 1)
		return socket_with_chdir(name, connect_socket);

	s = socket(PF_UNIX, SOCK_STREAM, 0);
	if (s < 0)
		return -1;
	sockun.sun_family = AF_UNIX;
	memcpy(sockun.sun_path, name, strlen(name) + 1);
	if (connect(s, (struct sockaddr *)&sockun, sizeof(sockun)) < 0) {
		close(s);

		/* ECONNREFUSED is also returned for regular files, so make
		 ** sure we are trying to connect to a socket. */
		if (errno == ECONNREFUSED) {
			struct stat st;

			if (stat(name, &st) < 0)
				return -1;
			else if (!S_ISSOCK(st.st_mode))
				errno = ENOTSOCK;
		}
		return -1;
	}
	return s;
}

void format_age(time_t secs, char *buf, size_t size)
{
	int d = (int)(secs / 86400);
	int h = (int)((secs % 86400) / 3600);
	int m = (int)((secs % 3600) / 60);
	int s = (int)(secs % 60);

	if (d > 0)
		snprintf(buf, size, "%dd %dh %dm %ds", d, h, m, s);
	else if (h > 0)
		snprintf(buf, size, "%dh %dm %ds", h, m, s);
	else if (m > 0)
		snprintf(buf, size, "%dm %ds", m, s);
	else
		snprintf(buf, size, "%ds", s);
}

void session_age(char *buf, size_t size)
{
	time_t now = time(NULL);
	format_age(now > session_start ? now - session_start : 0, buf, size);
}

/* Signal */
static RETSIGTYPE die(int sig)
{
	char age[32];
	session_age(age, sizeof(age));
	/* Print a nice pretty message for some things. */
	if (sig == SIGHUP || sig == SIGINT)
		printf("%s[%s: session '%s' detached after %s]\r\n",
		       clear_csi_data(), progname, session_shortname(), age);
	else
		printf
		    ("%s[%s: session '%s' got signal %d - exiting after %s]\r\n",
		     clear_csi_data(), progname, session_shortname(), sig, age);
	exit(1);
}

/* Window size change. */
static RETSIGTYPE win_change(ATTRIBUTE_UNUSED int sig)
{
	signal(SIGWINCH, win_change);
	win_changed = 1;
}

/* Handles input from the keyboard. */
static void process_kbd(int s, struct packet *pkt)
{
	/* Suspend? */
	if (!no_suspend && (pkt->u.buf[0] == cur_term.c_cc[VSUSP])) {
		/* Tell the master that we are suspending. */
		pkt->type = MSG_DETACH;
		write_packet_or_fail(s, pkt);

		/* And suspend... */
		tcsetattr(0, TCSADRAIN, &orig_term);
		printf("%s", clear_csi_data());
		kill(getpid(), SIGTSTP);
		tcsetattr(0, TCSADRAIN, &cur_term);

		/* Tell the master that we are returning. */
		pkt->type = MSG_ATTACH;
		pkt->len = 0;	/* normal ring replay on resume */
		write_packet_or_fail(s, pkt);

		/* We would like a redraw, too. */
		pkt->type = MSG_REDRAW;
		pkt->len = redraw_method;
		ioctl(0, TIOCGWINSZ, &pkt->u.ws);
		write_packet_or_fail(s, pkt);
		return;
	}
	/* Detach char? */
	else if (pkt->u.buf[0] == detach_char) {
		char age[32];
		session_age(age, sizeof(age));
		/* Tell the master we are detaching so it clears S_IXUSR on
		 * the socket immediately, before this process exits.
		 * Without this, the master only learns about the detach when
		 * it receives EOF on close(), which can race with a concurrent
		 * `atch list` reading the stale S_IXUSR bit. */
		pkt->type = MSG_DETACH;
		write_packet_or_fail(s, pkt);
		printf("%s[%s: session '%s' detached after %s]\r\n",
		       clear_csi_data(), progname, session_shortname(), age);
		exit(0);
	}
	/* Just in case something pukes out. */
	else if (pkt->u.buf[0] == '\f')
		win_changed = 1;

	/* Push it out */
	write_packet_or_fail(s, pkt);
}

/* Set to 1 once we have replayed the on-disk log, so attach_main
** knows not to replay it a second time. */
static int log_already_replayed;

/* Replay sockname+".log" to stdout, if it exists.
** saved_errno is from the failed connect: ECONNREFUSED means the session was
** killed/crashed (socket still on disk), ENOENT means clean exit (socket was
** unlinked; end marker is already in the log).
** Pass 0 when replaying for a running session (no end message printed).
** Returns 1 if a log was found and replayed, 0 if no log exists.
**
** Only the last SCROLLBACK_SIZE bytes of the log are replayed to avoid
** overwhelming the terminal when attaching to a session with a large log
** (e.g. a long-running build).  This matches the in-memory ring-buffer cap
** used when replaying a live session's scrollback. */
int replay_session_log(int saved_errno)
{
	char log_path[600];
	int logfd;
	const char *name;

	snprintf(log_path, sizeof(log_path), "%s.log", sockname);
	logfd = open(log_path, O_RDONLY);
	if (logfd < 0)
		return 0;

	{
		unsigned char rbuf[BUFSIZE];
		ssize_t n;
		off_t log_size;

		/* Seek to the last SCROLLBACK_SIZE bytes so that a very large
		 * log (e.g. from a long build session) does not flood the
		 * terminal.  If the log is smaller than SCROLLBACK_SIZE, start
		 * from the beginning. */
		log_size = lseek(logfd, 0, SEEK_END);
		if (log_size > (off_t)SCROLLBACK_SIZE)
			lseek(logfd, log_size - (off_t)SCROLLBACK_SIZE,
			      SEEK_SET);
		else
			lseek(logfd, 0, SEEK_SET);

		while ((n = read(logfd, rbuf, sizeof(rbuf))) > 0)
			write(1, rbuf, (size_t)n);
		close(logfd);
	}

	/* Socket still on disk = killed/crashed; clean exit already wrote its
	 * end marker into the log, so no extra message needed. */
	if (saved_errno == ECONNREFUSED) {
		name = session_shortname();
		printf("%s[%s: session '%s' ended unexpectedly]\r\n",
		       clear_csi_data(), progname, name);
	}
	log_already_replayed = 1;
	return 1;
}

/*
** Check whether attaching to 'sockname' would be a self-attach (i.e. the
** current process is running inside that session's ancestry chain).
**
** Returns 1 and prints an error if a genuine self-attach is detected.
** Returns 0 if the attach may proceed.
**
** Called before require_tty() so that the correct diagnostic is shown even
** when there is no terminal available.
*/
int check_attach_ancestry(void)
{
	const char *tosearch = getenv(SESSION_ENVVAR);

	if (!tosearch || !*tosearch)
		return 0;

	{
		size_t slen = strlen(sockname);
		const char *p = tosearch;

		while (*p) {
			const char *colon = strchr(p, ':');
			size_t tlen =
			    colon ? (size_t)(colon - p) : strlen(p);

			if (tlen == slen
			    && strncmp(p, sockname, tlen) == 0) {
				/* Verify we are genuinely inside this
				 * session before blocking the attach.
				 * session_is_ancestor() reads the .ppid
				 * file written by the master and checks
				 * the process ancestry; if the file is
				 * absent or the PID is not an ancestor,
				 * ATCH_SESSION is stale → allow attach. */
				if (session_is_ancestor(sockname)) {
					printf
					    ("%s: cannot attach to session '%s' from within itself\n",
					     progname, session_shortname());
					return 1;
				}
				/* Stale ATCH_SESSION — fall through. */
			}
			if (!colon)
				break;
			p = colon + 1;
		}
	}
	return 0;
}

int attach_main(int noerror)
{
	struct packet pkt;
	unsigned char buf[BUFSIZE];
	fd_set readfds;
	int s;

	/* Refuse to attach to any session in our ancestry chain (catches both
	 * direct self-attach and indirect loops like A -> B -> A).
	 * SESSION_ENVVAR is the colon-separated chain, so scanning it covers
	 * all ancestors.
	 *
	 * The check is performed via check_attach_ancestry(), which is also
	 * called early in the command handlers (before require_tty) so the
	 * correct error is shown even without a terminal. */
	if (check_attach_ancestry())
		return 1;

	/* Attempt to open the socket. Don't display an error if noerror is
	 ** set. */
	s = connect_socket(sockname);
	if (s < 0) {
		int saved_errno = errno;
		const char *name = session_shortname();

		if (!noerror) {
			if (!replay_session_log(saved_errno)) {
				if (saved_errno == ENOENT)
					printf
					    ("%s: session '%s' does not exist\n",
					     progname, name);
				else if (saved_errno == ECONNREFUSED)
					printf
					    ("%s: session '%s' is not running\n",
					     progname, name);
				else if (saved_errno == ENOTSOCK)
					printf
					    ("%s: '%s' is not a valid session\n",
					     progname, name);
				else
					printf("%s: %s: %s\n", progname,
					       sockname, strerror(saved_errno));
			}
		}
		return 1;
	}

	/* Replay the on-disk log so the user sees full session history.
	 ** Skip if already replayed by the error path (exited-session case). */
	int skip_ring = 0;
	if (!log_already_replayed && replay_session_log(0))
		skip_ring = 1;

	/* Record session start time from the socket file's ctime. */
	{
		struct stat st;
		session_start =
		    (stat(sockname, &st) == 0) ? st.st_mtime : time(NULL);
	}

	/* The current terminal settings are equal to the original terminal
	 ** settings at this point. */
	cur_term = orig_term;

	/* Set a trap to restore the terminal when we die. */
	atexit(restore_term);

	/* Set some signals. */
	signal(SIGPIPE, SIG_IGN);
	signal(SIGXFSZ, SIG_IGN);
	signal(SIGHUP, die);
	signal(SIGTERM, die);
	signal(SIGINT, die);
	signal(SIGQUIT, die);
	signal(SIGWINCH, win_change);

	/* Set raw mode. */
	cur_term.c_iflag &=
	    ~(IGNBRK | BRKINT | PARMRK | ISTRIP | INLCR | IGNCR | ICRNL);
	cur_term.c_iflag &= ~(IXON | IXOFF);
	cur_term.c_oflag &= ~(OPOST);
	cur_term.c_lflag &= ~(ECHO | ECHONL | ICANON | ISIG | IEXTEN);
	cur_term.c_cflag &= ~(CSIZE | PARENB);
	cur_term.c_cflag |= CS8;
	cur_term.c_cc[VLNEXT] = VDISABLE;
	cur_term.c_cc[VMIN] = 1;
	cur_term.c_cc[VTIME] = 0;
	tcsetattr(0, TCSADRAIN, &cur_term);

	/* Clear the screen on attach. Only do a full reset when explicitly
	 ** requested (CLEAR_MOVE); default/unspec just emits a blank line so
	 ** any preceding log replay remains visible.
	 ** When log replay was done for a running session (skip_ring=1), skip
	 ** the separator: the log ends at the exact pty cursor position, so
	 ** the prompt is already visible and correctly placed. */
	if (clear_method == CLEAR_MOVE && !no_ansiterm) {
		write_buf_or_fail(1, "\033c", 2);
	} else if (!quiet && !skip_ring) {
		write_buf_or_fail(1, "\r\n", 2);
	}

	/* Tell the master that we want to attach.
	 ** pkt.len=1 means the client already loaded the log; master skips
	 ** the in-memory ring replay to avoid showing history twice. */
	memset(&pkt, 0, sizeof(struct packet));
	pkt.type = MSG_ATTACH;
	pkt.len = skip_ring;
	write_packet_or_fail(s, &pkt);

	/* We would like a redraw, too. */
	pkt.type = MSG_REDRAW;
	pkt.len = redraw_method;
	ioctl(0, TIOCGWINSZ, &pkt.u.ws);
	write_packet_or_fail(s, &pkt);

	/* Wait for things to happen */
	while (1) {
		int n;

		FD_ZERO(&readfds);
		FD_SET(0, &readfds);
		FD_SET(s, &readfds);
		n = select(s + 1, &readfds, NULL, NULL, NULL);
		if (n < 0 && errno != EINTR && errno != EAGAIN) {
			char age[32];
			session_age(age, sizeof(age));
			printf
			    ("%s[%s: session '%s' select failed after %s]\r\n",
			     clear_csi_data(), progname, session_shortname(),
			     age);
			exit(1);
		}

		/* Pty activity */
		if (n > 0 && FD_ISSET(s, &readfds)) {
			ssize_t len = read(s, buf, sizeof(buf));

			if (len == 0) {
				if (!quiet) {
					char age[32];
					session_age(age, sizeof(age));
					printf
					    ("%s[%s: session '%s' exited after %s]\r\n",
					     clear_csi_data(), progname,
					     session_shortname(), age);
				}
				exit(0);
			} else if (len < 0) {
				char age[32];
				session_age(age, sizeof(age));
				printf
				    ("%s[%s: session '%s' read error after %s]\r\n",
				     clear_csi_data(), progname,
				     session_shortname(), age);
				exit(1);
			}
			/* Send the data to the terminal. */
			write_buf_or_fail(1, buf, len);
			n--;
		}
		/* stdin activity */
		if (n > 0 && FD_ISSET(0, &readfds)) {
			ssize_t len;

			pkt.type = MSG_PUSH;
			memset(pkt.u.buf, 0, sizeof(pkt.u.buf));
			len = read(0, pkt.u.buf, sizeof(pkt.u.buf));

			if (len <= 0)
				exit(1);

			pkt.len = len;
			process_kbd(s, &pkt);
			n--;
		}

		/* Window size changed? */
		if (win_changed) {
			win_changed = 0;

			pkt.type = MSG_WINCH;
			ioctl(0, TIOCGWINSZ, &pkt.u.ws);
			write_packet_or_fail(s, &pkt);
		}
	}
	return 0;
}

int push_main()
{
	struct packet pkt;
	int s;

	/* Attempt to open the socket. */
	s = connect_socket(sockname);
	if (s < 0) {
		printf("%s: %s: %s\n", progname, sockname, strerror(errno));
		return 1;
	}

	/* Set some signals. */
	signal(SIGPIPE, SIG_IGN);

	/* Push the contents of standard input to the socket. */
	pkt.type = MSG_PUSH;
	for (;;) {
		ssize_t len;

		memset(pkt.u.buf, 0, sizeof(pkt.u.buf));
		len = read(0, pkt.u.buf, sizeof(pkt.u.buf));

		if (len == 0)
			return 0;
		else if (len < 0) {
			printf("%s: %s: %s\n", progname, sockname,
			       strerror(errno));
			return 1;
		}

		pkt.len = len;
		len = write(s, &pkt, sizeof(struct packet));
		if (len != sizeof(struct packet)) {
			if (len >= 0)
				errno = EPIPE;

			printf("%s: %s: %s\n", progname, sockname,
			       strerror(errno));
			return 1;
		}
	}
}

static int send_kill(int sig)
{
	struct packet pkt;
	int s;
	ssize_t ret;

	s = connect_socket(sockname);
	if (s < 0)
		return -1;
	memset(&pkt, 0, sizeof(pkt));
	pkt.type = MSG_KILL;
	pkt.len = (unsigned char)sig;
	ret = write(s, &pkt, sizeof(pkt));
	close(s);
	return (ret == sizeof(pkt)) ? 0 : -1;
}

static int session_gone(void)
{
	struct stat st;
	return stat(sockname, &st) < 0 && errno == ENOENT;
}

/*
** Return 1 if the session is gone (socket removed) or dead (socket exists
** but master is no longer listening — ECONNREFUSED).  The latter happens
** when a session was renamed: the master's cleanup_session unlinks the old
** path, leaving the new-named socket as an orphan.
**
** If the socket is an orphan, remove it and its associated files.
*/
static int session_gone_or_dead(void)
{
	int s;
	struct sockaddr_un sockun;

	if (session_gone())
		return 1;

	/* Socket exists — try to connect */
	if (strlen(sockname) > sizeof(sockun.sun_path) - 1)
		return 0;	/* path too long, can't check */
	s = socket(PF_UNIX, SOCK_STREAM, 0);
	if (s < 0)
		return 0;
	sockun.sun_family = AF_UNIX;
	memcpy(sockun.sun_path, sockname, strlen(sockname) + 1);
	if (connect(s, (struct sockaddr *)&sockun, sizeof(sockun)) < 0) {
		close(s);
		if (errno == ECONNREFUSED) {
			/* Master is gone — clean up orphan */
			char assoc[800];

			unlink(sockname);
			snprintf(assoc, sizeof(assoc), "%s.log", sockname);
			unlink(assoc);
			snprintf(assoc, sizeof(assoc), "%s.ppid", sockname);
			unlink(assoc);
			return 1;
		}
		return 0;
	}
	close(s);
	return 0;		/* still alive */
}

int kill_main(int force)
{
	const char *name = session_shortname();
	int i;

	signal(SIGPIPE, SIG_IGN);

	if (force) {
		/* Skip the grace period — send SIGKILL immediately. */
		if (send_kill(SIGKILL) < 0) {
			if (errno == ENOENT)
				printf("%s: session '%s' does not exist\n",
				       progname, name);
			else if (errno == ECONNREFUSED)
				printf("%s: session '%s' is not running\n",
				       progname, name);
			else
				printf("%s: %s: %s\n", progname, sockname,
				       strerror(errno));
			return 1;
		}
		for (i = 0; i < 20; i++) {
			usleep(100000);
			if (session_gone_or_dead()) {
				if (!quiet)
					printf("%s: session '%s' killed\n",
					       progname, name);
				return 0;
			}
		}
		printf("%s: session '%s' did not stop\n", progname, name);
		return 1;
	}

	if (send_kill(SIGTERM) < 0) {
		if (errno == ENOENT)
			printf("%s: session '%s' does not exist\n",
			       progname, name);
		else if (errno == ECONNREFUSED)
			printf("%s: session '%s' is not running\n",
			       progname, name);
		else
			printf("%s: %s: %s\n", progname, sockname,
			       strerror(errno));
		return 1;
	}

	/* Wait up to 5 seconds for graceful exit. */
	for (i = 0; i < 50; i++) {
		usleep(100000);
		if (session_gone_or_dead()) {
			printf("%s: session '%s' stopped\n", progname, name);
			return 0;
		}
	}

	/* Still alive — escalate to SIGKILL. */
	send_kill(SIGKILL);

	for (i = 0; i < 20; i++) {
		usleep(100000);
		if (session_gone_or_dead()) {
			printf("%s: session '%s' killed\n", progname, name);
			return 0;
		}
	}

	printf("%s: session '%s' did not stop\n", progname, name);
	return 1;
}

/*
** Rename a session: socket, .log, and .ppid files.
** Both old_path and new_path must be full paths.
** The session must be alive (connectable). Dead sessions cannot be renamed.
** Returns 0 on success, 1 on error (message already printed).
*/
int rename_main(const char *old_path, const char *new_path)
{
	char old_assoc[800], new_assoc[800];
	const char *old_name, *new_name;
	struct stat st;
	int s;

	old_name = strrchr(old_path, '/');
	old_name = old_name ? old_name + 1 : old_path;
	new_name = strrchr(new_path, '/');
	new_name = new_name ? new_name + 1 : new_path;

	/* Check source exists */
	if (stat(old_path, &st) < 0 || !S_ISSOCK(st.st_mode)) {
		printf("%s: session '%s' does not exist\n", progname, old_name);
		return 1;
	}

	/* Check source is alive */
	s = socket(PF_UNIX, SOCK_STREAM, 0);
	if (s >= 0) {
		struct sockaddr_un sockun;

		sockun.sun_family = AF_UNIX;
		memcpy(sockun.sun_path, old_path, strlen(old_path) + 1);
		if (connect(s, (struct sockaddr *)&sockun, sizeof(sockun)) < 0) {
			close(s);
			printf("%s: session '%s' is not running\n",
			       progname, old_name);
			return 1;
		}
		close(s);
	}

	/* Check target does not exist */
	if (stat(new_path, &st) == 0) {
		printf("%s: session '%s' already exists\n", progname, new_name);
		return 1;
	}

	/* Rename socket */
	if (rename(old_path, new_path) < 0) {
		printf("%s: rename '%s' to '%s': %s\n", progname,
		       old_name, new_name, strerror(errno));
		return 1;
	}

	/* Rename .log (best-effort) */
	snprintf(old_assoc, sizeof(old_assoc), "%s.log", old_path);
	snprintf(new_assoc, sizeof(new_assoc), "%s.log", new_path);
	rename(old_assoc, new_assoc);

	/* Rename .ppid (best-effort) */
	snprintf(old_assoc, sizeof(old_assoc), "%s.ppid", old_path);
	snprintf(new_assoc, sizeof(new_assoc), "%s.ppid", new_path);
	rename(old_assoc, new_assoc);

	if (!quiet)
		printf("%s: session '%s' renamed to '%s'\n",
		       progname, old_name, new_name);
	return 0;
}

/* Remove an orphan socket and its associated .log and .ppid files. */
static void remove_orphan(const char *path)
{
	char assoc[800];

	unlink(path);
	snprintf(assoc, sizeof(assoc), "%s.log", path);
	unlink(assoc);
	snprintf(assoc, sizeof(assoc), "%s.ppid", path);
	unlink(assoc);
}

/* Session entry for the picker / list. */
struct session_entry {
	char name[256];
	char label[512];	/* pre-formatted display line */
	int dead;		/* 1 if orphan (ECONNREFUSED) */
};

#define MAX_SESSIONS 256

/*
** Collect all sessions in dir into entries[].  Orphan sockets (dead masters)
** are auto-cleaned (socket + .log + .ppid removed) and marked dead=1.
** Returns the number of entries collected.
*/
static int collect_sessions(const char *dir, struct session_entry *entries,
			    int max)
{
	char path[768];
	DIR *d;
	struct dirent *ent;
	time_t now = time(NULL);
	int count = 0;

	d = opendir(dir);
	if (!d)
		return 0;

	while ((ent = readdir(d)) != NULL && count < max) {
		struct stat st;
		char age[32];
		int s;

		if (ent->d_name[0] == '.')
			continue;
		snprintf(path, sizeof(path), "%s/%s", dir, ent->d_name);
		if (stat(path, &st) < 0 || !S_ISSOCK(st.st_mode))
			continue;

		format_age(now > st.st_mtime ? now - st.st_mtime : 0,
			   age, sizeof(age));

		s = connect_socket(path);
		if (s >= 0) {
			int attached = st.st_mode & S_IXUSR;
			close(s);
			snprintf(entries[count].name,
				 sizeof(entries[count].name), "%s",
				 ent->d_name);
			if (attached)
				snprintf(entries[count].label,
					 sizeof(entries[count].label),
					 "%-24s since %s ago [attached]",
					 ent->d_name, age);
			else
				snprintf(entries[count].label,
					 sizeof(entries[count].label),
					 "%-24s since %s ago",
					 ent->d_name, age);
			entries[count].dead = 0;
			count++;
		} else if (errno == ECONNREFUSED) {
			snprintf(entries[count].name,
				 sizeof(entries[count].name), "%s",
				 ent->d_name);
			snprintf(entries[count].label,
				 sizeof(entries[count].label),
				 "%-24s since %s ago [dead]",
				 ent->d_name, age);
			entries[count].dead = 1;
			remove_orphan(path);
			count++;
		}
	}

	closedir(d);
	return count;
}

/*
** Read a line of input in raw mode, echoing to stderr.
** Handles backspace. Returns the number of characters read,
** or -1 if the user pressed Escape to cancel.
** buf must be at least 'size' bytes.
*/
static int picker_readline(char *buf, int size)
{
	int pos = 0;
	unsigned char c;

	memset(buf, 0, (size_t)size);
	while (pos < size - 1) {
		if (read(0, &c, 1) != 1)
			return -1;
		if (c == 27)
			return -1;	/* Escape = cancel */
		if (c == '\r' || c == '\n')
			break;
		if (c == 127 || c == 8) {
			/* Backspace */
			if (pos > 0) {
				pos--;
				fprintf(stderr, "\b \b");
			}
			continue;
		}
		if (c == 3)
			return -1;	/* Ctrl-C = cancel */
		if (c < 32)
			continue;	/* Ignore other control chars */
		buf[pos++] = (char)c;
		fprintf(stderr, "%c", c);
	}
	buf[pos] = '\0';
	return pos;
}

/*
** Interactive picker: display sessions with arrow-key navigation.
** Enter selects a live session (execvp to atch attach <session>).
** k = kill selected session (with y/N confirmation).
** r = rename selected session (inline prompt).
** Escape / Ctrl-C exits without attaching.
** Dead sessions are shown but not selectable for attach/rename.
** Returns 0 on Escape/Ctrl-C, or does not return on Enter (execvp).
*/
static int interactive_picker(struct session_entry *entries, int count)
{
	struct termios orig, raw;
	int sel = 0;
	int i;
	unsigned char c;
	char dir[512];
	/* +1 for help banner line */
	int display_lines;

	get_session_dir(dir, sizeof(dir));

	/* Skip to the first non-dead session if possible. */
	for (i = 0; i < count; i++) {
		if (!entries[i].dead) {
			sel = i;
			break;
		}
	}

	/* Enter raw mode on stdin (fd 0). */
	if (tcgetattr(0, &orig) < 0)
		return 1;
	raw = orig;
	raw.c_lflag &= ~(ICANON | ECHO | ISIG);
	raw.c_cc[VMIN] = 1;
	raw.c_cc[VTIME] = 0;
	tcsetattr(0, TCSADRAIN, &raw);

	/* Hide cursor */
	fprintf(stderr, "\033[?25l");

	for (;;) {
		/* Render list */
		for (i = 0; i < count; i++) {
			if (i == sel && !entries[i].dead)
				fprintf(stderr, "\033[7m> %s\033[0m\r\n",
					entries[i].label);
			else if (entries[i].dead)
				fprintf(stderr, "\033[2m  %s\033[0m\r\n",
					entries[i].label);
			else
				fprintf(stderr, "  %s\r\n",
					entries[i].label);
		}

		/* Help banner */
		fprintf(stderr,
			"\033[2mEnter=attach  k=kill  r=rename  Esc=quit\033[0m\r\n");
		display_lines = count + 1;

		/* Read a key */
		if (read(0, &c, 1) != 1)
			break;

		if (c == 27) {
			/* Escape sequence or bare Escape */
			unsigned char seq[2];
			if (read(0, &seq[0], 1) == 1 && seq[0] == '[') {
				if (read(0, &seq[1], 1) == 1) {
					if (seq[1] == 'A') {
						/* Up arrow */
						int j = sel - 1;
						while (j >= 0 &&
						       entries[j].dead)
							j--;
						if (j >= 0)
							sel = j;
					} else if (seq[1] == 'B') {
						/* Down arrow */
						int j = sel + 1;
						while (j < count &&
						       entries[j].dead)
							j++;
						if (j < count)
							sel = j;
					}
				}
			} else if (seq[0] != '[') {
				/* Bare Escape key */
				break;
			}
		} else if (c == '\r' || c == '\n') {
			/* Enter: attach to the selected session */
			if (!entries[sel].dead) {
				/* Restore terminal, show cursor */
				tcsetattr(0, TCSADRAIN, &orig);
				fprintf(stderr, "\033[?25h");
				fflush(stderr);
				/* execvp to atch attach <session> */
				{
					char *args[4];
					args[0] = progname;
					args[1] = (char *)"attach";
					args[2] = entries[sel].name;
					args[3] = NULL;
					execvp(progname, args);
				}
				/* If execvp fails, fall through */
				perror(progname);
				return 1;
			}
		} else if (c == 'k' || c == 'K') {
			/* Kill: confirm then kill selected session */
			unsigned char confirm;

			/* Clear help line and show confirmation prompt */
			fprintf(stderr, "\033[%dA", display_lines);
			for (i = 0; i < display_lines; i++)
				fprintf(stderr, "\033[2K\r\n");
			fprintf(stderr, "\033[%dA", display_lines);

			/* Re-render list */
			for (i = 0; i < count; i++) {
				if (i == sel && !entries[i].dead)
					fprintf(stderr,
						"\033[7m> %s\033[0m\r\n",
						entries[i].label);
				else if (entries[i].dead)
					fprintf(stderr,
						"\033[2m  %s\033[0m\r\n",
						entries[i].label);
				else
					fprintf(stderr, "  %s\r\n",
						entries[i].label);
			}
			fprintf(stderr,
				"\033[33mKill '%s'? (y/N)\033[0m ",
				entries[sel].name);
			fflush(stderr);

			if (read(0, &confirm, 1) != 1 ||
			    (confirm != 'y' && confirm != 'Y')) {
				/* Cancelled — erase the confirmation line */
				fprintf(stderr, "\r\033[2K");
				fprintf(stderr, "\033[%dA", count);
				continue;
			}

			/* Show cursor for kill output */
			fprintf(stderr, "\r\033[2K");
			tcsetattr(0, TCSADRAIN, &orig);
			fprintf(stderr, "\033[?25h");
			fflush(stderr);

			/* Kill the session */
			{
				char path[768];
				snprintf(path, sizeof(path), "%s/%s",
					 dir, entries[sel].name);
				sockname = path;
				if (entries[sel].dead) {
					/* Dead session: just clean up files */
					unlink(path);
					{
						char assoc[800];
						snprintf(assoc, sizeof(assoc),
							 "%s.log", path);
						unlink(assoc);
						snprintf(assoc, sizeof(assoc),
							 "%s.ppid", path);
						unlink(assoc);
					}
				} else {
					kill_main(0);
				}
			}

			/* Re-collect sessions and restart picker */
			count = collect_sessions(dir, entries,
						 MAX_SESSIONS);
			if (count == 0) {
				if (!quiet)
					printf("(no sessions)\n");
				return 0;
			}

			/* Reset selection */
			sel = 0;
			for (i = 0; i < count; i++) {
				if (!entries[i].dead) {
					sel = i;
					break;
				}
			}

			/* Re-enter raw mode */
			tcsetattr(0, TCSADRAIN, &raw);
			fprintf(stderr, "\033[?25l");

			/* Clear screen area for fresh render */
			continue;
		} else if (c == 'r' || c == 'R') {
			/* Rename: only live sessions */
			if (entries[sel].dead) {
				/* Dead sessions cannot be renamed — ignore */
				fprintf(stderr, "\033[%dA", display_lines);
				continue;
			}

			/* Clear and re-render with rename prompt */
			fprintf(stderr, "\033[%dA", display_lines);
			for (i = 0; i < display_lines; i++)
				fprintf(stderr, "\033[2K\r\n");
			fprintf(stderr, "\033[%dA", display_lines);

			for (i = 0; i < count; i++) {
				if (i == sel)
					fprintf(stderr,
						"\033[7m> %s\033[0m\r\n",
						entries[i].label);
				else if (entries[i].dead)
					fprintf(stderr,
						"\033[2m  %s\033[0m\r\n",
						entries[i].label);
				else
					fprintf(stderr, "  %s\r\n",
						entries[i].label);
			}
			fprintf(stderr,
				"\033[33mNew name: \033[0m");
			fflush(stderr);

			/* Show cursor for input */
			fprintf(stderr, "\033[?25h");

			{
				char new_name[256];
				int nlen;
				char old_path[768], new_path[768];

				nlen = picker_readline(new_name,
						       (int)sizeof(new_name));

				/* Hide cursor again */
				fprintf(stderr, "\033[?25l");

				if (nlen <= 0) {
					/* Cancelled */
					fprintf(stderr, "\r\033[2K");
					fprintf(stderr, "\033[%dA", count);
					continue;
				}

				/* Validate: no slashes in name */
				if (strchr(new_name, '/') != NULL) {
					fprintf(stderr,
						"\r\033[2K");
					fprintf(stderr, "\033[%dA", count);
					continue;
				}

				snprintf(old_path, sizeof(old_path),
					 "%s/%s", dir,
					 entries[sel].name);
				snprintf(new_path, sizeof(new_path),
					 "%s/%s", dir, new_name);

				/* Temporarily restore terminal for rename output */
				tcsetattr(0, TCSADRAIN, &orig);
				fprintf(stderr, "\033[?25h");
				fflush(stderr);

				rename_main(old_path, new_path);

				/* Re-collect sessions */
				count = collect_sessions(dir, entries,
							 MAX_SESSIONS);
				if (count == 0) {
					if (!quiet)
						printf("(no sessions)\n");
					return 0;
				}

				/* Reset selection */
				sel = 0;
				for (i = 0; i < count; i++) {
					if (!entries[i].dead) {
						sel = i;
						break;
					}
				}

				/* Re-enter raw mode */
				tcsetattr(0, TCSADRAIN, &raw);
				fprintf(stderr, "\033[?25l");
			}
			continue;
		} else if (c == 3) {
			/* Ctrl-C */
			break;
		}

		/* Move cursor up to redraw */
		fprintf(stderr, "\033[%dA", display_lines);
	}

	/* Restore terminal, show cursor */
	tcsetattr(0, TCSADRAIN, &orig);
	fprintf(stderr, "\033[?25h");
	fflush(stderr);
	return 0;
}

int list_main(int no_picker)
{
	char dir[512];
	struct session_entry entries[MAX_SESSIONS];
	int count;
	int is_tty;

	get_session_dir(dir, sizeof(dir));

	count = collect_sessions(dir, entries, MAX_SESSIONS);

	if (count == 0) {
		if (!quiet)
			printf("(no sessions)\n");
		return 0;
	}

	is_tty = isatty(STDOUT_FILENO);

	if (is_tty && !no_picker) {
		return interactive_picker(entries, count);
	}

	/* Plain text fallback */
	{
		int i;
		for (i = 0; i < count; i++)
			printf("%s\n", entries[i].label);
	}
	return 0;
}

int clean_main(void)
{
	char dir[512];
	char path[768];
	DIR *d;
	struct dirent *ent;
	int cleaned = 0;

	get_session_dir(dir, sizeof(dir));

	d = opendir(dir);
	if (!d) {
		if (errno == ENOENT)
			goto done;
		printf("%s: %s: %s\n", progname, dir, strerror(errno));
		return 1;
	}

	while ((ent = readdir(d)) != NULL) {
		struct stat st;
		int s;

		if (ent->d_name[0] == '.')
			continue;
		snprintf(path, sizeof(path), "%s/%s", dir, ent->d_name);
		if (stat(path, &st) < 0 || !S_ISSOCK(st.st_mode))
			continue;

		s = connect_socket(path);
		if (s >= 0) {
			close(s);
			continue;	/* live session — skip */
		}
		if (errno == ECONNREFUSED) {
			if (!quiet)
				printf("%s: removed orphan '%s'\n",
				       progname, ent->d_name);
			remove_orphan(path);
			cleaned++;
		}
	}

	closedir(d);

 done:
	if (cleaned == 0 && !quiet)
		printf("%s: no orphan sessions found\n", progname);
	return 0;
}
