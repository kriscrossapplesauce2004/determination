#pragma once

#include "determination/control/state.hpp"

#include <string>

namespace determination::control {

struct ObservabilityOptions {
    std::string root;
    bool observe_only = true;
};

std::string status_payload(const ObservabilityOptions &options,
                           const StateRecord &state);
std::string doctor_payload(const ObservabilityOptions &options,
                           const StateRecord &state);
std::string metrics_payload(const ObservabilityOptions &options,
                            const StateRecord &state);
std::string capabilities_payload(const ObservabilityOptions &options,
                                 bool guest_endpoint);

} // namespace determination::control
