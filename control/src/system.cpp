#include "determination/control/system.hpp"

#include <algorithm>
#include <cerrno>
#include <chrono>
#include <cctype>
#include <cstring>
#include <dirent.h>
#include <fcntl.h>
#include <iomanip>
#include <sstream>
#include <sys/stat.h>
#include <unistd.h>

#ifdef __ANDROID__
#include <sys/system_properties.h>
#endif

namespace determination::control {

std::uint64_t monotonic_milliseconds()
{
    const auto now = std::chrono::steady_clock::now().time_since_epoch();
    return static_cast<std::uint64_t>(
        std::chrono::duration_cast<std::chrono::milliseconds>(now).count());
}

std::string read_file(const std::string &path, std::size_t limit)
{
    const int fd = open(path.c_str(), O_RDONLY | O_CLOEXEC);
    if (fd < 0) return {};
    std::string value;
    value.reserve(std::min<std::size_t>(limit, 4096U));
    char buffer[4096];
    while (value.size() < limit) {
        const std::size_t wanted = std::min(sizeof(buffer), limit - value.size());
        ssize_t count;
        do {
            count = read(fd, buffer, wanted);
        } while (count < 0 && errno == EINTR);
        if (count <= 0) break;
        value.append(buffer, static_cast<std::size_t>(count));
    }
    close(fd);
    return value;
}

std::string trim(std::string value)
{
    const auto not_space = [](unsigned char character) {
        return std::isspace(character) == 0;
    };
    value.erase(value.begin(),
                std::find_if(value.begin(), value.end(), not_space));
    value.erase(std::find_if(value.rbegin(), value.rend(), not_space).base(),
                value.end());
    return value;
}

std::string json_escape(const std::string &value)
{
    std::ostringstream output;
    for (const unsigned char character : value) {
        switch (character) {
        case '\\': output << "\\\\"; break;
        case '"': output << "\\\""; break;
        case '\b': output << "\\b"; break;
        case '\f': output << "\\f"; break;
        case '\n': output << "\\n"; break;
        case '\r': output << "\\r"; break;
        case '\t': output << "\\t"; break;
        default:
            if (character < 0x20U) {
                output << "\\u" << std::hex << std::setw(4) << std::setfill('0')
                       << static_cast<unsigned int>(character) << std::dec;
            } else {
                output << character;
            }
        }
    }
    return output.str();
}

std::string key_value(const std::string &text, const std::string &key)
{
    std::istringstream lines(text);
    std::string line;
    const std::string prefix = key + '=';
    std::string result;
    while (std::getline(lines, line)) {
        if (line.rfind(prefix, 0) == 0) result = trim(line.substr(prefix.size()));
    }
    if (result.size() >= 2U &&
        ((result.front() == '"' && result.back() == '"') ||
         (result.front() == '\'' && result.back() == '\''))) {
        result = result.substr(1, result.size() - 2U);
    }
    return result;
}

std::string boot_id()
{
    return trim(read_file("/proc/sys/kernel/random/boot_id", 128));
}

std::string android_property(const std::string &name)
{
#ifdef __ANDROID__
    char value[PROP_VALUE_MAX]{};
    const int size = __system_property_get(name.c_str(), value);
    return size > 0 ? std::string(value, static_cast<std::size_t>(size)) : std::string{};
#else
    (void)name;
    return {};
#endif
}

std::map<std::string, char> process_states(const std::vector<std::string> &names)
{
    std::map<std::string, char> answers;
    for (const std::string &name : names) answers[name] = '-';
    DIR *directory = opendir("/proc");
    if (!directory) {
        for (auto &[name, state] : answers) {
            (void)name;
            state = '?';
        }
        return answers;
    }
    std::size_t remaining = answers.size();
    while (const dirent *entry = readdir(directory)) {
        if (!std::isdigit(static_cast<unsigned char>(entry->d_name[0]))) continue;
        const std::string base = std::string("/proc/") + entry->d_name;
        const std::string name = trim(read_file(base + "/comm", 256));
        const auto answer = answers.find(name);
        if (answer == answers.end() || answer->second != '-') continue;
        const std::string status = read_file(base + "/status", 4096);
        const std::size_t position = status.find("State:");
        if (position != std::string::npos) {
            const std::size_t colon = status.find(':', position);
            const std::size_t state = colon == std::string::npos
                ? std::string::npos
                : status.find_first_not_of("\t ", colon + 1U);
            if (state != std::string::npos) answer->second = status[state];
        }
        if (answer->second == '-') answer->second = '?';
        if (--remaining == 0U) break;
    }
    closedir(directory);
    return answers;
}

char process_state(const std::string &name)
{
    const auto states = process_states({name});
    const auto found = states.find(name);
    return found == states.end() ? '?' : found->second;
}

bool path_exists(const std::string &path)
{
    struct stat metadata{};
    return lstat(path.c_str(), &metadata) == 0;
}

bool ensure_directory(const std::string &path, unsigned int mode,
                      std::string *error)
{
    if (path.empty() || path.front() != '/') {
        if (error) *error = "directory path must be absolute";
        errno = EINVAL;
        return false;
    }
    std::string current;
    std::size_t offset = 1;
    while (offset <= path.size()) {
        const std::size_t slash = path.find('/', offset);
        const std::size_t end = slash == std::string::npos ? path.size() : slash;
        current = path.substr(0, end);
        if (!current.empty() && mkdir(current.c_str(), static_cast<mode_t>(mode)) != 0 &&
            errno != EEXIST) {
            if (error) *error = std::strerror(errno);
            return false;
        }
        if (slash == std::string::npos) break;
        offset = slash + 1U;
    }
    return true;
}

bool atomic_write_file(const std::string &path, const std::string &value,
                       unsigned int mode, std::string *error)
{
    const std::size_t slash = path.rfind('/');
    const std::string parent = slash == std::string::npos ? "." : path.substr(0, slash);
    if (parent != "." && !ensure_directory(parent, 0750, error)) return false;
    const std::string temporary = path + ".new." + std::to_string(getpid());
    unlink(temporary.c_str());
    const int fd = open(temporary.c_str(), O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC,
                        static_cast<mode_t>(mode));
    if (fd < 0) {
        if (error) *error = std::strerror(errno);
        return false;
    }
    std::size_t offset = 0;
    while (offset < value.size()) {
        ssize_t written;
        do {
            written = write(fd, value.data() + offset, value.size() - offset);
        } while (written < 0 && errno == EINTR);
        if (written <= 0) {
            const int saved = errno;
            close(fd);
            unlink(temporary.c_str());
            if (error) *error = std::strerror(saved);
            return false;
        }
        offset += static_cast<std::size_t>(written);
    }
    if (fsync(fd) != 0) {
        const int saved = errno;
        close(fd);
        unlink(temporary.c_str());
        if (error) *error = std::strerror(saved);
        return false;
    }
    close(fd);
    if (rename(temporary.c_str(), path.c_str()) != 0) {
        if (error) *error = std::strerror(errno);
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

std::uint64_t fnv1a64(const std::string &value)
{
    std::uint64_t hash = 14695981039346656037ULL;
    for (const unsigned char byte : value) {
        hash ^= byte;
        hash *= 1099511628211ULL;
    }
    return hash;
}

} // namespace determination::control
