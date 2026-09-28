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

#define MIN_COLS 10
#define MIN_ROWS 4

static struct termios g_orig_termios;
static int g_termios_saved = 0;

// Sets the inner pane size. $CZR_SIZE_FILE ("cols rows", written by the shell
// hook when another window than Zed is focused) wins; otherwise Zed's size.
static void apply_size(int master_fd, int *dropped) {
    struct winsize ws;
    int zed_ok = ioctl(STDIN_FILENO, TIOCGWINSZ, &ws) == 0 &&
                 ws.ws_col >= MIN_COLS && ws.ws_row >= MIN_ROWS;
    // Drop degenerate/collapsed sizes (e.g. cols=2 from inactive Zed threads).
    // Zed cuts its screen to that size, so it must be redrawn later.
    if (!zed_ok) *dropped = 1;

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
        return;
    }
    if (!zed_ok) return;
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

    // Set non-blocking on master_fd
    int flags = fcntl(master_fd, F_GETFL, 0);
    fcntl(master_fd, F_SETFL, flags | O_NONBLOCK);

    char buf[4096];
    struct pollfd pfds[3];
    int child_exited = 0;
    int child_status = 0;
    int dropped = 0;
    apply_size(master_fd, &dropped);  // size file may predate us

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
                    apply_size(master_fd, &dropped);
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
            ssize_t n = read(STDIN_FILENO, buf, sizeof(buf));
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
            } else if (n == 0) {
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
