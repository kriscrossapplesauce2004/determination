/*
 * evgrab — hold EVIOCGRAB on evdev nodes for Determination desktop mode.
 *
 * On modern Android there is no standalone inputflinger process to stop:
 * input is EventHub/InputReader inside system_server, reading
 * /dev/input/event* non-exclusively. The clean handoff is an exclusive grab —
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
#define INPUT_DIR "/dev/input"

static int fds[MAX_NODES];
static int nfds;
static volatile sig_atomic_t quit;

static void on_term(int sig) { (void)sig; quit = 1; }

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
    DIR *d = opendir(INPUT_DIR);
    if (!d) {
        perror("evgrab: opendir " INPUT_DIR);
        return -1;
    }
    struct dirent *e;
    int rc = 0;
    while ((e = readdir(d))) {
        if (strncmp(e->d_name, "event", 5) != 0)
            continue;
        char path[288];
        snprintf(path, sizeof(path), INPUT_DIR "/%s", e->d_name);
        /* A node that appears/disappears mid-scan isn't fatal; a node that
         * exists but refuses the grab is — someone else holds it. */
        if (grab(path) < 0 && errno != ENOENT)
            rc = -1;
    }
    closedir(d);
    return rc;
}

int main(int argc, char **argv)
{
    const char *pidfile = NULL;
    int all = 0, opt;

    while ((opt = getopt(argc, argv, "ap:")) != -1) {
        switch (opt) {
        case 'a': all = 1; break;
        case 'p': pidfile = optarg; break;
        default:
            fprintf(stderr, "usage: evgrab -a [-p pidfile] | evgrab [-p pidfile] node...\n");
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

    /* Daemonize only after every grab succeeded, so the caller's exit-code
     * check is meaningful. */
    pid_t pid = fork();
    if (pid < 0) { perror("evgrab: fork"); release_all(); return 1; }
    if (pid > 0) {
        if (pidfile) {
            FILE *f = fopen(pidfile, "w");
            if (f) { fprintf(f, "%d\n", pid); fclose(f); }
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
