/*
 * evgrab holds EVIOCGRAB on evdev nodes for Determination desktop mode.
 *
 * On modern Android there is no standalone inputflinger process to stop:
 * input is EventHub/InputReader inside system_server, reading
 * /dev/input/event* non-exclusively. The clean handoff is an exclusive grab.
 * while we hold EVIOCGRAB, Android's readers see nothing (no double input),
 * and the guest's libinput reads the same nodes normally. Release on SIGTERM
 * returns input to Android. (Design spec §4.)
 *
 * Usage:
 *   evgrab -a [-p pidfile]            grab all /dev/input/event* nodes
 *   evgrab [-p pidfile] node...       grab the listed nodes
 *
 * Daemonizes after all grabs succeed; exits non-zero if any grab fails
 * (partial grabs are released), so the toggle script can abort cleanly.
 */

#include <dirent.h>
#include <errno.h>
#include <fcntl.h>
#include <linux/input.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <unistd.h>

#define MAX_NODES 64
#define DEFAULT_INPUT_DIR "/dev/input"

static int fds[MAX_NODES];
static int nfds;
static volatile sig_atomic_t quit;
static const char *input_dir = DEFAULT_INPUT_DIR;

static void on_term(int sig) { (void)sig; quit = 1; }

static int write_pidfile(const char *path, pid_t pid)
{
    char temporary[320];
    snprintf(temporary, sizeof(temporary), "%s.new.%ld", path, (long)getpid());
    int fd = open(temporary, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 0640);
    if (fd < 0) return -1;
    char proc[64], stat[512], start[64] = "unknown";
    snprintf(proc, sizeof(proc), "/proc/%ld/stat", (long)pid);
    int stat_fd = open(proc, O_RDONLY | O_CLOEXEC);
    if (stat_fd >= 0) {
        ssize_t count = read(stat_fd, stat, sizeof(stat) - 1);
        close(stat_fd);
        if (count > 0) {
            stat[count] = '\0';
            char *field = strrchr(stat, ')');
            for (int index = 0; field && index < 20; ++index)
                field = strchr(field + 1, ' ');
            if (field) {
                char *value = field + 1;
                char *end = strchr(value, ' ');
                if (end) *end = '\0';
                snprintf(start, sizeof(start), "%s", value);
            }
        }
    }
    dprintf(fd, "pid=%ld\nstart=%s\n", (long)pid, start);
    if (fsync(fd) != 0 || close(fd) != 0 || link(temporary, path) != 0) {
        int saved = errno;
        unlink(temporary);
        errno = saved;
        return -1;
    }
    unlink(temporary);
    return 0;
}

static int grab(const char *path)
{
    if (nfds >= MAX_NODES) {
        fprintf(stderr, "evgrab: too many nodes (max %d)\n", MAX_NODES);
        return -1;
    }
    int fd = open(path, O_RDONLY | O_NONBLOCK | O_CLOEXEC);
    if (fd < 0) {
        fprintf(stderr, "evgrab: open %s: %s\n", path, strerror(errno));
        return -1;
    }
    if (ioctl(fd, EVIOCGRAB, (void *)1) < 0) {
        fprintf(stderr, "evgrab: EVIOCGRAB %s: %s\n", path, strerror(errno));
        close(fd);
        return -1;
    }
    char name[80] = "?";
    ioctl(fd, EVIOCGNAME(sizeof(name)), name);
    fprintf(stderr, "evgrab: grabbed %s (%s)\n", path, name);
    fds[nfds++] = fd;
    return 0;
}

static void release_all(void)
{
    for (int i = 0; i < nfds; i++) {
        ioctl(fds[i], EVIOCGRAB, (void *)0);
        close(fds[i]);
    }
    nfds = 0;
}

static int grab_all(void)
{
    struct dirent **entries = NULL;
    const int count = scandir(input_dir, &entries, NULL, alphasort);
    if (count < 0) {
        perror("evgrab: scandir");
        return -1;
    }
    int rc = 0;
    for (int index = 0; index < count; ++index) {
        struct dirent *e = entries[index];
        if (strncmp(e->d_name, "event", 5) != 0) {
            free(e);
            continue;
        }
        char path[288];
        snprintf(path, sizeof(path), "%s/%s", input_dir, e->d_name);
        if (grab(path) < 0 && errno != ENOENT)
            rc = -1;
        free(e);
    }
    free(entries);
    return rc;
}

int main(int argc, char **argv)
{
    const char *pidfile = NULL;
    int all = 0, foreground = 0, opt;

    while ((opt = getopt(argc, argv, "afp:D:")) != -1) {
        switch (opt) {
        case 'a': all = 1; break;
        case 'f': foreground = 1; break;
        case 'p': pidfile = optarg; break;
        case 'D': input_dir = optarg; break;
        default:
            fprintf(stderr, "usage: evgrab [-f] [-D input-dir] -a [-p pidfile] | evgrab [-f] [-p pidfile] node...\n");
            return 2;
        }
    }

    if (all) {
        if (grab_all() < 0) { release_all(); return 1; }
    } else {
        if (optind == argc) {
            fprintf(stderr, "evgrab: no nodes given (want -a or paths)\n");
            return 2;
        }
        for (int i = optind; i < argc; i++)
            if (grab(argv[i]) < 0) { release_all(); return 1; }
    }
    if (nfds == 0) {
        fprintf(stderr, "evgrab: nothing grabbed\n");
        return 1;
    }

    if (foreground) {
        signal(SIGTERM, on_term);
        signal(SIGINT, on_term);
        while (!quit) pause();
        release_all();
        return 0;
    }

    /* Daemonize only after every grab succeeded. */
    pid_t pid = fork();
    if (pid < 0) { perror("evgrab: fork"); release_all(); return 1; }
    if (pid > 0) {
        if (pidfile) {
            if (write_pidfile(pidfile, pid) != 0) {
                perror("evgrab: pidfile");
                kill(pid, SIGTERM);
                return 1;
            }
        }
        return 0;
    }

    setsid();
    signal(SIGTERM, on_term);
    signal(SIGINT, on_term);
    while (!quit)
        pause();
    release_all();
    return 0;
}
