#define _GNU_SOURCE
#include <errno.h>
#include <fcntl.h>
#include <pty.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/poll.h>
#include <sys/signalfd.h>
#include <sys/wait.h>
#include <termios.h>
#include <unistd.h>

#define MIN_COLS 40
#define MIN_ROWS 10

static struct termios g_orig_termios;
static int g_termios_saved = 0;
static int g_focused = 1;      // Zed's terminal has focus
static int g_inner_focus = 0;  // the agent asked for focus reports itself

// Zed reports focus as ESC [ I / ESC [ O (mode 1004, enabled in main). Track it,
// and pass it on only if the agent asked for focus reports too.
// ponytail: a report split across two reads is missed; the next one fixes it.
static ssize_t take_focus(char *buf, ssize_t n, int *changed) {
    ssize_t o = 0;
    for (ssize_t i = 0; i < n; i++) {
        if (i + 2 < n && buf[i] == '\x1b' && buf[i + 1] == '[' && (buf[i + 2] == 'I' || buf[i + 2] == 'O')) {
            int f = buf[i + 2] == 'I';
            if (f != g_focused) {
                g_focused = f;
                *changed = 1;
            }
            if (!g_inner_focus) {
                i += 2;
                continue;
            }
        }
        buf[o++] = buf[i];
    }
    return o;
}

// Notes the agent turning focus reports on/off; returns 1 if it turned them
// off, so the caller turns them back on in Zed (the guard still needs them).
// ponytail: combined modes ("ESC [?1004;2004h") aren't parsed.
static int watch_focus_mode(const char *buf, ssize_t n) {
    static const char pat[] = "\x1b[?1004";
    const size_t len = sizeof pat - 1;
    const char *p = buf, *end = buf + n;
    int off = 0;
    while ((p = memmem(p, end - p, pat, len)) && p + len < end) {
        if (p[len] == 'h') g_inner_focus = 1;
        if (p[len] == 'l') g_inner_focus = 0, off = 1;
        p += len;
    }
    return off;
}

// Passes Zed's size to the pane. A shrink waits for Zed input (force): Zed
// shrinks when you switch to herdr's window (e.g. un-fullscreen), and herdr
// would then show the agent that small. Zed's focus reports don't help: it
// sends none when its whole window loses focus. Growing applies at once.
// ponytail: shrinking Zed while using it waits for a keystroke there.
// Also drops degenerate/collapsed sizes (e.g. cols=2 from inactive Zed
// threads) so they don't squish the agent.
// $CZR_SIZE_FILE ("cols rows", written by the shell watcher while herdr's
// window is focused) wins over all that: herdr then shows the agent full size.
static int g_hold = 0;  // a shrink is waiting for Zed input
static int g_herdr = 0; // the pane has herdr's size from the size file
static void apply_size(int master_fd, int *dropped, int force) {
    struct winsize ws, cur;
    const char *path = getenv("CZR_SIZE_FILE");
    FILE *f = path ? fopen(path, "r") : NULL;
    int cols = 0, rows = 0;
    if (f) {
        if (fscanf(f, "%d %d", &cols, &rows) != 2) cols = rows = 0;
        fclose(f);
    }
    if (cols >= MIN_COLS && rows >= MIN_ROWS) {
        struct winsize other = {.ws_row = rows, .ws_col = cols};
        ioctl(master_fd, TIOCSWINSZ, &other);
        g_herdr = 1;
        g_hold = 0;
        *dropped = 1;  // Zed's screen is stale now: redraw on return
        return;
    }
    if (g_herdr) force = 1, g_herdr = 0;  // back to Zed: take its size at once
    if (ioctl(STDIN_FILENO, TIOCGWINSZ, &ws) != 0) return;
    if (ws.ws_col < MIN_COLS || ws.ws_row < MIN_ROWS) {
        // Zed cuts its screen to that size, so it must be redrawn later.
        *dropped = 1;
        return;
    }
    if (!force && ioctl(master_fd, TIOCGWINSZ, &cur) == 0 &&
        (ws.ws_col < cur.ws_col || ws.ws_row < cur.ws_row)) {
        g_hold = 1;
        *dropped = 1;  // Zed now shows the old frame cut: redraw later
        return;
    }
    g_hold = 0;
    if (*dropped) {
        // Back at the old size the kernel sends no SIGWINCH and the agent
        // never repaints: nudge one column first to force it.
        struct winsize nudge = ws;
        nudge.ws_col--;
        ioctl(master_fd, TIOCSWINSZ, &nudge);
        usleep(50000);
        *dropped = 0;
    }
    ioctl(master_fd, TIOCSWINSZ, &ws);
}

static void restore_terminal(void) {
    if (g_termios_saved) {
        write(STDOUT_FILENO, "\x1b[?1004l", 8);
        tcsetattr(STDIN_FILENO, TCSANOW, &g_orig_termios);
        g_termios_saved = 0;
    }
}

int main(int argc, char *argv[]) {
    if (argc < 2) {
        fprintf(stderr, "Usage: %s <command> [args...]\n", argv[0]);
        return 1;
    }

    if (!isatty(STDIN_FILENO)) {
        execvp(argv[1], &argv[1]);
        perror("execvp");
        return 1;
    }

    if (tcgetattr(STDIN_FILENO, &g_orig_termios) == 0) {
        g_termios_saved = 1;
        atexit(restore_terminal);
    }

    struct winsize ws;
    int has_valid_ws = 0;
    if (ioctl(STDIN_FILENO, TIOCGWINSZ, &ws) == 0) {
        if (ws.ws_col >= MIN_COLS && ws.ws_row >= MIN_ROWS) {
            has_valid_ws = 1;
        }
    }
    if (!has_valid_ws) {
        ws.ws_col = 120;
        ws.ws_row = 35;
        ws.ws_xpixel = 0;
        ws.ws_ypixel = 0;
    }

    int master_fd, slave_fd;
    if (openpty(&master_fd, &slave_fd, NULL, NULL, &ws) < 0) {
        perror("openpty");
        return 1;
    }

    sigset_t mask, orig_mask;
    sigemptyset(&mask);
    sigaddset(&mask, SIGWINCH);
    sigaddset(&mask, SIGCHLD);
    sigaddset(&mask, SIGTERM);
    sigaddset(&mask, SIGHUP);
    sigaddset(&mask, SIGINT);
    sigaddset(&mask, SIGUSR2);  // size file changed
    if (sigprocmask(SIG_BLOCK, &mask, &orig_mask) < 0) {
        perror("sigprocmask");
        return 1;
    }

    int sfd = signalfd(-1, &mask, SFD_NONBLOCK | SFD_CLOEXEC);
    if (sfd < 0) {
        perror("signalfd");
        return 1;
    }

    pid_t child_pid = fork();
    if (child_pid < 0) {
        perror("fork");
        return 1;
    }

    if (child_pid == 0) {
        // Child process
        close(master_fd);
        close(sfd);

        // Unblock signals in child
        sigprocmask(SIG_SETMASK, &orig_mask, NULL);

        // Create new session and set controlling terminal
        setsid();
        ioctl(slave_fd, TIOCSCTTY, 0);

        dup2(slave_fd, STDIN_FILENO);
        dup2(slave_fd, STDOUT_FILENO);
        dup2(slave_fd, STDERR_FILENO);
        if (slave_fd > STDERR_FILENO) {
            close(slave_fd);
        }

        execvp(argv[1], &argv[1]);
        perror("execvp child");
        _exit(127);
    }

    // Parent process
    close(slave_fd);

    // Set raw mode on outer stdin
    struct termios raw = g_orig_termios;
    cfmakeraw(&raw);
    tcsetattr(STDIN_FILENO, TCSANOW, &raw);
    write(STDOUT_FILENO, "\x1b[?1004h", 8);  // ask Zed for focus reports

    // Set non-blocking on master_fd
    int flags = fcntl(master_fd, F_GETFL, 0);
    fcntl(master_fd, F_SETFL, flags | O_NONBLOCK);

    char buf[4096];
    struct pollfd pfds[3];
    int child_exited = 0;
    int child_status = 0;
    int dropped = 0;
    apply_size(master_fd, &dropped, 0);  // size file may predate us

    while (1) {
        pfds[0].fd = STDIN_FILENO;
        pfds[0].events = POLLIN;
        pfds[0].revents = 0;

        pfds[1].fd = master_fd;
        pfds[1].events = POLLIN;
        pfds[1].revents = 0;

        pfds[2].fd = sfd;
        pfds[2].events = POLLIN;
        pfds[2].revents = 0;

        int ret = poll(pfds, 3, -1);
        if (ret < 0) {
            if (errno == EINTR) continue;
            break;
        }

        // Handle signals
        if (pfds[2].revents & POLLIN) {
            struct signalfd_siginfo fdsi;
            while (read(sfd, &fdsi, sizeof(fdsi)) == sizeof(fdsi)) {
                if (fdsi.ssi_signo == SIGWINCH || fdsi.ssi_signo == SIGUSR2) {
                    apply_size(master_fd, &dropped, 0);
                } else if (fdsi.ssi_signo == SIGCHLD) {
                    pid_t p;
                    int status;
                    while ((p = waitpid(-1, &status, WNOHANG)) > 0) {
                        if (p == child_pid) {
                            child_exited = 1;
                            child_status = status;
                        }
                    }
                } else if (fdsi.ssi_signo == SIGTERM || fdsi.ssi_signo == SIGHUP || fdsi.ssi_signo == SIGINT) {
                    kill(child_pid, fdsi.ssi_signo);
                }
            }
        }

        // Handle stdin -> master_fd
        if (pfds[0].revents & POLLIN) {
            ssize_t got = read(STDIN_FILENO, buf, sizeof(buf));
            int changed = 0;
            ssize_t n = got > 0 ? take_focus(buf, got, &changed) : got;
            // Typing or clicking into Zed's terminal (or it gaining focus
            // inside Zed) applies a held shrink.
            if (g_hold && ((changed && g_focused) || n > 0)) apply_size(master_fd, &dropped, 1);
            if (n > 0) {
                ssize_t written = 0;
                while (written < n) {
                    ssize_t w = write(master_fd, buf + written, n - written);
                    if (w < 0) {
                        if (errno == EAGAIN || errno == EWOULDBLOCK) {
                            usleep(1000);
                            continue;
                        }
                        break;
                    }
                    written += w;
                }
            } else if (got == 0) {
                // Stdin EOF (e.g. thread closed)
                close(master_fd);
                break;
            }
        }

        // Handle master_fd -> stdout
        if (pfds[1].revents & POLLIN) {
            ssize_t n = read(master_fd, buf, sizeof(buf));
            if (n > 0) {
                ssize_t written = 0;
                while (written < n) {
                    ssize_t w = write(STDOUT_FILENO, buf + written, n - written);
                    if (w < 0) {
                        if (errno == EAGAIN || errno == EWOULDBLOCK) {
                            usleep(1000);
                            continue;
                        }
                        break;
                    }
                    written += w;
                }
                if (watch_focus_mode(buf, n)) write(STDOUT_FILENO, "\x1b[?1004h", 8);
            } else if (n <= 0 && errno != EAGAIN && errno != EWOULDBLOCK) {
                // Master closed
                break;
            }
        }

        if (pfds[1].revents & (POLLHUP | POLLERR)) {
            // Drain remaining
            ssize_t n;
            while ((n = read(master_fd, buf, sizeof(buf))) > 0) {
                write(STDOUT_FILENO, buf, n);
            }
            break;
        }

        if (child_exited) {
            // Drain any pending output before exiting
            ssize_t n;
            while ((n = read(master_fd, buf, sizeof(buf))) > 0) {
                write(STDOUT_FILENO, buf, n);
            }
            break;
        }
    }

    restore_terminal();

    if (child_exited) {
        if (WIFEXITED(child_status)) {
            return WEXITSTATUS(child_status);
        }
        if (WIFSIGNALED(child_status)) {
            return 128 + WTERMSIG(child_status);
        }
    } else {
        int status;
        waitpid(child_pid, &status, 0);
        if (WIFEXITED(status)) return WEXITSTATUS(status);
        if (WIFSIGNALED(status)) return 128 + WTERMSIG(status);
    }

    return 0;
}
