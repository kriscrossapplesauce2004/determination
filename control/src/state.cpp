#include "determination/control/state.hpp"

#include "determination/control/system.hpp"

#include <cerrno>
#include <charconv>
#include <cctype>
#include <cstring>
#include <fcntl.h>
#include <map>
#include <sstream>
#include <sys/stat.h>
#include <unistd.h>

namespace determination::control {
namespace {

std::string encode(const std::string &value)
{
    static constexpr char hex[] = "0123456789ABCDEF";
    std::string encoded;
    for (const unsigned char byte : value) {
        if (std::isalnum(byte) || byte == '-' || byte == '_' || byte == '.' ||
            byte == '/' || byte == ':') {
            encoded.push_back(static_cast<char>(byte));
        } else {
            encoded.push_back('%');
            encoded.push_back(hex[byte >> 4U]);
            encoded.push_back(hex[byte & 0x0fU]);
        }
    }
    return encoded;
}

int hex_value(char character)
{
    if (character >= '0' && character <= '9') return character - '0';
    if (character >= 'A' && character <= 'F') return character - 'A' + 10;
    if (character >= 'a' && character <= 'f') return character - 'a' + 10;
    return -1;
}

bool decode(const std::string &value, std::string *decoded)
{
    decoded->clear();
    for (std::size_t index = 0; index < value.size(); ++index) {
        if (value[index] != '%') {
            decoded->push_back(value[index]);
            continue;
        }
        if (index + 2U >= value.size()) return false;
        const int high = hex_value(value[index + 1U]);
        const int low = hex_value(value[index + 2U]);
        if (high < 0 || low < 0) return false;
        decoded->push_back(static_cast<char>((high << 4) | low));
        index += 2U;
    }
    return true;
}

template <typename Number>
bool parse_number(const std::string &value, Number *number)
{
    const char *begin = value.data();
    const char *end = begin + value.size();
    const auto parsed = std::from_chars(begin, end, *number);
    return parsed.ec == std::errc{} && parsed.ptr == end;
}

std::string parent_directory(const std::string &path)
{
    const std::size_t slash = path.rfind('/');
    return slash == std::string::npos ? "." : path.substr(0, slash);
}

bool write_all(int fd, const std::string &value)
{
    std::size_t offset = 0;
    while (offset < value.size()) {
        ssize_t written;
        do {
            written = write(fd, value.data() + offset, value.size() - offset);
        } while (written < 0 && errno == EINTR);
        if (written <= 0) return false;
        offset += static_cast<std::size_t>(written);
    }
    return true;
}

std::string join_steps(const std::vector<std::string> &steps)
{
    std::string joined;
    for (const std::string &step : steps) {
        if (!joined.empty()) joined.push_back('\n');
        joined.append(step);
    }
    return joined;
}

std::vector<std::string> split_steps(const std::string &joined)
{
    std::vector<std::string> steps;
    std::istringstream input(joined);
    std::string step;
    while (std::getline(input, step)) {
        if (!step.empty()) steps.push_back(std::move(step));
    }
    return steps;
}

} // namespace

std::string mode_name(Mode mode)
{
    switch (mode) {
    case Mode::Phone: return "phone";
    case Mode::Entering: return "entering";
    case Mode::Desktop: return "desktop";
    case Mode::Exiting: return "exiting";
    case Mode::Recovery: return "recovery";
    case Mode::Unknown: return "unknown";
    }
    return "unknown";
}

Mode parse_mode(const std::string &value)
{
    if (value == "phone") return Mode::Phone;
    if (value == "entering") return Mode::Entering;
    if (value == "desktop") return Mode::Desktop;
    if (value == "exiting") return Mode::Exiting;
    if (value == "recovery") return Mode::Recovery;
    return Mode::Unknown;
}

StateStore::StateStore(std::string path) : path_(std::move(path)) {}

bool StateStore::load(StateRecord *state, std::string *error) const
{
    const std::string text = read_file(path_, 128U * 1024U);
    if (text.empty()) {
        if (error) *error = path_exists(path_) ? "state file is empty" : "state file not found";
        return false;
    }
    std::map<std::string, std::string> values;
    std::istringstream lines(text);
    std::string line;
    while (std::getline(lines, line)) {
        if (line.empty()) continue;
        const std::size_t equals = line.find('=');
        if (equals == std::string::npos || equals == 0) {
            if (error) *error = "malformed state line";
            return false;
        }
        std::string decoded;
        if (!decode(line.substr(equals + 1U), &decoded)) {
            if (error) *error = "malformed state escape";
            return false;
        }
        values[line.substr(0, equals)] = std::move(decoded);
    }

    StateRecord candidate;
    if (!parse_number(values["schema"], &candidate.schema) || candidate.schema != 1 ||
        !parse_number(values["generation"], &candidate.generation) ||
        !parse_number(values["transition_id"], &candidate.transition_id) ||
        !parse_number(values["started_ms"], &candidate.started_monotonic_ms) ||
        !parse_number(values["deadline_ms"], &candidate.deadline_monotonic_ms) ||
        !parse_number(values["adapter_status"], &candidate.adapter_status)) {
        if (error) *error = "invalid state number or schema";
        return false;
    }
    candidate.boot_id = values["boot_id"];
    candidate.desired = parse_mode(values["desired"]);
    candidate.observed = parse_mode(values["observed"]);
    candidate.step = values["step"];
    candidate.completed_steps = split_steps(values["completed_steps"]);
    candidate.last_error = values["last_error"];
    candidate.adapter_output = values["adapter_output"];
    if (candidate.desired == Mode::Unknown || candidate.observed == Mode::Unknown ||
        candidate.boot_id.empty()) {
        if (error) *error = "invalid state mode or boot id";
        return false;
    }
    *state = std::move(candidate);
    return true;
}

bool StateStore::save(const StateRecord &state, std::string *error) const
{
    const std::string parent = parent_directory(path_);
    if (!ensure_directory(parent, 0750, error)) return false;

    std::ostringstream output;
    output << "schema=" << state.schema << '\n'
           << "generation=" << state.generation << '\n'
           << "boot_id=" << encode(state.boot_id) << '\n'
           << "desired=" << mode_name(state.desired) << '\n'
           << "observed=" << mode_name(state.observed) << '\n'
           << "transition_id=" << state.transition_id << '\n'
           << "step=" << encode(state.step) << '\n'
           << "completed_steps=" << encode(join_steps(state.completed_steps)) << '\n'
           << "started_ms=" << state.started_monotonic_ms << '\n'
           << "deadline_ms=" << state.deadline_monotonic_ms << '\n'
           << "adapter_status=" << state.adapter_status << '\n'
           << "last_error=" << encode(state.last_error) << '\n'
           << "adapter_output=" << encode(state.adapter_output) << '\n';

    const std::string temporary = path_ + ".new." + std::to_string(getpid());
    const int fd = open(temporary.c_str(), O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC,
                        0640);
    if (fd < 0) {
        if (errno == EEXIST) unlink(temporary.c_str());
        const int retry = open(temporary.c_str(), O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC,
                               0640);
        if (retry < 0) {
            if (error) *error = std::strerror(errno);
            return false;
        }
        const std::string text = output.str();
        const bool okay = write_all(retry, text) && fsync(retry) == 0;
        const int saved_errno = errno;
        close(retry);
        if (!okay) {
            unlink(temporary.c_str());
            if (error) *error = std::strerror(saved_errno);
            return false;
        }
    } else {
        const std::string text = output.str();
        const bool okay = write_all(fd, text) && fsync(fd) == 0;
        const int saved_errno = errno;
        close(fd);
        if (!okay) {
            unlink(temporary.c_str());
            if (error) *error = std::strerror(saved_errno);
            return false;
        }
    }
    if (rename(temporary.c_str(), path_.c_str()) != 0) {
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

std::string state_json(const StateRecord &state)
{
    std::ostringstream output;
    output << "{\"schema\":" << state.schema
           << ",\"generation\":" << state.generation
           << ",\"boot_id\":\"" << json_escape(state.boot_id) << '"'
           << ",\"desired\":\"" << mode_name(state.desired) << '"'
           << ",\"observed\":\"" << mode_name(state.observed) << '"'
           << ",\"transition_id\":" << state.transition_id
           << ",\"step\":\"" << json_escape(state.step) << '"'
           << ",\"completed_steps\":[";
    for (std::size_t index = 0; index < state.completed_steps.size(); ++index) {
        if (index != 0) output << ',';
        output << '"' << json_escape(state.completed_steps[index]) << '"';
    }
    output << ']'
           << ",\"started_monotonic_ms\":" << state.started_monotonic_ms
           << ",\"deadline_monotonic_ms\":" << state.deadline_monotonic_ms
           << ",\"adapter_status\":" << state.adapter_status
           << ",\"last_error\":\"" << json_escape(state.last_error) << '"'
           << '}';
    return output.str();
}

} // namespace determination::control
