#pragma once

#include "determination/control/state.hpp"

#include <sys/types.h>

namespace determination::control {

enum class Endpoint {
    Admin,
    Guest,
};

bool endpoint_peer_allowed(Endpoint endpoint, uid_t uid);
bool mode_request_allowed(Endpoint endpoint, uid_t uid, Mode target);
bool recovery_request_allowed(Endpoint endpoint, uid_t uid);
bool guest_report_allowed(Endpoint endpoint, uid_t uid);

} // namespace determination::control

