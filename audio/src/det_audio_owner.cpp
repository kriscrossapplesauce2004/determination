#include <algorithm>
#include <cerrno>
#include <chrono>
#include <csignal>
#include <cctype>
#include <cstdint>
#include <cstring>
#include <fcntl.h>
#include <fstream>
#include <iostream>
#include <map>
#include <optional>
#include <poll.h>
#include <sstream>
#include <string>
#include <string_view>
#include <sys/prctl.h>
#include <sys/file.h>
#include <sys/stat.h>
#include <sys/wait.h>
#include <thread>
#include <unistd.h>
#include <vector>

namespace {

struct Options {
    std::string command;
    std::string root = "/data/determination";
    std::string profile;
    std::string probe;
    std::string probe_root = "/";
    std::string getprop = "/system/bin/getprop";
    std::string setprop = "/system/bin/setprop";
    bool apply = false;
};

struct Profile {
    int schema = 0;
    std::string id;
    std::string card_contains;
    std::vector<std::string> services;
    std::vector<std::string> required_nodes;
    unsigned int timeout_ms = 5000;
    std::uint64_t hash = 0;
};

struct ServiceSnapshot {
    std::string name;
    std::string state;
};

struct Journal {
    int schema = 1;
    std::uint64_t generation = 0;
    int owner_pid = 0;
    std::uint64_t owner_started_ms = 0;
    std::string phase = "none";
    std::string boot_id;
    std::string profile_id;
    std::uint64_t profile_hash = 0;
    std::vector<ServiceSnapshot> services;
    std::string error;
};

struct CommandResult {
    bool started = false;
    bool timed_out = false;
    int status = -1;
    std::string output;
};

[[nodiscard]] std::string trim(std::string value) {
    while (!value.empty() && std::isspace(static_cast<unsigned char>(value.back()))) {
        value.pop_back();
    }
    size_t first = 0;
    while (first < value.size() &&
           std::isspace(static_cast<unsigned char>(value[first]))) {
        ++first;
    }
    return value.substr(first);
}

[[nodiscard]] std::string json_escape(std::string_view input) {
    std::ostringstream out;
    for (const unsigned char ch : input) {
        switch (ch) {
        case '"': out << "\\\""; break;
        case '\\': out << "\\\\"; break;
        case '\n': out << "\\n"; break;
        case '\r': out << "\\r"; break;
        case '\t': out << "\\t"; break;
        default:
            if (ch < 0x20) out << '?'; else out << static_cast<char>(ch);
        }
    }
    return out.str();
}

[[nodiscard]] std::optional<std::string> read_file(const std::string &path) {
    std::ifstream input(path, std::ios::binary);
    if (!input) return std::nullopt;
    std::ostringstream output;
    output << input.rdbuf();
    return output.str();
}

[[nodiscard]] bool valid_name(std::string_view value) {
    return !value.empty() && std::all_of(value.begin(), value.end(), [](char ch) {
        const unsigned char byte = static_cast<unsigned char>(ch);
        return std::isalnum(byte) != 0 || ch == '.' || ch == '_' || ch == '-';
    });
}

[[nodiscard]] std::uint64_t fnv1a(std::string_view value) {
    std::uint64_t hash = UINT64_C(14695981039346656037);
    for (const unsigned char byte : value) {
        hash ^= byte;
        hash *= UINT64_C(1099511628211);
    }
    return hash;
}

[[nodiscard]] bool parse_uint(std::string_view value, unsigned int *result) {
    if (value.empty()) return false;
    unsigned long parsed = 0;
    for (const char ch : value) {
        if (!std::isdigit(static_cast<unsigned char>(ch))) return false;
        parsed = parsed * 10UL + static_cast<unsigned long>(ch - '0');
        if (parsed > 60000UL) return false;
    }
    *result = static_cast<unsigned int>(parsed);
    return true;
}

[[nodiscard]] bool parse_u64(std::string_view value, std::uint64_t *result) {
    if (value.empty()) return false;
    std::uint64_t parsed = 0;
    for (const char ch : value) {
        if (!std::isdigit(static_cast<unsigned char>(ch))) return false;
        const std::uint64_t digit = static_cast<std::uint64_t>(ch - '0');
        if (parsed > (UINT64_MAX - digit) / 10U) return false;
        parsed = parsed * 10U + digit;
    }
    *result = parsed;
    return true;
}

[[nodiscard]] bool load_profile(const std::string &path, Profile *profile,
                                std::string *error) {
    const auto text = read_file(path);
    if (!text) {
        *error = "cannot read profile " + path;
        return false;
    }
    Profile candidate;
    candidate.hash = fnv1a(*text);
    std::istringstream input(*text);
    std::string line;
    unsigned int line_number = 0;
    while (std::getline(input, line)) {
        ++line_number;
        line = trim(line);
        if (line.empty() || line.front() == '#') continue;
        const size_t equals = line.find('=');
        if (equals == std::string::npos || equals == 0) {
            *error = "malformed profile line " + std::to_string(line_number);
            return false;
        }
        const std::string key = trim(line.substr(0, equals));
        const std::string value = trim(line.substr(equals + 1));
        if (key == "schema") {
            unsigned int schema = 0;
            if (!parse_uint(value, &schema)) {
                *error = "invalid profile schema";
                return false;
            }
            candidate.schema = static_cast<int>(schema);
        } else if (key == "profile") {
            candidate.id = value;
        } else if (key == "card_contains") {
            candidate.card_contains = value;
        } else if (key == "service") {
            if (!valid_name(value)) {
                *error = "invalid service name";
                return false;
            }
            candidate.services.push_back(value);
        } else if (key == "required_node") {
            if (value.rfind("/dev/snd/", 0) != 0 || value.find("..") != std::string::npos) {
                *error = "required_node must be below /dev/snd";
                return false;
            }
            candidate.required_nodes.push_back(value);
        } else if (key == "timeout_ms") {
            if (!parse_uint(value, &candidate.timeout_ms) ||
                candidate.timeout_ms < 250) {
                *error = "invalid timeout_ms";
                return false;
            }
        } else {
            *error = "unknown profile key " + key;
            return false;
        }
    }
    if (candidate.schema != 1 || !valid_name(candidate.id) ||
        candidate.card_contains.empty() || candidate.services.empty()) {
        *error = "profile requires schema=1, profile, card_contains and service";
        return false;
    }
    *profile = std::move(candidate);
    return true;
}

[[nodiscard]] CommandResult run_command(const std::string &path,
                                        const std::vector<std::string> &arguments,
                                        unsigned int timeout_ms) {
    CommandResult result;
    int pipe_fds[2];
    if (pipe2(pipe_fds, O_CLOEXEC | O_NONBLOCK) != 0) return result;
    std::vector<char *> argv;
    argv.push_back(const_cast<char *>(path.c_str()));
    for (const std::string &argument : arguments) {
        argv.push_back(const_cast<char *>(argument.c_str()));
    }
    argv.push_back(nullptr);

    const pid_t child = fork();
    if (child == 0) {
        prctl(PR_SET_PDEATHSIG, SIGTERM);
        if (getppid() == 1) _exit(126);
        dup2(pipe_fds[1], STDOUT_FILENO);
        dup2(pipe_fds[1], STDERR_FILENO);
        close(pipe_fds[0]);
        close(pipe_fds[1]);
        execv(path.c_str(), argv.data());
        _exit(127);
    }
    close(pipe_fds[1]);
    if (child < 0) {
        close(pipe_fds[0]);
        return result;
    }
    result.started = true;
    const auto deadline = std::chrono::steady_clock::now() +
                          std::chrono::milliseconds(timeout_ms);
    int wait_status = 0;
    bool exited = false;
    char buffer[2048];
    while (!exited) {
        const ssize_t count = read(pipe_fds[0], buffer, sizeof(buffer));
        if (count > 0 && result.output.size() < 65536U) {
            const size_t available = 65536U - result.output.size();
            result.output.append(buffer, std::min(static_cast<size_t>(count), available));
        }
        const pid_t waited = waitpid(child, &wait_status, WNOHANG);
        if (waited == child) {
            exited = true;
            break;
        }
        if (waited < 0 && errno != EINTR) break;
        if (std::chrono::steady_clock::now() >= deadline) {
            result.timed_out = true;
            kill(child, SIGKILL);
            while (waitpid(child, &wait_status, 0) < 0 && errno == EINTR) {}
            exited = true;
            break;
        }
        pollfd descriptor{.fd = pipe_fds[0], .events = POLLIN, .revents = 0};
        poll(&descriptor, 1, 20);
    }
    for (;;) {
        const ssize_t count = read(pipe_fds[0], buffer, sizeof(buffer));
        if (count > 0 && result.output.size() < 65536U) {
            const size_t available = 65536U - result.output.size();
            result.output.append(buffer, std::min(static_cast<size_t>(count), available));
        } else {
            break;
        }
    }
    close(pipe_fds[0]);
    if (!result.timed_out && exited && WIFEXITED(wait_status)) {
        result.status = WEXITSTATUS(wait_status);
    } else if (!result.timed_out && exited && WIFSIGNALED(wait_status)) {
        result.status = 128 + WTERMSIG(wait_status);
    }
    return result;
}

[[nodiscard]] std::string parent_directory(const std::string &path) {
    const size_t slash = path.rfind('/');
    return slash == std::string::npos ? "." : path.substr(0, slash);
}

[[nodiscard]] bool ensure_directory(const std::string &path) {
    if (path.empty() || path == "/") return true;
    struct stat info {};
    if (stat(path.c_str(), &info) == 0) return S_ISDIR(info.st_mode);
    const std::string parent = parent_directory(path);
    return ensure_directory(parent) &&
           (mkdir(path.c_str(), 0750) == 0 || errno == EEXIST);
}

[[nodiscard]] bool write_all(int fd, std::string_view content) {
    size_t offset = 0;
    while (offset < content.size()) {
        const ssize_t count = write(fd, content.data() + offset,
                                    content.size() - offset);
        if (count < 0 && errno == EINTR) continue;
        if (count <= 0) return false;
        offset += static_cast<size_t>(count);
    }
    return true;
}

[[nodiscard]] std::string journal_path(const Options &options) {
    return options.root + "/run/audio-owner.state";
}

[[nodiscard]] std::uint64_t monotonic_milliseconds() {
    return static_cast<std::uint64_t>(
        std::chrono::duration_cast<std::chrono::milliseconds>(
            std::chrono::steady_clock::now().time_since_epoch()).count());
}

class TransactionLock {
public:
    explicit TransactionLock(const Options &options) {
        const std::string path = options.root + "/run/audio-owner.lock";
        if (!ensure_directory(parent_directory(path))) return;
        fd_ = open(path.c_str(), O_RDWR | O_CREAT | O_CLOEXEC, 0640);
        if (fd_ >= 0 && flock(fd_, LOCK_EX | LOCK_NB) == 0) return;
        if (fd_ >= 0) close(fd_);
        fd_ = -1;
    }
    ~TransactionLock() { if (fd_ >= 0) close(fd_); }
    TransactionLock(const TransactionLock &) = delete;
    TransactionLock &operator=(const TransactionLock &) = delete;
    bool held() const { return fd_ >= 0; }
private:
    int fd_ = -1;
};

[[nodiscard]] std::string claim_marker_path(const Options &options) {
    return options.root + "/run/control/audio-claimed";
}

[[nodiscard]] bool remove_claim_marker(const Options &options,
                                       std::string *error) {
    const std::string path = claim_marker_path(options);
    if (unlink(path.c_str()) != 0 && errno != ENOENT) {
        *error = std::strerror(errno);
        return false;
    }
    const std::string parent = parent_directory(path);
    const int directory = open(parent.c_str(), O_RDONLY | O_DIRECTORY | O_CLOEXEC);
    if (directory >= 0) {
        fsync(directory);
        close(directory);
    }
    return true;
}

[[nodiscard]] bool write_claim_marker(const Options &options,
                                      const Journal &journal,
                                      std::string *error) {
    const std::string path = claim_marker_path(options);
    const std::string parent = parent_directory(path);
    if (!ensure_directory(parent)) {
        *error = "cannot create audio claim marker directory";
        return false;
    }
    const std::string temporary = path + ".new." + std::to_string(getpid());
    const int fd = open(temporary.c_str(), O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC,
                        0640);
    if (fd < 0) {
        *error = std::strerror(errno);
        return false;
    }
    const std::string content = "schema=1\nprofile=" + journal.profile_id +
        "\nboot_id=" + journal.boot_id + "\n";
    const bool okay = write_all(fd, content) && fsync(fd) == 0;
    const int saved_errno = errno;
    close(fd);
    if (!okay || rename(temporary.c_str(), path.c_str()) != 0) {
        *error = std::strerror(okay ? errno : saved_errno);
        unlink(temporary.c_str());
        return false;
    }
    chmod(path.c_str(), 0640);
    const int directory = open(parent.c_str(), O_RDONLY | O_DIRECTORY | O_CLOEXEC);
    if (directory >= 0) {
        fsync(directory);
        close(directory);
    }
    return true;
}

[[nodiscard]] bool save_journal(const Options &options, const Journal &journal,
                                std::string *error) {
    const std::string path = journal_path(options);
    const std::string parent = parent_directory(path);
    if (!ensure_directory(parent)) {
        *error = "cannot create journal directory";
        return false;
    }
    std::ostringstream output;
    output << "schema=" << journal.schema << '\n'
           << "generation=" << journal.generation << '\n'
           << "owner_pid=" << journal.owner_pid << '\n'
           << "owner_started_ms=" << journal.owner_started_ms << '\n'
           << "phase=" << journal.phase << '\n'
           << "boot_id=" << journal.boot_id << '\n'
           << "profile=" << journal.profile_id << '\n'
           << "profile_hash=" << journal.profile_hash << '\n';
    for (const auto &service : journal.services) {
        output << "service=" << service.name << ':' << service.state << '\n';
    }
    std::string clean_error = journal.error;
    std::replace(clean_error.begin(), clean_error.end(), '\n', ' ');
    output << "error=" << clean_error << '\n';

    const std::string temporary = path + ".new." + std::to_string(getpid());
    const int fd = open(temporary.c_str(), O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC,
                        0640);
    if (fd < 0) {
        *error = std::strerror(errno);
        return false;
    }
    const std::string content = output.str();
    const bool written = write_all(fd, content) && fsync(fd) == 0;
    const int saved_errno = errno;
    close(fd);
    if (!written || rename(temporary.c_str(), path.c_str()) != 0) {
        if (written) *error = std::strerror(errno); else *error = std::strerror(saved_errno);
        unlink(temporary.c_str());
        return false;
    }
    const int directory = open(parent.c_str(), O_RDONLY | O_DIRECTORY | O_CLOEXEC);
    if (directory >= 0) {
        fsync(directory);
        close(directory);
    }
    return true;
}

[[nodiscard]] bool load_journal(const Options &options, Journal *journal,
                                std::string *error) {
    const auto text = read_file(journal_path(options));
    if (!text) {
        *error = "journal not found";
        return false;
    }
    Journal candidate;
    std::istringstream input(*text);
    std::string line;
    while (std::getline(input, line)) {
        const size_t equals = line.find('=');
        if (equals == std::string::npos) continue;
        const std::string key = line.substr(0, equals);
        const std::string value = line.substr(equals + 1);
        if (key == "schema") {
            unsigned int schema = 0;
            if (!parse_uint(value, &schema)) {
                *error = "malformed journal schema";
                return false;
            }
            candidate.schema = static_cast<int>(schema);
        }
        else if (key == "generation") {
            if (!parse_u64(value, &candidate.generation)) {
                *error = "malformed journal generation";
                return false;
            }
        }
        else if (key == "owner_pid") {
            unsigned int owner_pid = 0;
            if (!parse_uint(value, &owner_pid)) {
                *error = "malformed journal owner pid";
                return false;
            }
            candidate.owner_pid = static_cast<int>(owner_pid);
        }
        else if (key == "owner_started_ms") {
            if (!parse_u64(value, &candidate.owner_started_ms)) {
                *error = "malformed journal owner start";
                return false;
            }
        }
        else if (key == "phase") candidate.phase = value;
        else if (key == "boot_id") candidate.boot_id = value;
        else if (key == "profile") candidate.profile_id = value;
        else if (key == "profile_hash") {
            if (!parse_u64(value, &candidate.profile_hash)) {
                *error = "malformed journal profile hash";
                return false;
            }
        }
        else if (key == "error") candidate.error = value;
        else if (key == "service") {
            const size_t colon = value.find(':');
            if (colon == std::string::npos || !valid_name(value.substr(0, colon))) {
                *error = "malformed journal service";
                return false;
            }
            candidate.services.push_back({value.substr(0, colon), value.substr(colon + 1)});
        }
    }
    if (candidate.schema != 1 || candidate.boot_id.empty() ||
        !valid_name(candidate.profile_id) || candidate.phase.empty()) {
        *error = "malformed audio journal";
        return false;
    }
    *journal = std::move(candidate);
    return true;
}

[[nodiscard]] std::string boot_id(const Options &options) {
    return trim(read_file(options.probe_root + "/proc/sys/kernel/random/boot_id")
                    .value_or("unknown"));
}

[[nodiscard]] bool topology_matches(const Options &options,
                                    const Profile &profile,
                                    std::string *error) {
    const auto cards = read_file(options.probe_root + "/proc/asound/cards");
    if (!cards || cards->find(profile.card_contains) == std::string::npos) {
        *error = "ALSA card topology does not match profile " + profile.id;
        return false;
    }
    for (const std::string &node : profile.required_nodes) {
        struct stat info {};
        if (stat((options.probe_root + node).c_str(), &info) != 0 ||
            !S_ISCHR(info.st_mode)) {
            *error = "required ALSA node missing or not a character device: " + node;
            return false;
        }
    }
    return true;
}

[[nodiscard]] std::string service_state(const Options &options,
                                        const std::string &service,
                                        unsigned int timeout_ms) {
    const CommandResult result = run_command(
        options.getprop, {"init.svc." + service}, timeout_ms);
    return result.status == 0 ? trim(result.output) : "unknown";
}

[[nodiscard]] bool set_service(const Options &options, const std::string &verb,
                               const std::string &service,
                               const std::string &wanted,
                               unsigned int timeout_ms, std::string *error) {
    const CommandResult command = run_command(
        options.setprop, {"ctl." + verb, service}, timeout_ms);
    if (command.status != 0) {
        *error = "setprop ctl." + verb + " " + service + " failed";
        return false;
    }
    const auto deadline = std::chrono::steady_clock::now() +
                          std::chrono::milliseconds(timeout_ms);
    do {
        if (service_state(options, service, timeout_ms) == wanted) return true;
        std::this_thread::sleep_for(std::chrono::milliseconds(50));
    } while (std::chrono::steady_clock::now() < deadline);
    *error = service + " did not reach " + wanted;
    return false;
}

[[nodiscard]] bool wait_for_unowned(const Options &options,
                                    const Profile &profile,
                                    std::string *error) {
    const auto deadline = std::chrono::steady_clock::now() +
                          std::chrono::milliseconds(profile.timeout_ms);
    do {
        const CommandResult probe = run_command(
            options.probe, {"--root", options.probe_root, "--require-unowned"},
            profile.timeout_ms);
        if (probe.status == 0) return true;
        if (probe.status != 3) {
            *error = probe.timed_out ? "ownership probe timed out" :
                                      "ownership probe failed";
            return false;
        }
        std::this_thread::sleep_for(std::chrono::milliseconds(50));
    } while (std::chrono::steady_clock::now() < deadline);
    *error = "guest did not release ALSA hardware before restore deadline";
    return false;
}

[[nodiscard]] bool restore_services(const Options &options, const Profile &profile,
                                    Journal *journal, bool require_release,
                                    std::string *error) {
    journal->phase = "restoring";
    if (!save_journal(options, *journal, error)) return false;
    if (!remove_claim_marker(options, error)) return false;
    if (require_release && !wait_for_unowned(options, profile, error)) {
        journal->phase = "restore-failed";
        journal->error = *error;
        std::string ignored;
        const bool journal_saved = save_journal(options, *journal, &ignored);
        (void)journal_saved;
        return false;
    }
    for (auto service = journal->services.rbegin();
         service != journal->services.rend(); ++service) {
        if (service->state != "running" && service->state != "restarting") continue;
        if (!set_service(options, "start", service->name, "running",
                         profile.timeout_ms, error)) {
            journal->phase = "restore-failed";
            journal->error = *error;
            std::string ignored;
            const bool journal_saved = save_journal(options, *journal, &ignored);
            (void)journal_saved;
            return false;
        }
    }
    journal->phase = "restored";
    journal->error.clear();
    return save_journal(options, *journal, error);
}

[[nodiscard]] bool rollback_services(const Options &options,
                                     const Profile &profile, Journal *journal,
                                     const std::string &cause,
                                     std::string *error) {
    if (!restore_services(options, profile, journal, false, error)) return false;
    journal->phase = "rolled-back";
    journal->error = cause;
    return save_journal(options, *journal, error);
}

[[nodiscard]] int claim(const Options &options, const Profile &profile) {
    TransactionLock lock(options);
    if (!lock.held()) {
        std::cerr << "another audio ownership transaction is active\n";
        return 75;
    }
    std::string error;
    if (!topology_matches(options, profile, &error)) {
        std::cerr << error << '\n';
        return 1;
    }
    if (access(options.probe.c_str(), X_OK) != 0 ||
        access(options.getprop.c_str(), X_OK) != 0 ||
        access(options.setprop.c_str(), X_OK) != 0) {
        std::cerr << "probe/getprop/setprop executable missing\n";
        return 1;
    }
    Journal previous;
    if (load_journal(options, &previous, &error) &&
        previous.phase != "restored" && previous.phase != "rolled-back" &&
        previous.phase != "none") {
        if (previous.phase == "claimed" && previous.boot_id == boot_id(options) &&
            previous.profile_hash == profile.hash) {
            std::cout << "already claimed\n";
            return 0;
        }
        std::cerr << "unfinished audio transaction; run recover first\n";
        return 1;
    }
    if (!options.apply) {
        std::cout << "{\"action\":\"claim\",\"apply\":false,\"profile\":\""
                  << json_escape(profile.id) << "\",\"services\":"
                  << profile.services.size() << "}\n";
        return 0;
    }

    Journal journal;
    journal.generation = previous.generation + 1U;
    journal.owner_pid = getpid();
    journal.owner_started_ms = monotonic_milliseconds();
    journal.phase = "snapshot";
    journal.boot_id = boot_id(options);
    journal.profile_id = profile.id;
    journal.profile_hash = profile.hash;
    for (const std::string &service : profile.services) {
        const std::string state = service_state(options, service, profile.timeout_ms);
        if (state == "unknown" || state.empty()) {
            std::cerr << "cannot snapshot service " << service << '\n';
            return 1;
        }
        journal.services.push_back({service, state});
    }
    if (!save_journal(options, journal, &error)) {
        std::cerr << "cannot save audio journal: " << error << '\n';
        return 1;
    }
    journal.phase = "quiescing";
    if (!save_journal(options, journal, &error)) {
        std::cerr << "cannot advance audio journal: " << error << '\n';
        return 1;
    }
    for (const auto &service : journal.services) {
        if (service.state != "running" && service.state != "restarting") continue;
        if (!set_service(options, "stop", service.name, "stopped",
                         profile.timeout_ms, &error)) {
            const std::string original_error = error;
            journal.error = original_error;
            const bool restored = rollback_services(
                options, profile, &journal, original_error, &error);
            std::cerr << "audio quiesce failed: " << original_error << '\n';
            if (!restored) std::cerr << "rollback also failed: " << error << '\n';
            return 1;
        }
    }
    const CommandResult probe = run_command(
        options.probe, {"--root", options.probe_root, "--require-unowned"},
        profile.timeout_ms);
    if (probe.status != 0) {
        journal.error = probe.timed_out ? "ownership probe timed out" :
                                         "ALSA hardware still has open holders";
        const std::string original_error = journal.error;
        const bool restored = rollback_services(
            options, profile, &journal, original_error, &error);
        std::cerr << original_error << '\n' << probe.output;
        if (!restored) std::cerr << "rollback also failed: " << error << '\n';
        return 1;
    }
    journal.phase = "claimed";
    journal.error.clear();
    if (!save_journal(options, journal, &error)) {
        const bool restored = rollback_services(
            options, profile, &journal, "cannot commit claimed journal", &error);
        std::cerr << "cannot commit claimed state; restored Android owners\n";
        if (!restored) std::cerr << "rollback also failed: " << error << '\n';
        return 1;
    }
    if (!write_claim_marker(options, journal, &error)) {
        const bool restored = rollback_services(
            options, profile, &journal, "cannot publish guest audio claim", &error);
        std::cerr << "cannot publish guest audio claim marker\n";
        if (!restored) std::cerr << "rollback also failed: " << error << '\n';
        return 1;
    }
    std::cout << "direct audio hardware claimed; PCM transport remains in guest ALSA\n";
    return 0;
}

[[nodiscard]] int restore(const Options &options, const Profile &profile,
                          bool recovery) {
    TransactionLock lock(options);
    if (!lock.held()) {
        std::cerr << "another audio ownership transaction is active\n";
        return 75;
    }
    std::string error;
    Journal journal;
    if (!load_journal(options, &journal, &error)) {
        std::cerr << error << '\n';
        return 1;
    }
    if (journal.phase == "restored") {
        std::cout << "already restored\n";
        return 0;
    }
    if (journal.profile_hash != profile.hash || journal.profile_id != profile.id) {
        std::cerr << "journal/profile mismatch; refusing unsafe restore\n";
        return 1;
    }
    if (journal.boot_id != boot_id(options)) {
        journal.phase = "stale-after-reboot";
        journal.error = "boot ID changed; no stale service actions applied";
        if (!save_journal(options, journal, &error)) std::cerr << error << '\n';
        std::cerr << "stale journal belongs to a previous boot; no action taken\n";
        return 1;
    }
    if (!options.apply) {
        std::cout << "{\"action\":\"" << (recovery ? "recover" : "restore")
                  << "\",\"apply\":false,\"phase\":\""
                  << json_escape(journal.phase) << "\"}\n";
        return 0;
    }
    const bool require_release =
        journal.phase == "claimed" || journal.phase == "restoring" ||
        journal.phase == "restore-failed" ||
        access(claim_marker_path(options).c_str(), F_OK) == 0;
    if (!restore_services(options, profile, &journal, require_release, &error)) {
        std::cerr << "audio restore failed: " << error << '\n';
        return 1;
    }
    std::cout << "Android audio ownership restored from journal\n";
    return 0;
}

void print_status(const Options &options) {
    Journal journal;
    std::string error;
    if (!load_journal(options, &journal, &error)) {
        std::cout << "{\"schema\":1,\"phase\":\"none\",\"journal\":false}\n";
        return;
    }
    std::cout << "{\"schema\":1,\"phase\":\"" << json_escape(journal.phase)
              << "\",\"journal\":true,\"profile\":\""
              << json_escape(journal.profile_id) << "\",\"boot_id\":\""
              << json_escape(journal.boot_id) << "\",\"services\":[";
    for (size_t index = 0; index < journal.services.size(); ++index) {
        if (index) std::cout << ',';
        std::cout << "{\"name\":\"" << json_escape(journal.services[index].name)
                  << "\",\"was\":\"" << json_escape(journal.services[index].state)
                  << "\"}";
    }
    std::cout << "],\"error\":\"" << json_escape(journal.error) << "\"}\n";
}

void usage(std::ostream &out) {
    out << "usage: det-audio-owner status [--root PATH]\n"
           "       det-audio-owner claim|restore|recover --profile FILE [--apply]\n"
           "              [--root PATH] [--probe PATH] [--probe-root PATH]\n"
           "              [--getprop PATH] [--setprop PATH]\n\n"
           "Without --apply, mutating commands only validate and print a plan.\n";
}

[[nodiscard]] bool parse_options(int argc, char **argv, Options *options) {
    if (argc < 2) return false;
    options->command = argv[1];
    for (int index = 2; index < argc; ++index) {
        const std::string argument = argv[index];
        auto value = [&](std::string *destination) {
            if (index + 1 >= argc) return false;
            *destination = argv[++index];
            return true;
        };
        if (argument == "--apply") options->apply = true;
        else if (argument == "--root") { if (!value(&options->root)) return false; }
        else if (argument == "--profile") { if (!value(&options->profile)) return false; }
        else if (argument == "--probe") { if (!value(&options->probe)) return false; }
        else if (argument == "--probe-root") { if (!value(&options->probe_root)) return false; }
        else if (argument == "--getprop") { if (!value(&options->getprop)) return false; }
        else if (argument == "--setprop") { if (!value(&options->setprop)) return false; }
        else return false;
    }
    if (options->root.empty() || options->root.front() != '/' ||
        options->probe_root.empty() || options->probe_root.front() != '/') return false;
    if (options->probe.empty()) options->probe = options->root + "/bin/det-audio-probe";
    if (options->profile.empty()) options->profile = options->root + "/etc/audio-owner.conf";
    return options->command == "status" || options->command == "claim" ||
           options->command == "restore" || options->command == "recover";
}

} // namespace

int main(int argc, char **argv) {
    Options options;
    if (!parse_options(argc, argv, &options)) {
        usage(std::cerr);
        return 2;
    }
    if (options.command == "status") {
        print_status(options);
        return 0;
    }
    Profile profile;
    std::string error;
    if (!load_profile(options.profile, &profile, &error)) {
        std::cerr << error << '\n';
        return 1;
    }
    if (options.command == "claim") return claim(options, profile);
    return restore(options, profile, options.command == "recover");
}
