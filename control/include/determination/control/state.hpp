#pragma once

#include <cstdint>
#include <string>
#include <vector>

namespace determination::control {

enum class Mode {
    Unknown,
    Phone,
    Entering,
    Desktop,
    Exiting,
    Recovery,
};

std::string mode_name(Mode mode);
Mode parse_mode(const std::string &value);

struct StateRecord {
    std::uint32_t schema = 1;
    std::uint64_t generation = 0;
    std::string boot_id;
    Mode desired = Mode::Phone;
    Mode observed = Mode::Unknown;
    std::uint64_t transition_id = 0;
    std::string step = "idle";
    std::vector<std::string> completed_steps;
    std::uint64_t started_monotonic_ms = 0;
    std::uint64_t deadline_monotonic_ms = 0;
    std::int32_t adapter_status = 0;
    std::string last_error;
    std::string adapter_output;
};

class StateStore {
public:
    explicit StateStore(std::string path);

    bool load(StateRecord *state, std::string *error) const;
    bool save(const StateRecord &state, std::string *error) const;
    const std::string &path() const { return path_; }

private:
    std::string path_;
};

std::string state_json(const StateRecord &state);

} // namespace determination::control
