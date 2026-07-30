#include "determination/control/adapter.hpp"

#include "determination/control/system.hpp"

#include <cerrno>
#include <csignal>
#include <cstring>
#include <fcntl.h>
#include <poll.h>
#include <sys/prctl.h>
#include <sys/wait.h>
#include <unistd.h>

extern char **environ;

namespace determination::control {

AdapterResult run_adapter(const std::string &path,
                          const std::vector<std::string> &arguments,
                          std::chrono::milliseconds timeout,
                          std::size_t output_limit,
                          const std::atomic<bool> *cancelled)
{
    AdapterResult result;
    int output_pipe[2];
    if (pipe2(output_pipe, O_CLOEXEC | O_NONBLOCK) != 0) {
        result.error = std::strerror(errno);
        return result;
    }

    std::vector<char *> argv;
    argv.reserve(arguments.size() + 2U);
    argv.push_back(const_cast<char *>(path.c_str()));
    for (const std::string &argument : arguments) {
        argv.push_back(const_cast<char *>(argument.c_str()));
    }
    argv.push_back(nullptr);

    const pid_t child = fork();
    if (child == 0) {
        prctl(PR_SET_PDEATHSIG, SIGTERM);
        if (getppid() == 1) _exit(126);
        if (setpgid(0, 0) != 0) _exit(126);
        clearenv();
        setenv("PATH", "/system/bin:/system/xbin:/usr/bin:/bin", 1);
        setenv("LANG", "C", 1);
        dup2(output_pipe[1], STDOUT_FILENO);
        dup2(output_pipe[1], STDERR_FILENO);
        close(output_pipe[0]);
        close(output_pipe[1]);
        execv(path.c_str(), argv.data());
        _exit(127);
    }
    close(output_pipe[1]);
    if (child < 0) {
        result.error = std::strerror(errno);
        close(output_pipe[0]);
        return result;
    }
    result.started = true;
    // Establish the group in the parent too, closing the child-side race before
    // timeout handling can send a group signal.
    if (setpgid(child, child) != 0 && errno != EACCES && errno != ESRCH) {
        result.error = std::strerror(errno);
    }

    const std::uint64_t deadline = monotonic_milliseconds() +
        static_cast<std::uint64_t>(timeout.count());
    int wait_status = 0;
    bool exited = false;
    char buffer[4096];
    while (!exited) {
        for (;;) {
            const ssize_t count = read(output_pipe[0], buffer, sizeof(buffer));
            if (count > 0) {
                const std::size_t available = result.output.size() < output_limit
                    ? output_limit - result.output.size() : 0U;
                const std::size_t captured = std::min(
                    static_cast<std::size_t>(count), available);
                result.output.append(buffer, captured);
                result.output_truncated = result.output_truncated ||
                    captured != static_cast<std::size_t>(count);
                continue;
            }
            if (count < 0 && errno == EINTR) continue;
            break;
        }
        const pid_t waited = waitpid(child, &wait_status, WNOHANG);
        if (waited == child) {
            exited = true;
            break;
        }
        if (waited < 0 && errno != EINTR) {
            result.error = std::strerror(errno);
            break;
        }
        const bool was_cancelled = cancelled && cancelled->load();
        if (was_cancelled || monotonic_milliseconds() >= deadline) {
            result.timed_out = !was_cancelled;
            kill(-child, SIGTERM);
            const std::uint64_t grace = monotonic_milliseconds() + 1000U;
            do {
                if (waitpid(child, &wait_status, WNOHANG) == child) {
                    exited = true;
                    break;
                }
                poll(nullptr, 0, 25);
            } while (monotonic_milliseconds() < grace);
            if (!exited) {
                kill(-child, SIGKILL);
                while (waitpid(child, &wait_status, 0) < 0 && errno == EINTR) {}
                exited = true;
            }
            break;
        }
        pollfd descriptor{.fd = output_pipe[0], .events = POLLIN, .revents = 0};
        poll(&descriptor, 1, 25);
    }

    for (;;) {
        const ssize_t count = read(output_pipe[0], buffer, sizeof(buffer));
        if (count > 0) {
            const std::size_t available = result.output.size() < output_limit
                ? output_limit - result.output.size() : 0U;
            const std::size_t captured = std::min(
                static_cast<std::size_t>(count), available);
            result.output.append(buffer, captured);
            result.output_truncated = result.output_truncated ||
                captured != static_cast<std::size_t>(count);
        }
        else if (count < 0 && errno == EINTR) continue;
        else break;
    }
    close(output_pipe[0]);

    if (cancelled && cancelled->load()) {
        result.exit_status = -1;
        result.error = "adapter cancelled";
    } else if (result.timed_out) {
        result.exit_status = -1;
        result.error = "adapter deadline exceeded";
    } else if (exited && WIFEXITED(wait_status)) {
        result.exit_status = WEXITSTATUS(wait_status);
    } else if (exited && WIFSIGNALED(wait_status)) {
        result.exit_status = 128 + WTERMSIG(wait_status);
    }
    return result;
}

} // namespace determination::control
